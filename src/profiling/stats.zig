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
pub const ref_kind_count: usize = 23;

/// RefKind 名称表（与 obj_header.RefKind 枚举顺序一一对应）
/// 不直接导入 obj_header 以避免 profiling ↔ value 循环依赖；
/// 此处手动镜像维护。每次 RefKind 增删需同步更新。
pub const REF_KIND_NAMES = [_][]const u8{
    "str",          "array",        "record",       "adt",
    "newtype",      "cell",         "range",        "closure",
    "partial",      "builtin",      "trait_val",    "lazy_val",
    "error_val",    "throw_val",    "array_iter",   "string_iter",
    "range_iter",   "atomic_val",   "async_val",    "channel_val",
    "sender_val",   "receiver_val", "boxed_scalar",
};

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

// Zig 0.16 移除了 std.os.windows 下的 QueryPerformanceFrequency /
// QueryPerformanceCounter / kernel32.Sleep，需直接 extern 声明。
extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;

/// 读取单调时钟的纳秒时间戳（替代 Zig 0.15 的 std.time.nanoTimestamp）
///
/// 平台分支：POSIX 用 clock_gettime(CLOCK_MONOTONIC)，Windows 用 QPC。
/// 返回值保证单调递增，可用于采样间隔与时长计算。
pub fn nanoTimestamp() i64 {
    switch (builtin.os.tag) {
        .windows => {
            var freq: std.os.windows.LARGE_INTEGER = 0;
            var now: std.os.windows.LARGE_INTEGER = 0;
            _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
            _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&now);
            if (freq == 0) return 0;
            // 拆分为秒 + 小数部分分别换算，避免 now * ns_per_s 在长时间
            // 运行后（QPC 计数可达 10^14）溢出 i64。
            const sec = @divFloor(now, freq);
            const frac = @mod(now, freq);
            return sec * std.time.ns_per_s + @divFloor(frac * std.time.ns_per_s, freq);
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
            Sleep(@intCast(ns / std.time.ns_per_ms));
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
    /// inclusive time：函数从进入到返回的总耗时（含子调用）
    inclusive_time_ns: u64 = 0,
    /// exclusive time：函数自身耗时（扣除子调用），用于定位真正的热点
    exclusive_time_ns: u64 = 0,
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
/// child_time_ns 累加本帧所有直接子调用的耗时，用于计算 exclusive time
pub const CallStackEntry = struct {
    func_idx: u32,
    start_ns: i64,
    child_time_ns: u64 = 0,
};

/// Per-function 时间数组（实时累加，aggregator 直接读取）
/// [0] = inclusive_time_ns, [1] = exclusive_time_ns
pub const FuncTimeArray = [MAX_TRACKED_FUNCS][2]u64;
pub const FuncCallArray = [MAX_TRACKED_FUNCS]u64;

test {
    std.testing.refAllDecls(@This());
}
