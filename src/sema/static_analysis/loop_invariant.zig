//! Pass 4：循环不变量分析。
//!
//! 估计循环体大小，标记小循环为可展开。
//! 编译器查询 LoopTable 决定是否展开（Task 11，可选）。
//!
//! 限制：仅做大小估计，不做不变量提升（HOIST）。

const std = @import("std");
const ast = @import("ast");

/// 循环信息
pub const LoopInfo = struct {
    /// 循环体是否足够小可展开（指令数估计 < threshold）
    is_small: bool,
    /// 估计的循环体指令数
    est_size: u32,
};

/// 循环语句 → 循环信息
/// 键为 *const ast.Stmt（for/while/loop 是 Stmt，不是 Expr）
pub const LoopTable = struct {
    entries: std.AutoHashMap(*const ast.Stmt, LoopInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LoopTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Stmt, LoopInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LoopTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *LoopTable, stmt: *const ast.Stmt, info: LoopInfo) !void {
        try self.entries.put(stmt, info);
    }

    pub fn lookup(self: *const LoopTable, stmt: *const ast.Stmt) ?LoopInfo {
        return self.entries.get(stmt);
    }

    pub fn isEmpty(self: *const LoopTable) bool {
        return self.entries.count() == 0;
    }
};

/// 循环展开阈值（体指令数估计）
const UNROLL_THRESHOLD: u32 = 32;

/// Pass 4：循环不变量分析器
pub const LoopInvariantPass = struct {
    table: LoopTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LoopInvariantPass {
        return .{
            .table = LoopTable.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LoopInvariantPass) void {
        self.table.deinit();
    }

    pub fn analyzeModule(self: *LoopInvariantPass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeExpr(decl.fun_decl.body);
        }
    }

    fn analyzeExpr(self: *LoopInvariantPass, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .block => |b| {
                for (b.statements) |s| try self.analyzeStmt(s);
                if (b.trailing_expr) |te| try self.analyzeExpr(te);
            },
            .if_expr => |i| {
                try self.analyzeExpr(i.condition);
                try self.analyzeExpr(i.then_branch);
                if (i.else_branch) |e| try self.analyzeExpr(e);
            },
            .binary => |bn| {
                try self.analyzeExpr(bn.left);
                try self.analyzeExpr(bn.right);
            },
            .unary => |u| try self.analyzeExpr(u.operand),
            .call => |c| {
                try self.analyzeExpr(c.callee);
                for (c.arguments) |arg| try self.analyzeExpr(arg);
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
            .spawn => |sp| try self.analyzeExpr(sp.body),
            .atomic_expr => |ae| try self.analyzeExpr(ae.value),
            else => {},
        }
    }

    fn analyzeStmt(self: *LoopInvariantPass, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .for_stmt => |f| {
                const size = self.estimateSize(f.body);
                try self.table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                try self.analyzeExpr(f.iterable);
                try self.analyzeExpr(f.body);
            },
            .while_stmt => |w| {
                const size = self.estimateSize(w.body);
                try self.table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                try self.analyzeExpr(w.condition);
                try self.analyzeExpr(w.body);
            },
            .loop_stmt => |l| {
                const size = self.estimateSize(l.body);
                try self.table.put(stmt, .{
                    .is_small = size <= UNROLL_THRESHOLD,
                    .est_size = size,
                });
                try self.analyzeExpr(l.body);
            },
            .val_decl => |v| try self.analyzeExpr(v.value),
            .var_decl => |v| try self.analyzeExpr(v.value),
            .assignment => |a| try self.analyzeExpr(a.value),
            .expression => |e| try self.analyzeExpr(e.expr),
            .return_stmt => |r| if (r.value) |v| try self.analyzeExpr(v),
            .defer_stmt => |d| try self.analyzeExpr(d.expr),
            .throw_stmt => |t| try self.analyzeExpr(t.expr),
            else => {},
        }
    }

    /// 估计表达式的字节码指令数
    fn estimateSize(self: *LoopInvariantPass, expr: *const ast.Expr) u32 {
        return switch (expr.*) {
            .int_literal, .float_literal, .bool_literal, .char_literal,
            .string_literal, .null_literal, .unit_literal, .identifier,
            => 1,
            .binary => 3, // left + right + op
            .unary => 2,
            .call => |c| 1 + @as(u32, @intCast(c.arguments.len)),
            .if_expr => |i| 5 + (if (i.else_branch != null) @as(u32, 1) else 0),
            .block => |b| blk: {
                var size: u32 = 0;
                for (b.statements) |s| size += self.estimateStmtSize(s);
                if (b.trailing_expr) |te| size += self.estimateSize(te);
                break :blk size;
            },
            else => 5, // 保守估计
        };
    }

    fn estimateStmtSize(self: *LoopInvariantPass, stmt: *const ast.Stmt) u32 {
        return switch (stmt.*) {
            .val_decl => |v| self.estimateSize(v.value) + 1,
            .var_decl => |v| self.estimateSize(v.value) + 1,
            .assignment => |a| self.estimateSize(a.value) + 1,
            .expression => |e| self.estimateSize(e.expr),
            .return_stmt => |r| if (r.value) |v| self.estimateSize(v) + 1 else 1,
            .for_stmt => 5, // 保守
            .while_stmt => 5,
            .loop_stmt => 5,
            else => 1,
        };
    }
};

test "LoopTable basic put/lookup" {
    var table = LoopTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    // 完整 put/lookup 需 AST 节点指针，在集成测试中覆盖
}
