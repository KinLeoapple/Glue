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
const args_mod = @import("args.zig");
const value = @import("value");

/// 源码执行结果：成功或失败
pub const ExecOutcome = enum { failed, ran_main };

/// 完整执行管线：词法分析 → 语法分析 → IR 构建 → IR 优化 → 引擎执行
pub fn executeSource(
    allocator: std.mem.Allocator,
    loader: *module_loader.ModuleLoader,
    cli_ctx: *args_mod.CliContext,
    io: std.Io,
    source: []const u8,
    filename: []const u8,
) ExecOutcome {
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    cli_ctx.prof.phases.phaseBegin(.lex);
    const tokens = lex.tokenize() catch |err| {
        cli_ctx.prof.phases.phaseEnd(.lex);
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: lexer error: {s}\n", .{ filename, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .failed;
    };
    cli_ctx.prof.phases.phaseEnd(.lex);
    defer allocator.free(tokens);

    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();
    cli_ctx.prof.phases.phaseBegin(.parse);
    const module = p.parseModule(filename) catch {
        cli_ctx.prof.phases.phaseEnd(.parse);
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        for (p.errors.items) |e| {
            stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
        }
        stderr_writer.flush() catch {};
        return .failed;
    };
    cli_ctx.prof.phases.phaseEnd(.parse);
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
    // AST arena：管理 loadDecls 和 rewriteModuleCalls 中创建的
    // 临时 AST 节点（mangled names、callee_ptr、new_stmt/expr、combined 数组）。
    // 这些节点随 entry_module 一起使用，IR 构建完成后统一释放。
    var ast_arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena_inst.deinit();
    const ast_arena = ast_arena_inst.allocator();

    // 模块加载阶段
    cli_ctx.prof.phases.phaseBegin(.module_load);
    loader.loadDecls(&entry_module, filename, &retained_parsers, &retained_sources, &retained_tokens, ast_arena) catch {};
    cli_ctx.prof.phases.phaseEnd(.module_load);

    // sema 阶段（语义分析 + 图构建元信息产出）
    // TypeInferencer.checkModule 推断所有表达式类型并记录到 SemaResult.expr_types，
    // 供 IRBuilder 在图构建时读取（驱动式接入：sema 驱动 IR 构建）。
    // 硬失败：sema 检出任何类型错误则打印并终止管线，不进入 IR 构建。
    cli_ctx.prof.phases.phaseBegin(.type_check);
    var sema_result = ir.SemaResult.init(allocator);
    defer sema_result.deinit();
    {
        var inferencer = sema.TypeInferencer.init(allocator);
        defer inferencer.deinit();
        inferencer.setSemaResult(&sema_result);
        inferencer.checkModule(&entry_module) catch {
            cli_ctx.prof.phases.phaseEnd(.type_check);
            return .failed;
        };
        if (inferencer.errors.items.len > 0) {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            for (inferencer.errors.items) |e| {
                stderr_writer.interface.print("{s}:{d}:{d}: sema error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
            }
            stderr_writer.flush() catch {};
            cli_ctx.prof.phases.phaseEnd(.type_check);
            return .failed;
        }
    }
    cli_ctx.prof.phases.phaseEnd(.type_check);

    // IR 构建阶段（AST → Glue IR 共享内存图）
    cli_ctx.prof.phases.phaseBegin(.ir_build);
    var builder = ir.IRBuilder.init(allocator) catch |err| {
        cli_ctx.prof.phases.phaseEnd(.ir_build);
        args_mod.printError(io, "{s}: IR builder init error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    // 注入 sema 产出的类型映射，驱动图构建（通道宽度由 sema 类型决定）
    builder.setSemaResult(&sema_result);
    // 运行纯度分析（fused_analysis）并注入 IRBuilder，驱动 memoization slot 分配
    // 纯函数 + 标量参数/返回 → compileCall 分配 memo_slot，Engine 运行时缓存结果
    var analysis_db = analysis_db_mod.AnalysisDB.init(allocator);
    defer analysis_db.deinit();
    cli_ctx.prof.phases.phaseBegin(.fused_analysis);
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
    cli_ctx.prof.phases.phaseEnd(.fused_analysis);
    builder.setPurityDB(&analysis_db.purity);
    builder.setEscapeTable(&analysis_db.escape);
    cli_ctx.prof.phases.phaseBegin(.ir_build_core);
    var glue_ir = builder.build(entry_module) catch |err| {
        cli_ctx.prof.phases.phaseEnd(.ir_build_core);
        cli_ctx.prof.phases.phaseEnd(.ir_build);
        args_mod.printError(io, "{s}: IR build error: {s} (in func: {?s}, last expr: {s})\n", .{ filename, @errorName(err), builder.debug_error_func_name, builder.debug_last_expr_tag });
        builder.deinit();
        return .failed;
    };
    // build() 成功后 arena 所有权转交 glue_ir，builder.deinit() 不再释放 arena
    builder.deinit();
    defer glue_ir.deinit();
    cli_ctx.prof.phases.phaseEnd(.ir_build_core);
    cli_ctx.prof.phases.phaseEnd(.ir_build);

    // 注入函数名表到 profiler（深拷贝，glue_ir deinit 后仍可使用）
    if (cli_ctx.profile_enabled) {
        var names_buf = std.ArrayList([]const u8).empty;
        defer names_buf.deinit(allocator);
        for (glue_ir.functions) |f| names_buf.append(allocator, f.name) catch break;
        cli_ctx.prof.setFuncNames(names_buf.items) catch {};
    }

    // IR 优化阶段（常量折叠 + 死节点消除 + 向量融合 + 通道活跃性）
    cli_ctx.prof.phases.phaseBegin(.ir_optimize);
    _ = ir.optimize(&glue_ir);
    cli_ctx.prof.phases.phaseEnd(.ir_optimize);

    // 引擎执行阶段
    cli_ctx.prof.phases.phaseBegin(.engine_run);
    cli_ctx.prof.phases.phaseBegin(.engine_setup);
    var eng = engine.Engine.initOwned(&glue_ir, allocator, cli_ctx.prof, io) catch |err| {
        cli_ctx.prof.phases.phaseEnd(.engine_setup);
        cli_ctx.prof.phases.phaseEnd(.engine_run);
        args_mod.printError(io, "{s}: engine init error: {s}\n", .{ filename, @errorName(err) });
        return .failed;
    };
    eng.io = io; // 注入 IO 接口供 syscall dispatch 使用
    cli_ctx.prof.phases.phaseEnd(.engine_setup);
    defer {
        cli_ctx.prof.phases.phaseBegin(.engine_teardown);
        eng.deinit();
        cli_ctx.prof.phases.phaseEnd(.engine_teardown);
        cli_ctx.prof.phases.phaseEnd(.engine_run);
    }

    cli_ctx.prof.phases.phaseBegin(.engine_exec);
    const result = eng.run() catch |err| {
        cli_ctx.prof.phases.phaseEnd(.engine_exec);
        if (eng.lastErrorLoc()) |loc| {
            args_mod.printError(io, "{s}:{d}:{d}: execution error: {s}\n", .{ filename, loc.line, loc.column, @errorName(err) });
        } else {
            args_mod.printError(io, "{s}: execution error: {s}\n", .{ filename, @errorName(err) });
        }
        return .failed;
    };
    cli_ctx.prof.phases.phaseEnd(.engine_exec);

    // 通用返回值打印：按 value.Value 变体分派，完整支持所有标量类型（含 i128/u128/f128）。
    // - 整数/浮点/布尔：打印字面值
    // - 引用类型（ref）：指针值打印无意义，不打印（避免泄露地址、避免误判位模式）
    // - unit/null/char：不打印
    printReturnValue(io, result);

    return .ran_main;
}

/// 按值变体打印标量返回值。
/// 仅整数/浮点/布尔打印字面值；引用/unit/null/char 不打印（与 main 函数语义一致）。
fn printReturnValue(io: std.Io, v: value.Value) void {
    var out_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    switch (v) {
        .i8 => |b| stdout_writer.interface.print("{d}\n", .{@as(i8, @bitCast(b[0]))}) catch {},
        .u8 => |b| stdout_writer.interface.print("{d}\n", .{b[0]}) catch {},
        .i16 => |b| stdout_writer.interface.print("{d}\n", .{@as(i16, @bitCast(b))}) catch {},
        .u16 => |b| stdout_writer.interface.print("{d}\n", .{@as(u16, @bitCast(b))}) catch {},
        .i32 => |b| stdout_writer.interface.print("{d}\n", .{@as(i32, @bitCast(b))}) catch {},
        .u32 => |b| stdout_writer.interface.print("{d}\n", .{@as(u32, @bitCast(b))}) catch {},
        .i64 => |b| stdout_writer.interface.print("{d}\n", .{@as(i64, @bitCast(b))}) catch {},
        .u64 => |b| stdout_writer.interface.print("{d}\n", .{@as(u64, @bitCast(b))}) catch {},
        .i128 => |b| stdout_writer.interface.print("{d}\n", .{@as(i128, @bitCast(b))}) catch {},
        .u128 => |b| stdout_writer.interface.print("{d}\n", .{@as(u128, @bitCast(b))}) catch {},
        .isize => |b| stdout_writer.interface.print("{d}\n", .{@as(isize, @bitCast(b))}) catch {},
        .usize => |b| stdout_writer.interface.print("{d}\n", .{@as(usize, @bitCast(b))}) catch {},
        .f16 => |b| stdout_writer.interface.print("{d}\n", .{@as(f16, @bitCast(b))}) catch {},
        .f32 => |b| stdout_writer.interface.print("{d}\n", .{@as(f32, @bitCast(b))}) catch {},
        .f64 => |b| stdout_writer.interface.print("{d}\n", .{@as(f64, @bitCast(b))}) catch {},
        .f128 => |b| stdout_writer.interface.print("{d}\n", .{@as(f128, @bitCast(b))}) catch {},
        .boolean => |b| stdout_writer.interface.print("{s}\n", .{if (b[0] != 0) "true" else "false"}) catch {},
        // ref/unit/null/char：返回值非标量字面量，不打印
        else => {},
    }
    stdout_writer.flush() catch {};
}
