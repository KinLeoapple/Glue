//! Pass 1：常量传播。
//!
//! 在函数内做前向数据流分析，追踪已知的常量绑定。
//! 编译器查询表达式是否为编译期常量，若是则直接发射 op_const 而非算术。
//!
//! 限制：仅分析函数体内的 val 绑定（不可变），不跨函数。

const std = @import("std");
const ast = @import("ast");

/// 常量值（仅基本类型）
pub const ConstValue = union(enum) {
    int_val: i128,
    float_val: f64,
    bool_val: bool,
    /// 非常量
    unknown,

    pub fn isInt(self: ConstValue) bool {
        return self == .int_val;
    }

    pub fn isBool(self: ConstValue) bool {
        return self == .bool_val;
    }
};

/// 表达式 → 常量值 的映射
pub const ConstTable = struct {
    entries: std.AutoHashMap(*const ast.Expr, ConstValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Expr, ConstValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *ConstTable, expr: *const ast.Expr, val: ConstValue) !void {
        try self.entries.put(expr, val);
    }

    pub fn lookup(self: *const ConstTable, expr: *const ast.Expr) ?ConstValue {
        return self.entries.get(expr);
    }

    pub fn isEmpty(self: *const ConstTable) bool {
        return self.entries.count() == 0;
    }
};

/// Pass 1：常量传播分析器
pub const ConstPropPass = struct {
    table: ConstTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstPropPass {
        return .{
            .table = ConstTable.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstPropPass) void {
        self.table.deinit();
    }

    pub fn analyzeModule(self: *ConstPropPass, module: *const ast.Module) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            // 每个函数独立分析（不跨函数传播）
            var env = std.StringHashMap(ConstValue).init(self.allocator);
            defer env.deinit();
            try self.analyzeExpr(decl.fun_decl.body, &env);
        }
    }

    fn analyzeExpr(self: *ConstPropPass, expr: *const ast.Expr, env: *std.StringHashMap(ConstValue)) anyerror!void {
        switch (expr.*) {
            .int_literal => |il| {
                const val = parseIntLiteral(self.allocator, il.raw) orelse ConstValue.unknown;
                try self.table.put(expr, val);
            },
            .float_literal => |fl| {
                if (std.fmt.parseFloat(f64, fl.raw)) |fval| {
                    try self.table.put(expr, .{ .float_val = fval });
                } else |_| {
                    try self.table.put(expr, ConstValue.unknown);
                }
            },
            .bool_literal => |bl| {
                try self.table.put(expr, .{ .bool_val = bl.value });
            },
            .identifier => |id| {
                if (env.get(id.name)) |val| {
                    try self.table.put(expr, val);
                }
            },
            .binary => |b| {
                try self.analyzeExpr(b.left, env);
                try self.analyzeExpr(b.right, env);

                // 尝试编译期求值
                const lv = self.table.lookup(b.left) orelse ConstValue.unknown;
                const rv = self.table.lookup(b.right) orelse ConstValue.unknown;
                if (evalBinary(b.op, lv, rv)) |result| {
                    try self.table.put(expr, result);
                }
            },
            .unary => |u| {
                try self.analyzeExpr(u.operand, env);
                const v = self.table.lookup(u.operand) orelse ConstValue.unknown;
                if (evalUnary(u.op, v)) |result| {
                    try self.table.put(expr, result);
                }
            },
            .if_expr => |i| {
                try self.analyzeExpr(i.condition, env);
                try self.analyzeExpr(i.then_branch, env);
                if (i.else_branch) |e| try self.analyzeExpr(e, env);
            },
            .block => |b| {
                // 块内 val 绑定加入 child env（不污染父环境）
                var child_env = std.StringHashMap(ConstValue).init(self.allocator);
                defer child_env.deinit();
                // 继承父环境
                var it = env.iterator();
                while (it.next()) |entry| {
                    try child_env.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                for (b.statements) |s| {
                    try self.analyzeStmt(s, &child_env);
                }
                if (b.trailing_expr) |te| try self.analyzeExpr(te, &child_env);
            },
            .call => |c| {
                try self.analyzeExpr(c.callee, env);
                for (c.arguments) |arg| try self.analyzeExpr(arg, env);
                // 函数调用结果不可静态求值（除非纯函数+常量参数，Phase 3 memoization 处理）
            },
            else => {},
        }
    }

    fn analyzeStmt(self: *ConstPropPass, stmt: *const ast.Stmt, env: *std.StringHashMap(ConstValue)) anyerror!void {
        switch (stmt.*) {
            .val_decl => |v| {
                try self.analyzeExpr(v.value, env);
                if (self.table.lookup(v.value)) |val| {
                    if (val != .unknown) {
                        try env.put(v.name, val);
                    }
                }
            },
            .var_decl => |v| {
                try self.analyzeExpr(v.value, env);
                // var 绑定不加入常量 env（可变）
            },
            .assignment => |a| {
                try self.analyzeExpr(a.value, env);
                // 赋值后该变量不再常量
                if (a.target.* == .identifier) {
                    _ = env.remove(a.target.identifier.name);
                }
            },
            .expression => |e| try self.analyzeExpr(e.expr, env),
            .return_stmt => |r| if (r.value) |v| try self.analyzeExpr(v, env),
            .for_stmt => |f| {
                try self.analyzeExpr(f.iterable, env);
                try self.analyzeExpr(f.body, env);
            },
            .while_stmt => |w| {
                try self.analyzeExpr(w.condition, env);
                try self.analyzeExpr(w.body, env);
            },
            .loop_stmt => |l| try self.analyzeExpr(l.body, env),
            else => {},
        }
    }
};

