//! 项目运行入口：定位项目、解析清单、读取入口源码并分派到运行模式。

const std = @import("std");
const module_loader = @import("module_loader");
const profiling = @import("profiler");
const debug_allocator = @import("debug_allocator");
const args_mod = @import("args.zig");
const manifest_mod = @import("manifest.zig");
const pipeline = @import("pipeline.zig");

const ExecOutcome = pipeline.ExecOutcome;

/// 执行 `glue run` / `glue debug`：定位项目、解析清单、读取入口源码并运行
pub fn runProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    profile_cfg: args_mod.ProfileConfig,
    diagnostic: bool,
) !void {
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
    try runMode(allocator, io, source, entry_path, profile_cfg, diagnostic);
}

/// 统一运行模式：普通模式用 c_allocator，诊断模式用 DebugAllocator 检测内存泄漏。
/// profile 状态通过 CliContext 显式传递给 executeSource，不再使用包级 var。
fn runMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    entry_path: []const u8,
    profile_cfg: args_mod.ProfileConfig,
    diagnostic: bool,
) !void {
    // 诊断模式：用 DebugAllocator 包装，defer 检查泄漏
    var dbg: ?debug_allocator.DebugAllocator = if (diagnostic) debug_allocator.DebugAllocator.init(io) else null;
    const exec_alloc = if (dbg != null) dbg.?.allocator() else allocator;
    defer if (dbg) |*d| {
        const leaked = d.deinit();
        if (leaked == .leak) {
            args_mod.printError(io, "[GLUE_GPA] LEAK detected\n", .{});
        } else {
            args_mod.printError(io, "[GLUE_GPA] clean (no leak / no double-free)\n", .{});
        }
    };

    var loader = module_loader.ModuleLoader.init(exec_alloc, io);
    defer loader.deinit();

    var prof = try profiling.GlobalProfiler.init(exec_alloc, profile_cfg.enabled, profile_cfg.interval_us, profile_cfg.json_path);
    defer prof.deinit();
    try prof.start();

    var cli_ctx = args_mod.CliContext{ .prof = &prof, .profile_enabled = profile_cfg.enabled };

    const RunCtx = struct {
        alloc: std.mem.Allocator,
        loader: *module_loader.ModuleLoader,
        cli_ctx: *args_mod.CliContext,
        io: std.Io,
        source: []const u8,
        entry_path: []const u8,
        outcome: ExecOutcome = .failed,
    };
    var rctx = RunCtx{
        .alloc = exec_alloc,
        .loader = &loader,
        .cli_ctx = &cli_ctx,
        .io = io,
        .source = source,
        .entry_path = entry_path,
    };

    if (std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 * 1024 }, struct {
        fn run(c: *RunCtx) void {
            c.outcome = pipeline.executeSource(c.alloc, c.loader, c.cli_ctx, c.io, c.source, c.entry_path);
        }
    }.run, .{&rctx})) |thread| {
        thread.join();
    } else |_| {
        rctx.outcome = pipeline.executeSource(exec_alloc, &loader, &cli_ctx, io, source, entry_path);
    }

    prof.dump(io);
    if (rctx.outcome == .failed) {
        loader.deinit();
        std.process.exit(1);
    }
}
