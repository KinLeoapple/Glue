//! AST 遍历框架（v3 阶段 11：vtable + walkExpr/walkStmt）
//!
//! 设计目标（对齐 spec §5.5）：
//! - vtable 结构体 `AstVisitor`（ctx + visit_expr/visit_stmt 可选回调），
//!   替代裸函数指针 callback，便于扩展 per-variant hook。
//! - `walkExpr`/`walkStmt` 遍历**含当前节点**（后序：先递归子节点，再回调当前），
//!   补齐 `walkExprChildren`/`walkStmtChildren` 只遍历子节点的缺口。
//! - 文件位置：`sema/ast_visitor.zig`（spec 要求，从 static_analysis/ 提升）。
//!
//! 向后兼容：保留 `walkExprChildren`/`walkStmtChildren`（callback 签名不变），
//! 6 个 static_analysis pass 无需改动即可继续工作；新代码可使用 vtable API。
//!
//! 新增 AST 变体：仅需在 `walkExprChildren`/`walkStmtChildren` 补一行子节点遍历。

const std = @import("std");
const ast = @import("ast");

// ════════════════════════════════════════════════════════════
// vtable：AstVisitor 结构体（spec §5.5 设计）
// ════════════════════════════════════════════════════════════

/// AST 访问者 vtable。
///
/// 使用方式：
/// ```zig
/// const v = AstVisitor{
///     .ctx = @ptrCast(self),
///     .visit_expr = myVisitExpr,
///     .visit_stmt = null,
/// };
/// try walkExpr(&v, expr);
/// ```
///
/// `visit_expr`/`visit_stmt` 在后序遍历中被调用（先递归子节点，再回调当前节点）。
/// 回调内部无需手动递归——`walkExpr`/`walkStmt` 自动处理子节点遍历。
pub const AstVisitor = struct {
    ctx: *anyopaque,
    visit_expr: ?*const fn (ctx: *anyopaque, expr: *const ast.Expr) anyerror!void = null,
    visit_stmt: ?*const fn (ctx: *anyopaque, stmt: *const ast.Stmt) anyerror!void = null,
};

// ════════════════════════════════════════════════════════════
// walkExpr / walkStmt（含当前节点，后序遍历）
// ════════════════════════════════════════════════════════════

/// 遍历表达式（含当前节点），后序：先递归子节点，再回调当前。
///
/// 若 `v.visit_expr` 非 null，对当前 `expr` 调用之；
/// 然后递归遍历所有子表达式（通过 `walkExprChildrenV`）。
pub fn walkExpr(v: *const AstVisitor, expr: *const ast.Expr) anyerror!void {
    try walkExprChildrenV(v, expr);
    if (v.visit_expr) |fn_| try fn_(v.ctx, expr);
}

/// 遍历语句（含当前节点），后序：先递归子节点，再回调当前。
pub fn walkStmt(v: *const AstVisitor, stmt: *const ast.Stmt) anyerror!void {
    try walkStmtChildrenV(v, stmt);
    if (v.visit_stmt) |fn_| try fn_(v.ctx, stmt);
}

// ════════════════════════════════════════════════════════════
// walkExprChildren / walkStmtChildren（vtable 版，仅子节点）
// ════════════════════════════════════════════════════════════

