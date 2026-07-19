# 执行引擎开发路线图

本文档记录 Glue IR 执行引擎（`src/engine/`）的分阶段开发计划。

设计参考：[glue-ir-design.md](glue-ir-design.md) 第 6 章

---

## 当前状态

**所有 Phase 1-7 已完成**，执行引擎覆盖 Glue IR 全部节点类型。366/366 测试通过。

**Phase 1（已完成）**：标量计算 + 基础控制流

- 常量节点：`const_i` / `const_f` / `const_bool` / `const_char` / `const_str` / `const_null` / `const_unit`
- 整数算术：`int_add/sub/mul/div/mod/and/or/xor/shl/shr/neg/abs/not`
- 浮点算术：`float_add/sub/mul/div/neg/abs`
- 比较运算：`cmp_eq/ne/lt/le/gt/ge`
- 布尔逻辑：`bool_and/or/not`
- 控制流：`call`、`halt_return/throw/panic`
- 标量运算复用 `src/value/ops.zig` 的 comptime 特化函数（dispatch 分派模式，详见 [glue-ir-design.md](glue-ir-design.md) 6.7 节）
- 接入 `src/mem/` 三层分配器（ChannelRegion / ShadowArena / ThreadContext）

**Phase 2（已完成）**：类型转换 + var/if/复合赋值

- 类型转换：`cast` / `cast_safe`（复用 `src/value/cast.zig` 的 O(1) 查表函数）
- 内存操作：`load` / `store`（var 变量声明与赋值，memcpy 实现）
- 选择执行：`vec_select`（if 表达式标量模式 N=1，条件选择 then/else 通道）
- 复合赋值：`+= -= *= /= %= &= |= ^= <<= >>=`（builder 层映射为二元运算 + store）
- builder 支持：`type_cast` AST 节点、`compound_assignment` 语句
- `run()` 返回值按通道实际宽度读取（1/2/4/8/16 字节，符号扩展）
- 修复 `execCast` 的 meta_index 偏移 bug（应直接索引，非 -1）
- 330/330 测试通过

**Phase 2.5（已完成）**：堆对象管理

- Engine 堆分配器集成（ThreadContext 对象池 + GlobalPool.buddy）
- `const_str` 完整实现（从 string_pool 创建 Str 对象，写入 ref_chan）
- `string_concat` / `string_len` / `string_index`
- `array_make` / `array_get` / `array_set` / `array_len` / `array_push` / `array_concat`
- `record_make` / `record_get` / `record_set`
- builder 支持：`string_interpolation`、`array_literal`、`record_literal`、`field_access`、`index`
- 修复 `@fieldParentPtr` 指针偏移（ArrayValue/RecordValue 是普通 struct，header 不在偏移 0）
- 修复 `u21` 只有 3 字节的问题（char_chan 宽度 4 字节，改用 `*u32` 写入）
- 修复字符串插值语法（`${expr}` → `{expr}`）
- 344/344 测试通过

**Phase 3（已完成）**：向量 op 执行（核心加速层）

- 向量节点：`vec_source` / `vec_map` / `vec_map2` / `vec_fold` / `vec_scan` / `vec_filter` / `vec_take` / `vec_take_while` / `vec_zip` / `vec_sink`
- Runtime 向量支持：`allocVector` / `vectorLen` / `vectorElemPtr` / `readVectorI64` / `writeVectorI64` / `chan_lengths` 数组
- 两种循环体编码模式：
  - **内联标量模式**（`body_len == 0`）：`inner_op` 直接引用单个标量运算（如 `int_add`），通过 `dispatchInlineBinOp` 分派
  - **子图模式**（`body_len > 0`）：`body_start` / `body_len` 引用主节点流中的子图，主循环通过 `body_skip` 位图跳过
