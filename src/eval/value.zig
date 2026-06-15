//! Glue 语言运行时值表示
//!
//! 定义求值过程中的所有运行时值类型，包括：
//! - 求值错误和控制流信号
//! - 范围值 (Range)
//! - 错误值 (ErrorValue)
//! - 内建函数类型 (BuiltinFn)
//! - 闭包 (Closure)
//! - 运行时值 (Value) — 所有求值结果的核心联合类型

const std = @import("std");
const ast = @import("ast");
const atomic_mod = @import("atomic");
const channel_mod = @import("channel");
const spawn_mod = @import("spawn");

// ============================================================
// 求值错误
// ============================================================

pub const EvalError = error{
    OutOfMemory,
    TypeMismatch,
    UndefinedVariable,
    ImmutableAssignment,
    NotCallable,
    WrongArity,
    IndexOutOfBounds,
    UnsupportedOperation,
    CircularDependency,
    FileNotFound,
    MissingMain,
};

/// 控制流信号 — 使用 Zig error 机制实现非局部跳转
pub const ControlFlow = error{
    ReturnValue,
    ThrowValue,
    BreakSignal,
    ContinueSignal,
    /// Glue panic — 不可捕获，但允许 defer 执行
    GluePanic,
    /// 尾调用信号 — TCO trampoline 使用
    TailCall,
};

/// 合并的求值错误集
pub const EvalResult = EvalError || ControlFlow;

// ============================================================
// 范围值
// ============================================================

pub const Range = struct {
    start: i128,
    end: i128,
    inclusive: bool, // true = ..=, false = ..

    pub fn contains(self: Range, val: i128) bool {
        if (self.inclusive) {
            return val >= self.start and val <= self.end;
        } else {
            return val >= self.start and val < self.end;
        }
    }

    pub fn len(self: Range) i128 {
        if (self.inclusive) {
            return self.end - self.start + 1;
        } else {
            return self.end - self.start;
        }
    }
};

// ============================================================
// 错误值
// ============================================================

pub const ErrorValue = struct {
    /// 错误类型名（如 "Error"、"FileError"）
    type_name: []const u8,
    message: []const u8,
    /// 是否为 Error 的子类型（文档 2.4.3: FileError <: Error）
    /// 自定义错误类型（type X = Error("...")）自动是 Error 的子类型
    is_error_subtype: bool = false,
};

// ============================================================
// Throw 值（Throw<T, E> 的运行时表示）
// ============================================================

/// Throw<T, E> 的运行时值
/// 文档 2.4.4: Throw<T, E> 的值有两种状态：
/// - Ok(value) — 成功，持有 T 类型的值
/// - Error(message) — 失败，持有错误信息
pub const ThrowValue = union(enum) {
    /// Ok(value) — 成功状态
    ok: *Value,
    /// Error(message) — 失败状态
    err: ErrorValue,
};

// ============================================================
// 内建函数类型
// ============================================================

/// 内建函数指针类型
///
/// 使用 *anyopaque 作为上下文指针以避免与 Evaluator 的循环依赖。
/// 在 eval.zig 中注册内建函数时，将 *Evaluator 转换为 *anyopaque；
/// 调用时，内建函数的 wrapper 将 *anyopaque 转换回 *Evaluator。
pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

/// 内建函数（带用户上下文）
///
/// ctx: *Evaluator（通过 @ptrCast 传递）
/// user_ctx: 可选的用户上下文指针（如 ErrorNewtypeCtx）
pub const Builtin = struct {
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,
};

// ============================================================
// ADT 值（代数数据类型的运行时表示）
// ============================================================

/// ADT 构造器字段
pub const AdtField = struct {
    /// 字段名（位置参数为 null）
    name: ?[]const u8,
    value: Value,
};

