//! Glue 字符串类型：基于 `Rc<str>` 的引用计数字符串
//!
//! 对应 Zig 实现中的 GlueString，使用 Rust 的 `Rc` 替代手动引用计数。
//! 字符串内容不可变，`concat` 等操作会产生新的 `GlueStr`。

use std::cmp::Ordering;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

/// Glue 字符串：引用计数的不可变 UTF-8 字符串
#[derive(Debug, Clone)]
pub struct GlueStr {
    inner: Rc<str>,
}

impl GlueStr {
    /// 从任意可转换为 `String` 的值创建字符串
    pub fn new(s: impl Into<String>) -> Self {
        Self {
            inner: Rc::from(s.into().as_str()),
        }
    }

    /// 从 `&str` 直接创建，共享底层数据
    pub fn from_str(s: &str) -> Self {
        Self {
            inner: Rc::from(s),
        }
    }

    /// 获取字符串字节切片
    pub fn bytes(&self) -> &str {
        &self.inner
    }

    /// 字节长度
    pub fn byte_len(&self) -> usize {
        self.inner.len()
    }

    /// Unicode 码点数量
    pub fn codepoint_count(&self) -> usize {
        self.inner.chars().count()
    }

    /// 是否为空字符串
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// 拼接两个字符串，返回新的 `GlueStr`
    pub fn concat(&self, other: &Self) -> Self {
        let mut buf = String::with_capacity(self.byte_len() + other.byte_len());
        buf.push_str(&self.inner);
        buf.push_str(&other.inner);
        Self::from_str(&buf)
    }

    /// 判断两个字符串内容是否相等
    pub fn equals(&self, other: &Self) -> bool {
        self.inner == other.inner
    }

    /// 字典序比较
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
