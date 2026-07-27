//! cancel 语义处理：取消协程 + 执行 defer 清理路径。
//!
//! cancel 流程（spec 3.4）：
//! 1. 从挂起注册表移除帧（若在挂起中）
//! 2. 标记 Cancelled
//! 3. 入就绪队列 → worker 调度时走 cancel 路径
//!
//! cancel 路径（runCancelPath）：
//! - 逆序执行已注册 defer（defer 块体是 sync 函数，临时栈跑）
//! - defer 执行完转终态，帧回池
//!
//! defer 块体执行需要 Engine 接入（通过 SegmentContext），
//! 批次 2 提供 runCancelPath 框架，defer 实际执行由 Engine 注入回调完成。

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;

/// 取消协程：从挂起注册表移除 + 标记 Cancelled + 入就绪队列执行 cancel 路径。
///
/// cancel 路径由 worker 主循环检测到 Cancelled 状态后调用 runCancelPath 执行：
/// 逆序执行已注册 defer，然后转终态。
/// defer 块体是 sync 函数，在 worker 临时栈执行（需 Engine 接入）。
pub fn cancelFrame(scheduler: *Scheduler, frame: *CoroutineFrame) void {
    // 1. 从挂起注册表移除（若在挂起中）
    scheduler.suspend_registry.remove(frame);

    // 2. 标记 Cancelled
    frame.setStatus(.cancelled);

    // 3. 入就绪队列，worker 调度时检测 Cancelled 状态走 cancel 路径
    //    选最闲 worker 入队
    if (scheduler.workers.len == 0) return;
    var min_idx: usize = 0;
    var min_count: u64 = scheduler.workers[0].readyCount();
    for (scheduler.workers[1..], 1..) |*w, i| {
        const c = w.readyCount();
        if (c < min_count) {
            min_count = c;
            min_idx = i;
        }
    }
    scheduler.workers[min_idx].pushReady(frame);
}

/// 执行 cancel 路径：逆序执行已注册 defer，转终态。
///
/// 由 worker 主循环在检测到帧状态为 Cancelled 时调用。
/// defer 块体执行需 Engine 接入（通过 SegmentContext.exec_node 执行 defer 块函数），
/// 批次 2 框架版：清空 suspend_target，defer 执行留 Engine 接入时完善。
pub fn runCancelPath(frame: *CoroutineFrame) void {
    // 清空挂起目标（帧已从挂起队列移除）
    frame.suspend_target = .none;

    // 逆序执行已注册 defer（defer_depth 个）
    // defer 块体是独立 sync 函数，需 Engine 通过 SegmentContext.exec_node 执行
    // 批次 2 框架：defer 执行待 Engine 接入后完善
    // 当前清零 defer_depth 表示 cancel 路径已走完
    frame.defer_depth = 0;
}

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const ir_mod = @import("ir");
const FrameLayout = ir_mod.FrameLayout;
const value_mod = @import("value");
const ChannelValue = value_mod.ChannelValue;
const SuspendRegistry = @import("suspend_registry.zig").SuspendRegistry;
const FramePool = frame_mod.FramePool;

fn emptyLayout() FrameLayout {
    return .{
        .total_size = 0,
        .param_region = .{ .start = 0, .size = 0 },
        .local_region = .{ .start = 0, .size = 0 },
        .temp_region = .{ .start = 0, .size = 0 },
    };
}

test "cancelFrame 标记 Cancelled 并入队" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = FramePool.init(testing.allocator, io);
    defer pool.deinit();
    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var sched = Scheduler.init(testing.allocator, io, &pool, &registry);
    // 不用 sched.deinit()——手动管理 worker 生命周期避免 defer 顺序问题
    const WorkerMod = @import("worker.zig");
    const storage = try testing.allocator.alloc(WorkerMod.Worker, 1);
    storage[0] = try WorkerMod.Worker.init(0, testing.allocator);
    sched.workers = storage;
    defer {
        storage[0].deinit();
        testing.allocator.free(storage);
    }

    const frame = try pool.alloc(0, emptyLayout(), &[_]u16{});
    frame.setStatus(.suspended);
    // 模拟挂起在 channel 上
    var chan: ChannelValue = undefined;
    chan.header = .{ .type_tag = .channel_val };
    registry.registerChanRecv(&chan, frame);

    // cancel
    cancelFrame(&sched, frame);

    try testing.expectEqual(frame_mod.CoroutineStatus.cancelled, frame.getStatus());
    try testing.expectEqual(@as(u64, 1), sched.workers[0].readyCount());
    // 挂起队列应已清空
    const wc = registry.waiterCount();
    try testing.expectEqual(@as(u32, 0), wc.recv);

    // 清理：从就绪队列弹出帧并回池
    const popped = sched.workers[0].popLocal().?;
    try testing.expectEqual(frame, popped);
    pool.free(popped);
}

test "runCancelPath 清空挂起目标" {
    var frame = CoroutineFrame.initFixed(0, emptyLayout(), &[_]u16{});
    frame.suspend_target = .{ .chan_recv = @ptrFromInt(0xdead) };
    frame.defer_depth = 3;

    runCancelPath(&frame);

    try testing.expectEqual(frame_mod.SuspendTarget.none, frame.suspend_target);
    try testing.expectEqual(@as(u16, 0), frame.defer_depth);
}
