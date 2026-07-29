# Rust 重写设计：Value + AST 模块

> 日期：2026-07-29
> 范围：将 Glue 语言的 `value/` 和 `parse/` 模块用 Rust 重写，作为整体 Rust 迁移的第一步。
> 原则：基于对 Glue 语法和值语义的深入理解重写，不机械翻译 Zig 代码。

---

## 1. 设计哲学

### 1.1 不翻译，重写

Zig 版的许多设计是为绕过语言限制或追求极致性能：
- `[N]u8` 标量存储 → Rust enum 自带 tag，用原生类型更安全
- `*ObjHeader` 统一指针 + `@fieldParentPtr` → Rust enum of Box 更惯用
- `NodeSlot<T>` 外置位置 + `@fieldParentPtr` 反算 → Rust 用 `Spanned<T>` 显式包装
- 手写原子 RC → Rust 用 Rc/Arc
- `ThreadContext` 多策略分配 → Rust 用 Allocator trait 抽象

### 1.2 保留核心语义

- 18 种标量类型的完整运算/转换/比较语义
- 23 种堆对象的类型系统和生命周期
- SIMD 友好的批量运算接口（类型化切片 `&[i32]`）
- deepCopy 深度限制（防栈溢出）
- equals 循环引用处理（深度限制）

### 1.3 方法通用实用

每个类型不只是数据定义，还要有完整的构造/访问/转换/比较/格式化方法。API 设计以"好用"为目标，不是"能跑就行"。

---

## 2. 项目结构

```
rust/
├── Cargo.toml
└── src/
    ├── lib.rs                    # pub mod value; pub mod ast;
    ├── main.rs                   # 二进制入口：parse <file> → 打印 AST
    ├── ast/
    │   ├── mod.rs                # 模块入口 + re-exports
    │   ├── span.rs               # Span, Spanned<T>
    │   ├── node.rs               # Expr/Stmt/Decl/TypeNode/Pattern/Kind
    │   ├── op.rs                 # BinaryOp/UnaryOp/CompoundAssignOp/CastMode
    │   ├── lexer.rs              # Token/Lexer
    │   ├── parser.rs             # Parser
    │   ├── binary_op_table.rs    # 优先级表
    │   ├── visitor.rs            # AstVisitor trait
    │   └── printer.rs            # Canonical AST printer (S-expression)
    └── value/
        ├── mod.rs                # Value enum + 构造/访问/谓词
        ├── scalar.rs             # ScalarTag + 标量元信息
        ├── ops.rs                # 标量单值运算
        ├── cast.rs               # 标量转换 (cast/tryCast)
        ├── batch.rs              # SIMD 批量运算
        ├── char.rs               # Char 类型
        ├── str.rs                # GlueStr (String-based, 非 SSO)
        ├── composite.rs          # Array/Record/Adt/Newtype/Cell/Range
        ├── callable.rs           # Closure/Partial/Builtin/TraitValue/LazyValue
        ├── control.rs            # ErrorValue/ThrowValue
        ├── iterator.rs           # ArrayIter/StringIter/RangeIter
        ├── concurrent.rs         # Atomic/AsyncHandle/Channel/Sender/Receiver
        ├── heap.rs               # HeapObj enum + HeapRef
        └── allocator.rs          # Allocator trait (默认 System)
```

---

## 3. AST 模块设计

### 3.1 核心类型

```rust
// ast/span.rs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span { pub line: u32, pub column: u32 }

#[derive(Debug, Clone)]
pub struct Spanned<T> {
    pub span: Span,
    pub node: T,
}

pub type ExprRef<'a> = &'a Spanned<Expr<'a>>;
pub type StmtRef<'a> = &'a Spanned<Stmt<'a>>;
pub type TypeRef<'a> = &'a Spanned<TypeNode<'a>>;
pub type PatternRef<'a> = &'a Spanned<Pattern<'a>>;
pub type KindRef<'a> = &'a Spanned<Kind>;
```

### 3.2 表达式（34 种变体）

基于语法规范，每个变体从语义命名：

