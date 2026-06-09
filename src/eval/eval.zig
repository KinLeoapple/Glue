//! Glue 语言核心求值器
//!
//! 执行 AST 并产生运行时值，支持：
//! - 基本类型值（整数、浮点、布尔、字符、字符串、null、单位值）
//! - 表达式求值（字面量、二元/一元运算、函数调用、Lambda、if/match 等）
//! - 语句执行（val/var 声明、赋值、return/throw/defer/break/continue/for/while/loop）
//! - 模式匹配（通配符、字面量、变量绑定、构造器、记录、或模式、守卫）
//! - 闭包和词法作用域
//! - Nullable 相关操作（??, ?., !, ?）
//!
//! 本文件是 eval 模块的核心，依赖同目录下的：
//! - value.zig — 运行时值表示
//! - env.zig — 变量环境
//! - pattern.zig — 模式匹配
//! - throw.zig — throw 运行时处理
//! - module_eval.zig — 模块求值

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const env = @import("env");
const pattern = @import("pattern");
const throw_mod = @import("throw_mod");
const module_eval = @import("module_eval");
const sema = @import("sema");

// ============================================================
// 便捷重导出
// ============================================================

pub const Value = value.Value;
pub const Range = value.Range;
pub const Environment = env.Environment;
pub const EvalError = value.EvalError;
pub const ControlFlow = value.ControlFlow;
pub const EvalResult = value.EvalResult;

// ============================================================
// 尾调用优化 (TCO)
// ============================================================

/// 尾调用信息 — 用于 trampoline 实现 TCO
///
/// 当函数在尾位置调用另一个函数时，不创建新的栈帧，
/// 而是设置 tail_call 信息，由 callFunction 的循环处理。
const TailCall = struct {
    closure: *value.Closure,
    args: []const Value,
};

/// 自定义错误类型构造器的上下文数据
const ErrorNewtypeCtx = struct {
    type_name: []const u8,
    default_prefix: []const u8,
};

/// ADT 构造器上下文数据
const AdtConstructorCtx = struct {
    type_name: []const u8,
    constructor_name: []const u8,
    field_names: []?[]const u8,
};

/// 记录类型构造器上下文数据
const RecordConstructorCtx = struct {
    field_names: [][]const u8,
};

/// Trait 声明信息
const TraitInfo = struct {
    name: []const u8,
    /// 方法名列表
    method_names: []const u8,
    /// 默认实现的方法（方法名 -> 闭包）
    default_methods: std.StringHashMap(*value.Closure),
};

/// Impl 方法注册项
const ImplMethodEntry = struct {
    trait_name: []const u8,
    method_name: []const u8,
    closure: *value.Closure,
};

/// 模块导出信息
const ModuleExportInfo = struct {
    /// 模块环境（包含所有声明）
    env: *Environment,
    /// pub 声明名称（以 \0 分隔的字符串）
    pub_names: []const u8,
};

