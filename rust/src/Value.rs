//! Value.rs — Glue 统一值系统（合并 14 个子模块）

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::VecDeque;
use rustc_hash::FxHashMap;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, Weak};
use std::sync::atomic::AtomicBool;

use rayon::prelude::*;
use pastey::paste;
use wide::{f32x4, f64x4, i8x16, i16x8, i32x4, i64x4, u8x16, u16x8, u32x4, u64x4, CmpEq, CmpGe, CmpGt, CmpLe, CmpLt, CmpNe};

// 从 Type 模块 re-export 类型判别标签
pub use crate::Type::ValueTag;

// =========================================================================
// 第一部分：标量基础类型（scalar.rs + char.rs）
// =========================================================================

// ---- F16 — IEEE 754 半精度浮点（binary16）----

/// IEEE 754 半精度浮点数：以 `u16` 存储 bit pattern
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F16(pub u16);

impl F16 {
    pub fn from_f32(x: f32) -> Self {
        F16(f32_to_f16_bits(x))
    }
    pub fn to_f32(self) -> f32 {
        f16_bits_to_f32(self.0)
    }
    pub fn from_f64(x: f64) -> Self {
        Self::from_f32(x as f32)
    }
    pub fn to_f64(self) -> f64 {
        self.to_f32() as f64
    }
    pub fn is_nan(self) -> bool {
        let exp = (self.0 >> 10) & 0x1F;
        let mant = self.0 & 0x3FF;
        exp == 0x1F && mant != 0
    }
    pub fn is_infinite(self) -> bool {
        let exp = (self.0 >> 10) & 0x1F;
        let mant = self.0 & 0x3FF;
        exp == 0x1F && mant == 0
    }
    pub fn to_bits(self) -> u16 {
        self.0
    }
    pub fn from_bits(b: u16) -> Self {
        F16(b)
    }

    // ---- IEEE 754 binary16 精确运算（不经过 f64 中转）----
    // 布局：sign(1) | exp(5, bias=15) | fraction(10)
    // 正规数 mantissa = (1 << 10) | fraction，共 11 位
    // 次正规数 mantissa = fraction，指数 = 1 - bias = -14
    // 与 F128 同一 unpack/pack 框架，因 mantissa 仅 11 位，u32 足够

    fn nan_val() -> Self { F16(0x7C00 | 1) }
    fn inf_val(sign: bool) -> Self { F16(if sign { 0xFC00 } else { 0x7C00 }) }
    fn zero_val(sign: bool) -> Self { F16(if sign { 0x8000 } else { 0 }) }

    /// 拆解为 (sign, unbiased_exp, mantissa)。
    /// 正规数 mantissa 含隐含 1（bit 10 = 1）；次正规数/零 mantissa = fraction。
    fn unpack(&self) -> (bool, i32, u32) {
        let bits = self.0;
        let sign = (bits >> 15) != 0;
        let raw_exp = ((bits >> 10) & 0x1F) as i32;
        let frac = (bits & 0x3FF) as u32;
        if raw_exp == 0 {
            (sign, 1 - 15, frac)
        } else {
            (sign, raw_exp - 15, frac | (1u32 << 10))
        }
    }

    /// 将 (sign, exp, mant, sticky) 规范化并舍入为 F16。
    /// mant 的 MSB 是隐含 1（可在任意位置），pack 负责对齐到 bit 10。
    /// 舍入模式：round-to-nearest-even。
    fn pack(sign: bool, exp: i32, mant: u32, sticky: bool) -> Self {
        if mant == 0 {
            return Self::zero_val(sign);
        }
        let msb = 31 - mant.leading_zeros() as i32;
        let shift = msb - 10;
        let mut adj_exp = exp + shift;
        let mut m = mant;
        let mut stk = sticky;
        let mut guard = false;
        if shift > 0 {
            let sh = shift as u32;
            if sh >= 32 {
                m = 0;
                stk = true;
            } else {
                guard = (mant >> (sh - 1)) & 1 != 0;
                if sh > 1 {
                    stk = stk || (mant & ((1u32 << (sh - 1)) - 1)) != 0;
                }
                m = mant >> sh;
            }
        } else if shift < 0 {
            m = mant << (-shift as u32);
        }
        if m == 0 {
            return Self::zero_val(sign);
        }
        let biased = adj_exp + 15;
        if biased >= 0x1F {
            return Self::inf_val(sign);
        }
        if biased <= 0 {
            let extra = (1 - biased) as u32;
            if extra >= 32 {
                if guard && stk { return Self::zero_val(false); }
                return Self::zero_val(sign);
            }
            if extra > 0 {
                let new_guard = (m >> (extra - 1)) & 1 != 0;
                if extra > 1 {
                    stk = stk || (m & ((1u32 << (extra - 1)) - 1)) != 0;
                }
                guard = new_guard;
                m >>= extra;
            }
            if guard && (stk || (m & 1) != 0) {
                m = m.wrapping_add(1);
                if m >= (1u32 << 10) {
                    return F16((if sign { 0x8000 } else { 0 }) | (1u16 << 10));
                }
            }
            return F16((if sign { 0x8000 } else { 0 }) | m as u16);
        }
        if guard && (stk || (m & 1) != 0) {
            m = m.wrapping_add(1);
            if m >= (1u32 << 11) {
                m >>= 1;
                adj_exp += 1;
                if adj_exp + 15 >= 0x1F {
                    return Self::inf_val(sign);
                }
            }
        }
        let frac = (m & 0x3FF) as u16;
        F16((if sign { 0x8000 } else { 0 }) | (((adj_exp + 15) as u16) << 10) | frac)
    }

    pub fn neg_f16(self) -> Self {
        F16(self.0 ^ 0x8000)
    }

    pub fn add_f16(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() { return Self::nan_val(); }
        if self.is_infinite() {
            if other.is_infinite() {
                let (sa, _, _) = self.unpack();
                let (sb, _, _) = other.unpack();
                return if sa == sb { self } else { Self::nan_val() };
            }
            return self;
        }
        if other.is_infinite() { return other; }

        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();
        if ma == 0 && mb == 0 { return Self::zero_val(sa && sb); }
        if ma == 0 { return other; }
        if mb == 0 { return self; }

        let ma_ext = ma << 2;
        let mb_ext = mb << 2;
        let result_exp;
        let (aligned_a, aligned_b, stk) = if ea > eb {
            let diff = (ea - eb) as u32;
            result_exp = ea;
            if diff >= 32 { (ma_ext, 0u32, mb_ext != 0) }
            else {
                let lost = mb_ext & ((1u32 << diff) - 1);
                (ma_ext, mb_ext >> diff, lost != 0)
            }
        } else if eb > ea {
            let diff = (eb - ea) as u32;
            result_exp = eb;
            if diff >= 32 { (0u32, mb_ext, ma_ext != 0) }
            else {
                let lost = ma_ext & ((1u32 << diff) - 1);
                (ma_ext >> diff, mb_ext, lost != 0)
            }
        } else {
            result_exp = ea;
            (ma_ext, mb_ext, false)
        };

        let (result_sign, result_mant) = if sa == sb {
            (sa, aligned_a.wrapping_add(aligned_b))
        } else if aligned_a >= aligned_b {
            (sa, aligned_a - aligned_b)
        } else {
            (sb, aligned_b - aligned_a)
        };
        if result_mant == 0 { return Self::zero_val(false); }
        Self::pack(result_sign, result_exp - 2, result_mant, stk)
    }

    pub fn sub_f16(self, other: Self) -> Self {
        self.add_f16(other.neg_f16())
    }

    pub fn mul_f16(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() { return Self::nan_val(); }
        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();
        let result_sign = sa ^ sb;
        if self.is_infinite() && mb == 0 { return Self::nan_val(); }
        if other.is_infinite() && ma == 0 { return Self::nan_val(); }
        if self.is_infinite() || other.is_infinite() { return Self::inf_val(result_sign); }
        if ma == 0 || mb == 0 { return Self::zero_val(result_sign); }

        let result_exp = ea + eb;
        // 11 × 11 = 22 位乘积，u32 足够
        let prod = (ma as u32) * (mb as u32);
        let total_bits = 32 - prod.leading_zeros() as i32;
        let shift = total_bits - 11;
        let (m, stk) = if shift > 0 {
            let sh = shift as u32;
            let lost = prod & ((1u32 << (sh - 1)) - 1);
            (prod >> sh, lost != 0)
        } else {
            (prod, false)
        };
        Self::pack(result_sign, result_exp - 10 + shift, m, stk)
    }

    pub fn div_f16(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() { return Self::nan_val(); }
        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();
        let result_sign = sa ^ sb;
        if self.is_infinite() && other.is_infinite() { return Self::nan_val(); }
        if self.is_infinite() { return Self::inf_val(result_sign); }
        if other.is_infinite() { return Self::zero_val(result_sign); }
        if mb == 0 {
            if ma == 0 { return Self::nan_val(); }
            return Self::inf_val(result_sign);
        }
        if ma == 0 { return Self::zero_val(result_sign); }

        let result_exp = ea - eb;
        // (ma << 12) / mb，商 ~12 位，u32 足够
        // ma/mb ∈ [0.5, 2)，(ma<<12)/mb ∈ [2^11, 2^13)，不溢出 u32
        let quot = ((ma as u32) << 12) / mb;
        let stk = ((ma << 12) % mb) != 0;
        // pack 语义：值 = mant * 2^(exp - 10)
        // 真实商 = (ma/mb) * 2^result_exp = quot * 2^(result_exp - 12)
        // exp = result_exp - 12 + 10 = result_exp - 2
        Self::pack(result_sign, result_exp - 2, quot, stk)
    }

    pub fn rem_f16(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() { return Self::nan_val(); }
        if other.is_infinite() { return self; }
        if self.is_infinite() { return Self::nan_val(); }
        let (_, _, mb) = other.unpack();
        if mb == 0 { return Self::nan_val(); }
        let (_, _, ma) = self.unpack();
        if ma == 0 { return self; }

        let quot = self.div_f16(other);
        let q_bits = quot.0;
        let q_exp = ((q_bits >> 10) & 0x1F) as i32 - 15;
        let q_int = if q_exp >= 0 {
            let shift = q_exp as u32;
            let q_mant = ((q_bits & 0x3FF) as u32) | (1u32 << 10);
            if shift >= 11 { 0u32 } else { q_mant >> shift }
        } else { 0u32 };
        let q_val = Self::from_f64(q_int as f64);
        let prod = q_val.mul_f16(other);
        self.sub_f16(prod)
    }
}

impl fmt::Debug for F16 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.is_nan() {
            write!(f, "NaN(f16)")
        } else if self.is_infinite() {
            if self.0 >> 15 != 0 {
                write!(f, "-inf(f16)")
            } else {
                write!(f, "inf(f16)")
            }
        } else {
            write!(f, "{}f16", self.to_f32())
        }
    }
}

impl fmt::Display for F16 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

/// f32 bit pattern → f16 bit pattern（IEEE 754 round-to-nearest）
fn f32_to_f16_bits(x: f32) -> u16 {
    let bits = x.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let mant = bits & 0x7FFFFF;

    if exp == 0xFF {
        let m = if mant != 0 { 0x200 } else { 0 };
        return sign | 0x7C00 | (m as u16);
    }

    let new_exp = exp - 127 + 15;
    if new_exp >= 0x1F {
        return sign | 0x7C00;
    }

    if new_exp <= 0 {
        if 14 - new_exp >= 24 {
            return sign;
        }
        let m = mant | 0x800000;
        let shift = 14 - new_exp;
        let rounded_m = m >> shift;
        let rem = m & ((1 << shift) - 1);
        let half = 1 << (shift - 1);
        let mut result = rounded_m;
        if rem > half || (rem == half && (rounded_m & 1) != 0) {
            result += 1;
        }
        return sign | (result as u16);
    }

    let m = mant >> 13;
    let rem = mant & 0x1FFF;
    let half = 0x1000;
    let mut result: u32 = ((new_exp as u32) << 10) | m;
    if rem > half || (rem == half && (m & 1) != 0) {
        result += 1;
    }
    sign | (result as u16)
}

/// f16 bit pattern → f32 bit pattern
fn f16_bits_to_f32(bits: u16) -> f32 {
    let sign = ((bits as u32) & 0x8000) << 16;
    let exp = ((bits as u32) >> 10) & 0x1F;
    let mant = (bits as u32) & 0x3FF;

    if exp == 0 {
        if mant == 0 {
            return f32::from_bits(sign);
        }
        let mut e: i32 = -1;
        let mut m = mant;
        while (m & 0x400) == 0 {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        let new_exp = (127 + e - 14) as u32;
        return f32::from_bits(sign | (new_exp << 23) | (m << 13));
    }

    if exp == 0x1F {
        let m = if mant != 0 { (mant << 13) | 0x400000 } else { 0 };
        return f32::from_bits(sign | 0x7F800000 | m);
    }

    let new_exp = exp + (127 - 15);
    f32::from_bits(sign | (new_exp << 23) | (mant << 13))
}

// ---- F128 — IEEE 754 四倍精度浮点（binary128）----

/// IEEE 754 四倍精度浮点数：以 `[u8; 16]` 存储 bit pattern
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F128(pub [u8; 16]);

/// # 已知限制 [V-7]
/// `from_f64`/`to_f64` 对**非整数值**存在精度丢失（pre-existing，原 scalar.rs 遗留）：
/// 仅对整数值保证精确往返。当前实现仅搬运 f64 的 53 位 mantissa 到 binary128 的高 53 位，
/// 丢弃低 60 位 mantissa 信息，未实现完整的 113 位 mantissa 舍入逻辑。
/// 依赖 f128 的数值程序在实现完整 IEEE 754 binary128 转换前，不应假设 f64↔f128 往返保真。
impl F128 {
    pub fn from_f64(x: f64) -> Self {
        let bits = x.to_bits();
        let sign = ((bits >> 63) & 1) as u128;
        let exp = ((bits >> 52) & 0x7FF) as i32;
        let mant = (bits & 0xFFFFFFFFFFFFF) as u128;

        let result: u128 = if exp == 0x7FF {
            let new_exp: u128 = 0x7FFF;
            let new_mant: u128 = if mant != 0 { (mant << 60) | 0x8000000000000000 } else { 0 };
            (sign << 127) | (new_exp << 112) | new_mant
        } else if exp == 0 {
            if mant == 0 {
                sign << 127
            } else {
                let new_exp: u128 = 0;
                (sign << 127) | (new_exp << 112) | (mant << 60)
            }
        } else {
            let new_exp = (exp - 1023 + 16383) as u128;
            (sign << 127) | (new_exp << 112) | (mant << 60)
        };

        F128(result.to_le_bytes())
    }

    pub fn to_f64(self) -> f64 {
        let bits = u128::from_le_bytes(self.0);
        let sign = ((bits >> 127) & 1) as u64;
        let exp = ((bits >> 112) & 0x7FFF) as i32;
        let mant = bits & ((1u128 << 112) - 1);

        if exp == 0x7FFF {
            let m: u64 = if mant != 0 {
                ((mant >> 60) as u64) | 0x8000000000000
            } else {
                0
            };
            return f64::from_bits((sign << 63) | (0x7FF << 52) | m);
        }

        if exp == 0 {
            if mant == 0 {
                return f64::from_bits(sign << 63);
            }
            // F128 subnormal 值转 f64 精度丢失，返回 ±0.0（已知限制）
            return f64::from_bits(sign << 63);
        }

        let new_exp = exp - 16383 + 1023;
        if new_exp >= 0x7FF {
            return f64::from_bits((sign << 63) | (0x7FF << 52));
        }
        if new_exp <= 0 {
            return f64::from_bits(sign << 63);
        }

        let m = (mant >> 60) as u64;
        f64::from_bits((sign << 63) | ((new_exp as u64) << 52) | m)
    }

    pub fn from_f32(x: f32) -> Self {
        Self::from_f64(x as f64)
    }
    pub fn to_f32(self) -> f32 {
        self.to_f64() as f32
    }
    pub fn is_nan(self) -> bool {
        let bits = u128::from_le_bytes(self.0);
        let exp = (bits >> 112) & 0x7FFF;
        let mant = bits & ((1u128 << 112) - 1);
        exp == 0x7FFF && mant != 0
    }
    pub fn is_infinite(self) -> bool {
        let bits = u128::from_le_bytes(self.0);
        let exp = (bits >> 112) & 0x7FFF;
        let mant = bits & ((1u128 << 112) - 1);
        exp == 0x7FFF && mant == 0
    }
    pub fn to_bits(self) -> [u8; 16] {
        self.0
    }
    pub fn from_bits(b: [u8; 16]) -> Self {
        F128(b)
    }

    // ---- IEEE 754 binary128 精确运算（不经过 f64 中转）----
    // 布局：sign(1) | exp(15, bias=16383) | fraction(112)
    // 正规数 mantissa = (1 << 112) | fraction，共 113 位
    // 次正规数 mantissa = fraction，指数 = 1 - bias = -16382

    fn nan_val() -> Self {
        F128(((0x7FFFu128 << 112) | 1).to_le_bytes())
    }
    fn inf_val(sign: bool) -> Self {
        F128((((sign as u128) << 127) | (0x7FFFu128 << 112)).to_le_bytes())
    }
    fn zero_val(sign: bool) -> Self {
        F128(((sign as u128) << 127).to_le_bytes())
    }

    /// 拆解为 (sign, unbiased_exp, mantissa)。
    /// 正规数 mantissa 含隐含 1（bit 112 = 1）；次正规数/零 mantissa = fraction。
    fn unpack(&self) -> (bool, i32, u128) {
        let bits = u128::from_le_bytes(self.0);
        let sign = (bits >> 127) != 0;
        let raw_exp = ((bits >> 112) & 0x7FFF) as i32;
        let frac = bits & ((1u128 << 112) - 1);
        if raw_exp == 0 {
            (sign, 1 - 16383, frac)
        } else {
            (sign, raw_exp - 16383, frac | (1u128 << 112))
        }
    }

    /// 将 (sign, exp, mant, sticky) 规范化并舍入为 F128。
    /// mant 的 MSB 是隐含 1（可以在任意位置），pack 负责对齐到 bit 112。
    /// sticky 表示低于 mant 最低有效位是否有非零信息。
    /// 舍入模式：round-to-nearest-even。
    fn pack(sign: bool, exp: i32, mant: u128, sticky: bool) -> Self {
        if mant == 0 {
            // 值极小，round-to-nearest-even 向下到 0
            return Self::zero_val(sign);
        }

        // 规范化：将 MSB 对齐到 bit 112
        let msb = 127 - mant.leading_zeros() as i32;
        let shift = msb - 112;
        let mut adj_exp = exp + shift;
        let mut m = mant;
        let mut stk = sticky;

        // guard 位：右移时移出的最高位
        let mut guard = false;
        if shift > 0 {
            let sh = shift as u32;
            if sh >= 128 {
                m = 0;
                guard = false;
                stk = true;
            } else {
                guard = (mant >> (sh - 1)) & 1 != 0;
                if sh > 1 {
                    stk = stk || (mant & ((1u128 << (sh - 1)) - 1)) != 0;
                }
                m = mant >> sh;
            }
        } else if shift < 0 {
            m = mant << (-shift as u32);
        }

        if m == 0 {
            return Self::zero_val(sign);
        }

        let biased = adj_exp + 16383;

        // 溢出 → ±Inf
        if biased >= 0x7FFF {
            return Self::inf_val(sign);
        }

        // 次正规数或下溢
        if biased <= 0 {
            let extra = (1 - biased) as u32;
            if extra >= 128 {
                // 完全下溢
                if guard && stk {
                    return Self::zero_val(false); // 0 是偶数
                }
                return Self::zero_val(sign);
            }
            // 右移 extra 位，保留 guard/sticky
            if extra > 0 {
                let new_guard = (m >> (extra - 1)) & 1 != 0;
                if extra > 1 {
                    stk = stk || (m & ((1u128 << (extra - 1)) - 1)) != 0;
                }
                guard = new_guard;
                m >>= extra;
            }
            // 舍入（round-to-nearest-even）
            if guard && (stk || (m & 1) != 0) {
                m = m.wrapping_add(1);
                if m >= (1u128 << 112) {
                    // 进位到最小正规数
                    return F128((((sign as u128) << 127) | (1u128 << 112)).to_le_bytes());
                }
            }
            return F128((((sign as u128) << 127) | m).to_le_bytes());
        }

        // 正规数：m 的 bit 112 = 1，小数 = bits 0-111
        // 舍入（round-to-nearest-even）
        if guard && (stk || (m & 1) != 0) {
            m = m.wrapping_add(1);
            // 进位可能使 mantissa 从 113 位变 114 位（bit 113 = 1）
            if m >= (1u128 << 113) {
                m >>= 1;
                adj_exp += 1;
                let biased2 = adj_exp + 16383;
                if biased2 >= 0x7FFF {
                    return Self::inf_val(sign);
                }
            }
        }
        let frac = m & ((1u128 << 112) - 1);
        let bits = ((sign as u128) << 127) | (((adj_exp + 16383) as u128) << 112) | frac;
        F128(bits.to_le_bytes())
    }

    /// 113 位 × 113 位 → 226 位乘积 (hi, lo)
    fn mul_113(a: u128, b: u128) -> (u128, u128) {
        let a_lo = a as u64 as u128;
        let a_hi = (a >> 64) as u64 as u128;
        let b_lo = b as u64 as u128;
        let b_hi = (b >> 64) as u64 as u128;
        let ll = a_lo * b_lo;
        let lh = a_lo * b_hi;
        let hl = a_hi * b_lo;
        let hh = a_hi * b_hi;
        let mid = (lh & 0xFFFF_FFFF_FFFF_FFFF) + (hl & 0xFFFF_FFFF_FFFF_FFFF) + (ll >> 64);
        let lo = (mid << 64) | (ll & 0xFFFF_FFFF_FFFF_FFFF);
        let hi = hh + (lh >> 64) + (hl >> 64) + (mid >> 64);
        (hi, lo)
    }

    /// 256 位 / 113 位长除法，返回 (商, 余数!=0)
    /// 被 rem 始终 < denom (< 2^113)，左移后 < 2^114，不会溢出 u128。
    fn div_256_by_113(numer_hi: u128, numer_lo: u128, denom: u128) -> (u128, bool) {
        let mut rem: u128 = 0;
        let mut quot: u128 = 0;
        for i in (0..256).rev() {
            let bit: u128 = if i >= 128 {
                (numer_hi >> (i - 128)) & 1
            } else {
                (numer_lo >> i) & 1
            };
            rem = (rem << 1) | bit;
            if rem >= denom {
                rem -= denom;
                if i < 128 {
                    quot |= 1u128 << i;
                }
            }
        }
        (quot, rem != 0)
    }

    /// 精确取负
    pub fn neg_f128(self) -> Self {
        let bits = u128::from_le_bytes(self.0) ^ (1u128 << 127);
        F128(bits.to_le_bytes())
    }

    /// 精确加法
    pub fn add_f128(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() {
            return Self::nan_val();
        }
        if self.is_infinite() {
            if other.is_infinite() {
                let (sa, _, _) = self.unpack();
                let (sb, _, _) = other.unpack();
                return if sa == sb { self } else { Self::nan_val() };
            }
            return self;
        }
        if other.is_infinite() {
            return other;
        }

        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();

        if ma == 0 && mb == 0 {
            // +0 + +0 = +0; -0 + -0 = -0; 混合 → +0 (round-to-nearest)
            return Self::zero_val(sa && sb);
        }
        if ma == 0 {
            return other;
        }
        if mb == 0 {
            return self;
        }

        // 扩展 mantissa 左移 2 位（腾出 guard/round 位空间）
        let ma_ext = ma << 2;
        let mb_ext = mb << 2;
        let result_exp;

        // 对齐指数（较小的右移，保留 sticky）
        let (aligned_a, aligned_b, stk) = if ea > eb {
            let diff = (ea - eb) as u32;
            result_exp = ea;
            if diff >= 128 {
                (ma_ext, 0u128, mb_ext != 0)
            } else {
                let lost = mb_ext & ((1u128 << diff) - 1);
                (ma_ext, mb_ext >> diff, lost != 0)
            }
        } else if eb > ea {
            let diff = (eb - ea) as u32;
            result_exp = eb;
            if diff >= 128 {
                (0u128, mb_ext, ma_ext != 0)
            } else {
                let lost = ma_ext & ((1u128 << diff) - 1);
                (ma_ext >> diff, mb_ext, lost != 0)
            }
        } else {
            result_exp = ea;
            (ma_ext, mb_ext, false)
        };

        // 带符号加法
        let (result_sign, result_mant) = if sa == sb {
            (sa, aligned_a.wrapping_add(aligned_b))
        } else if aligned_a >= aligned_b {
            (sa, aligned_a - aligned_b)
        } else {
            (sb, aligned_b - aligned_a)
        };

        if result_mant == 0 {
            return Self::zero_val(false); // x + (-x) = +0
        }

        // result_mant 是 115 位（113 + 2），pack 负责规范化到 113 位
        Self::pack(result_sign, result_exp - 2, result_mant, stk)
    }

    /// 精确减法
    pub fn sub_f128(self, other: Self) -> Self {
        self.add_f128(other.neg_f128())
    }

    /// 精确乘法
    pub fn mul_f128(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() {
            return Self::nan_val();
        }
        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();
        let result_sign = sa ^ sb;

        // Inf × 0 = NaN
        if self.is_infinite() && mb == 0 {
            return Self::nan_val();
        }
        if other.is_infinite() && ma == 0 {
            return Self::nan_val();
        }
        if self.is_infinite() || other.is_infinite() {
            return Self::inf_val(result_sign);
        }
        if ma == 0 || mb == 0 {
            return Self::zero_val(result_sign);
        }

        let result_exp = ea + eb;

        // 113 × 113 = 226 位乘积
        let (hi, lo) = Self::mul_113(ma, mb);

        // 确定乘积 MSB 位置
        let total_bits = if hi != 0 {
            128 + (128 - hi.leading_zeros() as i32)
        } else {
            128 - lo.leading_zeros() as i32
        };
        let shift = total_bits - 113; // 右移到 113 位

        let (m, stk) = if shift >= 128 {
            (0u128, hi != 0 || lo != 0)
        } else if shift > 0 {
            let sh = shift as u32;
            let lost = if sh > 0 {
                lo & ((1u128 << sh) - 1)
            } else {
                0
            };
            let m = (hi << (128 - sh)) | (lo >> sh);
            (m, lost != 0)
        } else {
            (lo, false)
        };

        // pack 语义：值 = mant * 2^(exp - 112)
        // 真实值 = (ma*mb) * 2^(result_exp - 224)
        // mant = (ma*mb) >> shift，所以 exp = result_exp - 112 + shift
        Self::pack(result_sign, result_exp - 112 + shift, m, stk)
    }

    /// 精确除法
    pub fn div_f128(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() {
            return Self::nan_val();
        }
        let (sa, ea, ma) = self.unpack();
        let (sb, eb, mb) = other.unpack();
        let result_sign = sa ^ sb;

        // Inf / Inf = NaN; x / 0 = NaN（x≠0）
        if self.is_infinite() && other.is_infinite() {
            return Self::nan_val();
        }
        if self.is_infinite() {
            return Self::inf_val(result_sign);
        }
        if other.is_infinite() {
            return Self::zero_val(result_sign);
        }
        if mb == 0 {
            if ma == 0 {
                return Self::nan_val(); // 0/0 = NaN
            }
            return Self::inf_val(result_sign); // x/0 = Inf
        }
        if ma == 0 {
            return Self::zero_val(result_sign);
        }

        let result_exp = ea - eb;

        // 计算 (ma << 114) / mb，得到 ~115 位商（在 u128 范围内）
        // ma/mb ∈ [0.5, 2)，所以 (ma<<114)/mb ∈ [2^113, 2^115)，不溢出 u128
        // pack 语义：值 = mant * 2^(exp - 112)
        // 真实商 = (ma/mb) * 2^result_exp = quot * 2^(result_exp - 114)
        // 所以 exp = result_exp - 114 + 112 = result_exp - 2
        let numer_hi = ma >> 14;
        let numer_lo = ma << 14;
        let (quot, stk) = Self::div_256_by_113(numer_hi, numer_lo, mb);
        Self::pack(result_sign, result_exp - 2, quot, stk)
    }

    /// 精确取模：IEEE 754 remainder（result = a - round_to_even(a/b) * b）
    pub fn rem_f128(self, other: Self) -> Self {
        if self.is_nan() || other.is_nan() {
            return Self::nan_val();
        }
        if other.is_infinite() {
            return self; // rem(x, Inf) = x
        }
        if self.is_infinite() {
            return Self::nan_val(); // rem(Inf, y) = NaN
        }
        let (_, _, mb) = other.unpack();
        if mb == 0 {
            return Self::nan_val(); // rem(x, 0) = NaN
        }
        let (_, _, ma) = self.unpack();
        if ma == 0 {
            return self; // rem(0, y) = 0
        }

        // q = round_to_even(a / b)
        let quot = self.div_f128(other);
        // 将 q 舍入到最接近的偶数整数
        let q_bits = u128::from_le_bytes(quot.0);
        let q_exp = ((q_bits >> 112) & 0x7FFF) as i32 - 16383;
        let q_int = if q_exp >= 0 {
            // q >= 1，右移小数部分取整
            let shift = q_exp as u32;
            let q_mant = (q_bits & ((1u128 << 112) - 1)) | (1u128 << 112);
            if shift >= 113 {
                0u128
            } else {
                q_mant >> shift
            }
        } else {
            0u128
        };
        // result = a - q_int * b
        let q_val = Self::from_f64(q_int as f64);
        let prod = q_val.mul_f128(other);
        self.sub_f128(prod)
    }
}

impl fmt::Debug for F128 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.is_nan() {
            write!(f, "NaN(f128)")
        } else if self.is_infinite() {
            let bits = u128::from_le_bytes(self.0);
            if bits >> 127 != 0 {
                write!(f, "-inf(f128)")
            } else {
                write!(f, "inf(f128)")
            }
        } else {
            write!(f, "{}f128", self.to_f64())
        }
    }
}

