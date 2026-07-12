//! Trait 解析与检查模块。
//!
//! 负责 Glue 语言中 trait 相关的全部语义检查工作，包括：
//! - 父 trait 方法的继承注册
//! - 用具体类型实例化含类型变量的类型
//! - 在调用点检查函数的 trait 约束是否被满足
//! - 实例化类型方案后检查其 trait bound 是否满足
//! - 单个 trait bound 的合法性校验
//! - 方法调用与方法安全调用的类型推断
//! - trait 声明的完整检查（含父 trait 冲突、override、委托等）
//! - 类型上 trait 实现的检查（孤儿规则、重叠实例、方法完备性）

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const TypeVar = type_check.TypeVar;
pub const TypeScheme = type_check.TypeScheme;
pub const BoundInfo = type_check.BoundInfo;
pub const TypeEnv = type_check.TypeEnv;
pub const TraitInfo = type_check.TraitInfo;
pub const TraitEntry = type_check.TraitEntry;
pub const TypeErrorKind = type_check.TypeErrorKind;
pub const SemaError = type_check.SemaError;
pub const TypeInferencer = type_check.TypeInferencer;

/// 将父 trait 的方法方案注册到当前环境，用于实现 trait 方法的继承。
/// 仅注册未被 `overridden` 标记且环境中尚不存在的方法。
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

/// 用具体类型 `concrete` 实例化类型 `ty` 中的类型变量。
/// 递归处理函数类型；其余具体类型原样返回。
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

/// 在函数调用点检查被调用函数声明的 trait bound 是否被满足。
/// 仅对内建类型名或当前模块定义的类型名做实现存在性校验。
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
            // 内建类型作为 trait 实参时，要求存在对应 trait 实现
            if (isBuiltinTypeName(tp_name)) {
                const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(trait_key);
                if (!inferencer.registered_traits.contains(trait_key)) {
                    inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no trait implementation found for trait {s}<{s}> at call site", .{ bound.trait_name, tp_name });
                }
            }
            // 用户定义类型作为 trait 实参时，同样要求存在对应实现
            if (inferencer.type_defining_modules.contains(tp_name)) {
                const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(trait_key);
                if (!inferencer.registered_traits.contains(trait_key)) {
                    inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no trait implementation found for trait {s}<{s}> at call site", .{ bound.trait_name, tp_name });
                }
            }
        }
    }
}

/// 在实例化类型方案后检查其 trait bound 是否被满足。
/// 对每个 bound，定位被绑定的具体类型名并校验是否注册了对应 trait 实现。
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
                    const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tn }) catch return;
                    defer inferencer.allocator.free(trait_key);
                    if (!inferencer.registered_traits.contains(trait_key)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no trait implementation found for {s}<{s}>", .{ bound.trait_name, tn });
                    }
                }
                break;
            }
        }
    }
}

/// 校验单个 trait bound 的合法性：trait 是否存在、各类型实参是否有对应实现。
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
                const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ bound.trait_name, tp_name }) catch return;
                defer inferencer.allocator.free(trait_key);
                if (!inferencer.registered_traits.contains(trait_key)) {
                    // 仅对内建类型与当前项目定义的类型报缺实现错误
                    if (isBuiltinTypeName(tp_name)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no trait implementation found for trait {s}<{s}>", .{ bound.trait_name, tp_name });
                    }
                    if (inferencer.type_defining_modules.contains(tp_name)) {
                        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "no trait implementation found for trait {s}<{s}>", .{ bound.trait_name, tp_name });
                    }
                }
            }
        } else {
            const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::", .{bound.trait_name}) catch return;
            defer inferencer.allocator.free(trait_key);
        }
        if (trait_info.associated_type_names.len > 0 and bound.type_args.len == 0) {
        }
    } else {
        inferencer.addErrorAt(.unsatisfied_bound, location.line, location.column, "trait '{s}' is not defined", .{bound.trait_name});
    }
}

