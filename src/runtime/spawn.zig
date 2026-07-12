//! 异步任务派生模块。
//!
//! 定义异步任务的状态枚举与任务句柄，用于跟踪派生任务的执行状态与结果。
//! 句柄内部通过原子状态与条件变量实现跨线程的结果同步。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");
const Value = value.Value;
const Mutex = sync.Mutex;
const Condition = sync.Condition;

/// 异步任务的执行状态。
pub const SpawnStatus = enum(u8) {
    Pending,
    Running,
    Completed,
    Cancelled,
    Failed,
};

/// 异步任务句柄，持有任务结果与同步原语。
///
/// 调用方可通过原子字段查询任务状态，并在任务完成后消费结果。
/// 句柄使用引用计数管理生命周期。
pub const SpawnHandle = struct {
    status: std.atomic.Value(SpawnStatus),
    result: ?Value,
    consumed: std.atomic.Value(bool),
    finished: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    panic_message: ?[]const u8 = null,
    mutex: Mutex,
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

    /// 释放句柄持有的资源，包括未消费的结果与 panic 信息。
    pub fn deinit(self: *SpawnHandle) void {
        if (self.result) |r| {
            var v = r;
            v.release(self.allocator);
        }
        if (self.panic_message) |msg| {
            std.heap.c_allocator.free(msg);
        }
    }
};