/// ADT 值 — 代数数据类型构造器的运行时实例
///
/// 如 `Circle(3.14)` 创建 AdtValue{ .type_name = "Shape", .constructor = "Circle", .fields = [...] }
/// 如 `Cons(1, Nil)` 创建 AdtValue{ .type_name = "List", .constructor = "Cons", .fields = [...] }
/// 如 `Lt` 创建 AdtValue{ .type_name = "Ordering", .constructor = "Lt", .fields = [] }
pub const AdtValue = struct {
    /// 类型名（如 Shape, List, Ordering）
    type_name: []const u8,
    /// 构造器名（如 Circle, Cons, Lt）
    constructor: []const u8,
    /// 构造器字段值
    fields: []AdtField,
};

// ============================================================
// Newtype 值（零开销包装类型的运行时表示）
// ============================================================

/// Newtype 值 — 单字段 ADT，创建语义不同但运行时零开销的新类型
///
/// 如 `type UserId = UserId(i32)` 声明后，`UserId(42)` 创建
/// NewtypeValue{ .type_name = "UserId", .inner = Value{ .integer = IntValue{ .value = 42 } } }
///
/// 文档 2.14: Newtype — 创建新类型，运行时零开销
/// 术语表: Newtype — 单字段 ADT，创建语义不同但运行时无开销的新类型
pub const NewtypeValue = struct {
    /// 类型名（如 UserId, Celsius）
    type_name: []const u8,
    /// 内部被包装的值
    inner: Value,
};

// ============================================================
// 闭包
// ============================================================

pub const Closure = struct {
    params: []ast.Param,
    body: ast.LambdaBody,
    env: *anyopaque, // *Environment — 使用不透明指针避免循环依赖
    allocator: std.mem.Allocator,
};

// ============================================================
// 并发原语值（Phase 4）— 从 runtime 模块 re-export
// ============================================================

pub const AtomicValue = atomic_mod.AtomicValue;
pub const AtomicType = atomic_mod.AtomicValue.AtomicType;
pub const atomicTypeToIntType = atomic_mod.atomicTypeToIntType;
pub const intTypeToAtomicType = atomic_mod.intTypeToAtomicType;
pub const valueToAtomicRaw = atomic_mod.valueToAtomicRaw;

pub const SpawnStatus = spawn_mod.SpawnStatus;
pub const SpawnHandle = spawn_mod.SpawnHandle;

pub const ChannelValue = channel_mod.ChannelValue;
pub const SenderValue = channel_mod.SenderValue;
pub const ReceiverValue = channel_mod.ReceiverValue;

// ============================================================
// 迭代器值（Iterable/Iterator 协议的运行时表示）
// ============================================================

/// 数组迭代器
pub const ArrayIterator = struct {
    array: []Value,
    index: usize,
};

/// 字符串迭代器（UTF-8 码点）
pub const StringIterator = struct {
    string: []const u8,
    byte_offset: usize,
};

/// 范围迭代器
pub const RangeIterator = struct {
    current: i128,
    end: i128,
    inclusive: bool,
};

// ============================================================
// 整数类型标签
// ============================================================

