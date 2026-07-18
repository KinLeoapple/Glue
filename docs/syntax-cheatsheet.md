# Glue 语法速查

> 精炼语法汇总 · 基于 parser 实际实现（`src/parse/parser.zig` + `lexer.zig`）
> 所有示例均取自 `tests/` 与 `bench/` 下的 `.glue` 测试用例

---

## 1. 变量绑定

```glue
val x = 42                  // 不可变（默认）
var count: i32 = 0          // 可变，显式类型
count = count + 1           // 重新赋值
count += 1                  // 复合赋值
val maybe: i32? = null      // 类型标注 + nullable
```

---

## 2. 函数

```glue
fun add(a: i32, b: i32): i32 { a + b }        // 块尾表达式即返回值
fun double(x: i32): i32 { return x * 2 }       // 显式 return（提前返回）
fun modify(data: var i32): i32 { data + 1 }    // var 参数（可变）

// 异步函数（实际并发原语，非 spawn）
async fun mul10x10(): i64 { 10 * 10 }
async fun send(ch: Channel<i64>): Unit { ch.send(12345) }

// Lambda（匿名函数）
fun(x) { x + 1 }
fun(x: i32) { x * 2 }                         // 带类型标注
async fun() { ... }                           // async lambda

// 箭头 lambda
val f = (x) => x + 1
val g = (a, b) => a + b

// 嵌套 fun 语句（捕获外层 var）
fun makeCounter(): () -> i32 {
    var n = 0
    fun() { n = n + 1; n }
}
```

---

## 3. 类型定义

```glue
// 枚举（Sum Type）—— 每个变体必须以 | 起始（含首个）
type Ordering =
    | Lt
    | Eq
    | Gt

// 带参数构造器（命名字段）
type Shape =
    | Circle(radius: f64)
    | Rectangle(width: f64, height: f64)

// 位置参数构造器
type Tree = | Leaf | Node(i32, Tree, Tree)

// 泛型 ADT
type List<T> = | Nil | Cons(T, List<T>)
type Pair<A, B> = Pair(first: A, second: B)

// 记录（Product Type）—— 字段必须命名
type User = (name: str, age: i32, email: str?)

// Newtype（单字段或多字段）
type UserId = UserId(i32)
type Point = Point(x: i32, y: i32)

// 类型别名
type Name = str

// 函数类型
type IntFn = () -> i32
type BinOp = (i32, i32) -> i32
```

---

## 4. Trait

### 定义（含关联类型与默认方法）
```glue
trait Iterator {
    type Item                    // 关联类型声明
    fun next(self): Item?
    fun map<U>(f: (Item) -> U): Iterator<U>   // 泛型方法
}

trait Printable {
    fun format(self): str
    fun print(self): str { "<" + self.format() + ">" }   // 默认方法
}
```

### 实现 Trait

```glue
// type 定义时内联实现
type MyInt: Show = MyInt(value: i32) {
    fun show(self): str { str(self.value) }
}

// 条件实现（类型参数有 trait 约束）
type Box<T: Show>: Show = Box(value: T) {
    fun show(self): str { "Box(" + self.value.show() + ")" }
}

// 实现多个 Trait —— 必须用括号
type Point: (Show, Comparable) = Point(x: i32, y: i32) {
    fun show(self): str { ... }
    fun compare(self, other): Ordering { ... }
}

// Error 子类型
type FileError: Error = FileError(msg: str) {
    override fun prefix(self): str { "file error" }
}
// 内置方法：e.message()、e.type_name()
```

> **注意**：关联类型只能在 trait 体中声明，不能在 type 实现块中定义。

---

## 5. 类型参数约束 vs 类型特化

> **关键区别：** trait 约束在 `<>` 内，`with` 只用于类型特化

```glue
// trait 约束：放在类型参数中
fun max<T: Comparable>(a: T, b: T): T { ... }       // 单个 trait
fun f<T: (Show, Eq)>(x: T): str { ... }             // 多个 trait（括号）
type Box<T: Show>: Show = Box(value: T) { ... }     // 类型定义
type Pair<A: Show, B: Show> = Pair(a: A, b: B)      // 多个类型参数

// 类型特化：with 后只跟具体类型
fun optimize<T>(x: T): T with T: i32 { ... }        // T 必须是 i32
type Vec<T>: IntOps with T: i32 = ...               // type 的 with 约束
```

### Kind 标注（高级类型）

```glue
type Functor<F: * -> *> { ... }    // F 是类型构造子
```

---

## 6. Pattern Matching

