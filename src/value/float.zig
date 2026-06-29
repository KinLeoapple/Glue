//! 自定义浮点类型——Type 枚举 + Float 结构体（全软件 IEEE 754）
//!
//! 用 [N]u8 字节数组存储所有浮点类型（f8/f16/f32/f64/f128）。
//! 完全自实现，不使用任何原生浮点算术 codegen（仅 fromNative/toNative 用内存拷贝取放原生值用于测试对照）。
//!
//! IEEE 754 编码参数：
//! - f8  (binary8 e5m2):   1 sign + 5 exp  + 2 mantissa,  bias=15    （OCP FP8 e5m2，有 inf/NaN）
//! - f16 (binary16):       1 sign + 5 exp  + 10 mantissa, bias=15
//! - f32 (binary32):       1 sign + 8 exp  + 23 mantissa, bias=127
//! - f64 (binary64):       1 sign + 11 exp + 52 mantissa, bias=1023
//! - f128 (binary128):     1 sign + 15 exp + 112 mantissa, bias=16383
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const ByteArray = @import("byte_array.zig").ByteArray;
const int = @import("int.zig");

/// 浮点类型枚举：5 个变体（f8 采用 e5m2 编码，与 f16 共享 5 位指数和 bias=15，有 inf/NaN 标准 IEEE 754 语义）
pub const Type = enum {
    f8,
    f16,
    f32,
    f64,
    f128,

    /// 字节数
    pub fn byteLength(self: Type) u8 {
        return switch (self) {
            .f8 => 1,
            .f16 => 2,
            .f32 => 4,
            .f64 => 8,
            .f128 => 16,
        };
    }

    /// 位数
    pub fn bitWidth(self: Type) u8 {
        return switch (self) {
            .f8 => 8,
            .f16 => 16,
            .f32 => 32,
            .f64 => 64,
            .f128 => 128,
        };
    }

    /// 指数字段位数
    pub fn exponentBits(self: Type) u8 {
        return switch (self) {
            .f8 => 5,
            .f16 => 5,
            .f32 => 8,
            .f64 => 11,
            .f128 => 15,
        };
    }

    /// 尾数字段位数（不含隐含位）
    pub fn mantissaBits(self: Type) u8 {
        return switch (self) {
            .f8 => 2,
            .f16 => 10,
            .f32 => 23,
            .f64 => 52,
            .f128 => 112,
        };
    }

    /// 指数偏置
    pub fn bias(self: Type) u16 {
        return switch (self) {
            .f8 => 15,
            .f16 => 15,
            .f32 => 127,
            .f64 => 1023,
            .f128 => 16383,
        };
    }

    /// 从类型名构造（"f8"/"f16"/"f32"/"f64"/"f128"），不匹配返回 null
    pub fn fromName(name: []const u8) ?Type {
        if (std.mem.eql(u8, name, "f8")) return .f8;
        if (std.mem.eql(u8, name, "f16")) return .f16;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        if (std.mem.eql(u8, name, "f128")) return .f128;
        return null;
    }
};

/// 解包后的 IEEE 754 字段（不含打包字节布局）
pub const Unpacked = struct {
    sign: u1, // 0=正，1=负
    exp: u32, // 原始指数字段值（0 = 零/次正规，max = inf/nan）
    mantissa: u128, // 尾数（不含隐含位；正规数调用方需自行补 1）
    is_nan: bool,
    is_infinite: bool,
};

/// 解包后的数学含义（用于加减法内部计算）
/// 区别于 Unpacked（原始 IEEE 754 字段），Decomposed 携带 unbiased 指数和含隐含位的尾数。
/// 尾数已左移 3 位预留 GRS（guard/round/sticky）位：
/// - bits [0, 3)：G（bit 2）/ R（bit 1）/ S（bit 0），舍入用
/// - bits [3, 3+p)：fraction（p = mantissaBits()）
/// - bit 3+p：隐含位（正规数=1，次正规/零=0）
/// - bits [3+p+1, ...)：进位预留
const Decomposed = struct {
    sign: u1,
    exp: i32, // unbiased
    mantissa: u128,
    is_nan: bool,
    is_infinite: bool,
    is_zero: bool,

    /// 规格化尾数至 implicit 位 (bit p+3) 置位。
    /// 次正规数的 decompose 不带隐含位（mantissa < 2^(p+3)），左移补齐并同步递减 exp。
    /// 左移不丢失精度（低位本就是 0）；正常数与零为 no-op。
    /// 乘除法在运算前调用，保证乘积 implicit 落在 2p+6、compose 无需左移（sticky 不被移走）。
    pub fn normalize(self: *Decomposed, p: u32) void {
        if (self.is_zero or self.is_nan or self.is_infinite) return;
        const implicit_bit: u128 = @as(u128, 1) << @intCast(p + 3);
        if (self.mantissa == 0 or self.mantissa >= implicit_bit) return;
        const clz: u32 = @intCast(@clz(self.mantissa));
        const target_clz: u32 = 128 - (p + 4);
        const sh: u32 = clz - target_clz;
        self.mantissa <<= @intCast(sh);
        self.exp -= @as(i32, @intCast(sh));
    }
};

