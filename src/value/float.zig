//! 自定义浮点类型——Type 枚举 + Float 结构体（全软件 IEEE 754）
//!
//! 存储布局：{type: Type, bits: u64, extra: u64}
//! - ≤64 位类型（f8/f16/f32/f64）：bits 持 IEEE 754 位模式（右对齐），extra = 0
//! - f128：bits = 128 位模式的低 64 位，extra = 高 64 位（符号位在 extra 的 bit 63）
//!
//! 核心优化：≤64 位类型的符号位判断、negate、abs、compare 等直接用原生 u64 位运算，
//! 绕过旧的 [16]u8 字节缓冲 + loadU128/storeU128 字节拼装开销。
//! f128 委托给 wide.zig 的 U128 软件实现。
//!
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
const wide_lib = @import("wide.zig");
const U128 = wide_lib.U128;
const U256 = wide_lib.U256;
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
    mantissa: U128, // 尾数（不含隐含位；正规数调用方需自行补 1）
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
    mantissa: U128,
    is_nan: bool,
    is_infinite: bool,
    is_zero: bool,

    /// 规格化尾数至 implicit 位 (bit p+3) 置位。
    /// 次正规数的 decompose 不带隐含位（mantissa < 2^(p+3)），左移补齐并同步递减 exp。
    /// 左移不丢失精度（低位本就是 0）；正常数与零为 no-op。
    /// 乘除法在运算前调用，保证乘积 implicit 落在 2p+6、compose 无需左移（sticky 不被移走）。
    pub fn normalize(self: *Decomposed, p: u32) void {
        if (self.is_zero or self.is_nan or self.is_infinite) return;
        const implicit_bit = U128.fromU64(1).shiftLeft(@intCast(p + 3));
        if (self.mantissa.isZero() or self.mantissa.compare(implicit_bit) != .lt) return;
        const clz: u32 = self.mantissa.clz();
        const target_clz: u32 = 128 - (p + 4);
        const sh: u32 = clz - target_clz;
        self.mantissa = self.mantissa.shiftLeft(@intCast(sh));
        self.exp -= @as(i32, @intCast(sh));
    }
};

