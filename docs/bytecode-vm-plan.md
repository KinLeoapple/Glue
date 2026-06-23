# Glue 字节码 VM 实施计划

状态：草案 / 待实施。作者视角承接性能优化链 #1–4 的最终结论
（见 `bench/BASELINE.md`、记忆 `glue-de-bruijn-negative`）：名字 intern（#3）后
增量优化彻底到顶，唯一剩下的数量级提速是**用字节码 VM 替换树遍历求值器核心**。

本文件是从"决定做 VM"到"VM 完全取代树遍历器"的完整路线图，含指令集、编译器、
调用约定、控制流降级、内存模型迁移、并发集成、分阶段里程碑与验证门禁。

---

## 0. 为什么是字节码 VM（动机回顾）

三连负结果（#4 帧池化 / #2 De Bruijn ~2% / B1 shadow_stack）+ 隔离剖析坐实：
每个二元运算 ~2.3µs，而原生加法是纳秒级，慢 ~1000×。成本**不在**变量查找、
帧分配、shadow_stack（全部已排除），而在树遍历机制本身**不可削减**的四件事：

1. 每个 AST 节点一次递归 `evalExpr` Zig 调用（栈帧建立/返回 + 无法内联）。
2. ~40 分支的 `union(enum)` tag switch（每节点一次跳转表分发）。
3. `EvalResult!Value` 的 `try` 错误传播（每层调用一次错误检查分支）。
4. 64 字节 `Value` 按值拷贝（每次求值结果在 Zig 栈上整体搬运）。

字节码 VM 一次性消灭 1、2、3：AST 编译成线性指令序列后，求值变成**一个**热循环
内的 switch（或 computed-goto），无递归、无 per-node 函数调用、控制流用跳转而非
Zig error。第 4 点（Value 宽度）作为独立的后续优化（NaN-boxing）单列，不在首版范围。

**目标**：fib/lookup/record 三 bench 相对当前 intern 后基线（31.9s / 44.1s / 7.5s）
取得 **3–8× 墙钟提速**，且 33/33 回归 + 并发用例全绿、无内存泄漏/double-free。

---

## 1. 范围与非目标

### 1.1 首版 VM 必须覆盖（与现有树遍历器功能对等）

VM 是树遍历器的**完全替代**，不是新增执行模式。最终 `glue run` 走 VM，
不保留两套求值路径（双路径维护成本高、易漂移，记忆已多次记录"双路径漂移"教训）。
因此首版即须覆盖现有所有语言特性：

- 字面量、算术/比较/逻辑/位运算、一元运算、范围、Elvis、字符串插值。
- 变量绑定（val/var）、块表达式、if 表达式、match（含守卫/或模式/构造器/记录模式）。
- 函数调用、默认柯里化（PartialApplication）、方法调用、字段访问、索引。
- 闭包（捕获 + 共享 cell 可变捕获）、lambda、TCO 尾调用。
- ADT/newtype/record 构造与解构、记录扩展。
- 控制流：return / throw / break / continue / defer / propagate(`?`) / non-null-assert(`!`)。
- 错误模型：Throw<T,E>、error_val 传播。
- 并发：spawn / atomic / channel / select（运行时不变，VM 调度集成见 §8）。
- HKT/GADT/Trait 值/Lazy/monad comprehension（这些大多在 sema 脱糖，VM 只需支持其降级后的核心节点）。

### 1.2 明确非目标（首版不做）

- **NaN-boxing / Value 瘦身**：64B Value 暂时原样进 VM（栈槽用 Value）。降低风险，
  第 4 点瓶颈留作 §10 后续。
- **寄存器式 VM**：首版用**栈式**（更简单、与表达式求值天然契合，编译器实现量小）。
- **JIT / 字节码缓存到磁盘**：每次 run 现编译现执行（编译耗时相对运行时可忽略）。
- **类型检查迁移**：sema（type_check 等）完全不动，仍在编译前跑；VM 只消费已检查的 AST。
- **删除树遍历器**：分阶段并存（见 §9 里程碑），全绿后再物理删除 `evalExpr` 等。

---

## 2. 总体架构与流水线

现流水线：`Lexer → Parser → AST → Sema(type_check) → resolve(intern) → 树遍历 Evaluator`。

新流水线（替换最后一段）：

```
Lexer → Parser → AST → Sema(type_check)   [完全不变]
                          ↓
                  Compiler (新, src/vm/compiler.zig)
                          ↓
                  Chunk / Function (字节码 + 常量池 + 调试信息)
                          ↓
                  VM (新, src/vm/vm.zig) ── 执行 ──> Value
```

`resolve.zig` 的角色升级：从"填 name_id + 休眠的 De Bruijn"变成**编译器的作用域解析前端**
（或直接并入 Compiler）。De Bruijn 在 VM 里**终于有意义**——VM 帧是扁平连续数组，
局部变量编译期解析成 `slot`（帧内偏移），不再有父链 walk。这是 #2 负结果在新底层下翻盘的地方。

### 2.1 新增文件（src/vm/）

| 文件 | 职责 |
|---|---|
| `src/vm/opcode.zig` | OpCode 枚举 + 指令编码/解码 helper |
| `src/vm/chunk.zig` | `Chunk`（code: []u8 / 常量池 / line 表）、`Function`（编译后函数对象） |
| `src/vm/compiler.zig` | AST → Chunk。含作用域栈、slot 分配、upvalue 解析、跳转回填 |
| `src/vm/vm.zig` | 执行引擎：CallFrame 栈 + 操作数栈 + 主 dispatch 循环 |
| `src/vm/disasm.zig` | 反汇编器（调试 + 测试黄金文件用） |

复用不变：`value.zig`（Value/refcount/COW/cell）、`env.zig`（仅全局环境/捕获仍可能用，
见 §6）、`intern.zig`、`pattern.zig`（匹配逻辑可复用判定）、所有 runtime/ 并发模块、
所有内建函数（`BuiltinFn` 签名不变，VM 用 OP_CALL_BUILTIN 调用）。

---

## 3. 值表示与栈模型（首版决策）

- **栈槽 = `value.Value`（64B 原样）**。操作数栈是 `std.ArrayListUnmanaged(Value)` 或预分配
  `[]Value`。不引入 NaN-boxing（§10 后续）。这样 refcount/COW/cell 语义**一字不改**地复用，
  风险面最小——这是首版能落地的关键决策。
- **常量池**：编译期把字面量（int/float/string/char）与函数对象、类型元信息装进
  `Chunk.constants: []Value`。运行时 `OP_CONST <idx>` 把常量 `retain` 后压栈。
  字符串常量在常量池持有所有权，压栈时按现有 string 语义处理（string 的 retain 是 no-op，
  需沿用 retainOwned/dupe 约定，见 §6.3）。
