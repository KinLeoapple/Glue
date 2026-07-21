//! 循环不变量分析模块。
//!
//! 提供循环信息表（LoopTable）和外提候选表（HoistTable），以及用于收集循环体内
//! 被赋值变量和外提候选表达式的辅助函数。循环不变量是指循环体内不依赖循环变量、
//! 每次迭代计算结果相同的表达式，可以安全地外提到循环外部以减少重复计算。
//! 这些数据由 fused_analysis 在遍历循环时收集。

const std = @import("std");
const ast = @import("ast");

/// 循环信息：是否为小循环（可考虑展开）及估算大小。
pub const LoopInfo = struct {
    is_small: bool,
    est_size: u32,
};

/// 循环语句到循环信息的映射表。
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

    /// 循环表是否为空。
    pub fn isEmpty(self: *const LoopTable) bool {
        return self.entries.count() == 0;
    }
};

/// 外提候选表。将可外提的表达式映射到其所属的循环语句。
pub const HoistTable = struct {
    entries: std.AutoHashMap(*const ast.Expr, *const ast.Stmt),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HoistTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Expr, *const ast.Stmt).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HoistTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *HoistTable, expr: *const ast.Expr, owner_loop: *const ast.Stmt) !void {
        try self.entries.put(expr, owner_loop);
    }

    pub fn lookup(self: *const HoistTable, expr: *const ast.Expr) ?*const ast.Stmt {
        return self.entries.get(expr);
    }

    /// 外提表是否为空。
    pub fn isEmpty(self: *const HoistTable) bool {
        return self.entries.count() == 0;
    }
};

/// 收集表达式体中被赋值的所有变量名，用于判断表达式是否为循环不变量。
pub fn collectAssignedVars(
    allocator: std.mem.Allocator,
    body: *const ast.Expr,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    return collectAssignedVarsExpr(allocator, body, out);
}

/// 递归收集表达式中被赋值的变量名。
fn collectAssignedVarsExpr(
    allocator: std.mem.Allocator,
    expr: *const ast.Expr,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| try collectAssignedVarsStmt(allocator, s, out);
            if (b.trailing_expr) |te| try collectAssignedVarsExpr(allocator, te, out);
        },
        .if_expr => |i| {
            try collectAssignedVarsExpr(allocator, i.condition, out);
            try collectAssignedVarsExpr(allocator, i.then_branch, out);
            if (i.else_branch) |e| try collectAssignedVarsExpr(allocator, e, out);
        },
        .binary => |bn| {
            try collectAssignedVarsExpr(allocator, bn.left, out);
            try collectAssignedVarsExpr(allocator, bn.right, out);
        },
        .unary => |u| try collectAssignedVarsExpr(allocator, u.operand, out),
        .ref_of => |r| try collectAssignedVarsExpr(allocator, r.operand, out),
        .deref => |d| try collectAssignedVarsExpr(allocator, d.operand, out),
        .call => |c| {
            try collectAssignedVarsExpr(allocator, c.callee, out);
            for (c.arguments) |a| try collectAssignedVarsExpr(allocator, a, out);
        },
        .match => |m| {
            try collectAssignedVarsExpr(allocator, m.scrutinee, out);
            for (m.arms) |arm| {
                if (arm.guard) |g| try collectAssignedVarsExpr(allocator, g, out);
                try collectAssignedVarsExpr(allocator, arm.body, out);
            }
        },
        .lambda => {},
        .type_cast => |tc| try collectAssignedVarsExpr(allocator, tc.expr, out),
        .atomic_expr => |ae| try collectAssignedVarsExpr(allocator, ae.value, out),
        .field_access => |f| try collectAssignedVarsExpr(allocator, f.object, out),
        .safe_access => |f| try collectAssignedVarsExpr(allocator, f.object, out),
        .index => |i| {
            try collectAssignedVarsExpr(allocator, i.object, out);
            try collectAssignedVarsExpr(allocator, i.index, out);
        },
        .non_null_assert => |n| try collectAssignedVarsExpr(allocator, n.expr, out),
        .propagate => |p| try collectAssignedVarsExpr(allocator, p.expr, out),
        .array_literal => |a| for (a.elements) |e| try collectAssignedVarsExpr(allocator, e, out),
        .record_literal => |r| for (r.fields) |f| try collectAssignedVarsExpr(allocator, f.value, out),
        .record_extend => |r| {
            try collectAssignedVarsExpr(allocator, r.base, out);
            for (r.updates) |u| try collectAssignedVarsExpr(allocator, u.value, out);
        },
        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expression) try collectAssignedVarsExpr(allocator, part.expression, out);
            }
        },
        // 赋值表达式中，若目标为标识符则记录该变量名。
        .assignment_expr => |a| {
            if (a.target.* == .identifier) {
                try addStringIfNotPresent(allocator, out, a.target.identifier.name);
            }
            try collectAssignedVarsExpr(allocator, a.value, out);
        },
        .compound_assign => |c| {
            if (c.target.* == .identifier) {
                try addStringIfNotPresent(allocator, out, c.target.identifier.name);
            }
            try collectAssignedVarsExpr(allocator, c.value, out);
        },
        else => {},
    }
}

