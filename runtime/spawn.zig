//! Spawn<T> 实现
//!
//! 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费
//! 每个 spawn 拥有独立 Evaluator + Per-heap GC
//! 实现 Per-heap GC 隔离（协程结束时 GC 整体释放）
//! 实现 Panic 协程隔离（panic 被捕获存入 SpawnHandle）
//!
//! 文档 §3.7: M:N 调度，少量 OS 线程上运行大量轻量级协程
//!
//! 同步原语选择：
//! - 使用 Zio 协程级 Mutex/Condition（zio.Mutex/zio.Condition）
//! - 在协程上下文中：await 挂起当前协程让出执行权（M:N 调度友好）
//! - 在非协程上下文中：自动回退到 futex 阻塞
//! - Zio Waiter 内部通过 getCurrentTaskOrNull() 检测上下文，自动选择挂起策略

const std = @import("std");
const zio = @import("zio");
const value = @import("value");

const Value = value.Value;
const ZioMutex = zio.Mutex;
const ZioCondition = zio.Condition;

/// SpawnStatus 枚举值 — 协程状态
/// 文档 §3.3.2: SpawnStatus 枚举
pub const SpawnStatus = enum(u8) {
    Pending,
    Running,
    Completed,
    Cancelled,
    Failed,
};

/// SpawnHandle — Spawn<T> 的运行时表示
/// 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费
///
/// 使用 Zio 协程级 Mutex/Condition：
/// - 在协程上下文中 await 挂起协程让出执行权
/// - 在非协程上下文中自动回退到 futex 阻塞
pub const SpawnHandle = struct {
    status: std.atomic.Value(SpawnStatus),
    /// 协程执行结果（完成后存储）
    result: ?Value,
    /// 是否已被消费（await 或 cancel）
    consumed: std.atomic.Value(bool),
    /// worker 是否已彻底结束（不再触碰本 handle）。
    /// 由 worker 在退出前最后一步置位；Evaluator.deinit 释放 handle 前自旋等待它，
    /// 避免「主线程已 cancel/退出但 detached worker 仍在写 handle」的 use-after-free。
    finished: std.atomic.Value(bool),
    /// 分配器
    allocator: std.mem.Allocator,
    /// IO 上下文（由 Zio Runtime 提供）
    io: std.Io,
    /// Panic 消息（协程隔离：子协程 panic 不影响主协程）
    panic_message: ?[]const u8 = null,
    /// Zio 协程级 Mutex — 保护 result 和状态转换
    mutex: ZioMutex,
    /// Zio 协程级 Condition — await 挂起等待
    condition: ZioCondition,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SpawnHandle {
        return SpawnHandle{
            .status = std.atomic.Value(SpawnStatus).init(.Pending),
            .result = null,
            .consumed = std.atomic.Value(bool).init(false),
            .finished = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .io = io,
            .mutex = ZioMutex.init,
            .condition = ZioCondition.init,
        };
    }

    pub fn deinit(self: *SpawnHandle) void {
        if (self.result) |r| {
            var v = r;
            v.deinit(self.allocator);
        }
        if (self.panic_message) |msg| {
            self.allocator.free(msg);
        }
    }
};
