# LFE 完整设计文档：纯数据流执行引擎

> **状态**：设计阶段
> **目标**：完全替代当前 VM 解释器，实现 Glue 全部语言特性，以数量级幅度超越 JIT
> **核心原则**：纯数据流——无 PC 跳转、无 decode-dispatch、无运行时函数调用、无动态分派
>
> **关联文档**：
> - [lfe-design.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/lfe-design.md) — LFE 初始设计（层流概念）
> - [value-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/value-redesign.md) — Value 层设计
> - [language-overview.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/language-overview.md) — Glue 语言手册

---

## 1. 设计动机

### 1.1 传统执行模型的根本局限

所有现有执行模型（VM / JIT / AOT）共享一个根本假设：**程序是指令序列**。

```
解释器：取指 → 解码 → 分派 → 执行 → 写回    （每条 5-10ns）
JIT：    CPU 取指 → 解码 → 执行 → 写回        （每条 0.25-1ns）
```

只要"指令序列"这个抽象存在，就无法消除以下固有开销：

| 开销来源 | 说明 | 周期数 |
|---|---|---|
| 指令缓存缺失 | CPU 等 L2/L3 缓存 | 10-40 |
| 分支预测失败 | 流水线回滚 | 15-20 |
| 指令解码 | x86 复杂解码 | 4-6 |
| 类型检查 | tagged union 判断 | 1-3 |
| 函数调用 | 栈帧建立/销毁 | 3-5 |
| 动态分派 | vtable 查找 / 哈希查找 | 5-20 |

### 1.2 突破点

**消除"指令"这一抽象层。程序不是指令序列，而是数据流动的路径。**

```
传统：程序 = 指令序列，执行 = 逐条取指解码执行
LFE： 程序 = 层流图（DAG），执行 = 数据持续流过层
```

没有取指、没有解码、没有分派。计算是数据流动的副产品——就像硬件电路，电路一旦建好，电流通过即出结果。

### 1.3 设计目标

| 目标 | 指标 |
|---|---|
| 比 VM 快 | 50-100 倍 |
| 比 JIT 快 | 8-16 倍 |
| 运行时分派 | 零（编译期全消除） |
| 运行时函数调用 | 零（编译期全内联） |
| 平台特定代码 | 零（完全依赖 Zig `@Vector` 自动适配） |
| 内存占用 | 当前 VM 的 5-10% |
| 内存碎片 | 零 |
| 外部依赖 | 零 |

### 1.4 与现有 lfe-design.md 的关系

本文档是 [lfe-design.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/lfe-design.md) 的完整修正版。初始文档定义了层流图的核心概念（Lamina / Channel / LaminarGraph），但在实现 Glue 全部特性时引入了不符合纯数据流原则的机制（extern_call 子图调用、PC 跳转、vtable 分派）。本文档修正这些偏差，提出完全符合纯数据流原则的方案。

---

## 2. 纯数据流原则

### 2.1 五条铁律

LFE 的所有设计决策必须服从以下五条铁律，违反任一条即偏离纯数据流：

1. **层流图始终是 DAG**——无回边、无跳转、无 PC。循环通过循环核（数据流迭代器）实现，不是控制流跳转。

2. **所有函数调用在编译期内联**——运行时不存在函数调用、栈帧、参数传递。递归通过循环核 + 显式栈（数据通道中的栈）实现。

3. **所有分派在编译期消除**——trait 单态化、闭包特化。编译期无法确定的动态分派用 `switch_lamina`（数据选择器，所有路径在图中，谓词门控输出），不是间接调用。

4. **层操作执行无 switch 分发**——用函数指针表（O(1) 索引）替代大 switch-case，消除 decode-dispatch 开销。

5. **运行时只有数据变换**——没有控制流（if/while/match 通过 select/mask/predicate 编译为数据选择），没有间接调用，没有栈管理。

### 2.2 什么是"纯数据流"

纯数据流的核心：**数据就绪驱动执行，编译期确定所有路径，运行时只有数据变换**。

超越 JIT 的核心：**JIT 有运行时编译开销 + 间接调用 + 分支预测失败；LFE 在编译期完成所有特化，运行时零开销**。

### 2.3 与命令式/函数式的关系

LFE 不是传统数据流架构（如 MIT Tagged Dataflow），也不是纯函数式语言。它是：

- **编译期**：全程序分析 + 全内联 + 单态化 + 循环转换——类似 Haskell 的 deforestation + Rust 的单态化
- **运行期**：数据流图执行——类似 SISAL 的 iterative form + GPU compute 的 SIMT

关键区别：LFE 的层流图在编译期完全确定，运行时是一个"通电即出结果"的电路，不是需要解释执行的指令。

---

## 3. 核心概念

### 3.1 层（Lamina）

层是 LFE 中最小的计算单元。**层不是指令**——它描述数据如何从输入通道流向输出通道。

```
层 = (操作类型, 输入通道[最多3], 输出通道, 可选谓词, 可选常量, 可选子类型标注)
```

一个层的执行语义：

```
读取输入通道的数据 → 执行操作 → 写入输出通道
```

层是纯数据描述，平台无关。同一套层描述在任何架构上执行。

### 3.2 通道（Channel）

通道是数据的载体，编译期确定类型和宽度。

| 通道类型 | 宽度 | 用途 |
|---|---|---|
| `i8_chan`..`i128_chan` | 1-16B | 整数 |
| `u8_chan`..`u128_chan` | 1-16B | 无符号整数 |
| `f16_chan`..`f128_chan` | 2-16B | 浮点 |
| `bool_chan` / `mask_chan` | 1B | 布尔值 / 谓词掩码 |
| `char_chan` | 4B | Unicode 字符 |
| `ref_chan` | 8B | 堆对象指针（`*ObjHeader`） |
| `null_chan` / `unit_chan` | 0B | 空值 / 单元值 |

通道数据存储在 `PhysicalChannel`（`[]align(16) u8`）中，16 字节对齐，SIMD 友好。

### 3.3 层流图（LaminarGraph）

层流图是一个 Glue 程序编译后的完整表示。**最终产物是单个 LaminarGraph**——所有函数已内联，所有泛型已单态化，所有分派已消除。

```zig
pub const LaminarGraph = struct {
    laminas: []const Lamina,         // 层序列（按拓扑序）
    channel_metas: []const ChannelMeta,  // 通道元数据
    channel_count: u16,
    input_channels: []const u16,     // 函数参数通道
    output_channel: u16,             // 返回值通道
    string_table: []const []const u8,
    name_table: []const []const u8,
    /// 循环核元数据列表
    loop_kernels: []const LoopKernelMeta,
    /// defer 注册表
    defer_entries: []const DeferEntry,
    arena: ?*std.heap.ArenaAllocator,
};
```

### 3.4 循环核（Loop Kernel）

循环核是 DAG 中被标记的子图区域，表示可重复执行的数据变换单元。**这不是 PC 跳转**——核内层序列始终是纯 DAG，引擎识别核边界后重入执行。

```zig
pub const LoopKernelMeta = struct {
    begin_idx: u16,          // 核入口层索引
    end_idx: u16,            // 核出口层索引
    state_chan: u16,         // 状态通道（反馈通道，初始值由外部提供）
    cond_chan: u16,          // 终止条件通道（mask_chan，false 时停止重入）
    state_update_chan: u16,  // 每次迭代的输出状态
};
```

