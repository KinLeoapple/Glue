//! 内存分配器 trait：为运行时值分配提供抽象接口
//!
//! 对应 Zig 实现中的 arena/buddy 分配器。Rust 版本当前使用 `Rc` 引用计数
//! 作为默认策略；后续可扩展为 arena 或 buddy 分配器实现。
//!
//! 设计原则：
//! - `Allocator` trait 提供字符串与数组的分配接口
//! - `DefaultAllocator` 使用标准 `Rc` 分配，零额外开销
//! - 未来可替换为 `ArenaAllocator`（bumpalo）或 `BuddyAllocator` 无需修改调用方

use std::rc::Rc;

use crate::value::Value;

// =========================================================================
// Allocator trait
// =========================================================================

/// 内存分配器 trait：抽象值分配策略
///
/// 所有方法接收 `&self`，实现可持有内部可变状态（如 `RefCell`）或为无状态（`Default`）。
/// trait 带 `Clone` bound，便于在协程帧与上下文中按值传递。
pub trait Allocator: Clone {
    /// 分配字符串，返回 `Rc<str>` 共享引用
    fn alloc_str(&self, s: &str) -> Rc<str>;

    /// 分配值数组，返回 `Rc<Vec<Value>>` 共享引用
    fn alloc_array(&self, vals: Vec<Value>) -> Rc<Vec<Value>>;

    /// 分配单个堆对象值（默认实现：直接构造 `Value`）
    fn alloc_value(&self, val: Value) -> Value {
        // 值类型已自带 `Rc`，无需额外分配
        val
    }
}

// =========================================================================
// DefaultAllocator — 默认分配器（基于 Rc）
// =========================================================================

/// 默认分配器：使用标准库 `Rc` 进行引用计数分配
///
/// 无内部状态，所有分配直接构造 `Rc`。
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

// =========================================================================
// 全局默认分配器
// =========================================================================

/// 获取全局默认分配器实例
pub fn default_allocator() -> DefaultAllocator {
    DefaultAllocator
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
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
