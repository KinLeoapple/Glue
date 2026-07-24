//! 线程上下文模块。
//!
//! 每线程一个的统一内存管理入口，热路径零同步：
//! - ChannelRegion（双 Region）：global_region 程序级 + call_region 函数级（bump + resetTo）
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
const buddy_mod = @import("buddy.zig");
const channel_region_mod = @import("channel_region.zig");
const shadow_arena_mod = @import("shadow_arena.zig");
const profiling = @import("profiling");

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
    call_region: ChannelRegion,
    arena: ShadowArena,
    global: *GlobalPool,
    backing: std.mem.Allocator,
    /// slot 查找缓存（2 路组相联）：deepCopy 等场景反复分配相同 size 时跳过线性扫描
    slot_cache_size: [2]u16 = .{ 0, 0 },
    slot_cache_idx: [2]u8 = .{ 0, 0 },
    slot_cache_next: u8 = 0,
    /// per-thread 性能采集器（--profile 时创建，否则 null）
    prof: ?*profiling.ThreadProfiler = null,
    /// GlobalProfiler 反向引用（deinit 时注销 ThreadProfiler 用）
    global_prof: ?*profiling.GlobalProfiler = null,

    /// 创建线程上下文
    /// global_prof 非 null 且 enabled 时创建并注册 ThreadProfiler
    /// io 从 global.io 取（线程上下文与所属 GlobalPool 共享同一 io 实例）
    pub fn init(global: *GlobalPool, backing: std.mem.Allocator, global_prof: ?*profiling.GlobalProfiler) !ThreadContext {
        var ctx = ThreadContext{
            .channels = ChannelRegion.init(backing),
            .call_region = ChannelRegion.init(backing),
            .arena = ShadowArena.init(backing),
            .global = global,
            .backing = backing,
        };
        if (global_prof) |gp| {
            if (gp.enabled) {
                // ThreadProfiler 由 GlobalProfiler.allocator 分配，生命周期归 GlobalProfiler 管理
                // （ThreadContext.deinit 不销毁，GlobalProfiler.dump/deinit 统一清理）
                const prof = try gp.allocator.create(profiling.ThreadProfiler);
                prof.* = profiling.ThreadProfiler.init(true, @truncate(std.Thread.getCurrentId()));
                gp.registerThread(prof);
                ctx.prof = prof;
                ctx.global_prof = gp;
            }
        }
        return ctx;
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
        self.call_region.deinit();
        self.arena.deinit();
        // ThreadProfiler 生命周期由 GlobalProfiler 管理（dump/deinit 时统一清理）
        // 这里只断开引用，不注销也不销毁
        self.prof = null;
    }

    /// 查找或创建指定 object_size 的池槽位索引
    /// 2 路缓存优先查找，命中则跳过线性扫描
    fn findOrCreateSlot(self: *ThreadContext, object_size: usize) !u8 {
        const sz: u16 = @intCast(object_size);
        // 2 路缓存快路径
        if (self.slot_cache_size[0] == sz) {
            if (self.prof) |p| p.recordSlotCache(true);
            return self.slot_cache_idx[0];
        }
        if (self.slot_cache_size[1] == sz) {
            if (self.prof) |p| p.recordSlotCache(true);
            return self.slot_cache_idx[1];
        }
        // 慢路径：线性扫描 pools
        for (0..self.pool_count) |i| {
            if (self.pools[i].object_size == sz) {
                self.slotCacheUpdate(sz, @intCast(i));
                if (self.prof) |p| p.recordSlotCache(false);
                return @intCast(i);
            }
        }
        if (self.pool_count >= MAX_POOLS) return error.TooManyPools;
        const idx = self.pool_count;
        self.pools[idx].object_size = sz;
        self.pool_count += 1;
        self.slotCacheUpdate(sz, @intCast(idx));
        if (self.prof) |p| p.recordSlotCache(false);
        return idx;
    }

    /// 更新 slot 缓存（轮转替换）
    inline fn slotCacheUpdate(self: *ThreadContext, size: u16, idx: u8) void {
        const slot = self.slot_cache_next;
        self.slot_cache_size[slot] = size;
        self.slot_cache_idx[slot] = idx;
        self.slot_cache_next ^= 1; // 在 0/1 之间轮转
    }

    /// 按 object_size 分配小对象（热路径：位图扫描，零锁）
    /// object_size 自动向上取整到 8 字节对齐，确保所有对象满足 u64/f64 对齐要求
    /// 返回切片长度 = 请求的 object_size（底层实际分配 aligned_size，多出的尾部不可用）
    pub fn allocBySize(self: *ThreadContext, object_size: usize) ![]u8 {
        // 向上取整到 8 字节对齐（u64/f64 的最大对齐要求）
        const aligned_size = std.mem.alignForward(usize, object_size, 8);
        if (aligned_size > MAX_PAGE_OBJECT_SIZE) return self.allocLarge(object_size);
        const idx = try self.findOrCreateSlot(aligned_size);
        const mem = try self.allocByIdx(idx);
        if (self.prof) |p| p.recordObjectPoolAlloc(object_size, false);
        return mem[0..object_size];
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
    /// object_size 自动向上取整到 8 字节对齐，与 allocBySize 保持一致
    pub fn freeBySize(self: *ThreadContext, object_size: usize, ptr: []u8) void {
        if (self.prof) |p| p.recordObjectPoolFree();
        const aligned_size = std.mem.alignForward(usize, object_size, 8);
        if (aligned_size > MAX_PAGE_OBJECT_SIZE) {
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
        const sz: u16 = @intCast(aligned_size);
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
        const result = try self.global.allocLarge(size);
        if (self.prof) |p| p.recordObjectPoolAlloc(size, true);
        return result;
    }

    /// 释放大对象
    pub fn freeLarge(self: *ThreadContext, ptr: []u8) void {
        self.global.freeLarge(ptr);
    }

    /// 分配通道数据
    pub fn allocChannel(self: *ThreadContext, size: usize) ![]u8 {
        const result = try self.channels.alloc(size);
        if (self.prof) |p| p.recordAllocatorWatermark(.channel, self.channels.used + self.call_region.used, true);
        return result;
    }

    /// 分配临时数据
    pub fn allocTemp(self: *ThreadContext, size: usize) ![]u8 {
        const result = try self.arena.alloc(size);
        if (self.prof) |p| p.recordAllocatorWatermark(.shadow_arena, self.arena.used, true);
        return result;
    }

    /// 函数返回：reset 临时区（O(1)）
    pub fn endFunction(self: *ThreadContext) void {
        if (self.prof) |p| p.recordAllocatorReset(.shadow_arena, self.arena.used);
        self.arena.reset();
    }

    // ── 对象分配 API ──

    /// 分配对象（统一入口）：按 total_size 路由到页池或 buddy
    /// total_size = sizeof(Type) + payload_size（连续内存分配）
    pub fn allocObj(self: *ThreadContext, total_size: usize) ![]u8 {
        return self.allocBySize(total_size);
    }

    /// 分配 arena 对象（逃逸分析驱动：非逃逸对象走 ShadowArena）
    /// endFunction 时由 arena.reset 统一回收，无需单独 freeObj。
    /// 调用方必须在初始化 ObjHeader 后立即调用 markArenaAllocated()。
    pub fn allocObjArena(self: *ThreadContext, total_size: usize) ![]u8 {
        const result = try self.arena.alloc(total_size);
        if (self.prof) |p| p.recordAllocatorWatermark(.shadow_arena, self.arena.used, true);
        return result;
    }

    /// 创建固定大小 arena 对象（便利方法）
    /// 返回未初始化的 *T，调用方必须设置字段并调用 markArenaAllocated()
    pub fn createObjArena(self: *ThreadContext, comptime T: type) !*T {
        const mem_bytes = try self.arena.alloc(@sizeOf(T));
        if (self.prof) |p| p.recordAllocatorWatermark(.shadow_arena, self.arena.used, true);
        return @ptrCast(@alignCast(mem_bytes.ptr));
    }

    /// 释放对象（统一入口）：从分配器元数据读取尺寸，无需调用方传 size
    /// 页池对象从 PageHeader.object_size 读取；buddy 对象从 BuddyHeader.block_size 读取
    pub fn freeObj(self: *ThreadContext, ptr: [*]u8) void {
        if (self.prof) |p| p.recordObjectPoolFree();
        if (page_pool.isPagePtr(ptr)) {
            const page = page_pool.pageOf(ptr);
            const object_size: usize = page_pool.pageHeader(page).object_size;
            const all_free = freeToPage(page, ptr);
            if (!all_free) return;
            // 页全空：线性扫描对应槽位
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
        } else {
            // buddy 对象：block_size 从 BuddyHeader 读取
            self.global.freeLarge(ptr[0..0]);
        }
    }

    /// 查询对象的分配大小（不释放内存）
    /// 页池对象从 PageHeader.object_size 读取；buddy 对象从 BuddyHeader.block_size 读取
    /// 用于 profiling recordFree 时获取真实 size，使 free_bytes/current_bytes 准确
    pub fn getAllocSize(self: *ThreadContext, ptr: [*]u8) usize {
        _ = self;
        if (page_pool.isPagePtr(ptr)) {
            const page = page_pool.pageOf(ptr);
            return page_pool.pageHeader(page).object_size;
        } else {
            // buddy 对象：BuddyHeader 在用户指针前 HEADER_SIZE 字节
            const buddy_header: *const buddy_mod.BuddyHeader = @ptrCast(@alignCast(ptr - buddy_mod.HEADER_SIZE));
            return buddy_header.block_size;
        }
    }

    /// 创建固定大小对象（便利方法）
    pub fn createObj(self: *ThreadContext, comptime T: type) !*T {
        const mem_bytes = try self.allocObj(@sizeOf(T));
        return @ptrCast(@alignCast(mem_bytes.ptr));
    }

    /// 保存 ShadowArena 水位（函数入口调用）
    pub fn saveWatermark(self: *ThreadContext) usize {
        return self.arena.saveWatermark();
    }

    /// 恢复 ShadowArena 水位（函数返回调用，释放临时分配）
    pub fn restoreWatermark(self: *ThreadContext, pos: usize) void {
        self.arena.restoreWatermark(pos);
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
    defer ctx.deinit();

    const mem = try ctx.allocBySize(48);
    try testing.expect(mem.len == 48);
    @memset(mem, 0xAA);

    ctx.freeBySize(48, mem);
}

test "ThreadContext 多次分配" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
    defer ctx.deinit();

    const mem = try ctx.allocBySize(500);
    try testing.expect(mem.len >= 500);
    @memset(mem, 0xBB);
    ctx.freeBySize(500, mem);
}

test "ThreadContext 通道分配" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
    defer ctx.deinit();

    const m1 = try ctx.allocChannel(100);
    @memset(m1, 0xCC);
    const m2 = try ctx.allocChannel(50);
    try testing.expect(m1.ptr != m2.ptr);
}

test "ThreadContext 临时区分配与 reset" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
    defer ctx.deinit();

    const m = try ctx.allocTemp(64);
    @memset(m, 0xDD);

    ctx.endFunction(); // reset 临时区
}

test "ThreadContext 全空页归还" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var global = GlobalPool.init(testing.allocator, threaded.io());
    defer global.deinit();
    var ctx = try ThreadContext.init(&global, testing.allocator, null);
    defer ctx.deinit();

    // 分配然后全部释放，页应被缓存或归还
    const m = try ctx.allocBySize(64);
    ctx.freeBySize(64, m);
}
