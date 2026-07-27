//! 死代码消除（DCE）模块。
//!
//! 定义死代码表（DeadTable）与分析遍（DeadCodePass）。分析遍对每个函数体执行
//! 不动点迭代：先收集所有被读取的变量名，再将从未被读取且初值无副作用的声明
//! 标记为死代码。标记为死代码后，其初始化值中读取的变量不再计入有效读取，
//! 因此需要反复迭代直到不再产生新的死代码。

const std = @import("std");
const ast = @import("ast");
const ast_visitor = @import("ast_visitor");

/// 死代码标记表。键为被标记为死代码的语句指针。
pub const DeadTable = struct {
    entries: std.AutoHashMap(*const ast.Stmt, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DeadTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Stmt, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DeadTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *DeadTable, stmt: *const ast.Stmt) !void {
        try self.entries.put(stmt, {});
    }

    /// 判断给定语句是否被标记为死代码。
    pub fn isDead(self: *const DeadTable, stmt: *const ast.Stmt) bool {
        return self.entries.contains(stmt);
    }

    /// 死代码表是否为空。
    pub fn isEmpty(self: *const DeadTable) bool {
        return self.entries.count() == 0;
    }
};

/// 死代码分析遍。逐函数遍历 AST，通过不动点迭代标记未被使用的声明。
pub const DeadCodePass = struct {
    table: *DeadTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: *DeadTable) DeadCodePass {
        return .{
            .table = table,
            .allocator = allocator,
        };
    }

    pub fn analyzeModule(self: *DeadCodePass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeFunction(decl.fun_decl.body);
        }
    }

    /// 对函数体执行不动点迭代：反复收集有效读取并标记死声明，直到不再变化。
    fn analyzeFunction(self: *DeadCodePass, body: *const ast.Expr) !void {
        var changed = true;
        while (changed) {
            changed = false;
            var reads = std.StringHashMap(void).init(self.allocator);
            defer reads.deinit();
            // 已标记为死的声明其初始化值中的读取不再计入。
            try self.collectReadsExpr(body, &reads);
            const before = self.table.entries.count();
            try self.collectAndMarkDeclsExpr(body, &reads);
            if (self.table.entries.count() > before) changed = true;
        }
    }

    /// 递归收集表达式中所有被读取的变量名。已标记为死代码的声明跳过其值。
    /// v3 阶段 11：使用 ast_visitor.walkExprChildren 消除手写递归分支，
    /// 仅保留 identifier（记录读取）、assignment_expr（跳过标识符目标）、
    /// block（委托 collectReadsStmt 以处理死声明跳过）的特化 hook。
    fn collectReadsExpr(self: *DeadCodePass, expr: *const ast.Expr, reads: *std.StringHashMap(void)) anyerror!void {
        var ctx = ReadsCtx{ .pass = self, .reads = reads };
        try collectReadsExprImpl(&ctx, expr);
    }

    /// 递归收集语句中所有被读取的变量名。
    /// v3 阶段 11：使用 ast_visitor.walkStmtChildren 消除手写递归分支，
    /// 仅保留 val_decl/var_decl（死声明跳过）和 assignment（跳过标识符目标）的特化 hook。
    fn collectReadsStmt(self: *DeadCodePass, stmt: *const ast.Stmt, reads: *std.StringHashMap(void)) anyerror!void {
        var ctx = ReadsCtx{ .pass = self, .reads = reads };
        try collectReadsStmtImpl(&ctx, stmt);
    }

    /// 遍历表达式，对其中声明的变量检查是否被读取；若未被读取且初值无副作用则标记为死。
    /// v3 阶段 11：使用 ast_visitor.walkExprChildren 消除手写递归分支，
    /// 仅保留 block（委托 collectAndMarkDeclsStmt）的特化 hook。
    fn collectAndMarkDeclsExpr(self: *DeadCodePass, expr: *const ast.Expr, reads: *const std.StringHashMap(void)) anyerror!void {
        var ctx = MarkCtx{ .pass = self, .reads = reads };
        try collectAndMarkDeclsImpl(&ctx, expr);
    }

    /// 遍历语句，对 val_decl / var_decl 检查其变量名是否被读取。
    /// 若未被读取且初值无副作用，则标记为死代码。
    /// v3 阶段 11：使用 ast_visitor.walkStmtChildren 消除手写递归分支，
    /// 仅保留 val_decl/var_decl（标记死代码）的特化 hook。
    fn collectAndMarkDeclsStmt(self: *DeadCodePass, stmt: *const ast.Stmt, reads: *const std.StringHashMap(void)) anyerror!void {
        var ctx = MarkCtx{ .pass = self, .reads = reads };
        try collectAndMarkDeclsStmtImpl(&ctx, stmt);
    }
};

