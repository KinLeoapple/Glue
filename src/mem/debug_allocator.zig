//! 调试分配器模块。
//!
//! 在底层分配器之上叠加分配追踪，用于检测内存泄漏、双重释放与长度不匹配。
//! 每次分配记录地址、长度、对齐与调用点；释放时校验并从映射中移除。
//! `deinit` 时若仍有未释放记录则报告泄漏。

const std = @import("std");
const sync = @import("sync");
const Mutex = sync.Mutex;

// 单次分配的追踪记录。
const AllocRecord = struct {
    len: usize,
    alignment: usize,
    ret_addr: usize,
};

/// 调试分配器，包装底层分配器并提供泄漏与双重释放检测。
pub const DebugAllocator = struct {
    backing: std.mem.Allocator,
    alloc_map: std.AutoHashMap(usize, AllocRecord),
    single_threaded: bool,
    /// 是否在检测到泄漏 / 双重释放时打印诊断信息。
    verbose: bool = true,
    lock: Mutex = .{},

    /// 创建多线程安全的调试分配器，底层使用 C 分配器。
    pub fn init() DebugAllocator {
        return .{
            .backing = std.heap.c_allocator,
            .alloc_map = std.AutoHashMap(usize, AllocRecord).init(std.heap.c_allocator),
            .single_threaded = false,
        };
    }

    /// 创建单线程调试分配器，跳过锁操作以减少开销。
    pub fn initSingleThreaded() DebugAllocator {
        return .{
            .backing = std.heap.c_allocator,
            .alloc_map = std.AutoHashMap(usize, AllocRecord).init(std.heap.c_allocator),
            .single_threaded = true,
        };
    }

    /// 释放分配映射。若存在未释放的分配则报告泄漏并返回 `.leak`。
    pub fn deinit(self: *DebugAllocator) LeakReport {
        const leaked_count = self.alloc_map.count();
        if (leaked_count == 0) {
            self.alloc_map.deinit();
            return .ok;
        }
        if (self.verbose) {
            std.debug.print("[GLUE_GPA] LEAK: {} allocations\n", .{leaked_count});
            var it = self.alloc_map.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| {
                const rec = entry.value_ptr.*;
                std.debug.print("[GLUE_GPA]   [{d}] addr=0x{x} len={} ret_addr=0x{x}\n", .{ idx, entry.key_ptr.*, rec.len, rec.ret_addr });
                idx += 1;
            }
        }
        self.alloc_map.deinit();
        return .leak;
    }

    /// `deinit` 的检测结果：无泄漏或存在泄漏。
    pub const LeakReport = enum { ok, leak };

    /// 返回符合 `std.mem.Allocator` 接口的分配器句柄。
    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
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

    // 分配并记录到映射，检测地址冲突。
    fn vtableAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        const ptr = self.backing.rawAlloc(len, .fromByteUnits(a), ra) orelse return null;
        self.lockIf();
        // 若地址已存在记录，视为异常，回滚分配。
        if (self.alloc_map.contains(@intFromPtr(ptr))) {
            self.unlockIf();
            self.backing.rawFree(ptr[0..len], .fromByteUnits(a), ra);
            return null;
        }
        // 记录分配信息
        const rec: AllocRecord = .{
            .len = len,
            .alignment = a,
            .ret_addr = ra,
        };
        self.alloc_map.put(@intFromPtr(ptr), rec) catch {
            self.unlockIf();
            self.backing.rawFree(ptr[0..len], .fromByteUnits(a), ra);
            return null;
        };
        self.unlockIf();
        return ptr;
    }

    // 原地调整大小并同步更新记录中的长度。
    fn vtableResize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        if (self.backing.rawResize(buf, .fromByteUnits(a), new_len, ra)) {
            self.lockIf();
            if (self.alloc_map.getPtr(@intFromPtr(buf.ptr))) |rec| {
                rec.len = new_len;
            }
            self.unlockIf();
            return true;
        }
        return false;
    }

    // 尝试原地扩展，失败则分配新内存、拷贝并释放旧内存。
    fn vtableRemap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        if (self.backing.rawResize(buf, .fromByteUnits(a), new_len, ra)) {
            self.lockIf();
            if (self.alloc_map.getPtr(@intFromPtr(buf.ptr))) |rec| {
                rec.len = new_len;
            }
            self.unlockIf();
            return buf.ptr;
        }
        const new_ptr = vtableAlloc(ctx, new_len, alignment, ra) orelse return null;
        const copy_len = @min(buf.len, new_len);
        @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
        vtableFree(ctx, buf, alignment, ra);
        return new_ptr;
    }

    // 释放并校验：双重释放、长度不匹配均会打印告警。
    fn vtableFree(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        const key = @intFromPtr(buf.ptr);
        self.lockIf();
        const rec = self.alloc_map.fetchRemove(key);
        self.unlockIf();
        if (rec == null) {
            // 未找到记录，疑似双重释放或非法释放。
            if (self.verbose) {
                std.debug.print(
                    "[GLUE_GPA] DOUBLE-FREE or invalid free: addr=0x{x} len={} ret_addr=0x{x}\n",
                    .{ key, buf.len, ra },
                );
            }
            return;
        }
        const actual = rec.?.value;
        if (actual.len != buf.len) {
            // 释放长度与分配长度不一致，按原始长度归还底层。
            if (self.verbose) {
                std.debug.print(
                    "[GLUE_GPA] free len mismatch: addr=0x{x} alloc_len={} free_len={} ret_addr=0x{x}\n",
                    .{ key, actual.len, buf.len, ra },
                );
            }
            self.backing.rawFree(
                @as([*]u8, @ptrCast(buf.ptr))[0..actual.len],
                .fromByteUnits(actual.alignment),
                ra,
            );
            return;
        }
        self.backing.rawFree(buf, .fromByteUnits(a), ra);
    }

    // 多线程模式下加锁，单线程模式下空操作。
    inline fn lockIf(self: *DebugAllocator) void {
        if (!self.single_threaded) self.lock.lock();
    }

    inline fn unlockIf(self: *DebugAllocator) void {
        if (!self.single_threaded) self.lock.unlock();
    }
};

test "DebugAllocator basic alloc/free" {
    var dbg = DebugAllocator.initSingleThreaded();
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();
    const p = alloc.alloc(u32, 10) catch unreachable;
    defer alloc.free(p);
    try std.testing.expect(p.len == 10);
}

test "DebugAllocator leak detection" {
    var dbg = DebugAllocator.initSingleThreaded();
    dbg.verbose = false;
    const alloc = dbg.allocator();
    _ = alloc.alloc(u8, 100) catch unreachable;
    const report = dbg.deinit();
    try std.testing.expect(report == .leak);
}

test "DebugAllocator double-free detection" {
    var dbg = DebugAllocator.initSingleThreaded();
    dbg.verbose = false;
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();
    const p = alloc.alloc(u8, 16) catch unreachable;
    alloc.free(p);
    alloc.free(p);
}

test "DebugAllocator alignment" {
    var dbg = DebugAllocator.initSingleThreaded();
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();
    const p = alloc.alignedAlloc(u8, .@"64", 256) catch unreachable;
    defer alloc.free(p);
    try std.testing.expect(@intFromPtr(p.ptr) % 64 == 0);
}