引擎执行循环核 = 重复应用同一组数据变换，直到终止条件。这和 `reduce_sum` 对数组元素重复应用加法是同构的。**不是 decode-dispatch**（层操作在编译期已知），**不是控制流跳转**（没有 PC 改变，是数据的重复变换）。

---

## 4. Value 层引入

### 4.1 设计原则

**Value 层保持高性能，LFE 引入 Value。** LFE 不重新定义堆对象系统，而是复用 Value 层的设计，并在 Value 层优化后直接受益。

### 4.2 Value 层现状

**已有优势（高性能基础）：**

| 特性 | 说明 |
|---|---|
| 标量 `[N]u8` 内联存储 | 按实际宽度，无 padding，可直接 SIMD 加载 |
| `@bitCast` 零成本转换 | 编译期消除，运行时无开销 |
| `batch.zig` SIMD 批处理 | 128-bit 基准，`@Vector` 平台无关抽象 |
| `ops.zig` comptime 分派表 | `inline for` + `ALL_TAGS` 编译期特化 |
| `ObjHeader` 统一 8B 头 | `@fieldParentPtr` 零成本还原具体类型 |
| Str SSO | ≤20 字节内联，避免堆分配 |
| 原子引用计数 | `retain` 用 `.monotonic`，无竞争时约 1 周期 |

**需要优化的瓶颈：**

| 瓶颈 | 当前实现 | 优化方案 |
|---|---|---|
| ADT 构造器分派 | 字符串名比较 `std.mem.eql` | 编译期分配整数 tag，运行时整数比较 |
| Trait 方法分派 | `StringHashMap<Value>` 哈希查找 | 方法索引化，编译期建立 name→index 映射 |
| Atomic 实现 | Mutex 临界区 | 标量用 `std.atomic`，复合类型才用 Mutex |
| 数组/记录赋值 | 每次深拷贝 | COW 引用计数，写入时才复制 |

### 4.3 LFE 如何引入 Value

**类型复用：**

```zig
// lamina.zig 直接 re-export Value 层的类型
pub const IntKind = value.scalar.IntKind;
pub const FloatKind = value.scalar.FloatKind;
pub const RefKind = value.obj_header.RefKind;
pub const NativeIntType = value.scalar.NativeIntType;
pub const NativeFloatType = value.scalar.NativeFloatType;
```

**SIMD 复用：**

LFE engine 的 `executeLamina` 直接调用 `batch.zig` 的批处理函数：

```zig
// engine.zig 中的调用模式
inline for (ALL_INT_KINDS) |k| {
    if (lam.int_kind.? == k) {
        const T = NativeIntType(k);
        const a = chan_in1.asTypedPtr(T);
        const b = chan_in2.asTypedPtr(T);
        const dst = chan_out.asTypedPtrMut(T);
        batch.batchBinOp(T, bin_op, dst, a, b) catch return error.DivisionByZero;
        return;
    }
}
```

**堆对象复用：**

- `ref_chan` 存储 `*ObjHeader`（8字节指针）
- 堆对象操作（`adt_make`/`record_make`/`array_make` 等）通过 `ObjectPool` 分配
- `@fieldParentPtr` 从 `*ObjHeader` 还原具体类型指针

**边界转换：**

`chanToValue`/`valueToChan` 在语义边界处转换（reduce / atomic / halt_return）。批处理路径直接在通道上操作，避免 Value（24B）的转换开销。

### 4.4 Value 层优化计划

以下优化在 Value 层完成，LFE 直接受益：

#### 4.4.1 ADT 构造器整数 tag

```zig
pub const AdtValue = struct {
    header: ObjHeader,
    type_name: []const u8,
    type_id: u16,           // 新增：类型 ID（编译期分配）
    constructor: []const u8,
    ctor_id: u16,           // 新增：构造器 ID（编译期分配）
    fields: []AdtField,
};
```

`adt_test_ctor` 操作从字符串比较变为整数比较：`adt.ctor_id == expected_id`。

#### 4.4.2 Trait 方法索引化

```zig
pub const TraitValue = struct {
    header: ObjHeader,
    trait_name: []const u8,
    trait_id: u16,              // 新增：trait ID
    methods: []Value,           // 改：按方法索引存储（不再是 HashMap）
    method_names: []const []const u8,  // 仅用于 format/debug
    data: ?Value,
    allocator: std.mem.Allocator,
    owned: bool,
};
```

`trait_call_method` 从哈希查找变为数组索引：`trait.methods[method_idx]`。`method_idx` 在编译期由 `name_table` 查得。

#### 4.4.3 Atomic 标量优化

```zig
pub const AtomicValue = struct {
    header: ObjHeader,
    payload: union(enum) {
        i32_atom: std.atomic.Value(i32),
        i64_atom: std.atomic.Value(i64),
        u32_atom: std.atomic.Value(u32),
        u64_atom: std.atomic.Value(u64),
        general: struct { data: Value, mutex: Mutex },
    },
};
```

单态化后编译器已知 `Atomic<T>` 的具体 T，选择对应的原子分支。

#### 4.4.4 COW 引用计数

```zig
pub const ArrayValue = struct {
    header: ObjHeader,
    elements: []Value,
    capacity: usize,
    fixed_size: ?u64,
    cow_rc: ?*u32,    // 新增：COW 引用计数（null 表示独占）
};
```

`deepCopy` 时 `cow_rc` 增 1，共享底层 `elements`。`array_set` 时检查 `cow_rc > 1`，复制底层 `elements` 后才写入。

---

## 5. 循环核机制

### 5.1 循环核的本质

循环核**不是引擎的 while 循环**，而是**数据流迭代器**：

- 核内层序列是纯 DAG（编译期完全确定）
- 引擎执行循环核 = 重复应用同一组数据变换，直到终止条件
- 这和 `reduce_sum` 对数组元素重复应用加法是同构的
- **不是 decode-dispatch**（层操作在编译期已知，不是运行时解码）
- **不是控制流跳转**（没有 PC 改变，是数据的重复变换）

### 5.2 引擎执行算法

```zig
pub fn run(self: *Engine) EngineError!void {
    var i: usize = 0;
    while (i < self.graph.laminas.len) {
        const lam = self.graph.laminas[i];

        // 检查是否是循环核入口
        if (self.isLoopKernelBegin(i)) |lk| {
            i = try self.runLoopKernel(lk);
            continue;
        }

        // 检查 halt（defer 先执行）
        if (lam.op == .halt_return or lam.op == .halt_throw) {
            try self.runDefers();  // LIFO 执行 defer 注册表
        }

        if (self.halt_reason != .none) break;

        // 谓词门控
        if (lam.predicate) |p| {
            if (self.channels[p].getScalar(u8, 0) == 0) {
                i += 1;
                continue;  // 谓词为 false，跳过此层
            }
        }

        // 函数指针表直接调用（无 switch 分发）
        try handlers[@intFromEnum(lam.op)](self, lam);
        i += 1;
    }
}
```

### 5.3 循环核执行

```zig
fn runLoopKernel(self: *Engine, lk: LoopKernelMeta) EngineError!usize {
    while (true) {
        // 执行核内层序列（纯 DAG）
        for (self.graph.laminas[lk.begin_idx..lk.end_idx]) |lam| {
            // 谓词门控
            if (lam.predicate) |p| {
                if (self.channels[p].getScalar(u8, 0) == 0) continue;
            }
            try handlers[@intFromEnum(lam.op)](self, lam);
        }

        // 检查终止条件（数据，不是控制流）
        const cond = self.channels[lk.cond_chan].getScalar(u8, 0);
        if (cond == 0) break;

        // 反馈：state_update → state
        const src = &self.channels[lk.state_update_chan];
        const dst = &self.channels[lk.state_chan];
        @memcpy(dst.data, src.data);
    }
    return lk.end_idx + 1;
}
```

