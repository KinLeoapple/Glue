//! Slab 分配器模块。
//!
//! 实现基于大小分级的 slab 内存分配器，支持：
//! - 编译期生成的尺寸分级表（包含语言运行时常用装箱类型的尺寸）。
//! - 按 slab 管理的小对象分配与空闲链表回收。
//! - 超过阈值的大对象直接走底层分配器并缓存复用。
//! - 线程本地缓存（`ThreadCache`）减少锁竞争。
//! - 类型化对象池（`TypedPool`）提供类型安全的获取/释放。
//! - 后台空闲回收线程定期驱逐长期闲置的 slab 与大块。

const std = @import("std");

/// 平台自适应计数器类型：64 位平台用 u64，32 位平台用 u32（避免 64 位原子不支持）。
const Counter = if (@sizeOf(usize) >= 8) u64 else u32;
const value = @import("value");
const sync = @import("sync");
const Mutex = sync.Mutex;

// 基础尺寸分级表，覆盖常见的小对象大小。
const BASE_CLASSES = [_]u32{
    16,   24,   32,   40,   48,   56,   64,   72,
    80,   88,   96,   104,  112,  120,  128,
    144,  160,  176,  192,  208,  224,  240,  256,
    320,  384,  448,  512,
    640,  768,  896,  1024,
    1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096,
};

// 运行时常用装箱类型，其尺寸会被合并到分级表中以获得精确匹配的 slab。
const BOX_TYPES = [_]type{
    value.AdtValue,
    value.NewtypeValue,
    value.ArrayValue,
    value.RecordValue,
    value.Cell,
    value.Range,
};

// 将基础分级与装箱类型尺寸合并为候选数组。
const ALL_CANDIDATES = blk: {
    var arr: [BASE_CLASSES.len + BOX_TYPES.len]u32 = undefined;
    for (BASE_CLASSES, 0..) |s, i| arr[i] = s;
    for (BOX_TYPES, 0..) |T, i| arr[BASE_CLASSES.len + i] = @intCast(@sizeOf(T));
    break :blk arr;
};

// 编译期插入排序，用于对候选尺寸数组排序。
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

