//! 公共子表达式消除（CSE）模块。
//!
//! 定义 CSE 结果表（CseTable）与分析遍（CsePass）。遍历函数体时记录已出现的
//! 可消除表达式，当后续遇到结构相同的表达式时，将其标记为冗余并指向首次出现
//! 的规范表达式。赋值和循环等可能改变可见值的构造会触发失效，清空已记录集合。

const std = @import("std");
const ast = @import("ast");

/// CSE 结果表。redundant_map 将冗余表达式映射到其规范（首次出现）表达式，
/// canonical_set 记录所有作为规范的表达式。
pub const CseTable = struct {
    redundant_map: std.AutoHashMap(*const ast.Expr, *const ast.Expr),
    canonical_set: std.AutoHashMap(*const ast.Expr, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CseTable {
        return .{
            .redundant_map = std.AutoHashMap(*const ast.Expr, *const ast.Expr).init(allocator),
            .canonical_set = std.AutoHashMap(*const ast.Expr, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CseTable) void {
        self.redundant_map.deinit();
        self.canonical_set.deinit();
    }

    /// 返回给定表达式的规范表达式；若表达式非冗余则返回 null。
    pub fn canonicalOf(self: *const CseTable, expr: *const ast.Expr) ?*const ast.Expr {
        return self.redundant_map.get(expr);
    }

    /// 判断给定表达式是否为某个 CSE 组的规范表达式。
    pub fn isCanonical(self: *const CseTable, expr: *const ast.Expr) bool {
        return self.canonical_set.contains(expr);
    }

    /// 结果表是否为空（无冗余表达式）。
    pub fn isEmpty(self: *const CseTable) bool {
        return self.redundant_map.count() == 0;
    }
};

/// 已见表达式条目，用于在遍历过程中追踪已出现的可消除表达式。
const SeenEntry = struct {
    expr: *const ast.Expr,
};

/// CSE 分析遍。逐函数遍历 AST，在函数体内识别结构相同的冗余表达式。
pub const CsePass = struct {
    table: *CseTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: *CseTable) CsePass {
        return .{
            .table = table,
            .allocator = allocator,
        };
    }

    pub fn analyzeModule(self: *CsePass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            try self.analyzeFunction(decl.fun_decl.body);
        }
    }

    fn analyzeFunction(self: *CsePass, body: *const ast.Expr) !void {
        var seen = std.ArrayListUnmanaged(SeenEntry).empty;
        defer seen.deinit(self.allocator);
        try self.processExpr(body, &seen);
    }

    fn processExpr(self: *CsePass, expr: *const ast.Expr, seen: *std.ArrayListUnmanaged(SeenEntry)) anyerror!void {
        switch (expr.*) {
            .binary => |b| {
                try self.processExpr(b.left, seen);
                try self.processExpr(b.right, seen);
                if (isCseEligibleBinary(expr)) {
                    // 与已见表达式逐一比较；若结构相同则标记为冗余。
                    for (seen.items) |entry| {
                        if (exprEqual(entry.expr, expr)) {
                            try self.table.redundant_map.put(expr, entry.expr);
                            try self.table.canonical_set.put(entry.expr, {});
                            return;
                        }
                    }
                    try seen.append(self.allocator, .{ .expr = expr });
                }
            },
            .unary => |u| try self.processExpr(u.operand, seen),
            .ref_of => |r| try self.processExpr(r.operand, seen),
            .deref => |d| try self.processExpr(d.operand, seen),
            .if_expr => |i| {
                // then / else 分支各自独立作用域，处理后清空已见集合。
                try self.processExpr(i.condition, seen);
                var then_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer then_seen.deinit(self.allocator);
                try self.processExpr(i.then_branch, &then_seen);
                if (i.else_branch) |e| {
                    var else_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer else_seen.deinit(self.allocator);
                    try self.processExpr(e, &else_seen);
                }
                seen.clearRetainingCapacity();
            },
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.processStmt(stmt, seen);
                    // 循环语句可能改变变量值，清空已见集合以保证安全。
                    switch (stmt.*) {
                        .while_stmt, .for_stmt, .loop_stmt => {
                            seen.clearRetainingCapacity();
                        },
                        else => {},
                    }
                }
                if (b.trailing_expr) |te| try self.processExpr(te, seen);
            },
            .call => |c| {
                try self.processExpr(c.callee, seen);
                for (c.arguments) |a| try self.processExpr(a, seen);
            },
            .method_call => |mc| {
                try self.processExpr(mc.object, seen);
                for (mc.arguments) |a| try self.processExpr(a, seen);
            },
            .safe_method_call => |mc| {
                try self.processExpr(mc.object, seen);
                for (mc.arguments) |a| try self.processExpr(a, seen);
            },
            .match => |m| {
                // 每个 arm 独立作用域。
                try self.processExpr(m.scrutinee, seen);
                for (m.arms) |arm| {
                    var arm_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                    defer arm_seen.deinit(self.allocator);
                    if (arm.guard) |g| try self.processExpr(g, &arm_seen);
                    try self.processExpr(arm.body, &arm_seen);
                }
                seen.clearRetainingCapacity();
            },
            .type_cast => |tc| try self.processExpr(tc.expr, seen),
            .atomic_expr => |ae| try self.processExpr(ae.value, seen),
            .lazy => |l| try self.processExpr(l.expr, seen),
            .field_access => |f| try self.processExpr(f.object, seen),
            .safe_access => |f| try self.processExpr(f.object, seen),
            .index => |i| {
                try self.processExpr(i.object, seen);
                try self.processExpr(i.index, seen);
            },
            .non_null_assert => |n| try self.processExpr(n.expr, seen),
            .propagate => |p| try self.processExpr(p.expr, seen),
            .array_literal => |a| {
                for (a.elements) |e| try self.processExpr(e, seen);
            },
            .record_literal => |r| {
                for (r.fields) |f| try self.processExpr(f.value, seen);
            },
            .record_extend => |r| {
                try self.processExpr(r.base, seen);
                for (r.updates) |u| try self.processExpr(u.value, seen);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) try self.processExpr(part.expression, seen);
                }
            },
            .assignment_expr => |a| {
                try self.processExpr(a.value, seen);
                // 对标识符赋值时仅需失效读取该变量的已见表达式；
                // 对复杂目标赋值则保守清空全部已见集合。
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name, seen);
                } else {
                    try self.processExpr(a.target, seen);
                    seen.clearRetainingCapacity();
                }
            },
            .compound_assign => |c| {
                try self.processExpr(c.value, seen);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name, seen);
                } else {
                    seen.clearRetainingCapacity();
                }
            },
            .lambda => {},
            .select => {},
            .inline_trait_value => {},
            else => {},
        }
    }

    fn processStmt(self: *CsePass, stmt: *const ast.Stmt, seen: *std.ArrayListUnmanaged(SeenEntry)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| try self.processExpr(v.value, seen),
            .var_decl => |v| try self.processExpr(v.value, seen),
            .assignment => |a| {
                try self.processExpr(a.value, seen);
                if (a.target.* == .identifier) {
                    self.invalidate(a.target.identifier.name, seen);
                } else {
                    seen.clearRetainingCapacity();
                }
            },
            .field_assignment => |f| {
                try self.processExpr(f.object, seen);
                try self.processExpr(f.value, seen);
                seen.clearRetainingCapacity();
            },
            .compound_assignment => |c| {
                try self.processExpr(c.value, seen);
                if (c.target.* == .identifier) {
                    self.invalidate(c.target.identifier.name, seen);
                } else {
                    seen.clearRetainingCapacity();
                }
            },
            .expression => |e| try self.processExpr(e.expr, seen),
            .return_stmt => |r| if (r.value) |v| try self.processExpr(v, seen),
            .while_stmt => |w| {
                // 循环体独立作用域，处理完条件后用独立的 seen 集合分析循环体。
                try self.processExpr(w.condition, seen);
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(w.body, &body_seen);
                seen.clearRetainingCapacity();
            },
            .for_stmt => |f| {
                try self.processExpr(f.iterable, seen);
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(f.body, &body_seen);
                seen.clearRetainingCapacity();
            },
            .loop_stmt => |l| {
                var body_seen = std.ArrayListUnmanaged(SeenEntry).empty;
                defer body_seen.deinit(self.allocator);
                try self.processExpr(l.body, &body_seen);
                seen.clearRetainingCapacity();
            },
            .defer_stmt => |d| try self.processExpr(d.expr, seen),
            .throw_stmt => |t| try self.processExpr(t.expr, seen),
            .break_stmt, .continue_stmt => {},
        }
    }

    /// 失效所有读取指定变量的已见表达式，因为该变量已被重新赋值。
    fn invalidate(self: *CsePass, name: []const u8, seen: *std.ArrayListUnmanaged(SeenEntry)) void {
        _ = self;
        var i: usize = 0;
        while (i < seen.items.len) {
            if (exprReadsVar(seen.items[i].expr, name)) {
                _ = seen.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// 两个表达式的结构相等性判断。比较时忽略位置信息，仅比较语义内容。
fn exprEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (@intFromEnum(a.*) != @intFromEnum(b.*)) return false;
    return switch (a.*) {
        .int_literal => |ai| std.mem.eql(u8, ai.raw, b.int_literal.raw),
        .float_literal => |af| std.mem.eql(u8, af.raw, b.float_literal.raw),
        .bool_literal => |ab| ab.value == b.bool_literal.value,
        .char_literal => |ac| ac.value == b.char_literal.value,
        .string_literal => |as| std.mem.eql(u8, as.value, b.string_literal.value),
        .null_literal, .unit_literal => true,
        .identifier => |ai| std.mem.eql(u8, ai.name, b.identifier.name),
        .binary => |ab| ab.op == b.binary.op and exprEqual(ab.left, b.binary.left) and exprEqual(ab.right, b.binary.right),
        .unary => |au| au.op == b.unary.op and exprEqual(au.operand, b.unary.operand),
        .ref_of => |ar| exprEqual(ar.operand, b.ref_of.operand),
        .deref => |ad| exprEqual(ad.operand, b.deref.operand),
        else => a == b,
    };
}

/// 判断表达式是否读取了指定名称的变量。
fn exprReadsVar(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |id| std.mem.eql(u8, id.name, name),
        .binary => |b| exprReadsVar(b.left, name) or exprReadsVar(b.right, name),
        .unary => |u| exprReadsVar(u.operand, name),
        .ref_of => |r| exprReadsVar(r.operand, name),
        .deref => |d| exprReadsVar(d.operand, name),
        else => false,
    };
}

/// 判断二元表达式是否适合 CSE。仅纯算术 / 比较 / 位运算且操作数满足条件的表达式可消除。
fn isCseEligibleBinary(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .binary => |b| switch (b.op) {
            .add, .sub, .mul, .div, .mod,
            .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
            .bit_and, .bit_or, .bit_xor, .shl, .shr,
            => return isCseEligibleOperand(b.left) and isCseEligibleOperand(b.right),
            else => return false,
        },
        else => return false,
    }
}

/// 判断操作数是否适合 CSE：字面量、标识符或递归满足条件的二元 / 一元表达式。
fn isCseEligibleOperand(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .identifier,
        => true,
        .binary => isCseEligibleBinary(expr),
        .unary => |u| (u.op == .neg or u.op == .not) and isCseEligibleOperand(u.operand),
        // 取引用/解引用涉及地址语义，不作为 CSE 候选
        .ref_of, .deref => false,
        else => false,
    };
}

test "CseTable basic" {
    var table = CseTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    try std.testing.expect(table.canonicalOf(@constCast(&ast.Expr{ .int_literal = .{ .raw = "1", .suffix = null } })) == null);
}

test "exprEqual literals" {
    const a = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    const b = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    try std.testing.expect(exprEqual(&a, &b));
    const c = ast.Expr{ .int_literal = .{ .raw = "43", .suffix = null } };
    try std.testing.expect(!exprEqual(&a, &c));
}

test "exprReadsVar" {
    const expr = ast.Expr{ .identifier = .{ .name = "x" } };
    try std.testing.expect(exprReadsVar(&expr, "x"));
    try std.testing.expect(!exprReadsVar(&expr, "y"));
}