- **栈即生命周期边界**：表达式求值结果留在操作数栈顶；语句丢弃值用 `OP_POP`（POP 必须 release）。
  这套"压栈 = +1 持有 / POP = release"的纪律取代树遍历器里散落的 retain/release 配对，
  是内存正确性的核心约定（§6 详述）。

### 3.1 操作数栈 vs 调用帧

- **操作数栈**：单一全局 `Value` 数组，跨所有调用帧共享（经典 stack-based VM）。
- **CallFrame**：记录 `function: *Function`、`ip: usize`（指令指针）、`slot_base: usize`
  （本帧局部变量在操作数栈中的起始偏移）、`captures: []Value`（upvalue 数组，闭包用）。
- 局部变量**不单独存**：直接住在操作数栈 `slot_base + slot` 处（参数 + 块内 val/var 连续排布）。
  `OP_GET_LOCAL <slot>` / `OP_SET_LOCAL <slot>` 是数组索引，O(1) 无哈希——De Bruijn 翻盘点。
- 全局（顶层函数/类型/构造器/内建）仍走 `name_id` → 全局表（`AutoHashMap(u32, Value)` 或
  编译期解析成 `OP_GET_GLOBAL <const_idx>`）。全局查找不在热路径（循环体内是 local），可接受哈希。

---

## 4. 指令集（OpCode）

首版栈式指令集。操作数（slot/idx/offset）紧跟 opcode 编码进 `code: []u8`
（首版用定长 `u8` opcode + 按需 `u16`/`u32` 立即数，简单；computed-goto 优化留后）。

### 4.1 常量 / 字面量
- `OP_CONST <u16 idx>` — 常量池[idx] retain 后压栈（int/float/string/char/函数对象）。
- `OP_NULL` / `OP_UNIT` / `OP_TRUE` / `OP_FALSE` — 压单例字面量。

### 4.2 局部 / 全局 / upvalue
- `OP_GET_LOCAL <u16 slot>` / `OP_SET_LOCAL <u16 slot>` — 帧内 slot 读/写（retain/release 见 §6）。
- `OP_GET_GLOBAL <u16 idx>` / `OP_DEF_GLOBAL <u16 idx>` — 全局表（idx → name_id 常量）。
- `OP_GET_UPVALUE <u16 i>` / `OP_SET_UPVALUE <u16 i>` — 闭包捕获数组读/写（cell 透明解包，§6.4）。

### 4.3 算术 / 比较 / 逻辑 / 位
- `OP_ADD/SUB/MUL/DIV/MOD` `OP_EQ/NEQ/LT/GT/LE/GE` `OP_BIT_AND/OR/XOR`
  `OP_NEG/NOT` `OP_CONCAT`(str) `OP_CONCAT_LIST`(++) `OP_RANGE`/`OP_RANGE_INCL` `OP_ELVIS`。
- 二元运算 pop 两值、push 一值。整数类型提升/位运算 unify 规则**沿用 type_check 已定的语义**
  （运行时按 IntValue.type_tag 算，逻辑从现 `evalBinary` 搬过来，不重新设计）。
- `&&`/`||` 短路用跳转实现（`OP_JUMP_IF_FALSE` + POP），不作二元 opcode。

### 4.4 控制流（跳转）
- `OP_JUMP <i32 off>` / `OP_JUMP_IF_FALSE <i32 off>`（peek 条件，false 跳转）/ `OP_JUMP_IF_TRUE`。
- `OP_POP` — 弹栈顶并 release。`OP_POP_N <u16>` — 批量（块退出清局部）。
- `OP_DUP` — 复制栈顶（retain）。用于 compound-assign / match scrutinee 复用。

### 4.5 调用 / 返回
- `OP_CALL <u8 argc>` — 栈布局 `[callee, arg0..arg_{argc-1}]`，调用后栈顶为返回值。
  内部分派：闭包 → 压 CallFrame；builtin → 直接调；partial → 柯里化（§5.3）；arity 不足 → 造 partial。
- `OP_TAIL_CALL <u8 argc>` — TCO：复用当前帧（§5.4），不压新 CallFrame。
- `OP_RETURN` — 弹返回值、release 本帧局部、弹 CallFrame、把返回值压回调用者栈。
- `OP_CALL_METHOD <u16 name_idx> <u8 argc>` — 方法分派（§5.5）。

### 4.6 构造 / 解构
- `OP_MAKE_ARRAY <u16 n>` — pop n 个元素，造 rc=1 ArrayValue 压栈。
- `OP_MAKE_RECORD <u16 const_idx>` — const 持字段名表，pop n 值造 RecordValue。
- `OP_MAKE_ADT <u16 const_idx>` — const 持 type_name/constructor/字段名，pop 字段值造 AdtValue。
- `OP_MAKE_NEWTYPE <u16 const_idx>` / `OP_MAKE_CLOSURE <u16 fn_idx>`（捕获 upvalue，§6.4）。
- `OP_GET_FIELD <u16 name_idx>` / `OP_SET_FIELD <u16 name_idx>` / `OP_INDEX` / `OP_SET_INDEX`。
- `OP_RECORD_EXTEND <u16 const_idx>` — 记录扩展/更新。

### 4.7 模式匹配（match）
match 编译成**判定树 + 跳转链**，不引入巨型单 opcode：
- `OP_MATCH_TAG <u16 ctor_idx> <i32 off>` — peek ADT，构造器名不符则跳 off（试下一臂）。
- `OP_MATCH_LIT <u16 const_idx> <i32 off>` — 字面量模式比较。
- `OP_DESTRUCTURE_FIELD <u16 i>` — 取 ADT/record 第 i 字段压栈（绑定变量到 slot）。
- 守卫 = 普通条件跳转；或模式 = 多个 tag 测试 OR；变量绑定 = `OP_SET_LOCAL`。
- 穷尽性已由 sema 保证；运行时兜底 `OP_MATCH_FAIL`（panic "non-exhaustive match"）。
- 复杂模式的判定可复用 `pattern.zig` 的匹配判定函数（编译器生成调用，或运行时 helper）。

### 4.8 控制信号 / 异常 / defer
- `OP_THROW` — 弹错误值，触发 unwind（§7.2，查 handler 表）。
- `OP_PROPAGATE` — `?` 传播：peek，若 null/Error 则提前 RETURN，否则解包压栈。
- `OP_NON_NULL` — `!` 断言，null 则 panic。
- `OP_PUSH_DEFER <u16 fn_idx>` / `OP_RUN_DEFERS` — defer 栈（§7.3）。
- `OP_BREAK` / `OP_CONTINUE` 编译成跳转，**不需 opcode**（循环边界编译期已知）。

### 4.9 并发（运行时不变，仅指令包装）
- `OP_SPAWN <u16 fn_idx>` / `OP_ATOMIC` / `OP_LAZY <u16 fn_idx>` / `OP_SELECT <u16 meta_idx>`。
- spawn/lazy 体编译成独立 Function；捕获按现有深拷贝（spawn）/ 闭包（lazy）语义（§8）。

