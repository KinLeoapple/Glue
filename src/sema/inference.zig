//! 语义推断：泛型实参/字段类型/方法分派/反射元信息
//!
//! v3 spec §5.1: 迁自 builder.zig 的 infer* 函数。
//! 职责：在 sema 阶段完成所有语义推断，产出 SemaResult 的元信息表。
//!
//! 迁移状态：
//! - 纯 sema 依赖的 infer* 函数已迁入（inferChanTypeFromExpr 等）
//! - 依赖 IRBuilder 运行时状态的函数仍由 IRBuilder 处理（见文件末尾"待迁移"清单）
//! - sema 侧不再保留 stub/简化版（避免双轨制），IRBuilder 侧为唯一实现

const std = @import("std");
const ast = @import("ast");
const ir_mod = @import("ir");
const type_descriptor_mod = @import("type_descriptor.zig");
const type_resolver = @import("type_resolver.zig");
const builtin_types = @import("builtin_types.zig");

const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const SemaResult = ir_mod.SemaResult;
const ir_td = ir_mod.type_descriptor_mod;

/// 类型绑定（迁自 builder.zig:160 BoundType）
/// 泛型实例化时，type_param 名 → 具体 TypeDescriptor 的映射
pub const BoundType = struct {
    type_desc: *const TypeDescriptor,
};

/// 类型绑定栈帧（迁自 builder.zig:156 TypeBinding）
pub const TypeBindingFrame = struct {
    map: std.StringHashMap(BoundType),
};

/// 类型绑定上下文：管理泛型实例化期间的类型参数绑定
/// 迁自 IRBuilder.type_binding_stack（builder.zig:232）
pub const TypeBindingContext = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(TypeBindingFrame),

    pub fn init(allocator: std.mem.Allocator) TypeBindingContext {
        return .{
            .allocator = allocator,
            .stack = std.ArrayList(TypeBindingFrame).init(allocator),
        };
    }

    pub fn deinit(self: *TypeBindingContext) void {
        for (self.stack.items) |*frame| {
            frame.map.deinit();
        }
        self.stack.deinit();
    }

    /// 压入类型绑定（迁自 builder.zig:9758 pushTypeBinding）
    pub fn push(self: *TypeBindingContext, type_params: []const ast.TypeParam, type_args: []const TypeDescriptor) !void {
        var frame = TypeBindingFrame{ .map = std.StringHashMap(BoundType).init(self.allocator) };
        for (type_params, type_args) |tp, ta| {
            try frame.map.put(tp.name, .{ .type_desc = ta });
        }
        try self.stack.append(frame);
    }

    /// 弹出类型绑定（迁自 builder.zig:9774 popTypeBinding）
    pub fn pop(self: *TypeBindingContext) void {
        if (self.stack.items.len == 0) return;
        var frame = self.stack.pop();
        frame.map.deinit();
    }

    /// 查找类型绑定（迁自 builder.zig:9714 lookupTypeBinding）
    /// 从栈顶向下查找，内层绑定优先
    pub fn lookup(self: *const TypeBindingContext, name: []const u8) ?BoundType {
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.stack.items[i].map.get(name)) |bt| {
                return bt;
            }
        }
        return null;
    }

    /// 当前栈顶深度
    pub fn depth(self: *const TypeBindingContext) usize {
        return self.stack.items.len;
    }
};

// ════════════════════════════════════════════════════════════
// InferContext：sema 阶段语义推断所需的上下文
// ════════════════════════════════════════════════════════════

/// 语义推断上下文：封装 sema 阶段可用的所有信息
///
/// 迁移自 IRBuilder 的内部状态子集，仅包含 sema 阶段已知的信息：
/// - sema_result: 语义分析产物（ExprInfo/TypeDef/FuncSig 等）
/// - module: AST 模块（用于查找 fun_decl/type_decl 的 AST 节点）
/// - arena: 临时分配器（生命周期与 sema 一致）
/// - type_binding_ctx: 泛型实例化的类型参数绑定
///
/// 不包含 IRBuilder 运行时状态（变量绑定/通道表/函数表），因此
/// 依赖这些状态的 infer* 函数仍保留在 IRBuilder 中。
pub const InferContext = struct {
    sema_result: *const SemaResult,
    module: *const ast.Module,
    arena: std.mem.Allocator,
    type_binding_ctx: ?*const TypeBindingContext = null,

    /// 构建 func_name → *const ast.Decl 映射（仅顶层 fun_decl）
    /// 用于 inferTypeArgs 等函数查找参数类型注解
    pub fn buildFuncDeclMap(self: *const InferContext, allocator: std.mem.Allocator) !std.StringHashMap(*const ast.Decl) {
        var map = std.StringHashMap(*const ast.Decl).init(allocator);
        for (self.module.declarations) |*decl| {
            switch (decl.*) {
                .fun_decl => |fd| try map.put(fd.name, decl),
                else => {},
            }
        }
        return map;
    }
};

// ════════════════════════════════════════════════════════════
// 已迁移的 infer* 函数（纯 sema 依赖）
// ════════════════════════════════════════════════════════════

/// 从表达式推断通道类型
///
/// 迁自 builder.zig:3713 inferChanTypeFromExpr
/// 仅依赖 sema_result.expr_types，无 IRBuilder 状态依赖
pub fn inferChanTypeFromExpr(ctx: *const InferContext, expr: *const ast.Expr) ?*const TypeDescriptor {
    if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
        return info.type_desc;
    }
    return null;
}

/// 从构造器名 + 字段名推断字段通道类型
///
/// 迁自 builder.zig:3612 inferFieldTypeByCtor
/// 仅依赖 sema_result.ctor_def_index
pub fn inferFieldTypeByCtor(ctx: *const InferContext, type_name: []const u8, field: []const u8) ?*const TypeDescriptor {
    const ctor = ctx.sema_result.getCtorDef(type_name) orelse return null;
    for (ctor.field_names, 0..) |fname, i| {
        if (fname) |fn_str| {
            if (std.mem.eql(u8, fn_str, field)) {
                if (i < ctor.field_type_descs.len) return ctor.field_type_descs[i];
                return null;
            }
        }
    }
    return null;
}

/// 判断表达式是否为引用类型（&T / *T）
///
/// 迁自 builder.zig:3723 isRefExpr
/// 仅依赖 sema_result.expr_types
pub fn isRefExpr(ctx: *const InferContext, expr: *const ast.Expr) bool {
    if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
        return info.is_ref_type;
    }
    return false;
}

