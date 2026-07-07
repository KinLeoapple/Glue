//! 融合静态分析 pass：单次 AST 遍历同时填充 const_prop / loop_invariant / purity。
//!
//! 原实现中 3 个 pass（const_prop / branch_reach / loop_invariant）各自独立遍历
//! 所有 fun_decl 体，总计 3 次完整遍历。purity pass 还额外多轮递归 AST。
//!
//! 融合策略：
//! 1. 单次遍历每个函数体，同时收集：
//!    - 常量绑定 → db.const_prop
//!    - 循环大小 → db.loop_invariant
//!    - 调用边（按函数名）→ 临时 name_call_graph
//!    - 直接 impure 标记（调用 impure builtin / 方法调用 / spawn / select 等）→ direct_impure 集合
//! 2. 单次遍历后，用 name_call_graph + direct_impure 做 purity fixpoint（O(N+E)，不再递归 AST）
//! 3. branch_reach 依赖 const_prop 完成，保持独立轻量遍历（仅查 if 条件）
//!
//! 语义不变：所有 pass 的判定逻辑与原实现完全一致，仅合并遍历顺序。

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

const UNROLL_THRESHOLD: u32 = 32;

/// 融合分析器：单次遍历填充 const_prop / loop_invariant / hoist_table，并收集调用图用于 purity fixpoint。
pub const FusedAnalysis = struct {
    /// 借用：写入 db.const_prop
    const_table: *const_prop_mod.ConstTable,
    /// 借用：写入 db.loop_invariant
    loop_table: *loop_invariant_mod.LoopTable,
    /// 借用：写入 db.purity
    purity_table: *purity_mod.PurityTable,
    /// 借用：写入 db.hoist_table（LICM 不变量提升表）
    hoist_table: *loop_invariant_mod.HoistTable,
    /// 借用：写入 db.dead_code（DCE 死代码表）
    dead_table: *DeadTable,
    /// 借用：写入 db.cse（CSE 公共子表达式表）
    cse_table: *CseTable,
    allocator: std.mem.Allocator,

    /// 临时：函数名 → 它直接调用的函数名列表（仅顶层 fun_decl 之间的边）
    name_call_graph: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    /// 临时：直接 impure 的函数名集合（调用 impure builtin / 方法调用 / spawn 等）
    direct_impure: std.StringHashMap(void),
    /// 临时：所有 fun_decl 名字集合（用于 fixpoint 初始化）
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

    /// 分析模块：单次遍历 + purity fixpoint
    pub fn analyzeModule(self: *FusedAnalysis, module: *const ast.Module) !void {
        // Pass 1: 收集所有 fun_decl 名字，初始化 purity 表为 pure
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const name = decl.fun_decl.name;
            try self.all_fn_names.append(self.allocator, name);
            try self.purity_table.put(name, .pure);
        }

        // Pass 2: 单次遍历每个函数体，填充 const_prop / loop_invariant / name_call_graph / direct_impure
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const fd = decl.fun_decl;
            var env = ConstEnv.init(self.allocator, null);
            defer env.deinit();
            try self.analyzeExpr(fd.body, &env, fd.name);
        }

        // Pass 3: purity fixpoint（基于 name_call_graph，O(N+E)，不再递归 AST）
        try self.purityFixpoint();

        // Pass 4: DCE（迭代到 fixpoint，标记未引用且无副作用的 val_decl/var_decl 为 dead）
        var dce_pass = DeadCodePass.init(self.allocator, self.dead_table);
        try dce_pass.analyzeModule(module);

        // Pass 5: CSE（基本块级公共子表达式消除，标记 redundant → canonical）
        var cse_pass = CsePass.init(self.allocator, self.cse_table);
        try cse_pass.analyzeModule(module);
    }

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

                // 调用图边收集 + impure 判定
                if (c.callee.* == .identifier) {
                    const callee_name = c.callee.identifier.name;
                    // 自递归不算 impure（已在当前函数判定中）
                    if (!std.mem.eql(u8, callee_name, current_fn)) {
                        if (isImpureBuiltin(callee_name)) {
                            try self.direct_impure.put(current_fn, {});
                        } else {
                            // 记录调用边（callee 可能是顶层 fun_decl）
                            const gop = try self.name_call_graph.getOrPut(current_fn);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            // 去重
                            for (gop.value_ptr.items) |existing| {
                                if (std.mem.eql(u8, existing, callee_name)) return;
                            }
                            try gop.value_ptr.append(self.allocator, callee_name);
                        }
                    }
                } else {
                    // 间接调用（callee 非标识符）→ 保守 impure
                    try self.direct_impure.put(current_fn, {});
                }
            },
            .method_call => {
                // 方法调用保守视为 impure（与原 purity.exprHasImpureCall 一致）
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

    fn analyzeStmt(
        self: *FusedAnalysis,
        stmt: *const ast.Stmt,
        env: *ConstEnv,
        current_fn: []const u8,
    ) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                try self.analyzeExpr(v.value, env, current_fn);
                if (self.const_table.lookup(v.value)) |val| {
                    if (val != .unknown) {
                        try env.put(v.name, val);
                    }
                }
            },
            .var_decl => |v| {
                try self.analyzeExpr(v.value, env, current_fn);
                // var 绑定不加入常量 env（可变）
            },
            .assignment => |a| {
                try self.analyzeExpr(a.value, env, current_fn);
                // 赋值后该变量不再常量
                if (a.target.* == .identifier) {
                    _ = env.remove(a.target.identifier.name);
                }
            },
            .expression => |e| try self.analyzeExpr(e.expr, env, current_fn),
            .return_stmt => |r| if (r.value) |v| try self.analyzeExpr(v, env, current_fn),
            .for_stmt => |f| {
                try self.analyzeExpr(f.iterable, env, current_fn);
                // 循环大小估计（融合自 loop_invariant）
                const size = self.estimateSize(f.body);
                try self.loop_table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                // 【LICM】收集循环体内可 hoist 的不变量子表达式
                // for 循环变量每轮被赋值，算作 assigned
                const for_assigned = [_][]const u8{f.name};
                try loop_invariant_mod.collectHoistsInExpr(
                    self.allocator,
                    self.hoist_table,
                    f.body,
                    stmt,
                    &for_assigned,
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
                // 【LICM】while 无循环变量，assigned_vars 仅含循环体内 assignment target
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
                // 【LICM】loop 同 while——无循环变量
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

    /// 基于调用图的 purity fixpoint（O(N+E)）。
    /// 初始：direct_impure 集合中的函数标 impure；然后反向传播——
    /// 任何调用 impure 函数的函数也变 impure，直到收敛。
    fn purityFixpoint(self: *FusedAnalysis) !void {
        // 工作队列：初始为所有 direct_impure 函数
        var worklist = std.ArrayList([]const u8).empty;
        defer worklist.deinit(self.allocator);
        var it = self.direct_impure.keyIterator();
        while (it.next()) |k| {
            try worklist.append(self.allocator, k.*);
        }

        // 标记 direct_impure 为 impure
        for (worklist.items) |name| {
            try self.purity_table.put(name, .impure);
        }

        // 反向传播：worklist 中的函数是 impure 的，所有调用它的函数也变 impure。
        // 用逆邻接表：callee → [callers]
        // 构建 caller 表后，每次取出 impure 函数，把它的 callers 也加入 impure。
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

        // 处理 worklist
        while (worklist.items.len > 0) {
            const impure_fn = worklist.pop().?;
            // 找到所有调用 impure_fn 的函数
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

    /// 估计表达式的字节码指令数（镜像 loop_invariant.LoopInvariantPass.estimateSize）
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

/// 已知的 impure 内建函数名（镜像 purity.zig）
const impure_builtins = [_][]const u8{
    "println", "print", "eprintln", "eprint",
    "spawn",   "lazy",  "select",   "send",   "recv",
};

fn isImpureBuiltin(name: []const u8) bool {
    for (impure_builtins) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

// 以下函数镜像 const_prop.zig 的实现，保持语义一致
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
