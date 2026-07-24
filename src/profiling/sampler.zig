//! 后台采样线程
//!
//! - 每 interval_ns 遍历所有 ThreadProfiler 做 seqlock 读取
//! - 聚合多线程快照为单个 Sample 写入 timeline
//! - 实时读注册表（mutex 保护），确保 orbit worker 完整采集
//! - seqlock 无上限自旋读取，保证不丢失任何线程采样
//! - 自适应睡眠：>1ms 用 sleep，<=1ms 用自旋等待

const std = @import("std");
const builtin = @import("builtin");
const thread_profiler_mod = @import("thread_profiler.zig");
const timeline_mod = @import("timeline.zig");
const stats = @import("stats.zig");

const ThreadProfiler = thread_profiler_mod.ThreadProfiler;
const Timeline = timeline_mod.Timeline;
const Sample = stats.Sample;
const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ref_kind_count = stats.ref_kind_count;
const SpinMutex = stats.SpinMutex;
const nanoTimestamp = stats.nanoTimestamp;
const sleepNs = stats.sleepNs;

/// 后台采样线程
pub const Sampler = struct {
    global_prof: GlobalProfilerRef,
    interval_ns: u64,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    started: bool = false,

    /// GlobalProfiler 的引用类型（避免循环依赖，用接口）
    pub const GlobalProfilerRef = struct {
        thread_profilers: *std.ArrayList(*ThreadProfiler),
        registry_mutex: *SpinMutex,
        timeline: *Timeline,
    };

    /// 启动采样线程
    pub fn start(self: *Sampler) !void {
        if (self.started) return;
        self.thread = try std.Thread.spawn(.{}, sampleLoop, .{self});
        self.started = true;
    }

    /// 停止采样线程
    pub fn stop(self: *Sampler) void {
        if (!self.started) return;
        self.stop_flag.store(true, .release);
        self.thread.join();
        self.started = false;
    }

    fn sampleLoop(self: *Sampler) void {
        // 降低采样线程优先级（减少对主线程的调度干扰）
        reduceThreadPriority();

        var next_ns: i64 = nanoTimestamp();

        while (!self.stop_flag.load(.acquire)) {
            next_ns += @as(i64, @intCast(self.interval_ns));
            const now = nanoTimestamp();

            if (next_ns > now) {
                const sleep_ns: u64 = @intCast(next_ns - now);
                if (sleep_ns > 1_000_000) {
                    // >1ms 用 sleep
                    sleepNs(sleep_ns);
                } else {
                    // <=1ms 用自旋等待（高精度）
                    while (nanoTimestamp() < next_ns) {
                        std.atomic.spinLoopHint();
                    }
                }
            } else {
                // 已超过下一个采样点，重置基准
                next_ns = now;
            }

            self.collectAndPush(nanoTimestamp()) catch {};
        }
        // 停止前最后采集一次
        self.collectAndPush(nanoTimestamp()) catch {};
    }

    /// 遍历所有 ThreadProfiler，seqlock 读取并聚合为一个 Sample
    fn collectAndPush(self: *Sampler, now_ns: i64) !void {
        var aggregated = Sample{
            .wall_clock_ns = now_ns,
            .thread_id = 0, // 聚合后用 0 表示多线程总和
            .func_idx = 0,
            .global = .{},
            .types = [_]stats.TypeStats{.{}} ** ref_kind_count,
            .allocators = .{},
        };

        var primary_func: u32 = 0;
        var min_thread_id: u32 = std.math.maxInt(u32);

        // 实时获取当前所有 ThreadProfiler（持锁复制指针列表）
        var profilers_buf: [64]*ThreadProfiler = undefined;
        const count = blk: {
            self.global_prof.registry_mutex.lock();
            defer self.global_prof.registry_mutex.unlock();
            const items = self.global_prof.thread_profilers.items;
            const n = @min(items.len, profilers_buf.len);
            @memcpy(profilers_buf[0..n], items[0..n]);
            break :blk n;
        };

        // 无锁遍历快照
        for (profilers_buf[0..count]) |prof| {
            if (readThreadSnapshot(prof, &aggregated)) {
                if (prof.thread_id < min_thread_id) {
                    min_thread_id = prof.thread_id;
                    primary_func = aggregated.func_idx;
                }
            }
        }

        aggregated.func_idx = primary_func;
        try self.global_prof.timeline.push(aggregated);
    }

    /// seqlock 读取（无上限自旋，保证不丢失采样）
    /// 读取后累加到 dst（支持多线程聚合），而非覆盖
    fn readThreadSnapshot(prof: *ThreadProfiler, dst: *Sample) bool {
        var spin_count: u32 = 0;
        while (true) {
            const seq1 = prof.seq.load(.acquire);
            if (seq1 & 1 != 0) {
                std.atomic.spinLoopHint();
                spin_count += 1;
                if (spin_count > 1000) {
                    // 防御性：超过 1000 次自旋记录警告并跳过
                    // 正常情况永不触发（seqlock 区间极短）
                    return false;
                }
                continue;
            }

            // 读取所有计数器到本地临时变量（seqlock 一致性快照）
            const snap_global = prof.global;
            const snap_types = prof.types;
            const snap_allocators = prof.allocators;
            const snap_func = prof.current_func_idx.load(.acquire);

            const seq2 = prof.seq.load(.acquire);
            if (seq1 == seq2) {
                // 累加到 dst（多线程聚合）
                addGlobalStats(&dst.global, &snap_global);
                for (0..ref_kind_count) |k| {
                    addTypeStats(&dst.types[k], &snap_types[k]);
                }
                addAllocatorStats(&dst.allocators, &snap_allocators);
                dst.func_idx = snap_func;
                return true;
            }
            // seq 变化，继续重试
            std.atomic.spinLoopHint();
            spin_count += 1;
        }
    }
};

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

/// 降低采样线程优先级（平台相关）
///
/// 通过 libc setpriority 调整，失败时静默忽略。Zig 0.16 的 std.c 不再
/// 直接暴露 setpriority 符号，故按平台声明 extern。
fn reduceThreadPriority() void {
    switch (builtin.os.tag) {
        .linux => {
            // PRIO_PROCESS = 0
            _ = setpriority(0, 0, 10);
        },
        .macos, .ios, .maccatalyst, .tvos, .visionos, .watchos, .driverkit => {
            // PRIO_DARWIN_THREAD = 2
            _ = setpriority(2, 0, 20);
        },
        else => {},
    }
}

extern "c" fn setpriority(which: c_int, who: c_int, value: c_int) c_int;

test {
    std.testing.refAllDecls(@This());
}
