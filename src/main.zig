const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const module_loader = @import("module_loader");
const value = @import("value");
const slab_pool = @import("slab_pool");
const vm = @import("vm");
const profiler = @import("profiler");
const cache_mod = @import("cache");
const type_check = @import("sema");

/// 把求值器错误映射为专业英文消息（Go/Java 风格）。
/// 若求值器已经设置了带上下文的 panic_message（如 "no method 'x' on type 'array'"），
/// 优先使用它；否则按错误枚举给出通用但专业的兜底措辞。
fn runtimeErrorMessage(err: anyerror, panic_message: ?[]const u8) []const u8 {
    if (panic_message) |msg| return msg;
    return switch (err) {
        error.TypeMismatch => "type error: incompatible types",
        error.UndefinedVariable => "undefined name",
        error.ImmutableAssignment => "cannot assign to immutable binding",
        error.NotCallable => "value is not callable",
        error.WrongArity => "wrong number of arguments",
        error.IndexOutOfBounds => "index out of bounds",
        error.UnsupportedOperation => "unsupported operation",
        error.OutOfMemory => "out of memory",
        error.CircularDependency => "circular module dependency",
        error.FileNotFound => "file not found",
        error.MissingMain => "undefined entry point",
        else => @errorName(err),
    };
}

/// 打印一条运行时诊断，带可选行列。有位置则 `file:line:col: label: msg`，否则 `file: label: msg`。
fn printRuntimeDiag(iface: anytype, filename: []const u8, loc: ?ast.SourceLocation, label: []const u8, msg: []const u8) void {
    if (loc) |l| {
        iface.print("{s}:{d}:{d}: {s}: {s}\n", .{ filename, l.line, l.column, label, msg }) catch {};
    } else {
        iface.print("{s}: {s}: {s}\n", .{ filename, label, msg }) catch {};
    }
}

/// 项目清单（glue.toml）解析结果。
const Manifest = struct {
    name: []const u8,
    version: []const u8,
    /// 入口文件相对项目根的路径，缺省 "src/Main.glue"。
    entry: []const u8,
};

const MANIFEST_NAME = "glue.toml";
const DEFAULT_ENTRY = "src/Main.glue";

// ============================================================
// 运行选项（命令行 flag）
// ============================================================

/// `--profile`：全管线 profiling（阶段计时 + 内存统计 + opcode 频率），结束后输出报告。
var profiler_enabled: bool = false;

/// `--no-specialize`：禁用 JIT Phase 1 类型特化 opcode，全部回退到通用 opcode（A/B 对比用）。
var no_specialize: bool = false;

/// `--no-cache`：禁用字节码缓存（强制全量重编）。
var no_cache: bool = false;

/// 全局 profiler 实例（runNormal/runDiagnostic 入口设置 io，各阶段埋点写入，结束 dump）。
var prof: profiler.Profiler = .{};

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

fn printUsage(io: std.Io) void {
    printError(io,
        \\Glue v0.1.0 — project-based language runtime
        \\
        \\Usage:
        \\  glue init [name]   Scaffold a new Glue project (in ./name or current dir)
        \\  glue run           Build and run the current project
        \\  glue debug         Run with diagnostics (memory checking + runtime trace)
        \\
        \\Options:
        \\  --profile          Dump full pipeline profile (phases + memory + opcodes) after run
        \\  --no-specialize    Disable JIT Phase 1 type-specialized opcodes (A/B comparison)
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    // Windows 控制台默认使用 GBK 编码，需设置为 UTF-8 以正确输出非 ASCII 字符
    if (builtin.os.tag == .windows) {
        setWindowsConsoleUtf8();
    }

    const allocator = init.gpa;
    const io = init.io;

    const args_slice = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());

    if (args_slice.len < 2) {
        printUsage(io);
        std.process.exit(1);
    }

    const cmd = args_slice[1];

    if (std.mem.eql(u8, cmd, "init")) {
        const name: ?[]const u8 = if (args_slice.len >= 3) args_slice[2] else null;
        try cmdInit(allocator, io, name);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "debug")) {
        // 运行选项（命令行 flag）：扫描命令之后的参数。--profile 对 run/debug 均生效。
        for (args_slice[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--profile")) {
                profiler_enabled = true;
            } else if (std.mem.eql(u8, arg, "--no-specialize")) {
                no_specialize = true;
            } else if (std.mem.eql(u8, arg, "--no-cache")) {
                no_cache = true;
            } else {
                printError(io, "error: unknown option '{s}'\n\n", .{arg});
                printUsage(io);
                std.process.exit(1);
            }
        }
        try runProject(allocator, io, std.mem.eql(u8, cmd, "debug"));
    } else {
        printError(io, "error: unknown command '{s}'\n\n", .{cmd});
        printUsage(io);
        std.process.exit(1);
    }
}

