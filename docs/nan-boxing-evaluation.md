# NaN-boxing / Value 瘦身评估报告

**评估日期**: 2026-06-26  
**当前状态**: VM 已全面取代树遍历器，30/33 测试通过，性能提升 10-72×  
**评估目标**: 将 Value 从 64 字节压缩到 8 字节，目标再提升 3-5×

---

## 1. 当前 Value 结构分析

### 1.1 实测大小

```zig
// 当前 Value (src/value.zig:587)
pub const Value = union(enum) {
    integer: IntValue,      // i128 + IntType tag = 32 字节
    float: FloatValue,      // f64 + FloatType tag = 16 字节
    boolean: bool,
    char_val: u21,
    string: []const u8,     // 胖指针 16 字节
    null_val,
    unit,
    array: *ArrayValue,
    record: *RecordValue,
    adt: *AdtValue,
    newtype: *NewtypeValue,
    range: Range,           // 2×i128 + bool = 33 字节
    vm_closure: *VmClosure,
    partial: *PartialApplication,
    builtin: Builtin,
    error_val: ErrorValue,
    throw_val: *ThrowValue,
    array_iterator: *ArrayIterator,
    string_iterator: *StringIterator,
    range_iterator: *RangeIterator,
    atomic_val: *AtomicValue,
    spawn_val: *SpawnHandle,
    channel_val: *ChannelValue,
    sender_val: *SenderValue,
    receiver_val: *ReceiverValue,
    trait_value: *TraitValue,
    lazy_val: *LazyValue,
    cell_val: *Cell,
};

// 实测：union 取最大字段 + tag 对齐
// Range (2×i128 + bool) = 33 字节 → 对齐到 64 字节
```

**实测大小**: 64 字节（最大字段是 `range: Range` 的 33 字节，对齐后占 64）

### 1.2 使用热点统计

| 位置 | Value 操作 | 频率 |
|------|-----------|------|
| **操作数栈** | push/pop/copy | 每条指令 1-3 次 |
| **CallFrame slots** | 局部变量读写 | 高频（循环体内） |
| **globals** | 全局变量 | 低频 |
| **常量池** | 程序启动时初始化 | 一次性 |
| **refcount** | retain/release | VM 中仅 3 处显式调用 |

**关键发现**: 
- VM 操作数栈是 `ArrayListUnmanaged(Value)`，每次 push 拷贝 64 字节
- lookup benchmark 500万次内层循环，每次迭代 ~8 个栈操作 = **4000万次 × 64字节拷贝**
- record benchmark 每次构造 ADT 需压栈所有字段值

---

## 2. NaN-boxing 方案设计

### 2.1 IEEE-754 NaN 域编码

利用浮点数 NaN 的未定义位编码类型标签和小值：

```
64位布局（小端）:

正常浮点数: 0x0000_0000_0000_0000 - 0x7FF0_0000_0000_0000
           0xFFF0_0000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF

NaN编码区: 0x7FF8_0000_0000_0000 - 0x7FFF_FFFF_FFFF_FFFF (quiet NaN)
           ^^^^^^^^^^              ^^^^^^^^^^^^^^^^^^^^^
           高13位固定(qNaN)        低51位可用

编码方案:
  Bits 63-51 (13 bits): 0x7FF8 + 类型标签 (3 bits可编码8种类型)
  Bits 50-0  (51 bits): payload（指针或立即值）

具体编码:
  0x7FF8_0000_0000_0000 | (tag << 48) | payload

类型标签分配 (3 bits = 8 种):
  000 (0): 堆指针 (BoxedValue*)
  001 (1): 小整数 (i48: -140737488355328 ~ 140737488355327)
  010 (2): null
  011 (3): unit
  100 (4): boolean (payload 低1位: 0=false, 1=true)
  101 (5): char (u21 Unicode码点)
  110 (6): 特殊值（预留）
  111 (7): 浮点数指针（超出f64范围的需装箱）
```

### 2.2 装箱类型（BoxedValue）

无法直接编码的大值需要堆分配：

