#![allow(dead_code)]

use crate::sema::Sema::*;
use crate::ast::Ast::{
    AstArena, Decl, Expr, ExprId, InterpolationPart, LambdaBody, Module,
    Param, Pattern, PatternRef, SelectArm, Spanned, Stmt, StmtId,
    TypeNode, TypeParam, TypeRef as AstTypeRef,
};
use crate::TypeDesc::{
    STR_DESC, TypeDescriptor,
    BOOL_DESC, CHAR_DESC, F64_DESC, I32_DESC, NULL_DESC, VOID_DESC,
};
use rustc_hash::FxHashMap;

// ====== 以下是从 Inference.rs（原 SemaInfer.rs）740-2408 行原样迁移的代码 ======
// =========================================================================
// monomorph — 单态化实例化
//
// v3 spec §5.2: 迁自 src/sema/monomorph.zig。
// 职责：识别所有泛型调用点 → 推导 type_args → 去重 → 确定实例集合。
//
// 适配 Rust：
// - 表达式 key 由裸指针 `@intFromPtr` 改为 `ExprId.0 as u64`（AstArena 索引）
// - 类型解析委托 `resolve_type_node_concrete`（接收 `Option<TypeId>` 而非 `*TypeNode`）
// - 借用分离：`WalkCtx` 不持有 `sema_result`，通过独立字段参数传递，避免
//   `&mut SemaResult` 与 `&mut WalkCtx` 循环借用；`instance` 作为栈上局部变量
//   在 `push` 前完成体解析，与 `sema_result` 无别名
// - `field_access` 元信息按 `TypeDefKind` 区分 Record（field_id 从 0）与
//   ADT/Newtype（field_id 从 1，`__tag=0`），修正 Zig 版 Record 索引偏移
// =========================================================================

/// FNV-1a 64-bit 哈希（迁自 monomorph.zig:hashTypeArgs）。
/// 输入为 `type_id` 列表（`TypeDescriptor.type_id`）。
pub fn hash_type_args(type_args: &[&'static TypeDescriptor]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for ta in type_args {
        h ^= ta.type_id as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 构造单态化缓存键。格式：`{func_name}#{hash}`（与 Zig 版一致）。
pub fn build_cache_key(func_name: &str, type_args: &[&'static TypeDescriptor]) -> String {
    let hash = hash_type_args(type_args);
    format!("{}#{:x}", func_name, hash)
}

/// 查找已有单态化实例（仅查询缓存，不创建）。
pub fn find_instance(
    sema_result: &SemaResult,
    func_name: &str,
    type_args: &[&'static TypeDescriptor],
) -> Option<u32> {
    let cache_key = build_cache_key(func_name, type_args);
    sema_result.monomorph_index.get(&cache_key).copied()
}

// ── AST 遍历上下文 ──

/// AST 遍历上下文：携带函数名 → 声明映射与循环检测表。
///
/// 刻意不持有 `sema_result`：所有需要 `&mut SemaResult` 的函数将其作为独立参数
/// 接收，使 `&mut ctx.in_progress` 与 `&mut sema_result` 可同时存活（split borrow）。
struct WalkCtx<'a> {
    ast: &'a AstArena<'a>,
    /// 函数名 → FunDecl 引用，用于推导 type_args 时查询参数类型注解与返回类型
    func_decls: FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    /// 循环检测：正在实例化的 cache_key → instance_id（前向引用支持）
    in_progress: FxHashMap<String, u32>,
    /// 当前模块名（用于 expr_types 复合 key）
    module_name: &'a str,
}

/// 由 `ExprInfo` 推导对应 `TypeDescriptor`（隐式 type_args 推断用）。
/// `ExprInfo.type_desc` 已是 `&'static TypeDescriptor`，直接返回。
fn td_from_expr_info(info: &ExprInfo) -> &'static TypeDescriptor {
    info.type_desc
}

/// 由 AST 类型节点推导 `TypeDescriptor`（显式 type_args 用）。
/// 使用 `resolve_type_node_concrete` 为用户类型创建具体描述符，无回退。
fn td_from_type_node<'a>(
    tn: AstTypeRef,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> &'static TypeDescriptor {
    resolve_type_node_concrete(Some(tn), &[], ast, sema_result)
        .unwrap_or_else(|| sema_result.get_or_create_ref_desc("unknown"))
}

/// 推导泛型调用的 type_args
///
/// 优先级：
/// 1. 显式类型实参（call expr 的 type_args 字段，如 `foo<i32>(x)`）
/// 2. 隐式推断：
///    a. `.named` 类型注解（如 `init: A`）→ 实参 `ExprInfo` 的 `TypeDescriptor`
///    b. `.function` 类型注解（如 `f: (A, T) -> A`）→ lambda 实参的参数类型注解
///    c. `.function` 返回类型注解 → lambda 实参的返回类型（注解或 body 推断）
///
/// 未匹配的类型参数用 `get_or_create_ref_desc` 创建具名描述符（type_name = 参数名）。
fn infer_type_args<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    sig: &FuncSigInfo,
    ctx: &WalkCtx<'a>,
    sema_result: &mut SemaResult,
) -> Vec<&'static TypeDescriptor> {
    // 1. 显式类型实参：直接解析每个 TypeNode
    if let Some(hints) = type_args_hint {
        if !hints.is_empty() {
            let mut args = Vec::with_capacity(hints.len());
            for &tn in hints {
                args.push(td_from_type_node(tn, ctx.ast, sema_result));
            }
            return args;
        }
    }

    // 2. 隐式推断
    let fd_decl = match ctx.func_decls.get(func_name).copied() {
        Some(d) => d,
        None => {
            // AST 不可达（可能是方法或内建函数）：为每个类型参数创建具名描述符
            return sig
                .type_params
                .iter()
                .map(|tp| sema_result.get_or_create_ref_desc(tp))
                .collect();
        }
    };
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let mut name_to_td: FxHashMap<&str, &'static TypeDescriptor> = FxHashMap::default();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: 匹配 .named 类型注解（如 `init: A` → 实参类型）
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let pname = match &ctx.ast.ty(param_type).node {
            TypeNode::Named { name } => *name,
            _ => continue,
        };
        if !is_type_param(pname) || name_to_td.contains_key(pname) {
            continue;
        }
        let arg_key = module_expr_key(ctx.module_name, arg.0 as u64);
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: 匹配 .function 类型注解（如 `f: (A, T) -> A`）against lambda 实参
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let fn_type = match &ctx.ast.ty(param_type).node {
            TypeNode::Function {
                params: fn_params,
                return_type: fn_ret,
            } => (fn_params.as_slice(), *fn_ret),
            _ => continue,
        };
        let lambda = match &ctx.ast.expr(*arg).node {
            Expr::Lambda {
                params: lambda_params,
                return_type: lambda_rt,
                body,
                ..
            } => (lambda_params.as_slice(), *lambda_rt, body),
            _ => continue,
        };

        // 匹配函数类型参数与 lambda 参数
        let (fn_params, fn_ret) = fn_type;
        let (lambda_params, lambda_rt, _lambda_body) = lambda;
        let match_count = fn_params.len().min(lambda_params.len());
        for j in 0..match_count {
            let fp_name = match &ctx.ast.ty(fn_params[j]).node {
                TypeNode::Named { name } => *name,
                _ => continue,
            };
            if !is_type_param(fp_name) || name_to_td.contains_key(fp_name) {
                continue;
            }
            if let Some(lt) = lambda_params[j].type_annotation {
                if let Some(td) = resolve_type_node_concrete(Some(lt), &[], ctx.ast, sema_result) {
                    name_to_td.insert(fp_name, td);
                }
            }
        }

        // 匹配函数返回类型注解 → lambda 返回类型
        let ret_name = match &ctx.ast.ty(fn_ret).node {
            TypeNode::Named { name } => Some(*name),
            _ => None,
        };
        if let Some(ret_name) = ret_name {
            if is_type_param(ret_name) && !name_to_td.contains_key(ret_name) {
                if let Some(lrt) = lambda_rt {
                    if let Some(td) =
                        resolve_type_node_concrete(Some(lrt), &[], ctx.ast, sema_result)
                    {
                        name_to_td.insert(ret_name, td);
                    }
                } else if let Some(td) = infer_lambda_return_type(lambda, ctx, sema_result) {
                    name_to_td.insert(ret_name, td);
                }
            }
        }
    }

    // Pass 3: .generic 类型注解（如 `l: Lst<T>`）— 目前无法从 ref 通道提取元素类型，
    // 仅记录未绑定的类型参数名，依赖 Pass 1/2 已绑定的类型参数（跳过未绑定）

    // 输出 type_args：type_name 设为类型参数名，使 resolveTypeNode 按名匹配
    let mut args = Vec::with_capacity(sig.type_params.len());
    for tp_name in sig.type_params.iter() {
        let mut td = if let Some(&t) = name_to_td.get(tp_name.as_ref()) {
            t
        } else {
            sema_result.get_or_create_ref_desc(tp_name)
        };
        // 复制描述符并覆盖 type_name 为类型参数名（按名匹配 type_args 绑定）。
        // 由于 TypeDescriptor 在 pool 中泄漏为 &'static，此处构造一个新的泄漏副本。
        td = leak_with_type_name(td, tp_name.as_ref());
        args.push(td);
    }
    args
}