/// 从表达式推断类型名
///
/// 迁自 builder.zig:7981 inferTypeNameFromExpr（sema 回退路径）
/// 此版本仅实现 sema_result 可达的部分，IRBuilder 中的完整实现
/// 还回退到变量绑定/模块引用/方法调用等运行时状态
pub fn inferTypeNameFromExpr(ctx: *const InferContext, expr: *const ast.Expr) ?[]const u8 {
    if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
        if (info.type_name) |tn| return tn;
    }
    // 回退：nullary 构造器标识符（如 Lt/Eq/Gt）sema 推导为 fn_type，
    // type_name 为 null。从 ctor_def_index 查构造器的 type_name。
    if (expr.* == .identifier) {
        if (ctx.sema_result.getCtorDef(expr.identifier.name)) |ctor| {
            return ctor.type_name;
        }
    }
    return null;
}

/// 从表达式推断 Trait 类型名
///
/// 迁自 builder.zig:8108 inferTraitNameFromExpr（sema 路径）
/// 完整版还回退到变量绑定的 type_annotation
pub fn inferTraitNameFromExpr(ctx: *const InferContext, expr: *const ast.Expr) ?[]const u8 {
    if (expr.* == .identifier) {
        if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
            if (info.type_name) |tn| {
                if (ctx.sema_result.getTraitDef(tn) != null) return tn;
            }
        }
    }
    return null;
}

// ════════════════════════════════════════════════════════════
// 数组元素类型推断（纯 AST/sema 依赖）
// ════════════════════════════════════════════════════════════

/// 从 AST 表达式粗略推断通道类型（用于数组元素类型推断）
///
/// 迁自 builder.zig:7430 chanTypeFromExprAst
/// 纯 AST 推断，不依赖 IRBuilder 状态
pub fn chanTypeFromExprAst(expr: *const ast.Expr) *const TypeDescriptor {
    switch (expr.*) {
        .int_literal => |il| {
            if (il.suffix) |s| {
                if (builtin_types.typeDescriptorFromBuiltinName(s)) |td| return td;
            }
            return ir_td.i32_descriptor;
        },
        .float_literal => |fl| {
            if (fl.suffix) |s| {
                if (builtin_types.typeDescriptorFromBuiltinName(s)) |td| return td;
            }
            return ir_td.f32_descriptor;
        },
        .bool_literal => return ir_td.bool_descriptor,
        .string_literal, .string_interpolation => return ir_td.ref_descriptor,
        .char_literal => return ir_td.char_descriptor,
        .cast_builder => |cb| return type_resolver.resolveChanType(cb.target_type, &.{}) orelse ir_td.i64_descriptor,
        .type_cast => |tc| return type_resolver.resolveChanType(tc.target_type, &.{}) orelse ir_td.i64_descriptor,
        else => return ir_td.i64_descriptor,
    }
}

/// 推断数组字面量的元素通道类型
///
/// 迁自 builder.zig:7352 inferArrayLiteralElemType
/// 纯 AST 推断
pub fn inferArrayLiteralElemType(arr_expr: *const ast.Expr) *const TypeDescriptor {
    switch (arr_expr.*) {
        .array_literal => |al| {
            if (al.elements.len == 0) return ir_td.i64_descriptor;
            return chanTypeFromExprAst(al.elements[0]);
        },
        else => return ir_td.i64_descriptor,
    }
}

// ════════════════════════════════════════════════════════════
// 类型参数名判定（纯函数，迁自 builder.zig:4820）
// ════════════════════════════════════════════════════════════

/// 检查名称是否为类型参数（单字母大写名或 T1, T2 等）
/// 迁自 builder.zig:4820 isTypeNameParam
pub fn isTypeNameParam(name: []const u8) bool {
    if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return true;
    if (name.len == 2 and name[0] >= 'A' and name[0] <= 'Z' and (name[1] >= '0' and name[1] <= '9')) return true;
    return false;
}

/// 检查类型节点是否包含类型参数
/// 迁自 builder.zig:4805 typeNodeHasTypeParam
pub fn typeNodeHasTypeParam(type_node: *const ast.TypeNode) bool {
    return switch (type_node.*) {
        .named => |n| isTypeNameParam(n.name),
        .generic => |g| {
            for (g.args) |arg| {
                if (typeNodeHasTypeParam(arg)) return true;
            }
            return false;
        },
        .nullable => |nb| typeNodeHasTypeParam(nb.inner),
        else => false,
    };
}

// ════════════════════════════════════════════════════════════
// 桥接入口：供 IRBuilder 调用的 sema 产物查询
// ════════════════════════════════════════════════════════════

/// 解析 typeof 元信息
///
/// 迁自 builder.zig:3877 resolveTypeofMetaIndex
/// 在 sema 阶段直接解析 typeof(expr) 的 TypeDescriptor，存入 typeof_metas
pub fn resolveTypeofMeta(
    expr_id: u64,
    type_desc: *const TypeDescriptor,
    sema_result: *SemaResult,
) !void {
    try sema_result.typeof_metas.put(expr_id, .{
        .type_desc = type_desc,
    });
}

/// 解析 reflect 元信息
///
/// 迁自 builder.zig:3927 resolveReflectMetaIndex
/// 在 sema 阶段直接解析 reflect(expr) 的 TypeDescriptor，存入 reflect_metas
pub fn resolveReflectMeta(
    expr_id: u64,
    type_desc: *const TypeDescriptor,
    sema_result: *SemaResult,
) !void {
    try sema_result.reflect_metas.put(expr_id, .{
        .type_desc = type_desc,
    });
}

// ════════════════════════════════════════════════════════════
// Task 3.1-3.10: infer* 函数 sema 版（使用 sema_result + AST）
// 这些函数提供 sema 路径的实现，IRBuilder 可逐步切换调用
// ════════════════════════════════════════════════════════════

/// 变量绑定信息（用于 infer* 函数的变量回溯）
pub const VarBinding = struct {
    /// 变量声明时的类型注解（如有）
    type_annotation: ?*const ast.TypeNode = null,
    /// 变量绑定的初始化表达式（用于递归类型推断）
    ast_expr: ?*const ast.Expr = null,
};

/// 变量绑定查询接口（由调用方提供，如 IRBuilder.lookupVar 或 sema 的 ResolveCtx）
pub const VarLookupFn = *const fn (ctx: *anyopaque, name: []const u8) ?VarBinding;

/// 扩展的推断上下文：带变量绑定查询
/// 用于需要 lookupVar 的 infer* 函数
pub const InferContextExt = struct {
    base: *const InferContext,
    /// 变量绑定查询回调（由 IRBuilder 或 sema ResolveCtx 提供）
    var_lookup_ctx: ?*anyopaque = null,
    var_lookup_fn: ?VarLookupFn = null,

    /// 查询变量绑定
    pub fn lookupVar(self: *const InferContextExt, name: []const u8) ?VarBinding {
        if (self.var_lookup_fn) |fn_ptr| {
            return fn_ptr(self.var_lookup_ctx.?, name);
        }
        return null;
    }
};

