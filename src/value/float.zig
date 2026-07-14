//! 浮点数值类型模块
//!
//! 定义 Glue 语言的浮点数类型系统，支持 f16/f32/f64/f128 共四种
//! IEEE 754 精度。Float 结构体以低 64 位 + 高 64 位存储原始比特，
//! 提供加减乘除、比较、类型转换、整数互转、格式化等运算。
//! 所有运算基于软件实现的分解-重组（decompose/compose）流水线，
//! 不依赖硬件浮点指令，保证跨平台一致性。

const std = @import("std");
const wide_lib = @import("wide.zig");
const U128 = wide_lib.U128;
const U256 = wide_lib.U256;
const int = @import("int.zig");

/// 浮点数类型枚举，涵盖 16/32/64/128 位 IEEE 754 精度
pub const Type = enum {
f16,
f32,
f64,
f128,

/// 该类型占用的字节数
pub fn byteLength(self: Type) u8 {
return switch (self) {
.f16 => 2,
.f32 => 4,
.f64 => 8,
.f128 => 16,
};
}

/// 该类型的位宽
pub fn bitWidth(self: Type) u8 {
return switch (self) {
.f16 => 16,
.f32 => 32,
.f64 => 64,
.f128 => 128,
};
}

/// 指数字段的位数
pub fn exponentBits(self: Type) u8 {
return switch (self) {
.f16 => 5,
.f32 => 8,
.f64 => 11,
.f128 => 15,
};
}

/// 尾数字段的位数（不含隐含位）
pub fn mantissaBits(self: Type) u8 {
return switch (self) {
.f16 => 10,
.f32 => 23,
.f64 => 52,
.f128 => 112,
};
}

/// 指数偏置值
pub fn bias(self: Type) u16 {
return switch (self) {
.f16 => 15,
.f32 => 127,
.f64 => 1023,
.f128 => 16383,
};
}

/// 从类型名字符串解析为 Type，无法识别时返回 null
pub fn fromName(name: []const u8) ?Type {
if (std.mem.eql(u8, name, "f16")) return .f16;
if (std.mem.eql(u8, name, "f32")) return .f32;
if (std.mem.eql(u8, name, "f64")) return .f64;
if (std.mem.eql(u8, name, "f128")) return .f128;
return null;
}
};

/// 解包后的浮点数：符号、指数（原始编码值）、尾数及特殊值标记
pub const Unpacked = struct {
sign: u1,
exp: u32,
mantissa: U128,
is_nan: bool,
is_infinite: bool,
};

