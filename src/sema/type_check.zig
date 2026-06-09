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
    adt_types: std.StringHashMap(*Type),
    /// Trait 类型注册表
    trait_types: std.StringHashMap(*Type),

    pub fn init(allocator: std.mem.Allocator) TypeInferencer {
        return TypeInferencer{
            .allocator = allocator,
            .type_vars = std.ArrayList(*TypeVar).empty,
            .types = std.ArrayList(*Type).empty,
            .adt_types = std.StringHashMap(*Type).init(allocator),
            .trait_types = std.StringHashMap(*Type).init(allocator),
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
            var iter = self.adt_types.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.adt_types.deinit();
        }
        {
            var iter = self.trait_types.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.trait_types.deinit();
        }
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
        const t = try self.allocator.create(Type);
        t.* = Type{ .fn_type = .{ .params = params, .return_type = return_type } };
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
        const t = try self.allocator.create(Type);
        t.* = Type{ .adt_type = .{ .name = name, .type_args = type_args } };
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
            .null_literal => self.makeType(.null_type),
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
                // ? 操作符：T? -> T, Throw<T, E> -> T
                return inner_ty;
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
                // 查找 ADT 类型
                if (self.adt_types.get(n.name)) |adt_ty| {
                    return adt_ty;
                }
                // 未知命名类型，返回 ADT 类型占位
                return self.makeAdtType(n.name, &[_]*Type{});
            },
            .generic => |g| {
                var args = try self.allocator.alloc(*Type, g.args.len);
                for (g.args, 0..) |arg, i| {
                    args[i] = try self.typeFromAst(arg);
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
                const inner = try self.typeFromAst(n.inner);
                return self.makeNullableType(inner);
            },
            .function => |f| {
                var params = try self.allocator.alloc(*Type, f.params.len);
                for (f.params, 0..) |p, i| {
                    params[i] = try self.typeFromAst(p);
                }
                const ret = try self.typeFromAst(f.return_type);
                return self.makeFnType(params, ret);
            },
            .record => |r| {
                var fields = try self.allocator.alloc(FieldType, r.fields.len);
                for (r.fields, 0..) |f, i| {
                    fields[i] = FieldType{
                        .name = f.name,
                        .ty = try self.typeFromAst(f.ty),
                    };
                }
                const t = try self.allocator.create(Type);
                t.* = Type{ .record_type = .{ .fields = fields } };
                try self.types.append(self.allocator, t);
                return t;
            },
            .kind_annotated => |ka| {
                return self.typeFromAst(ka.inner);
            },
        }
    }

    // ============================================================
    // 模块级类型检查
    // ============================================================

    /// 对模块进行类型检查
    pub fn checkModule(self: *TypeInferencer, module: *const ast.Module) SemaError!void {
        var env = TypeEnv.init(self.allocator);
        defer env.deinit();

        for (module.declarations) |decl| {
            try self.checkDecl(decl, &env);
        }
    }

    /// 对声明进行类型检查
    pub fn checkDecl(self: *TypeInferencer, decl: ast.Decl, env: *TypeEnv) SemaError!void {
        switch (decl) {
            .fun_decl => |f| {
                const child_env = try env.createChild();
                var param_types = try self.allocator.alloc(*Type, f.params.len);
                for (f.params, 0..) |param, i| {
                    const param_ty = if (param.type_annotation) |ta|
                        try self.typeFromAst(ta)
                    else
                        try self.freshTypeVar();
                    param_types[i] = param_ty;
                    const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = param_ty };
                    try child_env.define(param.name, scheme);
                }

                const body_ty = try self.inferExpr(f.body, child_env);

                const fn_ty = try self.makeFnType(param_types, body_ty);

                if (f.return_type) |ret_type| {
                    const expected_ret = try self.typeFromAst(ret_type);
                    try self.unify(fn_ty.fn_type.return_type, expected_ret);
                }

                const scheme = try self.generalize(env, fn_ty);
                try env.define(f.name, scheme);
            },
            .type_decl => |td| {
                switch (td.def) {
                    .adt => |adt_def| {
                        const adt_ty = try self.makeAdtType(td.name, &[_]*Type{});
                        const key = try self.allocator.dupe(u8, td.name);
                        try self.adt_types.put(key, adt_ty);

                        // 注册每个构造器的类型
                        for (adt_def.constructors) |con| {
                            if (con.fields.len == 0) {
                                // 无参构造器：类型就是 ADT 类型
                                const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = adt_ty };
                                try env.define(con.name, scheme);
                            } else {
                                // 有参构造器：参数类型 -> ADT 类型
                                var param_types = try self.allocator.alloc(*Type, con.fields.len);
                                for (con.fields, 0..) |field, i| {
                                    param_types[i] = try self.typeFromAst(field.ty);
                                }
                                const ctor_ty = try self.makeFnType(param_types, adt_ty);
                                const scheme = try self.generalize(env, ctor_ty);
                                try env.define(con.name, scheme);
                            }
                        }
                    },
                    .record => |rec_def| {
                        var fields = try self.allocator.alloc(FieldType, rec_def.fields.len);
                        for (rec_def.fields, 0..) |f, i| {
                            fields[i] = FieldType{
                                .name = f.name,
                                .ty = try self.typeFromAst(f.ty),
                            };
                        }
                        const rec_ty = try self.allocator.create(Type);
                        rec_ty.* = Type{ .record_type = .{ .fields = fields } };
                        try self.types.append(self.allocator, rec_ty);

                        // 注册构造器
                        var param_types = try self.allocator.alloc(*Type, rec_def.fields.len);
                        for (rec_def.fields, 0..) |f, i| {
                            param_types[i] = try self.typeFromAst(f.ty);
                        }
                        const ctor_ty = try self.makeFnType(param_types, rec_ty);
                        const scheme = try self.generalize(env, ctor_ty);
                        try env.define(td.name, scheme);
                    },
                    .alias => {
                        // 类型别名：不创建新类型
                    },
                    .newtype => |nt| {
                        const inner_ty = try self.typeFromAst(nt.inner);
                        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = inner_ty };
                        try env.define(nt.name, scheme);
                    },
                    .error_newtype => {
                        // 错误 newtype：Throw 类型
                    },
                }
            },
            .trait_decl => |td| {
                const trait_ty = try self.allocator.create(Type);
                trait_ty.* = Type{ .trait_type = .{ .name = td.name, .type_args = &[_]*Type{} } };
                try self.types.append(self.allocator, trait_ty);
                const key = try self.allocator.dupe(u8, td.name);
                try self.trait_types.put(key, trait_ty);
            },
            .impl_decl => {
                // Impl 声明：验证方法签名与 trait 一致
                // Phase 2 简化处理
            },
            .use_decl => {
                // use 声明：类型检查在模块加载时处理
            },
            .pack_decl => {
                // pack 声明：模块系统处理
            },
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    _ = try self.inferStmt(s, env);
                } else {
                    _ = try self.inferExpr(ed.expr, env);
                }
            },
        }
    }
};
