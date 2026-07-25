//! worker 线程：跑协程状态机段的执行单元。
//!
//! 每 worker 持有：
//! - 本地就绪队列（Chase-Lev deque，LIFO push/pop + FIFO steal）
//! - 段执行入口（state_machine.runSegment，批次 2 实现）
//! - 线程句柄
//!
//! 主循环（spec 4.4）：
//! 1. popLocal（LIFO，缓存友好）
//! 2. trySteal（从其他 worker 的队列 FIFO 偷取）
//! 3. 仍无 → waitForWork（让出线程，等被唤醒）
//!
//! work-stealing 策略：本地空 → 随机选 victim → 偷一个 → 仍空 → 让出。
//! 偷取从 victim 队列 top 端（FIFO），减少与 owner 的 bottom 端竞争。

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const deque_mod = @import("deque.zig");
const WorkStealingDeque = deque_mod.WorkStealingDeque;

/// worker 线程：跑协程状态机段的执行单元。
pub const Worker = struct {
    id: u16,
    scheduler: ?*anyopaque = null, // *Scheduler，避免循环依赖用 anyopaque
    /// 本地就绪队列（Chase-Lev 无锁双端队列）
    ready_queue: WorkStealingDeque,
    /// worker 是否存活（主循环退出条件）
    alive: std.atomic.Value(bool),
    /// 线程句柄
    thread: ?std.Thread = null,
    /// backoff 计数（连续偷取失败时递增，减少无效轮询）
    steal_fail_count: u32 = 0,

    /// 创建 worker（分配就绪队列，不启动线程）
    pub fn init(id: u16, backing: std.mem.Allocator) !Worker {
        return .{
            .id = id,
            .ready_queue = try WorkStealingDeque.init(backing),
            .alive = std.atomic.Value(bool).init(false),
        };
    }

    /// 释放 worker 资源（就绪队列缓冲区）
    pub fn deinit(self: *Worker) void {
        self.ready_queue.deinit();
        if (self.thread) |t| {
            t.detach();
            self.thread = null;
        }
    }

    /// 入就绪队列（owner 线程或调度器调用）
    /// 帧状态由调用方设为 Ready，此方法只负责入队。
    pub fn pushReady(self: *Worker, frame: *CoroutineFrame) void {
        self.ready_queue.push(frame) catch {
            // 就绪队列溢出：直接放回全局队列（调度器注入的 fallback）
            // 批次 1 不实现全局队列，溢出视为调度异常
            @panic("worker ready queue overflow");
        };
    }

    /// 从本地就绪队列取协程（LIFO，缓存友好）
    pub fn popLocal(self: *Worker) ?*CoroutineFrame {
        return self.ready_queue.pop();
    }

    /// 从别的 worker 偷协程（FIFO，从 top 端偷取，减少与 owner 冲突）
    /// 返回 null 表示偷取失败（队列空或竞争失败）
    pub fn stealFrom(self: *Worker, victim: *Worker) ?*CoroutineFrame {
        _ = self;
        return victim.ready_queue.steal();
    }

    /// 启动 worker 线程
    /// run_fn 是 worker 主循环函数（Scheduler 提供，避免循环依赖）
    pub fn start(self: *Worker, run_fn: fn (*Worker) void) !void {
        self.alive.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run_fn, .{self});
    }

    /// 请求 worker 退出
    pub fn requestStop(self: *Worker) void {
        self.alive.store(false, .release);
    }

    /// 等待 worker 线程退出（join）
    pub fn join(self: *Worker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// worker 是否存活
    pub fn isAlive(self: *const Worker) bool {
        return self.alive.load(.acquire);
    }

    /// 就绪队列长度（近似值，监控用）
    pub fn readyCount(self: *const Worker) u64 {
        return self.ready_queue.size();
    }
};

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

fn makeFrame(id: u16) CoroutineFrame {
    return CoroutineFrame.initFixed(id, emptyLayout());
}

test "Worker pushReady/popLocal LIFO" {
    var w1 = try Worker.init(0, testing.allocator);
    defer w1.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);
    var f3 = makeFrame(3);

    w1.pushReady(&f1);
    w1.pushReady(&f2);
    w1.pushReady(&f3);

    // LIFO
    try testing.expectEqual(&f3, w1.popLocal().?);
    try testing.expectEqual(&f2, w1.popLocal().?);
    try testing.expectEqual(&f1, w1.popLocal().?);
    try testing.expectEqual(@as(?*CoroutineFrame, null), w1.popLocal());
}

test "Worker stealFrom 跨 worker 偷取" {
    var w1 = try Worker.init(0, testing.allocator);
    defer w1.deinit();
    var w2 = try Worker.init(1, testing.allocator);
    defer w2.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);
    var f3 = makeFrame(3);

    // w1 push 三个
    w1.pushReady(&f1);
    w1.pushReady(&f2);
    w1.pushReady(&f3);

    // w2 从 w1 偷（FIFO，从 top 端）
    try testing.expectEqual(&f1, w2.stealFrom(&w1).?);
    try testing.expectEqual(&f2, w2.stealFrom(&w1).?);

    // w1 pop 剩余（LIFO）
    try testing.expectEqual(&f3, w1.popLocal().?);
    try testing.expectEqual(@as(?*CoroutineFrame, null), w1.popLocal());
}

test "Worker readyCount 近似值" {
    var w = try Worker.init(0, testing.allocator);
    defer w.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);

    try testing.expectEqual(@as(u64, 0), w.readyCount());
    w.pushReady(&f1);
    w.pushReady(&f2);
    try testing.expectEqual(@as(u64, 2), w.readyCount());
    _ = w.popLocal();
    try testing.expectEqual(@as(u64, 1), w.readyCount());
}

test "Worker requestStop/isAlive" {
    var w = try Worker.init(0, testing.allocator);
    defer w.deinit();
    try testing.expect(!w.isAlive());
    w.alive.store(true, .release);
    try testing.expect(w.isAlive());
    w.requestStop();
    try testing.expect(!w.isAlive());
}
