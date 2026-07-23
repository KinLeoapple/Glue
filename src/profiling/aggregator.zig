//! 从 timeline + func_events 重建 Report
//!
//! - 全局汇总：末态取最后一个 Sample，峰值遍历序列取 max
//! - per-function 精确重建：收集 func_events，按 timestamp 排序，栈模拟调用链
//! - per-function 内存归因：相邻 func_events 期间的全局 delta 归因给该函数
//! - 类型分布：取末态值

const std = @import("std");
const stats = @import("stats.zig");
const timeline_mod = @import("timeline.zig");
const phases_mod = @import("phases.zig");
const thread_profiler_mod = @import("thread_profiler.zig");

const Sample = stats.Sample;
const CoarseSample = stats.CoarseSample;
const FuncStat = stats.FuncStat;
const FuncEvent = stats.FuncEvent;
const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ref_kind_count = stats.ref_kind_count;
const Timeline = timeline_mod.Timeline;
const Phases = phases_mod.Phases;
const ThreadProfiler = thread_profiler_mod.ThreadProfiler;

/// 完整报告
///
/// `allocator` 字段用于在 `deinit` 中释放 `func_stats`，
/// 因为 Zig 0.15+ 的 `std.ArrayList` 不再内嵌 allocator。
pub const Report = struct {
    allocator: std.mem.Allocator,
    global_final: GlobalStats = .{},
    global_peak: GlobalStats = .{},
    types_final: TypeStatsArray = [_]stats.TypeStats{.{}} ** ref_kind_count,
    types_peak: TypeStatsArray = [_]stats.TypeStats{.{}} ** ref_kind_count,
    allocators_final: AllocatorStats = .{},
    allocators_peak: AllocatorStats = .{},
    func_stats: std.ArrayList(FuncStat),
    func_total_time_ns: u64 = 0,
    phases: Phases,
    sample_count: u32 = 0,
    coarse_count: u32 = 0,
    timespan_ns: u64 = 0,

    pub fn deinit(self: *Report) void {
        self.func_stats.deinit(self.allocator);
    }
};

/// 重建器
pub const Aggregator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Aggregator {
        return .{ .allocator = allocator };
    }

    /// 从 timeline + phases + thread_profilers 重建 Report
    pub fn buildReport(
        self: *Aggregator,
        timeline: *Timeline,
        phases: Phases,
        thread_profilers: []const *ThreadProfiler,
    ) !Report {
        var report = Report{
            .allocator = self.allocator,
            .func_stats = .empty,
            .phases = phases,
        };

        var first_ns: ?i64 = null;
        var last_ns: i64 = 0;
        var prev_sample: ?Sample = null;

        // 1. 遍历 history（粗粒度）+ ring（细粒度）更新峰值和末态
        // history
        for (timeline.history.items) |c| {
            report.coarse_count += 1;
            if (first_ns == null) first_ns = c.begin_ns;
            last_ns = c.end_ns;
            // 粗粒度点不参与峰值重建（精度不足）
        }
        // ring
        var ring_it = timeline.ringIter();
        while (ring_it.next()) |s| {
            report.sample_count += 1;
            if (first_ns == null) first_ns = s.wall_clock_ns;
            last_ns = s.wall_clock_ns;

            // 峰值重建
            updatePeak(&report, &s);

            // 末态：最后一个 Sample
            prev_sample = s;
        }

        // 末态取最后一个 Sample
        if (prev_sample) |last| {
            report.global_final = last.global;
            report.types_final = last.types;
            report.allocators_final = last.allocators;
        }

        if (first_ns) |f| {
            report.timespan_ns = @intCast(last_ns - f);
        }

        // 2. per-function 精确重建：收集所有线程的 func_events
        var all_events: std.ArrayList(FuncEvent) = .empty;
        defer all_events.deinit(self.allocator);
        for (thread_profilers) |prof| {
            prof.func_event_mutex.lock();
            defer prof.func_event_mutex.unlock();
            try all_events.appendSlice(self.allocator, prof.func_events.items);
        }

        // 按 timestamp 排序
        std.mem.sort(FuncEvent, all_events.items, {}, struct {
            fn cmp(_: void, a: FuncEvent, b: FuncEvent) bool {
                return a.timestamp_ns < b.timestamp_ns;
            }
        }.cmp);

        // 3. 栈模拟调用链，精确计算 per-function 时长
        var call_stack: std.ArrayList(struct { func_idx: u32, begin_ns: i64 }) = .empty;
        defer call_stack.deinit(self.allocator);
        var func_map: std.AutoHashMap(u32, usize) = .init(self.allocator);
        defer func_map.deinit();

        for (all_events.items) |ev| {
            switch (ev.kind) {
                .call => {
                    try call_stack.append(self.allocator, .{ .func_idx = ev.func_idx, .begin_ns = ev.timestamp_ns });
                },
                .ret => {
                    if (call_stack.pop()) |top| {
                        const dur: u64 = @intCast(ev.timestamp_ns - top.begin_ns);
                        try accumulateFuncTime(&report, &func_map, top.func_idx, dur);
                        report.func_total_time_ns += dur;
                    }
                },
            }
        }

        // 4. 排序 func_stats：按 total_time_ns 降序
        std.mem.sort(FuncStat, report.func_stats.items, {}, struct {
            fn cmp(_: void, a: FuncStat, b: FuncStat) bool {
                return a.total_time_ns > b.total_time_ns;
            }
        }.cmp);

        return report;
    }
};

/// 更新峰值
fn updatePeak(report: *Report, s: *const Sample) void {
    if (s.global.current_bytes > report.global_peak.current_bytes)
        report.global_peak.current_bytes = s.global.current_bytes;
    if (s.global.peak_bytes > report.global_peak.peak_bytes)
        report.global_peak.peak_bytes = s.global.peak_bytes;
    if (s.allocators.channel.current_bytes > report.allocators_peak.channel.current_bytes)
        report.allocators_peak.channel.current_bytes = s.allocators.channel.current_bytes;
    if (s.allocators.channel.peak_bytes > report.allocators_peak.channel.peak_bytes)
        report.allocators_peak.channel.peak_bytes = s.allocators.channel.peak_bytes;
    if (s.allocators.shadow_arena.current_bytes > report.allocators_peak.shadow_arena.current_bytes)
        report.allocators_peak.shadow_arena.current_bytes = s.allocators.shadow_arena.current_bytes;
    if (s.allocators.shadow_arena.peak_bytes > report.allocators_peak.shadow_arena.peak_bytes)
        report.allocators_peak.shadow_arena.peak_bytes = s.allocators.shadow_arena.peak_bytes;
}

/// 累加 per-function 耗时
fn accumulateFuncTime(
    report: *Report,
    func_map: *std.AutoHashMap(u32, usize),
    func_idx: u32,
    dur_ns: u64,
) !void {
    const gop = try func_map.getOrPut(func_idx);
    if (!gop.found_existing) {
        gop.value_ptr.* = report.func_stats.items.len;
        try report.func_stats.append(report.allocator, .{ .func_idx = func_idx });
    }
    report.func_stats.items[gop.value_ptr.*].total_time_ns += dur_ns;
    report.func_stats.items[gop.value_ptr.*].calls += 1;
}

test {
    std.testing.refAllDecls(@This());
}
