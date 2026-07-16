# LFE：层流执行（Laminar Flow Execution）设计文档

> **状态**：设计阶段
> **目标**：完全替代当前 VM 解释器与 JIT 编译器，以数量级幅度提升执行性能
> **约束**：平台无关、零外部依赖、内存占用极小、CPU 密集型场景大幅加速
>
> **关联文档**：
> - [value-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/value-redesign.md) — Value 重建设计（`[N]u8` 标量 + 统一 ObjHeader + SWAC 运算）
> - [runtime-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/runtime-redesign.md) — Mem + Sync 重建设计（页池 + buddy + 通道线性区）

---

## 1. 设计动机

### 1.1 当前执行模型的根本局限

所有现有执行模型（VM / JIT / AOT）共享一个根本假设：**程序是指令序列**。

```
解释器：取指 → 解码 → 分派 → 执行 → 写回    （每条 5-10ns）
JIT：    CPU 取指 → 解码 → 执行 → 写回        （每条 0.25-1ns）
AOT：    同 JIT
```

只要"指令序列"这个抽象存在，就无法消除以下固有开销：

| 开销来源 | 说明 | 周期数 |
|---|---|---|
| 指令缓存缺失 | CPU 等 L2/L3 缓存 | 10-40 |
| 分支预测失败 | 流水线回滚 | 15-20 |
| 指令解码 | x86 复杂解码 | 4-6 |
| 类型检查 | tagged union 判断 | 1-3 |
| 函数调用 | 栈帧建立/销毁 | 3-5 |
| 中间结果搬运 | 寄存器/内存间传输 | 1-3 |

### 1.2 突破点

**消除"指令"这一抽象层。程序不是指令序列，而是数据流动的路径。**

LFE 的核心认知：

```
传统：程序 = 指令序列，执行 = 逐条取指解码执行
LFE： 程序 = 层流图，执行 = 数据持续流过层
```

没有取指、没有解码、没有分派。计算是数据流动的副产品——就像硬件电路，电路一旦建好，电流通过即出结果。

### 1.3 设计目标

| 目标 | 指标 |
|---|---|
| 比 VM 快 | 50-100 倍 |
| 比 JIT 快 | 8-16 倍 |
| 平台特定代码 | 零（完全依赖 Zig `@Vector` 自动适配） |
| 内存占用 | 当前 VM 的 5-10% |
| 内存碎片 | 零 |
| 外部依赖 | 零 |

---

## 2. 核心概念

### 2.1 层（Lamina）

层是 LFE 中最小的计算单元。**层不是指令**——它不描述"做什么操作"，而是描述"数据如何从输入通道流向输出通道"。

```
层 = (操作类型, 输入通道, 输出通道, 可选谓词, 可选常量)
```

一个层的执行语义：

```
读取输入通道的数据 → 执行操作 → 写入输出通道
```

层是纯数据描述，平台无关。同一套层描述可以在任何架构上执行。

### 2.2 通道（Channel）

通道是数据的载体。每个通道是一段连续内存，存储同类型的数据流。

**按实际宽度存储**：通道不使用统一宽度，而是按元素的实际字节宽度存储，最大化 SIMD 吞吐和缓存局部性。

```
通道 = (元素类型, 数据缓冲区 []u8, 元素字节宽度, 长度)
```

通道类型（按实际宽度分类）：

| 通道类型 | 存储内容 | 元素宽度 | 内存布局 |
|---|---|---|---|
| `i8_chan` / `u8_chan` | 8 位整数 | 1B | 连续 `[]u8` |
| `i16_chan` / `u16_chan` | 16 位整数 | 2B | 连续 `[]u8`（@bitCast 为 `[]i16`） |
| `i32_chan` / `u32_chan` | 32 位整数 | 4B | 连续 `[]u8`（@bitCast 为 `[]i32`） |
| `i64_chan` / `u64_chan` | 64 位整数 | 8B | 连续 `[]u8`（@bitCast 为 `[]i64`） |
| `i128_chan` / `u128_chan` | 128 位整数 | 16B | 连续 `[]u8`（@bitCast 为 `[]i128`） |
| `f16_chan` | 半精度浮点 | 2B | 连续 `[]u8`（@bitCast 为 `[]f16`） |
| `f32_chan` | 单精度浮点 | 4B | 连续 `[]u8`（@bitCast 为 `[]f32`） |
| `f64_chan` | 双精度浮点 | 8B | 连续 `[]u8`（@bitCast 为 `[]f64`） |
| `f128_chan` | 四精度浮点 | 16B | 连续 `[]u8`（@bitCast 为 `[]f128`） |
| `bool_chan` | 布尔值 | 1B | 连续 `[]u8`（0/1） |
| `char_chan` | Unicode 字符 | 4B | 连续 `[]u8`（@bitCast 为 `[]u32`） |
| `null_chan` | null 标记 | 0B | 无数据 |
| `unit_chan` | unit 标记 | 0B | 无数据 |
| `ref_chan` | 堆对象指针 | 8B | 连续 `[]u8`（@bitCast 为 `[]*ObjHeader`） |
| `mask_chan` | 比较结果/条件掩码 | 1B | 连续 `[]u8`（0/1，位压缩可选） |

**SoA 布局**：每个通道内部数据连续存储为 `[]u8`，SIMD 可通过 `@bitCast` 零成本转换为原生类型数组后直接向量加载，零 gather/scatter。

**按实际宽度的优势**（对比统一 u128）：

| 维度 | 统一 u128 | 按实际宽度 |
|---|---|---|
| i8 数组内存（1000 个） | 16000B | **1000B**（16x 节省） |
| i8 SIMD 吞吐 | 1 个/周期 | **16 个/周期**（@Vector(16,i8)） |
| riscv32 兼容 | u128 软件模拟 | u8-u32 原生支持 |
| 缓存局部性 | padding 稀释 | 紧凑，命中率高 |

### 2.3 层流图（Laminar Graph）

一个 Glue 函数被编译成层流图——一个有向无环图（DAG），节点是层，边是通道。

```
源码：fn compute(a: i64, b: i64) -> i64 { a + b * 2 }

层流图：
  ch_a ──────────────→ ┐
                        ├──→ [i64_add] ──→ ch_result
  ch_b → [i64_scale:×2] → ┘
```

层流图的关键特征：
- **无环**：DAG 结构，不存在回边
- **全内联**：函数调用在编译期全部内联，最终只有一个层流图
- **类型固化**：每个通道的类型在编译期确定，运行时零检查
- **平台无关**：层流图本身不包含任何架构相关信息

### 2.4 层序列（Lamina Sequence）

层流图在执行时被展平为**层序列**——按拓扑序排列的层列表。执行引擎逐层处理，每层处理所有数据。

```
层序列：
  Lamina 0: i64_scale   ch_b → ch_tmp   (b × 2)
  Lamina 1: i64_add     ch_a, ch_tmp → ch_result  (a + b×2)
  Lamina 2: halt_return ch_result
```

---

## 3. 类型系统与层定义

### 3.0 Glue 完整类型映射

LFE 覆盖 Glue 的全部 27 个 Value 变体（f8 已删除）。类型分为三大类：

| 分类 | Glue 类型 | LFE 通道类型 | 存储方式 |
|---|---|---|---|
| **标量（内联）** | i8/i16/i32/i64/i128, u8/u16/u32/u64/u128 | `i8_chan`...`u128_chan` | 按实际宽度 `[]u8`（1-16B/元素） |
| | f16/f32/f64/f128 | `f16_chan`...`f128_chan` | 按实际宽度 `[]u8`（2-16B/元素） |
| | bool | `bool_chan` | `[]u8`（0/1） |
| | char | `char_chan` | `[]u8`（@bitCast 为 `[]u32`） |
| | null | `null_chan` | 无数据（仅标记存在性） |
| | unit | `unit_chan` | 无数据（仅标记存在性） |
| **堆引用** | string | `ref_chan` + `RefKind.str` | `*ObjHeader` 指针 |
| | array | `ref_chan` + `RefKind.array` | `*ObjHeader` 指针 |
| | record | `ref_chan` + `RefKind.record` | `*ObjHeader` 指针 |
| | adt | `ref_chan` + `RefKind.adt` | `*ObjHeader` 指针 |
| | newtype | `ref_chan` + `RefKind.newtype` | `*ObjHeader` 指针 |
| | cell | `ref_chan` + `RefKind.cell` | `*ObjHeader` 指针 |
| | range | `ref_chan` + `RefKind.range` | `*ObjHeader` 指针 |
| | closure | `ref_chan` + `RefKind.closure` | `*ObjHeader` 指针 |
| | partial | `ref_chan` + `RefKind.partial` | `*ObjHeader` 指针 |
| | builtin | `ref_chan` + `RefKind.builtin` | `*ObjHeader` 指针 |
| | error_val | `ref_chan` + `RefKind.error_val` | `*ObjHeader` 指针 |
| | throw_val | `ref_chan` + `RefKind.throw_val` | `*ObjHeader` 指针 |
| | array_iterator | `ref_chan` + `RefKind.array_iter` | `*ObjHeader` 指针 |
| | string_iterator | `ref_chan` + `RefKind.string_iter` | `*ObjHeader` 指针 |
| | range_iterator | `ref_chan` + `RefKind.range_iter` | `*ObjHeader` 指针 |
| | atomic_val | `ref_chan` + `RefKind.atomic_val` | `*ObjHeader` 指针 |
| | spawn_val | `ref_chan` + `RefKind.spawn_val` | `*ObjHeader` 指针 |
| | channel_val | `ref_chan` + `RefKind.channel_val` | `*ObjHeader` 指针 |
| | sender_val | `ref_chan` + `RefKind.sender_val` | `*ObjHeader` 指针 |
| | receiver_val | `ref_chan` + `RefKind.receiver_val` | `*ObjHeader` 指针 |
| | trait_value | `ref_chan` + `RefKind.trait_val` | `*ObjHeader` 指针 |
| | lazy_val | `ref_chan` + `RefKind.lazy_val` | `*ObjHeader` 指针 |
| **谓词** | 比较结果 / 条件 | `mask_chan` | `[]u8`（0/1） |

