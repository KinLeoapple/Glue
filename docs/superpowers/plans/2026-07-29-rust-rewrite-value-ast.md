# Rust 重写 Value + AST 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Rust 重写 Glue 语言的 `value/` 和 `parse/` 模块，AST 通过全量 .glue diff 验证，Value 完整实现 18 种标量 + 23 种堆对象。

**Architecture:** 基于 Glue 语法规范和值语义规范，用 Rust 原生抽象（enum of Box + Rc + 标准堆）替代 Zig 特有技巧。AST 用 `&'a str` + bumpalo arena 零拷贝。Value 用原生类型标量 + enum of Box 堆对象。

**Tech Stack:** Rust 2021 edition, bumpalo (AST arena), std::rc::Rc (引用计数)

**Spec:** `docs/superpowers/specs/2026-07-29-rust-rewrite-value-ast-design.md`

---

## 阶段一：AST 模块（任务 1-12）

### Task 1: 项目脚手架

**Files:**
- Create: `rust/Cargo.toml`
- Create: `rust/src/lib.rs`
- Create: `rust/src/main.rs`

- [ ] **Step 1: 创建 Cargo.toml**

```toml
[package]
name = "glue-rs"
version = "0.1.0"
edition = "2021"

[dependencies]
bumpalo = "3"

[[bin]]
name = "glue"
path = "src/main.rs"

[lib]
name = "glue_rs"
path = "src/lib.rs"
```

- [ ] **Step 2: 创建 lib.rs**

```rust
pub mod ast;
pub mod value;
```

- [ ] **Step 3: 创建 main.rs 占位**

```rust
use std::env;
use std::fs;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args[1] != "parse" {
        eprintln!("Usage: glue parse <file>");
        process::exit(1);
    }
    let filename = &args[2];
    let source = match fs::read_to_string(filename) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Error reading {}: {}", filename, e);
            process::exit(1);
        }
    };
    // TODO: parse and print AST
    eprintln!("Source: {} bytes", source.len());
}
```

- [ ] **Step 4: 创建空模块目录**

创建 `rust/src/ast/mod.rs` 和 `rust/src/value/mod.rs`，内容暂为空。

- [ ] **Step 5: 验证编译**

Run: `cd rust && cargo build`
Expected: 编译通过（可能有 unused warning）

- [ ] **Step 6: Commit**

```bash
cd /Users/haojunhuang/CLionProjects/Glue
git add rust/
git commit -m "feat(rust): scaffold Cargo project for Value+AST rewrite"
```

---

### Task 2: AST 核心类型 — Span 和 Spanned

**Files:**
- Create: `rust/src/ast/mod.rs` (覆盖)
- Create: `rust/src/ast/span.rs`

- [ ] **Step 1: 编写 span.rs**

```rust
//! AST 源码位置与节点包装

/// 源码位置：行号与列号
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub line: u32,
    pub column: u32,
}

impl Span {
    pub fn new(line: u32, column: u32) -> Self {
        Self { line, column }
    }
}

/// AST 节点包装：将源码位置提取到节点外部
/// Rust 无法用 @fieldParentPtr 反算，改用显式包装
#[derive(Debug, Clone)]
pub struct Spanned<T> {
    pub span: Span,
    pub node: T,
}

impl<T> Spanned<T> {
    pub fn new(span: Span, node: T) -> Self {
        Self { span, node }
    }

    pub fn map<U, F: FnOnce(T) -> U>(self, f: F) -> Spanned<U> {
        Spanned { span: self.span, node: f(self.node) }
    }

    pub fn as_ref(&self) -> Spanned<&T> {
        Spanned { span: self.span, node: &self.node }
    }
}
```

- [ ] **Step 2: 编写 ast/mod.rs**

```rust
//! AST 模块入口

pub mod span;
pub mod op;
pub mod node;
pub mod lexer;
pub mod binary_op_table;
pub mod parser;
pub mod printer;

// Re-exports
pub use span::{Span, Spanned};
pub use op::*;
pub use node::*;
pub use lexer::{Token, TokenKind, Lexer};
pub use parser::{Parser, ParseError};
pub use printer::print_module;
```

- [ ] **Step 3: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -20`
Expected: 报错缺少 op.rs/node.rs 等文件（正常，下个任务创建）

- [ ] **Step 4: Commit**

```bash
git add rust/src/ast/span.rs rust/src/ast/mod.rs
git commit -m "feat(rust): add Span and Spanned<T> types"
```

---

### Task 3: AST 运算符与辅助类型 — op.rs

**Files:**
- Create: `rust/src/ast/op.rs`

完整定义 BinaryOp(22 种)、CompoundAssignOp(10 种)、UnaryOp(3 种)、CastMode(2 种)、Visibility(2 种)、Kind(2 变体)、InterpolationPart(2 变体)、LambdaBody(2 变体)、MatchArm、SelectArm(2 变体)、ImportItem、ConstructorField、RecordFieldType、RecordFieldExpr、Param、TypeParam、TraitBound、TypeConstraint、AssociatedType、ConstructorDef、MethodDecl、DelegateInfo、PatternRecordField、PatternLiteral(6 变体)。

每个类型 derive Debug/Clone/PartialEq。字段使用 `&'a str` 引用源码。

