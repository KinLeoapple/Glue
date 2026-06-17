//! Segregated Slab Pool — 段式 slab 分配器
//!
//! 目标：min(内存 + 碎片) s.t. 速度不退（偏速度的平衡）。
//!
//! 设计要点：
//! - 段式 size class：同一桶内所有 slot 等大，永不分裂/合并 → 外部碎片 = 0。
//! - size class 表低段 8B 步进精确贴合 Value 箱体（实测 Value=64/Array=40/Adt=56/
//!   Record=64/AdtField=80/Newtype=96/Partial=112/Lazy=128），定长箱体内部碎片≈0；
//!   高段 ~1.25× 几何步进，内部碎片 ≤ ~12.5%。
//! - slot 全部 16 对齐（满足 Value 的 @alignOf=16）。
//! - slab 块按 SLAB_SIZE(64KB) 对齐，头部内嵌于块首：free 时用指针掩码
//!   `ptr & ~(SLAB_SIZE-1)` O(1) 反查所属 slab。
//! - 每 slab 独立 free_list + bump + used 计数：empty slab 归还 O(1)，无需扫描全局链。
//! - 空 slab 归还：每 class 保留 1 个空 slab 作 buffer 防抖动，第 2 个起立即归还
//!   backing → 内存随死对象真回落，不焊在峰值。
//! - alloc/free 均 O(1)：freelist push/pop + 查表取整。
//!
//! 用途：替代 gc.zig 的 OldGenAllocator（first-fit + 分裂，碎片源）；
//! 作为主求值器的 value_allocator（运行期 Value 箱体/载荷），rc 归零 release 即还桶。

const std = @import("std");

/// 单个 slab（span）大小：向 backing 整块申请，切成等大 slot。必须是 2 的幂（掩码反查）。
/// 16KB：足够批量摊销 backing 调用，又不让欠占用的冷 class 浪费过多（每 class 最坏浪费 1 slab）。
const SLAB_SIZE: usize = 16 * 1024;
const SLAB_MASK: usize = ~(SLAB_SIZE - 1);
const SLAB_ALIGN: std.mem.Alignment = .fromByteUnits(SLAB_SIZE);

/// slot 最小对齐（= Value 的 @alignOf）。
const SLOT_ALIGNMENT: usize = 16;

/// ≥ 此阈值的分配直通 backing（大对象，不进 slab）。
const LARGE_THRESHOLD: usize = 4096;

/// size class 表（字节）。全部 16 的倍数。
/// 低段 8 步进贴箱体；中段 16 步进；高段 ~1.25× 几何。
const SIZE_CLASSES = [_]u32{
    // 低段：8 步进，精确命中 40/56/64/80/96/112/128 等箱体
    16,   24,   32,   40,   48,   56,   64,   72,
    80,   88,   96,   104,  112,  120,  128,
    // 中段：16 步进
    144,  160,  176,  192,  208,  224,  240,  256,
    // 高段：~1.25× 几何
    320,  384,  448,  512,
    640,  768,  896,  1024,
    1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096,
};

const NUM_CLASSES = SIZE_CLASSES.len;
const LOOKUP_LEN = LARGE_THRESHOLD / 8 + 1;

/// 空闲 slot 内嵌的侵入式链表节点（复用 slot 空间，零额外内存）。
const FreeNode = struct {
    next: ?*FreeNode,
};

/// 一个 slab：专属单一 size class，切成等大 slot。头部内嵌于 64KB 对齐块首。
const Slab = struct {
    /// 魔数：校验掩码反查到的确实是本 pool 的 slab 头。混合分配器阶段，
    /// 非本 pool 分配的指针（arena 内存）被误 free 时，掩码反查会落到非 slab
    /// 内存，magic 不匹配则安全忽略（交由 arena 统一回收）。
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
    /// backing 原始块（用于归还）。按 SLAB_ALIGN 对齐分配，free 须经 freeBlock。
    block: []u8,
    /// class 的 partial 双向链（有空位的 slab）。
    next: ?*Slab,
    prev: ?*Slab,
};

/// slab 头魔数。
const SLAB_MAGIC: u64 = 0x5142_5F4C_4F4F_50AB; // "SLB_LOOP" 变体

const SizeClass = struct {
    slot_size: u32,
    /// 有空位的 slab 双向链头（分配优先取这里）。
    partial: ?*Slab = null,
};

