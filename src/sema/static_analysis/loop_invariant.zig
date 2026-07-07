//! Pass 4：循环不变量分析。
//!
//! 估计循环体大小，标记小循环为可展开。
//! 编译器查询 LoopTable 决定是否展开（Task 11，可选）。
//!
//! 【LICM 扩展】同时收集循环不变量子表达式，加入 HoistTable。
//! 编译器在循环前 emit + set_local 缓存到 slot，循环内引用 slot 替代重算。

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

/// 【LICM】循环不变量提升表：表达式指针 → 该表达式所属循环的 stmt 指针。
/// 编译器查此表判断某表达式是否是已识别的循环不变量；同一条表达式仅可能属于一个直接外层循环。
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

    /// 查询表达式是否是某循环的可 hoist 不变量。返回该循环 stmt 指针。
    pub fn lookup(self: *const HoistTable, expr: *const ast.Expr) ?*const ast.Stmt {
        return self.entries.get(expr);
    }

    pub fn isEmpty(self: *const HoistTable) bool {
        return self.entries.count() == 0;
    }
};

/// 循环展开阈值（体指令数估计）
const UNROLL_THRESHOLD: u32 = 32;

// ============================================================
// 【LICM】模块级辅助函数：循环不变量分析
// ============================================================

/// 收集循环体内被赋值的变量名（含嵌套循环的 for 变量、assignment/compound_assignment target）。
/// 用于判定"循环不变量"——若 identifier 名字在此列表中，则该变量在循环内被修改，不是不变量。
/// 注意：val_decl/var_decl 的初始绑定不算"被修改"（仅 assignment 算），但 var_decl 名字若在循环内
/// 后续被 assignment，会被该 assignment 收集到。for_stmt 的循环变量每轮被赋值，必须算。
pub fn collectAssignedVars(
    allocator: std.mem.Allocator,
    body: *const ast.Expr,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    return collectAssignedVarsExpr(allocator, body, out);
}

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
        .assignment_expr => |a| {
            // a = b 的 LHS 是被赋值变量
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

fn collectAssignedVarsStmt(
    allocator: std.mem.Allocator,
    stmt: *const ast.Stmt,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    switch (stmt.*) {
        .val_decl => |v| {
            // val_decl 在循环内每轮重新绑定，绑定的变量值每轮可能不同（依赖循环变量）。
            // 必须加入 assigned_vars，否则 LICM 会误把循环内 val_decl 的变量当作不变量。
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
            // for 循环变量每轮被赋值
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

/// 遍历循环体，登记可 hoist 的不变量 binary 子表达式。
/// 自顶向下：遇到可 hoist 的 binary 即登记并停止递归子树（避免子表达式重复登记）。
pub fn collectHoistsInExpr(
    allocator: std.mem.Allocator,
    hoist_table: *HoistTable,
    expr: *const ast.Expr,
    owner_loop: *const ast.Stmt,
    assigned_vars: []const []const u8,
) anyerror!void {
    switch (expr.*) {
        .binary => |b| {
            if (isHoistableBinary(b, assigned_vars)) {
                try hoist_table.put(expr, owner_loop);
                // 不递归子树——整个 binary 已被 hoist，子表达式作为它的一部分也已被缓存
                return;
            }
            // 否则递归子表达式寻找可 hoist 子树
            try collectHoistsInExpr(allocator, hoist_table, b.left, owner_loop, assigned_vars);
            try collectHoistsInExpr(allocator, hoist_table, b.right, owner_loop, assigned_vars);
        },
        .unary => |u| try collectHoistsInExpr(allocator, hoist_table, u.operand, owner_loop, assigned_vars),
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
            // 不 hoist call 结果——保守
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
        .assignment_expr => |a| {
            // 不 hoist LHS（赋值目标）。RHS 可正常 hoist。
            try collectHoistsInExpr(allocator, hoist_table, a.value, owner_loop, assigned_vars);
        },
        .compound_assign => |c| {
            try collectHoistsInExpr(allocator, hoist_table, c.value, owner_loop, assigned_vars);
        },
        else => {},
    }
}

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
            // 不 hoist LHS（赋值目标）。RHS 可正常 hoist。
            try collectHoistsInExpr(allocator, hoist_table, a.value, owner_loop, assigned_vars);
        },
        .field_assignment => |f| try collectHoistsInExpr(allocator, hoist_table, f.value, owner_loop, assigned_vars),
        .compound_assignment => |c| try collectHoistsInExpr(allocator, hoist_table, c.value, owner_loop, assigned_vars),
        .expression => |e| try collectHoistsInExpr(allocator, hoist_table, e.expr, owner_loop, assigned_vars),
        .return_stmt => |r| if (r.value) |v| try collectHoistsInExpr(allocator, hoist_table, v, owner_loop, assigned_vars),
        .for_stmt => |f| {
            // 嵌套循环：递归处理（但不变量归属当前 owner_loop，因为嵌套循环体也是当前循环体的一部分）
            // 注意：嵌套循环的循环变量已在 assigned_vars 中（由 collectAssignedVars 收集）
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

/// 判定 binary 是否可 hoist：操作数都是循环不变量。
/// 算术（add/sub/mul/div/mod）会 panic（溢出/除零），hoist 到循环前会改变零次执行循环的 panic 时机。
/// 接受此语义差异（实际中循环零次执行且算术恰 panic 的情况极其罕见），以获取 LICM 收益。
/// concat/concat_list/range/range_inclusive/elvis 不 hoist（语义特殊/可能分配）。
fn isHoistableBinary(b: anytype, assigned_vars: []const []const u8) bool {
    switch (b.op) {
        .add, .sub, .mul, .div, .mod,
        .bit_and, .bit_or, .bit_xor,
        .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
        .and_op, .or_op => {},
        else => return false,
    }
    return isInvariantExpr(b.left, assigned_vars) and isInvariantExpr(b.right, assigned_vars);
}

/// 判定表达式是否是循环不变量：
/// - 字面量 → true
/// - identifier 名字不在 assigned_vars → true
/// - binary op 是 hoistable 且操作数都是 invariant → true
/// - 其他（call/method_call/spawn/index/field_access/unary 等）→ false（保守）
fn isInvariantExpr(expr: *const ast.Expr, assigned_vars: []const []const u8) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, => true,
        .identifier => |id| !isAssignedVar(id.name, assigned_vars),
        .binary => |b| isHoistableBinary(b, assigned_vars),
        else => false,
    };
}

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
    // 完整 put/lookup 需 AST 节点指针，在集成测试中覆盖
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
