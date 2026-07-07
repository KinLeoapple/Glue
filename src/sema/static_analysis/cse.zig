//! Pass：公共子表达式消除（CSE）。
//!
//! 借鉴 LLVM CSE：在同一基本块内识别重复计算的纯 binary 表达式，
//! 将后续出现标记为 redundant（指向首次出现的 canonical）。
//! 编译器在 emitExpr 的 .binary 分支查询：
//!   - redundant：读 canonical 的缓存 slot（op_get_local）替代重算
//!   - canonical：正常 emit 后缓存结果到 slot（op_set_local）供后续 redundant 读取
//!
//! 算法（基本块级 CSE，保守正确）：
//!   1. 按源序遍历 block 内语句，维护 seen 列表（已见的 CSE-eligible binary）
//!   2. 遇到 CSE-eligible binary 时，与 seen 逐一做结构相等比较
//!      - 命中：标记当前为 redundant → seen 中的为 canonical
//!      - 未命中：加入 seen
//!   3. 遇 assignment 到变量 v：从 seen 移除所有读取 v 的项（缓存失效）
//!   4. 遇控制流语句（if/while/for/loop）：清空 seen（合并点保守失效）
//!   5. 嵌套 block/if 分支体：使用独立 fresh seen（新作用域，不继承父级）
//!
//! 限制：
//! - 仅分析 pure binary（算术/比较/位运算，非 and/or/elvis/concat/range）
//! - 仅在同一 block 内有效（canonical 与 redundant 间无控制流分隔）
//! - 不跨函数、不跨 block
//! - 嵌套 if/match/while/for 体作为新作用域，不继承父级 seen

const std = @import("std");
const ast = @import("ast");

