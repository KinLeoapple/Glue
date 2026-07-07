//! 自实现 ArenaAllocator：基于 c_allocator 的区域分配器。
//! 分配的内存通过 chunk 链表管理，deinit 时一次性释放所有 chunk。
//!
//! 替代 std.heap.ArenaAllocator，避免依赖 Zig 原生分配器实现。
//! backing 为 std.heap.c_allocator（libc malloc/free），精确按需分配字节数。
//!
//! 特性：
//! - bump 指针分配（O(1)，无 free 操作）
//! - chunk 链表（用满则申请新 chunk）
//! - 跨平台：使用 c_allocator 的 rawAlloc/rawFree，无系统调用依赖
//! - 对齐：每次分配按 max(alignment, @alignOf(usize)) 对齐
//!
//! 用法：
//!   var arena = ArenaAllocator.init(c_allocator);
//!   defer arena.deinit();
//!   const alloc = arena.allocator();

const std = @import("std");

const DEFAULT_CHUNK_SIZE: usize = 4096;
const MIN_CHUNK_SIZE: usize = 256;

/// Chunk 链表节点
const Chunk = struct {
    /// 本 chunk 数据区长度（不含 Chunk 头）
    len: usize,
    /// 已分配字节数（bump 前沿）
    used: usize,
    /// 下一个 chunk（单链表）
    next: ?*Chunk,
    // 数据区紧随其后：data[0..len]
};

/// ArenaAllocator：bump 分配 + chunk 链表
pub const ArenaAllocator = struct {
    backing: std.mem.Allocator,
    /// 当前 chunk（最新分配的，bump 前沿在此）
    current: ?*Chunk,
    /// chunk 总数（统计用）
    chunk_count: usize,
    /// 默认 chunk 大小
    default_chunk_size: usize,

    pub fn init(backing: std.mem.Allocator) ArenaAllocator {
        return .{
            .backing = backing,
            .current = null,
            .chunk_count = 0,
            .default_chunk_size = DEFAULT_CHUNK_SIZE,
        };
    }

    /// 释放所有 chunk
    pub fn deinit(self: *ArenaAllocator) void {
        var cur = self.current;
        while (cur) |c| {
            const nxt = c.next;
            // 释放 chunk 整块（Chunk 头 + 数据区）
            const total = @sizeOf(Chunk) + c.len;
            const ptr: [*]u8 = @ptrCast(c);
            self.backing.rawFree(ptr[0..total], .@"4", @returnAddress());
            cur = nxt;
        }
        self.current = null;
        self.chunk_count = 0;
    }

    /// 返回 std.mem.Allocator 接口
    pub fn allocator(self: *ArenaAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ── vtable 实现 ──

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = &vtableAlloc,
        .resize = &vtableResize,
        .remap = &vtableRemap,
        .free = &vtableFree,
    };

    fn vtableAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(usize));

        // 尝试在当前 chunk 分配
        if (self.current) |c| {
            if (allocInChunk(c, len, a)) |ptr| return ptr;
        }

        // 当前 chunk 不够，申请新 chunk
        const chunk_size = @max(self.default_chunk_size, len + a);
        const new_chunk = self.newChunk(chunk_size, ra) orelse return null;
        // 新 chunk 插入链表头
        new_chunk.next = self.current;
        self.current = new_chunk;
        self.chunk_count += 1;

        return allocInChunk(new_chunk, len, a).?;
    }

    fn vtableResize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        _ = ctx;
        _ = alignment;
        _ = ra;
        // 仅当 new_len <= buf.len 时允许 in-place shrink（不释放内存）
        return new_len <= buf.len;
    }

    fn vtableRemap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        // shrink 直接复用原 buffer
        if (new_len <= buf.len) return buf.ptr;
        // grow：alloc 新块 + copy（旧块留在 arena 内，deinit 时统一释放）
        const new_ptr = vtableAlloc(ctx, new_len, alignment, ra) orelse return null;
        @memcpy(new_ptr[0..buf.len], buf);
        return new_ptr;
    }

    fn vtableFree(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ra;
        // ArenaAllocator 不支持单个 free：所有内存在 deinit 时统一释放
    }

    // ── 内部辅助 ──

    fn allocInChunk(chunk: *Chunk, len: usize, alignment: usize) ?[*]u8 {
        const data_start = @intFromPtr(chunk) + @sizeOf(Chunk);
        const data_end = data_start + chunk.len;
        const aligned_start = std.mem.alignForward(usize, data_start + chunk.used, alignment);
        const alloc_end = aligned_start + len;
        if (alloc_end > data_end) return null;
        chunk.used = (aligned_start + len) - data_start;
        return @ptrFromInt(aligned_start);
    }

    fn newChunk(self: *ArenaAllocator, data_size: usize, ra: usize) ?*Chunk {
        const total = @sizeOf(Chunk) + data_size;
        const ptr = self.backing.rawAlloc(total, .@"4", ra) orelse return null;
        const chunk: *Chunk = @ptrCast(@alignCast(ptr));
        chunk.* = .{ .len = data_size, .used = 0, .next = null };
        return chunk;
    }

    /// 查询已分配字节数（所有 chunk 的 used 之和）
    pub fn allocatedBytes(self: *const ArenaAllocator) usize {
        var total: usize = 0;
        var cur = self.current;
        while (cur) |c| {
            total += c.used;
            cur = c.next;
        }
        return total;
    }

    /// 查询保留字节数（所有 chunk 的 len 之和）
    pub fn reservedBytes(self: *const ArenaAllocator) usize {
        var total: usize = 0;
        var cur = self.current;
        while (cur) |c| {
            total += c.len;
            cur = c.next;
        }
        return total;
    }
};

// ============================================================
// 单元测试
// ============================================================

test "ArenaAllocator basic alloc" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const p = alloc.alloc(u32, 10) catch unreachable;
    try std.testing.expect(p.len == 10);
}

test "ArenaAllocator multiple allocs in one chunk" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const p1 = alloc.alloc(u8, 100) catch unreachable;
    const p2 = alloc.alloc(u8, 200) catch unreachable;
    // 不同指针
    try std.testing.expect(p1.ptr != p2.ptr);
    // 应该在同一个 chunk（100+200 < 4096）
    try std.testing.expect(arena.chunk_count == 1);
}

test "ArenaAllocator cross-chunk alloc" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    arena.default_chunk_size = 64; // 小 chunk 触发跨 chunk
    const alloc = arena.allocator();

    _ = alloc.alloc(u8, 50) catch unreachable;
    _ = alloc.alloc(u8, 50) catch unreachable;
    try std.testing.expect(arena.chunk_count >= 2);
}

test "ArenaAllocator alignment" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const p = alloc.alignedAlloc(u8, .@"64", 256) catch unreachable;
    try std.testing.expect(@intFromPtr(p.ptr) % 64 == 0);
}

test "ArenaAllocator free is no-op" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const p = alloc.alloc(u8, 16) catch unreachable;
    alloc.free(p); // 不应崩溃，也不应释放
    try std.testing.expect(arena.chunk_count == 1);
}

test "ArenaAllocator resize shrink" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const p = alloc.alloc(u8, 100) catch unreachable;
    // shrink 允许
    try std.testing.expect(alloc.resize(p, 50));
    // grow 不允许
    try std.testing.expect(!alloc.resize(p, 200));
}
