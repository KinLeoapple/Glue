//! Spawn<T> 实现
//!
//! 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费
//! 每个 spawn 拥有独立 VM + Per-spawn arena
//! 实现内存隔离（协程结束时 arena 整体释放）
//! 实现 Panic 协程隔离（panic 被捕获存入 SpawnHandle）

const std = @import("std");
const value = @import("value");
const sync = @import("sync");

const Value = value.Value;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

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
pub const SpawnHandle = struct {
    status: std.atomic.Value(SpawnStatus),
    /// 协程执行结果（完成后存储）
    result: ?Value,
    /// 是否已被消费（await 或 cancel）
    consumed: std.atomic.Value(bool),
    /// worker 是否已彻底结束（不再触碰本 handle）。
    /// 由 worker 在退出前最后一步置位；VM.deinit 释放 handle 前自旋等待它，
    /// 避免「主线程已 cancel/退出但 detached worker 仍在写 handle」的 use-after-free。
    finished: std.atomic.Value(bool),
    /// 分配器
    allocator: std.mem.Allocator,
    /// Panic 消息（协程隔离：子协程 panic 不影响主协程）
    panic_message: ?[]const u8 = null,
    /// 互斥锁 — 保护 result 和状态转换
    mutex: Mutex,
    /// 条件变量 — await 等待完成
    condition: Condition,

    pub fn init(allocator: std.mem.Allocator) SpawnHandle {
        return SpawnHandle{
            .status = std.atomic.Value(SpawnStatus).init(.Pending),
            .result = null,
            .consumed = std.atomic.Value(bool).init(false),
            .finished = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .condition = .{},
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
