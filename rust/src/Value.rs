//! Value.rs — Glue 统一值系统（合并 14 个子模块）

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::sync::Mutex;

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
    let mut result: u32 = ((new_exp as u32) << 10) | (m as u32);
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

// ---- ScalarTag — 18 种标量类型标签 ----

/// 标量类型标签：涵盖布尔、字符、整数与浮点共 18 种
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScalarTag {
    Bool,
    Char,
    I8,
    I16,
    I32,
    I64,
    I128,
    U8,
    U16,
    U32,
    U64,
    U128,
    Isize,
    Usize,
    F16,
    F32,
    F64,
    F128,
}

impl ScalarTag {
    pub fn byte_width(self) -> usize {
        match self {
            ScalarTag::Bool | ScalarTag::I8 | ScalarTag::U8 => 1,
            ScalarTag::I16 | ScalarTag::U16 | ScalarTag::F16 => 2,
            ScalarTag::Char | ScalarTag::I32 | ScalarTag::U32 | ScalarTag::F32 => 4,
            ScalarTag::I64 | ScalarTag::U64 | ScalarTag::Isize | ScalarTag::Usize | ScalarTag::F64 => 8,
            ScalarTag::I128 | ScalarTag::U128 | ScalarTag::F128 => 16,
        }
    }

    pub fn is_int(self) -> bool {
        matches!(
            self,
            ScalarTag::I8 | ScalarTag::I16 | ScalarTag::I32 | ScalarTag::I64 | ScalarTag::I128
                | ScalarTag::U8 | ScalarTag::U16 | ScalarTag::U32 | ScalarTag::U64 | ScalarTag::U128
                | ScalarTag::Isize | ScalarTag::Usize
        )
    }

    pub fn is_float(self) -> bool {
        matches!(self, ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128)
    }

    pub fn is_signed(self) -> bool {
        matches!(
            self,
            ScalarTag::I8 | ScalarTag::I16 | ScalarTag::I32 | ScalarTag::I64 | ScalarTag::I128 | ScalarTag::Isize
        )
    }

    pub fn is_bool(self) -> bool {
        matches!(self, ScalarTag::Bool)
    }

    pub fn is_char(self) -> bool {
        matches!(self, ScalarTag::Char)
    }

    pub fn is_numeric(self) -> bool {
        self.is_int() || self.is_float()
    }

    pub fn name(self) -> &'static str {
        match self {
            ScalarTag::Bool => "bool",
            ScalarTag::Char => "char",
            ScalarTag::I8 => "i8",
            ScalarTag::I16 => "i16",
            ScalarTag::I32 => "i32",
            ScalarTag::I64 => "i64",
            ScalarTag::I128 => "i128",
            ScalarTag::U8 => "u8",
            ScalarTag::U16 => "u16",
            ScalarTag::U32 => "u32",
            ScalarTag::U64 => "u64",
            ScalarTag::U128 => "u128",
            ScalarTag::Isize => "isize",
            ScalarTag::Usize => "usize",
            ScalarTag::F16 => "f16",
            ScalarTag::F32 => "f32",
            ScalarTag::F64 => "f64",
            ScalarTag::F128 => "f128",
        }
    }

    pub fn all() -> &'static [ScalarTag] {
        &[
            ScalarTag::Bool, ScalarTag::Char, ScalarTag::I8, ScalarTag::I16, ScalarTag::I32,
            ScalarTag::I64, ScalarTag::I128, ScalarTag::U8, ScalarTag::U16, ScalarTag::U32,
            ScalarTag::U64, ScalarTag::U128, ScalarTag::Isize, ScalarTag::Usize, ScalarTag::F16,
            ScalarTag::F32, ScalarTag::F64, ScalarTag::F128,
        ]
    }

    pub fn from_name(name: &str) -> Option<ScalarTag> {
        for tag in Self::all() {
            if tag.name() == name {
                return Some(*tag);
            }
        }
        None
    }
}

// ---- ScalarValue union — 16 字节 payload ----

