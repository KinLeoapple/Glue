# Value 重建设计文档

> **状态**：设计阶段
> **目标**：重建 Value 系统，实现内存连续、占用极小、运算极快
> **约束**：自实现类型、无外部依赖、跨 5 架构兼容、适应 LFE

---

## 1. 当前 Value 系统的问题

### 1.1 Value 联合体过大

当前 `Value` 联合体 32 字节，最大载荷是 `Int`/`Float`（各 24B，含 `type` 字段 + 7B padding）。

一个 `i8` 值在 `Value` 中占 32B，实际有效数据 1B，**浪费 96.9%**。

### 1.2 标量不连续

`Int` 结构体 `{type: Type, lo: u64, hi: u64}` 中 `type` 字段打断数据连续性。`[]Int` 数组无法直接作为 `[]u128` 供 SIMD 加载。

### 1.3 三套引用计数

| 机制 | 适用 | 字段 | 类型 |
|---|---|---|---|
| 非原子 `rc: u32` | 16 种堆对象 | `rc` | u32 |
| SSO 位域 `rc: u32` | Str | `rc`（复用） | u32 |
| 原子 `ref_count` | AtomicValue, ChannelValue | `ref_count` | usize |
| 无 RC | SpawnHandle | — | — |

### 1.4 无统一对象头

堆对象第一个字段五花八门（`rc`/`data`/`buffer`/`status`/`_word0`），无法统一识别类型或管理生命周期。

### 1.5 标量类型信息冗余

`Int.type` 和 `Float.type` 字段每个值都携带类型信息，但同一运算中操作数类型必然相同。24B 中 8B（type + padding）纯浪费。

---

## 2. 设计目标

| 目标 | 指标 |
|---|---|
| Value 大小 | 24B（从 32B 降低 25%） |
| 标量大小 | 按实际宽度（i8 = 1B，i64 = 8B） |
| 标量连续性 | `[]u8` 可直接 SIMD 加载 |
| RC 机制 | 统一一套 |
| 堆对象类型识别 | 统一 ObjHeader.type_tag |
| 跨架构一致性 | extern struct 保证 |
| 运算速度 | @bitCast 零成本 + 原生指令 |

---

## 3. 类型系统

### 3.1 Glue 完整类型清单

f8 已删除。当前共 27 个 Value 变体：

| 类别 | 类型 | 数量 |
|---|---|---|
| 特殊值 | null_val, unit | 2 |
| 布尔 | boolean | 1 |
| 字符 | char (u32) | 1 |
| 整数 | i8/i16/i32/i64/i128, u8/u16/u32/u64/u128 | 10 |
| 浮点 | f16/f32/f64/f128 | 4 |
| 字符串 | string (Str, SSO) | 1 |
| 复合 | array, record, adt, newtype, cell, range | 6 |
| 可调用 | vm_closure, partial, builtin, trait_value | 4 |
| 控制流 | error_val, throw_val | 2 |
| 迭代器 | array_iterator, string_iterator, range_iterator | 3 |
| 并发 | atomic_val, spawn_val, channel_val, sender_val, receiver_val | 5 |
| 惰性 | lazy_val | 1 |

### 3.2 Zig 原生类型映射

所有数值类型都有 Zig 原生对应，`@bitCast` 零成本：

| Glue 类型 | 字节宽度 | Zig 原生类型 | @bitCast | 硬件运算 |
|---|---|---|---|---|
| boolean | 1 | bool | ✅ | ✅ |
| char | 4 | u32 | ✅ | ✅ |
| i8-u128 | 1-16 | i8/u8/.../i128/u128 | ✅ | ✅ |
| f16 | 2 | f16 | ✅ | 编译器自动选硬件/软件 |
| f32 | 4 | f32 | ✅ | ✅ 全平台 |
| f64 | 8 | f64 | ✅ | ✅ 全平台 |
| f128 | 16 | f128 | ✅ | 部分平台软件模拟 |

**关键**：无 f8，无例外，所有数值类型都有原生 `@bitCast` 路径。

