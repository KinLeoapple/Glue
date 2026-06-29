const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Shared base modules
    // ============================================================

    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });

    const intern_module = b.createModule(.{
        .root_source_file = b.path("src/intern.zig"),
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

    // ============================================================
    // runtime/ sub-modules
    // ============================================================

    const slab_pool_module = b.createModule(.{
        .root_source_file = b.path("runtime/slab_pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    // profiler 模块：全管线 profiling（阶段计时 + 内存统计 + opcode 频率）。独立无依赖，
    // vm 与 root 共享（VM 计数 opcode，main 埋点阶段 + 注入 SlabPool 统计 + dump）。
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/profiler.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sync_module = b.createModule(.{
        .root_source_file = b.path("runtime/sync.zig"),
        .target = target,
        .optimize = optimize,
    });

    const channel_module = b.createModule(.{
        .root_source_file = b.path("runtime/channel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spawn_module = b.createModule(.{
        .root_source_file = b.path("runtime/spawn.zig"),
        .target = target,
        .optimize = optimize,
    });

    const atomic_module = b.createModule(.{
        .root_source_file = b.path("runtime/atomic.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vtable_module = b.createModule(.{
        .root_source_file = b.path("runtime/vtable.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // value module - 核心值表示层（与 ast 同级）
    // ============================================================

    const value_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("ast", ast_module);
    // value ↔ runtime: 循环依赖（value re-export runtime 类型，runtime 引用 Value）
    value_module.addImport("atomic", atomic_module);
    value_module.addImport("channel", channel_module);
    value_module.addImport("spawn", spawn_module);
    atomic_module.addImport("value", value_module);
    channel_module.addImport("value", value_module);
    channel_module.addImport("sync", sync_module);
    spawn_module.addImport("value", value_module);
    spawn_module.addImport("sync", sync_module);
    vtable_module.addImport("value", value_module);

    // ============================================================
    // sema/ modules - 语义分析（类型检查、trait解析等）
    // ============================================================

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

    const resolve_module = b.createModule(.{
        .root_source_file = b.path("src/sema/resolve.zig"),
        .target = target,
        .optimize = optimize,
    });
    resolve_module.addImport("ast", ast_module);
    resolve_module.addImport("intern", intern_module);

    // ============================================================
    // stdlib module
    // ============================================================

    const stdlib_module = b.createModule(.{
        .root_source_file = b.path("src/stdlib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // loader/ modules - 模块加载器
    // ============================================================

    const module_loader_module = b.createModule(.{
        .root_source_file = b.path("src/loader/module_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_loader_module.addImport("ast", ast_module);
    module_loader_module.addImport("lexer", lexer_module);
    module_loader_module.addImport("parser", parser_module);
    module_loader_module.addImport("sema", type_check_module);
    module_loader_module.addImport("resolve", resolve_module);
    module_loader_module.addImport("intern", intern_module);
    module_loader_module.addImport("stdlib", stdlib_module);

    // ============================================================
    // vm/ sub-modules（字节码 VM — docs/bytecode-vm-plan.md）
    // ============================================================
    // 依赖图顶点是 compiler.zig（它 @import vm.zig / disasm.zig / chunk.zig / opcode.zig）。
    // 只需注册一个模块，relative @import 拉起其余文件；外部依赖经 import 表注入。

    const vm_module = b.createModule(.{
        .root_source_file = b.path("src/vm/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_module.addImport("ast", ast_module);
    vm_module.addImport("value", value_module);
    vm_module.addImport("lexer", lexer_module);
    vm_module.addImport("parser", parser_module);
    vm_module.addImport("profiler", profiler_module);

    // sema 内部循环依赖：type_check ↔ subtype_check / throw_check / trait_resolve
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
    trait_resolve_module.addImport("kind_check", kind_check_module);
    gadt_check_module.addImport("type_check", type_check_module);

    // ============================================================
    // module/ sub-modules
    // ============================================================

    const module_resolver_module = b.createModule(.{
        .root_source_file = b.path("src/module/resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_resolver_module.addImport("ast", ast_module);

    // ============================================================
    // 内嵌标准库（@embedFile stdlib/*.glue）
    // ============================================================

    // ============================================================
    // Root module
    // ============================================================

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
    root_module.addImport("slab_pool", slab_pool_module);
    root_module.addImport("profiler", profiler_module);
    // M5：字节码 VM 接入 glue run（vm_module 再导出 VM/Program/ModuleCompiler/lexer/parser）。
    root_module.addImport("vm", vm_module);

    // Create glue executable
    const exe = b.addExecutable(.{
        .name = "glue",
        .root_module = root_module,
    });

    // Install executable to output directory
    b.installArtifact(exe);

    // VM bench 驱动：编译并在字节码 VM 上端到端跑 lookup 基准（含 main + println）。
    // root = src/vm/bench_main.zig，import "compiler"（= vm_module，再导出 vm/Program/lexer/parser）。
    const bench_vm_module = b.createModule(.{
        .root_source_file = b.path("src/vm/bench_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_vm_module.addImport("compiler", vm_module);
    const bench_vm_exe = b.addExecutable(.{
        .name = "bench_vm_lookup",
        .root_module = bench_vm_module,
    });
    const run_bench_vm = b.addRunArtifact(bench_vm_exe);
    const bench_vm_step = b.step("bench-vm", "Run lookup/record bench on the bytecode VM (exe arg: lookup|record)");
    bench_vm_step.dependOn(&run_bench_vm.step);

    // ============================================================
    // Tests
    // ============================================================

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

    const slab_pool_unit_tests = b.addTest(.{
        .root_module = slab_pool_module,
    });
    const run_slab_pool_unit_tests = b.addRunArtifact(slab_pool_unit_tests);

    const stdlib_unit_tests = b.addTest(.{
        .root_module = stdlib_module,
    });
    const run_stdlib_unit_tests = b.addRunArtifact(stdlib_unit_tests);

    const intern_unit_tests = b.addTest(.{
        .root_module = intern_module,
    });
    const run_intern_unit_tests = b.addRunArtifact(intern_unit_tests);

    const vm_unit_tests = b.addTest(.{
        .root_module = vm_module,
    });
    const run_vm_unit_tests = b.addRunArtifact(vm_unit_tests);

    // ============================================================
    // value_new 模块（自定义基础类型，独立 standalone）
    // ============================================================

    const value_new_module = b.createModule(.{
        .root_source_file = b.path("src/value/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const value_new_unit_tests = b.addTest(.{
        .root_module = value_new_module,
    });
    const run_value_new_unit_tests = b.addRunArtifact(value_new_unit_tests);

    const bench_value_module = b.createModule(.{
        .root_source_file = b.path("src/value/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_value_exe = b.addExecutable(.{
        .name = "bench_value",
        .root_module = bench_value_module,
    });
    const run_bench_value = b.addRunArtifact(bench_value_exe);
    const bench_value_step = b.step("bench-value", "Run custom types vs native bench");
    bench_value_step.dependOn(&run_bench_value.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_type_check_unit_tests.step);
    test_step.dependOn(&run_module_check_unit_tests.step);
    test_step.dependOn(&run_slab_pool_unit_tests.step);
    test_step.dependOn(&run_stdlib_unit_tests.step);
    test_step.dependOn(&run_intern_unit_tests.step);
    test_step.dependOn(&run_vm_unit_tests.step);
    test_step.dependOn(&run_value_new_unit_tests.step);
}
