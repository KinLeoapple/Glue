//! Channel 实现
//!
//! 文档 §3.5: 通过 channel 通信，不通过共享内存通信
//! 文档 §5.2: Channel 位于调度器 heap 中，两端只持有引用
//!
//! 使用 Zio 协程级同步原语（zio.Mutex/zio.Condition）：
//! - 在 Zio 协程上下文中：lock/wait 挂起当前协程让出执行权（M:N 调度友好）
//! - 在非协程上下文中（主线程/std.Thread）：自动回退到 futex 阻塞
//! - Zio Waiter 内部通过 getCurrentTaskOrNull() 检测上下文，自动选择挂起策略

const std = @import("std");
const zio = @import("zio");
const value = @import("value");

const Value = value.Value;
const ZioMutex = zio.Mutex;
const ZioCondition = zio.Condition;

/// Channel 值 — CSP 通信通道
/// 文档 §3.5: 通过 channel 通信，不通过共享内存通信
pub const ChannelValue = struct {
    /// 内部缓冲区
    buffer: std.ArrayList(Value),
    /// 缓冲区容量（0 = 同步/无缓冲）
    capacity: usize,
    /// 是否已关闭
    closed: bool,
    /// Zio 协程级互斥锁 — 保护缓冲区和关闭状态
    /// 在协程中挂起协程让出执行权，在非协程中回退到 futex
    mutex: ZioMutex,
    /// Zio 协程级条件变量 — recv 等待数据
    not_empty: ZioCondition,
    /// Zio 协程级条件变量 — send 等待空间
    not_full: ZioCondition,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 引用计数
    ref_count: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, cap: usize) ChannelValue {
        return ChannelValue{
            .buffer = std.ArrayList(Value).empty,
            .capacity = cap,
            .closed = false,
            .mutex = ZioMutex.init,
            .not_empty = ZioCondition.init,
            .not_full = ZioCondition.init,
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1),
        };
    }

    pub fn deinit(self: *ChannelValue) void {
        for (self.buffer.items) |v| {
            var val = v;
            val.deinit(self.allocator);
        }
        self.buffer.deinit(self.allocator);
    }

    /// 发送值到通道
    /// 关闭后返回 false
    pub fn send(self: *ChannelValue, val: Value) !bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();

        if (self.closed) return false;

        if (self.capacity == 0) {
            // 同步通道：直接放入一个元素
            try self.buffer.append(self.allocator, val);
            self.not_empty.signal();
            return true;
        } else {
            while (self.buffer.items.len >= self.capacity) {
                if (self.closed) return false;
                self.not_empty.waitUncancelable(&self.mutex);
            }
            try self.buffer.append(self.allocator, val);
            self.not_empty.signal();
            return true;
        }
    }

    /// 从通道接收值
    /// 缓冲区耗尽且已关闭返回 null
    pub fn recv(self: *ChannelValue) ?Value {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();

        while (self.buffer.items.len == 0) {
            if (self.closed) return null;
            self.not_empty.waitUncancelable(&self.mutex);
        }

        const val = self.buffer.orderedRemove(0);
        self.not_full.signal();
        return val;
    }

    /// 非阻塞接收 — 用于 select
    /// 无数据时返回 null（不区分关闭和空缓冲）
    pub fn tryRecv(self: *ChannelValue) ?Value {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();

        if (self.buffer.items.len == 0) return null;
        const val = self.buffer.orderedRemove(0);
        self.not_full.signal();
        return val;
    }

    /// 关闭通道（仅 Sender 可调用）
    pub fn close(self: *ChannelValue) void {
        self.mutex.lockUncancelable();
        self.closed = true;
        self.mutex.unlock();
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