### 3.0.1 通道与引用类型定义

```zig
/// 标量通道类型（按实际宽度）
const ScalarChanType = enum(u5) {
    // 整数（10 种）
    i8_chan, i16_chan, i32_chan, i64_chan, i128_chan,
    u8_chan, u16_chan, u32_chan, u64_chan, u128_chan,
    // 浮点（4 种，无 f8）
    f16_chan, f32_chan, f64_chan, f128_chan,
    // 其他标量
    bool_chan, char_chan, null_chan, unit_chan,
    // 堆引用与谓词
    ref_chan, mask_chan,
};

/// 堆引用的子类型标签（用于 ref_chan 的语义区分）
/// 详细定义见 value-redesign.md
const RefKind = enum(u5) {
    str, array, record, adt, newtype, cell, range,
    closure, partial, builtin, trait_val, lazy_val,
    error_val, throw_val,
    array_iter, string_iter, range_iter,
    atomic_val, spawn_val, channel_val, sender_val, receiver_val,
    generic,  // 通用指针（类型未知时）
};

/// 整数子类型（用于层操作特化）
const IntKind = enum(u4) {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
};

/// 浮点子类型（无 f8）
const FloatKind = enum(u3) {
    f16, f32, f64, f128,
};
```

### 3.0.2 按实际宽度策略

通道按元素的实际字节宽度存储为 `[]u8`，而非统一宽度。原因：

1. **内存精确**：i8 数组就是 1B/元素，零 padding 浪费
2. **SIMD 吞吐最优**：`@Vector(16, i8)` 一次处理 16 个 i8，`@Vector(4, i32)` 一次处理 4 个 i32
3. **跨平台一致**：`[]u8` 在所有架构上布局一致（无对齐差异）
4. **riscv32 友好**：u8-u32 原生支持，无需 u128 软件模拟

```zig
/// 通道的内存布局
/// 所有通道的数据缓冲区都是 []u8
/// 运算时通过 @bitCast 零成本转换为原生类型
const Channel = struct {
    data: []u8,           // 连续字节流（64B 对齐，SIMD 友好）
    elem_width: u4,       // 每元素字节数（1/2/4/8/16，或 0 表示无数据）
    elem_count: usize,    // 元素数量
    chan_type: ScalarChanType,
};
```

### 3.1 层数据结构

```zig
/// 层：平台无关的计算单元
const Lamina = struct {
    op: LaminaOp,
    /// 输入通道索引（最多 3 个，用于 fma 等三操作数层）
    inputs: [3]u16,
    /// 输出通道索引
    output: u16,
    /// 谓词掩码通道（可选，用于条件执行）
    predicate: ?u16 = null,
    /// 编译期常量 1（多用途：常量值、scale 乘数、字段索引等）
    const_val: ?i64 = null,
    /// 编译期常量 2（用于 scale_add 的加数）
    const_val2: ?i64 = null,
    /// 整数子类型（用于 int_chan 操作特化）
    int_kind: ?IntKind = null,
    /// 浮点子类型（用于 float_chan 操作特化，无 f8）
    float_kind: ?FloatKind = null,
    /// 堆引用子类型（用于 ref_chan 操作特化）
    ref_kind: ?RefKind = null,
    /// 外部函数索引（用于 extern_call）
    extern_idx: ?u16 = null,
    /// 字段名/构造器名索引（用于 record/adt 字段访问）
    name_idx: ?u16 = null,
};
```

### 3.2 层操作枚举