/// collectReads 的上下文：绑定 pass 与 reads 映射。
const ReadsCtx = struct {
    pass: *DeadCodePass,
    reads: *std.StringHashMap(void),
};

/// collectReadsExpr 的实现：特化 hook + 默认 walkExprChildren 递归。
fn collectReadsExprImpl(ctx: *ReadsCtx, expr: *const ast.Expr) anyerror!void {
    switch (expr.*) {
        // hook：identifier → 记录读取
        .identifier => |id| try ctx.reads.put(id.name, {}),
        // hook：assignment_expr → 跳过标识符目标
        .assignment_expr => |a| {
            if (a.target.* != .identifier) try collectReadsExprImpl(ctx, a.target);
            try collectReadsExprImpl(ctx, a.value);
        },
        // hook：block → 委托 collectReadsStmtImpl 处理死声明跳过
        .block => |b| {
            for (b.statements) |s| try collectReadsStmtImpl(ctx, s);
            if (b.trailing_expr) |te| try collectReadsExprImpl(ctx, te);
        },
        // 默认：walkExprChildren 递归
        else => {
            try ast_visitor.walkExprChildren(@ptrCast(ctx), expr, collectReadsExprCb);
        },
    }
}

/// walkExprChildren 回调适配器
fn collectReadsExprCb(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
    const c: *ReadsCtx = @ptrCast(@alignCast(ctx));
    try collectReadsExprImpl(c, expr);
}

/// collectReadsStmt 的实现：特化 hook + 默认 walkStmtChildren 递归。
fn collectReadsStmtImpl(ctx: *ReadsCtx, stmt: *const ast.Stmt) anyerror!void {
    switch (stmt.*) {
        // hook：val_decl/var_decl → 死声明跳过
        .val_decl => |v| {
            if (!ctx.pass.table.isDead(stmt)) try collectReadsExprImpl(ctx, v.value);
        },
        .var_decl => |v| {
            if (!ctx.pass.table.isDead(stmt)) try collectReadsExprImpl(ctx, v.value);
        },
        // hook：assignment → 跳过标识符目标
        .assignment => |a| {
            if (a.target.* != .identifier) try collectReadsExprImpl(ctx, a.target);
            try collectReadsExprImpl(ctx, a.value);
        },
        // 默认：walkStmtChildren 递归
        else => {
            try ast_visitor.walkStmtChildren(@ptrCast(ctx), stmt, collectReadsExprCb);
        },
    }
}

/// collectAndMark 的上下文：绑定 pass 与 reads 映射（只读）。
const MarkCtx = struct {
    pass: *DeadCodePass,
    reads: *const std.StringHashMap(void),
};

/// collectAndMarkDeclsExpr 的实现：特化 hook + 默认 walkExprChildren 递归。
fn collectAndMarkDeclsImpl(ctx: *MarkCtx, expr: *const ast.Expr) anyerror!void {
    switch (expr.*) {
        // hook：block → 委托 collectAndMarkDeclsStmtImpl 处理声明标记
        .block => |b| {
            for (b.statements) |s| try collectAndMarkDeclsStmtImpl(ctx, s);
            if (b.trailing_expr) |te| try collectAndMarkDeclsImpl(ctx, te);
        },
        // 默认：walkExprChildren 递归
        else => {
            try ast_visitor.walkExprChildren(@ptrCast(ctx), expr, collectAndMarkDeclsCb);
        },
    }
}