/// 从字段名推断字段通道类型（完整版）
///
/// 迁自 builder.zig:3627 inferFieldType
/// 依赖：sema_result.ctor_def_index + 变量绑定回溯
pub fn inferFieldType(
    ctx: *const InferContextExt,
    object: *const ast.Expr,
    field: []const u8,
) ?*const TypeDescriptor {
    // typeof(TypeName).field 特殊处理
    if (object.* == .call and object.call.callee.* == .identifier and
        std.mem.eql(u8, object.call.callee.identifier.name, "typeof"))
    {
        return typeInfoFieldType(field);
    }
    // 回溯变量绑定获取实际表达式
    const obj_expr = switch (object.*) {
        .identifier => |id| blk: {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.ast_expr) |e| break :blk e;
            }
            break :blk null;
        },
        else => object,
    } orelse return null;

    if (obj_expr.* == .call and obj_expr.call.callee.* == .identifier and
        std.mem.eql(u8, obj_expr.call.callee.identifier.name, "typeof"))
    {
        return typeInfoFieldType(field);
    }

    switch (obj_expr.*) {
        .record_literal => |rl| {
            for (rl.fields) |f| {
                if (std.mem.eql(u8, f.name, field)) {
                    return inferChanTypeFromExpr(ctx.base, f.value);
                }
            }
        },
        .record_extend => |re| {
            for (re.updates) |f| {
                if (std.mem.eql(u8, f.name, field)) {
                    return inferChanTypeFromExpr(ctx.base, f.value);
                }
            }
            return inferFieldType(ctx, re.base, field);
        },
        .call => |c| {
            const ctor_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            const ctor = ctx.base.sema_result.getCtorDef(ctor_name) orelse return null;
            for (ctor.field_names, 0..) |fname, i| {
                if (fname) |fn_str| {
                    if (std.mem.eql(u8, fn_str, field)) {
                        if (i < c.arguments.len) {
                            return inferChanTypeFromExpr(ctx.base, c.arguments[i]);
                        }
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// TypeInfo 字段名 → 通道类型
/// 迁自 builder.zig:3704 typeInfoFieldType
fn typeInfoFieldType(field: []const u8) ?*const TypeDescriptor {
    const ref_fields = [_][]const u8{
        "name", "module", "kind", "structure", "layout", "impls", "type_params",
    };
    for (ref_fields) |f| if (std.mem.eql(u8, field, f)) return ir_td.ref_descriptor;
    return null;
}

/// 推断表达式的通道类型（完整版）
///
/// 迁自 builder.zig:4753 inferExprChanType
/// 依赖：sema_result.expr_types + func_sigs + 变量绑定
pub fn inferExprChanType(ctx: *const InferContextExt, expr: *const ast.Expr) ?*const TypeDescriptor {
    switch (expr.*) {
        .call => |c| {
            const func_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            // 构造器调用：返回 ref_chan（构造器在堆上分配，返回引用）
            if (ctx.base.sema_result.getCtorDef(func_name) != null) {
                return ir_td.ref_descriptor;
            }
            // 普通函数调用：查 func_sigs 的 return_type_desc
            if (ctx.base.sema_result.getFuncSig(func_name)) |sig| {
                return sig.return_type_desc;
            }
            return null;
        },
        .int_literal => return ir_td.i32_descriptor,
        .float_literal => return ir_td.f32_descriptor,
        .bool_literal => return ir_td.bool_descriptor,
        .string_literal => return ir_td.ref_descriptor,
        .char_literal => return ir_td.char_descriptor,
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    if (type_resolver.resolveChanType(ta, &.{})) |ct| return ct;
                }
            }
            // 回退到 sema_result.expr_types
            return inferChanTypeFromExpr(ctx.base, expr);
        },
        .binary => |b| {
            return switch (b.op) {
                .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => ir_td.mask_descriptor,
                .and_op, .or_op => ir_td.bool_descriptor,
                else => inferExprChanType(ctx, b.left),
            };
        },
        else => return null,
    }
}

/// 推断 Throw 表达式的 Ok 通道类型
///
/// 迁自 builder.zig:4611 inferThrowOkChanType
/// 依赖：sema_result.func_sigs + 变量绑定
pub fn inferThrowOkChanType(ctx: *const InferContextExt, expr: *const ast.Expr) ?*const TypeDescriptor {
    switch (expr.*) {
        .call => |c| {
            const func_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            if (ctx.base.sema_result.getFuncSig(func_name)) |sig| {
                if (sig.is_throwing) return sig.return_type_desc;
            }
            return null;
        },
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    return throwOkChanType(ta);
                }
                if (binding.ast_expr) |src_expr| {
                    return inferThrowOkChanType(ctx, src_expr);
                }
            }
            return null;
        },
        .cast_builder => |cb| {
            if (cb.mode != .try_to) return null;
            return type_resolver.resolveChanType(cb.target_type, &.{});
        },
        .method_call => |mc| {
            // await：解包 Async<T> → T
            if (std.mem.eql(u8, mc.method, "await")) {
                // 简化：sema 阶段 await 返回类型记录在 expr_types
                return inferChanTypeFromExpr(ctx.base, expr);
            }
            return inferChanTypeFromExpr(ctx.base, expr);
        },
        else => return null,
    }
}

/// 推断 Throw 表达式的 Ok 类型名
///
/// 迁自 builder.zig:4686 inferThrowOkTypeName
pub fn inferThrowOkTypeName(ctx: *const InferContextExt, expr: *const ast.Expr) ?[]const u8 {
    switch (expr.*) {
        .call => |c| {
            const func_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            // 从 sema_result.expr_types 查返回类型名
            if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
                if (info.type_name) |tn| return tn;
            }
            _ = func_name;
            return null;
        },
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    return throwOkTypeName(ta);
                }
                if (binding.ast_expr) |src_expr| {
                    return inferThrowOkTypeName(ctx, src_expr);
                }
            }
            return null;
        },
        .cast_builder => |cb| {
            if (cb.mode != .try_to) return null;
            return type_resolver.typeNameFromNode(cb.target_type);
        },
        .propagate => |p| return inferThrowOkTypeName(ctx, p.expr),
        else => return null,
    }
}

/// 从 TypeNode 提取 Throw Ok 的 TypeDescriptor
/// 迁自 builder.zig throwOkChanType
fn throwOkChanType(tn: *const ast.TypeNode) ?*const TypeDescriptor {
    return switch (tn.*) {
        .named => |n| {
            // Throw<T> → T 的 TypeDescriptor
            if (std.mem.eql(u8, n.name, "Throw")) return null; // 需要类型参数
            return type_resolver.chanTypeFromTypeName(n.name);
        },
        else => type_resolver.resolveChanType(tn, &.{}),
    };
}

