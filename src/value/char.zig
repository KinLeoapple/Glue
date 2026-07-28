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
