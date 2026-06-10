//! Glue 语言语义分析模块
//!
//! 实现 Hindley-Milner 类型推断，包括：
//! - 类型表示（基本类型、函数类型、ADT 类型、类型变量等）
//! - 统一算法（unification）
//! - 类型推断（Algorithm W）
//! - 类型检查和错误报告

const std = @import("std");
const ast = @import("ast");

// ============================================================
// 类型表示
// ============================================================

/// 类型 ID（用于类型变量的唯一标识）
var next_type_id: usize = 0;

/// 类型节点
pub const Type = union(enum) {
    // 基本类型
    int_type,
    float_type,
    bool_type,
    string_type,
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

    pub fn format(self: Type, writer: anytype) !void {
        switch (self) {
            .int_type => try writer.writeAll("i32"),
            .float_type => try writer.writeAll("f64"),
            .bool_type => try writer.writeAll("bool"),
            .string_type => try writer.writeAll("String"),
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
            .int_type => try buf.appendSlice(allocator, "i32"),
            .float_type => try buf.appendSlice(allocator, "f64"),
            .bool_type => try buf.appendSlice(allocator, "bool"),
            .string_type => try buf.appendSlice(allocator, "String"),
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

    pub fn define(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !void {
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
        // 释放错误消息
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// 添加类型错误到错误列表
    fn addError(self: *TypeInferencer, kind: TypeErrorKind, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.errors.append(self.allocator, TypeError{
            .kind = kind,
            .message = message,
        }) catch {};
    }

    /// 添加带源码位置的类型错误
    fn addErrorAt(self: *TypeInferencer, kind: TypeErrorKind, line: u32, column: u32, comptime fmt: []const u8, args: anytype) void {
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
    pub fn freshTypeVar(self: *TypeInferencer) !*Type {
        const tv = try self.allocator.create(TypeVar);
        tv.* = TypeVar.init();
        try self.type_vars.append(self.allocator, tv);
        const t = try self.allocator.create(Type);
        t.* = Type{ .type_var = tv };
        try self.types.append(self.allocator, t);
        return t;
    }

    /// 创建基本类型
    pub fn makeType(self: *TypeInferencer, comptime tag: @TypeOf(Type.int_type)) !*Type {
        const t = try self.allocator.create(Type);
        t.* = tag;
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

        if (tag1 != tag2) return error.TypeMismatch;

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
                if (rt1.fields.len != rt2.fields.len) return error.TypeMismatch;
                for (rt1.fields, rt2.fields) |f1, f2| {
                    if (!std.mem.eql(u8, f1.name, f2.name)) return error.TypeMismatch;
                    try self.unify(f1.ty, f2.ty);
                }
            },
            .nullable_type => |inner1| {
                try self.unify(inner1, resolved2.nullable_type);
            },
            .adt_type => |at1| {
                const at2 = resolved2.adt_type;
                if (!std.mem.eql(u8, at1.name, at2.name)) return error.TypeMismatch;
                if (at1.type_args.len != at2.type_args.len) return error.TypeMismatch;
                for (at1.type_args, at2.type_args) |a1, a2| {
                    try self.unify(a1, a2);
                }
            },
            .throw_type => |tt1| {
                const tt2 = resolved2.throw_type;
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
            else => {
                // 基本类型相同（tag1 == tag2 已保证）
            },
        }
    }

    /// 函数返回类型统一：允许 T 自动提升为 T? 或 Throw<T, E>
    /// 文档 2.3.9: ? 传播语义 — 函数体返回 T 时，若声明返回 T?，T 自动提升
    fn unifyReturnType(self: *TypeInferencer, declared: *Type, inferred: *Type) SemaError!void {
        const resolved_declared = self.resolve(declared);
        const resolved_inferred = self.resolve(inferred);

        switch (resolved_declared.*) {
            .nullable_type => |inner| {
                // 声明返回 T?，推断为 T → 将 T 统一到 T? 的内部类型
                switch (resolved_inferred.*) {
                    .nullable_type => try self.unify(declared, inferred),
                    else => try self.unify(inner, inferred),
                }
            },
            .throw_type => |tt| {
                // 声明返回 Throw<T, E>，推断为 T → 将 T 统一到 Throw 的 value_type
                switch (resolved_inferred.*) {
                    .throw_type => try self.unify(declared, inferred),
                    else => try self.unify(tt.value_type, inferred),
                }
            },
            else => try self.unify(declared, inferred),
        }
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
            else => return resolved,
        }
    }

    // ============================================================
    // 类型推断（Algorithm W）
    // ============================================================

    /// 推断表达式的类型
    pub fn inferExpr(self: *TypeInferencer, expr: *const ast.Expr, env: *TypeEnv) SemaError!*Type {
        return switch (expr.*) {
            .int_literal => self.makeType(.int_type),
            .float_literal => self.makeType(.float_type),
            .bool_literal => self.makeType(.bool_type),
            .char_literal => self.makeType(.char_type),
            .string_literal => self.makeType(.string_type),
            .null_literal => {
                // null 的类型由上下文决定：统一为 T? 时自动收窄
                const tv = try self.freshTypeVar();
                return self.makeNullableType(tv);
            },
            .unit_literal => self.makeType(.unit_type),

            .identifier => |id| {
                if (env.lookup(id.name)) |scheme| {
                    return self.instantiate(scheme);
                }
                return error.UnboundVariable;
            },

            .binary => |bin| {
                const left_ty = try self.inferExpr(bin.left, env);
                const right_ty = try self.inferExpr(bin.right, env);

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
                    .concat => {
                        try self.unify(left_ty, try self.makeType(.string_type));
                        try self.unify(right_ty, try self.makeType(.string_type));
                        return self.makeType(.string_type);
                    },
                    .range, .range_inclusive => {
                        try self.unify(left_ty, try self.makeType(.int_type));
                        try self.unify(right_ty, try self.makeType(.int_type));
                        // Range 类型不是独立类型，元素类型由推断决定
                        return self.makeType(.int_type);
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
                try self.unify(callee_ty, expected_fn_ty);
                return ret_ty;
            },

            .if_expr => |ie| {
                const cond_ty = try self.inferExpr(ie.condition, env);
                try self.unify(cond_ty, try self.makeType(.bool_type));
                const then_ty = try self.inferExpr(ie.then_branch, env);
                if (ie.else_branch) |else_br| {
                    const else_ty = try self.inferExpr(else_br, env);
                    try self.unify(then_ty, else_ty);
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
                var result_ty: ?*Type = null;
                for (m.arms) |arm| {
                    const child_env = try env.createChild();
                    try self.inferPattern(arm.pattern, scrutinee_ty, child_env);
                    const body_ty = try self.inferExpr(arm.body, child_env);
                    if (result_ty) |rt| {
                        try self.unify(rt, body_ty);
                    } else {
                        result_ty = body_ty;
                    }
                }
                self.checkExhaustiveness(scrutinee_ty, m.arms, m.location);
                return result_ty orelse self.makeType(.unit_type);
            },

            .array_literal => |al| {
                const elem_ty = try self.freshTypeVar();
                for (al.elements) |elem| {
                    const ty = try self.inferExpr(elem, env);
                    try self.unify(elem_ty, ty);
                }
                // 数组类型简化为 [elem_ty]
                return self.makeType(.unknown_type);
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

            .field_access => |fa| {
                const obj_ty = try self.inferExpr(fa.object, env);
                // 简化处理：字段访问返回新类型变量
                // 完整实现需要记录类型检查
                _ = obj_ty;
                return self.freshTypeVar();
            },

            .method_call => |mc| {
                const obj_ty = try self.inferExpr(mc.object, env);
                _ = obj_ty;
                // 简化处理：方法调用返回新类型变量
                // 完整实现需要 trait 方法签名查找
                return self.freshTypeVar();
            },

            .propagate => |prop| {
                const inner_ty = try self.inferExpr(prop.expr, env);
                const resolved_inner = self.resolve(inner_ty);

                // 文档 2.3.9: ? 操作符严格按类型匹配，不跨 Nullable/Throw
                switch (resolved_inner.*) {
                    .nullable_type => |inner| {
                        // T? 上的 ? → 外层函数必须返回 U?
                        if (self.current_fn_return_type) |fn_ret| {
                            const resolved_ret = self.resolve(fn_ret);
                            switch (resolved_ret.*) {
                                .nullable_type => {
                                    // ✅ 外层返回 U?，兼容
                                },
                                else => {
                                    // ❌ 在非 Nullable 返回函数中对 T? 用 ?
                                    self.addErrorAt(.propagate_cross_type, prop.location.line, prop.location.column, "? on T? requires enclosing function to return U?, but got non-nullable return type", .{});
                                },
                            }
                        } else {
                            // 无返回类型注解，无法验证
                        }
                        return inner;
                    },
                    .throw_type => |tt| {
                        // Throw<T, E_inner> 上的 ? → 外层函数必须返回 Throw<U, E_outer>
                        if (self.current_fn_return_type) |fn_ret| {
                            const resolved_ret = self.resolve(fn_ret);
                            switch (resolved_ret.*) {
                                .throw_type => {
                                    // ✅ 外层返回 Throw<U, E_outer>，兼容
                                    // 文档要求 E_inner <: E_outer，Phase 2 简化：仅检查外层是 Throw
                                },
                                else => {
                                    // ❌ 在非 Throw 返回函数中对 Throw 用 ?
                                    self.addErrorAt(.propagate_cross_type, prop.location.line, prop.location.column, "? on Throw<T, E> requires enclosing function to return Throw<U, E'>, but got non-throw return type", .{});
                                },
                            }
                        }
                        return tt.value_type;
                    },
                    else => {
                        // ? 作用于非 T? 非 Throw<T,E> 的类型
                        // 文档 2.3.9: 在普通函数中使用 ? → 编译错误
                        if (self.current_fn_return_type) |fn_ret| {
                            const resolved_ret = self.resolve(fn_ret);
                            switch (resolved_ret.*) {
                                .nullable_type, .throw_type => {
                                    // 外层期望 Nullable/Throw 但表达式不是
                                    self.addErrorAt(.propagate_cross_type, prop.location.line, prop.location.column, "? cannot be used on a non-nullable, non-throw expression", .{});
                                },
                                else => {
                                    // 普通函数中对普通值用 ? — 也报错
                                    self.addErrorAt(.propagate_cross_type, prop.location.line, prop.location.column, "? cannot be used on a non-nullable, non-throw expression", .{});
                                },
                            }
                        }
                        return inner_ty;
                    },
                }
            },

            .non_null_assert => |nna| {
                return self.inferExpr(nna.expr, env);
            },

            .safe_access => |sa| {
                const obj_ty = try self.inferExpr(sa.object, env);
                _ = obj_ty;
                return self.freshTypeVar();
            },

            .safe_method_call => |smc| {
                const obj_ty = try self.inferExpr(smc.object, env);
                _ = obj_ty;
                return self.freshTypeVar();
            },

            .index => |idx| {
                const obj_ty = try self.inferExpr(idx.object, env);
                const idx_ty = try self.inferExpr(idx.index, env);
                _ = obj_ty;
                try self.unify(idx_ty, try self.makeType(.int_type));
                return self.freshTypeVar();
            },

            .string_interpolation => {
                return self.makeType(.string_type);
            },

            .type_cast => |tc| {
                _ = try self.inferExpr(tc.expr, env);
                return self.typeFromAst(tc.target_type);
            },

            .assignment_expr => |ae| {
                const val_ty = try self.inferExpr(ae.value, env);
                return val_ty;
            },

            // 尚未实现的表达式类型
            .spawn, .lazy, .select, .monad_comprehension, .inline_trait_value => {
                return self.freshTypeVar();
            },
        };
    }

    /// 推断语句的类型
    pub fn inferStmt(self: *TypeInferencer, stmt: *const ast.Stmt, env: *TypeEnv) SemaError!?*Type {
        return switch (stmt.*) {
            .val_decl => |vd| {
                const val_ty = try self.inferExpr(vd.value, env);
                const scheme = try self.generalize(env, val_ty);
                try env.define(vd.name, scheme);
                return null;
            },
            .var_decl => |vd| {
                const val_ty = try self.inferExpr(vd.value, env);
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = val_ty };
                try env.define(vd.name, scheme);
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
                // for item in iterable: item 的类型由 iterable 推断
                const item_ty = try self.freshTypeVar();
                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = item_ty };
                try child_env.define(fs.name, scheme);
                _ = iterable_ty;
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
                if (std.mem.eql(u8, n.name, "i32") or std.mem.eql(u8, n.name, "i64") or
                    std.mem.eql(u8, n.name, "i16") or std.mem.eql(u8, n.name, "i8"))
                {
                    return self.makeType(.int_type);
                }
                if (std.mem.eql(u8, n.name, "f64") or std.mem.eql(u8, n.name, "f32")) {
                    return self.makeType(.float_type);
                }
                if (std.mem.eql(u8, n.name, "bool")) {
                    return self.makeType(.bool_type);
                }
                if (std.mem.eql(u8, n.name, "String") or std.mem.eql(u8, n.name, "string")) {
                    return self.makeType(.string_type);
                }
                if (std.mem.eql(u8, n.name, "char")) {
                    return self.makeType(.char_type);
                }
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
            env.define("println", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // print : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("print", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // eprintln : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprintln", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // eprint : forall a. (a) -> ()
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("eprint", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // Panic : (String) -> !
        {
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = self.makeType(.string_type) catch return;
            const fn_ty = self.makeFnType(params, self.makeType(.unit_type) catch return) catch return;
            env.define("Panic", TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_ty }) catch {};
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
            env.define("eq", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // string : forall a. (a) -> String
        {
            const param = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = param;
            const fn_ty = self.makeFnType(params, self.makeType(.string_type) catch return) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = param.type_var.id;
            env.define("string", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // Error ADT 类型（用于 Throw<T, Error> 中的 Error 类型参数）
        const error_adt_ty = self.makeAdtType("Error", &[_]*Type{}) catch return;
        const error_adt_key = self.allocator.dupe(u8, "Error") catch return;
        self.adt_types.put(error_adt_key, AdtInfo{ .ty = error_adt_ty, .constructor_names = &[_][]const u8{} }) catch return;

        // Error : forall a. (String) -> Throw<a, Error>
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = self.makeType(.string_type) catch return;
            const throw_ty = self.allocator.create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.allocator, throw_ty) catch {};
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Error", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }

        // Ok : forall a. (a) -> Throw<a, Error>
        {
            const val_ty = self.freshTypeVar() catch return;
            const params = self.allocator.alloc(*Type, 1) catch return;
            params[0] = val_ty;
            const throw_ty = self.allocator.create(Type) catch return;
            throw_ty.* = Type{ .throw_type = .{ .value_type = val_ty, .error_type = error_adt_ty } };
            self.types.append(self.allocator, throw_ty) catch {};
            const fn_ty = self.makeFnType(params, throw_ty) catch return;
            const qvars = self.allocator.alloc(usize, 1) catch return;
            qvars[0] = val_ty.type_var.id;
            env.define("Ok", TypeScheme{ .quantified_vars = qvars, .ty = fn_ty }) catch {};
        }
    }

    /// 文档 2.7.6: Orphan Instance 禁止
    /// 文档 2.7.7: Overlapping Instances 禁止
    fn checkImplOrphanAndOverlapping(self: *TypeInferencer, id: @TypeOf(@as(ast.Decl, undefined).impl_decl)) void {
        const trait_name = id.trait_name;
        // 获取 impl 的类型名（从 impl TraitName for TypeName 中提取）
        const type_name = id.type_name;

        // --- Orphan 检查 ---
        // 规则：如果 Trait 和 Type 都不是当前模块定义的，则禁止
        const trait_module = self.trait_defining_modules.get(trait_name);
        const type_module = self.type_defining_modules.get(type_name);

        if (trait_module != null and type_module != null) {
            const tm = trait_module.?;
            const tym = type_module.?;
            // 两者都来自其他模块，且都不是当前模块
            if (!std.mem.eql(u8, tm, self.current_module) and
                !std.mem.eql(u8, tym, self.current_module))
            {
                self.addError(.unsatisfied_bound, "orphan instance: impl {s} for {s} — neither {s} nor {s} is defined in current module '{s}'", .{ trait_name, type_name, trait_name, type_name, self.current_module });
            }
        }

        // --- Overlapping 检查 ---
        // key: "trait_name::type_name"
        const impl_key = std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ trait_name, type_name }) catch return;
        if (self.registered_impls.get(impl_key)) |existing| {
            self.addError(.unsatisfied_bound, "overlapping instance: impl {s} for {s} already defined at line {d}", .{ trait_name, type_name, existing.line });
            self.allocator.free(impl_key);
        } else {
            self.registered_impls.put(impl_key, ImplRecord{
                .trait_name = trait_name,
                .type_name = type_name,
                .line = id.location.line,
                .column = id.location.column,
            }) catch return;
        }
    }

    /// 文档 2.7.4: 关联类型验证
    /// impl 必须定义 Trait 中声明的所有关联类型
    fn checkImplAssociatedTypes(self: *TypeInferencer, id: @TypeOf(@as(ast.Decl, undefined).impl_decl)) void {
        const trait_info = self.trait_types.get(id.trait_name) orelse return;
        if (trait_info.associated_type_names.len == 0) return;

        // 收集 impl 中已定义的关联类型名
        var defined_names = std.StringHashMap(void).init(self.allocator);
        defer defined_names.deinit();
        for (id.associated_type_defs) |atd| {
            defined_names.put(atd.name, {}) catch return;
        }

        // 检查 Trait 中声明的每个关联类型是否在 impl 中定义
        for (trait_info.associated_type_names) |assoc_name| {
            if (!defined_names.contains(assoc_name)) {
                self.addError(.unsatisfied_bound, "impl {s} for {s}: missing associated type '{s}'", .{ id.trait_name, id.type_name, assoc_name });
            }
        }
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
                const final_scheme = self.generalize(env, fn_ty) catch return;
                env.define(f.name, final_scheme) catch return;

                // 文档 2.7.3: Trait Bound `with` 验证
                for (f.bounds) |bound| {
                    self.checkTraitBound(bound, f.location);
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
                        self.adt_types.put(key, AdtInfo{
                            .ty = adt_ty,
                            .constructor_names = ctor_names,
                            .type_param_names = owned_type_param_names,
                            .defining_module = self.current_module,
                        }) catch return;
                        // 记录类型定义模块（用于 Orphan 检查）
                        const mod_key = self.allocator.dupe(u8, td.name) catch return;
                        const mod_val = self.allocator.dupe(u8, self.current_module) catch return;
                        self.type_defining_modules.put(mod_key, mod_val) catch return;

                        // 注册构造器到类型环境
                        for (adt_def.constructors) |con| {
                            // 每个构造器需要独立的 quantified_vars 副本
                            const qvars = self.allocator.dupe(usize, type_param_ids.items) catch return;
                            if (con.fields.len == 0) {
                                // 无参构造器：直接返回 ADT 类型
                                const scheme = TypeScheme{ .quantified_vars = qvars, .ty = adt_ty };
                                env.define(con.name, scheme) catch return;
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
                                env.define(con.name, scheme) catch return;
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
                        env.define(td.name, scheme) catch return;
                    },
                    .alias => {
                        // 类型别名：不创建新类型
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
                        env.define(nt.name, scheme) catch return;
                    },
                    .error_newtype => |en| {
                        // 错误 newtype：构造器类型 String -> ErrorADT
                        // 例如 type FileError = Error("file error") → FileError : String -> FileError
                        // 文档 2.4.2: Name 是 Error 的子类型——FileError <: Error
                        const error_adt = self.makeAdtType(en.name, &[_]*Type{}) catch return;
                        const ctor_params = self.allocator.alloc(*Type, 1) catch return;
                        ctor_params[0] = self.makeType(.string_type) catch return;
                        const ctor_ty = self.makeFnType(ctor_params, error_adt) catch return;
                        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = ctor_ty };
                        env.define(en.name, scheme) catch return;
                        // 注册为 ADT 类型，标记为 error newtype
                        const key = self.allocator.dupe(u8, en.name) catch return;
                        const ctor_names = self.allocator.alloc([]const u8, 1) catch return;
                        ctor_names[0] = en.name;
                        self.adt_types.put(key, AdtInfo{ .ty = error_adt, .constructor_names = ctor_names, .is_error_newtype = true }) catch return;
                    },
                }
            },
            .trait_decl => |td| {
                const trait_ty = self.allocator.create(Type) catch return;
                trait_ty.* = Type{ .trait_type = .{ .name = td.name, .type_args = &[_]*Type{} } };
                self.types.append(self.allocator, trait_ty) catch return;

                // 收集关联类型名称
                var assoc_names = self.allocator.alloc([]const u8, td.associated_types.len) catch return;
                for (td.associated_types, 0..) |at, i| {
                    assoc_names[i] = at.name;
                }

                // 收集方法名称
                var meth_names = self.allocator.alloc([]const u8, td.methods.len) catch return;
                for (td.methods, 0..) |m, i| {
                    meth_names[i] = m.name;
                }

                const key = self.allocator.dupe(u8, td.name) catch return;
                self.trait_types.put(key, TraitInfo{
                    .ty = trait_ty,
                    .associated_type_names = assoc_names,
                    .method_names = meth_names,
                    .defining_module = self.current_module,
                }) catch return;
                // 记录 Trait 定义模块（用于 Orphan 检查）
                const mod_key = self.allocator.dupe(u8, td.name) catch return;
                const mod_val = self.allocator.dupe(u8, self.current_module) catch return;
                self.trait_defining_modules.put(mod_key, mod_val) catch return;
            },
            .impl_decl => |id| {
                // 文档 2.7.6: Orphan Instance 禁止
                // 文档 2.7.7: Overlapping Instances 禁止
                self.checkImplOrphanAndOverlapping(id);

                // 文档 2.7.4: 关联类型验证
                // impl 必须定义 Trait 中声明的所有关联类型
                self.checkImplAssociatedTypes(id);

                // Impl 声明：将 impl 中的方法注册到类型环境
                // 这样后续代码可以直接调用 compare(a, b) 等
                for (id.methods) |method| {
                    if (method.body) |_| {
                        // 构造方法类型
                        var param_types = self.allocator.alloc(*Type, method.params.len) catch return;
                        for (method.params, 0..) |param, i| {
                            param_types[i] = if (param.type_annotation) |ta|
                                self.typeFromAst(ta) catch self.freshTypeVar() catch return
                            else
                                self.freshTypeVar() catch return;
                        }
                        const ret_ty = if (method.return_type) |rt|
                            self.typeFromAst(rt) catch self.freshTypeVar() catch return
                        else
                            self.freshTypeVar() catch return;
                        const fn_ty = self.makeFnType(param_types, ret_ty) catch return;
                        const scheme = self.generalize(env, fn_ty) catch return;
                        env.define(method.name, scheme) catch return;
                    }
                }
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
            error.TypeMismatch => self.addErrorAt(.type_mismatch, location.line, location.column, "type mismatch", .{}),
            error.UnboundVariable => self.addErrorAt(.unbound_variable, location.line, location.column, "unbound variable", .{}),
            error.ArityMismatch => self.addErrorAt(.arity_mismatch, location.line, location.column, "arity mismatch", .{}),
            error.OccursCheckFailed => self.addErrorAt(.recursive_type, location.line, location.column, "recursive type (occurs check failed)", .{}),
            error.MissingImplementation => self.addErrorAt(.missing_implementation, location.line, location.column, "missing implementation", .{}),
            error.RecursiveType => self.addErrorAt(.recursive_type, location.line, location.column, "recursive type", .{}),
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

    /// 文档 2.7.3: Trait Bound `with` 验证
    /// 检查声明的 Trait bound 是否有对应的 trait 定义和 impl 实现
    fn checkTraitBound(self: *TypeInferencer, bound: ast.TraitBound, location: ast.SourceLocation) void {
        // 检查 trait 是否已定义
        if (self.trait_types.getPtr(bound.trait_name)) |_| {
            // Trait 存在，验证通过
            // Phase 2 简化：仅检查 trait 是否已定义
            // 完整实现需要：
            // 1. 检查泛型参数是否满足 trait 的类型参数数量
            // 2. 检查函数体内调用的方法是否在 trait 的方法列表中
            // 3. 检查调用点是否有对应的 impl
        } else {
            // Trait 未定义
            self.addErrorAt(.unsatisfied_bound, location.line, location.column, "trait '{s}' is not defined", .{bound.trait_name});
        }
    }
};