/// 单一 Float 结构体：type + {bits, extra} + 运算方法
pub const Float = struct {
    type: Type,
    bits: u64,
    extra: u64,

    /// +0.0
    pub fn zero(t: Type) Float {
        return .{ .type = t, .bits = 0, .extra = 0 };
    }

    /// 从原生浮点构造（内存拷贝，不触发原生算术 codegen）
    /// 要求 @sizeOf(@TypeOf(v)) == t.byteLength()
    pub fn fromNative(t: Type, v: anytype) Float {
        const nbytes = t.byteLength();
        if (nbytes <= 8) {
            // ≤64 位：拷贝到 bits 的低字节，高字节为 0
            var result: Float = .{ .type = t, .bits = 0, .extra = 0 };
            const src: [*]const u8 = @ptrCast(&v);
            @memcpy(@as([*]u8, @ptrCast(&result.bits))[0..nbytes], src[0..nbytes]);
            return result;
        } else {
            // f128：memcpy 避免 LLVM i128 codegen bug
            var result: Float = .{ .type = t, .bits = 0, .extra = 0 };
            const src: [*]const u8 = @ptrCast(&v);
            @memcpy(@as([*]u8, @ptrCast(&result.bits))[0..8], src[0..8]);
            @memcpy(@as([*]u8, @ptrCast(&result.extra))[0..8], src[8..16]);
            return result;
        }
    }

    /// 转为原生浮点（内存拷贝）
    pub fn toNative(self: Float, comptime T: type) T {
        var result: T = undefined;
        const dst: [*]u8 = @ptrCast(&result);
        const nbytes = self.type.byteLength();
        if (nbytes <= 8) {
            @memcpy(dst[0..nbytes], @as([*]const u8, @ptrCast(&self.bits))[0..nbytes]);
        } else {
            @memcpy(dst[0..8], @as([*]const u8, @ptrCast(&self.bits))[0..8]);
            @memcpy(dst[8..16], @as([*]const u8, @ptrCast(&self.extra))[0..8]);
        }
        return result;
    }

    /// 转为 f128（正确精度转换，非位拷贝）。任意浮点精度 → f128。
    pub fn asF128(self: Float) f128 {
        if (self.type == .f128) return self.toNative(f128);
        return self.toFloatType(.f128).toNative(f128);
    }

    /// 符号位：true = 负数/负零
    pub inline fn isNegative(self: Float) bool {
        if (self.type.byteLength() <= 8) {
            const sh: u6 = @intCast(self.type.bitWidth() - 1);
            return (self.bits >> sh) & 1 == 1;
        }
        return (self.extra >> 63) & 1 == 1;
    }

    /// 是否为 NaN（指数字段全 1 且尾数字段非 0）
    /// 【优化】≤64 位直接 u64 位运算，避免 unpack 构造 U128 mantissa 开销。
    pub inline fn isNan(self: Float) bool {
        if (self.type.byteLength() <= 8) {
            const mb: u6 = @intCast(self.type.mantissaBits());
            const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
            const sign_mask: u64 = @as(u64, 1) << sign_sh;
            const without_sign = self.bits & ~sign_mask;
            const mant_mask: u64 = if (mb == 64) ~@as(u64, 0) else (@as(u64, 1) << mb) - 1;
            const mantissa_lo = without_sign & mant_mask;
            const exp_field = without_sign >> mb;
            const exp_bits = self.type.exponentBits();
            const max_exp: u64 = (@as(u64, 1) << @intCast(exp_bits)) - 1;
            return exp_field == max_exp and mantissa_lo != 0;
        }
        return self.unpack().is_nan;
    }

    /// 是否为无穷（指数字段全 1 且尾数字段 == 0）
    /// 【优化】≤64 位直接 u64 位运算。
    pub inline fn isInfinite(self: Float) bool {
        if (self.type.byteLength() <= 8) {
            const mb: u6 = @intCast(self.type.mantissaBits());
            const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
            const sign_mask: u64 = @as(u64, 1) << sign_sh;
            const without_sign = self.bits & ~sign_mask;
            const mant_mask: u64 = if (mb == 64) ~@as(u64, 0) else (@as(u64, 1) << mb) - 1;
            const mantissa_lo = without_sign & mant_mask;
            const exp_field = without_sign >> mb;
            const exp_bits = self.type.exponentBits();
            const max_exp: u64 = (@as(u64, 1) << @intCast(exp_bits)) - 1;
            return exp_field == max_exp and mantissa_lo == 0;
        }
        return self.unpack().is_infinite;
    }

    /// 是否为 0（指数 == 0 且尾数 == 0，含 +0 与 -0）
    /// 【优化】≤64 位直接 u64 位运算：无符号位即全 0 判定。
    pub inline fn isZero(self: Float) bool {
        if (self.type.byteLength() <= 8) {
            const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
            const sign_mask: u64 = @as(u64, 1) << sign_sh;
            return (self.bits & ~sign_mask) == 0;
        }
        const u = self.unpack();
        return u.exp == 0 and u.mantissa.isZero();
    }

    /// 是否为次正规数（指数 == 0 且尾数 != 0）
    /// 【优化】≤64 位直接 u64 位运算。
    pub inline fn isSubnormal(self: Float) bool {
        if (self.type.byteLength() <= 8) {
            const mb: u6 = @intCast(self.type.mantissaBits());
            const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
            const sign_mask: u64 = @as(u64, 1) << sign_sh;
            const without_sign = self.bits & ~sign_mask;
            const mant_mask: u64 = if (mb == 64) ~@as(u64, 0) else (@as(u64, 1) << mb) - 1;
            const mantissa_lo = without_sign & mant_mask;
            const exp_field = without_sign >> mb;
            return exp_field == 0 and mantissa_lo != 0;
        }
        const u = self.unpack();
        return u.exp == 0 and (!u.mantissa.isZero());
    }

    /// 解包 IEEE 754 字段
    pub fn unpack(self: Float) Unpacked {
        const t = self.type;
        const exp_bits = t.exponentBits();
        const mant_bits = t.mantissaBits();
        const total_bits = t.bitWidth();
        const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;

        if (total_bits <= 64) {
            // ≤64 位：直接在 u64 上操作，避免 U128 开销
            const sh: u6 = @intCast(total_bits - 1);
            const mb: u6 = @intCast(mant_bits);
            const sign: u1 = @intCast((self.bits >> sh) & 1);
            const sign_mask: u64 = @as(u64, 1) << sh;
            const without_sign = self.bits & ~sign_mask;
            const mant_mask: u64 = if (mant_bits == 64) ~@as(u64, 0) else (@as(u64, 1) << mb) - 1;
            const mantissa_lo = without_sign & mant_mask;
            const exp_field: u32 = @intCast(without_sign >> mb);
            return .{
                .sign = sign,
                .exp = exp_field,
                .mantissa = U128.fromU64(mantissa_lo),
                .is_nan = (exp_field == max_exp) and (mantissa_lo != 0),
                .is_infinite = (exp_field == max_exp) and (mantissa_lo == 0),
            };
        }

        // f128：用 U128
        const raw = U128.fromU64Pair(self.extra, self.bits);
        const sign: u1 = @intCast((self.extra >> 63) & 1);
        const sign_bit = U128.fromU64(1).shiftLeft(127);
        const without_sign = raw.and_(sign_bit.bitwiseNot());
        const mant_mask = U128.mask(@intCast(mant_bits));
        const mantissa = without_sign.and_(mant_mask);
        const exp_field: u32 = @intCast(without_sign.shiftRight(@intCast(mant_bits), false).lo);
        return .{
            .sign = sign,
            .exp = exp_field,
            .mantissa = mantissa,
            .is_nan = (exp_field == max_exp) and (!mantissa.isZero()),
            .is_infinite = (exp_field == max_exp) and (mantissa.isZero()),
        };
    }

    /// IEEE 754 totalOrder 比较：
    /// -NaN < -Inf < ... < -0 < +0 < ... < +Inf < +NaN
    /// 同号 NaN：quiet NaN > signaling NaN（简化为按尾数比较）
    pub inline fn compare(self: Float, other: Float) std.math.Order {
        std.debug.assert(self.type == other.type);
        return comparePortable(self, other);
    }

    /// 注：不标 inline——体积较大（~50 行含 NaN/Inf/符号分支），且测试用 comptime 已知参数
    /// 调用 compare 时会触发全链 comptime 求值超出 1000 分支配额。与 addPortable 等保持一致。
    fn comparePortable(self: Float, other: Float) std.math.Order {
        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 处理：NaN 总是排在边界
        if (ua.is_nan or ub.is_nan) {
            if (ua.is_nan and ub.is_nan) {
                // 同为 NaN：负号在前；同号按尾数（quiet > signaling 简化为尾数大小）
                if (ua.sign != ub.sign) return if (ua.sign == 1) .lt else .gt;
                if (ua.mantissa.compare(ub.mantissa) == .lt) return .lt;
                if (ua.mantissa.compare(ub.mantissa) == .gt) return .gt;
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

        // 同号非零：把位模式当作无符号整数比较，但需翻转符号位
        // 对正数：翻转最高位（让 0x00... 变成 0x80...，正数越大整数越大）
        // 对负数：全部取反（让 0xFF... 变成 0x00...，负数越大整数越小）
        const total_bits = self.type.bitWidth();
        if (total_bits <= 64) {
            // ≤64 位：直接 u64 比较
            const sh: u6 = @intCast(total_bits - 1);
            const sign_bit: u64 = @as(u64, 1) << sh;
            var va = self.bits;
            var vb = other.bits;
            if (ua.sign == 1) {
                va = ~va;
                vb = ~vb;
            } else {
                va ^= sign_bit;
                vb ^= sign_bit;
            }
            if (va < vb) return .lt;
            if (va > vb) return .gt;
            return .eq;
        }

        // f128：用 U128
        var va = U128.fromU64Pair(self.extra, self.bits);
        var vb = U128.fromU64Pair(other.extra, other.bits);
        if (ua.sign == 1) {
            va = va.bitwiseNot();
            vb = vb.bitwiseNot();
        } else {
            const sign_bit = U128.fromU64(1).shiftLeft(127);
            va = va.xor_(sign_bit);
            vb = vb.xor_(sign_bit);
        }
        return va.compare(vb);
    }

    // —— 加减法（S9 实现）——

    /// 解包为数学含义（unbiased 指数 + 含隐含位尾数 + GRS 预留）
    fn decompose(self: Float) Decomposed {
        const u = self.unpack();
        const t = self.type;
        const p = t.mantissaBits();
        const bias: i32 = @intCast(t.bias());

        if (u.is_nan) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = U128.zero(), .is_nan = true, .is_infinite = false, .is_zero = false };
        }
        if (u.is_infinite) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = U128.zero(), .is_nan = false, .is_infinite = true, .is_zero = false };
        }
        if (u.exp == 0 and u.mantissa.isZero()) {
            return .{ .sign = u.sign, .exp = 0, .mantissa = U128.zero(), .is_nan = false, .is_infinite = false, .is_zero = true };
        }

        var m: U128 = u.mantissa;
        var e: i32 = 0;
        if (u.exp == 0) {
            // 次正规数：无隐含位，exp = 1 - bias
            e = 1 - bias;
        } else {
            // 正规数：补隐含位，exp = exp_field - bias
            m = m.orBit(p);
            e = @as(i32, @intCast(u.exp)) - bias;
        }
        m = m.shiftLeft(3); // 左移 3 位预留 GRS
        return .{ .sign = u.sign, .exp = e, .mantissa = m, .is_nan = false, .is_infinite = false, .is_zero = false };
    }

    /// 取负（翻转符号位）。NaN 的符号位也翻转。
    pub inline fn negate(self: Float) Float {
        var result = self;
        if (self.type.byteLength() <= 8) {
            const sh: u6 = @intCast(self.type.bitWidth() - 1);
            result.bits ^= (@as(u64, 1) << sh);
        } else {
            result.extra ^= (@as(u64, 1) << 63);
        }
        return result;
    }

    /// 加法。
    /// NaN/Inf 结果触发 @panic（项目约束：浮点运算不得产生 NaN/Infinity）。
    pub inline fn add(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        return checkResult(addPortable(self, other));
    }

    fn addPortable(self: Float, other: Float) Float {
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
        const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
        const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
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
        db.mantissa = db.mantissa.shiftRightWithSticky(shift);

        // 尾数加减
        var mr: U128 = undefined;
        var sr: u1 = undefined;
        if (da.sign == db.sign) {
            mr = da.mantissa.add(db.mantissa).sum;
            sr = da.sign;
        } else {
            if (da.mantissa.compare(db.mantissa) != .lt) {
                mr = da.mantissa.sub(db.mantissa).diff;
                sr = da.sign;
            } else {
                mr = db.mantissa.sub(da.mantissa).diff;
                sr = db.sign;
            }
        }

        // x + (-x) = +0（RNE 模式下零结果恒为 +0）
        if (mr.isZero()) return makeZero(t, 0);

        return compose(t, sr, da.exp, mr);
    }

    /// 减法。
    /// NaN/Inf 结果触发 @panic。
    pub inline fn subtract(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        return checkResult(subtractPortable(self, other));
    }

    /// 等价于 addPortable(other.negate())
    fn subtractPortable(self: Float, other: Float) Float {
        return self.addPortable(other.negate());
    }

    /// 乘法。
    /// NaN/Inf 结果触发 @panic。
    pub inline fn multiply(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        return checkResult(multiplyPortable(self, other));
    }

    fn multiplyPortable(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const p: u32 = t.mantissaBits();

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 传播
        if (ua.is_nan or ub.is_nan) return makeNan(t);

        const a_inf = ua.is_infinite;
        const b_inf = ub.is_infinite;
        const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
        const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
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
        const product: U256 = da.mantissa.multiply(db.mantissa);

        // 乘积 implicit 在 bit 2p+6；检查进位 bit 2p+7
        const carry_pos: u32 = 2 * p + 7;
        var shifted = product;
        if (shifted.bit(carry_pos)) {
            // {hi, lo} 整体右移 1，最低位 OR 进 sticky
            shifted = shifted.shiftRight1WithSticky();
            result_exp += 1;
        }

        // 提取 bits [p+3, 2p+6) 到 mant：implicit 落在 p+3
        // mant = (product >> (p+3)) 的低 128 位
        const low_width: u32 = p + 3; // ≤ 115 < 128
        const mant: U128 = shifted.extractU128(low_width);
        // sticky：product bits [0, p+3) 非 0
        const low_bits_nonzero = shifted.lo.lowBitsNonZero(low_width);
        var result_mant = mant;
        if (low_bits_nonzero) result_mant = result_mant.orBit(0);

        return compose(t, result_sign, result_exp, result_mant);
    }

    /// 除法。
    /// NaN/Inf 结果触发 @panic（含 finite/0=Inf、0/0=NaN）。
    pub inline fn divide(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        return checkResult(dividePortable(self, other));
    }

    /// 除零不报错：finite/0 = Inf，0/0 = NaN（IEEE 754 语义）。
    fn dividePortable(self: Float, other: Float) Float {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const p: u32 = t.mantissaBits();

        const ua = self.unpack();
        const ub = other.unpack();

        // NaN 传播
        if (ua.is_nan or ub.is_nan) return makeNan(t);

        const a_inf = ua.is_infinite;
        const b_inf = ub.is_infinite;
        const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
        const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
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
        const dividend: U256 = da.mantissa.shiftLeftWide(@intCast(shift));

        const div_result = dividend.divideByU128(db.mantissa);
        var quotient: U128 = div_result.quotient;
        const remainder: U128 = div_result.remainder;

        // 商范围 [2^(p+2), 2^(p+4))；若 < 2^(p+3)（implicit 在 p+2）：左移 1，exp -= 1
        const implicit_bit: U128 = U128.fromU64(1).shiftLeft(@intCast(p + 3));
        if (quotient.compare(implicit_bit) == .lt) {
            quotient = quotient.shiftLeft(1);
            result_exp -= 1;
        }

        // sticky：余数非 0 → bit 0
        if (!remainder.isZero()) quotient = quotient.orBit(0);

        return compose(t, result_sign, result_exp, quotient);
    }

    /// 转换到另一精度的 Float（如 f32 → f64）。全软件：解包 → 重新打包。
    /// NaN/Inf 用目标类型重建；零/次正规/正规走 decompose → 对齐 → compose。
    pub inline fn toFloatType(self: Float, target: Type) Float {
        if (target == self.type) return self;
        const u = self.unpack();
        if (u.is_nan) return makeNan(target);
        if (u.is_infinite) return makeInf(target, u.sign);
        if (u.exp == 0 and u.mantissa.isZero()) return makeZero(target, u.sign);

        const p_self: u32 = self.type.mantissaBits();
        const p_target: u32 = target.mantissaBits();

        var da = self.decompose();
        da.normalize(p_self); // 规格化至 implicit 在 p_self+3（次正规补隐含位），值不变

        // 对齐 implicit 至 p_target+3：value = m × 2^(exp - (p+3))，移位不改变 exp
        var m = da.mantissa;
        if (p_self > p_target) {
            m = m.shiftRightWithSticky(p_self - p_target);
        } else if (p_target > p_self) {
            m = m.shiftLeft(@intCast(p_target - p_self));
        }
        return compose(target, da.sign, da.exp, m);
    }

    /// 转换为 Int（向零截断，IEEE 754 convertToIntegerTiesToZero）。
    /// NaN/Inf 或超出 target 范围 → error.Overflow。
    pub fn toInt(self: Float, target: int.Type) error{Overflow}!int.Int {
        const t = self.type;
        const u = self.unpack();
        if (u.is_nan or u.is_infinite) return error.Overflow;
        if (u.exp == 0 and u.mantissa.isZero()) return int.Int.zero(target);

        const p: u32 = t.mantissaBits();
        var da = self.decompose();
        da.normalize(p); // 规格化，da.mantissa 低 3 位为 0（GRS 占位）

        // |value| = da.mantissa × 2^frac_shift，向零截断 = floor(|value|)
        const frac_shift: i32 = da.exp - @as(i32, @intCast(p + 3));
        var mag: U128 = da.mantissa;

        if (frac_shift >= 0) {
            const sh: u32 = @intCast(frac_shift);
            if (sh >= 128) return error.Overflow;
            if (sh > 0) {
                // 检查高 sh 位是否非零（左移会溢出 U128）
                if (!mag.shiftRight(@intCast(128 - sh), false).isZero()) return error.Overflow;
                mag = mag.shiftLeft(@intCast(sh));
            }
        } else {
            const sh: u32 = @intCast(-frac_shift);
            if (sh >= 128) {
                mag = U128.zero();
            } else {
                mag = mag.shiftRight(@intCast(sh), false);
            }
        }

        const bits: u32 = target.bitWidth();
        if (da.sign == 0) {
            // 正数
            const max_mag: U128 = if (target.isSigned())
                U128.mask(@intCast(bits - 1))
            else if (bits == 128)
                U128.mask(128)
            else
                U128.mask(@intCast(bits));
            if (mag.compare(max_mag) == .gt) return error.Overflow;
            return int.Int.fromU128Unchecked(target, mag);
        } else {
            // 负数：两补 = -mag
            if (!target.isSigned()) return error.Overflow;
            const max_mag: U128 = U128.fromU64(1).shiftLeft(@intCast(bits - 1));
            if (mag.compare(max_mag) == .gt) return error.Overflow;
            const neg: U128 = mag.negate();
            return int.Int.fromU128Unchecked(target, neg);
        }
    }

    /// 从整数构造浮点数（全软件，不丢精度）。
    /// 整数值 = magnitude × 2^0，规格化为 1.xxx × 2^bit_pos 后用 compose 打包。
    /// 对阶时左移不丢精度（低位本就是 0），右移用 shiftRightWithSticky 保留舍入信息。
    /// 大整数转低精度浮点（如 i128→f32）会按 RNE 舍入，这是正确的语义行为。
    pub fn fromInt(target: Type, iv: int.Int) Float {
        const is_neg = iv.isNegative();

        // 构造 128 位补码值，负数取绝对值（U128 两补 negate）
        var mag: U128 = undefined;
        if (iv.type.byteLength() <= 8) {
            // ≤64 位：lo 已符号/零扩展到 u64。负数需把 hi 补为全 1 以构成 128 位补码
            if (iv.type.isSigned() and (iv.lo >> 63) & 1 == 1) {
                mag = U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, iv.lo);
            } else {
                mag = U128.fromU64(iv.lo);
            }
        } else {
            // 128 位：{hi, lo} 直接构成 U128
            mag = U128.fromU64Pair(iv.hi, iv.lo);
        }
        if (is_neg) mag = mag.negate();
        if (mag.isZero()) return makeZero(target, 0);

        const sign: u1 = if (is_neg) 1 else 0;
        const p: u32 = target.mantissaBits();
        const leading_zeros: u32 = mag.clz();
        const bit_pos: i32 = 127 - @as(i32, @intCast(leading_zeros));

        // 对齐尾数：隐含位需在 bit (p+3)，GRS 在 bit 0-2
        const target_pos: i32 = @as(i32, @intCast(p)) + 3;
        var mantissa = mag;
        if (bit_pos < target_pos) {
            const sh: u8 = @intCast(target_pos - bit_pos);
            mantissa = mantissa.shiftLeft(sh);
        } else if (bit_pos > target_pos) {
            const sh: u32 = @intCast(bit_pos - target_pos);
            mantissa = mantissa.shiftRightWithSticky(sh);
        }

        return compose(target, sign, bit_pos, mantissa);
    }

    /// 绝对值（清符号位）。NaN 符号位也清零（与 Zig @abs 一致）。
    pub fn abs(self: Float) Float {
        var result = self;
        if (self.type.byteLength() <= 8) {
            const sh: u6 = @intCast(self.type.bitWidth() - 1);
            result.bits &= ~(@as(u64, 1) << sh);
        } else {
            result.extra &= ~(@as(u64, 1) << 63);
        }
        return result;
    }

    /// 十进制格式化：将 self 写入 buf，返回写入的切片。
    /// 全软件：f8/f16/f32/f64 无损宽化到 f64 后用原生 {d}（shortest round-trip，不丢精度）；
    /// f128 软件分解整数/小数部分格式化（不丢精度）。
    /// buf 需至少 80 字节（符号 + 整数 39 位 + 小数点 + 小数 34 位）。
    pub fn formatDecimal(self: Float, buf: []u8) []const u8 {
        const t = self.type;

        // 特殊值
        if (self.isNan()) return "nan";
        if (self.isInfinite()) return if (self.isNegative()) "-inf" else "inf";
        if (self.isZero()) return if (self.isNegative()) "-0" else "0";

        // 非 f128：无损宽化到 f64 后用原生 {d}（不丢精度）
        if (t != .f128) {
            const fv = self.toFloatType(.f64).toNative(f64);
            return std.fmt.bufPrint(buf, "{d}", .{fv}) catch unreachable;
        }

        // f128 软件格式化
        const neg = self.isNegative();
        const abs_val = if (neg) self.negate() else self;
        const sign_str: []const u8 = if (neg) "-" else "";

        // 整数部分（溢出 → 十六进制科学计数法）
        const int_part = abs_val.toInt(.i128) catch {
            const u = abs_val.unpack();
            const unbiased: i32 = @as(i32, @intCast(u.exp)) - @as(i32, @intCast(t.bias()));
            const p: u32 = t.mantissaBits();
            const hex_digits: usize = (p + 3) / 4;
            var mant_hex: [32]u8 = undefined;
            var m = u.mantissa.orBit(@intCast(p));
            var i: usize = hex_digits;
            while (i > 0) : (i -= 1) {
                const digit: u8 = @truncate(m.lo & 0xF);
                mant_hex[i - 1] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
                m = m.shiftRight(4, false);
            }
            var exp_buf: [16]u8 = undefined;
            const exp_str = std.fmt.bufPrint(&exp_buf, "{d}", .{unbiased}) catch unreachable;
            return std.fmt.bufPrint(buf, "{s}0x1.{s}p{s}", .{ sign_str, mant_hex[0..hex_digits], exp_str }) catch unreachable;
        };

        // 格式化整数部分
        var int_buf: [41]u8 = undefined;
        const int_str = int_part.formatDecimal(&int_buf);

        // 计算小数部分：remainder = abs_val - fromInt(int_part)
        const int_float = Float.fromInt(.f128, int_part);
        var remainder = abs_val.subtract(int_float);
        if (remainder.isNegative()) remainder = remainder.negate();

        if (remainder.isZero()) {
            return std.fmt.bufPrint(buf, "{s}{s}", .{ sign_str, int_str }) catch unreachable;
        }

        // 反复乘 10 提取小数位（f128 约 34 位有效十进制）
        var frac_buf: [40]u8 = undefined;
        var frac_pos: usize = 0;
        const ten = Float.fromInt(.f128, int.Int.fromNative(.i64, @as(i64, 10)));
        while (frac_pos < 34 and !remainder.isZero()) {
            remainder = remainder.multiply(ten);
            const digit_int = remainder.toInt(.i8) catch break;
            const d: u8 = digit_int.toNative(u8);
            frac_buf[frac_pos] = '0' + d;
            frac_pos += 1;
            const digit_float = Float.fromInt(.f128, int.Int.fromNative(.i8, @as(i8, @bitCast(d))));
            remainder = remainder.subtract(digit_float);
            if (remainder.isNegative()) remainder = remainder.negate();
        }

        return std.fmt.bufPrint(buf, "{s}{s}.{s}", .{ sign_str, int_str, frac_buf[0..frac_pos] }) catch unreachable;
    }

    /// 复制符号位：返回 |self| 带 other 的符号。
    pub fn copySign(self: Float, other: Float) Float {
        var result = self;
        const other_neg = other.isNegative();
        if (self.type.byteLength() <= 8) {
            const sh: u6 = @intCast(self.type.bitWidth() - 1);
            const sign_bit: u64 = @as(u64, 1) << sh;
            result.bits = (result.bits & ~sign_bit) | (if (other_neg) sign_bit else 0);
        } else {
            const sign_bit: u64 = @as(u64, 1) << 63;
            result.extra = (result.extra & ~sign_bit) | (if (other_neg) sign_bit else 0);
        }
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
            const max_frac: U128 = U128.mask(@intCast(p));
            return packBytes(t, 1, max_exp - 1, max_frac);
        }

        const total_bits = t.bitWidth();
        if (total_bits <= 64) {
            // ≤64 位：直接 u64 运算
            const sh: u6 = @intCast(total_bits - 1);
            const sign_bit: u64 = @as(u64, 1) << sh;
            // ±0 → +min_subnormal
            if (self.bits == 0 or self.bits == sign_bit) {
                return packBytes(t, 0, 0, U128.fromU64(1));
            }
            var b = self.bits;
            if (u.sign == 0) {
                b +%= 1; // 正数 +1 ulp
            } else {
                b -%= 1; // 负数 -1 ulp（向 0，值变大）
            }
            return .{ .type = t, .bits = b, .extra = 0 };
        }

        // f128：用 U128
        var bits = U128.fromU64Pair(self.extra, self.bits);
        const sign_bit = U128.fromU64(1).shiftLeft(127);
        // ±0 → +min_subnormal
        if (bits.isZero() or bits.equals(sign_bit)) {
            return packBytes(t, 0, 0, U128.fromU64(1));
        }
        if (u.sign == 0) {
            bits = bits.add(U128.fromU64(1)).sum; // 正数 +1 ulp
        } else {
            bits = bits.sub(U128.fromU64(1)).diff; // 负数 -1 ulp（向 0，值变大）
        }
        return packRawBits(t, bits);
    }

    /// 向下一步（nextDown）：返回小于 self 的最大 Float。
    /// 等价于 -nextUp(-self)。
    pub fn nextDown(self: Float) Float {
        return self.negate().nextUp().negate();
    }
};

