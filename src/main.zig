//! Glue 语言运行时入口
//!
//! 提供命令行工具，支持项目脚手架初始化（`glue init`）、
//! 构建并运行项目（`glue run`）、以及带内存检测与运行时追踪的诊断模式（`glue debug`）。
//! 运行流程：定位项目根 → 解析清单 → 读取入口源码 → 词法分析 → 语法分析 →
//! 语义分析（sema 产出图构建元信息）→ IR 构建 → IR 优化 → 引擎执行（Glue IR 共享内存图模型）。

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const module_loader = @import("module_loader");
const profiling = @import("profiler");
const debug_allocator = @import("debug_allocator");
const ir = @import("ir");
const engine = @import("engine");
const sema = @import("sema");
const analysis_db_mod = @import("analysis_db");
const std_embed = @import("std_embed");
const ast_rewrite = @import("parse/ast_rewrite.zig");
const manifest_mod = @import("cli/manifest.zig");
const Manifest = manifest_mod.Manifest;
const MANIFEST_NAME = manifest_mod.MANIFEST_NAME;
const DEFAULT_ENTRY = manifest_mod.DEFAULT_ENTRY;
const init_cmd = @import("cli/init.zig");
const args_mod = @import("cli/args.zig");
const pipeline = @import("cli/pipeline.zig");
const ExecOutcome = pipeline.ExecOutcome;
const printError = args_mod.printError;
const printUsage = args_mod.printUsage;

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
        try init_cmd.cmdInit(allocator, io, name);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "debug")) {
        for (args_slice[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--profile")) {
                args_mod.profile_enabled = true;
            } else if (std.mem.startsWith(u8, arg, "--profile-json=")) {
                args_mod.profile_enabled = true;
                args_mod.profile_json_path = arg["--profile-json=".len..];
            } else if (std.mem.startsWith(u8, arg, "--profile-interval=")) {
                args_mod.profile_interval_us = std.fmt.parseInt(u64, arg["--profile-interval=".len..], 10) catch {
                    printError(io, "error: invalid --profile-interval value\n\n", .{});
                    printUsage(io);
                    std.process.exit(1);
                };
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

/// 执行 `glue run` / `glue debug`：定位项目、解析清单、读取入口源码并运行
fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();
    const root = (try manifest_mod.findProjectRoot(allocator, io)) orelse {
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
    const manifest = manifest_mod.parseManifest(manifest_src);
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

/// 普通运行模式：使用 c_allocator 在大栈线程中执行源码
fn runNormal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    var loader = module_loader.ModuleLoader.init(allocator, io);
    defer loader.deinit();
    args_mod.global_prof = try profiling.GlobalProfiler.init(allocator, args_mod.profile_enabled, args_mod.profile_interval_us, args_mod.profile_json_path);
    defer args_mod.global_prof.deinit();
    try args_mod.global_prof.start();

    const Ctx = struct {
        allocator: std.mem.Allocator,
        loader: *module_loader.ModuleLoader,
        io: std.Io,
        source: []const u8,
        entry_path: []const u8,
        outcome: ExecOutcome = .failed,
    };
    var ctx = Ctx{
        .allocator = allocator,
        .loader = &loader,
        .io = io,
        .source = source,
        .entry_path = entry_path,
    };

    if (std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 * 1024 }, struct {
        fn run(c: *Ctx) void {
            c.outcome = pipeline.executeSource(c.allocator, c.loader, c.io, c.source, c.entry_path);
        }
    }.run, .{&ctx})) |thread| {
        thread.join();
    } else |_| {
        ctx.outcome = pipeline.executeSource(allocator, &loader, io, source, entry_path);
    }

    args_mod.global_prof.dump(io);
    if (ctx.outcome == .failed) {
        loader.deinit();
        std.process.exit(1);
    }
}

/// 诊断运行模式：使用调试分配器在大栈线程中检测内存泄漏与双重释放
fn runDiagnostic(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    _ = allocator;
    // 多线程模式：orbit async 会在独立线程中使用同一 allocator，
    // 必须启用 Mutex 保护 alloc_map，否则 HashMap 并发访问触发 pointer_stability 断言
    var dbg = debug_allocator.DebugAllocator.init(io);
    const dbg_alloc = dbg.allocator();
    {
        var loader = module_loader.ModuleLoader.init(dbg_alloc, io);
        defer loader.deinit();
        args_mod.global_prof = try profiling.GlobalProfiler.init(dbg_alloc, args_mod.profile_enabled, args_mod.profile_interval_us, args_mod.profile_json_path);
        defer args_mod.global_prof.deinit();
        try args_mod.global_prof.start();

        const Ctx = struct {
            allocator: std.mem.Allocator,
            loader: *module_loader.ModuleLoader,
            io: std.Io,
            source: []const u8,
            entry_path: []const u8,
            outcome: ExecOutcome = .failed,
        };
        var ctx = Ctx{
            .allocator = dbg_alloc,
            .loader = &loader,
            .io = io,
            .source = source,
            .entry_path = entry_path,
        };

        if (std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 * 1024 }, struct {
            fn run(c: *Ctx) void {
                c.outcome = pipeline.executeSource(c.allocator, c.loader, c.io, c.source, c.entry_path);
            }
        }.run, .{&ctx})) |thread| {
            thread.join();
        } else |_| {
            ctx.outcome = pipeline.executeSource(dbg_alloc, &loader, io, source, entry_path);
        }

        args_mod.global_prof.dump(io);
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
