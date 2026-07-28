//! 单态化实例化
//!
//! v3 spec §5.2: 迁自 builder.zig:10031 instantiateFunction。
//! 职责：识别所有泛型调用点 → 推导 type_args → 去重 → 确定实例集合。

const std = @import("std");
const ast = @import("ast");
const ir_mod = @import("ir");
const type_descriptor_mod = @import("type_descriptor.zig");
const type_resolver = @import("type_resolver.zig");

const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const sema_output = @import("sema_output.zig");
const SemaResult = sema_output.SemaResult;
const MonomorphInstance = sema_output.MonomorphInstance;
const ChanLayout = sema_output.ChanLayout;
const FuncSigInfo = sema_output.FuncSigInfo;
const ExprInfo = sema_output.ExprInfo;
const FieldAccessInfo = sema_output.FieldAccessInfo;

/// AST 遍历与实例创建的错误集（显式定义以打破 walkExpr ↔ walkStmt 递归错误集循环）
const WalkError = error{OutOfMemory};

/// 单态化实例化结果
pub const MonoResult = struct {
    instance_id: u32,
    is_new: bool, // true = 新创建，false = 命中已有实例
};

/// FNV-1a 64-bit 哈希（迁自 builder.zig:10010 hashTypeArgs）
/// 输入改为 type_id 列表（TypeDescriptor.type_id）
pub fn hashTypeArgs(type_args: []const TypeDescriptor) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (type_args) |ta| {
        h ^= @as(u64, ta.type_id);
        h *%= 0x100000001b3;
    }
    return h;
}

/// 构造单态化缓存键
/// 格式："{func_name}#{hash}"（与 builder.zig:10047 保持一致）
pub fn buildCacheKey(
    allocator: std.mem.Allocator,
    func_name: []const u8,
    type_args: []const TypeDescriptor,
) WalkError![]u8 {
    const hash = hashTypeArgs(type_args);
    return std.fmt.allocPrint(allocator, "{s}#{x}", .{ func_name, hash });
}

/// 查找已有单态化实例（仅查询缓存，不创建）
pub fn findInstance(
    sema_result: *const SemaResult,
    func_name: []const u8,
    type_args: []const TypeDescriptor,
) ?u32 {
    const cache_key = buildCacheKey(sema_result.allocator, func_name, type_args) catch return null;
    defer sema_result.allocator.free(cache_key);

    return sema_result.monomorph_index.get(cache_key);
}

// ════════════════════════════════════════════════════════════════
// AST 遍历上下文与辅助函数
// ════════════════════════════════════════════════════════════════

/// AST 遍历上下文：携带 sema 结果与函数名 → 声明映射
const WalkCtx = struct {
    sema_result: *SemaResult,
    module: *const ast.Module,
    /// 函数名 → *const ast.Decl（指向 fun_decl 变体），用于推导 type_args 时
    /// 查询参数类型注解与返回类型
    func_decls: std.StringHashMap(*const ast.Decl),
    /// 循环检测：正在实例化的 cache_key → instance_id（前向引用支持）
    /// key 由 sema_result.allocator 分配，在 collectMonomorphInstances 末尾统一释放
    in_progress: std.StringHashMap(u32),
};

/// 由 ExprInfo 推导对应的 TypeDescriptor（用于隐式 type_args 推断）
/// ExprInfo.type_desc 已是 TypeDescriptor，直接返回
fn tdFromExprInfo(info: ExprInfo) *const TypeDescriptor {
    return info.type_desc;
}

/// 由 AST 类型节点推导 TypeDescriptor（用于显式 type_args）
/// 使用 resolveTypeNodeConcrete 为用户类型创建具体描述符，不回退
fn tdFromTypeNode(tn: *const ast.TypeNode, sema_result: *SemaResult) *const TypeDescriptor {
    return type_resolver.resolveTypeNodeConcrete(tn, &.{}, sema_result) orelse
        sema_result.getOrCreateRefDesc("unknown") catch unreachable;
}

