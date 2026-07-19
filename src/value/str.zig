//! 字符串值类型模块
//!
//! 定义 Glue 语言的字符串类型 Str，采用 SSO（Small String Optimization）
//! 策略：长度不超过 SSO_MAX（20 字节）的字符串内联存储在结构体中，
//! 超出时在堆上分配。SSO 模式使用 sso_flags 中的引用计数位实现共享，
//! 堆模式使用 ObjHeader.rc 引用计数。
//!
//! 堆模式两种缓冲区策略：
//! - 连续缓冲区（HEAP_CONTIGUOUS_FLAG 置位）：[Str header | byte buffer] 单次分配
//!   生产路径（createContiguous/concatContiguous）使用，deinit 为 no-op，freeObj 统一释放
//! - 独立缓冲区（HEAP_CONTIGUOUS_FLAG 清零）：Str header 与 buffer 分离
//!   临时/栈用路径（fromLiteral 返回 by-value Str）使用，deinit 释放 buffer
//!
//! 通过 ObjHeader 统一对象头参与统一的对象生命周期管理：
//! - header.type_tag 标识类型为 .str
//! - 堆模式下 header.rc 作为引用计数
//! - SSO 模式下 sso_flags 同时承载标志位、长度和引用计数

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
const mem_mod = @import("mem");

