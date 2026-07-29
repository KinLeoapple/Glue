# 合并 Value + AST 为单文件设计

> 对应实现计划：`docs/superpowers/plans/2026-07-30-merge-value-ast-single-file.md`

## 目标

将 `rust/src/value/` 下 14 个文件合并为单个 `rust/src/Value.rs`，将 `rust/src/ast/` 下 8 个文件合并为单个 `rust/src/Ast.rs`。同时通过标量结构收拢、宏生成样板代码、ptr_eq 缓存三项手段简化代码并优化性能。

## 非目标

- 不改动 AST 的解析逻辑、token 类型、printer 输出格式（仅物理合并）
- 不改动 HeapObj 的 23 种堆对象语义
- 不引入新的标量类型或堆对象类型
- 不修改 `Cargo.toml` 依赖

## 整体架构

### 文件结构

合并前：
```
rust/src/
  ast/
    mod.rs, span.rs, op.rs, node.rs, binary_op_table.rs,
    lexer.rs, parser.rs, printer.rs
  value/
    mod.rs, scalar.rs, char.rs, ops.rs, cast.rs, str.rs,
    heap.rs, composite.rs, callable.rs, control.rs, iterator.rs,
    concurrent.rs, batch.rs, allocator.rs
  lib.rs, main.rs
```

合并后：
```
rust/src/
  Ast.rs       (合并 ast/ 8 文件)
  Value.rs     (合并 value/ 14 文件)
  lib.rs
  main.rs
```

### Value.rs 核心结构变更

**Value enum：20 变体 → 4 变体**

```rust
pub enum Value {
    Null,
    Void,                              // void 类型的唯一值（原 Unit，统一命名避免误导）
    Scalar(ScalarValue, ScalarTag),    // 替代原 18 个标量变体
    Ref(HeapRef),
}
```

**ScalarValue union**（新增）：

```rust
#[derive(Clone, Copy)]
pub union ScalarValue {
    pub b: bool,
    pub cp: u32,                       // Char codepoint
    pub i8_: i8,   pub i16_: i16,  pub i32_: i32,  pub i64_: i64,
    pub i128_: i128,
    pub u8_: u8,   pub u16_: u16,  pub u32_: u32,  pub u64_: u64,
    pub u128_: u128,
    pub isz_: isize,  pub usz_: usize,
    pub f16_: u16,                     // F16 bits
    pub f32_: f32,
    pub f64_: f64,
    pub f128_: u128,                   // F128 bits
}
```

**ScalarTag**（沿用，18 种）：作为 union 访问的判别式。

**尺寸对比**：

| 版本 | Value enum 判别式 | payload | 对齐 | 总尺寸 |
|---|---|---|---|---|
| 旧 | 1 字节 | 16 字节（i128 撑大） | 8 | 32 字节（含 pad） |
| 新 | 1 字节 | 16 字节（ScalarValue union） + 1 字节 tag | 8 | 24 字节（tag 与 payload 共用对齐填充） |

**说明**：`ScalarValue` 最大成员为 `i128`/`u128`/`f128_`（16 字节），对齐 8。`ScalarTag` 为 1 字节 enum，放在 union 后的填充区，整体 24 字节对齐 8。比旧版省 8 字节，因为旧版 enum 的 discriminant + padding 占 8 字节，payload 占 16 字节，但 i128 要求 16 字节对齐导致额外 padding。

### 宏生成样板代码

**标量 API 宏**（替代 7 处 22 臂 match）：

```rust
macro_rules! impl_scalar_api {
    ($($tag:ident => $field:ident : $ty:ty, $name:literal);* $(;)?) => {
        impl Value {
            $(
                #[inline]
                pub fn $field(v: $ty) -> Self {
                    Value::Scalar(ScalarValue { $field: v }, ScalarTag::$tag)
                }

                #[inline]
                pub fn $field(&self) -> Option<$ty> {
                    match self {
                        Value::Scalar(sv, t) if *t == ScalarTag::$tag => {
                            Some(unsafe { sv.$field })
                        }
                        _ => None,
                    }
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
```

新增标量类型只需：①在 `ScalarTag` 加一项；②在宏调用加一行。原方案需改 8 处。

**堆访问器宏**（替代 22 个 `as_*` 方法）：

```rust
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
```

### 命名统一：Unit → Void

Glue 语言已统一使用 `void`，消除 `unit` 命名误导：
- `Value::Unit` → `Value::Void`，`Value::unit()` → `Value::void()`，`is_unit()` → `is_void()`
- `Expr::UnitLit` → `Expr::VoidLit`，printer 输出 `(unit_lit)` → `(void_lit)`
- Zig 端 `tools/ast_printer.zig` 同步改为 `(void_lit)`，保持 AST diff 一致
- Zig 端 AST 节点 `.unit_literal` 名称保留（内部实现，不影响输出）

### 特殊标量处理

**Char**：存 `u32` codepoint，构造/访问单独写（不走宏，因构造参数是 `Char` 而非原生类型）。

**F16/F128**：存 bits（`u16`/`u128`），构造/访问单独写（构造参数是 `F16`/`F128`，内部存 bits）。

### deep_clone 优化：ptr_eq 缓存

原 `deep_clone` 对共享子图（如菱形引用）会爆裂复制。新增 `HashMap<*const HeapObj, HeapRef>` 缓存：

```rust
pub fn deep_clone(&self) -> Value {
    let mut cache = HashMap::new();
    deep_clone_impl(self, 0, &mut cache)
}

fn deep_clone_impl(
    v: &Value, depth: u32,
    cache: &mut HashMap<*const HeapObj, HeapRef>,
) -> Value {
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
```

