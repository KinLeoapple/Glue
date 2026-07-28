# 消除 `orelse i64_descriptor` Fallback 反模式

**日期**：2026-07-29
**状态**：设计已完成，待用户审阅
**范围**：sema + IR 两层，共 38 处 `orelse ... i64_descriptor` / `orelse lookupByScalarKind(.i64)` fallback

---

## 1. 背景与动机

代码库中广泛存在 `x orelse type_descriptor_mod.i64_descriptor` 模式（38 处），用作类型解析失败时的兜底。审计发现：

- **i64 在大多数场景下是语义错误的占位符**（例如 nullable 通道的 inner 类型、Throw<T,E> 的 Ok 值类型、字段类型推导失败等）
- **静默产生错误类型**：fallback 触发后不会报错，而是把 i64 写入 ChannelMeta / ExprMeta / FuncSigInfo，污染后续 `inferExprChanType`、`inferThrowOkChanType` 等推导链
- **掩盖 sema 推导缺口**：真正的类型推导失败（type_var/unknown_type/never_type 未解析、ExprInfo 未记录）被 i64 兜底隐藏，无法暴露为可修复的 bug

用户选择 **panic/unreachable 策略**：让所有 fallback 触发时立即暴露为 panic，而非静默使用 i64。

## 2. 根因分类

调查上游函数返回 null 的根因，分为四类：

### 2.1 死代码型（调用方已保证非 null）

**根因**：调用方通过解析器不变量或 `if` 守卫已保证 `type_node` 非 null，而 `resolveTypeNodeConcrete` / `resolveTypeNodeResolved` / `chanTypeFromTypeNodeBound` 在入参非 null 时所有 switch 分支均以 `getOrCreateRefDesc(...) catch unreachable` 收尾，**不返回 null**。