```rust
pub enum Expr<'a> {
    // ── 字面量 ──
    IntLit { raw: &'a str, suffix: Option<&'a str> },
    FloatLit { raw: &'a str, suffix: Option<&'a str> },
    BoolLit(bool),
    CharLit(u32),                              // Unicode 码点
    StrLit(&'a str),
    StrInterp(Vec<InterpPart<'a>>),            // "Hello ${name}!"
    NullLit,
    UnitLit,                                   // void / ()

    // ── 标识符与赋值 ──
    Ident(&'a str),
    Assign { target: ExprRef<'a>, value: ExprRef<'a> },
    CompoundAssign { op: CompoundAssignOp, target: ExprRef<'a>, value: ExprRef<'a> },

    // ── 运算 ──
    Binary { op: BinaryOp, lhs: ExprRef<'a>, rhs: ExprRef<'a> },
    Unary { op: UnaryOp, operand: ExprRef<'a> },

    // ── 引用语义 ──
    RefOf(ExprRef<'a>),                        // &expr
    Deref(ExprRef<'a>),                        // *expr

    // ── 调用与访问 ──
    Call { callee: ExprRef<'a>, args: Vec<ExprRef<'a>>, type_args: Option<Vec<TypeRef<'a>>> },
    MethodCall { recv: ExprRef<'a>, method: &'a str, args: Vec<ExprRef<'a>>, type_args: Option<Vec<TypeRef<'a>>> },
    FieldAccess { recv: ExprRef<'a>, field: &'a str },
    Index { recv: ExprRef<'a>, index: ExprRef<'a> },
    Slice { recv: ExprRef<'a>, start: ExprRef<'a>, end: ExprRef<'a>, inclusive: bool },

    // ── 可空语法 ──
    SafeAccess { recv: ExprRef<'a>, field: &'a str },           // ?.
    SafeMethodCall { recv: ExprRef<'a>, method: &'a str, args: Vec<ExprRef<'a>>, type_args: Option<Vec<TypeRef<'a>>> },
    Propagate(ExprRef<'a>),                                      // expr?
    NonNullAssert(ExprRef<'a>),                                  // expr!!
    Elvis { lhs: ExprRef<'a>, rhs: ExprRef<'a> },               // ??

    // ── 容器字面量 ──
    ArrayLit { elements: Vec<ExprRef<'a>>, fill: Option<(ExprRef<'a>, ExprRef<'a>)> },
    RecordLit(Vec<RecordFieldExpr<'a>>),
    RecordExtend { base: ExprRef<'a>, updates: Vec<RecordFieldExpr<'a>> },

    // ── 函数与控制流 ──
    Lambda { params: Vec<Param<'a>>, body: LambdaBody<'a>, is_async: bool, return_type: Option<TypeRef<'a>> },
    If { cond: ExprRef<'a>, then_branch: ExprRef<'a>, else_branch: Option<ExprRef<'a>> },
    Block { stmts: Vec<StmtRef<'a>>, trailing: Option<ExprRef<'a>> },
    Match { scrutinee: ExprRef<'a>, arms: Vec<MatchArm<'a>> },

    // ── 类型转换 ──
    TypeCast { target: TypeRef<'a>, expr: ExprRef<'a>, safe: bool },
    CastBuilder { expr: ExprRef<'a>, target: TypeRef<'a>, mode: CastMode },

    // ── 特殊表达式 ──
    Atomic(ExprRef<'a>),
    Lazy(ExprRef<'a>),
    Select(Vec<SelectArm<'a>>),
    InlineTrait(Vec<MethodDecl<'a>>),
}
```

### 3.3 语句（14 种）、声明（6 种）、类型节点（10 种）、模式（7 种）

完整变体清单见语法规范。每个变体字段从语义设计，使用 `&'a str` 引用源码。

### 3.4 Lexer 设计

```rust
pub struct Token<'a> {
    pub kind: TokenKind,
    pub lexeme: &'a str,
    pub line: u32,
    pub column: u32,
}

pub struct Lexer<'a> {
    source: &'a str,
    pos: usize,
    line: u32,
    column: u32,
}
```

关键特性保留：
- 80 种 TokenKind（关键字/运算符/字面量/分隔符）
- 分号被当作空白跳过
- 字符串插值词法处理（单个 Token，Parser 阶段拆分）
- 十六/八/二进制整数、类型后缀
- 嵌套块注释
- 数字下划线分隔

### 3.5 Parser 设计