/// 单一 Float 结构体：type + bytes + 运算方法
pub const Float = struct {
    type: Type,
    bytes: ByteArray,

    /// +0.0
    pub fn zero(t: Type) Float {
        return .{ .type = t, .bytes = switch (t.byteLength()) {
            1 => .{ .b1 = [_]u8{0} },
            2 => .{ .b2 = [_]u8{0} ** 2 },
            4 => .{ .b4 = [_]u8{0} ** 4 },
            8 => .{ .b8 = [_]u8{0} ** 8 },
            16 => .{ .b16 = [_]u8{0} ** 16 },
            else => unreachable,
        } };
    }

    /// 从原生浮点构造（内存拷贝，不触发原生算术 codegen）
    /// 要求 @sizeOf(@TypeOf(v)) == t.byteLength()
    pub fn fromNative(t: Type, v: anytype) Float {
        const nbytes = t.byteLength();
        const src: [*]const u8 = @ptrCast(&v);
        return .{ .type = t, .bytes = switch (nbytes) {
            1 => .{ .b1 = src[0..1].* },
            2 => .{ .b2 = src[0..2].* },
            4 => .{ .b4 = src[0..4].* },
            8 => .{ .b8 = src[0..8].* },
            16 => .{ .b16 = src[0..16].* },
            else => unreachable,
        } };
    }

    /// 转为原生浮点（内存拷贝）
    pub fn toNative(self: Float, comptime T: type) T {
        var result: T = undefined;
        const dst: [*]u8 = @ptrCast(&result);
        const src = self.bytes.slice();
        @memcpy(dst[0..src.len], src);
        return result;
    }

    /// 转为 f128（正确精度转换，非位拷贝）。任意浮点精度 → f128。
    pub fn asF128(self: Float) f128 {
        if (self.type == .f128) return self.toNative(f128);
        return self.toFloatType(.f128).toNative(f128);
    }

    /// 符号位：true = 负数/负零
    pub fn isNegative(self: Float) bool {
        const a = self.bytes.slice();
        return (a[a.len - 1] & 0x80) != 0;
    }

    /// 是否为 NaN（指数字段全 1 且尾数字段非 0）
    pub fn isNan(self: Float) bool {
        const u = self.unpack();
        return u.is_nan;
    }

    /// 是否为无穷（指数字段全 1 且尾数字段 == 0）
    pub fn isInfinite(self: Float) bool {
        const u = self.unpack();
        return u.is_infinite;
    }

    /// 是否为 0（指数 == 0 且尾数 == 0，含 +0 与 -0）
    pub fn isZero(self: Float) bool {
        const u = self.unpack();
        return u.exp == 0 and u.mantissa == 0;
    }

    /// 是否为次正规数（指数 == 0 且尾数 != 0）
    pub fn isSubnormal(self: Float) bool {
        const u = self.unpack();
        return u.exp == 0 and u.mantissa != 0;
    }

    /// 解包 IEEE 754 字段
    pub fn unpack(self: Float) Unpacked {
        const t = self.type;
        const a = self.bytes.slice();
        const exp_bits = t.exponentBits();
        const mant_bits = t.mantissaBits();
        const bias = t.bias();

        // 提取符号位（最高位）
        const sign: u1 = @intCast((a[a.len - 1] >> 7) & 1);

        // 把整个字节序列读为 u128（小端）
        var raw: u128 = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            raw |= @as(u128, a[i]) << @intCast(i * 8);
        }

        // 清除符号位
        const sign_bit: u128 = @as(u128, 1) << @intCast(a.len * 8 - 1);
        const without_sign = raw & ~sign_bit;

        // 提取指数（紧接符号位后的 exp_bits 位）
        const mant_mask: u128 = (@as(u128, 1) << @intCast(mant_bits)) - 1;
        const mantissa: u128 = without_sign & mant_mask;
        const exp_field: u32 = @intCast(without_sign >> @intCast(mant_bits));

        const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
        const is_nan = (exp_field == max_exp) and (mantissa != 0);
        const is_infinite = (exp_field == max_exp) and (mantissa == 0);

        _ = bias;
        return .{
            .sign = sign,
            .exp = exp_field,
            .mantissa = mantissa,
            .is_nan = is_nan,
            .is_infinite = is_infinite,
        };
    }

    /// IEEE 754 totalOrder 比较：
    /// -NaN < -Inf < ... < -0 < +0 < ... < +Inf < +NaN
    /// 同号 NaN：quiet NaN > signaling NaN（简化为按尾数比较）
    pub fn compare(self: Float, other: Float) std.math.Order {
        std.debug.assert(self.type == other.type);
        const a = self.bytes.slice();
        const b = other.bytes.slice();

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 处理：NaN 总是排在边界
        if (ua.is_nan or ub.is_nan) {
            if (ua.is_nan and ub.is_nan) {
                // 同为 NaN：负号在前；同号按尾数（quiet > signaling 简化为尾数大小）
                if (ua.sign != ub.sign) return if (ua.sign == 1) .lt else .gt;
                if (ua.mantissa < ub.mantissa) return .lt;
                if (ua.mantissa > ub.mantissa) return .gt;
                return .eq;
            }
            // 单边 NaN：非 NaN 视为有符号数，NaN 视为最大正数（若 sign=0）或最小负数（若 sign=1）
            const nan_sign: u1 = if (ua.is_nan) ua.sign else ub.sign;
            const nan_is_self = ua.is_nan;
            if (nan_sign == 1) {
                // -NaN 最小
                return if (nan_is_self) .lt else .gt;
            } else {
                // +NaN 最大
                return if (nan_is_self) .gt else .lt;
            }
        }

        // 同为零（含 +0 与 -0）：视为相等
        if (self.isZero() and other.isZero()) return .eq;

        // 符号不同：负数 < 正数
        if (ua.sign != ub.sign) {
            return if (ua.sign == 1) .lt else .gt;
        }

        // 同号非零：把字节序列当作无符号整数比较，但需翻转符号位
        // 对正数：翻转最高位（让 0x00... 变成 0x80...，正数越大整数越大）
        // 对负数：全部取反（让 0xFF... 变成 0x00...，负数越大整数越小）
        var va: u128 = 0;
        var vb: u128 = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            va |= @as(u128, a[i]) << @intCast(i * 8);
            vb |= @as(u128, b[i]) << @intCast(i * 8);
        }
        if (ua.sign == 1) {
            va = ~va;
            vb = ~vb;
        } else {
            const sign_bit: u128 = @as(u128, 1) << @intCast(a.len * 8 - 1);
            va ^= sign_bit;
            vb ^= sign_bit;
        }
        if (va < vb) return .lt;
        if (va > vb) return .gt;
        return .eq;
    }

    // —— 加减法（S9 实现）——

    /// 解包为数学含义（unbiased 指数 + 含隐含位尾数 + GRS 预留）
    fn decompose(self: Float) Decomposed {
        const u = self.unpack();
        const t = self.type;
        const p = t.mantissaBits();
        const bias: i32 = @intCast(t.bias());

        if (u.is_nan) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = 0, .is_nan = true, .is_infinite = false, .is_zero = false };
        }
        if (u.is_infinite) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = 0, .is_nan = false, .is_infinite = true, .is_zero = false };
        }
        if (u.exp == 0 and u.mantissa == 0) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = 0, .is_nan = false, .is_infinite = false, .is_zero = true };
        }

        var m: u128 = u.mantissa;
        var e: i32 = 0;
        if (u.exp == 0) {
            // 次正规数：无隐含位，exp = 1 - bias
            e = 1 - bias;
        } else {
            // 正规数：补隐含位，exp = exp_field - bias
            m |= @as(u128, 1) << @intCast(p);
            e = @as(i32, @intCast(u.exp)) - bias;
        }
        m <<= 3; // 左移 3 位预留 GRS
        return .{ .sign = u.sign, .exp = e, .mantissa = m, .is_nan = false, .is_infinite = false, .is_zero = false };
    }

    /// 取负（翻转符号位）。NaN 的符号位也翻转。
    pub fn negate(self: Float) Float {
        var result = self;
        const a = result.bytes.sliceMutable();
        a[a.len - 1] ^= 0x80;
        return result;
    }

    /// 加法（全软件 IEEE 754）。要求 self.type == other.type。
    pub fn add(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        const t = self.type;

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 传播
        if (ua.is_nan or ub.is_nan) return makeNan(t);

        // Inf 处理
        if (ua.is_infinite and ub.is_infinite) {
            if (ua.sign == ub.sign) return self; // 同号 Inf + Inf = Inf
            return makeNan(t); // 异号 Inf - Inf = NaN
        }
        if (ua.is_infinite) return self;
        if (ub.is_infinite) return other;

        // Zero 处理
        const a_zero = (ua.exp == 0 and ua.mantissa == 0);
        const b_zero = (ub.exp == 0 and ub.mantissa == 0);
        if (a_zero and b_zero) {
            if (ua.sign == ub.sign) return makeZero(t, ua.sign);
            return makeZero(t, 0); // +0 + -0 = +0
        }
        if (a_zero) return other;
        if (b_zero) return self;

        // 常规路径
        var da = self.decompose();
        var db = other.decompose();

        // 保证 da.exp >= db.exp
        if (da.exp < db.exp) {
            const tmp = da;
            da = db;
            db = tmp;
        }

        // 对阶：右移 db.mantissa
        const shift: u32 = @intCast(da.exp - db.exp);
        db.mantissa = shiftRightWithSticky(db.mantissa, shift);

        // 尾数加减
        var mr: u128 = undefined;
        var sr: u1 = undefined;
        if (da.sign == db.sign) {
            mr = da.mantissa + db.mantissa;
            sr = da.sign;
        } else {
            if (da.mantissa >= db.mantissa) {
                mr = da.mantissa - db.mantissa;
                sr = da.sign;
            } else {
                mr = db.mantissa - da.mantissa;
                sr = db.sign;
            }
        }

        // x + (-x) = +0（RNE 模式下零结果恒为 +0）
        if (mr == 0) return makeZero(t, 0);

        return compose(t, sr, da.exp, mr);
    }

    /// 减法（等价于 self.add(other.negate())）
    pub fn subtract(self: Float, other: Float) Float {
        return self.add(other.negate());
    }

    /// 乘法（全软件 IEEE 754）。要求 self.type == other.type。
    pub fn multiply(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const p: u32 = t.mantissaBits();

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 传播
        if (ua.is_nan or ub.is_nan) return makeNan(t);

        const a_inf = ua.is_infinite;
        const b_inf = ub.is_infinite;
        const a_zero = (ua.exp == 0 and ua.mantissa == 0);
        const b_zero = (ub.exp == 0 and ub.mantissa == 0);
        const result_sign: u1 = ua.sign ^ ub.sign;

        // Inf 处理
        if (a_inf and b_inf) return makeInf(t, result_sign);
        if (a_inf or b_inf) {
            // 一方 Inf：若另一方为零 → NaN（Inf × 0），否则 Inf
            if ((a_inf and b_zero) or (b_inf and a_zero)) return makeNan(t);
            return makeInf(t, result_sign);
        }

        // 零处理
        if (a_zero or b_zero) return makeZero(t, result_sign);

        // 常规路径
        var da = self.decompose();
        var db = other.decompose();
        da.normalize(p);
        db.normalize(p);
        var result_exp: i32 = da.exp + db.exp;

        // 256 位乘积：da.mantissa × db.mantissa
        var hi: u128 = undefined;
        var lo: u128 = undefined;
        {
            const product = multiply128To256(da.mantissa, db.mantissa);
            hi = product.hi;
            lo = product.lo;
        }

        // 乘积 implicit 在 bit 2p+6；检查进位 bit 2p+7
        const carry_pos: u32 = 2 * p + 7;
        var carry_set = false;
        if (carry_pos < 128) {
            carry_set = (lo & (@as(u128, 1) << @intCast(carry_pos))) != 0;
        } else {
            carry_set = (hi & (@as(u128, 1) << @intCast(carry_pos - 128))) != 0;
        }
        if (carry_set) {
            // {hi, lo} 整体右移 1，最低位 OR 进 sticky
            const lost: u1 = @truncate(lo);
            lo = (lo >> 1) | (hi << 127);
            hi = hi >> 1;
            if (lost == 1) lo |= 1;
            result_exp += 1;
        }

        // 提取 bits [p+3, 2p+6) 到 mant：implicit 落在 p+3
        // mant = (product >> (p+3)) 的低 128 位
        const low_width: u32 = p + 3; // ≤ 115 < 128
        const mant: u128 = (lo >> @intCast(low_width)) | (hi << @intCast(128 - low_width));
        // sticky：product bits [0, p+3) 非 0（均在 lo 中）
        const low_mask: u128 = (@as(u128, 1) << @intCast(low_width)) - 1;
        var result_mant = mant;
        if ((lo & low_mask) != 0) result_mant |= 1;

        return compose(t, result_sign, result_exp, result_mant);
    }

    /// 除法（全软件 IEEE 754）。要求 self.type == other.type。
    /// 除零不报错：finite/0 = Inf，0/0 = NaN（IEEE 754 语义）。
    pub fn divide(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const p: u32 = t.mantissaBits();

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 传播
        if (ua.is_nan or ub.is_nan) return makeNan(t);

        const a_inf = ua.is_infinite;
        const b_inf = ub.is_infinite;
        const a_zero = (ua.exp == 0 and ua.mantissa == 0);
        const b_zero = (ub.exp == 0 and ub.mantissa == 0);
        const result_sign: u1 = ua.sign ^ ub.sign;

        // Inf 处理
        if (a_inf and b_inf) return makeNan(t); // Inf / Inf = NaN
        if (a_inf) return makeInf(t, result_sign);
        if (b_inf) return makeZero(t, result_sign); // finite / Inf = 0

        // 零处理
        if (a_zero and b_zero) return makeNan(t); // 0 / 0 = NaN
        if (a_zero) return makeZero(t, result_sign);
        if (b_zero) return makeInf(t, result_sign); // finite / 0 = Inf

        // 常规路径
        var da = self.decompose();
        var db = other.decompose();
        da.normalize(p);
        db.normalize(p);
        var result_exp: i32 = da.exp - db.exp;

        // 被除数 = da.mantissa << (p+3)，256 位
        const shift: u32 = p + 3; // < 128
        const dividend_lo: u128 = da.mantissa << @intCast(shift);
        const dividend_hi: u128 = da.mantissa >> @intCast(128 - shift);

        const div_result = divide256By128(dividend_hi, dividend_lo, db.mantissa);
        var quotient: u128 = div_result.quotient;
        const remainder: u128 = div_result.remainder;

        // 商范围 [2^(p+2), 2^(p+4))；若 < 2^(p+3)（implicit 在 p+2）：左移 1，exp -= 1
        const implicit_bit: u128 = @as(u128, 1) << @intCast(p + 3);
        if (quotient < implicit_bit) {
            quotient <<= 1;
            result_exp -= 1;
        }

        // sticky：余数非 0 → bit 0
        if (remainder != 0) quotient |= 1;

        return compose(t, result_sign, result_exp, quotient);
    }

    /// 转换到另一精度的 Float（如 f32 → f64）。全软件：解包 → 重新打包。
    /// NaN/Inf 用目标类型重建；零/次正规/正规走 decompose → 对齐 → compose。
    pub fn toFloatType(self: Float, target: Type) Float {
        if (target == self.type) return self;
        const u = self.unpack();
        if (u.is_nan) return makeNan(target);
        if (u.is_infinite) return makeInf(target, u.sign);
        if (u.exp == 0 and u.mantissa == 0) return makeZero(target, u.sign);

        const p_self: u32 = self.type.mantissaBits();
        const p_target: u32 = target.mantissaBits();

        var da = self.decompose();
        da.normalize(p_self); // 规格化至 implicit 在 p_self+3（次正规补隐含位），值不变

        // 对齐 implicit 至 p_target+3：value = m × 2^(exp - (p+3))，移位不改变 exp
        var m = da.mantissa;
        if (p_self > p_target) {
            m = shiftRightWithSticky(m, p_self - p_target);
        } else if (p_target > p_self) {
            m <<= @intCast(p_target - p_self);
        }
        return compose(target, da.sign, da.exp, m);
    }

    /// 转换为 Int（向零截断，IEEE 754 convertToIntegerTiesToZero）。
    /// NaN/Inf 或超出 target 范围 → error.Overflow。
    pub fn toInt(self: Float, target: int.Type) error{Overflow}!int.Int {
        const t = self.type;
        const u = self.unpack();
        if (u.is_nan or u.is_infinite) return error.Overflow;
        if (u.exp == 0 and u.mantissa == 0) return int.Int.zero(target);

        const p: u32 = t.mantissaBits();
        var da = self.decompose();
        da.normalize(p); // 规格化，da.mantissa 低 3 位为 0（GRS 占位）

        // |value| = da.mantissa × 2^frac_shift，向零截断 = floor(|value|)
        const frac_shift: i32 = da.exp - @as(i32, @intCast(p + 3));
        var mag: u128 = da.mantissa;

        if (frac_shift >= 0) {
            const sh: u32 = @intCast(frac_shift);
            if (sh >= 128) return error.Overflow;
            if (sh > 0) {
                if ((mag >> @intCast(128 - sh)) != 0) return error.Overflow; // 左移会溢出 u128
                mag <<= @intCast(sh);
            }
        } else {
            const sh: u32 = @intCast(-frac_shift);
            if (sh >= 128) {
                mag = 0;
            } else {
                mag >>= @intCast(sh);
            }
        }

        const bits: u32 = target.bitWidth();
        if (da.sign == 0) {
            // 正数
            const max_mag: u128 = if (target.isSigned())
                (@as(u128, 1) << @intCast(bits - 1)) - 1
            else if (bits == 128)
                std.math.maxInt(u128)
            else
                (@as(u128, 1) << @intCast(bits)) - 1;
            if (mag > max_mag) return error.Overflow;
            return int.Int.fromNative(target, mag);
        } else {
            // 负数：两补 = 0 -% mag
            if (!target.isSigned()) return error.Overflow;
            const max_mag: u128 = @as(u128, 1) << @intCast(bits - 1);
            if (mag > max_mag) return error.Overflow;
            const neg: u128 = 0 -% mag;
            return int.Int.fromNative(target, neg);
        }
    }

    /// 绝对值（清符号位）。NaN 符号位也清零（与 Zig @abs 一致）。
    pub fn abs(self: Float) Float {
        var result = self;
        const a = result.bytes.sliceMutable();
        a[a.len - 1] &= ~@as(u8, 0x80);
        return result;
    }

    /// 复制符号位：返回 |self| 带 other 的符号。
    pub fn copySign(self: Float, other: Float) Float {
        var result = self;
        const a = result.bytes.sliceMutable();
        const other_sign: u8 = if (other.isNegative()) 0x80 else 0x00;
        a[a.len - 1] = (a[a.len - 1] & ~@as(u8, 0x80)) | other_sign;
        return result;
    }

    /// 向上一步（nextUp）：返回大于 self 的最小 Float。
    /// NaN → NaN；+Inf → +Inf；-Inf → -max_finite；±0 → +min_subnormal；
    /// 正有限数 → +1 ulp（max_finite → +Inf）；负有限数 → -1 ulp（向 0 靠近，值变大）。
    pub fn nextUp(self: Float) Float {
        const t = self.type;
        const u = self.unpack();
        if (u.is_nan) return self;
        if (u.is_infinite) {
            if (u.sign == 0) return self; // +Inf → +Inf
            // -Inf → -max_finite
            const exp_bits = t.exponentBits();
            const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
            const p = t.mantissaBits();
            const max_frac: u128 = (@as(u128, 1) << @intCast(p)) - 1;
            return packBytes(t, 1, max_exp - 1, max_frac);
        }

        const a = self.bytes.slice();
        var bits: u128 = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            bits |= @as(u128, a[i]) << @intCast(i * 8);
        }
        const sign_bit: u128 = @as(u128, 1) << @intCast(a.len * 8 - 1);

        // ±0 → +min_subnormal
        if (bits == 0 or bits == sign_bit) {
            return packBytes(t, 0, 0, 1);
        }

        if (u.sign == 0) {
            bits +%= 1; // 正数 +1 ulp
        } else {
            bits -%= 1; // 负数 -1 ulp（向 0，值变大）
        }
        return packRawBits(t, bits);
    }

    /// 向下一步（nextDown）：返回小于 self 的最大 Float。
    /// 等价于 -nextUp(-self)。
    pub fn nextDown(self: Float) Float {
        return self.negate().nextUp().negate();
    }
};