/// 从 lambda body 推断返回类型。
/// 优先：显式返回类型注解 → body expression 的 ExprInfo → block trailing_expr 的 ExprInfo。
fn infer_lambda_return_type<'a>(
    lambda: (&'a [Param<'a>], Option<AstTypeRef>, &'a LambdaBody),
    ctx: &WalkCtx<'a>,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let (_, lambda_rt, body) = lambda;
    if let Some(rt) = lambda_rt {
        return resolve_type_node_concrete(Some(rt), &[], ctx.ast, sema_result);
    }
    match body {
        LambdaBody::Expression(body_expr) => {
            let key = module_expr_key(ctx.module_name, body_expr.0 as u64);
            sema_result
                .get_expr(key)
                .map(td_from_expr_info)
        }
        LambdaBody::Block(block_expr) => {
            if let Expr::Block { trailing: Some(trailing), .. } = &ctx.ast.expr(*block_expr).node {
                let key = module_expr_key(ctx.module_name, trailing.0 as u64);
                return sema_result
                    .get_expr(key)
                    .map(td_from_expr_info);
            }
            None
        }
    }
}

/// 构造一个 `type_name` 被覆盖的 `TypeDescriptor` 副本（泄漏为 `&'static`）。
///
/// 用于 `infer_type_args` 输出：type_name 设为类型参数名，使 `resolve_type_node_concrete`
/// 能按名匹配 `type_args` 绑定。其余字段（size/ops/type_id）继承源描述符。
fn leak_with_type_name(src: &'static TypeDescriptor, type_name: &str) -> &'static TypeDescriptor {
    let name_static: &'static str = Box::leak(type_name.to_string().into_boxed_str());
    Box::leak(Box::new(TypeDescriptor {
        size: src.size,
        ops: src.ops,
        type_id: src.type_id,
        type_name: name_static,
    }))
}

/// 查找或创建 `MonomorphInstance`
///
/// 1. 查 `monomorph_index` 缓存命中 → 返回 instance_id
/// 2. 未命中：创建栈上局部实例、注册 `in_progress`（前向引用支持）
/// 3. 用具体 type_args 解析函数体内所有表达式类型（可能触发前向引用）
/// 4. 解析完成后 `push` 到 `monomorph_instances`、写入缓存
fn get_or_create_instance<'a>(
    func_name: &str,
    type_args: &[&'static TypeDescriptor],
    fd_decl: &'a Spanned<Decl<'a>>,
    ast: &'a AstArena<'a>,
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
) -> u32 {
    let cache_key = build_cache_key(func_name, type_args);

    // 1. 查缓存
    if let Some(&idx) = sema_result.monomorph_index.get(&cache_key) {
        return idx;
    }

    // 2. 循环检测：前向引用支持
    if let Some(&existing_id) = in_progress.get(&cache_key) {
        return existing_id;
    }

    // 3. 新建栈上实例
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let instance_id = sema_result.monomorph_instances.len() as u32;
    let return_td = resolve_type_node_concrete(fd.return_type, type_args, ast, sema_result)
        .unwrap_or_else(|| sema_result.get_or_create_ref_desc("return"));

    let mut instance = MonomorphInstance {
        instance_id,
        func_name: func_name.into(),
        type_args: type_args.to_vec().into_boxed_slice(),
        chan_layout: ChanLayout::empty(),
        return_type: return_td,
        is_async: fd.is_async,
        expr_types: FxHashMap::default(),
        field_accesses: FxHashMap::default(),
    };

    // 4. 标记为正在实例化（前向引用支持）
    in_progress.insert(cache_key.clone(), instance_id);

    // 5. 递归解析函数体类型（instance 是栈上局部，与 sema_result 无别名）
    resolve_instance_body_types(
        &mut instance,
        &fd,
        ast,
        func_decls,
        in_progress,
        sema_result,
        type_args,
        module_name,
    );

    // 6. 写入实例表与缓存
    sema_result.monomorph_instances.push(instance);
    sema_result.monomorph_index.insert(cache_key, instance_id);
    instance_id
}

/// FunDecl 字段视图（从 `Decl::FunDecl` 提取，便于跨函数传递）。
struct FunDeclView<'a> {
    type_params: &'a [TypeParam<'a>],
    params: &'a [Param<'a>],
    return_type: Option<AstTypeRef>,
    body: ExprId,
    is_async: bool,
}

// ── AST 递归遍历：收集泛型调用点 ──

