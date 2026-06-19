const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const eval = @import("eval");
const slab_pool = @import("slab_pool");

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

/// 项目清单（glue.toml）解析结果。
const Manifest = struct {
    name: []const u8,
    version: []const u8,
    /// 入口文件相对项目根的路径，缺省 "src/Main.glue"。
    entry: []const u8,
};

const MANIFEST_NAME = "glue.toml";
const DEFAULT_ENTRY = "src/Main.glue";

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

fn printUsage(io: std.Io) void {
    printErr(io,
        \\Glue v0.1.0 — project-based language runtime
        \\
        \\Usage:
        \\  glue init [name]   Scaffold a new Glue project (in ./name or current dir)
        \\  glue run           Build and run the current project
        \\  glue debug         Run with diagnostics (memory checking + runtime trace)
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    // Windows 控制台默认使用 GBK 编码，需设置为 UTF-8 以正确输出非 ASCII 字符
    if (builtin.os.tag == .windows) {
        setWindowsConsoleUtf8();
    }

    const allocator = init.gpa;
    const io = init.io;

    const args_slice = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());

    if (args_slice.len < 2) {
        printUsage(io);
        std.process.exit(1);
    }

    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "init")) {
        const name: ?[]const u8 = if (args_slice.len >= 3) args_slice[2] else null;
        try cmdInit(allocator, io, name);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try runProject(allocator, io, false);
    } else if (std.mem.eql(u8, cmd, "debug")) {
        try runProject(allocator, io, true);
    } else {
        printErr(io, "error: unknown command '{s}'\n\n", .{cmd});
        printUsage(io);
        std.process.exit(1);
    }
}

// ============================================================
// 项目根定位 + 清单解析
// ============================================================

/// 从 cwd 向上逐级查找 glue.toml，返回项目根的相对路径前缀（"" 表示当前目录）。
/// 找不到返回 null。最多上溯 64 级（防御）。
fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var level: usize = 0;
    while (level < 64) : (level += 1) {
        // 拼出 <prefix>glue.toml 检测
        const candidate = if (prefix.items.len == 0)
            try allocator.dupe(u8, MANIFEST_NAME)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix.items, MANIFEST_NAME });
        defer allocator.free(candidate);
        if (cwd.access(io, candidate, .{})) {
            return try allocator.dupe(u8, prefix.items);
        } else |_| {}
        // 上溯一级：prefix 追加 "../"
        try prefix.appendSlice(allocator, ".." ++ [_]u8{std.fs.path.sep});
    }
    return null;
}

/// 极简 TOML 子集解析：逐行认 `key = "value"`（或裸值），忽略空行与 `#` 注释。
/// 仅取 name/version/entry 三个键；entry 缺省 src/Main.glue。返回的字符串借用 source（不分配）。
fn parseManifest(source: []const u8) Manifest {
    var name: []const u8 = "app";
    var version: []const u8 = "0.0.0";
    var entry: []const u8 = DEFAULT_ENTRY;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // 剥去成对引号
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "entry")) {
            if (val.len > 0) entry = val;
        }
    }
    return .{ .name = name, .version = version, .entry = entry };
}

// ============================================================
// glue init
// ============================================================

/// 检查目标目录状态，用于 init 的空目录约束。
const DirState = enum {
    /// 目录不存在（可创建）
    missing,
    /// 目录存在且为空
    empty,
    /// 目录存在但非空（无 glue.toml）
    non_empty,
    /// 目录存在且含 glue.toml（已是项目）
    is_project,
};

/// 检查 path 指向的目录状态。path 为空串表示当前目录。
fn checkDirState(io: std.Io, path: []const u8) DirState {
    const cwd = std.Io.Dir.cwd();
    const open_path = if (path.len == 0) "." else path;
    var dir = cwd.openDir(io, open_path, .{ .iterate = true }) catch {
        return .missing; // 打不开（多半不存在）→ 视为可创建
    };
    defer dir.close(io);
    var it = dir.iterate();
    var empty = true;
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, MANIFEST_NAME)) return .is_project;
        empty = false;
    }
    return if (empty) .empty else .non_empty;
}

fn cmdInit(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // 目标目录前缀：有 name 则 "name/"，否则当前目录 ""。
    const dir_prefix = if (name) |n|
        try std.fmt.allocPrint(allocator, "{s}{c}", .{ n, std.fs.path.sep })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dir_prefix);

    // 项目名：有 name 用 name，否则用 "app"。
    const proj_name = name orelse "app";

    // init 只在空目录初始化：先检查目标目录状态。
    // 目标目录 = name（或当前目录）；非空且非已存在项目 → 拒绝。
    const target_dir = name orelse "";
    switch (checkDirState(io, target_dir)) {
        .is_project => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printErr(io, "error: already a Glue project ({s} contains {s})\n", .{ shown, MANIFEST_NAME });
            std.process.exit(1);
        },
        .non_empty => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printErr(io, "error: {s} is not an empty directory\n", .{shown});
            std.process.exit(1);
        },
        .missing, .empty => {}, // 可初始化
    }

    // 清单路径
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, MANIFEST_NAME });
    defer allocator.free(manifest_path);

    // 创建目录：<prefix>src/
    const src_dir = try std.fmt.allocPrint(allocator, "{s}src", .{dir_prefix});
    defer allocator.free(src_dir);
    cwd.createDirPath(io, src_dir) catch |err| {
        printErr(io, "error: could not create directory '{s}': {s}\n", .{ src_dir, @errorName(err) });
        std.process.exit(1);
    };

    // 写清单
    const manifest_content = try std.fmt.allocPrint(allocator,
        \\name = "{s}"
        \\version = "0.1.0"
        \\entry = "{s}"
        \\
    , .{ proj_name, DEFAULT_ENTRY });
    defer allocator.free(manifest_content);
    cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_content }) catch |err| {
        printErr(io, "error: could not write '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };

    // 写入口 src/Main.glue
    const main_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, DEFAULT_ENTRY });
    defer allocator.free(main_path);
    const main_content =
        \\fun main() {
        \\    println("Hello, Glue!")
        \\}
        \\
    ;
    cwd.writeFile(io, .{ .sub_path = main_path, .data = main_content }) catch |err| {
        printErr(io, "error: could not write '{s}': {s}\n", .{ main_path, @errorName(err) });
        std.process.exit(1);
    };

    var out_buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    w.interface.print("Created Glue project '{s}'\n  {s}\n  {s}\n", .{ proj_name, manifest_path, main_path }) catch {};
    w.flush() catch {};
}

