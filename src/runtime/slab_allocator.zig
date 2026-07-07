//! SlabAllocator — 通用多线程 Slab 分配器
//!
//! 设计要点：
//! - Per-class Mutex：每个 size class 一把 std.Thread.Mutex，alloc/free 仅锁目标 class，
//!   不同 class 完全并行；多线程吞吐近线性。
//! - ThreadCache：per-thread 无锁快路径（可选）。alloc/free 走 free_lists 纯指针 push/pop，
//!   空则批量 refill、过满则批量 drain 到 SlabAllocator。
//! - Comptime 特化（核心利用 Zig comptime）：
//!   1. SIZE_CLASSES 表编译期合并基础档位 + 装箱类型 @sizeOf(T)，精确命中无内部碎片。
//!   2. CLASS_LOOKUP 表编译期生成 size→class_idx 反查表。
//!   3. TypedPool(T) 编译期计算 T 对应的 class_idx、slot_size，提供类型安全 acquire/release。
//! - 实现 std.mem.Allocator 接口（通用），同时支持类型安全 API。
//! - 多线程安全统计（std.atomic.Value）：live/reserved/peak 均原子更新。
//! - 段式 slab：同一 class 内 slot 等大，永不分裂/合并 → 外部碎片 = 0。
//! - slab 头内嵌于 16KB 对齐块首，free 时指针掩码 O(1) 反查所属 slab。
//! - 空 slab 全局缓存（per-pool 单锁，与 class 锁不嵌套），超上限归还 backing。
//!
//! 与 MagazineAllocator 的关系：
//! SlabAllocator 替代 MagazineAllocator，同时承担 Value thread-isolated 堆
//! 和通用共享堆职责。Value 路径用 thread-isolated 实例（每线程独立 SlabAllocator），
//! 通用路径用共享实例。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");
const Mutex = sync.Mutex;

// ============================================================
// Comptime size class 表生成
// ============================================================

/// 基础档位：8 步进 + 16 步进 + ~1.25× 几何高段。
/// 与 SlabPool 表保持一致以共享调校经验。
const BASE_CLASSES = [_]u32{
    16,   24,   32,   40,   48,   56,   64,   72,
    80,   88,   96,   104,  112,  120,  128,
    144,  160,  176,  192,  208,  224,  240,  256,
    320,  384,  448,  512,
    640,  768,  896,  1024,
    1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096,
};

/// 装箱类型列表：编译期特化目标。这些类型频繁创建销毁（rc 归零即释放），
/// 必须在 SIZE_CLASSES 中精确命中档位以消除内部碎片。
const BOX_TYPES = [_]type{
    value.AdtValue,
    value.NewtypeValue,
    value.ArrayValue,
    value.RecordValue,
    value.Cell,
    value.Range,
};

/// 所有候选 size（基础 + 装箱类型 @sizeOf），未去重未排序。
const ALL_CANDIDATES = blk: {
    var arr: [BASE_CLASSES.len + BOX_TYPES.len]u32 = undefined;
    for (BASE_CLASSES, 0..) |s, i| arr[i] = s;
    for (BOX_TYPES, 0..) |T, i| arr[BASE_CLASSES.len + i] = @intCast(@sizeOf(T));
    break :blk arr;
};

/// Comptime 插入排序（小数组高效，避免 std.sort.heap 的 comptime 分支配额问题）。
fn comptimeSort(comptime T: type, arr: anytype) void {
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        const key: T = arr[i];
        var j: usize = i;
        while (j > 0 and arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            j -= 1;
        }
        arr[j] = key;
    }
}

/// Comptime 合并去重排序生成最终 SIZE_CLASSES 表。
/// 装箱类型大小精确命中档位（无内部碎片），其他大小走最近档位（≤12.5% 内部碎片）。
pub const SIZE_CLASSES: [uniqueLen()]u32 = blk: {
    @setEvalBranchQuota(10000);
    var arr = ALL_CANDIDATES;
    comptimeSort(u32, &arr);

    // 去重 in-place
    var write: usize = 1;
    var read: usize = 1;
    while (read < arr.len) : (read += 1) {
        if (arr[read] != arr[write - 1]) {
            arr[write] = arr[read];
            write += 1;
        }
    }

    var result: [write]u32 = undefined;
    @memcpy(&result, arr[0..write]);
    break :blk result;
};

/// Comptime 计算 ALL_CANDIDATES 去重后的长度（用于 SIZE_CLASSES 数组维度）。
fn uniqueLen() usize {
    @setEvalBranchQuota(10000);
    var arr = ALL_CANDIDATES;
    comptimeSort(u32, &arr);

    var unique: usize = 1;
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        if (arr[i] != arr[i - 1]) unique += 1;
    }
    return unique;
}

pub const NUM_CLASSES = SIZE_CLASSES.len;

/// > 此阈值的分配直通 backing（大对象，不进 slab）。
/// 必须严格大于 SIZE_CLASSES 最大值（4096），否则 4096 档位的 slot 在 free 时
/// 会被 vtableFree 误判为 large 走 freeLarge（backing.free），但 slot 是 slab 内部指针，
/// backing canary 不匹配 → panic。原 bug：LARGE_THRESHOLD=4096 == SIZE_CLASSES.max。
pub const LARGE_THRESHOLD: usize = 4097;

/// slot 最小对齐（= 装箱 struct 的 @alignOf，均为 8：首字段 rc:u32 + 指针切片）。
pub const SLOT_ALIGNMENT: usize = 8;

/// 单个 slab（span）大小：必须是 2 的幂（掩码反查）。16KB 摊销 backing 调用 + 限制冷 class 浪费。
pub const SLAB_SIZE: usize = 16 * 1024;
pub const SLAB_MASK: usize = ~(SLAB_SIZE - 1);
const SLAB_ALIGN: std.mem.Alignment = .fromByteUnits(SLAB_SIZE);

const LOOKUP_LEN = LARGE_THRESHOLD / 8 + 1;

/// Comptime 生成 size → class_idx 查找表（运行时 O(1) 反查）。
/// 索引 = (len+7)/8；值 = SIZE_CLASSES 中首个 slot_size >= need 的下标。
/// 单指针扫描：ci 随 lk 单调递增，总循环 O(LOOKUP_LEN + NUM_CLASSES)，
/// 避免双层循环超 comptime 分支配额。
pub const CLASS_LOOKUP: [LOOKUP_LEN]u8 = blk: {
    @setEvalBranchQuota(10000);
    var lookup: [LOOKUP_LEN]u8 = [_]u8{0} ** LOOKUP_LEN;
    var ci: usize = 0;
    var lk: usize = 0;
    while (lk < LOOKUP_LEN) : (lk += 1) {
        const need: u32 = @intCast(lk * 8);
        while (ci < NUM_CLASSES - 1 and SIZE_CLASSES[ci] < need) ci += 1;
        lookup[lk] = @intCast(ci);
    }
    break :blk lookup;
};

// ============================================================
// 数据结构
// ============================================================

/// 空闲 slot 内嵌的侵入式链表节点（复用 slot 空间，零额外内存）。
pub const FreeNode = struct {
    next: ?*FreeNode,
};

/// 大对象追踪节点（单链表）。登记每个 allocLarge 分配，deinit 时兜底释放未 free 的。
/// LargeNode 自身通过 backing allocator 分配（小对象，几十字节）。
const LargeNode = struct {
    ptr: [*]u8,
    len: usize,
    /// rawFree 所需的 alignment 字节数（已调整：max(alignment, SLOT_ALIGNMENT)）。
    align_bytes: usize,
    next: ?*LargeNode,
    /// 进入 large_free_list 缓存的时间戳（milliTimestamp）。0 = 活跃分配。
    /// idle 回收协程据此判断是否超时未用，超时则归还 backing。
    idle_since: i64 = 0,
};

/// slab 头魔数：校验掩码反查到的确实是本 pool 的 slab 头。
/// 非 pool 分配的指针被误 free 时，magic 不匹配则安全忽略。
pub const SLAB_MAGIC: u64 = 0x5142_5F4C_4F4F_50AB; // "SLB_LOOP" 变体（与 SlabPool 一致）

