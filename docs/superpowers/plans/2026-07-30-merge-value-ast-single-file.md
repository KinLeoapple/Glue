# 合并 Value + AST 为单文件实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `rust/src/value/` 14 文件合并为 `rust/src/Value.rs`，`rust/src/ast/` 8 文件合并为 `rust/src/Ast.rs`，同时通过 ScalarValue union + 宏模板 + ptr_eq 缓存简化代码并优化性能。

**Architecture:** Value enum 从 20 变体收拢为 4 变体（Null/Void/Scalar/Ref），18 种标量由 ScalarValue union + ScalarTag 判别式表示。宏生成标量 API 和堆访问器，消除 7 处 22 臂 match。deep_clone 加 ptr_eq 缓存防爆裂复制。batch.rs 删 13 个冗余函数。Ast.rs 纯物理合并。

**Tech Stack:** Rust 2021, bumpalo (AST arena), std::rc::Rc (引用计数)

**Spec:** `docs/superpowers/specs/2026-07-30-merge-value-ast-single-file-design.md`

---

## 阶段一：Ast.rs 合并（任务 1）

### Task 1: 创建 Ast.rs 并合并 8 个 AST 文件

**Files:**
- Create: `rust/src/Ast.rs`
- Modify: `rust/src/lib.rs`
- Modify: `rust/src/main.rs`
- Delete: `rust/src/ast/` 目录下所有 8 个文件

**合并顺序**（按依赖序）：span → op → node → binary_op_table → lexer → parser → printer

- [ ] **Step 1: 创建 Ast.rs，内联 span.rs 内容**

读取 `rust/src/ast/span.rs` 全文，写入 `rust/src/Ast.rs` 开头（含模块文档注释 `//! Ast.rs — Glue 语法树（合并 8 个子模块）`）。

- [ ] **Step 2: 追加 op.rs 内容**

读取 `rust/src/ast/op.rs` 全文，追加到 `Ast.rs`。删除 op.rs 中的 `use crate::ast::span::Spanned;`（因已同文件），改为直接使用 `Spanned`。

- [ ] **Step 3: 追加 node.rs 内容**

读取 `rust/src/ast/node.rs` 全文，追加到 `Ast.rs`。删除 node.rs 中的 `use crate::ast::op::*;` 和 `use crate::ast::span::Spanned;`，改为直接引用。

- [ ] **Step 4: 追加 binary_op_table.rs 内容**

读取 `rust/src/ast/binary_op_table.rs` 全文，追加到 `Ast.rs`。删除其中的 `use crate::ast::op::*;`。

- [ ] **Step 5: 追加 lexer.rs 内容**

读取 `rust/src/ast/lexer.rs` 全文，追加到 `Ast.rs`。删除其中的 `use crate::ast::span::Span;`（如有）。

- [ ] **Step 6: 追加 parser.rs 内容**

读取 `rust/src/ast/parser.rs` 全文，追加到 `Ast.rs`。删除所有 `use crate::ast::*;`、`use crate::ast::op::*;`、`use crate::ast::node::*;`、`use crate::ast::binary_op_table::*;`、`use crate::ast::lexer::*;`、`use crate::ast::span::*;`。

- [ ] **Step 7: 追加 printer.rs 内容**

读取 `rust/src/ast/printer.rs` 全文，追加到 `Ast.rs`。删除所有 `use crate::ast::*;` 引用。

- [ ] **Step 8: 在 Ast.rs 末尾添加 re-exports**

```rust
// =========================================================================
// Re-exports
// =========================================================================

pub use span::{Span, Spanned};
pub use op::*;
pub use node::*;
pub use binary_op_table::{lookup_binary_op, BINARY_OPS, OpMapping};
pub use lexer::{Lexer, Token, TokenKind};
pub use parser::{Parser, ParseError};
pub use printer::{print_module, Printer};
```

- [ ] **Step 9: 更新 lib.rs**

将 `rust/src/lib.rs` 内容改为：

```rust
pub mod Ast;
pub mod Value;
```

注意：`Value` 模块尚不存在，此时编译会报错。先只改 ast 部分：

```rust
#[path = "Ast.rs"]
pub mod Ast;
pub mod value;
```

- [ ] **Step 10: 更新 main.rs**

将 `rust/src/main.rs` 第 13 行：
```rust
use glue_rs::ast::{Lexer, Parser, Printer};
```
改为：
```rust
use glue_rs::Ast::{Lexer, Parser, Printer};
```

- [ ] **Step 11: 删除旧 ast/ 目录**

```bash
cd /Users/haojunhuang/CLionProjects/Glue/rust
rm -rf src/ast/
```

- [ ] **Step 12: 验证编译**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo build 2>&1 | tail -20`
Expected: 编译通过（可能有 unused warning）

- [ ] **Step 13: 验证测试**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo test --lib 2>&1 | tail -5`
Expected: 177 passed; 0 failed

- [ ] **Step 14: 验证 AST diff**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo build --release 2>&1 | tail -2 && bash tools/diff_ast.sh 2>&1 | tail -3`
Expected: 99/99 passed

- [ ] **Step 15: Commit**

```bash
cd /Users/haojunhuang/CLionProjects/Glue
git add rust/src/Ast.rs rust/src/lib.rs rust/src/main.rs
git rm -r rust/src/ast/
git commit -m "refactor(rust): merge ast/ 8 files into single Ast.rs"
```

---

## 阶段二：Value.rs 核心结构（任务 2-5）

### Task 2: 创建 Value.rs 骨架 — 标量基础类型

**Files:**
- Create: `rust/src/Value.rs`

- [ ] **Step 1: 创建 Value.rs，写入模块文档和标量基础类型**

```rust
//! Value.rs — Glue 统一值系统（合并 14 个子模块）
//!
//! 架构：ScalarValue union + ScalarTag 收拢 18 种标量 → 单变体
//! 尺寸：24 字节（tag 1 + pad 7 + payload 16，对齐 8）

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::sync::Mutex;

// =========================================================================
// 第一部分：标量基础类型
// =========================================================================

/// F16: IEEE 754 binary16，存 bit pattern
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F16(pub u16);

impl F16 {
    pub fn from_f32(x: f32) -> Self { F16(f32_to_f16_bits(x)) }
    pub fn to_f32(self) -> f32 { f16_bits_to_f32(self.0) }
    pub fn from_f64(x: f64) -> Self { Self::from_f32(x as f32) }
    pub fn to_f64(self) -> f64 { self.to_f32() as f64 }
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
    pub fn to_bits(self) -> u16 { self.0 }
    pub fn from_bits(b: u16) -> Self { F16(b) }
}

impl fmt::Debug for F16 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.is_nan() { write!(f, "NaN(f16)") }
        else if self.is_infinite() {
            if self.0 >> 15 != 0 { write!(f, "-inf(f16)") } else { write!(f, "inf(f16)") }
        } else { write!(f, "{}f16", self.to_f32()) }
    }
}

