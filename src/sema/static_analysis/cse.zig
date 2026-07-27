//! 公共子表达式消除（CSE）模块。
//!
//! 定义 CSE 结果表（CseTable）与分析遍（CsePass）。遍历函数体时记录已出现的
//! 可消除表达式，当后续遇到结构相同的表达式时，将其标记为冗余并指向首次出现
//! 的规范表达式。赋值和循环等可能改变可见值的构造会触发失效，清空已记录集合。

const std = @import("std");
const ast = @import("ast");
const ast_visitor = @import("ast_visitor");

/// CSE 结果表。redundant_map 将冗余表达式映射到其规范（首次出现）表达式，
/// canonical_set 记录所有作为规范的表达式。
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

    /// 返回给定表达式的规范表达式；若表达式非冗余则返回 null。
    pub fn canonicalOf(self: *const CseTable, expr: *const ast.Expr) ?*const ast.Expr {
        return self.redundant_map.get(expr);
    }

    /// 判断给定表达式是否为某个 CSE 组的规范表达式。
    pub fn isCanonical(self: *const CseTable, expr: *const ast.Expr) bool {
        return self.canonical_set.contains(expr);
    }

    /// 结果表是否为空（无冗余表达式）。
    pub fn isEmpty(self: *const CseTable) bool {
        return self.redundant_map.count() == 0;
    }
};

/// 已见表达式条目，用于在遍历过程中追踪已出现的可消除表达式。
const SeenEntry = struct {
    expr: *const ast.Expr,
};

/// CSE 分析遍。逐函数遍历 AST，在函数体内识别结构相同的冗余表达式。
/// v3 阶段 11：使用 ast_visitor.walkExprChildren/walkStmtChildren 消除手写递归分支，
/// 仅保留作用域隔离（if_expr/match/loops）和失效逻辑（assignment）的特化 hook。
pub const CsePass = struct {
    table: *CseTable,
    allocator: std.mem.Allocator,
    /// 当前已见表达式列表指针（visitor 回调通过此字段访问 seen）
    current_seen: *std.ArrayListUnmanaged(SeenEntry) = undefined,

    pub fn init(allocator: std.mem.Allocator, table: *CseTable) CsePass {
        return .{
            .table = table,
            .allocator = allocator,
        };
    }

    pub fn analyzeModule(self: *CsePass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeFunction(decl.fun_decl.body);
        }
    }

    fn analyzeFunction(self: *CsePass, body: *const ast.Expr) !void {
        var seen = std.ArrayListUnmanaged(SeenEntry).empty;
        defer seen.deinit(self.allocator);
        self.current_seen = &seen;
        try self.processExprV(body);
    }

    /// processExpr 的 visitor 实现：特化 hook + 默认 walkExprChildren 递归。
    fn processExprV(self: *CsePass, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .binary => |b| {
                try self.processExprV(b.left);
                try self.processExprV(b.right);
                if (isCseEligibleBinary(expr)) {
                    // 与已见表达式逐一比较；若结构相同则标记为冗余。
                    for (self.current_seen.items) |entry| {
                        if (exprEqual(entry.expr, expr)) {
                            try self.table.redundant_map.put(expr, entry.expr);
                            try self.table.canonical_set.put(entry.expr, {});
                            return;
                        }
                    }
                    try self.current_seen.append(self.allocator, .{ .expr = expr });
                }
            },
            .if_expr => |i| {
                // then / else 分支各自独立作用域，处理后清空已见集合。
                try self.processExprV(i.condition);
                var then_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer then_seen.deinit(self.allocator);
                const saved = self.current_seen;
                self.current_seen = &then_seen;
                try self.processExprV(i.then_branch);
                if (i.else_branch) |e| {
                    var else_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer else_seen.deinit(self.allocator);
                    self.current_seen = &else_seen;
                    try self.processExprV(e);
                }
                self.current_seen = saved;
                self.current_seen.clearRetainingCapacity();
            },
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.processStmtV(stmt);
                    // 循环语句可能改变变量值，清空已见集合以保证安全。
                    switch (stmt.*) {
                        .while_stmt, .for_stmt, .loop_stmt => {
                            self.current_seen.clearRetainingCapacity();
                        },
                        else => {},
                    }
                }
                if (b.trailing_expr) |te| try self.processExprV(te);
            },
            .match => |m| {
                // 每个 arm 独立作用域。
                try self.processExprV(m.scrutinee);
                const saved = self.current_seen;
                for (m.arms) |arm| {
                    var arm_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer arm_seen.deinit(self.allocator);
                    self.current_seen = &arm_seen;
                    if (arm.guard) |g| try self.processExprV(g);
                    try self.processExprV(arm.body);
                }
                self.current_seen = saved;
                self.current_seen.clearRetainingCapacity();
            },
            .assignment_expr => |a| {
                try self.processExprV(a.value);
                // 对标识符赋值时仅需失效读取该变量的已见表达式；
                // 对复杂目标赋值则保守清空全部已见集合。
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name);
                } else {
                    try self.processExprV(a.target);
                    self.current_seen.clearRetainingCapacity();
                }
            },
            .compound_assign => |c| {
                try self.processExprV(c.value);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name);
                } else {
                    self.current_seen.clearRetainingCapacity();
                }
            },
            // lambda/select/inline_trait_value 不递归（作用域隔离或无 CSE 候选）
            .lambda, .select, .inline_trait_value => {},
            // 默认：walkExprChildren 递归
            else => {
                try ast_visitor.walkExprChildren(@ptrCast(self), expr, processExprCb);
            },
        }
    }

    /// walkExprChildren 回调适配器
    fn processExprCb(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
        const self: *CsePass = @ptrCast(@alignCast(ctx));
        try self.processExprV(expr);
    }

    /// processStmt 的 visitor 实现：特化 hook + 默认 walkStmtChildren 递归。
    fn processStmtV(self: *CsePass, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .assignment => |a| {
                try self.processExprV(a.value);
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name);
                } else {
                    self.current_seen.clearRetainingCapacity();
                }
            },
            .field_assignment => |f| {
                try self.processExprV(f.object);
                try self.processExprV(f.value);
                self.current_seen.clearRetainingCapacity();
            },
            .compound_assignment => |c| {
                try self.processExprV(c.value);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name);
                } else {
                    self.current_seen.clearRetainingCapacity();
                }
            },
            .while_stmt => |w| {
                // 循环体独立作用域，处理完条件后用独立的 seen 集合分析循环体。
                try self.processExprV(w.condition);
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                const saved = self.current_seen;
                self.current_seen = &body_seen;
                try self.processExprV(w.body);
                self.current_seen = saved;
                self.current_seen.clearRetainingCapacity();
            },
            .for_stmt => |f| {
                try self.processExprV(f.iterable);
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                const saved = self.current_seen;
                self.current_seen = &body_seen;
                try self.processExprV(f.body);
                self.current_seen = saved;
                self.current_seen.clearRetainingCapacity();
            },
            .loop_stmt => |l| {
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                const saved = self.current_seen;
                self.current_seen = &body_seen;
                try self.processExprV(l.body);
                self.current_seen = saved;
                self.current_seen.clearRetainingCapacity();
            },
            // 默认：walkStmtChildren 递归（val_decl/var_decl/expression/return_stmt/defer_stmt/throw_stmt/break/continue）
            else => {
                try ast_visitor.walkStmtChildren(@ptrCast(self), stmt, processExprCb);
            },
        }
    }

    /// 失效所有读取指定变量的已见表达式，因为该变量已被重新赋值。
    fn invalidate(self: *CsePass, name: []const u8) void {
        var i: usize = 0;
        while (i < self.current_seen.items.len) {
            if (exprReadsVar(self.current_seen.items[i].expr, name)) {
                _ = self.current_seen.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// 两个表达式的结构相等性判断。比较时忽略位置信息，仅比较语义内容。
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
        .ref_of => |ar| exprEqual(ar.operand, b.ref_of.operand),
        .deref => |ad| exprEqual(ad.operand, b.deref.operand),
        else => a == b,
    };
}

/// 判断表达式是否读取了指定名称的变量。
fn exprReadsVar(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |id| std.mem.eql(u8, id.name, name),
        .binary => |b| exprReadsVar(b.left, name) or exprReadsVar(b.right, name),
        .unary => |u| exprReadsVar(u.operand, name),
        .ref_of => |r| exprReadsVar(r.operand, name),
        .deref => |d| exprReadsVar(d.operand, name),
        else => false,
    };
}

