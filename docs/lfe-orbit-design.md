# LFE 星轨架构设计文档

> 太阳与星轨：静态入太阳，动态入轨道

## 目录

- [第 1 节：核心架构——太阳与星轨](#第-1-节核心架构太阳与星轨)
- [第 2 节：轨道枢纽（OrbitHub）](#第-2-节轨道枢纽orbithub)
- [第 3 节：轨道（Orbit）与环形轨道](#第-3-节轨道orbit与环形轨道)
- [第 4 节：通道系统——跨层数据流](#第-4-节通道系统跨层数据流)
- [第 5 节：执行引擎——双层级调度](#第-5-节执行引擎双层级调度)
- [第 6 节：编译器——静态入太阳，动态入轨道](#第-6-节编译器静态入太阳动态入轨道)
- [第 7 节：优化器——跨层优化](#第-7-节优化器跨层优化)
- [第 8 节：Glue 特性全覆盖](#第-8-节glue-特性全覆盖)
- [第 9 节：性能分析](#第-9-节性能分析)
- [第 10 节：数据结构定义](#第-10-节数据结构定义)
- [第 11 节：实施路径](#第-11-节实施路径)

---

## 第 1 节：核心架构——太阳与星轨

### 1.1 双层模型

LFE 分为两个执行层：

**太阳层（Solar Layer）**——静态 DAG。所有编译期可完全确定执行路径的计算在此层。纯数据流，无控制流，无分派。即当前的 `LaminarGraph`。

**星轨层（Orbital Layer）**——动态路径。每条轨道（Orbit）是一段独立的 lamina 序列，物理上与主 DAG 分离存储。轨道有进入条件，条件完全匹配才激活执行。

### 1.2 两层的关系

```
太阳层（DAG）
  │
  │ 数据流 → 条件计算（所有条件并行求值）
  │
  ├─ OrbitHub lamina（轨道枢纽）
  │     │ 读取条件值
  │     │ 匹配轨道 → 激活信号 + 输入数据
  │     ↓
  │  星轨层（独立子图集合）
  │  ┌────────────┬────────────┬────────────┐
  │  │ Orbit 0    │ Orbit 1    │ Orbit 2    │
  │  │ cond: A    │ cond: B    │ cond: C    │
  │  │ [未激活]    │ [激活→执行] │ [未激活]    │
  │  │  零开销     │  lamina序列 │  零开销     │
  │  └────────────┴─────┬──────┴────────────┘
  │                     ↓ 输出通道
  │ 数据流 ← 输出回写
  │
  │ 下游层（读取轨道输出继续计算）
```

### 1.3 关键特性

| 特性 | 机制 |
|---|---|
| **零浪费** | 未激活轨道完全不触及内存，不遍历、不检查 predicate |
| **零分派** | 条件值直接映射到轨道索引（如 ADT tag = 轨道号），枢纽是数据查表非控制流跳转 |
| **环形轨道** | 轨道可标记为环形（cyclic），天然表示循环——行星绕太阳公转 |
| **并行执行** | 独立轨道可并行执行（不同 worker 线程） |
| **缓存友好** | 激活轨道是一段连续 lamina 序列，CPU 预取友好 |

### 1.4 与旧设计的对比

| | 旧 LFE（纯 DAG） | 新 LFE（太阳+星轨） |
|---|---|---|
| 静态计算 | DAG | 太阳层（不变） |
| 动态分支 | 全展开+select（浪费） | 星轨层（零浪费） |
| 循环 | 循环核（DAG 补丁） | 环形轨道（自然） |
| 动态分派 | switch_lamina（仍全展开） | 轨道枢纽（零展开） |
| 资源开销 | N 个分支全计算 | 1 个条件计算 + 1 个轨道执行 |

---

## 第 2 节：轨道枢纽（OrbitHub）

### 2.1 OrbitHub 数据结构

OrbitHub 是太阳层中的一个特殊 lamina，负责将数据从太阳层导入星轨层，并将结果导回。

```
OrbitHub lamina
├─ input_channels: []u16        // 输入通道（条件值 + 轨道参数）
├─ orbit_table: []OrbitEntry    // 轨道表（编译期确定）
├─ output_channel: u16          // 输出回写通道
└─ hub_kind: OrbitHubKind       // 枢纽类型
```

```
OrbitEntry
├─ condition: OrbitCondition     // 进入条件
├─ orbit_index: u16              // 对应轨道索引
└─ param_mapping: []ParamBind    // 参数绑定（输入通道 → 轨道入口通道）
```

```
OrbitCondition
├─ cond_channel: u16             // 条件值所在的太阳层通道
├─ cond_kind: CondKind           // 比较方式
├─ expected_val: i64             // 期望值（ADT tag / bool / int 值）
```

### 2.2 枢纽类型

| hub_kind | 触发场景 | 条件匹配方式 | 轨道数 |
|---|---|---|---|
| `match_hub` | match 表达式 | ADT 构造器 tag == expected_val | 每个 arm 一条 |
| `if_hub` | if-else | bool 通道 == 1 / == 0 | 2 条（then / else） |
| `loop_hub` | while / for / loop | 条件通道 == 1（继续）/ == 0（退出） | 1 条环形轨道 |
| `trait_hub` | 动态 trait 分派 | type_tag == expected_val | 每个类型一条 |
| `error_hub` | error 分支 | error tag == expected_val | 每个 error 类型一条 |

### 2.3 激活机制——零分派的核心

枢纽激活轨道的过程**不是控制流跳转**，而是数据驱动的通道连接：

```
// 引擎执行 OrbitHub 时的伪代码
fn execOrbitHub(hub: OrbitHub):
    // 1. 读取条件值（数据读取，非跳转）
    cond_val = channels[hub.cond_channel].getScalar()

    // 2. 直接索引轨道（O(1) 查表，非 switch 分派）
    entry = hub.orbit_table[cond_val]    // cond_val 直接是轨道索引

    // 3. 绑定参数（通道拷贝，非栈帧建立）
    for binding in entry.param_mapping:
        orbits[entry.orbit_index].input[binding.dst] = channels[binding.src]

    // 4. 激活轨道（设置就绪标志，非 PC 跳转）
    orbits[entry.orbit_index].activate()

    // 5. 轨道执行完毕后输出回写
    channels[hub.output_channel] = orbits[entry.orbit_index].output
```

关键点：**条件值本身就是轨道索引**。编译器在编译期将 ADT tag / bool 值 / type_tag 直接映射为轨道表索引。运行时 `orbit_table[cond_val]` 是一次数组索引，O(1)，无 switch，无间接跳转。

### 2.4 条件不匹配的处理

对于 match 的 wildcard arm（`_`）或 if 没有 else 的情况，编译器生成一条**默认轨道**（default orbit），条件为 `always_match`。保证枢纽总能匹配到一条轨道。

### 2.5 轨道执行与太阳层的关系

轨道执行期间，太阳层暂停在 OrbitHub 处——但这是**数据依赖等待**，不是控制流阻塞。太阳层下游的 lamina 依赖 OrbitHub 的输出通道，数据未就绪时自然不执行。这和 DAG 中"数据就绪驱动执行"一致。

**例外：异步轨道（async_hub）不阻塞太阳层**——详见第 2.6 节。

### 2.6 两种 OrbitHub 模式

```
OrbitHubKind
├─ sync_hub     // 同步：主 DAG 等待轨道输出（match / if 分支结果）
└─ async_hub    // 异步：主 DAG 不等待，继续执行（协程 / fire-and-forget）
```

| 模式 | 主 DAG 行为 | 轨道行为 | 场景 |
|---|---|---|---|
| `sync_hub` | 数据依赖等待，轨道输出就绪后下游执行 | 执行完毕回写输出通道 | match arm、if-else、循环体 |
| `async_hub` | 不等待，立即继续执行后续 lamina | 独立并行执行，输出通过 channel/async_join 回传 | async fun、协程、fire-and-forget |

### 2.7 异步轨道与主 DAG 的同步

异步轨道不在 OrbitHub 处同步，而是通过**显式同步点**：

```
太阳层：
  ├─ lamina: async_create → OrbitHub(async_hub)
  │     ↓ 激活 Orbit N，不等待
  ├─ lamina: 继续执行（不等 Orbit N）     ← 关键：主 DAG 不阻塞
  ├─ ... 更多 lamina ...
  ├─ lamina: async_join(async_handle)     ← 显式同步点
  │     读取 Orbit N 的输出通道
  └─ 下游 lamina
```

async_join 是一个特殊 lamina——如果轨道未完成，当前执行流挂起（协程调度器切换到其他任务）；如果已完成，直接读取输出。

### 2.8 多轨道并行

一个主 DAG 可以同时激活多条异步轨道，它们并行运行：

```
太阳层：
  ├─ OrbitHub(async_hub) → 激活 Orbit A    ┐
  ├─ OrbitHub(async_hub) → 激活 Orbit B    │  三条轨道
  ├─ OrbitHub(async_hub) → 激活 Orbit C    │  并行运行
  ├─ ... 主 DAG 继续执行 ...                ┘
  ├─ async_join(A) → 读取结果
  ├─ async_join(B) → 读取结果
  └─ async_join(C) → 读取结果
```

这直接映射到现有的 M:N 协程调度器（`scheduler.zig`）——worker 线程从轨道队列取轨道执行，多个轨道在不同线程上并行。

### 2.9 修正后的双层关系

```
太阳层（主 DAG）
  │
  ├─ sync_hub: 等待轨道输出（分支选择）
  │     ↓ 数据依赖等待
  │  [轨道执行] → 输出回写 → 主 DAG 继续
  │
  ├─ async_hub: 不等待（协程）
  │     ↓ 激活信号
  │  [轨道并行执行] ←→ 主 DAG 同时继续
  │     ↓ 输出通过 async_join / channel 回传
  │
  └─ 主 DAG 继续后续 lamina
```

核心：**OrbitHub 不总是同步点**。sync_hub 是数据依赖等待（和 DAG 中其他数据依赖一样），async_hub 是纯激活信号（主 DAG 立即继续）。

---

## 第 3 节：轨道（Orbit）与环形轨道

### 3.1 Orbit 数据结构

```
Orbit
├─ laminas: []Lamina            // 轨道内的 lamina 序列（连续内存）
├─ input_channels: []u16        // 入口通道（从太阳层接收数据）
├─ output_channel: u16          // 出口通道（结果回写太阳层）
├─ is_cyclic: bool              // 是否环形轨道（循环）
├─ continue_channel: ?u16       // 环形轨道的继续条件通道
├─ nested_hubs: []u16           // 轨道内嵌套的 OrbitHub 索引
├─ state: OrbitState            // 运行时状态
└─ orbit_index: u16             // 自身索引（用于嵌套激活）
```

```
OrbitState
├─ inactive                     // 未激活——零开销
├─ running                      // 正在执行 lamina 序列
├─ waiting_nested               // 等待嵌套轨道完成
└─ done                         // 执行完毕，输出已回写
```

### 3.2 普通轨道执行（match arm / if 分支）

普通轨道是一次性执行的 lamina 序列：

```
激活 → 执行 laminas[0..N] → 输出回写 → 状态变 done
```

轨道内的 lamina 可以包含嵌套的 OrbitHub——即轨道内可以有子轨道。这支持嵌套 match 和 if-else if-else 链。

### 3.3 环形轨道（循环）

环形轨道是星轨设计的核心突破——**循环不是 DAG 的补丁，而是轨道的天然形态**。

```
while cond { body }

编译为：
  太阳层：
    条件初始化 → OrbitHub(loop_hub, cyclic=true) → 下游

  星轨层：
    Orbit 0 (环形):
      入口: 接收循环变量
      ├─ lamina: 计算条件 → continue_channel
      ├─ lamina: 条件为 false → 输出回写，状态变 done
      ├─ lamina: 条件为 true → 执行循环体
      └─ 循环体末尾: 更新循环变量 → 回到入口（公转）
```

环形轨道的执行算法：

```
fn execCyclicOrbit(orbit: *Orbit):
    while true:
        // 执行轨道内 lamina 序列
        for lam in orbit.laminas:
            executeLamina(lam)

        // 检查继续条件
        if orbit.continue_channel:
            if channels[orbit.continue_channel] == 0:
                break   // 退出公转

        // 循环变量已更新，回到轨道入口继续公转
        // 无 PC 跳转——这是数据驱动的重复执行
```

关键区别：循环变量更新是**数据通道写入**，回到入口是**重复执行同一段 lamina 序列**。不是指令地址跳转，是数据流迭代。CPU 指令缓存命中率高（同一段代码反复执行），且循环体内的无依赖 lamina 可被优化器重排为 SIMD 并行。

### 3.4 环形轨道与递归

递归函数编译为环形轨道 + 显式数据栈：

```
fun fib(n: i32): i32 {
    if n < 2 { return n }
    return fib(n-1) + fib(n-2)
}

编译为：
  Orbit 0 (环形，递归):
    ├─ OrbitHub(if_hub):
    │    ├─ n < 2 → Orbit 1 (终止): 输出 n
    │    └─ else → Orbit 2 (递归):
    │         ├─ push stack: fib(n-1) 的调用帧
    │         ├─ 激活 Orbit 0 处理 fib(n-1)
    │         ├─ push stack: fib(n-2) 的调用帧
    │         ├─ 激活 Orbit 0 处理 fib(n-2)
    │         └─ 两次结果相加 → 输出
    └─ (循环直到栈空)
```

显式数据栈是一条特殊通道（`stack_channel`），存储调用帧。不是 CPU 栈，不是函数调用——是数据流中的栈结构。

### 3.5 轨道内存布局

轨道的 laminas 在内存中**连续排列**，一个轨道一个块：

```
内存布局：
┌─────────────────────────────┐
│ 太阳层 laminas（主 DAG）      │  连续
├─────────────────────────────┤
│ Orbit 0 laminas              │  连续
├─────────────────────────────┤
│ Orbit 1 laminas              │  连续
├─────────────────────────────┤
│ Orbit 2 laminas (环形)        │  连续
├─────────────────────────────┤
│ 通道存储（所有层共享）         │  连续
└─────────────────────────────┘
```

未激活轨道的 lamina 块不会被 CPU 访问——不污染缓存，不占带宽。激活轨道是连续执行，CPU 预取器高效工作。

---

## 第 4 节：通道系统——跨层数据流

### 4.1 通道层级

太阳层和星轨层共享同一个通道存储，但通道有归属标记：

```
ChannelScope
├─ solar          // 太阳层通道（主 DAG）
├─ orbit          // 轨道内部通道（特定轨道私有）
├─ bridge_in      // 桥接入口（太阳层 → 轨道）
└─ bridge_out     // 桥接出口（轨道 → 太阳层）
```

### 4.2 桥接通道

轨道不直接访问太阳层通道——通过桥接通道传递数据：

```
太阳层通道 ch_x (solar)
  ↓ OrbitHub 参数绑定
桥接入口 ch_x_in (bridge_in) → 轨道内读取
  ↓ 轨道执行
桥接出口 ch_result_out (bridge_out) → 太阳层读取
  ↓
太阳层通道 ch_result (solar)
```

为什么需要桥接而非直接共享：
1. **环形轨道**：每次公转，入口通道被重新写入新值，但太阳层原通道不变
2. **异步轨道**：轨道并行运行，桥接通道是轨道私有拷贝，避免数据竞争
3. **轨道复用**：同一个轨道模板可被多次激活（如循环体），每次激活有独立的桥接通道实例

### 4.3 通道实例化

编译期只生成通道模板，运行时按轨道激活实例化：

```
通道存储布局：
┌──────────────────────────────┐
│ solar channels[0..N]         │  编译期固定
├──────────────────────────────┤
│ bridge_in[0..M]              │  编译期固定模板
├──────────────────────────────┤
│ bridge_out[0..M]             │  编译期固定模板
├──────────────────────────────┤
│ orbit channels[0..K]         │  轨道私有，激活时分配
├──────────────────────────────┤
│ async instances              │  异步轨道实例（可多个）
│  ├─ instance 0: bridge+orbit │
│  ├─ instance 1: bridge+orbit │
│  └─ instance 2: bridge+orbit │
└──────────────────────────────┘
```

轨道私有通道从 arena 分配（bump+reset），轨道执行完毕后释放。异步轨道实例的通道与协程任务绑定，任务结束后释放。

### 4.4 通道活跃性分析

编译期对通道做活跃性分析，复用槽位：

```
solar ch_a:     [████████░░░░░░░░░░░░░░]  活跃区间 0-8
orbit ch_x:     [░░░░░░░░████░░░░░░░░░░]  活跃区间 8-12
bridge ch_in:   [░░░░░░░░██░░░░░░░░░░░░]  活跃区间 8-10
bridge ch_out:  [░░░░░░░░░░░░██░░░░░░░░]  活跃区间 11-13
solar ch_b:     [░░░░░░░░░░░░░░████████]  活跃区间 13-20

→ ch_a 和 ch_x 可复用同一槽位（区间不重叠）
→ ch_in 和 ch_out 可复用同一槽位
```

这是现有优化器已有的机制，星轨层只是扩展了分析范围——把轨道内通道也纳入活跃性分析。

### 4.5 async_hub 的通道处理

异步轨道的桥接通道需要特殊处理——不能复用，因为多个实例可能同时活跃：

```
async Orbit N 被激活 3 次（如循环中创建多个协程）：
  instance 0: bridge_in_0, bridge_out_0, orbit_ch_0
  instance 1: bridge_in_1, bridge_out_1, orbit_ch_1
  instance 2: bridge_in_2, bridge_out_2, orbit_ch_2

async_handle = instance_index   // 句柄就是实例索引
async_join(handle) → 读取 instance[handle].bridge_out
```

实例通道从协程调度器的 arena 分配，随任务释放。这和现有 `scheduler.zig` 的 `LfeTask` 内存管理一致。

---

## 第 5 节：执行引擎——双层级调度

### 5.1 引擎核心结构

```
Engine
├─ graph: *LaminarGraph           // 太阳层（主 DAG）
├─ orbits: []Orbit                // 星轨层（所有轨道）
├─ channels: ChannelStore         // 统一通道存储
├─ scheduler: ?*Scheduler         // 协程调度器（异步轨道用）
├─ active_orbits: Queue           // 待执行的已激活轨道队列
├─ halt_reason: HaltReason        // 主 DAG 停止原因
└─ result: Value                  // 返回值
```

### 5.2 太阳层执行

太阳层仍是线性遍历 laminas，但遇到 OrbitHub 时分两种路径：

```
fn runSolar(self: *Engine):
    for lam in self.graph.laminas:
        if self.halt_reason != .none: break

        if lam.op == .orbit_hub:
            try self.execOrbitHub(lam)
        else:
            try self.executeLamina(lam)
```

### 5.3 OrbitHub 执行

```
fn execOrbitHub(self: *Engine, lam: Lamina):
    hub = lam.orbit_hub

    // 1. 读取条件值（仅 sync_hub）
    orbit_idx = if (hub.kind == .async_hub)
        0  // async 直接用预分配的轨道
    else
        self.readConditionAndMatch(hub)  // 条件值 → 轨道索引

    // 2. 绑定参数（桥接入口通道写入）
    orbit = &self.orbits[orbit_idx]
    for binding in hub.param_mapping:
        orbit.input[binding.dst] = self.channels[binding.src]

    // 3. 激活轨道
    orbit.state = .running

    // 4. 按模式处理
    switch hub.kind:
        .sync_hub:
            // 同步：立即执行轨道，等待输出
            try self.runOrbit(orbit)
            // 输出回写太阳层
            self.channels[hub.output_channel] = orbit.output

        .async_hub:
            // 异步：轨道入队，不等待
            self.active_orbits.push(orbit)
            // 返回句柄（轨道实例索引）
            self.channels[hub.output_channel] = orbit.instance_index
```

### 5.4 轨道执行

```
fn runOrbit(self: *Engine, orbit: *Orbit):
    if orbit.is_cyclic:
        // 环形轨道：数据驱动重复执行
        while true:
            for lam in orbit.laminas:
                if lam.op == .orbit_hub:
                    try self.execOrbitHub(lam)  // 嵌套枢纽
                else:
                    try self.executeLamina(lam)

            // 检查继续条件
            if orbit.continue_channel:
                if self.channels[orbit.continue_channel] == 0:
                    break
            else:
                break
    else:
        // 普通轨道：单次执行
        for lam in orbit.laminas:
            if lam.op == .orbit_hub:
                try self.execOrbitHub(lam)
            else:
                try self.executeLamina(lam)

    orbit.state = .done
```

关键点：**轨道内的 lamina 用同一套 `executeLamina` 执行**——轨道和太阳层共享同一套 op 处理函数指针表。轨道不是新的执行模型，只是新的调度单元。

### 5.5 异步轨道与调度器

异步轨道由协程调度器分发到 worker 线程：

```
// 主线程：太阳层执行 + 同步轨道
fn run(self: *Engine):
    try self.runSolar()

    // 太阳层结束后，等待所有异步轨道完成
    while self.active_orbits.len > 0:
        orbit = self.active_orbits.pop()
        // 如果有 scheduler，轨道在 worker 线程上执行
        // 如果没有，主线程执行
        try self.runOrbit(orbit)

    return self.result
```

有 scheduler 时，异步轨道分发到 worker 线程并行执行。async_join 处检查轨道状态——未完成则挂起当前任务，切换到其他任务。

### 5.6 函数指针表分派

太阳层和星轨层共用同一张函数指针表，消除 switch-case 分派：

```
// 编译期生成的函数指针表
const handlers = [_]Handler{
    execConstant,
    execIntAdd,
    execFloatMul,
    // ... 所有 op 的处理函数
    execOrbitHub,      // OrbitHub 也在表中
    execAsyncJoin,
    // ...
};

// 执行单个 lamina — O(1) 索引，无 switch
fn executeLamina(self: *Engine, lam: Lamina):
    const handler = handlers[@intFromEnum(lam.op)]
    try handler(self, lam)
```

这满足铁律——无 switch 分发。所有 op（包括 OrbitHub）通过函数指针表 O(1) 索引执行。

---

## 第 6 节：编译器——静态入太阳，动态入轨道

### 6.1 唯一规则

```
编译期完全确定执行路径？
  是 → 太阳层
  否 → 轨道层
```

没有中间地带，没有"路径确定但次数不确定"这种模糊分类。

### 6.2 静态/动态分类

| 构造 | 完全静态？ | 编译目标 |
|---|---|---|
| `a + b` | 是 | 太阳层 |
| `add(1, 2)`（无分支函数） | 是 | 内联到太阳层 |
| `add(x, y)`（无分支函数） | 是 | 内联到太阳层 |
| `if cond { A } else { B }` | 否 | 轨道层 |
| `match x { ... }` | 否 | 轨道层 |
| `while` / `for` / `loop` | 否 | 环形轨道 |
| 递归（含 if/match 的函数） | 否 | 轨道层 |
| `async fun()` | 否 | 异步轨道 |
| 动态 trait 分派 | 否 | 轨道层 |

关键：**递归函数只要含动态分支（if/match），就是动态的，整体进轨道层。** 即使递归调用本身路径确定，但函数体内的动态分支使整体不确定。

### 6.3 细粒度分层——局部动态切分

编译器以**表达式为粒度**判断静态/动态，而非以函数为粒度：

```
fun compute(x: i32, y: i32): i32 {
    val a = x + y                      // 静态 → 太阳层
    val b = x * y                      // 静态 → 太阳层
    val c = if a > b { a } else { b }  // 动态 → 轨道层（OrbitHub + 2 轨道）
    val d = c + 1                      // 静态 → 太阳层（依赖 c，在 OrbitHub 之后）
    d                                  // 静态 → 太阳层
}
```

编译结果：

```
太阳层：
    ch_a = int_add(ch_x, ch_y)
    ch_b = int_mul(ch_x, ch_y)
    ch_cond = int_gt(ch_a, ch_b)
    OrbitHub(if_hub) {
        cond: ch_cond,
        orbits: [0, 1],
        output: ch_c,        // 输出回写太阳层
    }
    ch_d = int_add(ch_c, 1)  // 太阳层继续，读取轨道输出
    halt_return(ch_d)

轨道层：
    Orbit 0 (then): output = ch_a
    Orbit 1 (else): output = ch_b
```

### 6.4 静态/动态判定算法

编译器对每个表达式递归判定：

```
fn isStatic(expr) bool:
    switch expr:
        .literal → true
        .identifier → true
        .binary(op, lhs, rhs) → isStatic(lhs) and isStatic(rhs)
        .field_access(obj, _) → isStatic(obj)
        .call(callee, args) →
            all isStatic(args)
            and 函数 callee 的函数体 isStaticBody()
        .if_expr → false           // 动态
        .match → false              // 动态
        .while/for/loop → false    // 动态
        .lambda → true             // 闭包构造本身静态
        .async_call → false        // 动态

fn isStaticBody(fn) bool:
    检查函数体所有表达式：
        全部 isStatic → true
        含任意动态 → false
```

### 6.5 编译器发射策略

```
fn compileExpr(expr) → channel:
    if isStatic(expr):
        // 静态：发射到当前层（太阳层或轨道内）
        return compileStatic(expr)
    else:
        // 动态：发射 OrbitHub + 轨道到当前层
        return compileDynamic(expr)

fn compileDynamic(expr) → channel:
    switch expr:
        .if_expr(cond, then, else) →
            ch_cond = compileExpr(cond)  // cond 可能静态
            // then/else 各编译为一个轨道
            // 轨道内部递归调用 compileExpr
            //   → 轨道内静态部分内联到轨道内
            //   → 轨道内动态部分生成嵌套轨道
            OrbitHub(if_hub, ch_cond, [orbit0, orbit1])
        .match → ...
        .loop → ...
```

### 6.6 嵌套动态的处理

轨道内部如果还有动态表达式，生成嵌套轨道：

```
fun compute(x): i32 {
    if x > 0 {
        if x > 10 { 100 } else { 50 }   // 嵌套 if
    } else {
        0
    }
}
```

```
太阳层：
    OrbitHub(if_hub, ch_x_gt_0)
        → Orbit 0 (then)
        → Orbit 1 (else: output=0)

Orbit 0 (then):
    ch_x_gt_10 = int_gt(ch_x, 10)
    OrbitHub(if_hub, ch_x_gt_10)        // 嵌套轨道枢纽
        → Orbit 2 (then: output=100)
        → Orbit 3 (else: output=50)
    output = 嵌套枢纽输出
```

轨道内可以无限嵌套轨道——每层只处理自己的动态部分，静态部分内联在轨道内。

### 6.7 函数调用的细粒度内联

函数内联到调用点所在的层，但**不改变层的属性**：

```
fun helper(a): i32 { a * 2 }           // 完全静态
fn compute(x): i32 {
    val a = x + 1                       // 静态
    val b = helper(a)                   // 静态（helper 无分支）→ 内联到太阳层
    val c = if b > 0 { b } else { 0 }   // 动态 → 轨道
    c
}
```

```
太阳层：
    ch_a = int_add(ch_x, 1)
    ch_b = int_mul(ch_a, 2)            // helper 内联
    ch_cond = int_gt(ch_b, 0)
    OrbitHub(if_hub, ch_cond) → ch_c
    halt_return(ch_c)
```

`helper` 完全静态，内联到太阳层，不产生轨道。只有 `if` 产生轨道。

### 6.8 match 表达式编译

```
match shape {
    Circle(r) => area(r),
    Rect(w, h) => w * h,
    _ => 0,
}
```

```
// 太阳层：无任何条件计算（条件匹配在轨道枢纽内完成）
OrbitHub {
    kind: match_hub,
    cond_channel: ch_shape,      // 直接用 ADT 值
    orbit_table: [
        { cond: tag==0, orbit: 0 },  // Circle
        { cond: tag==1, orbit: 1 },  // Rect
        { cond: always, orbit: 2 },  // wildcard
    ],
    output_channel: ch_result,
}

// 星轨层：只有匹配的轨道执行
Orbit 0 (Circle):
    ch_r = adt_get_field(ch_shape, "radius")
    ch_area = call(area, ch_r)     // area 函数体内联到此处
    output = ch_area

Orbit 1 (Rect):
    ch_w = adt_get_field(ch_shape, "width")
    ch_h = adt_get_field(ch_shape, "height")
    output = float_mul(ch_w, ch_h)

Orbit 2 (wildcard):
    output = constant(0)
```

### 6.9 if-else 编译

```
if cond { then_branch } else { else_branch }
```

```
// 太阳层
ch_cond = compileExpr(cond)
OrbitHub {
    kind: if_hub,        // sync_hub
    cond_channel: ch_cond,
    orbit_table: [
        { cond: ch_cond==1, orbit: 0 },  // then
        { cond: ch_cond==0, orbit: 1 },  // else
    ],
    output_channel: ch_result,
}

// 星轨层
Orbit 0 (then): compileExpr(then_branch) → output
Orbit 1 (else): compileExpr(else_branch) → output
```

### 6.10 while 循环编译

```
while cond { body }
```

```
// 太阳层：OrbitHub 激活环形轨道
OrbitHub {
    kind: loop_hub,
    orbit: 0,                // 环形轨道
    output_channel: ch_result,
}

// 星轨层
Orbit 0 (环形):
    ch_cond = <编译 cond，内联到此>
    // 条件检查——动态分支
    OrbitHub {
        kind: if_hub,
        cond_channel: ch_cond,
        orbit_table: [
            { cond: ==1, orbit: 1 },  // 执行循环体
            { cond: ==0, orbit: 2 },  // 退出
        ],
    }
Orbit 1 (循环体): <编译 body，内联到此> → 回到 Orbit 0
Orbit 2 (退出): output = unit
```

### 6.11 函数调用编译——全内联

```
fun add(a: i32, b: i32): i32 { a + b }

// 调用点
val x = add(1, 2)
```

编译为**太阳层直接内联**（函数体小）或**轨道**（函数体大/递归）：

```
// 小函数：直接内联到太阳层（无轨道开销）
ch_a = constant(1)
ch_b = constant(2)
ch_result = int_add(ch_a, ch_b)

// 大函数/递归：编译为轨道模板，调用点发射 OrbitHub
OrbitHub {
    kind: sync_hub,
    orbit: template_instantiation(add, i32, i32),
    param_mapping: [ch_a → in0, ch_b → in1],
    output_channel: ch_result,
}
```

编译器决策规则：
- 函数体 ≤ 8 个 lamina → 直接内联到调用点
- 函数体 > 8 个 lamina 或含循环/递归 → 编译为轨道，调用点用 OrbitHub

### 6.12 async fun 编译

```
async fun fetch_data(url: str): str { ... }

// 调用点
val handle = fetch_data("http://...")
```

```
// 太阳层
OrbitHub {
    kind: async_hub,     // 异步：不等待
    orbit: template(fetch_data),
    param_mapping: [ch_url → in0],
    output_channel: ch_handle,  // 输出是句柄，不是结果
}

// 星轨层
Orbit N (异步): compileBody(fetch_data) → output
// output 通过 async_join 读取，不回写 OrbitHub
```

### 6.13 内联深度控制

全内联可能导致代码爆炸。控制策略：

- 单态化后的函数体 ≤ 16 lamina → 内联
- 函数体 > 16 lamina → 内联一次，后续调用点引用同一轨道模板（但仍内联到所在层，不产生新轨道）
- 递归深度编译期上限：展开 ≤ 3 层，超过则用环形轨道 + 显式栈

---

## 第 7 节：优化器——跨层优化

### 7.1 优化器扩展

优化器在现有 4 个 pass（常量折叠、死通道消除、层融合、通道活跃性）基础上增加 3 个星轨专用 pass：

```
Optimizer passes:
  // 现有（太阳层）
  1. constantFolding        // 常量折叠
  2. deadChannelElim        // 死通道消除
  3. laminaFusion           // 层融合（scale_add/fma）
  4. channelLiveness        // 通道活跃性 + 槽位复用

  // 新增（星轨层）
  5. orbitMerging           // 轨道合并
  6. orbitDeadCode          // 轨道死代码消除
  7. staticHoisting         // 静态提升（轨道内静态代码提到太阳层）
```

### 7.2 静态提升（staticHoisting）

轨道内可能有静态代码——编译时因为函数含动态分支整体进了轨道，但部分 lamina 是静态的。优化器将这些静态 lamina 提升到太阳层：

```
优化前：
太阳层：OrbitHub(if_hub, ch_cond) → ch_result

Orbit 0 (then):
    ch_a = int_add(ch_x, 1)           // 静态！不依赖轨道条件
    ch_b = int_mul(ch_a, 2)           // 静态！
    output = ch_b

Orbit 1 (else):
    ch_c = int_add(ch_x, 1)           // 静态！与 Orbit 0 相同
    ch_d = int_mul(ch_c, 3)           // 静态！
    output = ch_d

优化后：
太阳层：
    ch_a = int_add(ch_x, 1)           // 提升到太阳层
    OrbitHub(if_hub, ch_cond)
        Orbit 0: output = int_mul(ch_a, 2)
        Orbit 1: output = int_mul(ch_a, 3)
    → ch_result
```

提升条件：
1. lamina 不依赖轨道的输入参数（只依赖太阳层通道）
2. lamina 在所有兄弟轨道中完全相同（可去重）
3. lamina 无副作用

### 7.3 轨道合并（orbitMerging）

合并只对**极简轨道**有效——轨道体本身很轻，OrbitHub 的激活开销反而比计算还大：

```
OrbitHub 开销 ≈ 条件计算 + 轨道索引 + 参数绑定 + 状态切换
             ≈ 5-8 个隐含操作

如果轨道体 ≤ 3 个 lamina 且无嵌套：
    OrbitHub 开销 > 轨道体开销 → 合并有利

如果轨道体 > 3 个 lamina 或含嵌套轨道：
    OrbitHub 开销 < 轨道体开销 → 合并有害（退化为全计算）
```

合并条件（全部满足才合并）：

1. 轨道数 ≤ 4
2. 每条轨道 lamina 数 ≤ 3
3. 各轨道 lamina 结构相同，仅常量参数不同
4. 各轨道均无副作用
5. **无嵌套轨道**——含嵌套 OrbitHub 的轨道不合并

```
// 可合并（简单计算）
match tag { 0 => x+1, 1 => x+2, _ => x }
// 每条轨道 1 个 lamina，合并为 select + add

// 不可合并（复杂计算）
match tag { 0 => fibonacci(x), 1 => sort(x), _ => 0 }
// 轨道体复杂，合并会导致三个计算全执行
```

### 7.3a 替代优化：轨道特化

对于复杂但结构相似的轨道，不做合并，而做**特化**——提取公共前缀/后缀到太阳层，只保留差异部分在轨道内：

```
优化前：
Orbit 0: ch_a = int_add(ch_x, 1); ch_b = float_mul(ch_a, pi); ch_c = float_sqrt(ch_b); output = ch_c
Orbit 1: ch_a = int_add(ch_x, 2); ch_b = float_mul(ch_a, pi); ch_c = float_sqrt(ch_b); output = ch_c

优化后（公共后缀提取到太阳层）：
太阳层：
    ch_diff = select(ch_cond, 1, 2)        // 只有差异部分用 select
    ch_a = int_add(ch_x, ch_diff)
    OrbitHub(skip)                          // 无轨道，直接继续
    ch_b = float_mul(ch_a, pi)             // 公共后缀在太阳层
    ch_c = float_sqrt(ch_b)

// 实际上整个 OrbitHub 被消除了，因为差异只是一个常量
```

但如果差异不是简单常量：

```
Orbit 0: ch_a = int_add(ch_x, 1); ch_b = heavy_compute_a(ch_a); output = ch_b
Orbit 1: ch_a = int_add(ch_x, 2); ch_b = heavy_compute_b(ch_a); output = ch_b

// 公共前缀可提取，但 heavy_compute 不同 → 不合并，只提取前缀
太阳层：
    ch_diff = select(ch_cond, 1, 2)
    ch_a = int_add(ch_x, ch_diff)
    OrbitHub(if_hub, ch_cond)
        Orbit 0: ch_b = heavy_compute_a(ch_a); output = ch_b
        Orbit 1: ch_b = heavy_compute_b(ch_a); output = ch_b
```

### 7.3b 优化器决策流程

```
fn tryOptimizeOrbits(hub, orbits):
    if allOrbitsSimple(orbits, max_laminas=3, no_nested=true):
        // 简单轨道：尝试合并为 select
        if canMergeToSelect(orbits):
            return mergeToSelect(hub, orbits)    // 消除轨道

    // 复杂轨道：尝试提取公共前缀/后缀
    prefix = extractCommonPrefix(orbits)         // 提到太阳层
    suffix = extractCommonSuffix(orbits)         // 提到太阳层
    if prefix or suffix:
        rewriteOrbits(orbits, without=prefix+suffix)
        emitToSolar(prefix)
        emitToSolar(suffix)

    // 无法优化：保持轨道不变
```

核心原则：**轨道是零浪费的（只执行匹配的），合并会退化为全计算。只有当轨道体比 OrbitHub 开销还小时，合并才有意义。**

### 7.4 轨道死代码消除（orbitDeadCode）

```
优化前：
OrbitHub(match_hub, ch_tag)
    Orbit 0: output = ch_x     // 但下游从不读取 output（被后续覆盖）
    Orbit 1: output = ch_y
    Orbit 2: output = ch_z

优化后（如果 match 结果在所有情况下被覆盖）：
// 整个 OrbitHub 消除
```

条件：
1. OrbitHub 输出通道从未被下游读取
2. 所有轨道无副作用

### 7.5 通道活跃性扩展

通道活跃性分析扩展到跨层：

```
solar ch_a:     [██████░░░░░░░░░░░░░░░░]  0-6
orbit_0 ch_x:   [░░░░░░██░░░░░░░░░░░░░░]  4-8  ← 可与 ch_a 复用
orbit_1 ch_y:   [░░░░░░░░██░░░░░░░░░░░░]  7-9  ← 可与 ch_a 复用
bridge ch_out:  [░░░░░░░░░░░░██░░░░░░░░]  10-12
solar ch_b:     [░░░░░░░░░░░░░░████████]  12-20 ← 可与 ch_out 复用
```

轨道内通道的活跃区间只在轨道执行期间——非激活时该槽位可被其他轨道或太阳层复用。

### 7.6 优化器执行顺序

```
optimize(graph, orbits):
    // 第一轮：太阳层优化
    constantFolding(graph)
    deadChannelElim(graph)
    laminaFusion(graph)

    // 第二轮：星轨层优化
    staticHoisting(graph, orbits)       // 先提升，让太阳层有更多可优化代码
    orbitMerging(graph, orbits)         // 再合并，可能消除轨道
    orbitDeadCode(graph, orbits)        // 再消除死轨道

    // 第三轮：联合优化
    channelLiveness(graph, orbits)      // 跨层通道复用
    constantFolding(graph)              // 提升后可能产生新的常量折叠机会
```

---

## 第 8 节：Glue 特性全覆盖

### 8.1 特性-机制映射

| Glue 特性 | 静态/动态 | 编译目标 | 机制 |
|---|---|---|---|
| 字面量 | 静态 | 太阳层 | `constant` |
| 算术/位运算/比较 | 静态 | 太阳层 | `int_*/float_*/bool_*` op |
| `if-else` | 动态 | 轨道层 | `OrbitHub(if_hub)` + 2 轨道 |
| `match` | 动态 | 轨道层 | `OrbitHub(match_hub)` + N 轨道 |
| `while/for/loop` | 动态 | 轨道层 | `OrbitHub(loop_hub)` + 环形轨道 |
| 无分支函数调用 | 静态 | 太阳层 | 内联到调用点 |
| 含分支函数调用 | 动态 | 轨道层 | 调用点发射 OrbitHub + 轨道模板 |
| 递归 | 动态 | 轨道层 | 环形轨道 + 显式数据栈 |
| `async fun()` | 动态 | 轨道层 | `OrbitHub(async_hub)` + 异步轨道 |
| `async lambda` | 动态 | 轨道层 | 同 async fun |
| 闭包（目标已知） | 静态 | 太阳层 | 内联 |
| 闭包（目标未知） | 动态 | 轨道层 | `OrbitHub(closure_hub)` |
| Trait 方法（静态单态化） | 静态 | 太阳层 | 内联 |
| Trait 方法（动态分派） | 动态 | 轨道层 | `OrbitHub(trait_hub)` + 每类型一轨道 |
| `defer` | 静态 | 太阳层 | halt 时 LIFO 执行 |
| `?` 传播 | 动态 | 轨道层 | `OrbitHub(error_hub)` |
| `?.` / `??` / `!` | 动态 | 轨道层 | `OrbitHub(nullable_hub)` |
| `select` 多路复用 | 动态 | 轨道层 | 多通道 try_recv + 循环轨道 |
| `throw` | 静态 | 太阳层 | `halt_throw` |
| `try { } catch { }` | 动态 | 轨道层 | `OrbitHub(error_hub)` |
| 泛型 | 编译期消除 | 太阳层/轨道层 | 单态化后按内容判定 |
| 关联类型 | 编译期消除 | 太阳层/轨道层 | 单态化时替换 |
| 模块系统 | 编译期 | 太阳层/轨道层 | 跨模块内联 |

### 8.2 defer 编译

defer 不产生轨道——它是 halt 时的附加执行序列：

```
fun process(): i32 {
    defer cleanup()
    val x = compute()
    if x > 0 { return x } else { return 0 }
}
```

```
太阳层：
    注册 defer: cleanup → defer_stack
    ch_x = compute()（内联或轨道）
    OrbitHub(if_hub) → ch_result
halt 时：
    LIFO 执行 defer_stack: cleanup()
    return ch_result
```

defer_stack 是引擎中的一个 LIFO 队列，halt_return/halt_throw 时先执行 defer 再返回。

### 8.3 ? 传播编译

```
val result = might_fail()?
```

`?` 是动态的——运行时才知道是成功还是失败：

```
太阳层：
    ch_throwable = call(might_fail)       // 内联到太阳层（如果无分支）
    OrbitHub(error_hub) {
        cond: ch_throwable.is_ok
        orbit_table: [
            { cond: is_ok==1, orbit: 0 },  // 成功：解包值
            { cond: is_ok==0, orbit: 1 },  // 失败：halt_throw
        ],
        output: ch_result,
    }
Orbit 0 (ok): output = throw_get_ok(ch_throwable)
Orbit 1 (err): halt_throw(ch_throwable)
```

### 8.4 动态 Trait 分派

```
trait Shape { fun area(self): f64 }
type Circle: Shape = Circle(r: f64) { fun area(self): f64 { pi * r * r } }
type Rect: Shape = Rect(w: f64, h: f64) { fun area(self): f64 { w * h } }

fun total_area(shapes: [Shape]): f64 {
    var sum = 0.0
    for s in shapes { sum = sum + s.area() }  // 动态分派
    sum
}
```

```
// s.area() 编译为 OrbitHub(trait_hub)
太阳层：
    ch_type_tag = trait_get_tag(ch_s)
    OrbitHub(trait_hub) {
        cond: ch_type_tag,
        orbit_table: [
            { cond: tag==Circle, orbit: 0 },
            { cond: tag==Rect,   orbit: 1 },
        ],
        output: ch_area,
    }
Orbit 0 (Circle): ch_r = field_get(ch_s, "r"); output = float_mul(float_mul(ch_r, ch_r), pi)
Orbit 1 (Rect):   ch_w = field_get(ch_s, "w"); ch_h = field_get(ch_s, "h"); output = float_mul(ch_w, ch_h)
```

如果 `Shape` 有 10 个实现类型，trait_hub 有 10 条轨道。但每次只执行 1 条——零浪费。type_tag 到 orbit_index 的映射是编译期确定的直接索引。

### 8.5 闭包分派

```
fun apply(f: fn(i32): i32, x: i32): i32 { f(x) }

// 调用点1: apply(n => n + 1, 5)
// 调用点2: apply(n => n * 2, 3)
```

如果 `f` 的目标编译期可确定（直接传 lambda），内联到太阳层。如果不可确定（从参数传入、存储在数据结构中）：

```
// 动态闭包调用
OrbitHub(closure_hub) {
    cond: ch_closure_tag,    // 闭包的 type_tag
    orbit_table: [
        { cond: tag==lambda_add, orbit: 0 },  // n => n + 1
        { cond: tag==lambda_mul, orbit: 1 },  // n => n * 2
    ],
    param_mapping: [ch_x → orbit_input],
    output: ch_result,
}
```

### 8.6 select 多路复用

```
select {
    msg = ch1.recv() => handle_a(msg)
    msg = ch2.recv() => handle_b(msg)
    timeout(100ms) => handle_timeout()
}
```

```
// 循环轨道 + try_recv
OrbitHub(loop_hub, cyclic=true) → ch_result
Orbit 0 (环形):
    ch_r1 = channel_try_recv(ch1)
    ch_r2 = channel_try_recv(ch2)
    ch_timeout = check_timer(100ms)
    OrbitHub(select_hub) {
        cond: 多条件优先级匹配
        orbit_table: [
            { cond: ch_r1.ready, orbit: 1 },   // handle_a
            { cond: ch_r2.ready, orbit: 2 },   // handle_b
            { cond: ch_timeout,   orbit: 3 },   // handle_timeout
            { cond: always,       orbit: 4 },   // 继续等待（回到轨道入口）
        ],
    }
Orbit 1: output = call(handle_a, ch_r1.value)
Orbit 2: output = call(handle_b, ch_r2.value)
Orbit 3: output = call(handle_timeout)
Orbit 4: continue_channel = 1  // 继续公转
```

---

## 第 9 节：性能分析

### 9.1 开销模型

每个操作的隐含开销（时钟周期）：

| 操作 | 太阳层 | 轨道层 | 说明 |
|---|---|---|---|
| 算术 lamina | 1-3 | 1-3 | 相同，纯数据变换 |
| OrbitHub 激活 | — | 5-8 | 条件读取 + 索引 + 参数绑定 + 状态切换 |
| 轨道执行入口 | — | 1-2 | 函数指针表索引 |
| 通道桥接写入 | — | 1 | 参数绑定时拷贝 |
| 通道桥接回写 | — | 1 | 输出回写太阳层 |
| 轨道切换（嵌套） | — | 3-5 | 保存当前轨道状态 + 激活子轨道 |
| 循环核公转一圈 | — | 2 | 回到入口（无 PC 跳转，重复执行） |

### 9.2 与旧设计的对比

以 `match x { A => fib(n), B => sort(arr), _ => 0 }` 为例：

| | 旧设计（全计算+select） | 新设计（星轨） |
|---|---|---|
| 条件计算 | 3 个构造器 tag 比较 | 1 次 tag 读取 → 轨道索引 |
| 分支体执行 | 3 个全执行（fib + sort + 0） | 1 个执行（匹配的） |
| 浪费比 | 2/3 计算浪费 | 0 浪费 |
| 总开销 | fib + sort + select 链 | OrbitHub(8) + fib 或 sort(1个) |

当 fib(n) 耗时 1000 周期、sort 耗时 5000 周期时：
- 旧设计：1000 + 5000 + 3(select) = 6003 周期
- 新设计：8 + 1000 或 8 + 5000 = 1008 或 5008 周期
- **5-6 倍提升**，且分支体越复杂优势越大

### 9.3 与 JIT 的对比

| 维度 | JIT | LFE 星轨 |
|---|---|---|
| 编译开销 | 运行时 profiling + 编译 | 零（编译期完成） |
| 分支预测失败 | 15-20 周期/次 | 零（无分支，数据索引） |
| 指令缓存缺失 | 10-40 周期/次 | 低（轨道连续内存，激活才加载） |
| 动态分派 | vtable 查找 5-20 周期 | 轨道索引 1 周期 |
| 函数调用 | 栈帧 3-5 周期 | 零（全内联） |
| 循环 | 取指+解码每轮 | 轨道公转每轮 2 周期（无取指） |

### 9.4 何时星轨不如纯 DAG

| 场景 | 原因 | 优化器对策 |
|---|---|---|
| 2-arm match，每条轨道 1 个 lamina | OrbitHub 开销(8) > 节省(1) | 轨道合并为 select |
| if-else 分支体完全相同 | 轨道无差异 | 轨道合并消除 |
| if 条件编译期可计算 | 不是真动态 | 常量折叠消除 if |
| 循环固定次数（如 `for i in 0..3`） | 编译期可展开 | 循环展开，不生成轨道 |

### 9.5 内存占用

```
太阳层 laminas:      N_solar × sizeof(Lamina)
轨道 laminas:        N_orbit × sizeof(Lamina)   ← 未激活不占缓存
OrbitHub 元数据:     N_hub × sizeof(OrbitHub)
轨道表:              N_hub × N_arm × sizeof(OrbitEntry)
通道存储:            N_channels × elem_width    ← 活跃性分析后复用

总内存 ≈ (N_solar + N_orbit) × sizeof(Lamina) + N_hub × overhead
```

相比旧设计，星轨增加的开销只有 OrbitHub 元数据。轨道 laminas 是从旧设计的"全展开在 DAG 中"变为"分离存储"——总量不增加，布局更优（激活才加载）。

### 9.6 并行执行收益

| 场景 | 旧设计 | 星轨设计 |
|---|---|---|
| async 创建 3 个协程 | 3 个 extern_call | 3 条异步轨道并行 |
| 独立 match 分支 | 串行 select 链 | 独立轨道可并行（如果无数据依赖） |
| 循环内独立迭代 | DAG 无法并行 | 轨道内无依赖 lamina 可 SIMD |

### 9.7 性能目标

| 目标 | 星轨设计目标 | 说明 |
|---|---|---|
| 比 VM 快 | 80-150x | 零浪费带来额外提升 |
| 比 JIT 快 | 10-20x | 无分支预测失败+零编译开销 |
| 动态分派开销 | 1 周期（轨道索引） | 比旧设计的 select 链更快 |
| 循环开销 | 2 周期/轮（公转） | 无取指无解码 |

---

## 第 10 节：数据结构定义

### 10.1 LaminaOp 扩展

在现有枚举基础上新增轨道相关 op：

```zig
pub const LaminaOp = enum {
    // ... 现有 150+ op 保持不变 ...

    // 轨道枢纽
    orbit_hub,              // sync_hub：同步轨道激活
    orbit_hub_async,        // async_hub：异步轨道激活
    orbit_join,             // async_join：等待异步轨道完成

    // defer
    defer_register,         // 注册 defer 到 LIFO 栈
    defer_execute,          // halt 时 LIFO 执行

    // 显式数据栈（递归用）
    stack_push,             // 压栈
    stack_pop,              // 出栈
    stack_peek,             // 查看栈顶
    stack_depth,            // 栈深度
};
```

### 10.2 OrbitHub 结构

```zig
/// 轨道枢纽：连接太阳层与星轨层
pub const OrbitHub = struct {
    /// 枢纽类型
    kind: OrbitHubKind,
    /// 条件值所在通道（async_hub 时无）
    cond_channel: ?u16 = null,
    /// 轨道表（编译期确定）
    orbit_table: []const OrbitEntry,
    /// 输出回写通道（async_hub 时输出句柄）
    output_channel: u16,
    /// 参数绑定：太阳层通道 → 轨道入口通道
    param_mapping: []const ParamBind = &.{},
    /// 是否环形（循环）
    is_cyclic: bool = false,
    /// 继续条件通道（环形轨道用）
    continue_channel: ?u16 = null,
};

pub const OrbitHubKind = enum {
    match_hub,       // match 表达式
    if_hub,          // if-else
    loop_hub,        // while/for/loop
    trait_hub,       // 动态 trait 分派
    closure_hub,     // 动态闭包调用
    error_hub,       // ? 传播 / try-catch
    nullable_hub,    // ?. / ?? / !
    select_hub,      // select 多路复用
    async_hub,       // async fun / async lambda
};

/// 轨道表条目
pub const OrbitEntry = struct {
    /// 进入条件
    condition: OrbitCondition,
    /// 对应轨道索引
    orbit_index: u16,
    /// 参数绑定（覆盖 OrbitHub 的默认绑定）
    param_mapping: []const ParamBind = &.{},
};

pub const OrbitCondition = struct {
    /// 条件值通道（null = always_match）
    cond_channel: ?u16 = null,
    /// 比较方式
    cond_kind: CondKind = .always,
    /// 期望值
    expected_val: i64 = 0,
};

pub const CondKind = enum {
    always,         // 无条件匹配（wildcard / default）
    eq,             // ==
    ne,             // !=
    gt,             // >
    lt,             // <
};

/// 参数绑定：太阳层通道 → 轨道入口通道
pub const ParamBind = struct {
    src: u16,       // 太阳层通道索引
    dst: u16,       // 轨道入口通道索引
};
```

### 10.3 Orbit 结构

```zig
/// 轨道：独立的 lamina 序列
pub const Orbit = struct {
    /// 轨道内 lamina 序列（连续内存）
    laminas: []Lamina,
    /// 入口通道（从太阳层接收数据）
    input_channels: []u16,
    /// 出口通道（结果回写太阳层）
    output_channel: u16,
    /// 是否环形轨道（循环）
    is_cyclic: bool = false,
    /// 环形轨道的继续条件通道
    continue_channel: ?u16 = null,
    /// 轨道内嵌套的 OrbitHub 索引列表
    nested_hubs: []const u16 = &.{},
    /// 运行时状态
    state: OrbitState = .inactive,
    /// 轨道私有通道数量
    private_channel_count: u16 = 0,
};

pub const OrbitState = enum {
    inactive,       // 未激活——零开销
    running,        // 正在执行
    done,           // 执行完毕
};
```

### 10.4 LaminarGraph 扩展

```zig
/// 层流图：太阳层 + 星轨层
pub const LaminarGraph = struct {
    // 太阳层
    laminas: []Lamina,
    channels: []PhysicalChannel,
    string_table: []const []const u8,

    // 星轨层
    orbits: []Orbit,
    orbit_hubs: []OrbitHub,         // 所有 OrbitHub 元数据

    // defer 栈
    defer_entries: []const DeferEntry,

    // 通道元数据
    channel_scopes: []const ChannelScope,
    total_channels: u32,
    solar_channel_count: u32,
    orbit_channel_count: u32,

    // 入口
    entry_channel: u16,
    return_channel: u16,
};

pub const ChannelScope = enum {
    solar,
    orbit,
    bridge_in,
    bridge_out,
};

pub const DeferEntry = struct {
    /// defer 体的轨道索引（defer 体编译为轨道）
    orbit_index: u16,
    /// 注册顺序（LIFO 执行）
    order: u32,
};
```

### 10.5 Lamina 扩展

```zig
pub const Lamina = struct {
    op: LaminaOp,
    /// 输入通道索引（数量因 op 而异，用固定数组 + count）
    inputs: [4]u16 = .{ 0, 0, 0, 0 },
    input_count: u8 = 0,
    /// 输出通道索引
    output: u16 = 0,
    /// 谓词掩码通道（保留，太阳层内条件执行用）
    predicate: ?u16 = null,
    /// 编译期常量 1
    const_val: ?i64 = null,
    /// 编译期常量 2
    const_val2: ?i64 = null,
    /// 通道元素宽度（字节）
    elem_width: u8 = 0,
    /// 元素数量（SIMD 批处理用）
    element_count: u32 = 1,
    /// OrbitHub 索引（op == .orbit_hub / .orbit_hub_async 时有效）
    hub_index: ?u16 = null,
    /// OrbitHub 输出句柄通道（op == .orbit_join 时有效）
    handle_channel: ?u16 = null,
};
```

### 10.6 Engine 扩展

```zig
pub const Engine = struct {
    graph: *const LaminarGraph,
    allocator: std.mem.Allocator,
    // 通道存储（所有层共享）
    channels: []u8,                  // 连续内存
    channel_offsets: []u32,          // 每个通道的偏移量
    // 轨道状态
    orbits: []Orbit,                 // 运行时轨道实例
    orbit_instances: ArrayList(OrbitInstance),  // 异步轨道实例
    // defer 栈
    defer_stack: ArrayList(DeferEntry),
    // 显式数据栈（递归用）
    data_stack: ArrayList(DataFrame),
    // 协程调度器
    scheduler: ?*Scheduler,
    // 执行状态
    halt_reason: HaltReason,
    result: u64,
    // 函数指针表
    handlers: *const [handlers_len]Handler,
};

pub const OrbitInstance = struct {
    orbit_index: u16,
    input_channels: []u16,
    output_channel: u16,
    state: OrbitState,
    task_handle: ?u64 = null,   // 协程任务句柄
};

pub const DataFrame = struct {
    /// 调用帧的通道快照
    channels: []u8,
    /// 返回地址（回写到的太阳层通道）
    return_channel: u16,
};
```

---

## 第 11 节：实施路径

### 11.1 当前状态评估

| 组件 | 状态 | 说明 |
|---|---|---|
| LaminaOp 枚举 | 已有 150+ op | 需新增轨道相关 op |
| Lamina 结构 | 已有 | 需扩展 hub_index 等字段 |
| LaminarGraph | 已有 | 需扩展 orbits/orbit_hubs 字段 |
| Engine.run() | 线性遍历 | 需改为双层级调度 |
| 函数指针表 | 部分实现 | 需补全所有 op |
| 编译器 | 基础结构 | 需增加轨道编译 |
| 优化器 | 4 个 pass | 需增加 3 个星轨 pass |
| 协程调度器 | 已有 scheduler.zig | 可复用 |
| Value 层 | 已有 | 无需改动 |

### 11.2 实施阶段

```
Phase A：轨道基础设施（地基）
  ├─ A1. 数据结构扩展
  │    ├─ LaminaOp 新增轨道 op
  │    ├─ OrbitHub / Orbit / OrbitEntry 结构
  │    └─ LaminarGraph 扩展 orbits/orbit_hubs 字段
  │
  ├─ A2. 引擎双层级调度
  │    ├─ runSolar() 太阳层执行
  │    ├─ execOrbitHub() 枢纽执行
  │    ├─ runOrbit() 轨道执行（含环形）
  │    └─ 函数指针表补全
  │
  └─ A3. 通道系统扩展
       ├─ ChannelScope 标记
       ├─ 桥接通道实例化
       └─ 跨层活跃性分析

Phase B：编译器（核心）
  ├─ B1. 静态/动态判定
  │    ├─ isStatic() 递归判定
  │    └─ 函数纯度分析集成
  │
  ├─ B2. 动态表达式编译
  │    ├─ compileIf → OrbitHub(if_hub)
  │    ├─ compileMatch → OrbitHub(match_hub)
  │    └─ 细粒度切分（局部动态）
  │
  └─ B3. 函数内联
       ├─ 静态函数内联到所在层
       └─ 动态函数发射 OrbitHub + 轨道模板

Phase C：循环与递归（突破）
  ├─ C1. 环形轨道
  │    ├─ while/for/loop → OrbitHub(loop_hub) + 环形轨道
  │    └─ 公转机制（continue_channel）
  │
  └─ C2. 递归编译
       ├─ 尾递归 → 环形轨道
       ├─ 非尾递归 → 环形轨道 + 显式数据栈
       └─ stack_push/pop/peek op 实现

Phase D：优化器（提效）
  ├─ D1. staticHoisting
  │    └─ 轨道内静态代码提升到太阳层
  │
  ├─ D2. orbitMerging
  │    └─ 极简轨道合并为 select（严格条件）
  │
  ├─ D3. orbitDeadCode
  │    └─ 死轨道消除
  │
  └─ D4. 跨层通道活跃性
       └─ 太阳层/轨道通道槽位复用

Phase E：异步与高级特性（扩展）
  ├─ E1. async 轨道
  │    ├─ async_hub + 异步轨道
  │    ├─ async_join 同步点
  │    └─ 协程调度器集成
  │
  ├─ E2. 动态分派
  │    ├─ trait_hub（动态 trait 分派）
  │    └─ closure_hub（动态闭包调用）
  │
  ├─ E3. 错误处理
  │    ├─ error_hub（? 传播 / try-catch）
  │    └─ nullable_hub（?. / ?? / !）
  │
  ├─ E4. defer
  │    ├─ defer_register / defer_execute
  │    └─ halt 时 LIFO 执行
  │
  └─ E5. select 多路复用
       └─ 循环轨道 + try_recv + select_hub
```

### 11.3 阶段依赖

```
A（基础设施） ← 必须先完成
  ↓
B（编译器） ← 依赖 A 的数据结构和引擎
  ↓
C（循环递归） ← 依赖 B 的编译框架
  ↓
D（优化器） ← 依赖 B/C 产生的轨道
  ↓
E（异步高级） ← 依赖 A-D

B 和 C 可部分并行（C 依赖 B2）
D 和 E 可部分并行（E 不依赖 D）
```

### 11.4 验证策略

每个阶段完成后验证：

| 阶段 | 验证方式 |
|---|---|
| A | 单元测试：OrbitHub 激活、轨道执行、环形轨道 |
| B | 端到端：if/match 表达式正确执行 |
| C | 端到端：while/for/递归正确执行 |
| D | 性能测试：优化前后 lamina 数/通道数对比 |
| E | 端到端：async 协程、错误传播、defer 正确执行 |

### 11.5 风险点（仅记录，暂不实现对应代码）

以下风险点仅作记录，对应的防御性代码暂不实现，待实际遇到问题时再处理：

| 风险 | 影响 | 对策（暂不实现） |
|---|---|---|
| 轨道嵌套过深 | 栈溢出 | 编译期限制嵌套深度 ≤ 16 |
| 全内联代码爆炸 | 内存膨胀 | 内联深度上限 + 轨道模板复用 |
| 环形轨道死循环 | 引擎挂死 | 编译期检测无限循环 + 运行时超时 |
| 通道活跃性分析复杂 | 编译慢 | 只分析太阳层 + 当前轨道，不做全局分析 |