/// 检查软件实现的结果，NaN/Inf 触发 @panic
fn checkResult(result: Float) Float {
    if (result.isNan()) @panic("float operation produced NaN");
    if (result.isInfinite()) @panic("float operation produced Infinity");
    return result;
}

/// 构造零（指定符号）
fn makeZero(t: Type, sign: u1) Float {
    if (t.byteLength() <= 8) {
        const sh: u6 = @intCast(t.bitWidth() - 1);
        const bits: u64 = if (sign == 1) @as(u64, 1) << sh else 0;
        return .{ .type = t, .bits = bits, .extra = 0 };
    }
    const extra: u64 = if (sign == 1) @as(u64, 1) << 63 else 0;
    return .{ .type = t, .bits = 0, .extra = extra };
}

/// 构造无穷（指定符号）
fn makeInf(t: Type, sign: u1) Float {
    const exp_bits = t.exponentBits();
    const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
    return packBytes(t, sign, max_exp, U128.zero());
}

/// 构造 NaN（canonical quiet NaN：sign=0, exp=全1, mantissa=1）
fn makeNan(t: Type) Float {
    const exp_bits = t.exponentBits();
    const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
    return packBytes(t, 0, max_exp, U128.fromU64(1));
}

/// 从 sign/stored_exp/fraction 打包为 Float
fn packBytes(t: Type, sign: u1, stored_exp: u32, fraction: U128) Float {
    const p = t.mantissaBits();
    const total_bits = t.bitWidth();
    if (total_bits <= 64) {
        // ≤64 位：直接在 u64 上拼装
        const sh: u6 = @intCast(total_bits - 1);
        const mb: u6 = @intCast(p);
        var raw: u64 = fraction.lo | (@as(u64, stored_exp) << mb);
        if (sign == 1) raw |= (@as(u64, 1) << sh);
        return .{ .type = t, .bits = raw, .extra = 0 };
    }
    // f128
    var raw: U128 = fraction;
    raw = raw.or_(U128.fromU64(stored_exp).shiftLeft(@intCast(p)));
    if (sign == 1) raw = raw.orBit(127);
    return .{ .type = t, .bits = raw.lo, .extra = raw.hi };
}