### 5.4 while 循环编译

```glue
var i = 0
while i < 10 {
    i += 1
}
```

编译为循环核：
```
ch_i_init (cell_make: 0)

─── loop_kernel_begin (state=ch_i, cond=ch_cond, update=ch_i') ───
ch_i → [cell_get] → ch_i_val
ch_i_val → [int_lt: 10] → ch_cond                    // 终止条件
ch_i_val → [int_add: 1] → ch_i_new                    // body: i += 1
ch_i_new → [cell_make] → ch_i'                        // 更新状态
─── loop_kernel_end ───

ch_i → [cell_get] → ch_result                         // 最终值
```

### 5.5 for-in-range 循环编译

```glue
var sum = 0
for x in range(1, 10) {
    sum += x
}
```

编译为循环核（状态 = (current, sum)）：
```
ch_current_init = 1, ch_sum_init = 0

─── loop_kernel_begin (state=(ch_current, ch_sum), cond=ch_cond, update=(ch_current', ch_sum')) ───
ch_current → [int_lt: 10] → ch_cond
ch_current → [int_add: ch_sum] → ch_sum'              // sum += x
ch_current → [int_add: 1] → ch_current'               // current++
─── loop_kernel_end ───

ch_sum → [halt_return]                                 // 最终 sum
```

### 5.6 for-in-iterable 循环编译

```glue
for item in collection {
    process(item)
}
```

脱糖为 `loop { match iter.next() { null => break, item => body } }`，编译为循环核：
```
ch_iter = [iter_make: collection]
ch_done_init = 0  (false)

─── loop_kernel_begin (state=ch_iter, cond=ch_done, update=ch_iter') ───
ch_iter → [iter_next] → ch_next_val, ch_has_next
ch_has_next → [mask_not] → ch_done                    // !has_next → 终止
ch_next_val → [process] → ch_discard                  // body（副作用）
ch_iter → ch_iter'                                    // 迭代器状态推进
─── loop_kernel_end ───
```

### 5.7 SIMD 批处理模式

循环核天然支持 SIMD 批处理：一次执行 K 个迭代，用 `compress` 收集未终止的迭代继续。这是 SISAL 的 iterative form 在 LFE 中的实现。

---

## 6. 全内联与单态化

### 6.1 全内联原则

**所有非递归函数在编译期内联到调用点。** 层流图中不存在 `extern_call`——函数体直接展开在调用位置。

```glue
fun add(a: i32, b: i32): i32 { a + b }
fun main() { add(1, 2) }
```

编译后层流图（add 已内联）：
```
[constant: 1] → ch_a
[constant: 2] → ch_b
[int_add: ch_a, ch_b] → ch_result
[halt_return: ch_result]
```

没有函数调用，没有栈帧，纯数据变换。

### 6.2 递归处理

编译器进行调用图分析，识别递归 SCC（强连通分量），将递归转为数据流机制：

| 递归类型 | 处理方式 |
|---|---|
| 尾递归 | 循环核（state = 参数 + accumulator） |
| 非尾递归 | 显式栈 + 循环核（栈是通道中的数据，不是调用栈） |
| 相互递归 | 识别 SCC，转为循环核 + 显式栈 |

**尾递归示例：**

```glue
fun fact(n: i32, acc: i32): i32 {
    if n <= 1 { acc } else { fact(n - 1, acc * n) }
}
```

编译为循环核：
```
ch_n_init = n, ch_acc_init = acc

─── loop_kernel_begin (state=(ch_n, ch_acc), cond=ch_done, update=(ch_n', ch_acc')) ───
ch_n → [int_le: 1] → ch_done                           // n <= 1 → 终止
ch_n → [int_sub: 1] → ch_n'                            // n' = n - 1
ch_acc, ch_n → [int_mul] → ch_acc'                     // acc' = acc * n
─── loop_kernel_end ───

ch_acc → [halt_return]
```

**非尾递归示例：**

```glue
fun fib(n: i32): i32 {
    if n < 2 { n } else { fib(n-1) + fib(n-2) }
}
```

编译器将递归转为迭代 + 显式栈（栈是通道中的数据，不是调用栈）：
```
// 工作栈：每个帧 = (n, phase, accum)
// phase: 0=初始, 1=有fib(n-1)结果, 2=完成
ch_stack = [array_make]

─── loop_kernel_begin (state=ch_stack, cond=ch_stack_empty, update=ch_stack') ───
ch_stack → [array_len] → ch_stack_empty                 // 栈空 → 终止
ch_stack → [array_pop] → ch_top                         // 取栈顶 (n, phase, accum)

// phase 0: 计算 n < 2
ch_top.n → [int_lt: 2] → ch_base
// base case: 结果 = n，压入父帧的 accum
// recursive case: 压入 (n-1, 0, 0)，当前帧 phase → 1

// phase 1: 有 fib(n-1) 结果
// 压入 (n-2, 0, 0)，当前帧 phase → 2，accum += result

// phase 2: 有 fib(n-2) 结果
// accum += result，弹出当前帧，结果压入父帧

ch_stack' → ch_stack                                   // 反馈
─── loop_kernel_end ───

ch_result → [halt_return]
```

栈是数据，迭代是数据流核。没有函数调用，没有调用栈，没有分派。

### 6.3 泛型单态化

**核心原则：泛型在编译期完全单态化，运行时不存在任何类型参数。**

Glue 的泛型是 Hindley-Milner + Trait 约束，天然适合编译期单态化。

#### 6.3.1 单态化流程

```
源代码（含泛型）
    ↓
[sema] 类型推断 + trait 约束求解 → 每个调用点的 T 确定为具体类型
    ↓
[LFE 编译器] 单态化：为每个 (函数, 具体类型参数) 组合生成特化层流图
    ↓
全内联：所有特化后的函数内联到调用点
    ↓
单个 LaminarGraph（无泛型、无函数表、无分派）
```

#### 6.3.2 类型参数替换

`T` 在不同调用点可能是 `i32`、`f64`、`MyType`，数据宽度和操作不同。单态化后，每个特化版本使用具体类型的通道：

```glue
fun max<T: Ord>(a: T, b: T): T {
    if a > b { a } else { b }
}
fun main() {
    val x = max(1, 2)          // T = i32
    val y = max(3.14, 2.71)    // T = f64
}
```

单态化 + 内联后：
```
// max<i32> 内联到调用点 1
[constant: 1] → ch_a1
[constant: 2] → ch_b1
[int_gt: ch_a1, ch_b1] → ch_cond1
ch_cond1, ch_a1, ch_b1 → [select] → ch_max1

// max<f64> 内联到调用点 2
[constant: 3.14] → ch_a2
[constant: 2.71] → ch_b2
[float_gt: ch_a2, ch_b2] → ch_cond2
ch_cond2, ch_a2, ch_b2 → [select] → ch_max2
```

`T: Ord` 约束的 `>` 操作在 i32 版本中特化为 `int_gt`，在 f64 版本中特化为 `float_gt`。**运行时零开销**。

#### 6.3.3 Trait 约束的方法分派

**情况 A：调用点类型已知（绝大多数情况）→ 编译期单态化**

