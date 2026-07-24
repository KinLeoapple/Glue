//! 报告输出：文本格式（stderr）+ JSON 格式（文件）

const std = @import("std");
const stats = @import("stats.zig");
const phases_mod = @import("phases.zig");
const aggregator = @import("aggregator.zig");

const Report = aggregator.Report;
const Phase = phases_mod.Phase;
const PHASE_NAMES = phases_mod.PHASE_NAMES;
const phase_count = phases_mod.phase_count;
const ref_kind_count = stats.ref_kind_count;
const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const FuncStat = stats.FuncStat;
const Stringify = std.json.Stringify;

/// 文本格式输出到 writer
pub fn dumpText(report: *const Report, writer: anytype) !void {
    try writer.print("\n[PROFILE]\n\n", .{});

    // 1. 管线阶段
    try writer.print("phases (wall-clock):\n", .{});
    try dumpPhases(report.phases, writer);

    // 2. 全局内存汇总
    // peak_bytes 是 ThreadProfiler 在每次 watermark/alloc 时维护的单调最大值，
    // 比采样到的 current_bytes 更准确（采样可能错过瞬时峰值）
    try writer.print("\nmemory (global):\n", .{});
    try writer.print("  peak live      : {d} B\n", .{report.global_final.peak_bytes});
    try writer.print("  final live     : {d} B\n", .{report.global_final.current_bytes});
    try writer.print("  total alloc    : {d} B ({d} objects)\n", .{
        report.global_final.alloc_bytes, report.global_final.alloc_count,
    });
    try writer.print("  total free     : {d} B ({d} objects)\n", .{
        report.global_final.free_bytes, report.global_final.free_count,
    });

    // 3. 逃逸分流
    try writer.print("\nescape analysis:\n", .{});
    const arena_pct = pct(report.global_final.arena_alloc_bytes, report.global_final.alloc_bytes);
    const heap_pct = 100.0 - arena_pct;
    try writer.print("  arena (no_escape) : {d} B ({d} allocs, {d:.1}%)\n", .{
        report.global_final.arena_alloc_bytes, report.global_final.arena_alloc_count, arena_pct,
    });
    try writer.print("  heap  (escape)    : {d} B ({d} allocs, {d:.1}%)\n", .{
        report.global_final.heap_alloc_bytes, report.global_final.heap_alloc_count, heap_pct,
    });

    // 4. RC 操作
    try writer.print("\nreference counting:\n", .{});
    try writer.print("  retain       : {d}\n", .{report.global_final.retain_count});
    try writer.print("  release      : {d}\n", .{report.global_final.release_count});
    try writer.print("  rc_to_zero   : {d}\n", .{report.global_final.rc_to_zero_count});

    // 5. 缓存命中率
    try writer.print("\ncache hit rate:\n", .{});
    try dumpHitRate(writer, "memo", report.global_final.memo_hits, report.global_final.memo_misses);
    try dumpHitRate(writer, "slot_cache", report.global_final.slot_cache_hits, report.global_final.slot_cache_misses);

    // 6. 三分配器
    try writer.print("\nallocators:\n", .{});
    try writer.print("  channel_region  : peak {d} B, resets {d} ({d} B reclaimed)\n", .{
        report.allocators_peak.channel.peak_bytes,
        report.allocators_final.channel.reset_count,
        report.allocators_final.channel.reset_bytes,
    });
    try writer.print("  object_pool     : {d} pages, {d} buddy allocs ({d} B)\n", .{
        report.allocators_final.object_pool.page_count,
        report.allocators_final.object_pool.buddy_alloc_count,
        report.allocators_final.object_pool.buddy_alloc_bytes,
    });
    try writer.print("  shadow_arena    : peak {d} B, resets {d} ({d} B reclaimed)\n", .{
        report.allocators_peak.shadow_arena.peak_bytes,
        report.allocators_final.shadow_arena.reset_count,
        report.allocators_final.shadow_arena.reset_bytes,
    });

    // 7. 类型分布 Top-10
    try writer.print("\ntype distribution (top 10 by alloc bytes):\n", .{});
    try dumpTypeDistribution(&report.types_final, writer);

    // 8. per-function Top-20
    // exclusive = 自身耗时（扣除子调用），用于定位热点
    // inclusive = 含子调用的总耗时，用于理解调用链开销
    // 百分比分母为 wall-clock total，exclusive 之和不会超过 100%
    try writer.print("\nfunctions (top 20 by exclusive time):\n", .{});
    try dumpFuncTopN(report, 20, writer);

    // 9. 时间序列元信息
    try writer.print("\ntimeline:\n", .{});
    try writer.print("  samples : {d} fine + {d} coarse = {d} total\n", .{
        report.sample_count, report.coarse_count, report.sample_count + report.coarse_count,
    });
    try writer.print("  timespan: {d:.3} ms\n", .{@as(f64, @floatFromInt(report.timespan_ns)) / 1_000_000.0});
}

