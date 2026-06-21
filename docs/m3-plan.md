# M3 计划 — 控制流 / 异常 / 方法（字节码 VM，分四片增量交付）✅ 全部完成

承接 M2（复合值 / 模式匹配，record bench 10×）。M3 把"除并发外"的语言特性补齐到 VM。
四片（M3a 字符串+转换 / M3b 控制流补全 / M3c 异常+传播+defer / M3d 方法+for）均已交付，
门禁全绿（VM 单测全过、回归 33/33、ReleaseFast 单测全过）。
范围（`docs/bytecode-vm-plan.md` §9 M3 原文）：
> throw/Throw 传播 + handler 表、propagate `?`、non-null `!`、defer、break/continue、
> 方法调用（回调现 callMethod）、字符串插值、type_cast、for/while/loop。
> 交付：除并发外的 tests/* 全部走 VM 通过。

## 不变量（沿用 M1/M2）
- VM 消费 type-checked AST（生产路径）；独立单测用类型后缀锁字面量类型。
- 复用 `value.zig` 既有值表示 + format/retain/release/clone，**零语义漂移**。
- 每片结束门禁：`zig build test` 全绿无泄漏 + `bash run_tests.sh` 33/33 + Debug+ReleaseFast exe 重建。
- VM 未实现的节点 → 编译器返回 `error.Unsupported`（该函数整体回退树遍历器，零长期破窗）。
- 内存：沿用 §6.1 栈所有权不变式（压栈 +1 / POP release / string 一律 retainOwned）。

## 关键约束（已勘定）
- **方法调用不回调 eval.callMethod**：该函数 ~1000 行且深耦合 `*Evaluator`（self.allocator/
  value_allocator/gluePanicFmt/callFunction）+ eval 的 GC/arena 内存模型，与 VM refcount 模型冲突。
  VM 在 `src/vm/method.zig` 重新实现内建方法（len/push/pop/...），用 VM 的 refcount 纪律。
  trait/impl 用户定义方法在 M4（需 trait 值降级），M3 仅覆盖内建方法 + 字符串/数组方法。
- **cast 逻辑搬运**：castInteger/castFloat/clampInt 是纯 value→value（除 gluePanic），
  在 `src/vm/cast.zig` 重新实现，溢出走 VM 的 fail（runtime panic）。
- **异常用显式 handler 表，不用 Zig error**：throw/propagate 触发 VM 主循环内的 unwind
  （沿 CallFrame 栈找 handler），与 eval 的 `error.ThrowValue` 完全不同的机制（§7.2）。

---

## M3a — 字符串 + 类型转换（自包含，最低风险）✅ 已完成

**目标**：string_literal / char_literal / string_interpolation / type_cast 四节点走 VM。**已达成**。

实现要点（与计划一致）：
- **OP_CONST 复用**：string（dupe owned）/ char 字面量进常量池。
- **OP_INTERP `<u16 n>`**（vm.doInterp）：literal 文本段编译期压成 string 常量，expression 段求值；
  VM 弹 n 段依次 `Value.format`（与 eval 同路径，零漂移）拼接，**format 后**再统一 release 各段
  （format 借用内容，须先拼后放），结果 push。
- **OP_CAST `<u16 type_name_const>`**（vm.doCast + 新 `src/vm/cast.zig`）：str→format；
  数值互转 castNumeric（镜像 eval castInteger/castFloat/clampInt/floatToInt，纯 value→value）；
  narrowing 溢出 → error.CastOverflow → VM fail（ArithmeticOverflow，对齐 eval gluePanic 消息）。
- cast.zig 自包含（仅依赖 value），3 个单测；compiler test{} 加 refAllDecls(cast.zig)。
- 门禁全绿：VM 单测 +8（string 字面量/插值×2/cast widening/float→int/int→str/溢出 panic/插值 churn 1000 次
  无 leak），`zig build test` 全过，回归 33/33（Debug+ReleaseFast），Debug+ReleaseFast exe 重建。
  ReleaseFast 唯一失败是既存 `edge_recursion_methods` teardown segfault（树遍历器 Bug2，与 VM 无关）。

## M3b — 控制流补全（break/continue/loop + 复合赋值 + 字段赋值）✅ 已完成

**目标**：loop_stmt / break_stmt / continue_stmt / compound_assignment / field_assignment 走 VM。**已达成**。

实现要点（与计划一致）：
- **LoopCtx 栈**（FnCompiler.loops）：每循环 push `{continue_target, breaks[]}`，嵌套自然支持。
  关键洞察：local 是帧入口预分配的定长 slot（非操作数栈增长），block 退出仅缩编译期 locals 追踪、
  不动运行时栈 → break/continue 在语句边界天然栈平衡，**无需插 OP_POP_N**。
- **break**：OP_JUMP 入 breaks[]，循环末尾统一回填到 cond 弹出后（栈平衡处）。
- **continue**：emitLoopBack 回跳 continue_target（while=条件起点，loop=体起点）。
- **loop_stmt**：`start: body; pop; jump start`，仅 break 退出。
- **compound_assignment**（emitCompoundAssign）：脱糖 `x = x op v`（local/upvalue），
  GET → v → 算术 op → SET。Atomic 透明操作留 M4。
- **field_assignment**（emitFieldAssign + OP_SET_FIELD）：identifier 目标 GET_LOCAL → v →
  SET_FIELD → SET_LOCAL 写回；临时对象 → POP 丢弃。**OP_SET_FIELD 栈效果 [record,val]→[new_record]**：
  COW（rc>1 浅拷分裂，type_name 复用借用 slice 不 dupe 防泄漏）+ 字段覆盖（旧值 release，val owned move）。
  值语义（`b=a; b.x=99` 不影响 a）由 COW 保证。
- 门禁全绿：VM 单测 +8（while+break/continue、loop+break、嵌套循环、复合赋值 +=−=*=%=、
  字段赋值、COW 值语义、loop+字段+复合赋值 churn 1000 次无 leak），`zig build test` 全过，
  回归 33/33（Debug），ReleaseFast 单测全过，Debug exe 重建。

## M3c — 异常 / 传播 / 非空断言 / elvis / defer ✅ 完成

**⚠️ 重大架构修正**（实现前勘定，推翻原计划的 handler 表设计）：
Glue **没有 try/catch**。错误是**值**：函数返回 `Throw<T,E>`，`throw e` 等价于
**返回一个 `throw_val.err`**（不跨帧 unwind），调用方用 `?` 显式传播或 `match` 解包 Ok/Error。
eval 印证：throw 设 throw_value + `error.ThrowValue`，但该错误**只传播到本函数调用边界**就变成
返回值（eval.zig:3578-3589）。故 **VM 不需要 handler 表 / 多帧 unwind**——
`OP_THROW ≈ OP_RETURN`（返回值是 throw_val.err）。这大幅简化 M3c。

**⚠️ 第二个架构发现（所有权模型）**：`Value.retain`/`release` 对 `throw_val`/`error_val`
是 **no-op**（eval 用 GC 疏散管理它们，nursery→old-gen，见 eval.zig:915）。但字节码 VM 是
**纯 refcount**。直接改 `release` 释放它们会让 eval GC double-free。解决：新增 **`Value.releaseVM`**
（仅 VM 调用，值语义深释放 throw_val/error_val 壳 + 错误字符串，嵌套值递归；其它类型委托 release），
VM 所有 release 站点（47 处）改走 releaseVM；`retainOwned` 对应深拷壳（值语义，无共享 → 无 double-free）。

已完成（门禁全绿：VM 单测 +12，`zig build test` 全过，回归 33/33，ReleaseFast 单测全过）：
- **Ok/Error → Native**（OP_CALL_NATIVE 扩 .ok/.err）：Error(msg)→throw_val.err{type_name="Error"}；
  Ok(v)→throw_val.ok（retainOwned v 自留）。
- **OP_THROW**：弹 throw 值，走 frameReturn（= OP_RETURN 路径，释放本帧局部 + 返回值移交）。
- **OP_PROPAGATE `?`**：null→提前返回 null；throw_val.err→提前返回该 throw_val；
  throw_val.ok→解包 inner（retainOwned）；其它原样。frameReturn 公共逻辑已抽出。
- **OP_NON_NULL `!`**：null→VM panic（新 error.NonNullAssertFailed）；否则原样。
- **`??` elvis**（emitBinary + OP_JUMP_IF_NOT_NULL）：left 非 null 短路用 left，否则弹后求值 right。
- **match Ok(v)/Error(e)**（OP_TEST_THROW 弹测 + OP_GET_THROW_OK/ERR 解包绑定）：
  Ok→inner，Error→error_val（包 ErrorValue）。`e.message`/`e.type_name` 经 doGetField error_val 分支。
- frameReturn 重构：OP_RETURN/THROW/PROPAGATE 共用，避免三处复制帧退出逻辑。

**defer 已完成（M3c-defer）**：block 作用域，LIFO，覆盖正常退出 / return / throw / break /
continue；defer 体内联重放字节码（读当前 slot → 见退出时的当前局部值，`var x=1; defer ...x; x=2`
重放见 2）。编译器侧 `defer_scopes` 栈：含 defer 的 block push 一层，emitBlock/emitTail-block
正常退出按 LIFO `replayTopDeferScope`；return/throw 前 `replayAllDefers`（禁尾调用）；break/continue
按 `replayDefersFrom(loop.defer_depth)` 重放循环体内层。`assignment_expr`（`defer x = v` 解析产物）
新增 emitExpr 支持（dup 值：一份写 slot，一份作表达式值）。`?` 传播早退在 OP_PROPAGATE 内部，
绕过 defer 重放 → 有活跃 defer 时 `?` 退回 eval（正确性优先，已注释标注）。顶层 defer 暂不支持。
门禁：正常退出 / 见当前值 / LIFO / return 前 / 函数体作用域 / throw 路径 / 循环每轮 / churn 共 8 单测全绿。

## M3d — 方法调用 + for 循环 ✅ 完成

**目标**：method_call / safe_access / safe_method_call / for_stmt 走 VM。

已完成（门禁全绿：VM 单测 +16，`zig build test` 全过，回归 33/33，ReleaseFast 单测全过）：
- **OP_CALL_METHOD `<u16 name_const><u8 argc>`**：栈布局 [receiver, args..]，新建 `src/vm/method.zig`
  分派内建方法（`len`/`is_empty`/`push`/`pop`/`first`/`last`/`contains`/`drop_last`，数组 + 字符串
  子集，镜像 eval callMethod）。纯 refcount 纪律：receiver/args 为栈 owned，dispatch 不持有
  （仅 retainOwned 需保留的元素入结果），调用方弹栈后 releaseVM。`len()` 字符串按 Unicode 标量计数。
  未知方法/类型不符/参数数错 → VM panic。并发/原子方法（send/recv/cas/swap/await/...）留 M4。
- **safe_access `?.field` / safe_method_call `?.m()`**：新增 OP_JUMP_IF_NULL（peek null 跳转，不弹，
  OP_JUMP_IF_NOT_NULL 的对偶）。receiver null → 短路保留 null；非 null → OP_GET_FIELD / OP_CALL_METHOD。
- **for_stmt**：`for x in iter { body }` —— iter 求值存隐藏 slot + index slot(i64=0)；
  新增 OP_FOR_NEXT `<u16 iter_slot><u16 idx_slot><i32 exit_off>`（运行时按 array/range/string 分派：
  耗尽跳 exit；否则压当前元素 retainOwned + idx++）。复用 break/continue 机制（含 defer_depth 重放）。
- **范围 `a..b` / `a..=b`**：新增 OP_MAKE_RANGE `<u8 inclusive>`（弹 [start,end] 压 range 值），
  emitBinary 扩 .range/.range_inclusive。for-in-range 直接迭代，无需先物化数组。
- 门禁：数组/字符串 len、push/contains/is_empty/drop_last 链式、未知方法 panic、for-in-array、
  for-in-range（开/闭区间）、break/continue、嵌套 for、safe access（非空/null 短路）、churn 共 16 单测全绿。

---

## 风险（M3 特有）
- **异常 unwind 内存正确性**（M3c）：unwind 跳过的每帧局部必须 release + defer 必须跑，
  漏 release → leak，多 release → double-free。每路径 --gpa 单测，throw 穿多帧 churn 压测。
- **方法重新实现漂移**（M3d）：VM method.zig 与 eval callMethod 语义须一致（同样的 len 语义、
  push 返回新数组等）。对照 eval 实现逐方法核对 + 回归测试覆盖。
- **defer 与 TCO 交互**：尾调用复用帧时若有未跑 defer → 须先跑。tryEmitTailCall 遇 defer 作用域退回 OP_CALL。
- **for_stmt 脱糖**：M3d 仅覆盖数组/range 快路径；用户 Iterable 留 M4，遇到 → Unsupported 回退。
