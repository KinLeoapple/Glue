# Glue IR 设计文档：共享内存图执行模型

> 本文档定义 Glue 语言的完整编译执行架构：前端（parse + sema）→ Glue IR → 中端（优化器）→ 后端（执行引擎）。
> Glue IR 是为 Glue 量身设计的共享内存图，不是 LLVM IR、不是文本 IR、不是 SSA。
> 本设计取代 LFE 的 lamina/graph + 星轨双轨制，统一为单一的 Glue IR 共享内存图。

---

## 1. 设计动机

### 1.1 LFE 星轨模型的问题

LFE 星轨模型存在根本性设计矛盾：

1. **用数据流模拟控制流，本质倒退**：OrbitHub 每次激活需 5-8 周期（条件读取 + 查表 + 参数绑定 memcpy + 执行 + 回写 memcpy），而 CPU 原生条件分支预测成功时仅 1-2 周期。
2. **对简单动态过度**：if/`?` 这种 1 周期的事被处理成 5-8 周期的轨道。
3. **参数绑定开销无法消除**：每次轨道激活都有 memcpy。
4. **优化器只能补救**：`orbitMerging`/`staticHoisting` 条件苛刻，大部分场景用不上。
5. **循环仍是解释器级**：环形轨道逐 lamina 执行，每个 lamina 走函数指针分派，无法超越 JIT 机器码循环。

### 1.2 核心洞察

**dispatch 的问题不是"存在"，而是"太频繁"。**

- LFE 星轨：1000 次循环 ≈ 5000 次 dispatch
- 向量 DAG：1000 次循环 ≈ 3 次 dispatch（降 1666 倍）

**真正的出路：用向量 op 把循环/递归的 dispatch 频率从 O(N) 降到 O(1)。**

不是消除 dispatch，而是把 dispatch 的粒度从"单元素"提升到"整批数据"。

### 1.3 设计目标

- 纯解释器框架内达到性能上限（不追求超越 JIT）
- 统一图结构，零切换开销
- 所有节点共享内存，CPU 缓存友好
- 为不同性质的特性提供最适合的节点类型，不强行统一机制
- async 保留星轨作为并行扩展层

---

## 2. 整体架构

```
Glue 源码
   ↓
┌─────────────────────────────────────────┐
│ 前端（parse + sema）                     │
│  parse: 纯语法，零语义                   │
│  sema: 语义分析 + 图构建驱动             │
│  产物: Glue IR（共享内存图）             │
└─────────────────────────────────────────┘
   ↓
┌─────────────────────────────────────────┐
│ 中端（优化器）                           │
│  全局数据流分析                          │
│  死节点消除 / 常量折叠                    │
│  单态化内联（route → scalar）            │
│  通道活跃性分析                          │
│  产物: 优化的 Glue IR                    │
└─────────────────────────────────────────┘
   ↓
┌─────────────────────────────────────────┐
│ 后端（执行引擎）                         │
│  单循环线性遍历节点                      │
│  switch 跳转表分派                       │
│  通道读写                                │
│  星轨调度（async/spawn）                 │
└─────────────────────────────────────────┘
   ↓
运行结果
```

### 2.1 三阶段职责

| 阶段 | 输入 | 输出 | 职责 |
|---|---|---|---|
| 前端 | Glue 源码 | Glue IR | 语法解析 + 语义分析 + 图生成 |
| 中端 | Glue IR | 优化的 Glue IR | 全局优化 |
| 后端 | Glue IR | 运行结果 | 线性遍历执行 |

### 2.2 与 LFE 的关系

- LFE 的 lamina 结构 → 演化为 Glue IR 的 Node
- LFE 的通道 → 保留为 Glue IR 的 ChannelSpace
- LFE 的太阳层 DAG → 演化为 Glue IR 的主节点流
- LFE 的星轨 → 仅保留 async/spawn 作为并行扩展层
- LFE 的 OrbitHub → 删除，由 gate/route/race 节点替代

---

## 3. Glue IR 定义

### 3.1 核心结构

Glue IR 是一段连续内存，包含节点流、通道空间、元数据表。

```zig
const GlueIR = struct {
    // 节点流（所有节点连续存储，线性遍历）
    nodes: []Node,

    // 通道空间（全局共享，所有节点读写同一空间）
    channels: ChannelSpace,

    // 元数据表（按 op 类型分表，紧凑存储）
    scalar_metas: []ScalarMeta,
    vector_metas: []VectorMeta,
    gate_metas: []GateMeta,
    route_metas: []RouteMeta,
    race_metas: []RaceMeta,
    cleanup_metas: []CleanupMeta,
    call_metas: []CallMeta,

    // 函数表（单态化后的具体函数，每个函数是一个 GlueIR 子图）
    functions: []Function,

    // 星轨表（async/spawn 的并行执行单元）
    orbits: []Orbit,

    // 字符串常量池
    string_pool: []const u8,

    // 调试信息
    debug_info: ?DebugInfo,
};
```

### 3.2 统一节点结构

所有节点固定 16 字节，连续存储，CPU 缓存友好。

```zig
const Node = struct {
    op: NodeOp,           // 操作类型（枚举）
    inputs: [4]u16,       // 输入通道索引（全局）
    input_count: u8,      // 实际输入数（0-4）
    output: u16,          // 输出通道索引（全局）
    meta_index: u16,      // 元数据表索引（指向对应 meta 表）
};
// 16 字节/节点
```

### 3.3 节点类型枚举

