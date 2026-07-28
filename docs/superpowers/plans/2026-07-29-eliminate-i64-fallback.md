# 消除 `orelse i64_descriptor` Fallback 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 55 处 `orelse i64_descriptor` / `orelse lookupByScalarKind(.i64)` fallback 反模式，用 `orelse unreachable`（死代码型）或 `orelse @panic(...)`（真实缺口型）替代，暴露 sema 推导缺口而非静默产生错误类型。

**Architecture:** 按 spec 分三批实施。批次 1（死代码型，19 处）用 `orelse unreachable`；批次 2（查找失败型 IR 侧，10 处）和批次 3（inner_type_desc 缺口型 15 处 + sema 侧 inference.zig 11 处）用 `orelse @panic(...)`。每批独立 `zig build` + `zig build test` 验证，失败则回退该处并记录 bug。

**Tech Stack:** Zig 0.16，Glue 编译器（sema + IR 双层）

**Spec:** [docs/superpowers/specs/2026-07-29-eliminate-i64-fallback-design.md](file:///Users/haojunhuang/CLionProjects/Glue/docs/superpowers/specs/2026-07-29-eliminate-i64-fallback-design.md)

---

## 文件结构

本计划修改以下文件（不创建新文件）：

| 文件 | 修改内容 | 批次 |
|---|---|---|
| `src/sema/populate.zig` | L61, L85: `orelse lookupByScalarKind(.i64)` → `orelse unreachable` | 1 |
| `src/ir/builder.zig` | L537, L548: `orelse i64_descriptor` → `orelse unreachable` | 1 |
| `src/ir/ast_traits.zig` | L398: `orelse i64_descriptor` → `orelse unreachable` | 1 |
| `src/ir/func_compiler.zig` | L98, L100, L188, L335, L552, L558: `orelse i64_descriptor` → `orelse unreachable` | 1 |
| `src/ir/expr_compiler.zig` | L3677, L3938, L3974: `orelse i64_descriptor` → `orelse unreachable` | 1 |
| `src/ir/expr_compiler.zig` | L851, L1319, L1734, L1735, L2759, L3261, L3321, L3328: `orelse i64_descriptor` → `orelse @panic(...)` | 2 |
| `src/ir/expr_compiler.zig` | L664, L1845, L1867, L2072, L2507, L2644, L2709, L3124, L3498, L4080: `orelse i64_descriptor` → `orelse @panic(...)` | 3 |
| `src/ir/func_compiler.zig` | L213: `orelse i64_descriptor` → `orelse @panic(...)` | 3 |
| `src/ir/pattern_compiler.zig` | L330, L333, L377: `orelse i64_descriptor` → `orelse @panic(...)` | 3 |
| `src/ir/stmt_compiler.zig` | L345: `orelse i64_descriptor` → `orelse @panic(...)` | 3 |
| `src/sema/inference.zig` | L226, L229, L231, L242, L245, L582, L587, L593, L600, L607, L609: `orelse ir_td.i64_descriptor` → `orelse @panic(...)` | 3 |

---

## 批次 1：死代码型（19 处）→ `orelse unreachable`

### Task 1: populate.zig 死代码型（2 处）

**Files:**
- Modify: `src/sema/populate.zig:61,85`

- [ ] **Step 1: 修改 L61**

```zig
// 之前
const return_type_desc = type_resolver.resolveTypeNodeConcrete(fd.return_type, &.{}, sema_result) orelse type_descriptor.lookupByScalarKind(.i64);
// 之后
const return_type_desc = type_resolver.resolveTypeNodeConcrete(fd.return_type, &.{}, sema_result) orelse unreachable;
```

- [ ] **Step 2: 修改 L85**

```zig
// 之前
const return_type_desc = type_resolver.resolveTypeNodeConcrete(m.return_type, &.{}, sema_result) orelse type_descriptor.lookupByScalarKind(.i64);
// 之后
const return_type_desc = type_resolver.resolveTypeNodeConcrete(m.return_type, &.{}, sema_result) orelse unreachable;
```

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 编译成功（无错误）

- [ ] **Step 4: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过

- [ ] **Step 5: 提交**

```bash
git add src/sema/populate.zig
git commit -m "refactor(sema): replace orelse i64 fallback with orelse unreachable in populate.zig

fd.return_type and m.return_type are guaranteed non-null by parser
(parser.zig:545-553, 954-960). resolveTypeNodeConcrete only returns
null when type_node is null, so the fallback is dead code."
```

### Task 2: builder.zig 死代码型（2 处）

**Files:**
- Modify: `src/ir/builder.zig:537,548`

- [ ] **Step 1: 修改 L537**

```zig
// 之前
self.chanTypeFromTypeNodeResolved(tn) orelse type_descriptor_mod.i64_descriptor
// 之后
self.chanTypeFromTypeNodeResolved(tn) orelse unreachable
```

- [ ] **Step 2: 修改 L548**

```zig
// 之前
self.chanTypeFromTypeNodeResolved(tn) orelse type_descriptor_mod.i64_descriptor
// 之后
self.chanTypeFromTypeNodeResolved(tn) orelse unreachable
```

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 4: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过

- [ ] **Step 5: 提交**

```bash
git add src/ir/builder.zig
git commit -m "refactor(ir): replace orelse i64 fallback with orelse unreachable in builder.zig

vd.type_annotation is guarded by if-let, so tn is non-null.
chanTypeFromTypeNodeResolved delegates to resolveTypeNodeResolved
which only returns null when type_node is null."
```

### Task 3: ast_traits.zig 死代码型（1 处）

**Files:**
- Modify: `src/ir/ast_traits.zig:398`

- [ ] **Step 1: 修改 L398**

```zig
// 之前
const td = chanTypeFromTypeNode(tn, sema_result) orelse type_descriptor_mod.i64_descriptor;
// 之后
const td = chanTypeFromTypeNode(tn, sema_result) orelse unreachable;
```

- [ ] **Step 2: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 3: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过

- [ ] **Step 4: 提交**

```bash
git add src/ir/ast_traits.zig
git commit -m "refactor(ir): replace orelse i64 fallback with orelse unreachable in ast_traits.zig

allocChanFromTypeNode L391 already handles null type_node,
so tn is guaranteed non-null at L398."
```

### Task 4: func_compiler.zig 死代码型（6 处）

**Files:**
- Modify: `src/ir/func_compiler.zig:98,100,188,335,552,558`

- [ ] **Step 1: 修改 L98**

```zig
// 之前
.nullable => |nb| try self.channels.allocNullable(self.chanTypeFromTypeNodeBound(nb.inner) orelse type_descriptor_mod.i64_descriptor),
// 之后
.nullable => |nb| try self.channels.allocNullable(self.chanTypeFromTypeNodeBound(nb.inner) orelse unreachable),
```

- [ ] **Step 2: 修改 L100**

```zig
// 之前
else => try self.allocChannel(self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor),
// 之后
else => try self.allocChannel(self.chanTypeFromTypeNodeBound(tn) orelse unreachable),
```

- [ ] **Step 3: 修改 L188**

```zig
// 之前
self.current_throw_ok_type_desc = builder_mod.throwOkChanType(effective_return_type, self.sema_result) orelse type_descriptor_mod.i64_descriptor;
// 之后
self.current_throw_ok_type_desc = builder_mod.throwOkChanType(effective_return_type, self.sema_result) orelse unreachable;
```

- [ ] **Step 4: 修改 L335**

```zig
// 之前
self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor
// 之后
self.chanTypeFromTypeNodeBound(tn) orelse unreachable
```

- [ ] **Step 5: 修改 L552**

```zig
// 之前
const return_chan_type = self.chanTypeFromTypeNodeBound(fd.return_type) orelse type_descriptor_mod.i64_descriptor;
// 之后
const return_chan_type = self.chanTypeFromTypeNodeBound(fd.return_type) orelse unreachable;
```

- [ ] **Step 6: 修改 L558**

```zig
// 之前
.nullable => |nb| self.chanTypeFromTypeNodeBound(nb.inner) orelse type_descriptor_mod.i64_descriptor,
// 之后
.nullable => |nb| self.chanTypeFromTypeNodeBound(nb.inner) orelse unreachable,
```

- [ ] **Step 7: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 8: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过

- [ ] **Step 9: 提交**

```bash
git add src/ir/func_compiler.zig
git commit -m "refactor(ir): replace orelse i64 fallback with orelse unreachable in func_compiler.zig

All 6 sites guarded by parser invariants:
- nb.inner non-null (parser.zig:1344)
- fd.return_type non-null (parser.zig:545-553)
- tn guarded by if-let
- throwOkChanType guarded by isThrowType check"
```

### Task 5: expr_compiler.zig 死代码型（3 处）

**Files:**
- Modify: `src/ir/expr_compiler.zig:3677,3938,3974`

- [ ] **Step 1: 修改 L3677**

```zig
// 之前
const return_type = self.chanTypeFromTypeNodeBound(lam.return_type) orelse type_descriptor_mod.i64_descriptor;
// 之后
const return_type = self.chanTypeFromTypeNodeBound(lam.return_type) orelse unreachable;
```

- [ ] **Step 2: 修改 L3938**

```zig
// 之前
const return_type = self.chanTypeFromTypeNodeBound(method.return_type) orelse type_descriptor_mod.i64_descriptor
// 之后
const return_type = self.chanTypeFromTypeNodeBound(method.return_type) orelse unreachable
```

- [ ] **Step 3: 修改 L3974**

```zig
// 之前
self.current_throw_ok_type_desc = throwOkChanType(method.return_type, self.sema_result) orelse type_descriptor_mod.i64_descriptor;
// 之后
self.current_throw_ok_type_desc = throwOkChanType(method.return_type, self.sema_result) orelse unreachable;
```

- [ ] **Step 4: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 5: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过

- [ ] **Step 6: 提交**

```bash
git add src/ir/expr_compiler.zig
git commit -m "refactor(ir): replace orelse i64 fallback with orelse unreachable in expr_compiler.zig

lam.return_type and method.return_type non-null by parser invariant.
throwOkChanType guarded by isThrowType check."
```

### Task 6: 批次 1 完整性验证

- [ ] **Step 1: 确认无残留 i64 fallback（死代码型）**

Run: `grep -n "orelse.*i64_descriptor\|orelse.*lookupByScalarKind(.i64)" src/sema/populate.zig src/ir/builder.zig src/ir/ast_traits.zig src/ir/func_compiler.zig`
Expected: 无输出（所有死代码型已消除）

- [ ] **Step 2: 确认 expr_compiler.zig 死代码型已消除**

Run: `grep -n "orelse.*i64_descriptor" src/ir/expr_compiler.zig | grep -E ":(3677|3938|3974):"`
Expected: 无输出

- [ ] **Step 3: 完整测试**

Run: `zig build test`
Expected: 19 个集成测试全部通过

---

## 批次 2：查找失败型 IR 侧（10 处）→ `orelse @panic(...)`

### Task 7: expr_compiler.zig 查找失败型 - chanTypeFromTypeNodeBound 调用（5 处）

**Files:**
- Modify: `src/ir/expr_compiler.zig:851,1319,1734,1735,2759`

- [ ] **Step 1: 修改 L851**

```zig
// 之前
else type_descriptor_mod.i64_descriptor;
// 之后（若上下文为 chanTypeFromTypeNodeBound 的 orelse）
else @panic("sema failed to resolve type node");
```

注：L851 实际形式需先 Read 确认上下文，可能是 `orelse type_descriptor_mod.i64_descriptor` 或 `else type_descriptor_mod.i64_descriptor`。若是 `else`（if-else 分支），归入范围外，跳过。

- [ ] **Step 2: 读取 L851 上下文确认形式**

Run: `sed -n '848,855p' src/ir/expr_compiler.zig`

根据实际形式决定是否修改。若为 `orelse type_descriptor_mod.i64_descriptor`，改为 `orelse @panic("sema failed to resolve chan type from type node")`。

- [ ] **Step 3: 修改 L1319**

```zig
// 之前
break :blk type_descriptor_mod.i64_descriptor;
// 之后（若上下文为 orelse）
break :blk @panic("sema failed to resolve chan type");
```

注：需先 Read L1315-1325 确认是 `orelse` 还是 `break :blk` 默认值。若为 `break :blk` 默认值（非 orelse），归入范围外，跳过。

- [ ] **Step 4: 读取 L1315-1325 上下文**

Run: `sed -n '1315,1325p' src/ir/expr_compiler.zig`

根据实际形式决定修改方式。

- [ ] **Step 5: 修改 L1734, L1735**

```zig
// 之前
.function => |f| break :blk self.chanTypeFromTypeNodeBound(f.return_type) orelse type_descriptor_mod.i64_descriptor,
else => break :blk self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor,
// 之后
.function => |f| break :blk self.chanTypeFromTypeNodeBound(f.return_type) orelse @panic("sema failed to resolve function return type"),
else => break :blk self.chanTypeFromTypeNodeBound(tn) orelse @panic("sema failed to resolve type node"),
```

- [ ] **Step 6: 修改 L2759**

```zig
// 之前
const chan_type: *const type_descriptor_mod.TypeDescriptor = sema_chan_type orelse self.inferFieldType(object, field) orelse type_descriptor_mod.i64_descriptor;
// 之后
const chan_type: *const type_descriptor_mod.TypeDescriptor = sema_chan_type orelse self.inferFieldType(object, field) orelse @panic("sema failed to infer field type");
```

- [ ] **Step 7: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 8: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。**若 panic 触发**，记录 panic 消息和触发位置，回退该处为 `orelse type_descriptor_mod.i64_descriptor`，在 project_memory "待修复 bug" 清单中记录 sema 推导缺口。

- [ ] **Step 9: 提交**

```bash
git add src/ir/expr_compiler.zig
git commit -m "refactor(ir): replace orelse i64 fallback with @panic in expr_compiler.zig (lookup failure type)

Expose sema type resolution gaps via panic instead of silently
using i64 as placeholder. If panic triggers, it indicates a real
sema inference gap that needs separate fix."
```

### Task 8: expr_compiler.zig 查找失败型 - channelElemTypeFromExpr 调用（2 处）

**Files:**
- Modify: `src/ir/expr_compiler.zig:3321,3328`

- [ ] **Step 1: 修改 L3321**

```zig
// 之前
const recv_type = self.channelElemTypeFromExpr(call_expr, "recv") orelse type_descriptor_mod.i64_descriptor;
// 之后
const recv_type = self.channelElemTypeFromExpr(call_expr, "recv") orelse @panic("sema failed to record channel recv elem type");
```

- [ ] **Step 2: 修改 L3328**

```zig
// 之前
const elem_type = self.channelElemTypeFromExpr(call_expr, "tryRecv") orelse type_descriptor_mod.i64_descriptor;
// 之后
const elem_type = self.channelElemTypeFromExpr(call_expr, "tryRecv") orelse @panic("sema failed to record channel tryRecv elem type");
```

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 4: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。若 panic 触发，回退并记录 bug。

- [ ] **Step 5: 提交**

```bash
git add src/ir/expr_compiler.zig
git commit -m "refactor(ir): replace orelse i64 fallback with @panic for channelElemTypeFromExpr"
```

### Task 9: expr_compiler.zig 查找失败型 - chanTypeFromTypeNodeBound 剩余（3 处）

**Files:**
- Modify: `src/ir/expr_compiler.zig:3261,3263`（注：spec 表中 L3261, L3263 可能是 if-else 默认值，需确认）

- [ ] **Step 1: 读取 L3255-3270 上下文**

Run: `sed -n '3255,3270p' src/ir/expr_compiler.zig`

确认 L3261, L3263 是 `orelse` 还是 `else`/`break :blk` 默认值。

- [ ] **Step 2: 若为 orelse，修改 L3261**

```zig
// 之前
self.chanTypeFromTypeNodeBound(rt) orelse type_descriptor_mod.i64_descriptor
// 之后
self.chanTypeFromTypeNodeBound(rt) orelse @panic("sema failed to resolve return type")
```

- [ ] **Step 3: 若为 orelse，修改 L3263**

```zig
// 之前（若是 orelse 模式）
type_descriptor_mod.i64_descriptor
// 之后
@panic("sema failed to resolve return type")
```

若 L3263 是 `else`/`break :blk` 默认值（非 orelse），跳过此步并在提交消息中说明。

- [ ] **Step 4: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 5: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。若 panic 触发，回退并记录 bug。

- [ ] **Step 6: 提交**

```bash
git add src/ir/expr_compiler.zig
git commit -m "refactor(ir): replace orelse i64 fallback with @panic for chanTypeFromTypeNodeBound in expr_compiler.zig"
```

### Task 10: 批次 2 完整性验证

- [ ] **Step 1: 确认批次 2 所有 orelse i64 已处理**

Run: `grep -n "orelse.*i64_descriptor" src/ir/expr_compiler.zig | grep -E ":(851|1319|1734|1735|2759|3261|3263|3321|3328):"`
Expected: 无输出（或仅剩确认为 if-else 默认值的行）

- [ ] **Step 2: 完整测试**

Run: `zig build test`
Expected: 19 个集成测试全部通过

---

## 批次 3：inner_type_desc 缺口型（15 处+11 处）→ `orelse @panic(...)`

### Task 11: expr_compiler.zig inner_type_desc 缺口型（10 处）

**Files:**
- Modify: `src/ir/expr_compiler.zig:664,1845,1867,2072,2507,2644,2709,3124,3498,4080`

- [ ] **Step 1: 修改 L664**

```zig
// 之前
const dst_ct = meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor;
// 之后
const dst_ct = meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type");
```

- [ ] **Step 2: 修改 L1845**

```zig
// 之前
try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
// 之后
try self.channels.allocNullable(ret_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"))
```

- [ ] **Step 3: 修改 L1867**

```zig
// 之前
.ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor
// 之后
.ret_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type")
```

注：需先 Read L1865-1870 确认完整上下文，可能是 `.memo_slot = self.tryAssignMemoSlot(..., ret_meta.inner_type_desc orelse ...)`。

- [ ] **Step 4: 修改 L2072**

```zig
// 之前
if (meta.type_desc.isNullable() and !isScalarChanType(meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)) return 0;
// 之后
if (meta.type_desc.isNullable() and !isScalarChanType(meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"))) return 0;
```

- [ ] **Step 5: 修改 L2507**

```zig
// 之前
const inner_type = val_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor;
// 之后
const inner_type = val_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type");
```

- [ ] **Step 6: 修改 L2644**

```zig
// 之前
const out = try self.allocChannel(src_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
const out = try self.allocChannel(src_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 7: 修改 L2709**

```zig
// 之前
const inner_type = if (obj_meta.type_desc.isNullable()) (obj_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor) else obj_meta.type_desc;
// 之后
const inner_type = if (obj_meta.type_desc.isNullable()) (obj_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type")) else obj_meta.type_desc;
```

- [ ] **Step 8: 修改 L3124**

```zig
// 之前
try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
// 之后
try self.channels.allocNullable(ret_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"))
```

- [ ] **Step 9: 修改 L3498**

```zig
// 之前
try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
// 之后
try self.channels.allocNullable(ret_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"))
```

- [ ] **Step 10: 修改 L4080**

```zig
// 之前
const inner_type = if (left_meta.type_desc.isNullable()) (left_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor) else left_meta.type_desc;
// 之后
const inner_type = if (left_meta.type_desc.isNullable()) (left_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type")) else left_meta.type_desc;
```

- [ ] **Step 11: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 12: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。**若 panic 触发**，回退该处为 `orelse type_descriptor_mod.i64_descriptor`，在 project_memory 记录 sema 推导缺口。

- [ ] **Step 13: 提交**

```bash
git add src/ir/expr_compiler.zig
git commit -m "refactor(ir): replace inner_type_desc orelse i64 fallback with @panic

nullable inner type should be inferred by sema. Null indicates
sema inference gap (type_var/unknown_type/never_type unresolved).
Expose via panic instead of silent i64 placeholder."
```

### Task 12: func_compiler.zig inner_type_desc 缺口型（1 处）

**Files:**
- Modify: `src/ir/func_compiler.zig:213`

- [ ] **Step 1: 修改 L213**

```zig
// 之前
const nc = try self.channels.allocNullable(return_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
const nc = try self.channels.allocNullable(return_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 2: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 3: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。若 panic 触发，回退并记录 bug。

- [ ] **Step 4: 提交**

```bash
git add src/ir/func_compiler.zig
git commit -m "refactor(ir): replace inner_type_desc orelse i64 fallback with @panic in func_compiler.zig"
```

### Task 13: pattern_compiler.zig inner_type_desc 缺口型（3 处）

**Files:**
- Modify: `src/ir/pattern_compiler.zig:330,333,377`

- [ ] **Step 1: 修改 L330**

```zig
// 之前
break :blk try self.channels.allocNullable(then_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
break :blk try self.channels.allocNullable(then_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 2: 修改 L333**

```zig
// 之前
break :blk try self.channels.allocNullable(else_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
break :blk try self.channels.allocNullable(else_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 3: 修改 L377**

```zig
// 之前
const unwrapped_chan = try self.allocChannel(scrut_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
const unwrapped_chan = try self.allocChannel(scrut_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 4: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 5: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。若 panic 触发，回退并记录 bug。

- [ ] **Step 6: 提交**

```bash
git add src/ir/pattern_compiler.zig
git commit -m "refactor(ir): replace inner_type_desc orelse i64 fallback with @panic in pattern_compiler.zig"
```

### Task 14: stmt_compiler.zig inner_type_desc 缺口型（1 处）

**Files:**
- Modify: `src/ir/stmt_compiler.zig:345`

- [ ] **Step 1: 修改 L345**

```zig
// 之前
const nc = try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
// 之后
const nc = try self.channels.allocNullable(ret_meta.inner_type_desc orelse @panic("sema failed to infer nullable inner type"));
```

- [ ] **Step 2: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 3: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。若 panic 触发，回退并记录 bug。

- [ ] **Step 4: 提交**

```bash
git add src/ir/stmt_compiler.zig
git commit -m "refactor(ir): replace inner_type_desc orelse i64 fallback with @panic in stmt_compiler.zig"
```

### Task 15: inference.zig sema 侧缺口型（11 处）

**Files:**
- Modify: `src/sema/inference.zig:226,229,231,242,245,582,587,593,600,607,609`

- [ ] **Step 1: 读取 L220-250 上下文**

Run: `sed -n '220,250p' src/sema/inference.zig`

确认每个 `orelse ir_td.i64_descriptor` 的具体语义。

- [ ] **Step 2: 修改 L226**

```zig
// 之前
return type_resolver.resolveTypeNodeConcrete(cb.target_type, &.{}, sema_result) orelse ir_td.i64_descriptor;
// 之后
return type_resolver.resolveTypeNodeConcrete(cb.target_type, &.{}, sema_result) orelse @panic("sema inference gap: cast target type unresolved");
```

- [ ] **Step 3: 修改 L229**

```zig
// 之前
return type_resolver.resolveTypeNodeConcrete(tc.target_type, &.{}, sema_result) orelse ir_td.i64_descriptor;
// 之后
return type_resolver.resolveTypeNodeConcrete(tc.target_type, &.{}, sema_result) orelse @panic("sema inference gap: cast target type unresolved");
```

- [ ] **Step 4: 修改 L231**

```zig
// 之前
else => return ir_td.i64_descriptor,
// 之后
else => @panic("sema inference gap: unexpected cast kind"),
```

注：L231 是 `else =>` 分支，非 `orelse`。若如此，改为 `@panic` 而非 `return ir_td.i64_descriptor`。需先 Read 确认。

- [ ] **Step 5: 修改 L242**

```zig
// 之前
if (al.elements.len == 0) return ir_td.i64_descriptor;
// 之后
if (al.elements.len == 0) @panic("sema inference gap: empty array literal");
```

- [ ] **Step 6: 修改 L245**

```zig
// 之前
else => return ir_td.i64_descriptor,
// 之后
else => @panic("sema inference gap: unexpected array literal element"),
```

- [ ] **Step 7: 读取 L578-612 上下文**

Run: `sed -n '578,612p' src/sema/inference.zig`

- [ ] **Step 8: 修改 L582**

```zig
// 之前
return ir_td.i64_descriptor;
// 之后
return @panic("sema inference gap: type unresolved");
```

注：需先 Read 确认 L582 是 `return` 还是 `orelse`。

- [ ] **Step 9: 修改 L587**

```zig
// 之前
if (ta.* == .array) return type_resolver.resolveTypeNodeConcrete(ta.array.element_type, &.{}, ctx.base.sema_result) orelse ir_td.i64_descriptor;
// 之后
if (ta.* == .array) return type_resolver.resolveTypeNodeConcrete(ta.array.element_type, &.{}, ctx.base.sema_result) orelse @panic("sema inference gap: array element type unresolved");
```

- [ ] **Step 10: 修改 L593, L600, L607, L609**

逐处读取上下文，按语义修改为 `@panic("sema inference gap: <具体原因>")`。

- [ ] **Step 11: 编译验证**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 12: 测试验证**

Run: `zig build test`
Expected: 19 个集成测试全部通过。**若 panic 触发**，回退该处为原值，在 project_memory 记录 sema 推导缺口。

- [ ] **Step 13: 提交**

```bash
git add src/sema/inference.zig
git commit -m "refactor(sema): replace orelse i64 fallback with @panic in inference.zig

Expose sema inference gaps via panic instead of silent i64 placeholder.
Each panic message describes the specific gap (cast target, array elem, etc.)."
```

### Task 16: 批次 3 完整性验证

- [ ] **Step 1: 确认所有 orelse i64 fallback 已消除**

Run: `grep -rn "orelse.*i64_descriptor\|orelse.*lookupByScalarKind(.i64)" src/sema/ src/ir/ | grep -v "test\|tests"`
Expected: 仅剩范围外项（若存在）

- [ ] **Step 2: 确认 inference.zig 的 ir_td.i64 fallback 已消除**

Run: `grep -n "orelse.*ir_td.i64_descriptor\|return ir_td.i64_descriptor" src/sema/inference.zig`
Expected: 仅剩确认为非 fallback 语义的行

- [ ] **Step 3: 完整测试**

Run: `zig build test`
Expected: 19 个集成测试全部通过

---

## 最终验证与文档

### Task 17: 最终完整性验证

- [ ] **Step 1: 全局扫描残留 orelse i64 fallback**

Run: `grep -rn "orelse.*i64_descriptor" src/ | grep -v test`
Expected: 无输出（或仅剩范围外项）

- [ ] **Step 2: 全局扫描 orelse lookupByScalarKind(.i64)**

Run: `grep -rn "orelse.*lookupByScalarKind(.i64)" src/`
Expected: 无输出

- [ ] **Step 3: zig build**

Run: `zig build`
Expected: 编译成功

- [ ] **Step 4: zig build test**

Run: `zig build test`
Expected: 19 个集成测试全部通过

### Task 18: 更新 project_memory

- [ ] **Step 1: 若有回退处，记录到 project_memory**

读取 `/Users/haojunhuang/.trae-cn/memory/projects/-Users-haojunhuang-CLionProjects-Glue/project_memory.md`，在"Pending Bug Fixes"章节追加：

```markdown
### sema 推导缺口（2026-07-29 fallback 消除发现）
- [位置]: [panic 消息] — 回退为 orelse i64_descriptor，待 sema 修复
```

若无回退，跳过此步。

- [ ] **Step 2: 提交 project_memory 更新**

```bash
git add /Users/haojunhuang/.trae-cn/memory/projects/-Users-haojunhuang-CLionProjects-Glue/project_memory.md 2>/dev/null || true
git commit -m "docs: update project_memory with sema inference gaps found during fallback elimination" --allow-empty
```

注：project_memory 不在项目仓库内，此步可能跳过。

---

## 自审清单

**1. Spec 覆盖**：
- ✅ §2.1 死代码型 19 处 → Task 1-5
- ✅ §2.2 inner_type_desc 缺口型 15 处 → Task 11-14
- ✅ §2.3 查找失败型 IR 侧 10 处 → Task 7-9
- ✅ §2.3 查找失败型 sema 侧 11 处 → Task 15
- ✅ §4 范围外项明确不动
- ✅ §5 验证策略（zig build + zig build test + 回退机制）体现在每个 Task
- ✅ §6 实施顺序（批次 1→2→3）体现在 Task 编号顺序

**2. 占位符扫描**：
- Task 7-9 中部分步骤需先 Read 上下文确认是 `orelse` 还是 `else`/`break :blk`，这是必要的谨慎（L851, L1319, L3261, L3263 形式未完全确认），已给出两种情况的处理方式
- Task 15 的 L593, L600, L607, L609 需逐处 Read 确认语义，已给出步骤

**3. 类型一致性**：
- `@panic` 返回 `noreturn`，可替代任何类型的 `orelse` 分支，无类型不一致问题
- `unreachable` 同样返回 `noreturn`，与 `orelse` 语义兼容
