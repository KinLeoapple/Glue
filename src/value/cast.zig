//! 标量类型转换：ScalarTag 之间的语义转换。
//!
//! 转换规则：
//! - i→i 宽化：安全，直接转换
//! - i→i 窄化：超范围返回 error.CastOverflow
//! - f→f 宽化/窄化：IEEE 754 round-to-nearest，精度损失不报错
//! - i→f：直接转换，大整数丢精度不报错（IEEE 754 标准行为）
//! - f→i：截断小数 + 超范围饱和（NaN→0, +Inf→max, -Inf→min, 超大值→饱和）
//! - bool→int：false=0, true=1
//! - int→bool：0=false, 非0=true
//! - char→int：u32 码点直接转
//! - int→char：检查有效 Unicode 码点（0..0x10FFFF），超范围返回 error.CastOverflow
//! - bool↔f、char↔f：bool→f=0.0/1.0，char→f=码点浮点，f→bool/f→char 走 f→i 再转
//!
//! 分派表按 (src_tag, dst_tag) 二维索引，O(1) 查表，comptime 特化内联。

const std = @import("std");
const scalar = @import("scalar.zig");
const ScalarTag = scalar.ScalarTag;

/// 转换错误
pub const CastError = error{CastOverflow};

/// 转换函数指针类型：src [16]u8 → dst [16]u8，可能失败
pub const CastFn = *const fn ([16]u8) CastError![16]u8;

// ── 单类型转换实现（comptime 特化）──

/// 整数→整数转换
fn intToIntCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    // 范围检查：分 4 种情况处理，避免 i128 无法表示 u128.maxInt
    if (@typeInfo(DstT).int.signedness == .signed) {
        const dst_max_i128: i128 = @intCast(std.math.maxInt(DstT));
        const dst_min_i128: i128 = @intCast(std.math.minInt(DstT));
        if (@typeInfo(SrcT).int.signedness == .signed) {
            // 有符号源 → 有符号目标：i128 足够表示所有有符号范围
            const src_i128: i128 = @intCast(src_val);
            if (src_i128 < dst_min_i128 or src_i128 > dst_max_i128) {
                return error.CastOverflow;
            }
        } else {
            // 无符号源 → 有符号目标：src >= 0，只需检查上界
            // dst_max >= 0（所有有符号类型的 max 均 >= 0），转 u128 比较避免 i128 溢出
            const dst_max_u128: u128 = @intCast(dst_max_i128);
            const src_u128: u128 = @intCast(src_val);
            if (src_u128 > dst_max_u128) {
                return error.CastOverflow;
            }
        }
    } else {
        // 无符号目标：用 u128 做范围比较，源为负时直接溢出
        const dst_max_u128: u128 = @intCast(std.math.maxInt(DstT));
        if (@typeInfo(SrcT).int.signedness == .signed) {
            const src_i128: i128 = @intCast(src_val);
            if (src_i128 < 0) return error.CastOverflow;
            const src_u128: u128 = @intCast(src_i128);
            if (src_u128 > dst_max_u128) return error.CastOverflow;
        } else {
            const src_u128: u128 = @intCast(src_val);
            if (src_u128 > dst_max_u128) return error.CastOverflow;
        }
    }
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @intCast(src_val);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 浮点→浮点转换（宽化/窄化，IEEE 754 round-to-nearest，不报错）
fn floatToFloatCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @floatCast(src_val);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 整数→浮点转换（直接转换，大整数丢精度不报错）
fn intToFloatCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @floatFromInt(src_val);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 浮点→整数转换（截断小数 + 超范围饱和）
/// NaN→0, +Inf→max, -Inf→min, 超大值→max, 超小值→min
fn floatToIntCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);

    const dst_max: DstT = std.math.maxInt(DstT);
    const dst_min: DstT = std.math.minInt(DstT);
    const max_as_f: SrcT = @floatFromInt(dst_max);
    const min_as_f: SrcT = @floatFromInt(dst_min);

    var result: [16]u8 = [_]u8{0} ** 16;
    // NaN → 0
    if (std.math.isNan(src_val)) {
        result[0..@sizeOf(DstT)].* = @bitCast(@as(DstT, 0));
        return result;
    }
    // +Inf → max
    if (std.math.isInf(src_val) and src_val > 0) {
        result[0..@sizeOf(DstT)].* = @bitCast(dst_max);
        return result;
    }
    // -Inf → min
    if (std.math.isInf(src_val) and src_val < 0) {
        result[0..@sizeOf(DstT)].* = @bitCast(dst_min);
        return result;
    }
    // 截断小数
    const truncated: SrcT = @trunc(src_val);
    // 超范围饱和
    if (truncated >= max_as_f) {
        result[0..@sizeOf(DstT)].* = @bitCast(dst_max);
        return result;
    }
    if (truncated <= min_as_f) {
        result[0..@sizeOf(DstT)].* = @bitCast(dst_min);
        return result;
    }
    // 正常范围：截断后转换
    const dst_val: DstT = @intFromFloat(truncated);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// bool→整数转换