// —— 加减法辅助函数（S9 实现）——

/// 右移并保留 sticky（丢失的位 OR 到 bit 0）
fn shiftRightWithSticky(m: u128, shift: u32) u128 {
    if (shift == 0) return m;
    if (shift >= 128) return if (m != 0) 1 else 0;
    const mask: u128 = (@as(u128, 1) << @intCast(shift)) - 1;
    const lost = m & mask;
    const shifted = m >> @intCast(shift);
    return shifted | (if (lost != 0) @as(u128, 1) else 0);
}

/// 构造零（指定符号）
fn makeZero(t: Type, sign: u1) Float {
    var f = Float.zero(t);
    if (sign == 1) {
        const a = f.bytes.sliceMutable();
        a[a.len - 1] |= 0x80;
    }
    return f;
}

/// 构造无穷（指定符号）
fn makeInf(t: Type, sign: u1) Float {
    const exp_bits = t.exponentBits();
    const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
    return packBytes(t, sign, max_exp, 0);
}

/// 构造 NaN（canonical quiet NaN：sign=0, exp=全1, mantissa=1）
fn makeNan(t: Type) Float {
    const exp_bits = t.exponentBits();
    const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
    return packBytes(t, 0, max_exp, 1);
}

/// 从 sign/stored_exp/fraction 打包为 Float
fn packBytes(t: Type, sign: u1, stored_exp: u32, fraction: u128) Float {
    const p = t.mantissaBits();
    const nbytes = t.byteLength();
    var raw: u128 = 0;
    raw |= fraction;
    raw |= @as(u128, stored_exp) << @intCast(p);
    if (sign == 1) {
        raw |= @as(u128, 1) << @intCast(nbytes * 8 - 1);
    }
    var bytes: [16]u8 = [_]u8{0} ** 16;
    var i: usize = 0;
    while (i < nbytes) : (i += 1) {
        bytes[i] = @truncate(raw >> @intCast(i * 8));
    }
    return .{ .type = t, .bytes = switch (nbytes) {
        1 => .{ .b1 = bytes[0..1].* },
        2 => .{ .b2 = bytes[0..2].* },
        4 => .{ .b4 = bytes[0..4].* },
        8 => .{ .b8 = bytes[0..8].* },
        16 => .{ .b16 = bytes[0..16].* },
        else => unreachable,
    } };
}

/// 从原始位模式（u128，低 nbytes 字节有效）打包为 Float
fn packRawBits(t: Type, bits: u128) Float {
    const nbytes = t.byteLength();
    var bytes: [16]u8 = [_]u8{0} ** 16;
    var i: usize = 0;
    while (i < nbytes) : (i += 1) {
        bytes[i] = @truncate(bits >> @intCast(i * 8));
    }
    return .{ .type = t, .bytes = switch (nbytes) {
        1 => .{ .b1 = bytes[0..1].* },
        2 => .{ .b2 = bytes[0..2].* },
        4 => .{ .b4 = bytes[0..4].* },
        8 => .{ .b8 = bytes[0..8].* },
        16 => .{ .b16 = bytes[0..16].* },
        else => unreachable,
    } };
}

