//! 模块加载器 - 负责模块的加载、解析和依赖管理
//!
//! 职责：
//! - 从文件系统或 stdlib 加载模块源码
//! - 解析源码为 AST
//! - 管理模块依赖关系（循环依赖检测、去重）
//! - 协调类型检查流程
//!
//! 不负责：
//! - 代码执行（Tree Walker 已移除）
//! - 语义分析细节（委托给 sema/）
//! - 值的运行时表示（在 runtime/）

const std = @import("std");
const ast = @import("ast");
const lexer_mod = @import("lexer");
const parser_mod = @import("parser");
const type_check = @import("sema");
const resolve = @import("resolve");
const intern_mod = @import("intern");
const stdlib = @import("stdlib");
const analysis_db_mod = @import("analysis_db");

/// stdlib 目录的合成标记
const STDLIB_DIR_MARKER = "<stdlib>";

/// 模块加载器 - 管理模块加载和依赖
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,

    /// 类型推断器（负责类型检查）
    type_inferencer: type_check.TypeInferencer,

    /// JIT 分析数据库（Phase 2+：purity/call_graph/const_prop 等）
    analysis_db: analysis_db_mod.AnalysisDB,

    /// 字符串内部化器
    interner: intern_mod.Interner,

    /// 当前源文件目录（用于解析相对路径的 use 导入）
    current_source_dir: ?[]const u8,

    /// 正在加载的模块（用于循环依赖检测）
    loading_modules: std.StringHashMap(void),

    /// 已加载的模块缓存
    loaded_modules: std.StringHashMap(ast.Module),

    /// 保留的源码（用于生命周期管理，AST 借用源字节）
    retained_sources: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: ?std.Io) ModuleLoader {
        return .{
            .allocator = allocator,
            .io = io,
            .type_inferencer = type_check.TypeInferencer.init(allocator),
            .analysis_db = analysis_db_mod.AnalysisDB.init(allocator),
            .interner = intern_mod.Interner.init(allocator),
            .current_source_dir = null,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(ast.Module).init(allocator),
            .retained_sources = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        // 清理 loading_modules 的键
        var loading_it = self.loading_modules.keyIterator();
        while (loading_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.loading_modules.deinit();

        // 清理 loaded_modules 的键
        var loaded_it = self.loaded_modules.keyIterator();
        while (loaded_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.loaded_modules.deinit();

        // 清理保留的源码
        for (self.retained_sources.items) |source| {
            self.allocator.free(source);
        }
        self.retained_sources.deinit(self.allocator);

        // 清理当前源目录
        if (self.current_source_dir) |dir| {
            self.allocator.free(dir);
        }

        // 清理类型检查器和相关组件
        self.type_inferencer.deinit();
        self.analysis_db.deinit();
        self.interner.deinit();
    }

    /// 为 VM 准备模块：加载依赖 + 解析 + 类型检查
    pub fn prepareModule(self: *ModuleLoader, module: ast.Module) !void {
        const module_name = module.name;

        // 设置当前模块的源文件目录
        const saved_source_dir = self.current_source_dir;
        if (module.source_path) |sp| {
            if (std.mem.lastIndexOfScalar(u8, sp, std.fs.path.sep)) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
            } else if (std.mem.lastIndexOfScalar(u8, sp, '/')) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
            }
        }
        defer {
            if (saved_source_dir) |dir| self.allocator.free(dir);
            self.current_source_dir = saved_source_dir;
        }

        // 标记"正在加载"（循环依赖检测）
        const owned_name = try self.allocator.dupe(u8, module_name);
        try self.loading_modules.put(owned_name, {});
        defer {
            if (self.loading_modules.fetchRemove(module_name)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        try self.prepareModuleInner(module, module_name);
    }

    /// 内部准备函数：加载依赖 + 类型检查
    fn prepareModuleInner(self: *ModuleLoader, module: ast.Module, module_name: []const u8) anyerror!void {
        // 预加载 use 依赖
        for (module.declarations) |decl| {
            if (decl == .import_decl) {
                const ud = decl.import_decl;
                if (ud.module_path.len == 0) continue;
                if (self.loaded_modules.contains(ud.module_path[0])) continue;

                try self.loadModule(ud.module_path);
            }
            // 处理 pack 声明：pub pack Memory 需要加载子模块
            if (decl == .pack_decl) {
                const pd = decl.pack_decl;
                if (self.loaded_modules.contains(pd.name)) continue;

                // 子模块路径相对于当前模块所在目录
                var sub_path = [_][]const u8{pd.name};
                self.loadModule(&sub_path) catch {
                    // 子模块加载失败不致命，继续
                };
            }
        }

        // 类型检查
        self.type_inferencer.checkModule(&module);

        // Resolve (处理标识符解析)
        try resolve.resolveModule(&module, &self.interner);

        // 融合静态分析：单次 AST 遍历同时填充 purity / const_prop / loop_invariant / hoist_table，
        // 并用基于调用图的 fixpoint 替代 purity 的多轮 AST 重递归。
        // 语义与原 4 个独立 pass 完全一致，仅合并遍历顺序（详见 fused_analysis.zig）。
        {
            var fused = analysis_db_mod.FusedAnalysis.init(
                self.allocator,
                &self.analysis_db.const_prop,
                &self.analysis_db.loop_invariant,
                &self.analysis_db.purity,
                &self.analysis_db.hoist_table,
            );
            defer fused.deinit();
            fused.analyzeModule(&module) catch {};
        }

        // 分支可达性 pass 依赖 const_prop 完成，保持独立轻量遍历（仅查 if 条件）。
        {
            var br_pass = analysis_db_mod.branch_reach.BranchReachPass.init(
                self.allocator,
                &self.analysis_db.const_prop,
            );
            defer br_pass.deinit();
            br_pass.analyzeModule(&module) catch {};

            // 合并结果到 analysis_db.branch_reach
            var it = br_pass.table.entries.iterator();
            while (it.next()) |entry| {
                self.analysis_db.branch_reach.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }

        _ = module_name;
    }

    /// 从文件或 stdlib 加载模块
    fn loadModule(self: *ModuleLoader, module_path: [][]const u8) anyerror!void {
        // 检查是否在 stdlib 中
        const in_stdlib = if (self.current_source_dir) |d|
            std.mem.eql(u8, d, STDLIB_DIR_MARKER)
        else
            false;

        // 优先从 stdlib 加载
        if (in_stdlib and module_path.len == 1) {
            if (stdlib.lookup(module_path[0])) |source| {
                const synthetic_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{c}{s}.glue",
                    .{ STDLIB_DIR_MARKER, std.fs.path.sep, module_path[0] },
                );
                try self.retained_sources.append(self.allocator, synthetic_path);
                try self.parseAndPrepare(source, module_path[0], synthetic_path);
                return;
            }
        }

        // 文件系统加载（使用 std.Io.Dir API）
        if (self.io) |io| {
            if (self.current_source_dir) |source_dir| {
                if (!std.mem.eql(u8, source_dir, STDLIB_DIR_MARKER)) {
                    // 拼接基础路径：source_dir/component1/component2/...
                    var file_path = std.ArrayList(u8).empty;
                    defer file_path.deinit(self.allocator);
                    try file_path.appendSlice(self.allocator, source_dir);
                    for (module_path) |component| {
                        try file_path.append(self.allocator, std.fs.path.sep);
                        try file_path.appendSlice(self.allocator, component);
                    }

                    const cwd = std.Io.Dir.cwd();

                    // 尝试扁平文件模块：base/path/module.glue
                    const flat_path = try std.fmt.allocPrint(self.allocator, "{s}.glue", .{file_path.items});
                    defer self.allocator.free(flat_path);

                    // 尝试目录模块：base/path/module/pack.glue
                    const pack_path = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}{c}pack.glue",
                        .{ file_path.items, std.fs.path.sep },
                    );
                    defer self.allocator.free(pack_path);

                    const flat_exists = if (cwd.access(io, flat_path, .{})) true else |_| false;
                    const dir_exists = if (cwd.access(io, pack_path, .{})) true else |_| false;

                    // 确定要加载的文件路径
                    const resolved_path: ?[]const u8 = if (flat_exists)
                        flat_path
                    else if (dir_exists)
                        pack_path
                    else
                        null;

                    if (resolved_path) |path| {
                        // 读取文件内容
                        const source = cwd.readFileAlloc(io, path, self.allocator, .unlimited) catch {
                            return error.FileNotFound;
                        };
                        try self.retained_sources.append(self.allocator, source);

                        // 保存完整路径用于子模块解析
                        const full_path = try self.allocator.dupe(u8, path);
                        try self.retained_sources.append(self.allocator, full_path);

                        // 解析并准备模块
                        try self.parseAndPrepare(source, module_path[0], full_path);
                        return;
                    }
                }
            }
        }

        // 回退到 stdlib 查找
        if (module_path.len == 1) {
            if (stdlib.lookup(module_path[0])) |source| {
                const synthetic_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{c}{s}.glue",
                    .{ STDLIB_DIR_MARKER, std.fs.path.sep, module_path[0] },
                );
                try self.retained_sources.append(self.allocator, synthetic_path);
                try self.parseAndPrepare(source, module_path[0], synthetic_path);
                return;
            }
        }

        return error.FileNotFound;
    }

    /// 解析并准备模块（解析 + 类型检查）
    fn parseAndPrepare(
        self: *ModuleLoader,
        source: []const u8,
        module_name: []const u8,
        source_path: []const u8,
    ) anyerror!void {
        // 词法分析
        var lex = lexer_mod.Lexer.init(self.allocator, source);
        defer lex.deinit();
        const tokens = try lex.tokenize();
        defer self.allocator.free(tokens);

        // 语法分析
        var p = parser_mod.Parser.init(self.allocator, tokens);
        defer p.deinit();
        var module = try p.parseModule(source_path);
        module.name = module_name;
        module.source_path = source_path;

        // 设置源目录
        const saved_source_dir = self.current_source_dir;
        if (std.mem.lastIndexOfScalar(u8, source_path, std.fs.path.sep)) |idx| {
            self.current_source_dir = try self.allocator.dupe(u8, source_path[0..idx]);
        } else if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |idx| {
            self.current_source_dir = try self.allocator.dupe(u8, source_path[0..idx]);
        }
        defer {
            if (saved_source_dir) |dir| self.allocator.free(dir);
            self.current_source_dir = saved_source_dir;
        }

        // 循环依赖检测
        if (self.loading_modules.contains(module_name)) {
            return error.CircularDependency;
        }

        // 标记正在加载
        const owned_name = try self.allocator.dupe(u8, module_name);
        try self.loading_modules.put(owned_name, {});
        defer {
            if (self.loading_modules.fetchRemove(module_name)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        // 准备模块（递归处理依赖 + 类型检查）
        try self.prepareModuleInner(module, module_name);

        // 注册到已加载模块缓存
        const registered_name = try self.allocator.dupe(u8, module_name);
        try self.loaded_modules.put(registered_name, module);
    }

    /// 收集模块的所有 use 依赖（递归，去重）
    pub fn collectDependencies(
        self: *ModuleLoader,
        module: ast.Module,
        out: *std.ArrayList(ast.Module),
        seen: *std.StringHashMap(void),
    ) !void {
        // 设置当前模块的源目录（用于解析相对的 pack 子模块）
        const saved_source_dir = self.current_source_dir;
        var dir_changed = false;
        if (module.source_path) |sp| {
            if (std.mem.lastIndexOfScalar(u8, sp, std.fs.path.sep)) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
                dir_changed = true;
            } else if (std.mem.lastIndexOfScalar(u8, sp, '/')) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
                dir_changed = true;
            }
        }
        defer {
            if (dir_changed) {
                if (self.current_source_dir) |dir| self.allocator.free(dir);
                self.current_source_dir = saved_source_dir;
            }
        }

        for (module.declarations) |decl| {
            if (decl == .import_decl) {
                const ud = decl.import_decl;
                if (ud.module_path.len == 0) continue;
                const dep_name = ud.module_path[0];
                if (seen.contains(dep_name)) continue;

                // 加载依赖模块
                try self.loadModule(ud.module_path);

                const dep_module = self.loaded_modules.get(dep_name) orelse continue;
                try seen.put(try self.allocator.dupe(u8, dep_name), {});

                // 递归收集传递依赖
                try self.collectDependencies(dep_module, out, seen);

                // 添加到输出列表
                try out.append(self.allocator, dep_module);
            }
            // 处理 pack 声明：pub pack Memory 需要收集子模块
            if (decl == .pack_decl) {
                const pd = decl.pack_decl;
                if (seen.contains(pd.name)) continue;

                // 加载子模块（current_source_dir 已设为当前模块目录）
                var sub_path = [_][]const u8{pd.name};
                self.loadModule(&sub_path) catch continue;

                const sub_module = self.loaded_modules.get(pd.name) orelse continue;
                try seen.put(try self.allocator.dupe(u8, pd.name), {});

                // 递归收集子模块的传递依赖
                try self.collectDependencies(sub_module, out, seen);

                // 添加到输出列表
                try out.append(self.allocator, sub_module);
            }
        }
    }

    /// 设置源文件目录（用于解析相对导入）
    pub fn setSourceDir(self: *ModuleLoader, dir: []const u8) !void {
        if (self.current_source_dir) |old_dir| {
            self.allocator.free(old_dir);
        }
        self.current_source_dir = try self.allocator.dupe(u8, dir);
    }
};
