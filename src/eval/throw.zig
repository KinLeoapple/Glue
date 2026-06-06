//! Glue 语言 throw 运行时处理
//!
//! Phase 1 中 throw 处理相对简单：
//! - `throw` 语句创建错误值并通过 `error.ThrowValue` 传播
//! - `?`（传播操作符）检查 null/error 值并向上传播
//! - `ThrowSignal` 携带被抛出的值
//!
//! 实际的 throw/catch 控制流逻辑位于 eval.zig 中，
//! 利用 Zig 的 error union 类型实现非局部跳转。
//! 本文件为未来 try/catch 扩展预留。

const std = @import("std");
const value = @import("value");

/// 携带抛出值的信号
///
/// 当 `throw` 语句执行时，被抛出的值存储在此结构中，
/// 配合 Zig 的 `error.ThrowValue` 实现跨作用域传播。
pub const ThrowSignal = struct {
    value: value.Value,
};

/// 判断值是否可被 `?` 传播操作符向上传递。
///
/// - `null_val` → 可传播（T? 的 null）
/// - `throw_val` → 可传播（Throw<T, E> 的错误状态）
/// - 其他值 → 不可传播
/// 文档 2.3.9：`?` 不跨 Nullable 和 Throw 自动转换
pub fn isPropagable(val: value.Value) bool {
    return switch (val) {
        .null_val => true,
        .throw_val => true,
        else => false,
    };
}

/// 创建 Throw Ok 值
pub fn makeOk(allocator: std.mem.Allocator, val: value.Value) !value.Value {
    const val_ptr = try allocator.create(value.Value);
    val_ptr.* = val;
    const tv = try allocator.create(value.ThrowValue);
    tv.* = value.ThrowValue{ .ok = val_ptr };
    return value.Value{ .throw_val = tv };
}

/// 创建 Throw Error 值
pub fn makeErr(allocator: std.mem.Allocator, type_name: []const u8, message: []const u8) !value.Value {
    const tv = try allocator.create(value.ThrowValue);
    tv.* = value.ThrowValue{ .err = value.ErrorValue{
        .type_name = try allocator.dupe(u8, type_name),
        .message = try allocator.dupe(u8, message),
    } };
    return value.Value{ .throw_val = tv };
}
