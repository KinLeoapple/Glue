//! 循环不变量分析模块。
//!
//! 提供循环信息表（LoopTable）和外提候选表（HoistTable），以及用于收集循环体内
//! 被赋值变量和外提候选表达式的辅助函数。循环不变量是指循环体内不依赖循环变量、
//! 每次迭代计算结果相同的表达式，可以安全地外提到循环外部以减少重复计算。
//! 这些数据由 fused_analysis 在遍历循环时收集。
//!
//! v3 阶段 11：使用 ast_visitor.walkExprChildren/walkStmtChildren 消除手写递归分支，
//! 仅保留特化 hook（赋值目标记录、循环变量记录、二元表达式外提判定、作用域隔离）。

const std = @import("std");
const ast = @import("ast");
const ast_visitor = @import("ast_visitor");

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
    var ctx = AssignedVarsCtx{ .allocator = allocator, .out = out };
    try collectAssignedVarsExprImpl(&ctx, body);
}

/// collectAssignedVars 的上下文：绑定 allocator 与输出列表。
const AssignedVarsCtx = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
};

/// collectAssignedVarsExpr 的实现：特化 hook + 默认 walkExprChildren 递归。
/// v3 阶段 11：消除手写递归分支，仅保留赋值目标记录、block 委托、作用域隔离的 hook。
fn collectAssignedVarsExprImpl(ctx: *AssignedVarsCtx, expr: *const ast.Expr) anyerror!void {
    switch (expr.*) {
        // hook：assignment_expr → 记录标识符目标，递归 value
        .assignment_expr => |a| {
            if (a.target.* == .identifier) {
                try addStringIfNotPresent(ctx.allocator, ctx.out, a.target.identifier.name);
            }
            try collectAssignedVarsExprImpl(ctx, a.value);
        },
        // hook：compound_assign → 记录标识符目标，递归 value
        .compound_assign => |c| {
            if (c.target.* == .identifier) {
                try addStringIfNotPresent(ctx.allocator, ctx.out, c.target.identifier.name);
            }
            try collectAssignedVarsExprImpl(ctx, c.value);
        },
        // hook：block → 委托 collectAssignedVarsStmtImpl 处理语句级 hook
        .block => |b| {
            for (b.statements) |s| try collectAssignedVarsStmtImpl(ctx, s);
            if (b.trailing_expr) |te| try collectAssignedVarsExprImpl(ctx, te);
        },
        // 作用域隔离：不递归（lambda/select/inline_trait_value/spawn/lazy 内的赋值不影响外层）
        .lambda, .select, .inline_trait_value, .spawn_expr, .lazy => {},
        // 默认：walkExprChildren 递归
        else => {
            try ast_visitor.walkExprChildren(@ptrCast(ctx), expr, collectAssignedVarsExprCb);
        },
    }
}

/// walkExprChildren 回调适配器
fn collectAssignedVarsExprCb(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
    const c: *AssignedVarsCtx = @ptrCast(@alignCast(ctx));
    try collectAssignedVarsExprImpl(c, expr);
}