---

## 4. Value 联合体设计

### 4.1 存储策略：按实际宽度 u8 数组

标量以 `[N]u8` 存储，按类型实际宽度：

```zig
pub const Value = union(enum) {
    // ── 零字节特殊值 ──
    null_val,
    unit,

    // ── 标量：按实际宽度的 u8 数组 ──
    boolean: [1]u8,
    char: [4]u8,

    i8: [1]u8,   u8: [1]u8,
    i16: [2]u8,  u16: [2]u8,
    i32: [4]u8,  u32: [4]u8,
    i64: [8]u8,  u64: [8]u8,
    i128: [16]u8, u128: [16]u8,

    f16: [2]u8,
    f32: [4]u8,
    f64: [8]u8,
    f128: [16]u8,

    // ── 堆引用：统一指针 ──
    ref: *ObjHeader,
};
// @sizeOf(Value) = 24B（16B 最大 payload + 8B tag 对齐）
```

### 4.2 为什么用 `[N]u8` 而非原生类型

1. **内存连续**：`[N]u8` 的对齐是 1，无 padding。通道中 `[]u8` 可直接 `@ptrCast` 为 `[]i32` 等
2. **跨平台一致**：u8 永远 1 字节，所有架构布局相同。`extern struct` 进一步保证
3. **序列化零拷贝**：存储就是字节，无需转换
4. **@bitCast 零成本**：运算时 `@bitCast` 为原生类型，编译期消除，运行时零指令

### 4.3 堆引用统一

22 种堆对象统一为 `ref: *ObjHeader`，通过 `ObjHeader.type_tag` 区分类型。不再有 22 个独立指针变体。

### 4.4 Value 大小分析

```
最大 payload：i128/u128/f128 = [16]u8 = 16B
tag：1B（27 个变体，u8 足够）
对齐：16B payload 需 16B 对齐，tag 8B 对齐
@sizeOf(Value) = 24B

对比当前：
  当前 32B → 新 24B，省 25%
  当前 Int 24B（含 type+padding）→ 新 i32 [4]u8，省 83%
```

---

## 5. ObjHeader 统一对象头

### 5.1 设计

```zig
/// 堆对象类型标签
pub const RefKind = enum(u8) {
    // 复合
    str, array, record, adt, newtype, cell, range,
    // 可调用
    vm_closure, partial, builtin, trait_val, lazy_val,
    // 控制流
    error_val, throw_val,
    // 迭代器
    array_iter, string_iter, range_iter,
    // 并发
    atomic_val, spawn_val, channel_val, sender_val, receiver_val,
};

/// 所有堆对象的统一头部
pub const ObjHeader = extern struct {
    type_tag: RefKind,   // 1B，类型识别
    rc: u32,             // 4B，统一引用计数（初始 1）
    // 3B 隐式 padding 对齐到 8B
};
```

### 5.2 所有堆对象以 ObjHeader 开头

```zig
pub const ArrayValue = extern struct {
    header: ObjHeader,
    elements: [*]Value,
    len: usize,
    capacity: usize,
    fixed_size: ?u64,
};

pub const AdtValue = extern struct {
    header: ObjHeader,
    type_name: []const u8,
    constructor: []const u8,
    fields: [*]AdtField,
    field_count: usize,
};

// ... 其余堆对象同理
```

### 5.3 Str SSO 特殊处理

Str 保留 SSO 优化。SSO 模式下字符串内联在 Value 中（通过 `ref` 指向栈上 Str），堆模式走 ObjHeader：

```zig
pub const Str = extern struct {
    header: ObjHeader,   // type_tag = .str
    // SSO 数据 / 堆指针 + 长度
    _word0: u64,
    _word1: u64,
    _word2: u32,
    sso_flags: u32,      // SSO 模式：标志+长度+RC 位域
};
```

### 5.4 统一 RC 接口

