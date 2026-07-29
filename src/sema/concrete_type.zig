//! ConcreteType：sema 的统一类型表示。
//!
//! 替代旧的 HM Type 系统。保留 type_var/unify/occurs/resolve 用于局部推断
//! （null 字面量、未标注 lambda 参数），废弃 generalize/instantiate/TypeScheme
//! （泛型显式声明，无自动泛化）。

const std = @import("std");
const ir = @import("ir");

/// 类型变量（用于局部推断，非 HM 量化）
pub const TypeVar = struct {
    id: usize,
    bound: ?*ConcreteType = null, // 统一后的绑定
    is_rigid: bool = false, // 泛型参数声明为 rigid（不可与不同类型统一）

    /// 兼容旧 HM 代码的全局计数器初始化（freshTypeVar 方法路径使用）。
    /// 新代码应优先使用 TypeAllocator.freshTypeVar/freshRigidVar。
    var next_id: usize = 0;

    pub fn init() TypeVar {
        const id = next_id;
        next_id += 1;
        return TypeVar{ .id = id };
    }
};

/// ConcreteType 统一类型表示
pub const ConcreteType = union(enum) {
    // 标量类型
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
    /// 发散类型：return/throw 等早退路径
    never_type,

    // 局部推断用类型变量
    type_var: *TypeVar,

    // 复合类型
    fn_type: struct {
        params: []*ConcreteType,
        return_type: *ConcreteType,
    },
    record_type: struct {
        fields: []FieldType,
        name: ?[]const u8 = null,
    },
    adt_type: struct {
        name: []const u8,
        type_args: []*ConcreteType,
    },
    nullable_type: *ConcreteType,
    generic_type: struct {
        name: []const u8,
        args: []*ConcreteType,
    },
    array_type: struct {
        element_type: *ConcreteType,
        size: ?u64,
    },
    throw_type: struct {
        value_type: *ConcreteType,
        error_type: *ConcreteType,
    },
    trait_type: struct {
        name: []const u8,
        type_args: []*ConcreteType,
    },
    ref_type: struct {
        inner: *ConcreteType,
        is_raw: bool,
    },
    unknown_type,

    pub const FieldType = struct {
        name: ?[]const u8, // null = positional
        ty: *ConcreteType,
    };

    // ── 分类谓词 ──

    pub fn isIntType(self: ConcreteType) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type,
            .u8_type, .u16_type, .u32_type, .u64_type, .u128_type,
            .isize_type, .usize_type => true,
            else => false,
        };
    }

    pub fn isFloatType(self: ConcreteType) bool {
        return switch (self) {
            .f16_type, .f32_type, .f64_type, .f128_type => true,
            else => false,
        };
    }

    pub fn isNumericType(self: ConcreteType) bool {
        return self.isIntType() or self.isFloatType();
    }

    pub fn intTypeBitWidth(self: ConcreteType) ?u16 {
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

    pub fn floatTypeBitWidth(self: ConcreteType) ?u16 {
        return switch (self) {
            .f16_type => 16,
            .f32_type => 32,
            .f64_type => 64,
            .f128_type => 128,
            else => null,
        };
    }

    /// 提取类型名（用于 ExprInfo.type_name）
    pub fn typeName(self: *const ConcreteType) ?[]const u8 {
        return switch (self.*) {
            .adt_type => |at| at.name,
            .generic_type => |gt| gt.name,
            .trait_type => |tt| tt.name,
            .ref_type => |rt| rt.inner.typeName(),
            .nullable_type => |inner| inner.typeName(),
            .i8_type => "i8",
            .i16_type => "i16",
            .i32_type => "i32",
            .i64_type => "i64",
            .i128_type => "i128",
            .u8_type => "u8",
            .u16_type => "u16",
            .u32_type => "u32",
            .u64_type => "u64",
            .u128_type => "u128",
            .isize_type => "isize",
            .usize_type => "usize",
            .f16_type => "f16",
            .f32_type => "f32",
            .f64_type => "f64",
            .f128_type => "f128",
            .bool_type => "bool",
            .str_type => "str",
            .char_type => "char",
            .unit_type => "void",
            .null_type => "Null",
            else => null,
        };
    }

    /// 仅返回 22 种内置标量类型名，复合类型返回 null。
    /// 用于 format 方法区分"内置类型直接输出名"与"复合类型走 switch 格式化"。
    pub fn builtinName(self: ConcreteType) ?[]const u8 {
        return switch (self) {
            .i8_type => "i8",
            .i16_type => "i16",
            .i32_type => "i32",
            .i64_type => "i64",
            .i128_type => "i128",
            .u8_type => "u8",
            .u16_type => "u16",
            .u32_type => "u32",
            .u64_type => "u64",
            .u128_type => "u128",
            .isize_type => "isize",
            .usize_type => "usize",
            .f16_type => "f16",
            .f32_type => "f32",
            .f64_type => "f64",
            .f128_type => "f128",
            .bool_type => "bool",
            .str_type => "str",
            .char_type => "char",
            .unit_type => "void",
            .null_type => "Null",
            else => null,
        };
    }

    /// 整数是否为有符号类型
    pub fn isSignedIntType(self: ConcreteType) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type, .i128_type, .isize_type => true,
            else => false,
        };
    }

    /// int→float 精确 widening 路径表（spec §4.2）
    pub fn intToFloatWidening(int_ty: ConcreteType, float_ty: ConcreteType) bool {
        const platform_bits: u16 = @intCast(@bitSizeOf(isize));
        return switch (int_ty) {
            .i8_type, .u8_type, .i16_type, .u16_type => switch (float_ty) {
                .f32_type, .f64_type, .f128_type => true,
                else => false,
            },
            .i32_type, .u32_type => switch (float_ty) {
                .f64_type, .f128_type => true,
                else => false,
            },
            .i64_type, .u64_type => switch (float_ty) {
                .f128_type => true,
                else => false,
            },
            .i128_type, .u128_type => false,
            .isize_type, .usize_type => blk: {
                const equiv: ConcreteType = if (platform_bits <= 32)
                    if (int_ty == .isize_type) .i32_type else .u32_type
                else
                    if (int_ty == .isize_type) .i64_type else .u64_type;
                break :blk intToFloatWidening(equiv, float_ty);
            },
            else => false,
        };
    }

    /// 格式化类型到 writer（用于错误消息）
    pub fn format(self: ConcreteType, writer: anytype) !void {
        if (self.builtinName()) |name| {
            if (self == .unit_type) {
                try writer.writeAll("void");
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
                    if (field.name) |name| {
                        try writer.print("{s}: ", .{name});
                    }
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
            .never_type => try writer.writeAll("!"),
            else => unreachable,
        }
    }

    /// 格式化类型到 ArrayList（用于需要分配的场景）
    pub fn formatArrayList(self: ConcreteType, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        if (self.builtinName()) |name| {
            if (self == .unit_type) {
                try buf.appendSlice(allocator, "void");
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
                    if (field.name) |name| {
                        try buf.print(allocator, "{s}: ", .{name});
                    }
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
            .never_type => try buf.appendSlice(allocator, "!"),
            else => unreachable,
        }
    }
};

/// 类型环境（替代旧 TypeEnv，无 TypeScheme）
pub const ConcreteEnv = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(*ConcreteType),
    parent: ?*ConcreteEnv,

    pub fn init(allocator: std.mem.Allocator) ConcreteEnv {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(*ConcreteType).init(allocator),
            .parent = null,
        };
    }

    pub fn deinit(self: *ConcreteEnv) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn createChild(self: *ConcreteEnv) !*ConcreteEnv {
        const child = try self.allocator.create(ConcreteEnv);
        child.* = ConcreteEnv.init(self.allocator);
        child.parent = self;
        return child;
    }

    pub fn define(self: *ConcreteEnv, name: []const u8, ty: *ConcreteType) !void {
        if (self.bindings.contains(name)) return error.DuplicateDefinition;
        const key = try self.allocator.dupe(u8, name);
        try self.bindings.put(key, ty);
    }

    pub fn lookup(self: *ConcreteEnv, name: []const u8) ?*ConcreteType {
        if (self.bindings.get(name)) |ty| return ty;
        if (self.parent) |parent| return parent.lookup(name);
        return null;
    }
};

