//! SIMD 批量运算：使用 @Vector 自动向量化
//!
//! 按类型宽度自动选择最优向量宽度，128 位 SIMD 通道
//! comptime op 参数确保只编译匹配的分支，int/float 自动分流

const std = @import("std");

/// 二元算术操作
pub const BinOp = enum { add, sub, mul, div, mod, band, bor, bxor };

/// 一元算术操作
pub const UnaryOp = enum { neg, abs, bnot };

/// 比较操作
pub const CmpOp = enum { lt, gt, eq, ne, le, ge };

/// SIMD 通道数（128-bit 基准，128 位类型退化为 1）
inline fn lanesOf(comptime T: type) usize {
    const bits = @bitSizeOf(T);
    if (bits >= 128) return 1;
    return 128 / bits;
}

inline fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

inline fn isSignedInt(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .int and info.int.signedness == .signed;
}

/// 二元算术批量运算
pub fn batchBinOp(
    comptime T: type,
    comptime op: BinOp,
    dst: []T,
    a: []const T,
    b: []const T,
) !void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const f = isFloat(T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const vb: Vec = b[i..][0..lanes].*;
        const result: Vec = switch (op) {
            .add => if (f) va + vb else va +% vb,
            .sub => if (f) va - vb else va -% vb,
            .mul => if (f) va * vb else va *% vb,
            .div => if (f) va / vb else blk: {
                for (b[i..][0..lanes]) |x| if (x == 0) return error.DivisionByZero;
                break :blk @divTrunc(va, vb);
            },
            .mod => blk: {
                for (b[i..][0..lanes]) |x| if (x == 0) return error.DivisionByZero;
                break :blk @rem(va, vb);
            },
            .band => va & vb,
            .bor => va | vb,
            .bxor => va ^ vb,
        };
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < a.len) : (i += 1) {
        dst[i] = switch (op) {
            .add => if (f) a[i] + b[i] else a[i] +% b[i],
            .sub => if (f) a[i] - b[i] else a[i] -% b[i],
            .mul => if (f) a[i] * b[i] else a[i] *% b[i],
            .div => if (f) a[i] / b[i] else if (b[i] == 0) return error.DivisionByZero else @divTrunc(a[i], b[i]),
            .mod => if (b[i] == 0) return error.DivisionByZero else @rem(a[i], b[i]),
            .band => a[i] & b[i],
            .bor => a[i] | b[i],
            .bxor => a[i] ^ b[i],
        };
    }
}

/// 融合乘加：a * b + c
pub fn batchFma(comptime T: type, dst: []T, a: []const T, b: []const T, c: T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const f = isFloat(T);
    const c_vec: Vec = @splat(c);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const vb: Vec = b[i..][0..lanes].*;
        const result: Vec = if (f) va * vb + c_vec else va *% vb +% c_vec;
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < a.len) : (i += 1) {
        dst[i] = if (f) a[i] * b[i] + c else a[i] *% b[i] +% c;
    }
}

/// 缩放加：a * scale + addend
pub fn batchScaleAdd(comptime T: type, dst: []T, a: []const T, scale: T, addend: T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const f = isFloat(T);
    const scale_vec: Vec = @splat(scale);
    const addend_vec: Vec = @splat(addend);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const result: Vec = if (f) va * scale_vec + addend_vec else va *% scale_vec +% addend_vec;
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < a.len) : (i += 1) {
        dst[i] = if (f) a[i] * scale + addend else a[i] *% scale +% addend;
    }
}

/// 一元算术批量运算
pub fn batchUnary(comptime T: type, comptime op: UnaryOp, dst: []T, a: []const T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const f = isFloat(T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const result: Vec = switch (op) {
            .neg => if (f) -va else @as(Vec, @splat(0)) -% va,
            .abs => if (f) @abs(va) else blk: {
                const zero: Vec = @splat(0);
                const neg = zero -% va;
                const mask = va < zero;
                break :blk @select(T, mask, neg, va);
            },
            .bnot => ~va,
        };
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < a.len) : (i += 1) {
        dst[i] = switch (op) {
            .neg => if (f) -a[i] else 0 -% a[i],
            .abs => if (f) @abs(a[i]) else if (isSignedInt(T) and a[i] < 0) 0 -% a[i] else a[i],
            .bnot => ~a[i],
        };
    }
}

/// 比较批量运算（输出 u8 mask：1 为真，0 为假）
pub fn batchCompare(comptime T: type, comptime op: CmpOp, dst: []u8, a: []const T, b: []const T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const one: @Vector(lanes, u8) = @splat(1);
    const zero: @Vector(lanes, u8) = @splat(0);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const vb: Vec = b[i..][0..lanes].*;
        const mask: @Vector(lanes, bool) = switch (op) {
            .lt => va < vb,
            .gt => va > vb,
            .eq => va == vb,
            .ne => va != vb,
            .le => va <= vb,
            .ge => va >= vb,
        };
        dst[i..][0..lanes].* = @as([lanes]u8, @select(u8, mask, one, zero));
    }
    while (i < a.len) : (i += 1) {
        dst[i] = switch (op) {
            .lt => if (a[i] < b[i]) 1 else 0,
            .gt => if (a[i] > b[i]) 1 else 0,
            .eq => if (a[i] == b[i]) 1 else 0,
            .ne => if (a[i] != b[i]) 1 else 0,
            .le => if (a[i] <= b[i]) 1 else 0,
            .ge => if (a[i] >= b[i]) 1 else 0,
        };
    }
}

