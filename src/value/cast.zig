//! 标量类型转换：ScalarTag 之间的语义转换。
//!
//! 转换规则（Rust `as` 风格：永不报错，编译器层面发 warning）：
//! - i→i 宽化：零扩展/符号扩展，安全
//! - i→i 窄化：wrap（按位截断），如 300→i8 = 44
//! - f→f 宽化/窄化：IEEE 754 round-to-nearest，超大值→Inf
//! - i→f：round-to-nearest，大整数丢精度
//! - f→i：截断小数 + 饱和（NaN→0, +Inf→max, -Inf→min, 超大值→max/min）
//! - bool→int：false=0, true=1
//! - int→bool：0=false, 非0=true
//! - char→int：u32 码点直接转
//! - int→char：wrap 截断到 u32（不检查 Unicode 有效性，与 Rust `as` 一致）
//! - bool↔f、char↔f：bool→f=0.0/1.0，char→f=码点浮点，f→bool 直接判 0，f→char 走 f→i32 再 wrap
//!
//! 分派表按 (src_tag, dst_tag) 二维索引，O(1) 查表，comptime 特化内联。

const std = @import("std");
const scalar = @import("scalar.zig");
const ScalarTag = scalar.ScalarTag;

/// 转换函数指针类型：src [16]u8 → dst [16]u8，永不失败
pub const CastFn = *const fn ([16]u8) [16]u8;

// ── 单类型转换实现（comptime 特化）──

/// 整数→整数转换（wrap 语义：窄化时按位截断）
fn intToIntCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    const src_signed = @typeInfo(SrcT).int.signedness == .signed;
    const dst_signed = @typeInfo(DstT).int.signedness == .signed;
    // 同符号宽化：@intCast 安全
    // 同符号窄化：@truncate 按位截断
    // 跨符号（无论宽窄）：@bitCast 到无符号中间类型，按目标位宽截断/扩展，再 @bitCast 回目标符号
    const dst_val: DstT = if (src_signed == dst_signed) blk: {
        if (@sizeOf(DstT) >= @sizeOf(SrcT)) {
            break :blk @intCast(src_val);
        } else {
            break :blk @truncate(src_val);
        }
    } else blk: {
        const SrcUnsigned = std.meta.Int(.unsigned, @bitSizeOf(SrcT));
        const DstUnsigned = std.meta.Int(.unsigned, @bitSizeOf(DstT));
        const src_unsigned: SrcUnsigned = @bitCast(src_val);
        const dst_unsigned: DstUnsigned = if (@sizeOf(DstT) > @sizeOf(SrcT))
            @intCast(src_unsigned)
        else
            @truncate(src_unsigned);
        break :blk @bitCast(dst_unsigned);
    };
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 浮点→浮点转换（IEEE 754 round-to-nearest，超大值→Inf）
fn floatToFloatCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
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