/// 从 TypeNode 提取 Throw Ok 的类型名
/// 迁自 builder.zig throwOkTypeName
fn throwOkTypeName(tn: *const ast.TypeNode) ?[]const u8 {
    return switch (tn.*) {
        .named => |n| n.name,
        .generic => |g| g.name,
        else => null,
    };
}

/// 推断数组元素类型
///
/// 迁自 builder.zig:7373 inferArrayElemType
/// 依赖：sema_result.expr_types + 变量绑定
/// 支持：array_literal、identifier、method_call（s.bytes() → u8_chan）、binary.concat_list、field_access
pub fn inferArrayElemType(ctx: *const InferContextExt, expr: *const ast.Expr) *const TypeDescriptor {
    switch (expr.*) {
        .array_literal => return inferArrayLiteralElemType(expr),
        .method_call => |mc| {
            // s.bytes() 返回 u8[]
            if (std.mem.eql(u8, mc.method, "bytes")) return ir_td.u8_descriptor;
            return ir_td.i64_descriptor;
        },
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    if (ta.* == .array) return type_resolver.resolveChanType(ta.array.element_type, &.{}) orelse ir_td.i64_descriptor;
                }
                if (binding.ast_expr) |src_expr| {
                    return inferArrayElemType(ctx, src_expr);
                }
            }
            return ir_td.i64_descriptor;
        },
        .binary => |b| {
            // a ++ b：递归推断左操作数元素类型
            if (b.op == .concat_list) {
                return inferArrayElemType(ctx, b.left);
            }
            return ir_td.i64_descriptor;
        },
        .field_access => |fa| {
            // newtype/record 字段访问：通过 sema_result 查字段类型，推断数组元素类型
            if (inferFieldArrayElemType(ctx, fa.object, fa.field)) |et| {
                return et;
            }
            return ir_td.i64_descriptor;
        },
        else => return ir_td.i64_descriptor,
    }
}

/// 推断字段数组元素类型
///
/// 迁自 builder.zig:7416 inferFieldArrayElemType
pub fn inferFieldArrayElemType(
    ctx: *const InferContextExt,
    object: *const ast.Expr,
    field: []const u8,
) ?*const TypeDescriptor {
    const type_name = inferTypeNameFromExprComplete(ctx, object) orelse return null;
    // 查类型定义的字段类型
    if (ctx.base.sema_result.getCtorDef(type_name)) |ctor| {
        for (ctor.field_names, 0..) |fname, i| {
            if (fname) |fn_str| {
                if (std.mem.eql(u8, fn_str, field)) {
                    if (i < ctor.field_type_descs.len) return ctor.field_type_descs[i];
                }
            }
        }
    }
    return null;
}

/// 从表达式推断类型名（完整版）
///
/// 迁自 builder.zig:7989 inferTypeNameFromExpr
/// 依赖：sema_result.expr_types + 变量绑定 + 模块 AST
pub fn inferTypeNameFromExprComplete(
    ctx: *const InferContextExt,
    expr: *const ast.Expr,
) ?[]const u8 {
    // 1. sema_result.expr_types
    if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
        if (info.type_name) |tn| return tn;
    }
    // 2. nullary 构造器标识符
    if (expr.* == .identifier) {
        if (ctx.base.sema_result.getCtorDef(expr.identifier.name)) |ctor| {
            return ctor.type_name;
        }
    }
    // 3. 变量绑定的类型标注
    if (expr.* == .identifier) {
        if (ctx.lookupVar(expr.identifier.name)) |binding| {
            if (binding.type_annotation) |tn| {
                return type_resolver.typeNameFromNode(tn);
            }
            // 无类型标注时，从初始化表达式递归推断
            if (binding.ast_expr) |var_expr| {
                return inferTypeNameFromExprComplete(ctx, var_expr);
            }
        }
    }
    // 4. 函数调用/方法调用：查返回类型
    switch (expr.*) {
        .call => |c| {
            if (c.callee.* == .identifier) {
                // 查 sema_result.expr_types（sema 已记录调用结果类型）
                if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
                    if (info.type_name) |tn| return tn;
                }
            }
        },
        .method_call, .safe_method_call => {
            if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
                if (info.type_name) |tn| return tn;
            }
        },
        .propagate => |p| {
            return inferThrowOkTypeName(ctx, p.expr);
        },
        else => {},
    }
    return null;
}

/// 从表达式推断 Trait 类型名（完整版）
///
/// 迁自 builder.zig:8116 inferTraitNameFromExpr
pub fn inferTraitNameFromExprComplete(
    ctx: *const InferContextExt,
    expr: *const ast.Expr,
) ?[]const u8 {
    switch (expr.*) {
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |tn| {
                    if (tn.* == .named) {
                        if (ctx.base.sema_result.getTraitDef(tn.named.name) != null) {
                            return tn.named.name;
                        }
                    }
                }
            }
            // 回退到 sema_result
            if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
                if (info.type_name) |tn| {
                    if (ctx.base.sema_result.getTraitDef(tn) != null) return tn;
                }
            }
        },
        else => {},
    }
    return null;
}

/// 推断字段访问的 type_id
///
/// 迁自 builder.zig:9875 inferFieldAccessTypeId
/// 简化版：返回字段的 type_id（0 = ref_chan）
pub fn inferFieldAccessTypeId(
    ctx: *const InferContextExt,
    fa: anytype,
) u16 {
    const obj_type_name = inferTypeNameFromExprComplete(ctx, fa.object) orelse return 0;
    if (ctx.base.sema_result.getCtorDef(obj_type_name)) |ctor| {
        for (ctor.field_names, 0..) |fname, i| {
            if (fname) |fn_str| {
                if (std.mem.eql(u8, fn_str, fa.field)) {
                    if (i < ctor.field_type_descs.len) {
                        const td = ctor.field_type_descs[i];
                        return td.type_id;
                    }
                }
            }
        }
    }
    return 0;
}

/// 推断表达式的 type_id
///
/// 迁自 builder.zig:10006 inferTypeIdFromExpr
pub fn inferTypeIdFromExpr(ctx: *const InferContextExt, expr: *const ast.Expr) u16 {
    if (ctx.base.sema_result.getExpr(@intFromPtr(expr))) |info| {
        return info.type_desc.type_id;
    }
    // field_access：递归推断
    if (expr.* == .field_access) {
        return inferFieldAccessTypeId(ctx, &expr.field_access);
    }
    return 0;
}

// ════════════════════════════════════════════════════════════
// Task 3.4: inferReturnTypeAst + findFuncReturnTypeAst
// 纯 AST 遍历，仅依赖 module
// ════════════════════════════════════════════════════════════

