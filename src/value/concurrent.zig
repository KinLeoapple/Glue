//! 并发值类型模块
//!
//! 定义 Glue 语言中承载并发语义的值类型：
//! - AtomicValue 互斥保护的原子操作容器
//! - SpawnHandle 异步任务句柄
//! - ChannelValue/SenderValue/ReceiverValue CSP 风格通道通信
//!
//! 这些类型持有或传递 Value，属于语义层，依赖 runtime 层的同步原语。

const std = @import("std");
const value = @import("mod.zig");
const sync = @import("sync");
const Value = value.Value;
const Int = value.Int;
const Float = value.Float;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

// ──────────────────────────────────────────────
// AtomicValue
// ──────────────────────────────────────────────

/// 原子操作可能产生的错误。
pub const AtomicError = error{
    ArithmeticOverflow,
    DivideByZero,
};

/// 受互斥锁保护的原子值容器。
///
/// 所有读写操作均在临界区内完成，保证对复合类型 `Value` 的线程安全访问。
/// 引用计数用于管理容器自身的生命周期。
pub const AtomicValue = struct {
    data: Value,
    mutex: Mutex,
    ref_count: std.atomic.Value(usize),

    /// 创建初始引用计数为 1 的原子值。
    pub fn init(val: Value) AtomicValue {
        return AtomicValue{
            .data = val,
            .mutex = .{},
            .ref_count = std.atomic.Value(usize).init(1),
        };
    }

    /// 读取当前值的快照。
    pub fn load(self: *AtomicValue) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }

    /// 原子地写入新值。
    pub fn store(self: *AtomicValue, val: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = val;
    }

    /// 原子加法。操作数会按当前值类型进行类型转换，溢出返回错误。
    pub fn fetchAdd(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.add(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.add(b));
            },
            else => self.data,
        };
    }

    /// 原子减法。语义与 `fetchAdd` 对应。
    pub fn fetchSub(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.subtract(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.subtract(b));
            },
            else => self.data,
        };
    }

    /// 原子乘法。
    pub fn fetchMul(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.multiply(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.multiply(b));
            },
            else => self.data,
        };
    }

    /// 原子除法。整数除零返回 `DivideByZero`。
    pub fn fetchDiv(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.divideTruncating(b) catch return error.DivideByZero);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.divide(b));
            },
            else => self.data,
        };
    }

    /// 原子取模。浮点取模通过除法取整再相减实现，除零返回错误。
    pub fn fetchMod(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.remainder(b) catch return error.DivideByZero);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                if (b.isZero()) return error.DivideByZero;
                const q = a.divide(b);
                const q_int = q.toInt(.i128) catch return error.ArithmeticOverflow;
                const q_float = value.Float.fromInt(a.type, q_int);
                break :blk Value.fromFloat(a.subtract(b.multiply(q_float)));
            },
            else => self.data,
        };
    }

    /// 原子按位与。仅对整数类型有效。
    pub fn fetchAnd(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.bitwiseAnd(b));
            },
            else => self.data,
        };
    }

    /// 原子按位或。仅对整数类型有效。
    pub fn fetchOr(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.bitwiseOr(b));
            },
            else => self.data,
        };
    }

    /// 比较并交换。当前值等于 `expected` 时替换为 `new`，返回是否成功。
    pub fn cas(self: *AtomicValue, expected: Value, new: Value) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.meta.eql(self.data, expected)) {
            self.data = new;
            return true;
        }
        return false;
    }

    /// 原子交换，返回旧值并写入新值。
    pub fn xchg(self: *AtomicValue, new: Value) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.data;
        self.data = new;
        return old;
    }

    /// 增加引用计数。
    pub fn ref(self: *AtomicValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，返回是否为最后一次引用（计数归零）。
    pub fn unref(self: *AtomicValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }
};

// ──────────────────────────────────────────────
// SpawnHandle
// ──────────────────────────────────────────────

/// 异步任务的执行状态。
pub const SpawnStatus = enum(u8) {
    Pending,
    Running,
    Completed,
    Cancelled,
    Failed,
};

/// 异步任务句柄，持有任务结果与同步原语。
///
/// 调用方可通过原子字段查询任务状态，并在任务完成后消费结果。
/// 句柄使用引用计数管理生命周期。
pub const SpawnHandle = struct {
    status: std.atomic.Value(SpawnStatus),
    result: ?Value,
    consumed: std.atomic.Value(bool),
    finished: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    panic_message: ?[]const u8 = null,
    mutex: Mutex,
    condition: Condition,

    pub fn init(allocator: std.mem.Allocator) SpawnHandle {
        return SpawnHandle{
            .status = std.atomic.Value(SpawnStatus).init(.Pending),
            .result = null,
            .consumed = std.atomic.Value(bool).init(false),
            .finished = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .condition = .{},
        };
    }

    /// 释放句柄持有的资源，包括未消费的结果与 panic 信息。
    pub fn deinit(self: *SpawnHandle) void {
        if (self.result) |r| {
            var v = r;
            v.release(self.allocator);
        }
        if (self.panic_message) |msg| {
            std.heap.c_allocator.free(msg);
        }
    }
};

