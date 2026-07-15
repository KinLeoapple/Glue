//! Glue 语言运行时入口
//!
//! 提供命令行工具，支持项目脚手架初始化（`glue init`）、
//! 构建并运行项目（`glue run`）、以及带内存检测与运行时追踪的诊断模式（`glue debug`）。
//! 运行流程：定位项目根 → 解析清单 → 读取入口源码 → 词法分析 → 语法分析 →
//! 类型检查，执行后端由 LFE 层流图引擎接管。

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const module_loader = @import("module_loader");
const profiler = @import("profiler");
const debug_allocator = @import("debug_allocator");
const lfe = @import("lfe");

/// 项目清单：名称、版本与入口文件路径
const Manifest = struct {
    name: []const u8,
    version: []const u8,
    entry: []const u8,
};

const MANIFEST_NAME = "glue.toml";
const DEFAULT_ENTRY = "src/Main.glue";

var profiler_enabled: bool = false;
var prof: profiler.Profiler = .{};

/// 向标准错误流打印格式化错误信息
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// 打印命令行用法说明
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
        \\  --profile          Dump full pipeline profile (phases + memory) after run
        \\
    , .{});
}

/// 程序入口：解析命令行参数并分派到对应子命令
pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        setWindowsConsoleUtf8();
    }
    const allocator = std.heap.c_allocator;
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
        for (args_slice[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--profile")) {
                profiler_enabled = true;
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

/// 从当前目录向上逐级查找包含清单文件的目录，返回其相对前缀
fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var level: usize = 0;
    while (level < 64) : (level += 1) {
        const candidate = if (prefix.items.len == 0)
            try allocator.dupe(u8, MANIFEST_NAME)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix.items, MANIFEST_NAME });
        defer allocator.free(candidate);
        if (cwd.access(io, candidate, .{})) {
            return try allocator.dupe(u8, prefix.items);
        } else |_| {}
        try prefix.appendSlice(allocator, ".." ++ [_]u8{std.fs.path.sep});
    }
    return null;
}

/// 解析清单文件内容（简化的 key = value 格式），返回 Manifest
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

/// 目标目录状态：不存在、空、非空、已是项目
const DirState = enum {
    missing,
    empty,
    non_empty,
    is_project,
};