// ── unify / occurs / resolve（保留 HM 局部推断能力）──

pub const UnifyError = error{
    TypeMismatch,
    OccursCheckFailed,
    RecursiveType,
    OutOfMemory,
};

/// 解析 type_var 的最终绑定
pub fn resolve(ty: *ConcreteType) *ConcreteType {
    var current = ty;
    while (current.* == .type_var) {
        const tv = current.type_var;
        if (tv.bound) |bound| {
            current = bound;
        } else {
            break;
        }
    }
    return current;
}

/// occurs check：防止 type_var 出现在 ty 中（避免无限类型）
pub fn occurs(var_id: usize, ty: *const ConcreteType) bool {
    return switch (ty.*) {
        .type_var => |tv| tv.id == var_id,
        .fn_type => |ft| {
            for (ft.params) |p| if (occurs(var_id, p)) return true;
            return occurs(var_id, ft.return_type);
        },
        .record_type => |rt| {
            for (rt.fields) |f| if (occurs(var_id, f.ty)) return true;
            return false;
        },
        .nullable_type => |inner| occurs(var_id, inner),
        .ref_type => |rt| occurs(var_id, rt.inner),
        .adt_type => |at| {
            for (at.type_args) |arg| if (occurs(var_id, arg)) return true;
            return false;
        },
        .throw_type => |tt| occurs(var_id, tt.value_type) or occurs(var_id, tt.error_type),
        .generic_type => |gt| {
            for (gt.args) |arg| if (occurs(var_id, arg)) return true;
            return false;
        },
        .trait_type => |tt| {
            for (tt.type_args) |arg| if (occurs(var_id, arg)) return true;
            return false;
        },
        .array_type => |at| occurs(var_id, at.element_type),
        else => false,
    };
}