/// 从模块 AST 查找函数的返回类型 TypeNode
/// 迁自 builder.zig:1637 findFuncReturnTypeAst
/// 纯 AST 遍历，无 IRBuilder 状态依赖
pub fn findFuncReturnTypeAst(module: *const ast.Module, name: []const u8) ?*ast.TypeNode {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    if (dot) |idx| {
        // mangled "Type.method"：先在 type_decl 的方法中查找
        const type_name = name[0..idx];
        const method_name = name[idx + 1 ..];
        for (module.declarations) |decl| {
            switch (decl) {
                .type_decl => |td| {
                    if (!std.mem.eql(u8, td.name, type_name)) continue;
                    for (td.methods) |m| {
                        if (std.mem.eql(u8, m.name, method_name)) return m.return_type;
                    }
                },
                else => {},
            }
        }
        // 多段 mangled 名（如 "std.pack.sub.func"）是 fun_decl，按全名精确匹配
        if (std.mem.indexOfScalar(u8, method_name, '.') != null) {
            for (module.declarations) |decl| {
                switch (decl) {
                    .fun_decl => |fd| {
                        if (std.mem.eql(u8, fd.name, name)) return fd.return_type;
                    },
                    else => {},
                }
            }
        }
    } else {
        // 普通函数名
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    if (std.mem.eql(u8, fd.name, name)) return fd.return_type;
                },
                else => {},
            }
        }
    }
    return null;
}

/// 从模块 AST 查找函数的参数列表
/// 迁自 builder.zig decl_collector.zig:369 findFuncParamsAst
/// 纯 AST 遍历，无 IRBuilder 状态依赖
pub fn findFuncParamsAst(module: *const ast.Module, name: []const u8) ?[]ast.Param {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    if (dot) |idx| {
        // mangled "Type.method"：先在 type_decl 的方法中查找
        const type_name = name[0..idx];
        const method_name = name[idx + 1 ..];
        for (module.declarations) |decl| {
            switch (decl) {
                .type_decl => |td| {
                    if (!std.mem.eql(u8, td.name, type_name)) continue;
                    for (td.methods) |m| {
                        if (std.mem.eql(u8, m.name, method_name)) return m.params;
                    }
                },
                else => {},
            }
        }
        // 多段 mangled 名（如 "std.pack.sub.func"）是 fun_decl，按全名精确匹配
        if (std.mem.indexOfScalar(u8, method_name, '.') != null) {
            for (module.declarations) |decl| {
                switch (decl) {
                    .fun_decl => |fd| {
                        if (std.mem.eql(u8, fd.name, name)) return fd.params;
                    },
                    else => {},
                }
            }
        }
    } else {
        // 普通函数名
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    if (std.mem.eql(u8, fd.name, name)) return fd.params;
                },
                else => {},
            }
        }
    }
    return null;
}

/// 推断表达式的返回类型 AST 节点
/// 迁自 builder.zig:4521 inferReturnTypeAst
/// 依赖：findFuncReturnTypeAst + 变量绑定
pub fn inferReturnTypeAst(
    ctx: *const InferContextExt,
    expr: *const ast.Expr,
) ?*ast.TypeNode {
    switch (expr.*) {
        .call => |c| {
            if (c.callee.* == .identifier) {
                return findFuncReturnTypeAst(ctx.base.module, c.callee.identifier.name);
            }
            return null;
        },
        .method_call => |mc| {
            const arena_alloc = ctx.base.arena;
            if (inferTypeNameFromExprComplete(ctx, mc.object)) |type_name| {
                const mangled = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ type_name, mc.method }) catch return null;
                return findFuncReturnTypeAst(ctx.base.module, mangled);
            }
            return null;
        },
        .safe_method_call => |smc| {
            const arena_alloc = ctx.base.arena;
            if (inferTypeNameFromExprComplete(ctx, smc.object)) |type_name| {
                const mangled = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ type_name, smc.method }) catch return null;
                return findFuncReturnTypeAst(ctx.base.module, mangled);
            }
            return null;
        },
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| return @constCast(ta);
                if (binding.ast_expr) |src_expr| return inferReturnTypeAst(ctx, src_expr);
            }
            return null;
        },
        .propagate => |p| return inferReturnTypeAst(ctx, p.expr),
        else => return null,
    }
}

/// 推断 Throw 表达式的 Ok 值类型节点
/// 迁自 builder.zig:4566 inferThrowOkTypeNode
pub fn inferThrowOkTypeNode(
    ctx: *const InferContextExt,
    expr: *const ast.Expr,
) ?*ast.TypeNode {
    switch (expr.*) {
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    return throwOkTypeNode(ta);
                }
                if (binding.ast_expr) |src_expr| {
                    return inferThrowOkTypeNode(ctx, src_expr);
                }
            }
            return null;
        },
        .method_call, .call => {
            if (inferReturnTypeAst(ctx, expr)) |rt| {
                return throwOkTypeNode(rt);
            }
            return null;
        },
        .propagate => |p| return inferThrowOkTypeNode(ctx, p.expr),
        .cast_builder => |cb| {
            if (cb.mode != .try_to) return null;
            return cb.target_type;
        },
        else => return null,
    }
}

/// 从 TypeNode 提取 Throw Ok 的 TypeNode
/// 迁自 builder.zig:10270 throwOkTypeNode
fn throwOkTypeNode(type_node: ?*const ast.TypeNode) ?*ast.TypeNode {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Throw")) return null;
            if (g.args.len < 1) return null;
            return g.args[0];
        },
        else => return null,
    }
}

// ════════════════════════════════════════════════════════════
// GADT 类型推断（迁自 IRBuilder）
// ════════════════════════════════════════════════════════════
//
// GADT（Generalized Algebraic Data Type）类型推断用于：
// - match arm 内的类型参数绑定（如 Expr<T> 匹配 Add(Expr<i32>) 时推断 T=i32）
// - 构造器调用的返回类型推断（如 If(BoolLit, IntLit, IntLit) : Expr<i32>）
// - 泛型函数调用的返回类型推断（如 filter<T>(l: List<T>) : List<T>）
//
// 迁移自 IRBuilder 的 4 个目标函数 + 辅助函数：
// - pushGadtBindingsForArm / popGadtBindings（栈操作）
// - inferConstructorChanType / inferGenericCallReturnType（类型推断）
// - matchTypeParamBinding / extractCtorTypeBinding / resolveFieldTypeWithBindings
// - chanTypeWithTypeNode（类型解析）
//
// gadt_binding_stack 仍由 IRBuilder 持有内存（编译期生命周期），
// sema 通过 GadtContext.binding_stack 指针操作。

