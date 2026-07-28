# Error trait 移至 builtin 设计

## 1. 背景与动机

### 1.1 当前问题

Error trait 当前完全硬编码在 Zig 层（`src/sema/type_check.zig:3402-3465`），存在以下问题：

1. **无 .glue 定义文件**：Error trait 的 ADT、构造器、trait scheme 全部在 sema 层硬编码注册，无法通过 .glue 语法查看或修改。

2. **message()/type_name() 绕过 trait 系统**：IR 编译时（`expr_compiler.zig:3396-3407`）通过方法名硬编码映射到专用 IR 节点 `error_message`/`obj_type_name`，不经过 `func_table` 查找，**不支持用户 override**。

3. **fields[2] hack**：3 处硬编码用 `fields[2]` 读取 msg 字段（假设字段顺序为 `[__tag=0, kind=1, msg=2, ...]`）：
   - `engine/builtin_exec.zig:315-319`（execErrorMessage）
   - `engine/control_exec.zig:164-180`（execGateMakeErr）
   - `syscall/util.zig:126-142`（makeThrowErr）

   该 hack 对 IOError/TimeError 正确，但对 **CastError 错误**（msg 在 fields[1]），导致 `e.message()` 返回空字符串。

4. **ThrowValue.err 持有 ErrorValue**：`ThrowValue.Payload.err` 类型为 `*ErrorValue`，需从 RecordValue 提取 msg 重建 ErrorValue，是 fields[2] hack 的根源。

### 1.2 设计目标

- Error trait 像普通用户 trait 一样在 `.glue` 文件中定义
- message()/type_name() 走正常 trait 方法分派，支持 override
- 消除所有专用 IR 节点和 `fields[2]` hack
- 支持用户自定义 Error 类型

## 2. 命名设计

### 2.1 trait 与构造器分离

为避免 `Error` 既是 trait 名又是构造器名的歧义：

- `Err` 是 trait 名（`trait Err { ... }`）
- `Error` 是构造器/类型名（`type Error: Err = Error(msg: str)`）
- `IOError: Err`、`CastError: Err`、`TimeError: Err`

### 2.2 命名合理性

- `Err` 作为 trait 名简洁（类似 Rust 的 `Error` trait 但避免冲突）
- `Error` 作为具体错误类型符合直觉（"一个 Error 实例"）
- 用户自定义 `type MyError: Err = MyError(...)` 清晰表达"实现 Err trait"

### 2.3 向后兼容性

- `throw Error("negative")` 保留
- `throw IOError(...)` 保留
- `type IOError: Error` → `type IOError: Err`（需批量替换）
- `Error(e) =>` 模式匹配保留

## 3. .glue 定义

### 3.1 新建 `src/builtin/error/Err.glue`

```glue
trait Err {
    fun message(self): str {
        self.msg
    }
    fun type_name(self): str {
        "Error"
    }
}
```

- `message()` 默认实现：字段访问 `self.msg`（编译为 `field_access` IR，按字段名查找，非下标）
- `type_name()` 默认实现：返回字面量 `"Error"`（子类型 override 返回自己的类型名）

### 3.2 新建 `src/builtin/error/Error.glue`

```glue
type Error: Err = Error(msg: str)
```

- `Error(msg: str)` 构造器：构造匿名 Error 实例，msg 字段命名为 `msg`
- 通过 trait 分派 `message()` 返回 msg，`type_name()` 返回 "Error"

### 3.3 修改现有 builtin error .glue

- `IOError.glue`：`: Error` → `: Err`
- `CastError.glue`：`: Error` → `: Err`
- `TimeError.glue`：`: Error` → `: Err`
- `pack.glue`：加入 Err.glue + Error.glue

### 3.4 字段命名约束

所有 Err trait 子类型的 msg 字段必须命名为 `msg`（当前 CastError/IOError/TimeError 均符合）。用户自定义 Error 类型若 msg 字段不叫 `msg`，必须 override `message()`。

## 4. IR 编译与执行分派改造

### 4.1 expr_compiler.zig 改造

删除 `message`/`type_name` 方法名硬编码（`expr_compiler.zig:3396-3407`），改为走正常 method_call 分派：