/// 标量值联合体：18 种标量的 payload，由 `ScalarTag` 判别式守护访问
#[derive(Clone, Copy)]
pub union ScalarValue {
    pub b: bool,
    pub cp: u32,
    pub i8_: i8,
    pub i16_: i16,
    pub i32_: i32,
    pub i64_: i64,
    pub i128_: i128,
    pub u8_: u8,
    pub u16_: u16,
    pub u32_: u32,
    pub u64_: u64,
    pub u128_: u128,
    pub isz_: isize,
    pub usz_: usize,
    pub f16_: u16,
    pub f32_: f32,
    pub f64_: f64,
    pub f128_: u128,
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
        Char { codepoint: self.codepoint.wrapping_add(1) }
    }

    pub fn predecessor(self) -> Self {
        Char { codepoint: self.codepoint.wrapping_sub(1) }
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
    pub fn from_str(s: &str) -> Self {
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
        Self::from_str(&buf)
    }
    pub fn equals(&self, other: &Self) -> bool {
        self.inner == other.inner
    }
    pub fn compare(&self, other: &Self) -> Ordering {
        self.inner.cmp(&other.inner)
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
}

impl ArrayValue {
    pub fn new(elements: Vec<Value>) -> Self {
        Self { elements, fixed_size: None, elem_is_ref: false }
    }
    pub fn new_fixed(elements: Vec<Value>, size: u64) -> Self {
        Self { elements, fixed_size: Some(size), elem_is_ref: false }
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
    pub value: Value,
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
    pub inner: Value,
}

/// Cell：可变引用单元
#[derive(Debug, Clone)]
pub struct Cell {
    pub inner: RefCell<Value>,
}

impl Cell {
    pub fn new(val: Value) -> Self {
        Self { inner: RefCell::new(val) }
    }
    pub fn get(&self) -> std::cell::Ref<Value> {
        self.inner.borrow()
    }
    pub fn set(&self, val: Value) {
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
pub type BuiltinFn = fn(&[Value]) -> Result<Value, String>;

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
    pub bound_args: Vec<Value>,
    pub self_upvalue_idx: i32,
    pub upvalue_ref_bits: u8,
    pub cell_upvalues: u8,
}

/// 偏应用值
#[derive(Debug, Clone)]
pub struct PartialApplication {
    pub func_id: u32,
    pub bound_args: Vec<Value>,
    pub remaining_arity: u8,
    pub bound_arg_ref_bits: u16,
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
#[derive(Clone)]
pub struct LazyValue {
    pub cached: Option<Value>,
    pub forced: bool,
    pub thunk: Option<Rc<dyn Fn() -> Value>>,
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

// ---- iterator.rs → ArrayIterator, StringIterator, RangeIterator ----

/// 数组迭代器
#[derive(Debug, Clone)]
pub struct ArrayIterator {
    pub array: Rc<Vec<Value>>,
    pub index: usize,
}

impl ArrayIterator {
    pub fn new(array: Rc<Vec<Value>>) -> Self {
        Self { array, index: 0 }
    }
    pub fn next(&mut self) -> Option<Value> {
        if self.index < self.array.len() {
            let val = self.array[self.index].clone();
            self.index += 1;
            Some(val)
        } else {
            None
        }
    }
}

/// 字符串迭代器
#[derive(Debug, Clone)]
pub struct StringIterator {
    pub string: Rc<str>,
    pub byte_offset: usize,
}

impl StringIterator {
    pub fn new(string: Rc<str>) -> Self {
        Self { string, byte_offset: 0 }
    }
    pub fn next(&mut self) -> Option<u32> {
        if self.byte_offset >= self.string.len() {
            return None;
        }
        let rest = &self.string[self.byte_offset..];
        let c = rest.chars().next()?;
        self.byte_offset += c.len_utf8();
        Some(c as u32)
    }
}

/// 范围迭代器（堆对象）
#[derive(Debug, Clone)]
pub struct RangeIterator {
    pub current: i64,
    pub end: i64,
    pub inclusive: bool,
}

impl RangeIterator {
    pub fn new(start: i64, end: i64, inclusive: bool) -> Self {
        Self { current: start, end, inclusive }
    }
    pub fn next(&mut self) -> Option<i64> {
        if self.inclusive {
            if self.current <= self.end {
                let v = self.current;
                self.current += 1;
                Some(v)
            } else {
                None
            }
        } else if self.current < self.end {
            let v = self.current;
            self.current += 1;
            Some(v)
        } else {
            None
        }
    }
}

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
        self.data.lock().unwrap().clone()
    }
    pub fn store(&self, val: Value) {
        *self.data.lock().unwrap() = val;
    }
    pub fn swap(&self, val: Value) -> Value {
        std::mem::replace(&mut *self.data.lock().unwrap(), val)
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
    result: Mutex<Option<Value>>,
}

impl AsyncHandle {
    pub fn new() -> Self {
        Self { status: Mutex::new(AsyncStatus::Pending), result: Mutex::new(None) }
    }
    pub fn status(&self) -> AsyncStatus {
        *self.status.lock().unwrap()
    }
    pub fn set_status(&self, status: AsyncStatus) {
        *self.status.lock().unwrap() = status;
    }
    pub fn result(&self) -> Option<Value> {
        self.result.lock().unwrap().clone()
    }
    pub fn set_result(&self, val: Value) {
        *self.result.lock().unwrap() = Some(val);
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
    buffer: Mutex<Vec<Value>>,
    capacity: usize,
    closed: Mutex<bool>,
}

impl ChannelValue {
    pub fn new(capacity: usize) -> Self {
        Self { buffer: Mutex::new(Vec::new()), capacity, closed: Mutex::new(false) }
    }
    pub fn send(&self, val: Value) -> Result<(), String> {
        if *self.closed.lock().unwrap() {
            return Err("channel closed".to_string());
        }
        let mut buf = self.buffer.lock().unwrap();
        if self.capacity > 0 && buf.len() >= self.capacity {
            return Err("channel full".to_string());
        }
        buf.push(val);
        Ok(())
    }
    pub fn recv(&self) -> Option<Value> {
        let mut buf = self.buffer.lock().unwrap();
        if !buf.is_empty() {
            Some(buf.remove(0))
        } else {
            None
        }
    }
    pub fn try_send(&self, val: Value) -> Result<(), String> {
        self.send(val)
    }
    pub fn try_recv(&self) -> Option<Value> {
        self.recv()
    }
    pub fn close(&self) {
        *self.closed.lock().unwrap() = true;
    }
    pub fn is_closed(&self) -> bool {
        *self.closed.lock().unwrap()
    }
}

impl Clone for ChannelValue {
    fn clone(&self) -> Self {
        let buf = self.buffer.lock().unwrap().clone();
        Self { buffer: Mutex::new(buf), capacity: self.capacity, closed: Mutex::new(*self.closed.lock().unwrap()) }
    }
}

/// 发送端值
#[derive(Debug, Clone)]
pub struct SenderValue {
    pub channel: Rc<ChannelValue>,
}

/// 接收端值
#[derive(Debug, Clone)]
pub struct ReceiverValue {
    pub channel: Rc<ChannelValue>,
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
    ArrayIter(ArrayIterator),
    StringIter(StringIterator),
    RangeIter(RangeIterator),
    AtomicVal(AtomicValue),
    AsyncVal(AsyncHandle),
    ChannelVal(ChannelValue),
    SenderVal(SenderValue),
    ReceiverVal(ReceiverValue),
    CoroutineFrame,
}

/// 堆引用：引用计数的堆对象
pub type HeapRef = Rc<HeapObj>;

/// 引用类型枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefKind {
    Str, Array, Record, Adt, Newtype, Cell, Range, Closure, Partial, Builtin,
    TraitVal, LazyVal, ErrorVal, ThrowVal, ArrayIter, StringIter, RangeIter,
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
            HeapObj::ArrayIter(_) => RefKind::ArrayIter,
            HeapObj::StringIter(_) => RefKind::StringIter,
            HeapObj::RangeIter(_) => RefKind::RangeIter,
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
            HeapObj::ArrayIter(_) => "array_iter",
            HeapObj::StringIter(_) => "string_iter",
            HeapObj::RangeIter(_) => "range_iter",
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
            HeapObj::ArrayIter(_) => "<iter>",
            HeapObj::StringIter(_) => "<iter>",
            HeapObj::RangeIter(_) => "<iter>",
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
                for e in &a.elements {
                    e.hash(state);
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
            HeapObj::ArrayIter(a) => a.index.hash(state),
            HeapObj::StringIter(s) => s.byte_offset.hash(state),
            HeapObj::RangeIter(r) => {
                r.current.hash(state);
                r.end.hash(state);
                r.inclusive.hash(state);
            }
            HeapObj::Partial(_) | HeapObj::TraitVal(_) | HeapObj::LazyVal(_)
            | HeapObj::AtomicVal(_) | HeapObj::AsyncVal(_) | HeapObj::ChannelVal(_)
            | HeapObj::SenderVal(_) | HeapObj::ReceiverVal(_) | HeapObj::CoroutineFrame => {}
        }
    }
}

// =========================================================================
// 第三部分：Value enum（4 变体）
// =========================================================================

/// Glue 统一值：标量内联 + 堆对象引用
#[derive(Clone)]
pub enum Value {
    Null,
    Void,
    Scalar(ScalarValue, ScalarTag),
    Ref(HeapRef),
}

impl Default for Value {
    fn default() -> Self {
        Value::Void
    }
}

// =========================================================================
// 第四部分：宏生成标量 API
// =========================================================================

macro_rules! impl_scalar_api {
    ($($tag:ident => $ctor:ident / $field:ident / $acc:ident : $ty:ty);* $(;)?) => {
        impl Value {
            $(
                #[inline]
                pub fn $ctor(v: $ty) -> Self {
                    Value::Scalar(ScalarValue { $field: v }, ScalarTag::$tag)
                }

                #[inline]
                pub fn $acc(&self) -> Option<$ty> {
                    match self {
                        Value::Scalar(sv, t) if *t == ScalarTag::$tag => {
                            Some(unsafe { sv.$field })
                        }
                        _ => None,
                    }
                }
            )*
        }
    };
}

impl_scalar_api! {
    Bool => bool / b / as_bool : bool;
    I8 => i8 / i8_ / as_i8 : i8;
    I16 => i16 / i16_ / as_i16 : i16;
    I32 => i32 / i32_ / as_i32 : i32;
    I64 => i64 / i64_ / as_i64 : i64;
    I128 => i128 / i128_ / as_i128 : i128;
    U8 => u8 / u8_ / as_u8 : u8;
    U16 => u16 / u16_ / as_u16 : u16;
    U32 => u32 / u32_ / as_u32 : u32;
    U64 => u64 / u64_ / as_u64 : u64;
    U128 => u128 / u128_ / as_u128 : u128;
    Isize => isize / isz_ / as_isize : isize;
    Usize => usize / usz_ / as_usize : usize;
    F32 => f32 / f32_ / as_f32 : f32;
    F64 => f64 / f64_ / as_f64 : f64;
}

// ---- Char / F16 / F128 特殊构造器与访问器 ----

impl Value {
    /// 构造字符值
    pub fn char(c: Char) -> Self {
        Value::Scalar(ScalarValue { cp: c.codepoint }, ScalarTag::Char)
    }

    /// 从 codepoint 构造字符值（不校验）
    pub fn char_from_codepoint(cp: u32) -> Self {
        Value::Scalar(ScalarValue { cp }, ScalarTag::Char)
    }

    /// 从 Rust `char` 构造字符值
    pub fn from_rust_char(c: char) -> Self {
        Value::Scalar(ScalarValue { cp: c as u32 }, ScalarTag::Char)
    }

    /// 转为 `Char`
    pub fn as_char(&self) -> Option<Char> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::Char => {
                Some(Char::from_codepoint_unchecked(unsafe { sv.cp }))
            }
            _ => None,
        }
    }

    /// 构造 F16 值
    pub fn f16(v: F16) -> Self {
        Value::Scalar(ScalarValue { f16_: v.0 }, ScalarTag::F16)
    }

    /// 转为 `F16`
    pub fn as_f16(&self) -> Option<F16> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::F16 => {
                Some(F16(unsafe { sv.f16_ }))
            }
            _ => None,
        }
    }

    /// 构造 F128 值
    pub fn f128(v: F128) -> Self {
        Value::Scalar(ScalarValue { f128_: u128::from_le_bytes(v.0) }, ScalarTag::F128)
    }

    /// 转为 `F128`
    pub fn as_f128(&self) -> Option<F128> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::F128 => {
                Some(F128(unsafe { sv.f128_ }.to_le_bytes()))
            }
            _ => None,
        }
    }
}

// =========================================================================
// 第五部分：宏生成堆访问器
// =========================================================================

macro_rules! impl_heap_accessors {
    ($($method:ident => $variant:ident as $ty:ty);* $(;)?) => {
        impl Value {
            $(
                #[inline]
                pub fn $method(&self) -> Option<&$ty> {
                    match self {
                        Value::Ref(r) => match r.as_ref() {
                            HeapObj::$variant(v) => Some(v),
                            _ => None,
                        },
                        _ => None,
                    }
                }
            )*
        }
    };
}

impl_heap_accessors! {
    as_str => Str as GlueStr;
    as_array => Array as ArrayValue;
    as_record => Record as RecordValue;
    as_adt => Adt as AdtValue;
    as_newtype => Newtype as NewtypeValue;
    as_cell => Cell as Cell;
    as_range => Range as Range;
    as_closure => Closure as Closure;
    as_partial => Partial as PartialApplication;
    as_builtin => Builtin as Builtin;
    as_trait_val => TraitVal as TraitValue;
    as_lazy => LazyVal as LazyValue;
    as_error_val => ErrorVal as ErrorValue;
    as_throw_val => ThrowVal as ThrowValue;
    as_array_iter => ArrayIter as ArrayIterator;
    as_string_iter => StringIter as StringIterator;
    as_range_iter_obj => RangeIter as RangeIterator;
    as_atomic => AtomicVal as AtomicValue;
    as_async_handle => AsyncVal as AsyncHandle;
    as_channel => ChannelVal as ChannelValue;
    as_sender => SenderVal as SenderValue;
    as_receiver => ReceiverVal as ReceiverValue;
}

// =========================================================================
// 第十五部分：堆构造器（来自 mod.rs）
// =========================================================================

impl Value {
    /// 构造 `null` 值
    pub fn null() -> Self {
        Value::Null
    }

    /// 构造 `void` 唯一值
    pub fn void() -> Self {
        Value::Void
    }

    /// 包装任意堆对象为 `Value`
    pub fn heap(obj: HeapObj) -> Self {
        Value::Ref(Rc::new(obj))
    }

    /// 从 `HeapRef` 构造
    pub fn from_ref(r: HeapRef) -> Self {
        Value::Ref(r)
    }

    /// 构造字符串值
    pub fn str(s: impl Into<String>) -> Self {
        Value::heap(HeapObj::Str(GlueStr::new(s)))
    }

    /// 从 `&str` 构造字符串值（共享）
    pub fn str_from(s: &str) -> Self {
        Value::heap(HeapObj::Str(GlueStr::from_str(s)))
    }

    /// 构造字符串值（从 `GlueStr`）
    pub fn from_glue_str(s: GlueStr) -> Self {
        Value::heap(HeapObj::Str(s))
    }

    /// 构造动态数组值
    pub fn array(elements: Vec<Value>) -> Self {
        Value::heap(HeapObj::Array(ArrayValue::new(elements)))
    }

    /// 构造固定大小数组值
    pub fn array_fixed(elements: Vec<Value>, size: u64) -> Self {
        Value::heap(HeapObj::Array(ArrayValue::new_fixed(elements, size)))
    }

    /// 构造记录值
    pub fn record(
        type_name: impl Into<String>,
        fields: Vec<Value>,
        field_names: Vec<Option<String>>,
    ) -> Self {
        Value::heap(HeapObj::Record(RecordValue::new(
            type_name.into(),
            fields,
            field_names,
        )))
    }

    /// 构造 ADT 值
    pub fn adt(
        type_name: impl Into<String>,
        constructor: impl Into<String>,
        fields: Vec<AdtField>,
    ) -> Self {
        Value::heap(HeapObj::Adt(AdtValue::new(
            type_name.into(),
            constructor.into(),
            fields,
        )))
    }