/// 从 sign/unbiased exp/含 GRS 的尾数 打包为 Float
/// 处理规格化 + RNE 舍入 + 范围判定（上溢→Inf，下溢→次正规/零）
fn compose(t: Type, sign: u1, exp: i32, mantissa: u128) Float {
    const p: u32 = t.mantissaBits();
    const bias: i32 = @intCast(t.bias());
    const exp_bits = t.exponentBits();
    const max_exp_field: i32 = (@as(i32, 1) << @intCast(exp_bits)) - 1;

    var m = mantissa;
    var e = exp;

    if (m == 0) return makeZero(t, sign);

    const implicit_bit: u128 = @as(u128, 1) << @intCast(p + 3);
    const carry_bit: u128 = @as(u128, 1) << @intCast(p + 4);

    // 处理加法进位（bit p+4 置位）
    if (m >= carry_bit) {
        m = shiftRightWithSticky(m, 1);
        e += 1;
    }

    // 规格化：左移至 bit (p+3) 置位
    if (m != 0 and m < implicit_bit) {
        const clz_m: u32 = @intCast(@clz(m));
        const target_clz: u32 = 128 - p - 4;
        const shift_amt = clz_m - target_clz;
        m <<= @intCast(shift_amt);
        e -= @as(i32, @intCast(shift_amt));
    }

    // 上溢检查
    if (e + bias >= max_exp_field) {
        return makeInf(t, sign);
    }

    var stored_exp: i32 = undefined;

    if (e + bias >= 1) {
        // 正规数
        stored_exp = e + bias;
    } else {
        // 次正规数：右移对齐到次正规位置（effective exp = 1 - bias）
        const shift: u32 = @intCast(1 - bias - e);
        m = shiftRightWithSticky(m, shift);
        stored_exp = 0;
    }

    // RNE 舍入（round-to-nearest-even）
    const lsb_bit: u128 = @as(u128, 1) << 3;
    const guard_bit: u128 = @as(u128, 1) << 2;
    const round_bit: u128 = @as(u128, 1) << 1;

    const g = (m & guard_bit) != 0;
    const r = (m & round_bit) != 0;
    const s = (m & 1) != 0;
    const lsb_set = (m & lsb_bit) != 0;

    var rounded = m & ~@as(u128, 7);
    if (g and (r or s or lsb_set)) {
        rounded +%= lsb_bit;
    }
    m = rounded;

    // 舍入后溢出检查
    if (stored_exp == 0) {
        // 次正规：舍入后若 bit (p+3) 置位 → 升格为最小正规数
        if (m & implicit_bit != 0) {
            stored_exp = 1;
        }
    } else {
        // 正规：舍入后若 bit (p+4) 置位 → 右移 + stored_exp+1
        if (m & carry_bit != 0) {
            m >>= 1;
            stored_exp += 1;
            if (stored_exp >= max_exp_field) {
                return makeInf(t, sign);
            }
        }
    }

    const fraction_mask: u128 = (@as(u128, 1) << @intCast(p)) - 1;
    const fraction = (m >> 3) & fraction_mask;

    return packBytes(t, sign, @intCast(stored_exp), fraction);
}

// —— 256 位算术辅助函数（S10 乘除法用）——

/// 128×128 → 256 位乘法
/// 分裂为 4 个 u64×u64 → u128 部分积，进位链组合
fn multiply128To256(a: u128, b: u128) struct { hi: u128, lo: u128 } {
    const a_lo: u64 = @truncate(a);
    const a_hi: u64 = @truncate(a >> 64);
    const b_lo: u64 = @truncate(b);
    const b_hi: u64 = @truncate(b >> 64);

    const ll: u128 = @as(u128, a_lo) * @as(u128, b_lo);
    const lh: u128 = @as(u128, a_lo) * @as(u128, b_hi);
    const hl: u128 = @as(u128, a_hi) * @as(u128, b_lo);
    const hh: u128 = @as(u128, a_hi) * @as(u128, b_hi);

    const ll_lo: u64 = @truncate(ll);
    const ll_hi: u64 = @truncate(ll >> 64);
    const lh_lo: u64 = @truncate(lh);
    const lh_hi: u64 = @truncate(lh >> 64);
    const hl_lo: u64 = @truncate(hl);
    const hl_hi: u64 = @truncate(hl >> 64);
    const hh_lo: u64 = @truncate(hh);
    const hh_hi: u64 = @truncate(hh >> 64);

    const p0: u64 = ll_lo;

    const p1: u128 = @as(u128, ll_hi) + @as(u128, lh_lo) + @as(u128, hl_lo);
    const p1_lo: u64 = @truncate(p1);
    const c1: u64 = @truncate(p1 >> 64);

    const p2: u128 = @as(u128, hh_lo) + @as(u128, lh_hi) + @as(u128, hl_hi) + @as(u128, c1);
    const p2_lo: u64 = @truncate(p2);
    const c2: u64 = @truncate(p2 >> 64);

    const p3: u128 = @as(u128, hh_hi) + @as(u128, c2);
    const p3_lo: u64 = @truncate(p3);

    const lo: u128 = @as(u128, p0) | (@as(u128, p1_lo) << 64);
    const hi: u128 = @as(u128, p2_lo) | (@as(u128, p3_lo) << 64);

    return .{ .hi = hi, .lo = lo };
}

/// 256 位 / 128 位 → 128 位商 + 128 位余数
/// shift-subtract 长除法，256 次迭代。要求商不超过 128 位（调用方保证）。
fn divide256By128(dividend_hi: u128, dividend_lo: u128, divisor: u128) struct { quotient: u128, remainder: u128 } {
    var dh = dividend_hi;
    var dl = dividend_lo;
    var rem: u128 = 0;
    var rem_carry: u1 = 0;
    var quot_lo: u128 = 0;
    var quot_hi: u128 = 0;

    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const bit: u1 = @truncate(dh >> 127);
        dh = (dh << 1) | (dl >> 127);
        dl = dl << 1;

        rem_carry = @truncate(rem >> 127);
        rem = (rem << 1) | bit;

        if (rem_carry == 1 or rem >= divisor) {
            rem = rem -% divisor;
            rem_carry = 0;
            if (i < 128) {
                quot_hi = quot_hi | (@as(u128, 1) << @intCast(127 - i));
            } else {
                quot_lo = quot_lo | (@as(u128, 1) << @intCast(255 - i));
            }
        }
    }

    std.debug.assert(quot_hi == 0);
    return .{ .quotient = quot_lo, .remainder = rem };
}

test "Type.byteLength/bitWidth/exponentBits/mantissaBits/bias" {
    try std.testing.expectEqual(@as(u8, 2), Type.f16.byteLength());
    try std.testing.expectEqual(@as(u8, 16), Type.f16.bitWidth());
    try std.testing.expectEqual(@as(u8, 5), Type.f16.exponentBits());
    try std.testing.expectEqual(@as(u8, 10), Type.f16.mantissaBits());
    try std.testing.expectEqual(@as(u16, 15), Type.f16.bias());

    try std.testing.expectEqual(@as(u8, 4), Type.f32.byteLength());
    try std.testing.expectEqual(@as(u8, 8), Type.f32.exponentBits());
    try std.testing.expectEqual(@as(u8, 23), Type.f32.mantissaBits());
    try std.testing.expectEqual(@as(u16, 127), Type.f32.bias());

    try std.testing.expectEqual(@as(u8, 8), Type.f64.byteLength());
    try std.testing.expectEqual(@as(u8, 11), Type.f64.exponentBits());
    try std.testing.expectEqual(@as(u8, 52), Type.f64.mantissaBits());
    try std.testing.expectEqual(@as(u16, 1023), Type.f64.bias());

    try std.testing.expectEqual(@as(u8, 16), Type.f128.byteLength());
    try std.testing.expectEqual(@as(u8, 15), Type.f128.exponentBits());
    try std.testing.expectEqual(@as(u8, 112), Type.f128.mantissaBits());
    try std.testing.expectEqual(@as(u16, 16383), Type.f128.bias());
}

test "Float.fromNative/toNative roundtrip" {
    // f32
    {
        const cases = [_]f32{ 0.0, -0.0, 1.0, -1.0, 3.14, -3.14, std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (cases) |v| {
            const x = Float.fromNative(.f32, v);
            try std.testing.expectEqual(v, x.toNative(f32));
        }
    }
    // f64
    {
        const cases = [_]f64{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f64), -std.math.floatMax(f64) };
        for (cases) |v| {
            const x = Float.fromNative(.f64, v);
            try std.testing.expectEqual(v, x.toNative(f64));
        }
    }
    // f16
    {
        const cases = [_]f16{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f16) };
        for (cases) |v| {
            const x = Float.fromNative(.f16, v);
            try std.testing.expectEqual(v, x.toNative(f16));
        }
    }
    // f128
    {
        const cases = [_]f128{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f128) };
        for (cases) |v| {
            const x = Float.fromNative(.f128, v);
            try std.testing.expectEqual(v, x.toNative(f128));
        }
    }
}

test "Float.isNan/isInfinite/isZero/isSubnormal/isNegative" {
    // f32
    const pos_inf_f32 = Float.fromNative(.f32, std.math.inf(f32));
    const neg_inf_f32 = Float.fromNative(.f32, -std.math.inf(f32));
    const pos_nan_f32 = Float.fromNative(.f32, std.math.nan(f32));
    const pos_zero_f32 = Float.fromNative(.f32, @as(f32, 0.0));
    const neg_zero_f32 = Float.fromNative(.f32, @as(f32, -0.0));
    const normal_f32 = Float.fromNative(.f32, @as(f32, 1.0));
    const subnormal_f32 = Float.fromNative(.f32, std.math.floatMin(f32) / 2);

    try std.testing.expect(!pos_inf_f32.isNan());
    try std.testing.expect(pos_inf_f32.isInfinite());
    try std.testing.expect(!pos_inf_f32.isZero());
    try std.testing.expect(!pos_inf_f32.isSubnormal());
    try std.testing.expect(!pos_inf_f32.isNegative());

    try std.testing.expect(!neg_inf_f32.isNan());
    try std.testing.expect(neg_inf_f32.isInfinite());
    try std.testing.expect(neg_inf_f32.isNegative());

    try std.testing.expect(pos_nan_f32.isNan());
    try std.testing.expect(!pos_nan_f32.isInfinite());

    try std.testing.expect(pos_zero_f32.isZero());
    try std.testing.expect(!pos_zero_f32.isNegative());
    try std.testing.expect(neg_zero_f32.isZero());
    try std.testing.expect(neg_zero_f32.isNegative());

    try std.testing.expect(!normal_f32.isZero());
    try std.testing.expect(!normal_f32.isSubnormal());

    try std.testing.expect(subnormal_f32.isSubnormal());
    try std.testing.expect(!subnormal_f32.isZero());

    // f64 / f128 类似（少量验证）
    try std.testing.expect(Float.fromNative(.f64, std.math.nan(f64)).isNan());
    try std.testing.expect(Float.fromNative(.f64, std.math.inf(f64)).isInfinite());
    try std.testing.expect(Float.fromNative(.f128, std.math.nan(f128)).isNan());
    try std.testing.expect(Float.fromNative(.f128, std.math.inf(f128)).isInfinite());
}

