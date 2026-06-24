# Tree Walker 代码清理计划

## 概述

现在 VM 是唯一的执行引擎，可以清理 Tree Walker 相关代码。但由于 VM 仍然依赖部分基础设施（类型检查、值类型、依赖收集），需要谨慎处理。

---

## 当前状态分析

### 文件概览

| 文件 | 大小 | 状态 | 说明 |
|------|------|------|------|
| `src/eval/eval.zig` | 6139 行 | 部分需要 | 包含类型检查（需要）和执行代码（不需要） |
| `src/eval/value.zig` | ~1500 行 | **必须保留** | VM 使用 Value 类型 |
| `src/eval/env.zig` | ~800 行 | **必须保留** | VM 使用 Environment |
| `src/eval/pattern.zig` | ~350 行 | 检查依赖 | 可能被类型检查使用 |
| `src/eval/throw.zig` | ~100 行 | 检查依赖 | Throw 辅助函数 |
| `src/eval/module_eval.zig` | ~100 行 | 检查依赖 | 模块求值辅助 |

### VM 使用的 Evaluator 功能

从 `src/main.zig` 分析，VM 使用：

```zig
// 1. 值分配器
ev.value_allocator = pool.allocator();
ev.global_env.value_allocator = ev.value_allocator;

// 2. 词法寻址开关
ev.use_lexical_addressing = true;

// 3. 准备模块（类型检查）
ev.prepareModuleForVm(module)

// 4. 设置源目录
ev.setSourceDirForVm(sp[0..idx])

// 5. 收集依赖
ev.collectUseDependencies(module, &deps, &seen)

// 6. VM 初始化
vm.VM.initWithIo(ev.value_allocator, io)
```

---

## 可以移除的代码

### 1. 纯 Tree Walker 执行函数（高优先级）

这些函数不再被调用，可以安全移除：

```zig
// src/eval/eval.zig

pub fn callMain() - 调用 main 入口（已被 VM 替代）
pub fn evalModule() - 执行模块（已被 VM 替代）
pub fn evalModulePrepared() - 执行已准备的模块（已被 VM 替代）
pub fn evalDecl() - 执行声明（已被 VM 替代）
pub fn evalExpr() - 执行表达式（已被 VM 替代）
pub fn evalStmt() - 执行语句（已被 VM 替代）
pub fn evalSource() - 执行源码（已被 VM 替代）

// 所有 eval* 辅助函数：
fn evalIntLiteral()
fn evalFloatLiteral()
fn evalStringInterpolation()
fn evalIdentifier()
fn evalBinary()
fn evalUnary()
fn evalCall()
fn evalMethodCall()
fn evalFieldAccess()
fn evalIf()
fn evalMatch()
fn evalLet()
fn evalBlock()
fn evalLambda()
fn evalArray()
fn evalRecord()
... 等等（约 50+ 个函数）
```

**估计行数**: ~4000 行（eval.zig 的 65%）

### 2. Tree Walker 特定的数据结构

```zig
// 调用栈追踪（只用于 Tree Walker）
call_stack: std.ArrayList(CallFrame)

// 延迟栈（只用于 Tree Walker）
// defer 栈已被 VM 自己管理
```

### 3. Tree Walker 特定的内置函数实现

```zig
// 这些内置函数只被 Tree Walker 调用
fn builtinPrintln()
fn builtinPrint()
fn builtinPanic()
fn builtinEq()
fn builtinString()
fn builtinTypeName()
... 等等（约 20+ 个函数）
```

**估计行数**: ~500 行

---

## 必须保留的代码

### 1. 类型检查和准备阶段

```zig
// src/eval/eval.zig

pub fn prepareModuleForVm() - VM 需要
fn prepareModuleInner() - 被 prepareModuleForVm 调用
fn loadModuleFromFile() - 被准备阶段调用
pub fn setSourceDirForVm() - VM 需要
pub fn collectUseDependencies() - VM 需要
fn evalSourceModule() - 被 collectUseDependencies 调用
```