---

## 5. 编译器（AST → Chunk）

`src/vm/compiler.zig`，单遍递归下降发射字节码。每个函数体编译成一个 `Function`
（顶层 main 也是一个 Function）。承接 `resolve.zig` 的作用域栈结构。

### 5.1 数据结构

```zig
pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),       // 字节码
    constants: std.ArrayListUnmanaged(Value),// 常量池
    lines: std.ArrayListUnmanaged(SourceLocation), // ip→源位置（错误报告）
};
pub const Function = struct {
    chunk: Chunk,
    arity: u8,
    slot_count: u16,        // 帧需预留的栈槽数（参数 + 所有块内局部，编译期算定）
    upvalues: []UpvalueDesc,// 捕获描述（从父帧 local 还是父帧 upvalue 来）
    name_id: u32,
};
pub const UpvalueDesc = struct { from_parent_local: bool, index: u16 };
```

### 5.2 作用域与 slot 分配
- 编译器维护 `scopes: []Scope`，每个 Scope 是当前函数内的 local 列表（name_id → slot）。
- 进入块：记当前 slot 高水位；退出块：发 `OP_POP_N` 弹掉块内局部、回退高水位。
- slot 是**帧内连续偏移**（参数占 0..arity-1，之后是块局部）。`slot_count` = 函数体内
  同时存活的最大 slot 数（不是声明总数，块退出后 slot 复用）。
- 标识符解析三级（升级自现 ResolvedRef）：本函数 local → `OP_GET_LOCAL`；
  外层函数 local/upvalue → 登记 upvalue 链 + `OP_GET_UPVALUE`；否则全局 → `OP_GET_GLOBAL`。

### 5.3 默认柯里化
`OP_CALL <argc>` 在 VM 内判断：若 argc < callee.arity → 不执行，造
`PartialApplication{ func, bound_args, remaining }` 压栈（语义同现 evalCall）。
argc == arity → 正常调用。argc > arity → 调用后对返回值再 apply 剩余（现有逻辑搬运）。

### 5.4 尾调用（TCO）
编译器识别尾位置（沿用现 `preserves_tail` 规则：call/if/block/match 尾部）的 `call`，
发 `OP_TAIL_CALL` 而非 `OP_CALL`。VM 执行 `OP_TAIL_CALL`：
1. release 当前帧所有局部（除即将复用的实参）；
2. 把新实参移到当前帧 slot_base 起始处；
3. `ip = 0`、`function = callee`，**不压新 CallFrame**（复用当前帧）。

这把现 trampoline 的 `error.TailCall` 循环变成帧原地重置，省掉错误传播。
深度递归非尾调用仍压 CallFrame——但 VM 帧在**堆上的 CallFrame 数组**，不吃 Zig 原生栈，
顺带消除现树遍历器深递归爆 Zig 栈的隐患。

### 5.5 方法调用 / 字段
`obj.method(args)`：编译 `OP_CALL_METHOD <name_idx> <argc>`。VM 运行时按 receiver 类型
查方法（内建方法表 / trait impl / 模块 trait 值），复用现 `callMethod` 的分派逻辑
（抽出成可被 VM 调用的 helper，避免重写几千行方法实现）。首版可让 `OP_CALL_METHOD`
直接回调进现有 `callMethod`（receiver + args 从栈取），逐步内联热方法。

### 5.6 跳转回填
if/while/loop/match/&&/|| 用"先发占位 offset、记录位置、目标确定后回填"标准技术。
break/continue：编译器为每个循环维护 break/continue 跳转待回填列表，循环结束时回填。

---

## 6. 内存模型迁移（最高风险区）

这是整个项目最易出 double-free / leak / UAF 的地方。续15 收口的 refcount/owned/cell
模型必须**逐条搬运**到 VM 的栈纪律，不能想当然。核心是把散落在树遍历器各处的
retain/release 配对，重整成**栈机的统一不变式**。

### 6.1 栈所有权不变式（核心约定）
- **栈上每个 Value 都持有一份 owned 引用（+1）**。压栈即 +1，弹栈（POP/消费）即 -1。
- `OP_CONST`：常量池保留母本，压栈前 `retain`（复合值 rc+1；string 走 retainOwned/dupe）。
- `OP_GET_LOCAL` / `OP_GET_UPVALUE` / `OP_GET_GLOBAL`：读出后 `retain` 再压栈
  （栈副本独立持有，与帧 slot 的母本各算一份）。
- `OP_SET_LOCAL`：弹栈顶值写入 slot，**先 release 旧值** 再放新值（不额外 retain——
  所有权从栈转移到 slot）。`OP_POP`：release 栈顶。
- 二元运算：pop 两操作数（持有权转入运算）、release 输入、push 结果（新 +1）。
- 函数返回：返回值 retain 保活 → release 本帧所有 slot → 返回值压回调用者栈。

### 6.2 帧销毁
`OP_RETURN` / `OP_TAIL_CALL` 复用帧时：对 `slot_base..slot_base+slot_count` 范围内
所有 Value 调 `release`（等价现 `call_env.releaseEnv`）。返回值在 release 前已 retain 逃逸。

### 6.3 string 借用陷阱（已知雷区，必须沿用 retainOwned）
记忆 `glue-name-interning` 记录：string 的 `retain` 是 no-op、返回借用 slice，
for 循环 define→release 会 double-free。VM 里同样：凡是"把一个值放进会被独立 release
的位置"（slot/数组/字段/返回），string 必须走 `retainOwned`（dupe 独立 owned），
不能用裸 retain。编译器/VM 在 `OP_GET_*`、`OP_MAKE_ARRAY` 等处统一用 retainOwned 语义。

### 6.4 闭包捕获与共享 cell（var 捕获）
现模型：`buildCaptureEnv` 把自由变量快照进 capture_env，可变 var 捕获用共享 `*Cell`
（帧绑定与闭包指同一 cell，rc 联合持有）。VM 迁移：
- `OP_MAKE_CLOSURE` 按 `Function.upvalues` 描述，从父帧 local slot 或父帧 upvalue 取值，
  组成 `captures: []Value` 存进 Closure。**不可变捕获** retainOwned 快照；
  **可变捕获（var）** 捕获 `*Cell`（slot 里存的就是 cell_val，或捕获时装箱成 cell）。
- `OP_GET_UPVALUE`：若是 cell_val 则透明解包 `.inner`（沿用现 evalIdentifier cell 解包）；
  `OP_SET_UPVALUE`：写转发到 `cell.inner`（沿用现 env.set→cell 转发）。
- Closure 的 rc / capture 释放回调（env_release_fn 等价物）：归零时 release 所有 captures。
- **关键**：哪些 var 需要装箱成 cell，由编译器在作用域分析时判定（被内层闭包捕获且可变），
  对应现 resolve 的闭包转换。未被捕获的 var 留普通 slot（不装箱，省开销）。