/// 遍历表达式的所有子表达式（不含 expr 自身），对每个子节点递归 walkExpr。
fn walkExprChildrenV(v: *const AstVisitor, expr: *const ast.Expr) anyerror!void {
    switch (expr.*) {
        // 叶子节点：无子表达式
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal,
        .identifier,
        => {},

        // string_interpolation：遍历 parts 中的表达式
        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expression) try walkExpr(v, part.expression);
            }
        },

        // 单子节点
        .unary => |u| try walkExpr(v, u.operand),
        .ref_of => |r| try walkExpr(v, r.operand),
        .deref => |d| try walkExpr(v, d.operand),
        .non_null_assert => |n| try walkExpr(v, n.expr),
        .propagate => |p| try walkExpr(v, p.expr),
        .field_access => |f| try walkExpr(v, f.object),
        .safe_access => |s| try walkExpr(v, s.object),
        .type_cast => |tc| try walkExpr(v, tc.expr),
        .cast_builder => |cb| try walkExpr(v, cb.expr),
        .atomic_expr => |ae| try walkExpr(v, ae.value),
        .lazy => |l| try walkExpr(v, l.expr),
        .spawn_expr => |se| try walkExpr(v, se.expr),

        // 双子节点
        .assignment_expr => |a| {
            try walkExpr(v, a.target);
            try walkExpr(v, a.value);
        },
        .compound_assign => |c| {
            try walkExpr(v, c.target);
            try walkExpr(v, c.value);
        },
        .binary => |b| {
            try walkExpr(v, b.left);
            try walkExpr(v, b.right);
        },
        .index => |i| {
            try walkExpr(v, i.object);
            try walkExpr(v, i.index);
        },
        .slice => |s| {
            try walkExpr(v, s.object);
            try walkExpr(v, s.start);
            try walkExpr(v, s.end);
        },
        .if_expr => |i| {
            try walkExpr(v, i.condition);
            try walkExpr(v, i.then_branch);
            if (i.else_branch) |e| try walkExpr(v, e);
        },

        // 多子节点
        .call => |c| {
            try walkExpr(v, c.callee);
            for (c.arguments) |arg| try walkExpr(v, arg);
        },
        .method_call => |mc| {
            try walkExpr(v, mc.object);
            for (mc.arguments) |arg| try walkExpr(v, arg);
        },
        .safe_method_call => |smc| {
            try walkExpr(v, smc.object);
            for (smc.arguments) |arg| try walkExpr(v, arg);
        },
        .array_literal => |al| {
            for (al.elements) |e| try walkExpr(v, e);
            if (al.fill_value) |fv| try walkExpr(v, fv);
            if (al.fill_count) |fc| try walkExpr(v, fc);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try walkExpr(v, f.value);
        },
        .record_extend => |re| {
            try walkExpr(v, re.base);
            for (re.updates) |f| try walkExpr(v, f.value);
        },

        // 含语句的表达式
        .block => |b| {
            for (b.statements) |s| try walkStmtV(v, s);
            if (b.trailing_expr) |te| try walkExpr(v, te);
        },

        // match：scrutinee + arms（guard + body）
        .match => |m| {
            try walkExpr(v, m.scrutinee);
            for (m.arms) |arm| {
                if (arm.guard) |g| try walkExpr(v, g);
                try walkExpr(v, arm.body);
            }
        },

        // lambda：body
        .lambda => |l| switch (l.body) {
            .block => |body_expr| try walkExpr(v, body_expr),
            .expression => |body_expr| try walkExpr(v, body_expr),
        },

        // select：arms 的 channel_expr + body
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    try walkExpr(v, r.channel_expr);
                    try walkExpr(v, r.body);
                },
                .timeout => |t| {
                    try walkExpr(v, t.duration);
                    try walkExpr(v, t.body);
                },
            };
        },

        .inline_trait_value => |itv| {
            for (itv.methods) |method| {
                if (method.body) |body| try walkExpr(v, body);
            }
        },
    }
}

/// 遍历语句的所有子节点（vtable 版），对子表达式递归 walkExpr，对嵌套语句递归 walkStmt。
fn walkStmtChildrenV(v: *const AstVisitor, stmt: *const ast.Stmt) anyerror!void {
    switch (stmt.*) {
        .val_decl => |val| try walkExpr(v, val.value),
        .var_decl => |val| try walkExpr(v, val.value),
        .assignment => |a| {
            try walkExpr(v, a.target);
            try walkExpr(v, a.value);
        },
        .compound_assignment => |c| {
            try walkExpr(v, c.target);
            try walkExpr(v, c.value);
        },
        .field_assignment => |f| {
            try walkExpr(v, f.object);
            try walkExpr(v, f.value);
        },
        .expression => |e| try walkExpr(v, e.expr),
        .return_stmt => |r| if (r.value) |val| try walkExpr(v, val),
        .defer_stmt => |d| try walkExpr(v, d.expr),
        .throw_stmt => |t| try walkExpr(v, t.expr),
        .for_stmt => |f| {
            try walkExpr(v, f.iterable);
            try walkExpr(v, f.body);
        },
        .while_stmt => |w| {
            try walkExpr(v, w.condition);
            try walkExpr(v, w.body);
        },
        .loop_stmt => |l| try walkExpr(v, l.body),
        .break_stmt, .continue_stmt => {},
    }
}

/// 语句遍历的内部辅助（含当前语句回调）。
fn walkStmtV(v: *const AstVisitor, stmt: *const ast.Stmt) anyerror!void {
    try walkStmtChildrenV(v, stmt);
    if (v.visit_stmt) |fn_| try fn_(v.ctx, stmt);
}

