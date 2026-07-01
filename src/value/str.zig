//! 自定义字符串类型——Str 结构体（Small String Optimization）
//!
//! 24 字节定长，8 字节对齐。rc 的 bit 31 作为 SSO 标志：
//! - SSO 模式（bit 31 = 1）：bits 0-4 编码长度（0..20），内联数据在
//!   offset 0-19（20 字节连续），短字符串零字节堆分配。
//! - 堆模式（bit 31 = 0）：ptr 在 offset 0-7，len 在 offset 8-15，
//!   offset 16-19 未用，rc 在 offset 20-23。
//!
//! 完全自实现，仅依赖 allocator 的字节拷贝与 std.unicode 的码点计数。
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");

/// UTF-8 字符串（SSO 优化：≤20 字节内联，>20 字节堆分配）
pub const Str = extern struct {
    // 布局（24 字节，8 字节对齐）：
    //   offset 0-7:   SSO data[0..8]  /  heap ptr
    //   offset 8-15:  SSO data[8..16] /  heap len
    //   offset 16-19: SSO data[16..20] / heap unused
    //   offset 20-23: rc（bit 31 = SSO flag, bits 0-4 = SSO length 0..20）
    _word0: u64 = 0,
    _word1: u64 = 0,
    _word2: u32 = 0,
    rc: u32 = SSO_FLAG, // 默认 SSO 模式，长度 0

    const SSO_FLAG: u32 = 0x80000000;
    const SSO_LEN_MASK: u32 = 0x1F; // bits 0-4, max 20
    /// SSO 最大字节数
    pub const SSO_MAX: usize = 20;

    pub inline fn isSso(self: *const Str) bool {
        return (self.rc & SSO_FLAG) != 0;
    }

    fn ssoLen(self: *const Str) usize {
        return self.rc & SSO_LEN_MASK;
    }

    /// 从字面量构造（≤20 字节走 SSO 零字节堆分配，>20 字节走堆分配）
    /// allocator 持有堆字节所有权（SSO 模式下不使用 allocator）
    pub fn fromLiteral(allocator: std.mem.Allocator, s: []const u8) !Str {
        if (s.len <= SSO_MAX) {
            return initSso(s);
        }
        const owned = try allocator.dupe(u8, s);
        return initHeap(owned.ptr, owned.len);
    }

    /// 从已拥有的字节缓冲构造（≤20 字节走 SSO 并释放 buf，>20 字节接管 buf 所有权）
    pub fn fromOwnedBytes(allocator: std.mem.Allocator, buf: []u8) Str {
        if (buf.len <= SSO_MAX) {
            const result = initSso(buf);
            allocator.free(buf);
            return result;
        }
        return initHeap(buf.ptr, buf.len);
    }

    fn initSso(s: []const u8) Str {
        var result = Str{ .rc = SSO_FLAG | @as(u32, @intCast(s.len)) };
        const dst: [*]u8 = @ptrCast(&result);
        @memcpy(dst[0..s.len], s);
        return result;
    }

    fn initHeap(ptr: [*]u8, len: usize) Str {
        return .{
            ._word0 = @intFromPtr(ptr),
            ._word1 = len,
            ._word2 = 0,
            .rc = 1, // 堆模式，rc = 1，bit 31 = 0
        };
    }

    /// 释放底层字节（仅堆模式需要 free；SSO 模式无操作）
    pub fn deinit(self: *Str, allocator: std.mem.Allocator) void {
        if (!self.isSso()) {
            const ptr: [*]u8 = @ptrFromInt(self._word0);
            allocator.free(ptr[0..self._word1]);
            self._word0 = 0;
            self._word1 = 0;
        }
    }

    /// 返回字节切片（只读）。SSO 模式返回内联数据，堆模式返回堆切片。
    pub inline fn bytes(self: *const Str) []const u8 {
        if (self.isSso()) {
            const len = self.ssoLen();
            const ptr: [*]const u8 = @ptrCast(self);
            return ptr[0..len];
        }
        const ptr: [*]const u8 = @ptrFromInt(self._word0);
        return ptr[0..self._word1];
    }

    /// UTF-8 字节数
    pub inline fn byteLength(self: Str) usize {
        if (self.isSso()) {
            return self.ssoLen();
        }
        return self._word1;
    }

    /// 码点数（解码计数）
    pub fn codepointCount(self: Str) !usize {
        return try std.unicode.utf8CountCodepoints(self.bytes());
    }

    /// 拼接：返回新 Str（self 与 other 保持不变；allocator 显式传入）
    pub fn concat(self: Str, allocator: std.mem.Allocator, other: Str) !Str {
        const a_len = self.byteLength();
        const b_len = other.byteLength();
        const total = a_len + b_len;
        if (total <= SSO_MAX) {
            var result = Str{ .rc = SSO_FLAG | @as(u32, @intCast(total)) };
            const dst: [*]u8 = @ptrCast(&result);
            @memcpy(dst[0..a_len], self.bytes());
            @memcpy(dst[a_len..total], other.bytes());
            return result;
        }
        const buf = try allocator.alloc(u8, total);
        @memcpy(buf[0..a_len], self.bytes());
        @memcpy(buf[a_len..total], other.bytes());
        return initHeap(buf.ptr, total);
    }

    /// 字典序逐字节比较（ReleaseFast 下 std.mem.order 走 SIMD 加速）
    pub fn compare(self: Str, other: Str) std.math.Order {
        return std.mem.order(u8, self.bytes(), other.bytes());
    }

    /// 相等（ReleaseFast 下 std.mem.eql 走 SIMD 加速）
    pub fn equals(self: Str, other: Str) bool {
        return std.mem.eql(u8, self.bytes(), other.bytes());
    }
};