/// GADT 推断上下文：封装所有 GADT 类型推断所需的依赖
/// 由 IRBuilder 构造（栈上），传递给 sema 侧的 GADT 推断函数
pub const GadtContext = struct {
    allocator: std.mem.Allocator,
    sema_result: *const SemaResult,
    current_type_args: []const TypeDescriptor,
    current_module: ?*const ast.Module,
    /// GADT 绑定栈（IRBuilder 持有内存，sema 通过指针操作）
    binding_stack: ?*std.ArrayList(std.StringHashMap(*const TypeDescriptor)) = null,
    /// 当前函数参数类型注解（IRBuilder 持有）
    func_param_types: ?[]const ast.Param = null,
    /// 当前函数名（用于递归调用检测）
    func_name: ?[]const u8 = null,
    /// 变量绑定查询回调（复用 InferContextExt 的 VarLookupFn）
    var_lookup_ctx: ?*anyopaque = null,
    var_lookup_fn: ?VarLookupFn = null,
    /// 表达式通道类型推断回调（IR 侧设置，用于递归 inferExprChanType）
    infer_expr_ctx: ?*anyopaque = null,
    infer_expr_fn: ?*const fn (ctx: *anyopaque, expr: *const ast.Expr) ?*const TypeDescriptor = null,

    /// 查询变量绑定
    pub fn lookupVar(self: *const GadtContext, name: []const u8) ?VarBinding {
        if (self.var_lookup_fn) |fn_ptr| {
            return fn_ptr(self.var_lookup_ctx.?, name);
        }
        return null;
    }

    /// 从 sema_result 查找构造器的 return_type TypeNode（GADT 专用）
    pub fn getCtorAstReturnType(self: *const GadtContext, ctor_name: []const u8) ?*ast.TypeNode {
        const ctor = self.sema_result.getCtorDef(ctor_name) orelse return null;
        if (ctor.return_type_node) |rtn| return @constCast(rtn);
        return null;
    }

    /// 从 sema_result 查找构造器字段的 TypeNode
    pub fn getCtorAstFieldTypeNode(self: *const GadtContext, ctor_name: []const u8, field_idx: usize) ?*ast.TypeNode {
        const ctor = self.sema_result.getCtorDef(ctor_name) orelse return null;
        if (field_idx >= ctor.field_type_nodes.len) return null;
        if (ctor.field_type_nodes[field_idx]) |ftn| return @constCast(ftn);
        return null;
    }

    /// 从模块 AST 查找函数参数列表
    pub fn findFuncParamsAst(self: *const GadtContext, name: []const u8) ?[]ast.Param {
        const mod = self.current_module orelse return null;
        return @import("inference.zig").findFuncParamsAst(mod, name);
    }

    /// 从模块 AST 查找函数返回类型
    pub fn findFuncReturnTypeAst(self: *const GadtContext, name: []const u8) ?*ast.TypeNode {
        const mod = self.current_module orelse return null;
        return @import("inference.zig").findFuncReturnTypeAst(mod, name);
    }

    /// 委托 sema type_resolver 解析类型节点的通道类型
    pub fn chanTypeFromTypeNodeBound(self: *const GadtContext, type_node: ?*ast.TypeNode) ?*const TypeDescriptor {
        return type_resolver.chanTypeFromTypeNodeBound(type_node, self.current_type_args, null);
    }

    /// 检查名称是否为类型参数
    pub fn isTypeParamName(_: *const GadtContext, name: []const u8) bool {
        return isTypeNameParam(name);
    }

    /// 递归推断表达式通道类型（通过回调，避免循环依赖）
    pub fn inferExprChanType(self: *const GadtContext, expr: *const ast.Expr) ?*const TypeDescriptor {
        if (self.infer_expr_fn) |fn_ptr| {
            return fn_ptr(self.infer_expr_ctx.?, expr);
        }
        return null;
    }
};

/// 递归匹配类型参数绑定
/// param_type: 参数的类型注解（可能含泛型参数 T）
/// arg_type: 实参的通道类型
/// bindings: 输出——类型参数名 → 通道类型
pub fn matchTypeParamBinding(
    ctx: *const GadtContext,
    param_type: *ast.TypeNode,
    arg_type: *const TypeDescriptor,
    bindings: *std.StringHashMap(*const TypeDescriptor),
) void {
    switch (param_type.*) {
        .named => |n| {
            if (ctx.isTypeParamName(n.name)) {
                if (!bindings.contains(n.name)) {
                    bindings.put(n.name, arg_type) catch {};
                }
                return;
            }
        },
        .generic => {
            // 泛型类型如 Expr<T>：arg_type 是 ref_chan，类型参数绑定由 extractCtorTypeBinding 处理
        },
        .nullable => |nb| {
            matchTypeParamBinding(ctx, nb.inner, arg_type, bindings);
        },
        else => {},
    }
}

/// 从构造器调用表达式或带类型注解的标识符提取 GADT 类型参数绑定
/// 例如：Add(IntLit(3), IntLit(4)) 的 return_type 是 Expr<i32>
/// 匹配参数类型 Expr<T> → T = i32
pub fn extractCtorTypeBinding(
    ctx: *const GadtContext,
    expr: *const ast.Expr,
    param_type: ?*ast.TypeNode,
    bindings: *std.StringHashMap(*const TypeDescriptor),
) void {
    if (param_type == null) return;
    const pt = param_type.?;

    var arg_type_node: ?*ast.TypeNode = null;

    if (expr.* == .call) {
        const func_name = switch (expr.call.callee.*) {
            .identifier => |id| id.name,
            else => return,
        };
        const ctor = ctx.sema_result.getCtorDef(func_name) orelse return;
        const ctor_rt = ctx.getCtorAstReturnType(func_name) orelse return;

        if (typeNodeHasTypeParam(ctor_rt)) {
            const field_count = @min(ctor.field_type_descs.len, expr.call.arguments.len);
            for (0..field_count) |i| {
                const field_type = ctx.getCtorAstFieldTypeNode(func_name, i) orelse continue;
                extractCtorTypeBinding(ctx, expr.call.arguments[i], field_type, bindings);
            }
        }
        arg_type_node = ctor_rt;
    } else if (expr.* == .identifier) {
        const id = expr.identifier;
        if (ctx.lookupVar(id.name)) |binding| {
            arg_type_node = @constCast(binding.type_annotation);
        }
    }
    const arg_tn = arg_type_node orelse return;

    if (pt.* != .generic or arg_tn.* != .generic) return;
    if (!std.mem.eql(u8, pt.generic.name, arg_tn.generic.name)) return;

    const param_args = pt.generic.args;
    const arg_args = arg_tn.generic.args;
    const count = @min(param_args.len, arg_args.len);
    for (0..count) |i| {
        const pa = param_args[i];
        const ca = arg_args[i];
        if (pa.* == .named and ca.* == .named) {
            const tp_name = pa.named.name;
            if (ctx.isTypeParamName(tp_name)) {
                if (std.mem.eql(u8, ca.named.name, tp_name)) continue;
                const ct = ctx.chanTypeFromTypeNodeBound(ca) orelse continue;
                if (!bindings.contains(tp_name)) {
                    bindings.put(tp_name, ct) catch {};
                }
            }
        }
    }
}