```zig
/// 统一 retain：所有堆对象一个函数
pub fn retain(obj: *ObjHeader) *ObjHeader {
    obj.rc += 1;
    return obj;
}

/// 统一 release：通过 type_tag 分派 deinit
pub fn release(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    if (obj.rc > 1) {
        obj.rc -= 1;
        return;
    }
    deinit_table[@intFromEnum(obj.type_tag)](obj, allocator);
}
```

**消除**：
- 三套 RC 机制 → 一套 `ObjHeader.rc`
- `runtime_bridge.zig` → 已删除
- mod.zig 中 200+ 行的 retain/release switch → 分派表

---

## 6. 泛型运算系统

### 6.1 标量类型标签

```zig
/// 所有可字节编码的数值类型
pub const ScalarTag = enum(u8) {
    boolean, char,
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f128,
};
// 共 16 种（无 f8）
```

### 6.2 编译期类型映射

```zig
/// tag → Zig 原生类型
fn NativeType(comptime tag: ScalarTag) type {
    return switch (tag) {
        .boolean => bool,
        .char => u32,
        .i8 => i8, .i16 => i16, .i32 => i32, .i64 => i64, .i128 => i128,
        .u8 => u8, .u16 => u16, .u32 => u32, .u64 => u64, .u128 => u128,
        .f16 => f16, .f32 => f32, .f64 => f64, .f128 => f128,
    };
}

/// tag → 字节宽度
fn byteWidth(comptime tag: ScalarTag) usize {
    return @sizeOf(NativeType(tag));
}
```

### 6.3 泛型运算函数

一个函数定义，编译期自动生成 16 个特化版本：

```zig
/// 泛型加法：覆盖所有数值类型
pub fn add(comptime tag: ScalarTag, a: Value, b: Value) Value {
    const T = NativeType(tag);
    const w = byteWidth(tag);

    // @bitCast 从 [N]u8 提取原生值（编译期消除，零指令）
    const av: T = @bitCast(a.payload[0..w].*);
    const bv: T = @bitCast(b.payload[0..w].*);

    // 原生运算（1 条指令）
    const result = switch (@typeInfo(T)) {
        .int => av +% bv,           // 整数：无分支溢出加法
        .float => av + bv,          // 浮点：IEEE 754 加法
        .bool => av or bv,          // 布尔或
        else => @compileError("unsupported"),
    };

    // @bitCast 写回 [N]u8（编译期消除，零指令）
    return packValue(tag, @bitCast(result));
}
```

### 6.4 运行时分派表

```zig
const ArithFn = *const fn (Value, Value) Value;

/// comptime 生成 16 种类型的加法特化分派表
const add_table = blk: {
    const tags = [_]ScalarTag{
        .boolean, .char,
        .i8, .i16, .i32, .i64, .i128,
        .u8, .u16, .u32, .u64, .u128,
        .f16, .f32, .f64, .f128,
    };
    var table: [tags.len]ArithFn = undefined;
    inline for (tags, 0..) |tag, i| {
        table[i] = struct {
            fn call(a: Value, b: Value) Value {
                return add(tag, a, b);
            }
        }.call;
    }
    break :blk table;
};

/// 运行时分派：1 次表查找 + 1 次间接调用
pub fn addValues(a: Value, b: Value) ?Value {
    if (@intFromEnum(a) != @intFromEnum(b)) return null;
    const idx = @intFromEnum(a);
    if (idx >= add_table.len) return null;
    return add_table[idx](a, b);
}
```

### 6.5 生成的代码质量

```asm
; add_table[.i32] 特化后的实际汇编
mov eax, [rdi]       ; 取前 4 字节
add eax, [rsi]       ; 1 条原生加法
mov [rdx], eax       ; 写回前 4 字节
ret
; 共 3 条指令，和手写 i32 加法完全相同

; add_table[.f64] 特化
movsd xmm0, [rdi]    ; 取 8 字节
addsd xmm0, [rsi]    ; 1 条 SSE 加法
movsd [rdx], xmm0    ; 写回
ret
```

### 6.6 批量 SIMD 运算