/// 字符串值，extern struct 保证内存布局确定
///
/// 布局（32 字节）：
/// - header: 8B，ObjHeader（type_tag + rc）
/// - _word0: 8B，SSO 内联数据 / 堆模式缓冲区指针
/// - _word1: 8B，SSO 内联数据 / 堆模式字节长度
/// - _word2: 4B，SSO 内联数据 / 堆模式分配容量（bit31=连续标志）
/// - sso_flags: 4B，SSO 标志位 + 长度 + 引用计数
pub const Str = extern struct {
    header: ObjHeader = .{ .type_tag = .str },
    _word0: u64 = 0,
    _word1: u64 = 0,
    _word2: u32 = 0,
    sso_flags: u32 = SSO_FLAG | SSO_REFCOUNT_INIT,

    // SSO 标志位：sso_flags 最高位为 1 表示 SSO 模式
    const SSO_FLAG: u32 = 0x80000000;
    // SSO 长度掩码：低 5 位存储内联字符串长度
    const SSO_LEN_MASK: u32 = 0x1F;
    // SSO 引用计数的位移量
    const SSO_REFCOUNT_SHIFT: u5 = 5;
    // SSO 引用计数掩码
    const SSO_REFCOUNT_MASK: u32 = 0x7FFFFFE0;
    // SSO 引用计数初始值
    const SSO_REFCOUNT_INIT: u32 = 1 << SSO_REFCOUNT_SHIFT;

    /// 堆模式连续缓冲区标志：_word2 bit31 置位表示 buffer 与 Str header 连续分配
    /// 置位时 deinit 为 no-op（buffer 随 freeObj 统一释放）
    /// 清零时 deinit 需 freeObj 释放独立 buffer
    const HEAP_CONTIGUOUS_FLAG: u32 = 0x80000000;

    /// SSO 模式下内联存储的最大字节数
    pub const SSO_MAX: usize = 20;

    /// 判断当前是否为 SSO 模式
    pub inline fn isSso(self: *const Str) bool {
        return (self.sso_flags & SSO_FLAG) != 0;
    }

    /// 判断堆模式下缓冲区是否为连续分配（与 Str header 在同一分配中）
    pub inline fn isContiguous(self: *const Str) bool {
        return !self.isSso() and (self._word2 & HEAP_CONTIGUOUS_FLAG) != 0;
    }

    // 获取 SSO 模式下的内联字符串长度
    fn ssoLen(self: *const Str) usize {
        return self.sso_flags & SSO_LEN_MASK;
    }

    /// SSO 模式下增加引用计数
    pub inline fn ssoRetain(self: *Str) void {
        const count = (self.sso_flags & SSO_REFCOUNT_MASK) >> SSO_REFCOUNT_SHIFT;
        if (count == 0x3FFFFFF) @panic("Str.ssoRetain: SSO refcount overflow (26-bit limit)");
        self.sso_flags = (self.sso_flags & ~SSO_REFCOUNT_MASK) | ((count + 1) << SSO_REFCOUNT_SHIFT);
    }

    /// SSO 模式下减少引用计数，返回 true 表示引用计数已降为零
    pub inline fn ssoRelease(self: *Str) bool {
        const count = (self.sso_flags & SSO_REFCOUNT_MASK) >> SSO_REFCOUNT_SHIFT;
        if (count <= 1) return true;
        self.sso_flags = (self.sso_flags & ~SSO_REFCOUNT_MASK) | ((count - 1) << SSO_REFCOUNT_SHIFT);
        return false;
    }

    /// 堆模式下增加引用计数
    pub inline fn heapRetain(self: *Str) void {
        self.header.rc += 1;
    }

    /// 堆模式下减少引用计数，返回 true 表示引用计数已降为零
    pub inline fn heapRelease(self: *Str) bool {
        self.header.rc -= 1;
        return self.header.rc == 0;
    }

    // ── 栈/临时用 by-value 构造（独立缓冲区） ──

    /// 从字面量构造字符串（by-value），短字符串走 SSO，长字符串分配独立缓冲区
    /// 返回的 Str 若为堆模式，buffer 为独立分配，deinit 时需释放
    pub fn fromLiteral(tctx: *ThreadContext, s: []const u8) !Str {
        if (s.len <= SSO_MAX) {
            return initSso(s);
        }
        const buf = try tctx.allocObj(s.len);
        @memcpy(buf[0..s.len], s);
        return initHeap(buf.ptr, s.len, s.len);
    }

    /// 从已拥有的字节切片构造字符串（by-value），短字符串走 SSO 并释放原缓冲区
    /// 长字符串直接接管 buf 指针（独立缓冲区，deinit 时释放）
    pub fn fromOwnedBytes(tctx: *ThreadContext, buf: []u8) Str {
        if (buf.len <= SSO_MAX) {
            const result = initSso(buf);
            tctx.freeObj(buf.ptr);
            return result;
        }
        return initHeap(buf.ptr, buf.len, buf.len);
    }

    // ── 堆分配连续构造（生产路径，单次分配） ──

    /// 创建堆分配的 Str（连续内存：header + buffer）
    /// SSO 模式：Str 堆分配但数据内联
    /// 堆模式：[Str header | byte buffer] 单次分配，deinit 为 no-op
    pub fn createContiguous(tctx: *ThreadContext, data: []const u8) !*Str {
        if (data.len <= SSO_MAX) {
            const self = try tctx.createObj(Str);
            self.* = initSso(data);
            return self;
        }
        const total = @sizeOf(Str) + data.len;
        const mem = try tctx.allocObj(total);
        const self: *Str = @ptrCast(@alignCast(mem.ptr));
        const buf_ptr: [*]u8 = mem.ptr + @sizeOf(Str);
        @memcpy(buf_ptr[0..data.len], data);
        self.* = initHeapContiguous(buf_ptr, data.len, data.len);
        return self;
    }

    /// 拼接两个字符串，返回堆分配的连续 Str（生产路径）
    /// SSO 结果：Str 堆分配但数据内联
    /// 堆结果：[Str header | byte buffer (2x 过分配)] 单次分配
    pub fn concatContiguous(tctx: *ThreadContext, a: Str, b: Str) !*Str {
        const a_len = a.byteLength();
        const b_len = b.byteLength();
        const total = a_len + b_len;
        if (total <= SSO_MAX) {
            const self = try tctx.createObj(Str);
            self.* = Str{ .sso_flags = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(total)) };
            const dst: [*]u8 = @ptrCast(&self._word0);
            @memcpy(dst[0..a_len], a.bytes());
            @memcpy(dst[a_len..total], b.bytes());
            return self;
        }
        const new_cap = @max(total * 2, total + 16);
        const alloc_size = @sizeOf(Str) + new_cap;
        const mem = try tctx.allocObj(alloc_size);
        const self: *Str = @ptrCast(@alignCast(mem.ptr));
        const buf_ptr: [*]u8 = mem.ptr + @sizeOf(Str);
        @memcpy(buf_ptr[0..a_len], a.bytes());
        @memcpy(buf_ptr[a_len..total], b.bytes());
        self.* = initHeapContiguous(buf_ptr, total, new_cap);
        return self;
    }

    // 初始化 SSO 模式：将字符串内联拷贝到结构体内
    fn initSso(s: []const u8) Str {
        var result = Str{ .sso_flags = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(s.len)) };
        const dst: [*]u8 = @ptrCast(&result._word0);
        @memcpy(dst[0..s.len], s);
        return result;
    }

    /// 将两个字节切片拼接为 SSO 字符串（调用方需确保总长度不超过 SSO_MAX）
    pub fn concatSso(a: []const u8, b: []const u8) Str {
        const total = a.len + b.len;
        var result = Str{ .sso_flags = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(total)) };
        const dst: [*]u8 = @ptrCast(&result._word0);
        @memcpy(dst[0..a.len], a);
        @memcpy(dst[a.len..total], b);
        return result;
    }

    /// 判断两个长度拼接后是否可走 SSO
    pub inline fn canConcatSso(a_len: usize, b_len: usize) bool {
        return a_len + b_len <= SSO_MAX;
    }

    // 初始化堆模式（独立缓冲区）：存储指针、长度、容量，引用计数设为 1
    // HEAP_CONTIGUOUS_FLAG 清零，deinit 时释放独立 buffer
    fn initHeap(ptr: [*]u8, len: usize, cap: usize) Str {
        return .{
            ._word0 = @intFromPtr(ptr),
            ._word1 = len,
            ._word2 = @intCast(cap),
            .sso_flags = 0,
        };
    }

    // 初始化堆模式（连续缓冲区）：buffer 紧跟 Str header 之后
    // HEAP_CONTIGUOUS_FLAG 置位，deinit 为 no-op（buffer 随 freeObj 统一释放）
    fn initHeapContiguous(ptr: [*]u8, len: usize, cap: usize) Str {
        return .{
            ._word0 = @intFromPtr(ptr),
            ._word1 = len,
            ._word2 = @as(u32, @intCast(cap)) | HEAP_CONTIGUOUS_FLAG,
            .sso_flags = 0,
        };
    }

    /// 释放堆模式下的独立缓冲区，SSO/连续模式为空操作
    /// 注意：仅释放独立 buffer，不释放 Str 本体（Str 由 freeObj/栈管理释放）
    /// arena 分配的对象：独立 buffer 也从 arena 分配，跳过 freeObj（arena.reset 统一回收）
    pub fn deinit(self: *Str, tctx: *ThreadContext) void {
        if (!self.isSso() and (self._word2 & HEAP_CONTIGUOUS_FLAG) == 0) {
            if (!self.header.isArenaAllocated()) {
                const ptr: [*]u8 = @ptrFromInt(@as(usize, @truncate(self._word0)));
                tctx.freeObj(ptr);
            }
            self._word0 = 0;
            self._word1 = 0;
            self._word2 = 0;
        }
    }

    /// 返回字符串的字节切片
    pub inline fn bytes(self: *const Str) []const u8 {
        if (self.isSso()) {
            const len = self.ssoLen();
            const ptr: [*]const u8 = @ptrCast(&self._word0);
            return ptr[0..len];
        }
        const ptr: [*]const u8 = @ptrFromInt(@as(usize, @truncate(self._word0)));
        return ptr[0..@as(usize, @truncate(self._word1))];
    }

    /// 返回字符串字节长度
    pub inline fn byteLength(self: Str) usize {
        if (self.isSso()) {
            return self.ssoLen();
        }
        return @as(usize, @truncate(self._word1));
    }

    /// 返回 Unicode 码点数量
    pub fn codepointCount(self: Str) !usize {
        return try std.unicode.utf8CountCodepoints(self.bytes());
    }

    /// 就地追加：当 self 为堆模式、rc==1（无容器引用）、结果仍需堆模式且非自拼接时，
    /// 容量足够则仅拷贝 other（零 alloc），容量不足时：
    /// - 独立缓冲区：分配新 buffer、拷贝、释放旧 buffer
    /// - 连续缓冲区：无法单独释放 buffer，返回 false（调用方应回退到 concatContiguous）
    /// 返回 true 表示就地追加成功（self 已被修改），false 表示调用方应回退到 concat。
    pub fn concatInPlace(self: *Str, tctx: *ThreadContext, other: *const Str) bool {
        if (self.isSso()) return false;
        if (self.header.rc != 1) return false;
        if (self == other) return false;
        const a_len = self.byteLength();
        const b_len = other.byteLength();
        const total = a_len + b_len;
        if (total <= SSO_MAX) return false;

        const word2 = self._word2;
        const is_contiguous = (word2 & HEAP_CONTIGUOUS_FLAG) != 0;
        const cap: usize = @as(usize, @truncate(word2 & ~HEAP_CONTIGUOUS_FLAG));

        // 容量足够：仅追加 right，零 alloc、零全量拷贝（两种模式通用）
        if (total <= cap) {
            const ptr: [*]u8 = @ptrFromInt(@as(usize, @truncate(self._word0)));
            @memcpy(ptr[a_len..total], other.bytes());
            self._word1 = total;
            return true;
        }

        // 容量不足：连续缓冲区无法单独释放 buffer，返回 false
        if (is_contiguous) return false;

        // 独立缓冲区：分配新 buffer、拷贝、释放旧 buffer
        const new_cap = @max(total * 2, total + 16);
        const new_buf = tctx.allocObj(new_cap) catch return false;
        @memcpy(new_buf[0..a_len], self.bytes());
        @memcpy(new_buf[a_len..total], other.bytes());
        const old_ptr: [*]u8 = @ptrFromInt(@as(usize, @truncate(self._word0)));
        tctx.freeObj(old_ptr);
        self._word0 = @intFromPtr(new_buf.ptr);
        self._word1 = total;
        self._word2 = @intCast(new_cap);
        return true;
    }

    /// 拼接两个字符串（by-value 返回，独立缓冲区）
    /// 结果短则 SSO，长则堆分配（2x 过分配以支持后续就地追加）
    /// 注意：返回的 Str 若为堆模式，buffer 为独立分配，deinit 时需释放
    pub fn concat(self: Str, tctx: *ThreadContext, other: Str) !Str {
        const a_len = self.byteLength();
        const b_len = other.byteLength();
        const total = a_len + b_len;
        if (total <= SSO_MAX) {
            var result = Str{ .sso_flags = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(total)) };
            const dst: [*]u8 = @ptrCast(&result._word0);
            @memcpy(dst[0..a_len], self.bytes());
            @memcpy(dst[a_len..total], other.bytes());
            return result;
        }
        const new_cap = @max(total * 2, total + 16);
        const buf = try tctx.allocObj(new_cap);
        @memcpy(buf[0..a_len], self.bytes());
        @memcpy(buf[a_len..total], other.bytes());
        return initHeap(buf.ptr, total, new_cap);
    }

    /// 按字典序比较
    pub fn compare(self: Str, other: Str) std.math.Order {
        return std.mem.order(u8, self.bytes(), other.bytes());
    }

    /// 判断两字符串内容是否相等
    pub fn equals(self: Str, other: Str) bool {
        return std.mem.eql(u8, self.bytes(), other.bytes());
    }
};