/// 一个 slab：专属单一 size class，切成等大 slot。头部内嵌于 16KB 对齐块首。
const Slab = struct {
    magic: u64,
    class_idx: u8,
    /// 已分配出去（未归还）的 slot 数。used==0 即整块空。
    used: u32,
    /// 本 slab 总 slot 数。
    total: u32,
    /// 下一个从未分配过的 slot 序号（bump 前沿）；bump==total 后只靠 free_list。
    bump: u32,
    /// slots 区相对块首的字节偏移。
    slots_offset: u32,
    /// 本 slab 自己的空闲 slot 链。
    free_list: ?*FreeNode,
    /// class 的 partial 双向链（有空位的 slab）。
    next: ?*Slab,
    prev: ?*Slab,
    /// 全局 all_slabs 单链（追踪所有活跃 slab，deinit 时遍历释放，含满 slab）。
    all_next: ?*Slab = null,
    /// 进入 empty 缓存的时间戳（milliTimestamp）。0 = 非 empty 缓存状态。
    /// idle 回收协程据此判断是否超时未用，超时则归还 backing。
    idle_since: i64 = 0,
};

/// size class + per-class 锁 + partial 链。
const Class = struct {
    slot_size: u32,
    /// 有空位的 slab 双向链头（分配优先取这里）。
    partial: ?*Slab = null,
    /// per-class 互斥锁：alloc/free 仅锁目标 class，不同 class 完全并行。
    lock: Mutex = .{},
};

/// 全局空 slab 缓存上限：空 slab 进缓存等待复用（同 class 再 alloc 时 O(1) 取回），
/// 超上限则立即归还 backing。idle 回收协程定期扫描缓存，超时未用的 slab 归还 backing，
/// 兼顾"复用减少 backing 调用"与"内存紧凑（空闲超时即归还）"。
const MAX_EMPTY_SLABS: usize = 64;

// ============================================================
// Zig 0.16 时间 API 适配
// ============================================================
//
// Zig 0.16 移除了 std.time.milliTimestamp 和 std.Thread.sleep，时间与睡眠
// 改为基于 io 接口：std.Io.Timestamp.now(io, .awake) 和 io.vtable.sleep。
//
// 全局 Threaded 实例（global_single_threaded）的 now/sleep 实现是纯系统调用
// （Windows: QueryPerformanceCounter/Sleep；POSIX: clock_gettime/clock_nanosleep），
// 不访问 Threaded 内部状态，故可从任意线程安全调用（与项目 vm.zig 中
// `self.io orelse std.Io.Threaded.global_single_threaded.io()` 模式一致）。

/// 获取当前单调时钟时间（毫秒）。线程安全。
fn nowMs() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Timestamp.now(io, .awake);
    // ts.nanoseconds 是 i96，divTrunc 后仍为 i96；单调时钟毫秒值远在 i64 范围内，安全截断。
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

/// 睡眠指定毫秒。线程安全。
fn sleepMs(ms: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = .fromNanoseconds(@intCast(ms * std.time.ns_per_ms)),
            .clock = .awake,
        },
    };
    timeout.sleep(io) catch {};
}

// ============================================================
// SlabAllocator — 通用多线程 slab 分配器主体
// ============================================================

