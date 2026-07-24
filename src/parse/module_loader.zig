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
const std_embed = @import("std_embed");
const ast_rewrite = @import("ast_rewrite.zig");

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

        // 已加载的子模块集合（避免重复加载），key 格式："pack/sub"
        var loaded_submodules = std.StringHashMap(void).init(self.allocator);
        defer loaded_submodules.deinit();

        // 源文件所在目录（带分隔符），供用户模块的文件系统查找使用
        const source_dir = std.fs.path.dirname(source_filename) orelse "";
        const source_dir_with_sep = if (source_dir.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ source_dir, std.fs.path.sep })
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(source_dir_with_sep);

        for (entry_module.declarations) |decl| {
            switch (decl) {
                .import_decl => |imp| {
                    if (imp.module_path.len == 0) continue;
                    const module_name = imp.module_path[0];
                    if (std.mem.eql(u8, module_name, "std")) {
                        try self.loadStdlibPack(
                            imp.module_path,
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
                            source_dir_with_sep,
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

    /// 加载 stdlib pack：从 @embedFile 表读取 pack.glue 与子模块，mangle 为 std.<pack>.<sub>.<fun>
    fn loadStdlibPack(
        self: *ModuleLoader,
        module_path: [][]const u8,
        extra_decls: *std.ArrayList(ast.Decl),
        loaded_submodules: *std.StringHashMap(void),
        retained_parsers: *std.ArrayList(*parser_mod.Parser),
        retained_sources: *std.ArrayList([]const u8),
        retained_tokens: *std.ArrayList([]lexer_mod.Token),
        ast_arena: std.mem.Allocator,
    ) !void {
        if (module_path.len < 2) return;
        const pack_name = module_path[1];
        // module_prefix 统一 mangling 前缀：std 分支为 "std.<pack>"
        const module_prefix = std.fmt.allocPrint(ast_arena, "std.{s}", .{pack_name}) catch return;

        // 读嵌入表中的 pack.glue
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

        // 构建 sibling_modules：同 pack 内所有子模块短名 → 完整模块路径
        var sibling_modules = std.StringHashMap([]const u8).init(self.allocator);
        defer sibling_modules.deinit();
        for (pack_module.declarations) |pack_decl| {
            switch (pack_decl) {
                .pack_decl => |pd| {
                    const mangled_mod = std.fmt.allocPrint(ast_arena, "{s}.{s}", .{ module_prefix, pd.name }) catch continue;
                    sibling_modules.put(pd.name, mangled_mod) catch continue;
                },
                else => {},
            }
        }

        // 对 pack 中每个 pub pack X，读嵌入表中的 <pack>/<X>.glue
        // 全量加载 pack 内全部子模块（子模块间存在跨模块依赖，部分加载会导致 sema 报错）
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

                    // @embedFile 返回 const 数据，dupe 一份以匹配 retained_sources 的 free 语义
                    const sub_src = try self.allocator.dupe(u8, sub_src_embed);

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
                        module_prefix,
                        sub_name,
                        sub_module,
                        &sibling_modules,
                        extra_decls,
                        ast_arena,
                    );
                },
                else => {},
            }
        }
    }

    /// 加载用户 pack：从文件系统读取 pack.glue 与子模块，mangle 为 <module>.<sub>.<fun>
    fn loadUserPack(
        self: *ModuleLoader,
        module_name: []const u8,
        source_dir_with_sep: []const u8,
        extra_decls: *std.ArrayList(ast.Decl),
        loaded_submodules: *std.StringHashMap(void),
        retained_parsers: *std.ArrayList(*parser_mod.Parser),
        retained_sources: *std.ArrayList([]const u8),
        retained_tokens: *std.ArrayList([]lexer_mod.Token),
        ast_arena: std.mem.Allocator,
    ) !void {
        // module_prefix 统一 mangling 前缀：用户分支为 "<module>"
        const module_prefix = module_name;
        const io = self.io orelse return;
        const cwd = std.Io.Dir.cwd();

        // 读取 pack.glue
        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}{s}{c}pack.glue", .{ source_dir_with_sep, module_name, std.fs.path.sep });
        defer self.allocator.free(pack_path);
        const pack_src = cwd.readFileAlloc(io, pack_path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(pack_src);

        // 解析 pack.glue
        var pack_lex = lexer_mod.Lexer.init(self.allocator, pack_src);
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
                    const mangled_mod = std.fmt.allocPrint(ast_arena, "{s}.{s}", .{ module_prefix, pd.name }) catch continue;
                    sibling_modules.put(pd.name, mangled_mod) catch continue;
                },
                else => {},
            }
        }

        // 查找并加载子模块
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
                        module_prefix,
                        sub_name,
                        sub_module,
                        &sibling_modules,
                        extra_decls,
                        ast_arena,
                    );
                },
                else => {},
            }
        }
    }

    /// 收集子模块的 pub fun/type/val 声明，做 name mangling 与跨模块调用重写，追加到 extra_decls。
    /// mangle 格式：<module_prefix>.<sub_name>.<name>
    ///   std 分支：module_prefix = "std.<pack>" → "std.<pack>.<sub>.<fun>"
    ///   user 分支：module_prefix = "<module>" → "<module>.<sub>.<fun>"
    fn collectAndMangleDecls(
        self: *ModuleLoader,
        module_prefix: []const u8,
        sub_name: []const u8,
        sub_module: ast.Module,
        sibling_modules: *std.StringHashMap([]const u8),
        extra_decls: *std.ArrayList(ast.Decl),
        ast_arena: std.mem.Allocator,
    ) !void {
        // 构建 local_renames：同模块 pub fun/val 短名 → mangled name
        var local_renames = std.StringHashMap([]const u8).init(self.allocator);
        defer local_renames.deinit();
        for (sub_module.declarations) |sd| {
            switch (sd) {
                .fun_decl => |fd| {
                    if (fd.visibility == .public) {
                        const mangled = std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ module_prefix, sub_name, fd.name }) catch continue;
                        local_renames.put(fd.name, mangled) catch continue;
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |st| {
                        switch (st.*) {
                            .val_decl => |vd| {
                                if (vd.visibility == .public) {
                                    const mangled = std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ module_prefix, sub_name, vd.name }) catch continue;
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
                        // 同步重写函数体内部对同模块函数的短名调用
                        ast_rewrite.rewriteModuleCalls(new_fd.body, &local_renames, sibling_modules, ast_arena);
                        try extra_decls.append(self.allocator, .{ .fun_decl = new_fd });
                    }
                },
                // 合并 pub type_decl：newtype/record/ADT 类型定义需要被加载，
                // 否则函数体内部的 newtype 构造器会找不到类型
                .type_decl => |td| {
                    if (td.visibility == .public) {
                        var new_td = td;
                        new_td.visibility = .private;
                        try extra_decls.append(self.allocator, .{ .type_decl = new_td });
                    }
                },
                // 合并 pub val 声明（expr_decl 包装的 val_decl）
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
                                    // 重写 value 表达式中的同模块短名调用
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
};
