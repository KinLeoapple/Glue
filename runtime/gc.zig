//! Per-heap GC
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GarbageCollector {
        return GarbageCollector{ .allocator = allocator };
    }

    pub fn deinit(self: *GarbageCollector) void {
        _ = self;
    }
};