/// 从 AST 类型节点 + 泛型绑定映射推导类型描述符
/// type_bindings: 类型参数名 → 具体类型描述符（如 "T" → i32_descriptor）
pub fn chanTypeWithTypeNode(
    ctx: *const GadtContext,
    type_node: ?*ast.TypeNode,
    type_bindings: std.StringHashMap(*const TypeDescriptor),
) ?*const TypeDescriptor {
    if (type_bindings.count() == 0) {
        return type_resolver.resolveTypeNode(type_node, &.{});
    }

    var type_args = ctx.allocator.alloc(TypeDescriptor, type_bindings.count()) catch return null;
    defer ctx.allocator.free(type_args);

    var i: usize = 0;
    var it = type_bindings.iterator();
    while (it.next()) |entry| {
        const base = entry.value_ptr.*;
        type_args[i] = .{
            .size = base.size,
            .alignment = base.alignment,
            .is_ref = base.is_ref,
            .is_nullable = base.is_nullable,
            .is_null_type = base.is_null_type,
            .is_unit_type = base.is_unit_type,
            .scalar_ops = base.scalar_ops,
            .slots = base.slots,
            .slot_kind = base.slot_kind,
            .type_id = base.type_id,
            .type_name = entry.key_ptr.*,
        };
        i += 1;
    }

    return type_resolver.resolveTypeNode(type_node, type_args);
}

/// 推断构造器调用的通道类型（含 GADT 类型参数推断）
/// 对于 If(Expr<bool>, Expr<T>, Expr<T>) : Expr<T>，
/// 当实参为 (BoolLit, IntLit, IntLit) 时，T=i32，返回 Expr<i32> 的通道类型
pub fn inferConstructorChanType(
    ctx: *const GadtContext,
    ctor: @import("sema_output.zig").CtorDefInfo,
    arguments: []*ast.Expr,
) ?*const TypeDescriptor {
    const rt = ctx.getCtorAstReturnType(ctor.name) orelse return ir_td.ref_descriptor;

    if (!typeNodeHasTypeParam(rt)) {
        return ctx.chanTypeFromTypeNodeBound(rt);
    }

    var bindings = std.StringHashMap(*const TypeDescriptor).init(ctx.allocator);
    defer bindings.deinit();

    const field_count = @min(ctor.field_type_descs.len, arguments.len);
    for (0..field_count) |i| {
        const field_type = ctx.getCtorAstFieldTypeNode(ctor.name, i) orelse continue;
        const arg_type = ctx.inferExprChanType(arguments[i]) orelse continue;
        matchTypeParamBinding(ctx, field_type, arg_type, &bindings);
        extractCtorTypeBinding(ctx, arguments[i], field_type, &bindings);
    }

    return chanTypeWithTypeNode(ctx, rt, bindings);
}

/// 推断泛型函数调用的返回通道类型
/// 通过匹配参数类型注解与实参类型，推断类型参数绑定
pub fn inferGenericCallReturnType(
    ctx: *const GadtContext,
    func_name: []const u8,
    arguments: []*ast.Expr,
) ?*const TypeDescriptor {
    const sig = ctx.sema_result.getFuncSig(func_name) orelse return null;
    if (sig.type_params.len == 0) return null;

    var bindings = std.StringHashMap(*const TypeDescriptor).init(ctx.allocator);
    defer bindings.deinit();

    // 递归调用当前函数：从 GADT 绑定栈顶获取已有的类型参数绑定
    if (ctx.func_name) |cfn| {
        if (std.mem.eql(u8, cfn, func_name)) {
            if (ctx.binding_stack) |stack| {
                if (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    var it = top.iterator();
                    while (it.next()) |entry| {
                        bindings.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
                    }
                }
            }
        }
    }

    const func_params = ctx.findFuncParamsAst(func_name);
    const param_count = if (func_params) |p| @min(p.len, arguments.len) else 0;
    for (0..param_count) |i| {
        const param_type = func_params.?[i].type_annotation orelse continue;
        const arg_type = ctx.inferExprChanType(arguments[i]) orelse continue;
        matchTypeParamBinding(ctx, param_type, arg_type, &bindings);
        extractCtorTypeBinding(ctx, arguments[i], param_type, &bindings);
    }

    const func_return_type = ctx.findFuncReturnTypeAst(func_name) orelse return null;
    return chanTypeWithTypeNode(ctx, func_return_type, bindings);
}

/// 使用 GADT 绑定栈解析类型节点的通道类型
/// 从栈顶向下查找类型参数绑定，找到则返回具体类型
pub fn resolveFieldTypeWithBindings(
    ctx: *const GadtContext,
    type_node: ?*ast.TypeNode,
) *const TypeDescriptor {
    const tn = type_node orelse return ir_td.ref_descriptor;
    if (tn.* == .named) {
        const name = tn.named.name;
        if (ctx.isTypeParamName(name)) {
            if (ctx.binding_stack) |stack| {
                var i: usize = stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (stack.items[i].get(name)) |ct| return ct;
                }
            }
            return ir_td.i64_descriptor;
        }
        return ctx.chanTypeFromTypeNodeBound(tn) orelse ir_td.ref_descriptor;
    }
    return ctx.chanTypeFromTypeNodeBound(tn) orelse ir_td.ref_descriptor;
}