/// 整数具体类型标签，用于运行时溢出检查
pub const IntType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,

    /// 该类型是否为有符号整数
    pub fn isSigned(self: IntType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            .u8, .u16, .u32, .u64, .u128 => false,
        };
    }

    /// 返回该整数类型的最小值（u128 存储，有符号类型使用二补数表示）
    pub fn minInt(self: IntType) u128 {
        return switch (self) {
            .i8 => @as(u128, @bitCast(@as(i128, std.math.minInt(i8)))),
            .i16 => @as(u128, @bitCast(@as(i128, std.math.minInt(i16)))),
            .i32 => @as(u128, @bitCast(@as(i128, std.math.minInt(i32)))),
            .i64 => @as(u128, @bitCast(@as(i128, std.math.minInt(i64)))),
            .i128 => @as(u128, @bitCast(@as(i128, std.math.minInt(i128)))),
            .u8, .u16, .u32, .u64, .u128 => 0,
        };
    }

    /// 返回该整数类型的最大值
    pub fn maxInt(self: IntType) u128 {
        return switch (self) {
            .i8 => @as(u128, std.math.maxInt(i8)),
            .i16 => @as(u128, std.math.maxInt(i16)),
            .i32 => @as(u128, std.math.maxInt(i32)),
            .i64 => @as(u128, std.math.maxInt(i64)),
            .i128 => @as(u128, @bitCast(@as(i128, std.math.maxInt(i128)))),
            .u8 => std.math.maxInt(u8),
            .u16 => std.math.maxInt(u16),
            .u32 => std.math.maxInt(u32),
            .u64 => std.math.maxInt(u64),
            .u128 => std.math.maxInt(u128),
        };
    }

    /// 检查值是否在该类型的范围内
    /// 有符号类型：将 u128 解释为 i128 进行有符号比较
    /// 无符号类型：直接与 maxInt 比较
    pub fn inRange(self: IntType, val: u128) bool {
        return switch (self) {
            inline .i8, .i16, .i32, .i64, .i128 => |tag| {
                const signed_val: i128 = @bitCast(val);
                const signed_min: i128 = switch (tag) {
                    .i8 => std.math.minInt(i8),
                    .i16 => std.math.minInt(i16),
                    .i32 => std.math.minInt(i32),
                    .i64 => std.math.minInt(i64),
                    .i128 => std.math.minInt(i128),
                    else => unreachable,
                };
                const signed_max: i128 = switch (tag) {
                    .i8 => std.math.maxInt(i8),
                    .i16 => std.math.maxInt(i16),
                    .i32 => std.math.maxInt(i32),
                    .i64 => std.math.maxInt(i64),
                    .i128 => std.math.maxInt(i128),
                    else => unreachable,
                };
                return signed_val >= signed_min and signed_val <= signed_max;
            },
            inline .u8, .u16, .u32, .u64, .u128 => |tag| {
                const unsigned_max: u128 = switch (tag) {
                    .u8 => std.math.maxInt(u8),
                    .u16 => std.math.maxInt(u16),
                    .u32 => std.math.maxInt(u32),
                    .u64 => std.math.maxInt(u64),
                    .u128 => std.math.maxInt(u128),
                    else => unreachable,
                };
                return val <= unsigned_max;
            },
        };
    }

    /// 从类型名称字符串解析
    pub fn fromName(name: []const u8) ?IntType {
        if (std.mem.eql(u8, name, "i8")) return .i8;
        if (std.mem.eql(u8, name, "i16")) return .i16;
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i64")) return .i64;
        if (std.mem.eql(u8, name, "i128")) return .i128;
        if (std.mem.eql(u8, name, "u8")) return .u8;
        if (std.mem.eql(u8, name, "u16")) return .u16;
        if (std.mem.eql(u8, name, "u32")) return .u32;
        if (std.mem.eql(u8, name, "u64")) return .u64;
        if (std.mem.eql(u8, name, "u128")) return .u128;
        return null;
    }
};

/// 带类型标签的整数值
/// value 使用 u128 存储，可表示 u128::MAX
/// 有符号类型的负值以二补数形式存储，通过 type_tag 区分解释方式
pub const IntValue = struct {
    value: u128,
    type_tag: IntType = .i32, // 默认 i32（文档：默认整数字面量为 i32）

    /// 获取有符号整数值（仅用于有符号类型）
    pub fn signedValue(self: IntValue) i128 {
        return @bitCast(self.value);
    }
};

// ============================================================
// 浮点类型标签
// ============================================================

/// 浮点具体类型标签，用于运行时精度检查
/// 文档 §2.2: f32 为 32 位浮点数，f64 为 64 位浮点数（默认浮点字面量）
pub const FloatType = enum {
    f32,
    f64,

    pub fn fromName(name: []const u8) ?FloatType {
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        return null;
    }
};

