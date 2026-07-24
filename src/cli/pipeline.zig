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

/// 源码执行结果：成功或失败
pub const ExecOutcome = enum { failed, ran_main };

/// 加载导入的子模块声明：扫描 import_decl，读取 pack.glue 和子模块 .glue 文件，
/// 将 pub fun 以 "Module.Sub.fun" 的 mangled 名合并到主模块声明列表。
/// 保留 parser/source/tokens 直到 IR 构建完成。
fn loadImportedDeclarations(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry_module: *ast.Module,
    source_filename: []const u8,
    retained_parsers: *std.ArrayList(*parser.Parser),
    retained_sources: *std.ArrayList([]const u8),
    retained_tokens: *std.ArrayList([]lexer.Token),
    ast_arena: std.mem.Allocator,
) !void {
    var extra_decls = std.ArrayList(ast.Decl).empty;
    defer extra_decls.deinit(allocator);

    // 已加载的 stdlib 子模块集合（避免重复加载）
    // key 格式："pack/sub"，如 "time/Duration"、"io/File"
    var loaded_submodules = std.StringHashMap(void).init(allocator);
    defer loaded_submodules.deinit();

    // 获取源文件所在目录
    const source_dir = std.fs.path.dirname(source_filename) orelse "";
    const source_dir_with_sep = if (source_dir.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{c}", .{ source_dir, std.fs.path.sep })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(source_dir_with_sep);

    const cwd = std.Io.Dir.cwd();

    for (entry_module.declarations) |decl| {
        switch (decl) {
            .import_decl => |imp| {
                if (imp.module_path.len == 0) continue;
                const module_name = imp.module_path[0];

                // stdlib 嵌入查找：import std.<pack>[.<sub>] → 从 @embedFile 表读取
                // 设计文档 §2.3：stdlib 通过 @embedFile 编进二进制，无需文件系统访问
                if (std.mem.eql(u8, module_name, "std")) {
                    if (imp.module_path.len < 2) continue;
                    const pack_name = imp.module_path[1];
                    // import std.<pack>.<sub>：只加载指定子模块；import std.<pack>：加载 pack 中所有子模块
                    const specific_sub: ?[]const u8 = if (imp.module_path.len >= 3) imp.module_path[2] else null;

                    // 读嵌入表中的 pack.glue（路径如 "io/pack.glue"、"time/pack.glue"）
                    var path_buf: [256]u8 = undefined;
                    const pack_path = std.fmt.bufPrint(&path_buf, "{s}/pack.glue", .{pack_name}) catch continue;
                    const pack_src_embed = std_embed.find(pack_path) orelse continue;

                    // 解析 pack.glue
                    var pack_lex = lexer.Lexer.init(allocator, pack_src_embed);
                    defer pack_lex.deinit();
                    const pack_tokens = pack_lex.tokenize() catch continue;
                    defer allocator.free(pack_tokens);
                    var pack_parser = parser.Parser.init(allocator, pack_tokens);
                    defer pack_parser.deinit();
                    const pack_module = pack_parser.parseModule("pack") catch continue;

                    // 构建 sibling_modules：同 pack 内所有子模块短名 → 完整模块路径
                    // 用于重写跨子模块调用，如 DateTime.add_days 内部 `Calendar.add_days(...)`
                    // 会被重写为 `std.time.Calendar.add_days(...)`
                    var sibling_modules = std.StringHashMap([]const u8).init(allocator);
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

                    // 对 pack 中每个 pub pack X，读嵌入表中的 <pack>/<X>.glue
                    // 注意：忽略 specific_sub 过滤，加载 pack 内全部子模块。
                    // 原因：子模块之间存在跨模块依赖（如 SystemTime.to_local 调用
                    // DateTime.from_components），只加载指定子模块会导致 sema 报
                    // undefined variable。stdlib 体量较小，全量加载可接受。
                    _ = specific_sub;
                    for (pack_module.declarations) |pack_decl| {
                        switch (pack_decl) {
                            .pack_decl => |pd| {
                                const sub_name = pd.name;
                                // 跳过已加载的子模块（多个 import std.<pack>.<sub> 时避免重复）
                                const sub_key = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_name, sub_name }) catch continue;
                                defer allocator.free(sub_key);
                                if (loaded_submodules.contains(sub_key)) continue;
                                loaded_submodules.put(try ast_arena.dupe(u8, sub_key), {}) catch continue;
                                const sub_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.glue", .{ pack_name, sub_name }) catch continue;
                                const sub_src_embed = std_embed.find(sub_path) orelse continue;

                                // @embedFile 返回的是 const 数据，需要 dupe 一份以匹配 retained_sources 的 free 语义
                                const sub_src = try allocator.dupe(u8, sub_src_embed);

                                // 词法分析
                                var sub_lex = lexer.Lexer.init(allocator, sub_src);
                                const sub_tokens = sub_lex.tokenize() catch {
                                    allocator.free(sub_src);
                                    continue;
                                };

                                // 语法分析
                                const sub_parser_ptr = try allocator.create(parser.Parser);
                                sub_parser_ptr.* = parser.Parser.init(allocator, sub_tokens);
                                const sub_module = sub_parser_ptr.parseModule(sub_name) catch {
                                    sub_parser_ptr.deinit();
                                    allocator.destroy(sub_parser_ptr);
                                    allocator.free(sub_tokens);
                                    allocator.free(sub_src);
                                    continue;
                                };

                                // 保留资源
                                try retained_parsers.append(allocator, sub_parser_ptr);
                                try retained_sources.append(allocator, sub_src);
                                try retained_tokens.append(allocator, sub_tokens);

                                // 收集 pub fun 声明，重命名为 std.<pack>.<sub>.<fun>
                                // 先构建本子模块短名 → mangled name 映射，用于重写函数体内部
                                // 对同模块其他函数的短名调用（如 weekday_of 内部调用 to_julian_day）
                                // 注意：不重写 type 构造器调用（如 Duration(...)），sema 通过
                                // 合并的 type_decl 解析构造器名
                                var local_renames = std.StringHashMap([]const u8).init(allocator);
                                defer local_renames.deinit();
                                for (sub_module.declarations) |sd| {
                                    switch (sd) {
                                        .fun_decl => |fd| {
                                            if (fd.visibility == .public) {
                                                const mangled = std.fmt.allocPrint(ast_arena, "std.{s}.{s}.{s}", .{ pack_name, sub_name, fd.name }) catch continue;
                                                local_renames.put(fd.name, mangled) catch continue;
                                            }
                                        },
                                        .expr_decl => |ed| {
                                            // 收集 pub val 声明（如 SystemTime.UNIX_EPOCH）的短名 → mangled name
                                            if (ed.stmt) |st| {
                                                switch (st.*) {
                                                    .val_decl => |vd| {
                                                        if (vd.visibility == .public) {
                                                            const mangled = std.fmt.allocPrint(ast_arena, "std.{s}.{s}.{s}", .{ pack_name, sub_name, vd.name }) catch continue;
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
                                                ast_rewrite.rewriteModuleCalls(new_fd.body, &local_renames, &sibling_modules, ast_arena);
                                                try extra_decls.append(allocator, .{ .fun_decl = new_fd });
                                            }
                                        },
                                        // 合并 pub type_decl：newtype/record/ADT 类型定义需要被加载，
                                        // 否则函数体内部的 newtype 构造器（如 Duration(...)）会找不到类型
                                        .type_decl => |td| {
                                            if (td.visibility == .public) {
                                                var new_td = td;
                                                new_td.visibility = .private;
                                                try extra_decls.append(allocator, .{ .type_decl = new_td });
                                            }
                                        },
                                        // 合并 pub val 声明（expr_decl 包装的 val_decl，如 SystemTime.UNIX_EPOCH）
                                        // 重命名 name 为 mangled name，重写 value 中的同模块短名调用
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
                                                            ast_rewrite.rewriteModuleCalls(vd.value, &local_renames, &sibling_modules, ast_arena);
                                                            const new_expr = ast_arena.create(ast.Expr) catch continue;
                                                            new_expr.* = .{ .unit_literal = {} };
                                                            try extra_decls.append(allocator, .{ .expr_decl = .{
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
                            },
                            else => {},
                        }
                    }
                    continue;
                }

                // 读取 pack.glue
                const pack_path = try std.fmt.allocPrint(allocator, "{s}{s}{c}pack.glue", .{ source_dir_with_sep, module_name, std.fs.path.sep });
                defer allocator.free(pack_path);
                const pack_src = cwd.readFileAlloc(io, pack_path, allocator, .unlimited) catch continue;
                defer allocator.free(pack_src);

                // 解析 pack.glue
                var pack_lex = lexer.Lexer.init(allocator, pack_src);
                defer pack_lex.deinit();
                const pack_tokens = pack_lex.tokenize() catch continue;
                defer allocator.free(pack_tokens);
                var pack_parser = parser.Parser.init(allocator, pack_tokens);
                defer pack_parser.deinit();
                const pack_module = pack_parser.parseModule("pack") catch continue;

                // 构建 sibling_modules：同 pack 内所有子模块短名 → 完整模块路径
                var sibling_modules = std.StringHashMap([]const u8).init(allocator);
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

                // 查找子模块名
                for (pack_module.declarations) |pack_decl| {
                    switch (pack_decl) {
                        .pack_decl => |pd| {
                            const sub_name = pd.name;
                            // 跳过已加载的子模块（多个 import 涉及同 pack 时避免重复）
                            const sub_key = std.fmt.allocPrint(allocator, "{s}/{s}", .{ module_name, sub_name }) catch continue;
                            defer allocator.free(sub_key);
                            if (loaded_submodules.contains(sub_key)) continue;
                            loaded_submodules.put(try ast_arena.dupe(u8, sub_key), {}) catch continue;

                            // 读取子模块文件
                            const sub_path = try std.fmt.allocPrint(allocator, "{s}{s}{c}{s}.glue", .{ source_dir_with_sep, module_name, std.fs.path.sep, sub_name });
                            defer allocator.free(sub_path);
                            const sub_src = cwd.readFileAlloc(io, sub_path, allocator, .unlimited) catch continue;

                            // 词法分析
                            var sub_lex = lexer.Lexer.init(allocator, sub_src);
                            const sub_tokens = sub_lex.tokenize() catch {
                                allocator.free(sub_src);
                                continue;
                            };

                            // 语法分析
                            const sub_parser_ptr = try allocator.create(parser.Parser);
                            sub_parser_ptr.* = parser.Parser.init(allocator, sub_tokens);
                            const sub_module = sub_parser_ptr.parseModule(sub_name) catch {
                                sub_parser_ptr.deinit();
                                allocator.destroy(sub_parser_ptr);
                                allocator.free(sub_tokens);
                                allocator.free(sub_src);
                                continue;
                            };

                            // 保留资源
                            try retained_parsers.append(allocator, sub_parser_ptr);
                            try retained_sources.append(allocator, sub_src);
                            try retained_tokens.append(allocator, sub_tokens);

                            // 收集 pub fun 声明，重命名为 Module.Sub.fun
                            // 先构建本子模块短名 → mangled name 映射，用于重写函数体内部
                            // 对同模块其他函数的短名调用
                            // 注意：不重写 type 构造器调用，sema 通过合并的 type_decl 解析
                            var local_renames = std.StringHashMap([]const u8).init(allocator);
                            defer local_renames.deinit();
                            for (sub_module.declarations) |sd| {
                                switch (sd) {
                                    .fun_decl => |fd| {
                                        if (fd.visibility == .public) {
                                            const mangled = std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ module_name, sub_name, fd.name }) catch continue;
                                            local_renames.put(fd.name, mangled) catch continue;
                                        }
                                    },
                                    .expr_decl => |ed| {
                                        // 收集 pub val 声明的短名 → mangled name
                                        if (ed.stmt) |st| {
                                            switch (st.*) {
                                                .val_decl => |vd| {
                                                    if (vd.visibility == .public) {
                                                        const mangled = std.fmt.allocPrint(ast_arena, "{s}.{s}.{s}", .{ module_name, sub_name, vd.name }) catch continue;
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
                                            ast_rewrite.rewriteModuleCalls(new_fd.body, &local_renames, &sibling_modules, ast_arena);
                                            try extra_decls.append(allocator, .{ .fun_decl = new_fd });
                                        }
                                    },
                                    .type_decl => |td| {
                                        if (td.visibility == .public) {
                                            var new_td = td;
                                            new_td.visibility = .private;
                                            try extra_decls.append(allocator, .{ .type_decl = new_td });
                                        }
                                    },
                                    // 合并 pub val 声明（expr_decl 包装的 val_decl）
                                    // 重命名 name 为 mangled name，重写 value 中的同模块短名调用
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
                                                        ast_rewrite.rewriteModuleCalls(vd.value, &local_renames, &sibling_modules, ast_arena);
                                                        const new_expr = ast_arena.create(ast.Expr) catch continue;
                                                        new_expr.* = .{ .unit_literal = {} };
                                                        try extra_decls.append(allocator, .{ .expr_decl = .{
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
                        },
                        else => {},
                    }
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

/// 完整执行管线：词法分析 → 语法分析 → IR 构建 → IR 优化 → 引擎执行
pub fn executeSource(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    io: std.Io,
    source: []const u8,
    filename: []const u8,
) ExecOutcome {
    _ = loader; // module_loader 暂未接入新流水线（单文件模式）

    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    args_mod.global_prof.phases.phaseBegin(.lex);
    const tokens = lex.tokenize() catch |err| {
        args_mod.global_prof.phases.phaseEnd(.lex);
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: lexer error: {s}\n", .{ filename, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .failed;
    };
    args_mod.global_prof.phases.phaseEnd(.lex);
    defer allocator.free(tokens);

    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();
    args_mod.global_prof.phases.phaseBegin(.parse);
    const module = p.parseModule(filename) catch {
        args_mod.global_prof.phases.phaseEnd(.parse);
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        for (p.errors.items) |e| {
            stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
        }
        stderr_writer.flush() catch {};
        return .failed;
    };
    args_mod.global_prof.phases.phaseEnd(.parse);
    var entry_module = module;
    entry_module.source_path = filename;

    // 加载导入的子模块声明（多模块支持）
    var retained_parsers = std.ArrayList(*parser.Parser).empty;
    defer {
        for (retained_parsers.items) |*rp| {
            rp.*.deinit();
            allocator.destroy(rp.*);
        }
        retained_parsers.deinit(allocator);
    }
    var retained_sources = std.ArrayList([]const u8).empty;
    defer {
        for (retained_sources.items) |s| allocator.free(s);
        retained_sources.deinit(allocator);
    }
    var retained_tokens = std.ArrayList([]lexer.Token).empty;
    defer {
        for (retained_tokens.items) |t| allocator.free(t);
        retained_tokens.deinit(allocator);
    }
    // AST arena：管理 loadImportedDeclarations 和 rewriteModuleCalls 中创建的
    // 临时 AST 节点（mangled names、callee_ptr、new_stmt/expr、combined 数组）。
    // 这些节点随 entry_module 一起使用，IR 构建完成后统一释放。
    var ast_arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena_inst.deinit();
    const ast_arena = ast_arena_inst.allocator();

    // 模块加载阶段
    args_mod.global_prof.phases.phaseBegin(.module_load);
    loadImportedDeclarations(allocator, io, &entry_module, filename, &retained_parsers, &retained_sources, &retained_tokens, ast_arena) catch {};
    args_mod.global_prof.phases.phaseEnd(.module_load);

    // sema 阶段（语义分析 + 图构建元信息产出）
    // TypeInferencer.checkModule 推断所有表达式类型并记录到 SemaResult.expr_types，
    // 供 IRBuilder 在图构建时读取（驱动式接入：sema 驱动 IR 构建）。
    // 硬失败：sema 检出任何类型错误则打印并终止管线，不进入 IR 构建。
    args_mod.global_prof.phases.phaseBegin(.type_check);
    var sema_result = ir.SemaResult.init(allocator);
    defer sema_result.deinit();
    {
        var inferencer = sema.TypeInferencer.init(allocator);
        defer inferencer.deinit();
        inferencer.setSemaResult(&sema_result);
        inferencer.checkModule(&entry_module);
        if (inferencer.errors.items.len > 0) {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            for (inferencer.errors.items) |e| {
                stderr_writer.interface.print("{s}:{d}:{d}: sema error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
            }
            stderr_writer.flush() catch {};
            args_mod.global_prof.phases.phaseEnd(.type_check);
            return .failed;
        }
    }
    args_mod.global_prof.phases.phaseEnd(.type_check);

    // IR 构建阶段（AST → Glue IR 共享内存图）
    args_mod.global_prof.phases.phaseBegin(.ir_build);
    var builder = ir.IRBuilder.init(allocator) catch |err| {
        args_mod.global_prof.phases.phaseEnd(.ir_build);
        args_mod.printError(io, "{s}: IR builder init error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    // 注入 sema 产出的类型映射，驱动图构建（通道宽度由 sema 类型决定）
    builder.setSemaResult(&sema_result);
    // 运行纯度分析（fused_analysis）并注入 IRBuilder，驱动 memoization slot 分配
    // 纯函数 + 标量参数/返回 → compileCall 分配 memo_slot，Engine 运行时缓存结果
    var analysis_db = analysis_db_mod.AnalysisDB.init(allocator);
    defer analysis_db.deinit();
    args_mod.global_prof.phases.phaseBegin(.fused_analysis);
    {
        var fused = analysis_db_mod.FusedAnalysis.init(
            allocator,
            &analysis_db.const_prop,
            &analysis_db.loop_invariant,
            &analysis_db.purity,
            &analysis_db.hoist_table,
            &analysis_db.dead_code,
            &analysis_db.cse,
            &analysis_db.escape,
            &analysis_db.param_escape,
        );
        defer fused.deinit();
        fused.analyzeModule(&entry_module) catch |err| {
            args_mod.printError(io, "fused analysis error: {s}\n", .{@errorName(err)});
        };
    }
    args_mod.global_prof.phases.phaseEnd(.fused_analysis);
    builder.setPurityDB(&analysis_db.purity);
    builder.setEscapeTable(&analysis_db.escape);
    args_mod.global_prof.phases.phaseBegin(.ir_build_core);
    var glue_ir = builder.build(entry_module) catch |err| {
        args_mod.global_prof.phases.phaseEnd(.ir_build_core);
        args_mod.global_prof.phases.phaseEnd(.ir_build);
        args_mod.printError(io, "{s}: IR build error: {s}\n", .{ filename, @errorName(err) });
        builder.deinit();
        return .failed;
    };
    // build() 成功后 arena 所有权转交 glue_ir，builder.deinit() 不再释放 arena
    builder.deinit();
    defer glue_ir.deinit();
    args_mod.global_prof.phases.phaseEnd(.ir_build_core);
    args_mod.global_prof.phases.phaseEnd(.ir_build);

    // 注入函数名表到 profiler（深拷贝，glue_ir deinit 后仍可使用）
    if (args_mod.profile_enabled) {
        var names_buf = std.ArrayList([]const u8).empty;
        defer names_buf.deinit(allocator);
        for (glue_ir.functions) |f| names_buf.append(allocator, f.name) catch break;
        args_mod.global_prof.setFuncNames(names_buf.items) catch {};
    }

    // IR 优化阶段（常量折叠 + 死节点消除 + 向量融合 + 通道活跃性）
    args_mod.global_prof.phases.phaseBegin(.ir_optimize);
    _ = ir.optimize(&glue_ir);
    args_mod.global_prof.phases.phaseEnd(.ir_optimize);

    // 引擎执行阶段
    args_mod.global_prof.phases.phaseBegin(.engine_run);
    args_mod.global_prof.phases.phaseBegin(.engine_setup);
    var eng = engine.Engine.initOwned(&glue_ir, allocator, &args_mod.global_prof, io) catch |err| {
        args_mod.global_prof.phases.phaseEnd(.engine_setup);
        args_mod.global_prof.phases.phaseEnd(.engine_run);
        args_mod.printError(io, "{s}: engine init error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    eng.io = io; // 注入 IO 接口供内置 print/println 使用
    args_mod.global_prof.phases.phaseEnd(.engine_setup);
    defer {
        args_mod.global_prof.phases.phaseBegin(.engine_teardown);
        eng.deinit();
        args_mod.global_prof.phases.phaseEnd(.engine_teardown);
        args_mod.global_prof.phases.phaseEnd(.engine_run);
    }

    args_mod.global_prof.phases.phaseBegin(.engine_exec);
    const result = eng.run() catch |err| {
        args_mod.global_prof.phases.phaseEnd(.engine_exec);
        args_mod.printError(io, "{s}: execution error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    args_mod.global_prof.phases.phaseEnd(.engine_exec);

    // 输出 main 函数返回值（unit/null 类型不打印）
    const ret_chan_type = glue_ir.channels.get(eng.result_chan).chan_type;
    if (ret_chan_type != .unit_chan and ret_chan_type != .null_chan) {
        var out_buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
        stdout_writer.interface.print("{d}\n", .{result}) catch {};
        stdout_writer.flush() catch {};
    }

    return .ran_main;
}