/// JSON 格式输出到 writer
///
/// `writer` 须为 `*std.Io.Writer`（其他 writer 类型未测试）。
pub fn dumpJson(report: *const Report, writer: anytype) !void {
    var jw: Stringify = .{ .writer = writer };
    try jw.beginObject();

    try jw.objectField("phases");
    try dumpPhasesJson(&report.phases, &jw);

    try jw.objectField("global_final");
    try dumpGlobalJson(&report.global_final, &jw);

    try jw.objectField("global_peak");
    try dumpGlobalJson(&report.global_peak, &jw);

    try jw.objectField("types_final");
    try dumpTypesJson(&report.types_final, &jw);

    try jw.objectField("allocators_final");
    try dumpAllocatorsJson(&report.allocators_final, &jw);

    try jw.objectField("allocators_peak");
    try dumpAllocatorsJson(&report.allocators_peak, &jw);

    try jw.objectField("functions");
    try dumpFuncStatsJson(&report.func_stats, report.phases.total_ns, report.func_names, &jw);

    try jw.objectField("timeline_meta");
    try jw.beginObject();
    try jw.objectField("sample_count");
    try jw.write(report.sample_count);
    try jw.objectField("coarse_count");
    try jw.write(report.coarse_count);
    try jw.objectField("timespan_ns");
    try jw.write(report.timespan_ns);
    try jw.endObject();

    try jw.endObject();
}

// ============ 内部辅助 ============

fn dumpPhases(phases: phases_mod.Phases, writer: anytype) !void {
    // 顶层阶段
    for (0..phase_count) |i| {
        const phase: Phase = @enumFromInt(i);
        if (!phase.isTopLevel()) continue;
        const t = phases.timings[i];
        if (t.elapsed_ns == 0) continue;
        const ms = @as(f64, @floatFromInt(t.elapsed_ns)) / 1e6;
        const p = t.pct(phases.total_ns);
        try writer.print("  {s: <16}: {d:>8.3} ms ({d:>5.1}%)  self: {d:>8.3} ms\n", .{
            PHASE_NAMES[i], ms, p, @as(f64, @floatFromInt(t.self_ns)) / 1e6,
        });
        // 子阶段
        for (0..phase_count) |j| {
            const sub: Phase = @enumFromInt(j);
            if (sub.parent()) |par| {
                if (par == phase) {
                    const st = phases.timings[j];
                    if (st.elapsed_ns == 0) continue;
                    const sms = @as(f64, @floatFromInt(st.elapsed_ns)) / 1e6;
                    const sp = st.pct(phases.total_ns);
                    try writer.print("    {s: <14}: {d:>8.3} ms ({d:>5.1}%)  self: {d:>8.3} ms\n", .{
                        PHASE_NAMES[j], sms, sp, @as(f64, @floatFromInt(st.self_ns)) / 1e6,
                    });
                }
            }
        }
    }
    const total_ms = @as(f64, @floatFromInt(phases.total_ns)) / 1e6;
    try writer.print("  {s: <16}: {d:>8.3} ms\n", .{ "total", total_ms });
}

