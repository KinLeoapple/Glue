//! SIMD 批量运算：使用 @Vector 自动向量化
//!
//! 按类型宽度自动选择最优向量宽度，128 位 SIMD 通道

const std = @import("std");
const scalar = @import("scalar.zig");

/// 批量加法：自动按类型宽度选择 SIMD 向量宽度
pub fn batchAdd(comptime T: type, dst: []T, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);
    const Vec = @Vector(lanes, T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        dst[i..][0..lanes].* = @as([lanes]T,
            @as(Vec, a[i..][0..lanes].*) +% @as(Vec, b[i..][0..lanes].*)
        );
    }
    while (i < a.len) : (i += 1) dst[i] = a[i] +% b[i];
}

/// 批量减法
pub fn batchSub(comptime T: type, dst: []T, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);
    const Vec = @Vector(lanes, T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        dst[i..][0..lanes].* = @as([lanes]T,
            @as(Vec, a[i..][0..lanes].*) -% @as(Vec, b[i..][0..lanes].*)
        );
    }
    while (i < a.len) : (i += 1) dst[i] = a[i] -% b[i];
}

/// 批量乘法
pub fn batchMul(comptime T: type, dst: []T, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);
    const Vec = @Vector(lanes, T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        dst[i..][0..lanes].* = @as([lanes]T,
            @as(Vec, a[i..][0..lanes].*) *% @as(Vec, b[i..][0..lanes].*)
        );
    }
    while (i < a.len) : (i += 1) dst[i] = a[i] *% b[i];
}

/// 批量比较（输出 mask 字节数组）
pub fn batchEq(comptime T: type, dst: []u8, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);
    const Vec = @Vector(lanes, T);
    const MaskVec = @Vector(lanes, bool);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const mask: MaskVec = @as(Vec, a[i..][0..lanes].*) == @as(Vec, b[i..][0..lanes].*);
        comptime var j: usize = 0;
        inline while (j < lanes) : (j += 1) {
            dst[i + j] = if (mask[j]) 1 else 0;
        }
    }
    while (i < a.len) : (i += 1) dst[i] = if (a[i] == b[i]) 1 else 0;
}

/// 批量小于比较
pub fn batchLt(comptime T: type, dst: []u8, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);
    const Vec = @Vector(lanes, T);
    const MaskVec = @Vector(lanes, bool);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const mask: MaskVec = @as(Vec, a[i..][0..lanes].*) < @as(Vec, b[i..][0..lanes].*);
        comptime var j: usize = 0;
        inline while (j < lanes) : (j += 1) {
            dst[i + j] = if (mask[j]) 1 else 0;
        }
    }
    while (i < a.len) : (i += 1) dst[i] = if (a[i] < b[i]) 1 else 0;
}
