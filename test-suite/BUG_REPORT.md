# Glue 引擎 Bug 修复追踪

> 本文档由 `test-suite/` 测试套件发现，记录所有引擎 bug 的修复优先级与临时绕过方案。
> 最后更新：2026-08-07（#1-#17 已修复；执行器审查 H1-H5、M1-M9、L1-L12 已修复）

---

## 修复优先级总览

| 优先级 | Bug ID | 简述 | 状态 |
|--------|--------|------|------|
| P0 | #3 | 数组变量索引返回 `<non-scalar>` | 已修复 (2026-08-05) |
| P0 | #4 | `arr.len()` 返回 `void` | 已修复 (2026-08-05) |
| P0 | #10 | `defer` 不执行 | 已修复 (2026-08-05) |
| P0 | #13 | Newtype match 解包不执行 | 已修复 (2026-08-05) |
| P1 | #1 | `!=` 运算符在 record/enum/newtype 始终返回 false | 已修复 (2026-08-05) |
| P1 | #6 | 闭包修改的 var 无法用 `==` 与字面量比较 | 已修复 (2026-08-05) |
| P1 | #12 | Trait 默认方法返回 `<non-scalar>` | 已修复 (2026-08-05) |
| P1 | #7 | `?` 传播运算符不工作 | 已修复 (2026-08-05) |
| P1 | #16 | `str + int` 字符串拼接返回 `<non-scalar>` | 已修复 (2026-08-05) |
| P2 | #5 | `for-in arr.iter()` 迭代不工作 | 已修复 (2026-08-05) |
| P2 | #8 | `?.` 链式访问不工作 | 已修复 (2026-08-05) |
| P2 | #9 | `str? ??` 合并返回 false | 已修复 (2026-08-05) |
| P2 | #11 | `while break` 不工作 | 已修复 (2026-08-05) |
| P2 | #14 | 返回 newtype 解包值的函数返回 `void` | 已修复 (2026-08-05) |
| P3 | #15 | 非 ASCII 字符串索引 panic | 已修复 (2026-08-05) |
| P3 | #17 | 字符串插值中 `bool == bool` 表达式恒返回 true | 已修复 (2026-08-05) |
| P3 | #2 | `==` 在 record 上始终返回 true（与 #1 关联） | 已修复 (2026-08-05) |

---

## P0 优先级（核心功能阻塞）

### Bug #3：数组变量索引返回 `<non-scalar>`

- **状态**：已修复 (2026-08-05)
- **现象**：使用 `i32` 变量作为数组索引时，返回 `<non-scalar>` 而非元素值
- **复现代码**：
  ```glue
  val arr = [10, 20, 30, 40]
  var i: i32 = 0
  println(arr[i])  // <non-scalar>（应为 10）
  ```
- **影响**：所有使用循环变量索引数组的代码（`while`、`for` 循环遍历数组）
- **根因**：局部变量读取（`Expr::Ident`）直接返回节点 ID，不依赖 `current_effect`。当 while 循环通过 WriteBack 更新变量值时，后续表达式在 WriteBack 完成前读取旧值。全局变量读取已有 `current_effect` 依赖（`compile_global_load`），但局部变量读取缺少。
- **修复**：
  1. 在 `compile_expr` 的 `Expr::Ident` 分支中，当 `current_effect` 存在时创建 CF_SEQ 依赖节点，确保局部变量读取在前序副作用完成后执行（与 `compile_global_load` 机制一致）
  2. 在 `register_while_subgraph`、`register_loop_subgraph`、`register_for_subgraph` 中编译子图内容前重置 `current_effect = None`，避免在循环体帧 `reset_loop_iteration` 后因外部 effect 依赖导致死锁
- **验证**：14 个功能测试全部通过，5 个性能测试全部通过，无回归

### Bug #4：`arr.len()` 返回 `void`

- **状态**：已修复 (2026-08-05)
- **现象**：数组 `.len()` 方法返回 `void` 而非长度值
- **复现代码**：
  ```glue
  val arr = [1, 2, 3]
  println(arr.len())  // void（应为 3）
  ```
- **影响**：无法动态获取数组长度，限制所有数组迭代场景
- **根因**：IR 编译器的 `expr_type_id` 方法仅使用 `info.type_name` 获取类型名，未 fallback 到 `info.type_desc.type_name`。当数组字面量推断后 `type_name` 为 `None` 但 `type_desc.type_name` 为 `"array"` 时，`expr_type_name` 正确返回 `"array"`，而 `expr_type_id` 返回 `None`。这导致 `lookup_intrinsic` 中 `type_id=None`，方法签名查询失败（`sig=None`），intrinsic 方法（如 `len()`）无法降级为 compute_fn 节点，最终返回 `void`。
- **修复**：修改 `Ir.rs` 的 `expr_type_id` 方法，使其与 `expr_type_name` 逻辑一致——优先使用 `info.type_name`，fallback 到 `info.type_desc.type_name`，确保数组等复合类型的 `type_id` 能正确解析，intrinsic 方法可正常降级。
- **验证**：`arrays` 测试新增 4 个 `.len()` 用例（基本长度、空数组、6 元素数组、`while + len()` 动态边界迭代）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #10：`defer` 不执行

- **状态**：已修复 (2026-08-05)
- **现象**：`defer` 块中的代码不执行，LIFO 顺序无效
- **复现代码**：
  ```glue
  var log: str = ""
  fun lifo(): void {
      defer log = log + "A"
      defer log = log + "B"
      log = log + "body|"
  }
  lifo()
  println(log)  // "body|"（应为 "body|BA"）
  ```
- **影响**：资源清理、日志记录等依赖 defer 的场景全部失效
- **根因**：`Ir.rs` 的 `compile_lambda` 方法在编译 lambda/嵌套函数体时未设置 `current_function_sg`。defer 语句编译时通过 `current_function_sg` 将 defer body 注册到当前函数子图的 `defer_table`，但 `current_function_sg` 为 `None`（或指向外层函数），导致 defer_table 未被填充，Engine 帧完成时无法找到 defer body 执行。顶层函数不受影响（`compile_function` 正确设置了 `current_function_sg`），因此顶层函数的 defer 正常工作。
- **修复**：在 `compile_lambda` 中编译 body 前保存 `current_function_sg`，设置为 `Some(sg_id)`（lambda 子图 ID），body 编译后恢复原值。这确保 defer 语句能正确注册到 lambda 子图的 `defer_table`，Engine 帧完成时按 LIFO 顺序执行。
- **验证**：`throw` 测试新增 4 个 defer 用例（LIFO 顺序、单个 defer、无 defer 控制组、多 defer 顺序）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #13：Newtype match 解包不执行

- **状态**：已修复 (2026-08-05)
- **现象**：`match` 模式匹配 newtype 时，分支体不执行，函数返回 `void`
- **复现代码**：
  ```glue
  type Meters = Meters(f64)
  fun areaM(m: Meters): f64 {
      match m {
          Meters(v) => v * v  // 不执行
      }
  }
  println(areaM(Meters(5.0)))  // void（应为 25.0）
  ```
- **影响**：所有依赖 newtype 解包运算的场景
- **根因**：`Engine.rs` 的 `compute_pattern_ctor_match` 和 `compute_pattern_adt_field_get` 两个 compute_fn 都不处理 `HeapObj::Newtype`。newtype 值在运行时表示为 `HeapObj::Newtype(NewtypeValue { type_name, inner })`，但模式匹配的构造器判别（`compute_pattern_ctor_match`）和字段提取（`compute_pattern_adt_field_get`）都缺少对 `HeapObj::Newtype` 的 match 分支，导致构造器判别返回 `false`（所有 arm 不匹配）、字段提取返回 `Value::VOID`（模式变量 `v` 绑定到 void）。
- **修复**：
  1. `compute_pattern_ctor_match` 新增 `HeapObj::Newtype(n) => n.type_name == *ctor_name` 分支。Newtype 的构造器名 == 类型名，所以比较 `NewtypeValue.type_name`。
  2. `compute_pattern_adt_field_get` 新增 `HeapObj::Newtype(n)` 分支，`idx == 0` 时通过 `ValueArena::with_global(|a| a.get_value(n.inner))` 解引用 `inner` 句柄获取内部值。
- **验证**：`newtype` 测试新增 4 个 match 解包用例（f64 解包、返回值解包、i64 解包、解包后重新包装）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

