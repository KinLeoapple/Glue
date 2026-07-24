# main.zig 重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 1207 行的 `src/main.zig` 拆分到 `src/cli/` 子系统，统一模块加载到 `ModuleLoader`，消除包级可变状态与运行模式重复代码。

**Architecture:** 沿用项目既有 `mod.zig` 子系统入口约定。AST 重写抽到 `src/parse/ast_rewrite.zig`；CLI/脚手架/管线/运行模式抽到 `src/cli/{mod,args,manifest,init,pipeline,run}.zig`；`loadImportedDeclarations` 融入 `ModuleLoader`（拆 `loadStdlibPack`/`loadUserPack`）；profile 状态收进 `CliContext` 显式传递。

**Tech Stack:** Zig（项目当前工具链），既有 build.zig 模块图。

**Spec:** [docs/superpowers/specs/2026-07-24-main-restructure-design.md](file:///f:/Projects/Zig/Glue/docs/superpowers/specs/2026-07-24-main-restructure-design.md)

---

## 验证约定

本计划是**行为保持重构**——没有新功能，因此不写新测试。每个任务的验证标准统一为：

- `zig build` 编译成功（无 error）
- `zig build test` 全部通过（既有单元测试不回归）
- 手动冒烟：在一个含 stdlib import 的测试项目上运行 `glue run`，确认输出不变

冒烟用例固定为 `tests/std_datetime`（import std.time.DateTime，覆盖 stdlib embed + mangling + 跨子模块调用重写路径）：

```bash
cd tests/std_datetime
../../zig-out/bin/glue run
cd ../..
```

记录其首轮输出作为基准，每个任务后对比。若输出变化即回退该任务。

每个任务末尾提交，commit message 前缀 `refactor:`。

---

## 文件结构

迁移完成后的目标结构：

```
src/
  parse/
    ast_rewrite.zig   — 新建：rewriteModuleCalls + rewriteStmt（纯 AST 变换）
    module_loader.zig — 改：新增 loadStdlibPack/loadUserPack/loadDecls
    ast.zig           — 不变
    lexer.zig         — 不变
    parser.zig        — 不变
  cli/
    mod.zig           — 新建：CliContext、Options、pub fn run(init)
    args.zig          — 新建：parseArgs、printUsage、printError
    manifest.zig      — 新建：Manifest、parseManifest、findProjectRoot、checkDirState、DirState、常量
    init.zig          — 新建：cmdInit
    pipeline.zig      — 新建：executeSource、ExecOutcome
    run.zig           — 新建：runProject、runSource（合并 runNormal/runDiagnostic）
  main.zig            — 改：极薄入口（setWindowsConsoleUtf8 + cli.run）
build.zig             — 改：module_loader 接 std_embed；root_module 调整 import
```

---

## Task 1: 抽出 AST 重写到 parse/ast_rewrite.zig

**Files:**
- Create: `src/parse/ast_rewrite.zig`
- Modify: `src/main.zig:289-529`（删除 rewriteModuleCalls + rewriteStmt）
- Modify: `src/main.zig:10-20`（import 区，新增 ast_rewrite 引用）

- [ ] **Step 1: 创建 ast_rewrite.zig，迁移 rewriteModuleCalls 与 rewriteStmt**

创建 `src/parse/ast_rewrite.zig`，文件头：

```zig
//! AST 模块调用重写：把同模块短名调用改写为 mangled name。
//!
//! 当子模块 pub 函数被 mangle 为 "Module.Sub.method" 后，函数体内部对同模块
//! 其他函数的短名调用需要同步重写，否则 sema 会报 undefined variable。
//! 纯 AST 变换，无副作用，可独立单测。

const std = @import("std");
const ast = @import("ast");
```

把 `src/main.zig:289-529` 的 `rewriteModuleCalls` 与 `rewriteStmt` 两个函数**原样**迁移过来（含 doc 注释）。改为 `pub` 可见性：

```zig
pub fn rewriteModuleCalls(
    expr: *ast.Expr,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void { ... }

pub fn rewriteStmt(
    stmt: *ast.Stmt,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void { ... }
```

函数体不变。

- [ ] **Step 2: main.zig 删除原函数并改用 import**

在 `src/main.zig` import 区（第 10-20 行附近）新增：

```zig
const ast_rewrite = @import("parse/ast_rewrite.zig");
```

删除 `src/main.zig:289-529`（rewriteModuleCalls + rewriteStmt 整段）。

把 `loadImportedDeclarations` 内部对 `rewriteModuleCalls` 的 4 处调用改为 `ast_rewrite.rewriteModuleCalls`（搜索 `rewriteModuleCalls(` 与 `rewriteStmt(` 在 main.zig 中的调用点，加 `ast_rewrite.` 前缀）。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 编译成功，无 error。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test`
Expected: 全部通过。

Run:
```bash
cd tests/std_datetime
../../zig-out/bin/glue run
cd ../..
```
Expected: 输出与基准一致（首次执行时记录该输出作为基准）。

- [ ] **Step 5: 提交**

```bash
git add src/parse/ast_rewrite.zig src/main.zig
git commit -m "refactor: extract AST rewrite to parse/ast_rewrite.zig"
```

---

## Task 2: 抽出 manifest 与常量到 cli/manifest.zig

**Files:**
- Create: `src/cli/manifest.zig`
- Modify: `src/main.zig:22-30, 106-175`（Manifest、常量、findProjectRoot、parseManifest、DirState、checkDirState）

- [ ] **Step 1: 创建 cli/manifest.zig**

创建 `src/cli/manifest.zig`：

```zig
//! 项目清单与项目根定位。

const std = @import("std");

/// 项目清单：名称、版本与入口文件路径
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    entry: []const u8,
};

pub const MANIFEST_NAME = "glue.toml";
pub const DEFAULT_ENTRY = "src/Main.glue";

/// 从当前目录向上逐级查找包含清单文件的目录，返回其相对前缀
pub fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 { ... }

/// 解析清单文件内容（简化的 key = value 格式），返回 Manifest
pub fn parseManifest(source: []const u8) Manifest { ... }

/// 目标目录状态：不存在、空、非空、已是项目
pub const DirState = enum { missing, empty, non_empty, is_project };

