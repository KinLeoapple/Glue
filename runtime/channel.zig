//! Channel 实现
//!
//! Phase 4 实现：并发原语
//! 文档 §3.5: 通过 channel 通信，不通过共享内存通信

const std = @import("std");

pub const Channel = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Channel {
        return Channel{ .allocator = allocator };
    }

    pub fn deinit(self: *Channel) void {
        _ = self;
    }
};
