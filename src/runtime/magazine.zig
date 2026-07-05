//! MagazineAllocator — 三层分配器架构（ThreadCache → SlabPool → page_allocator）
//!
//! 设计要点：
//! - ThreadCache: 每线程独享的 per-class 自由链表，alloc/free O(1) 无锁。
//!   纯指针 push/pop，无 SlabPool 的 partial 链/slabHasRoom/partialRemove 操作。
//! - SlabPool: 段式 slab 分配器，ThreadCache 批量 refill/drain。
//! - 每线程独立堆（rc 非原子，要求线程隔离堆）。
//! - 大对象（≥ LARGE_THRESHOLD）直通 SlabPool。
//! - batch refill/drain 减少与 SlabPool 的交互次数，BATCH_SIZE 个 slot 一次批量。
//!
//! 内存统计说明：
//! SlabPool 的 live_bytes 在 refill 时 +SIZE_CLASSES[ci]×BATCH_SIZE，drain 时对应减少。
//! 用户 alloc/free 走 ThreadCache 不触碰 SlabPool 统计。因此 live_bytes 包含
//! ThreadCache 缓存的空闲 slot（略有 over-count，bounded by MAX_CACHE × NUM_CLASSES）。

const std = @import("std");
const slab_pool = @import("slab_pool");

const SlabPool = slab_pool.SlabPool;
const FreeNode = slab_pool.FreeNode;
const NUM_CLASSES = slab_pool.NUM_CLASSES;
const SIZE_CLASSES = slab_pool.SIZE_CLASSES;
const LARGE_THRESHOLD = slab_pool.LARGE_THRESHOLD;
const SLOT_ALIGNMENT = slab_pool.SLOT_ALIGNMENT;
const SLAB_MASK = slab_pool.SLAB_MASK;
const SLAB_MAGIC = slab_pool.SLAB_MAGIC;

/// 每次 refill/drain 的 slot 数量。32：摊销 SlabPool 交互成本，又不占过多缓存。
const BATCH_SIZE: u32 = 32;

/// 每 class 最多缓存的空闲 slot 数。超过则 drain 一个 batch。
/// 64：覆盖典型工作集的 hot class（Cell/ArrayValue/AdtValue 等），限制 over-count。
const MAX_CACHE_PER_CLASS: u32 = 64;

/// 每线程独享的分配缓存。alloc 从 free_lists pop；free 向 free_lists push。
/// free_lists 为空时批量 refill；过满时批量 drain。
pub const ThreadCache = struct {
    pool: *SlabPool,
    free_lists: [NUM_CLASSES]?*FreeNode = [_]?*FreeNode{null} ** NUM_CLASSES,
    free_counts: [NUM_CLASSES]u32 = [_]u32{0} ** NUM_CLASSES,

    pub fn init(pool: *SlabPool) ThreadCache {
        return .{ .pool = pool };
    }

    /// 将所有缓存的 slot 归还 SlabPool。deinit 前调用。
    pub fn drainAll(self: *ThreadCache) void {
        const a = self.pool.allocator();
        for (&self.free_lists, 0..) |*fl, ci| {
            while (fl.*) |node| {
                fl.* = node.next;
                const ptr: [*]u8 = @ptrCast(node);
                a.rawFree(ptr[0..SIZE_CLASSES[ci]], .fromByteUnits(SLOT_ALIGNMENT), @returnAddress());
            }
            self.free_counts[ci] = 0;
        }
    }

    /// 从 SlabPool 批量取 BATCH_SIZE 个 slot 填充 free_lists[ci]。
    fn refill(self: *ThreadCache, ci: usize) void {
        const a = self.pool.allocator();
        const slot_size = SIZE_CLASSES[ci];
        var n: u32 = 0;
        while (n < BATCH_SIZE) : (n += 1) {
            const ptr = a.rawAlloc(slot_size, .fromByteUnits(SLOT_ALIGNMENT), @returnAddress()) orelse break;
            const node: *FreeNode = @ptrCast(@alignCast(ptr));
            node.next = self.free_lists[ci];
            self.free_lists[ci] = node;
            self.free_counts[ci] += 1;
        }
    }

    /// 从 free_lists[ci] 取 BATCH_SIZE 个 slot 归还 SlabPool。
    fn drainBatch(self: *ThreadCache, ci: usize) void {
        const a = self.pool.allocator();
        const slot_size = SIZE_CLASSES[ci];
        var n: u32 = 0;
        while (n < BATCH_SIZE) : (n += 1) {
            const node = self.free_lists[ci] orelse break;
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            const ptr: [*]u8 = @ptrCast(node);
            a.rawFree(ptr[0..slot_size], .fromByteUnits(SLOT_ALIGNMENT), @returnAddress());
        }
    }

    /// alloc：大对象直通 SlabPool；小对象先查 free_lists，空则 refill 后再取。
    pub fn alloc(self: *ThreadCache, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        // 大对象或高对齐：直通 SlabPool
        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            return self.pool.allocator().rawAlloc(len, alignment, @returnAddress());
        }

        const ci = self.pool.class_lookup[(len + 7) / 8];

        // 快路径：free_lists 有缓存
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }

        // 慢路径：refill 后再取
        self.refill(ci);
        if (self.free_lists[ci]) |node| {
            self.free_lists[ci] = node.next;
            self.free_counts[ci] -= 1;
            return @ptrCast(node);
        }
        return null; // SlabPool 也 OOM
    }

    /// free：大对象直通 SlabPool；小对象校验 slab magic 后 push free_lists，过满则 drain。
    pub fn free(self: *ThreadCache, buf: []u8, alignment: std.mem.Alignment) void {
        const len = buf.len;

        // 大对象或高对齐：直通 SlabPool
        if (len >= LARGE_THRESHOLD or alignment.toByteUnits() > SLOT_ALIGNMENT) {
            self.pool.allocator().rawFree(buf, alignment, @returnAddress());
            return;
        }

        // 校验指针确实来自 SlabPool 的 slab（读取 slab 头的 magic 字段）
        const slab_addr = @intFromPtr(buf.ptr) & SLAB_MASK;
        const magic_ptr: *const u64 = @ptrFromInt(slab_addr);
        if (magic_ptr.* != SLAB_MAGIC) {
            // 非 SlabPool 内存：委托 SlabPool（它会安全忽略）
            self.pool.allocator().rawFree(buf, alignment, @returnAddress());
            return;
        }

        const ci = self.pool.class_lookup[(len + 7) / 8];

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
};