```glue
fun show_all<T: Show>(items: Array<T>) {
    for item in items {
        println(item.show())  // T: Show 的 show 方法
    }
}

fun main() {
    show_all([MyInt(1), MyInt(2)])  // T = MyInt
}
```

编译器在 `show_all<MyInt>` 中，`item.show()` 的具体实现已知是 `MyInt.show`，直接内联。**无 vtable，无间接调用，纯数据流。**

**情况 B：类型参数无法在编译期确定 → switch_lamina**

这发生在一等 Trait 值（如 `Array<Show>` 中元素的具体类型不同）。编译器为所有可能的 Show 实现类型生成 switch_lamina（见第 8 章）。

#### 6.3.4 类型特化约束

`with T: ConcreteType` 将类型参数直接绑定到具体类型，不是 trait 约束：

```glue
// T 必须是 i32（不是"T 实现某 trait"，而是"T 就是 i32"）
fun optimize<T>(x: T): T with T: i32 {
    x * 2
}

// 混合使用：类型参数约束 + 类型特化
type SortedVec<T: Clone>: FastSort with T: i32 = SortedVec(data: [T]) { ... }
```

处理方式：直接替换 T 为具体类型，编译为单版本。比普通泛型更简单——无需从调用点推断类型。

#### 6.3.5 关联类型

```glue
trait Iterator {
    type Item
    fun next(self): Item?
}

type IntRange: Iterator {
    type Item = i32
    fun next(self): i32? { ... }
}
```

关联类型在单态化时替换为具体类型。`IntRange.Iterator.Item = i32`，所以 `IntRange.next()` 的返回类型确定为 `i32?`。

#### 6.3.6 编译器单态化算法

```zig
fn compile(allocator, module: ast.Module) CompileError!LaminarGraph {
    // 1. 收集所有函数定义 + trait 实现
    var func_table = collectFunctions(module);
    var trait_impls = collectTraitImpls(module);

    // 2. 从 main 开始，类型驱动的单态化
    var worklist = Worklist.init();
    worklist.push(.{ .func = "main", .type_args = &.{} });

    var specialized = StringHashMap(LaminarGraph).init(arena);

    while (worklist.pop()) |entry| {
        const key = makeKey(entry.func, entry.type_args);
        if (specialized.contains(key)) continue;

        // 3. 用具体类型替换类型参数，编译函数体
        const func = func_table[entry.func];
        const specialized_graph = compileFunction(func, entry.type_args, trait_impls);
        specialized.put(key, specialized_graph);

        // 4. 收集函数体中的泛型调用，加入 worklist
        for (specialized_graph.callsites) |cs| {
            if (cs.is_generic) {
                worklist.push(.{ .func = cs.func_name, .type_args = cs.resolved_types });
            }
        }
    }

    // 5. 全内联：从 main 开始展开所有调用
    return inlineAll(specialized, "main");
}
```

#### 6.3.7 代码爆炸控制

单态化为每个 `(函数, 类型参数)` 组合生成特化版本。缓解措施：

1. **死通道消除**（优化器已有）：未使用的特化版本被移除
2. **公共子表达式消除**（可扩展）：相同操作的特化版本合并
3. **通道槽位复用**（优化器已有）：不同特化版本的非活跃通道复用物理槽位
4. **只单态化实际调用的类型组合**

---

## 7. 模式匹配

### 7.1 测试链 + 谓词门控

所有 arm 在编译期内联在图中，谓词门控控制副作用，select 链选择结果。**无跳转。**

```glue
match shape {
    Circle(r) if r > 0 => pi * r * r,
    Rect(w, h) => w * h,
    _ => 0,
}
```

编译为：
```
ch_shape (input)

// Arm 1: Circle(r) if r > 0
ch_shape → [adt_test_ctor: Circle] → ch_m1
ch_shape → [adt_get_field: "radius"] → ch_r
ch_r → [int_gt: 0] → ch_guard1
ch_m1, ch_guard1 → [mask_and] → ch_arm1                 // Circle && r>0
ch_r → [float_mul: CONST(pi)] → ch_r2
ch_r2 → [float_mul: ch_r] → ch_area1

// Arm 2: Rect(w, h)
ch_shape → [adt_test_ctor: Rect] → ch_m2
ch_arm1 → [mask_not] → ch_not_arm1
ch_m2, ch_not_arm1 → [mask_and] → ch_arm2               // Rect && !arm1
ch_shape → [adt_get_field: "width"] → ch_w
ch_shape → [adt_get_field: "height"] → ch_h
ch_w, ch_h → [float_mul] → ch_area2

// Arm 3: _ (wildcard)
ch_arm1, ch_arm2 → [mask_or] → ch_matched
ch_matched → [mask_not] → ch_arm3                        // !matched

// 结果选择（优先级链）
ch_arm1, ch_area1, ch_area2 → [select] → ch_s1           // arm1 ? area1 : area2
ch_arm2, ch_s1, CONST(0) → [select] → ch_s2              // arm2 ? s1 : 0
```

### 7.2 嵌套模式

```glue
match tree {
    Node(_, Node(x, _, _), _) => x,
    _ => 0,
}
```

编译为多层 adt_test_ctor + adt_get_field + mask_and 链：
```
ch_tree → [adt_test_ctor: Node] → ch_m1
ch_tree → [adt_get_field: "left"] → ch_left
ch_left → [adt_test_ctor: Node] → ch_m2
ch_left → [adt_get_field: "value"] → ch_x
ch_m1, ch_m2 → [mask_and] → ch_arm1
// ...
```

### 7.3 字面量模式

```glue
match n {
    0 => "zero",
    1 => "one",
    _ => "many",
}
```

编译为整数比较 + select 链：
```
ch_n → [int_eq: 0] → ch_m0
ch_n → [int_eq: 1] → ch_m1
ch_m0, ch_m1 → [mask_or] → ch_matched
ch_matched → [mask_not] → ch_arm3

ch_m0, [str_const: "zero"], [str_const: "one"] → [select] → ch_s1
ch_m1, ch_s1, [str_const: "many"] → [select] → ch_result
```

### 7.4 或模式

```glue
match n {
    1 | 2 | 3 => "small",
    _ => "large",
}
```

编译为多个比较 + mask_or：
```
ch_n → [int_eq: 1] → ch_m1
ch_n → [int_eq: 2] → ch_m2
ch_n → [int_eq: 3] → ch_m3
ch_m1, ch_m2 → [mask_or] → ch_m12
ch_m12, ch_m3 → [mask_or] → ch_arm1
// ...
```

### 7.5 Throw / Nullable 模式

```glue
match result {
    Ok(v) => v,
    Error(e) => handle(e),
}
```

编译为：
```
ch_result → [throw_is_ok] → ch_ok?
ch_result → [throw_get_ok] → ch_v
ch_ok? → [mask_not] → ch_err?
ch_result → [throw_get_err] → ch_e
ch_v → [extern_inline: handle] → ch_handled  // handle 已内联

ch_ok?, ch_v, ch_handled → [select] → ch_result_out
```

### 7.6 穷举检查

编译器在 sema 阶段已做穷举检查（`checkExhaustiveness`）。LFE 编译器信任 sema 的结果，不需要运行时检查未匹配的情况。

### 7.7 副作用分支的谓词门控

副作用分支体（含 debug_print / channel_send 等）通过 `predicate` 字段门控：只有匹配的 arm 的副作用层才执行 IO。

```
ch_arm1 → [debug_print: "matched Circle", predicate=ch_arm1]
```