```zig
// 删除：
if (std.mem.eql(u8, method, "message")) { ... }
if (std.mem.eql(u8, method, "type_name")) { ... }
```

`compileMethodCall` 通用路径已支持 trait 方法分派（查 `func_table` 找 `Err.message`/`Err.type_name` 或子类型 override），无需新增逻辑。

### 4.2 IR 节点清理

- 删除 `error_message`、`obj_type_name` IR 节点（`node.zig:134-135`）
- 删除 op_table 注册（`op_table.zig:237-239`）
- 删除 dispatch_table 执行绑定（`dispatch_table.zig:543-545`）
- 删除 `execErrorMessage`/`execObjTypeName`（`builtin_exec.zig:297+`）

### 4.3 fields[2] hack 清理

| 位置 | 当前 | 改造后 |
|------|------|--------|
| `builtin_exec.zig:315-319` | `execErrorMessage` 用 `fields[2]` | 函数删除，message() 走 `field_access` 默认实现 |
| `control_exec.zig:164-180` | `execGateMakeErr` 用 `fields[2]` 提取 msg | 改为构造 ThrowValue 时不再提取 msg，直接持有 RecordValue |
| `syscall/util.zig:126-142` | `makeThrowErr` 用 `fields[2]` 提取 msg 重建 ErrorValue | 同上，直接持有 RecordValue |

### 4.4 ThrowValue.err 改为持有 RecordValue

```zig
pub const ThrowValue = struct {
    header: ObjHeader = .{ .type_tag = .throw_val },
    payload: Payload,

    pub const Payload = union(enum) {
        ok: Value,
        err: *RecordValue,  // 改为持有 error_newtype 的 RecordValue
    };
};
```

- `throw IOError(...)` → `ThrowValue.err` 直接持有 IOError 的 RecordValue
- `e.message()` → trait 方法分派到 `Err.message` 默认实现 → `field_access(self, "msg")` → 从 RecordValue 按 field_id_map 查找
- `e.type_name()` → trait 方法分派到 override 或默认实现

### 4.5 ErrorValue 类型处理

`ErrorValue` 仍保留用于 syscall 层构造错误（`makeIOError` 等不经过 .glue 的场景）。但 syscall 构造的 RecordValue 现在带 field_names（`makeRecordWithNames`），`field_access` 能正确按名查找，无需 `fields[2]` hack。

## 5. sema trait 注册改造

### 5.1 sema/type_check.zig 改造

删除 Error trait 的硬编码注册（`type_check.zig:3402-3465`），改为从 `Err.glue` 解析：

```zig
// 删除：error_adt_ty / Error 构造器 / error_trait_ty / trait_types.put("Error", ...)
// 保留：is_error_newtype 标志（AdtInfo 中，用于模式匹配覆盖检查）
```

Err.glue 与其他 builtin .glue 文件走同一解析流程：
- `registerBuiltins` 调用 `loadBuiltinPack("error/pack.glue")`
- pack.glue 包含 Err trait + Error type + 各 error_newtype 声明
- sema 解析 trait 定义，注册到 `trait_types`，方法 scheme 由 AST 推导

### 5.2 Error 构造器与 Throw 构造器命名歧义

**关键发现**：`Error` 名字在两个上下文使用：

1. **Throw<T,E> 的 err 构造器**：`match expr { Ok(v) => ..., Error(e) => ... }` 中 `Error(e)` 解构 ThrowValue，绑定 e 为内部错误值。这是 Throw 类型的构造器（类似 Result 的 Err）。

2. **error_newtype 类型 Error 的构造器**：`type Error: Err = Error(msg: str)` 定义的具体错误类型，`throw Error("negative")` 构造此类型实例。

**当前 `throw Error("negative")` 语义**：构造 ThrowValue.err，err 持有从 "negative" 构造的 ErrorValue（通过 `∀T,E. fn(E) -> Throw<T,E>` 特殊签名）。

**改造后语义**：
- `throw Error("negative")` 中 `Error("negative")` 构造 Error RecordValue（含 msg="negative"）
- `throw` 语句将其包装为 `ThrowValue.err(Error_record_value)`
- `match { Error(e) => ... }` 中 `Error(e)` 仍是 Throw 构造器，解构 ThrowValue，e 绑定为 Error RecordValue
- `e.message()` 通过 Err trait 分派到默认实现 `self.msg` → "negative"

