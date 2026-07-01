//! 自定义字符类型——Char 结构体
//!
//! 用 u32 直接存储 Unicode 码点（UTF-32）。
//! 完全自实现，不使用原生 char 类型。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");

/// 单个 Unicode 字符（UTF-32 码点存储）
pub const Char = struct {
    codepoint: u32,

    /// 从码点构造。校验 cp ≤ 0x10FFFF 且非代理区 (0xD800-0xDFFF)。
    pub fn fromCodePoint(cp: u21) error{InvalidCodePoint}!Char {
        if (cp > 0x10FFFF) return error.InvalidCodePoint;
        if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidCodePoint;
        return fromNativeUnchecked(cp);
    }

    /// 从原生 u21 构造（同 fromCodePoint，语义别名）
    pub fn fromNative(c: u21) error{InvalidCodePoint}!Char {
        return fromCodePoint(c);
    }

    inline fn fromNativeUnchecked(cp: u21) Char {
        return .{ .codepoint = @as(u32, cp) };
    }

    /// 转为码点
    pub inline fn toCodePoint(self: Char) u21 {
        return @intCast(self.codepoint);
    }

    /// 转为原生 u21（同 toCodePoint）
    pub inline fn toNative(self: Char) u21 {
        return self.toCodePoint();
    }

    /// 按码点数值比较
    pub inline fn compare(self: Char, other: Char) std.math.Order {
        return comparePortable(self, other);
    }

    inline fn comparePortable(self: Char, other: Char) std.math.Order {
        const a = self.toCodePoint();
        const b = other.toCodePoint();
        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }

    /// 相等
    pub inline fn equals(self: Char, other: Char) bool {
        return self.toCodePoint() == other.toCodePoint();
    }

    /// 后继字符（码点 +1，不校验，调用方负责语义）
    pub inline fn successor(self: Char) Char {
        return .{ .codepoint = self.codepoint +% 1 };
    }

    /// 前驱字符（码点 -1，不校验，调用方负责语义）
    pub inline fn predecessor(self: Char) Char {
        return .{ .codepoint = self.codepoint -% 1 };
    }

    /// 是否 ASCII（码点 ≤ 0x7F）
    pub inline fn isAscii(self: Char) bool {
        return self.toCodePoint() <= 0x7F;
    }

    /// 是否十进制数字 ('0'..'9')
    pub inline fn isDigit(self: Char) bool {
        const cp = self.toCodePoint();
        return cp >= '0' and cp <= '9';
    }

    /// 是否 ASCII 字母 ('a'..'z' 或 'A'..'Z')
    pub inline fn isAlpha(self: Char) bool {
        const cp = self.toCodePoint();
        return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
    }
};

// —— 测试 ——

test "Char.fromCodePoint/toCodePoint roundtrip" {
    const cases = [_]u21{ 0, 'A', 'Z', 'a', 'z', '0', '9', 0x7F, 0x80, '中', 0x4E2D, 0x1F600, 0x10FFFF };
    for (cases) |cp| {
        const c = try Char.fromCodePoint(cp);
        try std.testing.expectEqual(cp, c.toCodePoint());
    }
}

test "Char.fromCodePoint rejects invalid code points" {
    // 超出上限
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0x110000));
    // 代理区
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD800));
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xDFFF));
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD7FF + 1));
    // 边界合法值
    _ = try Char.fromCodePoint(0xD7FF);
    _ = try Char.fromCodePoint(0xE000);
    _ = try Char.fromCodePoint(0x10FFFF);
}

test "Char.compare and equals" {
    const a = try Char.fromCodePoint('A');
    const b = try Char.fromCodePoint('B');
    const a2 = try Char.fromCodePoint('A');
    try std.testing.expect(a.equals(a2));
    try std.testing.expect(!a.equals(b));
    try std.testing.expectEqual(std.math.Order.eq, a.compare(a2));
    try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
    try std.testing.expectEqual(std.math.Order.gt, b.compare(a));
}

test "Char.successor/predecessor" {
    const a = try Char.fromCodePoint('A');
    try std.testing.expectEqual(@as(u21, 'B'), a.successor().toCodePoint());
    try std.testing.expectEqual(@as(u21, '@'), a.predecessor().toCodePoint());

    const zhong = try Char.fromCodePoint('中');
    try std.testing.expectEqual(@as(u21, 0x4E2E), zhong.successor().toCodePoint());
    try std.testing.expectEqual(@as(u21, 0x4E2C), zhong.predecessor().toCodePoint());

    const emoji = try Char.fromCodePoint(0x1F600);
    try std.testing.expectEqual(@as(u21, 0x1F601), emoji.successor().toCodePoint());
    try std.testing.expectEqual(@as(u21, 0x1F5FF), emoji.predecessor().toCodePoint());

    // roundtrip: successor(predecessor(x)) == x
    try std.testing.expectEqual(@as(u21, 'A'), a.predecessor().successor().toCodePoint());
    try std.testing.expectEqual(@as(u21, 'A'), a.successor().predecessor().toCodePoint());
}

