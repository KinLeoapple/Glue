//! 迭代器堆对象类型：数组迭代器、字符串迭代器、范围迭代器
//!
//! 对应 Zig 实现中的迭代器值类型。迭代器持有底层数据的引用（`Rc`），
//! 每次 `next` 调用推进内部游标。

use std::rc::Rc;

use crate::value::Value;

// =========================================================================
// ArrayIterator — 数组迭代器
// =========================================================================

/// 数组迭代器：按顺序遍历数组元素
#[derive(Debug, Clone)]
pub struct ArrayIterator {
    /// 底层数组（共享引用）
    pub array: Rc<Vec<Value>>,
    /// 当前索引
    pub index: usize,
}

impl ArrayIterator {
    /// 创建数组迭代器
    pub fn new(array: Rc<Vec<Value>>) -> Self {
        Self { array, index: 0 }
    }

    /// 推进迭代器，返回下一个元素的克隆
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

// =========================================================================
// StringIterator — 字符串迭代器
// =========================================================================

/// 字符串迭代器：按 Unicode 码点遍历字符串
#[derive(Debug, Clone)]
pub struct StringIterator {
    /// 底层字符串（共享引用）
    pub string: Rc<str>,
    /// 当前字节偏移
    pub byte_offset: usize,
}

impl StringIterator {
    /// 创建字符串迭代器
    pub fn new(string: Rc<str>) -> Self {
        Self { string, byte_offset: 0 }
    }

    /// 推进迭代器，返回下一个码点
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

// =========================================================================
// RangeIterator — 范围迭代器
// =========================================================================

/// 范围迭代器：按顺序产生范围内的整数
#[derive(Debug, Clone)]
pub struct RangeIterator {
    /// 当前值
    pub current: i64,
    /// 结束值
    pub end: i64,
    /// 是否包含结束值
    pub inclusive: bool,
}

impl RangeIterator {
    /// 创建范围迭代器
    pub fn new(start: i64, end: i64, inclusive: bool) -> Self {
        Self {
            current: start,
            end,
            inclusive,
        }
    }

    /// 推进迭代器，返回下一个整数
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
