//! 类型检查与推断模块。
//!
//! 实现基于 Hindley-Milner 的类型推断系统，包括类型统一（unification）、泛化
//! （generalization）、实例化（instantiate）、子类型判定和 trait 约束求解。
//! TypeInferencer 是核心结构，负责对 AST 进行类型推断并收集类型错误。
//! 子模块 subtype_check、trait_resolve、throw_check、kind_check、gadt_check、
//! module_check 分别处理子类型、trait 解析、throw 类型、kind 检查、GADT 精化和
//! 模块检查等专门职责。

const std = @import("std");
const ast = @import("ast");
const ir = @import("ir");
const glue_builtin = @import("glue_builtin");
const subtype_check = @import("subtype_check");
const trait_resolve = @import("trait_resolve");
const throw_check = @import("throw_check");
const kind_check = @import("kind_check");
const gadt_check = @import("gadt_check");
const module_check = @import("module_check");

/// SemaResult 契约类型（来自 ir 模块）：sema 产出、builder 消费的表达式类型映射。
const SemaResult = ir.SemaResult;
const ExprInfo = ir.ExprInfo;
const ChanType = ir.ChanType;
const ConstVal = ir.ConstVal;
const TypeDefInfo = ir.sema_output_mod.TypeDefInfo;
const CtorDefInfo = ir.sema_output_mod.CtorDefInfo;
const TraitDefInfo = ir.sema_output_mod.TraitDefInfo;
const FuncSigInfo = ir.sema_output_mod.FuncSigInfo;
const TraitMethodSig = ir.sema_output_mod.TraitMethodSig;
const FnSigRef = ir.sema_output_mod.FnSigRef;
const TypeDefKind = ir.sema_output_mod.TypeDefKind;

/// 将 sema 内部 Type 表示转换为 IR 的 ChanType（决定通道宽度）。
/// 标量类型直接映射；复合类型（record/adt/array/fn/generic/trait）→ ref_chan（堆引用）；
/// nullable/throw 递归取内部类型；type_var/unknown 返回 null（无法静态确定）。
fn semaTypeToChanType(ty: *Type) ?ChanType {
    return switch (ty.*) {
        .i8_type => .i8_chan,
        .i16_type => .i16_chan,
        .i32_type => .i32_chan,
        .i64_type => .i64_chan,
        .i128_type => .i128_chan,
        .u8_type => .u8_chan,
        .u16_type => .u16_chan,
        .u32_type => .u32_chan,
        .u64_type => .u64_chan,
        .u128_type => .u128_chan,
        .isize_type => .isize_chan,
        .usize_type => .usize_chan,
        .f16_type => .f16_chan,
        .f32_type => .f32_chan,
        .f64_type => .f64_chan,
        .f128_type => .f128_chan,
        .bool_type => .bool_chan,
        .str_type => .ref_chan,
        .char_type => .char_chan,
        .null_type => .null_chan,
        .unit_type => .unit_chan,
        .record_type, .adt_type, .array_type, .fn_type, .generic_type, .trait_type => .ref_chan,
        .nullable_type => |inner| blk: {
            const inner_ct = semaTypeToChanType(inner) orelse .ref_chan;
            break :blk inner_ct;
        },
        .ref_type => .ref_chan,
        .throw_type => |tt| semaTypeToChanType(tt.value_type) orelse .ref_chan,
        .type_var, .unknown_type => null,
    };
}

/// 提取类型的名字（adt_type.name / generic_type.name），无法提取返回 null。
/// ref_type 和 nullable_type 会递归到内部类型，以便 trait 方法体内 `self`
/// （sema 推导为 ref_type）仍能正确解析出所属 ADT/Trait 名字。
fn typeNameOfType(ty: *Type) ?[]const u8 {
    return switch (ty.*) {
        .adt_type => |at| at.name,
        .generic_type => |gt| gt.name,
        .trait_type => |tt| tt.name,
        .ref_type => |rt| typeNameOfType(rt.inner),
        .nullable_type => |inner| typeNameOfType(inner),
        else => null,
    };
}

/// 批量将 Type 列表转换为 ChanType 列表，无法确定的类型回退为 ref_chan。
fn typesToChanTypes(allocator: std.mem.Allocator, types: []const *Type) ![]const ChanType {
    const result = try allocator.alloc(ChanType, types.len);
    for (types, 0..) |t, i| {
        result[i] = semaTypeToChanType(t) orelse .ref_chan;
    }
    return result;
}

/// 批量提取类型名列表，无法提取的元素为 null。
fn typeNamesOfTypes(allocator: std.mem.Allocator, types: []const *Type) ![]const ?[]const u8 {
    const result = try allocator.alloc(?[]const u8, types.len);
    for (types, 0..) |t, i| {
        result[i] = typeNameOfType(t);
    }
    return result;
}

var next_type_id: usize = 0;

const SINGLETON_COUNT: usize = 22;
fn singletonIdx(tag: Type) usize {
    return switch (tag) {
        .i8_type => 0,
        .i16_type => 1,
        .i32_type => 2,
        .i64_type => 3,
        .i128_type => 4,
        .u8_type => 5,
        .u16_type => 6,
        .u32_type => 7,
        .u64_type => 8,
        .u128_type => 9,
        .f16_type => 10,
        .f32_type => 11,
        .f64_type => 12,
        .f128_type => 13,
        .bool_type => 14,
        .str_type => 15,
        .char_type => 16,
        .null_type => 17,
        .unit_type => 18,
        .unknown_type => 19,
        .isize_type => 20,
        .usize_type => 21,
        else => SINGLETON_COUNT,
    };
}
/// Glue 语言的类型表示。涵盖基本类型（整型、浮点、布尔、字符串等）、类型变量、
/// 函数类型、记录类型、ADT 类型、可空类型、泛型类型、数组类型、throw 类型和 trait 类型。
pub const Type = union(enum) {
    i8_type,
    i16_type,
    i32_type,
    i64_type,
    i128_type,
    u8_type,
    u16_type,
    u32_type,
    u64_type,
    u128_type,
    isize_type,
    usize_type,
    f16_type,
    f32_type,
    f64_type,
    f128_type,
    bool_type,
    str_type,
    char_type,
    null_type,
    unit_type,
    type_var: *TypeVar,
    fn_type: struct {
        params: []*Type,
        return_type: *Type,
    },
    record_type: struct {
        fields: []FieldType,
    },
    adt_type: struct {
        name: []const u8,
        type_args: []*Type,
    },
    nullable_type: *Type,
    generic_type: struct {
        name: []const u8,
        args: []*Type,
    },
    array_type: struct {
        element_type: *Type,
        size: ?u64,
    },
    throw_type: struct {
        value_type: *Type,
        error_type: *Type,
    },
    trait_type: struct {
        name: []const u8,
        type_args: []*Type,
    },
    /// 借用引用 &T 或裸指针 *T：指向已有对象，通道存指针
    ref_type: struct {
        inner: *Type,
        is_raw: bool,
    },
    unknown_type,

    pub fn isIntType(self: Type) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type, .u8_type, .u16_type, .u32_type, .u64_type, .u128_type, .isize_type, .usize_type => true,
            else => false,
        };
    }
    pub fn isFloatType(self: Type) bool {
        return switch (self) {
            .f16_type, .f32_type, .f64_type, .f128_type => true,
            else => false,
        };
    }

    // ── Phase 4 isWidening 辅助函数（按 spec §4.2 / §7.2 精确路径表）──

    /// 整数类型的位宽（isize/usize 跟随平台位宽）
    pub fn intTypeBitWidth(self: Type) ?u16 {
        return switch (self) {
            .i8_type, .u8_type => 8,
            .i16_type, .u16_type => 16,
            .i32_type, .u32_type => 32,
            .i64_type, .u64_type => 64,
            .i128_type, .u128_type => 128,
            .isize_type, .usize_type => @intCast(@bitSizeOf(isize)),
            else => null,
        };
    }

    /// 浮点类型的位宽
    pub fn floatTypeBitWidth(self: Type) ?u16 {
        return switch (self) {
            .f16_type => 16,
            .f32_type => 32,
            .f64_type => 64,
            .f128_type => 128,
            else => null,
        };
    }

    /// 整数是否为有符号类型
    pub fn isSignedIntType(self: Type) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type, .isize_type => true,
            else => false,
        };
    }

    /// int→float 精确 widening 路径表（spec §4.2）
    /// 关键变化：
    ///   - i64→f64 不再是 widening（i64 有 64 位精度，f64 只有 53 位尾数）
    ///   - i128→f128 不是 widening（i128 有 128 位精度，f128 只有 113 位尾数）
    ///   - i8/i16/u8/u16 → f32/f64/f128 widening（精度无损）
    ///   - i32/u32 → f64/f128 widening
    ///   - i64/u64 → f128 widening（i64→f64 丢精度）
    ///   - i128/u128 → 无 widening 路径
    ///   - isize/usize 按平台位宽对应到 i64/u64（64 位平台）或 i32/u32（32 位平台）
    ///   - 任何 int→f16 都不是 widening（f16 仅 10 位尾数，无法无损表示任何整数）
    pub fn intToFloatWidening(int_ty: Type, float_ty: Type) bool {
        const platform_bits: u16 = @intCast(@bitSizeOf(isize));
        return switch (int_ty) {
            .i8_type, .u8_type, .i16_type, .u16_type => switch (float_ty) {
                .f32_type, .f64_type, .f128_type => true,
                else => false, // f16 不算 widening
            },
            .i32_type, .u32_type => switch (float_ty) {
                .f64_type, .f128_type => true,
                else => false,
            },
            .i64_type, .u64_type => switch (float_ty) {
                .f128_type => true,
                else => false,
            },
            .i128_type, .u128_type => false, // 无 widening 路径
            .isize_type, .usize_type => blk: {
                // 按平台位宽等价映射到 i64/u64 或 i32/u32
                const equiv: Type = if (platform_bits <= 32)
                    if (int_ty == .isize_type) .i32_type else .u32_type
                else
                    if (int_ty == .isize_type) .i64_type else .u64_type;
                break :blk intToFloatWidening(equiv, float_ty);
            },
            else => false,
        };
    }
    pub fn isNumericType(self: Type) bool {
        return self.isIntType() or self.isFloatType();
    }
    pub fn format(self: Type, writer: anytype) !void {
        if (builtinTypeName(self)) |name| {
            if (self == .unit_type) {
                try writer.writeAll("()");
            } else {
                try writer.writeAll(name);
            }
            return;
        }
        switch (self) {
            .type_var => |tv| {
                if (tv.bound) |bound| {
                    try bound.*.format(writer);
                } else {
                    try writer.print("'_{}", .{tv.id});
                }
            },
            .fn_type => |ft| {
                try writer.writeAll("(");
                for (ft.params, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try param.*.format(writer);
                }
                try writer.writeAll(") -> ");
                try ft.return_type.*.format(writer);
            },
            .record_type => |rt| {
                try writer.writeAll("(");
                for (rt.fields, 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}: ", .{field.name});
                    try field.ty.*.format(writer);
                }
                try writer.writeAll(")");
            },
            .adt_type => |at| {
                try writer.writeAll(at.name);
                if (at.type_args.len > 0) {
                    try writer.writeAll("<");
                    for (at.type_args, 0..) |arg, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try arg.*.format(writer);
                    }
                    try writer.writeAll(">");
                }
            },
            .nullable_type => |inner| {
                try inner.*.format(writer);
                try writer.writeAll("?");
            },
            .ref_type => |rt| {
                try writer.writeAll(if (rt.is_raw) "*" else "&");
                try rt.inner.*.format(writer);
            },
            .generic_type => |gt| {
                try writer.writeAll(gt.name);
                if (gt.args.len > 0) {
                    try writer.writeAll("<");
                    for (gt.args, 0..) |arg, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try arg.*.format(writer);
                    }
                    try writer.writeAll(">");
                }
            },
            .array_type => |at| {
                try at.element_type.*.format(writer);
                try writer.writeAll("[");
                if (at.size) |s| {
                    try writer.print("{}", .{s});
                }
                try writer.writeAll("]");
            },
            .throw_type => |tt| {
                try writer.writeAll("Throw<");
                try tt.value_type.*.format(writer);
                try writer.writeAll(", ");
                try tt.error_type.*.format(writer);
                try writer.writeAll(">");
            },
            .trait_type => |tt| {
                try writer.writeAll(tt.name);
                if (tt.type_args.len > 0) {
                    try writer.writeAll("<");
                    for (tt.type_args, 0..) |arg, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try arg.*.format(writer);
                    }
                    try writer.writeAll(">");
                }
            },
            .unknown_type => try writer.writeAll("?"),
            else => unreachable,
        }
    }
    pub fn formatArrayList(self: Type, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        if (builtinTypeName(self)) |name| {
            if (self == .unit_type) {
                try buf.appendSlice(allocator, "()");
            } else {
                try buf.appendSlice(allocator, name);
            }
            return;
        }
        switch (self) {
            .type_var => |tv| {
                if (tv.bound) |bound| {
                    try bound.*.formatArrayList(buf, allocator);
                } else {
                    try buf.print(allocator, "'_{}", .{tv.id});
                }
            },
            .fn_type => |ft| {
                try buf.appendSlice(allocator, "(");
                for (ft.params, 0..) |param, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try param.*.formatArrayList(buf, allocator);
                }
                try buf.appendSlice(allocator, ") -> ");
                try ft.return_type.*.formatArrayList(buf, allocator);
            },
            .record_type => |rt| {
                try buf.appendSlice(allocator, "(");
                for (rt.fields, 0..) |field, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "{s}: ", .{field.name});
                    try field.ty.*.formatArrayList(buf, allocator);
                }
                try buf.appendSlice(allocator, ")");
            },
            .adt_type => |at| {
                try buf.appendSlice(allocator, at.name);
                if (at.type_args.len > 0) {
                    try buf.appendSlice(allocator, "<");
                    for (at.type_args, 0..) |arg, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        try arg.*.formatArrayList(buf, allocator);
                    }
                    try buf.appendSlice(allocator, ">");
                }
            },
            .nullable_type => |inner| {
                try inner.*.formatArrayList(buf, allocator);
                try buf.appendSlice(allocator, "?");
            },
            .ref_type => |rt| {
                try buf.appendSlice(allocator, if (rt.is_raw) "*" else "&");
                try rt.inner.*.formatArrayList(buf, allocator);
            },
            .generic_type => |gt| {
                try buf.appendSlice(allocator, gt.name);
                if (gt.args.len > 0) {
                    try buf.appendSlice(allocator, "<");
                    for (gt.args, 0..) |arg, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        try arg.*.formatArrayList(buf, allocator);
                    }
                    try buf.appendSlice(allocator, ">");
                }
            },
            .array_type => |at| {
                try at.element_type.*.formatArrayList(buf, allocator);
                try buf.appendSlice(allocator, "[");
                if (at.size) |s| {
                    try buf.print(allocator, "{}", .{s});
                }
                try buf.appendSlice(allocator, "]");
            },
            .throw_type => |tt| {
                try buf.appendSlice(allocator, "Throw<");
                try tt.value_type.*.formatArrayList(buf, allocator);
                try buf.appendSlice(allocator, ", ");
                try tt.error_type.*.formatArrayList(buf, allocator);
                try buf.appendSlice(allocator, ">");
            },
            .trait_type => |tt| {
                try buf.appendSlice(allocator, tt.name);
                if (tt.type_args.len > 0) {
                    try buf.appendSlice(allocator, "<");
                    for (tt.type_args, 0..) |arg, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        try arg.*.formatArrayList(buf, allocator);
                    }
                    try buf.appendSlice(allocator, ">");
                }
            },
            .unknown_type => try buf.appendSlice(allocator, "?"),
            else => unreachable,
        }
    }
};

/// 内置类型名 ↔ Type 枚举映射表。
/// 涵盖文档中所有内置类型：i8~i128、u8~u128、f16~f128、bool、str、char、Unit、Null。
const BuiltinTypeEntry = struct { name: []const u8, ty: Type };

/// 所有内置类型条目（comptime 表，单一真相来源）
const BUILTIN_TYPES = [_]BuiltinTypeEntry{
    .{ .name = "i8", .ty = .i8_type },
    .{ .name = "i16", .ty = .i16_type },
    .{ .name = "i32", .ty = .i32_type },
    .{ .name = "i64", .ty = .i64_type },
    .{ .name = "i128", .ty = .i128_type },
    .{ .name = "u8", .ty = .u8_type },
    .{ .name = "u16", .ty = .u16_type },
    .{ .name = "u32", .ty = .u32_type },
    .{ .name = "u64", .ty = .u64_type },
    .{ .name = "u128", .ty = .u128_type },
    .{ .name = "isize", .ty = .isize_type },
    .{ .name = "usize", .ty = .usize_type },
    .{ .name = "f16", .ty = .f16_type },
    .{ .name = "f32", .ty = .f32_type },
    .{ .name = "f64", .ty = .f64_type },
    .{ .name = "f128", .ty = .f128_type },
    .{ .name = "bool", .ty = .bool_type },
    .{ .name = "str", .ty = .str_type },
    .{ .name = "char", .ty = .char_type },
    .{ .name = "Unit", .ty = .unit_type },
    .{ .name = "Null", .ty = .null_type },
};

/// 数值类型条目（整数 + 浮点，用于类型转换函数注册）
const NUMERIC_TYPES = [_]BuiltinTypeEntry{
    .{ .name = "i8", .ty = .i8_type },
    .{ .name = "i16", .ty = .i16_type },
    .{ .name = "i32", .ty = .i32_type },
    .{ .name = "i64", .ty = .i64_type },
    .{ .name = "i128", .ty = .i128_type },
    .{ .name = "u8", .ty = .u8_type },
    .{ .name = "u16", .ty = .u16_type },
    .{ .name = "u32", .ty = .u32_type },
    .{ .name = "u64", .ty = .u64_type },
    .{ .name = "u128", .ty = .u128_type },
    .{ .name = "isize", .ty = .isize_type },
    .{ .name = "usize", .ty = .usize_type },
    .{ .name = "f16", .ty = .f16_type },
    .{ .name = "f32", .ty = .f32_type },
    .{ .name = "f64", .ty = .f64_type },
    .{ .name = "f128", .ty = .f128_type },
};

/// 整数后缀条目（仅整数，用于整数字面量后缀推断）
const INT_SUFFIXES = [_]BuiltinTypeEntry{
    .{ .name = "i8", .ty = .i8_type },
    .{ .name = "i16", .ty = .i16_type },
    .{ .name = "i32", .ty = .i32_type },
    .{ .name = "i64", .ty = .i64_type },
    .{ .name = "i128", .ty = .i128_type },
    .{ .name = "u8", .ty = .u8_type },
    .{ .name = "u16", .ty = .u16_type },
    .{ .name = "u32", .ty = .u32_type },
    .{ .name = "u64", .ty = .u64_type },
    .{ .name = "u128", .ty = .u128_type },
    .{ .name = "isize", .ty = .isize_type },
    .{ .name = "usize", .ty = .usize_type },
};

/// 浮点后缀条目
const FLOAT_SUFFIXES = [_]BuiltinTypeEntry{
    .{ .name = "f16", .ty = .f16_type },
    .{ .name = "f32", .ty = .f32_type },
    .{ .name = "f64", .ty = .f64_type },
    .{ .name = "f128", .ty = .f128_type },
};

/// 按 Type 枚举查找内置类型名字符串，未找到返回 null
fn builtinTypeName(ty: Type) ?[]const u8 {
    inline for (BUILTIN_TYPES) |entry| {
        if (std.meta.activeTag(ty) == entry.ty) return entry.name;
    }
    return null;
}

