//! Per-heap GC
//!
//! Phase 4 实现：并发原语
//! 文档 §5.1: 每个协程拥有独立的 GC heap
//! 当前实现：使用 std.mem.Allocator 包装，提供 GC 接口但不做真正回收

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
