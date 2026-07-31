//! Value.rs — Glue 统一值系统（合并 14 个子模块）

use std::cell::RefCell;
use std::cmp::Ordering;
use rustc_hash::FxHashMap;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::Mutex;

use rayon::prelude::*;
use wide::{f32x4, f64x4, i32x4, i64x4, CmpEq, CmpGe, CmpGt, CmpLe, CmpLt, CmpNe};

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
        let mant = bits & 0xFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant != 0
    }
    pub fn is_infinite(self) -> bool {
        let bits = u128::from_le_bytes(self.0);
        let exp = (bits >> 112) & 0x7FFF;
        let mant = bits & 0xFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant == 0
    }
    pub fn to_bits(self) -> [u8; 16] {
        self.0
    }
    pub fn from_bits(b: [u8; 16]) -> Self {
        F128(b)
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

// ---- ValueTag — 18 种标量类型标签 ----

/// 标量类型标签：涵盖布尔、字符、整数与浮点共 18 种
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ValueTag {
    Null = 0,
    Void = 1,
    Bool = 2,
    Char = 3,
    I8 = 4,
    I16 = 5,
    I32 = 6,
    I64 = 7,
    U8 = 8,
    U16 = 9,
    U32 = 10,
    U64 = 11,
    Isize = 12,
    Usize = 13,
    I128 = 14,
    U128 = 15,
    F16 = 16,
    F32 = 17,
    F64 = 18,
    F128 = 19,
    Ref = 20,
}

impl ValueTag {
    pub fn is_scalar(self) -> bool {
        !matches!(self, ValueTag::Null | ValueTag::Void | ValueTag::Ref)
    }
}

impl ValueTag {
    pub fn byte_width(self) -> usize {
        match self {
            ValueTag::Bool | ValueTag::I8 | ValueTag::U8 => 1,
            ValueTag::I16 | ValueTag::U16 | ValueTag::F16 => 2,
            ValueTag::Char | ValueTag::I32 | ValueTag::U32 | ValueTag::F32 => 4,
            ValueTag::I64 | ValueTag::U64 | ValueTag::Isize | ValueTag::Usize | ValueTag::F64 => 8,
            ValueTag::I128 | ValueTag::U128 | ValueTag::F128 => 16,
            _ => 0,
        }
    }

    pub fn is_int(self) -> bool {
        matches!(
            self,
            ValueTag::I8 | ValueTag::I16 | ValueTag::I32 | ValueTag::I64 | ValueTag::I128
                | ValueTag::U8 | ValueTag::U16 | ValueTag::U32 | ValueTag::U64 | ValueTag::U128
                | ValueTag::Isize | ValueTag::Usize
        )
    }

    pub fn is_float(self) -> bool {
        matches!(self, ValueTag::F16 | ValueTag::F32 | ValueTag::F64 | ValueTag::F128)
    }

    pub fn is_signed(self) -> bool {
        matches!(
            self,
            ValueTag::I8 | ValueTag::I16 | ValueTag::I32 | ValueTag::I64 | ValueTag::I128 | ValueTag::Isize
        )
    }

    pub fn is_bool(self) -> bool {
        matches!(self, ValueTag::Bool)
    }

    pub fn is_char(self) -> bool {
        matches!(self, ValueTag::Char)
    }

    pub fn is_numeric(self) -> bool {
        self.is_int() || self.is_float()
    }

    pub fn name(self) -> &'static str {
        match self {
            ValueTag::Bool => "bool",
            ValueTag::Char => "char",
            ValueTag::I8 => "i8",
            ValueTag::I16 => "i16",
            ValueTag::I32 => "i32",
            ValueTag::I64 => "i64",
            ValueTag::I128 => "i128",
            ValueTag::U8 => "u8",
            ValueTag::U16 => "u16",
            ValueTag::U32 => "u32",
            ValueTag::U64 => "u64",
            ValueTag::U128 => "u128",
            ValueTag::Isize => "isize",
            ValueTag::Usize => "usize",
            ValueTag::F16 => "f16",
            ValueTag::F32 => "f32",
            ValueTag::F64 => "f64",
            ValueTag::F128 => "f128",
            _ => "unknown",
        }
    }

    pub fn all() -> &'static [ValueTag] {
        &[
            ValueTag::Bool, ValueTag::Char, ValueTag::I8, ValueTag::I16, ValueTag::I32,
            ValueTag::I64, ValueTag::I128, ValueTag::U8, ValueTag::U16, ValueTag::U32,
            ValueTag::U64, ValueTag::U128, ValueTag::Isize, ValueTag::Usize, ValueTag::F16,
            ValueTag::F32, ValueTag::F64, ValueTag::F128,
        ]
    }

    pub fn from_name(name: &str) -> Option<ValueTag> {
        for tag in Self::all() {
            if tag.name() == name {
                return Some(*tag);
            }
        }
        None
    }
}

// ---- ScalarTag — 标量类型标签（18 种，用于 ScalarValue union 类型守卫）----

/// 标量类型标签（18 种，用于 ScalarValue union 的类型守卫）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ScalarTag {
    Bool, Char,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Isize, Usize,
    F16, F32, F64, F128,
}

// ---- ScalarValue — 标量值 union（16 字节）----

/// 标量值 union（16 字节，容纳 i128/u128/F128）。
/// 通过 ScalarTag 类型守卫访问，unsafe 代码必须有对应 tag 检查。
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
    Scalar(ScalarValue, ScalarTag),
    Ref(Arc<HeapObj>),
}

unsafe impl Send for Value {}
unsafe impl Sync for Value {}

impl Value {
    // ---- 标量构造器 ----
    pub fn i32(v: i32) -> Self { Value::Scalar(ScalarValue { i32_val: v }, ScalarTag::I32) }
    pub fn i64(v: i64) -> Self { Value::Scalar(ScalarValue { i64_val: v }, ScalarTag::I64) }
    pub fn f64(v: f64) -> Self { Value::Scalar(ScalarValue { f64_val: v }, ScalarTag::F64) }
    pub fn f32(v: f32) -> Self { Value::Scalar(ScalarValue { f32_val: v }, ScalarTag::F32) }
    pub fn bool_val(v: bool) -> Self { Value::Scalar(ScalarValue { bool_val: v }, ScalarTag::Bool) }
    pub fn char_val(v: char) -> Self { Value::Scalar(ScalarValue { char_val: v as u32 }, ScalarTag::Char) }
    pub fn i8(v: i8) -> Self { Value::Scalar(ScalarValue { i8_val: v }, ScalarTag::I8) }
    pub fn i16(v: i16) -> Self { Value::Scalar(ScalarValue { i16_val: v }, ScalarTag::I16) }
    pub fn u8(v: u8) -> Self { Value::Scalar(ScalarValue { u8_val: v }, ScalarTag::U8) }
    pub fn u16(v: u16) -> Self { Value::Scalar(ScalarValue { u16_val: v }, ScalarTag::U16) }
    pub fn u32(v: u32) -> Self { Value::Scalar(ScalarValue { u32_val: v }, ScalarTag::U32) }
    pub fn u64(v: u64) -> Self { Value::Scalar(ScalarValue { u64_val: v }, ScalarTag::U64) }
    pub fn isize_val(v: isize) -> Self { Value::Scalar(ScalarValue { isize_val: v }, ScalarTag::Isize) }
    pub fn usize_val(v: usize) -> Self { Value::Scalar(ScalarValue { usize_val: v }, ScalarTag::Usize) }
    pub fn f16(v: F16) -> Self { Value::Scalar(ScalarValue { f16_val: v.0 }, ScalarTag::F16) }
    // 128 位标量构造器（bit pattern 存为 [u64; 2]）
    pub fn i128(v: i128) -> Self {
        let bits = v as u128;
        Value::Scalar(ScalarValue { i128_val: [(bits & 0xFFFF_FFFF_FFFF_FFFF) as u64, (bits >> 64) as u64] }, ScalarTag::I128)
    }
    pub fn u128(v: u128) -> Self {
        Value::Scalar(ScalarValue { u128_val: [(v & 0xFFFF_FFFF_FFFF_FFFF) as u64, (v >> 64) as u64] }, ScalarTag::U128)
    }
    pub fn f128(v: F128) -> Self {
        Value::Scalar(ScalarValue { f128_val: unsafe { std::mem::transmute(v.0) } }, ScalarTag::F128)
    }

    // ---- 堆对象构造器 ----
    pub fn ref_val(obj: HeapObj) -> Self { Value::Ref(Arc::new(obj)) }
    pub fn from_ref(r: HeapRef) -> Self { Value::Ref(r) }

    pub const NULL: Value = Value::Null;
    pub const VOID: Value = Value::Void;

    // ---- 标量访问器（带 tag 守卫，类型不匹配返回零值）----
    pub fn as_i32(&self) -> i32 { match self { Value::Scalar(v, ScalarTag::I32) => unsafe { v.i32_val }, _ => 0 } }
    pub fn as_i64(&self) -> i64 { match self { Value::Scalar(v, ScalarTag::I64) => unsafe { v.i64_val }, _ => 0 } }
    pub fn as_f64(&self) -> f64 { match self { Value::Scalar(v, ScalarTag::F64) => unsafe { v.f64_val }, _ => 0.0 } }
    pub fn as_f32(&self) -> f32 { match self { Value::Scalar(v, ScalarTag::F32) => unsafe { v.f32_val }, _ => 0.0 } }
    pub fn as_bool(&self) -> bool { match self { Value::Scalar(v, ScalarTag::Bool) => unsafe { v.bool_val }, _ => false } }
    pub fn as_char(&self) -> char { match self { Value::Scalar(v, ScalarTag::Char) => unsafe { char::from_u32_unchecked(v.char_val) }, _ => '\0' } }
    pub fn as_i8(&self) -> i8 { match self { Value::Scalar(v, ScalarTag::I8) => unsafe { v.i8_val }, _ => 0 } }
    pub fn as_i16(&self) -> i16 { match self { Value::Scalar(v, ScalarTag::I16) => unsafe { v.i16_val }, _ => 0 } }
    pub fn as_u8(&self) -> u8 { match self { Value::Scalar(v, ScalarTag::U8) => unsafe { v.u8_val }, _ => 0 } }
    pub fn as_u16(&self) -> u16 { match self { Value::Scalar(v, ScalarTag::U16) => unsafe { v.u16_val }, _ => 0 } }
    pub fn as_u32(&self) -> u32 { match self { Value::Scalar(v, ScalarTag::U32) => unsafe { v.u32_val }, _ => 0 } }
    pub fn as_u64(&self) -> u64 { match self { Value::Scalar(v, ScalarTag::U64) => unsafe { v.u64_val }, _ => 0 } }
    pub fn as_isize(&self) -> isize { match self { Value::Scalar(v, ScalarTag::Isize) => unsafe { v.isize_val }, _ => 0 } }
    pub fn as_usize(&self) -> usize { match self { Value::Scalar(v, ScalarTag::Usize) => unsafe { v.usize_val }, _ => 0 } }
    pub fn as_i128(&self) -> i128 { match self { Value::Scalar(v, ScalarTag::I128) => unsafe { i128::from_ne_bytes(std::mem::transmute(v.i128_val)) }, _ => 0 } }
    pub fn as_u128(&self) -> u128 { match self { Value::Scalar(v, ScalarTag::U128) => unsafe { u128::from_ne_bytes(std::mem::transmute(v.u128_val)) }, _ => 0 } }
    pub fn as_f16(&self) -> F16 { match self { Value::Scalar(v, ScalarTag::F16) => F16(unsafe { v.f16_val }), _ => F16(0) } }
    pub fn as_f128(&self) -> F128 { match self { Value::Scalar(v, ScalarTag::F128) => F128(unsafe { std::mem::transmute(v.f128_val) }), _ => F128([0u8; 16]) } }