/// 条件选择：mask != 0 ? true_val : false_val
pub fn batchSelect(comptime T: type, dst: []T, mask: []const u8, true_val: []const T, false_val: []const T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const zero_u8: @Vector(lanes, u8) = @splat(0);

    var i: usize = 0;
    while (i + lanes <= dst.len) : (i += lanes) {
        const vm: @Vector(lanes, u8) = mask[i..][0..lanes].*;
        const vt: Vec = true_val[i..][0..lanes].*;
        const vf: Vec = false_val[i..][0..lanes].*;
        const sel = vm != zero_u8;
        dst[i..][0..lanes].* = @as([lanes]T, @select(T, sel, vt, vf));
    }
    while (i < dst.len) : (i += 1) {
        dst[i] = if (mask[i] != 0) true_val[i] else false_val[i];
    }
}

/// 广播常量到所有元素
pub fn broadcast(comptime T: type, dst: []T, val: T) void {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const splat: Vec = @splat(val);

    var i: usize = 0;
    while (i + lanes <= dst.len) : (i += lanes) {
        dst[i..][0..lanes].* = @as([lanes]T, splat);
    }
    while (i < dst.len) : (i += 1) dst[i] = val;
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "batchBinOp 整数加法" {
    var a = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var b = [_]i32{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    var dst: [10]i32 = undefined;
    try batchBinOp(i32, .add, &dst, &a, &b);
    for (0..10) |i| try testing.expectEqual(a[i] +% b[i], dst[i]);
}

test "batchBinOp 浮点乘法" {
    var a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var b = [_]f32{ 2.0, 2.0, 2.0, 2.0, 2.0 };
    var dst: [5]f32 = undefined;
    try batchBinOp(f32, .mul, &dst, &a, &b);
    for (0..5) |i| try testing.expectApproxEqAbs(a[i] * b[i], dst[i], 0.001);
}

test "batchBinOp 除零错误" {
    var a = [_]i32{ 10, 20 };
    var b = [_]i32{ 2, 0 };
    var dst: [2]i32 = undefined;
    try testing.expectError(error.DivisionByZero, batchBinOp(i32, .div, &dst, &a, &b));
}

test "batchUnary 整数取负" {
    var a = [_]i32{ 1, -2, 3, -4, 5 };
    var dst: [5]i32 = undefined;
    batchUnary(i32, .neg, &dst, &a);
    for (0..5) |i| try testing.expectEqual(0 -% a[i], dst[i]);
}

test "batchUnary 浮点绝对值" {
    var a = [_]f64{ -1.5, 2.5, -3.5, 4.5 };
    var dst: [4]f64 = undefined;
    batchUnary(f64, .abs, &dst, &a);
    for (0..4) |i| try testing.expectEqual(@abs(a[i]), dst[i]);
}

test "batchCompare 整数小于" {
    var a = [_]i32{ 1, 5, 3, 7, 2 };
    var b = [_]i32{ 2, 3, 3, 1, 8 };
    var dst: [5]u8 = undefined;
    batchCompare(i32, .lt, &dst, &a, &b);
    try testing.expectEqual(@as(u8, 1), dst[0]); // 1 < 2
    try testing.expectEqual(@as(u8, 0), dst[1]); // 5 < 3 = false
    try testing.expectEqual(@as(u8, 0), dst[2]); // 3 < 3 = false
    try testing.expectEqual(@as(u8, 0), dst[3]); // 7 < 1 = false
    try testing.expectEqual(@as(u8, 1), dst[4]); // 2 < 8
}

test "batchSelect 条件选择" {
    var mask = [_]u8{ 1, 0, 1, 0, 1 };
    var tv = [_]i32{ 10, 20, 30, 40, 50 };
    var fv = [_]i32{ 100, 200, 300, 400, 500 };
    var dst: [5]i32 = undefined;
    batchSelect(i32, &dst, &mask, &tv, &fv);
    try testing.expectEqual(@as(i32, 10), dst[0]);
    try testing.expectEqual(@as(i32, 200), dst[1]);
    try testing.expectEqual(@as(i32, 30), dst[2]);
    try testing.expectEqual(@as(i32, 400), dst[3]);
    try testing.expectEqual(@as(i32, 50), dst[4]);
}

test "broadcast 广播常量" {
    var dst: [10]i32 = undefined;
    broadcast(i32, &dst, 42);
    for (0..10) |i| try testing.expectEqual(@as(i32, 42), dst[i]);
}

test "batchFma 融合乘加" {
    var a = [_]i32{ 1, 2, 3, 4 };
    var b = [_]i32{ 10, 20, 30, 40 };
    var dst: [4]i32 = undefined;
    batchFma(i32, &dst, &a, &b, 5);
    for (0..4) |i| try testing.expectEqual(a[i] *% b[i] +% 5, dst[i]);
}

test "batchScaleAdd 缩放加" {
    var a = [_]i32{ 1, 2, 3, 4, 5 };
    var dst: [5]i32 = undefined;
    batchScaleAdd(i32, &dst, &a, 3, 7);
    for (0..5) |i| try testing.expectEqual(a[i] *% 3 +% 7, dst[i]);
}