/// 统一两个类型（in-place 修改 type_var.bound）
pub fn unify(t1: *ConcreteType, t2: *ConcreteType) UnifyError!void {
    const a = resolve(t1);
    const b = resolve(t2);

    // 相同引用 → 成功
    if (a == b) return;

    // type_var 绑定
    if (a.* == .type_var) {
        const tv = a.type_var;
        if (tv.is_rigid) {
            // rigid var 只能与自身或另一个相同 id 的 var 统一
            if (b.* == .type_var and b.type_var.id == tv.id) return;
            return error.TypeMismatch;
        }
        if (occurs(tv.id, b)) return error.OccursCheckFailed;
        tv.bound = b;
        return;
    }
    if (b.* == .type_var) {
        const tv = b.type_var;
        if (tv.is_rigid) {
            return error.TypeMismatch;
        }
        if (occurs(tv.id, a)) return error.OccursCheckFailed;
        tv.bound = a;
        return;
    }

    // never_type 与任何类型统一为对方
    if (a.* == .never_type) {
        t1.* = b.*;
        return;
    }
    if (b.* == .never_type) {
        t2.* = a.*;
        return;
    }

    // unknown_type 与任何类型统一为对方（类似 never_type）
    if (a.* == .unknown_type) {
        t1.* = b.*;
        return;
    }
    if (b.* == .unknown_type) {
        t2.* = a.*;
        return;
    }

    // 结构化统一
    switch (a.*) {
        .i8_type => if (b.* == .i8_type) return,
        .i16_type => if (b.* == .i16_type) return,
        .i32_type => if (b.* == .i32_type) return,
        .i64_type => if (b.* == .i64_type) return,
        .i128_type => if (b.* == .i128_type) return,
        .u8_type => if (b.* == .u8_type) return,
        .u16_type => if (b.* == .u16_type) return,
        .u32_type => if (b.* == .u32_type) return,
        .u64_type => if (b.* == .u64_type) return,
        .u128_type => if (b.* == .u128_type) return,
        .isize_type => if (b.* == .isize_type) return,
        .usize_type => if (b.* == .usize_type) return,
        .f16_type => if (b.* == .f16_type) return,
        .f32_type => if (b.* == .f32_type) return,
        .f64_type => if (b.* == .f64_type) return,
        .f128_type => if (b.* == .f128_type) return,
        .bool_type => if (b.* == .bool_type) return,
        .str_type => if (b.* == .str_type) return,
        .char_type => if (b.* == .char_type) return,
        .null_type => if (b.* == .null_type) return,
        .unit_type => if (b.* == .unit_type) return,

        .fn_type => |fa| {
            if (b.* != .fn_type) return error.TypeMismatch;
            const fb = b.fn_type;
            if (fa.params.len != fb.params.len) return error.TypeMismatch;
            for (fa.params, fb.params) |pa, pb| try unify(pa, pb);
            try unify(fa.return_type, fb.return_type);
            return;
        },
        .record_type => |ra| {
            if (b.* != .record_type) return error.TypeMismatch;
            const rb = b.record_type;
            if (ra.fields.len != rb.fields.len) return error.TypeMismatch;
            for (ra.fields, rb.fields) |fa, fb| try unify(fa.ty, fb.ty);
            return;
        },
        .nullable_type => |inner_a| {
            if (b.* != .nullable_type) return error.TypeMismatch;
            try unify(inner_a, b.nullable_type);
            return;
        },
        .ref_type => |ra| {
            if (b.* != .ref_type) return error.TypeMismatch;
            const rb = b.ref_type;
            if (ra.is_raw != rb.is_raw) return error.TypeMismatch;
            try unify(ra.inner, rb.inner);
            return;
        },
        .adt_type => |aa| {
            if (b.* != .adt_type) return error.TypeMismatch;
            const ab = b.adt_type;
            if (!std.mem.eql(u8, aa.name, ab.name)) return error.TypeMismatch;
            if (aa.type_args.len != ab.type_args.len) return error.TypeMismatch;
            for (aa.type_args, ab.type_args) |ta, tb| try unify(ta, tb);
            return;
        },
        .generic_type => |ga| {
            if (b.* != .generic_type) return error.TypeMismatch;
            const gb = b.generic_type;
            if (!std.mem.eql(u8, ga.name, gb.name)) return error.TypeMismatch;
            if (ga.args.len != gb.args.len) return error.TypeMismatch;
            for (ga.args, gb.args) |ta, tb| try unify(ta, tb);
            return;
        },
        .trait_type => |ta| {
            if (b.* != .trait_type) return error.TypeMismatch;
            const tb = b.trait_type;
            if (!std.mem.eql(u8, ta.name, tb.name)) return error.TypeMismatch;
            if (ta.type_args.len != tb.type_args.len) return error.TypeMismatch;
            for (ta.type_args, tb.type_args) |ea, eb| try unify(ea, eb);
            return;
        },
        .array_type => |aa| {
            if (b.* != .array_type) return error.TypeMismatch;
            const ab = b.array_type;
            try unify(aa.element_type, ab.element_type);
            return;
        },
        .throw_type => |ta| {
            if (b.* != .throw_type) return error.TypeMismatch;
            const tb = b.throw_type;
            try unify(ta.value_type, tb.value_type);
            try unify(ta.error_type, tb.error_type);
            return;
        },
        .type_var, .unknown_type, .never_type => unreachable, // 已在前面处理
    }
    return error.TypeMismatch;
}