/// 类型变量。用于 Hindley-Milner 推断中的未解析类型，通过 id 唯一标识，
/// bound 字段在统一后指向绑定的具体类型。
pub const TypeVar = struct {
    id: usize,
    bound: ?*Type = null,
    pub fn init() TypeVar {
        const id = next_type_id;
        next_type_id += 1;
        return TypeVar{ .id = id };
    }
};
/// 记录字段：字段名与字段类型的配对。
pub const FieldType = struct {
    name: []const u8,
    ty: *Type,
};
/// ADT（代数数据类型）信息。记录类型、构造器名列表、是否为 error newtype、
/// 类型参数、所属模块、是否为 GADT 以及各构造器的字段类型 / 名称 / 返回类型。
pub const AdtInfo = struct {
    ty: *Type,
    constructor_names: []const []const u8,
    is_error_newtype: bool = false,
    type_param_names: []const []const u8 = &[_][]const u8{},
    defining_module: []const u8 = "",
    is_gadt: bool = false,
    ctor_field_types: []const []const *Type = &[_][]const *Type{},
    ctor_field_names: []const []const ?[]const u8 = &[_][]const ?[]const u8{},
    ctor_return_types: []const ?*Type = &[_]?*Type{},
};
/// Trait 实现条目：记录 trait 名、类型名和源码位置。
pub const TraitEntry = struct {
    trait_name: []const u8,
    type_name: []const u8,
    line: u32,
    column: u32,
};
/// Trait 定义信息。记录 trait 类型、关联类型名、方法名与方法方案、
/// 所属模块及类型参数的 kind 元数。
pub const TraitInfo = struct {
    ty: *Type,
    associated_type_names: []const []const u8 = &[_][]const u8{},
    method_names: []const []const u8 = &[_][]const u8{},
    /// 仅含无默认实现的方法名（实现类型必须提供这些方法）
    required_method_names: []const []const u8 = &[_][]const u8{},
    method_schemes: std.StringHashMap(TypeScheme),
    defining_module: []const u8 = "",
    type_param_kind_arities: []const usize = &[_]usize{},
    /// trait 声明中 Self 对应的 type var id，用于签名匹配时替换
    self_type_var_id: ?usize = null,
    /// trait 类型参数对应的 type var ids，用于签名匹配时替换
    trait_type_param_var_ids: []const usize = &[_]usize{},
};
/// 类型方案（type scheme）。量化变量列表表示全称量化，bounds 记录 trait 约束。
pub const TypeScheme = struct {
    quantified_vars: []usize,
    ty: *Type,
    bounds: []BoundInfo = &[_]BoundInfo{},
};
/// Trait 约束信息：trait 名与对应的类型参数索引。
pub const BoundInfo = struct {
    trait_name: []const u8,
    type_param_index: usize,
};
/// 类型环境。通过 parent 指针形成词法作用域链，用于变量名到类型方案的查找。
pub const TypeEnv = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(TypeScheme),
    parent: ?*TypeEnv,
    pub fn init(allocator: std.mem.Allocator) TypeEnv {
        return TypeEnv{
            .allocator = allocator,
            .bindings = std.StringHashMap(TypeScheme).init(allocator),
            .parent = null,
        };
    }
    pub fn deinit(self: *TypeEnv) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.quantified_vars);
        }
        self.bindings.deinit();
    }
    pub fn createChild(self: *TypeEnv) !*TypeEnv {
        const child = try self.allocator.create(TypeEnv);
        child.* = TypeEnv.init(self.allocator);
        child.parent = self;
        return child;
    }
    pub fn define(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !void {
        if (self.bindings.contains(name)) {
            return error.DuplicateDefinition;
        }
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, scheme);
    }
    pub fn defineOrReport(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !bool {
        if (self.bindings.contains(name)) {
            return false;
        }
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, scheme);
        return true;
    }
    pub fn redefine(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !void {
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, scheme);
    }
    pub fn lookup(self: *TypeEnv, name: []const u8) ?TypeScheme {
        if (self.bindings.get(name)) |scheme| {
            return scheme;
        }
        if (self.parent) |parent| {
            return parent.lookup(name);
        }
        return null;
    }
};
/// 语义分析错误集合。
pub const SemaError = error{
    OutOfMemory,
    TypeMismatch,
    UnboundVariable,
    ArityMismatch,
    OccursCheckFailed,
    MissingImplementation,
    RecursiveType,
    DuplicateDefinition,
};
/// 类型错误分类。
pub const TypeErrorKind = enum {
    type_mismatch,
    unbound_variable,
    arity_mismatch,
    occurs_check_failed,
    missing_implementation,
    recursive_type,
    non_exhaustive_match,
    propagate_cross_type,
    unsatisfied_bound,
    unconsumed_async,
    /// trait 方法签名不匹配或必需方法缺失（强制中止执行）
    signature_mismatch,
    /// import 别名冲突：短名重复或与本地定义冲突
    name_conflict,
    /// import item 不存在
    import_item_not_found,
};
/// 类型错误记录。包含错误种类、消息和源码位置。
pub const TypeError = struct {
    kind: TypeErrorKind,
    message: []const u8,
    line: u32 = 0,
    column: u32 = 0,
};
const LinearVarInfo = struct {
    name: []const u8,
    consumed: bool,
    line: u32,
    column: u32,
};
/// 类型推断器。核心语义分析结构，负责统一、泛化、实例化、子类型判定、
/// trait 约束求解和类型错误收集。委托 subtype_check、trait_resolve 等子模块
/// 完成专门职责。
pub const TypeInferencer = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    type_vars: std.ArrayList(*TypeVar),
    types: std.ArrayList(*Type),
    adt_types: std.StringHashMap(AdtInfo),
    trait_types: std.StringHashMap(TraitInfo),
    errors: std.ArrayList(TypeError),
    current_fn_return_type: ?*Type = null,
    current_type_params: ?*const std.StringHashMap(*Type) = null,
    current_self_type: ?*Type = null,
    current_module: []const u8 = "",
    trait_defining_modules: std.StringHashMap([]const u8),
    type_defining_modules: std.StringHashMap([]const u8),
    registered_traits: std.StringHashMap(TraitEntry),
    fn_bounds: std.StringHashMap([]ast.TraitBound),
    predeclared_fns: std.StringHashMap(void),
    predeclared_types: std.StringHashMap(void),
    suppress_errors: bool = false,
    /// sema 输出契约：若非 null，inferExpr 会把每个表达式推断出的类型记录到此结构，
    /// 供 IRBuilder 在图构建时读取（驱动式接入）。
    sema_result: ?*SemaResult = null,
    exported_schemes: std.StringHashMap(TypeScheme),
    module_member_sigs: std.StringHashMap([]module_check.MethodSig),
    module_submodules: std.StringHashMap([][]const u8),
    known_modules: std.StringHashMap(void),
    builtin_names: std.StringHashMap(void),
    narrowing_buf: [4]NarrowingInfo = undefined,
    narrowed_paths: std.StringHashMap(void),
    current_fn_info: ?CurrentFnInfo = null,
    linear_scope_stack: std.ArrayList(std.ArrayList(LinearVarInfo)),
    singleton_cache: [SINGLETON_COUNT]?*Type = [_]?*Type{null} ** SINGLETON_COUNT,
    const CurrentFnInfo = struct {
        name: []const u8,
        has_type_params: bool,
        has_return_annotation: bool,
        type_param_ids: []const usize,
    };
    pub fn init(allocator: std.mem.Allocator) TypeInferencer {
        return TypeInferencer{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .type_vars = std.ArrayList(*TypeVar).empty,
            .types = std.ArrayList(*Type).empty,
            .adt_types = std.StringHashMap(AdtInfo).init(allocator),
            .trait_types = std.StringHashMap(TraitInfo).init(allocator),
            .errors = std.ArrayList(TypeError).empty,
            .current_fn_return_type = null,
            .current_module = "",
            .trait_defining_modules = std.StringHashMap([]const u8).init(allocator),
            .type_defining_modules = std.StringHashMap([]const u8).init(allocator),
            .registered_traits = std.StringHashMap(TraitEntry).init(allocator),
            .fn_bounds = std.StringHashMap([]ast.TraitBound).init(allocator),
            .predeclared_fns = std.StringHashMap(void).init(allocator),
            .predeclared_types = std.StringHashMap(void).init(allocator),
            .exported_schemes = std.StringHashMap(TypeScheme).init(allocator),
            .module_member_sigs = std.StringHashMap([]module_check.MethodSig).init(allocator),
            .module_submodules = std.StringHashMap([][]const u8).init(allocator),
            .known_modules = std.StringHashMap(void).init(allocator),
            .builtin_names = std.StringHashMap(void).init(allocator),
            .linear_scope_stack = std.ArrayList(std.ArrayList(LinearVarInfo)).empty,
            .narrowed_paths = std.StringHashMap(void).init(allocator),
        };
    }
    /// 注入 SemaResult 输出契约。设置后，inferExpr 会把每个表达式的推断类型
    /// 记录到 sema_result.expr_types，供 IRBuilder 在图构建时读取。
    /// 传入 null 可关闭记录。SemaResult 所有权归调用方。
    pub fn setSemaResult(self: *TypeInferencer, sr: ?*SemaResult) void {
        self.sema_result = sr;
    }
    /// 释放所有资源。
    /// HashMap 内部结构由 backing allocator 分配，需逐一 deinit。
    /// 所有数据（键、值、Type/TypeVar、数组）由 arena 分配，arena.deinit 统一释放。
    pub fn deinit(self: *TypeInferencer) void {
        self.type_vars.deinit(self.arena.allocator());
        self.types.deinit(self.arena.allocator());
        self.adt_types.deinit();
        {
            var iter = self.trait_types.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.method_schemes.deinit();
            }
            self.trait_types.deinit();
        }
        self.trait_defining_modules.deinit();
        self.type_defining_modules.deinit();
        self.registered_traits.deinit();
        self.fn_bounds.deinit();
        self.predeclared_fns.deinit();
        self.predeclared_types.deinit();
        self.exported_schemes.deinit();
        self.module_member_sigs.deinit();
        self.module_submodules.deinit();
        self.known_modules.deinit();
        self.builtin_names.deinit();
        self.errors.deinit(self.arena.allocator());
        for (self.linear_scope_stack.items) |*scope| {
            scope.deinit(self.arena.allocator());
        }
        self.linear_scope_stack.deinit(self.arena.allocator());
        self.narrowed_paths.deinit();
        // Arena 所有权管理：
        // - 若 sema_result 非空：将 arena 所有权转移给 sema_result。sema_result 中的
        //   TypeDefInfo/CtorDefInfo/FuncSigInfo 等数据引用了 arena 分配的 Type 结构体
        //   及其 name 字符串，arena 必须与 sema_result 同生命周期。sema_result.deinit()
        //   会释放 owned_arena。
        // - 若 sema_result 为空（单元测试场景）：直接释放 arena，无悬空引用风险。
        if (self.sema_result) |sr| {
            if (sr.owned_arena == null) {
                sr.owned_arena = self.arena;
            } else {
                // sema_result 已持有 arena（不应发生），释放当前 arena 防止泄漏
                self.arena.deinit();
            }
        } else {
            self.arena.deinit();
        }
    }
    pub fn addError(self: *TypeInferencer, kind: TypeErrorKind, comptime fmt: []const u8, args: anytype) void {
        if (self.suppress_errors) return;
        const message = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return;
        self.errors.append(self.arena.allocator(), TypeError{
            .kind = kind,
            .message = message,
        }) catch {};
    }
    pub fn addErrorAt(self: *TypeInferencer, kind: TypeErrorKind, line: u32, column: u32, comptime fmt: []const u8, args: anytype) void {
        if (self.suppress_errors) return;
        const message = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return;
        self.errors.append(self.arena.allocator(), TypeError{
            .kind = kind,
            .message = message,
            .line = line,
            .column = column,
        }) catch {};
    }
    pub fn pushLinearScope(self: *TypeInferencer) void {
        self.linear_scope_stack.append(self.arena.allocator(), std.ArrayList(LinearVarInfo).empty) catch {};
    }
    pub fn popLinearScope(self: *TypeInferencer) void {
        if (self.linear_scope_stack.items.len == 0) return;
        const scope = &self.linear_scope_stack.items[self.linear_scope_stack.items.len - 1];
        for (scope.items) |info| {
            if (!info.consumed) {
                self.addErrorAt(.unconsumed_async, info.line, info.column, "Async<{s}> must be consumed (await or cancel)", .{info.name});
            }
        }
        scope.deinit(self.arena.allocator());
        _ = self.linear_scope_stack.pop();
    }
    pub fn registerLinearVar(self: *TypeInferencer, name: []const u8, line: u32, column: u32) void {
        if (self.linear_scope_stack.items.len == 0) return;
        const scope = &self.linear_scope_stack.items[self.linear_scope_stack.items.len - 1];
        scope.append(self.arena.allocator(), LinearVarInfo{
            .name = name,
            .consumed = false,
            .line = line,
            .column = column,
        }) catch {};
    }
    pub fn markLinearVarConsumed(self: *TypeInferencer, name: []const u8) void {
        var i: usize = self.linear_scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.linear_scope_stack.items[i];
            for (scope.items) |*info| {
                if (std.mem.eql(u8, info.name, name)) {
                    info.consumed = true;
                    return;
                }
            }
        }
    }
    pub fn isAsyncType(self: *TypeInferencer, ty: *Type) bool {
        const resolved = self.resolve(ty);
        return switch (resolved.*) {
            .generic_type => |gt| std.mem.eql(u8, gt.name, "Async"),
            else => false,
        };
    }
    pub fn resetForNextModule(self: *TypeInferencer) void {
        for (self.errors.items) |err| {
            self.arena.allocator().free(err.message);
        }
        self.errors.clearRetainingCapacity();
        self.predeclared_fns.clearRetainingCapacity();
        for (self.linear_scope_stack.items) |*scope| {
            scope.deinit(self.arena.allocator());
        }
        self.linear_scope_stack.clearRetainingCapacity();
    }
    pub fn isWidening(self: *TypeInferencer, wider: *Type, narrower: *Type) bool {
        const w = self.resolve(wider);
        const n = self.resolve(narrower);

        // 同类型：identity，视为 widening（永不失败的特例）
        if (std.meta.activeTag(w.*) == std.meta.activeTag(n.*)) {
            return switch (n.*) {
                .i8_type, .i16_type, .i32_type, .i64_type, .i128_type,
                .u8_type, .u16_type, .u32_type, .u64_type, .u128_type,
                .isize_type, .usize_type,
                .f16_type, .f32_type, .f64_type, .f128_type,
                .bool_type, .char_type,
                => true,
                else => false,
            };
        }

        // bool → 任意数值 → widening（false=0, true=1，可无损表示）
        if (n.* == .bool_type) {
            return switch (w.*) {
                .i8_type, .i16_type, .i32_type, .i64_type, .i128_type,
                .u8_type, .u16_type, .u32_type, .u64_type, .u128_type,
                .isize_type, .usize_type,
                .f16_type, .f32_type, .f64_type, .f128_type,
                => true,
                else => false,
            };
        }

        // char → 任意其他类型：均非 widening（按 §4.1 表，char→int = N 码点截断/检查）
        // char→char 已在上述同类型分支处理

        // int→int 规则（§7.2）：
        //   - 同符号且 dst 位数 ≥ src 位数 → widening
        //   - 跨符号同位数 → widening (bit reinterpret)
        //   - 跨符号不同位数 → 非 widening (需要范围检查)
        if (n.isIntType() and w.isIntType()) {
            const src_signed = n.isSignedIntType();
            const dst_signed = w.isSignedIntType();
            const src_bits = n.intTypeBitWidth() orelse return false;
            const dst_bits = w.intTypeBitWidth() orelse return false;
            if (src_signed == dst_signed) {
                return dst_bits >= src_bits;
            } else {
                return dst_bits == src_bits;
            }
        }

        // int→float: 按 §4.2 精确 widening 路径表
        if (n.isIntType() and w.isFloatType()) {
            return Type.intToFloatWidening(n.*, w.*);
        }

        // float→float: dst 位数 ≥ src 位数 → widening
        if (n.isFloatType() and w.isFloatType()) {
            const src_bits = n.floatTypeBitWidth() orelse return false;
            const dst_bits = w.floatTypeBitWidth() orelse return false;
            return dst_bits >= src_bits;
        }

        return false;
    }
    /// 创建新的类型变量。
    pub fn freshTypeVar(self: *TypeInferencer) !*Type {
        const tv = try self.arena.allocator().create(TypeVar);
        tv.* = TypeVar.init();
        try self.type_vars.append(self.arena.allocator(), tv);
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .type_var = tv };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeType(self: *TypeInferencer, comptime tag: @TypeOf(Type.i32_type)) !*Type {
        const idx = comptime singletonIdx(tag);
        if (idx < SINGLETON_COUNT) {
            if (self.singleton_cache[idx]) |cached| return cached;
            const t = try self.arena.allocator().create(Type);
            t.* = tag;
            try self.types.append(self.arena.allocator(), t);
            self.singleton_cache[idx] = t;
            return t;
        }
        const t = try self.arena.allocator().create(Type);
        t.* = tag;
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeArrayType(self: *TypeInferencer, element_type: *Type, size: ?u64) !*Type {
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .array_type = .{ .element_type = element_type, .size = size } };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    /// 构造借用引用类型 &T（is_raw=false）或裸指针 *T（is_raw=true）
    pub fn makeRefType(self: *TypeInferencer, inner: *Type, is_raw: bool) !*Type {
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .ref_type = .{ .inner = inner, .is_raw = is_raw } };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeFnType(self: *TypeInferencer, params: []*Type, return_type: *Type) !*Type {
        const owned_params = try self.arena.allocator().dupe(*Type, params);
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .fn_type = .{ .params = owned_params, .return_type = return_type } };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeGenericType(self: *TypeInferencer, name: []const u8, args: []const *Type) !*Type {
        const owned_name = try self.arena.allocator().dupe(u8, name);
        const owned_args = try self.arena.allocator().dupe(*Type, args);
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .generic_type = .{ .name = owned_name, .args = owned_args } };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeNullableType(self: *TypeInferencer, inner: *Type) !*Type {
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .nullable_type = inner };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    pub fn makeAdtType(self: *TypeInferencer, name: []const u8, type_args: []*Type) !*Type {
        const owned_args = try self.arena.allocator().dupe(*Type, type_args);
        const t = try self.arena.allocator().create(Type);
        t.* = Type{ .adt_type = .{ .name = name, .type_args = owned_args } };
        try self.types.append(self.arena.allocator(), t);
        return t;
    }
    const module_ref_prefix = "$module:";
    fn makeModuleRef(self: *TypeInferencer, module_name: []const u8) !*Type {
        const encoded = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}", .{ module_ref_prefix, module_name });
        return self.makeAdtType(encoded, &[_]*Type{});
    }
    pub fn asModuleRef(self: *TypeInferencer, ty: *Type) ?[]const u8 {
        const r = self.resolve(ty);
        if (r.* == .adt_type and std.mem.startsWith(u8, r.adt_type.name, module_ref_prefix)) {
            return r.adt_type.name[module_ref_prefix.len..];
        }
        return null;
    }
    fn moduleSatisfiesTrait(self: *TypeInferencer, module_name: []const u8, trait_name: []const u8) module_check.MatchResult {
        const provided = self.module_member_sigs.get(module_name) orelse return .{ .ok = true };
        const trait_info = self.trait_types.get(trait_name) orelse return .{ .ok = true };
        var required = std.ArrayList(module_check.MethodSig).empty;
        defer required.deinit(self.arena.allocator());
        for (trait_info.method_names) |mname| {
            const scheme = trait_info.method_schemes.get(mname) orelse continue;
            const rt = self.resolve(scheme.ty);
            const arity: usize = if (rt.* == .fn_type) rt.fn_type.params.len else 0;
            required.append(self.arena.allocator(), .{ .name = mname, .arity = arity }) catch continue;
        }
        var mc = module_check.ModuleChecker.init(self.arena.allocator());
        defer mc.deinit();
        return mc.structurallySatisfies(provided, required.items);
    }
    /// 统一两个类型。遵循 Hindley-Milner 算法，通过绑定类型变量实现统一，
    /// 包含数值宽化、记录子类型、ADT、throw 等特殊规则。
    pub fn unify(self: *TypeInferencer, t1: *Type, t2: *Type) SemaError!void {
        const resolved1 = self.resolve(t1);
        const resolved2 = self.resolve(t2);
        if (resolved1 == resolved2) return;
        switch (resolved1.*) {
            .type_var => |tv1| {
                if (self.occurs(tv1.id, resolved2)) {
                    return error.OccursCheckFailed;
                }
                tv1.bound = resolved2;
                return;
            },
            else => {},
        }
        switch (resolved2.*) {
            .type_var => |tv2| {
                if (self.occurs(tv2.id, resolved1)) {
                    return error.OccursCheckFailed;
                }
                tv2.bound = resolved1;
                return;
            },
            else => {},
        }
        const tag1 = std.meta.activeTag(resolved1.*);
        const tag2 = std.meta.activeTag(resolved2.*);
        if (tag1 != tag2) {
            if (resolved2.* == .nullable_type) {
                try self.unify(resolved1, resolved2.nullable_type);
                return;
            }
            if (resolved1.* == .null_type and resolved2.* == .nullable_type) {
                return;
            }
            return error.TypeMismatch;
        }
        switch (resolved1.*) {
            .fn_type => |ft1| {
                const ft2 = resolved2.fn_type;
                if (ft1.params.len != ft2.params.len) return error.ArityMismatch;
                for (ft1.params, ft2.params) |p1, p2| {
                    try self.unify(p1, p2);
                }
                try self.unify(ft1.return_type, ft2.return_type);
            },
            .record_type => |rt1| {
                const rt2 = resolved2.record_type;
                const smaller = if (rt1.fields.len <= rt2.fields.len) rt1 else rt2;
                const larger = if (rt1.fields.len <= rt2.fields.len) rt2 else rt1;
                for (smaller.fields) |sf| {
                    var found = false;
                    for (larger.fields) |lf| {
                        if (std.mem.eql(u8, sf.name, lf.name)) {
                            try self.unify(sf.ty, lf.ty);
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.TypeMismatch;
                }
            },
            .nullable_type => |inner1| {
                try self.unify(inner1, resolved2.nullable_type);
            },
            .ref_type => |rt1| {
                // &T/*T 统一：递归统一 inner，is_raw 不参与（仅安全提示）
                try self.unify(rt1.inner, resolved2.ref_type.inner);
            },
            .adt_type => |at1| {
                const at2 = resolved2.adt_type;
                if (self.isSubtype(resolved1, resolved2)) {
                    return;
                }
                if (self.isSubtype(resolved2, resolved1)) {
                    return;
                }
                if (!std.mem.eql(u8, at1.name, at2.name)) return error.TypeMismatch;
                if (at1.type_args.len != at2.type_args.len) return error.TypeMismatch;
                for (at1.type_args, at2.type_args) |a1, a2| {
                    try self.unify(a1, a2);
                }
            },
            .throw_type => |tt1| {
                const tt2 = resolved2.throw_type;
                if (self.isSubtype(resolved1, resolved2)) {
                    return;
                }
                try self.unify(tt1.value_type, tt2.value_type);
                try self.unify(tt1.error_type, tt2.error_type);
            },
            .generic_type => |gt1| {
                const gt2 = resolved2.generic_type;
                if (!std.mem.eql(u8, gt1.name, gt2.name)) return error.TypeMismatch;
                if (gt1.args.len != gt2.args.len) return error.TypeMismatch;
                for (gt1.args, gt2.args) |a1, a2| {
                    try self.unify(a1, a2);
                }
            },
            .trait_type => {
                if (self.isSubtype(resolved1, resolved2)) {
                    return;
                }
                if (self.isSubtype(resolved2, resolved1)) {
                    return;
                }
                if (!std.mem.eql(u8, resolved1.trait_type.name, resolved2.trait_type.name)) {
                    return error.TypeMismatch;
                }
            },
            else => {},
        }
    }
    fn unifyReturnType(self: *TypeInferencer, declared: *Type, inferred: *Type) SemaError!void {
        return throw_check.unifyReturnType(self, declared, inferred);
    }
    /// 解析类型：沿类型变量的 bound 链找到最终指向的具体类型。
    pub fn resolve(self: *TypeInferencer, t: *Type) *Type {
        switch (t.*) {
            .type_var => |tv| {
                if (tv.bound) |bound| {
                    const resolved = self.resolve(bound);
                    tv.bound = resolved;
                    return resolved;
                }
                return t;
            },
            else => return t,
        }
    }
    /// 判断 sub 是否为 super 的子类型。委托 subtype_check 模块完成。
    pub fn isSubtype(self: *TypeInferencer, sub: *Type, super: *Type) bool {
        return subtype_check.isSubtype(self, sub, super);
    }
    /// 无副作用的类型结构相等检查：不修改任何 type var，不触发 unify 副作用。
    /// 用于 trait 方法签名匹配时比较参数类型和返回类型。
    pub fn typesStructurallyEqual(self: *TypeInferencer, a_in: *Type, b_in: *Type) bool {
        const a = self.resolve(a_in);
        const b = self.resolve(b_in);
        if (@as(std.meta.Tag(Type), a.*) != @as(std.meta.Tag(Type), b.*)) return false;
        return switch (a.*) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type,
            .u8_type, .u16_type, .u32_type, .u64_type, .u128_type,
            .isize_type, .usize_type,
            .f16_type, .f32_type, .f64_type, .f128_type,
            .bool_type, .str_type, .char_type, .null_type, .unit_type, .unknown_type => true,
            .type_var => |va| {
                if (b.* == .type_var) {
                    return va.id == b.type_var.id;
                }
                return false;
            },
            .fn_type => |fa| {
                if (b.* != .fn_type) return false;
                const fb = b.fn_type;
                if (fa.params.len != fb.params.len) return false;
                for (fa.params, 0..) |pa, i| {
                    if (!self.typesStructurallyEqual(pa, fb.params[i])) return false;
                }
                return self.typesStructurallyEqual(fa.return_type, fb.return_type);
            },
            .adt_type => |aa| {
                if (b.* != .adt_type) return false;
                const ab = b.adt_type;
                if (!std.mem.eql(u8, aa.name, ab.name)) return false;
                if (aa.type_args.len != ab.type_args.len) return false;
                for (aa.type_args, 0..) |ta, i| {
                    if (!self.typesStructurallyEqual(ta, ab.type_args[i])) return false;
                }
                return true;
            },
            .trait_type => |aa| {
                if (b.* != .trait_type) return false;
                const ab = b.trait_type;
                if (!std.mem.eql(u8, aa.name, ab.name)) return false;
                if (aa.type_args.len != ab.type_args.len) return false;
                for (aa.type_args, 0..) |ta, i| {
                    if (!self.typesStructurallyEqual(ta, ab.type_args[i])) return false;
                }
                return true;
            },
            .generic_type => |aa| {
                if (b.* != .generic_type) return false;
                const ab = b.generic_type;
                if (!std.mem.eql(u8, aa.name, ab.name)) return false;
                if (aa.args.len != ab.args.len) return false;
                for (aa.args, 0..) |ta, i| {
                    if (!self.typesStructurallyEqual(ta, ab.args[i])) return false;
                }
                return true;
            },
            .nullable_type => |aa| {
                if (b.* != .nullable_type) return false;
                return self.typesStructurallyEqual(aa, b.nullable_type);
            },
            .ref_type => |aa| {
                if (b.* != .ref_type) return false;
                return aa.is_raw == b.ref_type.is_raw and
                    self.typesStructurallyEqual(aa.inner, b.ref_type.inner);
            },
            .throw_type => |aa| {
                if (b.* != .throw_type) return false;
                const ab = b.throw_type;
                return self.typesStructurallyEqual(aa.value_type, ab.value_type) and
                    self.typesStructurallyEqual(aa.error_type, ab.error_type);
            },
            .array_type => |aa| {
                if (b.* != .array_type) return false;
                const ab = b.array_type;
                return self.typesStructurallyEqual(aa.element_type, ab.element_type) and aa.size == ab.size;
            },
            .record_type => |aa| {
                if (b.* != .record_type) return false;
                const ab = b.record_type;
                if (aa.fields.len != ab.fields.len) return false;
                for (aa.fields, 0..) |fa, i| {
                    if (!std.mem.eql(u8, fa.name, ab.fields[i].name)) return false;
                    if (!self.typesStructurallyEqual(fa.ty, ab.fields[i].ty)) return false;
                }
                return true;
            },
        };
    }
    /// 用替换表替换类型中的 type var（按 var id）。无副作用，返回新类型。
    pub fn applyTypeSubst(self: *TypeInferencer, ty_in: *Type, subst: *const std.AutoHashMap(usize, *Type)) SemaError!*Type {
        const ty = self.resolve(ty_in);
        return switch (ty.*) {
            .type_var => |tv| {
                if (subst.get(tv.id)) |replacement| return replacement;
                return ty;
            },
            .fn_type => |ft| {
                const new_params = self.arena.allocator().alloc(*Type, ft.params.len) catch return error.OutOfMemory;
                for (ft.params, 0..) |p, i| {
                    new_params[i] = try self.applyTypeSubst(p, subst);
                }
                const new_ret = try self.applyTypeSubst(ft.return_type, subst);
                return self.makeFnType(new_params, new_ret);
            },
            .adt_type => |at| {
                if (at.type_args.len == 0) return ty;
                const new_args = self.arena.allocator().alloc(*Type, at.type_args.len) catch return error.OutOfMemory;
                for (at.type_args, 0..) |a, i| {
                    new_args[i] = try self.applyTypeSubst(a, subst);
                }
                return self.makeAdtType(at.name, new_args);
            },
            .trait_type => |tt| {
                if (tt.type_args.len == 0) return ty;
                const new_args = self.arena.allocator().alloc(*Type, tt.type_args.len) catch return error.OutOfMemory;
                for (tt.type_args, 0..) |a, i| {
                    new_args[i] = try self.applyTypeSubst(a, subst);
                }
                const result = self.arena.allocator().create(Type) catch return error.OutOfMemory;
                result.* = Type{ .trait_type = .{ .name = tt.name, .type_args = new_args } };
                self.types.append(self.arena.allocator(), result) catch return error.OutOfMemory;
                return result;
            },
            .generic_type => |gt| {
                if (gt.args.len == 0) return ty;
                const new_args = self.arena.allocator().alloc(*Type, gt.args.len) catch return error.OutOfMemory;
                for (gt.args, 0..) |a, i| {
                    new_args[i] = try self.applyTypeSubst(a, subst);
                }
                const result = self.arena.allocator().create(Type) catch return error.OutOfMemory;
                result.* = Type{ .generic_type = .{ .name = gt.name, .args = new_args } };
                self.types.append(self.arena.allocator(), result) catch return error.OutOfMemory;
                return result;
            },
            .nullable_type => |inner| {
                const new_inner = try self.applyTypeSubst(inner, subst);
                return self.makeNullableType(new_inner);
            },
            .ref_type => |rt| {
                const new_inner = try self.applyTypeSubst(rt.inner, subst);
                return self.makeRefType(new_inner, rt.is_raw);
            },
            .throw_type => |tt| {
                const new_val = try self.applyTypeSubst(tt.value_type, subst);
                const new_err = try self.applyTypeSubst(tt.error_type, subst);
                const result = self.arena.allocator().create(Type) catch return error.OutOfMemory;
                result.* = Type{ .throw_type = .{ .value_type = new_val, .error_type = new_err } };
                self.types.append(self.arena.allocator(), result) catch return error.OutOfMemory;
                return result;
            },
            .array_type => |at| {
                const new_elem = try self.applyTypeSubst(at.element_type, subst);
                const result = self.arena.allocator().create(Type) catch return error.OutOfMemory;
                result.* = Type{ .array_type = .{ .element_type = new_elem, .size = at.size } };
                self.types.append(self.arena.allocator(), result) catch return error.OutOfMemory;
                return result;
            },
            else => ty,
        };
    }
    fn recordArgSatisfies(self: *TypeInferencer, param: *Type, arg: *Type) bool {
        return subtype_check.recordArgSatisfies(self, param, arg);
    }
    fn widerIntType(self: *TypeInferencer, a: *Type, b: *Type) *Type {
        _ = self;
        const rank = struct {
            fn get(t: Type) u8 {
                return switch (t) {
                    .i8_type => 0,
                    .u8_type => 1,
                    .i16_type => 2,
                    .u16_type => 3,
                    .i32_type => 4,
                    .u32_type => 5,
                    .i64_type => 6,
                    .u64_type => 7,
                    .i128_type => 8,
                    .u128_type => 9,
                    // isize/usize 跟随平台位宽等价处理
                    .isize_type => 6,
                    .usize_type => 7,
                    else => 0,
                };
            }
        }.get;
        return if (rank(b.*) > rank(a.*)) b else a;
    }
    /// 浮点类型拓宽：取两个 float 类型中较宽者（f16 < f32 < f64 < f128）。
    fn widerFloatType(self: *TypeInferencer, a: *Type, b: *Type) *Type {
        _ = self;
        const rank = struct {
            fn get(t: Type) u8 {
                return switch (t) {
                    .f16_type => 0,
                    .f32_type => 1,
                    .f64_type => 2,
                    .f128_type => 3,
                    else => 0,
                };
            }
        }.get;
        return if (rank(b.*) > rank(a.*)) b else a;
    }
    /// 数值二元运算的类型推导（Rust 风格，int/float 对称）。
    /// 规则：
    ///   - 字面量可提升到另一侧的显式变量类型（2 + x:i64 → i64）
    ///   - 两侧都是字面量：选最宽类型（仅在 int 域或 float 域内，int+float 仍报错）
    ///   - 两侧都是显式变量类型：必须完全相同，否则 TypeMismatch（需显式 cast）
    /// 跨域（int + float）不在本函数处理范围，由调用方 unify。
    /// 返回运算结果类型；is_arith=false 表示比较运算，结果类型仅用于诊断。
    fn numericOpType(
        self: *TypeInferencer,
        left_ty: *Type,
        right_ty: *Type,
        left_expr: *const ast.Expr,
        right_expr: *const ast.Expr,
        is_arith: bool,
    ) SemaError!*Type {
        const rl = self.resolve(left_ty);
        const rr = self.resolve(right_ty);
        const left_is_literal = left_expr.* == .int_literal or left_expr.* == .float_literal;
        const right_is_literal = right_expr.* == .int_literal or right_expr.* == .float_literal;
        // 字面量提升到变量类型
        if (left_is_literal and !right_is_literal) return rr;
        if (!left_is_literal and right_is_literal) return rl;
        // 两侧都是字面量：选最宽（同域内）
        if (left_is_literal and right_is_literal) {
            if (rl.isIntType() and rr.isIntType()) return self.widerIntType(rl, rr);
            if (rl.isFloatType() and rr.isFloatType()) return self.widerFloatType(rl, rr);
            // 跨域字面量（1 + 2.0）：提升到 float
            if (rl.isIntType() and rr.isFloatType()) return rr;
            if (rl.isFloatType() and rr.isIntType()) return rl;
        }
        // 两侧都是显式变量类型：必须完全相同
        _ = is_arith;
        try self.unify(left_ty, right_ty);
        return left_ty;
    }
    fn nullableViolation(self: *TypeInferencer, target: *Type, source: *Type) bool {
        const rt = self.resolve(target);
        const rs = self.resolve(source);
        if (rt.* == .nullable_type) return false;
        if (rt.* == .type_var) return false;
        if (rs.* == .nullable_type) return true;
        if (rs.* == .null_type) return true;
        return false;
    }
    fn occurs(self: *TypeInferencer, id: usize, t: *Type) bool {
        const resolved = self.resolve(t);
        switch (resolved.*) {
            .type_var => |tv| return tv.id == id,
            .fn_type => |ft| {
                for (ft.params) |p| {
                    if (self.occurs(id, p)) return true;
                }
                return self.occurs(id, ft.return_type);
            },
            .record_type => |rt| {
                for (rt.fields) |f| {
                    if (self.occurs(id, f.ty)) return true;
                }
                return false;
            },
            .nullable_type => |inner| return self.occurs(id, inner),
            .ref_type => |rt| return self.occurs(id, rt.inner),
            .adt_type => |at| {
                for (at.type_args) |arg| {
                    if (self.occurs(id, arg)) return true;
                }
                return false;
            },
            .throw_type => |tt| {
                return self.occurs(id, tt.value_type) or self.occurs(id, tt.error_type);
            },
            .generic_type => |gt| {
                for (gt.args) |arg| {
                    if (self.occurs(id, arg)) return true;
                }
                return false;
            },
            else => return false,
        }
    }
    /// 泛化类型：将不在环境中自由出现的类型变量量化为类型方案。
    pub fn generalize(self: *TypeInferencer, env: *TypeEnv, ty: *Type) !TypeScheme {
        _ = env;
        var free_vars = std.ArrayList(usize).empty;
        defer free_vars.deinit(self.arena.allocator());
        self.collectFreeVars(ty, &free_vars);
        const quantified = try self.arena.allocator().dupe(usize, free_vars.items);
        return TypeScheme{
            .quantified_vars = quantified,
            .ty = ty,
        };
    }
    pub fn generalizeWithBounds(self: *TypeInferencer, env: *TypeEnv, ty: *Type, type_param_ids: []usize, bounds: []ast.TraitBound) !TypeScheme {
        _ = env;
        var free_vars = std.ArrayList(usize).empty;
        defer free_vars.deinit(self.arena.allocator());
        self.collectFreeVars(ty, &free_vars);
        const quantified = try self.arena.allocator().dupe(usize, free_vars.items);
        var bound_infos = std.ArrayList(BoundInfo).empty;
        defer bound_infos.deinit(self.arena.allocator());
        for (bounds) |bound| {
            for (bound.type_args) |_| {
                for (type_param_ids, 0..) |param_id, param_idx| {
                    for (quantified, 0..) |qvar_id, qidx| {
                        if (qvar_id == param_id) {
                            bound_infos.append(self.arena.allocator(), BoundInfo{
                                .trait_name = bound.trait_name,
                                .type_param_index = qidx,
                            }) catch return TypeScheme{ .quantified_vars = quantified, .ty = ty };
                            break;
                        }
                    }
                    _ = param_idx;
                    break;
                }
            }
        }
        const owned_bounds = try self.arena.allocator().dupe(BoundInfo, bound_infos.items);
        return TypeScheme{
            .quantified_vars = quantified,
            .ty = ty,
            .bounds = owned_bounds,
        };
    }
    /// 实例化类型方案：将量化变量替换为新的类型变量。
    pub fn instantiate(self: *TypeInferencer, scheme: TypeScheme) !*Type {
        if (scheme.quantified_vars.len == 0) return scheme.ty;
        var subst = std.AutoHashMap(usize, *Type).init(self.arena.allocator());
        defer subst.deinit();
        for (scheme.quantified_vars) |var_id| {
            const fresh = try self.freshTypeVar();
            try subst.put(var_id, fresh);
        }
        return self.applySubst(scheme.ty, subst);
    }
    /// 刷新类型：将类型中的量化变量替换为新的类型变量，用于保持类型方案的独立性。
    pub fn freshenType(self: *TypeInferencer, ty: *Type) !*Type {
        var free_vars = std.ArrayList(usize).empty;
        defer free_vars.deinit(self.arena.allocator());
        self.collectFreeVars(ty, &free_vars);
        if (free_vars.items.len == 0) return ty;
        var subst = std.AutoHashMap(usize, *Type).init(self.arena.allocator());
        defer subst.deinit();
        for (free_vars.items) |var_id| {
            const fresh = try self.freshTypeVar();
            try subst.put(var_id, fresh);
        }
        return self.applySubst(ty, subst);
    }
    fn collectFreeVars(self: *TypeInferencer, ty: *Type, free_vars: *std.ArrayList(usize)) void {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .type_var => |tv| {
                if (tv.bound == null) {
                    for (free_vars.items) |id| {
                        if (id == tv.id) return;
                    }
                    free_vars.append(self.arena.allocator(), tv.id) catch {};
                }
            },
            .fn_type => |ft| {
                for (ft.params) |p| {
                    self.collectFreeVars(p, free_vars);
                }
                self.collectFreeVars(ft.return_type, free_vars);
            },
            .record_type => |rt| {
                for (rt.fields) |f| {
                    self.collectFreeVars(f.ty, free_vars);
                }
            },
            .nullable_type => |inner| self.collectFreeVars(inner, free_vars),
            .ref_type => |rt| self.collectFreeVars(rt.inner, free_vars),
            .adt_type => |at| {
                for (at.type_args) |arg| {
                    self.collectFreeVars(arg, free_vars);
                }
            },
            .throw_type => |tt| {
                self.collectFreeVars(tt.value_type, free_vars);
                self.collectFreeVars(tt.error_type, free_vars);
            },
            .generic_type => |gt| {
                for (gt.args) |arg| {
                    self.collectFreeVars(arg, free_vars);
                }
            },
            else => {},
        }
    }
    fn applySubst(self: *TypeInferencer, ty: *Type, subst: std.AutoHashMap(usize, *Type)) !*Type {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .type_var => |tv| {
                if (subst.get(tv.id)) |replacement| {
                    return replacement;
                }
                return resolved;
            },
            .fn_type => |ft| {
                var new_params = try self.arena.allocator().alloc(*Type, ft.params.len);
                for (ft.params, 0..) |p, i| {
                    new_params[i] = try self.applySubst(p, subst);
                }
                const new_ret = try self.applySubst(ft.return_type, subst);
                return self.makeFnType(new_params, new_ret);
            },
            .nullable_type => |inner| {
                const new_inner = try self.applySubst(inner, subst);
                return self.makeNullableType(new_inner);
            },
            .ref_type => |rt| {
                const new_inner = try self.applySubst(rt.inner, subst);
                return self.makeRefType(new_inner, rt.is_raw);
            },
            .throw_type => |tt| {
                const new_val = try self.applySubst(tt.value_type, subst);
                const new_err = try self.applySubst(tt.error_type, subst);
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .throw_type = .{ .value_type = new_val, .error_type = new_err } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            .adt_type => |adt| {
                if (adt.type_args.len == 0) return resolved;
                var new_args = try self.arena.allocator().alloc(*Type, adt.type_args.len);
                for (adt.type_args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                return self.makeAdtType(adt.name, new_args);
            },
            .trait_type => |tt| {
                if (tt.type_args.len == 0) return resolved;
                var new_args = try self.arena.allocator().alloc(*Type, tt.type_args.len);
                for (tt.type_args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .trait_type = .{ .name = tt.name, .type_args = new_args } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            .record_type => |rt| {
                var new_fields = try self.arena.allocator().alloc(FieldType, rt.fields.len);
                for (rt.fields, 0..) |f, i| {
                    new_fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.applySubst(f.ty, subst),
                    };
                }
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .record_type = .{ .fields = new_fields } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            .array_type => |at| {
                const new_elem = try self.applySubst(at.element_type, subst);
                return self.makeArrayType(new_elem, at.size);
            },
            .generic_type => |gt| {
                if (gt.args.len == 0) return resolved;
                var new_args = try self.arena.allocator().alloc(*Type, gt.args.len);
                for (gt.args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .generic_type = .{ .name = gt.name, .args = new_args } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            else => return resolved,
        }
    }
    const NarrowingInfo = struct {
        name: []const u8,
        is_non_null: bool,
    };
    fn analyzeNullCheck(self: *TypeInferencer, cond: *const ast.Expr) []const NarrowingInfo {
        switch (cond.*) {
            .binary => |bin| {
                switch (bin.op) {
                    .not_eq, .ref_neq => {
                        if (self.isNullLiteral(bin.right)) {
                            if (self.getIdentifierName(bin.left)) |name| {
                                self.narrowing_buf[0] = .{ .name = name, .is_non_null = true };
                                return self.narrowing_buf[0..1];
                            }
                        }
                        if (self.isNullLiteral(bin.left)) {
                            if (self.getIdentifierName(bin.right)) |name| {
                                self.narrowing_buf[0] = .{ .name = name, .is_non_null = true };
                                return self.narrowing_buf[0..1];
                            }
                        }
                    },
                    .eq, .ref_eq => {
                        if (self.isNullLiteral(bin.right)) {
                            if (self.getIdentifierName(bin.left)) |name| {
                                self.narrowing_buf[0] = .{ .name = name, .is_non_null = false };
                                return self.narrowing_buf[0..1];
                            }
                        }
                        if (self.isNullLiteral(bin.left)) {
                            if (self.getIdentifierName(bin.right)) |name| {
                                self.narrowing_buf[0] = .{ .name = name, .is_non_null = false };
                                return self.narrowing_buf[0..1];
                            }
                        }
                    },
                    .and_op => {
                        const left_narrowings = self.analyzeNullCheck(bin.left);
                        const right_narrowings = self.analyzeNullCheck(bin.right);
                        if (left_narrowings.len == 0) return right_narrowings;
                        if (right_narrowings.len == 0) return left_narrowings;
                        return left_narrowings;
                    },
                    else => {},
                }
            },
            .unary => |un| {
                switch (un.op) {
                    .not => {
                        const inner = self.analyzeNullCheck(un.operand);
                        if (inner.len == 1) {
                            self.narrowing_buf[0] = .{ .name = inner[0].name, .is_non_null = !inner[0].is_non_null };
                            return self.narrowing_buf[0..1];
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        return &[_]NarrowingInfo{};
    }
    fn isNullLiteral(self: *TypeInferencer, expr: *const ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .null_literal => true,
            .identifier => |id| std.mem.eql(u8, id.name, "null"),
            else => false,
        };
    }
    fn getIdentifierName(self: *TypeInferencer, expr: *const ast.Expr) ?[]const u8 {
        _ = self;
        return switch (expr.*) {
            .identifier => |id| id.name,
            else => null,
        };
    }
    pub fn exprPath(self: *TypeInferencer, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            .identifier => |id| return self.arena.allocator().dupe(u8, id.name) catch null,
            .field_access => |fa| {
                const base = self.exprPath(fa.object) orelse return null;
                defer self.arena.allocator().free(base);
                return std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ base, fa.field }) catch null;
            },
            else => return null,
        }
    }
    fn fieldPathNullCheck(self: *TypeInferencer, cond: *const ast.Expr, out_path: *?[]const u8, out_then: *bool) void {
        if (cond.* != .binary) return;
        const bin = cond.binary;
        const is_neq = bin.op == .not_eq or bin.op == .ref_neq;
        const is_eq = bin.op == .eq or bin.op == .ref_eq;
        if (!is_neq and !is_eq) return;
        const operand: ?*const ast.Expr =
            if (self.isNullLiteral(bin.right)) bin.left else if (self.isNullLiteral(bin.left)) bin.right else null;
        const op = operand orelse return;
        if (op.* != .field_access) return;
        if (self.exprPath(op)) |p| {
            out_path.* = p;
            out_then.* = is_neq;
        }
    }
    fn pushNarrowedPath(self: *TypeInferencer, path: []const u8) bool {
        if (self.narrowed_paths.contains(path)) return false;
        const key = self.arena.allocator().dupe(u8, path) catch return false;
        self.narrowed_paths.put(key, {}) catch {
            self.arena.allocator().free(key);
            return false;
        };
        return true;
    }
    fn popNarrowedPath(self: *TypeInferencer, path: []const u8) void {
        if (self.narrowed_paths.fetchRemove(path)) |kv| {
            self.arena.allocator().free(kv.key);
        }
    }
    fn applyNarrowing(self: *TypeInferencer, env: *TypeEnv, narrowings: []const NarrowingInfo, want_non_null: bool) void {
        for (narrowings) |n| {
            if (n.is_non_null == want_non_null) {
                if (env.lookup(n.name)) |scheme| {
                    const resolved = self.resolve(scheme.ty);
                    if (resolved.* == .nullable_type) {
                        const narrowed_scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = resolved.nullable_type };
                        env.define(n.name, narrowed_scheme) catch {};
                    }
                }
            }
        }
    }
    fn tryWidenUnify(self: *TypeInferencer, t1: *Type, t2: *Type) SemaError!*Type {
        return throw_check.tryWidenUnify(self, t1, t2);
    }
    fn extractConstVal(self: *TypeInferencer, expr: *const ast.Expr, ty: *Type) ?ConstVal {
        const resolved = self.resolve(ty);
        switch (expr.*) {
            .int_literal => |lit| {
                if (!resolved.isIntType()) return null;
                const base: u8 = if (std.mem.startsWith(u8, lit.raw, "0x") or std.mem.startsWith(u8, lit.raw, "0X"))
                    16
                else if (std.mem.startsWith(u8, lit.raw, "0b") or std.mem.startsWith(u8, lit.raw, "0B"))
                    2
                else
                    10;
                const raw_str = if (base != 10) lit.raw[2..] else lit.raw;
                const val = std.fmt.parseInt(i128, raw_str, base) catch return null;
                return .{ .int_val = val };
            },
            .float_literal => |lit| {
                if (!resolved.isFloatType()) return null;
                const val = std.fmt.parseFloat(f64, lit.raw) catch return null;
                const bits: u64 = @bitCast(val);
                return .{ .float_val = @as(u128, bits) };
            },
            .bool_literal => |lit| {
                if (resolved.* != .bool_type) return null;
                return .{ .bool_val = lit.value };
            },
            .char_literal => |lit| {
                if (resolved.* != .char_type) return null;
                return .{ .char_val = lit.value };
            },
            else => return null,
        }
    }
    fn extractTypeArgs(self: *TypeInferencer, ty: *Type) ?[]const []const u8 {
        const resolved = self.resolve(ty);
        const args: []const *Type = switch (resolved.*) {
            .generic_type => |gt| gt.args,
            .adt_type => |at| at.type_args,
            else => return null,
        };
        if (args.len == 0) return null;
        const names = self.arena.allocator().alloc([]const u8, args.len) catch return null;
        for (args, 0..) |arg, i| {
            names[i] = typeNameOfType(self.resolve(arg)) orelse return null;
        }
        return names;
    }
    fn extractFnSig(self: *TypeInferencer, ty: *Type) ?FnSigRef {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .fn_type => |ft| {
                const param_types = self.arena.allocator().alloc(ChanType, ft.params.len) catch return null;
                for (ft.params, 0..) |p, i| {
                    param_types[i] = semaTypeToChanType(p) orelse .ref_chan;
                }
                const return_type = semaTypeToChanType(ft.return_type) orelse .ref_chan;
                return .{
                    .param_types = param_types,
                    .return_type = return_type,
                };
            },
            else => return null,
        }
    }
    /// 推断表达式的类型。这是类型检查的核心入口，递归处理所有表达式变体，
    /// 结合 expected 类型进行双向类型检查。返回推断出的类型。
    /// 表达式类型推断入口（wrapper）：委托 inferExprInner 完成实际推断，
    /// 若 sema_result 已设置，则把 (expr 指针地址 → ChanType) 记录到 SemaResult.expr_types，
    /// 供 IRBuilder 在图构建时读取（驱动式接入）。
    pub fn inferExpr(self: *TypeInferencer, expr: *const ast.Expr, env: *TypeEnv, expected: ?*Type) SemaError!*Type {
        const ty = try self.inferExprInner(expr, env, expected);
        if (self.sema_result) |sr| {
            if (semaTypeToChanType(ty)) |ct| {
                const type_name: ?[]const u8 = typeNameOfType(ty);
                var inner_ct: ChanType = .null_chan;
                if (ty.* == .nullable_type) {
                    inner_ct = semaTypeToChanType(ty.nullable_type) orelse .ref_chan;
                }
                const is_ref = switch (ty.*) {
                    .ref_type => true,
                    else => false,
                };
                const resolved_ty = self.resolve(ty);
                const is_raw_ref = switch (resolved_ty.*) {
                    .ref_type => |rt| rt.is_raw,
                    else => false,
                };
                sr.putExpr(@intFromPtr(expr), .{
                    .chan_type = ct,
                    .inner_type = inner_ct,
                    .type_name = type_name,
                    .is_ref_type = is_ref,
                    .is_raw_ref = is_raw_ref,
                    .const_val = self.extractConstVal(expr, ty),
                    .type_args = self.extractTypeArgs(ty),
                    .fn_sig = self.extractFnSig(ty),
                }) catch {};
            }
        }
        return ty;
    }
    fn inferExprInner(self: *TypeInferencer, expr: *const ast.Expr, env: *TypeEnv, expected: ?*Type) SemaError!*Type {
        return switch (expr.*) {
            .int_literal => |lit| {
                if (lit.suffix) |suffix| {
                    inline for (INT_SUFFIXES) |entry| {
                        if (std.mem.eql(u8, suffix, entry.name)) return self.makeType(entry.ty);
                    }
                }
                if (expected) |exp_ty| {
                    const resolved = self.resolve(exp_ty);
                    if (resolved.isIntType()) {
                        return exp_ty;
                    }
                }
                // Rust 模式：无约束时整数字面量默认回退 i32
                // 与 Rust/Java/C 默认 int 一致，避免类型随值大小漂移；
                // 有后缀或 expected 约束时由上方分支处理。
                return self.makeType(.i32_type);
            },
            .float_literal => |lit| {
                if (lit.suffix) |suffix| {
                    inline for (FLOAT_SUFFIXES) |entry| {
                        if (std.mem.eql(u8, suffix, entry.name)) return self.makeType(entry.ty);
                    }
                }
                if (expected) |exp_ty| {
                    const resolved = self.resolve(exp_ty);
                    if (resolved.isFloatType()) {
                        return exp_ty;
                    }
                }
                // Rust 模式：无约束时浮点字面量默认回退 f32
                // 与 Rust 默认浮点（f64）不同，Glue 选择 f32 以兼顾精度与内存；
                // 有后缀或 expected 约束时由上方分支处理。
                return self.makeType(.f32_type);
            },
            .bool_literal => self.makeType(.bool_type),
            .char_literal => self.makeType(.char_type),
            .string_literal => self.makeType(.str_type),
            .null_literal => {
                const tv = try self.freshTypeVar();
                return self.makeNullableType(tv);
            },
            .unit_literal => self.makeType(.unit_type),
            .identifier => |id| {
                if (env.lookup(id.name)) |scheme| {
                    if (self.current_fn_info) |fn_info| {
                        if (std.mem.eql(u8, id.name, fn_info.name) and
                            fn_info.has_type_params and
                            !fn_info.has_return_annotation and
                            scheme.quantified_vars.len > 0)
                        {
                            const loc = ast.exprLocation(expr);
                            self.addErrorAt(.recursive_type, loc.line, loc.column, "polymorphic recursive function '{s}' requires an explicit return type annotation", .{id.name});
                            return scheme.ty;
                        }
                    }
                    const ty = try self.instantiate(scheme);
                    return ty;
                }
                if (self.known_modules.contains(id.name)) {
                    return self.makeModuleRef(id.name) catch error.OutOfMemory;
                }
                // import 别名查找：短名 → 模块或符号
                if (self.sema_result) |sr| {
                    if (sr.getImportAlias(id.name)) |target| {
                        switch (target) {
                            .module => |full_path| {
                                return self.makeModuleRef(full_path) catch error.OutOfMemory;
                            },
                            .symbol => |mangled| {
                                // 函数/常量引用：查环境获取 mangled 名对应的类型
                                if (env.lookup(mangled)) |scheme| {
                                    return try self.instantiate(scheme);
                                }
                                // 未在环境中找到（可能是常量），返回 fresh var
                                return self.freshTypeVar() catch error.OutOfMemory;
                            },
                        }
                    }
                }
                const id_loc = ast.exprLocation(expr);
                self.addErrorAt(.unbound_variable, id_loc.line, id_loc.column, "undefined variable '{s}'", .{id.name});
                return self.freshTypeVar() catch error.OutOfMemory;
            },
            .binary => |bin| {
                var left_ty = try self.inferExpr(bin.left, env, null);
                var right_ty = try self.inferExpr(bin.right, env, null);
                left_ty = self.unwrapAtomic(left_ty);
                right_ty = self.unwrapAtomic(right_ty);
                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        const rl = self.resolve(left_ty);
                        const rr = self.resolve(right_ty);
                        // 数值算术（Rust 风格）：字面量可提升到变量类型，
                        // 两个显式变量类型不同则报错（需显式 cast）。int/float 规则对称。
                        if (rl.isNumericType() and rr.isNumericType()) {
                            return try self.numericOpType(left_ty, right_ty, bin.left, bin.right, true);
                        }
                        try self.unify(left_ty, right_ty);
                        return left_ty;
                    },
                    .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => {
                        const rl = self.resolve(left_ty);
                        const rr = self.resolve(right_ty);
                        // 数值比较（Rust 风格）：字面量可提升，两个显式变量类型必须相同
                        if (rl.isNumericType() and rr.isNumericType()) {
                            _ = try self.numericOpType(left_ty, right_ty, bin.left, bin.right, false);
                            return self.makeType(.bool_type);
                        }
                        // 其他类型：严格 unify
                        try self.unify(left_ty, right_ty);
                        return self.makeType(.bool_type);
                    },
                    .and_op, .or_op => {
                        try self.unify(left_ty, try self.makeType(.bool_type));
                        try self.unify(right_ty, try self.makeType(.bool_type));
                        return self.makeType(.bool_type);
                    },
                    .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                        try self.unify(left_ty, right_ty);
                        return left_ty;
                    },
                    .concat => {
                        try self.unify(left_ty, try self.makeType(.str_type));
                        try self.unify(right_ty, try self.makeType(.str_type));
                        return self.makeType(.str_type);
                    },
                    .concat_list => {
                        const elem_ty = try self.freshTypeVar();
                        const arr_ty = try self.arena.allocator().create(Type);
                        arr_ty.* = Type{ .array_type = .{ .element_type = elem_ty, .size = null } };
                        try self.types.append(self.arena.allocator(), arr_ty);
                        try self.unify(left_ty, arr_ty);
                        try self.unify(right_ty, arr_ty);
                        return arr_ty;
                    },
                    .range, .range_inclusive => {
                        // Range 元素类型默认 usize（数组索引/计数场景）
                        // 字面量操作数会经 expected=usize 路径自动提升
                        const usize_ty = try self.makeType(.usize_type);
                        _ = self.tryWidenUnify(usize_ty, left_ty) catch {
                            try self.unify(left_ty, usize_ty);
                        };
                        _ = self.tryWidenUnify(usize_ty, right_ty) catch {
                            try self.unify(right_ty, usize_ty);
                        };
                        return self.makeType(.usize_type);
                    },
                    .elvis => {
                        const rl = self.resolve(left_ty);
                        if (rl.* == .nullable_type) {
                            return rl.nullable_type;
                        }
                        return left_ty;
                    },
                }
            },
            .unary => |un| {
                const operand_ty = try self.inferExpr(un.operand, env, null);
                return switch (un.op) {
                    .not => {
                        // ! 对 bool 逻辑取反，~ 对整数按位取反
                        // 两者在 sema 层都返回操作数类型
                        // 编译器根据操作数类型分派到 bool_not 或 int_not
                        return operand_ty;
                    },
                    .bit_not => {
                        // ~ 对整数按位取反，返回操作数类型
                        return operand_ty;
                    },
                    .neg => operand_ty,
                };
            },
            .ref_of => |r| {
                // &expr：返回 ref_type(inner = expr 类型)
                const inner_ty = try self.inferExpr(r.operand, env, null);
                return self.makeRefType(inner_ty, false);
            },
            .deref => |d| {
                // *expr：解引用，返回 ref_type.inner
                const operand_ty = try self.inferExpr(d.operand, env, null);
                const resolved = self.resolve(operand_ty);
                switch (resolved.*) {
                    .ref_type => |rt| return rt.inner,
                    else => return operand_ty, // 非引用类型解引用：返回原类型（运行期可能报错）
                }
            },
            .lambda => |lam| {
                const child_env = try env.createChild();
                var param_types = try self.arena.allocator().alloc(*Type, lam.params.len);
                for (lam.params, 0..) |param, i| {
                    const param_ty = if (param.type_annotation) |ta|
                        try self.typeFromAst(ta)
                    else
                        try self.freshTypeVar();
                    param_types[i] = param_ty;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                    try child_env.define(param.name, scheme);
                }
                self.pushLinearScope();
                const body_ty = switch (lam.body) {
                    .block => |body| try self.inferExpr(body, child_env, null),
                    .expression => |e| try self.inferExpr(e, child_env, null),
                };
                self.popLinearScope();
                const ret_ty = if (lam.is_async)
                    try self.makeGenericType("Async", &[_]*Type{body_ty})
                else
                    body_ty;
                return self.makeFnType(param_types, ret_ty);
            },
            .call => |c| {
                const loc = ast.exprLocation(expr);
                // typeof 内建函数特殊处理：参数是类型引用（在值位置传递类型名）
                // 不走常规函数调用推断，直接构造 TypeInfo<T> 类型
                if (c.callee.* == .identifier) {
                    const callee_name = c.callee.identifier.name;
                    if (std.mem.eql(u8, callee_name, "typeof") and self.isBuiltinName("typeof")) {
                        return try self.inferTypeofCall(c.arguments, env, loc);
                    }
                }
                const callee_ty = try self.inferExpr(c.callee, env, null);
                const ret_ty = try self.freshTypeVar();
                const resolved_callee = self.resolve(callee_ty);
                switch (resolved_callee.*) {
                    .fn_type => |ft| {
                        if (ft.params.len == c.arguments.len) {
                            var arg_types = try self.arena.allocator().alloc(*Type, c.arguments.len);
                            for (c.arguments, ft.params, 0..) |arg, param_ty, i| {
                                arg_types[i] = try self.inferExpr(arg, env, param_ty);
                            }
                            var all_ok = true;
                            for (ft.params, arg_types) |param_ty, arg_ty| {
                                _ = self.tryWidenUnify(param_ty, arg_ty) catch {
                                    all_ok = false;
                                    break;
                                };
                            }
                            if (all_ok) {
                                self.checkCallSiteTraitBound(c.callee, loc);
                                return ft.return_type;
                            }
                        }
                    },
                    else => {},
                }
                var arg_types = try self.arena.allocator().alloc(*Type, c.arguments.len);
                for (c.arguments, 0..) |arg, i| {
                    arg_types[i] = try self.inferExpr(arg, env, null);
                }
                {
                    const rc = self.resolve(callee_ty);
                    if (rc.* == .fn_type and rc.fn_type.params.len == arg_types.len) {
                        for (rc.fn_type.params, 0..) |param_ty, i| {
                            if (self.asModuleRef(arg_types[i])) |mod_name| {
                                const rp = self.resolve(param_ty);
                                if (rp.* == .trait_type) {
                                    const res = self.moduleSatisfiesTrait(mod_name, rp.trait_type.name);
                                    if (res.ok) {
                                        arg_types[i] = param_ty;
                                    } else {
                                        switch (res.reason) {
                                            .missing => self.addErrorAt(.type_mismatch, loc.line, loc.column, "module '{s}' does not structurally satisfy trait '{s}': missing method '{s}'", .{ mod_name, rp.trait_type.name, res.missing_method.? }),
                                            .arity_mismatch => self.addErrorAt(.type_mismatch, loc.line, loc.column, "module '{s}' does not structurally satisfy trait '{s}': method '{s}' expects {d} param(s), got {d}", .{ mod_name, rp.trait_type.name, res.missing_method.?, res.arity_expected, res.arity_got }),
                                            .ok => {},
                                        }
                                        return ret_ty;
                                    }
                                }
                            }
                        }
                    }
                }
                {
                    const rc = self.resolve(callee_ty);
                    if (rc.* == .fn_type and rc.fn_type.params.len == arg_types.len) {
                        for (rc.fn_type.params, arg_types) |param_ty, arg_ty| {
                            if (!self.recordArgSatisfies(param_ty, arg_ty)) {
                                self.addErrorAt(.type_mismatch, loc.line, loc.column, "record argument missing required field(s) of parameter type", .{});
                                return ret_ty;
                            }
                            if (self.nullableViolation(param_ty, arg_ty)) {
                                self.addErrorAt(.type_mismatch, loc.line, loc.column, "cannot pass a nullable argument where a non-nullable type is expected (use '!' or '??' to unwrap)", .{});
                                return ret_ty;
                            }
                        }
                    }
                }
                switch (resolved_callee.*) {
                    .fn_type => |ft| {
                        if (ft.params.len == arg_types.len) {
                            var all_ok = true;
                            for (ft.params, arg_types) |param_ty, arg_ty| {
                                _ = self.tryWidenUnify(param_ty, arg_ty) catch {
                                    all_ok = false;
                                    break;
                                };
                            }
                            if (all_ok) {
                                self.checkCallSiteTraitBound(c.callee, loc);
                                return ft.return_type;
                            }
                        }
                        const expected_fn_ty = try self.makeFnType(arg_types, ret_ty);
                        if (self.unify(callee_ty, expected_fn_ty)) {
                            self.checkCallSiteTraitBound(c.callee, loc);
                            return ret_ty;
                        } else |_| {
                            if (c.arguments.len < ft.params.len) {
                                var all_ok = true;
                                for (arg_types, 0..) |arg_ty, i| {
                                    if (self.tryWidenUnify(ft.params[i], arg_ty)) |_| {} else |_| {
                                        all_ok = false;
                                        break;
                                    }
                                }
                                if (all_ok) {
                                    self.checkCallSiteTraitBound(c.callee, loc);
                                    const remaining_count = ft.params.len - c.arguments.len;
                                    var remaining_params = try self.arena.allocator().alloc(*Type, remaining_count);
                                    for (0..remaining_count) |i| {
                                        remaining_params[i] = ft.params[c.arguments.len + i];
                                    }
                                    return self.makeFnType(remaining_params, ft.return_type);
                                }
                            }
                            if (ft.params.len == arg_types.len) {
                                var all_ok = true;
                                for (ft.params, arg_types) |param_ty, arg_ty| {
                                    _ = self.tryWidenUnify(param_ty, arg_ty) catch {
                                        all_ok = false;
                                        break;
                                    };
                                }
                                if (all_ok) {
                                    self.checkCallSiteTraitBound(c.callee, loc);
                                    return ft.return_type;
                                }
                            }
                        }
                    },
                    else => {},
                }
                return error.TypeMismatch;
            },
            .if_expr => |ie| {
                const cond_ty = try self.inferExpr(ie.condition, env, null);
                try self.unify(cond_ty, try self.makeType(.bool_type));
                const narrowings = self.analyzeNullCheck(ie.condition);
                var narrow_path: ?[]const u8 = null;
                var path_non_null_in_then = true;
                self.fieldPathNullCheck(ie.condition, &narrow_path, &path_non_null_in_then);
                defer if (narrow_path) |p| self.arena.allocator().free(p);
                const then_env = try env.createChild();
                self.applyNarrowing(then_env, narrowings, true);
                self.pushLinearScope();
                const added_then = if (narrow_path != null and path_non_null_in_then)
                    self.pushNarrowedPath(narrow_path.?)
                else
                    false;
                const then_ty = try self.inferExpr(ie.then_branch, then_env, expected);
                if (added_then) self.popNarrowedPath(narrow_path.?);
                self.popLinearScope();
                if (ie.else_branch) |else_br| {
                    const else_env = try env.createChild();
                    self.applyNarrowing(else_env, narrowings, false);
                    self.pushLinearScope();
                    const added_else = if (narrow_path != null and !path_non_null_in_then)
                        self.pushNarrowedPath(narrow_path.?)
                    else
                        false;
                    const else_ty = try self.inferExpr(else_br, else_env, expected);
                    if (added_else) self.popNarrowedPath(narrow_path.?);
                    self.popLinearScope();
                    const rthen = self.resolve(then_ty);
                    const relse = self.resolve(else_ty);
                    if (rthen.* == .unit_type and relse.* != .unit_type) return else_ty;
                    if (relse.* == .unit_type and rthen.* != .unit_type) return then_ty;
                    const unified = try self.tryWidenUnify(then_ty, else_ty);
                    return unified;
                }
                return then_ty;
            },
            .block => |blk| {
                const child_env = try env.createChild();
                self.pushLinearScope();
                var result_ty = try self.makeType(.unit_type);
                for (blk.statements) |stmt| {
                    const stmt_ty = try self.inferStmt(stmt, child_env);
                    // return_stmt 的类型是函数返回值，在没有尾表达式时用作 block 类型
                    switch (stmt.*) {
                        .return_stmt => {
                            if (stmt_ty) |st| result_ty = st;
                        },
                        else => {},
                    }
                }
                if (blk.trailing_expr) |te| {
                    result_ty = try self.inferExpr(te, child_env, null);
                }
                self.popLinearScope();
                return result_ty;
            },
            .match => |m| {
                const scrutinee_ty = try self.inferExpr(m.scrutinee, env, null);
                const resolved_scrutinee = self.resolve(scrutinee_ty);
                const nullable_inner: ?*Type = switch (resolved_scrutinee.*) {
                    .nullable_type => |inner| inner,
                    else => null,
                };
                const is_gadt_scrutinee = blk: {
                    const rs = resolved_scrutinee;
                    if (rs.* == .adt_type) {
                        if (self.adt_types.get(rs.adt_type.name)) |info| break :blk info.is_gadt;
                    }
                    break :blk false;
                };
                var result_ty: ?*Type = null;
                for (m.arms) |arm| {
                    const child_env = try env.createChild();
                    const arm_matches_null = self.patternCoversNull(arm.pattern);
                    var pattern_ty: *Type = if (nullable_inner) |inner|
                        if (arm_matches_null) scrutinee_ty else inner
                    else
                        scrutinee_ty;
                    if (is_gadt_scrutinee) {
                        pattern_ty = self.freshenType(scrutinee_ty) catch scrutinee_ty;
                    }
                    try self.inferPattern(arm.pattern, pattern_ty, child_env);
                    self.pushLinearScope();
                    const body_ty = try self.inferExpr(arm.body, child_env, null);
                    self.popLinearScope();
                    if (is_gadt_scrutinee) {
                        if (result_ty == null) result_ty = try self.freshTypeVar();
                    } else if (result_ty) |rt| {
                        const unified = try self.tryWidenUnify(rt, body_ty);
                        result_ty = unified;
                    } else {
                        result_ty = body_ty;
                    }
                }
                self.checkExhaustiveness(scrutinee_ty, m.arms, ast.exprLocation(expr));
                return result_ty orelse self.makeType(.unit_type);
            },
            .array_literal => |al| {
                if (al.elements.len == 0) return self.freshTypeVar() catch unreachable;
                const first_ty = self.inferExpr(al.elements[0], env, null) catch return self.freshTypeVar() catch unreachable;
                for (al.elements[1..]) |elem| {
                    const elem_ty = self.inferExpr(elem, env, null) catch continue;
                    _ = self.tryWidenUnify(first_ty, elem_ty) catch {
                        self.unify(first_ty, elem_ty) catch {};
                    };
                }
                return self.makeArrayType(first_ty, null) catch unreachable;
            },
            .record_literal => |rl| {
                var fields = try self.arena.allocator().alloc(FieldType, rl.fields.len);
                for (rl.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.inferExpr(f.value, env, null),
                    };
                }
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .record_type = .{ .fields = fields } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            .record_extend => |re| {
                const re_loc = ast.exprLocation(expr);
                const base_ty = self.inferExpr(re.base, env, null) catch return self.freshTypeVar() catch unreachable;
                const resolved_base = self.resolve(base_ty);
                switch (resolved_base.*) {
                    .record_type => |rt| {
                        var all_fields = std.ArrayList(FieldType).empty;
                        for (rt.fields) |f| {
                            try all_fields.append(self.arena.allocator(), f);
                        }
                        for (re.updates) |update| {
                            const update_ty = try self.inferExpr(update.value, env, null);
                            var found = false;
                            for (all_fields.items, 0..) |*f, i| {
                                if (std.mem.eql(u8, f.name, update.name)) {
                                    all_fields.items[i].ty = update_ty;
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try all_fields.append(self.arena.allocator(), FieldType{
                                    .name = update.name,
                                    .ty = update_ty,
                                });
                            }
                        }
                        const t = try self.arena.allocator().create(Type);
                        t.* = Type{ .record_type = .{ .fields = try all_fields.toOwnedSlice(self.arena.allocator()) } };
                        try self.types.append(self.arena.allocator(), t);
                        return t;
                    },
                    else => {
                        self.addErrorAt(.type_mismatch, re_loc.line, re_loc.column, "record extend requires record type, got {}", .{resolved_base.*});
                        return self.freshTypeVar() catch unreachable;
                    },
                }
            },
            .field_access => |fa| {
                const fa_loc = ast.exprLocation(expr);
                const obj_ty = self.inferExpr(fa.object, env, null) catch return self.freshTypeVar() catch unreachable;
                // 类型即模块：如果 object 是 identifier 且在 import_aliases 中为 .module，
                // 优先按模块引用处理（即使 env 中有同名构造器函数类型）
                var effective_mod_ref: ?[]const u8 = self.asModuleRef(obj_ty);
                if (effective_mod_ref == null and fa.object.* == .identifier) {
                    if (self.sema_result) |sr| {
                        if (sr.getImportAlias(fa.object.identifier.name)) |target| {
                            if (target == .module) effective_mod_ref = target.module;
                        }
                    }
                }
                if (effective_mod_ref) |mod_name| {
                    if (self.module_submodules.get(mod_name)) |subs| {
                        for (subs) |sub| {
                            if (std.mem.eql(u8, sub, fa.field)) {
                                // 使用完整模块名 "Parent.Sub"，使后续方法查找能匹配
                                const full = std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ mod_name, fa.field }) catch return self.freshTypeVar() catch unreachable;
                                return self.makeModuleRef(full) catch unreachable;
                            }
                        }
                    }
                    const key = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00{s}", .{ mod_name, fa.field }) catch return self.freshTypeVar() catch unreachable;
                    defer self.arena.allocator().free(key);
                    if (self.exported_schemes.get(key)) |scheme| {
                        return self.instantiate(scheme) catch unreachable;
                    }
                    // import 别名 fallback：模块短名的字段访问，确认函数存在
                    // 如 Calendar.is_leap_year → "std.time.Calendar.is_leap_year"
                    // 精确类型推断由 IR 层处理，sema 返回 fresh var
                    if (self.sema_result) |sr| {
                        const mangled = std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ mod_name, fa.field }) catch return self.freshTypeVar() catch unreachable;
                        defer self.arena.allocator().free(mangled);
                        if (sr.func_sig_index.contains(mangled)) {
                            return self.freshTypeVar() catch unreachable;
                        }
                    }
                    return self.freshTypeVar() catch unreachable;
                }
                const resolved = self.resolve(obj_ty);
                var eff_resolved = resolved;
                if (eff_resolved.* == .nullable_type) {
                    if (self.exprPath(fa.object)) |op| {
                        defer self.arena.allocator().free(op);
                        if (self.narrowed_paths.contains(op)) {
                            eff_resolved = self.resolve(eff_resolved.nullable_type);
                        }
                    }
                }
                if (eff_resolved.* == .nullable_type) {
                    self.addErrorAt(.type_mismatch, fa_loc.line, fa_loc.column, "cannot access field '{s}' on nullable type; use '?.', '!', or narrow with 'if x != null' first", .{fa.field});
                    return self.freshTypeVar() catch unreachable;
                }
                switch (eff_resolved.*) {
                    .record_type => |rt| {
                        for (rt.fields) |field| {
                            if (std.mem.eql(u8, field.name, fa.field)) {
                                return field.ty;
                            }
                        }
                        self.addErrorAt(.type_mismatch, fa_loc.line, fa_loc.column, "record type has no field named '{s}'", .{fa.field});
                        return self.freshTypeVar() catch unreachable;
                    },
                    .adt_type => |at| {
                        if (self.adt_types.get(at.name)) |info| {
                            if (info.type_param_names.len == 0) {
                                for (info.ctor_field_names, 0..) |fns, ci| {
                                    for (fns, 0..) |fname_opt, fi| {
                                        if (fname_opt) |fname| {
                                            if (std.mem.eql(u8, fname, fa.field)) {
                                                return info.ctor_field_types[ci][fi];
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        return self.freshTypeVar() catch unreachable;
                    },
                    else => return self.freshTypeVar() catch unreachable,
                }
            },
            .method_call => |mc| {
                const result_ty = try trait_resolve.inferMethodCall(self, expr, mc, env);
                if (std.mem.eql(u8, mc.method, "await") or std.mem.eql(u8, mc.method, "cancel")) {
                    const obj_ty = self.inferExpr(mc.object, env, null) catch return result_ty;
                    if (self.isAsyncType(obj_ty)) {
                        if (self.getIdentifierName(mc.object)) |name| {
                            self.markLinearVarConsumed(name);
                        }
                    }
                }
                return result_ty;
            },
            .propagate => |prop| {
                const inner_ty = try self.inferExpr(prop.expr, env, null);
                const resolved_inner = self.resolve(inner_ty);
                return throw_check.checkPropagate(self, resolved_inner, inner_ty, self.current_fn_return_type, ast.exprLocation(expr));
            },
            .non_null_assert => |nna| {
                const inner = try self.inferExpr(nna.expr, env, null);
                const ri = self.resolve(inner);
                if (ri.* == .nullable_type) {
                    return ri.nullable_type;
                }
                return inner;
            },
            .safe_access => |sa| {
                const obj_ty = self.inferExpr(sa.object, env, null) catch return self.freshTypeVar() catch unreachable;
                const resolved = self.resolve(obj_ty);
                // 如果 obj 是 nullable<T>，解包 T 后查找字段；否则直接在 obj 上查找
                const inner_ty = if (resolved.* == .nullable_type) resolved.nullable_type else obj_ty;
                const inner_resolved = self.resolve(inner_ty);
                const field_ty: *Type = switch (inner_resolved.*) {
                    .record_type => |rt| blk: {
                        for (rt.fields) |field| {
                            if (std.mem.eql(u8, field.name, sa.field)) break :blk field.ty;
                        }
                        break :blk self.freshTypeVar() catch unreachable;
                    },
                    .adt_type => |at| blk: {
                        if (self.adt_types.get(at.name)) |info| {
                            if (info.type_param_names.len == 0) {
                                for (info.ctor_field_names, 0..) |fns, ci| {
                                    for (fns, 0..) |fname_opt, fi| {
                                        if (fname_opt) |fname| {
                                            if (std.mem.eql(u8, fname, sa.field)) {
                                                break :blk info.ctor_field_types[ci][fi];
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        break :blk self.freshTypeVar() catch unreachable;
                    },
                    else => self.freshTypeVar() catch unreachable,
                };
                // 如果字段本身是 nullable<T>，结果也是 nullable<T>（避免嵌套 nullable）
                const field_resolved = self.resolve(field_ty);
                if (field_resolved.* == .nullable_type) {
                    return field_resolved;
                }
                return self.makeNullableType(field_ty) catch unreachable;
            },
            .safe_method_call => |smc| {
                return trait_resolve.inferSafeMethodCall(self, smc, env);
            },
            .index => |idx| {
                const obj_ty = self.inferExpr(idx.object, env, null) catch return self.freshTypeVar() catch unreachable;
                // Phase 5: 数组索引类型强制 usize（spec §8.1）
                // 字面量经 expected 路径自动提升；显式整数变量若非 usize 需报错
                const usize_ty = try self.makeType(.usize_type);
                const idx_ty = self.inferExpr(idx.index, env, usize_ty) catch |err| {
                    if (err == error.TypeMismatch) {
                        const loc = ast.exprLocation(idx.index);
                        var idx_buf = std.ArrayList(u8).empty;
                        defer idx_buf.deinit(self.arena.allocator());
                        const actual_ty = self.inferExpr(idx.index, env, null) catch return self.freshTypeVar() catch unreachable;
                        actual_ty.formatArrayList(&idx_buf, self.arena.allocator()) catch {};
                        self.addErrorAt(.type_mismatch, loc.line, loc.column, "array index must be usize, got {s}; use cast(x).to(usize) to convert", .{idx_buf.items});
                        return self.freshTypeVar() catch unreachable;
                    }
                    return self.freshTypeVar() catch unreachable;
                };
                _ = idx_ty;
                const resolved = self.resolve(obj_ty);
                switch (resolved.*) {
                    .array_type => |at| return at.element_type,
                    else => return self.freshTypeVar() catch unreachable,
                }
            },
            .slice => |sl| {
                // arr[start..end] / s[start..end]：返回与对象相同类型
                _ = self.inferExpr(sl.start, env, null) catch return self.freshTypeVar() catch unreachable;
                _ = self.inferExpr(sl.end, env, null) catch return self.freshTypeVar() catch unreachable;
                const obj_ty = self.inferExpr(sl.object, env, null) catch return self.freshTypeVar() catch unreachable;
                const resolved = self.resolve(obj_ty);
                switch (resolved.*) {
                    // 数组切片返回相同元素类型的数组
                    .array_type => |at| {
                        const arr_ty = self.arena.allocator().create(Type) catch return self.freshTypeVar() catch unreachable;
                        arr_ty.* = Type{ .array_type = .{ .element_type = at.element_type, .size = null } };
                        self.types.append(self.arena.allocator(), arr_ty) catch return self.freshTypeVar() catch unreachable;
                        return arr_ty;
                    },
                    // 字符串切片返回字符串
                    .str_type => return self.makeType(.str_type),
                    else => return self.freshTypeVar() catch unreachable,
                }
            },
            .string_interpolation => {
                return self.makeType(.str_type);
            },
            .type_cast => |tc| {
                _ = try self.inferExpr(tc.expr, env, null);
                return self.typeFromAst(tc.target_type);
            },
            .cast_builder => |cb| {
                // Phase 3 cast builder：cast(expr).to(T) / cast(expr).try_to(T)
                // to: wrap on overflow / panic on Inf / panic on parse failure
                // try_to: returns Throw<T, CastError>
                // 注：isWidening 已在 Phase 4 重写为精确路径表，可用于未来 narrowing 诊断
                _ = try self.inferExpr(cb.expr, env, null);
                const target_ty = try self.typeFromAst(cb.target_type);
                switch (cb.mode) {
                    .to => return target_ty,
                    .try_to => {
                        // 结果类型 = Throw<T, CastError>
                        // CastError 已在 registerBuiltins 注册为 ADT（is_error_newtype=true）
                        const cast_error_ty = self.adt_types.get("CastError") orelse {
                            self.addErrorAt(.type_mismatch, ast.exprLocation(expr).line, ast.exprLocation(expr).column, "CastError builtin not registered", .{});
                            return self.freshTypeVar() catch unreachable;
                        };
                        const throw_ty = self.arena.allocator().create(Type) catch return self.freshTypeVar() catch unreachable;
                        throw_ty.* = Type{ .throw_type = .{ .value_type = target_ty, .error_type = cast_error_ty.ty } };
                        self.types.append(self.arena.allocator(), throw_ty) catch return self.freshTypeVar() catch unreachable;
                        return throw_ty;
                    },
                }
            },
            .assignment_expr => |ae| {
                const val_ty = try self.inferExpr(ae.value, env, null);
                if (self.isAsyncType(val_ty)) {
                    if (self.getIdentifierName(ae.target)) |name| {
                        const ae_loc = ast.exprLocation(expr);
                        self.registerLinearVar(name, ae_loc.line, ae_loc.column);
                    }
                }
                return val_ty;
            },
            .compound_assign => |ca| {
                var target_ty = try self.inferExpr(ca.target, env, null);
                target_ty = self.unwrapAtomic(target_ty);
                var val_ty = try self.inferExpr(ca.value, env, target_ty);
                val_ty = self.unwrapAtomic(val_ty);
                switch (ca.op) {
                    .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign => {
                        _ = self.tryWidenUnify(target_ty, val_ty) catch {
                            try self.unify(target_ty, val_ty);
                        };
                        return target_ty;
                    },
                    .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => {
                        try self.unify(target_ty, val_ty);
                        return target_ty;
                    },
                }
            },
            .atomic_expr => |ae| {
                var inner_expected: ?*Type = null;
                if (expected) |exp| {
                    const resolved_exp = self.resolve(exp);
                    if (resolved_exp.* == .generic_type) {
                        const gt = resolved_exp.generic_type;
                        if (std.mem.eql(u8, gt.name, "Atomic") and gt.args.len == 1) {
                            inner_expected = gt.args[0];
                        }
                    }
                }
                const val_ty = try self.inferExpr(ae.value, env, inner_expected);
                return self.makeGenericType("Atomic", &[_]*Type{val_ty});
            },
            .select => |sel| {
                var result_ty: ?*Type = null;
                for (sel.arms) |arm| {
                    switch (arm) {
                        .receive => |recv_arm| {
                            const arm_env = try env.createChild();
                            if (recv_arm.binding) |binding_name| {
                                const recv_ty = self.inferExpr(recv_arm.channel_expr, env, null) catch try self.freshTypeVar();
                                const resolved = self.resolve(recv_ty);
                                const elem_ty = if (resolved.* == .nullable_type) resolved.nullable_type else recv_ty;
                                arm_env.define(binding_name, TypeScheme{ .quantified_vars = &[_]usize{}, .ty = elem_ty }) catch {};
                            }
                            const body_ty = try self.inferExpr(recv_arm.body, arm_env, null);
                            if (result_ty == null) result_ty = body_ty;
                        },
                        .timeout => |timeout_arm| {
                            const body_ty = try self.inferExpr(timeout_arm.body, env, null);
                            if (result_ty == null) result_ty = body_ty;
                        },
                    }
                }
                return result_ty orelse try self.freshTypeVar();
            },
            .lazy => |lz| {
                _ = self.inferExpr(lz.expr, env, null) catch {};
                return self.freshTypeVar();
            },
            .inline_trait_value => {
                return self.freshTypeVar();
            },
            .spawn_expr => |sp| {
                // spawn 返回 Channel<T>，元素类型由派生表达式推断。
                // sema 侧退化为 fresh type var（不阻塞图构建），实际通道类型由 builder 决定。
                _ = self.inferExpr(sp.expr, env, null) catch try self.freshTypeVar();
                return self.freshTypeVar();
            },
        };
    }
    /// 推断语句的类型。处理声明、赋值、控制流等语句，返回可能的表达式类型。
    pub fn inferStmt(self: *TypeInferencer, stmt: *const ast.Stmt, env: *TypeEnv) SemaError!?*Type {
        switch (stmt.*) {
            .val_decl => |vd| {
                if (vd.type_annotation) |ta| kind_check.checkTypeNode(self, ta, &[_][]const u8{});
            },
            .var_decl => |vd| {
                if (vd.type_annotation) |ta| kind_check.checkTypeNode(self, ta, &[_][]const u8{});
            },
            else => {},
        }
        const loc = stmt.getLocation();
        return switch (stmt.*) {
            .val_decl => |vd| {
                if (self.isBuiltinName(vd.name)) {
                    self.addErrorAt(.type_mismatch, loc.line, loc.column, "cannot redefine built-in name '{s}'", .{vd.name});
                } else {
                    if (vd.value.* == .lambda) {
                        const lam = vd.value.*.lambda;
                        const child_env = try env.createChild();
                        const annot_fn: ?*Type = blk: {
                            if (vd.type_annotation) |ta| {
                                const at = self.typeFromAst(ta) catch break :blk null;
                                const rat = self.resolve(at);
                                if (rat.* == .fn_type) break :blk rat;
                            }
                            break :blk null;
                        };
                        var param_types = try self.arena.allocator().alloc(*Type, lam.params.len);
                        for (lam.params, 0..) |param, i| {
                            const param_ty = if (param.type_annotation) |ta|
                                try self.typeFromAst(ta)
                            else if (annot_fn) |af| (if (i < af.fn_type.params.len) af.fn_type.params[i] else try self.freshTypeVar()) else try self.freshTypeVar();
                            param_types[i] = param_ty;
                            const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                            try child_env.define(param.name, scheme);
                        }
                        const ret_ty = if (annot_fn) |af|
                            af.fn_type.return_type
                        else if (vd.type_annotation) |ta|
                            try self.typeFromAst(ta)
                        else
                            try self.freshTypeVar();
                        const fn_ty = try self.makeFnType(param_types, ret_ty);
                        const fn_scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                        try child_env.define(vd.name, fn_scheme);
                        const body_ty = switch (lam.body) {
                            .block => |body| try self.inferExpr(body, child_env, null),
                            .expression => |e| try self.inferExpr(e, child_env, null),
                        };
                        _ = self.tryWidenUnify(ret_ty, body_ty) catch {
                            self.addErrorAt(.type_mismatch, loc.line, loc.column, "val declaration annotation does not match inferred type", .{});
                        };
                        const final_scheme = try self.generalize(env, fn_ty);
                        if (!(try env.defineOrReport(vd.name, final_scheme))) {
                            self.addErrorAt(.type_mismatch, loc.line, loc.column, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                        }
                    } else {
                        const expected_ty = if (vd.type_annotation) |ta|
                            self.typeFromAstWithParams(ta, null) catch null
                        else
                            null;
                        const val_ty = try self.inferExpr(vd.value, env, expected_ty);
                        var bind_ty = val_ty;
                        if (vd.type_annotation) |ta| {
                            const annot_ty = self.typeFromAstWithParams(ta, null) catch null;
                            if (annot_ty) |at| {
                                if (self.nullableViolation(at, val_ty)) {
                                    self.addErrorAt(.type_mismatch, loc.line, loc.column, "cannot assign a nullable value to non-nullable binding '{s}' (use '!' or '??' to unwrap)", .{vd.name});
                                } else {
                                    _ = self.tryWidenUnify(at, val_ty) catch {
                                        self.addErrorAt(.type_mismatch, loc.line, loc.column, "annotation does not match value in val declaration", .{});
                                    };
                                }
                                bind_ty = at;
                            }
                        }
                        if (self.isAsyncType(val_ty)) {
                            self.registerLinearVar(vd.name, loc.line, loc.column);
                        }
                        const scheme = try self.generalize(env, bind_ty);
                        if (!(try env.defineOrReport(vd.name, scheme))) {
                            self.addErrorAt(.type_mismatch, loc.line, loc.column, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                        }
                    }
                }
                return null;
            },
            .var_decl => |vd| {
                if (self.isBuiltinName(vd.name)) {
                    self.addErrorAt(.type_mismatch, loc.line, loc.column, "cannot redefine built-in name '{s}'", .{vd.name});
                } else {
                    const expected_ty = if (vd.type_annotation) |ta|
                        self.typeFromAstWithParams(ta, null) catch null
                    else
                        null;
                    const val_ty = try self.inferExpr(vd.value, env, expected_ty);
                    var bind_ty = val_ty;
                    if (vd.type_annotation) |ta| {
                        const annot_ty = self.typeFromAstWithParams(ta, null) catch null;
                        if (annot_ty) |at| {
                            if (self.nullableViolation(at, val_ty)) {
                                self.addErrorAt(.type_mismatch, loc.line, loc.column, "cannot assign a nullable value to non-nullable binding '{s}' (use '!' or '??' to unwrap)", .{vd.name});
                            } else {
                                _ = self.tryWidenUnify(at, val_ty) catch {
                                    self.addErrorAt(.type_mismatch, loc.line, loc.column, "annotation does not match value in var declaration", .{});
                                };
                            }
                            bind_ty = at;
                        }
                    }
                    if (self.isAsyncType(val_ty)) {
                        self.registerLinearVar(vd.name, loc.line, loc.column);
                    }
                    const scheme = try self.generalize(env, bind_ty);
                    if (!(try env.defineOrReport(vd.name, scheme))) {
                        self.addErrorAt(.type_mismatch, loc.line, loc.column, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                    }
                }
                return null;
            },
            .assignment => |asgn| {
                const val_ty = try self.inferExpr(asgn.value, env, null);
                if (self.isAsyncType(val_ty)) {
                    if (self.getIdentifierName(asgn.target)) |name| {
                        self.registerLinearVar(name, loc.line, loc.column);
                    }
                }
                return null;
            },
            .field_assignment => |fa| {
                _ = try self.inferExpr(fa.value, env, null);
                return null;
            },
            .expression => |es| {
                return self.inferExpr(es.expr, env, null);
            },
            .return_stmt => |ret| {
                if (ret.value) |v| {
                    return self.inferExpr(v, env, null);
                }
                return self.makeType(.unit_type);
            },
            .defer_stmt => |ds| {
                _ = try self.inferExpr(ds.expr, env, null);
                return null;
            },
            .throw_stmt => |thr| {
                const thrown_ty = try self.inferExpr(thr.expr, env, null);
                throw_check.checkThrowStmt(self, thrown_ty, thr.location);
                return null;
            },
            .break_stmt, .continue_stmt => {
                return null;
            },
            .for_stmt => |fs| {
                const iterable_ty = try self.inferExpr(fs.iterable, env, null);
                const child_env = try env.createChild();
                const item_ty = try self.freshTypeVar();
                const resolved_iterable = self.resolve(iterable_ty);
                const is_builtin_iterable = switch (resolved_iterable.*) {
                    .array_type => true,
                    .str_type => true,
                    else => false,
                };
                if (!is_builtin_iterable) {
                    const iterable_type_name: ?[]const u8 = switch (resolved_iterable.*) {
                        .adt_type => |adt| adt.name,
                        .generic_type => |g| g.name,
                        else => null,
                    };
                    if (iterable_type_name) |tn| {
                        const trait_key = std.fmt.allocPrint(self.arena.allocator(), "Iterable::{s}", .{tn}) catch "";
                        defer {
                            if (trait_key.len > 0) self.arena.allocator().free(trait_key);
                        }
                        if (trait_key.len > 0 and !self.registered_traits.contains(trait_key)) {}
                    }
                }
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = item_ty };
                try child_env.define(fs.name, scheme);
                self.pushLinearScope();
                _ = try self.inferExpr(fs.body, child_env, null);
                self.popLinearScope();
                return null;
            },
            .while_stmt => |ws| {
                const cond_ty = try self.inferExpr(ws.condition, env, null);
                try self.unify(cond_ty, try self.makeType(.bool_type));
                self.pushLinearScope();
                _ = try self.inferExpr(ws.body, env, null);
                self.popLinearScope();
                return null;
            },
            .loop_stmt => |ls| {
                self.pushLinearScope();
                _ = try self.inferExpr(ls.body, env, null);
                self.popLinearScope();
                return null;
            },
            .compound_assignment => |ca| {
                _ = try self.inferExpr(&ast.Expr{ .compound_assign = .{
                    .op = ca.op,
                    .target = ca.target,
                    .value = ca.value,
                } }, env, null);
                return null;
            },
        };
    }
    /// 推断模式类型。将模式变量绑定到 expected_ty，处理 GADT 精化等特殊情况。
    pub fn inferPattern(self: *TypeInferencer, pat: *const ast.Pattern, expected_ty: *Type, env: *TypeEnv) SemaError!void {
        switch (pat.*) {
            .wildcard => {},
            .literal => |lit| {
                switch (lit) {
                    .null => {},
                    else => {
                        const lit_ty: ?*Type = switch (lit) {
                            .int => self.makeType(.i32_type) catch null,
                            .float => self.makeType(.f64_type) catch null,
                            .bool => self.makeType(.bool_type) catch null,
                            .char => self.makeType(.char_type) catch null,
                            .string => self.makeType(.str_type) catch null,
                            .null => null,
                        };
                        if (lit_ty) |lt| {
                            const re = self.resolve(expected_ty);
                            if (lit == .int and re.isIntType()) {} else {
                                self.unify(lt, expected_ty) catch {
                                    self.addError(.type_mismatch, "literal pattern type does not match the matched value type", .{});
                                };
                            }
                        }
                    },
                }
            },
            .variable => |v| {
                if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                    const nullary = @TypeOf(@as(ast.Pattern, undefined).constructor){
                        .name = v.name,
                        .patterns = &[_]*ast.Pattern{},
                    };
                    _ = gadt_check.refineConstructorPattern(self, nullary, expected_ty, env);
                } else {
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = expected_ty };
                    try env.define(v.name, scheme);
                }
            },
            .constructor => |con| {
                if (gadt_check.refineConstructorPattern(self, con, expected_ty, env)) {} else {
                    for (con.patterns) |sub_pat| {
                        const sub_ty = try self.freshTypeVar();
                        try self.inferPattern(sub_pat, sub_ty, env);
                    }
                }
            },
            .record => |rec| {
                for (rec.fields) |field| {
                    const field_ty = try self.freshTypeVar();
                    try self.inferPattern(field.pattern, field_ty, env);
                }
            },
            .or_pattern => |or_p| {
                try self.inferPattern(or_p.left, expected_ty, env);
                try self.inferPattern(or_p.right, expected_ty, env);
            },
            .guard => |g| {
                try self.inferPattern(g.pattern, expected_ty, env);
                const cond_ty = self.inferExpr(g.condition, env, null) catch return;
                self.unify(cond_ty, self.makeType(.bool_type) catch return) catch {
                    const g_loc = ast.patternLocation(pat);
                    self.addErrorAt(.type_mismatch, g_loc.line, g_loc.column, "match guard condition must be of type bool", .{});
                };
            },
        }
    }
    /// 将 AST 类型节点转换为内部类型表示。不带类型参数的便捷版本。
    pub fn typeFromAst(self: *TypeInferencer, type_node: *const ast.TypeNode) SemaError!*Type {
        return self.typeFromAstWithParams(type_node, self.current_type_params);
    }
    pub fn typeFromAstWithParams(self: *TypeInferencer, type_node: *const ast.TypeNode, type_param_map: ?*const std.StringHashMap(*Type)) SemaError!*Type {
        switch (type_node.*) {
            .named => |n| {
                inline for (BUILTIN_TYPES) |entry| {
                    if (std.mem.eql(u8, n.name, entry.name)) return self.makeType(entry.ty);
                }
                if (type_param_map) |tpm| {
                    if (tpm.get(n.name)) |ty| {
                        return ty;
                    }
                }
                if (self.adt_types.get(n.name)) |adt_info| {
                    return adt_info.ty;
                }
                if (self.trait_types.contains(n.name)) {
                    const t = try self.arena.allocator().create(Type);
                    t.* = Type{ .trait_type = .{ .name = n.name, .type_args = &[_]*Type{} } };
                    try self.types.append(self.arena.allocator(), t);
                    return t;
                }
                return self.makeAdtType(n.name, &[_]*Type{});
            },
            .self_type => {
                if (self.current_self_type) |self_ty| {
                    return self_ty;
                }
                const loc = ast.typeNodeLocation(type_node);
                self.addErrorAt(.type_mismatch, loc.line, loc.column, "Self type can only be used within type or trait methods", .{});
                return self.makeType(.unit_type);
            },
            .generic => |g| {
                var args = try self.arena.allocator().alloc(*Type, g.args.len);
                for (g.args, 0..) |arg, i| {
                    args[i] = try self.typeFromAstWithParams(arg, type_param_map);
                }
                if (type_param_map) |tpm| {
                    if (tpm.contains(g.name)) {
                        return self.makeGenericType(g.name, args);
                    }
                }
                if (std.mem.eql(u8, g.name, "Throw")) {
                    if (args.len == 2) {
                        const t = try self.arena.allocator().create(Type);
                        t.* = Type{ .throw_type = .{ .value_type = args[0], .error_type = args[1] } };
                        try self.types.append(self.arena.allocator(), t);
                        return t;
                    }
                }
                if (std.mem.eql(u8, g.name, "Atomic") or
                    std.mem.eql(u8, g.name, "Async") or
                    std.mem.eql(u8, g.name, "Channel") or
                    std.mem.eql(u8, g.name, "Sender") or
                    std.mem.eql(u8, g.name, "Receiver") or
                    std.mem.eql(u8, g.name, "Lazy") or
                    std.mem.eql(u8, g.name, "TypeInfo"))
                {
                    return self.makeGenericType(g.name, args);
                }
                if (self.adt_types.get(g.name)) |adt_info| {
                    if (adt_info.type_param_names.len > 0) {
                        return self.makeAdtType(g.name, args);
                    }
                }
                if (self.trait_types.contains(g.name)) {
                    const t = try self.arena.allocator().create(Type);
                    t.* = Type{ .trait_type = .{ .name = g.name, .type_args = args } };
                    try self.types.append(self.arena.allocator(), t);
                    return t;
                }
                const tn_loc = ast.typeNodeLocation(type_node);
                self.addErrorAt(.type_mismatch, tn_loc.line, tn_loc.column, "undefined type '{s}'", .{g.name});
                return self.makeAdtType(g.name, args);
            },
            .nullable => |n| {
                const inner = try self.typeFromAstWithParams(n.inner, type_param_map);
                return self.makeNullableType(inner);
            },
            .function => |f| {
                var params = try self.arena.allocator().alloc(*Type, f.params.len);
                for (f.params, 0..) |p, i| {
                    params[i] = try self.typeFromAstWithParams(p, type_param_map);
                }
                const ret = try self.typeFromAstWithParams(f.return_type, type_param_map);
                return self.makeFnType(params, ret);
            },
            .record => |r| {
                if (r.fields.len == 0) return self.makeType(.unit_type);
                var fields = try self.arena.allocator().alloc(FieldType, r.fields.len);
                for (r.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.typeFromAstWithParams(f.ty, type_param_map),
                    };
                }
                const t = try self.arena.allocator().create(Type);
                t.* = Type{ .record_type = .{ .fields = fields } };
                try self.types.append(self.arena.allocator(), t);
                return t;
            },
            .array => |a| {
                const elem = try self.typeFromAstWithParams(a.element_type, type_param_map);
                return self.makeArrayType(elem, a.size);
            },
            .kind_annotated => |ka| {
                return self.typeFromAstWithParams(ka.inner, type_param_map);
            },
            .ref_type => |rt| {
                // &T：借用引用类型，递归推导 inner 类型
                const inner = try self.typeFromAstWithParams(rt.inner, type_param_map);
                return self.makeRefType(inner, false);
            },
            .raw_ptr => |rp| {
                // *T：裸指针类型，递归推导 inner 类型，is_raw=true
                const inner = try self.typeFromAstWithParams(rp.inner, type_param_map);
                return self.makeRefType(inner, true);
            },
        }
    }
    /// 检查整个模块的类型。委托 module_check 完成实际的模块级检查。
    pub fn checkModule(self: *TypeInferencer, module: *const ast.Module) void {
        self.checkModuleWithName(module, module.name);
    }
    /// 带模块名的模块检查入口。委托 module_check 完成模块级声明检查、kind 检查、
    /// trait 检查和类型推断。
    pub fn checkModuleWithName(self: *TypeInferencer, module: *const ast.Module, module_name: []const u8) void {
        self.resetForNextModule();
        self.current_module = module_name;
        var env = TypeEnv.init(self.arena.allocator());
        defer env.deinit();
        self.registerBuiltins(&env);
        self.pushLinearScope();
        for (module.declarations) |decl| {
            if (decl == .import_decl) {
                const ud = decl.import_decl;
                self.importUseDecl(ud, &env);
                if (ud.visibility == .public) {
                    if (ud.items) |items| {
                        for (items) |item| {
                            const local = item.alias orelse item.name;
                            self.recordExportSymbol(module_name, local, &env);
                        }
                    }
                }
            }
        }
        self.registerImportedModuleStructure(module, &env);
        self.buildImportAliases(module);
        self.checkCrossKindNameClashes(module);
        self.suppress_errors = true;
        for (module.declarations) |decl| {
            if (decl == .fun_decl) {
                self.predeclareFunction(decl.fun_decl, &env);
            }
        }
        // 预声明所有 type_decl（含 newtype 构造器），使跨模块引用的构造器
        // 在函数体检查时已注册到 env（如 Instant.glue 引用 Duration 构造器）
        for (module.declarations) |decl| {
            if (decl == .type_decl) {
                self.predeclareTypeDecl(decl.type_decl, &env);
            }
        }
        self.suppress_errors = false;
        for (module.declarations) |decl| {
            self.checkDeclCollecting(decl, &env);
        }
        self.popLinearScope();
        self.recordModuleStructure(module, module_name);
    }
    /// 扫描主模块中 mangled 名函数（如 Store.Memory.put），为导入的模块注册
    /// 子模块列表和方法签名，使 Store.Memory 限定访问和模块作为 Trait 值可用。
    fn registerImportedModuleStructure(self: *TypeInferencer, module: *const ast.Module, env: *TypeEnv) void {
        for (module.declarations) |decl| {
            if (decl != .import_decl) continue;
            const ud = decl.import_decl;
            if (ud.module_path.len == 0) continue;
            // 选择性导入也需注册模块路径首段为模块引用：loadImportedDeclarations
            // 全量加载 pack 内子模块（含跨模块依赖），这些子模块内部使用完整路径
            // （如 DateTime.glue 的 std.time.DateTime.from_components），需要首段
            // （如 std）在 env 中可见，否则 sema 报 undefined variable。
            const mod = ud.module_path[0];

            // 注册模块引用变量，使 Store/std 能被识别为模块
            const mod_ty = self.makeModuleRef(mod) catch continue;
            const mod_scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = mod_ty };
            env.redefine(mod, mod_scheme) catch {};

            // 扫描 mangled 名函数 "Module.Sub.method"，提取子模块结构
            var subs = std.ArrayList([]const u8).empty;
            defer subs.deinit(self.arena.allocator());
            var subs_seen = std.StringHashMap(void).init(self.arena.allocator());
            defer subs_seen.deinit();
            // 为每个子模块收集方法签名
            var sub_sigs = std.StringHashMap(std.ArrayList(module_check.MethodSig)).init(self.arena.allocator());
            defer {
                var it = sub_sigs.iterator();
                while (it.next()) |e| e.value_ptr.deinit(self.arena.allocator());
                sub_sigs.deinit();
            }

            const prefix = std.fmt.allocPrint(self.arena.allocator(), "{s}.", .{mod}) catch continue;
            for (module.declarations) |d| {
                if (d != .fun_decl) continue;
                const f = d.fun_decl;
                if (!std.mem.startsWith(u8, f.name, prefix)) continue;
                const rest = f.name[prefix.len..];
                const sub_end = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
                const sub_name = rest[0..sub_end];
                const method_name = rest[sub_end + 1 ..];

                // 记录子模块名（去重）
                if (!subs_seen.contains(sub_name)) {
                    subs_seen.put(sub_name, {}) catch {};
                    const sub_dup = self.arena.allocator().dupe(u8, sub_name) catch continue;
                    subs.append(self.arena.allocator(), sub_dup) catch {};
                }

                // 记录方法签名到 "Module.Sub"
                const full_mod = std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ mod, sub_name }) catch continue;
                const entry = sub_sigs.getOrPut(full_mod) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayList(module_check.MethodSig).empty;
                }
                const method_dup = self.arena.allocator().dupe(u8, method_name) catch continue;
                entry.value_ptr.append(self.arena.allocator(), .{ .name = method_dup, .arity = f.params.len }) catch {};
            }

            // 记录模块的子模块列表
            self.putModuleSubmodules(mod, subs.toOwnedSlice(self.arena.allocator()) catch continue);

            // 记录每个子模块的方法签名
            var sig_it = sub_sigs.iterator();
            while (sig_it.next()) |entry| {
                const sigs = entry.value_ptr.items;
                const sigs_dup = self.arena.allocator().alloc(module_check.MethodSig, sigs.len) catch continue;
                for (sigs, 0..) |s, i| sigs_dup[i] = s;
                self.putModuleMemberSigs(entry.key_ptr.*, sigs_dup);
            }
        }
    }
    fn importUseDecl(self: *TypeInferencer, ud: anytype, env: *TypeEnv) void {
        if (ud.module_path.len == 0) return;
        const mod = ud.module_path[0];
        if (ud.items) |items| {
            for (items) |item| {
                const key = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00{s}", .{ mod, item.name }) catch continue;
                defer self.arena.allocator().free(key);
                if (self.exported_schemes.get(key)) |scheme| {
                    const import_name = item.alias orelse item.name;
                    env.redefine(import_name, scheme) catch {};
                }
            }
        } else {
            const prefix = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00", .{mod}) catch return;
            defer self.arena.allocator().free(prefix);
            var it = self.exported_schemes.iterator();
            while (it.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                    const sym = entry.key_ptr.*[prefix.len..];
                    env.redefine(sym, entry.value_ptr.*) catch {};
                }
            }
        }
    }

    // ── Import 别名表构建 ──

    /// 构建 import 别名表：扫描已合并 declarations，为每个 import_decl 注册短名
    /// 整路径导入：注册末段 → 完整模块路径
    /// selective import：注册短名 → mangled 函数/常量名 或 子模块路径
    /// 类型即模块：类型名与模块名同名时统一为模块引用
    fn buildImportAliases(self: *TypeInferencer, module: *const ast.Module) void {
        const sr = self.sema_result orelse return;
        const arena_alloc = self.arena.allocator();

        for (module.declarations) |decl| {
            if (decl != .import_decl) continue;
            const imp = decl.import_decl;
            if (imp.module_path.len == 0) continue;

            if (imp.items) |items| {
                self.buildSelectiveImportAliases(imp.module_path, items, module, sr, arena_alloc);
            } else {
                self.buildWholeImportAlias(imp.module_path, module, sr, arena_alloc);
            }
        }
    }

    /// 整路径导入的别名构建：import path.to.module
    fn buildWholeImportAlias(
        self: *TypeInferencer,
        module_path: []const []const u8,
        module: *const ast.Module,
        sr: *SemaResult,
        arena_alloc: std.mem.Allocator,
    ) void {
        const last_segment = module_path[module_path.len - 1];
        const full_path = joinModulePath(arena_alloc, module_path) catch return;

        // 冲突检测：短名重复
        if (sr.import_aliases.contains(last_segment)) {
            self.addErrorAt(.name_conflict, 0, 0, "duplicate import alias: '{s}'", .{last_segment});
            return;
        }
        // 冲突检测：与非类型本地定义冲突（类型定义允许，类型即模块）
        if (self.isLocalNonTypeDefinition(last_segment, module)) {
            self.addErrorAt(.name_conflict, 0, 0, "import alias '{s}' conflicts with local definition", .{last_segment});
            return;
        }
        sr.putImportAlias(last_segment, .{ .module = full_path }) catch {};
    }

    /// selective import 的别名构建：import path { item1, item2 as alias }
    fn buildSelectiveImportAliases(
        self: *TypeInferencer,
        module_path: []const []const u8,
        items: []const ast.ImportItem,
        module: *const ast.Module,
        sr: *SemaResult,
        arena_alloc: std.mem.Allocator,
    ) void {
        const prefix_path = joinModulePath(arena_alloc, module_path) catch return;

        for (items) |item| {
            const import_name = item.alias orelse item.name;
            const candidate_module = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ prefix_path, item.name }) catch continue;
            const candidate_symbol = candidate_module;

            // 冲突检测
            if (sr.import_aliases.contains(import_name)) {
                self.addErrorAt(.name_conflict, 0, 0, "duplicate import alias: '{s}'", .{import_name});
                continue;
            }
            if (self.isLocalNonTypeDefinition(import_name, module)) {
                self.addErrorAt(.name_conflict, 0, 0, "import alias '{s}' conflicts with local definition", .{import_name});
                continue;
            }

            const kind = classifyImportItem(item.name, candidate_module, candidate_symbol, module);
            switch (kind) {
                .function, .constant => {
                    sr.putImportAlias(import_name, .{ .symbol = candidate_symbol }) catch {};
                },
                .submodule, .type_kind => {
                    sr.putImportAlias(import_name, .{ .module = candidate_module }) catch {};
                },
                .not_found => {
                    self.addErrorAt(.import_item_not_found, 0, 0, "import item '{s}' not found in module '{s}'", .{ item.name, prefix_path });
                },
            }
        }
    }

    /// 判断名字是否为本地非类型定义（函数/变量/trait）
    fn isLocalNonTypeDefinition(self: *TypeInferencer, name: []const u8, module: *const ast.Module) bool {
        _ = self;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| if (std.mem.eql(u8, fd.name, name)) return true,
                .trait_decl => |td| if (std.mem.eql(u8, td.name, name)) return true,
                .expr_decl => |ed| {
                    if (ed.stmt) |st| {
                        switch (st.*) {
                            .val_decl => |vd| if (std.mem.eql(u8, vd.name, name)) return true,
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// selective import item 的种类分类
    const ImportItemKind = enum { function, constant, submodule, type_kind, not_found };
    fn classifyImportItem(
        item_name: []const u8,
        candidate_module: []const u8,
        candidate_symbol: []const u8,
        module: *const ast.Module,
    ) ImportItemKind {
        for (module.declarations) |decl| {
            if (decl == .fun_decl and std.mem.eql(u8, decl.fun_decl.name, candidate_symbol)) {
                return .function;
            }
            // 常量：expr_decl.stmt.val_decl.name == candidate_symbol
            if (decl == .expr_decl) {
                const ed = decl.expr_decl;
                if (ed.stmt) |st| {
                    switch (st.*) {
                        .val_decl => |vd| if (std.mem.eql(u8, vd.name, candidate_symbol)) return .constant,
                        else => {},
                    }
                }
            }
            // 子模块：存在以 candidate_module + "." 开头的 mangled 函数名
            if (decl == .fun_decl) {
                const fname = decl.fun_decl.name;
                if (std.mem.startsWith(u8, fname, candidate_module) and fname.len > candidate_module.len and fname[candidate_module.len] == '.') {
                    return .submodule;
                }
            }
            // 类型（原名不 mangle）
            if (decl == .type_decl and std.mem.eql(u8, decl.type_decl.name, item_name)) {
                return .type_kind;
            }
        }
        return .not_found;
    }

    /// 用 "." 连接模块路径段
    fn joinModulePath(arena_alloc: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        if (parts.len == 0) return "";
        var total: usize = 0;
        for (parts) |p| total += p.len + 1;
        const buf = try arena_alloc.alloc(u8, total - 1);
        var pos: usize = 0;
        for (parts, 0..) |p, i| {
            @memcpy(buf[pos..][0..p.len], p);
            pos += p.len;
            if (i < parts.len - 1) {
                buf[pos] = '.';
                pos += 1;
            }
        }
        return buf;
    }

    fn checkCrossKindNameClashes(self: *TypeInferencer, module: *const ast.Module) void {
        const Kind = enum { function, type_decl, trait_decl };
        var seen = std.StringHashMap(Kind).init(self.arena.allocator());
        defer seen.deinit();
        const consider = struct {
            fn add(inf: *TypeInferencer, map: *std.StringHashMap(Kind), name: []const u8, kind: Kind, loc: ast.SourceLocation) void {
                if (map.get(name)) |prev| {
                    if (prev != kind) {
                        inf.addErrorAt(.type_mismatch, loc.line, loc.column, "duplicate definition: '{s}' is already defined in this scope", .{name});
                    }
                    return;
                }
                map.put(name, kind) catch {};
            }
        };
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| consider.add(self, &seen, f.name, .function, f.location),
                .trait_decl => |t| consider.add(self, &seen, t.name, .trait_decl, t.location),
                .type_decl => |t| consider.add(self, &seen, t.name, .type_decl, t.location),
                else => {},
            }
        }
    }
    fn recordModuleStructure(self: *TypeInferencer, module: *const ast.Module, module_name: []const u8) void {
        var sigs = std.ArrayList(module_check.MethodSig).empty;
        var subs = std.ArrayList([]const u8).empty;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (f.visibility != .public) continue;
                    const name_dup = self.arena.allocator().dupe(u8, f.name) catch continue;
                    sigs.append(self.arena.allocator(), .{ .name = name_dup, .arity = f.params.len }) catch {};
                },
                .pack_decl => |pd| {
                    if (pd.visibility != .public) continue;
                    const sub_dup = self.arena.allocator().dupe(u8, pd.name) catch continue;
                    subs.append(self.arena.allocator(), sub_dup) catch {};
                },
                else => {},
            }
        }
        self.putModuleMemberSigs(module_name, sigs.toOwnedSlice(self.arena.allocator()) catch return);
        self.putModuleSubmodules(module_name, subs.toOwnedSlice(self.arena.allocator()) catch return);
        self.markKnownModule(module_name);
    }
    fn putModuleMemberSigs(self: *TypeInferencer, module_name: []const u8, sigs: []module_check.MethodSig) void {
        if (self.module_member_sigs.fetchRemove(module_name)) |old| {
            for (old.value) |s| self.arena.allocator().free(s.name);
            self.arena.allocator().free(old.value);
            self.arena.allocator().free(old.key);
        }
        const key = self.arena.allocator().dupe(u8, module_name) catch return;
        self.module_member_sigs.put(key, sigs) catch {
            self.arena.allocator().free(key);
        };
    }
    fn putModuleSubmodules(self: *TypeInferencer, module_name: []const u8, subs: [][]const u8) void {
        if (self.module_submodules.fetchRemove(module_name)) |old| {
            for (old.value) |s| self.arena.allocator().free(s);
            self.arena.allocator().free(old.value);
            self.arena.allocator().free(old.key);
        }
        const key = self.arena.allocator().dupe(u8, module_name) catch return;
        self.module_submodules.put(key, subs) catch {
            self.arena.allocator().free(key);
        };
    }
    fn markKnownModule(self: *TypeInferencer, module_name: []const u8) void {
        if (self.known_modules.contains(module_name)) return;
        const key = self.arena.allocator().dupe(u8, module_name) catch return;
        self.known_modules.put(key, {}) catch {
            self.arena.allocator().free(key);
        };
    }
    fn recordExportSymbol(self: *TypeInferencer, module_name: []const u8, sym: []const u8, env: *TypeEnv) void {
        const scheme = env.lookup(sym) orelse return;
        const key = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00{s}", .{ module_name, sym }) catch return;
        if (self.exported_schemes.getKey(key)) |old_key| {
            self.exported_schemes.put(old_key, scheme) catch {};
            self.arena.allocator().free(key);
        } else {
            self.exported_schemes.put(key, scheme) catch {
                self.arena.allocator().free(key);
            };
        }
    }
    fn predeclareFunction(self: *TypeInferencer, f: anytype, env: *TypeEnv) void {
        if (self.isBuiltinName(f.name)) return;
        if (self.predeclared_fns.contains(f.name)) {
            const msg = std.fmt.allocPrint(self.arena.allocator(), "duplicate definition: '{s}' is already defined in this scope", .{f.name}) catch return;
            self.errors.append(self.arena.allocator(), TypeError{ .kind = .type_mismatch, .message = msg }) catch {};
            return;
        }
        var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
        defer type_param_map.deinit();
        var type_param_ids = std.ArrayList(usize).empty;
        defer type_param_ids.deinit(self.arena.allocator());
        for (f.type_params) |tp| {
            const tv = self.freshTypeVar() catch return;
            type_param_map.put(tp.name, tv) catch return;
            type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
        }
        const param_types = self.arena.allocator().alloc(*Type, f.params.len) catch return;
        for (f.params, 0..) |param, i| {
            param_types[i] = if (param.type_annotation) |ta|
                self.typeFromAstWithParams(ta, &type_param_map) catch (self.freshTypeVar() catch return)
            else
                self.freshTypeVar() catch return;
        }
        const ret_ty = if (f.return_type) |rt|
            self.typeFromAstWithParams(rt, &type_param_map) catch (self.freshTypeVar() catch return)
        else
            self.freshTypeVar() catch return;
        const fn_ty = self.makeFnType(param_types, ret_ty) catch return;
        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = fn_ty };
        env.define(f.name, scheme) catch return;
        self.predeclared_fns.put(f.name, {}) catch {};
    }
    /// 查找已存在的 generic_type stub（由 registerBuiltins 创建）。
    /// 用于在 predeclareTypeDecl 中复用 stub 对象，使 syscall 签名中的引用
    /// 自动指向实际 record 类型，避免 stub 与实际类型不匹配的 sema 错误。
    fn findGenericTypeStub(self: *TypeInferencer, name: []const u8) ?*Type {
        for (self.types.items) |t| {
            switch (t.*) {
                .generic_type => |gt| {
                    if (std.mem.eql(u8, gt.name, name)) return t;
                },
                else => {},
            }
        }
        return null;
    }
    /// 预声明 type_decl：注册类型名到 adt_types 表，并把构造器名注册到 env。
    /// 这样跨模块引用的构造器（如 Instant.glue 引用 Duration(x)）在函数体检查
    /// 时已能解析。后续 checkDeclCollecting 会用 redefine 覆盖为完整方案。
    fn predeclareTypeDecl(self: *TypeInferencer, td: anytype, env: *TypeEnv) void {
        if (self.predeclared_types.contains(td.name)) return;
        self.predeclared_types.put(td.name, {}) catch return;
        switch (td.def) {
            .adt => |adt_def| {
                var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.arena.allocator());
                var type_param_names = std.ArrayList([]const u8).empty;
                defer type_param_names.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                    const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                    type_param_names.append(self.arena.allocator(), name_copy) catch return;
                }
                var adt_args = std.ArrayList(*Type).empty;
                defer adt_args.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = type_param_map.get(tp.name).?;
                    adt_args.append(self.arena.allocator(), tv) catch return;
                }
                // 复用 generic_type stub（由 registerBuiltins 创建的 TimeComponents 等）
                // 覆写为 adt_type，使 syscall 签名中的引用自动指向实际 ADT 类型
                const stub = self.findGenericTypeStub(td.name);
                const adt_ty = if (stub) |s| blk: {
                    const owned_args = self.arena.allocator().dupe(*Type, adt_args.items) catch return;
                    s.* = Type{ .adt_type = .{ .name = td.name, .type_args = owned_args } };
                    break :blk s;
                } else self.makeAdtType(td.name, adt_args.items) catch return;
                if (!self.adt_types.contains(td.name)) {
                    const ctor_names = self.arena.allocator().alloc([]const u8, adt_def.constructors.len) catch return;
                    for (adt_def.constructors, 0..) |con, i| {
                        ctor_names[i] = con.name;
                    }
                    const owned_tp_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                    const key = self.arena.allocator().dupe(u8, td.name) catch return;
                    self.adt_types.put(key, AdtInfo{
                        .ty = adt_ty,
                        .constructor_names = ctor_names,
                        .type_param_names = owned_tp_names,
                        .defining_module = self.current_module,
                    }) catch return;
                    const mod_key = self.arena.allocator().dupe(u8, td.name) catch return;
                    const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                    self.type_defining_modules.put(mod_key, mod_val) catch return;
                }
                for (adt_def.constructors) |con| {
                    if (self.isBuiltinName(con.name)) continue;
                    if (con.fields.len == 0) {
                        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = adt_ty };
                        env.define(con.name, scheme) catch continue;
                    } else {
                        const fts = self.arena.allocator().alloc(*Type, con.fields.len) catch return;
                        for (con.fields, 0..) |field, i| {
                            fts[i] = self.typeFromAstWithParams(field.ty, &type_param_map) catch (self.freshTypeVar() catch return);
                        }
                        const ctor_ty = self.makeFnType(fts, adt_ty) catch return;
                        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                        env.define(con.name, scheme) catch continue;
                    }
                }
            },
            .record => |rec_def| {
                var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                }
                // 检查是否已存在 generic_type stub（由 registerBuiltins 创建的 TimeComponents 等）
                // 如果存在，复用该 Type 对象，使 syscall 签名中的引用自动指向实际 record 类型
                const stub = self.findGenericTypeStub(td.name);
                const rec_ty = stub orelse blk: {
                    const new_ty = self.arena.allocator().create(Type) catch return;
                    self.types.append(self.arena.allocator(), new_ty) catch return;
                    break :blk new_ty;
                };
                const fields = self.arena.allocator().alloc(FieldType, rec_def.fields.len) catch return;
                for (rec_def.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = self.typeFromAstWithParams(f.ty, &type_param_map) catch return,
                    };
                }
                rec_ty.* = Type{ .record_type = .{ .fields = fields } };
                const param_types = self.arena.allocator().alloc(*Type, rec_def.fields.len) catch return;
                for (rec_def.fields, 0..) |f, i| {
                    param_types[i] = self.typeFromAstWithParams(f.ty, &type_param_map) catch return;
                }
                const ctor_ty = self.makeFnType(param_types, rec_ty) catch return;
                const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                if (!self.isBuiltinName(td.name)) {
                    env.define(td.name, scheme) catch {};
                }
                if (!self.adt_types.contains(td.name)) {
                    const key = self.arena.allocator().dupe(u8, td.name) catch return;
                    const type_param_names = self.arena.allocator().alloc([]const u8, td.type_params.len) catch return;
                    for (td.type_params, 0..) |tp, i| {
                        type_param_names[i] = tp.name;
                    }
                    self.adt_types.put(key, AdtInfo{
                        .ty = rec_ty,
                        .constructor_names = &[_][]const u8{},
                        .type_param_names = type_param_names,
                    }) catch return;
                }
            },
            .alias => |ta| {
                var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.arena.allocator());
                var type_param_names = std.ArrayList([]const u8).empty;
                defer type_param_names.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                    const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                    type_param_names.append(self.arena.allocator(), name_copy) catch return;
                }
                const target_ty = self.typeFromAstWithParams(ta.target, &type_param_map) catch return;
                const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = target_ty };
                if (!self.isBuiltinName(td.name)) {
                    env.define(td.name, scheme) catch {};
                }
                if (!self.adt_types.contains(td.name)) {
                    const key = self.arena.allocator().dupe(u8, td.name) catch return;
                    const owned_tp_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                    self.adt_types.put(key, AdtInfo{
                        .ty = target_ty,
                        .constructor_names = &[_][]const u8{},
                        .type_param_names = owned_tp_names,
                        .defining_module = self.current_module,
                    }) catch return;
                }
            },
            .newtype => |nt| {
                var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.arena.allocator());
                var type_param_names = std.ArrayList([]const u8).empty;
                defer type_param_names.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                    const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                    type_param_names.append(self.arena.allocator(), name_copy) catch return;
                }
                var adt_args = std.ArrayList(*Type).empty;
                defer adt_args.deinit(self.arena.allocator());
                for (td.type_params) |tp| {
                    const tv = type_param_map.get(tp.name).?;
                    adt_args.append(self.arena.allocator(), tv) catch return;
                }
                // 复用 generic_type stub（由 registerBuiltins 创建的 TimeComponents 等）
                // 覆写为 adt_type，使 syscall 签名中的引用自动指向实际 newtype 类型
                const stub = self.findGenericTypeStub(td.name);
                const newtype_ty = if (stub) |s| blk: {
                    const owned_args = self.arena.allocator().dupe(*Type, adt_args.items) catch return;
                    s.* = Type{ .adt_type = .{ .name = td.name, .type_args = owned_args } };
                    break :blk s;
                } else self.makeAdtType(td.name, adt_args.items) catch return;
                if (!self.adt_types.contains(td.name)) {
                    const type_key = self.arena.allocator().dupe(u8, td.name) catch return;
                    const ctor_names_single = self.arena.allocator().alloc([]const u8, 1) catch return;
                    ctor_names_single[0] = nt.name;
                    const owned_tp_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                    self.adt_types.put(type_key, AdtInfo{
                        .ty = newtype_ty,
                        .constructor_names = ctor_names_single,
                        .type_param_names = owned_tp_names,
                        .defining_module = self.current_module,
                    }) catch return;
                    const mod_key = self.arena.allocator().dupe(u8, td.name) catch return;
                    const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                    self.type_defining_modules.put(mod_key, mod_val) catch return;
                }
                const inner_ty = self.typeFromAstWithParams(nt.inner, &type_param_map) catch return;
                const ctor_params = self.arena.allocator().alloc(*Type, 1) catch return;
                ctor_params[0] = inner_ty;
                const ctor_ty = self.makeFnType(ctor_params, newtype_ty) catch return;
                const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                if (!self.isBuiltinName(nt.name)) {
                    env.define(nt.name, scheme) catch {};
                }
            },
            .error_newtype => |en| {
                const error_adt = self.makeAdtType(en.name, &[_]*Type{}) catch return;
                const ctor_params = self.arena.allocator().alloc(*Type, 1) catch return;
                ctor_params[0] = self.makeType(.str_type) catch return;
                const ctor_ty = self.makeFnType(ctor_params, error_adt) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = ctor_ty };
                if (!self.isBuiltinName(en.name)) {
                    env.define(en.name, scheme) catch {};
                }
                if (!self.adt_types.contains(en.name)) {
                    const key = self.arena.allocator().dupe(u8, en.name) catch return;
                    const ctor_names = self.arena.allocator().alloc([]const u8, 1) catch return;
                    ctor_names[0] = en.name;
                    self.adt_types.put(key, AdtInfo{
                        .ty = error_adt,
                        .constructor_names = ctor_names,
                        .is_error_newtype = true,
                    }) catch return;
                    const mod_key = self.arena.allocator().dupe(u8, en.name) catch return;
                    const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                    self.type_defining_modules.put(mod_key, mod_val) catch return;
                }
            },
        }
    }
    fn registerBuiltins(self: *TypeInferencer, env: *TypeEnv) void {
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("println", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("println");
        }
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("print", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("print");
        }
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprintln", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eprintln");
        }
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprint", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eprint");
        }
        {
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = self.makeType(.str_type) catch return;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            env.define("Panic", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Panic");
        }
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.str_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("str", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("str");
        }
        {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.str_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("type", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("type");
        }
        const error_adt_ty = self.makeAdtType("Error", &[_]*Type{}) catch return;
        const error_adt_key = self.arena.allocator().dupe(u8, "Error") catch return;
        self.adt_types.put(error_adt_key, AdtInfo{ .ty = error_adt_ty, .constructor_names = &[_][]const u8{} }) catch return;
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = self.makeType(.str_type) catch return;
            const throw_ty = self.arena.allocator().create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.arena.allocator(), throw_ty) catch return;
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Error", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Error");
        }
        // Error 作为完全内建 trait 注册
        // 设计：message/type_name 提供默认实现（读 ErrorValue 字段），用户可通过 override
        // 自定义行为。prefix 已合并到 type_name（错误前缀直接使用 type_name()），故移除。
        {
            const error_trait_ty = self.arena.allocator().create(Type) catch return;
            error_trait_ty.* = Type{ .trait_type = .{ .name = "Error", .type_args = &[_]*Type{} } };
            self.types.append(self.arena.allocator(), error_trait_ty) catch return;
            // method_names 包含所有方法；required_method_names 为空（message/type_name 均有默认实现）
            const error_method_names = self.arena.allocator().alloc([]const u8, 2) catch return;
            error_method_names[0] = "message";
            error_method_names[1] = "type_name";
            const error_required_names = &[_][]const u8{};
            const error_assoc_names = &[_][]const u8{};
            var error_method_schemes = std.StringHashMap(TypeScheme).init(self.arena.allocator());
            // message(self: Error) -> str
            {
                const self_type = self.arena.allocator().create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Error", .type_args = &[_]*Type{} } };
                self.types.append(self.arena.allocator(), self_type) catch return;
                const fn_params = self.arena.allocator().alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, self.makeType(.str_type) catch return) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                error_method_schemes.put(self.arena.allocator().dupe(u8, "message") catch return, scheme) catch return;
            }
            // type_name(self: Error) -> str
            {
                const self_type = self.arena.allocator().create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Error", .type_args = &[_]*Type{} } };
                self.types.append(self.arena.allocator(), self_type) catch return;
                const fn_params = self.arena.allocator().alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, self.makeType(.str_type) catch return) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                error_method_schemes.put(self.arena.allocator().dupe(u8, "type_name") catch return, scheme) catch return;
            }
            const error_key = self.arena.allocator().dupe(u8, "Error") catch return;
            self.trait_types.put(error_key, TraitInfo{
                .ty = error_trait_ty,
                .associated_type_names = error_assoc_names,
                .method_names = error_method_names,
                .required_method_names = error_required_names,
                .method_schemes = error_method_schemes,
                .defining_module = "<builtin>",
            }) catch return;
        }
        // builtin 类型注册（决策 #18/#23/#24）：从 glue_builtin.BUILTIN_TYPES 元信息表加载
        // 采用两遍策略：
        //   第一遍注册所有关联 ADT（IOErrorKind / TimeErrorKind）+ 构造器到 env
        //   第二遍注册所有 error_newtype（CastError / IOError / TimeError），字段类型
        //        可引用已注册的 ADT（如 IOError.kind: IOErrorKind）
        // sema 启动时全加载类型定义，代码生成阶段按需编译方法体（Phase 3 实现按需加载）

        // 第一遍：注册关联 ADT
        inline for (glue_builtin.BUILTIN_TYPES) |bt| {
            switch (bt.kind) {
                .adt => {
                    const adt_ty = self.makeAdtType(bt.name, &[_]*Type{}) catch return;
                    const ctor_names = self.arena.allocator().alloc([]const u8, bt.constructors.len) catch return;
                    for (bt.constructors, 0..) |c, i| {
                        ctor_names[i] = c;
                    }
                    const adt_key = self.arena.allocator().dupe(u8, bt.name) catch return;
                    self.adt_types.put(adt_key, AdtInfo{
                        .ty = adt_ty,
                        .constructor_names = ctor_names,
                        .defining_module = "<builtin>",
                    }) catch return;
                    self.registerBuiltinName(bt.name);
                    // 注册所有 unit constructor 到 env
                    // 注意：constructor 名不注册为 builtin_name，允许用户 ADT 覆盖
                    // （如 FileKind::Other 与 IOErrorKind::Other 可共存，后者会被前者覆盖）
                    for (bt.constructors) |con| {
                        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = adt_ty };
                        _ = env.define(con, scheme) catch return;
                    }
                },
                .error_newtype => {},
            }
        }
        // 第二遍：注册 error_newtype（字段类型可引用第一遍注册的 ADT）
        inline for (glue_builtin.BUILTIN_TYPES) |bt| {
            switch (bt.kind) {
                .error_newtype => {
                    // 注册 ADT 类型
                    const adt_ty = self.makeAdtType(bt.name, &[_]*Type{}) catch return;
                    // 构造器参数类型按 bt.fields 中的 type_name 查找：
                    //   1) 内建基础类型（i8/i16/.../str/bool）→ BUILTIN_TYPES 表
                    //   2) 已注册 ADT（IOErrorKind 等）→ self.adt_types
                    //   3) fallback → str_type
                    const ctor_params = self.arena.allocator().alloc(*Type, bt.fields.len) catch return;
                    inline for (bt.fields, 0..) |f, i| {
                        const field_ty: *Type = blk: {
                            inline for (BUILTIN_TYPES) |entry| {
                                if (comptime std.mem.eql(u8, entry.name, f.type_name)) break :blk self.makeType(entry.ty) catch return;
                            }
                            if (self.adt_types.get(f.type_name)) |info| break :blk info.ty;
                            break :blk self.makeType(.str_type) catch return;
                        };
                        ctor_params[i] = field_ty;
                    }
                    const ctor_ty = self.makeFnType(ctor_params, adt_ty) catch return;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = ctor_ty };
                    _ = env.define(bt.constructor_name, scheme) catch return;
                    self.registerBuiltinName(bt.constructor_name);
                    self.registerBuiltinName(bt.name);
                    // 注册到 adt_types（标记 is_error_newtype=true，作为 Error 子类型）
                    // 同时填充 ctor_field_names/ctor_field_types，使 field_access 能解析字段类型
                    const adt_key = self.arena.allocator().dupe(u8, bt.name) catch return;
                    const ctor_names = self.arena.allocator().alloc([]const u8, 1) catch return;
                    ctor_names[0] = bt.constructor_name;
                    // 单构造器：ctor_field_types/ctor_field_names 第一维长度=1
                    const ctor_field_types = self.arena.allocator().alloc([]const *Type, 1) catch return;
                    const ctor_field_names = self.arena.allocator().alloc([]const ?[]const u8, 1) catch return;
                    ctor_field_types[0] = ctor_params;
                    const field_names = self.arena.allocator().alloc(?[]const u8, bt.fields.len) catch return;
                    inline for (bt.fields, 0..) |f, i| {
                        field_names[i] = f.name;
                    }
                    ctor_field_names[0] = field_names;
                    self.adt_types.put(adt_key, AdtInfo{
                        .ty = adt_ty,
                        .constructor_names = ctor_names,
                        .is_error_newtype = true,
                        .defining_module = "<builtin>",
                        .ctor_field_types = ctor_field_types,
                        .ctor_field_names = ctor_field_names,
                    }) catch return;
                },
                .adt => {},
            }
        }
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = val_ty;
            const throw_ty = self.arena.allocator().create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.arena.allocator(), throw_ty) catch return;
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Ok", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Ok");
        }
        {
            const params = self.arena.allocator().alloc(*Type, 0) catch return;
            const ret_ty = self.makeNullableType(self.makeType(.str_type) catch return) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            env.define("scan", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("scan");
        }
        {
            const params = self.arena.allocator().alloc(*Type, 0) catch return;
            const ret_ty = self.makeNullableType(self.makeType(.str_type) catch return) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            env.define("scanln", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("scanln");
        }
        inline for (NUMERIC_TYPES) |cast| {
            const param = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(cast.ty) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define(cast.name, TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName(cast.name);
        }
        {
            const iterable_trait_ty = self.arena.allocator().create(Type) catch return;
            iterable_trait_ty.* = Type{ .trait_type = .{ .name = "Iterable", .type_args = &[_]*Type{} } };
            self.types.append(self.arena.allocator(), iterable_trait_ty) catch return;
            const iterable_method_names = self.arena.allocator().alloc([]const u8, 1) catch return;
            iterable_method_names[0] = "iterator";
            const iterable_assoc_names = &[_][]const u8{};
            var iterable_method_schemes = std.StringHashMap(TypeScheme).init(self.arena.allocator());
            {
                const t_var = self.freshTypeVar() catch return;
                const self_args = self.arena.allocator().alloc(*Type, 1) catch return;
                self_args[0] = t_var;
                const self_type = self.arena.allocator().create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Iterable", .type_args = self_args } };
                self.types.append(self.arena.allocator(), self_type) catch return;
                const ret_args = self.arena.allocator().alloc(*Type, 1) catch return;
                ret_args[0] = t_var;
                const ret_type = self.arena.allocator().create(Type) catch return;
                ret_type.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = ret_args } };
                self.types.append(self.arena.allocator(), ret_type) catch return;
                const fn_params = self.arena.allocator().alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, ret_type) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                iterable_method_schemes.put(self.arena.allocator().dupe(u8, "iterator") catch return, scheme) catch return;
            }
            const iterable_key = self.arena.allocator().dupe(u8, "Iterable") catch return;
            self.trait_types.put(iterable_key, TraitInfo{
                .ty = iterable_trait_ty,
                .associated_type_names = iterable_assoc_names,
                .method_names = iterable_method_names,
                .method_schemes = iterable_method_schemes,
                .defining_module = "<builtin>",
            }) catch return;
            self.builtin_names.put(self.arena.allocator().dupe(u8, "Iterable") catch return, {}) catch return;
        }
        {
            const iterator_trait_ty = self.arena.allocator().create(Type) catch return;
            iterator_trait_ty.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = &[_]*Type{} } };
            self.types.append(self.arena.allocator(), iterator_trait_ty) catch return;
            const iterator_method_names = self.arena.allocator().alloc([]const u8, 1) catch return;
            iterator_method_names[0] = "next";
            const iterator_assoc_names = &[_][]const u8{};
            var iterator_method_schemes = std.StringHashMap(TypeScheme).init(self.arena.allocator());
            {
                const t_var = self.freshTypeVar() catch return;
                const self_args = self.arena.allocator().alloc(*Type, 1) catch return;
                self_args[0] = t_var;
                const self_type = self.arena.allocator().create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = self_args } };
                self.types.append(self.arena.allocator(), self_type) catch return;
                const ret_type = self.makeNullableType(t_var) catch return;
                const fn_params = self.arena.allocator().alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, ret_type) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                iterator_method_schemes.put(self.arena.allocator().dupe(u8, "next") catch return, scheme) catch return;
            }
            const iterator_key = self.arena.allocator().dupe(u8, "Iterator") catch return;
            self.trait_types.put(iterator_key, TraitInfo{
                .ty = iterator_trait_ty,
                .associated_type_names = iterator_assoc_names,
                .method_names = iterator_method_names,
                .method_schemes = iterator_method_schemes,
                .defining_module = "<builtin>",
            }) catch return;
            self.builtin_names.put(self.arena.allocator().dupe(u8, "Iterator") catch return, {}) catch return;
        }
        {
            const t_var = self.freshTypeVar() catch return;
            const params = self.arena.allocator().alloc(*Type, 1) catch return;
            params[0] = self.makeType(.i32_type) catch return;
            const ret_ty = self.makeGenericType("Channel", &[_]*Type{t_var}) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = t_var.type_var.id;
            env.define("channel", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("channel");
        }
        // 注册所有 syscall 函数签名（IO/Time 原语）
        // 设计：__ 前缀函数返回 Throw<T, IOError> 或 Throw<T, TimeError>，
        // 极少部分（path_*/str_*/make_u8_array 等纯函数）返回值类型。
        // 返回类型按 spec 表 4.1 / 5.1 给出，参数从对应 spec 表中复制。
        self.registerSyscallSignatures(env);
        // 注册 typeof 内建函数名（参数是类型引用，特殊处理，不进入 env）
        // typeof 的实际处理在 inferExprInner 的 .call 分支中特殊分支
        self.registerBuiltinName("typeof");
    }

    /// 注册所有 syscall 函数签名到 env（__ 前缀函数）
    ///
    /// 这些函数由 IRBuilder 在 compileCallWithTypeArgs 中识别并编译为 syscall_call 节点。
    /// 类型签名按 stdlib 设计文档（docs/superpowers/specs/2026-07-19-stdlib-design.md）
    /// 表 4.1（IO）与表 5.1（Time）。
    fn registerSyscallSignatures(self: *TypeInferencer, env: *TypeEnv) void {
        // 构造 IOError 与 TimeError 的 ADT 类型（已由 BUILTIN_TYPES 注册，复用即可）
        const io_error_ty = self.makeAdtType("IOError", &[_]*Type{}) catch return;
        const time_error_ty = self.makeAdtType("TimeError", &[_]*Type{}) catch return;

        // 通用：构造 Throw<T, E> 类型
        const makeThrowTy = struct {
            fn f(it: *TypeInferencer, val_ty: *Type, err_ty: *Type) *Type {
                const t = it.arena.allocator().create(Type) catch return err_ty;
                t.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = err_ty } };
                it.types.append(it.arena.allocator(), t) catch return t;
                return t;
            }
        }.f;

        // 通用：注册一个 syscall 函数
        const define = struct {
            fn f(it: *TypeInferencer, e: *TypeEnv, name: []const u8, params: []*Type, ret_ty: *Type) void {
                const fn_ty = it.makeFnType(params, ret_ty) catch return;
                e.define(name, TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
                it.registerBuiltinName(name);
            }
        }.f;

        const str_ty = self.makeType(.str_type) catch return;
        const i32_ty = self.makeType(.i32_type) catch return;
        const i64_ty = self.makeType(.i64_type) catch return;
        const i128_ty = self.makeType(.i128_type) catch return;
        const usize_ty = self.makeType(.usize_type) catch return;
        const bool_ty = self.makeType(.bool_type) catch return;
        const unit_ty = self.makeType(.unit_type) catch return;
        const u8_ty = self.makeType(.u8_type) catch return;
        const u8_array_ty = self.makeArrayType(u8_ty, null) catch return;

        // Stat 类型：std/io 中定义的 record，syscall 层返回值类型用 generic "Stat"
        const stat_ty = self.makeGenericType("Stat", &[_]*Type{}) catch return;
        // DirEntry 类型：std/io 中定义的 record
        const dir_entry_ty = self.makeGenericType("DirEntry", &[_]*Type{}) catch return;
        const dir_entry_array_ty = self.makeArrayType(dir_entry_ty, null) catch return;
        // TimeComponents 类型：std/time 中定义的 record
        const time_comp_ty = self.makeGenericType("TimeComponents", &[_]*Type{}) catch return;

        // ── IO syscall (0-18) ──
        // __file_open(path: str, flags: i32, mode: i32) -> Throw<i64, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 3) catch return;
            ps[0] = str_ty;
            ps[1] = i32_ty;
            ps[2] = i32_ty;
            define(self, env, "__file_open", ps, makeThrowTy(self, i64_ty, io_error_ty));
        }
        // __file_close(fd: i64) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i64_ty;
            define(self, env, "__file_close", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __file_read(fd: i64, buf: u8[], len: usize) -> Throw<usize, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 3) catch return;
            ps[0] = i64_ty;
            ps[1] = u8_array_ty;
            ps[2] = usize_ty;
            define(self, env, "__file_read", ps, makeThrowTy(self, usize_ty, io_error_ty));
        }
        // __file_write(fd: i64, buf: u8[], len: usize) -> Throw<usize, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 3) catch return;
            ps[0] = i64_ty;
            ps[1] = u8_array_ty;
            ps[2] = usize_ty;
            define(self, env, "__file_write", ps, makeThrowTy(self, usize_ty, io_error_ty));
        }
        // __file_seek(fd: i64, offset: i64, whence: i32) -> Throw<i64, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 3) catch return;
            ps[0] = i64_ty;
            ps[1] = i64_ty;
            ps[2] = i32_ty;
            define(self, env, "__file_seek", ps, makeThrowTy(self, i64_ty, io_error_ty));
        }
        // __file_tell(fd: i64) -> Throw<i64, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i64_ty;
            define(self, env, "__file_tell", ps, makeThrowTy(self, i64_ty, io_error_ty));
        }
        // __file_stat(path: str) -> Throw<Stat, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = str_ty;
            define(self, env, "__file_stat", ps, makeThrowTy(self, stat_ty, io_error_ty));
        }
        // __file_fstat(fd: i64) -> Throw<Stat, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i64_ty;
            define(self, env, "__file_fstat", ps, makeThrowTy(self, stat_ty, io_error_ty));
        }
        // __file_remove(path: str) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = str_ty;
            define(self, env, "__file_remove", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __file_rename(old: str, new: str) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 2) catch return;
            ps[0] = str_ty;
            ps[1] = str_ty;
            define(self, env, "__file_rename", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __file_chmod(path: str, mode: i32) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 2) catch return;
            ps[0] = str_ty;
            ps[1] = i32_ty;
            define(self, env, "__file_chmod", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __dir_create(path: str, recursive: bool) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 2) catch return;
            ps[0] = str_ty;
            ps[1] = bool_ty;
            define(self, env, "__dir_create", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __dir_remove(path: str, recursive: bool) -> Throw<Unit, IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 2) catch return;
            ps[0] = str_ty;
            ps[1] = bool_ty;
            define(self, env, "__dir_remove", ps, makeThrowTy(self, unit_ty, io_error_ty));
        }
        // __dir_list(path: str) -> Throw<DirEntry[], IOError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = str_ty;
            define(self, env, "__dir_list", ps, makeThrowTy(self, dir_entry_array_ty, io_error_ty));
        }

        // ── Time syscall ──
        // __instant_now_ns() -> i128
        {
            const ps = self.arena.allocator().alloc(*Type, 0) catch return;
            define(self, env, "__instant_now_ns", ps, i128_ty);
        }
        // __systemtime_now_ns() -> i128
        {
            const ps = self.arena.allocator().alloc(*Type, 0) catch return;
            define(self, env, "__systemtime_now_ns", ps, i128_ty);
        }
        // __sleep_ns(ns: i128) -> Unit
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i128_ty;
            define(self, env, "__sleep_ns", ps, unit_ty);
        }
        // __localtime_offset_minutes() -> i32
        {
            const ps = self.arena.allocator().alloc(*Type, 0) catch return;
            define(self, env, "__localtime_offset_minutes", ps, i32_ty);
        }
        // __systemtime_to_local_components(ns: i128) -> TimeComponents
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i128_ty;
            define(self, env, "__systemtime_to_local_components", ps, time_comp_ty);
        }
        // __systemtime_to_utc_components(ns: i128) -> TimeComponents
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = i128_ty;
            define(self, env, "__systemtime_to_utc_components", ps, time_comp_ty);
        }
        // __components_to_ns_utc(comp: TimeComponents) -> Throw<i128, TimeError>
        {
            const ps = self.arena.allocator().alloc(*Type, 1) catch return;
            ps[0] = time_comp_ty;
            define(self, env, "__components_to_ns_utc", ps, makeThrowTy(self, i128_ty, time_error_ty));
        }
    }
    fn registerBuiltinName(self: *TypeInferencer, name: []const u8) void {
        if (!self.builtin_names.contains(name)) {
            const key = self.arena.allocator().dupe(u8, name) catch return;
            self.builtin_names.put(key, {}) catch return;
        }
    }
    pub fn isBuiltinName(self: *TypeInferencer, name: []const u8) bool {
        return self.builtin_names.contains(name);
    }
    /// typeof 内建函数的类型推断：typeof(TypeName) -> TypeInfo<TypeName>
    ///
    /// 参数语义：参数位置出现类型名（在值位置传递类型引用）
    /// - 具体类型：Point / i32 / str / Shape 等
    /// - 类型参数：T（在泛型函数内）
    /// - Self（在 Trait 默认方法内）
    ///
    /// 返回 TypeInfo<T> 类型。具体类型解析后由 IRBuilder 在 type_metadata_table
    /// 中查找；泛型 T 在运行时由引擎通过类型参数上下文查表。
    fn inferTypeofCall(
        self: *TypeInferencer,
        arguments: []*ast.Expr,
        env: *TypeEnv,
        loc: ast.SourceLocation,
    ) SemaError!*Type {
        if (arguments.len != 1) {
            self.addErrorAt(.type_mismatch, loc.line, loc.column, "typeof expects exactly 1 type argument, got {d}", .{arguments.len});
            return self.makeType(.unit_type) catch error.OutOfMemory;
        }
        // 参数必须是标识符（类型名）或 propagate（typeof(T?) 形式）
        const arg_expr = arguments[0];
        switch (arg_expr.*) {
            .propagate => |p| {
                // typeof(T?) — nullable 类型包装
                // 递归处理 inner expr 作为类型，构造 TypeInfo<T?> 类型
                var inner_args = [_]*ast.Expr{p.expr};
                const inner_type_info = try self.inferTypeofCall(&inner_args, env, loc);
                // inner_type_info 是 TypeInfo<T>，我们需要 TypeInfo<T?>
                // 从 TypeInfo<T> 中提取 T：TypeInfo 是 generic_type.args[0]
                if (inner_type_info.* == .generic_type and inner_type_info.generic_type.args.len == 1) {
                    const inner_ty = inner_type_info.generic_type.args[0];
                    const nullable_ty = try self.makeNullableType(inner_ty);
                    return self.makeGenericType("TypeInfo", &[_]*Type{nullable_ty}) catch error.OutOfMemory;
                }
                self.addErrorAt(.type_mismatch, loc.line, loc.column, "typeof(T?): inner type resolution failed", .{});
                return self.makeType(.unit_type) catch error.OutOfMemory;
            },
            .identifier => {},
            else => {
                self.addErrorAt(.type_mismatch, loc.line, loc.column, "typeof argument must be a type name (identifier) or T? (propagate), got {s}", .{@tagName(arg_expr.*)});
                return self.makeType(.unit_type) catch error.OutOfMemory;
            },
        }
        const type_name = arg_expr.identifier.name;
        // 1. 检查是否是 Self（Trait 默认方法内）
        if (std.mem.eql(u8, type_name, "Self")) {
            if (self.current_self_type) |self_ty| {
                return self.makeGenericType("TypeInfo", &[_]*Type{self_ty}) catch error.OutOfMemory;
            }
            self.addErrorAt(.type_mismatch, loc.line, loc.column, "typeof(Self): Self is not available in current context", .{});
            return self.makeType(.unit_type) catch error.OutOfMemory;
        }
        // 2. 检查是否是当前泛型函数的类型参数
        if (self.current_type_params) |tpm| {
            if (tpm.get(type_name)) |t| {
                return self.makeGenericType("TypeInfo", &[_]*Type{t}) catch error.OutOfMemory;
            }
        }
        // 3. 检查是否是内建类型（i32, str, bool 等）
        inline for (BUILTIN_TYPES) |entry| {
            if (std.mem.eql(u8, entry.name, type_name)) {
                const t = self.makeType(entry.ty) catch return error.OutOfMemory;
                return self.makeGenericType("TypeInfo", &[_]*Type{t}) catch error.OutOfMemory;
            }
        }
        // 4. 检查是否是 ADT/Record/Newtype/Alias 类型
        if (self.adt_types.get(type_name)) |info| {
            return self.makeGenericType("TypeInfo", &[_]*Type{info.ty}) catch error.OutOfMemory;
        }
        // 5. 检查是否是 Trait 类型
        if (self.trait_types.contains(type_name)) {
            const t = self.arena.allocator().create(Type) catch return error.OutOfMemory;
            t.* = Type{ .trait_type = .{ .name = type_name, .type_args = &[_]*Type{} } };
            self.types.append(self.arena.allocator(), t) catch return error.OutOfMemory;
            return self.makeGenericType("TypeInfo", &[_]*Type{t}) catch error.OutOfMemory;
        }
        // 6. 未找到类型
        self.addErrorAt(.type_mismatch, loc.line, loc.column, "typeof: unknown type '{s}'", .{type_name});
        return self.makeType(.unit_type) catch error.OutOfMemory;
    }
    fn unwrapAtomic(self: *TypeInferencer, ty: *Type) *Type {
        const resolved = self.resolve(ty);
        if (resolved.* == .generic_type) {
            if (std.mem.eql(u8, resolved.generic_type.name, "Atomic") and resolved.generic_type.args.len == 1) {
                return resolved.generic_type.args[0];
            }
        }
        return ty;
    }
    fn adtInfoToTypeDef(self: *TypeInferencer, name: []const u8, info: AdtInfo) !TypeDefInfo {
        const kind: TypeDefKind = blk: {
            if (info.is_error_newtype) break :blk .error_newtype;
            if (info.is_gadt and info.constructor_names.len == 1) break :blk .newtype;
            break :blk .adt;
        };
        const ctors = try self.arena.allocator().alloc(CtorDefInfo, info.constructor_names.len);
        for (info.constructor_names, 0..) |ctor_name, i| {
            const field_types: []const *Type = if (i < info.ctor_field_types.len) info.ctor_field_types[i] else &[_]*Type{};
            const field_names: []const ?[]const u8 = if (i < info.ctor_field_names.len) info.ctor_field_names[i] else &[_]?[]const u8{};
            const field_chan_types = try typesToChanTypes(self.arena.allocator(), field_types);
            const field_type_names = try typeNamesOfTypes(self.arena.allocator(), field_types);
            const return_type_name: ?[]const u8 = if (i < info.ctor_return_types.len)
                (if (info.ctor_return_types[i]) |rt| typeNameOfType(self.resolve(rt)) else null)
            else
                null;
            ctors[i] = .{
                .name = ctor_name,
                .type_name = name,
                .field_names = field_names,
                .field_chan_types = field_chan_types,
                .field_type_names = field_type_names,
                .is_newtype = (kind == .newtype),
                .return_type_name = return_type_name,
            };
        }
        return .{
            .name = name,
            .kind = kind,
            .constructors = ctors,
            .type_params = info.type_param_names,
        };
    }
    fn traitInfoToTraitDef(self: *TypeInferencer, name: []const u8, info: TraitInfo, ast_methods: []const ast.MethodDecl) !TraitDefInfo {
        const methods = try self.arena.allocator().alloc(TraitMethodSig, info.method_names.len);
        for (info.method_names, 0..) |mname, i| {
            // 从 AST 方法声明查找是否有默认实现体
            const has_body = blk: {
                for (ast_methods) |m| {
                    if (std.mem.eql(u8, m.name, mname)) break :blk m.body != null;
                }
                break :blk false;
            };
            if (info.method_schemes.get(mname)) |scheme| {
                const resolved = self.resolve(scheme.ty);
                if (resolved.* == .fn_type) {
                    const param_count: u8 = @intCast(resolved.fn_type.params.len);
                    const return_ct = semaTypeToChanType(resolved.fn_type.return_type) orelse .ref_chan;
                    methods[i] = .{
                        .name = mname,
                        .param_count = param_count,
                        .return_chan_type = return_ct,
                        .has_body = has_body,
                    };
                } else {
                    methods[i] = .{
                        .name = mname,
                        .param_count = 0,
                        .return_chan_type = .null_chan,
                        .has_body = has_body,
                    };
                }
            } else {
                methods[i] = .{
                    .name = mname,
                    .param_count = 0,
                    .return_chan_type = .null_chan,
                    .has_body = has_body,
                };
            }
        }
        return .{ .name = name, .methods = methods };
    }
    fn schemeToFuncSig(
        self: *TypeInferencer,
        name: []const u8,
        scheme: TypeScheme,
        ast_type_params: []const ast.TypeParam,
        is_async: bool,
        is_throwing: bool,
    ) !FuncSigInfo {
        const resolved = self.resolve(scheme.ty);
        if (resolved.* != .fn_type) {
            const tp_names = try self.arena.allocator().alloc([]const u8, ast_type_params.len);
            for (ast_type_params, 0..) |tp, i| tp_names[i] = tp.name;
            return .{
                .name = name,
                .type_params = tp_names,
                .param_chan_types = &[_]ChanType{},
                .return_chan_type = .null_chan,
                .param_is_ref = &[_]bool{},
                .is_async = is_async,
                .is_throwing = is_throwing,
            };
        }
        const ft = resolved.fn_type;
        const param_chan_types = try self.arena.allocator().alloc(ChanType, ft.params.len);
        const param_is_ref = try self.arena.allocator().alloc(bool, ft.params.len);
        for (ft.params, 0..) |p, i| {
            const presolved = self.resolve(p);
            param_chan_types[i] = semaTypeToChanType(presolved) orelse .ref_chan;
            param_is_ref[i] = (presolved.* == .ref_type);
        }
        const return_resolved = self.resolve(ft.return_type);
        const return_chan_type = semaTypeToChanType(return_resolved) orelse .ref_chan;
        const return_is_ref = (return_resolved.* == .ref_type);
        const tp_names = try self.arena.allocator().alloc([]const u8, ast_type_params.len);
        for (ast_type_params, 0..) |tp, i| tp_names[i] = tp.name;
        return .{
            .name = name,
            .type_params = tp_names,
            .param_chan_types = param_chan_types,
            .return_chan_type = return_chan_type,
            .param_is_ref = param_is_ref,
            .return_is_ref = return_is_ref,
            .is_async = is_async,
            .is_throwing = is_throwing,
        };
    }
    fn kindCheckDecl(self: *TypeInferencer, decl: ast.Decl) void {
        switch (decl) {
            .fun_decl => |f| {
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(self.arena.allocator());
                for (f.type_params) |tp| names.append(self.arena.allocator(), tp.name) catch return;
                for (f.params) |p| {
                    if (p.type_annotation) |ta| kind_check.checkTypeNode(self, ta, names.items);
                }
                if (f.return_type) |rt| kind_check.checkTypeNode(self, rt, names.items);
            },
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    switch (s.*) {
                        .val_decl => |vd| {
                            if (vd.type_annotation) |ta| kind_check.checkTypeNode(self, ta, &[_][]const u8{});
                        },
                        .var_decl => |vd| {
                            if (vd.type_annotation) |ta| kind_check.checkTypeNode(self, ta, &[_][]const u8{});
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    fn checkDeclCollecting(self: *TypeInferencer, decl: ast.Decl, env: *TypeEnv) void {
        self.kindCheckDecl(decl);
        switch (decl) {
            .fun_decl => |f| {
                const child_env = env.createChild() catch return;
                var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.arena.allocator());
                for (f.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                }
                var param_types = self.arena.allocator().alloc(*Type, f.params.len) catch return;
                for (f.params, 0..) |param, i| {
                    const param_ty: *Type = if (param.type_annotation) |ta|
                        self.typeFromAstWithParams(ta, &type_param_map) catch blk: {
                            self.addErrorAt(.type_mismatch, f.location.line, f.location.column, "invalid type annotation for parameter '{s}'", .{param.name});
                            break :blk self.freshTypeVar() catch return;
                        }
                    else
                        self.freshTypeVar() catch return;
                    param_types[i] = param_ty;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                    child_env.define(param.name, scheme) catch return;
                }
                const ret_ty_raw = if (f.return_type) |ret_type|
                    self.typeFromAstWithParams(ret_type, &type_param_map) catch self.freshTypeVar() catch return
                else
                    self.freshTypeVar() catch return;
                // async 函数：用户声明的返回类型 X 实际表示 Async<X>
                // 这样 fn_ty 签名和 unifyReturnType 都使用 Async<X>，
                // 与 body 推断的 Async<Y> 走 unifyReturnType 的 Async 递归分支，
                // 让 X 与 Y（如 i64 与 i8 字面量）正确 widen 比较。
                // 但若用户已显式声明返回 Async<X>（如 async fun sleep(): Async<Unit>），
                // 不再二次包装。
                const ret_ty = if (f.is_async) blk: {
                    const resolved_raw = self.resolve(ret_ty_raw);
                    if (resolved_raw.* == .generic_type and
                        std.mem.eql(u8, resolved_raw.generic_type.name, "Async") and
                        resolved_raw.generic_type.args.len == 1)
                    {
                        break :blk ret_ty_raw;
                    }
                    break :blk self.makeGenericType("Async", &[_]*Type{ret_ty_raw}) catch return;
                } else ret_ty_raw;
                const fn_ty = self.makeFnType(param_types, ret_ty) catch return;
                const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                const fn_scheme = TypeScheme{ .quantified_vars = qvars, .ty = fn_ty };
                child_env.define(f.name, fn_scheme) catch return;
                const prev_fn_return = self.current_fn_return_type;
                if (f.return_type) |ret_type| {
                    self.current_fn_return_type = self.typeFromAstWithParams(ret_type, &type_param_map) catch null;
                    // async 函数：声明返回类型应为 Async<X>，提取内部 X 作为 ? 传播的检查对象
                    // 这样 body 中的 `expr?` 能正确匹配外层 Throw 上下文
                    // （如 Async<Throw<File, IOError>> → current_fn_return_type = Throw<File, IOError>）
                    if (f.is_async) {
                        if (self.current_fn_return_type) |fr| {
                            const resolved = self.resolve(fr);
                            if (resolved.* == .generic_type and
                                std.mem.eql(u8, resolved.generic_type.name, "Async") and
                                resolved.generic_type.args.len == 1)
                            {
                                self.current_fn_return_type = resolved.generic_type.args[0];
                            }
                        }
                    }
                } else {
                    self.current_fn_return_type = null;
                }
                defer self.current_fn_return_type = prev_fn_return;
                const prev_type_params = self.current_type_params;
                self.current_type_params = if (f.type_params.len > 0) &type_param_map else prev_type_params;
                defer self.current_type_params = prev_type_params;
                const prev_fn_info = self.current_fn_info;
                const owned_type_param_ids = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                self.current_fn_info = CurrentFnInfo{
                    .name = f.name,
                    .has_type_params = f.type_params.len > 0,
                    .has_return_annotation = f.return_type != null,
                    .type_param_ids = owned_type_param_ids,
                };
                defer {
                    if (self.current_fn_info) |info| {
                        self.arena.allocator().free(info.type_param_ids);
                    }
                    self.current_fn_info = prev_fn_info;
                }
                const body_ty = self.inferExpr(f.body, child_env, null) catch |err| {
                    self.reportInferError(err, f.location);
                    return;
                };
                const effective_body_ty = if (f.is_async)
                    self.makeGenericType("Async", &[_]*Type{body_ty}) catch return
                else
                    body_ty;
                self.unifyReturnType(ret_ty, effective_body_ty) catch |err| {
                    self.reportUnifyError(err, f.location, ret_ty, effective_body_ty);
                };
                const final_scheme = if (f.bounds.len > 0)
                    self.generalizeWithBounds(env, fn_ty, type_param_ids.items, f.bounds) catch return
                else
                    self.generalize(env, fn_ty) catch return;
                if (self.isBuiltinName(f.name)) {
                    if (!std.mem.eql(u8, f.name, "compare") and !std.mem.eql(u8, f.name, "str")) {
                        self.addErrorAt(.type_mismatch, f.location.line, f.location.column, "cannot redefine built-in name '{s}'", .{f.name});
                    } else {
                        env.redefine(f.name, final_scheme) catch return;
                    }
                } else if (self.predeclared_fns.contains(f.name)) {
                    env.redefine(f.name, final_scheme) catch return;
                } else if (!(env.defineOrReport(f.name, final_scheme) catch false)) {
                    self.addErrorAt(.type_mismatch, f.location.line, f.location.column, "duplicate definition: '{s}' is already defined in this scope", .{f.name});
                }
                if (f.visibility == .public) {
                    self.recordExportSymbol(self.current_module, f.name, env);
                }
                for (f.bounds) |bound| {
                    self.checkTraitBound(bound, f.location);
                }
                if (f.bounds.len > 0) {
                    const name_copy = self.arena.allocator().dupe(u8, f.name) catch return;
                    const bounds_copy = self.arena.allocator().alloc(ast.TraitBound, f.bounds.len) catch return;
                    @memcpy(bounds_copy, f.bounds);
                    self.fn_bounds.put(name_copy, bounds_copy) catch return;
                }
                if (self.sema_result) |sr| {
                    const is_throwing = blk: {
                        var rt = self.resolve(ret_ty);
                        if (rt.* == .generic_type and std.mem.eql(u8, rt.generic_type.name, "Async") and rt.generic_type.args.len == 1) {
                            rt = self.resolve(rt.generic_type.args[0]);
                        }
                        break :blk rt.* == .throw_type;
                    };
                    sr.putFuncSig(self.schemeToFuncSig(f.name, final_scheme, f.type_params, f.is_async, is_throwing) catch return) catch {};
                }
            },
            .type_decl => |td| {
                switch (td.def) {
                    .adt => |adt_def| {
                        var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.arena.allocator());
                        var type_param_names = std.ArrayList([]const u8).empty;
                        defer type_param_names.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                            const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                            type_param_names.append(self.arena.allocator(), name_copy) catch return;
                        }
                        var adt_args = std.ArrayList(*Type).empty;
                        defer adt_args.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = type_param_map.get(tp.name).?;
                            adt_args.append(self.arena.allocator(), tv) catch return;
                        }
                        const adt_ty = self.makeAdtType(td.name, adt_args.items) catch return;
                        var ctor_names = self.arena.allocator().alloc([]const u8, adt_def.constructors.len) catch return;
                        for (adt_def.constructors, 0..) |con, i| {
                            ctor_names[i] = con.name;
                        }
                        const key = self.arena.allocator().dupe(u8, td.name) catch return;
                        const owned_type_param_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                        const is_predeclared = self.predeclared_types.contains(td.name);
                        const dup_or_builtin = self.isBuiltinName(td.name) or (self.adt_types.contains(td.name) and !is_predeclared);
                        if (self.isBuiltinName(td.name)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (is_predeclared) {
                            // 已 predeclared：跳过 adt_types 重复注册（predeclare 已注册）
                            // ctor_field_types 等字段会在下面的 !dup_or_builtin 分支中更新
                        } else if (self.adt_types.contains(td.name)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "duplicate type definition: '{s}' is already defined in this scope", .{td.name});
                        } else {
                            self.adt_types.put(key, AdtInfo{
                                .ty = adt_ty,
                                .constructor_names = ctor_names,
                                .type_param_names = owned_type_param_names,
                                .defining_module = self.current_module,
                            }) catch return;
                        }
                        const ctor_field_types = self.arena.allocator().alloc([]const *Type, adt_def.constructors.len) catch return;
                        const ctor_field_names = self.arena.allocator().alloc([]const ?[]const u8, adt_def.constructors.len) catch return;
                        const ctor_return_types = self.arena.allocator().alloc(?*Type, adt_def.constructors.len) catch return;
                        var is_gadt = false;
                        for (adt_def.constructors, 0..) |con, ci| {
                            const fts = self.arena.allocator().alloc(*Type, con.fields.len) catch return;
                            const fns = self.arena.allocator().alloc(?[]const u8, con.fields.len) catch return;
                            for (con.fields, 0..) |field, fi| {
                                fts[fi] = self.typeFromAstWithParams(field.ty, &type_param_map) catch (self.freshTypeVar() catch return);
                                fns[fi] = field.name;
                            }
                            ctor_field_types[ci] = fts;
                            ctor_field_names[ci] = fns;
                            if (con.return_type) |rt| {
                                is_gadt = true;
                                ctor_return_types[ci] = self.typeFromAstWithParams(rt, &type_param_map) catch null;
                            } else {
                                ctor_return_types[ci] = null;
                            }
                        }
                        if (!dup_or_builtin) {
                            if (self.adt_types.getPtr(td.name)) |info| {
                                info.is_gadt = is_gadt;
                                info.ctor_field_types = ctor_field_types;
                                info.ctor_field_names = ctor_field_names;
                                info.ctor_return_types = ctor_return_types;
                            }
                            if (self.sema_result) |sr| {
                                if (self.adt_types.get(td.name)) |info| {
                                    const td_info = self.adtInfoToTypeDef(td.name, info) catch return;
                                    sr.putTypeDef(td_info) catch {};
                                }
                            }
                        }
                        const mod_key = self.arena.allocator().dupe(u8, td.name) catch return;
                        const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                        self.type_defining_modules.put(mod_key, mod_val) catch return;
                        for (adt_def.constructors, 0..) |con, ci| {
                            const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                            const ret_ty = ctor_return_types[ci] orelse adt_ty;
                            if (self.isBuiltinName(con.name)) {
                                self.addErrorAt(.type_mismatch, con.location.line, con.location.column, "cannot redefine built-in name '{s}'", .{con.name});
                            } else if (con.fields.len == 0) {
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ret_ty };
                                if (self.predeclared_types.contains(td.name)) {
                                    env.redefine(con.name, scheme) catch {};
                                } else if (!(env.defineOrReport(con.name, scheme) catch false)) {
                                    self.addErrorAt(.type_mismatch, con.location.line, con.location.column, "duplicate definition: '{s}' is already defined in this scope", .{con.name});
                                }
                            } else {
                                const ctor_ty = self.makeFnType(@constCast(ctor_field_types[ci]), ret_ty) catch return;
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                                if (self.predeclared_types.contains(td.name)) {
                                    env.redefine(con.name, scheme) catch {};
                                } else if (!(env.defineOrReport(con.name, scheme) catch false)) {
                                    self.addErrorAt(.type_mismatch, con.location.line, con.location.column, "duplicate definition: '{s}' is already defined in this scope", .{con.name});
                                }
                            }
                        }
                        if (td.visibility == .public) {
                            for (adt_def.constructors) |con| {
                                self.recordExportSymbol(self.current_module, con.name, env);
                            }
                        }
                    },
                    .record => |rec_def| {
                        var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                        }
                        var fields = self.arena.allocator().alloc(FieldType, rec_def.fields.len) catch return;
                        for (rec_def.fields, 0..) |f, i| {
                            fields[i] = FieldType{
                                .name = f.name,
                                .ty = self.typeFromAstWithParams(f.ty, &type_param_map) catch return,
                            };
                        }
                        const rec_ty = self.arena.allocator().create(Type) catch return;
                        rec_ty.* = Type{ .record_type = .{ .fields = fields } };
                        self.types.append(self.arena.allocator(), rec_ty) catch return;
                        var param_types = self.arena.allocator().alloc(*Type, rec_def.fields.len) catch return;
                        for (rec_def.fields, 0..) |f, i| {
                            param_types[i] = self.typeFromAstWithParams(f.ty, &type_param_map) catch return;
                        }
                        const ctor_ty = self.makeFnType(param_types, rec_ty) catch return;
                        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                        if (self.isBuiltinName(td.name)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (self.predeclared_types.contains(td.name)) {
                            env.redefine(td.name, scheme) catch {};
                        } else if (!(env.defineOrReport(td.name, scheme) catch false)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "duplicate definition: '{s}' is already defined", .{td.name});
                        }
                        if (!self.adt_types.contains(td.name)) {
                            const key = self.arena.allocator().dupe(u8, td.name) catch return;
                            const type_param_names = self.arena.allocator().alloc([]const u8, td.type_params.len) catch return;
                            for (td.type_params, 0..) |tp, i| {
                                type_param_names[i] = tp.name;
                            }
                            self.adt_types.put(key, AdtInfo{
                                .ty = rec_ty,
                                .constructor_names = &[_][]const u8{},
                                .type_param_names = type_param_names,
                            }) catch return;
                            if (self.sema_result) |sr| {
                                const field_chan_types = typesToChanTypes(self.arena.allocator(), param_types) catch return;
                                const field_type_names = typeNamesOfTypes(self.arena.allocator(), param_types) catch return;
                                const field_name_list = self.arena.allocator().alloc(?[]const u8, fields.len) catch return;
                                for (fields, 0..) |f, i| field_name_list[i] = f.name;
                                const record_ctors = self.arena.allocator().alloc(CtorDefInfo, 1) catch return;
                                record_ctors[0] = .{
                                    .name = td.name,
                                    .type_name = td.name,
                                    .field_names = field_name_list,
                                    .field_chan_types = field_chan_types,
                                    .field_type_names = field_type_names,
                                };
                                sr.putTypeDef(.{
                                    .name = td.name,
                                    .kind = .record,
                                    .constructors = record_ctors,
                                    .type_params = type_param_names,
                                }) catch {};
                            }
                        }
                    },
                    .alias => |ta| {
                        var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.arena.allocator());
                        var type_param_names = std.ArrayList([]const u8).empty;
                        defer type_param_names.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                            const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                            type_param_names.append(self.arena.allocator(), name_copy) catch return;
                        }
                        const target_ty = self.typeFromAstWithParams(ta.target, &type_param_map) catch {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "invalid target type in type alias '{s}'", .{td.name});
                            return;
                        };
                        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = target_ty };
                        if (self.isBuiltinName(td.name)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (self.predeclared_types.contains(td.name)) {
                            env.redefine(td.name, scheme) catch {};
                        } else if (!(env.defineOrReport(td.name, scheme) catch false)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "duplicate definition: '{s}' is already defined", .{td.name});
                        }
                        if (!self.adt_types.contains(td.name)) {
                            const key = self.arena.allocator().dupe(u8, td.name) catch return;
                            const owned_type_param_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                            self.adt_types.put(key, AdtInfo{
                                .ty = target_ty,
                                .constructor_names = &[_][]const u8{},
                                .type_param_names = owned_type_param_names,
                                .defining_module = self.current_module,
                            }) catch return;
                            if (self.sema_result) |sr| {
                                const resolved_target = self.resolve(target_ty);
                                sr.putTypeDef(.{
                                    .name = td.name,
                                    .kind = .alias,
                                    .constructors = &[_]CtorDefInfo{},
                                    .type_params = owned_type_param_names,
                                    .target_type_name = typeNameOfType(resolved_target),
                                    .target_chan_type = semaTypeToChanType(resolved_target),
                                }) catch {};
                            }
                        }
                    },
                    .newtype => |nt| {
                        var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.arena.allocator());
                        var type_param_names = std.ArrayList([]const u8).empty;
                        defer type_param_names.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.arena.allocator(), tv.type_var.id) catch return;
                            const name_copy = self.arena.allocator().dupe(u8, tp.name) catch return;
                            type_param_names.append(self.arena.allocator(), name_copy) catch return;
                        }
                        var adt_args = std.ArrayList(*Type).empty;
                        defer adt_args.deinit(self.arena.allocator());
                        for (td.type_params) |tp| {
                            const tv = type_param_map.get(tp.name).?;
                            adt_args.append(self.arena.allocator(), tv) catch return;
                        }
                        const newtype_ty = self.makeAdtType(td.name, adt_args.items) catch return;
                        const inner_ty = self.typeFromAstWithParams(nt.inner, &type_param_map) catch return;
                        // 构造器字段类型/名称（newtype 有 1 个构造器，1 个字段 _0）
                        const ctor_field_types = self.arena.allocator().alloc([]const *Type, 1) catch return;
                        const nt_fts = self.arena.allocator().alloc(*Type, 1) catch return;
                        nt_fts[0] = inner_ty;
                        ctor_field_types[0] = nt_fts;
                        const ctor_field_names = self.arena.allocator().alloc([]const ?[]const u8, 1) catch return;
                        const nt_fns = self.arena.allocator().alloc(?[]const u8, 1) catch return;
                        nt_fns[0] = "_0";
                        ctor_field_names[0] = nt_fns;
                        const nt_return_types = self.arena.allocator().alloc(?*Type, 1) catch return;
                        nt_return_types[0] = null;
                        if (!self.adt_types.contains(td.name)) {
                            const type_key = self.arena.allocator().dupe(u8, td.name) catch return;
                            const ctor_names_single = self.arena.allocator().alloc([]const u8, 1) catch return;
                            ctor_names_single[0] = nt.name;
                            const owned_tp_names = type_param_names.toOwnedSlice(self.arena.allocator()) catch return;
                            self.adt_types.put(type_key, AdtInfo{
                                .ty = newtype_ty,
                                .constructor_names = ctor_names_single,
                                .type_param_names = owned_tp_names,
                                .defining_module = self.current_module,
                                .is_gadt = true,
                                .ctor_field_types = ctor_field_types,
                                .ctor_field_names = ctor_field_names,
                                .ctor_return_types = nt_return_types,
                            }) catch return;
                            const mod_key = self.arena.allocator().dupe(u8, td.name) catch return;
                            const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                            self.type_defining_modules.put(mod_key, mod_val) catch return;
                        } else {
                            if (self.adt_types.getPtr(td.name)) |info| {
                                info.is_gadt = true;
                                info.ctor_field_types = ctor_field_types;
                                info.ctor_field_names = ctor_field_names;
                                info.ctor_return_types = nt_return_types;
                            }
                        }
                        // 注册到 sema_result（与 ADT case 一致，不受 predeclare 影响）
                        if (self.sema_result) |sr| {
                            if (self.adt_types.get(td.name)) |info| {
                                sr.putTypeDef(self.adtInfoToTypeDef(td.name, info) catch return) catch {};
                            }
                        }
                        const ctor_params = self.arena.allocator().alloc(*Type, 1) catch return;
                        ctor_params[0] = inner_ty;
                        const ctor_ty = self.makeFnType(ctor_params, newtype_ty) catch return;
                        const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                        if (self.isBuiltinName(nt.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{nt.name});
                        } else if (self.predeclared_types.contains(td.name)) {
                            env.redefine(nt.name, scheme) catch {};
                        } else if (!(env.defineOrReport(nt.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{nt.name});
                        }
                        if (td.visibility == .public) {
                            self.recordExportSymbol(self.current_module, nt.name, env);
                        }
                    },
                    .error_newtype => |en| {
                        const error_adt = self.makeAdtType(en.name, &[_]*Type{}) catch return;
                        const ctor_params = self.arena.allocator().alloc(*Type, 1) catch return;
                        ctor_params[0] = self.makeType(.str_type) catch return;
                        const ctor_ty = self.makeFnType(ctor_params, error_adt) catch return;
                        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = ctor_ty };
                        const is_predeclared = self.predeclared_types.contains(td.name);
                        if (self.isBuiltinName(en.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{en.name});
                        } else if (is_predeclared) {
                            env.redefine(en.name, scheme) catch {};
                        } else if (!(env.defineOrReport(en.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{en.name});
                        }
                        if (self.isBuiltinName(en.name)) {} else if (is_predeclared) {
                            // 已 predeclared：跳过 adt_types 重复注册（predeclare 已注册）
                            // 但仍需补充 ctor_field_types/names 并注册到 sema_result
                            // （predeclare 阶段未设置 ctor_field_types，也未调用 putTypeDef）
                            if (self.adt_types.getPtr(en.name)) |info| {
                                const fts = self.arena.allocator().alloc(*Type, en.params.len) catch return;
                                const fns = self.arena.allocator().alloc(?[]const u8, en.params.len) catch return;
                                for (en.params, 0..) |param, fi| {
                                    fts[fi] = if (param.type_annotation) |tn|
                                        self.typeFromAstWithParams(tn, null) catch (self.makeType(.str_type) catch return)
                                    else
                                        self.makeType(.str_type) catch return;
                                    fns[fi] = param.name;
                                }
                                const ctor_field_types_arr = self.arena.allocator().alloc([]const *Type, 1) catch return;
                                const ctor_field_names_arr = self.arena.allocator().alloc([]const ?[]const u8, 1) catch return;
                                ctor_field_types_arr[0] = fts;
                                ctor_field_names_arr[0] = fns;
                                info.ctor_field_types = ctor_field_types_arr;
                                info.ctor_field_names = ctor_field_names_arr;
                            }
                            if (self.sema_result) |sr| {
                                if (self.adt_types.get(en.name)) |info| {
                                    sr.putTypeDef(self.adtInfoToTypeDef(en.name, info) catch return) catch {};
                                }
                            }
                        } else if (self.adt_types.contains(en.name)) {
                            self.addError(.type_mismatch, "duplicate type definition: '{s}' is already defined", .{en.name});
                        } else {
                            const key = self.arena.allocator().dupe(u8, en.name) catch return;
                            const ctor_names = self.arena.allocator().alloc([]const u8, 1) catch return;
                            ctor_names[0] = en.name;
                            self.adt_types.put(key, AdtInfo{ .ty = error_adt, .constructor_names = ctor_names, .is_error_newtype = true }) catch return;
                            const mod_key = self.arena.allocator().dupe(u8, en.name) catch return;
                            const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                            self.type_defining_modules.put(mod_key, mod_val) catch return;
                            if (self.sema_result) |sr| {
                                if (self.adt_types.get(en.name)) |info| {
                                    sr.putTypeDef(self.adtInfoToTypeDef(en.name, info) catch return) catch {};
                                }
                            }
                        }
                    },
                }
                if (td.methods.len > 0) {
                    // 漏洞修复 #1：Type 内部同名方法必须报错（重复定义）
                    {
                        var seen_methods = std.StringHashMap(void).init(self.arena.allocator());
                        defer seen_methods.deinit();
                        for (td.methods) |method| {
                            if (seen_methods.contains(method.name)) {
                                self.addErrorAt(.signature_mismatch, method.location.line, method.location.column, "duplicate method '{s}' in type '{s}'", .{ method.name, td.name });
                            } else {
                                const owned_name = self.arena.allocator().dupe(u8, method.name) catch continue;
                                seen_methods.put(owned_name, {}) catch continue;
                            }
                        }
                    }
                    const self_type = if (self.adt_types.get(td.name)) |info| info.ty else null;
                    if (self_type) |st| {
                        const old_self_type = self.current_self_type;
                        defer self.current_self_type = old_self_type;
                        self.current_self_type = st;
                        for (td.methods) |method| {
                            var type_param_map = std.StringHashMap(*Type).init(self.arena.allocator());
                            defer type_param_map.deinit();
                            for (td.type_params) |tp| {
                                const tv = self.freshTypeVar() catch continue;
                                type_param_map.put(tp.name, tv) catch continue;
                            }
                            for (method.type_params) |tp| {
                                const tv = self.freshTypeVar() catch continue;
                                type_param_map.put(tp.name, tv) catch continue;
                            }
                            const old_type_params = self.current_type_params;
                            defer self.current_type_params = old_type_params;
                            self.current_type_params = &type_param_map;

                            // 收集参数类型数组，供构造 fn scheme 复用
                            var param_types_list = std.ArrayList(*Type).empty;
                            defer param_types_list.deinit(self.arena.allocator());

                            const return_ty: *Type = blk: {
                                if (method.body) |body| {
                                    var method_env = TypeEnv.init(self.arena.allocator());
                                    defer method_env.deinit();
                                    for (method.params) |param| {
                                        // self 参数：绑定到所在 type 的类型（td.name 对应的 self_type）
                                        // 否则 method 体内 self.field 会因为 type_var 无法解析字段类型，
                                        // 导致 IRBuilder 拿不到 chan_type，fallback 到 i64_chan，
                                        // 进而破坏 ref 字段值（get() 返回跨类型字段的 bug 根源）。
                                        const is_self_param = std.mem.eql(u8, param.name, "self");
                                        const param_ty = if (is_self_param) pblk: {
                                            if (self.current_self_type) |self_st| break :pblk self_st;
                                            // 退化路径：无 self_type 时仍 fallback 到标注或 fresh var
                                            if (param.type_annotation) |ty|
                                                break :pblk self.typeFromAstWithParams(ty, &type_param_map) catch self.freshTypeVar() catch continue;
                                            break :pblk self.freshTypeVar() catch continue;
                                        } else if (param.type_annotation) |ty|
                                            self.typeFromAstWithParams(ty, &type_param_map) catch self.freshTypeVar() catch continue
                                        else
                                            self.freshTypeVar() catch continue;
                                        param_types_list.append(self.arena.allocator(), param_ty) catch continue;
                                        const scheme = TypeScheme{
                                            .quantified_vars = &[_]usize{},
                                            .ty = param_ty,
                                            .bounds = &[_]BoundInfo{},
                                        };
                                        method_env.define(param.name, scheme) catch continue;
                                    }
                                    const rt = if (method.return_type) |rt|
                                        self.typeFromAstWithParams(rt, &type_param_map) catch self.freshTypeVar() catch continue
                                    else
                                        self.freshTypeVar() catch continue;
                                    const old_return_type = self.current_fn_return_type;
                                    defer self.current_fn_return_type = old_return_type;
                                    self.current_fn_return_type = rt;
                                    const body_ty = self.inferExpr(body, &method_env, rt) catch |err| {
                                        self.reportInferError(err, method.location);
                                        break :blk rt;
                                    };
                                    // 与普通函数一致：用 unifyReturnType（含 int/float 拓宽），
                                    // 避免字面量推断的窄类型（如 u8 的 3）与声明的 i32 严格 unify 失败
                                    self.unifyReturnType(rt, body_ty) catch |err| {
                                        self.reportInferError(err, method.location);
                                    };
                                    break :blk rt;
                                } else {
                                    // 无 body 的方法（抽象声明）：仅从签名推断参数与返回类型
                                    for (method.params) |param| {
                                        const is_self_param = std.mem.eql(u8, param.name, "self");
                                        const param_ty = if (is_self_param) pblk: {
                                            if (self.current_self_type) |self_st| break :pblk self_st;
                                            if (param.type_annotation) |ty|
                                                break :pblk self.typeFromAstWithParams(ty, &type_param_map) catch self.freshTypeVar() catch continue;
                                            break :pblk self.freshTypeVar() catch continue;
                                        } else if (param.type_annotation) |ty|
                                            self.typeFromAstWithParams(ty, &type_param_map) catch self.freshTypeVar() catch continue
                                        else
                                            self.freshTypeVar() catch continue;
                                        param_types_list.append(self.arena.allocator(), param_ty) catch continue;
                                    }
                                    const rt = if (method.return_type) |rt|
                                        self.typeFromAstWithParams(rt, &type_param_map) catch self.freshTypeVar() catch continue
                                    else
                                        self.freshTypeVar() catch continue;
                                    break :blk rt;
                                }
                            };

                            // 将方法以 mangled name "TypeName.method" 注册到外层 env，
                            // 供 trait_resolve.inferMethodCall 在 o.method() 调用点查找返回类型。
                            // 这是修复 get() 返回跨类型字段值错误 bug 的关键：让 inferMethodCall
                            // 能拿到 method 的精确返回类型，而不是 fallback 到 freshTypeVar。
                            {
                                const fn_ty = self.makeFnType(param_types_list.items, return_ty) catch continue;
                                const fn_scheme = TypeScheme{
                                    .quantified_vars = &[_]usize{},
                                    .ty = fn_ty,
                                    .bounds = &[_]BoundInfo{},
                                };
                                const mangled = std.fmt.allocPrint(
                                    self.arena.allocator(),
                                    "{s}.{s}",
                                    .{ td.name, method.name },
                                ) catch continue;
                                env.redefine(mangled, fn_scheme) catch continue;
                                if (self.sema_result) |sr| {
                                    const meth_is_throwing = (self.resolve(return_ty).* == .throw_type);
                                    sr.putFuncSig(self.schemeToFuncSig(mangled, fn_scheme, method.type_params, false, meth_is_throwing) catch continue) catch {};
                                }
                            }
                        }
                    }
                }
                if (td.implemented_traits.len > 0) {
                    trait_resolve.checkTypeTraitImplementations(self, td, env);
                }
            },
            .trait_decl => |td| {
                trait_resolve.checkTraitDecl(self, td);
                if (self.sema_result) |sr| {
                    if (self.trait_types.get(td.name)) |info| {
                        sr.putTraitDef(self.traitInfoToTraitDef(td.name, info, td.methods) catch return) catch {};
                    }
                }
            },
            .import_decl => {},
            .pack_decl => {},
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    _ = self.inferStmt(s, env) catch |err| {
                        self.reportInferError(err, ed.location);
                    };
                } else {
                    _ = self.inferExpr(ed.expr, env, null) catch |err| {
                        self.reportInferError(err, ed.location);
                    };
                }
            },
        }
    }
    fn checkExhaustiveness(self: *TypeInferencer, scrutinee_ty: *Type, arms: []ast.MatchArm, location: ast.SourceLocation) void {
        const resolved = self.resolve(scrutinee_ty);
        switch (resolved.*) {
            .adt_type => |at| {
                if (self.adt_types.get(at.name)) |adt_info| {
                    const covered = self.arena.allocator().alloc(bool, adt_info.constructor_names.len) catch return;
                    defer self.arena.allocator().free(covered);
                    @memset(covered, false);
                    var has_wildcard = false;
                    for (arms) |arm| {
                        if (self.patternCoversWildcard(arm.pattern)) {
                            has_wildcard = true;
                            break;
                        }
                        self.markCoveredConstructors(arm.pattern, adt_info.constructor_names, covered);
                        if (adt_info.is_error_newtype) {
                            if (self.patternCoversConstructorNamed(arm.pattern, "Error")) {
                                for (0..covered.len) |i| {
                                    covered[i] = true;
                                }
                            }
                        }
                    }
                    if (has_wildcard) return;
                    var all_covered = true;
                    for (covered) |c| {
                        if (!c) {
                            all_covered = false;
                            break;
                        }
                    }
                    if (all_covered) return;
                    var missing_buf = std.ArrayList(u8).empty;
                    defer missing_buf.deinit(self.arena.allocator());
                    var first = true;
                    for (covered, 0..) |c, i| {
                        if (!c) {
                            if (!first) {
                                missing_buf.appendSlice(self.arena.allocator(), ", ") catch return;
                            }
                            missing_buf.appendSlice(self.arena.allocator(), adt_info.constructor_names[i]) catch return;
                            first = false;
                        }
                    }
                    self.addErrorAt(.non_exhaustive_match, location.line, location.column, "non-exhaustive match: missing patterns: {s}", .{missing_buf.items});
                }
            },
            .nullable_type => {
                var has_null = false;
                var has_wildcard = false;
                for (arms) |arm| {
                    if (self.patternCoversWildcard(arm.pattern)) {
                        has_wildcard = true;
                        break;
                    }
                    if (self.patternCoversNull(arm.pattern)) {
                        has_null = true;
                    }
                }
                if (has_wildcard) return;
                if (has_null) return;
                self.addErrorAt(.non_exhaustive_match, location.line, location.column, "non-exhaustive match: missing pattern: null", .{});
            },
            .throw_type => {
                var has_ok = false;
                var has_error = false;
                var has_wildcard = false;
                for (arms) |arm| {
                    if (self.patternCoversWildcard(arm.pattern)) {
                        has_wildcard = true;
                        break;
                    }
                    if (self.patternCoversConstructorNamed(arm.pattern, "Ok")) {
                        has_ok = true;
                    }
                    if (self.patternCoversConstructorNamed(arm.pattern, "Error")) {
                        has_error = true;
                    }
                }
                if (has_wildcard) return;
                var missing_buf = std.ArrayList(u8).empty;
                defer missing_buf.deinit(self.arena.allocator());
                var first = true;
                if (!has_ok) {
                    missing_buf.appendSlice(self.arena.allocator(), "Ok") catch return;
                    first = false;
                }
                if (!has_error) {
                    if (!first) {
                        missing_buf.appendSlice(self.arena.allocator(), ", ") catch return;
                    }
                    missing_buf.appendSlice(self.arena.allocator(), "Error") catch return;
                }
                if (!has_ok or !has_error) {
                    self.addErrorAt(.non_exhaustive_match, location.line, location.column, "non-exhaustive match: missing patterns: {s}", .{missing_buf.items});
                }
            },
            else => {},
        }
    }
    fn patternCoversWildcard(self: *TypeInferencer, pat: *const ast.Pattern) bool {
        return switch (pat.*) {
            .wildcard => true,
            .variable => |v| !(v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z'),
            .or_pattern => |or_p| self.patternCoversWildcard(or_p.left) and self.patternCoversWildcard(or_p.right),
            else => false,
        };
    }
    fn patternCoversNull(self: *TypeInferencer, pat: *const ast.Pattern) bool {
        return switch (pat.*) {
            .literal => |lit| switch (lit) {
                .null => true,
                else => false,
            },
            .or_pattern => |or_p| self.patternCoversNull(or_p.left) or self.patternCoversNull(or_p.right),
            else => false,
        };
    }
    fn patternCoversConstructorNamed(self: *TypeInferencer, pat: *const ast.Pattern, name: []const u8) bool {
        return switch (pat.*) {
            .constructor => |con| std.mem.eql(u8, con.name, name),
            .or_pattern => |or_p| self.patternCoversConstructorNamed(or_p.left, name) or self.patternCoversConstructorNamed(or_p.right, name),
            else => false,
        };
    }
    fn markCoveredConstructors(self: *TypeInferencer, pat: *const ast.Pattern, constructor_names: []const []const u8, covered: []bool) void {
        switch (pat.*) {
            .constructor => |con| {
                for (constructor_names, 0..) |ctor_name, i| {
                    if (std.mem.eql(u8, con.name, ctor_name)) {
                        covered[i] = true;
                        break;
                    }
                }
            },
            .variable => |v| {
                if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                    for (constructor_names, 0..) |ctor_name, i| {
                        if (std.mem.eql(u8, v.name, ctor_name)) {
                            covered[i] = true;
                            break;
                        }
                    }
                }
            },
            .or_pattern => |or_p| {
                self.markCoveredConstructors(or_p.left, constructor_names, covered);
                self.markCoveredConstructors(or_p.right, constructor_names, covered);
            },
            else => {},
        }
    }
    fn reportInferError(self: *TypeInferencer, err: SemaError, location: ast.SourceLocation) void {
        switch (err) {
            error.TypeMismatch => self.addErrorAt(.type_mismatch, location.line, location.column, "incompatible types", .{}),
            error.UnboundVariable => self.addErrorAt(.unbound_variable, location.line, location.column, "undefined name", .{}),
            error.ArityMismatch => self.addErrorAt(.arity_mismatch, location.line, location.column, "wrong number of arguments", .{}),
            error.OccursCheckFailed => {
                if (self.current_fn_info) |fn_info| {
                    if (fn_info.has_type_params and !fn_info.has_return_annotation) {
                        self.addErrorAt(.recursive_type, location.line, location.column, "polymorphic recursive function '{s}' requires an explicit return type annotation", .{fn_info.name});
                    } else {
                        self.addErrorAt(.recursive_type, location.line, location.column, "infinite type: occurs check failed", .{});
                    }
                } else {
                    self.addErrorAt(.recursive_type, location.line, location.column, "infinite type: occurs check failed", .{});
                }
            },
            error.MissingImplementation => self.addErrorAt(.missing_implementation, location.line, location.column, "trait method not implemented", .{}),
            error.RecursiveType => self.addErrorAt(.recursive_type, location.line, location.column, "infinite type", .{}),
            error.DuplicateDefinition => self.addErrorAt(.type_mismatch, location.line, location.column, "duplicate definition", .{}),
            error.OutOfMemory => {},
        }
    }
    fn reportUnifyError(self: *TypeInferencer, err: SemaError, location: ast.SourceLocation, expected: *Type, actual: *Type) void {
        switch (err) {
            error.TypeMismatch => {
                var expected_buf = std.ArrayList(u8).empty;
                var actual_buf = std.ArrayList(u8).empty;
                defer expected_buf.deinit(self.arena.allocator());
                defer actual_buf.deinit(self.arena.allocator());
                expected.formatArrayList(&expected_buf, self.arena.allocator()) catch {};
                actual.formatArrayList(&actual_buf, self.arena.allocator()) catch {};
                self.addErrorAt(.type_mismatch, location.line, location.column, "expected {s}, got {s}", .{ expected_buf.items, actual_buf.items });
            },
            else => self.reportInferError(err, location),
        }
    }
    fn checkCallSiteTraitBound(self: *TypeInferencer, callee: *const ast.Expr, location: ast.SourceLocation) void {
        trait_resolve.checkCallSiteTraitBound(self, callee, location);
    }
    fn checkTraitBound(self: *TypeInferencer, bound: ast.TraitBound, location: ast.SourceLocation) void {
        trait_resolve.checkTraitBound(self, bound, location);
    }
};