/// 推导泛型调用的 type_args
///
/// 优先级：
/// 1. 显式类型实参（call expr 的 type_args 字段，如 foo<i32>(x)）
/// 2. 隐式推断：
///    a. .named 类型注解（如 init: A）→ 实参 ExprInfo 的 TypeDescriptor
///    b. .function 类型注解（如 f: (A, T) -> A）→ lambda 实参的参数类型注解
///    c. .function 返回类型注解 → lambda 实参的返回类型（注解或 body 推断）
///
/// 未匹配的类型参数用 getOrCreateRefDesc 创建具名描述符
fn inferTypeArgs(
    func_name: []const u8,
    arguments: []const *const ast.Expr,
    type_args_hint: ?[]*ast.TypeNode,
    sig: FuncSigInfo,
    ctx: *WalkCtx,
) WalkError![]const TypeDescriptor {
    const alloc = ctx.sema_result.allocator;

    // 1. 显式类型实参：直接解析每个 TypeNode
    if (type_args_hint) |hints| {
        if (hints.len > 0) {
            const args = try alloc.alloc(TypeDescriptor, hints.len);
            for (hints, 0..) |tn, i| {
                args[i] = tdFromTypeNode(tn, ctx.sema_result).*;
            }
            return args;
        }
    }

    // 2. 隐式推断
    const fd_decl = ctx.func_decls.get(func_name) orelse {
        // AST 不可达（可能是方法或内建函数）：为每个类型参数创建具名描述符
        const args = try alloc.alloc(TypeDescriptor, sig.type_params.len);
        for (sig.type_params, 0..) |tp_name, i| {
            args[i] = (ctx.sema_result.getOrCreateRefDesc(tp_name) catch unreachable).*;
        }
        return args;
    };
    std.debug.assert(fd_decl.* == .fun_decl);
    const fd = &fd_decl.fun_decl;

    var name_to_td = std.StringHashMap(*const TypeDescriptor).init(alloc);
    defer name_to_td.deinit();

    // 辅助：检查 name 是否为类型参数
    const isTypeParam = struct {
        fn check(name: []const u8, params: []const []const u8) bool {
            for (params) |tp| {
                if (std.mem.eql(u8, tp, name)) return true;
            }
            return false;
        }
    }.check;

    const param_count = @min(fd.params.len, arguments.len);

    // Pass 1: 匹配 .named 类型注解（如 init: A → 实参类型）
    for (0..param_count) |i| {
        const param_type = fd.params[i].type_annotation orelse continue;
        if (param_type.* != .named) continue;
        const pname = param_type.named.name;
        if (!isTypeParam(pname, sig.type_params)) continue;
        if (name_to_td.contains(pname)) continue;

        const arg_key = @intFromPtr(arguments[i]);
        if (ctx.sema_result.getExpr(arg_key)) |info| {
            try name_to_td.put(pname, tdFromExprInfo(info));
        }
    }

    // Pass 2: 匹配 .function 类型注解（如 f: (A, T) -> A）against lambda 实参
    for (0..param_count) |i| {
        const param_type = fd.params[i].type_annotation orelse continue;
        if (param_type.* != .function) continue;

        // 实参必须是 lambda 表达式
        if (arguments[i].* != .lambda) continue;
        const lambda = &arguments[i].lambda;

        // 匹配函数类型参数与 lambda 参数
        const fn_params = param_type.function.params;
        const lambda_params = lambda.params;
        const match_count = @min(fn_params.len, lambda_params.len);
        for (0..match_count) |j| {
            const fn_ptype = fn_params[j];
            if (fn_ptype.* != .named) continue;
            const fp_name = fn_ptype.named.name;
            if (!isTypeParam(fp_name, sig.type_params)) continue;
            if (name_to_td.contains(fp_name)) continue;

            // 从 lambda 参数的类型注解获取具体类型
            if (lambda_params[j].type_annotation) |lt| {
                if (type_resolver.resolveTypeNodeConcrete(lt, &.{}, ctx.sema_result)) |td| {
                    try name_to_td.put(fp_name, td);
                }
            }
        }

        // 匹配函数返回类型注解 → lambda 返回类型
        const fn_ret = param_type.function.return_type;
        if (fn_ret.* == .named) {
            const ret_name = fn_ret.named.name;
            if (isTypeParam(ret_name, sig.type_params) and !name_to_td.contains(ret_name)) {
                // 优先：lambda 显式返回类型注解
                if (lambda.return_type) |lrt| {
                    if (type_resolver.resolveTypeNodeConcrete(lrt, &.{}, ctx.sema_result)) |td| {
                        try name_to_td.put(ret_name, td);
                    }
                } else {
                    // 回退：从 lambda body 推断返回类型
                    if (inferLambdaReturnType(lambda, ctx)) |td| {
                        try name_to_td.put(ret_name, td);
                    }
                }
            }
        }
    }

    // Pass 3: .generic 类型注解（如 l: Lst<T>）— 提取类型参数名
    // 目前无法从 ref 通道提取元素类型，仅记录未绑定的类型参数名
    // 依赖 Pass 1/2 已绑定的类型参数
    for (0..param_count) |i| {
        const param_type = fd.params[i].type_annotation orelse continue;
        if (param_type.* != .generic) continue;
        for (param_type.generic.args) |arg| {
            if (arg.* != .named) continue;
            const arg_name = arg.named.name;
            if (!isTypeParam(arg_name, sig.type_params)) continue;
            if (name_to_td.contains(arg_name)) continue;
            // 无法从实参推断元素类型，跳过（依赖其他 pass 或回退）
        }
    }

    // 输出 type_args：type_name 设为类型参数名，使 resolveTypeNode 按名匹配
    // 未匹配的类型参数：用 getOrCreateRefDesc 创建具名描述符（而非回退到通用 ref_descriptor）
    const args = try alloc.alloc(TypeDescriptor, sig.type_params.len);
    for (sig.type_params, 0..) |tp_name, i| {
        var td = if (name_to_td.get(tp_name)) |t| t.* else (ctx.sema_result.getOrCreateRefDesc(tp_name) catch unreachable).*;
        td.type_name = tp_name;
        args[i] = td;
    }
    return args;
}

/// 从 lambda body 推断返回类型
/// 优先：显式返回类型注解 → body expression 的 ExprInfo → block trailing_expr 的 ExprInfo
fn inferLambdaReturnType(lambda: anytype, ctx: *WalkCtx) ?*const TypeDescriptor {
    if (lambda.return_type) |rt| {
        return type_resolver.resolveTypeNodeConcrete(rt, &.{}, ctx.sema_result);
    }
    switch (lambda.body) {
        .expression => |body_expr| {
            const key = @intFromPtr(body_expr);
            if (ctx.sema_result.getExpr(key)) |info| return info.type_desc;
        },
        .block => |block_expr| {
            if (block_expr.* == .block) {
                if (block_expr.block.trailing_expr) |trailing| {
                    const key = @intFromPtr(trailing);
                    if (ctx.sema_result.getExpr(key)) |info| return info.type_desc;
                }
            }
        },
    }
    return null;
}

/// 查找或创建 MonomorphInstance
///
/// 1. 查 monomorph_index 缓存命中 → 返回 instance_id
/// 2. 未命中：创建新实例、写入 monomorph_instances、写入缓存
/// 3. 对新实例：用具体 type_args 解析函数体内所有表达式类型，存入实例本地表
///
/// type_args 切片所有权转移给 MonomorphInstance（由 sema_result.allocator 分配）
/// cache_key 由 sema_result.allocator 分配，生命周期与 SemaResult 一致
fn getOrCreateInstance(
    func_name: []const u8,
    type_args: []const TypeDescriptor,
    fd_decl: *const ast.Decl,
    ctx: *WalkCtx,
) WalkError!u32 {
    const alloc = ctx.sema_result.allocator;
    const cache_key = try buildCacheKey(alloc, func_name, type_args);

    // 1. 查缓存
    if (ctx.sema_result.monomorph_index.get(cache_key)) |idx| {
        alloc.free(cache_key);
        return idx;
    }

    // 2. 循环检测：前向引用支持
    //    若该实例正在实例化中（递归调用），返回预分配的 instance_id
    if (ctx.in_progress.get(cache_key)) |existing_id| {
        alloc.free(cache_key);
        return existing_id;
    }

    // 3. 新建实例
    std.debug.assert(fd_decl.* == .fun_decl);
    const fd = &fd_decl.fun_decl;

    const instance_id: u32 = @intCast(ctx.sema_result.monomorph_instances.items.len);

    const return_td = type_resolver.resolveTypeNodeConcrete(fd.return_type, type_args, ctx.sema_result) orelse
        ctx.sema_result.getOrCreateRefDesc("return") catch unreachable;

    // 空通道布局（实际布局由 IRBuilder 在编译实例体时计算）
    const empty_layout = ChanLayout{
        .local_chan_count = 0,
        .return_channel = 0,
        .local_offsets = &.{},
        .chan_type_descs = &.{},
        .chan_total_bytes = 0,
    };

    var instance = MonomorphInstance{
        .instance_id = instance_id,
        .func_name = func_name,
        .type_args = type_args,
        .chan_layout = empty_layout,
        .return_type = return_td,
        .is_async = fd.is_async,
        .expr_types = std.AutoHashMap(u64, ExprInfo).init(alloc),
        .field_accesses = std.AutoHashMap(u64, FieldAccessInfo).init(alloc),
    };

    // 4. 标记为正在实例化（前向引用支持）
    //    in_progress 使用独立 key 副本（dup），避免与 monomorph_index 的 key 双重释放
    const in_progress_key = try alloc.dupe(u8, cache_key);
    try ctx.in_progress.put(in_progress_key, instance_id);

    // 5. 递归解析函数体类型（可能触发前向引用，此时返回预分配的 instance_id）
    //    替代 IRBuilder 的 infer* 系列函数（变量绑定回溯 + 泛型字段访问）
    try resolveInstanceBodyTypes(&instance, fd, ctx);

    try ctx.sema_result.monomorph_instances.append(ctx.sema_result.allocator, instance);

    // 6. 写入 monomorph_index 缓存（cache_key 转移给 monomorph_index，与 SemaResult 同生命周期）
    try ctx.sema_result.monomorph_index.put(cache_key, instance_id);

    return instance_id;
}