/// 处理直接调用表达式（callee 为标识符）。
///
/// 仅处理 callee 是 identifier 的直接函数调用。方法调用、闭包调用等由
/// `process_method_call` 处理或跳过（递归遍历仍会进入 recv/arguments）。
#[allow(clippy::too_many_arguments)]
fn process_call<'a>(
    callee: ExprId,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
) {
    // 仅处理直接标识符调用：foo(args) 或 foo<T>(args)
    let func_name = match &ast.expr(callee).node {
        Expr::Ident(name) => *name,
        _ => return,
    };
    // 查函数签名：跳过未注册函数与非泛型函数
    let sig_owned: Option<FuncSigInfo> = sema_result
        .get_func_sig(func_name).cloned();
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return,
    };

    // 查函数 AST（用于参数类型注解与返回类型）
    let fd_decl = match func_decls.get(func_name).copied() {
        Some(d) => d,
        None => return,
    };

    // 推导 type_args（显式或隐式）
    let ctx = WalkCtx {
        ast,
        func_decls: func_decls.clone(),
        in_progress: FxHashMap::default(),
        module_name: "",
    };
    let type_args = infer_type_args(func_name, arguments, type_args_hint, &sig, &ctx, sema_result);

    // 查找或创建实例
    let instance_id = get_or_create_instance(
        func_name,
        &type_args,
        fd_decl,
        ast,
        func_decls,
        in_progress,
        sema_result,
        module_name,
    );

    // 记录调用点 → 实例映射
    sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);
}

/// 处理方法调用表达式。
///
/// 方法调用通过 trait 分派，完整解析需要对象类型构造 mangled 名。此处采用最佳努力
/// 策略：直接以方法名查 `func_sig`，命中则处理；未命中则跳过。递归遍历仍会进入
/// recv/arguments，保证嵌套调用被收集。
#[allow(clippy::too_many_arguments)]
fn process_method_call<'a>(
    method: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
) {
    // 直接以方法名查 func_sig（覆盖同名顶层函数的罕见场景）
    let sig_owned: Option<FuncSigInfo> = sema_result.get_func_sig(method).cloned();
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return,
    };

    let fd_decl = match func_decls.get(method).copied() {
        Some(d) => d,
        None => return,
    };

    let ctx = WalkCtx {
        ast,
        func_decls: func_decls.clone(),
        in_progress: FxHashMap::default(),
        module_name,
    };
    let type_args = infer_type_args(method, arguments, type_args_hint, &sig, &ctx, sema_result);

    let instance_id = get_or_create_instance(
        method,
        &type_args,
        fd_decl,
        ast,
        func_decls,
        in_progress,
        sema_result,
        module_name,
    );
    sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);

    // v3 阶段 1：记录方法分派元信息（最佳努力匹配，完整 trait 解析留待后续阶段）
    sema_result.method_dispatches.insert(
        call_expr.0 as u64,
        DispatchInfo {
            trait_id: 0,
            method_idx: 0,
            impl_fn_idx: 0,
            instance_id,
        },
    );
}

