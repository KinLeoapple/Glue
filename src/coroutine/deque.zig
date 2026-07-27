//! Chase-Lev 无锁 work-stealing 双端队列。
//!
//! 经典 work-stealing 调度数据结构：
//! - owner 线程从 bottom 端 push/pop（LIFO，缓存友好）
//! - thief 线程从 top 端 steal（FIFO，减少与 owner 冲突）
//! - 环形缓冲区 + 原子 bottom/top，无锁
//!
//! ABA 处理：bottom/top 用 u64 索引（实际不可回绕），环形定位用 idx % capacity。
//! 容量固定（CAPACITY），溢出时 push 返回 error.QueueFull（调度器应保证就绪队列不超限）。
//!
//! 内存序：
//! - push：写 buffer 后 Release bottom（steal 线程看到 bottom 新值时 buffer 已就绪）
//! - pop：SeqCst fence 后读 top（保证与 steal 的 CAS 正确同步）
//! - steal：读 bottom 后读 buffer（Acquire），CAS top（SeqCst）

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;

/// Chase-Lev deque 的固定容量（就绪队列上限）。
/// 协程就绪队列不会无限增长（挂起的协程在 registry 而非就绪队列），
/// 4096 足够；溢出由调用方处理（可 spawn 到全局溢出队列）。
pub const CAPACITY: usize = 4096;

/// 队列状态
pub const DequeError = error{QueueFull};

/// Chase-Lev work-stealing deque
///
/// 内存布局：环形缓冲区 + 原子 bottom/top
/// - bottom：owner 端索引（push/pop 操作），单调递增
/// - top：thief 端索引（steal 操作），单调递增
/// - 元素定位：idx % CAPACITY
pub const WorkStealingDeque = struct {
    /// 环形缓冲区（切片形式，便于 backing.free 归还）
    buffer: []?*CoroutineFrame,
    backing: std.mem.Allocator,
    /// bottom/top 用有符号整数，避免空队列 pop 时 b-1 下溢
    /// （Chase-Lev 算法要求 pop 先减 bottom 再判空，b=0 时 b-1=-1，t>-1 判空成立）
    bottom: std.atomic.Value(i64),
    top: std.atomic.Value(i64),

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

    /// owner 线程 push 到 bottom 端（LIFO）
    pub fn push(self: *WorkStealingDeque, frame: *CoroutineFrame) DequeError!void {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);
        if (b - t >= CAPACITY) return error.QueueFull;
        // 写 buffer 后 Release bottom，steal 线程看到新 bottom 时 buffer 已就绪
        const idx: usize = @intCast(@mod(b, @as(i64, CAPACITY)));
        self.buffer[idx] = frame;
        self.bottom.store(b + 1, .release);
    }

    /// owner 线程从 bottom 端 pop（LIFO）。返回 null 表示队列空。
    pub fn pop(self: *WorkStealingDeque) ?*CoroutineFrame {
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
            return frame;
        } else {
            // 被 steal 偷走，恢复 bottom
            self.bottom.store(t + 1, .release);
            return null;
        }
    }

    /// thief 线程从 top 端 steal（FIFO）。返回 null 表示队列空或竞争失败。
    /// 竞争失败时调用方可重试或选其他 victim。
    pub fn steal(self: *WorkStealingDeque) ?*CoroutineFrame {
        // SeqCst 序保证读 top 后读 bottom 的顺序（替代 @fence(.seq_cst)）
        const t = self.top.load(.seq_cst);
        const b = self.bottom.load(.seq_cst);
        if (t >= b) return null; // 空
        const idx: usize = @intCast(@mod(t, @as(i64, CAPACITY)));
        const frame = self.buffer[idx].?;
        // CAS top：成功则偷走，失败则竞争失败（调用方决定重试）
        // 偷取成功后，buffer 槽位可被复用（下次 push 覆盖）
        if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null) {
            return frame;
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

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const ir_mod = @import("ir");
const FrameLayout = ir_mod.FrameLayout;

fn emptyLayout() FrameLayout {
    return .{
        .total_size = 0,
        .param_region = .{ .start = 0, .size = 0 },
        .local_region = .{ .start = 0, .size = 0 },
        .temp_region = .{ .start = 0, .size = 0 },
    };
}

fn makeFrame(id: u16) CoroutineFrame {
    return CoroutineFrame.initFixed(id, emptyLayout(), &[_]u16{});
}

test "WorkStealingDeque 单线程 push/pop LIFO" {
    var deque = try WorkStealingDeque.init(testing.allocator);
    defer deque.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);
    var f3 = makeFrame(3);

    // LIFO 顺序
    try deque.push(&f1);
    try deque.push(&f2);
    try deque.push(&f3);

    try testing.expectEqual(&f3, deque.pop().?);
    try testing.expectEqual(&f2, deque.pop().?);
    try testing.expectEqual(&f1, deque.pop().?);
    try testing.expectEqual(@as(?*CoroutineFrame, null), deque.pop());
}

test "WorkStealingDeque steal FIFO" {
    var deque = try WorkStealingDeque.init(testing.allocator);
    defer deque.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);
    var f3 = makeFrame(3);

    try deque.push(&f1);
    try deque.push(&f2);
    try deque.push(&f3);

    // steal 从 top 端取（FIFO）
    try testing.expectEqual(&f1, deque.steal().?);
    try testing.expectEqual(&f2, deque.steal().?);

    // 剩余 f3 由 owner pop
    try testing.expectEqual(&f3, deque.pop().?);
    try testing.expectEqual(@as(?*CoroutineFrame, null), deque.pop());
}

test "WorkStealingDeque 空队列 pop/steal 返回 null" {
    var deque = try WorkStealingDeque.init(testing.allocator);
    defer deque.deinit();

    try testing.expectEqual(@as(?*CoroutineFrame, null), deque.pop());
    try testing.expectEqual(@as(?*CoroutineFrame, null), deque.steal());
    try testing.expect(deque.isEmpty());
}

test "WorkStealingDeque size 近似值" {
    var deque = try WorkStealingDeque.init(testing.allocator);
    defer deque.deinit();

    var f1 = makeFrame(1);
    var f2 = makeFrame(2);

    try testing.expectEqual(@as(u64, 0), deque.size());
    try deque.push(&f1);
    try deque.push(&f2);
    try testing.expectEqual(@as(u64, 2), deque.size());
    _ = deque.pop();
    try testing.expectEqual(@as(u64, 1), deque.size());
}

test "WorkStealingDeque QueueFull 溢出" {
    var deque = try WorkStealingDeque.init(testing.allocator);
    defer deque.deinit();

    // 分配 CAPACITY 个帧（栈上无法放 4096 个，用堆）
    const frames = try testing.allocator.alloc(CoroutineFrame, CAPACITY);
    defer testing.allocator.free(frames);
    for (frames, 0..) |*f, i| f.* = makeFrame(@intCast(i));

    for (frames) |*f| try deque.push(f);
    // 下一个 push 应溢出
    var extra = makeFrame(9999);
    try testing.expectError(error.QueueFull, deque.push(&extra));
}