impl fmt::Display for F16 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { fmt::Debug::fmt(self, f) }
}

/// F128: IEEE 754 binary128，存 bit pattern
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F128(pub u128);

impl F128 {
    pub fn from_f64(x: f64) -> Self { F128(f64_to_f128_bits(x)) }
    pub fn to_f64(self) -> f64 { f128_bits_to_f64(self.0) }
    pub fn is_nan(self) -> bool {
        let exp = (self.0 >> 112) & 0x7FFF;
        let mant = self.0 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant != 0
    }
    pub fn is_infinite(self) -> bool {
        let exp = (self.0 >> 112) & 0x7FFF;
        let mant = self.0 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant == 0
    }
    pub fn to_bits(self) -> u128 { self.0 }
    pub fn from_bits(b: u128) -> Self { F128(b) }
}

impl fmt::Debug for F128 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.is_nan() { write!(f, "NaN(f128)") }
        else if self.is_infinite() {
            if self.0 >> 127 != 0 { write!(f, "-inf(f128)") } else { write!(f, "inf(f128)") }
        } else { write!(f, "{}f128", self.to_f64()) }
    }
}

impl fmt::Display for F128 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { fmt::Debug::fmt(self, f) }
}

/// Char: Unicode 码点
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Char { pub codepoint: u32 }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharError { InvalidCodepoint }

impl Char {
    pub fn from_codepoint(cp: u32) -> Result<Self, CharError> {
        if cp > 0x10FFFF || (0xD800..=0xDFFF).contains(&cp) {
            return Err(CharError::InvalidCodepoint);
        }
        Ok(Char { codepoint: cp })
    }
    pub fn from_codepoint_unchecked(cp: u32) -> Self { Char { codepoint: cp } }
    pub fn codepoint(self) -> u32 { self.codepoint }
    pub fn is_ascii(self) -> bool { self.codepoint < 0x80 }
    pub fn is_digit(self) -> bool { (b'0' as u32..=b'9' as u32).contains(&self.codepoint) }
    pub fn is_alpha(self) -> bool {
        (b'a' as u32..=b'z' as u32).contains(&self.codepoint)
            || (b'A' as u32..=b'Z' as u32).contains(&self.codepoint)
    }
    pub fn is_alphanumeric(self) -> bool { self.is_alpha() || self.is_digit() }
    pub fn is_whitespace(self) -> bool {
        matches!(self.codepoint, 0x20 | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D)
    }
    pub fn to_uppercase(self) -> Self {
        if self.is_alpha() && self.codepoint >= b'a' as u32 {
            Char { codepoint: self.codepoint - 32 }
        } else { self }
    }
    pub fn to_lowercase(self) -> Self {
        if self.is_alpha() && self.codepoint < b'a' as u32 {
            Char { codepoint: self.codepoint + 32 }
        } else { self }
    }
    pub fn to_digit(self) -> Option<u32> {
        if self.is_digit() { Some(self.codepoint - b'0' as u32) } else { None }
    }
}

impl From<char> for Char {
    fn from(c: char) -> Self { Char { codepoint: c as u32 } }
}

impl fmt::Display for Char {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if let Some(c) = char::from_u32(self.codepoint) { write!(f, "{}", c) }
        else { write!(f, "\\u{:04X}", self.codepoint) }
    }
}

// ---- F16/F128 bits 转换（从原 scalar.rs 复制）----

fn f32_to_f16_bits(x: f32) -> u16 {
    // 从原 scalar.rs 完整复制 f32_to_f16_bits 函数体
    // （此处省略，实施时从 scalar.rs:80-200 复制）
    todo!("从 scalar.rs 复制 f32_to_f16_bits 实现")
}

fn f16_bits_to_f32(bits: u16) -> f32 {
    todo!("从 scalar.rs 复制 f16_bits_to_f32 实现")
}

fn f64_to_f128_bits(x: f64) -> u128 {
    todo!("从 scalar.rs 复制 f64_to_f128_bits 实现")
}

fn f128_bits_to_f64(bits: u128) -> f64 {
    todo!("从 scalar.rs 复制 f128_bits_to_f64 实现")
}
```

**注意**：`f32_to_f16_bits` 等 4 个函数需从 `rust/src/value/scalar.rs` 完整复制实现，不能用 `todo!`。

- [ ] **Step 2: 从 scalar.rs 复制 4 个 bits 转换函数**

读取 `rust/src/value/scalar.rs` 中 `f32_to_f16_bits`、`f16_bits_to_f32`、`f64_to_f128_bits`、`f128_bits_to_f64` 的完整实现，替换 Value.rs 中的 4 个 `todo!`。

- [ ] **Step 3: 验证编译（独立检查）**

此时 Value.rs 尚未接入 lib.rs，无法编译。跳过此步，下个任务继续。

- [ ] **Step 4: Commit（暂不提交，下个任务一起）**

---

### Task 3: Value.rs 添加 ScalarTag + ScalarValue union + Value enum

**Files:**
- Modify: `rust/src/Value.rs`（追加）

- [ ] **Step 1: 追加 ScalarTag 枚举**

```rust
// =========================================================================
// 第二部分：ScalarTag + ScalarValue union
// =========================================================================

/// 标量类型标签：18 种标量的判别式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScalarTag {
    Bool, Char,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Isize, Usize,
    F16, F32, F64, F128,
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
        matches!(self, ScalarTag::I8 | ScalarTag::I16 | ScalarTag::I32 | ScalarTag::I64
            | ScalarTag::I128 | ScalarTag::U8 | ScalarTag::U16 | ScalarTag::U32
            | ScalarTag::U64 | ScalarTag::U128 | ScalarTag::Isize | ScalarTag::Usize)
    }
    pub fn is_float(self) -> bool {
        matches!(self, ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128)
    }
    pub fn is_signed(self) -> bool {
        matches!(self, ScalarTag::I8 | ScalarTag::I16 | ScalarTag::I32 | ScalarTag::I64
            | ScalarTag::I128 | ScalarTag::Isize)
    }
    pub fn is_bool(self) -> bool { matches!(self, ScalarTag::Bool) }
    pub fn is_char(self) -> bool { matches!(self, ScalarTag::Char) }
    pub fn is_numeric(self) -> bool { self.is_int() || self.is_float() }
    pub fn name(self) -> &'static str {
        match self {
            ScalarTag::Bool => "bool", ScalarTag::Char => "char",
            ScalarTag::I8 => "i8", ScalarTag::I16 => "i16", ScalarTag::I32 => "i32",
            ScalarTag::I64 => "i64", ScalarTag::I128 => "i128",
            ScalarTag::U8 => "u8", ScalarTag::U16 => "u16", ScalarTag::U32 => "u32",
            ScalarTag::U64 => "u64", ScalarTag::U128 => "u128",
            ScalarTag::Isize => "isize", ScalarTag::Usize => "usize",
            ScalarTag::F16 => "f16", ScalarTag::F32 => "f32", ScalarTag::F64 => "f64",
            ScalarTag::F128 => "f128",
        }
    }
    pub fn all() -> &'static [ScalarTag] {
        &[ScalarTag::Bool, ScalarTag::Char, ScalarTag::I8, ScalarTag::I16,
          ScalarTag::I32, ScalarTag::I64, ScalarTag::I128, ScalarTag::U8,
          ScalarTag::U16, ScalarTag::U32, ScalarTag::U64, ScalarTag::U128,
          ScalarTag::Isize, ScalarTag::Usize, ScalarTag::F16, ScalarTag::F32,
          ScalarTag::F64, ScalarTag::F128]
    }
    pub fn from_name(name: &str) -> Option<ScalarTag> {
        Self::all().iter().find(|t| t.name() == name).copied()
    }
}

