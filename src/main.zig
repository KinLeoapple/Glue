//! Glue 语言运行时入口
//!
//! 提供命令行工具，支持项目脚手架初始化（`glue init`）、
//! 构建并运行项目（`glue run`）、以及带内存检测与运行时追踪的诊断模式（`glue debug`）。

const std = @import("std");
const cli = @import("cli/mod.zig");

pub fn main(init: std.process.Init) !void {
    try cli.main(init);
}
