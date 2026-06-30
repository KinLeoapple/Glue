//! 自定义字符类型——Char 结构体
//!
//! 用 [4]u8 字节数组存储 Unicode 码点（UTF-32 小端）。
//! 完全自实现，不使用原生 char 类型。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const builtin = @import("builtin");

// x86_64 汇编 extern 声明（符号定义在 arch/x86_64/char.S；大写 S 走 C 预处理器）
extern fn glue_cmp_char(a: [*]const u8, b: [*]const u8) i8;
extern fn glue_succ_char(out: [*]u8, a: [*]const u8) void;
extern fn glue_pred_char(out: [*]u8, a: [*]const u8) void;
extern fn glue_is_ascii_char(a: [*]const u8) u8;
extern fn glue_is_digit_char(a: [*]const u8) u8;
extern fn glue_is_alpha_char(a: [*]const u8) u8;

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
        const v: u32 = @intCast(cp);
        return .{ .bytes = .{
            @truncate(v & 0xFF),
            @truncate((v >> 8) & 0xFF),
            @truncate((v >> 16) & 0xFF),
            0,
        } };
    }

    /// 转为码点
    pub fn toCodePoint(self: Char) u21 {
        const v: u32 = @as(u32, self.bytes[0]) |
            (@as(u32, self.bytes[1]) << 8) |
            (@as(u32, self.bytes[2]) << 16);
        return @intCast(v);
    }

    /// 转为原生 u21（同 toCodePoint）
    pub fn toNative(self: Char) u21 {
        return self.toCodePoint();
    }

    /// 按码点数值比较
    /// 架构分派：x86_64 走汇编 glue_cmp_char，其他走 comparePortable。
    pub fn compare(self: Char, other: Char) std.math.Order {
        return switch (builtin.cpu.arch) {
            .x86_64 => switch (glue_cmp_char(&self.bytes, &other.bytes)) {
                -1 => .lt,
                0 => .eq,
                1 => .gt,
                else => unreachable,
            },
            else => comparePortable(self, other),
        };
    }

    /// 便携软件实现（非 x86_64 架构回退路径）
    fn comparePortable(self: Char, other: Char) std.math.Order {
        const a = self.toCodePoint();
        const b = other.toCodePoint();
        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }

    /// 相等
    /// 架构分派：x86_64 复用 glue_cmp_char == 0，其他走码点比较。
    pub fn equals(self: Char, other: Char) bool {
        return switch (builtin.cpu.arch) {
            .x86_64 => glue_cmp_char(&self.bytes, &other.bytes) == 0,
            else => self.toCodePoint() == other.toCodePoint(),
        };
    }

    /// 后继字符（码点 +1，字节进位运算，不校验，调用方负责语义）
    /// 架构分派：x86_64 走汇编 glue_succ_char，其他走字节循环。
    pub fn successor(self: Char) Char {
        var result: Char = undefined;
        switch (builtin.cpu.arch) {
            .x86_64 => glue_succ_char(&result.bytes, &self.bytes),
            else => {
                result = self;
                var carry: u16 = 1;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    const sum: u16 = @as(u16, result.bytes[i]) + carry;
                    result.bytes[i] = @truncate(sum);
                    carry = sum >> 8;
                }
            },
        }
        return result;
    }

    /// 前驱字符（码点 -1，字节借位运算，不校验，调用方负责语义）
    /// 架构分派：x86_64 走汇编 glue_pred_char，其他走字节循环。
    pub fn predecessor(self: Char) Char {
        var result: Char = undefined;
        switch (builtin.cpu.arch) {
            .x86_64 => glue_pred_char(&result.bytes, &self.bytes),
            else => {
                result = self;
                var borrow: u16 = 1;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    const v: u16 = @as(u16, result.bytes[i]);
                    if (v >= borrow) {
                        result.bytes[i] = @truncate(v - borrow);
                        borrow = 0;
                    } else {
                        result.bytes[i] = @truncate(256 - borrow + v);
                        borrow = 1;
                    }
                }
            },
        }
        return result;
    }

    /// 是否 ASCII（码点 ≤ 0x7F）
    /// 架构分派：x86_64 走汇编 glue_is_ascii_char，其他走码点比较。
    pub fn isAscii(self: Char) bool {
        return switch (builtin.cpu.arch) {
            .x86_64 => glue_is_ascii_char(&self.bytes) != 0,
            else => self.toCodePoint() <= 0x7F,
        };
    }

    /// 是否十进制数字 ('0'..'9')
    /// 架构分派：x86_64 走汇编 glue_is_digit_char，其他走码点范围检查。
    pub fn isDigit(self: Char) bool {
        return switch (builtin.cpu.arch) {
            .x86_64 => glue_is_digit_char(&self.bytes) != 0,
            else => blk: {
                const cp = self.toCodePoint();
                break :blk cp >= '0' and cp <= '9';
            },
        };
    }

    /// 是否 ASCII 字母 ('a'..'z' 或 'A'..'Z')
    /// 架构分派：x86_64 走汇编 glue_is_alpha_char，其他走码点范围检查。
    pub fn isAlpha(self: Char) bool {
        return switch (builtin.cpu.arch) {
            .x86_64 => glue_is_alpha_char(&self.bytes) != 0,
            else => blk: {
                const cp = self.toCodePoint();
                break :blk (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
            },
        };
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