参考 Zig `ast.zig:31-318` 的完整定义，用 Rust enum/struct 重写。

- [ ] **Step 1: 编写所有运算符枚举**

```rust
//! AST 运算符与辅助类型

/// 二元运算符（22 种）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryOp {
    Add, Sub, Mul, Div, Mod,
    Eq, NotEq, RefEq, RefNeq,
    Lt, Gt, LtEq, GtEq,
    And, Or,
    BitAnd, BitOr, BitXor,
    Shl, Shr,
    ConcatList, Range, RangeInclusive, Elvis,
}

/// 复合赋值运算符（10 种）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompoundAssignOp {
    AddAssign, SubAssign, MulAssign, DivAssign, ModAssign,
    BitAndAssign, BitOrAssign, BitXorAssign,
    ShlAssign, ShrAssign,
}

/// 一元运算符（3 种）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    Not, Neg, BitNot,
}

/// cast builder 转换模式
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CastMode {
    To,      // wrap on overflow，Inf panic
    TryTo,   // 越界返回 Throw<T, CastError>
}

/// 可见性
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Visibility {
    Private,
    Public,
}

/// Kind 类型系统
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Star,
    Arrow { param: Box<Kind>, result: Box<Kind> },
}
```

- [ ] **Step 2: 编写辅助结构体**

完整实现 Param、TypeParam、TraitBound、TypeConstraint、RecordFieldType、RecordFieldExpr、ConstructorField、InterpolationPart、LambdaBody、MatchArm、SelectArm、ImportItem、ConstructorDef、MethodDecl、DelegateInfo、AssociatedType、PatternRecordField、PatternLiteral。

所有字符串字段用 `&'a str`。子节点引用用 `ExprRef<'a>`/`TypeRef<'a>`/`PatternRef<'a>`（在 node.rs 中定义）。

- [ ] **Step 3: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -20`
Expected: 报错缺少 node.rs（下个任务创建）

- [ ] **Step 4: Commit**

```bash
git add rust/src/ast/op.rs
git commit -m "feat(rust): add AST operator and auxiliary types"
```

---

### Task 4: AST 节点定义 — node.rs

**Files:**
- Create: `rust/src/ast/node.rs`

完整定义 Expr(34 变体)、Stmt(14 变体)、Decl(6 变体)、TypeNode(10 变体)、Pattern(7 变体)、TypeDef(5 变体)、Module。

参考 spec 3.2 节的 Expr 定义，以及 Zig `ast.zig:97-605` 的完整定义。

- [ ] **Step 1: 定义引用类型别名**

```rust
//! AST 节点定义

use crate::ast::op::*;
use crate::ast::span::Spanned;

