//! 标准库模块加载器
//!
//! 负责将内置的标准库源文件（以 @embedFile 方式在编译期嵌入二进制）按名称对外提供，
//! 供模块加载器在解析 import 语句时查找内置模块源码。

const std = @import("std");

/// 标准库条目：模块名与对应源码
const Entry = struct {
    name: []const u8,
    source: []const u8,
};

/// 内置标准库模块表，源码在编译期通过 @embedFile 嵌入二进制
const modules = [_]Entry{
    .{ .name = "List", .source = @embedFile("stdlib/List.glue") },
};

/// 按名称查找内置标准库模块源码，找不到时返回 null
pub fn lookup(name: []const u8) ?[]const u8 {
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.source;
    }
    return null;
}