/// 整数→浮点转换（round-to-nearest，大整数丢精度）
fn intToFloatCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
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
fn floatToIntCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
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
fn boolToIntCast(comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
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
fn intToBoolCast(comptime SrcTag: ScalarTag, src: [16]u8) [16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    result[0] = if (src_val != 0) 1 else 0;
    return result;
}

/// bool→浮点转换
fn boolToFloatCast(comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: bool = src[0] != 0;
    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = if (src_val) 1.0 else 0.0;
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// char→整数转换（u32 码点直接转，窄化时 wrap 截断）
fn charToIntCast(comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
    const DstT = scalar.NativeType(DstTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_val: u32 = @bitCast(src[0..4].*);
    var result: [16]u8 = [_]u8{0} ** 16;
    // char(u32)→int：严格宽化用 @intCast，等宽/窄化走 wrap
    // 无符号目标用 @truncate，有符号目标经无符号中转 @bitCast
    const dst_val: DstT = if (@sizeOf(DstT) > @sizeOf(u32))
        @intCast(src_val)
    else if (@typeInfo(DstT).int.signedness == .unsigned)
        @truncate(src_val)
    else blk: {
        const DstUnsigned = std.meta.Int(.unsigned, @bitSizeOf(DstT));
        const dst_unsigned: DstUnsigned = @truncate(src_val);
        break :blk @bitCast(dst_unsigned);
    };
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 整数→char 转换（wrap 截断到 u32，不检查 Unicode 有效性）
fn intToCharCast(comptime SrcTag: ScalarTag, src: [16]u8) [16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    var result: [16]u8 = [_]u8{0} ** 16;
    // wrap 截断到 u32（与 Rust `as` 一致，不检查码点有效性）
    // 无符号源且能安全宽化用 @intCast；其余经无符号中转 @truncate
    const codepoint: u32 = if (@typeInfo(SrcT).int.signedness == .unsigned and @sizeOf(SrcT) <= @sizeOf(u32))
        @intCast(src_val)
    else if (@typeInfo(SrcT).int.signedness == .unsigned)
        @truncate(src_val)
    else blk: {
        const SrcUnsigned = std.meta.Int(.unsigned, @bitSizeOf(SrcT));
        const src_unsigned: SrcUnsigned = @bitCast(src_val);
        break :blk @truncate(src_unsigned);
    };
    result[0..4].* = @bitCast(codepoint);
    return result;
}

/// char→浮点转换
fn charToFloatCast(comptime DstTag: ScalarTag, src: [16]u8) [16]u8 {
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

fn identityCast(src: [16]u8) [16]u8 {
    return src;
}

// ── 分派表构建 ──

/// 判断 ScalarTag 是否为整数类型
pub fn isIntTag(tag: ScalarTag) bool {
    return switch (tag) {
        .i8, .i16, .i32, .i64, .i128,
        .u8, .u16, .u32, .u64, .u128,
        .isize, .usize,
        => true,
        else => false,
    };
}

/// 判断 ScalarTag 是否为浮点类型
pub fn isFloatTag(tag: ScalarTag) bool {
    return switch (tag) {
        .f16, .f32, .f64, .f128 => true,
        else => false,
    };
}

/// 返回 ScalarTag 的字符串名（用于 CastError.from/to 字段）
pub fn tagName(tag: ScalarTag) []const u8 {
    return switch (tag) {
        .boolean => "bool",
        .char => "char",
        .i8 => "i8", .i16 => "i16", .i32 => "i32", .i64 => "i64", .i128 => "i128",
        .u8 => "u8", .u16 => "u16", .u32 => "u32", .u64 => "u64", .u128 => "u128",
        .isize => "isize", .usize => "usize",
        .f16 => "f16", .f32 => "f32", .f64 => "f64", .f128 => "f128",
    };
}

/// 生成单个 (src, dst) 转换函数
fn makeCastFn(comptime src_tag: ScalarTag, comptime dst_tag: ScalarTag) CastFn {
    // 同类型：identity
    if (src_tag == dst_tag) return identityCast;

    // bool 相关
    if (src_tag == .boolean) {
        if (isIntTag(dst_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                return boolToIntCast(dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                return boolToFloatCast(dst_tag, s);
            }
        }.call;
        return identityCast; // bool→bool 已被上面处理，bool→char 不支持
    }
    if (dst_tag == .boolean) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                return intToBoolCast(src_tag, s);
            }
        }.call;
        // float→bool: 直接判 0
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
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
            fn call(s: [16]u8) [16]u8 {
                return charToIntCast(dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                return charToFloatCast(dst_tag, s);
            }
        }.call;
        return identityCast;
    }
    if (dst_tag == .char) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                return intToCharCast(src_tag, s);
            }
        }.call;
        // float→char: 走 float→i32 再 wrap 到 u32
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) [16]u8 {
                const intermediate = floatToIntCast(src_tag, .i32, s);
                return intToCharCast(.i32, intermediate);
            }
        }.call;
        return identityCast;
    }

    // 整数→整数
    if (isIntTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) [16]u8 {
                return intToIntCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→浮点
    if (isFloatTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) [16]u8 {
                return floatToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 整数→浮点
    if (isIntTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) [16]u8 {
                return intToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→整数
    if (isFloatTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) [16]u8 {
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

/// 执行标量转换：src_tag → dst_tag（永不失败，Rust `as` 风格）
/// src_bytes 按 src_tag 宽度读取，返回 [16]u8 结果（前 byteWidth(dst_tag) 字节有效）
pub inline fn cast(
    src_tag: ScalarTag,
    dst_tag: ScalarTag,
    src: [16]u8,
) [16]u8 {
    const si: usize = @intFromEnum(src_tag);
    const di: usize = @intFromEnum(dst_tag);
    return cast_table[si][di](src);
}

// ════════════════════════════════════════════════════════════════════
// 安全类型转换：tryCast（值域越界报错，精度损失不报错）
// ════════════════════════════════════════════════════════════════════

/// 安全转换错误
pub const TryCastError = error{CastOverflow};

/// 安全转换函数指针类型
pub const TryCastFn = *const fn ([16]u8) TryCastError![16]u8;

/// 安全整数→整数转换（值域越界报错）
fn intToIntTryCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) TryCastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    // 范围检查：分 4 种情况，避免 i128 无法表示 u128.maxInt
    if (@typeInfo(DstT).int.signedness == .signed) {
        const dst_max_i128: i128 = @intCast(std.math.maxInt(DstT));
        const dst_min_i128: i128 = @intCast(std.math.minInt(DstT));
        if (@typeInfo(SrcT).int.signedness == .signed) {
            const src_i128: i128 = @intCast(src_val);
            if (src_i128 < dst_min_i128 or src_i128 > dst_max_i128) return error.CastOverflow;
        } else {
            const dst_max_u128: u128 = @intCast(dst_max_i128);
            const src_u128: u128 = @intCast(src_val);
            if (src_u128 > dst_max_u128) return error.CastOverflow;
        }
    } else {
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

/// 安全浮点→整数转换（NaN/Inf/超范围报错，截断小数不报错）
fn floatToIntTryCast(comptime SrcTag: ScalarTag, comptime DstTag: ScalarTag, src: [16]u8) TryCastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const DstT = scalar.NativeType(DstTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const DstArr = scalar.ByteArray(DstTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);

    // NaN / Inf 无法对应整数 → 报错
    if (std.math.isNan(src_val) or std.math.isInf(src_val)) return error.CastOverflow;

    const dst_max: DstT = std.math.maxInt(DstT);
    const dst_min: DstT = std.math.minInt(DstT);
    const max_as_f: SrcT = @floatFromInt(dst_max);
    const min_as_f: SrcT = @floatFromInt(dst_min);

    const truncated: SrcT = @trunc(src_val);
    // 超范围 → 报错（不饱和）
    if (truncated >= max_as_f or truncated <= min_as_f) return error.CastOverflow;

    var result: [16]u8 = [_]u8{0} ** 16;
    const dst_val: DstT = @intFromFloat(truncated);
    const dst_arr: DstArr = @bitCast(dst_val);
    result[0..@sizeOf(DstT)].* = dst_arr;
    return result;
}

/// 安全整数→char 转换（码点超范围报错）
fn intToCharTryCast(comptime SrcTag: ScalarTag, src: [16]u8) TryCastError![16]u8 {
    const SrcT = scalar.NativeType(SrcTag);
    const SrcArr = scalar.ByteArray(SrcTag);
    const src_arr: SrcArr = src[0..@sizeOf(SrcT)].*;
    const src_val: SrcT = @bitCast(src_arr);
    if (src_val < 0 or src_val > 0x10FFFF) return error.CastOverflow;
    var result: [16]u8 = [_]u8{0} ** 16;
    const codepoint: u32 = @intCast(src_val);
    result[0..4].* = @bitCast(codepoint);
    return result;
}

/// 同类型 identity（安全版）
fn identityTryCast(src: [16]u8) TryCastError![16]u8 {
    return src;
}

/// 生成单个 (src, dst) 安全转换函数
fn makeTryCastFn(comptime src_tag: ScalarTag, comptime dst_tag: ScalarTag) TryCastFn {
    if (src_tag == dst_tag) return identityTryCast;

    // bool 相关：bool→int/float 永不溢出
    if (src_tag == .boolean) {
        if (isIntTag(dst_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return boolToIntCast(dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return boolToFloatCast(dst_tag, s);
            }
        }.call;
        return identityTryCast;
    }
    if (dst_tag == .boolean) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return intToBoolCast(src_tag, s);
            }
        }.call;
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                const SrcT = scalar.NativeType(src_tag);
                const SrcArr = scalar.ByteArray(src_tag);
                const src_arr: SrcArr = s[0..@sizeOf(SrcT)].*;
                const src_val: SrcT = @bitCast(src_arr);
                var result: [16]u8 = [_]u8{0} ** 16;
                result[0] = if (src_val != 0.0) 1 else 0;
                return result;
            }
        }.call;
        return identityTryCast;
    }

    // char 相关
    if (src_tag == .char) {
        if (isIntTag(dst_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return intToIntTryCast(.char, dst_tag, s);
            }
        }.call;
        if (isFloatTag(dst_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return charToFloatCast(dst_tag, s);
            }
        }.call;
        return identityTryCast;
    }
    if (dst_tag == .char) {
        if (isIntTag(src_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return intToCharTryCast(src_tag, s);
            }
        }.call;
        if (isFloatTag(src_tag)) return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                // f→char: 先安全 f→i32，再 i32→char 码点检查
                const intermediate = try floatToIntTryCast(src_tag, .i32, s);
                return intToCharTryCast(.i32, intermediate);
            }
        }.call;
        return identityTryCast;
    }

    // 整数→整数
    if (isIntTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return intToIntTryCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→浮点（精度损失不报错）
    if (isFloatTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return floatToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 整数→浮点（精度损失不报错）
    if (isIntTag(src_tag) and isFloatTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return intToFloatCast(src_tag, dst_tag, s);
            }
        }.call;
    }
    // 浮点→整数（NaN/Inf/超范围报错）
    if (isFloatTag(src_tag) and isIntTag(dst_tag)) {
        return struct {
            fn call(s: [16]u8) TryCastError![16]u8 {
                return floatToIntTryCast(src_tag, dst_tag, s);
            }
        }.call;
    }

    return identityTryCast;
}