**解析器不变量**：
- [parser.zig:545-553](file:///Users/haojunhuang/CLionProjects/Glue/src/parse/parser.zig#L545-L553)、[parser.zig:954-960](file:///Users/haojunhuang/CLionProjects/Glue/src/parse/parser.zig#L954-L960)：函数/方法声明必须显式标注返回类型，未标注会解析报错。因此 `fd.return_type` / `m.return_type` / `method.return_type` 在 AST 层保证非 null。
- [parser.zig:1344](file:///Users/haojunhuang/CLionProjects/Glue/src/parse/parser.zig#L1344)：nullable 类型解析时 `.inner = ty` 必被赋值，`nb.inner` 保证非 null。

**涉及位置**（16 处，均为 `orelse` 模式）：

| 文件 | 行号 | 守卫来源 |
|---|---|---|
| `ir/builder.zig` | 537, 548 | `if (vd.type_annotation) \|tn\|` 已守卫 |
| `ir/ast_traits.zig` | 398 | L391 已提前处理 null 分支 |
| `sema/populate.zig` | 61, 85 | `fd.return_type` / `m.return_type` 解析器保证非 null |
| `ir/func_compiler.zig` | 98, 100, 335, 552, 558 | `nb.inner` / `fd.return_type` / `tn` 解析器或 `if` 守卫保证非 null |
| `ir/expr_compiler.zig` | 3677, 3938 | `lam.return_type` / `method.return_type` 解析器保证非 null |

**throwOkChanType 死代码**（3 处，归入此类）：
- `ir/func_compiler.zig:188`
- `ir/expr_compiler.zig:3726, 3974`

这 3 处都在 `if (self.current_returns_throw)` 守卫内，即 `isThrowType(type_node)` 已返回 true。`throwOkChanType` 返回 null 仅当 AST 畸形（`Throw` 无 args 或 `args[0]` null），属于不可恢复的 AST 错误。

**注**：`func_compiler.zig:101, 337, 559, 560` 是 `if-else` 默认值（参数无类型标注时用 i64），非 `orelse` 模式，归入 §4 范围外。

### 2.2 `meta.inner_type_desc` 缺口型

**根因**：调用点都在 `meta.type_desc.isNullable()` 为真的分支里，nullable 通道的 inner 类型应由 sema 推导填充。null 表示 sema 推导缺口（type_var/unknown_type/never_type 未解析）。

**涉及位置**（15 处，均为 `orelse` 模式）：

| 文件 | 行号 |
|---|---|
| `ir/expr_compiler.zig` | 664, 1845, 1867, 2072, 2507, 2644, 2709, 3124, 3498, 4080 |
| `ir/func_compiler.zig` | 213 |
| `ir/pattern_compiler.zig` | 330, 333, 377 |
| `ir/stmt_compiler.zig` | 345 |

### 2.3 查找失败型

**根因**：`channelElemTypeFromExpr` / `lazyElemTypeFromExpr` / `inferFieldType` / `chanTypeFromTypeNodeBound` 返回 null 表示 sema 未记录 ExprInfo 或未解析类型节点，是 sema 推导覆盖缺口。

**涉及位置**（10 处）：

| 文件 | 行号 | 上游函数 |
|---|---|---|
| `ir/expr_compiler.zig` | 851, 1319, 1734, 1735, 1738, 2759, 3261, 3263, 3321, 3328 | `chanTypeFromTypeNodeBound` / `inferFieldType` / `channelElemTypeFromExpr` |
| `sema/inference.zig` | 226, 229, 231, 242, 245, 582, 587, 593, 600, 607, 609 | sema 侧 `orelse ir_td.i64_descriptor` |

实际计数：10 处 IR 侧 + 11 处 sema 侧 = 21 处。

### 2.4 总数

经逐处核对，`orelse i64_descriptor` / `orelse lookupByScalarKind(.i64)` fallback 总数为：
- 死代码型：19 处（16 + 3 throwOkChanType）
- inner_type_desc 缺口型：15 处
- 查找失败型：21 处（10 IR + 11 sema）
- **合计：55 处**

## 3. 设计方案

### 3.1 死代码型 → `orelse unreachable`

```zig
// 之前
const chan_type = self.chanTypeFromTypeNodeResolved(tn) orelse type_descriptor_mod.i64_descriptor;
// 之后
const chan_type = self.chanTypeFromTypeNodeResolved(tn) orelse unreachable;
```

**理由**：调用方已通过解析器不变量或 `if` 守卫保证上游非 null，`unreachable` 表达"数学上不可能触发"的语义。Debug 模式下 panic，Release 模式下 UB（但永远不会触发，因为不变量成立）。

### 3.2 inner_type_desc 缺口型 → `orelse @panic(...)`

```zig
// 之前
const inner_type = meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor;
// 之后
const inner_type = meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type");
```

**理由**：`inner_type_desc` 为 null 是真实的 sema 推导缺口（type_var/unknown_type/never_type），属于"可能发生但属 bug"的情况。`@panic` 安全地暴露 bug，不引入 UB。

### 3.3 查找失败型 → `orelse @panic(...)`

```zig
// 之前
const recv_type = self.channelElemTypeFromExpr(call_expr, "recv") orelse type_descriptor_mod.i64_descriptor;
// 之后
const recv_type = self.channelElemTypeFromExpr(call_expr, "recv") orelse @panic("sema failed to record channel elem type");
```

**理由**：同 3.2，sema 推导覆盖缺口应暴露而非静默兜底。`@panic` 消息应描述具体缺失的信息。

### 3.4 sema 侧 inference.zig → `orelse @panic(...)`

sema 侧 `inference.zig` 的 11 处 `orelse ir_td.i64_descriptor` 同样改为 `orelse @panic("sema inference gap: ...")`，消息描述具体推导缺口（如 "cast target type unresolved"、"array literal elem type unresolved" 等）。

## 4. 范围外

### 4.1 合法直接分配 `allocChannel(i64_descriptor)`（~20 处）

长度通道、索引通道、ADT tag 通道、winner_chan 等，语义本就是 i64，**不动**。

### 4.2 其他合法直接分配

`allocChannel(unit_descriptor)` / `bool_descriptor` / `ref_descriptor` / `str_descriptor` / `char_descriptor`，语义合法，**不动**。

### 4.3 `if-else` 默认值（非 `orelse` 模式）

- `ir/func_compiler.zig:101, 337` — 参数无类型标注时默认 i64（[parser.zig:1163-1166](file:///Users/haojunhuang/CLionProjects/Glue/src/parse/parser.zig#L1163-L1166) 允许参数省略类型）
- `ir/func_compiler.zig:559, 560` — return_chan_type.isNullable() 但 fd.return_type 非 nullable 分支 / fd.return_type 为 null 分支
- `ir/expr_compiler.zig:851, 1319, 1738, 3263, 3704, 3965` — `else`/`break :blk` 默认值

这些是 `if-else` 或 `switch` 默认分支，非 `orelse` 模式。若需消除，应单独评估每个默认分支的语义正确性。**本次不动**。

### 4.4 Struct 字段默认值（5 处）

- `ir/meta.zig:152` — `elem_type_desc: *const TypeDescriptor = type_descriptor_mod.i64_descriptor`
- `ir/meta.zig:249, 279, 452` — `result_type_desc: *const TypeDescriptor = type_descriptor_mod.i64_descriptor`
- `ir/builder.zig:208` — `current_throw_ok_type_desc: *const TypeDescriptor = type_descriptor_mod.i64_descriptor`

这是 Zig struct 字段默认值，不是 `orelse` fallback。改为 `undefined` 会引入未初始化读风险，且 `current_throw_ok_type_desc` 仅在 `current_returns_throw == true` 时读取（默认值永不使用）。**本次不动**，标记为未来可优化项（需逐处验证字段在使用前必被赋值）。

## 5. 验证策略

1. **`zig build` 必须通过**：编译期验证所有 `orelse unreachable` / `@panic` 语法正确
2. **`zig build test` 19 个集成测试必须通过**：运行期验证 sema 推导无缺口，panic 不触发
3. **若 panic 触发**：说明 sema 有真实推导缺口，**回退该处**为 `orelse i64_descriptor` 并记录到 project_memory 的"待修复 bug"清单，单独修复 sema 后再恢复 panic

## 6. 实施顺序

按风险从低到高分三批：

**批次 1**：死代码型（19 处）→ `orelse unreachable`
- 风险最低（数学上不可触发）
- 验证：`zig build` + `zig build test`

**批次 2**：查找失败型 IR 侧（10 处）→ `orelse @panic`
- 风险中等（可能暴露 ExprInfo 记录缺口）
- 验证：`zig build test`，若 panic 则回退该处

**批次 3**：inner_type_desc 缺口型（15 处）+ sema 侧 inference.zig（11 处）→ `orelse @panic`
- 风险最高（最可能暴露 sema 推导缺口）
- 验证：`zig build test`，若 panic 则回退该处并记录 bug

每批独立验证，失败不影响已完成的批次。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| panic 触发导致测试失败 | 回退该处为 `orelse i64_descriptor`，记录 bug，单独修复 sema |
| `unreachable` 在 Release 模式下 UB | 死代码型不变量成立，永远不会触发；若触发说明不变量被破坏，Debug 模式会先 panic |
| sema 推导缺口数量超预期 | 批次 3 可能产生多个回退；记录所有回退处，形成 sema 修复待办清单 |

## 8. 成功标准

- 55 处 `orelse i64_descriptor` fallback 全部消除（或回退并记录 bug）
- `zig build` 通过
- `zig build test` 19 个集成测试通过（允许个别处回退）
- project_memory 更新：记录回退处（若有）和 sema 推导缺口（若发现）
