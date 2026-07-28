//! comptime 内置类型注册表（v3 阶段 10）
//!
//! 统一标量名 → ScalarKind / TypeDescriptor 的映射，
//! 消除 6 处散落的 if-else 链（type_resolver/inference/expr_compiler/decl_collector 等）。
//!
//! 数据源：type_descriptor.zig 的 lookupByScalarKind（单一真相）。
//! 本模块通过 comptime 反射派生 name → ScalarKind 查找表，
//! 新增标量只需在 lookupByScalarKind 追加一条，无需改本文件。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");
const type_descriptor_mod = @import("type_descriptor.zig");

const ScalarKind = type_descriptor_mod.ScalarKind;
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const IntKind = value.scalar.IntKind;
const FloatKind = value.scalar.FloatKind;

/// 内置标量名条目（comptime 从 lookupByScalarKind 派生）
const BuiltinNameEntry = struct {
    name: []const u8,
    kind: ScalarKind,
};

/// comptime 构建的内置标量名表（单一真相：lookupByScalarKind）
pub const BUILTIN_NAMES: []const BuiltinNameEntry = blk: {
    const fields = std.meta.fields(ScalarKind);
    var entries: [fields.len]BuiltinNameEntry = undefined;
    for (fields, 0..) |field, i| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const td = type_descriptor_mod.lookupByScalarKind(kind);
        entries[i] = .{ .name = td.type_name, .kind = kind };
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

/// 标量名 → TypeDescriptor
pub fn typeDescriptorFromName(name: []const u8) ?TypeDescriptor {
    inline for (BUILTIN_NAMES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return type_descriptor_mod.lookupByScalarKind(entry.kind).*;
        }
    }
    return null;
}

/// 标量名 → *const TypeDescriptor（指针版本，用于需要稳定地址的场景）
pub fn typeDescriptorPtrFromName(name: []const u8) ?*const TypeDescriptor {
    if (scalarKindFromName(name)) |kind| {
        return type_descriptor_mod.lookupByScalarKind(kind);
    }
    return null;
}

/// 内置类型名（含标量 + str/unit）→ *const TypeDescriptor，未匹配返回 null
pub fn typeDescriptorFromBuiltinName(name: []const u8) ?*const TypeDescriptor {
    if (typeDescriptorPtrFromName(name)) |td| return td;
    if (std.mem.eql(u8, name, "str")) return ir_mod.type_descriptor_mod.str_descriptor;
    if (std.mem.eql(u8, name, "void")) return ir_mod.type_descriptor_mod.unit_descriptor;
    return null;
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


