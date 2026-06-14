//! 模块解析
//!
//! 负责将模块路径解析为文件路径，加载模块源代码
//! 支持两种模块形式：
//! - 文件模块：foo/bar.glue
//! - 目录模块：foo/bar/pack.glue

const std = @import("std");

pub const ModuleResolver = struct {
    allocator: std.mem.Allocator,
    source_dir: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) ModuleResolver {
        return ModuleResolver{ .allocator = allocator, .source_dir = null };
    }

    pub fn deinit(self: *ModuleResolver) void {
        if (self.source_dir) |dir| {
            self.allocator.free(dir);
        }
    }

    pub fn setSourceDir(self: *ModuleResolver, dir: []const u8) !void {
        if (self.source_dir) |d| self.allocator.free(d);
        self.source_dir = try self.allocator.dupe(u8, dir);
    }

    /// 解析模块路径为文件路径
    /// 尝试顺序：
    /// 1. base_dir/path/to/module.glue（文件模块）
    /// 2. base_dir/path/to/module/pack.glue（目录模块）
    /// 返回找到的文件路径，或 null 表示未找到
    pub fn resolvePath(self: *ModuleResolver, io: std.Io, module_path: []const []const u8) !?[]const u8 {
        const allocator = self.allocator;
        const base_dir = self.source_dir orelse ".";

        // 拼接基础路径
        var file_path = std.ArrayList(u8).empty;
        defer file_path.deinit(allocator);
        try file_path.appendSlice(allocator, base_dir);
        for (module_path) |component| {
            try file_path.append(allocator, std.fs.path.sep);
            try file_path.appendSlice(allocator, component);
        }

        // 尝试 .glue 文件
        const path_with_ext = try std.fmt.allocPrint(allocator, "{s}.glue", .{file_path.items});
        defer allocator.free(path_with_ext);

        const cwd = std.Io.Dir.cwd();
        if (cwd.access(io, path_with_ext, .{})) {
            return try allocator.dupe(u8, path_with_ext);
        } else |_| {
            // 尝试 pack.glue（目录模块）
            const pack_path = try std.fmt.allocPrint(allocator, "{s}" ++ [_]u8{std.fs.path.sep} ++ "pack.glue", .{file_path.items});
            defer allocator.free(pack_path);

            if (cwd.access(io, pack_path, .{})) {
                return try allocator.dupe(u8, pack_path);
            } else |_| {
                return null;
            }
        }
    }

    /// 加载模块源代码
    pub fn loadSource(self: *ModuleResolver, io: std.Io, path: []const u8) ![]const u8 {
        const allocator = self.allocator;
        const cwd = std.Io.Dir.cwd();
        return cwd.readFileAlloc(io, path, allocator, .unlimited);
    }
};
