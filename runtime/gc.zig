//! Per-heap GC（基于 ArenaAllocator）
//!
//! Phase 4 实现：并发原语
//! 文档 §5.1: 每个协程拥有独立的 GC heap
//! 当前实现：每个 spawn 协程使用独立 ArenaAllocator
//! 协程结束时 Arena 整体释放，零 GC 暂停
//! 未来可替换为真正的标记-清除 GC

const std = @import("std");

pub const GarbageCollector = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) GarbageCollector {
        return GarbageCollector{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *GarbageCollector) void {
        self.arena.deinit();
    }

    /// 获取用于分配的 allocator
    pub fn allocator(self: *GarbageCollector) std.mem.Allocator {
        return self.arena.allocator();
    }
};