pub const SlabAllocator = struct {
    backing: std.mem.Allocator,
    classes: [NUM_CLASSES]Class,

    /// 全局空 slab 缓存（单链栈，复用 Slab.next）。所有 class 共享，独立锁（不与 class 锁嵌套）。
    empty_slabs: ?*Slab = null,
    empty_count: usize = 0,
    empty_lock: Mutex = .{},

    /// 全局所有活跃 slab 链（单链栈，复用 Slab.all_next）。
    /// 追踪所有从 backing 申请的 slab（含 partial/满/empty 缓存），
    /// deinit 时遍历此链释放全部，避免满 slab（不在 partial 链）漏释放。
    all_slabs: ?*Slab = null,
    all_lock: Mutex = .{},

    /// 大对象追踪链（单链栈，LargeNode.next）。
    /// 登记每个 allocLarge 分配，freeLarge 时移除并归还 backing，deinit 时兜底释放未 free 的。
    large_list: ?*LargeNode = null,
    large_lock: Mutex = .{},

    /// 大对象空闲缓存链（单链栈，LargeNode.next）。freeLarge 时若 idle 回收已启用，
    /// 将 LargeNode 从 large_list 移到 large_free_list 并记录 idle_since 时间戳。
    /// allocLarge 优先从 large_free_list 查找精确大小复用；idle 回收协程定期扫描，
    /// 超时未用的归还 backing。复用 large_lock（与 large_list 共享，低频操作无争用）。
    large_free_list: ?*LargeNode = null,

    // ── idle 回收协程 ──
    /// idle 阈值（毫秒）：缓存中空闲超过此时间的 slab/大对象由回收协程归还 backing。
    /// 0 = 回收协程未启用（freeLarge 立即归还 backing，recycleSlab 仅靠 MAX_EMPTY_SLABS 限制）。
    idle_threshold_ms: i64 = 0,
    /// 回收协程扫描间隔（纳秒）。协程每次 sleep 此时长后扫描一次缓存。
    scan_interval_ns: u64 = 0,
    /// 回收协程线程句柄。null = 协程未启动。
    recycler_thread: ?std.Thread = null,
    /// 回收协程关闭标志：deinit 时置 true，协程下次唤醒后检测到即退出。
    recycler_shutdown: std.atomic.Value(bool) = .{ .raw = false },

    // ── idle 回收累计统计（atomic，profiler 读取反映回收效益）──
    /// 累计扫描次数（evictIdle 调用次数）。
    evict_scans: std.atomic.Value(u64) = .{ .raw = 0 },
    /// 累计归还的空 slab 数。
    evicted_slabs: std.atomic.Value(u64) = .{ .raw = 0 },
    /// 累计归还的大对象数。
    evicted_large: std.atomic.Value(u64) = .{ .raw = 0 },

    // ── 多线程安全统计（atomic）──
    /// 当前活对象字节数。
    live_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    /// 当前向 backing 申请的字节数（含 slab 缓存）。
    reserved_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    /// reserved_bytes 历史峰值（profiler 读取反映内存表现）。
    peak_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    /// live_bytes 历史峰值（用于算真实碎片率：live_peak/peak）。
    live_peak_bytes: std.atomic.Value(usize) = .{ .raw = 0 },

    /// 单线程模式标志：true 时跳过 atomic 操作和 Mutex lock/unlock。
    /// VM 单线程路径用 initSingleThreaded 创建实例，避免 atomic fetchAdd/fetchSub 和
    /// cmpxchg 的开销（单线程下这些操作无争用但仍消耗 cycle）。
    /// 多线程路径（spawn 子 VM）用 init 创建实例，保持线程安全。
    /// 注意：startIdleRecycler 会将此标志置 false（回收协程是独立线程，需锁保护）。
    single_threaded: bool = false,

    pub fn init(backing: std.mem.Allocator) SlabAllocator {
        var self = SlabAllocator{
            .backing = backing,
            .classes = undefined,
            .single_threaded = false,
        };
        for (&self.classes, 0..) |*c, i| {
            c.* = .{ .slot_size = SIZE_CLASSES[i] };
        }
        return self;
    }

    /// 单线程模式初始化：跳过 atomic 和 Mutex，适用于 VM 主线程。
    /// 多线程场景（spawn 子 VM）必须用 init()。
    pub fn initSingleThreaded(backing: std.mem.Allocator) SlabAllocator {
        var self = SlabAllocator{
            .backing = backing,
            .classes = undefined,
            .single_threaded = true,
        };
        for (&self.classes, 0..) |*c, i| {
            c.* = .{ .slot_size = SIZE_CLASSES[i] };
        }
        return self;
    }

    pub fn deinit(self: *SlabAllocator) void {
        // 先停止 idle 回收协程（置 shutdown + join），避免协程在 deinit 期间访问已释放的链表。
        self.stopIdleRecycler();

        // 遍历 all_slabs 释放所有 slab（含 partial 链 / 满 slab / empty 缓存中的全部 slab）。
        // 满 slab 分配满后从 partial 链摘除，不在任何业务链中，故必须依赖 all_slabs 才能释放。
        var cur = self.all_slabs;
        while (cur) |s| {
            const nxt = s.all_next;
            const block_ptr: [*]u8 = @ptrCast(s);
            self.backing.rawFree(block_ptr[0..SLAB_SIZE], SLAB_ALIGN, @returnAddress());
            cur = nxt;
        }
        self.all_slabs = null;
        // 遍历 large_list 释放所有未 free 的大对象（兜底：上层调用方可能未显式 free）。
        var ln = self.large_list;
        while (ln) |n| {
            const nxt = n.next;
            self.backing.rawFree(n.ptr[0..n.len], .fromByteUnits(n.align_bytes), @returnAddress());
            self.backing.destroy(n);
            ln = nxt;
        }
        self.large_list = null;
        // 遍历 large_free_list 释放所有缓存的大对象（idle 回收未及归还的兜底释放）。
        var fn_ = self.large_free_list;
        while (fn_) |n| {
            const nxt = n.next;
            self.backing.rawFree(n.ptr[0..n.len], .fromByteUnits(n.align_bytes), @returnAddress());
            self.backing.destroy(n);
            fn_ = nxt;
        }
        self.large_free_list = null;
        self.* = undefined;
    }

    pub fn allocator(self: *SlabAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = vtableAlloc,
                .resize = vtableResize,
                .remap = vtableRemap,
                .free = vtableFree,
            },
        };
    }

    // ── 内部：统计原子操作 ──
    // 峰值更新用 store 而非 CAS 循环：单线程下精确，多线程下 best-effort（可能丢失少量精度，
    // 但 store 是原子的，最终值是某线程看到的峰值）。避免每次 alloc 都进 CAS 循环。
    //
    // 单线程模式（single_threaded=true）：直接读写 .raw，跳过 atomic 指令（lock xadd 等），
    // 避免 ~10-20 cycle/次的 atomic 开销。多线程模式走 atomic 保证线程安全。

    inline fn addLive(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.live_bytes.raw += n;
            if (self.live_bytes.raw > self.live_peak_bytes.raw) {
                self.live_peak_bytes.raw = self.live_bytes.raw;
            }
            return;
        }
        const live = self.live_bytes.fetchAdd(n, .monotonic) + n;
        if (live > self.live_peak_bytes.load(.monotonic)) {
            self.live_peak_bytes.store(live, .monotonic);
        }
    }

    inline fn subLive(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.live_bytes.raw -= n;
            return;
        }
        _ = self.live_bytes.fetchSub(n, .monotonic);
    }

    inline fn addReserved(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.reserved_bytes.raw += n;
            if (self.reserved_bytes.raw > self.peak_bytes.raw) {
                self.peak_bytes.raw = self.reserved_bytes.raw;
            }
            return;
        }
        const reserved = self.reserved_bytes.fetchAdd(n, .monotonic) + n;
        if (reserved > self.peak_bytes.load(.monotonic)) {
            self.peak_bytes.store(reserved, .monotonic);
        }
    }

    inline fn subReserved(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.reserved_bytes.raw -= n;
            return;
        }
        _ = self.reserved_bytes.fetchSub(n, .monotonic);
    }

    // ── 内部：lock helpers（单线程模式跳过）──

    inline fn lockClass(self: *SlabAllocator, c: *Class) void {
        if (self.single_threaded) return;
        c.lock.lock();
    }

    inline fn unlockClass(self: *SlabAllocator, c: *Class) void {
        if (self.single_threaded) return;
        c.lock.unlock();
    }

    inline fn lockEmpty(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.empty_lock.lock();
    }

    inline fn unlockEmpty(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.empty_lock.unlock();
    }

    inline fn lockAll(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.all_lock.lock();
    }

    inline fn unlockAll(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.all_lock.unlock();
    }

    inline fn lockLarge(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.large_lock.lock();
    }

    inline fn unlockLarge(self: *SlabAllocator) void {
        if (self.single_threaded) return;
        self.large_lock.unlock();
    }

    // ── 内部：slab 操作 ──

    fn freeBlock(self: *SlabAllocator, slab: *Slab) void {
        // 从 all_slabs 链表移除（单链表线性搜索；freeBlock 是低频操作：recycleSlab 超上限时触发）
        self.lockAll();
        if (self.all_slabs == slab) {
            self.all_slabs = slab.all_next;
        } else {
            var prev = self.all_slabs;
            while (prev) |p| {
                if (p.all_next == slab) {
                    p.all_next = slab.all_next;
                    break;
                }
                prev = p.all_next;
            }
        }
        self.unlockAll();

        const block_ptr: [*]u8 = @ptrCast(slab);
        self.backing.rawFree(block_ptr[0..SLAB_SIZE], SLAB_ALIGN, @returnAddress());
    }

    /// 申请一个 16KB 对齐块并初始化为 class i 的 slab。优先复用全局空 slab 缓存。
    /// 调用方必须持有 class.lock。
    fn newSlab(self: *SlabAllocator, class_idx: usize) ?*Slab {
        var slab: *Slab = undefined;
        var is_new = false;

        // 优先复用全局空 slab 缓存（独立锁，与 class 锁不嵌套）
        self.lockEmpty();
        if (self.empty_slabs) |cached| {
            self.empty_slabs = cached.next;
            self.empty_count -= 1;
            slab = cached;
            self.unlockEmpty();
        } else {
            self.unlockEmpty();
            const block = self.backing.alignedAlloc(u8, SLAB_ALIGN, SLAB_SIZE) catch return null;
            slab = @ptrCast(@alignCast(block.ptr));
            self.addReserved(SLAB_SIZE);
            is_new = true;
        }

        // 复用 empty 缓存的 slab 已在 all_slabs 链中，保存 all_next 防止整体赋值断链
        const saved_all_next = if (is_new) null else slab.all_next;
        const hdr = std.mem.alignForward(usize, @sizeOf(Slab), SLOT_ALIGNMENT);
        const slot_size = SIZE_CLASSES[class_idx];
        const total: u32 = @intCast((SLAB_SIZE - hdr) / slot_size);
        slab.* = Slab{
            .magic = SLAB_MAGIC,
            .class_idx = @intCast(class_idx),
            .used = 0,
            .total = total,
            .bump = 0,
            .slots_offset = @intCast(hdr),
            .free_list = null,
            .next = null,
            .prev = null,
            .all_next = saved_all_next,
            .idle_since = 0,
        };
        if (is_new) {
            // 新分配的 slab 加入 all_slabs 链表头
            self.lockAll();
            slab.all_next = self.all_slabs;
            self.all_slabs = slab;
            self.unlockAll();
        }
        return slab;
    }

    /// 整块空的 slab：进全局缓存（等待复用 + idle 回收协程管理），超上限则归还 backing。
    /// 调用方必须持有 class.lock（slab 当前在 partial 链，需先摘除）。
    fn recycleSlab(self: *SlabAllocator, slab: *Slab) void {
        self.lockEmpty();
        if (self.empty_count < MAX_EMPTY_SLABS) {
            slab.idle_since = nowMs();
            slab.next = self.empty_slabs;
            slab.prev = null;
            self.empty_slabs = slab;
            self.empty_count += 1;
            self.unlockEmpty();
        } else {
            self.unlockEmpty();
            self.subReserved(SLAB_SIZE);
            self.freeBlock(slab);
        }
    }

    /// 从 slab 取一个 slot（free_list 优先，否则 bump）。调用方保证 slab 有空位。
    fn slabTake(slab: *Slab) [*]u8 {
        slab.used += 1;
        if (slab.free_list) |node| {
            slab.free_list = node.next;
            return @ptrCast(node);
        }
        const slot_size = SIZE_CLASSES[slab.class_idx];
        const off = slab.slots_offset + slab.bump * slot_size;
        slab.bump += 1;
        const base: [*]u8 = @ptrCast(slab);
        return base + off;
    }

    fn slabHasRoom(slab: *Slab) bool {
        return slab.free_list != null or slab.bump < slab.total;
    }

    fn partialPush(c: *Class, slab: *Slab) void {
        slab.prev = null;
        slab.next = c.partial;
        if (c.partial) |h| h.prev = slab;
        c.partial = slab;
    }

    fn partialRemove(c: *Class, slab: *Slab) void {
        if (slab.prev) |p| p.next = slab.next else c.partial = slab.next;
        if (slab.next) |n| n.prev = slab.prev;
        slab.prev = null;
        slab.next = null;
    }

    // ── 内部：分配/释放路径 ──

    /// 分配一个 slot（小对象路径，per-class 锁）。
    fn allocSlot(self: *SlabAllocator, ci: usize, len: usize) ?[*]u8 {
        const c = &self.classes[ci];
        self.lockClass(c);
        defer self.unlockClass(c);

        if (c.partial) |slab| {
            const ptr = SlabAllocator.slabTake(slab);
            if (!SlabAllocator.slabHasRoom(slab)) SlabAllocator.partialRemove(c, slab);
            self.addLive(len);
            return ptr;
        }

        const slab = self.newSlab(ci) orelse return null;
        SlabAllocator.partialPush(c, slab);
        const ptr = SlabAllocator.slabTake(slab);
        if (!SlabAllocator.slabHasRoom(slab)) SlabAllocator.partialRemove(c, slab);
        self.addLive(len);
        return ptr;
    }

    /// 批量分配 slot（一次 lock + 一次统计）。ThreadCache.refill 调用，
    /// 避免 32 次 lock/unlock + 32 次 atomic addLive。
    fn allocSlotBatch(self: *SlabAllocator, ci: usize, count: u32, out: [*]?[*]u8) u32 {
        const c = &self.classes[ci];
        self.lockClass(c);
        defer self.unlockClass(c);

        var n: u32 = 0;
        while (n < count) {
            if (c.partial == null) {
                const slab = self.newSlab(ci) orelse break;
                SlabAllocator.partialPush(c, slab);
            }
            const slab = c.partial.?;
            out[n] = SlabAllocator.slabTake(slab);
            n += 1;
            if (!SlabAllocator.slabHasRoom(slab)) SlabAllocator.partialRemove(c, slab);
        }
        if (n > 0) self.addLive(@as(usize, n) * SIZE_CLASSES[ci]);
        return n;
    }

    /// 释放一个 slot（小对象路径，per-class 锁）。
    /// 校验魔数：非 pool 分配的指针被误 free 时，magic 不匹配则安全忽略。
    fn freeSlot(self: *SlabAllocator, buf: []u8) void {
        const slab: *Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
        if (slab.magic != SLAB_MAGIC) return;
        const ci = slab.class_idx;
        const c = &self.classes[ci];

        self.lockClass(c);
        defer self.unlockClass(c);

        // was_full 必须在锁内读取：slabHasRoom 读 slab.free_list/bump，
        // 与并发 allocSlot/freeSlot 修改这些字段必须串行化，
        // 否则陈旧的 was_full 会导致 partial 链重复 push / 跳过 remove / 环。
        const was_full = !SlabAllocator.slabHasRoom(slab);

        // 推回 slab 自己的 free_list
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = slab.free_list;
        slab.free_list = node;
        slab.used -= 1;
        self.subLive(buf.len);

        if (slab.used == 0) {
            // slab 整块空：摘除后进全局空缓存（recycleSlab 内部获取 empty_lock）
            if (!was_full) SlabAllocator.partialRemove(c, slab);
            self.recycleSlab(slab);
        } else if (was_full) {
            // 之前满（不在 partial），现在有空位，加回 partial。
            SlabAllocator.partialPush(c, slab);
        }
    }

    /// 释放一个 slot（已知 class_idx 快路径，跳过 magic 校验）。
    /// 调用方必须保证：ptr 来自本 SlabAllocator 的 slab，ci 是正确的 class_idx。
    /// 用于 TypedPool(T).release（compile-time 已知 class_idx）。
    fn freeSlotKnown(self: *SlabAllocator, ci: usize, ptr: [*]u8) void {
        const c = &self.classes[ci];
        const slab: *Slab = @ptrFromInt(@intFromPtr(ptr) & SLAB_MASK);

        self.lockClass(c);
        defer self.unlockClass(c);

        // was_full 必须在锁内读取（同 freeSlot，防止竞态导致 partial 链损坏）。
        const was_full = !SlabAllocator.slabHasRoom(slab);

        // 推回 slab 自己的 free_list
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = slab.free_list;
        slab.free_list = node;
        slab.used -= 1;
        self.subLive(SIZE_CLASSES[ci]);

        if (slab.used == 0) {
            if (!was_full) SlabAllocator.partialRemove(c, slab);
            self.recycleSlab(slab);
        } else if (was_full) {
            SlabAllocator.partialPush(c, slab);
        }
    }

    /// 批量释放 slot（一次 lock + 一次统计）。ThreadCache.drainBatch 调用。
    /// 所有 slot 必须属于同一 class ci（由调用方保证）。
    fn freeSlotBatch(self: *SlabAllocator, ci: usize, in: [*]?[*]u8, count: u32) void {
        const c = &self.classes[ci];
        self.lockClass(c);
        defer self.unlockClass(c);

        const slot_size = SIZE_CLASSES[ci];
        var freed: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const ptr = in[i] orelse continue;
            const slab: *Slab = @ptrFromInt(@intFromPtr(ptr) & SLAB_MASK);
            if (slab.magic != SLAB_MAGIC) continue;
            if (slab.used == 0) continue;
            const was_full = !SlabAllocator.slabHasRoom(slab);
            const node: *FreeNode = @ptrCast(@alignCast(ptr));
            node.next = slab.free_list;
            slab.free_list = node;
            slab.used -= 1;
            if (slab.used == 0) {
                if (!was_full) SlabAllocator.partialRemove(c, slab);
                self.recycleSlab(slab);
            } else if (was_full) {
                SlabAllocator.partialPush(c, slab);
            }
            freed += 1;
        }
        if (freed > 0) self.subLive(@as(usize, freed) * slot_size);
    }

    /// 分配大对象：优先从 large_free_list 复用精确大小 + 对齐匹配的缓存块，
    /// 未命中则直通 backing。登记 LargeNode 到 large_list 供 deinit 兜底释放。
    fn allocLarge(self: *SlabAllocator, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);

        // 优先从 large_free_list 查找精确大小复用（idle 回收启用的场景下才有缓存）
        self.lockLarge();
        {
            var prev: ?*LargeNode = null;
            var cur = self.large_free_list;
            while (cur) |n| {
                if (n.len == len and n.align_bytes >= a) {
                    // 命中：从 free_list 摘除，移入 large_list（活跃追踪）
                    if (prev) |p| p.next = n.next else self.large_free_list = n.next;
                    n.idle_since = 0;
                    n.next = self.large_list;
                    self.large_list = n;
                    self.unlockLarge();
                    self.addLive(len);
                    // reserved_bytes 在首次分配时已计入，复用不重复计
                    return n.ptr;
                }
                prev = n;
                cur = n.next;
            }
        }
        self.unlockLarge();

        // 未命中缓存：直通 backing 精确分配
        const raw = self.backing.rawAlloc(len, .fromByteUnits(a), @returnAddress()) orelse return null;
        self.addReserved(len);
        self.addLive(len);
        // 登记到 large_list，deinit 时兜底释放未 free 的
        const node = self.backing.create(LargeNode) catch {
            self.backing.rawFree(raw[0..len], .fromByteUnits(a), @returnAddress());
            self.subReserved(len);
            self.subLive(len);
            return null;
        };
        node.* = .{ .ptr = raw, .len = len, .align_bytes = a, .idle_since = 0, .next = null };
        self.lockLarge();
        node.next = self.large_list;
        self.large_list = node;
        self.unlockLarge();
        return raw;
    }

    /// 释放大对象：若 idle 回收已启用，缓存到 large_free_list（记录 idle 时间戳）等待复用或超时归还；
    /// 否则立即归还 backing。reserved_bytes 在缓存期间保持不变（内存仍由我们持有），
    /// 由 idle 回收协程或 deinit 时最终归还。
    fn freeLarge(self: *SlabAllocator, buf: []u8, alignment: std.mem.Alignment) void {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);
        // 从 large_list 移除对应 LargeNode
        var found: ?*LargeNode = null;
        self.lockLarge();
        {
            var prev: ?*LargeNode = null;
            var cur = self.large_list;
            while (cur) |n| {
                if (n.ptr == buf.ptr and n.len == buf.len) {
                    if (prev) |p| p.next = n.next else self.large_list = n.next;
                    found = n;
                    break;
                }
                prev = n;
                cur = n.next;
            }
        }

        if (found != null and self.idle_threshold_ms > 0) {
            // idle 回收已启用：缓存到 large_free_list，记录 idle 时间戳
            const n = found.?;
            n.idle_since = nowMs();
            n.next = self.large_free_list;
            self.large_free_list = n;
            self.unlockLarge();
            self.subLive(buf.len);
            // reserved_bytes 不变（内存仍持有，待回收协程或 deinit 归还）
        } else {
            // 无 idle 回收或未找到追踪节点：立即归还 backing
            self.unlockLarge();
            self.subLive(buf.len);
            self.backing.rawFree(buf, .fromByteUnits(a), @returnAddress());
            self.subReserved(buf.len);
            if (found) |n| self.backing.destroy(n);
        }
    }

    // ── idle 回收协程 ──

    /// 启动 idle 回收协程：后台线程定期扫描 empty_slabs 和 large_free_list，
    /// 将空闲超过 idle_threshold_ms 的块归还 backing。
    /// 调用后 single_threaded 被置 false（协程是独立线程，需锁保护共享数据）。
    /// idle_threshold_ms: 空闲阈值（毫秒），建议 3000-10000。
    /// scan_interval_ms: 扫描间隔（毫秒），建议 500-2000。
    pub fn startIdleRecycler(self: *SlabAllocator, idle_threshold_ms: i64, scan_interval_ms: u64) void {
        self.single_threaded = false; // 回收协程是独立线程，必须启用锁 + atomic
        self.idle_threshold_ms = idle_threshold_ms;
        self.scan_interval_ns = scan_interval_ms * std.time.ns_per_ms;
        self.recycler_shutdown.store(false, .seq_cst);
        self.recycler_thread = std.Thread.spawn(.{}, recyclerEntry, .{self}) catch null;
    }

    /// 停止 idle 回收协程：置 shutdown 标志 + join 线程。deinit 前调用。
    fn stopIdleRecycler(self: *SlabAllocator) void {
        if (self.recycler_thread) |t| {
            self.recycler_shutdown.store(true, .seq_cst);
            t.join();
            self.recycler_thread = null;
        }
    }

    /// 回收协程线程入口：循环 sleep → 扫描 → 回收，直到 shutdown 标志置位。
    fn recyclerEntry(self: *SlabAllocator) void {
        const scan_ms: u64 = @intCast(self.scan_interval_ns / std.time.ns_per_ms);
        while (!self.recycler_shutdown.load(.seq_cst)) {
            sleepMs(scan_ms);
            if (self.recycler_shutdown.load(.seq_cst)) break;
            self.evictIdle();
        }
    }

    /// 扫描 empty_slabs 和 large_free_list，归还空闲超时的块到 backing。
    /// 先在锁内收集待回收列表，释放锁后再归还（避免锁嵌套 + 减少锁持有时长）。
    fn evictIdle(self: *SlabAllocator) void {
        const now = nowMs();
        _ = self.evict_scans.fetchAdd(1, .monotonic);

        // ── 回收空闲超时的 empty slab ──
        {
            var to_evict: ?*Slab = null;
            var evicted_count: u64 = 0;
            self.lockEmpty();
            {
                var prev: ?*Slab = null;
                var cur = self.empty_slabs;
                while (cur) |s| {
                    const nxt = s.next;
                    if (now - s.idle_since >= self.idle_threshold_ms) {
                        // 摘除并加入待回收链（复用 next 指针串联）
                        if (prev) |p| p.next = nxt else self.empty_slabs = nxt;
                        self.empty_count -= 1;
                        s.next = to_evict;
                        to_evict = s;
                        cur = nxt;
                        evicted_count += 1;
                    } else {
                        prev = s;
                        cur = nxt;
                    }
                }
            }
            self.unlockEmpty();

            // 释放锁后归还 backing（freeBlock 内部获取 all_lock，避免与 empty_lock 嵌套）
            while (to_evict) |s| {
                const nxt = s.next;
                self.subReserved(SLAB_SIZE);
                self.freeBlock(s);
                to_evict = nxt;
            }
            if (evicted_count > 0) {
                _ = self.evicted_slabs.fetchAdd(evicted_count, .monotonic);
            }
        }

        // ── 回收空闲超时的大对象 ──
        {
            var to_evict: ?*LargeNode = null;
            var evicted_count: u64 = 0;
            self.lockLarge();
            {
                var prev: ?*LargeNode = null;
                var cur = self.large_free_list;
                while (cur) |n| {
                    const nxt = n.next;
                    if (now - n.idle_since >= self.idle_threshold_ms) {
                        if (prev) |p| p.next = nxt else self.large_free_list = nxt;
                        n.next = to_evict;
                        to_evict = n;
                        cur = nxt;
                        evicted_count += 1;
                    } else {
                        prev = n;
                        cur = nxt;
                    }
                }
            }
            self.unlockLarge();

            // 释放锁后归还 backing
            while (to_evict) |n| {
                const nxt = n.next;
                self.backing.rawFree(n.ptr[0..n.len], .fromByteUnits(n.align_bytes), @returnAddress());
                self.subReserved(n.len);
                self.backing.destroy(n);
                to_evict = nxt;
            }
            if (evicted_count > 0) {
                _ = self.evicted_large.fetchAdd(evicted_count, .monotonic);
            }
        }
    }

    // ── 缓存快照 API（profiler 读取）──

    /// 读取 idle 回收累计统计（原子读取，profiler 调用）。
    pub fn getEvictStats(self: *SlabAllocator) struct { scans: u64, slabs: u64, large: u64 } {
        return .{
            .scans = self.evict_scans.load(.monotonic),
            .slabs = self.evicted_slabs.load(.monotonic),
            .large = self.evicted_large.load(.monotonic),
        };
    }

    /// 读取当前缓存规模快照（profiler 调用，需在 deinit 前）。
    /// empty_count 直接读字段（single_threaded 模式安全；多线程由 recycler 协程独占 empty_lock，
    /// 主线程此时不再 alloc/free，无竞态）。large 链长度需遍历计数。
    pub fn getCacheSnapshot(self: *SlabAllocator) struct {
        empty_count: usize,
        large_active: usize,
        large_cached: usize,
    } {
        const ec = self.empty_count;
        var large_active: usize = 0;
        var large_cached: usize = 0;
        // 不加锁遍历（profiler 在 VM 执行后读取，此时无并发修改）
        var ln = self.large_list;
        while (ln) |n| : (ln = n.next) large_active += 1;
        var fn_ = self.large_free_list;
        while (fn_) |n| : (fn_ = n.next) large_cached += 1;
        return .{
            .empty_count = ec,
            .large_active = large_active,
            .large_cached = large_cached,
        };
    }
};