/// 标量值联合体：18 种标量共享 16 字节 payload
///
/// 安全性：所有访问必须通过 ScalarTag 守卫，不可直接 union 读取。
#[derive(Clone, Copy)]
pub union ScalarValue {
    pub b: bool,
    pub cp: u32,
    pub i8_: i8,   pub i16_: i16,  pub i32_: i32,  pub i64_: i64,
    pub i128_: i128,
    pub u8_: u8,   pub u16_: u16,  pub u32_: u32,  pub u64_: u64,
    pub u128_: u128,
    pub isz_: isize,  pub usz_: usize,
    pub f16_: u16,
    pub f32_: f32,
    pub f64_: f64,
    pub f128_: u128,
}
```

- [ ] **Step 2: 追加 Value enum**

```rust
// =========================================================================
// 第三部分：Value 核心枚举（4 变体）
// =========================================================================

/// Glue 统一值：标量内联 + 堆对象引用
///
/// 尺寸：24 字节 = tag(1) + pad(7) + ScalarValue(16) + ScalarTag(1) + pad(7)
/// 对齐 8，比旧版 20 变体省 8 字节
#[derive(Clone)]
pub enum Value {
    Null,
    Void,
    Scalar(ScalarValue, ScalarTag),
    Ref(HeapRef),
}

impl Default for Value {
    fn default() -> Self { Value::Void }
}
```

- [ ] **Step 3: Commit（暂不提交）**

---

### Task 4: Value.rs 添加堆对象类型（合并 6 个文件）

**Files:**
- Modify: `rust/src/Value.rs`（追加）

**合并来源**：str.rs, composite.rs, callable.rs, control.rs, iterator.rs, concurrent.rs, heap.rs

- [ ] **Step 1: 追加 GlueStr（来自 str.rs）**

将 `rust/src/value/str.rs` 全文内容追加到 Value.rs，删除其中的 `use std::rc::Rc;`（已在文件头引入）和 `use std::cmp::Ordering;`（已引入）。保留 `use std::fmt;` 等（已引入）。

具体内容：`GlueStr` struct + impl（new/from_str/bytes/byte_len/codepoint_count/is_empty/concat/equals/compare）+ PartialEq/Eq/Hash/Display impl。

- [ ] **Step 2: 追加复合堆对象（来自 composite.rs）**

将 `rust/src/value/composite.rs` 全文内容追加到 Value.rs，删除 `use crate::value::Value;`（同文件）和 `use std::cell::RefCell;`（已引入）。

包含：ArrayValue, RecordField, RecordValue, AdtField, AdtValue, NewtypeValue, Cell, Range, RangeIter。

- [ ] **Step 3: 追加可调用堆对象（来自 callable.rs）**

将 `rust/src/value/callable.rs` 全文内容追加到 Value.rs，删除 `use crate::value::Value;` 和 `use std::rc::Rc;`。

包含：BuiltinFn, Builtin, Closure, PartialApplication, TraitValue, LazyValue。

- [ ] **Step 4: 追加控制流堆对象（来自 control.rs）**

将 `rust/src/value/control.rs` 全文内容追加到 Value.rs，删除 `use crate::value::Value;` 和 `use crate::value::composite::RecordValue;`（已同文件）。

包含：ErrorValue, ThrowPayload, ThrowValue。

- [ ] **Step 5: 追加迭代器堆对象（来自 iterator.rs）**

将 `rust/src/value/iterator.rs` 全文内容追加到 Value.rs，删除 `use crate::value::Value;` 和 `use std::rc::Rc;`。

包含：ArrayIterator, StringIterator, RangeIterator。

- [ ] **Step 6: 追加并发堆对象（来自 concurrent.rs）**

将 `rust/src/value/concurrent.rs` 全文内容追加到 Value.rs，删除 `use crate::value::Value;`、`use std::rc::Rc;`、`use std::sync::Mutex;`。

包含：AtomicValue, AsyncStatus, AsyncHandle, ChannelValue, SenderValue, ReceiverValue。

- [ ] **Step 7: 追加 HeapObj 枚举（来自 heap.rs）**

将 `rust/src/value/heap.rs` 全文内容追加到 Value.rs，删除所有 `use` 语句。包含：HeapObj enum（23 变体）+ HeapRef type alias + RefKind enum + impl（ref_kind/type_name/display_name/is_memoizable）+ Hash impl。

- [ ] **Step 8: Commit（暂不提交）**

---

### Task 5: Value.rs 添加宏生成 API + 构造器 + 访问器

**Files:**
- Modify: `rust/src/Value.rs`（追加）

- [ ] **Step 1: 追加标量构造器宏**

```rust
// =========================================================================
// 第四部分：宏生成标量 API
// =========================================================================

macro_rules! impl_scalar_api {
    ($($tag:ident => $field:ident : $ty:ty, $name:literal);* $(;)?) => {
        impl Value {
            $(
                #[inline]
                pub fn $field(v: $ty) -> Self {
                    Value::Scalar(ScalarValue { $field: v }, ScalarTag::$tag)
                }
            )*

            pub fn scalar_type_name(tag: ScalarTag) -> &'static str {
                match tag {
                    $(ScalarTag::$tag => $name,)*
                }
            }
        }
    };
}

