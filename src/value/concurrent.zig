//! 并发值类型模块
//!
//! 定义 Glue 语言中承载并发语义的值类型：
//! - AtomicValue 互斥保护的原子操作容器
//! - AsyncHandle 异步任务句柄
//! - ChannelValue/SenderValue/ReceiverValue CSP 风格通道通信
//!
//! 这些类型持有或传递 Value，属于语义层，依赖 runtime 层的同步原语。
//! 所有类型以 ObjHeader 作为首字段，通过统一 retain/release 管理引用计数，
//! 各类型的 deinit 函数注册到 obj_header.deinit_table 中由分派表调用。
//!
//! 内存布局：
//! - AtomicValue/SenderValue/ReceiverValue：固定大小，走 createObj 页池
//! - AsyncHandle：固定大小，panic_message 独立分配（罕见路径）
//! - ChannelValue：连续内存 [header | Value buffer[cap]]，单次分配单次释放

const std = @import("std");
const value = @import("mod.zig");
const sync = @import("sync");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
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

    /// 创建初始引用计数为 1 的原子值（by-value，用于栈/临时）。
    /// 堆分配路径使用 tctx.createObj(AtomicValue) + 赋值。
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
    pub fn deinit(self: *AtomicValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            self.data.release(tctx);
        }
    }
};

/// AtomicValue 的 ObjHeader deinit 分派入口。
pub fn atomicDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *AtomicValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

// ──────────────────────────────────────────────
// AsyncHandle
// ──────────────────────────────────────────────

/// 异步任务的执行状态。
pub const AsyncStatus = enum(u8) {
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
/// panic_message 为独立分配（罕见路径），deinit 时由 freeObj 释放。
pub const AsyncHandle = struct {
    header: ObjHeader = .{ .type_tag = .async_val },
    status: std.atomic.Value(AsyncStatus),
    result: ?Value,
    consumed: std.atomic.Value(bool),
    finished: std.atomic.Value(bool),
    panic_message: ?[]const u8 = null,
    mutex: Mutex,
    condition: Condition,

    pub fn init() AsyncHandle {
        return AsyncHandle{
            .status = std.atomic.Value(AsyncStatus).init(.Pending),
            .result = null,
            .consumed = std.atomic.Value(bool).init(false),
            .finished = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .condition = .{},
        };
    }

    /// 释放句柄持有的资源，包括未消费的结果与 panic 信息。
    pub fn deinit(self: *AsyncHandle, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            if (self.result) |r| {
                var v = r;
                v.release(tctx);
            }
        }
        if (self.panic_message) |msg| {
            tctx.freeObj(@ptrCast(@constCast(msg.ptr)));
            self.panic_message = null;
        }
    }

    /// 设置任务状态（原子操作）
    pub fn setStatus(self: *AsyncHandle, status: AsyncStatus) void {
        self.status.store(status, .release);
        if (status == .Completed or status == .Failed or status == .Cancelled) {
            self.finished.store(true, .release);
            self.mutex.lock();
            self.condition.broadcast();
            self.mutex.unlock();
        }
    }

    /// 获取任务状态（原子操作）
    pub fn getStatus(self: *AsyncHandle) AsyncStatus {
        return self.status.load(.acquire);
    }

    /// 设置任务结果（在任务完成时调用）
    /// 注意：不持锁，依赖 setStatus 中 finished.store(.release) 提供的 happens-before 保证
    pub fn setResult(self: *AsyncHandle, val: Value) void {
        self.result = val;
        self.setStatus(.Completed);
    }

    /// 设置 panic 信息（在任务失败时调用）
    /// 通过 tctx.allocObj 独立分配 msg 副本，deinit 时由 freeObj 释放
    /// 注意：不持锁，依赖 setStatus 中 finished.store(.release) 提供的 happens-before 保证
    pub fn setPanic(self: *AsyncHandle, tctx: *ThreadContext, msg: []const u8) void {
        const buf = tctx.allocObj(msg.len) catch return;
        @memcpy(buf, msg);
        self.panic_message = buf;
        self.setStatus(.Failed);
    }

    /// 阻塞等待任务完成并消费结果
    /// 返回结果值，如果任务失败则返回 null
    pub fn join(self: *AsyncHandle) ?Value {
        // 快速路径：已完成
        if (self.finished.load(.acquire)) {
            return self.consumeResult();
        }
        // 慢速路径：等待完成
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.finished.load(.acquire)) {
            self.condition.wait(&self.mutex);
        }
        return self.consumeResult();
    }

    /// 消费结果（只能消费一次）
    fn consumeResult(self: *AsyncHandle) ?Value {
        if (self.consumed.swap(true, .acq_rel)) {
            return null; // 已被消费
        }
        const result = self.result;
        self.result = null;
        return result;
    }

    /// 检查任务是否已完成
    pub fn isFinished(self: *AsyncHandle) bool {
        return self.finished.load(.acquire);
    }
};

/// AsyncHandle 的 ObjHeader deinit 分派入口。
pub fn asyncDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *AsyncHandle = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

// ──────────────────────────────────────────────
// ChannelValue / SenderValue / ReceiverValue
// ──────────────────────────────────────────────

