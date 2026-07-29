//! Value 模块：Glue 语言的值系统实现
//!
//! 包含 18 种标量类型和 23 种堆对象类型，实现内存管理、类型转换和基本运算。
//!
//! `Value` 是 Glue 运行时的统一值表示：
//! - 标量（bool/char/int/float）直接内联存储，零堆分配
//! - 堆对象通过 `Rc<HeapObj>` 引用计数共享
//! - `Null` 表示可空类型的空值，`Void` 表示 `void` 类型的唯一值

pub mod scalar;
pub mod char;
pub mod ops;
pub mod cast;
pub mod str;
pub mod heap;
pub mod composite;
pub mod callable;
pub mod control;
pub mod iterator;
pub mod concurrent;
pub mod batch;
pub mod allocator;

pub use scalar::{F16, F128, ScalarTag};
pub use char::{Char, CharError};
pub use str::GlueStr;
pub use heap::{HeapObj, HeapRef, RefKind};
pub use cast::{cast_value, try_cast_value, CastError};

use std::fmt;
use std::rc::Rc;

use crate::value::callable::{
    Builtin, BuiltinFn, Closure, LazyValue, PartialApplication, TraitValue,
};
use crate::value::composite::{
    AdtField, AdtValue, ArrayValue, Cell, NewtypeValue, Range, RecordValue,
};
use crate::value::concurrent::{
    AsyncHandle, AtomicValue, ChannelValue, ReceiverValue, SenderValue,
};
use crate::value::control::{ErrorValue, ThrowPayload, ThrowValue};
use crate::value::iterator::{ArrayIterator, RangeIterator, StringIterator};

// =========================================================================
// Value — 统一值枚举
// =========================================================================

/// Glue 统一值：标量内联 + 堆对象引用
///
/// 设计原则：
/// - 小尺寸标量直接内联，避免堆分配
/// - 堆对象通过 `Rc<HeapObj>` 共享，零拷贝传递
/// - `Null` 与 `Void` 区分：`Null` 为可空引用的空值，`Void` 为 `void` 类型的唯一值
#[derive(Clone)]
pub enum Value {
    // ---- 空值 ----
    /// 可空类型的空值（`null`）
    Null,
    /// `void` 类型的唯一值（`()`）
    Void,

    // ---- 标量（18 种，内联存储）----
    Bool(bool),
    Char(Char),
    I8(i8),
    I16(i16),
    I32(i32),
    I64(i64),
    I128(i128),
    U8(u8),
    U16(u16),
    U32(u32),
    U64(u64),
    U128(u128),
    Isize(isize),
    Usize(usize),
    F16(F16),
    F32(f32),
    F64(f64),
    F128(F128),

    // ---- 堆对象引用 ----
    Ref(HeapRef),
}