impl_scalar_api! {
    Bool  => bool:  bool,  "bool";
    I8    => i8_:   i8,    "i8";
    I16   => i16_:  i16,   "i16";
    I32   => i32_:  i32,   "i32";
    I64   => i64_:  i64,   "i64";
    I128  => i128_: i128,  "i128";
    U8    => u8_:   u8,    "u8";
    U16   => u16_:  u16,   "u16";
    U32   => u32_:  u32,   "u32";
    U64   => u64_:  u64,   "u64";
    U128  => u128_: u128,  "u128";
    Isize => isz_:  isize, "isize";
    Usize => usz_:  usize, "usize";
    F32   => f32_:  f32,   "f32";
    F64   => f64_:  f64,   "f64";
}
```

- [ ] **Step 2: 追加标量访问器宏**

```rust
macro_rules! impl_scalar_accessors {
    ($($method:ident => $field:ident : $ty:ty, $tag:ident);* $(;)?) => {
        impl Value {
            $(
                #[inline]
                pub fn $method(&self) -> Option<$ty> {
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

impl_scalar_accessors! {
    as_bool   => b:     bool,  Bool;
    as_i8     => i8_:   i8,    I8;
    as_i16    => i16_:  i16,   I16;
    as_i32    => i32_:  i32,   I32;
    as_i64    => i64_:  i64,   I64;
    as_i128   => i128_: i128,  I128;
    as_u8     => u8_:   u8,    U8;
    as_u16    => u16_:  u16,   U16;
    as_u32    => u32_:  u32,   U32;
    as_u64    => u64_:  u64,   U64;
    as_u128   => u128_: u128,  U128;
    as_isize  => isz_:  isize, Isize;
    as_usize  => usz_:  usize, Usize;
    as_f32    => f32_:  f32,   F32;
    as_f64    => f64_:  f64,   F64;
}
```

- [ ] **Step 3: 追加 Char/F16/F128 特殊构造器和访问器**

```rust
// Char/F16/F128 特殊处理（构造参数非原生类型）
impl Value {
    #[inline]
    pub fn char(c: Char) -> Self {
        Value::Scalar(ScalarValue { cp: c.codepoint }, ScalarTag::Char)
    }

    #[inline]
    pub fn char_from_codepoint(cp: u32) -> Self {
        Value::Scalar(ScalarValue { cp }, ScalarTag::Char)
    }

    #[inline]
    pub fn from_rust_char(c: char) -> Self {
        Value::Scalar(ScalarValue { cp: c as u32 }, ScalarTag::Char)
    }

    #[inline]
    pub fn as_char(&self) -> Option<Char> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::Char => {
                Some(Char { codepoint: unsafe { sv.cp } })
            }
            _ => None,
        }
    }

    #[inline]
    pub fn f16(v: F16) -> Self {
        Value::Scalar(ScalarValue { f16_: v.0 }, ScalarTag::F16)
    }

    #[inline]
    pub fn as_f16(&self) -> Option<F16> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::F16 => {
                Some(F16(unsafe { sv.f16_ }))
            }
            _ => None,
        }
    }

    #[inline]
    pub fn f128(v: F128) -> Self {
        Value::Scalar(ScalarValue { f128_: v.0 }, ScalarTag::F128)
    }

    #[inline]
    pub fn as_f128(&self) -> Option<F128> {
        match self {
            Value::Scalar(sv, t) if *t == ScalarTag::F128 => {
                Some(F128(unsafe { sv.f128_ }))
            }
            _ => None,
        }
    }
}
```

- [ ] **Step 4: 追加 Null/Void 构造器 + int_from_i64**

```rust
impl Value {
    #[inline] pub fn null() -> Self { Value::Null }
    #[inline] pub fn void() -> Self { Value::Void }

    /// 从 i64 按 tag 构造对应整数
    pub fn int_from_i64(tag: ScalarTag, v: i64) -> Self {
        match tag {
            ScalarTag::I8    => Value::i8(v as i8),
            ScalarTag::I16   => Value::i16(v as i16),
            ScalarTag::I32   => Value::i32(v as i32),
            ScalarTag::I64   => Value::i64(v),
            ScalarTag::I128  => Value::i128(v as i128),
            ScalarTag::U8    => Value::u8(v as u8),
            ScalarTag::U16   => Value::u16(v as u16),
            ScalarTag::U32   => Value::u32(v as u32),
            ScalarTag::U64   => Value::u64(v as u64),
            ScalarTag::U128  => Value::u128(v as u128),
            ScalarTag::Isize => Value::isz(v as isize),
            ScalarTag::Usize => Value::usz(v as usize),
            _ => Value::I64(v),
        }
    }
}
```

注意：`int_from_i64` 的 fallback 分支 `Value::I64(v)` 需改为 `Value::i64(v)`，因为已无 `Value::I64` 变体。修正：

```rust
            _ => Value::i64(v),
```

- [ ] **Step 5: 追加堆对象构造器（来自 mod.rs 原堆构造器）**

将 `rust/src/value/mod.rs` 中第 196-372 行的所有堆构造器方法追加到 Value.rs。需将 `Value::Bool(b)` 等旧变体引用改为新 API。具体方法：

```rust
impl Value {
    pub fn heap(obj: HeapObj) -> Self { Value::Ref(Rc::new(obj)) }
    pub fn from_ref(r: HeapRef) -> Self { Value::Ref(r) }
    pub fn str(s: impl Into<String>) -> Self { Value::heap(HeapObj::Str(GlueStr::new(s))) }
    pub fn str_from(s: &str) -> Self { Value::heap(HeapObj::Str(GlueStr::from_str(s))) }
    pub fn from_glue_str(s: GlueStr) -> Self { Value::heap(HeapObj::Str(s)) }
    pub fn array(elements: Vec<Value>) -> Self { Value::heap(HeapObj::Array(ArrayValue::new(elements))) }
    pub fn array_fixed(elements: Vec<Value>, size: u64) -> Self { Value::heap(HeapObj::Array(ArrayValue::new_fixed(elements, size))) }
    pub fn record(type_name: impl Into<String>, fields: Vec<Value>, field_names: Vec<Option<String>>) -> Self {
        Value::heap(HeapObj::Record(RecordValue::new(type_name.into(), fields, field_names)))
    }
    pub fn adt(type_name: impl Into<String>, constructor: impl Into<String>, fields: Vec<AdtField>) -> Self {
        Value::heap(HeapObj::Adt(AdtValue::new(type_name.into(), constructor.into(), fields)))
    }
    pub fn newtype(type_name: impl Into<String>, inner: Value) -> Self {
        Value::heap(HeapObj::Newtype(NewtypeValue { type_name: type_name.into(), inner }))
    }
    pub fn cell(val: Value) -> Self { Value::heap(HeapObj::Cell(Cell::new(val))) }
    pub fn range(start: i64, end: i64, inclusive: bool) -> Self { Value::heap(HeapObj::Range(Range::new(start, end, inclusive))) }
    pub fn closure(c: Closure) -> Self { Value::heap(HeapObj::Closure(c)) }
    pub fn partial(p: PartialApplication) -> Self { Value::heap(HeapObj::Partial(p)) }
    pub fn builtin(fn_ptr: BuiltinFn, name: impl Into<String>) -> Self {
        Value::heap(HeapObj::Builtin(Builtin { fn_ptr, name: name.into() }))
    }
    pub fn trait_val(t: TraitValue) -> Self { Value::heap(HeapObj::TraitVal(t)) }
    pub fn lazy(l: LazyValue) -> Self { Value::heap(HeapObj::LazyVal(l)) }
    pub fn error_val(type_name: impl Into<String>, message: impl Into<String>, is_error_subtype: bool) -> Self {
        Value::heap(HeapObj::ErrorVal(ErrorValue { type_name: type_name.into(), message: message.into(), is_error_subtype }))
    }
    pub fn throw_ok(val: Value) -> Self {
        Value::heap(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Ok(val) }))
    }
    pub fn throw_err(record: Rc<RecordValue>) -> Self {
        Value::heap(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    }
    pub fn array_iter(array: Rc<Vec<Value>>) -> Self { Value::heap(HeapObj::ArrayIter(ArrayIterator::new(array))) }
    pub fn string_iter(s: Rc<str>) -> Self { Value::heap(HeapObj::StringIter(StringIterator::new(s))) }
    pub fn range_iter(start: i64, end: i64, inclusive: bool) -> Self { Value::heap(HeapObj::RangeIter(RangeIterator::new(start, end, inclusive))) }
    pub fn atomic(val: Value) -> Self { Value::heap(HeapObj::AtomicVal(AtomicValue::new(val))) }
    pub fn async_handle() -> Self { Value::heap(HeapObj::AsyncVal(AsyncHandle::new())) }
    pub fn channel(capacity: usize) -> Self { Value::heap(HeapObj::ChannelVal(ChannelValue::new(capacity))) }
    pub fn sender(channel: Rc<ChannelValue>) -> Self { Value::heap(HeapObj::SenderVal(SenderValue { channel })) }
    pub fn receiver(channel: Rc<ChannelValue>) -> Self { Value::heap(HeapObj::ReceiverVal(ReceiverValue { channel })) }
}
```

- [ ] **Step 6: 追加堆访问器宏**

```rust
// =========================================================================
// 第五部分：堆访问器宏
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
    as_str         => Str        as GlueStr;
    as_array       => Array      as ArrayValue;
    as_record      => Record     as RecordValue;
    as_adt         => Adt        as AdtValue;
    as_newtype     => Newtype    as NewtypeValue;
    as_cell        => Cell       as Cell;
    as_range       => Range      as Range;
    as_closure     => Closure    as Closure;
    as_partial     => Partial    as PartialApplication;
    as_builtin     => Builtin    as Builtin;
    as_trait_val   => TraitVal   as TraitValue;
    as_lazy        => LazyVal    as LazyValue;
    as_error_val   => ErrorVal   as ErrorValue;
    as_throw_val   => ThrowVal   as ThrowValue;
    as_channel     => ChannelVal as ChannelValue;
    as_atomic      => AtomicVal  as AtomicValue;
    as_async_handle => AsyncVal  as AsyncHandle;
    as_sender      => SenderVal  as SenderValue;
    as_receiver    => ReceiverVal as ReceiverValue;
}
```

- [ ] **Step 7: 追加 as_ref / ref_kind**

```rust
impl Value {
    #[inline]
    pub fn as_ref(&self) -> Option<&HeapRef> {
        match self { Value::Ref(r) => Some(r), _ => None }
    }