// ── TypeAllocator：ConcreteType 分配器 ──

/// ConcreteType 分配器（arena-based，管理 type_var id 分配）
pub const TypeAllocator = struct {
    arena: std.heap.ArenaAllocator,
    next_var_id: usize = 0,
    type_vars: std.ArrayList(*TypeVar),

    pub fn init(child_allocator: std.mem.Allocator) TypeAllocator {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .next_var_id = 0,
            .type_vars = std.ArrayList(*TypeVar).empty,
        };
    }

    pub fn deinit(self: *TypeAllocator) void {
        self.type_vars.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn allocator(self: *TypeAllocator) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 创建新的类型变量（非 rigid，用于局部推断）
    pub fn freshTypeVar(self: *TypeAllocator) !*ConcreteType {
        const tv = try self.arena.allocator().create(TypeVar);
        tv.* = .{ .id = self.next_var_id, .bound = null, .is_rigid = false };
        self.next_var_id += 1;
        try self.type_vars.append(self.arena.allocator(), tv);
        const ty = try self.arena.allocator().create(ConcreteType);
        ty.* = .{ .type_var = tv };
        return ty;
    }

    /// 创建 rigid 类型变量（泛型参数声明，不可与不同类型统一）
    pub fn freshRigidVar(self: *TypeAllocator) !*ConcreteType {
        const tv = try self.arena.allocator().create(TypeVar);
        tv.* = .{ .id = self.next_var_id, .bound = null, .is_rigid = true };
        self.next_var_id += 1;
        try self.type_vars.append(self.arena.allocator(), tv);
        const ty = try self.arena.allocator().create(ConcreteType);
        ty.* = .{ .type_var = tv };
        return ty;
    }

    /// 分配 ConcreteType（arena）
    pub fn make(self: *TypeAllocator, ct: ConcreteType) !*ConcreteType {
        const ty = try self.arena.allocator().create(ConcreteType);
        ty.* = ct;
        return ty;
    }

    /// 从标量类型名反向构造 ConcreteType（用于内置类型）
    pub fn fromScalarName(self: *TypeAllocator, name: []const u8) !*ConcreteType {
        const Entry = struct { n: []const u8, t: ConcreteType };
        const table = [_]Entry{
            .{ .n = "i8", .t = .i8_type },
            .{ .n = "i16", .t = .i16_type },
            .{ .n = "i32", .t = .i32_type },
            .{ .n = "i64", .t = .i64_type },
            .{ .n = "i128", .t = .i128_type },
            .{ .n = "u8", .t = .u8_type },
            .{ .n = "u16", .t = .u16_type },
            .{ .n = "u32", .t = .u32_type },
            .{ .n = "u64", .t = .u64_type },
            .{ .n = "u128", .t = .u128_type },
            .{ .n = "isize", .t = .isize_type },
            .{ .n = "usize", .t = .usize_type },
            .{ .n = "f16", .t = .f16_type },
            .{ .n = "f32", .t = .f32_type },
            .{ .n = "f64", .t = .f64_type },
            .{ .n = "f128", .t = .f128_type },
            .{ .n = "bool", .t = .bool_type },
            .{ .n = "char", .t = .char_type },
            .{ .n = "Null", .t = .null_type },
            .{ .n = "void", .t = .unit_type },
        };
        for (table) |e| {
            if (std.mem.eql(u8, e.n, name)) return self.make(e.t);
        }
        return self.make(.unknown_type);
    }
};