// ============================================================
// 求值器
// ============================================================

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    global_env: Environment,
    io: ?std.Io = null,
    return_value: ?Value = null,
    throw_value: ?Value = null,
    /// Glue panic 消息 — 不可捕获，但允许 defer 执行
    panic_message: ?[]const u8 = null,
    closures: std.ArrayList(*value.Closure),
    /// TCO: 尾调用信息，用于 trampoline
    tail_call: ?TailCall = null,
    /// TCO: 当前是否在尾位置（用于检测尾调用）
    in_tail_position: bool = false,
    /// 自定义错误类型上下文列表
    error_newtype_contexts: std.ArrayList(*ErrorNewtypeCtx),
    /// ADT 构造器上下文列表
    adt_constructor_contexts: std.ArrayList(*AdtConstructorCtx),
    /// 记录类型构造器上下文列表
    record_constructor_contexts: std.ArrayList(*RecordConstructorCtx),
    /// Trait 声明注册表（trait_name -> TraitInfo）
    trait_registry: std.StringHashMap(TraitInfo),
    /// 所有已注册的 impl 方法
    impl_methods: std.ArrayList(ImplMethodEntry),
    /// 已加载模块的导出信息
    /// key: 模块路径, value: ModuleExportInfo
    module_exports: std.StringHashMap(ModuleExportInfo),
    /// 当前模块的源文件目录（用于解析相对模块路径）
    current_source_dir: ?[]const u8,
    /// 模块级 defer 栈 — 顶层 defer 语句注册到这里，模块结束时执行
    module_defer_stack: std.ArrayList(*const ast.Expr),
    /// 正在加载的模块集合（用于循环依赖检测）
    /// key: 模块名, value: void
    loading_modules: std.StringHashMap(void),
    /// 已加载完成的模块集合（避免重复加载）
    /// key: 模块名, value: void
    loaded_modules: std.StringHashMap(void),
    /// Hindley-Milner 类型推断器
    type_inferencer: sema.TypeInferencer,

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .closures = std.ArrayList(*value.Closure).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .io = io,
            .closures = std.ArrayList(*value.Closure).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        self.global_env.deinit();
        // 释放所有注册的闭包
        for (self.closures.items) |closure| {
            self.allocator.destroy(closure);
        }
        self.closures.deinit(self.allocator);
        // 释放所有错误类型上下文
        for (self.error_newtype_contexts.items) |ctx| {
            self.allocator.free(ctx.type_name);
            self.allocator.free(ctx.default_prefix);
            self.allocator.destroy(ctx);
        }
        self.error_newtype_contexts.deinit(self.allocator);
        // 释放所有 ADT 构造器上下文
        for (self.adt_constructor_contexts.items) |ctx| {
            self.allocator.free(ctx.type_name);
            self.allocator.free(ctx.constructor_name);
            for (ctx.field_names) |fn_opt| {
                if (fn_opt) |n| self.allocator.free(n);
            }
            self.allocator.free(ctx.field_names);
            self.allocator.destroy(ctx);
        }
        self.adt_constructor_contexts.deinit(self.allocator);
        // 释放所有记录类型构造器上下文
        for (self.record_constructor_contexts.items) |ctx| {
            for (ctx.field_names) |n| {
                self.allocator.free(n);
            }
            self.allocator.free(ctx.field_names);
            self.allocator.destroy(ctx);
        }
        self.record_constructor_contexts.deinit(self.allocator);
        // 释放 Trait 注册表
        {
            var iter = self.trait_registry.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.name);
                self.allocator.free(entry.value_ptr.method_names);
                var dm_iter = entry.value_ptr.default_methods.iterator();
                while (dm_iter.next()) |dm_entry| {
                    self.allocator.free(dm_entry.key_ptr.*);
                }
                entry.value_ptr.default_methods.deinit();
            }
            self.trait_registry.deinit();
        }
        // 释放 impl 方法注册表
        for (self.impl_methods.items) |entry| {
            self.allocator.free(entry.trait_name);
            self.allocator.free(entry.method_name);
        }
        self.impl_methods.deinit(self.allocator);
        // 释放模块导出表
        {
            var iter = self.module_exports.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.pub_names);
                // 注意：不释放 env，因为闭包可能引用它
            }
            self.module_exports.deinit();
        }
        // 释放 current_source_dir
        if (self.current_source_dir) |dir| {
            self.allocator.free(dir);
        }
        self.module_defer_stack.deinit(self.allocator);
        // 释放模块跟踪集合的 key
        {
            var iter = self.loading_modules.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.loading_modules.deinit();
        }
        {
            var iter = self.loaded_modules.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.loaded_modules.deinit();
        }
        // 释放类型推断器
        self.type_inferencer.deinit();
    }

    /// 触发 Glue panic — 不可捕获，但允许 defer 执行
    ///
    /// 文档要求：panic 不可捕获，但 defer 在 panic 时仍执行。
    /// 实现方式：设置 panic_message 并返回 error.GluePanic，
    /// evalBlock 捕获后执行 defer 栈，然后重新抛出。
    fn gluePanic(self: *Evaluator, message: []const u8) EvalResult!Value {
        self.panic_message = message;
        return error.GluePanic;
    }

    // ============================================================
    // 内建函数注册
    // ============================================================

    fn registerBuiltins(self: *Evaluator) void {

        // println
        self.global_env.define("println", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPrintln(args);
            }
        }.call } }, true) catch {};
        // print
        self.global_env.define("print", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPrint(args);
            }
        }.call } }, true) catch {};
        // eprintln
        self.global_env.define("eprintln", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEprintln(args);
            }
        }.call } }, true) catch {};
        // eprint
        self.global_env.define("eprint", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEprint(args);
            }
        }.call } }, true) catch {};
        // Panic 构造器
        self.global_env.define("Panic", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPanic(args);
            }
        }.call } }, true) catch {};
        // eq (结构相等)
        self.global_env.define("eq", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEq(args);
            }
        }.call } }, true) catch {};
        // string (类型转换)
        self.global_env.define("string", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinString(args);
            }
        }.call } }, true) catch {};
        // Error 构造器
        self.global_env.define("Error", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinError(args);
            }
        }.call } }, true) catch {};
        // Ok 构造器 — 创建 ThrowValue.ok
        self.global_env.define("Ok", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinOk(args);
            }
        }.call } }, true) catch {};
    }

    // ============================================================
    // 内建函数实现
    // ============================================================

    fn builtinPrintln(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            buf.append(self.allocator, '\n') catch {};
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        } else {
            std.debug.print("{s}\n", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinPrint(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        } else {
            std.debug.print("{s}", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinEprintln(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            buf.append(self.allocator, '\n') catch {};
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}", .{buf.items}) catch {};
            stderr_writer.flush() catch {};
        } else {
            std.debug.print("{s}\n", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinEprint(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}", .{buf.items}) catch {};
            stderr_writer.flush() catch {};
        } else {
            std.debug.print("{s}", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinPanic(self: *Evaluator, args: []const Value) EvalResult!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch {};
        const msg = try self.allocator.dupe(u8, buf.items);
        return self.gluePanic(msg);
    }

    fn builtinEq(self: *Evaluator, args: []const Value) EvalError!Value {
        _ = self;
        if (args.len != 2) return error.WrongArity;
        return Value{ .boolean = structuralEquals(args[0], args[1]) };
    }

    fn builtinString(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        return Value{ .string = buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    fn builtinError(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        const message = switch (args[0]) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        return throw_mod.makeErr(self.allocator, "Error", message);
    }

    /// Ok(value) — 创建 ThrowValue.ok
    fn builtinOk(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        return throw_mod.makeOk(self.allocator, args[0]);
    }

    // ============================================================
    // 模块求值
    // ============================================================

    pub fn evalModule(self: *Evaluator, module: ast.Module) !void {
        const module_name = module.name;

        // 循环依赖检测：如果模块正在加载中，说明存在循环依赖
        if (self.loading_modules.contains(module_name)) {
            return error.CircularDependency;
        }

        // 如果模块已加载完成，跳过重复加载
        if (self.loaded_modules.contains(module_name)) {
            return;
        }

        // 设置当前模块的源文件目录
        const saved_source_dir = self.current_source_dir;
        if (module.source_path) |sp| {
            // 提取目录部分
            if (std.mem.lastIndexOfScalar(u8, sp, std.fs.path.sep)) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
            } else if (std.mem.lastIndexOfScalar(u8, sp, '/')) |idx| {
                self.current_source_dir = try self.allocator.dupe(u8, sp[0..idx]);
            }
        }
        defer {
            if (saved_source_dir) |dir| {
                self.allocator.free(dir);
            }
            self.current_source_dir = saved_source_dir;
        }

        // 标记模块为"正在加载"
        const owned_name = try self.allocator.dupe(u8, module_name);
        try self.loading_modules.put(owned_name, {});
        defer {
            // 从 loading_modules 中移除
            if (self.loading_modules.fetchRemove(module_name)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        // 先检查后求值：运行 Hindley-Milner 类型推断
        self.type_inferencer.checkModule(&module) catch {
            // 类型推断错误不阻止求值，仅记录
            // 重置 panic_message 以避免干扰后续求值
            self.panic_message = null;
        };

        // 收集 pub 声明名称
        var pub_names = std.ArrayList(u8).empty;
        defer pub_names.deinit(self.allocator);

        for (module.declarations) |decl| {
            const decl_visibility = switch (decl) {
                .fun_decl => |f| f.visibility,
                .type_decl => |t| t.visibility,
                .trait_decl => |t| t.visibility,
                .pack_decl => |p| p.visibility,
                .impl_decl => |i| i.visibility,
                .use_decl => |u| u.visibility,
                .expr_decl => |ed| blk: {
                    if (ed.stmt) |s| {
                        break :blk switch (s.*) {
                            .val_decl => |vd| vd.visibility,
                            .var_decl => |vd| vd.visibility,
                            else => ast.Visibility.private,
                        };
                    }
                    break :blk ast.Visibility.private;
                },
            };
            const decl_name = switch (decl) {
                .fun_decl => |f| f.name,
                .type_decl => |t| t.name,
                .trait_decl => |t| t.name,
                .pack_decl => |p| p.name,
                .impl_decl => |i| i.trait_name,
                .use_decl => null,
                .expr_decl => |ed| blk: {
                    if (ed.stmt) |s| {
                        break :blk switch (s.*) {
                            .val_decl => |vd| vd.name,
                            .var_decl => |vd| vd.name,
                            else => null,
                        };
                    }
                    break :blk null;
                },
            };
            if (decl_visibility == .public) {
                if (decl_name) |name| {
                    if (pub_names.items.len > 0) {
                        try pub_names.append(self.allocator, 0);
                    }
                    try pub_names.appendSlice(self.allocator, name);
                }
            }
            try self.evalDecl(decl, &self.global_env);
        }

        // 存储模块导出信息
        const export_key = try self.allocator.dupe(u8, module_name);
        const owned_pub_names = try pub_names.toOwnedSlice(self.allocator);
        try self.module_exports.put(export_key, ModuleExportInfo{
            .env = &self.global_env,
            .pub_names = owned_pub_names,
        });

        // 执行模块级 defer（LIFO 顺序）
        self.runDefers(self.module_defer_stack.items, &self.global_env) catch {};
        self.module_defer_stack.clearRetainingCapacity();

        // 标记模块为"已加载完成"
        const loaded_name = try self.allocator.dupe(u8, module_name);
        try self.loaded_modules.put(loaded_name, {});
    }

    pub fn evalDecl(self: *Evaluator, decl: ast.Decl, environment: *Environment) !void {
        switch (decl) {
            .fun_decl => |f| {
                const closure = try self.allocator.create(value.Closure);
                closure.* = value.Closure{
                    .params = f.params,
                    .body = .{ .block = f.body },
                    .env = @ptrCast(environment),
                    .allocator = self.allocator,
                };
                try self.closures.append(self.allocator, closure);
                try environment.defineWithVisibility(f.name, Value{ .closure = closure }, false, f.visibility == .public);
            },
            .type_decl => |td| {
                switch (td.def) {
                    .error_newtype => |en| {
                        // 注册自定义错误类型构造器
                        // type FileError = Error("file error")
                        // FileError("msg") 创建 ThrowValue.err{ type_name = "FileError", message = "file error: msg" }
                        const ctx_data = try self.allocator.create(ErrorNewtypeCtx);
                        ctx_data.* = .{
                            .type_name = try self.allocator.dupe(u8, en.name),
                            .default_prefix = try self.allocator.dupe(u8, en.message),
                        };
                        try self.error_newtype_contexts.append(self.allocator, ctx_data);
                        try environment.defineWithVisibility(td.name, Value{ .builtin = value.Builtin{
                            .fn_ptr = struct {
                                fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                    const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                                    if (args.len != 1) return error.WrongArity;
                                    const message = switch (args[0]) {
                                        .string => |s| s,
                                        else => return error.TypeMismatch,
                                    };
                                    // 从 user_ctx 获取 ErrorNewtypeCtx
                                    const data: *ErrorNewtypeCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                    // 组合默认前缀和消息：prefix + ": " + message
                                    var full_msg = std.ArrayList(u8).empty;
                                    defer full_msg.deinit(ev.allocator);
                                    try full_msg.appendSlice(ev.allocator, data.default_prefix);
                                    try full_msg.appendSlice(ev.allocator, ": ");
                                    try full_msg.appendSlice(ev.allocator, message);
                                    const tv = try ev.allocator.create(value.ThrowValue);
                                    tv.* = value.ThrowValue{ .err = value.ErrorValue{
                                        .type_name = try ev.allocator.dupe(u8, data.type_name),
                                        .message = try full_msg.toOwnedSlice(ev.allocator),
                                        .is_error_subtype = true, // 文档 2.4.3: FileError <: Error
                                    } };
                                    return Value{ .throw_val = tv };
                                }
                            }.call,
                            .user_ctx = ctx_data,
                        } }, true, td.visibility == .public);
                    },
                    .newtype => |nt| {
                        // 注册 newtype 构造器
                        // type UserId = UserId(i32)
                        // UserId(42) 创建 NewtypeValue{ .type_name = "UserId", .inner = 42 }
                        //
                        // 抽象类型（文档 2.5.4）：
                        // pub type Handle = Handle(i32) — 类型名公开，构造器私有
                        // newtype 的构造器名与类型名相同，构造器始终私有
                        const type_name = try self.allocator.dupe(u8, nt.name);
                        const ctx = try self.allocator.create(ErrorNewtypeCtx);
                        ctx.* = .{
                            .type_name = type_name,
                            .default_prefix = "", // newtype 不使用 default_prefix
                        };
                        try self.error_newtype_contexts.append(self.allocator, ctx);
                        // newtype 构造器始终私有（即使类型是 pub）— 这是抽象类型的核心
                        // pub type Handle = Handle(i32) → Handle 类型名公开，Handle() 构造器私有
                        try environment.defineWithVisibility(td.name, Value{ .builtin = value.Builtin{
                            .fn_ptr = struct {
                                fn call(ctx_ptr: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                    const ev: *Evaluator = @ptrCast(@alignCast(ctx_ptr));
                                    if (args.len != 1) return error.WrongArity;
                                    const data: *ErrorNewtypeCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                    const nv = try ev.allocator.create(value.NewtypeValue);
                                    nv.* = value.NewtypeValue{
                                        .type_name = data.type_name,
                                        .inner = args[0],
                                    };
                                    return Value{ .newtype = nv };
                                }
                            }.call,
                            .user_ctx = ctx,
                        } }, true, false); // newtype 构造器始终私有
                    },
                    .alias => {
                        // Type Alias — Phase 1 无类型检查器，空操作即可
                        // 类型别名在运行时无影响
                    },
                    .adt => |adt_def| {
                        // 注册每个 ADT 构造器为可调用值
                        // 无参构造器（如 Lt, Nil）直接注册为 AdtValue
                        // 有参构造器（如 Circle(f64)）注册为 builtin 函数
                        const is_pub = td.visibility == .public;
                        for (adt_def.constructors) |con| {
                            if (con.fields.len == 0) {
                                // 无参构造器：直接注册为 AdtValue
                                const av = try self.allocator.create(value.AdtValue);
                                const empty_fields = try self.allocator.alloc(value.AdtField, 0);
                                av.* = value.AdtValue{
                                    .type_name = try self.allocator.dupe(u8, td.name),
                                    .constructor = try self.allocator.dupe(u8, con.name),
                                    .fields = empty_fields,
                                };
                                try environment.defineWithVisibility(con.name, Value{ .adt = av }, true, is_pub);
                            } else {
                                // 有参构造器：注册为 builtin 函数
                                const ctx = try self.allocator.create(AdtConstructorCtx);
                                ctx.* = .{
                                    .type_name = try self.allocator.dupe(u8, td.name),
                                    .constructor_name = try self.allocator.dupe(u8, con.name),
                                    .field_names = try self.allocator.alloc(?[]const u8, con.fields.len),
                                };
                                for (con.fields, 0..) |field, i| {
                                    ctx.field_names[i] = if (field.name) |n| try self.allocator.dupe(u8, n) else null;
                                }
                                try self.adt_constructor_contexts.append(self.allocator, ctx);
                                try environment.defineWithVisibility(con.name, Value{ .builtin = value.Builtin{
                                    .fn_ptr = struct {
                                        fn call(ctx_ptr: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                            const ev: *Evaluator = @ptrCast(@alignCast(ctx_ptr));
                                            const data: *AdtConstructorCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                            if (args.len != data.field_names.len) return error.WrongArity;

                                            const av = try ev.allocator.create(value.AdtValue);
                                            const fields = try ev.allocator.alloc(value.AdtField, args.len);
                                            for (args, 0..) |arg, i| {
                                                fields[i] = value.AdtField{
                                                    .name = if (data.field_names[i]) |n| try ev.allocator.dupe(u8, n) else null,
                                                    .value = arg,
                                                };
                                            }
                                            av.* = value.AdtValue{
                                                .type_name = try ev.allocator.dupe(u8, data.type_name),
                                                .constructor = try ev.allocator.dupe(u8, data.constructor_name),
                                                .fields = fields,
                                            };
                                            return Value{ .adt = av };
                                        }
                                    }.call,
                                    .user_ctx = ctx,
                                } }, true, is_pub);
                            }
                        }
                    },
                    .record => |rec_def| {
                        // 注册记录类型构造器
                        // type User = (name: String, age: i32)
                        // User("Alice", 30) 创建记录值 {name: "Alice", age: 30}
                        const ctx = try self.allocator.create(RecordConstructorCtx);
                        ctx.* = .{
                            .field_names = try self.allocator.alloc([]const u8, rec_def.fields.len),
                        };
                        for (rec_def.fields, 0..) |field, i| {
                            ctx.field_names[i] = try self.allocator.dupe(u8, field.name);
                        }
                        try self.record_constructor_contexts.append(self.allocator, ctx);
                        try environment.defineWithVisibility(td.name, Value{ .builtin = value.Builtin{
                            .fn_ptr = struct {
                                fn call(ctx_ptr: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                    const ev: *Evaluator = @ptrCast(@alignCast(ctx_ptr));
                                    const data: *RecordConstructorCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                    if (args.len != data.field_names.len) return error.WrongArity;

                                    var map = std.StringHashMap(Value).init(ev.allocator);
                                    for (args, 0..) |arg, i| {
                                        const key = try ev.allocator.dupe(u8, data.field_names[i]);
                                        try map.put(key, arg);
                                    }
                                    return Value{ .record = map };
                                }
                            }.call,
                            .user_ctx = ctx,
                        } }, true, td.visibility == .public);
                    },
                }
            },
            .trait_decl => |td| {
                // 注册 Trait 声明
                // 存储方法名列表和默认实现
                var method_names = std.ArrayList(u8).empty;
                defer method_names.deinit(self.allocator);
                var default_methods = std.StringHashMap(*value.Closure).init(self.allocator);

                for (td.methods) |method| {
                    // 方法名以 \0 分隔存储
                    if (method_names.items.len > 0) {
                        try method_names.append(self.allocator, 0);
                    }
                    try method_names.appendSlice(self.allocator, method.name);

                    // 如果方法有默认实现，创建闭包
                    if (method.body) |body| {
                        const closure = try self.allocator.create(value.Closure);
                        closure.* = value.Closure{
                            .params = method.params,
                            .body = .{ .block = body },
                            .env = @ptrCast(environment),
                            .allocator = self.allocator,
                        };
                        try self.closures.append(self.allocator, closure);
                        const method_name = try self.allocator.dupe(u8, method.name);
                        try default_methods.put(method_name, closure);
                    }
                }

                const owned_name = try self.allocator.dupe(u8, td.name);
                const owned_method_names = try method_names.toOwnedSlice(self.allocator);
                const trait_key = try self.allocator.dupe(u8, td.name);
                try self.trait_registry.put(trait_key, TraitInfo{
                    .name = owned_name,
                    .method_names = owned_method_names,
                    .default_methods = default_methods,
                });
            },
            .impl_decl => |id| {
                // 注册 Impl 声明
                // 为每个有方法体的方法创建闭包并注册到 impl_methods
                for (id.methods) |method| {
                    if (method.body) |body| {
                        const closure = try self.allocator.create(value.Closure);
                        closure.* = value.Closure{
                            .params = method.params,
                            .body = .{ .block = body },
                            .env = @ptrCast(environment),
                            .allocator = self.allocator,
                        };
                        try self.closures.append(self.allocator, closure);

                        try self.impl_methods.append(self.allocator, ImplMethodEntry{
                            .trait_name = try self.allocator.dupe(u8, id.trait_name),
                            .method_name = try self.allocator.dupe(u8, method.name),
                            .closure = closure,
                        });

                        // 同时将方法注册为环境中的函数（支持直接调用）
                        // 方法可见性由 MethodDecl.visibility 决定
                        try environment.defineWithVisibility(method.name, Value{ .closure = closure }, true, method.visibility == .public);
                    }
                }
            },
            .use_decl => |ud| {
                // 模块循环依赖检测
                if (ud.module_path.len > 0) {
                    const target_module = ud.module_path[0];
                    if (self.loading_modules.contains(target_module)) {
                        return error.CircularDependency;
                    }
                }

                // 构建模块路径键
                // (用于将来模块路径规范化，当前直接使用 module_path[0])

                // 检查模块是否已加载
                if (!self.loaded_modules.contains(ud.module_path[0])) {
                    // 尝试从文件系统加载模块
                    self.loadModuleFromFile(ud.module_path) catch |err| switch (err) {
                        error.FileNotFound => {
                            // 模块文件不存在，跳过（可能是内建模块或尚未实现）
                        },
                        else => return err,
                    };
                }

                // 从模块导出表中导入
                if (self.module_exports.getPtr(ud.module_path[0])) |export_info| {
                    const is_reexport = ud.visibility == .public;
                    if (ud.items) |items| {
                        // 选择性导入：use Module.{Item1, Item2}
                        for (items) |item| {
                            // 检查是否为 pub 声明（通过 Variable.is_public 字段）
                            if (export_info.env.get(item.name)) |val| {
                                if (!val.is_public) continue; // 跳过私有声明
                                const import_name = item.alias orelse item.name;
                                try environment.defineWithVisibility(import_name, val.value, false, is_reexport);
                            }
                        }
                    } else {
                        // 导入整个模块的所有 pub 声明：use Module
                        var iter = export_info.env.values.iterator();
                        while (iter.next()) |entry| {
                            if (entry.value_ptr.is_public) {
                                try environment.defineWithVisibility(entry.key_ptr.*, entry.value_ptr.value, false, is_reexport);
                            }
                        }
                    }
                }
            },
            .pack_decl => {
                // Phase 1: 简单处理
            },
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    switch (s.*) {
                        .defer_stmt => |def| {
                            // 顶层 defer 注册到模块级 defer 栈
                            try self.module_defer_stack.append(self.allocator, def.expr);
                        },
                        else => {
                            var defer_stack = std.ArrayList(*const ast.Expr).empty;
                            defer defer_stack.deinit(self.allocator);
                            _ = self.evalStmt(s, environment, &defer_stack) catch |err| switch (err) {
                                // 顶层 ? 传播：null 或 throw 导致提前退出当前语句，
                                // 但不应中断整个模块求值
                                error.ReturnValue, error.ThrowValue => {
                                    self.runDefers(defer_stack.items, environment) catch {};
                                },
                                error.GluePanic => {
                                    self.runDefers(defer_stack.items, environment) catch {};
                                    return error.GluePanic;
                                },
                                else => return err,
                            };
                            // 正常完成时也执行 defer
                            self.runDefers(defer_stack.items, environment) catch {};
                        },
                    }
                } else {
                    _ = self.evalExpr(ed.expr, environment) catch |err| switch (err) {
                        error.ReturnValue, error.ThrowValue => {},
                        error.GluePanic => return error.GluePanic,
                        else => return err,
                    };
                }
            },
        }
    }

    // ============================================================
    // 表达式求值
    // ============================================================

    pub fn evalExpr(self: *Evaluator, expr: *const ast.Expr, environment: *Environment) EvalResult!Value {
        // 只有以下表达式类型可以传递尾位置：
        // - .call: 尾位置的函数调用可以 TCO
        // - .if_expr: 分支在尾位置时保持
        // - .block: 尾表达式在尾位置时保持
        // - .match: 分支在尾位置时保持
        // 其他表达式类型（二元运算、一元运算等）的子表达式不在尾位置
        const preserves_tail = switch (expr.*) {
            .call, .if_expr, .block, .match => true,
            else => false,
        };
        const saved_tail = self.in_tail_position;
        if (!preserves_tail) {
            self.in_tail_position = false;
        }
        defer {
            self.in_tail_position = saved_tail;
        }

        return switch (expr.*) {
            .int_literal => |lit| self.evalIntLiteral(lit),
            .float_literal => |lit| self.evalFloatLiteral(lit),
            .bool_literal => |lit| Value{ .boolean = lit.value },
            .char_literal => |lit| Value{ .char_val = lit.value },
            .string_literal => |lit| Value{ .string = try self.allocator.dupe(u8, lit.value) },
            .string_interpolation => |interp| self.evalStringInterpolation(interp, environment),
            .null_literal => Value.null_val,
            .unit_literal => Value.unit,
            .identifier => |id| self.evalIdentifier(id, environment),
            .assignment_expr => |ae| self.evalAssignmentExpr(ae, environment),
            .binary => |bin| self.evalBinary(bin, environment),
            .unary => |un| self.evalUnary(un, environment),
            .call => |c| self.evalCall(c, environment),
            .method_call => |mc| self.evalMethodCall(mc, environment),
            .field_access => |fa| self.evalFieldAccess(fa, environment),
            .safe_access => |sa| self.evalSafeAccess(sa, environment),
            .safe_method_call => |smc| self.evalSafeMethodCall(smc, environment),
            .non_null_assert => |nna| self.evalNonNullAssert(nna, environment),
            .propagate => |prop| self.evalPropagate(prop, environment),
            .index => |idx| self.evalIndex(idx, environment),
            .array_literal => |al| self.evalArrayLiteral(al, environment),
            .record_literal => |rl| self.evalRecordLiteral(rl, environment),
            .lambda => |lam| self.evalLambda(lam, environment),
            .if_expr => |ie| return self.evalIfExpr(ie, environment),
            .block => |blk| return self.evalBlock(blk, environment),
            .match => |m| self.evalMatch(m, environment),
            .type_cast => |tc| self.evalTypeCast(tc, environment),
            .spawn => error.UnsupportedOperation,
            .lazy => error.UnsupportedOperation,
            .select => error.UnsupportedOperation,
            .monad_comprehension => error.UnsupportedOperation,
            .inline_trait_value => error.UnsupportedOperation,
        };
    }

    fn evalIntLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        // 解析整数值
        const int_val = parseInt(i128, raw) catch
            return self.gluePanic("integer overflow in literal");

        // 如果有类型后缀，检查范围
        if (suffix) |s| {
            return self.castInteger(int_val, s);
        }

        // 默认 i32
        return self.castInteger(int_val, "i32");
    }

    fn evalFloatLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) EvalResult!Value {
        _ = self;
        const raw = lit.raw;
        const suffix = lit.suffix;

        const float_val = parseFloat(f64, raw) catch
            return error.TypeMismatch;

        if (suffix) |s| {
            if (std.mem.eql(u8, s, "f32")) {
                const f32_val: f32 = @floatCast(float_val);
                return Value{ .float = @floatCast(f32_val) };
            }
        }

        return Value{ .float = float_val };
    }

    fn evalStringInterpolation(self: *Evaluator, interp: @TypeOf(@as(ast.Expr, undefined).string_interpolation), environment: *Environment) EvalResult!Value {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        for (interp.parts) |part| {
            switch (part) {
                .literal => |text| {
                    try result.appendSlice(self.allocator, text);
                },
                .expression => |expr| {
                    const val = try self.evalExpr(expr, environment);
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.allocator);
                    try val.format(&buf, self.allocator);
                    try result.appendSlice(self.allocator, buf.items);
                },
            }
        }

        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    fn evalIdentifier(self: *Evaluator, id: @TypeOf(@as(ast.Expr, undefined).identifier), environment: *Environment) EvalResult!Value {
        if (environment.get(id.name)) |v| {
            return v.value;
        }
        // 构建包含变量名的错误消息（需要分配以超过 panic_message 的生命周期）
        var buf = std.ArrayList(u8).empty;
        buf.appendSlice(self.allocator, "undefined variable: ") catch return error.UndefinedVariable;
        buf.appendSlice(self.allocator, id.name) catch return error.UndefinedVariable;
        const msg = buf.toOwnedSlice(self.allocator) catch return error.UndefinedVariable;
        self.panic_message = msg;
        return error.GluePanic;
    }

    fn evalAssignmentExpr(self: *Evaluator, ae: @TypeOf(@as(ast.Expr, undefined).assignment_expr), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(ae.value, environment);
        switch (ae.target.*) {
            .identifier => |id| {
                try environment.set(id.name, val);
            },
            else => return error.TypeMismatch,
        }
        return val;
    }

    // ============================================================
    // 二元运算
    // ============================================================

    fn evalBinary(self: *Evaluator, bin: @TypeOf(@as(ast.Expr, undefined).binary), environment: *Environment) EvalResult!Value {
        // 短路运算符
        switch (bin.op) {
            .and_op => {
                const left = try self.evalExpr(bin.left, environment);
                if (!try left.asBoolean()) return Value{ .boolean = false };
                const right = try self.evalExpr(bin.right, environment);
                return Value{ .boolean = try right.asBoolean() };
            },
            .or_op => {
                const left = try self.evalExpr(bin.left, environment);
                if (try left.asBoolean()) return Value{ .boolean = true };
                const right = try self.evalExpr(bin.right, environment);
                return Value{ .boolean = try right.asBoolean() };
            },
            .elvis => {
                const left = try self.evalExpr(bin.left, environment);
                if (!left.isNull()) return left;
                return try self.evalExpr(bin.right, environment);
            },
            else => {},
        }

        const left = try self.evalExpr(bin.left, environment);
        const right = try self.evalExpr(bin.right, environment);

        switch (bin.op) {
            .add => return self.evalAdd(left, right),
            .sub => return self.evalSub(left, right),
            .mul => return self.evalMul(left, right),
            .div => return self.evalDiv(left, right, bin.location),
            .mod => return self.evalMod(left, right, bin.location),
            .eq => return Value{ .boolean = left.equals(right) },
            .not_eq => return Value{ .boolean = !left.equals(right) },
            .lt => return self.evalLt(left, right),
            .gt => return self.evalGt(left, right),
            .lt_eq => return self.evalLtEq(left, right),
            .gt_eq => return self.evalGtEq(left, right),
            .concat => return self.evalConcat(left, right),
            .range => {
                const left_int = try left.asInteger();
                const right_int = try right.asInteger();
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = false } };
            },
            .range_inclusive => {
                const left_int = try left.asInteger();
                const right_int = try right.asInteger();
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = true } };
            },
            else => unreachable,
        }
    }

    fn evalAdd(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result = @addWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return self.gluePanic("integer overflow");
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float + right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) + right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float + @as(f64, @floatFromInt(right.integer)) };
        }
        if (left == .string and right == .string) {
            var result = std.ArrayList(u8).empty;
            try result.appendSlice(self.allocator, left.string);
            try result.appendSlice(self.allocator, right.string);
            return Value{ .string = try result.toOwnedSlice(self.allocator) };
        }
        return error.TypeMismatch;
    }

    fn evalSub(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result = @subWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return self.gluePanic("integer overflow");
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float - right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) - right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float - @as(f64, @floatFromInt(right.integer)) };
        }
        return error.TypeMismatch;
    }

    fn evalMul(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result = @mulWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return self.gluePanic("integer overflow");
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float * right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) * right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float * @as(f64, @floatFromInt(right.integer)) };
        }
        return error.TypeMismatch;
    }

    fn evalDiv(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer == 0) return self.gluePanic("division by zero");
            // 检查 i128 最小值 / -1 溢出
            if (left.integer == std.math.minInt(i128) and right.integer == -1) {
                return self.gluePanic("integer overflow");
            }
            return Value{ .integer = @divTrunc(left.integer, right.integer) };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return self.gluePanic("division by zero");
            const result = left.float / right.float;
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return self.gluePanic("division by zero");
            }
            return Value{ .float = result };
        }
        if (left == .integer and right == .float) {
            if (right.float == 0.0) return self.gluePanic("division by zero");
            const result = @as(f64, @floatFromInt(left.integer)) / right.float;
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return self.gluePanic("division by zero");
            }
            return Value{ .float = result };
        }
        if (left == .float and right == .integer) {
            if (right.integer == 0) return self.gluePanic("division by zero");
            const result = left.float / @as(f64, @floatFromInt(right.integer));
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return self.gluePanic("division by zero");
            }
            return Value{ .float = result };
        }
        return error.TypeMismatch;
    }

    fn evalMod(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer == 0) return self.gluePanic("division by zero");
            return Value{ .integer = @mod(left.integer, right.integer) };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return self.gluePanic("division by zero");
            return Value{ .float = @mod(left.float, right.float) };
        }
        return error.TypeMismatch;
    }

    fn evalLt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer < right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float < right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) < right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float < @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val < right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .lt };
        return error.TypeMismatch;
    }

    fn evalGt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer > right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float > right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) > right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float > @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val > right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .gt };
        return error.TypeMismatch;
    }

    fn evalLtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer <= right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float <= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) <= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float <= @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val <= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .gt };
        return error.TypeMismatch;
    }

    fn evalGtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer >= right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float >= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) >= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float >= @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val >= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .lt };
        return error.TypeMismatch;
    }

    fn evalConcat(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        const left_str = switch (left) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        const right_str = switch (right) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(self.allocator, left_str);
        try result.appendSlice(self.allocator, right_str);
        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    // ============================================================
    // 一元运算
    // ============================================================

    fn evalUnary(self: *Evaluator, un: @TypeOf(@as(ast.Expr, undefined).unary), environment: *Environment) EvalResult!Value {
        const operand = try self.evalExpr(un.operand, environment);
        return switch (un.op) {
            .not => switch (operand) {
                .boolean => |b| Value{ .boolean = !b },
                else => error.TypeMismatch,
            },
            .neg => switch (operand) {
                .integer => |i| {
                    const result = @subWithOverflow(@as(i128, 0), i);
                    if (result[1] != 0) return self.gluePanic("integer overflow");
                    return Value{ .integer = result[0] };
                },
                .float => |f| Value{ .float = -f },
                else => error.TypeMismatch,
            },
        };
    }

    // ============================================================
    // 函数调用
    // ============================================================

    fn evalCall(self: *Evaluator, call: @TypeOf(@as(ast.Expr, undefined).call), environment: *Environment) EvalResult!Value {
        // 先检查是否是类型转换调用
        if (call.callee.* == .identifier) {
            const name = call.callee.identifier.name;
            if (isBuiltinType(name) and call.arguments.len == 1) {
                const arg = try self.evalExpr(call.arguments[0], environment);
                return self.castValue(arg, name);
            }
        }

        const callee = try self.evalExpr(call.callee, environment);

        // 求值参数
        var args = std.ArrayList(Value).empty;
        for (call.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存（如数组切片）
        defer args.deinit(self.allocator);

        // TCO: 如果在尾位置且被调用者是闭包，使用尾调用优化
        if (self.in_tail_position and callee == .closure) {
            const owned_args = try self.allocator.dupe(Value, args.items);
            self.tail_call = TailCall{
                .closure = callee.closure,
                .args = owned_args,
            };
            return error.TailCall;
        }

        return self.callFunction(callee, args.items, environment);
    }

    fn callFunction(self: *Evaluator, callee: Value, args: []const Value, environment: ?*Environment) EvalResult!Value {
        _ = environment;

        switch (callee) {
            .closure => |initial_closure| {
                if (args.len != initial_closure.params.len) {
                    return error.WrongArity;
                }

                // Trampoline 循环：尾调用不创建新栈帧，而是循环执行
                var current_closure = initial_closure;
                var current_args = args;
                // 跟踪需要释放的 args（由 evalCall 中 toOwnedSlice 转移所有权）
                var args_owned: ?[]const Value = null;
                defer {
                    if (args_owned) |owned| self.allocator.free(owned);
                }

                while (true) {
                    // 从 *anyopaque 恢复 *Environment
                    const closure_env: *Environment = @ptrCast(@alignCast(current_closure.env));
                    const call_env = try closure_env.createChild();

                    for (current_closure.params, 0..) |param, i| {
                        try call_env.define(param.name, current_args[i], param.is_var);
                    }

                    // 清除尾调用标记
                    self.tail_call = null;

                    // 执行闭包体
                    const result = switch (current_closure.body) {
                        .block => |body| self.evalExpr(body, call_env),
                        .expression => |expr| self.evalExpr(expr, call_env),
                    };

                    const final_result = result catch |err| switch (err) {
                        error.ReturnValue => {
                            if (self.return_value) |val| {
                                self.return_value = null;
                                return val;
                            }
                            return Value.unit;
                        },
                        error.TailCall => {
                            // TCO: 检测到尾调用，循环执行下一次调用
                            const tc = self.tail_call.?;
                            self.tail_call = null;
                            // 释放上一次的 args 副本
                            if (args_owned) |owned| {
                                self.allocator.free(owned);
                                args_owned = null;
                            }
                            current_closure = tc.closure;
                            current_args = tc.args;
                            // tc.args 是 evalCall 中 toOwnedSlice 转移的，需要在此释放
                            args_owned = tc.args;
                            continue;
                        },
                        error.ThrowValue => {
                            // throw 语句产生的 ThrowValue.err 作为函数返回值
                            // 函数返回 Throw<T, E> 时，throw 等价于 return Error(...)
                            if (self.throw_value) |tv| {
                                self.throw_value = null;
                                return tv;
                            }
                            return error.ThrowValue;
                        },
                        else => return err,
                    };

                    return final_result;
                }
            },
            .builtin => |b| {
                const result = b.fn_ptr(@ptrCast(self), b.user_ctx, args) catch |err| {
                    // anyerror 不能直接转换为 EvalResult，只传播已知的错误
                    switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.TypeMismatch => return error.TypeMismatch,
                        error.UndefinedVariable => return error.UndefinedVariable,
                        error.ImmutableAssignment => return error.ImmutableAssignment,
                        error.NotCallable => return error.NotCallable,
                        error.WrongArity => return error.WrongArity,
                        error.IndexOutOfBounds => return error.IndexOutOfBounds,
                        error.UnsupportedOperation => return error.UnsupportedOperation,
                        error.GluePanic => return error.GluePanic,
                        error.FileNotFound => return error.FileNotFound,
                        else => return error.UnsupportedOperation,
                    }
                };
                return result;
            },
            else => return error.NotCallable,
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: @TypeOf(@as(ast.Expr, undefined).method_call), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(mc.object, environment);

        // 求值参数
        var args = std.ArrayList(Value).empty;
        for (mc.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存
        defer args.deinit(self.allocator);

        return self.callMethod(object, mc.method, args.items, environment);
    }

    fn callMethod(self: *Evaluator, object: Value, method: []const u8, args: []const Value, environment: ?*Environment) EvalResult!Value {
        // 内建方法
        if (std.mem.eql(u8, method, "len")) {
            return switch (object) {
                .string => |s| Value{ .integer = @as(i128, @intCast(s.len)) },
                .array => |arr| Value{ .integer = @as(i128, @intCast(arr.len)) },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "char_count")) {
            return switch (object) {
                .string => |s| {
                    const view = std.unicode.Utf8View.init(s) catch {
                        return Value{ .integer = @as(i128, @intCast(s.len)) };
                    };
                    var count: i128 = 0;
                    var iter = view.iterator();
                    while (iter.nextCodepoint() != null) {
                        count += 1;
                    }
                    return Value{ .integer = count };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "toString")) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);
            try object.format(&buf, self.allocator);
            return Value{ .string = try buf.toOwnedSlice(self.allocator) };
        }

        // 记录方法 — 在记录中查找方法字段
        if (object == .record) {
            if (object.record.get(method)) |val| {
                return self.callFunction(val, args, environment);
            }
        }

        // Impl 方法分派 — 搜索已注册的 impl 方法
        for (self.impl_methods.items) |entry| {
            if (std.mem.eql(u8, entry.method_name, method)) {
                // 将 object 作为第一个参数传递
                var full_args = std.ArrayList(Value).empty;
                try full_args.append(self.allocator, object);
                for (args) |arg| {
                    try full_args.append(self.allocator, arg);
                }
                defer full_args.deinit(self.allocator);
                return self.callFunction(Value{ .closure = entry.closure }, full_args.items, environment);
            }
        }

        return error.UndefinedVariable;
    }

    fn evalFieldAccess(self: *Evaluator, fa: @TypeOf(@as(ast.Expr, undefined).field_access), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(fa.object, environment);
        return self.accessField(object, fa.field);
    }

    fn accessField(self: *Evaluator, object: Value, field: []const u8) EvalResult!Value {
        switch (object) {
            .record => |map| {
                if (map.get(field)) |val| {
                    return val;
                }
                return error.UndefinedVariable;
            },
            .adt => |av| {
                // ADT 命名字段访问：circle.radius
                for (av.fields) |f| {
                    if (f.name) |n| {
                        if (std.mem.eql(u8, n, field)) {
                            return f.value;
                        }
                    }
                }
                return error.UndefinedVariable;
            },
            .error_val => |e| {
                // 文档 2.4.1: Error 有 message 字段
                // val e = Error("not found")
                // e.message    // "not found"
                if (std.mem.eql(u8, field, "message")) {
                    return Value{ .string = try self.allocator.dupe(u8, e.message) };
                }
                return error.UndefinedVariable;
            },
            .throw_val => |tv| {
                // 文档 2.4.7: Error(e) => println("error: " + e.message)
                // throw_val 的 .message 访问其内部错误消息
                switch (tv.*) {
                    .err => |e| {
                        if (std.mem.eql(u8, field, "message")) {
                            return Value{ .string = try self.allocator.dupe(u8, e.message) };
                        }
                    },
                    .ok => {},
                }
                return error.UndefinedVariable;
            },
            else => return error.TypeMismatch,
        }
    }

    fn evalSafeAccess(self: *Evaluator, sa: @TypeOf(@as(ast.Expr, undefined).safe_access), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(sa.object, environment);
        if (object.isNull()) return Value.null_val;
        return self.accessField(object, sa.field);
    }

    fn evalSafeMethodCall(self: *Evaluator, smc: @TypeOf(@as(ast.Expr, undefined).safe_method_call), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(smc.object, environment);
        if (object.isNull()) return Value.null_val;

        var args = std.ArrayList(Value).empty;
        for (smc.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存
        defer args.deinit(self.allocator);

        return self.callMethod(object, smc.method, args.items, environment);
    }

    fn evalNonNullAssert(self: *Evaluator, nna: @TypeOf(@as(ast.Expr, undefined).non_null_assert), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(nna.expr, environment);
        if (val.isNull()) return self.gluePanic("non-null assertion failed: value is null");
        return val;
    }

    fn evalPropagate(self: *Evaluator, prop: @TypeOf(@as(ast.Expr, undefined).propagate), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(prop.expr, environment);
        if (val.isNull()) {
            // ? 作用于 T? 时，null 提前返回 null
            self.return_value = Value.null_val;
            return error.ReturnValue;
        }
        if (val == .throw_val) {
            // ? 作用于 Throw<T, E> 时：
            // - 如果是 Ok(v)，解包返回 v
            // - 如果是 Error(e)，提前传播 throw
            switch (val.throw_val.*) {
                .ok => |v| return v.*,
                .err => {
                    self.throw_value = val;
                    return error.ThrowValue;
                },
            }
        }
        return val;
    }

    fn evalIndex(self: *Evaluator, idx: @TypeOf(@as(ast.Expr, undefined).index), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(idx.object, environment);
        const index_val = try self.evalExpr(idx.index, environment);

        switch (object) {
            .array => |arr| {
                const i = try index_val.asInteger();
                if (i < 0 or i >= @as(i128, @intCast(arr.len))) {
                    return error.IndexOutOfBounds;
                }
                return arr[@as(usize, @intCast(i))];
            },
            .string => |s| {
                const i = try index_val.asInteger();
                if (i < 0) return error.IndexOutOfBounds;
                // 文档 §2.2: 索引为 O(n) 操作，按字符位置索引，返回 Unicode 标量值
                const view = std.unicode.Utf8View.init(s) catch return error.IndexOutOfBounds;
                var iter = view.iterator();
                var char_idx: i128 = 0;
                while (iter.nextCodepoint()) |cp| {
                    if (char_idx == i) {
                        return Value{ .char_val = @as(u21, @intCast(cp)) };
                    }
                    char_idx += 1;
                }
                return error.IndexOutOfBounds;
            },
            else => return error.TypeMismatch,
        }
    }

    fn evalArrayLiteral(self: *Evaluator, al: @TypeOf(@as(ast.Expr, undefined).array_literal), environment: *Environment) EvalResult!Value {
        var arr = try self.allocator.alloc(Value, al.elements.len);
        errdefer {
            for (arr) |*a| a.deinit(self.allocator);
            self.allocator.free(arr);
        }
        for (al.elements, 0..) |elem, i| {
            arr[i] = try self.evalExpr(elem, environment);
        }
        return Value{ .array = arr };
    }

    fn evalRecordLiteral(self: *Evaluator, rl: @TypeOf(@as(ast.Expr, undefined).record_literal), environment: *Environment) EvalResult!Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();

        for (rl.fields) |field| {
            const key = try self.allocator.dupe(u8, field.name);
            const val = try self.evalExpr(field.value, environment);
            try map.put(key, val);
        }

        return Value{ .record = map };
    }

    fn evalLambda(self: *Evaluator, lam: @TypeOf(@as(ast.Expr, undefined).lambda), environment: *Environment) EvalResult!Value {
        const closure = try self.allocator.create(value.Closure);
        closure.* = value.Closure{
            .params = lam.params,
            .body = lam.body,
            .env = @ptrCast(environment),
            .allocator = self.allocator,
        };
        try self.closures.append(self.allocator, closure);
        return Value{ .closure = closure };
    }

    fn evalIfExpr(self: *Evaluator, ie: @TypeOf(@as(ast.Expr, undefined).if_expr), environment: *Environment) EvalResult!Value {
        // 条件不在尾位置 — 必须先求值完毕再判断分支
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        const condition = try self.evalExpr(ie.condition, environment);
        self.in_tail_position = saved_tail;
        // if 表达式的分支在尾位置时保持尾位置标记
        if (condition.isTruthy()) {
            return self.evalExpr(ie.then_branch, environment);
        } else if (ie.else_branch) |else_br| {
            return self.evalExpr(else_br, environment);
        }
        return Value.unit;
    }

    fn evalBlock(self: *Evaluator, blk: @TypeOf(@as(ast.Expr, undefined).block), environment: *Environment) EvalResult!Value {
        // Phase 1: 不 deinit block_env，因为闭包可能引用它
        const block_env = try environment.createChild();

        var defer_stack = std.ArrayList(*const ast.Expr).empty;
        defer defer_stack.deinit(self.allocator);

        var result: Value = Value.unit;

        // 执行语句 — 语句不在尾位置，必须清除尾位置标记
        const saved_tail_for_stmts = self.in_tail_position;
        self.in_tail_position = false;
        for (blk.statements) |stmt| {
            const stmt_result = self.evalStmt(stmt, block_env, &defer_stack) catch |err| switch (err) {
                error.ReturnValue, error.ThrowValue, error.BreakSignal, error.ContinueSignal, error.GluePanic => {
                    self.in_tail_position = saved_tail_for_stmts;
                    // 执行 defer（覆盖正常返回/throw/panic）
                    self.runDefers(defer_stack.items, block_env) catch {};
                    return err;
                },
                else => {
                    self.in_tail_position = saved_tail_for_stmts;
                    return err;
                },
            };
            if (stmt_result) |val| {
                result = val;
            }
        }
        self.in_tail_position = saved_tail_for_stmts;

        // 尾表达式 — 设置尾位置标记用于 TCO
        if (blk.trailing_expr) |expr| {
            const saved_tail = self.in_tail_position;
            self.in_tail_position = true;
            result = self.evalExpr(expr, block_env) catch |err| switch (err) {
                error.ReturnValue, error.ThrowValue, error.BreakSignal, error.ContinueSignal, error.GluePanic => {
                    self.in_tail_position = saved_tail;
                    // 执行 defer（覆盖正常返回/throw/panic）
                    self.runDefers(defer_stack.items, block_env) catch {};
                    return err;
                },
                error.TailCall => {
                    self.in_tail_position = saved_tail;
                    // 执行 defer 后传播尾调用
                    self.runDefers(defer_stack.items, block_env) catch {};
                    return err;
                },
                else => {
                    self.in_tail_position = saved_tail;
                    return err;
                },
            };
            self.in_tail_position = saved_tail;
        }

        // 执行 defer
        try self.runDefers(defer_stack.items, block_env);

        return result;
    }

    fn runDefers(self: *Evaluator, defer_stack: []const *const ast.Expr, environment: *Environment) !void {
        // LIFO 顺序
        var i: usize = defer_stack.len;
        while (i > 0) {
            i -= 1;
            _ = self.evalExpr(defer_stack[i], environment) catch {};
        }
    }

    // ============================================================
    // match 表达式
    // ============================================================

    fn evalMatch(self: *Evaluator, m: @TypeOf(@as(ast.Expr, undefined).match), environment: *Environment) EvalResult!Value {
        // scrutinee 不在尾位置 — 必须先求值完毕再进行匹配
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        const scrutinee = try self.evalExpr(m.scrutinee, environment);
        self.in_tail_position = saved_tail;

        // 守卫条件求值回调，将 evalExpr 传入 pattern.zig
        const guard_eval_ctx = pattern.GuardEvalCtx{
            .fn_ptr = struct {
                fn eval(ctx: *anyopaque, condition: *const ast.Expr, guard_env: *Environment) pattern.PatternError!bool {
                    const evaluator: *Evaluator = @ptrCast(@alignCast(ctx));
                    const result = try evaluator.evalExpr(condition, guard_env);
                    return result.isTruthy();
                }
            }.eval,
            .ctx = @ptrCast(self),
        };

        for (m.arms) |arm| {
            // Phase 1: 不 deinit match_env，因为闭包可能引用它
            const match_env = try environment.createChild();

            const matched = pattern.matchPattern(arm.pattern, scrutinee, match_env, guard_eval_ctx) catch |err| {
                return err;
            };

            if (matched) {
                // 检查 arm 级别守卫条件
                if (arm.guard) |guard| {
                    const guard_val = try self.evalExpr(guard, match_env);
                    if (!guard_val.isTruthy()) continue;
                }
                return self.evalExpr(arm.body, match_env);
            }
        }

        return self.gluePanic("match expression: no pattern matched");
    }

    // ============================================================
    // 类型转换
    // ============================================================

    fn evalTypeCast(self: *Evaluator, tc: @TypeOf(@as(ast.Expr, undefined).type_cast), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(tc.expr, environment);
        const type_name = switch (tc.target_type.*) {
            .named => |n| n.name,
            else => return error.TypeMismatch,
        };
        return self.castValue(val, type_name);
    }

    fn castValue(self: *Evaluator, val: Value, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "string")) {
            return self.valueToString(val);
        }
        if (val == .integer) {
            return self.castInteger(val.integer, type_name);
        }
        if (val == .float) {
            return self.castFloat(val.float, type_name);
        }
        if (val == .boolean) {
            if (std.mem.eql(u8, type_name, "string")) {
                return self.valueToString(val);
            }
            return error.TypeMismatch;
        }
        return error.TypeMismatch;
    }

    fn castInteger(self: *Evaluator, val: i128, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "i8")) {
            const result = clampInt(val, i8) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "i16")) {
            const result = clampInt(val, i16) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "i32")) {
            const result = clampInt(val, i32) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "i64")) {
            const result = clampInt(val, i64) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "i128")) return Value{ .integer = val };
        if (std.mem.eql(u8, type_name, "u8")) {
            const result = clampUInt(val, u8) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "u16")) {
            const result = clampUInt(val, u16) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "u32")) {
            const result = clampUInt(val, u32) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "u64")) {
            const result = clampUInt(val, u64) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "u128")) {
            const result = clampUInt(val, u128) catch return self.gluePanic("integer overflow in narrowing conversion");
            return Value{ .integer = result };
        }
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatFromInt(val)) };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = @as(f64, @floatFromInt(val)) };
        return error.TypeMismatch;
    }

    fn castFloat(self: *Evaluator, val: f64, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatCast(@as(f32, @floatCast(val)))) };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = val };
        if (std.mem.eql(u8, type_name, "i8")) return floatToInt(val, i8) catch return self.gluePanic("integer overflow in narrowing conversion");
        if (std.mem.eql(u8, type_name, "i16")) return floatToInt(val, i16) catch return self.gluePanic("integer overflow in narrowing conversion");
        if (std.mem.eql(u8, type_name, "i32")) return floatToInt(val, i32) catch return self.gluePanic("integer overflow in narrowing conversion");
        if (std.mem.eql(u8, type_name, "i64")) return floatToInt(val, i64) catch return self.gluePanic("integer overflow in narrowing conversion");
        if (std.mem.eql(u8, type_name, "i128")) return floatToInt(val, i128) catch return self.gluePanic("integer overflow in narrowing conversion");
        return error.TypeMismatch;
    }

    fn valueToString(self: *Evaluator, val: Value) EvalResult!Value {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try val.format(&buf, self.allocator);
        return Value{ .string = try buf.toOwnedSlice(self.allocator) };
    }

    // ============================================================
    // 语句执行
    // ============================================================

    pub fn evalStmt(self: *Evaluator, stmt: *const ast.Stmt, environment: *Environment, defer_stack: ?*std.ArrayList(*const ast.Expr)) EvalResult!?Value {
        return switch (stmt.*) {
            .val_decl => |vd| {
                const val = try self.evalExpr(vd.value, environment);
                try environment.defineWithVisibility(vd.name, val, false, vd.visibility == .public);
                return null;
            },
            .var_decl => |vd| {
                const val = try self.evalExpr(vd.value, environment);
                try environment.defineWithVisibility(vd.name, val, true, vd.visibility == .public);
                return null;
            },
            .assignment => |asgn| {
                const val = try self.evalExpr(asgn.value, environment);
                switch (asgn.target.*) {
                    .identifier => |id| {
                        try environment.set(id.name, val);
                    },
                    else => return error.TypeMismatch,
                }
                return null;
            },
            .field_assignment => |fa| {
                const val = try self.evalExpr(fa.value, environment);
                const object = try self.evalExpr(fa.object, environment);
                switch (object) {
                    .record => |*map| {
                        if (map.getPtr(fa.field)) |existing| {
                            existing.* = val;
                        } else {
                            return error.UndefinedVariable;
                        }
                    },
                    else => return error.TypeMismatch,
                }
                return null;
            },
            .expression => |expr_stmt| {
                const val = try self.evalExpr(expr_stmt.expr, environment);
                return val;
            },
            .return_stmt => |ret| {
                const val = if (ret.value) |v| try self.evalExpr(v, environment) else Value.unit;
                self.return_value = val;
                return error.ReturnValue;
            },
            .defer_stmt => |def| {
                // 注册到 defer 栈，而非立即执行
                if (defer_stack) |ds| {
                    try ds.append(self.allocator, def.expr);
                }
                return null;
            },
            .throw_stmt => |thr| {
                const val = try self.evalExpr(thr.expr, environment);
                // throw 语句：抛出满足 Error trait 的值
                switch (val) {
                    .throw_val => |tv| {
                        // throw Error("msg") / throw FileError("msg")
                        // 表达式已经是 ThrowValue.err，直接传播
                        self.throw_value = Value{ .throw_val = tv };
                        return error.ThrowValue;
                    },
                    .error_val => |e| {
                        // 旧路径：error_val 包装为 ThrowValue.err
                        const tv = try self.allocator.create(value.ThrowValue);
                        tv.* = value.ThrowValue{ .err = e };
                        self.throw_value = Value{ .throw_val = tv };
                        return error.ThrowValue;
                    },
                    else => return error.TypeMismatch,
                }
            },
            .break_stmt => {
                return error.BreakSignal;
            },
            .continue_stmt => {
                return error.ContinueSignal;
            },
            .for_stmt => |fs| {
                return self.evalForStmt(fs, environment);
            },
            .while_stmt => |ws| {
                return self.evalWhileStmt(ws, environment);
            },
            .loop_stmt => |ls| {
                return self.evalLoopStmt(ls, environment);
            },
        };
    }

    // ============================================================
    // 模块加载
    // ============================================================

    /// 从文件系统加载模块
    /// module_path: 模块路径组件，如 ["Collections"] 或 ["Collections", "Map"]
    fn loadModuleFromFile(self: *Evaluator, module_path: [][]const u8) anyerror!void {
        const allocator = self.allocator;
        const io = self.io orelse return error.FileNotFound;

        // 构建文件路径
        var file_path = std.ArrayList(u8).empty;
        defer file_path.deinit(allocator);

        // 基础目录
        const base_dir = self.current_source_dir orelse ".";

        // 拼接路径
        try file_path.appendSlice(allocator, base_dir);
        for (module_path) |component| {
            try file_path.append(allocator, std.fs.path.sep);
            try file_path.appendSlice(allocator, component);
        }

        // 尝试 .glue 文件
        const path_with_ext = try std.fmt.allocPrint(allocator, "{s}.glue", .{file_path.items});
        defer allocator.free(path_with_ext);

        // 尝试直接文件
        const cwd = std.Io.Dir.cwd();
        if (cwd.readFileAlloc(io, path_with_ext, allocator, .unlimited)) |source| {
            defer allocator.free(source);
            try self.evalSourceModule(source, module_path[0], path_with_ext);
            return;
        } else |_| {
            // 尝试 pack.glue（目录模块）
            const pack_path = try std.fmt.allocPrint(allocator, "{s}" ++ [_]u8{std.fs.path.sep} ++ "pack.glue", .{file_path.items});
            defer allocator.free(pack_path);

            if (cwd.readFileAlloc(io, pack_path, allocator, .unlimited)) |pack_source| {
                defer allocator.free(pack_source);
                try self.evalSourceModule(pack_source, module_path[0], pack_path);
                return;
            } else |_| {
                return error.FileNotFound;
            }
        }
    }

    /// 解析并求值源代码作为模块
    fn evalSourceModule(self: *Evaluator, source: []const u8, module_name: []const u8, source_path: []const u8) anyerror!void {
        const allocator = self.allocator;
        const lexer_mod = @import("lexer");
        const parser_mod = @import("parser");

        // 词法分析
        var lex = lexer_mod.Lexer.init(allocator, source);
        defer lex.deinit();
        const tokens = try lex.tokenize();
        defer allocator.free(tokens);

        // 语法分析
        var p = parser_mod.Parser.init(allocator, tokens);
        defer p.deinit();

        const module = try p.parseModule(module_name);

        // 创建带源路径的模块
        var module_with_path = module;
        module_with_path.source_path = source_path;

        // 求值模块
        try self.evalModule(module_with_path);
    }

    /// 检查名称是否在 pub_names 中
    fn isPubName(self: *Evaluator, pub_names: []const u8, name: []const u8) bool {
        _ = self;
        var start: usize = 0;
        for (pub_names, 0..) |ch, i| {
            if (ch == 0 or i == pub_names.len - 1) {
                const end = if (ch == 0) i else i + 1;
                if (end > start) {
                    const pub_name = pub_names[start..end];
                    if (std.mem.eql(u8, pub_name, name)) return true;
                }
                start = i + 1;
            }
        }
        return false;
    }

    fn evalForStmt(self: *Evaluator, fs: @TypeOf(@as(ast.Stmt, undefined).for_stmt), environment: *Environment) EvalResult!?Value {
        const iterable = try self.evalExpr(fs.iterable, environment);

        switch (iterable) {
            .array => |arr| {
                for (arr) |item| {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, item, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .string => |s| {
                // UTF-8 码点迭代
                var iter = std.unicode.Utf8View.init(s) catch {
                    // 如果不是有效 UTF-8，回退到字节迭代
                    for (s) |byte| {
                        const loop_env = try environment.createChild();
                        try loop_env.define(fs.name, Value{ .char_val = @as(u21, @intCast(byte)) }, false);
                        _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                            error.BreakSignal => break,
                            error.ContinueSignal => continue,
                            else => return err,
                        };
                    }
                    return null;
                };
                var utf8_iter = iter.iterator();
                while (utf8_iter.nextCodepoint()) |codepoint| {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .char_val = codepoint }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .range => |r| {
                var i: i128 = r.start;
                const end_val: i128 = if (r.inclusive) r.end + 1 else r.end;
                while (i < end_val) : (i += 1) {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .integer = i }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .integer => |range_end| {
                // 整数作为范围上限（0..range_end）
                if (range_end < 0) return null;
                var i: i128 = 0;
                while (i < range_end) : (i += 1) {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .integer = i }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            else => {
                // 非内建类型：尝试 Iterable/Iterator 协议
                // for item in list { body }
                // 脱糖为：val iter = list.iterator(); loop { match iter.next() { null => break, item => body } }
                return self.evalForStmtWithIterator(fs, iterable, environment);
            },
        }

        return null;
    }

    /// 通过 Iterable/Iterator 协议执行 for 循环
    /// 用于实现了 Iterable<T> trait 的自定义类型
    fn evalForStmtWithIterator(self: *Evaluator, fs: @TypeOf(@as(ast.Stmt, undefined).for_stmt), iterable: Value, environment: *Environment) EvalResult!?Value {
        // 调用 iterable.iterator() 获取迭代器
        const iter = self.callMethod(iterable, "iterator", &[_]Value{}, environment) catch |err| switch (err) {
            error.UndefinedVariable => return error.TypeMismatch,
            else => return err,
        };

        // 循环调用 iter.next()
        while (true) {
            const next_val = self.callMethod(iter, "next", &[_]Value{}, environment) catch |err| switch (err) {
                error.UndefinedVariable => return error.TypeMismatch,
                else => return err,
            };
            if (next_val.isNull()) break;

            const loop_env = try environment.createChild();
            try loop_env.define(fs.name, next_val, false);

            _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                error.BreakSignal => break,
                error.ContinueSignal => continue,
                else => return err,
            };
        }

        return null;
    }

    fn evalWhileStmt(self: *Evaluator, ws: @TypeOf(@as(ast.Stmt, undefined).while_stmt), environment: *Environment) EvalResult!?Value {
        while (true) {
            const condition = try self.evalExpr(ws.condition, environment);
            if (!condition.isTruthy()) break;

            _ = self.evalExpr(ws.body, environment) catch |err| switch (err) {
                error.BreakSignal => break,
                error.ContinueSignal => continue,
                else => return err,
            };
        }
        return null;
    }

    fn evalLoopStmt(self: *Evaluator, ls: @TypeOf(@as(ast.Stmt, undefined).loop_stmt), environment: *Environment) EvalResult!?Value {
        while (true) {
            _ = self.evalExpr(ls.body, environment) catch |err| switch (err) {
                error.BreakSignal => break,
                else => return err,
            };
        }
        return null;
    }
};

// ============================================================
// 文件级辅助函数
// ============================================================

/// 结构相等（递归比较值）
fn structuralEquals(a: Value, b: Value) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return false;
    return switch (a) {
        .integer => |i| i == b.integer,
        .float => |f| f == b.float,
        .boolean => |bo| bo == b.boolean,
        .char_val => |c| c == b.char_val,
        .string => |s| std.mem.eql(u8, s, b.string),
        .null_val => true,
        .unit => true,
        .range => |r| r.start == b.range.start and r.end == b.range.end and r.inclusive == b.range.inclusive,
        .array => |arr| {
            if (arr.len != b.array.len) return false;
            for (arr, b.array) |item_a, item_b| {
                if (!structuralEquals(item_a, item_b)) return false;
            }
            return true;
        },
        .record => |map| {
            // 比较所有键值对
            var iter = map.iterator();
            while (iter.next()) |entry| {
                if (b.record.get(entry.key_ptr.*)) |b_val| {
                    if (!structuralEquals(entry.value_ptr.*, b_val)) return false;
                } else {
                    return false;
                }
            }
            // 确保没有多余的键
            var b_iter = b.record.iterator();
            while (b_iter.next()) |entry| {
                if (map.get(entry.key_ptr.*)) |_| {} else {
                    return false;
                }
            }
            return true;
        },
        .closure => |c| c == b.closure,
        .builtin => |b_val| b_val.fn_ptr == b.builtin.fn_ptr and b_val.user_ctx == b.builtin.user_ctx,
        .error_val => |e| std.mem.eql(u8, e.type_name, b.error_val.type_name) and std.mem.eql(u8, e.message, b.error_val.message),
        .throw_val => |tv| tv == b.throw_val, // 引用相等
        .adt => |av| {
            if (!std.mem.eql(u8, av.type_name, b.adt.type_name)) return false;
            if (!std.mem.eql(u8, av.constructor, b.adt.constructor)) return false;
            if (av.fields.len != b.adt.fields.len) return false;
            for (av.fields, b.adt.fields) |a_field, b_field| {
                if (a_field.name == null or b_field.name == null) return false;
                if (!std.mem.eql(u8, a_field.name.?, b_field.name.?)) return false;
                if (!structuralEquals(a_field.value, b_field.value)) return false;
            }
            return true;
        },
        .newtype => |nv| {
            if (!std.mem.eql(u8, nv.type_name, b.newtype.type_name)) return false;
            return structuralEquals(nv.inner, b.newtype.inner);
        },
    };
}

fn parseInt(comptime T: type, raw: []const u8) !T {
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(std.heap.page_allocator);

    var i: usize = 0;

    // 检查进制前缀
    var base: u8 = 10;
    if (raw.len > 2 and raw[0] == '0') {
        if (raw[1] == 'x' or raw[1] == 'X') {
            base = 16;
            i = 2;
        } else if (raw[1] == 'o' or raw[1] == 'O') {
            base = 8;
            i = 2;
        } else if (raw[1] == 'b' or raw[1] == 'B') {
            base = 2;
            i = 2;
        }
    }

    // 去除类型后缀（如 i8, u32, i64, i128, u8, f32, f64 等）
    // 后缀格式：字母开头，后跟数字和字母
    var end = raw.len;
    if (end > 0) {
        var j = end;
        // 先跳过末尾的数字
        while (j > i and raw[j - 1] >= '0' and raw[j - 1] <= '9') {
            j -= 1;
        }
        // 再跳过字母部分
        if (j > i and ((raw[j - 1] >= 'a' and raw[j - 1] <= 'z') or (raw[j - 1] >= 'A' and raw[j - 1] <= 'Z'))) {
            j -= 1;
            // 继续跳过更多字母（如 i128 中的 i 后面没有更多字母，但 f32 有 f）
            while (j > i and ((raw[j - 1] >= 'a' and raw[j - 1] <= 'z') or (raw[j - 1] >= 'A' and raw[j - 1] <= 'Z'))) {
                j -= 1;
            }
            end = j;
        }
    }

    // 去除下划线
    while (i < end) : (i += 1) {
        if (raw[i] != '_') {
            clean.append(std.heap.page_allocator, raw[i]) catch return error.Overflow;
        }
    }

    const str = clean.items;
    if (str.len == 0) return 0;

    return std.fmt.parseInt(T, str, base) catch error.Overflow;
}

fn parseFloat(comptime T: type, raw: []const u8) !T {
    // 去除类型后缀
    var end = raw.len;
    while (end > 0) {
        const ch = raw[end - 1];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            end -= 1;
        } else {
            break;
        }
    }

    return std.fmt.parseFloat(T, raw[0..end]) catch error.TypeMismatch;
}

fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f32",  "f64",
        "bool", "string",
    };
    for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

fn clampInt(val: i128, comptime T: type) !i128 {
    const min: i128 = std.math.minInt(T);
    const max: i128 = std.math.maxInt(T);
    if (val < min or val > max) {
        return error.GluePanic;
    }
    return val;
}

fn clampUInt(val: i128, comptime T: type) !i128 {
    if (val < 0) {
        return error.GluePanic;
    }
    // 对于 u128，i128 的最大值就是上限（因为 i128 < u128::MAX）
    if (comptime std.math.maxInt(T) > std.math.maxInt(i128)) {
        // u128 类型：i128 正值都在范围内
        return val;
    }
    const max: i128 = @intCast(std.math.maxInt(T));
    if (val > max) {
        return error.GluePanic;
    }
    return val;
}

fn floatToInt(val: f64, comptime T: type) EvalResult!Value {
    if (std.math.isNan(val) or std.math.isInf(val)) return error.GluePanic;
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (val < min or val > max) return error.GluePanic;
    return Value{ .integer = @as(i128, @intFromFloat(val)) };
}

// ============================================================
// 便捷求值函数
// ============================================================

/// 解析并求值表达式字符串
pub fn evalSource(allocator: std.mem.Allocator, source: []const u8) !Value {
    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const expr = try p.parseExpr();

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    // 顶层表达式求值 — 如果产生 TailCall，需要 trampoline 处理
    const result = evaluator.evalExpr(expr, &evaluator.global_env) catch |err| switch (err) {
        error.TailCall => {
            const tc = evaluator.tail_call.?;
            evaluator.tail_call = null;
            return evaluator.callFunction(Value{ .closure = tc.closure }, tc.args, null);
        },
        else => return err,
    };
    return result;
}

