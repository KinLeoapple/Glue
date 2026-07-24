# main.zig 全面重构设计

- 日期：2026-07-24
- 范围：`src/main.zig`（1207 行）结构拆分 + 死代码消除 + 设计调整
- 目标：职责清晰、消除隐式耦合、与既有 `engine/` `ir/` 等子系统约定一致

## 现状问题

`src/main.zig` 混杂 6 类职责，且存在两处结构问题：

| 职责块 | 行数 | 问题 |
|---|---|---|
| CLI 参数/分派 + 全局 profile 状态 | ~75 | `global_prof` 等包级 `var`，隐式耦合 `executeSource`/`runNormal`/`runDiagnostic` |
| 项目脚手架（`findProjectRoot`/`parseManifest`/`cmdInit`） | ~130 | 配置解析与 CLI 混在一起 |
| AST 重写（`rewriteModuleCalls`/`rewriteStmt`） | ~240 | 纯 AST 变换工具，与 main 无关，无法单测 |
| 模块加载（`loadImportedDeclarations`） | ~375 | 与 `parse/module_loader.zig` 的 `ModuleLoader` 职责重叠 |
| 编译管线（`executeSource`） | ~195 | `_ = loader;` 显式忽略已存在的 `ModuleLoader` |
| 运行模式（`runNormal`/`runDiagnostic`） | ~90 | 两者几乎全重复，仅 allocator/leak 检测不同 |

`parse/module_loader.zig` 的 `ModuleLoader` 是**死代码**：`executeSource` 用 `_ = loader;` 忽略它，main.zig 自行重写了一套带 stdlib `@embedFile` 查找 + name mangling（`Module.Sub.fun`）+ 跨子模块调用重写的加载逻辑。

## 决策

通过澄清问答确定四项关键决策：

1. **范围**：全面重构（含设计调整），不仅拆分。
2. **双模块加载器**：统一到 `ModuleLoader`，让 `executeSource` 真正接入它，消除死代码。
3. **profile 状态**：收进 `Context` 结构体显式传递，删除包级 `var`。
4. **拆分粒度**：新建 `src/cli/` 子系统，与 `engine/` `ir/` 等子系统约定一致。

## 设计

### §1 模块加载统一到 ModuleLoader

把 main.zig 中的 `loadImportedDeclarations` 逻辑融入 `parse/module_loader.zig`，拆为两个方法：

- `loadStdlibPack`：处理 `import std.<pack>`，走 `@embedFile` 表（需给 `ModuleLoader` 加 `std_embed` 依赖）。读取嵌入表中的 `<pack>/pack.glue`，构建 `sibling_modules`（同 pack 内子模块短名 → 完整模块路径），遍历 pack 中每个 `pub pack X`，读取 `<pack>/<X>.glue`，词法/语法分析后收集 pub 声明，做 name mangling（`std.<pack>.<sub>.<fun>`）与跨子模块调用重写。
- `loadUserPack`：处理用户模块 `import <module>`，走文件系统。读取 `<source_dir>/<module>/pack.glue`，构建 `sibling_modules`（`<module>.<sub>`），遍历 pack 中子模块，读取 `<source_dir>/<module>/<sub>.glue`，词法/语法分析后收集 pub 声明，做 name mangling（`<module>.<sub>.<fun>`）与跨子模块调用重写。

两者共享：
- `sibling_modules` 构建逻辑
- `local_renames`（同模块 pub fun/val 短名 → mangled name）构建逻辑
- pub fun / pub type / pub val 声明收集与重命名
- 跨子模块调用重写（调用 `ast_rewrite.rewriteModuleCalls`）

`std` 分支与用户分支的差异仅在数据源（embed 表 vs 文件系统）与 mangling 前缀（`std.<pack>.<sub>` vs `<module>.<sub>`），拆分后每个方法职责单一。

**AST 重写独立成文件**：`rewriteModuleCalls` + `rewriteStmt` 迁入新建 `src/parse/ast_rewrite.zig`，作为纯 AST 变换工具，可独立单测。`ModuleLoader` 与 `main.zig` 均不再持有 AST 重写逻辑。

**接入点**：`executeSource` 删除 `_ = loader;`，改为真正调用 loader 的方法加载导入声明（如 `loader.loadDecls(&entry_module, filename)`，内部按 import 分派到 `loadStdlibPack`/`loadUserPack`）。