/// 递归收集语句中被赋值的变量名。
fn collectAssignedVarsStmt(
    allocator: std.mem.Allocator,
    stmt: *const ast.Stmt,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    switch (stmt.*) {
        .val_decl => |v| {
            try addStringIfNotPresent(allocator, out, v.name);
            try collectAssignedVarsExpr(allocator, v.value, out);
        },
        .var_decl => |v| {
            try addStringIfNotPresent(allocator, out, v.name);
            try collectAssignedVarsExpr(allocator, v.value, out);
        },
        .assignment => |a| {
            if (a.target.* == .identifier) {
                try addStringIfNotPresent(allocator, out, a.target.identifier.name);
            }
            try collectAssignedVarsExpr(allocator, a.value, out);
        },
        .field_assignment => |f| try collectAssignedVarsExpr(allocator, f.value, out),
        .compound_assignment => |c| {
            if (c.target.* == .identifier) {
                try addStringIfNotPresent(allocator, out, c.target.identifier.name);
            }
            try collectAssignedVarsExpr(allocator, c.value, out);
        },
        .expression => |e| try collectAssignedVarsExpr(allocator, e.expr, out),
        .return_stmt => |r| if (r.value) |v| try collectAssignedVarsExpr(allocator, v, out),
        .for_stmt => |f| {
            // for 循环变量在每次迭代中被重新赋值。
            try addStringIfNotPresent(allocator, out, f.name);
            try collectAssignedVarsExpr(allocator, f.iterable, out);
            try collectAssignedVarsExpr(allocator, f.body, out);
        },
        .while_stmt => |w| {
            try collectAssignedVarsExpr(allocator, w.condition, out);
            try collectAssignedVarsExpr(allocator, w.body, out);
        },
        .loop_stmt => |l| try collectAssignedVarsExpr(allocator, l.body, out),
        .defer_stmt => |d| try collectAssignedVarsExpr(allocator, d.expr, out),
        .throw_stmt => |t| try collectAssignedVarsExpr(allocator, t.expr, out),
        .break_stmt, .continue_stmt => {},
    }
}

/// 将变量名添加到列表中（去重）。
fn addStringIfNotPresent(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try out.append(allocator, name);
}

/// 在循环体内收集可外提的表达式，记录到 hoist_table 中。
/// assigned_vars 为循环体内被赋值的变量名列表，用于判断表达式是否为不变量。
pub fn collectHoistsInExpr(
    allocator: std.mem.Allocator,
    hoist_table: *HoistTable,
    expr: *const ast.Expr,
    owner_loop: *const ast.Stmt,
    assigned_vars: []const []const u8,
) anyerror!void {
    switch (expr.*) {
        .binary => |b| {
            // 若二元表达式整体可外提，则记录并停止递归。
            if (isHoistableBinary(b, assigned_vars)) {
                try hoist_table.put(expr, owner_loop);
                return;
            }
            try collectHoistsInExpr(allocator, hoist_table, b.left, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, b.right, owner_loop, assigned_vars);
        },
        .unary => |u| try collectHoistsInExpr(allocator, hoist_table, u.operand, owner_loop, assigned_vars),
        .ref_of => |r| try collectHoistsInExpr(allocator, hoist_table, r.operand, owner_loop, assigned_vars),
        .deref => |d| try collectHoistsInExpr(allocator, hoist_table, d.operand, owner_loop, assigned_vars),
        .if_expr => |i| {
            try collectHoistsInExpr(allocator, hoist_table, i.condition, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, i.then_branch, owner_loop, assigned_vars);
            if (i.else_branch) |e| try collectHoistsInExpr(allocator, hoist_table, e, owner_loop, assigned_vars);
        },
        .block => |b| {
            for (b.statements) |s| try collectHoistsInStmt(allocator, hoist_table, s, owner_loop, assigned_vars);
            if (b.trailing_expr) |te| try collectHoistsInExpr(allocator, hoist_table, te, owner_loop, assigned_vars);
        },
        .call => |c| {
            try collectHoistsInExpr(allocator, hoist_table, c.callee, owner_loop, assigned_vars);
            for (c.arguments) |a| try collectHoistsInExpr(allocator, hoist_table, a, owner_loop, assigned_vars);
        },
        .match => |m| {
            try collectHoistsInExpr(allocator, hoist_table, m.scrutinee, owner_loop, assigned_vars);
            for (m.arms) |arm| {
                if (arm.guard) |g| try collectHoistsInExpr(allocator, hoist_table, g, owner_loop, assigned_vars);
                try collectHoistsInExpr(allocator, hoist_table, arm.body, owner_loop, assigned_vars);
            }
        },
        .type_cast => |tc| try collectHoistsInExpr(allocator, hoist_table, tc.expr, owner_loop, assigned_vars),
        .atomic_expr => |ae| try collectHoistsInExpr(allocator, hoist_table, ae.value, owner_loop, assigned_vars),
        .field_access => |f| try collectHoistsInExpr(allocator, hoist_table, f.object, owner_loop, assigned_vars),
        .safe_access => |f| try collectHoistsInExpr(allocator, hoist_table, f.object, owner_loop, assigned_vars),
        .index => |i| {
            try collectHoistsInExpr(allocator, hoist_table, i.object, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, i.index, owner_loop, assigned_vars);
        },
        .array_literal => |a| for (a.elements) |e| try collectHoistsInExpr(allocator, hoist_table, e, owner_loop, assigned_vars),
        .record_literal => |r| for (r.fields) |f| try collectHoistsInExpr(allocator, hoist_table, f.value, owner_loop, assigned_vars),
        .record_extend => |r| {
            try collectHoistsInExpr(allocator, hoist_table, r.base, owner_loop, assigned_vars);
            for (r.updates) |u| try collectHoistsInExpr(allocator, hoist_table, u.value, owner_loop, assigned_vars);
        },
        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expression) try collectHoistsInExpr(allocator, hoist_table, part.expression, owner_loop, assigned_vars);
            }
        },
        // 赋值表达式中仅值部分可能包含可外提子表达式，目标部分跳过。
        .assignment_expr => |a| {
            try collectHoistsInExpr(allocator, hoist_table, a.value, owner_loop, assigned_vars);
        },
        .compound_assign => |c| {
            try collectHoistsInExpr(allocator, hoist_table, c.value, owner_loop, assigned_vars);
        },
        else => {},
    }
}

