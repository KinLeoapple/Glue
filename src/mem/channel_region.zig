//! 通道线性区模块。
//!
//! 为 Glue IR 通道数据提供 bump 分配 + resetTo 释放的线性区：
//! - 零元数据开销：无 free-list，无位图，无头部
//! - 零碎片：顺序分配，按偏移 resetTo
//! - SIMD 友好：64B 对齐，满足 AVX-512
//! - 按需扩容：容量不够时倍增扩容
//!
//! 生命周期与函数调用一致，函数返回时 O(1) resetTo 回收本函数通道内存。

const std = @import("std");

/// 通道数据线性区
pub const ChannelRegion = struct {
    data: ?[*]align(64) u8 = null, // 64B 对齐，满足 AVX-512
    len: usize = 0, // 已分配容量
    used: usize = 0, // 已使用字节数
    backing: std.mem.Allocator,
    /// 扩容信息：扩容后非 null，调用方需 rebase 指针后清除
    rebase_info: ?RebaseInfo = null,

    pub const RebaseInfo = struct {
        old_base: usize, // 旧 data 基址
        old_end: usize, // 旧 data 末尾
        offset: i64, // 新基址 - 旧基址（可能为负）
    };

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

    /// 分配 size 字节的通道数据，16B 对齐（SIMD 128-bit 友好，缓存行密度优先）。
    /// 热路径：1 次加法 + 1 次比较。64B 对齐会浪费 4x 内存用于标量通道，反而降低缓存密度。
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
            // 记录扩容偏移，供调用方 rebase 指针
            const old_base = @intFromPtr(d);
            const new_base = @intFromPtr(new_data.ptr);
            self.rebase_info = .{
                .old_base = old_base,
                .old_end = old_base + self.len,
                .offset = @as(i64, @bitCast(new_base)) - @as(i64, @bitCast(old_base)),
            };
        }
        self.data = new_data.ptr;
        self.len = new_len;
        return self.alloc(size);
    }

    /// 按指定对齐分配 size 字节（用于 per-function 整块分配）
    pub fn allocAligned(self: *ChannelRegion, size: usize, alignment: usize) ![]align(16) u8 {
        const aligned = std.mem.alignForward(usize, self.used, alignment);
        if (self.data != null and aligned + size <= self.len) {
            const ptr: [*]align(16) u8 = @ptrCast(@alignCast(self.data.? + aligned));
            self.used = aligned + size;
            return ptr[0..size];
        }

        // 容量不够：倍增扩容（同 alloc 逻辑）
        const new_len = @max(self.len * 2, aligned + size, 256);
        const new_data = try self.backing.alignedAlloc(u8, .@"64", new_len);
        if (self.data) |d| {
            @memcpy(new_data[0..self.used], d[0..self.used]);
            self.backing.free(d[0..self.len]);
            const old_base = @intFromPtr(d);
            const new_base = @intFromPtr(new_data.ptr);
            self.rebase_info = .{
                .old_base = old_base,
                .old_end = old_base + self.len,
                .offset = @as(i64, @bitCast(new_base)) - @as(i64, @bitCast(old_base)),
            };
        }
        self.data = new_data.ptr;
        self.len = new_len;
        return self.allocAligned(size, alignment);
    }

    /// 回收 offset 之后的所有 bump 分配（O(1)）
    /// 用于函数返回时回收本函数的通道内存
    pub fn resetTo(self: *ChannelRegion, offset: usize) void {
        std.debug.assert(offset <= self.used);
        self.used = offset;
    }
};