### 6.5 验证手段
- 全程用 `--gpa`（DebugAllocator）跑 churn 测试（record/string-array loop=5000），
  断言无 leak / double-free（SlabPool `slab.used` 不溢出）。
- ReleaseFast **单独**跑（记忆教训：run_tests.sh 是 Debug，掩盖 ReleaseFast-only 崩溃）。
- 每个内存敏感 opcode 配单测：构造→使用→丢弃后 allocator 干净。

---

## 7. 控制流与异常的字节码降级

### 7.1 return / break / continue
- `return` = `OP_RETURN`（尾位置）或先 `OP_JUMP` 到函数尾再 RETURN。
- `break`/`continue` = 编译期回填的 `OP_JUMP`（跳出/跳到循环条件），退出作用域处插 `OP_POP_N`。

### 7.2 throw / Throw<T,E> 传播
现用 Zig `error.ThrowValue` + `self.throw_value`。VM 改**显式 handler 表**：
- 每个 Function（或 try-等价作用域）记录 handler 区间 `[start_ip, end_ip) → handler_ip`。
- `OP_THROW`：弹错误值，沿 CallFrame 栈向上找覆盖当前 ip 的 handler；找到则跳 handler_ip
  （边 unwind 边 release 跳过帧的局部 + 跑这些帧的 defer）；没找到则传播为函数返回
  `Error(...)`（函数返回类型是 Throw 时）或 GluePanic。
- propagate `?`：`OP_PROPAGATE` peek 值，是 Error/null 则触发等价于 throw 的提前返回。

### 7.3 defer
现 defer 按 LIFO 在作用域退出（含正常/throw/panic）执行。VM：
- 每帧维护 `defer_stack: []DeferEntry`（DeferEntry = 编译后的 defer 体 Function + 捕获环境）。
- `OP_PUSH_DEFER` 压栈；帧退出的**所有**路径（OP_RETURN / unwind / panic）统一调
  `runDefers`（LIFO 执行，每个 defer 体在当前帧环境上跑）。这比树遍历器的 errdefer 散布更集中。

### 7.4 panic
`gluePanic` 现打印专业化错误 + 位置链后终止。VM 保留：`OP_*` 运行期错误（除零、越界、
非穷尽 match、non-null 断言失败）调统一 `vmPanic(loc, msg)`，用 `Chunk.lines[ip]` 取源位置，
跑已注册 defer 后终止进程（沿用现 `gluePanicFmt`/`setErrMsg`/main.zig 兜底映射，记忆
`glue-error-messages-professional`）。

---

## 8. 并发集成（运行时不变）

zio/scheduler/channel/spawn/atomic 全部不动。改动仅在"协程体如何执行"：

- **spawn**：现深拷贝捕获 + 在协程里跑闭包体。VM：spawn 体编译成 Function，
  `OP_SPAWN` 按现深拷贝语义快照捕获（Atomic 浅拷贝例外），协程入口起一个**新的 VM 执行
  上下文**（独立操作数栈 + CallFrame 栈）跑该 Function。每协程一个 VM 实例（轻量：栈是 ArrayList）。
- **GC 根集**：现 shadow_stack 是死复制 GC 的根（主求值器 gc==null，B1 已短路）。VM 下
  **操作数栈 + 各 CallFrame 的 slot + captures 本身就是精确根集**——GC 扫描 VM 栈即可，
  比 shadow_stack 更自然。首版可维持 gc==null 主路径（不开 GC），spawn 协程 GC 行为按需对接。
- **select / channel / atomic**：`OP_SELECT`/方法调用回调进现有 channel/atomic 运行时函数，
  阻塞点 yield 给 zio 调度器（与现一致，VM 循环在 channel 操作处让出）。

**风险**：VM 主循环若是一个大函数，协程让出点需保存/恢复 VM 状态。因 zio 是 stackful 协程，
VM 循环跑在协程自己的栈上，让出由 zio 处理，VM 无需手动保存——与现树遍历器同理（现在
evalExpr 递归也跑在协程栈上）。这降低了集成风险。

---

## 9. 分阶段里程碑（每阶段独立可验证）

每个里程碑结束都跑：`zig build test`（单元）+ `bash run_tests.sh`（Debug 33/33）+
ReleaseFast 单独跑全套 + `--gpa` churn + 三 bench 对照。**门禁不绿不进下一阶段。**

迁移策略：VM 与树遍历器**并存于一个 flag 后**（`use_bytecode_vm`，类比 `use_lexical_addressing`）。
VM 不支持的节点**回退树遍历器**（编译器遇未实现节点返回 `error.Unsupported`，该函数整体走旧路径）。
随覆盖面扩大逐步默认开启，全绿后删旧路径。这样任何时刻 `glue run` 都可用，零长期破窗。

**M0 — 骨架 + 算术核（约 2–3 天）** ✅ 已完成
opcode.zig / chunk.zig / vm.zig / disasm.zig 骨架 + 最小 compiler.zig；编译 + 执行：
字面量、一元/二元运算（含 && / || / 短路）、比较、位运算、if、block、val/var/赋值、
局部变量（slot）、return。算术语义复用 value.zig 的 promoteIntTypes/inRange/inferIntType，
零漂移。接入 build.zig（vm_module + test step）。
交付：`zig build test` 全过（含 5 个 VM 单测：算术 / 局部 slot / 跳转 / disasm / 端到端
compile+run）；回归 33/33（Debug）。注：fib 完整跑通需 CALL/RETURN（递归），留 M1，
M0 仅验证骨架 + 算术核可独立编译执行。VM 尚未接入 `glue run`（M5 默认开启前都走旧路径）。

**M1 — 函数 / 闭包 / TCO（约 3–4 天）**
OP_CALL/RETURN/TAIL_CALL、CallFrame 栈、默认柯里化、OP_MAKE_CLOSURE + upvalue、cell 捕获。
跑通 lookup bench（多变量 + 循环）+ 闭包测试（makeCounter 等）+ 尾递归不爆栈。
交付：lookup bench 通过（410780000）；闭包/TCO 回归子集全绿；--gpa 闭包 churn 干净。

**M1a — 顶层调用 + CallFrame 栈（已完成）** ✅
范围：OP_CALL（callee 用 func_idx 立即数，**无一等函数值**，零改 Value union）/ OP_RETURN
跨帧、堆上 CallFrame 栈（深递归不吃 Zig 原生栈，MAX_FRAMES=64K 防爆）、while 循环、
return 语句、模块级两遍编译（先建顶层函数表再编译体，支持前向引用）。标识符按**名字字符串**
编译期解析（自包含，不依赖 resolve 预pass）。
交付：fib(10)=55 / fib(20)=6765 / lookup compute(while+局部+取模) 单测全绿；M0 三测改用
单函数 Program 包装；回归 33/33。**首个性能数据点**（ReleaseFast 同机）：
fib(32) 树遍历器 32.5s → VM **0.91s ≈ 36×**（消除每调用 StringHashMap/env 分配，仅栈帧+slot）。
已知 M1a 边界：①不跑 type_check，字面量按"最小容纳类型"推断（真实管线由 castValue 按标注强转），
②无一等函数值/柯里化/闭包/break-continue/复合值（→ M1b+），③尚未接入 `glue run`。