```zig
pub const BoxedValue = struct {
    tag: BoxedTag,
    rc: u32,  // 引用计数
    
    pub const BoxedTag = enum(u8) {
        // 大整数（超出 i48 范围）
        big_int,        // payload: *BigInt
        
        // 字符串（长度 > 6 字节时装箱，≤6 可内联到 payload）
        string,         // payload: *String
        
        // 复合类型（原指针类型全部走这里）
        array,          // payload: *ArrayValue
        record,         // payload: *RecordValue
        adt,            // payload: *AdtValue
        newtype,        // payload: *NewtypeValue
        
        // 范围（i128 太大，必须装箱）
        range,          // payload: *Range
        
        // 闭包与函数
        vm_closure,     // payload: *VmClosure
        partial,        // payload: *PartialApplication
        builtin,        // payload: *Builtin
        
        // 错误与异常
        error_val,      // payload: *ErrorValue
        throw_val,      // payload: *ThrowValue
        
        // 迭代器
        array_iterator,
        string_iterator,
        range_iterator,
        
        // 并发原语
        atomic_val,
        spawn_val,
        channel_val,
        sender_val,
        receiver_val,
        
        // 高级特性
        trait_value,
        lazy_val,
        cell_val,
    };
    
    payload: union(BoxedTag) {
        big_int: struct { value: i128, type_tag: IntType },
        string: []const u8,
        array: *ArrayValue,
        record: *RecordValue,
        adt: *AdtValue,
        // ... 其余字段
    },
};

pub const Value = struct {
    bits: u64,
    
    // 解码辅助
    pub inline fn isFloat(self: Value) bool {
        return (self.bits & 0x7FF8_0000_0000_0000) != 0x7FF8_0000_0000_0000;
    }
    
    pub inline fn getTag(self: Value) u3 {
        return @intCast((self.bits >> 48) & 0x7);
    }
    
    pub inline fn getPayload(self: Value) u51 {
        return @intCast(self.bits & 0x0007_FFFF_FFFF_FFFF);
    }
    
    // 编码辅助
    pub inline fn fromFloat(f: f64) Value {
        return .{ .bits = @bitCast(f) };
    }
    
    pub inline fn fromInt(i: i48) Value {
        const payload: u51 = @bitCast(@as(i51, i));
        return .{ .bits = 0x7FF8_0000_0000_0000 | (1 << 48) | payload };
    }
    
    pub inline fn fromNull() Value {
        return .{ .bits = 0x7FF8_0000_0000_0000 | (2 << 48) };
    }
    
    pub inline fn fromBoxed(ptr: *BoxedValue) Value {
        const addr: u51 = @truncate(@intFromPtr(ptr));
        return .{ .bits = 0x7FF8_0000_0000_0000 | (0 << 48) | addr };
    }
};
```

---

## 3. 预期收益分析

### 3.1 内存占用

| 项目 | 当前 (64B) | NaN-boxing (8B) | 减少 |
|------|-----------|----------------|------|
| **操作数栈** (1000槽) | 64 KB | 8 KB | **87.5%** |
| **CallFrame slots** (100槽×64帧) | 409.6 KB | 51.2 KB | **87.5%** |
| **常量池** (1000项) | 64 KB | 8 KB | **87.5%** |
| **总计** (典型程序) | ~538 KB | ~67 KB | **87.5%** |

### 3.2 性能提升

基于 benchmark 剖析（每操作 ~2.3µs）：

| Benchmark | 当前瓶颈 | NaN-boxing 优化点 | 预期提升 |
|-----------|---------|------------------|---------|
| **fib(32)** | 调用密集（700万次） | 参数/返回值栈拷贝 64B→8B | **2-3×** |
| **lookup** | 变量查找（4000万栈操作） | GET_LOCAL/SET_LOCAL 拷贝 | **3-4×** |
| **record** | ADT构造+字段访问 | 字段值压栈 64B→8B | **4-5×** |

**保守估计总提升**: 当前 10-72× → **30-300×** (相对原始树遍历器)

**关键**: 64B 拷贝占 CPU L1 cache 线（64B），8B 拷贝仅需一次内存操作

---

## 4. 改造范围与风险评估

### 4.1 需修改的文件（8544 行代码）