```zig
const LaminaOp = enum(u8) {
    // ════════════════════════════════════════════
    // 常量与载入
    // ════════════════════════════════════════════
    constant,          // 将编译期常量广播到整个通道
                      //   int_chan: const_val 为值，int_kind 标注类型
                      //   float_chan: const_val 重解释为 f64，float_kind 标注类型
                      //   bool_chan: const_val 0=false, 1=true
                      //   char_chan: const_val 为 Unicode 码点
                      //   null_chan: 无参数
                      //   unit_chan: 无参数
    broadcast_input,   // 将标量输入广播到整个通道

    // ════════════════════════════════════════════
    // 整数算术（int_kind 标注具体子类型，运行时零检查）
    // 运算通过 @bitCast 转为原生类型后执行，编译为 1 条原生指令
    // ════════════════════════════════════════════
    int_add,           // a + b（溢出行为按 int_kind 的符号/宽度处理）
    int_sub,           // a - b
    int_mul,           // a * b
    int_div,           // a / b（除零 → halt_throw）
    int_mod,           // a % b
    int_neg,           // -a
    int_abs,           // |a|（有符号数取绝对值）

    // 整数融合算术
    int_scale,         // a * k（k = const_val）
    int_scale_add,     // a * k + c（k = const_val, c = const_val2）
    int_fma,           // a * b + c（三通道输入）

    // 整数位运算
    int_and,           // a & b
    int_or,            // a | b
    int_xor,           // a ^ b
    int_shl,           // a << b（b 来自通道或 const_val）
    int_shr,           // a >> b
    int_not,           // ~a

    // ════════════════════════════════════════════
    // 浮点算术（float_kind 标注具体子类型，无 f8）
    // f16/f32/f64/f128 全部有 Zig 原生类型，@bitCast 零成本
    // ════════════════════════════════════════════
    float_add, float_sub, float_mul, float_div,
    float_neg, float_abs,
    float_sqrt, float_floor, float_ceil, float_round,
    float_sin, float_cos, float_tan, float_log, float_exp,
    float_pow,         // a^b

    // 浮点融合算术
    float_scale,       // a * k
    float_scale_add,   // a * k + c
    float_fma,         // a * b + c

    // ════════════════════════════════════════════
    // 布尔运算（bool_chan）
    // ════════════════════════════════════════════
    bool_and,          // a && b
    bool_or,           // a || b
    bool_not,          // !a
    bool_xor,          // a != b（异或）

    // ════════════════════════════════════════════
    // 字符运算（char_chan）
    // ════════════════════════════════════════════
    char_to_int,       // 字符 → 整数码点
    int_to_char,       // 整数码点 → 字符（校验合法性）
    char_is_alpha,     // 是否字母
    char_is_digit,     // 是否数字
    char_is_whitespace,// 是否空白

    // ════════════════════════════════════════════
    // 比较（输出 mask_chan）
    // ════════════════════════════════════════════
    int_lt, int_gt, int_eq, int_ne, int_le, int_ge,
    float_lt, float_gt, float_eq, float_ne, float_le, float_ge,
    bool_eq, bool_ne,
    char_lt, char_gt, char_eq, char_ne, char_le, char_ge,

    // ════════════════════════════════════════════
    // 谓词与掩码
    // ════════════════════════════════════════════
    select,            // mask ? true_val : false_val（替代 if/else）
    mask_and,          // mask1 & mask2
    mask_or,           // mask1 | mask2
    mask_not,          // !mask
    mask_zero,         // 按 mask 将值清零（mask=0 处置零）

    // ════════════════════════════════════════════
    // 类型转换（@bitCast 零成本，仅改变解释方式）
    // ════════════════════════════════════════════
    int_widen,         // 整数宽度扩展（i32 → i64，int_kind 标注目标类型）
    int_narrow,        // 整数宽度截断（i64 → i32，溢出 → halt_throw）
    int_to_float,      // 整数 → 浮点
    float_to_int,      // 浮点 → 整数（截断/舍入按 int_kind）
    float_widen,       // 浮点精度扩展（f32 → f64）
    float_narrow,      // 浮点精度截断（f64 → f32）
    int_reinterpret,   // 有符号/无符号重解释（i32 ↔ u32，不改比特）
    null_to_nullable,  // null → nullable<T>（标记为空）

    // ════════════════════════════════════════════
    // 字符串操作（ref_chan + ref_kind=str）
    // ════════════════════════════════════════════
    str_const,         // 加载字符串常量（name_idx 索引常量表）
    str_concat,        // 字符串拼接（a + b）
    str_len,           // 字符串长度 → int_chan
    str_char_at,       // 字符串索引 → char_chan（越界 → halt_throw）
    str_slice,         // 子串截取
    str_to_chars,      // 字符串 → char_chan 流（逐字符）
    chars_to_str,      // char_chan 流 → 字符串
    str_eq,            // 字符串相等比较 → mask_chan
    str_starts_with,   // 前缀匹配 → mask_chan
    str_contains,      // 包含检查 → mask_chan

    // ════════════════════════════════════════════
    // 数组操作（ref_chan + ref_kind=array）
    // ════════════════════════════════════════════
    array_make,        // 创建数组（const_val = 长度，元素从输入通道填充）
    array_len,         // 数组长度 → int_chan
    array_get,         // 数组索引读取 → 任意通道（越界 → halt_throw）
    array_set,         // 数组索引写入
    array_push,        // 追加元素（可能触发扩容）
    array_map,         // 对每个元素应用子层流图 → 新数组
    array_filter,      // 按谓词过滤 → 新数组
    array_reduce,      // 归约 → 标量
    array_concat,      // 数组拼接
    array_slice,       // 数组切片
    array_to_stream,   // 数组 → 元素流（SoA 通道，用于 SIMD 批处理）
    stream_to_array,   // 元素流 → 数组

    // ════════════════════════════════════════════
    // 记录操作（ref_chan + ref_kind=record）
    // ════════════════════════════════════════════
    record_make,       // 创建记录（字段从多个输入通道填充，字段名从 name_idx 表获取）
    record_get,        // 读取字段（name_idx = 字段名索引）→ 任意通道
    record_set,        // 写入字段（name_idx = 字段名索引）
    record_has,        // 检查字段是否存在 → mask_chan
    record_extend,     // 扩展记录（添加新字段）

    // ════════════════════════════════════════════
    // ADT 操作（ref_chan + ref_kind=adt）
    // ════════════════════════════════════════════
    adt_make,          // 构造 ADT 值（const_val = 构造器索引，字段从输入通道填充）
    adt_get_ctor,      // 读取构造器名 → str_chan
    adt_get_field,     // 读取字段（name_idx = 字段名索引）
    adt_test_ctor,     // 测试是否匹配某构造器 → mask_chan（const_val = 构造器索引）
    adt_match,         // 模式匹配分派（switch_lamina 的 ADT 特化版）

    // ════════════════════════════════════════════
    // Newtype 操作（ref_chan + ref_kind=newtype）
    // ════════════════════════════════════════════
    newtype_wrap,      // 包装内部值 → newtype
    newtype_unwrap,    // 解包 → 内部值

    // ════════════════════════════════════════════
    // Cell 操作（ref_chan + ref_kind=cell，可变引用）
    // ════════════════════════════════════════════
    cell_make,         // 创建可变单元格
    cell_get,          // 读取内部值
    cell_set,          // 写入内部值
    cell_swap,         // 原子交换

    // ════════════════════════════════════════════
    // Range 操作（ref_chan + ref_kind=range）
    // ════════════════════════════════════════════
    range_make,        // 创建区间（start, end, inclusive）
    range_start,       // 区间起点 → int_chan
    range_end,         // 区间终点 → int_chan
    range_len,         // 区间长度 → int_chan
    range_to_stream,   // 区间 → int_chan 流（逐元素，用于 SIMD 批处理）

    // ════════════════════════════════════════════
    // 闭包操作（ref_chan + ref_kind=closure）
    // ════════════════════════════════════════════
    closure_make,      // 创建闭包（extern_idx = 函数索引，捕获通道 = upvalues）
    closure_call,      // 调用闭包（参数从输入通道，结果到输出通道）
    closure_capture,   // 读取捕获的 upvalue（const_val = upvalue 索引）

    // ════════════════════════════════════════════
    // 部分应用操作（ref_chan + ref_kind=partial）
    // ════════════════════════════════════════════
    partial_make,      // 创建部分应用（绑定部分参数）
    partial_call,      // 补全剩余参数并调用

    // ════════════════════════════════════════════
    // 内置函数操作（ref_chan + ref_kind=builtin）
    // ════════════════════════════════════════════
    builtin_call,      // 调用内置函数（extern_idx = 函数索引）

    // ════════════════════════════════════════════
    // 错误与异常（ref_chan + ref_kind=error_val/throw_val）
    // ════════════════════════════════════════════
    error_make,        // 创建错误值（type_name + message）
    throw_make,        // 创建 Throw 值（ok 或 err 分支）
    throw_is_ok,       // 检查是否成功 → mask_chan
    throw_is_err,      // 检查是否错误 → mask_chan
    throw_get_ok,      // 提取成功值（错误时 → halt_throw）
    throw_get_err,     // 提取错误值（成功时 → halt_throw）
    throw_propagate,   // 错误传播（err 时跳转到异常处理层流图）

    // ════════════════════════════════════════════
    // 迭代器操作（ref_chan + ref_kind=array_iter/string_iter/range_iter）
    // ════════════════════════════════════════════
    iter_has_next,     // 是否有下一个元素 → mask_chan
    iter_next,         // 获取下一个元素 → 任意通道
    iter_to_stream,    // 迭代器 → 元素流（批量预取，用于 SIMD）

    // ════════════════════════════════════════════
    // 并发操作（ref_chan + ref_kind=atomic_val/spawn_val/channel_val/...）
    // 并发值类型定义在 value/concurrent.zig
    // ════════════════════════════════════════════
    atomic_make,       // 创建原子值
    atomic_load,       // 原子读取 → 任意通道
    atomic_store,      // 原子写入
    atomic_cas,        // 比较交换 → mask_chan（成功/失败）

    spawn_create,      // 创建并发任务（extern_idx = 任务层流图索引）
    spawn_join,        // 等待任务完成 → 结果通道
    spawn_yield,       // 当前任务让出执行权

    channel_make,      // 创建通道
    channel_split,     // 通道拆分为 (sender, receiver) 双输出
    channel_send,      // 通过 channel 整体发送值
    channel_recv,      // 从 channel 整体接收值 → 任意通道
    channel_try_recv,  // 非阻塞接收 → (value, mask) 双输出
    channel_close,     // 关闭通道

    // Sender/Receiver 端点操作
    sender_send,       // 通过 sender 端点发送值
    sender_close,      // 关闭 sender 端点
    receiver_recv,     // 通过 receiver 端点接收值 → 任意通道
    receiver_try_recv, // 非阻塞接收 → (value, mask) 双输出
    receiver_close,    // 关闭 receiver 端点

    // ════════════════════════════════════════════
    // Trait 操作（ref_chan + ref_kind=trait_val）
    // ════════════════════════════════════════════
    trait_make,        // 创建 trait 对象（包装具体类型 + vtable）
    trait_call_method,// 调用 trait 方法（name_idx = 方法名索引）
    trait_downcast,    // 向下转型到具体类型 → (value, mask) 双输出

    // ════════════════════════════════════════════
    // 惰性值操作（ref_chan + ref_kind=lazy_val）
    // ════════════════════════════════════════════
    lazy_make,         // 创建惰性值（延迟执行的子层流图）
    lazy_force,        // 强制求值 → 实际值（首次调用时执行，后续缓存）
    lazy_is_forced,    // 检查是否已求值 → mask_chan

    // ════════════════════════════════════════════
    // Nullable 操作
    // ════════════════════════════════════════════
    nullable_make,     // 包装值为 nullable（可能为 null）
    nullable_is_null,  // 检查是否为 null → mask_chan
    nullable_unwrap,   // 解包（null 时 → halt_throw）
    nullable_unwrap_or,// 解包，null 时返回默认值

    // ════════════════════════════════════════════
    // 聚合（通道内归约）
    // ════════════════════════════════════════════
    reduce_sum,        // 通道内所有元素求和 → 标量
    reduce_min,        // 通道内最小值 → 标量
    reduce_max,        // 通道内最大值 → 标量
    reduce_prod,       // 通道内所有元素求积 → 标量
    reduce_count,      // 通道内元素计数 → 标量

    // ════════════════════════════════════════════
    // 流控制（通道级操作）
    // ════════════════════════════════════════════
    compress,          // 按 mask 压缩通道（filter 语义）
    expand,            // 按 mask 扩展通道
    concat,            // 拼接两个通道
    slice,             // 截取通道子区间（const_val = 起, const_val2 = 长度）
    duplicate,         // 复制通道
    length,            // 通道元素数 → int_chan

    // ════════════════════════════════════════════
    // 控制流出口
    // ════════════════════════════════════════════
    halt_return,       // 正常返回，结果在 output 通道
    halt_throw,        // 抛出异常，异常值在 output 通道
    halt_break,        // 循环 break
    halt_continue,     // 循环 continue

    // ════════════════════════════════════════════
    // 动态分派
    // ════════════════════════════════════════════
    switch_lamina,     // 按类型 ID / 构造器分派到不同子层流图
    extern_call,       // 调用外部函数，标量模式
    extern_call_batch, // 批量调用外部函数
};
```

### 3.3 层的执行语义

每个层操作的执行模型统一为：

```
对于通道中的每一批数据（LANE_COUNT 个元素）：
  读取输入通道的该批数据（[]u8 → @bitCast → 原生类型）
  执行操作（原生指令，1 周期）
  写入输出通道的该批数据（原生类型 → @bitCast → []u8）
```

标量模式（单元素）是批大小为 1 的特例。@bitCast 在编译期消除，运行时零指令。

---

## 4. 编译流程

### 4.1 管道总览

```
源码 (.glue)
   │
   ▼
[1] 前端（复用现有）
   Lexer → Parser → Sema（类型信息）
   │
   ▼
[2] 层流图构建器（新增，平台无关）
   AST + 类型信息 → 层流图
   ├── 函数全内联
   ├── 变量 → 通道分配
   ├── 表达式 → 层节点
   ├── 分支 → 谓词层（select）
   ├── 循环 → 流式展开
   └── 类型固化到通道（按实际宽度）
   │
   ▼
[3] 层融合优化器（新增，平台无关）
   ├── 相邻层融合（×2 → +1 变成 scale_add）
   ├── 常量折叠
   ├── 死路径消除（谓词常量为 false 的路径）
   ├── 通道活跃区间分析 + 物理槽位复用
   └── 通道数量最小化
   │
   ▼
[4] 通道布局器（新增，平台无关）
   ├── 分配物理通道索引
   ├── 计算精确内存布局（编译期已知总字节数）
   └── 生成通道初始化元数据
   │
   ▼
[5] 流内核执行（平台无关，依赖 @Vector + mem.ThreadContext）
   数据 → 通道（mem.ChannelRegion 分配）→ 流内核逐层处理 → 输出
```

### 4.2 层流图构建器