fn buildTryCastTable() [scalar.ALL_TAGS.len][scalar.ALL_TAGS.len]TryCastFn {
    @setEvalBranchQuota(50000);
    var table: [scalar.ALL_TAGS.len][scalar.ALL_TAGS.len]TryCastFn = undefined;
    inline for (scalar.ALL_TAGS, 0..) |src_tag, si| {
        inline for (scalar.ALL_TAGS, 0..) |dst_tag, di| {
            table[si][di] = makeTryCastFn(src_tag, dst_tag);
        }
    }
    return table;
}

pub const try_cast_table = buildTryCastTable();

/// 安全标量转换：src_tag → dst_tag（值域越界返回 error.CastOverflow）
/// - i→i 窄化溢出 → error
/// - f→i 的 NaN/Inf/超范围 → error
/// - int→char 码点超范围 → error
/// - f→f、i→f 精度损失不报错
pub inline fn tryCast(
    src_tag: ScalarTag,
    dst_tag: ScalarTag,
    src: [16]u8,
) TryCastError![16]u8 {
    const si: usize = @intFromEnum(src_tag);
    const di: usize = @intFromEnum(dst_tag);
    return try_cast_table[si][di](src);
}

// ════════════════════════════════════════════════════════════════════
// Phase 3 cast builder 辅助函数
// ════════════════════════════════════════════════════════════════════

