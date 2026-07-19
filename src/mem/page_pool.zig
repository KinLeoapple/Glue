//! 精确尺寸页池模块。
//!
//! 为每种固定大小的 ObjHeader 对象提供独立的页池分配器：
//! - 每页自包含：对象数组 + 位图 + 页头，零外部元数据
//! - 位图扫描分配/释放，热路径零锁
//! - 全空页可归还给 GlobalPool，实现零驻留
//!
//! 页布局（4KB）：
//! ```
//! [对象 0][对象 1]...[对象 N-1][位图][PageHeader]
//! ```
//! 元数据开销 < 1%，对象利用率 > 99%。

const std = @import("std");

/// 页大小，4KB
pub const PAGE_SIZE: usize = 4096;

/// 页头魔数，用于验证指针确实来自页池
pub const PAGE_MAGIC: u16 = 0xBEAF;

/// 页头，固定在每页末尾
pub const PageHeader = struct {
    object_count: u16, // 本页对象总数
    free_count: u16, // 空闲对象数
    object_size: u16, // 对象大小（反查用）
    magic: u16 = PAGE_MAGIC, // 魔数校验
};

/// 页指针类型：4KB 对齐的内存块
pub const PagePtr = [*]align(PAGE_SIZE) u8;

/// 编译期计算每页可容纳的对象数
pub fn objectsPerPage(comptime object_size: usize) usize {
    @setEvalBranchQuota(10000);
    const header_size = @sizeOf(PageHeader);
    var n: usize = 1;
    while (true) {
        const bitmap_size = ((n + 63) / 64) * @sizeOf(u64);
        if (n * object_size + bitmap_size + header_size > PAGE_SIZE) break;
        n += 1;
    }
    return n - 1;
}

/// 运行时计算每页可容纳的对象数
pub fn objectsPerPageRuntime(object_size: usize) usize {
    const header_size = @sizeOf(PageHeader);
    var n: usize = 1;
    while (true) {
        const bitmap_size = ((n + 63) / 64) * @sizeOf(u64);
        if (n * object_size + bitmap_size + header_size > PAGE_SIZE) break;
        n += 1;
    }
    return n - 1;
}

/// 判断指针是否在有效的页池页中
pub fn isPagePtr(ptr: [*]u8) bool {
    const page = pageOf(ptr);
    const hdr = pageHeader(page);
    return hdr.magic == PAGE_MAGIC;
}

/// 按指针地址反查页（4KB 对齐向下取整）
pub fn pageOf(ptr: [*]u8) PagePtr {
    const addr = @intFromPtr(ptr);
    const page_addr = addr & ~(@as(usize, PAGE_SIZE) - 1);
    return @ptrFromInt(page_addr);
}

/// 获取页头指针（位于页末尾）
pub fn pageHeader(page: PagePtr) *PageHeader {
    const offset = PAGE_SIZE - @sizeOf(PageHeader);
    return @ptrCast(@alignCast(page + offset));
}

/// 获取页位图指针（位于对象区之后）
fn pageBitmap(page: PagePtr, comptime object_size: usize, comptime N: usize) [*]u64 {
    return @ptrCast(@alignCast(page + N * object_size));
}