    /// 构造 Newtype 值
    pub fn newtype(type_name: impl Into<String>, inner: Value) -> Self {
        Value::heap(HeapObj::Newtype(NewtypeValue { type_name: type_name.into(), inner }))
    }

    /// 构造 Cell 值
    pub fn cell(val: Value) -> Self {
        Value::heap(HeapObj::Cell(Cell::new(val)))
    }

    /// 构造 Range 值
    pub fn range(start: i64, end: i64, inclusive: bool) -> Self {
        Value::heap(HeapObj::Range(Range::new(start, end, inclusive)))
    }

    /// 构造闭包值
    pub fn closure(c: Closure) -> Self {
        Value::heap(HeapObj::Closure(c))
    }

    /// 构造偏应用值
    pub fn partial(p: PartialApplication) -> Self {
        Value::heap(HeapObj::Partial(p))
    }

    /// 构造内建函数值
    pub fn builtin(fn_ptr: BuiltinFn, name: impl Into<String>) -> Self {
        Value::heap(HeapObj::Builtin(Builtin { fn_ptr, name: name.into() }))
    }

    /// 构造 Trait 值
    pub fn trait_val(t: TraitValue) -> Self {
        Value::heap(HeapObj::TraitVal(t))
    }

    /// 构造惰性值
    pub fn lazy(l: LazyValue) -> Self {
        Value::heap(HeapObj::LazyVal(l))
    }

    /// 构造错误值
    pub fn error_val(
        type_name: impl Into<String>,
        message: impl Into<String>,
        is_error_subtype: bool,
    ) -> Self {
        Value::heap(HeapObj::ErrorVal(ErrorValue {
            type_name: type_name.into(),
            message: message.into(),
            is_error_subtype,
        }))
    }

    /// 构造 `Ok` 抛出值
    pub fn throw_ok(val: Value) -> Self {
        Value::heap(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Ok(val) }))
    }

    /// 构造 `Err` 抛出值
    pub fn throw_err(record: Rc<RecordValue>) -> Self {
        Value::heap(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    }

    /// 构造数组迭代器
    pub fn array_iter(array: Rc<Vec<Value>>) -> Self {
        Value::heap(HeapObj::ArrayIter(ArrayIterator::new(array)))
    }

    /// 构造字符串迭代器
    pub fn string_iter(s: Rc<str>) -> Self {
        Value::heap(HeapObj::StringIter(StringIterator::new(s)))
    }

    /// 构造范围迭代器
    pub fn range_iter(start: i64, end: i64, inclusive: bool) -> Self {
        Value::heap(HeapObj::RangeIter(RangeIterator::new(start, end, inclusive)))
    }

    /// 构造原子值
    pub fn atomic(val: Value) -> Self {
        Value::heap(HeapObj::AtomicVal(AtomicValue::new(val)))
    }

    /// 构造异步句柄
    pub fn async_handle() -> Self {
        Value::heap(HeapObj::AsyncVal(AsyncHandle::new()))
    }

    /// 构造通道值
    pub fn channel(capacity: usize) -> Self {
        Value::heap(HeapObj::ChannelVal(ChannelValue::new(capacity)))
    }

    /// 构造发送端
    pub fn sender(channel: Rc<ChannelValue>) -> Self {
        Value::heap(HeapObj::SenderVal(SenderValue { channel }))
    }

    /// 构造接收端
    pub fn receiver(channel: Rc<ChannelValue>) -> Self {
        Value::heap(HeapObj::ReceiverVal(ReceiverValue { channel }))
    }

    /// 转为堆引用
    pub fn as_ref(&self) -> Option<&HeapRef> {
        match self {
            Value::Ref(r) => Some(r),
            _ => None,
        }
    }

    /// 获取堆对象引用类型（若为堆对象）
    pub fn ref_kind(&self) -> Option<RefKind> {
        match self {
            Value::Ref(r) => Some(r.ref_kind()),
            _ => None,
        }
    }

    /// 从 `i64` 按 `tag` 构造对应整数（用于 IR 加载立即数）
    pub fn int_from_i64(tag: ScalarTag, v: i64) -> Self {
        match tag {
            ScalarTag::I8 => Value::Scalar(ScalarValue { i8_: v as i8 }, ScalarTag::I8),
            ScalarTag::I16 => Value::Scalar(ScalarValue { i16_: v as i16 }, ScalarTag::I16),
            ScalarTag::I32 => Value::Scalar(ScalarValue { i32_: v as i32 }, ScalarTag::I32),
            ScalarTag::I64 => Value::Scalar(ScalarValue { i64_: v }, ScalarTag::I64),
            ScalarTag::I128 => Value::Scalar(ScalarValue { i128_: v as i128 }, ScalarTag::I128),
            ScalarTag::U8 => Value::Scalar(ScalarValue { u8_: v as u8 }, ScalarTag::U8),
            ScalarTag::U16 => Value::Scalar(ScalarValue { u16_: v as u16 }, ScalarTag::U16),
            ScalarTag::U32 => Value::Scalar(ScalarValue { u32_: v as u32 }, ScalarTag::U32),
            ScalarTag::U64 => Value::Scalar(ScalarValue { u64_: v as u64 }, ScalarTag::U64),
            ScalarTag::U128 => Value::Scalar(ScalarValue { u128_: v as u128 }, ScalarTag::U128),
            ScalarTag::Isize => Value::Scalar(ScalarValue { isz_: v as isize }, ScalarTag::Isize),
            ScalarTag::Usize => Value::Scalar(ScalarValue { usz_: v as usize }, ScalarTag::Usize),
            _ => Value::Scalar(ScalarValue { i64_: v }, ScalarTag::I64),
        }
    }
}

// =========================================================================
// 第六部分：谓词 + type_name + scalar_tag
// =========================================================================

impl Value {
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn is_void(&self) -> bool {
        matches!(self, Value::Void)
    }

    pub fn is_bool(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if *t == ScalarTag::Bool)
    }

    pub fn is_char(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if *t == ScalarTag::Char)
    }

    pub fn is_int(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if t.is_int())
    }

    pub fn is_float(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if t.is_float())
    }

    pub fn is_numeric(&self) -> bool {
        self.is_int() || self.is_float()
    }

    pub fn is_scalar(&self) -> bool {
        self.is_bool() || self.is_char() || self.is_numeric()
    }

    pub fn is_string(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(), HeapObj::Str(_)))
    }

    pub fn is_array(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(), HeapObj::Array(_)))
    }

    pub fn is_record(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(), HeapObj::Record(_)))
    }

    pub fn is_adt(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(), HeapObj::Adt(_)))
    }

    pub fn is_closure(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(), HeapObj::Closure(_)))
    }

    pub fn is_ref(&self) -> bool {
        matches!(self, Value::Ref(_))
    }

    pub fn is_callable(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(
                r.as_ref(),
                HeapObj::Closure(_) | HeapObj::Partial(_) | HeapObj::Builtin(_) | HeapObj::TraitVal(_)
            )
        )
    }

    pub fn requires_release(&self) -> bool {
        self.is_ref()
    }

    /// 获取值的类型名称
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Void => "void",
            Value::Scalar(_, tag) => tag.name(),
            Value::Ref(r) => r.type_name(),
        }
    }

    /// 获取对应的标量标签（若为标量）
    pub fn scalar_tag(&self) -> Option<ScalarTag> {
        match self {
            Value::Scalar(_, tag) => Some(*tag),
            _ => None,
        }
    }

    /// 将整数标量统一提升为 `i64`
    pub fn as_int_i64(&self) -> Option<i64> {
        match self {
            Value::Scalar(sv, tag) if tag.is_int() => unsafe {
                Some(match *tag {
                    ScalarTag::I8 => sv.i8_ as i64,
                    ScalarTag::I16 => sv.i16_ as i64,
                    ScalarTag::I32 => sv.i32_ as i64,
                    ScalarTag::I64 => sv.i64_,
                    ScalarTag::I128 => sv.i128_ as i64,
                    ScalarTag::U8 => sv.u8_ as i64,
                    ScalarTag::U16 => sv.u16_ as i64,
                    ScalarTag::U32 => sv.u32_ as i64,
                    ScalarTag::U64 => sv.u64_ as i64,
                    ScalarTag::U128 => sv.u128_ as i64,
                    ScalarTag::Isize => sv.isz_ as i64,
                    ScalarTag::Usize => sv.usz_ as i64,
                    _ => unreachable!(),
                })
            },
            _ => None,
        }
    }

    /// 将整数标量统一提升为 `i128`
    pub fn as_int_i128(&self) -> Option<i128> {
        match self {
            Value::Scalar(sv, tag) if tag.is_int() => unsafe {
                Some(match *tag {
                    ScalarTag::I8 => sv.i8_ as i128,
                    ScalarTag::I16 => sv.i16_ as i128,
                    ScalarTag::I32 => sv.i32_ as i128,
                    ScalarTag::I64 => sv.i64_ as i128,
                    ScalarTag::I128 => sv.i128_,
                    ScalarTag::U8 => sv.u8_ as i128,
                    ScalarTag::U16 => sv.u16_ as i128,
                    ScalarTag::U32 => sv.u32_ as i128,
                    ScalarTag::U64 => sv.u64_ as i128,
                    ScalarTag::U128 => sv.u128_ as i128,
                    ScalarTag::Isize => sv.isz_ as i128,
                    ScalarTag::Usize => sv.usz_ as i128,
                    _ => unreachable!(),
                })
            },
            _ => None,
        }
    }

    /// 将浮点标量统一提升为 `f64`
    pub fn as_float_f64(&self) -> Option<f64> {
        match self {
            Value::Scalar(sv, tag) if tag.is_float() => unsafe {
                Some(match *tag {
                    ScalarTag::F16 => F16(sv.f16_).to_f64(),
                    ScalarTag::F32 => sv.f32_ as f64,
                    ScalarTag::F64 => sv.f64_,
                    ScalarTag::F128 => F128(sv.f128_.to_le_bytes()).to_f64(),
                    _ => unreachable!(),
                })
            },
            _ => None,
        }
    }
}

// =========================================================================
// 第七部分：equals（ptr_eq 快速路径）
// =========================================================================

