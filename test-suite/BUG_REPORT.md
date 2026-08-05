# Glue 引擎 Bug 修复追踪

> 本文档由 `test-suite/` 测试套件发现，记录所有引擎 bug 的修复优先级与临时绕过方案。
> 最后更新：2026-08-05（#1、#2、#3、#4、#5、#6、#7、#8、#9、#10、#11、#12、#13、#14、#15、#16、#17 已修复）

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