/// 从原始位模式（U128）打包为 Float
fn packRawBits(t: Type, bits: U128) Float {
    if (t.byteLength() <= 8) {
        return .{ .type = t, .bits = bits.lo, .extra = 0 };
    }
    return .{ .type = t, .bits = bits.lo, .extra = bits.hi };
}

/// 从 sign/unbiased exp/含 GRS 的尾数 打包为 Float
/// 处理规格化 + RNE 舍入 + 范围判定（上溢→Inf，下溢→次正规/零）
fn compose(t: Type, sign: u1, exp: i32, mantissa: U128) Float {
    const p: u32 = t.mantissaBits();
    const bias: i32 = @intCast(t.bias());
    const exp_bits = t.exponentBits();
    const max_exp_field: i32 = (@as(i32, 1) << @intCast(exp_bits)) - 1;

    var m = mantissa;
    var e = exp;

    if (m.isZero()) return makeZero(t, sign);

    const implicit_bit: U128 = U128.fromU64(1).shiftLeft(@intCast(p + 3));
    const carry_bit: U128 = U128.fromU64(1).shiftLeft(@intCast(p + 4));

    // 处理加法进位（bit p+4 置位）
    if (m.compare(carry_bit) != .lt) {
        m = m.shiftRightWithSticky(1);
        e += 1;
    }

    // 规格化：左移至 bit (p+3) 置位
    if (!m.isZero() and m.compare(implicit_bit) == .lt) {
        const clz_m: u8 = m.clz();
        const target_clz: u8 = @intCast(128 - p - 4);
        const shift_amt: u8 = clz_m - target_clz;
        m = m.shiftLeft(shift_amt);
        e -= @as(i32, shift_amt);
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
        m = m.shiftRightWithSticky(shift);
        stored_exp = 0;
    }

    // RNE 舍入（round-to-nearest-even）
    // GRS 位布局：bit 3 = LSB（保留位），bit 2 = guard，bit 1 = round，bit 0 = sticky
    const g = m.testBit(2);
    const r = m.testBit(1);
    const s = m.testBit(0);
    const lsb_set = m.testBit(3);

    // 清除低 3 位（GRS）
    var rounded = m.and_(U128.fromU64(7).bitwiseNot());
    if (g and (r or s or lsb_set)) {
        rounded = rounded.add(U128.fromU64(8)).sum;
    }
    m = rounded;

    // 舍入后溢出检查
    if (stored_exp == 0) {
        // 次正规：舍入后若 bit (p+3) 置位 → 升格为最小正规数
        if (m.testBit(@intCast(p + 3))) {
            stored_exp = 1;
        }
    } else {
        // 正规：舍入后若 bit (p+4) 置位 → 右移 + stored_exp+1
        if (m.testBit(@intCast(p + 4))) {
            m = m.shiftRight(1, false);
            stored_exp += 1;
            if (stored_exp >= max_exp_field) {
                return makeInf(t, sign);
            }
        }
    }

    const fraction_mask: U128 = U128.mask(@intCast(p));
    const fraction: U128 = m.shiftRight(3, false).and_(fraction_mask);

    return packBytes(t, sign, @intCast(stored_exp), fraction);
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

            if (std.math.isNan(native_result) or std.math.isInf(native_result)) {
                // NaN/Inf 结果走 addPortable（算法正确性），add 会 panic
                const custom_result = a.addPortable(b);
                if (std.math.isNan(native_result)) {
                    try std.testing.expect(custom_result.isNan());
                } else {
                    try std.testing.expect(custom_result.isInfinite());
                }
            } else {
                const custom_result = a.add(b);
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

    const TestCase = struct { a: f32, b: f32 };
    const cases = [_]TestCase{
        .{ .a = inf, .b = inf },
        .{ .a = inf, .b = -inf },
        .{ .a = -inf, .b = inf },
        .{ .a = 0.0, .b = -0.0 },
        .{ .a = -0.0, .b = -0.0 },
        .{ .a = 1.0, .b = -1.0 },
        .{ .a = max, .b = max },
        .{ .a = max, .b = 1.0 },
        .{ .a = min_sub, .b = min_sub },
        .{ .a = min_sub, .b = 0.0 },
        .{ .a = -max, .b = -max },
        .{ .a = 1.0, .b = min_sub },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const native = c.a + c.b;

        if (std.math.isNan(native) or std.math.isInf(native)) {
            // NaN/Inf 结果走 addPortable（算法正确性）
            const r = a.addPortable(b);
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expect(r.isInfinite());
            }
        } else {
            const r = a.add(b);
            try std.testing.expectEqual(@as(u32, @bitCast(native)), @as(u32, @bitCast(r.toNative(f32))));
        }
    }
}