```zig
const LaminarCompiler = struct {
    allocator: std.mem.Allocator,
    laminas: std.ArrayList(Lamina),
    channel_count: u16,
    /// 逻辑通道 → 类型映射
    channel_types: std.ArrayList(ScalarChanType),

    /// 从 AST 编译层流图
    pub fn compile(
        allocator: std.mem.Allocator,
        module: ast.Module,
        type_env: *TypeEnv,
    ) !LaminarGraph {
        var self = LaminarCompiler{
            .allocator = allocator,
            .laminas = std.ArrayList(Lamina).init(allocator),
            .channel_count = 0,
            .channel_types = std.ArrayList(ScalarChanType).init(allocator),
        };
        defer self.laminas.deinit();
        defer self.channel_types.deinit();

        // 查找 main 函数并编译
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (std.mem.eql(u8, f.name, "main")) {
                        try self.compileFunction(f, type_env);
                    }
                },
                else => {},
            }
        }

        return .{
            .laminas = try self.laminas.toOwnedSlice(),
            .channel_count = self.channel_count,
            .channel_types = try self.channel_types.toOwnedSlice(),
        };
    }

    /// 编译函数体
    fn compileFunction(
        self: *LaminarCompiler,
        func: ast.FunDecl,
        type_env: *TypeEnv,
    ) !void {
        // 为每个参数分配通道（按实际类型宽度）
        var param_channels = std.ArrayList(u16).init(self.allocator);
        defer param_channels.deinit();

        for (func.params) |param| {
            const chan_type = mapTypeToChan(param.type);
            const chan = self.allocChannel(chan_type);
            try param_channels.append(chan);
        }

        // 编译函数体表达式
        const result_chan = try self.compileExpr(
            func.body,
            param_channels.items,
            type_env,
        );

        // 发射返回层
        try self.laminas.append(.{
            .op = .halt_return,
            .inputs = .{ result_chan, 0 },
            .output = result_chan,
        });
    }

    /// 编译表达式 → 返回结果通道索引
    fn compileExpr(
        self: *LaminarCompiler,
        expr: *const ast.Expr,
        env: []const u16,
        type_env: *TypeEnv,
    ) anyerror!u16 {
        return switch (expr.*) {
            // ── 整数字面量 ──
            .int_lit => |lit| blk: {
                // 根据字面量类型选择通道宽度
                const chan_type = mapIntType(lit.int_kind);
                const chan = self.allocChannel(chan_type);
                try self.laminas.append(.{
                    .op = .constant,
                    .inputs = .{ chan, 0 },
                    .output = chan,
                    .const_val = lit.value,
                    .int_kind = lit.int_kind,
                });
                break :blk chan;
            },

            // ── 变量引用 ──
            .identifier => |id| env[id.scope_index],

            // ── 二元运算 ──
            .binary => |b| blk: {
                const lhs_chan = try self.compileExpr(b.left, env, type_env);
                const rhs_chan = try self.compileExpr(b.right, env, type_env);
                const result_type = type_env.typeOf(b.left);
                const chan_type = mapTypeToChan(result_type);
                const out_chan = self.allocChannel(chan_type);

                const op: LaminaOp = switch (b.op) {
                    .add => .int_add,
                    .sub => .int_sub,
                    .mul => .int_mul,
                    .div => .int_div,
                    .mod => .int_mod,
                    .bit_and => .int_and,
                    .bit_or => .int_or,
                    .bit_xor => .int_xor,
                    .lt => .int_lt,
                    .gt => .int_gt,
                    .eq => .int_eq,
                    .ne => .int_ne,
                    .le => .int_le,
                    .ge => .int_ge,
                    else => unreachable,
                };

                try self.laminas.append(.{
                    .op = op,
                    .inputs = .{ lhs_chan, rhs_chan },
                    .output = out_chan,
                    .int_kind = mapIntKind(result_type),
                });
                break :blk out_chan;
            },

            // ── 条件表达式（分支 → 谓词化）──
            .if_expr => |iff| blk: {
                const cond_chan = try self.compileExpr(iff.cond, env, type_env);
                const true_chan = try self.compileExpr(iff.then_branch, env, type_env);
                const false_chan = try self.compileExpr(iff.else_branch, env, type_env);
                const result_type = type_env.typeOf(iff.then_branch);
                const out_chan = self.allocChannel(mapTypeToChan(result_type));
                try self.laminas.append(.{
                    .op = .select,
                    .inputs = .{ true_chan, false_chan },
                    .output = out_chan,
                    .predicate = cond_chan,
                });
                break :blk out_chan;
            },

            // ── 函数调用（全内联）──
            .call => |c| blk: {
                if (isInlineable(c.callee)) {
                    const arg_channels = try self.allocator.alloc(u16, c.args.len);
                    defer self.allocator.free(arg_channels);
                    for (c.args, 0..) |arg, i| {
                        arg_channels[i] = try self.compileExpr(arg, env, type_env);
                    }
                    const result = try self.compileInline(c.callee, arg_channels, type_env);
                    break :blk result;
                } else {
                    const arg_chan = try self.compileExpr(c.args[0], env, type_env);
                    const out_chan = self.allocChannel(.i64_chan);
                    try self.laminas.append(.{
                        .op = .extern_call,
                        .inputs = .{ arg_chan, 0 },
                        .output = out_chan,
                        .extern_idx = c.callee_fn_idx,
                    });
                    break :blk out_chan;
                }
            },

            else => return error.UnsupportedExpr,
        };
    }

    /// 分配新通道
    fn allocChannel(self: *LaminarCompiler, chan_type: ScalarChanType) u16 {
        const idx = self.channel_count;
        self.channel_count += 1;
        self.channel_types.append(chan_type) catch unreachable;
        return idx;
    }
};
```

### 4.3 层融合优化器

```zig
const LaminarOptimizer = struct {
    /// 融合相邻层
    pub fn fuse(laminas: []Lamina) ![]Lamina {
        var result = std.ArrayList(Lamina).init(allocator);

        var i: usize = 0;
        while (i < laminas.len) {
            const lam = laminas[i];

            // 模式 1：scale + add → scale_add
            if (lam.op == .int_scale and i + 1 < laminas.len) {
                const next = laminas[i + 1];
                if (next.op == .int_add and
                    next.inputs[0] == lam.output and
                    isConstantChannel(next.inputs[1], laminas))
                {
                    try result.append(.{
                        .op = .int_scale_add,
                        .inputs = .{ lam.inputs[0], 0 },
                        .output = next.output,
                        .const_val = lam.const_val.?,
                        .const_val2 = getConstant(next.inputs[1], laminas),
                        .int_kind = lam.int_kind,
                    });
                    i += 2;
                    continue;
                }
            }

            // 模式 2：常量折叠
            if (lam.op == .constant and i + 1 < laminas.len) {
                const next = laminas[i + 1];
                if (next.op == .int_scale and next.inputs[0] == lam.output) {
                    const folded = lam.const_val.? *% next.const_val.?;
                    try result.append(.{
                        .op = .constant,
                        .inputs = .{ next.output, 0 },
                        .output = next.output,
                        .const_val = folded,
                        .int_kind = next.int_kind,
                    });
                    i += 2;
                    continue;
                }
            }

            // 模式 3：死路径消除
            if (lam.op == .select) {
                if (isConstantFalse(lam.predicate, laminas)) {
                    try result.append(.{
                        .op = .move,
                        .inputs = .{ lam.inputs[1], 0 },
                        .output = lam.output,
                    });
                    i += 1;
                    continue;
                }
            }

            try result.append(lam);
            i += 1;
        }

        return try result.toOwnedSlice();
    }

    /// 通道活跃区间分析 + 物理槽位复用
    /// （逻辑同旧版，此处省略，见旧文档 4.3 节）
    pub fn allocatePhysicalSlots(
        allocator: std.mem.Allocator,
        laminas: []const Lamina,
        logical_count: u16,
    ) !struct {
        mapping: []u16,
        physical_count: u16,
    } {
        // 线性扫描分配物理槽位（同旧版）
        // ...
    }
};
```

### 4.4 通道布局器

```zig
/// 内存布局元数据（编译期计算，无运行时开销）
/// 按实际宽度计算各通道的字节大小
const ChannelLayout = struct {
    /// 每个物理通道的元素字节宽度
    elem_widths: []const u4,
    /// 每个物理通道的元素数量
    elem_counts: []const usize,
    /// 每个物理通道的字节大小
    chan_bytes: []const usize,
    /// 总字节大小
    total_bytes: usize,

    /// 根据物理通道分配结果计算布局
    pub fn compute(
        allocator: std.mem.Allocator,
        physical_count: u16,
        channel_types: []const ScalarChanType,
        logical_to_physical: []const u16,
        element_count: usize,
    ) !ChannelLayout {
        var elem_widths = try allocator.alloc(u4, physical_count);
        var chan_bytes = try allocator.alloc(usize, physical_count);

        // 计算每个物理通道的元素宽度
        for (channel_types, 0..) |t, logical_idx| {
            const phys = logical_to_physical[logical_idx];
            elem_widths[phys] = chanElemWidth(t);
        }

        // 计算每个物理通道的字节大小
        var total: usize = 0;
        for (elem_widths, 0..) |w, i| {
            chan_bytes[i] = @as(usize, w) * element_count;
            total += chan_bytes[i];
        }

        return .{
            .elem_widths = elem_widths,
            .elem_counts = &.{}, // 所有通道 element_count 相同
            .chan_bytes = chan_bytes,
            .total_bytes = total,
        };
    }
};

/// 通道类型 → 元素字节宽度
fn chanElemWidth(chan_type: ScalarChanType) u4 {
    return switch (chan_type) {
        .null_chan, .unit_chan => 0,
        .i8_chan, .u8_chan, .bool_chan => 1,
        .i16_chan, .u16_chan, .f16_chan => 2,
        .i32_chan, .u32_chan, .f32_chan, .char_chan => 4,
        .i64_chan, .u64_chan, .f64_chan, .ref_chan, .mask_chan => 8,
        .i128_chan, .u128_chan, .f128_chan => 16,
    };
}
```

