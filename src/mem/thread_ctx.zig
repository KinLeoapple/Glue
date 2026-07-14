//! 线程上下文模块。
//!
//! 每线程一个的统一内存管理入口，热路径零同步：
//! - ChannelRegion：通道数据，bump + reset
//! - ObjectPools：ObjHeader 对象，精确尺寸页池
//! - ShadowArena：临时作用域，bump + reset
//!
//! 设计要点：
//! - 线程本地每类型最多 2 页（1 active + 1 cached），零锁分配
//! - 全空页归还给 GlobalPool，实现零驻留
//! - 大于 256B 的对象走 GlobalPool.buddy
//! - mem 不引用 value 类型，通过 object_size 索引池

const std = @import("std");
const page_pool = @import("page_pool.zig");
const global_pool_mod = @import("global_pool.zig");
const channel_region_mod = @import("channel_region.zig");
const shadow_arena_mod = @import("shadow_arena.zig");

const PagePtr = page_pool.PagePtr;
const GlobalPool = global_pool_mod.GlobalPool;
const ChannelRegion = channel_region_mod.ChannelRegion;
const ShadowArena = shadow_arena_mod.ShadowArena;

/// 最大对象池类型数（足够容纳 22 种 ObjHeader 类型）
const MAX_POOLS: usize = 32;
/// 大于此尺寸走 buddy
const MAX_PAGE_OBJECT_SIZE: usize = global_pool_mod.MAX_PAGE_OBJECT_SIZE;

/// 线程本地对象池槽位
const PoolSlot = struct {
    object_size: u16 = 0, // 0 表示空槽
    active: ?PagePtr = null, // 当前分配页
    cached: ?PagePtr = null, // 全空闲页缓存（最多 1 页）
};

/// 线程上下文：每线程一个，热路径零同步
pub const ThreadContext = struct {
    pools: [MAX_POOLS]PoolSlot = [_]PoolSlot{.{}} ** MAX_POOLS,
    pool_count: u8 = 0,
    channels: ChannelRegion,
    arena: ShadowArena,
    global: *GlobalPool,
    backing: std.mem.Allocator,

    /// 创建线程上下文
    pub fn init(global: *GlobalPool, backing: std.mem.Allocator) ThreadContext {
        return .{
            .channels = ChannelRegion.init(backing),
            .arena = ShadowArena.init(backing),
            .global = global,
            .backing = backing,
        };
    }

    /// 释放所有线程本地资源（页归还给 GlobalPool）
    pub fn deinit(self: *ThreadContext) void {
        for (&self.pools) |*slot| {
            if (slot.object_size == 0) continue;
            if (slot.active) |p| self.global.returnPage(p);
            if (slot.cached) |p| self.global.returnPage(p);
            slot.active = null;
            slot.cached = null;
            slot.object_size = 0;
        }
        self.pool_count = 0;
        self.channels.deinit();
        self.arena.deinit();
    }

    /// 查找或创建指定 object_size 的池槽位索引
    fn findOrCreateSlot(self: *ThreadContext, object_size: usize) !u8 {
        const sz: u16 = @intCast(object_size);
        for (0..self.pool_count) |i| {
            if (self.pools[i].object_size == sz) return @intCast(i);
        }
        if (self.pool_count >= MAX_POOLS) return error.TooManyPools;
        const idx = self.pool_count;
        self.pools[idx].object_size = sz;
        self.pool_count += 1;
        return idx;
    }

    /// 按 object_size 分配小对象（热路径：位图扫描，零锁）
    pub fn allocBySize(self: *ThreadContext, object_size: usize) ![]u8 {
        if (object_size > MAX_PAGE_OBJECT_SIZE) return self.allocLarge(object_size);
        const idx = try self.findOrCreateSlot(object_size);
        return self.allocByIdx(idx);
    }

    /// 按槽位索引分配
    fn allocByIdx(self: *ThreadContext, idx: u8) ![]u8 {
        const slot = &self.pools[idx];
        const obj_size = slot.object_size;

        // 热路径：从 active 页分配
        if (slot.active) |page| {
            if (allocFromPage(page, obj_size)) |mem| return mem;
        }

        // active 满：用 cached 或从 global 获取新页
        if (slot.cached) |page| {
            slot.active = page;
            slot.cached = null;
            if (allocFromPage(page, obj_size)) |mem| return mem;
        }

        // 从 GlobalPool 获取新页
        const new_page = try self.global.acquirePageRuntime(obj_size);
        slot.active = new_page;
        if (allocFromPage(new_page, obj_size)) |mem| return mem;

        return error.AllocFailed; // 不应到达
    }

    /// 按 object_size 释放对象（热路径：清位图，零锁）
    pub fn freeBySize(self: *ThreadContext, object_size: usize, ptr: []u8) void {
        if (object_size > MAX_PAGE_OBJECT_SIZE) {
            self.freeLarge(ptr);
            return;
        }

        const page = page_pool.pageOf(ptr.ptr);
        // 验证指针确实来自页池
        if (!page_pool.isPagePtr(ptr.ptr)) {
            // 不是页池对象，可能是直接从 backing allocator 分配的
            self.backing.free(ptr);
            return;
        }

        const all_free = freeToPage(page, ptr.ptr);
        if (!all_free) return;

        // 页全空：归还或缓存
        const sz: u16 = @intCast(object_size);
        for (&self.pools) |*slot| {
            if (slot.object_size != sz) continue;
            if (slot.active == page) {
                slot.active = null;
                if (slot.cached == null) {
                    slot.cached = page; // 缓存全空页
                } else {
                    self.global.returnPage(page); // 已有缓存，归还
                }
            } else if (slot.cached == page) {
                // cached 页不会被释放，忽略
            } else {
                // 页可能属于其他线程的 pool，归还到 global
                self.global.returnPage(page);
            }
            return;
        }
        // 未找到对应池，归还到 global
        self.global.returnPage(page);
    }

    /// 分配大对象（委托给 GlobalPool.buddy）
    pub fn allocLarge(self: *ThreadContext, size: usize) ![]u8 {
        return self.global.allocLarge(size);
    }

    /// 释放大对象
    pub fn freeLarge(self: *ThreadContext, ptr: []u8) void {
        self.global.freeLarge(ptr);
    }

    /// 分配通道数据
    pub fn allocChannel(self: *ThreadContext, size: usize) ![]u8 {
        return self.channels.alloc(size);
    }

    /// 分配临时数据
    pub fn allocTemp(self: *ThreadContext, size: usize) ![]u8 {
        return self.arena.alloc(size);
    }

    /// 基本块结束：reset 通道（O(1)）
    pub fn endBlock(self: *ThreadContext) void {
        self.channels.reset();
    }

    /// 函数返回：reset 临时区（O(1)）
    pub fn endFunction(self: *ThreadContext) void {
        self.arena.reset();
    }
};

