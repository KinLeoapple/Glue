//! GADT 类型精化
//!
//! Phase 10+ 实现：广义代数数据类型、模式匹配中的类型精化

const std = @import("std");
const ast = @import("ast");

pub const GadtChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GadtChecker {
        return GadtChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *GadtChecker) void {
        _ = self;
    }
};
