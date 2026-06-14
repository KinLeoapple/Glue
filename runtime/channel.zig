//! Channel 实现
//!
//! 文档 §3.5: 通过 channel 通信，不通过共享内存通信

const std = @import("std");
const value = @import("value");

const Value = value.Value;

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