/// ObjHeader 分派表用的 Str 析构函数
///
/// 通过 @fieldParentPtr 从 ObjHeader 指针还原为 *Str，
/// 释放内部独立缓冲区（若有）后释放对象本体。
/// arena 分配的对象：本体由 arena.reset 统一回收，跳过 freeObj。
pub fn strDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *Str = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

fn testCtx() struct { g: mem_mod.GlobalPool, c: ThreadContext } {
    var g = mem_mod.GlobalPool.init(std.testing.allocator);
    const c = ThreadContext.init(&g, std.testing.allocator);
    return .{ .g = g, .c = c };
}

test "Str.fromLiteral/deinit no leak" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var s = try Str.fromLiteral(&tc.c, "hello");
    defer s.deinit(&tc.c);
    try std.testing.expectEqual(@as(usize, 5), s.byteLength());
}

test "Str.byteLength/codepointCount for ASCII/CJK/emoji" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    {
        var s = try Str.fromLiteral(&tc.c, "hello");
        defer s.deinit(&tc.c);
        try std.testing.expectEqual(@as(usize, 5), s.byteLength());
        try std.testing.expectEqual(@as(usize, 5), try s.codepointCount());
    }
    {
        var s = try Str.fromLiteral(&tc.c, "中文");
        defer s.deinit(&tc.c);
        try std.testing.expectEqual(@as(usize, 6), s.byteLength());
        try std.testing.expectEqual(@as(usize, 2), try s.codepointCount());
    }
    {
        var s = try Str.fromLiteral(&tc.c, "😀");
        defer s.deinit(&tc.c);
        try std.testing.expectEqual(@as(usize, 4), s.byteLength());
        try std.testing.expectEqual(@as(usize, 1), try s.codepointCount());
    }
    {
        var s = try Str.fromLiteral(&tc.c, "a中😀");
        defer s.deinit(&tc.c);
        try std.testing.expectEqual(@as(usize, 8), s.byteLength());
        try std.testing.expectEqual(@as(usize, 3), try s.codepointCount());
    }
}