test "Float.compare basic" {
    // 同号正数
    try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, 3.0)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
    try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, 1.0)).compare(Float.fromNative(.f32, @as(f32, 3.0))));
    try std.testing.expectEqual(.eq, Float.fromNative(.f32, @as(f32, 3.0)).compare(Float.fromNative(.f32, @as(f32, 3.0))));
    // 异号
    try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, 1.0)).compare(Float.fromNative(.f32, @as(f32, -1.0))));
    try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, -1.0)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
    // 同号负数
    try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, -3.0)).compare(Float.fromNative(.f32, @as(f32, -1.0))));
    try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, -1.0)).compare(Float.fromNative(.f32, @as(f32, -3.0))));
    // +0 与 -0 视为相等
    try std.testing.expectEqual(.eq, Float.fromNative(.f32, @as(f32, 0.0)).compare(Float.fromNative(.f32, @as(f32, -0.0))));
    // Inf
    try std.testing.expectEqual(.gt, Float.fromNative(.f32, std.math.inf(f32)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
    try std.testing.expectEqual(.lt, Float.fromNative(.f32, -std.math.inf(f32)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
    // NaN 排在末尾
    try std.testing.expectEqual(.gt, Float.fromNative(.f32, std.math.nan(f32)).compare(Float.fromNative(.f32, std.math.inf(f32))));
    try std.testing.expectEqual(.lt, Float.fromNative(.f32, std.math.inf(f32)).compare(Float.fromNative(.f32, std.math.nan(f32))));
    // f64
    try std.testing.expectEqual(.gt, Float.fromNative(.f64, @as(f64, 3.0)).compare(Float.fromNative(.f64, @as(f64, 1.0))));
    // f128
    try std.testing.expectEqual(.lt, Float.fromNative(.f128, @as(f128, -1.0)).compare(Float.fromNative(.f128, @as(f128, 1.0))));
}

test "Float.negate" {
    const cases = [_]struct { in: f32, exp: f32 }{
        .{ .in = 1.0, .exp = -1.0 },
        .{ .in = -3.14, .exp = 3.14 },
        .{ .in = 0.0, .exp = -0.0 },
        .{ .in = -0.0, .exp = 0.0 },
        .{ .in = std.math.inf(f32), .exp = -std.math.inf(f32) },
        .{ .in = -std.math.inf(f32), .exp = std.math.inf(f32) },
    };
    for (cases) |c| {
        const x = Float.fromNative(.f32, c.in);
        const r = x.negate();
        const got: f32 = r.toNative(f32);
        try std.testing.expectEqual(@as(u32, @bitCast(c.exp)), @as(u32, @bitCast(got)));
    }
    // NaN negate: still NaN
    const nan_val = Float.fromNative(.f32, std.math.nan(f32));
    try std.testing.expect(nan_val.negate().isNan());
}

test "Float.add f16 strategic" {
    const min_sub: f16 = std.math.floatMin(f16) / 2;
    const strategic = [_]f16{
        1.0, -1.0, 0.0, -0.0, 0.5, 2.0,
        std.math.floatMax(f16), std.math.floatMin(f16), min_sub,
        std.math.inf(f16), -std.math.inf(f16),
        1.0 + min_sub, 0.1, 65504.0,
    };

    var a_bits: u32 = 0;
    while (a_bits < 65536) : (a_bits += 1) {
        const a_native: f16 = @bitCast(@as(u16, @truncate(a_bits)));
        if (std.math.isNan(a_native)) continue;

        const a = Float.fromNative(.f16, a_native);
        for (strategic) |b_native| {
            if (std.math.isNan(b_native)) continue;
            const b = Float.fromNative(.f16, b_native);

            const native_result = a_native + b_native;
            const custom_result = a.add(b);

            if (std.math.isNan(native_result)) {
                try std.testing.expect(custom_result.isNan());
            } else {
                const native_bits: u16 = @bitCast(native_result);
                const custom_bits: u16 = @bitCast(custom_result.toNative(f16));
                try std.testing.expectEqual(native_bits, custom_bits);
            }
        }
    }
}

test "Float.add f32 boundary" {
    const inf = std.math.inf(f32);
    const max = std.math.floatMax(f32);
    const min_sub: f32 = std.math.floatTrueMin(f32);

    const TestCase = struct { a: f32, b: f32, expect_nan: bool };
    const cases = [_]TestCase{
        .{ .a = inf, .b = inf, .expect_nan = false },
        .{ .a = inf, .b = -inf, .expect_nan = true },
        .{ .a = -inf, .b = inf, .expect_nan = true },
        .{ .a = 0.0, .b = -0.0, .expect_nan = false },
        .{ .a = -0.0, .b = -0.0, .expect_nan = false },
        .{ .a = 1.0, .b = -1.0, .expect_nan = false },
        .{ .a = max, .b = max, .expect_nan = false },
        .{ .a = max, .b = 1.0, .expect_nan = false },
        .{ .a = min_sub, .b = min_sub, .expect_nan = false },
        .{ .a = min_sub, .b = 0.0, .expect_nan = false },
        .{ .a = -max, .b = -max, .expect_nan = false },
        .{ .a = 1.0, .b = min_sub, .expect_nan = false },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const r = a.add(b);
        const native = c.a + c.b;
        if (c.expect_nan) {
            try std.testing.expect(r.isNan());
            try std.testing.expect(std.math.isNan(native));
        } else {
            try std.testing.expectEqual(@as(u32, @bitCast(native)), @as(u32, @bitCast(r.toNative(f32))));
        }
    }
}

test "Float.subtract f32" {
    const inf = std.math.inf(f32);
    const max = std.math.floatMax(f32);

    // inf - inf = NaN
    {
        const a = Float.fromNative(.f32, inf);
        const b = Float.fromNative(.f32, inf);
        try std.testing.expect(a.subtract(b).isNan());
    }
    // 1.0 - 1.0 = +0
    {
        const a = Float.fromNative(.f32, @as(f32, 1.0));
        const b = Float.fromNative(.f32, @as(f32, 1.0));
        const r = a.subtract(b);
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
    }
    // +0 - (-0) = +0
    {
        const a = Float.fromNative(.f32, @as(f32, 0.0));
        const b = Float.fromNative(.f32, @as(f32, -0.0));
        const r = a.subtract(b);
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
    }
    // -0 - (-0) = +0
    {
        const a = Float.fromNative(.f32, @as(f32, -0.0));
        const b = Float.fromNative(.f32, @as(f32, -0.0));
        const r = a.subtract(b);
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
    }
    // max - (-max) = inf
    {
        const a = Float.fromNative(.f32, max);
        const b = Float.fromNative(.f32, -max);
        const r = a.subtract(b);
        try std.testing.expect(r.isInfinite());
        try std.testing.expect(!r.isNegative());
    }
    // 0 - 1.0 = -1.0
    {
        const a = Float.fromNative(.f32, @as(f32, 0.0));
        const b = Float.fromNative(.f32, @as(f32, 1.0));
        const r = a.subtract(b);
        try std.testing.expectEqual(@as(f32, -1.0), r.toNative(f32));
    }
}

test "Float.add f64 sample" {
    const max = std.math.floatMax(f64);
    const min_sub: f64 = std.math.floatMin(f64) / 2;

    const TestCase = struct { a: f64, b: f64 };
    const cases = [_]TestCase{
        .{ .a = 1.0, .b = 2.0 },
        .{ .a = 1e300, .b = 1e300 },
        .{ .a = min_sub, .b = min_sub },
        .{ .a = -1.0, .b = 1.0 },
        .{ .a = max, .b = max },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f64, c.a);
        const b = Float.fromNative(.f64, c.b);
        const r = a.add(b);
        const native = c.a + c.b;
        if (std.math.isNan(native)) {
            try std.testing.expect(r.isNan());
        } else {
            try std.testing.expectEqual(@as(u64, @bitCast(native)), @as(u64, @bitCast(r.toNative(f64))));
        }
    }
}

test "Float.add f128 sample" {
    const one: f128 = 1.0;
    const neg_one: f128 = -1.0;
    const max = std.math.floatMax(f128);
    const min_sub: f128 = std.math.floatMin(f128) / 2;

    const TestCase = struct { a: f128, b: f128 };
    const cases = [_]TestCase{
        .{ .a = one, .b = one },
        .{ .a = neg_one, .b = one },
        .{ .a = max, .b = max },
        .{ .a = min_sub, .b = min_sub },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f128, c.a);
        const b = Float.fromNative(.f128, c.b);
        const r = a.add(b);
        const native = c.a + c.b;
        if (std.math.isNan(native)) {
            try std.testing.expect(r.isNan());
        } else {
            try std.testing.expectEqual(@as(u128, @bitCast(native)), @as(u128, @bitCast(r.toNative(f128))));
        }
    }
}

test "Float.multiply f16 strategic" {
    const min_sub: f16 = std.math.floatMin(f16) / 2;
    const strategic = [_]f16{
        1.0, -1.0, 0.0, -0.0, 0.5, 2.0,
        std.math.floatMax(f16), std.math.floatMin(f16), min_sub,
        std.math.inf(f16), -std.math.inf(f16),
        1.0 + min_sub, 0.1, 65504.0,
    };

    var a_bits: u32 = 0;
    while (a_bits < 65536) : (a_bits += 1) {
        const a_native: f16 = @bitCast(@as(u16, @truncate(a_bits)));
        if (std.math.isNan(a_native)) continue;

        const a = Float.fromNative(.f16, a_native);
        for (strategic) |b_native| {
            if (std.math.isNan(b_native)) continue;
            const b = Float.fromNative(.f16, b_native);

            const native_result = a_native * b_native;
            const custom_result = a.multiply(b);

            if (std.math.isNan(native_result)) {
                try std.testing.expect(custom_result.isNan());
            } else {
                const native_bits: u16 = @bitCast(native_result);
                const custom_bits: u16 = @bitCast(custom_result.toNative(f16));
                try std.testing.expectEqual(native_bits, custom_bits);
            }
        }
    }
}

test "Float.multiply f32 boundary" {
    const inf = std.math.inf(f32);
    const max = std.math.floatMax(f32);
    const min_sub: f32 = std.math.floatTrueMin(f32);

    const TestCase = struct { a: f32, b: f32, expect_nan: bool };
    const cases = [_]TestCase{
        .{ .a = 1.0, .b = 2.0, .expect_nan = false },
        .{ .a = max, .b = 2.0, .expect_nan = false },
        .{ .a = max, .b = max, .expect_nan = false },
        .{ .a = min_sub, .b = 2.0, .expect_nan = false },
        .{ .a = 0.0, .b = inf, .expect_nan = true },
        .{ .a = inf, .b = 0.0, .expect_nan = true },
        .{ .a = inf, .b = inf, .expect_nan = false },
        .{ .a = -1.0, .b = 1.0, .expect_nan = false },
        .{ .a = -max, .b = -max, .expect_nan = false },
        .{ .a = 1e-38, .b = 1e38, .expect_nan = false },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const r = a.multiply(b);
        const native = c.a * c.b;
        if (c.expect_nan) {
            try std.testing.expect(r.isNan());
            try std.testing.expect(std.math.isNan(native));
        } else {
            try std.testing.expectEqual(@as(u32, @bitCast(native)), @as(u32, @bitCast(r.toNative(f32))));
        }
    }
}

test "Float.divide f16 strategic" {
    const min_sub: f16 = std.math.floatMin(f16) / 2;
    const strategic = [_]f16{
        1.0, -1.0, 0.0, -0.0, 0.5, 2.0,
        std.math.floatMax(f16), std.math.floatMin(f16), min_sub,
        std.math.inf(f16), -std.math.inf(f16),
        1.0 + min_sub, 0.1, 65504.0,
    };

    var a_bits: u32 = 0;
    while (a_bits < 65536) : (a_bits += 1) {
        const a_native: f16 = @bitCast(@as(u16, @truncate(a_bits)));
        if (std.math.isNan(a_native)) continue;

        const a = Float.fromNative(.f16, a_native);
        for (strategic) |b_native| {
            if (std.math.isNan(b_native)) continue;
            const b = Float.fromNative(.f16, b_native);

            const native_result = a_native / b_native;
            const custom_result = a.divide(b);

            if (std.math.isNan(native_result)) {
                try std.testing.expect(custom_result.isNan());
            } else if (std.math.isInf(native_result)) {
                try std.testing.expect(custom_result.isInfinite());
                // 符号一致
                try std.testing.expectEqual(std.math.signbit(native_result), custom_result.isNegative());
            } else {
                const native_bits: u16 = @bitCast(native_result);
                const custom_bits: u16 = @bitCast(custom_result.toNative(f16));
                try std.testing.expectEqual(native_bits, custom_bits);
            }
        }
    }
}

test "Float.divide f32 boundary" {
    const inf = std.math.inf(f32);
    const max = std.math.floatMax(f32);
    const min_sub: f32 = std.math.floatTrueMin(f32);

    const TestCase = struct { a: f32, b: f32, expect_nan: bool };
    const cases = [_]TestCase{
        .{ .a = 1.0, .b = 2.0, .expect_nan = false },
        .{ .a = 1.0, .b = 0.0, .expect_nan = false },
        .{ .a = -1.0, .b = 0.0, .expect_nan = false },
        .{ .a = 0.0, .b = 0.0, .expect_nan = true },
        .{ .a = inf, .b = inf, .expect_nan = true },
        .{ .a = inf, .b = 1.0, .expect_nan = false },
        .{ .a = 1.0, .b = inf, .expect_nan = false },
        .{ .a = max, .b = max, .expect_nan = false },
        .{ .a = max, .b = min_sub, .expect_nan = false },
        .{ .a = 1e38, .b = 1e-38, .expect_nan = false },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const r = a.divide(b);
        const native = c.a / c.b;
        if (c.expect_nan) {
            try std.testing.expect(r.isNan());
            try std.testing.expect(std.math.isNan(native));
        } else {
            try std.testing.expectEqual(@as(u32, @bitCast(native)), @as(u32, @bitCast(r.toNative(f32))));
        }
    }
}

test "Float.multiply/divide f64/f128 sample" {
    // f64 multiply
    {
        const TestCase = struct { a: f64, b: f64 };
        const cases = [_]TestCase{
            .{ .a = 1.5, .b = 2.5 },
            .{ .a = 1e300, .b = 1e-300 },
            .{ .a = std.math.floatMax(f64), .b = 10.0 },
        };
        for (cases) |c| {
            const a = Float.fromNative(.f64, c.a);
            const b = Float.fromNative(.f64, c.b);
            const r = a.multiply(b);
            const native = c.a * c.b;
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expectEqual(@as(u64, @bitCast(native)), @as(u64, @bitCast(r.toNative(f64))));
            }
        }
    }
    // f64 divide
    {
        const a = Float.fromNative(.f64, @as(f64, 1.0));
        const b = Float.fromNative(.f64, @as(f64, 3.0));
        const r = a.divide(b);
        const native: f64 = 1.0 / 3.0;
        try std.testing.expectEqual(@as(u64, @bitCast(native)), @as(u64, @bitCast(r.toNative(f64))));
    }
    // f128 multiply
    {
        const one: f128 = 1.0;
        const max = std.math.floatMax(f128);
        const TestCase = struct { a: f128, b: f128 };
        const cases = [_]TestCase{
            .{ .a = one, .b = one },
            .{ .a = max, .b = max },
        };
        for (cases) |c| {
            const a = Float.fromNative(.f128, c.a);
            const b = Float.fromNative(.f128, c.b);
            const r = a.multiply(b);
            const native = c.a * c.b;
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expectEqual(@as(u128, @bitCast(native)), @as(u128, @bitCast(r.toNative(f128))));
            }
        }
    }
    // f128 divide
    {
        const a = Float.fromNative(.f128, @as(f128, 1.0));
        const b = Float.fromNative(.f128, @as(f128, 3.0));
        const r = a.divide(b);
        const native: f128 = 1.0 / 3.0;
        try std.testing.expectEqual(@as(u128, @bitCast(native)), @as(u128, @bitCast(r.toNative(f128))));
    }
}

