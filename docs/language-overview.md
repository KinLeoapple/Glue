# Glue 语言当前状态总览

> 版本: 1.0.0-draft
> 最后更新: 2026-07-21
> 本文档与当前代码库（IR 共享内存图 + 执行引擎架构）严格对齐。

本文档是 Glue 语言的权威参考，涵盖设计、语法、类型系统、并发模型、模块系统、
内存管理与 IR 执行引擎的当前真实状态。

---

## 目录

1. [语言概述与设计哲学](#1-语言概述与设计哲学)
2. [类型系统](#2-类型系统)
3. [并行与并发模型](#3-并行与并发模型)
4. [模块系统](#4-模块系统)
5. [运行时与内存管理](#5-运行时与内存管理)
6. [语法设计](#6-语法设计)
7. [执行架构：Glue IR 与执行引擎](#7-执行架构glue-ir-与执行引擎)
8. [当前实现状态](#8-当前实现状态)
9. [设计决策记录](#9-设计决策记录)
10. [术语表](#10-术语表)

---

## 1. 语言概述与设计哲学

### 1.1 Glue 是什么

Glue 是一门通用编程语言，核心目标是让并行编程变得安全、自然、高效。Glue 采用
函数式范式，通过类型系统和运行时的协同设计，在编译期追踪空值和错误、在运行时
保证并行安全。

### 1.2 设计哲学

| 原则 | 含义 |
|---|---|
| **组合优于继承** | 通过 ADT + Trait + 一等 Trait 值组合行为，不提供继承机制 |
| **显式优于隐式** | 空值和错误通过类型系统显式标注，`?` 操作符显式传播，类型转换必须显式 |
| **安全默认** | 默认不可变、默认私有、默认值语义，安全不需要额外努力 |
| **运行时并行安全** | 并行安全由运行时架构保证，无需用户手动管理 |
| **约定优于配置** | 最小清单即可运行，程序入口为 `fun main()` |
| **渐进复杂度** | 简单的事情简单做，复杂的事情可能，但不强制 |

### 1.3 核心设计决策总览

| 维度 | 决策 |
|---|---|
| 目标领域 | 通用编程 |
| 范式 | 函数式 |
| 并发模型 | CSP：`async fun` + `Async<T>` + channel + `Atomic<T>` + `select` |
| 并行安全策略 | 运行时保证（值语义 + 深拷贝 + 线程隔离的分配器 + Atomic<T>） |
| 求值策略 | 严格求值（`Lazy<T>` 为设计保留，当前执行架构未实现） |
| 柯里化 | 默认柯里化 |
| 类型系统 | Hindley-Milner 推断 + ADT + GADT + Nullable + Throw<T, E> + Trait + HKT + 子类型 |
| 数据语义 | 值语义（默认不可变） |
| 共享机制 | Atomic<T> 跨任务共享原子状态（替代 Arc<T>） |
| 错误处理 | `Throw<T, E>` + `throw` + `?` 传播 + Nullable (`T?`) |
| 内存管理 | 引用计数（RC）+ 三级分配器（channel arena / object pool / shadow arena），无追踪式 GC |
| 模块系统 | 文件即模块 + `pack.glue` + `import` 导入 |
| 变异性 | 自动推导 + 可选显式标注 |
| 可见性 | 默认私有 + `pub` 公开 |
| 函数关键字 | `fun`（异步函数为 `async fun`） |
| 返回类型 | `: T` |
| Trait 实现 | type 定义时内联实现，语法：`type T: Trait = ...` |
| 类型参数约束 | `<T: Trait1 + Trait2>` |
| 类型特化约束 | `with T: ConcreteType` |
| 变量绑定 | `val`（不可变）、`var`（可变） |
| 并发原语 | `async fun` + `Async<T>.await()` + `channel` + `Atomic<T>` + `select` |
| 任务运行时 | 每个 async 调用一个 OS 线程，worker 拥有独立的 Engine/ThreadContext/Runtime |
| 类型转换 | cast builder：`cast(expr).to(T)` wrap 语义 / `cast(expr).try_to(T)` 检查语义 |
| 平台相关整数 | `isize`/`usize` 跟随平台位宽，用于数组索引、`len()` 返回、Range 步进 |
| Builtin 模块 | 用 Glue 自身定义内建错误类型（CastError/IOError/TimeError），按需加载 |
| 运算符 | 内建不可重载 |
| 字符串 | UTF-8 编码，迭代产生 `char` |
| 执行后端 | Glue IR 共享内存数据流图 + 线性执行引擎（唯一的执行后端） |

---

## 2. 类型系统

### 2.1 概述

Glue 的类型系统以 Hindley-Milner 为基础，扩展了代数数据类型 (ADT)、GADT、
Nullable 类型、Throw 类型、Trait、Higher-Kinded Types 和子类型关系。类型推断在
大多数场景下可以自动完成。

核心设计原则：
- **安全默认**：类型 `T` 不可空，`T?` 才可空；`T` 不会抛错，`Throw<T, E>` 才可抛
- **组合优于继承**：通过 ADT + Trait 组合行为，不提供继承
- **显式传播**：`?` 操作符统一处理 Nullable 和 Throw 的坏值传播
- **显式转换**：数值类型之间没有隐式转换，必须使用 cast builder
- **运算符用户不可重载**：`==`/`!=` 对所有类型自动派生为递归值相等，不可覆盖

### 2.2 基础类型

```
i8    i16    i32    i64    i128    isize
u8    u16    u32    u64    u128    usize
f16   f32    f64    f128
bool
char
```

| 类型 | 含义 | 备注 |
|---|---|---|
| `i8`..`i128` | 有符号整数 | 8 至 128 位 |
| `u8`..`u128` | 无符号整数 | 8 至 128 位 |
| `isize`/`usize` | 平台相关整数 | 64 位平台 = 8 字节；usize 用于数组索引、`len()` 返回、Range 步进 |
| `f16` | 16 位半精度浮点 | IEEE 754-2008 binary16 |
| `f32` | 32 位单精度浮点 | IEEE 754 binary32 |
| `f64` | 64 位双精度浮点 | IEEE 754 binary64 |
| `f128` | 128 位四精度浮点 | IEEE 754-2008 binary128 |
| `bool` | 布尔类型 | `true` / `false` |
| `char` | Unicode 标量值 | 4 字节，字面量用单引号 `'a'` |
| `str` | 字符串 | UTF-8 编码，`len()` 返回字符数（`usize`），迭代产生 `char` |
| `()` | 单位类型（Unit） | 表示没有有意义的值 |

**整数溢出行为**：整数溢出在 Debug 和 Release 模式下都会触发 panic，没有
wrap around 语义。

**浮点数无 NaN 和 Infinity**：浮点除零触发 panic。理由：NaN 的 `NaN != NaN`
与值相等语义冲突；特殊值增加类型系统不确定性；需要"无效/无穷"时使用
`f64?` 或 `Throw<f64, Error>` 显式表达。

**str 与 UTF-8**：迭代产生 `char`；索引是 O(n) 操作（变长编码）；`len()` 返回
Unicode 标量值数量而非字节数。

**数值类型之间无隐式转换**：必须使用 `cast(expr).to(T)` 显式转换。

### 2.2.1 借用引用类型 &T 与裸指针 *T

Glue 提供 `&T`（借用引用）和 `*T`（裸指针）两种引用类型，用于显式标注引用语义。

```glue
val x = 42
val ref: &i32 = &x       // 取引用，ref 指向 x 的值
val y = *ref             // 解引用，y = 42

fun increment(r: &i32) {  // 借用引用参数
    *r = *r + 1
}
```

**`&T` 借用引用**：
- 指向已有值的引用，共享读写，由 RC 管理生命周期
- 标量取引用时，编译器自动装箱到堆容器（`boxed_scalar`），使标量获得引用语义
- 复合类型取引用时，直接共享对象指针（行为与默认一致）
- `&expr` 取引用，`*expr` 解引用，`*ref = value` 通过引用写入

**`*T` 裸指针**：
- 绕过 RC 的不安全指针，不参与引用计数
- 预留用于 FFI 场景，普通代码不应使用

**设计动机**：Glue 的标量默认按值拷贝传递（内联在 24B Value 中），复合类型默认按指针共享传递。`&T` 允许标量也获得引用语义，使值类型和引用类型在需要时行为一致。

### 2.3 Nullable 类型

`T?` 表示 `T` 类型的值或 `null`，是类型系统的内建特性，不是语法糖。

```glue
val a: i32 = 42          // 不可空
val b: i32? = null       // 可空
val d: i32 = null        // 编译错误：i32 不可空
```

- `null` 的类型为 `Null`，`Null` 是所有 `T?` 类型的子类型
- `T?` 与 `T` 协变：`Cat <: Animal ⟹ Cat? <: Animal?`
- 双重可空扁平化：`T??` 等价于 `T?`

**类型收窄**：使用可空值前必须消除空值可能性（match 收窄 / if 收窄）。

```glue
fun greet(name: str?) : str {
    match name {
        null => "Hello, stranger",
        n => "Hello, " + n,    // n : str（已收窄）
    }
}
```

**相关操作符**：
- `?.` 安全调用：`name?.len()`，null 时短路返回 null（`i32?`）
- `??` Elvis：`name?.len() ?? 0`，提供默认值将 `T?` 转为 `T`
- `!` 非空断言：null 时运行时 panic
- `?` 传播：见 §2.3.1

#### 2.3.1 `?` 传播操作符

`?` 作为表达式后缀操作符，用于提前传播"坏值"：

```glue
fun greet() : str? {
    val name = get_name()?    // null 时提前返回 null
    "Hello, " + name
}

fun read_config() : Throw<Config, Error> {
    val content = read_file("config.json")?    // throw 时提前传播
    parse_json(content)?
}
```

规则：
- `expr?` 作用于 `T?` 时，外层函数必须返回 `U?`
- `expr?` 作用于 `Throw<T, E_inner>` 时，外层函数必须返回 `Throw<U, E_outer>`，
  且 `E_inner <: E_outer`
- 在普通函数中使用 `?` → 编译错误
- **`?` 不跨 Nullable 和 Throw 自动转换**（null 与 error 语义不同）

`Throw<T?, E>` 需要两步处理——先处理 Throw，再处理 Nullable。

### 2.4 Throw 类型

`Throw<T, E>` 是内建包装类型：成功返回 `T`，失败抛出类型为 `E` 的错误。

#### 2.4.1 Error Trait

`Error` 是内建 Trait，所有可被 `throw` 抛出的类型必须是 `Error` 的子类型。
提供内置方法 `message(self): str` 和 `type_name(self): str`（均可 override）。

#### 2.4.2 自定义错误类型

```glue
type FileError: Error = FileError(msg: str) {
    override fun type_name(self): str {
        "file error"
    }
}
```

- `FileError <: Error`；自定义错误类型之间没有子类型关系
- `throw` 只能抛出 Error 子类型，且只能在返回 `Throw<T, E>` 的函数中使用，
  抛出的错误类型必须是 `E` 的子类型

#### 2.4.3 Throw<T, E> 的值与模式匹配

`Throw<T, E>` 的值有两种状态：`Ok(value)` 与 `Error(e)`（D74：构造器简化为
Ok/Error，消除双层包装）。

```glue
match read_file("config.json") {
    Ok(content) => process(content),
    Error(e) => println("error: " + e.message),
}
```

#### 2.4.4 变异性

`Throw<T, E>` 对 `T` 和 `E` 均协变。

### 2.5 代数数据类型 (ADT)

```glue
// 枚举（和类型）
type Shape =
    | Circle(radius: f64)
    | Rectangle(width: f64, height: f64)

// 记录（积类型，匿名、结构化匹配）
type User = (
    name: str,
    age: i32,
    email: str?,
)

// 递归类型
type List<T> =
    | Nil
    | Cons(T, List<T>)

// 抽象类型（pub type 公开类型名、隐藏构造器）
pub type Handle = Handle(i32)
```

**无匿名元组**：记录必须有命名字段。

### 2.6 Pattern Matching

必须穷举检查，支持嵌套模式、守卫条件、或模式：

```glue
fun classify(n: i32) : str {
    match n {
        0 => "zero",
        n if n < 0 => "negative",
        1 | 2 | 3 => "small",
        _ => "other",
    }
}
```

`null` 作为模式直接匹配；`Ok(v)`/`Error(e)` 匹配 Throw。

### 2.7 Trait

Trait 是 Glue 中唯一的接口抽象机制——既用于编译期参数化多态（trait bound），
也用于运行时多态（一等 Trait 值）。

```glue
trait Comparable {
    fun compare(self, other: Self): Ordering
}

type MyInt: Comparable = MyInt(value: i32) {
    fun compare(self, other: Self): Ordering {
        if self.value < other.value { Lt }
        else if self.value == other.value { Eq }
        else { Gt }
    }
}

// 多 trait
type Point: (Show, Comparable) = Point(x: i32, y: i32) { ... }
```

语法规则：
- 实现 trait 时必须有大括号 `{ }`（即使全用默认实现）
- 单个 trait 可省略括号；多个用 `(Trait1, Trait2)`
- 不支持为已定义的类型后续添加实现（必须定义时一次性声明）
- 运算符不可重载；自定义类型使用命名方法

**Trait 组合**：子 Trait 继承父 Trait 方法；冲突消解支持委托（`=`）、重命名、
覆写（`override`）。

**类型参数约束与类型特化**：
- `<T: Ord>` / `<T: Ord + Debug>` — trait 约束
- `with T: i32` — 类型特化（限定具体类型）
- 两者可组合

**关联类型**：`type Item` 声明，`Self.Item` 访问。

**Self 类型**：可作返回/参数类型；不能作构造器；只能出现在 trait/type 实现中。

**名义化匹配 + Orphan 规则**：类型和 trait 至少有一个在当前模块定义；禁止
overlapping instances；编译期单态化。

**Iterable / Iterator**：

```glue
trait Iterable {
    type Item
    fun iterator(self): Iterator
}
trait Iterator {
    type Item
    fun next(self): Item?
}
```

`for item in collection` 要求 `collection` 实现 `Iterable`。

### 2.8 函数类型

```glue
fun add(a: i32, b: i32) : i32 { a + b }

// 默认柯里化：部分应用
val add5 = add(5)
add5(3)  // => 8
```

**禁止链式调用** `f(a)(b)`——部分应用的结果必须绑定到变量后再调用（D69）。

函数类型语法：`A -> B`、`(A, B) -> C`（柯里化语法糖）、`A -> Throw<B, E>`。

### 2.9 变异性 (Variance)

编译器自动推导：构造器参数/返回值协变，函数参数逆变，同时出现则不变；
`T?` 协变；`Throw<T, E>` 两个参数均协变。

### 2.10 类型推断

Hindley-Milner 推断，大多数场景无需标注。必须/建议标注：顶层函数签名（建议）、
模块公开 API（建议）、多态递归（必须）、歧义场景（必须）。

### 2.11 Higher-Kinded Types (HKT)

```
Kind          含义               示例
*             具体类型           i32, str, bool
* -> *        一阶类型构造器     List, Vec, Tree
* -> * -> *   二阶类型构造器     Map, Throw
```

### 2.12 子类型关系

1. **记录宽度子类型**：`(name: str, age: i32) <: (name: str)`
2. **Trait 结构化子类型**：方法更多的模块是方法更少的 Trait 的子类型
3. **Error 子类型**：自定义错误类型 `<: Error`

### 2.13 GADT

```glue
type Expr<T> =
    | IntLit(i32)                       : Expr<i32>
    | BoolLit(bool)                     : Expr<bool>
    | Add(Expr<i32>, Expr<i32>)         : Expr<i32>
    | If(Expr<bool>, Expr<T>, Expr<T>)  : Expr<T>
```

匹配 GADT 时编译器通过类型细化推导局部类型等式（`T ~ i32` 等）。

### 2.14 Type Alias 与 Newtype

```glue
type IntList = List<i32>       // 别名，不创建新类型
type UserId = UserId(i32)      // Newtype，运行时零开销
```

### 2.15 类型转换

```glue
cast(expr).to(T)        // wrap 语义：截断/饱和，永不失败
cast(expr).try_to(T)    // 检查语义：返回 Throw<T, CastError>
```

- widening 始终合法（`i8→i16→i32→i64→i128` 等；int→float 基于尾数精度分析）
- narrowing：`.to()` 按位截断（wrap）；`.try_to()` 超范围返回 `Err(CastError)`
- `i→i` 零/符号扩展；`f→f` round-to-nearest（产生 Inf 触发 panic，D82）；
  `f→i` 截断 + 饱和；`bool↔int`、`char↔int`（u32 码点）
- `CastError`：内建 Error 子类型（`builtin/error/CastError.glue`），
  字段 `from`/`to`/`msg`
- cast 是 D56（溢出 panic）的例外：显式转换由用户承担风险（D81）

**`str()`**：内建类型转换函数，任意值转字符串；字符串插值 `{expr}` 的底层机制。

**`type()`**：内建函数，返回任意值的运行时类型名（`str`）。对用户类型返回
类型名；对 `Ok`/`Error` 返回 `"Throw"`；对函数值返回 `"function"`。

### 2.16 命名规则

- 同层级禁止重复定义（val/var/fun/type/trait 同名）
- 嵌套作用域允许遮蔽
- `var` 可重新赋值但不可重复定义
- 内建名称禁止重新定义：`println`/`print`/`eprintln`/`eprint`/`scanln`/`scan`/
  `Panic`/`type`/`cast`/`str`/`Error`/`Ok`/`CastError`

### 2.17 迭代器脱糖

```glue
// for item in list { body } 脱糖为：
val iter = list.iterator()
loop {
    match iter.next() {
        null => break,
        item => body,
    }
}
```

内建 Iterable：`T[]`（元素）、`str`（char）、`start..end`（Range）。

### 2.18 错误处理策略

| 场景 | 推荐机制 |
|---|---|
| 值可能不存在 | `T?` |
| 操作可能失败，需要错误信息 | `Throw<T, E>` |
| 错误类型明确需穷举 | `Throw<T, SpecificError>` |
| 聚合多种错误 | `Throw<T, Error>` |
| 并发任务中的错误 | Channel 传递 `Throw<T, E>` |

### 2.19 I/O 内建函数

| 函数 | 签名 | 说明 |
|---|---|---|
| `println` | `Any -> Unit` | 输出值 + 换行到 stdout |
| `print` | `Any -> Unit` | 输出值到 stdout |
| `eprintln` | `Any -> Unit` | 输出值 + 换行到 stderr |
| `eprint` | `Any -> Unit` | 输出值到 stderr |
| `scanln` | `() -> str?` | stdin 读一行，EOF 返回 null |
| `scan` | `() -> str?` | stdin 读一个空白分隔 token，EOF 返回 null |

I/O 错误触发 panic，解析由用户显式完成。

---

## 3. 并行与并发模型

### 3.1 概述

Glue 采用 **CSP（通信顺序进程）** 并发模型，当前语法与运行机制：

- **`async fun` 定义异步函数**：调用即启动一个并发任务，返回 `Async<T>`
- **`Async<T>.await()`** 阻塞等待结果，**`.status()`** 非阻塞查询状态
- **channel** 传递数据，**select** 多路复用
- **`Atomic<T>`** 跨任务共享原子状态（替代 Arc<T>）
- 并行安全由运行时保证：任务间内存隔离 + 深拷贝传参 + 原子操作

> 注：早期设计中的 `spawn { }` 关键字与 `Spawn<T>` 类型已被 `async fun` +
> `Async<T>` 取代；`Lazy<T>` 当前未在新执行架构中实现。

### 3.2 async 函数

```glue
async fun compute(): i64 { 7 * 6 }

fun main() {
    val s = compute()      // 立即返回 Async<i64>，任务已在后台执行
    do_other_work()
    val r = s.await()      // 阻塞等待，r = 42

    // 链式调用
    val r2 = compute().await()
}
```

#### 3.2.1 捕获语义：深拷贝

async 函数的实参按**深拷贝**传递，任务内部修改不影响外部：

```glue
var count = 0
val s = incrCount(count)   // async fun incrCount(c: i64): i64 { c + 1 }
println(s.await())          // 1
println(count)              // 0（不变）
```

**例外**：`Atomic<T>` 按浅拷贝（引用）传递，共享底层内存——这是跨任务共享
可变状态的唯一方式。

#### 3.2.2 Async<T> 方法

| 方法 | 阻塞 | 说明 |
|---|---|---|
| `await()` | 是 | 等待完成并取结果 |
| `status()` | 否 | 查询状态（Pending/Running/Completed/Cancelled/Failed） |

### 3.3 Atomic<T>

```glue
var counter = atomic 0i64

async fun incr(c: Atomic<i64>): Unit { c = c + 1 }

val a = incr(counter)   // 浅拷贝，共享
a.await()
println(counter)         // 1
```

- **透明操作**：读写与复合赋值（`+=` 等）由编译器翻译为原子操作
- **显式操作**：`atm.swap(new)`（原子交换，返回旧值）、`atm.cas(expected, new)`
  （比较并交换，返回 bool）
- **引用语义 + 引用计数**：归零自动释放
- 当前实现为互斥锁保护（见 §8.3 已知限制）

### 3.4 Channel

```glue
val ch = channel(10)        // 缓冲区容量 10
ch.send(42)
val v = ch.recv()           // 阻塞接收

// 方向类型
val tx = ch.sender
val rx = ch.receiver
tx.send(1)
val x = rx.recv()
```

**关闭语义（D57）**：
- 仅 Sender 可关闭：`ch.sender.close()`
- 关闭后缓冲数据仍可读取
- 缓冲耗尽且已关闭时，`recv()` 返回 `null`

### 3.5 select 多路复用

```glue
select {
    cha.recv() => println("from-a"),
    chb.recv() => v => println("got {v}"),   // 绑定接收值
    timeout(1000) => println("timeout"),
}
```

选择第一个就绪的分支执行。

### 3.6 并行安全保证

| 机制 | 保证 | 适用场景 |
|---|---|---|
| 值语义 + 深拷贝 | 无共享引用 | 默认，覆盖绝大多数场景 |
| 线程隔离的分配器 | 无共享堆内存 | 所有并发代码 |
| Channel | 安全通信 | 任务间数据传递 |
| Atomic<T> | 原子操作共享 | 跨任务共享简单可变状态 |

### 3.7 调度模型（当前实现）

**每个 async 调用对应一个独立的 OS 线程**（`std.Thread.spawn` + detach）：

- 调用 `async fun` 时引擎创建 `AsyncHandle`（Mutex + Condition），
  spawn 一个 worker 线程执行函数体
- worker 线程拥有**独立的 Engine 实例、ThreadContext（三级分配器）与
  Runtime（通道存储）**；IR 与 GlobalPool 只读共享
- `await()` 通过条件变量阻塞等待；panic 通过 `setPanic` 隔离到任务级，
  不影响其他任务
- 结果在 worker 完成全部资源清理后写回 handle，再由 `await()` 取回

> 设计目标中的 M:N 协程调度（work-stealing）尚未实现；当前模型简单直接，
> 适用于中等并发规模（见 §8.3 已知限制）。

---

## 4. 模块系统

### 4.0 项目与工具链

Glue 以**项目**为单位组织代码。项目根由清单文件 `glue.toml` 标识，源码放在
`src/` 下，入口约定为 `src/Main.glue` 的 `fun main()`。

```
myapp/
├── glue.toml          // 项目清单（项目根标识）
└── src/
    ├── Main.glue      // 入口模块，含 fun main()
    └── ...
```

```toml
name = "myapp"
version = "0.1.0"
entry = "src/Main.glue"   # 可选，缺省 src/Main.glue
```

**CLI 命令**：

| 命令 | 说明 |
|---|---|
| `glue init [name]` | 脚手架新项目（目标须为空目录） |
| `glue run` | 编译并运行当前项目 |
| `glue debug` | 诊断模式运行（内存检查 + 运行时错误位置追踪） |
| `glue run --profile` | 运行后输出完整管线性能概览（各阶段耗时 + 内存统计） |

`run`/`debug` 从当前目录向上查找 `glue.toml` 定位项目根。编译错误、运行时
panic、缺少 `fun main()`、非项目目录等以非零退出码结束。

### 4.1 文件即模块

1. 每个 `.glue` 文件是一个模块
2. **`pack.glue`**：目录模块的入口文件；无 `pack.glue` 的目录被整体忽略；
   未在 `pack.glue` 声明的文件不参与编译
3. **一等 Trait 值**：Trait 可以作为运行时值传递（文件模块自动转换为 Trait 值，
   或内联 `trait { ... }` 字面量）

```glue
// pack.glue
pub pack Map            // 公开子模块（成员合并到父命名空间）
pack Internal           // 私有子模块
```

### 4.2 可见性

默认私有（类 Rust）：`fun`/`val`/`var`/`type`/`trait`/`pack` 默认仅当前模块可见，
跨模块访问必须 `pub`。`pub type` 公开类型名但隐藏构造器（抽象类型）。

### 4.3 import

```glue
import Collections.{Map, insert, empty}       // 选择性导入
import Collections.Map                         // 导入整个模块
import Collections.{Map as CMap}               // 别名
import Collections.*                           // 导入所有公开成员
pub import Collections.{Map}                   // 重新导出
```

模块循环依赖是编译错误（依赖必须是 DAG）。

### 4.4 一等 Trait 值的运行时表示

vtable 指针 + data 载荷的胖指针。vtable 含 size/align/drop/send 与接口函数指针；
跨线程传递时 vtable 共享（全局只读），data 深拷贝。

### 4.5 Builtin 模块（Glue 自举）

内建错误类型用 Glue 自身定义，避免在 Zig 主机硬编码：

- **`builtin/error/CastError.glue`** — `cast().try_to()` 失败错误
  （字段 `from`/`to`/`msg`）
- **`builtin/error/IOError.glue`** / **`TimeError.glue`** — syscall 失败错误
  （含 `IOErrorKind`/`TimeErrorKind` 枚举）
- **`builtin/error/pack.glue`** — Error 子类型的统一打包

源码通过 `@embedFile` 编进二进制；sema 阶段注册元信息，代码生成阶段按需编译。

### 4.6 内嵌标准库

标准库用 Glue 自身编写，`@embedFile` 内嵌（`src/std/embed.zig`）。`import` 时
**项目内同名文件优先**（允许用户覆盖），找不到才回退内嵌表——标准库零安装、
与运行目录无关。当前模块：

- **`std/io`**：`File`（open/read/write/close、Stat、O_* 常量）、`Fs`
  （readText/writeText 等高层 API）、`Dir`（list/create/remove）、`Path`、
  `Buffered`
- **`std/time`**：`Instant`（单调时钟 now/elapsed）、`SystemTime`、`DateTime`、
  `Duration`、`Calendar`、`Timer`

std 模块通过 `@[syscall]` 属性注解绑定宿主 syscall 原语（见 §7.6）。

---

## 5. 运行时与内存管理

### 5.1 内存管理总览

Glue 采用**引用计数（RC）+ 三级分配器**，无追踪式 GC：

- 堆对象统一携带 `ObjHeader`（引用计数 + type_tag），RC 归零即释放
- 不存在全局暂停；分配器按对象生命周期分三层，各司其职

### 5.2 三级分配器（src/mem/）

| 分配器 | 生命周期 | 机制 | 用途 |
|---|---|---|---|
| **ChannelRegion** | 短（基本块级） | bump + reset，64B 对齐（SIMD 兼容），容量倍增扩容 | IR 通道数据（节点间传递的 Value 字节） |
| **ObjectPool** | 中长期 | PagePool 精确尺寸页（位图扫描），页级管理 | 堆对象（字符串/数组/记录/闭包等 22 种） |
| **ShadowArena** | 极短（函数级） | bump + reset，16B 对齐 | 函数内临时数据 |

- **GlobalPool**：冷路径补给——buddy 分配器（512B–1MB，2 的幂分级、分裂/合并）
  处理大对象；每 size class 缓存最多 8 页，线程本地页不足时补充，线程结束归还
- **ThreadContext**（TLS）：每线程统一入口，热路径**零锁**（本地缓存最多
  2 页/size class），未命中走 GlobalPool
- **debug_allocator**：包装层，记录分配/释放的地址/大小/调用点，泄漏与
  双重释放检测（`glue debug` 使用）

### 5.3 值表示（src/value/）

`Value` 为 24 字节 union：

- **标量内联**：bool/char/i8..i128/u8..u128/isize/usize/f16..f128 以 `[N]u8`
  字节数组按**实际宽度**内联存储，对齐为 1、无 padding，可直接 SIMD 加载
- **堆引用**：23 种堆分配值统一为 `ref: *ObjHeader`，由 `type_tag` 区分
  （str、array、record、ADT、newtype、closure、trait 值、channel、
  sender/receiver、atomic、AsyncHandle、Throw、Error、iterator、boxed_scalar 等）
  其中 `boxed_scalar` 为标量借用引用 `&i32`/`&f64` 等的堆容器，内联标量值紧跟 ObjHeader 之后
- **标量运算**：`ops.zig` 以 comptime 分派 `@bitCast` 到原生类型计算，零开销；
  `batch.zig` 提供 SIMD 批量运算（循环体预编译路径使用）

### 5.4 线程模型

- 每个 OS 线程（主线程 + 每个 async worker）拥有独立 `ThreadContext`
- worker 线程的堆对象分配完全线程本地；跨线程传递的对象
  （如 `OrbitThreadData`）使用线程安全的 backing allocator
- 任务间不共享可堆内存；IR 与 GlobalPool 只读共享

### 5.5 跨任务传递规则

| 数据类型 | 传递方式 |
|---|---|
| 标量 | 值拷贝 |
| async 实参 | 深拷贝（当前实现为标量值拷贝，见 §8.3） |
| Atomic<T> | 浅拷贝（共享底层内存，引用计数） |
| Channel | 引用共享（Mutex + 条件变量保护） |
| 结果 | worker 清理完毕后写回 AsyncHandle |

---

## 6. 语法设计

### 6.1 关键字

```
fun async type trait override pack pub import with as
val var
match if else
channel select atomic
loop for in while break continue return
true false null
throw defer
```

### 6.2 函数定义

```glue
fun add(a: i32, b: i32) : i32 { a + b }
async fun fetch(url: str): str { ... }

// 借用引用参数 &T：显式标注引用语义，共享读写
fun increment(ref: &i32) {
    *ref = *ref + 1
}

val count = 0
increment(&count)        // count 变为 1

// Lambda
fun(x) { x + 1 }
(x) => x + 1
```

**函数参数语义**：
- **默认（值语义）**：标量按值拷贝传递（修改不影响外部）；复合类型（record/array/str）按指针共享传递（字段修改可见外部）
- **`&T`（显式引用）**：借用引用，标量装箱到堆容器后按指针共享，复合类型行为与默认一致
- **`*T`（裸指针）**：绕过 RC 的不安全指针，预留用于 FFI 场景

`var`/`val` 仅用于局部变量绑定的可变性（var = 可变绑定，val = 不可变绑定），不用于函数参数。
块最后一个表达式自动作为返回值，`return` 用于提前返回。

### 6.3 变量绑定

```glue
val x = 42              // 不可变，推断为 i8（最小可容纳类型）
var count: i32 = 0      // 可变
val len = name?.len() ?? 0
```

### 6.4 类型定义

见 §2.5/§2.13/§2.14（枚举、记录、GADT、别名、Newtype、自定义错误）。

### 6.5 错误处理

见 §2.3/§2.4（`?` 传播、Ok/Error 模式匹配）。

### 6.6 控制流

```glue
val desc = if x > 0 { "positive" } else { "non-positive" }

loop {
    if input == "quit" { break }
}

for i in 0..100 { println(i) }    // 0..100 默认 usize Range

while condition() { do_work() }
```

#### 6.6.1 尾调用优化

Glue 保证 TCO（含相互递归）。实现机制：IR builder 标记尾位置的调用
（`call_meta.tail_call`），引擎对**自递归**直接复用当前帧、对**互递归**通过
`tail_call` 信号在外层 trampoline 循环跳转，均不增长调用栈。非尾递归调用的
最大深度为 2,000,000（配合大栈线程）。

### 6.7 defer

`defer` 注册延迟操作，作用域退出时 LIFO 执行，覆盖正常返回/throw/panic
三种路径。实现为引擎内的 defer 栈（每函数最多 256 个）。

```glue
fun process(): Throw<Unit, FileError> {
    val f = open(path)?
    defer close(f)
    work(f)?
}
```

### 6.8 Panic

Panic 不可捕获，任务级隔离：一个 async 任务的 panic 不影响其他任务
（通过 `AsyncHandle.setPanic` 记录）。`Panic()` 触发 panic。

### 6.9 惰性求值

`Lazy<T>` 为设计保留特性，**当前执行架构未实现**（IR 无对应节点）。

### 6.10 运算符

```
算术:  +  -  *  /  %
拼接:  ++              // 数组拼接 [T] ++ [T] -> [T]（新数组，深拷贝）
索引:  arr[i]          // i 必须为 usize
比较:  ==  !=  <  >  <=  >=  ===  !==
逻辑:  &&  ||  !
Nullable:  ?.  ??  !  ?
范围:  ..  ..=
```

优先级（高 → 低）：`?.`/`.`/调用/`[]` → `?`/`!` → 前缀 `!`/`-` → `*`/`/`/`%` →
`+`/`-`/`++` → `..`/`..=` → 比较 → `==`/`!=` → `&&` → `||` → `??`

**`==` 值相等**（递归结构相等，自动派生不可覆盖）；**`===` 引用相等**（比较
内存地址，标量退化为 `==`）。递归类型循环引用的结构相等为未定义行为。

所有运算符不可重载。没有 `x++` 自增语法（用 `x += 1`）。

### 6.11 字面量

```glue
42              // 无后缀无标注：能容纳该值的最小类型（i8）
42i32           // 显式后缀
3.14            // 能精确往返表示的最小浮点类型（f128）
3.14f32
0xFF  0o77  0b1010  1_000_000
'a'  "hello"  "hello {name}"    // char / str / 插值
[1, 2, 3]                       // 数组
(name: "Alice", age: 30)        // 记录
```

整数字面量优先级：**后缀 > 上下文提升 > 标注 > 最小类型**。
- 上下文提升：数组索引、`for i in 0..N` Range、与 usize/isize 比较/赋值位置
  自动提升为 usize
- 最小类型：非负 `i8→u8→i16→u16→i32→u32→i64→u64→i128→u128`，
  负值 `i8→i16→i32→i64→i128`（同位宽优先有符号）
- 注意：`100 + 100` 两个 i8 相加结果 200 溢出 i8 → 算术溢出 panic；
  需更大范围请加后缀或标注

浮点字面量：后缀 > 标注 > 「精确往返的最小浮点类型」（`f16→f32→f64→f128`
取首个 round-trip 精确者）。`0.5` 为 f16，`3.14` 为 f128。

isize/usize 严格规则（Rust 风格）：字面量可上下文提升；显式变量之间严格统一
（`i32` 与 `usize` 变量比较是类型错误，须 cast）。

**Range 字面量**：`start..end` 非独立类型，元素类型由推断决定；迭代/索引
上下文默认 usize。

**字符串插值**：`{expr}` 调用 `str()`；`{{`/`}}` 转义花括号；`\n`/`\t`/`\r`/`\"`/`\\`。

### 6.12 注释

```glue
// 单行
/* 多行 */
/* 嵌套 /* 注释 */ 支持 */
```

---

## 7. 执行架构：Glue IR 与执行引擎

Glue 当前以 **Glue IR 共享内存数据流图 + 线性执行引擎** 作为唯一执行后端
（早期的树遍历器与字节码 VM 均已废弃删除）。

### 7.1 流水线

```
源代码 → Lexer → Token → Parser → AST
      → Sema（type_check + subtype/throw/trait/kind/gadt/module 子检查器）
      → Static Analysis（const_prop/cse/dead_code/escape/loop_invariant/
                          purity/branch_reach/call_graph，fused_analysis 融合）
      → analysis_db（分析结果数据库）
      → IR Builder（AST + SemaResult + analysis_db → GlueIR）
      → IR Optimizer（常量折叠/死节点消除/通道活跃性/向量融合）
      → Engine（线性执行）
```

- **先检查后求值**（D45）：sema 完全在编译期完成，引擎信任类型信息
- **现编译现执行**（D78）：无磁盘 IR 缓存

### 7.2 Glue IR：共享内存数据流图

IR 不是线性指令流，而是**节点 + 通道**的数据流图（`src/ir/`）：

- **Node**（`node.zig`）：固定 16 字节，连续存储，CPU 缓存友好。
  字段：op（u8）、inputs[]（输入通道索引）、output（输出通道）、
  meta_index（元数据索引）等
- **通道（Channel）**：节点间传递数据的边，全局统一通道空间、全局索引，
  无跨图映射；通道数据存放在 ChannelRegion（bump+reset，64B 对齐）
- **元数据**（`meta.zig`/`channel.zig`）：ScalarMeta、LoopMeta、CallMeta
  （含 tail_call 标记与 memo_slot）、ChannelMeta、TypeMetadata、orbit_metas、
  syscall_metas 等侧表，节点通过 meta_index 引用（1-indexed）
- **SemaResult 契约**（`sema_output.zig`）：sema 向 builder 传递表达式类型/
  位置等信息；analysis_db 提供 LICM 不变量、纯度等优化信息
- **printer.zig**：IR 图结构化可视化（调试用）

#### NodeOp 分组（src/ir/node.zig）

| 组 | 主要 op |
|---|---|
| 标量计算 | `const_*`、`int_add/sub/mul/div/mod`、位运算、`float_*`、`cmp_*`、`bool_*`、`cast`、`cast_to`、`cast_try_to` |
| 数据结构 | `array_make/get/set/len/push/concat/fill/slice/...`、`record_make/get/set/clone`、`string_concat/len/index/slice/bytes`、`array_to_str`、`newtype_wrap/unwrap` |
| 向量计算 | `vec_source`、`vec_map`、`vec_map2`、`vec_fold`、`vec_scan`、`vec_filter`、`vec_select`、`vec_take`、`vec_take_while`、`vec_zip`、`vec_sink` |
| 门控（?/Throw） | `gate_check`、`gate_get_ok/err`、`gate_propagate`、`gate_select`、`gate_make_ok/err` |
| 路由（Trait 分派） | `route_get_tag`、`route_dispatch`、`route_merge` |
| 竞争（select） | `race_source`、`race_select`、`race_yield` |
| 清理（defer） | `cleanup_register`、`cleanup_run` |
| Nullable | `nullable_make/is_null/unwrap/unwrap_or` |
| 控制流 | `call`、`halt_return/throw/panic/break/continue`、`scalar_loop` |
| 内建函数 | `builtin_print/println/eprint/eprintln/scan/scanln/ok/error/eq/str/ref_eq/type/panic/typeof` |
| Syscall | `syscall_call`（meta_index → syscall_metas） |
| 星轨（async/channel） | `orbit_async_create/join/status`、`orbit_chan_send/recv/try_recv`、`channel_create/sender/receiver/close` |
| 原子 | `atomic_swap`、`atomic_cas` |
| 反射 | `error_message`、`obj_type_name` |
| 闭包 | `closure_make`、`call_indirect` |

### 7.3 IR Builder（src/ir/builder.zig）

从 AST + SemaResult + analysis_db 构建 GlueIR，覆盖全部语言特性的 lowering：
函数/闭包/match/async/channel/trait/属性注解/内建函数/cast builder 等。
尾位置调用标记 `tail_call`；LICM 不变量外提信息来自 loop_invariant 分析。

### 7.4 IR Optimizer（src/ir/optimizer.zig）

常量折叠、死节点消除、通道活跃性分析、向量融合等 pass。

### 7.5 执行引擎（src/engine/engine.zig）

**执行模型**：
- 按函数 `node_start..node_start+node_count` 线性遍历 nodes[]
- 每个节点经 switch 分派到对应 `exec*` 函数
- 节点从 inputs[] 通道读数据，结果写 output 通道
- `halt_*` 节点终止当前函数执行；`call` 节点压栈调用

**调用与 TCO**：
- Frame 调用栈（func_idx / return_chan / return_pc），最大深度 2,000,000
- 自递归尾调用：复用当前帧；互递归尾调用：trampoline 跳转（均不增栈）
- `memo_slot > 0` 的调用支持记忆化（fib 等 bench 使用）

**循环加速（关键性能机制）**：
- `LoopActiveCache`：把 while 条件段/循环体段的有效节点预编译为
  **BodyInst 直接调用序列**，热循环内完全消除 switch dispatch
- 标量循环接入 `batch.zig` SIMD 批量运算与 `@reduce` 横向归约
- LICM 外提的不变量节点单独缓存，迭代内不重复执行

**defer**：引擎内 defer 栈（LIFO，每函数 ≤256），`cleanup_register` 入栈，
`halt` 时 `cleanup_run` 执行。

### 7.6 并发集成

- **async**：`orbit_async_create` 创建 AsyncHandle + spawn OS 线程
  （worker 独立 Engine/ThreadContext/Runtime，IR 与 GlobalPool 只读共享）；
  `orbit_async_join` 条件变量阻塞等待；`orbit_async_status` 查询状态
- **channel**：`channel_create`（带缓冲，Mutex + not_empty/not_full 条件变量）、
  `channel_sender/receiver`（方向句柄，RC 共享底层 channel）、
  `orbit_chan_send/recv/try_recv`、`channel_close`
- **select**：`race_source` 检查各分支就绪性 → `race_select` 选第一个就绪 →
  `race_yield` 让出
- **Atomic**：透明读写 + `atomic_swap`/`atomic_cas` 节点
- **syscall**：`syscall_call` 按 SyscallId 分派到 `src/syscall/`（io/time 原语），
  std 库的 `@[syscall]` 注解函数经此路径调用宿主

### 7.7 性能基线（ReleaseFast，2026-07-18，macOS）

| Benchmark | engine_run (ms) | 说明 |
|---|---|---|
| fib | 0.042 | 记忆化生效 |
| lookup | 108.9 | 长循环观测点 |
| record | 152.8 | 长循环观测点 |
| float | 41.1 | 软件 IEEE 754 路径 |
| string | 2.9 | |
| closure | 8.8 | |
| array | 9.6 | |
| tailcall | 143.6 | TCO 密集（千万级迭代） |

---

## 8. 当前实现状态

### 8.1 已实现的语言特性

| 类别 | 特性 |
|---|---|
| 基础类型 | i8..i128、u8..u128、isize/usize、f16/f32/f64/f128、bool、char、str、Unit |
| 字面量 | 整数（最小类型 + 后缀 + 标注 + 上下文提升）、浮点（round-trip 最小类型）、进制前缀、下划线、char、插值、数组、记录 |
| 运算符 | 算术/比较/逻辑/位/Nullable/范围/`++`/索引（强制 usize） |
| 类型转换 | cast builder（`.to` wrap / `.try_to` 检查），尾数精度宽化分析 |
| 变量绑定 | val/var、类型收窄、嵌套遮蔽 |
| 函数 | 命名函数、Lambda、柯里化、var 参数、禁止链式调用、TCO（含互递归） |
| 类型 | 枚举、记录、递归类型、抽象类型、别名、Newtype |
| ADT | Pattern Matching（守卫/或模式/构造器/记录/字面量/newtype/Throw）、穷举检查 |
| Nullable | `T?`、`?.`、`??`、`!`、`?` 传播、扁平化、协变 |
| Throw | `Throw<T, E>`、throw、`?` 传播、Ok/Error 匹配、Error 子类型、自定义错误 |
| Trait | 定义、type 内联实现、多 trait、默认方法、override、组合、关联类型、Self、trait bound、`with` 特化 |
| HKT | Kind 系统 |
| GADT | 构造器返回类型标注、match 类型细化 |
| 变异性 | 自动推导 |
| 子类型 | 记录宽度、Trait 结构化、Error |
| 控制流 | if/loop/while/for/break/continue/return/defer |
| 并发 | `async fun`、`Async<T>.await()/status()`、channel（send/recv/close/方向类型）、select（含 timeout）、Atomic（透明操作 + swap/cas） |
| 一等 Trait 值 | 文件模块作为 Trait 值、内联 trait 值、vtable 分派 |
| 模块 | 文件即模块、pack.glue、import（选择/整体/别名/通配）、pub、抽象类型、循环依赖检测 |
| 内嵌标准库 | std/io（File/Fs/Dir/Path/Buffered）、std/time（Instant/SystemTime/DateTime/Duration/Calendar/Timer） |
| Builtin | CastError/IOError/TimeError（Glue 自举，按需加载） |
| 项目 CLI | `glue init`/`run`/`debug`、`--profile`、glue.toml |
| I/O 内建 | println/print/eprintln/eprint/scanln/scan |

### 8.2 已实现的引擎能力

| 类别 | 覆盖 |
|---|---|
| 执行模型 | 线性遍历 + switch 分派 + 通道读写 |
| 调用 | Frame 栈（深度上限 2M）、TCO（自递归复用帧/互递归 trampoline）、记忆化 |
| 循环加速 | 循环体预编译（BodyInst 直接调用）、SIMD 批量运算、LICM 外提 |
| 向量 | vec_map/fold/scan/filter/select 等全套 |
| 门控/路由/竞争 | ? 传播、Trait 动态分派、select 多路复用 |
| defer | cleanup 栈，覆盖返回/throw/panic |
| 闭包 | closure_make + call_indirect |
| 并发 | OS 线程 + per-worker Engine/ThreadContext/Runtime + panic 任务级隔离 |
| channel | 缓冲 FIFO、关闭语义、方向句柄、try_recv |
| Atomic | 透明原子操作 + swap/cas |
| Syscall | SyscallId 分派，io/time 原语 |
| 内存 | RC + 三级分配器 + TLS 零锁热路径 |

### 8.3 已知限制与待办

| 项 | 状态 |
|---|---|
| `Lazy<T>` | 设计保留，新架构未实现（IR 无 lazy 节点） |
| `Async<T>.cancel()` / `.result()` | 设计保留，引擎未实现（仅有 await/status） |
| async 参数传递 | 当前上限 4 个 i64 标量参数（OrbitThreadData.args: [4]i64） |
| channel 传递值 | 当前以标量路径为主（readScalarValue/writeScalarValue） |
| Atomic 实现 | 互斥锁保护，非无锁指令 |
| 调度 | 每 async 一个 OS 线程，非 M:N 协程；大规模并发受线程数限制 |
| M:N work-stealing 调度器 | 未实现 |
| 部分 string/array 辅助 syscall | 待补 |

### 8.4 测试状态

- 单元测试：`zig build test` 聚合 13 组模块测试（lexer/parser/sema/value/ir/
  engine/syscall/mem 各分配器等），全部通过
- 端到端测试：`tests/` 下 47 个测试工程（edge_*/phase*/stress_*/std_* 等）
- 基准：`bench/` 14 个基准工程（含 stress_composite/compute/memory/profile）

---

## 9. 设计决策记录

| 编号 | 决策 | 理由 | 替代方案 |
|---|---|---|---|
| D01 | CSP + async + channel | 与函数式契合，简洁，运行时安全 | Actor, STM, async/await 关键字 |
| ~~D02~~ | ~~Per-heap 隔离 GC~~ | **已修订为 D87** | — |
| D03 | 运行时并行安全 | 降低学习门槛 | 编译期所有权系统 |
| D04 | 无 Effect System | Throw<T, E> 覆盖错误处理 | Effect System |
| D05 | 严格求值（Lazy 保留未实现） | 惰性与并行交互复杂 | 惰性求值 |
| D06 | 默认柯里化 | 函数式特征，自然部分应用 | 显式柯里化 |
| D07 | ADT + Trait（组合） | 组合优于继承 | class + 继承 |
| D08 | 文件即模块 + pack.glue | 简洁，约定优于配置 | 显式 module 声明 |
| D09 | 一等 Trait 值 (vtable) | 运行时多态 + 依赖注入 | 闭包元组 |
| D10-D12 | 结构化匹配（文件模块）/ 名义化匹配（type 内联）/ 根目录豁免 | 灵活 + 显式契约 + 零配置 | — |
| D13 | 入口 `src/Main.glue` + glue.toml | 约定优于配置 | 纯约定 / 完整配置 |
| D14-D15 | 无 pack.glue 目录忽略 / 未声明文件忽略 | 规则简单，允许 WIP 安静存在 | 自动发现 / 编译警告 |
| D16-D20 | Nullable 设计（`T?`/共享 null/内建/协变/扁平化） | 直觉简洁，专门优化 | Option ADT |
| D21-D24 | Trait bound / orphan 禁止 / overlapping 禁止 / 完整 HKT | 连贯性 + 表达力 | 字典传递 / 有条件允许 |
| D25-D29 | 子类型替代行变量 / GADT / 别名+Newtype / 无 Rank-N / 隐式 Existential | 简单直观 | Row Polymorphism 等 |
| D30-D34 | 花括号 / `fun` / `: T` / `<T: Trait>`+`with` / `val`/`var` | 主流 + 明确 | 缩进 / fn / where / let |
| ~~D35~~ | ~~spawn + Spawn.await()~~ | **已修订为 D89** | — |
| D36-D43 | Throw 设计（GADT `:` 标注 / 双参数 / Error trait / 错误 newtype / 统一 `?` / 严格传播 / 双机制 / 无 try-catch） | 类型安全 + 穷举匹配 | 单参数 / 异常 |
| ~~D44~~ | ~~字节码 VM~~ | **已修订为 D88** | — |
| D45 | 先检查后求值 | 引擎信任类型信息 | 求值器内嵌检查 |
| D46-D51 | 显式转换 / UTF-8 / 运算符不可重载 / Iterable 协议 / `==`+`===` / `?` 不跨类型 | 安全可预测 | 隐式提升 / 重载 |
| D52-D60 | Panic 不可捕获 / Panic() / OOM 可恢复 / defer / 溢出 panic / channel 关闭语义 / 深拷贝捕获 / var 原地修改 / main 无参数 | 简单统一 | panic-recover / RAII |
| D61-D62 | 浮点无 NaN/Inf / 模块依赖 DAG | 类型系统确定性 | IEEE 754 |
| D63-D74 | 数组固定大小 / 引用捕获（普通闭包）/ Range 非独立类型 / 插值 / List 属 std / 参数默认 val / 禁止链式调用 / TCO / 无匿名元组 / 无 Agent / Atomic 替代 Arc / Throw 构造器 Ok/Error | 简洁 + 安全 | 各自替代方案 |
| D75 | Trait 实现内联进 type 声明 | type 定义即完整契约 | 独立 impl 块 |
| ~~D76~~ | ~~Value 16 字节~~ | **已修订为 D90** | — |
| ~~D77~~ | ~~栈式 VM~~ | **已修订为 D88** | — |
| D78 | 现编译现执行 | 编译耗时相对运行时可忽略 | 磁盘缓存 / JIT |
| D79-D82 | cast builder / to vs try_to / cast 豁免溢出 panic / cast 产生 Inf panic | 双轨语义清晰 | Type(value) 语法 |
| D83-D86 | isize/usize 跟随平台 / 索引强制 usize / builtin Glue 自举 / builtin 按需加载 | 类型安全 + 自举方向 | 固定 64 位 / Zig 硬编码 |
| **D87** | **RC + 三级分配器，无追踪式 GC** | 零全局暂停、内存占用与碎片最小化；bump+reset 批量释放短命对象 | 分代复制 GC（原 D02） |
| **D88** | **Glue IR 共享内存数据流图 + 线性执行引擎** | 数据流图直接表达依赖；16B 定长节点缓存友好；循环体可预编译消除 dispatch | 字节码栈式 VM（原 D44/D77） |
| **D89** | **`async fun` + `Async<T>`，每任务一个 OS 线程** | 语法与函数调用统一；worker 独立 Engine/ThreadContext 天然隔离 | spawn 关键字 + M:N 协程（原 D35） |
| **D90** | **Value 24B：标量 [N]u8 按实际宽度内联，堆对象统一 ObjHeader** | 无 padding、SIMD 友好、类型无关分配器 | 16B tag+payload（原 D76） |
| **D91** | **循环体预编译（BodyInst）+ SIMD 批量运算** | 热循环消除 switch dispatch，吞吐最大化 | 逐节点 dispatch |
| **D92** | **ChannelRegion 64B 对齐 bump+reset** | SIMD 兼容 + O(1) 基本块级回收 | 逐对象释放 |
| **D93** | **sema 静态分析族 + analysis_db** | 检查与优化信息一次计算、builder/optimizer 复用 | 各阶段重复分析 |

---

## 10. 术语表

| 术语 | 英文 | 含义 |
|---|---|---|
| ADT | Algebraic Data Type | 代数数据类型（和类型 + 积类型） |
| GADT | Generalized ADT | 构造器可返回不同类型参数 |
| CSP | Communicating Sequential Processes | 通过 channel 通信的并发模型 |
| HM | Hindley-Milner | 类型推断算法 |
| HKT | Higher-Kinded Types | 高阶类型 |
| 一等 Trait 值 | First-Class Trait Value | Trait 作为运行时值，vtable 分派 |
| Nullable | Nullable | 可空类型 `T?` |
| Throw | Throw | `Throw<T, E>`，返回 T 或抛出 E |
| 类型收窄 | Type Narrowing | 编译器将 `T?` 收窄为 `T` |
| 类型细化 | Type Refinement | GADT match 推导局部类型等式 |
| 协变/逆变/不变 | Co/Contra/In-variant | 子类型替换规则 |
| Newtype | Newtype | 单字段 ADT，零开销新类型 |
| Async<T> | Async Handle | async 函数调用返回的任务句柄（await/status） |
| Atomic<T> | Atomic | 透明原子操作，跨任务共享状态 |
| Glue IR | Glue IR | 共享内存数据流图（16B 定长节点 + 全局通道） |
| 通道（IR） | Channel (IR) | IR 节点间传递数据的边，全局索引 |
| Channel（语言） | Channel | CSP 通信通道（send/recv/close） |
| RC | Reference Counting | 引用计数内存管理 |
| ChannelRegion | Channel Region | IR 通道数据的 bump+reset 分配区（64B 对齐） |
| ObjectPool | Object Pool | 堆对象精确尺寸页池 |
| ShadowArena | Shadow Arena | 函数级临时 bump+reset 分配区 |
| ThreadContext | Thread Context | 每线程分配器入口（TLS，热路径零锁） |
| GlobalPool | Global Pool | 冷路径页缓存 + buddy 大对象分配 |
| BodyInst | Body Instruction | 循环体预编译的直接调用指令（消除 dispatch） |
| TCO | Tail Call Optimization | 尾调用优化（自递归复用帧 / 互递归 trampoline） |
| LICM | Loop-Invariant Code Motion | 循环不变量外提 |
| 先检查后求值 | Check-then-eval | sema 不过则阻止执行，引擎信任类型信息 |
| 值相等/引用相等 | Value/Reference Equality | `==` 结构相等 / `===` 地址相等 |
| Panic | Panic | 不可恢复 bug，任务级隔离 |
| defer | defer | LIFO 延迟执行，覆盖返回/throw/panic |
| 深拷贝捕获 | Deep-copy Capture | async 实参深拷贝隔离（Atomic 浅拷贝例外） |
| cast builder | Cast Builder | `cast(expr).to(T)` / `.try_to(T)` 双轨转换 |