test "Str.concat (by-value, 独立缓冲区)" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "Hello, ");
    defer a.deinit(&tc.c);
    var b = try Str.fromLiteral(&tc.c, "世界!");
    defer b.deinit(&tc.c);
    var c = try a.concat(&tc.c, b);
    defer c.deinit(&tc.c);
    try std.testing.expectEqualStrings("Hello, 世界!", c.bytes());
    try std.testing.expectEqual(@as(usize, 14), c.byteLength());
    try std.testing.expectEqualStrings("Hello, ", a.bytes());
    try std.testing.expectEqualStrings("世界!", b.bytes());
}

test "Str.concatContiguous (连续缓冲区)" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    // total > SSO_MAX(20)，强制走堆连续路径
    var a = try Str.fromLiteral(&tc.c, "Hello, World! ");
    defer a.deinit(&tc.c);
    var b = try Str.fromLiteral(&tc.c, "世界!");
    defer b.deinit(&tc.c);
    const c = try Str.concatContiguous(&tc.c, a, b);
    defer tc.c.freeObj(@ptrCast(c));
    try std.testing.expectEqualStrings("Hello, World! 世界!", c.bytes());
    try std.testing.expect(c.isContiguous());
}

test "Str.createContiguous" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    {
        const s = try Str.createContiguous(&tc.c, "hi");
        defer tc.c.freeObj(@ptrCast(s));
        try std.testing.expect(s.isSso());
        try std.testing.expectEqualStrings("hi", s.bytes());
    }
    {
        const s = try Str.createContiguous(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes
        defer tc.c.freeObj(@ptrCast(s));
        try std.testing.expect(!s.isSso());
        try std.testing.expect(s.isContiguous());
        try std.testing.expectEqualStrings("0123456789ABCDEFGHIJK", s.bytes());
    }
}

