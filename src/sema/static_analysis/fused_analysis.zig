//! 融合静态分析模块。
//!
//! 将常量传播、纯度分析、循环不变量外提、死代码消除和公共子表达式消除融合为
//! 单遍分析。FusedAnalysis 在一次遍历中同时完成常量折叠与调用图构建，随后通过
//! 不动点迭代传播纯度信息，最后委托 DeadCodePass 和 CsePass 完成各自的独立遍。

const std = @import("std");
const ast = @import("ast");
const const_prop_mod = @import("const_prop.zig");
const loop_invariant_mod = @import("loop_invariant.zig");
const purity_mod = @import("purity.zig");
const dead_code_mod = @import("dead_code.zig");
const cse_mod = @import("cse.zig");

const ConstValue = const_prop_mod.ConstValue;
const ConstEnv = const_prop_mod.ConstEnv;
const LoopInfo = loop_invariant_mod.LoopInfo;
const HoistTable = loop_invariant_mod.HoistTable;
const PurityInfo = purity_mod.PurityInfo;
const DeadTable = dead_code_mod.DeadTable;
const DeadCodePass = dead_code_mod.DeadCodePass;
const CseTable = cse_mod.CseTable;
const CsePass = cse_mod.CsePass;

/// 循环展开的估算大小阈值。循环体估算大小不超过此值时视为小循环，可考虑展开。
const UNROLL_THRESHOLD: u32 = 32;

