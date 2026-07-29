//! Builtin 类型嵌入注册表
//!
//! 使用 @embedFile 在编译期把所有 builtin .glue 文件内容嵌入到二进制中，
//! 供 module_loader 在加载用户模块前预加载 builtin 类型定义。
//!
//! 与 stdlib (src/std/embed.zig) 的区别：
//!   - builtin 类型对所有用户代码默认可见（不需要 import）
//!   - builtin 类型不走 mangling（短名直接注册到全局环境）
//!   - builtin .glue 中的 trait_decl/type_decl/fun_decl 走通用 sema/IR 路径

const std = @import("std");

/// 单个 builtin 文件元信息：相对路径 + 内容
pub const BuiltinFile = struct {
    /// 相对路径（相对于 src/builtin/），如 "error/pack.glue"、"error/Err.glue"
    path: []const u8,
    /// 文件内容（@embedFile 在编译期嵌入）
    content: []const u8,
};

/// 所有 builtin .glue 文件表（comptime 单一真相来源）
pub const BUILTIN_FILES = [_]BuiltinFile{
    // ── error 模块 ──
    .{ .path = "error/pack.glue", .content = @embedFile("error/pack.glue") },
    .{ .path = "error/Err.glue", .content = @embedFile("error/Err.glue") },
    .{ .path = "error/Error.glue", .content = @embedFile("error/Error.glue") },
    .{ .path = "error/CastError.glue", .content = @embedFile("error/CastError.glue") },
    .{ .path = "error/IOError.glue", .content = @embedFile("error/IOError.glue") },
    .{ .path = "error/TimeError.glue", .content = @embedFile("error/TimeError.glue") },
    // ── iter 模块 ──
    .{ .path = "iter/pack.glue", .content = @embedFile("iter/pack.glue") },
    .{ .path = "iter/Iter.glue", .content = @embedFile("iter/Iter.glue") },
    // ── io 模块 ──
    .{ .path = "io/pack.glue", .content = @embedFile("io/pack.glue") },
    .{ .path = "io/Reader.glue", .content = @embedFile("io/Reader.glue") },
    .{ .path = "io/Writer.glue", .content = @embedFile("io/Writer.glue") },
};

/// 按相对路径查找嵌入的 builtin 文件内容，未命中返回 null
pub fn find(path: []const u8) ?[]const u8 {
    inline for (BUILTIN_FILES) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.content;
    }
    return null;
}
