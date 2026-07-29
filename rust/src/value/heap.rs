//! 堆对象统一枚举：`HeapObj` 汇总全部 23 种堆分配值类型
//!
//! 对应 Zig 实现中的 `HeapObj` 联合体。使用 Rust `enum` 替代 Zig tagged union，
//! 通过 `Rc<HeapObj>`（`HeapRef`）实现引用计数。

use std::rc::Rc;

use crate::value::callable::*;
use crate::value::composite::*;
use crate::value::concurrent::*;
use crate::value::control::*;
use crate::value::iterator::*;
use crate::value::str::GlueStr;

// =========================================================================
// HeapObj — 堆对象枚举（23 种）
// =========================================================================

/// 堆对象：所有堆分配值类型的统一表示
#[derive(Debug, Clone)]
pub enum HeapObj {
    // ---- 复合类型（7）----
    /// 字符串
    Str(GlueStr),
    /// 数组
    Array(ArrayValue),
    /// 记录
    Record(RecordValue),
    /// 代数数据类型实例
    Adt(AdtValue),
    /// Newtype 包装
    Newtype(NewtypeValue),
    /// 可变引用单元
    Cell(Cell),
    /// 范围
    Range(Range),
    // ---- 可调用类型（5）----
    /// 闭包
    Closure(Closure),
    /// 偏应用
    Partial(PartialApplication),
    /// 内建函数
    Builtin(Builtin),
    /// Trait 值
    TraitVal(TraitValue),
    /// 惰性值
    LazyVal(LazyValue),
    // ---- 控制流类型（2）----
    /// 错误值
    ErrorVal(ErrorValue),
    /// 抛出值
    ThrowVal(ThrowValue),
    // ---- 迭代器类型（3）----
    /// 数组迭代器
    ArrayIter(ArrayIterator),
    /// 字符串迭代器
    StringIter(StringIterator),
    /// 范围迭代器
    RangeIter(RangeIterator),
    // ---- 并发类型（5）----
    /// 原子值
    AtomicVal(AtomicValue),
    /// 异步句柄
    AsyncVal(AsyncHandle),
    /// 通道值
    ChannelVal(ChannelValue),
    /// 发送端
    SenderVal(SenderValue),
    /// 接收端
    ReceiverVal(ReceiverValue),
    // ---- 协程（1）----
    /// 协程帧（占位：协程帧结构复杂，此处仅作标记）
    CoroutineFrame,
}

/// 堆引用：引用计数的堆对象
pub type HeapRef = Rc<HeapObj>;

// =========================================================================
// RefKind — 引用类型判别
// =========================================================================

/// 引用类型枚举：镜像 Zig 实现的 `RefKind`，用于运行时类型判别
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefKind {
    Str,
    Array,
    Record,
    Adt,
    Newtype,
    Cell,
    Range,
    Closure,
    Partial,
    Builtin,
    TraitVal,
    LazyVal,
    ErrorVal,
    ThrowVal,
    ArrayIter,
    StringIter,
    RangeIter,
    AtomicVal,
    AsyncVal,
    ChannelVal,
    SenderVal,
    ReceiverVal,
    CoroutineFrame,
}

impl HeapObj {
    /// 获取引用类型
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

    /// 获取类型名称
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

    /// 获取显示名称（用于调试与错误信息）
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

    /// 是否可记忆化（值不可变且可安全缓存）
    pub fn is_memoizable(&self) -> bool {
        matches!(
            self,
            HeapObj::Str(_)
                | HeapObj::Array(_)
                | HeapObj::Record(_)
                | HeapObj::Adt(_)
                | HeapObj::Newtype(_)
                | HeapObj::Range(_)
                | HeapObj::ErrorVal(_)
                | HeapObj::ThrowVal(_)
        )
    }
}

// =========================================================================
// Hash — 与 heap_equals 一深的内容哈希（保持 HashMap 不变量）
// =========================================================================

impl std::hash::Hash for HeapObj {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        // 先写入判别式，确保不同变体哈希不同
        std::mem::discriminant(self).hash(state);
        match self {
            // 值相等类型：按内容哈希
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
                // Cell equals 比较内部值
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
                crate::value::control::ThrowPayload::Ok(v) => {
                    0u8.hash(state);
                    v.hash(state);
                }
                crate::value::control::ThrowPayload::Err(r) => {
                    1u8.hash(state);
                    // Err 按指针相等：使用 Rc 指针地址
                    let ptr: *const RecordValue = Rc::as_ptr(r);
                    ptr.hash(state);
                }
            },
            // 引用相等类型：按关键字段哈希（与 equals 一致）
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
            // 其余类型 equals 对不同 Rc 实例返回 false，哈希可为任意值
            // 使用类型名保证不同 RefKind 哈希不同
            HeapObj::Partial(_) | HeapObj::TraitVal(_) | HeapObj::LazyVal(_)
            | HeapObj::AtomicVal(_) | HeapObj::AsyncVal(_) | HeapObj::ChannelVal(_)
            | HeapObj::SenderVal(_) | HeapObj::ReceiverVal(_) | HeapObj::CoroutineFrame => {
                // 无额外内容：仅判别式即可
            }
        }
    }
}
