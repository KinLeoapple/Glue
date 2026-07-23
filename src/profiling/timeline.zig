//! 时间序列存储：RingBuffer + 分段累积
//!
//! - RING_SIZE = 10000 点细粒度采样
//! - ring 写满时聚合旧数据为 1 个 CoarseSample 存入 history
//! - history 上限 HISTORY_MAX = 10000，超限时二次聚合

const std = @import("std");
const stats = @import("stats.zig");

const Sample = stats.Sample;
const CoarseSample = stats.CoarseSample;
const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ref_kind_count = stats.ref_kind_count;

/// RingBuffer 容量
pub const RING_SIZE: usize = 10000;
/// history 上限
pub const HISTORY_MAX: usize = 10000;
/// history 超限时二次聚合的批量大小
const COARSE_BATCH: usize = 10;

/// 时间序列存储
///
/// `ring` 为堆分配的指针，避免 [RING_SIZE]Sample（约 11 MB）在栈上
/// 导致栈溢出。`init` 分配，`deinit` 释放。
pub const Timeline = struct {
    ring: *[RING_SIZE]Sample,
    ring_head: u64 = 0, // 下一个写入位置（单调递增）
    history: std.ArrayList(CoarseSample),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Timeline {
        const ring = try allocator.create([RING_SIZE]Sample);
        return .{ .ring = ring, .history = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Timeline) void {
        self.history.deinit(self.allocator);
        self.allocator.destroy(self.ring);
    }

    /// 写入一个采样点
    pub fn push(self: *Timeline, sample: Sample) !void {
        // ring 写满一轮时，先聚合最旧数据为 CoarseSample
        if (self.ring_head > 0 and self.ring_head % RING_SIZE == 0) {
            try self.snapshotOldestRing();
        }
        const idx = self.ring_head % RING_SIZE;
        self.ring[idx] = sample;
        self.ring_head += 1;
    }

    /// 将当前 ring 中的数据聚合为 1 个 CoarseSample 存入 history
    fn snapshotOldestRing(self: *Timeline) !void {
        if (self.ring_head < RING_SIZE) return;

        // ring 中最旧数据起始位置
        const start_idx = self.ring_head % RING_SIZE;
        const first = self.ring[start_idx];
        const last_idx = if (start_idx == 0) RING_SIZE - 1 else start_idx - 1;
        const last = self.ring[last_idx];

        // 统计 func_idx 众数（占时最多的函数）
        var func_dur: std.AutoHashMap(u32, u64) = .init(self.allocator);
        defer func_dur.deinit();
        var prev_ns = first.wall_clock_ns;
        var i: usize = 0;
        while (i < RING_SIZE) : (i += 1) {
            const idx = (start_idx + i) % RING_SIZE;
            const s = self.ring[idx];
            const dur: u64 = @intCast(s.wall_clock_ns - prev_ns);
            const gop = try func_dur.getOrPut(s.func_idx);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += dur;
            prev_ns = s.wall_clock_ns;
        }
        var mode_func: u32 = first.func_idx;
        var mode_dur: u64 = 0;
        var it = func_dur.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* > mode_dur) {
                mode_dur = kv.value_ptr.*;
                mode_func = kv.key_ptr.*;
            }
        }

        // history 超上限时二次聚合
        if (self.history.items.len >= HISTORY_MAX) {
            try self.coalesceHistory();
        }

        try self.history.append(self.allocator, .{
            .begin_ns = first.wall_clock_ns,
            .end_ns = last.wall_clock_ns,
            .thread_id = first.thread_id,
            .func_idx = mode_func,
            .global = last.global,
            .types = last.types,
            .allocators = last.allocators,
            .sample_count = @intCast(RING_SIZE),
        });
    }

    /// history 超上限时，将最旧 COARSE_BATCH 个聚合为 1 个
    fn coalesceHistory(self: *Timeline) !void {
        if (self.history.items.len < COARSE_BATCH) return;

        const first = self.history.items[0];
        const last = self.history.items[COARSE_BATCH - 1];
        var total_samples: u32 = 0;
        var i: usize = 0;
        while (i < COARSE_BATCH) : (i += 1) {
            total_samples += self.history.items[i].sample_count;
        }

        // 移除前 COARSE_BATCH 个，插入聚合后的 1 个
        var k: usize = 0;
        while (k < COARSE_BATCH) : (k += 1) {
            _ = self.history.orderedRemove(0);
        }
        try self.history.insert(self.allocator, 0, .{
            .begin_ns = first.begin_ns,
            .end_ns = last.end_ns,
            .thread_id = first.thread_id,
            .func_idx = last.func_idx, // 取末态
            .global = last.global,
            .types = last.types,
            .allocators = last.allocators,
            .sample_count = total_samples,
        });
    }

    /// 当前 ring 中的有效采样点数
    pub fn ringCount(self: *const Timeline) usize {
        return @intCast(@min(self.ring_head, RING_SIZE));
    }

    /// history 中的 CoarseSample 数
    pub fn historyCount(self: *const Timeline) usize {
        return self.history.items.len;
    }

    /// 遍历 ring 中的采样点（从最旧到最新）
    pub fn ringIter(self: *const Timeline) RingIter {
        const count = self.ringCount();
        const start = if (self.ring_head >= RING_SIZE) (self.ring_head % RING_SIZE) else 0;
        return .{ .timeline = self, .idx = 0, .count = count, .start = start };
    }

    pub const RingIter = struct {
        timeline: *const Timeline,
        idx: usize,
        count: usize,
        start: usize,

        pub fn next(self: *RingIter) ?Sample {
            if (self.idx >= self.count) return null;
            const ring_idx = (self.start + self.idx) % RING_SIZE;
            self.idx += 1;
            return self.timeline.ring[ring_idx];
        }
    };
};

test {
    std.testing.refAllDecls(@This());
}

test "push 和 ringCount" {
    var tl = try Timeline.init(std.testing.allocator);
    defer tl.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try tl.push(.{
            .wall_clock_ns = @intCast(i),
            .thread_id = 0,
            .func_idx = i,
            .global = .{},
            .types = [_]stats.TypeStats{.{}} ** ref_kind_count,
            .allocators = .{},
        });
    }
    try std.testing.expectEqual(@as(usize, 5), tl.ringCount());
    try std.testing.expectEqual(@as(usize, 0), tl.historyCount());
}

test "ring 写满触发分段累积" {
    var tl = try Timeline.init(std.testing.allocator);
    defer tl.deinit();

    var i: u32 = 0;
    while (i < RING_SIZE + 5) : (i += 1) {
        try tl.push(.{
            .wall_clock_ns = @intCast(i),
            .thread_id = 0,
            .func_idx = 0,
            .global = .{},
            .types = [_]stats.TypeStats{.{}} ** ref_kind_count,
            .allocators = .{},
        });
    }
    // ring 写满一轮后，history 应有 1 个 CoarseSample
    try std.testing.expectEqual(@as(usize, 1), tl.historyCount());
    try std.testing.expectEqual(@as(usize, 5), tl.ringCount());
}