fn boolToIntCast(comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: bool = src[0] != 0;
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = if (src_val) 1 else 0;
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 整数→bool 转换
fn intToBoolCast(comptime SrcTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    result[0] = if (src_val != 0) 1 else 0;
    return result;
}

/// bool→浮点转换
fn boolToFloatCast(comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: bool = src[0] != 0;
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = if (src_val) 1.0 else 0.0;
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// char→整数转换（u32 码点直接转）
fn charToIntCast(comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: u32 = @bitCast(src[0..4].*);
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @intCast(src_val);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 整数→char 转换（检查有效 Unicode 码点）
fn intToCharCast(comptime SrcTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    const codepoint: u32 = @intCast(src_val);
    if (codepoint > 0x10FFFF) return error.CastOverflow;
    var result: [16]u8 = [_]u8{0} ** 16;
    result[0..4].* = @bitCast(codepoint);
    return result;
}

/// char→浮点转换
fn charToFloatCast(comptime DstTag: ScalarTag, src: [16]u8) CastError![16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: u32 = @bitCast(src[0..4].*);
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @floatFromInt(src_val);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

// ── 同类型 identity（src_tag == dst_tag）──

fn identityCast(src: [16]u8) CastError![16]u8 {
    return src;
}

// ── 分派表构建 ──

/// 判断 ScalarTag 是否为整数类型
fn isIntTag(tag: ScalarTag) bool {
    return switch (tag) {
        .i8, .i16, .i32, .i64, .i128,
        .u8, .u16, .u32, .u64, .u128,
        => true,
        else => false,
    };
}

/// 判断 ScalarTag 是否为浮点类型
fn isFloatTag(tag: ScalarTag) bool {
    return switch (tag) {
        .f16, .f32, .f64, .f128 => true,
        else => false,
    };
}

/// 生成单个 (src, dst) 转换函数
fn makeCastFn(comptime src_tag: ScalarTag, comptime dst_tag: ScalarTag) CastFn {
    // 同类型：identity
    if (src_tag == dst_tag) return identityCast;

    // bool 相关
    if (src_tag == .boolean) {
        if (isIntTag(dst_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return boolToIntCast(dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return boolToFloatCast(dst_tag, s);
            }
        }.call;
        return identityCast; // bool→bool 已被上面处理，bool→char 不支持
    }
    if (dst_tag == .boolean) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return intToBoolCast(src_tag, s);
            }
        }.call;
        // float→bool: 走 float→i64→bool 的语义，但更简单是直接判 0
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                const SrcT = scalar.NativeType(src_tag);
                const SrcArr = scalar.ByteArray(src_tag);
                const src_arr: SrcArr = s[0..@sizeOf(SrcT)].*;
                const src_val: SrcT = @bitCast(src_arr);
                var result: [16]u8 = [_]u8{0} ** 16;
                result[0] = if (src_val != 0.0) 1 else 0;
                return result;
            }
        }.call;
        return identityCast;
    }

    // char 相关
    if (src_tag == .char) {
        if (isIntTag(dst_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return charToIntCast(dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return charToFloatCast(dst_tag, s);
            }
        }.call;
        return identityCast;
    }
    if (dst_tag == .char) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return intToCharCast(src_tag, s);
            }
        }.call;
        // float→char: 走 float→i64 再转 char（截断+码点检查）
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                const intermediate = floatToIntCast(src_tag, .i64, s) catch {
                    const result: [16]u8 = [_]u8{0} ** 16;
                    return result;
                };
                return intToCharCast(.i64, intermediate);
            }
        }.call;
        return identityCast;
    }

    // 整数→整数
    if (isIntTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return intToIntCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→浮点
    if (isFloatTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return floatToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 整数→浮点
    if (isIntTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return intToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→整数
    if (isFloatTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) CastError![16]u8 {
                return floatToIntCast(src_tag, dst_tag, s);
            }
        }.call;
    }

    // 不支持的转换：返回 identity（实际不应被调用）
    return identityCast;
}

/// 构建转换分派表（内部函数，使 @setEvalBranchQuota 作用于独立作用域）
fn buildCastTable() [scalar.ALL_TAGS.len][scalar.ALL_TAGS.len]CastFn {
    @setEvalBranchQuota(50000);
    var table: [scalar.ALL_TAGS.len][scalar.ALL_TAGS.len]CastFn = undefined;
    inline for (scalar.ALL_TAGS, 0..) |src_tag, si| {
        inline for (scalar.ALL_TAGS, 0..) |dst_tag, di| {
            table[si][di] = makeCastFn(src_tag, dst_tag);
        }
    }
    return table;
}

/// 转换分派表：[src_tag][dst_tag] → CastFn
/// 通过 ScalarTag 的 @intFromEnum 索引，O(1) 查表
pub const cast_table = buildCastTable();

