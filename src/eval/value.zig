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
// 并发原语值（Phase 4）
// ============================================================

/// Atomic<T> 值 — 跨协程共享原子状态
/// 文档 §3.4: Atomic<T> 是引用类型，atomic expr 创建堆上原子值
/// T 限制为原始类型：i8..i128, u8..u128, f32, f64, bool, char
pub const AtomicValue = struct {
    /// 原子存储的值 — 使用 i128 统一表示所有整数类型
    /// f64/bool/char 也通过 @bitCast 存储为 i128
    data: std.atomic.Value(i128),
    /// 引用计数 — 归零时自动释放
    ref_count: std.atomic.Value(usize),
    /// 类型标签 — 确定如何解释 data
    type_tag: AtomicType,

    pub const AtomicType = enum {
        i8, i16, i32, i64, i128,
        u8, u16, u32, u64, u128,
        f32, f64,
        bool,
        char,
    };

    /// 从整数值创建 AtomicValue
    pub fn initInt(int_val: i128, tag: AtomicType) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(int_val),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = tag,
        };
    }

    /// 从浮点值创建 AtomicValue
    pub fn initFloat(float_val: f64, tag: AtomicType) AtomicValue {
        const bits: u64 = @bitCast(float_val);
        return AtomicValue{
            .data = std.atomic.Value(i128).init(@as(i128, @intCast(bits))),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = tag,
        };
    }

    /// 从布尔值创建 AtomicValue
    pub fn initBool(b: bool) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(if (b) 1 else 0),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = .bool,
        };
    }

    /// 从字符值创建 AtomicValue
    pub fn initChar(c: u21) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(@as(i128, @intCast(c))),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = .char,
        };
    }

    /// 加载当前值到 Value
    pub fn load(self: *AtomicValue) Value {
        const raw = self.data.load(.seq_cst);
        return switch (self.type_tag) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128 => Value{ .integer = IntValue{ .value = raw, .type_tag = atomicTypeToIntType(self.type_tag) } },
            .f32, .f64 => Value{ .float = @bitCast(@as(u64, @intCast(raw))) },
            .bool => Value{ .boolean = raw != 0 },
            .char => Value{ .char_val = @intCast(raw) },
        };
    }

    /// 原子存储 Value
    pub fn store(self: *AtomicValue, val: Value) void {
        const raw = valueToAtomicRaw(val, self.type_tag);
        self.data.store(raw, .seq_cst);
    }

    /// 原子 fetch_add
    pub fn fetchAdd(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchAdd(operand, .seq_cst);
    }

    /// 原子 fetch_sub
    pub fn fetchSub(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchSub(operand, .seq_cst);
    }

    /// 原子 fetch_mul (使用 CAS 循环，因为没有硬件 fetch_mul)
    pub fn fetchMul(self: *AtomicValue, operand: i128) i128 {
        while (true) {
            const current = self.data.load(.seq_cst);
            const new_val = current * operand;
            if (self.data.cmpxchgStrong(current, new_val, .seq_cst, .seq_cst)) |_| {
                continue;
            }
            return current;
        }
    }

    /// 原子 fetch_and
    pub fn fetchAnd(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchAnd(operand, .seq_cst);
    }

    /// 原子 fetch_or
    pub fn fetchOr(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchOr(operand, .seq_cst);
    }

    /// CAS (compare-and-swap)，返回是否成功
    pub fn cas(self: *AtomicValue, expected: i128, new: i128) bool {
        return self.data.cmpxchgStrong(expected, new, .seq_cst, .seq_cst) == null;
    }

    /// 原子交换，返回旧值
    pub fn xchg(self: *AtomicValue, new: i128) i128 {
        return self.data.swap(new, .seq_cst);
    }

    /// 增加引用计数
    pub fn ref(self: *AtomicValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，归零返回 true
    pub fn unref(self: *AtomicValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }
};

pub fn atomicTypeToIntType(at: AtomicValue.AtomicType) IntType {
    return switch (at) {
        .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
        .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
        else => .i32, // f32/f64/bool/char 不应该走到这里
    };
}

pub fn intTypeToAtomicType(it: IntType) AtomicValue.AtomicType {
    return switch (it) {
        .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
        .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
    };
}