### batch.rs 精简

删除冗余代码：
- 6 个 thin-wrapper：`batch_bit_and`/`batch_bit_or`/`batch_bit_xor`/`batch_shl`/`batch_shr`/`batch_neg` 等，用户直接调 `batch_binop`/`batch_unaryop`
- 7 个 i64/f64 特化：`batch_add_i64`/`batch_mul_i64`/`batch_add_f64`/`batch_mul_f64`/`batch_cmp_f64`/`batch_reduce_sum_f64`/`batch_reduce_sum_i64`，泛型 + `T: Num` 已自动向量化

保留核心泛型函数：
- `batch_binop<T: Num>`
- `batch_unaryop<T: Num>`
- `batch_cmp<T: PartialOrd>`
- `batch_reduce<T: Num>`
- `batch_select<T: Copy>`
- `broadcast<T: Copy>`

行数：723 → ~350。

### Ast.rs 合并

纯物理合并，按依赖顺序内联：
1. `span.rs`（Span, Spanned）
2. `op.rs`（BinaryOp, UnaryOp, Param, TypeParam 等辅助类型）
3. `node.rs`（Expr, Stmt, Decl, TypeNode, Pattern, Module）
4. `binary_op_table.rs`（BINARY_OPS 静态表）
5. `lexer.rs`（TokenKind, Token, Lexer）
6. `parser.rs`（Parser, ParseError）
7. `printer.rs`（print_module, Printer）

消除所有跨文件 `use crate::ast::*`，保留对外 `pub use`。

## 安全性考虑

### union 访问安全性

`ScalarValue` 是 `union`，直接读取未激活成员是 UB。保证规则：
1. 所有 union 读取必须通过 `ScalarTag` 守卫
2. 构造时 tag 与字段必须匹配
3. `unsafe` 块仅出现在：①宏生成的访问器（tag 守卫）；②`scalar_equals`/`cast` 等内部函数（tag 已校验）
4. 外部代码不直接接触 `ScalarValue`，只通过 `Value::i32()` 等类型安全 API

### F16/F128 bits 语义

- `PartialEq`/`Hash` 按 bits 比较，保证 `NaN != NaN`（IEEE 754 语义）
- `equals()` 中 F16/F128 走 bits 比较，与原实现一致
- `Display`/`Debug` 转换为 `f32`/`f64` 显示

## 测试策略

1. **保留现有 177 个测试**，全部适配新 API
2. **新增 union 安全性测试**：
   - 构造后访问返回正确值
   - 错误 tag 访问返回 `None`
   - F16/F128 bits 往返一致性
3. **新增 ptr_eq 缓存测试**：
   - 菱形引用 deep_clone 后共享子图指针相等
   - 独立对象 deep_clone 后指针不等
4. **尺寸断言测试**：
   - `assert_eq!(std::mem::size_of::<Value>(), 24)`

## 影响范围

| 文件 | 变化 |
|---|---|
| `rust/src/Value.rs` | 新建，合并 14 文件，~2000 行（原 5518 行） |
| `rust/src/Ast.rs` | 新建，合并 8 文件，~7600 行（原 7638 行，几乎不变） |
| `rust/src/value/` | 删除整个目录 |
| `rust/src/ast/` | 删除整个目录 |
| `rust/src/lib.rs` | `pub mod ast` → `pub mod Ast`，`pub mod value` → `pub mod Value` |
| `rust/src/main.rs` | `use crate::ast::*` → `use crate::Ast::*` |
| `rust/tests/value_tests.rs` | 适配新 API（构造器名不变，访问器名不变） |

## 预期效果

| 指标 | 当前 | 合并后 |
|---|---|---|
| value/ 文件数 | 14 | 1 (Value.rs) |
| ast/ 文件数 | 8 | 1 (Ast.rs) |
| Value enum 变体 | 20 | 4 |
| Value 尺寸 | 32 字节 | 24 字节 |
| mod.rs 样板 match 臂 | 22×7=154 | 4×7=28 |
| 新增标量改动处 | 8 | 2（宏+ScalarTag） |
| batch.rs 行数 | 723 | ~350 |
| deep_clone 爆裂复制风险 | 有 | 无（ptr_eq 缓存） |
| 测试数 | 177 | 177+（含新增 union/尺寸测试） |

## 风险

1. **union unsafe**：需严格 tag 守卫，测试覆盖所有标量构造-访问往返
2. **Char/F16/F128 特殊处理**：不走宏，单独写构造器/访问器
3. **cast.rs 重写**：~50 处 union 读取需适配
4. **大文件**：Value.rs ~2000 行，Ast.rs ~7600 行，但逻辑清晰分节
5. **文件名大小写**：Rust 模块名惯例小写，但用户要求 `Value.rs`/`Ast.rs`，需在 `lib.rs` 用 `#[path = "Value.rs"] pub mod Value;`

## 迁移步骤（概要）

1. 创建 `Value.rs`：按 10 节结构组装（标量基础 → 堆对象 → Value enum → 宏 → equals → deep_clone → cast → ops/batch → allocator → 测试）
2. 创建 `Ast.rs`：按依赖顺序内联 8 文件
3. 更新 `lib.rs`/`main.rs` 模块声明
4. 适配测试
5. 删除旧 `value/`/`ast/` 目录
6. 验证：`cargo build` + `cargo test --lib` + `cargo clippy`
7. AST diff 验证：`rust/tools/diff_ast.sh` 保持 99/99 通过
