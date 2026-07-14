//! 全局池模块。
//!
//! 冷路径内存管理，线程本地内存不足时从此处补充，线程退出时归还。
//! 采用简单自旋锁保护（临界区短小）：
//! - 每 object_size 最多缓存 8 页
//! - 大对象通过 BuddyAllocator 分配
//! - 空页归还给 backing allocator

const std = @import("std");
const sync = @import("sync");
const Mutex = sync.Mutex;
const page_pool = @import("page_pool.zig");
const buddy_mod = @import("buddy.zig");
const PagePtr = page_pool.PagePtr;
const PageHeader = page_pool.PageHeader;
const BuddyAllocator = buddy_mod.BuddyAllocator;

/// 每种 size class 最多缓存的页数
const MAX_PAGES_PER_CLASS: u8 = 8;
/// 最大 size class 数量（足够容纳 22+ 种对象类型）
const MAX_SIZE_CLASSES: usize = 32;
/// 大于此尺寸的对象走 BuddyAllocator
pub const MAX_PAGE_OBJECT_SIZE: usize = 256;

/// size class 缓存条目
const SizeClassCache = struct {
    object_size: u16 = 0, // 0 表示空槽
    pages: [MAX_PAGES_PER_CLASS]?PagePtr = [_]?PagePtr{null} ** MAX_PAGES_PER_CLASS,
    count: u8 = 0,
};

/// 全局池：冷路径页缓存 + 大对象分配
pub const GlobalPool = struct {
    lock: Mutex = .{},
    caches: [MAX_SIZE_CLASSES]SizeClassCache = [_]SizeClassCache{.{}} ** MAX_SIZE_CLASSES,
    buddy: BuddyAllocator,
    backing: std.mem.Allocator,

    /// 创建全局池
    pub fn init(backing: std.mem.Allocator) GlobalPool {
        return .{
            .buddy = BuddyAllocator.init(backing),
            .backing = backing,
        };
    }

    /// 释放所有缓存页
    pub fn deinit(self: *GlobalPool) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.caches) |*cache| {
            if (cache.object_size == 0) continue;
            for (&cache.pages) |*page| {
                if (page.*) |p| {
                    freePageRaw(p, cache.object_size, self.backing);
                    page.* = null;
                }
            }
            cache.count = 0;
            cache.object_size = 0;
        }
        self.buddy.deinit();
    }

    /// 查找或创建指定 object_size 的缓存条目索引
    fn findOrInsertSlot(self: *GlobalPool, object_size: u16) ?usize {
        for (&self.caches, 0..) |*cache, i| {
            if (cache.object_size == object_size) return i;
            if (cache.object_size == 0) {
                cache.object_size = object_size;
                return i;
            }
        }
        return null;
    }

    /// 获取一个指定 object_size 的页（冷路径，加锁）
    pub fn acquirePage(self: *GlobalPool, comptime object_size: usize) !PagePtr {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.findOrInsertSlot(@intCast(object_size))) |idx| {
            const cache = &self.caches[idx];
            if (cache.count > 0) {
                cache.count -= 1;
                const page = cache.pages[cache.count];
                cache.pages[cache.count] = null;
                return page.?;
            }
        }
        // 缓存为空，分配新页
        const Pool = page_pool.PagePool(object_size);
        return Pool.allocPage(self.backing);
    }

    /// 获取一个运行时已知 object_size 的页
    pub fn acquirePageRuntime(self: *GlobalPool, object_size: usize) !PagePtr {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.findOrInsertSlot(@intCast(object_size))) |idx| {
            const cache = &self.caches[idx];
            if (cache.count > 0) {
                cache.count -= 1;
                const page = cache.pages[cache.count];
                cache.pages[cache.count] = null;
                return page.?;
            }
        }
        // 缓存为空，分配新页（运行时 size 需要 switch 或函数指针）
        return allocPageRuntime(object_size, self.backing);
    }

    /// 归还一个页到缓存，缓存满则释放给 backing allocator
    pub fn returnPage(self: *GlobalPool, page: PagePtr) void {
        const hdr = page_pool.pageHeader(page);
        const obj_size = hdr.object_size;

        self.lock.lock();
        defer self.lock.unlock();

        if (self.findOrInsertSlot(obj_size)) |idx| {
            const cache = &self.caches[idx];
            if (cache.count < MAX_PAGES_PER_CLASS) {
                cache.pages[cache.count] = page;
                cache.count += 1;
                return;
            }
        }
        // 缓存满，释放
        freePageRaw(page, obj_size, self.backing);
    }

    /// 分配大对象（委托给 BuddyAllocator）
    pub fn allocLarge(self: *GlobalPool, size: usize) ![]u8 {
        return self.buddy.alloc(size);
    }

    /// 释放大对象
    pub fn freeLarge(self: *GlobalPool, ptr: []u8) void {
        self.buddy.free(ptr);
    }
};