// ════════════════════════════════════════════════════════════════
// AST 递归遍历：收集泛型调用点
// ════════════════════════════════════════════════════════════════

/// 处理直接调用表达式（callee 为标识符）
///
/// 仅处理 callee 是 identifier 的直接函数调用。方法调用、闭包调用等
/// 由 processMethodCall 处理或跳过（递归遍历仍会进入 object/arguments）。
fn processCall(
    callee: *const ast.Expr,
    arguments: []const *const ast.Expr,
    type_args_hint: ?[]*ast.TypeNode,
    call_expr: *const ast.Expr,
    ctx: *WalkCtx,
) WalkError!void {
    // 仅处理直接标识符调用：foo(args) 或 foo<T>(args)
    if (callee.* != .identifier) return;
    const func_name = callee.identifier.name;

    // 查函数签名：跳过未注册函数与非泛型函数
    const sig = ctx.sema_result.getFuncSig(func_name) orelse return;
    if (sig.type_params.len == 0) return;

    // 查函数 AST（用于参数类型注解与返回类型）
    const fd_decl = ctx.func_decls.get(func_name) orelse return;

    // 推导 type_args（显式或隐式）
    const type_args = try inferTypeArgs(func_name, arguments, type_args_hint, sig, ctx);

    // 查找或创建实例
    const instance_id = try getOrCreateInstance(func_name, type_args, fd_decl, ctx);

    // 记录调用点 → 实例映射
    try ctx.sema_result.call_instantiations.put(@intFromPtr(call_expr), instance_id);
}

/// 处理方法调用表达式
///
/// 方法调用通过 trait 分派，完整解析需要对象类型构造 mangled 名。
/// 此处采用最佳努力策略：直接以方法名查 func_sig，命中则处理；
/// 未命中则跳过。递归遍历仍会进入 object/arguments，保证嵌套调用被收集。
fn processMethodCall(
    method: []const u8,
    arguments: []const *const ast.Expr,
    type_args_hint: ?[]*ast.TypeNode,
    call_expr: *const ast.Expr,
    ctx: *WalkCtx,
) WalkError!void {
    // 直接以方法名查 func_sig（覆盖同名顶层函数的罕见场景）
    const sig = ctx.sema_result.getFuncSig(method) orelse return;
    if (sig.type_params.len == 0) return;

    const fd_decl = ctx.func_decls.get(method) orelse return;

    const type_args = try inferTypeArgs(method, arguments, type_args_hint, sig, ctx);
    const instance_id = try getOrCreateInstance(method, type_args, fd_decl, ctx);
    try ctx.sema_result.call_instantiations.put(@intFromPtr(call_expr), instance_id);

    // v3 阶段 1：记录方法分派元信息（最佳努力匹配，完整 trait 解析留待后续阶段）
    // instance_id 暂存泛型方法实例，trait_id/method_idx/impl_fn_idx 待 trait 解析完善后填充
    try ctx.sema_result.method_dispatches.put(@intFromPtr(call_expr), .{
        .trait_id = 0,
        .method_idx = 0,
        .impl_fn_idx = 0,
        .instance_id = instance_id,
    });
}

/// 递归遍历 Stmt，收集所有嵌套的泛型调用点
fn walkStmt(stmt: *const ast.Stmt, ctx: *WalkCtx) WalkError!void {
    switch (stmt.*) {
        .val_decl => |v| try walkExpr(v.value, ctx),
        .var_decl => |v| try walkExpr(v.value, ctx),
        .assignment => |a| {
            try walkExpr(a.target, ctx);
            try walkExpr(a.value, ctx);
        },
        .field_assignment => |f| {
            try walkExpr(f.object, ctx);
            try walkExpr(f.value, ctx);
        },
        .compound_assignment => |c| {
            try walkExpr(c.target, ctx);
            try walkExpr(c.value, ctx);
        },
        .expression => |e| try walkExpr(e.expr, ctx),
        .return_stmt => |r| if (r.value) |v| try walkExpr(v, ctx),
        .defer_stmt => |d| try walkExpr(d.expr, ctx),
        .throw_stmt => |t| try walkExpr(t.expr, ctx),
        .break_stmt, .continue_stmt => {},
        .for_stmt => |f| {
            try walkExpr(f.iterable, ctx);
            try walkExpr(f.body, ctx);
        },
        .while_stmt => |w| {
            try walkExpr(w.condition, ctx);
            try walkExpr(w.body, ctx);
        },
        .loop_stmt => |l| try walkExpr(l.body, ctx),
    }
}