    pub fn ref_kind(&self) -> Option<RefKind> {
        match self { Value::Ref(r) => Some(r.ref_kind()), _ => None }
    }
}
```

- [ ] **Step 8: Commit（暂不提交）**

---

## 阶段三：Value.rs 谓词 + equals + deep_clone（任务 6-7）

### Task 6: Value.rs 添加谓词 + type_name + scalar_tag

**Files:**
- Modify: `rust/src/Value.rs`（追加）

- [ ] **Step 1: 追加谓词方法**

```rust
// =========================================================================
// 第六部分：谓词
// =========================================================================

impl Value {
    pub fn is_null(&self) -> bool { matches!(self, Value::Null) }
    pub fn is_void(&self) -> bool { matches!(self, Value::Void) }
    pub fn is_bool(&self) -> bool { matches!(self, Value::Scalar(_, t) if *t == ScalarTag::Bool) }
    pub fn is_char(&self) -> bool { matches!(self, Value::Scalar(_, t) if *t == ScalarTag::Char) }

    pub fn is_int(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if t.is_int())
    }
    pub fn is_float(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if t.is_float())
    }
    pub fn is_numeric(&self) -> bool {
        matches!(self, Value::Scalar(_, t) if t.is_numeric())
    }
    pub fn is_scalar(&self) -> bool {
        matches!(self, Value::Scalar(_, _))
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
    pub fn is_ref(&self) -> bool { matches!(self, Value::Ref(_)) }

    pub fn is_callable(&self) -> bool {
        matches!(self, Value::Ref(r) if matches!(r.as_ref(),
            HeapObj::Closure(_) | HeapObj::Partial(_) | HeapObj::Builtin(_) | HeapObj::TraitVal(_)))
    }

    pub fn requires_release(&self) -> bool { self.is_ref() }
}
```

- [ ] **Step 2: 追加 type_name + scalar_tag + 整数/浮点提升**

```rust
impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Void => "void",
            Value::Scalar(_, t) => t.name(),
            Value::Ref(r) => r.type_name(),
        }
    }

    pub fn scalar_tag(&self) -> Option<ScalarTag> {
        match self {
            Value::Scalar(_, t) => Some(*t),
            _ => None,
        }
    }

    pub fn as_int_i64(&self) -> Option<i64> {
        match self {
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::I8    => Some(sv.i8_ as i64),
                    ScalarTag::I16   => Some(sv.i16_ as i64),
                    ScalarTag::I32   => Some(sv.i32_ as i64),
                    ScalarTag::I64   => Some(sv.i64_),
                    ScalarTag::I128  => Some(sv.i128_ as i64),
                    ScalarTag::U8    => Some(sv.u8_ as i64),
                    ScalarTag::U16   => Some(sv.u16_ as i64),
                    ScalarTag::U32   => Some(sv.u32_ as i64),
                    ScalarTag::U64   => Some(sv.u64_ as i64),
                    ScalarTag::U128  => Some(sv.u128_ as i64),
                    ScalarTag::Isize => Some(sv.isz_ as i64),
                    ScalarTag::Usize => Some(sv.usz_ as i64),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    pub fn as_int_i128(&self) -> Option<i128> {
        match self {
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::I8    => Some(sv.i8_ as i128),
                    ScalarTag::I16   => Some(sv.i16_ as i128),
                    ScalarTag::I32   => Some(sv.i32_ as i128),
                    ScalarTag::I64   => Some(sv.i64_ as i128),
                    ScalarTag::I128  => Some(sv.i128_),
                    ScalarTag::U8    => Some(sv.u8_ as i128),
                    ScalarTag::U16   => Some(sv.u16_ as i128),
                    ScalarTag::U32   => Some(sv.u32_ as i128),
                    ScalarTag::U64   => Some(sv.u64_ as i128),
                    ScalarTag::U128  => Some(sv.u128_ as i128),
                    ScalarTag::Isize => Some(sv.isz_ as i128),
                    ScalarTag::Usize => Some(sv.usz_ as i128),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    pub fn as_float_f64(&self) -> Option<f64> {
        match self {
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::F16  => Some(F16(sv.f16_).to_f64()),
                    ScalarTag::F32  => Some(sv.f32_ as f64),
                    ScalarTag::F64  => Some(sv.f64_),
                    ScalarTag::F128 => Some(F128(sv.f128_).to_f64()),
                    _ => None,
                }
            }
            _ => None,
        }
    }
}
```

- [ ] **Step 3: Commit（暂不提交）**

---

### Task 7: Value.rs 添加 equals + deep_clone + Hash + Debug/Display

**Files:**
- Modify: `rust/src/Value.rs`（追加）

- [ ] **Step 1: 追加 equals 实现**

```rust
// =========================================================================
// 第七部分：equals（ptr_eq 快速路径 + 标量 tag 比较）
// =========================================================================

const EQUALS_MAX_DEPTH: u32 = 4096;

impl Value {
    pub fn equals(&self, other: &Value) -> bool {
        equals_impl(self, other, 0)
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool { self.equals(other) }
}

impl Eq for Value {}

fn equals_impl(a: &Value, b: &Value, depth: u32) -> bool {
    if depth > EQUALS_MAX_DEPTH { return false; }

    match (a, b) {
        (Value::Null, Value::Null) => return true,
        (Value::Void, Value::Void) => return true,
        (Value::Scalar(sv, st), Value::Scalar(ov, ot)) => {
            if st != ot { return false; }
            unsafe { scalar_equals(sv, ov, *st) }
        }
        (Value::Ref(x), Value::Ref(y)) => {
            if Rc::ptr_eq(x, y) { return true; }
            heap_equals(x, y, depth + 1)
        }
        _ => false,
    }
}

unsafe fn scalar_equals(a: &ScalarValue, b: &ScalarValue, tag: ScalarTag) -> bool {
    match tag {
        ScalarTag::Bool  => a.b == b.b,
        ScalarTag::Char  => a.cp == b.cp,
        ScalarTag::I8    => a.i8_ == b.i8_,
        ScalarTag::I16   => a.i16_ == b.i16_,
        ScalarTag::I32   => a.i32_ == b.i32_,
        ScalarTag::I64   => a.i64_ == b.i64_,
        ScalarTag::I128  => a.i128_ == b.i128_,
        ScalarTag::U8    => a.u8_ == b.u8_,
        ScalarTag::U16   => a.u16_ == b.u16_,
        ScalarTag::U32   => a.u32_ == b.u32_,
        ScalarTag::U64   => a.u64_ == b.u64_,
        ScalarTag::U128  => a.u128_ == b.u128_,
        ScalarTag::Isize => a.isz_ == b.isz_,
        ScalarTag::Usize => a.usz_ == b.usz_,
        ScalarTag::F16   => a.f16_ == b.f16_,
        ScalarTag::F32   => a.f32_.to_bits() == b.f32_.to_bits(),
        ScalarTag::F64   => a.f64_.to_bits() == b.f64_.to_bits(),
        ScalarTag::F128  => a.f128_ == b.f128_,
    }
}
```

- [ ] **Step 2: 追加 heap_equals（从 mod.rs 复制并适配）**

将 `rust/src/value/mod.rs` 中 `heap_equals` 函数（第 1020-1099 行）完整复制到 Value.rs。无需修改（已使用 HeapObj 匹配）。

- [ ] **Step 3: 追加 deep_clone（带 ptr_eq 缓存）**

```rust
// =========================================================================
// 第八部分：deep_clone（ptr_eq 缓存防爆裂复制）
// =========================================================================

const DEEP_CLONE_MAX_DEPTH: u32 = 4096;

impl Value {
    pub fn deep_clone(&self) -> Value {
        let mut cache: HashMap<*const HeapObj, HeapRef> = HashMap::new();
        deep_clone_impl(self, 0, &mut cache)
    }
}

fn deep_clone_impl(v: &Value, depth: u32, cache: &mut HashMap<*const HeapObj, HeapRef>) -> Value {
    if depth > DEEP_CLONE_MAX_DEPTH { return v.clone(); }
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

fn heap_deep_clone(obj: &HeapObj, depth: u32, cache: &mut HashMap<*const HeapObj, HeapRef>) -> HeapObj {
    if depth > DEEP_CLONE_MAX_DEPTH { return obj.clone(); }
    match obj {
        HeapObj::Str(s) => HeapObj::Str(s.clone()),
        HeapObj::Array(a) => {
            let elements: Vec<Value> = a.elements.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Array(ArrayValue { elements, fixed_size: a.fixed_size, elem_is_ref: a.elem_is_ref })
        }
        HeapObj::Record(r) => {
            let fields: Vec<Value> = r.fields.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Record(RecordValue {
                type_name: r.type_name.clone(), fields,
                field_names: r.field_names.clone(), field_ref_bits: r.field_ref_bits,
            })
        }
        HeapObj::Adt(a) => {
            let fields: Vec<AdtField> = a.fields.iter().map(|f| AdtField {
                name: f.name.clone(), value: deep_clone_impl(&f.value, depth + 1, cache),
            }).collect();
            HeapObj::Adt(AdtValue {
                type_name: a.type_name.clone(), constructor: a.constructor.clone(),
                fields, field_ref_bits: a.field_ref_bits,
            })
        }
        HeapObj::Newtype(n) => HeapObj::Newtype(NewtypeValue {
            type_name: n.type_name.clone(), inner: deep_clone_impl(&n.inner, depth + 1, cache),
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
                func_id: c.func_id, arity: c.arity, upvalues, bound_args,
                self_upvalue_idx: c.self_upvalue_idx, upvalue_ref_bits: c.upvalue_ref_bits,
                cell_upvalues: c.cell_upvalues,
            })
        }
        HeapObj::Partial(p) => {
            let bound_args: Vec<Value> = p.bound_args.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::Partial(PartialApplication {
                func_id: p.func_id, bound_args, remaining_arity: p.remaining_arity,
                bound_arg_ref_bits: p.bound_arg_ref_bits,
            })
        }
        HeapObj::Builtin(b) => HeapObj::Builtin(b.clone()),
        HeapObj::TraitVal(t) => {
            let method_values: Vec<Value> = t.method_values.iter().map(|e| deep_clone_impl(e, depth + 1, cache)).collect();
            HeapObj::TraitVal(TraitValue {
                trait_name: t.trait_name.clone(), method_names: t.method_names.clone(),
                method_values, data: t.data.as_ref().map(|d| deep_clone_impl(d, depth + 1, cache)),
                owned: t.owned,
            })
        }
        HeapObj::LazyVal(l) => {
            let cached = l.cached.as_ref().map(|c| deep_clone_impl(c, depth + 1, cache));
            HeapObj::LazyVal(LazyValue { cached, forced: l.forced, thunk: l.thunk.clone() })
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
```

- [ ] **Step 4: 追加 Hash impl**

```rust
// =========================================================================
// 第九部分：Hash
// =========================================================================

impl Hash for Value {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            Value::Null | Value::Void => {}
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::Bool  => sv.b.hash(state),
                    ScalarTag::Char  => sv.cp.hash(state),
                    ScalarTag::I8    => sv.i8_.hash(state),
                    ScalarTag::I16   => sv.i16_.hash(state),
                    ScalarTag::I32   => sv.i32_.hash(state),
                    ScalarTag::I64   => sv.i64_.hash(state),
                    ScalarTag::I128  => sv.i128_.hash(state),
                    ScalarTag::U8    => sv.u8_.hash(state),
                    ScalarTag::U16   => sv.u16_.hash(state),
                    ScalarTag::U32   => sv.u32_.hash(state),
                    ScalarTag::U64   => sv.u64_.hash(state),
                    ScalarTag::U128  => sv.u128_.hash(state),
                    ScalarTag::Isize => sv.isz_.hash(state),
                    ScalarTag::Usize => sv.usz_.hash(state),
                    ScalarTag::F16   => sv.f16_.hash(state),
                    ScalarTag::F32   => sv.f32_.to_bits().hash(state),
                    ScalarTag::F64   => sv.f64_.to_bits().hash(state),
                    ScalarTag::F128  => sv.f128_.hash(state),
                }
            },
            Value::Ref(r) => r.hash(state),
        }
    }
}
```

- [ ] **Step 5: 追加 Debug/Display impl**

```rust
// =========================================================================
// 第十部分：Debug / Display
// =========================================================================

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Null => write!(f, "null"),
            Value::Void => write!(f, "()"),
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::Bool  => write!(f, "{}", sv.b),
                    ScalarTag::Char  => write!(f, "'{}'", Char { codepoint: sv.cp }),
                    ScalarTag::I8    => write!(f, "{}i8", sv.i8_),
                    ScalarTag::I16   => write!(f, "{}i16", sv.i16_),
                    ScalarTag::I32   => write!(f, "{}", sv.i32_),
                    ScalarTag::I64   => write!(f, "{}i64", sv.i64_),
                    ScalarTag::I128  => write!(f, "{}i128", sv.i128_),
                    ScalarTag::U8    => write!(f, "{}u8", sv.u8_),
                    ScalarTag::U16   => write!(f, "{}u16", sv.u16_),
                    ScalarTag::U32   => write!(f, "{}u32", sv.u32_),
                    ScalarTag::U64   => write!(f, "{}u64", sv.u64_),
                    ScalarTag::U128  => write!(f, "{}u128", sv.u128_),
                    ScalarTag::Isize => write!(f, "{}isize", sv.isz_),
                    ScalarTag::Usize => write!(f, "{}usize", sv.usz_),
                    ScalarTag::F16   => write!(f, "{:?}", F16(sv.f16_)),
                    ScalarTag::F32   => write!(f, "{}f32", sv.f32_),
                    ScalarTag::F64   => write!(f, "{}", sv.f64_),
                    ScalarTag::F128  => write!(f, "{:?}", F128(sv.f128_)),
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
            Value::Scalar(sv, t) => unsafe {
                match t {
                    ScalarTag::Bool  => write!(f, "{}", sv.b),
                    ScalarTag::Char  => write!(f, "{}", Char { codepoint: sv.cp }),
                    ScalarTag::I8    => write!(f, "{}", sv.i8_),
                    ScalarTag::I16   => write!(f, "{}", sv.i16_),
                    ScalarTag::I32   => write!(f, "{}", sv.i32_),
                    ScalarTag::I64   => write!(f, "{}", sv.i64_),
                    ScalarTag::I128  => write!(f, "{}", sv.i128_),
                    ScalarTag::U8    => write!(f, "{}", sv.u8_),
                    ScalarTag::U16   => write!(f, "{}", sv.u16_),
                    ScalarTag::U32   => write!(f, "{}", sv.u32_),
                    ScalarTag::U64   => write!(f, "{}", sv.u64_),
                    ScalarTag::U128  => write!(f, "{}", sv.u128_),
                    ScalarTag::Isize => write!(f, "{}", sv.isz_),
                    ScalarTag::Usize => write!(f, "{}", sv.usz_),
                    ScalarTag::F16   => write!(f, "{}", F16(sv.f16_).to_f32()),
                    ScalarTag::F32   => write!(f, "{}", sv.f32_),
                    ScalarTag::F64   => write!(f, "{}", sv.f64_),
                    ScalarTag::F128  => write!(f, "{}", F128(sv.f128_).to_f64()),
                }
            },
            Value::Ref(r) => match r.as_ref() {
                HeapObj::Str(s) => write!(f, "{}", s),
                _ => write!(f, "{:?}", r),
            },
        }
    }
}
```

- [ ] **Step 6: Commit（暂不提交）**

---

## 阶段四：Value.rs 剩余模块 + 测试（任务 8-10）

### Task 8: Value.rs 添加 ops + cast + batch + allocator

**Files:**
- Modify: `rust/src/Value.rs`（追加）

- [ ] **Step 1: 追加 ops.rs 内容**

将 `rust/src/value/ops.rs` 全文追加到 Value.rs，删除 `use` 语句（无）。包含：Num trait + BitOps trait + 整数/浮点 impl。

- [ ] **Step 2: 追加 cast.rs 内容**

将 `rust/src/value/cast.rs` 全文追加到 Value.rs，删除 `use crate::value::scalar::{F16, F128, ScalarTag};`（已同文件）。包含：CastError, ParseError, cast_value, try_cast_value, parse_str 及所有辅助函数。

- [ ] **Step 3: 追加精简后的 batch.rs 内容**

将 `rust/src/value/batch.rs` 精简后追加到 Value.rs。删除以下 13 个函数：
- `batch_bit_and`, `batch_bit_or`, `batch_bit_xor`, `batch_shl`, `batch_shr`（5 个 thin-wrapper）
- `batch_neg`, `batch_abs`, `batch_bit_not`（3 个 thin-wrapper）
- `batch_add_i64`, `batch_mul_i64`, `batch_add_f64`, `batch_mul_f64`, `batch_cmp_f64`, `batch_reduce_sum_f64`, `batch_reduce_sum_i64`（7 个冗余特化）

保留：BinOp, UnaryOp, CmpOp, ReduceOp 枚举 + batch_binop, batch_unaryop, batch_cmp, batch_reduce, batch_select, broadcast 函数。

删除测试中对已删函数的引用（test_batch_add_i64 等改用 batch_binop）。

- [ ] **Step 4: 追加 allocator.rs 内容**

将 `rust/src/value/allocator.rs` 全文追加到 Value.rs，删除 `use std::rc::Rc;` 和 `use crate::value::Value;`。包含：Allocator trait + DefaultAllocator + default_allocator。

- [ ] **Step 5: 追加 re-exports**

```rust
// =========================================================================
// Re-exports
// =========================================================================