// ============================================================
// 项目根定位 + 清单解析
// ============================================================

/// 从 cwd 向上逐级查找 glue.toml，返回项目根的相对路径前缀（"" 表示当前目录）。
/// 找不到返回 null。最多上溯 64 级（防御）。
fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var level: usize = 0;
    while (level < 64) : (level += 1) {
        // 拼出 <prefix>glue.toml 检测
        const candidate = if (prefix.items.len == 0)
            try allocator.dupe(u8, MANIFEST_NAME)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix.items, MANIFEST_NAME });
        defer allocator.free(candidate);
        if (cwd.access(io, candidate, .{})) {
            return try allocator.dupe(u8, prefix.items);
        } else |_| {}
        // 上溯一级：prefix 追加 "../"
        try prefix.appendSlice(allocator, ".." ++ [_]u8{std.fs.path.sep});
    }
    return null;
}

/// 极简 TOML 子集解析：逐行认 `key = "value"`（或裸值），忽略空行与 `#` 注释。
/// 仅取 name/version/entry 三个键；entry 缺省 src/Main.glue。返回的字符串借用 source（不分配）。
fn parseManifest(source: []const u8) Manifest {
    var name: []const u8 = "app";
    var version: []const u8 = "0.0.0";
    var entry: []const u8 = DEFAULT_ENTRY;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // 剥去成对引号
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "entry")) {
            if (val.len > 0) entry = val;
        }
    }
    return .{ .name = name, .version = version, .entry = entry };
}

// ============================================================
// glue init
// ============================================================

/// 检查目标目录状态，用于 init 的空目录约束。
const DirState = enum {
    /// 目录不存在（可创建）
    missing,
    /// 目录存在且为空
    empty,
    /// 目录存在但非空（无 glue.toml）
    non_empty,
    /// 目录存在且含 glue.toml（已是项目）
    is_project,
};

/// 检查 path 指向的目录状态。path 为空串表示当前目录。
fn checkDirState(io: std.Io, path: []const u8) DirState {
    const cwd = std.Io.Dir.cwd();
    const open_path = if (path.len == 0) "." else path;
    var dir = cwd.openDir(io, open_path, .{ .iterate = true }) catch {
        return .missing; // 打不开（多半不存在）→ 视为可创建
    };
    defer dir.close(io);
    var it = dir.iterate();
    var empty = true;
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, MANIFEST_NAME)) return .is_project;
        empty = false;
    }
    return if (empty) .empty else .non_empty;
}