/// collectAssignedVarsStmt 的实现：特化 hook + 默认 walkStmtChildren 递归。
/// v3 阶段 11：消除手写递归分支，仅保留声明名记录、赋值目标记录、循环变量记录的 hook。
fn collectAssignedVarsStmtImpl(ctx: *AssignedVarsCtx, stmt: *const ast.Stmt) anyerror!void {
    switch (stmt.*) {
        // hook：val_decl/var_decl → 记录名，递归 value
        .val_decl => |v| {
            try addStringIfNotPresent(ctx.allocator, ctx.out, v.name);
            try collectAssignedVarsExprImpl(ctx, v.value);
        },
        .var_decl => |v| {
            try addStringIfNotPresent(ctx.allocator, ctx.out, v.name);
            try collectAssignedVarsExprImpl(ctx, v.value);
        },
        // hook：assignment → 记录标识符目标，递归 value
        .assignment => |a| {
            if (a.target.* == .identifier) {
                try addStringIfNotPresent(ctx.allocator, ctx.out, a.target.identifier.name);
            }
            try collectAssignedVarsExprImpl(ctx, a.value);
        },
        // hook：field_assignment → 仅递归 value（object 被读不被赋值）
        .field_assignment => |f| try collectAssignedVarsExprImpl(ctx, f.value),
        // hook：compound_assignment → 记录标识符目标，递归 value
        .compound_assignment => |c| {
            if (c.target.* == .identifier) {
                try addStringIfNotPresent(ctx.allocator, ctx.out, c.target.identifier.name);
            }
            try collectAssignedVarsExprImpl(ctx, c.value);
        },
        // hook：for_stmt → 记录循环变量，递归 iterable + body
        .for_stmt => |f| {
            try addStringIfNotPresent(ctx.allocator, ctx.out, f.name);
            try collectAssignedVarsExprImpl(ctx, f.iterable);
            try collectAssignedVarsExprImpl(ctx, f.body);
        },
        // 默认：walkStmtChildren 递归（while_stmt/loop_stmt/expression/return_stmt/defer_stmt/throw_stmt/break/continue）
        else => {
            try ast_visitor.walkStmtChildren(@ptrCast(ctx), stmt, collectAssignedVarsExprCb);
        },
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
    _ = allocator; // 公共 API 保留参数，visitor 实现内部不需要
    var ctx = HoistCtx{
        .hoist_table = hoist_table,
        .owner_loop = owner_loop,
        .assigned_vars = assigned_vars,
    };
    try collectHoistsInExprImpl(&ctx, expr);
}

/// collectHoistsInExpr 的上下文：绑定 hoist_table、owner_loop、assigned_vars。
const HoistCtx = struct {
    hoist_table: *HoistTable,
    owner_loop: *const ast.Stmt,
    assigned_vars: []const []const u8,
};

/// collectHoistsInExpr 的实现：特化 hook + 默认 walkExprChildren 递归。
/// v3 阶段 11：消除手写递归分支，仅保留二元表达式外提判定、赋值目标跳过、block 委托、作用域隔离的 hook。
fn collectHoistsInExprImpl(ctx: *HoistCtx, expr: *const ast.Expr) anyerror!void {
    switch (expr.*) {
        // hook：binary → 若可外提则记录并停止递归；否则递归子节点
        .binary => |b| {
            if (isHoistableBinary(b, ctx.assigned_vars)) {
                try ctx.hoist_table.put(expr, ctx.owner_loop);
                return;
            }
            try ast_visitor.walkExprChildren(@ptrCast(ctx), expr, collectHoistsInExprCb);
        },
        // hook：assignment_expr → 仅递归 value（目标跳过）
        .assignment_expr => |a| try collectHoistsInExprImpl(ctx, a.value),
        // hook：compound_assign → 仅递归 value（目标跳过）
        .compound_assign => |c| try collectHoistsInExprImpl(ctx, c.value),
        // hook：block → 委托 collectHoistsInStmtImpl 处理语句级 hook
        .block => |b| {
            for (b.statements) |s| try collectHoistsInStmtImpl(ctx, s);
            if (b.trailing_expr) |te| try collectHoistsInExprImpl(ctx, te);
        },
        // 作用域隔离：不递归（lambda/select/inline_trait_value/spawn/lazy 内的表达式不可外提到外层循环）
        .lambda, .select, .inline_trait_value, .spawn_expr, .lazy => {},
        // 默认：walkExprChildren 递归
        else => {
            try ast_visitor.walkExprChildren(@ptrCast(ctx), expr, collectHoistsInExprCb);
        },
    }
}

/// walkExprChildren 回调适配器
fn collectHoistsInExprCb(ctx: *anyopaque, expr: *const ast.Expr) anyerror!void {
    const c: *HoistCtx = @ptrCast(@alignCast(ctx));
    try collectHoistsInExprImpl(c, expr);
}

/// collectHoistsInStmt 的实现：特化 hook + 默认 walkStmtChildren 递归。
/// v3 阶段 11：消除手写递归分支，仅保留赋值/字段赋值/复合赋值目标跳过的 hook。
fn collectHoistsInStmtImpl(ctx: *HoistCtx, stmt: *const ast.Stmt) anyerror!void {
    switch (stmt.*) {
        // hook：assignment → 仅递归 value（目标跳过）
        .assignment => |a| try collectHoistsInExprImpl(ctx, a.value),
        // hook：field_assignment → 仅递归 value（object 跳过）
        .field_assignment => |f| try collectHoistsInExprImpl(ctx, f.value),
        // hook：compound_assignment → 仅递归 value（目标跳过）
        .compound_assignment => |c| try collectHoistsInExprImpl(ctx, c.value),
        // 默认：walkStmtChildren 递归（val_decl/var_decl/expression/return_stmt/defer_stmt/throw_stmt/for_stmt/while_stmt/loop_stmt/break/continue）
        else => {
            try ast_visitor.walkStmtChildren(@ptrCast(ctx), stmt, collectHoistsInExprCb);
        },
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
