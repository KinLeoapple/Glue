//! stdlib 嵌入注册表
//!
//! 使用 @embedFile 在编译期把所有 stdlib .glue 文件内容嵌入到二进制中，
//! 使用户代码可以通过 `import std.io.Fs` 等路径加载标准库（设计文档 §2.3）。
//!
//! 查找规则（module_loader 的 loadStdlibPack 中）：
//!   - import std.io.Fs  → 读 "io/pack.glue" 与 "io/<X>.glue"（X 遍历 pack 中的 pub pack）
//!   - import std.time.Timer → 读 "time/pack.glue" 与 "time/<X>.glue"
//!
//! 嵌入路径相对本文件所在目录（src/std/），与 stdlib 源码目录结构一一对应。
//!
//! 新增 stdlib 文件时只需在此表追加条目，无需修改其他位置。

const std = @import("std");

/// 单个 stdlib 文件元信息：相对路径 + 内容
pub const StdlibFile = struct {
    /// 相对路径（无前导 std/），如 "io/pack.glue"、"io/Fs.glue"
    path: []const u8,
    /// 文件内容（@embedFile 在编译期嵌入）
    content: []const u8,
};

/// 所有 stdlib .glue 文件表（comptime 单一真相来源）
pub const STDLIB_FILES = [_]StdlibFile{
    // ── IO 模块 ──
    .{ .path = "io/pack.glue", .content = @embedFile("io/pack.glue") },
    .{ .path = "io/File.glue", .content = @embedFile("io/File.glue") },
    .{ .path = "io/Path.glue", .content = @embedFile("io/Path.glue") },
    .{ .path = "io/Buffered.glue", .content = @embedFile("io/Buffered.glue") },
    .{ .path = "io/Dir.glue", .content = @embedFile("io/Dir.glue") },
    .{ .path = "io/Fs.glue", .content = @embedFile("io/Fs.glue") },
    // ── Time 模块 ──
    .{ .path = "time/pack.glue", .content = @embedFile("time/pack.glue") },
    .{ .path = "time/Duration.glue", .content = @embedFile("time/Duration.glue") },
    .{ .path = "time/Instant.glue", .content = @embedFile("time/Instant.glue") },
    .{ .path = "time/SystemTime.glue", .content = @embedFile("time/SystemTime.glue") },
    .{ .path = "time/DateTime.glue", .content = @embedFile("time/DateTime.glue") },
    .{ .path = "time/Calendar.glue", .content = @embedFile("time/Calendar.glue") },
    .{ .path = "time/Timer.glue", .content = @embedFile("time/Timer.glue") },
    // ── Net 模块 ──
    .{ .path = "net/pack.glue", .content = @embedFile("net/pack.glue") },
    .{ .path = "net/Addr.glue", .content = @embedFile("net/Addr.glue") },
    .{ .path = "net/TcpListener.glue", .content = @embedFile("net/TcpListener.glue") },
    .{ .path = "net/TcpStream.glue", .content = @embedFile("net/TcpStream.glue") },
    .{ .path = "net/UdpSocket.glue", .content = @embedFile("net/UdpSocket.glue") },
    .{ .path = "net/Dns.glue", .content = @embedFile("net/Dns.glue") },
};

/// 按相对路径查找嵌入的 stdlib 文件内容，未命中返回 null
pub fn find(path: []const u8) ?[]const u8 {
    inline for (STDLIB_FILES) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.content;
    }
    return null;
}

// ── 测试 ──

const testing = std.testing;

test "STDLIB_FILES 包含 19 个文件" {
    try testing.expectEqual(@as(usize, 19), STDLIB_FILES.len);
}

test "find 命中 io/pack.glue" {
    const content = find("io/pack.glue") orelse return error.TestUnexpectedResult;
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "pub pack") != null);
}

test "find 命中 time/Timer.glue" {
    const content = find("time/Timer.glue") orelse return error.TestUnexpectedResult;
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "async fun") != null);
}

test "find 未命中" {
    try testing.expect(find("nonexistent/Foo.glue") == null);
    try testing.expect(find("") == null);
}

test "IO 与 Time 模块文件齐全" {
    const io_files = [_][]const u8{
        "io/pack.glue", "io/File.glue", "io/Path.glue",
        "io/Buffered.glue", "io/Dir.glue", "io/Fs.glue",
    };
    const time_files = [_][]const u8{
        "time/pack.glue", "time/Duration.glue", "time/Instant.glue",
        "time/SystemTime.glue", "time/DateTime.glue", "time/Calendar.glue",
        "time/Timer.glue",
    };
    const net_files = [_][]const u8{
        "net/pack.glue", "net/Addr.glue", "net/TcpListener.glue",
        "net/TcpStream.glue", "net/UdpSocket.glue", "net/Dns.glue",
    };
    inline for (io_files) |p| {
        try testing.expect(find(p) != null);
    }
    inline for (time_files) |p| {
        try testing.expect(find(p) != null);
    }
    inline for (net_files) |p| {
        try testing.expect(find(p) != null);
    }
}
