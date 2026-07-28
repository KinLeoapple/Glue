//! SIMD 批量运算：使用 @Vector 自动向量化
//!
//! 按类型宽度自动选择最优向量宽度，128 位 SIMD 通道
//! comptime op 参数确保只编译匹配的分支，int/float 自动分流

const std = @import("std");

/// 二元算术操作
pub const BinOp = enum { add, sub, mul, div, mod, band, bor, bxor, shl, shr };

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
    // 浮点位运算和移位无意义（调用方 nodeOpToBatchBinOp 不会映射到此），comptime 提前返回
    // 避免后续 va & vb / @intCast 等对浮点向量实例化失败
    if (isFloat(T) and (op == .band or op == .bor or op == .bxor or op == .shl or op == .shr)) return;

    // i128/u128 位运算特化：用 @Vector(2, u64) 强制走 SIMD 寄存器
    // i128 位运算无进位依赖，可 1:1 并行
    // 主循环每次 2 个 i128（256 位），AVX2 下 1 条指令；SSE2/NEON/LSX 下 2 条
    if (@typeInfo(T) == .int and @bitSizeOf(T) == 128 and
        (op == .band or op == .bor or op == .bxor))
    {
        const HalfVec = @Vector(2, u64); // 128 位：1 条 pand/por/pxor
        const WideVec = @Vector(4, u64); // 256 位：AVX2 下 1 条 vpand/vpor/vpxor

        var i: usize = 0;
        // 主循环：每次 2 个 i128
        while (i + 2 <= a.len) : (i += 2) {
            const va: WideVec = @bitCast(a[i..][0..2].*);
            const vb: WideVec = @bitCast(b[i..][0..2].*);
            const r: WideVec = switch (op) {
                .band => va & vb,
                .bor => va | vb,
                .bxor => va ^ vb,
                else => unreachable,
            };
            dst[i..][0..2].* = @as([2]T, @bitCast(r));
        }
        // tail：剩余 1 个 i128
        if (i < a.len) {
            const va: HalfVec = @bitCast(a[i]);
            const vb: HalfVec = @bitCast(b[i]);
            const r: HalfVec = switch (op) {
                .band => va & vb,
                .bor => va | vb,
                .bxor => va ^ vb,
                else => unreachable,
            };
            dst[i] = @as(T, @bitCast(r));
        }
        return;
    }

    // i128/u128 加减法特化：@Vector(4, u64) 并行处理 2 个 i128
    // 难点：SIMD 加法 lane 独立，无跨 lane 进位，需手动分离 lo/hi 并传递进位/借位
    // 布局（小端序）：[a0_lo, a0_hi, a1_lo, a1_hi] → 分离为 [lo0, lo1] 和 [hi0, hi1]
    if (@typeInfo(T) == .int and @bitSizeOf(T) == 128 and (op == .add or op == .sub)) {
        const WideV = @Vector(4, u64); // 2 个 i128 = 256 位
        const HalfV = @Vector(2, u64); // 分离后的 lo 或 hi 通道
        const one: HalfV = @splat(1);
        const zero: HalfV = @splat(0);

        var i: usize = 0;
        // 主循环：每次 2 个 i128
        while (i + 2 <= a.len) : (i += 2) {
            const va: WideV = @bitCast(a[i..][0..2].*);
            const vb: WideV = @bitCast(b[i..][0..2].*);
            // 分离 lo/hi：va = [lo0, hi0, lo1, hi1] → lo = [lo0, lo1], hi = [hi0, hi1]
            const lo_a: HalfV = @shuffle(u64, va, undefined, [_]i32{ 0, 2 });
            const hi_a: HalfV = @shuffle(u64, va, undefined, [_]i32{ 1, 3 });
            const lo_b: HalfV = @shuffle(u64, vb, undefined, [_]i32{ 0, 2 });
            const hi_b: HalfV = @shuffle(u64, vb, undefined, [_]i32{ 1, 3 });

            const result: WideV = if (op == .add) blk: {
                // 加法：lo 先加，检测进位，hi 加进位
                const lo_sum: HalfV = lo_a +% lo_b; // 1 条 vpaddq
                const carry: HalfV = @select(u64, lo_sum < lo_a, one, zero); // 无符号比较检测溢出
                const hi_sum: HalfV = hi_a +% hi_b +% carry; // 2 条 vpaddq
                // 重新交错：[lo_sum0, hi_sum0, lo_sum1, hi_sum1]
                break :blk @shuffle(u64, lo_sum, hi_sum, [_]i32{ 0, -1, 1, -2 });
            } else blk: {
                // 减法：lo 先减，检测借位，hi 减借位
                const lo_diff: HalfV = lo_a -% lo_b; // 1 条 vpsubq
                const borrow: HalfV = @select(u64, lo_a < lo_b, one, zero); // lo_a < lo_b 表示需借位
                const hi_diff: HalfV = hi_a -% hi_b -% borrow; // 2 条 vpsubq
                break :blk @shuffle(u64, lo_diff, hi_diff, [_]i32{ 0, -1, 1, -2 });
            };
            dst[i..][0..2].* = @as([2]T, @bitCast(result));
        }
        // tail：剩余 1 个 i128，标量 wrapping 运算（LLVM 生成 add+adc）
        while (i < a.len) : (i += 1) {
            dst[i] = if (op == .add) a[i] +% b[i] else a[i] -% b[i];
        }
        return;
    }

    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const f = isFloat(T);

    // i128/u128 wrapping 乘法特化：2 次 i64 mul（标准算法需 4 次）
    // 对 wrapping 乘法取低 128 位：result = z0 + (z1 << 64) mod 2^128
    //   z0 = a_lo * b_lo        （128 位）
    //   z1 = a_hi * b_lo + a_lo * b_hi  （128 位，wrapping 加法）
    //   z2 = a_hi * b_hi        （贡献在 bit 128+，wrapping 下丢弃）
    // 关键：a_hi * b_lo 和 a_lo * b_hi 各只需低 64 位（高 64 位被 << 64 移出）
    // 因此实际只需 2 次 i64 乘法 + 1 次 u128 乘法
    if (@typeInfo(T) == .int and @bitSizeOf(T) == 128 and op == .mul and !f) {
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const au: u128 = @bitCast(a[i]);
            const bu: u128 = @bitCast(b[i]);
            const a_lo: u64 = @truncate(au);
            const a_hi: u64 = @truncate(au >> 64);
            const b_lo: u64 = @truncate(bu);
            const b_hi: u64 = @truncate(bu >> 64);

            // z0 = a_lo * b_lo（u128，保留全部 128 位）
            const z0: u128 = @as(u128, a_lo) * @as(u128, b_lo);
            // z1 = a_hi * b_lo + a_lo * b_hi（各取低 64 位，因为 << 64 后高 64 位溢出）
            const z1: u128 = @as(u128, a_hi *% b_lo) +% @as(u128, a_lo *% b_hi);

            // result = z0 + (z1 << 64) mod 2^128
            const result_u: u128 = z0 +% (z1 << 64);
            dst[i] = @bitCast(result_u);
        }
        return;
    }

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
            .shl => blk: {
                // 移位无法用 @Vector 直接运算（每 lane 移位量不同）
                // 降级为标量循环，LLVM 可自动向量化
                const arr_a: [lanes]T = va;
                const arr_b: [lanes]T = vb;
                var r: [lanes]T = undefined;
                for (0..lanes) |j| {
                    const max_bits = @bitSizeOf(T);
                    const raw = @as(u64, @intCast(if (arr_b[j] < 0) 0 else arr_b[j]));
                    r[j] = if (raw >= max_bits) 0 else arr_a[j] << @intCast(raw);
                }
                break :blk r;
            },
            .shr => blk: {
                const arr_a: [lanes]T = va;
                const arr_b: [lanes]T = vb;
                var r: [lanes]T = undefined;
                for (0..lanes) |j| {
                    const max_bits = @bitSizeOf(T);
                    const raw = @as(u64, @intCast(if (arr_b[j] < 0) 0 else arr_b[j]));
                    r[j] = if (raw >= max_bits) 0 else arr_a[j] >> @intCast(raw);
                }
                break :blk r;
            },
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
            .shl => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b[i] < 0) 0 else b[i]));
                break :blk if (raw >= max_bits) 0 else a[i] << @intCast(raw);
            },
            .shr => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b[i] < 0) 0 else b[i]));
                break :blk if (raw >= max_bits) 0 else a[i] >> @intCast(raw);
            },
        };
    }
}