// ════════════════════════════════════════════════════════════
// 向后兼容：callback-based API（6 个 static_analysis pass 继续使用）
// ════════════════════════════════════════════════════════════

/// 表达式访问者回调类型（callback-based，向后兼容）
pub const ExprVisitor = *const fn (ctx: *anyopaque, expr: *const ast.Expr) anyerror!void;
/// 语句访问者回调类型（callback-based，向后兼容）
pub const StmtVisitor = *const fn (ctx: *anyopaque, stmt: *const ast.Stmt) anyerror!void;

/// 遍历表达式的所有子表达式节点（不含 expr 自身）
/// 对每个子节点调用 callback。callback 可抛出 error 中断遍历。
pub fn walkExprChildren(ctx: *anyopaque, expr: *const ast.Expr, callback: ExprVisitor) anyerror!void {
    switch (expr.*) {
        // 叶子节点：无子表达式
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal,
        .identifier,
        => {},

        // string_interpolation：遍历 parts 中的表达式
        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expression) try callback(ctx, part.expression);
            }
        },

        // 单子节点
        .unary => |u| try callback(ctx, u.operand),
        .ref_of => |r| try callback(ctx, r.operand),
        .deref => |d| try callback(ctx, d.operand),
        .non_null_assert => |n| try callback(ctx, n.expr),
        .propagate => |p| try callback(ctx, p.expr),
        .field_access => |f| try callback(ctx, f.object),
        .safe_access => |s| try callback(ctx, s.object),
        .type_cast => |tc| try callback(ctx, tc.expr),
        .cast_builder => |cb| try callback(ctx, cb.expr),
        .atomic_expr => |ae| try callback(ctx, ae.value),
        .lazy => |l| try callback(ctx, l.expr),
        .spawn_expr => |se| try callback(ctx, se.expr),

        // 双子节点
        .assignment_expr => |a| {
            try callback(ctx, a.target);
            try callback(ctx, a.value);
        },
        .compound_assign => |c| {
            try callback(ctx, c.target);
            try callback(ctx, c.value);
        },
        .binary => |b| {
            try callback(ctx, b.left);
            try callback(ctx, b.right);
        },
        .index => |i| {
            try callback(ctx, i.object);
            try callback(ctx, i.index);
        },
        .slice => |s| {
            try callback(ctx, s.object);
            try callback(ctx, s.start);
            try callback(ctx, s.end);
        },
        .if_expr => |i| {
            try callback(ctx, i.condition);
            try callback(ctx, i.then_branch);
            if (i.else_branch) |e| try callback(ctx, e);
        },

        // 多子节点
        .call => |c| {
            try callback(ctx, c.callee);
            for (c.arguments) |arg| try callback(ctx, arg);
        },
        .method_call => |mc| {
            try callback(ctx, mc.object);
            for (mc.arguments) |arg| try callback(ctx, arg);
        },
        .safe_method_call => |smc| {
            try callback(ctx, smc.object);
            for (smc.arguments) |arg| try callback(ctx, arg);
        },
        .array_literal => |al| {
            for (al.elements) |e| try callback(ctx, e);
            if (al.fill_value) |fv| try callback(ctx, fv);
            if (al.fill_count) |fc| try callback(ctx, fc);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try callback(ctx, f.value);
        },
        .record_extend => |re| {
            try callback(ctx, re.base);
            for (re.updates) |f| try callback(ctx, f.value);
        },

        // 含语句的表达式
        .block => |b| {
            for (b.statements) |s| try walkStmtCb(ctx, s, callback);
            if (b.trailing_expr) |te| try callback(ctx, te);
        },

        // match：scrutinee + arms（guard + body）
        .match => |m| {
            try callback(ctx, m.scrutinee);
            for (m.arms) |arm| {
                if (arm.guard) |g| try callback(ctx, g);
                try callback(ctx, arm.body);
            }
        },

        // lambda：body
        .lambda => |l| switch (l.body) {
            .block => |body_expr| try callback(ctx, body_expr),
            .expression => |body_expr| try callback(ctx, body_expr),
        },

        // select：arms 的 channel_expr + body
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    try callback(ctx, r.channel_expr);
                    try callback(ctx, r.body);
                },
                .timeout => |t| {
                    try callback(ctx, t.duration);
                    try callback(ctx, t.body);
                },
            };
        },

        .inline_trait_value => |itv| {
            for (itv.methods) |method| {
                if (method.body) |body| try callback(ctx, body);
            }
        },
    }
}