/// 解析错误（str→数值）
pub const ParseError = error{ ParseFailed, OutOfMemory };

/// 将标量值格式化为字符串（用于 CastError.value 字段）
/// allocator 用于分配返回的字符串
pub fn formatScalarValue(allocator: std.mem.Allocator, tag: ScalarTag, bytes: [16]u8) ![]u8 {
    return switch (tag) {
        .boolean => allocator.dupe(u8, if (bytes[0] != 0) "true" else "false"),
        .char => blk: {
            const cp: u32 = @bitCast(bytes[0..4].*);
            const cp_u21: u21 = @intCast(cp & 0xFFFFF);
            break :blk std.fmt.allocPrint(allocator, "'{u}'", .{cp_u21});
        },
        .i8 => blk: {
            const v: i8 = @bitCast(bytes[0..1].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .i16 => blk: {
            const v: i16 = @bitCast(bytes[0..2].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .i32 => blk: {
            const v: i32 = @bitCast(bytes[0..4].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .i64 => blk: {
            const v: i64 = @bitCast(bytes[0..8].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .i128 => blk: {
            const v: i128 = @bitCast(bytes[0..16].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .isize => blk: {
            const v: isize = @bitCast(bytes[0..@sizeOf(isize)].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .u8 => blk: {
            const v: u8 = @bitCast(bytes[0..1].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .u16 => blk: {
            const v: u16 = @bitCast(bytes[0..2].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .u32 => blk: {
            const v: u32 = @bitCast(bytes[0..4].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .u64 => blk: {
            const v: u64 = @bitCast(bytes[0..8].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .u128 => blk: {
            const v: u128 = @bitCast(bytes[0..16].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .usize => blk: {
            const v: usize = @bitCast(bytes[0..@sizeOf(usize)].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .f16 => blk: {
            const v: f16 = @bitCast(bytes[0..2].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .f32 => blk: {
            const v: f32 = @bitCast(bytes[0..4].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .f64 => blk: {
            const v: f64 = @bitCast(bytes[0..8].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        .f128 => blk: {
            const v: f128 = @bitCast(bytes[0..16].*);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{v});
        },
    };
}

/// 将字符串解析为目标数值类型，返回 [16]u8 字节表示
/// 支持：i8..i128 / u8..u128 / isize / usize / f16..f128 / bool / char
pub fn parseStrToNumeric(str: []const u8, dst_tag: ScalarTag) ParseError![16]u8 {
    var result: [16]u8 = [_]u8{0} ** 16;
    switch (dst_tag) {
        .boolean => {
            if (std.mem.eql(u8, str, "true")) {
                result[0] = 1;
            } else if (std.mem.eql(u8, str, "false")) {
                result[0] = 0;
            } else return error.ParseFailed;
        },
        .char => {
            // 单字符字符串 → 码点
            if (str.len == 1) {
                const cp: u32 = str[0];
                result[0..4].* = @bitCast(cp);
            } else return error.ParseFailed;
        },
        .i8 => {
            const v = std.fmt.parseInt(i8, str, 10) catch return error.ParseFailed;
            result[0] = @bitCast(v);
        },
        .i16 => {
            const v = std.fmt.parseInt(i16, str, 10) catch return error.ParseFailed;
            result[0..2].* = @bitCast(v);
        },
        .i32 => {
            const v = std.fmt.parseInt(i32, str, 10) catch return error.ParseFailed;
            result[0..4].* = @bitCast(v);
        },
        .i64 => {
            const v = std.fmt.parseInt(i64, str, 10) catch return error.ParseFailed;
            result[0..8].* = @bitCast(v);
        },
        .i128 => {
            const v = std.fmt.parseInt(i128, str, 10) catch return error.ParseFailed;
            result[0..16].* = @bitCast(v);
        },
        .isize => {
            const v = std.fmt.parseInt(isize, str, 10) catch return error.ParseFailed;
            result[0..@sizeOf(isize)].* = @bitCast(v);
        },
        .u8 => {
            const v = std.fmt.parseInt(u8, str, 10) catch return error.ParseFailed;
            result[0] = @bitCast(v);
        },
        .u16 => {
            const v = std.fmt.parseInt(u16, str, 10) catch return error.ParseFailed;
            result[0..2].* = @bitCast(v);
        },
        .u32 => {
            const v = std.fmt.parseInt(u32, str, 10) catch return error.ParseFailed;
            result[0..4].* = @bitCast(v);
        },
        .u64 => {
            const v = std.fmt.parseInt(u64, str, 10) catch return error.ParseFailed;
            result[0..8].* = @bitCast(v);
        },
        .u128 => {
            const v = std.fmt.parseInt(u128, str, 10) catch return error.ParseFailed;
            result[0..16].* = @bitCast(v);
        },
        .usize => {
            const v = std.fmt.parseInt(usize, str, 10) catch return error.ParseFailed;
            result[0..@sizeOf(usize)].* = @bitCast(v);
        },
        .f16 => {
            const v = std.fmt.parseFloat(f16, str) catch return error.ParseFailed;
            result[0..2].* = @bitCast(v);
        },
        .f32 => {
            const v = std.fmt.parseFloat(f32, str) catch return error.ParseFailed;
            result[0..4].* = @bitCast(v);
        },
        .f64 => {
            const v = std.fmt.parseFloat(f64, str) catch return error.ParseFailed;
            result[0..8].* = @bitCast(v);
        },
        .f128 => {
            const v = std.fmt.parseFloat(f128, str) catch return error.ParseFailed;
            result[0..16].* = @bitCast(v);
        },
    }
    return result;
}

// ── 测试 ──

test "i→i 宽化：i8→i64" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 42; // i8(42)
    const result = cast(.i8, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "i→i 窄化：i64→i8 正常范围" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 100;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    try std.testing.expectEqual(@as(i8, 100), val);
}

test "i→i 窄化：i64→i8 wrap 截断（200→-56）" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 200;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    // 200 = 0xC8，截断到 i8 = 0xC8 = -56
    try std.testing.expectEqual(@as(i8, -56), val);
}

test "i→i 窄化：u32→i8 wrap 截断（300→44）" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: u32 = 300;
    src[0..4].* = @bitCast(src_val);
    const result = cast(.u32, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    // 300 = 0x12C，截断到 u8 = 0x2C = 44，再 interpret 为 i8 = 44
    try std.testing.expectEqual(@as(i8, 44), val);
}

test "f→f 窄化：f64→f32 精度损失" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 3.141592653589793;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .f32, src);
    const val: f32 = @bitCast(result[0..4].*);
    try std.testing.expectApproxEqAbs(@as(f32, 3.1415927), val, 1e-6);
}

test "f→f 窄化：f64(超大)→f32 = Inf" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 1e40;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .f32, src);
    const val: f32 = @bitCast(result[0..4].*);
    try std.testing.expect(std.math.isInf(val) and val > 0);
}

test "i→f 转换：i64→f64" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 42;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .f64, src);
    const val: f64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(f64, 42.0), val);
}

test "f→i 截断：f64(3.7)→i32=3" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 3.7;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, 3), val);
}

test "f→i 截断：f64(-1.2)→i32=-1" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = -1.2;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, -1), val);
}

test "f→i 饱和：f64(+Inf)→i32=maxInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = std.math.inf(f64);
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.maxInt(i32), val);
}

test "f→i 饱和：f64(-Inf)→i32=minInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = -std.math.inf(f64);
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.minInt(i32), val);
}

test "f→i 饱和：f64(NaN)→i32=0" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = std.math.nan(f64);
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, 0), val);
}

test "f→i 饱和：f64(超大值)→i32=maxInt" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: f64 = 1e20;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(std.math.maxInt(i32), val);
}

test "bool→int：true→1, false→0" {
    var src_t: [16]u8 = [_]u8{0} ** 16;
    src_t[0] = 1;
    const r1 = cast(.boolean, .i64, src_t);
    try std.testing.expectEqual(@as(i64, 1), @as(i64, @bitCast(r1[0..8].*)));

    var src_f: [16]u8 = [_]u8{0} ** 16;
    src_f[0] = 0;
    const r2 = cast(.boolean, .i64, src_f);
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @bitCast(r2[0..8].*)));
}

test "int→bool：0→false, 非0→true" {
    const src_zero: [16]u8 = [_]u8{0} ** 16;
    const r1 = cast(.i64, .boolean, src_zero);
    try std.testing.expectEqual(@as(u8, 0), r1[0]);

    var src_nonzero: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 42;
    src_nonzero[0..8].* = @bitCast(src_val);
    const r2 = cast(.i64, .boolean, src_nonzero);
    try std.testing.expectEqual(@as(u8, 1), r2[0]);
}

test "char→int：码点转换" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const codepoint: u32 = 'A'; // 65
    src[0..4].* = @bitCast(codepoint);
    const result = cast(.char, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 65), val);
}

test "int→char：正常码点" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 0x4e2d; // '中'
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .char, src);
    const val: u32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x4e2d), val);
}