// ──────────────────────────────────────────────
// ChannelValue / SenderValue / ReceiverValue
// ──────────────────────────────────────────────

/// 通道值，支持有缓冲环形队列与无缓冲（会合）两种模式。
///
/// 当 `capacity` 为 0 时采用会合模式：发送方阻塞直到接收方取走值。
/// 通过引用计数支持多端共享，关闭后所有阻塞操作立即返回。
pub const ChannelValue = struct {
    buffer: []Value,
    head: usize,
    tail: usize,
    count: usize,
    capacity: usize,
    // 会合模式下暂存待传递的值。
    rend_value: ?Value,
    // 会合模式下标记已有发送方就绪。
    rend_ready: bool,
    closed: bool,
    mutex: Mutex,
    not_empty: Condition,
    not_full: Condition,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(usize),

    /// 创建容量为 `cap` 的通道。`cap` 为 0 时进入会合模式。
    pub fn init(allocator: std.mem.Allocator, cap: usize) !ChannelValue {
        const buf: []Value = if (cap == 0) &.{} else try allocator.alloc(Value, cap);
        return ChannelValue{
            .buffer = buf,
            .head = 0,
            .tail = 0,
            .count = 0,
            .capacity = cap,
            .rend_value = null,
            .rend_ready = false,
            .closed = false,
            .mutex = .{},
            .not_empty = .{},
            .not_full = .{},
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1),
        };
    }

    /// 释放通道资源，包括未消费的缓冲值与会合暂存值。
    pub fn deinit(self: *ChannelValue) void {
        if (self.capacity > 0) {
            // 释放环形缓冲区中尚未被接收的值。
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                var v = self.buffer[(self.head + i) % self.capacity];
                v.release(self.allocator);
            }
            self.allocator.free(self.buffer);
        }
        if (self.rend_ready) {
            if (self.rend_value) |v| {
                var val = v;
                val.release(self.allocator);
            }
        }
    }

    /// 发送一个值。通道关闭后返回 false，阻塞直到有空间或被接收。
    pub fn send(self: *ChannelValue, val: Value) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.capacity == 0) {
            // 会合模式：等待之前的会合完成，然后提交新值并等待对方接收。
            while (self.rend_ready) {
                if (self.closed) return false;
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return false;
            self.rend_value = val;
            self.rend_ready = true;
            self.not_empty.signal();
            // 阻塞直到接收方取走会合值。
            while (self.rend_ready) {
                if (self.closed) return true;
                self.not_full.wait(&self.mutex);
            }
            return true;
        }
        // 有缓冲模式：等待环形队列出现空位。
        while (self.count >= self.capacity) {
            if (self.closed) return false;
            self.not_full.wait(&self.mutex);
        }
        if (self.closed) return false;
        self.buffer[self.tail] = val;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        self.not_empty.signal();
        return true;
    }

    /// 接收一个值。通道关闭且无数据时返回 null，否则阻塞直到有值可取。
    pub fn recv(self: *ChannelValue) ?Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.capacity == 0) {
            // 会合模式：等待发送方提交值后取走。
            while (!self.rend_ready) {
                if (self.closed) return null;
                self.not_empty.wait(&self.mutex);
            }
            const val = self.rend_value.?;
            self.rend_value = null;
            self.rend_ready = false;
            self.not_full.signal();
            return val;
        }
        // 有缓冲模式：等待环形队列出现数据。
        while (self.count == 0) {
            if (self.closed) return null;
            self.not_empty.wait(&self.mutex);
        }
        const val = self.buffer[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        self.not_full.signal();
        return val;
    }

    /// 非阻塞接收。无数据可取时立即返回 null。
    pub fn tryRecv(self: *ChannelValue) ?Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.capacity == 0) {
            if (!self.rend_ready) return null;
            const val = self.rend_value.?;
            self.rend_value = null;
            self.rend_ready = false;
            self.not_full.signal();
            return val;
        }
        if (self.count == 0) return null;
        const val = self.buffer[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        self.not_full.signal();
        return val;
    }

    /// 关闭通道，唤醒所有阻塞的发送方与接收方。
    pub fn close(self: *ChannelValue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
    }

    /// 增加引用计数。
    pub fn ref(self: *ChannelValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，返回是否为最后一次引用。
    pub fn unref(self: *ChannelValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }
};

