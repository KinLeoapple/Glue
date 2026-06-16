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
const module_resolver = @import("module_resolver");
const gc_mod = @import("gc");
const scheduler_mod = @import("scheduler");
const zio = @import("zio");

// ============================================================
// 便捷重导出
// ============================================================

pub const Value = value.Value;
pub const ArrayValue = value.ArrayValue;
pub const Range = value.Range;
pub const IntValue = value.IntValue;
pub const IntType = value.IntType;
pub const FloatValue = value.FloatValue;
pub const FloatType = value.FloatType;
pub const inferIntType = value.inferIntType;
pub const inferFloatType = value.inferFloatType;
pub const promoteIntTypes = value.promoteIntTypes;
pub const promoteFloatTypes = value.promoteFloatTypes;
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
    /// 各字段的内建类型名（如 "i32"），非内建类型为 null。用于构造时把实参强制
    /// 转换到声明的字段类型（与函数形参一致），避免 `Emp(.., 90)` 里 90 留作 i8。
    field_types: []?[]const u8,
};

/// 记录类型构造器上下文数据
const RecordConstructorCtx = struct {
    type_name: []const u8,
    field_names: [][]const u8,
    /// 各字段内建类型名（如 "i32"），非内建为 null。用于构造时强制转换实参到声明类型。
    field_types: []?[]const u8,
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

/// 函数调用嵌套深度上限。树遍历求值器每个 Glue 调用会在宿主栈上嵌套若干
/// callFunction/evalExpr 帧；实测原生栈约在 360 个 callFunction 帧附近溢出，
/// 故取保守值留出余量。超限抛 Glue panic 而非崩溃。深循环用尾递归（TCO 不增长栈）。
const max_call_depth: u32 = 200;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    global_env: Environment,
    io: ?std.Io = null,
    /// Work-stealing 调度器（基于 Zio Runtime）
    /// 文档 §3.7: M:N 调度，少量 OS 线程上运行大量轻量级协程
    /// 文档 §5.3: Work-stealing 调度器
    scheduler: ?*scheduler_mod.Scheduler = null,
    /// Per-heap GC 引用（spawn 协程中设置，主 Evaluator 为 null）
    gc: ?*gc_mod.GarbageCollector = null,
    /// Shadow Stack — 根集追踪方案 B
    /// 在分配前 pushRoot 保护临时 Value，防止 GC 误回收
    shadow_stack: std.ArrayList(value.Value),
    return_value: ?Value = null,
    throw_value: ?Value = null,
    /// Glue panic 消息 — 不可捕获，但允许 defer 执行
    panic_message: ?[]const u8 = null,
    /// 最近正在求值的表达式位置（覆盖式更新）。panic 时据此报告行列。
    current_loc: ?ast.SourceLocation = null,
    /// panic 发生时捕获的位置（main.zig 打印用）。
    panic_location: ?ast.SourceLocation = null,
    closures: std.ArrayList(*value.Closure),
    /// Lazy<T> thunk 列表（Phase 7）：统一管理生命周期
    lazy_values: std.ArrayList(*value.LazyValue),
    /// TCO: 尾调用信息，用于 trampoline
    tail_call: ?TailCall = null,
    /// TCO: 当前是否在尾位置（用于检测尾调用）
    in_tail_position: bool = false,
    /// 当前函数调用嵌套深度。树遍历求值器在宿主栈上递归，非尾递归过深会
    /// 撑爆原生栈并以无信息的 Zig panic 崩溃。用此计数器在接近极限前抛出
    /// 干净的 Glue panic（"stack overflow: recursion too deep"）。
    call_depth: u32 = 0,
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
    /// 模块名 -> 模块值（一等 Trait 值，文档 §4.6.2 文件模块作为 Trait 值）。
    /// pub 成员作为 vtable 方法，pub pack 子模块作为成员；支持 `Store.Memory` 限定访问。
    module_values: std.StringHashMap(Value),
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

    /// 跨模块加载时保留的源代码缓冲（文档 §4: 文件即模块）。
    /// 导入函数的闭包会捕获 AST 节点，而整数字面量的 `raw`、标识符名等
    /// 都是对模块 source 的切片。因此依赖模块的 source 必须存活到
    /// 求值器 deinit，否则被导入函数体在调用时会读到悬垂内存。
    retained_sources: std.ArrayList([]const u8),

    /// 模块路径解析器
    resolver: module_resolver.ModuleResolver,

    /// spawn 协程上下文 — 必须是命名结构体，供 evalSpawn 和 spawnCoroutineFunc 共享类型
    /// 文档 §3.7: spawn 通过 Zio 协程执行，不再使用 std.Thread
    pub const SpawnContext = struct {
        handle: *value.SpawnHandle,
        body: *const ast.Expr,
        env: *Environment,
        backing_allocator: std.mem.Allocator,
        io: std.Io,
        /// 继承父 Evaluator 的 scheduler，使嵌套 spawn 也能走 Zio 协程路径
        scheduler: ?*scheduler_mod.Scheduler,
        /// 继承父 Evaluator 的 GC 引用
        gc: ?*gc_mod.GarbageCollector,
    };

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .shadow_stack = std.ArrayList(value.Value).empty,
            .closures = std.ArrayList(*value.Closure).empty,
            .lazy_values = std.ArrayList(*value.LazyValue).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .trait_definition_order = std.ArrayList([]const u8).empty,
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .module_values = std.StringHashMap(Value).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
            .registered_impls = std.StringHashMap(void).init(allocator),
            .impl_registry = std.StringHashMap(ImplInfo).init(allocator),
            .scan_line_buf = std.ArrayList(u8).empty,
            .spawn_handles = std.ArrayList(*value.SpawnHandle).empty,
            .retained_sources = std.ArrayList([]const u8).empty,
            .resolver = module_resolver.ModuleResolver.init(allocator),
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .io = io,
            .shadow_stack = std.ArrayList(value.Value).empty,
            .closures = std.ArrayList(*value.Closure).empty,
            .lazy_values = std.ArrayList(*value.LazyValue).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .trait_definition_order = std.ArrayList([]const u8).empty,
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .module_values = std.StringHashMap(Value).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
            .registered_impls = std.StringHashMap(void).init(allocator),
            .impl_registry = std.StringHashMap(ImplInfo).init(allocator),
            .scan_line_buf = std.ArrayList(u8).empty,
            .spawn_handles = std.ArrayList(*value.SpawnHandle).empty,
            .retained_sources = std.ArrayList([]const u8).empty,
            .resolver = module_resolver.ModuleResolver.init(allocator),
        };
        ev.registerBuiltins();
        return ev;
    }

    /// 初始化带调度器的 Evaluator
    /// 文档 §3.7: spawn 通过 Zio 协程执行，需要调度器
    pub fn initWithScheduler(allocator: std.mem.Allocator, sched: *scheduler_mod.Scheduler) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .io = sched.getIo(),
            .scheduler = sched,
            .shadow_stack = std.ArrayList(value.Value).empty,
            .closures = std.ArrayList(*value.Closure).empty,
            .lazy_values = std.ArrayList(*value.LazyValue).empty,
            .error_newtype_contexts = std.ArrayList(*ErrorNewtypeCtx).empty,
            .adt_constructor_contexts = std.ArrayList(*AdtConstructorCtx).empty,
            .record_constructor_contexts = std.ArrayList(*RecordConstructorCtx).empty,
            .trait_registry = std.StringHashMap(TraitInfo).init(allocator),
            .trait_definition_order = std.ArrayList([]const u8).empty,
            .impl_methods = std.ArrayList(ImplMethodEntry).empty,
            .module_exports = std.StringHashMap(ModuleExportInfo).init(allocator),
            .module_values = std.StringHashMap(Value).init(allocator),
            .current_source_dir = null,
            .module_defer_stack = std.ArrayList(*const ast.Expr).empty,
            .loading_modules = std.StringHashMap(void).init(allocator),
            .loaded_modules = std.StringHashMap(void).init(allocator),
            .type_inferencer = sema.TypeInferencer.init(allocator),
            .registered_impls = std.StringHashMap(void).init(allocator),
            .impl_registry = std.StringHashMap(ImplInfo).init(allocator),
            .scan_line_buf = std.ArrayList(u8).empty,
            .spawn_handles = std.ArrayList(*value.SpawnHandle).empty,
            .retained_sources = std.ArrayList([]const u8).empty,
            .resolver = module_resolver.ModuleResolver.init(allocator),
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        self.shadow_stack.deinit(self.allocator);
        self.global_env.deinit();
        // 释放所有注册的闭包
        for (self.closures.items) |closure| {
            self.allocator.destroy(closure);
        }
        self.closures.deinit(self.allocator);
        // 释放所有 Lazy thunk
        for (self.lazy_values.items) |lz| {
            self.allocator.destroy(lz);
        }
        self.lazy_values.deinit(self.allocator);
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
        // 释放模块值表（键 owned；值 TraitValue 与其 methods 由 GC/allocator 管理）
        {
            var iter = self.module_values.keyIterator();
            while (iter.next()) |k| {
                self.allocator.free(k.*);
            }
            self.module_values.deinit();
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
            // 等待 worker 彻底结束后再释放，避免 detached worker 写已释放内存。
            // await 已等待结果；cancel/未消费的 handle 此处兜底等待 worker 退出。
            while (!handle.finished.load(.seq_cst)) {
                std.Thread.yield() catch {};
            }
            handle.deinit();
            self.allocator.destroy(handle);
        }
        self.spawn_handles.deinit(self.allocator);
        // 释放跨模块保留的源代码缓冲
        for (self.retained_sources.items) |src| {
            self.allocator.free(src);
        }
        self.retained_sources.deinit(self.allocator);
        // 释放模块解析器
        self.resolver.deinit();
    }

    /// 触发 Glue panic — 不可捕获，但允许 defer 执行
    ///
    /// 文档要求：panic 不可捕获，但 defer 在 panic 时仍执行。
    /// 实现方式：设置 panic_message 并返回 error.GluePanic，
    /// evalBlock 捕获后执行 defer 栈，然后重新抛出。
    fn gluePanic(self: *Evaluator, message: []const u8) EvalResult!Value {
        self.panic_message = message;
        if (self.panic_location == null) self.panic_location = self.current_loc;
        return error.GluePanic;
    }

    /// 带格式化消息的 panic：用 self.allocator 拼接消息；分配失败回退到 fallback。
    /// 用于需要上下文（类型名、方法名、数量等）的专业报错。
    fn gluePanicFmt(self: *Evaluator, comptime fmt: []const u8, args: anytype, fallback: []const u8) EvalResult!Value {
        self.panic_message = std.fmt.allocPrint(self.allocator, fmt, args) catch fallback;
        if (self.panic_location == null) self.panic_location = self.current_loc;
        return error.GluePanic;
    }

    /// 取运行时值的用户可见类型名；函数类（闭包/内建/部分应用）回退为 "function"。
    fn typeNameOf(val: Value) []const u8 {
        return valueTypeName(val) orelse "function";
    }

    /// 设置专业报错消息但返回调用方指定的具名错误（用于 EvalError 上下文，
    /// 那里不能返回 GluePanic）。main.zig 在打印时优先使用 panic_message。
    fn setErrMsg(self: *Evaluator, comptime fmt: []const u8, args: anytype, fallback: []const u8) void {
        self.panic_message = std.fmt.allocPrint(self.allocator, fmt, args) catch fallback;
        if (self.panic_location == null) self.panic_location = self.current_loc;
    }

    // ── Shadow Stack 根集追踪（方案 B）──

    /// 将临时 Value 压入 shadow stack，保护其不被 GC 回收
    /// 在跨分配点持有 Value 时调用
    pub fn pushRoot(self: *Evaluator, val: Value) void {
        self.shadow_stack.append(self.allocator, val) catch {};
    }

    /// 弹出一个 shadow stack 条目
    pub fn popRoot(self: *Evaluator) void {
        if (self.shadow_stack.items.len > 0) {
            _ = self.shadow_stack.pop();
        }
    }

    /// 弹出 n 个 shadow stack 条目
    pub fn popRoots(self: *Evaluator, n: usize) void {
        if (n <= self.shadow_stack.items.len) {
            self.shadow_stack.shrinkRetainingCapacity(self.shadow_stack.items.len - n);
        }
    }

    /// 从 Value 递归追踪所有可达的堆对象，标记到 GC 的 mark_set
    /// markObject 返回 true 表示新标记（需要继续追踪子对象）
    fn traceValue(self: *Evaluator, val: Value) void {
        const gc = self.gc orelse return;
        switch (val) {
            .unit, .null_val, .integer, .float, .boolean, .char_val, .builtin => {},
            .string => |s| {
                // 字符串切片的 ptr 指向堆分配的字符数据
                if (s.len > 0) {
                    _ = gc.markObject(@intFromPtr(s.ptr));
                }
            },
            .error_val => |ev| {
                if (ev.message.len > 0) _ = gc.markObject(@intFromPtr(ev.message.ptr));
                if (ev.type_name.len > 0) _ = gc.markObject(@intFromPtr(ev.type_name.ptr));
            },
            .range => {},
            .array => |av| {
                if (av.elements.len > 0) {
                    if (gc.markObject(@intFromPtr(av.elements.ptr))) {
                        for (av.elements) |v| self.traceValue(v);
                    }
                }
            },
            .record => |rv| {
                // RecordValue 内联于 Value，fields 是 StringHashMap(Value)
                var iter = rv.fields.iterator();
                while (iter.next()) |entry| {
                    self.traceValue(entry.value_ptr.*);
                }
            },
            .adt => |av| {
                if (gc.markObject(@intFromPtr(av))) {
                    if (av.fields.len > 0) {
                        if (gc.markObject(@intFromPtr(av.fields.ptr))) {
                            for (av.fields) |field| {
                                self.traceValue(field.value);
                            }
                        }
                    }
                }
            },
            .newtype => |nv| {
                if (gc.markObject(@intFromPtr(nv))) {
                    self.traceValue(nv.inner);
                }
            },
            .closure => |cl| {
                if (gc.markObject(@intFromPtr(cl))) {
                    // 追踪闭包捕获的环境
                    const closure_env: *Environment = @ptrCast(@alignCast(cl.env));
                    self.traceEnv(closure_env);
                }
            },
            .partial => |pa| {
                if (gc.markObject(@intFromPtr(pa))) {
                    self.traceValue(pa.func);
                    if (pa.bound_args.len > 0) {
                        if (gc.markObject(@intFromPtr(pa.bound_args.ptr))) {
                            for (pa.bound_args) |v| self.traceValue(v);
                        }
                    }
                }
            },
            .throw_val => |tv| {
                if (gc.markObject(@intFromPtr(tv))) {
                    switch (tv.*) {
                        .ok => |v_ptr| self.traceValue(v_ptr.*),
                        .err => {},
                    }
                }
            },
            .array_iterator => |ai| {
                if (gc.markObject(@intFromPtr(ai))) {
                    if (ai.array.len > 0) {
                        if (gc.markObject(@intFromPtr(ai.array.ptr))) {
                            for (ai.array) |v| self.traceValue(v);
                        }
                    }
                }
            },
            .string_iterator => |si| {
                _ = gc.markObject(@intFromPtr(si));
            },
            .range_iterator => |ri| {
                _ = gc.markObject(@intFromPtr(ri));
            },
            .atomic_val => |av| {
                _ = gc.markObject(@intFromPtr(av));
            },
            .spawn_val => |handle| {
                if (gc.markObject(@intFromPtr(handle))) {
                    if (handle.result) |r| self.traceValue(r);
                }
            },
            .channel_val => |ch| {
                if (gc.markObject(@intFromPtr(ch))) {
                    if (ch.buffer.items.len > 0) {
                        if (gc.markObject(@intFromPtr(ch.buffer.items.ptr))) {
                            for (ch.buffer.items) |v| self.traceValue(v);
                        }
                    }
                }
            },
            .sender_val => |sv| {
                if (gc.markObject(@intFromPtr(sv))) {
                    self.traceValue(.{ .channel_val = sv.channel });
                }
            },
            .receiver_val => |rv| {
                if (gc.markObject(@intFromPtr(rv))) {
                    self.traceValue(.{ .channel_val = rv.channel });
                }
            },
            .trait_value => |tv| {
                if (gc.markObject(@intFromPtr(tv))) {
                    // 追踪 vtable 中的方法闭包与 data 载荷
                    var it = tv.methods.valueIterator();
                    while (it.next()) |m| self.traceValue(m.*);
                    if (tv.data) |d| {
                        if (gc.markObject(@intFromPtr(d))) self.traceValue(d.*);
                    }
                }
            },
            .lazy_val => |lz| {
                if (gc.markObject(@intFromPtr(lz))) {
                    if (lz.forced) {
                        if (lz.cached) |c| self.traceValue(c);
                    }
                }
            },
        }
    }

    /// 从 Environment 递归追踪所有可达的堆对象
    fn traceEnv(self: *Evaluator, environment: *Environment) void {
        const gc = self.gc orelse return;
        if (gc.markObject(@intFromPtr(environment))) {
            // 追踪所有绑定值
            var iter = environment.values.iterator();
            while (iter.next()) |entry| {
                self.traceValue(entry.value_ptr.value);
            }
            // 追踪父环境
            if (environment.parent) |parent| {
                self.traceEnv(parent);
            }
            // 追踪子环境
            for (environment.children.items) |child| {
                self.traceEnv(child);
            }
        }
    }

    /// 执行垃圾回收：clearMarks → trace from roots → sweep
    /// 在安全点调用（声明之间、语句之间）
    pub fn collectGarbage(self: *Evaluator) void {
        const gc = self.gc orelse return;

        // 1. 清除所有标记
        gc.clearMarks();

        // 2. 从根集追踪：shadow stack + global_env
        for (self.shadow_stack.items) |val| {
            self.traceValue(val);
        }
        self.traceEnv(&self.global_env);

        // 3. Sweep：回收未标记的分配
        gc.sweep();
    }

    /// 检查是否应该触发 GC，如果应该则执行回收
    pub fn maybeCollectGarbage(self: *Evaluator) void {
        const gc = self.gc orelse return;
        // Minor GC：nursery 使用率超过阈值
        if (gc.shouldMinorCollect()) {
            self.minorGC();
        }
        // Major GC：老生代分配超过阈值
        if (gc.shouldCollect()) {
            self.collectGarbage();
        }
    }

    /// Minor GC：将 nursery 中所有活对象疏散到老生代
    /// 流程：beginMinorGC → 疏散根集 → endMinorGC
    pub fn minorGC(self: *Evaluator) void {
        const gc = self.gc orelse return;
        gc.beginMinorGC();

        // 疏散 shadow_stack 中的所有 Value
        for (self.shadow_stack.items) |*val| {
            self.evacuateValue(val);
        }

        // 疏散 global_env
        self.evacuateEnv(&self.global_env);

        gc.endMinorGC();
    }

    /// 疏散 Value：就地更新 Value 中所有 nursery 指针到老生代
    /// 对于每个 nursery 指针：晋升数据到老生代，更新 Value 中的指针
    fn evacuateValue(self: *Evaluator, val: *Value) void {
        const gc = self.gc orelse return;
        switch (val.*) {
            .unit, .null_val, .integer, .float, .boolean, .char_val, .builtin, .range => {},
            .string => |*s| {
                if (s.len > 0 and gc.isInNursery(@intFromPtr(s.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(s.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, s.len);
                    s.ptr = @ptrCast(@constCast(new_ptr));
                }
            },
            .error_val => |*ev| {
                if (ev.message.len > 0 and gc.isInNursery(@intFromPtr(ev.message.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(ev.message.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, ev.message.len);
                    ev.message.ptr = @ptrCast(@constCast(new_ptr));
                }
                if (ev.type_name.len > 0 and gc.isInNursery(@intFromPtr(ev.type_name.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(ev.type_name.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, ev.type_name.len);
                    ev.type_name.ptr = @ptrCast(@constCast(new_ptr));
                }
            },
            .array => |*av| {
                if (av.elements.len > 0 and gc.isInNursery(@intFromPtr(av.elements.ptr))) {
                    const byte_size = av.elements.len * @sizeOf(Value);
                    const old_ptr: [*]u8 = @ptrCast(@constCast(av.elements.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_elements: [*]Value = @ptrCast(@alignCast(new_ptr));
                    av.elements = new_elements[0..av.elements.len];
                }
                // 递归疏散每个元素
                for (av.elements) |*elem| {
                    self.evacuateValue(elem);
                }
            },
            .record => |*rv| {
                // RecordValue 的 fields 是 StringHashMap(Value)
                // HashMap 内部存储可能在 nursery 中，需要整体迁移
                self.evacuateStringHashMap(Value, &rv.fields);
            },
            .adt => |*av_ptr| {
                if (gc.isInNursery(@intFromPtr(av_ptr.*))) {
                    const byte_size = @sizeOf(value.AdtValue);
                    const old_ptr: [*]u8 = @ptrCast(av_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_av: *value.AdtValue = @ptrCast(@alignCast(new_ptr));
                    av_ptr.* = new_av;
                }
                // 疏散 AdtValue 内部字段
                const av = av_ptr.*;
                // type_name
                if (av.type_name.len > 0 and gc.isInNursery(@intFromPtr(av.type_name.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(av.type_name.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, av.type_name.len);
                    av.type_name.ptr = @ptrCast(@constCast(new_ptr));
                }
                // constructor
                if (av.constructor.len > 0 and gc.isInNursery(@intFromPtr(av.constructor.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(av.constructor.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, av.constructor.len);
                    av.constructor.ptr = @ptrCast(@constCast(new_ptr));
                }
                // fields 数组
                if (av.fields.len > 0 and gc.isInNursery(@intFromPtr(av.fields.ptr))) {
                    const byte_size = av.fields.len * @sizeOf(value.AdtField);
                    const old_ptr: [*]u8 = @ptrCast(@constCast(av.fields.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_fields: [*]value.AdtField = @ptrCast(@alignCast(new_ptr));
                    av.fields = new_fields[0..av.fields.len];
                }
                // 递归疏散每个字段
                for (av.fields) |*field| {
                    if (field.name) |name| {
                        if (name.len > 0 and gc.isInNursery(@intFromPtr(name.ptr))) {
                            const old_ptr: [*]u8 = @ptrCast(@constCast(name.ptr));
                            const new_ptr = gc.promoteToOldGen(old_ptr, name.len);
                            field.name = new_ptr[0..name.len];
                        }
                    }
                    self.evacuateValue(&field.value);
                }
            },
            .newtype => |*nv_ptr| {
                if (gc.isInNursery(@intFromPtr(nv_ptr.*))) {
                    const byte_size = @sizeOf(value.NewtypeValue);
                    const old_ptr: [*]u8 = @ptrCast(nv_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_nv: *value.NewtypeValue = @ptrCast(@alignCast(new_ptr));
                    nv_ptr.* = new_nv;
                }
                // type_name
                if (nv_ptr.*.type_name.len > 0 and gc.isInNursery(@intFromPtr(nv_ptr.*.type_name.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(nv_ptr.*.type_name.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, nv_ptr.*.type_name.len);
                    nv_ptr.*.type_name.ptr = @ptrCast(@constCast(new_ptr));
                }
                self.evacuateValue(&nv_ptr.*.inner);
            },
            .closure => |*cl_ptr| {
                if (gc.isInNursery(@intFromPtr(cl_ptr.*))) {
                    const byte_size = @sizeOf(value.Closure);
                    const old_ptr: [*]u8 = @ptrCast(cl_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_cl: *value.Closure = @ptrCast(@alignCast(new_ptr));
                    cl_ptr.* = new_cl;
                }
                // 疏散闭包捕获的环境
                const closure_env: *Environment = @ptrCast(@alignCast(cl_ptr.*.env));
                self.evacuateEnv(closure_env);
            },
            .partial => |*pa_ptr| {
                if (gc.isInNursery(@intFromPtr(pa_ptr.*))) {
                    const byte_size = @sizeOf(value.PartialApplication);
                    const old_ptr: [*]u8 = @ptrCast(pa_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_pa: *value.PartialApplication = @ptrCast(@alignCast(new_ptr));
                    pa_ptr.* = new_pa;
                }
                self.evacuateValue(&pa_ptr.*.func);
                if (pa_ptr.*.bound_args.len > 0 and gc.isInNursery(@intFromPtr(pa_ptr.*.bound_args.ptr))) {
                    const byte_size = pa_ptr.*.bound_args.len * @sizeOf(Value);
                    const old_ptr: [*]u8 = @ptrCast(@constCast(pa_ptr.*.bound_args.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_args: [*]Value = @ptrCast(@alignCast(new_ptr));
                    pa_ptr.*.bound_args = new_args[0..pa_ptr.*.bound_args.len];
                }
                for (pa_ptr.*.bound_args) |*arg| {
                    self.evacuateValue(arg);
                }
            },
            .throw_val => |*tv_ptr| {
                if (gc.isInNursery(@intFromPtr(tv_ptr.*))) {
                    const byte_size = @sizeOf(value.ThrowValue);
                    const old_ptr: [*]u8 = @ptrCast(tv_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_tv: *value.ThrowValue = @ptrCast(@alignCast(new_ptr));
                    tv_ptr.* = new_tv;
                }
                // 疏散 ThrowValue 内部数据
                switch (tv_ptr.*.*) {
                    .ok => |v_ptr| self.evacuateValue(v_ptr),
                    .err => |*ev| {
                        if (ev.message.len > 0 and gc.isInNursery(@intFromPtr(ev.message.ptr))) {
                            const old_ptr: [*]u8 = @ptrCast(@constCast(ev.message.ptr));
                            const new_ptr = gc.promoteToOldGen(old_ptr, ev.message.len);
                            ev.message.ptr = @ptrCast(@constCast(new_ptr));
                        }
                        if (ev.type_name.len > 0 and gc.isInNursery(@intFromPtr(ev.type_name.ptr))) {
                            const old_ptr: [*]u8 = @ptrCast(@constCast(ev.type_name.ptr));
                            const new_ptr = gc.promoteToOldGen(old_ptr, ev.type_name.len);
                            ev.type_name.ptr = @ptrCast(@constCast(new_ptr));
                        }
                    },
                }
            },
            .array_iterator => |*ai_ptr| {
                if (gc.isInNursery(@intFromPtr(ai_ptr.*))) {
                    const byte_size = @sizeOf(value.ArrayIterator);
                    const old_ptr: [*]u8 = @ptrCast(ai_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_ai: *value.ArrayIterator = @ptrCast(@alignCast(new_ptr));
                    ai_ptr.* = new_ai;
                }
                if (ai_ptr.*.array.len > 0 and gc.isInNursery(@intFromPtr(ai_ptr.*.array.ptr))) {
                    const byte_size = ai_ptr.*.array.len * @sizeOf(Value);
                    const old_ptr: [*]u8 = @ptrCast(@constCast(ai_ptr.*.array.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_arr: [*]Value = @ptrCast(@alignCast(new_ptr));
                    ai_ptr.*.array = new_arr[0..ai_ptr.*.array.len];
                }
                for (ai_ptr.*.array) |*elem| {
                    self.evacuateValue(elem);
                }
            },
            .string_iterator => |*si_ptr| {
                if (gc.isInNursery(@intFromPtr(si_ptr.*))) {
                    const byte_size = @sizeOf(value.StringIterator);
                    const old_ptr: [*]u8 = @ptrCast(si_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_si: *value.StringIterator = @ptrCast(@alignCast(new_ptr));
                    si_ptr.* = new_si;
                }
                if (si_ptr.*.string.len > 0 and gc.isInNursery(@intFromPtr(si_ptr.*.string.ptr))) {
                    const old_ptr: [*]u8 = @ptrCast(@constCast(si_ptr.*.string.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, si_ptr.*.string.len);
                    si_ptr.*.string.ptr = @ptrCast(@constCast(new_ptr));
                }
            },
            .range_iterator => |*ri_ptr| {
                if (gc.isInNursery(@intFromPtr(ri_ptr.*))) {
                    const byte_size = @sizeOf(value.RangeIterator);
                    const old_ptr: [*]u8 = @ptrCast(ri_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_ri: *value.RangeIterator = @ptrCast(@alignCast(new_ptr));
                    ri_ptr.* = new_ri;
                }
            },
            .atomic_val => |*av_ptr| {
                if (gc.isInNursery(@intFromPtr(av_ptr.*))) {
                    const byte_size = @sizeOf(value.AtomicValue);
                    const old_ptr: [*]u8 = @ptrCast(av_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_av: *value.AtomicValue = @ptrCast(@alignCast(new_ptr));
                    av_ptr.* = new_av;
                }
            },
            .spawn_val => |*handle_ptr| {
                if (gc.isInNursery(@intFromPtr(handle_ptr.*))) {
                    const byte_size = @sizeOf(value.SpawnHandle);
                    const old_ptr: [*]u8 = @ptrCast(handle_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_handle: *value.SpawnHandle = @ptrCast(@alignCast(new_ptr));
                    handle_ptr.* = new_handle;
                }
                if (handle_ptr.*.result) |*r| {
                    self.evacuateValue(r);
                }
            },
            .channel_val => |*ch_ptr| {
                if (gc.isInNursery(@intFromPtr(ch_ptr.*))) {
                    const byte_size = @sizeOf(value.ChannelValue);
                    const old_ptr: [*]u8 = @ptrCast(ch_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_ch: *value.ChannelValue = @ptrCast(@alignCast(new_ptr));
                    ch_ptr.* = new_ch;
                }
                // Channel buffer 中的值
                if (ch_ptr.*.buffer.items.len > 0 and gc.isInNursery(@intFromPtr(ch_ptr.*.buffer.items.ptr))) {
                    const byte_size = ch_ptr.*.buffer.items.len * @sizeOf(Value);
                    const old_ptr: [*]u8 = @ptrCast(@constCast(ch_ptr.*.buffer.items.ptr));
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_items: [*]Value = @ptrCast(@alignCast(new_ptr));
                    ch_ptr.*.buffer.items = new_items[0..ch_ptr.*.buffer.items.len];
                }
                for (ch_ptr.*.buffer.items) |*item| {
                    self.evacuateValue(item);
                }
            },
            .sender_val => |*sv_ptr| {
                if (gc.isInNursery(@intFromPtr(sv_ptr.*))) {
                    const byte_size = @sizeOf(value.SenderValue);
                    const old_ptr: [*]u8 = @ptrCast(sv_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_sv: *value.SenderValue = @ptrCast(@alignCast(new_ptr));
                    sv_ptr.* = new_sv;
                }
                // channel 指针
                if (gc.isInNursery(@intFromPtr(sv_ptr.*.channel))) {
                    const byte_size = @sizeOf(value.ChannelValue);
                    const old_ptr: [*]u8 = @ptrCast(sv_ptr.*.channel);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_ch: *value.ChannelValue = @ptrCast(@alignCast(new_ptr));
                    sv_ptr.*.channel = new_ch;
                    // 疏散 channel 内部
                    self.evacuateChannelValue(new_ch);
                }
            },
            .receiver_val => |*rv_ptr| {
                if (gc.isInNursery(@intFromPtr(rv_ptr.*))) {
                    const byte_size = @sizeOf(value.ReceiverValue);
                    const old_ptr: [*]u8 = @ptrCast(rv_ptr.*);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_rv: *value.ReceiverValue = @ptrCast(@alignCast(new_ptr));
                    rv_ptr.* = new_rv;
                }
                // channel 指针
                if (gc.isInNursery(@intFromPtr(rv_ptr.*.channel))) {
                    const byte_size = @sizeOf(value.ChannelValue);
                    const old_ptr: [*]u8 = @ptrCast(rv_ptr.*.channel);
                    const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
                    const new_ch: *value.ChannelValue = @ptrCast(@alignCast(new_ptr));
                    rv_ptr.*.channel = new_ch;
                    self.evacuateChannelValue(new_ch);
                }
            },
            .trait_value => |*tv_ptr| {
                // TraitValue 与其方法闭包用 self.allocator 分配（非 nursery）；
                // 仅需疏散 data 载荷内部可能的 nursery 指针。
                if (tv_ptr.*.data) |d| self.evacuateValue(d);
            },
            .lazy_val => |*lz_ptr| {
                // LazyValue 用 self.allocator 分配（非 nursery）；
                // 已求值时疏散缓存值内部可能的 nursery 指针。
                if (lz_ptr.*.forced) {
                    if (lz_ptr.*.cached) |*c| self.evacuateValue(c);
                }
            },
        }
    }

    /// 疏散 ChannelValue 内部数据（buffer items）
    fn evacuateChannelValue(self: *Evaluator, ch: *value.ChannelValue) void {
        const gc = self.gc orelse return;
        if (ch.buffer.items.len > 0 and gc.isInNursery(@intFromPtr(ch.buffer.items.ptr))) {
            const byte_size = ch.buffer.items.len * @sizeOf(Value);
            const old_ptr: [*]u8 = @ptrCast(@constCast(ch.buffer.items.ptr));
            const new_ptr = gc.promoteToOldGen(old_ptr, byte_size);
            const new_items: [*]Value = @ptrCast(@alignCast(new_ptr));
            ch.buffer.items = new_items[0..ch.buffer.items.len];
        }
        for (ch.buffer.items) |*item| {
            self.evacuateValue(item);
        }
    }

    /// 疏散 StringHashMap：将 HashMap 内部存储和所有 key/value 从 nursery 晋升到老生代
    /// HashMap 的内部结构不透明，采用重建策略：创建新 HashMap，逐条迁移
    fn evacuateStringHashMap(self: *Evaluator, comptime V: type, map: *std.StringHashMap(V)) void {
        const gc = self.gc orelse return;

        // 检查是否有任何数据在 nursery 中
        var has_nursery_data = false;
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (gc.isInNursery(@intFromPtr(key.ptr))) {
                has_nursery_data = true;
                break;
            }
        }

        if (!has_nursery_data) {
            // key 都不在 nursery，但 value 可能是 Value 类型需要疏散
            iter = map.iterator();
            while (iter.next()) |entry| {
                self.evacuateHashMapValue(V, entry.value_ptr);
            }
            return;
        }

        // 有 nursery 数据：重建 HashMap
        var new_map = std.StringHashMap(V).init(self.allocator);
        errdefer new_map.deinit();

        iter = map.iterator();
        while (iter.next()) |entry| {
            // 晋升 key
            const old_key = entry.key_ptr.*;
            var new_key: []const u8 = old_key;
            if (gc.isInNursery(@intFromPtr(old_key.ptr))) {
                const old_ptr: [*]u8 = @ptrCast(@constCast(old_key.ptr));
                const new_ptr = gc.promoteToOldGen(old_ptr, old_key.len);
                new_key = new_ptr[0..old_key.len];
            }

            // 晋升 value
            var v = entry.value_ptr.*;
            self.evacuateHashMapValue(V, &v);

            new_map.put(new_key, v) catch {};
        }

        // 替换旧 map（不 deinit 旧 map，nursery 内存会整体重置）
        map.* = new_map;
    }

    /// 疏散 HashMap 中的值（根据类型分派）
    fn evacuateHashMapValue(self: *Evaluator, comptime V: type, val_ptr: *V) void {
        if (V == Value) {
            self.evacuateValue(val_ptr);
        } else if (V == env.Variable) {
            self.evacuateValue(&val_ptr.value);
        }
    }

    /// 疏散 Environment：就地更新所有 nursery 指针
    fn evacuateEnv(self: *Evaluator, environment: *Environment) void {
        // 疏散 values HashMap
        self.evacuateStringHashMap(env.Variable, &environment.values);

        // 疏散父环境
        if (environment.parent) |parent| {
            self.evacuateEnv(parent);
        }

        // 疏散子环境
        for (environment.children.items) |child| {
            self.evacuateEnv(child);
        }
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
        // type (返回值的运行时类型名，文档 §2.15)
        self.global_env.define("type", Value{ .builtin = value.Builtin{ .fn_ptr = struct {
            fn call(ctx: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                _ = user_ctx;
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinTypeName(args);
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
        if (args.len != 1) {
            self.setErrMsg("println expects 1 argument, got {d}", .{args.len}, "println: wrong number of arguments");
            return error.WrongArity;
        }
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
        if (args.len != 1) {
            self.setErrMsg("print expects 1 argument, got {d}", .{args.len}, "print: wrong number of arguments");
            return error.WrongArity;
        }
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
        if (args.len != 1) {
            self.setErrMsg("eprintln expects 1 argument, got {d}", .{args.len}, "eprintln: wrong number of arguments");
            return error.WrongArity;
        }
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
        if (args.len != 1) {
            self.setErrMsg("eprint expects 1 argument, got {d}", .{args.len}, "eprint: wrong number of arguments");
            return error.WrongArity;
        }
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
        if (args.len != 1) {
            return self.gluePanicFmt("Panic expects 1 argument, got {d}", .{args.len}, "Panic: wrong number of arguments");
        }
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator, false) catch {};
        const msg = try self.allocator.dupe(u8, buf.items);
        return self.gluePanic(msg);
    }

    fn builtinEq(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 2) {
            self.setErrMsg("eq expects 2 arguments, got {d}", .{args.len}, "eq: wrong number of arguments");
            return error.WrongArity;
        }
        return Value{ .boolean = structuralEquals(args[0], args[1]) };
    }

    fn builtinString(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) {
            self.setErrMsg("str expects 1 argument, got {d}", .{args.len}, "str: wrong number of arguments");
            return error.WrongArity;
        }
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator, false) catch return error.OutOfMemory;
        return Value{ .string = buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    /// type(x) — 返回 x 的运行时类型名（str）。文档 §2.15。
    /// 基本类型返回具体类型名（如 "i32"、"str"、"bool"）；ADT/newtype 返回其类型名；
    /// 函数值（闭包/内建/部分应用）统一返回 "function"。
    fn builtinTypeName(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) {
            self.setErrMsg("type expects 1 argument, got {d}", .{args.len}, "type: wrong number of arguments");
            return error.WrongArity;
        }
        const name = valueTypeName(args[0]) orelse "function";
        return Value{ .string = self.allocator.dupe(u8, name) catch return error.OutOfMemory };
    }

    fn builtinError(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) {
            self.setErrMsg("Error expects 1 argument, got {d}", .{args.len}, "Error: wrong number of arguments");
            return error.WrongArity;
        }
        const message = switch (args[0]) {
            .string => |s| s,
            else => {
                self.setErrMsg("Error expects a str argument, got '{s}'", .{typeNameOf(args[0])}, "Error: type error");
                return error.TypeMismatch;
            },
        };
        return throw_mod.makeErr(self.allocator, "Error", message);
    }

    /// Ok(value) — 创建 ThrowValue.ok
    fn builtinOk(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) {
            self.setErrMsg("Ok expects 1 argument, got {d}", .{args.len}, "Ok: wrong number of arguments");
            return error.WrongArity;
        }
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
        if (args.len != 0) {
            self.setErrMsg("scanln expects 0 arguments, got {d}", .{args.len}, "scanln: wrong number of arguments");
            return error.WrongArity;
        }

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
        if (args.len != 0) {
            self.setErrMsg("scan expects 0 arguments, got {d}", .{args.len}, "scan: wrong number of arguments");
            return error.WrongArity;
        }

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
        if (args.len != 1) {
            self.setErrMsg("channel expects 1 argument, got {d}", .{args.len}, "channel: wrong number of arguments");
            return error.WrongArity;
        }
        const cap = switch (args[0]) {
            .integer => |iv| @as(usize, @intCast(if (iv.type_tag.isSigned()) iv.signedValue() else @as(i128, @intCast(iv.value)))),
            else => {
                self.setErrMsg("channel expects an integer capacity, got '{s}'", .{typeNameOf(args[0])}, "channel: type error");
                return error.TypeMismatch;
            },
        };
        const ch = try self.allocator.create(value.ChannelValue);
        ch.* = value.ChannelValue.init(self.allocator, cap);
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
            .closure, .builtin, .partial => {
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

        // 跨模块导入预加载（文档 §4.5 use）：在类型检查本模块之前，
        // 先加载并检查所有 use 依赖。这样依赖模块的导出函数 scheme 会被
        // 注册到 type_inferencer.exported_schemes，本模块的类型检查才能
        // 解析这些导入名字。依赖的运行时值也会在此一并求值（共享 global_env），
        // 后续本模块求值时 use_decl 只是从导出表引用已存在的值。
        // loading_modules 已包含本模块名，依赖若反向 use 本模块会触发循环依赖错误。
        for (module.declarations) |decl| {
            if (decl == .use_decl) {
                const ud = decl.use_decl;
                if (ud.module_path.len == 0) continue;
                if (self.loaded_modules.contains(ud.module_path[0])) continue;
                if (self.loading_modules.contains(ud.module_path[0])) return error.CircularDependency;
                self.loadModuleFromFile(ud.module_path) catch |err| switch (err) {
                    error.FileNotFound => {}, // 内建模块或尚未实现，跳过
                    else => return err,
                };
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
                        .unconsumed_spawn => "linear type error",
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
            // 安全点：声明之间触发 GC
            self.maybeCollectGarbage();
        }

        // 存储模块导出信息
        const export_key = try self.allocator.dupe(u8, module_name);
        const owned_pub_names = try pub_names.toOwnedSlice(self.allocator);
        try self.module_exports.put(export_key, ModuleExportInfo{
            .env = &self.global_env,
            .pub_names = owned_pub_names,
        });

        // 文档 §4.6.2: 把模块构建成「模块值」(一等 Trait 值)，pub 成员作为 vtable 方法、
        // pub pack 子模块作为成员，绑定 module_name -> 模块值，支持 `Store.Memory` 限定访问
        // 与「文件模块作为 Trait 值」的结构化传参。
        try self.buildAndBindModuleValue(module, module_name);

        // 执行模块级 defer（LIFO 顺序）
        self.runDefers(self.module_defer_stack.items, &self.global_env) catch {};
        self.module_defer_stack.clearRetainingCapacity();

        // 标记模块为"已加载完成"
        const loaded_name = try self.allocator.dupe(u8, module_name);
        try self.loaded_modules.put(loaded_name, {});
    }

    /// 构建模块值并绑定到 global_env 与 module_values 注册表。
    /// 模块值 = TraitValue{ trait_name=模块名, methods=pub 成员(函数闭包/子模块值), data=null }。
    fn buildAndBindModuleValue(self: *Evaluator, module: ast.Module, module_name: []const u8) !void {
        const tv = try self.allocator.create(value.TraitValue);
        var methods = std.StringHashMap(Value).init(self.allocator);

        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (f.visibility != .public) continue;
                    if (self.global_env.get(f.name)) |v| {
                        const key = try self.allocator.dupe(u8, f.name);
                        try methods.put(key, v.value);
                    }
                },
                .pack_decl => |pd| {
                    if (pd.visibility != .public) continue;
                    // 子模块的模块值已在其 evalModule 收尾时注册到 module_values
                    if (self.module_values.get(pd.name)) |sub_val| {
                        const key = try self.allocator.dupe(u8, pd.name);
                        try methods.put(key, sub_val);
                    }
                },
                else => {},
            }
        }

        tv.* = value.TraitValue{
            .trait_name = try self.allocator.dupe(u8, module_name),
            .methods = methods,
            .data = null,
            .allocator = self.allocator,
        };
        const module_val = Value{ .trait_value = tv };

        // 注册到 module_values（键 owned，覆盖时释放旧键）
        if (self.module_values.fetchRemove(module_name)) |old| {
            self.allocator.free(old.key);
        }
        const reg_key = try self.allocator.dupe(u8, module_name);
        try self.module_values.put(reg_key, module_val);

        // 绑定模块名到 global_env（限定访问 Module.member 的入口）；
        // 不覆盖同名已有绑定（如 trait 名占用——分属不同语义但共享 env 时以先到为准）。
        if (self.global_env.get(module_name) == null) {
            try self.global_env.define(module_name, module_val, false);
        }
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
                                    .field_types = try self.allocator.alloc(?[]const u8, con.fields.len),
                                };
                                for (con.fields, 0..) |field, i| {
                                    ctx.field_names[i] = if (field.name) |n| try self.allocator.dupe(u8, n) else null;
                                    ctx.field_types[i] = try self.builtinFieldTypeName(field.ty);
                                }
                                try self.adt_constructor_contexts.append(self.allocator, ctx);
                                // 构造器始终私有（文档 4.4.1: ADT 构造器私有）
                                try environment.defineWithVisibility(con.name, Value{ .builtin = value.Builtin{
                                    .fn_ptr = struct {
                                        fn call(ctx_ptr: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                            const ev: *Evaluator = @ptrCast(@alignCast(ctx_ptr));
                                            const data: *AdtConstructorCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                            if (args.len != data.field_names.len) {
                                                ev.setErrMsg("constructor '{s}' expects {d} argument(s), got {d}", .{ data.constructor_name, data.field_names.len, args.len }, "constructor: wrong number of arguments");
                                                return error.WrongArity;
                                            }

                                            const av = try ev.allocator.create(value.AdtValue);
                                            const fields = try ev.allocator.alloc(value.AdtField, args.len);
                                            for (args, 0..) |arg, i| {
                                                // 把实参强制转换到声明的字段类型（如 i32），与函数形参一致。
                                                const coerced = if (data.field_types[i]) |tn| (ev.castValue(arg, tn) catch arg) else arg;
                                                fields[i] = value.AdtField{
                                                    .name = if (data.field_names[i]) |n| try ev.allocator.dupe(u8, n) else null,
                                                    .value = coerced,
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
                            .field_types = try self.allocator.alloc(?[]const u8, rec_def.fields.len),
                        };
                        for (rec_def.fields, 0..) |field, i| {
                            ctx.field_names[i] = try self.allocator.dupe(u8, field.name);
                            ctx.field_types[i] = try self.builtinFieldTypeName(field.ty);
                        }
                        try self.record_constructor_contexts.append(self.allocator, ctx);
                        try environment.defineWithVisibility(td.name, Value{ .builtin = value.Builtin{
                            .fn_ptr = struct {
                                fn call(ctx_ptr: *anyopaque, user_ctx: ?*anyopaque, args: []const Value) anyerror!Value {
                                    const ev: *Evaluator = @ptrCast(@alignCast(ctx_ptr));
                                    const data: *RecordConstructorCtx = @ptrCast(@alignCast(user_ctx orelse return error.TypeMismatch));
                                    if (args.len != data.field_names.len) {
                                        ev.setErrMsg("constructor '{s}' expects {d} field(s), got {d}", .{ data.type_name, data.field_names.len, args.len }, "constructor: wrong number of arguments");
                                        return error.WrongArity;
                                    }

                                    var map = std.StringHashMap(Value).init(ev.allocator);
                                    for (args, 0..) |arg, i| {
                                        const key = try ev.allocator.dupe(u8, data.field_names[i]);
                                        const coerced = if (data.field_types[i]) |tn| (ev.castValue(arg, tn) catch arg) else arg;
                                        try map.put(key, coerced);
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
                        // 注意：模块求值共享 global_env，若导出 env 与目标 env 是
                        // 同一张表（依赖已预加载进 global_env），其 pub 符号已在作用域内，
                        // 再 put 会在迭代中改写同一 map 导致迭代器失效——直接跳过。
                        if (export_info.env != environment) {
                            var iter = export_info.env.values.iterator();
                            while (iter.next()) |entry| {
                                if (entry.value_ptr.is_public) {
                                    try environment.defineWithVisibility(entry.key_ptr.*, entry.value_ptr.value, false, is_reexport);
                                }
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
        // 记录当前表达式位置（覆盖式）。panic 发生时，最近一次更新即最内层正在求值的
        // 表达式，用于运行时错误报告行列。
        self.current_loc = ast.exprLocation(expr);
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
            .compound_assign => |ca| self.evalCompoundAssign(ca, environment),
            .lazy => |lz| {
                // 文档 §6.10: lazy expr 构建延迟求值 thunk，首次访问时计算并缓存
                const lazy_v = try self.allocator.create(value.LazyValue);
                lazy_v.* = value.LazyValue{
                    .expr = lz.expr,
                    .env = @ptrCast(environment),
                    .cached = null,
                    .forced = false,
                    .allocator = self.allocator,
                };
                try self.lazy_values.append(self.allocator, lazy_v);
                return Value{ .lazy_val = lazy_v };
            },
            .select => |sel| self.evalSelect(sel, environment),
            .monad_comprehension => |mc| self.evalMonadComprehension(mc, environment),
            .inline_trait_value => |itv| self.evalInlineTraitValue(itv, environment),
        };
    }

    fn evalIntLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        // 解析整数值：先尝试 u128（支持完整 u128 范围），再尝试 i128（负数字面量）
        const int_val: u128 = parseInt(u128, raw) catch
            @bitCast(parseInt(i128, raw) catch
                return self.gluePanic("arithmetic overflow: integer literal out of range"));

        // 如果有类型后缀，使用后缀指定的类型
        if (suffix) |s| {
            return self.castInteger(int_val, .i32, s);
        }

        // 无后缀：自动推断最小适用类型
        const inferred_type = inferIntType(int_val);
        if (!inferred_type.inRange(int_val)) return self.gluePanic("arithmetic overflow: integer literal out of range");
        return Value{ .integer = IntValue{ .value = int_val, .type_tag = inferred_type } };
    }

    fn evalFloatLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        const float_val = parseFloat(f128, raw) catch
            return self.gluePanic("invalid floating-point literal");

        // 文档要求：浮点数不包含 NaN 和 Infinity 值
        if (std.math.isNan(float_val) or std.math.isInf(float_val)) {
            return self.gluePanic("arithmetic overflow: floating-point literal out of range");
        }

        if (suffix) |s| {
            // 显式后缀：使用指定类型，检查范围
            const target_type = FloatType.fromName(s) orelse
                return self.gluePanic("invalid float type suffix");
            // 验证值在目标类型范围内
            switch (target_type) {
                .f16 => {
                    const f16_val: f16 = @floatCast(float_val);
                    if (std.math.isNan(f16_val) or std.math.isInf(f16_val))
                        return self.gluePanic("arithmetic overflow: floating-point literal out of range");
                },
                .f32 => {
                    const f32_val: f32 = @floatCast(float_val);
                    if (std.math.isNan(f32_val) or std.math.isInf(f32_val))
                        return self.gluePanic("arithmetic overflow: floating-point literal out of range");
                },
                .f64 => {
                    const f64_val: f64 = @floatCast(float_val);
                    if (std.math.isNan(f64_val) or std.math.isInf(f64_val))
                        return self.gluePanic("arithmetic overflow: floating-point literal out of range");
                },
                .f128 => {
                    // f128 always works (already checked NaN/Inf above)
                },
            }
            return Value{ .float = FloatValue{ .value = float_val, .type_tag = target_type } };
        }

        // 无后缀：自动推断最小适用类型（往返检查）
        const inferred_type = inferFloatType(float_val);
        return Value{ .float = FloatValue{ .value = float_val, .type_tag = inferred_type } };
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
                    self.pushRoot(val); // 保护 val：format 可能分配
                    defer self.popRoot();
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.allocator);
                    try val.format(&buf, self.allocator, false);
                    try result.appendSlice(self.allocator, buf.items);
                },
            }
        }

        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    /// 求值 val/var 声明的右侧。
    /// 特例：RHS 是「裸标识符且持有 Atomic」时，别名该 Atomic 引用而非透明 load。
    /// 文档 §3.4.5/§3.2.2：`val c = counter` 浅拷贝 Atomic 引用，使后续 `c += 1`
    /// 与 spawn 捕获共享同一底层原子单元；其它值上下文（算术/比较）仍由
    /// evalIdentifier 透明 load（文档 §3.4.2）。
    fn evalDeclRhs(self: *Evaluator, expr: *const ast.Expr, environment: *Environment) EvalResult!Value {
        if (expr.* == .identifier) {
            if (environment.get(expr.identifier.name)) |v| {
                if (v.value == .atomic_val) return v.value; // 别名，不 load
            }
        }
        return self.evalExpr(expr, environment);
    }

    /// 文档 §6.10: 强制求值 Lazy thunk。首次调用时计算表达式并缓存，
    /// 后续调用直接返回缓存值。
    fn forceLazy(self: *Evaluator, lz: *value.LazyValue) EvalResult!Value {
        if (lz.forced) {
            return lz.cached.?;
        }
        const lazy_env: *Environment = @ptrCast(@alignCast(lz.env));
        const result = try self.evalExpr(lz.expr, lazy_env);
        lz.cached = result;
        lz.forced = true;
        return result;
    }

    fn evalIdentifier(self: *Evaluator, id: @TypeOf(@as(ast.Expr, undefined).identifier), environment: *Environment) EvalResult!Value {
        if (environment.get(id.name)) |v| {
            // Atomic<T> 透明操作：读取时使用 atomic_load
            if (v.value == .atomic_val) {
                return v.value.atomic_val.load();
            }
            // Lazy<T> 透明操作（文档 §6.10）：首次访问时计算并缓存
            if (v.value == .lazy_val) {
                return self.forceLazy(v.value.lazy_val);
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
        // 保护 val：后续求值可能触发 GC
        self.pushRoot(val);
        defer self.popRoot();

        switch (ae.target.*) {
            .identifier => |id| {
                environment.set(id.name, val) catch |err| {
                    if (err == error.ImmutableAssignment) {
                        self.setErrMsg("cannot assign to immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{id.name}, "cannot assign to immutable binding");
                    }
                    return err;
                };
            },
            .index => |idx| {
                const object = try self.evalExpr(idx.object, environment);
                self.pushRoot(object);
                const index_val = try self.evalExpr(idx.index, environment);
                defer self.popRoot(); // pop object
                switch (object) {
                    .array => |*arr| {
                        const i_val = switch (index_val) {
                            .integer => |iv| iv,
                            else => return error.TypeMismatch,
                        };
                        const i: i128 = if (i_val.type_tag.isSigned()) i_val.signedValue() else @intCast(i_val.value);
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

    fn evalCompoundAssign(self: *Evaluator, ca: @TypeOf(@as(ast.Expr, undefined).compound_assign), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(ca.value, environment);

        // 如果目标是标识符且持有 Atomic 值，使用原子 fetch 操作
        switch (ca.target.*) {
            .identifier => |id| {
                if (environment.getPtr(id.name)) |variable| {
                    if (variable.value == .atomic_val) {
                        const av = variable.value.atomic_val;
                        const operand = value.valueToAtomicRaw(val, av.type_tag);
                        switch (ca.op) {
                            .add_assign => {
                                _ = av.fetchAdd(operand);
                                return av.load();
                            },
                            .sub_assign => {
                                _ = av.fetchSub(operand);
                                return av.load();
                            },
                            .mul_assign => {
                                _ = av.fetchMul(operand);
                                return av.load();
                            },
                            .div_assign => {
                                // CAS loop for division
                                while (true) {
                                    const current = av.data.load(.seq_cst);
                                    const current_val = av.load();
                                    const result = try self.evalDiv(current_val, val, ca.location);
                                    const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                                    if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst)) |_| {
                                        continue;
                                    }
                                    return result;
                                }
                            },
                            .mod_assign => {
                                // CAS loop for modulo
                                while (true) {
                                    const current = av.data.load(.seq_cst);
                                    const current_val = av.load();
                                    const result = try self.evalMod(current_val, val, ca.location);
                                    const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                                    if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst)) |_| {
                                        continue;
                                    }
                                    return result;
                                }
                            },
                            .bit_and_assign => {
                                _ = av.fetchAnd(operand);
                                return av.load();
                            },
                            .bit_or_assign => {
                                _ = av.fetchOr(operand);
                                return av.load();
                            },
                        }
                    }
                }
            },
            else => {},
        }

        // 非 Atomic 路径：读取当前值，执行二元运算，赋值，返回新值
        const current = try self.evalExpr(ca.target, environment);
        const result = switch (ca.op) {
            .add_assign => try self.evalAdd(current, val),
            .sub_assign => try self.evalSub(current, val),
            .mul_assign => try self.evalMul(current, val),
            .div_assign => try self.evalDiv(current, val, ca.location),
            .mod_assign => try self.evalMod(current, val, ca.location),
            .bit_and_assign => {
                if (current == .integer and val == .integer) {
                    const result_type = current.integer.type_tag;
                    const r = current.integer.value & val.integer.value;
                    if (!result_type.inRange(r)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = r, .type_tag = result_type } };
                }
                return self.gluePanic("bitwise & requires integer operands");
            },
            .bit_or_assign => {
                if (current == .integer and val == .integer) {
                    const result_type = current.integer.type_tag;
                    const r = current.integer.value | val.integer.value;
                    if (!result_type.inRange(r)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = r, .type_tag = result_type } };
                }
                return self.gluePanic("bitwise | requires integer operands");
            },
        };

        // 赋值新值
        switch (ca.target.*) {
            .identifier => |id| {
                environment.set(id.name, result) catch |err| {
                    if (err == error.ImmutableAssignment) {
                        self.setErrMsg("cannot assign to immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{id.name}, "cannot assign to immutable binding");
                    }
                    return err;
                };
            },
            else => return self.gluePanic("invalid assignment target"),
        }

        return result;
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
        // 保护 left：求值 right 期间可能触发 GC
        self.pushRoot(left);
        defer self.popRoot();
        const right = try self.evalExpr(bin.right, environment);

        switch (bin.op) {
            .add => return self.evalAdd(left, right),
            .sub => return self.evalSub(left, right),
            .mul => return self.evalMul(left, right),
            .div => return self.evalDiv(left, right, bin.location),
            .mod => return self.evalMod(left, right, bin.location),
            .eq => {
                if (left == .integer and right == .integer) {
                    const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
                    const lv: i128 = if (result_type.isSigned()) @bitCast(left.integer.value) else @intCast(left.integer.value);
                    const rv: i128 = if (result_type.isSigned()) @bitCast(right.integer.value) else @intCast(right.integer.value);
                    return Value{ .boolean = lv == rv };
                }
                if (left == .float and right == .float) {
                    return Value{ .boolean = left.float.value == right.float.value };
                }
                return Value{ .boolean = left.equals(right) };
            },
            .not_eq => {
                if (left == .integer and right == .integer) {
                    const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
                    const lv: i128 = if (result_type.isSigned()) @bitCast(left.integer.value) else @intCast(left.integer.value);
                    const rv: i128 = if (result_type.isSigned()) @bitCast(right.integer.value) else @intCast(right.integer.value);
                    return Value{ .boolean = lv != rv };
                }
                if (left == .float and right == .float) {
                    return Value{ .boolean = left.float.value != right.float.value };
                }
                return Value{ .boolean = !left.equals(right) };
            },
            .lt => return self.evalLt(left, right),
            .gt => return self.evalGt(left, right),
            .lt_eq => return self.evalLtEq(left, right),
            .gt_eq => return self.evalGtEq(left, right),
            .concat => return self.evalConcat(left, right),
            .concat_list => return self.evalConcatList(left, right),
            .range => {
                const left_int: i128 = if (left.integer.type_tag.isSigned()) left.integer.signedValue() else @intCast(left.integer.value);
                const right_int: i128 = if (right.integer.type_tag.isSigned()) right.integer.signedValue() else @intCast(right.integer.value);
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = false } };
            },
            .range_inclusive => {
                const left_int: i128 = if (left.integer.type_tag.isSigned()) left.integer.signedValue() else @intCast(left.integer.value);
                const right_int: i128 = if (right.integer.type_tag.isSigned()) right.integer.signedValue() else @intCast(right.integer.value);
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = true } };
            },
            .bit_and => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value & right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("bitwise & requires integer operands");
            },
            .bit_or => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value | right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("bitwise | requires integer operands");
            },
            .bit_xor => {
                if (left == .integer and right == .integer) {
                    const result_type = left.integer.type_tag;
                    const result = left.integer.value ^ right.integer.value;
                    if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                    return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                }
                return self.gluePanic("bitwise ^ requires integer operands");
            },
            else => unreachable,
        }
    }

    /// 检查浮点运算结果是否为 NaN 或 Infinity，若是则 panic，否则返回 Value
    /// 保留操作数的 FloatType（f16/f32/f64 运算结果需额外检查精度范围）
    fn checkFloatResult(self: *Evaluator, result: f128, type_tag: FloatType) EvalResult!Value {
        if (std.math.isNan(result) or std.math.isInf(result)) {
            return self.gluePanic("arithmetic overflow: floating-point operation out of range");
        }
        // 检查结果是否在目标类型范围内
        switch (type_tag) {
            .f16 => {
                const f16_result: f16 = @floatCast(result);
                if (std.math.isNan(f16_result) or std.math.isInf(f16_result))
                    return self.gluePanic("arithmetic overflow: floating-point operation out of range");
            },
            .f32 => {
                const f32_result: f32 = @floatCast(result);
                if (std.math.isNan(f32_result) or std.math.isInf(f32_result))
                    return self.gluePanic("arithmetic overflow: floating-point operation out of range");
            },
            .f64 => {
                const f64_result: f64 = @floatCast(result);
                if (std.math.isNan(f64_result) or std.math.isInf(f64_result))
                    return self.gluePanic("arithmetic overflow: floating-point operation out of range");
            },
            .f128 => {
                // f128 always works (already checked NaN/Inf above)
            },
        }
        return Value{ .float = FloatValue{ .value = result, .type_tag = type_tag } };
    }

    /// 将整数值转换为 f128（根据有符号/无符号类型正确解释）
    fn integerToFloat(iv: IntValue) f128 {
        return if (iv.type_tag.isSigned())
            @floatFromInt(@as(i128, @bitCast(iv.value)))
        else
            @floatFromInt(iv.value);
    }

    /// 确定两个浮点操作数运算结果的 FloatType
    fn resultFloatTag(left: FloatValue, right: FloatValue) FloatType {
        return promoteFloatTypes(left.type_tag, right.type_tag);
    }

    fn evalAdd(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            const result: u128 = if (result_type.isSigned())
                @bitCast(@as(i128, @bitCast(left.integer.value)) +% @as(i128, @bitCast(right.integer.value)))
            else
                left.integer.value +% right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float.value + right.float.value, resultFloatTag(left.float, right.float));
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(integerToFloat(left.integer) + right.float.value, right.float.type_tag);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float.value + integerToFloat(right.integer), left.float.type_tag);
        }
        if (left == .string and right == .string) {
            var result = std.ArrayList(u8).empty;
            try result.appendSlice(self.allocator, left.string);
            try result.appendSlice(self.allocator, right.string);
            return Value{ .string = try result.toOwnedSlice(self.allocator) };
        }
        return self.gluePanicFmt("operator '+' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '+'");
    }

    fn evalSub(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            const result: u128 = if (result_type.isSigned())
                @bitCast(@as(i128, @bitCast(left.integer.value)) -% @as(i128, @bitCast(right.integer.value)))
            else
                left.integer.value -% right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float.value - right.float.value, resultFloatTag(left.float, right.float));
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(integerToFloat(left.integer) - right.float.value, right.float.type_tag);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float.value - integerToFloat(right.integer), left.float.type_tag);
        }
        return self.gluePanicFmt("operator '-' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '-'");
    }

    fn evalMul(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            const result: u128 = if (result_type.isSigned())
                @bitCast(@as(i128, @bitCast(left.integer.value)) *% @as(i128, @bitCast(right.integer.value)))
            else
                left.integer.value *% right.integer.value;
            if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
        }
        if (left == .float and right == .float) {
            return self.checkFloatResult(left.float.value * right.float.value, resultFloatTag(left.float, right.float));
        }
        if (left == .integer and right == .float) {
            return self.checkFloatResult(integerToFloat(left.integer) * right.float.value, right.float.type_tag);
        }
        if (left == .float and right == .integer) {
            return self.checkFloatResult(left.float.value * integerToFloat(right.integer), left.float.type_tag);
        }
        return self.gluePanicFmt("operator '*' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '*'");
    }

    fn evalDiv(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            if (result_type.isSigned()) {
                const left_signed: i128 = @bitCast(left.integer.value);
                const right_signed: i128 = @bitCast(right.integer.value);
                // 检查有符号最小值 / -1 溢出
                if (left_signed == std.math.minInt(i128) and right_signed == -1) {
                    return self.gluePanic("arithmetic overflow: integer operation out of range");
                }
                const result = @divTrunc(left_signed, right_signed);
                if (!result_type.inRange(@bitCast(result))) return self.gluePanic("arithmetic overflow: integer operation out of range");
                return Value{ .integer = IntValue{ .value = @bitCast(result), .type_tag = result_type } };
            } else {
                const result = left.integer.value / right.integer.value;
                return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
            }
        }
        if (left == .float and right == .float) {
            if (right.float.value == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(left.float.value / right.float.value, resultFloatTag(left.float, right.float));
        }
        if (left == .integer and right == .float) {
            if (right.float.value == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(integerToFloat(left.integer) / right.float.value, right.float.type_tag);
        }
        if (left == .float and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(left.float.value / integerToFloat(right.integer), left.float.type_tag);
        }
        return self.gluePanicFmt("operator '/' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '/'");
    }

    fn evalMod(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer.value == 0) return self.gluePanic("arithmetic error: division by zero");
            const result_type = promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            if (result_type.isSigned()) {
                // 取余须与除法（@divTrunc，向零截断）保持一致：使用 @rem，
                // 余数符号跟随被除数，满足 (a/b)*b + a%b == a（Go/Java/C 语义）。
                const result = @rem(@as(i128, @bitCast(left.integer.value)), @as(i128, @bitCast(right.integer.value)));
                if (!result_type.inRange(@bitCast(result))) return self.gluePanic("arithmetic overflow: integer operation out of range");
                return Value{ .integer = IntValue{ .value = @bitCast(result), .type_tag = result_type } };
            } else {
                const result = left.integer.value % right.integer.value;
                return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
            }
        }
        if (left == .float and right == .float) {
            if (right.float.value == 0.0) return self.gluePanic("arithmetic error: division by zero");
            return self.checkFloatResult(@rem(left.float.value, right.float.value), resultFloatTag(left.float, right.float));
        }
        return self.gluePanicFmt("operator '%' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '%'");
    }

    fn evalLt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            if (left.integer.type_tag.isSigned()) {
                return Value{ .boolean = @as(i128, @bitCast(left.integer.value)) < @as(i128, @bitCast(right.integer.value)) };
            } else {
                return Value{ .boolean = left.integer.value < right.integer.value };
            }
        }
        if (left == .float and right == .float) return Value{ .boolean = left.float.value < right.float.value };
        if (left == .integer and right == .float) return Value{ .boolean = integerToFloat(left.integer) < right.float.value };
        if (left == .float and right == .integer) return Value{ .boolean = left.float.value < integerToFloat(right.integer) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val < right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .lt };
        return self.gluePanicFmt("operator '<' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '<'");
    }

    fn evalGt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            if (left.integer.type_tag.isSigned()) {
                return Value{ .boolean = @as(i128, @bitCast(left.integer.value)) > @as(i128, @bitCast(right.integer.value)) };
            } else {
                return Value{ .boolean = left.integer.value > right.integer.value };
            }
        }
        if (left == .float and right == .float) return Value{ .boolean = left.float.value > right.float.value };
        if (left == .integer and right == .float) return Value{ .boolean = integerToFloat(left.integer) > right.float.value };
        if (left == .float and right == .integer) return Value{ .boolean = left.float.value > integerToFloat(right.integer) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val > right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .gt };
        return self.gluePanicFmt("operator '>' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '>'");
    }

    fn evalLtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            if (left.integer.type_tag.isSigned()) {
                return Value{ .boolean = @as(i128, @bitCast(left.integer.value)) <= @as(i128, @bitCast(right.integer.value)) };
            } else {
                return Value{ .boolean = left.integer.value <= right.integer.value };
            }
        }
        if (left == .float and right == .float) return Value{ .boolean = left.float.value <= right.float.value };
        if (left == .integer and right == .float) return Value{ .boolean = integerToFloat(left.integer) <= right.float.value };
        if (left == .float and right == .integer) return Value{ .boolean = left.float.value <= integerToFloat(right.integer) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val <= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .gt };
        return self.gluePanicFmt("operator '<=' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '<='");
    }

    fn evalGtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            if (left.integer.type_tag.isSigned()) {
                return Value{ .boolean = @as(i128, @bitCast(left.integer.value)) >= @as(i128, @bitCast(right.integer.value)) };
            } else {
                return Value{ .boolean = left.integer.value >= right.integer.value };
            }
        }
        if (left == .float and right == .float) return Value{ .boolean = left.float.value >= right.float.value };
        if (left == .integer and right == .float) return Value{ .boolean = integerToFloat(left.integer) >= right.float.value };
        if (left == .float and right == .integer) return Value{ .boolean = left.float.value >= integerToFloat(right.integer) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val >= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .lt };
        return self.gluePanicFmt("operator '>=' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '>='");
    }

    fn evalConcat(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        const left_str = switch (left) {
            .string => |s| s,
            else => return self.gluePanicFmt("operator '+' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '+'"),
        };
        const right_str = switch (right) {
            .string => |s| s,
            else => return self.gluePanicFmt("operator '+' cannot be applied to operands of type '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '+'"),
        };
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(self.allocator, left_str);
        try result.appendSlice(self.allocator, right_str);
        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    /// ++ 数组拼接：把两个数组首尾相接，返回新的动态数组（元素深拷贝）。
    fn evalConcatList(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        const left_arr = switch (left) {
            .array => |a| a,
            else => return self.gluePanicFmt("operator '++' requires array operands, got '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '++'"),
        };
        const right_arr = switch (right) {
            .array => |a| a,
            else => return self.gluePanicFmt("operator '++' requires array operands, got '{s}' and '{s}'", .{ typeNameOf(left), typeNameOf(right) }, "type error: invalid operands for '++'"),
        };
        const new_arr = try self.allocator.alloc(Value, left_arr.elements.len + right_arr.elements.len);
        for (left_arr.elements, 0..) |e, i| {
            new_arr[i] = try e.clone(self.allocator);
        }
        for (right_arr.elements, 0..) |e, i| {
            new_arr[left_arr.elements.len + i] = try e.clone(self.allocator);
        }
        return Value{ .array = .{ .elements = new_arr, .fixed_size = null } };
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
                    if (result_type.isSigned()) {
                        const result: u128 = @bitCast(-%@as(i128, @bitCast(iv.value)));
                        if (!result_type.inRange(result)) return self.gluePanic("arithmetic overflow: integer operation out of range");
                        return Value{ .integer = IntValue{ .value = result, .type_tag = result_type } };
                    } else {
                        return self.gluePanic("arithmetic error: cannot negate unsigned integer");
                    }
                },
                .float => |fv| {
                    return self.checkFloatResult(-fv.value, fv.type_tag);
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
                // 类型转换的实参不在尾位置（同 evalCall 主路径的理由）
                const saved_tail_cast = self.in_tail_position;
                self.in_tail_position = false;
                defer self.in_tail_position = saved_tail_cast;
                const arg = try self.evalExpr(call.arguments[0], environment);
                return self.castValue(arg, name);
            }
        }

        // 尾位置只作用于「函数应用」本身，不传递给 callee 和实参。
        // evalExpr 对 .call 保留 in_tail_position（用于 TCO trampoline），
        // 但 callee 与实参的子表达式都不在尾位置——否则作为实参的函数调用
        // （如 println(f(7)) 中的 f(7)）会错误地触发 error.TailCall，
        // 劫持外层函数的 trampoline。求值它们时必须先关闭尾位置标记。
        const saved_tail_pos = self.in_tail_position;
        self.in_tail_position = false;

        const callee = try self.evalExpr(call.callee, environment);

        // 保护 callee：求值参数期间可能触发 GC
        self.pushRoot(callee);
        defer self.popRoot();

        // 求值参数
        var args = std.ArrayList(Value).empty;
        for (call.arguments) |arg_expr| {
            const arg = try self.evalExpr(arg_expr, environment);
            self.pushRoot(arg);
            try args.append(self.allocator, arg);
            // arg 已复制到 args 中，但 pushRoot 保护直到函数返回
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存（如数组切片）
        defer {
            args.deinit(self.allocator);
            self.popRoots(args.items.len); // 弹出所有参数的 root
        }

        // 恢复尾位置标记，供本次函数应用的 TCO 判断使用
        self.in_tail_position = saved_tail_pos;

        // Trait 方法的类型导向重分派：
        // impl 方法同时按裸名注册进环境，多个 impl 同名方法（如 Monad<List>.bind 与
        // Monad<Box>.bind）会互相覆盖，env 里只剩最后一个。当一个裸标识符调用对应
        // 多个不同类型的 impl 方法时，按第一个实参的运行时类型重新解析到正确的 impl，
        // 使 `bind(t, f)` 在 t 是 List 时用 List.bind、是 Box 时用 Box.bind。
        if (call.callee.* == .identifier and args.items.len > 0) {
            if (self.redispatchTraitMethod(call.callee.identifier.name, args.items[0])) |c| {
                return self.callFunction(Value{ .closure = c }, args.items, environment);
            }
        }

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

    /// 若 method_name 对应多个不同类型的 impl 方法，按 receiver 运行时类型选出
    /// 匹配的 impl 闭包；无歧义（0 或 1 个 impl）时返回 null，走普通环境解析。
    fn redispatchTraitMethod(self: *Evaluator, method_name: []const u8, receiver: Value) ?*value.Closure {
        const recv_type = valueTypeName(receiver) orelse return null;
        var match_count: usize = 0;
        var matched: ?*value.Closure = null;
        var name_count: usize = 0;
        for (self.impl_methods.items) |entry| {
            if (!std.mem.eql(u8, entry.method_name, method_name)) continue;
            name_count += 1;
            if (std.mem.eql(u8, entry.type_name, recv_type)) {
                matched = entry.closure;
                match_count += 1;
            }
        }
        // 只有当该方法名存在多个 impl（有歧义）且能按类型唯一匹配时才重分派
        if (name_count >= 2 and match_count == 1) return matched;
        return null;
    }

    fn callFunction(self: *Evaluator, callee: Value, args: []const Value, environment: ?*Environment) EvalResult!Value {
        _ = environment;

        // 递归深度保护：树遍历求值器在宿主栈上递归，非尾递归过深会撑爆原生栈。
        // 超过上限时抛出干净的 Glue panic，而不是无信息的 Zig 崩溃。
        // 深循环应改用尾递归（TCO trampoline 不增长栈）。
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) {
            return self.gluePanic("stack overflow: recursion too deep (use tail recursion for deep loops)");
        }

        switch (callee) {
            .partial => |pa| {
                // 合并已绑定参数和新参数
                const total = pa.bound_args.len + args.len;

                if (total == pa.remaining + pa.bound_args.len) {
                    // 参数足够，执行原始函数
                    var all_args = try self.allocator.alloc(Value, total);
                    defer self.allocator.free(all_args);
                    @memcpy(all_args[0..pa.bound_args.len], pa.bound_args);
                    @memcpy(all_args[pa.bound_args.len..], args);
                    return self.callFunction(pa.func, all_args, null);
                } else if (total < pa.remaining + pa.bound_args.len) {
                    // 参数仍不足，继续部分应用
                    return self.createPartialApplication(pa.func, pa.bound_args, args, pa.remaining + pa.bound_args.len - total);
                } else {
                    // 参数过多
                    return error.WrongArity;
                }
            },
            .closure => |initial_closure| {
                // 默认柯里化：参数不足时返回部分应用
                if (args.len < initial_closure.params.len) {
                    return self.createPartialApplication(callee, &[_]Value{}, args, initial_closure.params.len - args.len);
                }
                // 参数过多
                if (args.len > initial_closure.params.len) {
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
                        // 如果参数有类型注解，将实参转换为目标类型
                        const arg_val = if (param.type_annotation) |ta| blk: {
                            switch (ta.*) {
                                .named => |n| {
                                    if (isBuiltinType(n.name)) {
                                        break :blk self.castValue(current_args[i], n.name) catch current_args[i];
                                    }
                                },
                                else => {},
                            }
                            break :blk current_args[i];
                        } else current_args[i];
                        try call_env.define(param.name, arg_val, param.is_var);
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
            else => return self.gluePanicFmt("type '{s}' is not callable", .{typeNameOf(callee)}, "value is not callable"),
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: @TypeOf(@as(ast.Expr, undefined).method_call), environment: *Environment) EvalResult!Value {
        // 尾位置不传递给方法接收者与实参（同 evalCall 的理由）
        const saved_tail_mc = self.in_tail_position;
        self.in_tail_position = false;
        defer self.in_tail_position = saved_tail_mc;

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

        // 保护 object：求值参数期间可能触发 GC
        self.pushRoot(object);
        defer self.popRoot();

        // 求值参数
        var args = std.ArrayList(Value).empty;
        const root_count_before = self.shadow_stack.items.len;
        for (mc.arguments) |arg_expr| {
            const arg = try self.evalExpr(arg_expr, environment);
            self.pushRoot(arg);
            try args.append(self.allocator, arg);
        }
        // 注意：不 deinit 参数值，因为它们可能与环境中的变量共享内存
        defer {
            args.deinit(self.allocator);
            self.popRoots(self.shadow_stack.items.len - root_count_before);
        }

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
            .float => |fv| @tagName(fv.type_tag),
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
            .partial => "partial",
            .array_iterator => "array_iterator",
            .string_iterator => "string_iterator",
            .range_iterator => "range_iterator",
            .atomic_val => "Atomic",
            .spawn_val => "Spawn",
            .channel_val => "Channel",
            .sender_val => "Sender",
            .receiver_val => "Receiver",
            .trait_value => |tv| if (tv.trait_name.len > 0) tv.trait_name else "trait",
            .lazy_val => "Lazy",
        };
    }

    /// 文档 §4.6.3: 内联 Trait 值 `trait { fun m(..){...} }`。
    /// 把每个方法编译为闭包，构建 vtable（无 data 载荷）。
    fn evalInlineTraitValue(self: *Evaluator, itv: @TypeOf(@as(ast.Expr, undefined).inline_trait_value), environment: *Environment) EvalResult!Value {
        const tv = try self.allocator.create(value.TraitValue);
        var methods = std.StringHashMap(Value).init(self.allocator);
        for (itv.methods) |method| {
            if (method.body) |body| {
                const closure = try self.allocator.create(value.Closure);
                closure.* = value.Closure{
                    .params = method.params,
                    .body = .{ .block = body },
                    .env = @ptrCast(environment),
                    .allocator = self.allocator,
                };
                try self.closures.append(self.allocator, closure);
                const key = try self.allocator.dupe(u8, method.name);
                try methods.put(key, Value{ .closure = closure });
            }
        }
        tv.* = value.TraitValue{
            .trait_name = "",
            .methods = methods,
            .data = null,
            .allocator = self.allocator,
        };
        return Value{ .trait_value = tv };
    }

    fn callMethod(self: *Evaluator, object: Value, method: []const u8, args: []const Value, environment: ?*Environment) EvalResult!Value {
        // 文档 §4.6/§4.7: 一等 Trait 值方法调用——经 vtable 分派。
        if (object == .trait_value) {
            const tv = object.trait_value;
            if (tv.methods.get(method)) |impl_fn| {
                // 若有 data 载荷（文件模块作为 trait 值），作为首个 receiver 实参；
                // 内联 trait 值无 data，直接用调用实参。
                if (tv.data) |d| {
                    var full = try self.allocator.alloc(Value, args.len + 1);
                    defer self.allocator.free(full);
                    full[0] = d.*;
                    @memcpy(full[1..], args);
                    return self.callFunction(impl_fn, full, environment);
                }
                return self.callFunction(impl_fn, args, environment);
            }
            // 成员不在 vtable 中：要么不存在，要么是模块的非 pub（私有）符号。
            const owner = if (tv.trait_name.len > 0) tv.trait_name else "module";
            return self.gluePanicFmt("'{s}' is not an accessible member of '{s}' (it may be private or undefined)", .{ method, owner }, "inaccessible member");
        }

        // 内建方法
        if (std.mem.eql(u8, method, "len")) {
            return switch (object) {
                .string => |s| {
                    // len() 返回 Unicode 标量值（字符数），而非字节数
                    const view = std.unicode.Utf8View.init(s) catch {
                        return Value{ .integer = IntValue{ .value = @as(u128, @intCast(s.len)) } };
                    };
                    var count: u128 = 0;
                    var iter = view.iterator();
                    while (iter.nextCodepoint() != null) {
                        count += 1;
                    }
                    return Value{ .integer = IntValue{ .value = count } };
                },
                .array => |arr| Value{ .integer = IntValue{ .value = @as(u128, @intCast(arr.elements.len)) } },
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
                    if (args.len != 1) return self.gluePanicFmt("method '{s}' expects 1 argument, got {d}", .{ method, args.len }, "wrong number of arguments");
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
                    if (args.len != 1) return self.gluePanicFmt("method '{s}' expects 1 argument, got {d}", .{ method, args.len }, "wrong number of arguments");
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

        if (std.mem.eql(u8, method, "is_empty")) {
            return switch (object) {
                .array => |arr| Value{ .boolean = arr.elements.len == 0 },
                .string => |s| Value{ .boolean = s.len == 0 },
                else => self.gluePanicFmt("method 'is_empty' is not available on type '{s}'", .{typeNameOf(object)}, "no such method"),
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
                            return Value{ .integer = IntValue{ .value = @bitCast(val) } };
                        }
                    } else {
                        if (ri.current < ri.end) {
                            const val = ri.current;
                            ri.current += 1;
                            return Value{ .integer = IntValue{ .value = @bitCast(val) } };
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
                    // 精确匹配；或整数/浮点宽度互通匹配。
                    // 因字面量按「最小类型」推断（5 是 i8），而用户惯常写 impl T<i32>，
                    // 故对数值接收者放宽：任意整数类型可匹配任意整数 impl，浮点同理。
                    // 这与求值器算术的宽度提升一致，避免 `5.method()` 因 i8≠i32 找不到 impl。
                    if (!std.mem.eql(u8, entry.type_name, otn) and
                        !(isNumericTypeName(otn) and isNumericTypeName(entry.type_name) and
                        numericKindMatches(otn, entry.type_name)))
                    {
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
                                (impl_entry.type_name.len == 0 or std.mem.eql(u8, impl_entry.type_name, otn) or
                                (isNumericTypeName(otn) and isNumericTypeName(impl_entry.type_name) and numericKindMatches(otn, impl_entry.type_name))))
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
        // 使用 Zio Mutex/Condition — 在协程上下文中挂起当前协程让出执行权
        if (object == .spawn_val) {
            const handle = object.spawn_val;
            if (std.mem.eql(u8, method, "await")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                // 文档 §3.7: Spawn<T>.await() 挂起当前协程，让出执行权
                // Zio Condition.wait() 在协程上下文中挂起当前协程让出执行权
                handle.mutex.lockUncancelable();
                while (handle.status.load(.seq_cst) == .Pending or handle.status.load(.seq_cst) == .Running) {
                    handle.condition.waitUncancelable(&handle.mutex);
                }
                const result = handle.result;
                handle.consumed.store(true, .seq_cst);
                handle.mutex.unlock();
                if (handle.status.load(.seq_cst) == .Failed) {
                    // 文档 §3.6: Panic 协程隔离
                    // await 时如果子协程 panic，传播 panic 到当前协程
                    const msg = handle.panic_message orelse "spawn: coroutine failed";
                    return self.gluePanic(msg);
                }
                return result orelse Value.unit;
            }
            if (std.mem.eql(u8, method, "cancel")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                handle.mutex.lockUncancelable();
                handle.status.store(.Cancelled, .seq_cst);
                handle.consumed.store(true, .seq_cst);
                handle.condition.broadcast();
                handle.mutex.unlock();
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "status")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                const s = handle.status.load(.seq_cst);
                // 返回 SpawnStatus ADT 值
                return self.makeSpawnStatus(s);
            }
            if (std.mem.eql(u8, method, "result")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                handle.mutex.lockUncancelable();
                if (handle.status.load(.seq_cst) == .Completed) {
                    const r = handle.result;
                    handle.mutex.unlock();
                    return r orelse Value.null_val;
                }
                handle.mutex.unlock();
                return Value.null_val;
            }
        }

        // Channel<T> 方法
        // 文档 D57: 仅 Sender 可关闭 Channel
        if (object == .channel_val) {
            const ch = object.channel_val;
            if (std.mem.eql(u8, method, "send")) {
                if (args.len != 1) return self.gluePanicFmt("method '{s}' expects 1 argument, got {d}", .{ method, args.len }, "wrong number of arguments");
                const ok = ch.send(args[0]) catch return error.OutOfMemory;
                if (!ok) return self.gluePanic("channel: send on closed channel");
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "recv")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                const val = ch.recv();
                return val orelse Value.null_val;
            }
            // close 仅 Sender 可调用，Channel 本身不提供 close 方法
            if (std.mem.eql(u8, method, "close")) {
                return self.gluePanic("channel: close is only available on Sender, use ch.sender.close()");
            }
        }

        // Sender<T> 方法
        if (object == .sender_val) {
            const sv = object.sender_val;
            if (std.mem.eql(u8, method, "send")) {
                if (args.len != 1) return self.gluePanicFmt("method '{s}' expects 1 argument, got {d}", .{ method, args.len }, "wrong number of arguments");
                const ok = sv.channel.send(args[0]) catch return error.OutOfMemory;
                if (!ok) return self.gluePanic("channel: send on closed channel");
                return Value.unit;
            }
            if (std.mem.eql(u8, method, "close")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                sv.channel.close();
                return Value.unit;
            }
        }

        // Receiver<T> 方法
        if (object == .receiver_val) {
            const rv = object.receiver_val;
            if (std.mem.eql(u8, method, "recv")) {
                if (args.len != 0) return self.gluePanicFmt("method '{s}' expects 0 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                const val = rv.channel.recv();
                return val orelse Value.null_val;
            }
        }

        // Atomic<T> 方法
        if (object == .atomic_val) {
            const av = object.atomic_val;
            if (std.mem.eql(u8, method, "cas")) {
                if (args.len != 2) return self.gluePanicFmt("method '{s}' expects 2 arguments, got {d}", .{ method, args.len }, "wrong number of arguments");
                const expected: i128 = @bitCast(try args[0].asInteger());
                const new_val: i128 = @bitCast(try args[1].asInteger());
                return Value{ .boolean = av.cas(expected, new_val) };
            }
            if (std.mem.eql(u8, method, "swap")) {
                if (args.len != 1) return self.gluePanicFmt("method '{s}' expects 1 argument, got {d}", .{ method, args.len }, "wrong number of arguments");
                const new_val: i128 = @bitCast(try args[0].asInteger());
                const old_raw = av.xchg(new_val);
                return Value{ .integer = IntValue{ .value = @bitCast(old_raw), .type_tag = value.atomicTypeToIntType(av.type_tag) } };
            }
        }

        return self.gluePanicFmt("no method '{s}' on type '{s}'", .{ method, typeNameOf(object) }, "no such method");
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
                return self.gluePanicFmt("no field '{s}' on type 'record'", .{field}, "no such field");
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
                return self.gluePanicFmt("no field '{s}' on type '{s}'", .{ field, av.type_name }, "no such field");
            },
            .trait_value => |tv| {
                // 文档 §4.6.2: 模块值/Trait 值的成员访问——限定名 `Store.Memory`、
                // `Module.member`（子模块或导出函数）。在 vtable/成员表中查找。
                if (tv.methods.get(field)) |member| {
                    return member;
                }
                return self.gluePanicFmt("no member '{s}' on trait value '{s}'", .{ field, if (tv.trait_name.len > 0) tv.trait_name else "trait" }, "no such member");
            },
            .error_val => |e| {
                // 文档 2.4.1: Error 有 message 字段
                // val e = Error("not found")
                // e.message    // "not found"
                if (std.mem.eql(u8, field, "message")) {
                    return Value{ .string = try self.allocator.dupe(u8, e.message) };
                }
                return self.gluePanicFmt("no field '{s}' on type 'Error' (only 'message' is available)", .{field}, "no such field");
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
                return self.gluePanicFmt("no field '{s}' on type 'Throw'", .{field}, "no such field");
            },
            else => return self.gluePanicFmt("cannot access field '{s}' on type '{s}'", .{ field, typeNameOf(object) }, "cannot access field"),
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
                return self.gluePanicFmt("no field '{s}' on type 'Channel' (only 'sender' and 'receiver' are available)", .{field}, "no such field");
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
        // 保护 object：求值 index 期间可能触发 GC
        self.pushRoot(object);
        defer self.popRoot();
        const index_val = try self.evalExpr(idx.index, environment);

        switch (object) {
            .array => |arr| {
                const i_val = switch (index_val) {
                    .integer => |iv| iv,
                    else => return self.gluePanicFmt("array index must be an integer, got '{s}'", .{typeNameOf(index_val)}, "type error: non-integer array index"),
                };
                const i: i128 = if (i_val.type_tag.isSigned()) i_val.signedValue() else @intCast(i_val.value);
                if (i < 0 or i >= @as(i128, @intCast(arr.elements.len))) {
                    return self.gluePanicFmt("index {d} out of bounds for length {d}", .{ i, arr.elements.len }, "index out of bounds");
                }
                return arr.elements[@as(usize, @intCast(i))];
            },
            .string => |s| {
                const i_val = switch (index_val) {
                    .integer => |iv| iv,
                    else => return self.gluePanicFmt("string index must be an integer, got '{s}'", .{typeNameOf(index_val)}, "type error: non-integer string index"),
                };
                const i: i128 = if (i_val.type_tag.isSigned()) i_val.signedValue() else @intCast(i_val.value);
                if (i < 0) return self.gluePanicFmt("index {d} out of bounds", .{i}, "index out of bounds");
                // 文档 §2.2: 索引为 O(n) 操作，按字符位置索引，返回 Unicode 标量值
                const view = std.unicode.Utf8View.init(s) catch return self.gluePanic("invalid UTF-8 string");
                var iter = view.iterator();
                var char_idx: i128 = 0;
                while (iter.nextCodepoint()) |cp| {
                    if (char_idx == i) {
                        return Value{ .char_val = @as(u21, @intCast(cp)) };
                    }
                    char_idx += 1;
                }
                return self.gluePanicFmt("index {d} out of bounds for length {d}", .{ i, char_idx }, "index out of bounds");
            },
            else => return self.gluePanicFmt("cannot index into type '{s}'", .{typeNameOf(object)}, "type error: not indexable"),
        }
    }

    fn evalArrayLiteral(self: *Evaluator, al: @TypeOf(@as(ast.Expr, undefined).array_literal), environment: *Environment) EvalResult!Value {
        var arr = try self.allocator.alloc(Value, al.elements.len);
        errdefer {
            for (arr) |*a| a.deinit(self.allocator);
            self.allocator.free(arr);
        }
        const root_count_before = self.shadow_stack.items.len;
        for (al.elements, 0..) |elem, i| {
            arr[i] = try self.evalExpr(elem, environment);
            self.pushRoot(arr[i]); // 保护已求值的元素
        }
        self.popRoots(self.shadow_stack.items.len - root_count_before);
        return Value{ .array = .{ .elements = arr, .fixed_size = null } };
    }

    fn evalRecordLiteral(self: *Evaluator, rl: @TypeOf(@as(ast.Expr, undefined).record_literal), environment: *Environment) EvalResult!Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();

        const root_count_before = self.shadow_stack.items.len;
        for (rl.fields) |field| {
            const key = try self.allocator.dupe(u8, field.name);
            const val = try self.evalExpr(field.value, environment);
            self.pushRoot(val); // 保护已求值的字段值
            try map.put(key, val);
        }
        self.popRoots(self.shadow_stack.items.len - root_count_before);

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
                // 保护 base_val：后续 dupe/evalExpr 可能触发 GC
                self.pushRoot(base_val);
                defer self.popRoot();

                // 复制 base 的所有字段
                var map = std.StringHashMap(Value).init(self.allocator);
                errdefer map.deinit();

                var iter = base_rec.fields.iterator();
                while (iter.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    try map.put(key, entry.value_ptr.*);
                }

                // 应用 updates（覆盖或新增字段）
                const root_count_before = self.shadow_stack.items.len;
                for (re.updates) |update| {
                    const key = try self.allocator.dupe(u8, update.name);
                    const val = try self.evalExpr(update.value, environment);
                    self.pushRoot(val); // 保护已求值的更新值
                    // 如果 key 已存在，put 会覆盖旧值
                    try map.put(key, val);
                }
                self.popRoots(self.shadow_stack.items.len - root_count_before);

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

    /// 在 impl_methods 中查找 (type_name, method_name) 对应的方法闭包。
    fn findImplMethodClosure(self: *Evaluator, type_name: []const u8, method_name: []const u8) ?*value.Closure {
        for (self.impl_methods.items) |entry| {
            if (std.mem.eql(u8, entry.method_name, method_name) and
                std.mem.eql(u8, entry.type_name, type_name))
            {
                return entry.closure;
            }
        }
        return null;
    }

    /// 求值 Monad `@` 上下文表达式（文档 §2.11.2）。
    /// @M { x <- e1  y <- e2  result } 脱糖为：
    ///   bind(e1, fun(x){ bind(e2, fun(y){ pure(result) }) })
    /// bind/pure 取自 `impl Monad<M>`。脱糖为 AST 后求值：把解析到的 bind/pure
    /// 闭包绑定到子环境的保留名 "@bind"/"@pure"（含 @，用户不可能定义同名），
    /// 合成的 AST 用 identifier 引用它们。
    fn evalMonadComprehension(self: *Evaluator, mc: @TypeOf(@as(ast.Expr, undefined).monad_comprehension), environment: *Environment) EvalResult!Value {
        const bind_closure = self.findImplMethodClosure(mc.monad_type, "bind") orelse {
            self.panic_message = std.fmt.allocPrint(self.allocator, "monad: no 'bind' impl for {s}", .{mc.monad_type}) catch "monad: missing bind";
            return error.GluePanic;
        };
        const pure_closure = self.findImplMethodClosure(mc.monad_type, "pure") orelse {
            self.panic_message = std.fmt.allocPrint(self.allocator, "monad: no 'pure' impl for {s}", .{mc.monad_type}) catch "monad: missing pure";
            return error.GluePanic;
        };

        const loc = mc.location;
        const bind_id = try self.makeIdentExpr("@bind", loc);
        const pure_id = try self.makeIdentExpr("@pure", loc);

        // 从最内层向外折叠：acc 初始为 pure(result)，再对每个绑定（逆序）包一层 bind。
        var acc = try self.makeCallExpr(pure_id, &[_]*ast.Expr{@constCast(mc.result)}, loc);
        var i: usize = mc.bindings.len;
        while (i > 0) {
            i -= 1;
            const b = mc.bindings[i];
            // fun(b.name) { acc }
            const params = try self.allocator.alloc(ast.Param, 1);
            params[0] = ast.Param{ .location = loc, .name = b.name, .type_annotation = null, .is_var = false };
            const lambda = try self.allocator.create(ast.Expr);
            lambda.* = ast.Expr{ .lambda = .{ .location = loc, .params = params, .body = .{ .expression = acc } } };
            // @bind(b.expr, lambda)
            acc = try self.makeCallExpr(bind_id, &[_]*ast.Expr{ @constCast(b.expr), lambda }, loc);
        }

        // 子环境绑定 @bind/@pure 到解析出的闭包，再求值合成 AST
        const child = try environment.createChild();
        try child.define("@bind", Value{ .closure = bind_closure }, false);
        try child.define("@pure", Value{ .closure = pure_closure }, false);
        return self.evalExpr(acc, child);
    }

    /// 合成 identifier 表达式（用于 monad 脱糖）
    fn makeIdentExpr(self: *Evaluator, name: []const u8, loc: ast.SourceLocation) !*ast.Expr {
        const e = try self.allocator.create(ast.Expr);
        e.* = ast.Expr{ .identifier = .{ .location = loc, .name = name } };
        return e;
    }

    /// 合成 call 表达式（用于 monad 脱糖）
    fn makeCallExpr(self: *Evaluator, callee: *ast.Expr, args: []const *ast.Expr, loc: ast.SourceLocation) !*ast.Expr {
        const owned_args = try self.allocator.dupe(*ast.Expr, args);
        const e = try self.allocator.create(ast.Expr);
        e.* = ast.Expr{ .call = .{ .location = loc, .callee = callee, .arguments = owned_args, .type_args = null } };
        return e;
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

    /// 创建部分应用值 — 默认柯里化的核心
    /// 文档 §2.8.1: val add5 = add(5)  // 部分应用
    fn createPartialApplication(self: *Evaluator, func: Value, existing_bound: []const Value, new_args: []const Value, remaining: usize) EvalResult!Value {
        // 保护 func：后续 alloc/clone 可能触发 GC
        self.pushRoot(func);
        defer self.popRoot();

        const total_bound = existing_bound.len + new_args.len;
        const bound_args = try self.allocator.alloc(Value, total_bound);
        @memcpy(bound_args[0..existing_bound.len], existing_bound);
        for (new_args, 0..) |arg, i| {
            bound_args[existing_bound.len + i] = try arg.clone(self.allocator);
        }

        const pa = try self.allocator.create(value.PartialApplication);
        pa.* = value.PartialApplication{
            .func = try func.clone(self.allocator),
            .bound_args = bound_args,
            .remaining = remaining,
            .allocator = self.allocator,
        };
        return Value{ .partial = pa };
    }

    fn evalTypeCast(self: *Evaluator, tc: @TypeOf(@as(ast.Expr, undefined).type_cast), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(tc.expr, environment);
        const type_name = switch (tc.target_type.*) {
            .named => |n| n.name,
            else => return error.TypeMismatch,
        };
        return self.castValue(val, type_name);
    }

    /// 若字段/形参的类型注解是内建类型（i32/f64/bool/str 等），返回其名字（dup 到 allocator），
    /// 否则返回 null。用于构造器把实参强制转换到声明类型。
    fn builtinFieldTypeName(self: *Evaluator, ty: *const ast.TypeNode) !?[]const u8 {
        switch (ty.*) {
            .named => |n| {
                if (isBuiltinType(n.name)) return try self.allocator.dupe(u8, n.name);
                return null;
            },
            else => return null,
        }
    }

    fn castValue(self: *Evaluator, val: Value, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "str")) {
            return self.valueToString(val);
        }
        if (val == .integer) {
            return self.castInteger(val.integer.value, val.integer.type_tag, type_name);
        }
        if (val == .float) {
            return self.castFloat(val.float.value, type_name);
        }
        if (val == .boolean) {
            if (std.mem.eql(u8, type_name, "str")) {
                return self.valueToString(val);
            }
            return error.TypeMismatch;
        }
        return error.TypeMismatch;
    }

    fn castInteger(self: *Evaluator, val: u128, source_type_tag: IntType, type_name: []const u8) EvalResult!Value {
        const target_type = IntType.fromName(type_name) orelse {
            // Not an integer type — try float conversion
            const signed_val: i128 = @bitCast(val);
            const float_val: f128 = if (source_type_tag.isSigned()) @floatFromInt(signed_val) else @floatFromInt(val);
            if (std.mem.eql(u8, type_name, "f16")) return Value{ .float = FloatValue{ .value = float_val, .type_tag = .f16 } };
            if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = FloatValue{ .value = float_val, .type_tag = .f32 } };
            if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = FloatValue{ .value = float_val, .type_tag = .f64 } };
            if (std.mem.eql(u8, type_name, "f128")) return Value{ .float = FloatValue{ .value = float_val, .type_tag = .f128 } };
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
        if (std.mem.eql(u8, type_name, "i128")) {
            const result = clampInt(val, i128) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
            return Value{ .integer = IntValue{ .value = result, .type_tag = target_type } };
        }
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

    fn castFloat(self: *Evaluator, val: f128, type_name: []const u8) EvalResult!Value {
        // Float to integer conversions
        if (std.mem.eql(u8, type_name, "i8")) return floatToInt(val, i8) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i16")) return floatToInt(val, i16) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i32")) return floatToInt(val, i32) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i64")) return floatToInt(val, i64) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "i128")) return floatToInt(val, i128) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "u8")) return floatToInt(val, u8) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "u16")) return floatToInt(val, u16) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "u32")) return floatToInt(val, u32) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "u64")) return floatToInt(val, u64) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        if (std.mem.eql(u8, type_name, "u128")) return floatToInt(val, u128) catch return self.gluePanic("arithmetic overflow: narrowing conversion out of range");
        // Float to float conversions
        if (std.mem.eql(u8, type_name, "f16")) return Value{ .float = FloatValue{ .value = @as(f128, @floatCast(@as(f16, @floatCast(val)))), .type_tag = .f16 } };
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = FloatValue{ .value = @as(f128, @floatCast(@as(f32, @floatCast(val)))), .type_tag = .f32 } };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = FloatValue{ .value = @as(f128, @floatCast(@as(f64, @floatCast(val)))), .type_tag = .f64 } };
        if (std.mem.eql(u8, type_name, "f128")) return Value{ .float = FloatValue{ .value = val, .type_tag = .f128 } };
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
    /// 文档 §3.2.2: spawn 创建新协程，立即返回 Spawn<T>
    /// 文档 §5.1: 每个协程拥有独立的 GC heap（Per-heap GC）
    /// 文档 §3.6: Panic 协程隔离，子协程 panic 不影响父协程
    /// 文档 §3.7: M:N 调度，spawn 通过 Zio 协程执行
    fn evalSpawn(self: *Evaluator, sp: @TypeOf(@as(ast.Expr, undefined).spawn), environment: *Environment) EvalResult!Value {
        const io = self.io orelse return self.gluePanic("spawn: no IO context");

        // 深拷贝捕获环境（Atomic 例外）
        // deepCopy 返回 anyerror，需要转换到 EvalResult
        const cloned_env = environment.deepCopy(self.allocator, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.OutOfMemory,
            };
        };

        // 创建 SpawnHandle
        const handle = try self.allocator.create(value.SpawnHandle);
        handle.* = value.SpawnHandle.init(self.allocator, io);

        // 保护 handle：后续分配可能触发 GC
        self.pushRoot(.{ .spawn_val = handle });
        defer self.popRoot();

        // 注册 spawn handle 到 evaluator（在协程启动前注册，避免竞态）
        try self.spawn_handles.append(self.allocator, handle);

        // 准备 spawn 协程数据
        const ctx = try self.allocator.create(Evaluator.SpawnContext);
        ctx.* = Evaluator.SpawnContext{
            .handle = handle,
            .body = sp.body,
            .env = cloned_env,
            .backing_allocator = std.heap.page_allocator,
            .io = io,
            .scheduler = self.scheduler,
            .gc = self.gc,
        };

        // 通过 Zio 调度器提交协程
        // 文档 §3.7: M:N 调度，少量 OS 线程上运行大量轻量级协程
        handle.status.store(.Running, .seq_cst);
        if (self.scheduler) |sched| {
            // 有调度器：通过 Zio 协程执行（M:N 调度，用户态切换）
            const join_handle = sched.getRuntime().spawn(spawnCoroutineFunc, .{ctx}) catch {
                handle.status.store(.Failed, .seq_cst);
                handle.mutex.lockUncancelable();
                handle.panic_message = try self.allocator.dupe(u8, "spawn: failed to create coroutine");
                handle.condition.broadcast();
                handle.mutex.unlock();
                return Value{ .spawn_val = handle };
            };
            // detach：协程自行管理生命周期，通过 SpawnHandle 的 mutex/condition 同步
            _ = join_handle;
        } else {
            // 无调度器：回退到 std.Thread（1:1 OS 线程）
            const thread = std.Thread.spawn(.{}, spawnThreadFunc, .{ctx}) catch {
                handle.status.store(.Failed, .seq_cst);
                handle.mutex.lockUncancelable();
                handle.panic_message = try self.allocator.dupe(u8, "spawn: failed to create thread");
                handle.condition.broadcast();
                handle.mutex.unlock();
                return Value{ .spawn_val = handle };
            };
            thread.detach();
        }

        return Value{ .spawn_val = handle };
    }

    /// spawn 协程入口函数（Zio 协程）
    /// 文档 §3.7: 在 Zio 协程中创建独立 Evaluator + ArenaAllocator 执行 spawn body
    /// 实现 Per-heap GC 隔离和 Panic 协程隔离
    /// 使用 Zio Mutex/Condition — 在协程上下文中挂起当前协程让出执行权
    /// 把协程内未携带 panic_message 的错误映射为专业说明（供 SpawnHandle 存储）。
    fn spawnErrorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.ImmutableAssignment => "cannot assign to immutable binding inside spawned task",
            error.TypeMismatch => "type error in spawned task",
            error.UndefinedVariable => "undefined name in spawned task",
            error.WrongArity => "wrong number of arguments in spawned task",
            error.NotCallable => "value is not callable in spawned task",
            error.IndexOutOfBounds => "index out of bounds in spawned task",
            error.OutOfMemory => "out of memory in spawned task",
            else => "spawned task failed",
        };
    }

    fn spawnCoroutineFunc(ctx: *Evaluator.SpawnContext) void {
        const handle = ctx.handle;
        // worker 退出前最后置位 finished，通知 deinit 可安全释放 handle
        defer handle.finished.store(true, .seq_cst);
        const body = ctx.body;
        const env_ptr = ctx.env;
        const backing_allocator = ctx.backing_allocator;

        // 创建 Per-heap GC（分代式复制收集器）
        var gc = gc_mod.GarbageCollector.init(backing_allocator) catch {
            handle.status.store(.Failed, .seq_cst);
            handle.mutex.lockUncancelable();
            handle.condition.signal();
            handle.mutex.unlock();
            return;
        };
        defer gc.deinit();
        const arena_alloc = gc.allocator();

        // 创建独立 Evaluator（使用 GC 分配器，继承 IO 上下文和 scheduler）
        var ev = Evaluator.initWithIo(arena_alloc, ctx.io);
        ev.scheduler = ctx.scheduler;
        ev.gc = &gc; // 指向本协程的 Per-heap GC
        defer ev.deinit();

        // 执行 spawn body
        const result = ev.evalExpr(body, env_ptr) catch |err| {
            handle.mutex.lockUncancelable();
            // 文档 §3.6: Panic 协程隔离 — 子协程的错误被捕获存入 SpawnHandle，
            // await 时传播给父协程。优先用已设的 panic_message；否则按错误类型给出
            // 专业说明，避免出现无信息的 "coroutine failed"。
            if (ev.panic_message) |msg| {
                handle.panic_message = backing_allocator.dupe(u8, msg) catch null;
            } else {
                const detail = spawnErrorMessage(err);
                handle.panic_message = backing_allocator.dupe(u8, detail) catch null;
            }
            handle.status.store(.Failed, .seq_cst);
            handle.condition.broadcast();
            handle.mutex.unlock();
            return;
        };

        // 存储结果
        handle.mutex.lockUncancelable();
        handle.result = result;
        handle.status.store(.Completed, .seq_cst);
        handle.condition.broadcast();
        handle.mutex.unlock();
    }

    /// spawn 线程入口函数（std.Thread 回退）
    /// 无调度器时使用 1:1 OS 线程模型
    fn spawnThreadFunc(ctx: *Evaluator.SpawnContext) void {
        const handle = ctx.handle;
        // worker 退出前最后置位 finished，通知 deinit 可安全释放 handle
        defer handle.finished.store(true, .seq_cst);
        const body = ctx.body;
        const env_ptr = ctx.env;
        const backing_allocator = ctx.backing_allocator;

        // 创建 Per-heap GC（分代式复制收集器）
        var gc = gc_mod.GarbageCollector.init(backing_allocator) catch {
            handle.status.store(.Failed, .seq_cst);
            handle.mutex.lockUncancelable();
            handle.condition.signal();
            handle.mutex.unlock();
            return;
        };
        defer gc.deinit();
        const arena_alloc = gc.allocator();

        // 创建独立 Evaluator（使用 GC 分配器，继承 scheduler）
        var ev = Evaluator.initWithIo(arena_alloc, ctx.io);
        ev.scheduler = ctx.scheduler;
        ev.gc = &gc; // 指向本协程的 Per-heap GC
        defer ev.deinit();

        // 执行 spawn body
        const result = ev.evalExpr(body, env_ptr) catch |err| {
            handle.mutex.lockUncancelable();
            if (ev.panic_message) |msg| {
                handle.panic_message = backing_allocator.dupe(u8, msg) catch null;
            } else {
                handle.panic_message = backing_allocator.dupe(u8, spawnErrorMessage(err)) catch null;
            }
            handle.status.store(.Failed, .seq_cst);
            handle.condition.broadcast();
            handle.mutex.unlock();
            return;
        };

        // 存储结果
        handle.mutex.lockUncancelable();
        handle.result = result;
        handle.status.store(.Completed, .seq_cst);
        handle.condition.broadcast();
        handle.mutex.unlock();
    }

    // ============================================================
    // atomic 表达式求值
    // ============================================================

    /// atomic 表达式求值
    /// 文档 §3.4.1: atomic expr 在堆上创建原子值，返回 Atomic<T> 引用
    /// atomic 是关键字前缀表达式，不是函数调用
    fn evalAtomicExpr(self: *Evaluator, ae: @TypeOf(@as(ast.Expr, undefined).atomic_expr), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(ae.value, environment);
        // 保护 val：create 可能触发 GC
        self.pushRoot(val);
        defer self.popRoot();
        const av = try self.allocator.create(value.AtomicValue);
        switch (val) {
            .integer => |iv| {
                const int_raw: i128 = @bitCast(iv.value);
                av.* = value.AtomicValue.initInt(int_raw, value.intTypeToAtomicType(iv.type_tag));
            },
            .float => |fv| {
                av.* = value.AtomicValue.initFloat(fv.value, switch (fv.type_tag) {
                    .f16 => value.AtomicType.f16,
                    .f32 => value.AtomicType.f32,
                    .f64 => value.AtomicType.f64,
                    .f128 => value.AtomicType.f128,
                });
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
                var val = try self.evalDeclRhs(vd.value, environment);
                // 如果有类型注解，将值转换为目标类型
                if (vd.type_annotation) |ta| {
                    switch (ta.*) {
                        .named => |n| {
                            if (isBuiltinType(n.name)) {
                                val = self.castValue(val, n.name) catch val;
                            }
                        },
                        else => {},
                    }
                }
                try environment.defineWithVisibility(vd.name, val, false, vd.visibility == .public);
                return null;
            },
            .var_decl => |vd| {
                var val = try self.evalDeclRhs(vd.value, environment);
                // 如果有类型注解，将值转换为目标类型
                if (vd.type_annotation) |ta| {
                    switch (ta.*) {
                        .named => |n| {
                            if (isBuiltinType(n.name)) {
                                val = self.castValue(val, n.name) catch val;
                            }
                        },
                        else => {},
                    }
                }
                try environment.defineWithVisibility(vd.name, val, true, vd.visibility == .public);
                return null;
            },
            .assignment => |asgn| {
                const val = try self.evalExpr(asgn.value, environment);
                switch (asgn.target.*) {
                    .identifier => |id| {
                        environment.set(id.name, val) catch |err| {
                            if (err == error.ImmutableAssignment) {
                                self.setErrMsg("cannot assign to immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{id.name}, "cannot assign to immutable binding");
                            }
                            return err;
                        };
                    },
                    .field_access => |fa| {
                        // 处理 object.field = value 形式的赋值
                        switch (fa.object.*) {
                            .identifier => |id| {
                                if (environment.getPtr(id.name)) |variable| {
                                    if (!variable.*.is_mutable) {
                                        self.setErrMsg("cannot assign to field '{s}' of immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{ fa.field, id.name }, "cannot assign to field of immutable binding");
                                        return error.ImmutableAssignment;
                                    }
                                    if (variable.*.value == .record) {
                                        const map = &variable.*.value.record.fields;
                                        if (map.getPtr(fa.field)) |existing| {
                                            existing.* = val;
                                        } else {
                                            self.setErrMsg("no field '{s}' on type 'record'", .{fa.field}, "no such field");
                                            return error.GluePanic;
                                        }
                                    } else {
                                        self.setErrMsg("cannot assign field '{s}' on type '{s}'", .{ fa.field, typeNameOf(variable.*.value) }, "cannot assign field");
                                        return error.GluePanic;
                                    }
                                } else {
                                    self.setErrMsg("undefined variable '{s}'", .{id.name}, "undefined variable");
                                    return error.UndefinedVariable;
                                }
                            },
                            else => {
                                self.panic_message = "invalid field assignment target";
                                return error.GluePanic;
                            },
                        }
                    },
                    .index => |idx| {
                        const object = try self.evalExpr(idx.object, environment);
                        const index_val = try self.evalExpr(idx.index, environment);
                        switch (object) {
                            .array => |*arr| {
                                const i_val = switch (index_val) {
                                    .integer => |iv| iv,
                                    else => return error.TypeMismatch,
                                };
                                const i: i128 = if (i_val.type_tag.isSigned()) i_val.signedValue() else @intCast(i_val.value);
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
                            // 不可变绑定（val / 普通参数）不允许改字段。
                            if (!variable.*.is_mutable) {
                                self.setErrMsg("cannot assign to field '{s}' of immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{ fa.field, id.name }, "cannot assign to field of immutable binding");
                                return error.ImmutableAssignment;
                            }
                            if (variable.*.value == .record) {
                                const map = &variable.*.value.record.fields;
                                if (map.getPtr(fa.field)) |existing| {
                                    existing.* = val;
                                } else {
                                    self.setErrMsg("no field '{s}' on type 'record'", .{fa.field}, "no such field");
                                    return error.GluePanic;
                                }
                            } else {
                                self.setErrMsg("cannot assign field '{s}' on type '{s}'", .{ fa.field, typeNameOf(variable.*.value) }, "cannot assign field");
                                return error.GluePanic;
                            }
                        } else {
                            self.setErrMsg("undefined variable '{s}'", .{id.name}, "undefined variable");
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
            .compound_assignment => |ca| {
                const val = try self.evalExpr(ca.value, environment);
                // 如果目标是标识符且持有 Atomic 值，使用原子 fetch 操作
                switch (ca.target.*) {
                    .identifier => |id| {
                        if (environment.getPtr(id.name)) |variable| {
                            if (variable.value == .atomic_val) {
                                const av = variable.value.atomic_val;
                                const operand = value.valueToAtomicRaw(val, av.type_tag);
                                switch (ca.op) {
                                    .add_assign => {
                                        _ = av.fetchAdd(operand);
                                    },
                                    .sub_assign => {
                                        _ = av.fetchSub(operand);
                                    },
                                    .mul_assign => {
                                        _ = av.fetchMul(operand);
                                    },
                                    .div_assign => {
                                        while (true) {
                                            const current = av.data.load(.seq_cst);
                                            const current_val = av.load();
                                            const result = try self.evalDiv(current_val, val, ca.location);
                                            const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                                            if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst)) |_| {
                                                continue;
                                            }
                                            break;
                                        }
                                    },
                                    .mod_assign => {
                                        while (true) {
                                            const current = av.data.load(.seq_cst);
                                            const current_val = av.load();
                                            const result = try self.evalMod(current_val, val, ca.location);
                                            const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                                            if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst)) |_| {
                                                continue;
                                            }
                                            break;
                                        }
                                    },
                                    .bit_and_assign => {
                                        _ = av.fetchAnd(operand);
                                    },
                                    .bit_or_assign => {
                                        _ = av.fetchOr(operand);
                                    },
                                }
                                return null;
                            }
                        }
                    },
                    else => {},
                }
                // 非 Atomic 路径
                const current = try self.evalExpr(ca.target, environment);
                const result = switch (ca.op) {
                    .add_assign => try self.evalAdd(current, val),
                    .sub_assign => try self.evalSub(current, val),
                    .mul_assign => try self.evalMul(current, val),
                    .div_assign => try self.evalDiv(current, val, ca.location),
                    .mod_assign => try self.evalMod(current, val, ca.location),
                    .bit_and_assign => blk: {
                        if (current == .integer and val == .integer) {
                            const result_type = current.integer.type_tag;
                            const r = current.integer.value & val.integer.value;
                            if (!result_type.inRange(r)) {
                                self.panic_message = "arithmetic overflow: integer operation out of range";
                                return error.GluePanic;
                            }
                            break :blk Value{ .integer = IntValue{ .value = r, .type_tag = result_type } };
                        }
                        self.panic_message = "bitwise & requires integer operands";
                        return error.GluePanic;
                    },
                    .bit_or_assign => blk: {
                        if (current == .integer and val == .integer) {
                            const result_type = current.integer.type_tag;
                            const r = current.integer.value | val.integer.value;
                            if (!result_type.inRange(r)) {
                                self.panic_message = "arithmetic overflow: integer operation out of range";
                                return error.GluePanic;
                            }
                            break :blk Value{ .integer = IntValue{ .value = r, .type_tag = result_type } };
                        }
                        self.panic_message = "bitwise | requires integer operands";
                        return error.GluePanic;
                    },
                };
                // 赋值
                switch (ca.target.*) {
                    .identifier => |id| {
                        environment.set(id.name, result) catch |err| {
                            if (err == error.ImmutableAssignment) {
                                self.setErrMsg("cannot assign to immutable binding '{s}' (val bindings and parameters are immutable; use a var)", .{id.name}, "cannot assign to immutable binding");
                            }
                            return err;
                        };
                    },
                    else => {
                        self.panic_message = "invalid assignment target";
                        return error.GluePanic;
                    },
                }
                return null;
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

        // 使用 ModuleResolver 解析路径
        self.resolver.setSourceDir(self.current_source_dir orelse ".") catch {};
        const resolved_path = try self.resolver.resolvePath(io, module_path) orelse return error.FileNotFound;
        defer allocator.free(resolved_path);

        // 使用 ModuleResolver 加载源代码
        // 注意：source 不能在此释放——导入函数的闭包会切片引用它（整数字面量
        // raw、标识符名等）。交给 retained_sources 持有到求值器 deinit。
        const source = try self.resolver.loadSource(io, resolved_path);
        try self.retained_sources.append(self.allocator, source);

        try self.evalSourceModule(source, module_path[0], resolved_path);
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
            if (iterable.integer.type_tag.isSigned() and iterable.integer.signedValue() < 0) return null;
            iterable = Value{ .range = Range{ .start = 0, .end = @intCast(range_end), .inclusive = false } };
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
        .float => |fv| fv.value == b.float.value and fv.type_tag == b.float.type_tag,
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
        .partial => |pa| pa == b.partial, // 引用相等
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
        .trait_value => |tv| tv == b.trait_value, // 引用相等
        .lazy_val => |lz| lz == b.lazy_val, // 引用相等
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

    // 去除整数类型后缀（仅形如 i8/u32/i128 等：i/u 后跟十进制数字）。
    // 注意：不能盲目剥离尾部字母，否则会把十六进制数字 A–F 误当作后缀
    // （例如 0xFF 会被错误地清空）。
    var end = raw.len;
    {
        var j = end;
        // 跳过末尾的十进制数字（后缀的位宽部分，如 32、128）
        while (j > i and raw[j - 1] >= '0' and raw[j - 1] <= '9') {
            j -= 1;
        }
        // 后缀必须以单个 i/u 引导才算有效类型后缀
        if (j > i and j < end and (raw[j - 1] == 'i' or raw[j - 1] == 'u' or raw[j - 1] == 'I' or raw[j - 1] == 'U')) {
            end = j - 1;
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

/// 判断类型名是否为数值类型（整数或浮点）。用于 impl 方法分派的宽度互通匹配。
fn isNumericTypeName(name: []const u8) bool {
    const nums = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "f16", "f32", "f64", "f128",
    };
    for (nums) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// 两个数值类型名是否同属一类（都整数或都浮点）——整数 impl 不应匹配浮点接收者。
fn numericKindMatches(a: []const u8, b: []const u8) bool {
    const a_float = a.len > 0 and a[0] == 'f';
    const b_float = b.len > 0 and b[0] == 'f';
    return a_float == b_float;
}

fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f16",  "f32",  "f64",  "f128",
        "bool", "str",
    };
    for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

fn clampInt(val: u128, comptime T: type) !u128 {
    if (@typeInfo(T).int.signedness == .signed) {
        const signed_val: i128 = @bitCast(val);
        const signed_min: i128 = std.math.minInt(T);
        const signed_max: i128 = std.math.maxInt(T);
        if (signed_val < signed_min or signed_val > signed_max) {
            return error.GluePanic;
        }
    } else {
        const unsigned_max: u128 = std.math.maxInt(T);
        if (val > unsigned_max) {
            return error.GluePanic;
        }
    }
    return val;
}

fn clampUInt(val: u128, comptime T: type) !u128 {
    const unsigned_max: u128 = std.math.maxInt(T);
    if (val > unsigned_max) {
        return error.GluePanic;
    }
    return val;
}

fn floatToInt(val: f128, comptime T: type) EvalResult!Value {
    if (std.math.isNan(val) or std.math.isInf(val)) return error.GluePanic;
    const min: f128 = @floatFromInt(std.math.minInt(T));
    const max: f128 = @floatFromInt(std.math.maxInt(T));
    if (val < min or val > max) return error.GluePanic;
    const int_val: T = @intFromFloat(val);
    const result: u128 = if (@typeInfo(T).int.signedness == .signed) @bitCast(@as(i128, int_val)) else @intCast(int_val);
    const type_tag: IntType = comptime switch (T) {
        i8 => .i8, i16 => .i16, i32 => .i32, i64 => .i64, i128 => .i128,
        u8 => .u8, u16 => .u16, u32 => .u32, u64 => .u64, u128 => .u128,
        else => unreachable,
    };
    return Value{ .integer = IntValue{ .value = result, .type_tag = type_tag } };
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
