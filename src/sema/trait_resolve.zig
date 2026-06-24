//! Trait 解析
//!
//! 从 type_check.zig 提取的 Trait 解析逻辑，以自由函数形式实现。
//! TypeInferencer 上的方法委托到此模块。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const TypeVar = type_check.TypeVar;
pub const TypeScheme = type_check.TypeScheme;
pub const BoundInfo = type_check.BoundInfo;
pub const TypeEnv = type_check.TypeEnv;
pub const TraitInfo = type_check.TraitInfo;
pub const ImplRecord = type_check.ImplRecord;
pub const TypeErrorKind = type_check.TypeErrorKind;
pub const SemaError = type_check.SemaError;
pub const TypeInferencer = type_check.TypeInferencer;

/// 文档 2.7.6/2.7.7: Orphan Instance 检查和 Overlapping Instance 检查
pub fn checkImplOrphanAndOverlapping(
    inferencer: *TypeInferencer,
    id: @TypeOf(@as(ast.Decl, undefined).impl_decl),
) void {
    const trait_name = id.trait_name;
    const type_name = id.type_name;

    // --- Orphan 检查 ---
    const trait_module = inferencer.trait_defining_modules.get(trait_name);
    const type_module = inferencer.type_defining_modules.get(type_name);

    if (trait_module != null and type_module != null) {
        const tm = trait_module.?;
        const tym = type_module.?;
        if (!std.mem.eql(u8, tm, inferencer.current_module) and
            !std.mem.eql(u8, tym, inferencer.current_module))
        {
            inferencer.addError(.unsatisfied_bound, "orphan instance: impl {s} for {s} — neither {s} nor {s} is defined in current module '{s}'", .{ trait_name, type_name, trait_name, type_name, inferencer.current_module });
        }
    }

    // --- Overlapping 检查 ---
    const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ trait_name, type_name }) catch return;
    if (inferencer.registered_impls.get(impl_key)) |existing| {
        inferencer.addError(.unsatisfied_bound, "overlapping instance: impl {s} for {s} already defined at line {d}", .{ trait_name, type_name, existing.line });
        inferencer.allocator.free(impl_key);
    } else {
        inferencer.registered_impls.put(impl_key, ImplRecord{
            .trait_name = trait_name,
            .type_name = type_name,
            .line = id.location.line,
            .column = id.location.column,
        }) catch return;
    }
}

/// 文档 2.7.4: 关联类型验证
/// impl 必须定义 Trait 中声明的所有关联类型
pub fn checkImplAssociatedTypes(
    inferencer: *TypeInferencer,
    id: @TypeOf(@as(ast.Decl, undefined).impl_decl),
) void {
    const trait_info = inferencer.trait_types.get(id.trait_name) orelse return;
    if (trait_info.associated_type_names.len == 0) return;

    var defined_names = std.StringHashMap(void).init(inferencer.allocator);
    defer defined_names.deinit();
    for (id.associated_type_defs) |atd| {
        defined_names.put(atd.name, {}) catch return;
    }

    for (trait_info.associated_type_names) |assoc_name| {
        if (!defined_names.contains(assoc_name)) {
            inferencer.addError(.unsatisfied_bound, "impl {s} for {s}: missing associated type '{s}'", .{ id.trait_name, id.type_name, assoc_name });
        }
    }
}

/// 文档 2.7.2: 递归注册父 Trait 的方法到类型环境
/// impl Child<T> 会自动满足所有父 Trait 的 bound
pub fn registerParentTraitMethods(
    inferencer: *TypeInferencer,
    env: *TypeEnv,
    trait_name: []const u8,
    overridden: *std.StringHashMap(void),
) void {
    if (inferencer.trait_types.getPtr(trait_name)) |trait_info| {
        var ms_iter = trait_info.method_schemes.iterator();
        while (ms_iter.next()) |entry| {
            const mname = entry.key_ptr.*;
            if (!overridden.contains(mname)) {
                if (env.lookup(mname) == null) {
                    env.redefine(mname, entry.value_ptr.*) catch return;
                }
            }
        }
    }
}

