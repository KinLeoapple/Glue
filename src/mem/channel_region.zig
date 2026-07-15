//! 通道线性区模块。
//!
//! 为 LFE 通道数据提供 bump 分配 + reset 释放的线性区：
//! - 零元数据开销：无 free-list，无位图，无头部
//! - 零碎片：顺序分配，整块 reset
//! - SIMD 友好：64B 对齐，满足 AVX-512
//! - 按需扩容：容量不够时倍增扩容
//!
//! 生命周期与基本块一致，基本块结束时 O(1) reset。

const std = @import("std");

/// 通道数据线性区
pub const ChannelRegion = struct {
    data: ?[*]align(64) u8 = null, // 64B 对齐，满足 AVX-512
    len: usize = 0, // 已分配容量
    used: usize = 0, // 已使用字节数
    backing: std.mem.Allocator,

    /// 创建空线性区
    pub fn init(backing: std.mem.Allocator) ChannelRegion {
        return .{ .backing = backing };
    }

    /// 释放底层内存
    pub fn deinit(self: *ChannelRegion) void {
        if (self.data) |d| {
            self.backing.free(d[0..self.len]);
            self.data = null;
            self.len = 0;
            self.used = 0;
        }
    }

    /// 分配 size 字节的通道数据，16B 对齐。热路径：1 次加法 + 1 次比较。
    pub fn alloc(self: *ChannelRegion, size: usize) ![]align(16) u8 {
        const aligned = std.mem.alignForward(usize, self.used, 16);
        if (self.data != null and aligned + size <= self.len) {
            const ptr: [*]align(16) u8 = @ptrCast(@alignCast(self.data.? + aligned));
            self.used = aligned + size;
            return ptr[0..size];
        }

        // 容量不够：倍增扩容
        const new_len = @max(self.len * 2, aligned + size, 256);
        const new_data = try self.backing.alignedAlloc(u8, .@"64", new_len);
        if (self.data) |d| {
            @memcpy(new_data[0..self.used], d[0..self.used]);
            self.backing.free(d[0..self.len]);
        }
        self.data = new_data.ptr;
        self.len = new_len;
        // 递归重试
        return self.alloc(size);
    }

    /// 基本块结束：reset，O(1)
    pub fn reset(self: *ChannelRegion) void {
        self.used = 0;
    }
};

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "ChannelRegion 分配与 reset" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    const m1 = try region.alloc(100);
    @memset(m1, 0xAA);
    try testing.expectEqual(@as(usize, 100), region.used);

    _ = try region.alloc(16);
    try testing.expectEqual(@as(usize, 128), region.used);

    // reset 后 used 归零
    region.reset();
    try testing.expectEqual(@as(usize, 0), region.used);
}

test "ChannelRegion 扩容" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    const m1 = try region.alloc(200);
    @memset(m1, 0xBB);

    // 分配超过初始容量，触发扩容
    const m2 = try region.alloc(500);
    try testing.expect(m2.len == 500);
}

test "ChannelRegion 16B 对齐" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    _ = try region.alloc(7);
    const m2 = try region.alloc(1);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(m2.ptr) % 16);
}
