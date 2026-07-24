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
const run_cmd = @import("cli/run.zig");
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
        try run_cmd.runProject(allocator, io, std.mem.eql(u8, cmd, "debug"));
    } else {
        printError(io, "error: unknown command '{s}'\n\n", .{cmd});
        printUsage(io);
        std.process.exit(1);
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
