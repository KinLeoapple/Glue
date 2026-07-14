//! 并发值类型模块
//!
//! 定义 Glue 语言中承载并发语义的值类型：
//! - AtomicValue 互斥保护的原子操作容器
//! - SpawnHandle 异步任务句柄
//! - ChannelValue/SenderValue/ReceiverValue CSP 风格通道通信
//!
//! 这些类型持有或传递 Value，属于语义层，依赖 runtime 层的同步原语。
//! 所有类型以 ObjHeader 作为首字段，通过统一 retain/release 管理引用计数，
//! 各类型的 deinit 函数注册到 obj_header.deinit_table 中由分派表调用。

const std = @import("std");
const value = @import("mod.zig");
const sync = @import("sync");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const Value = value.Value;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

// ──────────────────────────────────────────────
// AtomicValue
// ──────────────────────────────────────────────

/// 受互斥锁保护的原子值容器。
///
/// 所有读写操作均在临界区内完成，保证对复合类型 `Value` 的线程安全访问。
/// 引用计数通过 ObjHeader 统一管理。
pub const AtomicValue = struct {
    header: ObjHeader = .{ .type_tag = .atomic_val },
    data: Value,
    mutex: Mutex,

    /// 创建初始引用计数为 1 的原子值。
    pub fn init(val: Value) AtomicValue {
        return AtomicValue{
            .data = val,
            .mutex = .{},
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

    /// 释放内部资源（data 值的引用计数递减），不销毁对象本体。
    pub fn deinit(self: *AtomicValue, allocator: std.mem.Allocator) void {
        self.data.release(allocator);
    }
};

/// AtomicValue 的 ObjHeader deinit 分派入口。
pub fn atomicDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *AtomicValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

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
/// 引用计数通过 ObjHeader 统一管理。
pub const SpawnHandle = struct {
    header: ObjHeader = .{ .type_tag = .spawn_val },
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
    pub fn deinit(self: *SpawnHandle, allocator: std.mem.Allocator) void {
        if (self.result) |r| {
            var v = r;
            v.release(allocator);
        }
        if (self.panic_message) |msg| {
            std.heap.c_allocator.free(msg);
        }
    }
};

/// SpawnHandle 的 ObjHeader deinit 分派入口。
pub fn spawnDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *SpawnHandle = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

// ──────────────────────────────────────────────
// ChannelValue / SenderValue / ReceiverValue
// ──────────────────────────────────────────────

/// 通道值，支持有缓冲环形队列与无缓冲（会合）两种模式。
///
/// 当 `capacity` 为 0 时采用会合模式：发送方阻塞直到接收方取走值。
/// 通过 ObjHeader 引用计数支持多端共享，关闭后所有阻塞操作立即返回。
pub const ChannelValue = struct {
    header: ObjHeader = .{ .type_tag = .channel_val },
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
        };
    }

    /// 释放通道资源，包括未消费的缓冲值与会合暂存值。
    pub fn deinit(self: *ChannelValue, allocator: std.mem.Allocator) void {
        if (self.capacity > 0) {
            // 释放环形缓冲区中尚未被接收的值。
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                var v = self.buffer[(self.head + i) % self.capacity];
                v.release(allocator);
            }
            self.allocator.free(self.buffer);
        }
        if (self.rend_ready) {
            if (self.rend_value) |v| {
                var val = v;
                val.release(allocator);
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
};

/// ChannelValue 的 ObjHeader deinit 分派入口。
pub fn channelDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *ChannelValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

/// 发送端句柄，持有底层通道的引用。
pub const SenderValue = struct {
    header: ObjHeader = .{ .type_tag = .sender_val },
    channel: *ChannelValue,

    /// 释放内部资源（递减底层通道的引用计数），不销毁对象本体。
    pub fn deinit(self: *SenderValue, allocator: std.mem.Allocator) void {
        obj_header.release(&self.channel.header, allocator);
    }
};

/// SenderValue 的 ObjHeader deinit 分派入口。
pub fn senderDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *SenderValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

/// 接收端句柄，持有底层通道的引用。
pub const ReceiverValue = struct {
    header: ObjHeader = .{ .type_tag = .receiver_val },
    channel: *ChannelValue,

    /// 释放内部资源（递减底层通道的引用计数），不销毁对象本体。
    pub fn deinit(self: *ReceiverValue, allocator: std.mem.Allocator) void {
        obj_header.release(&self.channel.header, allocator);
    }
};

/// ReceiverValue 的 ObjHeader deinit 分派入口。
pub fn receiverDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *ReceiverValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

/// 注册所有并发类型的 deinit 函数到 ObjHeader 分派表。
///
/// 应在运行时初始化阶段调用，使 obj_header.release 能正确分派到各类型的析构函数。
pub fn registerDeinits() void {
    obj_header.registerDeinit(.atomic_val, atomicDeinit);
    obj_header.registerDeinit(.spawn_val, spawnDeinit);
    obj_header.registerDeinit(.channel_val, channelDeinit);
    obj_header.registerDeinit(.sender_val, senderDeinit);
    obj_header.registerDeinit(.receiver_val, receiverDeinit);
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "AtomicValue load/store" {
    var av = AtomicValue.init(Value.fromI32(100));
    try testing.expectEqual(@as(i32, 100), av.load().asI32());
    av.store(Value.fromI64(42));
    try testing.expectEqual(@as(i64, 42), av.load().asI64());
}

test "AtomicValue cas" {
    var av = AtomicValue.init(Value.fromI32(10));
    try testing.expect(av.cas(Value.fromI32(10), Value.fromI32(20)));
    try testing.expectEqual(@as(i32, 20), av.load().asI32());
    try testing.expect(!av.cas(Value.fromI32(10), Value.fromI32(30)));
    try testing.expectEqual(@as(i32, 20), av.load().asI32());
}

test "AtomicValue xchg" {
    var av = AtomicValue.init(Value.fromI32(1));
    const old = av.xchg(Value.fromI32(99));
    try testing.expectEqual(@as(i32, 1), old.asI32());
    try testing.expectEqual(@as(i32, 99), av.load().asI32());
}

test "buffered channel ring buffer FIFO order" {
    var ch = try ChannelValue.init(testing.allocator, 3);
    defer ch.deinit(testing.allocator);
    try testing.expect(try ch.send(Value.fromI32(10)));
    try testing.expect(try ch.send(Value.fromI32(20)));
    try testing.expect(try ch.send(Value.fromI32(30)));
    const v1 = ch.tryRecv().?;
    try testing.expectEqual(@as(i32, 10), v1.asI32());
    try testing.expect(try ch.send(Value.fromI32(40)));
    const v2 = ch.recv().?;
    try testing.expectEqual(@as(i32, 20), v2.asI32());
    const v3 = ch.recv().?;
    try testing.expectEqual(@as(i32, 30), v3.asI32());
    const v4 = ch.recv().?;
    try testing.expectEqual(@as(i32, 40), v4.asI32());
    try testing.expect(ch.tryRecv() == null);
}

test "channel close wakes blocked recv" {
    var ch = try ChannelValue.init(testing.allocator, 1);
    defer ch.deinit(testing.allocator);
    ch.close();
    try testing.expect(ch.recv() == null);
}

test "channel send after close returns false" {
    var ch = try ChannelValue.init(testing.allocator, 2);
    defer ch.deinit(testing.allocator);
    ch.close();
    const v = Value.fromI32(99);
    try testing.expect(!(try ch.send(v)));
}