/// 带类型标签的浮点值
/// value 统一使用 f64 存储（f32 值可精确表示在 f64 中）
/// type_tag 区分 f32/f64，用于：
/// - 类型名推断（valueTypeName）
/// - 精度范围检查（f32 运算结果需验证在 f32 范围内）
/// - impl 方法分派
/// - Atomic<T> 类型标签
pub const FloatValue = struct {
    value: f64,
    type_tag: FloatType = .f64, // 默认 f64（文档：默认浮点字面量为 f64）
};

// ============================================================
// 运行时值
// ============================================================

/// 记录值（积类型 / Product Type）
/// 文档 §2.5.2：记录类型是匿名的，基于结构化匹配
/// type_name 存储创建时的类型名（如 "User"），用于构造器模式匹配
pub const RecordValue = struct {
    type_name: []const u8, // 创建时的类型名，匿名记录字面量为 ""
    fields: std.StringHashMap(Value),
};

/// 部分应用值 — 默认柯里化的运行时表示
/// 文档 §2.8.1: fun add(a: i32, b: i32) : i32 { a + b }
///   val add5 = add(5)  // 部分应用，返回 PartialApplication
///   add5(3)            // => 8
pub const PartialApplication = struct {
    /// 原始函数（闭包或内置函数）
    func: Value,
    /// 已绑定的参数
    bound_args: []Value,
    /// 剩余需要的参数数量
    remaining: usize,
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PartialApplication) void {
        for (self.bound_args) |arg| {
            var v = arg;
            v.deinit(self.allocator);
        }
        self.allocator.free(self.bound_args);
    }
};

/// 数组值
pub const ArrayValue = struct {
    elements: []Value,
    fixed_size: ?u64, // null = 动态 T[], non-null = 固定大小 T[N]
};