---

## P1 优先级（重要功能缺失）

### Bug #1：`!=` 运算符在 record/enum/newtype 始终返回 false

- **状态**：已修复 (2026-08-05)
- **现象**：`p1 != p2` 始终返回 `false`，即使两者字段不同
- **复现代码**：
  ```glue
  val p1 = Point(3, 4)
  val p3 = Point(5, 6)
  println(p1 != p3)      // false（应为 true）
  println(Red != Green)   // false（应为 true）
  ```
- **影响**：record、enum、newtype 的不等比较全部失效
- **根因**：`Ir.rs` 的 `select_binary_compute_fn` 对复合类型（record/adt/newtype/array/closure/throw 等）的 `==`/`!=` 运算返回标量比较函数 `CF_EQ_I32`/`CF_NE_I32`。复合类型的 `Value::as_i32()` 恒为 0，导致所有复合类型被判为相等，`!=` 恒返回 false。此外 `Value.rs` 的 `value_equals` 调用 `heap_equals` 时传递 `ValueArena::default()`（空 arena），无法解析 `ValueHandle` 引用的实际值，导致 newtype 内部值比较失败。
- **修复**：
  1. `Engine.rs` 新增 `compute_eq_obj`（CF_EQ_OBJ=298）和 `compute_ne_obj`（CF_NE_OBJ=299），通过 `ValueArena::with_global` 获取真实 arena，调用 `value_equals_with_arena` 进行深度语义比较。
  2. `Ir.rs` 的 `select_binary_compute_fn` 新增复合类型检测分支：当 `op` 为 `Eq`/`NotEq` 且 `ty_meta.is_none()`（非标量类型）时分派到 `CF_EQ_OBJ`/`CF_NE_OBJ`；并在 `pure_compute_fn_set` 中注册两者为纯函数。
  3. `Value.rs` 将 `value_equals`/`heap_equals` 改为 pub，新增 `value_equals_with_arena` 接受 arena 参数用于 `ValueHandle` 解引用，`heap_equals` 内部调用 `value_equals_with_arena` 确保嵌套复合类型比较正确。
- **验证**：`records`、`adt`、`newtype` 测试各新增 `!=` 用例（值不等、字段不等、双重否定 `!(!=)`、enum 不等、newtype 不等）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #6：闭包修改的 var 无法用 `==` 与字面量比较

- **状态**：已修复 (2026-08-05)
- **现象**：闭包内修改的 `var`，在外部用 `==` 与字面量比较时返回 `false`，即使值正确
- **复现代码**：
  ```glue
  var y: i32 = 0
  val inc = fun() { y = y + 1 }
  inc(); inc(); inc()
  println(y)        // 3（正确）
  println(y == 3)   // false（应为 true）
  ```
- **影响**：所有依赖闭包修改外部变量并进行比较的场景
- **根因**：与 Bug #3 同根因。局部变量读取（`Expr::Ident`）不依赖 `current_effect`，导致闭包调用（产生副作用）后的变量读取在 WriteBack 完成前执行，读到旧值。
- **修复**：随 Bug #3 的 `current_effect` 修复一并解决。在 `Expr::Ident` 分支添加 `current_effect` CF_SEQ 依赖，确保变量读取在前序副作用（包括闭包调用的 WriteBack）完成后执行。
- **验证**：closures 测试套件全部通过，恢复了正常的 `y == 3` 比较方式，无需使用返回值绕过。

### Bug #12：Trait 默认方法返回 `<non-scalar>`

- **状态**：已修复 (2026-08-05)
- **现象**：Trait 中定义的默认方法（有方法体的方法）在被调用时返回 `<non-scalar>`
- **复现代码**：
  ```glue
  trait Greet {
      fun name(self): str
      fun hello(self): str {
          "Hello, " + self.name()  // 默认实现
      }
  }
  type Ordering: Greet = | Lt | Eq | Gt {
      fun name(self): str { ... }
      // 未覆盖 hello，使用默认实现
  }
  println(Lt.hello())  // <non-scalar>（应为 "Hello, less"）
  ```
- **影响**：Trait 默认方法完全失效，必须显式实现所有方法
- **根因**：trait 默认方法 body 中的 `self` 缺少具体类型信息。Sema 将 trait 默认方法中的 `self` 类型注册为 "void"（因 trait 方法无具体类型），导致 `expr_type_name(self)` 返回 "void"、`expr_type_id(self)` 返回 None，`self.name()` 方法分派失败（路径 2 跳过，路径 3 因 type_id=None 跳过，call_target 未绑定），运行时 `compute_call_launch` 返回 VOID，显示为 `<non-scalar>`。
- **修复**：采用单态化方案：
  1. `trait_default_subgraphs` 键从 `(trait_idx, method_idx)` 改为 `(type_id, trait_idx, method_idx)`，为每个实现 trait 且未显式覆写该方法的类型生成专用子图。
  2. `compile_trait_default_method` 接受 `impl_type_name` 参数，编译特化版本时设置 `trait_self_type`，编译完成后重置。
  3. `expr_type_name`/`expr_type_id` 在 `trait_self_type` 存在且 expr 是 `Ident("self")` 时，直接返回 `trait_self_type` 对应的类型名/type_id，覆盖 Sema 注册的 "void"。
  4. build() 步骤 0a-trait 遍历 witness_table，为每个实现 trait 的类型预注册特化子图；步骤 2c 为每个需要特化的类型编译特化版本。
  5. 路径 3 用 `(type_id, trait_idx, method_idx)` 查找特化子图。
- **验证**：`traits` 测试中 `Ordering` 和 `Animal` 类型移除 `hello` 显式实现，改用 trait 默认方法；`Lt.hello()`/`Eq.hello()`/`Gt.hello()`/`Animal.hello()` 均返回正确结果；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #7：`?` 传播运算符不工作

- **状态**：已修复 (2026-08-05)
- **现象**：`expr?` 传播运算符对 Nullable 类型不工作，null 时导致调用方函数提前终止
- **复现代码**：
  ```glue
  fun propagateOpt(x: i32?): i32? {
      val y = x?
      y + 1
  }
  val r2: i32? = propagateOpt(null)  // main 函数被错误终止
  ```
- **影响**：所有使用 `?` 运算符进行 Nullable 传播的场景
- **根因**：包含两层问题：
  1. **Engine 缺失 Nullable 分支**：`compute_propagate` 仅处理 `ThrowVal`（Ok/Err），对 `Value::Null` 直接透传，未设置 `ControlSignal::Return` 导致 null 不传播。
  2. **内联展开破坏函数级作用域**：Analyzer 的 `inline_pass` 将包含 `?` 运算符的纯函数标记为内联候选，IrBuilder 通过 `compile_inline_expansion` 将函数体直接编译到调用方子图中。`compute_propagate` 通过 `ControlSignal::Return` 实现提前返回，该信号是函数级作用域——内联后 `Return(null)` 被设置在调用方帧上，导致调用方函数提前终止而非仅内联体返回。
- **修复**：
  1. `Engine.rs` 的 `compute_propagate` 新增 `else if v.is_null()` 分支：值为 null 时设 `frame.control_signal = ControlSignal::Return(v.clone())`，使函数提前返回 null。
  2. `Engine.rs` 的 `run_frame_sync_inner` 普通节点处理路径新增 compute_fn 控制信号检查：compute_fn（如 compute_propagate）直接设置 `control_signal` 后，跳过 `notify_downstream` 并 `continue`，避免在控制信号已设时继续处理下游节点。
  3. `Analyzer.rs` 的 `inline_pass` 新增 `has_propagate` 检查：函数体包含 `Expr::Propagate`（`?` 运算符）时不内联，因为 `ControlSignal::Return` 是函数级作用域，内联展开会错误终止调用方。
- **验证**：`nullable` 测试新增 2 个 `?` 传播用例（非 null 解包运算、null 提前返回）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #16：`str + int` 字符串拼接返回 `<non-scalar>`

- **状态**：已修复 (2026-08-05)
- **现象**：字符串与整数字面量拼接时，返回 `<non-scalar>` 而非拼接后的字符串
- **复现代码**：
  ```glue
  println("" + 6)           // <non-scalar>（应为 "6"）
  println("result=" + 42)   // <non-scalar>（应为 "result=42"）
  ```
