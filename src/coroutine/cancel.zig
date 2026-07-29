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
const CoroutineStatus = frame_mod.CoroutineStatus;
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

    // 2. CAS .suspended → .cancelled：仅当 CAS 成功才入队执行 cancel 路径。
    //    CAS 保护：wakeChain 可能已将帧状态从 .suspended 改为 .ready，
    //    此时 cancel 不应再入队（帧已在就绪队列中），避免双重入队（UAF）。
    if (frame.status.cmpxchgStrong(
        @intFromEnum(CoroutineStatus.suspended),
        @intFromEnum(CoroutineStatus.cancelled),
        .acq_rel,
        .monotonic,
    ) != null) {
        // CAS failed: frame was already woken/completed — skip enqueue
        return;
    }

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