test "int→char：超范围码点 wrap 截断（不报错）" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 0x110000; // 超出 Unicode 范围
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .char, src);
    const val: u32 = @bitCast(result[0..4].*);
    // 0x110000 截断到 u32 仍是 0x110000（i64→u32 不截断位，但值超出 u32 范围会 wrap）
    // i64(0x110000) → @truncate 到 u32 = 0x110000（值在 u32 范围内，不截断）
    try std.testing.expectEqual(@as(u32, 0x110000), val);
}

test "identity：同类型转换不变" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: i64 = 12345;
    src[0..8].* = @bitCast(src_val);
    const result = cast(.i64, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 12345), val);
}

test "u→i 跨符号：u8(200)→i8 wrap = -56" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 200;
    const result = cast(.u8, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    // 200 = 0xC8 → i8 = -56
    try std.testing.expectEqual(@as(i8, -56), val);
}

test "u→i 跨符号：u8(100)→i8 正常" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 100;
    const result = cast(.u8, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    try std.testing.expectEqual(@as(i8, 100), val);
}

test "u128→i128 wrap（超过 i128.maxInt）" {
    var src: [16]u8 = [_]u8{0} ** 16;
    // i128.maxInt + 1 = 0x8000_0000_0000_0000_0000_0000_0000_0000
    src[15] = 0x80;
    const result = cast(.u128, .i128, src);
    const val: i128 = @bitCast(result[0..16].*);
    // wrap: 0x8000...0 = i128.minInt
    try std.testing.expectEqual(std.math.minInt(i128), val);
}