// ──────────────────────────────────────────────
// Phase 4 isWidening 单元测试
// 验证 §4.2 精确 widening 路径表 + §7.2 int→int 规则
// ──────────────────────────────────────────────

const testing = std.testing;

test "isWidening: int→int 同符号宽化" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const i8_ty = try inf.makeType(.i8_type);
    const i16_ty = try inf.makeType(.i16_type);
    const i32_ty = try inf.makeType(.i32_type);
    const i64_ty = try inf.makeType(.i64_type);
    const i128_ty = try inf.makeType(.i128_type);
    const u8_ty = try inf.makeType(.u8_type);
    const u64_ty = try inf.makeType(.u64_type);

    // 同符号宽化 → widening
    try testing.expect(inf.isWidening(i16_ty, i8_ty));
    try testing.expect(inf.isWidening(i32_ty, i8_ty));
    try testing.expect(inf.isWidening(i64_ty, i32_ty));
    try testing.expect(inf.isWidening(i128_ty, i64_ty));
    try testing.expect(inf.isWidening(u64_ty, u8_ty));

    // 同类型 identity → widening
    try testing.expect(inf.isWidening(i32_ty, i32_ty));
    try testing.expect(inf.isWidening(u64_ty, u64_ty));

    // 同符号窄化 → 非 widening
    try testing.expect(!inf.isWidening(i8_ty, i16_ty));
    try testing.expect(!inf.isWidening(i32_ty, i64_ty));
    try testing.expect(!inf.isWidening(u8_ty, u64_ty));
}