pub use scalar::{F16, F128, ScalarTag, ScalarValue};
pub use char::{Char, CharError};
pub use str::GlueStr;
pub use heap::{HeapObj, HeapRef, RefKind};
pub use cast::{cast_value, try_cast_value, CastError};
```

注意：这些类型已在同文件定义，re-export 无需 use。实际只需确保 pub 可见性。删除此 step 或改为确认可见性。

- [ ] **Step 6: 更新 lib.rs 接入 Value.rs**

将 `rust/src/lib.rs` 改为：

```rust
#[path = "Ast.rs"]
pub mod Ast;

#[path = "Value.rs"]
pub mod Value;
```

- [ ] **Step 7: 验证编译**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo build 2>&1 | tail -30`
Expected: 编译通过（可能有 unused warning）。若有错误，修复类型引用（如 `Value::I32` → `Value::i32`）。

- [ ] **Step 8: Commit（暂不提交）**

---

### Task 9: Value.rs 添加测试

**Files:**
- Modify: `rust/src/Value.rs`（追加测试模块）

- [ ] **Step 1: 追加从 mod.rs 复制的测试**

将 `rust/src/value/mod.rs` 中 `#[cfg(test)] mod tests { ... }`（第 1354-1650 行）复制到 Value.rs 末尾。适配：
- `Value::unit()` → `Value::void()`
- `is_unit()` → `is_void()`
- `Value::I32(42)` 模式匹配改为 `Value::i32(42)` 构造（测试中用构造器即可，模式匹配改用 `as_i32()`）