```zig
const NodeOp = enum(u8) {
    // === 标量计算 ===
    const_i, const_f, const_bool, const_char, const_str, const_null,
    int_add, int_sub, int_mul, int_div, int_mod,
    int_and, int_or, int_xor, int_shl, int_shr, int_not,
    float_add, float_sub, float_mul, float_div,
    cmp_eq, cmp_ne, cmp_lt, cmp_le, cmp_gt, cmp_ge,
    bool_and, bool_or, bool_not,
    cast, cast_safe,

    // === 数据结构 ===
    array_make, array_get, array_set, array_len, array_push, array_concat,
    record_make, record_get, record_set,
    string_concat, string_len, string_index,
    newtype_wrap, newtype_unwrap,

    // === 向量计算（处理循环/递归） ===
    vec_source,           // 创建向量（range/array/repeat/iterate）
    vec_map,              // 逐元素变换（1→1）
    vec_map2,             // 双流合并（2→1）
    vec_fold,             // 归约（N→1）
    vec_scan,             // 前缀计算（递归线性化）
    vec_filter,           // 过滤（mask 压缩）
    vec_select,           // 条件选择（替代 if/match）
    vec_take,             // 取前 N 个
    vec_take_while,       // 取到条件不满足
    vec_zip,              // 并行合并
    vec_sink,             // 收集结果（to_array/last/count/drain）

    // === 门控（? 短路 / 错误传播） ===
    gate_check,           // 检查值是否 Ok
    gate_get_ok,          // 提取 Ok 值
    gate_get_err,         // 提取 Error 值
    gate_propagate,       // OR 传播错误掩码
    gate_select,          // 按 mask 选择值
    gate_make_ok,         // 构造 Ok
    gate_make_err,        // 构造 Error

    // === 路由（Trait 动态分派） ===
    route_get_tag,        // 读取值的 tag
    route_dispatch,       // 按 tag 分派到实现
    route_merge,          // 合并分派结果

    // === 竞争（select 多路复用） ===
    race_source,          // 竞争源（通道 try_recv / timeout）
    race_select,          // 选择第一个就绪的
    race_yield,           // 无就绪时让出执行权

    // === 清理（defer） ===
    cleanup_register,     // 注册 defer
    cleanup_run,          // halt 时执行清理链

    // === Nullable ===
    nullable_make, nullable_is_null, nullable_unwrap, nullable_unwrap_or,

    // === 内存管理 ===
    alloc, free, load, store,

    // === 控制流（最小化） ===
    call,                 // 函数调用
    halt_return,          // 正常返回
    halt_throw,           // 抛出错误
    halt_panic,           // panic（不可恢复）

    // === 星轨（async/spawn） ===
    orbit_async_create,   // 创建异步轨道
    orbit_async_join,     // 等待异步轨道完成
    orbit_chan_send,      // 向轨道通道发送
    orbit_chan_recv,      // 从轨道通道接收
    orbit_chan_try_recv,  // 非阻塞接收
};
```

### 3.4 通道空间

所有节点共享同一通道空间，全局通道索引，无跨图映射。

```zig
const ChannelSpace = struct {
    data: []u8,           // 连续存储所有通道数据
    offsets: []u32,       // 每个通道的起始偏移
    widths: []u8,         // 每个通道的数据宽度（字节）
    flags: []ChannelFlags, // 通道标志（可读/可写/已就绪）

    // 通道活跃性分析结果（优化器填充）
    live_ranges: []LiveRange,
};

const ChannelFlags = packed struct {
    ready: bool,          // 数据已就绪
    writable: bool,       // 可写
    readable: bool,       // 可读
    _pad: u5,
};
```

### 3.5 元数据表

按 op 类型分表，避免 union 膨胀，且同类 meta 连续访问缓存友好。

```zig
const ScalarMeta = struct {
    kind: ScalarKind,     // int_kind / float_kind / bool / char
    int_kind: IntKind,    // i8/i16/i32/i64/i128/u8/u16/u32/u64/u128
    float_kind: FloatKind, // f16/f32/f64/f128
};

const VectorMeta = struct {
    vec_op: VecOp,        // map/fold/scan/filter/select/...
    inner_op: NodeOp,     // 被包装的标量 op
    inner_meta: u16,      // 标量 op 的 meta 索引
    length: ?u32,         // 已知长度（编译期确定则填充）
};

const GateMeta = struct {
    error_type: u32,      // 错误类型索引
    propagate_from: u16,  // 上游错误掩码通道
};

const RouteMeta = struct {
    trait_id: u32,        // Trait 标识
    method_id: u32,       // 方法标识
    targets: []const u16, // 各实现的函数索引
    target_count: u8,
};

const RaceMeta = struct {
    source_count: u8,
    timeout_ms: ?u64,
};

const CleanupMeta = struct {
    trigger: HaltKind,    // return / throw / panic / any
    body_nodes: []const Node, // defer 体的节点序列
};

const CallMeta = struct {
    func_index: u16,      // 被调用函数索引
    arg_count: u8,
};
```

---

## 4. 前端设计（parse + sema）

### 4.1 parse：纯语法，零语义

**职责**：源码 → AST

- 词法分析：token 流
- 语法分析：AST 构建
- 只管结构正确，不管类型
- 不做任何语义判断

**输入**：Glue 源码文件

**输出**：AST（抽象语法树）

parse 阶段完全保留现有实现，无需修改。

### 4.2 sema：语义分析 + 图构建驱动

**职责**：AST → Glue IR

sema 从"检查器"升级为"图构建驱动器"。输出不再是"检查通过/失败"，而是**图构建所需的全部元信息**。

#### 4.2.1 sema 输出

```zig
const SemaResult = struct {
    // 类型信息（决定通道宽度）
    expr_types: HashMap(ExprId, Type),

    // Trait 分派信息（决定 route 节点）
    trait_impls: HashMap(TraitMethodId, []const ImplId),

    // 单态化映射（决定具体 op）
    monomorphization_map: HashMap(GenericId, ConcreteType),

    // 模式匹配信息（决定 vec_select）
    match_arms: HashMap(MatchId, []const MatchArmInfo),

    // 错误传播路径（决定 gate 节点）
    propagate_chains: HashMap(PropagateId, PropagationChain),

    // 通道分配（全局通道索引）
    channel_allocator: ChannelAllocator,

    // 编译期错误
    errors: []const CompileError,
};
```

#### 4.2.2 sema 保留并强化的检查

| 检查 | 强化方向 | 驱动的图构建 |
|---|---|---|
| 类型推导 | 输出精确类型 → 通道宽度 | 决定 `ChannelSpace.widths` |
| Trait 约束 | 输出实现列表 → route 分派表 | 决定 `RouteMeta.targets` |
| 泛型单态化 | 输出具体类型 → 具体 op | 决定 `Node.op` |
| 模式匹配分析 | 输出分支信息 → vec_select | 决定 `VectorMeta` |
| 错误传播分析 | 输出传播链 → gate 节点 | 决定 `GateMeta` |

#### 4.2.3 sema 可删除的检查

以下检查在单态化后无意义，可删除：

| 检查 | 删除原因 |
|---|---|
| 方法签名匹配 | 单态化直接内联，无"方法"概念 |
| 关联类型定义 | 单态化时替换，不进入图 |
| HKT / Kind 系统 | 编译期消除，不进入图 |
| 子类型关系 | 单态化后只有具体类型，无子类型 |

#### 4.2.4 图构建流程

sema 完成语义分析后，直接驱动图构建：

```
1. 遍历 AST，按表达式粒度处理
2. 类型推导 → 确定通道宽度
3. 泛型单态化 → 确定具体 op
4. 按表达式类型生成节点：
   - 字面量 → const_* 节点
   - 算术 → int_*/float_* 节点
   - if/match → vec_select 节点
   - for/while → vec_source + vec_map/fold 节点
   - 递归 → vec_scan 节点
   - ? 传播 → gate_check + gate_propagate 节点链
   - Trait 方法调用 → route_get_tag + route_dispatch 节点
   - defer → cleanup_register 节点
   - select → race_source + race_select 节点
   - async → orbit_async_create 节点
5. 分配全局通道索引
6. 填充元数据表
7. 输出 Glue IR
```