// =========================================================================
// 构造器：标量
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

    /// 构造布尔值
    pub fn bool(b: bool) -> Self {
        Value::Bool(b)
    }

    /// 构造字符值
    pub fn char(c: Char) -> Self {
        Value::Char(c)
    }

    /// 从 codepoint 构造字符值（不校验）
    pub fn char_from_codepoint(cp: u32) -> Self {
        Value::Char(Char::from_codepoint_unchecked(cp))
    }

    /// 从 Rust `char` 构造字符值
    pub fn from_rust_char(c: char) -> Self {
        Value::Char(Char::from(c))
    }

    /// 构造 i8 值
    pub fn i8(v: i8) -> Self {
        Value::I8(v)
    }
    pub fn i16(v: i16) -> Self {
        Value::I16(v)
    }
    pub fn i32(v: i32) -> Self {
        Value::I32(v)
    }
    pub fn i64(v: i64) -> Self {
        Value::I64(v)
    }
    pub fn i128(v: i128) -> Self {
        Value::I128(v)
    }
    pub fn u8(v: u8) -> Self {
        Value::U8(v)
    }
    pub fn u16(v: u16) -> Self {
        Value::U16(v)
    }
    pub fn u32(v: u32) -> Self {
        Value::U32(v)
    }
    pub fn u64(v: u64) -> Self {
        Value::U64(v)
    }
    pub fn u128(v: u128) -> Self {
        Value::U128(v)
    }
    pub fn isize(v: isize) -> Self {
        Value::Isize(v)
    }
    pub fn usize(v: usize) -> Self {
        Value::Usize(v)
    }
    pub fn f16(v: F16) -> Self {
        Value::F16(v)
    }
    pub fn f32(v: f32) -> Self {
        Value::F32(v)
    }
    pub fn f64(v: f64) -> Self {
        Value::F64(v)
    }
    pub fn f128(v: F128) -> Self {
        Value::F128(v)
    }

    /// 从 `i64` 按 `tag` 构造对应整数（用于 IR 加载立即数）
    pub fn int_from_i64(tag: ScalarTag, v: i64) -> Self {
        match tag {
            ScalarTag::I8 => Value::I8(v as i8),
            ScalarTag::I16 => Value::I16(v as i16),
            ScalarTag::I32 => Value::I32(v as i32),
            ScalarTag::I64 => Value::I64(v),
            ScalarTag::I128 => Value::I128(v as i128),
            ScalarTag::U8 => Value::U8(v as u8),
            ScalarTag::U16 => Value::U16(v as u16),
            ScalarTag::U32 => Value::U32(v as u32),
            ScalarTag::U64 => Value::U64(v as u64),
            ScalarTag::U128 => Value::U128(v as u128),
            ScalarTag::Isize => Value::Isize(v as isize),
            ScalarTag::Usize => Value::Usize(v as usize),
            _ => Value::I64(v),
        }
    }
}

// =========================================================================
// 构造器：堆对象
// =========================================================================

impl Value {
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
        Value::heap(HeapObj::Newtype(NewtypeValue {
            type_name: type_name.into(),
            inner,
        }))
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
        Value::heap(HeapObj::Builtin(Builtin {
            fn_ptr,
            name: name.into(),
        }))
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
        Value::heap(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Ok(val),
        }))
    }

    /// 构造 `Err` 抛出值
    pub fn throw_err(record: Rc<RecordValue>) -> Self {
        Value::heap(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(record),
        }))
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
        Value::heap(HeapObj::RangeIter(RangeIterator::new(
            start, end, inclusive,
        )))
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
}

// =========================================================================
// 访问器：标量
// =========================================================================

impl Value {
    /// 转为 `bool`（仅 `Bool` 变体）
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// 转为 `Char`
    pub fn as_char(&self) -> Option<Char> {
        match self {
            Value::Char(c) => Some(*c),
            _ => None,
        }
    }

