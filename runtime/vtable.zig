//! 一等 Trait 值 vtable 支持
//!
//! Phase 4 实现：并发原语

const std = @import("std");

pub const VTable = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VTable {
        return VTable{ .allocator = allocator };
    }

    pub fn deinit(self: *VTable) void {
        _ = self;
    }
};