test "Float.toFloatType f16->f32->f16 roundtrip exhaustive" {
    var bits: u32 = 0;
    while (bits < 65536) : (bits += 1) {
        const v_native: f16 = @bitCast(@as(u16, @truncate(bits)));
        const v = Float.fromNative(.f16, v_native);
        const wide = v.toFloatType(.f32);
        const back = wide.toFloatType(.f16);

        if (std.math.isNan(v_native)) {
            try std.testing.expect(wide.isNan());
            try std.testing.expect(back.isNan());
        } else {
            const native_wide: f32 = @floatCast(v_native);
            const native_back: f16 = @floatCast(native_wide);
            try std.testing.expectEqual(@as(u32, @bitCast(native_wide)), @as(u32, @bitCast(wide.toNative(f32))));
            try std.testing.expectEqual(@as(u16, @bitCast(native_back)), @as(u16, @bitCast(back.toNative(f16))));
        }
    }
}

test "Float.toFloatType f32->f64 widen samples" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    const samples = [_]f32{
        1.0, -1.0, 0.0, -0.0, 1.0 / 3.0,
        std.math.floatMax(f32), std.math.floatMin(f32),
        inf, -inf, nan,
    };
    for (samples) |v| {
        const a = Float.fromNative(.f32, v);
        const wide = a.toFloatType(.f64);
        if (std.math.isNan(v)) {
            try std.testing.expect(wide.isNan());
        } else {
            const native_wide: f64 = @floatCast(v);
            try std.testing.expectEqual(@as(u64, @bitCast(native_wide)), @as(u64, @bitCast(wide.toNative(f64))));
        }
    }
}

test "Float.toInt i64 truncation" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);

    const Case = struct { f: f32, expect_overflow: bool };
    const cases = [_]Case{
        .{ .f = 1.0, .expect_overflow = false },
        .{ .f = -3.7, .expect_overflow = false },
        .{ .f = 3.9, .expect_overflow = false },
        .{ .f = 0.5, .expect_overflow = false },
        .{ .f = -0.0, .expect_overflow = false },
        .{ .f = 1e10, .expect_overflow = false },
        .{ .f = -1e10, .expect_overflow = false },
        .{ .f = std.math.floatMax(f32), .expect_overflow = true },
        .{ .f = inf, .expect_overflow = true },
        .{ .f = nan, .expect_overflow = true },
    };

    for (cases) |c| {
        const v = Float.fromNative(.f32, c.f);
        const result = v.toInt(.i64);
        if (c.expect_overflow) {
            try std.testing.expectError(error.Overflow, result);
        } else {
            const r = try result;
            const native_trunc: f32 = @trunc(c.f);
            const native_val: i64 = @intFromFloat(native_trunc);
            try std.testing.expectEqual(native_val, r.toNative(i64));
        }
    }
}