**歧义风险**：`Error` 既是 Throw 构造器又是 error_newtype 类型名。sema 需按上下文区分：
- `throw Error(...)` → error_newtype 构造器（构造 RecordValue）
- `match { Error(e) => ... }` → Throw 构造器（解构 ThrowValue）

当前 sema 已支持 Throw 构造器 `Ok`/`Error` 的模式匹配（硬编码），改造后需确保 error_newtype `Error` 的构造器不与 Throw 构造器冲突。可能需要保留 Throw 构造器的特殊处理，error_newtype `Error` 仅在表达式位置（非 match pattern）作为构造器。

### 5.3 trait_resolve.zig

当前 trait_resolve 对 Error 无特判。改造后 Err trait 走通用 trait bound 检查：
- `throw IOError(...)` 时检查 IOError 是否实现 Err trait（通过 `is_error_newtype` 标志或 `parent_trait` 字段）
- `e.message()` 走通用 `inferMethodCall`，查 `Err.message` 方法 scheme

### 5.4 is_error_newtype 标志保留

`AdtInfo.is_error_newtype` 保留，用于：
- 模式匹配覆盖检查（`Error` 模式匹配所有 error_newtype 构造器）
- `throw` 语句类型检查（throw 的值必须实现 Err trait）

## 6. builtin.zig 扩展

```zig
pub const BuiltinKind = enum {
    error_newtype,
    adt,
    trait,  // 新增
};

// BUILTIN_TYPES 增加：
.{
    .name = "Err",
    .kind = .trait,
    .parent_trait = "",
    .source_path = "builtin/error/Err.glue",
    .pack_name = "error",
    // trait 特有：方法签名列表
    .trait_methods = &[_]TraitMethodInfo{
        .{ .name = "message", .params = &.{}, .ret = "str", .has_default = true },
        .{ .name = "type_name", .params = &.{}, .ret = "str", .has_default = true },
    },
},
.{
    .name = "Error",
    .kind = .error_newtype,
    .parent_trait = "Err",
    .source_path = "builtin/error/Error.glue",
    .pack_name = "error",
    .fields = &[_]FieldInfo{
        .{ .name = "msg", .type_name = "str" },
    },
},
```

## 7. 改动清单

### 7.1 文件改动

| 文件 | 改动 | 风险 |
|------|------|------|
| 新建 `src/builtin/error/Err.glue` | 定义 `trait Err`，message()/type_name() 默认实现 | 低 |
| 新建 `src/builtin/error/Error.glue` | 定义 `type Error: Err = Error(msg: str)` | 低 |
| `src/builtin/error/IOError.glue` | `: Error` → `: Err` | 低 |
| `src/builtin/error/CastError.glue` | `: Error` → `: Err` | 低 |
| `src/builtin/error/TimeError.glue` | `: Error` → `: Err` | 低 |
| `src/builtin/error/pack.glue` | 加入 Err.glue + Error.glue | 低 |
| `src/builtin.zig` | `BuiltinKind` 增加 `.trait`，BUILTIN_TYPES 增加 Err trait + Error type 条目 | 中 |
| `src/sema/type_check.zig:3402-3465` | 删除硬编码 Error 注册，改为从 .glue 解析 | 高 |
| `src/sema/type_check.zig:3466-3550` | builtin 加载流程支持 trait 类别 | 中 |
| `src/ir/decl_collector.zig:481` | registerBuiltinErrorTypes 支持 trait 注册 | 中 |
| `src/ir/expr_compiler.zig:3396-3407` | 删除 message/type_name 方法名硬编码，走通用 method_call | 高 |
| `src/ir/node.zig:134-135` | 删除 `error_message`/`obj_type_name` 节点 | 中 |
| `src/ir/op_table.zig:237-239` | 删除节点注册 | 低 |
| `src/engine/dispatch_table.zig:543-545` | 删除执行绑定 | 低 |
| `src/engine/builtin_exec.zig:297+` | 删除 `execErrorMessage`/`execObjTypeName` | 中 |
| `src/engine/control_exec.zig:142-199` | `execGateMakeErr` 删除 `fields[2]` hack，ThrowValue.err 持有 RecordValue | 高 |
| `src/syscall/util.zig:126-158` | `makeThrowErr` 删除 `fields[2]` hack，直接持有 RecordValue | 高 |
| `src/value/control.zig:33-52` | `ThrowValue.Payload.err` 类型从 `*ErrorValue` 改为 `*RecordValue` | 高 |
| `src/value/mod.zig:426` | `makeError` 保留（syscall 层用），但 ThrowValue 包装改为持有 RecordValue | 中 |
| 用户 .glue 文件 | `type X: Error` → `type X: Err` | 低（批量替换） |
| 测试文件 | trait 名引用 `Error` → `Err` | 低 |