impl fmt::Display for F128 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

// F16 运算符 trait：走精确 IEEE 754 binary16 运算，不经过 f64 中转
impl std::ops::Add for F16 {
    type Output = F16;
    fn add(self, rhs: F16) -> F16 { self.add_f16(rhs) }
}
impl std::ops::Sub for F16 {
    type Output = F16;
    fn sub(self, rhs: F16) -> F16 { self.sub_f16(rhs) }
}
impl std::ops::Mul for F16 {
    type Output = F16;
    fn mul(self, rhs: F16) -> F16 { self.mul_f16(rhs) }
}
impl std::ops::Div for F16 {
    type Output = F16;
    fn div(self, rhs: F16) -> F16 { self.div_f16(rhs) }
}
impl std::ops::Rem for F16 {
    type Output = F16;
    fn rem(self, rhs: F16) -> F16 { self.rem_f16(rhs) }
}
impl std::ops::Neg for F16 {
    type Output = F16;
    fn neg(self) -> F16 { self.neg_f16() }
}

// F128 运算符 trait：走精确 IEEE 754 binary128 运算，不经过 f64 中转
impl std::ops::Add for F128 {
    type Output = F128;
    fn add(self, rhs: F128) -> F128 { self.add_f128(rhs) }
}
impl std::ops::Sub for F128 {
    type Output = F128;
    fn sub(self, rhs: F128) -> F128 { self.sub_f128(rhs) }
}
impl std::ops::Mul for F128 {
    type Output = F128;
    fn mul(self, rhs: F128) -> F128 { self.mul_f128(rhs) }
}
impl std::ops::Div for F128 {
    type Output = F128;
    fn div(self, rhs: F128) -> F128 { self.div_f128(rhs) }
}
impl std::ops::Rem for F128 {
    type Output = F128;
    fn rem(self, rhs: F128) -> F128 { self.rem_f128(rhs) }
}
impl std::ops::Neg for F128 {
    type Output = F128;
    fn neg(self) -> F128 { self.neg_f128() }
}

// ---- ValueTag / ValueTag 已移至 Type.rs（通过 re-export 保持兼容）----

// ---- ScalarValue — 标量值 union（16 字节）----

/// 标量值 union（16 字节，容纳 i128/u128/F128）。
/// 通过 ValueTag 类型守卫访问，unsafe 代码必须有对应 tag 检查。
#[derive(Clone, Copy)]
#[repr(C)]
pub union ScalarValue {
    pub bool_val: bool,
    pub char_val: u32,
    pub i8_val: i8,
    pub i16_val: i16,
    pub i32_val: i32,
    pub i64_val: i64,
    pub u8_val: u8,
    pub u16_val: u16,
    pub u32_val: u32,
    pub u64_val: u64,
    pub isize_val: isize,
    pub usize_val: usize,
    pub i128_val: [u64; 2],
    pub u128_val: [u64; 2],
    pub f16_val: u16,
    pub f32_val: f32,
    pub f64_val: f64,
    pub f128_val: [u64; 2],
}

// ---- Value — Glue 运行时统一值表示（spec §3.3）----

/// Glue 运行时统一值表示（spec §3.3）。
/// Value 自包含：标量内联、堆对象通过 Arc 跨 worker 共享。
#[derive(Clone)]
pub enum Value {
    Null,
    Void,
    /// 标量值。tag 必须为标量变体（Bool/Char/I8.../F128），
    /// 非标量 tag（Null/Void/Ref）禁止进入此路径。
    Scalar(ScalarValue, ValueTag),
    Ref(Arc<HeapObj>),
}

impl Value {
    /// 构造标量值，debug 构建检查 tag 为标量变体。
    #[inline]
    fn scalar(sv: ScalarValue, tag: ValueTag) -> Self {
        debug_assert!(tag.is_scalar(), "non-scalar tag {:?} used for ScalarValue", tag);
        Value::Scalar(sv, tag)
    }
}

unsafe impl Send for Value {}
unsafe impl Sync for Value {}

impl Value {
    // ---- 标量构造器 ----
    // 所有构造器统一调用 Self::scalar()，使 debug_assert!(tag.is_scalar()) 守卫生效。
    pub fn i32(v: i32) -> Self { Self::scalar(ScalarValue { i32_val: v }, ValueTag::I32) }
    pub fn i64(v: i64) -> Self { Self::scalar(ScalarValue { i64_val: v }, ValueTag::I64) }
    pub fn f64(v: f64) -> Self { Self::scalar(ScalarValue { f64_val: v }, ValueTag::F64) }
    pub fn f32(v: f32) -> Self { Self::scalar(ScalarValue { f32_val: v }, ValueTag::F32) }
    pub fn bool_val(v: bool) -> Self { Self::scalar(ScalarValue { bool_val: v }, ValueTag::Bool) }
    pub fn char_val(v: char) -> Self { Self::scalar(ScalarValue { char_val: v as u32 }, ValueTag::Char) }
    pub fn i8(v: i8) -> Self { Self::scalar(ScalarValue { i8_val: v }, ValueTag::I8) }
    pub fn i16(v: i16) -> Self { Self::scalar(ScalarValue { i16_val: v }, ValueTag::I16) }
    pub fn u8(v: u8) -> Self { Self::scalar(ScalarValue { u8_val: v }, ValueTag::U8) }
    pub fn u16(v: u16) -> Self { Self::scalar(ScalarValue { u16_val: v }, ValueTag::U16) }
    pub fn u32(v: u32) -> Self { Self::scalar(ScalarValue { u32_val: v }, ValueTag::U32) }
    pub fn u64(v: u64) -> Self { Self::scalar(ScalarValue { u64_val: v }, ValueTag::U64) }
    pub fn isize_val(v: isize) -> Self { Self::scalar(ScalarValue { isize_val: v }, ValueTag::Isize) }
    pub fn usize_val(v: usize) -> Self { Self::scalar(ScalarValue { usize_val: v }, ValueTag::Usize) }
    pub fn f16(v: F16) -> Self { Self::scalar(ScalarValue { f16_val: v.0 }, ValueTag::F16) }
    // 128 位标量构造器（bit pattern 存为 [u64; 2]）
    pub fn i128(v: i128) -> Self {
        let bits = v as u128;
        Self::scalar(ScalarValue { i128_val: [(bits & 0xFFFF_FFFF_FFFF_FFFF) as u64, (bits >> 64) as u64] }, ValueTag::I128)
    }
    pub fn u128(v: u128) -> Self {
        Self::scalar(ScalarValue { u128_val: [(v & 0xFFFF_FFFF_FFFF_FFFF) as u64, (v >> 64) as u64] }, ValueTag::U128)
    }
    pub fn f128(v: F128) -> Self {
        Self::scalar(ScalarValue { f128_val: unsafe { std::mem::transmute(v.0) } }, ValueTag::F128)
    }

    // ---- 堆对象构造器 ----
    pub fn ref_val(obj: HeapObj) -> Self { Value::Ref(Arc::new(obj)) }
    pub fn from_ref(r: HeapRef) -> Self { Value::Ref(r) }

    pub const NULL: Value = Value::Null;
    pub const VOID: Value = Value::Void;

    // ---- 标量访问器（带 tag 守卫，整数类型间自动提升/截断）----
    /// 通用整数读取：覆盖所有整数 ValueTag，统一中转为 i128。
    /// 所有 as_iN/as_uN/as_isize/as_usize 委托本方法再 `as` 截断，避免特例匹配。
    pub fn as_int_i128(&self) -> i128 {
        match self {
            Value::Scalar(v, t) => unsafe {
                match t {
                    ValueTag::I8 => v.i8_val as i128,
                    ValueTag::I16 => v.i16_val as i128,
                    ValueTag::I32 => v.i32_val as i128,
                    ValueTag::I64 => v.i64_val as i128,
                    ValueTag::I128 => i128::from_ne_bytes(std::mem::transmute(v.i128_val)),
                    ValueTag::U8 => v.u8_val as i128,
                    ValueTag::U16 => v.u16_val as i128,
                    ValueTag::U32 => v.u32_val as i128,
                    ValueTag::U64 => v.u64_val as i128,
                    ValueTag::U128 => u128::from_ne_bytes(std::mem::transmute(v.u128_val)) as i128,
                    ValueTag::Isize => v.isize_val as i128,
                    ValueTag::Usize => v.usize_val as i128,
                    ValueTag::Char => v.char_val as i128,
                    _ => 0,
                }
            },
            _ => 0,
        }
    }
    /// 通用浮点读取：覆盖 F16/F32/F64/F128，统一中转为 f64。
    /// 所有 as_fN 委托本方法，避免特例匹配。
    pub fn as_float_f64(&self) -> f64 {
        match self {
            Value::Scalar(v, t) => unsafe {
                match t {
                    ValueTag::F16 => F16(v.f16_val).to_f64(),
                    ValueTag::F32 => v.f32_val as f64,
                    ValueTag::F64 => v.f64_val,
                    ValueTag::F128 => F128(std::mem::transmute(v.f128_val)).to_f64(),
                    _ => 0.0,
                }
            },
            _ => 0.0,
        }
    }
    // ---- 整数访问器：统一委托 as_int_i128，支持任意整数类型互读 ----
    pub fn as_i8(&self) -> i8 { self.as_int_i128() as i8 }
    pub fn as_i16(&self) -> i16 { self.as_int_i128() as i16 }
    pub fn as_i32(&self) -> i32 { self.as_int_i128() as i32 }
    pub fn as_i64(&self) -> i64 { self.as_int_i128() as i64 }
    pub fn as_i128(&self) -> i128 { self.as_int_i128() }
    pub fn as_u8(&self) -> u8 { self.as_int_i128() as u8 }
    pub fn as_u16(&self) -> u16 { self.as_int_i128() as u16 }
    pub fn as_u32(&self) -> u32 { self.as_int_i128() as u32 }
    pub fn as_u64(&self) -> u64 { self.as_int_i128() as u64 }
    pub fn as_u128(&self) -> u128 { self.as_int_i128() as u128 }
    pub fn as_isize(&self) -> isize { self.as_int_i128() as isize }
    pub fn as_usize(&self) -> usize { self.as_int_i128() as usize }
    // ---- 浮点访问器：统一委托 as_float_f64，支持任意浮点类型互读 ----
    pub fn as_f16(&self) -> F16 { F16::from_f64(self.as_float_f64()) }
    pub fn as_f32(&self) -> f32 { self.as_float_f64() as f32 }
    pub fn as_f64(&self) -> f64 { self.as_float_f64() }
    pub fn as_f128(&self) -> F128 { F128::from_f64(self.as_float_f64()) }
    // ---- 其他标量访问器 ----
    pub fn as_bool(&self) -> bool { match self { Value::Scalar(v, ValueTag::Bool) => unsafe { v.bool_val }, _ => false } }
    pub fn as_char(&self) -> char { match self { Value::Scalar(v, ValueTag::Char) => unsafe { char::from_u32_unchecked(v.char_val) }, _ => '\0' } }

    // ---- 堆对象访问器 ----
    pub fn heap_obj(&self) -> Option<&HeapObj> { match self { Value::Ref(r) => Some(r.as_ref()), _ => None } }
    pub fn heap_ref(&self) -> Option<HeapRef> { match self { Value::Ref(r) => Some(r.clone()), _ => None } }

    // ---- 判别 ----
    pub fn is_null(&self) -> bool { matches!(self, Value::Null) }
    pub fn is_void(&self) -> bool { matches!(self, Value::Void) }
    pub fn is_ref(&self) -> bool { matches!(self, Value::Ref(_)) }

    // ---- 标量 tag 访问（供 Hash/Debug/反射适配）----
    pub fn scalar_tag(&self) -> Option<ValueTag> {
        match self { Value::Scalar(_, t) => Some(*t), _ => None }
    }

    // ---- Weak 引用基础设施（用于打破 Cell 循环引用）----
    /// 返回指向自身堆对象的 Weak 引用。
    /// 仅对 `Value::Ref` 有意义；标量/Null/Void 返回 None。
    /// 调用方可将 Weak 存入 Cell 内部以打破 `a = Cell(b); b = Cell(a)` 形成的环。
    pub fn make_weak(&self) -> Option<Weak<HeapObj>> {
        match self { Value::Ref(r) => Some(Arc::downgrade(r)), _ => None }
    }

    /// 将 Weak 引用升级回 Value。若原对象已被回收则返回 None。
    pub fn upgrade_weak(weak: &Weak<HeapObj>) -> Option<Value> {
        weak.upgrade().map(Value::from_ref)
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Scalar(v, tag) => {
                // 复用 ValueHandle 的标量格式化逻辑：按 tag 读取 union 字段
                match tag {
                    ValueTag::Bool => write!(f, "{}", unsafe { v.bool_val }),
                    ValueTag::Char => write!(f, "'{}'", Char::from_codepoint_unchecked(unsafe { v.char_val })),
                    ValueTag::I8 => write!(f, "{}i8", unsafe { v.i8_val }),
                    ValueTag::I16 => write!(f, "{}i16", unsafe { v.i16_val }),
                    ValueTag::I32 => write!(f, "{}", unsafe { v.i32_val }),
                    ValueTag::I64 => write!(f, "{}i64", unsafe { v.i64_val }),
                    ValueTag::I128 => write!(f, "{}i128", unsafe { i128::from_ne_bytes(std::mem::transmute(v.i128_val)) }),
                    ValueTag::U8 => write!(f, "{}u8", unsafe { v.u8_val }),
                    ValueTag::U16 => write!(f, "{}u16", unsafe { v.u16_val }),
                    ValueTag::U32 => write!(f, "{}u32", unsafe { v.u32_val }),
                    ValueTag::U64 => write!(f, "{}u64", unsafe { v.u64_val }),
                    ValueTag::U128 => write!(f, "{}u128", unsafe { u128::from_ne_bytes(std::mem::transmute(v.u128_val)) }),
                    ValueTag::Isize => write!(f, "{}isize", unsafe { v.isize_val }),
                    ValueTag::Usize => write!(f, "{}usize", unsafe { v.usize_val }),
                    ValueTag::F16 => write!(f, "{:?}", F16(unsafe { v.f16_val })),
                    ValueTag::F32 => write!(f, "{}f32", unsafe { v.f32_val }),
                    ValueTag::F64 => write!(f, "{}", unsafe { v.f64_val }),
                    ValueTag::F128 => write!(f, "{:?}", F128(unsafe { std::mem::transmute(v.f128_val) })),
                    _ => unreachable!("non-scalar tag {:?} in ScalarValue", tag),
                }
            }
            Value::Ref(r) => fmt::Debug::fmt(r.as_ref(), f),
        }
    }
}

impl Hash for Value {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            Value::Null | Value::Void => {}
            Value::Scalar(v, tag) => {
                tag.hash(state);
                // 按 tag 哈希对应 union 字段
                match tag {
                    ValueTag::Bool => unsafe { v.bool_val }.hash(state),
                    ValueTag::Char => unsafe { v.char_val }.hash(state),
                    ValueTag::I8 => unsafe { v.i8_val }.hash(state),
                    ValueTag::I16 => unsafe { v.i16_val }.hash(state),
                    ValueTag::I32 => unsafe { v.i32_val }.hash(state),
                    ValueTag::I64 => unsafe { v.i64_val }.hash(state),
                    ValueTag::I128 => unsafe { v.i128_val }.hash(state),
                    ValueTag::U8 => unsafe { v.u8_val }.hash(state),
                    ValueTag::U16 => unsafe { v.u16_val }.hash(state),
                    ValueTag::U32 => unsafe { v.u32_val }.hash(state),
                    ValueTag::U64 => unsafe { v.u64_val }.hash(state),
                    ValueTag::U128 => unsafe { v.u128_val }.hash(state),
                    ValueTag::Isize => unsafe { v.isize_val }.hash(state),
                    ValueTag::Usize => unsafe { v.usize_val }.hash(state),
                    ValueTag::F16 => unsafe { v.f16_val }.hash(state),
                    ValueTag::F32 => unsafe { v.f32_val }.to_bits().hash(state),
                    ValueTag::F64 => unsafe { v.f64_val }.to_bits().hash(state),
                    ValueTag::F128 => unsafe { v.f128_val }.hash(state),
                    _ => unreachable!("non-scalar tag {:?} in ScalarValue", tag),
                }
            }
            Value::Ref(r) => (Arc::as_ptr(r) as usize).hash(state),
        }
    }
}

// ---- ValueHandle — 4B 索引句柄 ----

/// Glue 值的唯一句柄：4B 索引，编码类型桶 + 桶内索引。
/// 高 8 位 = ValueTag，低 24 位 = 桶内索引。
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ValueHandle(u32);

impl ValueHandle {
    const TAG_SHIFT: u32 = 24;
    const INDEX_MASK: u32 = 0x00FF_FFFF;

    #[inline]
    pub fn new(tag: ValueTag, index: usize) -> Self {
        // [V-3] release 也保留检查：index >= 2^24 会静默截断（MASK 抹掉高位）导致
        // 两个不同索引产生相同 ValueHandle → 句柄别名损坏。这是不可恢复的不变式违反，
        // 显式 panic 优于静默损坏（arena 不应分配超 16M 个同类型值）。
        assert!(index < (1 << 24), "ValueHandle index overflow: {index} >= 2^24");
        Self(((tag as u8 as u32) << Self::TAG_SHIFT) | (index as u32 & Self::INDEX_MASK))
    }

    #[inline]
    pub fn tag(self) -> ValueTag {
        // FFI 防御：extern "C" 原语经 from_raw 还原的 u32 可能携带越界 tag
        // （21..=255）。transmute 到 #[repr(u8)] enum 的非法判别值是 UB，
        // 故用 match 显式映射，越界统一兜底为 Null，保证任何 u32 都安全。
        match (self.0 >> Self::TAG_SHIFT) as u8 {
            0 => ValueTag::Null,
            1 => ValueTag::Void,
            2 => ValueTag::Bool,
            3 => ValueTag::Char,
            4 => ValueTag::I8,
            5 => ValueTag::I16,
            6 => ValueTag::I32,
            7 => ValueTag::I64,
            8 => ValueTag::U8,
            9 => ValueTag::U16,
            10 => ValueTag::U32,
            11 => ValueTag::U64,
            12 => ValueTag::Isize,
            13 => ValueTag::Usize,
            14 => ValueTag::I128,
            15 => ValueTag::U128,
            16 => ValueTag::F16,
            17 => ValueTag::F32,
            18 => ValueTag::F64,
            19 => ValueTag::F128,
            20 => ValueTag::Ref,
            _ => ValueTag::Null,
        }
    }

    #[inline]
    pub fn index(self) -> usize {
        (self.0 & Self::INDEX_MASK) as usize
    }

    /// 从原始 u32 构造 ValueHandle（供 extern "C" 原语跨 ABI 边界还原）
    #[inline]
    pub fn from_raw(raw: u32) -> Self {
        Self(raw)
    }

    /// 转为原始 u32（供 extern "C" 原语跨 ABI 边界传递）
    #[inline]
    pub fn to_raw(self) -> u32 {
        self.0
    }

    pub const NULL: ValueHandle = ValueHandle((ValueTag::Null as u8 as u32) << 24);
    pub const VOID: ValueHandle = ValueHandle((ValueTag::Void as u8 as u32) << 24);
    pub const TRUE: ValueHandle = ValueHandle(((ValueTag::Bool as u8 as u32) << 24) | 1);
    pub const FALSE: ValueHandle = ValueHandle((ValueTag::Bool as u8 as u32) << 24);
}

impl Default for ValueHandle {
    fn default() -> Self {
        ValueHandle::VOID
    }
}

impl fmt::Debug for ValueHandle {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "ValueHandle({:?}, {})", self.tag(), self.index())
    }
}

impl fmt::Display for ValueHandle {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

// ---- Char / CharError ----

/// 字符错误：codepoint 越界
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharError {
    InvalidCodepoint,
}

/// Unicode 字符：包装 codepoint（u32）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Char {
    pub codepoint: u32,
}

impl Char {
    pub fn from_codepoint(cp: u32) -> Result<Self, CharError> {
        if cp > 0x10FFFF || (0xD800..=0xDFFF).contains(&cp) {
            return Err(CharError::InvalidCodepoint);
        }
        Ok(Char { codepoint: cp })
    }

    pub fn from_codepoint_unchecked(cp: u32) -> Self {
        Char { codepoint: cp }
    }

    pub fn codepoint(self) -> u32 {
        self.codepoint
    }

    pub fn is_ascii(self) -> bool {
        self.codepoint < 0x80
    }

    pub fn is_digit(self) -> bool {
        (b'0' as u32..=b'9' as u32).contains(&self.codepoint)
    }

    pub fn is_alpha(self) -> bool {
        (b'a' as u32..=b'z' as u32).contains(&self.codepoint)
            || (b'A' as u32..=b'Z' as u32).contains(&self.codepoint)
    }

    pub fn is_alphanumeric(self) -> bool {
        self.is_alpha() || self.is_digit()
    }

    pub fn is_whitespace(self) -> bool {
        matches!(self.codepoint, 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0x85 | 0xA0)
    }

    pub fn to_upper(self) -> Self {
        if (b'a' as u32..=b'z' as u32).contains(&self.codepoint) {
            Char { codepoint: self.codepoint - 32 }
        } else {
            self
        }
    }

    pub fn to_lower(self) -> Self {
        if (b'A' as u32..=b'Z' as u32).contains(&self.codepoint) {
            Char { codepoint: self.codepoint + 32 }
        } else {
            self
        }
    }

    pub fn successor(self) -> Self {
        // [V-6] 跳过代理区 + 饱和到 0x10FFFF，避免 wrapping 回绕产生非法 codepoint
        let next = if self.codepoint >= 0x10FFFF {
            0x10FFFF
        } else if self.codepoint == 0xD7FF {
            0xE000
        } else {
            self.codepoint + 1
        };
        Char { codepoint: next }
    }

    pub fn predecessor(self) -> Self {
        // [V-6] 跳过代理区 + 饱和到 0，避免 wrapping 回绕产生非法 codepoint
        let prev = if self.codepoint == 0 {
            0
        } else if self.codepoint == 0xE000 {
            0xD7FF
        } else {
            self.codepoint - 1
        };
        Char { codepoint: prev }
    }

    pub fn compare(self, other: Self) -> Ordering {
        self.codepoint.cmp(&other.codepoint)
    }
}

impl fmt::Display for Char {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if let Some(c) = char::from_u32(self.codepoint) {
            write!(f, "{}", c)
        } else {
            write!(f, "\u{FFFD}")
        }
    }
}

impl From<char> for Char {
    fn from(c: char) -> Self {
        Char { codepoint: c as u32 }
    }
}

// =========================================================================
// 第二部分：堆对象类型（合并 6 个文件）
// =========================================================================

// ---- str.rs → GlueStr ----

/// Glue 字符串：引用计数的不可变 UTF-8 字符串
#[derive(Debug, Clone)]
pub struct GlueStr {
    inner: Arc<str>,
}

impl GlueStr {
    pub fn new(s: impl Into<String>) -> Self {
        Self { inner: Arc::from(s.into().as_str()) }
    }
    pub fn from_rust_str(s: &str) -> Self {
        Self { inner: Arc::from(s) }
    }
    pub fn bytes(&self) -> &str {
        &self.inner
    }
    pub fn byte_len(&self) -> usize {
        self.inner.len()
    }
    pub fn codepoint_count(&self) -> usize {
        self.inner.chars().count()
    }
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
    pub fn concat(&self, other: &Self) -> Self {
        let mut buf = String::with_capacity(self.byte_len() + other.byte_len());
        buf.push_str(&self.inner);
        buf.push_str(&other.inner);
        Self::from_rust_str(&buf)
    }
    pub fn equals(&self, other: &Self) -> bool {
        self.inner == other.inner
    }
    pub fn compare(&self, other: &Self) -> Ordering {
        self.inner.cmp(&other.inner)
    }

    /// 按码点索引取字符（UTF-8 安全）。
    ///
    /// 返回第 idx 个 Unicode 码点。越界返回 None。
    pub fn char_at(&self, idx: usize) -> Option<char> {
        self.inner.chars().nth(idx)
    }
}

impl PartialEq for GlueStr {
    fn eq(&self, other: &Self) -> bool {
        self.inner == other.inner
    }
}
impl Eq for GlueStr {}

impl Hash for GlueStr {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.inner.hash(state);
    }
}

impl fmt::Display for GlueStr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.inner)
    }
}

// ---- composite.rs → ArrayValue, RecordField, RecordValue, AdtField, AdtValue, NewtypeValue, Cell, Range, RangeIter ----

/// 数组值：元素可变（支持 push/pop），`fixed_size` 为 `Some` 时表示固定大小数组
#[derive(Debug, Clone)]
pub struct ArrayValue {
    pub elements: Vec<Value>,
    pub fixed_size: Option<u64>,
    pub elem_is_ref: bool,
    pub scalar_soa: Option<ScalarSoA>,
}

/// SoA 连续存储：当数组元素全为同类型标量时启用 SIMD 快路径
#[derive(Debug, Clone)]
pub enum ScalarSoA {
    I8(Vec<i8>),
    I16(Vec<i16>),
    I32(Vec<i32>),
    I64(Vec<i64>),
    U8(Vec<u8>),
    U16(Vec<u16>),
    U32(Vec<u32>),
    U64(Vec<u64>),
    Bool(Vec<bool>),
    Char(Vec<u32>),
    F32(Vec<f32>),
    F64(Vec<f64>),
}

impl ArrayValue {
    pub fn new(elements: Vec<Value>) -> Self {
        Self { elements, fixed_size: None, elem_is_ref: false, scalar_soa: None }
    }
    pub fn new_fixed(elements: Vec<Value>, size: u64) -> Self {
        Self { elements, fixed_size: Some(size), elem_is_ref: false, scalar_soa: None }
    }
    pub fn len(&self) -> usize {
        self.elements.len()
    }
    pub fn is_empty(&self) -> bool {
        self.elements.is_empty()
    }
    pub fn get(&self, index: usize) -> Option<&Value> {
        self.elements.get(index)
    }
    pub fn push(&mut self, val: Value) {
        self.elements.push(val);
    }
    pub fn pop(&mut self) -> Option<Value> {
        self.elements.pop()
    }
    /// 统一收集 u8 字节：SOA 快路径（U8 连续存储）或回退到逐元素提取。
    /// 封装双表示访问，调用方无需关心 SOA 是否启用。
    pub fn collect_u8_bytes(&self) -> Vec<u8> {
        if let Some(crate::Value::ScalarSoA::U8(ref data)) = self.scalar_soa {
            return data.clone();
        }
        self.elements.iter().map(|e| e.as_u8()).collect()
    }
}

/// 记录字段：可选名称 + 值
#[derive(Debug, Clone)]
pub struct RecordField {
    pub name: Option<String>,
    pub value: ValueHandle,
}

/// 记录值：具名类型的结构化数据
#[derive(Debug, Clone)]
pub struct RecordValue {
    pub type_name: String,
    pub fields: Vec<Value>,
    pub field_names: Vec<Option<String>>,
    pub field_ref_bits: u64,
}

