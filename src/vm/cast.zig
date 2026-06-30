//! Glue 字节码 VM — 类型转换（M3a）
//!
//! 重新实现 eval 的 castValue/castInteger/castFloat（纯 value→value，无 Evaluator 依赖）。
//! 溢出（narrowing out of range）返回 error.CastOverflow，VM 将其映射为运行期 panic。
//! 语义与 eval.castValue 一一对应（零漂移）：str→format；int/float 互转 clamp + type_tag。
//!
//! str 转换由 VM 调用方处理（需 format + allocator），本模块只管数值互转。
//!
//! 新 Value API：Int/Float 内联 union，IntType/FloatType 用 fromName 查表，
//! Float.toInt/toFloatType 提供正确精度转换，f8 自动支持。

const std = @import("std");
const value = @import("value");

const Value = value.Value;
const Int = value.Int;
const Float = value.Float;
const IntType = value.IntType;
const FloatType = value.FloatType;

pub const CastError = error{
    /// narrowing 超出目标类型范围（对齐 eval gluePanic "arithmetic overflow"）。
    CastOverflow,
    /// 不支持的源/目标类型组合（对齐 eval error.TypeMismatch）。
    CastTypeMismatch,
    /// 内存分配失败
    OutOfMemory,
};

/// 整数 → 目标类型（int 或 float）。镜像 eval.castInteger。
/// 全软件：int→int 用 coerceTo（字节级范围检查）；int→float 用 Float.fromInt（不丢精度）。
fn castInteger(allocator: std.mem.Allocator, val: Int, type_name: []const u8) CastError!Value {
    _ = allocator;

    // 整数目标：字节级类型转换，溢出返回 null
    if (IntType.fromName(type_name)) |target| {
        return Value.fromInt(val.coerceTo(target) orelse return error.CastOverflow);
    }

    // 浮点目标：软件 Int→Float 转换（全精度，含 f8）
    if (FloatType.fromName(type_name)) |target| {
        return Value.fromFloat(Float.fromInt(target, val));
    }

    return error.CastTypeMismatch;
}

/// 浮点 → 目标类型。镜像 eval.castFloat。
fn castFloat(allocator: std.mem.Allocator, val: Float, type_name: []const u8) CastError!Value {
    _ = allocator;

    // 整数目标：Float.toInt（向零截断，NaN/Inf/溢出 → error.Overflow）
    if (IntType.fromName(type_name)) |target| {
        const int_val = val.toInt(target) catch return error.CastOverflow;
        return Value.fromInt(int_val);
    }

    // 浮点目标：toFloatType（正确精度转换，含 f8）
    if (FloatType.fromName(type_name)) |target| {
        return Value.fromFloat(val.toFloatType(target));
    }

    return error.CastTypeMismatch;
}

/// 数值类型转换（不含 str —— str 由 VM 用 format 处理）。
/// 输入 val 是栈上 owned 值；返回新值（owned）。基础值类型，调用方按需 release 输入。
pub fn castNumeric(allocator: std.mem.Allocator, val: Value, type_name: []const u8) CastError!Value {
    if (val.isInteger()) {
        return castInteger(allocator, val.asInt(), type_name);
    }
    if (val.isFloat()) {
        return castFloat(allocator, val.asFloat(), type_name);
    }
    return error.CastTypeMismatch;
}