/// 运行时已知 size 的页分配（通过 switch 分派到 comptime 实例）
fn allocPageRuntime(object_size: usize, backing: std.mem.Allocator) !PagePtr {
    // 常见对象尺寸的 comptime 路径
    switch (object_size) {
        16 => return page_pool.PagePool(16).allocPage(backing),
        24 => return page_pool.PagePool(24).allocPage(backing),
        32 => return page_pool.PagePool(32).allocPage(backing),
        40 => return page_pool.PagePool(40).allocPage(backing),
        48 => return page_pool.PagePool(48).allocPage(backing),
        56 => return page_pool.PagePool(56).allocPage(backing),
        64 => return page_pool.PagePool(64).allocPage(backing),
        80 => return page_pool.PagePool(80).allocPage(backing),
        96 => return page_pool.PagePool(96).allocPage(backing),
        112 => return page_pool.PagePool(112).allocPage(backing),
        128 => return page_pool.PagePool(128).allocPage(backing),
        144 => return page_pool.PagePool(144).allocPage(backing),
        160 => return page_pool.PagePool(160).allocPage(backing),
        176 => return page_pool.PagePool(176).allocPage(backing),
        192 => return page_pool.PagePool(192).allocPage(backing),
        256 => return page_pool.PagePool(256).allocPage(backing),
        else => {
            // 未覆盖的尺寸：直接从 backing allocator 分配 4KB 对齐页并手动初始化
            const mem = try backing.alignedAlloc(u8, .fromByteUnits(4096), page_pool.PAGE_SIZE);
            const page: PagePtr = @ptrCast(mem.ptr);
            @memset(mem, 0);
            const hdr = page_pool.pageHeader(page);
            // 对于未注册尺寸，object_count 需要运行时计算
            const n = page_pool.objectsPerPageRuntime(object_size);
            hdr.object_count = @intCast(n);
            hdr.free_count = @intCast(n);
            hdr.object_size = @intCast(object_size);
            hdr.magic = page_pool.PAGE_MAGIC;
            return page;
        },
    }
}

/// 运行时释放页内存
fn freePageRaw(page: PagePtr, object_size: u16, backing: std.mem.Allocator) void {
    _ = object_size;
    const mem: []align(page_pool.PAGE_SIZE) u8 = page[0..page_pool.PAGE_SIZE];
    backing.free(mem);
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "GlobalPool 页获取与归还" {
    var pool = GlobalPool.init(testing.allocator);
    defer pool.deinit();

    const page = try pool.acquirePage(48);
    try testing.expect(page_pool.pageHeader(page).magic == page_pool.PAGE_MAGIC);
    try testing.expectEqual(@as(u16, 48), page_pool.pageHeader(page).object_size);

    pool.returnPage(page);
}

test "GlobalPool 页缓存复用" {
    var pool = GlobalPool.init(testing.allocator);
    defer pool.deinit();

    const p1 = try pool.acquirePage(32);
    pool.returnPage(p1);

    // 再次获取应复用缓存的页
    const p2 = try pool.acquirePage(32);
    try testing.expectEqual(@intFromPtr(p1), @intFromPtr(p2));
    pool.returnPage(p2);
}

test "GlobalPool 大对象分配" {
    var pool = GlobalPool.init(testing.allocator);
    defer pool.deinit();

    const mem = try pool.allocLarge(500);
    try testing.expect(mem.len >= 500);
    @memset(mem, 0xCC);
    pool.freeLarge(mem);
}
