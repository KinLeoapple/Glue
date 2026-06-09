//! Work-stealing 调度器
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{ .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        _ = self;
    }
};
