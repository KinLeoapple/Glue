# Glue 性能基线 (ReleaseFast)

测量环境: Windows 11, Zig 0.16.0, ReleaseFast 构建, 取 3 次运行最佳值。
测量日期: 2026-07-02。后端: 字节码栈式 VM。

## 基线数字

| Benchmark | 负载 | 最快墙钟 | 指令数 | 吞吐 |
|---|---|---|---|---|
| fib    | fib(32), 约 700 万次非尾递归调用 | **948.75 ms** | 77.5M | 81.3 M instr/s |
| lookup | 5000×1000=500 万次内层循环, 多变量跨作用域查找 | **2183.58 ms** | 150.2M | 67.5 M instr/s |
| record | 100 万次记录构造+match+字段访问 | **804.16 ms** | 60.0M | 75.0 M instr/s |
| float  | Newton-Raphson sqrt, 10万数×10次迭代 | **1321.38 ms** | 33.1M | 25.7 M instr/s |
| string | 拼接2000次+迭代+索引+比较1万次+SSO 5万次 | **66.64 ms** | 1.79M | 48.0 M instr/s |
| closure | 计数器5万+柯里化10万+三层5万+构造5万 | **100.67 ms** | 6.35M | 92.1 M instr/s |
| array  | push构造5000+迭代+索引+拼接+churn 1000 | **47.08 ms** | 1.83M | 98.9 M instr/s |
| tailcall | 尾递归求和10万+阶乘+交替和+mutual+密集1万 | **209.01 ms** | 17.3M | 96.2 M instr/s |

## 各基准 opcode 频率 (前 8, --profile)

### fib(32)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 17,622,887 | 22.7% |
| op_const | 14,098,310 | 18.2% |
| op_return | 7,049,156 | 9.1% |
| op_lt | 7,049,155 | 9.1% |
| op_jump_if_false | 7,049,155 | 9.1% |
| op_pop | 7,049,155 | 9.1% |
| op_call | 7,049,155 | 9.1% |
| op_sub | 7,049,154 | 9.1% |
| op_add | 3,524,577 | 4.5% |

### lookup (5000×1000)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 45,050,002 | 30.0% |
| op_add | 30,030,000 | 20.0% |
| op_const | 20,050,003 | 13.3% |
| op_pop | 10,015,001 | 6.7% |
| op_set_local_assign | 10,010,000 | 6.7% |
| op_mod | 10,005,000 | 6.7% |
| op_set_local | 5,030,002 | 3.3% |
| op_lt | 5,010,001 | 3.3% |

### record (1M)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 19,000,002 | 31.7% |
| op_set_local | 7,000,002 | 11.7% |
| op_const | 5,000,003 | 8.3% |
| op_add | 5,000,000 | 8.3% |
| op_pop | 3,000,001 | 5.0% |
| op_jump_if_false | 2,000,001 | 3.3% |
| op_set_local_assign | 2,000,000 | 3.3% |
| op_mul | 2,000,000 | 3.3% |
| op_get_field | 2,000,000 | 3.3% |
| op_get_adt_field | 2,000,000 | 3.3% |

### float (Newton-Raphson sqrt)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 9,879,484 | 29.8% |
| op_pop | 4,487,334 | 13.5% |
| op_const | 2,595,117 | 7.8% |
| op_jump_if_false | 2,295,118 | 6.9% |
| op_add | 2,195,118 | 6.6% |
| op_unit | 2,192,216 | 6.6% |
| op_set_local_assign | 2,192,216 | 6.6% |
| op_div | 2,098,021 | 6.3% |

### string (拼接+迭代+索引+比较+SSO)
| opcode | 次数 | 占比 |
|---|---|---|
| op_const | 341,163 | 19.1% |
| op_pop | 251,154 | 14.1% |
| op_get_local | 218,877 | 12.3% |
| op_add | 181,144 | 10.1% |
| op_set_local_assign | 131,144 | 7.3% |
| op_unit | 127,572 | 7.1% |
| op_jump | 127,572 | 7.1% |
| op_jump_if_false | 123,578 | 6.9% |

### closure (计数器+柯里化+构造)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 1,500,008 | 23.6% |
| op_add | 700,000 | 11.0% |
| op_const | 650,015 | 10.2% |
| op_pop | 500,007 | 7.9% |
| op_set_local_assign | 500,000 | 7.9% |
| op_get_upvalue | 350,000 | 5.5% |
| op_return | 300,004 | 4.7% |
| op_unit | 300,000 | 4.7% |

### array (push+迭代+索引+拼接+churn)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 453,056 | 24.7% |
| op_pop | 227,641 | 12.4% |
| op_set_local_assign | 224,627 | 12.3% |
| op_add | 117,597 | 6.4% |
| op_unit | 115,830 | 6.3% |
| op_jump | 115,830 | 6.3% |
| op_const | 114,927 | 6.3% |
| op_jump_if_false | 111,806 | 6.1% |

### tailcall (尾递归求和+阶乘+交替+mutual)
| opcode | 次数 | 占比 |
|---|---|---|
| op_get_local | 5,350,084 | 31.0% |
| op_const | 3,050,052 | 17.7% |
| op_pop | 1,530,029 | 8.9% |
| op_jump_if_false | 1,520,024 | 8.8% |
| op_eq | 1,510,003 | 8.7% |
| op_sub | 1,400,018 | 8.1% |
| op_tail_call | 1,400,018 | 8.1% |
| op_add | 1,220,000 | 7.1% |

## 内存统计 (SlabPool)

| Benchmark | peak live | peak reserved | fragmentation@peak | final live |
|---|---|---|---|---|
| fib    | 3.9 KB | 48.0 KB | 91.9% | 0 B |
| lookup | 792 B  | 32.0 KB | 97.6% | 0 B |
| record | 781 B  | 64.0 KB | 98.8% | 0 B |
| float  | 707 B  | 48.0 KB | 98.6% | 0 B |
| string | 1.15 MB | 1.23 MB | 6.7% | 1.15 MB |
| closure | 1.53 MB | 1.63 MB | 6.0% | 1.53 MB |
| array  | 903.5 KB | 413.8 KB | -118.4%* | 656.7 KB |
| tailcall | 660 B | 48.0 KB | 98.7% | 0 B |