/// MagazineAllocator：封装 SlabPool + ThreadCache，实现 std.mem.Allocator 接口。
/// 单线程使用：一个 MagazineAllocator 实例 = 一个线程的独立堆。
/// 多线程：每个线程创建自己的 MagazineAllocator（rc 非原子，要求线程隔离堆）。
pub const MagazineAllocator = struct {
    pool: SlabPool,
    cache: ThreadCache,

    pub fn init(backing: std.mem.Allocator) MagazineAllocator {
        var self = MagazineAllocator{
            .pool = SlabPool.init(backing),
            .cache = undefined,
        };
        self.cache = ThreadCache.init(&self.pool);
        return self;
    }

    pub fn deinit(self: *MagazineAllocator) void {
        self.cache.drainAll();
        self.pool.deinit();
    }

    pub fn allocator(self: *MagazineAllocator) std.mem.Allocator {
        // init 返回 by-value，cache.pool 仍指向 init 局部 self.pool（已失效）。
        // 这里 self 是调用方的稳定指针，刷新 cache.pool 指向自己的 pool 字段。
        self.cache.pool = &self.pool;
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
};

// ── vtable ──

fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *MagazineAllocator = @ptrCast(@alignCast(ctx));
    return self.cache.alloc(len, alignment);
}

fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const self: *MagazineAllocator = @ptrCast(@alignCast(ctx));
    self.cache.free(buf, alignment);
}

fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = ret_addr;
    // 大对象不支持原地 resize
    if (buf.len >= LARGE_THRESHOLD or new_len >= LARGE_THRESHOLD) return false;
    if (alignment.toByteUnits() > SLOT_ALIGNMENT) return false;
    // 委托 SlabPool 的 resize 逻辑：检查 slab magic + slot_size 容量
    const slab_addr = @intFromPtr(buf.ptr) & SLAB_MASK;
    const magic_ptr: *const u64 = @ptrFromInt(slab_addr);
    if (magic_ptr.* != SLAB_MAGIC) return false;
    // Slab.class_idx 在 magic 之后（u64 后第 9 字节）。读取 class_idx 查 slot_size。
    const class_idx_ptr: *const u8 = @ptrFromInt(slab_addr + @sizeOf(u64));
    const ci = class_idx_ptr.*;
    return new_len <= SIZE_CLASSES[ci];
}

fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

// ── 单测 ──

const testing = std.testing;

test "basic alloc/free roundtrip via ThreadCache" {
    var mag = MagazineAllocator.init(testing.allocator);
    defer mag.deinit();
    const a = mag.allocator();

    const sizes = [_]usize{ 16, 32, 40, 48, 56, 64, 80, 96, 112, 128, 200, 512, 1024, 4095 };
    for (sizes) |sz| {
        const buf = a.alloc(u8, sz) catch unreachable;
        try testing.expect(@intFromPtr(buf.ptr) % SLOT_ALIGNMENT == 0);
        a.free(buf);
    }
}

test "refill/drain batch under churn" {
    var mag = MagazineAllocator.init(testing.allocator);
    defer mag.deinit();
    const a = mag.allocator();

    // 模拟 churn：交替 alloc/free 触发 refill 和 drain
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
    // 全部释放后 cache 内有残留 slot，drainAll 在 deinit 中归还
}

test "large objects bypass ThreadCache" {
    var mag = MagazineAllocator.init(testing.allocator);
    defer mag.deinit();
    const a = mag.allocator();

    const big = a.alloc(u8, 100 * 1024) catch unreachable;
    try testing.expectEqual(@as(usize, 1), mag.pool.large_objects.count());
    a.free(big);
    try testing.expectEqual(@as(usize, 0), mag.pool.large_objects.count());
}

test "free non-slab pointer is safely ignored" {
    var mag = MagazineAllocator.init(testing.allocator);
    defer mag.deinit();
    const a = mag.allocator();

    // 用一个 HeapAllocator 分配的非 slab 指针测试 magic check 路径。
    // 不会 panic 即通过（magic 不匹配 → 委托 SlabPool → SlabPool 检查 magic → 忽略）
    const heap_buf = testing.allocator.alloc(u8, 64) catch unreachable;
    defer testing.allocator.free(heap_buf);
    a.free(heap_buf);
}