test "u128→i64 正常范围" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const src_val: u128 = 42;
    src[0..16].* = @bitCast(src_val);
    const result = cast(.u128, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "i128.minInt→i8 wrap" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 0x00;
    src[15] = 0x80; // i128.minInt = -2^127
    const result = cast(.i128, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    // i128.minInt 的低 8 位 = 0x00 → i8 = 0
    try std.testing.expectEqual(@as(i8, 0), val);
}

test "u128.maxInt→u128 identity" {
    var src: [16]u8 = [_]u8{0xFF} ** 16;
    const result = cast(.u128, .u128, src);
    try std.testing.expectEqualSlices(u8, &src, &result);
}

// ── tryCast 安全转换测试 ──

test "tryCast i→i 宽化：i8→i64 成功" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 42;
    const result = try tryCast(.i8, .i64, src);
    const val: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "tryCast i→i 窄化溢出：i64(200)→i8 报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(i64, 200));
    try std.testing.expectError(error.CastOverflow, tryCast(.i64, .i8, src));
}

test "tryCast i→i 窄化正常：i64(100)→i8 成功" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(i64, 100));
    const result = try tryCast(.i64, .i8, src);
    const val: i8 = @bitCast(result[0..1].*);
    try std.testing.expectEqual(@as(i8, 100), val);
}