    // ---- 堆对象访问器 ----
    pub fn heap_obj(&self) -> Option<&HeapObj> { match self { Value::Ref(r) => Some(r.as_ref()), _ => None } }
    pub fn heap_ref(&self) -> Option<HeapRef> { match self { Value::Ref(r) => Some(r.clone()), _ => None } }

    // ---- 判别 ----
    pub fn is_null(&self) -> bool { matches!(self, Value::Null) }
    pub fn is_void(&self) -> bool { matches!(self, Value::Void) }
    pub fn is_ref(&self) -> bool { matches!(self, Value::Ref(_)) }

    // ---- 标量 tag 访问（供 Hash/Debug/反射适配）----
    pub fn scalar_tag(&self) -> Option<ScalarTag> {
        match self { Value::Scalar(_, t) => Some(*t), _ => None }
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
                    ScalarTag::Bool => write!(f, "{}", unsafe { v.bool_val }),
                    ScalarTag::Char => write!(f, "'{}'", Char::from_codepoint_unchecked(unsafe { v.char_val })),
                    ScalarTag::I8 => write!(f, "{}i8", unsafe { v.i8_val }),
                    ScalarTag::I16 => write!(f, "{}i16", unsafe { v.i16_val }),
                    ScalarTag::I32 => write!(f, "{}", unsafe { v.i32_val }),
                    ScalarTag::I64 => write!(f, "{}i64", unsafe { v.i64_val }),
                    ScalarTag::I128 => write!(f, "{}i128", unsafe { i128::from_ne_bytes(std::mem::transmute(v.i128_val)) }),
                    ScalarTag::U8 => write!(f, "{}u8", unsafe { v.u8_val }),
                    ScalarTag::U16 => write!(f, "{}u16", unsafe { v.u16_val }),
                    ScalarTag::U32 => write!(f, "{}u32", unsafe { v.u32_val }),
                    ScalarTag::U64 => write!(f, "{}u64", unsafe { v.u64_val }),
                    ScalarTag::U128 => write!(f, "{}u128", unsafe { u128::from_ne_bytes(std::mem::transmute(v.u128_val)) }),
                    ScalarTag::Isize => write!(f, "{}isize", unsafe { v.isize_val }),
                    ScalarTag::Usize => write!(f, "{}usize", unsafe { v.usize_val }),
                    ScalarTag::F16 => write!(f, "{:?}", F16(unsafe { v.f16_val })),
                    ScalarTag::F32 => write!(f, "{}f32", unsafe { v.f32_val }),
                    ScalarTag::F64 => write!(f, "{}", unsafe { v.f64_val }),
                    ScalarTag::F128 => write!(f, "{:?}", F128(unsafe { std::mem::transmute(v.f128_val) })),
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
                    ScalarTag::Bool => unsafe { v.bool_val }.hash(state),
                    ScalarTag::Char => unsafe { v.char_val }.hash(state),
                    ScalarTag::I8 => unsafe { v.i8_val }.hash(state),
                    ScalarTag::I16 => unsafe { v.i16_val }.hash(state),
                    ScalarTag::I32 => unsafe { v.i32_val }.hash(state),
                    ScalarTag::I64 => unsafe { v.i64_val }.hash(state),
                    ScalarTag::I128 => unsafe { v.i128_val }.hash(state),
                    ScalarTag::U8 => unsafe { v.u8_val }.hash(state),
                    ScalarTag::U16 => unsafe { v.u16_val }.hash(state),
                    ScalarTag::U32 => unsafe { v.u32_val }.hash(state),
                    ScalarTag::U64 => unsafe { v.u64_val }.hash(state),
                    ScalarTag::U128 => unsafe { v.u128_val }.hash(state),
                    ScalarTag::Isize => unsafe { v.isize_val }.hash(state),
                    ScalarTag::Usize => unsafe { v.usize_val }.hash(state),
                    ScalarTag::F16 => unsafe { v.f16_val }.hash(state),
                    ScalarTag::F32 => unsafe { v.f32_val }.to_bits().hash(state),
                    ScalarTag::F64 => unsafe { v.f64_val }.to_bits().hash(state),
                    ScalarTag::F128 => unsafe { v.f128_val }.hash(state),
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
    inner: Rc<str>,
}

impl GlueStr {
    pub fn new(s: impl Into<String>) -> Self {
        Self { inner: Rc::from(s.into().as_str()) }
    }
    pub fn from_rust_str(s: &str) -> Self {
        Self { inner: Rc::from(s) }
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

/// Cell：可变引用单元
#[derive(Debug, Clone)]
pub struct Cell {
    pub inner: RefCell<ValueHandle>,
}

impl Cell {
    pub fn new(val: ValueHandle) -> Self {
        Self { inner: RefCell::new(val) }
    }
    pub fn get(&self) -> std::cell::Ref<'_, ValueHandle> {
        self.inner.borrow()
    }
    pub fn set(&self, val: ValueHandle) {
        *self.inner.borrow_mut() = val;
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

/// 偏应用值
#[derive(Debug, Clone)]
pub struct PartialApplication {
    pub func_id: u32,
    pub bound_args: Vec<ValueHandle>,
    pub remaining_arity: u8,
    pub bound_arg_ref_bits: u16,
}

/// Trait 值
#[derive(Debug, Clone)]
pub struct TraitValue {
    pub trait_name: String,
    pub method_names: Vec<String>,
    pub method_values: Vec<ValueHandle>,
    pub data: Option<ValueHandle>,
    pub owned: bool,
}

/// 惰性值
#[derive(Clone)]
pub struct LazyValue {
    pub cached: Option<ValueHandle>,
    pub forced: bool,
    pub thunk: Option<Rc<dyn Fn() -> ValueHandle>>,
}

impl fmt::Debug for LazyValue {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("LazyValue")
            .field("cached", &self.cached)
            .field("forced", &self.forced)
            .field("thunk", &self.thunk.as_ref().map(|_| "<thunk>"))
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
    Err(Rc<RecordValue>),
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
    data: Mutex<ValueHandle>,
}

impl AtomicValue {
    pub fn new(val: ValueHandle) -> Self {
        Self { data: Mutex::new(val) }
    }
    pub fn load(&self) -> ValueHandle {
        *self.data.lock().unwrap_or_else(|e| e.into_inner())
    }
    pub fn store(&self, val: ValueHandle) {
        *self.data.lock().unwrap_or_else(|e| e.into_inner()) = val;
    }
    pub fn swap(&self, val: ValueHandle) -> ValueHandle {
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

/// 通道值
#[derive(Debug)]
pub struct ChannelValue {
    buffer: Mutex<Vec<ValueHandle>>,
    capacity: usize,
    closed: Mutex<bool>,
}

impl ChannelValue {
    pub fn new(capacity: usize) -> Self {
        Self { buffer: Mutex::new(Vec::new()), capacity, closed: Mutex::new(false) }
    }
    pub fn send(&self, val: ValueHandle) -> Result<(), String> {
        let mut buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        // [V-5] 持 buffer 锁期间检查 closed，与 close（同样持 buffer 锁）互斥，消除 TOCTOU
        if *self.closed.lock().unwrap_or_else(|e| e.into_inner()) {
            return Err("channel closed".to_string());
        }
        if self.capacity > 0 && buf.len() >= self.capacity {
            return Err("channel full".to_string());
        }
        buf.push(val);
        Ok(())
    }
    pub fn recv(&self) -> Option<ValueHandle> {
        let mut buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        if !buf.is_empty() {
            Some(buf.remove(0))
        } else {
            None
        }
    }
    pub fn try_send(&self, val: ValueHandle) -> Result<(), String> {
        self.send(val)
    }
    pub fn try_recv(&self) -> Option<ValueHandle> {
        self.recv()
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
        Self { buffer: Mutex::new(buf), capacity: self.capacity, closed: Mutex::new(*self.closed.lock().unwrap_or_else(|e| e.into_inner())) }
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
    ChannelVal(ChannelValue),
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
                c.inner.borrow().hash(state);
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
                    let ptr: *const RecordValue = Rc::as_ptr(r);
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
}

/// Value 的统一存储：按类型分桶（SoA），每种标量类型独立连续存储。
/// 堆对象（HeapObj）仍用 Rc，存于 ref_bucket。
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
    /// 返回 Rc clone，避免 thread_local borrow 跨函数返回的生命周期问题。
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
                    ScalarTag::Bool => if sv.bool_val { ValueHandle::TRUE } else { ValueHandle::FALSE },
                    ScalarTag::Char => self.alloc_char(sv.char_val),
                    ScalarTag::I8 => self.alloc_i8(sv.i8_val),
                    ScalarTag::I16 => self.alloc_i16(sv.i16_val),
                    ScalarTag::I32 => self.alloc_i32(sv.i32_val),
                    ScalarTag::I64 => self.alloc_i64(sv.i64_val),
                    ScalarTag::U8 => self.alloc_u8(sv.u8_val),
                    ScalarTag::U16 => self.alloc_u16(sv.u16_val),
                    ScalarTag::U32 => self.alloc_u32(sv.u32_val),
                    ScalarTag::U64 => self.alloc_u64(sv.u64_val),
                    ScalarTag::Isize => self.alloc_isize(sv.isize_val),
                    ScalarTag::Usize => self.alloc_usize(sv.usize_val),
                    ScalarTag::I128 => self.alloc_i128(i128::from_ne_bytes(std::mem::transmute(sv.i128_val))),
                    ScalarTag::U128 => self.alloc_u128(u128::from_ne_bytes(std::mem::transmute(sv.u128_val))),
                    ScalarTag::F16 => self.alloc_f16(sv.f16_val),
                    ScalarTag::F32 => self.alloc_f32(sv.f32_val),
                    ScalarTag::F64 => self.alloc_f64(sv.f64_val),
                    ScalarTag::F128 => self.alloc_f128(F128(std::mem::transmute(sv.f128_val))),
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
    pub fn alloc_cell(&mut self, val: ValueHandle) -> ValueHandle {
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
    pub fn alloc_throw_err(&mut self, record: Rc<RecordValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    }
    pub fn alloc_atomic(&mut self, val: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::AtomicVal(AtomicValue::new(val)))
    }
    pub fn alloc_async_handle(&mut self) -> ValueHandle {
        self.alloc_ref(HeapObj::AsyncVal(AsyncHandle::new()))
    }
    pub fn alloc_channel(&mut self, capacity: usize) -> ValueHandle {
        self.alloc_ref(HeapObj::ChannelVal(ChannelValue::new(capacity)))
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
            ScalarTag::I8 => ScalarSoA::I8(arr.elements.iter().map(|h| h.as_i8()).collect()),
            ScalarTag::I16 => ScalarSoA::I16(arr.elements.iter().map(|h| h.as_i16()).collect()),
            ScalarTag::I32 => ScalarSoA::I32(arr.elements.iter().map(|h| h.as_i32()).collect()),
            ScalarTag::I64 => ScalarSoA::I64(arr.elements.iter().map(|h| h.as_i64()).collect()),
            ScalarTag::U8 => ScalarSoA::U8(arr.elements.iter().map(|h| h.as_u8()).collect()),
            ScalarTag::U16 => ScalarSoA::U16(arr.elements.iter().map(|h| h.as_u16()).collect()),
            ScalarTag::U32 => ScalarSoA::U32(arr.elements.iter().map(|h| h.as_u32()).collect()),
            ScalarTag::U64 => ScalarSoA::U64(arr.elements.iter().map(|h| h.as_u64()).collect()),
            ScalarTag::Bool => ScalarSoA::Bool(arr.elements.iter().map(|h| h.as_bool()).collect()),
            ScalarTag::Char => ScalarSoA::Char(arr.elements.iter().map(|h| h.as_char() as u32).collect()),
            ScalarTag::F32 => ScalarSoA::F32(arr.elements.iter().map(|h| h.as_f32()).collect()),
            ScalarTag::F64 => ScalarSoA::F64(arr.elements.iter().map(|h| h.as_f64()).collect()),
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
            HeapObj::ChannelVal(c) => Some(c),
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

fn heap_equals(a: &HeapObj, b: &HeapObj, arena: &ValueArena) -> bool {
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
                .all(|(p, q)| value_equals(p, q))
        }
        (HeapObj::Record(x), HeapObj::Record(y)) => {
            x.type_name == y.type_name
                && x.field_names == y.field_names
                && x.fields.len() == y.fields.len()
                && x.fields.iter().zip(&y.fields).all(|(p, q)| value_equals(p, q))
        }
        (HeapObj::Adt(x), HeapObj::Adt(y)) => {
            x.type_name == y.type_name
                && x.constructor == y.constructor
                && x.fields.len() == y.fields.len()
                && x
                    .fields
                    .iter()
                    .zip(&y.fields)
                    .all(|(xf, yf)| value_equals(&xf.value, &yf.value))
        }
        (HeapObj::Newtype(x), HeapObj::Newtype(y)) => {
            x.type_name == y.type_name && x.inner.equals(&y.inner, arena)
        }
        (HeapObj::Cell(x), HeapObj::Cell(y)) => {
            let xb = *x.inner.borrow();
            let yb = *y.inner.borrow();
            xb.equals(&yb, arena)
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
            (ThrowPayload::Ok(a), ThrowPayload::Ok(b)) => value_equals(a, b),
            (ThrowPayload::Err(a), ThrowPayload::Err(b)) => Rc::ptr_eq(a, b),
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
                    .all(|(p, q)| value_equals(p, q))
        }
        (HeapObj::Builtin(x), HeapObj::Builtin(y)) => {
            (x.fn_ptr as usize) == (y.fn_ptr as usize) && x.name == y.name
        }
        _ => std::mem::discriminant(a) == std::mem::discriminant(b),
    }
}

/// Value 语义相等（用于 HeapObj 字段比较）。
/// 标量按 tag + bit 比较；Ref 走 heap_equals 递归；Null/Void 按判别。
fn value_equals(a: &Value, b: &Value) -> bool {
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
                ScalarTag::Bool => (unsafe { av.bool_val } == unsafe { bv.bool_val }),
                ScalarTag::Char => (unsafe { av.char_val } == unsafe { bv.char_val }),
                ScalarTag::I8 => (unsafe { av.i8_val } == unsafe { bv.i8_val }),
                ScalarTag::I16 => (unsafe { av.i16_val } == unsafe { bv.i16_val }),
                ScalarTag::I32 => (unsafe { av.i32_val } == unsafe { bv.i32_val }),
                ScalarTag::I64 => (unsafe { av.i64_val } == unsafe { bv.i64_val }),
                ScalarTag::I128 => (unsafe { av.i128_val } == unsafe { bv.i128_val }),
                ScalarTag::U8 => (unsafe { av.u8_val } == unsafe { bv.u8_val }),
                ScalarTag::U16 => (unsafe { av.u16_val } == unsafe { bv.u16_val }),
                ScalarTag::U32 => (unsafe { av.u32_val } == unsafe { bv.u32_val }),
                ScalarTag::U64 => (unsafe { av.u64_val } == unsafe { bv.u64_val }),
                ScalarTag::U128 => (unsafe { av.u128_val } == unsafe { bv.u128_val }),
                ScalarTag::Isize => (unsafe { av.isize_val } == unsafe { bv.isize_val }),
                ScalarTag::Usize => (unsafe { av.usize_val } == unsafe { bv.usize_val }),
                ScalarTag::F16 => (unsafe { av.f16_val } == unsafe { bv.f16_val }),
                ScalarTag::F32 => unsafe { av.f32_val }.to_bits() == unsafe { bv.f32_val }.to_bits(),
                ScalarTag::F64 => unsafe { av.f64_val }.to_bits() == unsafe { bv.f64_val }.to_bits(),
                ScalarTag::F128 => (unsafe { av.f128_val } == unsafe { bv.f128_val }),
            }
        }
        (Value::Ref(ax), Value::Ref(bx)) => heap_equals(ax.as_ref(), bx.as_ref(), &ValueArena::default()),
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
            let inner = *c.inner.borrow();
            // Cell.inner 仍为 ValueHandle
            HeapObj::Cell(Cell::new(deep_clone_handle(inner, arena, cache)))
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
            // bound_args 仍为 ValueHandle
            let bound_args: Vec<ValueHandle> = p
                .bound_args
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Partial(PartialApplication {
                func_id: p.func_id,
                bound_args,
                remaining_arity: p.remaining_arity,
                bound_arg_ref_bits: p.bound_arg_ref_bits,
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
        // AtomicValue.data 仍为 ValueHandle
        HeapObj::AtomicVal(a) => HeapObj::AtomicVal(AtomicValue::new(deep_clone_handle(a.load(), arena, cache))),
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
    pub fn cell(&mut self, val: ValueHandle) -> ValueHandle {
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
    pub fn throw_err(&mut self, record: Rc<RecordValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(record),
        }))
    }
    pub fn atomic(&mut self, val: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::AtomicVal(AtomicValue::new(val)))
    }
    pub fn async_handle(&mut self) -> ValueHandle {
        self.alloc_ref(HeapObj::AsyncVal(AsyncHandle::new()))
    }
    pub fn channel(&mut self, capacity: usize) -> ValueHandle {
        self.alloc_ref(HeapObj::ChannelVal(ChannelValue::new(capacity)))
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
                fn shl(self, amount: u32) -> Self { self << amount }
                fn shr(self, amount: u32) -> Self { self >> amount }
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
        BinOp::Div => a.checked_div(b).unwrap_or_else(T::zero),
        BinOp::Mod => a.checked_rem(b).unwrap_or_else(T::zero),
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
        // 整数除零返回 0（与泛型 checked_div 语义一致）
        BinOp::Div => a.checked_div(b).unwrap_or(0),
        BinOp::Mod => a.checked_rem(b).unwrap_or(0),
        BinOp::Band => a & b,
        BinOp::Bor => a | b,
        BinOp::Bxor => a ^ b,
        BinOp::Shl => a << (b as u32),
        BinOp::Shr => a >> (b as u32),
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
        BinOp::Div => a.checked_div(b).unwrap_or(0),
        BinOp::Mod => a.checked_rem(b).unwrap_or(0),
        BinOp::Band => a & b,
        BinOp::Bor => a | b,
        BinOp::Bxor => a ^ b,
        BinOp::Shl => a << (b as u32),
        BinOp::Shr => a >> (b as u32),
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
    fn alloc_str(&self, s: &str) -> Rc<str>;
    fn alloc_array(&self, vals: Vec<ValueHandle>) -> Rc<Vec<ValueHandle>>;
    fn alloc_value(&self, val: ValueHandle) -> ValueHandle {
        val
    }
}

/// 默认分配器
#[derive(Debug, Clone, Default)]
pub struct DefaultAllocator;

impl Allocator for DefaultAllocator {
    fn alloc_str(&self, s: &str) -> Rc<str> {
        Rc::from(s)
    }
    fn alloc_array(&self, vals: Vec<ValueHandle>) -> Rc<Vec<ValueHandle>> {
        Rc::new(vals)
    }
}

pub fn default_allocator() -> DefaultAllocator {
    DefaultAllocator
}

// =========================================================================
// 第十六部分：测试
// =========================================================================

#[cfg(test)]
mod value_tests {
    use super::*;

    // ---- 构造器与访问器 ----

    #[test]
    fn test_scalar_constructors() {
        let mut a = ValueArena::new();
        assert!(a.null().is_null());
        assert!(a.void().is_void());
        assert_eq!(a.bool(true).as_bool(&a), Some(true));
        assert_eq!(a.i32(42).as_i32(&a), Some(42));
        assert_eq!(a.i64(-7).as_i64(&a), Some(-7));
        assert_eq!(a.u8(255).as_u8(&a), Some(255));
        assert_eq!(a.f64(2.5).as_f64(&a), Some(2.5));
    }

    #[test]
    fn test_char_constructor() {
        let mut a = ValueArena::new();
        let c = a.from_rust_char('A');
        assert!(c.is_char());
        assert_eq!(c.as_char(&a).unwrap().codepoint(), 65);
    }

    #[test]
    fn test_int_promotion() {
        let mut a = ValueArena::new();
        assert_eq!(a.i32(42).as_int_i64(&a), Some(42));
        assert_eq!(a.u64(100).as_int_i64(&a), Some(100));
        assert_eq!(a.i8(-5).as_int_i128(&a), Some(-5));
        assert_eq!(a.f64(2.5).as_int_i64(&a), None);
    }

    #[test]
    fn test_float_promotion() {
        let mut a = ValueArena::new();
        assert_eq!(a.f32(1.5).as_float_f64(&a), Some(1.5));
        assert_eq!(a.f64(2.5).as_float_f64(&a), Some(2.5));
        assert_eq!(a.i32(42).as_float_f64(&a), None);
    }

    // ---- 谓词 ----

    #[test]
    fn test_predicates() {
        let mut a = ValueArena::new();
        assert!(a.bool(false).is_bool());
        assert!(a.from_rust_char('x').is_char());
        assert!(a.i32(0).is_int());
        assert!(a.u64(1).is_int());
        assert!(a.f64(0.0).is_float());
        assert!(a.i32(0).is_numeric());
        assert!(a.f32(0.0).is_numeric());
        assert!(!a.bool(true).is_numeric());
        assert!(a.i32(0).is_scalar());
        assert!(!a.null().is_scalar());
    }

    #[test]
    fn test_heap_predicates() {
        let mut a = ValueArena::new();
        let s = a.str("hello");
        assert!(s.is_string(&a));
        assert!(s.is_ref());
        let e1 = Value::i32(1);
        let e2 = Value::i32(2);
        let arr = a.array(vec![e1, e2]);
        assert!(arr.is_array(&a));
        assert!(a.record("Foo", vec![], vec![]).is_record(&a));
        let cl = a.closure(Closure {
            func_id: 0,
            arity: 0,
            upvalues: vec![],
            bound_args: vec![],
            self_upvalue_idx: -1,
            upvalue_ref_bits: 0,
            cell_upvalues: 0,
        });
        assert!(cl.is_closure(&a));
        assert!(cl.is_callable(&a));
    }

    // ---- 类型名称 ----

    #[test]
    fn test_type_names() {
        let mut a = ValueArena::new();
        assert_eq!(a.null().type_name(&a), "null");
        assert_eq!(a.void().type_name(&a), "void");
        assert_eq!(a.bool(true).type_name(&a), "bool");
        assert_eq!(a.from_rust_char('x').type_name(&a), "char");
        assert_eq!(a.i32(0).type_name(&a), "i32");
        assert_eq!(a.u64(0).type_name(&a), "u64");
        assert_eq!(a.f64(0.0).type_name(&a), "f64");
        assert_eq!(a.str("x").type_name(&a), "str");
        assert_eq!(a.array(vec![]).type_name(&a), "array");
        assert_eq!(a.record("Foo", vec![], vec![]).type_name(&a), "record");
    }

    #[test]
    fn test_scalar_tag() {
        let mut a = ValueArena::new();
        assert_eq!(a.bool(true).scalar_tag(), Some(ValueTag::Bool));
        assert_eq!(a.i32(0).scalar_tag(), Some(ValueTag::I32));
        assert_eq!(a.f64(0.0).scalar_tag(), Some(ValueTag::F64));
        assert_eq!(a.null().scalar_tag(), None);
        assert_eq!(a.str("x").scalar_tag(), None);
    }

    // ---- equals ----

    #[test]
    fn test_equals_scalars() {
        let mut a = ValueArena::new();
        assert!(a.i32(42).equals(&a.i32(42), &a));
        assert!(!a.i32(42).equals(&a.i32(43), &a));
        assert!(a.bool(true).equals(&a.bool(true), &a));
        assert!(!a.bool(true).equals(&a.bool(false), &a));
        assert!(a.f64(2.5).equals(&a.f64(2.5), &a));
        assert!(a.null().equals(&a.null(), &a));
        assert!(a.void().equals(&a.void(), &a));
        assert!(!a.null().equals(&a.void(), &a));
    }

    #[test]
    fn test_equals_different_types() {
        let mut a = ValueArena::new();
        // 即使数值相同，不同标量类型不相等
        assert!(!a.i32(1).equals(&a.i64(1), &a));
        assert!(!a.i32(1).equals(&a.u32(1), &a));
        assert!(!a.i32(1).equals(&a.bool(true), &a));
    }

    #[test]
    fn test_equals_strings() {
        let mut a = ValueArena::new();
        let s1 = a.str("hello");
        let s2 = a.str("hello");
        let s3 = a.str("world");
        assert!(s1.equals(&s2, &a));
        assert!(!s1.equals(&s3, &a));
    }

    #[test]
    fn test_equals_arrays() {
        let mut a = ValueArena::new();
        let es: Vec<Value> = [1, 2, 3].iter().map(|&v| Value::i32(v)).collect();
        let a1 = a.array(es);
        let es: Vec<Value> = [1, 2, 3].iter().map(|&v| Value::i32(v)).collect();
        let a2 = a.array(es);
        let es: Vec<Value> = [1, 2].iter().map(|&v| Value::i32(v)).collect();
        let a3 = a.array(es);
        let es: Vec<Value> = [1, 2, 4].iter().map(|&v| Value::i32(v)).collect();
        let a4 = a.array(es);
        assert!(a1.equals(&a2, &a));
        assert!(!a1.equals(&a3, &a));
        assert!(!a1.equals(&a4, &a));
    }

    #[test]
    fn test_equals_records() {
        let mut a = ValueArena::new();
        let v = Value::i32(1);
        let r1 = a.record("Foo", vec![v], vec![Some("x".to_string())]);
        let v = Value::i32(1);
        let r2 = a.record("Foo", vec![v], vec![Some("x".to_string())]);
        let v = Value::i32(1);
        let r3 = a.record("Bar", vec![v], vec![Some("x".to_string())]);
        assert!(r1.equals(&r2, &a));
        assert!(!r1.equals(&r3, &a));
    }

    #[test]
    fn test_equals_adt() {
        let mut a = ValueArena::new();
        let v = Value::i32(42);
        let a1 = a.adt("Option", "Some", vec![AdtField {
            name: None,
            value: v,
        }]);
        let v = Value::i32(42);
        let a2 = a.adt("Option", "Some", vec![AdtField {
            name: None,
            value: v,
        }]);
        let a3 = a.adt("Option", "None", vec![]);
        assert!(a1.equals(&a2, &a));
        assert!(!a1.equals(&a3, &a));
    }

    #[test]
    fn test_equals_range() {
        let mut a = ValueArena::new();
        let r1 = a.range(1, 10, false);
        let r2 = a.range(1, 10, false);
        let r3 = a.range(1, 10, true);
        assert!(r1.equals(&r2, &a));
        assert!(!r1.equals(&r3, &a));
    }

    #[test]
    fn test_partial_eq_trait() {
        // PartialEq 比较句柄身份：同一句柄相等；单例常量相等
        let v = ValueHandle::TRUE;
        assert_eq!(v, v);
        assert_eq!(ValueHandle::NULL, ValueHandle::NULL);
        assert_eq!(ValueHandle::VOID, ValueHandle::VOID);
        assert_ne!(ValueHandle::NULL, ValueHandle::VOID);
    }

    // ---- deep_clone ----

    #[test]
    fn test_deep_clone_scalar() {
        let mut a = ValueArena::new();
        let v = a.i32(42);
        let c = v.deep_clone(&mut a);
        assert!(v.equals(&c, &a));
        // 标量是 Copy，克隆后仍是同一变体
        assert_eq!(c.as_i32(&a), Some(42));
    }

    #[test]
    fn test_deep_clone_array() {
        let mut a = ValueArena::new();
        let e1 = Value::i32(1);
        let e2 = Value::ref_val(HeapObj::Str(GlueStr::new("hello")));
        let e3 = Value::bool_val(true);
        let v = a.array(vec![e1, e2, e3]);
        let c = v.deep_clone(&mut a);
        assert!(v.equals(&c, &a));
        // 克隆后指针不同
        assert!(!Arc::ptr_eq(a.get_ref(v), a.get_ref(c)));
    }

    #[test]
    fn test_deep_clone_nested() {
        let mut a = ValueArena::new();
        let i1 = Value::i32(1);
        let i2 = Value::i32(2);
        let inner = Value::ref_val(HeapObj::Array(ArrayValue::new(vec![i1, i2])));
        let s = Value::ref_val(HeapObj::Str(GlueStr::new("x")));
        let outer = a.array(vec![inner, s]);
        let cloned = outer.deep_clone(&mut a);
        assert!(outer.equals(&cloned, &a));

        // 修改克隆不影响原（语义验证：克隆是独立的）
        let arr = cloned.as_array(&a).unwrap();
        assert_eq!(arr.elements.len(), 2);
    }

    #[test]
    fn test_deep_clone_record() {
        let mut a = ValueArena::new();
        let x = Value::i32(1);
        let y = Value::i32(2);
        let r = a.record(
            "Point",
            vec![x, y],
            vec![Some("x".to_string()), Some("y".to_string())],
        );
        let c = r.deep_clone(&mut a);
        assert!(r.equals(&c, &a));
    }

    // ---- Display / Debug ----

    #[test]
    fn test_display() {
        let mut a = ValueArena::new();
        let n = a.null();
        let v = a.void();
        let b = a.bool(true);
        let i = a.i32(42);
        let s = a.str("hello");
        let c = a.from_rust_char('A');
        assert_eq!(format!("{}", a.display(n)), "null");
        assert_eq!(format!("{}", a.display(v)), "()");
        assert_eq!(format!("{}", a.display(b)), "true");
        assert_eq!(format!("{}", a.display(i)), "42");
        assert_eq!(format!("{}", a.display(s)), "hello");
        assert_eq!(format!("{}", a.display(c)), "A");
    }

    #[test]
    fn test_debug() {
        let mut a = ValueArena::new();
        let i = a.i32(42);
        let i64v = a.i64(42);
        let u = a.u8(255);
        assert_eq!(format!("{:?}", a.debug(i)), "42");
        assert_eq!(format!("{:?}", a.debug(i64v)), "42i64");
        assert_eq!(format!("{:?}", a.debug(u)), "255u8");
    }

    // ---- Hash ----

    #[test]
    fn test_hash_consistency() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::Hasher;

        let mut a = ValueArena::new();

        fn hash_of(arena: &ValueArena, v: ValueHandle) -> u64 {
            let mut h = DefaultHasher::new();
            arena.hash_value(v, &mut h);
            h.finish()
        }

        // 相同标量按值哈希一致
        let v1 = a.i32(42);
        let v2 = a.i32(42);
        assert_eq!(hash_of(&a, v1), hash_of(&a, v2));
        // 不同类型哈希不同
        let v3 = a.i32(1);
        let v4 = a.i64(1);
        assert_ne!(hash_of(&a, v3), hash_of(&a, v4));
    }

    // ---- 内存语义 ----

    #[test]
    fn test_ref_sharing() {
        let mut a = ValueArena::new();
        let s1 = a.str("shared");
        let s2 = s1; // Copy：同一句柄，共享 Rc
        assert!(Arc::ptr_eq(a.get_ref(s1), a.get_ref(s2)));
        assert!(s1.equals(&s2, &a));
    }

    #[test]
    fn test_default_is_void() {
        assert!(ValueHandle::default().is_void());
    }
}

#[cfg(test)]
mod scalar_tests {
    use super::*;

    #[test]
    fn test_scalar_tag_count() {
        assert_eq!(ValueTag::all().len(), 18);
    }

    #[test]
    fn test_byte_width() {
        assert_eq!(ValueTag::Bool.byte_width(), 1);
        assert_eq!(ValueTag::Char.byte_width(), 4);
        assert_eq!(ValueTag::I8.byte_width(), 1);
        assert_eq!(ValueTag::I64.byte_width(), 8);
        assert_eq!(ValueTag::I128.byte_width(), 16);
        assert_eq!(ValueTag::F16.byte_width(), 2);
        assert_eq!(ValueTag::F128.byte_width(), 16);
    }

    #[test]
    fn test_predicates() {
        assert!(ValueTag::I32.is_int());
        assert!(!ValueTag::Bool.is_int());
        assert!(ValueTag::F64.is_float());
        assert!(ValueTag::I32.is_signed());
        assert!(!ValueTag::U32.is_signed());
        assert!(ValueTag::Isize.is_signed());
    }

    #[test]
    fn test_name_roundtrip() {
        for tag in ValueTag::all() {
            let name = tag.name();
            assert_eq!(ValueTag::from_name(name), Some(*tag));
        }
        assert_eq!(ValueTag::from_name("not_a_type"), None);
    }

    #[test]
    fn test_f16_basic() {
        let z = F16::from_f32(0.0);
        assert_eq!(z.to_f32(), 0.0);
        let one = F16::from_f32(1.0);
        assert_eq!(one.to_f32(), 1.0);
        let inf = F16::from_f32(f32::INFINITY);
        assert!(inf.is_infinite());
        let nan = F16::from_f32(f32::NAN);
        assert!(nan.is_nan());
    }

    #[test]
    fn test_f128_basic() {
        let z = F128::from_f64(0.0);
        assert_eq!(z.to_f64(), 0.0);
        let one = F128::from_f64(1.0);
        assert_eq!(one.to_f64(), 1.0);
        let inf = F128::from_f64(f64::INFINITY);
        assert!(inf.is_infinite());
        let nan = F128::from_f64(f64::NAN);
        assert!(nan.is_nan());
    }
}

#[cfg(test)]
mod char_tests {
    use super::*;

    #[test]
    fn test_from_codepoint_valid() {
        assert!(Char::from_codepoint(0x41).is_ok());
        assert!(Char::from_codepoint(0x10FFFF).is_ok());
        assert!(Char::from_codepoint(0).is_ok());
    }

    #[test]
    fn test_from_codepoint_invalid() {
        assert_eq!(Char::from_codepoint(0x110000), Err(CharError::InvalidCodepoint));
        assert_eq!(Char::from_codepoint(0xD800), Err(CharError::InvalidCodepoint));
        assert_eq!(Char::from_codepoint(0xDFFF), Err(CharError::InvalidCodepoint));
    }

    #[test]
    fn test_classification() {
        let a = Char::from('a');
        assert!(a.is_alpha());
        assert!(!a.is_digit());
        assert!(a.is_ascii());

        let five = Char::from('5');
        assert!(five.is_digit());
        assert!(!five.is_alpha());

        let space = Char::from(' ');
        assert!(space.is_whitespace());
    }

    #[test]
    fn test_case_conversion() {
        assert_eq!(Char::from('a').to_upper(), Char::from('A'));
        assert_eq!(Char::from('A').to_lower(), Char::from('a'));
        assert_eq!(Char::from('1').to_upper(), Char::from('1'));
    }

    #[test]
    fn test_successor_predecessor() {
        assert_eq!(Char::from('a').successor(), Char::from('b'));
        assert_eq!(Char::from('b').predecessor(), Char::from('a'));
    }

    #[test]
    fn test_to_string() {
        assert_eq!(Char::from('A').to_string(), "A");
        assert_eq!(Char::from('中').to_string(), "中");
    }
}

#[cfg(test)]
mod ops_tests {
    use super::*;

    #[test]
    fn test_int_add() {
        assert_eq!(i32::checked_add(1, 2), Some(3));
        assert_eq!(i32::checked_add(i32::MAX, 1), None);
        assert_eq!(u8::checked_add(255, 1), None);
    }

    #[test]
    fn test_int_sub() {
        assert_eq!(i32::checked_sub(5, 3), Some(2));
        assert_eq!(u8::checked_sub(0, 1), None);
    }

    #[test]
    fn test_int_mul() {
        assert_eq!(i32::checked_mul(3, 4), Some(12));
        assert_eq!(i32::checked_mul(i32::MAX, 2), None);
    }

    #[test]
    fn test_int_div() {
        assert_eq!(i32::checked_div(10, 3), Some(3));
        assert_eq!(i32::checked_div(10, 0), None);
        assert_eq!(i32::checked_rem(10, 3), Some(1));
        assert_eq!(i32::checked_rem(10, 0), None);
    }

    #[test]
    fn test_int_neg() {
        assert_eq!(i32::neg(5), Some(-5));
        assert_eq!(i32::neg(i32::MIN), None);
        assert_eq!(u32::neg(5), None);
    }

    #[test]
    fn test_float_add() {
        assert_eq!(f32::checked_add(1.5, 2.5), Some(4.0));
        assert_eq!(f64::checked_div(1.0, 0.0), Some(f64::INFINITY));
    }

    #[test]
    fn test_bitops() {
        assert_eq!(u8::bit_and(0xF0, 0x0F), 0x00);
        assert_eq!(u8::bit_or(0xF0, 0x0F), 0xFF);
        assert_eq!(u8::bit_xor(0xFF, 0x0F), 0xF0);
        assert_eq!(u8::bit_not(0x00), 0xFF);
        assert_eq!(u8::shl(0x01, 4), 0x10);
        assert_eq!(u8::shr(0x80, 4), 0x08);
        assert_eq!(i32::shl(1, 31), i32::MIN);
    }
}

#[cfg(test)]
mod cast_tests {
    use super::*;

    fn make_bytes(v: i32) -> Vec<u8> {
        v.to_le_bytes().to_vec()
    }

    #[test]
    fn test_cast_i32_to_i64() {
        let src = make_bytes(42);
        let dst = cast_value(ValueTag::I32, &src, ValueTag::I64);
        assert_eq!(i64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        }), 42);
    }