/// 从页中分配一个对象（运行时 size 版本）
fn allocFromPage(page: PagePtr, object_size: u16) ?[]u8 {
    const hdr = page_pool.pageHeader(page);
    if (hdr.free_count == 0) return null;
    if (hdr.object_size != object_size) return null;

    const n: usize = hdr.object_count;
    const sz: usize = object_size;
    const bitmap_words = (n + 63) / 64;
    const bitmap: [*]u64 = @ptrCast(@alignCast(page + n * sz));

    for (bitmap[0..bitmap_words], 0..) |word, wi| {
        if (word == 0xFFFF_FFFF_FFFF_FFFF) continue;
        const bit = @ctz(~word);
        const idx = wi * 64 + bit;
        if (idx >= n) continue;
        bitmap[wi] |= (@as(u64, 1) << @intCast(bit));
        hdr.free_count -= 1;
        return page[idx * sz ..][0..sz];
    }
    return null;
}

/// 释放对象到页，返回页是否全空
fn freeToPage(page: PagePtr, ptr: [*]u8) bool {
    const hdr = page_pool.pageHeader(page);
    const page_base = @intFromPtr(page);
    const ptr_addr = @intFromPtr(ptr);
    const offset = ptr_addr - page_base;
    const sz: usize = hdr.object_size;
    const idx = offset / sz;

    const n: usize = hdr.object_count;
    const bitmap: [*]u64 = @ptrCast(@alignCast(page + n * sz));
    const wi = idx / 64;
    const bit = idx % 64;
    bitmap[wi] &= ~(@as(u64, 1) << @intCast(bit));
    hdr.free_count += 1;
    return hdr.free_count == hdr.object_count;
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "ThreadContext 小对象分配与释放" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    const mem = try ctx.allocBySize(48);
    try testing.expect(mem.len == 48);
    @memset(mem, 0xAA);

    ctx.freeBySize(48, mem);
}

test "ThreadContext 多次分配" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    var ptrs: [20][]u8 = undefined;
    for (&ptrs) |*p| {
        p.* = try ctx.allocBySize(32);
    }
    // 验证所有指针不同
    for (ptrs, 0..) |p, i| {
        for (ptrs[i + 1 ..]) |q| {
            try testing.expect(p.ptr != q.ptr);
        }
    }
    for (ptrs) |p| ctx.freeBySize(32, p);
}

test "ThreadContext 大对象分配" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    const mem = try ctx.allocBySize(500);
    try testing.expect(mem.len >= 500);
    @memset(mem, 0xBB);
    ctx.freeBySize(500, mem);
}

test "ThreadContext 通道分配与 reset" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    const m1 = try ctx.allocChannel(100);
    @memset(m1, 0xCC);
    const m2 = try ctx.allocChannel(50);
    try testing.expect(m1.ptr != m2.ptr);

    ctx.endBlock(); // reset 通道
}

test "ThreadContext 临时区分配与 reset" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    const m = try ctx.allocTemp(64);
    @memset(m, 0xDD);

    ctx.endFunction(); // reset 临时区
}

test "ThreadContext 全空页归还" {
    var global = GlobalPool.init(testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, testing.allocator);
    defer ctx.deinit();

    // 分配然后全部释放，页应被缓存或归还
    const m = try ctx.allocBySize(64);
    ctx.freeBySize(64, m);
}
