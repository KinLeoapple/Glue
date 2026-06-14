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
const vtable_rt = @import("vtable_rt");

// ============================================================
// 便捷重导出
// ============================================================

pub const Value = value.Value;
pub const ArrayValue = value.ArrayValue;
pub const Range = value.Range;
pub const IntValue = value.IntValue;
pub const IntType = value.IntType;
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
    type_name: []const u8,
    field_names: [][]const u8,
};

/// 委托信息（运行时动态分派用）— 从 vtable 模块 re-export
pub const DelegateEntry = vtable_rt.DelegateEntry;

/// Trait 声明信息 — 从 vtable 模块 re-export
pub const TraitInfo = vtable_rt.TraitInfo;

/// Impl 方法注册项 — 从 vtable 模块 re-export
pub const ImplMethodEntry = vtable_rt.ImplMethodEntry;

/// Impl 注册信息 — 从 vtable 模块 re-export
pub const ImplInfo = vtable_rt.ImplInfo;

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

/// 持久化 stdin 读取器 — 存储读取缓冲区和 File.Reader
/// 避免每次调用 scan/scanln 时重建 reader 导致缓冲数据丢失
const StdinState = struct {
    buffer: [8192]u8 = undefined,
    reader: std.Io.File.Reader,
};

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
    /// Trait 定义顺序（后定义的优先），用于方法分派消歧
    trait_definition_order: std.ArrayList([]const u8),
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
    /// 已注册的 impl（用于 Overlapping Instances 检查）
    /// key: "trait_name::type_name", value: void
    registered_impls: std.StringHashMap(void),
    /// Impl 注册表（用于关联类型查找）
    /// key: "trait_name::type_name", value: ImplInfo
    impl_registry: std.StringHashMap(ImplInfo),
    /// scan/scanln 的持久化 stdin 读取器（堆分配，首次调用时创建）
    stdin_state: ?*StdinState = null,
    /// scan/scanln 的当前行缓冲区 — 由 readNextLine 填充
    scan_line_buf: std.ArrayList(u8),
    /// scan_line_buf 中当前读取位置
    scan_line_pos: usize = 0,
    /// 已创建的 SpawnHandle 列表（用于 deinit 时释放）
    spawn_handles: std.ArrayList(*value.SpawnHandle),

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .closures = std.ArrayList(*value.Closure).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .trait_definition_order = std.ArrayList([]const u8).empty,
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
            .registered_impls = std.StringHashMap(void).init(allocator),
            .impl_registry = std.StringHashMap(ImplInfo).init(allocator),
            .scan_line_buf = std.ArrayList(u8).empty,
            .spawn_handles = std.ArrayList(*value.SpawnHandle).empty,
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
            .trait_definition_order = std.ArrayList([]const u8).empty,
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
            .registered_impls = std.StringHashMap(void).init(allocator),
            .impl_registry = std.StringHashMap(ImplInfo).init(allocator),
            .scan_line_buf = std.ArrayList(u8).empty,
            .spawn_handles = std.ArrayList(*value.SpawnHandle).empty,
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
            self.allocator.free(ctx.type_name);
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
        // 释放 stdin 读取器和行缓冲区
        if (self.stdin_state) |state| {
            self.allocator.destroy(state);
        }
        self.scan_line_buf.deinit(self.allocator);
        // 等待所有 spawn 协程完成并释放 handle
        for (self.spawn_handles.items) |handle| {
            // 等待线程完成
            if (handle.thread) |t| {
                t.join();
            }
            handle.deinit();
            self.allocator.destroy(handle);
        }
        self.spawn_handles.deinit(self.allocator);
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

    /// 创建 SpawnStatus ADT 值
    fn makeSpawnStatus(self: *Evaluator, status: value.SpawnStatus) EvalResult!Value {
        const name = switch (status) {
            .Pending => "Pending",
            .Running => "Running",
            .Completed => "Completed",
            .Cancelled => "Cancelled",
            .Failed => "Failed",
        };
        const av = try self.allocator.create(value.AdtValue);
        av.* = value.AdtValue{
            .type_name = "SpawnStatus",
            .constructor = name,
            .fields = &[_]value.AdtField{},
        };
        return Value{ .adt = av };
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
        // str (类型转换)
        self.global_env.define("str", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
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
        // scan — 读取一个空白分隔的 token，EOF 返回 null
        self.global_env.define("scan", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinScan(args);
            }
        }.call } }, true) catch {};
        // scanln — 读取一行，EOF 返回 null
        self.global_env.define("scanln", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinScanln(args);
            }
        }.call } }, true) catch {};

        // channel — 创建 CSP 通道
        self.global_env.define("channel", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinChannel(args);
            }
        }.call } }, true) catch {};

        // 文档 2.7.8 / 2.17: Iterable<T> 和 Iterator<T> 内建 Trait
        {
            const iterable_method_names = self.allocator.dupe(u8, "iterator") catch return;
            const iterable_info = TraitInfo{
                .name = self.allocator.dupe(u8, "Iterable") catch return,
                .method_names = iterable_method_names,
                .default_methods = std.StringHashMap(*value.Closure).init(self.allocator),
                .parent_names = &[_][]const u8{},
                .associated_type_names = "",
                .override_methods = std.StringHashMap(void).init(self.allocator),
                .delegate_methods = std.StringHashMap(void).init(self.allocator),
                .delegate_infos = std.StringHashMap(DelegateEntry).init(self.allocator),
            };
            self.trait_registry.put(self.allocator.dupe(u8, "Iterable") catch return, iterable_info) catch return;
            self.trait_definition_order.append(self.allocator, self.allocator.dupe(u8, "Iterable") catch return) catch return;
        }
        {
            const iterator_method_names = self.allocator.dupe(u8, "next") catch return;
            const iterator_info = TraitInfo{
                .name = self.allocator.dupe(u8, "Iterator") catch return,
                .method_names = iterator_method_names,
                .default_methods = std.StringHashMap(*value.Closure).init(self.allocator),
                .parent_names = &[_][]const u8{},
                .associated_type_names = "",
                .override_methods = std.StringHashMap(void).init(self.allocator),
                .delegate_methods = std.StringHashMap(void).init(self.allocator),
                .delegate_infos = std.StringHashMap(DelegateEntry).init(self.allocator),
            };
            self.trait_registry.put(self.allocator.dupe(u8, "Iterator") catch return, iterator_info) catch return;
            self.trait_definition_order.append(self.allocator, self.allocator.dupe(u8, "Iterator") catch return) catch return;
        }
    }

    // ============================================================
    // 内建函数实现
    // ============================================================

    fn builtinPrintln(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
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
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
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
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
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
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
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
        args[0].format(&buf, self.allocator, false) catch {};
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
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
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

    /// 确保 stdin 持久化读取器已创建（首次调用时堆分配），返回读取器接口指针
    fn ensureStdinReader(self: *Evaluator) EvalResult!*std.Io.Reader {
        if (self.stdin_state) |state| return &state.reader.interface;
        const io = self.io orelse {
            self.panic_message = "scan: no IO context";
            return error.GluePanic;
        };
        const state = self.allocator.create(StdinState) catch return error.OutOfMemory;
        state.* = .{
            .buffer = undefined,
            .reader = std.Io.File.Reader.initStreaming(std.Io.File.stdin(), io, &state.buffer),
        };
        self.stdin_state = state;
        return &state.reader.interface;
    }

    /// 从 stdin 读取一行到 scan_line_buf（使用持久化 reader），不含 '\n' 和 '\r'，EOF 返回 null
    fn readNextLine(self: *Evaluator) EvalResult!?[]const u8 {
        const reader = try self.ensureStdinReader();
        self.scan_line_buf.clearRetainingCapacity();
        const line = reader.takeDelimiter('\n') catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "scan: IO error: {s}", .{@errorName(err)}) catch "scan: IO error";
            self.panic_message = msg;
            return error.GluePanic;
        };
        if (line) |l| {
            // Windows CRLF: 去掉尾部 '\r'
            const trimmed = if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l;
            self.scan_line_buf.appendSlice(self.allocator, trimmed) catch return error.OutOfMemory;
            self.scan_line_pos = 0;
            return self.scan_line_buf.items;
        } else {
            return null;
        }
    }

    /// scanln() — 读取一行（不含 '\n'），EOF 返回 null，IO 错误 panic
    fn builtinScanln(self: *Evaluator, args: []const Value) EvalResult!Value {
        if (args.len != 0) return error.WrongArity;

        // 如果当前行还有未消费内容，返回剩余部分
        if (self.scan_line_buf.items.len > 0 and self.scan_line_pos < self.scan_line_buf.items.len) {
            const remaining = self.scan_line_buf.items[self.scan_line_pos..];
            const owned = self.allocator.dupe(u8, remaining) catch return error.OutOfMemory;
            self.scan_line_pos = self.scan_line_buf.items.len;
            return Value{ .string = owned };
        }

        // 从 stdin 读取新行
        const line_opt = self.readNextLine() catch |err| {
            if (err == error.GluePanic) return error.GluePanic;
            return error.OutOfMemory;
        };
        if (line_opt) |line| {
            const owned = self.allocator.dupe(u8, line) catch return error.OutOfMemory;
            self.scan_line_pos = self.scan_line_buf.items.len;
            return Value{ .string = owned };
        } else {
            return Value.null_val;
        }
    }

    /// scan() — 读取一个空白分隔的 token，EOF 返回 null，IO 错误 panic
    fn builtinScan(self: *Evaluator, args: []const Value) EvalResult!Value {
        if (args.len != 0) return error.WrongArity;

        while (true) {
            // 尝试从当前行提取 token
            if (self.scan_line_buf.items.len > 0 and self.scan_line_pos < self.scan_line_buf.items.len) {
                const remaining = self.scan_line_buf.items[self.scan_line_pos..];
                // 跳过前导空白
                var start: usize = 0;
                while (start < remaining.len and (remaining[start] == ' ' or remaining[start] == '\t' or remaining[start] == '\r')) {
                    start += 1;
                }
                if (start < remaining.len) {
                    // 找到 token 结尾
                    var end = start + 1;
                    while (end < remaining.len and remaining[end] != ' ' and remaining[end] != '\t' and remaining[end] != '\r') {
                        end += 1;
                    }
                    const token_slice = remaining[start..end];
                    self.scan_line_pos += end;
                    const owned = self.allocator.dupe(u8, token_slice) catch return error.OutOfMemory;
                    return Value{ .string = owned };
                }
            }

            // 当前行没有更多 token，读取新行
            const line_opt = self.readNextLine() catch |err| {
                if (err == error.GluePanic) return error.GluePanic;
                return error.OutOfMemory;
            };
            if (line_opt == null) return Value.null_val;
            // 循环回去从新行中提取 token
        }
    }

    // ============================================================
    // 并发原语内建函数
    // ============================================================

    /// channel(capacity) — 创建 CSP 通道
    /// 文档 §3.5: val ch = channel<i32>(0) 无缓冲，channel<i32>(10) 缓冲区大小 10
    fn builtinChannel(self: *Evaluator, args: []const Value) EvalResult!Value {
        if (args.len != 1) return error.WrongArity;
        const io = self.io orelse return self.gluePanic("channel: no IO context");
        const cap = switch (args[0]) {
            .integer => |iv| @as(usize, @intCast(iv.value)),
            else => return error.TypeMismatch,
        };
        const ch = try self.allocator.create(value.ChannelValue);
        ch.* = value.ChannelValue.init(self.allocator, cap, io);
        return Value{ .channel_val = ch };
    }

    // ============================================================
    // 入口点调用
    // ============================================================

    /// 查找并调用全局环境中的 `main` 函数
    ///
    /// 仅在文件模式下调用（REPL 不调用）。
    /// 如果未找到 main，返回 error.MissingMain。
    /// 如果找到但不可调用，返回 error.TypeMismatch。
    pub fn callMain(self: *Evaluator) EvalResult!Value {
        const main_var = self.global_env.get("main") orelse return error.MissingMain;
        switch (main_var.value) {
            .closure, .builtin => {
                return self.callFunction(main_var.value, &[_]Value{}, null);
            },
            else => return error.TypeMismatch,
        }
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
        // 文档 D45: 先检查后求值 — 类型检查不通过则阻止求值
        self.type_inferencer.checkModule(&module);

        // 报告类型推断错误到 stderr
        if (self.type_inferencer.errors.items.len > 0) {
            if (self.io) |io| {
                var err_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                for (self.type_inferencer.errors.items) |err| {
                    const kind_str = switch (err.kind) {
                        .type_mismatch => "type error",
                        .unbound_variable => "scope error",
                        .arity_mismatch => "arity error",
                        .occurs_check_failed => "type error",
                        .missing_implementation => "impl error",
                        .recursive_type => "type error",
                        .non_exhaustive_match => "match error",
                        .propagate_cross_type => "type error",
                        .unsatisfied_bound => "bound error",
                    };
                    if (err.line > 0) {
                        stderr_writer.interface.print("{s}:{d}:{d}: {s}: {s}\n", .{ module_name, err.line, err.column, kind_str, err.message }) catch {};
                    } else {
                        stderr_writer.interface.print("{s}: {s}: {s}\n", .{ module_name, kind_str, err.message }) catch {};
                    }
                }
                stderr_writer.flush() catch {};
            }
            // 文档 D45: 先检查后求值 — 类型检查不通过则阻止求值
            return;
        }

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
            // 文档 D13: 入口点默认 Main.main，像 Java/Go 一样
            // 顶层裸表达式语句（如 println(...)）不执行，只有 fun main() 内的代码才执行
            // val/var 定义仍需求值（类似 Go 的包级变量初始化）
            if (decl == .expr_decl and decl.expr_decl.stmt == null) {
                continue;
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
                        // 文档 4.4.1 / 4.4.4: ADT 构造器默认私有
                        // pub type 公开类型名但隐藏构造器，实现抽象数据类型
                        // 外部只能通过模块提供的 pub fun 创建
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
                                // 构造器始终私有（文档 4.4.1: ADT 构造器私有）
                                try environment.defineWithVisibility(con.name, Value{ .adt = av }, true, false);
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
                                // 构造器始终私有（文档 4.4.1: ADT 构造器私有）
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
                                } }, true, false);
                            }
                        }
                    },
                    .record => |rec_def| {
                        // 注册记录类型构造器
                        // type User = (name: String, age: i32)
                        // User("Alice", 30) 创建记录值 {name: "Alice", age: 30}
                        const ctx = try self.allocator.create(RecordConstructorCtx);
                        ctx.* = .{
                            .type_name = try self.allocator.dupe(u8, td.name),
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
                                    return Value{ .record = .{ .type_name = try ev.allocator.dupe(u8, data.type_name), .fields = map } };
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
                // 文档 2.7.2: 子 Trait 自动拥有所有父 Trait 的方法，默认方法从父 Trait 继承
                var method_names = std.ArrayList(u8).empty;
                defer method_names.deinit(self.allocator);
                var default_methods = std.StringHashMap(*value.Closure).init(self.allocator);
                // 文档 2.7.2: override 方法名集合，仅 override 可覆盖父 Trait impl
                var override_method_names = std.StringHashMap(void).init(self.allocator);
                // 文档 2.7.2: 委托方法名集合，委托方法也可覆盖父 Trait impl
                var delegate_method_names = std.StringHashMap(void).init(self.allocator);
                // 文档 2.7.2: 委托信息（方法名 -> DelegateEntry），运行时动态查找
                var delegate_info_map = std.StringHashMap(DelegateEntry).init(self.allocator);
                // 冲突检测：记录每个方法名来自哪个父 Trait
                var method_sources = std.StringHashMap([]const u8).init(self.allocator);
                defer method_sources.deinit();

                // 先合并父 Trait 的方法名和默认方法
                for (td.parents) |parent| {
                    if (self.trait_registry.getPtr(parent.trait_name)) |parent_info| {
                        // 合并父 Trait 的方法名
                        if (parent_info.method_names.len > 0) {
                            if (method_names.items.len > 0) {
                                try method_names.append(self.allocator, 0);
                            }
                            try method_names.appendSlice(self.allocator, parent_info.method_names);
                        }
                        // 合并父 Trait 的默认方法（子 Trait 可覆写）
                        var dm_iter = parent_info.default_methods.iterator();
                        while (dm_iter.next()) |dm_entry| {
                            const name_copy = try self.allocator.dupe(u8, dm_entry.key_ptr.*);
                            try default_methods.put(name_copy, dm_entry.value_ptr.*);
                            // 记录方法来源
                            const src_copy = try self.allocator.dupe(u8, parent.trait_name);
                            try method_sources.put(name_copy, src_copy);
                        }
                    }
                }

                // 处理子 Trait 自身的方法声明
                // 文档 2.7.2: 冲突消解 — 委托(=)、重命名、override
                for (td.methods) |method| {
                    // 方法名以 \0 分隔存储
                    if (method_names.items.len > 0) {
                        try method_names.append(self.allocator, 0);
                    }
                    try method_names.appendSlice(self.allocator, method.name);

                    if (method.delegate) |del| {
                        // 委托语法：fun to_string(self): str = Serializable.to_string
                        // 文档 2.7.2: 委托方法在运行时动态查找父 Trait 的 impl 方法
                        // 不再静态绑定闭包，而是存储委托信息供运行时查找
                        try delegate_method_names.put(try self.allocator.dupe(u8, method.name), {});
                        const method_name = try self.allocator.dupe(u8, method.name);
                        try delegate_info_map.put(method_name, DelegateEntry{
                            .target_trait = try self.allocator.dupe(u8, del.trait_name),
                            .target_method = try self.allocator.dupe(u8, del.method_name),
                        });
                        // 更新方法来源
                        const src_copy = try self.allocator.dupe(u8, del.trait_name);
                        try method_sources.put(method_name, src_copy);
                        // 重命名：方法名与委托方法名不同时（如 fun debug_string = Debug.to_string）
                        // 此时方法名是 method.name，但实现来自 del.trait_name.del.method_name
                    } else if (method.body) |body| {
                        // 有方法体的方法（含 override）
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
                        // 文档 2.7.2: override 方法标记，仅 override 可覆盖父 Trait impl
                        if (method.is_override) {
                            try override_method_names.put(try self.allocator.dupe(u8, method.name), {});
                        }
                        // override 或有 body 的方法覆盖冲突
                        const src_copy = try self.allocator.dupe(u8, td.name);
                        try method_sources.put(method_name, src_copy);
                    }
                    // 无 body 且无 delegate 的方法是抽象方法，不需要默认实现
                }

                // 冲突检测：检查是否有来自不同父 Trait 的同名方法未被消解
                // 文档 2.7.2: 当多个父 Trait 有同名方法时，必须显式处理（委托/重命名/override）
                {
                    // 收集每个方法名来自的所有父 Trait
                    var method_all_sources = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
                    defer {
                        var mas_iter = method_all_sources.iterator();
                        while (mas_iter.next()) |entry| {
                            entry.value_ptr.deinit(self.allocator);
                        }
                        method_all_sources.deinit();
                    }

                    // 从父 Trait 的默认方法中收集来源
                    for (td.parents) |parent| {
                        if (self.trait_registry.getPtr(parent.trait_name)) |parent_info| {
                            var dm_iter2 = parent_info.default_methods.iterator();
                            while (dm_iter2.next()) |dm_entry| {
                                const mname = dm_entry.key_ptr.*;
                                if (method_all_sources.getPtr(mname)) |sources| {
                                    sources.append(self.allocator, parent.trait_name) catch {};
                                } else {
                                    var new_list = std.ArrayList([]const u8).empty;
                                    new_list.append(self.allocator, parent.trait_name) catch {};
                                    const name_copy = self.allocator.dupe(u8, mname) catch return;
                                    method_all_sources.put(name_copy, new_list) catch return;
                                }
                            }
                        }
                    }

                    // 检查未消解的冲突
                    var conflict_iter = method_all_sources.iterator();
                    while (conflict_iter.next()) |entry| {
                        const mname = entry.key_ptr.*;
                        const sources = entry.value_ptr.*;
                        // 只有来自多个不同父 Trait 的同名方法才是冲突
                        if (sources.items.len < 2) continue;
                        // 检查是否已被消解（override/delegate/有 body 的方法）
                        if (method_sources.get(mname)) |src| {
                            if (std.mem.eql(u8, src, td.name)) continue; // 已被消解
                        }
                        // 未消解的冲突 — 报错
                        const first = sources.items[0];
                        const second = sources.items[1];
                        if (self.io) |io| {
                            var err_buf: [4096]u8 = undefined;
                            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
                            stderr_writer.interface.print("{s}: error: unresolved conflict for method '{s}' — inherited from both {s} and {s}; use delegation, renaming, or override to resolve\n", .{ td.name, mname, first, second }) catch {};
                            stderr_writer.flush() catch {};
                        }
                    }
                }

                // 存储父 Trait 名称列表
                var parent_names = std.ArrayList([]const u8).empty;
                defer parent_names.deinit(self.allocator);
                for (td.parents) |parent| {
                    const name_copy = try self.allocator.dupe(u8, parent.trait_name);
                    try parent_names.append(self.allocator, name_copy);
                }

                const owned_name = try self.allocator.dupe(u8, td.name);
                const owned_method_names = try method_names.toOwnedSlice(self.allocator);
                const owned_parent_names = try parent_names.toOwnedSlice(self.allocator);
                // 关联类型名称
                var assoc_type_names = std.ArrayList(u8).empty;
                defer assoc_type_names.deinit(self.allocator);
                for (td.associated_types) |at| {
                    if (assoc_type_names.items.len > 0) {
                        try assoc_type_names.append(self.allocator, 0);
                    }
                    try assoc_type_names.appendSlice(self.allocator, at.name);
                }
                const owned_assoc_type_names = try assoc_type_names.toOwnedSlice(self.allocator);
                const trait_key = try self.allocator.dupe(u8, td.name);
                try self.trait_registry.put(trait_key, TraitInfo{
                    .name = owned_name,
                    .method_names = owned_method_names,
                    .default_methods = default_methods,
                    .parent_names = owned_parent_names,
                    .associated_type_names = owned_assoc_type_names,
                    .override_methods = override_method_names,
                    .delegate_methods = delegate_method_names,
                    .delegate_infos = delegate_info_map,
                });
                try self.trait_definition_order.append(self.allocator, try self.allocator.dupe(u8, td.name));
            },
            .impl_decl => |id| {
                // 注册 Impl 声明
                // 为每个有方法体的方法创建闭包并注册到 impl_methods
                // 文档 2.7.2: impl 未覆写的默认方法自动从 trait 继承

                // 文档 2.7.7: Overlapping Instances 禁止
                if (id.type_name.len > 0) {
                    const impl_key = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ id.trait_name, id.type_name });
                    if (self.registered_impls.contains(impl_key)) {
                        // Overlapping instance — 类型推断器会报错阻止求值
                        // 此处仅做防御性检查
                        self.allocator.free(impl_key);
                        return error.TypeMismatch;
                    }
                    try self.registered_impls.put(impl_key, {});

                    // 文档 2.7.4: 关联类型定义注册到 impl_registry
                    var associated_types = std.StringHashMap([]const u8).init(self.allocator);
                    for (id.associated_type_defs) |atd| {
                        const at_name = try self.allocator.dupe(u8, atd.name);
                        const at_type = try self.allocator.dupe(u8, switch (atd.actual_type.*) {
                            .named => |n| n.name,
                            .generic => |g| g.name,
                            else => "?",
                        });
                        try associated_types.put(at_name, at_type);
                    }
                    const impl_info_key = try self.allocator.dupe(u8, impl_key);
                    try self.impl_registry.put(impl_info_key, ImplInfo{
                        .trait_name = try self.allocator.dupe(u8, id.trait_name),
                        .type_name = try self.allocator.dupe(u8, id.type_name),
                        .associated_types = associated_types,
                    });
                }

                // 收集 impl 中已覆写的方法名
                var overridden_methods = std.StringHashMap(void).init(self.allocator);
                defer overridden_methods.deinit();

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
                            .type_name = try self.allocator.dupe(u8, id.type_name),
                            .method_name = try self.allocator.dupe(u8, method.name),
                            .closure = closure,
                        });

                        // 同时将方法注册为环境中的函数（支持直接调用）
                        // 方法可见性由 MethodDecl.visibility 决定
                        try environment.defineWithVisibility(method.name, Value{ .closure = closure }, true, method.visibility == .public);

                        // 记录已覆写的方法名
                        const name_copy = try self.allocator.dupe(u8, method.name);
                        try overridden_methods.put(name_copy, {});
                    }
                }

                // 将 trait 的默认方法注册到环境中（impl 未覆写的部分）
                // 文档 2.7.2: 子 Trait 自动拥有所有父 Trait 的方法
                if (self.trait_registry.getPtr(id.trait_name)) |trait_info| {
                    var dm_iter = trait_info.default_methods.iterator();
                    while (dm_iter.next()) |dm_entry| {
                        // 仅注册 impl 未覆写的默认方法
                        if (!overridden_methods.contains(dm_entry.key_ptr.*)) {
                            // 检查环境中是否已有同名函数（避免覆盖其他 impl 的方法）
                            if (environment.get(dm_entry.key_ptr.*) == null) {
                                try environment.defineWithVisibility(dm_entry.key_ptr.*, Value{ .closure = dm_entry.value_ptr.* }, true, true);
                            }
                        }
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
            .pack_decl => |pd| {
                // 文档 4.2-4.3: pack.glue 中的子模块声明
                // pub pack Name — 公开子模块，公开成员合并到父模块命名空间
                // pack Name — 私有子模块，仅注册模块名
                const sub_module_name = pd.name;

                // 检查子模块是否已加载
                if (!self.loaded_modules.contains(sub_module_name)) {
                    // 构建子模块路径
                    const module_path = try self.allocator.alloc([]const u8, 1);
                    module_path[0] = sub_module_name;
                    self.loadModuleFromFile(module_path) catch |err| switch (err) {
                        error.FileNotFound => {
                            // 子模块文件不存在，跳过
                        },
                        else => return err,
                    };
                }

                // 从模块导出表中获取子模块的公开声明
                if (self.module_exports.getPtr(sub_module_name)) |export_info| {
                    if (pd.visibility == .public) {
                        // pub pack: 子模块的公开成员合并到当前环境
                        var iter = export_info.env.values.iterator();
                        while (iter.next()) |entry| {
                            if (entry.value_ptr.is_public) {
                                // 避免覆盖已有定义
                                if (environment.get(entry.key_ptr.*) == null) {
                                    try environment.defineWithVisibility(entry.key_ptr.*, entry.value_ptr.value, false, true);
                                }
                            }
                        }
                    }
                    // 私有 pack: 子模块已加载到 module_exports，但不合并到当前环境
                    // 可通过 use SubModule 显式导入
                }
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
            .record_extend => |re| self.evalRecordExtend(re, environment),
            .lambda => |lam| self.evalLambda(lam, environment),
            .if_expr => |ie| return self.evalIfExpr(ie, environment),
            .block => |blk| return self.evalBlock(blk, environment),
            .match => |m| self.evalMatch(m, environment),
            .type_cast => |tc| self.evalTypeCast(tc, environment),
            .spawn => |sp| self.evalSpawn(sp, environment),
            .atomic_expr => |ae| self.evalAtomicExpr(ae, environment),
            .lazy => error.UnsupportedOperation,
            .select => |sel| self.evalSelect(sel, environment),
            .monad_comprehension => error.UnsupportedOperation,
            .inline_trait_value => error.UnsupportedOperation,
        };
    }

    fn evalIntLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        // 解析整数值
        const int_val = parseInt(i128, raw) catch
            return self.gluePanic("arithmetic overflow: integer literal out of range");

        // 如果有类型后缀，检查范围
        if (suffix) |s| {
            return self.castInteger(int_val, .i32, s);
        }

        // 默认 i32
        return self.castInteger(int_val, .i32, "i32");
    }

    fn evalFloatLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        const float_val = parseFloat(f64, raw) catch
            return self.gluePanic("invalid floating-point literal");

        // 文档要求：浮点数不包含 NaN 和 Infinity 值
        if (std.math.isNan(float_val) or std.math.isInf(float_val)) {
            return self.gluePanic("arithmetic overflow: floating-point literal out of range");
        }

        if (suffix) |s| {
            if (std.mem.eql(u8, s, "f32")) {
                const f32_val: f32 = @floatCast(float_val);
                if (std.math.isNan(f32_val) or std.math.isInf(f32_val)) {
                    return self.gluePanic("arithmetic overflow: floating-point literal out of range");
                }
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
                    try val.format(&buf, self.allocator, false);
                    try result.appendSlice(self.allocator, buf.items);
                },
            }
        }

        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    fn evalIdentifier(self: *Evaluator, id: @TypeOf(@as(ast.Expr, undefined).identifier), environment: *Environment) EvalResult!Value {
        if (environment.get(id.name)) |v| {
            // Atomic<T> 透明操作：读取时使用 atomic_load
            if (v.value == .atomic_val) {
                return v.value.atomic_val.load();
            }
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
            .index => |idx| {
                const object = try self.evalExpr(idx.object, environment);
                const index_val = try self.evalExpr(idx.index, environment);
                switch (object) {
                    .array => |*arr| {
                        const i = try index_val.asInteger();
                        if (i < 0 or i >= @as(i128, @intCast(arr.elements.len))) {
                            return error.IndexOutOfBounds;
                        }
                        arr.elements[@as(usize, @intCast(i))] = val;
                    },
                    else => return error.TypeMismatch,
                }
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
            .bit_and => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value & right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("位运算 & 要求整数操作数");
            },
            .bit_or => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value | right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("位运算 | 要求整数操作数");
            },
            .bit_xor => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value ^ right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("位运算 ^ 要求整数操作数");
            },
            else => unreachable,
        }
    }

    /// 检查浮点运算结果是否为 NaN 或 Infinity，若是则 panic，否则返回 Value
    fn checkFloatResult(self: *Evaluator, result: f64) EvalResult!Value {
        if (std.math.isNan(result) or std.math.isInf(result)) {
            return self.gluePanic("arithmetic overflow: floating-point operation out of range");
        }
        return Value{ .float = result };
    }

    fn evalAdd(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result_type = left.integer.type_tag;
            const result = left.integer.value + right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float + right.float);
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(@as(f64, @floatFromInt(left.integer.value)) + right.float);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float + @as(f64, @floatFromInt(right.integer.value)));
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
            const result_type = left.integer.type_tag;
            const result = left.integer.value - right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float - right.float);
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(@as(f64, @floatFromInt(left.integer.value)) - right.float);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float - @as(f64, @floatFromInt(right.integer.value)));
        }
        return error.TypeMismatch;
    }

    fn evalMul(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result_type = left.integer.type_tag;
            const result = left.integer.value * right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float * right.float);
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(@as(f64, @floatFromInt(left.integer.value)) * right.float);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float * @as(f64, @floatFromInt(right.integer.value)));
        }
        return error.TypeMismatch;
    }

    fn evalDiv(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            // 检查 i128 最小值 / -1 溢出
            if (left.integer.value == std.math.minInt(i128) and right.integer.value == -1) {
                return self.gluePanic("arithmetic overflow: integer operation out of range");
            }
            const result_type = left.integer.type_tag;
            const result = @divTrunc(left.integer.value, right.integer.value);
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(left.float / right.float);
        }
        if (left == .integer and right == .float) {
            if (right.float == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(@as(f64, @floatFromInt(left.integer.value)) / right.float);
        }
        if (left == .float and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(left.float / @as(f64, @floatFromInt(right.integer.value)));
        }
        return error.TypeMismatch;
    }

    fn evalMod(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            const result_type = left.integer.type_tag;
            const result = @mod(left.integer.value, right.integer.value);
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(@mod(left.float, right.float));
        }
        return error.TypeMismatch;
    }

    fn evalLt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer.value < right.integer.value };
        if (left == .float and right == .float) return Value{ .boolean = left.float < right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer.value)) < right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float < @as(f64, @floatFromInt(right.integer.value)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val < right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .lt };
        return error.TypeMismatch;
    }

    fn evalGt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer.value > right.integer.value };
        if (left == .float and right == .float) return Value{ .boolean = left.float > right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer.value)) > right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float > @as(f64, @floatFromInt(right.integer.value)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val > right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .gt };
        return error.TypeMismatch;
    }

    fn evalLtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer.value <= right.integer.value };
        if (left == .float and right == .float) return Value{ .boolean = left.float <= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer.value)) <= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float <= @as(f64, @floatFromInt(right.integer.value)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val <= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .gt };
        return error.TypeMismatch;
    }

    fn evalGtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer.value >= right.integer.value };
        if (left == .float and right == .float) return Value{ .boolean = left.float >= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer.value)) >= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float >= @as(f64, @floatFromInt(right.integer.value)) };
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
                .integer => |iv| {
                    const result_type = iv.type_tag;
                    const result = -iv.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                },
                .float => |f| {
                    return self.checkFloatResult(-f);
                },
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
                        error.MissingMain => return error.MissingMain,
                        else => return error.UnsupportedOperation,
                    }
                };
                return result;
            },
            else => return error.NotCallable,
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: @TypeOf(@as(ast.Expr, undefined).method_call), environment: *Environment) EvalResult!Value {
        // 文档 §3.4.2: Atomic<T> 方法调用时，不进行透明 atomic_load
        // 需要获取原始 Atomic/Channel/Sender/Receiver 值作为方法接收者
        const object = switch (mc.object.*) {
            .identifier => |id| raw_val: {
                if (environment.get(id.name)) |v| {
                    // 对并发原语类型，直接返回原始值（不做透明解包）
                    if (v.value == .atomic_val or v.value == .channel_val or v.value == .sender_val or v.value == .receiver_val or v.value == .spawn_val) {
                        break :raw_val v.value;
                    }
                }
                break :raw_val try self.evalExpr(mc.object, environment);
            },
            .field_access => |fa| raw_val: {
                const obj = try self.evalExpr(fa.object, environment);
                const field_val = self.accessField(obj, fa.field) catch break :raw_val try self.evalExpr(mc.object, environment);
                break :raw_val field_val;
            },
            else => try self.evalExpr(mc.object, environment),
        };

        // 求值参数
        var args = std.ArrayList(Value).empty;
        for (mc.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存
        defer args.deinit(self.allocator);

        return self.callMethod(object, mc.method, args.items, environment);
    }

    /// 检查接收者类型是否实现了指定 trait 的所有父 Trait
    /// 文档 2.7.2: 子 Trait 的 override 方法仅在接收者类型实现了所有父 Trait 时生效
    fn hasAllParentImpls(self: *Evaluator, trait_name: []const u8, obj_type_name: ?[]const u8) bool {
        const trait_info = self.trait_registry.getPtr(trait_name) orelse return false;
        if (obj_type_name) |otn| {
            // 检查每个父 Trait 是否有对应的 impl
            for (trait_info.parent_names) |parent_name| {
                var found = false;
                for (self.impl_methods.items) |impl_entry| {
                    if (std.mem.eql(u8, impl_entry.trait_name, parent_name) and
                        (impl_entry.type_name.len == 0 or std.mem.eql(u8, impl_entry.type_name, otn)))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }
        return false;
    }

    /// 从运行时值推断类型名（用于 impl 方法分派）
    /// 文档 2.7.1: impl Comparable<i32> 中的 i32 是目标类型
    /// 运行时需要判断接收者的类型名，以匹配正确的 impl
    fn valueTypeName(val: Value) ?[]const u8 {
        return switch (val) {
            .integer => |iv| @tagName(iv.type_tag),
            .float => "f64",
            .boolean => "bool",
            .char_val => "char",
            .string => "str",
            .null_val => "null",
            .unit => "unit",
            .array => "array",
            .record => "record",
            .adt => |av| av.type_name,
            .newtype => |nv| nv.type_name,
            .range => "range",
            .error_val => |e| e.type_name,
            .throw_val => "Throw",
            .closure, .builtin => null,
            .array_iterator => "array_iterator",
            .string_iterator => "string_iterator",
            .range_iterator => "range_iterator",
            .atomic_val => "Atomic",
            .spawn_val => "Spawn",
            .channel_val => "Channel",
            .sender_val => "Sender",
            .receiver_val => "Receiver",
        };
    }

    fn callMethod(self: *Evaluator, object: Value, method: []const u8, args: []const Value, environment: ?*Environment) EvalResult!Value {
        // 内建方法
        if (std.mem.eql(u8, method, "len")) {
            return switch (object) {
                .string => |s| {
                    // len() 返回 Unicode 标量值（字符数），而非字节数
                    const view = std.unicode.Utf8View.init(s) catch {
                        return Value{ .integer = IntValue{ .value = @as(i128, @intCast(s.len)) } };
                    };
                    var count: i128 = 0;
                    var iter = view.iterator();
                    while (iter.nextCodepoint() != null) {
                        count += 1;
                    }
                    return Value{ .integer = IntValue{ .value = count } };
                },
                .array => |arr| Value{ .integer = IntValue{ .value = @as(i128, @intCast(arr.elements.len)) } },
                else => error.TypeMismatch,
            };
        }

        // 动态数组方法（T[]）
        if (std.mem.eql(u8, method, "push")) {
            return switch (object) {
                .array => |arr| {
                    // push: 追加元素，返回新数组
                    // 文档：var 与值语义——支持重新赋值和原地修改
                    // 用法：var arr = [1, 2]; arr = arr.push(3)
                    if (args.len != 1) return error.WrongArity;
                    var new_arr = try self.allocator.alloc(Value, arr.elements.len + 1);
                    @memcpy(new_arr[0..arr.elements.len], arr.elements);
                    new_arr[arr.elements.len] = try args[0].clone(self.allocator);
                    return Value{ .array = .{ .elements = new_arr, .fixed_size = null } };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "pop")) {
            return switch (object) {
                .array => |arr| {
                    // pop: 弹出最后一个元素，返回 T?
                    if (arr.elements.len == 0) return Value.null_val;
                    return try arr.elements[arr.elements.len - 1].clone(self.allocator);
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "contains")) {
            return switch (object) {
                .array => |arr| {
                    // contains: 检查是否包含元素（结构相等）
                    if (args.len != 1) return error.WrongArity;
                    for (arr.elements) |item| {
                        if (structuralEquals(item, args[0])) {
                            return Value{ .boolean = true };
                        }
                    }
                    return Value{ .boolean = false };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "isEmpty")) {
            return switch (object) {
                .array => |arr| Value{ .boolean = arr.elements.len == 0 },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "first")) {
            return switch (object) {
                .array => |arr| {
                    if (arr.elements.len == 0) return Value.null_val;
                    return try arr.elements[0].clone(self.allocator);
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "last")) {
            return switch (object) {
                .array => |arr| {
                    if (arr.elements.len == 0) return Value.null_val;
                    return try arr.elements[arr.elements.len - 1].clone(self.allocator);
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "drop_last")) {
            return switch (object) {
                .array => |arr| {
                    // drop_last: 返回去掉最后一个元素的新数组
                    if (arr.elements.len == 0) return Value{ .array = arr };
                    const new_arr = try self.allocator.alloc(Value, arr.elements.len - 1);
                    @memcpy(new_arr, arr.elements[0 .. arr.elements.len - 1]);
                    return Value{ .array = .{ .elements = new_arr, .fixed_size = null } };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "toString")) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);
            try object.format(&buf, self.allocator, false);
            return Value{ .string = try buf.toOwnedSlice(self.allocator) };
        }

        // Iterable/Iterator 协议方法
        if (std.mem.eql(u8, method, "iterator")) {
            return switch (object) {
                .array => |arr| {
                    const iter = try self.allocator.create(value.ArrayIterator);
                    iter.* = .{ .array = arr.elements, .index = 0 };
                    return Value{ .array_iterator = iter };
                },
                .string => |s| {
                    const iter = try self.allocator.create(value.StringIterator);
                    iter.* = .{ .string = s, .byte_offset = 0 };
                    return Value{ .string_iterator = iter };
                },
                .range => |r| {
                    const iter = try self.allocator.create(value.RangeIterator);
                    iter.* = .{ .current = r.start, .end = r.end, .inclusive = r.inclusive };
                    return Value{ .range_iterator = iter };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "next")) {
            return switch (object) {
                .array_iterator => |ai| {
                    if (ai.index < ai.array.len) {
                        const val = ai.array[ai.index];
                        ai.index += 1;
                        return val;
                    }
                    return Value.null_val;
                },
                .string_iterator => |si| {
                    if (si.byte_offset >= si.string.len) return Value.null_val;
                    const remaining = si.string[si.byte_offset..];
                    const view = std.unicode.Utf8View.init(remaining) catch {
                        // 无效 UTF-8，回退到字节迭代
                        const byte = remaining[0];
                        si.byte_offset += 1;
                        return Value{ .char_val = @as(u21, @intCast(byte)) };
                    };
                    var iter = view.iterator();
                    if (iter.nextCodepoint()) |codepoint| {
                        si.byte_offset += std.unicode.utf8CodepointSequenceLength(codepoint) catch 1;
                        return Value{ .char_val = codepoint };
                    }
                    return Value.null_val;
                },
                .range_iterator => |ri| {
                    if (ri.inclusive) {
                        if (ri.current <= ri.end) {
                            const val = ri.current;
                            ri.current += 1;
                            return Value{ .integer = IntValue{ .value = val } };
                        }
                    } else {
                        if (ri.current < ri.end) {
                            const val = ri.current;
                            ri.current += 1;
                            return Value{ .integer = IntValue{ .value = val } };
                        }
                    }
                    return Value.null_val;
                },
                else => error.TypeMismatch,
            };
        }

        // 记录方法 — 在记录中查找方法字段
        if (object == .record) {
            if (object.record.fields.get(method)) |val| {
                return self.callFunction(val, args, environment);
            }
        }

        // Impl 方法分派 — 搜索已注册的 impl 方法
        // 文档 2.7.1: impl Comparable<i32> 定义的方法仅在接收者为 i32 时分派
        // 必须同时匹配 method_name 和接收者类型
        // 文档 2.7.2: 子 Trait 的 override 方法优先于父 Trait 的 impl 方法
        const obj_type_name = valueTypeName(object);

        // 子 Trait 方法分派 — 搜索组合 Trait 的方法覆盖
        // 文档 2.7.2: 在单个 Trait 组合内，override > 委托 > 父 Trait impl
        // 非 override 的 body 方法不能覆盖父 Trait impl（必须用 override 或委托）
        // 当多个 Trait 组合同时匹配时，后定义的优先（覆盖先定义的）
        {
            var best_result: ?Value = null;
            // 按定义顺序遍历 Trait，后定义的覆盖先定义的
            for (self.trait_definition_order.items) |trait_name| {
                const trait_info = self.trait_registry.getPtr(trait_name) orelse continue;
                if (trait_info.parent_names.len == 0) continue;
                if (!self.hasAllParentImpls(trait_name, obj_type_name)) continue;

                // 在此 Trait 组合内按优先级查找方法
                // 1) override 方法 — 覆盖父 Trait impl
                if (trait_info.override_methods.contains(method)) {
                    if (trait_info.default_methods.get(method)) |closure| {
                        var full_args = std.ArrayList(Value).empty;
                        try full_args.append(self.allocator, object);
                        for (args) |arg| {
                            try full_args.append(self.allocator, arg);
                        }
                        defer full_args.deinit(self.allocator);
                        best_result = self.callFunction(Value{ .closure = closure }, full_args.items, environment) catch |err| {
                            if (err == error.RecursionDetected) return err;
                            best_result = null;
                            continue;
                        };
                        continue;
                    }
                }
                // 2) 委托方法 — 运行时动态查找父 Trait 的 impl 方法
                if (trait_info.delegate_methods.contains(method)) {
                    if (trait_info.delegate_infos.get(method)) |del_info| {
                        if (obj_type_name) |otn| {
                            for (self.impl_methods.items) |impl_entry| {
                                if (std.mem.eql(u8, impl_entry.trait_name, del_info.target_trait) and
                                    std.mem.eql(u8, impl_entry.method_name, del_info.target_method) and
                                    (impl_entry.type_name.len == 0 or std.mem.eql(u8, impl_entry.type_name, otn)))
                                {
                                    var full_args = std.ArrayList(Value).empty;
                                    try full_args.append(self.allocator, object);
                                    for (args) |arg| {
                                        try full_args.append(self.allocator, arg);
                                    }
                                    defer full_args.deinit(self.allocator);
                                    best_result = self.callFunction(Value{ .closure = impl_entry.closure }, full_args.items, environment) catch |err| {
                                        if (err == error.RecursionDetected) return err;
                                        best_result = null;
                                        break;
                                    };
                                    break;
                                }
                            }
                        }
                        continue;
                    }
                }
                // 注意：非 override、非委托的 body 方法不能覆盖父 Trait impl
                // 类型检查器已确保同名方法必须加 override 或使用委托
            }
            if (best_result) |result| return result;
        }

        for (self.impl_methods.items) |entry| {
            if (std.mem.eql(u8, entry.method_name, method)) {
                // 检查接收者类型是否匹配 impl 的目标类型
                // type_name 为空字符串时表示未指定类型（兼容旧语法）
                if (entry.type_name.len == 0) {
                    // 未指定类型，按方法名匹配（向后兼容）
                } else if (obj_type_name) |otn| {
                    if (!std.mem.eql(u8, entry.type_name, otn)) {
                        // 接收者类型不匹配，跳过此 impl
                        continue;
                    }
                } else {
                    // 无法确定接收者类型，跳过此 impl
                    continue;
                }
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

        // Trait 默认方法分派 — impl 未覆写时回退到 trait 默认实现
        // 文档 2.7.2: 子 Trait 自动拥有所有父 Trait 的方法，默认方法在 impl 未覆写时自动使用
        // 必须检查接收者类型是否有对应的 impl 注册
        {
            var trait_iter = self.trait_registry.iterator();
            while (trait_iter.next()) |entry| {
                if (entry.value_ptr.default_methods.get(method)) |closure| {
                    // 检查接收者类型是否有该 trait 的 impl（任何方法）
                    const trait_name = entry.key_ptr.*;
                    var has_matching_impl = false;
                    if (obj_type_name) |otn| {
                        for (self.impl_methods.items) |impl_entry| {
                            if (std.mem.eql(u8, impl_entry.trait_name, trait_name) and
                                (impl_entry.type_name.len == 0 or std.mem.eql(u8, impl_entry.type_name, otn)))
                            {
                                has_matching_impl = true;
                                break;
                            }
                        }
                    }
                    if (!has_matching_impl) continue;
                    var full_args = std.ArrayList(Value).empty;
                    try full_args.append(self.allocator, object);
                    for (args) |arg| {
                        try full_args.append(self.allocator, arg);
                    }
                    defer full_args.deinit(self.allocator);
                    return self.callFunction(Value{ .closure = closure }, full_args.items, environment);
                }
            }
        }

        // ============================================================
        // 并发原语方法分派
        // ============================================================

        // Spawn<T> 方法
        if (object == .spawn_val) {
            const handle = object.spawn_val;
            if (std.mem.eql(u8, method, "await")) {
                if (args.len != 0) return error.WrongArity;
                // 阻塞等待完成
                handle.mutex.lockUncancelable(handle.io);
                while (handle.status.load(.seq_cst) == .Pending or handle.status.load(.seq_cst) == .Running) {
                    handle.condition.waitUncancelable(handle.io, &handle.mutex);
                }
                const result = handle.result;
                handle.consumed.store(true, .seq_cst);
                handle.mutex.unlock(handle.io);
                // 等待线程结束
                if (handle.thread) |t| {
                    t.join();
                    handle.thread = null;
                }
                if (handle.status.load(.seq_cst) == .Failed) {
                    return self.gluePanic("spawn: coroutine failed");
                }
                return result orelse Value.unit;
            }
            if (std.mem.eql(u8, method, "cancel")) {
                if (args.len != 0) return error.WrongArity;
                handle.mutex.lockUncancelable(handle.io);
                handle.status.store(.Cancelled, .seq_cst);
                handle.consumed.store(true, .seq_cst);
                handle.condition.broadcast(handle.io);
                handle.mutex.unlock(handle.io);
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "status")) {
                if (args.len != 0) return error.WrongArity;
                const s = handle.status.load(.seq_cst);
                // 返回 SpawnStatus ADT 值
                return self.makeSpawnStatus(s);
            }
            if (std.mem.eql(u8, method, "result")) {
                if (args.len != 0) return error.WrongArity;
                handle.mutex.lockUncancelable(handle.io);
                if (handle.status.load(.seq_cst) == .Completed) {
                    const r = handle.result;
                    handle.mutex.unlock(handle.io);
                    return r orelse Value.null_val;
                }
                handle.mutex.unlock(handle.io);
                return Value.null_val;
            }
        }

        // Channel<T> 方法
        if (object == .channel_val) {
            const ch = object.channel_val;
            if (std.mem.eql(u8, method, "send")) {
                if (args.len != 1) return error.WrongArity;
                const ok = ch.send(args[0]) catch return error.OutOfMemory;
                if (!ok) return self.gluePanic("channel: send on closed channel");
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "recv")) {
                if (args.len != 0) return error.WrongArity;
                const val = ch.recv();
                return val orelse Value.null_val;
            }
            if (std.mem.eql(u8, method, "close")) {
                if (args.len != 0) return error.WrongArity;
                ch.close();
                return Value.unit;
            }
        }

        // Sender<T> 方法
        if (object == .sender_val) {
            const sv = object.sender_val;
            if (std.mem.eql(u8, method, "send")) {
                if (args.len != 1) return error.WrongArity;
                const ok = sv.channel.send(args[0]) catch return error.OutOfMemory;
                if (!ok) return self.gluePanic("channel: send on closed channel");
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "close")) {
                if (args.len != 0) return error.WrongArity;
                sv.channel.close();
                return Value.unit;
            }
        }

        // Receiver<T> 方法
        if (object == .receiver_val) {
            const rv = object.receiver_val;
            if (std.mem.eql(u8, method, "recv")) {
                if (args.len != 0) return error.WrongArity;
                const val = rv.channel.recv();
                return val orelse Value.null_val;
            }
        }

        // Atomic<T> 方法
        if (object == .atomic_val) {
            const av = object.atomic_val;
            if (std.mem.eql(u8, method, "cas")) {
                if (args.len != 2) return error.WrongArity;
                const expected = try args[0].asInteger();
                const new_val = try args[1].asInteger();
                return Value{ .boolean = av.cas(expected, new_val) };
            }
            if (std.mem.eql(u8, method, "swap")) {
                if (args.len != 1) return error.WrongArity;
                const new_val = try args[0].asInteger();
                const old_raw = av.xchg(new_val);
                return Value{ .integer = IntValue{ .value = old_raw, .type_tag = value.atomicTypeToIntType(av.type_tag) } };
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
            .record => |rec| {
                if (rec.fields.get(field)) |val| {
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
            // Channel 方向类型字段访问
            .channel_val => |cv| {
                if (std.mem.eql(u8, field, "sender")) {
                    const sv = try self.allocator.create(value.SenderValue);
                    sv.* = value.SenderValue{ .channel = cv };
                    cv.ref();
                    return Value{ .sender_val = sv };
                }
                if (std.mem.eql(u8, field, "receiver")) {
                    const rv = try self.allocator.create(value.ReceiverValue);
                    rv.* = value.ReceiverValue{ .channel = cv };
                    cv.ref();
                    return Value{ .receiver_val = rv };
                }
                return error.UndefinedVariable;
            },
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
        if (val.isNull()) return self.gluePanic("non-null assertion failed on null value");
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
                if (i < 0 or i >= @as(i128, @intCast(arr.elements.len))) {
                    return error.IndexOutOfBounds;
                }
                return arr.elements[@as(usize, @intCast(i))];
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
        return Value{ .array = .{ .elements = arr, .fixed_size = null } };
    }

    fn evalRecordLiteral(self: *Evaluator, rl: @TypeOf(@as(ast.Expr, undefined).record_literal), environment: *Environment) EvalResult!Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();

        for (rl.fields) |field| {
            const key = try self.allocator.dupe(u8, field.name);
            const val = try self.evalExpr(field.value, environment);
            try map.put(key, val);
        }

        return Value{ .record = .{ .type_name = "", .fields = map } };
    }

    /// 记录扩展/更新求值
    /// Phase 3: 文档 §2.12.1 记录操作
    /// (...base, field: val) — 从 base 复制所有字段，然后用 updates 覆盖/新增
    fn evalRecordExtend(self: *Evaluator, re: @TypeOf(@as(ast.Expr, undefined).record_extend), environment: *Environment) EvalResult!Value {
        // 求值 base 表达式
        const base_val = try self.evalExpr(re.base, environment);

        // base 必须是记录
        switch (base_val) {
            .record => |base_rec| {
                // 复制 base 的所有字段
                var map = std.StringHashMap(Value).init(self.allocator);
                errdefer map.deinit();

                var iter = base_rec.fields.iterator();
                while (iter.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    try map.put(key, entry.value_ptr.*);
                }

                // 应用 updates（覆盖或新增字段）
                for (re.updates) |update| {
                    const key = try self.allocator.dupe(u8, update.name);
                    const val = try self.evalExpr(update.value, environment);
                    // 如果 key 已存在，put 会覆盖旧值
                    try map.put(key, val);
                }

                return Value{ .record = .{ .type_name = "", .fields = map } };
            },
            else => return error.TypeMismatch,
        }
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

        return self.gluePanic("non-exhaustive match: no pattern matched the scrutinee value");
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
        if (std.mem.eql(u8, type_name, "str")) {
            return self.valueToString(val);
        }
        if (val == .integer) {
            return self.castInteger(val.integer.value, val.integer.type_tag, type_name);
        }
        if (val == .float) {
            return self.castFloat(val.float, type_name);
        }
        if (val == .boolean) {
            if (std.mem.eql(u8, type_name, "str")) {
                return self.valueToString(val);
            }
            return error.TypeMismatch;
        }
        return error.TypeMismatch;
    }

    fn castInteger(self: *Evaluator, val: i128, source_type_tag: IntType, type_name: []const u8) EvalResult!Value {
        _ = source_type_tag;
        const target_type = IntType.fromName(type_name) orelse {
            // Not an integer type — try float conversion
            if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatFromInt(val)) };
            if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = @as(f64, @floatFromInt(val)) };
            return error.TypeMismatch;
        };
        if (std.mem.eql(u8, type_name, "i8")) {
            const result = clampInt(val, i8) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "i16")) {
            const result = clampInt(val, i16) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "i32")) {
            const result = clampInt(val, i32) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "i64")) {
            const result = clampInt(val, i64) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "i128")) return Value{ .integer = IntValue{ .value = val, .type_tag = target_type } };
        if (std.mem.eql(u8, type_name, "u8")) {
            const result = clampUInt(val, u8) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "u16")) {
            const result = clampUInt(val, u16) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "u32")) {
            const result = clampUInt(val, u32) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "u64")) {
            const result = clampUInt(val, u64) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        if (std.mem.eql(u8, type_name, "u128")) {
            const result = clampUInt(val, u128) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
        return error.TypeMismatch;
    }

    fn castFloat(self: *Evaluator, val: f64, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatCast(@as(f32, @floatCast(val)))) };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = val };
        if (std.mem.eql(u8, type_name, "i8")) return floatToInt(val, i8) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i16")) return floatToInt(val, i16) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i32")) return floatToInt(val, i32) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i64")) return floatToInt(val, i64) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i128")) return floatToInt(val, i128) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        return error.TypeMismatch;
    }

    fn valueToString(self: *Evaluator, val: Value) EvalResult!Value {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try val.format(&buf, self.allocator, false);
        return Value{ .string = try buf.toOwnedSlice(self.allocator) };
    }

    // ============================================================
    // spawn 表达式求值
    // ============================================================

    /// spawn 表达式求值
    /// 文档 §3.2: spawn 创建协程，立即返回 Spawn<T>，不阻塞当前代码
    /// 文档 §3.2.1: spawn 闭包深拷贝捕获，Atomic<T> 例外（浅拷贝）
    /// 当前实现：同步执行（保留深拷贝语义），避免 Evaluator 线程安全问题
    /// TODO: 后续引入线程安全 Evaluator 或 per-thread Evaluator 后启用真正并发
    fn evalSpawn(self: *Evaluator, sp: @TypeOf(@as(ast.Expr, undefined).spawn), environment: *Environment) EvalResult!Value {
        const io = self.io orelse return self.gluePanic("spawn: no IO context");

        // 深拷贝捕获环境（Atomic 例外）
        const cloned_env = try environment.deepCopy(self.allocator, null);

        // 创建 SpawnHandle
        const handle = try self.allocator.create(value.SpawnHandle);
        handle.* = value.SpawnHandle.init(self.allocator, io);

        // 同步执行 spawn body（在当前线程中执行）
        handle.status.store(.Running, .seq_cst);

        const result = self.evalExpr(sp.body, cloned_env) catch {
            handle.status.store(.Failed, .seq_cst);
            return Value{ .spawn_val = handle };
        };

        handle.mutex.lockUncancelable(handle.io);
        handle.result = result;
        handle.status.store(.Completed, .seq_cst);
        handle.condition.broadcast(handle.io);
        handle.mutex.unlock(handle.io);

        // 注册 spawn handle 到 evaluator
        try self.spawn_handles.append(self.allocator, handle);

        return Value{ .spawn_val = handle };
    }

    // ============================================================
    // atomic 表达式求值
    // ============================================================

    /// atomic 表达式求值
    /// 文档 §3.4.1: atomic expr 在堆上创建原子值，返回 Atomic<T> 引用
    /// atomic 是关键字前缀表达式，不是函数调用
    fn evalAtomicExpr(self: *Evaluator, ae: @TypeOf(@as(ast.Expr, undefined).atomic_expr), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(ae.value, environment);
        const av = try self.allocator.create(value.AtomicValue);
        switch (val) {
            .integer => |iv| {
                av.* = value.AtomicValue.initInt(iv.value, value.intTypeToAtomicType(iv.type_tag));
            },
            .float => |f| {
                av.* = value.AtomicValue.initFloat(f, .f64);
            },
            .boolean => |b| {
                av.* = value.AtomicValue.initBool(b);
            },
            .char_val => |c| {
                av.* = value.AtomicValue.initChar(c);
            },
            else => return self.gluePanic("atomic: unsupported type"),
        }
        return Value{ .atomic_val = av };
    }

    // ============================================================
    // select 表达式求值
    // ============================================================

    /// select 表达式求值
    /// 文档 §3.5.3: 多路复用通道操作
    fn evalSelect(self: *Evaluator, sel: @TypeOf(@as(ast.Expr, undefined).select), environment: *Environment) EvalResult!Value {
        // 简化实现：轮询所有接收分支，执行第一个就绪的
        // 如果没有就绪分支且有超时，执行超时分支
        // 否则阻塞等待

        // 辅助函数：从 channel_expr 中提取 Channel 值
        // 文档 §3.5.3: select arm 语法为 ch.recv() => body
        // channel_expr 可能是方法调用 ch.recv()，需要提取 ch 而非执行 recv
        const getChannelFromExpr = struct {
            fn run(ev: *Evaluator, expr: *const ast.Expr, eval_env: *Environment) EvalResult!*value.ChannelValue {
                // 如果是方法调用 ch.recv()，提取 ch
                if (expr.* == .method_call) {
                    const mc = expr.method_call;
                    if (std.mem.eql(u8, mc.method, "recv")) {
                        const obj = try ev.evalExpr(mc.object, eval_env);
                        return switch (obj) {
                            .channel_val => |cv| cv,
                            .receiver_val => |rv| rv.channel,
                            .sender_val => |sv| sv.channel,
                            else => error.TypeMismatch,
                        };
                    }
                }
                // 否则直接求值，期望得到 Channel/Sender/Receiver
                const val = try ev.evalExpr(expr, eval_env);
                return switch (val) {
                    .channel_val => |cv| cv,
                    .receiver_val => |rv| rv.channel,
                    .sender_val => |sv| sv.channel,
                    else => error.TypeMismatch,
                };
            }
        }.run;

        for (sel.arms) |arm| {
            switch (arm) {
                .receive => |recv_arm| {
                    const ch = try getChannelFromExpr(self, recv_arm.channel_expr, environment);
                    // 非阻塞尝试接收
                    if (ch.tryRecv()) |val| {
                        if (recv_arm.binding) |binding_name| {
                            try environment.define(binding_name, val, true);
                        }
                        return self.evalExpr(recv_arm.body, environment);
                    }
                },
                .timeout => continue,
            }
        }

        // 轮询未命中，检查超时分支
        for (sel.arms) |arm| {
            switch (arm) {
                .timeout => |timeout_arm| {
                    return self.evalExpr(timeout_arm.body, environment);
                },
                .receive => continue,
            }
        }

        // 没有超时分支，阻塞等待第一个就绪的通道
        for (sel.arms) |arm| {
            switch (arm) {
                .receive => |recv_arm| {
                    const ch = try getChannelFromExpr(self, recv_arm.channel_expr, environment);
                    const val = ch.recv();
                    if (val) |v| {
                        if (recv_arm.binding) |binding_name| {
                            try environment.define(binding_name, v, true);
                        }
                        return self.evalExpr(recv_arm.body, environment);
                    }
                },
                .timeout => continue,
            }
        }

        return Value.unit;
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
                    .field_access => |fa| {
                        // 处理 object.field = value 形式的赋值
                        switch (fa.object.*) {
                            .identifier => |id| {
                                if (environment.getPtr(id.name)) |variable| {
                                    if (variable.*.value == .record) {
                                        const map = &variable.*.value.record.fields;
                                        if (map.getPtr(fa.field)) |existing| {
                                            existing.* = val;
                                        } else {
                                            return error.UndefinedVariable;
                                        }
                                    } else {
                                        return error.TypeMismatch;
                                    }
                                } else {
                                    return error.UndefinedVariable;
                                }
                            },
                            else => return error.TypeMismatch,
                        }
                    },
                    .index => |idx| {
                        const object = try self.evalExpr(idx.object, environment);
                        const index_val = try self.evalExpr(idx.index, environment);
                        switch (object) {
                            .array => |*arr| {
                                const i = try index_val.asInteger();
                                if (i < 0 or i >= @as(i128, @intCast(arr.elements.len))) {
                                    return error.IndexOutOfBounds;
                                }
                                arr.elements[@as(usize, @intCast(i))] = val;
                            },
                            else => return error.TypeMismatch,
                        }
                    },
                    else => return error.TypeMismatch,
                }
                return null;
            },
            .field_assignment => |fa| {
                const val = try self.evalExpr(fa.value, environment);
                // 如果对象是标识符，直接修改环境中的变量
                switch (fa.object.*) {
                    .identifier => |id| {
                        if (environment.getPtr(id.name)) |variable| {
                            if (variable.*.value == .record) {
                                const map = &variable.*.value.record.fields;
                                if (map.getPtr(fa.field)) |existing| {
                                    existing.* = val;
                                } else {
                                    return error.UndefinedVariable;
                                }
                            } else {
                                return error.TypeMismatch;
                            }
                        } else {
                            return error.UndefinedVariable;
                        }
                    },
                    else => {
                        const object = try self.evalExpr(fa.object, environment);
                        switch (object) {
                            .record => |*rec| {
                                if (rec.fields.getPtr(fa.field)) |existing| {
                                    existing.* = val;
                                } else {
                                    return error.UndefinedVariable;
                                }
                            },
                            else => return error.TypeMismatch,
                        }
                    },
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
        var iterable = try self.evalExpr(fs.iterable, environment);

        // 整数作为范围上限（0..n）的语法糖，转换为 Range
        if (iterable == .integer) {
            const range_end = iterable.integer.value;
            if (range_end < 0) return null;
            iterable = Value{ .range = Range{ .start = 0, .end = range_end, .inclusive = false } };
        }

        // 所有类型统一通过 Iterable/Iterator 协议
        // for item in list { body }
        // 脱糖为：val iter = list.iterator(); loop { match iter.next() { null => break, item => body } }
        return self.evalForStmtWithIterator(fs, iterable, environment);
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
        .integer => |iv| iv.value == b.integer.value,
        .float => |f| f == b.float,
        .boolean => |bo| bo == b.boolean,
        .char_val => |c| c == b.char_val,
        .string => |s| std.mem.eql(u8, s, b.string),
        .null_val => true,
        .unit => true,
        .range => |r| r.start == b.range.start and r.end == b.range.end and r.inclusive == b.range.inclusive,
        .array => |arr| {
            if (arr.elements.len != b.array.elements.len) return false;
            for (arr.elements, b.array.elements) |item_a, item_b| {
                if (!structuralEquals(item_a, item_b)) return false;
            }
            return true;
        },
        .record => |rec| {
            // 比较所有键值对
            var iter = rec.fields.iterator();
            while (iter.next()) |entry| {
                if (b.record.fields.get(entry.key_ptr.*)) |b_val| {
                    if (!structuralEquals(entry.value_ptr.*, b_val)) return false;
                } else {
                    return false;
                }
            }
            // 确保没有多余的键
            var b_iter = b.record.fields.iterator();
            while (b_iter.next()) |entry| {
                if (rec.fields.get(entry.key_ptr.*)) |_| {} else {
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
        .array_iterator => |ai| ai == b.array_iterator, // 引用相等
        .string_iterator => |si| si == b.string_iterator, // 引用相等
        .range_iterator => |ri| ri == b.range_iterator, // 引用相等
        .atomic_val => |av| av == b.atomic_val, // 引用相等
        .spawn_val => |sh| sh == b.spawn_val, // 引用相等
        .channel_val => |cv| cv == b.channel_val, // 引用相等
        .sender_val => |sv| sv == b.sender_val, // 引用相等
        .receiver_val => |rv| rv == b.receiver_val, // 引用相等
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
        "bool", "str",
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
    return Value{ .integer = IntValue{ .value = @as(i128, @intFromFloat(val)) } };
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
    try std.testing.expectEqual(@as(i128, 42), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 3), add.integer.value);

    const sub = try evalSource(allocator, "10 - 3");
    try std.testing.expectEqual(@as(i128, 7), sub.integer.value);

    const mul = try evalSource(allocator, "4 * 5");
    try std.testing.expectEqual(@as(i128, 20), mul.integer.value);

    const div = try evalSource(allocator, "10 / 3");
    try std.testing.expectEqual(@as(i128, 3), div.integer.value);

    const mod = try evalSource(allocator, "10 % 3");
    try std.testing.expectEqual(@as(i128, 1), mod.integer.value);
}

test "求值器 - 运算符优先级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "1 + 2 * 3");
    try std.testing.expectEqual(@as(i128, 7), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, -42), neg.integer.value);

    const not_val = try evalSource(allocator, "!true");
    try std.testing.expectEqual(false, not_val.boolean);
}

test "求值器 - val 声明和引用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 42; x }");
    try std.testing.expectEqual(@as(i128, 42), result.integer.value);
}

