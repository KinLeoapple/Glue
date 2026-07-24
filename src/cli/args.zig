//! 命令行参数解析与用法说明。
//!
//! profile 选项在此解析为包级 var（过渡态），后续 Task 9 会收进 CliContext。

const std = @import("std");
const profiling = @import("profiler");

pub var profile_enabled: bool = false;
pub var profile_json_path: ?[]const u8 = null;
pub var profile_interval_us: u64 = 0;
pub var global_prof: profiling.GlobalProfiler = undefined;

/// 向标准错误流打印格式化错误信息
pub fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// 打印命令行用法说明
pub fn printUsage(io: std.Io) void {
    printError(io,
        \\Glue v0.1.0 — project-based language runtime
        \\
        \\Usage:
        \\  glue init [name]   Scaffold a new Glue project (in ./name or current dir)
        \\  glue run           Build and run the current project
        \\  glue debug         Run with diagnostics (memory checking + runtime trace)
        \\
        \\Options:
        \\  --profile              Enable profiling instrumentation
        \\  --profile-json=<path>  Write JSON report to file (implies --profile)
        \\  --profile-interval=<us> Sampling interval in microseconds (default: 1000)
        \\
    , .{});
}
