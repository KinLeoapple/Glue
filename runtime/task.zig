//! Task 实现
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const Task = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Task {
        return Task{ .allocator = allocator };
    }

    pub fn deinit(self: *Task) void {
        _ = self;
    }
};