test "求值器 - var 声明和赋值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var x = 1; x = 10; x }");
    try std.testing.expectEqual(@as(i128, 10), result.integer.value);
}

test "求值器 - if 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const then_val = try evalSource(allocator, "if true { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 1), then_val.integer.value);

    const else_val = try evalSource(allocator, "if false { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 2), else_val.integer.value);
}

test "求值器 - 块表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 1; val y = 2; x + y }");
    try std.testing.expectEqual(@as(i128, 3), result.integer.value);
}

test "求值器 - Lambda 和闭包" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Lambda 表达式体
    const result = try evalSource(allocator, "{ val add = (a, b) => a + b; add(3, 4) }");
    try std.testing.expectEqual(@as(i128, 7), result.integer.value);
}

test "求值器 - fun Lambda" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val double = fun(x) { x * 2 }; double(5) }");
    try std.testing.expectEqual(@as(i128, 10), result.integer.value);
}

test "求值器 - 闭包捕获" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 10; val f = (y) => x + y; f(5) }");
    try std.testing.expectEqual(@as(i128, 15), result.integer.value);
}

test "求值器 - match 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 字面量匹配
    const result = try evalSource(allocator, "match 1 { 0 => 100, 1 => 200, _ => 300 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer.value);
}

test "求值器 - match 通配符" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 99 { 0 => 100, _ => 200 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer.value);
}

