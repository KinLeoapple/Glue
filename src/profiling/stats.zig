//! Profiler 数据模型定义（纯类型 + 基础工具）
//!
//! 定义 GlobalStats / TypeStats / AllocatorStats / Sample / CoarseSample /
//! FuncStat / CallStackEntry 结构体，供 thread_profiler / sampler / aggregator 使用。
//!
//! 另提供 SpinMutex / nanoTimestamp / sleepNs 三个底层工具，供各 profiling
//! 子模块共享。Zig 0.16 的 std.time 不再提供 nanoTimestamp / sleep，且
//! std.Thread.Mutex 已移除，故在此内联最小实现（依赖 libc）。

const std = @import("std");
const builtin = @import("builtin");

/// 堆对象类型变体数量（与 obj_header.RefKind 的字段数一致）
/// 不直接导入 obj_header 以避免 profiling ↔ value 循环依赖。
/// 调用方用 @intFromEnum(ref_kind) 转为 u8 传入 profiler API。
pub const ref_kind_count: usize = 22;

// ============ 基础工具（Zig 0.16 兼容层）============

/// 自旋互斥锁（替代 Zig 0.15 的 std.Thread.Mutex）
///
/// 临界区短小（seqlock 更新、线程注册表）时使用自旋即可，
/// 无需 futex。state=0 未锁，state=1 已锁。
pub const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

/// 读取单调时钟的纳秒时间戳（替代 Zig 0.15 的 std.time.nanoTimestamp）
///
/// 平台分支：POSIX 用 clock_gettime(CLOCK_MONOTONIC)，Windows 用 QPC。
/// 返回值保证单调递增，可用于采样间隔与时长计算。
pub fn nanoTimestamp() i64 {
    switch (builtin.os.tag) {
        .windows => {
            var freq: i64 = 0;
            var now: i64 = 0;
            _ = std.os.windows.QueryPerformanceFrequency(&freq);
            _ = std.os.windows.QueryPerformanceCounter(&now);
            if (freq == 0) return 0;
            return @divFloor(now * std.time.ns_per_s, freq);
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
        },
    }
}

/// 纳秒级睡眠（替代 Zig 0.15 的 std.time.sleep）
///
/// POSIX 用 nanosleep，Windows 用 Sleep（毫秒粒度）。
pub fn sleepNs(ns: u64) void {
    switch (builtin.os.tag) {
        .windows => {
            std.os.windows.kernel32.Sleep(@intCast(ns / std.time.ns_per_ms));
        },
        else => {
            const sec: i64 = @intCast(ns / std.time.ns_per_s);
            const nsec: i64 = @intCast(ns % std.time.ns_per_s);
            const req: std.c.timespec = .{ .sec = sec, .nsec = nsec };
            _ = std.c.nanosleep(&req, null);
        },
    }
}

// ============ 数据模型 ============

/// 全局聚合计数器
pub const GlobalStats = struct {
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    alloc_bytes: u64 = 0,
    free_bytes: u64 = 0,
    current_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    arena_alloc_count: u64 = 0,
    arena_alloc_bytes: u64 = 0,
    heap_alloc_count: u64 = 0,
    heap_alloc_bytes: u64 = 0,
    retain_count: u64 = 0,
    release_count: u64 = 0,
    rc_to_zero_count: u64 = 0,
    memo_hits: u64 = 0,
    memo_misses: u64 = 0,
    slot_cache_hits: u64 = 0,
    slot_cache_misses: u64 = 0,
};

/// 按 RefKind 分布的类型统计
pub const TypeStats = struct {
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    live_count: u64 = 0,
    live_bytes: u64 = 0,
    free_count: u64 = 0,
};

/// 类型统计数组（22 种 RefKind）
pub const TypeStatsArray = [ref_kind_count]TypeStats;

/// 分配器种类
pub const AllocatorKind = enum { channel, object_pool, shadow_arena };

/// ChannelRegion 统计
pub const ChannelStats = struct {
    peak_bytes: u64 = 0,
    current_bytes: u64 = 0,
    reset_count: u64 = 0,
    reset_bytes: u64 = 0,
    alloc_count: u64 = 0,
};

/// ObjectPool/Buddy 统计
pub const ObjectPoolStats = struct {
    page_count: u64 = 0,
    page_alloc_count: u64 = 0,
    page_free_count: u64 = 0,
    buddy_alloc_count: u64 = 0,
    buddy_alloc_bytes: u64 = 0,
};

/// ShadowArena 统计
pub const ShadowArenaStats = struct {
    peak_bytes: u64 = 0,
    current_bytes: u64 = 0,
    reset_count: u64 = 0,
    reset_bytes: u64 = 0,
};

/// 三分配器统计聚合
pub const AllocatorStats = struct {
    channel: ChannelStats = .{},
    object_pool: ObjectPoolStats = .{},
    shadow_arena: ShadowArenaStats = .{},
};

/// arena 路径按类型累计（供 reset 时批量扣减 types.live_*）
pub const ArenaByType = struct {
    count: u64 = 0,
    bytes: u64 = 0,
};
pub const ArenaByTypeArray = [ref_kind_count]ArenaByType;

/// 时间序列单点（细粒度）
pub const Sample = struct {
    wall_clock_ns: i64,
    thread_id: u32,
    func_idx: u32,
    global: GlobalStats,
    types: TypeStatsArray,
    allocators: AllocatorStats,
};

/// 时间序列单点（粗粒度，分段累积后）
pub const CoarseSample = struct {
    begin_ns: i64,
    end_ns: i64,
    thread_id: u32,
    func_idx: u32, // 该段内占时最多的函数（众数）
    global: GlobalStats, // 末态累计值
    types: TypeStatsArray,
    allocators: AllocatorStats,
    sample_count: u32,
};

/// per-function 统计（aggregator 产出，非采集期存储）
pub const FuncStat = struct {
    func_idx: u32,
    calls: u64 = 0,
    total_time_ns: u64 = 0,
    arena_alloc_bytes: u64 = 0,
    heap_alloc_bytes: u64 = 0,
    retain_count: u64 = 0,
    release_count: u64 = 0,
};

/// Per-function 分配累加器（ThreadProfiler 内部使用，热路径 O(1) 数组访问）
/// 在 recordAlloc 中按 current_func_idx 累加，aggregator 读取后填充到 FuncStat
pub const FuncAllocAccum = struct {
    arena_bytes: u64 = 0,
    heap_bytes: u64 = 0,
    retain_count: u64 = 0,
    release_count: u64 = 0,
};

/// 最大跟踪函数数（超过此索引的函数不记录 per-function 内存归因）
pub const MAX_TRACKED_FUNCS: usize = 1024;
pub const FuncAllocArray = [MAX_TRACKED_FUNCS]FuncAllocAccum;

/// 最大调用栈深度（实时 per-function 计时用）
/// 超过此深度时跳过计时但不崩溃；O(log n) 递归远低于此限制
pub const MAX_CALL_DEPTH: usize = 4096;

/// 调用栈条目（实时 per-function 计时用）
pub const CallStackEntry = struct {
    func_idx: u32,
    start_ns: i64,
};

/// Per-function 时间和调用计数数组（实时累加，aggregator 直接读取）
pub const FuncTimeArray = [MAX_TRACKED_FUNCS]u64;
pub const FuncCallArray = [MAX_TRACKED_FUNCS]u64;

test {
    std.testing.refAllDecls(@This());
}
