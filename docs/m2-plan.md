# M2 — 复合值 / 模式匹配（字节码 VM）

承接 `docs/bytecode-vm-plan.md` §9 的 M2 里程碑。范围（原文）：
> 数组/记录/ADT/newtype 构造解构、字段/索引、match（全模式）、记录扩展。跑通 record bench。
> 交付：record bench 通过（666666666666000000）；match 相关回归全绿；--gpa record churn 干净。

## 不变量（沿用 M1）
- VM 消费 type-checked AST（生产路径）；独立单测用类型后缀锁字面量类型。
- 复用 `value.zig` 既有复合值表示（ArrayValue/RecordValue/AdtValue/NewtypeValue）+ 其
  retain/release/clone/format，**零语义漂移**（与树遍历器同一套值与格式化）。
- 每片结束门禁：`zig build test` 全绿无泄漏 + `bash run_tests.sh` 33/33 + Debug exe 重建 +
  ReleaseFast 单独跑通。改共享 Value union 后必须 `zig build`（整个 glue exe，非仅 test 模块）。
- VM 未实现的节点 → 编译器返回 `error.Unsupported`（该函数整体回退树遍历器，零长期破窗）。

## record bench 锚点（M2a 目标）
```glue
type Point = Point(x: i64, y: i64)
fun dist2(p: Point): i64 { match p { Point(x, y) => x * x + y * y } }
fun main() {
    var sum: i64 = 0; var i: i64 = 0
    while i < 1000000 {
        val p = Point(i, i + 1)
        sum = sum + dist2(p) + p.x - p.y
        i = i + 1
    }
    println(sum)   // 666666666666000000
}
```
触达特性：① `type T = Ctor(field: T, ...)` ADT 声明 → 构造器登记；② `Point(a, b)` 构造
AdtValue；③ `p.x` 字段访问（ADT 命名字段）；④ 单构造器 `match`（constructor pattern + 变量绑定）。

---

## M2a — ADT 构造 + 字段访问 + 构造器 match（record bench 子集）✅ 已完成

**目标**：跑通 record bench（666666666666000000）。最小覆盖上述 4 特性。**已达成**
（VM ~710ms vs 树遍历器 ~7350ms ≈ 10×，见 BASELINE.md）。

实现要点（与原计划一致）：
- `Program.adt_ctors` 表（chunk.zig，AdtCtorDesc 借用 AST 字符串）+ `ModuleCompiler.ctor_table`
  第一遍登记 ADT 构造器。
- opcode：OP_MAKE_ADT `<u16 ctor_idx><u8 argc>`、OP_GET_FIELD `<u16 name_const>`（命名字段）、
  OP_GET_ADT_FIELD `<u16 idx>`（位置字段，match 绑定用）、OP_TEST_CTOR `<u16 name_const>`、
  OP_MATCH_FAIL。disasm 全支持。
- emitCall 裸名命中 ctor_table → OP_MAKE_ADT（优先级在顶层函数后、native 前）。
- emitMatch（M2a 子集）：scrutinee 存隐藏 slot；逐 arm constructor/variable/wildcard 测试 + 绑定 +
  体；OP_TEST_CTOR + OP_JUMP_IF_FALSE 链；命中 OP_GET_ADT_FIELD 按位置绑字段。
- 门禁全绿：42/42 单测（+5 M2a）、回归 33/33、Debug+ReleaseFast exe、record bench 端到端。

## M2b — 数组 / 记录字面量 / 索引 ✅ 已完成

- **OP_MAKE_ARRAY `<u16 n>`**：栈顶 n 个元素 → ArrayValue（dynamic）。
- **OP_MAKE_RECORD `<u16 shape_idx>`**：栈顶 n 个值 + `program.record_shapes[shape_idx]` 的字段名
  → RecordValue（key dupe，value 接管 owned，type_name=""）。