/// 标量操作数的批量二元运算：dst[i] = a[i] op b（b 为标量，广播到所有 lane）
/// 用于 vec_map 的 `x op const` 形式，避免分配临时广播缓冲
pub fn batchBinOpScalar(comptime T: type, comptime op: BinOp, dst: []T, a: []const T, b: T) !void {
    const f = isFloat(T);

    // 浮点位运算和移位无意义，comptime 提前返回
    if (f and (op == .band or op == .bor or op == .bxor or op == .shl or op == .shr)) return;

    // i128/u128 位运算特化：标量 b 广播后等价于 batchBinOp，但省一次内存读取
    if (@typeInfo(T) == .int and @bitSizeOf(T) == 128 and
        (op == .band or op == .bor or op == .bxor))
    {
        const b_vec: @Vector(2, u64) = @bitCast(@as(T, b));
        for (a, 0..) |x, i| {
            const va: @Vector(2, u64) = @bitCast(x);
            const r: @Vector(2, u64) = switch (op) {
                .band => va & b_vec,
                .bor => va | b_vec,
                .bxor => va ^ b_vec,
                else => unreachable,
            };
            dst[i] = @as(T, @bitCast(r));
        }
        return;
    }

    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const b_vec: Vec = @splat(b);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: Vec = a[i..][0..lanes].*;
        const result: Vec = switch (op) {
            .add => if (f) va + b_vec else va +% b_vec,
            .sub => if (f) va - b_vec else va -% b_vec,
            .mul => if (f) va * b_vec else va *% b_vec,
            .div => if (f) va / b_vec else blk: {
                if (b == 0) return error.DivisionByZero;
                break :blk @divTrunc(va, b_vec);
            },
            .mod => blk: {
                if (b == 0) return error.DivisionByZero;
                break :blk @rem(va, b_vec);
            },
            .band => va & b_vec,
            .bor => va | b_vec,
            .bxor => va ^ b_vec,
            .shl => blk: {
                const arr_a: [lanes]T = va;
                var r: [lanes]T = undefined;
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b < 0) 0 else b));
                for (0..lanes) |j| r[j] = if (raw >= max_bits) 0 else arr_a[j] << @intCast(raw);
                break :blk r;
            },
            .shr => blk: {
                const arr_a: [lanes]T = va;
                var r: [lanes]T = undefined;
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b < 0) 0 else b));
                for (0..lanes) |j| r[j] = if (raw >= max_bits) 0 else arr_a[j] >> @intCast(raw);
                break :blk r;
            },
        };
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < a.len) : (i += 1) {
        dst[i] = switch (op) {
            .add => if (f) a[i] + b else a[i] +% b,
            .sub => if (f) a[i] - b else a[i] -% b,
            .mul => if (f) a[i] * b else a[i] *% b,
            .div => if (f) a[i] / b else if (b == 0) return error.DivisionByZero else @divTrunc(a[i], b),
            .mod => if (b == 0) return error.DivisionByZero else @rem(a[i], b),
            .band => a[i] & b,
            .bor => a[i] | b,
            .bxor => a[i] ^ b,
            .shl => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b < 0) 0 else b));
                break :blk if (raw >= max_bits) 0 else a[i] << @intCast(raw);
            },
            .shr => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b < 0) 0 else b));
                break :blk if (raw >= max_bits) 0 else a[i] >> @intCast(raw);
            },
        };
    }
}