fn evalBinary(op: ast.BinaryOp, lv: ConstValue, rv: ConstValue) ?ConstValue {
    if (lv == .unknown or rv == .unknown) return null;

    // 整数算术
    if (lv == .int_val and rv == .int_val) {
        const l = lv.int_val;
        const r = rv.int_val;
        return switch (op) {
            .add => .{ .int_val = l + r },
            .sub => .{ .int_val = l - r },
            .mul => .{ .int_val = l * r },
            .div => if (r != 0) .{ .int_val = @divTrunc(l, r) } else null,
            .mod => if (r != 0) .{ .int_val = @rem(l, r) } else null,
            .bit_and => .{ .int_val = l & r },
            .bit_or => .{ .int_val = l | r },
            .bit_xor => .{ .int_val = l ^ r },
            .eq => .{ .bool_val = l == r },
            .not_eq => .{ .bool_val = l != r },
            .lt => .{ .bool_val = l < r },
            .gt => .{ .bool_val = l > r },
            .lt_eq => .{ .bool_val = l <= r },
            .gt_eq => .{ .bool_val = l >= r },
            else => null,
        };
    }

    // 浮点算术
    if (lv == .float_val and rv == .float_val) {
        const l = lv.float_val;
        const r = rv.float_val;
        return switch (op) {
            .add => .{ .float_val = l + r },
            .sub => .{ .float_val = l - r },
            .mul => .{ .float_val = l * r },
            .div => if (r != 0.0) .{ .float_val = l / r } else null,
            .eq => .{ .bool_val = l == r },
            .not_eq => .{ .bool_val = l != r },
            .lt => .{ .bool_val = l < r },
            .gt => .{ .bool_val = l > r },
            .lt_eq => .{ .bool_val = l <= r },
            .gt_eq => .{ .bool_val = l >= r },
            else => null,
        };
    }

    // 布尔逻辑
    if (lv == .bool_val and rv == .bool_val) {
        return switch (op) {
            .and_op => .{ .bool_val = lv.bool_val and rv.bool_val },
            .or_op => .{ .bool_val = lv.bool_val or rv.bool_val },
            .eq => .{ .bool_val = lv.bool_val == rv.bool_val },
            .not_eq => .{ .bool_val = lv.bool_val != rv.bool_val },
            else => null,
        };
    }

    return null;
}

fn evalUnary(op: ast.UnaryOp, v: ConstValue) ?ConstValue {
    return switch (v) {
        .int_val => |i| switch (op) {
            .neg => .{ .int_val = -i },
            else => null,
        },
        .float_val => |f| switch (op) {
            .neg => .{ .float_val = -f },
            else => null,
        },
        .bool_val => |b| switch (op) {
            .not => .{ .bool_val = !b },
            else => null,
        },
        .unknown => null,
    };
}

/// 解析整数字面量（支持 0x/0o/0b 前缀和 _ 分隔符）
fn parseIntLiteral(allocator: std.mem.Allocator, raw: []const u8) ?ConstValue {
    // 去除下划线
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (raw) |c| {
        if (c != '_') clean.append(allocator, c) catch return null;
    }
    const bytes = clean.items;
    if (bytes.len == 0) return null;

    // 判断进制
    if (bytes.len >= 2 and bytes[0] == '0') {
        if (bytes[1] == 'x' or bytes[1] == 'X') {
            const val = std.fmt.parseInt(i128, bytes[2..], 16) catch return null;
            return .{ .int_val = val };
        }
        if (bytes[1] == 'o' or bytes[1] == 'O') {
            const val = std.fmt.parseInt(i128, bytes[2..], 8) catch return null;
            return .{ .int_val = val };
        }
        if (bytes[1] == 'b' or bytes[1] == 'B') {
            const val = std.fmt.parseInt(i128, bytes[2..], 2) catch return null;
            return .{ .int_val = val };
        }
    }
    const val = std.fmt.parseInt(i128, bytes, 10) catch return null;
    return .{ .int_val = val };
}

