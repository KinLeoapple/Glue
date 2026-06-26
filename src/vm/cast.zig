//! Glue 字节码 VM — 类型转换（M3a）
//!
//! 重新实现 eval 的 castValue/castInteger/castFloat（纯 value→value，无 Evaluator 依赖）。
//! 溢出（narrowing out of range）返回 error.CastOverflow，VM 将其映射为运行期 panic。
//! 语义与 eval.castValue 一一对应（零漂移）：str→format；int/float 互转 clamp + type_tag。
//!
//! str 转换由 VM 调用方处理（需 format + allocator），本模块只管数值互转。

const std = @import("std");
const value = @import("value");

const Value = value.Value;
const IntValue = value.IntValue;
const FloatValue = value.FloatValue;
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

fn clampInt(val: u128, comptime T: type) CastError!u128 {
    if (@typeInfo(T).int.signedness == .signed) {
        const signed_val: i128 = @bitCast(val);
        if (signed_val < std.math.minInt(T) or signed_val > std.math.maxInt(T)) return error.CastOverflow;
    } else {
        if (val > std.math.maxInt(T)) return error.CastOverflow;
    }
    return val;
}

fn floatToInt(allocator: std.mem.Allocator, val: f128, comptime T: type) CastError!Value {
    if (std.math.isNan(val) or std.math.isInf(val)) return error.CastOverflow;
    const min: f128 = @floatFromInt(std.math.minInt(T));
    const max: f128 = @floatFromInt(std.math.maxInt(T));
    if (val < min or val > max) return error.CastOverflow;
    const int_val: T = @intFromFloat(val);
    const result: u128 = if (@typeInfo(T).int.signedness == .signed) @bitCast(@as(i128, int_val)) else @intCast(int_val);
    const tag: IntType = comptime switch (T) {
        i8 => .i8, i16 => .i16, i32 => .i32, i64 => .i64, i128 => .i128,
        u8 => .u8, u16 => .u16, u32 => .u32, u64 => .u64, u128 => .u128,
        else => unreachable,
    };
    return Value.fromInt(allocator, IntValue{ .value = result, .type_tag = tag });
}

/// 整数 → 目标类型（int 或 float）。镜像 eval.castInteger。
fn castInteger(allocator: std.mem.Allocator, val: u128, source_tag: IntType, type_name: []const u8) CastError!Value {
    const target = IntType.fromName(type_name) orelse {
        // 非整数类型名 → 尝试浮点。
        const signed_val: i128 = @bitCast(val);
        const fv: f128 = if (source_tag.isSigned()) @floatFromInt(signed_val) else @floatFromInt(val);
        if (std.mem.eql(u8, type_name, "f16")) return Value.fromFloatValue(allocator, .{ .value = fv, .type_tag = .f16 });
        if (std.mem.eql(u8, type_name, "f32")) return Value.fromFloatValue(allocator, .{ .value = fv, .type_tag = .f32 });
        if (std.mem.eql(u8, type_name, "f64")) return Value.fromFloatValue(allocator, .{ .value = fv, .type_tag = .f64 });
        if (std.mem.eql(u8, type_name, "f128")) return Value.fromFloatValue(allocator, .{ .value = fv, .type_tag = .f128 });
        return error.CastTypeMismatch;
    };
    const clamped: u128 = switch (target) {
        .i8 => try clampInt(val, i8),
        .i16 => try clampInt(val, i16),
        .i32 => try clampInt(val, i32),
        .i64 => try clampInt(val, i64),
        .i128 => try clampInt(val, i128),
        .u8 => try clampInt(val, u8),
        .u16 => try clampInt(val, u16),
        .u32 => try clampInt(val, u32),
        .u64 => try clampInt(val, u64),
        .u128 => try clampInt(val, u128),
    };
    return Value.fromInt(allocator, IntValue{ .value = clamped, .type_tag = target });
}

/// 浮点 → 目标类型。镜像 eval.castFloat。
fn castFloat(allocator: std.mem.Allocator, val: f128, type_name: []const u8) CastError!Value {
    if (std.mem.eql(u8, type_name, "i8")) return floatToInt(allocator, val, i8);
    if (std.mem.eql(u8, type_name, "i16")) return floatToInt(allocator, val, i16);
    if (std.mem.eql(u8, type_name, "i32")) return floatToInt(allocator, val, i32);
    if (std.mem.eql(u8, type_name, "i64")) return floatToInt(allocator, val, i64);
    if (std.mem.eql(u8, type_name, "i128")) return floatToInt(allocator, val, i128);
    if (std.mem.eql(u8, type_name, "u8")) return floatToInt(allocator, val, u8);
    if (std.mem.eql(u8, type_name, "u16")) return floatToInt(allocator, val, u16);
    if (std.mem.eql(u8, type_name, "u32")) return floatToInt(allocator, val, u32);
    if (std.mem.eql(u8, type_name, "u64")) return floatToInt(allocator, val, u64);
    if (std.mem.eql(u8, type_name, "u128")) return floatToInt(allocator, val, u128);
    if (std.mem.eql(u8, type_name, "f16")) return Value.fromFloat16(@floatCast(val));
    if (std.mem.eql(u8, type_name, "f32")) return Value.fromFloat32(@floatCast(val));
    if (std.mem.eql(u8, type_name, "f64")) return Value.fromFloat64(@floatCast(val));
    if (std.mem.eql(u8, type_name, "f128")) return try Value.fromFloat128(allocator, val);
    return error.CastTypeMismatch;
}

/// 数值类型转换（不含 str —— str 由 VM 用 format 处理）。
/// 输入 val 是栈上 owned 值；返回新值（owned）。基础值类型，调用方按需 release 输入。
pub fn castNumeric(allocator: std.mem.Allocator, val: Value, type_name: []const u8) CastError!Value {
    if (val.isInteger()) {
        const int_val = val.asInt();
        return castInteger(allocator, int_val.value, int_val.type_tag, type_name);
    }
    if (val.isFloat()) {
        const float_val = val.asFloatValue();
        return castFloat(allocator, float_val.value, type_name);
    }
    return error.CastTypeMismatch;
}
