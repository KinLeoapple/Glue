//! 从 timeline + thread_profilers 重建 Report
//!
//! - 全局汇总：末态取最后一个 Sample，峰值遍历序列取 max
//! - per-function 时长：直接从 ThreadProfiler.func_time/func_calls 数组读取
//!   （实时调用栈计时，无事件缓冲区限制）
//! - per-function 内存归因：从 ThreadProfiler.func_alloc 数组累加
//! - 类型分布：取末态值

const std = @import("std");
const stats = @import("stats.zig");
const timeline_mod = @import("timeline.zig");
const phases_mod = @import("phases.zig");
const thread_profiler_mod = @import("thread_profiler.zig");

const Sample = stats.Sample;
const CoarseSample = stats.CoarseSample;
const FuncStat = stats.FuncStat;
const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ref_kind_count = stats.ref_kind_count;
const MAX_TRACKED_FUNCS = stats.MAX_TRACKED_FUNCS;
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
    phases: Phases,
    sample_count: u32 = 0,
    coarse_count: u32 = 0,
    timespan_ns: u64 = 0,
    /// 函数名表（按 func_idx 索引），由调用方在 dump 前注入。
    /// 仅用于报告展示，生命周期由外部管理（不归 Report 所有）。
    func_names: ?[]const []const u8 = null,

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

        // 末态：优先直接从 ThreadProfiler 读取（权威值，补充 timeline 采样不足）
        // 程序短或采样间隔长时，ring 中末态可能滞后甚至为空
        if (thread_profilers.len > 0) {
            var gf: GlobalStats = .{};
            var tf: TypeStatsArray = [_]stats.TypeStats{.{}} ** ref_kind_count;
            var af: AllocatorStats = .{};
            readFinalFromProfilers(thread_profilers, &gf, &tf, &af);
            report.global_final = gf;
            report.types_final = tf;
            report.allocators_final = af;
            // 末态也参与峰值更新（单调递增计数器的末态 = 峰值）
            updatePeakFromStats(&report, &gf, &af);
        } else if (prev_sample) |last| {
            // 无 ThreadProfiler 时回退到 timeline 末态
            report.global_final = last.global;
            report.types_final = last.types;
            report.allocators_final = last.allocators;
        }

        if (first_ns) |f| {
            report.timespan_ns = @intCast(last_ns - f);
        }

        // 2. per-function 时长和调用计数：直接从 ThreadProfiler 数组读取
        //    func_time[fi][0] = inclusive, func_time[fi][1] = exclusive
        var func_map: std.AutoHashMap(u32, usize) = .init(self.allocator);
        defer func_map.deinit();

        for (thread_profilers) |prof| {
            for (0..MAX_TRACKED_FUNCS) |fi| {
                const inclusive = prof.func_time[fi][0];
                const exclusive = prof.func_time[fi][1];
                const calls = prof.func_calls[fi];
                const fa = prof.func_alloc[fi];
                if (inclusive == 0 and exclusive == 0 and calls == 0 and
                    fa.arena_bytes == 0 and fa.heap_bytes == 0 and
                    fa.retain_count == 0 and fa.release_count == 0) continue;

                const gop = try func_map.getOrPut(@intCast(fi));
                if (!gop.found_existing) {
                    gop.value_ptr.* = report.func_stats.items.len;
                    try report.func_stats.append(self.allocator, .{ .func_idx = @intCast(fi) });
                }
                const fs = &report.func_stats.items[gop.value_ptr.*];
                fs.inclusive_time_ns += inclusive;
                fs.exclusive_time_ns += exclusive;
                fs.calls += calls;
                fs.arena_alloc_bytes += fa.arena_bytes;
                fs.heap_alloc_bytes += fa.heap_bytes;
                fs.retain_count += fa.retain_count;
                fs.release_count += fa.release_count;
            }
        }

        // 3. 排序 func_stats：按 exclusive_time_ns 降序（exclusive 才是热点指标）
        std.mem.sort(FuncStat, report.func_stats.items, {}, struct {
            fn cmp(_: void, a: FuncStat, b: FuncStat) bool {
                return a.exclusive_time_ns > b.exclusive_time_ns;
            }
        }.cmp);

        return report;
    }
};

/// 更新峰值：对所有 GlobalStats 和 AllocatorStats 字段取单调最大值
fn updatePeak(report: *Report, s: *const Sample) void {
    // GlobalStats：所有字段取 max（单调递增计数器的峰值 = 末态值）
    inline for (@typeInfo(GlobalStats).@"struct".fields) |f| {
        const sv = @field(s.global, f.name);
        const rv = @field(report.global_peak, f.name);
        if (sv > rv) @field(report.global_peak, f.name) = sv;
    }

    // ChannelStats：所有字段取 max
    inline for (@typeInfo(@TypeOf(s.allocators.channel)).@"struct".fields) |f| {
        const sv = @field(s.allocators.channel, f.name);
        const rv = @field(report.allocators_peak.channel, f.name);
        if (sv > rv) @field(report.allocators_peak.channel, f.name) = sv;
    }

    // ObjectPoolStats：所有字段取 max
    inline for (@typeInfo(@TypeOf(s.allocators.object_pool)).@"struct".fields) |f| {
        const sv = @field(s.allocators.object_pool, f.name);
        const rv = @field(report.allocators_peak.object_pool, f.name);
        if (sv > rv) @field(report.allocators_peak.object_pool, f.name) = sv;
    }

    // ShadowArenaStats：所有字段取 max
    inline for (@typeInfo(@TypeOf(s.allocators.shadow_arena)).@"struct".fields) |f| {
        const sv = @field(s.allocators.shadow_arena, f.name);
        const rv = @field(report.allocators_peak.shadow_arena, f.name);
        if (sv > rv) @field(report.allocators_peak.shadow_arena, f.name) = sv;
    }
}

