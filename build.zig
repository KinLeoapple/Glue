//! Glue 语言构建脚本
//!
//! 定义可执行目标 `glue` 以及各子模块之间的依赖关系，
//! 同时配置各模块的单元测试并聚合到 `test` 步骤。

const std = @import("std");

/// 构建入口：配置目标、优化级别、模块依赖、可执行产物与测试步骤
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

    // ---- 内存管理模块 ----
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/profiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ---- 并发原语模块：互斥锁、条件变量 ----
    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/sync/sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    const debug_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/mem/debug_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_allocator_module.addImport("sync", sync_module);

    // ---- 内存管理模块入口 ----
    const mem_module = b.createModule(.{
        .root_source_file = b.path("src/mem/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    mem_module.addImport("sync", sync_module);

    // ---- 值系统模块：依赖并发原语 ----
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("ast", ast_module);
    value_module.addImport("sync", sync_module);
    value_module.addImport("mem", mem_module);

    // ---- 语义分析模块族：分析数据库与各类检查器 ----
    const analysis_db_module = b.createModule(.{
        .root_source_file = b.path("src/sema/static_analysis/analysis_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    analysis_db_module.addImport("ast", ast_module);

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

    // ---- Glue IR 模块（新架构：共享内存图） ----
    const ir_module = b.createModule(.{
        .root_source_file = b.path("src/ir/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_module.addImport("ast", ast_module);
    ir_module.addImport("value", value_module);
    ir_module.addImport("analysis_db", analysis_db_module);
    ir_module.addImport("glue_builtin", builtin_module);

    // ---- sema 模块接入 IR 管线：type_check 及子检查器可读取 SemaResult 契约 ----
    // 依赖方向：sema → ir → (ast, value)，ir 不依赖 sema，无循环。
    type_check_module.addImport("ir", ir_module);
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
    root_module.addImport("value", value_module);
    root_module.addImport("profiler", profiler_module);
    root_module.addImport("sema", type_check_module);
    root_module.addImport("debug_allocator", debug_allocator_module);
    root_module.addImport("ir", ir_module);
    root_module.addImport("engine", engine_module);
    root_module.addImport("analysis_db", analysis_db_module);

    const exe = b.addExecutable(.{
        .name = "glue",
        .root_module = root_module,
    });
    exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(exe);

    // ---- 单元测试：为每个需要测试的模块创建测试产物 ----
    const lexer_unit_tests = b.addTest(.{
        .root_module = lexer_module,
    });
    const run_lexer_unit_tests = b.addRunArtifact(lexer_unit_tests);
    const parser_unit_tests = b.addTest(.{
        .root_module = parser_module,
    });
    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);
    const type_check_unit_tests = b.addTest(.{
        .root_module = type_check_module,
    });
    const run_type_check_unit_tests = b.addRunArtifact(type_check_unit_tests);
    const module_check_unit_tests = b.addTest(.{
        .root_module = module_check_module,
    });
    const run_module_check_unit_tests = b.addRunArtifact(module_check_unit_tests);
    const analysis_db_unit_tests = b.addTest(.{
        .root_module = analysis_db_module,
    });
    const run_analysis_db_unit_tests = b.addRunArtifact(analysis_db_unit_tests);
    const debug_allocator_unit_tests = b.addTest(.{
        .root_module = debug_allocator_module,
    });
    const run_debug_allocator_unit_tests = b.addRunArtifact(debug_allocator_unit_tests);

    // builtin 元信息表单元测试
    const builtin_unit_tests = b.addTest(.{
        .root_module = builtin_module,
    });
    const run_builtin_unit_tests = b.addRunArtifact(builtin_unit_tests);

    // 内存管理新模块测试（page_pool/buddy/channel_region/shadow_arena/global_pool/thread_ctx）
    const mem_test_modules = [_]struct { name: []const u8, file: []const u8, need_sync: bool }{
        .{ .name = "page_pool", .file = "src/mem/page_pool.zig", .need_sync = false },
        .{ .name = "buddy", .file = "src/mem/buddy.zig", .need_sync = true },
        .{ .name = "channel_region", .file = "src/mem/channel_region.zig", .need_sync = false },
        .{ .name = "shadow_arena", .file = "src/mem/shadow_arena.zig", .need_sync = false },
        .{ .name = "global_pool", .file = "src/mem/global_pool.zig", .need_sync = true },
        .{ .name = "thread_ctx", .file = "src/mem/thread_ctx.zig", .need_sync = true },
    };
    var mem_test_runs: [mem_test_modules.len]*std.Build.Step.Run = undefined;
    for (mem_test_modules, 0..) |m, i| {
        const mod = b.createModule(.{
            .root_source_file = b.path(m.file),
            .target = target,
            .optimize = optimize,
        });
        if (m.need_sync) mod.addImport("sync", sync_module);
        const test_art = b.addTest(.{ .root_module = mod });
        test_art.root_module.linkSystemLibrary("c", .{});
        mem_test_runs[i] = b.addRunArtifact(test_art);
    }

    // 值系统单独构建一份用于测试（需导入 sync 供 concurrent.zig 使用）
    const value_module_test = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module_test.addImport("sync", sync_module);
    value_module_test.addImport("ast", ast_module);
    value_module_test.addImport("mem", mem_module);
    const value_unit_tests = b.addTest(.{
        .root_module = value_module_test,
    });
    const run_value_unit_tests = b.addRunArtifact(value_unit_tests);

    // Glue IR 模块测试（需导入 ast 和 value）
    const ir_module_test = b.createModule(.{
        .root_source_file = b.path("src/ir/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_module_test.addImport("ast", ast_module);
    ir_module_test.addImport("value", value_module);
    ir_module_test.addImport("analysis_db", analysis_db_module);
    ir_module_test.addImport("glue_builtin", builtin_module);
    const ir_unit_tests = b.addTest(.{
        .root_module = ir_module_test,
    });
    const run_ir_unit_tests = b.addRunArtifact(ir_unit_tests);

    // 执行引擎测试（需导入 ir、mem、ast、lexer、parser、value）
    const engine_module_test = b.createModule(.{
        .root_source_file = b.path("src/engine/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module_test.addImport("ir", ir_module_test);
    engine_module_test.addImport("mem", mem_module);
    engine_module_test.addImport("ast", ast_module);
    engine_module_test.addImport("lexer", lexer_module);
    engine_module_test.addImport("parser", parser_module);
    engine_module_test.addImport("value", value_module);
    const engine_unit_tests = b.addTest(.{
        .root_module = engine_module_test,
    });
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);

    // 所有测试产物都需要链接 libc
    lexer_unit_tests.root_module.linkSystemLibrary("c", .{});
    parser_unit_tests.root_module.linkSystemLibrary("c", .{});
    type_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    module_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    analysis_db_unit_tests.root_module.linkSystemLibrary("c", .{});
    value_unit_tests.root_module.linkSystemLibrary("c", .{});
    debug_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    ir_unit_tests.root_module.linkSystemLibrary("c", .{});
    engine_unit_tests.root_module.linkSystemLibrary("c", .{});
    builtin_unit_tests.root_module.linkSystemLibrary("c", .{});

    // ---- 聚合测试步骤：`zig build test` 运行全部单元测试 ----
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_type_check_unit_tests.step);
    test_step.dependOn(&run_module_check_unit_tests.step);
    test_step.dependOn(&run_analysis_db_unit_tests.step);
    test_step.dependOn(&run_value_unit_tests.step);
    test_step.dependOn(&run_debug_allocator_unit_tests.step);
    test_step.dependOn(&run_ir_unit_tests.step);
    test_step.dependOn(&run_engine_unit_tests.step);
    test_step.dependOn(&run_builtin_unit_tests.step);
    for (mem_test_runs) |run| test_step.dependOn(&run.step);
}
