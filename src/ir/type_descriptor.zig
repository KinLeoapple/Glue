//! TypeDescriptor + ScalarOps vtable（类型定义部分）
//!
//! v3 spec §4.1: 替代 TypeKind 枚举 + ConcreteType 的统一类型描述符。
//! 所有类型（标量/引用/复合/容器）统一表示，递归 slots 支持任意嵌套。
//! scalar_ops vtable 消除标量读写 switch，增加类型只需追加 scalar_ops_table 条目。
//!
//! 本文件仅包含类型定义（TypeDescriptor/ScalarOps/Slot/SlotKind），
//! 供 ir 模块内部（sema_output.zig 等）直接引用，避免 ir → sema 循环依赖。
//! 标量 vtable 实现、scalar_ops_table、builtin_type_descriptors 等运行时数据
//! 仍留在 src/sema/type_descriptor.zig（sema 通过 ir import 引用此处类型）。

const std = @import("std");
const value = @import("value");
const channel_mod = @import("channel.zig");

const ChanType = channel_mod.ChanType;

/// 标量操作 vtable
pub const ScalarOps = struct {
    read: *const fn (ptr: *anyopaque) value.Value,
    write: *const fn (ptr: *anyopaque, v: value.Value) void,
    equal: *const fn (a: *anyopaque, b: *anyopaque) bool,
    format: *const fn (ptr: *anyopaque, buf: []u8) []const u8,
    hash: *const fn (ptr: *anyopaque) u64,
};

/// 复合类型 slot（统一 ADT/record/tuple/array/chan）
pub const Slot = struct {
    name: ?[]const u8, // positional 为 null
    offset: u32,
    type_desc: *const TypeDescriptor,
};

pub const SlotKind = enum {
    none, // 标量/引用
    named, // record（字段有名字）
    positional, // tuple/array（字段无名字）
    single, // chan（单一元素类型）
};

/// 统一类型描述符（替代 TypeKind 枚举 + ConcreteType）
pub const TypeDescriptor = struct {
    size: u8,
    alignment: u8,
    is_ref: bool,
    scalar_ops: ?*const ScalarOps = null,
    slots: []const Slot = &.{},
    slot_kind: SlotKind = .none,
    type_id: u16,
    type_name: []const u8,
    chan: ChanType,

    pub fn elemWidth(self: *const TypeDescriptor) u8 {
        return self.size;
    }
};

// ════════════════════════════════════════════════════════════
// builtin_chan_descriptors：每个 ChanType 对应的静态 TypeDescriptor
// ════════════════════════════════════════════════════════════
// v3 阶段 6：为 ChanSlot.type_desc 提供非空指针来源。
// 标量类型有 scalar_ops（sema 侧 builtin_type_descriptors 覆盖 18 种标量）；
// 非标量类型（ref_chan/nullable_chan/null_chan/unit_chan/mask_chan）scalar_ops=null，
// size/is_ref/chan 仍可用。nullable_chan 的 size=0（占位），实际宽度由 ChanSlot.width 持有。

/// 静态 TypeDescriptor 表，每个 ChanType 一条（21 条）。
/// 标量类型 type_id 从 1 起；非标量 type_id=0（无编译期类型 ID）。
pub const builtin_chan_descriptors: std.EnumArray(ChanType, TypeDescriptor) = .init(.{
    .i8_chan = .{ .size = 1, .alignment = 1, .is_ref = false, .type_id = 1, .type_name = "i8", .chan = .i8_chan },
    .i16_chan = .{ .size = 2, .alignment = 2, .is_ref = false, .type_id = 2, .type_name = "i16", .chan = .i16_chan },
    .i32_chan = .{ .size = 4, .alignment = 4, .is_ref = false, .type_id = 3, .type_name = "i32", .chan = .i32_chan },
    .i64_chan = .{ .size = 8, .alignment = 8, .is_ref = false, .type_id = 4, .type_name = "i64", .chan = .i64_chan },
    .i128_chan = .{ .size = 16, .alignment = 16, .is_ref = false, .type_id = 5, .type_name = "i128", .chan = .i128_chan },
    .u8_chan = .{ .size = 1, .alignment = 1, .is_ref = false, .type_id = 6, .type_name = "u8", .chan = .u8_chan },
    .u16_chan = .{ .size = 2, .alignment = 2, .is_ref = false, .type_id = 7, .type_name = "u16", .chan = .u16_chan },
    .u32_chan = .{ .size = 4, .alignment = 4, .is_ref = false, .type_id = 8, .type_name = "u32", .chan = .u32_chan },
    .u64_chan = .{ .size = 8, .alignment = 8, .is_ref = false, .type_id = 9, .type_name = "u64", .chan = .u64_chan },
    .u128_chan = .{ .size = 16, .alignment = 16, .is_ref = false, .type_id = 10, .type_name = "u128", .chan = .u128_chan },
    .isize_chan = .{ .size = @sizeOf(isize), .alignment = @alignOf(isize), .is_ref = false, .type_id = 11, .type_name = "isize", .chan = .isize_chan },
    .usize_chan = .{ .size = @sizeOf(usize), .alignment = @alignOf(usize), .is_ref = false, .type_id = 12, .type_name = "usize", .chan = .usize_chan },
    .f16_chan = .{ .size = 2, .alignment = 2, .is_ref = false, .type_id = 13, .type_name = "f16", .chan = .f16_chan },
    .f32_chan = .{ .size = 4, .alignment = 4, .is_ref = false, .type_id = 14, .type_name = "f32", .chan = .f32_chan },
    .f64_chan = .{ .size = 8, .alignment = 8, .is_ref = false, .type_id = 15, .type_name = "f64", .chan = .f64_chan },
    .f128_chan = .{ .size = 16, .alignment = 16, .is_ref = false, .type_id = 16, .type_name = "f128", .chan = .f128_chan },
    .bool_chan = .{ .size = 1, .alignment = 1, .is_ref = false, .type_id = 17, .type_name = "bool", .chan = .bool_chan },
    .char_chan = .{ .size = 4, .alignment = 4, .is_ref = false, .type_id = 18, .type_name = "char", .chan = .char_chan },
    .null_chan = .{ .size = 0, .alignment = 0, .is_ref = false, .type_id = 0, .type_name = "Null", .chan = .null_chan },
    .unit_chan = .{ .size = 0, .alignment = 0, .is_ref = false, .type_id = 0, .type_name = "Unit", .chan = .unit_chan },
    .ref_chan = .{ .size = 8, .alignment = 8, .is_ref = true, .type_id = 0, .type_name = "ref", .chan = .ref_chan },
    .mask_chan = .{ .size = 1, .alignment = 1, .is_ref = false, .type_id = 0, .type_name = "mask", .chan = .mask_chan },
    .nullable_chan = .{ .size = 0, .alignment = 0, .is_ref = false, .type_id = 0, .type_name = "nullable", .chan = .nullable_chan },
});

/// 按 ChanType 查找静态 TypeDescriptor（永不返回 null，所有 ChanType 均有条目）。
pub fn lookupChanDescriptor(ct: ChanType) *const TypeDescriptor {
    return builtin_chan_descriptors.getPtrConst(ct);
}
