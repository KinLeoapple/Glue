//! 数值类型转换实现。
//!
//! 提供整数与浮点数之间的相互转换，支持根据目标类型名
//! 执行截断、拓宽及精度调整，供 coerce/cast 指令调用。

const std = @import("std");
const value = @import("value");

const Value = value.Value;
const Int = value.Int;
const Float = value.Float;
const IntType = value.IntType;
const FloatType = value.FloatType;

/// 类型转换可能产生的错误。
pub const CastError = error{
    CastOverflow,
    CastTypeMismatch,
    OutOfMemory,
};

/// 将整数值转换为目标类型名指定的整数或浮点类型。
fn castInteger(allocator: std.mem.Allocator, val: Int, type_name: []const u8) CastError!Value {
    _ = allocator;
    if (IntType.fromName(type_name)) |target| {
        return Value.fromInt(val.coerceTo(target) orelse return error.CastOverflow);
    }
    if (FloatType.fromName(type_name)) |target| {
        return Value.fromFloat(Float.fromInt(target, val));
    }
    return error.CastTypeMismatch;
}

/// 将浮点值转换为目标类型名指定的整数或浮点类型。
fn castFloat(allocator: std.mem.Allocator, val: Float, type_name: []const u8) CastError!Value {
    _ = allocator;
    if (IntType.fromName(type_name)) |target| {
        const int_val = val.toInt(target) catch return error.CastOverflow;
        return Value.fromInt(int_val);
    }
    if (FloatType.fromName(type_name)) |target| {
        return Value.fromFloat(val.toFloatType(target));
    }
    return error.CastTypeMismatch;
}

/// 对数值型 Value 执行类型转换，非数值返回 CastTypeMismatch。
pub fn castNumeric(allocator: std.mem.Allocator, val: Value, type_name: []const u8) CastError!Value {
    if (val.isInteger()) {
        return castInteger(allocator, val.asInt(), type_name);
    }
    if (val.isFloat()) {
        return castFloat(allocator, val.asFloat(), type_name);
    }
    return error.CastTypeMismatch;
}