/// 精确尺寸页池，每种对象大小生成一个实例
pub fn PagePool(comptime object_size: usize) type {
    const N = objectsPerPage(object_size);
    const bitmap_words = (N + 63) / 64;

    return struct {
        pub const capacity = N;
        pub const obj_size = object_size;

        /// 从 backing allocator 分配一个新页并初始化
        pub fn allocPage(backing: std.mem.Allocator) !PagePtr {
            const mem = try backing.alignedAlloc(u8, .fromByteUnits(4096), PAGE_SIZE);
            const page: PagePtr = @ptrCast(mem.ptr);
            @memset(mem, 0);

            const hdr = pageHeader(page);
            hdr.object_count = @intCast(N);
            hdr.free_count = @intCast(N);
            hdr.object_size = @intCast(object_size);
            hdr.magic = PAGE_MAGIC;
            return page;
        }

        /// 归还页内存给 backing allocator
        pub fn freePage(page: PagePtr, backing: std.mem.Allocator) void {
            const mem: []align(PAGE_SIZE) u8 = page[0..PAGE_SIZE];
            backing.free(mem);
        }

        /// 从页中分配一个对象：位图扫描找空闲位
        pub fn pageAlloc(page: PagePtr) ?[]u8 {
            const hdr = pageHeader(page);
            if (hdr.free_count == 0) return null;

            const bitmap = pageBitmap(page, object_size, N)[0..bitmap_words];
            for (bitmap, 0..) |word, wi| {
                if (word == 0xFFFF_FFFF_FFFF_FFFF) continue;
                const bit = @ctz(~word);
                const idx = wi * 64 + bit;
                if (idx >= N) continue;
                bitmap[wi] |= (@as(u64, 1) << @intCast(bit));
                hdr.free_count -= 1;
                return page[idx * object_size ..][0..object_size];
            }
            return null;
        }

        /// 释放对象回页：清位图位，返回页是否全空
        pub fn pageFree(page: PagePtr, ptr: [*]u8) bool {
            const hdr = pageHeader(page);
            const page_base = @intFromPtr(page);
            const ptr_addr = @intFromPtr(ptr);
            const offset = ptr_addr - page_base;
            const idx = offset / object_size;

            const bitmap = pageBitmap(page, object_size, N);
            const wi = idx / 64;
            const bit = idx % 64;
            bitmap[wi] &= ~(@as(u64, 1) << @intCast(bit));
            hdr.free_count += 1;
            return hdr.free_count == hdr.object_count;
        }

        /// 页是否已满
        pub fn isFull(page: PagePtr) bool {
            return pageHeader(page).free_count == 0;
        }

        /// 页是否全空
        pub fn isEmpty(page: PagePtr) bool {
            const hdr = pageHeader(page);
            return hdr.free_count == hdr.object_count;
        }
    };
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "objectsPerPage 计算" {
    // 48B 对象：N*48 + ceil(N/8) + 12 <= 4096 → N=84
    try testing.expect(objectsPerPage(48) > 80);
    try testing.expect(objectsPerPage(48) < 86);

    // 16B 对象
    const n16 = objectsPerPage(16);
    try testing.expect(n16 * 16 + ((n16 + 63) / 64) * 8 + @sizeOf(PageHeader) <= PAGE_SIZE);
    try testing.expect((n16 + 1) * 16 + ((n16 + 64) / 64) * 8 + @sizeOf(PageHeader) > PAGE_SIZE);
}

test "PagePool 分配与释放" {
    const Pool = PagePool(48);
    const page = try Pool.allocPage(testing.allocator);
    defer Pool.freePage(page, testing.allocator);

    try testing.expectEqual(@as(u16, Pool.capacity), pageHeader(page).free_count);

    // 分配若干对象
    var slots: [10][]u8 = undefined;
    for (&slots) |*s| {
        s.* = Pool.pageAlloc(page) orelse return error.AllocFailed;
    }
    try testing.expectEqual(@as(u16, Pool.capacity - 10), pageHeader(page).free_count);

    // 释放部分
    for (slots[0..5]) |s| {
        _ = Pool.pageFree(page, s.ptr);
    }
    try testing.expectEqual(@as(u16, Pool.capacity - 5), pageHeader(page).free_count);

    // 再分配，应复用已释放的槽
    for (0..5) |_| {
        _ = Pool.pageAlloc(page) orelse return error.AllocFailed;
    }
    try testing.expectEqual(@as(u16, Pool.capacity - 10), pageHeader(page).free_count);
}

test "PagePool 全空检测" {
    const Pool = PagePool(32);
    const page = try Pool.allocPage(testing.allocator);
    defer Pool.freePage(page, testing.allocator);

    const slot = Pool.pageAlloc(page).?;
    try testing.expect(!Pool.isEmpty(page));

    _ = Pool.pageFree(page, slot.ptr);
    try testing.expect(Pool.isEmpty(page));
}

test "pageOf 指针反查" {
    const Pool = PagePool(64);
    const page = try Pool.allocPage(testing.allocator);
    defer Pool.freePage(page, testing.allocator);

    const slot = Pool.pageAlloc(page).?;
    const recovered = pageOf(slot.ptr);
    try testing.expectEqual(@intFromPtr(page), @intFromPtr(recovered));
    try testing.expect(isPagePtr(slot.ptr));
}

test "isPagePtr 对非页池指针返回 false" {
    var buf: [128]u8 = undefined;
    try testing.expect(!isPagePtr(&buf));
}