---

## 5. 流内核执行引擎

### 5.1 SWAC 运算模型

LFE 的运算核心采用 SWAC（Scalar Width-Adaptive Compute），详见 [value-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/value-redesign.md)。

核心原理：
1. 通道数据存储为 `[]u8`（按实际宽度）
2. 运算时 `@bitCast` 转为原生类型（编译期消除，零指令）
3. 原生类型运算（1 条 CPU 指令）
4. 结果 `@bitCast` 回 `[]u8`（编译期消除）

### 5.2 SIMD 宽度自动适配

```zig
/// 目标平台的 SIMD 宽度（编译期确定）
/// Zig 的 @Vector 会自动映射到目标平台的 SIMD 指令
const LANE_COUNT: usize = blk: {
    const arch = @import("builtin").cpu.arch;
    if (arch == .x86_64) break :blk 8;       // AVX2: 256-bit / 32-bit = 8
    if (arch == .aarch64) break :blk 4;      // NEON: 128-bit / 32-bit = 4
    if (arch == .riscv64) break :blk 4;      // RVV: 假设 VLEN=128
    if (arch == .riscv32) break :blk 2;      // RV32: 较窄
    if (arch == .loongarch64) break :blk 4;  // LSX: 128-bit
    break :blk 2;                             // 通用回退
};
```

### 5.3 通道访问接口

```zig
/// 物理通道的访问接口
/// 数据存储为 []u8，通过 @bitCast 零成本转换为原生类型
const PhysicalChannel = struct {
    data: []u8,              // 连续字节流（64B 对齐）
    elem_width: u4,          // 每元素字节数
    element_count: usize,

    /// 泛型标量读：@bitCast 零成本
    pub inline fn getScalar(self: *const PhysicalChannel, comptime T: type, idx: usize) T {
        const w = @sizeOf(T);
        const ptr: *const T = @ptrCast(@alignCast(self.data.ptr + idx * w));
        return ptr.*;
    }

    /// 泛型标量写：@bitCast 零成本
    pub inline fn setScalar(self: *PhysicalChannel, comptime T: type, idx: usize, val: T) void {
        const w = @sizeOf(T);
        const ptr: *T = @ptrCast(@alignCast(self.data.ptr + idx * w));
        ptr.* = val;
    }

    /// SIMD 向量读：@bitCast 零成本
    pub inline fn getVec(self: *const PhysicalChannel, comptime T: type, batch_idx: usize) @Vector(LANE_COUNT, T) {
        const start = batch_idx * LANE_COUNT;
        const w = @sizeOf(T);
        const slice: *const [LANE_COUNT]T = @ptrCast(@alignCast(self.data.ptr + start * w));
        return slice.*;
    }

    /// SIMD 向量写：@bitCast 零成本
    pub inline fn setVec(self: *PhysicalChannel, comptime T: type, batch_idx: usize, vec: @Vector(LANE_COUNT, T)) void {
        const start = batch_idx * LANE_COUNT;
        const w = @sizeOf(T);
        const slice: *[LANE_COUNT]T = @ptrCast(@alignCast(self.data.ptr + start * w));
        slice.* = vec;
    }
};
```

### 5.4 泛型批量运算

```zig
/// 泛型批量加法：一个函数覆盖所有数值类型
/// @bitCast 编译期消除，编译为原生 SIMD 指令
pub fn batchAdd(comptime T: type, dst: *PhysicalChannel, a: *const PhysicalChannel, b: *const PhysicalChannel) void {
    const Vec = @Vector(LANE_COUNT, T);
    const batch_count = a.element_count / LANE_COUNT;
    const tail_start = batch_count * LANE_COUNT;

    // SIMD 主循环
    var i: usize = 0;
    while (i < batch_count) : (i += 1) {
        const va: Vec = a.getVec(T, i);
        const vb: Vec = b.getVec(T, i);
        dst.setVec(T, i, va +% vb);
    }
    // 标量尾部
    while (i < a.element_count) : (i += 1) {
        dst.setScalar(T, i, a.getScalar(T, i) +% b.getScalar(T, i));
    }
}

/// 泛型批量比较：输出 mask_chan
pub fn batchLt(comptime T: type, dst: *PhysicalChannel, a: *const PhysicalChannel, b: *const PhysicalChannel) void {
    const Vec = @Vector(LANE_COUNT, T);
    const batch_count = a.element_count / LANE_COUNT;

    var i: usize = 0;
    while (i < batch_count) : (i += 1) {
        const va: Vec = a.getVec(T, i);
        const vb: Vec = b.getVec(T, i);
        const mask: @Vector(LANE_COUNT, bool) = va < vb;
        // 将 bool 向量打包为 u8 数组写入 mask 通道
        for (0..LANE_COUNT) |j| {
            dst.setScalar(u8, i * LANE_COUNT + j, @intFromBool(mask[j]));
        }
    }
}
```

### 5.5 运行时分派表

当类型在运行时才知道（如异构运算），通过 comptime 生成的分派表一次间接调用：

```zig
/// int_kind → 原生类型（编译期映射）
fn NativeIntType(comptime kind: IntKind) type {
    return switch (kind) {
        .i8 => i8, .i16 => i16, .i32 => i32, .i64 => i64, .i128 => i128,
        .u8 => u8, .u16 => u16, .u32 => u32, .u64 => u64, .u128 => u128,
    };
}

/// comptime 生成加法分派表（10 种整数类型）
const int_add_table = blk: {
    const kinds = [_]IntKind{ .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128 };
    var table: [kinds.len]BatchAddFn = undefined;
    inline for (kinds, 0..) |kind, i| {
        const T = NativeIntType(kind);
        table[i] = struct {
            fn call(dst: *PhysicalChannel, a: *const PhysicalChannel, b: *const PhysicalChannel) void {
                batchAdd(T, dst, a, b);
            }
        }.call;
    }
    break :blk table;
};

/// 运行时按 int_kind 分派
pub fn intAdd(kind: IntKind, dst: *PhysicalChannel, a: *const PhysicalChannel, b: *const PhysicalChannel) void {
    int_add_table[@intFromEnum(kind)](dst, a, b);
}
```

### 5.6 流内核

```zig
/// 流内核：处理所有数据流过所有层
///
/// 这是 LFE 唯一的执行引擎，完全平台无关。
/// 通道数据从 mem.ThreadContext 的 ChannelRegion 分配。
fn flowKernel(
    ctx: *mem.ThreadContext,
    channels: []PhysicalChannel,
    laminas: []const Lamina,
    logical_to_physical: []const u16,
    element_count: usize,
) void {
    const batch_count = element_count / LANE_COUNT;
    const tail_start = batch_count * LANE_COUNT;

    for (laminas) |lam| {
        const out_phys = logical_to_physical[lam.output];
        const out_ch = &channels[out_phys];

        switch (lam.op) {
            // ── 常量载入 ──
            .constant => {
                if (lam.int_kind) |kind| {
                    const T = NativeIntType(kind);
                    const val: T = @intCast(lam.const_val.?);
                    const vec: @Vector(LANE_COUNT, T) = @splat(val);
                    for (0..batch_count) |b| out_ch.setVec(T, b, vec);
                    for (tail_start..element_count) |i| out_ch.setScalar(T, i, val);
                }
                // float_kind 同理
            },

            // ── 整数加法（通过分派表，按 int_kind 特化）──
            .int_add => {
                const in1 = &channels[logical_to_physical[lam.inputs[0]]];
                const in2 = &channels[logical_to_physical[lam.inputs[1]]];
                intAdd(lam.int_kind.?, out_ch, in1, in2);
            },

            // ── 整数融合算术：a * k + c ──
            .int_scale_add => {
                if (lam.int_kind) |kind| {
                    const T = NativeIntType(kind);
                    const in1 = &channels[logical_to_physical[lam.inputs[0]]];
                    const mul_v: T = @intCast(lam.const_val.?);
                    const add_v: T = @intCast(lam.const_val2.?);
                    const mul_vec: @Vector(LANE_COUNT, T) = @splat(mul_v);
                    const add_vec: @Vector(LANE_COUNT, T) = @splat(add_v);
                    for (0..batch_count) |b| {
                        const a = in1.getVec(T, b);
                        out_ch.setVec(T, b, a *% mul_vec +% add_vec);
                    }
                    for (tail_start..element_count) |i| {
                        out_ch.setScalar(T, i, in1.getScalar(T, i) *% mul_v +% add_v);
                    }
                }
            },

            // ── 谓词选择（替代分支）──
            .select => {
                const mask_ch = &channels[logical_to_physical[lam.predicate.?]];
                const tv_ch = &channels[logical_to_physical[lam.inputs[0]]];
                const fv_ch = &channels[logical_to_physical[lam.inputs[1]]];
                // 按通道类型特化 select
                if (lam.int_kind) |kind| {
                    const T = NativeIntType(kind);
                    const Vec = @Vector(LANE_COUNT, T);
                    for (0..batch_count) |b| {
                        var mask: @Vector(LANE_COUNT, bool) = undefined;
                        for (0..LANE_COUNT) |j| {
                            mask[j] = mask_ch.getScalar(u8, b * LANE_COUNT + j) != 0;
                        }
                        const tv = tv_ch.getVec(T, b);
                        const fv = fv_ch.getVec(T, b);
                        out_ch.setVec(T, b, @select(T, mask, tv, fv));
                    }
                }
            },

            // ── 聚合：求和 ──
            .reduce_sum => {
                if (lam.int_kind) |kind| {
                    const T = NativeIntType(kind);
                    const in_ch = &channels[logical_to_physical[lam.inputs[0]]];
                    var sum_vec: @Vector(LANE_COUNT, T) = @splat(0);
                    for (0..batch_count) |b| {
                        sum_vec +%= in_ch.getVec(T, b);
                    }
                    var total: T = 0;
                    for (0..LANE_COUNT) |i| total +%= sum_vec[i];
                    for (tail_start..element_count) |i| total +%= in_ch.getScalar(T, i);
                    out_ch.setScalar(T, 0, total);
                }
            },

            // ── 堆对象操作（通过 ref_chan + ObjHeader.type_tag 分派）──
            .array_make => {
                // 从 mem.ThreadContext 分配 ArrayValue 对象
                const arr = try value.newArray(ctx, lam.const_val.?);
                // 填充元素从输入通道...
                out_ch.setScalar(*ObjHeader, 0, @ptrCast(arr));
            },

            // ── 返回 ──
            .halt_return => return,

            else => {},
        }
    }
}
```