```rust
pub struct Parser<'a> {
    tokens: &'a [Token<'a>],
    current: usize,
    arena: &'a Bump,                    // bumpalo arena
    errors: Vec<ParseError>,
    pending_eq: bool,                   // 虚拟 Token 拆分
    pending_gt: bool,
    pending_gt_eq: bool,
}
```

关键特性保留：
- 递归下降 + Pratt 优先级爬升
- pending_eq/pending_gt/pending_gt_eq 虚拟拆分机制
- 12 级运算符优先级（elvis 最低，乘除最高）
- `*` 跨行解引用检查
- 负数字面量折叠（`-42` → IntLit，非 Unary）
- lambda 两种 body 形式（block vs expression）
- record_literal vs record_extend 回溯解析
- `..`（数组填充）vs `...`（记录扩展）区分
- error recovery（synchronize 跳到声明边界）
- 条件不允许括号

### 3.6 AST Printer（Canonical S-expression）

用于全量 diff 验证。格式示例：
```
(module "Main"
  (fun_decl "main" [] (-> void)
    (block
      [(expr (call (ident "println") [(str "hello")]))]
      (unit))))
```

规则：每个节点 `(tag field1 field2 ...)`，子节点递归，字符串带引号，list 用 `[]`。行列号不打印。

### 3.7 AST Visitor

```rust
pub trait AstVisitor<'a> {
    fn visit_expr(&mut self, expr: ExprRef<'a>) { walk_expr(self, expr) }
    fn visit_stmt(&mut self, stmt: StmtRef<'a>) { walk_stmt(self, stmt) }
    fn visit_decl(&mut self, decl: &'a Decl<'a>) { walk_decl(self, decl) }
    // 可覆盖的特化 hook...
}
```

### 3.8 实用方法

- `Module::find_function(name) -> Option<&FunDecl>`
- `Expr::is_lvalue() -> bool`
- `Expr::is_literal() -> bool`
- `Spanned<T>::map(F) -> Spanned<U>`
- `Span::between(other) -> Span`

---

## 4. Value 模块设计

### 4.1 Value 联合体

```rust
pub enum Value {
    // 零字节特殊值
    Null,
    Unit,

    // 标量（原生类型，非 byte array）
    Bool(bool),
    Char(u32),
    I8(i8), I16(i16), I32(i32), I64(i64), I128(i128),
    U8(u8), U16(u16), U32(u32), U64(u64), U128(u128),
    Isize(isize), Usize(usize),
    F16(f16), F32(f32), F64(f64), F128(f128),

    // 堆引用
    Ref(HeapRef),
}
```

### 4.2 堆对象（23 种）

```rust
pub enum HeapObj {
    // 复合
    Str(GlueStr),
    Array(ArrayValue),
    Record(RecordValue),
    Adt(AdtValue),
    Newtype(NewtypeValue),
    Cell(Cell),
    Range(Range),
    // 可调用
    Closure(Closure),
    Partial(PartialApplication),
    Builtin(Builtin),
    TraitVal(TraitValue),
    LazyVal(LazyValue),
    // 控制流
    ErrorVal(ErrorValue),
    ThrowVal(ThrowValue),
    // 迭代器
    ArrayIter(ArrayIterator),
    StringIter(StringIterator),
    RangeIter(RangeIterator),
    // 并发
    AtomicVal(AtomicValue),
    AsyncVal(AsyncHandle),
    ChannelVal(ChannelValue),
    SenderVal(SenderValue),
    ReceiverVal(ReceiverValue),
    // 协程
    CoroutineFrame(CoroutineFrame),
}

pub type HeapRef = Rc<HeapObj>;    // 单线程；多线程时切换 Arc
```

### 4.3 标量运算系统

