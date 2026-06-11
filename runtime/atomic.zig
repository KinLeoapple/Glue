//! Atomic<T> 原子操作
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const Atomic = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Atomic {
        return Atomic{ .allocator = allocator };
    }

    pub fn deinit(self: *Atomic) void {
        _ = self;
    }
};