const EQUALS_MAX_DEPTH: u32 = 4096;

impl Value {
    pub fn equals(&self, other: &Value) -> bool {
        equals_impl(self, other, 0)
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        self.equals(other)
    }
}

impl Eq for Value {}

fn equals_impl(a: &Value, b: &Value, depth: u32) -> bool {
    if depth > EQUALS_MAX_DEPTH {
        return false;
    }
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::Void, Value::Void) => true,
        (Value::Scalar(sva, ta), Value::Scalar(svb, tb)) => {
            if ta != tb {
                return false;
            }
            scalar_equals(sva, svb, *ta)
        }
        (Value::Ref(x), Value::Ref(y)) => {
            if Rc::ptr_eq(x, y) {
                return true;
            }
            heap_equals(x, y, depth + 1)
        }
        _ => false,
    }
}

fn scalar_equals(a: &ScalarValue, b: &ScalarValue, tag: ScalarTag) -> bool {
    unsafe {
        match tag {
            ScalarTag::Bool => a.b == b.b,
            ScalarTag::Char => a.cp == b.cp,
            ScalarTag::I8 => a.i8_ == b.i8_,
            ScalarTag::I16 => a.i16_ == b.i16_,
            ScalarTag::I32 => a.i32_ == b.i32_,
            ScalarTag::I64 => a.i64_ == b.i64_,
            ScalarTag::I128 => a.i128_ == b.i128_,
            ScalarTag::U8 => a.u8_ == b.u8_,
            ScalarTag::U16 => a.u16_ == b.u16_,
            ScalarTag::U32 => a.u32_ == b.u32_,
            ScalarTag::U64 => a.u64_ == b.u64_,
            ScalarTag::U128 => a.u128_ == b.u128_,
            ScalarTag::Isize => a.isz_ == b.isz_,
            ScalarTag::Usize => a.usz_ == b.usz_,
            ScalarTag::F16 => a.f16_ == b.f16_,
            ScalarTag::F32 => a.f32_.to_bits() == b.f32_.to_bits(),
            ScalarTag::F64 => a.f64_.to_bits() == b.f64_.to_bits(),
            ScalarTag::F128 => a.f128_ == b.f128_,
        }
    }
}

fn heap_equals(a: &HeapObj, b: &HeapObj, depth: u32) -> bool {
    if depth > EQUALS_MAX_DEPTH {
        return false;
    }

    match (a, b) {
        (HeapObj::Str(x), HeapObj::Str(y)) => x.equals(y),
        (HeapObj::Array(x), HeapObj::Array(y)) => {
            if x.elements.len() != y.elements.len() {
                return false;
            }
            for (xe, ye) in x.elements.iter().zip(y.elements.iter()) {
                if !equals_impl(xe, ye, depth + 1) {
                    return false;
                }
            }
            x.fixed_size == y.fixed_size
        }
        (HeapObj::Record(x), HeapObj::Record(y)) => {
            if x.type_name != y.type_name || x.fields.len() != y.fields.len() {
                return false;
            }
            for (xf, yf) in x.fields.iter().zip(y.fields.iter()) {
                if !equals_impl(xf, yf, depth + 1) {
                    return false;
                }
            }
            x.field_names == y.field_names
        }
        (HeapObj::Adt(x), HeapObj::Adt(y)) => {
            if x.type_name != y.type_name || x.constructor != y.constructor {
                return false;
            }
            if x.fields.len() != y.fields.len() {
                return false;
            }
            for (xf, yf) in x.fields.iter().zip(y.fields.iter()) {
                if !equals_impl(&xf.value, &yf.value, depth + 1) {
                    return false;
                }
            }
            true
        }
        (HeapObj::Newtype(x), HeapObj::Newtype(y)) => {
            x.type_name == y.type_name && equals_impl(&x.inner, &y.inner, depth + 1)
        }
        (HeapObj::Cell(x), HeapObj::Cell(y)) => {
            let xb = x.get();
            let yb = y.get();
            equals_impl(&xb, &yb, depth + 1)
        }
        (HeapObj::Range(x), HeapObj::Range(y)) => {
            x.start == y.start && x.end == y.end && x.inclusive == y.inclusive
        }
        (HeapObj::ErrorVal(x), HeapObj::ErrorVal(y)) => {
            x.type_name == y.type_name && x.message == y.message && x.is_error_subtype == y.is_error_subtype
        }
        (HeapObj::ThrowVal(x), HeapObj::ThrowVal(y)) => match (&x.payload, &y.payload) {
            (ThrowPayload::Ok(a), ThrowPayload::Ok(b)) => equals_impl(a, b, depth + 1),
            (ThrowPayload::Err(a), ThrowPayload::Err(b)) => Rc::ptr_eq(a, b),
            _ => false,
        },
        (HeapObj::Closure(x), HeapObj::Closure(y)) => {
            x.func_id == y.func_id && x.arity == y.arity && x.upvalues.len() == y.upvalues.len()
        }
        (HeapObj::Builtin(x), HeapObj::Builtin(y)) => {
            x.fn_ptr as usize == y.fn_ptr as usize && x.name == y.name
        }
        (HeapObj::ArrayIter(x), HeapObj::ArrayIter(y)) => x.index == y.index,
        (HeapObj::StringIter(x), HeapObj::StringIter(y)) => x.byte_offset == y.byte_offset,
        (HeapObj::RangeIter(x), HeapObj::RangeIter(y)) => {
            x.current == y.current && x.end == y.end && x.inclusive == y.inclusive
        }
        _ => false,
    }
}

// =========================================================================
// 第八部分：deep_clone（ptr_eq 缓存）
// =========================================================================

const DEEP_CLONE_MAX_DEPTH: u32 = 4096;

impl Value {
    pub fn deep_clone(&self) -> Value {
        let mut cache: HashMap<*const HeapObj, HeapRef> = HashMap::new();
        deep_clone_impl(self, 0, &mut cache)
    }
}

fn deep_clone_impl(
    v: &Value,
    depth: u32,
    cache: &mut HashMap<*const HeapObj, HeapRef>,
) -> Value {
    if depth > DEEP_CLONE_MAX_DEPTH {
        return v.clone();
    }
    match v {
        Value::Ref(r) => {
            let key = Rc::as_ptr(r);
            if let Some(cached) = cache.get(&key) {
                return Value::Ref(cached.clone());
            }
            let cloned = Rc::new(heap_deep_clone(r, depth + 1, cache));
            cache.insert(key, cloned.clone());
            Value::Ref(cloned)
        }
        other => other.clone(),
    }
}

fn heap_deep_clone(
    obj: &HeapObj,
    depth: u32,
    cache: &mut HashMap<*const HeapObj, HeapRef>,
) -> HeapObj {
    if depth > DEEP_CLONE_MAX_DEPTH {
        return obj.clone();
    }
    match obj {
        HeapObj::Str(s) => HeapObj::Str(s.clone()),
        HeapObj::Array(a) => {
            let elements: Vec<Value> = a.elements.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Array(ArrayValue {
                elements,
                fixed_size: a.fixed_size,
                elem_is_ref: a.elem_is_ref,
            })
        }
        HeapObj::Record(r) => {
            let fields: Vec<Value> = r.fields.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Record(RecordValue {
                type_name: r.type_name.clone(),
                fields,
                field_names: r.field_names.clone(),
                field_ref_bits: r.field_ref_bits,
            })
        }
        HeapObj::Adt(a) => {
            let fields: Vec<AdtField> = a
                .fields
                .iter()
                .map(|f| AdtField {
                    name: f.name.clone(),
                    value: deep_clone_impl(&f.value, depth + 1, cache),
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
            inner: deep_clone_impl(&n.inner, depth + 1, cache),
        }),
        HeapObj::Cell(c) => {
            let inner = c.get();
            HeapObj::Cell(Cell::new(deep_clone_impl(&inner, depth + 1, cache)))
        }
        HeapObj::Range(r) => HeapObj::Range(r.clone()),
        HeapObj::Closure(c) => {
            let upvalues: Vec<Value> = c.upvalues.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            let bound_args: Vec<Value> = c.bound_args.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
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
            let bound_args: Vec<Value> = p.bound_args.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Partial(PartialApplication {
                func_id: p.func_id,
                bound_args,
                remaining_arity: p.remaining_arity,
                bound_arg_ref_bits: p.bound_arg_ref_bits,
            })
        }
        HeapObj::Builtin(b) => HeapObj::Builtin(b.clone()),
        HeapObj::TraitVal(t) => {
            let method_values: Vec<Value> =
                t.method_values.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::TraitVal(TraitValue {
                trait_name: t.trait_name.clone(),
                method_names: t.method_names.clone(),
                method_values,
                data: t.data.as_ref().map(|d| deep_clone_impl(d, depth + 1, cache)),
                owned: t.owned,
            })
        }
        HeapObj::LazyVal(l) => {
            let cached = l.cached.as_ref().map(|c| deep_clone_impl(c, depth + 1, cache));
            HeapObj::LazyVal(LazyValue {
                cached,
                forced: l.forced,
                thunk: l.thunk.clone(),
            })
        }
        HeapObj::ErrorVal(e) => HeapObj::ErrorVal(e.clone()),
        HeapObj::ThrowVal(t) => {
            let payload = match &t.payload {
                ThrowPayload::Ok(v) => ThrowPayload::Ok(deep_clone_impl(v, depth + 1, cache)),
                ThrowPayload::Err(r) => ThrowPayload::Err(r.clone()),
            };
            HeapObj::ThrowVal(ThrowValue { payload })
        }
        HeapObj::ArrayIter(a) => HeapObj::ArrayIter(a.clone()),
        HeapObj::StringIter(s) => HeapObj::StringIter(s.clone()),
        HeapObj::RangeIter(r) => HeapObj::RangeIter(r.clone()),
        HeapObj::AtomicVal(a) => {
            let val = a.load();
            HeapObj::AtomicVal(AtomicValue::new(deep_clone_impl(&val, depth + 1, cache)))
        }
        HeapObj::AsyncVal(a) => HeapObj::AsyncVal(a.clone()),
        HeapObj::ChannelVal(c) => HeapObj::ChannelVal(c.clone()),
        HeapObj::SenderVal(s) => HeapObj::SenderVal(s.clone()),
        HeapObj::ReceiverVal(r) => HeapObj::ReceiverVal(r.clone()),
        HeapObj::CoroutineFrame => HeapObj::CoroutineFrame,
    }
}

// =========================================================================
// 第九部分：Hash impl
// =========================================================================

impl Hash for Value {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            Value::Null | Value::Void => {}
            Value::Scalar(sv, tag) => {
                tag.hash(state);
                unsafe {
                    match *tag {
                        ScalarTag::Bool => sv.b.hash(state),
                        ScalarTag::Char => sv.cp.hash(state),
                        ScalarTag::I8 => sv.i8_.hash(state),
                        ScalarTag::I16 => sv.i16_.hash(state),
                        ScalarTag::I32 => sv.i32_.hash(state),
                        ScalarTag::I64 => sv.i64_.hash(state),
                        ScalarTag::I128 => sv.i128_.hash(state),
                        ScalarTag::U8 => sv.u8_.hash(state),
                        ScalarTag::U16 => sv.u16_.hash(state),
                        ScalarTag::U32 => sv.u32_.hash(state),
                        ScalarTag::U64 => sv.u64_.hash(state),
                        ScalarTag::U128 => sv.u128_.hash(state),
                        ScalarTag::Isize => sv.isz_.hash(state),
                        ScalarTag::Usize => sv.usz_.hash(state),
                        ScalarTag::F16 => sv.f16_.hash(state),
                        ScalarTag::F32 => sv.f32_.to_bits().hash(state),
                        ScalarTag::F64 => sv.f64_.to_bits().hash(state),
                        ScalarTag::F128 => sv.f128_.hash(state),
                    }
                }
            }
            Value::Ref(r) => {
                r.hash(state);
            }
        }
    }
}