impl RecordValue {
    pub fn new(type_name: String, fields: Vec<Value>, field_names: Vec<Option<String>>) -> Self {
        Self { type_name, fields, field_names, field_ref_bits: 0 }
    }
    pub fn get_field(&self, index: usize) -> Option<&Value> {
        self.fields.get(index)
    }
    pub fn find_field(&self, name: &str) -> Option<&Value> {
        for (i, field_name) in self.field_names.iter().enumerate() {
            if let Some(n) = field_name {
                if n == name {
                    return self.fields.get(i);
                }
            }
        }
        None
    }
}

/// ADT 字段：构造器的参数
#[derive(Debug, Clone)]
pub struct AdtField {
    pub name: Option<String>,
    pub value: Value,
}

/// ADT 值：代数数据类型实例
#[derive(Debug, Clone)]
pub struct AdtValue {
    pub type_name: String,
    pub constructor: String,
    pub fields: Vec<AdtField>,
    pub field_ref_bits: u64,
}

impl AdtValue {
    pub fn new(type_name: String, constructor: String, fields: Vec<AdtField>) -> Self {
        Self { type_name, constructor, fields, field_ref_bits: 0 }
    }
    pub fn get_field(&self, index: usize) -> Option<&Value> {
        self.fields.get(index).map(|f| &f.value)
    }
    pub fn find_field(&self, name: &str) -> Option<&Value> {
        for field in &self.fields {
            if let Some(n) = &field.name {
                if n == name {
                    return Some(&field.value);
                }
            }
        }
        None
    }
}

/// Newtype 值：包装单个内部值的具名类型
#[derive(Debug, Clone)]
pub struct NewtypeValue {
    pub type_name: String,
    pub inner: ValueHandle,
}

/// Cell：可变引用单元（`&T` 引用语义的运行时载体）
///
/// 内部持有 `Value`（自包含值，标量内联 + 堆对象 Arc 共享）。
/// `&expr` 创建 `Arc<HeapObj::Cell>` 包装当前值；`*r` 读取 Cell；
/// `*r = v` 写入 Cell。多個引用共享同一 Arc，写入对所有引用可见。
#[derive(Debug)]
pub struct Cell {
    pub inner: parking_lot::Mutex<Value>,
}

impl Clone for Cell {
    fn clone(&self) -> Self {
        Self { inner: parking_lot::Mutex::new(self.get()) }
    }
}

impl Cell {
    pub fn new(val: Value) -> Self {
        Self { inner: parking_lot::Mutex::new(val) }
    }
    /// 返回内部值的克隆。
    pub fn get(&self) -> Value {
        self.inner.lock().clone()
    }
    pub fn set(&self, val: Value) {
        *self.inner.lock() = val;
    }

    /// 返回指向自身的 Weak 引用（用于打破循环引用）。
    /// 调用方需确保 Cell 被包装在 `Arc<HeapObj::Cell>` 中；
    /// 若传入的 Arc 并非 Cell，返回 None。
    pub fn downgrade(arc: &Arc<HeapObj>) -> Option<Weak<HeapObj>> {
        match arc.as_ref() {
            HeapObj::Cell(_) => Some(Arc::downgrade(arc)),
            _ => None,
        }
    }
}

/// 范围值
#[derive(Debug, Clone)]
pub struct Range {
    pub start: i64,
    pub end: i64,
    pub inclusive: bool,
}

impl Range {
    pub fn new(start: i64, end: i64, inclusive: bool) -> Self {
        Self { start, end, inclusive }
    }
    pub fn contains(&self, val: i64) -> bool {
        if self.inclusive {
            val >= self.start && val <= self.end
        } else {
            val >= self.start && val < self.end
        }
    }
    pub fn len(&self) -> usize {
        if self.inclusive {
            if self.end >= self.start {
                (self.end - self.start + 1) as usize
            } else {
                0
            }
        } else if self.end > self.start {
            (self.end - self.start) as usize
        } else {
            0
        }
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    pub fn iter(&self) -> RangeIter {
        RangeIter { current: self.start, end: self.end, inclusive: self.inclusive }
    }
}

/// 范围迭代器（composite 内部）
#[derive(Debug, Clone)]
pub struct RangeIter {
    pub current: i64,
    pub end: i64,
    pub inclusive: bool,
}

// ---- callable.rs → BuiltinFn, Builtin, Closure, PartialApplication, TraitValue, LazyValue ----

/// 内建函数指针类型
pub type BuiltinFn = fn(&[ValueHandle]) -> Result<ValueHandle, String>;

/// 内建函数值
#[derive(Clone)]
pub struct Builtin {
    pub fn_ptr: BuiltinFn,
    pub name: String,
}

impl fmt::Debug for Builtin {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "<builtin {}>", self.name)
    }
}

/// 闭包值
#[derive(Debug, Clone)]
pub struct Closure {
    pub func_id: u32,
    pub arity: u8,
    pub upvalues: Vec<Value>,
    pub bound_args: Vec<ValueHandle>,
    pub self_upvalue_idx: i32,
    pub upvalue_ref_bits: u8,
    pub cell_upvalues: u8,
}

/// 偏应用值：对函数/闭包绑定了前导参数后得到的可调用值。
///
/// 统一调用语义：当新参数数 < remaining_arity → 产出新的 Partial（链式偏应用）；
/// 当新参数数 >= remaining_arity → 合并 bound_args + 新参数 + upvalues 启动子图。
/// upvalues 来自源 Closure（顶层函数偏应用时为空），与 Closure 的 upvalues 语义一致。
#[derive(Debug, Clone)]
pub struct PartialApplication {
    /// 目标子图 id（与 Closure.func_id 语义一致）
    pub func_id: u32,
    /// 来自源 Closure 的 upvalues（顶层函数偏应用时为空）
    pub upvalues: Vec<Value>,
    /// 已绑定的前导参数（按原函数参数顺序）
    pub bound_args: Vec<Value>,
    /// 仍需参数数 = subgraph.param_count - upvalues.len() - bound_args.len()
    pub remaining_arity: u8,
    /// 递归闭包自引用 upvalue 索引（-1 表示无自引用）
    pub self_upvalue_idx: i32,
}

/// Trait 值
#[derive(Debug, Clone)]
pub struct TraitValue {
    pub trait_name: String,
    pub method_names: Vec<String>,
    pub method_values: Vec<Value>,
    pub data: Option<Value>,
    pub owned: bool,
}

/// 惰性值
pub struct LazyValue {
    /// 缓存的求值结果（首次 force 后填充）
    /// Mutex 允许通过 &LazyValue 更新缓存（Arc 共享场景下的 interior mutability）
    pub cached: Mutex<Option<Value>>,
    /// 是否已求值
    pub forced: AtomicBool,
    /// thunk 子图的 Closure（func_id = thunk_sg, upvalues = 捕获值）
    /// force 时取此 Closure 启动子图计算，结果存入 cached
    pub data: Option<Value>,
}

impl Clone for LazyValue {
    fn clone(&self) -> Self {
        Self {
            cached: Mutex::new(self.cached.lock().unwrap().clone()),
            forced: AtomicBool::new(self.forced.load(std::sync::atomic::Ordering::Relaxed)),
            data: self.data.clone(),
        }
    }
}

impl fmt::Debug for LazyValue {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("LazyValue")
            .field("cached", &self.cached.lock().unwrap().is_some())
            .field("forced", &self.forced.load(std::sync::atomic::Ordering::Relaxed))
            .field("has_data", &self.data.is_some())
            .finish()
    }
}

// ---- control.rs → ErrorValue, ThrowPayload, ThrowValue ----

/// 错误值
#[derive(Debug, Clone)]
pub struct ErrorValue {
    pub type_name: String,
    pub message: String,
    pub is_error_subtype: bool,
}

/// 抛出载荷
#[derive(Debug, Clone)]
pub enum ThrowPayload {
    Ok(Value),
    Err(Arc<RecordValue>),
}

/// 抛出值
#[derive(Debug, Clone)]
pub struct ThrowValue {
    pub payload: ThrowPayload,
}

// ---- iterator.rs → 已全部迁移至 Glue builtin (Iterator.glue) ----
// 注：ArrayIterator / StringIterator / RangeIterator 均已迁移至 Glue builtin。

// ---- concurrent.rs → AtomicValue, AsyncStatus, AsyncHandle, ChannelValue, SenderValue, ReceiverValue ----

/// 原子值
#[derive(Debug)]
pub struct AtomicValue {
    data: Mutex<Value>,
}

impl AtomicValue {
    pub fn new(val: Value) -> Self {
        Self { data: Mutex::new(val) }
    }
    pub fn load(&self) -> Value {
        self.data.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    pub fn store(&self, val: Value) {
        *self.data.lock().unwrap_or_else(|e| e.into_inner()) = val;
    }
    pub fn swap(&self, val: Value) -> Value {
        std::mem::replace(&mut *self.data.lock().unwrap_or_else(|e| e.into_inner()), val)
    }
}

impl Clone for AtomicValue {
    fn clone(&self) -> Self {
        Self::new(self.load())
    }
}

/// 异步任务状态
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsyncStatus {
    Pending,
    Running,
    Completed,
    Cancelled,
    Failed,
}

/// 异步句柄
#[derive(Debug)]
pub struct AsyncHandle {
    status: Mutex<AsyncStatus>,
    result: Mutex<Option<ValueHandle>>,
}

impl AsyncHandle {
    pub fn new() -> Self {
        Self { status: Mutex::new(AsyncStatus::Pending), result: Mutex::new(None) }
    }
    pub fn status(&self) -> AsyncStatus {
        *self.status.lock().unwrap_or_else(|e| e.into_inner())
    }
    pub fn set_status(&self, status: AsyncStatus) {
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = status;
    }
    pub fn result(&self) -> Option<ValueHandle> {
        *self.result.lock().unwrap_or_else(|e| e.into_inner())
    }
    pub fn set_result(&self, val: ValueHandle) {
        *self.result.lock().unwrap_or_else(|e| e.into_inner()) = Some(val);
    }
}

impl Default for AsyncHandle {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for AsyncHandle {
    fn clone(&self) -> Self {
        let status = self.status();
        let result = self.result();
        Self { status: Mutex::new(status), result: Mutex::new(result) }
    }
}

/// 全局 channel id 计数器（线程安全，单/多 worker 共用）
static CHANNEL_ID_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 通道值
///
/// 统一存储 Engine 的 Value（非 ValueHandle），与 async 运行时一致。
/// id 用于 RuntimeEvent::ChannelReady 事件标识（send 后内联触发 on_event_arrived）。
#[derive(Debug)]
pub struct ChannelValue {
    id: u64,
    buffer: Mutex<VecDeque<Value>>,
    capacity: usize,
    closed: Mutex<bool>,
}

/// channel send 失败原因（运行时条件，非程序员错误）。
#[derive(Debug, Clone, Copy)]
pub enum ChannelSendError {
    /// channel 已关闭
    Closed,
    /// 有界 channel 已满
    Full { capacity: usize },
}

impl ChannelSendError {
    pub fn message(&self) -> &'static str {
        match self {
            ChannelSendError::Closed => "send on closed channel",
            ChannelSendError::Full { .. } => "channel full",
        }
    }
}

impl ChannelValue {
    pub fn new(capacity: usize) -> Self {
        Self {
            id: CHANNEL_ID_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            buffer: Mutex::new(VecDeque::new()),
            capacity,
            closed: Mutex::new(false),
        }
    }
    /// 返回 channel 的唯一 id（用于 RuntimeEvent::ChannelReady 事件标识）
    pub fn id(&self) -> u64 {
        self.id
    }
    /// 非阻塞发送：push 到 buffer。满或已关闭时返回 Err（运行时条件，非程序员错误）。
    pub fn send(&self, val: Value) -> Result<(), ChannelSendError> {
        let mut buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        // [V-5] 持 buffer 锁期间检查 closed，与 close（同样持 buffer 锁）互斥，消除 TOCTOU
        if *self.closed.lock().unwrap_or_else(|e| e.into_inner()) {
            return Err(ChannelSendError::Closed);
        }
        if self.capacity > 0 && buf.len() >= self.capacity {
            return Err(ChannelSendError::Full { capacity: self.capacity });
        }
        buf.push_back(val);
        Ok(())
    }
    /// 接收：pop 从 buffer 前端，无数据返回 None（await 路径在 resolve_and_check_await 处理挂起）
    pub fn recv(&self) -> Option<Value> {
        let mut buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        buf.pop_front()
    }
    /// 是否有数据可读
    pub fn has_data(&self) -> bool {
        !self.buffer.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
    }
    pub fn close(&self) {
        // [V-5] 持 buffer 锁设置 closed，与 send 的持锁检查互斥（锁序 buffer→closed 一致，无死锁）
        let _buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        *self.closed.lock().unwrap_or_else(|e| e.into_inner()) = true;
    }
    pub fn is_closed(&self) -> bool {
        *self.closed.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Clone for ChannelValue {
    fn clone(&self) -> Self {
        let buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner()).clone();
        Self {
            id: self.id,
            buffer: Mutex::new(buf),
            capacity: self.capacity,
            closed: Mutex::new(*self.closed.lock().unwrap_or_else(|e| e.into_inner())),
        }
    }
}

/// 发送端值
#[derive(Debug, Clone)]
pub struct SenderValue {
    pub channel: Arc<ChannelValue>,
}

/// 接收端值
#[derive(Debug, Clone)]
pub struct ReceiverValue {
    pub channel: Arc<ChannelValue>,
}

// ---- heap.rs → HeapObj enum + HeapRef + RefKind + impl ----

/// 堆对象：所有堆分配值类型的统一表示（23 种）
#[derive(Debug, Clone)]
pub enum HeapObj {
    Str(GlueStr),
    Array(ArrayValue),
    Record(RecordValue),
    Adt(AdtValue),
    Newtype(NewtypeValue),
    Cell(Cell),
    Range(Range),
    Closure(Closure),
    Partial(PartialApplication),
    Builtin(Builtin),
    TraitVal(TraitValue),
    LazyVal(LazyValue),
    ErrorVal(ErrorValue),
    ThrowVal(ThrowValue),
    AtomicVal(AtomicValue),
    AsyncVal(AsyncHandle),
    ChannelVal(Arc<ChannelValue>),
    SenderVal(SenderValue),
    ReceiverVal(ReceiverValue),
    CoroutineFrame,
}

/// 堆引用：引用计数的堆对象
pub type HeapRef = Arc<HeapObj>;

/// 引用类型枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefKind {
    Str, Array, Record, Adt, Newtype, Cell, Range, Closure, Partial, Builtin,
    TraitVal, LazyVal, ErrorVal, ThrowVal,
    AtomicVal, AsyncVal, ChannelVal, SenderVal, ReceiverVal, CoroutineFrame,
}

impl HeapObj {
    /// 统一提取底层 channel：ChannelVal/SenderVal/ReceiverVal 共享同一 Arc<ChannelValue>。
    /// 消除各处对三种类型的重复分派，send/close/await/select 统一调用此方法。
    pub fn channel(&self) -> Option<&Arc<ChannelValue>> {
        match self {
            HeapObj::ChannelVal(ch) => Some(ch),
            HeapObj::SenderVal(tx) => Some(&tx.channel),
            HeapObj::ReceiverVal(rx) => Some(&rx.channel),
            _ => None,
        }
    }

    /// 统一字段访问：Record/Adt 按名查找字段值，
    /// ChannelVal 按 channel 协议字段（sender/receiver）派生。
    /// 消除 compute_record_field_get 中对字段名和类型的硬编码分派。
    pub fn field_get(&self, name: &str) -> Option<Value> {
        match self {
            HeapObj::Record(r) => r.find_field(name).cloned(),
            HeapObj::Adt(a) => a.find_field(name).cloned(),
            HeapObj::ChannelVal(ch) => match name {
                "sender" => Some(Value::ref_val(HeapObj::SenderVal(SenderValue { channel: ch.clone() }))),
                "receiver" => Some(Value::ref_val(HeapObj::ReceiverVal(ReceiverValue { channel: ch.clone() }))),
                _ => None,
            },
            _ => None,
        }
    }

    pub fn ref_kind(&self) -> RefKind {
        match self {
            HeapObj::Str(_) => RefKind::Str,
            HeapObj::Array(_) => RefKind::Array,
            HeapObj::Record(_) => RefKind::Record,
            HeapObj::Adt(_) => RefKind::Adt,
            HeapObj::Newtype(_) => RefKind::Newtype,
            HeapObj::Cell(_) => RefKind::Cell,
            HeapObj::Range(_) => RefKind::Range,
            HeapObj::Closure(_) => RefKind::Closure,
            HeapObj::Partial(_) => RefKind::Partial,
            HeapObj::Builtin(_) => RefKind::Builtin,
            HeapObj::TraitVal(_) => RefKind::TraitVal,
            HeapObj::LazyVal(_) => RefKind::LazyVal,
            HeapObj::ErrorVal(_) => RefKind::ErrorVal,
            HeapObj::ThrowVal(_) => RefKind::ThrowVal,
            HeapObj::AtomicVal(_) => RefKind::AtomicVal,
            HeapObj::AsyncVal(_) => RefKind::AsyncVal,
            HeapObj::ChannelVal(_) => RefKind::ChannelVal,
            HeapObj::SenderVal(_) => RefKind::SenderVal,
            HeapObj::ReceiverVal(_) => RefKind::ReceiverVal,
            HeapObj::CoroutineFrame => RefKind::CoroutineFrame,
        }
    }

    pub fn type_name(&self) -> &'static str {
        match self {
            HeapObj::Str(_) => "str",
            HeapObj::Array(_) => "array",
            HeapObj::Record(_) => "record",
            HeapObj::Adt(_) => "adt",
            HeapObj::Newtype(_) => "newtype",
            HeapObj::Cell(_) => "cell",
            HeapObj::Range(_) => "range",
            HeapObj::Closure(_) => "closure",
            HeapObj::Partial(_) => "partial",
            HeapObj::Builtin(_) => "builtin",
            HeapObj::TraitVal(_) => "trait",
            HeapObj::LazyVal(_) => "lazy",
            HeapObj::ErrorVal(_) => "error",
            HeapObj::ThrowVal(_) => "throw",
            HeapObj::AtomicVal(_) => "atomic",
            HeapObj::AsyncVal(_) => "async",
            HeapObj::ChannelVal(_) => "channel",
            HeapObj::SenderVal(_) => "sender",
            HeapObj::ReceiverVal(_) => "receiver",
            HeapObj::CoroutineFrame => "coroutine",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            HeapObj::Str(_) => "str",
            HeapObj::Array(_) => "[...]",
            HeapObj::Record(_) => "record",
            HeapObj::Adt(_) => "adt",
            HeapObj::Newtype(_) => "newtype",
            HeapObj::Cell(_) => "cell",
            HeapObj::Range(_) => "range",
            HeapObj::Closure(_) => "<closure>",
            HeapObj::Partial(_) => "<partial>",
            HeapObj::Builtin(_) => "<builtin>",
            HeapObj::TraitVal(_) => "<trait>",
            HeapObj::LazyVal(_) => "<lazy>",
            HeapObj::ErrorVal(_) => "<error>",
            HeapObj::ThrowVal(_) => "<throw>",
            HeapObj::AtomicVal(_) => "<atomic>",
            HeapObj::AsyncVal(_) => "<async>",
            HeapObj::ChannelVal(_) => "<channel>",
            HeapObj::SenderVal(_) => "<sender>",
            HeapObj::ReceiverVal(_) => "<receiver>",
            HeapObj::CoroutineFrame => "<coroutine>",
        }
    }

    pub fn is_memoizable(&self) -> bool {
        matches!(
            self,
            HeapObj::Str(_) | HeapObj::Array(_) | HeapObj::Record(_) | HeapObj::Adt(_)
                | HeapObj::Newtype(_) | HeapObj::Range(_) | HeapObj::ErrorVal(_) | HeapObj::ThrowVal(_)
        )
    }
}

impl Hash for HeapObj {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            HeapObj::Str(s) => s.hash(state),
            HeapObj::Array(a) => {
                a.elements.len().hash(state);
                // SoA SIMD 快路径：批量哈希标量
                if let Some(soa) = &a.scalar_soa {
                    simd_hash_soa(soa, state);
                } else {
                    for e in &a.elements {
                        e.hash(state);
                    }
                }
                a.fixed_size.hash(state);
            }
            HeapObj::Record(r) => {
                r.type_name.hash(state);
                r.fields.len().hash(state);
                for f in &r.fields {
                    f.hash(state);
                }
                r.field_names.hash(state);
            }
            HeapObj::Adt(a) => {
                a.type_name.hash(state);
                a.constructor.hash(state);
                a.fields.len().hash(state);
                for f in &a.fields {
                    f.value.hash(state);
                }
            }
            HeapObj::Newtype(n) => {
                n.type_name.hash(state);
                n.inner.hash(state);
            }
            HeapObj::Cell(c) => {
                c.inner.lock().hash(state);
            }
            HeapObj::Range(r) => {
                r.start.hash(state);
                r.end.hash(state);
                r.inclusive.hash(state);
            }
            HeapObj::ErrorVal(e) => {
                e.type_name.hash(state);
                e.message.hash(state);
                e.is_error_subtype.hash(state);
            }
            HeapObj::ThrowVal(t) => match &t.payload {
                ThrowPayload::Ok(v) => {
                    0u8.hash(state);
                    v.hash(state);
                }
                ThrowPayload::Err(r) => {
                    1u8.hash(state);
                    let ptr: *const RecordValue = Arc::as_ptr(r);
                    ptr.hash(state);
                }
            },
            HeapObj::Closure(c) => {
                c.func_id.hash(state);
                c.arity.hash(state);
                c.upvalues.len().hash(state);
            }
            HeapObj::Builtin(b) => {
                (b.fn_ptr as usize).hash(state);
                b.name.hash(state);
            }
            HeapObj::Partial(_) | HeapObj::TraitVal(_) | HeapObj::LazyVal(_)
            | HeapObj::AtomicVal(_) | HeapObj::AsyncVal(_) | HeapObj::ChannelVal(_)
            | HeapObj::SenderVal(_) | HeapObj::ReceiverVal(_) | HeapObj::CoroutineFrame => {}
        }
    }
}

// =========================================================================
// 第三部分：Bucket<T> + ValueArena（全分桶 SoA 存储）
// =========================================================================

/// 类型分桶：连续存储同类型值 + 并行引用计数 + 空闲列表回收。
struct Bucket<T: Clone> {
    data: Vec<T>,
    refcounts: Vec<u32>,
    free_list: Vec<u32>,
}

impl<T: Clone> Bucket<T> {
    fn new() -> Self {
        Self { data: Vec::new(), refcounts: Vec::new(), free_list: Vec::new() }
    }

    fn alloc(&mut self, val: T) -> u32 {
        if let Some(idx) = self.free_list.pop() {
            self.data[idx as usize] = val;
            self.refcounts[idx as usize] = 1;
            idx
        } else {
            let idx = self.data.len() as u32;
            self.data.push(val);
            self.refcounts.push(1);
            idx
        }
    }

    #[inline]
    fn get(&self, idx: u32) -> &T {
        &self.data[idx as usize]
    }

    #[inline]
    fn get_mut(&mut self, idx: u32) -> &mut T {
        &mut self.data[idx as usize]
    }

    /// 当前已分配槽位数（含空闲未回收），用于 FFI 边界校验 handle 合法性
    #[inline]
    fn len(&self) -> usize {
        self.data.len()
    }

    fn inc_ref(&mut self, idx: u32) {
        self.refcounts[idx as usize] += 1;
    }

    fn dec_ref(&mut self, idx: u32) -> bool {
        let rc = &mut self.refcounts[idx as usize];
        *rc = rc.saturating_sub(1);
        if *rc == 0 {
            self.free_list.push(idx);
            true
        } else {
            false
        }
    }

    fn _refcount(&self, idx: u32) -> u32 {
        self.refcounts[idx as usize]
    }

    /// 清空该桶的所有数据、引用计数与空闲列表，回收内存。
    fn reset(&mut self) {
        self.data.clear();
        self.refcounts.clear();
        self.free_list.clear();
    }
}

/// Value 的统一存储：按类型分桶（SoA），每种标量类型独立连续存储。
/// 堆对象（HeapObj）用 Arc，存于 ref_bucket。
pub struct ValueArena {
    char_bucket: Bucket<u32>,
    i8_bucket: Bucket<i8>,
    i16_bucket: Bucket<i16>,
    i32_bucket: Bucket<i32>,
    i64_bucket: Bucket<i64>,
    u8_bucket: Bucket<u8>,
    u16_bucket: Bucket<u16>,
    u32_bucket: Bucket<u32>,
    u64_bucket: Bucket<u64>,
    isz_bucket: Bucket<isize>,
    usz_bucket: Bucket<usize>,
    i128_bucket: Bucket<[u64; 2]>,
    u128_bucket: Bucket<[u64; 2]>,
    f16_bucket: Bucket<u16>,
    f32_bucket: Bucket<f32>,
    f64_bucket: Bucket<f64>,
    f128_bucket: Bucket<[u64; 2]>,
    ref_bucket: Bucket<Arc<HeapObj>>,
}

macro_rules! impl_scalar_bucket_methods {
    ($($tag:ident => $alloc:ident / $get:ident : $ty:ty, $bucket:ident);* $(;)?) => {
        impl ValueArena {
            $(
                #[inline]
                pub fn $alloc(&mut self, v: $ty) -> ValueHandle {
                    let idx = self.$bucket.alloc(v);
                    ValueHandle::new(ValueTag::$tag, idx as usize)
                }
                #[inline]
                pub fn $get(&self, h: ValueHandle) -> $ty {
                    *self.$bucket.get(h.index() as u32)
                }
            )*
        }
    };
}

impl_scalar_bucket_methods! {
    Char => alloc_char / get_char : u32, char_bucket;
    I8 => alloc_i8 / get_i8 : i8, i8_bucket;
    I16 => alloc_i16 / get_i16 : i16, i16_bucket;
    I32 => alloc_i32 / get_i32 : i32, i32_bucket;
    I64 => alloc_i64 / get_i64 : i64, i64_bucket;
    U8 => alloc_u8 / get_u8 : u8, u8_bucket;
    U16 => alloc_u16 / get_u16 : u16, u16_bucket;
    U32 => alloc_u32 / get_u32 : u32, u32_bucket;
    U64 => alloc_u64 / get_u64 : u64, u64_bucket;
    Isize => alloc_isize / get_isize : isize, isz_bucket;
    Usize => alloc_usize / get_usize : usize, usz_bucket;
    F16 => alloc_f16 / get_f16 : u16, f16_bucket;
    F32 => alloc_f32 / get_f32 : f32, f32_bucket;
    F64 => alloc_f64 / get_f64 : f64, f64_bucket;
}

impl ValueArena {
    // ─── 全局 arena 访问（供 extern "C" 反射原语使用）──────────────
    // Glue 是单线程编译器，thread_local 足够。
    thread_local! {
        static GLOBAL_ARENA: RefCell<ValueArena> = RefCell::new(ValueArena::new());
    }

    /// 全局 arena 只读访问
    pub fn with_global<R>(f: impl FnOnce(&ValueArena) -> R) -> R {
        Self::GLOBAL_ARENA.with(|cell| f(&cell.borrow()))
    }

    /// 全局 arena 可变访问
    pub fn with_global_mut<R>(f: impl FnOnce(&mut ValueArena) -> R) -> R {
        Self::GLOBAL_ARENA.with(|cell| f(&mut cell.borrow_mut()))
    }

    /// 从 ValueHandle 查全局 arena 拿 HeapObj（反射原语核心路径）
    /// 返回 Arc clone，避免 thread_local borrow 跨函数返回的生命周期问题。
    pub fn get_global_obj(handle: ValueHandle) -> Option<Arc<HeapObj>> {
        if handle.tag() != ValueTag::Ref {
            return None;
        }
        Some(Self::with_global(|arena| arena.get_ref(handle).clone()))
    }

    /// 校验 handle 是否指向 arena 中合法槽位（FFI 边界防御）。
    /// 标量按 tag 查对应分桶 index 范围；Null/Void/Bool 为单例恒有效。
    /// 用于 extern "C" 反射原语入口，防止 C 侧脏 handle 导致越界 panic。
    pub fn is_valid_handle(handle: ValueHandle) -> bool {
        Self::with_global(|arena| arena.is_valid_handle_inner(handle))
    }