    #[test]
    fn test_cast_i32_to_i8_wrap() {
        let src = make_bytes(300);
        let dst = cast_value(ValueTag::I32, &src, ValueTag::I8);
        assert_eq!(dst[0] as i8, 300i32 as i8);
    }

    #[test]
    fn test_try_cast_i32_to_i8_overflow() {
        let src = make_bytes(300);
        assert_eq!(
            try_cast_value(ValueTag::I32, &src, ValueTag::I8),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_try_cast_i32_to_i8_ok() {
        let src = make_bytes(100);
        let dst = try_cast_value(ValueTag::I32, &src, ValueTag::I8).unwrap();
        assert_eq!(dst[0] as i8, 100);
    }

    #[test]
    fn test_cast_f64_to_i32_truncate() {
        let src = 3.7f64.to_le_bytes().to_vec();
        let dst = cast_value(ValueTag::F64, &src, ValueTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 3);
    }

    #[test]
    fn test_cast_f64_to_i32_nan() {
        let src = f64::NAN.to_le_bytes().to_vec();
        let dst = cast_value(ValueTag::F64, &src, ValueTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 0);
    }

    #[test]
    fn test_cast_f64_to_i32_inf() {
        let src = f64::INFINITY.to_le_bytes().to_vec();
        let dst = cast_value(ValueTag::F64, &src, ValueTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, i32::MAX);
    }

    #[test]
    fn test_try_cast_f64_to_i32_nan() {
        let src = f64::NAN.to_le_bytes().to_vec();
        assert_eq!(
            try_cast_value(ValueTag::F64, &src, ValueTag::I32),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_cast_bool_to_int() {
        let src = vec![1u8];
        let dst = cast_value(ValueTag::Bool, &src, ValueTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 1);
    }

    #[test]
    fn test_cast_int_to_bool() {
        let src = make_bytes(0);
        let dst = cast_value(ValueTag::I32, &src, ValueTag::Bool);
        assert_eq!(dst[0], 0);

        let src = make_bytes(42);
        let dst = cast_value(ValueTag::I32, &src, ValueTag::Bool);
        assert_eq!(dst[0], 1);
    }

    #[test]
    fn test_cast_char_to_int() {
        let src = 65u32.to_le_bytes().to_vec();
        let dst = cast_value(ValueTag::Char, &src, ValueTag::I64);
        let v = i64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 65);
    }

    #[test]
    fn test_try_cast_int_to_char_invalid() {
        let src = 0x110000u32.to_le_bytes().to_vec();
        assert_eq!(
            try_cast_value(ValueTag::I32, &src, ValueTag::Char),
            Err(CastError::InvalidCodepoint)
        );
    }

    #[test]
    fn test_try_cast_int_to_char_valid() {
        let src = 65i32.to_le_bytes().to_vec();
        let dst = try_cast_value(ValueTag::I32, &src, ValueTag::Char).unwrap();
        let v = u32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 65);
    }

    #[test]
    fn test_parse_str_int() {
        let dst = parse_str("42", ValueTag::I32).unwrap();
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 42);
    }

    #[test]
    fn test_parse_str_bool() {
        let dst = parse_str("true", ValueTag::Bool).unwrap();
        assert_eq!(dst[0], 1);

        let dst = parse_str("false", ValueTag::Bool).unwrap();
        assert_eq!(dst[0], 0);
    }

    #[test]
    fn test_parse_str_float() {
        let dst = parse_str("2.5", ValueTag::F64).unwrap();
        let v = f64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        });
        assert!((v - 2.5).abs() < 1e-10);
    }