/// 融合分析器。在一次遍历中完成常量传播、纯度分析和循环不变量收集，
/// 并在遍历结束后委托 DCE 和 CSE 进行独立分析。
pub const FusedAnalysis = struct {
    const_table: *const_prop_mod.ConstTable,
    loop_table: *loop_invariant_mod.LoopTable,
    purity_table: *purity_mod.PurityTable,
    hoist_table: *loop_invariant_mod.HoistTable,
    dead_table: *DeadTable,
    cse_table: *CseTable,
    allocator: std.mem.Allocator,
    /// 调用图：函数名 -> 其调用的其他函数名列表。
    name_call_graph: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    /// 直接判定为非纯的函数名集合（调用了内建非纯函数或方法调用等）。
    direct_impure: std.StringHashMap(void),
    /// 模块中所有函数名列表。
    all_fn_names: std.ArrayListUnmanaged([]const u8),

    pub fn init(
        allocator: std.mem.Allocator,
        const_table: *const_prop_mod.ConstTable,
        loop_table: *loop_invariant_mod.LoopTable,
        purity_table: *purity_mod.PurityTable,
        hoist_table: *loop_invariant_mod.HoistTable,
        dead_table: *DeadTable,
        cse_table: *CseTable,
    ) FusedAnalysis {
        return .{
            .const_table = const_table,
            .loop_table = loop_table,
            .purity_table = purity_table,
            .hoist_table = hoist_table,
            .dead_table = dead_table,
            .cse_table = cse_table,
            .allocator = allocator,
            .name_call_graph = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .direct_impure = std.StringHashMap(void).init(allocator),
            .all_fn_names = .empty,
        };
    }

    pub fn deinit(self: *FusedAnalysis) void {
        var it = self.name_call_graph.valueIterator();
        while (it.next()) |callees| callees.deinit(self.allocator);
        self.name_call_graph.deinit();
        self.direct_impure.deinit();
        self.all_fn_names.deinit(self.allocator);
    }

    /// 分析整个模块：常量传播 + 纯度不动点 + DCE + CSE。
    pub fn analyzeModule(self: *FusedAnalysis, module: *const ast.Module) !void {
        // 第一遍：收集所有函数名，初始假定全部为纯函数。
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const name = decl.fun_decl.name;
            try self.all_fn_names.append(self.allocator, name);
            try self.purity_table.put(name, .pure);
        }
        // 第二遍：逐函数进行常量传播与调用图构建。
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const fd = decl.fun_decl;
            var env = ConstEnv.init(self.allocator, null);
            defer env.deinit();
            try self.analyzeExpr(fd.body, &env, fd.name);
        }
        // 基于调用图传播纯度信息至不动点。
        try self.purityFixpoint();
        // 委托 DCE 和 CSE 进行独立分析。
        var dce_pass = DeadCodePass.init(self.allocator, self.dead_table);
        try dce_pass.analyzeModule(module);
        var cse_pass = CsePass.init(self.allocator, self.cse_table);
        try cse_pass.analyzeModule(module);
    }

    /// 递归分析表达式：常量折叠、调用图边收集、纯度判定。
    fn analyzeExpr(
        self: *FusedAnalysis,
        expr: *const ast.Expr,
        env: *ConstEnv,
        current_fn: []const u8,
    ) anyerror!void {
        switch (expr.*) {
            .int_literal => |il| {
                const val = parseIntLiteral(self.allocator, il.raw) orelse ConstValue.unknown;
                try self.const_table.put(expr, val);
            },
            .float_literal => |fl| {
                if (std.fmt.parseFloat(f64, fl.raw)) |fval| {
                    try self.const_table.put(expr, .{ .float_val = fval });
                } else |_| {
                    try self.const_table.put(expr, ConstValue.unknown);
                }
            },
            .bool_literal => |bl| {
                try self.const_table.put(expr, .{ .bool_val = bl.value });
            },
            .identifier => |id| {
                // 从常量环境中查找变量绑定。
                if (env.get(id.name)) |val| {
                    try self.const_table.put(expr, val);
                }
            },
            .binary => |b| {
                try self.analyzeExpr(b.left, env, current_fn);
                try self.analyzeExpr(b.right, env, current_fn);
                const lv = self.const_table.lookup(b.left) orelse ConstValue.unknown;
                const rv = self.const_table.lookup(b.right) orelse ConstValue.unknown;
                if (evalBinary(b.op, lv, rv)) |result| {
                    try self.const_table.put(expr, result);
                }
            },
            .unary => |u| {
                try self.analyzeExpr(u.operand, env, current_fn);
                const v = self.const_table.lookup(u.operand) orelse ConstValue.unknown;
                if (evalUnary(u.op, v)) |result| {
                    try self.const_table.put(expr, result);
                }
            },
            .if_expr => |i| {
                try self.analyzeExpr(i.condition, env, current_fn);
                try self.analyzeExpr(i.then_branch, env, current_fn);
                if (i.else_branch) |e| try self.analyzeExpr(e, env, current_fn);
            },
            .block => |b| {
                // 块创建新的子作用域。
                var child_env = ConstEnv.init(self.allocator, env);
                defer child_env.deinit();
                for (b.statements) |s| {
                    try self.analyzeStmt(s, &child_env, current_fn);
                }
                if (b.trailing_expr) |te| try self.analyzeExpr(te, &child_env, current_fn);
            },
            .call => |c| {
                try self.analyzeExpr(c.callee, env, current_fn);
                for (c.arguments) |arg| try self.analyzeExpr(arg, env, current_fn);
                if (c.callee.* == .identifier) {
                    const callee_name = c.callee.identifier.name;
                    // 递归调用不构成调用图边（不影响纯度判定），但标记为递归函数（memoization 用）
                    if (!std.mem.eql(u8, callee_name, current_fn)) {
                        if (isImpureBuiltin(callee_name)) {
                            // 调用内建非纯函数，当前函数直接标记为非纯。
                            try self.direct_impure.put(current_fn, {});
                        } else {
                            // 添加调用图边 current_fn -> callee_name（去重）。
                            const gop = try self.name_call_graph.getOrPut(current_fn);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            for (gop.value_ptr.items) |existing| {
                                if (std.mem.eql(u8, existing, callee_name)) return;
                            }
                            try gop.value_ptr.append(self.allocator, callee_name);
                        }
                    } else {
                        // 直接递归：标记为递归函数（驱动 memoization）
                        try self.purity_table.markRecursive(current_fn);
                    }
                } else {
                    // 非标识符调用（如方法调用、lambda 调用）保守视为非纯。
                    try self.direct_impure.put(current_fn, {});
                }
            },
            // 方法调用、安全方法调用、select、inline_trait_value 均保守视为非纯。
            .method_call => {
                try self.direct_impure.put(current_fn, {});
            },
            .safe_method_call => {
                try self.direct_impure.put(current_fn, {});
            },
            .select => {
                try self.direct_impure.put(current_fn, {});
            },
            .inline_trait_value => {
                try self.direct_impure.put(current_fn, {});
            },
            .field_access => |f| try self.analyzeExpr(f.object, env, current_fn),
            .safe_access => |f| try self.analyzeExpr(f.object, env, current_fn),
            .index => |i| {
                try self.analyzeExpr(i.object, env, current_fn);
                try self.analyzeExpr(i.index, env, current_fn);
            },
            .non_null_assert => |n| try self.analyzeExpr(n.expr, env, current_fn),
            .propagate => |p| try self.analyzeExpr(p.expr, env, current_fn),
            .array_literal => |a| {
                for (a.elements) |e| try self.analyzeExpr(e, env, current_fn);
            },
            .record_literal => |r| {
                for (r.fields) |f| try self.analyzeExpr(f.value, env, current_fn);
            },
            .record_extend => |r| {
                try self.analyzeExpr(r.base, env, current_fn);
                for (r.updates) |u| try self.analyzeExpr(u.value, env, current_fn);
            },
            .lambda => {},
            .match => |m| {
                try self.analyzeExpr(m.scrutinee, env, current_fn);
                for (m.arms) |arm| {
                    if (arm.guard) |g| try self.analyzeExpr(g, env, current_fn);
                    try self.analyzeExpr(arm.body, env, current_fn);
                }
            },
            .type_cast => |t| try self.analyzeExpr(t.expr, env, current_fn),
            .atomic_expr => |a| try self.analyzeExpr(a.value, env, current_fn),
            .lazy => |l| try self.analyzeExpr(l.expr, env, current_fn),
            .assignment_expr => |a| {
                try self.analyzeExpr(a.target, env, current_fn);
                try self.analyzeExpr(a.value, env, current_fn);
            },
            .compound_assign => |c| {
                try self.analyzeExpr(c.target, env, current_fn);
                try self.analyzeExpr(c.value, env, current_fn);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) try self.analyzeExpr(part.expression, env, current_fn);
                }
            },
            else => {},
        }
    }

    /// 递归分析语句：常量传播、循环大小估算、循环不变量收集。
    fn analyzeStmt(
        self: *FusedAnalysis,
        stmt: *const ast.Stmt,
        env: *ConstEnv,
        current_fn: []const u8,
    ) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                try self.analyzeExpr(v.value, env, current_fn);
                // 若初值为常量，则绑定到环境中。
                if (self.const_table.lookup(v.value)) |val| {
                    if (val != .unknown) {
                        try env.put(v.name, val);
                    }
                }
            },
            .var_decl => |v| {
                try self.analyzeExpr(v.value, env, current_fn);
            },
            .assignment => |a| {
                try self.analyzeExpr(a.value, env, current_fn);
                // 赋值后变量不再为常量，从环境中移除。
                if (a.target.* == .identifier) {
                    _ = env.remove(a.target.identifier.name);
                }
            },
            .expression => |e| try self.analyzeExpr(e.expr, env, current_fn),
            .return_stmt => |r| if (r.value) |v| try self.analyzeExpr(v, env, current_fn),
            .for_stmt => |f| {
                try self.analyzeExpr(f.iterable, env, current_fn);
                // 估算循环体大小并记录到循环表。
                const size = self.estimateSize(f.body);
                try self.loop_table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                // 收集循环体内被赋值的变量，用于判断循环不变量。
                var for_assigned: std.ArrayListUnmanaged([]const u8) = .empty;
                defer for_assigned.deinit(self.allocator);
                try for_assigned.append(self.allocator, f.name);
                try loop_invariant_mod.collectAssignedVars(self.allocator, f.body, &for_assigned);
                try loop_invariant_mod.collectHoistsInExpr(
                    self.allocator,
                    self.hoist_table,
                    f.body,
                    stmt,
                    for_assigned.items,
                );
                try self.analyzeExpr(f.body, env, current_fn);
            },
            .while_stmt => |w| {
                try self.analyzeExpr(w.condition, env, current_fn);
                const size = self.estimateSize(w.body);
                try self.loop_table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                var assigned: std.ArrayListUnmanaged([]const u8) = .empty;
                defer assigned.deinit(self.allocator);
                try loop_invariant_mod.collectAssignedVars(self.allocator, w.body, &assigned);
                try loop_invariant_mod.collectHoistsInExpr(
                    self.allocator,
                    self.hoist_table,
                    w.body,
                    stmt,
                    assigned.items,
                );
                try self.analyzeExpr(w.body, env, current_fn);
            },
            .loop_stmt => |l| {
                const size = self.estimateSize(l.body);
                try self.loop_table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                var assigned: std.ArrayListUnmanaged([]const u8) = .empty;
                defer assigned.deinit(self.allocator);
                try loop_invariant_mod.collectAssignedVars(self.allocator, l.body, &assigned);
                try loop_invariant_mod.collectHoistsInExpr(
                    self.allocator,
                    self.hoist_table,
                    l.body,
                    stmt,
                    assigned.items,
                );
                try self.analyzeExpr(l.body, env, current_fn);
            },
            .defer_stmt => |d| try self.analyzeExpr(d.expr, env, current_fn),
            .throw_stmt => |t| try self.analyzeExpr(t.expr, env, current_fn),
            .field_assignment => |f| try self.analyzeExpr(f.value, env, current_fn),
            .compound_assignment => |c| try self.analyzeExpr(c.value, env, current_fn),
            .break_stmt, .continue_stmt => {},
        }
    }

    /// 纯度不动点迭代：从直接非纯函数出发，沿逆向调用图传播 impure 标记。
    fn purityFixpoint(self: *FusedAnalysis) !void {
        // 工作列表初始化为所有直接非纯函数。
        var worklist = std.ArrayList([]const u8).empty;
        defer worklist.deinit(self.allocator);
        var it = self.direct_impure.keyIterator();
        while (it.next()) |k| {
            try worklist.append(self.allocator, k.*);
        }
        for (worklist.items) |name| {
            try self.purity_table.put(name, .impure);
        }

        // 构建逆向调用图：callee -> [callers]。
        var reverse_edges = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(self.allocator);
        defer {
            var rit = reverse_edges.valueIterator();
            while (rit.next()) |callers| callers.deinit(self.allocator);
            reverse_edges.deinit();
        }
        var git = self.name_call_graph.iterator();
        while (git.next()) |entry| {
            const caller = entry.key_ptr.*;
            for (entry.value_ptr.items) |callee| {
                const gop = try reverse_edges.getOrPut(callee);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, caller);
            }
        }

        // 工作列表算法：非纯函数的调用者也变为非纯，直到不再有变化。
        while (worklist.items.len > 0) {
            const impure_fn = worklist.pop().?;
            if (reverse_edges.get(impure_fn)) |callers| {
                for (callers.items) |caller| {
                    if (self.purity_table.lookup(caller)) |info| {
                        if (info == .pure) {
                            try self.purity_table.put(caller, .impure);
                            try worklist.append(self.allocator, caller);
                        }
                    }
                }
            }
        }
    }

    /// 估算表达式的大小（用于循环展开判定）。字面量和标识符为 1，复杂构造按结构递归累加。
    fn estimateSize(self: *FusedAnalysis, expr: *const ast.Expr) u32 {
        return switch (expr.*) {
            .int_literal, .float_literal, .bool_literal, .char_literal,
            .string_literal, .null_literal, .unit_literal, .identifier,
            => 1,
            .binary => 3,
            .unary => 2,
            .call => |c| 1 + @as(u32, @intCast(c.arguments.len)),
            .if_expr => |i| 5 + (if (i.else_branch != null) @as(u32, 1) else 0),
            .block => |b| blk: {
                var size: u32 = 0;
                for (b.statements) |s| size += self.estimateStmtSize(s);
                if (b.trailing_expr) |te| size += self.estimateSize(te);
                break :blk size;
            },
            else => 5,
        };
    }

    /// 估算语句的大小。
    fn estimateStmtSize(self: *FusedAnalysis, stmt: *const ast.Stmt) u32 {
        return switch (stmt.*) {
            .val_decl => |v| self.estimateSize(v.value) + 1,
            .var_decl => |v| self.estimateSize(v.value) + 1,
            .assignment => |a| self.estimateSize(a.value) + 1,
            .expression => |e| self.estimateSize(e.expr),
            .return_stmt => |r| if (r.value) |v| self.estimateSize(v) + 1 else 1,
            .for_stmt => 5,
            .while_stmt => 5,
            .loop_stmt => 5,
            else => 1,
        };
    }
};