/// 为 match arm 推送 GADT 类型绑定
/// 如果 pattern 是构造器模式且构造器有 return_type 注解（如 Expr<i32>），
/// 且被匹配值的类型包含类型参数（如 Expr<T>），则推断 T 的绑定
pub fn pushGadtBindingsForArm(
    ctx: *const GadtContext,
    scrutinee: *ast.Expr,
    pattern: *const ast.Pattern,
) void {
    var scrutinee_type: ?*ast.TypeNode = null;
    if (scrutinee.* == .identifier) {
        const name = scrutinee.identifier.name;
        if (ctx.func_param_types) |params| {
            for (params) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    scrutinee_type = p.type_annotation;
                    break;
                }
            }
        }
        if (scrutinee_type == null) {
            if (ctx.lookupVar(name)) |binding| {
                if (binding.type_annotation) |ta| {
                    scrutinee_type = @constCast(ta);
                }
            }
        }
    }
    if (scrutinee_type == null) return;

    const ctor_name = switch (pattern.*) {
        .constructor => |c| c.name,
        else => return,
    };
    const sr = ctx.sema_result;
    const ctor = sr.getCtorDef(ctor_name) orelse return;

    const scrutinee_generic = switch (scrutinee_type.?.*) {
        .generic => |g| g,
        else => return,
    };

    var bindings = std.StringHashMap(*const TypeDescriptor).init(ctx.allocator);
    var has_binding = false;

    const ctor_rt_opt = ctx.getCtorAstReturnType(ctor_name);
    if (ctor_rt_opt) |ctor_rt| {
        if (ctor_rt.* != .generic) {
            bindings.deinit();
            return;
        }
        const ctor_rt_generic = ctor_rt.generic;
        if (!std.mem.eql(u8, scrutinee_generic.name, ctor_rt_generic.name)) {
            bindings.deinit();
            return;
        }
        const param_args = scrutinee_generic.args;
        const ctor_args = ctor_rt_generic.args;
        const count = @min(param_args.len, ctor_args.len);
        for (0..count) |i| {
            const pa = param_args[i];
            const ca = ctor_args[i];
            if (pa.* == .named and ca.* == .named) {
                const tp_name = pa.named.name;
                if (ctx.isTypeParamName(tp_name)) {
                    if (std.mem.eql(u8, ca.named.name, tp_name)) continue;
                    const ct = ctx.chanTypeFromTypeNodeBound(ca) orelse continue;
                    bindings.put(tp_name, ct) catch {};
                    has_binding = true;
                }
            }
        }
    } else {
        const type_info = sr.getTypeDef(ctor.type_name) orelse {
            bindings.deinit();
            return;
        };
        if (!std.mem.eql(u8, scrutinee_generic.name, type_info.name)) {
            bindings.deinit();
            return;
        }
        const type_params = type_info.type_params;
        const scrutinee_args = scrutinee_generic.args;
        const count = @min(type_params.len, scrutinee_args.len);
        for (0..count) |i| {
            const tp_name = type_params[i];
            if (!ctx.isTypeParamName(tp_name)) continue;
            const ca = scrutinee_args[i];
            const ct = ctx.chanTypeFromTypeNodeBound(ca) orelse continue;
            bindings.put(tp_name, ct) catch {};
            has_binding = true;
        }
    }

    if (has_binding) {
        if (ctx.binding_stack) |stack| {
            stack.append(ctx.allocator, bindings) catch {
                bindings.deinit();
            };
        } else {
            bindings.deinit();
        }
    } else {
        bindings.deinit();
    }
}

/// 弹出 GADT 类型绑定栈顶
pub fn popGadtBindings(ctx: *GadtContext) void {
    if (ctx.binding_stack) |stack| {
        if (stack.pop()) |*bindings| {
            var b = bindings.*;
            b.deinit();
        }
    }
}

// ════════════════════════════════════════════════════════════
// 以下函数标记为"待迁移"（依赖 IRBuilder 运行时状态）
// 当前仍由 IRBuilder 处理，迁移需要先将 IRBuilder 状态外提
// ════════════════════════════════════════════════════════════
//
// 依赖变量绑定（lookupVar）的函数：
// - inferFieldType (3627) — 依赖 lookupVar 回溯变量定义
// - inferThrowOkTypeNode (4566) — 依赖 lookupVar
// - inferThrowOkChanType (4611) — 依赖 lookupVar
// - inferThrowOkTypeName (4686) — 依赖 lookupVar
// - inferExprChanType (4753) — 依赖 lookupVar + func_table + channels
// - inferArrayElemType (7365) — 依赖 lookupVar
// - inferTypeNameFromExpr 完整版 (7981) — 依赖 lookupVar + 模块引用
// - inferTraitNameFromExpr 完整版 (8108) — 依赖 lookupVar
// - inferFieldAccessTypeId (9867) — 依赖 lookupVar + type_binding_stack
// - inferTypeIdFromExpr (9998) — 依赖 inferTypeNameFromExpr + inferFieldAccessTypeId
//
// 依赖函数表/通道表的函数：
// - inferReturnTypeAst (4521) — 依赖 findFuncReturnTypeAst + isModuleReference
//
// 依赖类型绑定栈的函数：
// - inferCallTypeArgs 完整版 (4292) — 依赖 type_binding_stack + lookupTypeBinding
//
// 依赖 AST 查询的函数（getCtorAstReturnType/getCtorAstFieldTypeNode/findFuncParamsAst/findFuncReturnTypeAst）：
// - 上述多个函数间接依赖
//
// 依赖 pending_alias_targets/type_metadata_entries 的函数：
// - chanTypeFromTypeNodeResolved (9673)
// - chanTypeFromTypeId (9803)

// ════════════════════════════════════════════════════════════
// 编译期分析强制引用 + 冒烟测试
// ════════════════════════════════════════════════════════════

/// 强制编译器分析所有 infer* 函数（Zig 默认懒分析）
const _force_analysis = blk: {
    _ = inferFieldType;
    _ = inferExprChanType;
    _ = inferThrowOkChanType;
    _ = inferThrowOkTypeName;
    _ = inferArrayElemType;
    _ = inferFieldArrayElemType;
    _ = inferTypeNameFromExprComplete;
    _ = inferTraitNameFromExprComplete;
    _ = inferFieldAccessTypeId;
    _ = inferTypeIdFromExpr;
    _ = findFuncReturnTypeAst;
    _ = findFuncParamsAst;
    _ = inferReturnTypeAst;
    _ = inferThrowOkTypeNode;
    _ = typeInfoFieldType;
    _ = throwOkChanType;
    _ = throwOkTypeName;
    _ = throwOkTypeNode;
    _ = matchTypeParamBinding;
    _ = extractCtorTypeBinding;
    _ = chanTypeWithTypeNode;
    _ = inferConstructorChanType;
    _ = inferGenericCallReturnType;
    _ = resolveFieldTypeWithBindings;
    _ = pushGadtBindingsForArm;
    _ = popGadtBindings;
    break :blk {};
};

test "inference: chanTypeFromTypeName via type_resolver" {
    try std.testing.expectEqual(ir_td.i32_descriptor, type_resolver.chanTypeFromTypeName("i32"));
    try std.testing.expectEqual(ir_td.f64_descriptor, type_resolver.chanTypeFromTypeName("f64"));
    try std.testing.expectEqual(ir_td.bool_descriptor, type_resolver.chanTypeFromTypeName("bool"));
    try std.testing.expectEqual(ir_td.ref_descriptor, type_resolver.chanTypeFromTypeName("str"));
    try std.testing.expectEqual(ir_td.ref_descriptor, type_resolver.chanTypeFromTypeName("MyType"));
}

test "inference: typeNameFromNode" {
    const tn = ast.TypeNode{ .named = .{ .name = "Foo" } };
    try std.testing.expectEqualStrings("Foo", type_resolver.typeNameFromNode(&tn).?);
}

test "inference: chanTypeFromExprAst" {
    const expr = ast.Expr{ .int_literal = .{ .value = 42, .suffix = null } };
    try std.testing.expectEqual(ir_td.i32_descriptor, chanTypeFromExprAst(&expr));
}
