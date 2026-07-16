//! 死代码消除（DCE）模块。
//!
//! 定义死代码表（DeadTable）与分析遍（DeadCodePass）。分析遍对每个函数体执行
//! 不动点迭代：先收集所有被读取的变量名，再将从未被读取且初值无副作用的声明
//! 标记为死代码。标记为死代码后，其初始化值中读取的变量不再计入有效读取，
//! 因此需要反复迭代直到不再产生新的死代码。

const std = @import("std");
const ast = @import("ast");

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
    fn collectReadsExpr(self: *DeadCodePass, expr: *const ast.Expr, reads: *std.StringHashMap(void)) anyerror!void {
        switch (expr.*) {
            .identifier => |id| try reads.put(id.name, {}),
            .binary => |b| {
                try self.collectReadsExpr(b.left, reads);
                try self.collectReadsExpr(b.right, reads);
            },
            .unary => |u| try self.collectReadsExpr(u.operand, reads),
            .call => |c| {
                try self.collectReadsExpr(c.callee, reads);
                for (c.arguments) |a| try self.collectReadsExpr(a, reads);
            },
            .if_expr => |i| {
                try self.collectReadsExpr(i.condition, reads);
                try self.collectReadsExpr(i.then_branch, reads);
                if (i.else_branch) |e| try self.collectReadsExpr(e, reads);
            },
            .block => |b| {
                for (b.statements) |s| try self.collectReadsStmt(s, reads);
                if (b.trailing_expr) |te| try self.collectReadsExpr(te, reads);
            },
            .lambda => |l| switch (l.body) {
                .block => |body_expr| try self.collectReadsExpr(body_expr, reads),
                .expression => |body_expr| try self.collectReadsExpr(body_expr, reads),
            },
            .match => |m| {
                try self.collectReadsExpr(m.scrutinee, reads);
                for (m.arms) |arm| {
                    if (arm.guard) |g| try self.collectReadsExpr(g, reads);
                    try self.collectReadsExpr(arm.body, reads);
                }
            },
            .type_cast => |tc| try self.collectReadsExpr(tc.expr, reads),
            .atomic_expr => |ae| try self.collectReadsExpr(ae.value, reads),
            .lazy => |l| try self.collectReadsExpr(l.expr, reads),
            .field_access => |f| try self.collectReadsExpr(f.object, reads),
            .safe_access => |f| try self.collectReadsExpr(f.object, reads),
            .index => |i| {
                try self.collectReadsExpr(i.object, reads);
                try self.collectReadsExpr(i.index, reads);
            },
            .non_null_assert => |n| try self.collectReadsExpr(n.expr, reads),
            .propagate => |p| try self.collectReadsExpr(p.expr, reads),
            .array_literal => |a| for (a.elements) |e| try self.collectReadsExpr(e, reads),
            .record_literal => |r| for (r.fields) |f| try self.collectReadsExpr(f.value, reads),
            .record_extend => |r| {
                try self.collectReadsExpr(r.base, reads);
                for (r.updates) |u| try self.collectReadsExpr(u.value, reads);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) try self.collectReadsExpr(part.expression, reads);
                }
            },
            .method_call => |mc| {
                try self.collectReadsExpr(mc.object, reads);
                for (mc.arguments) |a| try self.collectReadsExpr(a, reads);
            },
            .safe_method_call => |mc| {
                try self.collectReadsExpr(mc.object, reads);
                for (mc.arguments) |a| try self.collectReadsExpr(a, reads);
            },
            .assignment_expr => |a| {
                // 赋值目标若是标识符则为写入而非读取，不收集。
                if (a.target.* != .identifier) try self.collectReadsExpr(a.target, reads);
                try self.collectReadsExpr(a.value, reads);
            },
            .compound_assign => |c| {
                try self.collectReadsExpr(c.target, reads);
                try self.collectReadsExpr(c.value, reads);
            },
            else => {},
        }
    }

    /// 递归收集语句中所有被读取的变量名。
    fn collectReadsStmt(self: *DeadCodePass, stmt: *const ast.Stmt, reads: *std.StringHashMap(void)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                // 已标记为死的声明不计入读取。
                if (!self.table.isDead(stmt)) try self.collectReadsExpr(v.value, reads);
            },
            .var_decl => |v| {
                if (!self.table.isDead(stmt)) try self.collectReadsExpr(v.value, reads);
            },
            .assignment => |a| {
                if (a.target.* != .identifier) try self.collectReadsExpr(a.target, reads);
                try self.collectReadsExpr(a.value, reads);
            },
            .field_assignment => |f| {
                try self.collectReadsExpr(f.object, reads);
                try self.collectReadsExpr(f.value, reads);
            },
            .compound_assignment => |c| {
                try self.collectReadsExpr(c.target, reads);
                try self.collectReadsExpr(c.value, reads);
            },
            .expression => |e| try self.collectReadsExpr(e.expr, reads),
            .return_stmt => |r| if (r.value) |v| try self.collectReadsExpr(v, reads),
            .for_stmt => |f| {
                try self.collectReadsExpr(f.iterable, reads);
                try self.collectReadsExpr(f.body, reads);
            },
            .while_stmt => |w| {
                try self.collectReadsExpr(w.condition, reads);
                try self.collectReadsExpr(w.body, reads);
            },
            .loop_stmt => |l| try self.collectReadsExpr(l.body, reads),
            .defer_stmt => |d| try self.collectReadsExpr(d.expr, reads),
            .throw_stmt => |t| try self.collectReadsExpr(t.expr, reads),
            .break_stmt, .continue_stmt => {},
        }
    }

    /// 遍历表达式，对其中声明的变量检查是否被读取；若未被读取且初值无副作用则标记为死。
    fn collectAndMarkDeclsExpr(self: *DeadCodePass, expr: *const ast.Expr, reads: *const std.StringHashMap(void)) anyerror!void {
        switch (expr.*) {
            .binary => |b| {
                try self.collectAndMarkDeclsExpr(b.left, reads);
                try self.collectAndMarkDeclsExpr(b.right, reads);
            },
            .unary => |u| try self.collectAndMarkDeclsExpr(u.operand, reads),
            .call => |c| {
                try self.collectAndMarkDeclsExpr(c.callee, reads);
                for (c.arguments) |a| try self.collectAndMarkDeclsExpr(a, reads);
            },
            .if_expr => |i| {
                try self.collectAndMarkDeclsExpr(i.condition, reads);
                try self.collectAndMarkDeclsExpr(i.then_branch, reads);
                if (i.else_branch) |e| try self.collectAndMarkDeclsExpr(e, reads);
            },
            .block => |b| {
                for (b.statements) |s| try self.collectAndMarkDeclsStmt(s, reads);
                if (b.trailing_expr) |te| try self.collectAndMarkDeclsExpr(te, reads);
            },
            .lambda => |l| switch (l.body) {
                .block => |body_expr| try self.collectAndMarkDeclsExpr(body_expr, reads),
                .expression => |body_expr| try self.collectAndMarkDeclsExpr(body_expr, reads),
            },
            .match => |m| {
                try self.collectAndMarkDeclsExpr(m.scrutinee, reads);
                for (m.arms) |arm| {
                    if (arm.guard) |g| try self.collectAndMarkDeclsExpr(g, reads);
                    try self.collectAndMarkDeclsExpr(arm.body, reads);
                }
            },
            .type_cast => |tc| try self.collectAndMarkDeclsExpr(tc.expr, reads),
            .atomic_expr => |ae| try self.collectAndMarkDeclsExpr(ae.value, reads),
            .lazy => |l| try self.collectAndMarkDeclsExpr(l.expr, reads),
            .field_access => |f| try self.collectAndMarkDeclsExpr(f.object, reads),
            .safe_access => |f| try self.collectAndMarkDeclsExpr(f.object, reads),
            .index => |i| {
                try self.collectAndMarkDeclsExpr(i.object, reads);
                try self.collectAndMarkDeclsExpr(i.index, reads);
            },
            .non_null_assert => |n| try self.collectAndMarkDeclsExpr(n.expr, reads),
            .propagate => |p| try self.collectAndMarkDeclsExpr(p.expr, reads),
            .array_literal => |a| for (a.elements) |e| try self.collectAndMarkDeclsExpr(e, reads),
            .record_literal => |r| for (r.fields) |f| try self.collectAndMarkDeclsExpr(f.value, reads),
            .record_extend => |r| {
                try self.collectAndMarkDeclsExpr(r.base, reads);
                for (r.updates) |u| try self.collectAndMarkDeclsExpr(u.value, reads);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) try self.collectAndMarkDeclsExpr(part.expression, reads);
                }
            },
            .method_call => |mc| {
                try self.collectAndMarkDeclsExpr(mc.object, reads);
                for (mc.arguments) |a| try self.collectAndMarkDeclsExpr(a, reads);
            },
            .safe_method_call => |mc| {
                try self.collectAndMarkDeclsExpr(mc.object, reads);
                for (mc.arguments) |a| try self.collectAndMarkDeclsExpr(a, reads);
            },
            .assignment_expr => |a| {
                try self.collectAndMarkDeclsExpr(a.target, reads);
                try self.collectAndMarkDeclsExpr(a.value, reads);
            },
            .compound_assign => |c| {
                try self.collectAndMarkDeclsExpr(c.target, reads);
                try self.collectAndMarkDeclsExpr(c.value, reads);
            },
            else => {},
        }
    }

    /// 遍历语句，对 val_decl / var_decl 检查其变量名是否被读取。
    /// 若未被读取且初值无副作用，则标记为死代码。
    fn collectAndMarkDeclsStmt(self: *DeadCodePass, stmt: *const ast.Stmt, reads: *const std.StringHashMap(void)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                if (!reads.contains(v.name) and isSideEffectFreeExpr(v.value)) {
                    try self.table.put(stmt);
                }
                try self.collectAndMarkDeclsExpr(v.value, reads);
            },
            .var_decl => |v| {
                if (!reads.contains(v.name) and isSideEffectFreeExpr(v.value)) {
                    try self.table.put(stmt);
                }
                try self.collectAndMarkDeclsExpr(v.value, reads);
            },
            .assignment => |a| try self.collectAndMarkDeclsExpr(a.value, reads),
            .field_assignment => |f| {
                try self.collectAndMarkDeclsExpr(f.object, reads);
                try self.collectAndMarkDeclsExpr(f.value, reads);
            },
            .compound_assignment => |c| {
                try self.collectAndMarkDeclsExpr(c.target, reads);
                try self.collectAndMarkDeclsExpr(c.value, reads);
            },
            .expression => |e| try self.collectAndMarkDeclsExpr(e.expr, reads),
            .return_stmt => |r| if (r.value) |val| try self.collectAndMarkDeclsExpr(val, reads),
            .for_stmt => |f| {
                try self.collectAndMarkDeclsExpr(f.iterable, reads);
                try self.collectAndMarkDeclsExpr(f.body, reads);
            },
            .while_stmt => |w| {
                try self.collectAndMarkDeclsExpr(w.condition, reads);
                try self.collectAndMarkDeclsExpr(w.body, reads);
            },
            .loop_stmt => |l| try self.collectAndMarkDeclsExpr(l.body, reads),
            .defer_stmt => |d| try self.collectAndMarkDeclsExpr(d.expr, reads),
            .throw_stmt => |t| try self.collectAndMarkDeclsExpr(t.expr, reads),
            .break_stmt, .continue_stmt => {},
        }
    }
};

/// 判断表达式是否无副作用。仅纯字面量、标识符、无副作用的一元 / 二元运算、
/// if 表达式、类型转换等可判定为无副作用；调用、索引、赋值等一律视为有副作用。
fn isSideEffectFreeExpr(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, .identifier,
        => true,
        .unary => |u| isSideEffectFreeExpr(u.operand),
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
        .non_null_assert => |n| isSideEffectFreeExpr(n.expr),
        // 以下表达式一律视为有副作用，不在此处逐条展开。
        .call, .method_call, .safe_method_call, .string_interpolation,
        .index, .record_literal, .record_extend, .array_literal,
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
