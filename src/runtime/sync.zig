//! 同步原语实现（跨平台，纯 Zig，无 OS 专有 API）
//!
//! 设计要点：
//! - Mutex：三段式自适应自旋（密集 spin → 退避 spin → OS yield），
//!   避免高竞争下的总线锁风暴，同时保持低竞争下的极低延迟。
//!   单线程模式（single_threaded=true）下所有 lock/unlock 为 no-op。
//! - Condition：双原子量（waiters + wakeups）模型 + 分层自旋等待。
//!   wait() 在持锁状态下登记 waiters，释放锁后分层等待 wakeups>0。
//!   调用方必须持锁调用 signal/broadcast（与 wait 持锁登记配对），否则会丢唤醒。
//!
//! 修复历史：
//!   1) wait 自旋条件 `waiters>0` 在多等待者下永久自旋（惊群 + 永不归零）；
//!   2) signal 的 check-then-act 竞态（load 后另一线程也 fetchSub 导致丢唤醒/下溢）；
//!   3) broadcast 用 store(0) 丢失在途等待者计数。

const std = @import("std");

// ============================================================
// 自适应自旋参数
// ============================================================

/// 密集自旋阶段：纯 spinLoopHint（PAUSE/YIELD 指令），不涉及 OS 调度。
/// 短临界区（slab class lock、channel mutex）通常在此阶段内拿到锁。
const SPIN_DENSE: u32 = 64;

/// 退避自旋阶段：每轮增加 spinLoopHint 次数（指数退避，上限 BACKOFF_MAX）。
/// 让出流水线资源，减少 cmpxchg 总线锁争用。
const SPIN_BACKOFF: u32 = 64;
const BACKOFF_MAX: u32 = 64;

/// yield 阶段：每轮调用 std.Thread.yield 让出 CPU 时间片。
/// 用于长临界区或高竞争场景，避免空转浪费 CPU。
const YIELD_THRESHOLD: u32 = SPIN_DENSE + SPIN_BACKOFF;

// ============================================================
// Mutex — 自适应自旋锁
// ============================================================

pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;

    /// 阻塞获取锁。快速路径无 cmpxchg 竞争；慢速路径走 noinline 自适应自旋。
    /// 调用方若已知 single_threaded，应跳过此方法直接访问数据（如 SlabAllocator.lockClass）。
    pub inline fn lock(self: *Mutex) void {
        // 快速路径：无竞争直接 cmpxchg 成功（绝大多数命中此路径）
        if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic)) |_| {} else return;
        // 慢速路径：noinline 避免膨胀调用方代码
        self.lockSlow();
    }

    /// 慢速路径：三段式自适应自旋（密集 spin → 退避 spin → OS yield）。
    /// 分离为 noinline 函数，避免 lock 被内联后膨胀调用方（dispatch 循环）。
    fn lockSlow(self: *Mutex) void {
        var attempts: u32 = 0;
        var backoff: u32 = 1;
        while (true) {
            // 先观察是否已释放（普通 load，不触发总线锁）
            // 配对 unlock 的 store(.release)
            if (self.state.load(.acquire) == UNLOCKED) {
                if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic)) |_| {} else return;
            }

            attempts += 1;

            if (attempts <= SPIN_DENSE) {
                // 阶段 1：密集自旋（极短延迟）
                std.atomic.spinLoopHint();
            } else if (attempts <= YIELD_THRESHOLD) {
                // 阶段 2：指数退避自旋（减少总线锁风暴）
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, BACKOFF_MAX);
            } else {
                // 阶段 3：OS yield（让出 CPU 时间片）
                // 长临界区或高竞争，避免空转浪费 CPU
                std.Thread.yield() catch {};
                // 重置退避以适应下次低竞争期
                backoff = 1;
                attempts = YIELD_THRESHOLD;
            }
        }
    }

    /// 释放锁。
    pub inline fn unlock(self: *Mutex) void {
        self.state.store(UNLOCKED, .release);
    }

    /// 非阻塞尝试获取锁。成功返回 true，已被占用返回 false。
    pub inline fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }

    /// 非阻塞尝试获取锁（弱版本，允许伪失败）。适合在自旋循环内使用。
    pub inline fn tryLockWeak(self: *Mutex) bool {
        return self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

// ============================================================
// Condition — 条件变量（双原子计数器 + 分层自旋）
// ============================================================

pub const Condition = struct {
    /// 当前已登记的等待者数（wait 入口 fetchAdd，出口 fetchSub）。
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 待消费的唤醒数（signal/broadcast 累积，wait 消费）。
    wakeups: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 等待唤醒。调用方必须持有 mutex。
    /// 不变量：waiters ≥ wakeups 始终成立。
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        // 持锁状态下登记：保证持锁的 signal/broadcast 能看到本等待者。
        _ = self.waiters.fetchAdd(1, .seq_cst);
        mutex.unlock();

        // 分层自旋等待唤醒。acquire 载入配对 signal/broadcast 的 release 写入。
        var attempts: u32 = 0;
        var backoff: u32 = 1;
        while (self.wakeups.load(.acquire) == 0) {
            attempts += 1;

            if (attempts <= SPIN_DENSE) {
                // 阶段 1：密集自旋（短等待场景，纳秒级延迟）
                std.atomic.spinLoopHint();
            } else if (attempts <= YIELD_THRESHOLD) {
                // 阶段 2：指数退避（中等等待，减少争用）
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, BACKOFF_MAX);
            } else {
                // 阶段 3：OS yield（长等待，让出 CPU）
                std.Thread.yield() catch {};
                backoff = 1;
                attempts = YIELD_THRESHOLD;
            }
        }

        // 消费一个唤醒并扣减等待者计数。
        _ = self.wakeups.fetchSub(1, .seq_cst);
        _ = self.waiters.fetchSub(1, .seq_cst);
        mutex.lock();
    }

    /// 带超时的等待。成功（被唤醒）返回 true，超时返回 false。
    /// 超时由 spin 计数上限控制（粗粒度，适合短超时场景）。
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

// ============================================================
// 单线程模式辅助
// ============================================================

/// 单线程模式下的空锁。所有方法为 no-op，零开销。
/// 用于 VM 主线程场景：分配器 single_threaded=true 时，
/// 替代真实 Mutex 完全消除原子指令开销。
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
