//! Glue 语言模块求值
//!
//! Phase 1: 简单的顶层声明求值
//! - fun 声明：创建闭包并绑定到全局环境
//! - 其他声明类型暂为占位

const std = @import("std");
const value = @import("value");
const env = @import("env");
const ast = @import("ast");

/// 模块求值结果
pub const ModuleResult = struct {
    success: bool,
    error_message: ?[]const u8 = null,
};