// ============================================================
// 测试
// ============================================================

test "求值器 - 整数字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "42");
    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "求值器 - 浮点字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "3.14");
    try std.testing.expect(result == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.float, 0.001);
}

test "求值器 - 布尔字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try evalSource(allocator, "true");
    try std.testing.expect(t == .boolean);
    try std.testing.expectEqual(true, t.boolean);

    const f = try evalSource(allocator, "false");
    try std.testing.expect(f == .boolean);
    try std.testing.expectEqual(false, f.boolean);
}

test "求值器 - null 和单位值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n = try evalSource(allocator, "null");
    try std.testing.expect(n == .null_val);

    const u = try evalSource(allocator, "()");
    try std.testing.expect(u == .unit);
}

test "求值器 - 基本算术" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const add = try evalSource(allocator, "1 + 2");
    try std.testing.expectEqual(@as(i128, 3), add.integer);

    const sub = try evalSource(allocator, "10 - 3");
    try std.testing.expectEqual(@as(i128, 7), sub.integer);

    const mul = try evalSource(allocator, "4 * 5");
    try std.testing.expectEqual(@as(i128, 20), mul.integer);

    const div = try evalSource(allocator, "10 / 3");
    try std.testing.expectEqual(@as(i128, 3), div.integer);

    const mod = try evalSource(allocator, "10 % 3");
    try std.testing.expectEqual(@as(i128, 1), mod.integer);
}