// ============================================================
// vtable — SlabAllocator 的 std.mem.Allocator 接口
// ============================================================

fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));

    if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
        return self.allocLarge(len, alignment);
    }

    const ci = CLASS_LOOKUP[(len + 7) / 8];
    return self.allocSlot(ci, len);
}

fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
    const len = buf.len;

    if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
        self.freeLarge(buf, alignment);
        return;
    }

    self.freeSlot(buf);
}

fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = ret_addr;
    if (buf.len >= LARGE_THRESHOLD or new_len >= LARGE_THRESHOLD) return false;
    if (alignment.toByteUnits() > SLOT_ALIGNMENT) return false;
    // 同 slot 容量内即可原地：slot_size 不变则 OK。
    const slab: *Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
    if (slab.magic != SLAB_MAGIC) return false;
    return new_len <= SIZE_CLASSES[slab.class_idx];
}

fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

// ============================================================
// ThreadCache — per-thread 无锁快路径
// ============================================================

/// 每次 refill/drain 的 slot 数量。32：摊销 SlabAllocator 交互成本，又不占过多缓存。
const BATCH_SIZE: u32 = 32;

/// 每 class 最多缓存的空闲 slot 数。超过则 drain 一个 batch。
/// 64：覆盖典型工作集的 hot class（Cell/ArrayValue/AdtValue 等），限制 over-count。
const MAX_CACHE_PER_CLASS: u32 = 64;