test "求值器 - match 变量绑定" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 42 { x => x + 1 }");
    try std.testing.expectEqual(@as(i128, 43), result.integer.value);
}

test "求值器 - Elvis 运算符 ??" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42 ?? 0");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer.value);

    const null_val = try evalSource(allocator, "null ?? 0");
    try std.testing.expectEqual(@as(i128, 0), null_val.integer.value);
}

test "求值器 - 非空断言 !" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42!");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer.value);

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
    try std.testing.expectEqual(@as(i128, 3), f2i.integer.value);

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
    try std.testing.expectEqual(@as(usize, 3), result.array.elements.len);
    try std.testing.expectEqual(@as(i128, 1), result.array.elements[0].integer.value);
    try std.testing.expectEqual(@as(i128, 2), result.array.elements[1].integer.value);
    try std.testing.expectEqual(@as(i128, 3), result.array.elements[2].integer.value);
}

test "求值器 - 索引访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val arr = [10, 20, 30]; arr[1] }");
    try std.testing.expectEqual(@as(i128, 20), result.integer.value);
}

test "求值器 - 记录字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "(name: \"Alice\", age: 30)");
    try std.testing.expect(result == .record);
    const name = result.record.fields.get("name").?;
    try std.testing.expectEqualStrings("Alice", name.string);
    const age = result.record.fields.get("age").?;
    try std.testing.expectEqual(@as(i128, 30), age.integer.value);
}