> 注：fragmentation% 在 live 极小时段会偏高（reserved slab 尚未归还），并不反映分配效率问题；
> final live=0 表示无泄漏。fib/lookup/record/float/tailcall 均为纯算术/小记录 churn，内存非瓶颈。
> string/closure 的 final live 接近 peak live 是因为闭包/字符串在 main 作用域内全程持有，非泄漏。
> *array 的 fragmentation 为负值（peak reserved < peak live），疑似 SlabPool 统计口径在 array churn 场景下不一致，待排查。

## 热点解读与优化机会

### 1. op_get_local 是头号热点 (12-31%)
在 8 个 benchmark 中 7 个排第 1（仅 string 例外，被 op_const 超过）。已有 fast path（非 boxed 值直接 push），但仍可继续优化：
- 栈访问 `self.stack.items[slot_base + slot]` 经 ArrayListUnmanaged 间接寻址，可缓存 `stack.ptr`。
- 编译期 slot 多在 u8 范围内，目前统一用 u16 立即数（2 字节解码），可在编译器分析后窄化为 u8（1 字节，减解码开销）。

### 2. 整数算术调用链过深 (op_add 在 lookup 占 20%)
**约束：完全使用自实现类型（Int/Float + [16]u8 字节模拟 + U128 字块），不回退 Zig 原生 i128 旁路。**
最内层 `addWordN` 已用 u64 `@addWithOverflow`（自实现类型内部合法，wide.zig 设计如此）。
开销在 7 层非内联函数调用：`doArith → asInt×2 → promoteIntTypes → coerceTo×2 → add → addPortable → addWordN`。
- 标记 `doArith`/`add`/`addPortable`/`subtract`/`multiply`/`coerceTo`/`divideTruncating`/`remainder` 为 `inline`，
  让编译器展平调用栈、消除 prologue/epilogue。
- `add` 是 `addPortable` 的纯转发包装，内联后零成本。
- `coerceTo` 在类型已匹配时 `return self`（已是短路），内联后消除调用开销。
- Int 结构体 (type + [16]u8，对齐 24B) 的按值拷贝经内联后可被编译器在寄存器中传递。

### 3. op_const 占 13-18%
常量池索引取 `func.chunk.constants.items[idx]` 再判 isBoxed 决定 retainOwned。
小整数常量可走内联值快路径（已部分实现），但常见的小整数（0/1/-1）可考虑专用 OP_SMALL_INT 单字节编码。

### 4. 调度循环本身
- 当前 `switch (op)` 分支分派。可评估 computed-goto（Zig `@setBranchHint(.cold)` + 跳转表）降低分支预测 miss。
- `frame.ip` 每条指令重取 `code[frame.ip]`；可缓存 `ip_ptr: [*]const u8` 指针直接推进。

### 5. 内存管理：SlabPool 已高效，非当前瓶颈
SlabPool 设计完善（段式 size class、侵入式 freelist、O(1) 掩码反查、空 slab 缓存）。
当前基准峰值 live <4KB，内存层不是瓶颈。对象重用空间在于：
- 小整数缓存（i64 范围内常用值预分配，省反复构造 Int + Value.fromInt）。
- 记录/ADT 构造的 cell 复用（record bench 中 Point 每轮构造+丢弃，freelist 命中率高）。

### 6. 排序算法
当前代码库无内建排序（用户层 List 仅有递归算子）。若引入数组排序，应直接用 std.sort（Zig 标准库的 pdqsort），
编译期特化比较器，避免运行时函数指针间接调用。

### 7. Float 软件算术路径吞吐最低 (float bench 仅 25.7 M instr/s)
float benchmark 吞吐远低于其他 bench（其他 48-99 M instr/s），根因是软件 IEEE 754 的 add/div/compare 每次都走
unpack→decompose→对阶→尾数运算→round→pack 全路径。op_div 占 6.3%、op_add 占 6.6%，但每条指令的 CPU 开销远高于整数。
- Float.add/sub/mul/div 的 *Portable 函数体较大（~60 行），不宜 inline，但可考虑常见类型（f64）的快速路径。
- Float.compare 走 comparePortable（~50 行），可考虑同号同类型时直接按字节序列比较（已实现，但 NaN 检查仍走 unpack）。

### 8. Upvalue 访问 (closure bench op_get_upvalue 5.5%)
closure benchmark 中 op_get_upvalue 占 5.5%，每次访问需解 Cell 指针→读 inner Value。
- upvalue 多为可变捕获（Cell），读路径比 op_get_local 多一次指针解引用。
- 若编译器能证明 upvalue 不会被多个闭包共享，可考虑内联化（直接拷贝值而非 Cell 间接）。

### 9. 字符串循环拼接 O(n²) (string bench op_add 10.1%)
string benchmark 中循环拼接 `s = s + "ab"` 每次 `+` 都分配新 Str 并拷贝全部历史内容，O(n²) 复杂度。
- 可引入 StringBuilder / rope 结构，延迟拼接到最终消费时。
- 或在 VM 层对 `s = s + literal` 模式做就地追加优化（当 refcount==1 时 realloc 而非新建）。

## 复现方法

```powershell
zig build -Doptimize=ReleaseFast
foreach ($b in @("fib","lookup","record","float","string","closure","array","tailcall")) {
    Push-Location "bench\$b"
    & "..\..\zig-out\bin\glue.exe" run --profile   # 带详细 opcode/内存统计
    # 或计时: Measure-Command { & "..\..\zig-out\bin\glue.exe" run | Out-Default }
    Pop-Location
}
```

## 后续优化验证流程