/// 递归遍历 Expr，收集所有泛型调用点
///
/// 对 call/method_call/safe_method_call 三种调用表达式，提取调用元信息并
/// 推导 type_args。同时递归进入所有子表达式，确保嵌套调用被完整收集。
fn walkExpr(expr: *const ast.Expr, ctx: *WalkCtx) WalkError!void {
    switch (expr.*) {
        // ── 调用表达式：核心收集目标 ──
        .call => |c| {
            try processCall(c.callee, c.arguments, c.type_args, expr, ctx);
            try walkExpr(c.callee, ctx);
            for (c.arguments) |arg| try walkExpr(arg, ctx);
        },
        .method_call => |mc| {
            try processMethodCall(mc.method, mc.arguments, mc.type_args, expr, ctx);
            try walkExpr(mc.object, ctx);
            for (mc.arguments) |arg| try walkExpr(arg, ctx);
        },
        .safe_method_call => |smc| {
            try processMethodCall(smc.method, smc.arguments, smc.type_args, expr, ctx);
            try walkExpr(smc.object, ctx);
            for (smc.arguments) |arg| try walkExpr(arg, ctx);
        },

        // ── 一元/二元/赋值 ──
        .binary => |b| {
            try walkExpr(b.left, ctx);
            try walkExpr(b.right, ctx);
        },
        .unary => |u| try walkExpr(u.operand, ctx),
        .ref_of => |r| try walkExpr(r.operand, ctx),
        .deref => |d| try walkExpr(d.operand, ctx),
        .assignment_expr => |a| {
            try walkExpr(a.target, ctx);
            try walkExpr(a.value, ctx);
        },
        .compound_assign => |c| {
            try walkExpr(c.target, ctx);
            try walkExpr(c.value, ctx);
        },
        .non_null_assert => |n| try walkExpr(n.expr, ctx),
        .propagate => |p| try walkExpr(p.expr, ctx),

        // ── 字段访问与索引 ──
        .field_access => |f| try walkExpr(f.object, ctx),
        .safe_access => |s| try walkExpr(s.object, ctx),
        .index => |i| {
            try walkExpr(i.object, ctx);
            try walkExpr(i.index, ctx);
        },
        .slice => |s| {
            try walkExpr(s.object, ctx);
            try walkExpr(s.start, ctx);
            try walkExpr(s.end, ctx);
        },

        // ── 容器字面量 ──
        .array_literal => |al| {
            for (al.elements) |e| try walkExpr(e, ctx);
            if (al.fill_value) |fv| try walkExpr(fv, ctx);
            if (al.fill_count) |fc| try walkExpr(fc, ctx);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try walkExpr(f.value, ctx);
        },
        .record_extend => |re| {
            try walkExpr(re.base, ctx);
            for (re.updates) |f| try walkExpr(f.value, ctx);
        },

        // ── 控制流 ──
        .lambda => |l| switch (l.body) {
            .block => |b| try walkExpr(b, ctx),
            .expression => |e| try walkExpr(e, ctx),
        },
        .if_expr => |i| {
            try walkExpr(i.condition, ctx);
            try walkExpr(i.then_branch, ctx);
            if (i.else_branch) |e| try walkExpr(e, ctx);
        },
        .block => |b| {
            for (b.statements) |s| try walkStmt(s, ctx);
            if (b.trailing_expr) |te| try walkExpr(te, ctx);
        },
        .match => |m| {
            try walkExpr(m.scrutinee, ctx);
            for (m.arms) |arm| {
                if (arm.guard) |g| try walkExpr(g, ctx);
                try walkExpr(arm.body, ctx);
            }
        },

        // ── 类型转换 ──
        .type_cast => |tc| try walkExpr(tc.expr, ctx),
        .cast_builder => |cb| try walkExpr(cb.expr, ctx),

        // ── 并发/异步 ──
        .atomic_expr => |ae| try walkExpr(ae.value, ctx),
        .lazy => |l| try walkExpr(l.expr, ctx),
        .spawn_expr => |se| try walkExpr(se.expr, ctx),
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    try walkExpr(r.channel_expr, ctx);
                    try walkExpr(r.body, ctx);
                },
                .timeout => |t| {
                    try walkExpr(t.duration, ctx);
                    try walkExpr(t.body, ctx);
                },
            };
        },

        // ── 字符串插值 ──
        .string_interpolation => |si| {
            for (si.parts) |part| switch (part) {
                .literal => {},
                .expression => |e| try walkExpr(e, ctx),
            };
        },

        // ── inline trait value：方法体可能含泛型调用 ──
        .inline_trait_value => |itv| {
            for (itv.methods) |method| {
                if (method.body) |body| try walkExpr(body, ctx);
            }
        },

        // ── 终端节点：无需递归 ──
        .int_literal,
        .float_literal,
        .bool_literal,
        .char_literal,
        .string_literal,
        .null_literal,
        .unit_literal,
        .identifier,
        => {},
    }
}

// ════════════════════════════════════════════════════════════════
// 主入口：collectMonomorphInstances
// ════════════════════════════════════════════════════════════════

/// 收集模块中所有泛型调用点，产出单态化实例集合
///
/// v3 spec §5.2 collectMonomorphInstances 算法：
/// 1. 构建 func_name → fun_decl 映射，供推导 type_args 时查询参数类型注解
/// 2. 遍历所有顶层声明：
///    a. 非泛型 fun_decl → 创建空 type_args 实例
///    b. 所有 fun_decl 体 / type_decl 方法体 / expr_decl → 递归遍历
/// 3. 对每个泛型调用点：推导 type_args → 去重 → 创建实例 → 记录调用点映射
///
/// 泛型函数本身不创建空实例（其具体实例由调用点驱动生成）。
/// 方法调用的完整 trait 分派解析留待后续阶段，当前仅做最佳努力匹配。
pub fn collectMonomorphInstances(
    module: *const ast.Module,
    sema_result: *SemaResult,
) WalkError!void {
    // v3 阶段 1：注册内置标量 TypeDescriptor 到全局表
    try type_resolver.registerBuiltinTypeDescriptors(sema_result);

    var ctx = WalkCtx{
        .sema_result = sema_result,
        .module = module,
        .func_decls = std.StringHashMap(*const ast.Decl).init(sema_result.allocator),
        .in_progress = std.StringHashMap(u32).init(sema_result.allocator),
    };
    defer {
        // 释放 in_progress 的 dup keys（所有权属于 in_progress，与 monomorph_index 隔离）
        var it = ctx.in_progress.iterator();
        while (it.next()) |entry| {
            sema_result.allocator.free(entry.key_ptr.*);
        }
        ctx.in_progress.deinit();
        ctx.func_decls.deinit();
    }

    // 1. 构建 func_name → *const ast.Decl 映射（仅顶层 fun_decl）
    for (module.declarations) |*decl| {
        switch (decl.*) {
            .fun_decl => |fd| {
                try ctx.func_decls.put(fd.name, decl);
            },
            else => {},
        }
    }

    // 2. 遍历所有顶层声明
    for (module.declarations) |*decl| {
        switch (decl.*) {
            .fun_decl => |fd| {
                // 非泛型函数：创建空 type_args 实例
                // （泛型函数不创建空实例，由调用点驱动）
                if (fd.type_params.len == 0) {
                    const empty_type_args = try sema_result.allocator.alloc(TypeDescriptor, 0);

                    const return_td = type_resolver.resolveTypeNodeConcrete(fd.return_type, empty_type_args, sema_result) orelse
                        sema_result.getOrCreateRefDesc("return") catch unreachable;

                    const empty_layout = ChanLayout{
                        .local_chan_count = 0,
                        .return_channel = 0,
                        .local_offsets = &.{},
                        .chan_type_descs = &.{},
                        .chan_total_bytes = 0,
                    };

                    const instance = MonomorphInstance{
                        .instance_id = @intCast(sema_result.monomorph_instances.items.len),
                        .func_name = fd.name,
                        .type_args = empty_type_args,
                        .chan_layout = empty_layout,
                        .return_type = return_td,
                        .is_async = fd.is_async,
                        .expr_types = std.AutoHashMap(u64, ExprInfo).init(sema_result.allocator),
                        .field_accesses = std.AutoHashMap(u64, FieldAccessInfo).init(sema_result.allocator),
                    };
                    try sema_result.monomorph_instances.append(sema_result.allocator, instance);

                    // 非泛型函数：遍历函数体收集泛型调用点
                    // （泛型函数体的调用点在 resolveInstanceBodyTypes 中发现，
                    //  因为它们依赖当前实例的 type_args 上下文才能正确推断类型实参）
                    try walkExpr(fd.body, &ctx);
                }
            },

            // 类型声明：遍历非泛型方法体（泛型方法体在实例化时发现）
            .type_decl => |td| {
                for (td.methods) |method| {
                    if (method.type_params.len > 0) continue; // 跳过泛型方法体
                    if (method.body) |body| try walkExpr(body, &ctx);
                }
            },

            // 顶层表达式声明：遍历表达式
            .expr_decl => |ed| {
                try walkExpr(ed.expr, &ctx);
                if (ed.stmt) |s| try walkStmt(s, &ctx);
            },

            // import / pack：无需遍历
            else => {},
        }
    }
}