/// 从所有 ThreadProfiler 直接读取末态（seqlock 一致性，多线程累加）
/// 补充 timeline 采样不足：程序短或采样间隔长时，ring 中末态可能滞后甚至为空
fn readFinalFromProfilers(
    thread_profilers: []const *ThreadProfiler,
    global_final: *GlobalStats,
    types_final: *TypeStatsArray,
    allocators_final: *AllocatorStats,
) void {
    for (thread_profilers) |prof| {
        // seqlock 读取一致性快照
        var snap_global: GlobalStats = .{};
        var snap_types: TypeStatsArray = [_]stats.TypeStats{.{}} ** ref_kind_count;
        var snap_allocators: AllocatorStats = .{};

        var spin_count: u32 = 0;
        var ok = false;
        while (true) {
            const seq1 = prof.seq.load(.acquire);
            if (seq1 & 1 != 0) {
                std.atomic.spinLoopHint();
                spin_count += 1;
                if (spin_count > 1000) break; // 防御性跳过
                continue;
            }
            snap_global = prof.global;
            snap_types = prof.types;
            snap_allocators = prof.allocators;
            const seq2 = prof.seq.load(.acquire);
            if (seq1 == seq2) {
                ok = true;
                break;
            }
            std.atomic.spinLoopHint();
            spin_count += 1;
        }

        if (!ok) continue; // seqlock 超时，跳过此线程

        // 累加到 final（多线程聚合）
        addGlobalStats(global_final, &snap_global);
        for (0..ref_kind_count) |k| {
            addTypeStats(&types_final[k], &snap_types[k]);
        }
        addAllocatorStats(allocators_final, &snap_allocators);
    }
}

/// 从末态 GlobalStats + AllocatorStats 更新峰值（补充 timeline 采样遗漏）
fn updatePeakFromStats(report: *Report, gf: *const GlobalStats, af: *const AllocatorStats) void {
    inline for (@typeInfo(GlobalStats).@"struct".fields) |f| {
        const sv = @field(gf.*, f.name);
        const rv = @field(report.global_peak, f.name);
        if (sv > rv) @field(report.global_peak, f.name) = sv;
    }
    inline for (@typeInfo(stats.ChannelStats).@"struct".fields) |f| {
        const sv = @field(af.channel, f.name);
        const rv = @field(report.allocators_peak.channel, f.name);
        if (sv > rv) @field(report.allocators_peak.channel, f.name) = sv;
    }
    inline for (@typeInfo(stats.ObjectPoolStats).@"struct".fields) |f| {
        const sv = @field(af.object_pool, f.name);
        const rv = @field(report.allocators_peak.object_pool, f.name);
        if (sv > rv) @field(report.allocators_peak.object_pool, f.name) = sv;
    }
    inline for (@typeInfo(stats.ShadowArenaStats).@"struct".fields) |f| {
        const sv = @field(af.shadow_arena, f.name);
        const rv = @field(report.allocators_peak.shadow_arena, f.name);
        if (sv > rv) @field(report.allocators_peak.shadow_arena, f.name) = sv;
    }
}

/// GlobalStats 字段累加（编译期反射，覆盖所有字段）
fn addGlobalStats(dst: *GlobalStats, src: *const GlobalStats) void {
    inline for (@typeInfo(GlobalStats).@"struct".fields) |f| {
        @field(dst, f.name) += @field(src, f.name);
    }
}

/// TypeStats 字段累加
fn addTypeStats(dst: *stats.TypeStats, src: *const stats.TypeStats) void {
    inline for (@typeInfo(stats.TypeStats).@"struct".fields) |f| {
        @field(dst, f.name) += @field(src, f.name);
    }
}

/// AllocatorStats 字段累加（channel + object_pool + shadow_arena）
fn addAllocatorStats(dst: *AllocatorStats, src: *const AllocatorStats) void {
    inline for (@typeInfo(stats.ChannelStats).@"struct".fields) |f| {
        @field(dst.channel, f.name) += @field(src.channel, f.name);
    }
    inline for (@typeInfo(stats.ObjectPoolStats).@"struct".fields) |f| {
        @field(dst.object_pool, f.name) += @field(src.object_pool, f.name);
    }
    inline for (@typeInfo(stats.ShadowArenaStats).@"struct".fields) |f| {
        @field(dst.shadow_arena, f.name) += @field(src.shadow_arena, f.name);
    }
}

test {
    std.testing.refAllDecls(@This());
}
