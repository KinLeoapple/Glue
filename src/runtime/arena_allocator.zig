//! 竞技场分配器模块。
//!
//! 提供基于链表式分块的 bump-pointer 分配器，所有分配在一次 `deinit` 中批量释放。
//! 适用于生命周期一致、无需逐个释放的临时作用域内存管理。

const std = @import("std");

// 默认分块的数据区大小。
const DEFAULT_CHUNK_SIZE: usize = 4096;

// 分块数据区的最小大小，避免过小分块造成浪费。
const MIN_CHUNK_SIZE: usize = 256;

// 分块头，记录数据区容量、已用量与链表指针。
const Chunk = struct {
    len: usize,
    used: usize,
    next: ?*Chunk,
};

/// 竞技场分配器，通过链式分块实现连续 bump 分配。
///
/// `free` 为空操作，所有内存在 `deinit` 时统一归还给底层分配器。
pub const ArenaAllocator = struct {
    backing: std.mem.Allocator,
    current: ?*Chunk,
    chunk_count: usize,
    default_chunk_size: usize,

    /// 使用指定底层分配器创建竞技场，默认分块大小为 4KB。
    pub fn init(backing: std.mem.Allocator) ArenaAllocator {
        return .{
            .backing = backing,
            .current = null,
            .chunk_count = 0,
            .default_chunk_size = DEFAULT_CHUNK_SIZE,
        };
    }

    /// 释放所有分块，归还内存给底层分配器。
    pub fn deinit(self: *ArenaAllocator) void {
        var cur = self.current;
        while (cur) |c| {
            const nxt = c.next;
            const total = @sizeOf(Chunk) + c.len;
            const ptr: [*]u8 = @ptrCast(c);
            self.backing.rawFree(ptr[0..total], .@"4", @returnAddress());
            cur = nxt;
        }
        self.current = null;
        self.chunk_count = 0;
    }

    /// 返回符合 `std.mem.Allocator` 接口的分配器句柄。
    pub fn allocator(self: *ArenaAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = &vtableAlloc,
        .resize = &vtableResize,
        .remap = &vtableRemap,
        .free = &vtableFree,
    };

    // 尝试在当前分块分配，不够则新建分块。
    fn vtableAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(usize));
        if (self.current) |c| {
            if (allocInChunk(c, len, a)) |ptr| return ptr;
        }
        // 当前分块空间不足，按需求与默认大小取较大值新建分块。
        const chunk_size = @max(self.default_chunk_size, len + a);
        const new_chunk = self.newChunk(chunk_size, ra) orelse return null;
        new_chunk.next = self.current;
        self.current = new_chunk;
        self.chunk_count += 1;
        return allocInChunk(new_chunk, len, a).?;
    }

    // 竞技场仅允许原地缩小，不支持扩展。
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
        return new_len <= buf.len;
    }

    // 扩展时分配新内存并拷贝原数据。
    fn vtableRemap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        if (new_len <= buf.len) return buf.ptr;
        const new_ptr = vtableAlloc(ctx, new_len, alignment, ra) orelse return null;
        @memcpy(new_ptr[0..buf.len], buf);
        return new_ptr;
    }

    // 竞技场中 free 为空操作，统一在 deinit 释放。
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
    }

    // 在分块数据区中按对齐要求 bump 分配。
    fn allocInChunk(chunk: *Chunk, len: usize, alignment: usize) ?[*]u8 {
        const data_start = @intFromPtr(chunk) + @sizeOf(Chunk);
        const data_end = data_start + chunk.len;
        const aligned_start = std.mem.alignForward(usize, data_start + chunk.used, alignment);
        const alloc_end = aligned_start + len;
        if (alloc_end > data_end) return null;
        chunk.used = (aligned_start + len) - data_start;
        return @ptrFromInt(aligned_start);
    }

    // 从底层分配器申请一块新的分块内存。
    fn newChunk(self: *ArenaAllocator, data_size: usize, ra: usize) ?*Chunk {
        const total = @sizeOf(Chunk) + data_size;
        const ptr = self.backing.rawAlloc(total, .@"4", ra) orelse return null;
        const chunk: *Chunk = @ptrCast(@alignCast(ptr));
        chunk.* = .{ .len = data_size, .used = 0, .next = null };
        return chunk;
    }

    /// 返回所有分块中已使用的字节数总和。
    pub fn allocatedBytes(self: *const ArenaAllocator) usize {
        var total: usize = 0;
        var cur = self.current;
        while (cur) |c| {
            total += c.used;
            cur = c.next;
        }
        return total;
    }

    /// 返回所有分块已预留（含未使用）的字节数总和。
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
    try std.testing.expect(p1.ptr != p2.ptr);
    try std.testing.expect(arena.chunk_count == 1);
}

test "ArenaAllocator cross-chunk alloc" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    arena.default_chunk_size = 64;
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
    alloc.free(p);
    try std.testing.expect(arena.chunk_count == 1);
}

test "ArenaAllocator resize shrink" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = alloc.alloc(u8, 100) catch unreachable;
    try std.testing.expect(alloc.resize(p, 50));
    try std.testing.expect(!alloc.resize(p, 200));
}
