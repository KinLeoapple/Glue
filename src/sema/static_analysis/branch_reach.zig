//! Pass 5：分支可达性分析。
//!
//! 查询 ConstTable 检测 if 表达式的条件是否为编译期常量布尔值。
//! 若是，则标记该分支为 always_true / always_false，编译器可跳过死分支。
//!
//! 限制：仅利用同函数内的常量传播结果（ConstTable 不跨函数）。

const std = @import("std");
const ast = @import("ast");
const const_prop_mod = @import("const_prop.zig");

/// 分支可达性信息
pub const BranchInfo = enum {
    /// 条件恒为 true：then 分支必执行，else 分支死代码
    always_true,
    /// 条件恒为 false：else 分支必执行（若有），then 分支死代码
    always_false,
    /// 条件为运行时值：两分支均可能执行
    runtime,

    pub fn isConst(self: BranchInfo) bool {
        return self != .runtime;
    }
};

/// 分支表：if_expr 节点指针 → BranchInfo
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

    pub fn isEmpty(self: *const BranchTable) bool {
        return self.entries.count() == 0;
    }
};

/// Pass 5：分支可达性分析器
pub const BranchReachPass = struct {
    table: BranchTable,
    /// 借用 ConstPropPass 的结果表（不拥有）
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

    /// 遍历模块所有 if_expr，查询条件是否为常量布尔
    pub fn analyzeModule(self: *BranchReachPass, module: *const ast.Module) !void {
        // 【优化】const_table 为空时所有 if 条件必然非常量，跳过整个遍历
        if (self.const_table.isEmpty()) return;
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeExpr(decl.fun_decl.body);
        }
    }

    fn analyzeExpr(self: *BranchReachPass, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .if_expr => |i| {
                // 先递归子节点（条件、then、else 内部可能还有嵌套 if）
                try self.analyzeExpr(i.condition);
                try self.analyzeExpr(i.then_branch);
                if (i.else_branch) |e| try self.analyzeExpr(e);

                // 查询条件是否为常量布尔
                if (self.const_table.lookup(i.condition)) |cv| {
                    if (cv == .bool_val) {
                        const info: BranchInfo = if (cv.bool_val) .always_true else .always_false;
                        try self.table.put(expr, info);
                    } else {
                        try self.table.put(expr, .runtime);
                    }
                } else {
                    try self.table.put(expr, .runtime);
                }
            },
            .binary => |b| {
                try self.analyzeExpr(b.left);
                try self.analyzeExpr(b.right);
            },
            .unary => |u| try self.analyzeExpr(u.operand),
            .call => |c| {
                try self.analyzeExpr(c.callee);
                for (c.arguments) |arg| try self.analyzeExpr(arg);
            },
            .block => |b| {
                for (b.statements) |s| try self.analyzeStmt(s);
                if (b.trailing_expr) |te| try self.analyzeExpr(te);
            },
            .match => |m| {
                try self.analyzeExpr(m.scrutinee);
                for (m.arms) |arm| {
                    if (arm.guard) |g| try self.analyzeExpr(g);
                    try self.analyzeExpr(arm.body);
                }
            },
            .lambda => |l| switch (l.body) {
                .block => |body_expr| try self.analyzeExpr(body_expr),
                .expression => |body_expr| try self.analyzeExpr(body_expr),
            },
            .type_cast => |tc| try self.analyzeExpr(tc.expr),
            .atomic_expr => |ae| try self.analyzeExpr(ae.value),
            else => {},
        }
    }

    fn analyzeStmt(self: *BranchReachPass, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| try self.analyzeExpr(v.value),
            .var_decl => |v| try self.analyzeExpr(v.value),
            .assignment => |a| try self.analyzeExpr(a.value),
            .expression => |e| try self.analyzeExpr(e.expr),
            .return_stmt => |r| if (r.value) |v| try self.analyzeExpr(v),
            .for_stmt => |f| {
                try self.analyzeExpr(f.iterable);
                try self.analyzeExpr(f.body);
            },
            .while_stmt => |w| {
                try self.analyzeExpr(w.condition);
                try self.analyzeExpr(w.body);
            },
            .loop_stmt => |l| try self.analyzeExpr(l.body),
            else => {},
        }
    }
};

test "BranchTable basic put/lookup" {
    var table = BranchTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    // 完整 put/lookup 需 AST 节点指针，在集成测试中覆盖
}

test "BranchInfo isConst" {
    try std.testing.expect(BranchInfo.always_true.isConst());
    try std.testing.expect(BranchInfo.always_false.isConst());
    try std.testing.expect(!BranchInfo.runtime.isConst());
}
