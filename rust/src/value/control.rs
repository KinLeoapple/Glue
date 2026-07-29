//! 控制流堆对象类型：错误值、抛出值
//!
//! 对应 Zig 实现中的控制流值类型，用于错误处理与异常传播。

use std::rc::Rc;

use crate::value::composite::RecordValue;
use crate::value::Value;

// =========================================================================
// ErrorValue — 错误值
// =========================================================================

/// 错误值：`error_newtype` 的实例，携带类型名与错误消息
#[derive(Debug, Clone)]
pub struct ErrorValue {
    /// 类型名称
    pub type_name: String,
    /// 错误消息
    pub message: String,
    /// 是否为 error 子类型
    pub is_error_subtype: bool,
}

// =========================================================================
// ThrowPayload / ThrowValue — 抛出值
// =========================================================================

/// 抛出载荷：正常值或错误记录
#[derive(Debug, Clone)]
pub enum ThrowPayload {
    /// 正常返回值
    Ok(Value),
    /// 错误记录（引用计数共享）
    Err(Rc<RecordValue>),
}

/// 抛出值：控制流 throw 的运行时表示
#[derive(Debug, Clone)]
pub struct ThrowValue {
    /// 抛出的载荷
    pub payload: ThrowPayload,
}
