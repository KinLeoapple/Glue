//! Glue 语言语义分析模块
//!
//! 实现 Hindley-Milner 类型推断，包括：
//! - 类型表示（基本类型、函数类型、ADT 类型、类型变量等）
//! - 统一算法（unification）
//! - 类型推断（Algorithm W）
//! - 类型检查和错误报告

const std = @import("std");
const ast = @import("ast");
const subtype_check = @import("subtype_check");
const trait_resolve = @import("trait_resolve");
const throw_check = @import("throw_check");

// ============================================================
// 类型表示
// ============================================================

/// 类型 ID（用于类型变量的唯一标识）
var next_type_id: usize = 0;

/// 类型节点
pub const Type = union(enum) {
    // 整数类型（方案 B：12 个独立 tag）
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

    // 浮点类型
    f32_type,
    f64_type,

    // 其他基本类型
    bool_type,
    str_type,
    char_type,
    null_type,
    unit_type,

    // 类型变量（用于推断）
    type_var: *TypeVar,

    // 函数类型：(params) -> return_type
    fn_type: struct {
        params: []*Type,
        return_type: *Type,
    },

    // 记录类型：(field: Type, ...)
    record_type: struct {
        fields: []FieldType,
    },

    // ADT 类型：TypeName<Args>
    adt_type: struct {
        name: []const u8,
        type_args: []*Type,
    },

    // 可空类型：T?
    nullable_type: *Type,

    // 泛型类型：Name<Args>
    generic_type: struct {
        name: []const u8,
        args: []*Type,
    },

    // 数组类型：T[N]（固定大小）或 T[]（动态大小）
    array_type: struct {
        element_type: *Type,
        size: ?u64, // null 表示动态数组
    },

    // Throw 类型：Throw<T, E>
    throw_type: struct {
        value_type: *Type,
        error_type: *Type,
    },

    // Trait 类型（用于 trait bound）
    trait_type: struct {
        name: []const u8,
        type_args: []*Type,
    },

    // 未知类型（推断失败时的回退）
    unknown_type,

    /// 判断是否为整数类型
    pub fn isIntType(self: Type) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type,
            .u8_type, .u16_type, .u32_type, .u64_type, .u128_type => true,
            else => false,
        };
    }

    /// 判断是否为浮点类型
    pub fn isFloatType(self: Type) bool {
        return switch (self) {
            .f32_type, .f64_type => true,
            else => false,
        };
    }

    /// 判断是否为数值类型（整数或浮点）
    pub fn isNumericType(self: Type) bool {
        return self.isIntType() or self.isFloatType();
    }

    pub fn format(self: Type, writer: anytype) !void {
        switch (self) {
            .i8_type => try writer.writeAll("i8"),
            .i16_type => try writer.writeAll("i16"),
            .i32_type => try writer.writeAll("i32"),
            .i64_type => try writer.writeAll("i64"),
            .i128_type => try writer.writeAll("i128"),
            .u8_type => try writer.writeAll("u8"),
            .u16_type => try writer.writeAll("u16"),
            .u32_type => try writer.writeAll("u32"),
            .u64_type => try writer.writeAll("u64"),
            .u128_type => try writer.writeAll("u128"),
            .f32_type => try writer.writeAll("f32"),
            .f64_type => try writer.writeAll("f64"),
            .bool_type => try writer.writeAll("bool"),
            .str_type => try writer.writeAll("str"),
            .char_type => try writer.writeAll("char"),
            .null_type => try writer.writeAll("Null"),
            .unit_type => try writer.writeAll("()"),
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
        }
    }

    /// 将类型格式化到 ArrayList（使用 ArrayList 的 print/appendSlice API）
    pub fn formatArrayList(self: Type, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        switch (self) {
            .i8_type => try buf.appendSlice(allocator, "i8"),
            .i16_type => try buf.appendSlice(allocator, "i16"),
            .i32_type => try buf.appendSlice(allocator, "i32"),
            .i64_type => try buf.appendSlice(allocator, "i64"),
            .i128_type => try buf.appendSlice(allocator, "i128"),
            .u8_type => try buf.appendSlice(allocator, "u8"),
            .u16_type => try buf.appendSlice(allocator, "u16"),
            .u32_type => try buf.appendSlice(allocator, "u32"),
            .u64_type => try buf.appendSlice(allocator, "u64"),
            .u128_type => try buf.appendSlice(allocator, "u128"),
            .f32_type => try buf.appendSlice(allocator, "f32"),
            .f64_type => try buf.appendSlice(allocator, "f64"),
            .bool_type => try buf.appendSlice(allocator, "bool"),
            .str_type => try buf.appendSlice(allocator, "str"),
            .char_type => try buf.appendSlice(allocator, "char"),
            .null_type => try buf.appendSlice(allocator, "Null"),
            .unit_type => try buf.appendSlice(allocator, "()"),
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
        }
    }
};

/// 类型变量
pub const TypeVar = struct {
    id: usize,
    bound: ?*Type = null,

    pub fn init() TypeVar {
        const id = next_type_id;
        next_type_id += 1;
        return TypeVar{ .id = id };
    }
};

/// 记录字段类型
pub const FieldType = struct {
    name: []const u8,
    ty: *Type,
};

/// ADT 信息（包含类型和构造器名称）
pub const AdtInfo = struct {
    ty: *Type,
    constructor_names: []const []const u8,
    /// 是否为 error newtype（文档 2.4.2: Name <: Error）
    is_error_newtype: bool = false,
    /// 类型参数名列表（如 List<T> 的 ["T"]）
    type_param_names: []const []const u8 = &[_][]const u8{},
    /// 定义该类型的模块名（用于 Orphan 检查）
    defining_module: []const u8 = "",
};

/// Impl 记录（用于 Overlapping 检查）
pub const ImplRecord = struct {
    trait_name: []const u8,
    type_name: []const u8,
    line: u32,
    column: u32,
};

/// Trait 信息（包含关联类型和方法名）
pub const TraitInfo = struct {
    ty: *Type,
    /// 关联类型名称列表（如 Container 的 ["Item"]）
    associated_type_names: []const []const u8 = &[_][]const u8{},
    /// 方法名称列表
    method_names: []const []const u8 = &[_][]const u8{},
    /// 方法类型方案（方法名 -> TypeScheme）
    method_schemes: std.StringHashMap(TypeScheme),
    /// 定义该 Trait 的模块名（用于 Orphan 检查）
    defining_module: []const u8 = "",
};

/// 类型方案（用于 let-polymorphism）
/// ∀a,b. T 表示类型 T 对类型变量 a, b 泛化
pub const TypeScheme = struct {
    /// 泛化的类型变量 ID 集合
    quantified_vars: []usize,
    /// 类型
    ty: *Type,
    /// 文档 2.7.3: Trait Bound 信息
    /// 每个 bound 包含 trait_name 和类型参数在 quantified_vars 中的索引
    /// 例如 `fun max<T>(a: T, b: T): T with Ord<T>` 的 bounds 为 [{Ord, 0}]
    bounds: []BoundInfo = &[_]BoundInfo{},
};

/// Trait Bound 信息（用于 TypeScheme）
pub const BoundInfo = struct {
    trait_name: []const u8,
    /// 类型参数在 quantified_vars 中的索引
    type_param_index: usize,
};

// ============================================================
// 类型环境
// ============================================================

/// 类型环境：变量名 -> 类型方案
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

    /// 定义绑定：同层级不允许重复定义
    /// 嵌套作用域（child_env）中允许遮蔽外层
    pub fn define(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !void {
        // 检查当前层级是否已有同名绑定
        if (self.bindings.contains(name)) {
            return error.DuplicateDefinition;
        }
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, scheme);
    }

    /// 定义绑定（容错版）：重复定义时返回 false 而非错误
    pub fn defineOrReport(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !bool {
        if (self.bindings.contains(name)) {
            return false;
        }
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, scheme);
        return true;
    }

    /// 重新定义绑定：允许覆盖已有定义（用于 impl 方法覆盖内建函数）
    /// 文档 2.7.1: impl 方法允许与内建函数同名（如 eq、compare），通过接收者类型分派
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

// ============================================================
// 类型推断错误
// ============================================================

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

/// 类型错误种类
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
};

/// 类型错误信息
pub const TypeError = struct {
    /// 错误种类
    kind: TypeErrorKind,
    /// 错误消息
    message: []const u8,
    /// 源码位置（行号，0-based）
    line: u32 = 0,
    /// 源码位置（列号，0-based）
    column: u32 = 0,
};

// ============================================================
// 类型推断器
// ============================================================

