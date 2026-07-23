//! Buddy 分配器模块（完整合并实现）。
//!
//! 为大于 256B 的大对象（大数组、大字符串、大 record）提供分配服务。
//! 采用标准 buddy 算法：2 的幂分级、分裂分配、伙伴合并释放。
//!
//! 设计要点：
//! - 管理 MAX_BLOCK_SIZE 对齐的 arena，每个 arena 独立维护 buddy 树
//! - 每块开头存 BuddyHeader（block_size），用户指针 = 块起始 + HEADER_SIZE
//! - 分配时向上取整到 2 的幂，不足时从更大块分裂
//! - 释放时递归合并伙伴块，直到伙伴不可用或达到 MAX_BLOCK_SIZE
//! - 热路径仅位运算 + 链表操作，无系统调用

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync");
const Mutex = sync.Mutex;

/// 最小块大小（512B）
pub const MIN_BLOCK_SIZE: usize = 512;
/// 最大块大小（1MB）
pub const MAX_BLOCK_SIZE: usize = 1 << 20;
/// size class 数量（512B 到 1MB，共 12 级）
pub const NUM_CLASSES: usize = blk: {
    var n: usize = 0;
    var s: usize = MIN_BLOCK_SIZE;
    while (s <= MAX_BLOCK_SIZE) : (s *= 2) n += 1;
    break :blk n;
};
/// 用户数据前的隐藏 header 大小（16B，保证用户数据 16B 对齐）
pub const HEADER_SIZE: usize = 16;

/// 空闲块链表节点（嵌入在空闲块开头）
/// 占用 24B，MIN_BLOCK_SIZE=512B 足够容纳
const FreeBlock = struct {
    header: BuddyHeader,
    next: ?*FreeBlock,
    prev: ?*FreeBlock,
};

/// 块头（分配和空闲时均有效，存储 block_size）
pub const BuddyHeader = extern struct {
    block_size: usize, // 实际 buddy 块大小（2 的幂）
    is_free: u8 = 0, // 1=空闲，0=已分配
    _pad: [7]u8 = [_]u8{0} ** 7, // 填充至 16B，保证用户数据 16B 对齐
};

/// Arena 标识魔数（用于验证指针来自 buddy）
pub const ARENA_MAGIC: u64 = 0x42554444_5941524E; // "BUDDYARN"

/// 计算请求大小对应的 size class 索引
fn classIndex(size: usize) usize {
    if (size <= MIN_BLOCK_SIZE) return 0;
    return @ctz(size) - @ctz(MIN_BLOCK_SIZE);
}

/// 计算请求大小对应的实际块大小（2 的幂向上取整）
fn roundUpSize(size: usize) usize {
    if (size <= MIN_BLOCK_SIZE) return MIN_BLOCK_SIZE;
    const pot = std.math.ceilPowerOfTwo(usize, size) catch return MAX_BLOCK_SIZE;
    return @min(pot, MAX_BLOCK_SIZE);
}

// =============================================================================
// Arena 内存分配：跨平台、零浪费、绕过 backing allocator
//
// buddy 的 arena 需要 alignment 对齐的 size 字节内存。某些平台的 backing allocator
//（如 Windows 的 std.heap.page_allocator）对超页对齐走 placeholder API 会失败。
// 此处直接调用 OS 层 API（POSIX mmap / Windows NtAllocateVirtualMemory），
// overalloc 后修剪前缀和后缀归还 OS，最终只保留 [aligned_addr, aligned_addr+size)，
// 零内存浪费。arena 不经过 backing，由 deinit 显式管理生命周期。
// =============================================================================

/// 申请一块 alignment 对齐、size 字节的 arena 内存。
/// 返回的切片指针满足 alignment 对齐，长度 = size（页对齐向上取整）。
/// 调用方负责用 arenaFree 释放。
fn arenaAlloc(size: usize, alignment: usize) ![]u8 {
    if (builtin.os.tag == .windows) {
        return arenaAllocWindows(size, alignment);
    } else {
        return arenaAllocPosix(size, alignment);
    }
}