// ============================================================
// glue run / glue debug
// ============================================================

/// 运行当前项目。diagnostic=true 走 DebugAllocator 诊断模式（glue debug）。
fn runProject(allocator: std.mem.Allocator, io: std.Io, diagnostic: bool) !void {
    const cwd = std.Io.Dir.cwd();

    const root = (try findProjectRoot(allocator, io)) orelse {
        printErr(io, "error: not a Glue project (no {s} found); run 'glue init' first\n", .{MANIFEST_NAME});
        std.process.exit(1);
    };
    defer allocator.free(root);

    // 读清单
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const manifest_src = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| {
        printErr(io, "error: could not read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest_src);
    const manifest = parseManifest(manifest_src);

    // 入口文件路径 = root + entry
    const entry_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, manifest.entry });
    defer allocator.free(entry_path);

    const source = cwd.readFileAlloc(io, entry_path, allocator, .unlimited) catch |err| {
        printErr(io, "error: could not read entry '{s}': {s}\n", .{ entry_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(source);

    if (diagnostic) {
        try runDiagnostic(allocator, io, source, entry_path);
    } else {
        try runNormal(allocator, io, source, entry_path);
    }
}

/// 普通运行（arena 快路径 + SlabPool）。出错以非零码退出。
fn runNormal(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var pool = slab_pool.SlabPool.init(allocator);
    defer pool.deinit();

    var ev = eval.Evaluator.initWithIo(arena_alloc, io);
    ev.value_allocator = pool.allocator();
    ev.global_env.value_allocator = ev.value_allocator;
    ev.use_lexical_addressing = true; // 任务#2:De Bruijn 局部变量数组快路径(自校验回退,绝不静默损坏)
    defer ev.deinit();

    const has_error = executeSource(arena_alloc, &ev, io, source, entry_path);

    var run_failed = has_error;
    if (!has_error) {
        run_failed = invokeMain(&ev, io, entry_path, false);
    }

    if (run_failed) {
        ev.deinit();
        arena.deinit();
        pool.deinit();
        std.process.exit(1);
    }
}

/// 诊断运行（glue debug）：全程 DebugAllocator + SlabPool(backing=dbg) 检测 double-free/泄漏，
/// trace=true 输出更详细的运行时错误位置链。结束报告 [GLUE_GPA] LEAK/clean。
fn runDiagnostic(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry_path: []const u8) !void {
    _ = allocator;
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const dbg_alloc = dbg.allocator();
    {
        var pool = slab_pool.SlabPool.init(dbg_alloc);
        defer pool.deinit();
        var ev = eval.Evaluator.initWithIo(dbg_alloc, io);
        ev.value_allocator = pool.allocator();
        ev.global_env.value_allocator = ev.value_allocator;
        ev.use_lexical_addressing = true; // 任务#2:开启(debug 路径同样)
        defer ev.deinit();
        const had_err = executeSource(dbg_alloc, &ev, io, source, entry_path);
        if (!had_err) {
            _ = invokeMain(&ev, io, entry_path, true);
        }
    }
    const leaked = dbg.deinit();
    if (leaked == .leak) {
        printErr(io, "[GLUE_GPA] LEAK detected\n", .{});
    } else {
        printErr(io, "[GLUE_GPA] clean (no leak / no double-free)\n", .{});
    }
}

/// 调用 main 入口，统一错误诊断。返回 true 表示运行失败。
/// trace=true 时（debug 模式）panic 额外打印位置链。
fn invokeMain(ev: *eval.Evaluator, io: std.Io, entry_path: []const u8, trace: bool) bool {
    _ = ev.callMain() catch |err| switch (err) {
        error.MissingMain => {
            printErr(io, "{s}: error: undefined entry point (no 'fun main')\n", .{entry_path});
            return true;
        },
        error.GluePanic => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            const msg = ev.panic_message orelse "unknown error";
            printRuntimeDiag(&stderr_writer.interface, entry_path, ev.panic_location, "runtime panic", msg);
            if (trace) {
                if (ev.panic_location) |l| {
                    stderr_writer.interface.print("  at {s}:{d}:{d}\n", .{ entry_path, l.line, l.column }) catch {};
                }
            }
            stderr_writer.flush() catch {};
            ev.panic_message = null;
            return true;
        },
        else => {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            printRuntimeDiag(&stderr_writer.interface, entry_path, ev.panic_location, "runtime error", runtimeErrorMessage(err, ev.panic_message));
            stderr_writer.flush() catch {};
            return true;
        },
    };
    return false;
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
        // 类型检查失败：错误已在 evalModule 内打印到 stderr，这里只需标记失败
        // （返回 true → 不调 callMain，避免 "undefined entry point" 误报）。
        error.TypeCheckFailed => return true,
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