/// 执行标量转换：src_tag → dst_tag
/// src_bytes 和 dst_bytes 按各自类型宽度读写（前 N 字节有效）
/// 返回 [16]u8 结果，调用者截取前 byteWidth(dst_tag) 字节
pub inline fn cast(
    src_tag: ScalarTag,
    dst_tag: ScalarTag,
    src: [16]u8,
) CastError![16]u8 {
    const si: usize = @intFromEnum(src_tag);
    const di: usize = @intFromEnum(dst_tag);
    return cast_table[si][di](src);
}

// ── 测试 ──

test "i→i 宽化：i8→i64" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 42; // i8(42)
    const result = try cast(.i8, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "i→i 窄化：i64→i8 正常范围" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 100;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.i64, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    try std.testing.expectEqual(@as(i8, 100), val);
}

test "i→i 窄化：i64→i8 溢出返回错误" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 200;
    src[0..8].* = @bitCast(src_val);
    try std.testing.expectError(error.CastOverflow, cast(.i64, .i8, src));
}

test "i→i 窄化：u32→i8 无符号超范围" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: u32 = 300;
    src[0..4].* = @bitCast(src_val);
    try std.testing.expectError(error.CastOverflow, cast(.u32, .i8, src));
}

test "f→f 窄化：f64→f32 精度损失不报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 3.141592653589793;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .f32, src);
    const val: f32 = @bitCast(result[0..4].*);
    try std.testing.expectApproxEqAbs(@as(f32, 3.1415927), val, 1e-6);
}

test "i→f 转换：i64→f64" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 42;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.i64, .f64, src);
    const val: f64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(f64, 42.0), val);
}

test "f→i 截断：f64(3.7)→i32=3" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 3.7;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, 3), val);
}

test "f→i 截断：f64(-1.2)→i32=-1" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = -1.2;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, -1), val);
}

test "f→i 饱和：f64(+Inf)→i32=maxInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = std.math.inf(f64);
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.maxInt(i32), val);
}

test "f→i 饱和：f64(-Inf)→i32=minInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = -std.math.inf(f64);
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.minInt(i32), val);
}

test "f→i 饱和：f64(NaN)→i32=0" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = std.math.nan(f64);
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, 0), val);
}

test "f→i 饱和：f64(超大值)→i32=maxInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 1e20;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.maxInt(i32), val);
}

test "bool→int：true→1, false→0" {
    var src_t: [16]u8 = [_]u8{0} ** 16;
    src_t[0] = 1;
    const r1 = try cast(.boolean, .i64, src_t);
    try std.testing.expectEqual(@as(i64, 1), @as(i64, @bitCast(r1[0..8].*)));

    var src_f: [16]u8 = [_]u8{0} ** 16;
    src_f[0] = 0;
    const r2 = try cast(.boolean, .i64, src_f);
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @bitCast(r2[0..8].*)));
}

test "int→bool：0→false, 非0→true" {
    const src_zero: [16]u8 = [_]u8{0} ** 16;
    const r1 = try cast(.i64, .boolean, src_zero);
    try std.testing.expectEqual(@as(u8, 0), r1[0]);

    var src_nonzero: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 42;
    src_nonzero[0..8].* = @bitCast(src_val);
    const r2 = try cast(.i64, .boolean, src_nonzero);
    try std.testing.expectEqual(@as(u8, 1), r2[0]);
}

test "char→int：码点转换" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const codepoint: u32 = 'A'; // 65
    src[0..4].* = @bitCast(codepoint);
    const result = try cast(.char, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 65), val);
}

test "int→char：正常码点" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 0x4e2d; // '中'
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.i64, .char, src);
    const val: u32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x4e2d), val);
}

test "int→char：超范围码点返回错误" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 0x110000; // 超出 Unicode 范围
    src[0..8].* = @bitCast(src_val);
    try std.testing.expectError(error.CastOverflow, cast(.i64, .char, src));
}

test "identity：同类型转换不变" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 12345;
    src[0..8].* = @bitCast(src_val);
    const result = try cast(.i64, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 12345), val);
}

test "u→i 跨符号：u8(200)→i8 溢出" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 200;
    try std.testing.expectError(error.CastOverflow, cast(.u8, .i8, src));
}

test "u→i 跨符号：u8(100)→i8 正常" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 100;
    const result = try cast(.u8, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    try std.testing.expectEqual(@as(i8, 100), val);
}

test "u128→i128 超过 i128.maxInt 溢出" {
    var src: [16]u8 = [_]u8{0} ** 16;
    // i128.maxInt + 1 = 0x8000_0000_0000_0000_0000_0000_0000_0000
    src[15] = 0x80;
    try std.testing.expectError(error.CastOverflow, cast(.u128, .i128, src));
}

test "u128→i64 正常范围" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: u128 = 42;
    src[0..16].* = @bitCast(src_val);
    const result = try cast(.u128, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "i128.minInt→i8 溢出" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 0x00;
    src[15] = 0x80; // i128.minInt = -2^127
    try std.testing.expectError(error.CastOverflow, cast(.i128, .i8, src));
}

test "u128.maxInt→u128 identity" {
    var src: [16]u8 = [_]u8{0xFF} ** 16;
    const result = try cast(.u128, .u128, src);
    try std.testing.expectEqualSlices(u8, &src, &result);
}