test "求值器 - 运算符优先级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "1 + 2 * 3");
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - 比较运算" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lt = try evalSource(allocator, "1 < 2");
    try std.testing.expectEqual(true, lt.boolean);

    const gt = try evalSource(allocator, "3 > 2");
    try std.testing.expectEqual(true, gt.boolean);

    const eq = try evalSource(allocator, "1 == 1");
    try std.testing.expectEqual(true, eq.boolean);

    const neq = try evalSource(allocator, "1 != 2");
    try std.testing.expectEqual(true, neq.boolean);
}

test "求值器 - 逻辑运算（短路）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const and_true = try evalSource(allocator, "true && true");
    try std.testing.expectEqual(true, and_true.boolean);

    const and_false = try evalSource(allocator, "true && false");
    try std.testing.expectEqual(false, and_false.boolean);

    const or_true = try evalSource(allocator, "false || true");
    try std.testing.expectEqual(true, or_true.boolean);

    const or_false = try evalSource(allocator, "false || false");
    try std.testing.expectEqual(false, or_false.boolean);
}

test "求值器 - 一元运算" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const neg = try evalSource(allocator, "-42");
    try std.testing.expectEqual(@as(i128, -42), neg.integer);

    const not_val = try evalSource(allocator, "!true");
    try std.testing.expectEqual(false, not_val.boolean);
}