/// 判断二元表达式是否适合 CSE。仅纯算术 / 比较 / 位运算且操作数满足条件的表达式可消除。
fn isCseEligibleBinary(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .binary => |b| switch (b.op) {
            .add, .sub, .mul, .div, .mod,
            .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
            .bit_and, .bit_or, .bit_xor, .shl, .shr,
            => return isCseEligibleOperand(b.left) and isCseEligibleOperand(b.right),
            else => return false,
        },
        else => return false,
    }
}

/// 判断操作数是否适合 CSE：字面量、标识符或递归满足条件的二元 / 一元表达式。
fn isCseEligibleOperand(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .identifier,
        => true,
        .binary => isCseEligibleBinary(expr),
        .unary => |u| (u.op == .neg or u.op == .not) and isCseEligibleOperand(u.operand),
        // 取引用/解引用涉及地址语义，不作为 CSE 候选
        .ref_of, .deref => false,
        else => false,
    };
}

test "CseTable basic" {
    var table = CseTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    try std.testing.expect(table.canonicalOf(@constCast(&ast.Expr{ .int_literal = .{ .raw = "1", .suffix = null } })) == null);
}

test "exprEqual literals" {
    const a = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    const b = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    try std.testing.expect(exprEqual(&a, &b));
    const c = ast.Expr{ .int_literal = .{ .raw = "43", .suffix = null } };
    try std.testing.expect(!exprEqual(&a, &c));
}

test "exprReadsVar" {
    const expr = ast.Expr{ .identifier = .{ .name = "x" } };
    try std.testing.expect(exprReadsVar(&expr, "x"));
    try std.testing.expect(!exprReadsVar(&expr, "y"));
}