/// 递归收集语句中可外提的表达式。
fn collectHoistsInStmt(
    allocator: std.mem.Allocator,
    hoist_table: *HoistTable,
    stmt: *const ast.Stmt,
    owner_loop: *const ast.Stmt,
    assigned_vars: []const []const u8,
) anyerror!void {
    switch (stmt.*) {
        .val_decl => |v| try collectHoistsInExpr(allocator, hoist_table, v.value, owner_loop, assigned_vars),
        .var_decl => |v| try collectHoistsInExpr(allocator, hoist_table, v.value, owner_loop, assigned_vars),
        .assignment => |a| {
            try collectHoistsInExpr(allocator, hoist_table, a.value, owner_loop, assigned_vars);
        },
        .field_assignment => |f| try collectHoistsInExpr(allocator, hoist_table, f.value, owner_loop, assigned_vars),
        .compound_assignment => |c| try collectHoistsInExpr(allocator, hoist_table, c.value, owner_loop, assigned_vars),
        .expression => |e| try collectHoistsInExpr(allocator, hoist_table, e.expr, owner_loop, assigned_vars),
        .return_stmt => |r| if (r.value) |v| try collectHoistsInExpr(allocator, hoist_table, v, owner_loop, assigned_vars),
        .for_stmt => |f| {
            try collectHoistsInExpr(allocator, hoist_table, f.iterable, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, f.body, owner_loop, assigned_vars);
        },
        .while_stmt => |w| {
            try collectHoistsInExpr(allocator, hoist_table, w.condition, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, w.body, owner_loop, assigned_vars);
        },
        .loop_stmt => |l| try collectHoistsInExpr(allocator, hoist_table, l.body, owner_loop, assigned_vars),
        .defer_stmt => |d| try collectHoistsInExpr(allocator, hoist_table, d.expr, owner_loop, assigned_vars),
        .throw_stmt => |t| try collectHoistsInExpr(allocator, hoist_table, t.expr, owner_loop, assigned_vars),
        .break_stmt, .continue_stmt => {},
    }
}

/// 判断二元表达式是否可外提：运算符为纯算术 / 比较 / 位运算，且两个操作数均为循环不变量。
fn isHoistableBinary(b: anytype, assigned_vars: []const []const u8) bool {
    switch (b.op) {
        .add, .sub, .mul, .div, .mod,
        .bit_and, .bit_or, .bit_xor, .shl, .shr,
        .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
        .and_op, .or_op => {},
        else => return false,
    }
    return isInvariantExpr(b.left, assigned_vars) and isInvariantExpr(b.right, assigned_vars);
}

/// 判断表达式是否为循环不变量：字面量恒为不变量，标识符需不在赋值列表中，
/// 二元表达式递归判断。
fn isInvariantExpr(expr: *const ast.Expr, assigned_vars: []const []const u8) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, => true,
        .identifier => |id| !isAssignedVar(id.name, assigned_vars),
        .binary => |b| isHoistableBinary(b, assigned_vars),
        else => false,
    };
}

/// 判断变量名是否在赋值列表中。
fn isAssignedVar(name: []const u8, assigned_vars: []const []const u8) bool {
    for (assigned_vars) |v| {
        if (std.mem.eql(u8, v, name)) return true;
    }
    return false;
}

test "LoopTable basic put/lookup" {
    var table = LoopTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
}

test "HoistTable basic put/lookup" {
    var table = HoistTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
}

test "isAssignedVar" {
    const assigned = [_][]const u8{ "i", "acc", "sum" };
    try std.testing.expect(isAssignedVar("i", &assigned));
    try std.testing.expect(isAssignedVar("acc", &assigned));
    try std.testing.expect(!isAssignedVar("a", &assigned));
    try std.testing.expect(!isAssignedVar("", &assigned));
}
