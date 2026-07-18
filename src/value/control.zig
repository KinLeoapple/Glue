//! 控制流值类型模块
//!
//! 定义 Glue 语言中用于控制流跳转的值类型：
//! - ErrorValue 表示可恢复的错误对象（连续内存：header + type_name + message）
//! - ThrowValue 表示一次抛出操作的载荷（成功值或错误）

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
const value = @import("mod.zig");
const Value = value.Value;

/// 错误值，携带类型名和消息，用于错误传播
///
/// 连续内存布局：[ErrorValue header | type_name bytes | message bytes]
/// type_name 和 message 切片指向尾部连续区域，单次分配单次释放
pub const ErrorValue = struct {
    header: ObjHeader = .{ .type_tag = .error_val },
    type_name: []const u8,
    message: []const u8,
    is_error_subtype: bool = false,

    /// 释放错误值持有的堆内存
    /// type_name 和 message 是连续内存的一部分，由 errorValDeinit 中的 freeObj 统一释放
    pub fn deinit(self: *ErrorValue, tctx: *ThreadContext) void {
        _ = tctx;
        _ = self;
    }
};

/// 抛出值，封装一次控制流抛出的结果
pub const ThrowValue = struct {
    header: ObjHeader = .{ .type_tag = .throw_val },
    payload: Payload,

    /// 抛出载荷：成功值或错误指针
    pub const Payload = union(enum) {
        ok: Value,
        err: *ErrorValue,
    };

    /// 释放抛出值持有的资源，递减内部错误值的引用计数
    pub fn deinit(self: *ThrowValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            switch (self.payload) {
                .ok => |v| v.release(tctx),
                .err => |e| obj_header.release(&e.header, tctx),
            }
        }
    }
};

// ── deinit_table 注册函数 ──

pub fn errorValDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

pub fn throwValDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ThrowValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

/// 注册所有控制流类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.error_val, errorValDeinit);
    obj_header.registerDeinit(.throw_val, throwValDeinit);
}