test "Float.toInt unsigned and narrow boundary" {
    // 负数转无符号 → Overflow
    {
        const v = Float.fromNative(.f32, @as(f32, -1.0));
        try std.testing.expectError(error.Overflow, v.toInt(.u64));
    }
    // 正数转 u64
    {
        const v = Float.fromNative(.f32, @as(f32, 1e10));
        const r = try v.toInt(.u64);
        const native_val: u64 = @intFromFloat(@trunc(@as(f32, 1e10)));
        try std.testing.expectEqual(native_val, r.toNative(u64));
    }
    // 超 i32 范围 → Overflow
    {
        const v = Float.fromNative(.f32, @as(f32, 1e10));
        try std.testing.expectError(error.Overflow, v.toInt(.i32));
    }
    // i32 正常范围
    {
        const v = Float.fromNative(.f32, @as(f32, 42.9));
        const r = try v.toInt(.i32);
        const native_val: i32 = @intFromFloat(@trunc(@as(f32, 42.9)));
        try std.testing.expectEqual(native_val, r.toNative(i32));
    }
}

test "Float.abs/copySign f32" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    const sign_bit: u32 = 1 << 31;

    const samples = [_]f32{
        1.0, -1.0, 0.0, -0.0, 3.14, -3.14,
        std.math.floatMax(f32), std.math.floatMin(f32),
        inf, -inf, nan,
    };

    for (samples) |v| {
        const a = Float.fromNative(.f32, v);

        // abs：清符号位（位运算对照）
        const r_abs = a.abs();
        const native_abs_bits: u32 = @as(u32, @bitCast(v)) & ~sign_bit;
        if (std.math.isNan(v)) {
            try std.testing.expect(r_abs.isNan());
        } else {
            try std.testing.expectEqual(native_abs_bits, @as(u32, @bitCast(r_abs.toNative(f32))));
        }

        // copySign：|self| 带 other 的符号（位运算对照）
        const others = [_]f32{ 1.0, -1.0, 0.0, -0.0, inf, -inf };
        for (others) |o| {
            const r_cs = a.copySign(Float.fromNative(.f32, o));
            const native_cs_bits: u32 = (@as(u32, @bitCast(v)) & ~sign_bit) | (@as(u32, @bitCast(o)) & sign_bit);
            try std.testing.expectEqual(native_cs_bits, @as(u32, @bitCast(r_cs.toNative(f32))));
        }
    }
}

test "Float.nextUp f32 boundary" {
    const inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);
    const max = std.math.floatMax(f32);
    const min_sub: f32 = std.math.floatTrueMin(f32);

    const Case = struct { input: f32, expect_bits: u32 };
    const cases = [_]Case{
        .{ .input = 1.0, .expect_bits = 0x3F800001 },
        .{ .input = -1.0, .expect_bits = 0xBF7FFFFF },
        .{ .input = 0.0, .expect_bits = 0x00000001 },
        .{ .input = -0.0, .expect_bits = 0x00000001 },
        .{ .input = inf, .expect_bits = 0x7F800000 },
        .{ .input = neg_inf, .expect_bits = 0xFF7FFFFF },
        .{ .input = max, .expect_bits = 0x7F800000 },
        .{ .input = -max, .expect_bits = 0xFF7FFFFE },
        .{ .input = min_sub, .expect_bits = 0x00000002 },
        .{ .input = -min_sub, .expect_bits = 0x80000000 },
    };
    for (cases) |c| {
        const v = Float.fromNative(.f32, c.input);
        const r = v.nextUp();
        try std.testing.expectEqual(c.expect_bits, @as(u32, @bitCast(r.toNative(f32))));
    }
}

test "Float.nextDown f32 boundary" {
    const inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);
    const max = std.math.floatMax(f32);
    const min_sub: f32 = std.math.floatTrueMin(f32);

    const Case = struct { input: f32, expect_bits: u32 };
    const cases = [_]Case{
        .{ .input = 1.0, .expect_bits = 0x3F7FFFFF },
        .{ .input = -1.0, .expect_bits = 0xBF800001 },
        .{ .input = 0.0, .expect_bits = 0x80000001 },
        .{ .input = -0.0, .expect_bits = 0x80000001 },
        .{ .input = inf, .expect_bits = 0x7F7FFFFF },
        .{ .input = neg_inf, .expect_bits = 0xFF800000 },
        .{ .input = max, .expect_bits = 0x7F7FFFFE },
        .{ .input = -max, .expect_bits = 0xFF800000 },
        .{ .input = min_sub, .expect_bits = 0x00000000 },
        .{ .input = -min_sub, .expect_bits = 0x80000002 },
    };
    for (cases) |c| {
        const v = Float.fromNative(.f32, c.input);
        const r = v.nextDown();
        try std.testing.expectEqual(c.expect_bits, @as(u32, @bitCast(r.toNative(f32))));
    }
}

test "Float.nextUp/nextDown f16 exhaustive vs std.math.nextAfter" {
    const pos_inf: f16 = std.math.inf(f16);
    const neg_inf: f16 = -std.math.inf(f16);
    var bits: u32 = 0;
    while (bits < 65536) : (bits += 1) {
        const v_native: f16 = @bitCast(@as(u16, @truncate(bits)));
        const v = Float.fromNative(.f16, v_native);

        const up = v.nextUp();
        const native_up: f16 = std.math.nextAfter(f16, v_native, pos_inf);
        if (std.math.isNan(v_native)) {
            try std.testing.expect(up.isNan());
        } else {
            try std.testing.expectEqual(@as(u16, @bitCast(native_up)), @as(u16, @bitCast(up.toNative(f16))));
        }

        const down = v.nextDown();
        const native_down: f16 = std.math.nextAfter(f16, v_native, neg_inf);
        if (std.math.isNan(v_native)) {
            try std.testing.expect(down.isNan());
        } else {
            try std.testing.expectEqual(@as(u16, @bitCast(native_down)), @as(u16, @bitCast(down.toNative(f16))));
        }
    }
}

// —— f8 (e5m2) 测试 ——
// f8 位布局：1 sign + 5 exponent + 2 mantissa，bias=15
// 关键位模式（小端 1 字节，位 7=sign，位 6-2=exp，位 1-0=mantissa）：
//   0x00=+0, 0x80=-0, 0x7C=+inf, 0xFC=-inf, 0x7D=+NaN
//   0x3C=1.0, 0xBC=-1.0, 0x38=0.5, 0x40=2.0, 0x44=4.0
//   0x3D=1.25, 0x3E=1.5, 0x3F=1.75
//   0x7B=max_normal(1.75×2^15), 0x04=min_normal(2^-14)
//   0x01=min_subnormal(2^-16), 0x03=max_subnormal(3×2^-16)

test "Type f8 methods" {
    try std.testing.expectEqual(@as(u8, 1), Type.f8.byteLength());
    try std.testing.expectEqual(@as(u8, 8), Type.f8.bitWidth());
    try std.testing.expectEqual(@as(u8, 5), Type.f8.exponentBits());
    try std.testing.expectEqual(@as(u8, 2), Type.f8.mantissaBits());
    try std.testing.expectEqual(@as(u16, 15), Type.f8.bias());
}

test "Type.fromName f8" {
    try std.testing.expectEqual(@as(?Type, .f8), Type.fromName("f8"));
    try std.testing.expectEqual(@as(?Type, .f16), Type.fromName("f16"));
    try std.testing.expectEqual(@as(?Type, null), Type.fromName("f4"));
}

test "Float f8 fromNative/toNative roundtrip" {
    const cases = [_]u8{ 0x00, 0x80, 0x7C, 0xFC, 0x7D, 0x3C, 0xBC, 0x38, 0x40, 0x44, 0x3D, 0x3E, 0x3F, 0x7B, 0x04, 0x01, 0x03 };
    for (cases) |bits| {
        const v = Float.fromNative(.f8, bits);
        try std.testing.expectEqual(bits, v.toNative(u8));
    }
}

test "Float f8 special values" {
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));
    const neg_zero = Float.fromNative(.f8, @as(u8, 0x80));
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    const neg_inf = Float.fromNative(.f8, @as(u8, 0xFC));
    const pos_nan = Float.fromNative(.f8, @as(u8, 0x7D));
    const one = Float.fromNative(.f8, @as(u8, 0x3C));

    // 零
    try std.testing.expect(pos_zero.isZero());
    try std.testing.expect(!pos_zero.isNegative());
    try std.testing.expect(neg_zero.isZero());
    try std.testing.expect(neg_zero.isNegative());

    // 无穷
    try std.testing.expect(pos_inf.isInfinite());
    try std.testing.expect(!pos_inf.isNan());
    try std.testing.expect(!pos_inf.isNegative());
    try std.testing.expect(neg_inf.isInfinite());
    try std.testing.expect(neg_inf.isNegative());

    // NaN
    try std.testing.expect(pos_nan.isNan());
    try std.testing.expect(!pos_nan.isInfinite());

    // 正规数
    try std.testing.expect(!one.isZero());
    try std.testing.expect(!one.isSubnormal());
    try std.testing.expect(!one.isNegative());
}

test "Float f8 subnormal" {
    const min_sub = Float.fromNative(.f8, @as(u8, 0x01)); // 2^-16
    const max_sub = Float.fromNative(.f8, @as(u8, 0x03)); // 3×2^-16
    const min_normal = Float.fromNative(.f8, @as(u8, 0x04)); // 2^-14

    try std.testing.expect(min_sub.isSubnormal());
    try std.testing.expect(!min_sub.isZero());
    try std.testing.expect(max_sub.isSubnormal());
    try std.testing.expect(!min_normal.isSubnormal());
}