/// 递归遍历 Stmt，收集所有嵌套的泛型调用点。
fn walk_stmt<'a>(
    stmt: StmtId,
    ctx: &mut WalkCtx<'a>,
    sema_result: &mut SemaResult,
) {
    let node = &ctx.ast.stmt(stmt).node;
    match node {
        Stmt::ValDecl { value, .. } => walk_expr(*value, ctx, sema_result),
        Stmt::VarDecl { value, .. } => walk_expr(*value, ctx, sema_result),
        Stmt::Assignment { target, value } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::FieldAssignment { object, value, .. } => {
            walk_expr(*object, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::CompoundAssignment { target, value, .. } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::Expression { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Return { value } => {
            if let Some(v) = value { walk_expr(*v, ctx, sema_result); }
        }
        Stmt::Defer { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Throw { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Break | Stmt::Continue => {}
        Stmt::For { iterable, body, .. } => {
            walk_expr(*iterable, ctx, sema_result);
            walk_expr(*body, ctx, sema_result);
        }
        Stmt::While { condition, body } => {
            walk_expr(*condition, ctx, sema_result);
            walk_expr(*body, ctx, sema_result);
        }
        Stmt::Loop { body } => walk_expr(*body, ctx, sema_result),
        Stmt::LocalDecl { decl } => match decl.as_ref() {
            crate::ast::Ast::Decl::FunDecl { body, .. } => walk_expr(*body, ctx, sema_result),
            crate::ast::Ast::Decl::TypeDecl { methods, .. }
            | crate::ast::Ast::Decl::TraitDecl { methods, .. } => {
                for m in methods.iter() {
                    if let Some(body) = m.body { walk_expr(body, ctx, sema_result); }
                }
            }
            _ => {}
        },
    }
}

/// 递归遍历 Expr，收集所有嵌套的泛型调用点。
///
/// 对 `call`/`method_call`/`safe_method_call` 三种调用表达式，提取调用元信息并
/// 推导 type_args。同时递归进入所有子表达式，确保嵌套调用被完整收集。
fn walk_expr<'a>(
    expr: ExprId,
    ctx: &mut WalkCtx<'a>,
    sema_result: &mut SemaResult,
) {
    // 先复制不可变引用字段，再用 &mut ctx.in_progress（split borrow）
    let ast = ctx.ast;
    let func_decls = &ctx.func_decls;
    let node = &ast.expr(expr).node;
    match node {
        // ── 调用表达式：核心收集目标 ──
        Expr::Call {
            callee,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_call(
                *callee,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
                ctx.module_name,
            );
            walk_expr(*callee, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }
        Expr::MethodCall {
            recv,
            method,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_method_call(
                method,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
                ctx.module_name,
            );
            walk_expr(*recv, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }
        Expr::SafeMethodCall {
            recv,
            method,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_method_call(
                method,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
                ctx.module_name,
            );
            walk_expr(*recv, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }

        // ── 一元/二元/赋值 ──
        Expr::Binary { op: _, lhs, rhs } => {
            walk_expr(*lhs, ctx, sema_result);
            walk_expr(*rhs, ctx, sema_result);
        }
        Expr::Unary { operand, .. } => walk_expr(*operand, ctx, sema_result),
        Expr::RefOf(operand) => walk_expr(*operand, ctx, sema_result),
        Expr::Deref(operand) => walk_expr(*operand, ctx, sema_result),
        Expr::Assign { target, value } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Expr::CompoundAssign { target, value, .. } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Expr::NonNullAssert(e) => walk_expr(*e, ctx, sema_result),
        Expr::Propagate(e) => walk_expr(*e, ctx, sema_result),
        Expr::Elvis { lhs, rhs } => {
            walk_expr(*lhs, ctx, sema_result);
            walk_expr(*rhs, ctx, sema_result);
        }

        // ── 字段访问与索引 ──
        Expr::FieldAccess { recv, .. } => walk_expr(*recv, ctx, sema_result),
        Expr::SafeAccess { recv, .. } => walk_expr(*recv, ctx, sema_result),
        Expr::Index { recv, index } => {
            walk_expr(*recv, ctx, sema_result);
            walk_expr(*index, ctx, sema_result);
        }
        Expr::Slice { recv, start, end, .. } => {
            walk_expr(*recv, ctx, sema_result);
            walk_expr(*start, ctx, sema_result);
            walk_expr(*end, ctx, sema_result);
        }

        // ── 容器字面量 ──
        Expr::ArrayLit { elements, fill } => {
            for &e in elements {
                walk_expr(e, ctx, sema_result);
            }
            if let Some((fv, fc)) = fill {
                walk_expr(*fv, ctx, sema_result);
                walk_expr(*fc, ctx, sema_result);
            }
        }
        Expr::RecordLit(fields) => {
            for f in fields {
                walk_expr(f.value, ctx, sema_result);
            }
        }
        Expr::RecordExtend { base, updates } => {
            walk_expr(*base, ctx, sema_result);
            for f in updates {
                walk_expr(f.value, ctx, sema_result);
            }
        }

        // ── 控制流 ──
        Expr::Lambda { body, .. } => match body {
            LambdaBody::Block(b) => walk_expr(*b, ctx, sema_result),
            LambdaBody::Expression(e) => walk_expr(*e, ctx, sema_result),
        },
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => {
            walk_expr(*cond, ctx, sema_result);
            walk_expr(*then_branch, ctx, sema_result);
            if let Some(eb) = else_branch {
                walk_expr(*eb, ctx, sema_result);
            }
        }
        Expr::Block { stmts, trailing } => {
            for &s in stmts {
                walk_stmt(s, ctx, sema_result);
            }
            if let Some(te) = trailing {
                walk_expr(*te, ctx, sema_result);
            }
        }
        Expr::Match { scrutinee, arms } => {
            walk_expr(*scrutinee, ctx, sema_result);
            for arm in arms {
                if let Some(g) = arm.guard {
                    walk_expr(g, ctx, sema_result);
                }
                walk_expr(arm.body, ctx, sema_result);
            }
        }

        // ── 并发/异步 ──
        Expr::Atomic(e) => walk_expr(*e, ctx, sema_result),
        Expr::Lazy(e) => walk_expr(*e, ctx, sema_result),
        Expr::Select(arms) => {
            for arm in arms {
                match arm {
                    SelectArm::Receive {
                        channel_expr, body, ..
                    } => {
                        walk_expr(*channel_expr, ctx, sema_result);
                        walk_expr(*body, ctx, sema_result);
                    }
                    SelectArm::Timeout { duration, body } => {
                        walk_expr(*duration, ctx, sema_result);
                        walk_expr(*body, ctx, sema_result);
                    }
                }
            }
        }

        // ── 字符串插值 ──
        Expr::StrInterp(parts) => {
            for part in parts {
                if let InterpolationPart::Expression(e) = part {
                    walk_expr(*e, ctx, sema_result);
                }
            }
        }

        // ── inline trait value：方法体可能含泛型调用 ──
        Expr::InlineTrait(methods) => {
            for method in methods {
                if let Some(body) = method.body {
                    walk_expr(body, ctx, sema_result);
                }
            }
        }

        // ── 终端节点：无需递归 ──
        Expr::IntLit { .. }
        | Expr::FloatLit { .. }
        | Expr::BoolLit(_)
        | Expr::CharLit(_)
        | Expr::StrLit(_)
        | Expr::NullLit
        | Expr::VoidLit
        | Expr::Ident(_) => {}
    }
}

// ── 主入口：collect_monomorph_instances ──

/// 收集模块中所有泛型调用点，产出单态化实例集合
///
/// v3 spec §5.2 `collectMonomorphInstances` 算法：
/// 1. 构建 `func_name → fun_decl` 映射，供推导 type_args 时查询参数类型注解
/// 2. 遍历所有顶层声明：
///    a. 非泛型 `fun_decl` → 创建空 type_args 实例
///    b. 所有 `fun_decl` 体 / `type_decl` 方法体 / `expr_decl` → 递归遍历
/// 3. 对每个泛型调用点：推导 type_args → 去重 → 创建实例 → 记录调用点映射
///
/// 泛型函数本身不创建空实例（其具体实例由调用点驱动生成）。
/// 方法调用的完整 trait 分派解析留待后续阶段，当前仅做最佳努力匹配。
pub fn collect_monomorph_instances<'a>(
    module: &'a Module<'a>,
    sema_result: &mut SemaResult,
) {
    // 注册内置标量 TypeDescriptor 到全局表
    register_builtin_type_descriptors(sema_result);
    // 注册内置类型方法签名（合成 TypeDefInfo），使方法查找走统一 (type_id, method_idx) 路径
    register_builtin_method_sigs(sema_result);

    let mut ctx = WalkCtx {
        ast: &module.arena,
        func_decls: FxHashMap::default(),
        in_progress: FxHashMap::default(),
        module_name: module.name,
    };

    // 1. 构建 func_name → &Spanned<Decl> 映射（仅顶层 fun_decl）
    for decl in &module.declarations {
        if let Decl::FunDecl { name, .. } = &decl.node {
            ctx.func_decls.insert(name, decl);
        }
    }

    // 2. 遍历所有顶层声明
    let declarations: Vec<&Spanned<Decl<'a>>> = module.declarations.iter().collect();
    for decl in declarations {
        match &decl.node {
            Decl::FunDecl {
                name,
                type_params,
                params,
                return_type,
                body,
                is_async,
                ..
            } => {
                // 非泛型函数：创建空 type_args 实例
                // （泛型函数不创建空实例，由调用点驱动）
                if type_params.is_empty() {
                    let empty_type_args: Vec<&'static TypeDescriptor> = Vec::new();
                    let return_td = resolve_type_node_concrete(
                        *return_type,
                        &empty_type_args,
                        &module.arena,
                        sema_result,
                    )
                    .unwrap_or_else(|| sema_result.get_or_create_ref_desc("return"));

                    let instance = MonomorphInstance {
                        instance_id: sema_result.monomorph_instances.len() as u32,
                        func_name: (*name).into(),
                        type_args: empty_type_args.into_boxed_slice(),
                        chan_layout: ChanLayout::empty(),
                        return_type: return_td,
                        is_async: *is_async,
                        expr_types: FxHashMap::default(),
                        field_accesses: FxHashMap::default(),
                    };
                    sema_result.monomorph_instances.push(instance);

                    // 非泛型函数：遍历函数体收集泛型调用点
                    // （泛型函数体的调用点在 resolveInstanceBodyTypes 中发现，
                    //  因为它们依赖当前实例的 type_args 上下文才能正确推断类型实参）
                    walk_expr(*body, &mut ctx, sema_result);
                }
                let _ = params; // params 未在非泛型分支使用
            }

            // 类型声明：遍历非泛型方法体（泛型方法体在实例化时发现）
            Decl::TypeDecl { methods, .. } => {
                // 收集需遍历的方法体，避免在借用 methods 时 &mut sema_result
                let bodies: Vec<ExprId> = methods
                    .iter()
                    .filter(|m| m.type_params.is_empty())
                    .filter_map(|m| m.body)
                    .collect();
                for body in bodies {
                    walk_expr(body, &mut ctx, sema_result);
                }
            }

            // 顶层表达式声明：遍历表达式
            Decl::ExprDecl { expr, stmt } => {
                walk_expr(*expr, &mut ctx, sema_result);
                if let Some(s) = stmt {
                    walk_stmt(*s, &mut ctx, sema_result);
                }
            }

            // import / pack：无需遍历
            _ => {}
        }
    }
}

// ── 实例体类型解析 ──

/// 实例体类型解析上下文
///
/// 持有 `&mut instance`（栈上局部，与 `sema_result` 无别名）和 `&mut sema_result`，
/// 通过 split borrowing 允许 `resolve_expr` 中 `&mut ctx.sema_result`（写调用点映射）
/// 与 `&mut ctx.instance`（写表达式类型表）交替进行。
struct ResolveCtx<'a, 'b> {
    instance: &'b mut MonomorphInstance,
    sema_result: &'a mut SemaResult,
    ast: &'a AstArena<'a>,
    type_args: &'a [&'static TypeDescriptor],
    /// 变量名 → 类型描述符（局部变量绑定，作用域栈）
    bindings: Vec<FxHashMap<&'a str, &'static TypeDescriptor>>,
    /// 类型参数名 → type_args 索引（快速查找）
    type_param_map: FxHashMap<&'a str, u16>,
    func_decls: &'a FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &'a mut FxHashMap<String, u32>,
    /// 当前模块名（用于 expr_types 复合 key）
    module_name: &'a str,
}

impl<'a, 'b> ResolveCtx<'a, 'b> {
    fn push_scope(&mut self) {
        self.bindings.push(FxHashMap::default());
    }

    fn pop_scope(&mut self) {
        if self.bindings.len() > 1 {
            self.bindings.pop();
        }
    }

    fn define_var(&mut self, name: &'a str, td: &'static TypeDescriptor) {
        if let Some(scope) = self.bindings.last_mut() {
            scope.insert(name, td);
        }
    }

    fn lookup_var(&self, name: &str) -> Option<&'static TypeDescriptor> {
        for scope in self.bindings.iter().rev() {
            if let Some(&td) = scope.get(name) {
                return Some(td);
            }
        }
        None
    }
}

/// 用具体 type_args 解析函数体内所有表达式类型
///
/// 递归遍历函数体 AST，对每个表达式计算其类型并存入 `instance.expr_types`。
/// 对 `field_access` 表达式额外存入 `instance.field_accesses`。
/// 替代 IRBuilder 的 `infer*` 系列函数。
fn resolve_instance_body_types<'a>(
    instance: &mut MonomorphInstance,
    fd: &FunDeclView<'a>,
    ast: &'a AstArena<'a>,
    func_decls: &'a FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    type_args: &[&'static TypeDescriptor],
    module_name: &'a str,
) {
    let mut type_param_map: FxHashMap<&'a str, u16> = FxHashMap::default();
    for (i, tp) in fd.type_params.iter().enumerate() {
        type_param_map.insert(tp.name, i as u16);
    }

    let bindings: Vec<FxHashMap<&'a str, &'static TypeDescriptor>> = vec![FxHashMap::default()];

    let mut rctx = ResolveCtx {
        instance,
        sema_result,
        ast,
        type_args,
        bindings,
        type_param_map,
        func_decls,
        in_progress,
        module_name,
    };

    // 注册函数参数到变量绑定
    for param in fd.params {
        let td = if let Some(ta) = param.type_annotation {
            resolve_type_node_concrete(Some(ta), type_args, ast, rctx.sema_result)
                .unwrap_or_else(|| rctx.sema_result.get_or_create_ref_desc("param"))
        } else {
            rctx.sema_result.get_or_create_ref_desc("param")
        };
        rctx.define_var(param.name, td);
    }

    // 遍历函数体
    resolve_expr(fd.body, &mut rctx);
}

/// 在函数体内发现泛型调用点时，用当前实例的 type_args 上下文推断 type_args 并创建实例
///
/// 与顶层 `process_call` 的区别：
/// - 顶层 `process_call` 依赖 `sema_result.expr_types`（HM 推断产出），无法解析类型参数 T
/// - 此函数用 `resolve_expr_type` 递归解析实参类型，能利用当前实例的 type_args 将 T 解析为具体类型
fn process_call_in_body<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ctx: &mut ResolveCtx<'a, '_>,
) {
    let sig_owned: Option<FuncSigInfo> = ctx
        .sema_result
        .get_func_sig(func_name).cloned();
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return, // 非泛型函数，无需单态化
    };

    let fd_decl = match ctx.func_decls.get(func_name).copied() {
        Some(d) => d,
        None => return,
    };

    // 读取当前实例函数名（&ctx.instance）与 type_args，与 &mut ctx.sema_result split borrow
    let cur_func_name: &str = ctx.instance.func_name.as_ref();
    let type_args = infer_type_args_in_body(
        func_name,
        arguments,
        type_args_hint,
        &sig,
        fd_decl,
        ctx.ast,
        ctx.type_args,
        cur_func_name,
        ctx.sema_result,
        ctx.module_name,
    );

    // 查找或创建实例
    let existing_id = find_instance(ctx.sema_result, func_name, &type_args);
    if let Some(id) = existing_id {
        ctx.sema_result
            .call_instantiations
            .insert(call_expr.0 as u64, id);
        return;
    }

    let instance_id = get_or_create_instance(
        func_name,
        &type_args,
        fd_decl,
        ctx.ast,
        ctx.func_decls,
        ctx.in_progress,
        ctx.sema_result,
        ctx.module_name,
    );
    ctx.sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);
}