/// 标量操作数的批量二元运算（右标量版）：dst[i] = a op b[i]
/// 用于 vec_map 的 `const op x` 形式
pub fn batchBinOpScalarR(comptime T: type, comptime op: BinOp, dst: []T, a: T, b: []const T) !void {
    const f = isFloat(T);

    // 浮点位运算和移位无意义，comptime 提前返回
    if (f and (op == .band or op == .bor or op == .bxor or op == .shl or op == .shr)) return;

    // i128/u128 位运算特化
    if (@typeInfo(T) == .int and @bitSizeOf(T) == 128 and
        (op == .band or op == .bor or op == .bxor))
    {
        const a_vec: @Vector(2, u64) = @bitCast(@as(T, a));
        for (b, 0..) |x, i| {
            const vb: @Vector(2, u64) = @bitCast(x);
            const r: @Vector(2, u64) = switch (op) {
                .band => a_vec & vb,
                .bor => a_vec | vb,
                .bxor => a_vec ^ vb,
                else => unreachable,
            };
            dst[i] = @as(T, @bitCast(r));
        }
        return;
    }

    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const a_vec: Vec = @splat(a);

    var i: usize = 0;
    while (i + lanes <= b.len) : (i += lanes) {
        const vb: Vec = b[i..][0..lanes].*;
        const result: Vec = switch (op) {
            .add => if (f) a_vec + vb else a_vec +% vb,
            .sub => if (f) a_vec - vb else a_vec -% vb,
            .mul => if (f) a_vec * vb else a_vec *% vb,
            .div => if (f) a_vec / vb else blk: {
                for (b[i..][0..lanes]) |x| if (x == 0) return error.DivisionByZero;
                break :blk @divTrunc(a_vec, vb);
            },
            .mod => blk: {
                for (b[i..][0..lanes]) |x| if (x == 0) return error.DivisionByZero;
                break :blk @rem(a_vec, vb);
            },
            .band => a_vec & vb,
            .bor => a_vec | vb,
            .bxor => a_vec ^ vb,
            // shl/shr 右操作数为向量，退化为标量循环（与 batchBinOp 一致）
            .shl, .shr => blk: {
                const arr_a: [lanes]T = a_vec;
                const arr_b: [lanes]T = vb;
                var r: [lanes]T = undefined;
                const max_bits = @bitSizeOf(T);
                for (0..lanes) |j| {
                    const raw = @as(u64, @intCast(if (arr_b[j] < 0) 0 else arr_b[j]));
                    r[j] = if (raw >= max_bits) 0 else if (op == .shl) arr_a[j] << @intCast(raw) else arr_a[j] >> @intCast(raw);
                }
                break :blk r;
            },
        };
        dst[i..][0..lanes].* = @as([lanes]T, result);
    }
    while (i < b.len) : (i += 1) {
        dst[i] = switch (op) {
            .add => if (f) a + b[i] else a +% b[i],
            .sub => if (f) a - b[i] else a -% b[i],
            .mul => if (f) a * b[i] else a *% b[i],
            .div => if (f) a / b[i] else if (b[i] == 0) return error.DivisionByZero else @divTrunc(a, b[i]),
            .mod => if (b[i] == 0) return error.DivisionByZero else @rem(a, b[i]),
            .band => a & b[i],
            .bor => a | b[i],
            .bxor => a ^ b[i],
            .shl => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b[i] < 0) 0 else b[i]));
                break :blk if (raw >= max_bits) 0 else a << @intCast(raw);
            },
            .shr => blk: {
                const max_bits = @bitSizeOf(T);
                const raw = @as(u64, @intCast(if (b[i] < 0) 0 else b[i]));
                break :blk if (raw >= max_bits) 0 else a >> @intCast(raw);
            },
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
    // 浮点位运算无意义（调用方 nodeOpToBatchUnaryOp 不会映射到此），comptime 提前返回
    if (isFloat(T) and op == .bnot) return;

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
// 归约与前缀扫描（用于 vec_fold/vec_scan 内联模式 SIMD 加速）
// ──────────────────────────────────────────────

