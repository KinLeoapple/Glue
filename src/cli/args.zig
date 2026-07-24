//! 命令行参数解析与用法说明。

const std = @import("std");
const profiling = @import("profiler");

/// profile 选项的解析结果，由 mod.main 收集后传给 run/runMode。
pub const ProfileConfig = struct {
    enabled: bool = false,
    json_path: ?[]const u8 = null,
    interval_us: u64 = 0,
};

/// 运行期上下文：显式传递 GlobalProfiler 引用与 profile 开关，替代包级 var。
pub const CliContext = struct {
    prof: *profiling.GlobalProfiler,
    profile_enabled: bool,
};

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
