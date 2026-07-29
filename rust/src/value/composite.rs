//! 复合堆对象类型：数组、记录、ADT、Newtype、Cell、Range
//!
//! 对应 Zig 实现中的复合值类型。可变容器使用 `RefCell`，不可变数据使用 `Rc`。
//! 所有引用 `Value` 的类型通过 `crate::value::Value` 前向引用，
//! 待 `mod.rs` 定义 `Value` 后即可编译。

use std::cell::RefCell;

use crate::value::Value;

// =========================================================================
// ArrayValue — 数组值
// =========================================================================

/// 数组值：元素可变（支持 push/pop），`fixed_size` 为 `Some` 时表示固定大小数组
#[derive(Debug, Clone)]
pub struct ArrayValue {
    /// 元素列表
    pub elements: Vec<Value>,
    /// 固定大小（`[T; N]` 中的 N），`None` 表示动态数组
    pub fixed_size: Option<u64>,
    /// 元素是否为引用类型（影响 GC 标记）
    pub elem_is_ref: bool,
}

impl ArrayValue {
    /// 创建动态数组
    pub fn new(elements: Vec<Value>) -> Self {
        Self {
            elements,
            fixed_size: None,
            elem_is_ref: false,
        }
    }

    /// 创建固定大小数组
    pub fn new_fixed(elements: Vec<Value>, size: u64) -> Self {
        Self {
            elements,
            fixed_size: Some(size),
            elem_is_ref: false,
        }
    }

    /// 元素数量
    pub fn len(&self) -> usize {
        self.elements.len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.elements.is_empty()
    }

    /// 按索引获取元素引用
    pub fn get(&self, index: usize) -> Option<&Value> {
        self.elements.get(index)
    }

    /// 追加元素
    pub fn push(&mut self, val: Value) {
        self.elements.push(val);
    }

    /// 弹出末尾元素
    pub fn pop(&mut self) -> Option<Value> {
        self.elements.pop()
    }
}

// =========================================================================
// RecordValue — 记录值
// =========================================================================

/// 记录字段：可选名称 + 值
#[derive(Debug, Clone)]
pub struct RecordField {
    pub name: Option<String>,
    pub value: Value,
}

/// 记录值：具名类型的结构化数据
#[derive(Debug, Clone)]
pub struct RecordValue {
    /// 类型名称
    pub type_name: String,
    /// 字段值列表（按定义顺序）
    pub fields: Vec<Value>,
    /// 字段名称列表（按定义顺序，`None` 表示匿名字段）
    pub field_names: Vec<Option<String>>,
    /// 字段引用位图：第 i 位为 1 表示第 i 个字段是引用类型
    pub field_ref_bits: u64,
}

impl RecordValue {
    /// 创建记录值
    pub fn new(type_name: String, fields: Vec<Value>, field_names: Vec<Option<String>>) -> Self {
        Self {
            type_name,
            fields,
            field_names,
            field_ref_bits: 0,
        }
    }

    /// 按索引获取字段值
    pub fn get_field(&self, index: usize) -> Option<&Value> {
        self.fields.get(index)
    }

    /// 按名称查找字段值
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

// =========================================================================
// AdtValue — 代数数据类型值
// =========================================================================

/// ADT 字段：构造器的参数
#[derive(Debug, Clone)]
pub struct AdtField {
    pub name: Option<String>,
    pub value: Value,
}

/// ADT 值：代数数据类型实例（如 `Some(x)`、`Ok(v)` 等）
#[derive(Debug, Clone)]
pub struct AdtValue {
    /// 类型名称
    pub type_name: String,
    /// 构造器名称（如 `Some`、`Ok`）
    pub constructor: String,
    /// 构造器字段列表
    pub fields: Vec<AdtField>,
    /// 字段引用位图
    pub field_ref_bits: u64,
}

impl AdtValue {
    /// 创建 ADT 值
    pub fn new(type_name: String, constructor: String, fields: Vec<AdtField>) -> Self {
        Self {
            type_name,
            constructor,
            fields,
            field_ref_bits: 0,
        }
    }

    /// 按索引获取字段值
    pub fn get_field(&self, index: usize) -> Option<&Value> {
        self.fields.get(index).map(|f| &f.value)
    }

    /// 按名称查找字段值
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

// =========================================================================
// NewtypeValue — Newtype 值
// =========================================================================

/// Newtype 值：包装单个内部值的具名类型
#[derive(Debug, Clone)]
pub struct NewtypeValue {
    /// 类型名称
    pub type_name: String,
    /// 内部值
    pub inner: Value,
}

// =========================================================================
// Cell — 可变引用单元
// =========================================================================

/// Cell：可变引用单元，通过 `RefCell` 实现内部可变性
#[derive(Debug, Clone)]
pub struct Cell {
    pub inner: RefCell<Value>,
}

impl Cell {
    /// 创建包含指定值的 Cell
    pub fn new(val: Value) -> Self {
        Self {
            inner: RefCell::new(val),
        }
    }

    /// 获取值的借用引用
    pub fn get(&self) -> std::cell::Ref<Value> {
        self.inner.borrow()
    }

    /// 设置新值
    pub fn set(&self, val: Value) {
        *self.inner.borrow_mut() = val;
    }
}

// =========================================================================
// Range — 范围值
// =========================================================================

/// 范围值：表示整数区间 `[start, end)` 或 `[start, end]`
#[derive(Debug, Clone)]
pub struct Range {
    /// 起始值（包含）
    pub start: i64,
    /// 结束值
    pub end: i64,
    /// 是否包含结束值（`true` 为闭区间 `[start, end]`）
    pub inclusive: bool,
}

impl Range {
    /// 创建范围
    pub fn new(start: i64, end: i64, inclusive: bool) -> Self {
        Self { start, end, inclusive }
    }

    /// 判断值是否在范围内
    pub fn contains(&self, val: i64) -> bool {
        if self.inclusive {
            val >= self.start && val <= self.end
        } else {
            val >= self.start && val < self.end
        }
    }

    /// 范围内元素数量
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

    /// 创建范围迭代器
    pub fn iter(&self) -> RangeIter {
        RangeIter {
            current: self.start,
            end: self.end,
            inclusive: self.inclusive,
        }
    }
}

/// 范围迭代器：逐个产生范围内的整数值
#[derive(Debug, Clone)]
pub struct RangeIter {
    /// 当前迭代位置
    pub current: i64,
    /// 结束值
    pub end: i64,
    /// 是否包含结束值
    pub inclusive: bool,
}
