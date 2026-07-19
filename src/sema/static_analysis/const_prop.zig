//! 常量传播模块。
//!
//! 提供常量值表示（ConstValue）、表达式常量表（ConstTable）和作用域常量环境
//! （ConstEnv），以及二元 / 一元运算的常量折叠辅助函数。常量传播是其他优化
//! （分支可达性、CSE 等）的基础数据来源，由 fused_analysis 在跨函数分析时
//! 将结果写入 ConstTable。

const std = @import("std");
const ast = @import("ast");

/// 编译期可追踪的常量值。unknown 表示该表达式无法折叠为常量。
pub const ConstValue = union(enum) {
    int_val: i128,
    float_val: f64,
    bool_val: bool,
    unknown,

    /// 是否为整型常量。
    pub fn isInt(self: ConstValue) bool {
        return self == .int_val;
    }

    /// 是否为布尔常量。
    pub fn isBool(self: ConstValue) bool {
        return self == .bool_val;
    }
};

/// 表达式到常量值的映射表。键为 AST 表达式指针，值为折叠后的常量。
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

    /// 常量表是否为空。
    pub fn isEmpty(self: *const ConstTable) bool {
        return self.entries.count() == 0;
    }
};

/// 作用域常量环境。通过 parent 指针形成词法作用域链，用于跟踪变量名到常量值的绑定。
pub const ConstEnv = struct {
    parent: ?*ConstEnv,
    locals: std.StringHashMap(ConstValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*ConstEnv) ConstEnv {
        return .{
            .parent = parent,
            .locals = std.StringHashMap(ConstValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstEnv) void {
        self.locals.deinit();
    }

    /// 沿作用域链查找变量名对应的常量值。
    pub fn get(self: *const ConstEnv, name: []const u8) ?ConstValue {
        var cur: ?*const ConstEnv = self;
        while (cur) |e| {
            if (e.locals.get(name)) |v| return v;
            cur = e.parent;
        }
        return null;
    }

    pub fn put(self: *ConstEnv, name: []const u8, val: ConstValue) !void {
        try self.locals.put(name, val);
    }

    /// 移除变量绑定，用于变量被重新赋值为非常量时。
    pub fn remove(self: *ConstEnv, name: []const u8) void {
        _ = self.locals.remove(name);
    }
};

/// 对两个常量执行二元运算并返回折叠结果；任一操作数为 unknown 或运算不适用时返回 null。
fn evalBinary(op: ast.BinaryOp, lv: ConstValue, rv: ConstValue) ?ConstValue {
    if (lv == .unknown or rv == .unknown) return null;

    // 整型运算：除法 / 取模需防止除零。
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
            .shl => .{ .int_val = if (r < @bitSizeOf(@TypeOf(l))) l << @intCast(r) else 0 },
            .shr => .{ .int_val = l >> @intCast(@min(r, @bitSizeOf(@TypeOf(l)) - 1)) },
            .eq => .{ .bool_val = l == r },
            .not_eq => .{ .bool_val = l != r },
            .lt => .{ .bool_val = l < r },
            .gt => .{ .bool_val = l > r },
            .lt_eq => .{ .bool_val = l <= r },
            .gt_eq => .{ .bool_val = l >= r },
            else => null,
        };
    }

    // 浮点运算：除法需防止除零。
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

    // 布尔逻辑运算。
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

/// 对常量执行一元运算并返回折叠结果；运算不适用时返回 null。
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

/// 解析整型字面量字符串，支持十进制、十六进制（0x）、八进制（0o）、二进制（0b）以及下划线分隔。
fn parseIntLiteral(allocator: std.mem.Allocator, raw: []const u8) ?ConstValue {
    // 先剔除下划线分隔符。
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (raw) |c| {
        if (c != '_') clean.append(allocator, c) catch return null;
    }
    const bytes = clean.items;
    if (bytes.len == 0) return null;

    // 根据前缀判断进制。
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