fn dumpHitRate(writer: anytype, name: []const u8, hits: u64, misses: u64) !void {
    const total = hits + misses;
    const rate = if (total > 0) (@as(f64, @floatFromInt(hits)) * 100.0) / @as(f64, @floatFromInt(total)) else 0;
    try writer.print("  {s: <12}: {d:.1}%  ({d} hits / {d} misses)\n", .{ name, rate, hits, misses });
}

fn dumpTypeDistribution(types: *const TypeStatsArray, writer: anytype) !void {
    // 收集并按 alloc_bytes 降序排序（程序结束时 live 通常已归零，按 alloc 更有信息量）
    var buf: [ref_kind_count]struct { idx: u8, alloc_bytes: u64 } = undefined;
    var n: usize = 0;
    for (0..ref_kind_count) |i| {
        if (types[i].alloc_bytes > 0) {
            buf[n] = .{ .idx = @intCast(i), .alloc_bytes = types[i].alloc_bytes };
            n += 1;
        }
    }
    std.mem.sort(@TypeOf(buf[0]), buf[0..n], {}, struct {
        fn cmp(_: void, a: @TypeOf(buf[0]), b: @TypeOf(buf[0])) bool {
            return a.alloc_bytes > b.alloc_bytes;
        }
    }.cmp);
    const top = @min(n, 10);
    for (buf[0..top]) |e| {
        const name = if (e.idx < stats.REF_KIND_NAMES.len) stats.REF_KIND_NAMES[e.idx] else "?";
        try writer.print("  {s: <13} : {d} live, {d} allocs, {d} B\n", .{
            name, types[e.idx].live_count, types[e.idx].alloc_count, types[e.idx].alloc_bytes,
        });
    }
}