- [ ] **Step 2: 追加从 scalar.rs 复制的测试**

将 `rust/src/value/scalar.rs` 中测试模块复制到 Value.rs 测试模块内。

- [ ] **Step 3: 追加从 char.rs/ops.rs/cast.rs/batch.rs/allocator.rs 复制的测试**

将各文件的测试模块合并到 Value.rs 测试模块。注意 batch 测试中删除对已删函数的引用。

- [ ] **Step 4: 追加新增 union 安全性测试**

```rust
#[cfg(test)]
mod union_tests {
    use super::*;

    #[test]
    fn test_union_construct_access_roundtrip() {
        assert_eq!(Value::i8(-5).as_i8(), Some(-5));
        assert_eq!(Value::i32(42).as_i32(), Some(42));
        assert_eq!(Value::i128(i128::MAX).as_i128(), Some(i128::MAX));
        assert_eq!(Value::u8(255).as_u8(), Some(255));
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
    }

    #[test]
    fn test_f16_f128_bits_roundtrip() {
        let f16 = F16::from_f32(1.5);
        assert_eq!(f16.to_f32(), 1.5);
        let v = Value::f16(f16);
        assert_eq!(v.as_f16(), Some(f16));

        let f128 = F128::from_f64(3.14159);
        assert_eq!(f128.to_f64(), 3.14159);
        let v = Value::f128(f128);
        assert_eq!(v.as_f128(), Some(f128));
    }

    #[test]
    fn test_value_size() {
        assert_eq!(std::mem::size_of::<Value>(), 24);
    }
}
```