pub type ExprRef<'a> = &'a Spanned<Expr<'a>>;
pub type StmtRef<'a> = &'a Spanned<Stmt<'a>>;
pub type TypeRef<'a> = &'a Spanned<TypeNode<'a>>;
pub type PatternRef<'a> = &'a Spanned<Pattern<'a>>;
pub type KindRef<'a> = &'a Spanned<Kind>;
```

- [ ] **Step 2: 定义 TypeNode(10 变体)**

```rust
#[derive(Debug, Clone)]
pub enum TypeNode<'a> {
    Named { name: &'a str },
    SelfType,
    Generic { name: &'a str, args: Vec<TypeRef<'a>> },
    Nullable { inner: TypeRef<'a> },
    RefType { inner: TypeRef<'a> },
    RawPtr { inner: TypeRef<'a> },
    Function { params: Vec<TypeRef<'a>>, return_type: TypeRef<'a> },
    Record { fields: Vec<RecordFieldType<'a>> },
    Array { element_type: TypeRef<'a>, size: Option<u64> },
    KindAnnotated { inner: TypeRef<'a>, kind: KindRef<'a> },
}
```

- [ ] **Step 3: 定义 Pattern(7 变体)**

```rust
#[derive(Debug, Clone)]
pub enum Pattern<'a> {
    Wildcard,
    Literal(PatternLiteral<'a>),
    Variable { name: &'a str },
    Constructor { name: &'a str, patterns: Vec<PatternRef<'a>> },
    Record { fields: Vec<PatternRecordField<'a>> },
    OrPattern { left: PatternRef<'a>, right: PatternRef<'a> },
    Guard { pattern: PatternRef<'a>, condition: ExprRef<'a> },
}
```

- [ ] **Step 4: 定义 Expr(34 变体)**

按 spec 3.2 节完整实现。

- [ ] **Step 5: 定义 Stmt(14 变体)**

```rust
#[derive(Debug, Clone)]
pub enum Stmt<'a> {
    ValDecl { name: &'a str, type_annotation: Option<TypeRef<'a>>, value: ExprRef<'a>, visibility: Visibility },
    VarDecl { name: &'a str, type_annotation: Option<TypeRef<'a>>, value: ExprRef<'a>, visibility: Visibility },
    Assignment { target: ExprRef<'a>, value: ExprRef<'a> },
    FieldAssignment { object: ExprRef<'a>, field: &'a str, value: ExprRef<'a> },
    CompoundAssignment { target: ExprRef<'a>, op: CompoundAssignOp, value: ExprRef<'a> },
    Expression { expr: ExprRef<'a> },
    Return { value: Option<ExprRef<'a>> },
    Defer { expr: ExprRef<'a> },
    Throw { expr: ExprRef<'a> },
    Break,
    Continue,
    For { name: &'a str, iterable: ExprRef<'a>, body: ExprRef<'a> },
    While { condition: ExprRef<'a>, body: ExprRef<'a> },
    Loop { body: ExprRef<'a> },
}
```

- [ ] **Step 6: 定义 Decl(6 变体) 和 Module**

```rust
#[derive(Debug, Clone)]
pub enum Decl<'a> {
    FunDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        params: Vec<Param<'a>>,
        return_type: Option<TypeRef<'a>>,
        bounds: Vec<TraitBound<'a>>,
        body: ExprRef<'a>,
        is_async: bool,
        is_entry: bool,
    },
    TypeDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        implemented_traits: Vec<TraitBound<'a>>,
        type_constraints: Vec<TypeConstraint<'a>>,
        def: TypeDef<'a>,
        methods: Vec<MethodDecl<'a>>,
    },
    TraitDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        parents: Vec<TraitBound<'a>>,
        associated_types: Vec<AssociatedType<'a>>,
        methods: Vec<MethodDecl<'a>>,
    },
    ImportDecl {
        module_path: Vec<&'a str>,
        items: Option<Vec<ImportItem<'a>>>,
        visibility: Visibility,
    },
    PackDecl {
        visibility: Visibility,
        name: &'a str,
    },
    ExprDecl {
        expr: ExprRef<'a>,
        stmt: Option<StmtRef<'a>>,
    },
}

#[derive(Debug, Clone)]
pub struct Module<'a> {
    pub name: &'a str,
    pub source_path: Option<&'a str>,
    pub declarations: Vec<Spanned<Decl<'a>>>,
}
```

- [ ] **Step 7: 定义 TypeDef(5 变体)**

```rust
#[derive(Debug, Clone)]
pub enum TypeDef<'a> {
    Adt { constructors: Vec<ConstructorDef<'a>> },
    Record { fields: Vec<RecordFieldType<'a>> },
    Alias { target: TypeRef<'a> },
    Newtype { name: &'a str, inner: TypeRef<'a> },
    ErrorNewtype { name: &'a str, params: Vec<Param<'a>> },
}
```

- [ ] **Step 8: 添加实用方法**

```rust
impl<'a> Expr<'a> {
    pub fn is_literal(&self) -> bool {
        matches!(self, Expr::IntLit { .. } | Expr::FloatLit { .. }
            | Expr::BoolLit(_) | Expr::CharLit(_)
            | Expr::StrLit(_) | Expr::NullLit | Expr::UnitLit)
    }

    pub fn is_lvalue(&self) -> bool {
        matches!(self, Expr::Ident(_) | Expr::FieldAccess { .. }
            | Expr::Index { .. } | Expr::Deref(_))
    }

    pub fn as_ident(&self) -> Option<&'a str> {
        if let Expr::Ident(name) = self { Some(*name) } else { None }
    }
}

impl<'a> Module<'a> {
    pub fn find_function(&self, name: &str) -> Option<&Spanned<Decl<'a>>> {
        self.declarations.iter().find(|d| {
            if let Decl::FunDecl { name: n, .. } = &d.node { *n == name } else { false }
        })
    }
}
```

- [ ] **Step 9: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -30`
Expected: 报错缺少 lexer.rs/parser.rs/printer.rs（下个任务创建）。类型定义本身应无错误。

- [ ] **Step 10: Commit**

```bash
git add rust/src/ast/node.rs
git commit -m "feat(rust): add AST node definitions (Expr/Stmt/Decl/TypeNode/Pattern)"
```

---

### Task 5: Lexer — lexer.rs

**Files:**
- Create: `rust/src/ast/lexer.rs`

完整实现 80 种 TokenKind + Lexer。参考 Zig `lexer.zig` 完整实现和语法规范 A 节。

关键特性：
- 分号当空白跳过
- 十六/八/二进制整数 + 类型后缀 + 下划线分隔
- 字符串插值（单个 Token，含嵌套花括号处理）
- 嵌套块注释
- `{{` `}}` 转义

- [ ] **Step 1: 定义 TokenKind(80 种)**

完整列出所有 80 种 token。参考语法规范 A.1 节。

- [ ] **Step 2: 定义 Token 和 Lexer 结构**

```rust
pub struct Token<'a> {
    pub kind: TokenKind,
    pub lexeme: &'a str,
    pub line: u32,
    pub column: u32,
}

pub struct Lexer<'a> {
    source: &'a str,
    bytes: &'a [u8],
    pos: usize,
    line: u32,
    column: u32,
}
```

- [ ] **Step 3: 实现 tokenize 主循环**

遍历 source，跳过空白和注释，识别 token。关键字查表。字符串插值处理嵌套花括号。

- [ ] **Step 4: 实现数字扫描**

十进制/十六进制/八进制/二进制整数，浮点（含 `.5` 和指数），类型后缀识别与回退。

- [ ] **Step 5: 实现字符串扫描**

处理 `"..."`，支持 `{{` `}}` 转义和 `${...}` 插值（brace depth 计数）。

- [ ] **Step 6: 实现字符扫描**

处理 `'x'`，支持转义序列和 `\u{...}` Unicode 转义。

- [ ] **Step 7: 实现注释扫描**

行注释 `//`，嵌套块注释 `/* */`。

- [ ] **Step 8: 编写单元测试**

测试关键字、标识符、数字、字符串、运算符、注释。

- [ ] **Step 9: 验证编译和测试**

Run: `cd rust && cargo test ast::lexer`
Expected: 所有 lexer 测试通过

- [ ] **Step 10: Commit**

```bash
git add rust/src/ast/lexer.rs
git commit -m "feat(rust): implement lexer with 80 token kinds"
```

---

### Task 6: 优先级表 — binary_op_table.rs

**Files:**
- Create: `rust/src/ast/binary_op_table.rs`

参考 Zig `binary_op_table.zig` 实现 12 级优先级。

- [ ] **Step 1: 定义优先级常量和映射表**

```rust
use crate::ast::op::BinaryOp;
use crate::ast::lexer::TokenKind;

pub const ELVIS_PREC: u8 = 1;
pub const OR_PREC: u8 = 2;
pub const AND_PREC: u8 = 3;
pub const BIT_OR_PREC: u8 = 4;
pub const BIT_XOR_PREC: u8 = 5;
pub const BIT_AND_PREC: u8 = 6;
pub const SHIFT_PREC: u8 = 7;
pub const EQUALITY_PREC: u8 = 8;
pub const COMPARISON_PREC: u8 = 9;
pub const RANGE_PREC: u8 = 10;
pub const ADDITION_PREC: u8 = 11;
pub const MULTIPLICATION_PREC: u8 = 12;

pub struct OpMapping {
    pub op: BinaryOp,
    pub precedence: u8,
    pub right_assoc: bool,
    pub check_multiline_deref: bool,
}

pub fn lookup(token: TokenKind) -> Option<OpMapping> { ... }
```

- [ ] **Step 2: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -20`
Expected: 编译通过

- [ ] **Step 3: Commit**

```bash
git add rust/src/ast/binary_op_table.rs
git commit -m "feat(rust): add binary operator precedence table"
```

---

### Task 7: Parser 核心 — parser.rs

**Files:**
- Create: `rust/src/ast/parser.rs`

这是最大的任务（~3000 行）。参考 Zig `parser.zig` 完整实现和语法规范 B 节。

- [ ] **Step 1: 定义 Parser 结构和错误**

```rust
pub struct ParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

pub struct Parser<'a> {
    tokens: &'a [Token<'a>],
    current: usize,
    arena: &'a Bump,
    errors: Vec<ParseError>,
    pending_eq: bool,
    pending_gt: bool,
    pending_gt_eq: bool,
}
```

- [ ] **Step 2: 实现 Token 导航（peek/advance/expect）**

含 pending_eq/pending_gt/pending_gt_eq 虚拟 Token 拆分机制。

- [ ] **Step 3: 实现 parseModule**

解析顶层声明序列，含 error recovery（synchronize）。

- [ ] **Step 4: 实现声明解析**

parseFunDecl、parseTypeDecl、parseTraitDecl、parseImportDecl、parsePackDecl。

- [ ] **Step 5: 实现类型解析**

parseType、parseFunctionType、parseNullableType、parsePrimaryType、parseRecordType。

含 expectCloseAngle 虚拟拆分和 checkCloseAngle 检测。

- [ ] **Step 6: 实现 Kind 解析**

parseKind、parseKindArrow、parseKindPrimary。

- [ ] **Step 7: 实现表达式解析入口**

parseExpr → parseBinary（Pratt 优先级爬升）→ parseUnary → parsePostfix → parsePrimary。

- [ ] **Step 8: 实现后缀表达式解析**

call、method_call、field_access、safe_access、safe_method_call、index、slice、propagate、non_null_assert、turbofish。

含 `*` 跨行解引用检查、链式调用禁止。

- [ ] **Step 9: 实现字面量解析**

int/float/bool/char/string/null/unit/void。含负数字面量折叠、字符串插值拆分。

- [ ] **Step 10: 实现容器字面量解析**

array_literal（含 fill 语法 `..`）、record_literal、record_extend（含 spread 语法 `...`）。含 lambda 回溯解析。

- [ ] **Step 11: 实现控制流表达式解析**

if_expr、block、match、select、atomic_expr、lazy、inline_trait_value、cast_builder、type_cast。

含条件不允许括号检查。

- [ ] **Step 12: 实现语句解析**

parseStmt、parseValDecl、parseVarDecl、parseFunStmt、parseReturnStmt、parseDeferStmt、parseThrowStmt、parseForStmt、parseWhileStmt、parseLoopStmt、parseExprOrAssignmentStmt。

含 isStmtStart 判断。

- [ ] **Step 13: 实现模式解析**

parsePattern、parseOrPattern、parsePrimaryPattern。含 wildcard/literal/variable/constructor/record/or_pattern。

- [ ] **Step 14: 实现 match arm 和 select arm 解析**

- [ ] **Step 15: 实现类型参数和 trait 约束解析**

parseTypeParams、parseTraitBounds、parseTypeConstraints、parseTraitBound。

- [ ] **Step 16: 实现 TypeDef 解析**

parseTypeDef（含 ADT/record/alias/newtype/error_newtype 回溯）、parseConstructorDef。

- [ ] **Step 17: 实现 MethodDecl 解析**

含 override/delegate/async/visibility/`&self` 语法糖。

- [ ] **Step 18: 实现辅助方法**

expectCloseAngle、checkCloseAngle、isTurbofishCall、tryParseLambda、parenGroupFollowedByArrow、rejectParenCondition、synchronize。

- [ ] **Step 19: 编写基础测试**

测试简单函数、类型声明、表达式解析。

- [ ] **Step 20: 验证编译和测试**

Run: `cd rust && cargo test ast::parser`
Expected: 基础测试通过

- [ ] **Step 21: Commit**

```bash
git add rust/src/ast/parser.rs
git commit -m "feat(rust): implement recursive descent parser with Pratt parsing"
```

---

### Task 8: AST Printer — printer.rs

**Files:**
- Create: `rust/src/ast/printer.rs`

实现 canonical S-expression 格式输出，用于 diff 验证。

- [ ] **Step 1: 实现 print_module 主函数**

```rust
pub fn print_module(module: &Module) -> String {
    let mut out = String::new();
    print_module_to(module, &mut out);
    out
}

fn print_module_to(module: &Module, out: &mut String) {
    out.push_str(&format!("(module \"{}\"", module.name));
    for decl in &module.declarations {
        out.push('\n');
        print_decl(&decl.node, out);
    }
    out.push(')');
}
```

- [ ] **Step 2: 实现 print_decl**

为每个 Decl 变体实现 S-expression 输出。

- [ ] **Step 3: 实现 print_expr**

为每个 Expr 变体实现 S-expression 输出。

- [ ] **Step 4: 实现 print_stmt / print_type / print_pattern**

- [ ] **Step 5: 测试 printer**

```rust
#[test]
fn test_print_simple_module() {
    // 解析简单 .glue 文件，打印 AST，验证格式
}
```

- [ ] **Step 6: Commit**

```bash
git add rust/src/ast/printer.rs
git commit -m "feat(rust): implement canonical AST printer (S-expression)"
```

---

### Task 9: 完善 main.rs — 端到端解析

**Files:**
- Modify: `rust/src/main.rs`

- [ ] **Step 1: 实现 parse 子命令**

```rust
use glue_rs::ast::{Lexer, Parser};
use bumpalo::Bump;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args[1] != "parse" {
        eprintln!("Usage: glue parse <file>");
        process::exit(1);
    }
    let filename = &args[2];
    let source = match fs::read_to_string(filename) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Error reading {}: {}", filename, e);
            process::exit(1);
        }
    };
    let mut lexer = Lexer::new(&source);
    let tokens = lexer.tokenize();
    let arena = Bump::new();
    let mut parser = Parser::new(&tokens, &arena);
    let module = parser.parse_module(filename);
    if !parser.errors.is_empty() {
        for e in &parser.errors {
            eprintln!("{}:{}:{}: parse error: {}", filename, e.line, e.column, e.message);
        }
        process::exit(1);
    }
    println!("{}", glue_rs::ast::print_module(&module));
}
```

- [ ] **Step 2: 验证端到端解析**

Run: `cd rust && cargo run -- parse ../tests/phase1/src/Main.glue`
Expected: 输出 S-expression AST

- [ ] **Step 3: Commit**

```bash
git add rust/src/main.rs
git commit -m "feat(rust): wire up parse command for end-to-end AST output"
```

---

### Task 10: Zig 侧 AST Printer — ast_printer.zig

**Files:**
- Create: `src/parse/ast_printer.zig`
- Modify: `src/cli/pipeline.zig` (添加 ast-print 子命令)
- Modify: `src/cli/mod.zig` (添加 ast-print 分派)
- Modify: `src/cli/run.zig` (添加 ast-print 处理)

这是对 Zig 侧的唯一改动，用于生成 diff 基准。

- [ ] **Step 1: 实现 ast_printer.zig**

输出与 Rust printer.rs 完全相同的 S-expression 格式。

- [ ] **Step 2: 添加 ast-print 子命令到 CLI**

- [ ] **Step 3: 验证 Zig 侧输出**

Run: `zig build run -- ast-print tests/phase1/src/Main.glue`
Expected: 输出 S-expression AST

- [ ] **Step 4: Commit**

```bash
git add src/parse/ast_printer.zig src/cli/
git commit -m "feat(zig): add ast-print command for canonical AST output"
```

---

### Task 11: Diff 验证脚本

**Files:**
- Create: `rust/tools/diff_ast.sh`

- [ ] **Step 1: 编写 diff 脚本**

```bash
#!/bin/bash
# 遍历所有 .glue 文件，对每个跑 Rust 和 Zig 两版，diff 输出

GLUE_FILES=$(find ../tests ../builtin ../src/builtin ../src/std ../bench -name "*.glue" | sort)
FAIL=0
TOTAL=0
PASS=0

for f in $GLUE_FILES; do
    TOTAL=$((TOTAL + 1))
    RUST_OUT=$(cargo run --quiet -- parse "$f" 2>/dev/null)
    ZIG_OUT=$(zig build run --quiet -- ast-print "$f" 2>/dev/null)
    if [ "$RUST_OUT" == "$ZIG_OUT" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "DIFF: $f"
        diff <(echo "$RUST_OUT") <(echo "$ZIG_OUT") | head -20
    fi
done

echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
```

- [ ] **Step 2: 运行 diff 验证**

Run: `cd rust && bash tools/diff_ast.sh`
Expected: 逐步修复差异直到全部通过

- [ ] **Step 3: 修复差异并迭代**

对每个 diff 文件，分析原因（语法遗漏/格式差异），修复 Rust parser 或 printer，重新验证。

- [ ] **Step 4: Commit**

```bash
git add rust/tools/diff_ast.sh
git commit -m "test(rust): add AST diff validation script"
```

---

### Task 12: AST 全量 diff 通过

**这是一个验证任务，不是编码任务。**

- [ ] **Step 1: 运行全量 diff**

Run: `cd rust && bash tools/diff_ast.sh`
Expected: `=== Results: 90/90 passed, 0 failed ===`

- [ ] **Step 2: 修复所有失败用例**

逐一分析失败用例，修复 Rust parser/printer 或 Zig printer。

- [ ] **Step 3: 最终验证**

Run: `cd rust && bash tools/diff_ast.sh`
Expected: 全部通过

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test(rust): all 90 .glue files pass AST diff validation"
```

---

## 阶段二：Value 模块（任务 13-22）

### Task 13: Value 标量层 — scalar.rs + char.rs

**Files:**
- Create: `rust/src/value/mod.rs` (覆盖空文件)
- Create: `rust/src/value/scalar.rs`
- Create: `rust/src/value/char.rs`

- [ ] **Step 1: 编写 value/mod.rs**

```rust
pub mod scalar;
pub mod char;
pub mod ops;
pub mod cast;
pub mod batch;
pub mod heap;
pub mod str;
pub mod composite;
pub mod callable;
pub mod control;
pub mod iterator;
pub mod concurrent;
pub mod allocator;

pub use scalar::ScalarTag;
pub use char::Char;
pub use heap::{HeapObj, HeapRef};
```

- [ ] **Step 2: 编写 scalar.rs**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScalarTag {
    Bool, Char,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Isize, Usize,
    F16, F32, F64, F128,
}

impl ScalarTag {
    pub fn byte_width(self) -> usize { ... }
    pub fn is_int(self) -> bool { ... }
    pub fn is_float(self) -> bool { ... }
    pub fn is_signed(self) -> bool { ... }
    pub fn name(self) -> &'static str { ... }
    pub fn all() -> &'static [ScalarTag] { ... }
}
```

- [ ] **Step 3: 编写 char.rs**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Char { pub codepoint: u32 }

impl Char {
    pub fn from_codepoint(cp: u32) -> Result<Self, CharError> { ... }
    pub fn is_ascii(self) -> bool { ... }
    pub fn is_digit(self) -> bool { ... }
    pub fn is_alpha(self) -> bool { ... }
}
```

- [ ] **Step 4: 验证编译和测试**

Run: `cd rust && cargo test value::scalar value::char`
Expected: 通过

- [ ] **Step 5: Commit**

```bash
git add rust/src/value/
git commit -m "feat(rust): add Value scalar tag and Char type"
```

---

### Task 14: 标量运算 — ops.rs

**Files:**
- Create: `rust/src/value/ops.rs`

实现算术/位/比较运算。用 trait + 泛型替代 Zig comptime 特化。

- [ ] **Step 1: 定义 Num trait**

```rust
pub trait Num: Sized + Copy {
    fn add(self, other: Self) -> Option<Self>;  // 溢出返回 None
    fn sub(self, other: Self) -> Option<Self>;
    fn mul(self, other: Self) -> Option<Self>;
    fn div(self, other: Self) -> Option<Self>;
    fn neg(self) -> Option<Self>;
}
```

- [ ] **Step 2: 为所有数值类型实现 Num**

i8/i16/i32/i64/i128/u8/u16/u32/u64/u128/isize/usize/f16/f32/f64/f128。

整数用 checked_add 等，浮点直接运算（永不返回 None，除零产生 Inf）。

- [ ] **Step 3: 实现位运算和比较**

bit_and/bit_or/bit_xor/bit_not/eq/ne/lt/gt/le/ge。

- [ ] **Step 4: 实现 Value 层运算分派**

```rust
pub fn value_add(a: &Value, b: &Value) -> Option<Value> { ... }
pub fn value_sub(a: &Value, b: &Value) -> Option<Value> { ... }
// ...
```

- [ ] **Step 5: 测试**

Run: `cd rust && cargo test value::ops`
Expected: 通过

- [ ] **Step 6: Commit**

```bash
git add rust/src/value/ops.rs
git commit -m "feat(rust): implement scalar arithmetic/bitwise/comparison ops"
```

---

### Task 15: 标量转换 — cast.rs

**Files:**
- Create: `rust/src/value/cast.rs`

实现 cast（wrap 语义）和 try_cast（越界报错）。参考 Zig `cast.zig` 语义。

- [ ] **Step 1: 定义错误类型**

```rust
#[derive(Debug, Clone)]
pub enum CastError {
    Overflow,
    ParseFailed(String),
}

#[derive(Debug, Clone)]
pub enum ParseError {
    ParseFailed(String),
}
```

- [ ] **Step 2: 实现 cast（wrap 语义）**

`pub fn cast(src: &Value, dst: ScalarTag) -> Value`

i→i 窄化用 `as` 截断，f→i 饱和，bool/char 转换。

- [ ] **Step 3: 实现 try_cast（越界报错）**

`pub fn try_cast(src: &Value, dst: ScalarTag) -> Result<Value, CastError>`

i→i 窄化检查值域，f→i 检查 NaN/Inf/超范围。

- [ ] **Step 4: 实现 parse_str**

`pub fn parse_str(s: &str, dst: ScalarTag) -> Result<Value, ParseError>`

- [ ] **Step 5: 测试 18×18 转换矩阵**

Run: `cd rust && cargo test value::cast`
Expected: 通过

- [ ] **Step 6: Commit**

```bash
git add rust/src/value/cast.rs
git commit -m "feat(rust): implement scalar cast and try_cast with full 18x18 matrix"
```

---

### Task 16: 堆对象定义 — heap.rs + str.rs + composite.rs

**Files:**
- Create: `rust/src/value/heap.rs`
- Create: `rust/src/value/str.rs`
- Create: `rust/src/value/composite.rs`

- [ ] **Step 1: 编写 heap.rs**

```rust
use std::rc::Rc;
use crate::value::str::GlueStr;
use crate::value::composite::*;

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
    CoroutineFrame(CoroutineFrame),
}

pub type HeapRef = Rc<HeapObj>;
```

- [ ] **Step 2: 编写 str.rs**

```rust
use std::rc::Rc;

#[derive(Debug, Clone)]
pub struct GlueStr {
    inner: Rc<str>,
}

impl GlueStr {
    pub fn new(s: impl Into<String>) -> Self { ... }
    pub fn bytes(&self) -> &str { &self.inner }
    pub fn byte_len(&self) -> usize { self.inner.len() }
    pub fn codepoint_count(&self) -> usize { ... }
}
```

- [ ] **Step 3: 编写 composite.rs**

完整定义 ArrayValue/RecordValue/AdtValue/AdtField/NewtypeValue/Cell/Range。

```rust
use std::cell::RefCell;
use std::rc::Rc;
use crate::value::heap::Value;

pub struct ArrayValue {
    pub elements: Vec<Value>,
    pub fixed_size: Option<u64>,
}
// ... 其余类型
```

- [ ] **Step 4: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -20`
Expected: 报错缺少 callable/control/iterator/concurrent（下个任务创建）

- [ ] **Step 5: Commit**

```bash
git add rust/src/value/heap.rs rust/src/value/str.rs rust/src/value/composite.rs
git commit -m "feat(rust): add heap object enum and composite types"
```

---

### Task 17: 剩余堆对象 — callable.rs + control.rs + iterator.rs + concurrent.rs

**Files:**
- Create: `rust/src/value/callable.rs`
- Create: `rust/src/value/control.rs`
- Create: `rust/src/value/iterator.rs`
- Create: `rust/src/value/concurrent.rs`

- [ ] **Step 1: 编写 callable.rs**

Closure/PartialApplication/Builtin/TraitValue/LazyValue。

- [ ] **Step 2: 编写 control.rs**

ErrorValue/ThrowValue/ThrowPayload。

- [ ] **Step 3: 编写 iterator.rs**

ArrayIterator/StringIterator/RangeIterator。

- [ ] **Step 4: 编写 concurrent.rs**

AtomicValue/AsyncHandle/ChannelValue/SenderValue/ReceiverValue。用 std::sync::Mutex。

- [ ] **Step 5: 验证编译**

Run: `cd rust && cargo build 2>&1 | head -20`
Expected: 编译通过

- [ ] **Step 6: Commit**

```bash
git add rust/src/value/callable.rs rust/src/value/control.rs rust/src/value/iterator.rs rust/src/value/concurrent.rs
git commit -m "feat(rust): add callable/control/iterator/concurrent heap objects"
```

---

### Task 18: Value 主体 — mod.rs

**Files:**
- Modify: `rust/src/value/mod.rs`

实现 Value enum + 所有构造/访问/谓词/equals/deep_clone/format 方法。

- [ ] **Step 1: 定义 Value enum**

```rust
use std::rc::Rc;
use crate::value::heap::{HeapObj, HeapRef};
use crate::value::scalar::ScalarTag;

pub enum Value {
    Null,
    Unit,
    Bool(bool),
    Char(u32),
    I8(i8), I16(i16), I32(i32), I64(i64), I128(i128),
    U8(u8), U16(u16), U32(u32), U64(u64), U128(u128),
    Isize(isize), Usize(usize),
    F16(f16), F32(f32), F64(f64), F128(f128),
    Ref(HeapRef),
}
```

- [ ] **Step 2: 实现所有构造器**

null/unit/bool/char/i8...i128/u8...u128/isize/usize/f16...f128（18 种标量）+ str/array/record/adt/newtype/cell/range/closure/...（23 种堆对象）。

- [ ] **Step 3: 实现所有访问器**

as_bool/as_char/as_i8...as_i128/as_u8...as_u128/as_f16...as_f128/as_str/as_array/as_ref 等。

- [ ] **Step 4: 实现谓词**

is_null/is_unit/is_bool/is_char/is_int/is_float/is_numeric/is_string/is_ref/requires_release。

- [ ] **Step 5: 实现 equals（递归 + 深度限制）**

```rust
pub fn equals(&self, other: &Value) -> bool {
    equals_impl(self, other, 0)
}

fn equals_impl(a: &Value, b: &Value, depth: u32) -> bool {
    if depth > 4096 { return false; }
    // ... 按 variant 分派
}
```

- [ ] **Step 6: 实现 deep_clone（递归 + 深度限制）**

- [ ] **Step 7: 实现 to_display_string 和 type_name**

- [ ] **Step 8: 实现 retain/release（Rc::clone/drop）**

- [ ] **Step 9: 测试**

Run: `cd rust && cargo test value::`
Expected: 通过

- [ ] **Step 10: Commit**

```bash
git add rust/src/value/mod.rs
git commit -m "feat(rust): implement Value enum with full construct/access/predicate/equals/clone/format"
```

---

### Task 19: SIMD 批量运算 — batch.rs

**Files:**
- Create: `rust/src/value/batch.rs`

实现类型化切片的 SIMD 批量运算。

- [ ] **Step 1: 定义批量运算枚举**

```rust
pub enum BinOp { Add, Sub, Mul, Div, Mod, Band, Bor, Bxor, Shl, Shr }
pub enum UnaryOp { Neg, Abs, Bnot }
pub enum CmpOp { Lt, Gt, Eq, Ne, Le, Ge }
pub enum ReduceOp { Add, Mul, Band, Bor, Bxor }
```

- [ ] **Step 2: 实现批量运算函数**

```rust
pub fn batch_add<T: Num>(dst: &mut [T], a: &[T], b: &[T])
pub fn batch_mul<T: Num>(dst: &mut [T], a: &[T], b: &[T])
pub fn batch_cmp<T: PartialOrd>(dst: &mut [u8], a: &[T], b: &[T], op: CmpOp)
pub fn batch_reduce<T: Num>(a: &[T], op: ReduceOp) -> T
pub fn batch_select<T: Copy>(dst: &mut [T], mask: &[u8], t: &[T], f: &[T])
pub fn broadcast<T: Copy>(dst: &mut [T], val: T)
```

- [ ] **Step 3: 测试**

Run: `cd rust && cargo test value::batch`
Expected: 通过

- [ ] **Step 4: Commit**

```bash
git add rust/src/value/batch.rs
git commit -m "feat(rust): implement SIMD batch operations"
```

---

### Task 20: Allocator trait — allocator.rs

**Files:**
- Create: `rust/src/value/allocator.rs`

- [ ] **Step 1: 定义 Allocator trait**

```rust
pub trait Allocator: Clone {
    fn alloc_str(&self, s: &str) -> Rc<str>;
    // 后续可扩展为 arena/buddy
}

#[derive(Clone, Default)]
pub struct DefaultAllocator;

impl Allocator for DefaultAllocator {
    fn alloc_str(&self, s: &str) -> Rc<str> { Rc::from(s) }
}
```

- [ ] **Step 2: 验证编译**

Run: `cd rust && cargo build`
Expected: 编译通过

- [ ] **Step 3: Commit**

```bash
git add rust/src/value/allocator.rs
git commit -m "feat(rust): add Allocator trait with default implementation"
```

---

### Task 21: Value 完整测试

**Files:**
- Create: `rust/tests/value_tests.rs`

- [ ] **Step 1: 编写标量测试**

18 种标量构造/访问/谓词全覆盖。

- [ ] **Step 2: 编写 cast 测试**

18×18 转换矩阵，含溢出/NaN/Inf 边界。

- [ ] **Step 3: 编写堆对象测试**

23 种堆对象构造/访问/equals。

- [ ] **Step 4: 编写 equals/deep_clone 测试**

含递归结构和深度限制。

- [ ] **Step 5: 运行全部测试**

Run: `cd rust && cargo test`
Expected: 全部通过

- [ ] **Step 6: Commit**

```bash
git add rust/tests/value_tests.rs
git commit -m "test(rust): comprehensive Value tests (scalar/cast/heap/equals/clone)"
```

---

### Task 22: 最终验证

- [ ] **Step 1: AST 全量 diff 仍通过**

Run: `cd rust && bash tools/diff_ast.sh`
Expected: 90/90 通过

- [ ] **Step 2: Value 全部测试通过**

Run: `cd rust && cargo test`
Expected: 全部通过

- [ ] **Step 3: cargo clippy 无警告**

Run: `cd rust && cargo clippy`
Expected: 无警告

- [ ] **Step 4: 最终 Commit**

```bash
git add -A
git commit -m "feat(rust): complete Value+AST rewrite with full validation"
```

---

## 实现顺序总结

```
Task 1:  脚手架
Task 2:  Span/Spanned
Task 3:  运算符类型
Task 4:  AST 节点定义
Task 5:  Lexer
Task 6:  优先级表
Task 7:  Parser（最大任务）
Task 8:  AST Printer
Task 9:  端到端 main.rs
Task 10: Zig ast_printer.zig
Task 11: Diff 脚本
Task 12: AST 全量 diff 通过
Task 13: Value 标量层
Task 14: 标量运算
Task 15: 标量转换
Task 16: 堆对象定义
Task 17: 剩余堆对象
Task 18: Value 主体
Task 19: SIMD 批量运算
Task 20: Allocator trait
Task 21: Value 测试
Task 22: 最终验证
```
