# M1b 计划 — 一等函数值 / 柯里化 / 闭包 / TCO（分三片增量交付）

承接 M1a（顶层调用 + CallFrame 栈，fib 36×）。M1b 是全 VM 最高风险一步：
触动**共享** `value.Value` union（eval 与 VM 同用），故拆成三片，每片独立测试门禁 + 回归 33/33。

## 关键约束（已勘定）
- 循环依赖：`chunk.zig` import `value` → `value.zig` **不能** import chunk。
  VM 闭包变体存 `*const anyopaque`（函数指针），VM 内 `@ptrCast` 还原（同现有 `Closure.env`）。
- `value.Value` 的 retain/release/clone/deinit/equals 都有 `else =>` 兜底 → 加变体可编译，
  但**必须**为新变体补显式 arm（refcount 正确性）。`format` 等无 else 的 exhaustive switch 需补 arm。
- 柯里化语义（镜像 eval callFunction）：`args < arity` → partial；`==` → 调用；`>` → WrongArity。

---

## M1b-1 — 一等函数值 + 栈式调用 + 默认柯里化（无捕获）✅ 已完成

**目标**：函数名可作值传递/返回；`OP_CALL_VALUE` 从栈顶取 callee 调用；参数不足产生部分应用。
不含 upvalue 捕获（留 M1b-2）——即只支持顶层函数作一等值。

### 实测落地（与原计划差异）
- **柯里化不复用 eval 的 `PartialApplication`**：eval 那个是 GC/arena 管理（无 rc，靠 evacuate），
  VM 是 refcount 管理，混用会双重内存模型 / 双重释放。改为**把 bound_args 折进 VmClosure**：
  `VmClosure{func, arity, upvalues, bound_args, rc, allocator}`，一个变体同时承载闭包 + 部分应用。
  `bound_args.len + argc == arity` → 调用；`<` → 产 bound_args 更长的新 vm_closure；`>` → WrongArity。
- **chained call `f(a)(b)` 语言禁止**（parser 显式报错，须经变量绑定柯里化）——测试用 `val g=f(a); g(b)`。
- **OP_CALL 快路径也要支持柯里化**：`add(5i64)` 是具名调用走 OP_CALL，argc<arity 时不能 WrongArity，
  须建部分应用 vm_closure。doCall 改为 `<arity`→partial / `==`→帧 / `>`→err。
- **CallFrame 重构**：`func_idx:u16` → `func:*const Function`（OP_CALL 与 OP_CALL_VALUE 统一）；
  新增 `frame_base`（返回时栈回退点+结果压入处）：OP_CALL 时 ==slot_base；OP_CALL_VALUE 时
  ==slot_base-1（callee 槽在 args 下方，RETURN 额外 release callee）。新增 `upvalues` 字段（M1b-2 用）。
- **enterClosure 栈重排**：有 bound_args 时，在 callee 槽与 new_args 间插入 bound（retainOwned），
  组成完整 arity 个 slot。

### 改动文件
- `value.zig`：+`VmClosure` 结构 + `vm_closure` union 变体；retain/release/clone/format/identityEquals/equals
  补 arm。**blast radius 受控**：仅 format 是 exhaustive 必须补；其余有 else 兜底但为正确性显式补。
  eval 的 closure/partial 语义零改动。
- `opcode.zig`/`disasm.zig`：+`op_closure <u16 func_idx>`、`op_call_value <u8 argc>`。
- `compiler.zig`：identifier 在值位置且是顶层函数名→`OP_CLOSURE`；emitCall 三路（具名顶层→OP_CALL 快路径；
  其余→callee 求值+OP_CALL_VALUE）。
- `vm.zig`：CallFrame 重构 + op_closure/op_call_value 分派 + doCall 柯里化 + doCallValue/enterClosure/
  makeBoundClosure。

### 测试门禁（全绿）
val f=fib;f(10)=55；apply(g,x){g(x)};apply(fib,10)=55；add(5) 绑定后 (3)=8；3-arg 分步柯里化=6；
add(1,2,3)→WrongArity。`zig build test`（eval+vm+9模块）全绿无泄漏；回归 33/33；Debug exe 重建。

---

## M1b-2 — 闭包 upvalue + cell 捕获 ✅ 已完成

**目标**：lambda/嵌套函数捕获外层变量；捕获 `var` 用共享 `*Cell`（镜像 eval Cell 语义）。

### 实测落地（与原计划差异）
- **clox 静态 upvalue 解析**：FnCompiler 加 `enclosing` 指针 + `upvalues` 列表。
  `resolveUpvalue(name)`：enclosing 有该 local→`addUpvalue(is_local=true, slot)`；否则递归
  `enclosing.resolveUpvalue`→`addUpvalue(is_local=false, 上层 upvalue idx)`。addUpvalue 去重。
- **lazy cell-boxing at OP_CLOSURE**（镜像 eval `buildCaptureEnv`，非 clox 的 open/close upvalue 机制）：
  捕获 local 时**就地** box 该 slot 成 `*Cell`（若非 cell），闭包 retain 同一 cell。cell rc 独立于帧，
  逃逸闭包（makeCounter）天然存活——无需 close-upvalue。
