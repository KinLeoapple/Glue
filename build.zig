//! Glue 语言构建脚本
//!
//! 定义可执行目标 `glue` 以及各子模块之间的依赖关系。

const std = @import("std");

/// 构建入口：配置目标、优化级别、模块依赖与可执行产物
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 前端核心模块：AST、词法分析器、语法分析器 ----
    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/parse/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/parse/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/parse/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);

    // ---- 性能分析模块 ----
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ---- 调试分配器模块（独立于 mem 入口，被 root/debug 命令使用） ----
    const debug_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/mem/debug_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- 内存管理模块入口 ----
    const mem_module = b.createModule(.{
        .root_source_file = b.path("src/mem/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    // mem → profiling 单向依赖：thread_ctx.zig 使用 ThreadProfiler/GlobalProfiler
    // profiling 不依赖 mem/value（stats.zig 用 u8 索引而非 RefKind，打破循环）
    mem_module.addImport("profiling", profiler_module);

    // ---- 值系统模块 ----
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("ast", ast_module);
    value_module.addImport("mem", mem_module);
    // profiling 需要 value 模块中的 obj_header（RefKind / ref_kind_count）
    profiler_module.addImport("value", value_module);

    // ---- 语义分析模块族：分析数据库与各类检查器 ----
    // v3 阶段 11：ast_visitor 从 static_analysis/ 提升至 sema/，作为独立模块供 analysis_db 消费
    const ast_visitor_module = b.createModule(.{
        .root_source_file = b.path("src/sema/ast_visitor.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_visitor_module.addImport("ast", ast_module);

    const analysis_db_module = b.createModule(.{
        .root_source_file = b.path("src/sema/static_analysis/analysis_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    analysis_db_module.addImport("ast", ast_module);
    analysis_db_module.addImport("ast_visitor", ast_visitor_module);

    // ---- Builtin 元信息模块：集中管理 builtin 类型字段布局（sema 与 ir 共用） ----
    // 注意：import 名取 "glue_builtin" 避免与 Zig 标准内建模块 "builtin" 冲突
    const builtin_module = b.createModule(.{
        .root_source_file = b.path("src/builtin.zig"),
        .target = target,
        .optimize = optimize,
    });
    const type_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/type_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_check_module.addImport("ast", ast_module);
    type_check_module.addImport("glue_builtin", builtin_module);
    const subtype_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/subtype_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    subtype_check_module.addImport("ast", ast_module);
    const throw_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/throw_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    throw_check_module.addImport("ast", ast_module);
    const trait_resolve_module = b.createModule(.{
        .root_source_file = b.path("src/sema/trait_resolve.zig"),
        .target = target,
        .optimize = optimize,
    });
    trait_resolve_module.addImport("ast", ast_module);
    const kind_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/kind_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    kind_check_module.addImport("ast", ast_module);
    const gadt_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/gadt_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gadt_check_module.addImport("ast", ast_module);
    const module_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/module_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_check_module.addImport("ast", ast_module);

    // ---- Stdlib 嵌入模块：@embedFile 把 std/ 下的 .glue 文件编进二进制 ----
    // 供 module_loader 的 loadDecls 解析 import std.* 时查找
    const std_embed_module = b.createModule(.{
        .root_source_file = b.path("src/std/embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- 模块加载器：串联前端与语义分析 ----
    const module_loader_module = b.createModule(.{
        .root_source_file = b.path("src/parse/module_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_loader_module.addImport("ast", ast_module);
    module_loader_module.addImport("lexer", lexer_module);
    module_loader_module.addImport("parser", parser_module);
    module_loader_module.addImport("sema", type_check_module);
    module_loader_module.addImport("analysis_db", analysis_db_module);
    module_loader_module.addImport("std_embed", std_embed_module);
    // v3 阶段 16：ast_rewrite 复用 sema/ast_visitor 的 walkExprChildrenMut
    module_loader_module.addImport("ast_visitor", ast_visitor_module);

    // ---- 语义分析模块间的交叉依赖：子检查器引用主类型检查器 ----
    type_check_module.addImport("subtype_check", subtype_check_module);
    type_check_module.addImport("throw_check", throw_check_module);
    type_check_module.addImport("trait_resolve", trait_resolve_module);
    type_check_module.addImport("kind_check", kind_check_module);
    type_check_module.addImport("gadt_check", gadt_check_module);
    type_check_module.addImport("module_check", module_check_module);
    subtype_check_module.addImport("type_check", type_check_module);
    throw_check_module.addImport("type_check", type_check_module);
    trait_resolve_module.addImport("type_check", type_check_module);
    kind_check_module.addImport("type_check", type_check_module);
    gadt_check_module.addImport("type_check", type_check_module);

    // ---- Syscall 原语模块（IO/Time 等宿主 syscall 包装）----
    // 不依赖 ir（SyscallId/REGISTRY 自包含），仅依赖 value（Value/ThreadContext）。
    // ir 模块依赖本模块的 lookupByName/returnKind/okTypeName 进行编译期查询。
    const syscall_module = b.createModule(.{
        .root_source_file = b.path("src/syscall/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    syscall_module.addImport("value", value_module);

    // ---- Glue IR 模块（新架构：共享内存图） ----
    // 依赖 syscall（SyscallId/lookupByName/returnKind/okTypeName 编译期查询）。
    const ir_module = b.createModule(.{
        .root_source_file = b.path("src/ir/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_module.addImport("ast", ast_module);
    ir_module.addImport("value", value_module);
    ir_module.addImport("analysis_db", analysis_db_module);
    ir_module.addImport("glue_builtin", builtin_module);
    ir_module.addImport("syscall", syscall_module);
    // v3 阶段 3：ir → sema 导入（用于架构收敛，builder.zig 消费 sema 侧 infer*/chanTypeFrom*）
    // Zig 0.16 支持模块间循环依赖（type_check ↔ subtype_check 已在用）。
    ir_module.addImport("sema", type_check_module);

    // ---- sema 模块接入 IR 管线：type_check 及子检查器可读取 SemaResult 契约 ----
    // 依赖方向：sema ↔ ir（双向），sema 产出 SemaResult，ir 消费 sema 侧 infer*/chanTypeFrom*
    type_check_module.addImport("ir", ir_module);
    // type_descriptor.zig 引用 value.Value（标量 vtable 的读写返回值类型）
    type_check_module.addImport("value", value_module);
    subtype_check_module.addImport("ir", ir_module);
    throw_check_module.addImport("ir", ir_module);
    trait_resolve_module.addImport("ir", ir_module);
    kind_check_module.addImport("ir", ir_module);
    gadt_check_module.addImport("ir", ir_module);
    module_check_module.addImport("ir", ir_module);

    // ---- 执行引擎模块（后端：接收 GlueIR 执行） ----
    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module.addImport("ir", ir_module);
    engine_module.addImport("mem", mem_module);
    engine_module.addImport("value", value_module);
    engine_module.addImport("syscall", syscall_module);
    engine_module.addImport("profiling", profiler_module);

    // ---- 协程调度模块（图驱动协程调度）----
    // 依赖 ir（CoroutineMeta 等）、value（ObjHeader/Value）、mem（ThreadContext）
    const coroutine_module = b.createModule(.{
        .root_source_file = b.path("src/coroutine/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    coroutine_module.addImport("ir", ir_module);
    coroutine_module.addImport("value", value_module);
    coroutine_module.addImport("mem", mem_module);
    coroutine_module.addImport("profiling", profiler_module);
    engine_module.addImport("coroutine", coroutine_module);

    // ---- 根模块：聚合所有依赖，产出可执行文件 ----
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("ast", ast_module);
    root_module.addImport("lexer", lexer_module);
    root_module.addImport("parser", parser_module);
    root_module.addImport("module_loader", module_loader_module);
    root_module.addImport("profiler", profiler_module);
    root_module.addImport("sema", type_check_module);
    root_module.addImport("debug_allocator", debug_allocator_module);
    root_module.addImport("ir", ir_module);
    root_module.addImport("engine", engine_module);
    root_module.addImport("analysis_db", analysis_db_module);
    // pipeline.zig 需按 value.Value 变体格式化返回值（eng.run() 返回 value.Value）
    root_module.addImport("value", value_module);

    const exe = b.addExecutable(.{
        .name = "glue",
        .root_module = root_module,
    });
    exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(exe);
}
