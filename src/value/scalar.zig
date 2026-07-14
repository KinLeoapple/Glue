//! 标量类型系统：ScalarTag 枚举、原生类型映射、字节宽度计算
//!
//! 所有数值类型通过 @bitCast 零成本转换为 Zig 原生类型进行运算

const std = @import("std");

/// 所有可字节编码的数值类型（无 f8）
pub const ScalarTag = enum(u8) {
    boolean, char,
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f128,
};

/// ScalarTag → Zig 原生类型的编译期映射
pub fn NativeType(comptime tag: ScalarTag) type {
    return switch (tag) {
        .boolean => bool,
        .char => u32,
        .i8 => i8, .i16 => i16, .i32 => i32, .i64 => i64, .i128 => i128,
        .u8 => u8, .u16 => u16, .u32 => u32, .u64 => u64, .u128 => u128,
        .f16 => f16, .f32 => f32, .f64 => f64, .f128 => f128,
    };
}

/// ScalarTag → 字节宽度
pub fn byteWidth(comptime tag: ScalarTag) usize {
    return @sizeOf(NativeType(tag));
}

/// ScalarTag → [N]u8 数组类型
pub fn ByteArray(comptime tag: ScalarTag) type {
    return [byteWidth(tag)]u8;
}

/// 所有 ScalarTag 值列表（用于 comptime 生成分派表）
pub const ALL_TAGS = [_]ScalarTag{
    .boolean, .char,
    .i8, .i16, .i32, .i64, .i128,
    .u8, .u16, .u32, .u64, .u128,
    .f16, .f32, .f64, .f128,
};

/// 整数子类型（用于层操作特化）
pub const IntKind = enum(u4) {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
};

/// 浮点子类型（无 f8）
pub const FloatKind = enum(u3) {
    f16, f32, f64, f128,
};

/// IntKind → Zig 原生类型
pub fn NativeIntType(comptime kind: IntKind) type {
    return switch (kind) {
        .i8 => i8, .i16 => i16, .i32 => i32, .i64 => i64, .i128 => i128,
        .u8 => u8, .u16 => u16, .u32 => u32, .u64 => u64, .u128 => u128,
    };
}

/// FloatKind → Zig 原生类型
pub fn NativeFloatType(comptime kind: FloatKind) type {
    return switch (kind) {
        .f16 => f16, .f32 => f32, .f64 => f64, .f128 => f128,
    };
}

/// 所有 IntKind 值列表
pub const ALL_INT_KINDS = [_]IntKind{
    .i8, .i16, .i32, .i64, .i128,
    .u8, .u16, .u32, .u64, .u128,
};

/// 所有 FloatKind 值列表
pub const ALL_FLOAT_KINDS = [_]FloatKind{
    .f16, .f32, .f64, .f128,
};