test "isWidening: int→int 跨符号规则" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const i32_ty = try inf.makeType(.i32_type);
    const u32_ty = try inf.makeType(.u32_type);
    const i64_ty = try inf.makeType(.i64_type);
    const u64_ty = try inf.makeType(.u64_type);
    const i8_ty = try inf.makeType(.i8_type);
    const u8_ty = try inf.makeType(.u8_type);

    // 跨符号同位数 → widening (bit reinterpret)
    try testing.expect(inf.isWidening(i32_ty, u32_ty));
    try testing.expect(inf.isWidening(u32_ty, i32_ty));
    try testing.expect(inf.isWidening(i8_ty, u8_ty));
    try testing.expect(inf.isWidening(u8_ty, i8_ty));

    // 跨符号不同位数 → 非 widening (需要范围检查)
    try testing.expect(!inf.isWidening(i64_ty, u32_ty));
    try testing.expect(!inf.isWidening(u64_ty, i32_ty));
    try testing.expect(!inf.isWidening(i32_ty, u64_ty));
}

test "isWidening: int→float 按 §4.2 精确路径" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const i8_ty = try inf.makeType(.i8_type);
    const i16_ty = try inf.makeType(.i16_type);
    const i32_ty = try inf.makeType(.i32_type);
    const i64_ty = try inf.makeType(.i64_type);
    const i128_ty = try inf.makeType(.i128_type);
    const f16_ty = try inf.makeType(.f16_type);
    const f32_ty = try inf.makeType(.f32_type);
    const f64_ty = try inf.makeType(.f64_type);
    const f128_ty = try inf.makeType(.f128_type);

    // i8/i16 → f32/f64/f128 widening（精度无损）
    try testing.expect(inf.isWidening(f32_ty, i8_ty));
    try testing.expect(inf.isWidening(f64_ty, i16_ty));
    try testing.expect(inf.isWidening(f128_ty, i8_ty));

    // i32 → f64/f128 widening
    try testing.expect(inf.isWidening(f64_ty, i32_ty));
    try testing.expect(inf.isWidening(f128_ty, i32_ty));

    // i64 → f128 widening
    try testing.expect(inf.isWidening(f128_ty, i64_ty));

    // 关键 bug 修复：i64→f64 不再是 widening（f64 仅 53 位尾数）
    try testing.expect(!inf.isWidening(f64_ty, i64_ty));
    // i128→f128 不是 widening（f128 仅 113 位尾数）
    try testing.expect(!inf.isWidening(f128_ty, i128_ty));
    // i128/u128 → 任何 float 都不 widening
    try testing.expect(!inf.isWidening(f128_ty, i128_ty));

    // 任何 int→f16 都不 widening（f16 仅 10 位尾数）
    try testing.expect(!inf.isWidening(f16_ty, i8_ty));
    try testing.expect(!inf.isWidening(f16_ty, i16_ty));

    // i32→f32 不是 widening（i32 有 32 位精度，f32 仅 23 位尾数）
    try testing.expect(!inf.isWidening(f32_ty, i32_ty));
}

