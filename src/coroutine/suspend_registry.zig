//! 挂起目标注册表：集中管理所有挂起帧的等待队列。
//!
//! channel send/recv/async complete 操作触发 wake*，唤醒等待者：
//! 唤醒 = 从等待链表摘除 + 设帧状态 Ready + 入就绪队列（通过 ready_callback）。
//!
//! 三类等待队列：
//! - chan_recv_waiters: channel 可读等待者（orbit_chan_recv 挂起）
//! - chan_send_waiters: channel 可写等待者（orbit_chan_send 挂起）
//! - async_join_waiters: AsyncHandle 完成等待者（orbit_async_join 挂起）
//!
//! 等待链表用侵入式单链表（帧的 wait_next 指针），FIFO 唤醒（公平）。
//! Io.Mutex 保护，fiber-aware（协程化后挂起 fiber 而非阻塞线程）。
//!
//! 唤醒回调：注册表不直接操作 Worker 就绪队列（避免循环依赖），
//! 由 Scheduler 注入 enqueue 回调，wake* 调用它将帧入就绪队列。

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const CoroutineStatus = frame_mod.CoroutineStatus;
const value_mod = @import("value");
const ChannelValue = value_mod.ChannelValue;
const AsyncHandle = value_mod.AsyncHandle;

/// 唤醒回调类型：将帧入就绪队列。
/// Scheduler 提供，避免 registry ↔ worker 循环依赖。
pub const EnqueueFn = *const fn (ctx: *anyopaque, frame: *CoroutineFrame) void;

/// 等待链表（侵入式单链表，FIFO 唤醒）
const WaiterList = struct {
    head: ?*CoroutineFrame = null,
    tail: ?*CoroutineFrame = null,

    /// 追加到队尾（FIFO 公平）
    fn pushBack(self: *WaiterList, frame: *CoroutineFrame) void {
        frame.wait_next = null;
        if (self.tail) |t| {
            t.wait_next = frame;
            self.tail = frame;
        } else {
            self.head = frame;
            self.tail = frame;
        }
    }

    /// 从队头摘除（FIFO 唤醒）
    fn popFront(self: *WaiterList) ?*CoroutineFrame {
        const f = self.head orelse return null;
        self.head = f.wait_next;
        if (self.head == null) self.tail = null;
        f.wait_next = null;
        return f;
    }

    /// 从链表移除指定帧（cancel 用，O(n)）
    fn remove(self: *WaiterList, target: *CoroutineFrame) void {
        if (self.head == target) {
            self.head = target.wait_next;
            if (self.head == null) self.tail = null;
            target.wait_next = null;
            return;
        }
        var prev = self.head;
        while (prev) |p| {
            if (p.wait_next == target) {
                p.wait_next = target.wait_next;
                if (self.tail == target) self.tail = p;
                target.wait_next = null;
                return;
            }
            prev = p.wait_next;
        }
    }

    fn isEmpty(self: *const WaiterList) bool {
        return self.head == null;
    }
};

