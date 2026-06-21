# M4 计划 — 并发 / 收尾特性（字节码 VM）

承接 M3（控制流 / 异常 / 方法，四片全绿）。M4 把并发原语 + 收尾特性补齐到 VM。
范围（`docs/bytecode-vm-plan.md` §8 / §9 M4 原文）：
> spawn / atomic / channel / select、lazy、monad comprehension、inline trait value、模块 trait 值。
> 交付：edge_concurrency* 等并发用例 ReleaseFast 全绿；33/33 全部走 VM。

注：M4 的"33/33 全走 VM"门禁依赖 M5 把 VM 接入 `glue run`（当前 run_tests.sh 走 eval，
VM 仅 compiler.zig 单测覆盖）。M4 阶段以 **VM 单测端到端验证 + eval 回归不退化** 为准。

## 不变量（沿用 M1/M2/M3）
- 运行时（zio/scheduler/channel/spawn/atomic）**完全不动**，VM 仅改"协程体如何执行"。
- 编译器遇未实现节点 → `error.Unsupported`，该函数整体回退树遍历器（零破窗）。
- 语义零漂移：复用 value.zig 的算术/比较/类型逻辑；VM 单测对照 eval 行为。

## 关键架构勘定（M4a 已确认）
- **共享并发值的所有权**：atomic/channel/sender/receiver/spawn 在 eval 走 GC（release no-op），
  协程间共享。VM 纯 refcount 下若 releaseVM 直接销毁会 double-free。**AtomicValue 自带原子
  `ref_count`（ref/unref）** —— VM 用它：retainOwned → `av.ref()` 返回别名；releaseVM → `av.unref()`
  归零 destroy。跨协程安全（原子计数）。channel 等同理（待 M4b 确认其 ref_count）。
- **atomic 读取透明 vs 方法接收者**：eval 读取 atomic 标识符自动 `load()` 出标量，但方法调用
  （cas/swap）取**原始** Atomic。VM 无编译期类型信息 → 运行时分派：`OP_GET_LOCAL`/`OP_GET_UPVALUE`
  对 atomic_val 透明 load（与 cell 解包同一分支，无额外热路径负担）；方法接收者经
  `OP_GET_LOCAL_RAW`/`OP_GET_UPVALUE_RAW` 取原始值。
- **atomic 复合赋值**：`c += n` 在 atomic 上是**就地** fetch<op>（不重写 slot）。VM 无类型信息 →
  `OP_COMPOUND_LOCAL <slot><arith_op>` 运行时分派：slot 持 atomic → 原子 fetch（add/sub/mul/and/or
  直接，div/mod 走 CAS 循环）；否则常规读改写。

## M4a — atomic（自包含，无协程）✅ 完成

**目标**：atomic_expr 构造 + 透明读取 + 复合赋值 + cas/swap 方法走 VM。

已完成（门禁全绿：VM 单测 +8，`zig build test` 全过，回归 33/33，ReleaseFast 单测全过）：
- **OP_MAKE_ATOMIC**：弹值（int/float/bool/char）包成 AtomicValue（ref_count=1）压 atomic_val。供 `atomic e`。
- **OP_GET_LOCAL / OP_GET_UPVALUE**：扩 atomic_val 透明 load 分支（一般读取出当前标量）。
- **OP_GET_LOCAL_RAW / OP_GET_UPVALUE_RAW**：方法接收者用，不透明 load（cas/swap 需原始 Atomic）。
  compiler `emitMethodReceiver` 对 identifier 接收者发 raw 读取。
- **OP_COMPOUND_LOCAL `<u16 slot><u8 arith_op>`**：Atomic 透明复合赋值运行时分派（见上）。
- **cas / swap 方法**：method.zig dispatch 扩 atomic_val 分支（cas → bool；swap → 旧值）。
- 所有权：retainOwned `av.ref()` / releaseVM `av.unref()` 归零 destroy（value.zig releaseVM 扩分支）。
- 门禁：读取透明、复合 add/sub、cas 成功/失败、swap、cas 后读新值、churn(1000) 共 8 单测全绿。

---

## M4b — channel ✅ 完成

**目标**：channel<T>(cap) 构造 + send/recv/close 方法走 VM，阻塞点 yield 给 zio 调度器。