// =========================================================================
// 第十部分：Debug / Display impl
// =========================================================================

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Scalar(sv, tag) => unsafe {
                match *tag {
                    ScalarTag::Bool => write!(f, "{}", sv.b),
                    ScalarTag::Char => write!(f, "'{}'", Char::from_codepoint_unchecked(sv.cp)),
                    ScalarTag::I8 => write!(f, "{}i8", sv.i8_),
                    ScalarTag::I16 => write!(f, "{}i16", sv.i16_),
                    ScalarTag::I32 => write!(f, "{}", sv.i32_),
                    ScalarTag::I64 => write!(f, "{}i64", sv.i64_),
                    ScalarTag::I128 => write!(f, "{}i128", sv.i128_),
                    ScalarTag::U8 => write!(f, "{}u8", sv.u8_),
                    ScalarTag::U16 => write!(f, "{}u16", sv.u16_),
                    ScalarTag::U32 => write!(f, "{}u32", sv.u32_),
                    ScalarTag::U64 => write!(f, "{}u64", sv.u64_),
                    ScalarTag::U128 => write!(f, "{}u128", sv.u128_),
                    ScalarTag::Isize => write!(f, "{}isize", sv.isz_),
                    ScalarTag::Usize => write!(f, "{}usize", sv.usz_),
                    ScalarTag::F16 => write!(f, "{:?}", F16(sv.f16_)),
                    ScalarTag::F32 => write!(f, "{}f32", sv.f32_),
                    ScalarTag::F64 => write!(f, "{}", sv.f64_),
                    ScalarTag::F128 => write!(f, "{:?}", F128(sv.f128_.to_le_bytes())),
                }
            },
            Value::Ref(r) => write!(f, "{:?}", r),
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Scalar(sv, tag) => unsafe {
                match *tag {
                    ScalarTag::Bool => write!(f, "{}", sv.b),
                    ScalarTag::Char => write!(f, "{}", Char::from_codepoint_unchecked(sv.cp)),
                    ScalarTag::I8 => write!(f, "{}", sv.i8_),
                    ScalarTag::I16 => write!(f, "{}", sv.i16_),
                    ScalarTag::I32 => write!(f, "{}", sv.i32_),
                    ScalarTag::I64 => write!(f, "{}", sv.i64_),
                    ScalarTag::I128 => write!(f, "{}", sv.i128_),
                    ScalarTag::U8 => write!(f, "{}", sv.u8_),
                    ScalarTag::U16 => write!(f, "{}", sv.u16_),
                    ScalarTag::U32 => write!(f, "{}", sv.u32_),
                    ScalarTag::U64 => write!(f, "{}", sv.u64_),
                    ScalarTag::U128 => write!(f, "{}", sv.u128_),
                    ScalarTag::Isize => write!(f, "{}", sv.isz_),
                    ScalarTag::Usize => write!(f, "{}", sv.usz_),
                    ScalarTag::F16 => write!(f, "{}", F16(sv.f16_).to_f32()),
                    ScalarTag::F32 => write!(f, "{}", sv.f32_),
                    ScalarTag::F64 => write!(f, "{}", sv.f64_),
                    ScalarTag::F128 => write!(f, "{}", F128(sv.f128_.to_le_bytes()).to_f64()),
                }
            },
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Str(s) => write!(f, "{}", s),
                _ => write!(f, "{:?}", r),
            },
        }
    }
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

pub fn cast_value(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Vec<u8> {
    let dst_width = dst_tag.byte_width();
    let mut result = vec![0u8; dst_width];

    if src_tag == dst_tag {
        let copy_len = src_bytes.len().min(dst_width);
        result[..copy_len].copy_from_slice(&src_bytes[..copy_len]);
        return result;
    }

    match (src_tag, dst_tag) {
        (ScalarTag::Bool, _) => {
            let b = read_bool(src_bytes);
            cast_from_bool(b, dst_tag, &mut result);
        }
        (ScalarTag::Char, _) => {
            let cp = read_u32_le(src_bytes);
            cast_from_u32(cp, dst_tag, &mut result);
        }
        (_, ScalarTag::Bool) => {
            let b = cast_to_bool(src_tag, src_bytes);
            write_bool(b, &mut result);
        }
        (_, ScalarTag::Char) => {
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

pub fn try_cast_value(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    if src_tag == dst_tag {
        return Ok(cast_value(src_tag, src_bytes, dst_tag));
    }

    if src_tag.is_int() && dst_tag == ScalarTag::Char {
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

pub fn parse_str(s: &str, dst_tag: ScalarTag) -> Result<Vec<u8>, ParseError> {
    let trimmed = s.trim();
    let result = vec![0u8; dst_tag.byte_width()];

    if trimmed.is_empty() {
        return Err(ParseError::ParseFailed("empty string".to_string()));
    }

    let mut result = result;

    match dst_tag {
        ScalarTag::Bool => {
            let b = match trimmed.to_ascii_lowercase().as_str() {
                "true" => true,
                "false" => false,
                _ => return Err(ParseError::ParseFailed(format!("invalid bool: {}", s))),
            };
            write_bool(b, &mut result);
        }
        ScalarTag::Char => {
            let mut chars = trimmed.chars();
            let c = chars.next().ok_or_else(|| ParseError::ParseFailed("empty char".to_string()))?;
            if chars.next().is_some() {
                return Err(ParseError::ParseFailed("char must be single character".to_string()));
            }
            write_u32_le(c as u32, &mut result);
        }
        ScalarTag::I8 => {
            let v: i8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i8(v, &mut result);
        }
        ScalarTag::I16 => {
            let v: i16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i16_le(v, &mut result);
        }
        ScalarTag::I32 => {
            let v: i32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i32_le(v, &mut result);
        }
        ScalarTag::I64 => {
            let v: i64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v, &mut result);
        }
        ScalarTag::I128 => {
            let v: i128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i128_le(v, &mut result);
        }
        ScalarTag::U8 => {
            let v: u8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u8(v, &mut result);
        }
        ScalarTag::U16 => {
            let v: u16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u16_le(v, &mut result);
        }
        ScalarTag::U32 => {
            let v: u32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u32_le(v, &mut result);
        }
        ScalarTag::U64 => {
            let v: u64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v, &mut result);
        }
        ScalarTag::U128 => {
            let v: u128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u128_le(v, &mut result);
        }
        ScalarTag::Isize => {
            let v: isize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v as i64, &mut result);
        }
        ScalarTag::Usize => {
            let v: usize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v as u64, &mut result);
        }
        ScalarTag::F32 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f32_le(v, &mut result);
        }
        ScalarTag::F64 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f64_le(v, &mut result);
        }
        ScalarTag::F16 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f16 = F16::from_f32(v);
            write_u16_le(f16.0, &mut result);
        }
        ScalarTag::F128 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f128 = F128::from_f64(v);
            result.copy_from_slice(&f128.0);
        }
    }

    Ok(result)
}

// ---- cast 内部辅助 ----

