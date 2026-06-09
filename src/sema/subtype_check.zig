//! 子类型检查
//!
//! Phase 7+ 实现：结构化子类型、Trait 子类型关系

const std = @import("std");
const ast = @import("ast");

pub const SubtypeChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SubtypeChecker {
        return SubtypeChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *SubtypeChecker) void {
        _ = self;
    }
};