#### 4.2.5 前端产物

前端最终产物是完整的 Glue IR：

```zig
fn compile(source: []const u8) !GlueIR {
    const ast = try parse(source);
    const sema_result = try analyzeSemantics(ast);
    if (sema_result.errors.len > 0) {
        return error.SemanticError;
    }
    const ir = try buildIR(ast, sema_result);
    return ir;
}
```

---

## 5. 中端设计（优化器）

### 5.1 职责

**输入**：Glue IR
**输出**：优化的 Glue IR

优化器在共享内存图上做全局分析，这是分离图做不到的优势。

### 5.2 优化 pass 列表

| Pass | 作用 | 收益 |
|---|---|---|
| constantFold | 常量折叠 | 编译期计算 |
| deadNodeElim | 死节点消除 | 减少节点数 |
| channelLiveness | 通道活跃性分析 | 槽位复用，减少内存 |
| monomorphInline | 单态化内联 | route → scalar（消除分派） |
| gateHoisting | 门控提升 | 减少全计算浪费 |
| vecFusion | 向量融合 | vec_map ∘ vec_map → vec_map |
| routeSpecialize | 路由特化 | 单一实现时消除 route |
| cleanupReorder | 清理链重排 | 减少清理开销 |

### 5.3 关键优化

#### 5.3.1 单态化内联（monomorphInline）

```
优化前：
  [route_get_tag(s)] → [route_dispatch(tag, [circle_area, rect_area])]

优化后（若编译期可确定 s 是 Circle）：
  [circle_area(s)]   // route 消除
```

**共享内存让优化器能跨节点看到全局数据流**，如果 route 的目标实现编译期可确定，直接消除 route。

#### 5.3.2 门控提升（gateHoisting）

```
优化前：
  [call(f)] [gate_check] [call(g)] [gate_check] [call(h)]

优化后（若 f 错误率高）：
  [call(f)] [gate_check] [halt_if_err]
  [call(h)] [call(g) error_path]
```

把"必然 skip"的节点移到 halt 后面，减少正常路径的遍历。这是共享内存带来的全局重排能力。

#### 5.3.3 向量融合（vecFusion）

```
优化前：
  ch_a = vec_map(add1, src)
  ch_b = vec_map(add2, ch_a)

优化后：
  ch_b = vec_map(compose(add1, add2), src)   // 融合为一次遍历
```

### 5.4 优化器实现

```zig
fn optimize(ir: *GlueIR) void {
    var changed = true;
    while (changed) {
        changed = false;
        changed = changed or constantFold(ir);
        changed = changed or deadNodeElim(ir);
        changed = changed or channelLiveness(ir);
        changed = changed or monomorphInline(ir);
        changed = changed or gateHoisting(ir);
        changed = changed or vecFusion(ir);
        changed = changed or routeSpecialize(ir);
    }
}
```

---

## 6. 后端设计（执行引擎）

### 6.1 职责

**输入**：优化的 Glue IR
**输出**：运行结果

### 6.2 核心执行循环

```zig
fn execute(ir: *GlueIR, engine: *Engine) EngineError!void {
    for (ir.nodes) |node| {
        switch (node.op) {
            // 标量
            .const_i => execConstI(engine, node),
            .int_add => execIntAdd(engine, node),
            // ... 其他标量

            // 向量
            .vec_source => execVecSource(engine, node),
            .vec_map => execVecMap(engine, node),
            .vec_fold => execVecFold(engine, node),
            // ... 其他向量

            // 门控
            .gate_check => execGateCheck(engine, node),
            .gate_propagate => execGatePropagate(engine, node),
            .gate_select => execGateSelect(engine, node),
            // ... 其他门控

            // 路由
            .route_get_tag => execRouteGetTag(engine, node),
            .route_dispatch => execRouteDispatch(engine, node),

            // 竞争
            .race_select => execRaceSelect(engine, node),

            // 清理
            .cleanup_register => execCleanupRegister(engine, node),

            // 控制
            .call => try execCall(engine, node),
            .halt_return => {
                try executeCleanups(engine, .return);
                return;
            },
            .halt_throw => {
                try executeCleanups(engine, .throw);
                return error.Thrown;
            },
            .halt_panic => {
                try executeCleanups(engine, .panic);
                return error.Panic;
            },

            // 星轨
            .orbit_async_create => try execOrbitAsyncCreate(engine, node),
            .orbit_async_join => try execOrbitAsyncJoin(engine, node),

            else => return error.UnsupportedOp,
        }
    }
}
```

**关键设计**：
- `switch` 跳转表分派（LLVM 自动生成，1 周期）
- 节点按 `*const Node` 指针传递（不复制 16 字节）
- 通道访问缓存到局部变量
- 零图切换开销

### 6.3 执行引擎状态

引擎使用 Glue 自实现的三层分配器体系（`src/mem/`），不依赖任何外部分配器：

```zig
const mem = @import("mem");
const ChannelRegion = mem.ChannelRegion;   // 通道数据，bump+reset，64B 对齐
const ShadowArena = mem.ShadowArena;       // 临时作用域，bump+reset，16B 对齐
const ThreadContext = mem.ThreadContext;   // 每线程统一入口，零锁热路径

const Engine = struct {
    ir: *GlueIR,
    channels: *ChannelSpace,

    // defer 栈（独立于主节点流，从 ShadowArena 分配）
    defer_stack: DeferStack,

    // 错误状态
    error_state: ?ErrorValue,

    // 星轨调度器（async/spawn）
    orbit_scheduler: ?*OrbitScheduler,

    // 自实现分配器（三层，src/mem/）
    tctx: *ThreadContext,        // 每线程统一入口
    // tctx 内部包含：
    //   channels: ChannelRegion  // 通道数据（短生命周期，基本块级 reset）
    //   arena: ShadowArena       // 临时缓冲（极短生命周期，函数级 reset）
    //   pools: []PoolSlot        // 对象池（中长生命周期，精确尺寸页池）
    //   global: *GlobalPool      // 冷路径 + 大对象（buddy 分配器）
};

/// defer 栈：从 ShadowArena 分配，函数返回时随 arena reset 释放
const DeferStack = struct {
    entries: []DeferEntry = &.{},
    len: usize = 0,
    cap: usize = 0,
    arena: *ShadowArena,

    fn push(self: *DeferStack, entry: DeferEntry) !void {
        if (self.len == self.cap) {
            const new_cap = if (self.cap == 0) 4 else self.cap * 2;
            const new_buf = try self.arena.alloc(@sizeOf(DeferEntry) * new_cap);
            if (self.len > 0) {
                @memcpy(new_buf[0..self.len * @sizeOf(DeferEntry)], self.entries);
            }
            self.entries = @ptrCast(@alignCast(new_buf.ptr));
            self.cap = new_cap;
        }
        self.entries[self.len] = entry;
        self.len += 1;
    }

    fn pop(self: *DeferStack) ?DeferEntry {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.entries[self.len];
    }
};
```