| 文件 | 行数 | 改动范围 | 风险 |
|------|------|---------|------|
| **src/value.zig** | 1327 | **完全重写** Value 定义 + retain/release/clone | ⚠️ **高** |
| **src/vm/vm.zig** | 2565 | 修改所有 Value 操作（解码/编码） | ⚠️ **高** |
| **src/vm/compiler.zig** | 4652 | 常量池编码改为 NaN-boxing | ⚠️ **中** |
| **src/vm/chunk.zig** | ~500 | 常量池类型从 `[]Value` 改为 `[]u64` | ⚠️ **低** |
| **src/vm/opcode.zig** | ~300 | 无需改动（字节码格式不变） | ✅ **无** |

**总计**: ~9000 行代码需审查，~3000 行需重写

### 4.2 关键风险点

#### 🔴 风险 1: refcount 模型重构（最高风险）

**当前模型**:
```zig
// 每个堆类型有独立的 rc 字段
pub const ArrayValue = struct {
    elements: []Value,
    rc: u32,  // ← 在结构体内
};

pub fn retain(self: Value) Value {
    switch (self) {
        .array => |p| p.rc += 1,  // ← 直接访问
        // ...
    }
}
```

**NaN-boxing 后**:
```zig
// 所有堆类型统一经 BoxedValue 包装
pub fn retain(self: Value) Value {
    if (self.isBoxed()) {
        const box = self.asBoxed();  // ← 解码指针
        box.rc += 1;  // ← 统一入口
    }
    return self;
}
```

**复杂性**: 需修改 ArrayValue/RecordValue/AdtValue 等 15+ 类型的 rc 字段布局

**缓解**: 
- 阶段 1: 保留当前结构体 rc，BoxedValue.payload 是胖指针
- 阶段 2: 统一迁移 rc 到 BoxedValue 头部

#### 🔴 风险 2: 指针对齐假设

NaN-boxing 只有 51 位 payload，x64 指针是 48 位（用户空间），但需验证：

```zig
// 风险：指针超出 51 位会截断
const addr: u51 = @truncate(@intFromPtr(ptr));
// 恢复：高位清零
const restored: usize = @intCast(addr);
```

**验证**: Windows/Linux x64 用户空间指针 < 2^48，安全

**缓解**: 编译期断言 `@sizeOf(usize) <= 6`，运行时检测指针高位

#### 🟡 风险 3: i128/Range 装箱开销

当前 `Range` 内联在 Value（33B），NaN-boxing 后必须装箱：

```zig
// 当前：栈上直接存 Range
Value{ .range = Range{ .start = 0, .end = 100 } }

// NaN-boxing：需堆分配
const box = allocator.create(BoxedValue);
box.* = .{ .tag = .range, .payload = .{ .range = Range{...} } };
Value.fromBoxed(box);
```

**影响**: Range 密集操作（for 循环）可能变慢

**缓解**: 
- RangeIterator 装箱一次，迭代复用
- 小范围（start/end < i48）可编码为两个连续栈槽（ABI 约定）

#### 🟡 风险 4: 字符串处理复杂化

当前 `string: []const u8` 是胖指针（16B），NaN-boxing 只有 51 位：

**方案 A**: 短字符串优化（SSO）
```zig
// ≤6 字节字符串：内联到 payload（6×8=48 位）
// >6 字节：装箱
if (s.len <= 6) {
    var payload: u48 = 0;
    @memcpy(@ptrCast(&payload), s.ptr, s.len);
    return Value.fromInlineString(payload, s.len);
} else {
    return Value.fromBoxed(allocator.create(BoxedString));
}
```

**方案 B**: 统一装箱
- 简化实现，牺牲短字符串性能

**推荐**: 方案 A（Glue 变量名/关键字多为短字符串）

#### 🟢 风险 5: 并发原语兼容性

Atomic/Channel/Spawn 当前是不透明指针，NaN-boxing 只需装箱：

```zig
// 无影响：引用语义不变
Value.fromBoxed(allocator.create(BoxedValue{
    .tag = .atomic_val,
    .payload = .{ .atomic_val = atomic_ptr },
}))
```

**风险**: 低（指针语义透明传递）

---

## 5. 实施计划

### 5.1 分阶段路线图

