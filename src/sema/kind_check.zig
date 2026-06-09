//! Kind 检查与推断
//!
//! Phase 5+ 实现：Kind 系统 (*, * -> *, * -> * -> * 等)

const std = @import("std");
const ast = @import("ast");

pub const KindChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KindChecker {
        return KindChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *KindChecker) void {
        _ = self;
    }
};