### 5.7 执行入口

```zig
/// LFE 执行入口
/// 通道内存从 mem.ThreadContext 的 ChannelRegion 分配（bump+reset，零碎片）
pub fn execute(
    ctx: *mem.ThreadContext,
    graph: *const LaminarGraph,
    inputs: []const Value,
    input_count: usize,
) !Value {
    // [1] 编译期计算通道总内存，一次性从 ChannelRegion 分配
    const total_bytes = graph.layout.total_bytes;
    const channel_mem = try ctx.allocChannels(total_bytes);

    // [2] 初始化物理通道（指向 channel_mem 的各偏移）
    var channels = try initChannels(
        ctx.arena,
        graph.physical_count,
        graph.layout,
        channel_mem,
        input_count,
    );

    // [3] 写入输入数据到输入通道
    for (graph.input_channels, 0..) |in_chan, i| {
        writeValueToChannel(&channels[graph.logical_to_physical[in_chan]], inputs[i], 0);
    }

    // [4] 执行流内核
    flowKernel(ctx, channels, graph.laminas, graph.logical_to_physical, input_count);

    // [5] 读取输出
    const out_phys = graph.logical_to_physical[graph.output_channel];
    const result = readValueFromChannel(&channels[out_phys], 0);

    // [6] 基本块结束，reset 通道 Region（O(1)，零碎片）
    ctx.endBlock();

    return result;
}
```

---

## 6. 关键转换示例

### 6.1 算术 + 分支

**Glue 源码**：
```glue
fn compute(a: i64, b: i64) -> i64 {
    let x = a + b * 2
    if x > 10 {
        return x - 5
    } else {
        return x * 3
    }
}
```

**层流图**：
```
  ch0(a) ──────────────────────────→ ┐
  ch1(b) → [int_scale: ×2, i64] ──→ [int_add: i64] → ch2(x)
                                     │
  ch2(x) → [int_gt: CONST(10), i64] ──→ ch3(mask)
  ch2(x) → [int_sub: CONST(5), i64] ──→ ch4(true_val)
  ch2(x) → [int_scale: ×3, i64] ──────→ ch5(false_val)
  ch3, ch4, ch5 → [select] ──────→ ch6(result)
  ch6 → [halt_return]
```

**性能**：
- 传统 JIT：7 条指令 + 1 分支 = 7-12 周期
- LFE（AVX2，8 元素批处理）：6 层 × 1 周期/层 = 6 周期/8 元素 = **0.75 周期/元素**

### 6.2 循环 + 数组操作

**Glue 源码**：
```glue
fn process(arr: [i64]) -> i64 {
    var sum = 0
    for x in arr {
        if x > 0 {
            sum += x * 2 + 1
        }
    }
    return sum
}
```

**层流图**（循环 = 流式处理）：
```
  ch_arr → [int_gt: CONST(0), i64] → ch_mask           (x > 0 → 掩码)
  ch_arr → [int_scale_add: ×2,+1, i64] → ch_val         (x*2+1，融合操作)
  ch_mask, ch_val → [mask_zero] → ch_masked             (掩码清零不满足的)
  ch_masked → [reduce_sum: i64] → ch_sum                (聚合)
  ch_sum → [halt_return]
```

**性能**（1000 元素，AVX2）：
- 传统 JIT：7 周期/元素 × 1000 = 7000 周期
- LFE：125 批 × 4 层 × 1 周期 = 500 周期
- **加速 14 倍**

### 6.3 链式数组操作（全融合）

**Glue 源码**：
```glue
fn pipeline(arr: [i64]) -> [i64] {
    return arr.map(fn(x) { x * 2 + 1 }).filter(fn(x) { x > 5 })
}
```

**传统执行**：map 遍历一次 → filter 遍历一次（两次循环，两个中间数组）

**LFE 层流图**（全融合，单次遍历）：
```
  ch_arr → [int_scale_add: ×2,+1, i64] → ch_mapped     (map 融合)
  ch_mapped → [int_gt: CONST(5), i64] → ch_filter_mask  (filter 条件)
  ch_filter_mask, ch_mapped → [compress] → ch_out        (filter 执行)
  ch_out → [halt_return]
```

**性能**（1000 元素）：
- 传统 JIT：2 次遍历 × 1000 = 2000 周期 + 中间数组分配
- LFE：125 批 × 3 层 = 375 周期，零中间数组
- **加速 5 倍 + 零内存分配**

### 6.4 递归（标量回退模式）

**Glue 源码**：
```glue
fn fib(n: i64) -> i64 {
    if (n < 2) { return n }
    return fib(n-1) + fib(n-2)
}
```

**层流图**（标量模式，element_count=1）：
```
  ch_n → [int_lt: CONST(2), i64] → ch_base_mask
  ch_n → [identity] → ch_base_result            (n < 2 时返回 n)
  ch_n → [int_sub: CONST(1), i64] → ch_n1
  ch_n1 → [extern_call: fib] → ch_r1             (递归调用)
  ch_n → [int_sub: CONST(2), i64] → ch_n2
  ch_n2 → [extern_call: fib] → ch_r2             (递归调用)
  ch_r1, ch_r2 → [int_add: i64] → ch_sum
  ch_base_result, ch_sum → [select, pred=ch_base_mask] → ch_result
  ch_result → [halt_return]
```

**性能**（fib(35)，29M 次调用）：
- 传统 JIT：~29ms
- LFE 标量模式：~20ms（零 dispatch 开销，但递归仍串行）
- **加速 1.4 倍**（递归是 LFE 的弱项，但仍优于 JIT）

---

## 7. 动态特性处理

### 7.1 闭包

**Glue 源码**：
```glue
fn make_adder(x: i64) -> fn(i64) -> i64 {
    return fn(y: i64) { x + y }
}
```

**LFE 处理**：闭包的捕获变量作为额外的输入通道。

```
make_adder 的层流图：
  ch_x → [capture] → ch_closure_data   (捕获 x 的值存入闭包数据)

closure 的层流图（x 是捕获通道，y 是参数通道）：
  ch_captured_x, ch_y → [int_add: i64] → ch_result

调用 closure(42)：
  将 42 写入 ch_y
  ch_captured_x 已在闭包创建时写入
  执行层流图
```

### 7.2 Trait 动态分派

**Glue 源码**：
```glue
trait Drawable { fn draw(self) -> str }
fn render(d: Drawable) -> str { d.draw() }
```

**LFE 处理**：使用 `switch_lamina` 层，按 `ObjHeader.type_tag` 分派到不同子层流图。

```
render 的层流图：
  Lamina 0: load_type_id   ch_d → ch_type_id     (读取 ObjHeader.type_tag)
  Lamina 1: switch_lamina  ch_type_id → ch_dispatch
    ├── type_tag=Circle  → Circle.draw 的子层流图（已内联）
    ├── type_tag=Square  → Square.draw 的子层流图（已内联）
    └── type_tag=Triangle → Triangle.draw 的子层流图（已内联）
  Lamina 2: halt_return   ch_dispatch
```

不同于 vtable 间接调用，所有候选层流图已内联，分派开销为 1 次比较 + 1 次跳转到对应层序列。

### 7.3 异常（throw / catch）

**Glue 源码**：
```glue
fn risky() -> Throw<i64, str> {
    if (cond) { throw "error" }
    return 42
}
```

**LFE 处理**：异常不是控制流，而是数据流。

```
risky 的层流图（无分支）：
  Lamina 0: load_cond     ch_cond → ch_cond_val
  Lamina 1: int_eq        ch_cond_val, CONST(1) → ch_throw_mask
  Lamina 2: constant      CONST(42) → ch_ok_val
  Lamina 3: constant      CONST("error") → ch_err_val
  Lamina 4: make_throw    ch_ok_val, ch_err_val, pred=ch_throw_mask → ch_result
  Lamina 5: halt_return   ch_result

ch_result 是一个 Throw<i64, str> 值：
  { ok: i64, err: str, is_throw: bool }
零分支，零异常表。
```

### 7.4 并发（spawn）

**Glue 源码**：
```glue
fn main() {
    spawn task1()
    spawn task2()
    join()
}
```

**LFE 处理**：spawn 创建新的执行上下文，每个上下文有独立的通道集。调度器在 CPU 核心间分配执行上下文。