    #[test]
    fn test_parse_str_fail() {
        assert!(parse_str("abc", ValueTag::I32).is_err());
    }
}

#[cfg(test)]
mod batch_tests {
    use super::*;

    #[test]
    fn test_op_enums() {
        assert_eq!(format!("{:?}", BinOp::Add), "Add");
        assert_eq!(format!("{:?}", CmpOp::Lt), "Lt");
        assert_eq!(format!("{:?}", UnaryOp::Neg), "Neg");
        assert_eq!(format!("{:?}", ReduceOp::Mul), "Mul");
    }

    #[test]
    fn test_batch_add_i64() {
        let a = [1i64, 2, 3, 4];
        let b = [10i64, 20, 30, 40];
        let mut dst = [0i64; 4];
        batch_binop(&mut dst, &a, &b, BinOp::Add);
        assert_eq!(dst, [11, 22, 33, 44]);
    }

    #[test]
    fn test_batch_mul_i64() {
        let a = [1i64, 2, 3, 4];
        let b = [2i64, 3, 4, 5];
        let mut dst = [0i64; 4];
        batch_binop(&mut dst, &a, &b, BinOp::Mul);
        assert_eq!(dst, [2, 6, 12, 20]);
    }

    #[test]
    fn test_batch_add_i64_overflow_wrap() {
        let a = [i64::MAX];
        let b = [1i64];
        let mut dst = [0i64; 1];
        batch_binop(&mut dst, &a, &b, BinOp::Add);
        assert_eq!(dst[0], i64::MIN);
    }