/// 将类型中的所有类型变量替换为具体类型
/// 用于 impl 方法的类型实例化（如 impl Ord<i32> 中 T -> i32）
pub fn instantiateWithConcreteType(
    inferencer: *TypeInferencer,
    ty: *Type,
    concrete: *Type,
) SemaError!*Type {
    const resolved = inferencer.resolve(ty);
    switch (resolved.*) {
        .type_var => {
            return concrete;
        },
        .fn_type => |ft| {
            var param_types = std.ArrayList(*Type).empty;
            for (ft.params) |pt| {
                const inst_pt = try instantiateWithConcreteType(inferencer, pt, concrete);
                param_types.append(inferencer.allocator, inst_pt) catch return error.OutOfMemory;
            }
            const inst_ret = try instantiateWithConcreteType(inferencer, ft.return_type, concrete);
            return inferencer.makeFnType(param_types.items, inst_ret);
        },
        .adt_type => return resolved,
        .i32_type => return resolved,
        .i64_type => return resolved,
        .bool_type => return resolved,
        .str_type => return resolved,
        .unit_type => return resolved,
        .nullable_type => return resolved,
        .throw_type => return resolved,
        .record_type => return resolved,
        .trait_type => return resolved,
        else => return resolved,
    }
}

/// Call-site trait bound checking
pub fn checkCallSiteTraitBound(
    inferencer: *TypeInferencer,
    callee: *const ast.Expr,
    location: ast.SourceLocation,
) void {
    const fn_name: ?[]const u8 = switch (callee.*) {
        .identifier => |v| v.name,
        else => null,
    };
    const name = fn_name orelse return;
    const bounds = inferencer.fn_bounds.get(name) orelse return;

    for (bounds) |bound| {
        if (bound.type_args.len == 0) continue;
        for (bound.type_args) |tp| {
            const tp_name: []const u8 = switch (tp.*) {
                .named => |n| n.name,
                .generic => |g| g.name,
                else => continue,
            };
            if (isBuiltinTypeName(tp_name)) {
                const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(impl_key);
                if (!inferencer.registered_impls.contains(impl_key)) {
                    inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no impl found for trait {s}<{s}> at call site", .{ bound.trait_name, tp_name });
                }
            }
            if (inferencer.type_defining_modules.contains(tp_name)) {
                const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(impl_key);
                if (!inferencer.registered_impls.contains(impl_key)) {
                    inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no impl found for trait {s}<{s}> at call site", .{ bound.trait_name, tp_name });
                }
            }
        }
    }
}

/// 文档 2.7.3: 从 TypeScheme 的 BoundInfo 检查 Trait Bound
/// 在实例化后调用，检查实例化后的类型参数是否满足 bound
pub fn checkInstantiatedBounds(
    inferencer: *TypeInferencer,
    scheme: TypeScheme,
    location: ast.SourceLocation,
) void {
    for (scheme.bounds) |bound| {
        if (bound.type_param_index >= scheme.quantified_vars.len) continue;
        const var_id = scheme.quantified_vars[bound.type_param_index];
        for (inferencer.type_vars.items) |tv| {
            if (tv.type_var.id == var_id and tv.type_var.bound != null) {
                const resolved = inferencer.resolve(tv.type_var.bound.?);
                const type_name: ?[]const u8 = switch (resolved.*) {
                    .adt_type => |adt| adt.name,
                    .named => |n| n.name,
                    else => null,
                };
                if (type_name) |tn| {
                    const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tn }) catch return;
                    defer inferencer.allocator.free(impl_key);
                    if (!inferencer.registered_impls.contains(impl_key)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no impl found for {s}<{s}>", .{ bound.trait_name, tn });
                    }
                }
                break;
            }
        }
    }
}

/// 文档 2.7.3: Trait Bound `with` 验证
/// 检查声明的 Trait bound 是否有对应的 trait 定义和 impl 实现
pub fn checkTraitBound(
    inferencer: *TypeInferencer,
    bound: ast.TraitBound,
    location: ast.SourceLocation,
) void {
    if (inferencer.trait_types.getPtr(bound.trait_name)) |trait_info| {
        if (bound.type_args.len > 0) {
            for (bound.type_args) |tp| {
                const tp_name: []const u8 = switch (tp.*) {
                    .named => |n| n.name,
                    .generic => |g| g.name,
                    else => continue,
                };
                const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(impl_key);
                if (!inferencer.registered_impls.contains(impl_key)) {
                    if (isBuiltinTypeName(tp_name)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no impl found for trait {s}<{s}>", .{ bound.trait_name, tp_name });
                    }
                    if (inferencer.type_defining_modules.contains(tp_name)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no impl found for trait {s}<{s}>", .{ bound.trait_name, tp_name });
                    }
                }
            }
        } else {
            const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::", .{bound.trait_name}) catch return;
            defer inferencer.allocator.free(impl_key);
        }

        if (trait_info.associated_type_names.len > 0 and bound.type_args.len == 0) {
            // Trait 有关联类型但 bound 没有指定 — 简化：不强制要求
        }
    } else {
        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "trait '{s}' is not defined", .{bound.trait_name});
    }
}