    pub(crate) fn is_valid_handle_inner(&self, h: ValueHandle) -> bool {
        let idx = h.index();
        match h.tag() {
            ValueTag::Null | ValueTag::Void | ValueTag::Bool => true,
            ValueTag::Char => idx < self.char_bucket.len(),
            ValueTag::I8 => idx < self.i8_bucket.len(),
            ValueTag::I16 => idx < self.i16_bucket.len(),
            ValueTag::I32 => idx < self.i32_bucket.len(),
            ValueTag::I64 => idx < self.i64_bucket.len(),
            ValueTag::U8 => idx < self.u8_bucket.len(),
            ValueTag::U16 => idx < self.u16_bucket.len(),
            ValueTag::U32 => idx < self.u32_bucket.len(),
            ValueTag::U64 => idx < self.u64_bucket.len(),
            ValueTag::Isize => idx < self.isz_bucket.len(),
            ValueTag::Usize => idx < self.usz_bucket.len(),
            ValueTag::I128 => idx < self.i128_bucket.len(),
            ValueTag::U128 => idx < self.u128_bucket.len(),
            ValueTag::F16 => idx < self.f16_bucket.len(),
            ValueTag::F32 => idx < self.f32_bucket.len(),
            ValueTag::F64 => idx < self.f64_bucket.len(),
            ValueTag::F128 => idx < self.f128_bucket.len(),
            ValueTag::Ref => idx < self.ref_bucket.len(),
        }
    }

    pub fn new() -> Self {
        Self {
            char_bucket: Bucket::new(),
            i8_bucket: Bucket::new(),
            i16_bucket: Bucket::new(),
            i32_bucket: Bucket::new(),
            i64_bucket: Bucket::new(),
            u8_bucket: Bucket::new(),
            u16_bucket: Bucket::new(),
            u32_bucket: Bucket::new(),
            u64_bucket: Bucket::new(),
            isz_bucket: Bucket::new(),
            usz_bucket: Bucket::new(),
            i128_bucket: Bucket::new(),
            u128_bucket: Bucket::new(),
            f16_bucket: Bucket::new(),
            f32_bucket: Bucket::new(),
            f64_bucket: Bucket::new(),
            f128_bucket: Bucket::new(),
            ref_bucket: Bucket::new(),
        }
    }

    /// 重置 arena，清空所有分桶并回收内存。
    /// 用于反射操作后的批量清理，避免反射原语 alloc 后无人 dec_ref 导致内存堆积。
    pub fn reset(&mut self) {
        self.char_bucket.reset();
        self.i8_bucket.reset();
        self.i16_bucket.reset();
        self.i32_bucket.reset();
        self.i64_bucket.reset();
        self.u8_bucket.reset();
        self.u16_bucket.reset();
        self.u32_bucket.reset();
        self.u64_bucket.reset();
        self.isz_bucket.reset();
        self.usz_bucket.reset();
        self.i128_bucket.reset();
        self.u128_bucket.reset();
        self.f16_bucket.reset();
        self.f32_bucket.reset();
        self.f64_bucket.reset();
        self.f128_bucket.reset();
        self.ref_bucket.reset();
    }

    #[inline]
    pub fn alloc_i128(&mut self, v: i128) -> ValueHandle {
        let idx = self.i128_bucket.alloc([(v as u128 & 0xFFFF_FFFF_FFFF_FFFF) as u64, ((v as u128) >> 64) as u64]);
        ValueHandle::new(ValueTag::I128, idx as usize)
    }
    #[inline]
    pub fn get_i128(&self, h: ValueHandle) -> i128 {
        let [lo, hi] = *self.i128_bucket.get(h.index() as u32);
        ((hi as i128) << 64) | (lo as i128)
    }

    #[inline]
    pub fn alloc_u128(&mut self, v: u128) -> ValueHandle {
        let idx = self.u128_bucket.alloc([(v & 0xFFFF_FFFF_FFFF_FFFF) as u64, (v >> 64) as u64]);
        ValueHandle::new(ValueTag::U128, idx as usize)
    }
    #[inline]
    pub fn get_u128(&self, h: ValueHandle) -> u128 {
        let [lo, hi] = *self.u128_bucket.get(h.index() as u32);
        ((hi as u128) << 64) | (lo as u128)
    }

    #[inline]
    pub fn alloc_f128(&mut self, v: F128) -> ValueHandle {
        let bits = u128::from_le_bytes(v.0);
        let idx = self.f128_bucket.alloc([(bits & 0xFFFF_FFFF_FFFF_FFFF) as u64, (bits >> 64) as u64]);
        ValueHandle::new(ValueTag::F128, idx as usize)
    }
    #[inline]
    pub fn get_f128(&self, h: ValueHandle) -> F128 {
        let [lo, hi] = *self.f128_bucket.get(h.index() as u32);
        F128(((hi as u128) << 64 | lo as u128).to_le_bytes())
    }

    // ---- 堆对象分配 ----
    #[inline]
    pub fn alloc_ref(&mut self, obj: HeapObj) -> ValueHandle {
        let idx = self.ref_bucket.alloc(Arc::new(obj));
        ValueHandle::new(ValueTag::Ref, idx as usize)
    }
    #[inline]
    pub fn alloc_ref_rc(&mut self, r: Arc<HeapObj>) -> ValueHandle {
        let idx = self.ref_bucket.alloc(r);
        ValueHandle::new(ValueTag::Ref, idx as usize)
    }
    #[inline]
    pub fn get_ref(&self, h: ValueHandle) -> &Arc<HeapObj> {
        self.ref_bucket.get(h.index() as u32)
    }

    // ---- Bool 单例 ----
    #[inline]
    pub fn bool_val(v: bool) -> ValueHandle {
        if v { ValueHandle::TRUE } else { ValueHandle::FALSE }
    }
    #[inline]
    pub fn get_bool(&self, h: ValueHandle) -> bool {
        h.index() == 1
    }

    // ---- Null/Void 单例 ----
    #[inline]
    pub fn null(&self) -> ValueHandle {
        ValueHandle::NULL
    }
    #[inline]
    pub fn void(&self) -> ValueHandle {
        ValueHandle::VOID
    }

    // ---- Value ↔ ValueHandle 转换（反射 FFI 边界用）----
    // 反射原语接收 u32 (ValueHandle raw)，但 HeapObj 字段已迁移为 Value。
    // alloc_value 将 Value 字段转回 ValueHandle 供 FFI 返回；
    // get_value 将入口 ValueHandle 转为 Value 供内部递归处理。

    /// 将 Value 转换为 ValueHandle（反射 FFI 边界：Value 字段 → ValueHandle raw u32）。
    /// 标量按 tag 分桶分配，Bool/Null/Void 走单例，Ref 走 ref_bucket。
    pub fn alloc_value(&mut self, v: &Value) -> ValueHandle {
        match v {
            Value::Null => ValueHandle::NULL,
            Value::Void => ValueHandle::VOID,
            Value::Scalar(sv, tag) => unsafe {
                match tag {
                    ValueTag::Bool => if sv.bool_val { ValueHandle::TRUE } else { ValueHandle::FALSE },
                    ValueTag::Char => self.alloc_char(sv.char_val),
                    ValueTag::I8 => self.alloc_i8(sv.i8_val),
                    ValueTag::I16 => self.alloc_i16(sv.i16_val),
                    ValueTag::I32 => self.alloc_i32(sv.i32_val),
                    ValueTag::I64 => self.alloc_i64(sv.i64_val),
                    ValueTag::U8 => self.alloc_u8(sv.u8_val),
                    ValueTag::U16 => self.alloc_u16(sv.u16_val),
                    ValueTag::U32 => self.alloc_u32(sv.u32_val),
                    ValueTag::U64 => self.alloc_u64(sv.u64_val),
                    ValueTag::Isize => self.alloc_isize(sv.isize_val),
                    ValueTag::Usize => self.alloc_usize(sv.usize_val),
                    ValueTag::I128 => self.alloc_i128(i128::from_ne_bytes(std::mem::transmute(sv.i128_val))),
                    ValueTag::U128 => self.alloc_u128(u128::from_ne_bytes(std::mem::transmute(sv.u128_val))),
                    ValueTag::F16 => self.alloc_f16(sv.f16_val),
                    ValueTag::F32 => self.alloc_f32(sv.f32_val),
                    ValueTag::F64 => self.alloc_f64(sv.f64_val),
                    ValueTag::F128 => self.alloc_f128(F128(std::mem::transmute(sv.f128_val))),
                    _ => unreachable!("non-scalar tag {:?} in ScalarValue", tag),
                }
            },
            Value::Ref(r) => self.alloc_ref_rc(r.clone()),
        }
    }

    /// 将 ValueHandle 转换为 Value（反射 FFI 边界：入口 handle → Value 供递归处理）。
    pub fn get_value(&self, h: ValueHandle) -> Value {
        match h.tag() {
            ValueTag::Null => Value::Null,
            ValueTag::Void => Value::Void,
            ValueTag::Bool => Value::bool_val(self.get_bool(h)),
            ValueTag::Char => Value::char_val(unsafe { char::from_u32_unchecked(self.get_char(h)) }),
            ValueTag::I8 => Value::i8(self.get_i8(h)),
            ValueTag::I16 => Value::i16(self.get_i16(h)),
            ValueTag::I32 => Value::i32(self.get_i32(h)),
            ValueTag::I64 => Value::i64(self.get_i64(h)),
            ValueTag::U8 => Value::u8(self.get_u8(h)),
            ValueTag::U16 => Value::u16(self.get_u16(h)),
            ValueTag::U32 => Value::u32(self.get_u32(h)),
            ValueTag::U64 => Value::u64(self.get_u64(h)),
            ValueTag::Isize => Value::isize_val(self.get_isize(h)),
            ValueTag::Usize => Value::usize_val(self.get_usize(h)),
            ValueTag::I128 => Value::i128(self.get_i128(h)),
            ValueTag::U128 => Value::u128(self.get_u128(h)),
            ValueTag::F16 => Value::f16(F16(self.get_f16(h))),
            ValueTag::F32 => Value::f32(self.get_f32(h)),
            ValueTag::F64 => Value::f64(self.get_f64(h)),
            ValueTag::F128 => Value::f128(self.get_f128(h)),
            ValueTag::Ref => Value::Ref(self.get_ref(h).clone()),
        }
    }

    // ---- 堆对象快捷构造器 ----
    pub fn alloc_str(&mut self, s: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::new(s)))
    }
    pub fn alloc_str_from(&mut self, s: &str) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::from_rust_str(s)))
    }
    pub fn alloc_array(&mut self, arr: ArrayValue) -> ValueHandle {
        self.alloc_ref(HeapObj::Array(arr))
    }
    pub fn alloc_record(&mut self, r: RecordValue) -> ValueHandle {
        self.alloc_ref(HeapObj::Record(r))
    }

    /// 就地修改记录字段（通过 Arc::make_mut，refcount==1 时零拷贝）。
    /// field_name 为字段名，在 record.field_names 中查找索引。
    pub fn set_record_field_by_name(
        &mut self,
        handle: ValueHandle,
        field_name: &str,
        new_value: Value,
    ) {
        let rc = self.ref_bucket.get_mut(handle.index() as u32);
        if let HeapObj::Record(ref mut r) = Arc::make_mut(rc) {
            for (i, name) in r.field_names.iter().enumerate() {
                if name.as_deref() == Some(field_name) {
                    if i < r.fields.len() {
                        r.fields[i] = new_value;
                    }
                    return;
                }
            }
        }
    }
    pub fn alloc_adt(&mut self, a: AdtValue) -> ValueHandle {
        self.alloc_ref(HeapObj::Adt(a))
    }
    pub fn alloc_newtype(&mut self, type_name: impl Into<String>, inner: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::Newtype(NewtypeValue { type_name: type_name.into(), inner }))
    }
    pub fn alloc_cell(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::Cell(Cell::new(val)))
    }
    pub fn alloc_range(&mut self, start: i64, end: i64, inclusive: bool) -> ValueHandle {
        self.alloc_ref(HeapObj::Range(Range::new(start, end, inclusive)))
    }
    pub fn alloc_closure(&mut self, c: Closure) -> ValueHandle {
        self.alloc_ref(HeapObj::Closure(c))
    }
    pub fn alloc_partial(&mut self, p: PartialApplication) -> ValueHandle {
        self.alloc_ref(HeapObj::Partial(p))
    }
    pub fn alloc_builtin(&mut self, fn_ptr: BuiltinFn, name: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Builtin(Builtin { fn_ptr, name: name.into() }))
    }
    pub fn alloc_trait_val(&mut self, t: TraitValue) -> ValueHandle {
        self.alloc_ref(HeapObj::TraitVal(t))
    }
    pub fn alloc_lazy(&mut self, l: LazyValue) -> ValueHandle {
        self.alloc_ref(HeapObj::LazyVal(l))
    }
    pub fn alloc_error_val(&mut self, type_name: impl Into<String>, message: impl Into<String>, is_error_subtype: bool) -> ValueHandle {
        self.alloc_ref(HeapObj::ErrorVal(ErrorValue {
            type_name: type_name.into(),
            message: message.into(),
            is_error_subtype,
        }))
    }
    pub fn alloc_throw_ok(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Ok(val) }))
    }
    pub fn alloc_throw_err(&mut self, record: Arc<RecordValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    }
    pub fn alloc_atomic(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::AtomicVal(AtomicValue::new(val)))
    }
    pub fn alloc_async_handle(&mut self) -> ValueHandle {
        self.alloc_ref(HeapObj::AsyncVal(AsyncHandle::new()))
    }
    pub fn alloc_channel(&mut self, capacity: usize) -> ValueHandle {
        self.alloc_ref(HeapObj::ChannelVal(Arc::new(ChannelValue::new(capacity))))
    }
    pub fn alloc_sender(&mut self, channel: Arc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::SenderVal(SenderValue { channel }))
    }
    pub fn alloc_receiver(&mut self, channel: Arc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ReceiverVal(ReceiverValue { channel }))
    }

    /// 从 i64 按 tag 构造对应整数
    pub fn int_from_i64(&mut self, tag: ValueTag, v: i64) -> ValueHandle {
        match tag {
            ValueTag::I8 => self.alloc_i8(v as i8),
            ValueTag::I16 => self.alloc_i16(v as i16),
            ValueTag::I32 => self.alloc_i32(v as i32),
            ValueTag::I64 => self.alloc_i64(v),
            ValueTag::I128 => self.alloc_i128(v as i128),
            ValueTag::U8 => self.alloc_u8(v as u8),
            ValueTag::U16 => self.alloc_u16(v as u16),
            ValueTag::U32 => self.alloc_u32(v as u32),
            ValueTag::U64 => self.alloc_u64(v as u64),
            ValueTag::U128 => self.alloc_u128(v as u128),
            ValueTag::Isize => self.alloc_isize(v as isize),
            ValueTag::Usize => self.alloc_usize(v as usize),
            _ => self.alloc_i64(v),
        }
    }

    // ---- 引用计数 ----
    pub fn inc_ref(&mut self, h: ValueHandle) {
        match h.tag() {
            ValueTag::Null | ValueTag::Void | ValueTag::Bool => {}
            ValueTag::Char => self.char_bucket.inc_ref(h.index() as u32),
            ValueTag::I8 => self.i8_bucket.inc_ref(h.index() as u32),
            ValueTag::I16 => self.i16_bucket.inc_ref(h.index() as u32),
            ValueTag::I32 => self.i32_bucket.inc_ref(h.index() as u32),
            ValueTag::I64 => self.i64_bucket.inc_ref(h.index() as u32),
            ValueTag::I128 => self.i128_bucket.inc_ref(h.index() as u32),
            ValueTag::U8 => self.u8_bucket.inc_ref(h.index() as u32),
            ValueTag::U16 => self.u16_bucket.inc_ref(h.index() as u32),
            ValueTag::U32 => self.u32_bucket.inc_ref(h.index() as u32),
            ValueTag::U64 => self.u64_bucket.inc_ref(h.index() as u32),
            ValueTag::U128 => self.u128_bucket.inc_ref(h.index() as u32),
            ValueTag::Isize => self.isz_bucket.inc_ref(h.index() as u32),
            ValueTag::Usize => self.usz_bucket.inc_ref(h.index() as u32),
            ValueTag::F16 => self.f16_bucket.inc_ref(h.index() as u32),
            ValueTag::F32 => self.f32_bucket.inc_ref(h.index() as u32),
            ValueTag::F64 => self.f64_bucket.inc_ref(h.index() as u32),
            ValueTag::F128 => self.f128_bucket.inc_ref(h.index() as u32),
            ValueTag::Ref => self.ref_bucket.inc_ref(h.index() as u32),
        }
    }
    pub fn dec_ref(&mut self, h: ValueHandle) {
        match h.tag() {
            ValueTag::Null | ValueTag::Void | ValueTag::Bool => {}
            ValueTag::Char => { self.char_bucket.dec_ref(h.index() as u32); }
            ValueTag::I8 => { self.i8_bucket.dec_ref(h.index() as u32); }
            ValueTag::I16 => { self.i16_bucket.dec_ref(h.index() as u32); }
            ValueTag::I32 => { self.i32_bucket.dec_ref(h.index() as u32); }
            ValueTag::I64 => { self.i64_bucket.dec_ref(h.index() as u32); }
            ValueTag::I128 => { self.i128_bucket.dec_ref(h.index() as u32); }
            ValueTag::U8 => { self.u8_bucket.dec_ref(h.index() as u32); }
            ValueTag::U16 => { self.u16_bucket.dec_ref(h.index() as u32); }
            ValueTag::U32 => { self.u32_bucket.dec_ref(h.index() as u32); }
            ValueTag::U64 => { self.u64_bucket.dec_ref(h.index() as u32); }
            ValueTag::U128 => { self.u128_bucket.dec_ref(h.index() as u32); }
            ValueTag::Isize => { self.isz_bucket.dec_ref(h.index() as u32); }
            ValueTag::Usize => { self.usz_bucket.dec_ref(h.index() as u32); }
            ValueTag::F16 => { self.f16_bucket.dec_ref(h.index() as u32); }
            ValueTag::F32 => { self.f32_bucket.dec_ref(h.index() as u32); }
            ValueTag::F64 => { self.f64_bucket.dec_ref(h.index() as u32); }
            ValueTag::F128 => { self.f128_bucket.dec_ref(h.index() as u32); }
            ValueTag::Ref => { self.ref_bucket.dec_ref(h.index() as u32); }
        }
    }

    /// 为数组填充 SoA 快路径（当元素同类型标量时）。
    /// 元素已迁移为 Value，直接用 Value 自带的标量访问器读取，无需经过 arena bucket。
    pub fn optimize_array_soa(&mut self, arr: &mut ArrayValue) {
        if arr.elements.is_empty() { return; }
        // 取首元素标量 tag，全部元素必须同 tag 才能启用 SoA
        let tag = match arr.elements[0].scalar_tag() {
            Some(t) => t,
            None => return,
        };
        if !arr.elements.iter().all(|h| h.scalar_tag() == Some(tag)) {
            return;
        }
        arr.scalar_soa = Some(match tag {
            ValueTag::I8 => ScalarSoA::I8(arr.elements.iter().map(|h| h.as_i8()).collect()),
            ValueTag::I16 => ScalarSoA::I16(arr.elements.iter().map(|h| h.as_i16()).collect()),
            ValueTag::I32 => ScalarSoA::I32(arr.elements.iter().map(|h| h.as_i32()).collect()),
            ValueTag::I64 => ScalarSoA::I64(arr.elements.iter().map(|h| h.as_i64()).collect()),
            ValueTag::U8 => ScalarSoA::U8(arr.elements.iter().map(|h| h.as_u8()).collect()),
            ValueTag::U16 => ScalarSoA::U16(arr.elements.iter().map(|h| h.as_u16()).collect()),
            ValueTag::U32 => ScalarSoA::U32(arr.elements.iter().map(|h| h.as_u32()).collect()),
            ValueTag::U64 => ScalarSoA::U64(arr.elements.iter().map(|h| h.as_u64()).collect()),
            ValueTag::Bool => ScalarSoA::Bool(arr.elements.iter().map(|h| h.as_bool()).collect()),
            ValueTag::Char => ScalarSoA::Char(arr.elements.iter().map(|h| h.as_char() as u32).collect()),
            ValueTag::F32 => ScalarSoA::F32(arr.elements.iter().map(|h| h.as_f32()).collect()),
            ValueTag::F64 => ScalarSoA::F64(arr.elements.iter().map(|h| h.as_f64()).collect()),
            _ => return,
        });
    }

    /// 格式化值为字符串（Display 语义）
    pub fn format_value(&self, h: ValueHandle) -> String {
        self.display_value(h).to_string()
    }

    /// 返回一个实现 Display 的包装器
    pub fn display_value<'a>(&'a self, h: ValueHandle) -> ValueDisplay<'a> {
        ValueDisplay { arena: self, handle: h }
    }

    /// 返回一个实现 Debug 的包装器
    pub fn debug_value<'a>(&'a self, h: ValueHandle) -> ValueDebug<'a> {
        ValueDebug { arena: self, handle: h }
    }
}

impl Default for ValueArena {
    fn default() -> Self {
        Self::new()
    }
}

/// Display 包装器：通过 arena 格式化值
pub struct ValueDisplay<'a> {
    arena: &'a ValueArena,
    handle: ValueHandle,
}

impl<'a> fmt::Display for ValueDisplay<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        arena_display(self.arena, self.handle, f)
    }
}

/// Debug 包装器：通过 arena 格式化值
pub struct ValueDebug<'a> {
    arena: &'a ValueArena,
    handle: ValueHandle,
}

impl<'a> fmt::Debug for ValueDebug<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        arena_debug(self.arena, self.handle, f)
    }
}

fn arena_display(arena: &ValueArena, h: ValueHandle, f: &mut fmt::Formatter) -> fmt::Result {
    match h.tag() {
        ValueTag::Null => write!(f, "null"),
        ValueTag::Void => write!(f, "()"),
        ValueTag::Bool => write!(f, "{}", arena.get_bool(h)),
        ValueTag::Char => write!(f, "{}", Char::from_codepoint_unchecked(arena.get_char(h))),
        ValueTag::I8 => write!(f, "{}", arena.get_i8(h)),
        ValueTag::I16 => write!(f, "{}", arena.get_i16(h)),
        ValueTag::I32 => write!(f, "{}", arena.get_i32(h)),
        ValueTag::I64 => write!(f, "{}", arena.get_i64(h)),
        ValueTag::I128 => write!(f, "{}", arena.get_i128(h)),
        ValueTag::U8 => write!(f, "{}", arena.get_u8(h)),
        ValueTag::U16 => write!(f, "{}", arena.get_u16(h)),
        ValueTag::U32 => write!(f, "{}", arena.get_u32(h)),
        ValueTag::U64 => write!(f, "{}", arena.get_u64(h)),
        ValueTag::U128 => write!(f, "{}", arena.get_u128(h)),
        ValueTag::Isize => write!(f, "{}", arena.get_isize(h)),
        ValueTag::Usize => write!(f, "{}", arena.get_usize(h)),
        ValueTag::F16 => write!(f, "{}", F16(arena.get_f16(h)).to_f32()),
        ValueTag::F32 => write!(f, "{}", arena.get_f32(h)),
        ValueTag::F64 => write!(f, "{}", arena.get_f64(h)),
        ValueTag::F128 => write!(f, "{}", arena.get_f128(h).to_f64()),
        ValueTag::Ref => match arena.get_ref(h).as_ref() {
            HeapObj::Str(s) => write!(f, "{}", s),
            other => write!(f, "{:?}", other),
        },
    }
}

fn arena_debug(arena: &ValueArena, h: ValueHandle, f: &mut fmt::Formatter) -> fmt::Result {
    match h.tag() {
        ValueTag::Null => write!(f, "null"),
        ValueTag::Void => write!(f, "()"),
        ValueTag::Bool => write!(f, "{}", arena.get_bool(h)),
        ValueTag::Char => write!(f, "'{}'", Char::from_codepoint_unchecked(arena.get_char(h))),
        ValueTag::I8 => write!(f, "{}i8", arena.get_i8(h)),
        ValueTag::I16 => write!(f, "{}i16", arena.get_i16(h)),
        ValueTag::I32 => write!(f, "{}", arena.get_i32(h)),
        ValueTag::I64 => write!(f, "{}i64", arena.get_i64(h)),
        ValueTag::I128 => write!(f, "{}i128", arena.get_i128(h)),
        ValueTag::U8 => write!(f, "{}u8", arena.get_u8(h)),
        ValueTag::U16 => write!(f, "{}u16", arena.get_u16(h)),
        ValueTag::U32 => write!(f, "{}u32", arena.get_u32(h)),
        ValueTag::U64 => write!(f, "{}u64", arena.get_u64(h)),
        ValueTag::U128 => write!(f, "{}u128", arena.get_u128(h)),
        ValueTag::Isize => write!(f, "{}isize", arena.get_isize(h)),
        ValueTag::Usize => write!(f, "{}usize", arena.get_usize(h)),
        ValueTag::F16 => write!(f, "{:?}", F16(arena.get_f16(h))),
        ValueTag::F32 => write!(f, "{}f32", arena.get_f32(h)),
        ValueTag::F64 => write!(f, "{}", arena.get_f64(h)),
        ValueTag::F128 => write!(f, "{:?}", arena.get_f128(h)),
        ValueTag::Ref => write!(f, "{:?}", arena.get_ref(h).as_ref()),
    }
}

// =========================================================================
// ValueTrait —— 对外统一接口（方法携带 &ValueArena）
// =========================================================================

/// Glue 统一值 trait：所有值类型的对外接口。
pub trait ValueTrait: Sized + Clone + Copy + PartialEq + Eq + Hash {
    // ---- 谓词（仅看 tag，不需要 arena）----
    fn is_null(&self) -> bool;
    fn is_void(&self) -> bool;
    fn is_bool(&self) -> bool;
    fn is_char(&self) -> bool;
    fn is_int(&self) -> bool;
    fn is_float(&self) -> bool;
    fn is_numeric(&self) -> bool;
    fn is_scalar(&self) -> bool;
    fn is_ref(&self) -> bool;
    fn requires_release(&self) -> bool;

    // ---- 堆谓词（需要 arena 解引用 HeapObj）----
    fn is_string(&self, arena: &ValueArena) -> bool;
    fn is_array(&self, arena: &ValueArena) -> bool;
    fn is_record(&self, arena: &ValueArena) -> bool;
    fn is_adt(&self, arena: &ValueArena) -> bool;
    fn is_closure(&self, arena: &ValueArena) -> bool;
    fn is_callable(&self, arena: &ValueArena) -> bool;

    // ---- 类型信息 ----
    fn type_name(&self, arena: &ValueArena) -> &'static str;
    fn scalar_tag(&self) -> Option<ValueTag>;

    // ---- 标量访问器（需要 arena 取值）----
    fn as_bool(&self, arena: &ValueArena) -> Option<bool>;
    fn as_i8(&self, arena: &ValueArena) -> Option<i8>;
    fn as_i16(&self, arena: &ValueArena) -> Option<i16>;
    fn as_i32(&self, arena: &ValueArena) -> Option<i32>;
    fn as_i64(&self, arena: &ValueArena) -> Option<i64>;
    fn as_i128(&self, arena: &ValueArena) -> Option<i128>;
    fn as_u8(&self, arena: &ValueArena) -> Option<u8>;
    fn as_u16(&self, arena: &ValueArena) -> Option<u16>;
    fn as_u32(&self, arena: &ValueArena) -> Option<u32>;
    fn as_u64(&self, arena: &ValueArena) -> Option<u64>;
    fn as_u128(&self, arena: &ValueArena) -> Option<u128>;
    fn as_isize(&self, arena: &ValueArena) -> Option<isize>;
    fn as_usize(&self, arena: &ValueArena) -> Option<usize>;
    fn as_f32(&self, arena: &ValueArena) -> Option<f32>;
    fn as_f64(&self, arena: &ValueArena) -> Option<f64>;
    fn as_char(&self, arena: &ValueArena) -> Option<Char>;
    fn as_f16(&self, arena: &ValueArena) -> Option<F16>;
    fn as_f128(&self, arena: &ValueArena) -> Option<F128>;

