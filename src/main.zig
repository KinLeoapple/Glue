const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const eval = @import("eval");

/// 把求值器错误映射为专业英文消息（Go/Java 风格）。
/// 若求值器已经设置了带上下文的 panic_message（如 "no method 'x' on type 'array'"），
/// 优先使用它；否则按错误枚举给出通用但专业的兜底措辞。
fn runtimeErrorMessage(err: anyerror, panic_message: ?[]const u8) []const u8 {
    if (panic_message) |msg| return msg;
    return switch (err) {
        error.TypeMismatch => "type error: incompatible types",
        error.UndefinedVariable => "undefined name",
        error.ImmutableAssignment => "cannot assign to immutable binding",
        error.NotCallable => "value is not callable",
        error.WrongArity => "wrong number of arguments",
        error.IndexOutOfBounds => "index out of bounds",
        error.UnsupportedOperation => "unsupported operation",
        error.OutOfMemory => "out of memory",
        error.CircularDependency => "circular module dependency",
        error.FileNotFound => "file not found",
        error.MissingMain => "undefined entry point",
        else => @errorName(err),
    };
}

/// 打印一条运行时诊断，带可选行列。有位置则 `file:line:col: label: msg`，否则 `file: label: msg`。
fn printRuntimeDiag(iface: anytype, filename: []const u8, loc: ?ast.SourceLocation, label: []const u8, msg: []const u8) void {
    if (loc) |l| {
        iface.print("{s}:{d}:{d}: {s}: {s}\n", .{ filename, l.line, l.column, label, msg }) catch {};
    } else {
        iface.print("{s}: {s}: {s}\n", .{ filename, label, msg }) catch {};
    }
}

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

    const has_error = executeSource(arena_alloc, &ev, io, source, filename);

    // 文件模式下，查找并调用 main 入口函数
    // 文档 D13: 入口点默认 Main.main，约定优于配置
    if (!has_error) {
        _ = ev.callMain() catch |err| switch (err) {
            error.MissingMain => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                stderr_writer.interface.print("{s}: error: undefined entry point\n", .{filename}) catch {};
                stderr_writer.flush() catch {};
            },
            error.GluePanic => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                const msg = ev.panic_message orelse "unknown error";
                printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "runtime panic", msg);
                stderr_writer.flush() catch {};
                ev.panic_message = null;
            },
            else => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "runtime error", runtimeErrorMessage(err, ev.panic_message));
                stderr_writer.flush() catch {};
            },
        };
    }
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

            _ = executeSource(allocator, &ev, io, trimmed, "<repl>");
        } else {
            break;
        }
    }

    try stdout.print("\nBye!\n", .{});
    try stdout_writer.flush();
}

fn executeSource(allocator: std.mem.Allocator, ev: *eval.Evaluator, io: std.Io, source: []const u8, filename: []const u8) bool {
    // 词法分析
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    const tokens = lex.tokenize() catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
        stderr_writer.interface.print("{s}: lexer error: {s}\n", .{ filename, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return true;
    };
    defer allocator.free(tokens);

    // 语法分析 — 尝试解析为模块（顶层声明）
    var p = parser.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = p.parseModule(filename) catch {
        // 模块解析失败，保存错误信息
        const module_errors = allocator.dupe(parser.ParseError, p.errors.items) catch {
            // 内存不足，直接报告表达式解析错误
            p.errors.clearRetainingCapacity();
            p.current = 0;
            const expr_fallback = p.parseExpr() catch {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                for (p.errors.items) |e| {
                    stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
                }
                stderr_writer.flush() catch {};
                return true;
            };
            _ = expr_fallback;
            return true;
        };
        defer allocator.free(module_errors);

        // 尝试解析为表达式
        p.errors.clearRetainingCapacity();
        p.current = 0;

        const expr = p.parseExpr() catch {
            // 表达式解析也失败，报告所有模块解析错误
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            const errors_to_report = if (module_errors.len > 0) module_errors else p.errors.items;
            for (errors_to_report) |e| {
                stderr_writer.interface.print("{s}:{d}:{d}: parse error: {s}\n", .{ filename, e.line, e.column, e.message }) catch {};
            }
            stderr_writer.flush() catch {};
            return true;
        };

        // 求值表达式
        const result = ev.evalExpr(expr, &ev.global_env) catch |err| switch (err) {
            error.GluePanic => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                const msg = ev.panic_message orelse "unknown panic";
                printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "panic", msg);
                stderr_writer.flush() catch {};
                ev.panic_message = null;
                return true;
            },
            else => {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "runtime error", runtimeErrorMessage(err, ev.panic_message));
                stderr_writer.flush() catch {};
                return true;
            },
        };

        // 打印结果
        if (result != .unit) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            result.format(&buf, allocator, false) catch return true;
            buf.append(allocator, '\n') catch {};
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        }
        return false;
    };

    // 求值模块
    // 入口文件路径作为 source_path，使 current_source_dir 能正确解析相对 use 依赖
    // （文档 §4.5）。否则从父目录运行 `glue dir/Main.glue` 时基目录误为 `.`。
    var entry_module = module;
    entry_module.source_path = filename;
    ev.evalModule(entry_module) catch |err| switch (err) {
        error.GluePanic => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            const msg = ev.panic_message orelse "unknown error";
            printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "runtime panic", msg);
            stderr_writer.flush() catch {};
            ev.panic_message = null;
            return true;
        },
        error.CircularDependency => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: error: circular module dependency\n", .{filename}) catch {};
            stderr_writer.flush() catch {};
            return true;
        },
        error.AmbiguousModule => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}: error: ambiguous module — both a flat file 'Mod.glue' and a directory module 'Mod/pack.glue' exist; remove one\n", .{filename}) catch {};
            stderr_writer.flush() catch {};
            return true;
        },
        else => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            printRuntimeDiag(&stderr_writer.interface, filename, ev.panic_location, "runtime error", runtimeErrorMessage(err, ev.panic_message));
            stderr_writer.flush() catch {};
            return true;
        },
    };
    return false;
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