- **GET/SET_LOCAL 透明解 cell**：slot 是 `cell_val` 则读/写 `.inner`（被捕获后的 local 变 cell）。
- **GET/SET_UPVALUE**：`frame.upvalues[idx]` 是 `*Cell`，读写其 `.inner`。
- **致命陷阱（已修）：lambda 函数索引错位**。emitLambda 在编译期把 lambda `addFunction` 追加到
  `program.functions` 末尾，会**插在顶层函数之间**，导致 `fn_table.idx ≠ program.functions 索引`
  （entry/OP_CALL 的 func_idx 指向错函数——曾把 lambda 当 run 执行，GET_UPVALUE 越界 crash）。
  修法：第一遍给每个顶层 fun **预留** program 槽（占位空 chunk），第二遍编译结果**覆盖**预留槽；
  lambda 追加到末尾（idx ≥ 顶层函数数）。这样 idx 全程对齐。

### 改动文件
- `opcode.zig`/`disasm.zig`：`OP_CLOSURE` 改变长 `<u16 func_idx><u8 n>[<u8 is_local><u16 index>]×n`；
  新增 `OP_GET_UPVALUE`/`OP_SET_UPVALUE <u16 idx>`。disasm 支持变长 CLOSURE。
- `compiler.zig`：Upvalue 结构 + FnCompiler.enclosing/upvalues + resolveUpvalue/addUpvalue；
  identifier/assignment 解析顺序 local→upvalue→顶层函数；emitLambda（子编译器编译 lambda 体→
  addFunction→发 CLOSURE+描述符）；compileModule 预留槽 + compileFunction 覆盖槽。
- `vm.zig`：OP_CLOSURE 捕获（box/共享 cell）；GET/SET_UPVALUE；GET/SET_LOCAL 透明解 cell。

### 测试门禁（全绿）
read-after-mutate（捕获 var 外部改可见=20）；闭包改捕获 var 外部可见(=2)；嵌套闭包共享同 cell(=4)；
makeCounter 逃逸跨调用累积(=3)；两 counter 独立(=31)。`zig build test` 32/32 全绿无泄漏；回归 33/33。
注：loop-capture/数组的完整 edge_closures 需 M2/M3 特性，留后。

## M1b-3 — 尾调用优化 OP_TAIL_CALL ✅ 已完成

**目标**：尾位置调用复用当前帧（栈不增长），深尾递归不爆 MAX_FRAMES。

### 实测落地（与原计划差异）
- **范围限定具名顶层函数 + argc==arity**：覆盖所有尾递归门禁（自递归 + 互递归）。闭包尾调用 /
  柯里化 / 超参 / 被 local 遮蔽 → 退回 OP_CALL(_VALUE)+OP_RETURN，语义正确仅不享 TCO。
  这样帧复用逻辑极简，避开 bound_args/callee-box 重排复杂度。
- **emitTail 尾位置发射**（编译器）：函数体改用 emitTail 而非 emitExpr+RETURN。
  - call 合格（tryEmitTailCall：具名顶层、未遮蔽、argc==entry.arity）→ OP_TAIL_CALL。
  - if_expr → 两分支各 emitTail（then 分支自带 RETURN，无需 end_jump 跳 else）。
  - block → 前序 stmt 正常发射，trailing_expr 走 emitTail。
  - return_stmt 的 value 也走 emitTail（`return f(x)` 也 TCO）。
  - 其它 / 不合格 call → emitExpr + OP_RETURN。
- **FnEntry 加 arity 字段**（第一遍填），lookupFnEntry 供合格性判定。
- **doTailCall 帧复用**（VM）：暂存栈顶 argc 实参到定长缓冲(argc≤255)→ 释放本帧局部槽
  (+frame_base<slot_base 时的 callee box)→ shrink 到 frame_base → 写回 args → 补 unit 到
  slot_count → **就地改写当前帧**(func=callee, ip=0, slot_base=frame_base=原fbase, upvalues=&.{})。
  不 push 新帧。runLoop 每轮重取 frame/code，改写后下轮自然执行 callee。

### 改动文件
- `opcode.zig`/`disasm.zig`：+`op_tail_call <u16 func_idx><u8 argc>`（同 OP_CALL 编码）。
- `compiler.zig`：FnEntry.arity + lookupFnEntry；emitTail + tryEmitTailCall；compileFunction 体用
  emitTail；return_stmt value 走 emitTail。
- `vm.zig`：op_tail_call 分派 + doTailCall（帧复用）。

### 测试门禁（全绿）
countDown(1M)→0（无 TCO 必爆 64K MAX_FRAMES）；sumTo(100,0)=5050（累加器）；fact(5,1)=120；
互递归 isEven(1M)=1（isEven/isOdd 互为尾调用各百万层）；非尾 `dbl(10)+1`=21（走 OP_CALL+RETURN 不退化）。
`zig build test` 37/37 全绿无泄漏；回归 33/33；Debug exe 重建。

**M1b 三片全部完成。**

---

## 不变量（三片共同）
- VM 消费 type-checked AST（生产路径）；独立测试用类型后缀锁字面量类型（M1a 既定）。
- 每片结束：`zig build test` 全绿 + `bash run_tests.sh` 33/33 + Debug exe 重建。
- 共享 Value 改动后必须重测 eval 全套（closure/cell churn 的 --gpa 干净）。