test "isWidening: float→float 宽化" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const f16_ty = try inf.makeType(.f16_type);
    const f32_ty = try inf.makeType(.f32_type);
    const f64_ty = try inf.makeType(.f64_type);
    const f128_ty = try inf.makeType(.f128_type);

    try testing.expect(inf.isWidening(f32_ty, f16_ty));
    try testing.expect(inf.isWidening(f64_ty, f32_ty));
    try testing.expect(inf.isWidening(f128_ty, f64_ty));
    try testing.expect(inf.isWidening(f128_ty, f16_ty));

    // 窄化 → 非 widening
    try testing.expect(!inf.isWidening(f16_ty, f32_ty));
    try testing.expect(!inf.isWidening(f32_ty, f64_ty));

    // identity → widening
    try testing.expect(inf.isWidening(f64_ty, f64_ty));
}

test "isWidening: bool → 任意数值 widening" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const bool_ty = try inf.makeType(.bool_type);
    const i32_ty = try inf.makeType(.i32_type);
    const u64_ty = try inf.makeType(.u64_type);
    const f64_ty = try inf.makeType(.f64_type);
    const str_ty = try inf.makeType(.str_type);

    try testing.expect(inf.isWidening(i32_ty, bool_ty));
    try testing.expect(inf.isWidening(u64_ty, bool_ty));
    try testing.expect(inf.isWidening(f64_ty, bool_ty));

    // bool→str 不是 widening（format 路径）
    try testing.expect(!inf.isWidening(str_ty, bool_ty));
}