test "求值器 - val 声明和引用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 42; x }");
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "求值器 - var 声明和赋值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var x = 1; x = 10; x }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - if 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const then_val = try evalSource(allocator, "if true { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 1), then_val.integer);

    const else_val = try evalSource(allocator, "if false { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 2), else_val.integer);
}

test "求值器 - 块表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 1; val y = 2; x + y }");
    try std.testing.expectEqual(@as(i128, 3), result.integer);
}

test "求值器 - Lambda 和闭包" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Lambda 表达式体
    const result = try evalSource(allocator, "{ val add = (a, b) => a + b; add(3, 4) }");
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - fun Lambda" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val double = fun(x) { x * 2 }; double(5) }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - 闭包捕获" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 10; val f = (y) => x + y; f(5) }");
    try std.testing.expectEqual(@as(i128, 15), result.integer);
}

test "求值器 - match 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 字面量匹配
    const result = try evalSource(allocator, "match 1 { 0 => 100, 1 => 200, _ => 300 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer);
}

test "求值器 - match 通配符" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 99 { 0 => 100, _ => 200 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer);
}

test "求值器 - match 变量绑定" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 42 { x => x + 1 }");
    try std.testing.expectEqual(@as(i128, 43), result.integer);
}

test "求值器 - Elvis 运算符 ??" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42 ?? 0");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);

    const null_val = try evalSource(allocator, "null ?? 0");
    try std.testing.expectEqual(@as(i128, 0), null_val.integer);
}