- `execFunction` 重构：提取 `execNode` + `body_skip` 位图（子图节点不在主循环执行，由 vec_* exec 按需调用 `execBodyNodes`）
- `for i in 0..N { body }` → `vec_source(range) |> vec_map(body) |> vec_sink(last)`，dispatch 从 O(N) 降为 O(1)
- `vec_fold` 内联模式：逐元素 `dispatchInlineBinOp(acc, elem)` 归约
- `vec_scan` 内联模式：逐元素 `dispatchInlineBinOp(acc, elem)` 前缀扫描，结果写入 output[i]
- `vec_sink`：`sink_last` / `sink_first` / `sink_count` / `sink_to_array`
- 修复 `pinToElement` 自引用偏移 bug（保存原始 `base_ptr`，每次基于原始指针计算偏移）
- 349/349 测试通过

**Phase 4（已完成）**：门控 + 清理（错误处理 + defer）

- 门控节点：`gate_check` / `gate_get_ok` / `gate_get_err` / `gate_propagate` / `gate_select` / `gate_make_ok` / `gate_make_err`
- 清理节点：`cleanup_register`（`cleanup_run` 由 `execFunction` 在 halt 时自动调用）
- Engine 新增 `defer_stack` 数组（`DeferFrame` 结构，256 深度）+ `defer_top` 栈顶指针
- `execFunction` 重构：halt 时跳出主循环，LIFO 执行本函数注册的 defer 帧
- `body_skip` 位图扩展：跳过 `cleanup_register` 注册的 defer 体节点（与 vec_* body 同机制）
- `gate_check`：读取 ref_chan 中的 ThrowValue，检查 payload 是 ok 还是 err，输出 mask
- `gate_get_ok`：从 ThrowValue 提取 Ok 值，通过 `writeScalarValue` 写入 output
- `gate_get_err`：从 ThrowValue 提取 ErrorValue 指针
- `gate_propagate`：AND 传播错误掩码（当前 Ok 且上游也 Ok 才 Ok）
- `gate_select`：按 mask 选择 ok_val 或 err_val
- `gate_make_ok`：构造 `ThrowValue{ .ok = value }`，直接 `backing.create` 分配
- `gate_make_err`：传递 ErrorValue 指针
- 辅助函数：`readRefObj`/`readThrow`/`readError`/`readScalarValue`/`writeScalarValue`
- 353/353 测试通过

**Phase 5（已完成）**：路由 + 竞争（select 多路复用）

- 路由节点：`route_get_tag` / `route_dispatch` / `route_merge`
- 竞争节点：`race_source` / `race_select` / `race_yield`
- `RouteMeta` 扩展：新增 `body_starts`/`body_lens` 字段支持子图模式（与 `VectorMeta`/`CleanupMeta` 一致的 body 机制）
- `compileSelect` 重写：编译每个 arm body 为子图，填充 `RouteMeta.body_starts`/`body_lens`，receive arm 的 binding 注册到作用域
- `body_skip` 位图扩展：跳过 `route_dispatch` 的 arm body 子图（与 vec_* body / cleanup body 同机制）
- `race_source`：检查通道就绪性，ref_chan 中的 ChannelValue 用 `count > 0`/`rend_ready` 检查，标量输入视为始终就绪
- `race_select`：扫描 N 个 mask，选第一个就绪的，输出 winner 索引（i64）
- `route_dispatch`：读取 winner 索引，用 `execBodyNodes` 执行对应 arm body 子图，拷贝结果到 output
- `race_yield`：简化为无操作（Phase 7 接入星轨调度器）
- `route_get_tag`：简化为直接传递值（完整实现需 TraitValue tag 支持）
- `route_merge`：简化为拷贝第一个输入
- 357/357 测试通过

**Phase 6（已完成）**：Nullable + 内存管理

