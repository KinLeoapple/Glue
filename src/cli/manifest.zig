//! 项目清单与项目根定位。
//!
//! 提供清单（glue.toml）解析、项目根向上查找、目标目录状态检测，
//! 供 `glue init`/`glue run`/`glue debug` 子命令共用。

const std = @import("std");

/// 项目清单：名称、版本与入口文件路径
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    entry: []const u8,
};

pub const MANIFEST_NAME = "glue.toml";
pub const DEFAULT_ENTRY = "src/Main.glue";

/// 从当前目录向上逐级查找包含清单文件的目录，返回其相对前缀
pub fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var level: usize = 0;
    while (level < 64) : (level += 1) {
        const candidate = if (prefix.items.len == 0)
            try allocator.dupe(u8, MANIFEST_NAME)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix.items, MANIFEST_NAME });
        defer allocator.free(candidate);
        if (cwd.access(io, candidate, .{})) {
            return try allocator.dupe(u8, prefix.items);
        } else |_| {}
        try prefix.appendSlice(allocator, ".." ++ [_]u8{std.fs.path.sep});
    }
    return null;
}

/// 解析清单文件内容（简化的 key = value 格式），返回 Manifest
pub fn parseManifest(source: []const u8) Manifest {
    var name: []const u8 = "app";
    var version: []const u8 = "0.0.0";
    var entry: []const u8 = DEFAULT_ENTRY;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "entry")) {
            if (val.len > 0) entry = val;
        }
    }
    return .{ .name = name, .version = version, .entry = entry };
}

/// 目标目录状态：不存在、空、非空、已是项目
pub const DirState = enum {
    missing,
    empty,
    non_empty,
    is_project,
};

/// 检查目标目录的状态
pub fn checkDirState(io: std.Io, path: []const u8) DirState {
    const cwd = std.Io.Dir.cwd();
    const open_path = if (path.len == 0) "." else path;
    var dir = cwd.openDir(io, open_path, .{ .iterate = true }) catch {
        return .missing;
    };
    defer dir.close(io);
    var it = dir.iterate();
    var empty = true;
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, MANIFEST_NAME)) return .is_project;
        empty = false;
    }
    return if (empty) .empty else .non_empty;
}