- **影响**：所有 `str + int` 字符串拼接场景，包括字符串插值的底层实现
- **根因**：`Ir.rs` 的 `select_binary_compute_fn` 仅在 LHS 类型为 `"str"` 且 op 为 `Add` 时返回 `CF_STR_CONCAT`，但 `compute_str_concat` 只处理 `(Str, Str)`，对 `(Str, int)` 等非字符串操作数返回 TypeError。`compile_binary` 直接编译 LHS/RHS 节点后用 `select_binary_compute_fn` 分派，未在 `str + non-str` 场景将非字符串操作数转换为字符串。
- **修复**：在 `Ir.rs` 的 `compile_binary` 中新增 `str + non-str` / `non-str + str` 混合类型检测：当 `Add` 运算的操作数任一方为 `str` 类型时，将非字符串操作数通过 `compute_reflect_format`（idx 290）转为字符串节点，然后用 `CF_STR_CONCAT` 拼接（与字符串插值 `"{expr}"` 的降级路径一致）。新增 `make_reflect_format_node` 辅助方法封装此转换。
- **验证**：`strings` 测试新增 7 个混合拼接用例（`str + int`、`int + str`、`str + bool`、`bool + str`、零值拼接、前后缀拼接）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

---

## P2 优先级（功能受限）

### Bug #5：`for-in arr.iter()` 迭代不工作

- **状态**：已修复 (2026-08-05)
- **现象**：`for x in arr.iter()` 无法正确迭代数组元素
- **复现代码**：
  ```glue
  for n in arr.iter() {
      sum = sum + n  // 不执行或返回错误
  }
  ```
- **影响**：数组迭代语法糖失效
- **根因**：与 Bug #3 同根因。For 循环体通过 `register_for_subgraph` 编译为递归子图，循环体内的变量读取（`Expr::Ident`）缺少 `current_effect` 依赖。当循环通过 WriteBack 更新变量值时，后续表达式在 WriteBack 完成前读取旧值，导致迭代不工作。
- **修复**：随 Bug #3 的 `current_effect` 修复一并解决。在 `Expr::Ident` 分支添加 `current_effect` CF_SEQ 依赖，并在 `register_for_subgraph` 中编译循环体前重置 `current_effect = None`，确保变量读取在前序副作用完成后执行。
- **验证**：`arrays` 测试新增 3 个 for-in 用例（数值数组求和、空数组迭代、字符串数组拼接）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #8：`?.` 链式访问不工作

- **状态**：已修复 (2026-08-05)
- **现象**：可空链式访问 `obj?.field` 无法使用，短路返回 null 后与 `null` 比较返回 false
- **复现代码**：
  ```glue
  val city = user?.addr?.city  // 短路返回 null
  println(city == null)        // false（应为 true）
  ```
- **影响**：可空类型的链式访问及后续 null 比较失效
- **根因**：与 Bug #9 同根因。`arena.type_name` 对 `ConcreteType::Nullable(inner)` 递归取 inner 名，导致 `str?` 的 `expr_type_name` 返回 `"str"`（内层类型名）。`select_binary_compute_fn` 的 `Eq` 因此分派到 `CF_EQ_STR`，而 `compute_eq_str` 通过 `heap_obj()` 匹配，`Value::Null` 的 `heap_obj()` 返回 `None`，导致 null 比较恒返回 false。
- **修复**：随 Bug #9 一并修复。新增 `expr_is_nullable` 方法检查 `ExprInfo.type_desc.type_name == "nullable"`，在 `select_binary_compute_fn` 中 nullable 类型的 `Eq`/`NotEq` 分派到 `CF_EQ_OBJ`/`CF_NE_OBJ`（`value_equals_with_arena` 正确处理 `Null` 判别式比较）。
- **验证**：`nullable` 测试新增 3 个 `?.` 链式访问用例（非空链式访问、null 短路返回 null、链式访问带 `??` 合并）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #9：`str? ??` 合并返回 false

- **状态**：已修复 (2026-08-05)
- **现象**：`str?` 类型的 `??` 合并运算符结果与字符串比较返回 false
- **复现代码**：
  ```glue
  val s: str? = null
  println(s ?? "default")                  // "default"（正确）
  println((s ?? "default") == "default")    // false（应为 true）
  ```
- **影响**：字符串可空类型的合并运算结果比较失败
- **根因**：两层问题：
  1. **`??` 分派错误**：`select_binary_compute_fn` 中 `str` 类型分支将 `Elvis` 运算符错误分派为 `CF_EQ_STR`（字符串相等比较），而非 `CF_ELVIS`。
  2. **nullable `==` 分派错误**：`arena.type_name` 对 `Nullable(inner)` 递归取 inner 名，导致 `str?` 的 `expr_type_name` 返回 `"str"`，`Eq` 分派到 `CF_EQ_STR`。`compute_eq_str` 不处理 `Value::Null`（`heap_obj()` 返回 `None`），导致 `?.` 短路或 `??` 合并产生的 null 值比较恒返回 false。
- **修复**：
  1. `Ir.rs` 的 `select_binary_compute_fn` 在类型分支前优先处理 `Elvis` 运算符，直接返回 `CF_ELVIS`。
  2. `Ir.rs` 新增 `expr_is_nullable` 方法（检查 `ExprInfo.type_desc.type_name == "nullable"`），在 `select_binary_compute_fn` 中 nullable 类型的 `Eq`/`NotEq` 分派到 `CF_EQ_OBJ`/`CF_NE_OBJ`（`value_equals_with_arena` 正确处理 `Null` 判别式比较）。
  3. `Engine.rs` 的 `compute_elvis` 实现运行时逻辑：lhs 为 null 时返回 rhs，否则返回 lhs。
- **验证**：`nullable` 测试新增 `str? ??` 合并比较用例（null 合并后 `==` 比较、非 null 合并后 `==` 比较）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #11：`while break` 不工作

- **状态**：已修复 (2026-08-05)
- **现象**：`while` 循环中的 `break` 语句不生效，循环无法提前退出
- **复现代码**：
  ```glue
  var j: i32 = 0
  while j < 100 {
      if j >= 5 { break }  // break 不生效
      j = j + 1
  }
  println(j)  // 100（应为 5）
  ```
- **影响**：所有依赖 `break` 提前退出循环的场景
- **根因**：与 Bug #3 同根因。break 语句后循环体的变量更新（`j = j + 1`）通过 WriteBack 写回，但后续条件判断（`j >= 5`）的变量读取不依赖 `current_effect`，在 WriteBack 完成前读取旧值，导致 break 条件永不满足。
- **修复**：随 Bug #3 的 `current_effect` 修复一并解决。
- **验证**：control_flow 测试套件新增 `while break exits at 5` 测试，全部通过。

### Bug #14：返回 newtype 解包值的函数返回 `void`