pub const Value = union(enum) {
    // 基本类型
    integer: IntValue,
    float: FloatValue,
    boolean: bool,
    char_val: u21,
    string: []const u8,
    null_val,
    unit,

    // 复合类型
    array: ArrayValue,
    record: RecordValue,

    // ADT 值（代数数据类型构造器实例）
    adt: *AdtValue,

    // Newtype 值（零开销包装类型实例）
    newtype: *NewtypeValue,

    // 范围
    range: Range,

    // 闭包
    closure: *Closure,

    // 部分应用（默认柯里化）
    partial: *PartialApplication,

    // 内建函数
    builtin: Builtin,

    // 错误值（用于 throw 传播）
    error_val: ErrorValue,

    // Throw 值（Throw<T, E> 的运行时表示）
    throw_val: *ThrowValue,

    // 迭代器（Iterable/Iterator 协议的运行时表示）
    /// 数组迭代器
    array_iterator: *ArrayIterator,
    /// 字符串迭代器（UTF-8 码点）
    string_iterator: *StringIterator,
    /// 范围迭代器
    range_iterator: *RangeIterator,

    // 并发原语值（Phase 4）
    /// Atomic<T> — 跨协程共享原子状态
    atomic_val: *AtomicValue,
    /// Spawn<T> — 协程句柄（线性类型）
    spawn_val: *SpawnHandle,
    /// Channel<T> — CSP 通信通道
    channel_val: *ChannelValue,
    /// Sender<T> — Channel 发送端
    sender_val: *SenderValue,
    /// Receiver<T> — Channel 接收端
    receiver_val: *ReceiverValue,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |arr| {
                for (arr.elements) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr.elements);
            },
            .record => |*rv| {
                if (rv.type_name.len > 0) {
                    allocator.free(rv.type_name);
                }
                var iter = rv.fields.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                rv.fields.deinit();
            },
            .string => |s| {
                allocator.free(s);
            },
            .error_val => |e| {
                allocator.free(e.type_name);
                allocator.free(e.message);
            },
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        v.deinit(allocator);
                        allocator.destroy(v);
                    },
                    .err => |e| {
                        allocator.free(e.type_name);
                        allocator.free(e.message);
                    },
                }
                allocator.destroy(tv);
            },
            .adt => {
                // ADT 值由 Evaluator 统一管理（通过 arena allocator），
                // 不在此释放，避免同一 *AdtValue 被多个 Value 引用导致 double-free
            },
            .newtype => {
                // Newtype 值由 Evaluator 统一管理，不在此释放
            },
            .partial => |pa| {
                pa.deinit();
                allocator.destroy(pa);
            },
            .array_iterator, .string_iterator, .range_iterator => {
                // 迭代器由 Evaluator 统一管理，不在此释放
            },
            else => {},
        }
    }

    /// 克隆值 — 用于同 Heap 内的值复制
    ///
    /// 注意：此方法用于同 Heap 内的值复制（如 Environment.define 深拷贝）。
    /// 跨 Heap 传递（spawn 闭包捕获）应使用 env.deepCloneValue，
    /// 它严格按照文档 §5.2 六类规则处理每种类型。
    ///
    /// §5.2 跨 Heap 传递规则对照：
    /// - 基础类型 (integer/float/boolean/char_val/null_val/unit/range): 值拷贝 ✓
    /// - 不可变数据结构 (string/array/record/adt/newtype/error_val/throw_val/partial): 深拷贝 ✓
    /// - 一等 Trait 值: vtable 共享 + data 深拷贝（Phase 7 实现，builtin 视为简化 Trait 值）
    /// - Channel (channel_val/sender_val/receiver_val): 引用传递（ref count）✓
    /// - 函数/闭包 (closure): 此处浅拷贝，跨 Heap 时由 deepCloneValue 深拷贝环境
    /// - Atomic<T> (atomic_val): 浅拷贝（ref count）✓
    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            // §5.2 规则 1: 基础类型 — 值拷贝
            .integer => self,
            .float => self,
            .boolean => self,
            .char_val => self,
            .null_val => self,
            .unit => self,
            .builtin => self,
            .range => self,
            // §5.2 规则 2: 不可变数据结构 — 深拷贝
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = try allocator.alloc(Value, arr.elements.len);
                for (arr.elements, 0..) |item, i| {
                    new_arr[i] = try item.clone(allocator);
                }
                return Value{ .array = ArrayValue{ .elements = new_arr, .fixed_size = arr.fixed_size } };
            },
            .record => |rv| {
                var new_map = std.StringHashMap(Value).init(allocator);
                var iter = rv.fields.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const val = try entry.value_ptr.*.clone(allocator);
                    try new_map.put(key, val);
                }
                return Value{ .record = .{
                    .type_name = if (rv.type_name.len > 0) try allocator.dupe(u8, rv.type_name) else "",
                    .fields = new_map,
                } };
            },
            // §5.2 规则 5: 闭包 — 同 Heap 内浅拷贝；跨 Heap 时由 deepCloneValue 深拷贝环境
            .closure => self,
            // §5.2 规则 2: 不可变数据结构 — 深拷贝
            .partial => |pa| {
                const new_pa = try allocator.create(PartialApplication);
                const new_args = try allocator.alloc(Value, pa.bound_args.len);
                for (pa.bound_args, 0..) |arg, i| {
                    new_args[i] = try arg.clone(allocator);
                }
                new_pa.* = PartialApplication{
                    .func = try pa.func.clone(allocator),
                    .bound_args = new_args,
                    .remaining = pa.remaining,
                    .allocator = allocator,
                };
                return Value{ .partial = new_pa };
            },
            .adt => |av| {
                const new_av = try allocator.create(AdtValue);
                new_av.* = AdtValue{
                    .type_name = try allocator.dupe(u8, av.type_name),
                    .constructor = try allocator.dupe(u8, av.constructor),
                    .fields = try allocator.alloc(AdtField, av.fields.len),
                };
                for (av.fields, 0..) |f, i| {
                    new_av.fields[i] = AdtField{
                        .name = if (f.name) |n| try allocator.dupe(u8, n) else null,
                        .value = try f.value.clone(allocator),
                    };
                }
                return Value{ .adt = new_av };
            },
            .newtype => |nv| {
                const new_nv = try allocator.create(NewtypeValue);
                new_nv.* = NewtypeValue{
                    .type_name = try allocator.dupe(u8, nv.type_name),
                    .inner = try nv.inner.clone(allocator),
                };
                return Value{ .newtype = new_nv };
            },
            .error_val => |e| Value{ .error_val = ErrorValue{
                .type_name = try allocator.dupe(u8, e.type_name),
                .message = try allocator.dupe(u8, e.message),
                .is_error_subtype = e.is_error_subtype,
            } },
            .throw_val => |tv| {
                const new_tv = try allocator.create(ThrowValue);
                switch (tv.*) {
                    .ok => |v| {
                        const cloned_val = try v.clone(allocator);
                        const cloned_ptr = try allocator.create(Value);
                        cloned_ptr.* = cloned_val;
                        new_tv.* = ThrowValue{ .ok = cloned_ptr };
                    },
                    .err => |e| {
                        new_tv.* = ThrowValue{ .err = ErrorValue{
                            .type_name = try allocator.dupe(u8, e.type_name),
                            .message = try allocator.dupe(u8, e.message),
                            .is_error_subtype = e.is_error_subtype,
                        } };
                    },
                }
                return Value{ .throw_val = new_tv };
            },
            // 迭代器：引用语义
            .array_iterator => |ai| Value{ .array_iterator = ai },
            .string_iterator => |si| Value{ .string_iterator = si },
            .range_iterator => |ri| Value{ .range_iterator = ri },
            // §5.2 规则 6: Atomic<T> — 浅拷贝（原子增加引用计数）
            .atomic_val => |av| {
                av.ref();
                return Value{ .atomic_val = av };
            },
            // Spawn<T> 线性类型：clone 不增加副本
            .spawn_val => self,
            // §5.2 规则 4: Channel — 调度器 heap 中，两端只持有引用
            .channel_val => |cv| {
                cv.ref();
                return Value{ .channel_val = cv };
            },
            .sender_val => |sv| {
                sv.ref();
                return Value{ .sender_val = sv };
            },
            .receiver_val => |rv| {
                rv.ref();
                return Value{ .receiver_val = rv };
            },
        };
    }

    /// debug=false: display 模式（顶层字符串无引号，用户友好）
    /// debug=true: repr 模式（字符串带引号，结构化表示）
    pub fn format(self: Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, debug: bool) !void {
        switch (self) {
            .integer => |iv| {
                if (iv.type_tag.isSigned()) {
                    try buf.print(allocator, "{}", .{@as(i128, @bitCast(iv.value))});
                } else {
                    try buf.print(allocator, "{}", .{iv.value});
                }
            },
            .float => |fv| try buf.print(allocator, "{d}", .{fv.value}),
            .boolean => |b| try buf.print(allocator, "{}", .{b}),
            .char_val => |c| try buf.print(allocator, "{u}", .{c}),
            .string => |s| if (debug) {
                try buf.print(allocator, "\"{s}\"", .{s});
            } else {
                try buf.print(allocator, "{s}", .{s});
            },
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .range => |r| {
                if (r.inclusive) {
                    try buf.print(allocator, "{}..={}", .{ r.start, r.end });
                } else {
                    try buf.print(allocator, "{}..{}", .{ r.start, r.end });
                }
            },
            .array => |arr| {
                try buf.appendSlice(allocator, "[");
                for (arr.elements, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try item.format(buf, allocator, true);
                }
                try buf.appendSlice(allocator, "]");
            },
            .record => |rv| {
                if (rv.type_name.len > 0) {
                    try buf.print(allocator, "{s}(", .{rv.type_name});
                } else {
                    try buf.appendSlice(allocator, "(");
                }
                var iter = rv.fields.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try buf.appendSlice(allocator, ", ");
                    first = false;
                    try buf.print(allocator, "{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.*.format(buf, allocator, true);
                }
                try buf.appendSlice(allocator, ")");
            },
            .closure => try buf.appendSlice(allocator, "<closure>"),
            .partial => try buf.appendSlice(allocator, "<partial>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .adt => |av| {
                try buf.print(allocator, "{s}", .{av.constructor});
                if (av.fields.len > 0) {
                    try buf.appendSlice(allocator, "(");
                    for (av.fields, 0..) |f, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        if (f.name) |n| {
                            try buf.print(allocator, "{s}: ", .{n});
                        }
                        try f.value.format(buf, allocator, true);
                    }
                    try buf.appendSlice(allocator, ")");
                }
            },
            .newtype => |nv| {
                try buf.print(allocator, "{s}(", .{nv.type_name});
                try nv.inner.format(buf, allocator, true);
                try buf.appendSlice(allocator, ")");
            },
            .error_val => |e| try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message }),
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        try buf.appendSlice(allocator, "Ok(");
                        try v.format(buf, allocator, true);
                        try buf.appendSlice(allocator, ")");
                    },
                    .err => |e| {
                        try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message });
                    },
                }
            },
            .array_iterator => try buf.appendSlice(allocator, "<array_iterator>"),
            .string_iterator => try buf.appendSlice(allocator, "<string_iterator>"),
            .range_iterator => try buf.appendSlice(allocator, "<range_iterator>"),
            .atomic_val => try buf.appendSlice(allocator, "<atomic>"),
            .spawn_val => try buf.appendSlice(allocator, "<spawn>"),
            .channel_val => try buf.appendSlice(allocator, "<channel>"),
            .sender_val => try buf.appendSlice(allocator, "<sender>"),
            .receiver_val => try buf.appendSlice(allocator, "<receiver>"),
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;
        return switch (self) {
            .integer => |iv| iv.value == other.integer.value and iv.type_tag == other.integer.type_tag,
            .float => |fv| fv.value == other.float.value and fv.type_tag == other.float.type_tag,
            .boolean => |b| b == other.boolean,
            .char_val => |c| c == other.char_val,
            .string => |s| std.mem.eql(u8, s, other.string),
            .null_val => true,
            .unit => true,
            .range => |r| r.start == other.range.start and r.end == other.range.end and r.inclusive == other.range.inclusive,
            // 引用相等
            .array => |a| a.elements.ptr == other.array.elements.ptr,
            .record => |r| @intFromPtr(&r) == @intFromPtr(&other.record),
            .adt => |av| av == other.adt, // 引用相等
            .newtype => |nv| nv == other.newtype, // 引用相等
            .closure => |c| c == other.closure,
            .partial => |pa| pa == other.partial,
            .builtin => |b_val| b_val.fn_ptr == other.builtin.fn_ptr and b_val.user_ctx == other.builtin.user_ctx,
            .error_val => |e| std.mem.eql(u8, e.type_name, other.error_val.type_name) and std.mem.eql(u8, e.message, other.error_val.message),
            .throw_val => |tv| tv == other.throw_val, // 引用相等
            .array_iterator => |ai| ai == other.array_iterator, // 引用相等
            .string_iterator => |si| si == other.string_iterator, // 引用相等
            .range_iterator => |ri| ri == other.range_iterator, // 引用相等
            .atomic_val => |av| av == other.atomic_val, // 引用相等
            .spawn_val => |sh| sh == other.spawn_val, // 引用相等
            .channel_val => |cv| cv == other.channel_val, // 引用相等
            .sender_val => |sv| sv == other.sender_val, // 引用相等
            .receiver_val => |rv| rv == other.receiver_val, // 引用相等
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |iv| iv.value != 0,
            .float => |fv| fv.value != 0.0,
            .null_val => false,
            .unit => false,
            else => true,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn asInteger(self: Value) !u128 {
        return switch (self) {
            .integer => |iv| iv.value,
            else => error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .float => |fv| fv.value,
            .integer => |iv| if (iv.type_tag.isSigned()) @floatFromInt(@as(i128, @bitCast(iv.value))) else @floatFromInt(iv.value),
            else => error.TypeMismatch,
        };
    }

    pub fn asBoolean(self: Value) !bool {
        return switch (self) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn asString(self: Value) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }
};