pub const TypeInferencer = struct {
    allocator: std.mem.Allocator,
    /// 类型变量存储（用于分配 TypeVar）
    type_vars: std.ArrayList(*TypeVar),
    /// 类型节点存储（用于分配 Type）
    types: std.ArrayList(*Type),
    /// ADT 类型注册表
    adt_types: std.StringHashMap(AdtInfo),
    /// Trait 类型注册表
    trait_types: std.StringHashMap(TraitInfo),
    /// 收集到的类型错误
    errors: std.ArrayList(TypeError),
    /// 当前函数的返回类型（用于 ? 传播检查）
    /// 文档 2.3.9: ? 操作符要求外层函数的返回类型兼容
    current_fn_return_type: ?*Type = null,
    /// 当前模块名（用于 Orphan 检查）
    current_module: []const u8 = "",
    /// Trait 定义模块记录（trait_name -> 定义它的模块名）
    trait_defining_modules: std.StringHashMap([]const u8),
    /// Type 定义模块记录（type_name -> 定义它的模块名）
    type_defining_modules: std.StringHashMap([]const u8),
    /// 已注册的 impl 记录（用于 Overlapping 检查）
    /// key: "trait_name::type_name"，value: impl 的位置信息
    registered_impls: std.StringHashMap(ImplRecord),
    /// 文档 2.7.3: 函数 Trait Bound 记录（函数名 -> bounds）
    /// 用于在调用点验证泛型 Trait Bound
    fn_bounds: std.StringHashMap([]ast.TraitBound),
    /// 内建函数/构造器名称集合（用于禁止用户遮蔽内建定义）
    builtin_names: std.StringHashMap(void),
    /// 用于 analyzeNullCheck 中翻转 is_non_null 的临时缓冲
    narrowing_buf: [4]NarrowingInfo = undefined,
    /// 当前正在推断的函数信息（用于多态递归检测）
    current_fn_info: ?CurrentFnInfo = null,

    /// 当前正在推断的函数信息
    const CurrentFnInfo = struct {
        /// 函数名
        name: []const u8,
        /// 函数是否有类型参数（泛型函数）
        has_type_params: bool,
        /// 函数是否有返回类型注解
        has_return_annotation: bool,
        /// 函数类型参数的 ID 集合（用于检测多态递归）
        type_param_ids: []const usize,
    };

    pub fn init(allocator: std.mem.Allocator) TypeInferencer {
        return TypeInferencer{
            .allocator = allocator,
            .type_vars = std.ArrayList(*TypeVar).empty,
            .types = std.ArrayList(*Type).empty,
            .adt_types = std.StringHashMap(AdtInfo).init(allocator),
            .trait_types = std.StringHashMap(TraitInfo).init(allocator),
            .errors = std.ArrayList(TypeError).empty,
            .current_fn_return_type = null,
            .current_module = "",
            .trait_defining_modules = std.StringHashMap([]const u8).init(allocator),
            .type_defining_modules = std.StringHashMap([]const u8).init(allocator),
            .registered_impls = std.StringHashMap(ImplRecord).init(allocator),
            .fn_bounds = std.StringHashMap([]ast.TraitBound).init(allocator),
            .builtin_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *TypeInferencer) void {
        for (self.type_vars.items) |tv| {
            self.allocator.destroy(tv);
        }
        self.type_vars.deinit(self.allocator);
        for (self.types.items) |t| {
            self.allocator.destroy(t);
        }
        self.types.deinit(self.allocator);
        {
            var iter = self.adt_types.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.constructor_names);
            }
            self.adt_types.deinit();
        }
        {
            var iter = self.trait_types.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.associated_type_names);
                self.allocator.free(entry.value_ptr.method_names);
            }
            self.trait_types.deinit();
        }
        {
            var iter = self.trait_defining_modules.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.trait_defining_modules.deinit();
        }
        {
            var iter = self.type_defining_modules.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.type_defining_modules.deinit();
        }
        {
            var iter = self.registered_impls.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.registered_impls.deinit();
        }
        self.fn_bounds.deinit();
        {
            var iter = self.builtin_names.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.builtin_names.deinit();
        }
        // 释放错误消息
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// 添加类型错误到错误列表
    pub fn addError(self: *TypeInferencer, kind: TypeErrorKind, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.errors.append(self.allocator, TypeError{
            .kind = kind,
            .message = message,
        }) catch {};
    }

    /// 添加带源码位置的类型错误
    pub fn addErrorAt(self: *TypeInferencer, kind: TypeErrorKind, line: u32, column: u32, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.errors.append(self.allocator, TypeError{
            .kind = kind,
            .message = message,
            .line = line,
            .column = column,
        }) catch {};
    }

    /// 重置推断器状态（保留 ADT/Trait 注册表，用于跨模块复用）
    pub fn resetForNextModule(self: *TypeInferencer) void {
        // 不清空 type_vars 和 types，因为 adt_types/trait_types 仍引用它们
        // 这些在 deinit 时统一释放
        // 释放错误消息
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.clearRetainingCapacity();
    }

    /// 创建新的类型变量
    /// 检查从 narrower 到 wider 是否是合法的 widening
    /// 文档 2.15: widening 转换始终合法
    /// i8 → i16 → i32 → i64 → i128 → f32 → f64
    /// u8 → u16 → u32 → u64 → u128
    /// i8 → f32 → f64, i16 → f32 → f64, i32 → f64, i64 → f64
    pub fn isWidening(self: *TypeInferencer, wider: *Type, narrower: *Type) bool {
        const w = self.resolve(wider);
        const n = self.resolve(narrower);

        // 定义数值类型的 "宽度" 等级
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
                    .f32_type => 10,
                    .f64_type => 11,
                    else => null,
                };
            }
        }.get;

        const w_rank = rank(w.*) orelse return false;
        const n_rank = rank(n.*) orelse return false;

        // widening: narrower 的等级 < wider 的等级
        return n_rank < w_rank;
    }

    pub fn freshTypeVar(self: *TypeInferencer) !*Type {
        const tv = try self.allocator.create(TypeVar);
        tv.* = TypeVar.init();
        try self.type_vars.append(self.allocator, tv);
        const t = try self.allocator.create(Type);
        t.* = Type{ .type_var = tv };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建基本类型（void tag，如 .i32_type, .bool_type 等）
    pub fn makeType(self: *TypeInferencer, comptime tag: @TypeOf(Type.i32_type)) !*Type {
        const t = try self.allocator.create(Type);
        t.* = tag;
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建数组类型：T[N] 或 T[]
    pub fn makeArrayType(self: *TypeInferencer, element_type: *Type, size: ?u64) !*Type {
        const t = try self.allocator.create(Type);
        t.* = Type{ .array_type = .{ .element_type = element_type, .size = size } };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建函数类型
    pub fn makeFnType(self: *TypeInferencer, params: []*Type, return_type: *Type) !*Type {
        const owned_params = try self.allocator.dupe(*Type, params);
        const t = try self.allocator.create(Type);
        t.* = Type{ .fn_type = .{ .params = owned_params, .return_type = return_type } };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建泛型类型（如 Spawn<T>, Channel<T>, Atomic<T> 等）
    pub fn makeGenericType(self: *TypeInferencer, name: []const u8, args: []const *Type) !*Type {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_args = try self.allocator.dupe(*Type, args);
        const t = try self.allocator.create(Type);
        t.* = Type{ .generic_type = .{ .name = owned_name, .args = owned_args } };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建可空类型
    pub fn makeNullableType(self: *TypeInferencer, inner: *Type) !*Type {
        const t = try self.allocator.create(Type);
        t.* = Type{ .nullable_type = inner };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建 ADT 类型
    pub fn makeAdtType(self: *TypeInferencer, name: []const u8, type_args: []*Type) !*Type {
        const owned_args = try self.allocator.dupe(*Type, type_args);
        const t = try self.allocator.create(Type);
        t.* = Type{ .adt_type = .{ .name = name, .type_args = owned_args } };
        try self.types.append(self.allocator, t);
        return t;
    }

    // ============================================================
    // 统一算法
    // ============================================================

    /// 统一两个类型
    pub fn unify(self: *TypeInferencer, t1: *Type, t2: *Type) SemaError!void {
        const resolved1 = self.resolve(t1);
        const resolved2 = self.resolve(t2);

        // 相同类型
        if (resolved1 == resolved2) return;

        switch (resolved1.*) {
            .type_var => |tv1| {
                // Occurs check：防止无限类型
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

        // 两个具体类型的统一
        const tag1 = std.meta.activeTag(resolved1.*);
        const tag2 = std.meta.activeTag(resolved2.*);

        // Phase 3: 子类型关系允许不同 tag 之间的兼容
        // - T <: T? (nullable_type)
        // - FileError <: Error (adt_type)
        // - Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
        if (tag1 != tag2) {
            // T <: T?：非 nullable 类型可以统一到 nullable 类型
            if (resolved2.* == .nullable_type) {
                try self.unify(resolved1, resolved2.nullable_type);
                return;
            }
            // Null <: T?
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
                // 文档 §2.12.1：记录宽度子类型
                // 字段更多的记录是字段更少的记录的子类型
                // (name: str, age: i32) <: (name: str)
                const smaller = if (rt1.fields.len <= rt2.fields.len) rt1 else rt2;
                const larger = if (rt1.fields.len <= rt2.fields.len) rt2 else rt1;
                // 较小记录的每个字段必须在较大记录中存在且类型兼容
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
                // Phase 3: Error 子类型（文档 §2.12.3）
                // FileError <: Error — 自定义错误类型是 Error 的子类型
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
                // Phase 3: Throw 子类型 — Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
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
                // Phase 3: Trait 结构化子类型（文档 §2.12.2）
                // 方法更多的模块是方法更少的 Trait 的子类型
                if (self.isSubtype(resolved1, resolved2)) {
                    return;
                }
                if (self.isSubtype(resolved2, resolved1)) {
                    return;
                }
                // 名字不同且无子类型关系
                if (!std.mem.eql(u8, resolved1.trait_type.name, resolved2.trait_type.name)) {
                    return error.TypeMismatch;
                }
            },
            else => {
                // 基本类型相同（tag1 == tag2 已保证）
            },
        }
    }

    /// 函数返回类型统一：允许 T 自动提升为 T? 或 Throw<T, E>
    /// 文档 2.3.9: ? 传播语义 — 函数体返回 T 时，若声明返回 T?，T 自动提升
    fn unifyReturnType(self: *TypeInferencer, declared: *Type, inferred: *Type) SemaError!void {
        return throw_check.unifyReturnType(self, declared, inferred);
    }

    /// 解析类型变量链，找到最终的类型
    pub fn resolve(self: *TypeInferencer, t: *Type) *Type {
        switch (t.*) {
            .type_var => |tv| {
                if (tv.bound) |bound| {
                    const resolved = self.resolve(bound);
                    tv.bound = resolved; // 路径压缩
                    return resolved;
                }
                return t;
            },
            else => return t,
        }
    }

    // ============================================================
    // 子类型检查（Phase 3: 文档 §2.12）
    // ============================================================

    /// 判断 sub 是否是 super 的子类型
    /// 文档 §2.12: Glue 使用三种子类型关系
    /// - 记录宽度子类型（§2.12.1）
    /// - Trait 结构化子类型（§2.12.2）
    /// - Error 子类型（§2.12.3）
    pub fn isSubtype(self: *TypeInferencer, sub: *Type, super: *Type) bool {
        const resolved_sub = self.resolve(sub);
        const resolved_super = self.resolve(super);

        // 相同类型
        if (resolved_sub == resolved_super) return true;

        // 1. Null <: T?（文档 §2.3.1: null 是所有 T? 的共享值）
        if (resolved_sub.* == .null_type and resolved_super.* == .nullable_type) return true;

        // 2. T <: T?（任何类型都是其可空版本的子类型）
        if (resolved_super.* == .nullable_type) {
            const inner = resolved_super.nullable_type;
            if (self.isSubtype(resolved_sub, inner)) return true;
        }

        // 3. 记录宽度子类型（文档 §2.12.1）
        //    (name: str, age: i32) <: (name: str)
        if (resolved_sub.* == .record_type and resolved_super.* == .record_type) {
            return self.isRecordSubtype(resolved_sub.record_type.fields, resolved_super.record_type.fields);
        }

        // 4. Error 子类型（文档 §2.12.3）
        //    FileError <: Error
        if (resolved_sub.* == .adt_type and resolved_super.* == .adt_type) {
            return self.isErrorSubtype(resolved_sub.adt_type.name, resolved_super.adt_type.name);
        }

        // 5. Throw 子类型：Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
        if (resolved_sub.* == .throw_type and resolved_super.* == .throw_type) {
            return self.isThrowSubtype(
                resolved_sub.throw_type.value_type,
                resolved_sub.throw_type.error_type,
                resolved_super.throw_type.value_type,
                resolved_super.throw_type.error_type,
            );
        }

        // 6. Trait 结构化子类型（文档 §2.12.2）
        //    方法更多的模块是方法更少的 Trait 的子类型
        if (resolved_sub.* == .trait_type and resolved_super.* == .trait_type) {
            return self.isTraitStructuralSubtype(resolved_sub.trait_type.name, resolved_super.trait_type.name);
        }

        return false;
    }

    /// 记录宽度子类型检查
    /// 文档 §2.12.1: 字段更多的记录是字段更少的记录的子类型
    fn isRecordSubtype(self: *TypeInferencer, sub_fields: []const FieldType, super_fields: []const FieldType) bool {
        _ = self;
        // 子类型（字段更多）必须包含父类型（字段更少）的所有字段
        for (super_fields) |super_field| {
            var found = false;
            for (sub_fields) |sub_field| {
                if (std.mem.eql(u8, super_field.name, sub_field.name)) {
                    // 字段类型必须相同（简化处理，递归子类型检查在 unify 中处理）
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Error 子类型检查
    /// 文档 §2.12.3: 自定义错误类型是 Error 的子类型
    fn isErrorSubtype(self: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
        // 检查 sub 是否是 Error 的子类型
        if (std.mem.eql(u8, super_name, "Error")) {
            if (self.adt_types.get(sub_name)) |info| {
                if (info.is_error_newtype) return true;
            }
        }
        return false;
    }

    /// Throw 子类型检查
    /// Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
    fn isThrowSubtype(self: *TypeInferencer, sub_val: *Type, sub_err: *Type, super_val: *Type, super_err: *Type) bool {
        // 值类型必须兼容
        if (!self.isSubtype(sub_val, super_val)) return false;
        // 错误类型必须是子类型关系
        if (!self.isSubtype(sub_err, super_err)) return false;
        return true;
    }

    /// Trait 结构化子类型检查
    /// 文档 §2.12.2: 方法更多的模块是方法更少的 Trait 的子类型
    fn isTraitStructuralSubtype(self: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
        const sub_info = self.trait_types.get(sub_name) orelse return false;
        const super_info = self.trait_types.get(super_name) orelse return false;

        // sub 必须包含 super 的所有方法
        for (super_info.method_names) |super_method| {
            var found = false;
            for (sub_info.method_names) |sub_method| {
                if (std.mem.eql(u8, super_method, sub_method)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Occurs check：检查类型变量 id 是否出现在类型 t 中
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

    // ============================================================
    // 泛化与实例化
    // ============================================================

    /// 泛化：将类型中的自由变量转换为量化变量
    pub fn generalize(self: *TypeInferencer, env: *TypeEnv, ty: *Type) !TypeScheme {
        _ = env;
        var free_vars = std.ArrayList(usize).empty;
        defer free_vars.deinit(self.allocator);
        self.collectFreeVars(ty, &free_vars);

        const quantified = try self.allocator.dupe(usize, free_vars.items);
        return TypeScheme{
            .quantified_vars = quantified,
            .ty = ty,
        };
    }

    /// 泛化（带 Trait Bound）：将类型中的自由变量转换为量化变量，并记录 bound 信息
    pub fn generalizeWithBounds(self: *TypeInferencer, env: *TypeEnv, ty: *Type, type_param_ids: []usize, bounds: []ast.TraitBound) !TypeScheme {
        _ = env;
        var free_vars = std.ArrayList(usize).empty;
        defer free_vars.deinit(self.allocator);
        self.collectFreeVars(ty, &free_vars);

        const quantified = try self.allocator.dupe(usize, free_vars.items);

        // 将 AST bounds 转换为 BoundInfo
        var bound_infos = std.ArrayList(BoundInfo).empty;
        defer bound_infos.deinit(self.allocator);
        for (bounds) |bound| {
            for (bound.type_args) |_| {
                // 查找类型参数名对应的量化变量索引
                for (type_param_ids, 0..) |param_id, param_idx| {
                    for (quantified, 0..) |qvar_id, qidx| {
                        if (qvar_id == param_id) {
                            bound_infos.append(self.allocator, BoundInfo{
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

        const owned_bounds = try self.allocator.dupe(BoundInfo, bound_infos.items);
        return TypeScheme{
            .quantified_vars = quantified,
            .ty = ty,
            .bounds = owned_bounds,
        };
    }

    /// 实例化：将类型方案中的量化变量替换为新的类型变量
    pub fn instantiate(self: *TypeInferencer, scheme: TypeScheme) !*Type {
        if (scheme.quantified_vars.len == 0) return scheme.ty;

        // 创建替换映射
        var subst = std.AutoHashMap(usize, *Type).init(self.allocator);
        defer subst.deinit();

        for (scheme.quantified_vars) |var_id| {
            const fresh = try self.freshTypeVar();
            try subst.put(var_id, fresh);
        }

        return self.applySubst(scheme.ty, subst);
    }

    fn collectFreeVars(self: *TypeInferencer, ty: *Type, free_vars: *std.ArrayList(usize)) void {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .type_var => |tv| {
                if (tv.bound == null) {
                    // 检查是否已存在
                    for (free_vars.items) |id| {
                        if (id == tv.id) return;
                    }
                    free_vars.append(self.allocator, tv.id) catch {};
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
                var new_params = try self.allocator.alloc(*Type, ft.params.len);
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
                const t = try self.allocator.create(Type);
                t.* = Type{ .throw_type = .{ .value_type = new_val, .error_type = new_err } };
                try self.types.append(self.allocator, t);
                return t;
            },
            .adt_type => |adt| {
                if (adt.type_args.len == 0) return resolved;
                var new_args = try self.allocator.alloc(*Type, adt.type_args.len);
                for (adt.type_args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                return self.makeAdtType(adt.name, new_args);
            },
            .trait_type => |tt| {
                if (tt.type_args.len == 0) return resolved;
                var new_args = try self.allocator.alloc(*Type, tt.type_args.len);
                for (tt.type_args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .trait_type = .{ .name = tt.name, .type_args = new_args } };
                try self.types.append(self.allocator, t);
                return t;
            },
            .record_type => |rt| {
                var new_fields = try self.allocator.alloc(FieldType, rt.fields.len);
                for (rt.fields, 0..) |f, i| {
                    new_fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.applySubst(f.ty, subst),
                    };
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .record_type = .{ .fields = new_fields } };
                try self.types.append(self.allocator, t);
                return t;
            },
            .array_type => |at| {
                const new_elem = try self.applySubst(at.element_type, subst);
                return self.makeArrayType(new_elem, at.size);
            },
            .generic_type => |gt| {
                if (gt.args.len == 0) return resolved;
                var new_args = try self.allocator.alloc(*Type, gt.args.len);
                for (gt.args, 0..) |arg, i| {
                    new_args[i] = try self.applySubst(arg, subst);
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .generic_type = .{ .name = gt.name, .args = new_args } };
                try self.types.append(self.allocator, t);
                return t;
            },
            else => return resolved,
        }
    }

    // ============================================================
    // Nullable 类型收窄（flow typing）
    // ============================================================

    /// 收窄信息：变量名 + 是否为非空
    const NarrowingInfo = struct {
        name: []const u8,
        is_non_null: bool,
    };

    /// 分析条件表达式中的 null 检查
    /// 返回收窄信息列表：
    /// - `x != null` → [("x", true)]  （then 分支中 x 为非空）
    /// - `x == null` → [("x", false)] （else 分支中 x 为非空）
    /// - 复合条件 `&&` → 合并两侧的收窄信息
    fn analyzeNullCheck(self: *TypeInferencer, cond: *const ast.Expr) []const NarrowingInfo {
        switch (cond.*) {
            .binary => |bin| {
                switch (bin.op) {
                    .not_eq => {
                        // expr != null → then 分支中 expr 非空
                        if (self.isNullLiteral(bin.right)) {
                            if (self.getIdentifierName(bin.left)) |name| {
                                return &[_]NarrowingInfo{.{ .name = name, .is_non_null = true }};
                            }
                        }
                        // null != expr → 同上
                        if (self.isNullLiteral(bin.left)) {
                            if (self.getIdentifierName(bin.right)) |name| {
                                return &[_]NarrowingInfo{.{ .name = name, .is_non_null = true }};
                            }
                        }
                    },
                    .eq => {
                        // expr == null → else 分支中 expr 非空
                        if (self.isNullLiteral(bin.right)) {
                            if (self.getIdentifierName(bin.left)) |name| {
                                return &[_]NarrowingInfo{.{ .name = name, .is_non_null = false }};
                            }
                        }
                        // null == expr → 同上
                        if (self.isNullLiteral(bin.left)) {
                            if (self.getIdentifierName(bin.right)) |name| {
                                return &[_]NarrowingInfo{.{ .name = name, .is_non_null = false }};
                            }
                        }
                    },
                    .and_op => {
                        // a && b → 合并两侧的收窄信息
                        const left_narrowings = self.analyzeNullCheck(bin.left);
                        const right_narrowings = self.analyzeNullCheck(bin.right);
                        // 简单合并：左侧 + 右侧
                        // 注意：这返回的是栈上临时切片，仅在当前调用栈有效
                        // 对于 && 短路，两侧的收窄在 then 分支都成立
                        if (left_narrowings.len == 0) return right_narrowings;
                        if (right_narrowings.len == 0) return left_narrowings;
                        // 两边都有收窄信息时，只返回左侧（简化处理，避免动态分配）
                        return left_narrowings;
                    },
                    else => {},
                }
            },
            .unary => |un| {
                switch (un.op) {
                    .not => {
                        // !(x == null) → then 分支中 x 非空，等价于 x != null
                        const inner = self.analyzeNullCheck(un.operand);
                        if (inner.len == 1) {
                            // 翻转 is_non_null
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

    /// 检查表达式是否为 null 字面量
    fn isNullLiteral(self: *TypeInferencer, expr: *const ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .null_literal => true,
            .identifier => |id| std.mem.eql(u8, id.name, "null"),
            else => false,
        };
    }

    /// 提取标识符名称（仅当表达式为简单标识符时）
    fn getIdentifierName(self: *TypeInferencer, expr: *const ast.Expr) ?[]const u8 {
        _ = self;
        return switch (expr.*) {
            .identifier => |id| id.name,
            else => null,
        };
    }

    /// 在子环境中应用收窄：将 T? 绑定收窄为 T
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

    /// Try to unify two types with auto-widening support
    /// - T and T? → unify T with inner, return T?
    /// - T? and T → unify inner with T, return T?
    /// - T and Throw<T', E> → unify T with T', return Throw<T', E>
    /// - Integer widening: i32 → i64, i32 → f64, etc.
    /// Falls back to regular unify if no widening applies
    fn tryWidenUnify(self: *TypeInferencer, t1: *Type, t2: *Type) SemaError!*Type {
        return throw_check.tryWidenUnify(self, t1, t2);
    }

    // ============================================================
    // 类型推断（Algorithm W）
    // ============================================================

    /// 推断表达式的类型
    pub fn inferExpr(self: *TypeInferencer, expr: *const ast.Expr, env: *TypeEnv) SemaError!*Type {
        return switch (expr.*) {
            .int_literal => self.makeType(.i32_type),
            .float_literal => self.makeType(.f64_type),
            .bool_literal => self.makeType(.bool_type),
            .char_literal => self.makeType(.char_type),
            .string_literal => self.makeType(.str_type),
            .null_literal => {
                // null 的类型由上下文决定：统一为 T? 时自动收窄
                const tv = try self.freshTypeVar();
                return self.makeNullableType(tv);
            },
            .unit_literal => self.makeType(.unit_type),

            .identifier => |id| {
                if (env.lookup(id.name)) |scheme| {
                    // 文档 2.10: 多态递归函数必须提供类型标注
                    // 当泛型函数递归调用自身时，如果没有返回类型注解，
                    // 不允许实例化类型参数（否则会产生无限类型）
                    if (self.current_fn_info) |fn_info| {
                        if (std.mem.eql(u8, id.name, fn_info.name) and
                            fn_info.has_type_params and
                            !fn_info.has_return_annotation and
                            scheme.quantified_vars.len > 0)
                        {
                            // 多态递归检测：泛型函数无返回类型标注时，
                            // 递归调用不允许实例化类型参数
                            // 报错并要求添加类型标注
                            self.addErrorAt(.recursive_type, id.location.line, id.location.column, "polymorphic recursive function '{s}' requires an explicit return type annotation", .{id.name});
                            // 不实例化，直接返回类型（避免无限类型）
                            return scheme.ty;
                        }
                    }
                    const ty = try self.instantiate(scheme);
                    return ty;
                }
                self.addErrorAt(.unbound_variable, id.location.line, id.location.column, "undefined variable '{s}'", .{id.name});
                return self.freshTypeVar() catch error.OutOfMemory;
            },

            .binary => |bin| {
                var left_ty = try self.inferExpr(bin.left, env);
                var right_ty = try self.inferExpr(bin.right, env);

                // 文档 §3.4.2: Atomic<T> 透明操作 — 算术/比较运算时自动解包
                left_ty = self.unwrapAtomic(left_ty);
                right_ty = self.unwrapAtomic(right_ty);

                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        try self.unify(left_ty, right_ty);
                        return left_ty;
                    },
                    .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq => {
                        try self.unify(left_ty, right_ty);
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
                    .range, .range_inclusive => {
                        try self.unify(left_ty, try self.makeType(.i32_type));
                        try self.unify(right_ty, try self.makeType(.i32_type));
                        // Range 类型不是独立类型，元素类型由推断决定
                        return self.makeType(.i32_type);
                    },
                    .elvis => {
                        // ?? 运算符：左操作数为 T?，右操作数为 T
                        return left_ty;
                    },
                }
            },

            .unary => |un| {
                const operand_ty = try self.inferExpr(un.operand, env);
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
                var param_types = try self.allocator.alloc(*Type, lam.params.len);
                for (lam.params, 0..) |param, i| {
                    const param_ty = if (param.type_annotation) |ta|
                        try self.typeFromAst(ta)
                    else
                        try self.freshTypeVar();
                    param_types[i] = param_ty;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                    try child_env.define(param.name, scheme);
                }

                const body_ty = switch (lam.body) {
                    .block => |body| try self.inferExpr(body, child_env),
                    .expression => |e| try self.inferExpr(e, child_env),
                };

                return self.makeFnType(param_types, body_ty);
            },

            .call => |c| {
                const callee_ty = try self.inferExpr(c.callee, env);
                const ret_ty = try self.freshTypeVar();
                var arg_types = try self.allocator.alloc(*Type, c.arguments.len);
                for (c.arguments, 0..) |arg, i| {
                    arg_types[i] = try self.inferExpr(arg, env);
                }
                const expected_fn_ty = try self.makeFnType(arg_types, ret_ty);
                // 先尝试直接统一
                if (self.unify(callee_ty, expected_fn_ty)) {
                    // 文档 2.7.3: 调用点 Trait Bound 延迟检查
                    self.checkCallSiteTraitBound(c.callee, c.location);
                    return ret_ty;
                } else |_| {
                    // 尝试参数自动提升：T 传给 T? 参数，T 传给 Throw<T, E> 参数
                    const resolved_callee = self.resolve(callee_ty);
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
                                    // 文档 2.7.3: 调用点 Trait Bound 延迟检查
                                    self.checkCallSiteTraitBound(c.callee, c.location);
                                    return ft.return_type;
                                }
                            }
                        },
                        else => {},
                    }
                    return error.TypeMismatch;
                }
            },

            .if_expr => |ie| {
                const cond_ty = try self.inferExpr(ie.condition, env);
                try self.unify(cond_ty, try self.makeType(.bool_type));

                // 分析条件中的 null 检查，获取收窄信息
                const narrowings = self.analyzeNullCheck(ie.condition);

                // Then 分支：应用 is_non_null == true 的收窄
                const then_env = try env.createChild();
                self.applyNarrowing(then_env, narrowings, true);
                const then_ty = try self.inferExpr(ie.then_branch, then_env);

                if (ie.else_branch) |else_br| {
                    // Else 分支：应用 is_non_null == false 的收窄（即条件取反时非空）
                    const else_env = try env.createChild();
                    self.applyNarrowing(else_env, narrowings, false);
                    const else_ty = try self.inferExpr(else_br, else_env);
                    const unified = try self.tryWidenUnify(then_ty, else_ty);
                    return unified;
                }
                return then_ty;
            },

            .block => |blk| {
                const child_env = try env.createChild();
                var result_ty = try self.makeType(.unit_type);
                for (blk.statements) |stmt| {
                    _ = try self.inferStmt(stmt, child_env);
                }
                if (blk.trailing_expr) |te| {
                    result_ty = try self.inferExpr(te, child_env);
                }
                return result_ty;
            },

            .match => |m| {
                const scrutinee_ty = try self.inferExpr(m.scrutinee, env);
                const resolved_scrutinee = self.resolve(scrutinee_ty);

                // 如果 scrutinee 是 T?，提取内部类型 T 用于非 null 分支的收窄
                const nullable_inner: ?*Type = switch (resolved_scrutinee.*) {
                    .nullable_type => |inner| inner,
                    else => null,
                };

                var result_ty: ?*Type = null;
                for (m.arms) |arm| {
                    const child_env = try env.createChild();

                    // 判断当前 arm 是否匹配 null
                    const arm_matches_null = self.patternCoversNull(arm.pattern);

                    // 如果 scrutinee 是 T? 且当前 arm 不匹配 null，
                    // 则变量绑定应收窄为 T（而非 T?）
                    const pattern_ty: *Type = if (nullable_inner) |inner|
                        if (arm_matches_null) scrutinee_ty else inner
                    else
                        scrutinee_ty;

                    try self.inferPattern(arm.pattern, pattern_ty, child_env);
                    const body_ty = try self.inferExpr(arm.body, child_env);
                    if (result_ty) |rt| {
                        const unified = try self.tryWidenUnify(rt, body_ty);
                        result_ty = unified;
                    } else {
                        result_ty = body_ty;
                    }
                }
                self.checkExhaustiveness(scrutinee_ty, m.arms, m.location);
                return result_ty orelse self.makeType(.unit_type);
            },

            .array_literal => |al| {
                if (al.elements.len == 0) return self.freshTypeVar() catch unreachable;
                const first_ty = self.inferExpr(al.elements[0], env) catch return self.freshTypeVar() catch unreachable;
                // Unify all element types with the first
                for (al.elements[1..]) |elem| {
                    const elem_ty = self.inferExpr(elem, env) catch continue;
                    self.unify(first_ty, elem_ty) catch {};
                }
                return self.makeArrayType(first_ty, null) catch unreachable;
            },

            .record_literal => |rl| {
                var fields = try self.allocator.alloc(FieldType, rl.fields.len);
                for (rl.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.inferExpr(f.value, env),
                    };
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .record_type = .{ .fields = fields } };
                try self.types.append(self.allocator, t);
                return t;
            },

            .record_extend => |re| {
                // Phase 3: 记录扩展/更新的类型推断
                // (...base, field: val) 的类型 = base 的字段类型 + updates 的字段类型
                const base_ty = self.inferExpr(re.base, env) catch return self.freshTypeVar() catch unreachable;
                const resolved_base = self.resolve(base_ty);

                switch (resolved_base.*) {
                    .record_type => |rt| {
                        // 收集 base 的字段
                        var all_fields = std.ArrayList(FieldType).empty;
                        for (rt.fields) |f| {
                            try all_fields.append(self.allocator, f);
                        }
                        // 应用 updates（覆盖或新增）
                        for (re.updates) |update| {
                            const update_ty = try self.inferExpr(update.value, env);
                            // 检查是否覆盖已有字段
                            var found = false;
                            for (all_fields.items, 0..) |*f, i| {
                                if (std.mem.eql(u8, f.name, update.name)) {
                                    all_fields.items[i].ty = update_ty;
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try all_fields.append(self.allocator, FieldType{
                                    .name = update.name,
                                    .ty = update_ty,
                                });
                            }
                        }
                        const t = try self.allocator.create(Type);
                        t.* = Type{ .record_type = .{ .fields = try all_fields.toOwnedSlice(self.allocator) } };
                        try self.types.append(self.allocator, t);
                        return t;
                    },
                    else => {
                        self.addErrorAt(.type_mismatch, re.location.line, re.location.column, "record extend requires record type, got {}", .{resolved_base.*});
                        return self.freshTypeVar() catch unreachable;
                    },
                }
            },

            .field_access => |fa| {
                const obj_ty = self.inferExpr(fa.object, env) catch return self.freshTypeVar() catch unreachable;
                const resolved = self.resolve(obj_ty);
                switch (resolved.*) {
                    .record_type => |rt| {
                        for (rt.fields) |field| {
                            if (std.mem.eql(u8, field.name, fa.field)) {
                                return field.ty;
                            }
                        }
                        self.addErrorAt(.type_mismatch, fa.location.line, fa.location.column, "record type has no field named '{s}'", .{fa.field});
                        return self.freshTypeVar() catch unreachable;
                    },
                    else => return self.freshTypeVar() catch unreachable,
                }
            },

            .method_call => |mc| {
                return trait_resolve.inferMethodCall(self, mc, env);
            },

            .propagate => |prop| {
                const inner_ty = try self.inferExpr(prop.expr, env);
                const resolved_inner = self.resolve(inner_ty);
                return throw_check.checkPropagate(self, resolved_inner, inner_ty, self.current_fn_return_type, prop.location);
            },

            .non_null_assert => |nna| {
                return self.inferExpr(nna.expr, env);
            },

            .safe_access => |sa| {
                const obj_ty = self.inferExpr(sa.object, env) catch return self.freshTypeVar() catch unreachable;
                // For now, return a nullable type variable
                _ = obj_ty;
                const inner = self.freshTypeVar() catch unreachable;
                return self.makeNullableType(inner) catch unreachable;
            },

            .safe_method_call => |smc| {
                return trait_resolve.inferSafeMethodCall(self, smc, env);
            },

            .index => |idx| {
                const obj_ty = self.inferExpr(idx.object, env) catch return self.freshTypeVar() catch unreachable;
                _ = self.inferExpr(idx.index, env) catch {};
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
                _ = try self.inferExpr(tc.expr, env);
                return self.typeFromAst(tc.target_type);
            },

            .assignment_expr => |ae| {
                const val_ty = try self.inferExpr(ae.value, env);
                return val_ty;
            },

            // 尚未实现的表达式类型 — Phase 4 并发原语类型推断
            .spawn => |sp| {
                const body_ty = try self.inferExpr(sp.body, env);
                // 返回 Spawn<T>，其中 T = body 类型
                return self.makeGenericType("Spawn", &[_]*Type{body_ty});
            },
            .atomic_expr => |ae| {
                const val_ty = try self.inferExpr(ae.value, env);
                // 返回 Atomic<T>，其中 T = 值类型
                return self.makeGenericType("Atomic", &[_]*Type{val_ty});
            },
            .select => |sel| {
                // select 返回第一个就绪分支体的类型
                if (sel.arms.len > 0) {
                    switch (sel.arms[0]) {
                        .receive => |recv_arm| return try self.inferExpr(recv_arm.body, env),
                        .timeout => |timeout_arm| return try self.inferExpr(timeout_arm.body, env),
                    }
                }
                return self.freshTypeVar();
            },
            .lazy, .monad_comprehension, .inline_trait_value => {
                return self.freshTypeVar();
            },
        };
    }

    /// 推断语句的类型
    pub fn inferStmt(self: *TypeInferencer, stmt: *const ast.Stmt, env: *TypeEnv) SemaError!?*Type {
        return switch (stmt.*) {
            .val_decl => |vd| {
                if (self.isBuiltinName(vd.name)) {
                    self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{vd.name});
                } else {
                    // 如果值是 lambda，先注册函数类型到环境以支持递归调用
                    if (vd.value.* == .lambda) {
                        const lam = vd.value.*.lambda;
                        const child_env = try env.createChild();
                        var param_types = try self.allocator.alloc(*Type, lam.params.len);
                        for (lam.params, 0..) |param, i| {
                            const param_ty = if (param.type_annotation) |ta|
                                try self.typeFromAst(ta)
                            else
                                try self.freshTypeVar();
                            param_types[i] = param_ty;
                            const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                            try child_env.define(param.name, scheme);
                        }
                        const ret_ty = if (vd.type_annotation) |ta|
                            try self.typeFromAst(ta)
                        else
                            try self.freshTypeVar();
                        const fn_ty = try self.makeFnType(param_types, ret_ty);
                        // 先注册到环境（支持递归调用）
                        const fn_scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                        try child_env.define(vd.name, fn_scheme);

                        // 推断 lambda 体
                        const body_ty = switch (lam.body) {
                            .block => |body| try self.inferExpr(body, child_env),
                            .expression => |e| try self.inferExpr(e, child_env),
                        };
                        // 统一返回类型
                        _ = self.tryWidenUnify(ret_ty, body_ty) catch {
                            self.addErrorAt(.type_mismatch, vd.location.line, vd.location.column, "type mismatch in val declaration: annotation does not match inferred type", .{});
                        };

                        // 注册到外层环境
                        const final_scheme = try self.generalize(env, fn_ty);
                        if (!(try env.defineOrReport(vd.name, final_scheme))) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                        }
                    } else {
                        const val_ty = try self.inferExpr(vd.value, env);
                        // 验证类型注解
                        if (vd.type_annotation) |ta| {
                            const annot_ty = self.typeFromAstWithParams(ta, null) catch null;
                            if (annot_ty) |at| {
                                _ = self.tryWidenUnify(at, val_ty) catch {
                                    self.addErrorAt(.type_mismatch, vd.location.line, vd.location.column, "type mismatch in val declaration", .{});
                                };
                            }
                        }
                        const scheme = try self.generalize(env, val_ty);
                        if (!(try env.defineOrReport(vd.name, scheme))) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                        }
                    }
                }
                return null;
            },
            .var_decl => |vd| {
                if (self.isBuiltinName(vd.name)) {
                    self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{vd.name});
                } else {
                    const val_ty = try self.inferExpr(vd.value, env);
                    // 验证类型注解
                    if (vd.type_annotation) |ta| {
                        const annot_ty = self.typeFromAstWithParams(ta, null) catch null;
                        if (annot_ty) |at| {
                            _ = self.tryWidenUnify(at, val_ty) catch {
                                self.addErrorAt(.type_mismatch, vd.location.line, vd.location.column, "type mismatch in var declaration", .{});
                            };
                        }
                    }
                    const scheme = try self.generalize(env, val_ty);
                    if (!(try env.defineOrReport(vd.name, scheme))) {
                        self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{vd.name});
                    }
                }
                return null;
            },
            .assignment => |asgn| {
                _ = try self.inferExpr(asgn.value, env);
                return null;
            },
            .field_assignment => |fa| {
                _ = try self.inferExpr(fa.value, env);
                return null;
            },
            .expression => |es| {
                return self.inferExpr(es.expr, env);
            },
            .return_stmt => |ret| {
                if (ret.value) |v| {
                    return self.inferExpr(v, env);
                }
                return self.makeType(.unit_type);
            },
            .defer_stmt => {
                return null;
            },
            .throw_stmt => |thr| {
                _ = try self.inferExpr(thr.expr, env);
                return null;
            },
            .break_stmt, .continue_stmt => {
                return null;
            },
            .for_stmt => |fs| {
                const iterable_ty = try self.inferExpr(fs.iterable, env);
                const child_env = try env.createChild();
                // 文档 2.7.8: for item in list 要求 list 的类型满足 Iterable<T>
                // 推断 item 的类型
                const item_ty = try self.freshTypeVar();

                // 验证可迭代类型：检查是否有 Iterable<T> 的 impl 或是内建可迭代类型
                const resolved_iterable = self.resolve(iterable_ty);
                const is_builtin_iterable = switch (resolved_iterable.*) {
                    .array_type => true,
                    .str_type => true,
                    else => false,
                };
                if (!is_builtin_iterable) {
                    // 检查是否有 Iterable<T> 的 impl
                    const iterable_type_name: ?[]const u8 = switch (resolved_iterable.*) {
                        .adt_type => |adt| adt.name,
                        .generic_type => |g| g.name,
                        else => null,
                    };
                    if (iterable_type_name) |tn| {
                        const impl_key = std.fmt.allocPrint(self.allocator, "Iterable::{s}", .{tn}) catch "";
                        defer {
                            if (impl_key.len > 0) self.allocator.free(impl_key);
                        }
                        if (impl_key.len > 0 and !self.registered_impls.contains(impl_key)) {
                            // 没有找到 Iterable 的 impl，但不阻止推断
                            // （运行时会尝试 callMethod 分派）
                        }
                    }
                }

                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = item_ty };
                try child_env.define(fs.name, scheme);
                _ = try self.inferExpr(fs.body, child_env);
                return null;
            },
            .while_stmt => |ws| {
                const cond_ty = try self.inferExpr(ws.condition, env);
                try self.unify(cond_ty, try self.makeType(.bool_type));
                _ = try self.inferExpr(ws.body, env);
                return null;
            },
            .loop_stmt => |ls| {
                _ = try self.inferExpr(ls.body, env);
                return null;
            },
        };
    }

    /// 推断模式类型，在环境中绑定变量
    pub fn inferPattern(self: *TypeInferencer, pat: *const ast.Pattern, expected_ty: *Type, env: *TypeEnv) SemaError!void {
        switch (pat.*) {
            .wildcard => {},
            .literal => {},
            .variable => |v| {
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = expected_ty };
                try env.define(v.name, scheme);
            },
            .constructor => |con| {
                // ADT 构造器模式
                for (con.patterns) |sub_pat| {
                    const sub_ty = try self.freshTypeVar();
                    try self.inferPattern(sub_pat, sub_ty, env);
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
            },
        }
    }

    /// 从 AST 类型注解创建类型
    pub fn typeFromAst(self: *TypeInferencer, type_node: *const ast.TypeNode) SemaError!*Type {
        return self.typeFromAstWithParams(type_node, null);
    }

    /// 从 AST 类型注解创建类型，支持类型参数映射
    /// type_param_map: 类型参数名 -> 类型变量（如 T -> '_0），用于泛型 ADT 构造器
    pub fn typeFromAstWithParams(self: *TypeInferencer, type_node: *const ast.TypeNode, type_param_map: ?*const std.StringHashMap(*Type)) SemaError!*Type {
        switch (type_node.*) {
            .named => |n| {
                // 整数类型映射
                if (std.mem.eql(u8, n.name, "i8")) return self.makeType(.i8_type);
                if (std.mem.eql(u8, n.name, "i16")) return self.makeType(.i16_type);
                if (std.mem.eql(u8, n.name, "i32")) return self.makeType(.i32_type);
                if (std.mem.eql(u8, n.name, "i64")) return self.makeType(.i64_type);
                if (std.mem.eql(u8, n.name, "i128")) return self.makeType(.i128_type);
                if (std.mem.eql(u8, n.name, "u8")) return self.makeType(.u8_type);
                if (std.mem.eql(u8, n.name, "u16")) return self.makeType(.u16_type);
                if (std.mem.eql(u8, n.name, "u32")) return self.makeType(.u32_type);
                if (std.mem.eql(u8, n.name, "u64")) return self.makeType(.u64_type);
                if (std.mem.eql(u8, n.name, "u128")) return self.makeType(.u128_type);
                // 浮点类型映射
                if (std.mem.eql(u8, n.name, "f32")) return self.makeType(.f32_type);
                if (std.mem.eql(u8, n.name, "f64")) return self.makeType(.f64_type);
                // 其他基本类型
                if (std.mem.eql(u8, n.name, "bool")) return self.makeType(.bool_type);
                if (std.mem.eql(u8, n.name, "str")) return self.makeType(.str_type);
                if (std.mem.eql(u8, n.name, "char")) return self.makeType(.char_type);
                // 查找类型参数映射（泛型 ADT 构造器中的 T 等）
                if (type_param_map) |tpm| {
                    if (tpm.get(n.name)) |ty| {
                        return ty;
                    }
                }
                // 查找 ADT 类型
                if (self.adt_types.get(n.name)) |adt_info| {
                    return adt_info.ty;
                }
                // 未知命名类型，返回 ADT 类型占位
                return self.makeAdtType(n.name, &[_]*Type{});
            },
            .generic => |g| {
                var args = try self.allocator.alloc(*Type, g.args.len);
                for (g.args, 0..) |arg, i| {
                    args[i] = try self.typeFromAstWithParams(arg, type_param_map);
                }
                if (std.mem.eql(u8, g.name, "Throw")) {
                    if (args.len == 2) {
                        const t = try self.allocator.create(Type);
                        t.* = Type{ .throw_type = .{ .value_type = args[0], .error_type = args[1] } };
                        try self.types.append(self.allocator, t);
                        return t;
                    }
                }
                // 检查是否为已注册的泛型 ADT
                if (self.adt_types.get(g.name)) |adt_info| {
                    if (adt_info.type_param_names.len > 0) {
                        return self.makeAdtType(g.name, args);
                    }
                }
                self.addError(.type_mismatch, "undefined type '{s}'", .{g.name});
                return self.makeAdtType(g.name, args);
            },
            .nullable => |n| {
                const inner = try self.typeFromAstWithParams(n.inner, type_param_map);
                return self.makeNullableType(inner);
            },
            .function => |f| {
                var params = try self.allocator.alloc(*Type, f.params.len);
                for (f.params, 0..) |p, i| {
                    params[i] = try self.typeFromAstWithParams(p, type_param_map);
                }
                const ret = try self.typeFromAstWithParams(f.return_type, type_param_map);
                return self.makeFnType(params, ret);
            },
            .record => |r| {
                // Empty record type () = unit type
                if (r.fields.len == 0) return self.makeType(.unit_type);
                var fields = try self.allocator.alloc(FieldType, r.fields.len);
                for (r.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.typeFromAstWithParams(f.ty, type_param_map),
                    };
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .record_type = .{ .fields = fields } };
                try self.types.append(self.allocator, t);
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

    // ============================================================
    // 模块级类型检查
    // ============================================================

    /// 对模块进行类型检查，收集错误而非提前返回
    /// 文档 7.1: 先检查后求值 — 类型推断错误报告给用户但不阻止求值
    pub fn checkModule(self: *TypeInferencer, module: *const ast.Module) void {
        self.checkModuleWithName(module, module.name);
    }

    /// 带模块名的类型检查（用于 Orphan 检查）
    pub fn checkModuleWithName(self: *TypeInferencer, module: *const ast.Module, module_name: []const u8) void {
        // 重置推断器状态（保留 ADT/Trait 注册表）
        self.resetForNextModule();
        self.current_module = module_name;

        var env = TypeEnv.init(self.allocator);
        defer env.deinit();

        // 注册内建函数到类型环境
        self.registerBuiltins(&env);

        for (module.declarations) |decl| {
            self.checkDeclCollecting(decl, &env);
        }
    }

    /// 注册内建函数到类型环境，与求值器的 registerBuiltins 对应
    /// 同时将内建名称注册到 builtin_names，禁止用户遮蔽
    fn registerBuiltins(self: *TypeInferencer, env: *TypeEnv) void {
        // 内建函数使用 let 多态：quantified_vars 包含类型变量 ID
        // 这样每次使用 println 时都会实例化一个新的类型变量

        // println : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("println", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("println");
        }

        // print : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("print", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("print");
        }

        // eprintln : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprintln", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eprintln");
        }

        // eprint : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprint", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eprint");
        }

        // Panic : (String) -> !
        {
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = self.makeType(.str_type) catch return;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            env.define("Panic", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Panic");
        }

        // eq : forall a. (a, a) -> bool
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 2) catch return;
            params[0] = param;
            params[1] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.bool_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eq", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("eq");
        }

        // string : forall a. (a) -> String
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.str_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("str", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("str");
        }

        // Error ADT 类型（用于 Throw<T, Error> 中的 Error 类型参数）
        const error_adt_ty = self.makeAdtType("Error", &[_]*Type{}) catch return;
        const error_adt_key = self.allocator.dupe(u8, "Error") catch return;
        self.adt_types.put(error_adt_key, AdtInfo{ .ty = error_adt_ty, .constructor_names = &[_][]const u8{} }) catch return;

        // Error : forall a. (String) -> Throw<a, Error>
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = self.makeType(.str_type) catch return;
            const throw_ty = self.allocator.create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.allocator, throw_ty) catch return;
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Error", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Error");
        }

        // Ok : forall a. (a) -> Throw<a, Error>
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = val_ty;
            const throw_ty = self.allocator.create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.allocator, throw_ty) catch return;
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Ok", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("Ok");
        }

        // scan : () -> str?
        {
            const params = self.allocator.alloc(*Type, 0) catch return;
            const ret_ty = self.makeNullableType(self.makeType(.str_type) catch return) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            env.define("scan", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("scan");
        }

        // scanln : () -> str?
        {
            const params = self.allocator.alloc(*Type, 0) catch return;
            const ret_ty = self.makeNullableType(self.makeType(.str_type) catch return) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            env.define("scanln", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch return;
            self.registerBuiltinName("scanln");
        }

        // 数值类型转换函数：Type(value) 显式转换
        // 文档 2.15: i8(), i16(), i32(), i64(), i128(), u8(), u16(), u32(), u64(), u128(), f32(), f64()
        // 签名: forall a. (a) -> TargetType
        const numeric_casts = .{
            .{ "i8", Type.i8_type },
            .{ "i16", Type.i16_type },
            .{ "i32", Type.i32_type },
            .{ "i64", Type.i64_type },
            .{ "i128", Type.i128_type },
            .{ "u8", Type.u8_type },
            .{ "u16", Type.u16_type },
            .{ "u32", Type.u32_type },
            .{ "u64", Type.u64_type },
            .{ "u128", Type.u128_type },
            .{ "f32", Type.f32_type },
            .{ "f64", Type.f64_type },
        };
        inline for (numeric_casts) |cast| {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(cast[1]) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define(cast[0], TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName(cast[0]);
        }

        // 文档 2.7.8 / 2.17: Iterable<T> 和 Iterator<T> 内建 Trait
        {
            const iterable_trait_ty = self.allocator.create(Type) catch return;
            iterable_trait_ty.* = Type{ .trait_type = .{ .name = "Iterable", .type_args = &[_]*Type{} } };
            self.types.append(self.allocator, iterable_trait_ty) catch return;
            const iterable_method_names = self.allocator.alloc([]const u8, 1) catch return;
            iterable_method_names[0] = "iterator";
            const iterable_assoc_names = self.allocator.alloc([]const u8, 1) catch return;
            iterable_assoc_names[0] = "Item";
            // 注册方法签名：fun iterator(self: Iterable<T>) : Iterator<T>
            var iterable_method_schemes = std.StringHashMap(TypeScheme).init(self.allocator);
            {
                const t_var = self.freshTypeVar() catch return;
                const self_args = self.allocator.alloc(*Type, 1) catch return;
                self_args[0] = t_var;
                const self_type = self.allocator.create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Iterable", .type_args = self_args } };
                self.types.append(self.allocator, self_type) catch return;
                const ret_args = self.allocator.alloc(*Type, 1) catch return;
                ret_args[0] = t_var;
                const ret_type = self.allocator.create(Type) catch return;
                ret_type.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = ret_args } };
                self.types.append(self.allocator, ret_type) catch return;
                const fn_params = self.allocator.alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, ret_type) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                iterable_method_schemes.put(self.allocator.dupe(u8, "iterator") catch return, scheme) catch return;
            }
            const iterable_key = self.allocator.dupe(u8, "Iterable") catch return;
            self.trait_types.put(iterable_key, TraitInfo{
                .ty = iterable_trait_ty,
                .associated_type_names = iterable_assoc_names,
                .method_names = iterable_method_names,
                .method_schemes = iterable_method_schemes,
                .defining_module = "<builtin>",
            }) catch return;
            self.builtin_names.put(self.allocator.dupe(u8, "Iterable") catch return, {}) catch return;
        }
        {
            const iterator_trait_ty = self.allocator.create(Type) catch return;
            iterator_trait_ty.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = &[_]*Type{} } };
            self.types.append(self.allocator, iterator_trait_ty) catch return;
            const iterator_method_names = self.allocator.alloc([]const u8, 1) catch return;
            iterator_method_names[0] = "next";
            const iterator_assoc_names = self.allocator.alloc([]const u8, 1) catch return;
            iterator_assoc_names[0] = "Item";
            // 注册方法签名：fun next(self: Iterator<T>) : T?
            var iterator_method_schemes = std.StringHashMap(TypeScheme).init(self.allocator);
            {
                const t_var = self.freshTypeVar() catch return;
                const self_args = self.allocator.alloc(*Type, 1) catch return;
                self_args[0] = t_var;
                const self_type = self.allocator.create(Type) catch return;
                self_type.* = Type{ .trait_type = .{ .name = "Iterator", .type_args = self_args } };
                self.types.append(self.allocator, self_type) catch return;
                const ret_type = self.makeNullableType(t_var) catch return;
                const fn_params = self.allocator.alloc(*Type, 1) catch return;
                fn_params[0] = self_type;
                const fn_ty = self.makeFnType(fn_params, ret_type) catch return;
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty };
                iterator_method_schemes.put(self.allocator.dupe(u8, "next") catch return, scheme) catch return;
            }
            const iterator_key = self.allocator.dupe(u8, "Iterator") catch return;
            self.trait_types.put(iterator_key, TraitInfo{
                .ty = iterator_trait_ty,
                .associated_type_names = iterator_assoc_names,
                .method_names = iterator_method_names,
                .method_schemes = iterator_method_schemes,
                .defining_module = "<builtin>",
            }) catch return;
            self.builtin_names.put(self.allocator.dupe(u8, "Iterator") catch return, {}) catch return;
        }

        // Phase 4 并发原语内建函数类型签名

        // channel : (i32) -> Channel<T>  — 简化为 forall a. (i32) -> Channel<a>
        {
            const t_var = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = self.makeType(.i32_type) catch return;
            const ret_ty = self.makeGenericType("Channel", &[_]*Type{t_var}) catch return;
            const fn_ty = self.makeFnType(params, ret_ty) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = t_var.type_var.id;
            env.define("channel", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch return;
            self.registerBuiltinName("channel");
        }
    }

    /// 将名称注册到 builtin_names 集合
    fn registerBuiltinName(self: *TypeInferencer, name: []const u8) void {
        if (!self.builtin_names.contains(name)) {
            const key = self.allocator.dupe(u8, name) catch return;
            self.builtin_names.put(key, {}) catch return;
        }
    }

    /// 检查名称是否为内建函数/构造器
    pub fn isBuiltinName(self: *TypeInferencer, name: []const u8) bool {
        return self.builtin_names.contains(name);
    }

    /// 文档 §3.4.2: Atomic<T> 透明操作 — 解包 Atomic<T> 为 T
    /// 在算术/比较运算、函数参数等上下文中自动调用
    fn unwrapAtomic(self: *TypeInferencer, ty: *Type) *Type {
        const resolved = self.resolve(ty);
        if (resolved.* == .generic_type) {
            if (std.mem.eql(u8, resolved.generic_type.name, "Atomic") and resolved.generic_type.args.len == 1) {
                return resolved.generic_type.args[0];
            }
        }
        return ty;
    }

    /// 文档 2.7.6: Orphan Instance 禁止
    /// 文档 2.7.7: Overlapping Instances 禁止
    fn checkImplOrphanAndOverlapping(self: *TypeInferencer, id: @TypeOf(@as(ast.Decl, undefined).impl_decl)) void {
        trait_resolve.checkImplOrphanAndOverlapping(self, id);
    }

    /// 文档 2.7.4: 关联类型验证
    /// impl 必须定义 Trait 中声明的所有关联类型
    fn checkImplAssociatedTypes(self: *TypeInferencer, id: @TypeOf(@as(ast.Decl, undefined).impl_decl)) void {
        trait_resolve.checkImplAssociatedTypes(self, id);
    }

    /// 文档 2.7.2: 递归注册父 Trait 的方法到类型环境
    /// impl Child<T> 会自动满足所有父 Trait 的 bound
    fn registerParentTraitMethods(self: *TypeInferencer, env: *TypeEnv, trait_name: []const u8, overridden: *std.StringHashMap(void)) void {
        trait_resolve.registerParentTraitMethods(self, env, trait_name, overridden);
    }

    /// 将类型中的所有类型变量替换为具体类型
    /// 用于 impl 方法的类型实例化（如 impl Ord<i32> 中 T -> i32）
    fn instantiateWithConcreteType(self: *TypeInferencer, ty: *Type, concrete: *Type) SemaError!*Type {
        return trait_resolve.instantiateWithConcreteType(self, ty, concrete);
    }

    /// 对声明进行类型检查，收集错误而非提前返回
    fn checkDeclCollecting(self: *TypeInferencer, decl: ast.Decl, env: *TypeEnv) void {
        switch (decl) {
            .fun_decl => |f| {
                const child_env = env.createChild() catch return;

                // 泛型函数：fun max<T>(a: T, b: T): T with Ord<T>
                var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                defer type_param_map.deinit();
                var type_param_ids = std.ArrayList(usize).empty;
                defer type_param_ids.deinit(self.allocator);

                for (f.type_params) |tp| {
                    const tv = self.freshTypeVar() catch return;
                    type_param_map.put(tp.name, tv) catch return;
                    type_param_ids.append(self.allocator, tv.type_var.id) catch return;
                }

                var param_types = self.allocator.alloc(*Type, f.params.len) catch return;
                for (f.params, 0..) |param, i| {
                    const param_ty: *Type = if (param.type_annotation) |ta|
                        self.typeFromAstWithParams(ta, &type_param_map) catch blk: {
                            self.addError(.type_mismatch, "invalid type annotation for parameter '{s}'", .{param.name});
                            break :blk self.freshTypeVar() catch return;
                        }
                    else
                        self.freshTypeVar() catch return;
                    param_types[i] = param_ty;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                    child_env.define(param.name, scheme) catch return;
                }

                // 先构造函数类型，注册到环境中（支持递归调用）
                const ret_ty = if (f.return_type) |ret_type|
                    self.typeFromAstWithParams(ret_type, &type_param_map) catch self.freshTypeVar() catch return
                else
                    self.freshTypeVar() catch return;
                const fn_ty = self.makeFnType(param_types, ret_ty) catch return;
                // 先用显式 type_params 构造初始 scheme（支持递归调用）
                const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                const fn_scheme = TypeScheme{ .quantified_vars = qvars, .ty = fn_ty };
                child_env.define(f.name, fn_scheme) catch return;

                // 文档 2.3.9: 设置当前函数返回类型，用于 ? 传播检查
                const prev_fn_return = self.current_fn_return_type;
                if (f.return_type) |ret_type| {
                    self.current_fn_return_type = self.typeFromAstWithParams(ret_type, &type_param_map) catch null;
                } else {
                    self.current_fn_return_type = null;
                }
                defer self.current_fn_return_type = prev_fn_return;

                // 设置当前函数信息（用于多态递归检测）
                const prev_fn_info = self.current_fn_info;
                const owned_type_param_ids = self.allocator.dupe(usize, type_param_ids.items) catch return;
                self.current_fn_info = CurrentFnInfo{
                    .name = f.name,
                    .has_type_params = f.type_params.len > 0,
                    .has_return_annotation = f.return_type != null,
                    .type_param_ids = owned_type_param_ids,
                };
                defer {
                    if (self.current_fn_info) |info| {
                        self.allocator.free(info.type_param_ids);
                    }
                    self.current_fn_info = prev_fn_info;
                }

                const body_ty = self.inferExpr(f.body, child_env) catch |err| {
                    self.reportInferError(err, f.location);
                    return;
                };

                // 统一推断的返回类型与声明的返回类型
                // 文档 2.3.9: ? 传播语义允许函数体返回 T 自动提升为 T? / Throw<T, E>
                // 例如 fun useNullable(): i32? { val v = maybeNull()?; v + 1 }
                // v + 1 推断为 i32，但函数返回 i32?，i32 应自动提升
                self.unifyReturnType(ret_ty, body_ty) catch |err| {
                    self.reportUnifyError(err, f.location, ret_ty, body_ty);
                };

                // 同时注册到外层环境（供后续声明使用）
                // 推断完函数体后重新泛化，捕获推断出的自由类型变量（let 多态）
                const final_scheme = if (f.bounds.len > 0)
                    self.generalizeWithBounds(env, fn_ty, type_param_ids.items, f.bounds) catch return
                else
                    self.generalize(env, fn_ty) catch return;
                if (self.isBuiltinName(f.name)) {
                    // 文档 2.7.1: impl 方法允许与内建函数同名（通过接收者类型分派）
                    // eq、compare、str 等方法名在 impl 中常见，允许覆盖
                    if (!std.mem.eql(u8, f.name, "eq") and !std.mem.eql(u8, f.name, "compare") and !std.mem.eql(u8, f.name, "str")) {
                        self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{f.name});
                    } else {
                        // 允许覆盖内建函数（使用 redefine 而非 defineOrReport）
                        env.redefine(f.name, final_scheme) catch return;
                    }
                } else if (!(env.defineOrReport(f.name, final_scheme) catch false)) {
                    self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{f.name});
                }

                // 文档 2.7.3: Trait Bound `with` 验证
                for (f.bounds) |bound| {
                    self.checkTraitBound(bound, f.location);
                }

                // 文档 2.7.3: 记录函数的 Trait Bound，用于调用点延迟检查
                if (f.bounds.len > 0) {
                    const name_copy = self.allocator.dupe(u8, f.name) catch return;
                    // 复制 bounds 数组
                    const bounds_copy = self.allocator.alloc(ast.TraitBound, f.bounds.len) catch return;
                    @memcpy(bounds_copy, f.bounds);
                    self.fn_bounds.put(name_copy, bounds_copy) catch return;
                }
            },
            .type_decl => |td| {
                switch (td.def) {
                    .adt => |adt_def| {
                        // 泛型 ADT：type List<T> = | Nil | Cons(T, List<T>)
                        // 创建类型参数名 -> 类型变量的映射
                        var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.allocator);
                        var type_param_names = std.ArrayList([]const u8).empty;
                        defer type_param_names.deinit(self.allocator);

                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.allocator, tv.type_var.id) catch return;
                            const name_copy = self.allocator.dupe(u8, tp.name) catch return;
                            type_param_names.append(self.allocator, name_copy) catch return;
                        }

                        // ADT 类型：如果有类型参数，创建 adt_type 带参数（按声明顺序）
                        var adt_args = std.ArrayList(*Type).empty;
                        defer adt_args.deinit(self.allocator);
                        for (td.type_params) |tp| {
                            const tv = type_param_map.get(tp.name).?;
                            adt_args.append(self.allocator, tv) catch return;
                        }
                        const adt_ty = self.makeAdtType(td.name, adt_args.items) catch return;

                        // 收集构造器名称
                        var ctor_names = self.allocator.alloc([]const u8, adt_def.constructors.len) catch return;
                        for (adt_def.constructors, 0..) |con, i| {
                            ctor_names[i] = con.name;
                        }

                        const key = self.allocator.dupe(u8, td.name) catch return;
                        const owned_type_param_names = type_param_names.toOwnedSlice(self.allocator) catch return;
                        if (self.isBuiltinName(td.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (self.adt_types.contains(td.name)) {
                            self.addError(.type_mismatch, "duplicate type definition: '{s}' is already defined in this scope", .{td.name});
                        } else {
                            self.adt_types.put(key, AdtInfo{
                                .ty = adt_ty,
                                .constructor_names = ctor_names,
                                .type_param_names = owned_type_param_names,
                                .defining_module = self.current_module,
                            }) catch return;
                        }
                        // 记录类型定义模块（用于 Orphan 检查）
                        const mod_key = self.allocator.dupe(u8, td.name) catch return;
                        const mod_val = self.allocator.dupe(u8, self.current_module) catch return;
                        self.type_defining_modules.put(mod_key, mod_val) catch return;

                        // 注册构造器到类型环境
                        for (adt_def.constructors) |con| {
                            // 每个构造器需要独立的 quantified_vars 副本
                            const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                            if (self.isBuiltinName(con.name)) {
                                self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{con.name});
                            } else if (con.fields.len == 0) {
                                // 无参构造器：直接返回 ADT 类型
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = adt_ty };
                                if (!(env.defineOrReport(con.name, scheme) catch false)) {
                                    self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{con.name});
                                }
                            } else {
                                // 带参构造器：参数类型 -> ADT 类型
                                var param_types = self.allocator.alloc(*Type, con.fields.len) catch return;
                                for (con.fields, 0..) |field, i| {
                                    param_types[i] = self.typeFromAstWithParams(field.ty, &type_param_map) catch blk: {
                                        self.addError(.type_mismatch, "invalid type for field '{s}' in constructor '{s}'", .{ field.name orelse "_", con.name });
                                        break :blk self.freshTypeVar() catch return;
                                    };
                                }
                                const ctor_ty = self.makeFnType(param_types, adt_ty) catch return;
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                                if (!(env.defineOrReport(con.name, scheme) catch false)) {
                                    self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined in this scope", .{con.name});
                                }
                            }
                        }
                    },
                    .record => |rec_def| {
                        // 泛型记录类型：type Pair<A, B> = (first: A, second: B)
                        var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.allocator);

                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.allocator, tv.type_var.id) catch return;
                        }

                        var fields = self.allocator.alloc(FieldType, rec_def.fields.len) catch return;
                        for (rec_def.fields, 0..) |f, i| {
                            fields[i] = FieldType{
                                .name = f.name,
                                .ty = self.typeFromAstWithParams(f.ty, &type_param_map) catch return,
                            };
                        }
                        const rec_ty = self.allocator.create(Type) catch return;
                        rec_ty.* = Type{ .record_type = .{ .fields = fields } };
                        self.types.append(self.allocator, rec_ty) catch return;

                        var param_types = self.allocator.alloc(*Type, rec_def.fields.len) catch return;
                        for (rec_def.fields, 0..) |f, i| {
                            param_types[i] = self.typeFromAstWithParams(f.ty, &type_param_map) catch return;
                        }
                        const ctor_ty = self.makeFnType(param_types, rec_ty) catch return;
                        const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                        if (self.isBuiltinName(td.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (!(env.defineOrReport(td.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{td.name});
                        }
                        // 注册记录类型名到 adt_types，使类型注解中可用
                        // 例如 fun greet(u: User): str 中的 User 需要解析为 record_type
                        if (!self.adt_types.contains(td.name)) {
                            const key = self.allocator.dupe(u8, td.name) catch return;
                            const type_param_names = self.allocator.alloc([]const u8, td.type_params.len) catch return;
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
                        // 类型别名：type IntList = List<i32>
                        // 文档 2.14: Type Alias 不创建新类型
                        // 在类型环境中注册别名，使其在类型注解中可用
                        var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.allocator);
                        var type_param_names = std.ArrayList([]const u8).empty;
                        defer type_param_names.deinit(self.allocator);

                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.allocator, tv.type_var.id) catch return;
                            const name_copy = self.allocator.dupe(u8, tp.name) catch return;
                            type_param_names.append(self.allocator, name_copy) catch return;
                        }

                        // 解析目标类型
                        const target_ty = self.typeFromAstWithParams(ta.target, &type_param_map) catch {
                            self.addError(.type_mismatch, "invalid target type in type alias '{s}'", .{td.name});
                            return;
                        };

                        // 注册别名为类型方案（与目标类型等价）
                        const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = target_ty };
                        if (self.isBuiltinName(td.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{td.name});
                        } else if (!(env.defineOrReport(td.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{td.name});
                        }

                        // 始终注册到 adt_types 中（用于 typeFromAst 解析类型别名）
                        // 无论是否有类型参数，都需要注册，否则 typeFromAst 无法解析 IntList 等别名
                        if (!self.adt_types.contains(td.name)) {
                            const key = self.allocator.dupe(u8, td.name) catch return;
                            const owned_type_param_names = type_param_names.toOwnedSlice(self.allocator) catch return;
                            self.adt_types.put(key, AdtInfo{
                                .ty = target_ty,
                                .constructor_names = &[_][]const u8{},
                                .type_param_names = owned_type_param_names,
                                .defining_module = self.current_module,
                            }) catch return;
                        }
                    },
                    .newtype => |nt| {
                        // newtype 构造器类型：inner -> newtype
                        // 例如 type UserId = UserId(i32) → UserId : i32 -> UserId
                        // 泛型 newtype: type Pair<A, B> = Pair(first: A, second: B)
                        var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                        defer type_param_map.deinit();
                        var type_param_ids = std.ArrayList(usize).empty;
                        defer type_param_ids.deinit(self.allocator);

                        for (td.type_params) |tp| {
                            const tv = self.freshTypeVar() catch return;
                            type_param_map.put(tp.name, tv) catch return;
                            type_param_ids.append(self.allocator, tv.type_var.id) catch return;
                        }

                        var adt_args = std.ArrayList(*Type).empty;
                        defer adt_args.deinit(self.allocator);
                        for (td.type_params) |tp| {
                            const tv = type_param_map.get(tp.name).?;
                            adt_args.append(self.allocator, tv) catch return;
                        }
                        const newtype_ty = self.makeAdtType(td.name, adt_args.items) catch return;
                        const inner_ty = self.typeFromAstWithParams(nt.inner, &type_param_map) catch return;
                        const ctor_params = self.allocator.alloc(*Type, 1) catch return;
                        ctor_params[0] = inner_ty;
                        const ctor_ty = self.makeFnType(ctor_params, newtype_ty) catch return;
                        const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                        const scheme = TypeScheme{ .quantified_vars = qvars, .ty = ctor_ty };
                        if (self.isBuiltinName(nt.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{nt.name});
                        } else if (!(env.defineOrReport(nt.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{nt.name});
                        }
                    },
                    .error_newtype => |en| {
                        // 错误 newtype：构造器类型 String -> ErrorADT
                        // 例如 type FileError = Error("file error") → FileError : String -> FileError
                        // 文档 2.4.2: Name 是 Error 的子类型——FileError <: Error
                        const error_adt = self.makeAdtType(en.name, &[_]*Type{}) catch return;
                        const ctor_params = self.allocator.alloc(*Type, 1) catch return;
                        ctor_params[0] = self.makeType(.str_type) catch return;
                        const ctor_ty = self.makeFnType(ctor_params, error_adt) catch return;
                        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = ctor_ty };
                        if (self.isBuiltinName(en.name)) {
                            self.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{en.name});
                        } else if (!(env.defineOrReport(en.name, scheme) catch false)) {
                            self.addError(.type_mismatch, "duplicate definition: '{s}' is already defined", .{en.name});
                        }
                        // 注册为 ADT 类型，标记为 error newtype
                        if (self.isBuiltinName(en.name)) {
                            // 已在上面报错
                        } else if (self.adt_types.contains(en.name)) {
                            self.addError(.type_mismatch, "duplicate type definition: '{s}' is already defined", .{en.name});
                        } else {
                            const key = self.allocator.dupe(u8, en.name) catch return;
                            const ctor_names = self.allocator.alloc([]const u8, 1) catch return;
                            ctor_names[0] = en.name;
                            self.adt_types.put(key, AdtInfo{ .ty = error_adt, .constructor_names = ctor_names, .is_error_newtype = true }) catch return;
                        }
                    },
                }
            },
            .trait_decl => |td| {
                trait_resolve.checkTraitDecl(self, td);
            },
            .impl_decl => |id| {
                trait_resolve.checkImplDecl(self, id, env);
            },
            .use_decl => {
                // use 声明：类型检查在模块加载时处理
            },
            .pack_decl => {
                // pack 声明：模块系统处理
            },
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    _ = self.inferStmt(s, env) catch |err| {
                        self.reportInferError(err, ed.location);
                    };
                } else {
                    _ = self.inferExpr(ed.expr, env) catch |err| {
                        self.reportInferError(err, ed.location);
                    };
                }
            },
        }
    }

    /// 检查模式匹配的穷尽性
    fn checkExhaustiveness(self: *TypeInferencer, scrutinee_ty: *Type, arms: []ast.MatchArm, location: ast.SourceLocation) void {
        const resolved = self.resolve(scrutinee_ty);

        switch (resolved.*) {
            .adt_type => |at| {
                // ADT 类型：检查所有构造器是否被覆盖
                if (self.adt_types.get(at.name)) |adt_info| {
                    const covered = self.allocator.alloc(bool, adt_info.constructor_names.len) catch return;
                    defer self.allocator.free(covered);
                    @memset(covered, false);

                    var has_wildcard = false;
                    for (arms) |arm| {
                        if (self.patternCoversWildcard(arm.pattern)) {
                            has_wildcard = true;
                            break;
                        }
                        self.markCoveredConstructors(arm.pattern, adt_info.constructor_names, covered);
                        // 文档 2.4.2: FileError <: Error
                        // Error 模式覆盖所有 error newtype 的构造器
                        if (adt_info.is_error_newtype) {
                            if (self.patternCoversConstructorNamed(arm.pattern, "Error")) {
                                for (0..covered.len) |i| {
                                    covered[i] = true;
                                }
                            }
                        }
                    }

                    if (has_wildcard) return;

                    // 检查是否所有构造器都被覆盖
                    var all_covered = true;
                    for (covered) |c| {
                        if (!c) {
                            all_covered = false;
                            break;
                        }
                    }
                    if (all_covered) return;

                    // 收集缺失的构造器
                    var missing_buf = std.ArrayList(u8).empty;
                    defer missing_buf.deinit(self.allocator);
                    var first = true;
                    for (covered, 0..) |c, i| {
                        if (!c) {
                            if (!first) {
                                missing_buf.appendSlice(self.allocator, ", ") catch return;
                            }
                            missing_buf.appendSlice(self.allocator, adt_info.constructor_names[i]) catch return;
                            first = false;
                        }
                    }
                    self.addErrorAt(.non_exhaustive_match, location.line, location.column, "non-exhaustive match: missing patterns: {s}", .{missing_buf.items});
                }
            },
            .nullable_type => {
                // Nullable T? 类型：检查 null 是否被处理
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
                // Throw<T, E> 类型：检查 Ok 和 Error 是否都被处理
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
                defer missing_buf.deinit(self.allocator);
                var first = true;
                if (!has_ok) {
                    missing_buf.appendSlice(self.allocator, "Ok") catch return;
                    first = false;
                }
                if (!has_error) {
                    if (!first) {
                        missing_buf.appendSlice(self.allocator, ", ") catch return;
                    }
                    missing_buf.appendSlice(self.allocator, "Error") catch return;
                }
                if (!has_ok or !has_error) {
                    self.addErrorAt(.non_exhaustive_match, location.line, location.column, "non-exhaustive match: missing patterns: {s}", .{missing_buf.items});
                }
            },
            else => {
                // 其他类型不做穷尽性检查
            },
        }
    }

    /// 检查模式是否为通配符（_ 或变量绑定），覆盖所有情况
    fn patternCoversWildcard(self: *TypeInferencer, pat: *const ast.Pattern) bool {
        return switch (pat.*) {
            .wildcard => true,
            .variable => true,
            .or_pattern => |or_p| self.patternCoversWildcard(or_p.left) and self.patternCoversWildcard(or_p.right),
            else => false,
        };
    }

    /// 检查模式是否覆盖 null
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

    /// 检查模式是否覆盖指定名称的构造器
    fn patternCoversConstructorNamed(self: *TypeInferencer, pat: *const ast.Pattern, name: []const u8) bool {
        return switch (pat.*) {
            .constructor => |con| std.mem.eql(u8, con.name, name),
            .or_pattern => |or_p| self.patternCoversConstructorNamed(or_p.left, name) or self.patternCoversConstructorNamed(or_p.right, name),
            else => false,
        };
    }

    /// 标记模式覆盖的构造器
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
            .or_pattern => |or_p| {
                self.markCoveredConstructors(or_p.left, constructor_names, covered);
                self.markCoveredConstructors(or_p.right, constructor_names, covered);
            },
            else => {},
        }
    }

    /// 报告推断错误
    fn reportInferError(self: *TypeInferencer, err: SemaError, location: ast.SourceLocation) void {
        switch (err) {
            error.TypeMismatch => self.addErrorAt(.type_mismatch, location.line, location.column, "type mismatch: incompatible types", .{}),
            error.UnboundVariable => self.addErrorAt(.unbound_variable, location.line, location.column, "undefined variable", .{}),
            error.ArityMismatch => self.addErrorAt(.arity_mismatch, location.line, location.column, "function argument count mismatch", .{}),
            error.OccursCheckFailed => {
                // 文档 2.10: 多态递归函数必须提供类型标注
                // 当泛型函数的递归调用使用了与自身不同的类型参数时，
                // HM 推断无法处理，会产生无限类型（occurs check 失败）
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
            error.DuplicateDefinition => self.addErrorAt(.type_mismatch, location.line, location.column, "duplicate definition in scope", .{}),
            error.OutOfMemory => {}, // 不报告 OOM
        }
    }

    /// 报告统一错误，包含期望类型和实际类型
    fn reportUnifyError(self: *TypeInferencer, err: SemaError, location: ast.SourceLocation, expected: *Type, actual: *Type) void {
        switch (err) {
            error.TypeMismatch => {
                var expected_buf = std.ArrayList(u8).empty;
                var actual_buf = std.ArrayList(u8).empty;
                defer expected_buf.deinit(self.allocator);
                defer actual_buf.deinit(self.allocator);
                expected.formatArrayList(&expected_buf, self.allocator) catch {};
                actual.formatArrayList(&actual_buf, self.allocator) catch {};
                self.addErrorAt(.type_mismatch, location.line, location.column, "type mismatch: expected {s}, got {s}", .{ expected_buf.items, actual_buf.items });
            },
            else => self.reportInferError(err, location),
        }
    }

    /// 文档 2.7.3: 调用点 Trait Bound 延迟检查
    /// 当调用泛型函数时，检查类型参数是否满足函数声明的 Trait Bound
    fn checkCallSiteTraitBound(self: *TypeInferencer, callee: *const ast.Expr, location: ast.SourceLocation) void {
        trait_resolve.checkCallSiteTraitBound(self, callee, location);
    }

    /// 文档 2.7.3: 从 TypeScheme 的 BoundInfo 检查 Trait Bound
    /// 在实例化后调用，检查实例化后的类型参数是否满足 bound
    fn checkInstantiatedBounds(self: *TypeInferencer, scheme: TypeScheme, location: ast.SourceLocation) void {
        trait_resolve.checkInstantiatedBounds(self, scheme, location);
    }

    /// 文档 2.7.3: Trait Bound `with` 验证
    /// 检查声明的 Trait bound 是否有对应的 trait 定义和 impl 实现
    fn checkTraitBound(self: *TypeInferencer, bound: ast.TraitBound, location: ast.SourceLocation) void {
        trait_resolve.checkTraitBound(self, bound, location);
    }
};