fn read_bool(bytes: &[u8]) -> bool {
    bytes.first().copied().unwrap_or(0) != 0
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

fn read_int_as_i128(tag: ScalarTag, bytes: &[u8]) -> i128 {
    match tag {
        ScalarTag::I8 => bytes.first().copied().unwrap_or(0) as i8 as i128,
        ScalarTag::U8 => bytes.first().copied().unwrap_or(0) as u8 as i128,
        ScalarTag::I16 => i16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::U16 => u16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::I32 => i32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::U32 => u32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::I64 => read_i64_le(bytes) as i128,
        ScalarTag::U64 => read_u64_le(bytes) as i128,
        ScalarTag::I128 => read_i128_le(bytes),
        ScalarTag::U128 => read_u128_le(bytes) as i128,
        ScalarTag::Isize => read_i64_le(bytes) as isize as i128,
        ScalarTag::Usize => read_u64_le(bytes) as usize as i128,
        _ => 0,
    }
}

fn read_int_as_u128(tag: ScalarTag, bytes: &[u8]) -> u128 {
    match tag {
        ScalarTag::I8 => bytes.first().copied().unwrap_or(0) as i8 as i128 as u128,
        ScalarTag::U8 => bytes.first().copied().unwrap_or(0) as u8 as u128,
        ScalarTag::I16 => i16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128 as u128,
        ScalarTag::U16 => u16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as u128,
        ScalarTag::I32 => i32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128 as u128,
        ScalarTag::U32 => u32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as u128,
        ScalarTag::I64 => read_i64_le(bytes) as i128 as u128,
        ScalarTag::U64 => read_u64_le(bytes) as u128,
        ScalarTag::I128 => read_i128_le(bytes) as u128,
        ScalarTag::U128 => read_u128_le(bytes),
        ScalarTag::Isize => read_i64_le(bytes) as isize as i128 as u128,
        ScalarTag::Usize => read_u64_le(bytes) as usize as u128,
        _ => 0,
    }
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

fn cast_from_bool(b: bool, dst_tag: ScalarTag, dst: &mut [u8]) {
    let val: i128 = if b { 1 } else { 0 };
    if dst_tag.is_int() {
        cast_from_i128(val, dst_tag, dst);
    } else if dst_tag.is_float() {
        let f = if b { 1.0 } else { 0.0 };
        cast_from_f64(f, dst_tag, dst);
    } else if dst_tag == ScalarTag::Char {
        write_u32_le(val as u32, dst);
    }
}

fn cast_from_u32(cp: u32, dst_tag: ScalarTag, dst: &mut [u8]) {
    if dst_tag.is_int() {
        cast_from_u128(cp as u128, dst_tag, dst);
    } else if dst_tag.is_float() {
        cast_from_f64(cp as f64, dst_tag, dst);
    } else if dst_tag == ScalarTag::Bool {
        write_bool(cp != 0, dst);
    }
}

fn cast_from_i128(val: i128, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::I8 => write_i8(val as i8, dst),
        ScalarTag::U8 => write_u8(val as u8, dst),
        ScalarTag::I16 => write_i16_le(val as i16, dst),
        ScalarTag::U16 => write_u16_le(val as u16, dst),
        ScalarTag::I32 => write_i32_le(val as i32, dst),
        ScalarTag::U32 => write_u32_le(val as u32, dst),
        ScalarTag::I64 => write_i64_le(val as i64, dst),
        ScalarTag::U64 => write_u64_le(val as u64, dst),
        ScalarTag::I128 => write_i128_le(val, dst),
        ScalarTag::U128 => write_u128_le(val as u128, dst),
        ScalarTag::Isize => write_i64_le(val as isize as i64, dst),
        ScalarTag::Usize => write_u64_le(val as usize as u64, dst),
        _ => {}
    }
}

fn cast_from_u128(val: u128, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::I8 => write_i8(val as i8, dst),
        ScalarTag::U8 => write_u8(val as u8, dst),
        ScalarTag::I16 => write_i16_le(val as i16, dst),
        ScalarTag::U16 => write_u16_le(val as u16, dst),
        ScalarTag::I32 => write_i32_le(val as i32, dst),
        ScalarTag::U32 => write_u32_le(val as u32, dst),
        ScalarTag::I64 => write_i64_le(val as i64, dst),
        ScalarTag::U64 => write_u64_le(val as u64, dst),
        ScalarTag::I128 => write_i128_le(val as i128, dst),
        ScalarTag::U128 => write_u128_le(val, dst),
        ScalarTag::Isize => write_i64_le(val as isize as i64, dst),
        ScalarTag::Usize => write_u64_le(val as usize as u64, dst),
        _ => {}
    }
}

fn cast_from_f64(val: f64, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::F16 => write_f16(F16::from_f32(val as f32), dst),
        ScalarTag::F32 => write_f32_le(val as f32, dst),
        ScalarTag::F64 => write_f64_le(val, dst),
        ScalarTag::F128 => write_f128(F128::from_f64(val), dst),
        _ => {}
    }
}

fn cast_to_bool(src_tag: ScalarTag, src_bytes: &[u8]) -> bool {
    match src_tag {
        ScalarTag::Bool => read_bool(src_bytes),
        ScalarTag::Char => read_u32_le(src_bytes) != 0,
        ScalarTag::I8 => src_bytes.first().copied().unwrap_or(0) as i8 != 0,
        ScalarTag::U8 => src_bytes.first().copied().unwrap_or(0) != 0,
        ScalarTag::I16 | ScalarTag::U16 => {
            let mut b = [0u8; 2];
            let l = src_bytes.len().min(2);
            b[..l].copy_from_slice(&src_bytes[..l]);
            u16::from_le_bytes(b) != 0
        }
        ScalarTag::I32 | ScalarTag::U32 => {
            let v = read_u32_le(src_bytes);
            v != 0
        }
        ScalarTag::I64 | ScalarTag::U64 | ScalarTag::Isize | ScalarTag::Usize => {
            read_u64_le(src_bytes) != 0
        }
        ScalarTag::I128 | ScalarTag::U128 => {
            read_u128_le(src_bytes) != 0
        }
        ScalarTag::F32 => read_f32_le(src_bytes) != 0.0,
        ScalarTag::F64 => read_f64_le(src_bytes) != 0.0,
        ScalarTag::F16 => read_f16(src_bytes).to_f32() != 0.0,
        ScalarTag::F128 => read_f128(src_bytes).to_f64() != 0.0,
    }
}

fn cast_to_u32(src_tag: ScalarTag, src_bytes: &[u8]) -> u32 {
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
    } else if src_tag == ScalarTag::Bool {
        if read_bool(src_bytes) { 1 } else { 0 }
    } else {
        0
    }
}

fn read_float_as_f64(tag: ScalarTag, bytes: &[u8]) -> f64 {
    match tag {
        ScalarTag::F16 => read_f16(bytes).to_f64(),
        ScalarTag::F32 => read_f32_le(bytes) as f64,
        ScalarTag::F64 => read_f64_le(bytes),
        ScalarTag::F128 => read_f128(bytes).to_f64(),
        _ => 0.0,
    }
}

fn cast_int_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    if dst_tag.is_signed() {
        let val = read_int_as_i128(src_tag, src_bytes);
        cast_from_i128(val, dst_tag, dst);
    } else {
        let val = read_int_as_u128(src_tag, src_bytes);
        cast_from_u128(val, dst_tag, dst);
    }
}

fn cast_int_to_float(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let val = if src_tag.is_signed() {
        read_int_as_i128(src_tag, src_bytes) as f64
    } else {
        read_int_as_u128(src_tag, src_bytes) as f64
    };
    cast_from_f64(val, dst_tag, dst);
}

fn cast_float_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);
    match dst_tag {
        ScalarTag::I8 => write_i8(f as i8, dst),
        ScalarTag::I16 => write_i16_le(f as i16, dst),
        ScalarTag::I32 => write_i32_le(f as i32, dst),
        ScalarTag::I64 => write_i64_le(f as i64, dst),
        ScalarTag::I128 => write_i128_le(f as i128, dst),
        ScalarTag::Isize => write_i64_le(f as isize as i64, dst),
        ScalarTag::U8 => write_u8(f as u8, dst),
        ScalarTag::U16 => write_u16_le(f as u16, dst),
        ScalarTag::U32 => write_u32_le(f as u32, dst),
        ScalarTag::U64 => write_u64_le(f as u64, dst),
        ScalarTag::U128 => write_u128_le(f as u128, dst),
        ScalarTag::Usize => write_u64_le(f as usize as u64, dst),
        _ => {}
    }
}

fn cast_float_to_float(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);
    cast_from_f64(f, dst_tag, dst);
}

