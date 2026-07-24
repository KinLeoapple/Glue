//! CLI 子系统入口：命令行参数解析与子命令分派。
//!
//! 分派到三个子命令：
//! - `glue init [name]`：脚手架化新项目
//! - `glue run`：构建并运行当前项目
//! - `glue debug`：带内存检测与运行时追踪的诊断模式

const std = @import("std");
const builtin = @import("builtin");
const args_mod = @import("args.zig");
const init_cmd = @import("init.zig");
const run_cmd = @import("run.zig");

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
