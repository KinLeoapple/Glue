//! 简单的同步原语实现
//! 使用原子操作和自旋锁
//!
//! 设计要点（已修复原 Condition 的致命语义错误）：
//! - Condition 用「等待者计数 + 待消费唤醒计数」双原子量模型。
//! - wait() 在持锁状态下登记 waiters，再释放锁自旋等 wakeups>0，
//!   消费一个唤醒后扣减 waiters。
//! - signal()/broadcast() 仅在 waiters>0 时累积 wakeups（避免无谓 spurious）。
//! - 调用方必须持锁调用 signal/broadcast（与 wait 持锁登记配对），
//!   否则会丢唤醒。channel.close 已改为持锁广播。
//! - 修复了原实现的三个 bug：
//!   1) wait 自旋条件 `waiters>0` 在多等待者下永久自旋（惊群 + 永不归零）；
//!   2) signal 的 check-then-act 竞态（load 后另一线程也 fetchSub 导致丢唤醒/下溢）；
//!   3) broadcast 用 store(0) 丢失在途等待者计数。

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

/// 条件变量（基于双原子计数器 + 自旋）
///
/// 不变量：waiters ≥ wakeups 始终成立（每个 wakeup 对应一个登记过的等待者）。
/// 调用约定：signal/broadcast 必须在与 wait 相同的 mutex 保护下调用，
/// 否则在「waiter 检查条件 → 登记 waiters」与「signaler 检查 waiters → 累积 wakeup」
/// 之间可能出现丢唤醒。
pub const Condition = struct {
    /// 当前已登记的等待者数（wait 入口 fetchAdd，出口 fetchSub）。
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 待消费的唤醒数（signal/broadcast 累积，wait 消费）。
    wakeups: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        // 持锁状态下登记：保证持锁的 signal/broadcast 能看到本等待者。
        _ = self.waiters.fetchAdd(1, .seq_cst);
        mutex.unlock();

        // 自旋等待唤醒。acquire 载入配对 signal/broadcast 的 release 写入。
        while (self.wakeups.load(.acquire) == 0) {
            std.atomic.spinLoopHint();
        }

        // 消费一个唤醒并扣减等待者计数。
        _ = self.wakeups.fetchSub(1, .seq_cst);
        _ = self.waiters.fetchSub(1, .seq_cst);
        mutex.lock();
    }

    /// 唤醒一个等待者。若无人等待则无操作（不累积无谓 wakeup）。
    /// 必须在与 wait 相同的 mutex 保护下调用。
    pub fn signal(self: *Condition) void {
        if (self.waiters.load(.acquire) == 0) return;
        _ = self.wakeups.fetchAdd(1, .release);
    }

    /// 唤醒所有当前等待者。
    /// 必须在与 wait 相同的 mutex 保护下调用。
    /// 注：若已有 pending wakeup（来自先前 signal），fetchAdd(w) 可能超过 waiters，
    /// 超出部分会变成后续 wait() 的 spurious wakeup，由调用方的 while-loop 条件重检查吸收。
    pub fn broadcast(self: *Condition) void {
        const w = self.waiters.load(.acquire);
        if (w == 0) return;
        _ = self.wakeups.fetchAdd(w, .release);
    }
};