```glue
// 字面量 + 守卫 + 或模式 + 通配符
match value {
    0 => "zero"
    n if n < 0 => "negative"        // 守卫条件
    1 | 2 | 3 => "small"            // 或模式
    _ => "other"                    // 通配符
}

// ADT 解构（嵌套）
match shape {
    Circle(r) => 3.14 * r * r
    Rectangle(w, h) => w * h
}

// 深嵌套
match tree {
    Node(_, Node(x, _, _), _) => x
    Leaf => -1
}

// 位置模式
match p {
    Pt(0, 0) => "origin"
    Pt(x, y) if x > 0 && y > 0 => "Q1"
}

// 记录模式（命名字段）
match seg {
    Seg(Pt(x1, y1), Pt(x2, y2)) => ...
}

// nullable 匹配
match n {
    null => "nothing"
    x => "got " + str(x)            // x 已收窄为非空
}

// val/var 绑定模式
match opt {
    val x => x + 1
    null => 0
}
```

---

## 7. Nullable (`T?`)

```glue
val name: str? = get_name()

name?.len()                 // 安全调用 → i32?
name?.owner?.addr?.city     // 深链 ?. 
name?.len() ?? 0            // Elvis 默认值 → i32
name!.len()                 // 非空断言（null 则 panic）
val x = name?               // ? 传播（外层须返回 U?）

// 链式 Elvis
val first = a ?? b ?? c ?? -1

// ? 传播 Throw
val x = checked(a)?         // throw 时提前传播

// if 类型收窄
fun length(s: str?): i32 {
    if s != null { s.len() } else { 0 }   // then 分支中 s 收窄为 str
}

// 类型转换 + ? 传播
val x = i32(big)?           // 转换失败时传播失败，成功时解包出 i32 内部值
```

---

## 8. 错误处理 Throw<T, E>

```glue
fun read(path: str): Throw<str, Error> {
    if bad { throw Error("failed") }
    Ok("content")
}

// ? 传播
fun chain(a: i32, b: i32): Throw<i32, Error> {
    val x = checked(a)?     // throw 时提前传播
    val y = checked(b)?
    Ok(x + y)
}

// 模式匹配
match read("f") {
    Ok(content) => content
    Error(e) => e.message()
}

// 自定义 Error 子类型
type NotFound: Error = NotFound(msg: str) {
    override fun prefix(self): str { "not found" }
}
```

---

## 9. 控制流

```glue
// if 是表达式
val d = if x > 0 { "pos" } else { "neg" }

// for-in 循环
for i in 0..100 { ... }            // 开区间
for i in 1..=10 { ... }            // 闭区间
for item in [1, 2, 3] { ... }      // 数组迭代
for ch in "héllo" { ... }          // 字符串按 Unicode 标量值迭代

while cond() { ... }
loop { if done { break } }         // 无限循环 + break

defer cleanup()                    // 作用域退出时执行（LIFO）
defer counter = 10                 // defer 也支持赋值语句

// break / continue
for i in 1..=10 {
    if i % 2 == 0 { continue }
    if i > 5 { break }
    sum += i
}
```

> **条件禁止括号**：`if`/`while`/`for`/`match` 的条件以 `(` 开头会报错。

---

## 10. 并发

> **实际并发原语是 `async fun` + `.await()`，不是 `spawn`**

```glue
// 异步函数
async fun mul10x10(): i64 { 10 * 10 }
async fun incr(c: Atomic<i64>): Unit { c = c + 1 }
async fun produce(ch: Channel<i64>): Unit { ch.send(12345) }

// 启动与等待
val s = mul10x10()
println(s.await())           // 等待结果
println(s.status())          // 状态查询

// 原子变量
var counter = atomic 0       // atomic 表达式
counter += 1                 // 透明原子操作
val old = atm.swap(20)       // 原子 swap
val ok = atm.cas(20, 30)     // CAS

// 通道
val ch = channel(10)         // channel(size)
ch.send(42)
val v = ch.recv()
val tx = ch.sender           // 拆分发送端
val rx = ch.receiver         // 拆分接收端
tx.close()

// select 多路复用
select {
    ch1.recv() => handle(v)
    ch2.recv() => handle(v)
    timeout(1000) => onTimeout()
}

// 绑定接收值
select {
    ch.recv() => v => println("got " + str(v))
}
```

---

## 11. 一等 Trait 值与 Lazy

```glue
// 内联 trait 值（匿名实现）
val logger: Logger = trait {
    fun log(msg) { println(msg) }
}
logger.log("hi")
run_with(logger)                          // 作为参数传递

// 惰性求值
val v: Lazy<i32> = lazy expensive()       // 首次访问时计算并缓存
```

---

## 12. 模块系统