/// 在实例体上下文中推断 type_args
///
/// 与顶层 `infer_type_args` 的区别：
/// - 显式类型实参：用当前实例的 type_args 解析类型参数 T（而非空 type_args）
/// - 隐式推断：用 `resolve_expr_type` 递归解析实参类型（而非 `sema_result.expr_types`）
/// - 直接递归：递归调用自身时，type_args 与当前实例一致
#[allow(clippy::too_many_arguments)]
fn infer_type_args_in_body<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    sig: &FuncSigInfo,
    fd_decl: &'a Spanned<Decl<'a>>,
    ast: &'a AstArena<'a>,
    cur_type_args: &[&'static TypeDescriptor],
    cur_func_name: &str,
    sema_result: &mut SemaResult,
    module_name: &str,
) -> Vec<&'static TypeDescriptor> {
    // 1. 显式类型实参：用当前实例的 type_args 解析（支持 foo<T>(x) 中 T 为外层类型参数）
    if let Some(hints) = type_args_hint {
        if !hints.is_empty() {
            let mut args = Vec::with_capacity(hints.len());
            for &tn in hints {
                let td = resolve_type_node_concrete(Some(tn), cur_type_args, ast, sema_result)
                    .unwrap_or_else(|| sema_result.get_or_create_ref_desc("type_arg"));
                args.push(td);
            }
            return args;
        }
    }

    // 2. 直接递归：递归调用自身时，type_args 与当前实例一致
    //    （如 foldl<T,A> 体内的 foldl(t, f(init,x), f) 使用相同 T,A）
    //    这避免了从 .generic 类型参数（Lst<T>）和非 lambda 实参无法推断 T 的问题
    if func_name == cur_func_name {
        return cur_type_args.to_vec();
    }

    // 3. 隐式推断
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let mut name_to_td: FxHashMap<&str, &'static TypeDescriptor> = FxHashMap::default();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: .named 类型注解
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let pname = match &ast.ty(param_type).node {
            TypeNode::Named { name } => *name,
            _ => continue,
        };
        if !is_type_param(pname) || name_to_td.contains_key(pname) {
            continue;
        }
        // 用一个临时 ResolveCtx 调用 resolve_expr_type —— 但此处无 instance，
        // 改用 sema_result.expr_types 回退（与 Zig 行为一致：Pass 1 用 ExprInfo）
        let arg_key = module_expr_key(module_name, arg.0 as u64);
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: .function 类型注解 → lambda 实参的参数类型注解
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let (fn_params, fn_ret) = match &ast.ty(param_type).node {
            TypeNode::Function {
                params: p,
                return_type: r,
            } => (p.as_slice(), *r),
            _ => continue,
        };
        let (lambda_params, lambda_rt) = match &ast.expr(*arg).node {
            Expr::Lambda {
                params: lp,
                return_type: lrt,
                ..
            } => (lp.as_slice(), *lrt),
            _ => continue,
        };

        let match_count = fn_params.len().min(lambda_params.len());
        for j in 0..match_count {
            let fp_name = match &ast.ty(fn_params[j]).node {
                TypeNode::Named { name } => *name,
                _ => continue,
            };
            if !is_type_param(fp_name) || name_to_td.contains_key(fp_name) {
                continue;
            }
            if let Some(lt) = lambda_params[j].type_annotation {
                if let Some(td) = resolve_type_node_concrete(Some(lt), cur_type_args, ast, sema_result)
                {
                    name_to_td.insert(fp_name, td);
                }
            }
        }

        // 返回类型注解 → lambda 返回类型
        let ret_name = match &ast.ty(fn_ret).node {
            TypeNode::Named { name } => Some(*name),
            _ => None,
        };
        if let Some(ret_name) = ret_name {
            if is_type_param(ret_name) && !name_to_td.contains_key(ret_name) {
                if let Some(lrt) = lambda_rt {
                    if let Some(td) =
                        resolve_type_node_concrete(Some(lrt), cur_type_args, ast, sema_result)
                    {
                        name_to_td.insert(ret_name, td);
                    }
                }
            }
        }
    }

    // 按 sig.type_params 顺序输出 TypeDescriptor
    let mut args = Vec::with_capacity(sig.type_params.len());
    for tp_name in sig.type_params.iter() {
        let td = if let Some(&t) = name_to_td.get(tp_name.as_ref()) {
            t
        } else {
            sema_result.get_or_create_ref_desc(tp_name)
        };
        args.push(leak_with_type_name(td, tp_name.as_ref()));
    }
    args
}