/// 检查目标目录的状态
fn checkDirState(io: std.Io, path: []const u8) DirState {
    const cwd = std.Io.Dir.cwd();
    const open_path = if (path.len == 0) "." else path;
    var dir = cwd.openDir(io, open_path, .{ .iterate = true }) catch {
        return .missing;
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

/// 执行 `glue init` 子命令：在指定目录（或当前目录）脚手架化新项目
fn cmdInit(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dir_prefix = if (name) |n|
        try std.fmt.allocPrint(allocator, "{s}{c}", .{ n, std.fs.path.sep })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dir_prefix);
    const proj_name = name orelse "app";
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
        .missing, .empty => {},
    }
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const src_dir = try std.fmt.allocPrint(allocator, "{s}src", .{dir_prefix});
    defer allocator.free(src_dir);
    cwd.createDirPath(io, src_dir) catch |err| {
        printError(io, "error: could not create directory '{s}': {s}\n", .{ src_dir, @errorName(err) });
        std.process.exit(1);
    };
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

/// 执行 `glue run` / `glue debug`：定位项目、解析清单、读取入口源码并运行
fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();
    const root = (try findProjectRoot(allocator, io)) orelse {
        printError(io, "error: not a Glue project (no {s} found); run 'glue init' first\n", .{MANIFEST_NAME});
        std.process.exit(1);
    };
    defer allocator.free(root);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const manifest_src = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| {
        printError(io, "error: could not read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest_src);
    const manifest = parseManifest(manifest_src);
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

/// 源码执行结果：成功或失败
const ExecOutcome = enum { failed, ran_main };

/// 完整执行管线：词法分析 → 语法分析 → 类型检查 → LFE 层流执行
fn executeSource(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    io: std.Io,
    source: []const u8,
    filename: []const u8,
) ExecOutcome {
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
    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();
    prof.phaseBegin(.parse);
    const module = p.parseModule(filename) catch {
        prof.phaseEnd();
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        for (p.errors.items) |e| {
            stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
        }
        stderr_writer.flush() catch {};
        return .failed;
    };
    prof.phaseEnd();
    var entry_module = module;
    entry_module.source_path = filename;

    // 类型检查阶段
    prof.phaseBegin(.type_check);
    loader.prepareModule(entry_module) catch |err| switch (err) {
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

    // LFE 层流执行阶段
    prof.phaseBegin(.lfe_compile);
    var graph = lfe.LaminarCompiler.compile(allocator, entry_module) catch |err| {
        prof.phaseEnd();
        printError(io, "{s}: LFE compile error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    defer graph.deinit(allocator);
    prof.phaseEnd();

    // LFE 优化阶段（常量折叠 + 死通道消除 + 层融合 + 槽位复用）
    prof.phaseBegin(.lfe_optimize);
    var optimized = lfe.Optimizer.optimize(allocator, &graph) catch |err| {
        prof.phaseEnd();
        printError(io, "{s}: LFE optimize error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    defer if (optimized.arena == null) {
        allocator.free(optimized.laminas);
        allocator.free(optimized.channel_metas);
        if (optimized.input_channels.len > 0) allocator.free(optimized.input_channels);
    };
    prof.phaseEnd();

    prof.phaseBegin(.lfe_run);
    if (optimized.subgraphs.len > 0) {
        // 并发模式：使用 M:N 协程调度器
        var sched = lfe.Scheduler.init(allocator, std.Thread.getCpuCount() catch 4, 1);
        sched.start() catch |err| {
            prof.phaseEnd();
            printError(io, "{s}: LFE scheduler start error: {s}\n", .{ filename, @errorName(err) });
            return .failed;
        };
        defer sched.stop();

        // 创建 main task
        const main_task = lfe.LfeTask.create(allocator, &sched, &optimized, 1) catch |err| {
            prof.phaseEnd();
            printError(io, "{s}: LFE task create error: {s}\n", .{ filename, @errorName(err) });
            return .failed;
        };
        _ = sched.active_tasks.fetchAdd(1, .monotonic);
        sched.enqueue(main_task);

        // 等待 main task 完成
        sched.waitFor(main_task);
        sched.stop();
    } else {
        // 纯顺序模式：直接用 Engine
        var eng = lfe.Engine.init(allocator, &optimized, 1) catch |err| {
            prof.phaseEnd();
            printError(io, "{s}: LFE engine init error: {s}\n", .{ filename, @errorName(err) });
            return .failed;
        };
        defer eng.deinit();

        eng.run() catch |err| {
            prof.phaseEnd();
            printError(io, "{s}: LFE execution error: {s}\n", .{ filename, @errorName(err) });
            return .failed;
        };
    }
    prof.phaseEnd();

    return .ran_main;
}

/// 普通运行模式：使用 c_allocator 执行源码
fn runNormal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    var loader = module_loader.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    prof = profiler.Profiler.init(profiler_enabled, io);
    const outcome = executeSource(allocator, &loader, io, source, entry_path);
    if (profiler_enabled) {
        prof.dump(io);
    }
    if (outcome == .failed) {
        loader.deinit();
        std.process.exit(1);
    }
}

/// 诊断运行模式：使用调试分配器检测内存泄漏与双重释放
fn runDiagnostic(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    _ = allocator;
    var dbg = debug_allocator.DebugAllocator.initSingleThreaded();
    const dbg_alloc = dbg.allocator();
    {
        var loader = module_loader.ModuleLoader.init(dbg_alloc, io);
        defer loader.deinit();
        prof = profiler.Profiler.init(profiler_enabled, io);
        _ = executeSource(dbg_alloc, &loader, io, source, entry_path);
        if (profiler_enabled) {
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

/// 在 Windows 上将控制台输出代码页设置为 UTF-8
fn setWindowsConsoleUtf8() void {
    const windows = std.os.windows;
    const CP_UTF8: windows.UINT = 65001;
    _ = SetConsoleOutputCP(CP_UTF8);
}

const SetConsoleOutputCP = @extern(
    *const fn (std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL,
    .{ .name = "SetConsoleOutputCP" },
);
