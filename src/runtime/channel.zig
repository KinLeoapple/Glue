//! 通道模块。
//!
//! 实现 CSP 风格的并发通信原语，支持有缓冲与无缓冲（会合）两种模式。
//! 通道通过互斥锁与条件变量保证线程安全，关闭后唤醒所有阻塞的发送方与接收方。
//! 同时提供 `SenderValue`/`ReceiverValue` 引用句柄，共享同一底层通道。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");
const Value = value.Value;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// 通道值，支持有缓冲环形队列与无缓冲会合传递。
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

const testing = std.testing;

test "buffered channel ring buffer FIFO order" {
    var ch = try ChannelValue.init(testing.allocator, 3);
    defer ch.deinit();
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 10))));
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 20))));
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 30))));
    const v1 = ch.tryRecv().?;
    try testing.expectEqual(@as(i32, 10), v1.asInt().toNative(i32));
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 40))));
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
    const v = Value.fromInt(value.Int.fromNative(.i32, 99));
    try testing.expect(!(try ch.send(v)));
}