    // ---- 堆访问器 ----
    fn as_str<'a>(&self, arena: &'a ValueArena) -> Option<&'a GlueStr>;
    fn as_array<'a>(&self, arena: &'a ValueArena) -> Option<&'a ArrayValue>;
    fn as_record<'a>(&self, arena: &'a ValueArena) -> Option<&'a RecordValue>;
    fn as_adt<'a>(&self, arena: &'a ValueArena) -> Option<&'a AdtValue>;
    fn as_newtype<'a>(&self, arena: &'a ValueArena) -> Option<&'a NewtypeValue>;
    fn as_cell<'a>(&self, arena: &'a ValueArena) -> Option<&'a Cell>;
    fn as_range<'a>(&self, arena: &'a ValueArena) -> Option<&'a Range>;
    fn as_closure<'a>(&self, arena: &'a ValueArena) -> Option<&'a Closure>;
    fn as_partial<'a>(&self, arena: &'a ValueArena) -> Option<&'a PartialApplication>;
    fn as_builtin<'a>(&self, arena: &'a ValueArena) -> Option<&'a Builtin>;
    fn as_trait_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a TraitValue>;
    fn as_lazy<'a>(&self, arena: &'a ValueArena) -> Option<&'a LazyValue>;
    fn as_error_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ErrorValue>;
    fn as_throw_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ThrowValue>;
    fn as_atomic<'a>(&self, arena: &'a ValueArena) -> Option<&'a AtomicValue>;
    fn as_async_handle<'a>(&self, arena: &'a ValueArena) -> Option<&'a AsyncHandle>;
    fn as_channel<'a>(&self, arena: &'a ValueArena) -> Option<&'a ChannelValue>;
    fn as_sender<'a>(&self, arena: &'a ValueArena) -> Option<&'a SenderValue>;
    fn as_receiver<'a>(&self, arena: &'a ValueArena) -> Option<&'a ReceiverValue>;
    fn as_ref<'a>(&self, arena: &'a ValueArena) -> Option<&'a HeapRef>;
    fn ref_kind(&self, arena: &ValueArena) -> Option<RefKind>;

    // ---- 数值提升 ----
    fn as_int_i64(&self, arena: &ValueArena) -> Option<i64>;
    fn as_int_i128(&self, arena: &ValueArena) -> Option<i128>;
    fn as_float_f64(&self, arena: &ValueArena) -> Option<f64>;

    // ---- 相等与深克隆 ----
    fn equals(&self, other: &Self, arena: &ValueArena) -> bool;
    fn deep_clone(&self, arena: &mut ValueArena) -> Self;
}

// =========================================================================
// =========================================================================
// ValueHandle —— ValueTrait 实现（通过 ValueArena 访问桶内数据）
// =========================================================================

impl ValueTrait for ValueHandle {
    // ---- 谓词（仅看 tag，不需要 arena）----
    #[inline]
    fn is_null(&self) -> bool {
        self.tag() == ValueTag::Null
    }
    #[inline]
    fn is_void(&self) -> bool {
        self.tag() == ValueTag::Void
    }
    #[inline]
    fn is_bool(&self) -> bool {
        self.tag() == ValueTag::Bool
    }
    #[inline]
    fn is_char(&self) -> bool {
        self.tag() == ValueTag::Char
    }
    #[inline]
    fn is_int(&self) -> bool {
        self.tag().is_int()
    }
    #[inline]
    fn is_float(&self) -> bool {
        self.tag().is_float()
    }
    #[inline]
    fn is_numeric(&self) -> bool {
        self.tag().is_numeric()
    }
    #[inline]
    fn is_scalar(&self) -> bool {
        self.tag().is_scalar()
    }
    #[inline]
    fn is_ref(&self) -> bool {
        self.tag() == ValueTag::Ref
    }
    #[inline]
    fn requires_release(&self) -> bool {
        !matches!(self.tag(), ValueTag::Null | ValueTag::Void | ValueTag::Bool)
    }

    // ---- 堆谓词（需要 arena 解引用 HeapObj）----
    #[inline]
    fn is_string(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Str(_)))
    }
    #[inline]
    fn is_array(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Array(_)))
    }
    #[inline]
    fn is_record(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Record(_)))
    }
    #[inline]
    fn is_adt(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Adt(_)))
    }
    #[inline]
    fn is_closure(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Closure(_)))
    }
    #[inline]
    fn is_callable(&self, arena: &ValueArena) -> bool {
        matches!(
            arena.heap_obj_opt(*self),
            Some(HeapObj::Closure(_) | HeapObj::Builtin(_) | HeapObj::Partial(_))
        )
    }

    // ---- 类型信息 ----
    fn type_name(&self, arena: &ValueArena) -> &'static str {
        match self.tag() {
            ValueTag::Null => "null",
            ValueTag::Void => "void",
            ValueTag::Ref => arena.get_ref(*self).type_name(),
            t => t.name(),
        }
    }
    #[inline]
    fn scalar_tag(&self) -> Option<ValueTag> {
        let t = self.tag();
        if t.is_scalar() {
            Some(t)
        } else {
            None
        }
    }

    // ---- 标量访问器（需要 arena 取值）----
    #[inline]
    fn as_bool(&self, arena: &ValueArena) -> Option<bool> {
        if self.tag() == ValueTag::Bool {
            Some(arena.get_bool(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i8(&self, arena: &ValueArena) -> Option<i8> {
        if self.tag() == ValueTag::I8 {
            Some(arena.get_i8(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i16(&self, arena: &ValueArena) -> Option<i16> {
        if self.tag() == ValueTag::I16 {
            Some(arena.get_i16(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i32(&self, arena: &ValueArena) -> Option<i32> {
        if self.tag() == ValueTag::I32 {
            Some(arena.get_i32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i64(&self, arena: &ValueArena) -> Option<i64> {
        if self.tag() == ValueTag::I64 {
            Some(arena.get_i64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i128(&self, arena: &ValueArena) -> Option<i128> {
        if self.tag() == ValueTag::I128 {
            Some(arena.get_i128(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u8(&self, arena: &ValueArena) -> Option<u8> {
        if self.tag() == ValueTag::U8 {
            Some(arena.get_u8(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u16(&self, arena: &ValueArena) -> Option<u16> {
        if self.tag() == ValueTag::U16 {
            Some(arena.get_u16(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u32(&self, arena: &ValueArena) -> Option<u32> {
        if self.tag() == ValueTag::U32 {
            Some(arena.get_u32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u64(&self, arena: &ValueArena) -> Option<u64> {
        if self.tag() == ValueTag::U64 {
            Some(arena.get_u64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u128(&self, arena: &ValueArena) -> Option<u128> {
        if self.tag() == ValueTag::U128 {
            Some(arena.get_u128(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_isize(&self, arena: &ValueArena) -> Option<isize> {
        if self.tag() == ValueTag::Isize {
            Some(arena.get_isize(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_usize(&self, arena: &ValueArena) -> Option<usize> {
        if self.tag() == ValueTag::Usize {
            Some(arena.get_usize(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_f32(&self, arena: &ValueArena) -> Option<f32> {
        if self.tag() == ValueTag::F32 {
            Some(arena.get_f32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_f64(&self, arena: &ValueArena) -> Option<f64> {
        if self.tag() == ValueTag::F64 {
            Some(arena.get_f64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_char(&self, arena: &ValueArena) -> Option<Char> {
        if self.tag() == ValueTag::Char {
            Some(Char::from_codepoint_unchecked(arena.get_char(*self)))
        } else {
            None
        }
    }
    #[inline]
    fn as_f16(&self, arena: &ValueArena) -> Option<F16> {
        if self.tag() == ValueTag::F16 {
            Some(F16(arena.get_f16(*self)))
        } else {
            None
        }
    }
    #[inline]
    fn as_f128(&self, arena: &ValueArena) -> Option<F128> {
        if self.tag() == ValueTag::F128 {
            Some(arena.get_f128(*self))
        } else {
            None
        }
    }

    // ---- 堆访问器 ----
    #[inline]
    fn as_str<'a>(&self, arena: &'a ValueArena) -> Option<&'a GlueStr> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Str(s) => Some(s),
            _ => None,
        }
    }
    #[inline]
    fn as_array<'a>(&self, arena: &'a ValueArena) -> Option<&'a ArrayValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Array(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_record<'a>(&self, arena: &'a ValueArena) -> Option<&'a RecordValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Record(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_adt<'a>(&self, arena: &'a ValueArena) -> Option<&'a AdtValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Adt(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_newtype<'a>(&self, arena: &'a ValueArena) -> Option<&'a NewtypeValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Newtype(n) => Some(n),
            _ => None,
        }
    }
    #[inline]
    fn as_cell<'a>(&self, arena: &'a ValueArena) -> Option<&'a Cell> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Cell(c) => Some(c),
            _ => None,
        }
    }
    #[inline]
    fn as_range<'a>(&self, arena: &'a ValueArena) -> Option<&'a Range> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Range(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_closure<'a>(&self, arena: &'a ValueArena) -> Option<&'a Closure> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Closure(c) => Some(c),
            _ => None,
        }
    }
    #[inline]
    fn as_partial<'a>(&self, arena: &'a ValueArena) -> Option<&'a PartialApplication> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Partial(p) => Some(p),
            _ => None,
        }
    }
    #[inline]
    fn as_builtin<'a>(&self, arena: &'a ValueArena) -> Option<&'a Builtin> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Builtin(b) => Some(b),
            _ => None,
        }
    }
    #[inline]
    fn as_trait_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a TraitValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::TraitVal(t) => Some(t),
            _ => None,
        }
    }
    #[inline]
    fn as_lazy<'a>(&self, arena: &'a ValueArena) -> Option<&'a LazyValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::LazyVal(l) => Some(l),
            _ => None,
        }
    }
    #[inline]
    fn as_error_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ErrorValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ErrorVal(e) => Some(e),
            _ => None,
        }
    }
    #[inline]
    fn as_throw_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ThrowValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ThrowVal(t) => Some(t),
            _ => None,
        }
    }
    #[inline]
    fn as_atomic<'a>(&self, arena: &'a ValueArena) -> Option<&'a AtomicValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::AtomicVal(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_async_handle<'a>(&self, arena: &'a ValueArena) -> Option<&'a AsyncHandle> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::AsyncVal(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_channel<'a>(&self, arena: &'a ValueArena) -> Option<&'a ChannelValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ChannelVal(c) => Some(c.as_ref()),
            _ => None,
        }
    }
    #[inline]
    fn as_sender<'a>(&self, arena: &'a ValueArena) -> Option<&'a SenderValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::SenderVal(s) => Some(s),
            _ => None,
        }
    }
    #[inline]
    fn as_receiver<'a>(&self, arena: &'a ValueArena) -> Option<&'a ReceiverValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ReceiverVal(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_ref<'a>(&self, arena: &'a ValueArena) -> Option<&'a HeapRef> {
        if self.tag() == ValueTag::Ref {
            Some(arena.get_ref(*self))
        } else {
            None
        }
    }
    #[inline]
    fn ref_kind(&self, arena: &ValueArena) -> Option<RefKind> {
        arena.heap_obj_opt(*self).map(|o| o.ref_kind())
    }

    // ---- 数值提升 ----
    fn as_int_i64(&self, arena: &ValueArena) -> Option<i64> {
        match self.tag() {
            ValueTag::I8 => Some(arena.get_i8(*self) as i64),
            ValueTag::I16 => Some(arena.get_i16(*self) as i64),
            ValueTag::I32 => Some(arena.get_i32(*self) as i64),
            ValueTag::I64 => Some(arena.get_i64(*self)),
            ValueTag::I128 => Some(arena.get_i128(*self) as i64),
            ValueTag::U8 => Some(arena.get_u8(*self) as i64),
            ValueTag::U16 => Some(arena.get_u16(*self) as i64),
            ValueTag::U32 => Some(arena.get_u32(*self) as i64),
            ValueTag::U64 => Some(arena.get_u64(*self) as i64),
            ValueTag::U128 => Some(arena.get_u128(*self) as i64),
            ValueTag::Isize => Some(arena.get_isize(*self) as i64),
            ValueTag::Usize => Some(arena.get_usize(*self) as i64),
            _ => None,
        }
    }
    fn as_int_i128(&self, arena: &ValueArena) -> Option<i128> {
        match self.tag() {
            ValueTag::I8 => Some(arena.get_i8(*self) as i128),
            ValueTag::I16 => Some(arena.get_i16(*self) as i128),
            ValueTag::I32 => Some(arena.get_i32(*self) as i128),
            ValueTag::I64 => Some(arena.get_i64(*self) as i128),
            ValueTag::I128 => Some(arena.get_i128(*self)),
            ValueTag::U8 => Some(arena.get_u8(*self) as i128),
            ValueTag::U16 => Some(arena.get_u16(*self) as i128),
            ValueTag::U32 => Some(arena.get_u32(*self) as i128),
            ValueTag::U64 => Some(arena.get_u64(*self) as i128),
            ValueTag::U128 => Some(arena.get_u128(*self) as i128),
            ValueTag::Isize => Some(arena.get_isize(*self) as i128),
            ValueTag::Usize => Some(arena.get_usize(*self) as i128),
            _ => None,
        }
    }
    fn as_float_f64(&self, arena: &ValueArena) -> Option<f64> {
        match self.tag() {
            ValueTag::F16 => Some(F16(arena.get_f16(*self)).to_f64()),
            ValueTag::F32 => Some(arena.get_f32(*self) as f64),
            ValueTag::F64 => Some(arena.get_f64(*self)),
            ValueTag::F128 => Some(arena.get_f128(*self).to_f64()),
            _ => None,
        }
    }

    // ---- 相等与深克隆 ----
    fn equals(&self, other: &Self, arena: &ValueArena) -> bool {
        if self.tag() != other.tag() {
            return false;
        }
        match self.tag() {
            ValueTag::Null | ValueTag::Void => true,
            ValueTag::Bool => arena.get_bool(*self) == arena.get_bool(*other),
            ValueTag::Char => arena.get_char(*self) == arena.get_char(*other),
            ValueTag::I8 => arena.get_i8(*self) == arena.get_i8(*other),
            ValueTag::I16 => arena.get_i16(*self) == arena.get_i16(*other),
            ValueTag::I32 => arena.get_i32(*self) == arena.get_i32(*other),
            ValueTag::I64 => arena.get_i64(*self) == arena.get_i64(*other),
            ValueTag::I128 => arena.get_i128(*self) == arena.get_i128(*other),
            ValueTag::U8 => arena.get_u8(*self) == arena.get_u8(*other),
            ValueTag::U16 => arena.get_u16(*self) == arena.get_u16(*other),
            ValueTag::U32 => arena.get_u32(*self) == arena.get_u32(*other),
            ValueTag::U64 => arena.get_u64(*self) == arena.get_u64(*other),
            ValueTag::U128 => arena.get_u128(*self) == arena.get_u128(*other),
            ValueTag::Isize => arena.get_isize(*self) == arena.get_isize(*other),
            ValueTag::Usize => arena.get_usize(*self) == arena.get_usize(*other),
            ValueTag::F16 => arena.get_f16(*self) == arena.get_f16(*other),
            ValueTag::F32 => {
                arena.get_f32(*self).to_bits() == arena.get_f32(*other).to_bits()
            }
            ValueTag::F64 => {
                arena.get_f64(*self).to_bits() == arena.get_f64(*other).to_bits()
            }
            ValueTag::F128 => arena.get_f128(*self) == arena.get_f128(*other),
            ValueTag::Ref => {
                let a = arena.get_ref(*self);
                let b = arena.get_ref(*other);
                Arc::ptr_eq(a, b) || heap_equals(a, b, arena)
            }
        }
    }

    fn deep_clone(&self, arena: &mut ValueArena) -> Self {
        let mut cache = DeepCloneCache { handle: FxHashMap::default(), value: FxHashMap::default() };
        deep_clone_handle(*self, arena, &mut cache)
    }
}

// =========================================================================
// 堆对象深比较与深克隆（带 ptr_eq 缓存以共享子图）
// =========================================================================

// -------------------- SoA SIMD 快路径 --------------------

/// 尝试用 SIMD 批量比较两个 SoA 数组。
/// 仅当双方 SoA 类型相同时生效，返回 `Some(bool)`。
/// 类型不匹配时返回 `None`，由调用方回退到逐元素路径。
fn try_simd_soa_equals(a: &ScalarSoA, b: &ScalarSoA) -> Option<bool> {
    match (a, b) {
        (ScalarSoA::I32(va), ScalarSoA::I32(vb)) => Some(simd_eq_i32(va, vb)),
        (ScalarSoA::I64(va), ScalarSoA::I64(vb)) => Some(simd_eq_i64(va, vb)),
        (ScalarSoA::F32(va), ScalarSoA::F32(vb)) => Some(simd_eq_f32_bits(va, vb)),
        (ScalarSoA::F64(va), ScalarSoA::F64(vb)) => Some(simd_eq_f64_bits(va, vb)),
        // 其余类型用普通 slice 比较（Rust slice PartialEq 已优化）
        (ScalarSoA::I8(va), ScalarSoA::I8(vb)) => Some(va == vb),
        (ScalarSoA::I16(va), ScalarSoA::I16(vb)) => Some(va == vb),
        (ScalarSoA::U8(va), ScalarSoA::U8(vb)) => Some(va == vb),
        (ScalarSoA::U16(va), ScalarSoA::U16(vb)) => Some(va == vb),
        (ScalarSoA::U32(va), ScalarSoA::U32(vb)) => Some(va == vb),
        (ScalarSoA::U64(va), ScalarSoA::U64(vb)) => Some(va == vb),
        (ScalarSoA::Bool(va), ScalarSoA::Bool(vb)) => Some(va == vb),
        (ScalarSoA::Char(va), ScalarSoA::Char(vb)) => Some(va == vb),
        _ => None, // 类型不匹配，回退
    }
}

#[inline]
fn simd_eq_i32(a: &[i32], b: &[i32]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let n = a.len();
    if n == 0 {
        return true;
    }
    if n >= PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        return a.par_chunks(chunk)
            .zip(b.par_chunks(chunk))
            .all(|(ca, cb)| simd_eq_i32_chunk(ca, cb));
    }
    simd_eq_i32_chunk(a, b)
}

#[inline]
fn simd_eq_i32_chunk(a: &[i32], b: &[i32]) -> bool {
    let n = a.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    for (ca, cb) in a[..simd_len]
        .chunks_exact(SIMD_LANES)
        .zip(b[..simd_len].chunks_exact(SIMD_LANES))
    {
        let va = i32x4::new(ca.try_into().unwrap());
        let vb = i32x4::new(cb.try_into().unwrap());
        let mask = va.cmp_eq(vb);
        let arr = mask.to_array();
        if arr.contains(&0) {
            return false;
        }
    }
    a[simd_len..]
        .iter()
        .zip(&b[simd_len..])
        .all(|(&x, &y)| x == y)
}

#[inline]
fn simd_eq_i64(a: &[i64], b: &[i64]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let n = a.len();
    if n == 0 {
        return true;
    }
    if n >= PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        return a.par_chunks(chunk)
            .zip(b.par_chunks(chunk))
            .all(|(ca, cb)| simd_eq_i64_chunk(ca, cb));
    }
    simd_eq_i64_chunk(a, b)
}

#[inline]
fn simd_eq_i64_chunk(a: &[i64], b: &[i64]) -> bool {
    let n = a.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    for (ca, cb) in a[..simd_len]
        .chunks_exact(SIMD_LANES)
        .zip(b[..simd_len].chunks_exact(SIMD_LANES))
    {
        let va = i64x4::new(ca.try_into().unwrap());
        let vb = i64x4::new(cb.try_into().unwrap());
        let mask = va.cmp_eq(vb);
        let arr = mask.to_array();
        if arr.contains(&0) {
            return false;
        }
    }
    a[simd_len..]
        .iter()
        .zip(&b[simd_len..])
        .all(|(&x, &y)| x == y)
}

/// f32 按位比较（避免 NaN 不等问题）。
#[inline]
fn simd_eq_f32_bits(a: &[f32], b: &[f32]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let n = a.len();
    if n == 0 {
        return true;
    }
    if n >= PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        return a.par_chunks(chunk)
            .zip(b.par_chunks(chunk))
            .all(|(ca, cb)| simd_eq_f32_bits_chunk(ca, cb));
    }
    simd_eq_f32_bits_chunk(a, b)
}

#[inline]
fn simd_eq_f32_bits_chunk(a: &[f32], b: &[f32]) -> bool {
    let n = a.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    for (ca, cb) in a[..simd_len]
        .chunks_exact(SIMD_LANES)
        .zip(b[..simd_len].chunks_exact(SIMD_LANES))
    {
        let va = i32x4::new([
            ca[0].to_bits() as i32,
            ca[1].to_bits() as i32,
            ca[2].to_bits() as i32,
            ca[3].to_bits() as i32,
        ]);
        let vb = i32x4::new([
            cb[0].to_bits() as i32,
            cb[1].to_bits() as i32,
            cb[2].to_bits() as i32,
            cb[3].to_bits() as i32,
        ]);
        let mask = va.cmp_eq(vb);
        let arr = mask.to_array();
        if arr.contains(&0) {
            return false;
        }
    }
    a[simd_len..]
        .iter()
        .zip(&b[simd_len..])
        .all(|(&x, &y)| x.to_bits() == y.to_bits())
}

/// f64 按位比较（避免 NaN 不等问题）。
#[inline]
fn simd_eq_f64_bits(a: &[f64], b: &[f64]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let n = a.len();
    if n == 0 {
        return true;
    }
    if n >= PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        return a.par_chunks(chunk)
            .zip(b.par_chunks(chunk))
            .all(|(ca, cb)| simd_eq_f64_bits_chunk(ca, cb));
    }
    simd_eq_f64_bits_chunk(a, b)
}

#[inline]
fn simd_eq_f64_bits_chunk(a: &[f64], b: &[f64]) -> bool {
    let n = a.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    for (ca, cb) in a[..simd_len]
        .chunks_exact(SIMD_LANES)
        .zip(b[..simd_len].chunks_exact(SIMD_LANES))
    {
        let va = i64x4::new([
            ca[0].to_bits() as i64,
            ca[1].to_bits() as i64,
            ca[2].to_bits() as i64,
            ca[3].to_bits() as i64,
        ]);
        let vb = i64x4::new([
            cb[0].to_bits() as i64,
            cb[1].to_bits() as i64,
            cb[2].to_bits() as i64,
            cb[3].to_bits() as i64,
        ]);
        let mask = va.cmp_eq(vb);
        let arr = mask.to_array();
        if arr.contains(&0) {
            return false;
        }
    }
    a[simd_len..]
        .iter()
        .zip(&b[simd_len..])
        .all(|(&x, &y)| x.to_bits() == y.to_bits())
}

// -------------------- SoA SIMD 批量哈希 --------------------

/// 用 SIMD 批量哈希 SoA 数据。
/// 对 I32/I64/F32/F64 走 SIMD 累积，其余类型回退到逐元素哈希。
fn simd_hash_soa<H: Hasher>(soa: &ScalarSoA, state: &mut H) {
    match soa {
        ScalarSoA::I32(v) => simd_hash_i32(v, state),
        ScalarSoA::I64(v) => simd_hash_i64(v, state),
        ScalarSoA::F32(v) => simd_hash_f32(v, state),
        ScalarSoA::F64(v) => simd_hash_f64(v, state),
        ScalarSoA::I8(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::I16(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::U8(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::U16(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::U32(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::U64(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::Bool(v) => v.iter().for_each(|x| x.hash(state)),
        ScalarSoA::Char(v) => v.iter().for_each(|x| x.hash(state)),
    }
}

fn simd_hash_i32<H: Hasher>(v: &[i32], state: &mut H) {
    let n = v.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    let mut acc = i32x4::splat(0);
    for chunk in v[..simd_len].chunks_exact(SIMD_LANES) {
        let c = i32x4::new(chunk.try_into().unwrap());
        acc = (acc << 1) ^ c;
    }
    for x in acc.to_array() {
        x.hash(state);
    }
    for &x in &v[simd_len..] {
        x.hash(state);
    }
}

fn simd_hash_i64<H: Hasher>(v: &[i64], state: &mut H) {
    let n = v.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    let mut acc = i64x4::splat(0);
    for chunk in v[..simd_len].chunks_exact(SIMD_LANES) {
        let c = i64x4::new(chunk.try_into().unwrap());
        acc = (acc << 1) ^ c;
    }
    for x in acc.to_array() {
        x.hash(state);
    }
    for &x in &v[simd_len..] {
        x.hash(state);
    }
}

fn simd_hash_f32<H: Hasher>(v: &[f32], state: &mut H) {
    let n = v.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    let mut acc = i32x4::splat(0);
    for chunk in v[..simd_len].chunks_exact(SIMD_LANES) {
        let c = i32x4::new([
            chunk[0].to_bits() as i32,
            chunk[1].to_bits() as i32,
            chunk[2].to_bits() as i32,
            chunk[3].to_bits() as i32,
        ]);
        acc = (acc << 1) ^ c;
    }
    for x in acc.to_array() {
        x.hash(state);
    }
    for &x in &v[simd_len..] {
        x.to_bits().hash(state);
    }
}

fn simd_hash_f64<H: Hasher>(v: &[f64], state: &mut H) {
    let n = v.len();
    let simd_len = (n / SIMD_LANES) * SIMD_LANES;
    let mut acc = i64x4::splat(0);
    for chunk in v[..simd_len].chunks_exact(SIMD_LANES) {
        let c = i64x4::new([
            chunk[0].to_bits() as i64,
            chunk[1].to_bits() as i64,
            chunk[2].to_bits() as i64,
            chunk[3].to_bits() as i64,
        ]);
        acc = (acc << 1) ^ c;
    }
    for x in acc.to_array() {
        x.hash(state);
    }
    for &x in &v[simd_len..] {
        x.to_bits().hash(state);
    }
}

// -------------------- SoA deep_clone 快路径 --------------------

/// SoA 快路径深克隆：标量为 Copy，直接用 Value 构造器内联重建，无需经过 arena bucket。
fn simd_soa_deep_clone(soa: &ScalarSoA) -> Vec<Value> {
    match soa {
        ScalarSoA::I32(v) => v.iter().map(|&x| Value::i32(x)).collect(),
        ScalarSoA::I64(v) => v.iter().map(|&x| Value::i64(x)).collect(),
        ScalarSoA::F32(v) => v.iter().map(|&x| Value::f32(x)).collect(),
        ScalarSoA::F64(v) => v.iter().map(|&x| Value::f64(x)).collect(),
        ScalarSoA::I8(v) => v.iter().map(|&x| Value::i8(x)).collect(),
        ScalarSoA::I16(v) => v.iter().map(|&x| Value::i16(x)).collect(),
        ScalarSoA::U8(v) => v.iter().map(|&x| Value::u8(x)).collect(),
        ScalarSoA::U16(v) => v.iter().map(|&x| Value::u16(x)).collect(),
        ScalarSoA::U32(v) => v.iter().map(|&x| Value::u32(x)).collect(),
        ScalarSoA::U64(v) => v.iter().map(|&x| Value::u64(x)).collect(),
        ScalarSoA::Bool(v) => v.iter().map(|&x| Value::bool_val(x)).collect(),
        ScalarSoA::Char(v) => v.iter().map(|&x| Value::char_val(char::from_u32(x).unwrap_or('\0'))).collect(),
    }
}

pub fn heap_equals(a: &HeapObj, b: &HeapObj, arena: &ValueArena) -> bool {
    match (a, b) {
        (HeapObj::Str(x), HeapObj::Str(y)) => x.equals(y),
        (HeapObj::Array(x), HeapObj::Array(y)) => {
            if x.fixed_size != y.fixed_size || x.elements.len() != y.elements.len() {
                return false;
            }
            // SoA SIMD 快路径：双方都有 scalar_soa 且同类型
            if let (Some(sa), Some(sb)) = (&x.scalar_soa, &y.scalar_soa) {
                if let Some(result) = try_simd_soa_equals(sa, sb) {
                    return result;
                }
            }
            // 回退：逐元素比较（元素为 Value）
            x.elements
                .iter()
                .zip(&y.elements)
                .all(|(p, q)| value_equals_with_arena(p, q, arena))
        }
        (HeapObj::Record(x), HeapObj::Record(y)) => {
            x.type_name == y.type_name
                && x.field_names == y.field_names
                && x.fields.len() == y.fields.len()
                && x.fields.iter().zip(&y.fields).all(|(p, q)| value_equals_with_arena(p, q, arena))
        }
        (HeapObj::Adt(x), HeapObj::Adt(y)) => {
            x.type_name == y.type_name
                && x.constructor == y.constructor
                && x.fields.len() == y.fields.len()
                && x
                    .fields
                    .iter()
                    .zip(&y.fields)
                    .all(|(xf, yf)| value_equals_with_arena(&xf.value, &yf.value, arena))
        }
        (HeapObj::Newtype(x), HeapObj::Newtype(y)) => {
            x.type_name == y.type_name && x.inner.equals(&y.inner, arena)
        }
        (HeapObj::Cell(x), HeapObj::Cell(y)) => {
            let xb = x.inner.lock().clone();
            let yb = y.inner.lock().clone();
            value_equals_with_arena(&xb, &yb, arena)
        }
        (HeapObj::Range(x), HeapObj::Range(y)) => {
            x.start == y.start && x.end == y.end && x.inclusive == y.inclusive
        }
        (HeapObj::ErrorVal(x), HeapObj::ErrorVal(y)) => {
            x.type_name == y.type_name
                && x.message == y.message
                && x.is_error_subtype == y.is_error_subtype
        }
        (HeapObj::ThrowVal(x), HeapObj::ThrowVal(y)) => match (&x.payload, &y.payload) {
            (ThrowPayload::Ok(a), ThrowPayload::Ok(b)) => value_equals_with_arena(a, b, arena),
            (ThrowPayload::Err(a), ThrowPayload::Err(b)) => Arc::ptr_eq(a, b),
            _ => false,
        },
        (HeapObj::Closure(x), HeapObj::Closure(y)) => {
            x.func_id == y.func_id
                && x.arity == y.arity
                && x.upvalues.len() == y.upvalues.len()
                && x
                    .upvalues
                    .iter()
                    .zip(&y.upvalues)
                    .all(|(p, q)| value_equals_with_arena(p, q, arena))
        }
        (HeapObj::Builtin(x), HeapObj::Builtin(y)) => {
            (x.fn_ptr as usize) == (y.fn_ptr as usize) && x.name == y.name
        }
        _ => std::mem::discriminant(a) == std::mem::discriminant(b),
    }
}

/// Value 语义相等（用于 HeapObj 字段比较）。
/// 标量按 tag + bit 比较；Ref 走 heap_equals 递归；Null/Void 按判别。
pub fn value_equals(a: &Value, b: &Value) -> bool {
    value_equals_with_arena(a, b, &ValueArena::default())
}

/// Value 语义相等（带 ValueArena，用于 ValueHandle 比较）。
pub fn value_equals_with_arena(a: &Value, b: &Value, arena: &ValueArena) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) | (Value::Void, Value::Void) => true,
        (Value::Scalar(av, at), Value::Scalar(bv, bt)) => {
            if at != bt {
                return false;
            }
            // 按 tag 比较 union 字段 bit pattern。
            // 注意：match arm 体以 unsafe{} 开头时，Rust 将其解析为「表达式块」并视作整条 arm 体，
            // 后续 `==` 会被当作下一条 arm 的模式。必须用括号包裹比较表达式。
            match at {
                ValueTag::Bool => (unsafe { av.bool_val } == unsafe { bv.bool_val }),
                ValueTag::Char => (unsafe { av.char_val } == unsafe { bv.char_val }),
                ValueTag::I8 => (unsafe { av.i8_val } == unsafe { bv.i8_val }),
                ValueTag::I16 => (unsafe { av.i16_val } == unsafe { bv.i16_val }),
                ValueTag::I32 => (unsafe { av.i32_val } == unsafe { bv.i32_val }),
                ValueTag::I64 => (unsafe { av.i64_val } == unsafe { bv.i64_val }),
                ValueTag::I128 => (unsafe { av.i128_val } == unsafe { bv.i128_val }),
                ValueTag::U8 => (unsafe { av.u8_val } == unsafe { bv.u8_val }),
                ValueTag::U16 => (unsafe { av.u16_val } == unsafe { bv.u16_val }),
                ValueTag::U32 => (unsafe { av.u32_val } == unsafe { bv.u32_val }),
                ValueTag::U64 => (unsafe { av.u64_val } == unsafe { bv.u64_val }),
                ValueTag::U128 => (unsafe { av.u128_val } == unsafe { bv.u128_val }),
                ValueTag::Isize => (unsafe { av.isize_val } == unsafe { bv.isize_val }),
                ValueTag::Usize => (unsafe { av.usize_val } == unsafe { bv.usize_val }),
                ValueTag::F16 => (unsafe { av.f16_val } == unsafe { bv.f16_val }),
                ValueTag::F32 => unsafe { av.f32_val }.to_bits() == unsafe { bv.f32_val }.to_bits(),
                ValueTag::F64 => unsafe { av.f64_val }.to_bits() == unsafe { bv.f64_val }.to_bits(),
                ValueTag::F128 => (unsafe { av.f128_val } == unsafe { bv.f128_val }),
                _ => unreachable!("non-scalar tag in ScalarValue"),
            }
        }
        (Value::Ref(ax), Value::Ref(bx)) => heap_equals(ax.as_ref(), bx.as_ref(), arena),
        _ => false,
    }
}

/// 深克隆缓存：Value 路径与 ValueHandle 路径各自维护 ptr→结果缓存，
/// 避免环引用（如 Cell）导致无限递归。两条路径的缓存相互独立，
/// 因为 HeapObj 字段处于部分迁移状态（部分为 Value，部分仍为 ValueHandle）。
struct DeepCloneCache {
    handle: FxHashMap<*const HeapObj, ValueHandle>,
    value: FxHashMap<*const HeapObj, Value>,
}

/// Value 路径深克隆：标量/空值直接 clone（廉价），Ref 递归克隆 HeapObj。
fn deep_clone_value(v: &Value, arena: &mut ValueArena, cache: &mut DeepCloneCache) -> Value {
    match v {
        Value::Null | Value::Void | Value::Scalar(_, _) => v.clone(),
        Value::Ref(rc) => {
            let key = Arc::as_ptr(rc);
            if let Some(cached) = cache.value.get(&key) {
                return cached.clone();
            }
            let new_obj = deep_clone_heap(rc.as_ref(), arena, cache);
            let new_v = Value::Ref(Arc::new(new_obj));
            cache.value.insert(key, new_v.clone());
            new_v
        }
    }
}

fn deep_clone_handle(
    h: ValueHandle,
    arena: &mut ValueArena,
    cache: &mut DeepCloneCache,
) -> ValueHandle {
    match h.tag() {
        ValueTag::Null => ValueHandle::NULL,
        ValueTag::Void => ValueHandle::VOID,
        ValueTag::Bool => ValueArena::bool_val(arena.get_bool(h)),
        ValueTag::Char => arena.alloc_char(arena.get_char(h)),
        ValueTag::I8 => arena.alloc_i8(arena.get_i8(h)),
        ValueTag::I16 => arena.alloc_i16(arena.get_i16(h)),
        ValueTag::I32 => arena.alloc_i32(arena.get_i32(h)),
        ValueTag::I64 => arena.alloc_i64(arena.get_i64(h)),
        ValueTag::I128 => arena.alloc_i128(arena.get_i128(h)),
        ValueTag::U8 => arena.alloc_u8(arena.get_u8(h)),
        ValueTag::U16 => arena.alloc_u16(arena.get_u16(h)),
        ValueTag::U32 => arena.alloc_u32(arena.get_u32(h)),
        ValueTag::U64 => arena.alloc_u64(arena.get_u64(h)),
        ValueTag::U128 => arena.alloc_u128(arena.get_u128(h)),
        ValueTag::Isize => arena.alloc_isize(arena.get_isize(h)),
        ValueTag::Usize => arena.alloc_usize(arena.get_usize(h)),
        ValueTag::F16 => arena.alloc_f16(arena.get_f16(h)),
        ValueTag::F32 => arena.alloc_f32(arena.get_f32(h)),
        ValueTag::F64 => arena.alloc_f64(arena.get_f64(h)),
        ValueTag::F128 => arena.alloc_f128(arena.get_f128(h)),
        ValueTag::Ref => {
            let rc = arena.get_ref(h).clone();
            let key = Arc::as_ptr(&rc);
            if let Some(&cached) = cache.handle.get(&key) {
                return cached;
            }
            let new_obj = deep_clone_heap(&rc, arena, cache);
            let new_h = arena.alloc_ref_rc(Arc::new(new_obj));
            cache.handle.insert(key, new_h);
            new_h
        }
    }
}

fn deep_clone_heap(
    obj: &HeapObj,
    arena: &mut ValueArena,
    cache: &mut DeepCloneCache,
) -> HeapObj {
    match obj {
        HeapObj::Str(s) => HeapObj::Str(s.clone()),
        HeapObj::Array(a) => {
            // SoA 快路径：标量是 Copy 的，直接 clone SoA，元素用 Value 重建
            if let Some(soa) = &a.scalar_soa {
                let elems: Vec<Value> = simd_soa_deep_clone(soa);
                return HeapObj::Array(ArrayValue {
                    elements: elems,
                    fixed_size: a.fixed_size,
                    elem_is_ref: a.elem_is_ref,
                    scalar_soa: Some(soa.clone()),
                });
            }
            // 回退：逐元素 deep_clone（元素为 Value）
            let elems: Vec<Value> = a
                .elements
                .iter()
                .map(|e| deep_clone_value(e, arena, cache))
                .collect();
            HeapObj::Array(ArrayValue {
                elements: elems,
                fixed_size: a.fixed_size,
                elem_is_ref: a.elem_is_ref,
                scalar_soa: a.scalar_soa.clone(),
            })
        }
        HeapObj::Record(r) => {
            // fields 已迁移为 Value
            let fields: Vec<Value> = r
                .fields
                .iter()
                .map(|e| deep_clone_value(e, arena, cache))
                .collect();
            HeapObj::Record(RecordValue {
                type_name: r.type_name.clone(),
                fields,
                field_names: r.field_names.clone(),
                field_ref_bits: r.field_ref_bits,
            })
        }
        HeapObj::Adt(a) => {
            // AdtField.value 已迁移为 Value
            let fields: Vec<AdtField> = a
                .fields
                .iter()
                .map(|f| AdtField {
                    name: f.name.clone(),
                    value: deep_clone_value(&f.value, arena, cache),
                })
                .collect();
            HeapObj::Adt(AdtValue {
                type_name: a.type_name.clone(),
                constructor: a.constructor.clone(),
                fields,
                field_ref_bits: a.field_ref_bits,
            })
        }
        HeapObj::Newtype(n) => HeapObj::Newtype(NewtypeValue {
            type_name: n.type_name.clone(),
            // inner 仍为 ValueHandle
            inner: deep_clone_handle(n.inner, arena, cache),
        }),
        HeapObj::Cell(c) => {
            let inner = c.inner.lock().clone();
            HeapObj::Cell(Cell::new(deep_clone_value(&inner, arena, cache)))
        }
        HeapObj::Range(r) => HeapObj::Range(r.clone()),
        HeapObj::Closure(c) => {
            // upvalues 已迁移为 Value，bound_args 仍为 ValueHandle
            let upvalues: Vec<Value> = c
                .upvalues
                .iter()
                .map(|e| deep_clone_value(e, arena, cache))
                .collect();
            let bound_args: Vec<ValueHandle> = c
                .bound_args
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Closure(Closure {
                func_id: c.func_id,
                arity: c.arity,
                upvalues,
                bound_args,
                self_upvalue_idx: c.self_upvalue_idx,
                upvalue_ref_bits: c.upvalue_ref_bits,
                cell_upvalues: c.cell_upvalues,
            })
        }
        HeapObj::Partial(p) => {
            let upvalues: Vec<Value> = p
                .upvalues
                .iter()
                .map(|v| deep_clone_value(v, arena, cache))
                .collect();
            let bound_args: Vec<Value> = p
                .bound_args
                .iter()
                .map(|v| deep_clone_value(v, arena, cache))
                .collect();
            HeapObj::Partial(PartialApplication {
                func_id: p.func_id,
                upvalues,
                bound_args,
                remaining_arity: p.remaining_arity,
                self_upvalue_idx: p.self_upvalue_idx,
            })
        }
        HeapObj::ThrowVal(t) => match &t.payload {
            // ThrowPayload::Ok 已迁移为 Value
            ThrowPayload::Ok(v) => HeapObj::ThrowVal(ThrowValue {
                payload: ThrowPayload::Ok(deep_clone_value(v, arena, cache)),
            }),
            ThrowPayload::Err(r) => HeapObj::ThrowVal(ThrowValue {
                payload: ThrowPayload::Err(r.clone()),
            }),
        },
        HeapObj::Builtin(b) => HeapObj::Builtin(b.clone()),
        HeapObj::TraitVal(t) => HeapObj::TraitVal(t.clone()),
        HeapObj::LazyVal(l) => HeapObj::LazyVal(l.clone()),
        HeapObj::ErrorVal(e) => HeapObj::ErrorVal(e.clone()),
        // AtomicValue.data 为 Value，递归深拷贝
        HeapObj::AtomicVal(a) => HeapObj::AtomicVal(AtomicValue::new(deep_clone_value(&a.load(), arena, cache))),
        HeapObj::AsyncVal(a) => HeapObj::AsyncVal(a.clone()),
        HeapObj::ChannelVal(c) => HeapObj::ChannelVal(c.clone()),
        HeapObj::SenderVal(s) => HeapObj::SenderVal(s.clone()),
        HeapObj::ReceiverVal(r) => HeapObj::ReceiverVal(r.clone()),
        HeapObj::CoroutineFrame => HeapObj::CoroutineFrame,
    }
}

// =========================================================================
// ValueArena 便捷构造器（镜像旧 ValueHandle 构造器 API）+ 格式化/哈希辅助
// =========================================================================

impl ValueArena {
    /// 若句柄为 Ref，返回对应堆对象引用；否则返回 None。
    #[inline]
    pub fn heap_obj_opt(&self, h: ValueHandle) -> Option<&HeapObj> {
        if h.tag() == ValueTag::Ref {
            Some(self.get_ref(h).as_ref())
        } else {
            None
        }
    }

    // ---- 单例便捷构造器（无分配）----
    // null()/void() 由既有 impl ValueArena 提供（已改为 &self）。
    #[inline]
    pub fn bool(&self, v: bool) -> ValueHandle {
        Self::bool_val(v)
    }

    // ---- 标量分配便捷别名 ----
    #[inline]
    pub fn i8(&mut self, v: i8) -> ValueHandle {
        self.alloc_i8(v)
    }
    #[inline]
    pub fn i16(&mut self, v: i16) -> ValueHandle {
        self.alloc_i16(v)
    }
    #[inline]
    pub fn i32(&mut self, v: i32) -> ValueHandle {
        self.alloc_i32(v)
    }
    #[inline]
    pub fn i64(&mut self, v: i64) -> ValueHandle {
        self.alloc_i64(v)
    }
    #[inline]
    pub fn i128(&mut self, v: i128) -> ValueHandle {
        self.alloc_i128(v)
    }
    #[inline]
    pub fn u8(&mut self, v: u8) -> ValueHandle {
        self.alloc_u8(v)
    }
    #[inline]
    pub fn u16(&mut self, v: u16) -> ValueHandle {
        self.alloc_u16(v)
    }
    #[inline]
    pub fn u32(&mut self, v: u32) -> ValueHandle {
        self.alloc_u32(v)
    }
    #[inline]
    pub fn u64(&mut self, v: u64) -> ValueHandle {
        self.alloc_u64(v)
    }
    #[inline]
    pub fn u128(&mut self, v: u128) -> ValueHandle {
        self.alloc_u128(v)
    }
    #[inline]
    pub fn isize(&mut self, v: isize) -> ValueHandle {
        self.alloc_isize(v)
    }
    #[inline]
    pub fn usize(&mut self, v: usize) -> ValueHandle {
        self.alloc_usize(v)
    }
    #[inline]
    pub fn f16(&mut self, v: F16) -> ValueHandle {
        self.alloc_f16(v.0)
    }
    #[inline]
    pub fn f32(&mut self, v: f32) -> ValueHandle {
        self.alloc_f32(v)
    }
    #[inline]
    pub fn f64(&mut self, v: f64) -> ValueHandle {
        self.alloc_f64(v)
    }
    #[inline]
    pub fn f128(&mut self, v: F128) -> ValueHandle {
        self.alloc_f128(v)
    }
    #[inline]
    pub fn char(&mut self, c: Char) -> ValueHandle {
        self.alloc_char(c.codepoint)
    }
    #[inline]
    pub fn from_rust_char(&mut self, c: char) -> ValueHandle {
        self.alloc_char(c as u32)
    }

    // ---- 堆对象便捷构造器 ----
    pub fn str(&mut self, s: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::new(s)))
    }
    pub fn str_from(&mut self, s: &str) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::from_rust_str(s)))
    }
    pub fn from_glue_str(&mut self, s: GlueStr) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(s))
    }
    pub fn heap(&mut self, obj: HeapObj) -> ValueHandle {
        self.alloc_ref(obj)
    }
    pub fn from_ref(&mut self, r: HeapRef) -> ValueHandle {
        self.alloc_ref_rc(r)
    }
    pub fn array(&mut self, elements: Vec<Value>) -> ValueHandle {
        self.alloc_ref(HeapObj::Array(ArrayValue::new(elements)))
    }
    pub fn array_fixed(&mut self, elements: Vec<Value>, size: u64) -> ValueHandle {
        self.alloc_ref(HeapObj::Array(ArrayValue::new_fixed(elements, size)))
    }
    pub fn record(
        &mut self,
        type_name: impl Into<String>,
        fields: Vec<Value>,
        field_names: Vec<Option<String>>,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::Record(RecordValue::new(
            type_name.into(),
            fields,
            field_names,
        )))
    }
    pub fn adt(
        &mut self,
        type_name: impl Into<String>,
        constructor: impl Into<String>,
        fields: Vec<AdtField>,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::Adt(AdtValue::new(
            type_name.into(),
            constructor.into(),
            fields,
        )))
    }
    pub fn newtype(&mut self, type_name: impl Into<String>, inner: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::Newtype(NewtypeValue {
            type_name: type_name.into(),
            inner,
        }))
    }
    pub fn cell(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::Cell(Cell::new(val)))
    }
    pub fn range(&mut self, start: i64, end: i64, inclusive: bool) -> ValueHandle {
        self.alloc_ref(HeapObj::Range(Range::new(start, end, inclusive)))
    }
    pub fn closure(&mut self, c: Closure) -> ValueHandle {
        self.alloc_ref(HeapObj::Closure(c))
    }
    pub fn partial(&mut self, p: PartialApplication) -> ValueHandle {
        self.alloc_ref(HeapObj::Partial(p))
    }
    pub fn builtin(&mut self, fn_ptr: BuiltinFn, name: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Builtin(Builtin {
            fn_ptr,
            name: name.into(),
        }))
    }
    pub fn trait_val(&mut self, t: TraitValue) -> ValueHandle {
        self.alloc_ref(HeapObj::TraitVal(t))
    }
    pub fn lazy(&mut self, l: LazyValue) -> ValueHandle {
        self.alloc_ref(HeapObj::LazyVal(l))
    }
    pub fn error_val(
        &mut self,
        type_name: impl Into<String>,
        message: impl Into<String>,
        is_error_subtype: bool,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::ErrorVal(ErrorValue {
            type_name: type_name.into(),
            message: message.into(),
            is_error_subtype,
        }))
    }
    pub fn throw_ok(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Ok(val),
        }))
    }
    pub fn throw_err(&mut self, record: Arc<RecordValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(record),
        }))
    }
    pub fn atomic(&mut self, val: Value) -> ValueHandle {
        self.alloc_ref(HeapObj::AtomicVal(AtomicValue::new(val)))
    }
    pub fn async_handle(&mut self) -> ValueHandle {
        self.alloc_ref(HeapObj::AsyncVal(AsyncHandle::new()))
    }
    pub fn channel(&mut self, capacity: usize) -> ValueHandle {
        self.alloc_ref(HeapObj::ChannelVal(Arc::new(ChannelValue::new(capacity))))
    }
    pub fn sender(&mut self, channel: Arc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::SenderVal(SenderValue { channel }))
    }
    pub fn receiver(&mut self, channel: Arc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ReceiverVal(ReceiverValue { channel }))
    }

    // ---- 格式化包装器 ----
    pub fn display(&self, h: ValueHandle) -> ValueDisplay<'_> {
        ValueDisplay { arena: self, handle: h }
    }
    pub fn debug(&self, h: ValueHandle) -> ValueDebug<'_> {
        ValueDebug { arena: self, handle: h }
    }

    // ---- 按值哈希 ----
    pub fn hash_value<H: Hasher>(&self, h: ValueHandle, state: &mut H) {
        match h.tag() {
            ValueTag::Null => 0u8.hash(state),
            ValueTag::Void => 1u8.hash(state),
            ValueTag::Bool => {
                2u8.hash(state);
                self.get_bool(h).hash(state)
            }
            ValueTag::Char => {
                3u8.hash(state);
                self.get_char(h).hash(state)
            }
            ValueTag::I8 => {
                4u8.hash(state);
                self.get_i8(h).hash(state)
            }
            ValueTag::I16 => {
                5u8.hash(state);
                self.get_i16(h).hash(state)
            }
            ValueTag::I32 => {
                6u8.hash(state);
                self.get_i32(h).hash(state)
            }
            ValueTag::I64 => {
                7u8.hash(state);
                self.get_i64(h).hash(state)
            }
            ValueTag::I128 => {
                8u8.hash(state);
                self.get_i128(h).hash(state)
            }
            ValueTag::U8 => {
                9u8.hash(state);
                self.get_u8(h).hash(state)
            }
            ValueTag::U16 => {
                10u8.hash(state);
                self.get_u16(h).hash(state)
            }
            ValueTag::U32 => {
                11u8.hash(state);
                self.get_u32(h).hash(state)
            }
            ValueTag::U64 => {
                12u8.hash(state);
                self.get_u64(h).hash(state)
            }
            ValueTag::U128 => {
                13u8.hash(state);
                self.get_u128(h).hash(state)
            }
            ValueTag::Isize => {
                14u8.hash(state);
                self.get_isize(h).hash(state)
            }
            ValueTag::Usize => {
                15u8.hash(state);
                self.get_usize(h).hash(state)
            }
            ValueTag::F16 => {
                16u8.hash(state);
                self.get_f16(h).hash(state)
            }
            ValueTag::F32 => {
                17u8.hash(state);
                self.get_f32(h).to_bits().hash(state)
            }
            ValueTag::F64 => {
                18u8.hash(state);
                self.get_f64(h).to_bits().hash(state)
            }
            ValueTag::F128 => {
                19u8.hash(state);
                self.get_f128(h).hash(state)
            }
            ValueTag::Ref => {
                20u8.hash(state);
                self.get_ref(h).hash(state);
            }
        }
    }
}