pub fn valueToAtomicRaw(val: Value, tag: AtomicValue.AtomicType) i128 {
    _ = tag;
    return switch (val) {
        .integer => |iv| iv.value,
        .float => |f| @as(i128, @intCast(@as(u64, @bitCast(f)))),
        .boolean => |b| if (b) 1 else 0,
        .char_val => |c| @as(i128, @intCast(c)),
        else => 0,
    };
}

/// SpawnStatus 枚举值 — 协程状态
pub const SpawnStatus = enum(u8) {
    Pending,
    Running,
    Completed,
    Cancelled,
    Failed,
};

/// SpawnHandle — Spawn<T> 的运行时表示
/// 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费
pub const SpawnHandle = struct {
    status: std.atomic.Value(SpawnStatus),
    /// 协程执行结果（完成后存储）
    result: ?Value,
    /// 协程线程
    thread: ?std.Thread,
    /// 互斥锁 — 保护 result 和状态转换
    mutex: std.Io.Mutex,
    /// 条件变量 — await 阻塞等待
    condition: std.Io.Condition,
    /// 是否已被消费（await 或 cancel）
    consumed: std.atomic.Value(bool),
    /// 分配器
    allocator: std.mem.Allocator,
    /// IO 上下文
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SpawnHandle {
        return SpawnHandle{
            .status = std.atomic.Value(SpawnStatus).init(.Pending),
            .result = null,
            .thread = null,
            .mutex = std.Io.Mutex.init,
            .condition = std.Io.Condition.init,
            .consumed = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *SpawnHandle) void {
        if (self.result) |r| {
            var v = r;
            v.deinit(self.allocator);
        }
    }
};

/// Channel 值 — CSP 通信通道
/// 文档 §3.5: 通过 channel 通信，不通过共享内存通信
pub const ChannelValue = struct {
    /// 内部缓冲区
    buffer: std.ArrayList(Value),
    /// 缓冲区容量（0 = 同步/无缓冲）
    capacity: usize,
    /// 是否已关闭
    closed: std.atomic.Value(bool),
    /// 互斥锁 — 保护缓冲区和关闭状态
    mutex: std.Io.Mutex,
    /// 条件变量 — recv 等待数据
    not_empty: std.Io.Condition,
    /// 条件变量 — send 等待空间
    not_full: std.Io.Condition,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 引用计数
    ref_count: std.atomic.Value(usize),
    /// IO 上下文
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, cap: usize, io: std.Io) ChannelValue {
        return ChannelValue{
            .buffer = std.ArrayList(Value).empty,
            .capacity = cap,
            .closed = std.atomic.Value(bool).init(false),
            .mutex = std.Io.Mutex.init,
            .not_empty = std.Io.Condition.init,
            .not_full = std.Io.Condition.init,
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1),
            .io = io,
        };
    }

    /// 发送值到通道
    /// 关闭后返回 false
    pub fn send(self: *ChannelValue, val: Value) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed.load(.seq_cst)) return false;

        // 同步通道（容量 0）：暂存一个元素，等待 recv 取走
        // 缓冲通道：缓冲未满时写入
        if (self.capacity == 0) {
            // 同步通道：直接放入一个元素
            try self.buffer.append(self.allocator, val);
            self.not_empty.signal(self.io);
            // 等待 recv 取走（简化实现：对于同步通道直接返回）
            return true;
        } else {
            while (self.buffer.items.len >= self.capacity) {
                if (self.closed.load(.seq_cst)) return false;
                self.not_full.waitUncancelable(self.io, &self.mutex);
            }
            try self.buffer.append(self.allocator, val);
            self.not_empty.signal(self.io);
            return true;
        }
    }

    /// 从通道接收值
    /// 缓冲区耗尽且已关闭返回 null
    pub fn recv(self: *ChannelValue) ?Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.buffer.items.len == 0) {
            if (self.closed.load(.seq_cst)) return null;
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        }

        const val = self.buffer.orderedRemove(0);
        self.not_full.signal(self.io);
        return val;
    }

    /// 非阻塞接收 — 用于 select
    /// 无数据时返回 null（不区分关闭和空缓冲）
    pub fn tryRecv(self: *ChannelValue) ?Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.buffer.items.len == 0) return null;
        const val = self.buffer.orderedRemove(0);
        self.not_full.signal(self.io);
        return val;
    }

    /// 关闭通道（仅 Sender 可调用）
    pub fn close(self: *ChannelValue) void {
        self.mutex.lockUncancelable(self.io);
        self.closed.store(true, .seq_cst);
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// 增加引用计数
    pub fn ref(self: *ChannelValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，归零返回 true
    pub fn unref(self: *ChannelValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }

    pub fn deinit(self: *ChannelValue) void {
        for (self.buffer.items) |v| {
            var val = v;
            val.deinit(self.allocator);
        }
        self.buffer.deinit(self.allocator);
    }
};

/// Sender 值 — Channel 的发送端
/// 文档 §3.5.2: 方向类型，限制只能 send 和 close
pub const SenderValue = struct {
    channel: *ChannelValue,

    pub fn ref(self: *SenderValue) void {
        self.channel.ref();
    }
    pub fn unref(self: *SenderValue) bool {
        return self.channel.unref();
    }
};

/// Receiver 值 — Channel 的接收端
/// 文档 §3.5.2: 方向类型，限制只能 recv
/// 文档 §3.5.4: Receiver<T> 实现了 Iterable<T>，通道关闭后循环自动结束
pub const ReceiverValue = struct {
    channel: *ChannelValue,

    pub fn ref(self: *ReceiverValue) void {
        self.channel.ref();
    }
    pub fn unref(self: *ReceiverValue) bool {
        return self.channel.unref();
    }
};

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

    /// 返回该整数类型的最小值
    pub fn minInt(self: IntType) i128 {
        return switch (self) {
            .i8 => std.math.minInt(i8),
            .i16 => std.math.minInt(i16),
            .i32 => std.math.minInt(i32),
            .i64 => std.math.minInt(i64),
            .i128 => std.math.minInt(i128),
            .u8, .u16, .u32, .u64, .u128 => 0,
        };
    }

    /// 返回该整数类型的最大值
    pub fn maxInt(self: IntType) i128 {
        return switch (self) {
            .i8 => std.math.maxInt(i8),
            .i16 => std.math.maxInt(i16),
            .i32 => std.math.maxInt(i32),
            .i64 => std.math.maxInt(i64),
            .i128 => std.math.maxInt(i128),
            .u8 => std.math.maxInt(u8),
            .u16 => std.math.maxInt(u16),
            .u32 => std.math.maxInt(u32),
            .u64 => std.math.maxInt(u64),
            .u128 => std.math.maxInt(i128), // i128 无法表示 u128::MAX，取 i128::MAX
        };
    }

    /// 检查值是否在该类型的范围内
    pub fn inRange(self: IntType, val: i128) bool {
        return val >= self.minInt() and val <= self.maxInt();
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
pub const IntValue = struct {
    value: i128,
    type_tag: IntType = .i32, // 默认 i32（文档：默认整数字面量为 i32）
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

/// 数组值
pub const ArrayValue = struct {
    elements: []Value,
    fixed_size: ?u64, // null = 动态 T[], non-null = 固定大小 T[N]
};

pub const Value = union(enum) {
    // 基本类型
    integer: IntValue,
    float: f64,
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
            .array_iterator, .string_iterator, .range_iterator => {
                // 迭代器由 Evaluator 统一管理，不在此释放
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .integer => self,
            .float => self,
            .boolean => self,
            .char_val => self,
            .null_val => self,
            .unit => self,
            .builtin => self,
            .range => self,
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
            .closure => self,
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
            .array_iterator => |ai| Value{ .array_iterator = ai }, // 引用相等
            .string_iterator => |si| Value{ .string_iterator = si }, // 引用相等
            .range_iterator => |ri| Value{ .range_iterator = ri }, // 引用相等
            // 并发原语：引用语义，clone 为浅拷贝
            .atomic_val => |av| {
                av.ref();
                return Value{ .atomic_val = av };
            },
            .spawn_val => self, // Spawn 是线性类型，clone 不增加副本
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
            .integer => |iv| try buf.print(allocator, "{}", .{iv.value}),
            .float => |f| try buf.print(allocator, "{d}", .{f}),
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
            .integer => |iv| iv.value == other.integer.value,
            .float => |f| f == other.float,
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
            .float => |f| f != 0.0,
            .null_val => false,
            .unit => false,
            else => true,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn asInteger(self: Value) !i128 {
        return switch (self) {
            .integer => |iv| iv.value,
            else => error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |iv| @floatFromInt(iv.value),
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