test "求值器 - 字段访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val p = (name: \"Bob\", age: 25); p.age }");
    try std.testing.expectEqual(@as(i128, 25), result.integer.value);
}

test "求值器 - 安全访问 ?." {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const null_access = try evalSource(allocator, "null?.field");
    try std.testing.expect(null_access == .null_val);

    const valid_access = try evalSource(allocator, "{ val p = (x: 1); p?.x }");
    try std.testing.expectEqual(@as(i128, 1), valid_access.integer.value);
}

test "求值器 - while 循环" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var sum = 0; var i = 0; while i < 5 { sum = sum + i; i = i + 1 }; sum }");
    try std.testing.expectEqual(@as(i128, 10), result.integer.value);
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
    arr[0] = Value{ .integer = IntValue{ .value = 1 } };
    arr[1] = Value{ .integer = IntValue{ .value = 2 } };
    arr[2] = Value{ .integer = IntValue{ .value = 3 } };
    arr[3] = Value{ .integer = IntValue{ .value = 4 } };
    arr[4] = Value{ .integer = IntValue{ .value = 5 } };
    const args = [_]Value{Value{ .array = .{ .elements = arr, .fixed_size = null } }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 15), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 5), result.integer.value);
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
    arr[0] = Value{ .integer = IntValue{ .value = 1 } };
    arr[1] = Value{ .integer = IntValue{ .value = 2 } };
    arr[2] = Value{ .integer = IntValue{ .value = 3 } };
    arr[3] = Value{ .integer = IntValue{ .value = 4 } };
    arr[4] = Value{ .integer = IntValue{ .value = 5 } };
    const args = [_]Value{Value{ .array = .{ .elements = arr, .fixed_size = null } }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 12), result.integer.value);
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
    const args = [_]Value{ Value{ .integer = IntValue{ .value = 3 } }, Value{ .integer = IntValue{ .value = 4 } } };
    const result = try evaluator.callFunction(add_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 7), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 42), non_null.integer.value);
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
    const make_args = [_]Value{Value{ .integer = IntValue{ .value = 5 } }};
    const add5 = try evaluator.callFunction(make_adder.value, &make_args, null);

    const add_args = [_]Value{Value{ .integer = IntValue{ .value = 3 } }};
    const result = try evaluator.callFunction(add5, &add_args, null);
    try std.testing.expectEqual(@as(i128, 8), result.integer.value);
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
    const args = [_]Value{Value{ .integer = IntValue{ .value = 10 } }};
    const result = try evaluator.callFunction(fib_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 55), result.integer.value);
}

test "求值器 - match 记录模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match (x: 1, y: 2) { (x: a, y: b) => a + b }");
    try std.testing.expectEqual(@as(i128, 3), result.integer.value);
}

test "求值器 - match 布尔模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match true { true => 1, false => 0 }");
    try std.testing.expectEqual(@as(i128, 1), result.integer.value);
}

test "求值器 - match null 模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match null { null => 0, _ => 1 }");
    try std.testing.expectEqual(@as(i128, 0), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 1), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 42), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 1), r1.integer.value);

    const r2 = try evaluator.callFunction(fn_val.value, &[_]Value{eq_val.value}, null);
    try std.testing.expectEqual(@as(i128, 2), r2.integer.value);

    const r3 = try evaluator.callFunction(fn_val.value, &[_]Value{gt_val.value}, null);
    try std.testing.expectEqual(@as(i128, 3), r3.integer.value);
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
    try std.testing.expectEqual(@as(i128, 99), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 15), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 3), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 10), result.integer.value);
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
    try std.testing.expectEqual(@as(i128, 30), result.integer.value);
}