fn try_cast_int_narrow(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    let sval = read_int_as_i128(src_tag, src_bytes);
    let uval = read_int_as_u128(src_tag, src_bytes);

    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ScalarTag::I8 => (i8::MIN as i128..=i8::MAX as i128).contains(&sval),
            ScalarTag::I16 => (i16::MIN as i128..=i16::MAX as i128).contains(&sval),
            ScalarTag::I32 => (i32::MIN as i128..=i32::MAX as i128).contains(&sval),
            ScalarTag::I64 => (i64::MIN as i128..=i64::MAX as i128).contains(&sval),
            ScalarTag::Isize => (isize::MIN as i128..=isize::MAX as i128).contains(&sval),
            _ => true,
        }
    } else {
        if src_tag.is_signed() && sval < 0 {
            false
        } else {
            match dst_tag {
                ScalarTag::U8 => uval <= u8::MAX as u128,
                ScalarTag::U16 => uval <= u16::MAX as u128,
                ScalarTag::U32 => uval <= u32::MAX as u128,
                ScalarTag::U64 => uval <= u64::MAX as u128,
                ScalarTag::Usize => uval <= usize::MAX as u128,
                _ => true,
            }
        }
    };

    if !in_range {
        return Err(CastError::Overflow);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

fn try_cast_float_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    let f = read_float_as_f64(src_tag, src_bytes);

    if f.is_nan() || f.is_infinite() {
        return Err(CastError::Overflow);
    }

    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ScalarTag::I8 => f >= i8::MIN as f64 && f <= i8::MAX as f64,
            ScalarTag::I16 => f >= i16::MIN as f64 && f <= i16::MAX as f64,
            ScalarTag::I32 => f >= i32::MIN as f64 && f <= i32::MAX as f64,
            ScalarTag::I64 => f >= i64::MIN as f64 && f <= i64::MAX as f64,
            ScalarTag::I128 => f >= i128::MIN as f64 && f <= i128::MAX as f64,
            ScalarTag::Isize => f >= isize::MIN as f64 && f <= isize::MAX as f64,
            _ => true,
        }
    } else {
        match dst_tag {
            ScalarTag::U8 => f >= 0.0 && f <= u8::MAX as f64,
            ScalarTag::U16 => f >= 0.0 && f <= u16::MAX as f64,
            ScalarTag::U32 => f >= 0.0 && f <= u32::MAX as f64,
            ScalarTag::U64 => f >= 0.0 && f <= u64::MAX as f64,
            ScalarTag::U128 => f >= 0.0 && f <= u128::MAX as f64,
            ScalarTag::Usize => f >= 0.0 && f <= usize::MAX as f64,
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

/// 通用二元运算分派
pub fn batch_binop<T>(dst: &mut [T], a: &[T], b: &[T], op: BinOp)
where T: Num + BitOps {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = match op {
            BinOp::Add => a[i].wrapping_add(b[i]),
            BinOp::Sub => a[i].wrapping_sub(b[i]),
            BinOp::Mul => a[i].wrapping_mul(b[i]),
            BinOp::Div => a[i].checked_div(b[i]).unwrap_or_else(T::zero),
            BinOp::Mod => a[i].checked_rem(b[i]).unwrap_or_else(T::zero),
            BinOp::Band => a[i].bit_and(b[i]),
            BinOp::Bor => a[i].bit_or(b[i]),
            BinOp::Bxor => a[i].bit_xor(b[i]),
            BinOp::Shl => a[i].shl(b[i].to_u32()),
            BinOp::Shr => a[i].shr(b[i].to_u32()),
        };
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

/// 批量比较运算：输出 `u8` 掩码
pub fn batch_cmp<T>(dst: &mut [u8], a: &[T], b: &[T], op: CmpOp)
where T: PartialOrd {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = match op {
            CmpOp::Lt => a[i] < b[i],
            CmpOp::Gt => a[i] > b[i],
            CmpOp::Eq => a[i] == b[i],
            CmpOp::Ne => a[i] != b[i],
            CmpOp::Le => a[i] <= b[i],
            CmpOp::Ge => a[i] >= b[i],
        }
        .into();
    }
}

/// 批量归约运算
pub fn batch_reduce<T>(a: &[T], op: ReduceOp) -> T
where T: Num + BitOps {
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
// 第十四部分：allocator.rs
// =========================================================================

/// 内存分配器 trait
pub trait Allocator: Clone {
    fn alloc_str(&self, s: &str) -> Rc<str>;
    fn alloc_array(&self, vals: Vec<Value>) -> Rc<Vec<Value>>;
    fn alloc_value(&self, val: Value) -> Value {
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
    fn alloc_array(&self, vals: Vec<Value>) -> Rc<Vec<Value>> {
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
        assert!(Value::null().is_null());
        assert!(Value::void().is_void());
        assert_eq!(Value::bool(true).as_bool(), Some(true));
        assert_eq!(Value::i32(42).as_i32(), Some(42));
        assert_eq!(Value::i64(-7).as_i64(), Some(-7));
        assert_eq!(Value::u8(255).as_u8(), Some(255));
        assert_eq!(Value::f64(2.5).as_f64(), Some(2.5));
    }

    #[test]
    fn test_char_constructor() {
        let c = Value::from_rust_char('A');
        assert!(c.is_char());
        assert_eq!(c.as_char().unwrap().codepoint(), 65);
    }

    #[test]
    fn test_int_promotion() {
        assert_eq!(Value::i32(42).as_int_i64(), Some(42));
        assert_eq!(Value::u64(100).as_int_i64(), Some(100));
        assert_eq!(Value::i8(-5).as_int_i128(), Some(-5));
        assert_eq!(Value::f64(2.5).as_int_i64(), None);
    }

    #[test]
    fn test_float_promotion() {
        assert_eq!(Value::f32(1.5).as_float_f64(), Some(1.5));
        assert_eq!(Value::f64(2.5).as_float_f64(), Some(2.5));
        assert_eq!(Value::i32(42).as_float_f64(), None);
    }

    // ---- 谓词 ----

    #[test]
    fn test_predicates() {
        assert!(Value::bool(false).is_bool());
        assert!(Value::from_rust_char('x').is_char());
        assert!(Value::i32(0).is_int());
        assert!(Value::u64(1).is_int());
        assert!(Value::f64(0.0).is_float());
        assert!(Value::i32(0).is_numeric());
        assert!(Value::f32(0.0).is_numeric());
        assert!(!Value::bool(true).is_numeric());
        assert!(Value::i32(0).is_scalar());
        assert!(!Value::null().is_scalar());
    }

    #[test]
    fn test_heap_predicates() {
        assert!(Value::str("hello").is_string());
        assert!(Value::str("hello").is_ref());
        assert!(Value::array(vec![Value::i32(1), Value::i32(2)]).is_array());
        assert!(Value::record("Foo", vec![], vec![]).is_record());
        assert!(Value::closure(Closure {
            func_id: 0,
            arity: 0,
            upvalues: vec![],
            bound_args: vec![],
            self_upvalue_idx: -1,
            upvalue_ref_bits: 0,
            cell_upvalues: 0,
        })
        .is_closure());
        assert!(Value::closure(Closure {
            func_id: 0,
            arity: 0,
            upvalues: vec![],
            bound_args: vec![],
            self_upvalue_idx: -1,
            upvalue_ref_bits: 0,
            cell_upvalues: 0,
        })
        .is_callable());
    }

    // ---- 类型名称 ----

    #[test]
    fn test_type_names() {
        assert_eq!(Value::null().type_name(), "null");
        assert_eq!(Value::void().type_name(), "void");
        assert_eq!(Value::bool(true).type_name(), "bool");
        assert_eq!(Value::from_rust_char('x').type_name(), "char");
        assert_eq!(Value::i32(0).type_name(), "i32");
        assert_eq!(Value::u64(0).type_name(), "u64");
        assert_eq!(Value::f64(0.0).type_name(), "f64");
        assert_eq!(Value::str("x").type_name(), "str");
        assert_eq!(Value::array(vec![]).type_name(), "array");
        assert_eq!(Value::record("Foo", vec![], vec![]).type_name(), "record");
    }

    #[test]
    fn test_scalar_tag() {
        assert_eq!(Value::bool(true).scalar_tag(), Some(ScalarTag::Bool));
        assert_eq!(Value::i32(0).scalar_tag(), Some(ScalarTag::I32));
        assert_eq!(Value::f64(0.0).scalar_tag(), Some(ScalarTag::F64));
        assert_eq!(Value::null().scalar_tag(), None);
        assert_eq!(Value::str("x").scalar_tag(), None);
    }

    // ---- equals ----

    #[test]
    fn test_equals_scalars() {
        assert!(Value::i32(42).equals(&Value::i32(42)));
        assert!(!Value::i32(42).equals(&Value::i32(43)));
        assert!(Value::bool(true).equals(&Value::bool(true)));
        assert!(!Value::bool(true).equals(&Value::bool(false)));
        assert!(Value::f64(2.5).equals(&Value::f64(2.5)));
        assert!(Value::null().equals(&Value::null()));
        assert!(Value::void().equals(&Value::void()));
        assert!(!Value::null().equals(&Value::void()));
    }

    #[test]
    fn test_equals_different_types() {
        // 即使数值相同，不同标量类型不相等
        assert!(!Value::i32(1).equals(&Value::i64(1)));
        assert!(!Value::i32(1).equals(&Value::u32(1)));
        assert!(!Value::i32(1).equals(&Value::bool(true)));
    }

    #[test]
    fn test_equals_strings() {
        let s1 = Value::str("hello");
        let s2 = Value::str("hello");
        let s3 = Value::str("world");
        assert!(s1.equals(&s2));
        assert!(!s1.equals(&s3));
    }

    #[test]
    fn test_equals_arrays() {
        let a1 = Value::array(vec![Value::i32(1), Value::i32(2), Value::i32(3)]);
        let a2 = Value::array(vec![Value::i32(1), Value::i32(2), Value::i32(3)]);
        let a3 = Value::array(vec![Value::i32(1), Value::i32(2)]);
        let a4 = Value::array(vec![Value::i32(1), Value::i32(2), Value::i32(4)]);
        assert!(a1.equals(&a2));
        assert!(!a1.equals(&a3));
        assert!(!a1.equals(&a4));
    }

    #[test]
    fn test_equals_records() {
        let r1 = Value::record("Foo", vec![Value::i32(1)], vec![Some("x".to_string())]);
        let r2 = Value::record("Foo", vec![Value::i32(1)], vec![Some("x".to_string())]);
        let r3 = Value::record("Bar", vec![Value::i32(1)], vec![Some("x".to_string())]);
        assert!(r1.equals(&r2));
        assert!(!r1.equals(&r3));
    }

    #[test]
    fn test_equals_adt() {
        let a1 = Value::adt("Option", "Some", vec![AdtField {
            name: None,
            value: Value::i32(42),
        }]);
        let a2 = Value::adt("Option", "Some", vec![AdtField {
            name: None,
            value: Value::i32(42),
        }]);
        let a3 = Value::adt("Option", "None", vec![]);
        assert!(a1.equals(&a2));
        assert!(!a1.equals(&a3));
    }

    #[test]
    fn test_equals_range() {
        let r1 = Value::range(1, 10, false);
        let r2 = Value::range(1, 10, false);
        let r3 = Value::range(1, 10, true);
        assert!(r1.equals(&r2));
        assert!(!r1.equals(&r3));
    }

    #[test]
    fn test_partial_eq_trait() {
        assert_eq!(Value::i32(42), Value::i32(42));
        assert_ne!(Value::i32(42), Value::i32(43));
        assert_eq!(Value::str("x"), Value::str("x"));
    }

    // ---- deep_clone ----

    #[test]
    fn test_deep_clone_scalar() {
        let v = Value::i32(42);
        let c = v.deep_clone();
        assert!(v.equals(&c));
        // 标量是 Copy，克隆后仍是同一变体
        assert_eq!(c.as_i32(), Some(42));
    }

    #[test]
    fn test_deep_clone_array() {
        let v = Value::array(vec![Value::i32(1), Value::str("hello"), Value::bool(true)]);
        let c = v.deep_clone();
        assert!(v.equals(&c));
        // 克隆后指针不同
        assert!(!matches!(
            (&v, &c),
            (Value::Ref(a), Value::Ref(b)) if std::rc::Rc::ptr_eq(a, b)
        ));
    }

    #[test]
    fn test_deep_clone_nested() {
        let inner = Value::array(vec![Value::i32(1), Value::i32(2)]);
        let outer = Value::array(vec![inner, Value::str("x")]);
        let cloned = outer.deep_clone();
        assert!(outer.equals(&cloned));

        // 修改克隆不影响原（语义验证：克隆是独立的）
        if let Value::Ref(r) = &cloned {
            if let HeapObj::Array(a) = r.as_ref() {
                assert_eq!(a.elements.len(), 2);
            }
        }
    }

    #[test]
    fn test_deep_clone_record() {
        let r = Value::record(
            "Point",
            vec![Value::i32(1), Value::i32(2)],
            vec![Some("x".to_string()), Some("y".to_string())],
        );
        let c = r.deep_clone();
        assert!(r.equals(&c));
    }

    // ---- Display / Debug ----

    #[test]
    fn test_display() {
        assert_eq!(format!("{}", Value::null()), "null");
        assert_eq!(format!("{}", Value::void()), "()");
        assert_eq!(format!("{}", Value::bool(true)), "true");
        assert_eq!(format!("{}", Value::i32(42)), "42");
        assert_eq!(format!("{}", Value::str("hello")), "hello");
        assert_eq!(format!("{}", Value::from_rust_char('A')), "A");
    }

    #[test]
    fn test_debug() {
        assert_eq!(format!("{:?}", Value::i32(42)), "42");
        assert_eq!(format!("{:?}", Value::i64(42)), "42i64");
        assert_eq!(format!("{:?}", Value::u8(255)), "255u8");
    }

    // ---- Hash ----

    #[test]
    fn test_hash_consistency() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        fn hash_of(v: &Value) -> u64 {
            let mut h = DefaultHasher::new();
            v.hash(&mut h);
            h.finish()
        }

        // 相同标量哈希一致
        assert_eq!(hash_of(&Value::i32(42)), hash_of(&Value::i32(42)));
        assert_eq!(hash_of(&Value::str("x")), hash_of(&Value::str("x")));
        // 不同类型哈希不同
        assert_ne!(hash_of(&Value::i32(1)), hash_of(&Value::i64(1)));
    }

    // ---- 内存语义 ----

    #[test]
    fn test_ref_sharing() {
        let s1 = Value::str("shared");
        let s2 = s1.clone();
        // 克隆共享 Rc 指针
        match (&s1, &s2) {
            (Value::Ref(a), Value::Ref(b)) => assert!(Rc::ptr_eq(a, b)),
            _ => panic!("expected Ref variants"),
        }
        assert!(s1.equals(&s2));
    }

    #[test]
    fn test_default_is_void() {
        assert!(matches!(Value::default(), Value::Void));
    }
}

#[cfg(test)]
mod scalar_tests {
    use super::*;

    #[test]
    fn test_scalar_tag_count() {
        assert_eq!(ScalarTag::all().len(), 18);
    }

    #[test]
    fn test_byte_width() {
        assert_eq!(ScalarTag::Bool.byte_width(), 1);
        assert_eq!(ScalarTag::Char.byte_width(), 4);
        assert_eq!(ScalarTag::I8.byte_width(), 1);
        assert_eq!(ScalarTag::I64.byte_width(), 8);
        assert_eq!(ScalarTag::I128.byte_width(), 16);
        assert_eq!(ScalarTag::F16.byte_width(), 2);
        assert_eq!(ScalarTag::F128.byte_width(), 16);
    }

    #[test]
    fn test_predicates() {
        assert!(ScalarTag::I32.is_int());
        assert!(!ScalarTag::Bool.is_int());
        assert!(ScalarTag::F64.is_float());
        assert!(ScalarTag::I32.is_signed());
        assert!(!ScalarTag::U32.is_signed());
        assert!(ScalarTag::Isize.is_signed());
    }

    #[test]
    fn test_name_roundtrip() {
        for tag in ScalarTag::all() {
            let name = tag.name();
            assert_eq!(ScalarTag::from_name(name), Some(*tag));
        }
        assert_eq!(ScalarTag::from_name("not_a_type"), None);
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
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::I64);
        assert_eq!(i64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        }), 42);
    }

    #[test]
    fn test_cast_i32_to_i8_wrap() {
        let src = make_bytes(300);
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::I8);
        assert_eq!(dst[0] as i8, 300i32 as i8);
    }

    #[test]
    fn test_try_cast_i32_to_i8_overflow() {
        let src = make_bytes(300);
        assert_eq!(
            try_cast_value(ScalarTag::I32, &src, ScalarTag::I8),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_try_cast_i32_to_i8_ok() {
        let src = make_bytes(100);
        let dst = try_cast_value(ScalarTag::I32, &src, ScalarTag::I8).unwrap();
        assert_eq!(dst[0] as i8, 100);
    }

    #[test]
    fn test_cast_f64_to_i32_truncate() {
        let src = 3.7f64.to_le_bytes().to_vec();
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
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
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
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
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
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
            try_cast_value(ScalarTag::F64, &src, ScalarTag::I32),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_cast_bool_to_int() {
        let src = vec![1u8];
        let dst = cast_value(ScalarTag::Bool, &src, ScalarTag::I32);
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
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::Bool);
        assert_eq!(dst[0], 0);

        let src = make_bytes(42);
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::Bool);
        assert_eq!(dst[0], 1);
    }

    #[test]
    fn test_cast_char_to_int() {
        let src = 65u32.to_le_bytes().to_vec();
        let dst = cast_value(ScalarTag::Char, &src, ScalarTag::I64);
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
            try_cast_value(ScalarTag::I32, &src, ScalarTag::Char),
            Err(CastError::InvalidCodepoint)
        );
    }

    #[test]
    fn test_try_cast_int_to_char_valid() {
        let src = 65i32.to_le_bytes().to_vec();
        let dst = try_cast_value(ScalarTag::I32, &src, ScalarTag::Char).unwrap();
        let v = u32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 65);
    }

    #[test]
    fn test_parse_str_int() {
        let dst = parse_str("42", ScalarTag::I32).unwrap();
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 42);
    }

    #[test]
    fn test_parse_str_bool() {
        let dst = parse_str("true", ScalarTag::Bool).unwrap();
        assert_eq!(dst[0], 1);

        let dst = parse_str("false", ScalarTag::Bool).unwrap();
        assert_eq!(dst[0], 0);
    }

    #[test]
    fn test_parse_str_float() {
        let dst = parse_str("2.5", ScalarTag::F64).unwrap();
        let v = f64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        });
        assert!((v - 2.5).abs() < 1e-10);
    }

    #[test]
    fn test_parse_str_fail() {
        assert!(parse_str("abc", ScalarTag::I32).is_err());
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
        let arr = alloc.alloc_array(vec![Value::i32(1), Value::i32(2), Value::i32(3)]);
        assert_eq!(arr.len(), 3);
        assert_eq!(arr[0].as_i32(), Some(1));
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
        let v = Value::i32(42);
        let allocated = alloc.alloc_value(v);
        assert_eq!(allocated.as_i32(), Some(42));
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
        assert_eq!(Value::i8(-5).as_i8(), Some(-5));
        assert_eq!(Value::i16(-1000).as_i16(), Some(-1000));
        assert_eq!(Value::i32(42).as_i32(), Some(42));
        assert_eq!(Value::i64(i64::MAX).as_i64(), Some(i64::MAX));
        assert_eq!(Value::i128(i128::MIN).as_i128(), Some(i128::MIN));
        assert_eq!(Value::u8(255).as_u8(), Some(255));
        assert_eq!(Value::u16(65535).as_u16(), Some(65535));
        assert_eq!(Value::u32(u32::MAX).as_u32(), Some(u32::MAX));
        assert_eq!(Value::u64(u64::MAX).as_u64(), Some(u64::MAX));
        assert_eq!(Value::u128(u128::MAX).as_u128(), Some(u128::MAX));
        assert_eq!(Value::f32(3.14).as_f32(), Some(3.14));
        assert_eq!(Value::f64(2.71828).as_f64(), Some(2.71828));
    }

    #[test]
    fn test_union_wrong_tag_returns_none() {
        let v = Value::i32(42);
        assert_eq!(v.as_i64(), None);
        assert_eq!(v.as_u32(), None);
        assert_eq!(v.as_f32(), None);
        assert_eq!(v.as_bool(), None);
        assert_eq!(v.as_char(), None);
    }

    #[test]
    fn test_f16_f128_bits_roundtrip() {
        let f16 = F16::from_f32(1.5);
        assert_eq!(f16.to_f32(), 1.5);
        let v = Value::f16(f16);
        assert_eq!(v.as_f16(), Some(f16));

        // F128 往返测试（已修复掩码 bug）
        let f128 = F128::from_f64(3.14159);
        assert_eq!(f128.to_f64(), 3.14159);
        let v = Value::f128(f128);
        assert_eq!(v.as_f128(), Some(f128));
    }

    #[test]
    fn test_char_roundtrip() {
        let c = Char::from_codepoint(0x4E2D).unwrap(); // '中'
        let v = Value::char(c);
        assert_eq!(v.as_char(), Some(c));
        assert_eq!(v.as_i32(), None); // char 不是 int
    }

    #[test]
    fn test_value_size() {
        // Value = enum tag + ScalarValue(16B, align 16) + ScalarTag(1B)
        // 因 i128 要求 16 字节对齐，整体为 32 字节
        let size = std::mem::size_of::<Value>();
        assert!(size <= 32, "Value size should be <= 32 bytes, got {}", size);
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
        // 菱形引用：outer 两次引用同一 inner
        let inner = Value::array(vec![Value::i32(1), Value::i32(2)]);
        let outer = Value::array(vec![
            Value::from_ref(inner.as_ref().unwrap().clone()),
            Value::from_ref(inner.as_ref().unwrap().clone()),
        ]);

        let cloned = outer.deep_clone();

        // 克隆后两个 inner 应共享同一 Rc（ptr_eq）
        if let Value::Ref(r) = &cloned {
            if let HeapObj::Array(a) = r.as_ref() {
                if let (Value::Ref(r1), Value::Ref(r2)) = (&a.elements[0], &a.elements[1]) {
                    assert!(Rc::ptr_eq(r1, r2), "cloned diamond should share subgraph");
                    return;
                }
            }
        }
        panic!("expected cloned diamond structure");
    }

    #[test]
    fn test_deep_clone_independent_objects_not_shared() {
        let a = Value::array(vec![Value::i32(1)]);
        let b = Value::array(vec![Value::i32(1)]);
        let outer = Value::array(vec![a.clone(), b.clone()]);
        let cloned = outer.deep_clone();

        if let Value::Ref(r) = &cloned {
            if let HeapObj::Array(a) = r.as_ref() {
                if let (Value::Ref(r1), Value::Ref(r2)) = (&a.elements[0], &a.elements[1]) {
                    assert!(!Rc::ptr_eq(r1, r2), "independent objects should not share");
                    return;
                }
            }
        }
        panic!("expected structure");
    }
}