/// 挂起目标注册表
pub const SuspendRegistry = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    backing: std.mem.Allocator,
    /// channel → 等待可读的帧链表
    chan_recv_waiters: std.AutoHashMapUnmanaged(*ChannelValue, WaiterList),
    /// channel → 等待可写的帧链表
    chan_send_waiters: std.AutoHashMapUnmanaged(*ChannelValue, WaiterList),
    /// AsyncHandle → 等待完成的帧链表
    async_join_waiters: std.AutoHashMapUnmanaged(*AsyncHandle, WaiterList),
    /// 唤醒回调（Scheduler 注入，将帧入就绪队列）
    enqueue_ctx: ?*anyopaque = null,
    enqueue_fn: ?EnqueueFn = null,

    /// 创建注册表
    pub fn init(io: std.Io, backing: std.mem.Allocator) SuspendRegistry {
        return .{
            .io = io,
            .backing = backing,
            .chan_recv_waiters = .{},
            .chan_send_waiters = .{},
            .async_join_waiters = .{},
        };
    }

    /// 释放注册表资源
    pub fn deinit(self: *SuspendRegistry) void {
        self.chan_recv_waiters.deinit(self.backing);
        self.chan_send_waiters.deinit(self.backing);
        self.async_join_waiters.deinit(self.backing);
    }

    /// 注册唤醒回调（Scheduler 启动时调用）
    pub fn setEnqueueCallback(self: *SuspendRegistry, ctx: *anyopaque, fn_: EnqueueFn) void {
        self.enqueue_ctx = ctx;
        self.enqueue_fn = fn_;
    }

    /// 注册 channel recv 等待：帧挂起等待 channel 可读
    pub fn registerChanRecv(self: *SuspendRegistry, chan: *ChannelValue, frame: *CoroutineFrame) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = self.chan_recv_waiters.getOrPut(self.backing, chan) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.pushBack(frame);
    }

    /// 注册 channel send 等待：帧挂起等待 channel 可写
    pub fn registerChanSend(self: *SuspendRegistry, chan: *ChannelValue, frame: *CoroutineFrame) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = self.chan_send_waiters.getOrPut(self.backing, chan) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.pushBack(frame);
    }

    /// 注册 async join 等待：帧挂起等待 AsyncHandle 完成
    pub fn registerAsyncJoin(self: *SuspendRegistry, handle: *AsyncHandle, frame: *CoroutineFrame) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = self.async_join_waiters.getOrPut(self.backing, handle) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.pushBack(frame);
    }

    /// 唤醒 channel recv 等待者：channel 有数据可读时调用
    /// 唤醒所有等待者（broadcast，由 runSegment try-first 决定谁真正读到）
    pub fn wakeChanRecv(self: *SuspendRegistry, chan: *ChannelValue) void {
        var to_wake: ?*CoroutineFrame = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.chan_recv_waiters.getPtr(chan)) |list| {
                // 唤醒全部等待者（broadcast）：多个协程可能同时等同一 channel，
                // try-first 保证只有一个真正读到，其余重新挂起
                to_wake = list.head;
                list.head = null;
                list.tail = null;
            }
        }
        // 解锁后入就绪队列（避免持锁回调）
        wakeChain(to_wake, self.enqueue_ctx, self.enqueue_fn);
    }

    /// 唤醒 channel send 等待者：channel 有空间可写时调用
    pub fn wakeChanSend(self: *SuspendRegistry, chan: *ChannelValue) void {
        var to_wake: ?*CoroutineFrame = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.chan_send_waiters.getPtr(chan)) |list| {
                to_wake = list.head;
                list.head = null;
                list.tail = null;
            }
        }
        wakeChain(to_wake, self.enqueue_ctx, self.enqueue_fn);
    }

    /// 唤醒 async join 等待者：AsyncHandle 完成时调用
    pub fn wakeAsyncJoin(self: *SuspendRegistry, handle: *AsyncHandle) void {
        var to_wake: ?*CoroutineFrame = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.async_join_waiters.getPtr(handle)) |list| {
                to_wake = list.head;
                list.head = null;
                list.tail = null;
            }
        }
        wakeChain(to_wake, self.enqueue_ctx, self.enqueue_fn);
    }

    /// 从所有等待队列移除帧（cancel 用，帧被取消时从挂起链摘除）
    pub fn remove(self: *SuspendRegistry, frame: *CoroutineFrame) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // 遍历所有等待队列移除（cancel 不知帧在哪个队列，全扫）
        var recv_it = self.chan_recv_waiters.valueIterator();
        while (recv_it.next()) |list| list.remove(frame);
        var send_it = self.chan_send_waiters.valueIterator();
        while (send_it.next()) |list| list.remove(frame);
        var join_it = self.async_join_waiters.valueIterator();
        while (join_it.next()) |list| list.remove(frame);
    }

    /// 等待者计数（监控/profiling 用，近似值）
    pub fn waiterCount(self: *SuspendRegistry) struct { recv: u32, send: u32, join: u32 } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var recv: u32 = 0;
        var send: u32 = 0;
        var join: u32 = 0;
        var recv_it = self.chan_recv_waiters.valueIterator();
        while (recv_it.next()) |list| {
            var n: u32 = 0;
            var cur = list.head;
            while (cur) |f| : (cur = f.wait_next) n += 1;
            recv += n;
        }
        var send_it = self.chan_send_waiters.valueIterator();
        while (send_it.next()) |list| {
            var n: u32 = 0;
            var cur = list.head;
            while (cur) |f| : (cur = f.wait_next) n += 1;
            send += n;
        }
        var join_it = self.async_join_waiters.valueIterator();
        while (join_it.next()) |list| {
            var n: u32 = 0;
            var cur = list.head;
            while (cur) |f| : (cur = f.wait_next) n += 1;
            join += n;
        }
        return .{ .recv = recv, .send = send, .join = join };
    }
};

/// 唤醒链表上所有帧：逐个设 Ready + 入就绪队列
fn wakeChain(head: ?*CoroutineFrame, ctx: ?*anyopaque, enqueue_fn: ?EnqueueFn) void {
    var cur = head;
    while (cur) |f| {
        const next = f.wait_next;
        f.wait_next = null;
        f.setStatus(.ready);
        if (enqueue_fn) |fn_| if (ctx) |c| fn_(c, f);
        cur = next;
    }
}

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const ir_mod = @import("ir");
const FrameLayout = ir_mod.FrameLayout;

fn emptyLayout() FrameLayout {
    return .{
        .total_size = 0,
        .param_region = .{ .start = 0, .size = 0 },
        .local_region = .{ .start = 0, .size = 0 },
        .temp_region = .{ .start = 0, .size = 0 },
    };
}

/// 测试用唤醒计数器
const WakeCounter = struct {
    count: u32 = 0,
    woken: std.ArrayList(*CoroutineFrame),
    backing: std.mem.Allocator,

    fn enqueue(ctx: *anyopaque, frame: *CoroutineFrame) void {
        const self: *WakeCounter = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.woken.append(self.backing, frame) catch {};
    }
};