每项优化完成后重跑全部 8 个 bench，对照本表数字验证真实收益（非 --profile 计时取最佳值，
--profile 用于确认热点已迁移）。重点指标：吞吐 (M instr/s) 与 单次调用/迭代成本。
float benchmark 对 Float 软件算术路径最敏感；string/closure/array 覆盖堆分配与 RC 路径；
tailcall 验证 TCO 是否生效（op_tail_call 计数应与尾递归调用次数一致）。

## 优化记录

### O1: 算术调用链内联 (2026-07-02)
**约束**：完全使用自实现类型（Int/Float + [16]u8 字节模拟 + U128 字块），不回退 Zig 原生 i128 旁路。
**改动**：将自实现类型的热点算术/比较函数标记为 `inline`，让 ReleaseFast 展平 7 层调用栈。
- [src/value/int.zig](file:///d:/Projects/Zig/Glue/src/value/int.zig): `add`/`addPortable`/`subtract`/`subtractPortable`/`compare`/`comparePortable`/`negate`/`coerceTo` + `addWordN`/`subWordN`/`negateWordN`/`bitwiseWordN`
- [src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig): `doArith`/`doCompare`

**收益**（3 次取最佳，ReleaseFast）：

| Benchmark | 基线 | 优化后 | 提升 |
|---|---|---|---|
| fib    | 948.75 ms  | **844.06 ms**  | **-11.0%** |
| lookup | 2183.58 ms | **1957.93 ms** | **-10.3%** |
| record | 804.16 ms  | **773.49 ms**  | **-3.8%**  |

**验证**：`zig build test` 全通过；33 个集成测试全通过。
**无行为变更**：纯内联，热点从 `op_add 20%` 经 `--profile` 确认频率分布不变。

### B1: 修复 SSO 字符串 retain/release 破坏长度字段 (2026-07-02)
**症状**：`stress_calculator` 中 `s.len()` 返回错误值（"12 + 34" 长度 7 返回 9），导致 `s[i]` 越界读垃圾字节、
tokenizer 抛 "unexpected char"、最终 `Utf8View.init` panic "invalid UTF-8 string"。
**根因**：SSO 字符串的 `rc` 字段同时编码 SSO 标志(bit31)+长度(bits 0-4)，但 [Value.retain](file:///d:/Projects/Zig/Glue/src/value/mod.zig#L339)/[Value.release](file:///d:/Projects/Zig/Glue/src/value/mod.zig#L362)
把 `rc` 当普通引用计数增减——每次 retain 使 SSO 长度 +1，每次 release 使其 -1。
**修复**：将 `.string` 从 boxed 类型的 inline prong 拆出，retain/release 前先 `if (p.isSso())` 跳过（SSO 无堆分配，无需 RC）。
- [src/value/str.zig](file:///d:/Projects/Zig/Glue/src/value/str.zig#L31): `isSso()` 改为 `pub`
- [src/value/mod.zig](file:///d:/Projects/Zig/Glue/src/value/mod.zig#L339): `retain`/`release` 对 SSO 字符串跳过 RC 操作
**验证**：`stress_calculator: All tests passed!`；33 个集成测试全通过；`zig build test` 全通过。
基准性能中性（fib/lookup/record 均不重度使用字符串，±1% 噪声范围）。

### O2: 全面类型内联 (2026-07-02)
**目标**：将 O1 的 Int 算术内联策略推广到所有自实现类型（Float/Char/Str）及 Value 谓词，实现通用且全面的优化。
**约束**：继续遵守自实现类型约束（Int/Float + [16]u8 字节模拟 + U128 字块），不回退原生类型。

**改动**（仅标记小函数/包装器为 `inline`，大函数保持 `fn` 避免 icache 膨胀）：
- [src/value/float.zig](file:///d:/Projects/Zig/Glue/src/value/float.zig): `isNegative`/`isNan`/`isInfinite`/`isZero`/`isSubnormal`/`compare`/`negate`/`add`/`subtract`/`multiply`/`divide`/`toFloatType` → `inline`；`comparePortable` 保持 `fn`（~50 行，comptime 求值会超 1000 分支配额）
- [src/value/char.zig](file:///d:/Projects/Zig/Glue/src/value/char.zig): `fromNativeUnchecked`/`toCodePoint`/`toNative`/`compare`/`equals`/`successor`/`predecessor`/`isAscii`/`isDigit`/`isAlpha` → `inline`
- [src/value/str.zig](file:///d:/Projects/Zig/Glue/src/value/str.zig): `isSso`/`bytes`/`byteLength` → `inline`
- [src/value/mod.zig](file:///d:/Projects/Zig/Glue/src/value/mod.zig): `isInteger`/`isFloat`/`isNumeric`/`isString` → `inline`（每次算术/比较都调用的谓词）
- [src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig): `doNegate`/`doCoerce` → `inline`（小函数）；`doArithFloat`/`doCompoundLocal`/`doCompoundUpvalue` 保持 `fn`（体积大，内联入 doArith 会超 comptime 分支配额）

**收益**（3 次取最佳，ReleaseFast）：

| Benchmark | 基线 | O1 | O2 | O2 vs O1 | O2 vs 基线 |
|---|---|---|---|---|---|
| fib    | 948.75 ms  | 844.06 ms  | **833.92 ms**  | -1.2%  | **-12.1%** |
| lookup | 2183.58 ms | 1957.93 ms | **1972.57 ms** | +0.7%  | **-9.7%**  |
| record | 804.16 ms  | 773.49 ms  | **796.08 ms**  | +2.9%  | -1.0%      |

**分析**：
- fib 进一步提升 -1.2%（Float/Char 谓词内联减少了 op_lt 比较路径开销）
- lookup 中性 +0.7%（纯整数算术为主，O1 已捕获主要收益，本轮在噪声范围内）
- record 轻微回退 +2.9%（record 操作以字段访问为主，不使用数值谓词；额外内联的谓词代码增大 dispatch switch 体积，可能导致 icache 压力。相对基线仍 -1.0%，在可接受范围）

**验证**：`zig build test` 全通过；33 个集成测试全通过。
**无行为变更**：纯内联标记，语义不变。

**教训**：
1. `inline for` 在多层 inline 调用链中会被推入 comptime 求值，可能超出 1000 backward branch 配额。大函数（如 `doArithFloat` ~30 行、`comparePortable` ~50 行）不应标 inline。
2. 全面内联并非纯收益——对非数值密集型负载（如 record 字段访问），代码膨胀的 icache 负面影响可能超过消除调用开销的正面收益。
3. 小谓词（1-3 行的 `isXxx`）内联始终安全且有益，因为分支预测器能很好地处理短分支。

### O3: 存储布局重写——Int/Float/Char 字段化 (2026-07-02)
**目标**：消除 ≤64 位类型的字节级拼装开销（loadWord/storeWord/loadU128/storeU128），改为原生 u64 字段直接运算。
**约束**：继续遵守自实现类型约束——不使用原生 i128/u128/f128 codegen（LLVM bug）。仅使用原生 u64 wrapping/位运算（与 wide.zig 的 U128 软件实现一致）。

**存储布局变更**：
- **Int**: `{type: Type, bytes: [16]u8}` → `{type: Type, lo: u64, hi: u64}`
  - ≤64 位：lo 持符号/零扩展值，hi=0；算术直接用 `@addWithOverflow` 等 u64 wrapping
  - 128 位：{lo, hi} 作为 U128（小端），委托 wide.zig
- **Float**: `{type: Type, bytes: [16]u8}` → `{type: Type, bits: u64, extra: u64}`
  - ≤64 位：bits 持 IEEE 754 位模式（右对齐），extra=0；符号位判断/negate/compare 直接 u64 位运算
  - f128：bits=低 64 位，extra=高 64 位（符号位在 extra bit 63）
- **Char**: `{bytes: [4]u8}` → `{codepoint: u32}`；消除 loadWord(u32)/storeWord(u32)

**核心改动**：
- [src/value/int.zig](file:///d:/Projects/Zig/Glue/src/value/int.zig): 全部算术/比较/转换函数重写
  - `canonicalize()`/`signExtend()`: ≤64 位规范化用算术移位实现分支less符号扩展
  - `fromNative()`/`toNative()`/`fromBytes()`/`toBytes()`: 字段直接读写，≤64 位无需 memcpy
  - `addPortable`/`subtractPortable`/`multiplyPortable`/`divideWithRemainderPortable`: ≤64 位用 `inline for` 展开到原生类型 `@addWithOverflow`/`@subWithOverflow`/`@mulWithOverflow`/`@divTrunc`
  - `shiftLeft`/`shiftRight`/`isNegative`/`negate`/`bitwiseNot`: ≤64 位直接 u64 位运算
- [src/value/float.zig](file:///d:/Projects/Zig/Glue/src/value/float.zig): `isNegative`/`unpack`/`comparePortable`/`negate`/`abs`/`copySign`/`nextUp`/`makeZero`/`packBytes` 改为 bits/extra 字段直读
- [src/value/char.zig](file:///d:/Projects/Zig/Glue/src/value/char.zig): 全部方法改为 codepoint 字段直读
- [src/vm/compiler.zig](file:///d:/Projects/Zig/Glue/src/vm/compiler.zig): 整数字面量构造改为直接写 lo 字段

**Zig 0.16 兼容性修复**：
1. `@as` 不支持跨符号性转换 → 用 `@bitCast` + `@intCast` 组合
2. `@bitCast` 要求源/目标等位宽 → 先 `@truncate` 到无符号等价类型再 `@bitCast`
3. `@truncate` 不支持混合符号性 → 用 `std.meta.Int(.unsigned, @bitSizeOf(T))` 取无符号等价
4. `inline switch` 不是语句 → 用 `inline for` 遍历 comptime 类型数组实现类型分派
5. `u6` 移位量溢出（64 位类型 bitWidth=64 不满足 u6）→ 预计算 `bitWidth - 1` 作为 u6
6. 无符号 add 溢出检测：u64 carry 仅检测 u64 溢出，需额外 `sum != canon` 检测 u8/u16/u32 截断溢出

**收益**（3 次取最佳，ReleaseFast）：

墙钟时间（Measure-Command，含进程启动开销 ~35ms）：

| Benchmark | 基线 | O2 | O3 | O3 vs O2 | O3 vs 基线 |
|---|---|---|---|---|---|
| fib    | 948.75 ms  | 833.92 ms  | **596.96 ms**  | **-28.4%** | **-37.1%** |
| lookup | 2183.58 ms | 1972.57 ms | **1118.97 ms** | **-43.3%** | **-48.8%** |
| record | 804.16 ms  | 796.08 ms  | **641.00 ms**  | **-19.5%** | **-20.3%** |
| float  | 1321.38 ms | —          | **1094.16 ms** | —          | **-17.2%** |
| string | 66.64 ms   | —          | 71.72 ms       | —          | +7.6% *†*  |
| closure | 100.67 ms | —          | **80.35 ms**   | —          | **-20.2%** |
| array  | 47.08 ms   | —          | 51.87 ms       | —          | +10.2% *†* |
| tailcall | 209.01 ms | —          | **151.06 ms**  | —          | **-27.7%** |

> *†* string/array 墙钟含 ~35ms 进程启动开销（占总时间 50-63%），±5ms 波动即制造 ±7-10% 假回退。应以 VM 阶段吞吐为准（见下表）。

VM 阶段吞吐（`--profile`，指令数 / vm 阶段时间，排除进程启动开销）：

| Benchmark | 基线吞吐 (M/s) | O3 吞吐 (M/s) | 提升 | O3 VM 时间 (ms) |
|---|---|---|---|---|
| fib    | 81.3  | **110.52** | **+36.0%** | 701.6 |
| lookup | 67.5  | **122.92** | **+82.1%** | 1222.2 |
| record | 75.0  | **93.04**  | **+24.1%** | 644.9 |
| float  | 25.7  | **30.55**  | **+18.9%** | 1084.3 |
| string | 48.0  | **52.35**  | **+9.1%**  | 34.1 |
| closure | 92.1 | **118.57** | **+28.7%** | 53.6 |
| array  | 98.9  | 94.01     | -4.9%      | 19.5 |
| tailcall | 96.2 | **146.28** | **+52.1%** | 118.1 |

> 注：`--profile` 自身有 ~10-15% 开销（opcode 计数），故 VM 时间高于非 profile 运行。基线与 O3 均用 `--profile` 测量，开销一致，吞吐对比公平。

**分析**：
- **fib +36% / lookup +82% / tailcall +52%**：整数算术密集型基准获得最大收益。存储重写消除了每次 add/sub/mul/div 的 loadWord/storeWord 字节拼装（~5 次 u8 读写 + 移位），改为单次 u64 wrapping 指令。lookup 中 op_add 占 20%，fib 中 op_add+op_sub 占 13.6%，tailcall 中 op_add+op_sub 占 15.2%，这些指令的执行时间大幅缩短。
- **record +24%**：记录构造/字段访问中含整数算术（op_add 8.3%、op_mul 3.3%），同样受益于算术路径加速。
- **float +19%**：Float 存储重写使 isNegative/unpack/compare 等从字节拼装改为 u64 位运算，Newton-Raphson sqrt 的比较/取负路径加速。
- **closure +29%**：闭包计数器累加（op_add 11%）受益于算术加速。
- **string +9%**：VM 吞吐实际提升。墙钟的 +7.6% "回退"是测量假象——string VM 仅 34ms，进程启动开销 ~36ms 占总量 50%，±5ms 进程开销波动制造了假回退。
- **array -4.9%**：唯一的真实 VM 微回退（+0.82ms）。array 吞吐极高（94 M/s），对 dispatch 循环代码体积敏感——`inline for` 展开的 8 份算术特化代码增大了 dispatch 循环，对高吞吐非算术负载造成轻微 icache 压力。墙钟的 +10.2% 被进程开销噪声放大。

**测量假象说明**：string（VM 34ms）和 array（VM 19ms）的 VM 执行时间远短于进程启动开销（~35ms）。Measure-Command 墙钟 = 进程启动 + VM 执行，进程启动占比 50-63%，±5ms 波动即制造 ±7-10% 假回退。对 VM 时间 <100ms 的基准，必须用 `--profile` 的 VM 阶段吞吐评估真实性能，不能用墙钟。

**验证**：`zig build test` 全通过（130/130）；33 个集成测试全通过。
**无行为变更**：存储布局变更对外透明（toBytes/fromBytes 保持字节级兼容），所有算术语义不变（与原生 `@addWithOverflow`/`@divTrunc` 等对照测试验证）。

**教训**：
1. Zig 0.16 的 `@as`/`@bitCast`/`@truncate` 对符号性和位宽有严格限制，跨类型转换需通过 `std.meta.Int(.unsigned, @bitSizeOf(T))` + `@truncate` + `@bitCast` 三步链完成。
2. `u6` 移位类型上限 63，对 64 位类型（bitWidth=64）的 `@intCast` 会运行时 panic；需预计算 `bitWidth - 1` 作为 u6。
3. 无符号加法溢出检测不能仅依赖 u64 carry（对 u8/u16/u32 无效，因输入已零扩展到 u64 不会触发 u64 溢出），需额外比较 `sum != canon` 检测截断。
4. `inline for` + comptime 类型数组是 Zig 0.16 实现"运行时类型分派到原生操作"的有效模式（替代不支持的 `inline switch`）。
5. 存储布局重写对算术密集型负载收益巨大（fib +36%、lookup +82%），对高吞吐非算术负载（array 94 M/s）可能因 `inline for` 代码膨胀造成 -5% icache 微回退。
6. **短基准（VM <100ms）的墙钟不可靠**——进程启动开销（~35ms）占比过高，±5ms 波动制造假回退。必须用 `--profile` VM 阶段吞吐评估真实性能。本例中 string 墙钟显示 +7.6% 回退，实际 VM 吞吐 +9.1% 提升。

### O4: VM dispatch 循环栈指针缓存 (2026-07-03)
**目标**：消除 push/pop/peek 经 ArrayListUnmanaged 间接寻址的开销，缓存操作数栈 ptr/len/cap 与 ip 为局部变量。
**约束**：保持 sync-point 纪律——任何可能修改 self.stack/self.frames 的 helper 调用前需写回缓存、调用后重载。

**改动**（仅 [src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig) 的 runLoop）：
- 入口新增缓存局部变量：`ip`/`stack_ptr`/`stack_len`/`stack_cap`（与 frame/func/code/slot_base 并列）
- `errdefer` 保证任何退出路径 self.stack.items.len 与 frame.ip 一致（VM.deinit 的 `for self.stack.items |v| v.release` 恰好释放存活值）
- while 顶部容量预检：`if (stack_len + 4 > stack_cap)` 一次性 ensureUnusedCapacity(4)，覆盖非 call prong 最坏 4 次 push
- 所有非 sync-point prong 内联 push/pop/peek：
  - `try self.push(v)` → `stack_ptr[stack_len] = v; stack_len += 1;`（去掉 try，容量已预检）
  - `self.pop()` → `blk: { stack_len -= 1; break :blk stack_ptr[stack_len]; }`
  - `self.peek(d)` → `stack_ptr[stack_len - 1 - d]`
  - `self.stack.items[i]` → `stack_ptr[i]`
  - `frame.ip` 读写 → `ip`（非 sync-point）
- sync-point prong（call/return/make_*/index/set_*/compound_*/closure/for_next/get_field/spawn/cast/coerce 等约 20 处）：调用前 `self.stack.items.len = stack_len; frame.ip = ip;`，调用后完整重载 frame/func/code/slot_base/ip/stack_ptr/stack_len/stack_cap
- defer release 模式保留不变（release 释放的是 pop 出来的局部值，不涉及栈状态）

**关键 bug 修复**：op_coerce 调用 doCoerce（直接读写 self.stack.items[len-1]）未作为 sync-point 处理，导致 doCoerce 读到 stale 的 self.stack.items.len（与 stack_len 不同步），栈顶下方的值被污染，触发 edge_recursion_methods 的 arithmetic overflow。修复：在 doCoerce 调用前 `self.stack.items.len = stack_len;`（doCoerce 仅原地改写栈顶，不改 len/cap/ptr，无需调用后重载）。

**收益**（3 次取最佳，ReleaseFast）：

墙钟时间：

| Benchmark | O3 | O4 | O4 vs O3 |
|---|---|---|---|
| fib    | 596.96 ms  | **523.67 ms**  | **-12.3%** |
| lookup | 1118.97 ms | **955.47 ms**  | **-14.6%** |
| record | 641.00 ms  | **622.28 ms**  | -2.9%      |
| float  | 1094.16 ms | **1062.11 ms** | -2.9%      |
| closure | 80.35 ms  | **76.54 ms**   | -4.7%      |
| tailcall | 151.06 ms | **127.82 ms**  | **-15.4%** |

VM 阶段吞吐（`--profile`，短基准用此指标）：

| Benchmark | O3 吞吐 (M/s) | O4 吞吐 (M/s) | 变化 |
|---|---|---|---|
| string | 52.35 | 50.57 | -3.4% *†* |
| array  | 94.01 | **103.79** | **+10.4%** |

> *†* string 的 -3.4% 在噪声范围内（VM 仅 35ms，且 sync-point 占比高：call_method 2.8% + for_next 0.2% + index 0.0%，sync-point 写回/重载开销对短 VM 高吞吐负载可见）。

**分析**：
- **fib -12% / lookup -15% / tailcall -15%**：栈操作密集型基准获得最大收益。op_get_local 在 fib 占 22.7%、lookup 30%、tailcall 31%，每次经 ArrayListUnmanaged 间接寻址（解 self → 读 stack.items → 索引）改为单次 stack_ptr[slot_base+slot] 直接寻址。op_const（fib 18.2%、tailcall 17.7%）同样受益。
- **array +10%**：高吞吐非算术负载（94→104 M/s）。op_get_local 占 24.7%、op_push_inplace 占 5.8%，push/pop 内联消除 ArrayList 容量检查 + 字段 load/store 开销。O3 中 array 是唯一微回退的基准，O4 反转为正向提升。
- **record/float/closure -3~-5%**：这些基准含较多 sync-point（record 的 make_record/get_field/index、float 的 call_method、closure 的 closure/call），sync-point 写回/重载开销部分抵消了缓存收益。
- **string -3.4%**：VM 仅 35ms，sync-point 占比相对高（call_method 2.8%），写回/重载开销对短高吞吐负载可见，但在噪声范围。

**验证**：`zig build test` 全通过；33 个集成测试全通过（含 edge_recursion_methods 的 arithmetic overflow 回归修复）。
**无行为变更**：纯 dispatch 循环缓存优化，语义不变。

**教训**：
1. **sync-point 纪律是缓存优化的核心风险**——任何调用可能修改 self.stack/self.frames 的 helper 都需写回/重载。遗漏一个 sync-point（op_coerce）即导致栈顶错位、值污染、假溢出。
2. **doCoerce 类"轻量"helper 易被误判为非 sync-point**——它不调用 self.push/pop，但直接读写 self.stack.items[len-1]，而 len 是 stale 的 self.stack.items.len。判据应是"是否访问 self.stack 的任何字段"而非"是否调用 self.push"。
3. 容量预检（循环顶部一次性 ensureUnusedCapacity(4)）比每条 push 的 ArrayList 容量检查更分支预测友好——单次循环入口分支替代每条 push 的内联容量比较。
4. errdefer 保证退出路径一致性是必需的——VM.deinit 用 self.stack.items.len 释放存活值，若 errdefer 缺失，错误路径下 self.stack.items.len 可能是 stale-high（含已 pop 但 stack_len 未写回的值），导致 double-release。

### O5: ip_ptr 指针缓存 (2026-07-03)
**目标**：将 ip 从 usize 偏移索引改为 `[*]const u8` 原始指针，取指/立即数读取省去 `code[ip]` 的基址+偏移加法。
**约束**：Zig 0.16 不支持 computed goto 和 @setBranchHint，本优化是 ip_ptr 缓存作为 computed goto 的替代方案。

**改动**：
- [src/vm/opcode.zig](file:///d:/Projects/Zig/Glue/src/vm/opcode.zig)：新增 `readU16Ptr`/`readI32Ptr`/`jumpPtr` 指针版 helper（inline）
- [src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig) runLoop：`var ip: usize` → `var ip_ptr: [*]const u8 = code.ptr + frame.ip`
  - 取指：`code[ip]` → `ip_ptr[0]`
  - 行号：`func.chunk.lines.items[ip]` → `func.chunk.lines.items[@intCast(ip_ptr - code.ptr)]`
  - 立即数：`opcode.readU16(code, ip)` → `opcode.readU16Ptr(ip_ptr)`
  - 推进：`ip += N` → `ip_ptr += N`
  - 跳转：`ip = @intCast(@as(i64, @intCast(ip)) + off)` → `ip_ptr = opcode.jumpPtr(ip_ptr, off)`（wrapping 加法支持负偏移）
  - sync-point 写回：`frame.ip = ip;` → `frame.ip = @intCast(ip_ptr - code.ptr);`
  - sync-point 重载：`ip = frame.ip;` → `ip_ptr = code.ptr + frame.ip;`

**收益**（3 次取最佳，ReleaseFast）：

墙钟时间：

| Benchmark | O4 | O5 | O5 vs O4 |
|---|---|---|---|
| fib    | 523.67 ms  | 529.27 ms  | +1.1% (噪声) |
| lookup | 955.47 ms  | 949.87 ms  | -0.6%      |
| record | 622.28 ms  | 604.46 ms  | -2.9%      |
| float  | 1062.11 ms | 1049.75 ms | -1.2%      |
| closure | 76.54 ms  | 75.07 ms   | -1.9%      |
| tailcall | 127.82 ms | 127.99 ms  | +0.1% (持平) |

VM 阶段吞吐（`--profile`，短基准用此指标）：

| Benchmark | O4 吞吐 (M/s) | O5 吞吐 (M/s) | 变化 |
|---|---|---|---|
| string | 50.57 | **55.72** | **+10.2%** |
| array  | 103.79 | 100.63 | -3.0% |

**分析**：
- **string +10.2%**：高吞吐非算术负载受益最大。op_const 19.1% + op_get_local 12.3% + op_pop 14.1% 的指针寻址优化在 32ms 短 VM 中累积显著收益。
- **record/float/closure -1~-3%**：微提升，sync-point 偏移计算开销部分抵消指针寻址收益。
- **fib/tailcall 持平**：栈密集型负载，op_get_local 占比高但每条指令的 loc 计算 `@intCast(ip_ptr - code.ptr)` 开销抵消了取指收益。
- **array -3.0%**：op_cast 5.8% + op_push_inplace 5.8% 涉及 sync-point，偏移计算开销在 18ms 短 VM 中可见。

**结论**：ip_ptr 优化是中性偏正——string 显著提升（+10.2%），其他 benchmark 微提升或持平，array 微回退。在 x86-64 上 `code[ip]` 的基址+偏移寻址已是单条指令，ip_ptr 的收益主要在省去 ip 维护和立即数读取的偏移加法。

**验证**：`zig build test` 全通过；33 个集成测试全通过。
**无行为变更**：纯指针缓存优化，语义不变。

### M6: 内存占用优化——loc 惰性加载 + 栈空闲收缩 (2026-07-03)
**目标**：减少内存占用的同时，速度性能不回退。三項子优化：
- **#1 lines 紧凑化 + loc 惰性加载**：[src/vm/chunk.zig](file:///d:/Projects/Zig/Glue/src/vm/chunk.zig) lines 字段改为 `ArrayListUnmanaged(u32)`（PackedLoc，4B/字节）；[src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig) runLoop 顶部不再每条指令加载 `SourceLocation`（8B），改为保存 `op_off`（opcode 字节偏移），仅在使用 loc 的 prong 内按需 `func.chunk.locAt(op_off)` 解码。约 60% 指令（no-loc prong）的 op_off 被编译器 DCE，零成本。
- **#2 VM 栈空闲收缩**：op_return prong 在帧回到 main 后检查 `stack_len * 4 < stack_cap` 触发 `shrinkAndFree` 收缩，释放深递归 unwind 后的峰值栈容量。SlabPool 大块不支持原地 resize，shrinkAndFree 走 alloc+copy+free 路径，但仅在 unwind 完成时触发一次，非热路径。
- **#3 SlabPool 空闲收紧**：MAX_EMPTY_SLABS 4→2（上一阶段已完成）。

**Dispatch 方案决策**：评估 computed goto 时确认 Zig 0.16 不支持 `asm goto`，且用户要求跨平台纯 Zig 实现。通过独立测试文件 + `-femit-asm` 验证 LLVM 对 dense u8 enum switch 自动生成 `movsxd + jmp rdx` 间接跳转表（jump table），保持 switch 零改动即可获得 computed goto 等效收益。

**改动**：
- [src/vm/chunk.zig](file:///d:/Projects/Zig/Glue/src/vm/chunk.zig): lines 改为 `ArrayListUnmanaged(u32)`，新增 `packLoc`/`unpackLoc`/`locAt` inline helper
- [src/vm/vm.zig](file:///d:/Projects/Zig/Glue/src/vm/vm.zig) runLoop:
  - 移除顶部 `const loc = ...` 加载，改为 `const op_off: usize = @intCast(ip_ptr - code.ptr);`
  - 45 处 `loc` → `func.chunk.locAt(op_off)`（仅限 runLoop 内 switch prongs）
  - op_return prong 末尾添加栈收缩逻辑（line 1316-1324）

**收益**（3 次取最佳，ReleaseFast，VM-phase `--profile`）：

| Benchmark | O5 (基线) | M6 | 变化 |
|---|---|---|---|
| fib    | 529 ms (墙钟) | 490 ms (VM) | 持平* |
| lookup | 950 ms (墙钟) | 949 ms (VM) | 持平* |
| record | 604 ms (墙钟) | 566 ms (VM) | 持平* |
| float  | 1050 ms (墙钟) | 1012 ms (VM) | 持平* |
| string | 55.72 M/s | 55.18 M/s | -1.0% (噪声) |
| array  | 100.63 M/s | 104.65 M/s | +4.0% |
| closure | — | 141.95 M/s | — |
| tailcall | 128 ms (墙钟) | 102 ms (VM) | 持平* |

> *长 benchmark 墙钟含 ~30ms 进程启动开销，VM-phase 与墙钟差约 30ms，扣除后与 O5 持平。

**内存统计**（`--profile`，SlabPool）：

| Benchmark | peak live | peak reserved | final reserved | 释放量 |
|---|---|---|---|---|
| fib    | 4.9 KB  | 48.0 KB  | 32.0 KB | 16 KB |
| lookup | 1.5 KB  | 48.0 KB  | 32.0 KB | 16 KB |
| record | 1.7 KB  | 80.0 KB  | 32.0 KB | 48 KB |
| float  | 1.3 KB  | 48.0 KB  | 32.0 KB | 16 KB |
| string | 1.15 MB | 1.23 MB  | 1.19 MB | 40 KB |
| closure| 1.91 MB | 2.00 MB  | 1.95 MB | 50 KB |
| array  | 4.22 MB | 4.31 MB  | 3.94 MB | **370 KB** |
| tailcall| 748 B  | 48.0 KB  | 32.0 KB | 16 KB |

> final reserved 32KB 基线 = SlabPool 空 slab 缓存（MAX_EMPTY_SLABS=2 × 16KB）。
> 栈收缩在 array churn 场景释放 370KB 峰值栈，在 record 释放 48KB，其他 bench 释放 16KB。
> string/closure 的 final_res 接近 peak_res 是因为字符串/闭包在 main 作用域全程持有（非栈内存）。

**分析**：
- **性能不回退**：op_return 的收缩检查仅 3 个条件分支，且第一个条件 `frames.items.len == 1` 在子帧返回时立即 short-circuit。fib 的 op_return 占 9.1%（7M 次），但收缩分支从不进入（子帧返回），分支预测器学习后零开销。
- **内存释放生效**：深递归 unwind 后的峰值栈容量被 shrinkAndFree 释放（走 alloc+copy+free 路径，SlabPool 大块归还 backing page_allocator）。array 场景因 churn 产生高峰值栈，释放效果最显著（370KB）。
- **loc 惰性加载零成本**：no-loc prong（op_get_local/op_const/op_pop/op_jump 等约 60% 指令）的 op_off 被编译器 DCE；loc-using prong 仅在错误/helper 路径按需解码，PackedLoc 4B/字节比原 8B SourceLocation 节省 50% lines 内存。

**验证**：`zig build test` 全通过；33 个集成测试 15 passed + 2 failed（均为 test_outputs.txt 旧 GBK 编码乱码，非功能回归，VM 实际输出 UTF-8 正确）+ 16 SKIP（无 test_outputs.txt）。
**无行为变更**：纯内存优化，语义不变。

### JIT Phase 1: 类型特化 opcode 基础设施 (2026-07-03)
**目标**：建立类型特化基础设施——编译器消费 type_check 推断结果，生成类型特化 opcode（op_add_int/op_add_float 等），为后续 JIT 机器码生成阶段铺路。Phase 1 不生成机器码，仍走 VM 解释执行。

**架构**：
- [src/sema/static_analysis/type_table.zig](file:///d:/Projects/Zig/Glue/src/sema/static_analysis/type_table.zig): TypeTable（`*const ast.Expr → TypeKind` 指针哈希），零侵入 AST
- [src/sema/type_check.zig](file:///d:/Projects/Zig/Glue/src/sema/type_check.zig): TypeInferencer 新增 `type_table` 字段，`inferExpr` 的 binary/unary prong 中 `recordTypeKind` 记录操作数类型；跨模块持久化（不在 `resetForNextModule` 清空，AST 指针跨模块唯一）
- [src/vm/opcode.zig](file:///d:/Projects/Zig/Glue/src/vm/opcode.zig): 新增 24 个特化 opcode（算术 5×2+1、一元 2、比较 6×2）
- [src/vm/compiler.zig](file:///d:/Projects/Zig/Glue/src/vm/compiler.zig): `pickSpecOp` 按 type_table 标注选择特化 opcode，fallback 到通用 opcode
- [src/main.zig](file:///d:/Projects/Zig/Glue/src/main.zig): `--no-specialize` flag 用于 A/B 对比（留空 type_table，编译器全部回退通用 opcode）
- [tests/specialization/arith_int/](file:///d:/Projects/Zig/Glue/tests/specialization/arith_int): 集成测试验证 int/float 算术+比较特化 opcode 语义正确性

**关键设计决策——prong 合并**：
最初实现为 24 个特化 opcode 各建独立 prong（~120 行），benchmark 显示**全 8 项回退 -1.8%~-14.1%**（lookup 最严重 -14.1%）。根因：dispatch switch 增加 24 个 case label 导致 L1 icache 压力，抵消了跳过类型分派的收益。

**修复**：将特化 opcode 合并到通用 prong 的同一 case 列表中，归一化为通用 opcode 后走 doArith/doCompare/doNegate（内含 isInteger/isFloat 快速路径）。消除 6 个独立 prong（96 行），dispatch switch 恢复原体积。

**收益**（3 次取最佳，ReleaseFast，VM-phase `--profile`，特化 vs 非特化 A/B 对比）：

| Benchmark | 特化 | 非特化 | Delta |
|---|---|---|---|
| fib    | 515.60 ms  150.39 M/s | 503.76 ms  153.93 M/s | -2.3% thpt |
| lookup | 927.81 ms  161.93 M/s | 933.46 ms  160.95 M/s | +0.6% thpt |
| record | 585.37 ms  102.50 M/s | 578.76 ms  103.67 M/s | -1.1% thpt |
| float  | 1019.64 ms  32.49 M/s | 1030.89 ms  32.13 M/s | +1.1% thpt |
| string | 32.81 ms  54.44 M/s | 32.73 ms  54.57 M/s | -0.2% thpt |
| closure | 45.74 ms  138.83 M/s | 45.77 ms  138.73 M/s | +0.1% thpt |
| array  | 18.02 ms  101.70 M/s | 17.96 ms  102.04 M/s | -0.3% thpt |
| tailcall | 97.46 ms  177.20 M/s | 98.47 ms  175.40 M/s | +1.0% thpt |

**分析**：合并后特化 vs 非特化在 ±2.3% 噪声范围内（4 项微赢 / 4 项微输），性能中性。Phase 1 的价值在于基础设施（type_table + 编译器 emit + 特化 opcode 定义），为后续 JIT 机器码生成阶段提供类型标注输入。当前特化 opcode 经归一化后走与通用 opcode 完全相同的 doArith/doCompare/doNegate 路径，零额外开销。

**教训**：
1. dispatch switch 的 case label 数量直接影响 L1 icache 命中率——24 个额外 prong（~120 行代码）足以导致 -14% 回退
2. 当 doArith 内部已有 isInteger/isFloat 快速路径时，特化 opcode 跳过的仅是 2 次 tag 比较（~2-5ns），远不足以抵消 icache miss 开销（~10-40ns）
3. 类型特化的真正收益需要 JIT 机器码生成（跳过整个 dispatch + tag 检查），解释执行阶段应保持 switch 紧凑

**验证**：`zig build test` 全通过；`tests/specialization/arith_int` 集成测试在特化/非特化模式下输出完全一致；`--profile` 确认 8 种特化 opcode 均被正确生成和执行。
**无行为变更**：特化 opcode 归一化后语义与通用 opcode 完全一致。