### 6.4 分配器职责映射

Glue IR 各部分的内存分配明确归属到自实现分配器：

| IR 组件 | 分配器 | 理由 |
|---|---|---|
| 节点流 `[]Node` | ThreadContext 对象池 | 编译期生成，中长生命周期，固定 16B 节点 |
| 通道数据 `ChannelSpace.data` | ChannelRegion | 运行时短生命周期，64B 对齐 SIMD 友好，基本块级 reset |
| 元数据表 | ThreadContext 对象池 | 编译期生成，中长生命周期 |
| 函数表 `[]Function` | ThreadContext 对象池 | 编译期生成，程序级生命周期 |
| 星轨表 `[]Orbit` | ThreadContext 对象池 | 编译期生成，中长生命周期 |
| 字符串常量池 | ThreadContext 对象池 | 编译期生成，程序级生命周期 |
| defer 栈 | ShadowArena | 函数级生命周期，随 arena reset 释放 |
| 临时计算缓冲区 | ShadowArena | 极短生命周期，函数级 reset |
| 运行时大数组/大对象 | GlobalPool.buddy | 超过页池尺寸（>256B）的大对象 |
| async 轨道实例 | ThreadContext 对象池 | 中长生命周期，任务结束释放 |

### 6.5 分配器生命周期管理

```
程序启动：
  GlobalPool.init(backing)           // 全局池
  ThreadContext.init(global, backing) // 每线程上下文

函数调用：
  tctx.channels.reset()              // 通道区重置（基本块级）
  tctx.arena.reset()                 // 临时区重置（函数级）
  // 对象池分配的对象在函数返回时由引用计数/GC 管理

函数返回：
  defer 栈 LIFO 执行                 // 从 arena 分配，随 reset 释放
  tctx.arena.reset()                 // O(1) 释放所有临时数据

基本块结束：
  tctx.channels.reset()              // O(1) 释放通道数据

程序退出：
  ThreadContext.deinit()             // 归还页给 GlobalPool
  GlobalPool.deinit()                // 释放所有内存
```

### 6.6 三层分配器的热路径特性

| 分配器 | 热路径开销 | 同步 | 碎片 | 对齐 |
|---|---|---|---|---|
| ChannelRegion | 1 次加法 + 1 次比较 | 零（线程本地） | 零（bump+reset） | 64B（AVX-512） |
| ShadowArena | 1 次加法 + 1 次比较 | 零（线程本地） | 零（bump+reset） | 16B（SSE/NEON） |
| ThreadContext 对象池 | 位图扫描 | 零（线程本地） | 零（精确尺寸页池） | 对象自然对齐 |
| GlobalPool.buddy | buddy 分裂合并 | 自旋锁（冷路径） | 低（buddy 合并） | 页对齐 |

### 6.7 标量运算复用 value.ops

执行引擎的标量运算（算术、位运算、比较）**直接复用 `src/value/ops.zig` 的 comptime 特化函数**，不重复实现任何运算逻辑。

**设计动机**：
- `value.ops` 已为所有 16 种 ScalarTag 提供完整的 comptime 特化运算函数（add/sub/mul/div/mod/neg/bitAnd/bitOr/bitXor/bitNot/eq/ne/lt/le/gt/ge）
- 运算函数以 `comptime tag: ScalarTag` 参数特化，`@bitCast` 在编译期消除，运行时零开销
- 引擎复用这些函数可避免维护两套运算逻辑，确保语义一致性

**dispatch 分派模式**：

`ops` 函数的 `tag` 参数是 `comptime`，但引擎运行时从通道元信息推导的 `tag` 是运行时值。通过 `inline switch` 展开所有类型到 comptime 分支解决：

```zig
// 运行时 tag → comptime 分派
fn dispatchIntBinOp(tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
    return switch (tag) {
        .i8  => dispatchIntBinOpT(.i8,  kind, a, b),
        .i16 => dispatchIntBinOpT(.i16, kind, a, b),
        // ... 所有 10 种整数类型
        else => null,
    };
}

// comptime 特化分支：调用 ops 函数
fn dispatchIntBinOpT(comptime tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
    const W = comptime scalar.byteWidth(tag);
    const ByteArrayT = scalar.ByteArray(tag);
    const a_bytes: ByteArrayT = a[0..W].*;
    const b_bytes: ByteArrayT = b[0..W].*;
    const result: ?ByteArrayT = switch (kind) {
        .add     => ops.add(tag, a_bytes, b_bytes),
        .div     => ops.div(tag, a_bytes, b_bytes),
        .bit_and => ops.bitAnd(tag, a_bytes, b_bytes),
        // ...
    };
    // ...
}
```

**已实现的 dispatch 函数组**：

| dispatch 函数 | 覆盖类型 | 对应 ops 函数 |
|---|---|---|
| `dispatchIntBinOp` | i8-i128, u8-u128（10 种） | add/sub/mul/div/mod/bitAnd/bitOr/bitXor |
| `dispatchFloatBinOp` | f16, f32, f64, f128（4 种） | add/sub/mul/div |
| `dispatchIntUnOp` | i8-i128, u8-u128（10 种） | neg/bitNot/abs |
| `dispatchFloatUnOp` | f16, f32, f64, f128（4 种） | neg/abs |
| `dispatchCmp` | 所有 16 种 ScalarTag | eq/ne/lt/le/gt/ge |

**特殊处理**：
- `boolean` 类型不经过 `ops`（`@bitCast` 位宽不匹配：bool 1 bit vs [1]u8 8 bit），在 `dispatchCmp` 中内联比较
- 通道数据以 16 字节填充缓冲区（`[16]u8`）传递给 ops 函数，ops 内部按 `comptime W` 截取前 N 字节
- `div`/`mod` 返回 `?ByteArray`，除零时返回 `null`，引擎转为 `error.DivisionByZero`

---

## 7. 各特性的处理映射

### 7.1 静态特性（编译期消除）

| 特性 | 处理 |
|---|---|
| 泛型 `<T>` | 单态化 |
| Trait 约束 | 编译期检查 |
| 关联类型 | 单态化时替换 |
| 类型别名 | 编译期消除 |
| Trait 默认方法 | 编译期内联 |
| 静态 Trait 分派 | 单态化内联（route → scalar） |
| 可见性 | 编译期 |
| 模块系统 | 编译期解析 |