/// CSE 表：
/// - redundant_map: redundant expr → canonical expr（首次出现）
/// - canonical_set: canonical expr 集合（编译器据此决定是否缓存结果）
pub const CseTable = struct {
    redundant_map: std.AutoHashMap(*const ast.Expr, *const ast.Expr),
    canonical_set: std.AutoHashMap(*const ast.Expr, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CseTable {
        return .{
            .redundant_map = std.AutoHashMap(*const ast.Expr, *const ast.Expr).init(allocator),
            .canonical_set = std.AutoHashMap(*const ast.Expr, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CseTable) void {
        self.redundant_map.deinit();
        self.canonical_set.deinit();
    }

    /// 查询 expr 是否是 redundant（有对应的 canonical）。返回 canonical expr。
    pub fn canonicalOf(self: *const CseTable, expr: *const ast.Expr) ?*const ast.Expr {
        return self.redundant_map.get(expr);
    }

    /// 查询 expr 是否是 canonical（有 redundant 指向它）。
    pub fn isCanonical(self: *const CseTable, expr: *const ast.Expr) bool {
        return self.canonical_set.contains(expr);
    }

    pub fn isEmpty(self: *const CseTable) bool {
        return self.redundant_map.count() == 0;
    }
};

/// seen 列表项：已见的 CSE-eligible binary 表达式
const SeenEntry = struct {
    expr: *const ast.Expr,
};

/// CSE pass（借用 CseTable，由 AnalysisDB 持有）
pub const CsePass = struct {
    table: *CseTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: *CseTable) CsePass {
        return .{
            .table = table,
            .allocator = allocator,
        };
    }

    /// 分析模块：对每个 fun_decl 体跑 CSE
    pub fn analyzeModule(self: *CsePass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeFunction(decl.fun_decl.body);
        }
    }

    fn analyzeFunction(self: *CsePass, body: *const ast.Expr) !void {
        var seen = std.ArrayListUnmanaged(SeenEntry).empty;
        defer seen.deinit(self.allocator);
        try self.processExpr(body, &seen);
    }

    /// 处理表达式：递归子表达式，对 CSE-eligible binary 查 seen 匹配或登记。
    fn processExpr(self: *CsePass, expr: *const ast.Expr, seen: *std.ArrayListUnmanaged(SeenEntry)) anyerror!void {
        switch (expr.*) {
            .binary => |b| {
                // 先递归子表达式（后序：子树先处理）
                try self.processExpr(b.left, seen);
                try self.processExpr(b.right, seen);
                // 当前 binary 是否 CSE-eligible
                if (isCseEligibleBinary(expr)) {
                    // 与 seen 逐一结构比较
                    for (seen.items) |entry| {
                        if (exprEqual(entry.expr, expr)) {
                            // 命中：标记 redundant → canonical
                            try self.table.redundant_map.put(expr, entry.expr);
                            try self.table.canonical_set.put(entry.expr, {});
                            return;
                        }
                    }
                    // 未命中：加入 seen
                    try seen.append(self.allocator, .{ .expr = expr });
                }
            },
            .unary => |u| try self.processExpr(u.operand, seen),
            .if_expr => |i| {
                // 条件在当前作用域
                try self.processExpr(i.condition, seen);
                // then/else 分支体：新作用域（fresh seen）
                var then_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer then_seen.deinit(self.allocator);
                try self.processExpr(i.then_branch, &then_seen);
                if (i.else_branch) |e| {
                    var else_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer else_seen.deinit(self.allocator);
                    try self.processExpr(e, &else_seen);
                }
                // if 后：清空 seen（合并点保守失效）
                seen.clearRetainingCapacity();
            },
            .block => |b| {
                // block 内语句按源序处理，共享 seen
                for (b.statements) |stmt| {
                    try self.processStmt(stmt, seen);
                    // 控制流语句后清空 seen（保守）
                    switch (stmt.*) {
                        .while_stmt, .for_stmt, .loop_stmt => {
                            seen.clearRetainingCapacity();
                        },
                        else => {},
                    }
                }
                if (b.trailing_expr) |te| try self.processExpr(te, seen);
            },
            .call => |c| {
                try self.processExpr(c.callee, seen);
                for (c.arguments) |a| try self.processExpr(a, seen);
            },
            .method_call => |mc| {
                try self.processExpr(mc.object, seen);
                for (mc.arguments) |a| try self.processExpr(a, seen);
            },
            .safe_method_call => |mc| {
                try self.processExpr(mc.object, seen);
                for (mc.arguments) |a| try self.processExpr(a, seen);
            },
            .match => |m| {
                try self.processExpr(m.scrutinee, seen);
                // 每个 arm 体：新作用域
                for (m.arms) |arm| {
                    var arm_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer arm_seen.deinit(self.allocator);
                    if (arm.guard) |g| try self.processExpr(g, &arm_seen);
                    try self.processExpr(arm.body, &arm_seen);
                }
                // match 后：清空 seen
                seen.clearRetainingCapacity();
            },
            .type_cast => |tc| try self.processExpr(tc.expr, seen),
            .spawn => |sp| {
                // spawn 体：新作用域
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(sp.body, &body_seen);
            },
            .atomic_expr => |ae| try self.processExpr(ae.value, seen),
            .lazy => |l| try self.processExpr(l.expr, seen),
            .field_access => |f| try self.processExpr(f.object, seen),
            .safe_access => |f| try self.processExpr(f.object, seen),
            .index => |i| {
                try self.processExpr(i.object, seen);
                try self.processExpr(i.index, seen);
            },
            .non_null_assert => |n| try self.processExpr(n.expr, seen),
            .propagate => |p| try self.processExpr(p.expr, seen),
            .array_literal => |a| {
                for (a.elements) |e| try self.processExpr(e, seen);
            },
            .record_literal => |r| {
                for (r.fields) |f| try self.processExpr(f.value, seen);
            },
            .record_extend => |r| {
                try self.processExpr(r.base, seen);
                for (r.updates) |u| try self.processExpr(u.value, seen);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) try self.processExpr(part.expression, seen);
                }
            },
            .assignment_expr => |a| {
                try self.processExpr(a.value, seen);
                // 赋值失效 seen 中读取该变量的项
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name, seen);
                } else {
                    // 复杂赋值目标（字段/索引）：保守清空 seen
                    try self.processExpr(a.target, seen);
                    seen.clearRetainingCapacity();
                }
            },
            .compound_assign => |c| {
                try self.processExpr(c.value, seen);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name, seen);
                } else {
                    seen.clearRetainingCapacity();
                }
            },
            .lambda => {},
            .select => {},
            .inline_trait_value => {},
            else => {},
        }
    }

    /// 处理语句：提取表达式并处理，处理赋值失效。
    fn processStmt(self: *CsePass, stmt: *const ast.Stmt, seen: *std.ArrayListUnmanaged(SeenEntry)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| try self.processExpr(v.value, seen),
            .var_decl => |v| try self.processExpr(v.value, seen),
            .assignment => |a| {
                try self.processExpr(a.value, seen);
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name, seen);
                } else {
                    // 字段/索引赋值：保守清空
                    seen.clearRetainingCapacity();
                }
            },
            .field_assignment => |f| {
                try self.processExpr(f.object, seen);
                try self.processExpr(f.value, seen);
                // 字段赋值可能间接修改变量：保守清空
                seen.clearRetainingCapacity();
            },
            .compound_assignment => |c| {
                try self.processExpr(c.value, seen);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name, seen);
                } else {
                    seen.clearRetainingCapacity();
                }
            },
            .expression => |e| try self.processExpr(e.expr, seen),
            .return_stmt => |r| if (r.value) |v| try self.processExpr(v, seen),
            .while_stmt => |w| {
                try self.processExpr(w.condition, seen);
                // 循环体：新作用域
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(w.body, &body_seen);
                // while 后：清空 seen
                seen.clearRetainingCapacity();
            },
            .for_stmt => |f| {
                try self.processExpr(f.iterable, seen);
                // 循环体：新作用域
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(f.body, &body_seen);
                // for 后：清空 seen
                seen.clearRetainingCapacity();
            },
            .loop_stmt => |l| {
                // 循环体：新作用域
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(l.body, &body_seen);
                // loop 后：清空 seen
                seen.clearRetainingCapacity();
            },
            .defer_stmt => |d| try self.processExpr(d.expr, seen),
            .throw_stmt => |t| try self.processExpr(t.expr, seen),
            .break_stmt, .continue_stmt => {},
        }
    }

    /// 从 seen 中移除所有读取变量 name 的项。
    fn invalidate(self: *CsePass, name: []const u8, seen: *std.ArrayListUnmanaged(SeenEntry)) void {
        _ = self;
        var i: usize = 0;
        while (i < seen.items.len) {
            if (exprReadsVar(seen.items[i].expr, name)) {
                _ = seen.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ============================================================
// 结构相等判定
// ============================================================

/// 两个表达式是否结构相等（递归比较 AST 节点）。
fn exprEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (@intFromEnum(a.*) != @intFromEnum(b.*)) return false;
    return switch (a.*) {
        .int_literal => |ai| std.mem.eql(u8, ai.raw, b.int_literal.raw),
        .float_literal => |af| std.mem.eql(u8, af.raw, b.float_literal.raw),
        .bool_literal => |ab| ab.value == b.bool_literal.value,
        .char_literal => |ac| ac.value == b.char_literal.value,
        .string_literal => |as| std.mem.eql(u8, as.value, b.string_literal.value),
        .null_literal, .unit_literal => true,
        .identifier => |ai| std.mem.eql(u8, ai.name, b.identifier.name),
        .binary => |ab| ab.op == b.binary.op and exprEqual(ab.left, b.binary.left) and exprEqual(ab.right, b.binary.right),
        .unary => |au| au.op == b.unary.op and exprEqual(au.operand, b.unary.operand),
        else => a == b, // 其他类型用指针相等（不参与 CSE 匹配）
    };
}

/// 表达式是否读取变量 name（递归检查子表达式）。
fn exprReadsVar(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |id| std.mem.eql(u8, id.name, name),
        .binary => |b| exprReadsVar(b.left, name) or exprReadsVar(b.right, name),
        .unary => |u| exprReadsVar(u.operand, name),
        else => false,
    };
}

// ============================================================
// CSE 资格判定
// ============================================================

/// binary 是否 CSE-eligible：op 是纯算术/比较/位运算，且操作数均 eligible。
fn isCseEligibleBinary(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .binary => |b| switch (b.op) {
            .add, .sub, .mul, .div, .mod,
            .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
            .bit_and, .bit_or, .bit_xor,
            => return isCseEligibleOperand(b.left) and isCseEligibleOperand(b.right),
            // and/or/elvis 短路语义不适合 CSE（可能不计算右操作数）
            // concat/concat_list/range/range_inclusive 可能分配，不 CSE
            else => return false,
        },
        else => return false,
    }
}

