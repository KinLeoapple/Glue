//! `glue init` 子命令：在指定目录（或当前目录）脚手架化新项目。

const std = @import("std");
const manifest_mod = @import("manifest.zig");

const MANIFEST_NAME = manifest_mod.MANIFEST_NAME;
const DEFAULT_ENTRY = manifest_mod.DEFAULT_ENTRY;

/// 向标准错误流打印格式化错误信息
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// 执行 `glue init` 子命令：在指定目录（或当前目录）脚手架化新项目
pub fn cmdInit(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dir_prefix = if (name) |n|
        try std.fmt.allocPrint(allocator, "{s}{c}", .{ n, std.fs.path.sep })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dir_prefix);
    const proj_name = name orelse "app";
    const target_dir = name orelse "";
    switch (manifest_mod.checkDirState(io, target_dir)) {
        .is_project => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printError(io, "error: already a Glue project ({s} contains {s})\n", .{ shown, MANIFEST_NAME });
            std.process.exit(1);
        },
        .non_empty => {
            const shown = if (target_dir.len == 0) "current directory" else target_dir;
            printError(io, "error: {s} is not an empty directory\n", .{shown});
            std.process.exit(1);
        },
        .missing, .empty => {},
    }
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, MANIFEST_NAME });
    defer allocator.free(manifest_path);
    const src_dir = try std.fmt.allocPrint(allocator, "{s}src", .{dir_prefix});
    defer allocator.free(src_dir);
    cwd.createDirPath(io, src_dir) catch |err| {
        printError(io, "error: could not create directory '{s}': {s}\n", .{ src_dir, @errorName(err) });
        std.process.exit(1);
    };
    const manifest_content = try std.fmt.allocPrint(allocator,
        \\name = "{s}"
        \\version = "0.1.0"
        \\entry = "{s}"
        \\
    , .{ proj_name, DEFAULT_ENTRY });
    defer allocator.free(manifest_content);
    cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_content }) catch |err| {
        printError(io, "error: could not write '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    const main_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, DEFAULT_ENTRY });
    defer allocator.free(main_path);
    const main_content =
        \\fun main() {
        \\    println("Hello, Glue!")
        \\    0
        \\}
        \\
    ;
    cwd.writeFile(io, .{ .sub_path = main_path, .data = main_content }) catch |err| {
        printError(io, "error: could not write '{s}': {s}\n", .{ main_path, @errorName(err) });
        std.process.exit(1);
    };
    var out_buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    w.interface.print("Created Glue project '{s}'\n  {s}\n  {s}\n", .{ proj_name, manifest_path, main_path }) catch {};
    w.flush() catch {};
}
