//! comptime 内置类型名注册表（ir 模块用）
//!
//! 从 ChanType 枚举 comptime 派生 name → ChanType 查找表，
//! 消除 ir/ 中散落的 if-else 链（decl_collector/builder/expr_compiler）。
//!
//! 单一真相：ChanType 枚举字段名（去 `_chan` 后缀即为类型名）。
//! 新增标量只需在 ChanType 追加 `xxx_chan`，本文件自动覆盖。
//!
//! 注：sema/ 有独立的 builtin_types.zig（依赖 ScalarKind/builtin_type_descriptors），
//! ir/ 不能依赖 sema/，故本文件从 ChanType 直接派生，两者数据一致。

const std = @import("std");
const channel_mod = @import("channel.zig");
const value = @import("value");

const ChanType = channel_mod.ChanType;
const IntKind = value.scalar.IntKind;
const FloatKind = value.scalar.FloatKind;

/// 内置类型名条目（comptime 从 ChanType 枚举派生）
const BuiltinNameEntry = struct {
    name: []const u8,
    chan: ChanType,
};

/// comptime 计算有效标量条目数（跳过 null_chan/mask_chan/nullable_chan）
const SCALAR_COUNT = blk: {
    const fields = std.meta.fields(ChanType);
    var count: usize = 0;
    for (fields) |field| {
        const name = field.name;
        if (std.mem.eql(u8, name, "null_chan")) continue;
        if (std.mem.eql(u8, name, "mask_chan")) continue;
        if (std.mem.eql(u8, name, "nullable_chan")) continue;
        count += 1;
    }
    break :blk count;
};

/// comptime 构建：从 ChanType 枚举字段名去 `_chan` 后缀派生类型名
/// 仅保留标量类型（跳过 null_chan/mask_chan/nullable_chan 等非类型名条目）
const SCALAR_ENTRIES: [SCALAR_COUNT]BuiltinNameEntry = blk: {
    const fields = std.meta.fields(ChanType);
    var entries: [SCALAR_COUNT]BuiltinNameEntry = undefined;
    var idx: usize = 0;
    for (fields) |field| {
        const chan: ChanType = @enumFromInt(field.value);
        const name = field.name;
        // 跳过非类型名条目
        if (std.mem.eql(u8, name, "null_chan")) continue;
        if (std.mem.eql(u8, name, "mask_chan")) continue;
        if (std.mem.eql(u8, name, "nullable_chan")) continue;
        // 去掉 `_chan` 后缀得到类型名
        const type_name = name[0 .. name.len - 5];
        entries[idx] = .{ .name = type_name, .chan = chan };
        idx += 1;
    }
    break :blk entries;
};

/// 非标量内置类型（str 是堆引用，不在 ChanType 枚举中单独列出）
const NON_SCALAR_BUILTINS = [_]BuiltinNameEntry{
    .{ .name = "str", .chan = .ref_chan },
};

/// 内置类型名（标量 + str）→ ChanType，未匹配返回 null
pub fn chanTypeFromBuiltinName(name: []const u8) ?ChanType {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.chan;
    }
    inline for (NON_SCALAR_BUILTINS) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.chan;
    }
    return null;
}

/// 内置类型名（标量 + str）→ ChanType，未匹配返回 default（用户类型 → ref_chan）
pub inline fn chanTypeFromNameWithDefault(name: []const u8, default: ChanType) ChanType {
    return chanTypeFromBuiltinName(name) orelse default;
}

/// 标量名 → IntKind（非整数返回 null）
pub fn intKindFromName(name: []const u8) ?IntKind {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return switch (entry.chan) {
                .i8_chan => .i8,
                .i16_chan => .i16,
                .i32_chan => .i32,
                .i64_chan => .i64,
                .i128_chan => .i128,
                .u8_chan => .u8,
                .u16_chan => .u16,
                .u32_chan => .u32,
                .u64_chan => .u64,
                .u128_chan => .u128,
                .isize_chan => .isize,
                .usize_chan => .usize,
                else => null,
            };
        }
    }
    return null;
}

/// 标量名 → FloatKind（非浮点返回 null）
pub fn floatKindFromName(name: []const u8) ?FloatKind {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return switch (entry.chan) {
                .f16_chan => .f16,
                .f32_chan => .f32,
                .f64_chan => .f64,
                .f128_chan => .f128,
                else => null,
            };
        }
    }
    return null;
}

test "builtin_type_names: chanTypeFromBuiltinName 覆盖标量 + str" {
    try std.testing.expect(chanTypeFromBuiltinName("i8").? == .i8_chan);
    try std.testing.expect(chanTypeFromBuiltinName("u64").? == .u64_chan);
    try std.testing.expect(chanTypeFromBuiltinName("f64").? == .f64_chan);
    try std.testing.expect(chanTypeFromBuiltinName("bool").? == .bool_chan);
    try std.testing.expect(chanTypeFromBuiltinName("char").? == .char_chan);
    try std.testing.expect(chanTypeFromBuiltinName("str").? == .ref_chan);
    try std.testing.expect(chanTypeFromBuiltinName("unit").? == .unit_chan);
    try std.testing.expect(chanTypeFromBuiltinName("isize").? == .isize_chan);
    try std.testing.expect(chanTypeFromBuiltinName("usize").? == .usize_chan);
    try std.testing.expect(chanTypeFromBuiltinName("not_a_type") == null);
}

test "builtin_type_names: intKindFromName / floatKindFromName" {
    try std.testing.expect(intKindFromName("i32").? == .i32);
    try std.testing.expect(intKindFromName("u128").? == .u128);
    try std.testing.expect(intKindFromName("isize").? == .isize);
    try std.testing.expect(intKindFromName("f64") == null);
    try std.testing.expect(floatKindFromName("f64").? == .f64);
    try std.testing.expect(floatKindFromName("f128").? == .f128);
    try std.testing.expect(floatKindFromName("i32") == null);
}