test "WaiterList FIFO pushBack/popFront" {
    var list = WaiterList{};
    var f1 = CoroutineFrame.initFixed(1, emptyLayout(), &[_]u16{});
    var f2 = CoroutineFrame.initFixed(2, emptyLayout(), &[_]u16{});
    var f3 = CoroutineFrame.initFixed(3, emptyLayout(), &[_]u16{});

    try testing.expect(list.isEmpty());
    list.pushBack(&f1);
    list.pushBack(&f2);
    list.pushBack(&f3);

    try testing.expectEqual(&f1, list.popFront().?);
    try testing.expectEqual(&f2, list.popFront().?);
    try testing.expectEqual(&f3, list.popFront().?);
    try testing.expectEqual(@as(?*CoroutineFrame, null), list.popFront());
    try testing.expect(list.isEmpty());
}

test "WaiterList remove 中间与首尾" {
    var list = WaiterList{};
    var f1 = CoroutineFrame.initFixed(1, emptyLayout(), &[_]u16{});
    var f2 = CoroutineFrame.initFixed(2, emptyLayout(), &[_]u16{});
    var f3 = CoroutineFrame.initFixed(3, emptyLayout(), &[_]u16{});

    list.pushBack(&f1);
    list.pushBack(&f2);
    list.pushBack(&f3);

    // 移除中间
    list.remove(&f2);
    try testing.expectEqual(&f1, list.popFront().?);
    try testing.expectEqual(&f3, list.popFront().?);
    try testing.expect(list.isEmpty());

    // 移除队头
    list.pushBack(&f1);
    list.pushBack(&f2);
    list.remove(&f1);
    try testing.expectEqual(&f2, list.popFront().?);

    // 移除队尾
    list.pushBack(&f1);
    list.pushBack(&f2);
    list.remove(&f2);
    try testing.expectEqual(&f1, list.popFront().?);
}

test "SuspendRegistry register/wakeChanRecv 唤醒入就绪队列" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var counter = WakeCounter{ .woken = .empty, .backing = testing.allocator };
    defer counter.woken.deinit(testing.allocator);
    registry.setEnqueueCallback(@ptrCast(&counter), WakeCounter.enqueue);

    // ChannelValue 需要完整 ObjHeader，测试用 stack 分配模拟
    var chan: ChannelValue = undefined;
    chan.header = .{ .type_tag = .channel_val };

    var f1 = CoroutineFrame.initFixed(1, emptyLayout(), &[_]u16{});
    var f2 = CoroutineFrame.initFixed(2, emptyLayout(), &[_]u16{});
    f1.setStatus(.suspended);
    f2.setStatus(.suspended);

    registry.registerChanRecv(&chan, &f1);
    registry.registerChanRecv(&chan, &f2);

    const wc = registry.waiterCount();
    try testing.expectEqual(@as(u32, 2), wc.recv);

    // 唤醒：两个帧都应入就绪队列
    registry.wakeChanRecv(&chan);
    try testing.expectEqual(@as(u32, 2), counter.count);
    try testing.expectEqual(CoroutineStatus.ready, f1.getStatus());
    try testing.expectEqual(CoroutineStatus.ready, f2.getStatus());

    // 唤醒后等待队列应空
    const wc2 = registry.waiterCount();
    try testing.expectEqual(@as(u32, 0), wc2.recv);
}

test "SuspendRegistry remove 从挂起队列摘除" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var counter = WakeCounter{ .woken = .empty, .backing = testing.allocator };
    defer counter.woken.deinit(testing.allocator);
    registry.setEnqueueCallback(@ptrCast(&counter), WakeCounter.enqueue);

    var chan: ChannelValue = undefined;
    chan.header = .{ .type_tag = .channel_val };

    var f1 = CoroutineFrame.initFixed(1, emptyLayout(), &[_]u16{});
    var f2 = CoroutineFrame.initFixed(2, emptyLayout(), &[_]u16{});
    registry.registerChanRecv(&chan, &f1);
    registry.registerChanRecv(&chan, &f2);

    // 移除 f1（cancel 语义）
    registry.remove(&f1);

    // 唤醒只应唤起 f2
    registry.wakeChanRecv(&chan);
    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expectEqual(&f2, counter.woken.items[0]);
}

test "SuspendRegistry 空唤醒无副作用" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var counter = WakeCounter{ .woken = .empty, .backing = testing.allocator };
    defer counter.woken.deinit(testing.allocator);
    registry.setEnqueueCallback(@ptrCast(&counter), WakeCounter.enqueue);

    var chan: ChannelValue = undefined;
    chan.header = .{ .type_tag = .channel_val };

    // 无等待者时唤醒
    registry.wakeChanRecv(&chan);
    try testing.expectEqual(@as(u32, 0), counter.count);
}
