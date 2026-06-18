//! 内嵌标准库
//!
//! 文档 D67：List 等集合属于 std 库，用 Glue 自身实现。这里用 @embedFile 把
//! src/stdlib/*.glue 源码编进解释器二进制，`use <Name>` 加载模块时若项目内找不到
//! 同名文件，则回退到这张内嵌表（零安装、与 cwd 无关）。
//!
//! 新增标准库模块：在 src/stdlib/ 下加 <Name>.glue，并在 modules 表里登记一行。

const std = @import("std");

const Entry = struct {
    name: []const u8,
    source: []const u8,
};

/// 内嵌模块表。name 是 `use <name>` 的单段模块名，source 是其 .glue 源码。
const modules = [_]Entry{
    .{ .name = "List", .source = @embedFile("stdlib/List.glue") },
    .{ .name = "Compare", .source = @embedFile("stdlib/Compare.glue") },
};

/// 按模块名查内嵌源码；未命中返回 null（调用方据此回退/报错）。
pub fn lookup(name: []const u8) ?[]const u8 {
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.source;
    }
    return null;
}

test "lookup hits embedded module" {
    try std.testing.expect(lookup("List") != null);
    try std.testing.expect(lookup("Compare") != null);
    try std.testing.expect(lookup("DoesNotExist") == null);
}