**M1b — 一等函数值 / 柯里化 / 闭包（待办）**
把 VM 函数引入 Value（评估循环依赖与 retain/release/clone 改动面）、默认柯里化、
OP_MAKE_CLOSURE + upvalue、cell 捕获、TAIL_CALL（尾位置复用帧不增长）。
跑通 lookup bench + 闭包测试（makeCounter）+ 尾递归不爆栈。

**M2 — 复合值 / 模式匹配（已完成）** ✅
数组/记录/ADT/newtype 构造解构、字段/索引、match（全模式）、记录扩展。跑通 record bench。
交付：record bench 通过（666666666666000000，VM ~0.71s vs 树遍历器 ~7.35s ≈ 10×）；match 全模式
（literal/or/guard/record/nested/newtype）+ record_extend 单测全绿；--gpa churn 干净。
拆 M2a（ADT 构造/字段/单 match）/M2b（数组·记录字面量·索引）/M2c（全模式 match·记录扩展·newtype）
三片，详见 docs/m2-plan.md。

**M3 — 控制流 / 异常 / 方法（约 4–5 天）**
throw/Throw 传播 + handler 表、propagate `?`、non-null `!`、defer、break/continue、
方法调用（回调现 callMethod）、字符串插值、type_cast、for/while/loop。
交付：除并发外的 tests/* 全部走 VM 通过。

**M4 — 并发 / 收尾特性（约 3–4 天）**
spawn/atomic/channel/select、lazy、monad comprehension、inline trait value、模块 trait 值。
交付：edge_concurrency* 等并发用例 ReleaseFast 全绿；33/33 全部走 VM。

**M5 — 默认开启 + 删除树遍历器（约 2–3 天）**
`use_bytecode_vm` 默认 true，跑满全套门禁；确认无回退路径触发后，物理删除 evalExpr 等
树遍历核心（保留被 VM 复用的 helper：callMethod 分派、castValue、内建函数、pattern 判定）。
更新 docs/language-design.md（§7.2 执行模型）、BASELINE.md（VM 后新基线）、本计划标"已完成"。

**M5a — VM 接入 glue run（脚手架 + 回退 + 整数定型）✅ 已完成**
关键发现：M1–M4 的「flag 后并存 + 回退」脚手架（§9）**从未存在**——VM 只被 bench_main.zig
与单测驱动，33 个回归项目全走树遍历器；M1–M4 单测用手写单模块源，跳过 type_check 与跨文件 use。
本片把 VM 真正接入 `glue run`：

- **拆分 evalModule**（src/eval/eval.zig）：抽出 `prepareModuleInner`（use 预加载 + checkModule +
  resolveModule），新增 `prepareModuleForVm`（VM 准备）与 `evalModulePrepared`（回退时跳过重复
  准备——类型注册表不随 resetForNextModule 清空，二次 checkModule 会误报 duplicate type）。
- **main.zig 调度**：`tryRunOnVM` 先 `vmEligible` 预扫描（仅 fun + adt/newtype + 无副作用裸表达式
  的模块进 VM；use/trait/impl/pack/顶层 val/record 整体回退——因 compileModule 对这些是静默
  `else=>{}`，不预扫描会编出残缺 Program）。VM 编译期 Unsupported / 无 main → 回退树遍历器。
  三态 ExecOutcome（ran_main / needs_main / failed）+ VmOutcome（含 fell_back_prepared）。
  `GLUE_VM=0` 关闭、`GLUE_VM_TRACE=1` 打印 ran-VM/fell-back（覆盖率度量）。build.zig：root 导入 vm_module。
- **整数定型（核心修复）**：VM 不跑 type_check，原先按 inferIntType 取最小容纳类型 → 形参/绑定
  注解的 i32/i64 宽度丢失 → 算术溢出 panic（whole-module 编译下，eligibility 不蕴含语义等价，
  编译期回退兜不住运行期分歧）。修复 = 镜像 eval 在形参/val/var 注解处的隐式 castValue：
  - 新增 `OP_COERCE <type_name>`（best-effort：仅 int/float→builtin 数值类型协调 type_tag，
    溢出/非数值/泛型类型名原样保留，**绝不 panic**，区别于会 panic 的 OP_CAST）。
  - 编译器：函数/lambda 入口对带 builtin 数值注解的形参发 GET_LOCAL+COERCE+SET_LOCAL；
    val/var 注解在 RHS 后发 COERCE（compiler.zig `emitParamCoercions`/`emitCoerceFromAnnotation`）。
  - 连带修 VM `compare` 的 ==/!=：原用 tag-strict `Value.equals`，协调后操作数 tag 不同
    （i32 形参 vs i8 字面量）→ `n==0` 恒 false 死循环；改为按值比较（promoteIntTypes 后），镜像 eval。
- **顺带补齐 VM 运行时**（让 eligible 项目真跑通，非新特性）：`arith` 的 `s + t` 字符串拼接、
  `compare` 的字符串字典序、Spawn `status()`（建 SpawnStatus ADT）、match `Ok(v)` 接受裸值
  （非 throw_val 视作 Ok 载荷，镜像 eval pattern.zig）。
- **门禁全绿**：zig build test（+6 M5 单测，leak-checked allocator）；run_tests.sh 33/33（Debug，
  VM 默认开）；ReleaseFast 33/33；GLUE_VM=0 33/33（回退路径 == 旧路径，零漂移）；VM 覆盖 **9/33**
  端到端真跑 VM（edge_arithmetic/concurrency/patterns/recursion_methods/strings_closures/
  throw_records/perf_recursion/phase4/phase6），其余 24 编译期回退（use/trait/impl/HKT/record）；
  perf_recursion VM 2.15s vs 树遍历器 5.14s ≈ **2.4×**（确认 VM 在 run 路径生效非静默全回退）。
  glue debug 的 LEAK 为既存（树遍历器同样报，与 M5 无关）。

**M5 剩余（未做）**：默认开启已达成（M5a），但「删除树遍历器」需先把回退的 24 个项目搬上 VM
——即在 VM 编译器实现 trait/impl 运行时分派、跨文件 use 导入、HKT `@`/monad、GADT、record/顶层
val。这是 M3/M4 级工作量（被早期里程碑记账却从未抵达 run 路径），应单列里程碑，不在 M5a 范围。

**M5b — VM 覆盖扩展（9→14）✅ 已完成**
在 M5a 基础上补齐若干 VM 缺口，把真跑 VM 的项目从 9/33 提到 **14/33**（array_concat / edge_closures
/ edge_iterators / edge_concurrency_race / type_builtin 新增），全程 33/33 不回归：
- **`++` 数组拼接**：新增 `OP_CONCAT_LIST`（弹两数组、元素各 retainOwned 拼新数组），编译器
  `concat_list` 分支发射。解锁 array_concat / edge_iterators。
- **`type()` 内建**：新增 Native `type_of` + `vmValueTypeName`（镜像 eval valueTypeName，纯
  value→name）。解锁 type_builtin / array_concat（输出与树遍历器逐行一致）。
- **alias 类型 eligible**：`type X = () -> i32` 等别名无运行时效果（编译器忽略），加入 vmEligible
  的 type_decl 白名单。解锁 edge_closures。
- **atomic 引用别名修复（并发正确性）**：`val c = counter`（counter 是 atomic）原经 `op_get_local`
  透明 load 成标量 → c 丢引用 → `spawn { c += 1 }` 累加丢失（VM 印 0，树遍历器印 1）。修复：
  新增 `emitBindingRhs`——val/var 的 RHS 是裸 identifier 时用 raw 读取保留 atomic 引用（镜像 eval
  把 atomic 当引用类型绑定）。连带让 `op_get_local_raw`/`op_get_upvalue_raw` 仍透明 force lazy
  （raw 只保留 atomic 引用、不跳过 lazy force，保持 lazy 绑定即 force 语义）。
- **for 循环变量被闭包捕获（cell-box）**：`doForNext` 原直接读 idx/iter slot 的 `.integer`，但
  循环体内闭包/spawn 捕获使 slot 就地 box 成 *Cell → "access integer while cell_val active" 崩溃。
  修复：doForNext 透明解包 idx/iter 的 cell，idx++ 写回 cell.inner。解锁 edge_concurrency_race。
- 门禁：zig build test（+M5b 单测：++ 长度 / atomic 别名 / for 闭包捕获）；Debug VM-on 33/33；
  Debug VM-off 33/33；ReleaseFast 33/33。

**M5c — letrec / ADT 字段定型（14→17）✅ 已完成**
把真跑 VM 的项目从 14/33 提到 **17/33**（stress_graph / stress_database / stress_regex 新增），
全程 33/33 + 单测无泄漏：
- **递归局部函数（letrec）**：嵌套 `fun go(){...go()...}` 解析为 val_decl(lambda)。修复：①val_decl
  RHS 是 lambda 时**先声明 slot**（lambda 体内可解析自身为 upvalue）；②emitCall 的 callee 标识符
  被 local **或 upvalue** 遮蔽时走通用 op_call_value（原仅查 local，upvalue 自引用漏判→Unsupported）。
- **letrec 循环引用（弱自引用）**：cell↔closure 互持→纯 refcount 泄漏。新增 `OP_SET_LOCAL_LETREC`
  + VmClosure.self_upvalue_idx：闭包捕获自身 cell 的 upvalue 标记为弱（cell.rc-=1 抵消 op_closure
  retain，releaseVM 跳过该 upvalue 不反向释放 cell），断环且无 use-after-free。镜像 eval defineWeak。
- **ADT 字段隐式定型**：`Emp(.., salary: i32)` 构造时实参 100（推断 i8）未协调→后续 `s*pct` 溢出 i8。
  AdtCtorDesc 增 field_types，OP_MAKE_ADT 对 builtin 数值字段 best-effort castNumeric（镜像 eval
  构造器 castValue）。
- 门禁：zig build test（+M5c 单测：letrec 递归 / ADT 字段定型，std.testing.allocator 无泄漏）；
  Debug VM-on/off 33/33；ReleaseFast 33/33；三新增项目 VM vs 树遍历器输出逐行一致。

**M5d — 内置函数补齐 ✅ 已完成**
VM 原仅 6 个 Native（println/print/Ok/Error/channel/type）。核查 eval 共注册 13 个内置函数，
本片补齐全部缺口，VM 内置函数集**完整**（覆盖率维持 17/33——缺的内置非覆盖瓶颈，瓶颈是
trait/impl/use/HKT）：
- **eq(a,b)**：结构深相等（递归 array/record/adt/newtype），新增 `vmStructuralEquals`（镜像 eval
  structuralEquals）。区别于 VM `Value.equals` 的引用相等。
- **Panic(v)**：格式化 v 后触发 VM panic（经 fail 报告，main.zig 已统一映射为 runtime panic）。
- **eprint/eprintln**：写 stderr（镜像 eval builtinEprint/Eprintln）。
- **scan/scanln**：stdin token/行读取。新增 VM.scan_line_buf/scan_line_pos/stdin_state（持久 reader）
  + doScan/doScanln/readNextLine/ensureStdinReader，逐条镜像 eval（含跨行 token、当前行剩余、
  CRLF 去尾、EOF→null）。VM.deinit 释放行缓冲 + reader。
- **str**：早已支持（解析为 type_cast，走 op_cast 的 str 分支）。
- 门禁：zig build test（+eq 结构相等单测）；Debug VM-on/off 33/33；ReleaseFast 33/33；
  scan/scanln/eq/Panic/eprintln 端到端 VM vs 树遍历器输出一致（含管道 stdin、EOF）。

**VM 基础能力现状**：所有基本类型（整数全宽 + 浮点全宽 + bool/char/str/null/unit + 数组/记录/
ADT/newtype/range/atomic/channel/spawn/lazy）+ 全部 13 个内置函数 + 整数/浮点字面量推断与
注解定型，均已完整支持。剩余回退仅因 trait/impl 运行时分派 / 跨文件 use / HKT / GADT / record
顶层声明等成块特性未实现。

**M5e — 自定义错误类型 + char 比较（17→22）✅ 已完成**
把真跑 VM 的项目从 17/33 提到 **22/33**（edge_nullable / phase3 / stress_calculator / stress_json
/ stress_program 新增），全程 33/33 不回归、5 新增项目 VM vs 树遍历器输出逐行一致：
- **error_newtype 构造器**：`type FileError = Error("file error")` → `FileError("msg")` 产
  `throw_val.err{type_name="FileError", message="file error: msg", is_error_subtype=true}`。新增
  chunk `ErrorCtorDesc` + `Program.error_ctors`/`addErrorCtor`、opcode `OP_MAKE_ERROR <err_idx>`、
  compiler `error_table`/`lookupError`（第一遍登记，emitCall 裸名命中 → OP_MAKE_ERROR）、VM 弹 str
  拼 `prefix + ": " + msg` 建 throw_val.err。main.zig `vmEligible` 加 error_newtype 进白名单。
  镜像 eval 的 error_newtype 构造器。
- **VM doGetField 补 throw_val.err 的 .message/.type_name**（原仅 error_val）：`fe.message` 访问
  自定义错误消息（镜像 eval accessField throw_val 分支，文档 2.4.7）。
- **VM compare 补 char 序比较**（<,>,<=,>=）：`c >= '0' && c <= '9'`（镜像 eval evalLt/Gt/Le/Ge
  的 char_val 分支）。
- 门禁：zig build test（158 VM 单测，+2 M5e：throw_val.err 构造 / `.message` 访问，无泄漏）；
  Debug VM-on/off 33/33；ReleaseFast 33/33。
- 既存（非本片）：edge_closures / edge_concurrency / phase4 的 VM vs 树遍历器输出 DIFFER 早于本片
  存在（git stash 验证），系并发值捕获语义差异，待单查。
- 剩余回退 11：trait/impl 运行时分派（phase2/phase5/phase7/edge_*_traits/cond_impl）+ 跨文件 use
  （stdlib_*/test_module_trait）+ 顶层 val/var（phase1）+ record（edge_value_semantics）。