/// 发送端句柄，共享底层通道的引用计数。
pub const SenderValue = struct {
    channel: *ChannelValue,

    pub fn ref(self: *SenderValue) void {
        self.channel.ref();
    }

    pub fn unref(self: *SenderValue) bool {
        return self.channel.unref();
    }
};

/// 接收端句柄，共享底层通道的引用计数。
pub const ReceiverValue = struct {
    channel: *ChannelValue,

    pub fn ref(self: *ReceiverValue) void {
        self.channel.ref();
    }

    pub fn unref(self: *ReceiverValue) bool {
        return self.channel.unref();
    }
};

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "AtomicValue fetchAdd int type promotion (widen operand)" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 50)));
    try av.fetchAdd(operand);
    try testing.expectEqual(@as(i32, 150), av.load().asInt().toNative(i32));
    const operand2 = Value.fromInt(Int.fromNative(.i64, @as(i64, 200)));
    try av.fetchAdd(operand2);
    try testing.expectEqual(@as(i32, 350), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAdd int narrowing overflow returns error" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 100))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1000)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    try testing.expectEqual(@as(i8, 100), av.load().asInt().toNative(i8));
}

test "AtomicValue fetchAdd int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchSub int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.minInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchSub(operand));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchMul int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 2)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchMul(operand));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchDiv int divide by zero" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const zero = Value.fromInt(Int.fromNative(.i32, @as(i32, 0)));
    try testing.expectError(error.DivideByZero, av.fetchDiv(zero));
    try testing.expectEqual(@as(i32, 100), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchMod int divide by zero" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const zero = Value.fromInt(Int.fromNative(.i32, @as(i32, 0)));
    try testing.expectError(error.DivideByZero, av.fetchMod(zero));
    try testing.expectEqual(@as(i32, 100), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAdd float type promotion" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 1.5))));
    const operand = Value.fromFloat(Float.fromNative(.f32, @as(f32, 2.5)));
    try av.fetchAdd(operand);
    const result = av.load().asFloat().toNative(f64);
    try testing.expectApproxEqAbs(@as(f64, 4.0), result, 1e-9);
}

test "AtomicValue fetchMod float divide by zero" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 10.0))));
    const zero = Value.fromFloat(Float.fromNative(.f64, @as(f64, 0.0)));
    try testing.expectError(error.DivideByZero, av.fetchMod(zero));
}

test "AtomicValue fetchMod float overflow returns error" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 1e50))));
    const divisor = Value.fromFloat(Float.fromNative(.f64, @as(f64, 1.0)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchMod(divisor));
}

test "AtomicValue fetchAnd/fetchOr int type promotion" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 0xFF))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F)));
    try av.fetchAnd(operand);
    try testing.expectEqual(@as(i32, 0x0F), av.load().asInt().toNative(i32));
    const operand2 = Value.fromInt(Int.fromNative(.i16, @as(i16, 0x100)));
    try av.fetchOr(operand2);
    try testing.expectEqual(@as(i32, 0x10F), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAnd int narrowing overflow returns error" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 256)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAnd(operand));
}

test "buffered channel ring buffer FIFO order" {
    var ch = try ChannelValue.init(testing.allocator, 3);
    defer ch.deinit();
    try testing.expect(try ch.send(Value.fromInt(Int.fromNative(.i32, 10))));
    try testing.expect(try ch.send(Value.fromInt(Int.fromNative(.i32, 20))));
    try testing.expect(try ch.send(Value.fromInt(Int.fromNative(.i32, 30))));
    const v1 = ch.tryRecv().?;
    try testing.expectEqual(@as(i32, 10), v1.asInt().toNative(i32));
    try testing.expect(try ch.send(Value.fromInt(Int.fromNative(.i32, 40))));
    const v2 = ch.recv().?;
    try testing.expectEqual(@as(i32, 20), v2.asInt().toNative(i32));
    const v3 = ch.recv().?;
    try testing.expectEqual(@as(i32, 30), v3.asInt().toNative(i32));
    const v4 = ch.recv().?;
    try testing.expectEqual(@as(i32, 40), v4.asInt().toNative(i32));
    try testing.expect(ch.tryRecv() == null);
}

test "channel close wakes blocked recv" {
    var ch = try ChannelValue.init(testing.allocator, 1);
    defer ch.deinit();
    ch.close();
    try testing.expect(ch.recv() == null);
}

test "channel send after close returns false" {
    var ch = try ChannelValue.init(testing.allocator, 2);
    defer ch.deinit();
    ch.close();
    const v = Value.fromInt(Int.fromNative(.i32, 99));
    try testing.expect(!(try ch.send(v)));
}