/// 全局空 slab 缓存上限：空 64KB 块可重切给任意 class，故跨 class 共享一个池。
/// 偏速度的平衡：保留少量块防抖动，超限立即归还 backing → 内存随死对象回落。
const MAX_EMPTY_SLABS: usize = 4;

pub const SlabPool = struct {
    backing: std.mem.Allocator,
    classes: [NUM_CLASSES]SizeClass,
    /// size → class_idx 查表。索引 = (len+7)/8。
    class_lookup: [LOOKUP_LEN]u8,
    /// 大对象（≥ LARGE_THRESHOLD）登记。
    large_objects: std.ArrayList(LargeObj),
    /// 全局空 slab 缓存（单链栈，复用 Slab.next）。
    empty_slabs: ?*Slab,
    empty_count: usize,

    // ── 统计（碎片率 = 1 - live_bytes/reserved_bytes）──
    live_bytes: usize,
    reserved_bytes: usize,

    const LargeObj = struct {
        ptr: [*]u8,
        len: usize,
    };

    pub fn init(backing: std.mem.Allocator) SlabPool {
        var pool = SlabPool{
            .backing = backing,
            .classes = undefined,
            .class_lookup = undefined,
            .large_objects = std.ArrayList(LargeObj).empty,
            .empty_slabs = null,
            .empty_count = 0,
            .live_bytes = 0,
            .reserved_bytes = 0,
        };
        for (&pool.classes, 0..) |*c, i| {
            c.* = SizeClass{ .slot_size = SIZE_CLASSES[i] };
        }
        // 构建 size → class_idx 查表：每个槽找 slot_size >= need 的最小 class。
        var lk: usize = 0;
        while (lk < LOOKUP_LEN) : (lk += 1) {
            const need: u32 = @intCast(lk * 8);
            var idx: usize = 0;
            while (idx < NUM_CLASSES - 1 and SIZE_CLASSES[idx] < need) idx += 1;
            pool.class_lookup[lk] = @intCast(idx);
        }
        return pool;
    }

    pub fn deinit(self: *SlabPool) void {
        for (&self.classes) |*c| {
            var cur = c.partial;
            while (cur) |s| {
                const nxt = s.next;
                self.freeBlock(s.block);
                cur = nxt;
            }
        }
        var e = self.empty_slabs;
        while (e) |s| {
            const nxt = s.next;
            self.freeBlock(s.block);
            e = nxt;
        }
        for (self.large_objects.items) |obj| {
            self.backing.free(obj.ptr[0..obj.len]);
        }
        self.large_objects.deinit(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *SlabPool) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = vtAlloc,
                .resize = vtResize,
                .remap = vtRemap,
                .free = vtFree,
            },
        };
    }

    // ── 内部 ──

    /// 归还一个 slab 的 backing 块，带回 SLAB_ALIGN 对齐（否则 DebugAllocator 报对齐不匹配）。
    fn freeBlock(self: *SlabPool, block: []u8) void {
        self.backing.rawFree(block, SLAB_ALIGN, @returnAddress());
    }

    /// 申请一个 64KB 对齐块并初始化为 class i 的 slab。优先复用全局空 slab 缓存。
    fn newSlab(self: *SlabPool, class_idx: usize) ?*Slab {
        var slab: *Slab = undefined;
        if (self.empty_slabs) |cached| {
            // 复用缓存块，重切给本 class（块大小不变，仅重算 total/offset）。
            self.empty_slabs = cached.next;
            self.empty_count -= 1;
            slab = cached;
        } else {
            const block = self.backing.alignedAlloc(u8, SLAB_ALIGN, SLAB_SIZE) catch return null;
            slab = @ptrCast(@alignCast(block.ptr));
            slab.block = block;
            self.reserved_bytes += SLAB_SIZE;
        }
        const hdr = std.mem.alignForward(usize, @sizeOf(Slab), SLOT_ALIGNMENT);
        const slot_size = SIZE_CLASSES[class_idx];
        const total: u32 = @intCast((SLAB_SIZE - hdr) / slot_size);
        const block = slab.block;
        slab.* = Slab{
            .magic = SLAB_MAGIC,
            .class_idx = @intCast(class_idx),
            .used = 0,
            .total = total,
            .bump = 0,
            .slots_offset = @intCast(hdr),
            .free_list = null,
            .block = block,
            .next = null,
            .prev = null,
        };
        return slab;
    }

    /// 整块空的 slab：进全局缓存（防抖动），超上限则归还 backing。
    fn recycleSlab(self: *SlabPool, slab: *Slab) void {
        if (self.empty_count < MAX_EMPTY_SLABS) {
            slab.next = self.empty_slabs;
            slab.prev = null;
            self.empty_slabs = slab;
            self.empty_count += 1;
        } else {
            self.reserved_bytes -= slab.block.len;
            self.freeBlock(slab.block);
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

    /// 把 slab 接到 class.partial 链头。
    fn partialPush(c: *SizeClass, slab: *Slab) void {
        slab.prev = null;
        slab.next = c.partial;
        if (c.partial) |h| h.prev = slab;
        c.partial = slab;
    }

    /// 从 class.partial 链摘除 slab。
    fn partialRemove(c: *SizeClass, slab: *Slab) void {
        if (slab.prev) |p| p.next = slab.next else c.partial = slab.next;
        if (slab.next) |n| n.prev = slab.prev;
        slab.prev = null;
        slab.next = null;
    }
};

// ── vtable ──

fn vtAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *SlabPool = @ptrCast(@alignCast(ctx));

    // 大对象直通 backing。
    if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);
        const raw = self.backing.rawAlloc(len, std.mem.Alignment.fromByteUnits(a), @returnAddress()) orelse return null;
        self.large_objects.append(self.backing, .{ .ptr = raw, .len = len }) catch {
            self.backing.rawFree(raw[0..len], std.mem.Alignment.fromByteUnits(a), @returnAddress());
            return null;
        };
        self.reserved_bytes += len;
        self.live_bytes += len;
        return raw;
    }

    const ci = self.class_lookup[(len + 7) / 8];
    const c = &self.classes[ci];

    // 1. partial 链有空位 slab。
    if (c.partial) |slab| {
        const ptr = SlabPool.slabTake(slab);
        if (!SlabPool.slabHasRoom(slab)) SlabPool.partialRemove(c, slab); // 满了摘除
        self.live_bytes += len;
        return ptr;
    }

    // 2. 新 slab（newSlab 内部优先复用全局空 slab 缓存）。
    const slab = self.newSlab(ci) orelse return null;
    SlabPool.partialPush(c, slab);
    const ptr = SlabPool.slabTake(slab);
    if (!SlabPool.slabHasRoom(slab)) SlabPool.partialRemove(c, slab);
    self.live_bytes += len;
    return ptr;
}