### 7.2 数据流特性（直接融入 DAG）

| 特性 | 节点 | dispatch |
|---|---|---|
| 算术/位运算/比较 | 标量 op | 1 次/op |
| for/while | vec_source + vec_map/fold | O(1)/循环 |
| 线性递归 | vec_scan | O(1)/递归 |
| if/match | vec_select | 0（数据选择） |
| break/continue | vec_take_while / vec_drop | 0 |
| 数组迭代 | vec_source(array) + vec_map | O(1) |
| Range | vec_source(range) | O(1) |
| 字段访问 | record_get/set | 1 次 |
| 类型转换 | cast / cast_safe | 1 次 |

### 7.3 控制流特性（专用节点）

| 特性 | 节点 | 机制 |
|---|---|---|
| `?` 传播 | gate_check + gate_propagate + gate_select | 门控数据流 |
| `throw` | halt_throw | halt 节点 |
| Nullable | nullable_make/is_null/unwrap/unwrap_or | 数据选择 |
| `??` Elvis | vec_select | 数据选择 |
| `?.` 安全访问 | nullable + vec_select | 数据选择 |

### 7.4 动态分派特性

| 特性 | 节点 | 机制 |
|---|---|---|
| Trait 动态分派 | route_get_tag + route_dispatch | tag 索引 + 间接调用 |
| 闭包动态分派 | route_dispatch | 同上 |

### 7.5 时序特性

| 特性 | 节点 | 机制 |
|---|---|---|
| defer | cleanup_register + cleanup_run | halt 时 LIFO 执行 |
| 副作用顺序 | DAG 拓扑序 | 自然保证 |

### 7.6 并发特性（星轨）

| 特性 | 节点 | 机制 |
|---|---|---|
| async | orbit_async_create + orbit_async_join | 星轨并行执行 |
| spawn | orbit_async_create | 星轨并行执行 |
| select 多路复用 | race_source + race_select + race_yield | 竞争图 |
| 协程取消 | orbit 取消标志 | 外部中断 |
| Atomic | atomic_load/store/cas | 硬件指令 |

---

## 8. 核心难题处理详解

### 8.1 `?` 短路：门控数据流

**问题**：`?` 失败时后续所有计算都不应执行。

**方案**：error_mask 沿图传播，门控节点检查 mask。

```
val a = f()?      // ?点1
val b = g(a)?     // ?点2
val c = h(b)      // 无 ?
result = c
```

编译为：

```
N0: ch_a = call(f)
N1: ch_ok_a = gate_check(ch_a)              // 检查 is_ok
N2: ch_val_a = gate_get_ok(ch_a)            // 提取值
N3: ch_b = call(g, ch_val_a)                // 仍执行（全计算）
N4: ch_ok_b = gate_propagate(ch_ok_a, gate_check(ch_b))  // OR 传播
N5: ch_val_b = gate_get_ok(ch_b)
N6: ch_c = call(h, ch_val_b)                // 仍执行
N7: ch_ok_c = gate_propagate(ch_ok_b, ...)
N8: result = gate_select(ch_ok_c, ch_c, ERROR)
```

**执行规则**：
- `gate_check`：1 周期检查 is_ok
- `gate_propagate`：1 周期 OR 运算
- `gate_select`：1 周期数据选择

**代价**：仍全计算（g/h 即使失败也执行），但可通过 `gateHoisting` 优化重排。

### 8.2 Trait 动态分派：路由节点

**问题**：运行时才知道调哪个实现。

**方案**：编译期构建分派表，运行时 tag 索引。

```
for s in shapes { sum += s.area() }
// shapes 可能含 Circle/Rect/Triangle
```

编译为：

```
N0: ch_src = vec_source(shapes)
N1: ch_tag = vec_map(route_get_tag, ch_src)
N2: ch_area = vec_map2(route_dispatch, ch_src, ch_tag)
    // route_dispatch 内部：tag 索引 + 间接调用
    // targets = [circle_area_fn, rect_area_fn, tri_area_fn]
N3: ch_sum = vec_fold(0, int_add, ch_area)
```

**执行规则**：
- `route_get_tag`：1 次内存读
- `route_dispatch`：1 次数组索引 + 1 次间接调用

**优化**：若编译期可确定所有 shapes 都是 Circle，`routeSpecialize` 把 route 消除为直接调用。

### 8.3 defer：清理链

**问题**：执行时机依赖 halt。

**方案**：defer 栈独立于主节点流，halt 时 LIFO 执行。

```
fun process() {
    defer cleanup_a()
    defer cleanup_b()
    return result
}
```

编译为：

```
主节点流：
  N0: cleanup_register(cleanup_a)   // 注册到 defer 栈
  N1: cleanup_register(cleanup_b)   // 注册到 defer 栈
  N2: ... 主计算 ...
  N3: halt_return(result)

defer 栈（LIFO）：
  cleanup_b 的节点序列
  cleanup_a 的节点序列
```

**执行规则**：
- `cleanup_register`：压栈（O(1)）
- halt 时 `executeCleanups`：LIFO 弹栈执行

### 8.4 select：竞争图

**问题**：多源竞争等待。

**方案**：race 节点检查所有源，第一个就绪的胜出。

```
select {
    ch1.recv() => v => handle_a(v)
    ch2.recv() => v => handle_b(v)
}
```

编译为：

```
N0: ch_r1 = race_source(ch1)    // try_recv
N1: ch_r2 = race_source(ch2)    // try_recv
N2: ch_winner = race_select(ch_r1, ch_r2)
N3: result = route_dispatch(ch_winner, [handle_a, handle_b])
```

**执行规则**：
- `race_source`：1 次 try_recv
- `race_select`：1 次比较找第一个就绪
- 若全部未就绪：`race_yield` 让出执行权（结合协程调度器）

### 8.5 循环/递归：向量 op

**问题**：循环/递归的 dispatch 频率 O(N)。

**方案**：向量化，dispatch 降到 O(1)。

```
// 计算 0 到 999 的平方和
var sum = 0
for i in 0..1000 { sum += i * i }
```

编译为：

```
N0: ch_src = vec_source(range, 0, 1000)     // 1 次 dispatch
N1: ch_sq = vec_map(int_mul, ch_src, ch_src) // 1 次 dispatch
N2: ch_sum = vec_fold(0, int_add, ch_sq)     // 1 次 dispatch
// 共 3 次 dispatch（vs 传统 5000 次）
```

**递归**：

```
fun fib(n): i32 {
    if n < 2 return n
    return fib(n-1) + fib(n-2)
}
```

编译为：