// `read_int_as!` 按 tag 从字节读取整数并提升为 i128 / u128。
// 整数类型（含 Isize/Usize）经符号扩展后转目标类型，非整数 tag 回退 0。
// 有符号源在转 u128 时经 i128 中转，以保留与原逐臂代码一致的语义。
macro_rules! read_int_as {
    ($tag:expr, $bytes:expr, i128) => {
        match $tag {
            ValueTag::I8    => $bytes.first().copied().unwrap_or(0) as i8 as i128,
            ValueTag::U8    => $bytes.first().copied().unwrap_or(0) as u8 as i128,
            ValueTag::I16   => read_i16_le($bytes) as i128,
            ValueTag::U16   => read_u16_le($bytes) as i128,
            ValueTag::I32   => read_i32_le($bytes) as i128,
            ValueTag::U32   => read_u32_le($bytes) as i128,
            ValueTag::I64   => read_i64_le($bytes) as i128,
            ValueTag::U64   => read_u64_le($bytes) as i128,
            ValueTag::I128  => read_i128_le($bytes),
            ValueTag::U128  => read_u128_le($bytes) as i128,
            ValueTag::Isize => read_i64_le($bytes) as isize as i128,
            ValueTag::Usize => read_u64_le($bytes) as usize as i128,
            _ => 0,
        }
    };
    ($tag:expr, $bytes:expr, u128) => {
        match $tag {
            ValueTag::I8    => $bytes.first().copied().unwrap_or(0) as i8 as i128 as u128,
            ValueTag::U8    => $bytes.first().copied().unwrap_or(0) as u8 as u128,
            ValueTag::I16   => read_i16_le($bytes) as i128 as u128,
            ValueTag::U16   => read_u16_le($bytes) as u128,
            ValueTag::I32   => read_i32_le($bytes) as i128 as u128,
            ValueTag::U32   => read_u32_le($bytes) as u128,
            ValueTag::I64   => read_i64_le($bytes) as i128 as u128,
            ValueTag::U64   => read_u64_le($bytes) as u128,
            ValueTag::I128  => read_i128_le($bytes) as u128,
            ValueTag::U128  => read_u128_le($bytes),
            ValueTag::Isize => read_i64_le($bytes) as isize as i128 as u128,
            ValueTag::Usize => read_u64_le($bytes) as usize as u128,
            _ => 0,
        }
    };
}

// `write_int_bytes!` 按 dst_tag 将整数（i128 或 u128）写入目标字节缓冲，
// 复用既有 write_*_le 辅助函数以保持与原逐臂代码一致的截断/填充语义。
macro_rules! write_int_bytes {
    ($val:expr, $tag:expr, $dst:expr) => {
        match $tag {
            ValueTag::I8    => write_i8($val as i8, $dst),
            ValueTag::U8    => write_u8($val as u8, $dst),
            ValueTag::I16   => write_i16_le($val as i16, $dst),
            ValueTag::U16   => write_u16_le($val as u16, $dst),
            ValueTag::I32   => write_i32_le($val as i32, $dst),
            ValueTag::U32   => write_u32_le($val as u32, $dst),
            ValueTag::I64   => write_i64_le($val as i64, $dst),
            ValueTag::U64   => write_u64_le($val as u64, $dst),
            ValueTag::I128  => write_i128_le($val as i128, $dst),
            ValueTag::U128  => write_u128_le($val as u128, $dst),
            ValueTag::Isize => write_i64_le($val as isize as i64, $dst),
            ValueTag::Usize => write_u64_le($val as usize as u64, $dst),
            _ => {}
        }
    };
}

// =========================================================================
// 第十一部分：ops.rs（Num trait + BitOps trait + impl）
// =========================================================================

/// 数值运算 trait：支持溢出检测的算术运算
pub trait Num: Sized + Copy {
    fn checked_add(self, other: Self) -> Option<Self>;
    fn checked_sub(self, other: Self) -> Option<Self>;
    fn checked_mul(self, other: Self) -> Option<Self>;
    fn checked_div(self, other: Self) -> Option<Self>;
    fn checked_rem(self, other: Self) -> Option<Self>;
    fn neg(self) -> Option<Self>;
    fn zero() -> Self;
    fn wrapping_add(self, other: Self) -> Self;
    fn wrapping_sub(self, other: Self) -> Self;
    fn wrapping_mul(self, other: Self) -> Self;
    fn wrapping_neg(self) -> Self;
    fn abs(self) -> Self;
    fn to_u32(self) -> u32;
}

macro_rules! impl_num_signed {
    ($($t:ty),*) => {
        $(
            impl Num for $t {
                fn checked_add(self, other: Self) -> Option<Self> { self.checked_add(other) }
                fn checked_sub(self, other: Self) -> Option<Self> { self.checked_sub(other) }
                fn checked_mul(self, other: Self) -> Option<Self> { self.checked_mul(other) }
                fn checked_div(self, other: Self) -> Option<Self> { self.checked_div(other) }
                fn checked_rem(self, other: Self) -> Option<Self> { self.checked_rem(other) }
                fn neg(self) -> Option<Self> { self.checked_neg() }
                fn zero() -> Self { 0 }
                fn wrapping_add(self, other: Self) -> Self { self.wrapping_add(other) }
                fn wrapping_sub(self, other: Self) -> Self { self.wrapping_sub(other) }
                fn wrapping_mul(self, other: Self) -> Self { self.wrapping_mul(other) }
                fn wrapping_neg(self) -> Self { self.wrapping_neg() }
                fn abs(self) -> Self { self.wrapping_abs() }
                fn to_u32(self) -> u32 { self as u32 }
            }
        )*
    };
}

macro_rules! impl_num_unsigned {
    ($($t:ty),*) => {
        $(
            impl Num for $t {
                fn checked_add(self, other: Self) -> Option<Self> { self.checked_add(other) }
                fn checked_sub(self, other: Self) -> Option<Self> { self.checked_sub(other) }
                fn checked_mul(self, other: Self) -> Option<Self> { self.checked_mul(other) }
                fn checked_div(self, other: Self) -> Option<Self> { self.checked_div(other) }
                fn checked_rem(self, other: Self) -> Option<Self> { self.checked_rem(other) }
                fn neg(self) -> Option<Self> { self.checked_neg() }
                fn zero() -> Self { 0 }
                fn wrapping_add(self, other: Self) -> Self { self.wrapping_add(other) }
                fn wrapping_sub(self, other: Self) -> Self { self.wrapping_sub(other) }
                fn wrapping_mul(self, other: Self) -> Self { self.wrapping_mul(other) }
                fn wrapping_neg(self) -> Self { self.wrapping_neg() }
                fn abs(self) -> Self { self }
                fn to_u32(self) -> u32 { self as u32 }
            }
        )*
    };
}