fn vtFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const self: *SlabPool = @ptrCast(@alignCast(ctx));
    const len = buf.len;

    // 大对象：线性查登记表归还。
    if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
        const a = @max(alignment.toByteUnits(), SLOT_ALIGNMENT);
        for (self.large_objects.items, 0..) |obj, i| {
            if (obj.ptr == buf.ptr) {
                self.backing.rawFree(buf.ptr[0..obj.len], std.mem.Alignment.fromByteUnits(a), @returnAddress());
                self.reserved_bytes -= obj.len;
                self.live_bytes -= obj.len;
                _ = self.large_objects.swapRemove(i);
                return;
            }
        }
        return; // 未登记：忽略（不属于本 pool）
    }

    // 掩码反查所属 slab。校验魔数：非本 pool 的指针（混合分配器阶段残留的
    // arena 内存被误 free）掩码会落到非 slab 内存，magic 不符则安全忽略。
    const slab: *Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
    if (slab.magic != SLAB_MAGIC) return;
    const c = &self.classes[slab.class_idx];
    const was_full = !SlabPool.slabHasRoom(slab);

    // 推回 slab 自己的 free_list。
    const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
    node.next = slab.free_list;
    slab.free_list = node;
    slab.used -= 1;
    self.live_bytes -= len;

    if (slab.used == 0) {
        // slab 整块空。它当前在 partial 链（had room）；摘除后进全局空缓存。
        if (!was_full) SlabPool.partialRemove(c, slab);
        self.recycleSlab(slab);
    } else if (was_full) {
        // 之前满（不在 partial），现在有空位，加回 partial。
        SlabPool.partialPush(c, slab);
    }
}