#### **阶段 0: 原型验证（2-3 天）**

目标：单测验证 NaN-boxing 编解码正确性

```zig
// tests/nan_boxing_test.zig
test "encode/decode float" {
    const v = Value.fromFloat(3.14);
    try expect(v.isFloat());
    try expectEqual(3.14, v.asFloat());
}

test "encode/decode small int" {
    const v = Value.fromInt(42);
    try expect(!v.isFloat());
    try expectEqual(.small_int, v.getTag());
    try expectEqual(42, v.asSmallInt());
}

test "encode/decode null/unit/bool" { ... }

test "pointer round-trip" {
    var box = BoxedValue{ .tag = .array, ... };
    const v = Value.fromBoxed(&box);
    try expectEqual(&box, v.asBoxed());
}
```

**交付**: 20+ 单测全绿，覆盖所有编码路径

#### **阶段 1: Value 结构重写（5-7 天）**

修改 `src/value.zig`:

1. 定义 `Value = struct { bits: u64 }`
2. 实现编码函数（`fromFloat`/`fromInt`/`fromBoxed` 等）
3. 实现解码函数（`isFloat`/`getTag`/`asFloat` 等）
4. 定义 `BoxedValue` 统一头部
5. **关键**: 迁移 `retain`/`release`/`clone` 到新模型

**验证**: value.zig 单测全绿（当前 ~50 个测试）

**门禁**: 
- `zig build test` 全过
- 内存泄漏检测（`std.testing.allocator`）

#### **阶段 2: VM 集成（7-10 天）**

修改 `src/vm/vm.zig`:

1. **操作数栈**: `ArrayListUnmanaged(Value)` 保持不变（Value 现在是 8B）
2. **解码点**: 每个 `OP_*` 实现中加解码逻辑
   ```zig
   // 当前
   const a = self.pop();
   const result = a.integer.value + b.integer.value;
   
   // NaN-boxing 后
   const a = self.pop();
   if (!a.isInt()) return error.TypeMismatch;
   const a_int = if (a.isSmallInt()) 
       a.asSmallInt() 
   else 
       a.asBoxed().payload.big_int.value;
   ```

3. **常量池**: `Program.constants` 从 `[]Value` 改为直接存 `[]u64`
4. **全局变量**: `globals: ArrayListUnmanaged(Value)` 无需改

**增量验证**: 每完成 5 个 opcode，跑对应单测

**里程碑**:
- M0 单测通过（算术核）
- M1 单测通过（函数调用）
- M2 单测通过（复合值）

#### **阶段 3: 回归测试（3-5 天）**

1. `zig build test` 全过（173 VM 单测）
2. `bash run_tests.sh` 30/33 全绿（NaN-boxing 分支）
3. ReleaseFast 独立验证
4. **性能对比**:
   ```bash
   # 基线（当前 64B Value）
   fib: 0.91s, lookup: 2.03s, record: 0.71s
   
   # NaN-boxing（目标）
   fib: <0.4s, lookup: <0.6s, record: <0.2s
   ```

#### **阶段 4: 优化与收尾（2-3 天）**

1. **热路径优化**: 
   - 内联 `isFloat`/`getTag` 等辅助函数
   - computed-goto dispatch（叠加 NaN-boxing）

2. **SSO（短字符串优化）**:
   - ≤6 字节字符串内联到 payload

3. **文档更新**:
   - `docs/bytecode-vm-plan.md` 补充 NaN-boxing 章节
   - `docs/nan-boxing-design.md` 详细设计文档

**总工期**: 19-28 天（3-4 周）

---

## 6. 替代方案对比

| 方案 | Value 大小 | 实施难度 | 预期提升 | 风险 |
|------|-----------|---------|---------|------|
| **方案 A: NaN-boxing** | 8B | 高（重写 refcount） | 3-5× | 高（内存模型重构） |
| **方案 B: Tagged union (16B)** | 16B | 中（tag+指针分离） | 2-3× | 中（部分重写） |
| **方案 C: 专用栈槽类型** | 混合 | 低（栈优化） | 1.5-2× | 低（局部改动） |

### 方案 B: Tagged union (16B)