引擎在 `predicate=false` 时跳过实际 IO。**这不是分派**——是数据驱动的条件执行，和 `select` 语义一致。

---

## 8. 闭包与 Trait

### 8.1 闭包：编译期内联或 switch_lamina

**闭包的两种情况：**

| 情况 | 处理方式 |
|---|---|
| 调用点已知闭包目标 | 编译期内联闭包体 |
| 调用点未知闭包目标 | switch_lamina（数据选择器） |

**情况 A：已知目标的闭包**

```glue
val adder = fun(x) { fun(y) { x + y } }
val add5 = adder(5)
add5(3)  // = 8
```

编译器在 `add5(3)` 调用点已知闭包是 `adder` 的内层 lambda，直接内联：
```
[constant: 5] → ch_x          // upvalue
[constant: 3] → ch_y          // 参数
ch_x, ch_y → [int_add] → ch_result
```

**情况 B：未知目标的闭包（一等函数）**

```glue
val f: (i32) -> i32 = get_function()
f(42)  // f 的具体实现运行时才知道
```

编译器为所有可能的 `(i32) -> i32` 函数生成 switch_lamina：
```
ch_f (closure ref)
ch_arg = 42

// 提取闭包的函数索引
ch_f → [closure_get_func_idx] → ch_func_idx

// 所有可能的函数路径（编译期内联）
ch_arg → [func_0_body] → ch_r0, predicate=(func_idx==0)
ch_arg → [func_1_body] → ch_r1, predicate=(func_idx==1)
ch_arg → [func_2_body] → ch_r2, predicate=(func_idx==2)

// 数据选择
ch_func_idx → [int_eq: 0] → ch_is_0
ch_is_0, ch_r0, ch_r1 → [select] → ch_s1
ch_func_idx → [int_eq: 1] → ch_is_1
ch_is_1, ch_s1, ch_r2 → [select] → ch_result
```

**这不是分派**——所有路径在编译期内联在图中，运行时只有数据选择（select）。

### 8.2 闭包捕获

**捕获语义：**
- 普通闭包：引用捕获（共享 upvalue）
- spawn 闭包（async fun）：深拷贝捕获（隔离）
- val 捕获：值拷贝
- var 捕获：Cell 引用（普通闭包可修改外部 var）

**编译期处理：**

编译器分析闭包的捕获列表，为每个捕获的变量分配 upvalue 通道。内联闭包体时，upvalue 通道直接绑定到外层作用域的通道。

```
// val count = 0
// val f = fun() { count + 1 }
// f()

[constant: 0] → ch_count           // val count = 0
// 闭包 f 内联到调用点，ch_count 直接作为 upvalue
ch_count → [int_add: 1] → ch_result  // count + 1
```

对于 var 捕获：
```
// var count = 0
// val f = fun() { count = count + 1 }
// f()

[cell_make: 0] → ch_count_cell      // var count = 0（Cell）
// 闭包 f 内联到调用点
ch_count_cell → [cell_get] → ch_count_val
ch_count_val → [int_add: 1] → ch_new_count
ch_count_cell → [cell_set: ch_new_count]  // 修改外部 var
```

### 8.3 Trait：编译期单态化或 switch_lamina

**情况 A：调用点类型已知 → 编译期单态化**

```glue
trait Show { fun show(self): str }
type MyInt: Show = MyInt(value: i32) {
    fun show(self): str { "MyInt(" + str(self.value) + ")" }
}
val x: Show = MyInt(42)
x.show()
```

编译器在调用点已知 `x` 的具体类型是 `MyInt`，直接内联 `MyInt.show` 的实现：
```
ch_x → [adt_get_field: "value"] → ch_val
ch_val → [int_to_str] → ch_str1
[str_const: "MyInt("] → ch_s1
ch_s1 → [str_concat: ch_str1] → ch_s2
[str_const: ")"] → ch_s3
ch_s2 → [str_concat: ch_s3] → ch_result
```

**无 vtable，无查表，无分派。**

**情况 B：一等 Trait 值（动态类型）→ switch_lamina**

```glue
val shapes: Array<Show> = [Circle(1), Rect(2, 3)]
for s in shapes {
    println(s.show())  // s 的具体类型运行时变化
}
```

`Array<Show>` 中每个元素的具体类型不同，无法单态化为单一版本。编译器为所有可能的 Show 实现类型生成 switch_lamina：

```
ch_s → [adt_get_ctor_id] → ch_tag

// Circle.show() 路径（编译期内联）
ch_s → [adt_get_field: "radius"] → ch_r
ch_r → [float_to_str] → ch_r_str
[str_const: "Circle("] → ch_c1
ch_c1 → [str_concat: ch_r_str] → ch_c2
ch_c2 → [str_concat: ")"] → ch_circle_result, predicate=(tag==CIRCLE_ID)

// Rect.show() 路径（编译期内联）
ch_s → [adt_get_field: "width"] → ch_w
ch_s → [adt_get_field: "height"] → ch_h
ch_w → [float_to_str] → ch_w_str
ch_h → [float_to_str] → ch_h_str
[str_const: "Rect("] → ch_r1
ch_r1 → [str_concat: ch_w_str] → ch_r2
ch_r2 → [str_concat: ", "] → ch_r3
ch_r3 → [str_concat: ch_h_str] → ch_r4
ch_r4 → [str_concat: ")"] → ch_rect_result, predicate=(tag==RECT_ID)

// 数据选择
ch_tag → [int_eq: CIRCLE_ID] → ch_is_circle
ch_is_circle, ch_circle_result, ch_rect_result → [select] → ch_final
ch_final → [debug_print]
```

**这不是分派**——所有路径在编译期内联在图中，运行时只有数据选择（select）。

### 8.4 文件模块作为 Trait 值

Glue 支持文件模块作为 Trait 值（结构化匹配）。文件模块若提供了 trait 要求的全部方法签名，即可作为该 trait 的值传递。

LFE 处理：编译器在编译期检查模块是否满足 trait，满足则生成 TraitValue 对象（方法索引化）。运行时通过 `trait_call_method` 按方法索引调用。

由于方法索引在编译期已知，`trait_call_method` 实际是数组索引访问（`trait.methods[method_idx]`），不是哈希查找。

---

## 9. defer 与 select

### 9.1 defer：编译期注册 + halt 时执行

```glue
fun f() {
    defer println("cleanup")
    // ... body ...
    return result
}
```

编译：
- 遇到 `defer_stmt` 时，将 body 编译为一个独立的"清理层序列"，注册到 `defer_entries`
- `halt_return` / `halt_throw` 执行前，引擎逆序执行 defer_entries 中的所有清理层序列

```zig
pub const DeferEntry = struct {
    begin_idx: u16,    // 清理层序列在 graph.laminas 中的起始索引
    count: u16,        // 清理层序列长度
};
```

```zig
fn runDefers(self: *Engine) EngineError!void {
    // LIFO 逆序执行
    var i = self.graph.defer_entries.len;
    while (i > 0) {
        i -= 1;
        const entry = self.graph.defer_entries[i];
        for (self.graph.laminas[entry.begin_idx..entry.begin_idx + entry.count]) |lam| {
            try handlers[@intFromEnum(lam.op)](self, lam);
        }
    }
}
```

defer 层序列是 DAG 的一部分（编译期确定位置），运行时只是逆序执行它们，不破坏数据流模型。

### 9.2 select 多路复用

