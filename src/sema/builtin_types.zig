//! comptime 内置类型注册表（v3 阶段 10）
//!
//! 统一标量名 → ScalarKind / ChanType / TypeDescriptor 的映射，
//! 消除 6 处散落的 if-else 链（type_resolver/inference/expr_compiler/decl_collector 等）。
//!
//! 数据源：type_descriptor.zig 的 builtin_type_descriptors（单一真相）。
//! 本模块通过 comptime 反射派生 name → ScalarKind / name → ChanType 查找表，
//! 新增标量只需在 builtin_type_descriptors 追加一条，无需改本文件。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");
const type_descriptor_mod = @import("type_descriptor.zig");

const ScalarKind = type_descriptor_mod.ScalarKind;
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const ChanType = ir_mod.ChanType;
const IntKind = value.scalar.IntKind;
const FloatKind = value.scalar.FloatKind;

/// 内置标量名条目（comptime 从 builtin_type_descriptors 派生）
const BuiltinNameEntry = struct {
    name: []const u8,
    kind: ScalarKind,
    chan: ChanType,
};

/// comptime 构建的内置标量名表（单一真相：builtin_type_descriptors）
pub const BUILTIN_NAMES: []const BuiltinNameEntry = blk: {
    const fields = std.meta.fields(ScalarKind);
    var entries: [fields.len]BuiltinNameEntry = undefined;
    for (fields, 0..) |field, i| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const td = type_descriptor_mod.builtin_type_descriptors.get(kind);
        entries[i] = .{ .name = td.type_name, .kind = kind, .chan = td.chan };
    }
    const final = entries;
    break :blk &final;
};

/// 标量名 → ScalarKind
pub fn scalarKindFromName(name: []const u8) ?ScalarKind {
    inline for (BUILTIN_NAMES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.kind;
    }
    return null;
}

/// 标量名 → ChanType
pub fn chanTypeFromName(name: []const u8) ?ChanType {
    inline for (BUILTIN_NAMES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.chan;
    }
    return null;
}

/// 标量名 → TypeDescriptor
pub fn typeDescriptorFromName(name: []const u8) ?TypeDescriptor {
    inline for (BUILTIN_NAMES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return type_descriptor_mod.builtin_type_descriptors.get(entry.kind);
        }
    }
    return null;
}

// ── 非标量内置类型（str/unit 等堆引用或零字节类型，不在 ScalarKind 中）──

const NonScalarBuiltin = struct {
    name: []const u8,
    chan: ChanType,
};

const NON_SCALAR_BUILTINS = [_]NonScalarBuiltin{
    .{ .name = "str", .chan = .ref_chan },
    .{ .name = "unit", .chan = .unit_chan },
};

/// 内置类型名（含标量 + str/unit）→ ChanType，未匹配返回 null
pub fn chanTypeFromBuiltinName(name: []const u8) ?ChanType {
    if (chanTypeFromName(name)) |ct| return ct;
    inline for (NON_SCALAR_BUILTINS) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.chan;
    }
    return null;
}

/// 内置类型名（含标量 + str/unit）→ ChanType，未匹配返回 default（用户类型 → ref_chan）
pub fn chanTypeFromNameWithDefault(name: []const u8, default: ChanType) ChanType {
    return chanTypeFromBuiltinName(name) orelse default;
}

/// 标量名 → IntKind（非整数标量返回 null）
pub fn intKindFromName(name: []const u8) ?IntKind {
    const kind = scalarKindFromName(name) orelse return null;
    return switch (kind) {
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .i128 => .i128,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .u128 => .u128,
        .isize => .isize,
        .usize => .usize,
        else => null,
    };
}

/// 标量名 → FloatKind（非浮点标量返回 null）
pub fn floatKindFromName(name: []const u8) ?FloatKind {
    const kind = scalarKindFromName(name) orelse return null;
    return switch (kind) {
        .f16 => .f16,
        .f32 => .f32,
        .f64 => .f64,
        .f128 => .f128,
        else => null,
    };
}

// ── 内置泛型类型构造器（高阶类型，固定 arity）──

/// 内置泛型类型条目
const BuiltinGenericEntry = struct {
    name: []const u8,
    arity: u8,
};

/// 内置泛型类型构造器表（单一真相）。
/// 新增内置泛型类型只需在此追加一条，type_check / kind_check 自动适配。
pub const BUILTIN_GENERIC_TYPES = [_]BuiltinGenericEntry{
    .{ .name = "Throw", .arity = 2 },
    .{ .name = "Atomic", .arity = 1 },
    .{ .name = "Async", .arity = 1 },
    .{ .name = "Channel", .arity = 1 },
    .{ .name = "Sender", .arity = 1 },
    .{ .name = "Receiver", .arity = 1 },
    .{ .name = "Lazy", .arity = 1 },
    .{ .name = "TypeInfo", .arity = 1 },
    .{ .name = "Reflect", .arity = 1 },
};

/// 内置泛型类型名 → arity（未匹配返回 null）
pub fn genericTypeArity(name: []const u8) ?u8 {
    inline for (BUILTIN_GENERIC_TYPES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.arity;
    }
    return null;
}

/// 判断 name 是否为内置泛型类型构造器
pub fn isBuiltinGenericType(name: []const u8) bool {
    return genericTypeArity(name) != null;
}

test "builtin_types: scalarKindFromName 覆盖所有内置标量" {
    try std.testing.expect(scalarKindFromName("i8").? == .i8);
    try std.testing.expect(scalarKindFromName("u8").? == .u8);
    try std.testing.expect(scalarKindFromName("i32").? == .i32);
    try std.testing.expect(scalarKindFromName("f64").? == .f64);
    try std.testing.expect(scalarKindFromName("bool").? == .bool);
    try std.testing.expect(scalarKindFromName("char").? == .char);
    try std.testing.expect(scalarKindFromName("not_a_type") == null);
}

test "builtin_types: chanTypeFromName 与 builtin_type_descriptors 一致" {
    for (BUILTIN_NAMES) |entry| {
        const chan = chanTypeFromName(entry.name).?;
        try std.testing.expect(chan == entry.chan);
    }
}

test "builtin_types: BUILTIN_NAMES 覆盖所有 ScalarKind 变体" {
    try std.testing.expect(BUILTIN_NAMES.len == std.meta.fields(ScalarKind).len);
}