test "Str.concatInPlace 独立缓冲区就地追加" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap, 独立
    defer a.deinit(&tc.c);
    var b = try Str.fromLiteral(&tc.c, "XYZWV"); // 5 bytes, SSO
    defer b.deinit(&tc.c);

    const ok = a.concatInPlace(&tc.c, &b);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("0123456789ABCDEFGHIJKXYZWV", a.bytes());
    try std.testing.expectEqual(@as(usize, 26), a.byteLength());
    try std.testing.expectEqualStrings("XYZWV", b.bytes());
}

test "Str.concatInPlace 连续缓冲区容量足够时零 alloc" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    // concatContiguous 产生 2x 过分配的连续缓冲区
    // 注意：fromLiteral 用于 >SSO_MAX 的字符串（concatSso 仅限 <=SSO_MAX）
    var a_src = try Str.fromLiteral(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap 独立
    defer a_src.deinit(&tc.c);
    const a = try Str.concatContiguous(&tc.c, a_src, Str.concatSso("", ""));
    defer tc.c.freeObj(@ptrCast(a));
    try std.testing.expect(a.isContiguous());
    try std.testing.expectEqualStrings("0123456789ABCDEFGHIJK", a.bytes());

    // 容量足够：total=26 <= cap(42)，走零 alloc 快速路径
    var b = try Str.fromLiteral(&tc.c, "XYZWV");
    defer b.deinit(&tc.c);
    const ok = a.concatInPlace(&tc.c, &b);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("0123456789ABCDEFGHIJKXYZWV", a.bytes());
    try std.testing.expectEqual(@as(usize, 26), a.byteLength());
}