```glue
select {
    v = ch1.recv() => process(v),
    v = ch2.recv() => handle(v),
    timeout(1000) => println("timeout"),
}
```

编译为多通道非阻塞尝试 + 优先级选择：
```
ch1 → [channel_try_recv] → ch_v1, ch_ok1
ch2 → [channel_try_recv] → ch_v2, ch_ok2
// timer → [timer_check: 1000] → ch_ok3

ch_ok1 → [mask_not] → ch_not_ok1
ch_ok2, ch_not_ok1 → [mask_and] → ch_arm2       // ok2 && !ok1
ch_ok1, ch_ok2 → [mask_or] → ch_matched
ch_matched → [mask_not] → ch_arm3                 // timeout

ch_arm1, ch_v1 → [process 内联] → ch_r1
ch_arm2, ch_v2 → [handle 内联] → ch_r2
ch_arm3 → [debug_print: "timeout"] → ch_r3

ch_arm1, ch_r1, ch_r2 → [select] → ch_s1
ch_arm2, ch_s1, ch_r3 → [select] → ch_result
```

如果所有通道都无数据，编译为循环核（重试直到有数据或超时）：
```
─── loop_kernel_begin (state=ch_retry, cond=ch_any_ready, update=ch_retry') ───
ch1 → [channel_try_recv] → ch_v1, ch_ok1
ch2 → [channel_try_recv] → ch_v2, ch_ok2
ch_ok1, ch_ok2 → [mask_or] → ch_any_ready
// timer 检查
─── loop_kernel_end ───
```

---

## 10. 错误处理与 Nullable

### 10.1 错误值传播

throw 不破坏数据流，而是产出"错误值"沿通道传播：

```
throw_make(err) → ch_throw_val  (RefKind=Throw)
throw_is_ok(ch_throw_val) → ch_ok?
throw_propagate(ch_throw_val, ch_ok?) → 传播或解包
halt_throw(ch_throw_val) → 终止（在循环核最外层检查）
```

整个数据流图保持 DAG，错误值像 Maybe monad 一样传播。

### 10.2 `?` 传播操作符

```glue
fun read_file(): Throw<str, FileError> {
    val content = open(path)?   // ? 传播 Error
    Ok(content)
}
```

编译为 throw_propagate（已有引擎实现）：
```
ch_result_open → [throw_is_ok] → ch_ok?
ch_result_open → [throw_get_ok] → ch_content
// ? 传播：若 ch_ok?=false，则 halt_throw(ch_result_open)
ch_ok? → [halt_throw: ch_result_open]  (predicate 门控)
ch_content → [throw_make: Ok] → ch_return
```

### 10.3 Nullable 操作

```glue
val name: str? = maybe_null()
val len = name?.len() ?? 0
```

编译：
```
ch_name → [nullable_is_null] → ch_is_null
ch_name → [nullable_unwrap] → ch_name_val
ch_name_val → [str_len] → ch_len1
ch_is_null, ch_len1, CONST(0) → [select] → ch_len  // null ? 0 : len1
```

`?.` 安全调用 → nullable_is_null + select 门控
`??` → nullable_unwrap_or
`!` → nullable_unwrap（null 时 panic）
`?` 传播 → null_to_nullable + select 或 halt_throw

### 10.4 `?` 的精确语义

`?` 在 Nullable 和 Throw 上下文有不同语义，不跨类型自动转换：

| 上下文 | `expr?` 的语义 | 要求外层函数返回 |
|---|---|---|
| Nullable `T?` | 展开为 `T`，null 时提前返回 null | `U?` |
| Throw `Throw<T, E>` | 展开为 `T`，throw 时提前传播 | `Throw<U, E'>` |

在 `Throw<T,E>` 返回的函数中对 `T?` 用 `?` → 编译错误（`propagate_cross_type`）。反之亦然。

### 10.5 Panic

Panic 不可捕获，协程级隔离。通过 Zig 的 `@panic` 触发。LfeTask 的 `error_val` 字段传播 panic，task 状态置 `failed`，不影响其他 task。

---

## 11. 模块系统

### 11.1 复用 ModuleLoader

LFE 复用现有 ModuleLoader 加载多模块 AST。编译器从"编译单个函数"变为"全程序内联编译"：

```zig
pub fn compile(
    allocator: std.mem.Allocator,
    modules: []const ast.Module,  // ModuleLoader 输出
) CompileError!LaminarGraph {
    // 1. 收集所有模块的函数定义 + trait 实现 + 类型定义
    // 2. 从 main 开始，类型驱动的单态化 + 全内联
    // 3. 处理 import（跨模块函数引用 → 统一函数表）
    // 4. 生成单个 LaminarGraph（无子图、无函数表）
}
```

### 11.2 跨模块函数调用

跨模块函数调用通过统一的函数表查找，在编译期内联：

```
模块 A: fun helper(x: i32): i32 { x * 2 }
模块 B: import A.{helper}
        fun main() { helper(42) }
```

编译时 ModuleLoader 加载两个模块，编译器在 main 中内联 helper：
```
[constant: 42] → ch_x
ch_x → [int_mul: 2] → ch_result
[halt_return: ch_result]
```

### 11.3 import 的所有形式

| 语法 | 语义 |
|---|---|
| `import M.{a, b}` | 选择性导入 |
| `import M.item` | 导入单项 |
| `import M.{item as alias}` | 别名导入 |
| `import M.*` | 通配导入 |
| `pub import ...` | 再导出 |

LFE 编译器在收集函数定义时统一处理所有 import 形式，建立全程序的符号表。

### 11.4 pack.glue 目录模块

目录模块入口 `pack.glue`（`pub pack Name`）作为命名空间。LFE 编译器将 `Store.Memory.delete(...)` 这样的限定访问解析为对应模块的函数调用，然后内联。

---

## 12. Glue 特性覆盖矩阵

### 12.1 完整特性覆盖表