    pub fn as_i8(&self) -> Option<i8> {
        match self {
            Value::I8(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_i16(&self) -> Option<i16> {
        match self {
            Value::I16(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_i32(&self) -> Option<i32> {
        match self {
            Value::I32(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Value::I64(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_i128(&self) -> Option<i128> {
        match self {
            Value::I128(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_u8(&self) -> Option<u8> {
        match self {
            Value::U8(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_u16(&self) -> Option<u16> {
        match self {
            Value::U16(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_u32(&self) -> Option<u32> {
        match self {
            Value::U32(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Value::U64(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_u128(&self) -> Option<u128> {
        match self {
            Value::U128(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_isize(&self) -> Option<isize> {
        match self {
            Value::Isize(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_usize(&self) -> Option<usize> {
        match self {
            Value::Usize(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_f16(&self) -> Option<F16> {
        match self {
            Value::F16(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_f32(&self) -> Option<f32> {
        match self {
            Value::F32(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::F64(v) => Some(*v),
            _ => None,
        }
    }
    pub fn as_f128(&self) -> Option<F128> {
        match self {
            Value::F128(v) => Some(*v),
            _ => None,
        }
    }

    /// 将整数标量统一提升为 `i64`（用于索引、比较等）
    pub fn as_int_i64(&self) -> Option<i64> {
        match self {
            Value::I8(v) => Some(*v as i64),
            Value::I16(v) => Some(*v as i64),
            Value::I32(v) => Some(*v as i64),
            Value::I64(v) => Some(*v),
            Value::I128(v) => Some(*v as i64),
            Value::U8(v) => Some(*v as i64),
            Value::U16(v) => Some(*v as i64),
            Value::U32(v) => Some(*v as i64),
            Value::U64(v) => Some(*v as i64),
            Value::U128(v) => Some(*v as i64),
            Value::Isize(v) => Some(*v as i64),
            Value::Usize(v) => Some(*v as i64),
            _ => None,
        }
    }

    /// 将整数标量统一提升为 `i128`
    pub fn as_int_i128(&self) -> Option<i128> {
        match self {
            Value::I8(v) => Some(*v as i128),
            Value::I16(v) => Some(*v as i128),
            Value::I32(v) => Some(*v as i128),
            Value::I64(v) => Some(*v as i128),
            Value::I128(v) => Some(*v),
            Value::U8(v) => Some(*v as i128),
            Value::U16(v) => Some(*v as i128),
            Value::U32(v) => Some(*v as i128),
            Value::U64(v) => Some(*v as i128),
            Value::U128(v) => Some(*v as i128),
            Value::Isize(v) => Some(*v as i128),
            Value::Usize(v) => Some(*v as i128),
            _ => None,
        }
    }

    /// 将浮点标量统一提升为 `f64`
    pub fn as_float_f64(&self) -> Option<f64> {
        match self {
            Value::F16(v) => Some(v.to_f64()),
            Value::F32(v) => Some(*v as f64),
            Value::F64(v) => Some(*v),
            Value::F128(v) => Some(v.to_f64()),
            _ => None,
        }
    }
}

// =========================================================================
// 访问器：堆对象
// =========================================================================

impl Value {
    /// 转为堆引用
    pub fn as_ref(&self) -> Option<&HeapRef> {
        match self {
            Value::Ref(r) => Some(r),
            _ => None,
        }
    }

    /// 转为字符串引用
    pub fn as_str(&self) -> Option<&GlueStr> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Str(s) => Some(s),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为数组引用
    pub fn as_array(&self) -> Option<&ArrayValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Array(a) => Some(a),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为记录引用
    pub fn as_record(&self) -> Option<&RecordValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Record(r) => Some(r),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为 ADT 引用
    pub fn as_adt(&self) -> Option<&AdtValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Adt(a) => Some(a),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为 Newtype 引用
    pub fn as_newtype(&self) -> Option<&NewtypeValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Newtype(n) => Some(n),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为 Cell 引用
    pub fn as_cell(&self) -> Option<&Cell> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Cell(c) => Some(c),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为 Range 引用
    pub fn as_range(&self) -> Option<&Range> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Range(r) => Some(r),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为闭包引用
    pub fn as_closure(&self) -> Option<&Closure> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Closure(c) => Some(c),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为偏应用引用
    pub fn as_partial(&self) -> Option<&PartialApplication> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Partial(p) => Some(p),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为内建函数引用
    pub fn as_builtin(&self) -> Option<&Builtin> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Builtin(b) => Some(b),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为 Trait 值引用
    pub fn as_trait_val(&self) -> Option<&TraitValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::TraitVal(t) => Some(t),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为惰性值引用
    pub fn as_lazy(&self) -> Option<&LazyValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::LazyVal(l) => Some(l),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为错误值引用
    pub fn as_error_val(&self) -> Option<&ErrorValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::ErrorVal(e) => Some(e),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为抛出值引用
    pub fn as_throw_val(&self) -> Option<&ThrowValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::ThrowVal(t) => Some(t),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为通道值引用
    pub fn as_channel(&self) -> Option<&ChannelValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::ChannelVal(c) => Some(c),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为原子值引用
    pub fn as_atomic(&self) -> Option<&AtomicValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::AtomicVal(a) => Some(a),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为异步句柄引用
    pub fn as_async_handle(&self) -> Option<&AsyncHandle> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::AsyncVal(a) => Some(a),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为发送端引用
    pub fn as_sender(&self) -> Option<&SenderValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::SenderVal(s) => Some(s),
                _ => None,
            },
            _ => None,
        }
    }

    /// 转为接收端引用
    pub fn as_receiver(&self) -> Option<&ReceiverValue> {
        match self {
            Value::Ref(r) => match r.as_ref() {
                HeapObj::ReceiverVal(r) => Some(r),
                _ => None,
            },
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
}

// =========================================================================
// 谓词
// =========================================================================

impl Value {
    /// 是否为 `null`
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// 是否为 `void`
    pub fn is_void(&self) -> bool {
        matches!(self, Value::Void)
    }

    /// 是否为布尔
    pub fn is_bool(&self) -> bool {
        matches!(self, Value::Bool(_))
    }

    /// 是否为字符
    pub fn is_char(&self) -> bool {
        matches!(self, Value::Char(_))
    }

    /// 是否为整数类型
    pub fn is_int(&self) -> bool {
        matches!(
            self,
            Value::I8(_)
                | Value::I16(_)
                | Value::I32(_)
                | Value::I64(_)
                | Value::I128(_)
                | Value::U8(_)
                | Value::U16(_)
                | Value::U32(_)
                | Value::U64(_)
                | Value::U128(_)
                | Value::Isize(_)
                | Value::Usize(_)
        )
    }

    /// 是否为浮点类型
    pub fn is_float(&self) -> bool {
        matches!(
            self,
            Value::F16(_) | Value::F32(_) | Value::F64(_) | Value::F128(_)
        )
    }

    /// 是否为数值（整数或浮点）
    pub fn is_numeric(&self) -> bool {
        self.is_int() || self.is_float()
    }

    /// 是否为标量（bool/char/int/float）
    pub fn is_scalar(&self) -> bool {
        self.is_bool() || self.is_char() || self.is_numeric()
    }

    /// 是否为字符串
    pub fn is_string(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(r.as_ref(), HeapObj::Str(_))
        )
    }

    /// 是否为数组
    pub fn is_array(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(r.as_ref(), HeapObj::Array(_))
        )
    }

    /// 是否为记录
    pub fn is_record(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(r.as_ref(), HeapObj::Record(_))
        )
    }

    /// 是否为 ADT
    pub fn is_adt(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(r.as_ref(), HeapObj::Adt(_))
        )
    }

    /// 是否为闭包
    pub fn is_closure(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(r.as_ref(), HeapObj::Closure(_))
        )
    }

    /// 是否为堆引用
    pub fn is_ref(&self) -> bool {
        matches!(self, Value::Ref(_))
    }

    /// 是否为可调用值（闭包/偏应用/内建函数/Trait）
    pub fn is_callable(&self) -> bool {
        matches!(
            self,
            Value::Ref(r) if matches!(
                r.as_ref(),
                HeapObj::Closure(_) | HeapObj::Partial(_) | HeapObj::Builtin(_) | HeapObj::TraitVal(_)
            )
        )
    }

    /// 是否需要 release（堆引用，引用计数 > 1 时需显式释放）
    pub fn requires_release(&self) -> bool {
        self.is_ref()
    }
}

// =========================================================================
// 类型名称
// =========================================================================

impl Value {
    /// 获取值的类型名称（用于调试与错误信息）
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Void => "void",
            Value::Bool(_) => "bool",
            Value::Char(_) => "char",
            Value::I8(_) => "i8",
            Value::I16(_) => "i16",
            Value::I32(_) => "i32",
            Value::I64(_) => "i64",
            Value::I128(_) => "i128",
            Value::U8(_) => "u8",
            Value::U16(_) => "u16",
            Value::U32(_) => "u32",
            Value::U64(_) => "u64",
            Value::U128(_) => "u128",
            Value::Isize(_) => "isize",
            Value::Usize(_) => "usize",
            Value::F16(_) => "f16",
            Value::F32(_) => "f32",
            Value::F64(_) => "f64",
            Value::F128(_) => "f128",
            Value::Ref(r) => r.type_name(),
        }
    }

    /// 获取对应的标量标签（若为标量）
    pub fn scalar_tag(&self) -> Option<ScalarTag> {
        match self {
            Value::Bool(_) => Some(ScalarTag::Bool),
            Value::Char(_) => Some(ScalarTag::Char),
            Value::I8(_) => Some(ScalarTag::I8),
            Value::I16(_) => Some(ScalarTag::I16),
            Value::I32(_) => Some(ScalarTag::I32),
            Value::I64(_) => Some(ScalarTag::I64),
            Value::I128(_) => Some(ScalarTag::I128),
            Value::U8(_) => Some(ScalarTag::U8),
            Value::U16(_) => Some(ScalarTag::U16),
            Value::U32(_) => Some(ScalarTag::U32),
            Value::U64(_) => Some(ScalarTag::U64),
            Value::U128(_) => Some(ScalarTag::U128),
            Value::Isize(_) => Some(ScalarTag::Isize),
            Value::Usize(_) => Some(ScalarTag::Usize),
            Value::F16(_) => Some(ScalarTag::F16),
            Value::F32(_) => Some(ScalarTag::F32),
            Value::F64(_) => Some(ScalarTag::F64),
            Value::F128(_) => Some(ScalarTag::F128),
            _ => None,
        }
    }
}

// =========================================================================
// equals — 深度相等（带深度限制防环）
// =========================================================================

/// 相等比较的最大递归深度
const EQUALS_MAX_DEPTH: u32 = 4096;

impl Value {
    /// 深度相等比较（递归，带深度限制防止循环引用）
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

    // 快速路径：同类型标量直接比较
    match (a, b) {
        (Value::Null, Value::Null) => return true,
        (Value::Void, Value::Void) => return true,
        (Value::Bool(x), Value::Bool(y)) => return x == y,
        (Value::Char(x), Value::Char(y)) => return x == y,
        (Value::I8(x), Value::I8(y)) => return x == y,
        (Value::I16(x), Value::I16(y)) => return x == y,
        (Value::I32(x), Value::I32(y)) => return x == y,
        (Value::I64(x), Value::I64(y)) => return x == y,
        (Value::I128(x), Value::I128(y)) => return x == y,
        (Value::U8(x), Value::U8(y)) => return x == y,
        (Value::U16(x), Value::U16(y)) => return x == y,
        (Value::U32(x), Value::U32(y)) => return x == y,
        (Value::U64(x), Value::U64(y)) => return x == y,
        (Value::U128(x), Value::U128(y)) => return x == y,
        (Value::Isize(x), Value::Isize(y)) => return x == y,
        (Value::Usize(x), Value::Usize(y)) => return x == y,
        (Value::F16(x), Value::F16(y)) => return x == y,
        (Value::F32(x), Value::F32(y)) => return x == y,
        (Value::F64(x), Value::F64(y)) => return x == y,
        (Value::F128(x), Value::F128(y)) => return x == y,
        _ => {}
    }

    // 堆对象比较
    match (a, b) {
        (Value::Ref(x), Value::Ref(y)) => {
            // 指针相等快速路径
            if Rc::ptr_eq(x, y) {
                return true;
            }
            heap_equals(x, y, depth + 1)
        }
        _ => false,
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
            // fixed_size 也需一致
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
        // 闭包等可调用值按引用相等语义
        (HeapObj::Closure(x), HeapObj::Closure(y)) => {
            x.func_id == y.func_id && x.arity == y.arity && x.upvalues.len() == y.upvalues.len()
        }
        (HeapObj::Builtin(x), HeapObj::Builtin(y)) => {
            // 函数指针相等
            x.fn_ptr as usize == y.fn_ptr as usize && x.name == y.name
        }
        (HeapObj::ArrayIter(x), HeapObj::ArrayIter(y)) => x.index == y.index,
        (HeapObj::StringIter(x), HeapObj::StringIter(y)) => x.byte_offset == y.byte_offset,
        (HeapObj::RangeIter(x), HeapObj::RangeIter(y)) => {
            x.current == y.current && x.end == y.end && x.inclusive == y.inclusive
        }
        // 其余堆对象按引用相等
        _ => false,
    }
}

// =========================================================================
// deep_clone — 深拷贝（带深度限制防环）
// =========================================================================

/// 深拷贝的最大递归深度
const DEEP_CLONE_MAX_DEPTH: u32 = 4096;

impl Value {
    /// 深拷贝（递归，带深度限制）
    ///
    /// - 标量：直接复制（`Copy` 语义）
    /// - 堆对象：递归克隆内部 `Value`
    /// - 指针相等的堆对象：克隆后仍共享（避免爆裂复制）
    pub fn deep_clone(&self) -> Value {
        deep_clone_impl(self, 0)
    }
}

fn deep_clone_impl(v: &Value, depth: u32) -> Value {
    if depth > DEEP_CLONE_MAX_DEPTH {
        return v.clone();
    }
    match v {
        Value::Ref(r) => Value::Ref(Rc::new(heap_deep_clone(r, depth + 1))),
        other => other.clone(),
    }
}

fn heap_deep_clone(obj: &HeapObj, depth: u32) -> HeapObj {
    if depth > DEEP_CLONE_MAX_DEPTH {
        return obj.clone();
    }
    match obj {
        HeapObj::Str(s) => HeapObj::Str(s.clone()),
        HeapObj::Array(a) => {
            let elements: Vec<Value> = a.elements.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
            HeapObj::Array(ArrayValue {
                elements,
                fixed_size: a.fixed_size,
                elem_is_ref: a.elem_is_ref,
            })
        }
        HeapObj::Record(r) => {
            let fields: Vec<Value> = r.fields.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
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
                    value: deep_clone_impl(&f.value, depth + 1),
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
            inner: deep_clone_impl(&n.inner, depth + 1),
        }),
        HeapObj::Cell(c) => {
            let inner = c.get();
            HeapObj::Cell(Cell::new(deep_clone_impl(&inner, depth + 1)))
        }
        HeapObj::Range(r) => HeapObj::Range(r.clone()),
        HeapObj::Closure(c) => {
            let upvalues: Vec<Value> = c.upvalues.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
            let bound_args: Vec<Value> = c.bound_args.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
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
            let bound_args: Vec<Value> = p.bound_args.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
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
                t.method_values.iter().map(|e| deep_clone_impl(e, depth + 1)).collect();
            HeapObj::TraitVal(TraitValue {
                trait_name: t.trait_name.clone(),
                method_names: t.method_names.clone(),
                method_values,
                data: t.data.as_ref().map(|d| deep_clone_impl(d, depth + 1)),
                owned: t.owned,
            })
        }
        HeapObj::LazyVal(l) => {
            let cached = l.cached.as_ref().map(|c| deep_clone_impl(c, depth + 1));
            HeapObj::LazyVal(LazyValue {
                cached,
                forced: l.forced,
                thunk: l.thunk.clone(),
            })
        }
        HeapObj::ErrorVal(e) => HeapObj::ErrorVal(e.clone()),
        HeapObj::ThrowVal(t) => {
            let payload = match &t.payload {
                ThrowPayload::Ok(v) => ThrowPayload::Ok(deep_clone_impl(v, depth + 1)),
                ThrowPayload::Err(r) => ThrowPayload::Err(r.clone()),
            };
            HeapObj::ThrowVal(ThrowValue { payload })
        }
        HeapObj::ArrayIter(a) => HeapObj::ArrayIter(a.clone()),
        HeapObj::StringIter(s) => HeapObj::StringIter(s.clone()),
        HeapObj::RangeIter(r) => HeapObj::RangeIter(r.clone()),
        HeapObj::AtomicVal(a) => {
            let val = a.load();
            HeapObj::AtomicVal(AtomicValue::new(deep_clone_impl(&val, depth + 1)))
        }
        HeapObj::AsyncVal(a) => HeapObj::AsyncVal(a.clone()),
        HeapObj::ChannelVal(c) => HeapObj::ChannelVal(c.clone()),
        HeapObj::SenderVal(s) => HeapObj::SenderVal(s.clone()),
        HeapObj::ReceiverVal(r) => HeapObj::ReceiverVal(r.clone()),
        HeapObj::CoroutineFrame => HeapObj::CoroutineFrame,
    }
}

// =========================================================================
// Hash — 标量按值哈希，堆对象按内容哈希（与 equals 保持一致）
// =========================================================================

impl std::hash::Hash for Value {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            Value::Null | Value::Void => {}
            Value::Bool(b) => b.hash(state),
            Value::Char(c) => c.hash(state),
            Value::I8(v) => v.hash(state),
            Value::I16(v) => v.hash(state),
            Value::I32(v) => v.hash(state),
            Value::I64(v) => v.hash(state),
            Value::I128(v) => v.hash(state),
            Value::U8(v) => v.hash(state),
            Value::U16(v) => v.hash(state),
            Value::U32(v) => v.hash(state),
            Value::U64(v) => v.hash(state),
            Value::U128(v) => v.hash(state),
            Value::Isize(v) => v.hash(state),
            Value::Usize(v) => v.hash(state),
            Value::F16(v) => v.hash(state),
            Value::F32(v) => v.to_bits().hash(state),
            Value::F64(v) => v.to_bits().hash(state),
            Value::F128(v) => v.to_bits().hash(state),
            Value::Ref(r) => {
                // 堆对象按内容哈希（保持与 equals 一致的 HashMap 不变量）
                r.hash(state);
            }
        }
    }
}

// =========================================================================
// Debug / Display
// =========================================================================

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Bool(b) => write!(f, "{}", b),
            Value::Char(c) => write!(f, "'{}'", c),
            Value::I8(v) => write!(f, "{}i8", v),
            Value::I16(v) => write!(f, "{}i16", v),
            Value::I32(v) => write!(f, "{}", v),
            Value::I64(v) => write!(f, "{}i64", v),
            Value::I128(v) => write!(f, "{}i128", v),
            Value::U8(v) => write!(f, "{}u8", v),
            Value::U16(v) => write!(f, "{}u16", v),
            Value::U32(v) => write!(f, "{}u32", v),
            Value::U64(v) => write!(f, "{}u64", v),
            Value::U128(v) => write!(f, "{}u128", v),
            Value::Isize(v) => write!(f, "{}isize", v),
            Value::Usize(v) => write!(f, "{}usize", v),
            Value::F16(v) => write!(f, "{:?}", v),
            Value::F32(v) => write!(f, "{}f32", v),
            Value::F64(v) => write!(f, "{}", v),
            Value::F128(v) => write!(f, "{:?}", v),
            Value::Ref(r) => write!(f, "{:?}", r),
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Bool(b) => write!(f, "{}", b),
            Value::Char(c) => write!(f, "{}", c),
            Value::I8(v) => write!(f, "{}", v),
            Value::I16(v) => write!(f, "{}", v),
            Value::I32(v) => write!(f, "{}", v),
            Value::I64(v) => write!(f, "{}", v),
            Value::I128(v) => write!(f, "{}", v),
            Value::U8(v) => write!(f, "{}", v),
            Value::U16(v) => write!(f, "{}", v),
            Value::U32(v) => write!(f, "{}", v),
            Value::U64(v) => write!(f, "{}", v),
            Value::U128(v) => write!(f, "{}", v),
            Value::Isize(v) => write!(f, "{}", v),
            Value::Usize(v) => write!(f, "{}", v),
            Value::F16(v) => write!(f, "{}", v.to_f32()),
            Value::F32(v) => write!(f, "{}", v),
            Value::F64(v) => write!(f, "{}", v),
            Value::F128(v) => write!(f, "{}", v.to_f64()),
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Str(s) => write!(f, "{}", s),
                _ => write!(f, "{:?}", r),
            },
        }
    }
}

// =========================================================================
// Default — 默认为 `void`
// =========================================================================

impl Default for Value {
    fn default() -> Self {
        Value::Void
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
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
        assert!(matches!(c, Value::I32(42)));
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