**注意**: `evalSourceModule` 虽然名字叫 "eval"，但实际上只做解析和类型检查，不执行。

### 2. 类型检查器集成

```zig
// 类型检查相关字段
type_inferencer: *type_check.Inferencer
trait_resolver: *trait_resolve.TraitResolver

// 类型检查相关方法
// 都需要保留
```

### 3. 值和环境管理

```zig
// src/eval/value.zig - 完全保留
// src/eval/env.zig - 完全保留

// Evaluator 中的这些字段：
value_allocator: std.mem.Allocator
global_env: Environment
module_values: std.StringHashMap(Value)
loaded_modules: std.StringHashMap(ast.Module)
```

### 4. 垃圾回收基础设施

```zig
// GC 根追踪（VM 也使用值类型）
gc_roots: std.ArrayList(Value)

pub fn pushRoot()
pub fn popRoot()
pub fn popRoots()
fn traceValue()
fn traceEnv()
```

---

## 清理方案

### 方案 A: 激进清理（推荐）

**目标**: 移除所有 Tree Walker 执行代码，保留必要基础设施

**步骤**:

1. **阶段1**: 移除明显不用的函数
   - 移除 `callMain`, `evalModule`, `evalModulePrepared`
   - 移除所有 `eval*` 辅助函数（~50个）
   - 移除内置函数实现（~20个）
   - **估计减少**: ~4000 行

2. **阶段2**: 清理数据结构
   - 移除 `call_stack` 字段
   - 清理不再使用的 GC 相关代码
   - **估计减少**: ~200 行

3. **阶段3**: 重构必要函数
   - 将 `prepareModuleForVm` 等函数移到独立模块
   - 创建 `src/sema/module_loader.zig` 专门处理模块加载
   - **估计减少**: ~500 行（通过重构简化）

**总计减少**: ~4700 行（eval.zig 从 6139 行减少到 ~1400 行）

**风险**: 中等 - 需要仔细测试，但架构清晰

**收益**: 
- 代码更清晰
- 更容易维护
- 更快的编译时间

### 方案 B: 保守标记（备选）

**目标**: 保留所有代码，但清晰标记哪些是死代码

**步骤**:

1. 在 Tree Walker 函数前添加注释：
   ```zig
   /// DEPRECATED: Tree Walker execution (no longer used since VM-only)
   /// TODO: Remove in future cleanup
   pub fn evalExpr(...) { ... }
   ```

2. 使用条件编译标记：
   ```zig
   const ENABLE_TREE_WALKER = false;
   
   pub fn evalExpr(...) {
       if (!ENABLE_TREE_WALKER) @compileError("Tree Walker disabled");
       // ...
   }
   ```

**收益**: 
- 零风险
- 代码仍然可读（作为参考）

**缺点**:
- 代码膨胀
- 编译时间长
- 维护负担

---

## 推荐执行计划

### 立即执行（方案 A - 阶段 1）

移除明显不用的函数：

1. **创建备份分支**
   ```bash
   git checkout -b backup-tree-walker
   git checkout master
   ```

2. **移除执行函数**
   - 移除 `callMain`
   - 移除 `evalModule`, `evalModulePrepared`
   - 移除 `evalDecl`
   - 移除 `evalExpr` 和所有 `eval*` 辅助函数
   - 移除内置函数实现

3. **测试验证**
   ```bash
   zig build test
   ```

4. **提交**
   ```bash
   git commit -m "重大清理: 移除Tree Walker执行代码 (阶段1)"
   ```

### 后续执行（可选）

**阶段 2**: 清理数据结构  
**阶段 3**: 重构模块加载器

---

## 依赖分析

### VM 对 eval 模块的依赖链