| 特性类别 | 特性 | LFE 方案 | 状态 |
|---|---|---|---|
| **字面量** | int/float/bool/char/str/null/unit | constant / str_const | ✅ 已实现 |
| **字面量** | string_interpolation | str_concat 链 | 待实现 |
| **字面量** | array_literal `[1,2,3]` | array_make | 待实现 |
| **字面量** | record_literal `(n: "a")` | record_make | 待实现 |
| **运算符** | 算术 `+ - * / %` | int/float 算术 op | ✅ 已实现 |
| **运算符** | 位运算 `& \| ^` | int_and/or/xor | ✅ 已实现 |
| **运算符** | 比较 `== != < > <= >=` | int/float/bool/char 比较 op | ✅ 已实现 |
| **运算符** | 逻辑 `&& \|\| !` | bool_and/or/not | ✅ 已实现 |
| **运算符** | 范围 `..` `..=` | range_make | ✅ 已实现 |
| **运算符** | 拼接 `++` `+`(str) | array_concat / str_concat | 待实现 |
| **运算符** | 复合赋值 `+= -= *= /= %= &= \|=` | cell_get + 算术 + cell_set | 待实现 |
| **运算符** | Nullable `?.` `??` `!` `?` | nullable op + select | 待实现 |
| **运算符** | 类型转换 `Type(value)` | int_widen/narrow 等 | 待实现 |
| **控制流** | if/else | select 谓词化 | ✅ 已实现 |
| **控制流** | while/loop/for | 循环核 + 反馈通道 | 待实现 |
| **控制流** | break/continue | halt_break/continue | ✅ 已实现 |
| **控制流** | return | halt_return | ✅ 已实现 |
| **控制流** | defer | 编译期注册 + halt 时 LIFO 执行 | 待实现 |
| **控制流** | 块表达式 | 语句序列 + 尾表达式 | ✅ 已实现 |
| **模式匹配** | wildcard `_` | mask 恒真 | 待实现 |
| **模式匹配** | literal pattern | int_eq/str_eq + mask | 待实现 |
| **模式匹配** | variable pattern | 直接绑定通道 | 待实现 |
| **模式匹配** | constructor pattern | adt_test_ctor + adt_get_field | 待实现 |
| **模式匹配** | record pattern | record_get + mask | 待实现 |
| **模式匹配** | or_pattern `1\|2\|3` | mask_or 链 | 待实现 |
| **模式匹配** | guard `if cond` | mask_and | 待实现 |
| **数据类型** | ADT（枚举/递归/GADT） | adt_make/get_field/test_ctor | 待实现 |
| **数据类型** | record | record_make/get/set | 待实现 |
| **数据类型** | newtype | newtype_wrap/unwrap | 待实现 |
| **数据类型** | array `T[N]` / `T[]` | array_make/get/set/push | 待实现 |
| **数据类型** | str | str_const/concat/len/char_at | 部分实现 |
| **数据类型** | Cell | cell_make/get/set/swap | ✅ 已实现 |
| **数据类型** | Range | range_make/start/end/len | ✅ 已实现 |
| **函数** | 命名函数 | 编译期内联 | 待实现 |
| **函数** | lambda | 编译期内联 / switch_lamina | 待实现 |
| **函数** | 默认柯里化 | 编译期部分应用 | 待实现 |
| **函数** | 嵌套函数 | 编译期内联 + 闭包捕获 | 待实现 |
| **函数** | 递归（尾/非尾/相互） | 循环核 + 显式栈 | 待实现 |
| **错误处理** | Throw `Throw<T, E>` | throw_make/is_ok/get_ok/propagate | ✅ 已实现 |
| **错误处理** | `throw` 语句 | halt_throw | ✅ 已实现 |
| **错误处理** | `?` 传播 | throw_propagate | ✅ 已实现 |
| **错误处理** | Error trait | trait 单态化 | 待实现 |
| **并发** | async fun / Async<T> | async_create/join/status | ✅ 已实现 |
| **并发** | Atomic<T> | atomic_make/load/store/cas/swap | ✅ 已实现 |
| **并发** | Channel<T> | channel_make/send/recv/close | ✅ 已实现 |
| **并发** | Sender/Receiver | channel_split + sender/receiver op | ✅ 已实现 |
| **并发** | select 多路复用 | 多通道 try_recv + 优先级选择 | 待实现 |
| **Trait** | trait 定义 + 实现 | 编译期单态化 | 待实现 |
| **Trait** | 默认方法 / override | 编译期内联 | 待实现 |
| **Trait** | 关联类型 | 单态化时替换 | 待实现 |
| **Trait** | Trait 组合 / delegate | 编译期内联 | 待实现 |
| **Trait** | 一等 Trait 值 | switch_lamina | 待实现 |
| **泛型** | 泛型函数 `<T>` | 编译期单态化 | 待实现 |
| **泛型** | trait 约束 `<T: Trait>` | 单态化时内联具体实现 | 待实现 |
| **泛型** | 类型特化 `with T: Type` | 直接替换 T 为具体类型 | 待实现 |
| **泛型** | HKT (Kind 系统) | kind 检查在 sema，LFE 只需单态化 | 待实现 |
| **模块** | import | 复用 ModuleLoader + 全内联 | 待实现 |
| **模块** | pack.glue | 命名空间解析 + 内联 | 待实现 |
| **模块** | pub 可见性 | sema 检查，LFE 信任 | 待实现 |
| **其他** | lazy | lazy_make/force | 待实现 |
| **其他** | 部分应用 | 编译期部分应用 + 内联 | 待实现 |
| **其他** | 注释 `//` `/* */` | lexer 处理，LME 无关 | ✅ 不涉及 |

### 12.2 内建函数覆盖

| 内建函数 | LFE 方案 |
|---|---|
| `println` / `print` / `eprintln` / `eprint` | debug_print |
| `eq` | equals（Value 层结构比较） |
| `str()` | 值转字符串（int_to_str / float_to_str / format） |
| `type()` | 运行时类型名（switch on type_tag） |
| `Panic()` | @panic |
| `i8()`..`i128()` / `u8()`..`u128()` / `f16()`..`f128()` | int_widen/narrow/int_to_float/float_to_int |

### 12.3 内建方法覆盖

| 类型 | 方法 | LFE 方案 |
|---|---|---|
| Array | len/is_empty/contains/first/last/push/pop/drop_last | array_len/contains/first/last/push/pop + 内联 |
| str | len/is_empty + 索引 | str_len + str_char_at |
| Atomic | cas/swap + 复合赋值 | atomic_cas/swap/fetch_add/fetch_sub |
| Async | await/cancel/status/result | async_join + async_status |
| Channel | send/recv/close + sender/receiver | channel op |
| Error | message()/type_name()/prefix() | 内联实现 |

### 12.4 不需要的 LaminaOp

基于对 Glue 的深入分析，以下操作实际不需要：

| LaminaOp | 原因 |
|---|---|
| `int_shl` / `int_shr` | Glue 无移位运算符 |
| `extern_call` / `extern_call_batch` | 全内联，无运行时函数调用 |

---

## 13. 实现路线图

### Phase 1: 基础填充（不改架构）

**目标**：填充纯数据流 op，不改变架构。

**引擎**：
- 31 个纯填充 op：int_scale, 浮点数学函数(sqrt/floor/ceil/round/sin/cos/tan/log/exp/pow/scale), char 运算(char_to_int/int_to_char/char_is_alpha/digit/whitespace), mask 运算(mask_and/or/not/zero), 类型转换(int_widen/narrow/int_to_float/float_to_int/float_widen/narrow/int_reinterpret/null_to_nullable)

**编译器**：
- compound_assign（`+= -= *= /= %= &= |=`）
- range 运算符（`..` `..=`）
- type_cast（`Type(value)` 语法）

**验证**：edge_arithmetic 通过

### Phase 2: Value 层优化 + 堆对象

**目标**：优化 Value 层性能，实现堆对象操作。

**Value 层优化**：
- ADT 构造器整数 tag（`ctor_id: u16`）
- TraitValue 方法索引化（`methods: []Value`）
- AtomicValue 标量分支（`std.atomic`）
- ArrayValue COW 引用计数

**引擎**：
- Engine 添加 ObjectPool 引用
- 24 个堆对象 op：字符串(str_concat/len/char_at/slice/to_chars/chars_to_str/eq/starts_with/contains), 数组(array_make/len/get/set/push/map/filter/reduce/concat/slice/to_stream/stream_to_array), 记录(record_make/get/set/has/extend), ADT(adt_make/get_ctor/get_field/test_ctor/match), Newtype(newtype_wrap/unwrap), Nullable(nullable_make/is_null/unwrap/unwrap_or)

**编译器**：
- array_literal, record_literal, field_access, index, safe_access, non_null_assert, record_extend, field_assignment

**验证**：edge_patterns, edge_strings_closures, edge_nullable, edge_throw_records, edge_newtype_safety

### Phase 3: 循环核 + 全内联

**目标**：实现循环和函数调用的纯数据流方案。