/// 通道值，支持有缓冲环形队列与无缓冲（会合）两种模式。
///
/// 当 `capacity` 为 0 时采用会合模式：发送方阻塞直到接收方取走值。
/// 通过 ObjHeader 引用计数支持多端共享，关闭后所有阻塞操作立即返回。
///
/// 连续内存布局：[ChannelValue header | Value buffer[capacity]]
/// buffer 切片指向尾部连续区域，单次分配单次释放。
/// 会合模式（capacity=0）下 buffer 为空切片，不分配额外空间。
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

    /// 创建容量为 `cap` 的通道。`cap` 为 0 时进入会合模式。
    /// 连续内存分配：[ChannelValue header | Value buffer[cap]]
    /// 返回堆分配的 *ChannelValue，buffer 指向 header 之后的连续区域。
    pub fn create(tctx: *ThreadContext, cap: usize) !*ChannelValue {
        const total = @sizeOf(ChannelValue) + cap * @sizeOf(Value);
        const mem = try tctx.allocObj(total);
        const self: *ChannelValue = @ptrCast(@alignCast(mem.ptr));
        const buf: []Value = if (cap == 0) &.{} else blk: {
            const buf_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(ChannelValue)));
            break :blk buf_ptr[0..cap];
        };
        self.* = .{
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
        };
        return self;
    }

    /// 释放通道资源，包括未消费的缓冲值与会合暂存值。
    /// buffer 是连续内存的一部分，随 channelDeinit 中的 freeObj 统一释放，无需单独释放。
    pub fn deinit(self: *ChannelValue, tctx: *ThreadContext) void {
        if (self.capacity > 0) {
            // 释放环形缓冲区中尚未被接收的值。
            if (!obj_header.shutdown_mode) {
                var i: usize = 0;
                while (i < self.count) : (i += 1) {
                    var v = self.buffer[(self.head + i) % self.capacity];
                    v.release(tctx);
                }
            }
            // buffer 连续内存随 freeObj 统一释放
        }
        if (self.rend_ready) {
            if (!obj_header.shutdown_mode) {
                if (self.rend_value) |v| {
                    var val = v;
                    val.release(tctx);
                }
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
pub fn channelDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ChannelValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

/// 发送端句柄，持有底层通道的引用。
pub const SenderValue = struct {
    header: ObjHeader = .{ .type_tag = .sender_val },
    channel: *ChannelValue,

    /// 释放内部资源（递减底层通道的引用计数），不销毁对象本体。
    pub fn deinit(self: *SenderValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            obj_header.release(&self.channel.header, tctx);
        }
    }
};

/// SenderValue 的 ObjHeader deinit 分派入口。
pub fn senderDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *SenderValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

/// 接收端句柄，持有底层通道的引用。
pub const ReceiverValue = struct {
    header: ObjHeader = .{ .type_tag = .receiver_val },
    channel: *ChannelValue,

    /// 释放内部资源（递减底层通道的引用计数），不销毁对象本体。
    pub fn deinit(self: *ReceiverValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            obj_header.release(&self.channel.header, tctx);
        }
    }
};

/// ReceiverValue 的 ObjHeader deinit 分派入口。
pub fn receiverDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ReceiverValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

/// 注册所有并发类型的 deinit 函数到 ObjHeader 分派表。
///
/// 应在运行时初始化阶段调用，使 obj_header.release 能正确分派到各类型的析构函数。
pub fn registerDeinits() void {
    obj_header.registerDeinit(.atomic_val, atomicDeinit);
    obj_header.registerDeinit(.async_val, asyncDeinit);
    obj_header.registerDeinit(.channel_val, channelDeinit);
    obj_header.registerDeinit(.sender_val, senderDeinit);
    obj_header.registerDeinit(.receiver_val, receiverDeinit);
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;
const mem_mod = @import("mem");

fn testCtx() struct { g: mem_mod.GlobalPool, c: ThreadContext } {
    var g = mem_mod.GlobalPool.init(testing.allocator);
    const c = ThreadContext.init(&g, testing.allocator);
    return .{ .g = g, .c = c };
}

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
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const ch = try ChannelValue.create(&tc.c, 3);
    defer tc.c.freeObj(@ptrCast(ch));
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
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const ch = try ChannelValue.create(&tc.c, 1);
    defer tc.c.freeObj(@ptrCast(ch));
    ch.close();
    try testing.expect(ch.recv() == null);
}

test "channel send after close returns false" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const ch = try ChannelValue.create(&tc.c, 2);
    defer tc.c.freeObj(@ptrCast(ch));
    ch.close();
    const v = Value.fromI32(99);
    try testing.expect(!(try ch.send(v)));
}

test "AsyncHandle setPanic 释放 panic_message" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const handle = try tc.c.createObj(AsyncHandle);
    handle.* = AsyncHandle.init();
    handle.setPanic(&tc.c, "boom");
    try testing.expect(handle.panic_message != null);
    try testing.expectEqualStrings("boom", handle.panic_message.?);
    try testing.expectEqual(AsyncStatus.Failed, handle.getStatus());
    // 手动触发 deinit（释放 panic_message 独立分配）
    handle.deinit(&tc.c);
    tc.c.freeObj(@ptrCast(handle));
}

test "ChannelValue 会合模式 capacity=0" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const ch = try ChannelValue.create(&tc.c, 0);
    defer tc.c.freeObj(@ptrCast(ch));
    try testing.expectEqual(@as(usize, 0), ch.capacity);
    try testing.expectEqual(@as(usize, 0), ch.buffer.len);
}