/// 释放 arenaAlloc 返回的切片
fn arenaFree(buf: []u8) void {
    if (builtin.os.tag == .windows) {
        arenaFreeWindows(buf);
    } else {
        // POSIX: munmap 释放整段映射
        std.posix.munmap(@alignCast(buf));
    }
}

/// POSIX arena 分配：mmap overalloc + alignPointer + munmap 修剪前缀后缀
fn arenaAllocPosix(size: usize, alignment: usize) ![]u8 {
    const page_size = std.heap.page_size_min;
    const page_aligned_len = std.mem.alignForward(usize, size, page_size);
    // alignment > page_size 时需要 overalloc 以保证有对齐窗口；否则直接页对齐分配
    const max_drop_len = alignment -| page_size;
    const overalloc_len = page_aligned_len + max_drop_len;

    const slice = try std.posix.mmap(
        null,
        overalloc_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    const result_ptr = std.mem.alignPointer(slice.ptr, alignment) orelse {
        std.posix.munmap(slice);
        return error.OutOfMemory;
    };

    // 修剪前缀 [slice.ptr, result_ptr)
    const drop_len = @intFromPtr(result_ptr) - @intFromPtr(slice.ptr);
    if (drop_len != 0) {
        std.posix.munmap(slice[0..drop_len]);
    }
    // 修剪后缀 [result_ptr + page_aligned_len, slice.ptr + overalloc_len)
    const remaining_len = overalloc_len - drop_len;
    if (remaining_len > page_aligned_len) {
        const suffix = result_ptr[page_aligned_len..remaining_len];
        std.posix.munmap(@alignCast(suffix));
    }

    return @alignCast(result_ptr[0..page_aligned_len]);
}

/// Windows arena 分配：NtAllocateVirtualMemory overalloc + NtFreeVirtualMemory 修剪前缀后缀
fn arenaAllocWindows(size: usize, alignment: usize) ![]u8 {
    const w = std.os.windows;
    const ntdll = w.ntdll;
    const page_size = std.heap.page_size_min;
    const page_aligned_len = std.mem.alignForward(usize, size, page_size);
    // Windows 分配粒度为 64KB，NtAllocateVirtualMemory(BaseAddress=NULL) 返回 64KB 对齐地址。
    // alignment > 64KB 时需要 overalloc 以保证有对齐窗口。
    const alloc_granularity: usize = 0x10000;
    const max_drop_len = if (alignment > alloc_granularity) alignment - alloc_granularity else 0;
    const overalloc_len = page_aligned_len + max_drop_len;

    const current_process = w.GetCurrentProcess();
    // base 用 ?*anyopaque 以便能初始化为 null（PVOID 是 *anyopaque，不可空）
    var base: ?*anyopaque = null;
    var region_size: w.SIZE_T = overalloc_len;
    const alloc_type: w.MEM.ALLOCATE = .{ .COMMIT = true, .RESERVE = true };
    const protect: w.PAGE = .{ .READWRITE = true };

    const status = ntdll.NtAllocateVirtualMemory(current_process, @ptrCast(&base), 0, &region_size, alloc_type, protect);
    if (status != .SUCCESS) return error.OutOfMemory;

    const base_addr = @intFromPtr(base);
    const aligned_addr = std.mem.alignForward(usize, base_addr, alignment);
    const result_ptr: [*]u8 = @ptrFromInt(aligned_addr);

    // 修剪前缀 [base_addr, aligned_addr)
    const prefix_len = aligned_addr - base_addr;
    if (prefix_len != 0) {
        var prefix_base: ?*anyopaque = @ptrFromInt(base_addr);
        var prefix_size: w.SIZE_T = prefix_len;
        _ = ntdll.NtFreeVirtualMemory(current_process, @ptrCast(&prefix_base), &prefix_size, .{ .RELEASE = true });
    }

    // 修剪后缀 [aligned_addr + page_aligned_len, base_addr + overalloc_len)
    const suffix_start = aligned_addr + page_aligned_len;
    const suffix_len = base_addr + overalloc_len - suffix_start;
    if (suffix_len != 0) {
        var suffix_base: ?*anyopaque = @ptrFromInt(suffix_start);
        var suffix_size: w.SIZE_T = suffix_len;
        _ = ntdll.NtFreeVirtualMemory(current_process, @ptrCast(&suffix_base), &suffix_size, .{ .RELEASE = true });
    }

    return result_ptr[0..page_aligned_len];
}

/// Windows arena 释放：NtFreeVirtualMemory(RELEASE) 释放整段
fn arenaFreeWindows(buf: []u8) void {
    const w = std.os.windows;
    const ntdll = w.ntdll;
    const current_process = w.GetCurrentProcess();
    var base: ?*anyopaque = @ptrCast(buf.ptr);
    var size: w.SIZE_T = buf.len;
    _ = ntdll.NtFreeVirtualMemory(current_process, @ptrCast(&base), &size, .{ .RELEASE = true });
}

/// Buddy 风格大对象分配器（完整合并实现）
pub const BuddyAllocator = struct {
    backing: std.mem.Allocator,
    lock: Mutex = .{},
    free_lists: [NUM_CLASSES]?*FreeBlock = [_]?*FreeBlock{null} ** NUM_CLASSES,
    // arena 由 OS 层 API 直接分配（arenaAlloc），1MB 对齐、零浪费，不经过 backing。
    // backing 仅用于 large_allocs 和 arenas 列表自身的元数据。
    arenas: std.ArrayList([]u8) = .empty,
    // 超大对象（> MAX_BLOCK_SIZE）直接走 backing，独立跟踪以便 deinit 释放
    large_allocs: std.ArrayList([]align(16) u8) = .empty,

    /// 创建分配器
    pub fn init(backing: std.mem.Allocator) BuddyAllocator {
        return .{ .backing = backing };
    }

    /// 释放所有 arena 和超大对象
    pub fn deinit(self: *BuddyAllocator) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.arenas.items) |arena| {
            arenaFree(arena);
        }
        self.arenas.deinit(self.backing);
        // 释放残留的超大对象
        for (self.large_allocs.items) |mem| {
            self.backing.free(mem);
        }
        self.large_allocs.deinit(self.backing);
        self.free_lists = [_]?*FreeBlock{null} ** NUM_CLASSES;
    }

    /// 分配一个新 arena 并加入 free list
    /// 通过 OS 层 API（arenaAlloc）获取 1MB 对齐、1MB 大小的内存，前缀后缀已归还 OS，零浪费。
    /// buddy 树根即切片起点，满足 1MB 对齐，free() 中的 arena_base = block_addr & ~(MAX_BLOCK_SIZE-1) 算式不变。
    fn growArena(self: *BuddyAllocator) !void {
        const buf = try arenaAlloc(MAX_BLOCK_SIZE, MAX_BLOCK_SIZE);
        try self.arenas.append(self.backing, buf);

        // 将整个 arena 作为一个 MAX_BLOCK_SIZE 空闲块加入最高级 free list
        const block: *FreeBlock = @ptrCast(@alignCast(buf.ptr));
        block.header.block_size = MAX_BLOCK_SIZE;
        block.header.is_free = 1;
        block.next = null;
        block.prev = null;
        const top_idx = NUM_CLASSES - 1;
        self.free_lists[top_idx] = block;
    }

    /// 从 free list 移除块
    fn removeFromList(self: *BuddyAllocator, idx: usize, block: *FreeBlock) void {
        if (block.prev) |p| {
            p.next = block.next;
        } else {
            self.free_lists[idx] = block.next;
        }
        if (block.next) |n| {
            n.prev = block.prev;
        }
        block.header.is_free = 0;
    }

    /// 加入 free list 头部
    fn addToList(self: *BuddyAllocator, idx: usize, block: *FreeBlock) void {
        block.header.is_free = 1;
        block.prev = null;
        block.next = self.free_lists[idx];
        if (self.free_lists[idx]) |head| {
            head.prev = block;
        }
        self.free_lists[idx] = block;
    }

    /// 分配指定大小的内存块
    /// 返回的切片长度 = 用户请求的 size（不含 HEADER_SIZE）
    pub fn alloc(self: *BuddyAllocator, size: usize) ![]u8 {
        // 用户请求 size + HEADER_SIZE → 实际块大小
        const total = size + HEADER_SIZE;

        // 超大对象（> MAX_BLOCK_SIZE）：直接走 backing，header 标记 block_size > MAX_BLOCK_SIZE
        // 这避免了 roundUpSize 截断到 MAX_BLOCK_SIZE 导致的缓冲区溢出
        if (total > MAX_BLOCK_SIZE) {
            self.lock.lock();
            defer self.lock.unlock();
            const mem = try self.backing.alignedAlloc(u8, .fromByteUnits(16), total);
            const block: *FreeBlock = @ptrCast(@alignCast(mem.ptr));
            block.header.block_size = total; // 记录实际总大小，> MAX_BLOCK_SIZE 标识超大对象
            block.header.is_free = 0;
            try self.large_allocs.append(self.backing, mem);
            const user_ptr = @as([*]u8, @ptrCast(block)) + HEADER_SIZE;
            return user_ptr[0..size];
        }

        const block_size = roundUpSize(total);
        const idx = classIndex(block_size);

        self.lock.lock();
        defer self.lock.unlock();

        // 在 idx 及以上 class 查找空闲块
        var found: ?*FreeBlock = null;
        var found_idx = idx;
        while (found_idx < NUM_CLASSES) : (found_idx += 1) {
            if (self.free_lists[found_idx]) |b| {
                found = b;
                break;
            }
        }

        if (found == null) {
            // 无可用块，分配新 arena
            try self.growArena();
            found_idx = NUM_CLASSES - 1;
            found = self.free_lists[found_idx] orelse return error.OutOfMemory;
        }

        // 移除找到的块
        self.removeFromList(found_idx, found.?);

        // 分裂到目标大小
        var block = found.?;
        var cur_idx = found_idx;
        while (cur_idx > idx) {
            cur_idx -= 1;
            const cur_size = @as(usize, MIN_BLOCK_SIZE) << @intCast(cur_idx);
            // 分裂：前半保留，后半加入 free list
            const buddy_addr = @intFromPtr(block) + cur_size;
            const buddy: *FreeBlock = @ptrFromInt(buddy_addr);
            buddy.header.block_size = cur_size;
            self.addToList(cur_idx, buddy);
            // block 保持前半，更新 block_size
            block.header.block_size = cur_size;
        }

        // 标记为已分配（block_size 已在 header 中）
        const user_ptr = @as([*]u8, @ptrCast(block)) + HEADER_SIZE;
        return user_ptr[0..size];
    }

    /// 释放内存块，递归合并伙伴
    /// ptr 必须是 alloc 返回的用户指针
    pub fn free(self: *BuddyAllocator, ptr: []u8) void {
        const block_addr = @intFromPtr(ptr.ptr) - HEADER_SIZE;
        var block: *FreeBlock = @ptrFromInt(block_addr);
        const stored_size = block.header.block_size;

        // 超大对象：block_size > MAX_BLOCK_SIZE 标识直接走 backing 分配
        if (stored_size > MAX_BLOCK_SIZE) {
            self.lock.lock();
            defer self.lock.unlock();
            const total = stored_size;
            const mem: []align(16) u8 = @as([*]align(16) u8, @alignCast(@ptrCast(block)))[0..total];
            // 从 large_allocs 移除并释放
            for (self.large_allocs.items, 0..) |item, i| {
                if (item.ptr == @as([*]u8, @ptrCast(block))) {
                    _ = self.large_allocs.swapRemove(i);
                    break;
                }
            }
            self.backing.free(mem);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        var cur_size = stored_size;

        // 递归合并伙伴
        while (cur_size < MAX_BLOCK_SIZE) {
            // 计算伙伴地址：arena_base + (offset XOR cur_size)
            const arena_base = block_addr & ~(@as(usize, MAX_BLOCK_SIZE) - 1);
            const offset = block_addr - arena_base;
            const buddy_offset = offset ^ cur_size;
            const buddy_addr = arena_base + buddy_offset;

            // 伙伴地址必须在同一 arena 内
            if (buddy_addr < arena_base or buddy_addr >= arena_base + MAX_BLOCK_SIZE) break;
            // 伙伴地址不能等于自己（offset XOR cur_size == offset 时表示已是第一个块）
            if (buddy_addr == block_addr) break;

            const buddy: *FreeBlock = @ptrFromInt(buddy_addr);
            // 检查伙伴是否空闲且大小相同（O(1) 检查）
            if (buddy.header.block_size != cur_size) break;
            if (buddy.header.is_free != 1) break;

            // 移除伙伴并合并
            const buddy_idx = classIndex(cur_size);
            self.removeFromList(buddy_idx, buddy);

            // 合并后取较小地址作为新块
            const merged_addr = @min(block_addr, buddy_addr);
            const merged: *FreeBlock = @ptrFromInt(merged_addr);
            merged.header.block_size = cur_size * 2;
            block = merged;
            cur_size *= 2;
        }

        // 加入对应 free list
        const final_idx = classIndex(cur_size);
        block.header.block_size = cur_size;
        self.addToList(final_idx, block);
    }
};

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "BuddyAllocator 分配与释放" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const mem = try buddy.alloc(600);
    try testing.expect(mem.len == 600);

    @memset(mem, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), mem[0]);

    buddy.free(mem);
}