/// 每线程独享的分配缓存。alloc 从 free_lists pop；free 向 free_lists push。
/// free_lists 为空时批量 refill；过满时批量 drain。
/// 单线程使用：一个 ThreadCache 实例 = 一个线程的无锁快路径。
/// 多线程：每个线程创建自己的 ThreadCache（共享底层 SlabAllocator）。
pub const ThreadCache = struct {
    pool: *SlabAllocator,
    free_lists: [NUM_CLASSES]?*FreeNode = [_]?*FreeNode{null} ** NUM_CLASSES,
    free_counts: [NUM_CLASSES]u32 = [_]u32{0} ** NUM_CLASSES,

    // ── 统计计数器（per-instance，单线程使用无需 atomic）──
    /// alloc 快路径命中（free_lists 有缓存）。
    stat_hits: u64 = 0,
    /// alloc 慢路径 miss（触发 refill）。
    stat_misses: u64 = 0,
    /// refill 调用次数。
    stat_refills: u64 = 0,
    /// drain 调用次数。
    stat_drains: u64 = 0,

    pub fn init(pool: *SlabAllocator) ThreadCache {
        return .{ .pool = pool };
    }

    /// 将所有缓存的 slot 归还 SlabAllocator。deinit 前调用。
    /// 走 freeSlotBatch 批量归还（一次 lock + 一次统计），比 vtableFree 逐个释放高效。
    pub fn deinit(self: *ThreadCache) void {
        var batch: [BATCH_SIZE]?[*]u8 = undefined;
        for (&self.free_lists, 0..) |*fl, ci| {
            while (fl.* != null) {
                var n: u32 = 0;
                while (n < BATCH_SIZE) : (n += 1) {
                    const node = fl.* orelse break;
                    fl.* = node.next;
                    batch[n] = @ptrCast(node);
                }
                if (n > 0) self.pool.freeSlotBatch(ci, &batch, n);
            }
            self.free_counts[ci] = 0;
        }
    }

    /// 从 SlabAllocator 批量取 BATCH_SIZE 个 slot 填充 free_lists[ci]。
    /// 走 SlabAllocator.allocSlotBatch：一次 lock + 一次 atomic 统计，
    /// 避免 32 次 vtableAlloc → allocSlot 的 lock/atomic 开销。
    fn refill(self: *ThreadCache, ci: usize) void {
        self.stat_refills += 1;
        var ptrs: [BATCH_SIZE]?[*]u8 = undefined;
        const n = self.pool.allocSlotBatch(ci, BATCH_SIZE, &ptrs);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const ptr = ptrs[i].?;
            const node: *FreeNode = @ptrCast(@alignCast(ptr));
            node.next = self.free_lists[ci];
            self.free_lists[ci] = node;
            self.free_counts[ci] += 1;
        }
    }

    /// 从 free_lists[ci] 取 BATCH_SIZE 个 slot 归还 SlabAllocator。
    /// 走 SlabAllocator.freeSlotBatch：一次 lock + 一次 atomic 统计。
    fn drainBatch(self: *ThreadCache, ci: usize) void {
        self.stat_drains += 1;
        var ptrs: [BATCH_SIZE]?[*]u8 = undefined;
        var n: u32 = 0;
        while (n < BATCH_SIZE) : (n += 1) {
            const node = self.free_lists[ci] orelse break;
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            ptrs[n] = @ptrCast(node);
        }
        if (n > 0) self.pool.freeSlotBatch(ci, &ptrs, n);
    }

    /// alloc：大对象直通 SlabAllocator；小对象先查 free_lists，空则 refill 后再取。
    pub fn alloc(self: *ThreadCache, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            return self.pool.allocator().rawAlloc(len, alignment, @returnAddress());
        }

        const ci = CLASS_LOOKUP[(len + 7) / 8];

        // 快路径：free_lists 有缓存
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            self.stat_hits += 1;
            return @ptrCast(node);
        }

        // 慢路径：refill 后再取
        self.stat_misses += 1;
        self.refill(ci);
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }
        return null; // SlabAllocator 也 OOM
    }

    /// free：大对象直通 SlabAllocator；小对象直接 push free_lists，过满则 drain。
    ///
    /// 从 slab 头读 class_idx 确定 size class（而非用 buf.len 反查 CLASS_LOOKUP）。
    /// 这是为了正确处理 resize 后的场景：调用方可能通过 cacheVtableResize 改变了 buf.len，
    /// 但 slot 实际所属的 size class 由 slab 元数据决定，不会随 resize 改变。
    /// 若用 buf.len 反查，resize 后会查到错误的 size class，把 slot 推入错误的 free_list，
    /// 导致后续 alloc 返回错误大小的内存 → 内存损坏。
    /// 大对象（len ≥ LARGE_THRESHOLD）走 SlabAllocator.freeLarge 路径，不进 free_lists。
    pub fn free(self: *ThreadCache, buf: []u8, alignment: std.mem.Alignment) void {
        const len = buf.len;

        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            self.pool.allocator().rawFree(buf, alignment, @returnAddress());
            return;
        }

        // 从 slab 头读 class_idx（与 SlabAllocator.freeSlot 一致），避免 resize 后 buf.len
        // 不再对应原始 size class 的问题。
        const slab_addr = @intFromPtr(buf.ptr) & SLAB_MASK;
        const slab: *Slab = @ptrFromInt(slab_addr);
        if (slab.magic != SLAB_MAGIC) {
            // 非 slab 分配（理论不应发生），回退到 buf.len 反查以保持兼容
            const ci = CLASS_LOOKUP[(len + 7) / 8];
            const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
            node.next = self.free_lists[ci];
            self.free_lists[ci] = node;
            self.free_counts[ci] += 1;
            if (self.free_counts[ci] > MAX_CACHE_PER_CLASS) {
                self.drainBatch(ci);
            }
            return;
        }
        const ci = slab.class_idx;

        // push 到 free_lists
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = self.free_lists[ci];
        self.free_lists[ci] = node;
        self.free_counts[ci] += 1;

        // 过满则 drain 一个 batch
        if (self.free_counts[ci] > MAX_CACHE_PER_CLASS) {
            self.drainBatch(ci);
        }
    }

    /// ── TypedPool 快路径（已知 class_idx，跳过 magic 校验 + CLASS_LOOKUP）──
    ///
    /// TypedPool(T).acquire 编译期已知 class_idx，调用本方法跳过运行时 CLASS_LOOKUP 反查。
    /// 调用方必须保证：ci 是有效的 class_idx（来自 compile-time CLASS_LOOKUP[(size+7)/8]），
    /// 且本 ThreadCache 是该 slot 的唯一所有者（acquire 自本池）。
    pub inline fn allocKnown(self: *ThreadCache, ci: usize, slot_size: usize) ?[*]u8 {
        _ = slot_size; // slot_size 仅用于统计，alloc 路径无统计（统计在 SlabAllocator.allocSlotBatch）
        // 快路径：free_lists 有缓存
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            self.stat_hits += 1;
            return @ptrCast(node);
        }

        // 慢路径：refill 后再取
        self.stat_misses += 1;
        self.refill(ci);
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }
        return null;
    }

    /// TypedPool(T).release 编译期已知 class_idx，调用本方法跳过 magic 校验 + CLASS_LOOKUP。
    /// 调用方必须保证：ptr 来自本 ThreadCache（或底层 SlabAllocator）的 slab，
    /// 且 ci 是正确的 class_idx（来自 compile-time CLASS_LOOKUP[(size+7)/8]）。
    pub inline fn freeKnown(self: *ThreadCache, ci: usize, ptr: [*]u8) void {
        // push 到 free_lists（跳过 magic 校验 + CLASS_LOOKUP）
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.free_lists[ci];
        self.free_lists[ci] = node;
        self.free_counts[ci] += 1;

        // 过满则 drain 一个 batch
        if (self.free_counts[ci] > MAX_CACHE_PER_CLASS) {
            self.drainBatch(ci);
        }
    }

    /// ── Comptime 特化的类型安全 acquire/release（VM 热路径 API）──
    ///
    /// 编译期已知 T 的 class_idx，跳过 vtable 间接调用 + CLASS_LOOKUP 反查。
    /// 大对象（≥ LARGE_THRESHOLD 或高对齐）回退到 SlabAllocator.allocator()。
    pub inline fn acquireTyped(self: *ThreadCache, comptime T: type) !*T {
        const TP = TypedPool(T);
        if (comptime TP.CLASS_IDX) |ci| {
            const raw = self.allocKnown(ci, @sizeOf(T)) orelse return error.OutOfMemory;
            return @ptrCast(@alignCast(raw));
        }
        return self.pool.allocator().create(T);
    }

    pub inline fn releaseTyped(self: *ThreadCache, comptime T: type, item: *T) void {
        const TP = TypedPool(T);
        if (comptime TP.CLASS_IDX) |ci| {
            const ptr: [*]u8 = @ptrCast(item);
            self.freeKnown(ci, ptr);
            return;
        }
        self.pool.allocator().destroy(item);
    }

    /// 读取 ThreadCache 统计快照（profiler 调用，需在 deinit 前）。
    pub fn getStats(self: *ThreadCache) struct { hits: u64, misses: u64, refills: u64, drains: u64 } {
        return .{
            .hits = self.stat_hits,
            .misses = self.stat_misses,
            .refills = self.stat_refills,
            .drains = self.stat_drains,
        };
    }

    /// 返回实现 std.mem.Allocator 接口的 wrapper（委托给 ThreadCache 的无锁快路径）。
    pub fn allocator(self: *ThreadCache) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = cacheVtableAlloc,
                .resize = cacheVtableResize,
                .remap = cacheVtableRemap,
                .free = cacheVtableFree,
            },
        };
    }
};