// —— 测试 ——

test "Str.fromLiteral/deinit no leak" {
    const allocator = std.testing.allocator;
    var s = try Str.fromLiteral(allocator, "hello");
    defer s.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), s.byteLength());
}

test "Str.byteLength/codepointCount for ASCII/CJK/emoji" {
    const allocator = std.testing.allocator;

    // ASCII
    {
        var s = try Str.fromLiteral(allocator, "hello");
        defer s.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 5), s.byteLength());
        try std.testing.expectEqual(@as(usize, 5), try s.codepointCount());
    }

    // 中文（每个汉字 UTF-8 占 3 字节）
    {
        var s = try Str.fromLiteral(allocator, "中文");
        defer s.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 6), s.byteLength());
        try std.testing.expectEqual(@as(usize, 2), try s.codepointCount());
    }

    // emoji（U+1F600 占 4 字节）
    {
        var s = try Str.fromLiteral(allocator, "😀");
        defer s.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), s.byteLength());
        try std.testing.expectEqual(@as(usize, 1), try s.codepointCount());
    }

    // 混合
    {
        var s = try Str.fromLiteral(allocator, "a中😀");
        defer s.deinit(allocator);
        // 'a' = 1, '中' = 3, '😀' = 4 → 8 字节, 3 码点
        try std.testing.expectEqual(@as(usize, 8), s.byteLength());
        try std.testing.expectEqual(@as(usize, 3), try s.codepointCount());
    }
}

test "Str.concat" {
    const allocator = std.testing.allocator;
    var a = try Str.fromLiteral(allocator, "Hello, ");
    defer a.deinit(allocator);
    var b = try Str.fromLiteral(allocator, "世界!");
    defer b.deinit(allocator);

    var c = try a.concat(allocator, b);
    defer c.deinit(allocator);

    try std.testing.expectEqualStrings("Hello, 世界!", c.bytes());
    // "Hello, " = 7 字节, "世界!" = 3+3+1 = 7 字节, 合计 14
    try std.testing.expectEqual(@as(usize, 14), c.byteLength());
    // 原 Str 不变
    try std.testing.expectEqualStrings("Hello, ", a.bytes());
    try std.testing.expectEqualStrings("世界!", b.bytes());
}