/// 标量二元运算辅助（reduce/scan 的标量路径与块间修正共用）
/// 调用方负责对 div/mod 预检除零
inline fn scalarBinOp(comptime T: type, comptime op: BinOp, a: T, b: T) T {
    const f = isFloat(T);
    return switch (op) {
        .add => if (f) a + b else a +% b,
        .sub => if (f) a - b else a -% b,
        .mul => if (f) a * b else a *% b,
        .div => if (f) a / b else @divTrunc(a, b),
        .mod => @rem(a, b),
        .band => a & b,
        .bor => a | b,
        .bxor => a ^ b,
        .shl => blk: {
            const max_bits = @bitSizeOf(T);
            const raw = @as(u64, @intCast(if (b < 0) 0 else b));
            break :blk if (raw >= max_bits) 0 else a << @intCast(raw);
        },
        .shr => blk: {
            const max_bits = @bitSizeOf(T);
            const raw = @as(u64, @intCast(if (b < 0) 0 else b));
            break :blk if (raw >= max_bits) 0 else a >> @intCast(raw);
        },
    };
}

/// 向量二元运算辅助（仅可结合运算，scan 块内与块间修正使用）
inline fn vecBinOp(comptime T: type, comptime op: BinOp, a: anytype, b: anytype) @TypeOf(a) {
    const f = isFloat(T);
    return switch (op) {
        .add => if (f) a + b else a +% b,
        .mul => if (f) a * b else a *% b,
        .band => a & b,
        .bor => a | b,
        .bxor => a ^ b,
        else => unreachable, // scan SIMD 路径仅覆盖可结合运算
    };
}