// ============================================================
// vtable — ThreadCache 的 std.mem.Allocator 接口
// ============================================================

fn cacheVtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *ThreadCache = @ptrCast(@alignCast(ctx));
    return self.alloc(len, alignment);
}

fn cacheVtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const self: *ThreadCache = @ptrCast(@alignCast(ctx));
    self.free(buf, alignment);
}

fn cacheVtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = ret_addr;
    if (buf.len >= LARGE_THRESHOLD or new_len >= LARGE_THRESHOLD) return false;
    if (alignment.toByteUnits() > SLOT_ALIGNMENT) return false;
    // 委托 SlabAllocator 的 resize 逻辑：检查 slab magic + slot_size 容量
    const slab: *const Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
    if (slab.magic != SLAB_MAGIC) return false;
    // 用 slot_size（由 slab 元数据决定，不受 resize 影响）判断是否可原地扩展
    return new_len <= SIZE_CLASSES[slab.class_idx];
}

fn cacheVtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

// ============================================================
// TypedPool(T) — Comptime 特化的类型安全对象池
// ============================================================

/// Comptime 特化的类型安全对象池。
/// 编译期计算 T 对应的 size class、slot 大小，提供类型安全 acquire/release API。
/// 底层走 SlabAllocator（共享）或 ThreadCache（per-thread 无锁快路径）。
///
/// Comptime 收益：
/// - class_idx 编译期确定，acquire 跳过运行时 CLASS_LOOKUP 反查
/// - slot_size 编译期确定，release 跳过运行时 SIZE_CLASSES 数组访问
/// - 类型安全：acquire 返回 *T，release 接受 *T，避免 @ptrCast 散落
///
/// 用法：
///   var pool = SlabAllocator.init(backing);
///   var typed = TypedPool(Cell).initShared(&pool);
///   const cell = try typed.acquire();
///   cell.* = .{ .rc = 1, .inner = ... };
///   // ... 使用 cell ...
///   cell.inner.release(allocator);  // 调用方负责 deinit
///   typed.release(cell);
pub fn TypedPool(comptime T: type) type {
    const size = @sizeOf(T);
    const align_of_T = @alignOf(T);

    // 编译期计算 class_idx（大对象/高对齐返回 null，走通用路径）
    const class_idx_opt: ?usize = if (size >= LARGE_THRESHOLD or align_of_T > SLOT_ALIGNMENT)
        null
    else
        CLASS_LOOKUP[(size + 7) / 8];

    // 编译期确定 slot 大小（用于 release 路径跳过 SIZE_CLASSES 数组访问）
    const slot_size: usize = if (class_idx_opt) |ci| SIZE_CLASSES[ci] else size;

    return struct {
        const Self = @This();

        /// 后端实现：共享 SlabAllocator 或 per-thread ThreadCache。
        backend: Backend,

        const Backend = union(enum) {
            shared: *SlabAllocator,
            thread_cache: *ThreadCache,
        };

        /// 编译期信息：T 在 SIZE_CLASSES 中的 class_idx（大对象为 null）。
        pub const CLASS_IDX = class_idx_opt;
        /// 编译期信息：T 实际分配的 slot 大小（大对象为 size 本身）。
        pub const SLOT_SIZE = slot_size;
        /// 编译期信息：T 的对齐。
        pub const ALIGNMENT = align_of_T;

        pub fn initShared(pool: *SlabAllocator) Self {
            return .{ .backend = .{ .shared = pool } };
        }

        pub fn initThreadCache(cache: *ThreadCache) Self {
            return .{ .backend = .{ .thread_cache = cache } };
        }

        /// 分配并返回 T 指针。内存未初始化，调用方负责构造 T。
        /// Comptime 特化：若 CLASS_IDX 已知，跳过运行时 CLASS_LOOKUP 反查 + magic 校验。
        pub fn acquire(self: *Self) !*T {
            const alignment: std.mem.Alignment = .fromByteUnits(ALIGNMENT);
            const raw: [*]u8 = switch (self.backend) {
                .shared => |p| blk: {
                    // Comptime fast path：class_idx 已知
                    if (CLASS_IDX) |ci| {
                        break :blk p.allocSlot(ci, size) orelse return error.OutOfMemory;
                    }
                    break :blk p.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
                },
                .thread_cache => |c| blk: {
                    if (CLASS_IDX) |ci| {
                        // 走 allocKnown 快路径：跳过 CLASS_LOOKUP + len/alignment 检查
                        break :blk c.allocKnown(ci, size) orelse return error.OutOfMemory;
                    }
                    break :blk c.pool.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
                },
            };
            return @ptrCast(@alignCast(raw));
        }

        /// 释放 T 指针。调用方负责先调用 T 的 deinit（如有）。
        /// Comptime 特化：CLASS_IDX 已知时，走 freeKnown 快路径
        /// （跳过 magic 校验 + CLASS_LOOKUP + len/alignment 检查 + slice 构造）。
        pub fn release(self: *Self, item: *T) void {
            switch (self.backend) {
                .shared => |p| blk: {
                    if (CLASS_IDX) |ci| {
                        // 小对象：走 freeSlotKnown 快路径（跳过 magic 校验）
                        const ptr: [*]u8 = @ptrCast(item);
                        p.freeSlotKnown(ci, ptr);
                        break :blk;
                    }
                    // 大对象：走 allocator 接口
                    const slice: []T = @as([*]T, @ptrCast(item))[0..1];
                    p.allocator().free(slice);
                },
                .thread_cache => |c| blk: {
                    if (CLASS_IDX) |ci| {
                        // 走 freeKnown 快路径：跳过 magic 校验 + CLASS_LOOKUP
                        const ptr: [*]u8 = @ptrCast(item);
                        c.freeKnown(ci, ptr);
                        break :blk;
                    }
                    const buf: []u8 = @as([*]u8, @ptrCast(item))[0..size];
                    c.pool.allocator().rawFree(buf, .fromByteUnits(ALIGNMENT), @returnAddress());
                },
            }
        }
    };
}

