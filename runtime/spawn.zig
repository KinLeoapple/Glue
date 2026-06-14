//! Spawn<T> 实现（基于 std.Thread）
//!
//! 文档 §3.3: Spawn 是线性类型，必须被 await() 或 cancel() 消费

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
    }
};
