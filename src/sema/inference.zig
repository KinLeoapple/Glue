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
const ChanType = ir_mod.ChanType;
const SemaResult = ir_mod.SemaResult;

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
pub fn inferChanTypeFromExpr(ctx: *const InferContext, expr: *const ast.Expr) ?ChanType {
    if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
        return info.chan_type;
    }
    return null;
}

/// 从构造器名 + 字段名推断字段通道类型
///
/// 迁自 builder.zig:3612 inferFieldTypeByCtor
/// 仅依赖 sema_result.ctor_def_index
pub fn inferFieldTypeByCtor(ctx: *const InferContext, type_name: []const u8, field: []const u8) ?ChanType {
    const ctor = ctx.sema_result.getCtorDef(type_name) orelse return null;
    for (ctor.field_names, 0..) |fname, i| {
        if (fname) |fn_str| {
            if (std.mem.eql(u8, fn_str, field)) {
                if (i < ctor.field_chan_types.len) return ctor.field_chan_types[i];
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
pub fn chanTypeFromExprAst(expr: *const ast.Expr) ChanType {
    switch (expr.*) {
        .int_literal => |il| {
            if (il.suffix) |s| {
                if (builtin_types.chanTypeFromBuiltinName(s)) |ct| return ct;
            }
            return .i32_chan;
        },
        .float_literal => |fl| {
            if (fl.suffix) |s| {
                if (builtin_types.chanTypeFromBuiltinName(s)) |ct| return ct;
            }
            return .f32_chan;
        },
        .bool_literal => return .bool_chan,
        .string_literal, .string_interpolation => return .ref_chan,
        .char_literal => return .char_chan,
        else => return .i64_chan,
    }
}

/// 推断数组字面量的元素通道类型
///
/// 迁自 builder.zig:7352 inferArrayLiteralElemType
/// 纯 AST 推断
pub fn inferArrayLiteralElemType(arr_expr: *const ast.Expr) ChanType {
    switch (arr_expr.*) {
        .array_literal => |al| {
            if (al.elements.len == 0) return .i64_chan;
            return chanTypeFromExprAst(al.elements[0]);
        },
        else => return .i64_chan,
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
) ?ChanType {
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
fn typeInfoFieldType(field: []const u8) ?ChanType {
    const ref_fields = [_][]const u8{
        "name", "module", "kind", "structure", "layout", "impls", "type_params",
    };
    for (ref_fields) |f| if (std.mem.eql(u8, field, f)) return .ref_chan;
    return null;
}

/// 推断表达式的通道类型（完整版）
///
/// 迁自 builder.zig:4753 inferExprChanType
/// 依赖：sema_result.expr_types + func_sigs + 变量绑定
pub fn inferExprChanType(ctx: *const InferContextExt, expr: *const ast.Expr) ?ChanType {
    switch (expr.*) {
        .call => |c| {
            const func_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            // 构造器调用：返回 ref_chan（构造器在堆上分配，返回引用）
            if (ctx.base.sema_result.getCtorDef(func_name) != null) {
                return .ref_chan;
            }
            // 普通函数调用：查 func_sigs 的 return_chan_type
            if (ctx.base.sema_result.getFuncSig(func_name)) |sig| {
                return sig.return_chan_type;
            }
            return null;
        },
        .int_literal => return .i32_chan,
        .float_literal => return .f32_chan,
        .bool_literal => return .bool_chan,
        .string_literal => return .ref_chan,
        .char_literal => return .char_chan,
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
                .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => .mask_chan,
                .and_op, .or_op => .bool_chan,
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
pub fn inferThrowOkChanType(ctx: *const InferContextExt, expr: *const ast.Expr) ?ChanType {
    switch (expr.*) {
        .call => |c| {
            const func_name = switch (c.callee.*) {
                .identifier => |id| id.name,
                else => return null,
            };
            if (ctx.base.sema_result.getFuncSig(func_name)) |sig| {
                if (sig.is_throwing) return sig.return_chan_type;
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

/// 从 TypeNode 提取 Throw Ok 的 ChanType
/// 迁自 builder.zig throwOkChanType
fn throwOkChanType(tn: *const ast.TypeNode) ?ChanType {
    return switch (tn.*) {
        .named => |n| {
            // Throw<T> → T 的 ChanType
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
pub fn inferArrayElemType(ctx: *const InferContextExt, expr: *const ast.Expr) ChanType {
    switch (expr.*) {
        .array_literal => return inferArrayLiteralElemType(expr),
        .identifier => |id| {
            if (ctx.lookupVar(id.name)) |binding| {
                if (binding.type_annotation) |ta| {
                    if (ta.* == .array) return type_resolver.resolveChanType(ta.array.elem, &.{}) orelse .i64_chan;
                }
                if (binding.ast_expr) |src_expr| {
                    return inferArrayElemType(ctx, src_expr);
                }
            }
            return .i64_chan;
        },
        else => return .i64_chan,
    }
}

/// 推断字段数组元素类型
///
/// 迁自 builder.zig:7416 inferFieldArrayElemType
pub fn inferFieldArrayElemType(
    ctx: *const InferContextExt,
    object: *const ast.Expr,
    field: []const u8,
) ?ChanType {
    const type_name = inferTypeNameFromExprComplete(ctx, object) orelse return null;
    // 查类型定义的字段类型
    if (ctx.base.sema_result.getCtorDef(type_name)) |ctor| {
        for (ctor.field_names, 0..) |fname, i| {
            if (fname) |fn_str| {
                if (std.mem.eql(u8, fn_str, field)) {
                    if (i < ctor.field_chan_types.len) return ctor.field_chan_types[i];
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
                    if (i < ctor.field_chan_types.len) {
                        const ct = ctor.field_chan_types[i];
                        if (type_descriptor_mod.lookupBuiltinByChan(ct)) |td| {
                            return td.type_id;
                        }
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
        if (type_descriptor_mod.lookupBuiltinByChan(info.chan_type)) |td| {
            return td.type_id;
        }
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
// - inferGenericCallReturnType (4904) — 依赖 findFuncReturnTypeAst + gadt_binding_stack
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
//
// GADT 绑定函数：
// - pushGadtBindingsForArm (5115) — 依赖 current_func_param_types + lookupVar + gadt_binding_stack
// - popGadtBindings (5228)

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
    _ = inferReturnTypeAst;
    _ = inferThrowOkTypeNode;
    _ = typeInfoFieldType;
    _ = throwOkChanType;
    _ = throwOkTypeName;
    _ = throwOkTypeNode;
    break :blk {};
};

test "inference: chanTypeFromTypeName via type_resolver" {
    try std.testing.expectEqual(ChanType.i32_chan, type_resolver.chanTypeFromTypeName("i32"));
    try std.testing.expectEqual(ChanType.f64_chan, type_resolver.chanTypeFromTypeName("f64"));
    try std.testing.expectEqual(ChanType.bool_chan, type_resolver.chanTypeFromTypeName("bool"));
    try std.testing.expectEqual(ChanType.ref_chan, type_resolver.chanTypeFromTypeName("str"));
    try std.testing.expectEqual(ChanType.ref_chan, type_resolver.chanTypeFromTypeName("MyType"));
}

test "inference: typeNameFromNode" {
    const tn = ast.TypeNode{ .named = .{ .name = "Foo" } };
    try std.testing.expectEqualStrings("Foo", type_resolver.typeNameFromNode(&tn).?);
}

test "inference: chanTypeFromExprAst" {
    const expr = ast.Expr{ .int_literal = .{ .value = 42, .suffix = null } };
    try std.testing.expectEqual(ChanType.i32_chan, chanTypeFromExprAst(&expr));
}