test "Float.subtract f32" {
    const inf = std.math.inf(f32);
    const max = std.math.floatMax(f32);

    // inf - inf = NaN（走 subtractPortable，subtract 会 panic）
    {
        const a = Float.fromNative(.f32, inf);
        const b = Float.fromNative(.f32, inf);
        try std.testing.expect(a.subtractPortable(b).isNan());
    }
    // 1.0 - 1.0 = +0（有限结果走 subtract）
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
    // max - (-max) = inf（走 subtractPortable）
    {
        const a = Float.fromNative(.f32, max);
        const b = Float.fromNative(.f32, -max);
        const r = a.subtractPortable(b);
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
        const native = c.a + c.b;
        if (std.math.isNan(native) or std.math.isInf(native)) {
            const r = a.addPortable(b);
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expect(r.isInfinite());
            }
        } else {
            const r = a.add(b);
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
        const native = c.a + c.b;
        if (std.math.isNan(native) or std.math.isInf(native)) {
            const r = a.addPortable(b);
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expect(r.isInfinite());
            }
        } else {
            const r = a.add(b);
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

            if (std.math.isNan(native_result) or std.math.isInf(native_result)) {
                const custom_result = a.multiplyPortable(b);
                if (std.math.isNan(native_result)) {
                    try std.testing.expect(custom_result.isNan());
                } else {
                    try std.testing.expect(custom_result.isInfinite());
                }
            } else {
                const custom_result = a.multiply(b);
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

    const TestCase = struct { a: f32, b: f32 };
    const cases = [_]TestCase{
        .{ .a = 1.0, .b = 2.0 },
        .{ .a = max, .b = 2.0 },
        .{ .a = max, .b = max },
        .{ .a = min_sub, .b = 2.0 },
        .{ .a = 0.0, .b = inf },
        .{ .a = inf, .b = 0.0 },
        .{ .a = inf, .b = inf },
        .{ .a = -1.0, .b = 1.0 },
        .{ .a = -max, .b = -max },
        .{ .a = 1e-38, .b = 1e38 },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const native = c.a * c.b;
        if (std.math.isNan(native) or std.math.isInf(native)) {
            const r = a.multiplyPortable(b);
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expect(r.isInfinite());
            }
        } else {
            const r = a.multiply(b);
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

            if (std.math.isNan(native_result) or std.math.isInf(native_result)) {
                const custom_result = a.dividePortable(b);
                if (std.math.isNan(native_result)) {
                    try std.testing.expect(custom_result.isNan());
                } else {
                    try std.testing.expect(custom_result.isInfinite());
                    try std.testing.expectEqual(std.math.signbit(native_result), custom_result.isNegative());
                }
            } else {
                const custom_result = a.divide(b);
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

    const TestCase = struct { a: f32, b: f32 };
    const cases = [_]TestCase{
        .{ .a = 1.0, .b = 2.0 },
        .{ .a = 1.0, .b = 0.0 },
        .{ .a = -1.0, .b = 0.0 },
        .{ .a = 0.0, .b = 0.0 },
        .{ .a = inf, .b = inf },
        .{ .a = inf, .b = 1.0 },
        .{ .a = 1.0, .b = inf },
        .{ .a = max, .b = max },
        .{ .a = max, .b = min_sub },
        .{ .a = 1e38, .b = 1e-38 },
    };

    for (cases) |c| {
        const a = Float.fromNative(.f32, c.a);
        const b = Float.fromNative(.f32, c.b);
        const native = c.a / c.b;
        if (std.math.isNan(native) or std.math.isInf(native)) {
            const r = a.dividePortable(b);
            if (std.math.isNan(native)) {
                try std.testing.expect(r.isNan());
            } else {
                try std.testing.expect(r.isInfinite());
            }
        } else {
            const r = a.divide(b);
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
            const native = c.a * c.b;
            if (std.math.isNan(native) or std.math.isInf(native)) {
                const r = a.multiplyPortable(b);
                if (std.math.isNan(native)) {
                    try std.testing.expect(r.isNan());
                } else {
                    try std.testing.expect(r.isInfinite());
                }
            } else {
                const r = a.multiply(b);
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
            const native = c.a * c.b;
            if (std.math.isNan(native) or std.math.isInf(native)) {
                const r = a.multiplyPortable(b);
                if (std.math.isNan(native)) {
                    try std.testing.expect(r.isNan());
                } else {
                    try std.testing.expect(r.isInfinite());
                }
            } else {
                const r = a.multiply(b);
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

test "Float.toInt i128 truncation and overflow" {
    // F5: doArithFloat 浮点取模溢出检测依赖 Float.toInt(.i128) 在商超出 i128 范围时返回 Overflow。
    // 此测试验证该路径：极大商（1e50 / 1.0 = 1e50）超出 i128 max (~1.7e38)。

    // 正常范围：1e10 截断为 i128
    {
        const v = Float.fromNative(.f64, @as(f64, 1e10));
        const r = try v.toInt(.i128);
        try std.testing.expectEqual(@as(i128, 10_000_000_000), r.toNative(i128));
    }
    // 负数正常范围
    {
        const v = Float.fromNative(.f64, @as(f64, -1e10));
        const r = try v.toInt(.i128);
        try std.testing.expectEqual(@as(i128, -10_000_000_000), r.toNative(i128));
    }
    // i128 边界内（接近 max，i128 max ≈ 1.7e38）
    // 不用 @intFromFloat 对照以避免 LLVM i128 codegen bug
    {
        const v = Float.fromNative(.f64, @as(f64, 1e38));
        const r = try v.toInt(.i128);
        try std.testing.expect(!r.isNegative());
    }
    // 超出 i128 范围 → Overflow（F5 核心场景：取模商溢出）
    {
        const v = Float.fromNative(.f64, @as(f64, 1e50));
        try std.testing.expectError(error.Overflow, v.toInt(.i128));
    }
    {
        const v = Float.fromNative(.f64, @as(f64, -1e50));
        try std.testing.expectError(error.Overflow, v.toInt(.i128));
    }
    // Inf/NaN → Overflow
    {
        const v = Float.fromNative(.f64, std.math.inf(f64));
        try std.testing.expectError(error.Overflow, v.toInt(.i128));
    }
    {
        const v = Float.fromNative(.f64, std.math.nan(f64));
        try std.testing.expectError(error.Overflow, v.toInt(.i128));
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
    try std.testing.expect(u.mantissa.isZero());
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
    try std.testing.expect(un2.mantissa.equals(U128.fromU64(1)));
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

    // 1.0 + 1.0 = 2.0（有限结果走 add）
    try std.testing.expectEqual(@as(u8, 0x40), one.add(one).toNative(u8));
    // 1.0 + 0.5 = 1.5
    try std.testing.expectEqual(@as(u8, 0x3E), one.add(half).toNative(u8));
    // 1.0 + (-1.0) = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.add(neg_one).toNative(u8));
    // 1.0 + 0 = 1.0
    try std.testing.expectEqual(@as(u8, 0x3C), one.add(pos_zero).toNative(u8));

    // inf + inf = inf（NaN/Inf 走 addPortable，add 会 panic）
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.addPortable(pos_inf).isInfinite());
    // inf + (-inf) = NaN
    const neg_inf = Float.fromNative(.f8, @as(u8, 0xFC));
    try std.testing.expect(pos_inf.addPortable(neg_inf).isNan());
}

test "Float f8 subtract" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const half = Float.fromNative(.f8, @as(u8, 0x38));

    // 1.0 - 0.5 = 0.5（有限结果走 subtract）
    try std.testing.expectEqual(@as(u8, 0x38), one.subtract(half).toNative(u8));
    // 1.0 - 1.0 = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.subtract(one).toNative(u8));
}

test "Float f8 multiply" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const two = Float.fromNative(.f8, @as(u8, 0x40));
    const one_point_five = Float.fromNative(.f8, @as(u8, 0x3E));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));

    // 2.0 × 2.0 = 4.0 (0x44)（有限结果走 multiply）
    try std.testing.expectEqual(@as(u8, 0x44), two.multiply(two).toNative(u8));
    // 1.0 × 1.5 = 1.5
    try std.testing.expectEqual(@as(u8, 0x3E), one.multiply(one_point_five).toNative(u8));
    // 1.0 × 0 = +0
    try std.testing.expectEqual(@as(u8, 0x00), one.multiply(pos_zero).toNative(u8));

    // inf × 0 = NaN（NaN/Inf 走 multiplyPortable）
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.multiplyPortable(pos_zero).isNan());
    // inf × inf = inf
    try std.testing.expect(pos_inf.multiplyPortable(pos_inf).isInfinite());
}

test "Float f8 divide" {
    const one = Float.fromNative(.f8, @as(u8, 0x3C));
    const two = Float.fromNative(.f8, @as(u8, 0x40));
    const pos_zero = Float.fromNative(.f8, @as(u8, 0x00));

    // 1.0 / 2.0 = 0.5 (0x38)（有限结果走 divide）
    try std.testing.expectEqual(@as(u8, 0x38), one.divide(two).toNative(u8));
    // 2.0 / 2.0 = 1.0
    try std.testing.expectEqual(@as(u8, 0x3C), two.divide(two).toNative(u8));
    // 1.0 / 0.0 = +inf（NaN/Inf 走 dividePortable）
    try std.testing.expectEqual(@as(u8, 0x7C), one.dividePortable(pos_zero).toNative(u8));
    // 0.0 / 0.0 = NaN
    try std.testing.expect(pos_zero.dividePortable(pos_zero).isNan());

    // inf / inf = NaN
    const pos_inf = Float.fromNative(.f8, @as(u8, 0x7C));
    try std.testing.expect(pos_inf.dividePortable(pos_inf).isNan());
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