```
src/main.zig
  ↓
eval.Evaluator (仅用于准备阶段)
  ↓
├─ prepareModuleForVm()
│   ↓
│   ├─ prepareModuleInner()
│   │   ↓
│   │   ├─ loadModuleFromFile()
│   │   │   ↓
│   │   │   └─ evalSourceModule() [仅解析+类型检查]
│   │   │
│   │   └─ type_check.Inferencer (类型检查)
│   │
│   └─ type_check.Inferencer
│
├─ collectUseDependencies()
│   ↓
│   └─ evalSourceModule() [仅解析+类型检查]
│
├─ setSourceDirForVm()
│
└─ value_allocator (传给 VM)

src/vm/*.zig
  ↓
value.Value (直接导入)
  ↓
├─ Value 类型定义
├─ makeArray()
├─ makeRecord()
├─ releaseVM()
└─ ... (值操作函数)
```

**关键发现**: 
- VM 不直接调用任何 `eval*` 执行函数
- VM 只使用 `prepareModuleForVm` 和依赖收集
- `value.zig` 被 VM 直接导入，独立于 Evaluator

---

## 风险评估

### 高风险

- ❌ **无** - 所有移除的代码都不再被调用

### 中风险

- ⚠️ 可能有隐藏的依赖（但测试会发现）
- ⚠️ 文档和注释可能引用旧代码（需要更新）

### 低风险

- ✅ VM 独立性强，不依赖 Tree Walker
- ✅ 有完整的测试覆盖
- ✅ 可以随时回滚到备份分支

---

## 成功标准

清理完成后：

1. ✅ **185/185 测试通过**
2. ✅ **编译时间减少** (更少代码)
3. ✅ **代码行数显著减少** (预计 -4000 行)
4. ✅ **架构更清晰** (VM-only, 无混淆)
5. ✅ **文档更新** (移除 Tree Walker 引用)

---

## 预期成果

### 代码统计（预测）

| 项目 | 当前 | 清理后 | 变化 |
|------|------|--------|------|
| src/eval/eval.zig | 6139 行 | ~1400 行 | -4739 行 (-77%) |
| 总代码行数 | ~25,000 行 | ~20,000 行 | -5000 行 (-20%) |
| 编译时间 | ~8s | ~6s | -25% |
| 二进制大小 | ~8MB | ~6MB | -25% |

### 架构简化

```
之前:
├── eval/ (Tree Walker)
│   ├── eval.zig (执行 + 类型检查)
│   ├── value.zig
│   └── env.zig
├── vm/ (VM)
└── sema/ (类型检查)

清理后:
├── sema/ (类型检查 + 模块加载)
│   ├── type_check.zig
│   ├── trait_resolve.zig
│   └── module_loader.zig (从 eval 移过来)
├── vm/ (VM - 唯一执行引擎)
└── eval/ (值类型和基础设施)
    ├── value.zig
    └── env.zig
```

---

## 下一步

### 立即行动

1. **备份当前状态**
   ```bash
   git checkout -b backup-before-tree-walker-cleanup
   git checkout master
   ```

2. **移除 Tree Walker 执行函数**（阶段 1）
   - 修改 `src/eval/eval.zig`
   - 移除所有 `eval*` 函数

3. **测试验证**
   ```bash
   zig build test --summary all
   ```

4. **提交并文档化**

### 建议时间线

- **阶段 1** (移除执行函数): 立即执行，2小时
- **阶段 2** (清理数据结构): 第二天，1小时
- **阶段 3** (重构模块加载): 未来版本，4小时

---

## 结论

Tree Walker 清理是安全且有益的：

1. ✅ **大幅减少代码** (~4000-5000 行)
2. ✅ **提高可维护性**
3. ✅ **加快编译速度**
4. ✅ **澄清架构**
5. ✅ **零功能损失** (VM 是唯一执行引擎)

**推荐**: 执行方案 A - 阶段 1（激进清理，移除执行函数）

---

**创建日期**: 2025-06-25  
**作者**: Kiro  
**状态**: 待执行