```zig
/// SIMD 批量加法：自动按类型宽度选择最优向量宽度
pub fn batchAdd(comptime T: type, dst: []T, a: []const T, b: []const T) void {
    const lanes = 128 / @bitSizeOf(T);  // i8→16, i32→4, i64→2
    const Vec = @Vector(lanes, T);

    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        dst[i..][0..lanes].* = @as([lanes]T,
            @as(Vec, a[i..][0..lanes].*) +% @as(Vec, b[i..][0..lanes].*)
        );
    }
    while (i < a.len) : (i += 1) dst[i] = a[i] +% b[i];
}
```

| 类型 | SIMD 宽度 | 一次处理元素数 | 对比当前提升 |
|---|---|---|---|
| i8/u8 | @Vector(16, i8) | 16 | 79x |
| i16/u16 | @Vector(8, i16) | 8 | 40x |
| i32/u32 | @Vector(4, i32) | 4 | 20x |
| i64/u64 | @Vector(2, i64) | 2 | 10x |
| f32 | @Vector(4, f32) | 4 | 20x |
| f64 | @Vector(2, f64) | 2 | 10x |

---

## 7. LFE 通道与 Value 的关系

### 7.1 通道：纯数据，无 tag

LFE 通道是连续的原始字节数组，不包含 Value tag：

```zig
const Channel = struct {
    data: []u8,        // 连续字节流，16B 对齐
    element_width: u3, // 每元素字节数（1/2/4/8/16）
    count: usize,
};
```

### 7.2 通道与 Value 的转换

```zig
/// Value → 通道元素（零拷贝：直接取 payload）
fn channelPush(chan: *Channel, v: Value) void {
    const w = elementWidth(v);
    chan.data[chan.count * w ..][0..w].* = v.payload[0..w].*;
    chan.count += 1;
}

/// 通道元素 → Value（零拷贝：填充 payload + 设置 tag）
fn channelGet(chan: *Channel, i: usize) Value {
    const w = chan.element_width;
    var v: Value = .{ .tag = chan.element_tag };
    v.payload[0..w].* = chan.data[i * w ..][0..w].*;
    return v;
}
```

### 7.3 通道 SIMD 加载

通道 `[]u8` 可直接 `@ptrCast` 为原生类型数组并 SIMD 加载：

```zig
fn chanAddI32(dst: *Channel, a: *Channel, b: *Channel) void {
    const va: [*]i32 = @ptrCast(@alignCast(a.data.ptr));
    const vb: [*]i32 = @ptrCast(@alignCast(b.data.ptr));
    const vr: [*]i32 = @ptrCast(@alignCast(dst.data.ptr));

    const Vec4 = @Vector(4, i32);
    var i: usize = 0;
    while (i + 4 <= a.count) : (i += 4) {
        vr[i..][0..4].* = @as([4]i32,
            @as(Vec4, va[i..][0..4].*) +% @as(Vec4, vb[i..][0..4].*)
        );
    }
    while (i < a.count) : (i += 1) vr[i] = va[i] +% vb[i];
}
```

---

## 8. 内存对比

### 8.1 单值

| 类型 | 当前 Value | 新 Value | 节省 |
|---|---|---|---|
| i8 | 32B (Int 24B + tag) | 2B (1B payload + 1B tag) | 94% |
| i32 | 32B | 5B (4B + 1B) | 84% |
| i64 | 32B | 9B (8B + 1B) | 72% |
| i128 | 32B | 17B (16B + 1B) | 47% |
| f64 | 32B | 9B | 72% |
| bool | 32B | 2B | 94% |

### 8.2 数组（1000 元素）

| 类型 | 当前 []Value | 新 []u8 通道 | 节省 |
|---|---|---|---|
| i8 | 32000B | 1000B | 97% |
| i32 | 32000B | 4000B | 88% |
| i64 | 32000B | 8000B | 75% |
| f64 | 32000B | 8000B | 75% |

### 8.3 堆对象