/// method_call 表达式的 trait 方法分派解析
pub fn inferMethodCall(
    inferencer: *TypeInferencer,
    mc: @TypeOf(@as(ast.Expr, undefined).method_call),
    env: *TypeEnv,
) SemaError!*Type {
    const obj_ty = inferencer.inferExpr(mc.object, env, null) catch return inferencer.freshTypeVar() catch unreachable;
    // 文档 §2.3.5：使用可空值前必须消除空值可能性。对 nullable 接收者直接调方法非法——
    // 必须先用 ?.（安全调用）、!（非空断言）或 if x != null narrowing 消除 null。
    // narrowing 后绑定已收窄为非 null（applyNarrowing），故此处只拦真正的 nullable。
    {
        const robj = inferencer.resolve(obj_ty);
        if (robj.* == .nullable_type) {
            // 字段路径 narrowing：若接收者路径（如 "u.addr"）已在 narrowed_paths 中
            // （处于 `if (u.addr != null)` 的 then 分支），视为已收窄，放行。
            var narrowed = false;
            if (inferencer.exprPath(mc.object)) |op| {
                defer inferencer.allocator.free(op);
                narrowed = inferencer.narrowed_paths.contains(op);
            }
            if (!narrowed) {
                inferencer.addErrorAt(.type_mismatch, mc.location.line, mc.location.column, "cannot call method '{s}' on nullable type; use '?.', '!', or narrow with 'if x != null' first", .{mc.method});
                return inferencer.freshTypeVar() catch unreachable;
            }
        }
    }
    // 查找 trait 方法签名
    var trait_iter = inferencer.trait_types.iterator();
    while (trait_iter.next()) |entry| {
        if (entry.value_ptr.method_schemes.get(mc.method)) |scheme| {
            const instantiated = inferencer.instantiate(scheme) catch return inferencer.freshTypeVar() catch unreachable;
            const resolved = inferencer.resolve(instantiated);
            switch (resolved.*) {
                .fn_type => |ft| {
                    if (ft.params.len > 0) {
                        inferencer.unify(ft.params[0], obj_ty) catch {};
                    }
                    return ft.return_type;
                },
                else => return resolved,
            }
        }
    }
    return inferencer.freshTypeVar() catch unreachable;
}

/// safe_method_call 表达式的 trait 方法分派解析
pub fn inferSafeMethodCall(
    inferencer: *TypeInferencer,
    smc: @TypeOf(@as(ast.Expr, undefined).safe_method_call),
    env: *TypeEnv,
) SemaError!*Type {
    const obj_ty = inferencer.inferExpr(smc.object, env, null) catch return inferencer.freshTypeVar() catch unreachable;
    // Try to find the method in registered traits (similar to method_call)
    var trait_iter = inferencer.trait_types.iterator();
    while (trait_iter.next()) |entry| {
        for (entry.value_ptr.method_names) |mname| {
            if (std.mem.eql(u8, mname, smc.method)) {
                const inner = inferencer.freshTypeVar() catch unreachable;
                return inferencer.makeNullableType(inner) catch unreachable;
            }
        }
    }
    _ = obj_ty;
    const inner = inferencer.freshTypeVar() catch unreachable;
    return inferencer.makeNullableType(inner) catch unreachable;
}

/// trait_decl 声明的处理逻辑
/// 计算 ast.Kind 的箭头 arity（`* -> *` → 1，`* -> * -> *` → 2，`*` → 0）。
fn kindArrowArity(k: *const ast.Kind) usize {
    return switch (k.*) {
        .star => 0,
        .arrow => |a| 1 + kindArrowArity(a.result),
    };
}

