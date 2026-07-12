//! 字符串值类型模块
//!
//! 定义 Glue 语言的字符串类型 Str，采用 SSO（Small String Optimization）
//! 策略：长度不超过 SSO_MAX（20 字节）的字符串内联存储在结构体中，
//! 超出时在堆上分配。SSO 模式使用引用计数位实现共享，堆模式使用
//! 独立的引用计数字段。

const std = @import("std");

/// 字符串值，extern struct 保证内存布局确定
pub const Str = extern struct {
_word0: u64 = 0,
_word1: u64 = 0,
_word2: u32 = 0,
rc: u32 = SSO_FLAG | SSO_REFCOUNT_INIT,

// SSO 标志位：rc 最高位为 1 表示 SSO 模式
const SSO_FLAG: u32 = 0x80000000;
// SSO 长度掩码：低 5 位存储内联字符串长度
const SSO_LEN_MASK: u32 = 0x1F;
// SSO 引用计数的位移量
const SSO_REFCOUNT_SHIFT: u5 = 5;
// SSO 引用计数掩码
const SSO_REFCOUNT_MASK: u32 = 0x7FFFFFE0;
// SSO 引用计数初始值
const SSO_REFCOUNT_INIT: u32 = 1 << SSO_REFCOUNT_SHIFT;

/// SSO 模式下内联存储的最大字节数
pub const SSO_MAX: usize = 20;

/// 判断当前是否为 SSO 模式
pub inline fn isSso(self: *const Str) bool {
return (self.rc & SSO_FLAG) != 0;
}

// 获取 SSO 模式下的内联字符串长度
fn ssoLen(self: *const Str) usize {
return self.rc & SSO_LEN_MASK;
}

/// SSO 模式下增加引用计数
pub inline fn ssoRetain(self: *Str) void {
const count = (self.rc & SSO_REFCOUNT_MASK) >> SSO_REFCOUNT_SHIFT;
if (count == 0x3FFFFFF) @panic("Str.ssoRetain: SSO refcount overflow (26-bit limit)");
self.rc = (self.rc & ~SSO_REFCOUNT_MASK) | ((count + 1) << SSO_REFCOUNT_SHIFT);
}

/// SSO 模式下减少引用计数，返回 true 表示引用计数已降为零
pub inline fn ssoRelease(self: *Str) bool {
const count = (self.rc & SSO_REFCOUNT_MASK) >> SSO_REFCOUNT_SHIFT;
if (count <= 1) return true;
self.rc = (self.rc & ~SSO_REFCOUNT_MASK) | ((count - 1) << SSO_REFCOUNT_SHIFT);
return false;
}

/// 从字面量构造字符串，短字符串走 SSO，长字符串在堆上拷贝
pub fn fromLiteral(allocator: std.mem.Allocator, s: []const u8) !Str {
if (s.len <= SSO_MAX) {
return initSso(s);
}
const owned = try allocator.dupe(u8, s);
return initHeap(owned.ptr, owned.len);
}

/// 从已拥有的字节切片构造字符串，短字符串走 SSO 并释放原缓冲区
pub fn fromOwnedBytes(allocator: std.mem.Allocator, buf: []u8) Str {
if (buf.len <= SSO_MAX) {
const result = initSso(buf);
allocator.free(buf);
return result;
}
return initHeap(buf.ptr, buf.len);
}

// 初始化 SSO 模式：将字符串内联拷贝到结构体内
fn initSso(s: []const u8) Str {
var result = Str{ .rc = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(s.len)) };
const dst: [*]u8 = @ptrCast(&result);
@memcpy(dst[0..s.len], s);
return result;
}

/// 将两个字节切片拼接为 SSO 字符串（调用方需确保总长度不超过 SSO_MAX）
pub fn concatSso(a: []const u8, b: []const u8) Str {
const total = a.len + b.len;
var result = Str{ .rc = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(total)) };
const dst: [*]u8 = @ptrCast(&result);
@memcpy(dst[0..a.len], a);
@memcpy(dst[a.len..total], b);
return result;
}

/// 判断两个长度拼接后是否可走 SSO
pub inline fn canConcatSso(a_len: usize, b_len: usize) bool {
return a_len + b_len <= SSO_MAX;
}

// 初始化堆模式：存储指针、长度，引用计数设为 1
fn initHeap(ptr: [*]u8, len: usize) Str {
return .{
._word0 = @intFromPtr(ptr),
._word1 = len,
._word2 = 0,
.rc = 1,
};
}