| 对象 | 当前大小 | 新大小（含 ObjHeader） | 变化 |
|---|---|---|---|
| ArrayValue | 48B (rc 4B + ...) | 48B (header 8B + ...) | 持平 |
| AdtValue | 56B | 56B | 持平 |
| Str | 24B | 32B (header 8B + SSO 24B) | +8B（统一头代价） |

---

## 9. 运算速度对比

### 9.1 单值运算

| 运算 | 当前（Int.add） | 新（add(i32,...)） | 提升 |
|---|---|---|---|
| 周期数 | 5-7 | 1 | 5-7x |
| 内存读取 | 48B | 8B | 6x |
| 内存写入 | 24B | 4B | 6x |
| 分支数 | 3-4 | 0 | 消除 |

### 9.2 批量运算（1000 元素）

| 类型 | 当前（逐个 128 位） | 新（SIMD 批量） | 提升 |
|---|---|---|---|
| i8 | ~5000 周期 | ~63 周期 | 79x |
| i32 | ~5000 周期 | ~250 周期 | 20x |
| i64 | ~5000 周期 | ~500 周期 | 10x |
| f64 | ~5000 周期 | ~500 周期 | 10x |

---

## 10. 实施计划

### 阶段 1：ObjHeader 基础设施

- 定义 `ObjHeader`、`RefKind` 枚举
- 所有堆对象 struct 添加 `header: ObjHeader` 字段
- 实现统一 `retain`/`release` 分派表
- 实现统一 `deinit_table`

### 阶段 2：标量重构

- `Int` struct 改为 `bits: u128`（过渡期保留，后续删除）
- `Float` struct 改为 `bits: u128`（过渡期保留）
- Value 联合体标量变体改为 `[N]u8`
- 实现构造/访问辅助函数（`fromI32`/`asI32` 等）

### 阶段 3：Value 联合体重建

- 标量变体改为按实际宽度 `[N]u8`
- 22 种堆对象变体合并为 `ref: *ObjHeader`
- 重写 `retain`/`release`/`deepCopy`/`format`/`equals`

### 阶段 4：泛型运算系统

- 实现 `ScalarTag` 枚举和类型映射
- 实现泛型 `add`/`sub`/`mul`/`div`/`mod`/比较/位运算
- comptime 生成分派表
- 实现 SIMD 批量运算

### 阶段 5：迁移 VM 和 JIT

- VM 的标量运算路径迁移到泛型运算
- JIT 的标量运算路径迁移到泛型运算
- 验证所有现有测试通过

### 阶段 6：LFE 通道集成

- 实现 `Channel` 结构
- 实现 Value ↔ Channel 零拷贝转换
- 实现 Channel SIMD 批量运算

---

## 11. 与现有架构的关系

### 11.1 保留的部分

| 模块 | 角色 |
|---|---|
| Lexer/Parser/Sema | 不变 |
| ModuleLoader | 不变 |
| Str SSO 机制 | 保留（内部优化） |
| runtime/sync + 分配器 | 保留 |
| value/concurrent.zig | 保留（已迁移完成） |

### 11.2 重构的部分

| 模块 | 变化 |
|---|---|
| value/mod.zig | Value 联合体重建 |
| value/int.zig | Int → 过渡后删除 |
| value/float.zig | Float → 过渡后删除 |
| value/composite.zig | 添加 ObjHeader |
| value/callable.zig | 添加 ObjHeader |
| value/control.zig | 添加 ObjHeader |
| value/iterator.zig | 添加 ObjHeader |
| value/concurrent.zig | 添加 ObjHeader |
| value/str.zig | 添加 ObjHeader，保留 SSO |

### 11.3 新增的部分

| 模块 | 职责 |
|---|---|
| value/obj_header.zig | ObjHeader、RefKind、统一 RC |
| value/scalar.zig | ScalarTag、泛型运算、分派表 |
| value/ops.zig | 泛型运算函数（add/sub/mul/...） |
| value/batch.zig | SIMD 批量运算 |