```
N0: ch_init = vec_source(repeat, (0, 1))
N1: ch_iter = vec_scan(step_fib, ch_init)    // (a,b) → (b, a+b)
N2: ch_taken = vec_take(n, ch_iter)
N3: ch_first = vec_map(fst, ch_taken)
N4: result = vec_sink(last, ch_first)
// 零递归调用，零栈帧
```

---

## 9. 星轨扩展层（async/spawn）

### 9.1 为什么 async 保留星轨

async 是唯一真正需要"独立执行单元 + 并行调度"的特性。它不在同一线性流里，无法用门控/路由/竞争节点表达。

### 9.2 星轨作为 Glue IR 的扩展层

```
async fun compute() -> i32 { ... }

编译为：
  N0: orbit_async_create(compute_func) → handle
  // 主节点流继续执行，不等待
  ...
  N1: result = orbit_async_join(handle)
  // 等待 async 完成，取结果
```

### 9.3 星轨调度器

```zig
const OrbitScheduler = struct {
    orbits: []OrbitInstance,
    worker_threads: []Thread,

    fn submit(self: *OrbitScheduler, func: u16) u16 {
        // 创建轨道实例，分发到 worker 线程
    }

    fn join(self: *OrbitScheduler, handle: u16) Value {
        // 等待轨道完成，返回结果
    }
};
```

### 9.4 星轨与主图的关系

- 星轨轨道是独立的 Glue IR 子图
- 通过桥接通道与主图传递数据
- async_create 激活轨道，async_join 等待结果
- 主图不阻塞，继续执行后续节点

---

## 10. 内存布局

### 10.1 分配器分区布局

Glue IR 的内存由 `src/mem/` 的自实现分配器管理，按生命周期分三层：

```
┌─────────────────────────────────────────────────────────┐
│ ThreadContext 对象池（中长生命周期，精确尺寸页池）        │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 节点流页（16B Node × N，连续存储）               │   │
│  │ [N0][N1][N2][N3]...[Nn]                         │   │
│  ├─────────────────────────────────────────────────┤   │
│  │ 元数据表页（按类型分表，同表连续）                │   │
│  │ [ScalarMeta × n][VectorMeta × n][GateMeta × n]  │   │
│  ├─────────────────────────────────────────────────┤   │
│  │ 函数表页（每个 Function 含 nodes 指针 + 元信息）  │   │
│  │ [Func0][Func1]...                              │   │
│  ├─────────────────────────────────────────────────┤   │
│  │ 星轨表页（Orbit 定义）                          │   │
│  │ [Orbit0][Orbit1]...                            │   │
│  ├─────────────────────────────────────────────────┤   │
│  │ 字符串常量池页                                  │   │
│  │ [str0][str1]...                                │   │
│  └─────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│ ChannelRegion（短生命周期，bump+reset，64B 对齐）        │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 通道数据区（基本块级 reset）                     │   │
│  │ [ch0: 4B][ch1: 8B][ch2: 1B]...（64B 对齐）      │   │
│  └─────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│ ShadowArena（极短生命周期，bump+reset，16B 对齐）        │
│  ┌─────────────────────────────────────────────────┐   │
│  │ defer 栈（函数级 reset）                        │   │
│  │ [DeferEntry0][DeferEntry1]...                   │   │
│  ├─────────────────────────────────────────────────┤   │
│  │ 临时计算缓冲区（函数级 reset）                   │   │
│  │ [temp_buf0][temp_buf1]...                       │   │
│  └─────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│ GlobalPool.buddy（大对象，冷路径）                       │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 运行时大数组 / 大对象（>256B）                   │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 10.2 缓存友好性

- 节点流从对象池分配，连续存储，CPU 预取友好
- 通道数据从 ChannelRegion 分配，64B 对齐，SIMD 友好（AVX-512）
- 元数据按类型分表，同类访问连续
- 16 字节节点，一个缓存行放 4 个节点
- 临时数据从 ShadowArena 分配，16B 对齐，函数返回时 O(1) reset
- 三层分配器线程本地零锁，热路径无同步开销

### 10.3 分配器选型规则

| 数据特征 | 选型规则 | 示例 |
|---|---|---|
| 固定尺寸 + 中长生命周期 | ThreadContext 对象池 | Node、Meta、Function |
| 变长 + 短生命周期 + SIMD | ChannelRegion | 通道数据 |
| 变长 + 极短生命周期 | ShadowArena | defer 栈、临时缓冲 |
| 大对象（>256B） | GlobalPool.buddy | 运行时大数组 |
| 编译期已知 + 程序级 | ThreadContext 对象池 | 字符串常量池 |

---

## 11. SIMD 集成

Glue IR 的向量 op 直接映射到 `src/value/batch.zig` 的 SIMD 批量运算，实现真正的数据级并行。

### 11.1 SIMD 基础设施（已有，复用）

| 组件 | 位置 | 作用 |
|---|---|---|
| `SIMD_BITS = 128` | `src/lfe/lamina.zig` | 128 位 SIMD 基准（平台无关） |
| `simdLaneCount(T)` | `src/lfe/lamina.zig` | 按类型计算通道数（i32→4, i64→2, i8→16） |
| `batchBinOp` | `src/value/batch.zig` | 二元算术批量运算（@Vector） |
| `batchUnary` | `src/value/batch.zig` | 一元算术批量运算 |
| `batchCompare` | `src/value/batch.zig` | 比较运算（输出 u8 mask） |
| `batchSelect` | `src/value/batch.zig` | 条件选择（mask 驱动） |
| `batchFma` | `src/value/batch.zig` | 融合乘加（a*b+c） |
| `batchScaleAdd` | `src/value/batch.zig` | 缩放加（a*scale+addend） |
| `broadcast` | `src/value/batch.zig` | 广播常量 |
| `ChannelRegion` | `src/mem/channel_region.zig` | 64B 对齐，SIMD 友好 |

### 11.2 向量 op → SIMD 函数映射

每个向量 op 的内部执行直接调用 batch.zig 的 SIMD 函数：

```zig
const batch = @import("value").batch;