fn cmdInit(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // 目标目录前缀：有 name 则 "name/"，否则当前目录 ""。
    const dir_prefix = if (name) |n|
        try std.fmt.allocPrint(allocator, "{s}{c}", .{ n, std.fs.path.sep })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dir_prefix);

    // 项目名：有 name 用 name，否则用 "app"。
    const proj_name = name orelse "app";

    // init 只在空目录初始化：先检查目标目录状态。
    // 目标目录 = name（或当前目录）；非空且非已存在项目 → 拒绝。
    const target_dir = name orelse "";
    switch (checkDirState(io, target_dir)) {
        .is_project => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printError(io, "error: already a Glue project ({s} contains {s})\n", .{ shown, MANIFEST_NAME });
            std.process.exit(1);
        },
        .non_empty => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printError(io, "error: {s} is not an empty directory\n", .{shown});
            std.process.exit(1);
        },
        .missing, .empty => {}, // 可初始化
    }

    // 清单路径
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, MANIFEST_NAME });
    defer allocator.free(manifest_path);

    // 创建目录：<prefix>src/
    const src_dir = try std.fmt.allocPrint(allocator, "{s}src", .{dir_prefix});
    defer allocator.free(src_dir);
    cwd.createDirPath(io, src_dir) catch |err| {
        printError(io, "error: could not create directory '{s}': {s}\n", .{ src_dir, @errorName(err) });
        std.process.exit(1);
    };

    // 写清单
    const manifest_content = try std.fmt.allocPrint(allocator,
        \\name = "{s}"
        \\version = "0.1.0"
        \\entry = "{s}"
        \\
    , .{ proj_name, DEFAULT_ENTRY });
    defer allocator.free(manifest_content);
    cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_content }) catch |err| {
        printError(io, "error: could not write '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };

    // 写入口 src/Main.glue
    const main_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, DEFAULT_ENTRY });
    defer allocator.free(main_path);
    const main_content =
        \\fun main() {
        \\    println("Hello, Glue!")
        \\}
        \\
    ;
    cwd.writeFile(io, .{ .sub_path = main_path, .data = main_content }) catch |err| {
        printError(io, "error: could not write '{s}': {s}\n", .{ main_path, @errorName(err) });
        std.process.exit(1);
    };

    var out_buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    w.interface.print("Created Glue project '{s}'\n  {s}\n  {s}\n", .{ proj_name, manifest_path, main_path }) catch {};
    w.flush() catch {};
}

// ============================================================
// glue run / glue debug
// ============================================================

