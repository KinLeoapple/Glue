//! 泛型运算系统：comptime 特化的标量运算
//!
//! 所有运算通过 @bitCast 将 [N]u8 转为原生类型执行，
//! 编译期消除 @bitCast，运行时零开销

const std = @import("std");
const scalar = @import("scalar.zig");
const ScalarTag = scalar.ScalarTag;
const NativeType = scalar.NativeType;
const byteWidth = scalar.byteWidth;
const ByteArray = scalar.ByteArray;

/// 从 [N]u8 提取原生值（@bitCast 编译期消除）
pub inline fn extract(comptime tag: ScalarTag, bytes: ByteArray(tag)) NativeType(tag) {
    return @bitCast(bytes);
}

/// 将原生值打包为 [N]u8（@bitCast 编译期消除）
pub inline fn pack(comptime tag: ScalarTag, val: NativeType(tag)) ByteArray(tag) {
    return @bitCast(val);
}

// ── 算术运算 ──

/// 泛型加法
pub fn add(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const bv: T = @bitCast(b);
    const result = switch (@typeInfo(T)) {
        .int => av +% bv,
        .float => av + bv,
        .bool => av or bv,
        else => @compileError("unsupported type for add"),
    };
    return @bitCast(result);
}

/// 泛型减法
pub fn sub(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const bv: T = @bitCast(b);
    const result = switch (@typeInfo(T)) {
        .int => av -% bv,
        .float => av - bv,
        .bool => av and !bv,
        else => @compileError("unsupported type for sub"),
    };
    return @bitCast(result);
}

/// 泛型乘法
pub fn mul(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const bv: T = @bitCast(b);
    const result = switch (@typeInfo(T)) {
        .int => av *% bv,
        .float => av * bv,
        .bool => av and bv,
        else => @compileError("unsupported type for mul"),
    };
    return @bitCast(result);
}

/// 泛型除法（整数除零返回 null，浮点除零按 IEEE 754 处理）
pub fn div(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ?ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const bv: T = @bitCast(b);
    const result = switch (@typeInfo(T)) {
        .int => if (bv == 0) null else @as(?T, @divTrunc(av, bv)),
        .float => @as(?T, av / bv),
        else => @compileError("unsupported type for div"),
    };
    return if (result) |r| @bitCast(r) else null;
}

/// 泛型取模（整数专用，除零返回 null）
pub fn mod(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ?ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const bv: T = @bitCast(b);
    const result = switch (@typeInfo(T)) {
        .int => if (bv == 0) null else @as(?T, @rem(av, bv)),
        .float => @as(?T, @mod(av, bv)),
        else => @compileError("unsupported type for mod"),
    };
    return if (result) |r| @bitCast(r) else null;
}

/// 泛型取负
pub fn neg(comptime tag: ScalarTag, a: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    const av: T = @bitCast(a);
    const result = switch (@typeInfo(T)) {
        .int => -%av,
        .float => -av,
        else => @compileError("unsupported type for neg"),
    };
    return @bitCast(result);
}

// ── 位运算（整数专用）──

pub fn bitAnd(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    return @bitCast(@as(T, @bitCast(a)) & @as(T, @bitCast(b)));
}

pub fn bitOr(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    return @bitCast(@as(T, @bitCast(a)) | @as(T, @bitCast(b)));
}

pub fn bitXor(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    return @bitCast(@as(T, @bitCast(a)) ^ @as(T, @bitCast(b)));
}

pub fn bitNot(comptime tag: ScalarTag, a: ByteArray(tag)) ByteArray(tag) {
    const T = NativeType(tag);
    return @bitCast(~@as(T, @bitCast(a)));
}

// ── 比较运算（返回 bool）──

pub fn eq(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) == @as(T, @bitCast(b));
}

pub fn ne(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) != @as(T, @bitCast(b));
}

pub fn lt(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) < @as(T, @bitCast(b));
}

pub fn gt(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) > @as(T, @bitCast(b));
}

pub fn le(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) <= @as(T, @bitCast(b));
}

pub fn ge(comptime tag: ScalarTag, a: ByteArray(tag), b: ByteArray(tag)) bool {
    const T = NativeType(tag);
    return @as(T, @bitCast(a)) >= @as(T, @bitCast(b));
}