/// 检查目标目录的状态
pub fn checkDirState(io: std.Io, path: []const u8) DirState { ... }
```

把 `src/main.zig:106-175` 的 `findProjectRoot`、`parseManifest`、`DirState`、`checkDirState` 原样迁入，改为 `pub`。把第 22-30 行的 `Manifest`、`MANIFEST_NAME`、`DEFAULT_ENTRY` 也迁入。

- [ ] **Step 2: main.zig 删除原内容并 import**

删除 main.zig 中已迁移的常量与函数（第 22-30、106-175 行）。

import 区新增：

```zig
const manifest_mod = @import("cli/manifest.zig");
const Manifest = manifest_mod.Manifest;
const MANIFEST_NAME = manifest_mod.MANIFEST_NAME;
const DEFAULT_ENTRY = manifest_mod.DEFAULT_ENTRY;
```

main.zig 内对 `findProjectRoot`/`parseManifest`/`checkDirState`/`DirState` 的调用加 `manifest_mod.` 前缀。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出与基准一致。

- [ ] **Step 5: 提交**

```bash
git add src/cli/manifest.zig src/main.zig
git commit -m "refactor: extract manifest and project-root to cli/manifest.zig"
```

---

## Task 3: 抽出脚手架到 cli/init.zig

**Files:**
- Create: `src/cli/init.zig`
- Modify: `src/main.zig:177-236`（cmdInit）

- [ ] **Step 1: 创建 cli/init.zig**

创建 `src/cli/init.zig`：

```zig
//! `glue init` 子命令：在指定目录脚手架化新项目。

const std = @import("std");
const manifest_mod = @import("manifest.zig");

const MANIFEST_NAME = manifest_mod.MANIFEST_NAME;
const DEFAULT_ENTRY = manifest_mod.DEFAULT_ENTRY;

