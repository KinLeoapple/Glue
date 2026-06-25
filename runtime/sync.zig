//! 简单的同步原语实现
//! 使用原子操作和自旋锁

const std = @import("std");

/// 简单的互斥锁（自旋锁）
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(UNLOCKED, .release);
    }
};

/// 简单的条件变量（基于自旋）
pub const Condition = struct {
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self.waiters.fetchAdd(1, .monotonic);
        mutex.unlock();

        // 简单的自旋等待实现
        // 注意：这不是最优的，但在没有 futex 的情况下是可行的
        while (self.waiters.load(.monotonic) > 0) {
            std.atomic.spinLoopHint();
        }

        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        if (self.waiters.load(.monotonic) > 0) {
            _ = self.waiters.fetchSub(1, .monotonic);
        }
    }

    pub fn broadcast(self: *Condition) void {
        self.waiters.store(0, .release);
    }
};