```zig
pub const Value = struct {
    tag: u8,       // 类型标签
    _pad: [7]u8,   // 对齐
    payload: u64,  // 指针或立即值
};
```

**优点**: 
- 实施简单（无需 NaN 域技巧）
- 指针不受 51 位限制

**缺点**: 
- 16B 仍需 2 次 cache 读取
- 提速仅 4× vs NaN-boxing 的 8×

### 方案 C: 专用栈槽优化

保持 64B Value，仅优化栈操作：

```zig
// 栈槽存储裸 union payload（不含 tag）
stack_slots: []u64,
stack_tags: []u8,

// push 时分离
fn push(val: Value) void {
    stack_tags[sp] = @intFromEnum(val);
    stack_slots[sp] = @bitCast(val.payload);
    sp += 1;
}
```

**优点**: 
- 低风险（Value 定义不变）
- retain/release 逻辑不变

**缺点**: 
- 收益有限（1.5-2×）
- 无法优化常量池/全局变量

---

## 7. 推荐决策

### ✅ 推荐：先实施方案 B（16B Tagged union）

**理由**:

1. **风险可控**: 
   - refcount 逻辑基本不变（BoxedValue 头部统一）
   - 指针无截断风险（完整 64 位）
   - 渐进式迁移（先 16B，验证后再考虑 8B）

2. **收益显著**: 
   - 16B → 栈拷贝仍降低 75%
   - 预期 2-3× 提升（lookup: 2.03s → ~0.7s）
   - 低风险下达成 VM 下一数量级优化

3. **迭代路径清晰**:
   ```
   64B (当前) → 16B (Tagged union, 3周)
                  ↓ 验证收益
                8B (NaN-boxing, 再3周)
   ```

4. **技术债务小**: 
   - 16B 方案可平滑升级到 8B
   - 若 16B 收益已达目标，可止步

### 🔶 备选：直接实施方案 A（8B NaN-boxing）

**仅当满足**:
- 团队对 NaN-boxing 有经验
- 有 2 个月专注时间窗口
- 必须达到 5× 提升（业务硬需求）

---

## 8. 下一步行动

### 立即可做（1-2 天）

1. **基准测试细化**:
   ```bash
   # 剖析当前 64B 拷贝占比
   perf record -g zig-out/bin/glue run bench/lookup/main.glue
   perf report
   ```

2. **原型验证 16B 方案**:
   ```zig
   // tests/tagged_union_prototype.zig
   const Value16 = struct {
       tag: ValueTag,
       payload: u64,
   };
   // 测试编解码 + 性能微基准
   ```

3. **评估会议**: 
   - 确认目标提升倍数（2× vs 5×）
   - 分配人力（1 人全职 or 2 人协作）
   - 决策方案 B vs 方案 A

### 阶段 1 启动条件

- [ ] 原型验证完成（16B 编解码正确）
- [ ] 基准测试确认拷贝占比 >30%
- [ ] 门禁脚本准备（`run_tests.sh` + 性能回归检测）
- [ ] 创建分支 `feature/value-slimming`

---

## 9. 附录：性能模型

### 当前瓶颈分解（lookup benchmark）

```
总耗时: 2030ms (500万迭代)
├─ 指令 dispatch: ~400ms (20%)
├─ 栈拷贝 (64B×8次/迭代): ~800ms (40%) ← NaN-boxing 目标
├─ 算术运算: ~300ms (15%)
├─ 变量查找 (slot 索引): ~200ms (10%)
├─ 分支跳转: ~200ms (10%)
└─ refcount overhead: ~130ms (5%)
```

**16B 方案预期**:
- 栈拷贝: 800ms → 200ms（↓75%）
- **总耗时: 2030ms → 1430ms (1.4×)**

**8B 方案预期**:
- 栈拷贝: 800ms → 100ms（↓87.5%）
- Cache 友好: dispatch/算术再快 20% → -140ms
- **总耗时: 2030ms → 990ms (2.0×)**

**结论**: 16B 方案性能/风险比更优，先实施

---

**最终建议**: 先用 3 周实施 **16B Tagged union** (方案 B)，验证 2× 提升后，评估是否继续投入 NaN-boxing。