**M5f — 索引赋值 COW（22→23）✅ 已完成**
把真跑 VM 的项目从 22/33 提到 **23/33**（edge_value_semantics 新增），全程 33/33 不回归、
edge_value_semantics 输出与树遍历器逐行一致（含别名独立 / 多层别名链 / 数组嵌套记录共享等 COW 回归）：
- **OP_SET_INDEX**（无操作数）：栈 `[array, index, val] → [new_array]`。compiler 的 `.assignment`
  语句 target 是 `.index` 时走新 `emitIndexAssign`（identifier 数组目标：GET_LOCAL → index → val →
  SET_INDEX → SET_LOCAL 写回；临时对象：obj → index → val → SET_INDEX → POP）。VM `doSetIndex`
  镜像 `doSetField` 的 COW：rc>1 浅拷分裂（元素 retainOwned）+ 原体 rc-1，越界/非数组/非整数索引
  panic，旧元素 release + val owned move。
- 此前 edge_value_semantics 唯一回退原因是 `c[0] = 99` 索引赋值 Unsupported（field_assignment
  早已支持，index 赋值缺失）。
- 门禁：zig build test（170 VM 单测，+2 M5f：索引读写 / COW 别名独立，无泄漏）；Debug VM-on/off
  33/33；ReleaseFast 33/33。
