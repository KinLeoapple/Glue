//! 自实现 DebugAllocator：在 c_allocator（libc malloc）之上叠加分配追踪，
//! deinit 时检测泄漏（未 free 的分配）和 double-free（重复 free 同一指针）。
//!
//! 替代 std.heap.DebugAllocator，避免依赖 Zig 原生分配器实现。
//! backing 为 std.heap.c_allocator（libc malloc/free），精确按需分配字节数。
//!
//! 用法：
//!   var dbg = DebugAllocator.init();
//!   defer _ = dbg.deinit();  // 报告泄漏
//!   const alloc = dbg.allocator();
//!
//! 线程安全：内部 Mutex 保护 alloc_map。单线程场景（VM 主线程）可用 initSingleThreaded 跳过锁。

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync");

const Mutex = sync.Mutex;

/// 分配追踪记录
const AllocRecord = struct {
    len: usize,
    /// 0 = 无对齐要求（默认指针自然对齐），否则为请求的对齐字节数。
    alignment: usize,
    /// 分配时的返回地址（用于泄漏堆栈定位）。
    ret_addr: usize,
};

/// DebugAllocator：c_allocator + 分配追踪 + 泄漏/double-free 检测。
pub const DebugAllocator = struct {
    backing: std.mem.Allocator,
    /// 分配指针 → 记录。所有未释放的分配在此。
    alloc_map: std.AutoHashMap(usize, AllocRecord),
    /// 单线程模式跳过锁。
    single_threaded: bool,
    lock: Mutex = .{},

    pub fn init() DebugAllocator {
        return .{
            .backing = std.heap.c_allocator,
            .alloc_map = std.AutoHashMap(usize, AllocRecord).init(std.heap.c_allocator),
            .single_threaded = false,
        };
    }

    pub fn initSingleThreaded() DebugAllocator {
        return .{
            .backing = std.heap.c_allocator,
            .alloc_map = std.AutoHashMap(usize, AllocRecord).init(std.heap.c_allocator),
            .single_threaded = true,
        };
    }

    /// 释放追踪表并检测泄漏。返回 .leak 表示有未释放的分配。
    pub fn deinit(self: *DebugAllocator) LeakReport {
        const leaked_count = self.alloc_map.count();
        if (leaked_count == 0) {
            self.alloc_map.deinit();
            return .ok;
        }
        // 报告泄漏：输出首个泄漏的地址和大小（避免海量输出）
        var it = self.alloc_map.iterator();
        if (it.next()) |entry| {
            const rec = entry.value_ptr.*;
            std.debug.print(
                "[GLUE_DBG] LEAK: addr=0x{x} len={} align={} ret_addr=0x{x}\n",
                .{ entry.key_ptr.*, rec.len, rec.alignment, rec.ret_addr },
            );
        }
        std.debug.print("[GLUE_DBG] total leaked allocations: {}\n", .{leaked_count});
        self.alloc_map.deinit();
        return .leak;
    }

    pub const LeakReport = enum { ok, leak };

    /// 返回 std.mem.Allocator 接口（vtable 委托给 alloc/free/remap 函数）。
    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
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
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        const ptr = self.backing.rawAlloc(len, .fromByteUnits(a), ra) orelse return null;
        self.lockIf();
        // double-alloc 同一指针：理论不可能（malloc 不返回在用指针），但防御性检查
        if (self.alloc_map.contains(@intFromPtr(ptr))) {
            self.unlockIf();
            // 严重错误：释放新分配并返回 null
            self.backing.rawFree(ptr[0..len], .fromByteUnits(a), ra);
            return null;
        }
        self.alloc_map.put(@intFromPtr(ptr), .{
            .len = len,
            .alignment = a,
            .ret_addr = ra,
        }) catch {
            self.unlockIf();
            self.backing.rawFree(ptr[0..len], .fromByteUnits(a), ra);
            return null;
        };
        self.unlockIf();
        return ptr;
    }

    fn vtableResize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        // 尝试 in-place resize：成功则更新记录长度
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

    fn vtableRemap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        // 尝试 in-place remap（rawResize）；失败则 alloc 新块 + copy + free 旧块
        const a = @max(alignment.toByteUnits(), @alignOf(std.c.max_align_t));
        if (self.backing.rawResize(buf, .fromByteUnits(a), new_len, ra)) {
            self.lockIf();
            if (self.alloc_map.getPtr(@intFromPtr(buf.ptr))) |rec| {
                rec.len = new_len;
            }
            self.unlockIf();
            return buf.ptr;
        }
        // 退路：分配新块并复制
        const new_ptr = vtableAlloc(ctx, new_len, alignment, ra) orelse return null;
        const copy_len = @min(buf.len, new_len);
        @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
        vtableFree(ctx, buf, alignment, ra);
        return new_ptr;
    }

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
            // double-free 或非法 free：报告但不调用 backing.free（避免崩溃）
            std.debug.print(
                "[GLUE_DBG] DOUBLE-FREE or invalid free: addr=0x{x} len={} ret_addr=0x{x}\n",
                .{ key, buf.len, ra },
            );
            return;
        }
        // 校验长度一致性（可选，避免传错 len）
        const actual = rec.?.value;
        if (actual.len != buf.len) {
            std.debug.print(
                "[GLUE_DBG] free len mismatch: addr=0x{x} alloc_len={} free_len={} ret_addr=0x{x}\n",
                .{ key, actual.len, buf.len, ra },
            );
            // 用 alloc 时的真实长度释放
            self.backing.rawFree(
                @as([*]u8, @ptrCast(buf.ptr))[0..actual.len],
                .fromByteUnits(actual.alignment),
                ra,
            );
            return;
        }
        self.backing.rawFree(buf, .fromByteUnits(a), ra);
    }

    inline fn lockIf(self: *DebugAllocator) void {
        if (!self.single_threaded) self.lock.lock();
    }

    inline fn unlockIf(self: *DebugAllocator) void {
        if (!self.single_threaded) self.lock.unlock();
    }
};

// ============================================================
// 单元测试
// ============================================================

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
    const alloc = dbg.allocator();

    _ = alloc.alloc(u8, 100) catch unreachable; // 故意泄漏
    const report = dbg.deinit();
    try std.testing.expect(report == .leak);
}

test "DebugAllocator double-free detection" {
    var dbg = DebugAllocator.initSingleThreaded();
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();

    const p = alloc.alloc(u8, 16) catch unreachable;
    alloc.free(p);
    // 第二次 free：应触发 double-free 报告（打印到 stderr，不崩溃）
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
