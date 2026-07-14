//! 控制流值类型模块
//!
//! 定义 Glue 语言中用于控制流跳转的值类型：
//! - ErrorValue 表示可恢复的错误对象
//! - ThrowValue 表示一次抛出操作的载荷（成功值或错误）

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const value = @import("mod.zig");
const Value = value.Value;

/// 错误值，携带类型名和消息，用于错误传播
pub const ErrorValue = struct {
    header: ObjHeader = .{ .type_tag = .error_val },
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
    header: ObjHeader = .{ .type_tag = .throw_val },
    payload: union(enum) {
        ok: Value,
        err: *ErrorValue,
    },

    /// 释放抛出值持有的资源，递减内部错误值的引用计数
    pub fn deinit(self: *ThrowValue, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .ok => |v| v.release(allocator),
            .err => |e| obj_header.release(&e.header, allocator),
        }
    }
};

// ── deinit_table 注册函数 ──

pub fn errorValDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

pub fn throwValDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *ThrowValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

/// 注册所有控制流类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.error_val, errorValDeinit);
    obj_header.registerDeinit(.throw_val, throwValDeinit);
}