/// 排序并去重后的最终尺寸分级表。
pub const SIZE_CLASSES: [uniqueLen()]u32 = blk: {
    @setEvalBranchQuota(10000);
    var arr = ALL_CANDIDATES;
    comptimeSort(u32, &arr);
    // 去重：将唯一值压缩到数组前端。
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

// 计算去重后的分级表长度。
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

/// 尺寸分级总数。
pub const NUM_CLASSES = SIZE_CLASSES.len;

/// 超过此阈值的对象走大对象路径，不进入 slab。
pub const LARGE_THRESHOLD: usize = 4097;

/// 槽位对齐要求，所有小对象分配均按此对齐。
pub const SLOT_ALIGNMENT: usize = 8;

/// 单个 slab 的物理大小。
pub const SLAB_SIZE: usize = 16 * 1024;

/// slab 地址掩码，用于从槽位指针反查所属 slab。
pub const SLAB_MASK: usize = ~(SLAB_SIZE - 1);

const SLAB_ALIGN: std.mem.Alignment = .fromByteUnits(SLAB_SIZE);

// 查找表长度：覆盖从 0 到 LARGE_THRESHOLD 按 8 字节对齐的所有尺寸。
const LOOKUP_LEN = LARGE_THRESHOLD / 8 + 1;

/// 尺寸到分级索引的快速查找表。输入为 (len+7)/8，输出为分级下标。
pub const CLASS_LOOKUP: [LOOKUP_LEN]u8 = blk: {
    @setEvalBranchQuota(10000);
    var lookup: [LOOKUP_LEN]u8 = [_]u8{0} ** LOOKUP_LEN;
    var ci: usize = 0;
    var lk: usize = 0;
    while (lk < LOOKUP_LEN) : (lk += 1) {
        const need: u32 = @intCast(lk * 8);
        // 找到第一个能容纳 need 的分级。
        while (ci < NUM_CLASSES - 1 and SIZE_CLASSES[ci] < need) ci += 1;
        lookup[lk] = @intCast(ci);
    }
    break :blk lookup;
};

/// 空闲链表节点，复用槽位内存存储链表指针。
pub const FreeNode = struct {
    next: ?*FreeNode,
};

// 大对象追踪节点，记录大块内存的元信息。
const LargeNode = struct {
    ptr: [*]u8,
    len: usize,
    align_bytes: usize,
    next: ?*LargeNode,
    idle_since: i64 = 0,
};

/// slab 头部魔数，用于校验指针确实指向 slab。
pub const SLAB_MAGIC: u64 = 0x5142_5F4C_4F4F_50AB;

// slab 头部，管理单个 slab 内的槽位分配状态。
const Slab = struct {
    magic: u64,
    class_idx: u8,
    used: u32,
    total: u32,
    bump: u32,
    slots_offset: u32,
    free_list: ?*FreeNode,
    next: ?*Slab,
    prev: ?*Slab,
    all_next: ?*Slab = null,
    idle_since: i64 = 0,
};

// 单个尺寸分级的运行时状态，包含部分满 slab 链表与锁。
const Class = struct {
    slot_size: u32,
    partial: ?*Slab = null,
    lock: Mutex = .{},
};

// 空闲 slab 缓存上限，超过则直接归还底层。
const MAX_EMPTY_SLABS: usize = 64;

// 获取当前毫秒时间戳。
fn nowMs() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// 毫秒级睡眠，用于回收线程的周期等待。
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

/// Slab 分配器主体。
///
/// 维护按尺寸分级的 slab 集合、空闲 slab 缓存与大对象缓存，
/// 支持多线程与单线程两种模式。可选启动后台回收线程驱逐闲置内存。
pub const SlabAllocator = struct {
    backing: std.mem.Allocator,
    classes: [NUM_CLASSES]Class,
    empty_slabs: ?*Slab = null,
    empty_count: usize = 0,
    empty_lock: Mutex = .{},
    all_slabs: ?*Slab = null,
    all_lock: Mutex = .{},
    large_list: ?*LargeNode = null,
    large_lock: Mutex = .{},
    large_free_list: ?*LargeNode = null,
    idle_threshold_ms: i64 = 0,
    scan_interval_ns: u64 = 0,
    recycler_thread: ?std.Thread = null,
    recycler_shutdown: std.atomic.Value(bool) = .{ .raw = false },
    evict_scans: std.atomic.Value(Counter) = .{ .raw = 0 },
    evicted_slabs: std.atomic.Value(Counter) = .{ .raw = 0 },
    evicted_large: std.atomic.Value(Counter) = .{ .raw = 0 },
    live_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    reserved_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    peak_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    live_peak_bytes: std.atomic.Value(usize) = .{ .raw = 0 },
    single_threaded: bool = false,

    /// 创建多线程模式的分配器。
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

    /// 创建单线程模式的分配器，跳过所有锁操作。
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

    /// 停止回收线程并释放所有 slab 与大对象内存。
    pub fn deinit(self: *SlabAllocator) void {
        self.stopIdleRecycler();
        // 释放所有 slab 块。
        var cur = self.all_slabs;
        while (cur) |s| {
            const nxt = s.all_next;
            const block_ptr: [*]u8 = @ptrCast(s);
            self.backing.rawFree(block_ptr[0..SLAB_SIZE], SLAB_ALIGN, @returnAddress());
            cur = nxt;
        }
        self.all_slabs = null;
        // 释放所有活跃大对象。
        var ln = self.large_list;
        while (ln) |n| {
            const nxt = n.next;
            self.backing.rawFree(n.ptr[0..n.len], .fromByteUnits(n.align_bytes), @returnAddress());
            self.backing.destroy(n);
            ln = nxt;
        }
        self.large_list = null;
        // 释放所有缓存大对象。
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

    /// 返回符合 `std.mem.Allocator` 接口的分配器句柄。
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

    // 增加活跃字节数并更新峰值。
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

    // 减少活跃字节数。
    inline fn subLive(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.live_bytes.raw -= n;
            return;
        }
        _ = self.live_bytes.fetchSub(n, .monotonic);
    }

    // 增加预留字节数并更新峰值。
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

    // 减少预留字节数。
    inline fn subReserved(self: *SlabAllocator, n: usize) void {
        if (self.single_threaded) {
            self.reserved_bytes.raw -= n;
            return;
        }
        _ = self.reserved_bytes.fetchSub(n, .monotonic);
    }

    // 以下为各粒度的加锁辅助，单线程模式下均为空操作。
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

    // 从全局 slab 链表中移除并释放一个 slab 块。
    fn freeBlock(self: *SlabAllocator, slab: *Slab) void {
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

    // 获取一个 slab：优先复用空闲缓存，否则从底层分配新块。
    fn newSlab(self: *SlabAllocator, class_idx: usize) ?*Slab {
        var slab: *Slab = undefined;
        var is_new = false;
        self.lockEmpty();
        if (self.empty_slabs) |cached| {
            // 复用缓存的空闲 slab。
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
            // 新分配的 slab 需登记到全局链表。
            self.lockAll();
            slab.all_next = self.all_slabs;
            self.all_slabs = slab;
            self.unlockAll();
        }
        return slab;
    }

    // 回收一个空闲 slab：优先进入缓存，缓存满则归还底层。
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

    // 从 slab 中取一个槽位：优先空闲链表，否则 bump 分配。
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

    // 判断 slab 是否还有可用槽位。
    fn slabHasRoom(slab: *Slab) bool {
        return slab.free_list != null or slab.bump < slab.total;
    }

    // 将 slab 插入分级部分满链表头部。
    fn partialPush(c: *Class, slab: *Slab) void {
        slab.prev = null;
        slab.next = c.partial;
        if (c.partial) |h| h.prev = slab;
        c.partial = slab;
    }

    // 从分级部分满链表中移除 slab。
    fn partialRemove(c: *Class, slab: *Slab) void {
        if (slab.prev) |p| p.next = slab.next else c.partial = slab.next;
        if (slab.next) |n| n.prev = slab.prev;
        slab.prev = null;
        slab.next = null;
    }

    // 在指定分级中分配一个槽位。
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
        // 无部分满 slab，新建一个。
        const slab = self.newSlab(ci) orelse return null;
        SlabAllocator.partialPush(c, slab);
        const ptr = SlabAllocator.slabTake(slab);
        if (!SlabAllocator.slabHasRoom(slab)) SlabAllocator.partialRemove(c, slab);
        self.addLive(len);
        return ptr;
    }

    // 批量分配槽位，用于线程缓存填充。
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

    // 通过指针掩码反查 slab 并释放槽位。
    fn freeSlot(self: *SlabAllocator, buf: []u8) void {
        const slab: *Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
        if (slab.magic != SLAB_MAGIC) return;
        const ci = slab.class_idx;
        const c = &self.classes[ci];
        self.lockClass(c);
        defer self.unlockClass(c);
        const was_full = !SlabAllocator.slabHasRoom(slab);
        // 将释放的槽位挂入空闲链表。
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = slab.free_list;
        slab.free_list = node;
        slab.used -= 1;
        self.subLive(buf.len);
        if (slab.used == 0) {
            // slab 完全空闲，回收或归还。
            if (!was_full) SlabAllocator.partialRemove(c, slab);
            self.recycleSlab(slab);
        } else if (was_full) {
            // 从满变非满，重新加入部分满链表。
            SlabAllocator.partialPush(c, slab);
        }
    }

    // 已知分级索引时释放槽位，省去查表开销。
    fn freeSlotKnown(self: *SlabAllocator, ci: usize, ptr: [*]u8) void {
        const c = &self.classes[ci];
        const slab: *Slab = @ptrFromInt(@intFromPtr(ptr) & SLAB_MASK);
        self.lockClass(c);
        defer self.unlockClass(c);
        const was_full = !SlabAllocator.slabHasRoom(slab);
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

    // 批量释放槽位，用于线程缓存回填。
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

    // 分配大对象：优先复用缓存，否则从底层分配。
    fn allocLarge(self: *SlabAllocator, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);
        self.lockLarge();
        {
            // 在空闲大对象缓存中查找尺寸匹配的块。
            var prev: ?*LargeNode = null;
            var cur = self.large_free_list;
            while (cur) |n| {
                if (n.len == len and n.align_bytes >= a) {
                    if (prev) |p| p.next = n.next else self.large_free_list = n.next;
                    n.idle_since = 0;
                    n.next = self.large_list;
                    self.large_list = n;
                    self.unlockLarge();
                    self.addLive(len);
                    return n.ptr;
                }
                prev = n;
                cur = n.next;
            }
        }
        self.unlockLarge();
        // 缓存未命中，从底层分配新块。
        const raw = self.backing.rawAlloc(len, .fromByteUnits(a), @returnAddress()) orelse return null;
        self.addReserved(len);
        self.addLive(len);
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

    // 释放大对象：有回收阈值时进入缓存，否则直接归还底层。
    fn freeLarge(self: *SlabAllocator, buf: []u8, alignment: std.mem.Alignment) void {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);
        var found: ?*LargeNode = null;
        self.lockLarge();
        {
            // 在活跃大对象链表中查找匹配的节点。
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
            // 进入空闲缓存，等待复用或被回收线程驱逐。
            const n = found.?;
            n.idle_since = nowMs();
            n.next = self.large_free_list;
            self.large_free_list = n;
            self.unlockLarge();
            self.subLive(buf.len);
        } else {
            // 无回收机制，直接归还底层。
            self.unlockLarge();
            self.subLive(buf.len);
            self.backing.rawFree(buf, .fromByteUnits(a), @returnAddress());
            self.subReserved(buf.len);
            if (found) |n| self.backing.destroy(n);
        }
    }

    /// 启动后台空闲回收线程。`idle_threshold_ms` 为闲置阈值，`scan_interval_ms` 为扫描间隔。
    pub fn startIdleRecycler(self: *SlabAllocator, idle_threshold_ms: i64, scan_interval_ms: u64) void {
        self.single_threaded = false;
        self.idle_threshold_ms = idle_threshold_ms;
        self.scan_interval_ns = scan_interval_ms * std.time.ns_per_ms;
        self.recycler_shutdown.store(false, .seq_cst);
        self.recycler_thread = std.Thread.spawn(.{}, recyclerEntry, .{self}) catch null;
    }

    // 通知回收线程退出并等待其结束。
    fn stopIdleRecycler(self: *SlabAllocator) void {
        if (self.recycler_thread) |t| {
            self.recycler_shutdown.store(true, .seq_cst);
            t.join();
            self.recycler_thread = null;
        }
    }

    // 回收线程入口：周期性扫描并驱逐闲置内存。
    fn recyclerEntry(self: *SlabAllocator) void {
        const scan_ms: u64 = @intCast(self.scan_interval_ns / std.time.ns_per_ms);
        while (!self.recycler_shutdown.load(.seq_cst)) {
            sleepMs(scan_ms);
            if (self.recycler_shutdown.load(.seq_cst)) break;
            self.evictIdle();
        }
    }

    // 扫描并驱逐超过闲置阈值的空闲 slab 与大对象。
    fn evictIdle(self: *SlabAllocator) void {
        const now = nowMs();
        _ = self.evict_scans.fetchAdd(1, .monotonic);
        {
            // 驱逐闲置空闲 slab。
            var to_evict: ?*Slab = null;
            var evicted_count: Counter = 0;
            self.lockEmpty();
            {
                var prev: ?*Slab = null;
                var cur = self.empty_slabs;
                while (cur) |s| {
                    const nxt = s.next;
                    if (now - s.idle_since >= self.idle_threshold_ms) {
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
            // 释放被驱逐的 slab。
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
        {
            // 驱逐闲置大对象缓存。
            var to_evict: ?*LargeNode = null;
            var evicted_count: Counter = 0;
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

    /// 返回回收统计：扫描次数、驱逐 slab 数、驱逐大对象数。
    pub fn getEvictStats(self: *SlabAllocator) struct { scans: u64, slabs: u64, large: u64 } {
        return .{
            .scans = @intCast(self.evict_scans.load(.monotonic)),
            .slabs = @intCast(self.evicted_slabs.load(.monotonic)),
            .large = @intCast(self.evicted_large.load(.monotonic)),
        };
    }

    /// 返回缓存快照：空闲 slab 数、活跃大对象数、缓存大对象数。
    pub fn getCacheSnapshot(self: *SlabAllocator) struct {
        empty_count: usize,
        large_active: usize,
        large_cached: usize,
    } {
        const ec = self.empty_count;
        var large_active: usize = 0;
        var large_cached: usize = 0;
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

// ===== SlabAllocator 的 vtable 实现 =====

fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
    // 大对象或高对齐要求走大对象路径。
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
    // 仅支持同分级内的原地缩小判断。
    if (buf.len >= LARGE_THRESHOLD or new_len >= LARGE_THRESHOLD) return false;
    if (alignment.toByteUnits() > SLOT_ALIGNMENT) return false;
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

// 批量操作的单次批量大小与每类缓存上限。
const BATCH_SIZE: u32 = 32;
const MAX_CACHE_PER_CLASS: u32 = 64;

/// 线程本地缓存，减少对全局 slab 分配器的锁竞争。
///
/// 每个线程维护各分级的空闲链表，分配命中时直接取用，
/// 未命中时批量从全局分配器补充，超额时批量回填。
pub const ThreadCache = struct {
    pool: *SlabAllocator,
    free_lists: [NUM_CLASSES]?*FreeNode = [_]?*FreeNode{null} ** NUM_CLASSES,
    free_counts: [NUM_CLASSES]u32 = [_]u32{0} ** NUM_CLASSES,
    stat_hits: u64 = 0,
    stat_misses: u64 = 0,
    stat_refills: u64 = 0,
    stat_drains: u64 = 0,

    /// 绑定到指定全局分配器创建线程缓存。
    pub fn init(pool: *SlabAllocator) ThreadCache {
        return .{ .pool = pool };
    }

    /// 释放时将所有缓存槽位批量归还给全局分配器。
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

    // 从全局分配器批量补充槽位到本地缓存。
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

    // 将本地缓存中超额的槽位批量回填给全局分配器。
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

    /// 通用分配接口，大对象委托给全局分配器。
    pub fn alloc(self: *ThreadCache, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            return self.pool.allocator().rawAlloc(len, alignment, @returnAddress());
        }
        const ci = CLASS_LOOKUP[(len + 7) / 8];
        // 快速路径：本地缓存命中。
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            self.stat_hits += 1;
            return @ptrCast(node);
        }
        // 慢速路径：补充后重试。
        self.stat_misses += 1;
        self.refill(ci);
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }
        return null;
    }

    /// 通用释放接口，大对象委托给全局分配器。
    pub fn free(self: *ThreadCache, buf: []u8, alignment: std.mem.Alignment) void {
        const len = buf.len;
        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            self.pool.allocator().rawFree(buf, alignment, @returnAddress());
            return;
        }
        const slab_addr = @intFromPtr(buf.ptr) & SLAB_MASK;
        const slab: *Slab = @ptrFromInt(slab_addr);
        if (slab.magic != SLAB_MAGIC) {
            // 非 slab 指针，按尺寸分级缓存。
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
        // slab 指针，使用 slab 的分级索引。
        const ci = slab.class_idx;
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = self.free_lists[ci];
        self.free_lists[ci] = node;
        self.free_counts[ci] += 1;
        if (self.free_counts[ci] > MAX_CACHE_PER_CLASS) {
            self.drainBatch(ci);
        }
    }

    /// 已知分级索引的快速分配。
    pub inline fn allocKnown(self: *ThreadCache, ci: usize, slot_size: usize) ?[*]u8 {
        _ = slot_size;
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            self.stat_hits += 1;
            return @ptrCast(node);
        }
        self.stat_misses += 1;
        self.refill(ci);
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }
        return null;
    }

    /// 已知分级索引的快速释放。
    pub inline fn freeKnown(self: *ThreadCache, ci: usize, ptr: [*]u8) void {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.free_lists[ci];
        self.free_lists[ci] = node;
        self.free_counts[ci] += 1;
        if (self.free_counts[ci] > MAX_CACHE_PER_CLASS) {
            self.drainBatch(ci);
        }
    }

    /// 类型化获取：尺寸匹配分级时走快速路径，否则委托全局分配器。
    pub inline fn acquireTyped(self: *ThreadCache, comptime T: type) !*T {
        const TP = TypedPool(T);
        if (comptime TP.CLASS_IDX) |ci| {
            const raw = self.allocKnown(ci, @sizeOf(T)) orelse return error.OutOfMemory;
            return @ptrCast(@alignCast(raw));
        }
        return self.pool.allocator().create(T);
    }

    /// 类型化释放：与 `acquireTyped` 配对。
    pub inline fn releaseTyped(self: *ThreadCache, comptime T: type, item: *T) void {
        const TP = TypedPool(T);
        if (comptime TP.CLASS_IDX) |ci| {
            const ptr: [*]u8 = @ptrCast(item);
            self.freeKnown(ci, ptr);
            return;
        }
        self.pool.allocator().destroy(item);
    }

    /// 返回缓存命中/未命中/补充/回填统计。
    pub fn getStats(self: *ThreadCache) struct { hits: u64, misses: u64, refills: u64, drains: u64 } {
        return .{
            .hits = self.stat_hits,
            .misses = self.stat_misses,
            .refills = self.stat_refills,
            .drains = self.stat_drains,
        };
    }

    /// 返回符合 `std.mem.Allocator` 接口的分配器句柄。
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

// ===== ThreadCache 的 vtable 实现 =====

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
    const slab: *const Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
    if (slab.magic != SLAB_MAGIC) return false;
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

/// 类型化对象池，为特定类型提供类型安全的获取与释放。
///
/// 编译期计算类型的尺寸分级，匹配时走 slab 快速路径，
/// 过大或不满足对齐时回退到底层分配器。
pub fn TypedPool(comptime T: type) type {
    const size = @sizeOf(T);
    const align_of_T = @alignOf(T);
    // 编译期确定类型所属的分级索引，无法匹配时为 null。
    const class_idx_opt: ?usize = if (size >= LARGE_THRESHOLD or align_of_T > SLOT_ALIGNMENT)
        null
    else
        CLASS_LOOKUP[(size + 7) / 8];
    const slot_size: usize = if (class_idx_opt) |ci| SIZE_CLASSES[ci] else size;
    return struct {
        const Self = @This();
        backend: Backend,

        const Backend = union(enum) {
            shared: *SlabAllocator,
            thread_cache: *ThreadCache,
        };

        /// 类型对应的分级索引，无法走 slab 时为 null。
        pub const CLASS_IDX = class_idx_opt;
        /// 实际使用的槽位大小。
        pub const SLOT_SIZE = slot_size;
        /// 类型的对齐要求。
        pub const ALIGNMENT = align_of_T;

        /// 绑定全局分配器创建类型化池。
        pub fn initShared(pool: *SlabAllocator) Self {
            return .{ .backend = .{ .shared = pool } };
        }

        /// 绑定线程缓存创建类型化池。
        pub fn initThreadCache(cache: *ThreadCache) Self {
            return .{ .backend = .{ .thread_cache = cache } };
        }

        /// 获取一个类型化对象实例。
        pub fn acquire(self: *Self) !*T {
            const alignment: std.mem.Alignment = .fromByteUnits(ALIGNMENT);
            const raw: [*]u8 = switch (self.backend) {
                .shared => |p| blk: {
                    if (CLASS_IDX) |ci| {
                        break :blk p.allocSlot(ci, size) orelse return error.OutOfMemory;
                    }
                    break :blk p.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
                },
                .thread_cache => |c| blk: {
                    if (CLASS_IDX) |ci| {
                        break :blk c.allocKnown(ci, size) orelse return error.OutOfMemory;
                    }
                    break :blk c.pool.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
                },
            };
            return @ptrCast(@alignCast(raw));
        }

        /// 释放一个类型化对象实例。
        pub fn release(self: *Self, item: *T) void {
            switch (self.backend) {
                .shared => |p| blk: {
                    if (CLASS_IDX) |ci| {
                        const ptr: [*]u8 = @ptrCast(item);
                        p.freeSlotKnown(ci, ptr);
                        break :blk;
                    }
                    const slice: []T = @as([*]T, @ptrCast(item))[0..1];
                    p.allocator().free(slice);
                },
                .thread_cache => |c| blk: {
                    if (CLASS_IDX) |ci| {
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

const testing = std.testing;

test "comptime SIZE_CLASSES includes box types" {
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
    var list = std.ArrayList([]u8).empty;
    defer list.deinit(testing.allocator);
    const slots_per_slab = (SLAB_SIZE - 128) / 64;
    const total_allocs = (MAX_EMPTY_SLABS + 16) * slots_per_slab;
    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        list.append(testing.allocator, a.alloc(u8, 64) catch unreachable) catch unreachable;
    }
    const peak = pool.reserved_bytes.load(.monotonic);
    for (list.items) |b| a.free(b);
    try testing.expect(pool.reserved_bytes.load(.monotonic) <= MAX_EMPTY_SLABS * SLAB_SIZE);
    try testing.expect(pool.reserved_bytes.load(.monotonic) < peak);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes.load(.monotonic));
}

test "SlabAllocator large objects bypass slabs" {
    var pool = SlabAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();
    const big = a.alloc(u8, 100 * 1024) catch unreachable;
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
    var total_errors: u32 = 0;
    for (ctxs) |c| total_errors += c.errors.load(.monotonic);
    try testing.expectEqual(@as(u32, 0), total_errors);
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
    const buf = testing.allocator.alloc(u8, 64) catch unreachable;
    defer testing.allocator.free(buf);
    a.free(buf);
}
