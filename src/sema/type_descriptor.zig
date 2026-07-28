//! TypeDescriptor sema 侧扩展（ScalarKind 枚举 + lookupByScalarKind）
//!
//! v3 spec §4.1: 替代 TypeKind 枚举 + ConcreteType 的统一类型描述符。
//!
//! 标量 vtable 实现（read/write/equal/format/hash）已迁至 src/ir/type_descriptor.zig。
//! 本文件保留 sema 侧所需的 ScalarKind 枚举和 lookupByScalarKind 函数，
//! 通过委托 ir 侧的静态描述符保证指针唯一性，避免实现重复。

const std = @import("std");
const value = @import("value");
const ir_mod = @import("ir");

// 类型定义已移至 ir/type_descriptor.zig，此处重导出以保持下游引用兼容
pub const TypeDescriptor = ir_mod.type_descriptor_mod.TypeDescriptor;
pub const ScalarOps = ir_mod.type_descriptor_mod.ScalarOps;
pub const Slot = ir_mod.type_descriptor_mod.Slot;
pub const SlotKind = ir_mod.type_descriptor_mod.SlotKind;

/// 标量种类（对应 scalar_ops_table 的 key）
pub const ScalarKind = enum {
    i8, u8, i16, u16, i32, u32, i64, u64, i128, u128, isize, usize,
    f16, f32, f64, f128, bool, char,
};

// ════════════════════════════════════════════════════════════
// scalar_ops_table：引用 ir 侧已实现的 ScalarOps 常量
// ════════════════════════════════════════════════════════════

pub const scalar_ops_table: std.EnumArray(ScalarKind, ScalarOps) = .init(.{
    .i8 = ir_mod.type_descriptor_mod.i8_ops,
    .u8 = ir_mod.type_descriptor_mod.u8_ops,
    .i16 = ir_mod.type_descriptor_mod.i16_ops,
    .u16 = ir_mod.type_descriptor_mod.u16_ops,
    .i32 = ir_mod.type_descriptor_mod.i32_ops,
    .u32 = ir_mod.type_descriptor_mod.u32_ops,
    .i64 = ir_mod.type_descriptor_mod.i64_ops,
    .u64 = ir_mod.type_descriptor_mod.u64_ops,
    .i128 = ir_mod.type_descriptor_mod.i128_ops,
    .u128 = ir_mod.type_descriptor_mod.u128_ops,
    .isize = ir_mod.type_descriptor_mod.isize_ops,
    .usize = ir_mod.type_descriptor_mod.usize_ops,
    .f16 = ir_mod.type_descriptor_mod.f16_ops,
    .f32 = ir_mod.type_descriptor_mod.f32_ops,
    .f64 = ir_mod.type_descriptor_mod.f64_ops,
    .f128 = ir_mod.type_descriptor_mod.f128_ops,
    .bool = ir_mod.type_descriptor_mod.bool_ops,
    .char = ir_mod.type_descriptor_mod.char_ops,
});

/// 按 ScalarKind 查找 *const TypeDescriptor（委托给 ir 侧的静态描述符，保证指针一致性）
pub fn lookupByScalarKind(kind: ScalarKind) *const TypeDescriptor {
    return switch (kind) {
        .i8 => ir_mod.type_descriptor_mod.i8_descriptor,
        .u8 => ir_mod.type_descriptor_mod.u8_descriptor,
        .i16 => ir_mod.type_descriptor_mod.i16_descriptor,
        .u16 => ir_mod.type_descriptor_mod.u16_descriptor,
        .i32 => ir_mod.type_descriptor_mod.i32_descriptor,
        .u32 => ir_mod.type_descriptor_mod.u32_descriptor,
        .i64 => ir_mod.type_descriptor_mod.i64_descriptor,
        .u64 => ir_mod.type_descriptor_mod.u64_descriptor,
        .i128 => ir_mod.type_descriptor_mod.i128_descriptor,
        .u128 => ir_mod.type_descriptor_mod.u128_descriptor,
        .isize => ir_mod.type_descriptor_mod.isize_descriptor,
        .usize => ir_mod.type_descriptor_mod.usize_descriptor,
        .f16 => ir_mod.type_descriptor_mod.f16_descriptor,
        .f32 => ir_mod.type_descriptor_mod.f32_descriptor,
        .f64 => ir_mod.type_descriptor_mod.f64_descriptor,
        .f128 => ir_mod.type_descriptor_mod.f128_descriptor,
        .bool => ir_mod.type_descriptor_mod.bool_descriptor,
        .char => ir_mod.type_descriptor_mod.char_descriptor,
    };
}

/// 兼容旧代码的别名：builtin_type_descriptors.getPtrConst(kind) → lookupByScalarKind(kind)
pub fn builtinTypeDescriptorPtr(kind: ScalarKind) *const TypeDescriptor {
    return lookupByScalarKind(kind);
}