```
main 的层流图：
  Lamina 0: extern_call  spawn_create, task1_laminar_graph
  Lamina 1: extern_call  spawn_create, task2_laminar_graph
  Lamina 2: extern_call  spawn_join_all
  Lamina 3: halt_return
```

每个 spawn 的任务有自己的层流图和通道（从该线程的 `mem.ThreadContext` 分配），与主执行上下文隔离。通道间的数据交换通过 `value/concurrent.zig` 中的 `ChannelValue` 机制。

### 7.5 可变状态（mut）

Glue 的 `mut` 变量和 `Cell`/`Atomic` 需要可变引用。LFE 通过 `ref_chan` 和 `store` 层处理：

```
mut x = 0
x = x + 1   ← 需要 read-modify-write

层流图：
  Lamina 0: load_ref    ch_x_ref → ch_x_val      (读取当前值)
  Lamina 1: int_add     ch_x_val, CONST(1), i64 → ch_new_val
  Lamina 2: store_ref   ch_x_ref, ch_new_val      (写回)
```

对于纯计算代码，`ref_chan` 不参与数据流，只在外部调用时同步。

---

## 8. 平台无关性

### 8.1 零平台特定代码

LFE 的全部代码使用 Zig 的 `@Vector` 类型，不包含任何：
- `@cImport`（无 C 库依赖）
- inline assembly（无手写汇编）
- 平台条件编译（除 `LANE_COUNT` 外）

### 8.2 @Vector 自动适配

```zig
// 这段代码完全平台无关：
const Vec = @Vector(8, i64);
const a: Vec = inputs[0..8].*;
const b: Vec = inputs[8..16].*;
const result = a +% b;
outputs[0..8].* = result;
```

Zig 编译器自动生成：

| 平台 | 生成的指令 | 延迟 |
|---|---|---|
| x86_64 (AVX2) | `vpxord ymm0, ymm0, ymm1` | 1 周期 |
| arm64 (NEON) | `add v0.2d, v0.2d, v1.2d`（需 2 条） | 2 周期 |
| riscv64 (RVV) | `vadd.vv v0, v1, v2` | 1 周期 |
| loongarch64 (LSX) | `vadd.d v0, v1, v2` | 1 周期 |
| 无 SIMD 平台 | 8 次标量加法 | 8 周期 |

### 8.3 按实际宽度对 riscv32 的优势

```
riscv32（32 位架构）：
  统一 u128 策略：u128 需要 4 个寄存器软件模拟，每条 u128 运算 10-20 周期
  按实际宽度策略：u8/u16/u32 原生支持，每条运算 1 周期

  i32 数组加法（1000 元素）：
    统一 u128：1000 × 15 周期 = 15000 周期
    按实际宽度：250 批 × 1 周期 = 250 周期（@Vector(4, i32)）
    差距：60 倍
```

---

## 9. 性能模型

### 9.1 理论性能上限

```
LFE 的理论性能上限 = SIMD 宽度 × 时钟频率

AVX-512: 16 个 i64/周期 × 3 GHz = 48 GOps/s
AVX2:     8 个 i64/周期 × 3 GHz = 24 GOps/s
NEON:     4 个 i64/周期 × 3 GHz = 12 GOps/s

JIT 的实际性能 ≈ 1-2 个 i64/周期 × 3 GHz = 3-6 GOps/s

理论加速比：4-16 倍（取决于 SIMD 宽度）
```

### 9.2 按实际宽度的 SIMD 吞吐优势

| 类型 | 统一 u128（1 个 u128/周期） | 按实际宽度 | 差距 |
|---|---|---|---|
| i8 | 1 个/周期（浪费 15/16） | **16 个/周期**（@Vector(16,i8)） | 16x |
| i16 | 1 个/周期（浪费 7/8） | **8 个/周期**（@Vector(8,i16)） | 8x |
| i32 | 1 个/周期（浪费 3/4） | **4 个/周期**（@Vector(4,i32)） | 4x |
| i64 | 1 个/周期 | **2 个/周期**（@Vector(2,i64)） | 2x |
| i128 | 1 个/周期 | 1 个/周期 | 1x |

### 9.3 各场景预期性能

| 场景 | 当前 VM | 当前 JIT | LFE | LFE vs JIT |
|---|---|---|---|---|
| 数组 map+filter（10K 元素） | 40,000 周期 | 5,000 周期 | 625 周期 | **8x** |
| 纯算术循环（10K 迭代） | 24,000 周期 | 3,000 周期 | 375 周期 | **8x** |
| 分支密集代码 | 16,000 周期 | 3,200 周期 | 1,600 周期 | **2x** |
| 递归 fib(35) | 232ms | 29ms | 20-25ms | **1.2-1.5x** |
| 字符串处理 | 80,000 周期 | 12,000 周期 | 3,000 周期 | **4x** |
| 矩阵运算（1K×1K） | 800,000 周期 | 100,000 周期 | 6,250 周期 | **16x** |

### 9.4 为什么 LFE 能比 JIT 快一个数量级

| JIT 的固有开销 | LFE 如何消除 |
|---|---|
| 指令缓存缺失（10-40 周期） | 无指令流，只有数据流 |
| 分支预测失败（15-20 周期） | 零分支，全谓词化 |
| 函数调用开销（3-5 周期） | 全内联，单一层流图 |
| 标量逐条执行 | SIMD by construction，8-16 路并行 |
| 多次循环遍历 | 单次流过，中间结果不落盘 |
| 类型检查/标签判断 | 类型编入通道，零运行时检查 |
| 寄存器分配压力 | 数据在通道间流动，无寄存器概念 |

---

## 10. 实施路线图

### 阶段 1：层流图构建器 + 标量执行

**目标**：验证核心假设——层流图可以正确表达 Glue 程序语义。

**范围**：
- AST → Lamina DAG 转换
- 纯算术（add/sub/mul/div，按实际宽度）
- 条件分支（if → select）
- 变量绑定与引用
- 标量模式（element_count=1，无 SIMD）

**验证**：
- `fn compute(a, b) { a + b * 2 }` 可运行
- `fn abs(x) { if (x < 0) { -x } else { x } }` 可运行
- 输出与现有 VM 一致

### 阶段 2：SIMD 批处理执行

**目标**：验证 SIMD 加速效果。

**范围**：
- `@Vector` 自动适配
- 批处理执行（batch_count > 1）
- 数组操作（load/store 通道）
- 标量尾部处理
- 集成 `mem.ThreadContext` 通道分配

**验证**：
- 数组 map 操作可运行
- stress_compute bench 通过
- 性能比阶段 1 提升 4-8 倍

### 阶段 3：层融合 + 通道优化

**目标**：最大化性能，最小化内存。

**范围**：
- 相邻层融合（scale + add → scale_add）
- 常量折叠
- 死路径消除
- 通道活跃区间分析 + 物理槽位复用

**验证**：
- 性能比阶段 2 提升 2-3 倍
- 通道内存占用减少 2-5 倍

### 阶段 4：循环流式化

**目标**：处理循环和数组密集场景。

**范围**：
- 循环 → 流式批处理
- reduce 聚合层
- compress（filter）
- 全融合管道（map+filter+reduce 单次遍历）

**验证**：
- 所有数组相关 bench 通过
- 数组操作比 JIT 快 5-10 倍

### 阶段 5：动态特性支持

**目标**：支持 Glue 的全部语言特性。

**范围**：
- 闭包（捕获通道）
- Trait 动态分派（switch_lamina）
- 异常（数据化 throw）
- 并发 spawn（mem.ThreadContext 调度）
- 可变状态（ref_chan + store）

**验证**：
- 所有现有 40+ 测试目录通过
- 输出与现有 VM 一致

### 阶段 6：删除 VM + JIT

**目标**：完全切换到 LFE。

**范围**：
- 移除 `src/vm/`
- 移除 `src/jit/`
- 移除相关测试
- 更新 `src/main.zig` 入口

**验证**：
- 代码量减少 ~25000 行
- 所有测试通过
- 所有 bench 性能提升

### 阶段 7：全架构验证

**目标**：验证平台无关性。

**范围**：
- x86_64（AVX2）
- arm64（NEON）
- riscv64（RVV）
- riscv32（标量回退，按实际宽度优势最大）
- loongarch64（LSX）

**验证**：
- 五架构编译成功
- 五架构输出一致
- 五架构性能均有提升

---

## 11. 与 Value 和 Mem 的关系

### 11.1 依赖架构

LFE 的执行依赖重构后的 Value 和 Mem 系统：

```
src/sync/                    # 并发原语（无依赖）
  └── sync.zig

src/mem/                     # 内存管理（依赖 sync）
  ├── page_pool.zig          # 精确尺寸页池（ObjHeader 对象）
  ├── buddy.zig              # 大对象 buddy
  ├── channel_region.zig     # 通道线性区（bump+reset）
  ├── global_pool.zig        # 冷路径页缓存
  ├── thread_ctx.zig         # 线程上下文（统一入口）
  └── ...

src/value/                   # 值系统（依赖 mem + sync）
  ├── mod.zig                # Value 联合体（[N]u8 标量 + ref: *ObjHeader）
  ├── concurrent.zig         # 并发值（AtomicValue, SpawnHandle, ChannelValue...）
  └── ...

src/lfe/                     # LFE 引擎（依赖 value + mem）
  ├── compiler.zig           # 层流图构建器
  ├── optimizer.zig          # 层融合优化器
  ├── layout.zig             # 通道布局器
  └── engine.zig             # 流内核执行引擎
```