/// 块内 inclusive scan（Hillis-Steele 对数步数）
/// comptime 展开 stride，每步用 @shuffle 取偏移向量，与 identity 合并后做向量运算
inline fn inclusiveScanVec(
    comptime T: type,
    comptime op: BinOp,
    v: @Vector(lanesOf(T), T),
) @Vector(lanesOf(T), T) {
    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);
    const id_val: T = switch (op) {
        .add => 0,
        .mul => 1,
        .band => ~@as(T, 0),
        .bor => 0,
        .bxor => 0,
        else => unreachable,
    };
    const id_vec: Vec = @splat(id_val);

    var r = v;
    comptime var stride: usize = 1;
    inline while (stride < lanes) : (stride <<= 1) {
        const indices = comptime blk: {
            var arr: [lanes]i32 = undefined;
            for (0..lanes) |i| {
                // i < stride：取 id_vec[i]（@shuffle 负索引：-(i+1) → b[i]）
                // i >= stride：取 r[i - stride]（正索引）
                arr[i] = if (i < stride) -@as(i32, @intCast(i + 1)) else @as(i32, @intCast(i - stride));
            }
            break :blk arr;
        };
        const shifted = @shuffle(T, r, id_vec, indices);
        r = vecBinOp(T, op, r, shifted);
    }
    return r;
}

/// SIMD 横向归约：对可结合运算（add/mul/band/bor/bxor）用 @reduce 横向归约
/// 不可结合运算（sub/div/mod/shl/shr）退化为类型化标量循环
/// init 为初始累加器，返回 init op a[0] op a[1] op ... op a[len-1]
pub fn batchReduce(comptime T: type, comptime op: BinOp, init: T, a: []const T) !T {
    const f = isFloat(T);
    // 浮点位运算无意义（调用方 nodeOpToBatchBinOp 不会映射到此），comptime 提前返回
    // 避免后续 @reduce/.And 等对浮点类型实例化失败
    if (f and (op == .band or op == .bor or op == .bxor)) return init;

    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);

    // 可结合运算判定：位运算仅整数可结合
    const associative = switch (op) {
        .add, .mul => true,
        .band, .bor, .bxor => !f,
        else => false,
    };

    var acc = init;

    if (associative and lanes > 1 and a.len >= lanes) {
        var i: usize = 0;
        // SIMD 块：每 lanes 个元素横向归约为标量，再与 acc 合并
        while (i + lanes <= a.len) : (i += lanes) {
            const v: Vec = a[i..][0..lanes].*;
            const reduced: T = switch (op) {
                .add => @as(T, @reduce(.Add, v)),
                .mul => @as(T, @reduce(.Mul, v)),
                .band => @as(T, @reduce(.And, v)),
                .bor => @as(T, @reduce(.Or, v)),
                .bxor => @as(T, @reduce(.Xor, v)),
                else => unreachable,
            };
            acc = scalarBinOp(T, op, acc, reduced);
        }
        // tail：剩余元素标量归约
        while (i < a.len) : (i += 1) acc = scalarBinOp(T, op, acc, a[i]);
    } else {
        // 不可结合或小数组：标量路径
        for (a) |x| {
            if ((op == .div or op == .mod) and !f and x == 0) return error.DivisionByZero;
            acc = scalarBinOp(T, op, acc, x);
        }
    }
    return acc;
}

/// SIMD 分段前缀扫描：对可结合运算用块内 inclusive scan + 块间累加器修正
/// 不可结合运算退化为类型化标量循环
/// dst[i] = init op a[0] op a[1] op ... op a[i]（inclusive scan）
pub fn batchScan(comptime T: type, comptime op: BinOp, init: T, dst: []T, a: []const T) !void {
    const f = isFloat(T);
    // 浮点位运算无意义，comptime 提前返回（同 batchReduce）
    if (f and (op == .band or op == .bor or op == .bxor)) return;

    const lanes = lanesOf(T);
    const Vec = @Vector(lanes, T);

    const associative = switch (op) {
        .add, .mul => true,
        .band, .bor, .bxor => !f,
        else => false,
    };

    var acc = init;

    if (associative and lanes > 1 and a.len >= lanes) {
        var i: usize = 0;
        while (i + lanes <= a.len) : (i += lanes) {
            const v: Vec = a[i..][0..lanes].*;
            // 块内 inclusive scan
            const block = inclusiveScanVec(T, op, v);
            // 块间修正：整块加上前缀累加器 acc
            const acc_vec: Vec = @splat(acc);
            const shifted = vecBinOp(T, op, acc_vec, block);
            dst[i..][0..lanes].* = @as([lanes]T, shifted);
            // 更新 acc 为本块最后一个元素
            const arr: [lanes]T = shifted;
            acc = arr[lanes - 1];
        }
        // tail：标量扫描
        while (i < a.len) : (i += 1) {
            acc = scalarBinOp(T, op, acc, a[i]);
            dst[i] = acc;
        }
    } else {
        for (a, 0..) |x, idx| {
            if ((op == .div or op == .mod) and !f and x == 0) return error.DivisionByZero;
            acc = scalarBinOp(T, op, acc, x);
            dst[idx] = acc;
        }
    }
}
