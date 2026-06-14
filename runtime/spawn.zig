//! Spawn<T> 实现（基于 std.Thread 真正并发）
//!
//! 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费
//! 每个 spawn 在独立线程中执行，拥有独立 Evaluator + ArenaAllocator
//! 实现 Per-heap GC 隔离（协程结束时 Arena 整体释放）
//! 实现 Panic 协程隔离（panic 被捕获存入 SpawnHandle）

const std = @import("std");
const value = @import("value");

const Value = value.Value;

/// SpawnStatus 枚举值 — 协程状态
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
    /// 协程线程
    thread: ?std.Thread,
    /// 互斥锁 — 保护 result 和状态转换
    mutex: std.Io.Mutex,
    /// 条件变量 — await 阻塞等待
    condition: std.Io.Condition,
    /// 是否已被消费（await 或 cancel）
    consumed: std.atomic.Value(bool),
    /// 分配器
    allocator: std.mem.Allocator,
    /// IO 上下文
    io: std.Io,
    /// Panic 消息（协程隔离：子协程 panic 不影响主协程）
    panic_message: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SpawnHandle {
        return SpawnHandle{
            .status = std.atomic.Value(SpawnStatus).init(.Pending),
            .result = null,
            .thread = null,
            .mutex = std.Io.Mutex.init,
            .condition = std.Io.Condition.init,
            .consumed = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .io = io,
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
