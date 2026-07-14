//! Buddy 分配器模块。
//!
//! 为大于 256B 的大对象（大数组、大字符串、大 record）提供分配服务。
//! 采用按 2 的幂分级的空闲链表缓存，分配时向上取整到最近的 2 的幂。
//!
//! 设计简化说明：
//! 本实现使用带 size class 的空闲链表缓存，不实现 buddy 合并。
//! 大对象生命周期通常较长，碎片可接受；后续可扩展为完整 buddy 合并。

const std = @import("std");
const sync = @import("sync");
const Mutex = sync.Mutex;

/// 最小块大小（512B）
pub const MIN_BLOCK_SIZE: usize = 512;
/// 最大块大小（1MB）
pub const MAX_BLOCK_SIZE: usize = 1 << 20;
/// size class 数量
pub const NUM_CLASSES: usize = blk: {
    var n: usize = 0;
    var s: usize = MIN_BLOCK_SIZE;
    while (s <= MAX_BLOCK_SIZE) : (s *= 2) n += 1;
    break :blk n;
};

/// 空闲链表节点，嵌入在空闲块的开头
const FreeNode = struct {
    block_size: usize, // 实际块大小
    next: ?*FreeNode,
};

/// 计算请求大小对应的 size class 索引
fn classIndex(size: usize) usize {
    if (size <= MIN_BLOCK_SIZE) return 0;
    var idx: usize = 0;
    var s: usize = MIN_BLOCK_SIZE;
    while (s < size) : (s *= 2) idx += 1;
    return @min(idx, NUM_CLASSES - 1);
}

/// 计算请求大小对应的实际块大小（2 的幂）
fn roundUpSize(size: usize) usize {
    if (size <= MIN_BLOCK_SIZE) return MIN_BLOCK_SIZE;
    var s: usize = MIN_BLOCK_SIZE;
    while (s < size) : (s *= 2) {}
    return @min(s, MAX_BLOCK_SIZE);
}

/// Buddy 风格大对象分配器
pub const BuddyAllocator = struct {
    backing: std.mem.Allocator,
    lock: Mutex = .{},
    free_lists: [NUM_CLASSES]?*FreeNode = [_]?*FreeNode{null} ** NUM_CLASSES,

    /// 创建分配器
    pub fn init(backing: std.mem.Allocator) BuddyAllocator {
        return .{ .backing = backing };
    }

    /// 释放所有缓存的空闲块
    pub fn deinit(self: *BuddyAllocator) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.free_lists) |*list| {
            while (list.*) |node| {
                list.* = node.next;
                const ptr = @as([*]u8, @ptrCast(node))[0..node.block_size];
                self.backing.free(ptr);
            }
        }
    }

    /// 分配指定大小的内存块。返回的块大小可能是 2 的幂向上取整。
    pub fn alloc(self: *BuddyAllocator, size: usize) ![]u8 {
        const idx = classIndex(size);

        self.lock.lock();
        defer self.lock.unlock();

        // 从对应 class 及更大的 class 查找空闲块
        var i = idx;
        while (i < NUM_CLASSES) : (i += 1) {
            if (self.free_lists[i]) |node| {
                if (node.block_size >= size) {
                    self.free_lists[i] = node.next;
                    return @as([*]u8, @ptrCast(node))[0..node.block_size];
                }
            }
        }

        // 从 backing allocator 分配
        const block_size = roundUpSize(size);
        return self.backing.alloc(u8, block_size);
    }

    /// 释放内存块，归还到空闲链表缓存
    pub fn free(self: *BuddyAllocator, ptr: []u8) void {
        const idx = classIndex(ptr.len);

        self.lock.lock();
        defer self.lock.unlock();

        const node: *FreeNode = @ptrCast(@alignCast(ptr.ptr));
        node.block_size = ptr.len;
        node.next = self.free_lists[idx];
        self.free_lists[idx] = node;
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
    try testing.expect(mem.len >= 600);

    // 写入数据验证
    @memset(mem, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), mem[0]);

    buddy.free(mem);
}

test "BuddyAllocator 缓存复用" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const m1 = try buddy.alloc(512);
    buddy.free(m1);

    // 第二次分配相同大小，应从缓存复用
    const m2 = try buddy.alloc(512);
    try testing.expectEqual(m1.ptr, m2.ptr);
    buddy.free(m2);
}

test "BuddyAllocator 不同大小分配" {
    var buddy = BuddyAllocator.init(testing.allocator);
    defer buddy.deinit();

    const sizes = [_]usize{ 256, 512, 1024, 4096, 8192 };
    var ptrs: [sizes.len][]u8 = undefined;
    for (sizes, 0..) |s, i| {
        ptrs[i] = try buddy.alloc(s);
        try testing.expect(ptrs[i].len >= s);
    }
    for (ptrs) |p| buddy.free(p);
}