fn dumpFuncTopN(report: *const Report, n: usize, writer: anytype) !void {
    const top = @min(report.func_stats.items.len, n);
    const total_ns = report.phases.total_ns;
    // 表头
    try writer.print("  {s: <20} {s:>10} {s:>10} {s:>7} {s:>7}  {s}\n", .{
        "name", "excl(ms)", "incl(ms)", "excl%", "incl%", "calls  arena  heap",
    });
    for (report.func_stats.items[0..top]) |fs| {
        const excl_ms = @as(f64, @floatFromInt(fs.exclusive_time_ns)) / 1e6;
        const incl_ms = @as(f64, @floatFromInt(fs.inclusive_time_ns)) / 1e6;
        const excl_pct = if (total_ns > 0)
            (@as(f64, @floatFromInt(fs.exclusive_time_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns))
        else
            0;
        const incl_pct = if (total_ns > 0)
            (@as(f64, @floatFromInt(fs.inclusive_time_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns))
        else
            0;
        const name = if (report.func_names) |names|
            (if (fs.func_idx < names.len) names[fs.func_idx] else "<untracked>")
        else
            null;
        if (name) |nm| {
            try writer.print("  {s: <20} {d:>10.3} {d:>10.3} {d:>6.1}% {d:>6.1}%  {d}  {d} B  {d} B\n", .{
                nm, excl_ms, incl_ms, excl_pct, incl_pct,
                fs.calls, fs.arena_alloc_bytes, fs.heap_alloc_bytes,
            });
        } else {
            try writer.print("  #{d: <19} {d:>10.3} {d:>10.3} {d:>6.1}% {d:>6.1}%  {d}  {d} B  {d} B\n", .{
                fs.func_idx, excl_ms, incl_ms, excl_pct, incl_pct,
                fs.calls, fs.arena_alloc_bytes, fs.heap_alloc_bytes,
            });
        }
    }
}

fn pct(numerator: u64, denominator: u64) f64 {
    if (denominator == 0) return 0;
    return (@as(f64, @floatFromInt(numerator)) * 100.0) / @as(f64, @floatFromInt(denominator));
}

fn dumpPhasesJson(phases: *const phases_mod.Phases, jw: anytype) !void {
    try jw.beginArray();
    for (0..phase_count) |i| {
        const t = phases.timings[i];
        if (t.elapsed_ns == 0) continue;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(PHASE_NAMES[i]);
        try jw.objectField("elapsed_ns");
        try jw.write(t.elapsed_ns);
        try jw.objectField("self_ns");
        try jw.write(t.self_ns);
        try jw.objectField("pct");
        try jw.write(t.pct(phases.total_ns));
        try jw.endObject();
    }
    try jw.endArray();
}

fn dumpGlobalJson(g: *const GlobalStats, jw: anytype) !void {
    try jw.beginObject();
    inline for (@typeInfo(GlobalStats).@"struct".fields) |f| {
        try jw.objectField(f.name);
        try jw.write(@field(g, f.name));
    }
    try jw.endObject();
}

fn dumpTypesJson(types: *const TypeStatsArray, jw: anytype) !void {
    try jw.beginArray();
    for (0..stats.ref_kind_count) |i| {
        if (types[i].alloc_bytes == 0) continue;
        try jw.beginObject();
        try jw.objectField("kind_idx");
        try jw.write(@as(u8, @intCast(i)));
        try jw.objectField("kind_name");
        const name = if (i < stats.REF_KIND_NAMES.len) stats.REF_KIND_NAMES[i] else "?";
        try jw.write(name);
        try jw.objectField("alloc_count");
        try jw.write(types[i].alloc_count);
        try jw.objectField("alloc_bytes");
        try jw.write(types[i].alloc_bytes);
        try jw.objectField("live_count");
        try jw.write(types[i].live_count);
        try jw.objectField("live_bytes");
        try jw.write(types[i].live_bytes);
        try jw.endObject();
    }
    try jw.endArray();
}

fn dumpAllocatorsJson(a: *const AllocatorStats, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("channel");
    try jw.beginObject();
    inline for (@typeInfo(@TypeOf(a.channel)).@"struct".fields) |f| {
        try jw.objectField(f.name);
        try jw.write(@field(a.channel, f.name));
    }
    try jw.endObject();
    try jw.objectField("object_pool");
    try jw.beginObject();
    inline for (@typeInfo(@TypeOf(a.object_pool)).@"struct".fields) |f| {
        try jw.objectField(f.name);
        try jw.write(@field(a.object_pool, f.name));
    }
    try jw.endObject();
    try jw.objectField("shadow_arena");
    try jw.beginObject();
    inline for (@typeInfo(@TypeOf(a.shadow_arena)).@"struct".fields) |f| {
        try jw.objectField(f.name);
        try jw.write(@field(a.shadow_arena, f.name));
    }
    try jw.endObject();
    try jw.endObject();
}

fn dumpFuncStatsJson(
    func_stats: *const std.ArrayList(FuncStat),
    total_ns: u64,
    func_names: ?[]const []const u8,
    jw: anytype,
) !void {
    try jw.beginArray();
    for (func_stats.items) |fs| {
        try jw.beginObject();
        try jw.objectField("func_idx");
        try jw.write(fs.func_idx);
        if (func_names) |names| {
            if (fs.func_idx < names.len) {
                try jw.objectField("func_name");
                try jw.write(names[fs.func_idx]);
            }
        }
        try jw.objectField("calls");
        try jw.write(fs.calls);
        try jw.objectField("inclusive_time_ns");
        try jw.write(fs.inclusive_time_ns);
        try jw.objectField("exclusive_time_ns");
        try jw.write(fs.exclusive_time_ns);
        try jw.objectField("exclusive_pct");
        const ep = if (total_ns > 0)
            (@as(f64, @floatFromInt(fs.exclusive_time_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns))
        else
            0;
        try jw.write(ep);
        try jw.objectField("inclusive_pct");
        const ip = if (total_ns > 0)
            (@as(f64, @floatFromInt(fs.inclusive_time_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns))
        else
            0;
        try jw.write(ip);
        try jw.objectField("arena_alloc_bytes");
        try jw.write(fs.arena_alloc_bytes);
        try jw.objectField("heap_alloc_bytes");
        try jw.write(fs.heap_alloc_bytes);
        try jw.endObject();
    }
    try jw.endArray();
}

test {
    std.testing.refAllDecls(@This());
}
