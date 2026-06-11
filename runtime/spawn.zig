//! Spawn<T> 实现（基于 Zio Task）
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const Spawn = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Spawn {
        return Spawn{ .allocator = allocator };
    }

    pub fn deinit(self: *Spawn) void {
        _ = self;
    }
};