已完成（门禁全绿：VM 单测 +8，`zig build test` 全过，回归 33/33，ReleaseFast 单测全过）：
- **channel(cap) 构造**：`channel` 加进 Native 枚举，`doCallNative` 弹整数容量建 ChannelValue
  （ref_count=1）压 channel_val。复用现 channel 运行时（mutex/condition 不动）。
- **send/recv 方法**（method.zig dispatch 扩 channel_val/sender_val/receiver_val 分支）：
  - `send(v)` → 把 v `retainOwned` 进缓冲（调用方随后 release 实参），关闭则 ChannelClosed → VM panic。
  - `recv()` → 缓冲值所有权**转出**（不再 retain），关闭且空 → null。
  - `sender.close()` 关闭通道；Channel 本身无 close（仅 Sender，与 eval 一致）。
- **方向类型字段**：`ch.sender` / `ch.receiver`（doGetField 扩 channel_val 分支，各 ref channel + 新包装）。
- **所有权**（value.zig releaseVM + vm.zig retainOwned 扩分支）：channel/sender/receiver 内建原子
  ref_count。channel 归零 deinit+destroy（清理未消费缓冲，无泄漏）；sender/receiver 轻包装各持
  一个 channel ref + 自身分配，unref channel 后销毁包装；retainOwned 对 sender/receiver 新分配包装。
- 门禁：缓冲 send/recv、FIFO 顺序、关闭后空 recv→null、sender/receiver 分离、关闭后排空缓冲、
  字符串通道（leak-checked）、churn(500)、丢弃含未消费缓冲的通道（leak-checked）共 8 单测全绿。

注：channel.deinit 用 value.deinit（硬递归释放）清理残留缓冲值。标量/字符串通道无虞；
含共享 rc 的数组/record 入通道再丢弃属边界（deinit 忽略 rc），M4c/真实并发用例再核。

---

## M4c — spawn ✅ 完成（实 OS 线程模型）

**目标**：spawn { body } 编译成独立 Function，协程内起新 VM 执行上下文。

**架构决策**（用户拍板：实 OS 线程，而非同步执行）：VM 纯 refcount，array/record 用**非原子** rc，
跨线程 retain 会 race；atomic/channel 用**原子** ref_count 跨线程安全。故每个 spawn 起 std.Thread，
子 VM 用 per-spawn arena（page_allocator 裸打底）分配 → 与父/兄弟协程**内存隔离**（正是 eval 给每协程
独立 GC heap 的同款理由）。捕获深拷进 arena；await 时结果跨线程深拷回父 allocator（race-free：仅 worker
完成后父线程读 arena）。channel 协调 spawn 真并行（阻塞点走 std.Thread.Futex）。

已完成（门禁全绿：VM 单测 +8，`zig build test` 全过 ×5 无 race/leak，回归 33/33，ReleaseFast 全过）：
- **OP_SPAWN**：弹 body 编译的零参 vm_closure，深拷捕获（`deepCopyAcross`）进 arena，起 std.Thread
  跑子 VM（`spawnThreadEntry` → `callClosureBody`），压 spawn_val。失败仍压 handle（status=Failed）。
- **deepCopyAcross**（value.zig 新增）：跨线程**完整**深拷 —— array/record 重新分配递归拷（不 retain，
  非原子 rc 跨线程不安全）；string dupe；atomic/channel/sender/receiver **共享**（原子 ref_count 安全）；
  closure/trait/lazy/iterator → error.Unsupported（spawn body 捕获到这些则该函数回退树遍历器）。
- **await / cancel**（doSpawnMethod）：await 挂起等 worker（ZioCondition futex 回退），结果深拷回父
  allocator，Failed → SpawnFailed panic；cancel 标记取消。spawn_val 生命周期归 VM.spawns（非 refcount）。
- **OP_COMPOUND_UPVALUE**：spawn body 里 `counter += 1`（捕获的 Atomic）必经此路 —— cell.inner 持
  atomic → 原子 fetch<op>，**不可**退化为标量覆盖（否则子线程把共享 atomic 覆写成本地 int，丢失累加）。
- **VM.deinit**：join 所有 worker（保证不再触碰 handle/arena），releaseCapture 平衡捕获对共享原语
  加的 ref，再 arena.deinit + 释放 handle/ctx。