fn execVecMap(engine: *Engine, node: Node) void {
    const meta = engine.ir.vector_metas[node.meta_index];
    const src_ch = engine.channels.get(node.inputs[0]);
    const dst_ch = engine.channels.get(node.output);

    // 按类型分派到 SIMD 批量运算
    switch (meta.inner_op) {
        .int_add => {
            const T = intTypeFromMeta(meta.inner_meta);
            switch (T) {
                .i32 => batch.batchBinOp(i32, .add, dst_ch.asSlice(i32), src_ch.asSlice(i32), ...),
                .i64 => batch.batchBinOp(i64, .add, ...),
                // ... 其他整数宽度
            }
        },
        .float_mul => {
            const T = floatTypeFromMeta(meta.inner_meta);
            switch (T) {
                .f32 => batch.batchBinOp(f32, .mul, ...),
                .f64 => batch.batchBinOp(f64, .mul, ...),
                // ...
            }
        },
        // ...
    }
}
```

### 11.3 完整映射表

| 向量 op | SIMD 函数 | 说明 |
|---|---|---|
| `vec_map(int_add)` | `batchBinOp(T, .add, ...)` | 4 路并行（i32） |
| `vec_map(int_sub)` | `batchBinOp(T, .sub, ...)` | 4 路并行 |
| `vec_map(int_mul)` | `batchBinOp(T, .mul, ...)` | 4 路并行 |
| `vec_map(int_neg)` | `batchUnary(T, .neg, ...)` | 4 路并行 |
| `vec_map(int_abs)` | `batchUnary(T, .abs, ...)` | 4 路并行 |
| `vec_map2(int_add)` | `batchBinOp(T, .add, ...)` | 双流合并 |
| `vec_select` | `batchSelect(T, ...)` | mask 驱动选择 |
| `vec_filter` | `batchCompare` + 压缩 | mask 生成 + compact |
| `vec_fold(add)` | `batchBinOp` 分治 + 标量归约 | 树形归约 |
| `vec_scan(add)` | `batchBinOp` 前缀和 | 前缀扫描 |
| FMA 优化 | `batchFma(T, ...)` | a*b+c 融合 |
| 广播常量 | `broadcast(T, ...)` | @splat |

### 11.4 通道布局保证 SIMD 对齐

```
ChannelRegion（64B 对齐）：
┌──────────────────────────────────────────────────┐
│ ch0: [i32 × 4]  │ ch1: [i32 × 4]  │ ch2: [i32 × 4]│
│  16B 对齐        │  16B 对齐        │  16B 对齐     │
├──────────────────────────────────────────────────┤
│ 每个 i32 通道恰好填满 1 个 SIMD 寄存器（4 × 32bit）│
│ 无需尾端标量处理                                  │
└──────────────────────────────────────────────────┘
```

**关键设计**：通道宽度按 SIMD 寄存器对齐：
- i32 通道：16B（4 × 4B，1 个 SSE/NEON 寄存器）
- i64 通道：16B（2 × 8B，1 个 SSE/NEON 寄存器）
- f32 通道：16B（4 × 4B）
- f64 通道：16B（2 × 8B）
- i8 通道：16B（16 × 1B）

### 11.5 vec_fold 的 SIMD 树形归约

```
// 1000 个 i32 求和
// 传统标量：1000 次加法
// SIMD 树形归约：250 次 SIMD 加法 + 1 次标量归约

批次 1: [v0  v1  v2  v3]  +
批次 2: [v4  v5  v6  v7]  =
        [s0  s1  s2  s3]   ← 1 次 SIMD add（4 路并行）

... 250 次 SIMD add ...

最终：[r0  r1  r2  r3]  →  r0+r1+r2+r3  ← 3 次标量加法
```

```zig
fn execVecFold(engine: *Engine, node: Node) void {
    const meta = engine.ir.vector_metas[node.meta_index];
    const src = engine.channels.get(node.inputs[0]).asSlice(i32);
    const init = engine.channels.get(node.inputs[1]).asScalar(i32);

    // SIMD 树形归约
    const lanes = simdLaneCount(i32);  // 4
    var acc: @Vector(lanes, i32) = @splat(init);
    var i: usize = 0;
    while (i + lanes <= src.len) : (i += lanes) {
        const v: @Vector(lanes, i32) = src[i..][0..lanes].*;
        acc += v;  // 1 次 SIMD add
    }
    // 标量归约剩余通道
    var result: i32 = 0;
    const arr: [lanes]i32 = acc;
    for (arr) |x| result += x;
    while (i < src.len) : (i += 1) result += src[i];

    engine.channels.setScalar(node.output, result);
}
```

### 11.6 vec_filter 的 SIMD mask 实现

```
// 过滤 arr 中 > 10 的元素
// 1. batchCompare 生成 mask
// 2. 按 mask 压缩