/// 打印错误信息到 stderr（与 args.zig 共用接口）
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// 执行 `glue init` 子命令
pub fn cmdInit(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !void { ... }
```

把 `src/main.zig:177-236` 的 `cmdInit` 原样迁入，改为 `pub`。

注意：`printError` 此处先在 init.zig 内复制一份（与 main.zig 现状一致）。Task 5 会统一到 args.zig。

- [ ] **Step 2: main.zig 删除 cmdInit 并 import**

删除 `src/main.zig:177-236`。

import 区新增：

```zig
const init_cmd = @import("cli/init.zig");
```

`main` 中 `cmdInit(allocator, io, name)` 调用改为 `init_cmd.cmdInit(allocator, io, name)`。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出一致。

额外验证 init 路径：
```bash
mkdir /tmp/glue-init-test
cd /tmp/glue-init-test
<repo>/zig-out/bin/glue init myapp
ls myapp
cd <repo>
```
Expected: `myapp/glue.toml` 与 `myapp/src/Main.glue` 存在。

- [ ] **Step 5: 提交**

```bash
git add src/cli/init.zig src/main.zig
git commit -m "refactor: extract cmdInit to cli/init.zig"
```

---

## Task 4: 抽出 args/printError/printUsage 到 cli/args.zig

**Files:**
- Create: `src/cli/args.zig`
- Modify: `src/main.zig:32-61`（profile 全局 var、printError、printUsage）

- [ ] **Step 1: 创建 cli/args.zig**

创建 `src/cli/args.zig`：

```zig
//! 命令行参数解析与用法说明。
//!
//! profile 选项在此解析为包级 var（过渡态），Task 9 会收进 CliContext。

const std = @import("std");
const profiling = @import("profiler");

pub var profile_enabled: bool = false;
pub var profile_json_path: ?[]const u8 = null;
pub var profile_interval_us: u64 = 0;
pub var global_prof: profiling.GlobalProfiler = undefined;

/// 向标准错误流打印格式化错误信息
pub fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// 打印命令行用法说明
pub fn printUsage(io: std.Io) void { ... }
```

把 `src/main.zig:32-35`（4 个 var）与 `:38-61`（printError、printUsage）原样迁入，改为 `pub`。

- [ ] **Step 2: main.zig 删除原内容并 import**

删除 main.zig 第 32-61 行。

import 区新增：

```zig
const args_mod = @import("cli/args.zig");
const printError = args_mod.printError;
const printUsage = args_mod.printUsage;
```

main.zig 内对 `profile_enabled`/`profile_json_path`/`profile_interval_us`/`global_prof` 的引用改为 `args_mod.profile_enabled` 等。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出一致。

- [ ] **Step 5: 提交**

```bash
git add src/cli/args.zig src/main.zig
git commit -m "refactor: extract args/usage/printError to cli/args.zig"
```

---

## Task 5: 抽出 executeSource 到 cli/pipeline.zig

**Files:**
- Create: `src/cli/pipeline.zig`
- Modify: `src/main.zig:268-1104`（ExecOutcome、executeSource）

- [ ] **Step 1: 创建 cli/pipeline.zig**

创建 `src/cli/pipeline.zig`：

```zig
//! 编译管线：词法 → 语法 → 模块加载 → sema → IR → 优化 → 引擎执行。

const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const module_loader = @import("module_loader");
const ir = @import("ir");
const engine = @import("engine");
const sema = @import("sema");
const analysis_db_mod = @import("analysis_db");
const std_embed = @import("std_embed");
const ast_rewrite = @import("../parse/ast_rewrite.zig");
const args_mod = @import("args.zig");
const manifest_mod = @import("manifest.zig");

/// 源码执行结果
pub const ExecOutcome = enum { failed, ran_main };

/// 完整执行管线
pub fn executeSource(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    io: std.Io,
    source: []const u8,
    filename: []const u8,
) ExecOutcome { ... }
```

把 `src/main.zig:268-1104` 的 `ExecOutcome` 与 `executeSource` 原样迁入，改为 `pub`。内部对 `global_prof` 的引用改为 `args_mod.global_prof`，对 `printError` 的引用改为 `args_mod.printError`。`loadImportedDeclarations` 与 `rewriteModuleCalls`/`rewriteStmt` 仍在 pipeline.zig 内（此 Task 仅移动 executeSource 本身；loadImportedDeclarations 在 Task 7 迁移）。

注意：`loadImportedDeclarations` 函数仍在 main.zig，pipeline.zig 需要调用它。把它声明为 `pub fn` 并在 pipeline.zig 通过 main.zig 引用会造成循环 import。处理方式：**本 Task 一并把 `loadImportedDeclarations` 迁入 pipeline.zig**（它是 executeSource 的私有辅助）。即把 main.zig:534-908 也迁入 pipeline.zig，改为模块内私有 `fn`。

- [ ] **Step 2: main.zig 删除 executeSource 与 loadImportedDeclarations**

删除 `src/main.zig:268-1104`（ExecOutcome + loadImportedDeclarations + executeSource）。

import 区新增：

```zig
const pipeline = @import("cli/pipeline.zig");
const ExecOutcome = pipeline.ExecOutcome;
```

main.zig 内对 `executeSource` 的调用改为 `pipeline.executeSource`。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出一致。

- [ ] **Step 5: 提交**

```bash
git add src/cli/pipeline.zig src/main.zig
git commit -m "refactor: extract executeSource and loadImportedDeclarations to cli/pipeline.zig"
```

---

## Task 6: 抽出运行模式到 cli/run.zig

**Files:**
- Create: `src/cli/run.zig`
- Modify: `src/main.zig:238-266, 1106-1196`（runProject、runNormal、runDiagnostic）

- [ ] **Step 1: 创建 cli/run.zig**

创建 `src/cli/run.zig`：

```zig
//! 项目运行入口：定位项目、解析清单、读取入口源码并分派到运行模式。

const std = @import("std");
const builtin = @import("builtin");
const module_loader = @import("module_loader");
const profiling = @import("profiler");
const debug_allocator = @import("debug_allocator");
const args_mod = @import("args.zig");
const manifest_mod = @import("manifest.zig");
const pipeline = @import("pipeline.zig");

const ExecOutcome = pipeline.ExecOutcome;
const MANIFEST_NAME = manifest_mod.MANIFEST_NAME;

/// 执行 `glue run` / `glue debug`
pub fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void { ... }

/// 普通运行模式
fn runNormal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void { ... }

/// 诊断运行模式
fn runDiagnostic(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void { ... }
```

把 `src/main.zig:238-266`（runProject）、`:1106-1145`（runNormal）、`:1147-1196`（runDiagnostic）原样迁入。`runProject` 改 `pub`，其余保持私有。内部 `global_prof` 引用改 `args_mod.global_prof`，`printError` 改 `args_mod.printError`，`findProjectRoot`/`parseManifest` 改 `manifest_mod.` 前缀，`executeSource` 改 `pipeline.executeSource`。

- [ ] **Step 2: main.zig 删除运行模式函数并 import**

删除 main.zig 第 238-266、1106-1196 行。

import 区新增：

```zig
const run_cmd = @import("cli/run.zig");
```

`main` 中 `runProject(allocator, io, ...)` 调用改为 `run_cmd.runProject(allocator, io, ...)`。

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出一致。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue debug && cd ../..` → 输出一致，且末尾 `[GLUE_GPA] clean` 出现。

- [ ] **Step 5: 提交**

```bash
git add src/cli/run.zig src/main.zig
git commit -m "refactor: extract runProject/runNormal/runDiagnostic to cli/run.zig"
```

---

## Task 7: 创建 cli/mod.zig 入口，main.zig 收薄

**Files:**
- Create: `src/cli/mod.zig`
- Modify: `src/main.zig`（仅留 setWindowsConsoleUtf8 + 调用 cli.run）

- [ ] **Step 1: 创建 cli/mod.zig**

创建 `src/cli/mod.zig`：

```zig
//! CLI 子系统入口：命令分派。

const std = @import("std");
const builtin = @import("builtin");
const args_mod = @import("args.zig");
const init_cmd = @import("init.zig");
const run_cmd = @import("run.zig");

/// 程序入口：解析命令行参数并分派到对应子命令
pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        setWindowsConsoleUtf8();
    }
    const allocator = std.heap.c_allocator;
    const io = init.io;
    const args_slice = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    if (args_slice.len < 2) {
        args_mod.printUsage(io);
        std.process.exit(1);
    }
    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "init")) {
        const name: ?[]const u8 = if (args_slice.len >= 3) args_slice[2] else null;
        try init_cmd.cmdInit(allocator, io, name);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "debug")) {
        for (args_slice[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--profile")) {
                args_mod.profile_enabled = true;
            } else if (std.mem.startsWith(u8, arg, "--profile-json=")) {
                args_mod.profile_enabled = true;
                args_mod.profile_json_path = arg["--profile-json=".len..];
            } else if (std.mem.startsWith(u8, arg, "--profile-interval=")) {
                args_mod.profile_interval_us = std.fmt.parseInt(u64, arg["--profile-interval=".len..], 10) catch {
                    args_mod.printError(io, "error: invalid --profile-interval value\n\n", .{});
                    args_mod.printUsage(io);
                    std.process.exit(1);
                };
            } else {
                args_mod.printError(io, "error: unknown option '{s}'\n\n", .{arg});
                args_mod.printUsage(io);
                std.process.exit(1);
            }
        }
        try run_cmd.runProject(allocator, io, std.mem.eql(u8, cmd, "debug"));
    } else {
        args_mod.printError(io, "error: unknown command '{s}'\n\n", .{cmd});
        args_mod.printUsage(io);
        std.process.exit(1);
    }
}

/// 在 Windows 上将控制台输出代码页设置为 UTF-8
fn setWindowsConsoleUtf8() void {
    const windows = std.os.windows;
    const CP_UTF8: windows.UINT = 65001;
    _ = SetConsoleOutputCP(CP_UTF8);
}

const SetConsoleOutputCP = @extern(
    *const fn (std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL,
    .{ .name = "SetConsoleOutputCP" },
);
```

内容来自原 main.zig 的 `main` 函数（第 63-104 行）与 `setWindowsConsoleUtf8`/`SetConsoleOutputCP`（第 1197-1207 行）。

- [ ] **Step 2: main.zig 收薄为极薄入口**

把 `src/main.zig` 全文替换为：

```zig
//! Glue 语言运行时入口
//!
//! 提供命令行工具，支持项目脚手架初始化（`glue init`）、
//! 构建并运行项目（`glue run`）、以及带内存检测与运行时追踪的诊断模式（`glue debug`）。

const cli = @import("cli/mod.zig");

pub fn main(init: std.process.Init) !void {
    try cli.main(init);
}
```

- [ ] **Step 3: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: 测试 + 冒烟验证**

Run: `zig build test` → 全部通过。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..` → 输出一致。
Run: `cd tests/std_datetime && ../../zig-out/bin/glue debug && cd ../..` → 输出一致，`[GLUE_GPA] clean` 出现。

- [ ] **Step 5: 提交**

```bash
git add src/cli/mod.zig src/main.zig
git commit -m "refactor: create cli/mod.zig entry, slim down main.zig"
```

---

## Task 8: 融入 ModuleLoader —— loadStdlibPack + loadUserPack

**Files:**
- Modify: `src/parse/module_loader.zig`（新增 loadStdlibPack、loadUserPack、loadDecls）
- Modify: `src/cli/pipeline.zig`（executeSource 改用 loader，删除 loadImportedDeclarations）
- Modify: `build.zig:126-135`（module_loader_module 接 std_embed）

这是最高风险任务：`executeSource` 从自带 `loadImportedDeclarations` 切换到调用 `ModuleLoader`。行为必须保持一致。

- [ ] **Step 1: build.zig 给 module_loader_module 接 std_embed**

在 `build.zig` 第 126-135 行的 module_loader_module 配置块末尾新增：

```zig
    module_loader_module.addImport("std_embed", std_embed_module);
```

注意：`std_embed_module` 在 build.zig 第 173-177 行定义，在 module_loader_module 配置之后。Zig build 允许前向引用（build 函数内 addImport 可在 createModule 之后调用）。确认 `std_embed_module` 的 `const` 声明在 `addImport` 调用之前——若顺序问题导致编译错误，把 `std_embed_module` 的 createModule 移到 module_loader_module 之前。

- [ ] **Step 2: module_loader.zig 顶部加 import**

`src/parse/module_loader.zig` import 区新增：

```zig
const std_embed = @import("std_embed");
const ast_rewrite = @import("ast_rewrite.zig");
```

- [ ] **Step 3: module_loader.zig 新增 loadDecls 公开方法**

在 `ModuleLoader` struct 内（`collectDependencies` 方法之后）新增：

```zig
    /// 加载 entry_module 中所有 import_decl 引入的子模块声明，做 name mangling
    /// 与跨子模块调用重写，合并到 entry_module.declarations。
    /// 保留 parser/source/tokens 直到 IR 构建完成（由调用方通过 retained_* 字段管理）。
    pub fn loadDecls(
        self: *ModuleLoader,
        entry_module: *ast.Module,
        source_filename: []const u8,
        retained_parsers: *std.ArrayList(*parser_mod.Parser),
        retained_sources: *std.ArrayList([]const u8),
        retained_tokens: *std.ArrayList([]lexer_mod.Token),
        ast_arena: std.mem.Allocator,
    ) !void {
        var extra_decls = std.ArrayList(ast.Decl).empty;
        defer extra_decls.deinit(self.allocator);

        var loaded_submodules = std.StringHashMap(void).init(self.allocator);
        defer loaded_submodules.deinit();

        for (entry_module.declarations) |decl| {
            switch (decl) {
                .import_decl => |imp| {
                    if (imp.module_path.len == 0) continue;
                    const module_name = imp.module_path[0];
                    if (std.mem.eql(u8, module_name, "std")) {
                        try self.loadStdlibPack(
                            imp,
                            &extra_decls,
                            &loaded_submodules,
                            retained_parsers,
                            retained_sources,
                            retained_tokens,
                            ast_arena,
                        );
                    } else {
                        try self.loadUserPack(
                            module_name,
                            source_filename,
                            &extra_decls,
                            &loaded_submodules,
                            retained_parsers,
                            retained_sources,
                            retained_tokens,
                            ast_arena,
                        );
                    }
                },
                else => {},
            }
        }

        // 合并声明到主模块
        if (extra_decls.items.len > 0) {
            const combined = try ast_arena.alloc(ast.Decl, entry_module.declarations.len + extra_decls.items.len);
            @memcpy(combined[0..entry_module.declarations.len], entry_module.declarations);
            @memcpy(combined[entry_module.declarations.len..], extra_decls.items);
            entry_module.declarations = combined;
        }
    }
```

- [ ] **Step 4: module_loader.zig 新增 loadStdlibPack 私有方法**

在 `loadDecls` 之后新增。逻辑取自原 main.zig:570-741（std 分支），关键改动：用 `self.allocator` 替代 `allocator`，用 `std_embed.find` 替代直接调用，mangling 前缀 `std.<pack>.<sub>`，调用 `ast_rewrite.rewriteModuleCalls`。

```zig
    /// 加载 stdlib pack：从 @embedFile 表读取 pack.glue 与子模块，mangle 为 std.<pack>.<sub>.<fun>
    fn loadStdlibPack(
        self: *ModuleLoader,
        imp: ast.ImportDecl,
        extra_decls: *std.ArrayList(ast.Decl),
        loaded_submodules: *std.StringHashMap(void),
        retained_parsers: *std.ArrayList(*parser_mod.Parser),
        retained_sources: *std.ArrayList([]const u8),
        retained_tokens: *std.ArrayList([]lexer_mod.Token),
        ast_arena: std.mem.Allocator,
    ) !void {
        if (imp.module_path.len < 2) return;
        const pack_name = imp.module_path[1];

        var path_buf: [256]u8 = undefined;
        const pack_path = std.fmt.bufPrint(&path_buf, "{s}/pack.glue", .{pack_name}) catch return;
        const pack_src_embed = std_embed.find(pack_path) orelse return;

        // 解析 pack.glue
        var pack_lex = lexer_mod.Lexer.init(self.allocator, pack_src_embed);
        defer pack_lex.deinit();
        const pack_tokens = pack_lex.tokenize() catch return;
        defer self.allocator.free(pack_tokens);
        var pack_parser = parser_mod.Parser.init(self.allocator, pack_tokens);
        defer pack_parser.deinit();
        const pack_module = pack_parser.parseModule("pack") catch return;

        // 构建 sibling_modules
        var sibling_modules = std.StringHashMap([]const u8).init(self.allocator);
        defer sibling_modules.deinit();
        for (pack_module.declarations) |pack_decl| {
            switch (pack_decl) {
                .pack_decl => |pd| {
                    const mangled_mod = std.fmt.allocPrint(ast_arena, "std.{s}.{s}", .{ pack_name, pd.name }) catch continue;
                    sibling_modules.put(pd.name, mangled_mod) catch continue;
                },
                else => {},
            }
        }

        // 遍历 pack 中每个 pub pack X，读 <pack>/<X>.glue
        for (pack_module.declarations) |pack_decl| {
            switch (pack_decl) {
                .pack_decl => |pd| {
                    const sub_name = pd.name;
                    const sub_key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pack_name, sub_name }) catch continue;
                    defer self.allocator.free(sub_key);
                    if (loaded_submodules.contains(sub_key)) continue;
                    loaded_submodules.put(try ast_arena.dupe(u8, sub_key), {}) catch continue;

                    const sub_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.glue", .{ pack_name, sub_name }) catch continue;
                    const sub_src_embed = std_embed.find(sub_path) orelse continue;
                    const sub_src = try self.allocator.dupe(u8, sub_src_embed);

                    // 词法 + 语法
                    var sub_lex = lexer_mod.Lexer.init(self.allocator, sub_src);
                    const sub_tokens = sub_lex.tokenize() catch {
                        self.allocator.free(sub_src);
                        continue;
                    };
                    const sub_parser_ptr = try self.allocator.create(parser_mod.Parser);
                    sub_parser_ptr.* = parser_mod.Parser.init(self.allocator, sub_tokens);
                    const sub_module = sub_parser_ptr.parseModule(sub_name) catch {
                        sub_parser_ptr.deinit();
                        self.allocator.destroy(sub_parser_ptr);
                        self.allocator.free(sub_tokens);
                        self.allocator.free(sub_src);
                        continue;
                    };

                    try retained_parsers.append(self.allocator, sub_parser_ptr);
                    try retained_sources.append(self.allocator, sub_src);
                    try retained_tokens.append(self.allocator, sub_tokens);

                    // 收集 pub 声明并 mangle
                    try self.collectAndMangleDecls(
                        sub_module,
                        pack_name,
                        sub_name,
                        "std",
                        &sibling_modules,
                        extra_decls,
                        ast_arena,
                    );
                },
                else => {},
            }
        }
    }
