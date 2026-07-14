//! 影子竞技场模块。
//!
//! 为函数级临时数据（格式化缓冲区、中间计算结果）提供 bump+reset 分配：
//! - 16B 对齐，满足 SSE/NEON
//! - 零元数据，零碎片
//! - 函数返回时 O(1) reset

const std = @import("std");

/// 临时作用域线性区
pub const ShadowArena = struct {
    data: ?[*]align(16) u8 = null, // 16B 对齐
    len: usize = 0,
    used: usize = 0,
    backing: std.mem.Allocator,

    /// 创建空竞技场
    pub fn init(backing: std.mem.Allocator) ShadowArena {
        return .{ .backing = backing };
    }

    /// 释放底层内存
    pub fn deinit(self: *ShadowArena) void {
        if (self.data) |d| {
            self.backing.free(d[0..self.len]);
            self.data = null;
            self.len = 0;
            self.used = 0;
        }
    }

    /// 分配 size 字节，16B 对齐
    pub fn alloc(self: *ShadowArena, size: usize) ![]u8 {
        const aligned = std.mem.alignForward(usize, self.used, 16);
        if (self.data != null and aligned + size <= self.len) {
            const ptr = self.data.? + aligned;
            self.used = aligned + size;
            return ptr[0..size];
        }

        // 倍增扩容
        const new_len = @max(self.len * 2, aligned + size, 256);
        const new_data = try self.backing.alignedAlloc(u8, .@"16", new_len);
        if (self.data) |d| {
            @memcpy(new_data[0..self.used], d[0..self.used]);
            self.backing.free(d[0..self.len]);
        }
        self.data = new_data.ptr;
        self.len = new_len;
        return self.alloc(size);
    }

    /// 函数返回时 reset，O(1)
    pub fn reset(self: *ShadowArena) void {
        self.used = 0;
    }
};

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "ShadowArena 分配与 reset" {
    var arena = ShadowArena.init(testing.allocator);
    defer arena.deinit();

    const m1 = try arena.alloc(100);
    @memset(m1, 0xAA);
    try testing.expectEqual(@as(usize, 100), arena.used);

    arena.reset();
    try testing.expectEqual(@as(usize, 0), arena.used);
}

test "ShadowArena 16B 对齐" {
    var arena = ShadowArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.alloc(3);
    const m2 = try arena.alloc(1);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(m2.ptr) % 16);
}