test "Str.concatInPlace 连续缓冲区容量不足时回退" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const a = try Str.createContiguous(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, cap=21
    defer tc.c.freeObj(@ptrCast(a));
    try std.testing.expect(a.isContiguous());

    var b = try Str.fromLiteral(&tc.c, "XYZWVXYZWVXYZWVXYZWVXYZWV"); // 25 bytes
    defer b.deinit(&tc.c);
    // total=46 > cap=21，连续缓冲区无法 realloc，应回退
    try std.testing.expect(!a.concatInPlace(&tc.c, &b));
}

test "Str.concatInPlace SSO 回退" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "abc"); // SSO
    defer a.deinit(&tc.c);
    var b = try Str.fromLiteral(&tc.c, "def");
    defer b.deinit(&tc.c);
    try std.testing.expect(!a.concatInPlace(&tc.c, &b));
}

test "Str.concatInPlace 自拼接回退" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap
    defer a.deinit(&tc.c);
    try std.testing.expect(!a.concatInPlace(&tc.c, &a));
}

test "Str.concatInPlace rc>1 时回退" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap
    defer a.deinit(&tc.c);
    a.heapRetain(); // rc=2
    var b = try Str.fromLiteral(&tc.c, "XYZWV");
    defer b.deinit(&tc.c);
    try std.testing.expect(!a.concatInPlace(&tc.c, &b));
    _ = a.heapRelease(); // rc=1，恢复
}

test "Str.compare and equals" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var a = try Str.fromLiteral(&tc.c, "apple");
    defer a.deinit(&tc.c);
    var b = try Str.fromLiteral(&tc.c, "banana");
    defer b.deinit(&tc.c);
    var a2 = try Str.fromLiteral(&tc.c, "apple");
    defer a2.deinit(&tc.c);
    var app = try Str.fromLiteral(&tc.c, "app");
    defer app.deinit(&tc.c);
    try std.testing.expect(a.equals(a2));
    try std.testing.expect(!a.equals(b));
    try std.testing.expectEqual(std.math.Order.eq, a.compare(a2));
    try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
    try std.testing.expectEqual(std.math.Order.gt, b.compare(a));
    try std.testing.expectEqual(std.math.Order.lt, app.compare(a));
    try std.testing.expectEqual(std.math.Order.gt, a.compare(app));
}

test "Str.empty string" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var s = try Str.fromLiteral(&tc.c, "");
    defer s.deinit(&tc.c);
    try std.testing.expectEqual(@as(usize, 0), s.byteLength());
    try std.testing.expectEqual(@as(usize, 0), try s.codepointCount());
    var other = try Str.fromLiteral(&tc.c, "");
    defer other.deinit(&tc.c);
    try std.testing.expect(s.equals(other));
    try std.testing.expectEqual(std.math.Order.eq, s.compare(other));
    var hi = try Str.fromLiteral(&tc.c, "hi");
    defer hi.deinit(&tc.c);
    var c1 = try s.concat(&tc.c, hi);
    defer c1.deinit(&tc.c);
    try std.testing.expectEqualStrings("hi", c1.bytes());
    var c2 = try hi.concat(&tc.c, s);
    defer c2.deinit(&tc.c);
    try std.testing.expectEqualStrings("hi", c2.bytes());
}

test "Str.SSO boundary (≤20 inline, >20 heap)" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    {
        const lit = "0123456789ABCDEFGHIJ";
        try std.testing.expectEqual(@as(usize, 20), lit.len);
        var s = try Str.fromLiteral(&tc.c, lit);
        defer s.deinit(&tc.c);
        try std.testing.expect(s.isSso());
        try std.testing.expectEqualStrings(lit, s.bytes());
    }
    {
        const lit = "0123456789ABCDEFGHIJK";
        try std.testing.expectEqual(@as(usize, 21), lit.len);
        var s = try Str.fromLiteral(&tc.c, lit);
        defer s.deinit(&tc.c);
        try std.testing.expect(!s.isSso());
        try std.testing.expectEqualStrings(lit, s.bytes());
    }
}