impl_num_signed!(i8, i16, i32, i64, i128, isize);
impl_num_unsigned!(u8, u16, u32, u64, u128, usize);

impl Num for f32 {
    fn checked_add(self, other: Self) -> Option<Self> { Some(self + other) }
    fn checked_sub(self, other: Self) -> Option<Self> { Some(self - other) }
    fn checked_mul(self, other: Self) -> Option<Self> { Some(self * other) }
    fn checked_div(self, other: Self) -> Option<Self> { Some(self / other) }
    fn checked_rem(self, other: Self) -> Option<Self> { Some(self % other) }
    fn neg(self) -> Option<Self> { Some(-self) }
    fn zero() -> Self { 0.0 }
    fn wrapping_add(self, other: Self) -> Self { self + other }
    fn wrapping_sub(self, other: Self) -> Self { self - other }
    fn wrapping_mul(self, other: Self) -> Self { self * other }
    fn wrapping_neg(self) -> Self { -self }
    fn abs(self) -> Self { self.abs() }
    fn to_u32(self) -> u32 { self as u32 }
}

impl Num for f64 {
    fn checked_add(self, other: Self) -> Option<Self> { Some(self + other) }
    fn checked_sub(self, other: Self) -> Option<Self> { Some(self - other) }
    fn checked_mul(self, other: Self) -> Option<Self> { Some(self * other) }
    fn checked_div(self, other: Self) -> Option<Self> { Some(self / other) }
    fn checked_rem(self, other: Self) -> Option<Self> { Some(self % other) }
    fn neg(self) -> Option<Self> { Some(-self) }
    fn zero() -> Self { 0.0 }
    fn wrapping_add(self, other: Self) -> Self { self + other }
    fn wrapping_sub(self, other: Self) -> Self { self - other }
    fn wrapping_mul(self, other: Self) -> Self { self * other }
    fn wrapping_neg(self) -> Self { -self }
    fn abs(self) -> Self { self.abs() }
    fn to_u32(self) -> u32 { self as u32 }
}

/// 位运算 trait
pub trait BitOps: Sized + Copy {
    fn bit_and(self, other: Self) -> Self;
    fn bit_or(self, other: Self) -> Self;
    fn bit_xor(self, other: Self) -> Self;
    fn bit_not(self) -> Self;
    fn shl(self, amount: u32) -> Self;
    fn shr(self, amount: u32) -> Self;
}

macro_rules! impl_bitops {
    ($($t:ty),*) => {
        $(
            impl BitOps for $t {
                fn bit_and(self, other: Self) -> Self { self & other }
                fn bit_or(self, other: Self) -> Self { self | other }
                fn bit_xor(self, other: Self) -> Self { self ^ other }
                fn bit_not(self) -> Self { !self }
                fn shl(self, amount: u32) -> Self { self.wrapping_shl(amount) }
                fn shr(self, amount: u32) -> Self { self.wrapping_shr(amount) }
            }
        )*
    };
}

impl_bitops!(i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize);

// =========================================================================
// 第十二部分：cast.rs（CastError, ParseError, cast_value, try_cast_value, parse_str）
// =========================================================================

/// 转换错误
#[derive(Debug, Clone, PartialEq)]
pub enum CastError {
    Overflow,
    InvalidCodepoint,
}

/// 解析错误
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    ParseFailed(String),
}

pub fn cast_value(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag) -> Vec<u8> {
    let dst_width = dst_tag.byte_width();
    let mut result = vec![0u8; dst_width];

    if src_tag == dst_tag {
        let copy_len = src_bytes.len().min(dst_width);
        result[..copy_len].copy_from_slice(&src_bytes[..copy_len]);
        return result;
    }

    match (src_tag, dst_tag) {
        (ValueTag::Bool, _) => {
            let b = read_bool(src_bytes);
            cast_from_bool(b, dst_tag, &mut result);
        }
        (ValueTag::Char, _) => {
            let cp = read_u32_le(src_bytes);
            cast_from_u32(cp, dst_tag, &mut result);
        }
        (_, ValueTag::Bool) => {
            let b = cast_to_bool(src_tag, src_bytes);
            write_bool(b, &mut result);
        }
        (_, ValueTag::Char) => {
            let cp = cast_to_u32(src_tag, src_bytes);
            write_u32_le(cp, &mut result);
        }
        (s, d) if s.is_int() && d.is_int() => {
            cast_int_to_int(src_tag, src_bytes, dst_tag, &mut result);
        }
        (s, d) if s.is_int() && d.is_float() => {
            cast_int_to_float(src_tag, src_bytes, dst_tag, &mut result);
        }
        (s, d) if s.is_float() && d.is_int() => {
            cast_float_to_int(src_tag, src_bytes, dst_tag, &mut result);
        }
        (s, d) if s.is_float() && d.is_float() => {
            cast_float_to_float(src_tag, src_bytes, dst_tag, &mut result);
        }
        _ => {}
    }

    result
}

pub fn try_cast_value(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag) -> Result<Vec<u8>, CastError> {
    if src_tag == dst_tag {
        return Ok(cast_value(src_tag, src_bytes, dst_tag));
    }

    if src_tag.is_int() && dst_tag == ValueTag::Char {
        let cp = cast_to_u32(src_tag, src_bytes);
        if cp > 0x10FFFF || (0xD800..=0xDFFF).contains(&cp) {
            return Err(CastError::InvalidCodepoint);
        }
        let mut result = vec![0u8; 4];
        write_u32_le(cp, &mut result);
        return Ok(result);
    }

    if src_tag.is_int() && dst_tag.is_int() && src_tag.byte_width() > dst_tag.byte_width() {
        return try_cast_int_narrow(src_tag, src_bytes, dst_tag);
    }

    if src_tag.is_float() && dst_tag.is_int() {
        return try_cast_float_to_int(src_tag, src_bytes, dst_tag);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

pub fn parse_str(s: &str, dst_tag: ValueTag) -> Result<Vec<u8>, ParseError> {
    let trimmed = s.trim();
    let result = vec![0u8; dst_tag.byte_width()];

    if trimmed.is_empty() {
        return Err(ParseError::ParseFailed("empty string".to_string()));
    }

    let mut result = result;

    match dst_tag {
        ValueTag::Bool => {
            let b = match trimmed.to_ascii_lowercase().as_str() {
                "true" => true,
                "false" => false,
                _ => return Err(ParseError::ParseFailed(format!("invalid bool: {}", s))),
            };
            write_bool(b, &mut result);
        }
        ValueTag::Char => {
            let mut chars = trimmed.chars();
            let c = chars.next().ok_or_else(|| ParseError::ParseFailed("empty char".to_string()))?;
            if chars.next().is_some() {
                return Err(ParseError::ParseFailed("char must be single character".to_string()));
            }
            write_u32_le(c as u32, &mut result);
        }
        ValueTag::I8 => {
            let v: i8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i8(v, &mut result);
        }
        ValueTag::I16 => {
            let v: i16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i16_le(v, &mut result);
        }
        ValueTag::I32 => {
            let v: i32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i32_le(v, &mut result);
        }
        ValueTag::I64 => {
            let v: i64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v, &mut result);
        }
        ValueTag::I128 => {
            let v: i128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i128_le(v, &mut result);
        }
        ValueTag::U8 => {
            let v: u8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u8(v, &mut result);
        }
        ValueTag::U16 => {
            let v: u16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u16_le(v, &mut result);
        }
        ValueTag::U32 => {
            let v: u32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u32_le(v, &mut result);
        }
        ValueTag::U64 => {
            let v: u64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v, &mut result);
        }
        ValueTag::U128 => {
            let v: u128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u128_le(v, &mut result);
        }
        ValueTag::Isize => {
            let v: isize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v as i64, &mut result);
        }
        ValueTag::Usize => {
            let v: usize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v as u64, &mut result);
        }
        ValueTag::F32 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f32_le(v, &mut result);
        }
        ValueTag::F64 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f64_le(v, &mut result);
        }
        ValueTag::F16 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f16 = F16::from_f32(v);
            write_u16_le(f16.0, &mut result);
        }
        ValueTag::F128 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f128 = F128::from_f64(v);
            result.copy_from_slice(&f128.0);
        }
        _ => return Err(ParseError::ParseFailed(format!("unsupported tag: {:?}", dst_tag))),
    }

    Ok(result)
}

// ---- cast 内部辅助 ----

fn read_bool(bytes: &[u8]) -> bool {
    bytes.first().copied().unwrap_or(0) != 0
}

fn read_i16_le(bytes: &[u8]) -> i16 {
    let mut buf = [0u8; 2];
    let len = bytes.len().min(2);
    buf[..len].copy_from_slice(&bytes[..len]);
    i16::from_le_bytes(buf)
}

fn read_u16_le(bytes: &[u8]) -> u16 {
    let mut buf = [0u8; 2];
    let len = bytes.len().min(2);
    buf[..len].copy_from_slice(&bytes[..len]);
    u16::from_le_bytes(buf)
}

fn read_i32_le(bytes: &[u8]) -> i32 {
    let mut buf = [0u8; 4];
    let len = bytes.len().min(4);
    buf[..len].copy_from_slice(&bytes[..len]);
    i32::from_le_bytes(buf)
}

fn read_u32_le(bytes: &[u8]) -> u32 {
    let mut buf = [0u8; 4];
    let len = bytes.len().min(4);
    buf[..len].copy_from_slice(&bytes[..len]);
    u32::from_le_bytes(buf)
}

fn read_i64_le(bytes: &[u8]) -> i64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    i64::from_le_bytes(buf)
}

fn read_u64_le(bytes: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    u64::from_le_bytes(buf)
}

fn read_i128_le(bytes: &[u8]) -> i128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    i128::from_le_bytes(buf)
}

fn read_u128_le(bytes: &[u8]) -> u128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    u128::from_le_bytes(buf)
}

fn read_f32_le(bytes: &[u8]) -> f32 {
    let mut buf = [0u8; 4];
    let len = bytes.len().min(4);
    buf[..len].copy_from_slice(&bytes[..len]);
    f32::from_le_bytes(buf)
}

fn read_f64_le(bytes: &[u8]) -> f64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    f64::from_le_bytes(buf)
}

fn read_f16(bits: &[u8]) -> F16 {
    let mut buf = [0u8; 2];
    let len = bits.len().min(2);
    buf[..len].copy_from_slice(&bits[..len]);
    F16(u16::from_le_bytes(buf))
}

fn read_f128(bytes: &[u8]) -> F128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    F128(buf)
}

fn read_int_as_i128(tag: ValueTag, bytes: &[u8]) -> i128 {
    read_int_as!(tag, bytes, i128)
}

fn read_int_as_u128(tag: ValueTag, bytes: &[u8]) -> u128 {
    read_int_as!(tag, bytes, u128)
}

fn write_bool(b: bool, dst: &mut [u8]) {
    if dst.is_empty() { return; }
    dst[0] = if b { 1 } else { 0 };
}

fn write_u8(v: u8, dst: &mut [u8]) {
    if !dst.is_empty() { dst[0] = v; }
}

fn write_i8(v: i8, dst: &mut [u8]) {
    write_u8(v as u8, dst);
}

fn write_u16_le(v: u16, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(2);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i16_le(v: i16, dst: &mut [u8]) {
    write_u16_le(v as u16, dst);
}

fn write_u32_le(v: u32, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(4);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i32_le(v: i32, dst: &mut [u8]) {
    write_u32_le(v as u32, dst);
}

fn write_u64_le(v: u64, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(8);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i64_le(v: i64, dst: &mut [u8]) {
    write_u64_le(v as u64, dst);
}

fn write_u128_le(v: u128, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(16);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i128_le(v: i128, dst: &mut [u8]) {
    write_u128_le(v as u128, dst);
}

fn write_f32_le(v: f32, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(4);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_f64_le(v: f64, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(8);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_f16(f: F16, dst: &mut [u8]) {
    write_u16_le(f.0, dst);
}

fn write_f128(f: F128, dst: &mut [u8]) {
    let len = dst.len().min(16);
    dst[..len].copy_from_slice(&f.0[..len]);
}

fn cast_from_bool(b: bool, dst_tag: ValueTag, dst: &mut [u8]) {
    let val: i128 = if b { 1 } else { 0 };
    if dst_tag.is_int() {
        cast_from_i128(val, dst_tag, dst);
    } else if dst_tag.is_float() {
        let f = if b { 1.0 } else { 0.0 };
        cast_from_f64(f, dst_tag, dst);
    } else if dst_tag == ValueTag::Char {
        write_u32_le(val as u32, dst);
    }
}

fn cast_from_u32(cp: u32, dst_tag: ValueTag, dst: &mut [u8]) {
    if dst_tag.is_int() {
        cast_from_u128(cp as u128, dst_tag, dst);
    } else if dst_tag.is_float() {
        cast_from_f64(cp as f64, dst_tag, dst);
    } else if dst_tag == ValueTag::Bool {
        write_bool(cp != 0, dst);
    }
}

fn cast_from_i128(val: i128, dst_tag: ValueTag, dst: &mut [u8]) {
    write_int_bytes!(val, dst_tag, dst)
}

fn cast_from_u128(val: u128, dst_tag: ValueTag, dst: &mut [u8]) {
    write_int_bytes!(val, dst_tag, dst)
}

fn cast_from_f64(val: f64, dst_tag: ValueTag, dst: &mut [u8]) {
    match dst_tag {
        ValueTag::F16 => write_f16(F16::from_f32(val as f32), dst),
        ValueTag::F32 => write_f32_le(val as f32, dst),
        ValueTag::F64 => write_f64_le(val, dst),
        ValueTag::F128 => write_f128(F128::from_f64(val), dst),
        _ => {}
    }
}

fn cast_to_bool(src_tag: ValueTag, src_bytes: &[u8]) -> bool {
    match src_tag {
        ValueTag::Bool => read_bool(src_bytes),
        ValueTag::Char => read_u32_le(src_bytes) != 0,
        ValueTag::I8 => src_bytes.first().copied().unwrap_or(0) as i8 != 0,
        ValueTag::U8 => src_bytes.first().copied().unwrap_or(0) != 0,
        ValueTag::I16 | ValueTag::U16 => {
            let mut b = [0u8; 2];
            let l = src_bytes.len().min(2);
            b[..l].copy_from_slice(&src_bytes[..l]);
            u16::from_le_bytes(b) != 0
        }
        ValueTag::I32 | ValueTag::U32 => {
            let v = read_u32_le(src_bytes);
            v != 0
        }
        ValueTag::I64 | ValueTag::U64 | ValueTag::Isize | ValueTag::Usize => {
            read_u64_le(src_bytes) != 0
        }
        ValueTag::I128 | ValueTag::U128 => {
            read_u128_le(src_bytes) != 0
        }
        ValueTag::F32 => read_f32_le(src_bytes) != 0.0,
        ValueTag::F64 => read_f64_le(src_bytes) != 0.0,
        ValueTag::F16 => read_f16(src_bytes).to_f32() != 0.0,
        ValueTag::F128 => read_f128(src_bytes).to_f64() != 0.0,
        _ => false,
    }
}

fn cast_to_u32(src_tag: ValueTag, src_bytes: &[u8]) -> u32 {
    if src_tag.is_int() {
        read_int_as_u128(src_tag, src_bytes) as u32
    } else if src_tag.is_float() {
        let f = read_float_as_f64(src_tag, src_bytes);
        if f.is_nan() {
            0
        } else if f >= u32::MAX as f64 {
            u32::MAX
        } else if f <= 0.0 {
            0
        } else {
            f as u32
        }
    } else if src_tag == ValueTag::Bool {
        if read_bool(src_bytes) { 1 } else { 0 }
    } else {
        0
    }
}

fn read_float_as_f64(tag: ValueTag, bytes: &[u8]) -> f64 {
    match tag {
        ValueTag::F16 => read_f16(bytes).to_f64(),
        ValueTag::F32 => read_f32_le(bytes) as f64,
        ValueTag::F64 => read_f64_le(bytes),
        ValueTag::F128 => read_f128(bytes).to_f64(),
        _ => 0.0,
    }
}

fn cast_int_to_int(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag, dst: &mut [u8]) {
    if dst_tag.is_signed() {
        let val = read_int_as_i128(src_tag, src_bytes);
        cast_from_i128(val, dst_tag, dst);
    } else {
        let val = read_int_as_u128(src_tag, src_bytes);
        cast_from_u128(val, dst_tag, dst);
    }
}

fn cast_int_to_float(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag, dst: &mut [u8]) {
    let val = if src_tag.is_signed() {
        read_int_as_i128(src_tag, src_bytes) as f64
    } else {
        read_int_as_u128(src_tag, src_bytes) as f64
    };
    cast_from_f64(val, dst_tag, dst);
}

fn cast_float_to_int(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);
    match dst_tag {
        ValueTag::I8 => write_i8(f as i8, dst),
        ValueTag::I16 => write_i16_le(f as i16, dst),
        ValueTag::I32 => write_i32_le(f as i32, dst),
        ValueTag::I64 => write_i64_le(f as i64, dst),
        ValueTag::I128 => write_i128_le(f as i128, dst),
        ValueTag::Isize => write_i64_le(f as isize as i64, dst),
        ValueTag::U8 => write_u8(f as u8, dst),
        ValueTag::U16 => write_u16_le(f as u16, dst),
        ValueTag::U32 => write_u32_le(f as u32, dst),
        ValueTag::U64 => write_u64_le(f as u64, dst),
        ValueTag::U128 => write_u128_le(f as u128, dst),
        ValueTag::Usize => write_u64_le(f as usize as u64, dst),
        _ => {}
    }
}

fn cast_float_to_float(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);
    cast_from_f64(f, dst_tag, dst);
}

fn try_cast_int_narrow(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag) -> Result<Vec<u8>, CastError> {
    let sval = read_int_as_i128(src_tag, src_bytes);
    let uval = read_int_as_u128(src_tag, src_bytes);

    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ValueTag::I8 => (i8::MIN as i128..=i8::MAX as i128).contains(&sval),
            ValueTag::I16 => (i16::MIN as i128..=i16::MAX as i128).contains(&sval),
            ValueTag::I32 => (i32::MIN as i128..=i32::MAX as i128).contains(&sval),
            ValueTag::I64 => (i64::MIN as i128..=i64::MAX as i128).contains(&sval),
            ValueTag::Isize => (isize::MIN as i128..=isize::MAX as i128).contains(&sval),
            _ => true,
        }
    } else {
        if src_tag.is_signed() && sval < 0 {
            false
        } else {
            match dst_tag {
                ValueTag::U8 => uval <= u8::MAX as u128,
                ValueTag::U16 => uval <= u16::MAX as u128,
                ValueTag::U32 => uval <= u32::MAX as u128,
                ValueTag::U64 => uval <= u64::MAX as u128,
                ValueTag::Usize => uval <= usize::MAX as u128,
                _ => true,
            }
        }
    };

    if !in_range {
        return Err(CastError::Overflow);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

fn try_cast_float_to_int(src_tag: ValueTag, src_bytes: &[u8], dst_tag: ValueTag) -> Result<Vec<u8>, CastError> {
    let f = read_float_as_f64(src_tag, src_bytes);

    if f.is_nan() || f.is_infinite() {
        return Err(CastError::Overflow);
    }

    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ValueTag::I8 => f >= i8::MIN as f64 && f <= i8::MAX as f64,
            ValueTag::I16 => f >= i16::MIN as f64 && f <= i16::MAX as f64,
            ValueTag::I32 => f >= i32::MIN as f64 && f <= i32::MAX as f64,
            ValueTag::I64 => f >= i64::MIN as f64 && f <= i64::MAX as f64,
            ValueTag::I128 => f >= i128::MIN as f64 && f <= i128::MAX as f64,
            ValueTag::Isize => f >= isize::MIN as f64 && f <= isize::MAX as f64,
            _ => true,
        }
    } else {
        match dst_tag {
            ValueTag::U8 => f >= 0.0 && f <= u8::MAX as f64,
            ValueTag::U16 => f >= 0.0 && f <= u16::MAX as f64,
            ValueTag::U32 => f >= 0.0 && f <= u32::MAX as f64,
            ValueTag::U64 => f >= 0.0 && f <= u64::MAX as f64,
            ValueTag::U128 => f >= 0.0 && f <= u128::MAX as f64,
            ValueTag::Usize => f >= 0.0 && f <= usize::MAX as f64,
            _ => true,
        }
    };

    if !in_range {
        return Err(CastError::Overflow);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

// =========================================================================
// 第十三部分：batch.rs（精简）
// =========================================================================

/// 二元运算
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinOp {
    Add, Sub, Mul, Div, Mod, Band, Bor, Bxor, Shl, Shr,
}

/// 一元运算
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnaryOp {
    Neg, Abs, Bnot,
}

/// 比较运算
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CmpOp {
    Lt, Gt, Eq, Ne, Le, Ge,
}

/// 归约运算
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReduceOp {
    Add, Mul, Band, Bor, Bxor,
}

/// 大数组并行阈值：超过该长度时启用 rayon 并行分块。
const PARALLEL_THRESHOLD: usize = 4096;

/// 计算并行分块大小：将数组切成约 (线程数 × 4) 块，并对齐到 4 lane
/// 以便 SIMD kernel 每个 chunk 都能尽量走满整 lane。
#[inline]
fn par_chunk_size(n: usize) -> usize {
    let pieces = rayon::current_num_threads().max(1) * 4;
    let chunk = n.div_ceil(pieces);
    // 向上对齐到 4 的倍数
    let chunk = (chunk + 3) & !3;
    chunk.max(4)
}

/// 通用二元运算分派（标量路径）。大数组（> PARALLEL_THRESHOLD）走 rayon 并行，
/// 小数组走单线程标量以避免线程调度开销。
pub fn batch_binop<T>(dst: &mut [T], a: &[T], b: &[T], op: BinOp)
where
    T: Num + BitOps + Send + Sync,
{
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| {
                let m = d.len();
                for i in 0..m {
                    d[i] = binop_scalar_t(av[i], bv[i], op);
                }
            });
    } else {
        for i in 0..n {
            dst[i] = binop_scalar_t(a[i], b[i], op);
        }
    }
}

/// 标量二元运算（泛型后备，与原始 for 循环语义完全一致）。
#[inline]
fn binop_scalar_t<T: Num + BitOps>(a: T, b: T, op: BinOp) -> T {
    match op {
        BinOp::Add => a.wrapping_add(b),
        BinOp::Sub => a.wrapping_sub(b),
        BinOp::Mul => a.wrapping_mul(b),
        BinOp::Div => a.checked_div(b).expect("division by zero"),
        BinOp::Mod => a.checked_rem(b).expect("division by zero"),
        BinOp::Band => a.bit_and(b),
        BinOp::Bor => a.bit_or(b),
        BinOp::Bxor => a.bit_xor(b),
        BinOp::Shl => a.shl(b.to_u32()),
        BinOp::Shr => a.shr(b.to_u32()),
    }
}

/// 通用一元运算分派
pub fn batch_unaryop<T>(dst: &mut [T], a: &[T], op: UnaryOp)
where T: Num + BitOps {
    let n = dst.len().min(a.len());
    for i in 0..n {
        dst[i] = match op {
            UnaryOp::Neg => a[i].wrapping_neg(),
            UnaryOp::Abs => a[i].abs(),
            UnaryOp::Bnot => a[i].bit_not(),
        };
    }
}

/// 批量比较运算：输出 `u8` 掩码（0/1）。大数组走 rayon 并行，小数组走标量。
pub fn batch_cmp<T>(dst: &mut [u8], a: &[T], b: &[T], op: CmpOp)
where
    T: PartialOrd + Sync,
{
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| {
                let m = d.len();
                for i in 0..m {
                    d[i] = cmp_scalar_t(&av[i], &bv[i], op) as u8;
                }
            });
    } else {
        for i in 0..n {
            dst[i] = cmp_scalar_t(&a[i], &b[i], op) as u8;
        }
    }
}

/// 标量比较（泛型后备，按引用比较，因此不要求 T: Copy）。
#[inline]
fn cmp_scalar_t<T: PartialOrd + ?Sized>(a: &T, b: &T, op: CmpOp) -> bool {
    match op {
        CmpOp::Lt => a < b,
        CmpOp::Gt => a > b,
        CmpOp::Eq => a == b,
        CmpOp::Ne => a != b,
        CmpOp::Le => a <= b,
        CmpOp::Ge => a >= b,
    }
}

/// 批量归约运算。大数组走 rayon 并行归约（各分块局部归约后再合并，
/// wrapping add/mul 与位运算均满足结合律，结果与顺序归约一致）。
pub fn batch_reduce<T>(a: &[T], op: ReduceOp) -> T
where
    T: Num + BitOps + Send + Sync,
{
    if a.is_empty() {
        return T::zero();
    }
    if a.len() > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(a.len());
        let partials: Vec<T> = a.par_chunks(chunk).map(|c| reduce_seq(c, op)).collect();
        let mut acc = partials[0];
        for &p in &partials[1..] {
            acc = reduce_combine(acc, p, op);
        }
        acc
    } else {
        reduce_seq(a, op)
    }
}

/// 顺序归约（从 a[0] 起累加，与原始实现语义一致）。
#[inline]
fn reduce_seq<T: Num + BitOps>(a: &[T], op: ReduceOp) -> T {
    if a.is_empty() {
        return T::zero();
    }
    let mut acc = a[0];
    for &v in &a[1..] {
        acc = match op {
            ReduceOp::Add => acc.wrapping_add(v),
            ReduceOp::Mul => acc.wrapping_mul(v),
            ReduceOp::Band => acc.bit_and(v),
            ReduceOp::Bor => acc.bit_or(v),
            ReduceOp::Bxor => acc.bit_xor(v),
        };
    }
    acc
}

/// 合并两个归约部分结果。
#[inline]
fn reduce_combine<T: Num + BitOps>(a: T, b: T, op: ReduceOp) -> T {
    match op {
        ReduceOp::Add => a.wrapping_add(b),
        ReduceOp::Mul => a.wrapping_mul(b),
        ReduceOp::Band => a.bit_and(b),
        ReduceOp::Bor => a.bit_or(b),
        ReduceOp::Bxor => a.bit_xor(b),
    }
}

/// 掩码选择
pub fn batch_select<T>(dst: &mut [T], mask: &[u8], t: &[T], f: &[T])
where T: Copy {
    let n = dst.len().min(mask.len()).min(t.len()).min(f.len());
    for i in 0..n {
        dst[i] = if mask[i] != 0 { t[i] } else { f[i] };
    }
}

/// 广播
pub fn broadcast<T>(dst: &mut [T], val: T)
where T: Copy {
    for slot in dst.iter_mut() {
        *slot = val;
    }
}

// =========================================================================
// 第十三部分补充：SIMD 加速特化（wide crate + rayon）
//
// 对 f32/f64/i32/i64 提供独立的 SIMD 特化函数（4-wide）。
// - 算术/位运算走 SIMD lane，无法向量化的运算（整数 Div/Mod/Shl/Shr、
//   浮点 Mod）回退到标量；
// - 大数组（> PARALLEL_THRESHOLD）走 rayon 并行分块，每块由 SIMD kernel 处理；
// - 这些是 *额外* 的 pub fn，泛型版本（batch_binop 等）保持不变。
// =========================================================================

/// SIMD lane 宽度。
const SIMD_LANES: usize = 4;

// -------------------- f32 --------------------

#[inline]
fn binop_f32_scalar(a: f32, b: f32, op: BinOp) -> f32 {
    match op {
        BinOp::Add => a + b,
        BinOp::Sub => a - b,
        BinOp::Mul => a * b,
        BinOp::Div => a / b,
        BinOp::Mod => a % b,
        // f32 不支持位运算/移位，保持原值
        _ => a,
    }
}

fn binop_f32_kernel(dst: &mut [f32], a: &[f32], b: &[f32], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    let use_simd = matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div);
    if use_simd {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            let va = f32x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
            let vb = f32x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
            let r = match op {
                BinOp::Add => va + vb,
                BinOp::Sub => va - vb,
                BinOp::Mul => va * vb,
                BinOp::Div => va / vb,
                _ => unreachable!(),
            };
            dst[i..i + SIMD_LANES].copy_from_slice(&r.to_array());
        }
    } else {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            for j in 0..SIMD_LANES {
                dst[i + j] = binop_f32_scalar(a[i + j], b[i + j], op);
            }
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = binop_f32_scalar(a[i], b[i], op);
    }
}

