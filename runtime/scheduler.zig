//! Work-stealing 调度器（基于 Zio 运行时）
//!
//! Phase 4 实现：并发原语
//! 文档 §3.7: M:N 调度，少量 OS 线程上运行大量轻量级协程
//! 使用 Zio 库提供 stackful coroutine + io_uring/IOCP/kqueue 事件循环

const std = @import("std");
const zio = @import("zio");

pub const Scheduler = struct {
    runtime: *zio.Runtime,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Scheduler {
        const runtime = try allocator.create(zio.Runtime);
        runtime.* = try zio.Runtime.init(allocator, .{
            .executors = .auto,
        });
        return Scheduler{
            .runtime = runtime,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.runtime.deinit();
        self.allocator.destroy(self.runtime);
    }
};
