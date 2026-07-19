//! 性能分析器。
//!
//! 收集编译与运行各阶段的耗时、内存 slab 统计与线程缓存命中率，
//! 最终通过 dump 输出可读的报告到 stderr。

const std = @import("std");

/// 平台自适应计数器类型：64 位平台用 u64，32 位平台用 u32（避免 64 位原子不支持）。
const Counter = if (@sizeOf(usize) >= 8) u64 else u32;

/// 编译/运行阶段标识，用于阶段级耗时统计。
pub const Phase = enum {
    lex,
    parse,
    type_check,
    ir_build,
    ir_optimize,
    engine_run,
};

/// 各阶段对应的显示名称，与 Phase 枚举顺序一致。
const PHASE_NAMES = [@typeInfo(Phase).@"enum".fields.len][]const u8{
    "lex",
    "parse",
    "type_check",
    "ir_build",
    "ir_optimize",
    "engine_run",
};

/// 性能分析器，聚合各阶段耗时与内存统计。
/// 计数字段使用 atomic 以支持多线程安全更新。
pub const Profiler = struct {
    enabled: bool = false,
    io: ?std.Io = null,
    phase_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = .{0} ** @typeInfo(Phase).@"enum".fields.len,
    phase_start: ?std.Io.Timestamp = null,
    current_phase: ?Phase = null,
    slab_peak_bytes: usize = 0,
    slab_live_peak_bytes: usize = 0,
    slab_live_bytes: usize = 0,
    slab_reserved_bytes: usize = 0,
    slab_empty_count: usize = 0,
    slab_large_active: usize = 0,
    slab_large_cached: usize = 0,
    slab_evicted_slabs: u64 = 0,
    slab_evicted_large: u64 = 0,
    slab_evict_scans: u64 = 0,
    cache_hits: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_misses: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_refills: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_drains: std.atomic.Value(Counter) = .{ .raw = 0 },

    /// 创建分析器实例，enabled 控制是否实际采集数据。
    pub fn init(enabled: bool, io: ?std.Io) Profiler {
        return .{ .enabled = enabled, .io = io };
    }

    /// 标记某阶段开始计时。
    pub fn phaseBegin(self: *Profiler, phase: Phase) void {
        if (!self.enabled) return;
        if (self.io) |io| {
            self.phase_start = std.Io.Timestamp.now(io, .awake);
            self.current_phase = phase;
        }
    }

    /// 结束当前阶段计时，将耗时累加到对应 phase_ns 槽位。
    pub fn phaseEnd(self: *Profiler) void {
        if (!self.enabled) return;
        if (self.phase_start) |start| {
            if (self.io) |io| {
                const end = std.Io.Timestamp.now(io, .awake);
                const ns: i96 = start.durationTo(end).nanoseconds;
                if (ns > 0) {
                    if (self.current_phase) |p| {
                        self.phase_ns[@intFromEnum(p)] += @intCast(ns);
                    }
                }
            }
        }
        self.phase_start = null;
        self.current_phase = null;
    }

    // 线程缓存命中/未命中/填充/排空计数
    pub inline fn recordCacheHit(self: *Profiler) void {
        _ = self.cache_hits.fetchAdd(1, .monotonic);
    }
    pub inline fn recordCacheMiss(self: *Profiler) void {
        _ = self.cache_misses.fetchAdd(1, .monotonic);
    }
    pub inline fn recordRefill(self: *Profiler) void {
        _ = self.cache_refills.fetchAdd(1, .monotonic);
    }
    pub inline fn recordDrain(self: *Profiler) void {
        _ = self.cache_drains.fetchAdd(1, .monotonic);
    }

    /// 记录 slab 内存分配器的当前与峰值字节数。
    pub fn recordSlabStats(
        self: *Profiler,
        live: usize,
        reserved: usize,
        live_peak: usize,
        reserved_peak: usize,
    ) void {
        self.slab_live_bytes = live;
        self.slab_reserved_bytes = reserved;
        self.slab_live_peak_bytes = live_peak;
        self.slab_peak_bytes = reserved_peak;
    }

    /// 记录 slab 缓存的空 slab 数、大对象数及驱逐统计。
    pub fn recordSlabCacheStats(
        self: *Profiler,
        empty_count: usize,
        large_active: usize,
        large_cached: usize,
        evicted_slabs: u64,
        evicted_large: u64,
        evict_scans: u64,
    ) void {
        self.slab_empty_count = empty_count;
        self.slab_large_active = large_active;
        self.slab_large_cached = large_cached;
        self.slab_evicted_slabs = evicted_slabs;
        self.slab_evicted_large = evicted_large;
        self.slab_evict_scans = evict_scans;
    }

    /// 整体设置线程缓存统计（用于从外部汇总导入）。
    pub fn recordCacheStats(
        self: *Profiler,
        hits: u64,
        misses: u64,
        refills: u64,
        drains: u64,
    ) void {
        self.cache_hits.store(@intCast(hits), .monotonic);
        self.cache_misses.store(@intCast(misses), .monotonic);
        self.cache_refills.store(@intCast(refills), .monotonic);
        self.cache_drains.store(@intCast(drains), .monotonic);
    }

    /// 将所有采集到的统计以可读格式输出到 stderr。
    /// 包含阶段耗时、内存与线程缓存统计。
    pub fn dump(self: *Profiler, io: std.Io) void {
        if (!self.enabled) return;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        const wr = &w.interface;
        wr.print("\n[PROFILE]\n", .{}) catch {};

        // 阶段耗时
        var total_ns: u64 = 0;
        for (self.phase_ns) |n| total_ns += n;
        wr.print("phases (wall-clock):\n", .{}) catch {};
        for (self.phase_ns, 0..) |n, i| {
            if (n == 0) continue;
            const ms = @as(f64, @floatFromInt(n)) / 1e6;
            const pct = if (total_ns > 0)
                (@as(f64, @floatFromInt(n)) * 100.0) / @as(f64, @floatFromInt(total_ns))
            else
                0;
            wr.print("  {s: <14}: {d:>8.3} ms ({d:.1}%)\n", .{ PHASE_NAMES[i], ms, pct }) catch {};
        }
        const total_ms = @as(f64, @floatFromInt(total_ns)) / 1e6;
        wr.print("  {s: <14}: {d:>8.3} ms\n", .{ "total", total_ms }) catch {};

        // 内存统计
        wr.print("\nmemory:\n", .{}) catch {};
        wr.print("  peak live     : {s}\n", .{formatBytes(self.slab_live_peak_bytes)}) catch {};
        wr.print("  peak reserved : {s}\n", .{formatBytes(self.slab_peak_bytes)}) catch {};
        if (self.slab_peak_bytes > 0) {
            const frag = 1.0 - (@as(f64, @floatFromInt(self.slab_live_peak_bytes)) /
                @as(f64, @floatFromInt(self.slab_peak_bytes)));
            wr.print("  fragmentation : {d:.1}%  (at peak)\n", .{frag * 100.0}) catch {};
        }
        wr.print("  final live    : {s}\n", .{formatBytes(self.slab_live_bytes)}) catch {};
        wr.print("  final reserved: {s}\n", .{formatBytes(self.slab_reserved_bytes)}) catch {};

        // 内存缓存统计
        wr.print("\nmemory cache:\n", .{}) catch {};
        wr.print("  empty slabs cached : {d}\n", .{self.slab_empty_count}) catch {};
        wr.print("  large objects live : {d}\n", .{self.slab_large_active}) catch {};
        wr.print("  large objects idle : {d}\n", .{self.slab_large_cached}) catch {};
        if (self.slab_evict_scans > 0) {
            wr.print("  idle evict scans   : {d}\n", .{self.slab_evict_scans}) catch {};
            wr.print("  idle evicted slabs : {d}\n", .{self.slab_evicted_slabs}) catch {};
            wr.print("  idle evicted large : {d}\n", .{self.slab_evicted_large}) catch {};
        }

        // 线程缓存统计
        const cache_h = self.cache_hits.load(.monotonic);
        const cache_m = self.cache_misses.load(.monotonic);
        if (cache_h + cache_m > 0) {
            const cache_total = cache_h + cache_m;
            const hit_rate = (@as(f64, @floatFromInt(cache_h)) * 100.0) /
                @as(f64, @floatFromInt(cache_total));
            wr.print("\nthread cache:\n", .{}) catch {};
            wr.print("  hits    : {d}\n", .{cache_h}) catch {};
            wr.print("  misses  : {d}\n", .{cache_m}) catch {};
            wr.print("  hit rate: {d:.1}%\n", .{hit_rate}) catch {};
            wr.print("  refills : {d}\n", .{self.cache_refills.load(.monotonic)}) catch {};
            wr.print("  drains  : {d}\n", .{self.cache_drains.load(.monotonic)}) catch {};
        }

        w.flush() catch {};
    }
};

/// 将字节数格式化为人类可读的字符串（B/KB/MB）。
/// 使用静态缓冲区，结果在下一次调用前有效。
fn formatBytes(bytes: usize) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    if (bytes < 1024) {
        return std.fmt.bufPrint(&Static.buf, "{d} B", .{bytes}) catch "<err>";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(&Static.buf, "{d:.1} KB", .{kb}) catch "<err>";
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(&Static.buf, "{d:.2} MB", .{mb}) catch "<err>";
    }
}
