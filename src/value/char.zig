//! 自定义字符类型——Char 结构体
//!
//! 用 [4]u8 字节数组存储 Unicode 码点（UTF-32 小端）。
//! 完全自实现，不使用原生 char 类型。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const byte_array = @import("byte_array.zig");
const loadWord = byte_array.loadWord;
const storeWord = byte_array.storeWord;

/// 单个 Unicode 字符（UTF-32 小端存储）
pub const Char = struct {
    bytes: [4]u8, // UTF-32 码点，小端

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

    fn fromNativeUnchecked(cp: u21) Char {
        var result: Char = .{ .bytes = undefined };
        storeWord(u32, &result.bytes, @as(u32, cp));
        return result;
    }

    /// 转为码点
    pub fn toCodePoint(self: Char) u21 {
        return @intCast(loadWord(u32, &self.bytes));
    }

    /// 转为原生 u21（同 toCodePoint）
    pub fn toNative(self: Char) u21 {
        return self.toCodePoint();
    }

    /// 按码点数值比较
    pub fn compare(self: Char, other: Char) std.math.Order {
        return comparePortable(self, other);
    }

    fn comparePortable(self: Char, other: Char) std.math.Order {
        const a = self.toCodePoint();
        const b = other.toCodePoint();
        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }

    /// 相等
    pub fn equals(self: Char, other: Char) bool {
        return self.toCodePoint() == other.toCodePoint();
    }

    /// 后继字符（码点 +1，u32 字块加法，不校验，调用方负责语义）
    pub fn successor(self: Char) Char {
        var result: Char = self;
        storeWord(u32, &result.bytes, loadWord(u32, &result.bytes) +% 1);
        return result;
    }

    /// 前驱字符（码点 -1，u32 字块减法，不校验，调用方负责语义）
    pub fn predecessor(self: Char) Char {
        var result: Char = self;
        storeWord(u32, &result.bytes, loadWord(u32, &result.bytes) -% 1);
        return result;
    }

    /// 是否 ASCII（码点 ≤ 0x7F）
    pub fn isAscii(self: Char) bool {
        return self.toCodePoint() <= 0x7F;
    }

    /// 是否十进制数字 ('0'..'9')
    pub fn isDigit(self: Char) bool {
        const cp = self.toCodePoint();
        return cp >= '0' and cp <= '9';
    }

    /// 是否 ASCII 字母 ('a'..'z' 或 'A'..'Z')
    pub fn isAlpha(self: Char) bool {
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