```rust
// scalar.rs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScalarTag { Bool, Char, I8, I16, I32, I64, I128, U8, U16, U32, U64, U128, Isize, Usize, F16, F32, F64, F128 }

impl ScalarTag {
    pub fn byte_width(self) -> usize { ... }
    pub fn is_int(self) -> bool { ... }
    pub fn is_float(self) -> bool { ... }
    pub fn name(self) -> &'static str { ... }
}

// ops.rs — 算术/位/比较运算（泛型特化）
pub fn add<T: Num>(a: T, b: T) -> Option<T>    // 溢出返回 None
pub fn sub<T: Num>(a: T, b: T) -> Option<T>
pub fn mul<T: Num>(a: T, b: T) -> Option<T>
pub fn div<T: Num>(a: T, b: T) -> Option<T>
pub fn neg<T: Num>(a: T) -> Option<T>
// 位运算：bit_and/bit_or/bit_xor/bit_not
// 比较：eq/ne/lt/gt/le/ge

// cast.rs — 标量转换
pub fn cast(src: Value, dst: ScalarTag) -> Value           // wrap 语义
pub fn try_cast(src: Value, dst: ScalarTag) -> Result<Value, CastError>
pub fn parse_str(s: &str, dst: ScalarTag) -> Result<Value, ParseError>

// batch.rs — SIMD 批量运算
pub fn batch_add<T>(dst: &mut [T], a: &[T], b: &[T])        // 自动 SIMD
pub fn batch_mul<T>(dst: &mut [T], a: &[T], b: &[T])
pub fn batch_cmp<T>(dst: &mut [u8], a: &[T], b: &[T], op: CmpOp)
pub fn batch_reduce<T>(a: &[T], op: ReduceOp) -> T
// ...
```

### 4.4 Value 核心方法

```rust
impl Value {
    // ── 构造 ──
    pub fn null() -> Self { Value::Null }
    pub fn unit() -> Self { Value::Unit }
    pub fn bool(b: bool) -> Self { Value::Bool(b) }
    pub fn char(c: u32) -> Self { Value::Char(c) }
    pub fn i32(v: i32) -> Self { Value::I32(v) }
    pub fn i64(v: i64) -> Self { Value::I64(v) }
    pub fn f64(v: f64) -> Self { Value::F64(v) }
    // ... 所有 18 种标量构造器

    pub fn str(s: impl Into<String>) -> Self { Value::Ref(Rc::new(HeapObj::Str(GlueStr::from(s)))) }
    pub fn array(elements: Vec<Value>) -> Self { ... }
    pub fn record(type_name: &str, fields: Vec<Value>) -> Self { ... }
    // ... 所有堆对象构造器

    // ── 访问 ──
    pub fn as_bool(&self) -> Option<bool>
    pub fn as_i32(&self) -> Option<i32>
    pub fn as_i64(&self) -> Option<i64>
    pub fn as_f64(&self) -> Option<f64>
    pub fn as_str(&self) -> Option<&str>
    pub fn as_array(&self) -> Option<&[Value]>
    pub fn as_ref(&self) -> Option<&HeapObj>
    // ... 所有类型访问器

    // ── 谓词 ──
    pub fn is_null(&self) -> bool
    pub fn is_unit(&self) -> bool
    pub fn is_bool(&self) -> bool
    pub fn is_int(&self) -> bool
    pub fn is_float(&self) -> bool
    pub fn is_numeric(&self) -> bool
    pub fn is_string(&self) -> bool
    pub fn is_ref(&self) -> bool           // 等价 Zig isBoxed()
    pub fn requires_release(&self) -> bool  // ref 返回 true，标量 false

    // ── 标量标签 ──
    pub fn scalar_tag(&self) -> Option<ScalarTag>
    pub fn byte_width(&self) -> usize

    // ── 转换 ──
    pub fn cast(&self, dst: ScalarTag) -> Value           // wrap 语义
    pub fn try_cast(&self, dst: ScalarTag) -> Result<Value, CastError>

    // ── 比较 ──
    pub fn equals(&self, other: &Value) -> bool           // 递归，深度限制 4096

    // ── 克隆 ──
    pub fn deep_clone(&self) -> Value                     // 递归深拷贝，深度限制 4096

    // ── 格式化 ──
    pub fn to_display_string(&self) -> String             // 用户可读格式
    pub fn type_name(&self) -> &'static str               // "i32"/"str"/"array" 等

    // ── RC ──
    pub fn retain(&self) -> Value                          // Rc::clone，标量 no-op
    pub fn release(self)                                   // Rc drop，标量 no-op
}
```

### 4.5 堆对象类型定义

每种堆对象是独立 struct，字段从语义设计：