// ════════════════════════════════════════════════════════════════
// 实例体类型解析：用具体 type_args 解析函数体内所有表达式类型
// ════════════════════════════════════════════════════════════════

/// 实例体类型解析的错误集（显式定义以打破 resolveExpr ↔ resolveStmt 递归错误集循环）
const ResolveError = error{OutOfMemory};

/// 实例本地变量绑定（name → 类型描述符）
/// 用于解析 identifier 表达式的类型（回溯 val/var 声明）
const LocalBinding = struct {
    type_desc: *const TypeDescriptor,
};

/// 实例体类型解析上下文
const ResolveCtx = struct {
    instance: *MonomorphInstance,
    sema_result: *SemaResult,
    type_args: []const TypeDescriptor,
    allocator: std.mem.Allocator,
    /// 变量名 → 类型描述符（局部变量绑定，作用域栈）
    bindings: std.ArrayList(std.StringHashMap(LocalBinding)),
    /// 类型参数名 → type_args 索引（快速查找）
    type_param_map: std.StringHashMap(u16),
    /// WalkCtx 引用：用于在函数体内发现泛型调用点时创建实例
    /// （泛型函数体内的调用依赖当前实例的 type_args 上下文，
    /// 顶层 walk 无法正确推断，故在 resolveInstanceBodyTypes 中发现并创建）
    walk_ctx: *WalkCtx,

    fn init(allocator: std.mem.Allocator, instance: *MonomorphInstance, sema_result: *SemaResult, fd: anytype, walk_ctx: *WalkCtx) !ResolveCtx {
        var ctx = ResolveCtx{
            .instance = instance,
            .sema_result = sema_result,
            .type_args = instance.type_args,
            .allocator = allocator,
            .bindings = .empty,
            .type_param_map = std.StringHashMap(u16).init(allocator),
            .walk_ctx = walk_ctx,
        };
        // 构建类型参数名 → 索引映射
        for (fd.type_params, 0..) |tp, i| {
            try ctx.type_param_map.put(tp.name, @intCast(i));
        }
        // 压入初始作用域
        try ctx.bindings.append(allocator, std.StringHashMap(LocalBinding).init(allocator));
        return ctx;
    }

    fn deinit(self: *ResolveCtx) void {
        for (self.bindings.items) |*b| b.deinit();
        self.bindings.deinit(self.allocator);
        self.type_param_map.deinit();
    }

    fn pushScope(self: *ResolveCtx) !void {
        try self.bindings.append(self.allocator, std.StringHashMap(LocalBinding).init(self.allocator));
    }

    fn popScope(self: *ResolveCtx) void {
        if (self.bindings.items.len > 1) {
            var scope = self.bindings.pop() orelse return;
            scope.deinit();
        }
    }

    fn defineVar(self: *ResolveCtx, name: []const u8, td: *const TypeDescriptor) !void {
        try self.bindings.items[self.bindings.items.len - 1].put(name, .{ .type_desc = td });
    }

    fn lookupVar(self: *const ResolveCtx, name: []const u8) ?*const TypeDescriptor {
        var i: usize = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bindings.items[i].get(name)) |b| return b.type_desc;
        }
        return null;
    }
};

/// 用具体 type_args 解析函数体内所有表达式类型
///
/// 递归遍历函数体 AST，对每个表达式计算其类型并存入 instance.expr_types。
/// 对 field_access 表达式额外存入 instance.field_accesses。
/// 替代 IRBuilder 的 infer* 系列函数。
fn resolveInstanceBodyTypes(
    instance: *MonomorphInstance,
    fd: anytype,
    ctx: *WalkCtx,
) ResolveError!void {
    var rctx = try ResolveCtx.init(ctx.sema_result.allocator, instance, ctx.sema_result, fd, ctx);
    defer rctx.deinit();

    // 注册函数参数到变量绑定
    for (fd.params, 0..) |param, i| {
        const td = if (param.type_annotation) |ta|
            type_resolver.resolveTypeNodeConcrete(ta, instance.type_args, ctx.sema_result) orelse
                ctx.sema_result.getOrCreateRefDesc("param") catch unreachable
        else
            ctx.sema_result.getOrCreateRefDesc("param") catch unreachable;
        _ = i;
        try rctx.defineVar(param.name, td);
    }

    // 遍历函数体
    try resolveExpr(fd.body, &rctx);
}

