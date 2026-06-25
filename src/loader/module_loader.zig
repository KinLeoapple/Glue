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

/// stdlib 目录的合成标记
const STDLIB_DIR_MARKER = "<stdlib>";

/// 模块加载器 - 管理模块加载和依赖
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,

    /// 类型推断器（负责类型检查）
    type_inferencer: type_check.TypeInferencer,

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
        _ = module_name;

        // 预加载 use 依赖
        for (module.declarations) |decl| {
            if (decl == .import_decl) {
                const ud = decl.import_decl;
                if (ud.module_path.len == 0) continue;
                if (self.loaded_modules.contains(ud.module_path[0])) continue;

                try self.loadModule(ud.module_path);
            }
        }

        // 类型检查
        self.type_inferencer.checkModule(&module);

        // Resolve (处理标识符解析)
        try resolve.resolveModule(&module, &self.interner);
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

        // TODO: 添加文件系统加载逻辑
        // 目前只支持 stdlib 模块

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