test "isWidening: char → 任意其他类型非 widening" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const char_ty = try inf.makeType(.char_type);
    const i32_ty = try inf.makeType(.i32_type);
    const u32_ty = try inf.makeType(.u32_type);
    const i64_ty = try inf.makeType(.i64_type);
    const f32_ty = try inf.makeType(.f32_type);

    // char→任何其他类型都不 widening（按 §4.1 表 N=码点截断/检查）
    try testing.expect(!inf.isWidening(i32_ty, char_ty));
    try testing.expect(!inf.isWidening(u32_ty, char_ty));
    try testing.expect(!inf.isWidening(i64_ty, char_ty));
    try testing.expect(!inf.isWidening(f32_ty, char_ty));

    // char→char identity 是 widening
    try testing.expect(inf.isWidening(char_ty, char_ty));
}

test "isWidening: isize/usize 按平台位宽对应" {
    var inf = TypeInferencer.init(testing.allocator);
    defer inf.deinit();
    const isize_ty = try inf.makeType(.isize_type);
    const usize_ty = try inf.makeType(.usize_type);
    const i32_ty = try inf.makeType(.i32_type);
    const i64_ty = try inf.makeType(.i64_type);
    const u32_ty = try inf.makeType(.u32_type);
    const u64_ty = try inf.makeType(.u64_type);
    const f128_ty = try inf.makeType(.f128_type);

    // 64 位平台：isize=i64, usize=u64
    if (@bitSizeOf(isize) == 64) {
        // i32→isize 同符号宽化 → widening
        try testing.expect(inf.isWidening(isize_ty, i32_ty));
        // u32→usize 同符号宽化 → widening
        try testing.expect(inf.isWidening(usize_ty, u32_ty));
        // i64→isize identity（按平台等价）→ widening
        try testing.expect(inf.isWidening(isize_ty, i64_ty));
        // u64→usize identity → widening
        try testing.expect(inf.isWidening(usize_ty, u64_ty));
        // isize→f128 按 i64→f128 规则 → widening
        try testing.expect(inf.isWidening(f128_ty, isize_ty));
        // usize→f128 按 u64→f128 规则 → widening
        try testing.expect(inf.isWidening(f128_ty, usize_ty));
        // isize→i32 同符号窄化 → 非 widening
        try testing.expect(!inf.isWidening(i32_ty, isize_ty));
    }
}