- **状态**：已修复 (2026-08-05，随 #13 一并修复）
- **现象**：函数中通过 match 解包 newtype 并返回值时，返回 `void`（与 #13 关联）
- **复现代码**：
  ```glue
  fun celsiusRaw(c: Celsius): f64 {
      match c {
          Celsius(v) => v  // 不执行
      }
  }
  println(celsiusRaw(Celsius(100.0)))  // void（应为 100.0）
  ```
- **影响**：所有返回 newtype 解包值的函数
- **根因**：与 #13 同根因。`compute_pattern_ctor_match` 和 `compute_pattern_adt_field_get` 不处理 `HeapObj::Newtype`，导致 newtype match 分支不匹配、模式变量绑定到 void，函数返回 void。
- **修复**：随 #13 一并修复。`compute_pattern_ctor_match` 新增 `HeapObj::Newtype(n) => n.type_name == *ctor_name` 分支；`compute_pattern_adt_field_get` 新增 `HeapObj::Newtype(n)` 分支提取 inner 值。
- **验证**：`newtype` 测试中 `celsiusRaw(Celsius(100.0)) == 100.0` 用例通过；14 个功能测试 + 5 个性能测试全部通过，无回归

---

## P3 优先级（边缘场景）

### Bug #15：非 ASCII 字符串索引 panic

- **状态**：已修复 (2026-08-05)
- **现象**：对包含非 ASCII 字符（如 `'é'`、`'你'`）的字符串进行索引访问时，字符显示为 `U+XXXX` 转义形式而非实际字符；char 字面量 `'é'` 触发 panic
- **错误信息**：`end byte index ... is not a char boundary`
- **复现代码**：
  ```glue
  val u = "héllo你好"
  println(u[1])  // 原显示 U+00E9（应为 é）；'é' 字面量 panic
  ```
- **影响**：Unicode 字符串的索引访问与 char 字面量
- **根因**：三层问题：
  1. **`scan_char` 按单字节前进**：`Ast.rs` 的 `scan_char` 对非 ASCII 字符（多字节 UTF-8 序列）仅 `self.pos += 1`，导致 `pos` 停在字符中间，后续 `&self.source[start..self.pos]` 切片 panic（非 char boundary）。
  2. **`parse_char_value` 仅取首字节**：第 5705 行 `bytes[0] as u32` 对多字节字符仅取首字节值，无法还原 Unicode 码点。
  3. **`format_value` 对非 ASCII char 输出 U+转义**：`Reflect.rs` 两处 char 格式化逻辑对码点 > 0x7F 的字符输出 `U+{:04X}` 转义形式，而非实际字符。
- **修复**：
  1. `Ast.rs` 的 `scan_char` 非 ASCII 分支按 UTF-8 起始字节判断字符长度（1/2/3/4 字节），按字符边界前进 `self.pos`。
  2. `Ast.rs` 的 `parse_char_value` 用 `content.chars().next().map(|c| c as u32)` 解码完整 UTF-8 序列为 Unicode 码点。
  3. `Reflect.rs` 两处 char 格式化逻辑改用 `char::from_u32(c)` 将码点转为字符后输出，非法码点才 fallback 到 `U+XXXX` 转义。
- **验证**：`strings` 测试新增 4 个 Unicode 字符索引用例（`é`、`你`、`好`、CJK 首字符）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #17：字符串插值中 `bool == bool` 表达式恒返回 true

- **状态**：已修复 (2026-08-05)
- **现象**：字符串插值 `"{bool_expr}"` 中直接嵌入 `bool == bool` 比较表达式时，结果恒为 `true`，而相同表达式直接打印或赋值给变量后再插值均正常
- **复现代码**：
  ```glue
  println(true == false)              // false（正确）
  val r: bool = true == false
  println(r)                          // false（正确）
  println("{r}")                      // false（正确）
  println("{true == false}")          // true（错误，应为 false）
  println("d: {5 == 10}")            // "d: false"（正确，int == int 正常）
  ```
- **影响**：字符串插值中直接嵌入 `bool == bool` 表达式的场景。注意 `int == int` 等其他类型比较在插值中正常，仅 `bool == bool` 受影响
- **根因**：`Inference.rs` 的 `infer_expr_inner` 对 `Expr::StrInterp(_)` 仅返回 `ConcreteType::Str`，未递归推断插值内部的子表达式，导致子表达式的 ExprInfo 未注册到 `expr_types`。IR 编译 `select_binary_compute_fn` 查 `expr_type_name(lhs)` 返回 `None`，回退 `ty_name = "i32"`，将 `bool == bool` 误分派到 `CF_EQ_I32`。`Value::as_int_i128` 对 `ScalarTag::Bool` 走 `_ => 0` 分支（line 1237），`true`/`false` 均读为 0，`0 == 0` 恒为 true。`int == int` 正常是因为 `as_i32` 对整数返回真实值
- **修复**：`Inference.rs` 的 `Expr::StrInterp` 分支递归调用 `infer_expr` 推断每个 `InterpolationPart::Expression` 子表达式，确保其 ExprInfo 注册到 `expr_types`，使 IR 编译能正确按操作数类型分派 compute_fn
- **验证**：`strings` 测试新增 6 个插值比较用例（`bool == bool` true/false、`int == int` true/false、带前缀的 bool/int 插值比较）全部通过；14 个功能测试 + 5 个性能测试全部通过，无回归

### Bug #2：`==` 在 record 上始终返回 true（与 #1 关联）

- **状态**：已修复 (2026-08-05，随 #1 一并修复）
- **现象**：`p1 == p3` 返回 `true`，无论字段是否相同
- **复现代码**：
  ```glue
  val p1 = Point(3, 4)
  val p3 = Point(5, 6)
  println(p1 == p3)  // true（应为 false）
  ```
- **影响**：record 相等性判断失效
- **根因**：与 #1 同根因。`select_binary_compute_fn` 对复合类型的 `==` 返回 `CF_EQ_I32`，`as_i32()` 恒为 0 导致所有复合类型判为相等。
- **修复**：随 #1 一并修复。`select_binary_compute_fn` 的复合类型检测分支对 `Eq` 分派到 `CF_EQ_OBJ`，调用 `compute_eq_obj` 进行深度语义比较。
- **验证**：`records` 测试中 `check(p == p2, "record value equality")` 验证相等返回 true，`check(p != p3, "record inequality (!=)")` 验证不等返回 false（原 bug 场景）；14 个功能测试 + 5 个性能测试全部通过，无回归

---

## 语法限制（非 Bug，需文档说明）

这些是语言设计选择而非 bug，但需要文档明确说明：

| 限制 | 说明 | 绕过方式 |
|------|------|---------|
| 闭包不支持显式返回类型标注 | `fun(n: i32): i32 { ... }` 解析错误 | 省略返回类型 `fun(n: i32) { ... }` |
| 字符串不支持 `{{` 花括号转义 | `"{{not a var}}"` 解析错误 | 避免使用花括号转义 |

---

## 修复检查清单

每修复一个 bug，请：

1. 在对应测试文件中移除临时绕过方案，恢复标准语法
2. 移除测试文件头部的"注意"注释
3. 运行 `cd test-suite/functional/<name> && glue run` 验证修复
4. 运行完整测试套件确认无回归：
  ```bash
  cd /Users/haojunhuang/CLionProjects/Glue
  GLUE=./rust/target/release/glue
  for d in test-suite/functional/*/; do
      name=$(basename "$d")
      result=$(cd "$d" && $GLUE run 2>&1 | tail -1)
      echo "  $name: $result"
  done
  ```
5. 在本文档中将状态从"待修复"改为"已修复"，记录修复日期

---

## 执行器审查 Bug 汇总（2026-08-07）

> 本次审查针对 `src/engine/` 与 `src/ir/Compute.rs` 的调度核心、帧管理、子图调用、异步运行时、并发策略进行静态分析，共发现 31 个问题。已去除误报和重复项，按严重程度分级如下。

### 修复优先级总览

| 优先级 | 编号 | 模块 | 问题简述 | 状态 |
|--------|------|------|----------|------|
| P0 | H1 | 并发策略 | Multi 模式 worker 在有 pending timer 时全部退出 → 引擎 panic | 已修复 (2026-08-07) |
| P0 | H2 | 事件投递 | 帧注册 waiter 后 insert 回 HashMap 前事件丢失 | 已修复 (2026-08-07) |
| P0 | H3 | 事件投递 | check-then-register TOCTOU 竞态 | 已修复 (2026-08-07) |
| P0 | H4 | 异步调用 | alloc_id + register 分离，子帧可在注册前完成被误判为 sync | 已修复 (2026-08-07) |
| P0 | H5 | 完成回调 | pending_completions 兜底路径丢弃 child_signal | 已修复 (2026-08-07) |
| P1 | M1 | 调度核心 | notify_downstream 腐蚀 PENDING_EXTERNAL 哨兵值 | 已修复 (2026-08-07) |
| P1 | M2 | 调度核心 | pending_inputs u8 溢出与哨兵混淆 | 已修复 (2026-08-07) |
| P1 | M3 | 帧管理 | reset_loop_iteration 未清除 body_frame 的 select_timers | 已修复 (2026-08-07) |
| P1 | M4 | 帧管理 | 嵌套循环 body_frame_id 未清除 → 复用过时内层帧 | 已修复 (2026-08-07) |
| P1 | M5 | 帧管理 | reset_loop_iteration 未清除 loop_frame 的 ready_queue | 已修复 (2026-08-07) |
| P1 | M6 | 调度核心 | iter_guard 超限静默返回导致活锁 | 已修复 (2026-08-07) |
| P1 | M7 | 计算路径 | 同步路径空队列返回未就绪的 return_node 值 | 已修复 (2026-08-07) |
| P1 | M8 | 计算路径 | 同步路径非 Call 的 pending 未被清除 | 已修复 (2026-08-07) |
| P1 | M9 | 计算路径 | compute_closure_call 的 self_upvalue_idx 无边界检查 | 已修复 (2026-08-07) |
| P2 | L1 | 内存泄漏 | cleanup 从未被调用 → entries/fired_set 无界增长 | 已修复 (2026-08-07) |
| P2 | L2 | 并发策略 | check_timers 推帧后直接 park 不重新检查 | 已修复 (2026-08-07) |
| P2 | L3 | 并发策略 | worker park 前的 lost-wakeup | 已修复 (2026-08-07) |
| P2 | L4 | 计算路径 | force_lazy_value_sync 裸指针别名 UB | 已修复 (2026-08-07) |
| P2 | L5 | 并发策略 | notify_all 惊群效应 | 已修复 (2026-08-07) |
| P2 | L6 | 事件投递 | on_event_arrived 的 O(n²) retain | 已修复 (2026-08-07) |
| P3 | L7 | 调度核心 | extract_child_return 注释与 same_function 帧语义不符 | 已修复 (2026-08-07) |
| P3 | L8 | 子图调用 | LoopBody break/return 递归无深度限制 | 已修复 (2026-08-07) |
| P3 | L9 | 异步运行时 | TimerRuntime::next_id 无溢出检查 | 已修复 (2026-08-07) |
| P3 | L10 | 子图调用 | complete_and_wake_caller LoopBody 路径未处理 loop_frame 缺失 | 已修复 (2026-08-07) |
| P3 | L11 | 子图调用 | pending_completions 对同一 caller 多次完成互相覆盖 | 已修复 (2026-08-07) |
| P3 | L12 | 计算路径 | 同步路径 LoopBody Continue/None 不重置循环帧 | 已修复 (2026-08-07) |

---

### P0 优先级（高危：导致 panic / 死锁 / 静默错误结果）

#### Bug H1：Multi 模式 worker 在有 pending timer 时全部退出 → 引擎 panic

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Strategy.rs:280-286`
- **问题**：当 `active_count` 减到 0 时，最后一个 worker 直接 `return` 退出，不检查是否有 pending timer 或 event_waiters。若所有帧都 `await timer.sleep()`，所有 worker 相继退出，定时器到期时没有 worker 存在来处理事件，帧永远无法被唤醒，最终 `run_multi`（Strategy.rs:220）的 `expect("no result produced")` 触发 panic
- **对比**：`run_single`（Strategy.rs:134-154）正确地检查了 `next_deadline` 和 `event_waiters`，在有 pending timer 时 park 到 deadline。Multi 模式的 worker_main 在步骤 4 直接退出，永远到不了步骤 5 的 park 逻辑
- **触发场景**：Multi 模式下包含 `await timer.sleep()` 的程序。例如 2 个 worker，一个帧 await sleep(5s)，两个 worker 都找不到工作后相继退出，5 秒后定时器到期但无人处理，引擎 panic
- **修复**：在步骤 4 `active_count == 0` 时，最后一个 worker 退出前检查 `timer_runtime.next_deadline()` 和 `event_waiters`。若有 pending timer 或 event_waiters，不退出，fall through 到步骤 5 park 到 deadline（active_count 保持为 0，步骤 5 末尾 `+1` 恢复）；若无 pending 才退出。锁顺序为 active → timer → event_waiters（无反向获取，不会死锁）
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug H2：事件投递竞态 — 帧注册 waiter 后、insert 回 HashMap 前事件丢失

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:692`（注册 waiter 后 return）+ `src/engine/Schedule.rs:953`（才 insert 回 HashMap）
- **问题**：帧的挂起流程跨越两个函数：`run_frame_nodes` 在行 692 注册 event_waiter 并设置 Suspended 状态后返回；`process_frame` 在行 953 才将帧 insert 回 `frames` HashMap。在这两步之间，帧**不在** HashMap 中但**已在** event_waiters 中。若另一 worker 在此窗口内调用 `on_event_arrived`（AsyncRt.rs:248），`frames.remove(&fid)` 返回 None → `continue`，事件被丢弃。帧随后被 insert 回 HashMap 状态为 Suspended，但其 event_waiter 已被移除，没有任何机制会再次投递该事件，帧永久挂起
- **对比**：`SubgraphComplete` 事件有 `pending_completions` 机制兜底此竞态，但 `TimerFired`/`ChannelReady`/`AsyncJoin` 三种事件**没有等价机制**
- **触发场景**：Multi 模式下，帧 A await timer/channel/async 事件，同时另一个 worker 恰好在 A 的 `run_frame_nodes` 返回后、`process_frame` insert 回 HashMap 前触发了对应事件
- **修复**：
  1. Engine 结构体新增 `pending_events: HashMap<FrameId, (RuntimeEvent, Value)>` 字段（与 `pending_completions` 对称）
  2. `on_event_arrived` 中 `frames.remove(&fid)` 返回 None 时，不再 `continue` 丢弃事件，而是将 `(event, value)` 存入 `pending_events[fid]`（waiter 已在上方从 event_waiters 移除，无需重复清理）
  3. `process_frame` 的 Suspended 分支，insert 帧后检查 `pending_events`，若有则调用 `apply_event_to_frame` 注入事件值 + 唤醒
  4. 提取 `apply_event_to_frame` 辅助方法（`on_event_arrived` 和 `process_frame` 共用），消除代码重复
  5. `cancel_frame` 中清理 `pending_events`，避免被取消帧残留事件
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug H3：check-then-register TOCTOU 竞态

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/AsyncRt.rs:217`（检查 is_fired）+ `src/engine/Schedule.rs:692`（注册 waiter）
- **问题**：`resolve_and_check_await` 检查事件是否就绪（timer 的 `is_fired`、channel 的 `recv`、async 的 `try_get_result`），返回 None 表示未就绪。然后调用方在行 692 注册 waiter。在"检查返回 None"和"注册 waiter"之间存在时间窗口：
  1. Worker W1：`is_fired(timer_id)` → false
  2. Worker W2：`check_timers` → `check_and_fire` 弹出该 timer → `on_event_arrived(TimerFired(timer_id))`。event_waiters 中没有该 waiter（尚未注册）→ 事件丢弃
  3. W1：注册 `(TimerFired(timer_id), fid)` 到 event_waiters，帧挂起
  4. 定时器已从堆中弹出，不会再触发，帧永久挂起
- **影响范围**：Channel 路径（`ch.recv()` 返回 None 后另一 worker send 触发 ChannelNotify）和 AsyncJoin 路径（`try_get_result` 返回 None 后子帧完成触发 on_event_arrived）同理
- **触发场景**：Multi 模式下，短定时器（duration 接近 0）、高频 channel 操作、或快速完成的 async 调用
- **修复**：将 `resolve_and_check_await` 重构为 `resolve_check_and_register_await`，把"检查就绪"和"注册 waiter"合并到同一锁临界区，消除 TOCTOU 窗口：
  - **Timer**：持 `timer_runtime` 锁执行 `start` + `is_fired`，未就绪则在释放 timer 锁后注册 waiter（`check_and_fire` 也在 timer 锁内，无法在 start 和 is_fired 之间弹出 timer）
  - **AsyncJoin**：持 `async_join_runtime` 锁执行 `try_get_result`，未就绪则在同锁内注册 waiter（`set_result` 也在该锁内，无法在两步之间触发）
  - **Channel**：`ch.recv()` 返回 None 后立即注册 waiter，`ChannelNotify` → `on_event_arrived` 会查 event_waiters，此时 waiter 已在位
  - 调用方（Schedule.rs）不再重复 push event_waiters，仅设帧状态后 return
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug H4：async call 的 alloc_id + register 分离，子帧可在注册前完成被误判为 sync

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:625-631`
- **问题**：`child_fid` 在行 625 被推入队列后，另一个 worker 可以立即拾取并执行该子帧。如果子帧在行 631（`register`）之前完成，`process_frame`（Schedule.rs:959）调用 `find_by_child(child_fid)` 返回 None（entry 尚未注册），子帧被当作 sync call 处理：
  1. `complete_and_wake_caller` 被调用，返回值被写入 `pending_completions[caller_fid]`
  2. 当前 worker 继续执行行 631（register）、行 638（set_value 写入 async_handle）、notify_downstream
  3. 当调用方帧后续挂起时，`process_frame` 检查 `pending_completions`，发现条目，将返回值写入 call_node（而非 await_node），覆盖了 async_handle 值
  4. await 节点永远得不到值，帧状态混乱
- **对比**：代码中已定义 `alloc_and_registered`（AsyncRt.rs:133-138）来消除此竞态窗口，但**从未被调用**（全项目 grep 无结果）
- **触发场景**：Multi 模式下，async 调用的子图非常小（快速完成），另一个 worker 在 register 之前拾取并执行完子帧
- **修复**：将 async call 路径重构为"先注册再 push"：
  1. 对 async call，先调用 `alloc_and_register(child_fid)` 原子分配 async_id 并注册映射，再 `queue.push(child_fid)`
  2. 子帧被任何 worker 拾取时，`find_by_child` 可正确匹配 → 走 async 完成路径（`set_result` + 触发 AsyncJoin 事件）
  3. sync call 路径不变（其竞态由 `pending_completions` 兜底：父帧不在 HashMap 时子帧完成，`complete_and_wake_caller` 暂存完成信息，`process_frame` insert 帧后消费）
  4. 使用的 `alloc_and_register` 方法已存在于 AsyncRt.rs:133-138，此前从未被调用
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug H5：pending_completions 恢复路径丢弃 child_signal

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:932`
- **问题**：当子帧先于父帧 insert 回 HashMap 完成时，完成信息存入 `pending_completions`（Subgraph.rs:305-308），三元组 `(call_node, return_value, child_signal)` 被保存。但 process_frame 消费 pending completion 时，`child_signal` 被 `let _ = child_signal;` 显式丢弃
- **对比**：正常路径 `complete_and_wake_caller`（Subgraph.rs:328-331）会传播 Break/Return 信号到调用方帧；pending_completions 路径完全跳过这一步
- **触发场景**：并发场景下，子帧完成时父帧恰好不在 HashMap 中（正在被 process_frame 执行或正在 complete_and_wake_caller 中被 remove）。子帧带有 Break/Return 信号时，信号丢失，调用方继续执行本应中断的代码路径
- **修复**：在 pending_completions 消费路径中复制 `complete_and_wake_caller` 正常路径的 Gate 信号传播逻辑：检查 `call_graph_id` 对应节点是否为 Gate，若是且 `child_signal != ControlSignal::None`，则设 `frame.control_signal = child_signal`。`call_graph_id` 已在消费路径中计算，直接复用
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

---

### P1 优先级（中危：特定场景下出错）

#### Bug M1：notify_downstream 腐蚀 PENDING_EXTERNAL 哨兵值

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:372-373`
- **问题**：`prepare_frame_nodes`（行 286）、`prepare_same_function_frame`（Frame.rs:173/178）、`start_subgraph`（Subgraph.rs:118/123）将嵌套子图节点和 EventSource 节点的 `pending_inputs` 设为 `PENDING_EXTERNAL`（= `u8::MAX` = 255），表示"永不就绪/外部源"。但 `notify_downstream` 遍历全局 downstreams 时会对这些节点执行 `255 > 0 → 254` 的递减，腐蚀哨兵值。若累计 255 次递减则归零，嵌套节点被错误推入父帧就绪队列并被父帧执行（应在子帧中执行）
- **触发场景**：任何包含嵌套子图的图——父帧的 Const 节点或计算节点向嵌套子图的入口/参数节点供值时即触发腐蚀
- **修复**：在递减前检查 `pending != PENDING_EXTERNAL`，若为哨兵则跳过递减（哨兵保持 255，不会归零，不会被错误推入就绪队列）
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M2：pending_inputs 的 u8 溢出与哨兵混淆

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:303` + `src/engine/Frame.rs:188` + `src/engine/Subgraph.rs:130` + `src/ir/Ir.rs:974` + `src/engine/mod.rs:49`
- **问题**：in-frame 输入计数被 `as u8` 截断。两类问题：
  1. **溢出回绕**：若节点有 256 个 in-frame 输入，`256u8 == 0`，节点被标记为已就绪，实际所有输入未必就绪 → 读取未初始化值
  2. **哨兵混淆**：若节点恰好有 255 个 in-frame 输入，`255u8 == PENDING_EXTERNAL`，节点被误判为"外部源/嵌套节点"，永不入就绪队列 → 节点被静默跳过，帧死锁
- **触发场景**：编译器生成的图中存在高入度节点（≥255 输入），如大型 switch/match 的汇聚节点、宽记录构造
- **修复**：将 `pending_inputs` 从 `Vec<u8>` 改为 `Vec<u16>`，`PENDING_EXTERNAL` 从 `u8::MAX`(255) 改为 `u16::MAX`(65535)：
  1. `Ir.rs:974`：`pending_inputs: Vec<u8>` → `Vec<u16>`
  2. `mod.rs:49`：`PENDING_EXTERNAL: u8 = u8::MAX` → `u16 = u16::MAX`
  3. `Schedule.rs:302`：`count() as u8` → `as u16`
  4. `Frame.rs:188`：`0u8` → `0u16`
  5. `Subgraph.rs:130`：`0u8` → `0u16`
  6. `Frame.rs:255`：`reset_node_pending` 参数 `pending: u8` → `u16`
  7. 溢出阈值从 256 提升到 65536，哨兵值从 255 提升到 65535，实际入度不可能达到此量级
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M3：reset_loop_iteration 未清除 body_frame 的 select_timers

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Frame.rs:97-101`
- **问题**：`reset_loop_iteration` 重置 body 帧时，清除了 `value_table`、`ready_queue`、`control_signal`、`pending`，但遗漏了 `select_timers`。对比 `switch_subgraph`（Subgraph.rs:29）会清除 `select_timers`，此处遗漏导致循环体内 select 语句注册的 Timer ID 跨迭代残留。当 body 帧在下一迭代被复用时，select 分支评估代码会通过 `frame.select_timers.iter().find` 找到旧 Timer ID，若旧 Timer 已 fire，`is_fired` 立即返回 true，导致 select 错误地立即选中该分支
- **触发场景**：循环体内包含 select 语句且分支有 Timer 类型事件源
- **修复**：在 body_frame 重置段添加 `body_frame.select_timers.clear();`（与 `switch_subgraph` 保持一致）
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M4：嵌套循环 body_frame_id 未清除 → 复用过时内层帧

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Frame.rs:97-129`
- **问题**：当循环体（LoopBody）内部嵌套另一个循环时，外层 body 帧同时也是内层循环的"loop frame"，其 `body_frame_id` 指向内层 body 帧。当外层循环迭代结束、`reset_loop_iteration` 重置外层 body 帧时，`body_frame_id` 未被清除。外层 body 帧在下一迭代被复用后，执行到内层循环的 Gate 节点时进入 body_frame_id 复用路径。该路径从 HashMap 中取出旧的内层 body 帧，但**只注入参数和设置 caller/state，不重置 value_table、pending_inputs、ready_queue**。内层 body 帧保留了上一外层迭代中最后一次内层迭代的计算结果和就绪状态
- **触发场景**：嵌套循环（循环体内含循环）。外层循环第二迭代及以后，内层循环使用过时的 body 帧状态执行，产生错误结果或静默跳过
- **修复**：在 body_frame 重置段添加 `body_frame.body_frame_id = None;`。清除后，外层 body 帧在下一迭代遇到内层循环 Gate 节点时，`body_frame_id` 为 None → 走 `start_subgraph` 首次创建路径，创建全新的内层 body 帧（而非复用过时帧）
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M5：reset_loop_iteration 未清除 loop_frame 的 ready_queue

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Frame.rs:131-136`
- **问题**：`reset_loop_iteration` 重置 loop_frame 时清除了 `control_signal`、`state`、`suspend_state`、`suspend_event`、`pending`，但未清除 `ready_queue`。随后函数向 `ready_queue` push 了新节点（iter_next、cond），但这些是追加到旧队列尾部。如果 loop_frame 在挂起时 `ready_queue` 非空，旧条目会残留，loop_frame 被重新处理时旧条目先于 cond/iter_next 被执行，可能引用已过时的值
- **触发场景**：loop_frame 的 ready_queue 在挂起时非空
- **修复**：在步骤 1（For 循环重置 iter_next）之前添加步骤 0：`loop_frame.ready_queue.clear();`。必须在步骤 1-3 之前执行，否则会清掉刚 push 的 cond/iter_next/gate 节点
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M6：iter_guard 超限静默返回导致活锁

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Schedule.rs:406-411` + `src/ir/Compute.rs:2621-2626`
- **问题**：当循环迭代超过 500000（异步路径）或 100000（同步路径）次时，函数直接 `return`，**不设置 `frame.state` 为 Failed，不记录任何错误**。在异步路径中，`process_frame` 取回帧后检查 `frame.state`，由于未被修改（仍是 Ready），会落入 `match state` 的 `_ =>` 分支（Schedule.rs:999-1003），将帧重新入队 → 帧被无限重新调度，每次都在 500000 次迭代后静默返回，形成活锁且永不报告错误。同步路径返回 `Value::VOID`，掩盖计算未完成
- **触发场景**：大规模循环、指数级节点重触发、或其他 bug 导致死循环
- **修复**：
  1. 异步路径（Schedule.rs）：超限时设 `frame.state = FrameState::Failed` 后 return。`process_frame` 的 Failed 分支（Schedule.rs:1023）会正确处理：有 caller 时唤醒调用方，无 caller 时返回 NULL
  2. 同步路径（Compute.rs）：超限时返回 `Value::NULL`（替代 `Value::VOID`），与顶层 Failed 返回 NULL 语义一致
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M7：同步路径空队列返回未就绪的 return_node 值

- **状态**：已修复 (2026-08-07)
- **位置**：`src/ir/Compute.rs:2636-2643`
- **问题**：当就绪队列为空且未触发 Return 控制信号时，直接从 `return_node` 取值返回。但如果 `return_node` 尚未计算（`pending_inputs > 0` 且 `ready == false`），`get_value_by_global` 会返回值表中的未初始化值（`Value::NULL`）或上一轮循环迭代的陈旧值。**静默返回错误结果而非报错**，掩盖了图中的死锁/调度错误
- **触发场景**：thunk 子图（LazyValue force）中存在调度错误、循环未重置、或节点 pending 计数错误导致死锁时
- **修复**：空队列时检查 return_node 的 `ready` 标志，未就绪则返回 `Value::NULL` 表示计算失败。使用 `wrapping_sub` 计算 return_local 避免下溢，bounds 检查防止越界
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M8：同步路径非 Call 的 pending 未被清除

- **状态**：已修复 (2026-08-07)
- **位置**：`src/ir/Compute.rs:2705-2834`
- **问题**：当 `frame.pending` 为 `Some(Pending::Await/SelectWait/ChannelNotify/Cancel)` 时，`if let Some(Pending::Call(_))` 不匹配，落入 `else` 分支。但 `else` 分支不清除 `frame.pending`（仅 Call 分支在行 2707 清除）。导致：①该 pending 永久残留；②当前节点被当作普通节点写入值表并通知下游（值通常是 `Value::VOID`）；③后续每次循环 `pending = frame.pending.clone()` 仍为 `Some(Await...)`，每个被弹出的节点都走 else 分支被错误处理，直到 `iter_guard` 超时
- **触发场景**：thunk 子图意外包含 await/channel/select 节点时
- **修复**：在 Call 分支和普通节点 else 分支之间增加 `else if pending.is_some()` 分支：清除 `frame.pending = None` 并返回 `Value::NULL`。同步路径不支持 async 相关 Pending，返回 NULL 明确表示计算失败，避免错误执行和 iter_guard 超限
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug M9：compute_closure_call 的 self_upvalue_idx 无边界检查

- **状态**：已修复 (2026-08-07)
- **位置**：`src/ir/Compute.rs:2968-2978`
- **问题**：`self_idx` 的计算假设 `self_upvalue_idx < upvalues_len`，但无断言或边界检查。如果 `self_upvalue_idx` 超出 upvalues 范围，`args[self_idx]` 会 panic（数组越界）。此外，`upvalues_start = args.len() - upvalues_len` 在 `upvalues_len > args.len()` 时会下溢（usize 下溢 panic）
- **触发场景**：递归闭包的 `self_upvalue_idx` 元数据与实际 upvalues 数量不一致时
- **修复**：在 `if self_upvalue_idx >= 0` 块内依次添加 4 个断言：① `upvalues_len <= args.len()` 防止 usize 下溢；② `self_upvalue_idx < upvalues_len` 确保 slot 落在 upvalues 区间内；③ `self_idx < args.len()` 防止最终数组越界。先将 `self_upvalue_idx` 转为 usize 局部变量再做比较，避免 i32→usize 转换前未检查范围
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过（含 closures 递归闭包用例），5/5 性能测试通过，无回归

---

### P2 优先级（低危 / 性能 / 内存泄漏）

#### Bug L1：cleanup 从未被调用 → 内存泄漏

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/AsyncRt.rs` + `src/engine/Schedule.rs`
- **问题**：`AsyncJoinRuntime::entries` 只在 `cleanup_consumed` 被调用时清理已完成且已消费的 entry；`TimerRuntime::fired_set` 只在 `cleanup()` 被调用时清空。但两者均未被调用，长时间运行的程序中这两个集合会无界增长
- **修复**：
  1. **TimerRuntime**：`is_fired` 改为 `&mut self` 消费式读取（返回 true 时移除条目）；`check_timers` 在派发所有 fired timer 事件后调用 `cleanup()` 清理残余条目（安全：`is_fired` 仅在 `start()` 同锁内调用，不会查询旧条目）
  2. **AsyncJoinRuntime**：`try_get_result` 改为 `&mut self` 消费式读取（返回 Some 时 `swap_remove` entry）；新增 `remove_entry` 方法；`on_event_arrived` 返回唤醒的 waiter 数量；完成路径中若 `woken > 0`（waiter 已被唤醒，值已通过事件注入）则调用 `remove_entry` 清理 entry；若 `woken == 0`（无 waiter）则保留 entry 供 `try_get_result` 消费式读取
- **验证**：cargo build 无警告，8/8 单元测试通过，18/18 功能测试通过，5/5 性能测试通过，无回归

#### Bug L2：check_timers 推帧后直接 park 不重新检查

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Strategy.rs:315-323`
- **问题**：`check_timers` 触发到期定时器将就绪帧推入 `local_queue`，但之后直接计算 park timeout 并 park，不重新检查队列。就绪帧滞留在队列中，直到 park timeout（默认 10ms）到期才被处理
- **修复**：在 `check_timers` 后增加队列重新检查：若 `local_queue` 或 `global_queue` 非空，恢复 active_count 并 `continue` 处理就绪帧，而非 park
- **验证**：cargo build 无警告，8/8 单元测试通过，功能测试通过，无回归

#### Bug L3：worker park 前的 lost-wakeup

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Strategy.rs:278-333`
- **问题**：步骤 4（释放 active_count 锁）和步骤 5（获取 wakeup 锁）之间存在窗口。另一 worker 可在此窗口内处理完帧后调用 `notify_all`，由于当前 worker 还未进入 `wait_for`，该通知被丢失，当前 worker 随后 park 直到 park timeout 才醒来
- **修复**：将 step 4（active_count 减量 + 全空闲退出检查）合并到 step 5 的 wakeup 锁临界区内。active_count 减量在 wakeup 锁内执行，`notify_all` 必须先获取 wakeup 锁，因此无法在减量与 `wait_for` 之间插入通知，消除 lost-wakeup 窗口
- **验证**：cargo build 无警告，8/8 单元测试通过，无回归

#### Bug L4：force_lazy_value_sync 裸指针别名 UB

- **状态**：已修复 (2026-08-07)
- **位置**：`src/ir/Compute.rs:2560-2562`
- **问题**：`parent_frame_ptr = caller_frame as *mut Frame` 后 `run_frame_sync` 内部 `&mut *ptr` / `&*ptr` 与 caller_frame 的活跃 `&mut` 借用构成别名 UB。单线程下实际不会崩溃，但违反 Rust 别名规则
- **修复**：将 `parent_frame_ptr` 设为 `null_mut()`。thunk 帧的 upvalues 已在创建时作为参数注入（行 2553-2558），thunk 子图体内所有变量引用都在自身节点范围内，不需要通过帧链穿透访问外层变量。消除裸指针完全避免别名 UB
- **验证**：cargo build 无警告，8/8 单元测试通过，strings/throw/nullable/records/adt/newtype/closures/traits 等 8 个功能测试全部通过（覆盖 `compute_reflect_format` → `force_lazy_value_sync` 路径），无回归

#### Bug L5：notify_all 惊群效应

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Strategy.rs:249-275`
- **问题**：每处理完一帧就 `notify_all` 唤醒所有 parked worker。大多数情况下只有一帧入队，被唤醒的 worker 大多偷不到工作又重新 park，在高 worker 数 + 低帧数场景下造成大量无效唤醒和上下文切换
- **修复**：将步骤 1/2/3（pop_local/try_steal/try_global）后的 `notify_all` 改为 `notify_one`。单帧入队只需唤醒一个 worker，被唤醒的 worker 处理完后若有更多工作会继续 `notify_one` 级联唤醒。退出路径保留 `notify_all`（需唤醒所有 worker 退出）
- **验证**：cargo build 无警告，8/8 单元测试通过，无回归

#### Bug L6：on_event_arrived 的 O(n²) retain

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/AsyncRt.rs:303-305`
- **问题**：`event_waiters.retain(|(_, fid)| !waiters.contains(fid))` 使用 `Vec::contains`（O(n)）嵌套在 `retain`（O(n)）中，总体 O(n²)，当 event_waiters 较大时性能下降明显
- **修复**：将 `waiters` Vec 转为 `HashSet<FrameId>` 后用于 retain 的 `contains` 查找，将 retain 从 O(n²) 降为 O(n)
- **验证**：cargo build 无警告，8/8 单元测试通过，无回归

---

### P3 优先级（维护风险 / 极端边界）

#### Bug L7：extract_child_return 注释与 same_function 帧语义不符

- **状态**：待修复
- **位置**：`src/engine/Schedule.rs:390-391`
- **问题**：注释声称"同函数分支和跨函数调用均如此"（node_offset = node_range.0），但这是**错误的**。同函数分支帧（same_function）的 `node_offset` 被设为父函数的 `node_start`（见 Frame.rs:85、146），而非分支子图自身的 `node_range.0`。代码本身使用的是 `child.node_offset`（正确值），所以**代码正确但注释具有误导性**
- **修复方向**：修正注释

#### Bug L8：LoopBody break/return 递归无深度限制

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Subgraph.rs:249-300`
- **问题**：LoopBody 帧的 break/return 会递归调用 `complete_and_wake_caller(loop_frame)`。如果 loop_frame 本身也是另一个 LoopBody 帧（嵌套循环的内层 body break），会再次进入 LoopBody 分支递归。深度嵌套循环的 break 会产生多层递归，极端嵌套下可能栈溢出
- **修复**：将 `complete_and_wake_caller` 的 LoopBody break/return 传播改为迭代式 `loop {}` 循环。break/return 路径中，loop_frame 取出后设为新的 `child_frame` 并 `continue` 循环，而非递归调用 `self.complete_and_wake_caller(*lf)`。Continue/None 路径保持原有 reset + insert 逻辑。深度嵌套循环的 break 现在以 O(1) 栈空间传播

#### Bug L9：TimerRuntime::next_id 无溢出检查

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/AsyncRt.rs` TimerRuntime::start
- **问题**：对比 `AsyncJoinRuntime::alloc_id` 有 `assert!(self.next_async_id < u32::MAX)`，但 `TimerRuntime::start` 没有溢出检查。`next_id` 是 `u32`，超过 4 亿个定时器后回绕，可能导致 TimerId 冲突
- **修复**：在 `TimerRuntime::start` 中添加 `assert!(self.next_id < u32::MAX, "TimerId overflow: too many timers")`

#### Bug L10：complete_and_wake_caller LoopBody 路径未处理 loop_frame 缺失

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/Subgraph.rs:276-299`
- **问题**：当 `loop_frame` 为 None（不在 HashMap 中）时：①`reset_loop_iteration` 不被调用 → body 帧不重置；②loop_frame 不被 re-insert 或 push → 循环终止；③body 帧仍以 `Completed` 状态、旧 caller 引用被插入 HashMap，成为孤儿帧
- **修复**：loop_frame 缺失属于不变量违反（body 帧的 caller 引用的 loop 帧必须存在于 frames HashMap）。Break/Return 路径和 Continue/None 路径均改为 `unwrap_or_else(|| panic!(...))` 显式 panic，报告不变量违反而非静默丢弃。Continue/None 路径同时简化为 `reset_loop_iteration(&mut *loop_frame, ...)` + `insert` + `push`，消除原先两段 `if let Some` 导致的 loop_frame None 时 body 帧仍被插入为孤儿的问题

#### Bug L11：pending_completions 对同一 caller 多次完成互相覆盖

- **状态**：已修复 (2026-08-07)
- **位置**：`src/engine/mod.rs:66-67`、`src/engine/Subgraph.rs:312-319`、`src/engine/Schedule.rs:941-982`
- **问题**：`pending_completions` 是 `HashMap<FrameId, (NodeId, Value, ControlSignal)>`，每个 caller_fid 只能存储一个 pending completion。如果同一 caller 有多个子帧并发完成（如 async call 后多个子帧同时完成），第二个 `insert` 会覆盖第一个，导致第一个子帧的返回值和信号丢失
- **修复**：将 `pending_completions` 值类型从 `(NodeId, Value, ControlSignal)` 改为 `Vec<(NodeId, Value, ControlSignal)>`。写入方（Subgraph.rs）改用 `entry().or_insert_with(Vec::new).push(...)` 追加。消费方（Schedule.rs）改用 `remove().unwrap_or_default()` + `if !completions.is_empty()` 批量遍历处理，逐个 `set_value` + 信号传播 + `notify_downstream`。清理方（Schedule.rs:549 `remove`）不变，移除整个 entry

#### Bug L12：同步路径 LoopBody Continue/None 不重置循环帧

- **状态**：已修复 (2026-08-07)
- **位置**：`src/ir/Compute.rs:2576-2658`（新增 `reset_loop_frame_for_next_iteration`）、`src/ir/Compute.rs:2885-2892`
- **问题**：在同步路径中，LoopBody 子帧完成（Continue/None）后仅 `notify_downstream`，**不调用 `reset_loop_iteration`**（异步路径 `complete_and_wake_caller` 会调用）。因此循环帧的 `cond_node` 不会被重置为 pending、`iter_next_node` 不会被重新入队、Gate 节点 pending 不会重置为 1。`notify_downstream` 通知的下游可能因 pending 计数错误而永不就绪 → 循环只执行一次
- **修复**：新增自由函数 `reset_loop_frame_for_next_iteration(frame, graph)`，与 `Engine::reset_loop_iteration` 对应但不处理 body_frame 复用（同步路径每次迭代新建 child_frame）。该函数：①清空 ready_queue；②For 循环重置 iter_next_node（pending=0 + 入队）；③重置 cond_node（While/Loop: pending=0 + Const 预填充 + 入队；For: pending=1）；④重置 Gate 节点（pending=1，等 cond notify）；⑤重置帧状态。LoopBody Continue/None 分支改为调用此函数替代 `notify_downstream`，使主循环重新拾取 cond 执行

---

### 修复路线图建议

| 阶段 | 范围 | Bug 编号 | 根因主题 |
|------|------|----------|----------|
| **阶段 1** | Multi 模式原子性 | H1-H4 | 事件投递与帧状态管理缺乏原子性（同一根因的 4 种表现） |
| **阶段 2** | 信号传播完整性 | H5, L11 | 并发兜底路径丢弃控制信号 |
| **阶段 3** | pending_inputs 数据完整性 | M1, M2 | 哨兵腐蚀 + u8 溢出 |
| **阶段 4** | 循环帧复用重置 | M3, M4, M5 | reset_loop_iteration 字段遗漏 |
| **阶段 5** | 静默错误防护 | M6, M7, M8, M9 | iter_guard/空队列/未清 pending/边界检查 |
| **阶段 6** | 性能与内存 | L1-L6, L8-L12 | cleanup/惊群/O(n²)/栈深度 |

### 核心结论

H1-H4 是同一根因（**Multi 模式事件投递缺乏原子性**）的 4 种表现，建议一起修复。单线程模式（`run_single`）通过天然的串行执行避免了这些竞态，但 Multi 模式的 worker 之间没有对"帧挂起 → waiter 注册 → 帧 insert 回 HashMap"这一序列提供原子性保证。

若当前主要使用单线程模式运行，H1-H4 暂不触发；M1-M5 在单线程下也可能触发（尤其含嵌套子图或循环的程序），建议优先处理。