pub fn checkTraitDecl(
    inferencer: *TypeInferencer,
    td: @TypeOf(@as(ast.Decl, undefined).trait_decl),
) void {
    const trait_ty = inferencer.allocator.create(Type) catch return;
    trait_ty.* = Type{ .trait_type = .{ .name = td.name, .type_args = &[_]*Type{} } };
    inferencer.types.append(inferencer.allocator, trait_ty) catch return;

    // 收集关联类型名称
    var assoc_names = inferencer.allocator.alloc([]const u8, td.associated_types.len) catch return;
    for (td.associated_types, 0..) |at, i| {
        assoc_names[i] = at.name;
    }

    // 创建类型参数映射
    var type_param_map = std.StringHashMap(*Type).init(inferencer.allocator);
    defer type_param_map.deinit();

    // 创建 Self 类型变量（表示实现该 trait 的类型）
    const self_type_var = inferencer.freshTypeVar() catch return;
    const old_self_type = inferencer.current_self_type;
    defer inferencer.current_self_type = old_self_type;
    inferencer.current_self_type = self_type_var;

    for (td.type_params) |tp| {
        const tv = inferencer.freshTypeVar() catch return;
        type_param_map.put(tp.name, tv) catch return;
    }
    for (td.associated_types) |at| {
        const tv = inferencer.freshTypeVar() catch return;
        type_param_map.put(at.name, tv) catch return;
    }

    // 收集方法名称和类型签名
    var meth_names_list = std.ArrayList([]const u8).empty;
    defer meth_names_list.deinit(inferencer.allocator);
    var method_schemes = std.StringHashMap(TypeScheme).init(inferencer.allocator);

    // 先合并父 Trait 的方法签名
    for (td.parents) |parent| {
        if (inferencer.trait_types.getPtr(parent.trait_name)) |parent_info| {
            for (parent_info.method_names) |mname| {
                meth_names_list.append(inferencer.allocator, mname) catch return;
            }
            var ms_iter = parent_info.method_schemes.iterator();
            while (ms_iter.next()) |entry| {
                const mname = inferencer.allocator.dupe(u8, entry.key_ptr.*) catch return;
                method_schemes.put(mname, entry.value_ptr.*) catch return;
            }
        }
    }

    // 再处理子 Trait 自身的方法
    for (td.methods) |m| {
        var name_conflicts_with_parent = false;
        for (td.parents) |parent| {
            if (inferencer.trait_types.getPtr(parent.trait_name)) |parent_info| {
                for (parent_info.method_names) |pmname| {
                    if (std.mem.eql(u8, pmname, m.name)) {
                        name_conflicts_with_parent = true;
                        break;
                    }
                }
            }
            if (name_conflicts_with_parent) break;
        }
        if (name_conflicts_with_parent and !m.is_override and m.delegate == null) {
            inferencer.addError(.type_mismatch, "method '{s}' conflicts with parent trait — use 'override' or delegation to resolve", .{m.name});
        }
        if (m.is_override and !name_conflicts_with_parent) {
            inferencer.addError(.type_mismatch, "override method '{s}' not found in any parent trait", .{m.name});
        }
        if (m.delegate) |del| {
            if (inferencer.trait_types.getPtr(del.trait_name)) |del_trait| {
                var found_method = false;
                for (del_trait.method_names) |dmname| {
                    if (std.mem.eql(u8, dmname, del.method_name)) {
                        found_method = true;
                        break;
                    }
                }
                if (!found_method) {
                    inferencer.addError(.type_mismatch, "delegate method '{s}' not found in trait '{s}'", .{ del.method_name, del.trait_name });
                }
            } else {
                inferencer.addError(.type_mismatch, "delegate trait '{s}' is not defined", .{del.trait_name});
            }
        }
        meth_names_list.append(inferencer.allocator, m.name) catch return;
        // 方法自身的类型参数（如 map<T, U>）并入一个临时映射，
        // 使方法签名里的 T/U 以及 F<T>（trait 的 F）都能解析。
        var method_param_map = std.StringHashMap(*Type).init(inferencer.allocator);
        defer method_param_map.deinit();
        {
            var it = type_param_map.iterator();
            while (it.next()) |e| method_param_map.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
        for (m.type_params) |mtp| {
            const tv = inferencer.freshTypeVar() catch return;
            method_param_map.put(mtp.name, tv) catch {};
        }
        var param_types = std.ArrayList(*Type).empty;
        for (m.params) |param| {
            const pt = if (param.type_annotation) |ta|
                inferencer.typeFromAstWithParams(ta, &method_param_map) catch inferencer.freshTypeVar() catch return
            else
                inferencer.freshTypeVar() catch return;
            param_types.append(inferencer.allocator, pt) catch return;
        }
        const ret_type = if (m.return_type) |rt|
            inferencer.typeFromAstWithParams(rt, &method_param_map) catch inferencer.freshTypeVar() catch return
        else
            inferencer.freshTypeVar() catch return;
        const fn_type = inferencer.makeFnType(param_types.items, ret_type) catch return;
        const scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = fn_type };
        const mname = inferencer.allocator.dupe(u8, m.name) catch return;
        method_schemes.put(mname, scheme) catch return;
    }

    // 冲突检测
    {
        var method_all_sources = std.StringHashMap(std.ArrayList([]const u8)).init(inferencer.allocator);
        defer {
            var mas_iter = method_all_sources.iterator();
            while (mas_iter.next()) |entry| {
                entry.value_ptr.deinit(inferencer.allocator);
            }
            method_all_sources.deinit();
        }

        for (td.parents) |parent| {
            if (inferencer.trait_types.getPtr(parent.trait_name)) |parent_info| {
                for (parent_info.method_names) |mname| {
                    if (method_all_sources.getPtr(mname)) |sources| {
                        sources.append(inferencer.allocator, parent.trait_name) catch {};
                    } else {
                        var new_list = std.ArrayList([]const u8).empty;
                        new_list.append(inferencer.allocator, parent.trait_name) catch {};
                        const name_copy = inferencer.allocator.dupe(u8, mname) catch return;
                        method_all_sources.put(name_copy, new_list) catch return;
                    }
                }
            }
        }

        var conflict_iter = method_all_sources.iterator();
        while (conflict_iter.next()) |entry| {
            const mname = entry.key_ptr.*;
            const sources = entry.value_ptr.*;
            if (sources.items.len < 2) continue;
            var resolved = false;
            for (td.methods) |m| {
                if (std.mem.eql(u8, m.name, mname) and (m.is_override or m.delegate != null)) {
                    resolved = true;
                    break;
                }
            }
            if (!resolved) {
                const first = sources.items[0];
                const second = sources.items[1];
                inferencer.addError(.type_mismatch, "unresolved conflict for method '{s}' — inherited from both {s} and {s}; use 'override' or delegation to resolve", .{ mname, first, second });
            }
        }
    }

    const meth_names = meth_names_list.toOwnedSlice(inferencer.allocator) catch return;

    // 文档 §2.11.1: 计算每个类型参数声明的 kind arity（`->` 个数），
    // 供 impl 头部的类型实参 kind 检查使用。
    const kind_arities = inferencer.allocator.alloc(usize, td.type_params.len) catch return;
    for (td.type_params, 0..) |tp, i| {
        kind_arities[i] = if (tp.kind) |k| kindArrowArity(k) else 0;
    }

    const key = inferencer.allocator.dupe(u8, td.name) catch return;
    if (inferencer.isBuiltinName(td.name)) {
        inferencer.addError(.type_mismatch, "cannot redefine built-in name '{s}'", .{td.name});
    } else if (inferencer.trait_types.contains(td.name)) {
        inferencer.addError(.type_mismatch, "duplicate trait definition: '{s}' is already defined in this scope", .{td.name});
    } else {
        inferencer.trait_types.put(key, TraitInfo{
            .ty = trait_ty,
            .associated_type_names = assoc_names,
            .method_names = meth_names,
            .method_schemes = method_schemes,
            .defining_module = inferencer.current_module,
            .type_param_kind_arities = kind_arities,
        }) catch return;
    }
    const mod_key = inferencer.allocator.dupe(u8, td.name) catch return;
    const mod_val = inferencer.allocator.dupe(u8, inferencer.current_module) catch return;
    inferencer.trait_defining_modules.put(mod_key, mod_val) catch return;
}