/// 推断方法调用表达式的类型。
/// 先推断接收者类型并对 nullable 接收者做安全检查，再在各 trait 的方法方案中
/// 查找匹配方法，实例化后用接收者类型统一 self 参数，返回方法返回类型。
pub fn inferMethodCall(
    inferencer: *TypeInferencer,
    mc: @TypeOf(@as(ast.Expr, undefined).method_call),
    env: *TypeEnv,
) SemaError!*Type {
    const obj_ty = inferencer.inferExpr(mc.object, env, null) catch return inferencer.freshTypeVar() catch unreachable;
    {
        // 对 nullable 接收者调用方法：需已通过窄化确认非空，否则报错
        const robj = inferencer.resolve(obj_ty);
        if (robj.* == .nullable_type) {
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

    // 遍历所有 trait 查找同名方法
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

/// 推断安全方法调用（`?.method(...)`）的类型。
/// 始终返回一个 nullable 包装的新类型变量，表示可能为空的结果。
pub fn inferSafeMethodCall(
    inferencer: *TypeInferencer,
    smc: @TypeOf(@as(ast.Expr, undefined).safe_method_call),
    env: *TypeEnv,
) SemaError!*Type {
    const obj_ty = inferencer.inferExpr(smc.object, env, null) catch return inferencer.freshTypeVar() catch unreachable;
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

/// 计算种类的箭头 arity：star 为 0，箭头则递归累加。
fn kindArrowArity(k: *const ast.Kind) usize {
    return switch (k.*) {
        .star => 0,
        .arrow => |a| 1 + kindArrowArity(a.result),
    };
}

/// 完整检查一个 trait 声明：注册 trait 类型、收集父 trait 方法、校验
/// override/委托冲突、检测多继承的方法冲突，并登记 trait 的定义模块。
pub fn checkTraitDecl(
    inferencer: *TypeInferencer,
    td: @TypeOf(@as(ast.Decl, undefined).trait_decl),
) void {
    const trait_ty = inferencer.allocator.create(Type) catch return;
    trait_ty.* = Type{ .trait_type = .{ .name = td.name, .type_args = &[_]*Type{} } };
    inferencer.types.append(inferencer.allocator, trait_ty) catch return;
    var assoc_names = inferencer.allocator.alloc([]const u8, td.associated_types.len) catch return;
    for (td.associated_types, 0..) |at, i| {
        assoc_names[i] = at.name;
    }

    var type_param_map = std.StringHashMap(*Type).init(inferencer.allocator);
    defer type_param_map.deinit();
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

    var meth_names_list = std.ArrayList([]const u8).empty;
    defer meth_names_list.deinit(inferencer.allocator);
    var method_schemes = std.StringHashMap(TypeScheme).init(inferencer.allocator);

    // 继承父 trait 的方法名与方法方案
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

    // 处理本 trait 自身声明的方法，并校验 override/委托合法性
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

    // 检测多继承导致的同名方法冲突，要求子类用 override/委托消解
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

/// 判断 `name` 是否为内建基础类型名。
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

/// 检查某类型上声明的 trait 实现：应用孤儿规则、检测重叠实例、
/// 校验必需方法是否齐全，并把实现的方法方案注入到环境以便方法解析。
pub fn checkTypeTraitImplementations(
    inferencer: *TypeInferencer,
    td: @TypeOf(@as(ast.Decl, undefined).type_decl),
    env: *TypeEnv,
) void {
    for (td.implemented_traits) |trait_bound| {
        const trait_info = inferencer.trait_types.getPtr(trait_bound.trait_name) orelse {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "undefined trait '{s}'", .{trait_bound.trait_name});
            continue;
        };
        // 孤儿规则：类型与 trait 至少有一个定义在当前模块
        const type_in_current_module = std.mem.eql(u8, inferencer.current_module, inferencer.type_defining_modules.get(td.name) orelse "");
        const trait_in_current_module = std.mem.eql(u8, inferencer.current_module, inferencer.trait_defining_modules.get(trait_bound.trait_name) orelse "");
        if (!type_in_current_module and !trait_in_current_module) {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "orphan instance: neither type '{s}' nor trait '{s}' is defined in this module", .{ td.name, trait_bound.trait_name });
        }
        // 重叠实例检测
        const trait_key = std.fmt.allocPrint(inferencer.allocator, "{s}::{s}", .{ trait_bound.trait_name, td.name }) catch return;
        defer inferencer.allocator.free(trait_key);
        if (inferencer.registered_traits.contains(trait_key)) {
            inferencer.addErrorAt(.type_mismatch, td.location.line, td.location.column, "overlapping instance: trait '{s}' is already implemented for type '{s}'", .{ trait_bound.trait_name, td.name });
        } else {
            const key_owned = inferencer.allocator.dupe(u8, trait_key) catch return;
            inferencer.registered_traits.put(key_owned, TraitEntry{
                .trait_name = trait_bound.trait_name,
                .type_name = td.name,
                .line = td.location.line,
                .column = td.location.column,
            }) catch return;
        }
        // 校验 trait 必需方法是否全部实现
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
        // 将实现的方法方案以 "TypeName.methodName" 的键注入环境
        for (trait_info.method_names) |mname| {
            if (trait_info.method_schemes.get(mname)) |method_scheme| {
                const method_key = std.fmt.allocPrint(inferencer.allocator, "{s}.{s}", .{ td.name, mname }) catch continue;
                env.bindings.put(method_key, method_scheme) catch {
                    inferencer.allocator.free(method_key);
                    continue;
                };
            }
        }
    }
}