/// 释放堆模式下的字节缓冲区，SSO 模式为空操作
pub fn deinit(self: *Str, allocator: std.mem.Allocator) void {
if (!self.isSso()) {
const ptr: [*]u8 = @ptrFromInt(self._word0);
allocator.free(ptr[0..self._word1]);
self._word0 = 0;
self._word1 = 0;
}
}

/// 返回字符串的字节切片
pub inline fn bytes(self: *const Str) []const u8 {
if (self.isSso()) {
const len = self.ssoLen();
const ptr: [*]const u8 = @ptrCast(self);
return ptr[0..len];
}
const ptr: [*]const u8 = @ptrFromInt(self._word0);
return ptr[0..self._word1];
}

/// 返回字符串字节长度
pub inline fn byteLength(self: Str) usize {
if (self.isSso()) {
return self.ssoLen();
}
return self._word1;
}

/// 返回 Unicode 码点数量
pub fn codepointCount(self: Str) !usize {
return try std.unicode.utf8CountCodepoints(self.bytes());
}

/// 拼接两个字符串，结果短则 SSO，长则堆分配
pub fn concat(self: Str, allocator: std.mem.Allocator, other: Str) !Str {
const a_len = self.byteLength();
const b_len = other.byteLength();
const total = a_len + b_len;
if (total <= SSO_MAX) {
var result = Str{ .rc = SSO_FLAG | SSO_REFCOUNT_INIT | @as(u32, @intCast(total)) };
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

/// 按字典序比较
pub fn compare(self: Str, other: Str) std.math.Order {
return std.mem.order(u8, self.bytes(), other.bytes());
}

/// 判断两字符串内容是否相等
pub fn equals(self: Str, other: Str) bool {
return std.mem.eql(u8, self.bytes(), other.bytes());
}
};

test "Str.fromLiteral/deinit no leak" {
const allocator = std.testing.allocator;
var s = try Str.fromLiteral(allocator, "hello");
defer s.deinit(allocator);
try std.testing.expectEqual(@as(usize, 5), s.byteLength());
}

test "Str.byteLength/codepointCount for ASCII/CJK/emoji" {
const allocator = std.testing.allocator;
{
var s = try Str.fromLiteral(allocator, "hello");
defer s.deinit(allocator);
try std.testing.expectEqual(@as(usize, 5), s.byteLength());
try std.testing.expectEqual(@as(usize, 5), try s.codepointCount());
}
{
var s = try Str.fromLiteral(allocator, "中文");
defer s.deinit(allocator);
try std.testing.expectEqual(@as(usize, 6), s.byteLength());
try std.testing.expectEqual(@as(usize, 2), try s.codepointCount());
}
{
var s = try Str.fromLiteral(allocator, "😀");
defer s.deinit(allocator);
try std.testing.expectEqual(@as(usize, 4), s.byteLength());
try std.testing.expectEqual(@as(usize, 1), try s.codepointCount());
}
{
var s = try Str.fromLiteral(allocator, "a中😀");
defer s.deinit(allocator);
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
try std.testing.expectEqual(@as(usize, 14), c.byteLength());
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
try std.testing.expect(a.equals(a2));
try std.testing.expect(!a.equals(b));
try std.testing.expectEqual(std.math.Order.eq, a.compare(a2));
try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
try std.testing.expectEqual(std.math.Order.gt, b.compare(a));
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
{
const lit = "0123456789ABCDEFGHIJ";
try std.testing.expectEqual(@as(usize, 20), lit.len);
var s = try Str.fromLiteral(allocator, lit);
defer s.deinit(allocator);
try std.testing.expect(s.isSso());
try std.testing.expectEqualStrings(lit, s.bytes());
}
{
const lit = "0123456789ABCDEFGHIJK";
try std.testing.expectEqual(@as(usize, 21), lit.len);
var s = try Str.fromLiteral(allocator, lit);
defer s.deinit(allocator);
try std.testing.expect(!s.isSso());
try std.testing.expectEqualStrings(lit, s.bytes());
}
}

test "Str.fromOwnedBytes SSO vs heap" {
const allocator = std.testing.allocator;
{
const buf = try allocator.alloc(u8, 5);
@memcpy(buf, "hello");
var s = Str.fromOwnedBytes(allocator, buf);
defer s.deinit(allocator);
try std.testing.expect(s.isSso());
try std.testing.expectEqualStrings("hello", s.bytes());
}
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
