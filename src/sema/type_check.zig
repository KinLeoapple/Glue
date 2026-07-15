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
const subtype_check = @import("subtype_check");
const trait_resolve = @import("trait_resolve");
const throw_check = @import("throw_check");
const kind_check = @import("kind_check");
const gadt_check = @import("gadt_check");
const module_check = @import("module_check");
fn canRoundTripFloat(comptime T: type, val: f64) bool {
    if (std.math.isNan(val) or std.math.isInf(val) or val == 0.0) {
        return true;
    }
    const abs_val = @abs(val);
    const max_val: f64 = switch (T) {
        f16 => 65504.0,
        f32 => 3.4028234663852886e38,
        f64 => std.math.floatMax(f64),
        f128 => std.math.floatMax(f64),
        else => @compileError("Unsupported float type"),
    };
    if (abs_val > max_val) {
        return false;
    }
    const converted: T = @floatCast(val);
    const back: f64 = @floatCast(converted);
    const epsilon = std.math.floatEps(f64);
    const diff = @abs(back - val);
    const relative_error = if (abs_val > 0.0) diff / abs_val else diff;
    return relative_error < epsilon * 10.0;
}
var next_type_id: usize = 0;

const SINGLETON_COUNT: usize = 20;
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
    unknown_type,

    pub fn isIntType(self: Type) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type, .u8_type, .u16_type, .u32_type, .u64_type, .u128_type => true,
            else => false,
        };
    }
    pub fn isFloatType(self: Type) bool {
        return switch (self) {
            .f16_type, .f32_type, .f64_type, .f128_type => true,
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
    suppress_errors: bool = false,
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
            .exported_schemes = std.StringHashMap(TypeScheme).init(allocator),
            .module_member_sigs = std.StringHashMap([]module_check.MethodSig).init(allocator),
            .module_submodules = std.StringHashMap([][]const u8).init(allocator),
            .known_modules = std.StringHashMap(void).init(allocator),
            .builtin_names = std.StringHashMap(void).init(allocator),
            .linear_scope_stack = std.ArrayList(std.ArrayList(LinearVarInfo)).empty,
            .narrowed_paths = std.StringHashMap(void).init(allocator),
        };
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
        self.arena.deinit();
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
        const rank = struct {
            fn get(t: Type) ?u8 {
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
                    .f16_type => 9,
                    .f32_type => 10,
                    .f64_type => 11,
                    .f128_type => 12,
                    else => null,
                };
            }
        }.get;
        const w_rank = rank(w.*) orelse return false;
        const n_rank = rank(n.*) orelse return false;
        return n_rank < w_rank;
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
    fn asModuleRef(self: *TypeInferencer, ty: *Type) ?[]const u8 {
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
    fn parseIntLiteral(self: *TypeInferencer, raw: []const u8) !i128 {
        _ = self;
        var input = raw;
        var is_negative = false;
        if (input.len > 0 and input[0] == '-') {
            is_negative = true;
            input = input[1..];
        }
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (input) |c| {
            if (c != '_') {
                if (len >= buf.len) return error.TooLong;
                buf[len] = c;
                len += 1;
            }
        }
        const clean = buf[0..len];
        var value: i128 = 0;
        if (clean.len >= 2 and clean[0] == '0') {
            if (clean[1] == 'x' or clean[1] == 'X') {
                value = std.fmt.parseInt(i128, clean[2..], 16) catch return error.ParseError;
            } else if (clean[1] == 'o' or clean[1] == 'O') {
                value = std.fmt.parseInt(i128, clean[2..], 8) catch return error.ParseError;
            } else if (clean[1] == 'b' or clean[1] == 'B') {
                value = std.fmt.parseInt(i128, clean[2..], 2) catch return error.ParseError;
            } else {
                value = std.fmt.parseInt(i128, clean, 10) catch return error.ParseError;
            }
        } else {
            value = std.fmt.parseInt(i128, clean, 10) catch return error.ParseError;
        }
        return if (is_negative) -value else value;
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
                    else => 0,
                };
            }
        }.get;
        return if (rank(b.*) > rank(a.*)) b else a;
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
                    .not_eq => {
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
                    .eq => {
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
        const is_neq = bin.op == .not_eq;
        const is_eq = bin.op == .eq;
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
    /// 推断表达式的类型。这是类型检查的核心入口，递归处理所有表达式变体，
    /// 结合 expected 类型进行双向类型检查。返回推断出的类型。
    pub fn inferExpr(self: *TypeInferencer, expr: *const ast.Expr, env: *TypeEnv, expected: ?*Type) SemaError!*Type {
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
                const val = self.parseIntLiteral(lit.raw) catch {
                    return self.makeType(.i32_type);
                };
                if (val < 0) {
                    if (val >= -128) return self.makeType(.i8_type);
                    if (val >= -32768) return self.makeType(.i16_type);
                    if (val >= -2147483648) return self.makeType(.i32_type);
                    if (val >= -9223372036854775808) return self.makeType(.i64_type);
                    return self.makeType(.i128_type);
                } else {
                    if (val <= 127) return self.makeType(.i8_type);
                    if (val <= 255) return self.makeType(.u8_type);
                    if (val <= 32767) return self.makeType(.i16_type);
                    if (val <= 65535) return self.makeType(.u16_type);
                    if (val <= 2147483647) return self.makeType(.i32_type);
                    if (val <= 4294967295) return self.makeType(.u32_type);
                    if (val <= 9223372036854775807) return self.makeType(.i64_type);
                    if (val <= 18446744073709551615) return self.makeType(.u64_type);
                    return self.makeType(.i128_type);
                }
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
                const float_val = std.fmt.parseFloat(f64, lit.raw) catch {
                    return self.makeType(.f64_type);
                };
                if (canRoundTripFloat(f16, float_val)) {
                    return self.makeType(.f16_type);
                }
                if (canRoundTripFloat(f32, float_val)) {
                    return self.makeType(.f32_type);
                }
                if (canRoundTripFloat(f64, float_val)) {
                    return self.makeType(.f64_type);
                }
                return self.makeType(.f128_type);
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
                        if (rl.isIntType() and rr.isIntType()) {
                            return self.widerIntType(rl, rr);
                        }
                        try self.unify(left_ty, right_ty);
                        return left_ty;
                    },
                    .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq => {
                        const rl = self.resolve(left_ty);
                        const rr = self.resolve(right_ty);
                        if (!(rl.isIntType() and rr.isIntType())) {
                            try self.unify(left_ty, right_ty);
                        }
                        return self.makeType(.bool_type);
                    },
                    .and_op, .or_op => {
                        try self.unify(left_ty, try self.makeType(.bool_type));
                        try self.unify(right_ty, try self.makeType(.bool_type));
                        return self.makeType(.bool_type);
                    },
                    .bit_and, .bit_or, .bit_xor => {
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
                        const i32_ty = try self.makeType(.i32_type);
                        _ = self.tryWidenUnify(i32_ty, left_ty) catch {
                            try self.unify(left_ty, i32_ty);
                        };
                        _ = self.tryWidenUnify(i32_ty, right_ty) catch {
                            try self.unify(right_ty, i32_ty);
                        };
                        return self.makeType(.i32_type);
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
                        try self.unify(operand_ty, try self.makeType(.bool_type));
                        return self.makeType(.bool_type);
                    },
                    .neg => operand_ty,
                };
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
                    _ = try self.inferStmt(stmt, child_env);
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
                if (self.asModuleRef(obj_ty)) |mod_name| {
                    if (self.module_submodules.get(mod_name)) |subs| {
                        for (subs) |sub| {
                            if (std.mem.eql(u8, sub, fa.field)) {
                                return self.makeModuleRef(fa.field) catch unreachable;
                            }
                        }
                    }
                    const key = std.fmt.allocPrint(self.arena.allocator(), "{s}\x00{s}", .{ mod_name, fa.field }) catch return self.freshTypeVar() catch unreachable;
                    defer self.arena.allocator().free(key);
                    if (self.exported_schemes.get(key)) |scheme| {
                        return self.instantiate(scheme) catch unreachable;
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
                _ = obj_ty;
                const inner = self.freshTypeVar() catch unreachable;
                return self.makeNullableType(inner) catch unreachable;
            },
            .safe_method_call => |smc| {
                return trait_resolve.inferSafeMethodCall(self, smc, env);
            },
            .index => |idx| {
                const obj_ty = self.inferExpr(idx.object, env, null) catch return self.freshTypeVar() catch unreachable;
                _ = self.inferExpr(idx.index, env, null) catch {};
                const resolved = self.resolve(obj_ty);
                switch (resolved.*) {
                    .array_type => |at| return at.element_type,
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
                    .bit_and_assign, .bit_or_assign => {
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
                _ = try self.inferExpr(thr.expr, env, null);
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
                    std.mem.eql(u8, g.name, "Lazy"))
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
        self.checkCrossKindNameClashes(module);
        self.suppress_errors = true;
        for (module.declarations) |decl| {
            if (decl == .fun_decl) {
                self.predeclareFunction(decl.fun_decl, &env);
            }
        }
        self.suppress_errors = false;
        for (module.declarations) |decl| {
            self.checkDeclCollecting(decl, &env);
        }
        self.popLinearScope();
        self.recordModuleStructure(module, module_name);
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
            const params = self.arena.allocator().alloc(*Type, 2) catch return;
            params[0] = param;
            params[1] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.bool_type) catch return) catch return;
            const qvars = self.arena.allocator().alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eq", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eq");
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
        {
            const error_trait_ty = self.arena.allocator().create(Type) catch return;
            error_trait_ty.* = Type{ .trait_type = .{ .name = "Error", .type_args = &[_]*Type{} } };
            self.types.append(self.arena.allocator(), error_trait_ty) catch return;
            // method_names 包含所有方法；required_method_names 仅含必需方法（prefix）
            const error_method_names = self.arena.allocator().alloc([]const u8, 3) catch return;
            error_method_names[0] = "message";
            error_method_names[1] = "type_name";
            error_method_names[2] = "prefix";
            const error_required_names = self.arena.allocator().alloc([]const u8, 1) catch return;
            error_required_names[0] = "prefix";
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
            // prefix(self: Error) -> str
            {
                const self_type = self.arena.allocator().create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Error", .type_args = &[_]*Type{} } };
                self.types.append(self.arena.allocator(), self_type) catch return;
                const fn_params = self.arena.allocator().alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, self.makeType(.str_type) catch return) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                error_method_schemes.put(self.arena.allocator().dupe(u8, "prefix") catch return, scheme) catch return;
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
    fn unwrapAtomic(self: *TypeInferencer, ty: *Type) *Type {
        const resolved = self.resolve(ty);
        if (resolved.* == .generic_type) {
            if (std.mem.eql(u8, resolved.generic_type.name, "Atomic") and resolved.generic_type.args.len == 1) {
                return resolved.generic_type.args[0];
            }
        }
        return ty;
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
                const ret_ty = if (f.return_type) |ret_type|
                    self.typeFromAstWithParams(ret_type, &type_param_map) catch self.freshTypeVar() catch return
                else
                    self.freshTypeVar() catch return;
                const fn_ty = self.makeFnType(param_types, ret_ty) catch return;
                const qvars = self.arena.allocator().dupe(usize, type_param_ids.items) catch return;
                const fn_scheme = TypeScheme{ .quantified_vars = qvars, .ty = fn_ty };
                child_env.define(f.name, fn_scheme) catch return;
                const prev_fn_return = self.current_fn_return_type;
                if (f.return_type) |ret_type| {
                    self.current_fn_return_type = self.typeFromAstWithParams(ret_type, &type_param_map) catch null;
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
                const effective_body_ty = if (f.is_async and f.return_type == null)
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
                    if (!std.mem.eql(u8, f.name, "eq") and !std.mem.eql(u8, f.name, "compare") and !std.mem.eql(u8, f.name, "str")) {
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
                        const dup_or_builtin = self.isBuiltinName(td.name) or self.adt_types.contains(td.name);
                        if (self.isBuiltinName(td.name)) {
                            self.addErrorAt(.type_mismatch, td.location.line, td.location.column, "cannot redefine built-in name '{s}'", .{td.name});
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
                                if (!(env.defineOrReport(con.name, scheme) catch false)) {
                                    self.addErrorAt(.type_mismatch, con.location.line, con.location.column, "duplicate definition: '{s}' is already defined in this scope", .{con.name});
                                }
                            } else {
                                const ctor_ty = self.makeFnType(@constCast(ctor_field_types[ci]), ret_ty) catch return;
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                                if (!(env.defineOrReport(con.name, scheme) catch false)) {
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
                        if (self.isBuiltinName(nt.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{nt.name});
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
                        if (self.isBuiltinName(en.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{en.name});
                        } else if (!(env.defineOrReport(en.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{en.name});
                        }
                        if (self.isBuiltinName(en.name)) {} else if (self.adt_types.contains(en.name)) {
                            self.addError(.type_mismatch, "duplicate type definition: '{s}' is already defined", .{en.name});
                        } else {
                            const key = self.arena.allocator().dupe(u8, en.name) catch return;
                            const ctor_names = self.arena.allocator().alloc([]const u8, 1) catch return;
                            ctor_names[0] = en.name;
                            self.adt_types.put(key, AdtInfo{ .ty = error_adt, .constructor_names = ctor_names, .is_error_newtype = true }) catch return;
                            const mod_key = self.arena.allocator().dupe(u8, en.name) catch return;
                            const mod_val = self.arena.allocator().dupe(u8, self.current_module) catch return;
                            self.type_defining_modules.put(mod_key, mod_val) catch return;
                        }
                    },
                }
                if (td.methods.len > 0) {
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
                            if (method.body) |body| {
                                var method_env = TypeEnv.init(self.arena.allocator());
                                defer method_env.deinit();
                                for (method.params) |param| {
                                    const param_ty = if (param.type_annotation) |ty|
                                        self.typeFromAstWithParams(ty, &type_param_map) catch self.freshTypeVar() catch continue
                                    else
                                        self.freshTypeVar() catch continue;
                                    const scheme = TypeScheme{
                                        .quantified_vars = &[_]usize{},
                                        .ty = param_ty,
                                        .bounds = &[_]BoundInfo{},
                                    };
                                    method_env.define(param.name, scheme) catch continue;
                                }
                                const return_ty = if (method.return_type) |rt|
                                    self.typeFromAstWithParams(rt, &type_param_map) catch self.freshTypeVar() catch continue
                                else
                                    self.freshTypeVar() catch continue;
                                const old_return_type = self.current_fn_return_type;
                                defer self.current_fn_return_type = old_return_type;
                                self.current_fn_return_type = return_ty;
                                const body_ty = self.inferExpr(body, &method_env, return_ty) catch |err| {
                                    self.reportInferError(err, method.location);
                                    continue;
                                };
                                self.unify(body_ty, return_ty) catch |err| {
                                    self.reportInferError(err, method.location);
                                };
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