/// 在函数体内发现泛型调用点时，用当前实例的 type_args 上下文推断 type_args 并创建实例
///
/// 与顶层 processCall 的区别：
/// - 顶层 processCall 依赖 sema_result.expr_types（HM 推断产出），无法解析类型参数 T
/// - 此函数用 resolveExprType 递归解析实参类型，能利用当前实例的 type_args 将 T 解析为具体类型
fn processCallInBody(
    func_name: []const u8,
    arguments: []const *const ast.Expr,
    type_args_hint: ?[]*ast.TypeNode,
    call_expr: *const ast.Expr,
    ctx: *ResolveCtx,
) ResolveError!void {
    const sig = ctx.sema_result.getFuncSig(func_name) orelse return;
    if (sig.type_params.len == 0) return; // 非泛型函数，无需单态化

    const fd_decl = ctx.walk_ctx.func_decls.get(func_name) orelse return;

    const type_args = try inferTypeArgsInBody(func_name, arguments, type_args_hint, sig, fd_decl, ctx);

    // 查找或创建实例（getOrCreateInstance 在缓存命中时不释放 type_args，需手动处理）
    const existing_id = findInstance(ctx.sema_result, func_name, type_args);
    if (existing_id) |id| {
        // 缓存命中：type_args 不被实例拥有，需释放
        ctx.sema_result.allocator.free(type_args);
        try ctx.sema_result.call_instantiations.put(@intFromPtr(call_expr), id);
        return;
    }

    const instance_id = getOrCreateInstance(func_name, type_args, fd_decl, ctx.walk_ctx) catch return;
    try ctx.sema_result.call_instantiations.put(@intFromPtr(call_expr), instance_id);
}

/// 在实例体上下文中推断 type_args
///
/// 与顶层 inferTypeArgs 的区别：
/// - 显式类型实参：用当前实例的 type_args 解析类型参数 T（而非空 type_args）
/// - 隐式推断：用 resolveExprType 递归解析实参类型（而非 sema_result.expr_types）
fn inferTypeArgsInBody(
    func_name: []const u8,
    arguments: []const *const ast.Expr,
    type_args_hint: ?[]*ast.TypeNode,
    sig: FuncSigInfo,
    fd_decl: *const ast.Decl,
    ctx: *ResolveCtx,
) ![]const TypeDescriptor {
    const alloc = ctx.sema_result.allocator;

    // 1. 显式类型实参：用当前实例的 type_args 解析（支持 foo<T>(x) 中 T 为外层类型参数）
    if (type_args_hint) |hints| {
        if (hints.len > 0) {
            const args = try alloc.alloc(TypeDescriptor, hints.len);
            for (hints, 0..) |tn, i| {
                args[i] = if (type_resolver.resolveTypeNodeConcrete(tn, ctx.type_args, ctx.sema_result)) |td| td.* else (ctx.sema_result.getOrCreateRefDesc("type_arg") catch unreachable).*;
            }
            return args;
        }
    }

    // 2. 直接递归：递归调用自身时，type_args 与当前实例一致
    //    （如 foldl<T,A> 体内的 foldl(t, f(init,x), f) 使用相同 T,A）
    //    这避免了从 .generic 类型参数（Lst<T>）和非 lambda 实参无法推断 T 的问题
    if (std.mem.eql(u8, func_name, ctx.instance.func_name)) {
        const args = try alloc.alloc(TypeDescriptor, ctx.type_args.len);
        for (ctx.type_args, 0..) |ta, i| args[i] = ta;
        return args;
    }

    // 3. 隐式推断
    std.debug.assert(fd_decl.* == .fun_decl);
    const fd = &fd_decl.fun_decl;

    var name_to_td = std.StringHashMap(*const TypeDescriptor).init(alloc);
    defer name_to_td.deinit();

    const isTypeParam = struct {
        fn check(name: []const u8, params: []const []const u8) bool {
            for (params) |tp| {
                if (std.mem.eql(u8, tp, name)) return true;
            }
            return false;
        }
    }.check;

    const param_count = @min(fd.params.len, arguments.len);

    // Pass 1: .named 类型注解
    for (0..param_count) |i| {
        const param_type = fd.params[i].type_annotation orelse continue;
        if (param_type.* != .named) continue;
        const pname = param_type.named.name;
        if (!isTypeParam(pname, sig.type_params)) continue;
        if (name_to_td.contains(pname)) continue;

        const arg_td = resolveExprType(arguments[i], ctx) orelse continue;
        try name_to_td.put(pname, arg_td);
    }

    // Pass 2: .function 类型注解 → lambda 实参的参数类型注解
    for (0..param_count) |i| {
        const param_type = fd.params[i].type_annotation orelse continue;
        if (param_type.* != .function) continue;

        if (arguments[i].* != .lambda) continue;
        const lambda = &arguments[i].lambda;

        const fn_params = param_type.function.params;
        const lambda_params = lambda.params;
        const match_count = @min(fn_params.len, lambda_params.len);
        for (0..match_count) |j| {
            const fn_ptype = fn_params[j];
            if (fn_ptype.* != .named) continue;
            const fp_name = fn_ptype.named.name;
            if (!isTypeParam(fp_name, sig.type_params)) continue;
            if (name_to_td.contains(fp_name)) continue;

            if (lambda_params[j].type_annotation) |lt| {
                if (type_resolver.resolveTypeNodeConcrete(lt, ctx.type_args, ctx.sema_result)) |td| {
                    try name_to_td.put(fp_name, td);
                }
            }
        }

        // 返回类型注解 → lambda 返回类型
        const fn_ret = param_type.function.return_type;
        if (fn_ret.* == .named) {
            const ret_name = fn_ret.named.name;
            if (isTypeParam(ret_name, sig.type_params) and !name_to_td.contains(ret_name)) {
                if (lambda.return_type) |lrt| {
                    if (type_resolver.resolveTypeNodeConcrete(lrt, ctx.type_args, ctx.sema_result)) |td| {
                        try name_to_td.put(ret_name, td);
                    }
                }
            }
        }
    }

    // 按 sig.type_params 顺序输出 TypeDescriptor
    // type_name 设为类型参数名，使 resolveTypeNode 能按名匹配类型参数
    // 未匹配的类型参数：用 getOrCreateRefDesc 创建具名描述符（而非回退到通用 ref_descriptor）
    const args = try alloc.alloc(TypeDescriptor, sig.type_params.len);
    for (sig.type_params, 0..) |tp_name, i| {
        var td = if (name_to_td.get(tp_name)) |t| t.* else (ctx.sema_result.getOrCreateRefDesc(tp_name) catch unreachable).*;
        td.type_name = tp_name;
        args[i] = td;
    }
    return args;
}