test "Str.fromOwnedBytes SSO vs heap" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    {
        const buf = try tc.c.allocObj(5);
        @memcpy(buf, "hello");
        var s = Str.fromOwnedBytes(&tc.c, buf);
        defer s.deinit(&tc.c);
        try std.testing.expect(s.isSso());
        try std.testing.expectEqualStrings("hello", s.bytes());
    }
    {
        const buf = try tc.c.allocObj(25);
        @memset(buf, 'x');
        var s = Str.fromOwnedBytes(&tc.c, buf);
        defer s.deinit(&tc.c);
        try std.testing.expect(!s.isSso());
        try std.testing.expectEqual(@as(usize, 25), s.byteLength());
    }
}

test "Str concat produces SSO when result ≤20" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    {
        var a = try Str.fromLiteral(&tc.c, "abc");
        defer a.deinit(&tc.c);
        var b = try Str.fromLiteral(&tc.c, "def");
        defer b.deinit(&tc.c);
        var c = try a.concat(&tc.c, b);
        defer c.deinit(&tc.c);
        try std.testing.expect(c.isSso());
        try std.testing.expectEqualStrings("abcdef", c.bytes());
    }
    {
        var a = try Str.fromLiteral(&tc.c, "0123456789");
        defer a.deinit(&tc.c);
        var b = try Str.fromLiteral(&tc.c, "ABCDEFGHIJK");
        defer b.deinit(&tc.c);
        var c = try a.concat(&tc.c, b);
        defer c.deinit(&tc.c);
        try std.testing.expect(!c.isSso());
        try std.testing.expectEqualStrings("0123456789ABCDEFGHIJK", c.bytes());
    }
}

test "Str layout with ObjHeader" {
    // header(8) + _word0(8) + _word1(8) + _word2(4) + sso_flags(4) = 32
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Str));
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var s = try Str.fromLiteral(&tc.c, "hi");
    defer s.deinit(&tc.c);
    try std.testing.expectEqual(obj_header.RefKind.str, s.header.type_tag);
    try std.testing.expect(s.isSso());
    // SSO 模式下 header.rc 保持默认值 1（未使用）
    try std.testing.expectEqual(@as(u32, 1), s.header.rc);
}

test "Str heap retain/release via header.rc" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var s = try Str.fromLiteral(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap
    defer s.deinit(&tc.c);
    try std.testing.expect(!s.isSso());
    try std.testing.expectEqual(@as(u32, 1), s.header.rc);
    s.heapRetain();
    try std.testing.expectEqual(@as(u32, 2), s.header.rc);
    try std.testing.expect(!s.heapRelease());
    try std.testing.expectEqual(@as(u32, 1), s.header.rc);
    try std.testing.expect(s.heapRelease());
}

test "Str strDeinit for heap-allocated contiguous Str" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const s = try Str.createContiguous(&tc.c, "0123456789ABCDEFGHIJK"); // 21 bytes, heap, contiguous
    try std.testing.expect(!s.isSso());
    try std.testing.expect(s.isContiguous());
    strDeinit(&s.header, &tc.c);
}

test "Str strDeinit for SSO-allocated Str" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    const s = try Str.createContiguous(&tc.c, "hi"); // SSO
    try std.testing.expect(s.isSso());
    // SSO 模式下 deinit 为空操作，strDeinit 仅释放对象本体
    strDeinit(&s.header, &tc.c);
}

test "Str sso retain/release in sso_flags" {
    var tc = testCtx();
    tc.c.global = &tc.g;
    defer tc.g.deinit();
    defer tc.c.deinit();
    var s = try Str.fromLiteral(&tc.c, "abc");
    defer s.deinit(&tc.c);
    try std.testing.expect(s.isSso());
    const initial_flags = s.sso_flags;
    s.ssoRetain();
    // 引用计数从 1 增加到 2，标志位和长度不变
    try std.testing.expectEqual(initial_flags + (1 << Str.SSO_REFCOUNT_SHIFT), s.sso_flags);
    try std.testing.expect(!s.ssoRelease());
    try std.testing.expectEqual(initial_flags, s.sso_flags);
    // 最后一次 release 返回 true
    try std.testing.expect(s.ssoRelease());
}