/// 分解后的浮点数：符号、无偏指数、带 3 位保护位的尾数及特殊值标记
const Decomposed = struct {
sign: u1,
exp: i32,
mantissa: U128,
is_nan: bool,
is_infinite: bool,
is_zero: bool,

/// 规范化尾数：左移使其隐含位对齐到 p+3 位置，同时调整指数
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

/// 浮点数值，由类型标记和原始比特（低 64 位 + 高 64 位）组成
pub const Float = struct {
type: Type,
bits: u64,
extra: u64,

/// 构造零值
pub fn zero(t: Type) Float {
return .{ .type = t, .bits = 0, .extra = 0 };
}

/// 从原生浮点数构造，按字节拷贝原始比特
pub fn fromNative(t: Type, v: anytype) Float {
const nbytes = t.byteLength();
if (nbytes <= 8) {
var result: Float = .{ .type = t, .bits = 0, .extra = 0 };
const src: [*]const u8 = @ptrCast(&v);
@memcpy(@as([*]u8, @ptrCast(&result.bits))[0..nbytes], src[0..nbytes]);
return result;
} else {
var result: Float = .{ .type = t, .bits = 0, .extra = 0 };
const src: [*]const u8 = @ptrCast(&v);
@memcpy(@as([*]u8, @ptrCast(&result.bits))[0..8], src[0..8]);
@memcpy(@as([*]u8, @ptrCast(&result.extra))[0..8], src[8..16]);
return result;
}
}

/// 转换为原生浮点数类型
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

/// 转换为 f128（非 f128 类型先做类型转换）
pub fn asF128(self: Float) f128 {
if (self.type == .f128) return self.toNative(f128);
return self.toFloatType(.f128).toNative(f128);
}

/// 判断符号位是否为负
pub inline fn isNegative(self: Float) bool {
if (self.type.byteLength() <= 8) {
const sh: u6 = @intCast(self.type.bitWidth() - 1);
return (self.bits >> sh) & 1 == 1;
}
return (self.extra >> 63) & 1 == 1;
}
/// 判断是否为 NaN
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
/// 判断是否为无穷大
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
/// 判断是否为零（含 +0 和 -0）
pub inline fn isZero(self: Float) bool {
if (self.type.byteLength() <= 8) {
const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
const sign_mask: u64 = @as(u64, 1) << sign_sh;
return (self.bits & ~sign_mask) == 0;
}
const u = self.unpack();
return u.exp == 0 and u.mantissa.isZero();
}
/// 判断是否为次正规数（非零且指数字段为零）
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
/// 解包原始比特为符号、指数字段、尾数及特殊值标记
pub fn unpack(self: Float) Unpacked {
const t = self.type;
const exp_bits = t.exponentBits();
const mant_bits = t.mantissaBits();
const total_bits = t.bitWidth();
const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
if (total_bits <= 64) {
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
/// 比较两个浮点数的大小，返回 lt/gt/eq
pub inline fn compare(self: Float, other: Float) std.math.Order {
std.debug.assert(self.type == other.type);
return comparePortable(self, other);
}

/// 比较的可移植实现：处理 NaN 排序后按符号和比特模式比较
fn comparePortable(self: Float, other: Float) std.math.Order {
const ua = self.unpack();
const ub = other.unpack();
if (ua.is_nan or ub.is_nan) {
if (ua.is_nan and ub.is_nan) {
if (ua.sign != ub.sign) return if (ua.sign == 1) .lt else .gt;
if (ua.mantissa.compare(ub.mantissa) == .lt) return .lt;
if (ua.mantissa.compare(ub.mantissa) == .gt) return .gt;
return .eq;
}
const nan_sign: u1 = if (ua.is_nan) ua.sign else ub.sign;
const nan_is_self = ua.is_nan;
if (nan_sign == 1) {
return if (nan_is_self) .lt else .gt;
} else {
return if (nan_is_self) .gt else .lt;
}
}
if (self.isZero() and other.isZero()) return .eq;
if (ua.sign != ub.sign) {
return if (ua.sign == 1) .lt else .gt;
}
const total_bits = self.type.bitWidth();
if (total_bits <= 64) {
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
/// 分解为无偏指数和带保护位的尾数，供算术运算使用
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
e = 1 - bias;
} else {
m = m.orBit(p);
e = @as(i32, @intCast(u.exp)) - bias;
}
m = m.shiftLeft(3);
return .{ .sign = u.sign, .exp = e, .mantissa = m, .is_nan = false, .is_infinite = false, .is_zero = false };
}
/// 翻转符号位
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

// ── 算术运算 ──

/// 加法，结果为 NaN 或无穷时 panic
pub inline fn add(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
return checkResult(addPortable(self, other));
}

/// 加法的可移植实现：对齐指数后做尾数加减
fn addPortable(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
const t = self.type;
const ua = self.unpack();
const ub = other.unpack();
if (ua.is_nan or ub.is_nan) return makeNan(t);
if (ua.is_infinite and ub.is_infinite) {
if (ua.sign == ub.sign) return self;
return makeNan(t);
}
if (ua.is_infinite) return self;
if (ub.is_infinite) return other;
const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
if (a_zero and b_zero) {
if (ua.sign == ub.sign) return makeZero(t, ua.sign);
return makeZero(t, 0);
}
if (a_zero) return other;
if (b_zero) return self;
var da = self.decompose();
var db = other.decompose();
if (da.exp < db.exp) {
const tmp = da;
da = db;
db = tmp;
}
const shift: u32 = @intCast(da.exp - db.exp);
db.mantissa = db.mantissa.shiftRightWithSticky(shift);
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
if (mr.isZero()) return makeZero(t, 0);
return compose(t, sr, da.exp, mr);
}
/// 减法，等价于加法加上符号翻转
pub inline fn subtract(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
return checkResult(subtractPortable(self, other));
}

/// 减法的可移植实现
fn subtractPortable(self: Float, other: Float) Float {
return self.addPortable(other.negate());
}

/// 乘法，结果为 NaN 或无穷时 panic
pub inline fn multiply(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
return checkResult(multiplyPortable(self, other));
}

/// 乘法的可移植实现：尾数相乘后规范化
fn multiplyPortable(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
const t = self.type;
const p: u32 = t.mantissaBits();
const ua = self.unpack();
const ub = other.unpack();
if (ua.is_nan or ub.is_nan) return makeNan(t);
const a_inf = ua.is_infinite;
const b_inf = ub.is_infinite;
const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
const result_sign: u1 = ua.sign ^ ub.sign;
if (a_inf and b_inf) return makeInf(t, result_sign);
if (a_inf or b_inf) {
if ((a_inf and b_zero) or (b_inf and a_zero)) return makeNan(t);
return makeInf(t, result_sign);
}
if (a_zero or b_zero) return makeZero(t, result_sign);
var da = self.decompose();
var db = other.decompose();
da.normalize(p);
db.normalize(p);
var result_exp: i32 = da.exp + db.exp;
const product: U256 = da.mantissa.multiply(db.mantissa);
const carry_pos: u32 = 2 * p + 7;
var shifted = product;
if (shifted.bit(carry_pos)) {
shifted = shifted.shiftRight1WithSticky();
result_exp += 1;
}
const low_width: u32 = p + 3;
const mant: U128 = shifted.extractU128(low_width);
const low_bits_nonzero = shifted.lo.lowBitsNonZero(low_width);
var result_mant = mant;
if (low_bits_nonzero) result_mant = result_mant.orBit(0);
return compose(t, result_sign, result_exp, result_mant);
}
/// 除法，结果为 NaN 或无穷时 panic
pub inline fn divide(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
return checkResult(dividePortable(self, other));
}

/// 除法的可移植实现：扩展被除数后做无符号除法
fn dividePortable(self: Float, other: Float) Float {
std.debug.assert(self.type == other.type);
const t = self.type;
const p: u32 = t.mantissaBits();
const ua = self.unpack();
const ub = other.unpack();
if (ua.is_nan or ub.is_nan) return makeNan(t);
const a_inf = ua.is_infinite;
const b_inf = ub.is_infinite;
const a_zero = (ua.exp == 0 and ua.mantissa.isZero());
const b_zero = (ub.exp == 0 and ub.mantissa.isZero());
const result_sign: u1 = ua.sign ^ ub.sign;
if (a_inf and b_inf) return makeNan(t);
if (a_inf) return makeInf(t, result_sign);
if (b_inf) return makeZero(t, result_sign);
if (a_zero and b_zero) return makeNan(t);
if (a_zero) return makeZero(t, result_sign);
if (b_zero) return makeInf(t, result_sign);
var da = self.decompose();
var db = other.decompose();
da.normalize(p);
db.normalize(p);
var result_exp: i32 = da.exp - db.exp;
const shift: u32 = p + 3;
const dividend: U256 = da.mantissa.shiftLeftWide(@intCast(shift));
const div_result = dividend.divideByU128(db.mantissa);
var quotient: U128 = div_result.quotient;
const remainder: U128 = div_result.remainder;
const implicit_bit: U128 = U128.fromU64(1).shiftLeft(@intCast(p + 3));
if (quotient.compare(implicit_bit) == .lt) {
quotient = quotient.shiftLeft(1);
result_exp -= 1;
}
if (!remainder.isZero()) quotient = quotient.orBit(0);
return compose(t, result_sign, result_exp, quotient);
}
/// 类型转换：调整尾数精度后重组为目标类型
pub inline fn toFloatType(self: Float, target: Type) Float {
if (target == self.type) return self;
const u = self.unpack();
if (u.is_nan) return makeNan(target);
if (u.is_infinite) return makeInf(target, u.sign);
if (u.exp == 0 and u.mantissa.isZero()) return makeZero(target, u.sign);
const p_self: u32 = self.type.mantissaBits();
const p_target: u32 = target.mantissaBits();
var da = self.decompose();
da.normalize(p_self);
var m = da.mantissa;
if (p_self > p_target) {
m = m.shiftRightWithSticky(p_self - p_target);
} else if (p_target > p_self) {
m = m.shiftLeft(@intCast(p_target - p_self));
}
return compose(target, da.sign, da.exp, m);
}
/// 转换为整数：截断小数部分，超出目标整数范围时返回 Overflow
pub fn toInt(self: Float, target: int.Type) error{Overflow}!int.Int {
const t = self.type;
const u = self.unpack();
if (u.is_nan or u.is_infinite) return error.Overflow;
if (u.exp == 0 and u.mantissa.isZero()) return int.Int.zero(target);
const p: u32 = t.mantissaBits();
var da = self.decompose();
da.normalize(p);
const frac_shift: i32 = da.exp - @as(i32, @intCast(p + 3));
var mag: U128 = da.mantissa;
if (frac_shift >= 0) {
const sh: u32 = @intCast(frac_shift);
if (sh >= 128) return error.Overflow;
if (sh > 0) {
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
const max_mag: U128 = if (target.isSigned())
U128.mask(@intCast(bits - 1))
else if (bits == 128)
U128.mask(128)
else
U128.mask(@intCast(bits));
if (mag.compare(max_mag) == .gt) return error.Overflow;
return int.Int.fromU128Unchecked(target, mag);
} else {
if (!target.isSigned()) return error.Overflow;
const max_mag: U128 = U128.fromU64(1).shiftLeft(@intCast(bits - 1));
if (mag.compare(max_mag) == .gt) return error.Overflow;
const neg: U128 = mag.negate();
return int.Int.fromU128Unchecked(target, neg);
}
}
/// 从整数构造浮点数：规范化尾数后重组
pub fn fromInt(target: Type, iv: int.Int) Float {
const is_neg = iv.isNegative();
var mag: U128 = undefined;
if (iv.type.byteLength() <= 8) {
if (iv.type.isSigned() and (iv.lo >> 63) & 1 == 1) {
mag = U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, iv.lo);
} else {
mag = U128.fromU64(iv.lo);
}
} else {
mag = U128.fromU64Pair(iv.hi, iv.lo);
}
if (is_neg) mag = mag.negate();
if (mag.isZero()) return makeZero(target, 0);
const sign: u1 = if (is_neg) 1 else 0;
const p: u32 = target.mantissaBits();
const leading_zeros: u32 = mag.clz();
const bit_pos: i32 = 127 - @as(i32, @intCast(leading_zeros));
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
/// 取绝对值（清零符号位）
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
/// 格式化为十进制字符串，写入 buf 并返回有效切片
/// f128 超大值退化为十六进制科学计数法表示
pub fn formatDecimal(self: Float, buf: []u8) []const u8 {
const t = self.type;
if (self.isNan()) return "nan";
if (self.isInfinite()) return if (self.isNegative()) "-inf" else "inf";
if (self.isZero()) return if (self.isNegative()) "-0" else "0";
if (t != .f128) {
const fv = self.toFloatType(.f64).toNative(f64);
return std.fmt.bufPrint(buf, "{d}", .{fv}) catch unreachable;
}
const neg = self.isNegative();
const abs_val = if (neg) self.negate() else self;
const sign_str: []const u8 = if (neg) "-" else "";
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
var int_buf: [41]u8 = undefined;
const int_str = int_part.formatDecimal(&int_buf);
const int_float = Float.fromInt(.f128, int_part);
var remainder = abs_val.subtract(int_float);
if (remainder.isNegative()) remainder = remainder.negate();
if (remainder.isZero()) {
return std.fmt.bufPrint(buf, "{s}{s}", .{ sign_str, int_str }) catch unreachable;
}
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
/// 复制 other 的符号位到 self
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
/// 返回下一个更大的浮点数（ULP +1）
pub fn nextUp(self: Float) Float {
const t = self.type;
const u = self.unpack();
if (u.is_nan) return self;
if (u.is_infinite) {
if (u.sign == 0) return self;
const exp_bits = t.exponentBits();
const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
const p = t.mantissaBits();
const max_frac: U128 = U128.mask(@intCast(p));
return packBytes(t, 1, max_exp - 1, max_frac);
}
const total_bits = t.bitWidth();
if (total_bits <= 64) {
const sh: u6 = @intCast(total_bits - 1);
const sign_bit: u64 = @as(u64, 1) << sh;
if (self.bits == 0 or self.bits == sign_bit) {
return packBytes(t, 0, 0, U128.fromU64(1));
}
var b = self.bits;
if (u.sign == 0) {
b +%= 1;
} else {
b -%= 1;
}
return .{ .type = t, .bits = b, .extra = 0 };
}
var bits = U128.fromU64Pair(self.extra, self.bits);
const sign_bit = U128.fromU64(1).shiftLeft(127);
if (bits.isZero() or bits.equals(sign_bit)) {
return packBytes(t, 0, 0, U128.fromU64(1));
}
if (u.sign == 0) {
bits = bits.add(U128.fromU64(1)).sum;
} else {
bits = bits.sub(U128.fromU64(1)).diff;
}
return packRawBits(t, bits);
}
/// 返回下一个更小的浮点数（ULP -1）
pub fn nextDown(self: Float) Float {
return self.negate().nextUp().negate();
}
};

// ── 模块级工具函数 ──

/// 检查运算结果：NaN 或无穷大时 panic
fn checkResult(result: Float) Float {
if (result.isNan()) @panic("float operation produced NaN");
if (result.isInfinite()) @panic("float operation produced Infinity");
return result;
}
/// 构造带符号的零值
fn makeZero(t: Type, sign: u1) Float {
if (t.byteLength() <= 8) {
const sh: u6 = @intCast(t.bitWidth() - 1);
const bits: u64 = if (sign == 1) @as(u64, 1) << sh else 0;
return .{ .type = t, .bits = bits, .extra = 0 };
}
const extra: u64 = if (sign == 1) @as(u64, 1) << 63 else 0;
return .{ .type = t, .bits = 0, .extra = extra };
}
/// 构造无穷大
fn makeInf(t: Type, sign: u1) Float {
const exp_bits = t.exponentBits();
const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
return packBytes(t, sign, max_exp, U128.zero());
}
/// 构造 NaN（尾数最低位置 1）
fn makeNan(t: Type) Float {
const exp_bits = t.exponentBits();
const max_exp: u32 = (@as(u32, 1) << @intCast(exp_bits)) - 1;
return packBytes(t, 0, max_exp, U128.fromU64(1));
}
/// 将符号、指数字段和尾数打包为 Float 原始比特
fn packBytes(t: Type, sign: u1, stored_exp: u32, fraction: U128) Float {
const p = t.mantissaBits();
const total_bits = t.bitWidth();
if (total_bits <= 64) {
const sh: u6 = @intCast(total_bits - 1);
const mb: u6 = @intCast(p);
var raw: u64 = fraction.lo | (@as(u64, stored_exp) << mb);
if (sign == 1) raw |= (@as(u64, 1) << sh);
return .{ .type = t, .bits = raw, .extra = 0 };
}
var raw: U128 = fraction;
raw = raw.or_(U128.fromU64(stored_exp).shiftLeft(@intCast(p)));
if (sign == 1) raw = raw.orBit(127);
return .{ .type = t, .bits = raw.lo, .extra = raw.hi };
}
/// 将 U128 原始比特打包为 Float（用于 nextUp/nextDown）
fn packRawBits(t: Type, bits: U128) Float {
if (t.byteLength() <= 8) {
return .{ .type = t, .bits = bits.lo, .extra = 0 };
}
return .{ .type = t, .bits = bits.lo, .extra = bits.hi };
}
/// 重组流水线核心：规范化尾数、处理溢出/下溢、执行舍入并打包为 Float
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
if (m.compare(carry_bit) != .lt) {
m = m.shiftRightWithSticky(1);
e += 1;
}
if (!m.isZero() and m.compare(implicit_bit) == .lt) {
const clz_m: u8 = m.clz();
const target_clz: u8 = @intCast(128 - p - 4);
const shift_amt: u8 = clz_m - target_clz;
m = m.shiftLeft(shift_amt);
e -= @as(i32, shift_amt);
}
if (e + bias >= max_exp_field) {
return makeInf(t, sign);
}
var stored_exp: i32 = undefined;
if (e + bias >= 1) {
stored_exp = e + bias;
} else {
const shift: u32 = @intCast(1 - bias - e);
m = m.shiftRightWithSticky(shift);
stored_exp = 0;
}
const g = m.testBit(2);
const r = m.testBit(1);
const s = m.testBit(0);
const lsb_set = m.testBit(3);
var rounded = m.and_(U128.fromU64(7).bitwiseNot());
if (g and (r or s or lsb_set)) {
rounded = rounded.add(U128.fromU64(8)).sum;
}
m = rounded;
if (stored_exp == 0) {
if (m.testBit(@intCast(p + 3))) {
stored_exp = 1;
}
} else {
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
{
const cases = [_]f32{ 0.0, -0.0, 1.0, -1.0, 3.14, -3.14, std.math.floatMax(f32), -std.math.floatMax(f32) };
for (cases) |v| {
const x = Float.fromNative(.f32, v);
try std.testing.expectEqual(v, x.toNative(f32));
}
}
{
const cases = [_]f64{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f64), -std.math.floatMax(f64) };
for (cases) |v| {
const x = Float.fromNative(.f64, v);
try std.testing.expectEqual(v, x.toNative(f64));
}
}
{
const cases = [_]f16{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f16) };
for (cases) |v| {
const x = Float.fromNative(.f16, v);
try std.testing.expectEqual(v, x.toNative(f16));
}
}
{
const cases = [_]f128{ 0.0, -0.0, 1.0, -1.0, 3.14, std.math.floatMax(f128) };
for (cases) |v| {
const x = Float.fromNative(.f128, v);
try std.testing.expectEqual(v, x.toNative(f128));
}
}
}
test "Float.isNan/isInfinite/isZero/isSubnormal/isNegative" {
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
try std.testing.expect(Float.fromNative(.f64, std.math.nan(f64)).isNan());
try std.testing.expect(Float.fromNative(.f64, std.math.inf(f64)).isInfinite());
try std.testing.expect(Float.fromNative(.f128, std.math.nan(f128)).isNan());
try std.testing.expect(Float.fromNative(.f128, std.math.inf(f128)).isInfinite());
}
test "Float.compare basic" {
try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, 3.0)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, 1.0)).compare(Float.fromNative(.f32, @as(f32, 3.0))));
try std.testing.expectEqual(.eq, Float.fromNative(.f32, @as(f32, 3.0)).compare(Float.fromNative(.f32, @as(f32, 3.0))));
try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, 1.0)).compare(Float.fromNative(.f32, @as(f32, -1.0))));
try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, -1.0)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
try std.testing.expectEqual(.lt, Float.fromNative(.f32, @as(f32, -3.0)).compare(Float.fromNative(.f32, @as(f32, -1.0))));
try std.testing.expectEqual(.gt, Float.fromNative(.f32, @as(f32, -1.0)).compare(Float.fromNative(.f32, @as(f32, -3.0))));
try std.testing.expectEqual(.eq, Float.fromNative(.f32, @as(f32, 0.0)).compare(Float.fromNative(.f32, @as(f32, -0.0))));
try std.testing.expectEqual(.gt, Float.fromNative(.f32, std.math.inf(f32)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
try std.testing.expectEqual(.lt, Float.fromNative(.f32, -std.math.inf(f32)).compare(Float.fromNative(.f32, @as(f32, 1.0))));
try std.testing.expectEqual(.gt, Float.fromNative(.f32, std.math.nan(f32)).compare(Float.fromNative(.f32, std.math.inf(f32))));
try std.testing.expectEqual(.lt, Float.fromNative(.f32, std.math.inf(f32)).compare(Float.fromNative(.f32, std.math.nan(f32))));
try std.testing.expectEqual(.gt, Float.fromNative(.f64, @as(f64, 3.0)).compare(Float.fromNative(.f64, @as(f64, 1.0))));
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
{
const a = Float.fromNative(.f32, inf);
const b = Float.fromNative(.f32, inf);
try std.testing.expect(a.subtractPortable(b).isNan());
}
{
const a = Float.fromNative(.f32, @as(f32, 1.0));
const b = Float.fromNative(.f32, @as(f32, 1.0));
const r = a.subtract(b);
try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
}
{
const a = Float.fromNative(.f32, @as(f32, 0.0));
const b = Float.fromNative(.f32, @as(f32, -0.0));
const r = a.subtract(b);
try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
}
{
const a = Float.fromNative(.f32, @as(f32, -0.0));
const b = Float.fromNative(.f32, @as(f32, -0.0));
const r = a.subtract(b);
try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(r.toNative(f32))));
}
{
const a = Float.fromNative(.f32, max);
const b = Float.fromNative(.f32, -max);
const r = a.subtractPortable(b);
try std.testing.expect(r.isInfinite());
try std.testing.expect(!r.isNegative());
}
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
{
const a = Float.fromNative(.f64, @as(f64, 1.0));
const b = Float.fromNative(.f64, @as(f64, 3.0));
const r = a.divide(b);
const native: f64 = 1.0 / 3.0;
try std.testing.expectEqual(@as(u64, @bitCast(native)), @as(u64, @bitCast(r.toNative(f64))));
}
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
{
const v = Float.fromNative(.f32, @as(f32, -1.0));
try std.testing.expectError(error.Overflow, v.toInt(.u64));
}
{
const v = Float.fromNative(.f32, @as(f32, 1e10));
const r = try v.toInt(.u64);
const native_val: u64 = @intFromFloat(@trunc(@as(f32, 1e10)));
try std.testing.expectEqual(native_val, r.toNative(u64));
}
{
const v = Float.fromNative(.f32, @as(f32, 1e10));
try std.testing.expectError(error.Overflow, v.toInt(.i32));
}
{
const v = Float.fromNative(.f32, @as(f32, 42.9));
const r = try v.toInt(.i32);
const native_val: i32 = @intFromFloat(@trunc(@as(f32, 42.9)));
try std.testing.expectEqual(native_val, r.toNative(i32));
}
}
test "Float.toInt i128 truncation and overflow" {
{
const v = Float.fromNative(.f64, @as(f64, 1e10));
const r = try v.toInt(.i128);
try std.testing.expectEqual(@as(i128, 10_000_000_000), r.toNative(i128));
}
{
const v = Float.fromNative(.f64, @as(f64, -1e10));
const r = try v.toInt(.i128);
try std.testing.expectEqual(@as(i128, -10_000_000_000), r.toNative(i128));
}
{
const v = Float.fromNative(.f64, @as(f64, 1e38));
const r = try v.toInt(.i128);
try std.testing.expect(!r.isNegative());
}
{
const v = Float.fromNative(.f64, @as(f64, 1e50));
try std.testing.expectError(error.Overflow, v.toInt(.i128));
}
{
const v = Float.fromNative(.f64, @as(f64, -1e50));
try std.testing.expectError(error.Overflow, v.toInt(.i128));
}
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
const r_abs = a.abs();
const native_abs_bits: u32 = @as(u32, @bitCast(v)) & ~sign_bit;
if (std.math.isNan(v)) {
try std.testing.expect(r_abs.isNan());
} else {
try std.testing.expectEqual(native_abs_bits, @as(u32, @bitCast(r_abs.toNative(f32))));
}
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