/// 解析表达式类型并存入实例表
fn resolveExpr(expr: *const ast.Expr, ctx: *ResolveCtx) ResolveError!void {
    // 对调用表达式：先发现并创建被调用函数的实例（填充 call_instantiations），
    // 再计算返回类型（resolveExprType 的 .call 分支会查询 call_instantiations）
    switch (expr.*) {
        .call => |c| {
            if (c.callee.* == .identifier) {
                processCallInBody(c.callee.identifier.name, c.arguments, c.type_args, expr, ctx) catch {};
            }
        },
        .method_call => |mc| {
            processCallInBody(mc.method, mc.arguments, mc.type_args, expr, ctx) catch {};
        },
        .safe_method_call => |smc| {
            processCallInBody(smc.method, smc.arguments, smc.type_args, expr, ctx) catch {};
        },
        else => {},
    }

    const td = resolveExprType(expr, ctx) orelse
        ctx.sema_result.getOrCreateRefDesc("unknown") catch unreachable;

    // 存入实例本地表达式类型表
    try ctx.instance.expr_types.put(@intFromPtr(expr), .{
        .type_desc = td,
        .type_name = td.type_name,
        .is_ref_type = td.isRef(),
    });

    // v3 阶段 1：同步填充 sema_result.resolved_type_descs（全局表达式→TypeDescriptor 映射）
    try ctx.sema_result.resolved_type_descs.put(@intFromPtr(expr), td);

    // 递归处理子表达式
    switch (expr.*) {
        .field_access => |fa| {
            // 额外存入 field_accesses 元信息
            const obj_td = resolveExprType(fa.object, ctx) orelse
                ctx.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
            if (ctx.sema_result.lookupFieldId(obj_td.type_name, fa.field)) |field_id| {
                // 查询字段类型
                if (ctx.sema_result.getCtorDef(obj_td.type_name)) |ctor| {
                    const idx = field_id;
                    if (idx > 0 and idx - 1 < ctor.field_type_descs.len) {
                        const field_td = ctor.field_type_descs[idx - 1];
                        try ctx.instance.field_accesses.put(@intFromPtr(expr), .{
                            .obj_type_desc = obj_td,
                            .field_idx = field_id,
                            .field_type_desc = field_td,
                        });
                    }
                }
            }
            try resolveExpr(fa.object, ctx);
        },
        .call => |c| {
            try resolveExpr(c.callee, ctx);
            for (c.arguments) |arg| try resolveExpr(arg, ctx);
        },
        .method_call => |mc| {
            try resolveExpr(mc.object, ctx);
            for (mc.arguments) |arg| try resolveExpr(arg, ctx);
        },
        .safe_method_call => |smc| {
            try resolveExpr(smc.object, ctx);
            for (smc.arguments) |arg| try resolveExpr(arg, ctx);
        },
        .binary => |b| {
            try resolveExpr(b.left, ctx);
            try resolveExpr(b.right, ctx);
        },
        .unary => |u| try resolveExpr(u.operand, ctx),
        .ref_of => |r| try resolveExpr(r.operand, ctx),
        .deref => |d| try resolveExpr(d.operand, ctx),
        .assignment_expr => |a| {
            try resolveExpr(a.target, ctx);
            try resolveExpr(a.value, ctx);
        },
        .compound_assign => |c| {
            try resolveExpr(c.target, ctx);
            try resolveExpr(c.value, ctx);
        },
        .non_null_assert => |n| try resolveExpr(n.expr, ctx),
        .propagate => |p| try resolveExpr(p.expr, ctx),
        .safe_access => |s| try resolveExpr(s.object, ctx),
        .index => |i| {
            try resolveExpr(i.object, ctx);
            try resolveExpr(i.index, ctx);
        },
        .slice => |s| {
            try resolveExpr(s.object, ctx);
            try resolveExpr(s.start, ctx);
            try resolveExpr(s.end, ctx);
        },
        .array_literal => |al| {
            for (al.elements) |e| try resolveExpr(e, ctx);
            if (al.fill_value) |fv| try resolveExpr(fv, ctx);
            if (al.fill_count) |fc| try resolveExpr(fc, ctx);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try resolveExpr(f.value, ctx);
        },
        .record_extend => |re| {
            try resolveExpr(re.base, ctx);
            for (re.updates) |f| try resolveExpr(f.value, ctx);
        },
        .if_expr => |i| {
            try resolveExpr(i.condition, ctx);
            try resolveExpr(i.then_branch, ctx);
            if (i.else_branch) |eb| try resolveExpr(eb, ctx);
        },
        .match => |m| {
            try resolveExpr(m.scrutinee, ctx);
            for (m.arms) |arm| {
                try ctx.pushScope();
                defer ctx.popScope();
                // 注册 pattern 绑定
                try resolvePattern(arm.pattern, ctx);
                try resolveExpr(arm.body, ctx);
            }
        },
        .block => |b| {
            try ctx.pushScope();
            defer ctx.popScope();
            for (b.statements) |stmt| try resolveStmt(stmt, ctx);
            if (b.trailing_expr) |r| try resolveExpr(r, ctx);
        },
        .lambda => |l| switch (l.body) {
            .block => |blk| try resolveExpr(blk, ctx),
            .expression => |e| try resolveExpr(e, ctx),
        },
        else => {},
    }
}

/// 解析语句（递归处理声明和控制流）
fn resolveStmt(stmt: *const ast.Stmt, ctx: *ResolveCtx) ResolveError!void {
    switch (stmt.*) {
        .val_decl => |v| {
            const td = resolveExprType(v.value, ctx) orelse
                ctx.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
            try resolveExpr(v.value, ctx);
            try ctx.defineVar(v.name, td);
        },
        .var_decl => |v| {
            const td = resolveExprType(v.value, ctx) orelse
                ctx.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
            try resolveExpr(v.value, ctx);
            try ctx.defineVar(v.name, td);
        },
        .assignment => |a| {
            try resolveExpr(a.target, ctx);
            try resolveExpr(a.value, ctx);
        },
        .field_assignment => |f| {
            try resolveExpr(f.object, ctx);
            try resolveExpr(f.value, ctx);
        },
        .compound_assignment => |c| {
            try resolveExpr(c.target, ctx);
            try resolveExpr(c.value, ctx);
        },
        .expression => |e| try resolveExpr(e.expr, ctx),
        .return_stmt => |r| if (r.value) |v| try resolveExpr(v, ctx),
        .defer_stmt => |d| try resolveExpr(d.expr, ctx),
        .throw_stmt => |t| try resolveExpr(t.expr, ctx),
        .break_stmt, .continue_stmt => {},
        .for_stmt => |f| {
            try resolveExpr(f.iterable, ctx);
            try ctx.pushScope();
            defer ctx.popScope();
            // 从迭代对象推断元素类型
            const iter_td = resolveExprType(f.iterable, ctx) orelse
                ctx.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
            try ctx.defineVar(f.name, iter_td);
            try resolveExpr(f.body, ctx);
        },
        .while_stmt => |w| {
            try resolveExpr(w.condition, ctx);
            try resolveExpr(w.body, ctx);
        },
        .loop_stmt => |l| try resolveExpr(l.body, ctx),
    }
}

