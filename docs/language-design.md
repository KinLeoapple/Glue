# Glue 语言设计规范

> 版本: 0.7.0-draft
> 最后更新: 2026-06-05

---

## 目录

1. [语言概述与设计哲学](#1-语言概述与设计哲学)
2. [类型系统](#2-类型系统)
3. [并行与并发模型](#3-并行与并发模型)
4. [模块系统](#4-模块系统)
5. [运行时与垃圾回收](#5-运行时与垃圾回收)
6. [语法设计](#6-语法设计)
7. [解释器架构与实现路线图](#7-解释器架构与实现路线图)

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
| **约定优于配置** | 零配置即可运行，默认入口为 `Main.glue` 中的 `main` 函数 |
| **渐进复杂度** | 简单的事情简单做，复杂的事情可能，但不强制 |

### 1.3 核心设计决策总览

| 维度 | 决策 |
|---|---|
| 目标领域 | 通用编程 |
| 范式 | 函数式 |
| 并发模型 | CSP + spawn + channel |
| 并行安全策略 | 运行时保证（值语义 + 深拷贝 + Per-Heap GC） |
| 求值策略 | 严格求值 + 显式惰性 (`Lazy<T>`) |
| 柯里化 | 默认柯里化 |
| 类型系统 | Hindley-Milner 推断 + ADT + GADT + Nullable + Throw<T, E> + Trait + HKT + 子类型 |
| 数据语义 | 值语义（默认不可变） |
| 共享机制 | Arc<T> 共享不可变数据 |
| 错误处理 | `Throw<T, E>` + `throw` + `?` 传播 + Nullable (`T?`) |
| GC 策略 | Per-Heap 隔离 GC |
| 模块系统 | 文件即模块 + `pack.glue` + 一等 Trait 值 (vtable) |
| 变异性 | 自动推导 + 可选显式标注 |
| 可见性 | 默认私有 + `pub` 公开 |
| 函数关键字 | `fun` |
| 返回类型 | `: T` |
| Trait Bound | `with Bound` |
| 泛型参数 | `<T>` |
| 变量绑定 | `val`（不可变）/ `var`（可变） |
| 并发原语 | `spawn` + `task.await()` + `channel` |
| 类型转换 | 显式 `Type(value)` 语法，widening 合法 narrowing 运行时检查 |
| 运算符 | 内建不可重载 |
| 字符串 | UTF-8 编码，迭代产生 `char` |

---

## 2. 类型系统

### 2.1 概述

Glue 的类型系统以 Hindley-Milner 为基础，扩展了代数数据类型 (ADT)、GADT、Nullable 类型、Throw 类型、Trait、Higher-Kinded Types 和子类型关系。类型推断在大多数场景下可以自动完成，用户无需显式标注。

核心设计原则：

- **安全默认**：类型 `T` 不可空，`T?` 才可空；`T` 不会抛错，`Throw<T, E>` 才可能
- **组合优于继承**：通过 ADT + Trait 组合行为，不提供继承
- **显式传播**：`?` 操作符统一处理 Nullable 和 Throw 的坏值传播
- **显式转换**：数值类型之间没有隐式转换，必须使用 `Type(value)` 显式转换
- **运算符用户不可重载**：运算符对内建类型有特例（如 `String + String` 拼接），自定义类型使用命名方法

### 2.2 基础类型

```
i8    i16    i32    i64    i128
u8    u16    u32    u64    u128
f32   f64
bool
char
```

基础类型均为值类型，存储在栈上或直接内联在数据结构中。

| 类型 | 含义 | 备注 |
|---|---|---|
| `i8`..`i128` | 有符号整数 | 默认整数字面量为 `i32` |
| `u8`..`u128` | 无符号整数 | |
| `f32`, `f64` | 浮点数 | 默认浮点字面量为 `f64` |
| `bool` | 布尔值 | 值为 `true` 或 `false` |
| `char` | Unicode 标量值 | 4 字节，字面量用单引号 `'a'`，显示时无引号 `a` |
| `String` | 字符串 | UTF-8 编码，字面量用双引号 `"hello"`，迭代产生 `char` |
| `()` | 单位类型 | 又称 `Unit`，表示没有有意义的值 |

**整数溢出行为**：

整数溢出在 Debug 和 Release 模式下都会触发 panic。溢出几乎总是 bug，静默 wrap around 会掩盖错误：

```glue
val max: i32 = 2147483647
val overflow = max + 1    // panic: integer overflow
```

整数溢出就是 panic，没有 wrap around 语义。

**浮点数无 NaN 和 Infinity**：

Glue 的浮点数不包含 NaN 和 Infinity 值。浮点除零触发 panic，而非产生 Infinity 或 NaN：

```glue
val a = 1.0 / 0.0     // panic: division by zero
val b = 0.0 / 0.0     // panic: division by zero
```

理由：
1. NaN 的 `NaN != NaN` 语义与 Glue 的 `==` 引用相等冲突
2. NaN 和 Infinity 是 IEEE 754 的特殊值，增加了类型系统的不确定性——每个 `f64` 值都需要考虑"可能是 NaN"的情况
3. 浮点除零几乎总是 bug，panic 比 silently 产生特殊值更安全
4. 如果需要表示"无效"或"无穷大"，使用 `f64?` 或 `Throw<f64, Error>` 显式表达

**String 的 UTF-8 编码**：

String 使用 UTF-8 编码存储，这是内存效率最高的 Unicode 编码方式。UTF-8 编码带来以下特性：

- **迭代产生 `char`**：遍历 String 时产生 Unicode 标量值（`char`），而非字节
- **索引为 O(n) 操作**：由于 UTF-8 是变长编码，通过索引访问第 n 个字符需要从头遍历字节
- **字节长度与字符数不同**：`str.len()` 返回字节长度，`str.char_count()` 返回字符数

```glue
val s = "你好"
s.len()          // 6（UTF-8 编码，每个中文字符占 3 字节）
s.char_count()   // 2（2 个 Unicode 标量值）

// 迭代产生 char
for c in s {
    println(c)   // 依次输出 '你' 和 '好'
}
```

**数值类型之间无隐式转换**：

不同数值类型之间不会自动转换，必须使用显式转换语法 `Type(value)`：

```glue
val a: i32 = 42
val b: i64 = i64(a)      // 显式转换
val c: f64 = f64(a)      // 显式转换
// val d: i64 = a         // ❌ 编译错误：no implicit conversion
```

### 2.3 Nullable 类型

Glue 不使用 `Option<T>`，而是通过内建的 Nullable 类型系统支持空值。

#### 2.3.1 `T?` 语法

`T?` 表示 `T` 类型的值或 `null`。`T?` 是类型系统的内建特性，不是语法糖。

```glue
val a: i32 = 42          // ✅ 不可空
val b: i32? = null       // ✅ 可空，持有 null
val c: i32? = 42         // ✅ 可空类型也可以持有非空值
val d: i32 = null        // ❌ 编译错误：i32 不可空
```

#### 2.3.2 `null` 的类型

`null` 是所有 `T?` 类型的共享值。`null` 的类型为 `Null`，`Null` 是所有 `T?` 类型的子类型：

```
Null <: String?
Null <: i32?
Null <: User?
```

因此 `null` 可以赋值给任何 `T?` 类型的变量。

#### 2.3.3 `T?` 的变异性

`T?` 对 `T` 协变：

```
Cat <: Animal  →  Cat? <: Animal?
```

#### 2.3.4 双重可空扁平化

`T??` 等价于 `T?`，不区分"null"和"嵌套的 null"：

```glue
val x: String?? = null       // 等价于 String?
val x: String?? = "hello"    // 等价于 String?
```

#### 2.3.5 使用可空值——类型收窄

使用可空值前必须消除空值可能性。编译器通过类型收窄 (type narrowing) 追踪：

**match 收窄**：

```glue
fun greet(name: String?) : String {
    match name {
        null => "Hello, stranger",
        n => "Hello, " + n,    // n : String（已收窄为不可空）
    }
}
```

**if 收窄**：

```glue
fun length(s: String?) : i32 {
    if s != null { s.len() } else { 0 }
    // s 在 then 分支中收窄为 String
}
```

#### 2.3.6 安全调用操作符 `?.`

```glue
val len = name?.len()    // 如果 name 为 null，返回 null；否则返回 len
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
val city = user?.address?.city    // city : String?
```

#### 2.3.7 Elvis 操作符 `??`

```glue
val len = name?.len() ?? 0    // 如果为 null，使用默认值 0
// len 的类型: i32
```

`??` 提供默认值，将 `T?` 转为 `T`。

#### 2.3.8 非空断言 `!`

```glue
val len = name!.len()    // 如果 name 为 null，运行时 panic
```

`!` 用于确定值不为 null 但编译器无法证明的情况。应谨慎使用。

#### 2.3.9 `?` 传播操作符

`?` 作为表达式后缀操作符，用于提前传播"坏值"：

**在 `T?` 上**：

```glue
fun greet() : String? {
    val name = get_name()?    // null 时提前返回 null
    "Hello, " + name          // name 已收窄为 String
}
```

**在 `Throw<T, E>` 上**：

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

null 和 error 是语义不同的概念——null 表示"值不存在"，error 表示"操作失败并附带原因"。因此 `?` 严格按类型匹配，不跨类型传播：

```glue
// ❌ 编译错误：在 Throw 函数中对 T? 用 ?
fun read_config() : Throw<Config, Error> {
    val name = get_name()?     // get_name() 返回 String?，? 要求外层返回 U?
    parse_config(name)
}

// ✅ 正确：显式处理 null
fun read_config() : Throw<Config, Error> {
    val name = get_name() ?? throw Error("name is null")
    parse_config(name)
}

// ❌ 编译错误：在 Nullable 函数中对 Throw 用 ?
fun safe_get() : String? {
    val content = read_file("data.txt")?  // read_file 返回 Throw<String, FileError>
    content
}

// ✅ 正确：模式匹配处理 Throw
fun safe_get() : String? {
    match read_file("data.txt") {
        Ok(content) => content,
        Err(_) => null,
    }
}
```

**`Throw<T?, E>` 的两步处理**：

当两个维度同时存在时，需要分别处理——先处理 Throw，再处理 Nullable：

```glue
fun find_user(id: i32) : Throw<User?, FileError> {
    val result = db_query(id)?    // Throw<User?, FileError> -> User?
    result                         // User? — 可能是 null
}

// 使用时两步处理
val user = match find_user(42) {
    Ok(u) => u,           // u : User?
    Err(e) => null,       // 降级为 null
}
// user : User? — 还需要处理 null
val name = user?.name ?? "anonymous"
```

> **注意**：`T?` 中的 `?` 是类型后缀（表示可空），`expr?` 中的 `?` 是表达式操作符（表示传播）。两者处于不同语法位置，编译器无歧义区分。

#### 2.3.10 Nullable 与 Pattern Matching

`null` 作为模式直接匹配：

```glue
fun describe(n: i32?) : String {
    match n {
        null => "nothing",
        0 => "zero",
        x if x < 0 => "negative",
        _ => "positive",
    }
}
```

#### 2.3.11 Nullable 与 Trait

`T` 和 `T?` 是不同的类型，需要分别实现 trait：

```glue
impl Show<i32> {
    fun show(n) { string(n) }
}

impl Show<i32?> {
    fun show(n) {
        match n {
            null => "null",
            x => string(x),
        }
    }
}
```

#### 2.3.12 Nullable 与泛型

```glue
fun first<T>(list: List<T>) : T? {
    match list {
        Nil => null,
        Cons(x, _) => x,
    }
}
```

#### 2.3.13 Nullable 与并行

```glue
fun producer(ch: Sender<i32?>) : Unit {
    ch.send(42)
    ch.send(null)        // ✅ 发送 null
}

fun consumer(ch: Receiver<i32?>) : Unit {
    val v = ch.recv()
    match v {
        null => println("got null"),
        n => println(n),
    }
}
```

#### 2.3.14 Nullable 不是副作用

null 是类型系统追踪的属性，不是运行时副作用。访问可空值、处理 null 不涉及 Effect。

### 2.4 Throw 类型

`Throw<T, E>` 是内建包装类型，表示"返回 T 或抛出类型为 E 的错误"。通过双参数形式，错误类型 E 在类型签名中显式声明，使得错误处理既类型安全又支持穷举匹配。

#### 2.4.1 Error Trait

`Error` 是内建 Trait，所有可被 `throw` 抛出的类型必须满足 `Error`：

```glue
// Error 是内建 Trait，无需定义
throw Error("something went wrong")

// Error 有 message 字段
val e = Error("not found")
e.message    // "not found"
```

`Error` 是所有错误类型的基类型。自定义错误类型（通过 `type X = Error("msg")` 定义）都是 `Error` 的子类型。

#### 2.4.2 自定义错误类型

使用 newtype 语法创建自定义错误类型，自动满足 Error trait：

```glue
type FileError = Error("file error")
type NetworkError = Error("network error")
type ParseError = Error("parse error")
```

语法：`type Name = Error("默认前缀")`

语义：
1. 创建 newtype `Name`，包装一个 `String` message
2. 自动实现 Error trait
3. `"默认前缀"` 是 message 的默认前缀
4. **`Name` 是 `Error` 的子类型**——`FileError <: Error`

```glue
throw FileError("config.json not found")
throw NetworkError("connection refused")
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
fun read_file(path: String) : Throw<String, FileError> {
    if !found { throw FileError(path + " not found") }
    "content"
}
```

`Throw<T, E>` 的值有两种状态：
- `Ok(value)` — 成功，持有 T 类型的值
- `Err(error)` — 失败，持有 E 类型的错误值

#### 2.4.5 throw 语句

`throw` 抛出一个满足 Error trait 的值，立即终止当前函数执行：

```glue
fun risky_operation() : Throw<String, Error> {
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
    val content = read_file("config.json")?    // Throw<String, FileError> -> String
    val config = parse_json(content)?           // Throw<Config, ParseError> -> Config
    config
}
```

`?` 的传播规则：
- `expr?` 作用于 `Throw<T, E_inner>` 时，成功得到 `T`，失败则提前传播 throw
- 外层函数必须返回 `Throw<U, E_outer>`，且 `E_inner <: E_outer`
- 在普通函数中调用 `Throw<T, E>` 函数，必须通过模式匹配显式处理，不能用 `?`

#### 2.4.7 Throw 模式匹配

**E 为具体错误类型——穷举匹配**：

```glue
match read_file("config.json") {    // Throw<String, FileError>
    Ok(content) => process(content),
    Err(FileError(e)) => println("file: " + e.message),
}
// ✅ 穷举：Err 只可能是 FileError
```

**E 为 Error 基类型——需要 catch-all**：

```glue
match read_config() {    // Throw<Config, Error>
    Ok(config) => use(config),
    Err(FileError(e)) => println("file: " + e.message),
    Err(ParseError(e)) => println("parse: " + e.message),
    Err(e) => println("error: " + e.message),    // catch-all
}
```

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
Cat <: Animal  →  Throw<Cat, E> <: Throw<Animal, E>
FileError <: Error  →  Throw<T, FileError> <: Throw<T, Error>
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
    name: String,
    age: i32,
    email: String?,
)
```

记录类型是匿名的，基于结构化匹配：

```glue
fun greet(user: (name: String, age: i32)) : String {
    "Hello, " + user.name
}
```

**无匿名元组**：记录必须有命名字段，`(String, i32)` 不存在。如果需要通用配对类型，使用：

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
fun describe(n: i32?) : String {
    match n {
        null => "nothing",
        x => "got " + string(x),
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
fun classify(n: i32) : String {
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

```glue
trait Comparable<T> {
    fun compare(a: T, b: T) : Ordering
}

impl Comparable<i32> {
    fun compare(a, b) {
        if a < b { Lt } else if a == b { Eq } else { Gt }
    }
}
```

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
2. **自动派生**：`impl Child for T` 自动满足所有父 Trait 的 bound
3. **冲突消解**：当多个父 Trait 有同名方法时，必须显式处理

冲突消解方式：

**委托（`=`）**：

```glue
trait Combined(Serializable, Debug) {
    fun to_string(self) : String = Serializable.to_string
}
```

**重命名**：

```glue
trait Combined(Serializable, Debug) {
    fun to_string(self) : String = Serializable.to_string
    fun debug_string(self) : String = Debug.to_string
}
```

**覆写（`override`）**：

```glue
trait Combined(Serializable, Debug) {
    override fun to_string(self) : String {
        "[" + Debug.to_string(self) + "]"
    }
}
```

#### 2.7.3 Trait Bound

```glue
fun max<T>(a: T, b: T) : T with Ord<T> {
    if lte(a, b) { b } else { a }
}
```

#### 2.7.4 关联类型

```glue
trait Container {
    type Item
    fun empty() : Container
    fun insert(self: Container, item: Item) : Container
    fun len(self: Container) : i32
}
```

#### 2.7.5 名义化匹配与结构化匹配

| 匹配方式 | 适用场景 | 分派方式 | 连贯性 |
|---|---|---|---|
| 名义化（`impl`） | 自定义类型实现 Trait | 编译期单态化 | 全局唯一 |
| 结构化（自动） | 文件模块作为 Trait 值 | 运行时 vtable | 按匹配规则 |

#### 2.7.6 Orphan Instance 禁止

| Trait 定义方 | Type 定义方 | 是否允许 impl |
|---|---|---|
| 当前模块 | 当前模块 | ✅ |
| 其他模块 | 当前模块 | ✅ |
| 当前模块 | 其他模块 | ✅ |
| 其他模块 | 其他模块 | ❌ |

#### 2.7.7 Overlapping Instances 禁止

不允许两个 impl 的类型有重叠。如果需要不同行为，用 newtype 包装。

#### 2.7.8 Iterable 与 Iterator

```glue
trait Iterable<T> {
    fun iterator(self) : Iterator<T>
}

trait Iterator<T> {
    fun next(self) : T?
}
```

`for item in list` 要求 `list` 的类型满足 `Iterable<T>`。

### 2.8 函数类型

#### 2.8.1 默认柯里化

```glue
fun add(a: i32, b: i32) : i32 { a + b }

// 部分应用
val add5 = add(5)
add5(3)  // => 8
```

#### 2.8.2 函数类型语法

```
A -> B              函数：A 到 B
(A, B) -> C         多参数（语法糖，实际是柯里化）
A -> Throw<B, E>    可能抛错的函数
```

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

Glue 采用 Hindley-Milner 类型推断，大多数场景下无需显式标注类型：

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
*           具体类型         i32, String, bool
* -> *      一阶类型构造器   List, Vec, Tree, Array
* -> * -> * 二阶类型构造器   Map, Throw
(* -> *) -> *  高阶类型构造器  Functor, Monad
```

```glue
trait Functor<F : * -> *> {
    fun map<T, U>(ft: F<T>, f: T -> U) : F<U>
}

trait Monad<F : * -> *>(Functor<F>) {
    fun pure<A>(a: A) : F<A>
    fun bind<A, B>(fa: F<A>, f: A -> F<B>) : F<B>
}
```

#### 2.11.2 Monad 组合

```glue
impl Monad<List> {
    fun pure(value) { Cons(value, Nil) }
    fun bind(list, f) { concat_map(list, f) }
}

// 通用的 @ 上下文表达式（语法糖）
fun compute() : List<i32> {
    @List {
        x <- [1, 2, 3]
        y <- [4, 5, 6]
        x + y
    }
}
// => [5, 6, 7, 6, 7, 8, 7, 8, 9]
```

### 2.12 子类型关系

Glue 使用三种子类型关系：

#### 2.12.1 记录宽度子类型

字段更多的记录是字段更少的记录的子类型：

```
(name: String, age: i32)  <:  (name: String)
```

#### 2.12.2 Trait 结构化子类型

方法更多的模块是方法更少的 Trait 的子类型：

```
{ get, put, delete, list }  <:  { get, put }
```

#### 2.12.3 Error 子类型

自定义错误类型是 `Error` 的子类型：

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

### 2.14 Type Aliases 与 Newtype

```glue
// Type Alias — 不创建新类型
type IntList = List<i32>
type Name = String

// Newtype — 创建新类型，运行时零开销
type UserId = UserId(i32)
type Celsius = Celsius(f64)
```

### 2.15 类型转换

显式 `Type(value)` 语法，无隐式转换：

**widening（低位转高位）**：始终合法：

```glue
val x: i8 = 42
val y: i16 = i16(x)     // ✅
val z: i32 = i32(y)     // ✅
val f: f64 = f64(z)     // ✅
```

合法路径：
- `i8 → i16 → i32 → i64 → i128`
- `u8 → u16 → u32 → u64 → u128`
- `i8 → f32 → f64`，`i16 → f32 → f64`，`i32 → f64`
- `u8 → f32 → f64`，`u16 → f32 → f64`，`u32 → f64`

**narrowing（高位转低位）**：运行时检查，值超出范围则 panic：

```glue
val big: i64 = 42
val small: i32 = i32(big)     // ✅ 42 在 i32 范围内

val huge: i64 = 9999999999
val overflow: i32 = i32(huge) // ❌ panic: value does not fit in i32

val neg: i32 = -1
val unsign: u32 = u32(neg)    // ❌ panic: value -1 does not fit in u32
```

**`string()` 类型转换**：`string()` 是内建类型转换函数，将任意值转为字符串表示，与 `i32()`、`f64()` 同类：

```glue
string(42)          // "42"
string(3.14)        // "3.14"
string(true)        // "true"
string('a')         // "a"
```

`string()` 也是字符串插值 `{expr}` 的底层机制——插值时自动调用 `string(expr)`。

### 2.16 迭代器

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
| `Array<T>` | 数组元素 |
| `String` | `char` |
| `start..end` | 范围值，T 由推断决定 |

### 2.17 错误处理策略

| 场景 | 推荐机制 | 理由 |
|---|---|---|
| 值可能不存在 | `T?` | 最轻量，语义清晰 |
| 操作可能失败，需要错误信息 | `Throw<T, E>` | 携带错误详情，`?` 传播 |
| 操作可能失败，错误类型明确 | `Throw<T, SpecificError>` | 穷举匹配，类型安全 |
| 聚合多种错误 | `Throw<T, Error>` | 统一处理，catch-all |
| 并发任务中的错误 | Channel 传递 `Throw<T, E>` | CSP 模型 |

---

## 3. 并行与并发模型

### 3.1 概述

Glue 采用 **CSP (通信顺序进程)** 作为并发模型：

- 通过 channel 通信，不通过共享内存通信
- `spawn` 创建协程，`task.await()` 阻塞等待结果
- **没有 async/await 关键字**
- 运行时保证并行安全

### 3.2 spawn

`spawn` 创建协程，立即返回 `Task<T>`，不阻塞当前代码：

```glue
val t = spawn { fetch_url("http://example.com") }
do_other_work()
val result = t.await()
```

#### 3.2.1 spawn 捕获语义

- **普通闭包**：引用捕获，共享外部作用域
- **spawn 闭包**：深拷贝捕获，完全隔离（`Arc<T>` 例外，浅拷贝）

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

### 3.3 Task

`spawn` 返回 `Task<T>`：

```glue
t.await()                        // 阻塞等待，返回 T
Task.await_all([t1, t2, t3])    // 等待全部
Task.await_any([t1, t2])        // 等待任一完成
Task.timeout(t, 1000)           // 带超时等待，返回 T?
```

`await` 不是关键字，而是 `Task<T>` 的方法。

### 3.4 Channel

#### 3.4.1 创建与使用

```glue
val ch = channel<i32>(0)       // 无缓冲（同步）
val ch = channel<i32>(10)      // 缓冲区大小 10

ch.send(42)                    // 发送
val value = ch.recv()          // 接收
```

#### 3.4.2 方向类型

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

#### 3.4.3 Select

```glue
select {
    ch1.recv() => value => handle_a(value),
    ch2.recv() => value => handle_b(value),
    timeout(1000) => handle_timeout(),
}
```

#### 3.4.4 Channel 关闭

- **仅 Sender 可关闭**
- 关闭后缓冲数据仍可读取
- 关闭后 send 返回 `SendError`
- 关闭后 recv 缓冲区耗尽返回 `null`

```glue
ch.close()

match ch.send(42) {
    Ok(()) => println("sent"),
    Err(SendError) => println("channel closed"),
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

### 3.5 并行安全保证

#### 3.5.1 值语义 + 深拷贝

1. **默认值语义**：传参时拷贝值，不共享引用
2. **深拷贝隔离**：跨协程传递时深拷贝，确保无共享可变状态
3. **无共享可变状态**：两个协程不可能同时持有同一块可变内存的引用

#### 3.5.2 Per-Heap GC 隔离

每个协程拥有独立的 GC heap：
- 两个协程不可能同时访问同一块堆内存
- 跨协程传递数据时，数据被深拷贝到目标 heap
- GC 回收不需要全局暂停

#### 3.5.3 共享不可变数据：Arc<T>

当需要跨协程共享大块不可变数据时，使用 `Arc<T>` 避免深拷贝开销：

```glue
val config: Arc<Config> = arc(load_config())

spawn {
    use(config)    // 零拷贝，共享同一份数据
}

spawn {
    use(config)    // 零拷贝，共享同一份数据
}
```

`Arc<T>` 保证：
- 内容不可变——多个协程只读访问，天然安全
- 引用计数原子——跨协程增减引用数，最后一个引用消失时释放
- spawn 捕获 `Arc<T>` 时浅拷贝（只复制指针 + 原子增加引用计数），而非深拷贝整个数据

**需要共享可变状态时**，使用 spawn + channel 手动实现——启动一个协程持有状态，其他协程通过 channel 发送请求：

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

#### 3.5.4 并行安全总结

| 机制 | 保证 | 适用场景 |
|---|---|---|
| 值语义 + 深拷贝 | 无共享引用 | 默认，覆盖绝大多数场景 |
| Per-Heap GC | 无共享堆内存 | 所有并发代码 |
| Channel | 安全通信 | 协程间数据传递 |
| Arc<T> | 不可变共享 | 只读数据跨协程零拷贝共享 |

### 3.6 调度模型

Glue 采用 **M:N 调度（协程）**，少量 OS 线程上运行大量轻量级协程。

运行时内置 work-stealing 调度器：
- 每个 worker 线程有本地任务队列
- 空闲 worker 从其他 worker "偷"任务
- `task.await()` 挂起当前协程，让出执行权

---

## 4. 模块系统

### 4.1 概述

1. **文件即模块**：每个 `.glue` 文件是一个模块
2. **`pack.glue`**：目录模块的入口文件
3. **一等 Trait 值**：Trait 可以作为运行时值传递

### 4.2 文件到模块的映射

- `src/` 根目录下的 `.glue` 文件直接参与编译
- 子目录：有 `pack.glue` → 目录成为模块；无 `pack.glue` → 整个目录被忽略
- 文件未在 `pack.glue` 中声明 → 不参与编译

```
src/
├── Main.glue                          ✅ 根目录
├── Collections/
│   ├── pack.glue                      ✅ 目录入口
│   ├── Map.glue                       ✅ 已声明
│   └── Wip/
│       └── Vector.glue                ❌ 无 pack.glue
└── Temp.glue                          ✅ 根目录
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

| 声明 | 可见范围 |
|---|---|
| 默认（无 `pub`） | 仅当前模块 |
| `pub` | 所有模块 |
| `pub pack X` | 子模块对外可见 |
| `pack X` | 子模块仅内部可见 |

### 4.5 `use` 导入

```glue
use Collections.{Map, insert, empty}       // 选择性导入
use Collections.Map                         // 导入整个模块
use Collections.{Map as CMap, insert as ins}  // 别名
```

#### 4.5.1 模块循环依赖

两个模块互相 `use` 会触发编译错误：

```glue
// A.glue
use B.{helper}     // ❌ 编译错误：检测到循环依赖 A → B → A
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
    fun log(msg: String) : Unit { println(msg) }
}
```

### 4.7 一等 Trait 值的运行时表示

vtable 指针 + data 载荷的胖指针：

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

---

## 5. 运行时与垃圾回收

### 5.1 Per-Heap 隔离 GC

每个协程拥有独立的 GC heap。

核心优势：
- **零全局暂停**：每个 heap 独立回收
- **天然防数据竞争**：两个协程不可能同时访问同一块内存
- **高效回收**：函数式风格产生大量短命对象，隔离 GC 各自独立回收

GC 算法：**分代式复制收集器**（新生代 + 老生代 + 大对象区）

### 5.2 跨 Heap 传递规则

| 数据类型 | 跨 Heap 传递方式 |
|---|---|
| 基础类型 | 值拷贝（栈上） |
| 不可变数据结构 | 深拷贝到目标 heap |
| 一等 Trait 值 | vtable 共享 + data 深拷贝 |
| Channel | 调度器 heap 中，两端只持有引用 |
| 函数/闭包 | 深拷贝捕获的环境 |
| Arc<T> | 浅拷贝（原子增加引用计数） |

### 5.3 Work-Stealing 调度器

- 每个 worker 线程有本地任务队列
- 空闲 worker 从其他 worker 偷任务
- Worker 数量默认等于 CPU 核心数

### 5.4 运行时层次

```
┌─────────────────────────────────────────┐
│              用户代码                      │
├─────────────────────────────────────────┤
│        并行原语 (spawn, channel, select)  │
├─────────────────────────────────────────┤
│        一等 Trait 值运行时 (vtable 分派)      │
├─────────────────────────────────────────┤
│        Work-Stealing 调度器               │
├─────────────────────────────────────────┤
│        Per-Heap GC                       │
├─────────────────────────────────────────┤
│        OS 线程池                          │
└─────────────────────────────────────────┘
```

---

## 6. 语法设计

### 6.1 概述

Glue 采用花括号 C 族函数式语法。

### 6.2 关键字

```
fun type trait impl override pack pub use with as
val var
match if else
spawn channel select
loop for in while break continue return
true false null
throw lazy defer
```

### 6.3 函数定义

```glue
fun add(a: i32, b: i32) : i32 { a + b }
fun multiply(a: i32) : (i32 -> i32) { fun(b) { a * b } }

// 返回 Throw
fun read_file(path: String) : Throw<String, FileError> {
    if !found { throw FileError("not found") }
    "content"
}

// 带 Trait Bound
fun max<T>(a: T, b: T) : T with Ord<T> {
    if lte(a, b) { b } else { a }
}

// var 参数
fun process(data: var List<i32>) {
    data.push(42)       // ✅ var 参数可修改
}

// Lambda
fun(x) { x + 1 }
(x) => x + 1
```

**函数参数默认 val**，需要修改时显式标注 `var`。

### 6.4 变量绑定

```glue
val x = 42              // 不可变
var count = 0           // 可变
count = count + 1

val name: String? = get_name()
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
    host: String,
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
type FileError = Error("file error")
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
fun greet() : String? {
    val name = get_name()?
    "Hello, " + name
}

// 模式匹配
match read_file("config.json") {
    Ok(content) => process(content),
    Err(FileError(e)) => println("file: " + e.message),
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

`defer` 注册延迟执行的操作，在当前作用域退出时按 LIFO 顺序执行：

```glue
fun process_file(path: String) : Throw<Unit, FileError> {
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
..   开区间（不包含上界）    0..10
..=  闭区间（包含上界）      0..=9
```

#### 运算符优先级（从高到低）

```
1.  ?.  .   函数调用
2.  ?   !
3.  !   -（前缀）
4.  *  /  %
5.  +  -
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
42              // i32（默认）
42i32           // 显式 i32
42u64           // 显式 u64
3.14            // f64（默认）
3.14f32         // 显式 f32
0xFF            // 十六进制
0o77            // 八进制
0b1010          // 二进制
1_000_000       // 下划线分隔

'a'                     // char
"hello"                 // String
"hello {name}"          // 字符串插值

true  false  null

[1, 2, 3]                      // Array<i32>
(name: "Alice", age: 30)       // 记录
```

#### 6.12.1 Range 字面量

`start..end` 不是独立类型，元素类型由推断决定，默认 i32：

```glue
0..3            // i32 范围
0i8..127i8      // i8 范围
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

- `{expression}` — 调用 `string()` 转为字符串（内建类型转换函数，与 `i32()`、`f64()` 同类）
- `{{` → `{`，`}}` → `}`
- `\"` → `"`，`\\` → `\`
- `\n`、`\t`、`\r` — 换行、制表、回车

### 6.13 注释

```glue
// 单行注释

/* 多行注释 */

/* 嵌套 /* 注释 */ 支持 */
```

---

## 7. 解释器架构与实现路线图

### 7.1 解释器流水线

```
源代码 → Lexer → Token → Parser → AST → Sema → 求值器 (Evaluator)
```

#### Sema（语义分析）

- 类型推断 (Hindley-Milner)
- Kind 推断与检查
- Throw 类型检查
- Trait 解析与 bound 检查
- 子类型检查
- 变异性推导
- GADT 类型细化与穷举检查
- Nullable 类型收窄
- Pattern matching 穷举检查
- 模块类型结构化匹配
- 类型转换合法性检查

#### 求值器 (Evaluator)

AST 树遍历求值器，采用 **先检查后求值** 策略：

- 环境 (Environment)：词法作用域的变量绑定链
- Throw 处理：`throw` 通过栈展开传播
- 并发求值：`spawn` 创建协程，`channel` 委托运行时
- defer 执行：作用域退出时 LIFO 顺序执行
- 类型转换：`Type(value)` 显式转换

### 7.2 解释器组件结构

```
glue/
├── src/
│   ├── main.zig              // 解释器入口 (REPL + 文件执行)
│   ├── lexer.zig             // 词法分析
│   ├── parser.zig            // 语法分析
│   ├── ast.zig               // AST 定义
│   ├── sema/
│   │   ├── type_check.zig    // 类型检查与推断
│   │   ├── kind_check.zig    // Kind 检查与推断
│   │   ├── throw_check.zig   // Throw 类型检查
│   │   ├── subtype_check.zig // 子类型检查
│   │   ├── variance.zig      // 变异性推导
│   │   ├── trait_resolve.zig // Trait 解析
│   │   ├── gadt_check.zig    // GADT 类型细化
│   │   └── module_check.zig  // 模块类型匹配
│   ├── eval/
│   │   ├── value.zig         // 运行时值表示
│   │   ├── env.zig           // 环境
│   │   ├── eval.zig          // 核心求值器
│   │   ├── pattern.zig       // Pattern matching 求值
│   │   ├── throw.zig         // Throw 运行时处理
│   │   └── module_eval.zig   // 一等 Trait 值求值
│   └── module/
│       ├── resolver.zig      // 模块解析
│       └── graph.zig         // 依赖图
├── runtime/
│   ├── scheduler.zig         // Work-stealing 调度器
│   ├── gc.zig                // Per-heap GC
│   ├── channel.zig           // Channel 实现
│   ├── task.zig              // Task 实现
│   ├── arc.zig               // Arc<T> 原子引用计数
│   └── vtable.zig            // 一等 Trait 值 vtable 支持
└── build.zig                 // Zig 构建脚本
```

### 7.3 实现阶段

#### Phase 1：语言基础

| 目标 | 产出 |
|---|---|
| Lexer | Token 流 |
| Parser | AST |
| 求值器 | 可执行基本表达式 |
| 基础类型 | i8..i128, u8..u128, f32, f64, bool, char |
| Nullable | `T?`、`null`、`?.`、`??`、`!`、类型收窄、`?` 传播 |
| Throw | `Throw<T, E>`、`throw`、`?` 传播、`Ok/Err` 模式匹配 |
| `?` 不跨 Nullable/Throw | `?` 严格按类型匹配 |
| Error | 内建 Error trait、自定义错误类型、Error 子类型 |
| Type Alias + Newtype | 类型别名与零开销包装 |
| 类型转换 | 显式 `Type(value)`，widening 合法 narrowing 运行时检查 |
| 相等性 | `==` 引用相等，`eq` 结构相等 |
| Panic | 不可捕获，三级断言，协程隔离 |
| defer | LIFO 顺序，覆盖正常返回/throw/panic |
| 整数溢出 | Debug + Release 均 panic，无 wrapping |
| 浮点数 | 无 NaN/Infinity，除零 panic |
| Channel 关闭 | 仅 Sender 可关闭，关闭后缓冲数据可读 |
| spawn 捕获 | spawn 时深拷贝，Arc<T> 浅拷贝 |
| 闭包捕获 | 普通闭包引用捕获，spawn 闭包深拷贝 |
| var 与值语义 | 支持重新赋值和原地修改 |
| main 签名 | `fun main()` 无参数 |
| 数组 | 固定大小（参考 C），动态集合用 List |
| 模块依赖 | 循环依赖编译错误 |
| Range | 非独立类型，元素类型由推断决定 |
| 字符串插值 | `{expr}` 插值，`{{`/`}}` 转义 |
| List | 标准库类型 |
| 函数参数 | 默认 val，`var` 标注才可修改 |
| 尾调用优化 | 保证 TCO |
| 元组 | 无匿名元组，记录必须有命名字段 |
| REPL | 交互式求值 |

#### Phase 2：顺序语义完整

| 目标 | 产出 |
|---|---|
| ADT | 代数数据类型 + Pattern Matching |
| 类型推断 | Hindley-Milner |
| Trait | 定义、实现、bound |
| Iterable/Iterator | `for` 循环脱糖 |
| 模块系统 | 文件即模块 + pack.glue + use |

#### Phase 3：子类型与记录操作

| 目标 | 产出 |
|---|---|
| 记录宽度子类型 | 字段更多是更少的子类型 |
| Trait 结构化子类型 | 方法更多是更少的子类型 |
| Error 子类型 | FileError <: Error |
| 记录操作 | 扩展、更新、模式匹配 |

#### Phase 4：并发原语

| 目标 | 产出 |
|---|---|
| 运行时调度器 | Work-stealing scheduler |
| Channel | 创建、发送、接收、方向类型 |
| spawn | 协程创建，返回 Task<T> |
| Task.await() | 阻塞等待协程结果 |
| Per-heap GC | 隔离垃圾回收 |
| select | 多路复用 |
| Arc<T> | 原子引用计数，不可变数据跨协程共享 |

#### Phase 5：HKT

| 目标 | 产出 |
|---|---|
| Kind 系统 | `*`、`* -> *`、`* -> * -> *` 等 |
| Kind 推断 | 自动推导 |
| Trait HKT | Functor、Monad 等高阶 trait |
| Monad `@` 语法 | 上下文表达式语法糖 |

#### Phase 6：GADT

| 目标 | 产出 |
|---|---|
| GADT 定义 | `:` 语法标注构造器返回类型 |
| 类型细化 | GADT match 中的类型等式推导 |
| GADT 穷举检查 | 考虑类型约束 |

#### Phase 7：一等 Trait 值与高级特性

| 目标 | 产出 |
|---|---|
| 一等 Trait 值 | Trait 作为运行时值传递 |
| 结构化匹配 | 文件模块自动满足 Trait |
| 内联 Trait 值 | `trait { ... }` 匿名实现 |
| vtable 生成 | 运行时多态分派 |
| Lazy | 显式惰性求值 |

#### Phase 8：优化与生态

| 目标 | 产出 |
|---|---|
| 优化器 | 内联、常量折叠、死代码消除 |
| 标准库 | 集合、IO、网络、JSON 等 |
| 包管理器 | 依赖管理与分发 |
| LSP | 语言服务器协议支持 |
| 自举 | 用 Glue 实现 Glue |

### 7.4 实现语言

解释器和运行时使用 **Zig 0.16** 实现：
- 精确控制内存布局，适合实现 GC 和 Arc
- 内建原子操作，适合实现调度器
- 无隐藏分配，行为可预测
- 交叉编译支持好

---

## 附录 A：设计决策记录

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
| D11 | 名义化 + 结构化双模式 | `impl` 保证优化，结构化减少样板 | 纯名义化 / 纯结构化 |
| D12 | 根目录特殊豁免 | 最小项目零配置 | 根目录也需 pack.glue |
| D13 | 入口点默认 Main.main | 约定优于配置 | glue.toml 配置 |
| D14 | 无 pack.glue 目录忽略 | 规则简单 | 自动发现 |
| D15 | 未声明文件忽略 | 允许未完成代码安静存在 | 编译警告/错误 |
| D16 | Nullable `T?` 替代 `Option<T>` | 直觉且简洁 | Option ADT |
| D17 | `null` 是所有 `T?` 共享值 | `Null` 是所有 `T?` 的子类型 | 每种类型独立 null |
| D18 | `T?` 是类型系统特性 | 编译器内建知识，专门优化 | 语法糖为 ADT |
| D19 | `T?` 对 `T` 协变 | 符合变异性推导 | 不变 |
| D20 | `T??` 扁平化为 `T?` | 双重可空无实际意义 | 保留双重可空 |
| D21 | Trait bound 独立机制 | 编译期字典传递消除 | 统一为 Throw |
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
| D33 | `with Bound` Trait Bound | Scala 风格 | where / requires |
| D34 | `val`/`var` 变量绑定 | 明确区分 | let / 无关键字 |
| D35 | spawn + task.await() + channel | 简洁，CSP 本质 | async/await |
| D36 | GADT 用 `:` 标注返回类型 | 简洁 | where / returns |
| D37 | `Throw<T, E>` 双参数形式 | 支持穷举错误匹配 | 单参数 / 异常 |
| D38 | Error 是内建 Trait | 类型安全 | 任意类型可 throw |
| D39 | `type X = Error("msg")` | newtype 语法简洁，X <: Error | 手动 impl Error |
| D40 | `?` 统一 Nullable 和 Throw 传播 | 语法统一 | 不同操作符 |
| D41 | `?` 在非 Throw/非 Nullable 函数中编译错误 | 强制显式处理 | 允许自动传播 |
| D42 | Throw + Nullable 双机制 | 互补而非互斥 | 统一为一种 |
| D43 | 无 try/catch/finally | `?` + 模式匹配覆盖主要场景 | 保留 try/catch |
| D44 | AST 树遍历解释器 | 实现简单，适合早期迭代 | 字节码 VM / LLVM |
| D45 | 先检查后求值 | 求值器信任类型信息 | 求值器内嵌类型检查 |
| D46 | 显式类型转换 | widening 合法 narrowing 运行时检查 | 隐式提升 / 截断 |
| D47 | String 是 UTF-8 | 内存高效 | UTF-16 / Array<char> |
| D48 | 运算符不可重载 | 简单可预测 | 支持重载 |
| D49 | Iterable/Iterator Trait | 统一迭代协议 | 内建 for 循环 |
| D50 | `==` 引用相等 | 性能可预测 O(1)，结构相等用 `eq` | 结构相等为默认 |
| D51 | `?` 不跨 Nullable/Throw | null 和 error 语义不同 | 自动转换 |
| D52 | Panic 不可捕获 | bug 不应恢复，协程级隔离 | panic/recover |
| D53 | 三级断言 | 区分开发期检查、接口契约、不可达 | 统一 assert |
| D54 | OOM 是可恢复错误 | 分配 API 返回 T? | OOM 触发 panic |
| D55 | `defer` 关键字 | LIFO，覆盖正常返回/throw/panic | RAII |
| D56 | 整数溢出均 panic | 无 wrap around 语义 | Release 下 wrap |
| D57 | Channel 关闭语义 | 仅 Sender 关闭，缓冲数据可读 | Go 的 panic on closed |
| D58 | spawn 时深拷贝捕获 | Arc<T> 浅拷贝例外 | 引用捕获 |
| D59 | var 原地修改和重新赋值 | 记录字段 `user.name = ...` | 纯不可变 |
| D60 | main 无参数 | 命令行参数通过 `Env.args()` | 带参数 |
| D61 | 浮点数无 NaN/Infinity | 除零 panic | 遵循 IEEE 754 |
| D62 | 模块循环依赖编译错误 | 依赖必须是 DAG | 允许循环依赖 |
| D63 | 数组固定大小 | 参考 C，动态用 List | 动态数组 |
| D64 | 普通闭包引用捕获 | spawn 闭包深拷贝 | 统一引用/深拷贝 |
| D65 | Range 非独立类型 | 元素类型由推断决定 | Range<T> 独立类型 |
| D66 | 字符串插值 | `{expr}` 插值，调用 `string()`（内建类型转换） | 无插值 |
| D67 | List 是标准库类型 | 核心语言只提供 Array | List 内建 |
| D68 | 函数参数默认 val | 安全默认 | 默认 var |
| D69 | 尾调用优化 | 保证 TCO，含相互递归 | 不保证 TCO |
| D70 | 无匿名元组 | 记录必须有命名字段 | 支持匿名元组 |
| D71 | 去掉 Agent | spawn+channel 已足够，减少概念 | 保留 Agent |
| D72 | 保留 Arc<T> | 不可变数据零拷贝无替代方案 | 去掉 Arc |

## 附录 B：术语表

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
| Error | Error | 内建 Trait，所有可被 throw 抛出的类型必须满足 |
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
| Arc<T> | Arc<T> | 原子引用计数包装类型，不可变数据的跨协程零拷贝共享 |
| 求值器 | Evaluator | AST 树遍历求值器 |
| 先检查后求值 | Check-then-eval | Sema 先完成类型检查，求值器信任类型信息 |
| 引用相等 | Reference Equality | `==` 比较内存地址（ADT）或值（基础类型） |
| 结构相等 | Structural Equality | `eq` 方法逐字段比较值 |
| Panic | Panic | 不可恢复的 bug，不可捕获，协程级隔离 |
| 断言 | Assertion | assert/precondition/fatal 三级断言 |
| defer | defer | 延迟执行，LIFO 顺序，覆盖正常返回/throw/panic |
| 整数溢出 | Integer Overflow | Debug + Release 均 panic，无 wrapping |
| Channel 关闭 | Channel Close | 仅 Sender 可关闭，关闭后缓冲数据可读 |
| 闭包捕获 | Closure Capture | 普通闭包引用捕获，spawn 闭包深拷贝 |
| 原地修改 | In-place Mutation | var 绑定支持重新赋值和字段修改 |
| 尾调用优化 | Tail Call Optimization | 保证 TCO，尾递归不栈溢出 |
| 值语义深拷贝 | Value Semantics Deep Copy | 赋值和传参均深拷贝，两个变量完全独立 |
