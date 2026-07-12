//! Value 内存布局常量（架构无关）。
//!
//! 定义 Value 联合体的字段偏移量、标签枚举值与类型枚举值，
//! 供 JIT 代码生成器在编译期引用这些固定布局以生成正确的内存访问指令。

const value = @import("value");

/// Value 的字节大小（编译期常量，用于 JIT 代码生成）。
pub const VALUE_SIZE: usize = @sizeOf(value.Value);
/// Value 的对齐要求。
pub const VALUE_ALIGN: usize = @alignOf(value.Value);

/// Value 标签在联合体中的偏移量。
/// Zig 的 union(enum) 将 tag 放在联合体末尾（offset 24）。
pub const TAG_OFFSET: usize = 24;
/// Value 负载（payload）的偏移量（联合体起始处）。
pub const PAYLOAD_OFFSET: usize = 0;
/// Int.lo 字段在 Value 中的偏移量。
/// Int 布局: { lo: u64, hi: u64, type: IntType, ... }
/// lo 在 payload 起始处 = offset 0。
pub const INT_LO_OFFSET: usize = 0;
/// Int.type 在 Value 中的偏移量。
pub const INT_TYPE_OFFSET: usize = 16;
/// Int.hi 在 Value 中的偏移量。
pub const INT_HI_OFFSET: usize = 8;

/// Float.bits 字段在 Value 中的偏移量。
/// Float 布局: { bits: u64, extra: u64, type: FloatType }
/// Zig 重排字段使 bits 在 offset 0。
pub const FLOAT_BITS_OFFSET: usize = @offsetOf(value.Float, "bits");
/// Float.extra 字段在 Value 中的偏移量。
pub const FLOAT_EXTRA_OFFSET: usize = @offsetOf(value.Float, "extra");
/// Float.type 字段在 Value 中的偏移量。
pub const FLOAT_TYPE_OFFSET: usize = @offsetOf(value.Float, "type");

/// Value 标签枚举值（对应 union(enum) 的变体顺序）。
pub const TAG_NULL: u8 = 0;
pub const TAG_UNIT: u8 = 1;
pub const TAG_BOOLEAN: u8 = 2;
pub const TAG_CHAR: u8 = 3;
pub const TAG_INT: u8 = 4;
pub const TAG_FLOAT: u8 = 5;
pub const TAG_STRING: u8 = 6;
pub const TAG_ARRAY: u8 = 7;

/// ArrayValue 字段偏移量。
/// ArrayValue { elements: []Value, capacity: usize, fixed_size: ?u64 }
/// []Value 是 fat pointer { ptr: [*]Value, len: usize }
/// elements.ptr 在 offset 0, elements.len 在 offset 8
pub const ARRAY_ELEMENTS_PTR_OFFSET: usize = 0;
pub const ARRAY_ELEMENTS_LEN_OFFSET: usize = 8;

/// Int.Type 枚举值（对应 IntType 的变体顺序）。
pub const INT_TYPE_I8: u8 = 0;
pub const INT_TYPE_I16: u8 = 1;
pub const INT_TYPE_I32: u8 = 2;
pub const INT_TYPE_I64: u8 = 3;
pub const INT_TYPE_U8: u8 = 4;
pub const INT_TYPE_U16: u8 = 5;
pub const INT_TYPE_U32: u8 = 6;
pub const INT_TYPE_U64: u8 = 7;
pub const INT_TYPE_I128: u8 = 8;

/// Float.Type 枚举值（对应 FloatType 的变体顺序）。
pub const FLOAT_TYPE_F8: u8 = 0;
pub const FLOAT_TYPE_F16: u8 = 1;
pub const FLOAT_TYPE_F32: u8 = 2;
pub const FLOAT_TYPE_F64: u8 = 3;
pub const FLOAT_TYPE_F128: u8 = 4;

test "Value 布局常量验证" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 0), INT_LO_OFFSET);
    try std.testing.expectEqual(@as(usize, 8), INT_HI_OFFSET);
    try std.testing.expectEqual(@as(usize, 16), INT_TYPE_OFFSET);
    try std.testing.expectEqual(@as(usize, 24), TAG_OFFSET);
    std.debug.print("\nValue size: {}\n", .{@sizeOf(value.Value)});
    std.debug.print("Float.bits offset: {}\n", .{FLOAT_BITS_OFFSET});
    std.debug.print("Float.type offset: {}\n", .{FLOAT_TYPE_OFFSET});
    std.debug.print("Float.extra offset: {}\n", .{FLOAT_EXTRA_OFFSET});
}
