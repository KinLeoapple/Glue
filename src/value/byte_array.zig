//! 变长字节数组 union（小端补码存储）
//!
//! 同一位宽的 signed/unsigned 共用同一 union 变体（符号性由 Type 字段区分）。
//! 被 int.zig 和 float.zig 共用，作为底层字节存储。
//!
//! 字节 IO 原语（loadWord/storeWord/loadU128/storeU128）从 wide.zig 再导出，
//! 供 int.zig/float.zig/char.zig 共用。

const std = @import("std");
const wide = @import("wide.zig");
pub const U128 = wide.U128;

/// 变长字节数组 union（小端补码存储）
/// 同一位宽的 signed/unsigned 共用同一 union 变体（符号性由 Type 字段区分）
pub const ByteArray = union(enum) {
    b1: [1]u8, // i8/u8/f16
    b2: [2]u8, // i16/u16
    b4: [4]u8, // i32/u32/f32
    b8: [8]u8, // i64/u64/f64
    b16: [16]u8, // i128/u128/f128

    /// 返回有效字节数
    pub fn byteLength(self: ByteArray) u8 {
        return switch (self) {
            .b1 => 1,
            .b2 => 2,
            .b4 => 4,
            .b8 => 8,
            .b16 => 16,
        };
    }

    /// 构造零初始化的 ByteArray（用作算术结果容器，避免 r16 中间缓冲 + packFromBuffer 拷贝）
    pub fn zero(byte_len: u8) ByteArray {
        return switch (byte_len) {
            1 => .{ .b1 = [_]u8{0} },
            2 => .{ .b2 = [_]u8{0} ** 2 },
            4 => .{ .b4 = [_]u8{0} ** 4 },
            8 => .{ .b8 = [_]u8{0} ** 8 },
            16 => .{ .b16 = [_]u8{0} ** 16 },
            else => unreachable,
        };
    }

    /// 返回有效字节切片（只读）
    pub fn slice(self: *const ByteArray) []const u8 {
        return switch (self.*) {
            .b1 => &self.b1,
            .b2 => &self.b2,
            .b4 => &self.b4,
            .b8 => &self.b8,
            .b16 => &self.b16,
        };
    }

    /// 返回有效字节切片（可变）
    /// 注意：必须用 `&self.bN` 显式取字段指针，不能用 `switch (self.*) { .bN => |*b| b }`
    /// 后者在 release 模式下 b 可能指向临时值而非 self 内部，导致 extern 汇编写入错误位置。
    pub fn sliceMutable(self: *ByteArray) []u8 {
        return switch (self.*) {
            .b1 => &self.b1,
            .b2 => &self.b2,
            .b4 => &self.b4,
            .b8 => &self.b8,
            .b16 => &self.b16,
        };
    }
};

test "ByteArray.byteLength" {
    const ba1: ByteArray = .{ .b1 = [_]u8{0} };
    const ba2: ByteArray = .{ .b2 = [_]u8{0} ** 2 };
    const ba4: ByteArray = .{ .b4 = [_]u8{0} ** 4 };
    const ba8: ByteArray = .{ .b8 = [_]u8{0} ** 8 };
    const ba16: ByteArray = .{ .b16 = [_]u8{0} ** 16 };
    try std.testing.expectEqual(@as(u8, 1), ba1.byteLength());
    try std.testing.expectEqual(@as(u8, 2), ba2.byteLength());
    try std.testing.expectEqual(@as(u8, 4), ba4.byteLength());
    try std.testing.expectEqual(@as(u8, 8), ba8.byteLength());
    try std.testing.expectEqual(@as(u8, 16), ba16.byteLength());
}

test "ByteArray.zero" {
    const z1 = ByteArray.zero(1);
    try std.testing.expectEqual(@as(u8, 1), z1.byteLength());
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, z1.slice());

    const z4 = ByteArray.zero(4);
    try std.testing.expectEqual(@as(u8, 4), z4.byteLength());
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 4, z4.slice());

    const z16 = ByteArray.zero(16);
    try std.testing.expectEqual(@as(u8, 16), z16.byteLength());
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 16, z16.slice());
}

test "ByteArray.slice/sliceMutable" {
    var ba: ByteArray = .{ .b4 = [_]u8{ 0x01, 0x02, 0x03, 0x04 } };
    const s = ba.slice();
    try std.testing.expectEqual(@as(u8, 0x01), s[0]);
    try std.testing.expectEqual(@as(u8, 0x04), s[3]);

    const sm = ba.sliceMutable();
    sm[0] = 0xFF;
    try std.testing.expectEqual(@as(u8, 0xFF), ba.slice()[0]);
}

// ============================================================
// 字节 IO 原语（从 wide.zig 再导出 + U128 适配）
// ============================================================

pub const loadWord = wide.loadWord;
pub const storeWord = wide.storeWord;

/// 从 1/2/4/8/16 字节数组构造 U128（不足 16 字节高位补 0）
pub inline fn loadU128(bytes: []const u8) U128 {
    return switch (bytes.len) {
        1 => U128.fromU64(@as(u64, bytes[0])),
        2 => U128.fromU64(loadWord(u16, bytes)),
        4 => U128.fromU64(loadWord(u32, bytes)),
        8 => U128.fromU64(loadWord(u64, bytes)),
        16 => U128.load(bytes),
        else => unreachable,
    };
}

/// 将 U128 写入 N 字节数组（截取低 N 字节）
pub inline fn storeU128(bytes: []u8, val: U128) void {
    switch (bytes.len) {
        1 => bytes[0] = @truncate(val.lo),
        2 => storeWord(u16, bytes, @truncate(val.lo)),
        4 => storeWord(u32, bytes, @truncate(val.lo)),
        8 => storeWord(u64, bytes, val.lo),
        16 => val.store(bytes),
        else => unreachable,
    }
}

test "loadWord/storeWord" {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(@as(u32, 0x12345678), loadWord(u32, &bytes));

    var buf: [4]u8 = undefined;
    storeWord(u32, &buf, 0xDEADBEEF);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE }, &buf);
}

test "loadU128/storeU128" {
    // 1 字节
    {
        const bytes = [_]u8{0xAB};
        const v = loadU128(&bytes);
        try std.testing.expectEqual(U128.fromU64(0xAB), v);
        var buf: [1]u8 = undefined;
        storeU128(&buf, v);
        try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    }
    // 4 字节
    {
        const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
        const v = loadU128(&bytes);
        try std.testing.expectEqual(U128.fromU64(0x12345678), v);
        var buf: [4]u8 = undefined;
        storeU128(&buf, v);
        try std.testing.expectEqualSlices(u8, &bytes, &buf);
    }
    // 16 字节
    {
        var bytes: [16]u8 = undefined;
        @memset(&bytes, 0);
        bytes[0] = 0x42;
        const v = loadU128(&bytes);
        try std.testing.expectEqual(U128.fromU64(0x42), v);
        var buf: [16]u8 = undefined;
        storeU128(&buf, v);
        try std.testing.expectEqualSlices(u8, &bytes, &buf);
    }
}
