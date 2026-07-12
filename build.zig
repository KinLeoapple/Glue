//! Glue 语言构建脚本
//!
//! 定义可执行目标 `glue` 以及各子模块之间的依赖关系，
//! 同时配置各模块的单元测试并聚合到 `test` 步骤。

const std = @import("std");
const builtin = @import("builtin");

/// 构建入口：配置目标、优化级别、模块依赖、可执行产物与测试步骤
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 前端核心模块：AST、词法分析器、语法分析器 ----
    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);

    // ---- 运行时基础模块：slab 分配器、性能分析器、同步原语、channel、spawn、原子操作 ----
    const slab_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/slab_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/profiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    const channel_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/channel.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spawn_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/spawn.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atomic_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/atomic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const debug_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/debug_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_allocator_module.addImport("sync", sync_module);
    const arena_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/arena_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("arena_allocator", arena_allocator_module);

    // ---- 值系统模块：与运行时各模块互相导入 ----
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("ast", ast_module);
    value_module.addImport("atomic", atomic_module);
    value_module.addImport("channel", channel_module);
    value_module.addImport("spawn", spawn_module);
    atomic_module.addImport("value", value_module);
    atomic_module.addImport("sync", sync_module);
    channel_module.addImport("value", value_module);
    channel_module.addImport("sync", sync_module);
    spawn_module.addImport("value", value_module);
    spawn_module.addImport("sync", sync_module);
    slab_allocator_module.addImport("value", value_module);
    slab_allocator_module.addImport("sync", sync_module);

    // ---- 语义分析模块族：分析数据库与各类检查器 ----
    const analysis_db_module = b.createModule(.{
        .root_source_file = b.path("src/sema/static_analysis/analysis_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    analysis_db_module.addImport("ast", ast_module);
    const type_check_module = b.createModule(.{
        .root_source_file = b.path("src/sema/type_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_check_module.addImport("ast", ast_module);
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

    // ---- 标准库模块 ----
    const stdlib_module = b.createModule(.{
        .root_source_file = b.path("src/stdlib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- 模块加载器：串联前端、语义分析与标准库 ----
    const module_loader_module = b.createModule(.{
        .root_source_file = b.path("src/loader/module_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_loader_module.addImport("ast", ast_module);
    module_loader_module.addImport("lexer", lexer_module);
    module_loader_module.addImport("parser", parser_module);
    module_loader_module.addImport("sema", type_check_module);
    module_loader_module.addImport("stdlib", stdlib_module);
    module_loader_module.addImport("analysis_db", analysis_db_module);
    module_loader_module.addImport("arena_allocator", arena_allocator_module);

    // ---- 虚拟机模块：共享层与寄存器式编译器 ----
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/vm/shared/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_module.addImport("ast", ast_module);
    shared_module.addImport("value", value_module);
    const reg_vm_module = b.createModule(.{
        .root_source_file = b.path("src/vm/reg/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    reg_vm_module.addImport("ast", ast_module);
    reg_vm_module.addImport("value", value_module);
    reg_vm_module.addImport("lexer", lexer_module);
    reg_vm_module.addImport("parser", parser_module);
    reg_vm_module.addImport("profiler", profiler_module);
    reg_vm_module.addImport("analysis_db", analysis_db_module);
    reg_vm_module.addImport("slab_allocator", slab_allocator_module);
    reg_vm_module.addImport("debug_allocator", debug_allocator_module);
    reg_vm_module.addImport("arena_allocator", arena_allocator_module);
    reg_vm_module.addImport("shared", shared_module);

    // ---- JIT 编译器模块 ----
    const jit_module = b.createModule(.{
        .root_source_file = b.path("src/jit/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    jit_module.addImport("value", value_module);
    jit_module.addImport("ast", ast_module);
    jit_module.addImport("reg_vm", reg_vm_module);
    // 循环依赖：reg_vm 需要 jit 模块来集成 JIT 加速
    // Zig 的惰性编译可以正确处理这种循环导入
    reg_vm_module.addImport("jit", jit_module);

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
    root_module.addImport("slab_allocator", slab_allocator_module);
    root_module.addImport("profiler", profiler_module);
    root_module.addImport("reg_vm", reg_vm_module);
    root_module.addImport("sema", type_check_module);
    root_module.addImport("debug_allocator", debug_allocator_module);
    root_module.addImport("arena_allocator", arena_allocator_module);
    root_module.addImport("jit", jit_module);

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
    const slab_allocator_unit_tests = b.addTest(.{
        .root_module = slab_allocator_module,
    });
    const run_slab_allocator_unit_tests = b.addRunArtifact(slab_allocator_unit_tests);
    const stdlib_unit_tests = b.addTest(.{
        .root_module = stdlib_module,
    });
    const run_stdlib_unit_tests = b.addRunArtifact(stdlib_unit_tests);
    const reg_vm_unit_tests = b.addTest(.{
        .root_module = reg_vm_module,
    });
    const run_reg_vm_unit_tests = b.addRunArtifact(reg_vm_unit_tests);
    const atomic_unit_tests = b.addTest(.{
        .root_module = atomic_module,
    });
    const run_atomic_unit_tests = b.addRunArtifact(atomic_unit_tests);
    const analysis_db_unit_tests = b.addTest(.{
        .root_module = analysis_db_module,
    });
    const run_analysis_db_unit_tests = b.addRunArtifact(analysis_db_unit_tests);
    const debug_allocator_unit_tests = b.addTest(.{
        .root_module = debug_allocator_module,
    });
    const run_debug_allocator_unit_tests = b.addRunArtifact(debug_allocator_unit_tests);
    const arena_allocator_unit_tests = b.addTest(.{
        .root_module = arena_allocator_module,
    });
    const run_arena_allocator_unit_tests = b.addRunArtifact(arena_allocator_unit_tests);
    const jit_unit_tests = b.addTest(.{
        .root_module = jit_module,
    });
    const run_jit_unit_tests = b.addRunArtifact(jit_unit_tests);

    // 值系统单独构建一份用于测试（避免与运行时互相导入形成循环依赖）
    const value_new_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const value_new_unit_tests = b.addTest(.{
        .root_module = value_new_module,
    });
    const run_value_new_unit_tests = b.addRunArtifact(value_new_unit_tests);

    // 所有测试产物都需要链接 libc
    lexer_unit_tests.root_module.linkSystemLibrary("c", .{});
    parser_unit_tests.root_module.linkSystemLibrary("c", .{});
    type_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    module_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    slab_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    stdlib_unit_tests.root_module.linkSystemLibrary("c", .{});
    reg_vm_unit_tests.root_module.linkSystemLibrary("c", .{});
    atomic_unit_tests.root_module.linkSystemLibrary("c", .{});
    analysis_db_unit_tests.root_module.linkSystemLibrary("c", .{});
    value_new_unit_tests.root_module.linkSystemLibrary("c", .{});
    debug_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    arena_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    jit_unit_tests.root_module.linkSystemLibrary("c", .{});

    // ---- 聚合测试步骤：`zig build test` 运行全部单元测试 ----
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_type_check_unit_tests.step);
    test_step.dependOn(&run_module_check_unit_tests.step);
    test_step.dependOn(&run_slab_allocator_unit_tests.step);
    test_step.dependOn(&run_stdlib_unit_tests.step);
    test_step.dependOn(&run_reg_vm_unit_tests.step);
    test_step.dependOn(&run_atomic_unit_tests.step);
    test_step.dependOn(&run_analysis_db_unit_tests.step);
    test_step.dependOn(&run_value_new_unit_tests.step);
    test_step.dependOn(&run_debug_allocator_unit_tests.step);
    test_step.dependOn(&run_arena_allocator_unit_tests.step);
    test_step.dependOn(&run_jit_unit_tests.step);
}