/// 收集 impl 头部泛型实参中的自由类型变量，登记为 fresh type var。
/// 如 `Show<Box<T>>` 的 type_arg 是 `Box<T>`，递归到裸名 `T`——若 T 不是
/// 已知 ADT/内建类型构造器，就是自由类型变量，绑一个 fresh var 供方法体解析。
fn collectImplHeadTypeParams(
    inferencer: *TypeInferencer,
    node: *const ast.TypeNode,
    map: *std.StringHashMap(*Type),
) void {
    switch (node.*) {
        .named => |n| {
            if (map.contains(n.name)) return;
            // 已知类型构造器/ADT 名不是自由变量（如 Box、i64）
            if (inferencer.adt_types.contains(n.name)) return;
            if (isBuiltinTypeName(n.name)) return;
            const tv = inferencer.freshTypeVar() catch return;
            map.put(n.name, tv) catch {};
        },
        .generic => |g| {
            for (g.args) |arg| collectImplHeadTypeParams(inferencer, arg, map);
        },
        .nullable => |nl| collectImplHeadTypeParams(inferencer, nl.inner, map),
        .array => |a| collectImplHeadTypeParams(inferencer, a.element_type, map),
        else => {},
    }
}

/// impl_decl 声明的处理逻辑
pub fn checkImplDecl(
    inferencer: *TypeInferencer,
    id: @TypeOf(@as(ast.Decl, undefined).impl_decl),
    env: *TypeEnv,
) void {
    // Orphan Instance 禁止 / Overlapping Instances 禁止
    checkImplOrphanAndOverlapping(inferencer, id);

    // 文档 §2.11.1: impl 头部类型实参的 kind 检查
    @import("kind_check").checkImplKinds(inferencer, id);

    // 关联类型验证
    checkImplAssociatedTypes(inferencer, id);

    // 构建 impl 的类型参数映射
    var impl_type_param_map = std.StringHashMap(*Type).init(inferencer.allocator);
    defer impl_type_param_map.deinit();
    if (inferencer.trait_types.getPtr(id.trait_name)) |trait_info| {
        _ = trait_info;
    }
    // 参数化条件实现（impl Show<Box<T>> with Show<T>）：把头部泛型实参中的
    // 自由类型变量（如 Box<T> 的 T、Pair<A,B> 的 A/B）登记为 fresh type var，
    // 使方法体里 self.value（类型 T）的字段访问/方法调用能解析。
    for (id.type_args) |arg| {
        collectImplHeadTypeParams(inferencer, arg, &impl_type_param_map);
    }
    // 校验 with 约束引用的 trait 已定义（与 checkTraitBound 一致的 best-effort）。
    for (id.bounds) |bound| {
        if (!inferencer.trait_types.contains(bound.trait_name)) {
            inferencer.addErrorAt(.unsatisfied_bound, id.location.line, id.location.column, "trait '{s}' is not defined", .{bound.trait_name});
        }
    }
    // 将关联类型定义加入类型参数映射
    for (id.associated_type_defs) |atd| {
        const assoc_ty = inferencer.typeFromAst(atd.actual_type) catch inferencer.freshTypeVar() catch continue;
        impl_type_param_map.put(atd.name, assoc_ty) catch continue;
    }
    // 从 impl 的 type_args 构建具体类型
    const concrete_type = if (id.type_name.len > 0)
        inferencer.typeFromAst(&ast.TypeNode{ .named = .{ .location = .{ .line = 0, .column = 0 }, .name = id.type_name } }) catch null
    else
        null;

    // 收集 impl 中已覆写的方法名
    var overridden = std.StringHashMap(void).init(inferencer.allocator);
    defer overridden.deinit();

    // 将 impl 中的方法注册到类型环境
    for (id.methods) |method| {
        if (method.body) |_| {
            var param_types = inferencer.allocator.alloc(*Type, method.params.len) catch return;
            for (method.params, 0..) |param, i| {
                param_types[i] = if (param.type_annotation) |ta|
                    inferencer.typeFromAstWithParams(ta, &impl_type_param_map) catch inferencer.freshTypeVar() catch return
                else
                    inferencer.freshTypeVar() catch return;
            }
            const ret_ty = if (method.return_type) |rt|
                inferencer.typeFromAstWithParams(rt, &impl_type_param_map) catch inferencer.freshTypeVar() catch return
            else
                inferencer.freshTypeVar() catch return;
            const fn_ty = inferencer.makeFnType(param_types, ret_ty) catch return;
            const scheme = inferencer.generalize(env, fn_ty) catch return;
            env.redefine(method.name, scheme) catch return;
            const name_copy = inferencer.allocator.dupe(u8, method.name) catch return;
            overridden.put(name_copy, {}) catch return;
        }
    }

    // 将 Trait 的默认方法注册到类型环境（impl 未覆写的部分）
    if (inferencer.trait_types.getPtr(id.trait_name)) |trait_info| {
        var ms_iter = trait_info.method_schemes.iterator();
        while (ms_iter.next()) |entry| {
            const mname = entry.key_ptr.*;
            if (!overridden.contains(mname)) {
                if (env.lookup(mname) == null) {
                    const method_scheme = entry.value_ptr.*;
                    if (concrete_type) |ct| {
                        const inst_ty = instantiateWithConcreteType(inferencer, method_scheme.ty, ct) catch return;
                        const inst_scheme = TypeScheme{ .quantified_vars = &[_]usize{}, .ty = inst_ty };
                        env.redefine(mname, inst_scheme) catch return;
                    } else {
                        env.redefine(mname, method_scheme) catch return;
                    }
                }
            }
        }
        // 递归注册父 Trait 的方法
        registerParentTraitMethods(inferencer, env, id.trait_name, &overridden);
    }
}

