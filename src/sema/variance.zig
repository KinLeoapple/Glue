//! 变异性推导
//!
//! Phase 8+ 实现：类型参数的协变、逆变、不变推导

const std = @import("std");
const ast = @import("ast");

pub const VarianceDeriver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VarianceDeriver {
        return VarianceDeriver{ .allocator = allocator };
    }

    pub fn deinit(self: *VarianceDeriver) void {
        _ = self;
    }
};