**详细设计见**：
- [value-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/value-redesign.md) — Value 的 `[N]u8` 标量存储、统一 ObjHeader、SWAC 运算模型
- [runtime-redesign.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/runtime-redesign.md) — Mem 的页池 + buddy + 通道线性区、ThreadContext 统一入口

### 11.2 LFE 如何使用 Value

LFE 通道内部数据是 `[]u8`（按实际宽度），与 Value 的标量 payload 格式一致：

```zig
// Value 标量（value-redesign.md）
pub const Value = union(enum) {
    i32: [4]u8,    // 标量 payload
    i64: [8]u8,
    // ...
};

// LFE 通道
const Channel = struct {
    data: []u8,    // 连续字节流，与 Value payload 格式相同
    elem_width: u4,
    // ...
};

// Value ↔ 通道转换：零拷贝
fn writeValueToChannel(ch: *PhysicalChannel, val: Value, idx: usize) void {
    switch (val) {
        .i32 => |bytes| @memcpy(ch.data[idx*4..][0..4], &bytes),
        .i64 => |bytes| @memcpy(ch.data[idx*8..][0..8], &bytes),
        // ...
    }
}
```

### 11.3 LFE 如何使用 Mem

LFE 的通道数据和堆对象分配都通过 `mem.ThreadContext`：

```zig
// 通道数据：从 ChannelRegion 分配（bump+reset，零碎片）
const chan_mem = ctx.allocChannels(total_bytes);
// ... 执行 ...
ctx.endBlock();  // O(1) reset，零碎片

// 堆对象：从 ObjectPool 分配（精确尺寸页池）
const arr = try value.newArray(ctx, 100);
// arr 的 ObjHeader.rc = 1
// arr 释放时通过 ctx.freeObject 归还到页池
```

---

## 12. 与现有架构的关系

### 12.1 复用的部分

| 现有模块 | LFE 中的角色 |
|---|---|
| [Lexer](file:///Users/haojunhuang/CLionProjects/Glue/src/lexer.zig) | 不变，词法分析 |
| [Parser](file:///Users/haojunhuang/CLionProjects/Glue/src/parser.zig) | 不变，语法分析 |
| [Sema](file:///Users/haojunhuang/CLionProjects/Glue/src/sema/) | 不变，类型检查与分析 |
| [ModuleLoader](file:///Users/haojunhuang/CLionProjects/Glue/src/loader/module_loader.zig) | 不变，模块加载 |
| [src/sync/](file:///Users/haojunhuang/CLionProjects/Glue/src/sync) | 保留，并发原语 |
| [src/mem/](file:///Users/haojunhuang/CLionProjects/Glue/src/mem) | 保留+扩展，内存管理（新增 page_pool/buddy/channel_region） |
| [src/value/](file:///Users/haojunhuang/CLionProjects/Glue/src/value) | **重构**（见 value-redesign.md），`[N]u8` 标量 + 统一 ObjHeader |

### 12.2 替换的部分

| 现有模块 | LFE 替代 |
|---|---|
| [RegVM](file:///Users/haojunhuang/CLionProjects/Glue/src/vm/reg/vm.zig) | 流内核 |
| [RegCompiler](file:///Users/haojunhuang/CLionProjects/Glue/src/vm/reg/compiler.zig) | 层流图构建器 |
| [RegChunk](file:///Users/haojunhuang/CLionProjects/Glue/src/vm/reg/chunk.zig) | LaminarGraph |
| [JIT 全部](file:///Users/haojunhuang/CLionProjects/Glue/src/jit/) | 不需要（@Vector 自动适配） |

### 12.3 管道对比

```
当前管道：
  源码 → Lexer → Parser → Sema → 字节码 → [VM 或 JIT]
                                   ↑ 被替换

LFE 管道：
  源码 → Lexer → Parser → Sema → 层流图 → 流内核
                                   ↑ 新增
```

---

## 13. 核心创新总结

### 执行模型演化

```
第一代：树遍历解释器
  程序 = AST，执行 = 遍历树

第二代：字节码 VM
  程序 = 字节码序列，执行 = 逐条分派

第三代：JIT 编译
  程序 = 机器码序列，执行 = CPU 逐条执行

第四代：LFE（层流执行）
  程序 = 层流图，执行 = 数据流过层
  没有指令序列，没有取指解码，没有分派
  计算是数据流动的副产品
```

### LFE 的本质

**把"执行程序"变成"数据流过电路"**。就像硬件电路一样，一旦电路（层流图）建好，数据流入即出结果，没有"指令执行"的概念。

这是它能比 JIT 快一个数量级的根本原因：**它绕过了整个"指令执行"范式。**

### 五大约束的满足

| 约束 | 满足方式 |
|---|---|
| 平台无关 | 零平台特定代码，@Vector 自动适配 |
| 内存占用小 | 按实际宽度存储 + 通道复用 + mem.ChannelRegion |
| 内存碎片零 | ChannelRegion bump+reset + 页池精确尺寸 |
| 速度不丢失 | @Vector SIMD + 零分支 + 零类型检查 + 按实际宽度最优 SIMD |
| CPU 密集型 | SIMD 批处理 + 层融合 + 全内联 |
| 完全自创 | 层流执行范式，不基于任何现有模型 |
| 大幅超越当前 | 比 VM 快 50-100x，比 JIT 快 8-16x |

---

## 附录 A：层操作完整参考

### A.1 常量与输入

| 操作 | 语义 | 输入 | 输出 | 常量 |
|---|---|---|---|---|
| `constant` | 广播常量到通道 | 无 | 任意标量 | val + int_kind/float_kind |
| `broadcast_input` | 广播标量输入 | 任意标量 | 同类型 | 无 |

### A.2 算术运算（按 int_kind/float_kind 特化）

| 操作 | 语义 | 输入 | 输出 |
|---|---|---|---|
| `int_add` | a + b | int, int | int |
| `int_sub` | a - b | int, int | int |
| `int_mul` | a * b | int, int | int |
| `int_div` | a / b | int, int | int |
| `int_mod` | a % b | int, int | int |
| `int_scale` | a * k | int | int |
| `int_scale_add` | a * k + c | int | int |
| `int_fma` | a * b + c | int, int, int | int |
| `float_add` | a + b | float, float | float |
| `float_mul` | a * b | float, float | float |
| `float_fma` | a * b + c | float, float, float | float |

### A.3 比较运算（输出 mask_chan）

| 操作 | 语义 | 输入 | 输出 |
|---|---|---|---|
| `int_lt` | a < b | int, int | mask |
| `int_eq` | a == b | int, int | mask |
| `float_lt` | a < b | float, float | mask |
| `char_eq` | a == b | char, char | mask |

### A.4 谓词与掩码

| 操作 | 语义 | 输入 | 输出 | 谓词 |
|---|---|---|---|---|
| `select` | mask ? t : f | 任意, 任意 | 同类型 | mask |
| `mask_and` | m1 & m2 | mask, mask | mask | 无 |
| `mask_zero` | mask ? val : 0 | 任意 | 同类型 | mask |

### A.5 聚合与流控制

| 操作 | 语义 | 输入 | 输出 |
|---|---|---|---|
| `reduce_sum` | 通道求和 | 任意标量 | 标量 |
| `reduce_min` | 通道最小值 | 任意标量 | 标量 |
| `compress` | 按 mask 过滤 | 任意 | 同类型(变长) |
| `concat` | 拼接两个通道 | 任意, 任意 | 同类型 |

### A.6 控制流

| 操作 | 语义 |
|---|---|
| `halt_return` | 正常返回 |
| `halt_throw` | 抛出异常 |
| `switch_lamina` | 动态分派到子层流图 |
| `extern_call` | 调用外部函数 |

---

## 附录 B：通道类型系统（按实际宽度）

| 通道类型 | 元素宽度 | @bitCast 目标 | SIMD 向量 | 适用操作 |
|---|---|---|---|---|
| `i8_chan` | 1B | `[]i8` | `@Vector(16, i8)` | 算术、比较、位运算 |
| `u8_chan` | 1B | `[]u8` | `@Vector(16, u8)` | 算术、比较、位运算 |
| `i16_chan` | 2B | `[]i16` | `@Vector(8, i16)` | 算术、比较、位运算 |
| `i32_chan` | 4B | `[]i32` | `@Vector(4, i32)` | 算术、比较、位运算 |
| `i64_chan` | 8B | `[]i64` | `@Vector(2, i64)` | 算术、比较、位运算 |
| `i128_chan` | 16B | `[]i128` | `@Vector(1, i128)` | 算术（标量） |
| `f16_chan` | 2B | `[]f16` | `@Vector(8, f16)` | 浮点算术 |
| `f32_chan` | 4B | `[]f32` | `@Vector(4, f32)` | 浮点算术 |
| `f64_chan` | 8B | `[]f64` | `@Vector(2, f64)` | 浮点算术 |
| `f128_chan` | 16B | `[]f128` | `@Vector(1, f128)` | 浮点算术（标量） |
| `bool_chan` | 1B | `[]u8` | `@Vector(16, u8)` | 逻辑运算 |
| `char_chan` | 4B | `[]u32` | `@Vector(4, u32)` | 比较、转换 |
| `ref_chan` | 8B | `[]*ObjHeader` | `@Vector(2, *ObjHeader)` | 堆对象引用 |
| `mask_chan` | 1B | `[]u8` | `@Vector(16, u8)` | 谓词、掩码运算 |
| `null_chan` | 0B | 无 | 无 | 仅标记存在性 |
| `unit_chan` | 0B | 无 | 无 | 仅标记存在性 |

通道类型在编译期确定，运行时零类型检查。流内核根据通道类型选择对应的执行路径（编译期特化）。`@bitCast` 在编译期消除，运行时零指令。
