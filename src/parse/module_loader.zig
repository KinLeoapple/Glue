//! 模块加载器。
//!
//! 负责从源文件加载 Glue 模块，解析、类型检查并运行分析 passes，
//! 同时处理模块间的依赖收集与循环依赖检测。维护源目录上下文以便
//! 解析相对导入路径，并将已加载模块与所属 arena 保留至生命周期结束。

const std = @import("std");
const ast = @import("ast");
const lexer_mod = @import("lexer");
const parser_mod = @import("parser");
const type_check = @import("sema");
const analysis_db_mod = @import("analysis_db");

/// 字符串 intern 池：模块名等重复字符串统一去重分配，由池统一释放。
const StringInterner = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// 返回与 s 内容相同的稳定切片：若池中已有则复用，否则 dupe 并登记。
    fn intern(self: *StringInterner, s: []const u8) ![]const u8 {
        if (self.map.get(s)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, s);
        try self.map.put(owned, owned);
        return owned;
    }

    fn deinit(self: *StringInterner) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.*);
        }
        self.map.deinit();
    }
};

/// 模块加载器，负责模块的解析、类型检查、依赖分析与生命周期管理。
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    type_inferencer: type_check.TypeInferencer,
    analysis_db: analysis_db_mod.AnalysisDB,
    current_source_dir: ?[]const u8,
    loading_modules: std.StringHashMap(void),
    loaded_modules: std.StringHashMap(ast.Module),
    retained_sources: std.ArrayList([]const u8),
    retained_arenas: std.ArrayList(std.heap.ArenaAllocator),
    interner: StringInterner,

    /// 初始化加载器，创建类型推导器与分析数据库。
    pub fn init(allocator: std.mem.Allocator, io: ?std.Io) ModuleLoader {
        return .{
            .allocator = allocator,
            .io = io,
            .type_inferencer = type_check.TypeInferencer.init(allocator),
            .analysis_db = analysis_db_mod.AnalysisDB.init(allocator),
            .current_source_dir = null,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(ast.Module).init(allocator),
            .retained_sources = .{ .items = &.{}, .capacity = 0 },
            .retained_arenas = .{ .items = &.{}, .capacity = 0 },
            .interner = StringInterner.init(allocator),
        };
    }

    /// 释放所有持有的源文本、arena 与分析设施。
    /// 模块名由 interner 统一管理，无需单独释放。
    pub fn deinit(self: *ModuleLoader) void {
        self.loading_modules.deinit();
        self.loaded_modules.deinit();
        for (self.retained_sources.items) |source| {
            self.allocator.free(source);
        }
        self.retained_sources.deinit(self.allocator);
        for (self.retained_arenas.items) |*arena| {
            arena.deinit();
        }
        self.retained_arenas.deinit(self.allocator);
        if (self.current_source_dir) |dir| {
            self.allocator.free(dir);
        }
        self.type_inferencer.deinit();
        self.analysis_db.deinit();
        self.interner.deinit();
    }

    /// 准备一个已解析的模块：规范化名称、切换源目录、加载依赖并运行类型检查与分析。
    pub fn prepareModule(self: *ModuleLoader, module: ast.Module) !void {
        // 优先用源路径的文件名（不含扩展名）作为模块名，否则回退到 module.name
        const module_name = blk: {
            if (module.source_path) |sp| {
                const stem = std.fs.path.stem(std.fs.path.basename(sp));
                if (stem.len > 0) {
                    break :blk try self.interner.intern(stem);
                }
            }
            break :blk module.name;
        };

        // 根据源路径切换 current_source_dir，defer 中恢复
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

        // 登记到 loading_modules 以检测循环依赖
        const owned_name = try self.interner.intern(module_name);
        try self.loading_modules.put(owned_name, {});
        defer {
            _ = self.loading_modules.fetchRemove(module_name);
        }
        try self.prepareModuleInner(module, module_name);
    }

    /// 递归加载模块的 import/pack 依赖，随后执行类型检查与融合分析 passes。
    fn prepareModuleInner(self: *ModuleLoader, module: ast.Module, module_name: []const u8) anyerror!void {
        // 先加载所有未加载的依赖模块
        for (module.declarations) |decl| {
            if (decl == .import_decl) {
                const ud = decl.import_decl;
                if (ud.module_path.len == 0) continue;
                if (self.loaded_modules.contains(ud.module_path[0])) continue;
                try self.loadModule(ud.module_path);
            }
            if (decl == .pack_decl) {
                const pd = decl.pack_decl;
                if (self.loaded_modules.contains(pd.name)) continue;
                var sub_path = [_][]const u8{pd.name};
                self.loadModule(&sub_path) catch {};
            }
        }

        // 类型检查
        self.type_inferencer.checkModule(&module);
        if (self.type_inferencer.errors.items.len > 0) {
            var has_fatal = false;
            for (self.type_inferencer.errors.items) |err| {
                if (err.kind == .signature_mismatch) {
                    std.debug.print("error:{d}:{d}: {s}\n", .{ err.line, err.column, err.message });
                    has_fatal = true;
                }
            }
            if (has_fatal) return error.TypeCheckFailed;
        }

        // 融合分析：常量传播、循环不变量、纯度、提升、死代码消除、公共子表达式
        {
            var fused = analysis_db_mod.FusedAnalysis.init(
                self.allocator,
                &self.analysis_db.const_prop,
                &self.analysis_db.loop_invariant,
                &self.analysis_db.purity,
                &self.analysis_db.hoist_table,
                &self.analysis_db.dead_code,
                &self.analysis_db.cse,
                &self.analysis_db.escape,
                &self.analysis_db.param_escape,
            );
            defer fused.deinit();
            fused.analyzeModule(&module) catch {};
        }

        // 分支可达性分析，结果合并到 analysis_db.branch_reach
        {
            var br_pass = analysis_db_mod.branch_reach.BranchReachPass.init(
                self.allocator,
                &self.analysis_db.const_prop,
            );
            defer br_pass.deinit();
            br_pass.analyzeModule(&module) catch {};
            var it = br_pass.table.entries.iterator();
            while (it.next()) |entry| {
                self.analysis_db.branch_reach.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
        _ = module_name;
    }

    /// 根据模块路径加载模块源文本并解析。
    /// 查找顺序：文件系统 flat.glue → pack.glue，找不到则返回 FileNotFound。
    fn loadModule(self: *ModuleLoader, module_path: [][]const u8) anyerror!void {
        // 文件系统查找：尝试 flat.glue 与 pack.glue 两种布局
        if (self.io) |io| {
            if (self.current_source_dir) |source_dir| {
                var file_path = std.ArrayList(u8).empty;
                defer file_path.deinit(self.allocator);
                try file_path.appendSlice(self.allocator, source_dir);
                for (module_path) |component| {
                    try file_path.append(self.allocator, std.fs.path.sep);
                    try file_path.appendSlice(self.allocator, component);
                }
                const cwd = std.Io.Dir.cwd();
                const flat_path = try std.fmt.allocPrint(self.allocator, "{s}.glue", .{file_path.items});
                defer self.allocator.free(flat_path);
                const pack_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{c}pack.glue",
                    .{ file_path.items, std.fs.path.sep },
                );
                defer self.allocator.free(pack_path);
                const flat_exists = if (cwd.access(io, flat_path, .{})) true else |_| false;
                const dir_exists = if (cwd.access(io, pack_path, .{})) true else |_| false;
                const resolved_path: ?[]const u8 = if (flat_exists)
                    flat_path
                else if (dir_exists)
                    pack_path
                else
                    null;
                if (resolved_path) |path| {
                    const source = cwd.readFileAlloc(io, path, self.allocator, .unlimited) catch {
                        return error.FileNotFound;
                    };
                    try self.retained_sources.append(self.allocator, source);
                    const full_path = try self.allocator.dupe(u8, path);
                    try self.retained_sources.append(self.allocator, full_path);
                    try self.parseAndPrepare(source, module_path[0], full_path);
                    return;
                }
            }
        }
        return error.FileNotFound;
    }

    /// 词法分析、解析模块、切换源目录、检测循环依赖，并注册到 loaded_modules。
    /// 解析器 arena 被保留以延长 AST 生命周期。
    fn parseAndPrepare(
        self: *ModuleLoader,
        source: []const u8,
        module_name: []const u8,
        source_path: []const u8,
    ) anyerror!void {
        var lex = lexer_mod.Lexer.init(self.allocator, source);
        defer lex.deinit();
        const tokens = try lex.tokenize();
        defer self.allocator.free(tokens);
        var p = parser_mod.Parser.init(self.allocator, tokens);
        var arena_retained = false;
        errdefer if (!arena_retained) p.deinit();
        var module = try p.parseModule(source_path);
        module.name = module_name;
        module.source_path = source_path;

        // 切换 current_source_dir 以便后续依赖解析
        const saved_source_dir = self.current_source_dir;
        var dir_changed = false;
        if (std.mem.lastIndexOfScalar(u8, source_path, std.fs.path.sep)) |idx| {
            self.current_source_dir = try self.allocator.dupe(u8, source_path[0..idx]);
            dir_changed = true;
        } else if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |idx| {
            self.current_source_dir = try self.allocator.dupe(u8, source_path[0..idx]);
            dir_changed = true;
        }
        defer {
            if (dir_changed) {
                if (self.current_source_dir) |dir| self.allocator.free(dir);
                self.current_source_dir = saved_source_dir;
            }
        }

        // 循环依赖检测
        if (self.loading_modules.contains(module_name)) {
            return error.CircularDependency;
        }
        const owned_name = try self.interner.intern(module_name);
        try self.loading_modules.put(owned_name, {});
        defer {
            _ = self.loading_modules.fetchRemove(module_name);
        }

        try self.prepareModuleInner(module, module_name);

        // 保留解析器 arena，使 AST 在加载器生命周期内有效
        try self.retained_arenas.append(self.allocator, p.arena);
        arena_retained = true;
        errdefer {
            _ = self.retained_arenas.pop();
            arena_retained = false;
        }

        const registered_name = try self.interner.intern(module_name);
        try self.loaded_modules.put(registered_name, module);
        // tokens 与 errors 均由 arena 管理，偷走 arena 后无需单独释放
    }

    /// 递归收集模块的所有依赖（import 与 pack），按依赖顺序追加到 out。
    /// seen 集合用于避免重复收集，确保每个模块只出现一次。
    pub fn collectDependencies(
        self: *ModuleLoader,
        module: ast.Module,
        out: *std.ArrayList(ast.Module),
        seen: *std.StringHashMap(void),
    ) !void {
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
                if (!self.loaded_modules.contains(dep_name)) {
                    try self.loadModule(ud.module_path);
                }
                const dep_module = self.loaded_modules.get(dep_name) orelse continue;
                try seen.put(try self.interner.intern(dep_name), {});
                try self.collectDependencies(dep_module, out, seen);
                try out.append(self.allocator, dep_module);
            }
            if (decl == .pack_decl) {
                const pd = decl.pack_decl;
                if (seen.contains(pd.name)) continue;
                var sub_path = [_][]const u8{pd.name};
                if (!self.loaded_modules.contains(pd.name)) {
                    self.loadModule(&sub_path) catch continue;
                }
                const sub_module = self.loaded_modules.get(pd.name) orelse continue;
                try seen.put(try self.interner.intern(pd.name), {});
                try self.collectDependencies(sub_module, out, seen);
                try out.append(self.allocator, sub_module);
            }
        }
    }

    /// 显式设置当前源目录，释放旧值。
    pub fn setSourceDir(self: *ModuleLoader, dir: []const u8) !void {
        if (self.current_source_dir) |old_dir| {
            self.allocator.free(old_dir);
        }
        self.current_source_dir = try self.allocator.dupe(u8, dir);
    }
};
