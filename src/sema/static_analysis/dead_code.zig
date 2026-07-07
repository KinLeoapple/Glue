//! Pass：死代码消除（DCE）。
//!
//! 借鉴 LLVM DCE：识别"完全未被引用"且"RHS 无副作用"的 val_decl/var_decl，
//! 标记为 dead。编译器在 emitStmt 中查询 DeadTable，命中则跳过整个声明
//!（不分配 slot、不 emit RHS、不 emit set_local），消除 dead 指令。
//!
//! 算法（迭代到 fixpoint，捕获 chained dead）：
//!   1. 收集所有"读取位置"的 identifier name（assignment target 不算读取；
//!      compound_assignment target 既读又写，算读取）
//!   2. 已标记 dead 的 val_decl/var_decl 的 RHS 不计入 reads（因为 RHS 不再 emit）
//!   3. 遍历所有 val_decl/var_decl，若 name 不在 reads 且 RHS 无副作用 → 标记 dead
//!   4. 重复 1-3 直到 table 不再增长
//!
//! 限制：函数级分析（不跨函数）；只标记整个声明 dead（不做部分消除）。

const std = @import("std");
const ast = @import("ast");

/// 死代码表：被标记为 dead 的 val_decl/var_decl stmt 指针集合
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

    pub fn isDead(self: *const DeadTable, stmt: *const ast.Stmt) bool {
        return self.entries.contains(stmt);
    }

    pub fn isEmpty(self: *const DeadTable) bool {
        return self.entries.count() == 0;
    }
};

/// DCE pass（借用 DeadTable，由 AnalysisDB 持有）
pub const DeadCodePass = struct {
    table: *DeadTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: *DeadTable) DeadCodePass {
        return .{
            .table = table,
            .allocator = allocator,
        };
    }

    /// 分析模块：对每个 fun_decl 体跑迭代 DCE
    pub fn analyzeModule(self: *DeadCodePass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeFunction(decl.fun_decl.body);
        }
    }

    fn analyzeFunction(self: *DeadCodePass, body: *const ast.Expr) !void {
        // 迭代到 fixpoint：每次标记新 dead 后，被 dead 的 RHS 引用不再算 reads，
        // 可能使上游 val_decl 也变 dead。
        var changed = true;
        while (changed) {
            changed = false;
            var reads = std.StringHashMap(void).init(self.allocator);
            defer reads.deinit();
            try self.collectReadsExpr(body, &reads);
            const before = self.table.entries.count();
            try self.collectAndMarkDeclsExpr(body, &reads);
            if (self.table.entries.count() > before) changed = true;
        }
    }

    /// 收集"读取位置"的 identifier name。
    /// 已标记 dead 的 val_decl/var_decl 的 RHS 不收集（因为 RHS 不再 emit）。
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
            .spawn => |sp| try self.collectReadsExpr(sp.body, reads),
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
                // 纯 identifier target 是写入，不算读取；其他 target（字段/索引）的 object 部分算读取
                if (a.target.* != .identifier) try self.collectReadsExpr(a.target, reads);
                try self.collectReadsExpr(a.value, reads);
            },
            .compound_assign => |c| {
                // compound assignment target 既读又写（a += 1 读取 a）
                try self.collectReadsExpr(c.target, reads);
                try self.collectReadsExpr(c.value, reads);
            },
            else => {},
        }
    }

    fn collectReadsStmt(self: *DeadCodePass, stmt: *const ast.Stmt, reads: *std.StringHashMap(void)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                // 已 dead 的 RHS 不再 emit，不收集其 reads
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

    /// 遍历所有 val_decl/var_decl，若 name 未被读取 且 RHS 无副作用 → 标记 dead。
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
            .spawn => |sp| try self.collectAndMarkDeclsExpr(sp.body, reads),
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

/// 判定表达式是否无副作用（保守版，镜像 compiler.exprHasNoSideEffects）。
/// 用于 DCE：RHS 无副作用时，未使用的 val_decl 可安全消除。
fn isSideEffectFreeExpr(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, .identifier,
        => true,
        .unary => |u| isSideEffectFreeExpr(u.operand),
        .binary => |b| switch (b.op) {
            .and_op, .or_op, .elvis => false, // 短路可能跳过右操作数，保守不消除
            .range, .range_inclusive, .concat_list => false, // 可能分配
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
        // 有副作用或可能抛异常/分配
        .call, .method_call, .safe_method_call, .string_interpolation,
        .index, .record_literal, .record_extend, .array_literal,
        .lambda, .match, .select, .spawn, .lazy,
        .assignment_expr, .compound_assign, .propagate,
        .atomic_expr, .inline_trait_value,
        => false,
    };
}

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
    // 直接构造字面量 AST 节点测试
    const expr = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null, .location = .{ .line = 1, .column = 1 } } };
    try std.testing.expect(isSideEffectFreeExpr(&expr));
}
