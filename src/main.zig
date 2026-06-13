const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const eval = @import("eval");

pub fn main(init: std.process.Init) !void {
    // Windows 控制台默认使用 GBK 编码，需设置为 UTF-8 以正确输出非 ASCII 字符
    if (builtin.os.tag == .windows) {
        setWindowsConsoleUtf8();
    }

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
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, filename, allocator, .unlimited) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: error: could not read file: {s}\n", .{ filename, @errorName(err) }) catch {};
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

    executeSource(arena_alloc, &ev, io, source, filename);

    // 文件模式下，查找并调用 main 入口函数
    _ = ev.callMain() catch |err| switch (err) {
        error.MissingMain => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: error: undefined entry point — every program requires a 'fun main()' declaration\n", .{filename}) catch {};
            stderr_writer.flush() catch {};
        },
        error.GluePanic => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            const msg = ev.panic_message orelse "unknown error";
            stderr_writer.interface.print("{s}: runtime panic: {s}\n", .{ filename, msg }) catch {};
            stderr_writer.flush() catch {};
            ev.panic_message = null;
        },
        else => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: runtime error: {s}\n", .{ filename, @errorName(err) }) catch {};
            if (ev.panic_message) |msg| {
                stderr_writer.interface.print("  detail: {s}\n", .{msg}) catch {};
            }
            stderr_writer.flush() catch {};
        },
    };
}

fn runRepl(allocator: std.mem.Allocator, io: std.Io) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const stdout = &stdout_writer.interface;

    var in_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const stdin = &stdin_reader.interface;

    try stdout.print("Glue v0.1.0 -- Interactive REPL\n", .{});
    try stdout_writer.flush();
    try stdout.print("Enter expressions to evaluate, type :quit to exit\n\n", .{});
    try stdout_writer.flush();

    var ev = eval.Evaluator.initWithIo(allocator, io);
    defer ev.deinit();

    while (true) {
        try stdout.print("> ", .{});
        try stdout_writer.flush();

        const line = stdin.takeDelimiter('\n') catch |err| {
            if (err == error.EndOfStream) break;
            try stdout.print("<repl>: error: failed to read input: {s}\n", .{@errorName(err)});
            try stdout_writer.flush();
            continue;
        };

        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) break;

            executeSource(allocator, &ev, io, trimmed, "<repl>");
        } else {
            break;
        }
    }

    try stdout.print("\nBye!\n", .{});
    try stdout_writer.flush();
}

fn executeSource(allocator: std.mem.Allocator, ev: *eval.Evaluator, io: std.Io, source: []const u8, filename: []const u8) void {
    // 词法分析
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    const tokens = lex.tokenize() catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: lexer error: {s}\n", .{ filename, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return;
    };
    defer allocator.free(tokens);

    // 语法分析 — 尝试解析为模块（顶层声明）
    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = p.parseModule(filename) catch {
        // 模块解析失败，尝试解析为表达式
        p.errors.clearRetainingCapacity();
        p.current = 0;

        const expr = p.parseExpr() catch {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            for (p.errors.items) |e| {
                stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
            }
            stderr_writer.flush() catch {};
            return;
        };

        // 求值表达式
        const result = ev.evalExpr(expr, &ev.global_env) catch |err| switch (err) {
            error.GluePanic => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                const msg = ev.panic_message orelse "unknown panic";
                stderr_writer.interface.print("{s}: panic: {s}\n", .{ filename, msg }) catch {};
                stderr_writer.flush() catch {};
                ev.panic_message = null;
                return;
            },
            else => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                stderr_writer.interface.print("{s}: runtime error: {s}\n", .{ filename, @errorName(err) }) catch {};
                stderr_writer.flush() catch {};
                return;
            },
        };

        // 打印结果
        if (result != .unit) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            result.format(&buf, allocator, false) catch return;
            buf.append(allocator, '\n') catch {};
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        }
        return;
    };

    // 求值模块
    ev.evalModule(module) catch |err| switch (err) {
        error.GluePanic => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            const msg = ev.panic_message orelse "unknown error";
            stderr_writer.interface.print("{s}: runtime panic: {s}\n", .{ filename, msg }) catch {};
            stderr_writer.flush() catch {};
            ev.panic_message = null;
        },
        error.CircularDependency => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: error: circular module dependency\n", .{filename}) catch {};
            stderr_writer.flush() catch {};
        },
        else => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: runtime error: {s}\n", .{ filename, @errorName(err) }) catch {};
            if (ev.panic_message) |msg| {
                stderr_writer.interface.print("  detail: {s}\n", .{msg}) catch {};
            }
            stderr_writer.flush() catch {};
        },
    };
}

fn setWindowsConsoleUtf8() void {
    const windows = std.os.windows;
    const CP_UTF8: windows.UINT = 65001;
    _ = SetConsoleOutputCP(CP_UTF8);
}

const SetConsoleOutputCP = @extern(
    *const fn (std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL,
    .{ .name = "SetConsoleOutputCP" },
);
