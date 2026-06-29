//! 控制流类型装箱 struct——ErrorValue/ThrowValue
//!
//! 每个 struct 首字段 rc:u32，Value union 持 *T 指针。
//! ErrorValue.type_name/message 假设字面量（与旧 value.zig 一致，deinit 不释放）。
//! ThrowValue.payload.err 用 *ErrorValue 统一装箱语义。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;

/// 错误值：Error(T: message)
pub const ErrorValue = struct {
    rc: u32 = 1,
    type_name: []const u8,
    message: []const u8,
    is_error_subtype: bool = false,

    pub fn deinit(self: *ErrorValue, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // type_name/message 假设字面量（与旧 value.zig 一致）
    }
};

/// 抛出值：ok(正常值) 或 err(错误值)
pub const ThrowValue = struct {
    rc: u32 = 1,
    payload: union(enum) {
        ok: Value,
        err: *ErrorValue,
    },

    pub fn deinit(self: *ThrowValue, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .ok => |v| v.release(allocator),
            .err => |e| {
                if (e.rc > 1) {
                    e.rc -= 1;
                } else {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
            },
        }
    }
};
