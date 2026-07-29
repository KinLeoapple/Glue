// docs/web/js/content.js — Part 1: 章节元数据结构

// 每个 chapter: { id, group, title, sections: [{ id, title }] }
// group: 'tutorial' | 'reference'
// content 字段将在 Task 5 填充

const CHAPTERS = [
    // 教程
    { id: 'home', group: 'tutorial', title: '首页', sections: [] },
    { id: 'start', group: 'tutorial', title: '0. 起步', sections: [
        { id: 'what', title: '什么是 Glue' },
        { id: 'install', title: '安装与项目结构' },
        { id: 'hello', title: 'Hello World' },
        { id: 'fib', title: '第一个示例' },
    ]},
    { id: 'types', group: 'tutorial', title: '1. 基础类型与字面量', sections: [
        { id: 'scalars', title: '标量类型' },
        { id: 'int-rules', title: '整数规则' },
        { id: 'float', title: '浮点数' },
        { id: 'literals', title: '字面量' },
        { id: 'str', title: 'str 与 UTF-8' },
    ]},
    { id: 'vars', group: 'tutorial', title: '2. 变量与函数', sections: [
        { id: 'bindings', title: '变量绑定' },
        { id: 'functions', title: '函数定义' },
        { id: 'currying', title: '柯里化' },
        { id: 'lambda', title: 'Lambda 表达式' },
        { id: 'refs', title: '借用引用' },
    ]},
    { id: 'control', group: 'tutorial', title: '3. 控制流', sections: [
        { id: 'if', title: 'if 表达式' },
        { id: 'loops', title: '循环' },
        { id: 'range', title: 'Range 与迭代器' },
        { id: 'defer', title: 'defer 延迟执行' },
        { id: 'tco', title: '尾调用优化' },
    ]},
    { id: 'adt', group: 'tutorial', title: '4. 代数数据类型与模式匹配', sections: [
        { id: 'enum', title: '枚举' },
        { id: 'record', title: '记录' },
        { id: 'newtype', title: 'Newtype 与别名' },
        { id: 'generic-adt', title: '泛型 ADT' },
        { id: 'gadt', title: 'GADT' },
        { id: 'match', title: '模式匹配' },
    ]},
    { id: 'trait', group: 'tutorial', title: '5. Trait 特征', sections: [
        { id: 'define', title: '定义与实现' },
        { id: 'multi', title: '多 Trait 实现' },
        { id: 'bounds', title: '约束与特化' },
        { id: 'first-class', title: '一等 Trait 值' },
    ]},
    { id: 'nullable', group: 'tutorial', title: '6. 可空类型与错误处理', sections: [
        { id: 'nullable', title: 'T? 可空类型' },
        { id: 'operators', title: '操作符' },
        { id: 'propagation', title: '? 传播' },
        { id: 'throw', title: 'Throw<T,E> 类型' },
        { id: 'custom-error', title: '自定义错误' },
        { id: 'strategy', title: '策略对照' },
    ]},
    { id: 'cast', group: 'tutorial', title: '7. 类型转换', sections: [
        { id: 'cast-builder', title: 'cast 构建器' },
        { id: 'builtin-cast', title: '内建转换函数' },
        { id: 'rules', title: '转换规则' },
    ]},
    { id: 'concurrency', group: 'tutorial', title: '8. 并发编程', sections: [
        { id: 'async', title: 'async fun 异步函数' },
        { id: 'capture', title: '参数捕获' },
        { id: 'channel', title: 'Channel 通道' },
        { id: 'select', title: 'select 多路复用' },
        { id: 'atomic', title: 'Atomic<T> 原子类型' },
        { id: 'safety', title: '并行安全' },
    ]},
    { id: 'modules', group: 'tutorial', title: '9. 模块系统与标准库', sections: [
        { id: 'file-module', title: '文件即模块' },
        { id: 'visibility', title: '可见性' },
        { id: 'import', title: 'import 导入' },
        { id: 'stdlib', title: '标准库' },
    ]},
    // 参考
    { id: 'r1-cheatsheet', group: 'reference', title: 'R1. 语法速查表', sections: [] },
    { id: 'r2-types', group: 'reference', title: 'R2. 类型系统参考', sections: [] },
    { id: 'r3-builtins', group: 'reference', title: 'R3. 内建函数参考', sections: [] },
    { id: 'r4-stdlib', group: 'reference', title: 'R4. 标准库 API', sections: [] },
    { id: 'r5-philosophy', group: 'reference', title: 'R5. 设计哲学', sections: [] },
];

// docs/web/js/content.js — Part 2: 内容数据（将在 Task 7-10 填充）