```

- [ ] **Step 5: module_loader.zig 新增 loadUserPack 私有方法**

在 `loadStdlibPack` 之后新增。逻辑取自原 main.zig:742-896（用户模块分支），关键改动：用 `self.allocator`、`self.io`，走文件系统，mangling 前缀 `<module>.<sub>`。

```zig
    /// 加载用户 pack：从文件系统读取 pack.glue 与子模块，mangle 为 <module>.<sub>.<fun>
    fn loadUserPack(
        self: *ModuleLoader,
        module_name: []const u8,
        source_filename: []const u8,
        extra_decls: *std.ArrayList(ast.Decl),
        loaded_submodules: *std.StringHashMap(void),
        retained_parsers: *std.ArrayList(*parser_mod.Parser),
        retained_sources: *std.ArrayList([]const u8),
        retained_tokens: *std.ArrayList([]lexer_mod.Token),
        ast_arena: std.mem.Allocator,
    ) !void {
        const io = self.io orelse return;
        const source_dir = std.fs.path.dirname(source_filename) orelse "";
        const source_dir_with_sep = if (source_dir.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ source_dir, std.fs.path.sep })
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(source_dir_with_sep);

        const cwd = std.Io.Dir.cwd();
        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}{s}{c}pack.glue", .{ source_dir_with_sep, module_name, std.fs.path.sep });
        defer self.allocator.free(pack_path);
        const pack_src = cwd.readFileAlloc(io, pack_path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(pack_src);

        var pack_lex = lexer_mod.Lexer.init(self.allocator, pack_src);
        defer pack_lex.deinit();
        const pack_tokens = pack_lex.tokenize() catch return;
        defer self.allocator.free(pack_tokens);
        var pack_parser = parser_mod.Parser.init(self.allocator, pack_tokens);
        defer pack_parser.deinit();
        const pack_module = pack_parser.parseModule("pack") catch return;

        // sibling_modules
        var sibling_modules = std.StringHashMap([]const u8).init(self.allocator);
        defer sibling_modules.deinit();
        for (pack_module.declarations) |pack_decl| {
            switch (pack_decl) {
                .pack_decl => |pd| {
                    const mangled_mod = std.fmt.allocPrint(ast_arena, "{s}.{s}", .{ module_name, pd.name }) catch continue;
                    sibling_modules.put(pd.name, mangled_mod) catch continue;
                },
                else => {},
            }
        }

        for (pack_module.declarations) |pack_decl| {
            switch (pack_decl) {
                .pack_decl => |pd| {
                    const sub_name = pd.name;
                    const sub_key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ module_name, sub_name }) catch continue;
                    defer self.allocator.free(sub_key);
                    if (loaded_submodules.contains(sub_key)) continue;
                    loaded_submodules.put(try ast_arena.dupe(u8, sub_key), {}) catch continue;

                    const sub_path = try std.fmt.allocPrint(self.allocator, "{s}{s}{c}{s}.glue", .{ source_dir_with_sep, module_name, std.fs.path.sep, sub_name });
                    defer self.allocator.free(sub_path);
                    const sub_src = cwd.readFileAlloc(io, sub_path, self.allocator, .unlimited) catch continue;

                    var sub_lex = lexer_mod.Lexer.init(self.allocator, sub_src);
                    const sub_tokens = sub_lex.tokenize() catch {
                        self.allocator.free(sub_src);
                        continue;
                    };
                    const sub_parser_ptr = try self.allocator.create(parser_mod.Parser);
                    sub_parser_ptr.* = parser_mod.Parser.init(self.allocator, sub_tokens);
                    const sub_module = sub_parser_ptr.parseModule(sub_name) catch {
                        sub_parser_ptr.deinit();
                        self.allocator.destroy(sub_parser_ptr);
                        self.allocator.free(sub_tokens);
                        self.allocator.free(sub_src);
                        continue;
                    };

                    try retained_parsers.append(self.allocator, sub_parser_ptr);
                    try retained_sources.append(self.allocator, sub_src);
                    try retained_tokens.append(self.allocator, sub_tokens);

                    try self.collectAndMangleDecls(
                        sub_module,
                        module_name,
                        sub_name,
                        "",
                        &sibling_modules,
                        extra_decls,
                        ast_arena,
                    );
                },
                else => {},
            }
        }
    }