- **关键修复（兼修 M1b）**：releaseVM 对 vm_closure/cell_val 之前 fallthrough 到 release()，后者对
  atomic/channel 是 no-op → 捕获进 cell 的并发原语 ref_count 不递减而泄漏。新增 releaseVM 的
  vm_closure/cell_val 分支递归 releaseVM（归零深释放内层）。M1b 闭包同获益。
- 门禁：纯计算 spawn+await、多 spawn 独立、捕获快照、atomic 跨线程共享、并发累加(2×1000→2000)、
  字符串结果深拷、churn(50)、channel handoff 共 8 单测全绿（×5 无 race/leak）。

---

## M4d — select / lazy / inline-trait ✅ 完成

**目标**：select 多路复用、lazy 透明 force、inline trait 值方法分派。（monad_comprehension 不在门禁内
——它 desugar 成 flatMap 链，留 eval 路径；VM 见到则该函数回退树遍历器。）

三特性各自独立、规模相当于前序切片。已完成（门禁全绿：VM 单测 +16，`zig build test` ×5 无 race/leak，
回归 33/33，ReleaseFast 全过）：

**lazy（6 单测）** —— 透明 force + 缓存：
- expr 编成零参闭包（自动捕获），OP_MAKE_LAZY 包成 lazy_val（复用 LazyValue，加 vm_thunk/rc 字段，
  eval 模式 vm_thunk==null 不受影响）。OP_GET_LOCAL/UPVALUE 读到 vm 模式 lazy → forceLazyVM。
- **forceLazyVM 用 stop_depth 边界嵌套运行**：新增 VM.stop_depth，frameReturn 弹回此深度即返回（默认 0
  = 入口帧，旧语义不变）。force 时临时设为当前深度跑 thunk 到完成，缓存结果。thunk 内嵌套调用压更深帧、
  其 RETURN 深度 > stop_depth 不误触发——语义正确。缓存生效（thunk 仅首次跑）、never-forced 无泄漏均验证。

**select（5 单测）** —— 镜像 eval 三段式（无 spin loop，确定性 VM-parity）：
- 新增 OP_TRY_RECV（非阻塞，压 [value, flag]）+ OP_RECV（阻塞，压 value）。channelOf 从
  channel/sender/receiver 取底层 *ChannelValue。
- emitSelect：① poll 各 recv arm（OP_TRY_RECV + jump_if_false 链，绑定走临时 local slot）；② 无就绪
  则首个 timeout arm body（duration 求值丢弃——VM 无定时器，超时即默认分支）；③ 无 timeout 则阻塞
  OP_RECV 首个 recv arm。双通道、timeout 回退、spawn-producer 解阻塞、both-ready 取首 arm 均验证。

**inline trait（5 单测）** —— vtable 方法分派：
- 各方法体编成带 arity 的 Function（params 占 slot，自动捕获 enclosing 为 upvalue），
  [name(const), OP_CLOSURE] 顺序压栈，OP_MAKE_TRAIT `<count>` 弹对建 vm_owned trait_value（vtable）。
- doCallMethod 截获 vm_owned trait_value → doTraitMethod：vtable 查 name 得 vm_closure，替换 receiver
  槽（retainOwned，vtable 持母本），边界嵌套运行（同 forceLazyVM 套路）跑方法体，结果压栈。
- TraitValue 加 vm_owned/rc 字段（eval 模式 vm_owned==false，releaseVM no-op 交 GC；VM 模式归零释放
  vtable key + vm_closure + 箱体）。捕获 enclosing、多方法、churn 无泄漏、重复调用均验证。

**关键基建**：releaseVM 的 vm_closure/cell_val/lazy_val/trait_value 分支递归 releaseVM（非 release
no-op），retainOwned 对 vm 模式 lazy/trait 走 rc+1。stop_depth 嵌套运行机制为 lazy force 与 trait
分派共用。

---

## 风险（M4 特有）
- **协程内 VM 状态**：zio stackful 协程 → VM 循环跑在协程自己栈上，让出由 zio 处理，无需手动
  保存（与现树遍历器同理）。降低集成风险。
- **共享值 double-free**：已由 AtomicValue 原子 ref_count 化解（M4a）；channel/spawn 待逐一确认。
- **deepCopy 捕获**：spawn 深拷贝捕获语义在 VM 下需对接（captures 是 VM 栈/cell，非 Environment）。