```rust
// str.rs — 用 String 替代 SSO extern struct
pub struct GlueStr { inner: Rc<str> }     // 共享，零拷贝切片

// composite.rs
pub struct ArrayValue { elements: Vec<Value>, fixed_size: Option<u64> }
pub struct RecordValue { type_name: Rc<str>, fields: Vec<Value>, field_names: Vec<Option<Rc<str>>> }
pub struct AdtValue { type_name: Rc<str>, constructor: Rc<str>, fields: Vec<AdtField> }
pub struct AdtField { name: Option<Rc<str>>, value: Value }
pub struct NewtypeValue { type_name: Rc<str>, inner: Value }
pub struct Cell { inner: RefCell<Value> }                    // 可变单元
pub struct Range { start: i128, end: i128, inclusive: bool }

// callable.rs
pub struct Closure { func: ClosureFunc, upvalues: Vec<Value>, bound_args: Vec<Value> }
pub struct PartialApplication { func: ClosureFunc, bound_args: Vec<Value>, remaining_arity: u8 }
pub struct Builtin { fn_ptr: BuiltinFn, user_ctx: Option<Box<dyn Any>> }
pub struct TraitValue { trait_name: Rc<str>, methods: Vec<(Rc<str>, Value)>, data: Option<Value> }
pub struct LazyValue { thunk: Rc<dyn Fn() -> Value>, cached: OnceCell<Value> }

// control.rs
pub struct ErrorValue { type_name: Rc<str>, message: Rc<str> }
pub struct ThrowValue { payload: ThrowPayload }
pub enum ThrowPayload { Ok(Value), Err(Box<RecordValue>) }

// concurrent.rs（接口完整，锁用 std::sync::Mutex）
pub struct AtomicValue { data: Mutex<Value> }
pub struct AsyncHandle { status: Mutex<AsyncStatus>, result: Mutex<Option<Value>> }
pub struct ChannelValue { buffer: Mutex<ChannelBuf> }
// ...
```

### 4.6 Allocator trait

```rust
// allocator.rs
pub trait Allocator: Clone {
    fn alloc_str(&self, s: &str) -> Rc<str>;
    fn alloc_array(&self, elements: Vec<Value>) -> ArrayValue;
    // ... 当前默认实现用标准堆；后续可替换为 arena/buddy
}

#[derive(Clone, Default)]
pub struct DefaultAllocator;
impl Allocator for DefaultAllocator { ... }
```

---

## 5. 验证方案

### 5.1 AST 全量 diff

1. Rust 侧 `cargo run -- parse <file>` 输出 canonical S-expression
2. Zig 侧新增 `src/parse/ast_printer.zig`，`zig build run -- ast-print <file>` 输出相同格式
3. 脚本 `rust/tools/diff_ast.sh`：遍历 `tests/ + builtin/ + std/ + bench/` 所有 `.glue`，对每个跑两版，diff 输出

### 5.2 Value 单元测试

- 18 种标量构造/访问/谓词全覆盖
- cast/try_cast 全 18×18 矩阵
- 23 种堆对象构造/访问
- equals 递归比较 + 深度限制
- deep_clone 递归 + 深度限制
- format 输出格式

### 5.3 依赖

```toml
[dependencies]
bumpalo = "3"          # AST arena
```

---

## 6. 实现顺序

1. `ast/span.rs` + `ast/op.rs` + `ast/node.rs`（类型定义，无逻辑）
2. `ast/lexer.rs`（自包含，可单测）
3. `ast/binary_op_table.rs`（优先级表）
4. `ast/parser.rs`（核心，~3000 行）
5. `ast/printer.rs`（canonical 格式）
6. Zig 侧 `ast_printer.zig`（diff 基准）
7. 全量 diff 验证
8. `value/scalar.rs` + `value/ops.rs` + `value/cast.rs`（标量层）
9. `value/heap.rs` + 23 种堆对象 struct
10. `value/mod.rs`（Value enum + 构造/访问/谓词/equals/deep_clone/format）
11. `value/batch.rs`（SIMD 批量运算）
12. Value 单元测试

---

## 7. 舍弃项（后续可重新引入）

- arena 分配优化（ShadowArena + ARENA_ALLOCATED flag）
- Str SSO 26 位独立 RC
- worker 线程分配对象迁移机制（WORKER_ALLOCATED flag）
- buddy allocator + page pool
- rebase_info 通道指针修正
- deinit_table 运行时注册模式（Rust 用 trait/enum match 替代）
- ref_kind_table 函数指针分派表（Rust 用 enum match 替代）

这些是性能优化或 Zig 特有技巧，不影响功能正确性。当前目标是完全可用的实现，后续移植 mem/ 时可重新引入。
