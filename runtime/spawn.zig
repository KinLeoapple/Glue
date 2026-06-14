//! Spawn<T> 实现（基于 std.Thread）
//!
//! Phase 4 实现：并发原语
//! 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费

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