**build.zig 改动**：
- `module_loader_module.addImport("std_embed", std_embed_module)`
- `module_loader_module` 无需新增 ast 依赖（已有）
- `ast_rewrite` 作为 `parse` 子模块，可由 `module_loader` 直接 `@import` 同目录文件

### §2 cli/ 子系统结构

```
src/cli/
  mod.zig        — 入口：CliContext、pub fn run(init)
  args.zig       — Options 结构、parseArgs、printUsage、printError
  manifest.zig   — Manifest、parseManifest、findProjectRoot、checkDirState、DirState、MANIFEST_NAME、DEFAULT_ENTRY
  init.zig       — cmdInit 脚手架
  pipeline.zig   — executeSource 编译管线 + ExecOutcome
  run.zig        — runProject + 合并后的运行模式 runSource
src/main.zig     — 极薄入口：setWindowsConsoleUtf8 + cli.run(init)
```

每个文件单一职责，`mod.zig` 作入口，与 `engine/mod.zig`、`ir/mod.zig`、`mem/mod.zig` 等子系统约定一致。

### §3 Context / profile 状态流

删除 `main.zig` 顶部 4 个包级 `var`：

```zig
var profile_enabled: bool = false;
var profile_json_path: ?[]const u8 = null;
var profile_interval_us: u64 = 0;
var global_prof: profiling.GlobalProfiler = undefined;
```

新增（定义在 `cli/mod.zig`）：

```zig
pub const Options = struct {
    profile_enabled: bool = false,
    profile_json_path: ?[]const u8 = null,
    profile_interval_us: u64 = 0,
};

pub const CliContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    prof: *profiling.GlobalProfiler,  // 由 run 持有实例，传指针
};
```

`executeSource` 改为接收 `*CliContext`，内部用 `ctx.prof` 替代 `global_prof`。`prof` 实例由 `run.zig` 的运行模式函数持有，传指针进管线，避免深拷贝。调用链：

```
cli.run(init)
  → parseArgs → Options
  → runProject(allocator, io, options, diagnostic)
      → 持有 GlobalProfiler 实例
      → 构造 CliContext{ allocator, io, options, prof: &prof }
      → runSource(ctx, source, entry_path, diagnostic)
          → executeSource(ctx, loader, source, filename)
              → ctx.prof.phases.phaseBegin(...)
```

### §4 运行模式去重

`runNormal` + `runDiagnostic`（~90 行，几乎全重复）合并为单一 `runSource`：

```zig
fn runSource(ctx: *CliContext, source: []const u8, entry_path: []const u8, diagnostic: bool) !void
```

差异通过 `diagnostic` 分支控制：
- `diagnostic == false`：`CliContext.allocator` 直接用 `c_allocator`，`executeSource(ctx, ...)` 内部全程用 `ctx.allocator`。
- `diagnostic == true`：`runSource` 内部先构造 `DebugAllocator`，再构造一个 `CliContext`，其 `allocator` 字段填 `dbg.allocator()`（而非 `c_allocator`），`prof` 仍指向同一 `GlobalProfiler` 实例。`executeSource` 接收该 context，全程用 dbg allocator。结尾 `dbg.deinit()` 检测 leak 并打印 `[GLUE_GPA]` 报告。

共享：Ctx struct 定义、`std.Thread.spawn`（16GB 栈）、`executeSource` 调用、`ctx.prof.dump(io)`、失败时 `std.process.exit(1)`。

## 迁移顺序（增量、可回退）

每步独立编译验证，符合"迭代实现 + 回退"偏好：

1. **抽 AST 重写** → `parse/ast_rewrite.zig`，main.zig 引用，验证编译。
2. **抽 CLI/manifest/init/pipeline/run** → `cli/`，main.zig 变薄，验证编译。
3. **融入 ModuleLoader** + 接 std_embed，`executeSource` 改用 loader，验证编译 + 运行测试套件。
4. **引入 CliContext + 合并运行模式**，删除包级 `var`，验证编译 + 运行测试套件。
5. **清理 build.zig** 依赖与无用 import，验证编译 + 测试。

## 非目标

- 不修改编译管线本身的行为（lex/sema/IR/engine 各阶段逻辑不变）。
- 不修改 AST 数据结构、IR 数据结构。
- 不修改 `ModuleLoader` 既有的 `prepareModule`/`collectDependencies` 等方法签名（仅新增方法）。
- 不调整 profiling 模块内部实现。