- [ ] **Step 5: 追加 ptr_eq 缓存测试**

```rust
#[cfg(test)]
mod deep_clone_cache_tests {
    use super::*;

    #[test]
    fn test_deep_clone_diamond_shares_subgraph() {
        // 菱形引用：outer 两次引用同一 inner
        let inner = Value::array(vec![Value::i32(1), Value::i32(2)]);
        let outer = Value::array(vec![
            Value::Ref(inner.as_ref().unwrap().clone()),
            Value::Ref(inner.as_ref().unwrap().clone()),
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
```

- [ ] **Step 6: 验证测试**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo test --lib 2>&1 | tail -5`
Expected: 全部通过（177+ 新增测试）

- [ ] **Step 7: Commit（暂不提交）**

---

### Task 10: 删除旧 value/ 目录 + 更新外部引用 + 最终验证

**Files:**
- Delete: `rust/src/value/` 目录
- Modify: `rust/tests/value_tests.rs`

- [ ] **Step 1: 删除旧 value/ 目录**

```bash
cd /Users/haojunhuang/CLionProjects/Glue/rust
rm -rf src/value/
```

- [ ] **Step 2: 更新 tests/value_tests.rs 的 use 路径**

将 `rust/tests/value_tests.rs` 开头的：
```rust
use glue_rs::value::*;
```
改为：
```rust
use glue_rs::Value::*;
```

或更精确：
```rust
use glue_rs::Value::{self, *};
```

- [ ] **Step 3: 验证编译**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo build 2>&1 | tail -20`
Expected: 编译通过

- [ ] **Step 4: 验证 lib 测试**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo test --lib 2>&1 | tail -5`
Expected: 全部通过

- [ ] **Step 5: 验证集成测试**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo test 2>&1 | tail -10`
Expected: 全部通过

- [ ] **Step 6: 验证 clippy**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo clippy 2>&1 | tail -5`
Expected: 0 errors

- [ ] **Step 7: 验证 AST diff**

Run: `cd /Users/haojunhuang/CLionProjects/Glue/rust && cargo build --release 2>&1 | tail -2 && bash tools/diff_ast.sh 2>&1 | tail -3`
Expected: 99/99 passed

- [ ] **Step 8: Commit**

```bash
cd /Users/haojunhuang/CLionProjects/Glue
git add rust/src/Value.rs rust/src/lib.rs rust/tests/value_tests.rs
git rm -r rust/src/value/
git commit -m "refactor(rust): merge value/ 14 files into single Value.rs with ScalarValue union

- Value enum: 20 variants → 4 (Null/Void/Scalar/Ref)
- 18 scalars collapsed into ScalarValue union + ScalarTag
- Value size: 32 → 24 bytes
- Macro-generated scalar API and heap accessors
- deep_clone with ptr_eq cache prevents exponential copying
- batch.rs: removed 13 redundant functions (723 → ~350 lines)
- All 177 tests pass + new union safety/size tests"
```

---

## 验收清单

- [ ] `cargo build` 无错误
- [ ] `cargo test --lib` 全部通过（177+ 测试）
- [ ] `cargo test` 全部通过（含集成测试）
- [ ] `cargo clippy` 0 errors
- [ ] AST diff 99/99 通过
- [ ] `rust/src/value/` 目录已删除
- [ ] `rust/src/ast/` 目录已删除
- [ ] `rust/src/Value.rs` 存在且可编译
- [ ] `rust/src/Ast.rs` 存在且可编译
- [ ] `Value` 尺寸为 24 字节（测试断言）