/// 遍历语句的所有子节点（表达式 + 嵌套语句）
pub fn walkStmtChildren(ctx: *anyopaque, stmt: *const ast.Stmt, callback: ExprVisitor) anyerror!void {
    switch (stmt.*) {
        .val_decl => |v| try callback(ctx, v.value),
        .var_decl => |v| try callback(ctx, v.value),
        .assignment => |a| {
            try callback(ctx, a.target);
            try callback(ctx, a.value);
        },
        .compound_assignment => |c| {
            try callback(ctx, c.target);
            try callback(ctx, c.value);
        },
        .field_assignment => |f| {
            try callback(ctx, f.object);
            try callback(ctx, f.value);
        },
        .expression => |e| try callback(ctx, e.expr),
        .return_stmt => |r| if (r.value) |v| try callback(ctx, v),
        .defer_stmt => |d| try callback(ctx, d.expr),
        .throw_stmt => |t| try callback(ctx, t.expr),
        .for_stmt => |f| {
            try callback(ctx, f.iterable);
            try callback(ctx, f.body);
        },
        .while_stmt => |w| {
            try callback(ctx, w.condition);
            try callback(ctx, w.body);
        },
        .loop_stmt => |l| try callback(ctx, l.body),
        .break_stmt, .continue_stmt => {},
    }
}

/// 语句完整遍历（callback-based，含语句回调）
/// 注意：vtable 版 `walkStmt` 是新标准 API；此函数保留供 callback-based 的
/// `walkExprChildren` 在遍历 block 语句时内部调用。
pub fn walkStmtCb(ctx: *anyopaque, stmt: *const ast.Stmt, expr_callback: ExprVisitor) anyerror!void {
    // 默认：语句不回调自身，只遍历其表达式子节点
    try walkStmtChildren(ctx, stmt, expr_callback);
}

// ════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════

test "ast_visitor: walkExprChildren 遍历 binary 的左右子节点" {
    const left = ast.Expr{ .int_literal = .{ .raw = "1", .suffix = null } };
    const right = ast.Expr{ .int_literal = .{ .raw = "2", .suffix = null } };
    const expr = ast.Expr{ .binary = .{ .op = .add, .left = @constCast(&left), .right = @constCast(&right) } };

    var count: u32 = 0;
    const Ctx = struct {
        n: *u32,
        fn cb(ctx: *anyopaque, e: *const ast.Expr) anyerror!void {
            _ = e;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
    };
    var c = Ctx{ .n = &count };
    try walkExprChildren(@ptrCast(&c), &expr, Ctx.cb);
    try std.testing.expect(count == 2);
}

test "ast_visitor: walkStmtChildren 遍历 val_decl 的 value" {
    const val = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    const stmt = ast.Stmt{ .val_decl = .{ .name = "x", .type_annotation = null, .value = @constCast(&val) } };

    var count: u32 = 0;
    const Ctx = struct {
        n: *u32,
        fn cb(ctx: *anyopaque, e: *const ast.Expr) anyerror!void {
            _ = e;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
    };
    var c = Ctx{ .n = &count };
    try walkStmtChildren(@ptrCast(&c), &stmt, Ctx.cb);
    try std.testing.expect(count == 1);
}

test "ast_visitor: vtable walkExpr 后序遍历（子节点先于父节点回调）" {
    // binary(int(1), int(2))：后序应先回调叶子，最后回调 binary
    const left = ast.Expr{ .int_literal = .{ .raw = "1", .suffix = null } };
    const right = ast.Expr{ .int_literal = .{ .raw = "2", .suffix = null } };
    const expr = ast.Expr{ .binary = .{ .op = .add, .left = @constCast(&left), .right = @constCast(&right) } };

    const Ctx = struct {
        order: *std.ArrayList([]const u8),
        fn cb(ctx: *anyopaque, e: *const ast.Expr) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const tag = switch (e.*) {
                .int_literal => "int",
                .binary => "binary",
                else => "other",
            };
            try self.order.append(tag);
        }
    };

    var order = std.ArrayList([]const u8){};
    defer order.deinit(std.testing.allocator);
    var c = Ctx{ .order = &order };
    const v = AstVisitor{ .ctx = @ptrCast(&c), .visit_expr = Ctx.cb };
    try walkExpr(&v, &expr);

    // 后序：int, int, binary
    try std.testing.expectEqual(@as(usize, 3), order.items.len);
    try std.testing.expectEqualStrings("int", order.items[0]);
    try std.testing.expectEqualStrings("int", order.items[1]);
    try std.testing.expectEqualStrings("binary", order.items[2]);
}
