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

/// Buddy 风格大对象分配器（完整合并实现）
pub const BuddyAllocator = struct {
    backing: std.mem.Allocator,
    lock: Mutex = .{},
    free_lists: [NUM_CLASSES]?*FreeBlock = [_]?*FreeBlock{null} ** NUM_CLASSES,
    arenas: std.ArrayList([]align(MAX_BLOCK_SIZE) u8) = .empty,
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
            self.backing.free(arena);
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
    fn growArena(self: *BuddyAllocator) !void {
        const arena = try self.backing.alignedAlloc(u8, .fromByteUnits(MAX_BLOCK_SIZE), MAX_BLOCK_SIZE);
        try self.arenas.append(self.backing, arena);

        // 将整个 arena 作为一个 MAX_BLOCK_SIZE 空闲块加入最高级 free list
        const block: *FreeBlock = @ptrCast(@alignCast(arena.ptr));
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