### 7.2 高风险点

1. **ThrowValue.err 类型变更**（`*ErrorValue` → `*RecordValue`）：影响所有 ThrowValue 构造和消费路径。需排查：
   - `execGateMakeErr`（control_exec.zig）
   - `execGateMakeOk`（control_exec.zig）
   - `execRouteDispatch`（route_dispatch 的 ? 传播）
   - `orbit_async_join` 结果读取
   - syscall 层 makeThrowErr/makeThrowOk

2. **sema trait 注册重构**：删除 type_check.zig:3402-3465 硬编码后，需确保 .glue 解析能正确注册 trait scheme，且 `is_error_newtype` 标志仍正确设置。

3. **message() 默认实现的 field_access**：`self.msg` 编译为 field_access，需确认 field_id_map 在所有 error_newtype 上正确注册 "msg" 字段名。

4. **Error 构造器与 Throw 构造器命名歧义**：`Error` 既是 Throw<T,E> 的 err 构造器（`match { Error(e) => ... }`）又是 error_newtype 类型名（`throw Error("negative")`）。sema 需按上下文区分：表达式位置 → error_newtype 构造器，match pattern 位置 → Throw 构造器。当前 sema 已硬编码 Throw 构造器处理，需确保两者不冲突。

## 8. 验证策略

- `zig build` 编译通过
- `zig build test` 全部测试通过
- 重点关注 edge_throw_records 测试（使用 `Error("negative")` 和 `e.message()`）
- 重点关注 edge_buf_reader 测试（IOError 路径）

## 9. 范围限定

本次改动**不涉及**：
- channel 元素类型精确推导（recv 仍是 i64，需 sema 层 ChannelValue<T> 修复，属于另一独立任务）
- Err trait 的 Display/Debug 等扩展（YAGNI）
- 错误链（error chain）等高级特性（YAGNI）

## 10. 关键文件路径索引

- Error trait 硬编码定义：`src/sema/type_check.zig:3402-3465`
- builtin 注册表：`src/builtin.zig`
- builtin 加载（sema 两遍）：`src/sema/type_check.zig:3466-3550`
- builtin 加载（IR）：`src/ir/decl_collector.zig:481`
- message/type_name IR 编译：`src/ir/expr_compiler.zig:3396-3407`
- IR 节点定义：`src/ir/node.zig:134-135`
- IR op_table 注册：`src/ir/op_table.zig:237-239`
- 执行分派表：`src/engine/dispatch_table.zig:543-545`
- execErrorMessage（fields[2] hack #1）：`src/engine/builtin_exec.zig:297-335`
- execObjTypeName：`src/engine/builtin_exec.zig:340+`
- execGateMakeErr（fields[2] hack #2）：`src/engine/control_exec.zig:142-199`
- ThrowValue/ErrorValue 定义：`src/value/control.zig:18-52`
- makeError：`src/value/mod.zig:426`
- makeIOError / makeThrowErr（fields[2] hack #3）：`src/syscall/util.zig:90-158`
- trait_resolve（无 Error 特判）：`src/sema/trait_resolve.zig`
- IOError.glue：`src/builtin/error/IOError.glue`
- CastError.glue：`src/builtin/error/CastError.glue`
- TimeError.glue：`src/builtin/error/TimeError.glue`
- error pack 声明：`src/builtin/error/pack.glue`
