//! Throw 类型检查
//!
//! Phase 6+ 实现：Throw<T, E> 效果系统与错误传播检查

const std = @import("std");
const ast = @import("ast");

pub const ThrowChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ThrowChecker {
        return ThrowChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *ThrowChecker) void {
        _ = self;
    }
};