test "Float f8 unpack fields" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const u = one.unpack();
    try std.testing.expectEqual(@as(u1, 0), u.sign);
    try std.testing.expectEqual(@as(u32, 15), u.exp); // bias=15, unbiased=0
    try std.testing.expectEqual(@as(u128, 0), u.mantissa);
    try std.testing.expect(!u.is_nan);
    try std.testing.expect(!u.is_infinite);

    const neg_one = Float.fromNative(.f8, @as(u8, 0xBC));
    const un = neg_one.unpack();
    try std.testing.expectEqual(@as(u1, 1), un.sign);
    try std.testing.expectEqual(@as(u32, 15), un.exp);

    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    const ui = pos_inf.unpack();
    try std.testing.expectEqual(@as(u32, 31), ui.exp); // 全 1
    try std.testing.expect(ui.is_infinite);

    const pos_nan = Float.fromNative(.f8, @as(u8, 0x7D));
    const un2 = pos_nan.unpack();
    try std.testing.expectEqual(@as(u32, 31), un2.exp);
    try std.testing.expect(un2.is_nan);
    try std.testing.expectEqual(@as(u128, 1), un2.mantissa);
}

test "Float f8 compare" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const two = Float.fromNative(.f8, @as(u8, 0x40));
    const neg_one = Float.fromNative(.f8, @as(u8, 0xBC));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));
    const neg_zero = Float.fromNative(.f8, @as(u8, 0x80));
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    const neg_inf = Float.fromNative(.f8, @as(u8, 0xFC));

    try std.testing.expectEqual(.lt, one.compare(two));
    try std.testing.expectEqual(.gt, two.compare(one));
    try std.testing.expectEqual(.eq, one.compare(Float.fromNative(.f8, @as(u8, 0x3C))));
    try std.testing.expectEqual(.gt, one.compare(neg_one));
    try std.testing.expectEqual(.lt, neg_one.compare(one));
    // +0 与 -0 相等
    try std.testing.expectEqual(.eq, pos_zero.compare(neg_zero));
    // Inf
    try std.testing.expectEqual(.gt, pos_inf.compare(one));
    try std.testing.expectEqual(.lt, neg_inf.compare(one));
    try std.testing.expectEqual(.lt, neg_inf.compare(pos_inf));
}

test "Float f8 negate" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const neg_one = one.negate();
    try std.testing.expectEqual(@as(u8, 0xBC), neg_one.toNative(u8));

    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));
    const neg_zero = pos_zero.negate();
    try std.testing.expectEqual(@as(u8, 0x80), neg_zero.toNative(u8));

    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    const neg_inf = pos_inf.negate();
    try std.testing.expectEqual(@as(u8, 0xFC), neg_inf.toNative(u8));
}

test "Float f8 add" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const half = Float.fromNative(.f8, @as(u8, 0x38));
    const neg_one = Float.fromNative(.f8, @as(u8, 0xBC));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));

    // 1.0 + 1.0 = 2.0
    try std.testing.expectEqual(@as(u8, 0x40), one.add(one).toNative(u8));
    // 1.0 + 0.5 = 1.5
    try std.testing.expectEqual(@as(u8, 0x3E), one.add(half).toNative(u8));
    // 1.0 + (-1.0) = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.add(neg_one).toNative(u8));
    // 1.0 + 0 = 1.0
    try std.testing.expectEqual(@as(u8, 0x3C), one.add(pos_zero).toNative(u8));

    // inf + inf = inf
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.add(pos_inf).isInfinite());
    // inf + (-inf) = NaN
    const neg_inf = Float.fromNative(.f8, @as(u8, 0xFC));
    try std.testing.expect(pos_inf.add(neg_inf).isNan());
}

test "Float f8 subtract" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const half = Float.fromNative(.f8, @as(u8, 0x38));

    // 1.0 - 0.5 = 0.5
    try std.testing.expectEqual(@as(u8, 0x38), one.subtract(half).toNative(u8));
    // 1.0 - 1.0 = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.subtract(one).toNative(u8));
}

test "Float f8 multiply" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const two = Float.fromNative(.f8, @as(u8, 0x40));
    const one_point_five = Float.fromNative(.f8, @as(u8, 0x3E));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));

    // 2.0 × 2.0 = 4.0 (0x44)
    try std.testing.expectEqual(@as(u8, 0x44), two.multiply(two).toNative(u8));
    // 1.0 × 1.5 = 1.5
    try std.testing.expectEqual(@as(u8, 0x3E), one.multiply(one_point_five).toNative(u8));
    // 1.0 × 0 = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.multiply(pos_zero).toNative(u8));

    // inf × 0 = NaN
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.multiply(pos_zero).isNan());
    // inf × inf = inf
    try std.testing.expect(pos_inf.multiply(pos_inf).isInfinite());
}

test "Float f8 divide" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const two = Float.fromNative(.f8, @as(u8, 0x40));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));

    // 1.0 / 2.0 = 0.5 (0x38)
    try std.testing.expectEqual(@as(u8, 0x38), one.divide(two).toNative(u8));
    // 2.0 / 2.0 = 1.0
    try std.testing.expectEqual(@as(u8, 0x3C), two.divide(two).toNative(u8));
    // 1.0 / 0.0 = +inf
    try std.testing.expectEqual(@as(u8, 0x7C), one.divide(pos_zero).toNative(u8));
    // 0.0 / 0.0 = NaN
    try std.testing.expect(pos_zero.divide(pos_zero).isNan());

    // inf / inf = NaN
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.divide(pos_inf).isNan());
}

test "Float f8 toFloatType f8->f16 widen" {
    // f8 1.0 (0x3C) -> f16 1.0 (0x3C00)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x3C));
        const wide = v.toFloatType(.f16);
        try std.testing.expectEqual(@as(u16, 0x3C00), @as(u16, @bitCast(wide.toNative(f16))));
    }
    // f8 0.5 (0x38) -> f16 0.5 (0x3800)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x38));
        const wide = v.toFloatType(.f16);
        try std.testing.expectEqual(@as(u16, 0x3800), @as(u16, @bitCast(wide.toNative(f16))));
    }
    // f8 1.5 (0x3E) -> f16 1.5 (0x3E00)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x3E));
        const wide = v.toFloatType(.f16);
        try std.testing.expectEqual(@as(u16, 0x3E00), @as(u16, @bitCast(wide.toNative(f16))));
    }
    // f8 +inf (0x7C) -> f16 +inf (0x7C00)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x7C));
        const wide = v.toFloatType(.f16);
        try std.testing.expect(wide.isInfinite());
        try std.testing.expectEqual(@as(u16, 0x7C00), @as(u16, @bitCast(wide.toNative(f16))));
    }
    // f8 +0 (0x00) -> f16 +0 (0x0000)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x00));
        const wide = v.toFloatType(.f16);
        try std.testing.expectEqual(@as(u16, 0x0000), @as(u16, @bitCast(wide.toNative(f16))));
    }
    // f8 NaN -> f16 NaN
    {
        const v = Float.fromNative(.f8, @as(u8, 0x7D));
        const wide = v.toFloatType(.f16);
        try std.testing.expect(wide.isNan());
    }
}

test "Float f8 toFloatType f16->f8 narrow" {
    // f16 1.0 (0x3C00) -> f8 1.0 (0x3C)
    {
        const v = Float.fromNative(.f16, @as(f16, 1.0));
        const narrow = v.toFloatType(.f8);
        try std.testing.expectEqual(@as(u8, 0x3C), narrow.toNative(u8));
    }
    // f16 0.5 (0x3800) -> f8 0.5 (0x38)
    {
        const v = Float.fromNative(.f16, @as(f16, 0.5));
        const narrow = v.toFloatType(.f8);
        try std.testing.expectEqual(@as(u8, 0x38), narrow.toNative(u8));
    }
    // f16 1.5 (0x3E00) -> f8 1.5 (0x3E)
    {
        const v = Float.fromNative(.f16, @as(f16, 1.5));
        const narrow = v.toFloatType(.f8);
        try std.testing.expectEqual(@as(u8, 0x3E), narrow.toNative(u8));
    }
    // f16 2.0 (0x4000) -> f8 2.0 (0x40)
    {
        const v = Float.fromNative(.f16, @as(f16, 2.0));
        const narrow = v.toFloatType(.f8);
        try std.testing.expectEqual(@as(u8, 0x40), narrow.toNative(u8));
    }
}

test "Float f8 toFloatType roundtrip f8->f16->f8" {
    // 所有非 NaN 的 f8 值经 f16 中转应能还原
    var bits: u16 = 0;
    while (bits < 256) : (bits += 1) {
        const v = Float.fromNative(.f8, @as(u8, @truncate(bits)));
        if (v.isNan()) continue; // NaN 不保证位级还原

        const wide = v.toFloatType(.f16);
        const back = wide.toFloatType(.f8);
        try std.testing.expectEqual(v.toNative(u8), back.toNative(u8));
    }
}

test "Float f8 nextUp/nextDown" {
    // +0 -> min_subnormal (0x01)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x00));
        try std.testing.expectEqual(@as(u8, 0x01), v.nextUp().toNative(u8));
    }
    // 1.0 -> 1.25 (0x3D, 下一个 ulp)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x3C));
        try std.testing.expectEqual(@as(u8, 0x3D), v.nextUp().toNative(u8));
    }
    // max_normal (0x7B) -> +inf (0x7C)
    {
        const v = Float.fromNative(.f8, @as(u8, 0x7B));
        try std.testing.expectEqual(@as(u8, 0x7C), v.nextUp().toNative(u8));
    }
    // +inf -> +inf
    {
        const v = Float.fromNative(.f8, @as(u8, 0x7C));
        try std.testing.expectEqual(@as(u8, 0x7C), v.nextUp().toNative(u8));
    }
    // -inf -> -max_normal (0xFB)
    {
        const v = Float.fromNative(.f8, @as(u8, 0xFC));
        try std.testing.expectEqual(@as(u8, 0xFB), v.nextUp().toNative(u8));
    }
    // nextDown: 1.0 (0x3C) -> 0x3B = 0_01110_11 = 1.75 × 2^-1 = 0.875（1.0 的前驱）
    {
        const v = Float.fromNative(.f8, @as(u8, 0x3C));
        try std.testing.expectEqual(@as(u8, 0x3B), v.nextDown().toNative(u8));
    }
}
