//! comptime 内置类型名注册表（ir 模块用）
//!
//! 从标量类型名派生 name → *const TypeDescriptor / IntKind / FloatKind 查找表，
//! 消除 ir/ 中散落的 if-else 链（decl_collector/builder/expr_compiler）。
//!
//! 单一真相：type_descriptor.zig 的静态 TypeDescriptor 常量。
//! 新增标量只需在 type_descriptor.zig 追加描述符，本文件自动覆盖。
//!
//! 注：chanTypeFromTypeNode 已统一委托 sema/type_resolver.resolveChanType。
//! 本文件提供 intKindFromName/floatKindFromName/typeDescFromBuiltinName 等 ir 内部专用查询。

const std = @import("std");
const type_descriptor_mod = @import("type_descriptor.zig");
const value = @import("value");

const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const IntKind = value.scalar.IntKind;
const FloatKind = value.scalar.FloatKind;

/// 内置类型名条目（comptime 从标量描述符表派生）
const BuiltinNameEntry = struct {
    name: []const u8,
    type_desc: *const TypeDescriptor,
};

/// comptime 构建标量条目表（i8..char 共 18 种）
const SCALAR_ENTRIES = blk: {
    const descs = [_]struct { name: []const u8, desc: *const TypeDescriptor }{
        .{ .name = "i8", .desc = type_descriptor_mod.i8_descriptor },
        .{ .name = "i16", .desc = type_descriptor_mod.i16_descriptor },
        .{ .name = "i32", .desc = type_descriptor_mod.i32_descriptor },
        .{ .name = "i64", .desc = type_descriptor_mod.i64_descriptor },
        .{ .name = "i128", .desc = type_descriptor_mod.i128_descriptor },
        .{ .name = "u8", .desc = type_descriptor_mod.u8_descriptor },
        .{ .name = "u16", .desc = type_descriptor_mod.u16_descriptor },
        .{ .name = "u32", .desc = type_descriptor_mod.u32_descriptor },
        .{ .name = "u64", .desc = type_descriptor_mod.u64_descriptor },
        .{ .name = "u128", .desc = type_descriptor_mod.u128_descriptor },
        .{ .name = "isize", .desc = type_descriptor_mod.isize_descriptor },
        .{ .name = "usize", .desc = type_descriptor_mod.usize_descriptor },
        .{ .name = "f16", .desc = type_descriptor_mod.f16_descriptor },
        .{ .name = "f32", .desc = type_descriptor_mod.f32_descriptor },
        .{ .name = "f64", .desc = type_descriptor_mod.f64_descriptor },
        .{ .name = "f128", .desc = type_descriptor_mod.f128_descriptor },
        .{ .name = "bool", .desc = type_descriptor_mod.bool_descriptor },
        .{ .name = "char", .desc = type_descriptor_mod.char_descriptor },
    };
    var entries: [descs.len]BuiltinNameEntry = undefined;
    for (descs, 0..) |d, i| {
        entries[i] = .{ .name = d.name, .type_desc = d.desc };
    }
    break :blk entries;
};

/// 非标量内置类型（str 是堆引用，unit 是零字节类型）
const NON_SCALAR_BUILTINS = [_]struct { name: []const u8, type_desc: *const TypeDescriptor }{
    .{ .name = "str", .type_desc = type_descriptor_mod.ref_descriptor },
    .{ .name = "void", .type_desc = type_descriptor_mod.unit_descriptor },
};

/// 内置类型名（标量 + str/unit）→ *const TypeDescriptor，未匹配返回 null
pub fn typeDescFromBuiltinName(name: []const u8) ?*const TypeDescriptor {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.type_desc;
    }
    inline for (NON_SCALAR_BUILTINS) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.type_desc;
    }
    return null;
}

/// 内置类型名（标量 + str/unit）→ *const TypeDescriptor，未匹配返回 default
pub inline fn typeDescFromNameWithDefault(name: []const u8, default: *const TypeDescriptor) *const TypeDescriptor {
    return typeDescFromBuiltinName(name) orelse default;
}

/// 标量名 → IntKind（非整数返回 null）
pub fn intKindFromName(name: []const u8) ?IntKind {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.type_desc.toIntKind();
        }
    }
    return null;
}

/// 标量名 → FloatKind（非浮点返回 null）
pub fn floatKindFromName(name: []const u8) ?FloatKind {
    inline for (SCALAR_ENTRIES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.type_desc.toFloatKind();
        }
    }
    return null;
}

test "builtin_type_names: typeDescFromBuiltinName 覆盖标量 + str" {
    try std.testing.expectEqual(type_descriptor_mod.i8_descriptor, typeDescFromBuiltinName("i8").?);
    try std.testing.expectEqual(type_descriptor_mod.u64_descriptor, typeDescFromBuiltinName("u64").?);
    try std.testing.expectEqual(type_descriptor_mod.f64_descriptor, typeDescFromBuiltinName("f64").?);
    try std.testing.expectEqual(type_descriptor_mod.bool_descriptor, typeDescFromBuiltinName("bool").?);
    try std.testing.expectEqual(type_descriptor_mod.char_descriptor, typeDescFromBuiltinName("char").?);
    try std.testing.expectEqual(type_descriptor_mod.ref_descriptor, typeDescFromBuiltinName("str").?);
    try std.testing.expectEqual(type_descriptor_mod.unit_descriptor, typeDescFromBuiltinName("void").?);
    try std.testing.expectEqual(type_descriptor_mod.isize_descriptor, typeDescFromBuiltinName("isize").?);
    try std.testing.expectEqual(type_descriptor_mod.usize_descriptor, typeDescFromBuiltinName("usize").?);
    try std.testing.expect(typeDescFromBuiltinName("not_a_type") == null);
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