test "tryCast u128→i128 超范围报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[15] = 0x80; // i128.maxInt + 1
    try std.testing.expectError(error.CastOverflow, tryCast(.u128, .i128, src));
}

test "tryCast f→i NaN 报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(std.math.nan(f64));
    try std.testing.expectError(error.CastOverflow, tryCast(.f64, .i32, src));
}

test "tryCast f→i Inf 报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(std.math.inf(f64));
    try std.testing.expectError(error.CastOverflow, tryCast(.f64, .i32, src));
}

test "tryCast f→i 超范围报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(f64, 1e20));
    try std.testing.expectError(error.CastOverflow, tryCast(.f64, .i32, src));
}

test "tryCast f→i 截断不报错：f64(3.7)→i32=3" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(f64, 3.7));
    const result = try tryCast(.f64, .i32, src);
    const val: i32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(i32, 3), val);
}

test "tryCast int→char 超范围报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(i64, 0x110000));
    try std.testing.expectError(error.CastOverflow, tryCast(.i64, .char, src));
}

test "tryCast int→char 负值报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(i64, -1));
    try std.testing.expectError(error.CastOverflow, tryCast(.i64, .char, src));
}

test "tryCast int→char 正常码点" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(i64, 0x4e2d));
    const result = try tryCast(.i64, .char, src);
    const val: u32 = @bitCast(result[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x4e2d), val);
}

test "tryCast f→f 精度损失不报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0..8].* = @bitCast(@as(f64, 3.141592653589793));
    const result = try tryCast(.f64, .f32, src);
    const val: f32 = @bitCast(result[0..4].*);
    try std.testing.expectApproxEqAbs(@as(f32, 3.1415927), val, 1e-6);
}

