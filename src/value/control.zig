//! 控制流值类型模块
//!
//! 定义 Glue 语言中用于控制流跳转的值类型：
//! - ErrorValue 表示可恢复的错误对象
//! - ThrowValue 表示一次抛出操作的载荷（成功值或错误）

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;

/// 错误值，携带类型名和消息，用于错误传播
pub const ErrorValue = struct {
rc: u32 = 1,
type_name: []const u8,
message: []const u8,
is_error_subtype: bool = false,

/// 释放错误值持有的堆内存
pub fn deinit(self: *ErrorValue, allocator: std.mem.Allocator) void {
allocator.free(self.type_name);
allocator.free(self.message);
}
};

/// 抛出值，封装一次控制流抛出的结果
pub const ThrowValue = struct {
rc: u32 = 1,
payload: union(enum) {
ok: Value,
err: *ErrorValue,
},

/// 释放抛出值持有的资源，递减内部错误值的引用计数
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
