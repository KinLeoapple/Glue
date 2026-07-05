//! Heap Allocator — 跟踪式堆分配器
//!
//! 目标：替代 std.heap.ArenaAllocator 用于 loader/AST 路径，提供精确的 alloc/free 跟踪
//! 与对称的 live_bytes 记账。每笔分配独立登记在 HashMap 中，free 时 O(1) 查表归还 backing。
//!
//! 设计要点：
//! - 实现 std.mem.Allocator 接口（alloc/resize/remap/free 四函数 vtable）。
//! - 所有分配登记到 live_allocs: AutoHashMap(ptr_addr → Meta{len, alignment})，
//!   free 时 O(1) 查表验证并归还 backing；未登记的指针安全忽略（兼容混合分配器场景）。
//! - live_bytes / peak_bytes 对称记账：alloc 增、free 减、resize/remap 差额补齐。
//! - deinit 释放所有未归还的分配（泄漏兜底，避免内存泄漏在 loader 重建时累积）。
//! - 不做 size class 分桶（与 SlabPool 互补：SlabPool 服务 VM value 热路径，HeapAllocator
//!   服务 loader/AST 冷路径，分配频率低且大小多样，HashMap 跟踪开销可接受）。
//!
//! 用途：loader/AST 路径（替代 ArenaAllocator）；spawn 协程 per-spawn 隔离堆（替代 page
//! ArenaAllocator）。提供与 ArenaAllocator 一致的"批量 deinit 兜底"语义，但保留精确的
//! 单次 free 跟踪能力，让 retain/release 路径的 allocator.free 调用真正回收内存。

const std = @import("std");

/// 单笔分配的元信息：len 和确保时的对齐。
/// free / resize / remap 调用方传入的 alignment 可能与 alloc 时不一致（u8 自然对齐 1），
/// 故必须按 Meta.alignment 归还 backing，否则 DebugAllocator 会报对齐不匹配。
const Meta = struct {
    len: usize,
    alignment: usize,
};

pub const HeapAllocator = struct {
    backing: std.mem.Allocator,
    live_allocs: std.AutoHashMap(usize, Meta),
    live_bytes: usize,
    peak_bytes: usize,

    pub fn init(backing: std.mem.Allocator) HeapAllocator {
        return .{
            .backing = backing,
            .live_allocs = std.AutoHashMap(usize, Meta).init(backing),
            .live_bytes = 0,
            .peak_bytes = 0,
        };
    }

    pub fn deinit(self: *HeapAllocator) void {
        // 泄漏兜底：遍历所有未归还的分配，逐个归还 backing。
        // 这保留了 ArenaAllocator 的"批量释放"语义——调用方即使忘记 free 也不会泄漏。
        var it = self.live_allocs.iterator();
        while (it.next()) |entry| {
            const meta = entry.value_ptr.*;
            const ptr: [*]u8 = @ptrFromInt(entry.key_ptr.*);
            self.backing.rawFree(
                ptr[0..meta.len],
                std.mem.Alignment.fromByteUnits(meta.alignment),
                @returnAddress(),
            );
        }
        self.live_allocs.deinit();
        self.* = undefined;
    }

    /// 返回 std.mem.Allocator 视图（实现 Allocator 接口）。
    pub fn allocator(self: *HeapAllocator) std.mem.Allocator {
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

    // ── 内部辅助 ──

    inline fn addLive(self: *HeapAllocator, n: usize) void {
        self.live_bytes += n;
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
    }

    inline fn subLive(self: *HeapAllocator, n: usize) void {
        self.live_bytes -= n;
    }

    // ── vtable ──

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        // 确保 backing 用 max(请求对齐, 8) ——与 SlabPool 一致，让后续 free 即使传 u8 自然对齐
        // 也能用 Meta.alignment 正确归还。
        const a = @max(alignment.toByteUnits(), @as(usize, 8));
        const raw = self.backing.rawAlloc(len, std.mem.Alignment.fromByteUnits(a), ret_addr) orelse return null;
        // 登记：free 时按 Meta 校验。put 失败（罕见，HashMap 扩容 OOM）则回滚。
        self.live_allocs.put(@intFromPtr(raw), .{ .len = len, .alignment = a }) catch {
            self.backing.rawFree(raw[0..len], std.mem.Alignment.fromByteUnits(a), ret_addr);
            return null;
        };
        self.addLive(len);
        return raw;
    }

    fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment; // 用 Meta.alignment 归还，不用调用方传入的 alignment
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        if (self.live_allocs.fetchRemove(key)) |entry| {
            const meta = entry.value;
            self.backing.rawFree(buf.ptr[0..meta.len], std.mem.Alignment.fromByteUnits(meta.alignment), ret_addr);
            self.subLive(meta.len);
        }
        // 未登记：安全忽略（混合分配器阶段残留的 arena 内存被误 free）
    }

    fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        const meta_ptr = self.live_allocs.getPtr(key) orelse return false;
        const old_len = meta_ptr.len;
        const old_align = meta_ptr.alignment;
        // 委托 backing 尝试原地 resize
        if (self.backing.rawResize(buf, std.mem.Alignment.fromByteUnits(old_align), new_len, ret_addr)) {
            // 成功：更新 Meta 和记账
            meta_ptr.len = new_len;
            if (new_len > old_len) {
                self.addLive(new_len - old_len);
            } else {
                self.subLive(old_len - new_len);
            }
            return true;
        }
        return false;
    }

    fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = alignment;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        const meta_ptr = self.live_allocs.getPtr(key) orelse return null;
        const old_len = meta_ptr.len;
        const old_align = meta_ptr.alignment;
        // 委托 backing 尝试 remap（可能返回原地址或新地址）
        if (self.backing.rawRemap(buf, std.mem.Alignment.fromByteUnits(old_align), new_len, ret_addr)) |new_ptr| {
            // 成功：可能地址变了，需更新 HashMap key
            if (@intFromPtr(new_ptr) != key) {
                // 地址改变：移除旧 key，登记新 key
                _ = self.live_allocs.remove(key);
                self.live_allocs.put(@intFromPtr(new_ptr), .{ .len = new_len, .alignment = old_align }) catch {
                    // put 失败极罕见；此时 new_ptr 已被 backing 分配但未登记，
                    // 调用方会继续使用 → 泄漏但不会崩溃。deinit 兜底也无法回收。
                    // 接受此风险（HashMap 扩容 OOM 在 loader 路径几乎不会发生）。
                };
            } else {
                // 地址不变：原地更新 Meta
                meta_ptr.len = new_len;
            }
            // 记账差额
            if (new_len > old_len) {
                self.addLive(new_len - old_len);
            } else {
                self.subLive(old_len - new_len);
            }
            return new_ptr;
        }
        return null;
    }
};