/// 解析 match pattern 中的变量绑定
fn resolvePattern(pattern: *const ast.Pattern, ctx: *ResolveCtx) ResolveError!void {
    switch (pattern.*) {
        .variable => |v| {
            // pattern 变量类型未知，用 getOrCreateRefDesc 创建具名描述符
            const td = ctx.sema_result.getOrCreateRefDesc("pattern_var") catch unreachable;
            try ctx.defineVar(v.name, td);
        },
        .constructor => |cp| {
            for (cp.patterns) |fp| try resolvePattern(fp, ctx);
        },
        .record => |rp| {
            for (rp.fields) |field| try resolvePattern(field.pattern, ctx);
        },
        .or_pattern => |op| {
            try resolvePattern(op.left, ctx);
            try resolvePattern(op.right, ctx);
        },
        .guard => |g| try resolvePattern(g.pattern, ctx),
        else => {},
    }
}

/// 解析表达式的类型（不存入表，仅返回类型描述符）
///
/// 核心类型推断逻辑：
/// 1. 字面量：直接映射（int_literal → i32, string_literal → ref 等）
/// 2. identifier：查变量绑定，回退到 sema_result.expr_types
/// 3. field_access：查对象类型的字段类型
/// 4. call/method_call：查函数签名返回类型
/// 5. 其他：回退到 sema_result.expr_types
fn resolveExprType(expr: *const ast.Expr, ctx: *ResolveCtx) ?*const TypeDescriptor {
    switch (expr.*) {
        .int_literal => |il| {
            if (il.suffix) |s| {
                if (type_resolver.resolveTypeNodeConcrete(&.{ .named = .{ .name = s } }, ctx.type_args, ctx.sema_result)) |td| return td;
            }
            return type_descriptor_mod.lookupByScalarKind(.i32);
        },
        .float_literal => |fl| {
            if (fl.suffix) |s| {
                if (type_resolver.resolveTypeNodeConcrete(&.{ .named = .{ .name = s } }, ctx.type_args, ctx.sema_result)) |td| return td;
            }
            return type_descriptor_mod.lookupByScalarKind(.f64);
        },
        .bool_literal => return type_descriptor_mod.lookupByScalarKind(.bool),
        .char_literal => return type_descriptor_mod.lookupByScalarKind(.char),
        .string_literal, .string_interpolation => return ir_mod.type_descriptor_mod.str_descriptor,
        .null_literal => return &type_resolver.null_type_descriptor,
        .unit_literal => return &type_resolver.unit_type_descriptor,
        .identifier => |id| {
            // 1. 查类型参数绑定
            if (ctx.type_param_map.get(id.name)) |idx| {
                if (idx < ctx.type_args.len) return &ctx.type_args[idx];
            }
            // 2. 查局部变量绑定
            if (ctx.lookupVar(id.name)) |td| return td;
            // 3. 查 sema_result.expr_types
            if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
                return info.type_desc;
            }
            return null;
        },
        .field_access => |fa| {
            // 递归解析对象类型，再查字段类型
            const obj_td = resolveExprType(fa.object, ctx) orelse return null;
            if (ctx.sema_result.lookupFieldId(obj_td.type_name, fa.field)) |field_id| {
                if (ctx.sema_result.getCtorDef(obj_td.type_name)) |ctor| {
                    if (field_id > 0 and field_id - 1 < ctor.field_type_descs.len) {
                        return ctor.field_type_descs[field_id - 1];
                    }
                }
            }
            return ctx.sema_result.getOrCreateRefDesc(obj_td.type_name) catch unreachable;
        },
        .call => |c| {
            if (c.callee.* == .identifier) {
                // 构造器调用：返回以类型名命名的具体描述符
                if (ctx.sema_result.getCtorDef(c.callee.identifier.name)) |ctor| {
                    const ret_name = ctor.return_type_name orelse ctor.type_name;
                    return ctx.sema_result.getOrCreateRefDesc(ret_name) catch unreachable;
                }
                // 优先查询 call_instantiations：泛型调用点已由 processCallInBody 创建实例
                // 实例的 return_type 用具体 type_args 解析，避免 sig.return_type_desc 的 ref_chan 回退
                if (ctx.sema_result.call_instantiations.get(@intFromPtr(expr))) |instance_id| {
                    if (instance_id < ctx.sema_result.monomorph_instances.items.len) {
                        return ctx.sema_result.monomorph_instances.items[instance_id].return_type;
                    }
                }
                // 非泛型函数或未命中：查 sig.return_type_desc
                if (ctx.sema_result.getFuncSig(c.callee.identifier.name)) |sig| {
                    return sig.return_type_desc;
                }
            }
            return ctx.sema_result.getOrCreateRefDesc("call_result") catch unreachable;
        },
        .method_call, .safe_method_call => {
            // 查询 call_instantiations（processCallInBody 已为泛型方法调用创建实例）
            if (ctx.sema_result.call_instantiations.get(@intFromPtr(expr))) |instance_id| {
                if (instance_id < ctx.sema_result.monomorph_instances.items.len) {
                    return ctx.sema_result.monomorph_instances.items[instance_id].return_type;
                }
            }
            // 未命中：回退到 sema_result.expr_types
            if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
                return info.type_desc;
            }
            return ctx.sema_result.getOrCreateRefDesc("method_result") catch unreachable;
        },
        .block => |b| {
            // 返回 block 的 trailing_expr 类型（最后一个表达式）
            if (b.trailing_expr) |r| return resolveExprType(r, ctx);
            return &type_resolver.unit_type_descriptor;
        },
        else => {
            // 其他表达式：回退到 sema_result.expr_types
            if (ctx.sema_result.getExpr(@intFromPtr(expr))) |info| {
                return info.type_desc;
            }
            return null;
        },
    }
}

// ════════════════════════════════════════════════════════════════
// 编译期分析强制引用 + 冒烟测试
// ════════════════════════════════════════════════════════════════

/// 强制编译器分析所有内部函数（Zig 默认懒分析，未调用函数体不检查类型错误）
const _force_analysis = blk: {
    _ = collectMonomorphInstances;
    _ = findInstance;
    _ = hashTypeArgs;
    _ = buildCacheKey;
    _ = walkExpr;
    _ = walkStmt;
    _ = processCall;
    _ = processMethodCall;
    _ = inferTypeArgs;
    _ = getOrCreateInstance;
    _ = tdFromExprInfo;
    _ = tdFromTypeNode;
    _ = resolveInstanceBodyTypes;
    _ = resolveExpr;
    _ = resolveStmt;
    _ = resolvePattern;
    _ = resolveExprType;
    break :blk {};
};