/// walkExprChildren 回调适配器
fn collectAndMarkDeclsCb(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
    const c: *MarkCtx = @ptrCast(@alignCast(ctx));
    try collectAndMarkDeclsImpl(c, expr);
}

/// collectAndMarkDeclsStmt 的实现：特化 hook + 默认 walkStmtChildren 递归。
fn collectAndMarkDeclsStmtImpl(ctx: *MarkCtx, stmt: *const ast.Stmt) anyerror!void {
    switch (stmt.*) {
        // hook：val_decl/var_decl → 标记死代码后递归
        .val_decl => |v| {
            if (!ctx.reads.contains(v.name) and isSideEffectFreeExpr(v.value)) {
                try ctx.pass.table.put(stmt);
            }
            try collectAndMarkDeclsImpl(ctx, v.value);
        },
        .var_decl => |v| {
            if (!ctx.reads.contains(v.name) and isSideEffectFreeExpr(v.value)) {
                try ctx.pass.table.put(stmt);
            }
            try collectAndMarkDeclsImpl(ctx, v.value);
        },
        // 默认：walkStmtChildren 递归
        else => {
            try ast_visitor.walkStmtChildren(@ptrCast(ctx), stmt, collectAndMarkDeclsCb);
        },
    }
}

/// 判断表达式是否无副作用。仅纯字面量、标识符、无副作用的一元 / 二元运算、
/// if 表达式、类型转换等可判定为无副作用；调用、索引、赋值等一律视为有副作用。
fn isSideEffectFreeExpr(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, .identifier,
        => true,
        .unary => |u| isSideEffectFreeExpr(u.operand),
        .ref_of => |r| isSideEffectFreeExpr(r.operand),
        .deref => |d| isSideEffectFreeExpr(d.operand),
        .binary => |b| switch (b.op) {
            // 短路运算、范围、列表拼接等可能有副作用或特殊语义，保守视为非纯。
            .and_op, .or_op, .elvis => false,
            .range, .range_inclusive, .concat_list => false,
            else => isSideEffectFreeExpr(b.left) and isSideEffectFreeExpr(b.right),
        },
        .block => |b| {
            for (b.statements) |s| if (!isSideEffectFreeStmt(s)) return false;
            if (b.trailing_expr) |te| return isSideEffectFreeExpr(te);
            return true;
        },
        .field_access => |f| isSideEffectFreeExpr(f.object),
        .safe_access => |f| isSideEffectFreeExpr(f.object),
        .if_expr => |i| {
            if (!isSideEffectFreeExpr(i.condition)) return false;
            if (!isSideEffectFreeExpr(i.then_branch)) return false;
            if (i.else_branch) |e| if (!isSideEffectFreeExpr(e)) return false;
            return true;
        },
        .type_cast => |tc| isSideEffectFreeExpr(tc.expr),
        .cast_builder => |cb| isSideEffectFreeExpr(cb.expr),
        .non_null_assert => |n| isSideEffectFreeExpr(n.expr),
        // 以下表达式一律视为有副作用，不在此处逐条展开。
        .call, .method_call, .safe_method_call, .string_interpolation,
        .index, .slice, .record_literal, .record_extend, .array_literal,
        .lambda, .match, .select, .lazy, .spawn_expr,
        .assignment_expr, .compound_assign, .propagate,
        .atomic_expr, .inline_trait_value,
        => false,
    };
}

/// 判断语句是否无副作用。仅表达式语句和声明语句可能无副作用，其余一律视为有副作用。
fn isSideEffectFreeStmt(stmt: *const ast.Stmt) bool {
    return switch (stmt.*) {
        .expression => |e| isSideEffectFreeExpr(e.expr),
        .val_decl => |v| isSideEffectFreeExpr(v.value),
        .var_decl => |v| isSideEffectFreeExpr(v.value),
        else => false,
    };
}

test "DeadTable basic" {
    var table = DeadTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
}

test "isSideEffectFreeExpr literals" {
    const expr = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    try std.testing.expect(isSideEffectFreeExpr(&expr));
}