- Nullable 节点：`nullable_make` / `nullable_is_null` / `nullable_unwrap` / `nullable_unwrap_or`
- 内存管理节点：`alloc` / `free`（`load`/`store` 在 Phase 2 已实现）
- nullable_chan 布局：`[inner_value_bytes][null_flag: 1 byte]`（null_flag=0 有值，=1 为 null）
- `nullable_make`：将值包装为 Nullable<T>，ref_chan 的 null 指针或 null_chan 自动包装为 null
- `nullable_is_null`：读取 null flag 输出 bool
- `nullable_unwrap`：提取 inner 值，null 时返回 `error.Panic`
- `nullable_unwrap_or`：null 时返回 default 值，否则取 inner
- `alloc`：通过 `ThreadContext.allocBySize` 分配堆内存，零初始化
- `free`：简化为无操作（arena 分配器由 reset 统一回收）
- builder 新增编译方法：
  - `compileNonNullAssert`（`expr!`）：nullable_chan 直接 unwrap，ref_chan 先包装再 unwrap
  - `compileSafeAccess`（`obj?.field`）：nullable 包装 + is_null 检查 + vec_select 条件选择
  - `compileElvis`（`left ?? right`）：编译为 `nullable_unwrap_or`，非 nullable/ref 类型直接返回 left
- 360/360 测试通过

---

**Phase 7（已完成）**：星轨执行（async/spawn）

- 星轨节点：`orbit_async_create` / `orbit_async_join` / `orbit_chan_send` / `orbit_chan_recv` / `orbit_chan_try_recv`
- `orbit_async_create`：创建 `AsyncHandle` 堆对象，spawn 独立线程执行 async 函数
- `orbit_async_join`：阻塞等待 async 任务完成，读取结果写入 output 通道
- `orbit_chan_send` / `orbit_chan_recv` / `orbit_chan_try_recv`：通过 `ChannelValue` 进行线程间通信
- `orbitWorker`：独立线程函数，使用 `Engine.initOwned` 创建独立 Engine 实例（共享 IR，独立 Runtime/ThreadContext），避免数据竞争
- builder `compileCall` 自动检测 async 函数：发射 `orbit_async_create` + `orbit_async_join`（自动 await 语义）
- `AsyncHandle` 线程安全：原子 status/finished/consumed 字段 + Mutex/Condition 实现 join 语义
- 修复 `setResult`/`setPanic` mutex 死锁（不持锁，依赖 `finished.store(.release)` happens-before）
- 修复 `OrbitThreadData` 内存泄漏（`defer alloc.destroy(data)`）
- 修复 builder `func_table` 注册 bug（第一遍用独立计数器，非 `functions.items.len`）
- 366/366 测试通过

---

## 优先级建议

```
Phase 2 (基础)  →  Phase 3 (核心加速)  →  Phase 4 (错误处理)
                                              ↓
Phase 7 (并发)  ←  Phase 6 (内存)  ←  Phase 5 (分派)
```

**Phase 3 是最关键的阶段**——这是项目"dispatch 降频 1000 倍 + SIMD 4 倍并行 = ~46 倍综合加速比"目标的核心实现点。建议在 Phase 2 简单完成后优先推进 Phase 3。

---

## 复用映射总表

| Engine 阶段 | 复用的 value 模块 | 复用的 mem 模块 |
|---|---|---|
| Phase 1（已完成） | `ops.zig`（标量运算） | `ChannelRegion`（通道数据） |
| Phase 2 | `cast.zig`、`composite.zig`、`str.zig`、`obj_header.zig` | `ThreadContext` 对象池（堆对象） |
| Phase 3 | `batch.zig`（SIMD 批量运算）、`scalar.zig`（ScalarTag 映射） | `ChannelRegion`（64B 对齐向量数据） |
| Phase 4 | `control.zig`（ErrorValue/ThrowValue） | `ShadowArena`（defer 栈） |
| Phase 5 | `callable.zig`（TraitValue） | `ThreadContext` 对象池（分派表） |
| Phase 6 | `composite.zig`（Cell） | `GlobalPool.buddy`（大对象） |
| Phase 7 | `concurrent.zig`（ChannelValue/Sender/Receiver） | `ThreadContext` 对象池（轨道实例） |