- 剩余回退 10：全部需 trait/impl 运行时分派（phase2/5/7/edge_*_traits/cond_impl）或跨文件 use
  （stdlib_*/test_module_trait）或顶层 val/var（phase1）。

**M5g — 顶层 val/var 全局变量（23→24）✅ 已完成**
把真跑 VM 的项目从 23/33 提到 **24/33**（phase1 新增），全程 33/33 不回归、phase1 输出与树遍历器
382 行逐行一致（含 ReleaseFast）：
- **全局存储**：VM 加 `globals: ArrayListUnmanaged(Value)`（`call` 时按 `program.global_count`
  预留 unit 占位，`deinit` release）。Program 加 `global_count` + `globals_init: ?u16`。
- **opcode**：`OP_GET_GLOBAL <u16 idx>`（retainOwned globals[idx] 压栈）/ `OP_SET_GLOBAL <u16 idx>`
  （弹 owned 写入，旧值 release）。
- **compiler**：ModuleCompiler 加 `global_table`（name → idx + is_mutable）+ lookupGlobal。第一遍登记
  顶层 expr_decl 的 val_decl/var_decl（裸表达式 stmt==null 不登记，文档 D13）。第二遍编译完函数体后，
  若有全局则 `compileGlobalsInit` 生成零参初始化函数（按声明顺序求值 RHS + 注解定型 + OP_SET_GLOBAL），
  记入 `program.globals_init`。
- **VM.call 改造**：先预留 globals + 运行 globals_init（用 `callNoArgs` + stop_depth 边界，镜像
  forceLazyVM）再建 main 入口帧。标识符/赋值全路径接全局（local → upvalue → fn → ctor → **global**）：
  identifier 读、`.assignment`、`assignment_expr`、compound_assignment（GET+arith+SET，顶层全局非
  spawn 捕获故无 atomic 透明）、emitFieldAssign（g.f=v COW 写回）、emitIndexAssign（g[i]=v COW 写回）。
  main.zig vmEligible 放行带 val_decl/var_decl 的 expr_decl。
- 门禁：zig build test（173 VM 单测，+3 M5g：全局 val 读 / var 跨调用变更 / 复合赋值，无泄漏）；
  Debug VM-on/off 33/33；ReleaseFast 33/33。
- glue debug VM 路径 LEAK：VM-on 报大量 leak（phase1 5518），但属 VM 路径既存（stress_database
  自 M5c 起跑 VM 同样 VM-on>0；最小 globals 复现 VM-on=80 ≤ VM-off=82，证非 globals 引入），系 VM
  执行路径既存问题（println 循环 string churn 等），权威 leak 门禁（testing.allocator 单测）干净。
- 剩余回退 9：trait/impl 运行时分派（phase2/5/7/edge_pattern_trait_safety/edge_records_traits/
  cond_impl）+ 跨文件 use（stdlib_compare/stdlib_list/test_module_trait）。下一里程碑攻 trait/impl（覆盖 6）。

**M5h — 顶层 trait 声明放行（24→25）✅ 已完成**
把真跑 VM 的项目从 24/33 提到 **25/33**（phase7 新增），全程 33/33 不回归、phase7 输出逐行一致：
- phase7 只用 inline trait 值（M4d 已支持，自带 vtable）+ 顶层 `trait Logger` 声明 + lazy，**无 impl**。
- VM 编译器第一遍早已 `else => {}` 跳过 trait_decl（无运行时效果）；唯一阻塞是 main.zig vmEligible 把
  trait_decl 归入 `else => return false`。修复 = vmEligible 放行 `.trait_decl => {}`。
- 关键安全性：含 impl 的模块仍回退（impl_decl 命中 vmEligible 的 `else`）——trait 默认方法仅经 impl
  分派可达，无 impl 时不可达，故放行 trait 声明安全；inline trait 值实现全部方法，不依赖 trait 注册表。
  验证 phase2/phase5/edge_pattern_trait_safety/edge_records_traits/cond_impl（均含 impl）确认仍回退。
- 门禁：zig build test（173 VM 单测，无新增，纯 eligibility 放行）；Debug VM-on/off 33/33；ReleaseFast 33/33。
- 剩余回退 8：impl 运行时分派（phase2/5/edge_pattern_trait_safety/edge_records_traits/cond_impl，5）
  + 跨文件 use（stdlib_compare/stdlib_list/test_module_trait，3）。impl 分派是下一最大块（覆盖 5）。

**M5i — impl 方法运行时分派（25→27）✅ 已完成**
把真跑 VM 的项目从 25/33 提到 **27/33**（edge_pattern_trait_safety + edge_records_traits 新增），
全程 33/33 不回归、两项输出逐行一致：
- **impl 方法表**：Program 加 `impl_methods`（ImplMethodDesc{type_name, method_name, trait_name,
  func_idx}）+ `trait_defaults`。compiler 第二遍把每个有 body 的 impl/trait 方法编成顶层零捕获
  Function（self+params 占 slot 0..），登记进表。
