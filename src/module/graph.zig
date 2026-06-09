//! 依赖图
//!
//! 管理模块依赖关系，检测循环依赖

const std = @import("std");

pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    loading: std.StringHashMap(void),
    loaded: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return DependencyGraph{
            .allocator = allocator,
            .loading = std.StringHashMap(void).init(allocator),
            .loaded = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        {
            var iter = self.loading.keyIterator();
            while (iter.next()) |key| self.allocator.free(key.*);
            self.loading.deinit();
        }
        {
            var iter = self.loaded.keyIterator();
            while (iter.next()) |key| self.allocator.free(key.*);
            self.loaded.deinit();
        }
    }

    /// 开始加载模块，返回是否检测到循环依赖
    pub fn beginLoad(self: *DependencyGraph, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        try self.loading.put(owned, {});
    }

    /// 完成加载模块
    pub fn endLoad(self: *DependencyGraph, name: []const u8) void {
        if (self.loading.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
        const owned = self.allocator.dupe(u8, name) catch return;
        self.loaded.put(owned, {}) catch {};
    }

    /// 检查是否正在加载（循环依赖检测）
    pub fn isLoading(self: *DependencyGraph, name: []const u8) bool {
        return self.loading.contains(name);
    }

    /// 检查是否已加载
    pub fn isLoaded(self: *DependencyGraph, name: []const u8) bool {
        return self.loaded.contains(name);
    }
};
