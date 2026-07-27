//! 分支可达性分析模块。
//!
//! 基于常量传播的结果，判断 if 表达式的条件是否在编译期可确定为常量布尔值。
//! 若条件恒为 true 或 false，则对应的分支必然可达或必然不可达，可用于死分支
//! 消除等优化。分析结果记录在 BranchTable 中，键为 if 表达式指针。

const std = @import("std");
const ast = @import("ast");
const const_prop_mod = @import("const_prop.zig");
const ast_visitor = @import("ast_visitor");

/// 分支可达性信息：恒真、恒假或运行时判定。
pub const BranchInfo = enum {
    always_true,
    always_false,
    runtime,

    /// 是否为编译期确定的常量分支（非运行时判定）。
    pub fn isConst(self: BranchInfo) bool {
        return self != .runtime;
    }
};

/// if 表达式到分支可达性信息的映射表。
pub const BranchTable = struct {
    entries: std.AutoHashMap(*const ast.Expr, BranchInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BranchTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Expr, BranchInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BranchTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *BranchTable, if_expr: *const ast.Expr, info: BranchInfo) !void {
        try self.entries.put(if_expr, info);
    }

    pub fn lookup(self: *const BranchTable, if_expr: *const ast.Expr) ?BranchInfo {
        return self.entries.get(if_expr);
    }

    /// 分支表是否为空。
    pub fn isEmpty(self: *const BranchTable) bool {
        return self.entries.count() == 0;
    }
};

/// 分支可达性分析遍。依赖常量传播结果，逐函数遍历 AST 判定每个 if 的分支可达性。
pub const BranchReachPass = struct {
    table: BranchTable,
    const_table: *const const_prop_mod.ConstTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, const_table: *const const_prop_mod.ConstTable) BranchReachPass {
        return .{
            .table = BranchTable.init(allocator),
            .const_table = const_table,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BranchReachPass) void {
        self.table.deinit();
    }

    pub fn analyzeModule(self: *BranchReachPass, module: *const ast.Module) !void {
        // 无常量信息时跳过分析。
        if (self.const_table.isEmpty()) return;
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeExpr(decl.fun_decl.body);
        }
    }

    /// 递归分析表达式，对 if 表达式根据条件常量值判定分支可达性。
    /// v3 阶段 11：使用 ast_visitor.walkExprChildren 消除手写递归分支，
    /// 仅保留 if_expr 的特化 hook（常量条件检查）。
    fn analyzeExpr(self: *BranchReachPass, expr: *const ast.Expr) anyerror!void {
        // 先递归子节点（默认遍历）
        try ast_visitor.walkExprChildren(@ptrCast(self), expr, analyzeExprCallback);
        // 特化 hook：if_expr 的常量条件判定
        if (expr.* == .if_expr) {
            const i = expr.if_expr;
            // 查询条件在常量表中的值，判定分支可达性。
            if (self.const_table.lookup(i.condition)) |cv| {
                if (cv == .bool_val) {
                    const info: BranchInfo = if (cv.bool_val) .always_true else .always_false;
                    try self.table.put(expr, info);
                } else {
                    // 条件为常量但非布尔类型，视为运行时判定。
                    try self.table.put(expr, .runtime);
                }
            } else {
                // 条件无常量信息，视为运行时判定。
                try self.table.put(expr, .runtime);
            }
        }
    }

    /// walkExprChildren 的回调适配器（拆出以匹配 ExprVisitor 签名）
    fn analyzeExprCallback(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
        const self: *BranchReachPass = @ptrCast(@alignCast(ctx));
        try self.analyzeExpr(expr);
    }

    /// 递归分析语句中的表达式。
    /// v3 阶段 11：使用 ast_visitor.walkStmtChildren 消除手写递归分支。
    fn analyzeStmt(self: *BranchReachPass, stmt: *const ast.Stmt) anyerror!void {
        try ast_visitor.walkStmtChildren(@ptrCast(self), stmt, analyzeExprCallback);
    }
};

test "BranchTable basic put/lookup" {
    var table = BranchTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
}

test "BranchInfo isConst" {
    try std.testing.expect(BranchInfo.always_true.isConst());
    try std.testing.expect(BranchInfo.always_false.isConst());
    try std.testing.expect(!BranchInfo.runtime.isConst());
}