/// 内建非纯函数列表。这些函数有 I/O、并发或通信副作用，调用它们的函数自动判定为非纯。
const impure_builtins = [_][]const u8{
    "println", "print", "eprintln", "eprint",
    "async",   "lazy",  "select",   "send",   "recv",
};

/// 判断给定函数名是否为内建非纯函数。
fn isImpureBuiltin(name: []const u8) bool {
    for (impure_builtins) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

/// 对两个常量执行二元运算并返回折叠结果；任一操作数为 unknown 或运算不适用时返回 null。
fn evalBinary(op: ast.BinaryOp, lv: ConstValue, rv: ConstValue) ?ConstValue {
    if (lv == .unknown or rv == .unknown) return null;
    if (lv == .int_val and rv == .int_val) {
        const l = lv.int_val;
        const r = rv.int_val;
        return switch (op) {
            .add => .{ .int_val = l + r },
            .sub => .{ .int_val = l - r },
            .mul => .{ .int_val = l * r },
            .div => if (r != 0) .{ .int_val = @divTrunc(l, r) } else null,
            .mod => if (r != 0) .{ .int_val = @rem(l, r) } else null,
            .bit_and => .{ .int_val = l & r },
            .bit_or => .{ .int_val = l | r },
            .bit_xor => .{ .int_val = l ^ r },
            .shl => .{ .int_val = if (r < @bitSizeOf(@TypeOf(l))) l << @intCast(r) else 0 },
            .shr => .{ .int_val = l >> @intCast(@min(r, @bitSizeOf(@TypeOf(l)) - 1)) },
            .eq => .{ .bool_val = l == r },
            .not_eq => .{ .bool_val = l != r },
            .lt => .{ .bool_val = l < r },
            .gt => .{ .bool_val = l > r },
            .lt_eq => .{ .bool_val = l <= r },
            .gt_eq => .{ .bool_val = l >= r },
            else => null,
        };
    }
    if (lv == .float_val and rv == .float_val) {
        const l = lv.float_val;
        const r = rv.float_val;
        return switch (op) {
            .add => .{ .float_val = l + r },
            .sub => .{ .float_val = l - r },
            .mul => .{ .float_val = l * r },
            .div => if (r != 0.0) .{ .float_val = l / r } else null,
            .eq => .{ .bool_val = l == r },
            .not_eq => .{ .bool_val = l != r },
            .lt => .{ .bool_val = l < r },
            .gt => .{ .bool_val = l > r },
            .lt_eq => .{ .bool_val = l <= r },
            .gt_eq => .{ .bool_val = l >= r },
            else => null,
        };
    }
    if (lv == .bool_val and rv == .bool_val) {
        return switch (op) {
            .and_op => .{ .bool_val = lv.bool_val and rv.bool_val },
            .or_op => .{ .bool_val = lv.bool_val or rv.bool_val },
            .eq => .{ .bool_val = lv.bool_val == rv.bool_val },
            .not_eq => .{ .bool_val = lv.bool_val != rv.bool_val },
            else => null,
        };
    }
    return null;
}

/// 对常量执行一元运算并返回折叠结果；运算不适用时返回 null。
fn evalUnary(op: ast.UnaryOp, v: ConstValue) ?ConstValue {
    return switch (v) {
        .int_val => |i| switch (op) {
            .neg => .{ .int_val = -i },
            else => null,
        },
        .float_val => |f| switch (op) {
            .neg => .{ .float_val = -f },
            else => null,
        },
        .bool_val => |b| switch (op) {
            .not => .{ .bool_val = !b },
            else => null,
        },
        .unknown => null,
    };
}

/// 解析整型字面量字符串，支持十进制、十六进制（0x）、八进制（0o）、二进制（0b）以及下划线分隔。
fn parseIntLiteral(allocator: std.mem.Allocator, raw: []const u8) ?ConstValue {
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (raw) |c| {
        if (c != '_') clean.append(allocator, c) catch return null;
    }
    const bytes = clean.items;
    if (bytes.len == 0) return null;
    if (bytes.len >= 2 and bytes[0] == '0') {
        if (bytes[1] == 'x' or bytes[1] == 'X') {
            const val = std.fmt.parseInt(i128, bytes[2..], 16) catch return null;
            return .{ .int_val = val };
        }
        if (bytes[1] == 'o' or bytes[1] == 'O') {
            const val = std.fmt.parseInt(i128, bytes[2..], 8) catch return null;
            return .{ .int_val = val };
        }
        if (bytes[1] == 'b' or bytes[1] == 'B') {
            const val = std.fmt.parseInt(i128, bytes[2..], 2) catch return null;
            return .{ .int_val = val };
        }
    }
    const val = std.fmt.parseInt(i128, bytes, 10) catch return null;
    return .{ .int_val = val };
}
