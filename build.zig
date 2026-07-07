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

    // slab_allocator_module：通用多线程 Slab 分配器（统一分配器，替代 HeapAllocator/MagazineAllocator/SlabPool）。
    // 特性：Per-class Mutex + ThreadCache + Comptime 特化（SIZE_CLASSES 合并装箱类型 @sizeOf，
    // TypedPool(T) 类型安全 acquire/release）。依赖 value（编译期收集装箱类型大小）。
    // loader/AST/value/spawn 全部统一使用此分配器。
    // 注：value_module 在下方定义，addImport 在 value_module 之后调用。
    const slab_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/slab_allocator.zig"),
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

    // debug_allocator 模块：自实现 DebugAllocator（c_allocator + 泄漏/double-free 检测），
    // 替代 std.heap.DebugAllocator。
    const debug_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/debug_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_allocator_module.addImport("sync", sync_module);

    // arena_allocator 模块：自实现 ArenaAllocator（c_allocator backing + chunk 链表 bump 分配），
    // 替代 std.heap.ArenaAllocator。
    const arena_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/arena_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // parser 依赖 arena_allocator（替代 std.heap.ArenaAllocator）
    parser_module.addImport("arena_allocator", arena_allocator_module);

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
    atomic_module.addImport("sync", sync_module);
    channel_module.addImport("value", value_module);
    channel_module.addImport("sync", sync_module);
    spawn_module.addImport("value", value_module);
    spawn_module.addImport("sync", sync_module);
    // slab_allocator 依赖 value（编译期收集装箱类型 @sizeOf 生成 SIZE_CLASSES）
    slab_allocator_module.addImport("value", value_module);
    slab_allocator_module.addImport("sync", sync_module);

    // ============================================================
    // sema/ modules - 语义分析（类型检查、trait解析等）
    // ============================================================

    // analysis_db 模块：JIT 静态分析数据库（purity/call_graph/const_prop 等）。
    // 依赖 ast。供 vm/compiler 和 loader 查询优化决策。
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
    module_loader_module.addImport("stdlib", stdlib_module);
    module_loader_module.addImport("analysis_db", analysis_db_module);
    module_loader_module.addImport("arena_allocator", arena_allocator_module);

    // ============================================================
    // vm/ sub-modules（字节码 VM — docs/bytecode-vm-plan.md）
    // ============================================================
    // 依赖图顶点是 compiler.zig（它 @import vm.zig / disasm.zig / chunk.zig / opcode.zig）。
    // 只需注册一个模块，外部依赖经 import 表注入。

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
    vm_module.addImport("analysis_db", analysis_db_module);
    vm_module.addImport("slab_allocator", slab_allocator_module);
    vm_module.addImport("debug_allocator", debug_allocator_module);
    vm_module.addImport("arena_allocator", arena_allocator_module);

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
    root_module.addImport("slab_allocator", slab_allocator_module);
    root_module.addImport("profiler", profiler_module);
    root_module.addImport("vm", vm_module);
    root_module.addImport("sema", type_check_module);
    root_module.addImport("debug_allocator", debug_allocator_module);
    root_module.addImport("arena_allocator", arena_allocator_module);

    // Create glue executable
    const exe = b.addExecutable(.{
        .name = "glue",
        .root_module = root_module,
    });
    // 链接 libc：底层 backing 使用 c_allocator（libc malloc，精确按需分配），
    // 替代 Zig 原生 page_allocator / GeneralPurposeAllocator / DebugAllocator。
    exe.root_module.linkSystemLibrary("c", .{});

    // Install executable to output directory
    b.installArtifact(exe);

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

    const slab_allocator_unit_tests = b.addTest(.{
        .root_module = slab_allocator_module,
    });
    const run_slab_allocator_unit_tests = b.addRunArtifact(slab_allocator_unit_tests);

    const stdlib_unit_tests = b.addTest(.{
        .root_module = stdlib_module,
    });
    const run_stdlib_unit_tests = b.addRunArtifact(stdlib_unit_tests);

    const vm_unit_tests = b.addTest(.{
        .root_module = vm_module,
    });
    const run_vm_unit_tests = b.addRunArtifact(vm_unit_tests);

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

    // 测试同样需要链接 libc（c_allocator 依赖 libc malloc/free）。
    lexer_unit_tests.root_module.linkSystemLibrary("c", .{});
    parser_unit_tests.root_module.linkSystemLibrary("c", .{});
    type_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    module_check_unit_tests.root_module.linkSystemLibrary("c", .{});
    slab_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    stdlib_unit_tests.root_module.linkSystemLibrary("c", .{});
    vm_unit_tests.root_module.linkSystemLibrary("c", .{});
    atomic_unit_tests.root_module.linkSystemLibrary("c", .{});
    analysis_db_unit_tests.root_module.linkSystemLibrary("c", .{});
    value_new_unit_tests.root_module.linkSystemLibrary("c", .{});
    debug_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});
    arena_allocator_unit_tests.root_module.linkSystemLibrary("c", .{});

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_type_check_unit_tests.step);
    test_step.dependOn(&run_module_check_unit_tests.step);
    test_step.dependOn(&run_slab_allocator_unit_tests.step);
    test_step.dependOn(&run_stdlib_unit_tests.step);
    test_step.dependOn(&run_vm_unit_tests.step);
    test_step.dependOn(&run_atomic_unit_tests.step);
    test_step.dependOn(&run_analysis_db_unit_tests.step);
    test_step.dependOn(&run_value_new_unit_tests.step);
    test_step.dependOn(&run_debug_allocator_unit_tests.step);
    test_step.dependOn(&run_arena_allocator_unit_tests.step);
}