test "BuddyAllocator 缓存复用" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const m1 = try buddy.alloc(512);
    buddy.free(m1);

    // 第二次分配相同大小，应从 free list 复用
    const m2 = try buddy.alloc(512);
    try testing.expectEqual(@intFromPtr(m1.ptr), @intFromPtr(m2.ptr));
    buddy.free(m2);
}

test "BuddyAllocator 不同大小分配" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const sizes = [_]usize{ 256, 512, 1024, 4096, 8192 };
    var ptrs: [sizes.len][]u8 = undefined;
    for (sizes, 0..) |s, i| {
        ptrs[i] = try buddy.alloc(s);
        try testing.expect(ptrs[i].len == s);
    }
    for (ptrs) |p| buddy.free(p);
}

test "BuddyAllocator 分裂与合并" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    // 分配多个小块触发分裂
    var ptrs: [16][]u8 = undefined;
    for (&ptrs) |*p| {
        p.* = try buddy.alloc(512);
    }
    // 全部释放后应合并回一个 MAX_BLOCK_SIZE 块
    for (ptrs) |p| buddy.free(p);

    // 再次分配大块应成功（证明合并有效）
    const big = try buddy.alloc(512 * 1024);
    try testing.expect(big.len == 512 * 1024);
    buddy.free(big);
}

test "BuddyAllocator 合并后复用" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    // 分配两个相邻块
    const a = try buddy.alloc(512);
    const b = try buddy.alloc(512);
    buddy.free(a);
    buddy.free(b);

    // 合并后应能分配 1024 块
    const c = try buddy.alloc(1024);
    try testing.expect(c.len == 1024);
    buddy.free(c);
}

test "BuddyAllocator 16B 对齐" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const m = try buddy.alloc(100);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(m.ptr) % 16);
    buddy.free(m);
}

test "BuddyAllocator 大量分配无碎片" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    // 模拟 fib 递归：大量小对象创建释放
    var ptrs: [100][]u8 = undefined;
    for (&ptrs) |*p| {
        p.* = try buddy.alloc(64);
    }
    for (ptrs) |p| buddy.free(p);

    // 重复多轮，验证合并有效
    for (0..10) |_| {
        for (&ptrs) |*p| {
            p.* = try buddy.alloc(64);
        }
        for (ptrs) |p| buddy.free(p);
    }
}