test "求值器 - 非空断言 !" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42!");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);

    // null! 应该 panic
    // const null_assert = evalSource(allocator, "null!");
}

test "求值器 - 类型转换" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // i32 -> f64 (widening)
    const i2f = try evalSource(allocator, "f64(42)");
    try std.testing.expect(i2f == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), i2f.float, 0.001);

    // f64 -> i32 (narrowing)
    const f2i = try evalSource(allocator, "i32(3.14)");
    try std.testing.expectEqual(@as(i128, 3), f2i.integer);

    // string()
    const s = try evalSource(allocator, "string(42)");
    try std.testing.expect(s == .string);
    try std.testing.expectEqualStrings("42", s.string);
}

test "求值器 - 数组字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "[1, 2, 3]");
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 3), result.array.len);
    try std.testing.expectEqual(@as(i128, 1), result.array[0].integer);
    try std.testing.expectEqual(@as(i128, 2), result.array[1].integer);
    try std.testing.expectEqual(@as(i128, 3), result.array[2].integer);
}

test "求值器 - 索引访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val arr = [10, 20, 30]; arr[1] }");
    try std.testing.expectEqual(@as(i128, 20), result.integer);
}

test "求值器 - 记录字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "(name: \"Alice\", age: 30)");
    try std.testing.expect(result == .record);
    const name = result.record.get("name").?;
    try std.testing.expectEqualStrings("Alice", name.string);
    const age = result.record.get("age").?;
    try std.testing.expectEqual(@as(i128, 30), age.integer);
}

