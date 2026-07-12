//! Unicode 字符类型模块
//!
//! 定义 Glue 语言中的字符类型 Char，基于 Unicode 码点
//! 表示单个字符，提供码点验证、比较、判断等操作。

const std = @import("std");

/// Unicode 字符值，存储码点
pub const Char = struct {
codepoint: u32,

/// 从码点构造字符，拒绝超出范围或代理区的码点
pub fn fromCodePoint(cp: u21) error{InvalidCodePoint}!Char {
if (cp > 0x10FFFF) return error.InvalidCodePoint;
if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidCodePoint;
return fromNativeUnchecked(cp);
}

/// 从原生 u21 构造字符，带码点校验
pub fn fromNative(c: u21) error{InvalidCodePoint}!Char {
return fromCodePoint(c);
}

// 内部构造，跳过校验
inline fn fromNativeUnchecked(cp: u21) Char {
return .{ .codepoint = @as(u32, cp) };
}

/// 返回 Unicode 码点
pub inline fn toCodePoint(self: Char) u21 {
return @intCast(self.codepoint);
}

/// 返回原生 u21 表示
pub inline fn toNative(self: Char) u21 {
return self.toCodePoint();
}

/// 按码点大小比较
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

/// 判断两字符是否相等
pub inline fn equals(self: Char, other: Char) bool {
return self.toCodePoint() == other.toCodePoint();
}

/// 返回后继字符（码点加一，回绕）
pub inline fn successor(self: Char) Char {
return .{ .codepoint = self.codepoint +% 1 };
}

/// 返回前驱字符（码点减一，回绕）
pub inline fn predecessor(self: Char) Char {
return .{ .codepoint = self.codepoint -% 1 };
}

/// 判断是否为 ASCII 字符
pub inline fn isAscii(self: Char) bool {
return self.toCodePoint() <= 0x7F;
}

/// 判断是否为十进制数字
pub inline fn isDigit(self: Char) bool {
const cp = self.toCodePoint();
return cp >= '0' and cp <= '9';
}

/// 判断是否为字母
pub inline fn isAlpha(self: Char) bool {
const cp = self.toCodePoint();
return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
}
};

test "Char.fromCodePoint/toCodePoint roundtrip" {
const cases = [_]u21{ 0, 'A', 'Z', 'a', 'z', '0', '9', 0x7F, 0x80, '中', 0x4E2D, 0x1F600, 0x10FFFF };
for (cases) |cp| {
const c = try Char.fromCodePoint(cp);
try std.testing.expectEqual(cp, c.toCodePoint());
}
}

test "Char.fromCodePoint rejects invalid code points" {
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0x110000));
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD800));
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xDFFF));
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD7FF + 1));
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

test "Char to UTF-8 encoding preserves codepoint (1-4 bytes)" {
const Case = struct { cp: u21, expected: []const u8 };
const cases = [_]Case{
.{ .cp = 'A', .expected = "A" },
.{ .cp = 'Z', .expected = "Z" },
.{ .cp = 0x7F, .expected = "\x7F" },
.{ .cp = 0x80, .expected = "\xC2\x80" },
.{ .cp = 0x7FF, .expected = "\xDF\xBF" },
.{ .cp = 0x800, .expected = "\xE0\xA0\x80" },
.{ .cp = '中', .expected = "\xE4\xB8\xAD" },
.{ .cp = 0xFFFF, .expected = "\xEF\xBF\xBF" },
.{ .cp = 0x10000, .expected = "\xF0\x90\x80\x80" },
.{ .cp = 0x1F600, .expected = "\xF0\x9F\x98\x80" },
.{ .cp = 0x10FFFF, .expected = "\xF4\x8F\xBF\xBF" },
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
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xD800));
try std.testing.expectError(error.InvalidCodePoint, Char.fromCodePoint(0xDFFF));
}

test "Char to UTF-8 byte length matches codepoint range" {
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
