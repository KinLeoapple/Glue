//! Arc<T> 原子引用计数
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const Arc = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Arc {
        return Arc{ .allocator = allocator };
    }

    pub fn deinit(self: *Arc) void {
        _ = self;
    }
};