- **方法语法分派**：VM doCallMethod 在 native method.dispatch 前先查 impl_methods（receiver 类型名 +
  方法名，**数值宽度互通**：字面量 5→i8 匹配 impl<i32>，镜像 eval）；命中走 `invokeMethodBody`
  （receiver+args 已在栈顶作 slot 0..，建帧 + stop_depth 边界跑到 RETURN）。未命中查 trait_defaults。
- **自由函数式 trait 方法**（with-clause 约束的 `compare(a,b)`）：ModuleCompiler 第一遍登记 method_names；
  emitCall 裸名命中且 argc≥1 → 发 OP_CALL_METHOD（receiver=arg0，argc-1），复用分派。
- main.zig vmEligible 放行 `.impl_decl => {}`。
- 门禁：zig build test（176 VM 单测，+3 M5i：ADT receiver 分派 / trait 默认方法回退 / 自由函数式
  trait 方法，无泄漏）；Debug VM-on/off 33/33；ReleaseFast 33/33。
- 剩余回退 6：phase2（nullary trait 方法 `zero()`，需返回类型导向分派）、phase5（monad/HKT）、
  cond_impl + stdlib_compare/stdlib_list/test_module_trait（跨文件 use 导入）。下一可攻：跨文件 use（覆盖 4）。

**M5j — 单段 `use` 跨文件导入（27→30）✅ 已完成**
把真跑 VM 的项目从 27/33 提到 **30/33**（stdlib_compare + stdlib_list + cond_impl 新增），全程
33/33 不回归、三项输出逐行一致：
- **依赖 AST 收集**（eval.zig）：`collectUseDependencies`（递归传递依赖，按模块名去重，依赖先于入口入
  列表保证定义先于使用）+ loadDependencySource（项目文件优先，回退内嵌 stdlib）+ parseDependencyModule
  （仅词法+语法，不类型检查/不 resolve——VM 按名字字符串自包含解析）。token 集合存新字段
  retained_token_sets（AST 借用），持有到 deinit。
- **多模块编译**（compiler.zig）：compileModule 重构出 registerDecls/compileBodies，新增
  `compileModuleWithDeps(entry, deps)`——deps 先注册+编译（stdlib trait/impl/fn 合并进**同一 Program**，
  扁平 impl 表天然合并），再 entry。fun 同名去重。顶层 val/var 仅入口。
- main.zig：vmEligible 放行单段 `.use_decl`（多段路径仍回退）；tryRunOnVM 调 collectUseDependencies +
  compileModuleWithDeps。
- 条件 impl（`impl Show<Box<T>> with Show<T>`）无需特殊处理：VM 扁平 impl 表 + 数值宽度互通已覆盖
  （条件约束是类型检查期概念，运行期只按 receiver 类型名查方法，cond_impl 嵌套 Box 递归分派即生效）。
- 门禁：zig build test（177 VM 单测，+1 M5j：跨模块 dep impl+fn 合并）；Debug VM-on/off 33/33；ReleaseFast 33/33。
- 剩余回退 3：phase2（nullary trait 方法 `zero()` 返回类型导向分派）、phase5（monad/HKT）、
  test_module_trait（多段 use `Store.Memory` + pack 子模块值）。均需各自较重的专门机制。

首版（栈式 + 64B Value）预期消灭瓶颈 1/2/3（递归调用 / tag switch / try 传播），
保守预估 **3–8× 墙钟**。各 bench 预期：
- **fib**（调用密集）：CallFrame 复用 + 无 per-node 递归，预期收益最大。
- **lookup**（变量查找密集）：slot 数组索引替代哈希 + 无递归分发，De Bruijn 翻盘。
- **record**（复合值 churn）：受 Value 宽度 + refcount 主导，VM 收益相对小（瓶颈 4 未动）。

**VM 之后的后续优化（独立项，按收益排序）**：
1. **NaN-boxing / Value 瘦身**（瓶颈 4）：64B → 8–16B，栈拷贝成本骤降，record 类受益最大。
2. **computed-goto / threaded dispatch**：Zig 用 `inline switch` 或标签指针消除 switch 跳转表开销。
3. **superinstructions**：合并高频 opcode 对（如 GET_LOCAL+GET_LOCAL+ADD）减少分发次数。
4. **常量折叠 / DCE 字节码 pass**：编译期优化（对无冗余热循环无效，对真实冗余有效）。
5. **inline caching**：方法分派 / 字段访问的单态内联缓存。

---

## 11. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 内存模型搬运出错（double-free/leak/UAF） | 高 | §6 栈不变式纪律 + 每 opcode --gpa 单测 + ReleaseFast 单独跑；string 一律 retainOwned |
| 闭包 cell 捕获在 VM 下漂移 | 高 | M1 专门验 makeCounter/逃逸闭包；编译期判定哪些 var 装箱 |
| 双路径长期漂移（VM/树遍历语义不一致） | 中 | 回退仅作临时脚手架；M5 尽早删旧路径；同一套回归测两路径 |
| TCO 帧复用误判尾位置 | 中 | 沿用现 preserves_tail 规则；尾递归深度测试（countDown 大 N 不爆栈） |
| 并发协程下 VM 状态保存 | 中 | 依赖 zio stackful（VM 跑在协程栈，让出由 zio 处理，无需手动保存）—— 同现机制 |
| match 复杂模式编译错漏 | 中 | 复用 pattern.zig 判定逻辑；穷尽性靠 sema；运行时 MATCH_FAIL 兜底 |
| 编译器 bug 静默生成错字节码 | 中 | disasm 黄金文件测试 + 每节点小程序 round-trip 验证 |
| 工期超预期（核心求值器重写） | 中 | 分 M0–M5 增量交付，每阶段独立可用可验证，可随时暂停 |

---

## 12. 验证门禁（每里程碑必跑）

1. `zig build test` — 单元测试（含新增 opcode/compiler/disasm 单测）全过。
2. `bash run_tests.sh` — Debug 构建 33/33（或当前总数）全绿。
3. **ReleaseFast 单独跑全套**（不经 run_tests.sh）— 捕获 ReleaseFast-only 崩溃。
4. `--gpa` churn 测试（record / string-array / 闭包 loop=5000）— 无 leak / double-free。
5. 三 bench（fib/lookup/record）对照基线 — 正确值 + 墙钟记录进 BASELINE.md。
6. 并发用例（M4 起）ReleaseFast 全绿。

> 已知既存问题：`edge_recursion_methods` 在 ReleaseFast 下 teardown segfault（记忆
> `glue-perf-baseline-and-bugs` Bug2，与 VM 无关）。VM 迁移时可顺带排查是否消失
> （VM 帧管理替换树遍历器 teardown，可能恰好绕过该 UAF）。
