# Glue 语法速查

> 精炼语法汇总 · 所有示例均经 35/35 测试验证

---

## 1. 变量绑定

```glue
val x = 42              // 不可变（默认）
var count: i32 = 0      // 可变，显式类型
count = count + 1       // 重新赋值
```

---

## 2. 函数

```glue
fun add(a: i32, b: i32): i32 { a + b }      // 块尾表达式即返回值
fun double(x: i32): i32 { return x * 2 }     // 显式 return（提前返回）
fun modify(data: var i32): i32 { data + 1 }  // var 参数

// Lambda
fun(x) { x + 1 }
(x) => x + 1
```

---

## 3. 类型定义

```glue
// 枚举（Sum Type）—— 每个变体必须以 | 起始（含首个）
type Ordering =
    | Lt
    | Eq
    | Gt

// 带参数构造器
type Shape =
    | Circle(radius: f64)
    | Rectangle(width: f64, height: f64)

// 记录（Product Type）—— 字段必须命名
type User = (name: str, age: i32, email: str?)

// Newtype
type UserId = UserId(i32)
type Point = Point(x: i32, y: i32)

// 类型别名
type Name = str

// 递归类型
type List<T> = | Nil | Cons(T, List<T>)
```

---

## 4. Trait

### 定义
```glue
trait Show {
    fun show(self): str
}

// 带默认实现
trait Printable {
    fun format(self): str
    fun print(self): str { "<" + self.format() + ">" }   // 默认方法
}
```

### 实现（两种方式）
```glue
// 方式一：type 定义时内联实现
type MyInt: Show = MyInt(value: i32) {
    fun show(self): str { str(self.value) }
}

// 方式二：独立 impl 块
impl Show<Ordering> {
    fun show(self): str { ... }
}
```

### 实现多个 Trait —— 必须用括号
```glue
type Point: (Show, Comparable) = Point(x: i32, y: i32) {
    fun show(self): str { ... }
    fun compare(self, other): Ordering { ... }
}
```

### Error 子类型
```glue
type FileError: Error = FileError(msg: str) {
    override fun prefix(self): str { "file error" }
}
// 内置方法：e.message()、e.type_name()
```

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
```

---

## 6. Pattern Matching

```glue
match value {
    0 => "zero"
    n if n < 0 => "negative"        // 守卫条件
    1 | 2 | 3 => "small"            // 或模式
    _ => "other"                    // 通配符
}

// ADT 解构
match shape {
    Circle(r) => 3.14 * r * r
    Rectangle(w, h) => w * h
}

// 嵌套模式
match tree {
    Node(_, Node(x, _, _), _) => x
    Leaf => -1
}

// nullable 匹配
match n {
    null => "nothing"
    x => "got " + str(x)            // x 已收窄为非空
}
```

---

## 7. Nullable (`T?`)

```glue
val name: str? = get_name()

name?.len()             // 安全调用 → i32?
name?.len() ?? 0        // Elvis 默认值 → i32
name!.len()             // 非空断言（null 则 panic）
val x = name?           // ? 传播（外层须返回 U?）

// if 类型收窄
fun length(s: str?): i32 {
    if (s != null) { s.len() } else { 0 }   // then 分支中 s 收窄为 str
}
```

---

## 8. 错误处理 Throw<T, E>

```glue
fun read(path: str): Throw<str, Error> {
    if (bad) { throw Error("failed") }
    Ok("content")
}

// ? 传播
fun chain(): Throw<i32, Error> {
    val x = read(a)?        // throw 时提前传播
    Ok(x)
}

// 模式匹配
match read("f") {
    Ok(content) => content
    Error(e) => e.message()
}
```

---

## 9. 控制流

```glue
val d = if x > 0 { "pos" } else { "neg" }   // if 是表达式

for i in 0..100 { ... }                      // 开区间
for i in 1..=10 { ... }                      // 闭区间
for item in [1, 2, 3] { ... }                // 数组迭代
for ch in "hello" { ... }                    // 字符串迭代

while cond() { ... }
loop { if done { break } }

defer cleanup()                              // 作用域退出时执行（LIFO）
```

---

## 10. 并发

```glue
val s = spawn { compute() }     // 启动协程
val r = s.await()               // 等待结果
s.cancel()                      // 取消

var counter = atomic 0          // 原子变量
counter += 1                    // 透明原子操作

val ch = channel<i32>(0)        // 无缓冲通道
ch.send(42)
val v = ch.recv()

select {
    ch1.recv() => v => handle(v)
    timeout(1000) => onTimeout()
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

// 惰性求值
val v: Lazy<i32> = lazy expensive()   // 首次访问时计算并缓存
```

---

## 12. 模块系统

```glue
import Compare              // 导入模块

// 文件模块：src/Store/Memory.glue
// 目录模块入口：src/Store/pack.glue
pub pack Memory             // 在 pack.glue 中声明公开子模块

Store.Memory.put(k, v)      // 限定访问子模块
run(Store.Memory)           // 文件模块作为 Trait 值传递
```

---

## 13. 字面量

```glue
42          // 推断为能容纳的最小类型（i8）
42i32       // 显式后缀
3.14        // 浮点
0xFF 0o77 0b1010            // 进制前缀
1_000_000                  // 下划线分隔
'a'                        // char
"hello {name}"             // 字符串插值
[1, 2, 3]                  // 数组
(name: "Alice", age: 30)   // 记录
```

---

## 14. 运算符

```
算术   + - * / %
比较   == != < > <= >=
逻辑   && || !
可空   ?. ?? ! ?
范围   ..  ..=
集合   ++              // 数组拼接（非自增！自增用 x += 1）
```

**优先级（高→低）：** `?.` · `?` `!` · 一元 · `* / %` · `+ - ++` · `.. ..=` · 比较 · 相等 · `&&` · `||` · `??`

> 运算符不可重载。`==` 是引用相等，结构相等用 `eq()`。

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
