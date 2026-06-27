# Glue 语言当前状态总览

> 版本: 0.9.0-draft
> 最后更新: 2026-06-27

本文档是 Glue 语言的权威参考，涵盖设计、语法、类型系统、并发模型、模块系统与字节码 VM 实现的当前真实状态。历史进展记录已废弃，本文档仅描述当前代码库的实际能力。

---

## 目录

1. [语言概述与设计哲学](#1-语言概述与设计哲学)
2. [类型系统](#2-类型系统)
3. [并行与并发模型](#3-并行与并发模型)
4. [模块系统](#4-模块系统)
5. [运行时与垃圾回收](#5-运行时与垃圾回收)
6. [语法设计](#6-语法设计)
7. [字节码 VM 架构](#7-字节码-vm-架构)
8. [当前实现状态](#8-当前实现状态)
9. [设计决策记录](#9-设计决策记录)
10. [术语表](#10-术语表)

---

## 1. 语言概述与设计哲学

### 1.1 Glue 是什么

Glue 是一门通用编程语言，核心目标是让并行编程变得安全、自然、高效。Glue 采用函数式范式，通过类型系统和运行时的协同设计，在编译期追踪空值和错误、在运行时保证并行安全。

### 1.2 设计哲学

| 原则 | 含义 |
|---|---|
| **组合优于继承** | 通过 ADT + Trait + 一等 Trait 值组合行为，不提供继承机制 |
| **显式优于隐式** | 空值和错误通过类型系统显式标注，`?` 操作符显式传播，类型转换必须显式 |
| **安全默认** | 默认不可变、默认私有、默认值语义，安全不需要额外努力 |
| **运行时并行安全** | 并行安全由运行时架构保证，无需用户手动管理 |
| **约定优于配置** | 最小清单即可运行，程序入口为 `fun main()`，类似 C/Go/Java |
| **渐进复杂度** | 简单的事情简单做，复杂的事情可能，但不强制 |

### 1.3 核心设计决策总览

| 维度 | 决策 |
|---|---|
| 目标领域 | 通用编程 |
| 范式 | 函数式 |
| 并发模型 | CSP + spawn + channel |
| 并行安全策略 | 运行时保证（值语义 + 深拷贝 + Per-Heap GC + Atomic<T>） |
| 求值策略 | 严格求值 + 显式惰性 (`Lazy<T>`) |
| 柯里化 | 默认柯里化 |
| 类型系统 | Hindley-Milner 推断 + ADT + GADT + Nullable + Throw<T, E> + Trait + HKT + 子类型 |
| 数据语义 | 值语义（默认不可变） |
| 共享机制 | Atomic<T> 跨协程共享原子状态（替代 Arc<T>） |
| 错误处理 | `Throw<T, E>` + `throw` + `?` 传播 + Nullable (`T?`) |
| GC 策略 | Per-Heap 隔离 GC |
| 模块系统 | 文件即模块 + `pack.glue` + `import` 导入 |
| 变异性 | 自动推导 + 可选显式标注 |
| 可见性 | 默认私有 + `pub` 公开 |
| 函数关键字 | `fun` |
| 返回类型 | `: T` |
| Trait 实现 | type 定义时内联实现，语法：`type T: Trait = ...` |
| 类型参数约束 | `<T: Trait1 + Trait2>` |
| 类型特化约束 | `with T: ConcreteType` |
| 变量绑定 | `val`（不可变）、`var`（可变） |
| 并发原语 | `spawn` + `Spawn<T>.await()` + `channel` + `Atomic<T>` + `select` |
| 协程运行时 | 依赖 Zio 库（栈式协程 + 多线程调度 + io_uring/IOCP/kqueue） |
| 类型转换 | 显式 `Type(value)` 语法，widening 合法 narrowing 运行时检查 |
| 运算符 | 内建不可重载 |
| 字符串 | UTF-8 编码，迭代产生 `char` |
| 执行后端 | 字节码栈式 VM（树遍历求值器已废弃） |

---

## 2. 类型系统

### 2.1 概述

Glue 的类型系统以 Hindley-Milner 为基础，扩展了代数数据类型 (ADT)、GADT、Nullable 类型、Throw 类型、Trait、Higher-Kinded Types 和子类型关系。类型推断在大多数场景下可以自动完成，用户无需显式标注。

核心设计原则：
- **安全默认**：类型 `T` 不可空，`T?` 才可空；`T` 不会抛错，`Throw<T, E>` 才可抛
- **组合优于继承**：通过 ADT + Trait 组合行为，不提供继承
- **显式传播**：`?` 操作符统一处理 Nullable 和 Throw 的坏值传播
- **显式转换**：数值类型之间没有隐式转换，必须使用 `Type(value)` 显式转换
- **运算符用户不可重载**：运算符对内建类型有特例（如 `str + str` 拼接），自定义类型使用命名方法

### 2.2 基础类型

```
i8    i16    i32    i64    i128
u8    u16    u32    u64    u128
f16   f32    f64    f128
bool
char
```

基础类型均为值类型，存储在栈上或直接内联在数据结构中。

| 类型 | 含义 | 备注 |
|---|---|---|
| `i8` | 有符号 8 位整数 | |
| `i16` | 有符号 16 位整数 | |
| `i32` | 有符号 32 位整数 | |
| `i64` | 有符号 64 位整数 | |
| `i128` | 有符号 128 位整数 | |
| `u8` | 无符号 8 位整数 | |
| `u16` | 无符号 16 位整数 | |
| `u32` | 无符号 32 位整数 | |
| `u64` | 无符号 64 位整数 | |
| `u128` | 无符号 128 位整数 | |
| `f16` | 16 位半精度浮点数 | IEEE 754-2008 binary16，范围 ±65504，约 3 位十进制精度 |
| `f32` | 32 位单精度浮点数 | IEEE 754 binary32，约 7 位十进制精度 |
| `f64` | 64 位双精度浮点数 | IEEE 754 binary64，约 15 位十进制精度 |
| `f128` | 128 位四精度浮点数 | IEEE 754-2008 binary128，约 34 位十进制精度 |
| `bool` | 布尔类型 | 值为 `true` 或 `false` |
| `char` | Unicode 标量值 | 4 字节，字面量用单引号 `'a'`，显示时无引号 `a` |
| `str` | 字符串 | UTF-8 编码，字面量用双引号 `"hello"`，迭代产生 `char` |
| `()` | 单位类型 | 又称 `Unit`，表示没有有意义的值 |

**整数溢出行为**：
整数溢出在 Debug 和 Release 模式下都会触发 panic。溢出几乎总是 bug，静默 wrap around 会掩盖错误：

```glue
val max: i32 = 2147483647
val overflow = max + 1    // panic: integer overflow
```

整数溢出就是 panic，没有 wrap around 语义。

**浮点数无 NaN 和 Infinity**：
Glue 的浮点数不包含 NaN 和 Infinity 值。浮点除零触发 panic，而非产生 Infinity 或 NaN。

```glue
val a = 1.0 / 0.0     // panic: division by zero
val b = 0.0 / 0.0     // panic: division by zero
```

理由：
1. NaN 的 `NaN != NaN` 语义与 Glue 的 `==` 引用相等冲突
2. NaN 和 Infinity 是 IEEE 754 的特殊值，增加了类型系统的不确定性——每个 `f64` 值都需要考虑"可能是 NaN"的情况
3. 浮点除零几乎总是 bug，panic 比 silently 产生特殊值更安全
4. 如果需要表示"无效"或"无穷大"，使用 `f64?` 或 `Throw<f64, Error>` 显式表达

**str 与 UTF-8 编码**：
str 使用 UTF-8 编码存储，这是内存效率最高的 Unicode 编码方式。UTF-8 编码带来以下特性：

- **迭代产生 `char`**：遍历 str 时产生 Unicode 标量值（`char`），而非字节
- **索引是 O(n) 操作**：由于 UTF-8 是变长编码，通过索引访问第 n 个字符需要从头遍历字节
- **`len()` 返回字符数**：`str.len()` 返回 Unicode 标量值数量（字符数），而非字节数

```glue
val s = "你好"
s.len()          // 2（2 个 Unicode 标量值）

// 迭代产生 char
for c in s {
    println(c)   // 依次输出 '你' '好'
}
```

**数值类型之间无隐式转换**：
不同数值类型之间不会自动转换，必须使用显式转换语法 `Type(value)`。

```glue
val a: i32 = 42
val b: i64 = i64(a)      // 显式转换
val c: f64 = f64(a)      // 显式转换
// val d: i64 = a         // 编译错误：no implicit conversion
```

### 2.3 Nullable 类型

Glue 不使用 `Option<T>`，而是通过内建的 Nullable 类型系统支持空值。

#### 2.3.1 `T?` 语法

`T?` 表示 `T` 类型的值或 `null`。`T?` 是类型系统的内建特性，不是语法糖。

```glue
val a: i32 = 42          // 不可空
val b: i32? = null       // 可空，持有 null
val c: i32? = 42         // 可空类型也可以持有非空值
val d: i32 = null        // 编译错误：i32 不可空
```

#### 2.3.2 `null` 的类型

`null` 是所有 `T?` 类型的共享值。`null` 的类型为 `Null`，`Null` 是所有 `T?` 类型的子类型。

```
Null <: str?
Null <: i32?
Null <: User?
```

因此 `null` 可以赋值给任何 `T?` 类型的变量。

#### 2.3.3 `T?` 的变异性

`T?` 与 `T` 协变：

```
Cat <: Animal  ⟹  Cat? <: Animal?
```

#### 2.3.4 双重可空扁平化

`T??` 等价于 `T?`，不区分"null"和"嵌套的 null"。

```glue
val x: str?? = null       // 等价于 str?
val x: str?? = "hello"    // 等价于 str?
```

#### 2.3.5 使用可空值——类型收窄

使用可空值前必须消除空值可能性。编译器通过类型收窄 (type narrowing) 追踪。

**match 收窄**：

```glue
fun greet(name: str?) : str {
    match name {
        null => "Hello, stranger",
        n => "Hello, " + n,    // n : str（已收窄为不可空）
    }
}
```

**if 收窄**：

```glue
fun length(s: str?) : i32 {
    if s != null { s.len() } else { 0 }
    // s 在 then 分支中收窄为 str
}
```

#### 2.3.6 安全调用操作符 `?.`

```glue
val len = name?.len()    // 如果 name 是 null，返回 null；否则返回 len
// len 的类型: i32?
```

等价于：

```glue
match name {
    null => null,
    n => n.len(),
}
```

`?.` 可以链式调用：

```glue
val city = user?.address?.city    // city : str?
```

#### 2.3.7 Elvis 操作符 `??`

```glue
val len = name?.len() ?? 0    // 如果是 null，使用默认值 0
// len 的类型: i32
```

`??` 提供默认值，将 `T?` 转为 `T`。

#### 2.3.8 非空断言 `!`

```glue
val len = name!.len()    // 如果 name 是 null，运行时 panic
```

`!` 用于确定值不为 null 但编译器无法证明的情况。应谨慎使用。

#### 2.3.9 `?` 传播操作符

`?` 作为表达式后缀操作符，用于提前传播"坏值"。

**用于 `T?` 时**：

```glue
fun greet() : str? {
    val name = get_name()?    // null 时提前返回 null
    "Hello, " + name          // name 已收窄为 str
}
```

**用于 `Throw<T, E>` 时**：

```glue
fun read_config() : Throw<Config, Error> {
    val content = read_file("config.json")?    // throw 时提前传播 throw
    val config = parse_json(content)?           // throw 时提前传播 throw
    config
}
```

`?` 操作符要求外层函数的返回类型兼容：
- `expr?` 作用于 `T?` 时，外层函数必须返回 `U?`
- `expr?` 作用于 `Throw<T, E_inner>` 时，外层函数必须返回 `Throw<U, E_outer>`，且 `E_inner <: E_outer`
- 在普通函数（非 `T?`、非 `Throw<T, E>` 返回）中使用 `?`，编译错误

**`?` 不跨 Nullable 和 Throw 自动转换**：
null 和 error 是语义不同的概念——null 表示"值不存在"，error 表示"操作失败并附带原因"。因此 `?` 严格按类型匹配，不跨类型传播。

```glue
// ✗ 编译错误：在 Throw 函数中对 T? 用 ?
fun read_config() : Throw<Config, Error> {
    val name = get_name()?     // get_name() 返回 str?，要求外层返回 U?
    parse_config(name)
}

// ✓ 正确：显式处理 null
fun read_config() : Throw<Config, Error> {
    val name = get_name() ?? throw Error("name is null")
    parse_config(name)
}

// ✗ 编译错误：在 Nullable 函数中对 Throw 用 ?
fun safe_get() : str? {
    val content = read_file("data.txt")?  // read_file 返回 Throw<str, FileError>
    content
}

// ✓ 正确：模式匹配处理 Throw
fun safe_get() : str? {
    match read_file("data.txt") {
        Ok(content) => content,
        Error(_) => null,
    }
}
```

**`Throw<T?, E>` 的两步处理**：
当两个维度同时存在时，需要分别处理——先处理 Throw，再处理 Nullable。

```glue
fun find_user(id: i32) : Throw<User?, FileError> {
    val result = db_query(id)?    // Throw<User?, FileError> -> User?
    result                         // User? 仍可能是 null
}

// 使用时两步处理
val user = match find_user(42) {
    Ok(u) => u,           // u : User?
    Error(e) => null,       // 降级为 null
}
// user : User?  还需要处理 null
val name = user?.name ?? "anonymous"
```

> **注意**：`T?` 中的 `?` 是类型后缀（表示可空），`expr?` 中的 `?` 是表达式操作符（表示传播）。两者处于不同语法位置，编译器无歧义区分。

#### 2.3.10 Nullable 与 Pattern Matching

`null` 作为模式直接匹配：

```glue
fun describe(n: i32?) : str {
    match n {
        null => "nothing",
        0 => "zero",
        x if x < 0 => "negative",
        _ => "positive",
    }
}
```

#### 2.3.11 Nullable 与 Trait

`T` 和 `T?` 是不同的类型，需要分别实现 trait。

```glue
trait Show {
    fun show(self): str
}

type MyInt: Show = MyInt(value: i32) {
    fun show(self): str { 
        str(self.value) 
    }
}

type NullableInt: Show = NullableInt(value: i32?) {
    fun show(self): str {
        match self.value {
            None => "null",
            Some(x) => str(x),
        }
    }
}
```

#### 2.3.12 Nullable 与并发

```glue
fun producer(ch: Sender<i32?>) : Unit {
    ch.send(42)
    ch.send(null)        // ✓ 发送 null
}

fun consumer(ch: Receiver<i32?>) : Unit {
    val v = ch.recv()
    match v {
        null => println("got null"),
        n => println(n),
    }
}
```

#### 2.3.13 Nullable 不是副作用

null 是类型系统追踪的属性，不是运行时副作用。访问可空值、处理 null 不涉及 Effect。

### 2.4 Throw 类型

`Throw<T, E>` 是内建包装类型，表示"返回 T 或抛出类型为 E 的错误"。通过双参数形式，错误类型 E 在类型签名中显式声明，使得错误处理既类型安全又支持穷举匹配。

#### 2.4.1 Error Trait

`Error` 是内建 Trait，所有可以被 `throw` 抛出的类型必须满足 `Error`。

```glue
// Error 是内建 Trait，无需定义
throw Error("something went wrong")

// Error 有 message 字段
val e = Error("not found")
e.message    // "not found"
```

`Error` 是所有错误类型的基类型。自定义错误类型都是 `Error` 的子类型。

#### 2.4.2 自定义错误类型

使用 OOP 风格语法创建自定义错误类型，通过 `: Error` 声明实现 Error trait：

```glue
type FileError: Error = FileError(msg: str) {
    override fun prefix(self): str {
        "file error"
    }
}

type NetworkError: Error = NetworkError(msg: str) {
    override fun prefix(self): str {
        "network error"
    }
}

type ParseError: Error = ParseError(msg: str) {
    override fun prefix(self): str {
        "parse error"
    }
}
```

语法：`type Name: Error = Name(msg: str) { override fun prefix(self): str { "前缀" } }`

语义：
1. 声明 `Name` 实现 Error trait（`: Error`）
2. 定义构造器参数 `msg: str`
3. 通过 `override fun prefix` 定义错误前缀
4. Error trait 提供内置方法：`message(self): str` 和 `type_name(self): str`
5. **`Name` 是 `Error` 的子类型**——`FileError <: Error`

```glue
throw FileError("config.json not found")
// 错误消息通过 message() 方法获取
val e = FileError("test")
println(e.message())  // "file error: test"

throw NetworkError("connection refused")
// 错误消息: "network error: connection refused"
```

#### 2.4.3 Error 子类型关系

```
Error              // 基类型
├── FileError      // <: Error
├── NetworkError   // <: Error
└── ParseError     // <: Error
```

子类型关系规则：
- `FileError <: Error`、`NetworkError <: Error`、`ParseError <: Error`
- 自定义错误类型之间没有子类型关系
- `Error` 是所有错误类型的公共父类型

#### 2.4.4 Throw<T, E> 的定义

`Throw<T, E>` 是内建类型，其中 `T` 是成功时的值类型，`E` 是错误类型（必须满足 `Error` 约束）：

```glue
fun read_file(path: str) : Throw<str, FileError> {
    if !found { throw FileError(path + " not found") }
    "content"
}
```

`Throw<T, E>` 的值有两种状态：
- `Ok(value)` ——成功，持有 T 类型的值
- `Error(message)` ——失败，持有错误信息

#### 2.4.5 throw 语句

`throw` 抛出一个满足 Error trait 的值，立即终止当前函数执行。

```glue
fun risky_operation() : Throw<str, Error> {
    if something_wrong { throw Error("unexpected failure") }
    "ok"
}
```

规则：
- `throw` 只能抛出满足 Error trait 的值
- `throw` 只能在返回 `Throw<T, E>` 的函数中使用
- `throw` 抛出的错误类型必须是 E 的子类型
- `throw` 会立即终止函数执行

#### 2.4.6 `?` 传播 Throw

```glue
fun read_config() : Throw<Config, Error> {
    val content = read_file("config.json")?    // Throw<str, FileError> -> str
    val config = parse_json(content)?           // Throw<Config, ParseError> -> Config
    config
}
```

`?` 的传播规则：
- `expr?` 作用于 `Throw<T, E_inner>` 时，成功得到 `T`，失败则提前传播 throw
- 外层函数必须返回 `Throw<U, E_outer>`，且 `E_inner <: E_outer`
- 在普通函数中调用 `Throw<T, E>` 函数，必须通过模式匹配显式处理，不能用 `?`

#### 2.4.7 Throw 模式匹配

```glue
match read_file("config.json") {    // Throw<str, FileError>
    Ok(content) => process(content),
    Error(e) => println("error: " + e.message),
}
```

`Ok(v)` 匹配成功值，`Error(e)` 匹配错误值。

#### 2.4.8 Throw 与 Nullable 的组合

`Throw<T?, E>` 合法——可能 throw，也可能返回 null，两个维度独立：

```glue
fun find_user(id: i32) : Throw<User?, FileError> {
    val result = db_query(id)?
    result
}
```

#### 2.4.9 Throw 的变异性

`Throw<T, E>` 对 `T` 和 `E` 均协变：

```
Cat <: Animal  ⟹  Throw<Cat, E> <: Throw<Animal, E>
FileError <: Error  ⟹  Throw<T, FileError> <: Throw<T, Error>
```

### 2.5 代数数据类型 (ADT)

ADT 是 Glue 组织数据的核心方式。没有 class，没有继承。

#### 2.5.1 枚举类型（和类型 / Sum Type）

```glue
type Ordering =
    | Lt
    | Eq
    | Gt

type Shape =
    | Circle(radius: f64)
    | Rectangle(width: f64, height: f64)
    | Triangle(a: f64, b: f64, c: f64)
```

#### 2.5.2 记录类型（积类型 / Product Type）

```glue
type User = (
    name: str,
    age: i32,
    email: str?,
)
```

记录类型是匿名的，基于结构化匹配：

```glue
fun greet(user: (name: str, age: i32)) : str {
    "Hello, " + user.name
}
```

**无匿名元组**：记录必须有命名字段，`(str, i32)` 不存在。如果需要通用配对类型，使用：

```glue
type Pair<A, B> = Pair(first: A, second: B)
```

#### 2.5.3 递归类型

```glue
type List<T> =
    | Nil
    | Cons(T, List<T>)

type Tree<T> =
    | Leaf
    | Node(T, Tree<T>, Tree<T>)
```

#### 2.5.4 抽象类型（隐藏构造器）

```glue
pub type Handle = Handle(i32)
// 类型 Handle 对外可见，但构造器 Handle(i32) 是私有的
```

### 2.6 Pattern Matching

Pattern matching 是 ADT、Nullable 和 Throw 的核心操作，必须穷举检查：

```glue
fun describe(n: i32?) : str {
    match n {
        null => "nothing",
        x => "got " + str(x),
    }
}

fun area(shape: Shape) : f64 {
    match shape {
        Circle(r) => pi * r * r,
        Rectangle(w, h) => w * h,
        Triangle(a, b, c) => {
            val s = (a + b + c) / 2.0
            sqrt(s * (s - a) * (s - b) * (s - c))
        },
    }
}
```

支持嵌套模式、守卫条件、或模式：

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

### 2.7 Trait

Trait 定义行为接口，用组合代替继承。Trait 是 Glue 中唯一的接口抽象机制——既用于编译期参数化多态（Trait bound），也用于运行时多态（一等 Trait 值）。

#### 2.7.1 定义与实现

Trait 定义行为接口，类型通过在定义时声明实现的 trait 来获得这些行为：

```glue
trait Comparable {
    fun compare(self, other: Self): Ordering
}

// 在类型定义时实现 trait（必须有大括号）
type MyInt: Comparable = MyInt(value: i32) {
    fun compare(self, other: Self): Ordering {
        val a = self.value
        val b = other.value
        if a < b { Lt } else if a == b { Eq } else { Gt }
    }
}

// 实现多个 trait
type Point: (Show, Comparable) = Point(x: i32, y: i32) {
    fun show(self): str {
        "(" + str(self.x) + ", " + str(self.y) + ")"
    }
    
    fun compare(self, other: Self): Ordering {
        // 实现比较逻辑
        Eq
    }
}
```

**语法规则**：
- 类型实现 trait 时必须有大括号 `{ }`，即使使用默认实现也需要空大括号
- 单个 trait 可以省略括号：`type T: Trait = ...`
- 多个 trait 用括号和逗号：`type T: (Trait1, Trait2) = ...`
- 不支持为已定义的类型后续添加 trait 实现（必须在定义时一次性声明）

**运算符不可重载**：`+`、`==`、`<` 等运算符是内建的，只能用于内建数值类型。自定义类型需要使用命名方法（如 `add`、`compare`、`eq`）。

#### 2.7.2 Trait 组合

```glue
trait Ord<T>(Eq<T>, Comparable<T>) {
    fun lte(a: T, b: T) : bool {
        match compare(a, b) {
            Lt | Eq => true,
            Gt => false,
        }
    }
}
```

组合语义：
1. **方法继承**：子 Trait 自动拥有所有父 Trait 的方法
2. **自动派生**：实现子 Trait 的类型自动满足所有父 Trait 的约束
3. **冲突消解**：当多个父 Trait 有同名方法时，必须显式处理

冲突消解方式：

**委托（`=`）**：

```glue
trait Combined(Serializable, Debug) {
    fun to_string(self) : str = Serializable.to_string
}
```

**重命名**：

```glue
trait Combined(Serializable, Debug) {
    fun to_string(self) : str = Serializable.to_string
    fun debug_string(self) : str = Debug.to_string
}
```

**覆写（`override`）**：

```glue
trait Combined(Serializable, Debug) {
    override fun to_string(self) : str {
        "[" + Debug.to_string(self) + "]"
    }
}
```

#### 2.7.3 类型参数约束与类型特化

**类型参数约束**：要求类型参数实现特定 trait

```glue
// 函数的类型参数约束
fun max<T: Ord>(a: T, b: T): T {
    if lte(a, b) { b } else { a }
}

// 多个约束用 + 连接
fun debug_compare<T: Ord + Debug>(a: T, b: T): str {
    "Comparing " + a.debug() + " with " + b.debug()
}

// 类型定义的类型参数约束
type Wrapper<T: Clone>: Container = Wrapper(value: T) {
    fun clone_item(self): T {
        self.value.clone()
    }
}

// 实现 trait 时的类型参数约束
type Vec<T: Show>: Display = Vec(data: [T]) {
    fun display(self): str {
        "[" + self.data.map(|x| x.show()).join(", ") + "]"
    }
}
```

**类型特化约束**：限制类型参数为特定具体类型

```glue
// 只为 Vec<i32> 实现 IntOps
type Vec<T>: IntOps with T: i32 = Vec(data: [T]) {
    fun sum(self): i32 {
        var total = 0
        for item in self.data {
            total = total + item
        }
        total
    }
}

// 函数的类型特化
fun optimize<T>(x: T): T with T: i32 {
    // 只接受 i32 类型
    x * 2
}

// 混合使用：类型参数约束 + 类型特化
type SortedVec<T: Clone>: FastSort with T: i32 = SortedVec(data: [T]) {
    fun fast_sort(self) {
        // T 必须实现 Clone，且必须是 i32
    }
}
```

**约束语法总结**：
- `<T: Trait>` - 类型参数约束：T 必须实现 Trait
- `<T: Trait1 + Trait2>` - 多个 trait 约束
- `with T: ConcreteType` - 类型特化：T 必须是 ConcreteType
- 两种约束可以组合使用

#### 2.7.4 关联类型

关联类型允许 trait 声明与实现类型相关的类型成员：

```glue
trait Container {
    type Item                    // 关联类型
    fun empty(): Self
    fun insert(self, item: Item): Self
    fun len(self): i32
}

// 实现时指定关联类型
type Vec<T>: Container = Vec(data: [T], length: i32) {
    type Item = T                // 指定 Item 为 T
    
    fun empty(): Self {
        Vec([], 0)
    }
    
    fun insert(self, item: T): Self {
        // ...
        self
    }
    
    fun len(self): i32 {
        self.length
    }
}
```

**访问关联类型**：使用 `Self.Item` 语法访问当前类型的关联类型：

```glue
trait Mappable {
    type Item
    fun map<U>(self, f: Item -> U): Self
}
```

#### 2.7.5 Self 类型

`Self` 代表实现 trait 的当前类型，只能在 trait 和类型实现中使用：

```glue
trait Builder {
    fun new(): Self                      // 静态方法：返回 Self
    fun add(self, item: i32): Self       // 实例方法：返回 Self
    fun compare(self, other: Self): bool // Self 作为参数
}

type IntBuilder: Builder = IntBuilder(items: [i32]) {
    fun new(): Self {
        IntBuilder([])               // 使用具体类型名构造
    }
    
    fun add(self, item: i32): Self {
        IntBuilder(self.items ++ [item])
    }
    
    fun compare(self, other: Self): bool {
        self.items.len() == other.items.len()
    }
}
```

**Self 的语义规则**：
- ✅ `Self` 作为类型（返回类型、参数类型）
- ❌ `Self` 不能作为构造器（使用具体类型名）
- ✅ `Self.Item` 访问关联类型
- ❌ `Self` 不能出现在顶层函数中（只能在 trait/type 实现中）
- ✅ `self.method()` 调用实例方法（动态分派）
- ✅ `Self.method()` 调用静态方法（在 trait 内部）

**调用方式**：

```glue
trait Factory {
    fun create(): Self           // 静态方法
    fun process(self): Self      // 实例方法
    
    fun chain(self): Self {
        self.process()           // 实例方法调用
    }
}

// 外部调用
val builder = IntBuilder.new()   // 类型名::静态方法
val result = builder.add(42)     // 实例.方法
```

#### 2.7.6 名义化匹配

Trait 实现采用名义化匹配，通过在类型定义时显式声明实现的 trait 来建立关系。编译器会进行单态化，生成特化代码，实现零成本抽象。

#### 2.7.7 Orphan Instance 规则

由于类型只能在定义时声明实现的 trait，orphan 规则简化为：

**类型和 trait 必须至少有一个在当前模块定义**

| Trait 定义在 | Type 定义在 | 是否允许实现 |
|---|---|---|
| 当前模块 | 当前模块 | ✓ (在 type 定义中) |
| 其他模块 | 当前模块 | ✓ (在 type 定义中) |
| 当前模块 | 其他模块 | ✗ (无法修改外部类型) |
| 其他模块 | 其他模块 | ✗ (无法修改外部类型) |

**注意**：由于不支持后续为已定义类型添加 trait 实现，无法为标准库或第三方库的类型实现自定义 trait。需要通过 newtype 包装来实现：

```glue
// 标准库的 i32 无法直接实现自定义 trait
// 需要用 newtype 包装
type MyInt: Show = MyInt(value: i32) {
    fun show(self): str {
        str(self.value)
    }
}
```

#### 2.7.8 Overlapping Instances 禁止

不允许同一类型多次实现同一 trait。如果需要不同行为，使用 newtype 包装。

#### 2.7.9 Iterable 与 Iterator

```glue
trait Iterable {
    type Item
    fun iterator(self): Iterator
}

trait Iterator {
    type Item
    fun next(self): Item?
}

// 实现示例
type Vec<T>: Iterable = Vec(data: [T]) {
    type Item = T
    
    fun iterator(self): VecIterator<T> {
        VecIterator(self.data, 0)
    }
}

type VecIterator<T>: Iterator = VecIterator(data: [T], index: i32) {
    type Item = T
    
    fun next(self): T? {
        if self.index < self.data.len() {
            val item = self.data[self.index]
            self.index = self.index + 1
            Some(item)
        } else {
            None
        }
    }
}
```

`for item in collection` 要求 `collection` 的类型实现 `Iterable` trait。

### 2.8 函数类型

#### 2.8.1 默认柯里化

```glue
fun add(a: i32, b: i32) : i32 { a + b }

// 部分应用
val add5 = add(5)
add5(3)  // => 8
```

**禁止链式调用**：不允许 `f(a)(b)` 这种写法，必须将部分应用的结果绑定到变量后再调用。

```glue
// ✗ 禁止链式调用
add(5)(3)           // 语法错误
multiply(2)(3)(4)   // 语法错误

// ✓ 必须绑定到变量
val add5 = add(5)
add5(3)             // => 8

val step1 = multiply(2)
val step2 = step1(3)
step2(4)            // => 24
```

理由：链式调用 `f(a)(b)` 可读性差，容易与嵌套函数调用混淆。显式绑定让中间值和类型更清晰。

#### 2.8.2 函数类型语法

```
A -> B              函数：A 到 B
(A, B) -> C         多参数（语法糖，实际是柯里化）
A -> Throw<B, E>    可能抛错的函数
```

多参数函数类型 `(A, B) -> C` 在类型位置由 `(` ... `)` 后紧跟 `->` 与记录类型 `(name: T, ...)`
区分。它解析为接受 N 个参数的函数类型，可接受同元数的 lambda（`(a, b) => ...`）或命名函数
作实参——这是高阶库函数（`map`/`filter`/`fold`）形参注解的常用形式。

### 2.9 变异性 (Variance)

编译器自动推导每个类型参数的变异性：

| 位置 | 变异性 |
|---|---|
| 构造器参数（产出值） | 协变 |
| 函数返回值 | 协变 |
| 函数参数（消费值） | 逆变 |
| 同时出现在协变和逆变位置 | 不变 |
| Nullable `T?` | 协变 |
| Throw `Throw<T, E>` | T 协变，E 协变 |

### 2.10 类型推断

Glue 采用 Hindley-Milner 类型推断，大多数场景下无需显式标注类型。

```glue
fun add(a, b) { a + b }
// 编译器推断：add : i32 -> i32 -> i32
```

类型标注在以下场景必须或建议提供：
- 顶层函数签名（建议）
- 模块公开 API（建议）
- 多态递归函数（必须）
- 存在歧义时（必须）

### 2.11 Higher-Kinded Types (HKT)

#### 2.11.1 Kind 系统

```
Kind        含义             示例
*           具体类型         i32, str, bool
* -> *      一阶类型构造器   List, Vec, Tree
* -> * -> * 二阶类型构造器   Map, Throw
```

### 2.12 子类型关系

Glue 使用三种子类型关系：

#### 2.12.1 记录宽度子类型

字段更多的记录是字段更少的记录的子类型：

```
(name: str, age: i32)  <:  (name: str)
```

#### 2.12.2 Trait 结构化子类型

方法更多的模块是方法更少的 Trait 的子类型。

```
{ get, put, delete, list }  <:  { get, put }
```

#### 2.12.3 Error 子类型

自定义错误类型是 `Error` 的子类型。

```
FileError <: Error
NetworkError <: Error
```

### 2.13 GADT

GADT 允许 ADT 的构造器返回不同的类型参数：

```glue
type Expr<T> =
    | IntLit(i32)                       : Expr<i32>
    | BoolLit(bool)                     : Expr<bool>
    | Add(Expr<i32>, Expr<i32>)         : Expr<i32>
    | If(Expr<bool>, Expr<T>, Expr<T>)  : Expr<T>
```

匹配 GADT 时，编译器通过类型细化推导局部类型等式：

```glue
fun eval<T>(expr: Expr<T>) : T {
    match expr {
        IntLit(n) => n,                      // T ~ i32
        BoolLit(b) => b,                     // T ~ bool
        Add(a, b) => eval(a) + eval(b),      // T ~ i32
        If(cond, then, else) =>
            if eval(cond) { eval(then) } else { eval(else) },
    }
}
```

GADT match 分支中可能需要显式类型标注。

### 2.14 Type Alias 与 Newtype

```glue
// Type Alias ——不创建新类型
type IntList = List<i32>
type Name = str

// Newtype ——创建新类型，运行时零开销
type UserId = UserId(i32)
type Celsius = Celsius(f64)
```

### 2.15 类型转换

显式 `Type(value)` 语法，无隐式转换。

**widening（低位转高位）**：始终合法：

```glue
val x: i8 = 42
val y: i16 = i16(x)     // ✓
val z: i32 = i32(y)     // ✓
val f: f64 = f64(z)     // ✓
```

合法路径：
- `i8 → i16 → i32 → i64 → i128`
- `u8 → u16 → u32 → u64 → u128`
- `i8 → f32 → f64`，`i16 → f32 → f64`，`i32 → f64`
- `u8 → f32 → f64`，`u16 → f32 → f64`，`u32 → f64`

**narrowing（高位转低位）**：运行时检查，值超出范围则 panic。

```glue
val big: i64 = 42
val small: i32 = i32(big)     // ✓ 42 在 i32 范围内
val huge: i64 = 9999999999
val overflow: i32 = i32(huge) // ✗ panic: value does not fit in i32

val neg: i32 = -1
val unsign: u32 = u32(neg)    // ✗ panic: value -1 does not fit in u32
```

**`str()` 类型转换**：`str()` 是内建类型转换函数，将任意值转为字符串表示，与 `i32()`、`f64()` 同类。

```glue
str(42)          // "42"
str(3.14)        // "3.14"
str(true)        // "true"
str('a')         // "a"
```

`str()` 也是字符串插值 `{expr}` 的底层机制——插值时自动调用 `str(expr)`。

**`type()` 运行时类型名**：`type()` 是内建函数，返回任意值的运行时类型名（`str`）。签名为 `(Any) -> str`。

```glue
type(42)            // "i8"   —— 无标注整数取最小类型（见 §6.12）
type(42i32)         // "i32"  —— 后缀
val n: i64 = 42
type(n)             // "i64"  —— 标注
type("hello")       // "str"
type(true)          // "bool"
type('a')           // "char"
type([1, 2, 3])     // "array"
type((x: 1, y: 2))  // "record"
```

对用户定义类型，返回其类型名；对 `Ok`/`Error`/`throw` 值，返回 `"Throw"`；对函数值（闭包 / 内建 / 部分应用），返回 `"function"`。

```glue
type Color = | Red | Green | Blue
type UserId = UserId(i32)

type(Red)           // "Color"
type(UserId(7))     // "UserId"
type(Ok(5))         // "Throw"
type(fun(x) { x })  // "function"
```

### 2.16 命名规则

**同层级禁止重复定义**：在同一作用域内，`val`、`var`、`fun`、`type`、`trait` 不允许重复定义同名标识符。

```glue
val x = 1
val x = 2       // ✗ duplicate definition: 'x' is already defined in this scope

fun f() = 1
fun f() = 2     // ✗ duplicate definition: 'f' is already defined in this scope

type A = | Foo
type B = | Foo  // ✗ duplicate definition: 'Foo' is already defined
```

**嵌套作用域允许遮蔽**：内层作用域可以定义与外层同名的 `val`/`var`。

```glue
val x = 1
{
    val x = 2   // ✓ 内层遮蔽外层
    println(x)  // 2
}
println(x)      // 1
```

**`var` 允许重新赋值但不允许重复定义**：

```glue
var x = 1
x = 2           // ✓ 重新赋值
var x = 3       // ✗ duplicate definition: 'x' is already defined in this scope
```

**内建名称禁止重新定义**：以下内建函数和类型转换函数不允许被用户定义遮蔽。

| 类别 | 名称 |
|------|------|
| I/O | `println`, `print`, `eprintln`, `eprint`, `scanln`, `scan` |
| 工具 | `Panic`, `eq`, `type` |
| 类型转换 | `str`, `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128`, `f32`, `f64` |
| 错误处理 | `Error`, `Ok` |

```glue
val println = 42     // ✗ cannot redefine built-in 'println'
fun eq(a, b) = a     // ✗ cannot redefine built-in 'eq'
type Error = ...     // ✗ cannot redefine built-in 'Error'
```

**大小写敏感**：`eq` 和 `Eq` 是不同的标识符。`eq` 是内建函数，`Eq` 可以作为构造器名：

```glue
type Ordering = | Lt | Eq | Gt   // ✓ 构造器 Eq 与内建函数 eq 不冲突
val eq = Eq                       // ✗ 变量名 eq 与内建函数冲突
val eq_val = Eq                   // ✓
```

### 2.17 迭代器

```glue
trait Iterable<T> {
    fun iterator(self) : Iterator<T>
}

trait Iterator<T> {
    fun next(self) : T?
}
```

for 循环脱糖：

```glue
// for item in list { body }
// 脱糖为：
val iter = list.iterator()
loop {
    match iter.next() {
        null => break,
        item => body,
    }
}
```

内建 Iterable 实现：

| 类型 | 迭代产生 |
|---|---|
| `List<T>`（标准库） | 列表元素 |
| `T[]` | 数组元素 |
| `str` | `char` |
| `start..end` | 范围值，T 由推断决定 |

### 2.18 错误处理策略

| 场景 | 推荐机制 | 理由 |
|---|---|---|
| 值可能不存在 | `T?` | 最轻量，语义清晰 |
| 操作可能失败，需要错误信息 | `Throw<T, E>` | 携带错误详情，`?` 传播 |
| 操作可能失败，错误类型明确 | `Throw<T, SpecificError>` | 穷举匹配，类型安全 |
| 聚合多种错误 | `Throw<T, Error>` | 统一处理，catch-all |
| 并发任务中的错误 | Channel 传递 `Throw<T, E>` | CSP 模型 |

### 2.19 I/O 内建函数

#### 输出

| 函数 | 签名 | 说明 |
|------|------|------|
| `println` | `Any -> Unit` | 输出值 + 换行到 stdout |
| `print` | `Any -> Unit` | 输出值到 stdout（无换行） |
| `eprintln` | `Any -> Unit` | 输出值 + 换行到 stderr |
| `eprint` | `Any -> Unit` | 输出值到 stderr（无换行） |

#### 输入

| 函数 | 签名 | 说明 |
|------|------|------|
| `scanln` | `() -> str?` | 从 stdin 读取一行（不含 `\n`），EOF 返回 `null` |
| `scan` | `() -> str?` | 从 stdin 读取一个空白分隔的 token，EOF 返回 `null` |

**错误处理**：I/O 错误（如 stdin 不可用）触发 panic，不使用 Throw。解析由用户显式完成：

```glue
val line = scanln()          // "42"
val n = i32(line ?? "0")     // 用户负责类型转换
val t = scan()               // 读取一个空白分隔的 token
```

---

## 3. 并行与并发模型

### 3.1 概述

Glue 采用 **CSP (通信顺序进程)** 作为并发模型。
- 通过 channel 通信，不通过共享内存通信
- `spawn` 创建协程，返回 `Spawn<T>`，`await()` 阻塞等待结果
- `Atomic<T>` 提供跨协程共享原子状态（替代 `Arc<T>`）
- **没有 async/await 关键字**
- 运行时保证并行安全
- 协程运行时基于 **Zio 库**（栈式协程 + 多线程调度 + io_uring/IOCP/kqueue）

### 3.2 spawn

`spawn` 创建协程，立即返回 `Spawn<T>`，不阻塞当前代码。`spawn` 是表达式，可以链式调用。

```glue
var s: Spawn<i32> = spawn { fetch_url("http://example.com") }
do_other_work()
val result = s.await()

// 链式调用：spawn + await 一体
val result2 = spawn { compute() }.await()
```

#### 3.2.1 spawn 捕获语义

- **普通闭包**：引用捕获，共享外部作用域
- **spawn 闭包**：深拷贝捕获，完全隔离（`Atomic<T>` 例外，浅拷贝）

```glue
var count = 0

// 普通闭包——引用捕获
val f = fun() { count = count + 1 }  // 共享外部 count
f()   // count 变为 1

// spawn 闭包——深拷贝捕获
spawn {
    count = count + 1   // 修改的是副本，不影响外部 count
}
```

#### 3.2.2 Atomic<T> 浅拷贝例外

`Atomic<T>` 在 spawn 捕获时浅拷贝（共享底层内存），这是跨协程共享状态的唯一方式。

```glue
var counter: Atomic<i32> = atomic 0
var c = counter  // 浅拷贝 Atomic 引用
var s = spawn { c += 1 }  // 浅拷贝，共享 counter
s.await()
println(counter)  // 1
```

### 3.3 Spawn\<T\>

`spawn` 返回 `Spawn<T>`，**线性类型**——必须被 `await()` 或 `cancel()` 消费，未被消费的 Spawn 离开作用域时编译错误。

#### 3.3.1 Spawn 方法

| 方法 | 消费 Spawn | 阻塞 | 返回类型 | 说明 |
|---|---|---|---|---|
| `await()` | 是 | 是 | `T` | 等待完成取结果 |
| `cancel()` | 是 | 否 | `()` | 取消协程，触发 defer 清理 |
| `status()` | 否 | 否 | `SpawnStatus` | 查询状态 |
| `result()` | 否 | 否 | `T?` | 非阻塞取结果，未完成返回 `None` |

```glue
var s = spawn { compute() }

// await：消费 Spawn，等待结果
val r = s.await()

// cancel：消费 Spawn，取消协程
s.cancel()

// status：查询状态（不消费）
match s.status() {
    Pending   => println("waiting in queue")
    Running   => println("working...")
    Completed => println("done")
    Cancelled => println("was cancelled")
    Failed    => println("crashed")
}

// result：非阻塞取结果（不消费）
val maybe: i32? = s.result()
```

#### 3.3.2 SpawnStatus 枚举

```glue
type SpawnStatus =
    | Pending    // 调度器队列中，尚未开始
    | Running    // 正在执行
    | Completed  // 成功完成
    | Cancelled  // 被取消
    | Failed     // 协程 panic/出错
```

#### 3.3.3 线性类型规则

Spawn 离开作用域时若未被消费 → **编译错误**：

```glue
// ✗ 编译错误：Spawn 未被消费
{
    var s = spawn { compute() }
} // Error: Spawn<i32> must be consumed (await or cancel)

// ✓ 显式消费
{
    var s = spawn { compute() }
    s.await()
}

// ✓ defer 消费
{
    var s = spawn { compute() }
    defer s.await()
}
```

#### 3.3.4 Spawn 与 defer

`defer` 与 Spawn 的组合非常自然，解决线性类型的消费要求：

```glue
// defer await：作用域结束自动等待
fun parallel_fetch(): str {
    var s1 = spawn { fetch("a") }
    var s2 = spawn { fetch("b") }
    defer s1.await()
    defer s2.await()
    do_other_work()
    // 作用域结束时 LIFO：先 s2.await()，再 s1.await()
}

// defer cancel：清理模式
fun with_timeout(): i32 {
    var s = spawn { long_compute() }
    defer s.cancel()  // 作用域结束时若未消费则取消
    if something_wrong { return 0 }
    s.await()         // await 消费后，cancel 不再执行
}

// defer spawn：延迟创建协程
fun process(): () {
    defer spawn { cleanup() }  // 作用域结束时启动清理协程
    do_work()
}
```

### 3.4 Atomic\<T\>

`Atomic<T>` 是跨协程共享原子状态的唯一方式，替代 `Arc<T>`。操作与普通变量一致，编译器自动翻译为原子指令。

#### 3.4.1 创建与使用

```glue
var counter: Atomic<i32> = atomic 0
```

`atomic expr` 在堆上创建原子值，返回 `Atomic<T>` 引用。

#### 3.4.2 透明操作

`Atomic<T>` 的操作与普通变量语法一致，编译器自动翻译为原子指令：

| 用户写的 | 编译器生成 | 语义 |
|---|---|---|
| `val x = counter` | `atomic_load(&counter)` | 原子读 |
| `counter = 42` | `atomic_store(&counter, 42)` | 原子写 |
| `counter += 1` | `atomic_fetch_add(&counter, 1)` | 原子 RMW |
| `counter -= 1` | `atomic_fetch_sub(&counter, 1)` | 原子 RMW |
| `counter *= 2` | `atomic_fetch_mul(&counter, 2)` | 原子 RMW |
| `counter &= 0xFF` | `atomic_fetch_and(&counter, 0xFF)` | 原子 RMW |
| `counter \|= 0x01` | `atomic_fetch_or(&counter, 0x01)` | 原子 RMW |
| `counter = counter + 1` | CAS 循环 | 原子 RMW（回退） |
| `if counter > 10` | `atomic_load(&counter) > 10` | 原子读 + 比较 |

**复合赋值 vs 赋值表达式**：
- `counter += 1` → 直接映射到 `fetch_add`，**单条原子指令**，最高效
- `counter = counter + 1` → 编译器生成 **CAS 循环**（load → compute → CAS，失败重试），正确但稍慢
- 编译器可优化：若检测到 `counter = counter OP const`，自动转为 `counter OP= const`

#### 3.4.3 显式高级操作

```glue
counter.cas(expected, new)    // CAS，返回 bool
counter.swap(new_value)       // 原子交换，返回旧值
```

#### 3.4.4 Atomic 语义

- **引用语义**：`Atomic<T>` 是引用类型，`atomic expr` 创建堆上原子值
- **spawn 浅拷贝**：spawn 捕获 `Atomic<T>` 时浅拷贝（共享同一底层内存）
- **T 限制为原始类型**：i8..i128, u8..u128, f32, f64, bool, char
- **引用计数**：内部引用计数，归零时自动释放
- **唯一共享机制**：只有 `Atomic<T>` 可以跨 spawn 共享可变状态
- **非 Atomic 变量**：spawn 捕获时深拷贝

#### 3.4.5 完整示例

```glue
// 并发计数器
var counter: Atomic<i32> = atomic 0

// 启动 10 个协程各自加 1
var spawns: List<Spawn<()>> = []
for i in 0..10 {
    val c = counter  // 浅拷贝 Atomic 引用
    spawns = spawns ++ [spawn { c += 1 }]
}

// 等待所有完成
for s in spawns { s.await() }

println(counter)  // 10，无需任何显式原子操作
```

### 3.5 Channel

#### 3.5.1 创建与使用

```glue
val ch = channel<i32>(0)       // 无缓冲（同步）
val ch = channel<i32>(10)      // 缓冲区大小 10

ch.send(42)                    // 发送
val value = ch.recv()          // 接收
```

#### 3.5.2 方向类型

```glue
fun producer(ch: Sender<i32>) : Unit {
    ch.send(1)
}

fun consumer(ch: Receiver<i32>) : Unit {
    val v = ch.recv()
}

val ch = channel<i32>(0)
spawn producer(ch.sender)
spawn consumer(ch.receiver)
```

#### 3.5.3 Select

```glue
select {
    ch1.recv() => value => handle_a(value),
    ch2.recv() => value => handle_b(value),
    timeout(1000) => handle_timeout(),
}
```

#### 3.5.4 Channel 关闭

- **仅 Sender 可关闭**
- 关闭后缓冲数据仍可读取
- 关闭后 send 返回 `SendError`
- 关闭后 recv 缓冲区耗尽返回 `null`

```glue
ch.close()

match ch.send(42) {
    Ok(()) => println("sent"),
    Error(e) => println("channel closed"),
}

loop {
    match ch.recv() {
        null => break,      // 通道已关闭且缓冲区为空
        value => process(value),
    }
}

// for 循环自动处理关闭
for value in ch {
    process(value)
}
```

`Receiver<T>` 实现了 `Iterable<T>`，通道关闭后循环自动结束。

### 3.6 并行安全保证

#### 3.6.1 值语义 + 深拷贝

1. **默认值语义**：传参时拷贝值，不共享引用
2. **深拷贝隔离**：跨协程传递时深拷贝，确保无共享可变状态
3. **无共享可变状态**：两个协程不可能同时持有同一块可变内存的引用（`Atomic<T>` 例外）

#### 3.6.2 Per-Heap GC 隔离

每个协程拥有独立的 GC heap。
- 两个协程不可能同时访问同一块堆内存
- 跨协程传递数据时，数据被深拷贝到目标 heap
- GC 回收不需要全局暂停

#### 3.6.3 跨协程共享：Atomic\<T\>

`Atomic<T>` 是跨协程共享状态的唯一机制，替代 `Arc<T>`。

```glue
var counter: Atomic<i32> = atomic 0

var s1 = spawn { counter += 1 }  // 浅拷贝，共享 counter
var s2 = spawn { counter += 1 }  // 浅拷贝，共享 counter
s1.await()
s2.await()
println(counter)  // 2
```

`Atomic<T>` 保证：
- **操作原子性**——编译器将所有读写翻译为原子指令，无数据竞争
- **引用计数自动管理**——跨协程传递时原子增减引用计数，归零时释放
- **spawn 捕获时浅拷贝**——只复制引用，不复制底层值
- **T 限制为原始类型**——避免复合类型的原子性问题

**需要更复杂的共享状态时**，使用 spawn + channel 手动实现——启动一个协程持有状态，其他协程通过 channel 发送请求：

```glue
val ch = channel<Command>(10)

// 状态协程
spawn {
    var state = 0
    loop {
        match ch.recv() {
            Inc => { state = state + 1 }
            Get(reply) => { reply.send(state) }
        }
    }
}
```

这是 CSP 的本意——通过通信共享，而非通过共享内存通信。

#### 3.6.4 并行安全总结

| 机制 | 保证 | 适用场景 |
|---|---|---|
| 值语义 + 深拷贝 | 无共享引用 | 默认，覆盖绝大多数场景 |
| Per-Heap GC | 无共享堆内存 | 所有并发代码 |
| Channel | 安全通信 | 协程间数据传递 |
| Atomic\<T\> | 原子操作共享 | 跨协程共享简单可变状态 |

### 3.7 调度模型

Glue 采用 **M:N 调度（协程）**，少量 OS 线程上运行大量轻量级协程。

运行时基于 **Zio 库**：
- 栈式协程（fibers），用户态上下文切换
- 多线程调度，协程可跨线程迁移
- 支持 Linux (io_uring/epoll), Windows (IOCP), macOS (kqueue)
- 可增长栈（通过虚拟内存预留自动扩展）
- Work-stealing 调度器：每个 worker 线程有本地任务队列，空闲 worker 从其他 worker 偷任务
- `Spawn<T>.await()` 挂起当前协程，让出执行权

---

## 4. 模块系统

### 4.0 项目与工具链

Glue 以**项目**为单位组织代码（类 Cargo/npm）。项目根由清单文件 `glue.toml` 标识，源码放在 `src/` 下，入口约定为 `src/Main.glue` 的 `fun main()`。

**项目布局：**

```
myapp/
├── glue.toml          // 项目清单（项目根标识）
└── src/
    ├── Main.glue      // 入口模块，含 fun main()
    └── ...            // 其余模块
```

**清单 `glue.toml`**（极简 TOML 子集）：

```toml
name = "myapp"
version = "0.1.0"
entry = "src/Main.glue"   # 可选，缺省 src/Main.glue
```

`entry` 可指向非标准布局的入口（如根目录的 `Main.glue`）。

**CLI 命令：**

| 命令 | 说明 |
|---|---|
| `glue init [name]` | 脚手架新项目（在 `./name` 或当前目录生成 `glue.toml` + `src/Main.glue`）；目标须为空目录 |
| `glue run` | 编译并运行当前项目（从 `fun main()` 启动） |
| `glue debug` | 诊断模式运行（内存检查 + 运行时错误位置追踪） |

`run`/`debug` 从当前目录向上查找 `glue.toml` 定位项目根。编译错误（类型/解析）、运行时 panic、缺少 `fun main()`、非项目目录等以非零退出码结束；正常结束退出码为 0。

### 4.1 概述

1. **文件即模块**：每个 `.glue` 文件是一个模块
2. **`pack.glue`**：目录模块的入口文件
3. **一等 Trait 值**：Trait 可以作为运行时值传递

### 4.2 文件到模块的映射

- `src/` 根目录下的 `.glue` 文件直接参与编译
- 子目录：有 `pack.glue` 则目录成为模块；无 `pack.glue` 则整个目录被忽略
- 文件未在 `pack.glue` 中声明 → 不参与编译

```
src/
├── Main.glue                          // 根目录
├── Collections/
│   ├── pack.glue                      // 目录入口
│   ├── Map.glue                       // 已声明 ✓
│   └── Wip/
│       └── Vector.glue                // 无 pack.glue
└── Temp.glue                          // 根目录
```

### 4.3 `pack.glue` 的内容

```glue
pub pack Map            // 公开子模块
pub pack Set            // 公开子模块
pack Internal           // 私有子模块

pub type Pair<K, V> = Pair(K, V)    // 模块自身定义
```

`pub pack` 的子模块公开成员自动合并到父模块命名空间。

### 4.4 可见性

Glue 采用**默认私有**的可见性模型（类似 Rust）：所有声明默认仅在当前模块内可见，跨模块访问必须显式标注 `pub`。

#### 4.4.1 可见性规则

| 声明 | 默认可见性 | 公开方式 |
|---|---|---|
| `fun` | 私有 | `pub fun` |
| `val` / `var` | 私有 | `pub val` / `pub var` |
| `type` / ADT | 私有 | `pub type` |
| ADT 构造器 | 私有 | 抽象类型（构造器不对外暴露） |
| `trait` | 私有 | `pub trait` |
| trait 方法 | 私有 | `pub fun` in trait |
| trait 关联类型 | 私有 | `pub type` in trait |
| `type` 实现方法 | 私有 | `pub fun` in type 实现 |
| `pack` | 私有 | `pub pack` |

#### 4.4.2 模块内自由访问

同一模块（文件）内的所有声明互相可见，不受 `pub` 限制。

```glue
// Utils.glue
fun helper() : i32 { 42 }       // 私有，但同模块可调用
pub fun api() : i32 { helper() } // 公开，跨模块可调用
```

#### 4.4.3 跨模块访问

跨模块（`import` 导入）只能访问 `pub` 声明。

```glue
// Main.glue
import Utils.{api}     // ✓ api 是 pub
import Utils.{helper}  // ✗ 编译错误：helper 是私有的
```

#### 4.4.4 抽象类型

`pub type` 公开类型名但隐藏构造器，实现抽象数据类型：

```glue
pub type Handle = Handle(i32)
// 类型 Handle 对外可见，但构造器 Handle(i32) 是私有的
// 外部只能通过模块提供的 pub fun 创建
```

#### 4.4.5 `import` 导入的可见性

`import` 导入的符号在当前模块中默认私有（即导入后不会自动再导出）。

```glue
import Collections.{Map}   // Map 在当前模块中是私有的
pub import Collections.{Map} // Map 在当前模块中是公开的，可被再导出
```

### 4.5 `import` 导入

```glue
import Collections.{Map, insert, empty}       // 选择性导入
import Collections.Map                         // 导入整个模块
import Collections.{Map as CMap, insert as ins}  // 别名
import Collections.*                           // 导入所有公开成员
```

**导入语法**：
- `import path.{item1, item2}` - 选择性导入
- `import path.item` - 导入单个项
- `import path.{item as alias}` - 导入并重命名
- `import path.*` - 导入所有公开成员（谨慎使用，可能导致命名冲突）
- `pub import ...` - 重新导出（使导入的符号在当前模块也公开）

#### 4.5.1 模块循环依赖

两个模块互相 `import` 会触发编译错误：

```glue
// A.glue
import B.{helper}     // ✗ 编译错误：检测到循环依赖 A ↔ B ↔ A
```

依赖关系必须是 DAG。解决方案：提取共享部分到第三个模块。

### 4.6 一等 Trait 值

#### 4.6.1 Trait 作为类型

```glue
trait Store {
    type Key
    type Value
    fun get(key: Key) : Throw<Value?, Error>
    fun put(key: Key, value: Value) : Unit
}
```

#### 4.6.2 文件模块作为 Trait 值

```glue
fun run(s: Store) : Unit {
    s.put("hello", "world")
}

fun main() {
    run(Store.Memory)    // 文件模块自动转换为 Trait 值
}
```

#### 4.6.3 内联 Trait 值

```glue
val logger : Logger = trait {
    fun log(msg: str) : Unit { println(msg) }
}
```

### 4.7 一等 Trait 值的运行时表示

vtable 指针 + data 载荷的胖指针。

| VTable 字段 | 用途 |
|---|---|
| `size` | 数据载荷大小 |
| `align` | 数据对齐要求 |
| `drop` | 析构函数指针 |
| `send` | 深拷贝函数指针 |
| `fn_0..fn_n` | Trait 接口函数指针 |

跨 Heap 传递时：vtable 共享（全局只读），data 深拷贝。

### 4.8 最小可运行项目

```
src/
└── Main.glue
```

```glue
fun main() {
    println("Hello, Glue!")
}
```

### 4.9 内嵌标准库

标准库用 Glue 自身编写（文档 D67：核心语言只提供 `T[]`，集合等属 std 库），通过
`@embedFile` 编进解释器二进制。`import <Name>` 加载模块时，**项目内同名文件优先**（允许用户
覆盖），找不到才回退到内嵌表——因此标准库零安装、与运行目录无关。

源码位于 `src/stdlib/*.glue`，登记在 `src/stdlib.zig` 的内嵌表中。首批模块：

- **`List`** — 函数式链表 `List<T> = | Nil | Cons(T, List<T>)`，配套
  `length`/`map`/`filter`/`foldl`/`foldr`/`reverse`/`append`/`elem`/`from_array`
  等算子。`pub type` 的构造器（`Nil`/`Cons`）随 `import List` 一并导入到值命名空间。
  本模块还用类型参数约束（§2.7.3）提供对 `List<T>` 的 `Show` 实现（当 `T: Show` 时），
  故元素可 `Show` 的链表自身也可 `show()`。
- **`Compare`** — 类型类 trait `Eq` / `Ord` / `Show`，及对内建类型的实现：
  `Show`/`Eq`/`Ord` 覆盖 `i64`（所有整数宽度）、`f64`（所有浮点宽度）、`str`、`char`，
  `Show`/`Eq` 另覆盖 `bool`。容器类型可借类型参数约束（§2.7.3）扩展。

---

## 5. 运行时与垃圾回收

### 5.1 Per-Heap 隔离 GC

每个协程拥有独立的 GC heap。

核心优势：
- **零全局暂停**：每个 heap 独立回收
- **天然防数据竞争**：两个协程不可能同时访问同一块内存
- **高效回收**：函数式风格产生大量的短命对象，隔离 GC 各自独立回收

GC 算法：**分代式复制收集器**（新生代 + 老生代 + 大对象区）

### 5.2 跨 Heap 传递规则

| 数据类型 | 跨 Heap 传递方式 |
|---|---|
| 基础类型 | 值拷贝（栈上） |
| 不可变数据结构 | 深拷贝到目标 heap |
| 一等 Trait 值 | vtable 共享 + data 深拷贝 |
| Channel | 调度器 heap 中，两端只持有引用 |
| 函数/闭包 | 深拷贝捕获的环境 |
| Atomic<T> | 浅拷贝（原子增加引用计数） |

### 5.3 Work-Stealing 调度器

- 每个 worker 线程有本地任务队列
- 空闲 worker 从其他 worker 偷任务
- Worker 数量默认等于 CPU 核心数

### 5.4 运行时层次

```
┌─────────────────────────────────────────┐
│             用户代码                      │
├─────────────────────────────────────────┤
│       并行原语 (spawn, channel, select)  │
├─────────────────────────────────────────┤
│       一等 Trait 值运行时 (vtable 分派)      │
├─────────────────────────────────────────┤
│       Work-Stealing 调度器              │
├─────────────────────────────────────────┤
│       Per-Heap GC                       │
├─────────────────────────────────────────┤
│       OS 线程池                         │
└─────────────────────────────────────────┘
```

---

## 6. 语法设计

### 6.1 概述

Glue 采用花括号 C 族函数式语法。

### 6.2 关键字

```
fun type trait override pack pub import with as
val var
match if else
spawn channel select atomic
loop for in while break continue return
true false null
throw lazy defer
```

### 6.3 函数定义

```glue
fun add(a: i32, b: i32) : i32 { a + b }
fun multiply(a: i32) : (i32 -> i32) { fun(b) { a * b } }

// 返回 Throw
fun read_file(path: str) : Throw<str, FileError> {
    if !found { throw FileError("not found") }
    "content"
}

// ✓ Trait Bound
fun max<T>(a: T, b: T) : T with Ord<T> {
    if lte(a, b) { b } else { a }
}

// var 参数
fun process(data: var List<i32>) {
    data.push(42)       // ✓ var 参数可修改
}

// Lambda
fun(x) { x + 1 }
(x) => x + 1
```

**函数参数默认 val**，需要修改时显式标注 `var`。

### 6.4 变量绑定

```glue
val x = 42              // 不可变，自动推断为 i8
var count: i32 = 0      // 可变，显式 i32（累加器应标注类型）
count = count + 1

val name: str? = get_name()
val len = name?.len() ?? 0
```

### 6.5 类型定义

```glue
// 枚举
type Shape =
    | Circle(radius: f64)
    | Rectangle(width: f64, height: f64)

// 记录
type Config = (
    host: str,
    port: i32,
)

// GADT
type Expr<T> =
    | IntLit(i32) : Expr<i32>
    | Add(Expr<i32>, Expr<i32>) : Expr<i32>

// Type Alias
type IntList = List<i32>

// Newtype
type UserId = UserId(i32)

// 自定义错误
type FileError: Error = FileError(msg: str) {
    override fun prefix(self): str { "file error" }
}
```

### 6.6 错误处理

```glue
// ? 传播 Throw
fun read_config() : Throw<Config, Error> {
    val content = read_file("config.json")?
    val config = parse_json(content)?
    config
}

// ? 传播 Nullable
fun greet() : str? {
    val name = get_name()?
    "Hello, " + name
}

// 模式匹配
match read_file("config.json") {
    Ok(content) => process(content),
    Error(e) => println("file: " + e.message),
}
```

### 6.7 控制流

```glue
// if/else（表达式）
val desc = if x > 0 { "positive" } else { "non-positive" }

// loop
loop {
    val input = read_line()
    if input == "quit" { break }
    process(input)
}

// for（需要 Iterable<T>）
for i in 0..100 { println(i) }

// while
while condition() { do_work() }

// return（可选，类似 Rust）
// 块最后一个表达式自动返回，无需 return
fun double(x: i32) : i32 { x * 2 }

// return 用于提前返回
fun find(items: List<i32>, target: i32) : i32? {
    for item in items {
        if item == target { return item }
    }
    null    // 未找到，返回 null
}
```

#### 6.7.1 尾调用优化

Glue 保证尾调用优化 (TCO)。尾递归不会导致栈溢出：

```glue
fun sum(n: i32, acc: i32) : i32 {
    if n == 0 { acc } else { sum(n - 1, acc + n) }
}
```

相互递归也支持 TCO。

### 6.8 defer

`defer` 注册延迟执行的操作，在当前作用域退出时以 LIFO 顺序执行。

```glue
fun process_file(path: str) : Throw<Unit, FileError> {
    val file = open_file(path)?
    defer close_file(file)

    val content = read_content(file)?
    process(content)
}
```

执行时机：正常返回 / throw / panic 时均执行。

### 6.9 Panic 与断言

Panic 不可捕获。三级断言：

```glue
assert(x > 0)              // 开发期检查
precondition(index < len)   // 接口契约
fatal("unreachable")       // 不可达代码
```

Panic 协程级隔离：一个协程的 panic 不影响其他协程。

### 6.10 惰性求值

```glue
val lazy_val: Lazy<i32> = lazy expensive_computation()
```

`Lazy<T>` 延迟求值，首次访问时计算并缓存。

### 6.11 运算符

#### 算术运算符

```
+    -    *    /    %
```

`+` 在字符串上下文表示拼接（`"a" + "b"`），在数值上下文表示加法。

#### 集合运算符

```
++   数组/列表拼接   [1, 2] ++ [3, 4]  →  [1, 2, 3, 4]
```

`++` 把两个**同元素类型**的数组首尾相接，返回一个**新的动态数组**（元素深拷贝，原数组不变）。两侧元素类型须一致（`[T] ++ [T] → [T]`）。常用于在循环中追加：

```glue
var acc = []
for i in 1..=3 {
    acc = acc ++ [i]    // 追加单元素数组
}
// acc == [1, 2, 3]
```

> 注：`++` 仅用于数组拼接，不是自增运算符——Glue 没有 `x++` / `++x` 自增语法（参考 Zig，自增请用 `x += 1`）。

#### 比较运算符

```
==   !=   <    >    <=   >=
```

**`==` 引用相等**：基础类型值相等，ADT 比较内存地址。结构相等用 `eq` 方法。

#### 逻辑运算符

```
&&   ||   !
```

#### Nullable 运算符

```
?.   ??   !    ?
```

#### 范围运算符

```
..   开区间（不包含上界）   0..10
..=  闭区间（包含上界）     0..=9
```

#### 运算符优先级（从高到低）

```
1.  ?.  .   函数调用
2.  ?   !
3.  !   -（前缀）
4.  *  /  %
5.  +  -  ++
6.  ..  ..=
7.  <  >  <=  >=
8.  ==  !=
9.  &&
10. ||
11. ??
```

所有运算符不可重载。

### 6.12 字面量

```glue
42              // 无后缀、无标注：推断为能容纳该值的最小类型（此处 i8）
42i32           // 显式 i32
42u64           // 显式 u64
3.14            // 无后缀、无标注：推断为能精确往返表示该值的最小浮点类型（此处 f128）
3.14f32         // 显式 f32
0xFF            // 十六进制
0o77            // 八进制
0b1010          // 二进制
1_000_000       // 下划线分隔
'a'                     // char
"hello"                 // str
"hello {name}"          // 字符串插值
true  false  null

[1, 2, 3]                      // i32[]
(name: "Alice", age: 30)       // 记录
```

整数字面量的类型按如下优先级确定：

1. **显式后缀**最高优先：`42i32`、`255u8` 直接采用后缀类型。
2. **显式类型标注**次之：`val x: i64 = 5` 中字面量按标注类型 `i64` 处理（声明 / 形参处转换）。
3. **既无后缀也无标注**时，推断为**能容纳该值的最小类型**：非负值按 `i8 → u8 → i16 → u16 → i32 → u32 → i64 → u64 → i128 → u128` 逐级取首个可容纳者（同位宽优先有符号），负值按 `i8 → i16 → i32 → i64 → i128`。例如 `42` 为 `i8`、`200` 为 `u8`、`-200` 为 `i16`、`100000` 为 `i32`。

> 注意：在"最小类型"规则下，无标注字面量参与算术时按各自的最小类型做范围检查。
> 例如 `100 + 100`：两操作数均为 `i8`（最大 127），结果 `200` 超出 `i8` 范围会触发
> 算术溢出 panic。需要更大范围时请加后缀（`100i32 + 100`）或标注变量类型
> （`val a: i32 = 100`）。

浮点字面量遵循同样的优先级（后缀 > 标注 > 默认），但默认规则不同：

1. **显式后缀**：`3.14f32`、`2.0f64` 直接采用后缀类型。
2. **显式类型标注**：`val x: f64 = 3.14` 按标注类型处理。
3. **既无后缀也无标注**时，推断为**能精确往返（round-trip）表示该值的最小浮点类型**：按 `f16 → f32 → f64 → f128` 逐级尝试，取首个「转成该精度再转回来仍等于原值」的类型。例如 `0.5` 为 `f16`（可精确表示）、`3.14` 为 `f128`（在 f16/f32/f64 下均有精度损失，无法精确往返）。需要固定精度时请加后缀或标注（如 `val pi: f64 = 3.14`）。

#### 6.12.1 Range 字面量

`start..end` 不是独立类型，元素类型由推断决定。

```glue
0..3            // i8 范围（自动推断）
0i32..1000i32   // i32 范围（显式指定）
0u64..1000u64   // u64 范围
```

Range 实现 `Iterable<T>`。

#### 6.12.2 字符串插值

```glue
val name = "World"
val msg = "Hello, {name}!"              // "Hello, World!"

val x = 10
val result = "{x} + {x} = {x + x}"      // "10 + 10 = 20"

val raw = "{{not interpolated}}"         // "{not interpolated}"
```

- `{expression}` 会调用 `str()` 转为字符串（内建类型转换函数，与 `i32()`、`f64()` 同类）
- `{{` → `{`，`}}` → `}`
- `\"` → `"`，`\\` → `\`
- `\n`、`\t`、`\r` → 换行、制表、回车

### 6.13 注释

```glue
// 单行注释

/* 多行注释 */

/* 嵌套 /* 注释 */ 支持 */
```

---

## 7. 字节码 VM 架构

Glue 当前以**字节码栈式 VM**作为唯一执行后端（树遍历求值器已废弃）。本节描述 VM 的实际架构与运行机制。

### 7.1 流水线

```
源代码 → Lexer → Token → Parser → AST → Sema(type_check 等) → resolve(intern)
                          ↓
                  VM Compiler (src/vm/compiler.zig)
                          ↓
                  Chunk / Function / Program（字节码 + 常量池 + 调试信息）
                          ↓
                  VM (src/vm/vm.zig) ── 执行 ──> Value
```

- **Lexer**（`src/lexer.zig`）：源码 → Token 流
- **Parser**（`src/parser.zig`）：Token → AST（不构造符号表，纯语法）
- **Sema**（`src/sema/`）：类型推断 / Kind 检查 / Throw 检查 / Trait 解析 / 子类型 / 变异性 / GADT 细化 / 模块结构化匹配。**完全在编译前完成，VM 信任类型信息**
- **resolve**（`src/sema/resolve.zig`）：name intern，作用域解析前端
- **VM Compiler**（`src/vm/compiler.zig`）：AST → 字节码 + 常量池
- **VM**（`src/vm/vm.zig`）：栈式字节码执行引擎

### 7.2 栈所有权不变式

栈上每个 `Value` 持有一份 owned 引用：
- 压栈即 +1（retain/retainOwned）
- 弹栈消费即 -1（release）
- 局部变量住在操作数栈 `slot_base + slot` 处

这套不变式使得 RC（引用计数）天然集成到字节码栈操作中，无需 GC root 扫描。

### 7.3 Value 表示

`Value` 为 16 字节紧凑表示（`src/value.zig`）：

```
tag: u8          // 1 字节类型标签
_pad: [7]u8      // 7 字节对齐填充
payload: u64     // 8 字节载荷
```

- **小值内联**：bool/char/i8..i64/u8..u64/f32 等直接放进 payload
- **大值装箱**：i128/u128/f64/f128/str/array/record/ADT/closure/trait 等通过 `*BoxedValue` 指针引用堆

### 7.4 指令集

指令编码：每条指令 = 1 字节 opcode + 0 或多个立即数。立即数宽度固定（u16 用于 idx/slot，i32 用于跳转偏移），小端序。完整指令集见 `src/vm/opcode.zig`，按功能分组：

| 组 | 主要 opcode |
|---|---|
| 常量/字面量 | `OP_CONST`、`OP_NULL`、`OP_UNIT`、`OP_TRUE`、`OP_FALSE` |
| 局部变量 | `OP_GET_LOCAL`、`OP_SET_LOCAL`、`OP_SET_LOCAL_LETREC`、`OP_SET_LOCAL_ASSIGN`、`OP_GET_GLOBAL`、`OP_SET_GLOBAL` |
| 算术/比较/位/一元 | `OP_ADD/SUB/MUL/DIV/MOD`、`OP_EQ/NEQ/LT/GT/LE/GE`、`OP_BIT_AND/OR/XOR`、`OP_NEG/NOT` |
| 跳转 | `OP_JUMP`、`OP_JUMP_IF_FALSE/TRUE` |
| 栈操作 | `OP_POP`、`OP_POP_N`、`OP_DUP` |
| 调用/返回 | `OP_CALL`（顶层快路径）、`OP_CALL_VALUE`（栈上闭包）、`OP_TAIL_CALL`（TCO）、`OP_CALL_NATIVE`（内建）、`OP_RETURN` |
| 闭包/upvalue | `OP_CLOSURE`、`OP_GET_UPVALUE`、`OP_SET_UPVALUE`、`OP_GET_UPVALUE_RAW` |
| 复合值/match | `OP_MAKE_ADT`、`OP_GET_FIELD`、`OP_GET_ADT_FIELD`、`OP_TEST_CTOR`、`OP_MATCH_FAIL`、`OP_MAKE_ARRAY`、`OP_MAKE_RECORD`、`OP_INDEX`、`OP_TEST_LIT`、`OP_RECORD_EXTEND`、`OP_MAKE_NEWTYPE`、`OP_TEST_NEWTYPE`、`OP_GET_NEWTYPE_INNER`、`OP_MAKE_ERROR` |
| 字符串/转换 | `OP_INTERP`、`OP_CAST`、`OP_COERCE`、`OP_CONCAT_LIST` |
| 字段/索引赋值 | `OP_SET_FIELD`、`OP_SET_INDEX` |
| 异常/Nullable | `OP_JUMP_IF_NOT_NULL/NULL`、`OP_NON_NULL`、`OP_PROPAGATE`、`OP_THROW`、`OP_TEST_THROW`、`OP_GET_THROW_OK/ERR` |
| 方法调用/for | `OP_CALL_METHOD`、`OP_FOR_NEXT`、`OP_MAKE_RANGE` |
| Atomic | `OP_MAKE_ATOMIC`、`OP_GET_LOCAL_RAW`、`OP_COMPOUND_LOCAL/UPVALUE` |
| 并发/Lazy/Trait | `OP_SPAWN`、`OP_MAKE_LAZY`、`OP_TRY_RECV`、`OP_RECV`、`OP_MAKE_TRAIT` |

### 7.5 编译器

`ModuleCompiler`（`src/vm/compiler.zig`）采用两遍编译：

1. **第一遍（registerDecls）**：登记所有顶层声明到对应表（`fun_table`/`adt_table`/`newtype_table`/`error_table`/`global_table`/`trait_method_table` 等），建立全局符号索引。`trait_decl` 与无方法的 `type_decl` 在此遍后即完成（无运行时效果）。
2. **第二遍（compileBodies）**：编译每个函数体、trait 方法体、全局初始化器为字节码。`type_decl` 的内联 trait 方法被编成顶层零捕获 Function，登记进 `program.trait_methods`（TraitMethodDesc：`type_name`/`method_name`/`trait_name`/`func_idx`）。

### 7.6 Program 结构

`Program`（`src/vm/chunk.zig`）聚合所有编译产物：

| 字段 | 含义 |
|---|---|
| `functions` | 顶层函数（含 trait 方法编成的零捕获 Function） |
| `adt_ctors` | ADT 构造器描述（字段名、类型名、构造器名） |
| `newtype_ctors` | Newtype 构造器描述 |
| `error_ctors` | Error 子类型构造器描述 |
| `record_shapes` | 记录字段名集合（用于 `OP_MAKE_RECORD`/`OP_RECORD_EXTEND`） |
| `trait_methods` | Trait 方法表（运行时按 receiver 类型名 + 方法名分派） |
| `trait_defaults` | Trait 默认方法表 |
| `trait_infos` | Trait 声明信息（含父 trait、关联类型、override/delegate 集合） |
| `globals` / `global_count` | 顶层 val/var 全局变量槽 |
| `globals_init` | 全局初始化函数 idx |

### 7.7 运行时分派

#### 7.7.1 函数调用

- **顶层函数快路径**：`OP_CALL <func_idx> <argc>` 直接索引 `program.functions[func_idx]`，无哈希查找。
- **栈上闭包**：`OP_CALL_VALUE <argc>` 处理 `vm_closure`（部分应用、嵌套函数、一等函数值）。
- **尾调用**：`OP_TAIL_CALL` 复用当前帧，保证 TCO。

#### 7.7.2 方法调用（`OP_CALL_METHOD`）

分派优先级（在 `vm.zig` 的 `doCallMethod` 中实现）：

1. **内建方法表**（`src/vm/method.zig`）：按 receiver 类型 + 方法名查找内建方法（如 `str.len()`、`array.append()`、`Atomic.cas()`、`Spawn.await()` 等）。
2. **用户 trait 方法表**（`program.trait_methods`）：按 receiver 运行时类型名 + 方法名查找。**数值宽度互通**——字面量 `5`（i8）匹配 `i32` 类型的 trait 实现（镜像 eval 语义）。
3. **Trait 默认方法**（`program.trait_defaults`）：当 trait 声明了默认方法且类型未提供具体实现时回退。

未命中以上三层的 `OP_CALL_METHOD` 触发 panic。

#### 7.7.3 自由函数式 trait 方法

带 `with` 约束的自由函数（如 `compare(a, b)`，receiver 是第一个参数）经编译器识别后，`OP_CALL` 裸名命中且 argc≥1 时改发 `OP_CALL_METHOD`，receiver=arg0，argc-1，复用方法分派机制。

### 7.8 跨文件 use 依赖

`compileModuleWithDeps`（`compiler.zig`）支持单段 `use` 跨文件导入：

- `collectUseDependencies`（递归传递依赖，按模块名去重，依赖先于入口入列表）
- 依赖模块先注册+编译（stdlib 的 trait/fn 合并进同一 Program，扁平 trait 方法表天然合并）
- 入口模块最后编译
- 多段路径 `use` 仍回退到树遍历器（保留兼容）

### 7.9 并发集成

VM 与运行时协同（`src/vm/vm.zig` + `runtime/`）：

- **spawn**：`OP_SPAWN` 弹闭包，深拷捕获快照进 per-spawn arena（`std.heap.ArenaAllocator` + `page_allocator` 裸打底），起 OS 线程跑子 VM 执行 body。await 时取结果（深拷回父 allocator）。子 VM 与父 VM 内存完全隔离（VM 纯 refcount，array/record 非原子 rc 跨线程不安全 → 必须隔离堆）。
- **channel**：`OP_RECV` 阻塞 recv、`OP_TRY_RECV` 非阻塞 tryRecv（select 多路复用）。
- **Atomic**：`OP_MAKE_ATOMIC` 包装标量为 `AtomicValue`；`OP_COMPOUND_LOCAL/UPVALUE` 透明翻译为原子 fetch<op>；slot 持 atomic 时 `OP_SET_LOCAL_ASSIGN` 透明 atomic store（保持共享身份）。
- **Lazy**：`OP_MAKE_LAZY` 包装闭包为 `lazy_val`，首次透明读取（`OP_GET_LOCAL/UPVALUE`）时 force，缓存结果。
- **一等 Trait 值**：`OP_MAKE_TRAIT` 弹 count 个 [name(string), closure] 对，建 `vm_owned` trait_value（vtable: name→vm_closure）。

### 7.10 vmEligible 资格检查

VM 当前已支持全部语言特性，`vmEligible`（`src/main.zig`）仅检查模块是否含 `fun main()`——所有声明类型（type/trait/fun/val/var/use）均能被 VM 编译器处理，无需保守预扫描。

### 7.11 VM 模块结构

```
src/vm/
├── compiler.zig    // ModuleCompiler：AST → 字节码
├── vm.zig          // VM 执行引擎 + Spawn 上下文
├── chunk.zig       // Program / Function / Chunk / TraitMethodDesc / TraitInfo 等数据结构
├── opcode.zig      // OpCode 枚举 + Native 内建函数 id
├── method.zig      // 内建方法表（按 receiver 类型 + 方法名分派）
├── cast.zig        // 类型转换实现（OP_CAST / OP_COERCE）
└── disasm.zig      // 反汇编（调试用）

runtime/
├── slab_pool.zig   // Slab 分配器
├── sync.zig        // 同步原语
├── channel.zig     // Channel 实现
├── spawn.zig       // SpawnHandle 实现（std.Thread + Per-heap GC + Panic 隔离）
├── atomic.zig      // AtomicValue 原子操作
└── vtable.zig      // 一等 Trait 值 vtable 数据结构（DelegateEntry / TraitInfo / TraitMethodEntry / TraitRegistration）
```

---

## 8. 当前实现状态

### 8.1 已实现的语言特性

| 类别 | 特性 |
|---|---|
| **基础类型** | i8..i128、u8..u128、f16/f32/f64/f128、bool、char、str、Unit |
| **字面量** | 整数（最小类型推断 + 后缀 + 标注）、浮点（round-trip 最小类型）、十六进制/八进制/二进制、下划线分隔、char、字符串插值、数组、记录 |
| **运算符** | 算术、比较、逻辑、位、Nullable（`?.`/`??`/`!`/`?`）、范围（`..`/`..=`）、数组拼接（`++`） |
| **变量绑定** | `val`/`var`、类型收窄、嵌套遮蔽 |
| **函数** | 命名函数、Lambda、默认柯里化、var 参数、禁止链式调用、TCO |
| **类型** | 枚举、记录、递归类型、抽象类型、Type Alias、Newtype |
| **ADT** | Pattern Matching（含守卫/或模式/构造器/记录/字面量/newtype/Throw 模式）、穷举检查 |
| **Nullable** | `T?`、`null`、`?.`、`??`、`!`、`?` 传播、双重可空扁平化、协变 |
| **Throw** | `Throw<T, E>`、`throw`、`?` 传播、`Ok/Error` 模式匹配、Error 子类型、自定义错误类型 |
| **Trait** | 定义、type 内联实现、多 trait（括号）、默认方法、override、组合（父 trait + 冲突消解）、关联类型、Self 类型、类型参数约束、类型特化（`with`） |
| **HKT** | Kind 系统、`*`/`* -> *`/`* -> * -> *` |
| **GADT** | `:` 构造器返回类型标注、match 中类型细化 |
| **变异性** | 自动推导（协变/逆变/不变） |
| **子类型** | 记录宽度子类型、Trait 结构化子类型、Error 子类型 |
| **控制流** | `if`/`else`（表达式）、`loop`、`while`、`for`、`break`/`continue`、`return`、`defer` |
| **并发** | `spawn`、`Spawn<T>.await()/cancel()/status()/result()`、`channel`、`Sender`/`Receiver`、`select`、`Atomic<T>` |
| **惰性** | `Lazy<T>` + `lazy` 表达式 |
| **一等 Trait 值** | 文件模块作为 Trait 值、内联 `trait { ... }` 值、vtable 分派 |
| **模块** | 文件即模块、`pack.glue`、`import`（选择性/整体/别名/通配）、`pub` 可见性、抽象类型、循环依赖检测 |
| **内嵌标准库** | `List`（含 `Show` 实现）、`Compare`（`Eq`/`Ord`/`Show` 覆盖内建类型） |
| **项目 CLI** | `glue init`/`run`/`debug`、`glue.toml` 清单 |
| **I/O 内建** | `println`/`print`/`eprintln`/`eprint`/`scanln`/`scan` |

### 8.2 已实现的 VM 能力

| 类别 | 覆盖范围 |
|---|---|
| **指令集** | M0-M5 全套 opcode（见 §7.4） |
| **执行模型** | 栈式 + 引用计数 + 栈所有权不变式 |
| **调用** | 顶层快路径、栈上闭包、TCO、Native 内建、部分应用 |
| **复合值** | ADT 构造/解构、记录字面量/扩展/更新、Newtype、数组、索引 |
| **字符串** | 插值、`str()` 转换、UTF-8 codepoint 索引 |
| **类型转换** | `OP_CAST`（widening/narrowing 运行时检查）、`OP_COERCE`（best-effort 数值协调） |
| **赋值** | 字段赋值（COW）、索引赋值（COW）、复合赋值、全局变量读写 |
| **异常/Nullable** | `?.`/`??`/`!`/`?`/`throw`/Ok-Error 模式匹配 |
| **方法分派** | 内建方法表、用户 trait 方法表（数值宽度互通）、trait 默认方法、自由函数式 trait 方法 |
| **Trait 值** | 内联 `trait { ... }` 构造、vtable 分派 |
| **Atomic** | 透明原子读写、复合赋值、cas/swap |
| **spawn** | OS 线程 + per-spawn arena + 深拷捕获 + Panic 隔离 |
| **channel** | send/recv、方向类型、关闭语义、select 多路复用 |
| **Lazy** | 透明 force + 缓存 |
| **跨文件 use** | 单段 use 依赖收集 + 多模块合并编译 |
| **全局变量** | 顶层 val/var、globals_init 初始化函数 |

### 8.3 VM 资格

VM 当前可处理所有合法 Glue 程序。`vmEligible`（`src/main.zig`）仅要求模块含 `fun main()`。

---

## 9. 设计决策记录

| 编号 | 决策 | 理由 | 替代方案 |
|---|---|---|---|
| D01 | CSP + spawn + channel | 与函数式契合，简洁，运行时安全 | Actor, STM, async/await |
| D02 | Per-heap 隔离 GC | 零全局暂停，天然防数据竞争 | 追踪式 GC, RC |
| D03 | 运行时并行安全 | 降低用户学习门槛 | 编译期所有权系统 |
| D04 | 无 Effect System | 简化语言，Throw<T, E> 覆盖错误处理 | Effect System |
| D05 | 严格求值 + 显式 Lazy | 惰性求值与并行交互复杂 | 惰性求值 |
| D06 | 默认柯里化 | 函数式语言特征，自然支持部分应用 | 显式柯里化 |
| D07 | ADT + Trait（组合） | 组合优于继承 | class + inheritance |
| D08 | 文件即模块 + pack.glue | 简洁，约定优于配置 | 显式 module 声明 |
| D09 | 一等 Trait 值 (vtable) | 运行时多态 + 依赖注入 | 闭包元组 / 独立 module 类型 |
| D10 | 结构化匹配（文件模块） | 灵活，减少样板代码 | 全部名义化匹配 |
| D11 | 名义化匹配 | 类型定义时显式声明实现 trait，编译期单态化 | 纯名义化 / 纯结构化 |
| D12 | 根目录特殊豁免 | 最小项目零配置 | 根目录也需 pack.glue |
| D13 | 入口点默认 `src/Main.glue` 的 `fun main()`，`glue.toml` 作项目根标识 + 可选 `entry` 覆盖 | 约定优于配置，最小配置 | 纯约定无清单 / 完整配置文件 |
| D14 | 无 pack.glue 目录忽略 | 规则简单 | 自动发现 |
| D15 | 未声明文件忽略 | 允许未完成代码安静存在 | 编译警告/错误 |
| D16 | Nullable `T?` 替代 `Option<T>` | 直觉且简洁 | Option ADT |
| D17 | `null` 是所有 `T?` 共享值 | `Null` 是所有 `T?` 的子类型 | 每种类型独立 null |
| D18 | `T?` 是类型系统特性 | 编译器内建知识，专门优化 | 语法糖为 ADT |
| D19 | `T?` 与 `T` 协变 | 符合变异性推导 | 不变 |
| D20 | `T??` 扁平化为 `T?` | 双重可空无实际意义 | 保留双重可空 |
| D21 | Trait bound 独立机制 | 编译期字典传递消除 | 统一到 Throw |
| D22 | Orphan instance 禁止 | 保证连贯性 | 有条件允许 |
| D23 | Overlapping instances 禁止 | 避免不可预测行为 | 最具体匹配 |
| D24 | 完整 HKT | 表达力最强 | 有限 HKT |
| D25 | 子类型关系替代行变量 | 更简单、错误信息更直观 | Row Polymorphism |
| D26 | GADT | 类型安全 AST、状态机 | 不支持 |
| D27 | Type Alias + Newtype | 减少重复、语义化 | 不支持 |
| D28 | Rank-N 初期不支持 | 推断不可判定 | 支持（需标注） |
| D29 | Existential 通过 ADT+模块隐式 | 覆盖 90% 场景 | 显式 ∃ 语法 |
| D30 | 花括号语法 | C 族风格，主流 | 缩进 / do...end |
| D31 | `fun` 函数关键字 | 函数式语言惯例 | fn / def |
| D32 | `: T` 返回类型标注 | 简洁 | -> T |
| D33 | `<T: Trait>` 类型参数约束，`with T: Type` 类型特化 | 清晰明确 | where / requires |
| D34 | `val`/`var` 变量绑定 | 明确区分 | let / 无关键字 |
| D35 | spawn + spawn.await() + channel | 简洁，CSP 本质 | async/await |
| D36 | GADT 用 `:` 标注返回类型 | 简洁 | where / returns |
| D37 | `Throw<T, E>` 双参数形式 | 支持穷举错误匹配 | 单参数 / 异常 |
| D38 | Error 是内建 Trait | 类型安全 | 任意类型可 throw |
| D39 | `type X: Error = X(msg: str)` + override prefix | newtype 语法简洁，X <: Error | 手动实现 Error trait |
| D40 | `?` 统一 Nullable 和 Throw 传播 | 语法统一 | 不同操作符 |
| D41 | `?` 在非 Throw/非 Nullable 函数中编译错误 | 强制显式处理 | 允许自动传播 |
| D42 | Throw + Nullable 双机制 | 互补而非互斥 | 统一为一个 |
| D43 | 无 try/catch/finally | `?` + 模式匹配覆盖主要场景 | 保留 try/catch |
| D44 | 字节码 VM（替代树遍历器） | 数量级提速，单热循环分发 | 树遍历 / LLVM JIT |
| D45 | 先检查后求值 | 类型检查不通过则阻止求值，求值器信任类型信息 | 求值器内嵌类型检查 |
| D46 | 显式类型转换 | widening 合法 narrowing 运行时检查 | 隐式提升 / 截断 |
| D47 | str 用 UTF-8 | 内存高效 | UTF-16 / char[] |
| D48 | 运算符不可重载 | 简单可预测 | 支持重载 |
| D49 | Iterable/Iterator Trait | 统一迭代协议 | 内建 for 循环 |
| D50 | `==` 引用相等 | 性能可预测 O(1)，结构相等用 `eq` | 结构相等为默认 |
| D51 | `?` 不跨 Nullable/Throw | null 和 error 语义不同 | 自动转换 |
| D52 | Panic 不可捕获 | bug 不应恢复，协程级隔离 | panic/recover |
| D53 | `Panic()` 触发 panic | 不可捕获，协程级隔离，简单统一 | 三级断言(assert/precondition/fatal) |
| D54 | OOM 是可恢复错误 | 分配 API 返回 T? | OOM 触发 panic |
| D55 | `defer` 关键字 | LIFO，覆盖正常返回/throw/panic | RAII |
| D56 | 整数溢出均 panic | 无 wrap around 语义 | Release 时 wrap |
| D57 | Channel 关闭语义 | 仅 Sender 关闭，缓冲数据可读 | Go 的 panic on closed |
| D58 | spawn 时深拷贝捕获 | Atomic<T> 浅拷贝例外 | 引用捕获 |
| D59 | var 原地修改和重新赋值 | 记录字段 `user.name = ...` | 纯不可变 |
| D60 | main 无参数 | 命令行参数通过 `Env.args()` | 带参数 |
| D61 | 浮点数无 NaN/Infinity | 除零 panic | 遵循 IEEE 754 |
| D62 | 模块循环依赖编译错误 | 依赖必须是 DAG | 允许循环依赖 |
| D63 | 数组固定大小 | 参考 C，动态用 List | 动态数组 |
| D64 | 普通闭包引用捕获 | spawn 闭包深拷贝 | 统一引用/深拷贝 |
| D65 | Range 非独立类型 | 元素类型由推断决定 | Range<T> 独立类型 |
| D66 | 字符串插值 | `{expr}` 插值，调用 `str()`（内建类型转换） | 无插值 |
| D67 | List 属于 std 库 | 标准库提供，核心语言只提供 T[] | List 内建 |
| D68 | 函数参数默认 val | 安全默认 | 默认 var |
| D69 | 禁止链式调用 `f(a)(b)` | 可读性差，易与嵌套调用混淆，显式绑定更清晰 | 允许链式调用 |
| D70 | 尾调用优化 | 保证 TCO，含相互递归 | 不保证 TCO |
| D71 | 无匿名元组 | 记录必须有命名字段 | 支持匿名元组 |
| D72 | 去掉 Agent | spawn+channel 已足够，减少概念 | 保留 Agent |
| D73 | Atomic<T> 替代 Arc<T> | 透明原子操作更安全简洁，无数据竞争 | 保留 Arc<T> |
| D74 | Throw 构造器简化为 Ok/Error | 消除 Err(Error(...)) 双重包装冗余，Error() 直接创建 ThrowValue.err | 保留 Err + Error 双层构造 |
| D75 | Trait 实现内联进 type 声明 | 消除独立 trait 实现声明形式，简化语法，type 定义即完整契约 | 保留独立 trait 实现块声明 |
| D76 | Value 16 字节紧凑表示 | tag + payload 双字，小值内联大值装箱，栈拷贝廉价 | 64 字节 union(enum) 按值拷贝 |
| D77 | 栈式 VM（非寄存器式） | 与表达式求值天然契合，编译器实现量小 | 寄存器式 VM |
| D78 | 现编译现执行（无磁盘字节码缓存） | 编译耗时相对运行时可忽略 | JIT / 字节码缓存到磁盘 |

---

## 10. 术语表

| 术语 | 英文 | 含义 |
|---|---|---|
| ADT | Algebraic Data Type | 代数数据类型，通过和类型与积类型组合数据 |
| GADT | Generalized Algebraic Data Types | 广义代数数据类型，构造器可返回不同类型参数 |
| CSP | Communicating Sequential Processes | 通信顺序进程，通过 channel 通信的并发模型 |
| HM | Hindley-Milner | 类型推断算法 |
| HKT | Higher-Kinded Types | 高阶类型，对类型构造器进行抽象 |
| Kind | Kind | 类型的类型，如 `*`、`* -> *` |
| 一等 Trait 值 | First-Class Trait Value | Trait 作为运行时值，通过 vtable 实现动态分派 |
| VTable | Virtual Table | 虚函数表，运行时多态分派的实现机制 |
| STW | Stop-The-World | 垃圾回收时暂停所有线程 |
| Work-Stealing | Work-Stealing | 空闲线程从其他线程偷任务的调度策略 |
| Nullable | Nullable | 可空类型 `T?`，表示 T 类型的值或 null |
| Null | Null | null 值的类型，是所有 `T?` 的子类型 |
| Throw | Throw | 包装类型 `Throw<T, E>`，表示返回 T 或抛出类型为 E 的错误 |
| Error | Error | 内建 Trait，所有可以被 throw 抛出的类型必须满足 |
| 类型收窄 | Type Narrowing | 编译器通过条件检查将 `T?` 收窄为 `T` |
| 类型细化 | Type Refinement | GADT match 中推导局部类型等式 |
| 类型转换 | Type Conversion | 显式将值从一种类型转换为另一种类型 |
| 协变 | Covariant | 允许用子类型替换父类型 |
| 逆变 | Contravariant | 允许用父类型替换子类型 |
| 不变 | Invariant | 不允许子类型或父类型替换 |
| 连贯性 | Coherence | 对任意 (Trait, Type) 组合全局最多一个实现 |
| 子类型 | Subtyping | 类型间的兼容关系 |
| 宽度子类型 | Width Subtyping | 字段更多的记录是字段更少的记录的子类型 |
| 结构化子类型 | Structural Subtyping | 方法更多的模块是方法更少的 Trait 的子类型 |
| Newtype | Newtype | 单字段 ADT，创建语义不同但运行时无开销的新类型 |
| Type Alias | Type Alias | 类型别名，不创建新类型 |
| 迭代器 | Iterator | 提供 `next()` 方法的 Trait，返回 `T?` |
| 可迭代 | Iterable | 提供 `iterator()` 方法的 Trait |
| 协程 | Coroutine | 轻量级并发执行单元，由运行时调度 |
| Atomic<T> | Atomic<T> | 透明原子操作，跨协程共享原子状态 |
| 字节码 VM | Bytecode VM | 将 AST 编译为线性字节码后由栈式执行引擎运行 |
| Chunk | Chunk | 字节码指令序列 + 立即数编码 |
| 先检查后求值 | Check-then-eval | Sema 先完成类型检查，类型错误阻止求值；VM 信任类型信息 |
| 引用相等 | Reference Equality | `==` 比较内存地址（ADT）或值（基础类型） |
| 结构相等 | Structural Equality | `eq` 方法逐字段比较 |
| Panic | Panic | 不可恢复的 bug，不可捕获，协程级隔离 |
| 断言 | Assertion | 统一为 `Panic()` 构造器，不可恢复，不可捕获 |
| defer | defer | 延迟执行，LIFO 顺序，覆盖正常返回/throw/panic |
| 整数溢出 | Integer Overflow | Debug + Release 均 panic，无 wrapping |
| Channel 关闭 | Channel Close | 仅 Sender 可关闭，关闭后缓冲数据可读 |
| 闭包捕获 | Closure Capture | 普通闭包引用捕获，spawn 闭包深拷贝 |
| 原地修改 | In-place Mutation | var 绑定支持重新赋值和字段修改 |
| 尾调用优化 | Tail Call Optimization | 保证 TCO，尾递归不栈溢出 |
| 值语义深拷贝 | Value Semantics Deep Copy | 赋值和传参均深拷贝，两个变量完全独立 |
| 栈所有权不变式 | Stack Ownership Invariant | 栈上每个 Value 持有一份 owned 引用，压栈 +1 弹栈 -1 |