const CONTENT = {
    // home 在 main.js 的 renderHome() 中处理

    // ── 第 0 章 起步 ──────────────────────────────────────────
    start: {
        title: '0. 起步',
        sections: {
            what: {
                title: '什么是 Glue',
                blocks: [
                    { type: 'p', text: 'Glue 是一门通用编程语言，核心目标是让并行编程变得安全、自然、高效。它采用函数式范式，通过类型系统和运行时的协同设计，在编译期追踪空值和错误、在运行时保证并行安全。' },
                    { type: 'p', text: '三条核心设计哲学：' },
                    { type: 'ul', items: [
                        '**组合优于继承** — 通过 ADT + Trait 组合行为，不提供继承机制',
                        '**显式优于隐式** — 空值和错误通过类型系统显式标注，`?` 操作符显式传播，类型转换必须显式',
                        '**运行时并行安全** — 并行安全由运行时架构保证，无需用户手动管理',
                    ]},
                ],
            },
            install: {
                title: '安装与项目结构',
                blocks: [
                    { type: 'p', text: 'Glue 以项目为单位组织代码。项目根由清单文件 `glue.toml` 标识，源码放在 `src/` 下，入口约定为 `src/Main.glue` 的 `fun main(): void`。' },
                    { type: 'code', code: 'myapp/\n├── glue.toml          // 项目清单\n└── src/\n    ├── Main.glue      // 入口模块\n    └── ...', filename: '项目结构' },
                    { type: 'code', code: 'name = "myapp"\nversion = "0.1.0"\nentry = "src/Main.glue"', filename: 'glue.toml' },
                    { type: 'table', headers: ['命令', '说明'], rows: [
                        ['`glue init [name]`', '脚手架新项目（目标须为空目录或不存在，不存在的目录会被自动创建）'],
                        ['`glue run`', '编译并运行当前项目'],
                        ['`glue debug`', '诊断模式运行（内存泄漏检查 + 运行时错误位置追踪）'],
                        ['`glue run --profile`', '运行后输出完整管线性能概览（`debug` 也可用）'],
                        ['`--profile-json=<path>`', '将性能报告以 JSON 写入文件（隐含 `--profile`）'],
                        ['`--profile-interval=<us>`', '设置采样间隔，单位微秒（默认 1000）'],
                    ]},
                    { type: 'p', text: '`run`/`debug` 从当前目录向上查找 `glue.toml` 定位项目根。错误位置追踪（file:line:column）在所有模式下均可用，`debug` 额外提供内存泄漏检查。' },
                ],
            },
            hello: {
                title: 'Hello World',
                blocks: [
                    { type: 'code', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    println("Hello, Glue!")\n}', filename: 'src/Main.glue' },
                    { type: 'p', text: '`fun main(): void` 是程序入口。所有函数声明必须显式标注返回类型（无返回值用 `: void`），省略返回类型是编译错误。`println` 从 `std.io.Console` 模块导入。' },
                    { type: 'p', text: '运行：' },
                    { type: 'code', code: '$ glue run\nHello, Glue!', filename: '终端' },
                ],
            },
            fib: {
                title: '第一个示例',
                blocks: [
                    { type: 'p', text: '用递归 + match 实现斐波那契，演示函数定义、模式匹配和递归：' },
                    { type: 'code', code: 'import std.io.Console.{println}\n\nfun fib(n: i64): i64 {\n    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }\n}\n\nfun main(): void {\n    println(fib(10))   // 55\n    println(fib(20))   // 6765\n}', filename: 'src/Main.glue' },
                    { type: 'p', text: '块最后一个表达式自动作为返回值，`return` 用于提前返回。整数溢出会 panic，没有 wrap around 语义。' },
                ],
            },
        },
    },

    // ── 第 1 章 基础类型与字面量 ────────────────────────────────
    types: {
        title: '1. 基础类型与字面量',
        sections: {
            scalars: {
                title: '标量类型',
                blocks: [
                    { type: 'table', headers: ['类型', '含义', '备注'], rows: [
                        ['`i8`..`i128`', '有符号整数', '8 至 128 位'],
                        ['`u8`..`u128`', '无符号整数', '8 至 128 位'],
                        ['`isize`/`usize`', '平台相关整数', '64 位平台 = 8 字节；usize 用于数组索引、len() 返回'],
                        ['`f16`/`f32`/`f64`/`f128`', '浮点数', 'IEEE 754 各种精度'],
                        ['`bool`', '布尔', '`true` / `false`'],
                        ['`char`', 'Unicode 标量值', '4 字节，字面量用单引号'],
                        ['`str`', '字符串', 'UTF-8 编码'],
                        ['`void`', '单位类型', '表示没有有意义的值'],
                    ]},
                ],
            },
            'int-rules': {
                title: '整数规则',
                blocks: [
                    { type: 'p', text: '整数溢出在所有构建模式下都会触发运行时错误（error.Overflow），没有 wrap around 语义。' },
                    { type: 'p', text: '无后缀无标注的整数字面量默认推断为 `i32`，不按值大小选择最小类型。推断优先级：后缀 > 上下文期望类型 > 固定默认 `i32`。' },
                    { type: 'code', code: 'val a = 42          // i32（默认整型）\nval b = 42i32       // 显式后缀\nval c: i32 = 42     // 标注提升\nval d: u8 = 200     // 上下文提升为 u8', filename: 'example.glue' },
                    { type: 'tip', text: '`100i8 + 100i8` 两个 i8 相加结果 200 溢出 → 运行时错误；需更大范围请加后缀或标注。注意 `100 + 100` 默认为 i32，不会溢出。' },
                    { type: 'p', text: '上下文提升：数组索引、`for i in 0..N` Range、与 usize/isize 比较/赋值位置自动提升为 usize。' },
                ],
            },
            float: {
                title: '浮点数',
                blocks: [
                    { type: 'p', text: '浮点数没有 NaN（产生 NaN 的运算如 `0.0/0.0` 触发运行时错误）。Infinity 存在且为合法值（IEEE 754 标准行为）：`1.0/0.0` 产生 `+Inf` 而非错误。' },
                    { type: 'p', text: '需要"无效/无穷"时使用 `f64?` 或 `Throw<f64, Error>` 显式表达。' },
                    { type: 'p', text: '浮点字面量推断优先级：后缀 > 上下文期望类型 > 固定默认 `f32`。`0.5` 和 `3.14` 均为 `f32`。' },
                ],
            },
            literals: {
                title: '字面量',
                blocks: [
                    { type: 'code', code: '42              // 整数，默认 i32\n42i32           // 显式后缀\n3.14            // 浮点，默认 f32\n3.14f32         // 显式浮点后缀\n0xFF  0o77  0b1010  1_000_000   // 进制前缀 + 下划线\n\'a\'             // char\n\'\\u{1F600}\'     // char Unicode 转义\n"hello"         // str\n"hello {name}"  // 字符串插值\n{{literal}}     // 转义花括号\n[1, 2, 3]       // 数组\n(name: "Alice", age: 30)  // 记录', filename: 'example.glue' },
                    { type: 'p', text: '字符串插值 `{expr}` 自动转换为 `str`；字符串转义序列：`\\n`/`\\t`/`\\r`/`\\"`/`\\\\`/`\\{`/`\\}`。char 字面量还支持 `\\0`（空字符）和 `\\u{HEX}`（Unicode 码点）。' },
                ],
            },
            str: {
                title: 'str 与 UTF-8',
                blocks: [
                    { type: 'p', text: '`str` 是 UTF-8 编码字符串。迭代产生 `char`；`len()` 返回 Unicode 标量值数量（非字节数）；索引是 O(n) 操作（变长编码）。' },
                    { type: 'code', code: 'val s = "héllo"\nprintln(s.len())     // 5（字符数）\nfor ch in s {         // 迭代 char\n    println(ch)\n}\nval c = s[cast(0).to(usize)]  // 索引须 usize', filename: 'example.glue' },
                    { type: 'warn', text: '数组索引必须为 `usize`，整型变量须用 `cast(i).to(usize)` 转换。' },
                ],
            },
        },
    },

    // ── 第 2 章 变量与函数 ──────────────────────────────────────
    vars: {
        title: '2. 变量与函数',
        sections: {
            bindings: {
                title: '变量绑定',
                blocks: [
                    { type: 'code', code: 'val x = 42              // 不可变（默认）\nvar count: i32 = 0      // 可变，显式类型\ncount = count + 1       // 重新赋值\ncount += 1              // 复合赋值\nval maybe: i32? = null  // 可空标注', filename: 'example.glue' },
                    { type: 'p', text: '`val` 不可变，`var` 可变。类型推断大多数场景无需标注。`var`/`val` 仅用于局部变量，不用于函数参数。' },
                ],
            },
            functions: {
                title: '函数定义',
                blocks: [
                    { type: 'code', code: 'fun add(a: i32, b: i32): i32 { a + b }\nfun double(x: i32): i32 { return x * 2 }   // 显式 return\nasync fun fetch(url: str): str { ... }      // 异步函数', filename: 'example.glue' },
                    { type: 'p', text: '块最后一个表达式自动作为返回值，`return` 用于提前返回。所有函数声明必须显式标注返回类型，无返回值用 `: void`。' },
                    { type: 'p', text: '函数参数语义：标量与复合类型默认均按值深拷贝传递（修改不影响外部）。只有显式使用 `&T`/`*T` 引用参数才按引用共享（字段修改可见外部）。部分应用（柯里化）时同样执行深拷贝，修改原值不影响已绑定的部分应用结果。' },
                ],
            },
            currying: {
                title: '柯里化',
                blocks: [
                    { type: 'p', text: 'Glue 默认柯里化：' },
                    { type: 'code', code: 'fun add(a: i32, b: i32): i32 { a + b }\n\nval add5 = add(5)    // 部分应用，add5: (i32) -> i32\nval result = add5(3) // => 8', filename: 'example.glue' },
                    { type: 'warn', text: '禁止链式调用 `f(a)(b)` — 部分应用的结果必须绑定到变量后再调用，需拆分为 `val tmp = f(a); tmp(b)`。' },
                ],
            },
            lambda: {
                title: 'Lambda 表达式',
                blocks: [
                    { type: 'p', text: '两种 Lambda 语法：' },
                    { type: 'code', code: 'val f = fun(x) { x + 1 }       // fun 表达式\nval g = (x) => x + 1           // 箭头 lambda\nval h = fun(x: i32) { x * 2 }  // 带类型标注', filename: 'example.glue' },
                    { type: 'p', text: '闭包捕获 var 按引用共享：' },
                    { type: 'code', code: 'var n: i32 = 0\nval inc = fun() { n = n + 1 }\ninc()\ninc()\nprintln(n)   // 2', filename: 'example.glue' },
                ],
            },
            refs: {
                title: '借用引用',
                blocks: [
                    { type: 'p', text: '`&T` 借用引用允许标量获得引用语义：' },
                    { type: 'code', code: 'fun increment(r: &i32): void {\n    *r = *r + 1\n}\n\nval count: i32 = 5\nincrement(&count)\nprintln(count)   // 6', filename: 'example.glue' },
                    { type: 'p', text: '`&expr` 取引用，`*expr` 解引用，`*ref = value` 通过引用写入。' },
                    { type: 'p', text: '`*T` 裸指针绕过 RC，预留用于 FFI 场景，普通代码不应使用。' },
                ],
            },
        },
    },

    // ── 第 3 章 控制流 ──────────────────────────────────────────
    control: {
        title: '3. 控制流',
        sections: {
            if: {
                title: 'if 表达式',
                blocks: [
                    { type: 'p', text: '`if` 是表达式，有返回值：' },
                    { type: 'code', code: 'val desc = if x > 0 { "positive" } else { "non-positive" }', filename: 'example.glue' },
                    { type: 'warn', text: '`if`/`while`/`for`/`match` 的条件禁止以 `(` 开头。' },
                ],
            },
            loops: {
                title: '循环',
                blocks: [
                    { type: 'code', code: 'loop {\n    if input == "quit" { break }\n}\n\nwhile condition() { do_work() }\n\nfor i in 0..100 { println(i) }     // 开区间\nfor i in 1..=10 { println(i) }     // 闭区间\nfor item in [1, 2, 3] { ... }      // 数组迭代\nfor ch in "héllo" { ... }          // 字符串迭代', filename: 'example.glue' },
                    { type: 'p', text: '`break` 跳出循环，`continue` 进入下一次迭代。' },
                ],
            },
            range: {
                title: 'Range 与迭代器',
                blocks: [
                    { type: 'p', text: '`start..end` 开区间，`start..=end` 闭区间。元素类型由推断决定，迭代/索引上下文默认 usize。' },
                    { type: 'p', text: '`for item in collection` 编译为向量化 `vec_source` IR 节点，直接处理数组、Range 与 `str`，不走 `iterator()` 方法协议。`Iterable` trait 在类型系统中已声明，但当前编译器不强制要求实现。内建可迭代：`T[]`（元素）、`str`（char）、Range。' },
                    { type: 'code', code: '// for item in list 实际编译为向量化执行：\n//   vec_source(list) 生成元素向量，循环体对每个元素执行\n// （逻辑上等价于：）\nloop {\n    match iter.next() {\n        null => break,\n        item => body,\n    }\n}', filename: '编译模型' },
                ],
            },
            defer: {
                title: 'defer 延迟执行',
                blocks: [
                    { type: 'p', text: '`defer` 注册延迟操作，作用域退出时 LIFO 执行，覆盖正常返回和 throw 两种路径。同步函数中 panic（`error.Panic`）会跳过 defer 直接传播。异步函数的 DeferTable 已在编译期构建，但运行时尚未接入执行路径，因此 async 函数中的 defer 当前不会被触发。' },
                    { type: 'code', code: 'fun process(): Throw<void, FileError> {\n    val f = open(path)?\n    defer close(f)\n    work(f)?\n}', filename: 'example.glue' },
                    { type: 'code', code: 'fun lifo(): void {\n    defer println("A")\n    defer println("B")\n    defer println("C")\n    println("body")\n}\n// 输出: body C B A', filename: 'example.glue' },
                ],
            },
            tco: {
                title: '尾调用优化',
                blocks: [
                    { type: 'p', text: 'Glue 对自递归尾调用保证 TCO——复用当前帧，不增长调用栈。相互递归的 trampoline 机制目前仅有消费端脚手架，尚未接入检测与跳转，因此互递归尾调用仍会增长调用栈。' },
                    { type: 'code', code: 'fun count(n: i32, acc: i32): i32 {\n    if n == 0 { acc }\n    else { count(n - 1, acc + 1) }   // 尾递归，不增栈\n}', filename: 'example.glue' },
                ],
            },
        },
    },

    // ── 第 4 章 ADT 与 Pattern Matching ────────────────────────
    adt: {
        title: '4. 代数数据类型与模式匹配',
        sections: {
            enum: {
                title: '枚举',
                blocks: [
                    { type: 'p', text: '每个变体必须以 `|` 起始（含首个）：' },
                    { type: 'code', code: 'type Shape =\n    | Circle(radius: f64)\n    | Rectangle(width: f64, height: f64)\n\ntype Tree = | Leaf | Node(i32, Tree, Tree)', filename: 'example.glue' },
                ],
            },
            record: {
                title: '记录',
                blocks: [
                    { type: 'p', text: '字段必须命名，无匿名元组：' },
                    { type: 'code', code: 'type User = (name: str, age: i32, email: str?)\n\nval u = (name: "Alice", age: 30, email: null)\nprintln(u.name)   // Alice', filename: 'example.glue' },
                    { type: 'warn', text: '`(1, 2)` 会报错，必须用命名字段。' },
                ],
            },
            newtype: {
                title: 'Newtype 与别名',
                blocks: [
                    { type: 'code', code: 'type UserId = UserId(i32)      // Newtype，类型安全包装\ntype IntList = List<i32>       // 别名，不创建新类型\ntype Name = str               // 别名', filename: 'example.glue' },
                    { type: 'tip', text: 'Newtype 提供类型级别的安全区分，但运行时并非零开销——值会被包装为堆分配的 `NewtypeValue` 对象，模式匹配时执行解包。别名（alias）不创建新类型，直接引用目标类型。' },
                ],
            },
            'generic-adt': {
                title: '泛型 ADT',
                blocks: [
                    { type: 'code', code: 'type List<T> =\n    | Nil\n    | Cons(T, List<T>)\n\ntype Pair<A, B> = Pair(first: A, second: B)\n\ntype Tree<T> = | Leaf | Node(T, Tree<T>, Tree<T>)', filename: 'example.glue' },
                    { type: 'p', text: '泛型高阶函数示例：' },
                    { type: 'code', code: 'fun map<T, U>(l: Lst<T>, f: (T) -> U): Lst<U> {\n    match l {\n        Nil => Nil\n        Cons(x, t) => Cons(f(x), map(t, f))\n    }\n}', filename: 'example.glue' },
                ],
            },
            gadt: {
                title: 'GADT',
                blocks: [
                    { type: 'p', text: '构造器可返回不同类型参数，match 时编译器推导局部类型等式：' },
                    { type: 'code', code: 'type Expr<T> =\n    | IntLit(i32)                       : Expr<i32>\n    | BoolLit(bool)                     : Expr<bool>\n    | Add(Expr<i32>, Expr<i32>)         : Expr<i32>\n    | If(Expr<bool>, Expr<T>, Expr<T>)  : Expr<T>', filename: 'example.glue' },
                ],
            },
            match: {
                title: '模式匹配',
                blocks: [
                    { type: 'p', text: '必须穷举检查。支持字面量、构造器解构、守卫条件、或模式、通配符：' },
                    { type: 'code', code: 'fun classify(n: i32): str {\n    match n {\n        0 => "zero",\n        n if n < 0 => "negative",\n        1 | 2 | 3 => "small",\n        _ => "other",\n    }\n}', filename: 'example.glue' },
                    { type: 'code', code: '// 嵌套解构\nfun deepNest(t: Tree): i32 {\n    match t {\n        Node(_, Node(x, _, _), Node(y, _, _)) => x + y\n        Node(v, Leaf, Leaf) => v\n        Node(v, _, _) => v * 100\n        Leaf => -1\n    }\n}', filename: 'example.glue' },
                    { type: 'code', code: '// 记录模式 + 守卫\nfun quadrant(p: Pt): str {\n    match p {\n        Pt(0, 0) => "origin"\n        Pt(x, y) if x > 0 && y > 0 => "Q1"\n        _ => "other"\n    }\n}', filename: 'example.glue' },
                    { type: 'p', text: '`null` 作为模式直接匹配可空值；`Ok(v)`/`Error(e)` 匹配 Throw。' },
                ],
            },
        },
    },

    // ── 第 5 章 Trait ───────────────────────────────────────────
    trait: {
        title: '5. Trait 特征',
        sections: {
            define: {
                title: '定义与实现',
                blocks: [
                    { type: 'p', text: 'Trait 是唯一的接口抽象机制。定义时含关联类型和默认方法：' },
                    { type: 'code', code: 'trait Iterator {\n    type Item\n    fun next(self): Item?\n    fun map<U>(f: (Item) -> U): Iterator<U>   // 泛型方法\n}\n\ntrait Printable {\n    fun format(self): str\n    fun print(self): str { "<" + self.format() + ">" }  // 默认方法\n}', filename: 'example.glue' },
                    { type: 'p', text: 'type 定义时内联实现，`override` 覆写默认方法：' },
                    { type: 'code', code: 'type MyInt: Show = MyInt(value: i32) {\n    fun show(self): str { cast(self.value).to(str) }\n}\n\ntype FileError: Error = FileError(msg: str) {\n    override fun type_name(self): str { "file error" }\n}', filename: 'example.glue' },
                    { type: 'tip', text: '实现 trait 时必须有大括号 `{ }`（即使全用默认实现）。关联类型只能在 trait 体中声明，不能在 type 实现块中定义。' },
                ],
            },
            multi: {
                title: '多 Trait 实现',
                blocks: [
                    { type: 'p', text: '多个 trait 必须用括号：' },
                    { type: 'code', code: 'type Point: (Show, Comparable) = Point(x: i32, y: i32) {\n    fun show(self): str { ... }\n    fun compare(self, other): Ordering { ... }\n}', filename: 'example.glue' },
                ],
            },
            bounds: {
                title: '约束与特化',
                blocks: [
                    { type: 'warn', text: '关键区别：trait 约束在 `<>` 内用 `: TraitName`；`with` 的含义取决于位置——在类型声明中用于类型特化（`with T: 具体类型`），在函数声明和类型参数中用于追加 trait 约束（`with TraitName`）。' },
                    { type: 'code', code: '// trait 约束（在 <> 内）\nfun max<T: Comparable>(a: T, b: T): T { ... }\nfun f<T: (Show, Eq)>(x: T): str { ... }\ntype Box<T: Show>: Show = Box(value: T) { ... }\n\n// 类型特化（with 在类型声明中：T: 具体类型）\ntype Vec<T>: IntOps with T: i32 = ...\n\n// 追加 trait 约束（with 在函数声明中：TraitName）\nfun process<T>(x: T): void with Serializable { ... }', filename: 'example.glue' },
                    { type: 'p', text: '运算符不可重载。`==`/`!=` 对所有类型自动派生为递归值相等，不可覆盖。' },
                ],
            },
            'first-class': {
                title: '一等 Trait 值',
                blocks: [
                    { type: 'p', text: 'Trait 可作为运行时值传递。文件模块自动转换为 Trait 值：' },
                    { type: 'code', code: '// Store/Memory.glue\npub fun put(key: str, value: str): void { ... }\npub fun get(key: str): str { ... }\n\n// Main.glue\ntrait KVStore {\n    fun put(key: str, value: str): void\n    fun get(key: str): str\n}\n\nfun run(s: KVStore): void {\n    s.put("hello", "world")\n    println(s.get("hello"))\n}\n\nfun main(): void {\n    run(Store.Memory)   // 文件模块自动转为 Trait 值\n}', filename: 'example.glue' },
                    { type: 'p', text: '内联 trait 值（匿名实现）：' },
                    { type: 'code', code: 'val logger: Logger = trait {\n    fun log(msg): void { println(msg) }\n}', filename: 'example.glue' },
                ],
            },
        },
    },

    // ── 第 6 章 Nullable 与错误处理 ────────────────────────────
    nullable: {
        title: '6. 可空类型与错误处理',
        sections: {
            nullable: {
                title: 'T? 可空类型',
                blocks: [
                    { type: 'p', text: '`T?` 表示 `T` 类型的值或 `null`，是类型系统内建特性，不是语法糖。' },
                    { type: 'code', code: 'val a: i32 = 42          // 不可空\nval b: i32? = null       // 可空\nval d: i32 = null        // 编译错误：i32 不可空', filename: 'example.glue' },
                    { type: 'p', text: '`T??` 扁平化为 `T?`。`T?` 与 `T` 协变。' },
                ],
            },
            operators: {
                title: '操作符',
                blocks: [
                    { type: 'code', code: 'name?.len()              // 安全调用 → i32?\nname?.owner?.addr?.city // 深链 ?.\nname?.len() ?? 0         // Elvis 默认值 → i32\nname!.len()              // 非空断言（null 时返回零值，不 panic；调用方应先判空）\nval x = name?            // ? 传播（外层须返回 U?）', filename: 'example.glue' },
                    { type: 'code', code: '// 链式 Elvis\nval first = a ?? b ?? c ?? -1', filename: 'example.glue' },
                    { type: 'p', text: '使用可空值前必须消除空值可能性（match 收窄 / if 收窄）：' },
                    { type: 'code', code: 'fun greet(name: str?): str {\n    match name {\n        null => "Hello, stranger",\n        n => "Hello, " + n,    // n: str（已收窄）\n    }\n}', filename: 'example.glue' },
                ],
            },
            propagation: {
                title: '? 传播',
                blocks: [
                    { type: 'p', text: '`?` 作为表达式后缀操作符，提前传播"坏值"：' },
                    { type: 'code', code: 'fun greet(): str? {\n    val name = get_name()?    // null 时提前返回 null\n    "Hello, " + name\n}\n\nfun read_config(): Throw<Config, Error> {\n    val content = read_file("config.json")?  // throw 时提前传播\n    parse_json(content)?\n}', filename: 'example.glue' },
                    { type: 'warn', text: '`?` 不跨 Nullable 和 Throw 自动转换（null 与 error 语义不同）。`Throw<T?, E>` 需两步处理——先 Throw，再 Nullable。' },
                ],
            },
            throw: {
                title: 'Throw<T,E> 类型',
                blocks: [
                    { type: 'p', text: '`Throw<T, E>` 是内建包装类型：成功返回 `T`，失败抛出 `E`。值有两种状态 `Ok(value)` 与 `Error(e)`。' },
                    { type: 'code', code: 'fun read(path: str): Throw<str, Error> {\n    if bad { throw Error("failed") }\n    Ok("content")\n}\n\nmatch read("f") {\n    Ok(content) => content\n    Error(e) => e.message()\n}', filename: 'example.glue' },
                    { type: 'p', text: '`Error` 是内建 Trait，所有可被 `throw` 抛出的类型必须是 `Error` 的子类型。在返回 `Throw<T, E>` 的函数中，`throw` 构造可被 `match` 捕获的错误值；在非 `Throw` 返回的函数中使用 `throw` 不会报编译错误，但会编译为 `halt_throw` 硬终止（`error.Thrown`，不可被 `match` 捕获）。' },
                ],
            },
            'custom-error': {
                title: '自定义错误',
                blocks: [
                    { type: 'code', code: 'type NotFound: Error = NotFound(msg: str) {\n    override fun type_name(self): str { "not found" }\n}\n\ntype Timeout: Error = Timeout(msg: str) {\n    override fun type_name(self): str { "timeout" }\n}\n\nfun lookup(id: i32): Throw<str, Error> {\n    if id < 0 { throw NotFound("id " + cast(id).to(str)) }\n    if id == 0 { throw Timeout("slow") }\n    Ok("user-" + cast(id).to(str))\n}', filename: 'example.glue' },
                    { type: 'tip', text: '自定义错误类型 `<: Error`，错误类型之间没有子类型关系，但都可流入 `Throw<_, Error>`。`e.message()` 是方法调用。' },
                ],
            },
            strategy: {
                title: '策略对照',
                blocks: [
                    { type: 'table', headers: ['场景', '推荐机制'], rows: [
                        ['值可能不存在', '`T?`'],
                        ['操作可能失败，需要错误信息', '`Throw<T, E>`'],
                        ['错误类型明确需穷举', '`Throw<T, SpecificError>`'],
                        ['聚合多种错误', '`Throw<T, Error>`'],
                        ['并发任务中的错误', 'Channel 传递 `Throw<T, E>`'],
                    ]},
                ],
            },
        },
    },

    // ── 第 7 章 类型转换 ────────────────────────────────────────
    cast: {
        title: '7. 类型转换',
        sections: {
            'cast-builder': {
                title: 'cast 构建器',
                blocks: [
                    { type: 'code', code: 'cast(expr).to(T)        // wrap 语义：数值→数值截断/饱和；str→数值 和 f→f 窄化产生 Inf 时 panic\ncast(expr).try_to(T)    // 检查语义：返回 Throw<T, CastError>', filename: 'example.glue' },
                    { type: 'p', text: 'widening 始终合法（`i8→i16→i32→...`）。narrowing：i→i 窄化 `.to()` 按位截断（wrap），`.try_to()` 超范围返回 `Error(CastError)`；f→i 窄化 `.to()` 截断小数 + 饱和（NaN→0, ±Inf→min/max），`.try_to()` 遇 NaN/Inf/超范围返回 `Error(CastError)`（小数截断不报错）。' },
                ],
            },
            'builtin-cast': {
                title: '内建转换函数',
                blocks: [
                    { type: 'p', text: '`cast` 是唯一的内建类型转换函数。所有类型转换都通过 `cast(expr).to(T)` 或 `cast(expr).try_to(T)` 完成。' },
                    { type: 'code', code: '// widening\ncast(-42i8).to(i16)         // -42\ncast(-42i8).to(i32)         // -42\n\n// narrowing\ncast(300i32).to(i8)          // 44（300 - 256 = 44，截断）\n\n// int → float\ncast(42i32).to(f32)          // 42\n\n// float → int（截断向零）\ncast(3.14).to(i32)           // 3\ncast(-3.99).to(i32)          // -3\n\n// char ↔ int\nval c: char = \'A\'\ncast(c).to(i32)              // 65\ncast(97).to(char)            // a\n\n// 任意类型 → str\ncast(42).to(str)             // "42"', filename: 'example.glue' },
                ],
            },
            rules: {
                title: '转换规则',
                blocks: [
                    { type: 'table', headers: ['方向', '规则'], rows: [
                        ['`i→i`', '宽化：零/符号扩展；窄化：按位截断（wrap）'],
                        ['`f→f`', 'round-to-nearest；`.to()` 产生 Inf 时 panic'],
                        ['`f→i`', '截断小数（向零）+ 饱和（NaN→0, ±Inf→min/max）'],
                        ['`bool→int`', 'true=1, false=0'],
                        ['`int→bool`', '0=false, 非0=true'],
                        ['`char↔int`', 'u32 码点'],
                    ]},
                    { type: 'tip', text: '`cast(x).to(T)` 是 wrap 语义转换（str→数值 和 f→f 窄化产生 Inf 时 panic）。`cast(x).try_to(T)` 提供检查语义，超范围返回 `Error(CastError)`，可被 `match` 捕获。' },
                ],
            },
        },
    },

    // ── 第 8 章 并发编程 ────────────────────────────────────────
    concurrency: {
        title: '8. 并发编程',
        sections: {
            async: {
                title: 'async fun 异步函数',
                blocks: [
                    { type: 'p', text: 'Glue 采用 CSP（通信顺序进程）并发模型。`async fun` 定义异步函数，调用即启动一个并发任务，返回 `Async<T>`：' },
                    { type: 'code', snippet: 'async fun compute(): i64 { 7 * 6 }\n\nval s = compute()      // 立即返回 Async<i64>\nval r = s.await()      // 阻塞等待，r = 42', code: 'import std.io.Console.{println}\n\nasync fun compute(): i64 { 7 * 6 }\n\nfun do_other_work(): void { println("working...") }\n\nfun main(): void {\n    val s = compute()      // 立即返回 Async<i64>，任务已在后台执行\n    do_other_work()\n    val r = s.await()      // 阻塞等待，r = 42\n    println(r)\n\n    // 链式调用\n    val r2 = compute().await()\n    println(r2)\n}', filename: 'example.glue' },
                    { type: 'table', headers: ['方法', '阻塞', '说明'], rows: [
                        ['`await()`', '是', '等待完成并取结果'],
                        ['`status()`', '否', '查询状态码（0=Pending 1=Running 2=Completed 3=Cancelled 4=Failed）'],
                    ]},
                    { type: 'warn', text: '`Async<T>` 必须被消费——调用 `.await()` 取结果，否则编译错误（`unconsumed_async`）。当前实现中 `cancel()` 尚未接入 IR 编译，只能通过 `.await()` 消费。' },
                ],
            },
            capture: {
                title: '参数捕获',
                blocks: [
                    { type: 'p', text: 'async 函数的标量实参按值复制传递，引用类型（记录、数组）按指针浅拷贝传递（共享底层对象）。返回值在 `await` 时深拷贝回主线程：' },
                    { type: 'code', snippet: 'val s = incrCount(count)   // 标量按值复制\nprintln(s.await())          // 1\nprintln(count)              // 0（不变）', code: 'import std.io.Console.{println}\n\nasync fun incrCount(c: i64): i64 { c + 1 }\n\nfun main(): void {\n    var count = 0\n    val s = incrCount(count)   // 标量按值复制\n    println(s.await())          // 1\n    println(count)              // 0（标量按值复制，不变）\n}', filename: 'example.glue' },
                    { type: 'tip', text: '`Atomic<T>`、`Channel`、以及 `&T`/`*T` 引用参数均按引用共享底层内存，是跨任务共享可变状态的途径。其中 `Atomic<T>` 是共享简单标量可变状态的首选方式。' },
                ],
            },
            channel: {
                title: 'Channel 通道',
                blocks: [
                    { type: 'code', snippet: 'val ch = channel(10)        // 缓冲区容量 10\nch.send(42)\nval v = ch.recv()           // 阻塞接收\n\n// 方向类型\nval tx = ch.sender\nval rx = ch.receiver', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    val ch = channel(10)        // 缓冲区容量 10\n    ch.send(42)\n    val v = ch.recv()           // 阻塞接收\n    println(v)                  // 42\n\n    // 方向类型\n    val tx = ch.sender\n    val rx = ch.receiver\n    tx.send(1)\n    val x = rx.recv()\n    println(x)                  // 1\n}', filename: 'example.glue' },
                    { type: 'p', text: '关闭语义：`close()` 可在 Channel / Sender / Receiver 任一端调用（实现未限定为 Sender）；约定上推荐使用 Sender 端关闭。关闭后缓冲数据仍可读取；缓冲耗尽且已关闭时 `recv()` 返回 `null`。' },
                    { type: 'code', snippet: 'val ch2 = channel(10)\nch2.send(100)\nch2.sender.close()\nprintln(ch2.recv())   // 100\nprintln(ch2.recv())   // null（closed + drained）', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    val ch2 = channel(10)\n    ch2.send(100)\n    ch2.send(200)\n    ch2.sender.close()\n    println(ch2.recv())   // 100\n    println(ch2.recv())   // 200\n    println(ch2.recv())   // null（closed + drained）\n}', filename: 'example.glue' },
                ],
            },
            select: {
                title: 'select 多路复用',
                blocks: [
                    { type: 'code', snippet: 'select {\n    cha.recv() => println("from-a"),\n    chb.recv() => println("from-b"),\n    timeout(1000) => println("timeout"),\n}', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    val cha = channel(10)\n    val chb = channel(10)\n    cha.send("a")\n    chb.send("b")\n\n    select {\n        cha.recv() => println("from-a"),\n        chb.recv() => println("from-b"),\n        timeout(1000) => println("timeout"),\n    }\n}', filename: 'example.glue' },
                    { type: 'p', text: '绑定接收值：' },
                    { type: 'code', snippet: 'select {\n    ch.recv() => v => println("got " + cast(v).to(str)),\n}', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    val ch = channel(10)\n    ch.send(42)\n\n    select {\n        ch.recv() => v => println("got " + cast(v).to(str)),\n    }\n}', filename: 'example.glue' },
                    { type: 'p', text: '选择第一个就绪的分支执行。' },
                ],
            },
            atomic: {
                title: 'Atomic<T> 原子类型',
                blocks: [
                    { type: 'code', snippet: 'var counter = atomic 0i64\n\nasync fun incr(c: Atomic<i64>): void { c = c + 1 }\n\nval a1 = incr(counter)\na1.await()\nprintln(counter)         // 1', code: 'import std.io.Console.{println}\n\nvar counter = atomic 0i64\n\nasync fun incr(c: Atomic<i64>): void { c = c + 1 }\n\nfun main(): void {\n    val a1 = incr(counter)\n    a1.await()\n    println(counter)         // 1（共享底层内存）\n}', filename: 'example.glue' },
                    { type: 'p', text: '透明操作：仅复合赋值（`+=`/`-=`）由编译器翻译为原子 read-modify-write 操作。显式操作：`swap`（返回旧值）和 `cas`（比较并交换，返回 bool）。' },
                    { type: 'p', text: '显式操作：' },
                    { type: 'code', snippet: 'var atm = atomic 10\nprintln(atm.swap(20))    // 10（旧值）\nprintln(atm.cas(20, 30)) // true\nprintln(atm.cas(99, 40)) // false', code: 'import std.io.Console.{println}\n\nfun main(): void {\n    var atm = atomic 10\n    println(atm.swap(20))    // 10（旧值）\n    println(atm)             // 20\n    println(atm.cas(20, 30)) // true\n    println(atm)             // 30\n    println(atm.cas(99, 40)) // false\n    println(atm)             // 30（不变）\n}', filename: 'example.glue' },
                ],
            },
            safety: {
                title: '并行安全',
                blocks: [
                    { type: 'table', headers: ['机制', '保证', '适用场景'], rows: [
                        ['值语义 + 按值复制', '标量无共享引用', '默认，覆盖绝大多数场景'],
                        ['线程隔离的分配器', 'worker 线程本地堆', '所有并发代码'],
                        ['Channel', '安全通信', '任务间数据传递'],
                        ['`Atomic<T>`', '原子操作共享', '跨任务共享简单可变状态'],
                        ['`&T`/`*T` 引用参数', '按引用共享', 'worker 直接修改主线程对象'],
                    ]},
                    { type: 'p', text: '并行安全由运行时架构保证，无需用户手动管理。' },
                ],
            },
        },
    },

    // ── 第 9 章 模块系统与标准库 ────────────────────────────────
    modules: {
        title: '9. 模块系统与标准库',
        sections: {
            'file-module': {
                title: '文件即模块',
                blocks: [
                    { type: 'p', text: '每个 `.glue` 文件是一个模块。`pack.glue` 是目录模块的入口文件；无 `pack.glue` 的目录被整体忽略；未在 `pack.glue` 声明的文件不参与编译。' },
                    { type: 'code', code: '// pack.glue\npub pack Map            // 公开子模块（成员合并到父命名空间）\npack Internal           // 私有子模块', filename: 'pack.glue' },
                ],
            },
            visibility: {
                title: '可见性',
                blocks: [
                    { type: 'p', text: '默认私有：`fun`/`val`/`var`/`type`/`trait`/`pack` 默认仅当前模块可见，跨模块访问必须 `pub`。' },
                    { type: 'p', text: '`pub type` 公开类型名及其构造器；当前实现没有抽象/不透明类型机制（构造器不隐藏）。' },
                ],
            },
            import: {
                title: 'import 导入',
                blocks: [
                    { type: 'code', code: 'import Collections.{Map, insert, empty}       // 选择性导入（须用 .{} 语法）\nimport Collections.Map                         // 导入整个模块（所有公开成员）\nimport Collections.{Map as CMap}               // 别名\npub import Collections.{Map}                   // 重新导出', filename: 'example.glue' },
                    { type: 'p', text: '选择性导入须使用 `.{}` 语法（`import M.{a, b}`）。`import M.Name` 整体导入已包含所有公开成员，不支持 `import M.*` 通配符。模块循环依赖是编译错误（依赖必须是 DAG）。' },
                    { type: 'code', code: '// 短名导入\nimport std.time.Calendar.{ is_leap_year, days_in_month as dim }\nimport std.io.Console.{println}\n\nfun main(): void {\n    println(is_leap_year(2024))   // true\n    println(dim(2026, 1))         // 31\n}', filename: 'example.glue' },
                ],
            },
            stdlib: {
                title: '标准库',
                blocks: [
                    { type: 'p', text: '标准库用 Glue 自身编写，`@embedFile` 内嵌进二进制，零安装。`import std.<pack>.<mod>` 总是从内嵌表加载；当前实现不支持用项目内同名文件覆盖标准库。' },
                    { type: 'table', headers: ['模块', '内容'], rows: [
                        ['`std/io`', '`Console`（println/print/eprintln/eprint/scanln/scan）、`File`（open/read/write/close/stat/seek）、`Fs`（read_file/write_file/append_file）、`Dir`（list/create/remove/walk）、`Path`（路径操作）、`Buffered`（BufReader/BufWriter）'],
                        ['`std/time`', '`Instant`（now/elapsed/duration_since）、`SystemTime`（now/to_utc/to_local）、`DateTime`（format/to_iso8601）、`Duration`（from_secs/as_nanos）、`Calendar`（is_leap_year/days_in_month/weekday_of）、`Timer`（sleep/ticker/timeout）'],
                        ['`std/net`', '`Addr`（Ipv4Addr/Ipv6Addr/SocketAddr）、`TcpListener`（bind/accept）、`TcpStream`（connect/read/write/read_until）、`UdpSocket`（bind/send_to/recv_from）、`Dns`（resolve）'],
                        ['`std/reflect`', '`Reflect`（format — 任意值转字符串，println 底层机制）'],
                    ]},
                    { type: 'p', text: '内建错误类型（`CastError`、`IOError`、`TimeError`）由编译器在启动时自动注册到全局环境，无需 import 即可使用。' },
                    { type: 'code', code: 'import std.io.Console.{println}\nimport std.time.Calendar.{is_leap_year}\n\nfun main(): void {\n    println(is_leap_year(2024))   // true\n    println(is_leap_year(1900))   // false\n}', filename: 'example.glue' },
                ],
            },
        },
    },

    // ── 参考部分 R1-R5 ──────────────────────────────────────────
    'r1-cheatsheet': {
        title: 'R1. 语法速查表',
        sections: {},
        sectionOrder: [],
        intro: [
            { type: 'h3', text: '关键字', id: 'keywords' },
            { type: 'code', code: 'fun async type trait override pack pub import with as\nval var\nmatch if else\nchannel select atomic\nloop for in while break continue return\nthrow defer lazy\ntrue false null', filename: '关键字' },
            { type: 'h3', text: '运算符（优先级高→低）', id: 'operators' },
            { type: 'code', code: '?.  ·  ? !  ·  一元(- ! ~)  ·  * / %  ·  + - ++  ·  .. ..=\n·  比较(< > <= >=)  ·  相等(== != === !==)  ·  << >>  ·  &  ·  ^  ·  |\n·  &&  ·  ||  ·  ??', filename: '优先级' },
            { type: 'table', headers: ['运算符', '含义'], rows: [
                ['`+ - * / %`', '算术'],
                ['`++`', '数组拼接（非自增！自增用 `x += 1`）'],
                ['`== !=`', '递归值相等（自动派生，不可覆盖）'],
                ['`=== !==`', '引用相等（比较内存地址）'],
                ['`&& || !`', '逻辑'],
                ['`& | ^ ~ << >>`', '位运算'],
                ['`?. ?? ! ?`', 'Nullable'],
                ['`.. ..=`', 'Range'],
                ['`...`', '记录扩展'],
                ['`=> ->`', 'match 分支 / 函数类型'],
            ]},
            { type: 'h3', text: '复合赋值', id: 'compound' },
            { type: 'code', code: '+= -= *= /= %=  &= |= ^= <<= >>=', filename: '复合赋值' },
            { type: 'h3', text: '关键规则速记', id: 'rules' },
            { type: 'table', headers: ['规则', '说明'], rows: [
                ['默认不可变', '`val` 默认，`var` 显式可变'],
                ['枚举前导 `|`', '每个变体（含首个）必须以 `|` 起始'],
                ['多 trait 用括号', '`type X: (T1, T2)` / `<T: (A, B)>`'],
                ['trait 约束在 `<>`', '`<T: Trait>`；`with` 在类型声明中用于特化，在函数声明中用于追加 trait 约束'],
                ['记录字段命名', '无匿名元组'],
                ['Error 用方法', '`e.message()` 而非 `e.message`'],
                ['块尾即返回', '最后表达式自动返回，`return` 用于提前返回'],
                ['函数须标返回类型', '所有函数必须显式标注返回类型，无返回值用 `: void`'],
                ['无自增运算符', '用 `x += 1`，`++` 仅数组拼接'],
                ['条件禁止括号', '`if`/`while`/`for`/`match` 条件不能以 `(` 开头'],
                ['禁止链式调用', '`f(a)(b)` 报错，需拆分'],
                ['并发用 async', '`async fun` 返回 `Async<T>`，须 `.await()` 消费（`cancel()` 尚未接入）'],
                ['`==` 值相等', '递归结构相等，自动派生；引用相等用 `===`'],
                ['整数溢出错误', '所有构建模式触发运行时错误，无 wrap 语义'],
            ]},
        ],
    },

    'r2-types': {
        title: 'R2. 类型系统参考',
        sections: {},
        sectionOrder: [],
        intro: [
            { type: 'h3', text: '基础类型完整表', id: 'basic-types' },
            { type: 'table', headers: ['类型', '位宽', '用途'], rows: [
                ['`i8`..`i128`', '8/16/32/64/128', '有符号整数'],
                ['`u8`..`u128`', '8/16/32/64/128', '无符号整数'],
                ['`isize`/`usize`', '平台位宽', 'isize 平台相关；usize 用于数组索引、len() 返回、Range 步进'],
                ['`f16`/`f32`/`f64`/`f128`', '16/32/64/128', 'IEEE 754 浮点'],
                ['`bool`', '1', '布尔'],
                ['`char`', '32', 'Unicode 标量值'],
                ['`str`', '变长', 'UTF-8 字符串'],
                ['`void`', '0', '单位类型'],
            ]},
            { type: 'h3', text: '运算符语义', id: 'op-semantics' },
            { type: 'table', headers: ['运算符', '语义'], rows: [
                ['`==` / `!=`', '递归值相等（结构相等），编译器自动派生，用户不可覆盖'],
                ['`===` / `!==`', '引用相等，比较内存地址；标量退化为 `==`/`!=`'],
                ['`++`', '数组拼接 `[T] ++ [T] -> [T]`（新数组，深拷贝）'],
                ['`..` / `..=`', 'Range 字面量（开区间/闭区间）'],
                ['`?.`', '安全调用，null 时短路返回 null'],
                ['`??`', 'Elvis，提供默认值将 `T?` 转为 `T`'],
                ['`!`', '非空断言，null 时运行时 panic'],
                ['`?`', '传播操作符，提前传播 null 或 error'],
            ]},
            { type: 'h3', text: '变异性', id: 'variance' },
            { type: 'p', text: '编译器自动推导：构造器参数/返回值协变，函数参数逆变，同时出现则不变。`T?` 协变；`Throw<T, E>` 两个参数均协变。' },
            { type: 'h3', text: '子类型关系', id: 'subtype' },
            { type: 'ul', items: [
                '**记录宽度子类型**：`(name: str, age: i32) <: (name: str)`',
                '**Trait 结构化子类型**：方法更多的模块是方法更少的 Trait 的子类型',
                '**Error 子类型**：自定义错误类型 `<: Error`',
            ]},
            { type: 'h3', text: 'HKT / GADT / Kind', id: 'hkt' },
            { type: 'table', headers: ['Kind', '含义', '示例'], rows: [
                ['`*`', '具体类型', 'i32, str, bool'],
                ['`* -> *`', '一阶类型构造器', 'List, Vec, Tree'],
                ['`* -> * -> *`', '二阶类型构造器', 'Map, Throw'],
            ]},
            { type: 'code', code: 'type Functor<F: * -> *> { ... }    // F 是类型构造子\n\ntype Expr<T> =\n    | IntLit(i32)               : Expr<i32>\n    | BoolLit(bool)             : Expr<bool>\n    | Add(Expr<i32>, Expr<i32>) : Expr<i32>', filename: 'GADT' },
        ],
    },

    'r3-builtins': {
        title: 'R3. 内建函数参考',
        sections: {},
        sectionOrder: [],
        intro: [
            { type: 'p', text: '`println`/`print`/`eprintln`/`eprint`/`scanln`/`scan` 不是语言内建函数，而是标准库 `std.io.Console` 模块的函数，需 `import` 后使用（详见 R4）。以下为真正的语言内建。' },
            { type: 'h3', text: '类型转换', id: 'conv' },
            { type: 'table', headers: ['函数', '说明'], rows: [
                ['`cast(expr)`', '返回 cast builder，链式 `.to(T)` / `.try_to(T)`（详见第 7 章）'],
            ]},
            { type: 'h3', text: '类型与反射', id: 'reflect' },
            { type: 'table', headers: ['函数', '说明'], rows: [
                ['`type(x)`', '返回运行时类型名（str），如 `"i32"`、`"str"`、`"array"`'],
                ['`typeof(x)`', '返回编译时类型信息（TypeInfo 记录）'],
                ['`reflect(x)`', '返回值的反射表示'],
            ]},
            { type: 'h3', text: '并发', id: 'concurrency' },
            { type: 'table', headers: ['函数', '说明'], rows: [
                ['`channel(n)`', '创建缓冲区容量为 n 的 Channel（详见第 8 章）'],
            ]},
            { type: 'h3', text: '错误相关', id: 'error' },
            { type: 'table', headers: ['名称', '说明'], rows: [
                ['`throw expr`', '抛出错误（须在返回 `Throw<T, E>` 的函数中）'],
                ['`Ok(value)`', '构造 Throw 成功值'],
                ['`Error(e)`', '构造 Throw 错误值'],
                ['`Panic()`', '触发 panic（不可捕获，任务级隔离）'],
            ]},
            { type: 'h3', text: '禁止重新定义的名称', id: 'reserved' },
            { type: 'p', text: '以下内建名称禁止重新定义：`Panic` / `type` / `typeof` / `cast` / `str` / `reflect` / `channel` / `Error` / `Ok` / `CastError` / `IOError` / `TimeError` / `IOErrorKind` / `TimeErrorKind`，以及所有数值类型名（`i8`..`i128`、`u8`..`u128`、`isize`/`usize`、`f16`..`f128`）。`bool`、`char` 虽为内建类型名，但当前未被注册为禁止重定义名称。`Iterable`、`Iterator` 也为内建 trait 名。' },
        ],
    },

    'r4-stdlib': {
        title: 'R4. 标准库 API 参考',
        sections: {},
        sectionOrder: [],
        intro: [
            { type: 'p', text: '标准库用 Glue 自身编写，`@embedFile` 内嵌进二进制，零安装。`import std.<pack>.<mod>` 总是从内嵌表加载，不支持项目内同名文件覆盖。' },
            { type: 'h3', text: 'std/io', id: 'io' },
            { type: 'table', headers: ['类型/模块', '主要 API'], rows: [
                ['`Console`', '`println(x)` / `print(x)` / `eprintln(x)` / `eprint(x)` / `scanln()` / `scan()`'],
                ['`File`', 'open / read / write / close / stat / stat_of / seek / tell / remove / rename / chmod / read_exact / write_all / copy_to；类型 OpenMode / SeekFrom / FileKind / Stat'],
                ['`Fs`', 'read_file / write_file / append_file / read_file_bytes / write_file_bytes'],
                ['`Dir`', 'list / list_path / create / create_path / remove / walk；类型 DirEntry'],
                ['`Path`', 'path_from / to_str / join / join_str / parent / filename / extension / file_stem / is_absolute_path / is_relative_path'],
                ['`Buffered`', 'BufReader（new_reader / read_line / read_to_end / read_to_string / read_byte）、BufWriter（new_writer / write / write_str / write_line / flush）'],
            ]},
            { type: 'h3', text: 'std/time', id: 'time' },
            { type: 'table', headers: ['类型', '主要 API'], rows: [
                ['`Instant`', 'now / elapsed / duration_since / add_duration / sub_duration（单调时钟）'],
                ['`SystemTime`', 'now / to_utc / to_local / from_datetime_utc / duration_since / add_duration / sub_duration / is_before / is_after'],
                ['`DateTime`', 'from_components / to_components / add_days / add_duration / format / to_iso8601 / month_name / weekday_name'],
                ['`Duration`', 'from_secs / from_millis / from_micros / from_nanos / as_secs / as_millis / as_micros / as_nanos / add / sub / mul / div / is_zero'],
                ['`Calendar`', 'is_leap_year / days_in_month / day_of_year / weekday_of / to_julian_day / from_julian_day / days_between / add_days'],
                ['`Timer`', 'sleep / sleep_secs / ticker / timeout'],
            ]},
            { type: 'h3', text: 'std/net', id: 'net' },
            { type: 'table', headers: ['类型', '主要 API'], rows: [
                ['`Addr`', 'Ipv4Addr（v4_from_octets / v4_loopback / v4_is_loopback）、Ipv6Addr（v6_from_segments / v6_loopback）、IpAddr（ip_from_v4 / ip_from_v6 / ip_is_v4）、SocketAddr（socket_from / socket_ip / socket_port）'],
                ['`TcpListener`', 'bind / accept / close / local_addr；类型 AcceptResult'],
                ['`TcpStream`', 'connect / from_accept_fd / read / write / write_all / read_until / close / peer_addr'],
                ['`UdpSocket`', 'bind / send_to / recv_from / close / local_addr；类型 RecvFromResult'],
                ['`Dns`', 'resolve（主机名 → IpAddr[]）'],
            ]},
            { type: 'h3', text: 'std/reflect', id: 'reflect' },
            { type: 'table', headers: ['类型', '主要 API'], rows: [
                ['`Reflect`', 'format（任意值转字符串，println 底层机制）'],
            ]},
            { type: 'code', code: 'import std.io.Console.{println}\nimport std.time.Calendar.{is_leap_year, days_in_month}\n\nfun main(): void {\n    println(is_leap_year(2024))   // true\n    println(days_in_month(2026, 1))  // 31\n}', filename: 'example.glue' },
        ],
    },

    'r5-philosophy': {
        title: 'R5. 设计哲学',
        sections: {},
        sectionOrder: [],
        intro: [
            { type: 'h3', text: '核心原则', id: 'principles' },
            { type: 'table', headers: ['原则', '含义'], rows: [
                ['组合优于继承', '通过 ADT + Trait + 一等 Trait 值组合行为，不提供继承机制'],
                ['显式优于隐式', '空值和错误通过类型系统显式标注，`?` 操作符显式传播，类型转换必须显式'],
                ['安全默认', '默认不可变、默认私有、默认值语义，安全不需要额外努力'],
                ['运行时并行安全', '并行安全由运行时架构保证，无需用户手动管理'],
                ['约定优于配置', '最小清单即可运行，程序入口为 `fun main(): void`'],
                ['渐进复杂度', '简单的事情简单做，复杂的事情可能，但不强制'],
            ]},
            { type: 'h3', text: '关键设计决策', id: 'decisions' },
            { type: 'table', headers: ['决策', '理由'], rows: [
                ['CSP + async + channel', '与函数式契合，简洁，运行时安全'],
                ['运行时并行安全', '降低学习门槛（vs 编译期所有权系统）'],
                ['默认柯里化', '函数式特征，自然部分应用'],
                ['ADT + Trait（组合）', '组合优于继承'],
                ['文件即模块 + pack.glue', '简洁，约定优于配置'],
                ['先检查后求值', 'sema 完全在编译期完成，引擎信任类型信息'],
                ['RC + 三级分配器', '零全局暂停、内存占用与碎片最小化'],
                ['数据流图 IR', '直接表达依赖，缓存友好，循环体可预编译'],
                ['async fun + M:N 协程调度', '语法与函数调用统一，N 个 worker 线程 work-stealing 调度 M 个协程，worker 天然隔离'],
            ]},
        ],
    },
};