/// 解析表达式类型并存入实例表
fn resolve_expr<'a, 'b>(expr: ExprId, ctx: &mut ResolveCtx<'a, 'b>) {
    // 对调用表达式：先发现并创建被调用函数的实例（填充 call_instantiations），
    // 再计算返回类型（resolve_expr_type 的 .call 分支会查询 call_instantiations）
    {
        let ast = ctx.ast;
        let node = &ast.expr(expr).node;
        match node {
            Expr::Call {
                callee,
                args,
                type_args,
            } => {
                if let Expr::Ident(_) = &ast.expr(*callee).node {
                    let hint = type_args.as_deref();
                    process_call_in_body(
                        callee_name(ast, *callee),
                        args.as_slice(),
                        hint,
                        expr,
                        ctx,
                    );
                }
            }
            Expr::MethodCall {
                recv: _,
                method,
                args,
                type_args,
            } => {
                let hint = type_args.as_deref();
                process_call_in_body(method, args.as_slice(), hint, expr, ctx);
            }
            Expr::SafeMethodCall {
                recv: _,
                method,
                args,
                type_args,
            } => {
                let hint = type_args.as_deref();
                process_call_in_body(method, args.as_slice(), hint, expr, ctx);
            }
            _ => {}
        }
    }

    let td = resolve_expr_type(expr, ctx)
        .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));

    let expr_key = expr.0 as u64;
    let mut info = ExprInfo::new(td, expr_key);
    info.type_name = Some(td.type_name.into());
    info.is_ref_type = td.is_ref();
    ctx.instance.expr_types.insert(expr_key, info);

    // 同步填充 sema_result.resolved_type_descs（全局表达式→TypeDescriptor 映射）
    ctx.sema_result.resolved_type_descs.insert(expr_key, td);

    // 递归处理子表达式 + field_access 元信息
    let ast = ctx.ast;
    let node = &ast.expr(expr).node;
    match node {
        Expr::FieldAccess { recv, field } => {
            // 额外存入 field_accesses 元信息
            let obj_td = resolve_expr_type(*recv, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            if let Some((field_id, field_td)) =
                ctx.sema_result.resolve_field_td(obj_td.type_name, field)
            {
                ctx.instance.field_accesses.insert(
                    expr_key,
                    FieldAccessInfo {
                        obj_type_desc: obj_td,
                        field_idx: field_id,
                        field_type_desc: field_td,
                    },
                );
            }
            resolve_expr(*recv, ctx);
        }
        Expr::Call {
            callee, args, ..
        } => {
            resolve_expr(*callee, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::MethodCall {
            recv, args, ..
        } => {
            resolve_expr(*recv, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::SafeMethodCall {
            recv, args, ..
        } => {
            resolve_expr(*recv, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::Binary { op: _, lhs, rhs } => {
            resolve_expr(*lhs, ctx);
            resolve_expr(*rhs, ctx);
        }
        Expr::Unary { operand, .. } => resolve_expr(*operand, ctx),
        Expr::RefOf(operand) => resolve_expr(*operand, ctx),
        Expr::Deref(operand) => resolve_expr(*operand, ctx),
        Expr::Assign { target, value } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Expr::CompoundAssign { target, value, .. } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Expr::NonNullAssert(e) => resolve_expr(*e, ctx),
        Expr::Propagate(e) => resolve_expr(*e, ctx),
        Expr::SafeAccess { recv, .. } => resolve_expr(*recv, ctx),
        Expr::Index { recv, index } => {
            resolve_expr(*recv, ctx);
            resolve_expr(*index, ctx);
        }
        Expr::Slice {
            recv, start, end, ..
        } => {
            resolve_expr(*recv, ctx);
            resolve_expr(*start, ctx);
            resolve_expr(*end, ctx);
        }
        Expr::ArrayLit { elements, fill } => {
            for &e in elements {
                resolve_expr(e, ctx);
            }
            if let Some((fv, fc)) = fill {
                resolve_expr(*fv, ctx);
                resolve_expr(*fc, ctx);
            }
        }
        Expr::RecordLit(fields) => {
            for f in fields {
                resolve_expr(f.value, ctx);
            }
        }
        Expr::RecordExtend { base, updates } => {
            resolve_expr(*base, ctx);
            for f in updates {
                resolve_expr(f.value, ctx);
            }
        }
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => {
            resolve_expr(*cond, ctx);
            resolve_expr(*then_branch, ctx);
            if let Some(eb) = else_branch {
                resolve_expr(*eb, ctx);
            }
        }
        Expr::Match { scrutinee, arms } => {
            resolve_expr(*scrutinee, ctx);
            for arm in arms {
                ctx.push_scope();
                resolve_pattern(arm.pattern, ctx);
                if let Some(g) = arm.guard {
                    resolve_expr(g, ctx);
                }
                resolve_expr(arm.body, ctx);
                ctx.pop_scope();
            }
        }
        Expr::Block { stmts, trailing } => {
            ctx.push_scope();
            let stmts: Vec<StmtId> = stmts.to_vec();
            for s in stmts {
                resolve_stmt(s, ctx);
            }
            if let Some(te) = trailing {
                resolve_expr(*te, ctx);
            }
            ctx.pop_scope();
        }
        Expr::Lambda { body, .. } => match body {
            LambdaBody::Block(b) => resolve_expr(*b, ctx),
            LambdaBody::Expression(e) => resolve_expr(*e, ctx),
        },
        _ => {}
    }
}

/// 解析语句（递归处理声明和控制流）
fn resolve_stmt<'a, 'b>(stmt: StmtId, ctx: &mut ResolveCtx<'a, 'b>) {
    let ast = ctx.ast;
    let node = &ast.stmt(stmt).node;
    match node {
        Stmt::ValDecl { name, value, .. } => {
            let td = resolve_expr_type(*value, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            resolve_expr(*value, ctx);
            ctx.define_var(name, td);
        }
        Stmt::VarDecl { name, value, .. } => {
            let td = resolve_expr_type(*value, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            resolve_expr(*value, ctx);
            ctx.define_var(name, td);
        }
        Stmt::Assignment { target, value } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::FieldAssignment { object, value, .. } => {
            resolve_expr(*object, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::CompoundAssignment { target, value, .. } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::Expression { expr } => resolve_expr(*expr, ctx),
        Stmt::Return { value } => {
            if let Some(v) = value {
                resolve_expr(*v, ctx);
            }
        }
        Stmt::Defer { expr } => resolve_expr(*expr, ctx),
        Stmt::Throw { expr } => resolve_expr(*expr, ctx),
        Stmt::Break | Stmt::Continue => {}
        Stmt::For {
            name,
            iterable,
            body,
        } => {
            let span = ast.stmt(stmt).span;
            resolve_expr(*iterable, ctx);
            ctx.push_scope();
            let iter_td = resolve_expr_type(*iterable, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            // 检查 iterable 类型 implement Iterator
            // 已知迭代器类型：Iterator(trait 值)/ArrayIter/RangeIterator/StringIterator
            // 已知非迭代器类型：array/str/基元类型 → 报错提示用 .iter()
            // 其他类型（用户自定义）放行（witness_table 在 InferContext 中，此路径不可访问）
            let iter_type_name = iter_td.type_name;
            const NON_ITERATOR_TYPES: &[&str] = &[
                "array", "str", "i32", "i64", "f32", "f64", "bool",
                "u8", "u16", "u32", "u64", "f128", "void", "null",
            ];
            if NON_ITERATOR_TYPES.contains(&iter_type_name) {
                ctx.sema_result.add_error(SemaError::new(
                    &format!(
                        "类型 '{}' 未实现 Iterator，For 循环要求迭代器类型。数组请用 arr.iter()，字符串请用 str_iter(s)",
                        iter_type_name
                    ),
                    span.line,
                    span.column,
                ));
            }
            ctx.define_var(name, iter_td);
            resolve_expr(*body, ctx);
            ctx.pop_scope();
        }
        Stmt::While { condition, body } => {
            resolve_expr(*condition, ctx);
            resolve_expr(*body, ctx);
        }
        Stmt::Loop { body } => resolve_expr(*body, ctx),
        Stmt::LocalDecl { decl } => match decl.as_ref() {
            crate::ast::Ast::Decl::FunDecl { body, .. } => {
                resolve_expr(*body, ctx);
            }
            crate::ast::Ast::Decl::TypeDecl { methods, .. }
            | crate::ast::Ast::Decl::TraitDecl { methods, .. } => {
                for m in methods.iter() {
                    if let Some(body) = m.body {
                        resolve_expr(body, ctx);
                    }
                }
            }
            _ => {}
        },
    }
}

/// 解析 match pattern 中的变量绑定
fn resolve_pattern<'a, 'b>(pattern: PatternRef, ctx: &mut ResolveCtx<'a, 'b>) {
    let ast = ctx.ast;
    let node = &ast.pattern(pattern).node;
    match node {
        Pattern::Variable { name } => {
            // 无参 ADT 构造器不应注册为变量绑定
            if !ctx.sema_result.ctor_def_index.contains_key(*name) {
                let td = ctx.sema_result.get_or_create_ref_desc("pattern_var");
                ctx.define_var(name, td);
            }
        }
        Pattern::Constructor { patterns, .. } => {
            let patterns: Vec<PatternRef> = patterns.to_vec();
            for fp in patterns {
                resolve_pattern(fp, ctx);
            }
        }
        Pattern::Record { fields } => {
            let field_patterns: Vec<PatternRef> =
                fields.iter().map(|f| f.pattern).collect();
            for fp in field_patterns {
                resolve_pattern(fp, ctx);
            }
        }
        Pattern::OrPattern { left, right } => {
            resolve_pattern(*left, ctx);
            resolve_pattern(*right, ctx);
        }
        Pattern::Guard { pattern, .. } => resolve_pattern(*pattern, ctx),
        _ => {}
    }
}

/// 解析表达式的类型（不存入表，仅返回类型描述符）
///
/// 核心类型推断逻辑：
/// 1. 字面量：直接映射（int_literal → i32, string_literal → str 等）
/// 2. identifier：查变量绑定 → 类型参数绑定 → sema_result.expr_types
/// 3. field_access：查对象类型的字段类型
/// 4. call/method_call：查函数签名返回类型或 call_instantiations 实例返回类型
/// 5. 其他：回退到 sema_result.expr_types
fn resolve_expr_type<'a, 'b>(
    expr: ExprId,
    ctx: &mut ResolveCtx<'a, 'b>,
) -> Option<&'static TypeDescriptor> {
    let ast = ctx.ast;
    let node = &ast.expr(expr).node;
    match node {
        Expr::IntLit { suffix, .. } => Some(
            suffix
                .as_deref()
                .and_then(type_descriptor_from_builtin_name)
                .unwrap_or(&I32_DESC),
        ),
        Expr::FloatLit { suffix, .. } => Some(
            suffix
                .as_deref()
                .and_then(type_descriptor_from_builtin_name)
                .unwrap_or(&F64_DESC),
        ),
        Expr::BoolLit(_) => Some(&BOOL_DESC),
        Expr::CharLit(_) => Some(&CHAR_DESC),
        Expr::StrLit(_) | Expr::StrInterp(_) => Some(&STR_DESC),
        Expr::NullLit => Some(&NULL_DESC),
        Expr::VoidLit => Some(&VOID_DESC),
        Expr::Ident(name) => {
            // 1. 查类型参数绑定
            if let Some(&idx) = ctx.type_param_map.get(name) {
                if (idx as usize) < ctx.type_args.len() {
                    return Some(ctx.type_args[idx as usize]);
                }
            }
            // 2. 查局部变量绑定
            if let Some(td) = ctx.lookup_var(name) {
                return Some(td);
            }
            // 3. 查 sema_result.expr_types
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            ctx.sema_result
                .get_expr(key)
                .map(td_from_expr_info)
        }
        Expr::FieldAccess { recv, field } => {
            // 递归解析对象类型，再查字段类型
            let obj_td = resolve_expr_type(*recv, ctx)?;
            if let Some((_, field_td)) = ctx.sema_result.resolve_field_td(obj_td.type_name, field) {
                return Some(field_td);
            }
            Some(ctx.sema_result.get_or_create_ref_desc(obj_td.type_name))
        }
        Expr::Call {
            callee, type_args, ..
        } => {
            if let Expr::Ident(callee_name_str) = &ast.expr(*callee).node {
                // 构造器调用：返回以类型名命名的具体描述符
                // 复制 ret_name 为 owned String，释放 ctor 的不可变借用后再 &mut
                let ctor_ret_name: Option<String> = ctx
                    .sema_result
                    .get_ctor_def(callee_name_str)
                    .map(|ctor| {
                        ctor.return_type_name
                            .as_deref()
                            .unwrap_or(ctor.type_name.as_ref())
                            .to_string()
                    });
                if let Some(ret_name) = ctor_ret_name {
                    return Some(ctx.sema_result.get_or_create_ref_desc(&ret_name));
                }
                // 优先查询 call_instantiations：泛型调用点已由 process_call_in_body 创建实例
                if let Some(&instance_id) = ctx.sema_result.call_instantiations.get(&(expr.0 as u64))
                {
                    if let Some(inst) = ctx
                        .sema_result
                        .monomorph_instances
                        .get(instance_id as usize)
                    {
                        return Some(inst.return_type);
                    }
                }
                // 非泛型函数或未命中：查 sig.return_type_desc
                if let Some(sig) = ctx.sema_result.get_func_sig(callee_name_str) {
                    return Some(sig.return_type_desc);
                }
            }
            let _ = type_args;
            Some(ctx.sema_result.get_or_create_ref_desc("call_result"))
        }
        Expr::MethodCall { .. } | Expr::SafeMethodCall { .. } => {
            // 查询 call_instantiations（process_call_in_body 已为泛型方法调用创建实例）
            if let Some(&instance_id) = ctx.sema_result.call_instantiations.get(&(expr.0 as u64)) {
                if let Some(inst) = ctx
                    .sema_result
                    .monomorph_instances
                    .get(instance_id as usize)
                {
                    return Some(inst.return_type);
                }
            }
            // 未命中：回退到 sema_result.expr_types，再回退到具名描述符
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            match ctx
                .sema_result
                .get_expr(key)
                .map(td_from_expr_info)
            {
                Some(td) => Some(td),
                None => Some(ctx.sema_result.get_or_create_ref_desc("method_result")),
            }
        }
        Expr::Block { trailing, .. } => {
            if let Some(te) = trailing {
                resolve_expr_type(*te, ctx)
            } else {
                Some(&VOID_DESC)
            }
        }
        _ => {
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            ctx
                .sema_result
                .get_expr(key)
                .map(td_from_expr_info)
        }
    }
}

/// 提取 callee 为 Ident 时的函数名（供 `process_call_in_body` 使用）。
fn callee_name<'a>(ast: &AstArena<'a>, callee: ExprId) -> &'a str {
    match &ast.expr(callee).node {
        Expr::Ident(name) => name,
        _ => "",
    }
}

// ====== 以下是新增的 trait 默认方法单态化逻辑 ======

/// 判断类型是否在 AST 层显式实现了某方法（有 body）。
///
/// 用于跳过 trait 默认方法特化：类型已显式覆写该方法时不需要生成特化子图。
/// 与 Ir.rs 步骤 0 注册 method_subgraphs 的条件一致（method.body.is_some()）。
fn type_has_explicit_method<'a>(module: &'a Module<'a>, type_name: &str, method_name: &str) -> bool {
    for decl in &module.declarations {
        if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &decl.node {
            if *name == type_name {
                return methods.iter().any(|m| &*m.name == method_name && m.body.is_some());
            }
        }
    }
    false
}

/// 收集 trait 默认方法单态化实例。
///
/// 为每个实现 trait 但未显式覆写该方法的类型生成一个 TraitDefaultInstance 条目。
/// IR 层（IrBuilder）消费此表预注册并编译特化子图。
///
/// 算法：
/// 1. 遍历模块中的 TraitDecl，获取 trait_idx
/// 2. 从 witness_table 收集所有实现该 trait 的类型 (type_id, type_name)
/// 3. 对每个有 body 的默认方法，为每个实现类型生成特化实例
/// 4. 跳过类型已显式覆写该方法的情况（AST 层判断 type_has_explicit_method）
pub fn collect_trait_default_instances<'a>(
    module: &'a Module<'a>,
    sema_result: &mut SemaResult,
) {
    for decl in &module.declarations {
        if let crate::ast::Ast::Decl::TraitDecl { name, methods, .. } = &decl.node {
            let trait_idx = match sema_result.trait_def_index.get(*name).copied() {
                Some(idx) => idx,
                None => continue,
            };
            // 收集所有实现该 trait 的类型（从 witness_table）
            let impl_entries: Vec<(u16, String)> = sema_result
                .witness_table
                .entries()
                .iter()
                .filter(|e| e.trait_name.as_ref() == *name)
                .filter_map(|e| {
                    // type_id → type_name（反查 type_defs）
                    sema_result.type_defs.iter().enumerate()
                        .find(|(i, _)| crate::TypeDesc::dynamic_type_id(*i as u16) == e.type_id)
                        .map(|(_, td)| (e.type_id, td.name.to_string()))
                })
                .collect();

            for (method_idx, method) in methods.iter().enumerate() {
                if method.body.is_none() {
                    continue;
                }
                let method_name: &str = method.name.as_ref();
                for (type_id, type_name) in &impl_entries {
                    // 跳过类型已显式覆写该方法的情况
                    if type_has_explicit_method(module, type_name, method_name) {
                        continue;
                    }
                    sema_result.trait_default_instances.push(TraitDefaultInstance {
                        type_id: *type_id,
                        type_name: type_name.as_str().into(),
                        trait_idx,
                        trait_name: (*name).into(),
                        method_idx: method_idx as u16,
                    });
                }
            }
        }
    }
}

/// Sema 后单态化统一入口。
///
/// 在 Sema 阶段完成后调用，执行两类单态化实例收集：
/// 1. `collect_monomorph_instances`：泛型函数调用点驱动的单态化
/// 2. `collect_trait_default_instances`：trait 默认方法按实现类型特化
///
/// IR 层（IrBuilder）消费 SemaResult 中的 monomorph_instances 和 trait_default_instances
/// 生成对应的特化子图。
pub fn run_monomorphization<'a>(
    module: &'a Module<'a>,
    sema_result: &mut SemaResult,
) {
    collect_monomorph_instances(module, sema_result);
    collect_trait_default_instances(module, sema_result);
}
