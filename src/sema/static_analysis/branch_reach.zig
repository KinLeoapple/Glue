//! 分支可达性分析模块。
//!
//! 基于常量传播的结果，判断 if 表达式的条件是否在编译期可确定为常量布尔值。
//! 若条件恒为 true 或 false，则对应的分支必然可达或必然不可达，可用于死分支
//! 消除等优化。分析结果记录在 BranchTable 中，键为 if 表达式指针。

const std = @import("std");
const ast = @import("ast");
const const_prop_mod = @import("const_prop.zig");

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
    fn analyzeExpr(self: *BranchReachPass, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .if_expr => |i| {
                try self.analyzeExpr(i.condition);
                try self.analyzeExpr(i.then_branch);
                if (i.else_branch) |e| try self.analyzeExpr(e);
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
            },
            .binary => |b| {
                try self.analyzeExpr(b.left);
                try self.analyzeExpr(b.right);
            },
            .unary => |u| try self.analyzeExpr(u.operand),
            .ref_of => |r| try self.analyzeExpr(r.operand),
            .deref => |d| try self.analyzeExpr(d.operand),
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

    /// 递归分析语句中的表达式。
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
}

test "BranchInfo isConst" {
    try std.testing.expect(BranchInfo.always_true.isConst());
    try std.testing.expect(BranchInfo.always_false.isConst());
    try std.testing.expect(!BranchInfo.runtime.isConst());
}