test "Char.isAscii/isDigit/isAlpha" {
    try std.testing.expect((try Char.fromCodePoint('A')).isAscii());
    try std.testing.expect((try Char.fromCodePoint('中')).isAscii() == false);
    try std.testing.expect((try Char.fromCodePoint(0x80)).isAscii() == false);

    try std.testing.expect((try Char.fromCodePoint('0')).isDigit());
    try std.testing.expect((try Char.fromCodePoint('9')).isDigit());
    try std.testing.expect((try Char.fromCodePoint('A')).isDigit() == false);
    try std.testing.expect((try Char.fromCodePoint('a')).isDigit() == false);

    try std.testing.expect((try Char.fromCodePoint('A')).isAlpha());
    try std.testing.expect((try Char.fromCodePoint('z')).isAlpha());
    try std.testing.expect((try Char.fromCodePoint('0')).isAlpha() == false);
    try std.testing.expect((try Char.fromCodePoint('中')).isAlpha() == false);
}

// ============================================================
// char→str UTF-8 编码测试：支撑 F1 修复（不截断 Unicode 码点）
// ============================================================

test "Char to UTF-8 encoding preserves codepoint (1-4 bytes)" {
    // F1: char→str 转换必须用 UTF-8 编码（1-4 字节），不能用 @intCast 截断为 u8。
    // 此测试验证 Char.toNative() + std.unicode.utf8Encode 对各码点区间的正确性。
    const Case = struct { cp: u21, expected: []const u8 };
    const cases = [_]Case{
        .{ .cp = 'A', .expected = "A" }, // 1 字节 (ASCII)
        .{ .cp = 'Z', .expected = "Z" },
        .{ .cp = 0x7F, .expected = "\x7F" }, // 1 字节边界
        .{ .cp = 0x80, .expected = "\xC2\x80" }, // 2 字节起始
        .{ .cp = 0x7FF, .expected = "\xDF\xBF" }, // 2 字节边界
        .{ .cp = 0x800, .expected = "\xE0\xA0\x80" }, // 3 字节起始
        .{ .cp = '中', .expected = "\xE4\xB8\xAD" }, // 3 字节（U+4E2D）
        .{ .cp = 0xFFFF, .expected = "\xEF\xBF\xBF" }, // 3 字节边界
        .{ .cp = 0x10000, .expected = "\xF0\x90\x80\x80" }, // 4 字节起始
        .{ .cp = 0x1F600, .expected = "\xF0\x9F\x98\x80" }, // 4 字节（😀）
        .{ .cp = 0x10FFFF, .expected = "\xF4\x8F\xBF\xBF" }, // 4 字节边界
    };
    for (cases) |c| {
        const ch = try Char.fromCodePoint(c.cp);
        const native = ch.toNative();
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(native, &buf);
        try std.testing.expectEqualStrings(c.expected, buf[0..len]);
    }
}

test "Char to UTF-8 encoding rejects surrogate halves" {
    // F1: 代理区码点不应被编码（Char.fromCodePoint 已拒绝，但验证不回归）
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD800));
    try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xDFFF));
}

test "Char to UTF-8 byte length matches codepoint range" {
    // 验证 UTF-8 编码长度规则：1/2/3/4 字节对应不同码点区间
    const Range = struct { cp: u21, expected_len: u3 };
    const ranges = [_]Range{
        .{ .cp = 0x00, .expected_len = 1 },
        .{ .cp = 0x7F, .expected_len = 1 },
        .{ .cp = 0x80, .expected_len = 2 },
        .{ .cp = 0x7FF, .expected_len = 2 },
        .{ .cp = 0x800, .expected_len = 3 },
        .{ .cp = 0xFFFF, .expected_len = 3 },
        .{ .cp = 0x10000, .expected_len = 4 },
        .{ .cp = 0x10FFFF, .expected_len = 4 },
    };
    for (ranges) |r| {
        const ch = try Char.fromCodePoint(r.cp);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(ch.toNative(), &buf);
        try std.testing.expectEqual(r.expected_len, len);
    }
}
