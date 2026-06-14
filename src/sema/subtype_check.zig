//! 子类型检查
//!
//! Phase 3 实现在 type_check.zig 的 TypeInferencer.isSubtype() 方法中。
//! 此模块保留为未来独立子类型检查器的入口点。

const std = @import("std");

pub const SubtypeChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SubtypeChecker {
        return SubtypeChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *SubtypeChecker) void {
        _ = self;
    }
};