// ── 单测 ──

const testing = std.testing;

test "basic alloc/free roundtrip" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    const buf = try a.alloc(u8, 100);
    try testing.expect(@intFromPtr(buf.ptr) % 8 == 0);
    try testing.expect(heap.live_bytes == 100);
    try testing.expect(heap.live_allocs.count() == 1);
    a.free(buf);
    try testing.expect(heap.live_bytes == 0);
    try testing.expect(heap.live_allocs.count() == 0);
}

test "multiple allocs tracked independently" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    const b1 = try a.alloc(u8, 16);
    const b2 = try a.alloc(u8, 32);
    const b3 = try a.alloc(u32, 5);
    try testing.expect(heap.live_bytes == 16 + 32 + 20);
    try testing.expect(heap.live_allocs.count() == 3);

    a.free(b2);
    try testing.expect(heap.live_bytes == 16 + 20);
    try testing.expect(heap.live_allocs.count() == 2);

    a.free(b1);
    a.free(b3);
    try testing.expect(heap.live_bytes == 0);
}

test "leaked allocations reclaimed on deinit" {
    var heap = HeapAllocator.init(testing.allocator);
    const a = heap.allocator();
    _ = try a.alloc(u8, 64);
    _ = try a.alloc(u8, 128);
    try testing.expect(heap.live_bytes == 192);
    // 不 free，直接 deinit —— 不应泄漏到 testing.allocator
    heap.deinit();
}

test "resize in place updates accounting" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    var buf = try a.alloc(u8, 64);
    try testing.expect(heap.live_bytes == 64);

    // 尝试原地扩容（page_allocator 通常支持同页内扩展）
    if (a.resize(buf, 128)) {
        try testing.expect(heap.live_bytes == 128);
        buf.len = 128;
    }
    a.free(buf);
    try testing.expect(heap.live_bytes == 0);
}

test "create/destroy typed objects" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    const Point = struct { x: i32, y: i32 };
    const p = try a.create(Point);
    p.* = .{ .x = 10, .y = 20 };
    try testing.expect(p.x == 10);
    try testing.expect(heap.live_bytes >= @sizeOf(Point));
    a.destroy(p);
    try testing.expect(heap.live_bytes == 0);
}

test "free unknown pointer is safe no-op" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    // 不属于本 heap 的指针（用 testing.allocator 分配，heap.free 应安全忽略）
    const foreign = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(foreign);
    a.free(foreign);
    try testing.expect(heap.live_bytes == 0);
    try testing.expect(heap.live_allocs.count() == 0);
}

test "peak_bytes tracks high water mark" {
    var heap = HeapAllocator.init(testing.allocator);
    defer heap.deinit();
    const a = heap.allocator();

    const b1 = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 200);
    try testing.expect(heap.peak_bytes == 300);
    a.free(b1);
    try testing.expect(heap.peak_bytes == 300); // peak 不下降
    const b3 = try a.alloc(u8, 50);
    try testing.expect(heap.peak_bytes == 300); // 仍 < 300
    a.free(b3);
}