/// 检查名称是否为内建类型名
fn isBuiltinTypeName(name: []const u8) bool {
    const builtin_types = .{
        "i8",  "i16", "i32", "i64", "i128",
        "u8",  "u16", "u32", "u64", "u128",
        "f32", "f64", "bool", "str", "char",
    };
    inline for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

/// 检查 type 声明的 trait 实现（新语法）
/// type Point: Show, Eq = (x: i32, y: i32) { methods }
pub fn checkTypeTraitImplementations(
    inferencer: *TypeInferencer,
    td: @TypeOf(@as(ast.Decl, undefined).type_decl),
    env: *TypeEnv,
) void {
    // 为每个实现的 trait 进行验证
    for (td.implemented_traits) |trait_bound| {
        // 检查 trait 是否存在
        const trait_info = inferencer.trait_types.getPtr(trait_bound.trait_name) orelse {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "undefined trait '{s}'", .{trait_bound.trait_name});
            continue;
        };

        // Orphan 检查：类型和 trait 至少有一个在当前模块定义
        const type_in_current_module = std.mem.eql(u8, inferencer.current_module, inferencer.type_defining_modules.get(td.name) orelse "");
        const trait_in_current_module = std.mem.eql(u8, inferencer.current_module, inferencer.trait_defining_modules.get(trait_bound.trait_name) orelse "");

        if (!type_in_current_module and !trait_in_current_module) {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "orphan instance: neither type '{s}' nor trait '{s}' is defined in this module", .{ td.name, trait_bound.trait_name });
        }

        // Overlapping 检查：确保没有重复实现
        const impl_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ trait_bound.trait_name, td.name }) catch return;
        defer inferencer.allocator.free(impl_key);

        if (inferencer.registered_impls.contains(impl_key)) {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "overlapping instance: trait '{s}' is already implemented for type '{s}'", .{ trait_bound.trait_name, td.name });
        } else {
            const key_owned = inferencer.allocator.dupe(u8, impl_key) catch return;
            inferencer.registered_impls.put(key_owned, ImplRecord{
                .trait_name = trait_bound.trait_name,
                .type_name = td.name,
                .line = td.location.line,
                .column = td.location.column,
            }) catch return;
        }

        // 验证所有 trait 方法都已实现
        for (trait_info.method_names) |required_method| {
            var found = false;
            for (td.methods) |method| {
                if (std.mem.eql(u8, method.name, required_method)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "type '{s}' does not implement required method '{s}' from trait '{s}'", .{ td.name, required_method, trait_bound.trait_name });
            }
        }

        // 将 trait 方法注册到环境中（用于方法调用解析）
        for (trait_info.method_names) |mname| {
            if (trait_info.method_schemes.get(mname)) |method_scheme| {
                // 将方法注册到类型环境中
                const method_key = std.fmt.allocPrint(inferencer.allocator, "{s}.{s}", .{ td.name, mname }) catch continue;
                defer inferencer.allocator.free(method_key);

                env.bindings.put(method_key, method_scheme) catch continue;
            }
        }
    }
}