// ============================================================
// 单元测试
// ============================================================

const testing = std.testing;

test "comptime SIZE_CLASSES includes box types" {
    // 验证装箱类型大小在 SIZE_CLASSES 中有精确档位（无内部碎片）
    inline for (BOX_TYPES) |T| {
        const sz: u32 = @intCast(@sizeOf(T));
        var found = false;
        for (SIZE_CLASSES) |s| {
            if (s == sz) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "comptime CLASS_LOOKUP correctness" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 各 size class 都应成功分配且 8 对齐
    for (SIZE_CLASSES) |sz| {
        const buf = a.alloc(u8, sz) catch unreachable;
        try testing.expect(@intFromPtr(buf.ptr) % SLOT_ALIGNMENT == 0);
        a.free(buf);
    }
}

test "SlabAllocator basic alloc/free roundtrip" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const sizes = [_]usize{ 16, 32, 40, 48, 56, 64, 80, 96, 112, 128, 200, 512, 1024, 4095 };
    for (sizes) |sz| {
        const buf = a.alloc(u8, sz) catch unreachable;
        try testing.expect(@intFromPtr(buf.ptr) % SLOT_ALIGNMENT == 0);
        a.free(buf);
    }
}

test "SlabAllocator slab reverse-lookup via mask" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    var bufs: [64][]u8 = undefined;
    for (&bufs) |*b| b.* = a.alloc(u8, 64) catch unreachable;
    for (bufs) |b| a.free(b);
}