test "tryCast i→f 大整数丢精度不报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const big: i64 = 1 << 53; // f64 可精确表示，+1 则不行
    src[0..8].* = @bitCast(big);
    const result = try tryCast(.i64, .f64, src);
    const val: f64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(f64, @floatFromInt(big)), val);
}

// ── isize/usize 测试（平台相关位宽）──

test "isize/usize ScalarTag 在 ALL_TAGS 中" {
    // 验证新枚举值已被纳入 comptime 生成路径
    var has_isize = false;
    var has_usize = false;
    for (scalar.ALL_TAGS) |t| {
        if (t == .isize) has_isize = true;
        if (t == .usize) has_usize = true;
    }
    try std.testing.expect(has_isize);
    try std.testing.expect(has_usize);
}

test "isize/usize NativeType 字节宽度跟随平台" {
    // 在 64 位平台上为 8，32 位平台上为 4
    try std.testing.expectEqual(@sizeOf(isize), scalar.byteWidth(.isize));
    try std.testing.expectEqual(@sizeOf(usize), scalar.byteWidth(.usize));
}

test "isize→i64 等宽转换往返" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: isize = -12345;
    src[0..@sizeOf(isize)].* = @bitCast(v);
    const result = cast(.isize, .i64, src);
    const out: i64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(i64, -12345), out);
}

test "usize→u64 等宽转换往返" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: usize = 9876543;
    src[0..@sizeOf(usize)].* = @bitCast(v);
    const result = cast(.usize, .u64, src);
    const out: u64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(u64, 9876543), out);
}

test "i32→usize 宽化" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: i32 = 100000;
    src[0..4].* = @bitCast(v);
    const result = cast(.i32, .usize, src);
    const out: usize = @bitCast(result[0..@sizeOf(usize)].*);
    try std.testing.expectEqual(@as(usize, 100000), out);
}

test "usize→i8 wrap 截断" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: usize = 300; // 超过 i8 范围
    src[0..@sizeOf(usize)].* = @bitCast(v);
    const result = cast(.usize, .i8, src);
    const out: i8 = @bitCast(result[0..1].*);
    // 300 = 0x12C，截取低 8 位 = 0x2C = 44
    try std.testing.expectEqual(@as(i8, 44), out);
}

test "isize→f64 转换" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: isize = 42;
    src[0..@sizeOf(isize)].* = @bitCast(v);
    const result = cast(.isize, .f64, src);
    const out: f64 = @bitCast(result[0..8].*);
    try std.testing.expectEqual(@as(f64, 42.0), out);
}

test "tryCast usize→isize 在 i64 平台不溢出" {
    var src: [16]u8 = [_]u8{0} ** 16;
    const v: usize = std.math.maxInt(i64);
    src[0..@sizeOf(usize)].* = @bitCast(v);
    const result = try tryCast(.usize, .isize, src);
    const out: isize = @bitCast(result[0..@sizeOf(isize)].*);
    try std.testing.expectEqual(@as(isize, std.math.maxInt(i64)), out);
}

test "tryCast usize→isize 超范围报错" {
    var src: [16]u8 = [_]u8{0} ** 16;
    // usize max 大于 isize max，应抛出 CastOverflow
    src[0..@sizeOf(usize)].* = @bitCast(@as(usize, std.math.maxInt(usize)));
    try std.testing.expectError(error.CastOverflow, tryCast(.usize, .isize, src));
}

test "cast_table 16×16 完整覆盖（isize/usize 行）" {
    // 验证 comptime 生成的 cast_table 对所有 isize/usize 目标都有入口
    var src: [16]u8 = [_]u8{0} ** 16;
    src[0] = 1;
    // 对每个目标类型执行一次，确保不 panic
    _ = cast(.isize, .i8, src);
    _ = cast(.isize, .u8, src);
    _ = cast(.isize, .isize, src);
    _ = cast(.isize, .usize, src);
    _ = cast(.isize, .f64, src);
    _ = cast(.usize, .i8, src);
    _ = cast(.usize, .u8, src);
    _ = cast(.usize, .isize, src);
    _ = cast(.usize, .usize, src);
    _ = cast(.usize, .f64, src);
}
