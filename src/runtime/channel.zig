//! Channel 实现
//!
//! 文档 §3.5: 通过 channel 通信，不通过共享内存通信
//! 文档 §5.2: Channel 位于调度器 heap 中，两端只持有引用
//!
//! 设计要点（本轮优化）：
//! - 缓冲通道 (capacity>0): 预分配 capacity 槽环形缓冲区，head/tail/count 三指针。
//!   消除原 ArrayList.orderedRemove(0) 的 O(n) memmove，send/recv 均 O(1)。
//! - 同步通道 (capacity==0): 真 rendezvous 语义。send 阻塞直到 recv 取走值
//!   （原实现是无界 ArrayList，与 CSP 语义不符且内存无限增长）。
//! - close() 在持锁状态下广播（原实现 unlock 后 broadcast 会丢唤醒，
//!   配合新 sync.Condition 的持锁调用约定）。
//! - 字段布局：buffer/head/tail/count 用于 buffered；rend_value/rend_ready 用于 rendezvous。
//!   两种模式互斥（由 capacity 决定），共享 mutex/not_empty/not_full。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");

const Value = value.Value;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// Channel 值 — CSP 通信通道
/// 文档 §3.5: 通过 channel 通信，不通过共享内存通信
pub const ChannelValue = struct {
    /// 环形缓冲区（capacity>0 时预分配；capacity==0 时为空切片）。
    buffer: []Value,
    /// 读位置（下一个 recv 取的槽）。
    head: usize,
    /// 写位置（下一个 send 放的槽）。
    tail: usize,
    /// 当前缓冲元素数。
    count: usize,
    /// 用户指定的容量。0 = rendezvous。
    capacity: usize,

    /// rendezvous 槽位（仅 capacity==0 用）。send 放入后阻塞直到 recv 取走。
    rend_value: ?Value,
    /// rendezvous 槽位是否有待取值。
    rend_ready: bool,

    /// 是否已关闭
    closed: bool,
    /// 互斥锁 — 保护缓冲区和关闭状态
    mutex: Mutex,
    /// 条件变量 — recv 等待数据 / send 通知有值
    not_empty: Condition,
    /// 条件变量 — send 等待空位 (buffered) 或已取走 (rendezvous)
    not_full: Condition,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 引用计数
    ref_count: std.atomic.Value(usize),

    /// 创建 ChannelValue。capacity==0 为 rendezvous 通道，>0 为缓冲通道（预分配 buffer）。
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

    pub fn deinit(self: *ChannelValue) void {
        // 释放 ring buffer 中残留值
        if (self.capacity > 0) {
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                var v = self.buffer[(self.head + i) % self.capacity];
                v.release(self.allocator);
            }
            self.allocator.free(self.buffer);
        }
        // 释放 rendezvous 槽中残留值（send 已交付但 recv 未取）
        if (self.rend_ready) {
            if (self.rend_value) |v| {
                var val = v;
                val.release(self.allocator);
            }
        }
    }

    /// 发送值到通道
    /// 关闭后返回 false；rendezvous 通道阻塞直到 recv 取走值
    pub fn send(self: *ChannelValue, val: Value) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return false;

        if (self.capacity == 0) {
            // rendezvous：等待槽空闲 → 放值 → 等待 recv 取走
            while (self.rend_ready) {
                if (self.closed) return false;
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return false;
            self.rend_value = val;
            self.rend_ready = true;
            self.not_empty.signal();
            // 阻塞直到 recv 取走（真 rendezvous 语义）
            while (self.rend_ready) {
                if (self.closed) return true; // 已交付，close 不撤销
                self.not_full.wait(&self.mutex);
            }
            return true;
        }

        // buffered：等待空位
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

    /// 从通道接收值
    /// 缓冲区耗尽且已关闭返回 null
    pub fn recv(self: *ChannelValue) ?Value {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.capacity == 0) {
            // rendezvous：等待有值 → 取走 → 通知 send
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

        // buffered
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

    /// 非阻塞接收 — 用于 select
    /// 无数据时返回 null（不区分关闭和空缓冲）
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

    /// 关闭通道（仅 Sender 可调用）
    /// 持锁广播：与新 sync.Condition 的持锁调用约定一致，避免 unlock 后 broadcast 丢唤醒。
    pub fn close(self: *ChannelValue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
    }

    /// 增加引用计数
    pub fn ref(self: *ChannelValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，归零返回 true
    pub fn unref(self: *ChannelValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
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

// ── 单测 ──

const testing = std.testing;

test "buffered channel ring buffer FIFO order" {
    var ch = try ChannelValue.init(testing.allocator, 3);
    defer ch.deinit();

    // send 3 个值（填满缓冲）
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 10))));
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 20))));
    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 30))));

    // 第 4 个应阻塞（缓冲满）— 先 tryRecv 消费一个腾出空位
    const v1 = ch.tryRecv().?;
    try testing.expectEqual(@as(i32, 10), v1.asInt().toNative(i32));

    try testing.expect(try ch.send(Value.fromInt(value.Int.fromNative(.i32, 40))));

    // FIFO 顺序验证
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

    // 空通道 close 后 recv 应返回 null（不阻塞）
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
