//! 自定义字符串类型——Str 结构体
//!
//! 用 []u8 存储 UTF-8 字节序列，由 allocator 管理生命周期。
//! 完全自实现，仅依赖 allocator 的字节拷贝与 std.unicode 的码点计数。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");

/// UTF-8 字符串（allocator 持有字节切片所有权）
pub const Str = struct {
    rc: u32 = 1, // 引用计数（供 Value 装箱）
    bytes: []u8, // UTF-8 字节
    allocator: std.mem.Allocator,

    /// 从字面量构造（拷贝字节，allocator 持有所有权）
    pub fn fromLiteral(allocator: std.mem.Allocator, s: []const u8) !Str {
        const owned = try allocator.dupe(u8, s);
        return .{ .bytes = owned, .allocator = allocator };
    }

    /// 释放底层字节
    pub fn deinit(self: *Str) void {
        self.allocator.free(self.bytes);
        self.bytes = &[_]u8{};
    }

    /// UTF-8 字节数
    pub fn byteLength(self: Str) usize {
        return self.bytes.len;
    }

    /// 码点数（解码计数）
    pub fn codepointCount(self: Str) !usize {
        return try std.unicode.utf8CountCodepoints(self.bytes);
    }

    /// 拼接：返回新 Str（self 与 other 保持不变）
    pub fn concat(self: Str, other: Str) !Str {
        const a_len = self.byteLength();
        const b_len = other.byteLength();
        const buf = try self.allocator.alloc(u8, a_len + b_len);
        @memcpy(buf[0..a_len], self.bytes);
        @memcpy(buf[a_len .. a_len + b_len], other.bytes);
        return .{ .bytes = buf, .allocator = self.allocator };
    }

    /// 字典序逐字节比较
    pub fn compare(self: Str, other: Str) std.math.Order {
        const a = self.bytes;
        const b = other.bytes;
        const min_len = if (a.len < b.len) a.len else b.len;
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            if (a[i] < b[i]) return .lt;
            if (a[i] > b[i]) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }

    /// 相等
    pub fn equals(self: Str, other: Str) bool {
        if (self.bytes.len != other.bytes.len) return false;
        var i: usize = 0;
        while (i < self.bytes.len) : (i += 1) {
            if (self.bytes[i] != other.bytes[i]) return false;
        }
        return true;
    }
};

// —— 测试 ——

test "Str.fromLiteral/deinit no leak" {
    const allocator = std.testing.allocator;
    var s = try Str.fromLiteral(allocator, "hello");
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 5), s.byteLength());
}

test "Str.byteLength/codepointCount for ASCII/CJK/emoji" {
    const allocator = std.testing.allocator;

    // ASCII
    {
        var s = try Str.fromLiteral(allocator, "hello");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 5), s.byteLength());
        try std.testing.expectEqual(@as(usize, 5), try s.codepointCount());
    }

    // 中文（每个汉字 UTF-8 占 3 字节）
    {
        var s = try Str.fromLiteral(allocator, "中文");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 6), s.byteLength());
        try std.testing.expectEqual(@as(usize, 2), try s.codepointCount());
    }

    // emoji（U+1F600 占 4 字节）
    {
        var s = try Str.fromLiteral(allocator, "😀");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 4), s.byteLength());
        try std.testing.expectEqual(@as(usize, 1), try s.codepointCount());
    }

    // 混合
    {
        var s = try Str.fromLiteral(allocator, "a中😀");
        defer s.deinit();
        // 'a' = 1, '中' = 3, '😀' = 4 → 8 字节, 3 码点
        try std.testing.expectEqual(@as(usize, 8), s.byteLength());
        try std.testing.expectEqual(@as(usize, 3), try s.codepointCount());
    }
}

test "Str.concat" {
    const allocator = std.testing.allocator;
    var a = try Str.fromLiteral(allocator, "Hello, ");
    defer a.deinit();
    var b = try Str.fromLiteral(allocator, "世界!");
    defer b.deinit();

    var c = try a.concat(b);
    defer c.deinit();

    try std.testing.expectEqualStrings("Hello, 世界!", c.bytes);
    // "Hello, " = 7 字节, "世界!" = 3+3+1 = 7 字节, 合计 14
    try std.testing.expectEqual(@as(usize, 14), c.byteLength());
    // 原 Str 不变
    try std.testing.expectEqualStrings("Hello, ", a.bytes);
    try std.testing.expectEqualStrings("世界!", b.bytes);
}

test "Str.compare and equals" {
    const allocator = std.testing.allocator;

    var a = try Str.fromLiteral(allocator, "apple");
    defer a.deinit();
    var b = try Str.fromLiteral(allocator, "banana");
    defer b.deinit();
    var a2 = try Str.fromLiteral(allocator, "apple");
    defer a2.deinit();
    var app = try Str.fromLiteral(allocator, "app");
    defer app.deinit();

    // equals
    try std.testing.expect(a.equals(a2));
    try std.testing.expect(!a.equals(b));

    // compare 相等
    try std.testing.expectEqual(std.math.Order.eq, a.compare(a2));
    // 'apple' < 'banana'
    try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
    try std.testing.expectEqual(std.math.Order.gt, b.compare(a));
    // 前缀 'app' < 'apple'（较短的字串字典序在前）
    try std.testing.expectEqual(std.math.Order.lt, app.compare(a));
    try std.testing.expectEqual(std.math.Order.gt, a.compare(app));
}

test "Str.empty string" {
    const allocator = std.testing.allocator;
    var s = try Str.fromLiteral(allocator, "");
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.byteLength());
    try std.testing.expectEqual(@as(usize, 0), try s.codepointCount());

    var other = try Str.fromLiteral(allocator, "");
    defer other.deinit();
    try std.testing.expect(s.equals(other));
    try std.testing.expectEqual(std.math.Order.eq, s.compare(other));

    // 空串与非空串拼接
    var hi = try Str.fromLiteral(allocator, "hi");
    defer hi.deinit();
    var c1 = try s.concat(hi);
    defer c1.deinit();
    try std.testing.expectEqualStrings("hi", c1.bytes);
    var c2 = try hi.concat(s);
    defer c2.deinit();
    try std.testing.expectEqualStrings("hi", c2.bytes);
}
