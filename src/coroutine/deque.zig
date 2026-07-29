//! Chase-Lev work-stealing 双端队列。
//!
//! 经典 work-stealing 调度数据结构：
//! - owner 线程从 bottom 端 push/pop（LIFO，缓存友好）
//! - thief 线程从 top 端 steal（FIFO，减少与 owner 冲突）
//! - 环形缓冲区 + 原子 bottom/top
//!
//! ABA 处理：bottom/top 用 u64 索引（实际不可回绕），环形定位用 idx % capacity。
//! 容量固定（CAPACITY），溢出时 push 返回 error.QueueFull（调度器应保证就绪队列不超限）。
//!
//! 内存序：
//! - push：写 buffer 后 Release bottom（steal 线程看到 bottom 新值时 buffer 已就绪）
//! - pop：SeqCst fence 后读 top（保证与 steal 的 CAS 正确同步）
//! - steal：读 bottom 后读 buffer（Acquire），CAS top（SeqCst）
//!
//! 线程安全说明：
//! 标准 Chase-Lev deque 要求只有 owner 线程操作 bottom（push/pop）。
//! 但本调度器中，async（主线程）和 enqueueFrame（任意 worker）都会调用 push，
//! 而 owner worker 调用 pop。因此 push 和 pop 可能跨线程并发，破坏 bottom 单写者不变量。
//! 使用 push_lock 互斥锁序列化 push/pop 对 bottom 的修改，steal 保持无锁（仅 CAS top）。

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const Mutex = @import("value").concurrent.Mutex;

/// Chase-Lev deque 的固定容量（就绪队列上限）。
/// 协程就绪队列不会无限增长（挂起的协程在 registry 而非就绪队列），
/// 4096 足够；溢出由调用方处理（可 async 到全局溢出队列）。
pub const CAPACITY: usize = 4096;

/// 队列状态
pub const DequeError = error{QueueFull};

/// Chase-Lev work-stealing deque
///
/// 内存布局：环形缓冲区 + 原子 bottom/top + push/pop 互斥锁
/// - bottom：owner 端索引（push/pop 操作），单调递增
/// - top：thief 端索引（steal 操作），单调递增
/// - 元素定位：idx % CAPACITY
/// - push_lock：序列化跨线程 push/pop 对 bottom 的修改
pub const WorkStealingDeque = struct {
    /// 环形缓冲区（切片形式，便于 backing.free 归还）
    buffer: []?*CoroutineFrame,
    backing: std.mem.Allocator,
    /// bottom/top 用有符号整数，避免空队列 pop 时 b-1 下溢
    /// （Chase-Lev 算法要求 pop 先减 bottom 再判空，b=0 时 b-1=-1，t>-1 判空成立）
    bottom: std.atomic.Value(i64),
    top: std.atomic.Value(i64),
    /// 序列化 push/pop：跨线程 push（asyncLaunch/enqueueFrame）与 owner pop 并发时，
    /// 防止 pop 读到 stale bottom 后覆盖 push 的 bottom 写入，导致帧丢失。
    /// steal 不需要此锁（仅 CAS top + 原子读 bottom）。
    push_lock: Mutex = .{},

    /// 创建 deque（分配环形缓冲区）
    pub fn init(backing: std.mem.Allocator) !WorkStealingDeque {
        const buf = try backing.alloc(?*CoroutineFrame, CAPACITY);
        @memset(buf, null);
        return .{
            .buffer = buf,
            .backing = backing,
            .bottom = std.atomic.Value(i64).init(0),
            .top = std.atomic.Value(i64).init(0),
        };
    }

    /// 释放环形缓冲区
    pub fn deinit(self: *WorkStealingDeque) void {
        self.backing.free(self.buffer);
    }

    /// push 到 bottom 端（LIFO）。
    /// 可跨线程调用（asyncLaunch/enqueueFrame），push_lock 序列化与 pop 的并发。
    pub fn push(self: *WorkStealingDeque, frame: *CoroutineFrame) DequeError!void {
        self.push_lock.lock();
        defer self.push_lock.unlock();

        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);
        if (b - t >= CAPACITY) return error.QueueFull;
        // 写 buffer 后 Release bottom，steal 线程看到新 bottom 时 buffer 已就绪
        const idx: usize = @intCast(@mod(b, @as(i64, CAPACITY)));
        self.buffer[idx] = frame;
        self.bottom.store(b + 1, .release);
    }

    /// 从 bottom 端 pop（LIFO）。返回 null 表示队列空。
    /// owner 线程调用，push_lock 序列化与跨线程 push 的并发。
    pub fn pop(self: *WorkStealingDeque) ?*CoroutineFrame {
        self.push_lock.lock();
        defer self.push_lock.unlock();

        const b = self.bottom.load(.monotonic);
        // 先减 bottom（预占），与 steal 竞争
        // 有符号 i64 保证 b=0 时 b-1=-1 不下溢
        self.bottom.store(b - 1, .monotonic);
        // SeqCst 序保证与 steal 的 CAS 正确同步（替代 @fence(.seq_cst)）
        const t = self.top.load(.seq_cst);

        if (t > b - 1) {
            // 队列空：恢复 bottom 到 top（避免 bottom 漂移）
            self.bottom.store(t, .release);
            return null;
        }
        const idx: usize = @intCast(@mod(b - 1, @as(i64, CAPACITY)));
        if (t < b - 1) {
            // 多于 1 个元素：无竞争，直接取
            const frame = self.buffer[idx].?;
            self.buffer[idx] = null;
            return frame;
        }
        // t == b - 1：最后一个元素，与 steal 竞争
        const frame = self.buffer[idx].?;
        // CAS top：成功则独占，失败则被 steal 偷走
        if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null) {
            self.buffer[idx] = null;
            // 成功获取最后一个元素后恢复 bottom 到 t+1（与已推进的 top 一致），
            // 否则 bottom 停留在 t 而 top 已为 t+1，下次 push 使 bottom=t+1=top，
            // 队列被误判为空，元素永久丢失。
            self.bottom.store(t + 1, .release);
            return frame;
        } else {
            // 被 steal 偷走，恢复 bottom
            self.bottom.store(t + 1, .release);
            return null;
        }
    }

    /// thief 线程从 top 端 steal（FIFO）。返回 null 表示队列空或竞争失败。
    /// 竞争失败时调用方可重试或选其他 victim。
    /// 无锁：仅使用原子操作（读 bottom + CAS top），与 push/pop 通过原子 bottom/top 同步。
    pub fn steal(self: *WorkStealingDeque) ?*CoroutineFrame {
        // SeqCst 序保证读 top 后读 bottom 的顺序（替代 @fence(.seq_cst)）
        const t = self.top.load(.seq_cst);
        const b = self.bottom.load(.seq_cst);
        if (t >= b) return null; // 空
        const idx: usize = @intCast(@mod(t, @as(i64, CAPACITY)));
        // Read as optional — pop() may have nullified this slot concurrently.
        // Let CAS validate ownership; only return the value if CAS succeeds.
        const frame = self.buffer[idx]; // ?*CoroutineFrame, no .?
        if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null) {
            return frame orelse null;
        }
        return null;
    }

    /// 当前元素数量（近似值，跨线程读取有竞态，仅供监控/profiling）
    pub fn size(self: *const WorkStealingDeque) u64 {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic);
        return if (b > t) @intCast(b - t) else 0;
    }

    /// 是否为空（近似值）
    pub fn isEmpty(self: *const WorkStealingDeque) bool {
        return self.size() == 0;
    }
};