fn vtResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = ret_addr;
    // 大对象不支持原地 resize。
    if (buf.len >= LARGE_THRESHOLD or new_len >= LARGE_THRESHOLD) return false;
    if (alignment.toByteUnits() > SLOT_ALIGNMENT) return false;
    // 同 slot 容量内即可原地：slot_size 不变则 OK。
    const slab: *Slab = @ptrFromInt(@intFromPtr(buf.ptr) & SLAB_MASK);
    if (slab.magic != SLAB_MAGIC) return false; // 非本 pool 内存，拒绝原地 resize
    return new_len <= SIZE_CLASSES[slab.class_idx];
}

fn vtRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

// ── 单测 ──

const testing = std.testing;

test "basic alloc/free roundtrip, size classes" {
    var pool = SlabPool.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 各箱体大小都应成功分配且 16 对齐。
    const sizes = [_]usize{ 16, 40, 56, 64, 80, 96, 112, 128, 200, 512, 1024, 4095 };
    for (sizes) |sz| {
        const buf = a.alloc(u8, sz) catch unreachable;
        try testing.expect(@intFromPtr(buf.ptr) % SLOT_ALIGNMENT == 0);
        a.free(buf);
    }
}

test "slab reverse-lookup via mask is correct" {
    var pool = SlabPool.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 同 class 分配多个，free 走掩码反查，无 double-free（DebugAllocator 会 panic）。
    var bufs: [64][]u8 = undefined;
    for (&bufs) |*b| b.* = a.alloc(u8, 64) catch unreachable;
    for (bufs) |b| a.free(b);
}

test "empty slab returns to backing, capped global cache" {
    var pool = SlabPool.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 分配足够多的 64B 触发 >1 个 slab，再全部释放。
    var list = std.ArrayList([]u8).empty;
    defer list.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        list.append(testing.allocator, a.alloc(u8, 64) catch unreachable) catch unreachable;
    }
    const peak = pool.reserved_bytes;
    for (list.items) |b| a.free(b);

    // 全 free 后：reserved 回落到 <= MAX_EMPTY_SLABS 个空 slab，远小于 peak。
    try testing.expect(pool.reserved_bytes <= MAX_EMPTY_SLABS * SLAB_SIZE);
    try testing.expect(pool.reserved_bytes < peak);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes);
}

test "large objects bypass slabs" {
    var pool = SlabPool.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const big = a.alloc(u8, 100 * 1024) catch unreachable;
    try testing.expectEqual(@as(usize, 1), pool.large_objects.items.len);
    a.free(big);
    try testing.expectEqual(@as(usize, 0), pool.large_objects.items.len);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes);
}

test "fragmentation stays low under churn" {
    var pool = SlabPool.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 模拟 churn：维持稳定工作集（~2000 活对象），在饱和态测碎片才有意义。
    var live = std.ArrayList([]u8).empty;
    defer {
        for (live.items) |b| a.free(b);
        live.deinit(testing.allocator);
    }
    var seed: u64 = 12345;
    var i: usize = 0;
    // 贴近 Glue 真实分配：聚集在箱体大小（40/56/64/80/96/112/128）。
    const box_sizes = [_]usize{ 40, 56, 64, 64, 80, 96, 112, 128 };
    while (i < 40000) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const sz: usize = box_sizes[(seed >> 33) % box_sizes.len];
        // 工作集未满则倾向分配；满了则交替，维持稳态。
        const want_free = live.items.len >= 2000 or ((seed & 1) == 0 and live.items.len > 1000);
        if (want_free) {
            const idx = (seed >> 1) % live.items.len;
            a.free(live.items[idx]);
            _ = live.swapRemove(idx);
        } else {
            live.append(testing.allocator, a.alloc(u8, sz) catch unreachable) catch unreachable;
        }
    }
    // 稳态碎片率 = 1 - live/reserved。段式无外部碎片，此处主要是「每 class 末尾
    // 半空 slab」的开销（工作集非 slot 整数倍时固有，~1.5-2× 属 slab 分配器正常范围）。
    if (pool.reserved_bytes > 0) {
        const frag = 1.0 - @as(f64, @floatFromInt(pool.live_bytes)) /
            @as(f64, @floatFromInt(pool.reserved_bytes));
        try testing.expect(frag < 0.6);
    }
}
