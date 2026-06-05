const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const eval = @import("eval");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args_slice = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());

    if (args_slice.len > 1) {
        try runFile(allocator, io, args_slice[1]);
    } else {
        try runRepl(allocator, io);
    }
}

fn runFile(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const source = dir.readFileAlloc(io, filename, allocator, .unlimited) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("错误：无法读取文件 '{s}': {}\n", .{ filename, err }) catch {};
        stderr_writer.flush() catch {};
        return;
    };
    defer allocator.free(source);

    // 使用 ArenaAllocator 管理解析和求值的所有临时分配
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ev = eval.Evaluator.initWithIo(arena_alloc, io);
    defer ev.deinit();

    executeSource(arena_alloc, &ev, io, source);
}

fn runRepl(allocator: std.mem.Allocator, io: std.Io) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const stdout = &stdout_writer.interface;

    var in_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const stdin = &stdin_reader.interface;

    try stdout.print("Glue v0.1.0 — 交互式求值器\n", .{});
    try stdout_writer.flush();
    try stdout.print("输入表达式求值，输入 :quit 退出\n\n", .{});
    try stdout_writer.flush();

    var ev = eval.Evaluator.initWithIo(allocator, io);
    defer ev.deinit();

    while (true) {
        try stdout.print("> ", .{});
        try stdout_writer.flush();

        const line = stdin.takeDelimiter('\n') catch |err| {
            if (err == error.EndOfStream) break;
            try stdout.print("读取错误: {}\n", .{err});
            try stdout_writer.flush();
            continue;
        };

        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) break;

            executeSource(allocator, &ev, io, trimmed);
        } else {
            break;
        }
    }

    try stdout.print("\n再见！\n", .{});
    try stdout_writer.flush();
}

fn executeSource(allocator: std.mem.Allocator, ev: *eval.Evaluator, io: std.Io, source: []const u8) void {
    // 词法分析
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    const tokens = lex.tokenize() catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("词法分析错误: {}\n", .{err}) catch {};
        stderr_writer.flush() catch {};
        return;
    };
    defer allocator.free(tokens);

    // 语法分析 — 尝试解析为模块（顶层声明）
    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = p.parseModule("<repl>") catch {
        // 模块解析失败，尝试解析为表达式
        p.errors.clearRetainingCapacity();
        p.current = 0;

        const expr = p.parseExpr() catch {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            for (p.errors.items) |e| {
                stderr_writer.interface.print("{d}:{d}: {s}\n", .{ e.line, e.column, e.message }) catch {};
            }
            stderr_writer.flush() catch {};
            return;
        };

        // 求值表达式
        const result = ev.evalExpr(expr, &ev.global_env) catch |err| {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("求值错误: {}\n", .{err}) catch {};
            stderr_writer.flush() catch {};
            return;
        };

        // 打印结果
        if (result != .unit) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            result.format(&buf, allocator) catch return;
            buf.append(allocator, '\n') catch {};
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        }
        return;
    };

    // 求值模块
    ev.evalModule(module) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("求值错误: {}\n", .{err}) catch {};
        stderr_writer.flush() catch {};
    };
}