/// 运行当前项目。diagnostic=true 走 DebugAllocator 诊断模式（glue debug）。
fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();

    const root = (try findProjectRoot(allocator, io)) orelse {
        printError(io, "error: not a Glue project (no {s} found); run 'glue init' first\n", .{MANIFEST_NAME});
        std.process.exit(1);
    };
    defer allocator.free(root);

    // 读清单
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const manifest_src = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| {
        printError(io, "error: could not read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest_src);
    const manifest = parseManifest(manifest_src);

    // 入口文件路径 = root + entry
    const entry_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest.entry });
    defer allocator.free(entry_path);

    const source = cwd.readFileAlloc(io, entry_path, allocator, .unlimited) catch |err| {
        printError(io, "error: could not read entry '{s}': {s}\n", .{ entry_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(source);

    if (diagnostic) {
        try runDiagnostic(allocator, io, source, entry_path);
    } else {
        try runNormal(allocator, io, source, entry_path);
    }
}

/// 普通运行（arena 快路径 + SlabPool）。出错以非零码退出。
fn runNormal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var pool = slab_pool.SlabPool.init(allocator);
    defer pool.deinit();
    const value_allocator = pool.allocator();

    // 【缓存】创建 CacheStore（.cache 目录，按 mtime+size+符号签名命中）
    var cache_store = cache_mod.CacheStore.init(arena_alloc, io, ".cache", !no_cache);
    if (!no_cache) cache_store.ensureDir() catch {};

    var loader = module_loader.ModuleLoader.init(arena_alloc, io);
    defer loader.deinit();
    loader.cache_store = &cache_store;

    // profiler：初始化（io 用于单调时钟）。SlabPool 统计在 executeSource 返回后注入（pool 未 deinit）。
    prof = profiler.Profiler.init(profiler_enabled, io);

    const outcome = executeSource(arena_alloc, &loader, value_allocator, io, source, entry_path);

    // 注入 SlabPool 内存统计 + 输出 profile 报告（pool.deinit 前读取准确统计）。
    if (profiler_enabled) {
        prof.recordSlabStats(pool.live_bytes, pool.reserved_bytes, pool.live_peak_bytes, pool.peak_bytes);
        prof.dump(io);
    }

    // VM 已执行 main 或失败
    if (outcome == .failed) {
        loader.deinit();
        arena.deinit();
        pool.deinit();
        std.process.exit(1);
    }
}

/// 诊断运行（glue debug）：全程 DebugAllocator + SlabPool(backing=dbg) 检测 double-free/泄漏，
/// trace=true 输出更详细的运行时错误位置链。结束报告 [GLUE_GPA] LEAK/clean。
fn runDiagnostic(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    _ = allocator;
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const dbg_alloc = dbg.allocator();
    {
        var pool = slab_pool.SlabPool.init(dbg_alloc);
        defer pool.deinit();
        const value_allocator = pool.allocator();

        // 【缓存】诊断模式同样支持缓存（便于检测缓存路径的内存问题）
        var cache_store = cache_mod.CacheStore.init(dbg_alloc, io, ".cache", !no_cache);
        if (!no_cache) cache_store.ensureDir() catch {};

        var loader = module_loader.ModuleLoader.init(dbg_alloc, io);
        defer loader.deinit();
        loader.cache_store = &cache_store;

        // profiler：诊断模式同样支持 profiling。
        prof = profiler.Profiler.init(profiler_enabled, io);

        _ = executeSource(dbg_alloc, &loader, value_allocator, io, source, entry_path);

        if (profiler_enabled) {
            prof.recordSlabStats(pool.live_bytes, pool.reserved_bytes, pool.live_peak_bytes, pool.peak_bytes);
            prof.dump(io);
        }
    }
    const leaked = dbg.deinit();
    if (leaked == .leak) {
        printError(io, "[GLUE_GPA] LEAK detected\n", .{});
    } else {
        printError(io, "[GLUE_GPA] clean (no leak / no double-free)\n", .{});
    }
}

// ============================================================
// M5：字节码 VM 执行路径 + 树遍历器回退
// ============================================================

/// tryRunOnVM 的结果。
/// - ran_main：VM 已编译并执行 main（含 println 等副作用）。
/// - failed：准备阶段（类型检查）失败或 VM 运行期 panic（已报告）。
const VmOutcome = enum { ran_main, failed };

/// VM 资格检查：确保模块有 main 函数
/// VM 编译器现在处理所有声明类型，不再需要保守的预扫描
fn vmEligible(module: ast.Module) bool {
    for (module.declarations) |decl| {
        switch (decl) {
            .fun_decl => |f| {
                if (std.mem.eql(u8, f.name, "main")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// 尝试在字节码 VM 上整体编译并执行模块（含 main）。
fn tryRunOnVM(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    value_allocator: std.mem.Allocator,
    io: std.Io,
    module: ast.Module,
    filename: []const u8,
) VmOutcome {
    if (!vmEligible(module)) {
        printError(io, "{s}: error: no 'main' function found\n", .{filename});
        return .failed;
    }

    // 【whole-program cache】尝试从缓存加载合并后 Program（命中则跳过 prepareModule + compile）
    if (loader.cache_store) |store| {
        if (store.enabled) {
            if (tryLoadWholeProgram(allocator, store, io, module, filename)) |cached_program| {
                // 缓存命中：直接执行
                var program = cached_program;
                defer program.deinit();
                const entry = program.entry orelse {
                    printError(io, "{s}: error: cached program has no entry\n", .{filename});
                    return .failed;
                };
                return runProgram(allocator, value_allocator, io, &program, entry, filename);
            }
        }
    }

    // 准备阶段：use 预加载 + 类型检查 + resolve
    prof.phaseBegin(.type_check);
    loader.prepareModule(module) catch |err| switch (err) {
        error.TypeCheckFailed => {
            prof.phaseEnd();
            return .failed;
        },
        error.CircularDependency => {
            prof.phaseEnd();
            printError(io, "{s}: error: circular module dependency\n", .{filename});
            return .failed;
        },
        else => {
            prof.phaseEnd();
            printError(io, "{s}: error: preparation failed: {s}\n", .{ filename, @errorName(err) });
            return .failed;
        },
    };
    prof.phaseEnd();

    // 编译模块 → Program
    var mc = vm.ModuleCompiler.init(allocator);
    // JIT Phase 2: wire AnalysisDB (含 type_table 引用) from ModuleLoader to ModuleCompiler
    // --no-specialize 时留空（null），编译器全部回退到通用 opcode
    if (!no_specialize) {
        loader.analysis_db.type_table = &loader.type_inferencer.type_table;
        mc.analysis_db = &loader.analysis_db;
    }
    defer mc.deinit();
    defer mc.program.deinit();

    // 收集 use 依赖模块
    if (module.source_path) |sp| {
        const sep_idx = std.mem.lastIndexOfScalar(u8, sp, std.fs.path.sep) orelse
            std.mem.lastIndexOfScalar(u8, sp, '/');
        if (sep_idx) |idx| loader.setSourceDir(sp[0..idx]) catch {};
    }
    var deps = std.ArrayList(ast.Module).empty;
    defer deps.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }
    loader.collectDependencies(module, &deps, &seen) catch |err| {
        printError(io, "{s}: error: dependency collection failed: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };

    prof.phaseBegin(.compile);
    mc.compileModuleWithDeps(&module, deps.items) catch |err| {
        prof.phaseEnd();
        printError(io, "{s}: error: compilation failed: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    prof.phaseEnd();

    const entry = mc.lookupFn("main") orelse {
        printError(io, "{s}: error: 'main' function not found after compilation\n", .{filename});
        return .failed;
    };

    // 【whole-program cache】编译成功后写入缓存（包含合并后 Program + 依赖列表 + usage）
    if (loader.cache_store) |store| {
        if (store.enabled) {
            writeWholeProgram(allocator, store, io, module, deps.items, &mc.program, &loader.type_inferencer) catch {};
        }
    }

    return runProgram(allocator, value_allocator, io, &mc.program, entry, filename);
}

/// 【whole-program cache】尝试从缓存加载合并后 Program。
/// 命中返回 owned Program（调用方 deinit），未命中返回 null。
fn tryLoadWholeProgram(
    allocator: std.mem.Allocator,
    store: *const cache_mod.CacheStore,
    io: std.Io,
    module: ast.Module,
    filename: []const u8,
) ?vm.chunk.Program {
    // 入口 src_path（stdlib 合成路径无缓存）
    const src_path = module.source_path orelse return null;
    if (std.mem.startsWith(u8, src_path, "<stdlib>")) return null;

    // stat 入口文件
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, src_path, .{}) catch return null;
    const key = cache_mod.CacheKey{
        .src_path = src_path,
        .mtime = @as(i128, stat.mtime.nanoseconds),
        .size = stat.size,
    };

    // 读 .bcc 文件
    const bcc_name = store.bccFilename(src_path) catch return null;
    defer allocator.free(bcc_name);

    var bcc = cache_mod.readBccFile(allocator, io, store, bcc_name) catch return null;
    defer bcc.deinit();

    // 命中校验：入口 mtime+size + 所有依赖 mtime+size
    // （usage/接口签名校验在 mtime+size 匹配时冗余——接口由源码决定，源码未变则接口未变）
    // 直接调用简化校验（跳过 usage 校验，whole-program 模式下依赖 mtime+size 足够）
    if (!cache_mod.isCacheHitWholeProgramSimple(&bcc, key, io)) {
        return null;
    }
    _ = filename;

    // 命中：从 BccFile 构造 Program（转移所有权）
    const program = cache_mod.bccFileToProgram(&bcc) catch return null;
    return program;
}

/// 【whole-program cache】序列化合并后 Program + 依赖列表 + usage 到 .bcc 文件。
fn writeWholeProgram(
    allocator: std.mem.Allocator,
    store: *const cache_mod.CacheStore,
    io: std.Io,
    module: ast.Module,
    deps: []const ast.Module,
    program: *const vm.chunk.Program,
    inferencer: *const type_check.TypeInferencer,
) !void {
    const src_path = module.source_path orelse return;
    if (std.mem.startsWith(u8, src_path, "<stdlib>")) return;

    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, src_path, .{}) catch return;

    // 构造 BccFile
    var bcc = cache_mod.BccFile.init(allocator, .{
        .magic = cache_mod.CACHE_MAGIC,
        .version = cache_mod.CACHE_VERSION,
        .src_mtime = @as(i128, stat.mtime.nanoseconds),
        .src_size = stat.size,
        .module_name = try allocator.dupe(u8, module.name),
        .src_path = try allocator.dupe(u8, src_path),
    });
    defer bcc.deinit();

    // 收集依赖列表（src_path + module_name + mtime + size）
    for (deps) |dep| {
        const dep_path = dep.source_path orelse continue;
        if (std.mem.startsWith(u8, dep_path, "<stdlib>")) continue; // stdlib 合成路径跳过
        const dep_stat = cwd.statFile(io, dep_path, .{}) catch continue;
        try bcc.deps.append(allocator, .{
            .src_path = try allocator.dupe(u8, dep_path),
            .module_name = try allocator.dupe(u8, dep.name),
            .mtime = @as(i128, dep_stat.mtime.nanoseconds),
            .size = dep_stat.size,
        });
    }

    // 提取入口模块接口（供下游模块缓存命中校验，whole-program 模式下冗余但保留）
    var iface = cache_mod.interface.extractInterface(allocator, &module, inferencer) catch return;
    defer iface.deinit();
    for (iface.symbols.items) |s| {
        try bcc.iface.addSymbol(s.name, s.kind, s.sig_hash);
    }

    // 复制 usage（type_check 期间记录的导入符号使用）
    // 注意：whole-program 模式下 usage 主要用于调试，命中校验依赖 mtime+size
    if (inferencer.symbol_usage) |tracker| {
        for (tracker.entries.items) |e| {
            try bcc.usage.record(e.module_path, e.symbol_name, e.kind, e.sig_hash);
        }
    }

    // 字节码部分：直接从 Program 转移（BccFile 持有引用，writeBytes 时序列化）
    bcc.entry = program.entry;
    bcc.global_count = program.global_count;
    bcc.globals_init = program.globals_init;
    // functions / Desc 表 / trait_order 借用 Program（writeBytes 只读，不转移所有权）
    bcc.functions = @constCast(program).functions;
    bcc.adt_ctors = @constCast(program).adt_ctors;
    bcc.record_shapes = @constCast(program).record_shapes;
    bcc.newtype_ctors = @constCast(program).newtype_ctors;
    bcc.error_ctors = @constCast(program).error_ctors;
    bcc.trait_methods = @constCast(program).trait_methods;
    bcc.trait_defaults = @constCast(program).trait_defaults;
    bcc.trait_parents = @constCast(program).trait_parents;
    bcc.trait_resolves = @constCast(program).trait_resolves;
    bcc.trait_order = @constCast(program).trait_order;
    // 清空 bcc 的这些字段标记，防止 bcc.deinit 释放它们（所有权仍属于 Program）
    // —— 但 BccFile.deinit 会调 freeAdtCtor 等！需用 flag 控制。
    // 简化：writeBytes 后立即清空 bcc 的字节码字段（避免 deinit 释放）
    defer {
        bcc.functions = .empty;
        bcc.adt_ctors = .empty;
        bcc.record_shapes = .empty;
        bcc.newtype_ctors = .empty;
        bcc.error_ctors = .empty;
        bcc.trait_methods = .empty;
        bcc.trait_defaults = .empty;
        bcc.trait_parents = .empty;
        bcc.trait_resolves = .empty;
        bcc.trait_order = .empty;
    }

    // reloc_table：whole-program cache 不需要重定位（已合并为绝对 idx）
    // 留空（bcc.reloc_table 已在 init 中初始化为空）

    const bcc_name = try store.bccFilename(src_path);
    defer allocator.free(bcc_name);
    cache_mod.writeBccFile(io, store, &bcc, bcc_name) catch return;
}

/// 【whole-program cache】执行已编译的 Program（缓存命中路径与正常路径共用）。
fn runProgram(
    allocator: std.mem.Allocator,
    value_allocator: std.mem.Allocator,
    io: std.Io,
    program: *vm.chunk.Program,
    entry: u16,
    filename: []const u8,
) VmOutcome {
    _ = allocator;
    // 执行 main
    var machine = vm.VM.initWithIo(value_allocator, io);
    defer machine.deinit();
    if (profiler_enabled) machine.setProfiler(&prof);
    prof.phaseBegin(.vm);
    const result = machine.call(program, entry, &.{}) catch |err| {
        prof.phaseEnd();
        const msg = machine.err_msg orelse runtimeErrorMessage(@as(anyerror, err), null);
        const loc: ?ast.SourceLocation = if (machine.err_loc.line > 0) machine.err_loc else null;
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        printRuntimeDiag(&stderr_writer.interface, filename, loc, "runtime panic", msg);
        stderr_writer.flush() catch {};
        return .failed;
    };
    prof.phaseEnd();

    // 检查是否有未捕获的 throw
    if (result == .throw_val) {
        const throw_val = result.throw_val.payload;
        switch (throw_val) {
            .err => |e| {
                std.debug.print("Uncaught error: {s}\n", .{e.message});
            },
            .ok => {},
        }
        result.release(value_allocator);
        return .failed;
    }

    result.release(value_allocator);
    return .ran_main;
}

/// executeSource 的结果。
/// - failed：出错（已报告），调用方以非零码退出。
/// - ran_main：VM 已编译并执行 main。
const ExecOutcome = enum { failed, ran_main };

fn executeSource(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    value_allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    filename: []const u8,
) ExecOutcome {
    // 词法分析
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    prof.phaseBegin(.lex);
    const tokens = lex.tokenize() catch |err| {
        prof.phaseEnd();
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: lexer error: {s}\n", .{ filename, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .failed;
    };
    prof.phaseEnd();
    defer allocator.free(tokens);

    // 语法分析 — 只支持模块（顶层声明）
    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();

    prof.phaseBegin(.parse);
    const module = p.parseModule(filename) catch {
        prof.phaseEnd();
        // 模块解析失败，报告错误
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        for (p.errors.items) |e| {
            stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
        }
        stderr_writer.flush() catch {};
        return .failed;
    };
    prof.phaseEnd();

    // 设置入口模块的源文件路径
    // 入口文件路径作为 source_path，使模块加载器能正确解析相对 use 依赖
    // （文档 §4.5）。否则从父目录运行 `glue dir/Main.glue` 时基目录误为 `.`。
    var entry_module = module;
    entry_module.source_path = filename;

    // VM-only路径：直接在字节码VM上编译并执行模块
    switch (tryRunOnVM(allocator, loader, value_allocator, io, entry_module, filename)) {
        .ran_main => return .ran_main,
        .failed => return .failed,
    }
}

fn setWindowsConsoleUtf8() void {
    const windows = std.os.windows;
    const CP_UTF8: windows.UINT = 65001;
    _ = SetConsoleOutputCP(CP_UTF8);
}

const SetConsoleOutputCP = @extern(
    *const fn (std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL,
    .{ .name = "SetConsoleOutputCP" },
);