/// 操作数是否 CSE-eligible：字面量/identifier/pure binary/pure unary。
fn isCseEligibleOperand(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .identifier,
        => true,
        .binary => isCseEligibleBinary(expr),
        .unary => |u| (u.op == .neg or u.op == .not) and isCseEligibleOperand(u.operand),
        else => false,
    };
}

test "CseTable basic" {
    var table = CseTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    try std.testing.expect(table.canonicalOf(@constCast(&ast.Expr{ .int_literal = .{ .raw = "1", .suffix = null, .location = .{ .line = 1, .column = 1 } } })) == null);
}

test "exprEqual literals" {
    const a = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null, .location = .{ .line = 1, .column = 1 } } };
    const b = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null, .location = .{ .line = 2, .column = 3 } } };
    try std.testing.expect(exprEqual(&a, &b));
    const c = ast.Expr{ .int_literal = .{ .raw = "43", .suffix = null, .location = .{ .line = 1, .column = 1 } } };
    try std.testing.expect(!exprEqual(&a, &c));
}

test "exprReadsVar" {
    const expr = ast.Expr{ .identifier = .{ .name = "x", .location = .{ .line = 1, .column = 1 } } };
    try std.testing.expect(exprReadsVar(&expr, "x"));
    try std.testing.expect(!exprReadsVar(&expr, "y"));
}