    #[test]
    fn test_batch_cmp_i64() {
        let a = [1i64, 5, 3, 3];
        let b = [2i64, 4, 3, 4];
        let mut dst = [0u8; 4];

        batch_cmp(&mut dst, &a, &b, CmpOp::Lt);
        assert_eq!(dst, [1, 0, 0, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Gt);
        assert_eq!(dst, [0, 1, 0, 0]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Eq);
        assert_eq!(dst, [0, 0, 1, 0]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Ne);
        assert_eq!(dst, [1, 1, 0, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Le);
        assert_eq!(dst, [1, 0, 1, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Ge);
        assert_eq!(dst, [0, 1, 1, 0]);
    }

    #[test]
    fn test_batch_cmp_f64() {
        let a = [1.5f64, 2.5, 3.0];
        let b = [2.0f64, 2.5, 2.9];
        let mut dst = [0u8; 3];
        batch_cmp(&mut dst, &a, &b, CmpOp::Gt);
        assert_eq!(dst, [0, 0, 1]);
    }

    #[test]
    fn test_batch_reduce_sum_i64() {
        assert_eq!(batch_reduce(&[1i64, 2, 3, 4, 5], ReduceOp::Add), 15);
        assert_eq!(batch_reduce::<i64>(&[], ReduceOp::Add), 0);
        assert_eq!(batch_reduce(&[i64::MAX, 1], ReduceOp::Add), i64::MIN); // wrapping
    }

    // ---- 掩码选择 ----

    #[test]
    fn test_batch_select() {
        let mask = [1u8, 0, 1, 0];
        let t = [10i64, 20, 30, 40];
        let f = [100i64, 200, 300, 400];
        let mut dst = [0i64; 4];
        batch_select(&mut dst, &mask, &t, &f);
        assert_eq!(dst, [10, 200, 30, 400]);
    }

    #[test]
    fn test_batch_select_f64() {
        let mask = [0u8, 1, 0];
        let t = [1.0f64, 2.0, 3.0];
        let f = [10.0f64, 20.0, 30.0];
        let mut dst = [0.0f64; 3];
        batch_select(&mut dst, &mask, &t, &f);
        assert_eq!(dst, [10.0, 2.0, 30.0]);
    }

    // ---- 广播 ----

    #[test]
    fn test_broadcast_i64() {
        let mut dst = [0i64; 5];
        broadcast(&mut dst, 42);
        assert_eq!(dst, [42, 42, 42, 42, 42]);
    }

    #[test]
    fn test_broadcast_f64() {
        let mut dst = [0.0f64; 3];
        broadcast(&mut dst, 2.5);
        assert_eq!(dst, [2.5, 2.5, 2.5]);
    }

    #[test]
    fn test_broadcast_empty() {
        let mut dst: [i64; 0] = [];
        broadcast(&mut dst, 42);
        assert!(dst.is_empty());
    }

    // ---- 长度不一致时取最小值 ----

    #[test]
    fn test_batch_length_mismatch() {
        let a = [1i64, 2, 3];
        let b = [10i64, 20];
        let mut dst = [0i64, 0, 0, 0];
        batch_binop(&mut dst, &a, &b, BinOp::Add);
        // 只处理前 2 个元素
        assert_eq!(dst[0], 11);
        assert_eq!(dst[1], 22);
        // dst[2], dst[3] 保持原值
        assert_eq!(dst[2], 0);
        assert_eq!(dst[3], 0);
    }

    // ---- 批量位运算（u8 作为可位运算类型）----

    #[test]
    fn test_batch_bit_and_u8() {
        let a = [0xF0u8, 0xFF, 0x0F];
        let b = [0x0Fu8, 0xF0, 0x0F];
        let mut dst = [0u8; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Band);
        assert_eq!(dst, [0x00, 0xF0, 0x0F]);
    }

    #[test]
    fn test_batch_bit_or_u8() {
        let a = [0xF0u8, 0x0F, 0x00];
        let b = [0x0Fu8, 0xF0, 0xFF];
        let mut dst = [0u8; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Bor);
        assert_eq!(dst, [0xFF, 0xFF, 0xFF]);
    }

    #[test]
    fn test_batch_bit_xor_u8() {
        let a = [0xFFu8, 0xAA, 0x00];
        let b = [0x0Fu8, 0x55, 0xFF];
        let mut dst = [0u8; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Bxor);
        assert_eq!(dst, [0xF0, 0xFF, 0xFF]);
    }

    #[test]
    fn test_batch_bit_not_u8() {
        let a = [0x00u8, 0xFF, 0x0F];
        let mut dst = [0u8; 3];
        batch_unaryop(&mut dst, &a, UnaryOp::Bnot);
        assert_eq!(dst, [0xFF, 0x00, 0xF0]);
    }

    // ---- 批量一元运算 ----

    #[test]
    fn test_batch_neg_i64() {
        let a = [1i64, -2, 3, 0];
        let mut dst = [0i64; 4];
        batch_unaryop(&mut dst, &a, UnaryOp::Neg);
        assert_eq!(dst, [-1, 2, -3, 0]);
    }

    #[test]
    fn test_batch_abs_i64() {
        let a = [1i64, -2, -3, 0];
        let mut dst = [0i64; 4];
        batch_unaryop(&mut dst, &a, UnaryOp::Abs);
        assert_eq!(dst, [1, 2, 3, 0]);
    }

    // ---- 通用分派 ----

    #[test]
    fn test_batch_binop_dispatch_i64() {
        let a = [1i64, 2, 3];
        let b = [4i64, 5, 6];
        let mut dst = [0i64; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Add);
        assert_eq!(dst, [5, 7, 9]);
    }

    #[test]
    fn test_batch_unaryop_dispatch_i64() {
        let a = [1i64, -2, 3];
        let mut dst = [0i64; 3];
        batch_unaryop(&mut dst, &a, UnaryOp::Neg);
        assert_eq!(dst, [-1, 2, -3]);

        batch_unaryop(&mut dst, &a, UnaryOp::Abs);
        assert_eq!(dst, [1, 2, 3]);
    }

    // ---- ReduceOp 通用（u8 用于位运算归约）----

    #[test]
    fn test_batch_reduce_band_u8() {
        let a = [0xFFu8, 0xF0, 0x0F];
        let result = batch_reduce(&a, ReduceOp::Band);
        assert_eq!(result, 0x00);
    }

    #[test]
    fn test_batch_reduce_bor_u8() {
        let a = [0xF0u8, 0x0F, 0x00];
        let result = batch_reduce(&a, ReduceOp::Bor);
        assert_eq!(result, 0xFF);
    }

    #[test]
    fn test_batch_reduce_bxor_u8() {
        let a = [0xFFu8, 0x0F, 0xF0];
        let result = batch_reduce(&a, ReduceOp::Bxor);
        assert_eq!(result, 0x00);
    }

    #[test]
    fn test_batch_reduce_empty() {
        let a: [u8; 0] = [];
        // 空切片归约返回 T::zero()
        assert_eq!(batch_reduce(&a, ReduceOp::Bor), 0u8);
        assert_eq!(batch_reduce(&a, ReduceOp::Add), 0u8);
    }

    #[test]
    fn test_batch_reduce_add_i64() {
        let a = [1i64, 2, 3, 4, 5];
        assert_eq!(batch_reduce(&a, ReduceOp::Add), 15);
    }

    #[test]
    fn test_batch_reduce_mul_i64() {
        let a = [1i64, 2, 3, 4];
        assert_eq!(batch_reduce(&a, ReduceOp::Mul), 24);
    }

    #[test]
    fn test_batch_shl_shr_i32() {
        let a = [1i32, 2, 4];
        let b = [1i32, 2, 3];
        let mut dst = [0i32; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Shl);
        assert_eq!(dst, [2, 8, 32]);

        let a2 = [8i32, 16, 32];
        let b2 = [1i32, 2, 3];
        batch_binop(&mut dst, &a2, &b2, BinOp::Shr);
        assert_eq!(dst, [4, 4, 4]);
    }

    #[test]
    fn test_batch_div_mod_i32() {
        let a = [10i32, 20, 30];
        let b = [3i32, 7, 5];
        let mut dst = [0i32; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Div);
        assert_eq!(dst, [3, 2, 6]);

        batch_binop(&mut dst, &a, &b, BinOp::Mod);
        assert_eq!(dst, [1, 6, 0]);
    }

    #[test]
    fn test_batch_div_zero_returns_zero() {
        let a = [10i32];
        let b = [0i32];
        let mut dst = [0i32; 1];
        batch_binop(&mut dst, &a, &b, BinOp::Div);
        assert_eq!(dst[0], 0);
    }

    // =====================================================================
    // SIMD 特化测试
    // =====================================================================

    fn ref_binop_f32(a: &[f32], b: &[f32], op: BinOp) -> Vec<f32> {
        a.iter()
            .zip(b.iter())
            .map(|(x, y)| match op {
                BinOp::Add => x + y,
                BinOp::Sub => x - y,
                BinOp::Mul => x * y,
                BinOp::Div => x / y,
                BinOp::Mod => x % y,
                _ => *x,
            })
            .collect()
    }

    fn ref_binop_f64(a: &[f64], b: &[f64], op: BinOp) -> Vec<f64> {
        a.iter()
            .zip(b.iter())
            .map(|(x, y)| match op {
                BinOp::Add => x + y,
                BinOp::Sub => x - y,
                BinOp::Mul => x * y,
                BinOp::Div => x / y,
                BinOp::Mod => x % y,
                _ => *x,
            })
            .collect()
    }

    #[test]
    fn test_simd_binop_f32() {
        let lens = [0usize, 1, 3, 4, 7, 16, 100];
        let ops = [BinOp::Add, BinOp::Sub, BinOp::Mul, BinOp::Div, BinOp::Mod];
        for &n in &lens {
            let a: Vec<f32> = (0..n).map(|i| (i as f32) * 0.5 + 1.0).collect();
            let b: Vec<f32> = (0..n).map(|i| (i as f32) * 0.25 + 2.0).collect();
            for &op in &ops {
                let mut got = vec![0.0f32; n];
                batch_binop_f32(&mut got, &a, &b, op);
                assert_eq!(got, ref_binop_f32(&a, &b, op), "f32 {:?} len {}", op, n);
            }
        }
    }

    #[test]
    fn test_simd_binop_f64() {
        let lens = [0usize, 1, 3, 4, 7, 16, 100];
        let ops = [BinOp::Add, BinOp::Sub, BinOp::Mul, BinOp::Div, BinOp::Mod];
        for &n in &lens {
            let a: Vec<f64> = (0..n).map(|i| (i as f64) * 0.5 + 1.0).collect();
            let b: Vec<f64> = (0..n).map(|i| (i as f64) * 0.25 + 2.0).collect();
            for &op in &ops {
                let mut got = vec![0.0f64; n];
                batch_binop_f64(&mut got, &a, &b, op);
                assert_eq!(got, ref_binop_f64(&a, &b, op), "f64 {:?} len {}", op, n);
            }
        }
    }

    #[test]
    fn test_simd_binop_i32() {
        let ops = [
            BinOp::Add,
            BinOp::Sub,
            BinOp::Mul,
            BinOp::Div,
            BinOp::Mod,
            BinOp::Band,
            BinOp::Bor,
            BinOp::Bxor,
            BinOp::Shl,
            BinOp::Shr,
        ];
        for n in [0usize, 1, 3, 4, 7, 16, 100] {
            let a: Vec<i32> = (0..n as i32).map(|i| i + 1).collect();
            // b 始终 >= 1，避免除零；移位量 1..=5，避免溢出 panic
            let b: Vec<i32> = (0..n as i32).map(|i| (i % 5) + 1).collect();
            for &op in &ops {
                let mut got = vec![0i32; n];
                let mut want = vec![0i32; n];
                batch_binop_i32(&mut got, &a, &b, op);
                batch_binop(&mut want, &a, &b, op); // 泛型标量作参考
                assert_eq!(got, want, "i32 {:?} len {}", op, n);
            }
        }
    }

    #[test]
    fn test_simd_binop_i64() {
        let ops = [
            BinOp::Add,
            BinOp::Sub,
            BinOp::Mul,
            BinOp::Div,
            BinOp::Mod,
            BinOp::Band,
            BinOp::Bor,
            BinOp::Bxor,
            BinOp::Shl,
            BinOp::Shr,
        ];
        for n in [0usize, 1, 3, 4, 7, 16, 100] {
            let a: Vec<i64> = (0..n as i64).map(|i| i + 1).collect();
            let b: Vec<i64> = (0..n as i64).map(|i| (i % 5) + 1).collect();
            for &op in &ops {
                let mut got = vec![0i64; n];
                let mut want = vec![0i64; n];
                batch_binop_i64(&mut got, &a, &b, op);
                batch_binop(&mut want, &a, &b, op);
                assert_eq!(got, want, "i64 {:?} len {}", op, n);
            }
        }
    }

    #[test]
    fn test_simd_binop_i64_overflow_wrap() {
        // SIMD 整数加法使用 wrapping 语义：i64::MAX + 1 == i64::MIN
        let a = [i64::MAX];
        let b = [1i64];
        let mut got = [0i64; 1];
        batch_binop_i64(&mut got, &a, &b, BinOp::Add);
        assert_eq!(got[0], i64::MIN);
    }

    #[test]
    fn test_simd_binop_i32_div_zero() {
        // 整数除零走标量 checked_div → 返回 0
        let a = [10i32, 20, 30, 40];
        let b = [0i32, 2, 0, 4];
        let mut got = [0i32; 4];
        batch_binop_i32(&mut got, &a, &b, BinOp::Div);
        assert_eq!(got, [0, 10, 0, 10]);
    }

    // ---- 大数组（> PARALLEL_THRESHOLD，触发 rayon 并行）----

    #[test]
    fn test_simd_binop_f32_large() {
        let n = 10_000;
        let a: Vec<f32> = (0..n).map(|i| i as f32).collect();
        let b: Vec<f32> = (0..n).map(|i| (i as f32) * 2.0 + 1.0).collect();
        let mut got = vec![0.0f32; n];
        batch_binop_f32(&mut got, &a, &b, BinOp::Add);
        for i in 0..n {
            assert_eq!(got[i], a[i] + b[i], "idx {}", i);
        }
    }

    #[test]
    fn test_simd_binop_i64_large() {
        let n = 10_000;
        let a: Vec<i64> = (0..n as i64).collect();
        let b: Vec<i64> = (1..=n as i64).collect();
        let mut got = vec![0i64; n];
        let mut want = vec![0i64; n];
        batch_binop_i64(&mut got, &a, &b, BinOp::Add);
        batch_binop(&mut want, &a, &b, BinOp::Add); // 泛型并行标量
        assert_eq!(got, want);
    }

    #[test]
    fn test_batch_binop_generic_parallel_large() {
        let n = 10_000;
        let a: Vec<i64> = (0..n as i64).collect();
        let b: Vec<i64> = (1..=n as i64).collect();
        let mut got = vec![0i64; n];
        batch_binop(&mut got, &a, &b, BinOp::Add);
        for i in 0..n {
            assert_eq!(got[i], a[i] + b[i]);
        }
    }

    #[test]
    fn test_batch_reduce_parallel_large() {
        let n = 10_000;
        let a: Vec<i64> = (0..n as i64).collect();
        let got = batch_reduce(&a, ReduceOp::Add);
        // 0+1+...+9999 = 9999*10000/2
        assert_eq!(got, (n as i64 - 1) * (n as i64) / 2);

        let got_mul = batch_reduce(&[1i64, 2, 3, 4, 5, 6], ReduceOp::Mul);
        assert_eq!(got_mul, 720);
    }

    // ---- 比较 SIMD ----

    #[test]
    fn test_simd_cmp_f32() {
        let a: [f32; 4] = [1.0, 5.0, 3.0, 3.0];
        let b: [f32; 4] = [2.0, 4.0, 3.0, 4.0];
        let cases: [(CmpOp, [u8; 4]); 6] = [
            (CmpOp::Lt, [1, 0, 0, 1]),
            (CmpOp::Gt, [0, 1, 0, 0]),
            (CmpOp::Eq, [0, 0, 1, 0]),
            (CmpOp::Ne, [1, 1, 0, 1]),
            (CmpOp::Le, [1, 0, 1, 1]),
            (CmpOp::Ge, [0, 1, 1, 0]),
        ];
        for (op, exp) in cases {
            let mut dst = [0u8; 4];
            batch_cmp_f32(&mut dst, &a, &b, op);
            assert_eq!(dst, exp, "f32 {:?}", op);
        }
    }

    #[test]
    fn test_simd_cmp_f32_tail() {
        // len 5：1 个 SIMD block + 1 个尾部标量
        let a = [1.0f32, 5.0, 3.0, 3.0, 9.0];
        let b = [2.0f32, 4.0, 3.0, 4.0, 9.0];
        let mut dst = [0u8; 5];
        batch_cmp_f32(&mut dst, &a, &b, CmpOp::Le);
        assert_eq!(dst, [1, 0, 1, 1, 1]);
    }

    #[test]
    fn test_simd_cmp_f64() {
        let a = [1.5f64, 2.5, 3.0, 3.0];
        let b = [2.0f64, 2.5, 2.9, 3.0];
        let cases: [(CmpOp, [u8; 4]); 6] = [
            (CmpOp::Lt, [1, 0, 0, 0]),
            (CmpOp::Gt, [0, 0, 1, 0]),
            (CmpOp::Eq, [0, 1, 0, 1]),
            (CmpOp::Ne, [1, 0, 1, 0]),
            (CmpOp::Le, [1, 1, 0, 1]),
            (CmpOp::Ge, [0, 1, 1, 1]),
        ];
        for (op, exp) in cases {
            let mut dst = [0u8; 4];
            batch_cmp_f64(&mut dst, &a, &b, op);
            assert_eq!(dst, exp, "f64 {:?}", op);
        }
    }

    #[test]
    fn test_simd_cmp_f64_large() {
        let n = 10_000;
        let a: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let b: Vec<f64> = (0..n).map(|i| (i as f64) + 0.5).collect(); // a < b 全部成立
        let mut dst = vec![0u8; n];
        batch_cmp_f64(&mut dst, &a, &b, CmpOp::Lt);
        for v in &dst {
            assert_eq!(*v, 1u8);
        }
    }

    // ---- 归约 SIMD ----

    #[test]
    fn test_simd_reduce_f32() {
        assert_eq!(batch_reduce_f32(&[], ReduceOp::Add), 0.0);
        assert_eq!(batch_reduce_f32(&[1.0, 2.0, 3.0, 4.0], ReduceOp::Add), 10.0);
        // 含尾部元素
        assert_eq!(batch_reduce_f32(&[1.0, 2.0, 3.0, 4.0, 5.0], ReduceOp::Add), 15.0);
        assert_eq!(batch_reduce_f32(&[2.0, 3.0, 4.0], ReduceOp::Mul), 24.0);
    }

    #[test]
    fn test_simd_reduce_f64() {
        assert_eq!(batch_reduce_f64(&[], ReduceOp::Add), 0.0);
        assert_eq!(batch_reduce_f64(&[1.5, 2.5, 3.0, 4.0], ReduceOp::Add), 11.0);
        assert_eq!(batch_reduce_f64(&[1.5, 2.5, 3.0], ReduceOp::Mul), 11.25);
    }

    #[test]
    fn test_simd_reduce_f32_large() {
        let n = 10_000;
        let a: Vec<f32> = (0..n).map(|i| i as f32).collect();
        let got = batch_reduce_f32(&a, ReduceOp::Add);
        // 精确和（f64 累加再转 f32）作参考，SIMD 分组求和可能有微小舍入差异
        let want = (0..n).map(|i| i as f64).sum::<f64>() as f32;
        assert!(
            (got - want).abs() < 50.0,
            "got={} want={}",
            got,
            want
        );
    }
}

#[cfg(test)]
mod allocator_tests {
    use super::*;

    #[test]
    fn test_alloc_str() {
        let alloc = DefaultAllocator;
        let s1 = alloc.alloc_str("hello");
        let s2 = alloc.alloc_str("hello");
        assert_eq!(&*s1, "hello");
        assert_eq!(&*s2, "hello");
        // 不同分配产生不同 Rc 指针
        assert!(!Rc::ptr_eq(&s1, &s2));
    }

    #[test]
    fn test_alloc_str_empty() {
        let alloc = DefaultAllocator;
        let s = alloc.alloc_str("");
        assert!(s.is_empty());
    }

    #[test]
    fn test_alloc_str_unicode() {
        let alloc = DefaultAllocator;
        let s = alloc.alloc_str("你好世界");
        assert_eq!(&*s, "你好世界");
        assert_eq!(s.len(), 12); // UTF-8 字节数
    }

    #[test]
    fn test_alloc_array() {
        let alloc = DefaultAllocator;
        let mut arena = ValueArena::new();
        let arr = alloc.alloc_array(vec![arena.i32(1), arena.i32(2), arena.i32(3)]);
        assert_eq!(arr.len(), 3);
        assert_eq!(arr[0].as_i32(&arena), Some(1));
    }

    #[test]
    fn test_alloc_array_empty() {
        let alloc = DefaultAllocator;
        let arr = alloc.alloc_array(vec![]);
        assert!(arr.is_empty());
    }

    #[test]
    fn test_alloc_value_default_impl() {
        let alloc = DefaultAllocator;
        let mut arena = ValueArena::new();
        let v = arena.i32(42);
        let allocated = alloc.alloc_value(v);
        assert_eq!(allocated.as_i32(&arena), Some(42));
    }

    #[test]
    fn test_default_allocator_singleton() {
        let a1 = default_allocator();
        let a2 = default_allocator();
        // DefaultAllocator 无状态，多次获取等价
        let s1 = a1.alloc_str("test");
        let s2 = a2.alloc_str("test");
        assert_eq!(&*s1, &*s2);
    }

    #[test]
    fn test_allocator_clone() {
        let a1 = DefaultAllocator;
        let a2 = a1.clone();
        let s1 = a1.alloc_str("x");
        let s2 = a2.alloc_str("x");
        assert_eq!(&*s1, &*s2);
    }
}

// =========================================================================
// union 安全性测试
// =========================================================================

#[cfg(test)]
mod union_tests {
    use super::*;

    #[test]
    fn test_union_construct_access_roundtrip() {
        let mut a = ValueArena::new();
        assert_eq!(a.i8(-5).as_i8(&a), Some(-5));
        assert_eq!(a.i16(-1000).as_i16(&a), Some(-1000));
        assert_eq!(a.i32(42).as_i32(&a), Some(42));
        assert_eq!(a.i64(i64::MAX).as_i64(&a), Some(i64::MAX));
        assert_eq!(a.i128(i128::MIN).as_i128(&a), Some(i128::MIN));
        assert_eq!(a.u8(255).as_u8(&a), Some(255));
        assert_eq!(a.u16(65535).as_u16(&a), Some(65535));
        assert_eq!(a.u32(u32::MAX).as_u32(&a), Some(u32::MAX));
        assert_eq!(a.u64(u64::MAX).as_u64(&a), Some(u64::MAX));
        assert_eq!(a.u128(u128::MAX).as_u128(&a), Some(u128::MAX));
        assert_eq!(a.f32(1.5).as_f32(&a), Some(1.5));
        assert_eq!(a.f64(2.5).as_f64(&a), Some(2.5));
    }

    #[test]
    fn test_union_wrong_tag_returns_none() {
        let mut a = ValueArena::new();
        let v = a.i32(42);
        assert_eq!(v.as_i64(&a), None);
        assert_eq!(v.as_u32(&a), None);
        assert_eq!(v.as_f32(&a), None);
        assert_eq!(v.as_bool(&a), None);
        assert_eq!(v.as_char(&a), None);
    }

    #[test]
    fn test_f16_f128_bits_roundtrip() {
        let mut a = ValueArena::new();
        let f16 = F16::from_f32(1.5);
        assert_eq!(f16.to_f32(), 1.5);
        let v = a.f16(f16);
        assert_eq!(v.as_f16(&a), Some(f16));

        // F128 往返测试（已修复掩码 bug）
        let f128 = F128::from_f64(1.5);
        assert_eq!(f128.to_f64(), 1.5);
        let v = a.f128(f128);
        assert_eq!(v.as_f128(&a), Some(f128));
    }

    #[test]
    fn test_char_roundtrip() {
        let mut a = ValueArena::new();
        let c = Char::from_codepoint(0x4E2D).unwrap(); // '中'
        let v = a.char(c);
        assert_eq!(v.as_char(&a), Some(c));
        assert_eq!(v.as_i32(&a), None); // char 不是 int
    }

    #[test]
    fn test_value_size() {
        // ValueHandle 是 4B 索引（u32）
        let size = std::mem::size_of::<ValueHandle>();
        assert_eq!(size, 4, "ValueHandle should be 4 bytes, got {}", size);
    }
}

// =========================================================================
// deep_clone ptr_eq 缓存测试
// =========================================================================

#[cfg(test)]
mod deep_clone_cache_tests {
    use super::*;

    #[test]
    fn test_deep_clone_diamond_shares_subgraph() {
        let mut a = ValueArena::new();
        // 菱形引用：outer 两次引用同一 inner
        let i1 = Value::i32(1);
        let i2 = Value::i32(2);
        let inner = a.array(vec![i1, i2]);
        let inner_rc = a.get_ref(inner).clone();
        let e0 = Value::from_ref(inner_rc.clone());
        let e1 = Value::from_ref(inner_rc.clone());
        let outer = a.array(vec![e0, e1]);

        let cloned = outer.deep_clone(&mut a);

        // 克隆后两个 inner 应共享同一 Rc（ptr_eq）
        let arr = cloned.as_array(&a).unwrap();
        let c0 = arr.elements[0].clone();
        let c1 = arr.elements[1].clone();
        let r0 = c0.heap_ref().unwrap();
        let r1 = c1.heap_ref().unwrap();
        assert!(Arc::ptr_eq(&r0, &r1), "cloned diamond should share subgraph");
    }

    #[test]
    fn test_deep_clone_independent_objects_not_shared() {
        let mut a = ValueArena::new();
        let i1 = Value::i32(1);
        let arr1 = Value::ref_val(HeapObj::Array(ArrayValue::new(vec![i1])));
        let i2 = Value::i32(1);
        let arr2 = Value::ref_val(HeapObj::Array(ArrayValue::new(vec![i2])));
        let outer = a.array(vec![arr1, arr2]);
        let cloned = outer.deep_clone(&mut a);

        let arr = cloned.as_array(&a).unwrap();
        let c0 = arr.elements[0].clone();
        let c1 = arr.elements[1].clone();
        let r0 = c0.heap_ref().unwrap();
        let r1 = c1.heap_ref().unwrap();
        assert!(!Arc::ptr_eq(&r0, &r1), "independent objects should not share");
    }
}

#[cfg(test)]
mod simd_internal_tests {
    use super::*;

    #[test]
    fn test_simd_eq_i32() {
        let a = vec![1i32, 2, 3, 4, 5, 6, 7, 8, 9];
        let b = vec![1i32, 2, 3, 4, 5, 6, 7, 8, 9];
        assert!(simd_eq_i32(&a, &b));
        let c = vec![1i32, 2, 3, 4, 5, 6, 7, 8, 0];
        assert!(!simd_eq_i32(&a, &c));
    }

    #[test]
    fn test_simd_eq_i32_empty_and_mismatched_len() {
        assert!(simd_eq_i32(&[], &[]));
        assert!(!simd_eq_i32(&[1, 2], &[1]));
    }

    #[test]
    fn test_simd_eq_i64_large() {
        let a: Vec<i64> = (0..10000).collect();
        let b: Vec<i64> = (0..10000).collect();
        assert!(simd_eq_i64(&a, &b));
        let mut c = b.clone();
        c[9999] = 0;
        assert!(!simd_eq_i64(&a, &c));
    }

    #[test]
    fn test_simd_eq_f32_bits() {
        let a = vec![1.0f32, 2.0, 3.0, f32::NAN, 5.0];
        let b = vec![1.0f32, 2.0, 3.0, f32::NAN, 5.0];
        assert!(simd_eq_f32_bits(&a, &b)); // NaN bits 相等
    }

    #[test]
    fn test_simd_eq_f64_bits() {
        let a = vec![1.0f64, 2.0, 3.0, f64::NAN, 5.0];
        let b = vec![1.0f64, 2.0, 3.0, f64::NAN, 5.0];
        assert!(simd_eq_f64_bits(&a, &b)); // NaN bits 相等
        let c = vec![1.0f64, 2.0, 3.0, 0.0, 5.0];
        assert!(!simd_eq_f64_bits(&a, &c));
    }

    #[test]
    fn test_simd_eq_i32_large_parallel() {
        let a: Vec<i32> = (0..20000).collect();
        let b: Vec<i32> = (0..20000).collect();
        assert!(simd_eq_i32(&a, &b));
        let mut c = b.clone();
        c[15000] = -1;
        assert!(!simd_eq_i32(&a, &c));
    }

    #[test]
    fn test_soa_equals_integration() {
        let mut arena = ValueArena::new();
        let elems1: Vec<Value> = (0..100).map(|i| Value::i32(i)).collect();
        let elems2: Vec<Value> = (0..100).map(|i| Value::i32(i)).collect();
        let mut arr1 = ArrayValue::new(elems1);
        let mut arr2 = ArrayValue::new(elems2);
        arena.optimize_array_soa(&mut arr1);
        arena.optimize_array_soa(&mut arr2);
        // 通过 heap_equals 走 SoA 快路径
        let h1 = arena.alloc_ref(HeapObj::Array(arr1));
        let h2 = arena.alloc_ref(HeapObj::Array(arr2));
        assert!(h1.equals(&h2, &arena));
    }

    #[test]
    fn test_soa_equals_inequality_integration() {
        let mut arena = ValueArena::new();
        let elems1: Vec<Value> = (0..100).map(|i| Value::i32(i)).collect();
        let elems2: Vec<Value> = (0..100).map(|i| Value::i32(if i == 50 { 999 } else { i })).collect();
        let mut arr1 = ArrayValue::new(elems1);
        let mut arr2 = ArrayValue::new(elems2);
        arena.optimize_array_soa(&mut arr1);
        arena.optimize_array_soa(&mut arr2);
        let h1 = arena.alloc_ref(HeapObj::Array(arr1));
        let h2 = arena.alloc_ref(HeapObj::Array(arr2));
        assert!(!h1.equals(&h2, &arena));
    }

    #[test]
    fn test_soa_hash_integration() {
        let mut arena = ValueArena::new();
        let elems: Vec<Value> = (0..100).map(|i| Value::i64(i)).collect();
        let mut arr = ArrayValue::new(elems);
        arena.optimize_array_soa(&mut arr);
        // 确保能 hash 不 panic（Hash impl 在 HeapObj 上）
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        HeapObj::Array(arr).hash(&mut hasher);
    }

    #[test]
    fn test_soa_hash_consistency() {
        // 两个值相同的 SoA 数组应产生相同哈希
        let mut arena1 = ValueArena::new();
        let elems1: Vec<Value> = (0..50).map(|i| Value::i32(i)).collect();
        let mut arr1 = ArrayValue::new(elems1);
        arena1.optimize_array_soa(&mut arr1);
        let mut h1 = std::collections::hash_map::DefaultHasher::new();
        HeapObj::Array(arr1).hash(&mut h1);
        let hash1 = std::collections::hash_map::DefaultHasher::finish(&h1);

        let mut arena2 = ValueArena::new();
        let elems2: Vec<Value> = (0..50).map(|i| Value::i32(i)).collect();
        let mut arr2 = ArrayValue::new(elems2);
        arena2.optimize_array_soa(&mut arr2);
        let mut h2 = std::collections::hash_map::DefaultHasher::new();
        HeapObj::Array(arr2).hash(&mut h2);
        let hash2 = std::collections::hash_map::DefaultHasher::finish(&h2);

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_soa_deep_clone_integration() {
        let mut arena = ValueArena::new();
        let elems: Vec<Value> = (0..100).map(|i| Value::f64(i as f64)).collect();
        let mut arr = ArrayValue::new(elems);
        arena.optimize_array_soa(&mut arr);
        let h = arena.alloc_ref(HeapObj::Array(arr));
        let cloned = h.deep_clone(&mut arena);
        assert!(h.equals(&cloned, &arena));
    }

    #[test]
    fn test_soa_deep_clone_independent() {
        // deep_clone 后修改克隆不影响原对象
        let mut arena = ValueArena::new();
        let elems: Vec<Value> = (0..10).map(|i| Value::i32(i)).collect();
        let mut arr = ArrayValue::new(elems);
        arena.optimize_array_soa(&mut arr);
        let h = arena.alloc_ref(HeapObj::Array(arr));
        let cloned = h.deep_clone(&mut arena);
        assert!(h.equals(&cloned, &arena));
    }

    #[test]
    fn test_try_simd_soa_equals_type_mismatch() {
        let a = ScalarSoA::I32(vec![1, 2, 3]);
        let b = ScalarSoA::I64(vec![1, 2, 3]);
        assert_eq!(try_simd_soa_equals(&a, &b), None);
    }

    #[test]
    fn test_try_simd_soa_equals_bool_and_char() {
        let a = ScalarSoA::Bool(vec![true, false, true]);
        let b = ScalarSoA::Bool(vec![true, false, true]);
        assert_eq!(try_simd_soa_equals(&a, &b), Some(true));

        let c = ScalarSoA::Char(vec![65, 66, 67]);
        let d = ScalarSoA::Char(vec![65, 66, 67]);
        assert_eq!(try_simd_soa_equals(&c, &d), Some(true));

        let e = ScalarSoA::Char(vec![65, 66, 68]);
        assert_eq!(try_simd_soa_equals(&c, &e), Some(false));
    }
}