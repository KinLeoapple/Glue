//! 运行时同步原语模块。
//!
//! 提供基于自旋退避策略的互斥锁（`Mutex`）、条件变量（`Condition`）
//! 以及单线程场景下使用的空互斥锁（`NullMutex`）。
//! 所有原语均不依赖操作系统 futex，采用自旋 + 退避 + 让步的三段式策略，
//! 适用于临界区短小的运行时内部场景。

const std = @import("std");

// 自旋阶段参数：在进入退避前进行密集自旋的次数。
const SPIN_DENSE: u32 = 64;

// 退避阶段参数：退避阶段的最大尝试次数。
const SPIN_BACKOFF: u32 = 64;

// 退避指数增长的上限，防止退避循环过长。
const BACKOFF_MAX: u32 = 64;

// 超过该阈值后切换为线程让步（yield），避免空转浪费 CPU。
const YIELD_THRESHOLD: u32 = SPIN_DENSE + SPIN_BACKOFF;

/// 基于原子比较交换的自旋互斥锁。
///
/// 采用三段式等待策略：
/// 1. 快速路径：单次 CAS 尝试获取锁。
/// 2. 密集自旋：少量 `spinLoopHint` 自旋等待。
/// 3. 指数退避：逐步增加自旋次数。
/// 4. 线程让步：长时间无法获取时调用 `Thread.yield`。
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;

    /// 获取锁。快速路径尝试一次 CAS，失败后进入慢速自旋路径。
    pub inline fn lock(self: *Mutex) void {
        if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic)) |_| {} else return;
        self.lockSlow();
    }

    // 慢速获取路径：三段式自旋退避循环。
    fn lockSlow(self: *Mutex) void {
        var attempts: u32 = 0;
        var backoff: u32 = 1;
        while (true) {
            // 观察锁状态，尝试在空闲时获取。
            if (self.state.load(.acquire) == UNLOCKED) {
                if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic)) |_| {} else return;
            }
            attempts += 1;
            if (attempts <= SPIN_DENSE) {
                // 阶段一：密集自旋，单次 CPU 提示。
                std.atomic.spinLoopHint();
            } else if (attempts <= YIELD_THRESHOLD) {
                // 阶段二：指数退避，逐步增加自旋次数。
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, BACKOFF_MAX);
            } else {
                // 阶段三：让出线程调度，避免长时间占用 CPU。
                std.Thread.yield() catch {};
                backoff = 1;
                attempts = YIELD_THRESHOLD;
            }
        }
    }

    /// 释放锁。使用 release 序保证临界区内的写入对其他线程可见。
    pub inline fn unlock(self: *Mutex) void {
        self.state.store(UNLOCKED, .release);
    }

    /// 尝试获取锁，成功返回 true，失败立即返回 false。
    pub inline fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }

    /// 使用弱 CAS 尝试获取锁，可能在 CAS 本可成功时偶发失败。
    pub inline fn tryLockWeak(self: *Mutex) bool {
        return self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

/// 基于自旋的条件变量。
///
/// 通过 `waiters`/`wakeups` 两个计数器实现等待与唤醒，
/// 不依赖操作系统条件变量，采用与 `Mutex` 相同的三段式退避策略。
pub const Condition = struct {
    // 当前等待该条件的线程数。
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // 累积的唤醒次数，等待者消费后递减。
    wakeups: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 等待条件被唤醒。调用前必须持有 `mutex`，返回前会重新获取。
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        mutex.unlock();

        // 三段式自旋等待唤醒计数出现。
        var attempts: u32 = 0;
        var backoff: u32 = 1;
        while (self.wakeups.load(.acquire) == 0) {
            attempts += 1;
            if (attempts <= SPIN_DENSE) {
                std.atomic.spinLoopHint();
            } else if (attempts <= YIELD_THRESHOLD) {
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, BACKOFF_MAX);
            } else {
                std.Thread.yield() catch {};
                backoff = 1;
                attempts = YIELD_THRESHOLD;
            }
        }
        // 消费一次唤醒，退出等待。
        _ = self.wakeups.fetchSub(1, .seq_cst);
        _ = self.waiters.fetchSub(1, .seq_cst);
        mutex.lock();
    }

    /// 限定最大自旋次数的等待，超时返回 false，被唤醒返回 true。
    pub fn waitFor(self: *Condition, mutex: *Mutex, max_spins: u32) bool {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        mutex.unlock();
        var attempts: u32 = 0;
        var backoff: u32 = 1;
        const result = blk: while (attempts < max_spins) {
            if (self.wakeups.load(.acquire) != 0) break :blk true;
            attempts += 1;
            if (attempts <= SPIN_DENSE) {
                std.atomic.spinLoopHint();
            } else if (attempts <= YIELD_THRESHOLD) {
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, BACKOFF_MAX);
            } else {
                std.Thread.yield() catch {};
                backoff = 1;
                attempts = YIELD_THRESHOLD;
            }
        };
        if (result) {
            _ = self.wakeups.fetchSub(1, .seq_cst);
        }
        _ = self.waiters.fetchSub(1, .seq_cst);
        mutex.lock();
        return result;
    }

    /// 唤醒一个等待者。仅当存在等待者时才增加唤醒计数。
    pub fn signal(self: *Condition) void {
        if (self.waiters.load(.acquire) == 0) return;
        _ = self.wakeups.fetchAdd(1, .release);
    }

    /// 唤醒所有等待者。按当前等待者数量批量增加唤醒计数。
    pub fn broadcast(self: *Condition) void {
        const w = self.waiters.load(.acquire);
        if (w == 0) return;
        _ = self.wakeups.fetchAdd(w, .release);
    }
};

/// 空互斥锁，所有操作为空实现，用于单线程场景下替代 `Mutex` 以消除同步开销。
pub const NullMutex = struct {
    pub fn lock(self: *NullMutex) void {
        _ = self;
    }

    pub fn unlock(self: *NullMutex) void {
        _ = self;
    }

    pub fn tryLock(self: *NullMutex) bool {
        _ = self;
        return true;
    }
};