```glue
import Compare                          // 导入模块
import Collections.{Map as CMap}        // 导入并重命名

// 文件模块：src/Store/Memory.glue
// 目录模块入口：src/Store/pack.glue
pub pack Memory                         // 在 pack.glue 中声明公开子模块

Store.Memory.put(k, v)                  // 限定访问子模块
run(Store.Memory)                       // 文件模块作为 Trait 值传递

pub fun put(key: str, value: str): Unit { ... }   // pub 可见性
```

---

## 13. 字面量

```glue
42          // 整数，推断为能容纳的最小类型（i8）
42i32       // 显式后缀（i8..i128 u8..u128 f16 f32 f64 f128）
3.14        // 浮点
3.14f32     // 显式浮点后缀
0xFF 0o77 0b1010            // 进制前缀
1_000_000                  // 下划线分隔
'a'                        // char
'\u{1F600}'                // Unicode 转义
"hello {name}"             // 字符串插值
"{{literal}}"              // 字面花括号
[1, 2, 3]                  // 数组
(name: "Alice", age: 30)   // 记录字面量
()                         // 单位值 unit

// 记录扩展
val base = (a: 1, b: 2, c: 3)
val updated = (...base, b: 20)           // record_extend
val mixed = (x: 1, ...base, y: 2)        // 混合扩展
```

> **匿名元组禁止**：`(1, 2)` 会报错，必须用命名字段。

---

## 14. 运算符

```
算术     + - * / %
比较     == != < > <= >=
引用相等 === !==
逻辑     && || !
位运算   & | ^ ~ << >>
可空     ?. ?? ! ?
范围     ..  ..=
拼接     ++              // 数组拼接（非自增！自增用 x += 1）
展开     ...             // 记录扩展
箭头     => ->           // match 分支 / 函数类型

复合赋值 += -= *= /= %=  &= |= ^= <<= >>=
```

**优先级（高→低）：**
```
?.  ·  ? !  ·  一元(- ! ~)  ·  * / %  ·  + - ++  ·  .. ..=
·  比较(< > <= >=)  ·  相等(== != === !==)  ·  &  ·  ^  ·  |  ·  << >>
·  &&  ·  ||  ·  ??
```

> 运算符不可重载。
> - `==` / `!=`：**递归值相等**（结构相等），由编译器自动派生，用户不可覆盖。对标量、str、array、record、ADT、newtype、range、error_val 递归比较内容。
> - `===` / `!==`：**引用相等**，比较两个值的内存地址。标量上退化为 `==`/`!=`。
> - 递归类型（如 `type List<T> = | Cons(T, List<T>)`）的结构相等若遇到循环引用，行为为 **UB**（未定义行为），不做运行时检测。
> **负号与数字字面量折叠**：`-42` 直接合并为负整数字面量。

---

## 15. 类型转换

```glue
i32(big)                    // 类型转换（失败 panic）
f64(42)                     // 整数 → 浮点
str(42)                     // 整数 → 字符串
str('A')                    // char → 字符串
i32(x)?                     // 转换 + ? 传播：失败时传播失败，成功解包出 i32 内部值
```

---

## 16. 后缀表达式

```glue
obj.field                    // 字段访问
obj.method(args)             // 方法调用
obj.method::<Type>(args)     // turbofish 调用（显式泛型类型）
obj?.field                   // 安全字段访问
obj?.method(args)            // 安全方法调用
arr[index]                   // 索引
f(args)                      // 函数调用
```

> **禁止链式调用**：`f(a)(b)` 会报错，必须拆分为 `val tmp = f(a); tmp(b)`。

---

## 关键规则速记

| 规则 | 说明 |
|------|------|
| 默认不可变 | `val` 默认，`var` 显式可变 |
| 枚举前导 `\|` | 每个变体（含首个）必须以 `\|` 起始 |
| 多 trait 用括号 | `type X: (T1, T2)` / `<T: (A, B)>` |
| trait 约束在 `<>` | `<T: Trait>`，`with` 只用于类型特化 |
| 记录字段命名 | 无匿名元组，`(str, i32)` 不存在 |
| Error 用方法 | `e.message()` 而非 `e.message` |
| 块尾即返回 | 最后表达式自动返回，`return` 用于提前返回 |
| 无自增运算符 | 用 `x += 1`，`++` 仅数组拼接 |
| 条件禁止括号 | `if`/`while`/`for`/`match` 条件不能以 `(` 开头 |
| 禁止链式调用 | `f(a)(b)` 报错，需拆分 |
| 并发用 async | `async fun` + `.await()`，非 `spawn` |
| 关联类型限 trait | 只能在 trait 体声明，不能在 type 实现块定义 |
| `==` 值相等 | 递归结构相等，自动派生；引用相等用 `===` |
| 整数溢出 panic | 无 wrap 语义 |