test "Str.compare and equals" {
    const allocator = std.testing.allocator;

    var a = try Str.fromLiteral(allocator, "apple");
    defer a.deinit(allocator);
    var b = try Str.fromLiteral(allocator, "banana");
    defer b.deinit(allocator);
    var a2 = try Str.fromLiteral(allocator, "apple");
    defer a2.deinit(allocator);
    var app = try Str.fromLiteral(allocator, "app");
    defer app.deinit(allocator);

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
    defer s.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), s.byteLength());
    try std.testing.expectEqual(@as(usize, 0), try s.codepointCount());

    var other = try Str.fromLiteral(allocator, "");
    defer other.deinit(allocator);
    try std.testing.expect(s.equals(other));
    try std.testing.expectEqual(std.math.Order.eq, s.compare(other));

    // 空串与非空串拼接
    var hi = try Str.fromLiteral(allocator, "hi");
    defer hi.deinit(allocator);
    var c1 = try s.concat(allocator, hi);
    defer c1.deinit(allocator);
    try std.testing.expectEqualStrings("hi", c1.bytes());
    var c2 = try hi.concat(allocator, s);
    defer c2.deinit(allocator);
    try std.testing.expectEqualStrings("hi", c2.bytes());
}

test "Str.SSO boundary (≤20 inline, >20 heap)" {
    const allocator = std.testing.allocator;

    // 恰好 20 字节 → SSO
    {
        const lit = "0123456789ABCDEFGHIJ"; // 20 字节
        try std.testing.expectEqual(@as(usize, 20), lit.len);
        var s = try Str.fromLiteral(allocator, lit);
        defer s.deinit(allocator);
        try std.testing.expect(s.isSso());
        try std.testing.expectEqualStrings(lit, s.bytes());
    }

    // 21 字节 → 堆
    {
        const lit = "0123456789ABCDEFGHIJK"; // 21 字节
        try std.testing.expectEqual(@as(usize, 21), lit.len);
        var s = try Str.fromLiteral(allocator, lit);
        defer s.deinit(allocator);
        try std.testing.expect(!s.isSso());
        try std.testing.expectEqualStrings(lit, s.bytes());
    }
}

test "Str.fromOwnedBytes SSO vs heap" {
    const allocator = std.testing.allocator;

    // 短 buf → SSO，buf 被 free
    {
        const buf = try allocator.alloc(u8, 5);
        @memcpy(buf, "hello");
        var s = Str.fromOwnedBytes(allocator, buf);
        defer s.deinit(allocator);
        try std.testing.expect(s.isSso());
        try std.testing.expectEqualStrings("hello", s.bytes());
    }

    // 长 buf → 堆，buf 所有权被接管
    {
        const buf = try allocator.alloc(u8, 25);
        @memset(buf, 'x');
        var s = Str.fromOwnedBytes(allocator, buf);
        defer s.deinit(allocator);
        try std.testing.expect(!s.isSso());
        try std.testing.expectEqual(@as(usize, 25), s.byteLength());
    }
}

test "Str concat produces SSO when result ≤20" {
    const allocator = std.testing.allocator;

    // "abc" + "def" = 6 字节 → SSO
    {
        var a = try Str.fromLiteral(allocator, "abc");
        defer a.deinit(allocator);
        var b = try Str.fromLiteral(allocator, "def");
        defer b.deinit(allocator);
        var c = try a.concat(allocator, b);
        defer c.deinit(allocator);
        try std.testing.expect(c.isSso());
        try std.testing.expectEqualStrings("abcdef", c.bytes());
    }

    // 10 + 11 = 21 字节 → 堆
    {
        var a = try Str.fromLiteral(allocator, "0123456789");
        defer a.deinit(allocator);
        var b = try Str.fromLiteral(allocator, "ABCDEFGHIJK");
        defer b.deinit(allocator);
        var c = try a.concat(allocator, b);
        defer c.deinit(allocator);
        try std.testing.expect(!c.isSso());
        try std.testing.expectEqualStrings("0123456789ABCDEFGHIJK", c.bytes());
    }
}