test "求值器 - 字段访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val p = (name: \"Bob\", age: 25); p.age }");
    try std.testing.expectEqual(@as(i128, 25), result.integer);
}

test "求值器 - 安全访问 ?." {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const null_access = try evalSource(allocator, "null?.field");
    try std.testing.expect(null_access == .null_val);

    const valid_access = try evalSource(allocator, "{ val p = (x: 1); p?.x }");
    try std.testing.expectEqual(@as(i128, 1), valid_access.integer);
}

test "求值器 - while 循环" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var sum = 0; var i = 0; while i < 5 { sum = sum + i; i = i + 1 }; sum }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - for 循环" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 使用 evalExpr 直接测试，避免解析器限制
    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun sum_arr(arr) { var s = 0; for x in arr { s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("sum_arr").?;
    var arr = try allocator.alloc(Value, 5);
    arr[0] = Value{ .integer = 1 };
    arr[1] = Value{ .integer = 2 };
    arr[2] = Value{ .integer = 3 };
    arr[3] = Value{ .integer = 4 };
    arr[4] = Value{ .integer = 5 };
    const args = [_]Value{Value{ .array = arr }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 15), result.integer);
}

test "求值器 - loop 和 break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun loop_test() { var i = 0; loop { i = i + 1; if i >= 5 { break } }; i }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("loop_test").?;
    const args = [_]Value{};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 5), result.integer);
}

test "求值器 - for 循环 continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun skip_three(arr) { var s = 0; for x in arr { if x == 3 { continue } s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("skip_three").?;
    var arr = try allocator.alloc(Value, 5);
    arr[0] = Value{ .integer = 1 };
    arr[1] = Value{ .integer = 2 };
    arr[2] = Value{ .integer = 3 };
    arr[3] = Value{ .integer = 4 };
    arr[4] = Value{ .integer = 5 };
    const args = [_]Value{Value{ .array = arr }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 12), result.integer);
}

test "求值器 - 顶层函数声明和调用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun add(a, b) { a + b }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    // 调用 add 函数
    const add_fn = evaluator.global_env.get("add").?;
    const args = [_]Value{ Value{ .integer = 3 }, Value{ .integer = 4 } };
    const result = try evaluator.callFunction(add_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - 字符串拼接" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "\"hello\" + \" \" + \"world\"");
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "求值器 - 传播操作符 ?" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 非 null 值传播
    const non_null = try evalSource(allocator, "42?");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);
}

test "求值器 - 嵌套闭包" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun make_adder(x) { fun(y) { x + y } }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const make_adder = evaluator.global_env.get("make_adder").?;
    const make_args = [_]Value{Value{ .integer = 5 }};
    const add5 = try evaluator.callFunction(make_adder.value, &make_args, null);

    const add_args = [_]Value{Value{ .integer = 3 }};
    const result = try evaluator.callFunction(add5, &add_args, null);
    try std.testing.expectEqual(@as(i128, 8), result.integer);
}

test "求值器 - 递归函数" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun fib(n) { if n <= 1 { n } else { fib(n - 1) + fib(n - 2) } }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fib_fn = evaluator.global_env.get("fib").?;
    const args = [_]Value{Value{ .integer = 10 }};
    const result = try evaluator.callFunction(fib_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 55), result.integer);
}

test "求值器 - match 记录模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match (x: 1, y: 2) { (x: a, y: b) => a + b }");
    try std.testing.expectEqual(@as(i128, 3), result.integer);
}

test "求值器 - match 布尔模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match true { true => 1, false => 0 }");
    try std.testing.expectEqual(@as(i128, 1), result.integer);
}

test "求值器 - match null 模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match null { null => 0, _ => 1 }");
    try std.testing.expectEqual(@as(i128, 0), result.integer);
}

// ============================================================
// Phase 2 测试
// ============================================================

// --- ADT + Pattern Matching ---

test "Phase 2 - ADT 枚举类型（无参构造器）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Ordering =
        \\    | Lt
        \\    | Eq
        \\    | Gt
        \\
        \\fun test_ordering() {
        \\    match Lt {
        \\        Lt => 1,
        \\        Eq => 2,
        \\        Gt => 3,
        \\    }
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_ordering").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 1), result.integer);
}

test "Phase 2 - ADT 带参构造器和字段访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Shape =
        \\    | Circle(radius: f64)
        \\    | Rectangle(width: f64, height: f64)
        \\
        \\fun test_field() {
        \\    val s = Circle(3.0)
        \\    s.radius
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_field").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.float, 0.001);
}

test "Phase 2 - ADT 模式匹配" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Shape =
        \\    | Circle(radius: f64)
        \\    | Rectangle(width: f64, height: f64)
        \\
        \\fun area(shape) {
        \\    match shape {
        \\        Circle(r) => 3.14159 * r * r,
        \\        Rectangle(w, h) => w * h,
        \\    }
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("area").?;
    // 调用 Circle(2.0) 来测试
    const circle_val = evaluator.global_env.get("Circle").?;
    const circle_args = [_]Value{Value{ .float = 2.0 }};
    const shape = try evaluator.callFunction(circle_val.value, &circle_args, null);
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{shape}, null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159 * 2.0 * 2.0), result.float, 0.01);
}

test "Phase 2 - ADT 多构造器匹配" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Option =
        \\    | Some(value: i32)
        \\    | None
        \\
        \\fun test_match() {
        \\    match Some(42) {
        \\        Some(v) => v,
        \\        None => 0,
        \\    }
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_match").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "Phase 2 - ADT 枚举匹配不同分支" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Ordering =
        \\    | Lt
        \\    | Eq
        \\    | Gt
        \\
        \\fun describe(o) {
        \\    match o {
        \\        Lt => 1,
        \\        Eq => 2,
        \\        Gt => 3,
        \\    }
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("describe").?;
    const lt_val = evaluator.global_env.get("Lt").?;
    const eq_val = evaluator.global_env.get("Eq").?;
    const gt_val = evaluator.global_env.get("Gt").?;

    const r1 = try evaluator.callFunction(fn_val.value, &[_]Value{lt_val.value}, null);
    try std.testing.expectEqual(@as(i128, 1), r1.integer);

    const r2 = try evaluator.callFunction(fn_val.value, &[_]Value{eq_val.value}, null);
    try std.testing.expectEqual(@as(i128, 2), r2.integer);

    const r3 = try evaluator.callFunction(fn_val.value, &[_]Value{gt_val.value}, null);
    try std.testing.expectEqual(@as(i128, 3), r3.integer);
}

// --- Trait 定义与实现 ---

test "Phase 2 - Trait 方法调用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\trait Describable {
        \\    fun describe(self) : i32
        \\}
        \\
        \\impl Describable {
        \\    fun describe(self) {
        \\        99
        \\    }
        \\}
        \\
        \\fun test_trait() {
        \\    42.describe()
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_trait").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 99), result.integer);
}

// --- 记录类型构造器 ---

test "Phase 2 - 记录类型构造器" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Point = (x: f64, y: f64)
        \\
        \\fun test_point() {
        \\    val p = Point(1.0, 2.0)
        \\    p.x
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_point").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.float, 0.001);
}

// --- for 循环（内建 Iterable） ---

test "Phase 2 - for 循环数组迭代" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun sum_arr() { var s = 0; for x in [1, 2, 3, 4, 5] { s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("sum_arr").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 15), result.integer);
}

test "Phase 2 - for 循环字符串迭代" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun count_chars() { var c = 0; for ch in \"abc\" { c = c + 1 }; c }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("count_chars").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 3), result.integer);
}

test "Phase 2 - for 循环 range 迭代" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun sum_range() { var s = 0; for x in 1..5 { s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("sum_range").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

// --- ADT 字段访问 ---

test "Phase 2 - ADT 字段访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source =
        \\type Pair = Pair(first: i32, second: i32)
        \\
        \\fun test_pair() {
        \\    val p = Pair(10, 20)
        \\    p.first + p.second
        \\}
    ;
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);
    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();
    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();
    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("test_pair").?;
    const result = try evaluator.callFunction(fn_val.value, &[_]Value{}, null);
    try std.testing.expectEqual(@as(i128, 30), result.integer);
}