```

- [ ] **Step 6: module_loader.zig 新增 collectAndMangleDecls 共享辅助方法**

抽取 std/user 两个分支共享的"收集 pub 声明 + mangle + 重写"逻辑。`mangle_prefix` 为 "std" 时生成 `std.<pack>.<sub>.<fun>`，为 "" 时生成 `<module>.<sub>.<fun>`。

```zig
    /// 收集子模块的 pub fun/type/val 声明，做 name mangling 与跨模块调用重写，追加到 extra_decls。
    /// mangle_prefix 为 "std" → "std.<pack>.<sub>.<fun>"；为 "" → "<pack>.<sub>.<fun>"
    fn collectAndMangleDecls(
        self: *ModuleLoader,
        sub_module: ast.Module,
        pack_name: []const u8,
        sub_name: []const u8,
        mangle_prefix: []const u8,
        sibling_modules: *std.StringHashMap([]const u8),
        extra_decls: *std.ArrayList(ast.Decl),
        ast_arena: std.mem.Allocator,
    ) !void {
        // 构建 local_renames
        var local_renames = std.StringHashMap([]const u8).init(self.allocator);
        defer local_renames.deinit();
        for (sub_module.declarations) |sd| {
            switch (sd) {
                .fun_decl => |fd| {
                    if (fd.visibility == .public) {
                        const mangled = if (mangle_prefix.len > 0)
                            std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}.{s}", .{ mangle_prefix, pack_name, sub_name, fd.name }) catch continue
                        else
                            std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ pack_name, sub_name, fd.name }) catch continue;
                        local_renames.put(fd.name, mangled) catch continue;
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |st| {
                        switch (st.*) {
                            .val_decl => |vd| {
                                if (vd.visibility == .public) {
                                    const mangled = if (mangle_prefix.len > 0)
                                        std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}.{s}", .{ mangle_prefix, pack_name, sub_name, vd.name }) catch continue
                                    else
                                        std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ pack_name, sub_name, vd.name }) catch continue;
                                    local_renames.put(vd.name, mangled) catch continue;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        for (sub_module.declarations) |sub_decl| {
            switch (sub_decl) {
                .fun_decl => |fd| {
                    if (fd.visibility == .public) {
                        const mangled_name = local_renames.get(fd.name) orelse continue;
                        var new_fd = fd;
                        new_fd.name = mangled_name;
                        new_fd.visibility = .private;
                        ast_rewrite.rewriteModuleCalls(new_fd.body, &local_renames, sibling_modules, ast_arena);
                        try extra_decls.append(self.allocator, .{ .fun_decl = new_fd });
                    }
                },
                .type_decl => |td| {
                    if (td.visibility == .public) {
                        var new_td = td;
                        new_td.visibility = .private;
                        try extra_decls.append(self.allocator, .{ .type_decl = new_td });
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |st| {
                        switch (st.*) {
                            .val_decl => |vd| {
                                if (vd.visibility == .public) {
                                    const mangled_name = local_renames.get(vd.name) orelse continue;
                                    const new_stmt = ast_arena.create(ast.Stmt) catch continue;
                                    new_stmt.* = .{ .val_decl = .{
                                        .name = mangled_name,
                                        .type_annotation = vd.type_annotation,
                                        .value = vd.value,
                                        .visibility = .private,
                                    } };
                                    ast_rewrite.rewriteModuleCalls(vd.value, &local_renames, sibling_modules, ast_arena);
                                    const new_expr = ast_arena.create(ast.Expr) catch continue;
                                    new_expr.* = .{ .unit_literal = {} };
                                    try extra_decls.append(self.allocator, .{ .expr_decl = .{
                                        .location = ed.location,
                                        .expr = new_expr,
                                        .stmt = new_stmt,
                                    } });
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }
```

- [ ] **Step 7: pipeline.zig 的 executeSource 改用 loader，删除 loadImportedDeclarations**

`src/cli/pipeline.zig` 中：
- 删除 `loadImportedDeclarations` 函数整段
- 删除 `ast_rewrite`、`std_embed`、`manifest_mod` 等仅 loadImportedDeclarations 使用的 import（若 executeSource 不再直接用）
- `executeSource` 内 `loadImportedDeclarations(...)` 调用替换为：

```zig
    loader.loadDecls(&entry_module, filename, &retained_parsers, &retained_sources, &retained_tokens, ast_arena) catch {};
```

- `executeSource` 签名不变（仍接收 `loader: *module_loader.ModuleLoader`），删除函数体内的 `_ = loader;`。

- [ ] **Step 8: 编译验证**

Run: `zig build`
Expected: 成功。若报 module_loader 找不到 ast_rewrite，确认 ast_rewrite.zig 与 module_loader.zig 同在 src/parse/ 目录，`@import("ast_rewrite.zig")` 路径正确。

- [ ] **Step 9: 测试 + 冒烟验证（重点）**

Run: `zig build test` → 全部通过。

Run:
```bash
cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..
cd tests/std_calendar && ../../zig-out/bin/glue run && cd ../..
cd tests/std_instant && ../../zig-out/bin/glue run && cd ../..
cd tests/std_duration && ../../zig-out/bin/glue run && cd ../..
cd tests/std_systemtime && ../../zig-out/bin/glue run && cd ../..
```
Expected: 全部输出与基准一致（stdlib 路径全面覆盖）。

Run: `cd tests/edge_import_non_std && ../../zig-out/bin/glue run && cd ../..`
Expected: 输出与基准一致（用户模块 import 路径覆盖）。

若任一不一致，对比 main.zig 旧版 loadImportedDeclarations 与新 loadStdlibPack/loadUserPack 的逻辑差异，重点查 mangling 前缀与 sibling_modules 构建。

- [ ] **Step 10: 提交**

```bash
git add src/parse/module_loader.zig src/cli/pipeline.zig build.zig
git commit -m "refactor: unify module loading into ModuleLoader (loadStdlibPack/loadUserPack)"
```

---

## Task 9: 引入 CliContext，合并运行模式，删除包级 var

**Files:**
- Modify: `src/cli/mod.zig`（新增 Options、CliContext；main 改用 Options）
- Modify: `src/cli/args.zig`（删除 profile var，仅留 printError/printUsage）
- Modify: `src/cli/pipeline.zig`（executeSource 接收 *CliContext）
- Modify: `src/cli/run.zig`（合并 runNormal/runDiagnostic 为 runSource）

- [ ] **Step 1: cli/mod.zig 新增 Options 与 CliContext，改 main 解析 Options**

`src/cli/mod.zig` 顶部新增类型定义：

```zig
const profiling = @import("profiler");

pub const Options = struct {
    profile_enabled: bool = false,
    profile_json_path: ?[]const u8 = null,
    profile_interval_us: u64 = 0,
};

pub const CliContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    prof: *profiling.GlobalProfiler,
};
```

把 `main` 函数中 profile 参数解析改为写入局部 `var options = Options{};`，然后调用 `run_cmd.runProject(allocator, io, options, diagnostic)`：

```zig
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "debug")) {
        var options = Options{};
        for (args_slice[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--profile")) {
                options.profile_enabled = true;
            } else if (std.mem.startsWith(u8, arg, "--profile-json=")) {
                options.profile_enabled = true;
                options.profile_json_path = arg["--profile-json=".len..];
            } else if (std.mem.startsWith(u8, arg, "--profile-interval=")) {
                options.profile_interval_us = std.fmt.parseInt(u64, arg["--profile-interval=".len..], 10) catch {
                    args_mod.printError(io, "error: invalid --profile-interval value\n\n", .{});
                    args_mod.printUsage(io);
                    std.process.exit(1);
                };
            } else {
                args_mod.printError(io, "error: unknown option '{s}'\n\n", .{arg});
                args_mod.printUsage(io);
                std.process.exit(1);
            }
        }
        try run_cmd.runProject(allocator, io, options, std.mem.eql(u8, cmd, "debug"));
    }
```

- [ ] **Step 2: args.zig 删除 profile 包级 var**

`src/cli/args.zig` 删除：

```zig
pub var profile_enabled: bool = false;
pub var profile_json_path: ?[]const u8 = null;
pub var profile_interval_us: u64 = 0;
pub var global_prof: profiling.GlobalProfiler = undefined;
```

删除 `const profiling = @import("profiler");`（不再需要）。仅保留 `printError` 与 `printUsage`。

- [ ] **Step 3: pipeline.zig 的 executeSource 改接收 *CliContext**

`src/cli/pipeline.zig` 改 `executeSource` 签名：

```zig
pub fn executeSource(
    ctx: *CliContext,
    loader: *module_loader.ModuleLoader,
    source: []const u8,
    filename: []const u8,
) ExecOutcome {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const prof = ctx.prof;
    // ... 函数体中 global_prof 替换为 prof，args_mod.global_prof 替换为 prof
    // ... engine.Engine.initOwned(&glue_ir, allocator, prof, io) 不变
}
```

需要 `const CliContext = @import("mod.zig").CliContext;`（注意避免循环 import：mod.zig import run.zig import pipeline.zig import mod.zig —— Zig 允许，因为只是类型引用）。

函数体内所有 `args_mod.global_prof` 替换为 `prof`，`args_mod.printError` 替换为 `args_mod.printError`（不变）。

- [ ] **Step 4: run.zig 合并 runNormal/runDiagnostic 为 runSource，runProject 改接 Options**

`src/cli/run.zig` 重写：

```zig
const CliContext = @import("mod.zig").CliContext;
const Options = @import("mod.zig").Options;

pub fn runProject(allocator: std.mem.Allocator, io: std.Io, options: Options, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();
    const root = (try manifest_mod.findProjectRoot(allocator, io)) orelse {
        args_mod.printError(io, "error: not a Glue project (no {s} found); run 'glue init' first\n", .{manifest_mod.MANIFEST_NAME});
        std.process.exit(1);
    };
    defer allocator.free(root);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest_mod.MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const manifest_src = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| {
        args_mod.printError(io, "error: could not read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest_src);
    const manifest = manifest_mod.parseManifest(manifest_src);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest.entry });
    defer allocator.free(entry_path);
    const source = cwd.readFileAlloc(io, entry_path, allocator, .unlimited) catch |err| {
        args_mod.printError(io, "error: could not read entry '{s}': {s}\n", .{ entry_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // 持有 GlobalProfiler 实例
    var prof = try profiling.GlobalProfiler.init(allocator, options.profile_enabled, options.profile_interval_us, options.profile_json_path);
    defer prof.deinit();
    try prof.start();

    var ctx = CliContext{
        .allocator = allocator,
        .io = io,
        .options = options,
        .prof = &prof,
    };

    try runSource(&ctx, source, entry_path, diagnostic);

    prof.dump(io);
}

fn runSource(ctx: *CliContext, source: []const u8, entry_path: []const u8, diagnostic: bool) !void {
    var outcome: ExecOutcome = .failed;
    if (diagnostic) {
        // 诊断模式：用 DebugAllocator 构造独立 context
        var dbg = debug_allocator.DebugAllocator.init();
        const dbg_alloc = dbg.allocator();
        var dbg_ctx = CliContext{
            .allocator = dbg_alloc,
            .io = ctx.io,
            .options = ctx.options,
            .prof = ctx.prof,
        };
        {
            var loader = module_loader.ModuleLoader.init(dbg_alloc, ctx.io);
            defer loader.deinit();
            outcome = runInThread(&dbg_ctx, &loader, source, entry_path);
        }
        const leaked = dbg.deinit();
        if (leaked == .leak) {
            args_mod.printError(ctx.io, "[GLUE_GPA] LEAK detected\n", .{});
        } else {
            args_mod.printError(ctx.io, "[GLUE_GPA] clean (no leak / no double-free)\n", .{});
        }
        // 诊断模式不在失败时 exit（与原 runDiagnostic 行为一致）
    } else {
        // 普通模式：用 ctx.allocator
        var loader = module_loader.ModuleLoader.init(ctx.allocator, ctx.io);
        defer loader.deinit();
        outcome = runInThread(ctx, &loader, source, entry_path);
        if (outcome == .failed) {
            loader.deinit();
            std.process.exit(1);
        }
    }
}

/// 在大栈线程中执行 executeSource；spawn 失败则当前线程执行。
fn runInThread(
    ctx: *CliContext,
    loader: *module_loader.ModuleLoader,
    source: []const u8,
    entry_path: []const u8,
) ExecOutcome {
    const Ctx = struct {
        ctx: *CliContext,
        loader: *module_loader.ModuleLoader,
        source: []const u8,
        entry_path: []const u8,
        outcome: ExecOutcome = .failed,
    };
    var c = Ctx{ .ctx = ctx, .loader = loader, .source = source, .entry_path = entry_path };
    if (std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 * 1024 }, struct {
        fn run(cc: *Ctx) void {
            cc.outcome = pipeline.executeSource(cc.ctx, cc.loader, cc.source, cc.entry_path);
        }
    }.run, .{&c})) |thread| {
        thread.join();
    } else |_| {
        c.outcome = pipeline.executeSource(ctx, loader, source, entry_path);
    }
    return c.outcome;
}
```

注意：诊断分支不在失败时 `exit`（与原 `runDiagnostic` 行为一致）；普通分支失败时显式 `loader.deinit()` 后 `exit(1)`（`std.process.exit` 不运行 defer，故需显式 deinit）。删除原 `runNormal` 与 `runDiagnostic`。

- [ ] **Step 5: pipeline.zig 删除 args_mod.global_prof 相关 import**

确认 pipeline.zig 不再引用 `args_mod.global_prof`/`args_mod.profile_enabled` 等。保留 `args_mod.printError`。

- [ ] **Step 6: 编译验证**

Run: `zig build`
Expected: 成功。若报循环 import，确认 pipeline.zig 对 mod.zig 仅取类型（`CliContext`/`Options`），Zig 允许类型层面的循环引用。

- [ ] **Step 7: 测试 + 冒烟验证（重点）**

Run: `zig build test` → 全部通过。

Run:
```bash
cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..
cd tests/std_datetime && ../../zig-out/bin/glue debug && cd ../..
cd tests/std_datetime && ../../zig-out/bin/glue run --profile && cd ../..
```
Expected: 三种模式输出与基准一致；debug 模式 `[GLUE_GPA] clean` 出现；profile 模式不报错。

- [ ] **Step 8: 提交**

```bash
git add src/cli/mod.zig src/cli/args.zig src/cli/pipeline.zig src/cli/run.zig
git commit -m "refactor: introduce CliContext, merge run modes, remove package-level vars"
```

---

## Task 10: 清理 build.zig 与无用 import

**Files:**
- Modify: `build.zig`（确认 module_loader 接 std_embed；root_module 检查）
- Modify: `src/cli/pipeline.zig`（删除不再使用的 import）
- Modify: `src/cli/run.zig`（删除不再使用的 import）

- [ ] **Step 1: 审查 pipeline.zig import**

`src/cli/pipeline.zig` 顶部 import 列表中，删除 executeSource 不再直接使用的项。迁移后 executeSource 不再用 `std_embed`、`ast_rewrite`、`manifest_mod`（这些已迁入 module_loader.zig）。保留：`std`、`lexer`、`parser`、`ast`、`module_loader`、`ir`、`engine`、`sema`、`analysis_db`、`args_mod`、`CliContext`（来自 mod.zig）。

- [ ] **Step 2: 审查 run.zig import**

确认 `builtin` 若不再使用则删除（setWindowsConsoleUtf8 已在 mod.zig）。保留：`std`、`module_loader`、`profiling`、`debug_allocator`、`args_mod`、`manifest_mod`、`pipeline`、`CliContext`/`Options`/`ExecOutcome`。

- [ ] **Step 3: 审查 build.zig root_module 依赖**

确认 `root_module` 的 import 列表（build.zig:207-218）仍包含 main.zig（经 cli/ 间接）需要的所有模块：`ast`、`lexer`、`parser`、`module_loader`、`value`、`profiler`、`sema`、`debug_allocator`、`ir`、`engine`、`analysis_db`、`std_embed`。不应删除任何一项（cli/ 子文件共享 root_module 的 import 命名空间）。

确认 `module_loader_module` 已接 `std_embed`（Task 8 Step 1）。

- [ ] **Step 4: 编译验证**

Run: `zig build`
Expected: 成功。

- [ ] **Step 5: 测试 + 全面冒烟验证**

Run: `zig build test` → 全部通过。

Run:
```bash
cd tests/std_datetime && ../../zig-out/bin/glue run && cd ../..
cd tests/std_datetime && ../../zig-out/bin/glue debug && cd ../..
cd tests/edge_import_non_std && ../../zig-out/bin/glue run && cd ../..
cd tests/phase1 && ../../zig-out/bin/glue run && cd ../..
cd bench/fib && ../../zig-out/bin/glue run && cd ../..
```
Expected: 全部输出与基准一致。

- [ ] **Step 6: 提交**

```bash
git add src/cli/pipeline.zig src/cli/run.zig build.zig
git commit -m "refactor: clean up build.zig and unused imports"
```

---

## 完成确认

全部 10 个任务完成后，确认：

- `src/main.zig` 行数从 1207 降至 ~15 行
- `src/cli/` 含 6 个文件，每个单一职责
- `src/parse/ast_rewrite.zig` 独立存在
- `src/parse/module_loader.zig` 新增 loadDecls/loadStdlibPack/loadUserPack/collectAndMangleDecls
- `main.zig` 顶部无包级 `var`
- `zig build` + `zig build test` 通过
- 所有冒烟用例输出与基准一致

最终提交一个汇总 commit（可选）：

```bash
git commit --allow-empty -m "refactor: main.zig restructure complete (10 tasks)"
```