/// f32 SIMD + rayon 并行二元运算。
pub fn batch_binop_f32(dst: &mut [f32], a: &[f32], b: &[f32], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| binop_f32_kernel(d, av, bv, op));
    } else {
        binop_f32_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

// -------------------- f64 --------------------

#[inline]
fn binop_f64_scalar(a: f64, b: f64, op: BinOp) -> f64 {
    match op {
        BinOp::Add => a + b,
        BinOp::Sub => a - b,
        BinOp::Mul => a * b,
        BinOp::Div => a / b,
        BinOp::Mod => a % b,
        _ => a,
    }
}

fn binop_f64_kernel(dst: &mut [f64], a: &[f64], b: &[f64], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    let use_simd = matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div);
    if use_simd {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            let va = f64x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
            let vb = f64x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
            let r = match op {
                BinOp::Add => va + vb,
                BinOp::Sub => va - vb,
                BinOp::Mul => va * vb,
                BinOp::Div => va / vb,
                _ => unreachable!(),
            };
            dst[i..i + SIMD_LANES].copy_from_slice(&r.to_array());
        }
    } else {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            for j in 0..SIMD_LANES {
                dst[i + j] = binop_f64_scalar(a[i + j], b[i + j], op);
            }
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = binop_f64_scalar(a[i], b[i], op);
    }
}

/// f64 SIMD + rayon 并行二元运算。
pub fn batch_binop_f64(dst: &mut [f64], a: &[f64], b: &[f64], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| binop_f64_kernel(d, av, bv, op));
    } else {
        binop_f64_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

// -------------------- i32 --------------------

#[inline]
fn binop_i32_scalar(a: i32, b: i32, op: BinOp) -> i32 {
    match op {
        BinOp::Add => a.wrapping_add(b),
        BinOp::Sub => a.wrapping_sub(b),
        BinOp::Mul => a.wrapping_mul(b),
        // 整数除零直接 panic（不回退）
        BinOp::Div => a / b,
        BinOp::Mod => a % b,
        BinOp::Band => a & b,
        BinOp::Bor => a | b,
        BinOp::Bxor => a ^ b,
        BinOp::Shl => a.wrapping_shl(b as u32),
        BinOp::Shr => a.wrapping_shr(b as u32),
    }
}

fn binop_i32_kernel(dst: &mut [i32], a: &[i32], b: &[i32], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    // i32x4 支持算术 + 位运算（均 wrapping，与泛型语义一致）；
    // Div/Mod（无 SIMD 整数除法、且需除零保护）与 Shl/Shr（逐 lane 变长移位
    // 不支持）回退标量。
    let use_simd = matches!(
        op,
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Band | BinOp::Bor | BinOp::Bxor
    );
    if use_simd {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            let va = i32x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
            let vb = i32x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
            let r = match op {
                BinOp::Add => va + vb,
                BinOp::Sub => va - vb,
                BinOp::Mul => va * vb,
                BinOp::Band => va & vb,
                BinOp::Bor => va | vb,
                BinOp::Bxor => va ^ vb,
                _ => unreachable!(),
            };
            dst[i..i + SIMD_LANES].copy_from_slice(&r.to_array());
        }
    } else {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            for j in 0..SIMD_LANES {
                dst[i + j] = binop_i32_scalar(a[i + j], b[i + j], op);
            }
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = binop_i32_scalar(a[i], b[i], op);
    }
}

/// i32 SIMD + rayon 并行二元运算。
pub fn batch_binop_i32(dst: &mut [i32], a: &[i32], b: &[i32], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| binop_i32_kernel(d, av, bv, op));
    } else {
        binop_i32_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

// -------------------- i64 --------------------

#[inline]
fn binop_i64_scalar(a: i64, b: i64, op: BinOp) -> i64 {
    match op {
        BinOp::Add => a.wrapping_add(b),
        BinOp::Sub => a.wrapping_sub(b),
        BinOp::Mul => a.wrapping_mul(b),
        BinOp::Div => a / b,
        BinOp::Mod => a % b,
        BinOp::Band => a & b,
        BinOp::Bor => a | b,
        BinOp::Bxor => a ^ b,
        BinOp::Shl => a.wrapping_shl(b as u32),
        BinOp::Shr => a.wrapping_shr(b as u32),
    }
}

fn binop_i64_kernel(dst: &mut [i64], a: &[i64], b: &[i64], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    let use_simd = matches!(
        op,
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Band | BinOp::Bor | BinOp::Bxor
    );
    if use_simd {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            let va = i64x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
            let vb = i64x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
            let r = match op {
                BinOp::Add => va + vb,
                BinOp::Sub => va - vb,
                BinOp::Mul => va * vb,
                BinOp::Band => va & vb,
                BinOp::Bor => va | vb,
                BinOp::Bxor => va ^ vb,
                _ => unreachable!(),
            };
            dst[i..i + SIMD_LANES].copy_from_slice(&r.to_array());
        }
    } else {
        for blk in 0..blocks {
            let i = blk * SIMD_LANES;
            for j in 0..SIMD_LANES {
                dst[i + j] = binop_i64_scalar(a[i + j], b[i + j], op);
            }
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = binop_i64_scalar(a[i], b[i], op);
    }
}

/// i64 SIMD + rayon 并行二元运算。
pub fn batch_binop_i64(dst: &mut [i64], a: &[i64], b: &[i64], op: BinOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| binop_i64_kernel(d, av, bv, op));
    } else {
        binop_i64_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

// -------------------- 比较 f32 / f64 --------------------

fn cmp_f32_kernel(dst: &mut [u8], a: &[f32], b: &[f32], op: CmpOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    for blk in 0..blocks {
        let i = blk * SIMD_LANES;
        let va = f32x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
        let vb = f32x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
        // wide 浮点比较返回 mask：true 为全 1 位（f32 表现为 NaN），
        // false 为 0.0。用 to_bits() != 0 判定。
        let m = match op {
            CmpOp::Lt => va.cmp_lt(vb),
            CmpOp::Gt => va.cmp_gt(vb),
            CmpOp::Eq => va.cmp_eq(vb),
            CmpOp::Ne => va.cmp_ne(vb),
            CmpOp::Le => va.cmp_le(vb),
            CmpOp::Ge => va.cmp_ge(vb),
        };
        let arr = m.to_array();
        for j in 0..SIMD_LANES {
            dst[i + j] = (arr[j].to_bits() != 0) as u8;
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = cmp_scalar_t(&a[i], &b[i], op) as u8;
    }
}

/// f32 SIMD + rayon 并行比较（输出 u8 掩码）。
pub fn batch_cmp_f32(dst: &mut [u8], a: &[f32], b: &[f32], op: CmpOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| cmp_f32_kernel(d, av, bv, op));
    } else {
        cmp_f32_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

fn cmp_f64_kernel(dst: &mut [u8], a: &[f64], b: &[f64], op: CmpOp) {
    let n = dst.len().min(a.len()).min(b.len());
    let blocks = n / SIMD_LANES;
    for blk in 0..blocks {
        let i = blk * SIMD_LANES;
        let va = f64x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
        let vb = f64x4::new(b[i..i + SIMD_LANES].try_into().unwrap());
        let m = match op {
            CmpOp::Lt => va.cmp_lt(vb),
            CmpOp::Gt => va.cmp_gt(vb),
            CmpOp::Eq => va.cmp_eq(vb),
            CmpOp::Ne => va.cmp_ne(vb),
            CmpOp::Le => va.cmp_le(vb),
            CmpOp::Ge => va.cmp_ge(vb),
        };
        let arr = m.to_array();
        for j in 0..SIMD_LANES {
            dst[i + j] = (arr[j].to_bits() != 0) as u8;
        }
    }
    let tail = blocks * SIMD_LANES;
    for i in tail..n {
        dst[i] = cmp_scalar_t(&a[i], &b[i], op) as u8;
    }
}

/// f64 SIMD + rayon 并行比较（输出 u8 掩码）。
pub fn batch_cmp_f64(dst: &mut [u8], a: &[f64], b: &[f64], op: CmpOp) {
    let n = dst.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    if n > PARALLEL_THRESHOLD {
        let chunk = par_chunk_size(n);
        dst[..n]
            .par_chunks_mut(chunk)
            .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
            .for_each(|(d, (av, bv))| cmp_f64_kernel(d, av, bv, op));
    } else {
        cmp_f64_kernel(&mut dst[..n], &a[..n], &b[..n], op);
    }
}

// =========================================================================
// SIMD 补全：i8/i16/u8/u16/u32/u64 binop + cmp，以及 i32/i64 cmp
// 每类型用 wide 原生 lane 数（i8x16=16, i16x8=8, i32x4=4, i64x4=4,
// u8x16=16, u16x8=8, u32x4=4, u64x4=4），最大化 SIMD 利用率。
// =========================================================================

/// 通用整数 SIMD binop kernel 生成宏（含乘法）
/// 支持 add/sub/mul/and/or/xor 的 SIMD 加速；div/mod/shl/shr 回退标量。
macro_rules! impl_simd_int_binop {
    ($ty:ty, $vec:ty, $lanes:expr, $scalar_fn:ident) => {
        #[inline]
        fn $scalar_fn(a: $ty, b: $ty, op: BinOp) -> $ty {
            match op {
                BinOp::Add => a.wrapping_add(b),
                BinOp::Sub => a.wrapping_sub(b),
                BinOp::Mul => a.wrapping_mul(b),
                BinOp::Div => a / b,
                BinOp::Mod => a % b,
                BinOp::Band => a & b,
                BinOp::Bor => a | b,
                BinOp::Bxor => a ^ b,
                BinOp::Shl => a.wrapping_shl(b as u32),
                BinOp::Shr => a.wrapping_shr(b as u32),
            }
        }

        paste! {
            #[inline]
            fn [<binop_ $ty _kernel>](dst: &mut [$ty], a: &[$ty], b: &[$ty], op: BinOp) {
                let n = dst.len().min(a.len()).min(b.len());
                let blocks = n / $lanes;
                let use_simd = matches!(
                    op,
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Band | BinOp::Bor | BinOp::Bxor
                );
                if use_simd {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        let va = <$vec>::new(a[i..i + $lanes].try_into().unwrap());
                        let vb = <$vec>::new(b[i..i + $lanes].try_into().unwrap());
                        let r = match op {
                            BinOp::Add => va + vb,
                            BinOp::Sub => va - vb,
                            BinOp::Mul => va * vb,
                            BinOp::Band => va & vb,
                            BinOp::Bor => va | vb,
                            BinOp::Bxor => va ^ vb,
                            _ => unreachable!(),
                        };
                        dst[i..i + $lanes].copy_from_slice(&r.to_array());
                    }
                } else {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        for j in 0..$lanes {
                            dst[i + j] = $scalar_fn(a[i + j], b[i + j], op);
                        }
                    }
                }
                let tail = blocks * $lanes;
                for i in tail..n {
                    dst[i] = $scalar_fn(a[i], b[i], op);
                }
            }

            pub fn [<batch_binop_ $ty>](dst: &mut [$ty], a: &[$ty], b: &[$ty], op: BinOp) {
                let n = dst.len().min(a.len()).min(b.len());
                if n == 0 { return; }
                if n > PARALLEL_THRESHOLD {
                    let chunk = par_chunk_size(n);
                    dst[..n]
                        .par_chunks_mut(chunk)
                        .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
                        .for_each(|(d, (av, bv))| [<binop_ $ty _kernel>](d, av, bv, op));
                } else {
                    [<binop_ $ty _kernel>](&mut dst[..n], &a[..n], &b[..n], op);
                }
            }
        }
    };
}

/// i8/u8 专用宏：无 SIMD 乘法（8 位乘法无硬件支持），其余运算同上
macro_rules! impl_simd_int_binop_no_mul {
    ($ty:ty, $vec:ty, $lanes:expr, $scalar_fn:ident) => {
        #[inline]
        fn $scalar_fn(a: $ty, b: $ty, op: BinOp) -> $ty {
            match op {
                BinOp::Add => a.wrapping_add(b),
                BinOp::Sub => a.wrapping_sub(b),
                BinOp::Mul => a.wrapping_mul(b),
                BinOp::Div => a / b,
                BinOp::Mod => a % b,
                BinOp::Band => a & b,
                BinOp::Bor => a | b,
                BinOp::Bxor => a ^ b,
                BinOp::Shl => a.wrapping_shl(b as u32),
                BinOp::Shr => a.wrapping_shr(b as u32),
            }
        }

        paste! {
            #[inline]
            fn [<binop_ $ty _kernel>](dst: &mut [$ty], a: &[$ty], b: &[$ty], op: BinOp) {
                let n = dst.len().min(a.len()).min(b.len());
                let blocks = n / $lanes;
                let use_simd = matches!(
                    op,
                    BinOp::Add | BinOp::Sub | BinOp::Band | BinOp::Bor | BinOp::Bxor
                );
                if use_simd {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        let va = <$vec>::new(a[i..i + $lanes].try_into().unwrap());
                        let vb = <$vec>::new(b[i..i + $lanes].try_into().unwrap());
                        let r = match op {
                            BinOp::Add => va + vb,
                            BinOp::Sub => va - vb,
                            BinOp::Band => va & vb,
                            BinOp::Bor => va | vb,
                            BinOp::Bxor => va ^ vb,
                            _ => unreachable!(),
                        };
                        dst[i..i + $lanes].copy_from_slice(&r.to_array());
                    }
                } else {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        for j in 0..$lanes {
                            dst[i + j] = $scalar_fn(a[i + j], b[i + j], op);
                        }
                    }
                }
                let tail = blocks * $lanes;
                for i in tail..n {
                    dst[i] = $scalar_fn(a[i], b[i], op);
                }
            }

            pub fn [<batch_binop_ $ty>](dst: &mut [$ty], a: &[$ty], b: &[$ty], op: BinOp) {
                let n = dst.len().min(a.len()).min(b.len());
                if n == 0 { return; }
                if n > PARALLEL_THRESHOLD {
                    let chunk = par_chunk_size(n);
                    dst[..n]
                        .par_chunks_mut(chunk)
                        .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
                        .for_each(|(d, (av, bv))| [<binop_ $ty _kernel>](d, av, bv, op));
                } else {
                    [<binop_ $ty _kernel>](&mut dst[..n], &a[..n], &b[..n], op);
                }
            }
        }
    };
}

// i8/u8 无 SIMD 乘法（8 位乘法无硬件支持），其余整数类型有
impl_simd_int_binop_no_mul!(i8, i8x16, 16, binop_i8_scalar);
impl_simd_int_binop!(i16, i16x8, 8, binop_i16_scalar);
impl_simd_int_binop_no_mul!(u8, u8x16, 16, binop_u8_scalar);
impl_simd_int_binop!(u16, u16x8, 8, binop_u16_scalar);
impl_simd_int_binop!(u32, u32x4, 4, binop_u32_scalar);
impl_simd_int_binop!(u64, u64x4, 4, binop_u64_scalar);

// -------------------- 有符号整数 SIMD cmp（i8/i16/i32/i64）--------------------
// wide 对有符号整数提供 CmpEq/CmpLt/CmpGt，其余组合：Ne=!Eq, Le=Lt|Eq, Ge=Gt|Eq

/// 有符号整数 SIMD cmp kernel 生成宏
macro_rules! impl_simd_signed_cmp {
    ($ty:ty, $vec:ty, $lanes:expr) => {
        paste! {
            #[inline]
            fn [<cmp_ $ty _kernel>](dst: &mut [u8], a: &[$ty], b: &[$ty], op: CmpOp) {
                let n = dst.len().min(a.len()).min(b.len());
                let blocks = n / $lanes;
                for blk in 0..blocks {
                    let i = blk * $lanes;
                    let va = <$vec>::new(a[i..i + $lanes].try_into().unwrap());
                    let vb = <$vec>::new(b[i..i + $lanes].try_into().unwrap());
                    // wide 有符号整数比较返回同类型 mask（全 1/0），转 bool
                    let arr = match op {
                        CmpOp::Eq => CmpEq::cmp_eq(va, vb).to_array(),
                        CmpOp::Ne => {
                            let m = CmpEq::cmp_eq(va, vb);
                            (!m).to_array()
                        }
                        CmpOp::Lt => CmpLt::cmp_lt(va, vb).to_array(),
                        CmpOp::Gt => CmpGt::cmp_gt(va, vb).to_array(),
                        CmpOp::Le => {
                            let lt = CmpLt::cmp_lt(va, vb);
                            let eq = CmpEq::cmp_eq(va, vb);
                            (lt | eq).to_array()
                        }
                        CmpOp::Ge => {
                            let gt = CmpGt::cmp_gt(va, vb);
                            let eq = CmpEq::cmp_eq(va, vb);
                            (gt | eq).to_array()
                        }
                    };
                    for j in 0..$lanes {
                        dst[i + j] = (arr[j] != 0) as u8;
                    }
                }
                let tail = blocks * $lanes;
                for i in tail..n {
                    dst[i] = cmp_scalar_t(&a[i], &b[i], op) as u8;
                }
            }

            pub fn [<batch_cmp_ $ty>](dst: &mut [u8], a: &[$ty], b: &[$ty], op: CmpOp) {
                let n = dst.len().min(a.len()).min(b.len());
                if n == 0 { return; }
                if n > PARALLEL_THRESHOLD {
                    let chunk = par_chunk_size(n);
                    dst[..n]
                        .par_chunks_mut(chunk)
                        .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
                        .for_each(|(d, (av, bv))| [<cmp_ $ty _kernel>](d, av, bv, op));
                } else {
                    [<cmp_ $ty _kernel>](&mut dst[..n], &a[..n], &b[..n], op);
                }
            }
        }
    };
}

impl_simd_signed_cmp!(i8, i8x16, 16);
impl_simd_signed_cmp!(i16, i16x8, 8);
impl_simd_signed_cmp!(i32, i32x4, 4);
impl_simd_signed_cmp!(i64, i64x4, 4);

// -------------------- 无符号整数 SIMD cmp（u8/u16/u32/u64）--------------------
// wide 对无符号整数仅提供 CmpEq，其余比较回退标量（无 SIMD 无符号比较指令）

/// 无符号整数 SIMD cmp kernel 生成宏：仅 Eq/Ne 走 SIMD，其余标量
macro_rules! impl_simd_unsigned_cmp {
    ($ty:ty, $vec:ty, $lanes:expr) => {
        paste! {
            #[inline]
            fn [<cmp_ $ty _kernel>](dst: &mut [u8], a: &[$ty], b: &[$ty], op: CmpOp) {
                let n = dst.len().min(a.len()).min(b.len());
                let blocks = n / $lanes;
                let use_simd = matches!(op, CmpOp::Eq | CmpOp::Ne);
                if use_simd {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        let va = <$vec>::new(a[i..i + $lanes].try_into().unwrap());
                        let vb = <$vec>::new(b[i..i + $lanes].try_into().unwrap());
                        let arr = match op {
                            CmpOp::Eq => CmpEq::cmp_eq(va, vb).to_array(),
                            CmpOp::Ne => {
                                let m = CmpEq::cmp_eq(va, vb);
                                (!m).to_array()
                            }
                            _ => unreachable!(),
                        };
                        for j in 0..$lanes {
                            dst[i + j] = (arr[j] != 0) as u8;
                        }
                    }
                } else {
                    for blk in 0..blocks {
                        let i = blk * $lanes;
                        for j in 0..$lanes {
                            dst[i + j] = cmp_scalar_t(&a[i + j], &b[i + j], op) as u8;
                        }
                    }
                }
                let tail = blocks * $lanes;
                for i in tail..n {
                    dst[i] = cmp_scalar_t(&a[i], &b[i], op) as u8;
                }
            }

            pub fn [<batch_cmp_ $ty>](dst: &mut [u8], a: &[$ty], b: &[$ty], op: CmpOp) {
                let n = dst.len().min(a.len()).min(b.len());
                if n == 0 { return; }
                if n > PARALLEL_THRESHOLD {
                    let chunk = par_chunk_size(n);
                    dst[..n]
                        .par_chunks_mut(chunk)
                        .zip(a[..n].par_chunks(chunk).zip(b[..n].par_chunks(chunk)))
                        .for_each(|(d, (av, bv))| [<cmp_ $ty _kernel>](d, av, bv, op));
                } else {
                    [<cmp_ $ty _kernel>](&mut dst[..n], &a[..n], &b[..n], op);
                }
            }
        }
    };
}

impl_simd_unsigned_cmp!(u8, u8x16, 16);
impl_simd_unsigned_cmp!(u16, u16x8, 8);
impl_simd_unsigned_cmp!(u32, u32x4, 4);
impl_simd_unsigned_cmp!(u64, u64x4, 4);

// -------------------- 归约 f32 / f64 --------------------

fn reduce_add_f32_seq(a: &[f32]) -> f32 {
    let n = a.len();
    if n == 0 {
        return 0.0;
    }
    let blocks = n / SIMD_LANES;
    let mut acc = f32x4::splat(0.0);
    for blk in 0..blocks {
        let i = blk * SIMD_LANES;
        acc += f32x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
    }
    let mut sum = acc.reduce_add();
    for &v in a.iter().skip(blocks * SIMD_LANES) {
        sum += v;
    }
    sum
}

/// f32 归约：Add 走 SIMD（+ rayon 并行），Mul 走标量，位运算对 f32 无意义。
pub fn batch_reduce_f32(a: &[f32], op: ReduceOp) -> f32 {
    if a.is_empty() {
        return 0.0;
    }
    match op {
        ReduceOp::Add => {
            let n = a.len();
            if n > PARALLEL_THRESHOLD {
                let chunk = par_chunk_size(n);
                let partials: Vec<f32> =
                    a.par_chunks(chunk).map(reduce_add_f32_seq).collect();
                partials.iter().copied().fold(0.0, |x, y| x + y)
            } else {
                reduce_add_f32_seq(a)
            }
        }
        _ => {
            let mut acc = a[0];
            for &v in &a[1..] {
                acc = match op {
                    ReduceOp::Mul => acc * v,
                    _ => acc,
                };
            }
            acc
        }
    }
}

fn reduce_add_f64_seq(a: &[f64]) -> f64 {
    let n = a.len();
    if n == 0 {
        return 0.0;
    }
    let blocks = n / SIMD_LANES;
    let mut acc = f64x4::splat(0.0);
    for blk in 0..blocks {
        let i = blk * SIMD_LANES;
        acc += f64x4::new(a[i..i + SIMD_LANES].try_into().unwrap());
    }
    let mut sum = acc.reduce_add();
    for &v in a.iter().skip(blocks * SIMD_LANES) {
        sum += v;
    }
    sum
}

/// f64 归约：Add 走 SIMD（+ rayon 并行），Mul 走标量。
pub fn batch_reduce_f64(a: &[f64], op: ReduceOp) -> f64 {
    if a.is_empty() {
        return 0.0;
    }
    match op {
        ReduceOp::Add => {
            let n = a.len();
            if n > PARALLEL_THRESHOLD {
                let chunk = par_chunk_size(n);
                let partials: Vec<f64> =
                    a.par_chunks(chunk).map(reduce_add_f64_seq).collect();
                partials.iter().copied().fold(0.0, |x, y| x + y)
            } else {
                reduce_add_f64_seq(a)
            }
        }
        _ => {
            let mut acc = a[0];
            for &v in &a[1..] {
                acc = match op {
                    ReduceOp::Mul => acc * v,
                    _ => acc,
                };
            }
            acc
        }
    }
}

// =========================================================================
// 第十四部分：allocator.rs
// =========================================================================

/// 内存分配器 trait
pub trait Allocator: Clone {
    fn alloc_str(&self, s: &str) -> Arc<str>;
    fn alloc_array(&self, vals: Vec<ValueHandle>) -> Arc<Vec<ValueHandle>>;
    fn alloc_value(&self, val: ValueHandle) -> ValueHandle {
        val
    }
}

/// 默认分配器
#[derive(Debug, Clone, Default)]
pub struct DefaultAllocator;

impl Allocator for DefaultAllocator {
    fn alloc_str(&self, s: &str) -> Arc<str> {
        Arc::from(s)
    }
    fn alloc_array(&self, vals: Vec<ValueHandle>) -> Arc<Vec<ValueHandle>> {
        Arc::new(vals)
    }
}

pub fn default_allocator() -> DefaultAllocator {
    DefaultAllocator
}

// =========================================================================
// 第十五部分：纯算术核心 — 无 Frame 依赖，runtime compute_fn 与编译期 ConstFold 共用
// =========================================================================
//
// 为所有整数/浮点类型生成纯算术函数，语义与 Engine.rs 的 compute_fn 宏严格一致：
//   - 整数 add/sub/mul: wrapping 语义
//   - 整数 div/mod: checked，除零返回 0
//   - 整数 shl/shr: 移位量为 i32（与 Engine.rs 读取 as_i32 一致），cast u32 后 wrapping
//   - 浮点 div: 原生除法（除零产生 inf/nan）
// runtime compute_fn 调用这些纯函数（复用），编译期 ConstFold 也调用同一份算术（解耦 Frame）。

/// 为指定整数类型生成全套纯算术函数（add/sub/mul/div/mod/bitand/bitor/bitxor/shl/shr/neg/bitnot）。
/// shl/shr 的移位量参数为 i32（与 Engine.rs compute_shl_*/compute_shr_* 读取 as_i32 一致）。
macro_rules! impl_arith_int {
    ($ty:ident, $rust:ty) => {
        paste! {
            #[inline] pub fn [<arith_add_$ty>](a: $rust, b: $rust) -> $rust { a.wrapping_add(b) }
            #[inline] pub fn [<arith_sub_$ty>](a: $rust, b: $rust) -> $rust { a.wrapping_sub(b) }
            #[inline] pub fn [<arith_mul_$ty>](a: $rust, b: $rust) -> $rust { a.wrapping_mul(b) }
            #[inline] pub fn [<arith_div_$ty>](a: $rust, b: $rust) -> $rust { a / b }
            #[inline] pub fn [<arith_mod_$ty>](a: $rust, b: $rust) -> $rust { a % b }
            #[inline] pub fn [<arith_bitand_$ty>](a: $rust, b: $rust) -> $rust { a & b }
            #[inline] pub fn [<arith_bitor_$ty>](a: $rust, b: $rust) -> $rust { a | b }
            #[inline] pub fn [<arith_bitxor_$ty>](a: $rust, b: $rust) -> $rust { a ^ b }
            #[inline] pub fn [<arith_shl_$ty>](a: $rust, shift: i32) -> $rust { a.wrapping_shl(shift as u32) }
            #[inline] pub fn [<arith_shr_$ty>](a: $rust, shift: i32) -> $rust { a.wrapping_shr(shift as u32) }
            #[inline] pub fn [<arith_neg_$ty>](a: $rust) -> $rust { a.wrapping_neg() }
            #[inline] pub fn [<arith_bitnot_$ty>](a: $rust) -> $rust { !a }
        }
    };
}

/// 为指定浮点类型生成全套纯算术函数（add/sub/mul/div/mod/neg）。
macro_rules! impl_arith_float {
    ($ty:ident, $rust:ty) => {
        paste! {
            #[inline] pub fn [<arith_add_$ty>](a: $rust, b: $rust) -> $rust { a + b }
            #[inline] pub fn [<arith_sub_$ty>](a: $rust, b: $rust) -> $rust { a - b }
            #[inline] pub fn [<arith_mul_$ty>](a: $rust, b: $rust) -> $rust { a * b }
            #[inline] pub fn [<arith_div_$ty>](a: $rust, b: $rust) -> $rust { a / b }
            #[inline] pub fn [<arith_mod_$ty>](a: $rust, b: $rust) -> $rust { a % b }
            #[inline] pub fn [<arith_neg_$ty>](a: $rust) -> $rust { -a }
        }
    };
}

// 整数类型展开（12 类型 × 12 运算）
impl_arith_int!(i8,    i8);
impl_arith_int!(i16,   i16);
impl_arith_int!(i32,   i32);
impl_arith_int!(i64,   i64);
impl_arith_int!(i128,  i128);
impl_arith_int!(u8,    u8);
impl_arith_int!(u16,   u16);
impl_arith_int!(u32,   u32);
impl_arith_int!(u64,   u64);
impl_arith_int!(u128,  u128);
impl_arith_int!(isize, isize);
impl_arith_int!(usize, usize);

// 浮点类型展开（4 类型 × 6 运算）
impl_arith_float!(f16, F16);
impl_arith_float!(f32, f32);
impl_arith_float!(f64, f64);
impl_arith_float!(f128, F128);

// =========================================================================
// 布尔纯算术 — 与 Engine.rs compute_and_bool/or/not 语义一致
// =========================================================================

#[inline] pub fn arith_and_bool(a: bool, b: bool) -> bool { a && b }
#[inline] pub fn arith_or_bool(a: bool, b: bool) -> bool { a || b }
#[inline] pub fn arith_not_bool(a: bool) -> bool { !a }