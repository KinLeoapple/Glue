//! 项目运行入口：定位项目、解析清单、读取入口源码并分派到运行模式。

const std = @import("std");
const builtin = @import("builtin");
const module_loader = @import("module_loader");
const profiling = @import("profiler");
const debug_allocator = @import("debug_allocator");
const args_mod = @import("args.zig");
const manifest_mod = @import("manifest.zig");
const pipeline = @import("pipeline.zig");

const ExecOutcome = pipeline.ExecOutcome;

/// 执行 `glue run` / `glue debug`：定位项目、解析清单、读取入口源码并运行
pub fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();
    const root = (try manifest_mod.findProjectRoot(allocator, io)) orelse {
        args_mod.printError(io, "error: not a Glue project (no {s} found); run 'glue init' first\n", .{manifest_mod.MANIFEST_NAME});
        std.process.exit(1);
    };
    defer allocator.free(root);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest_mod.MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const manifest_src = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| {
        args_mod.printError(io, "error: could not read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest_src);
    const manifest = manifest_mod.parseManifest(manifest_src);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest.entry });
    defer allocator.free(entry_path);
    const source = cwd.readFileAlloc(io, entry_path, allocator, .unlimited) catch |err| {
        args_mod.printError(io, "error: could not read entry '{s}': {s}\n", .{ entry_path, @errorName(err) });
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
        args_mod.printError(io, "[GLUE_GPA] LEAK detected\n", .{});
    } else {
        args_mod.printError(io, "[GLUE_GPA] clean (no leak / no double-free)\n", .{});
    }
}
