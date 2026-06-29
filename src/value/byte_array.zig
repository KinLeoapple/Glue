//! 变长字节数组 union（小端补码存储）
//!
//! 同一位宽的 signed/unsigned 共用同一 union 变体（符号性由 Type 字段区分）。
//! 被 int.zig 和 float.zig 共用，作为底层字节存储。

const std = @import("std");

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

    /// 返回有效字节切片（只读）
    pub fn slice(self: *const ByteArray) []const u8 {
        return switch (self.*) {
            .b1 => |*b| b,
            .b2 => |*b| b,
            .b4 => |*b| b,
            .b8 => |*b| b,
            .b16 => |*b| b,
        };
    }

    /// 返回有效字节切片（可变）
    pub fn sliceMutable(self: *ByteArray) []u8 {
        return switch (self.*) {
            .b1 => |*b| b,
            .b2 => |*b| b,
            .b4 => |*b| b,
            .b8 => |*b| b,
            .b16 => |*b| b,
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

test "ByteArray.slice/sliceMutable" {
    var ba: ByteArray = .{ .b4 = [_]u8{ 0x01, 0x02, 0x03, 0x04 } };
    const s = ba.slice();
    try std.testing.expectEqual(@as(u8, 0x01), s[0]);
    try std.testing.expectEqual(@as(u8, 0x04), s[3]);

    const sm = ba.sliceMutable();
    sm[0] = 0xFF;
    try std.testing.expectEqual(@as(u8, 0xFF), ba.slice()[0]);
}