- **OP_INDEX**：`a[i]` 弹 index + object，array 整数索引边界检查 / string codepoint 索引，retain 元素压栈。
- **OP_GET_FIELD** 复用 M2a（记录命名字段——已支持 .record 分支）。
- 实现要点：record 字面量是 **paren 语法** `(f: v, ...)`（非花括号）；Program 加 `record_shapes` 表
  （RecordShape.field_names 借用 AST）+ addRecordShape；doMakeRecord 用 getOrPut 处理重复字段名
  （释放旧值 + 复用旧 key，防泄漏）。
- 门禁全绿：48/48 单测（+6 M2b，含 1000 次数组 churn 在 std.testing.allocator 下无 leak）、回归 33/33、
  Debug+ReleaseFast exe、bench 无回归。

## M2c — 全模式 match + 记录扩展 + newtype ✅ 已完成

- **递归 emitPatternMatch(pattern, scrut_slot, fail_jumps)** 重写 match 编译，覆盖全部 pattern：
  - literal（OP_TEST_LIT，int/float 仅比值忽略 type_tag；string dupe 进常量池）
  - 大写裸名 → nullary ADT 构造器测试（Red/Green/Blue）；小写 → 变量绑定
  - constructor（OP_TEST_CTOR + 按位置 OP_GET_ADT_FIELD 解字段，**递归**子模式 → 嵌套）
  - record pattern（按字段名 OP_GET_FIELD 解构 + 递归）
  - or_pattern（emitPatternBool 短路 OR 链，仅非绑定子模式；含绑定 → Unsupported 回退）
  - guard（pattern if cond：先匹配绑定再 emitExpr 条件测试）
  - 栈纪律：每个测试不中时跳 fail（栈顶留 1 个 false bool），fail 落点统一 pop；恒匹配 arm 不产
    fail jump（跳过 pop，避免栈失衡）。
- **OP_RECORD_EXTEND `<u16 shape_idx>`**：`(...base, f: v)` 浅拷 base 字段（dupe key + retain value）
  + updates 覆盖/新增（getOrPut 释放被覆盖拷贝），建新 RecordValue。
- **newtype**：第一遍登记 newtype_table；裸名 `Handle(x)` → OP_MAKE_NEWTYPE；match `Handle(p)` →
  OP_TEST_NEWTYPE + OP_GET_NEWTYPE_INNER 递归子模式。
- 裸名 nullary 构造器作为**值**（如 `code(Green)`）：emitExpr identifier 分支 → OP_MAKE_ADT argc=0。
- **修了既存错误路径泄漏**：FnCompiler.deinit 现拥有 chunk（成功路径已置空壳；Unsupported/OOM 中途
  退出时释放半成品 chunk）——M2c literal pattern 后缀解析触发 Unsupported 才暴露此前的泄漏。
- 关键坑：pattern int/float 原始文本**含类型后缀**（"1i64"），须剥离 i/u/f 后缀 + 进制前缀 + 下划线
  再 parse（独立实现 parsePatternInt/floatBodyEnd，不复用 pattern.zig 的 page_allocator 版）。
- 门禁全绿：59/59 单测（+11 M2c：literal/or/guard/record/nested/nullary-enum/record-extend/newtype +
  1000 次 match churn 无 leak）、回归 33/33、Debug+ReleaseFast exe、bench 无回归。

**M2 三片（M2a/M2b/M2c）全部完成。**

---

## 风险（M2 特有）
- **复合值 refcount 在 VM 下漂移**：构造接管 owned、字段访问 retain、对象 release 的纪律必须严格
  （沿用 M1 栈不变式 + 每 op --gpa 单测）。record bench 百万次 churn 是天然压测。
- **match 编译错漏**：复用树遍历器同款 pattern 判定语义；每模式小程序 round-trip + disasm 黄金验证。
- **字段查找性能**：RecordValue 用 StringHashMap，ADT 用线性 fields——record bench 主要是 ADT
  位置字段，命名字段查找走线性即可（字段数小）。后续可选编译期字段 → slot 索引优化。