**架构扩展**：
- LaminarGraph 添加 loop_kernels 和 defer_entries 字段
- Engine.run 改为支持循环核识别 + runLoopKernel
- 函数指针表替代 executeLamina 的 switch

**编译器**：
- 全内联：调用图分析 + 非递归函数内联
- 递归处理：尾递归 → 循环核，非尾递归 → 显式栈 + 循环核
- while/loop/for → 循环核
- 函数调用 → 编译期内联

**验证**：edge_iterators, edge_recursion_methods, edge_value_semantics

### Phase 4: 闭包 + Trait + 模式匹配

**目标**：实现闭包、Trait、模式匹配的完整支持。

**编译器**：
- 闭包捕获：upvalue 通道绑定
- lambda 内联 / switch_lamina
- trait 单态化 + 方法内联
- match 多 arm + 嵌套模式 + or_pattern + guard
- string_interpolation（str_concat 链）

**验证**：edge_closures, edge_method_dispatch, edge_generic_adt, edge_patterns

### Phase 5: 高级特性

**目标**：实现 defer、select、lazy 等高级特性。

**引擎 + 编译器**：
- defer 注册 + LIFO 执行
- select 多路复用（多通道 try_recv + 优先级选择 + 循环核重试）
- lazy_make/force/is_forced
- 部分应用（编译期部分应用 + 内联）

**验证**：edge_concurrency（完整）, stress_*

### Phase 6: 模块系统 + 泛型单态化

**目标**：实现多模块编译和泛型单态化。

**编译器**：
- compileProgram（多模块 → 单个 LaminarGraph）
- 复用 ModuleLoader
- 跨模块函数内联
- 泛型单态化算法（worklist + 类型驱动）
- 类型特化约束（`with T: ConcreteType`）
- 关联类型替换

**验证**：edge_module_trait, 所有测试通过

### Phase 7: 全程序验证

**目标**：所有测试通过，性能基准测试。

- 所有 edge_* 测试通过
- 所有 phase* 测试通过
- 所有 stress_* 测试通过
- 性能对比 VM（目标 50-100x）
- 性能对比 JIT（目标 8-16x）

---

## 14. 函数指针表替代 switch

### 14.1 当前问题

`executeLamina` 的大 switch 是 decode-dispatch，每次执行都要 switch(op) 分派到对应处理函数。

### 14.2 函数指针表方案

```zig
const Handler = *const fn(*Engine, *const Lamina) EngineError!void;

const handlers = [_]Handler{
    execConstant,
    execBroadcastInput,
    execMove,
    execIntAdd,
    execIntSub,
    // ... 所有 150+ 操作的特化函数
};
```

运行时直接索引调用，无 switch 分支：

```zig
try handlers[@intFromEnum(lam.op)](self, lam);
```

- O(1) 索引，无分支预测失败
- 比 switch-case 更快
- 编译器可以对小函数内联

### 14.3 标量/批处理双路径

每个 handler 内部根据 `element_count` 选择标量或批处理路径：

```zig
fn execIntAdd(engine: *Engine, lam: *const Lamina) EngineError!void {
    if (engine.element_count <= 1) {
        // 标量快速路径
        inline for (ALL_INT_KINDS) |k| {
            if (lam.int_kind.? == k) {
                const T = NativeIntType(k);
                const a = engine.channels[lam.inputs[0]].getScalar(T, 0);
                const b = engine.channels[lam.inputs[1]].getScalar(T, 0);
                engine.channels[lam.output].setScalar(T, 0, a +% b);
                return;
            }
        }
    } else {
        // SIMD 批处理路径
        inline for (ALL_INT_KINDS) |k| {
            if (lam.int_kind.? == k) {
                const T = NativeIntType(k);
                batch.batchBinOp(T, .add, dst, a, b) catch return error.DivisionByZero;
                return;
            }
        }
    }
}
```

---

## 15. 性能预期

### 15.1 与 VM 对比

| 维度 | VM | LFE | 倍数 |
|---|---|---|---|
| 指令分派 | switch-case decode-dispatch | 函数指针表 O(1) 索引 | 5-10x |
| 函数调用 | 栈帧建立/销毁 | 编译期内联，零开销 | ∞ |
| 类型分派 | 运行时 tag 检查 | 编译期单态化，零开销 | ∞ |
| 循环 | PC 跳转 + 分支预测 | 循环核数据流迭代器 | 2-5x |
| SIMD | 无 | 128-bit @Vector 自动向量化 | 4-16x |
| 内存 | Value 24B 数组 | 通道紧凑布局 + 槽位复用 | 3-5x |

### 15.2 与 JIT 对比

| 维度 | JIT | LFE | 优势 |
|---|---|---|---|
| 编译开销 | 运行时编译 | 编译期完成 | 无运行时开销 |
| 间接调用 | 运行时内联缓存 | 编译期全内联 | 无 icache miss |
| 分支预测 | 运行时 profile | 编译期全消除 | 无 mispredict |
| 类型特化 | 运行时 spec | 编译期单态化 | 无运行时开销 |
| 内存布局 | 运行时优化 | 编译期确定 | 可预测 |

### 15.3 性能瓶颈分析

LFE 的性能瓶颈预计在：

1. **代码爆炸**：全内联 + 单态化可能导致层流图过大 → 缓解：死通道消除 + 槽位复用
2. **堆对象操作**：ADT/record/array 的堆分配 → 缓解：ObjectPool + COW
3. **循环核迭代次数**：大数据集循环 → 缓解：SIMD 批处理（一次 K 个迭代）
4. **switch_lamina 路径数**：动态类型场景的路径爆炸 → 缓解：编译器分析减少可能的类型

---

## 附录 A: 关键文件路径

- LFE 核心类型：`/Users/haojunhuang/CLionProjects/Glue/src/lfe/lamina.zig`
- LFE 编译器：`/Users/haojunhuang/CLionProjects/Glue/src/lfe/compiler.zig`
- LFE 引擎：`/Users/haojunhuang/CLionProjects/Glue/src/lfe/engine.zig`
- LFE 调度器：`/Users/haojunhuang/CLionProjects/Glue/src/lfe/scheduler.zig`
- LFE 优化器：`/Users/haojunhuang/CLionProjects/Glue/src/lfe/optimizer.zig`
- Value 层：`/Users/haojunhuang/CLionProjects/Glue/src/value/`
- AST 定义：`/Users/haojunhuang/CLionProjects/Glue/src/parse/ast.zig`
- 语义分析：`/Users/haojunhuang/CLionProjects/Glue/src/sema/`
- 测试用例：`/Users/haojunhuang/CLionProjects/Glue/tests/`

## 附录 B: 与 lfe-design.md 的差异

| 维度 | lfe-design.md（旧） | 本文档（新） |
|---|---|---|
| 函数调用 | extern_call 子图实例化 | 编译期全内联 |
| 递归 | extern_call 嵌套 | 循环核 + 显式栈 |
| Trait 分派 | vtable 查表 | 编译期单态化 / switch_lamina |
| 闭包调用 | closure_call 子图 | 编译期内联 / switch_lamina |
| 循环 | 未明确 | 循环核（数据流迭代器） |
| 层操作执行 | switch-case | 函数指针表 |
| 编译产物 | LaminarGraph + subgraphs | 单个 LaminarGraph（全内联） |
| 泛型 | 未涉及 | 编译期全单态化 |
| 模块系统 | 未涉及 | 复用 ModuleLoader + 全内联 |