test "ConstTable basic put/lookup" {
    var table = ConstTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expect(table.isEmpty());
    // 构造一个假 Expr 指针用于测试 lookup
    // 由于 ConstTable 用 *const ast.Expr 做键，这里仅测试空表行为
    // 完整的 put/lookup 测试需要 AST 节点，在集成测试中覆盖
}

test "ConstValue tags" {
    const v1: ConstValue = .{ .int_val = 42 };
    const v3: ConstValue = .{ .bool_val = true };
    const v4: ConstValue = .unknown;
    try std.testing.expect(v1.isInt());
    try std.testing.expect(!v1.isBool());
    try std.testing.expect(v3.isBool());
    try std.testing.expect(!v4.isInt());
}

test "evalBinary integer arithmetic" {
    const l: ConstValue = .{ .int_val = 6 };
    const r: ConstValue = .{ .int_val = 4 };
    try std.testing.expectEqual(@as(i128, 10), evalBinary(.add, l, r).?.int_val);
    try std.testing.expectEqual(@as(i128, 2), evalBinary(.sub, l, r).?.int_val);
    try std.testing.expectEqual(@as(i128, 24), evalBinary(.mul, l, r).?.int_val);
    try std.testing.expectEqual(@as(i128, 1), evalBinary(.div, l, r).?.int_val);
    try std.testing.expectEqual(true, evalBinary(.lt, r, l).?.bool_val);
    try std.testing.expectEqual(false, evalBinary(.gt, r, l).?.bool_val);
}

test "evalBinary float arithmetic" {
    const l: ConstValue = .{ .float_val = 6.0 };
    const r: ConstValue = .{ .float_val = 4.0 };
    try std.testing.expectEqual(@as(f64, 10.0), evalBinary(.add, l, r).?.float_val);
    try std.testing.expectEqual(@as(f64, 1.5), evalBinary(.div, l, r).?.float_val);
}

test "evalBinary boolean logic" {
    const t: ConstValue = .{ .bool_val = true };
    const f: ConstValue = .{ .bool_val = false };
    try std.testing.expectEqual(true, evalBinary(.and_op, t, t).?.bool_val);
    try std.testing.expectEqual(false, evalBinary(.and_op, t, f).?.bool_val);
    try std.testing.expectEqual(true, evalBinary(.or_op, f, t).?.bool_val);
}

test "evalBinary unknown returns null" {
    const u: ConstValue = .unknown;
    const l: ConstValue = .{ .int_val = 1 };
    try std.testing.expect(evalBinary(.add, u, l) == null);
    try std.testing.expect(evalBinary(.add, l, u) == null);
}

test "evalUnary neg and not" {
    const i: ConstValue = .{ .int_val = 5 };
    try std.testing.expectEqual(@as(i128, -5), evalUnary(.neg, i).?.int_val);
    const f: ConstValue = .{ .float_val = 2.5 };
    try std.testing.expectEqual(@as(f64, -2.5), evalUnary(.neg, f).?.float_val);
    const b: ConstValue = .{ .bool_val = true };
    try std.testing.expectEqual(false, evalUnary(.not, b).?.bool_val);
}

test "parseIntLiteral decimal hex octal binary" {
    const a = parseIntLiteral(std.testing.allocator, "42");
    try std.testing.expectEqual(@as(i128, 42), a.?.int_val);
    const b = parseIntLiteral(std.testing.allocator, "0xFF");
    try std.testing.expectEqual(@as(i128, 255), b.?.int_val);
    const c = parseIntLiteral(std.testing.allocator, "0o17");
    try std.testing.expectEqual(@as(i128, 15), c.?.int_val);
    const d = parseIntLiteral(std.testing.allocator, "0b1010");
    try std.testing.expectEqual(@as(i128, 10), d.?.int_val);
    const e = parseIntLiteral(std.testing.allocator, "1_000_000");
    try std.testing.expectEqual(@as(i128, 1000000), e.?.int_val);
}