arr:    [5, 15, 8, 20, 3, 25, 10, 30]
mask:   [0,  1, 0,  1, 0,  1,  0,  1]  ← batchCompare 1 次 SIMD
result: [15, 20, 25, 30]               ← compact
```

```zig
fn execVecFilter(engine: *Engine, node: Node) void {
    const src = engine.channels.get(node.inputs[0]).asSlice(i32);
    const threshold = engine.channels.get(node.inputs[1]).asScalar(i32);
    const mask_buf = engine.tctx.arena.alloc(src.len) catch unreachable;  // 临时 mask

    // 1. SIMD 比较：生成 mask
    //    广播 threshold 后批量比较
    batch.broadcast(i32, threshold_slice, threshold);
    batch.batchCompare(i32, .gt, mask_buf, src, threshold_slice);

    // 2. 按 mask 压缩
    const dst = engine.channels.get(node.output).asSlice(i32);
    var dst_idx: usize = 0;
    for (src, 0..) |v, i| {
        if (mask_buf[i] != 0) {
            dst[dst_idx] = v;
            dst_idx += 1;
        }
    }
    engine.channels.setLength(node.output, dst_idx);
}
```

### 11.7 SIMD 自动平台映射

`@Vector` 是 Zig 的平台无关 SIMD 抽象，编译器自动映射到目标架构指令：

| 架构 | 128 位映射 | 说明 |
|---|---|---|
| x86_64 | SSE2 | `@Vector(4, i32)` → `PADDD` |
| aarch64 | NEON | `@Vector(4, i32)` → `ADD V0.4S` |
| riscv64 | RVV | `@Vector(4, i32)` → `vadd.vv` |
| loongarch64 | LSX | `@Vector(4, i32)` → `vadd.w` |

**零跨平台代码**：Glue 不写任何架构相关代码，Zig 编译器自动选择最优指令。

### 11.8 标量 op 和向量 op 的统一

标量 op 是 N=1 的向量 op。执行引擎可以统一处理：

```zig
fn execIntAdd(engine: *Engine, node: Node) void {
    const meta = engine.ir.scalar_metas[node.meta_index];
    const T = intTypeFromMeta(meta);

    // 如果通道是批量通道（element_count > 1），走 SIMD
    if (engine.channels.getElementCount(node.inputs[0]) > 1) {
        batch.batchBinOp(T, .add,
            engine.channels.get(node.output).asSlice(T),
            engine.channels.get(node.inputs[0]).asSlice(T),
            engine.channels.get(node.inputs[1]).asSlice(T));
    } else {
        // 标量路径
        const a = engine.channels.get(node.inputs[0]).asScalar(T);
        const b = engine.channels.get(node.inputs[1]).asScalar(T);
        engine.channels.setScalar(node.output, a + b);
    }
}
```

**关键优势**：标量 op 和向量 op 共享同一套类型处理逻辑，只是数据宽度不同。SIMD 是数据宽度的自然延伸，不是特殊路径。

### 11.9 性能预期

以"1000 个 i32 求和"为例：

| 实现 | 指令数 | 说明 |
|---|---|---|
| 标量循环 | 1000 ADD | 逐元素相加 |
| SIMD 树形归约 | 250 SIMD ADD + 3 ADD | 4 路并行 |
| **加速比** | **~4x** | 128 位 SIMD |

以"1000 个 i32 加 1000 个 i32"为例：

| 实现 | 指令数 | 说明 |
|---|---|---|
| 标量循环 | 1000 ADD | 逐元素相加 |
| vec_map(int_add) | 250 SIMD ADD | 4 路并行 |
| **加速比** | **~4x** | 128 位 SIMD |

---

## 12. 性能分析

### 12.1 dispatch 频率对比

以"计算 0 到 999 的平方和"为例：

| 模型 | dispatch 次数 | 备注 |
|---|---|---|
| LFE 星轨 | ~5000 | 循环 × (op + 回边 + 条件) |
| Glue IR 向量 | 3 | vec_source + vec_map + vec_fold |

### 12.2 单 op 开销对比

| 维度 | LFE 当前 | Glue IR 目标 |
|---|---|---|
| 分派 | 函数指针表（~10 周期） | switch 跳转表（~1 周期） |
| 节点传递 | 按值复制 64B | 指针 16B |
| 通道访问 | 三重间接 | 局部变量缓存 |
| 类型分派 | inline for + if（线性） | switch（跳转表） |

### 12.3 各特性开销

| 特性 | Glue IR 开销 | 备注 |
|---|---|---|
| 标量算术 | 1 周期/op | switch 分派 |
| 向量 map | 1 次 dispatch + SIMD 批处理 | dispatch 降 1000 倍 + SIMD 4 倍 |
| if/match | 0 dispatch | 数据选择 |
| `?` 传播 | 1 周期/?点 | gate_check |
| Trait 分派 | 1 次查表 + 1 次间接调用 | route_dispatch |
| defer | 0（仅 halt 时） | cleanup_run |
| select | N 次尝试 + 1 次选择 | race_select |
| async | 星轨调度 | orbit_scheduler |

### 12.4 综合加速比

以"1000 个 i32 数组求和"为例：

| 模型 | dispatch | 计算指令 | 总开销 | 相对加速 |
|---|---|---|---|---|
| LFE 星轨 | 5000 次函数指针 | 1000 次标量 ADD | ~60000 周期 | 1x（基准） |
| Glue IR 向量 | 3 次 switch | 250 次 SIMD ADD | ~1300 周期 | **~46x** |
| 理论极限 | 0 | 250 次 SIMD ADD | ~1000 周期 | ~60x |

**加速来源**：
- dispatch 降频：5000 → 3（~1666 倍）
- SIMD 并行：1000 → 250（~4 倍）
- 综合加速：~46 倍

---

## 13. 实现路线图

### Phase 1: Glue IR 核心（前端）
- 定义 Node / NodeOp / GlueIR 结构
- sema 输出 SemaResult
- 图构建器：AST → Glue IR
- 覆盖标量 op + 基础控制流

### Phase 2: 向量 op
- 实现 vec_source / vec_map / vec_fold / vec_scan / vec_select
- 循环/递归编译为向量 op
- 验证 dispatch 降频

### Phase 3: 门控/路由/竞争/清理节点
- gate 节点链（? 短路）
- route 节点（Trait 分派）
- race 节点（select）
- cleanup 节点（defer）

### Phase 4: 优化器
- constantFold / deadNodeElim / channelLiveness
- monomorphInline / gateHoisting / vecFusion

### Phase 5: 星轨扩展
- orbit_async_create / orbit_async_join
- OrbitScheduler 调度器
- 桥接通道

### Phase 6: 迁移与验证
- 迁移现有测试
- 性能基准测试
- 交叉编译验证

---

## 14. 与现有代码的关系

| 现有模块 | 新架构角色 | 处理 |
|---|---|---|
| `src/lfe/lamina.zig` | 演化为 Node | 重构 |
| `src/lfe/engine.zig` | 后端执行引擎 | 重构 |
| `src/lfe/compiler.zig` | 前端图构建器 | 重构 |
| `src/lfe/optimizer.zig` | 中端优化器 | 重构 |
| `src/lfe/builtin.zig` | 内置方法表 | 保留 |
| `src/sema/` | 前端 sema | 强化 |
| `src/parse/` | 前端 parse | 保留 |
| `src/value/` | 运行时值系统 | 保留 |
| `src/value/batch.zig` | SIMD 批量运算 | **核心复用** |
| `src/mem/` | 内存管理 | 保留 |
| `src/sync/` | 并发原语 | 保留 |

---

## 15. 设计风险

| 风险 | 影响 | 对策 |
|---|---|---|
| ? 短路全计算浪费 | 失败时多余计算 | gateHoisting 优化重排 |
| 向量 op 对副作用循环不友好 | 副作用顺序难保证 | 保留标量循环 fallback |
| route 间接调用开销 | 动态分派慢于直接调用 | routeSpecialize 消除 |
| 星轨调度复杂度 | async 实现难度 | 复用现有协程调度器 |
| 优化器 pass 顺序敏感 | 优化效果不稳定 | 固定 pass 顺序 + 不动点迭代 |
| SIMD 尾端处理 | 长度非 lanes 整数倍 | batch.zig 已有标量尾端处理 |

---

## 16. 总结

Glue IR 是为 Glue 量身设计的共享内存图执行模型：

- **统一图结构**：所有节点在同一连续内存，零切换开销
- **向量 op**：循环/递归的 dispatch 从 O(N) 降到 O(1)
- **SIMD 并行**：向量 op 直接映射 batch.zig 的 @Vector 批量运算，4 路并行
- **专用节点**：gate/route/race/cleanup 各司其职
- **星轨扩展**：async/spawn 保留并行执行能力
- **三阶段清晰**：前端（parse+sema）→ 中端（优化器）→ 后端（执行引擎）
- **自实现分配器**：ThreadContext/ChannelRegion/ShadowArena/GlobalPool 四层

**核心洞察**：
1. dispatch 的问题不是"存在"，而是"太频繁"。向量 op 把频率降 1000 倍。
2. SIMD 是数据宽度的自然延伸，标量是 N=1 的向量。batch.zig 已有完整实现。
3. 综合加速比 ~46 倍（dispatch 降频 1666 倍 × SIMD 4 倍并行）。