test "SlabAllocator empty slab caching within MAX_EMPTY_SLABS" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 分配超过 MAX_EMPTY_SLABS 能容纳的 slot 数，确保部分 slab 全空后超上限归还 backing。
    var list = std.ArrayList([]u8).empty;
    defer list.deinit(testing.allocator);
    const slots_per_slab = (SLAB_SIZE - 128) / 64; // 保守估算（扣除 Slab 头 + 对齐）
    const total_allocs = (MAX_EMPTY_SLABS + 16) * slots_per_slab;
    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        list.append(testing.allocator, a.alloc(u8, 64) catch unreachable) catch unreachable;
    }
    const peak = pool.reserved_bytes.load(.monotonic);
    for (list.items) |b| a.free(b);

    // 全 free 后：reserved 回落到 <= MAX_EMPTY_SLABS 个空 slab（超出部分已归还 backing）
    try testing.expect(pool.reserved_bytes.load(.monotonic) <= MAX_EMPTY_SLABS * SLAB_SIZE);
    // 超量分配确保 peak > MAX_EMPTY_SLABS * SLAB_SIZE，故 free 后 reserved < peak
    try testing.expect(pool.reserved_bytes.load(.monotonic) < peak);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes.load(.monotonic));
}

test "SlabAllocator large objects bypass slabs" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const big = a.alloc(u8, 100 * 1024) catch unreachable;
    // 大对象不登记 HashMap，直接走 backing。live_bytes 仍统计。
    try testing.expectEqual(@as(usize, 100 * 1024), pool.live_bytes.load(.monotonic));
    a.free(big);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes.load(.monotonic));
}

test "SlabAllocator multi-threaded contention" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const ThreadCtx = struct {
        alloc: std.mem.Allocator,
        iters: usize,
        errors: std.atomic.Value(u32) = .{ .raw = 0 },

        fn run(ctx: *@This()) void {
            var live = std.ArrayList([]u8).empty;
            defer {
                for (live.items) |b| ctx.alloc.free(b);
                live.deinit(testing.allocator);
            }
            var i: usize = 0;
            while (i < ctx.iters) : (i += 1) {
                const sz: usize = switch (i % 4) {
                    0 => 32,
                    1 => 48,
                    2 => 64,
                    else => 128,
                };
                const buf = ctx.alloc.alloc(u8, sz) catch {
                    _ = ctx.errors.fetchAdd(1, .monotonic);
                    continue;
                };
                live.append(testing.allocator, buf) catch {
                    ctx.alloc.free(buf);
                    continue;
                };
                if (live.items.len > 100) {
                    ctx.alloc.free(live.orderedRemove(0));
                }
            }
        }
    };

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;
    var ctxs: [num_threads]ThreadCtx = undefined;
    for (&ctxs) |*c| c.* = .{ .alloc = a, .iters = 10000 };
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctxs[i]});
    for (threads) |t| t.join();

    // 检查无错误
    var total_errors: u32 = 0;
    for (ctxs) |c| total_errors += c.errors.load(.monotonic);
    try testing.expectEqual(@as(u32, 0), total_errors);

    // 全部释放后 live_bytes 应归零
    try testing.expectEqual(@as(usize, 0), pool.live_bytes.load(.monotonic));
}

test "ThreadCache fast path roundtrip" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    var cache = ThreadCache.init(&pool);
    defer cache.deinit();
    const a = cache.allocator();

    var bufs: [100][]u8 = undefined;
    for (&bufs) |*b| b.* = a.alloc(u8, 48) catch unreachable;
    for (bufs) |b| a.free(b);
}

test "ThreadCache refill/drain under churn" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    var cache = ThreadCache.init(&pool);
    defer cache.deinit();
    const a = cache.allocator();

    var live = std.ArrayList([]u8).empty;
    defer {
        for (live.items) |b| a.free(b);
        live.deinit(testing.allocator);
    }
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const buf = a.alloc(u8, 48) catch unreachable;
        live.append(testing.allocator, buf) catch unreachable;
        if (live.items.len > 100) {
            a.free(live.orderedRemove(0));
        }
    }
}

test "TypedPool type safety" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    var typed = TypedPool(value.Cell).initShared(&pool);

    const cell = try typed.acquire();
    defer typed.release(cell);
    cell.* = .{ .rc = 1, .inner = .{ .unit = {} } };
    try testing.expectEqual(@as(u32, 1), cell.rc);

    // 编译期信息验证
    try testing.expect(TypedPool(value.Cell).CLASS_IDX != null);
    try testing.expectEqual(@sizeOf(value.Cell), TypedPool(value.Cell).SLOT_SIZE);
}

test "TypedPool via ThreadCache" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    var cache = ThreadCache.init(&pool);
    defer cache.deinit();
    var typed = TypedPool(value.Cell).initThreadCache(&cache);

    var cells: [10]*value.Cell = undefined;
    for (&cells) |*c| c.* = try typed.acquire();
    for (cells) |c| typed.release(c);
}

test "TypedPool large object fallback" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();

    // 大对象：class_idx 为 null，走通用路径
    const Large = struct { data: [8192]u8 };
    var typed = TypedPool(Large).initShared(&pool);

    try testing.expectEqual(@as(?usize, null), TypedPool(Large).CLASS_IDX);

    const obj = try typed.acquire();
    defer typed.release(obj);
    obj.data[0] = 42;
    try testing.expectEqual(@as(u8, 42), obj.data[0]);
}

test "free non-slab pointer is safely ignored" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 用 testing.allocator 分配的非 slab 指针测试 magic check 路径
    const buf = testing.allocator.alloc(u8, 64) catch unreachable;
    defer testing.allocator.free(buf);
    a.free(buf); // 不会 panic（magic 不匹配 → SlabAllocator 安全忽略）
}
