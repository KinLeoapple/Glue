//! 宽整型运算模块
//!
//! 提供超出原生整数宽度的算术运算支持：
//! - mulU64ToU128 将两个 u64 相乘得到 u128
//! - multiplyU64Schoolbook 多精度乘法
//! - U128 128 位无符号整数及运算
//! - U256 256 位无符号整数及运算
//!
//! 这些类型是 int.zig 和 float.zig 实现 128 位运算的基础设施。

const std = @import("std");

/// 将两个 u64 相乘，返回 128 位结果（低 64 位 + 高 64 位）
pub inline fn mulU64ToU128(a: u64, b: u64) struct { lo: u64, hi: u64 } {
const a_lo: u32 = @truncate(a & 0xFFFFFFFF);
const a_hi: u32 = @truncate(a >> 32);
const b_lo: u32 = @truncate(b & 0xFFFFFFFF);
const b_hi: u32 = @truncate(b >> 32);
const ll: u64 = @as(u64, a_lo) * @as(u64, b_lo);
const lh: u64 = @as(u64, a_lo) * @as(u64, b_hi);
const hl: u64 = @as(u64, a_hi) * @as(u64, b_lo);
const hh: u64 = @as(u64, a_hi) * @as(u64, b_hi);
// 中间项进位累加
const mid: u64 = (ll >> 32) + (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF);
const lo: u64 = (ll & 0xFFFFFFFF) | (mid << 32);
const hi: u64 = hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
return .{ .lo = lo, .hi = hi };
}

/// 多精度乘法：对等长字节缓冲区执行教科书式逐字乘法
pub fn multiplyU64Schoolbook(r: []u8, a: []const u8, b: []const u8) void {
@memset(r, 0);
const n_words = a.len / 8;
std.debug.assert(a.len % 8 == 0);
std.debug.assert(b.len == a.len);
std.debug.assert(r.len == 2 * a.len);
var i: usize = 0;
while (i < n_words) : (i += 1) {
const av: u64 = loadWord(u64, a[i * 8 ..][0..8]);
if (av == 0) continue;
var j: usize = 0;
while (j < n_words) : (j += 1) {
const bv: u64 = loadWord(u64, b[j * 8 ..][0..8]);
if (bv == 0) continue;
const prod = mulU64ToU128(av, bv);
const lo_idx = i + j;
const existing_lo: u64 = loadWord(u64, r[lo_idx * 8 ..][0..8]);
const sum_lo, const c1 = @addWithOverflow(existing_lo, prod.lo);
storeWord(u64, r[lo_idx * 8 ..][0..8], sum_lo);
// 向高位传播进位
var k = lo_idx + 1;
var to_add: u64 = prod.hi +% @as(u64, c1);
while (to_add != 0 and k < n_words * 2) : (k += 1) {
const existing: u64 = loadWord(u64, r[k * 8 ..][0..8]);
const sum, const c = @addWithOverflow(existing, to_add);
storeWord(u64, r[k * 8 ..][0..8], sum);
to_add = c;
}
}
}
}

/// 从字节切片按小端序加载一个整数
pub inline fn loadWord(comptime Word: type, bytes: []const u8) Word {
const n = @sizeOf(Word);
std.debug.assert(bytes.len >= n);
var result: Word = 0;
inline for (0..n) |i| {
result |= @as(Word, bytes[i]) << @intCast(i * 8);
}
return result;
}

/// 将一个整数按小端序写入字节切片
pub inline fn storeWord(comptime Word: type, bytes: []u8, val: Word) void {
const n = @sizeOf(Word);
std.debug.assert(bytes.len >= n);
inline for (0..n) |i| {
bytes[i] = @truncate(val >> @intCast(i * 8));
}
}

/// 128 位无符号整数
pub const U128 = struct {
hi: u64,
lo: u64,

/// 零值
pub inline fn zero() U128 {
return .{ .hi = 0, .lo = 0 };
}

/// 从低 64 位构造，高位为零
pub inline fn fromU64(lo: u64) U128 {
return .{ .hi = 0, .lo = lo };
}

/// 从高低位对构造
pub inline fn fromU64Pair(hi: u64, lo: u64) U128 {
return .{ .hi = hi, .lo = lo };
}

/// 生成低 width 位为 1 的掩码
pub inline fn mask(width: u8) U128 {
if (width == 0) return .{ .hi = 0, .lo = 0 };
if (width >= 128) return .{ .hi = ~@as(u64, 0), .lo = ~@as(u64, 0) };
if (width < 64) {
return .{ .hi = 0, .lo = (@as(u64, 1) << @intCast(width)) - 1 };
}
if (width == 64) {
return .{ .hi = 0, .lo = ~@as(u64, 0) };
}
const hi_width: u6 = @intCast(width - 64);
return .{ .hi = (@as(u64, 1) << hi_width) - 1, .lo = ~@as(u64, 0) };
}

/// 从 16 字节小端序缓冲区加载
pub inline fn load(bytes: []const u8) U128 {
return .{
.lo = loadWord(u64, bytes[0..8]),
.hi = loadWord(u64, bytes[8..16]),
};
}

/// 以小端序写入 16 字节缓冲区
pub inline fn store(self: U128, bytes: []u8) void {
storeWord(u64, bytes[0..8], self.lo);
storeWord(u64, bytes[8..16], self.hi);
}

/// 加法，返回和与进位
pub inline fn add(self: U128, other: U128) struct { sum: U128, carry: u1 } {
const lo, const c1 = @addWithOverflow(self.lo, other.lo);
const hi, const c2 = @addWithOverflow(self.hi, other.hi);
const hi_final, const c3 = @addWithOverflow(hi, c1);
return .{ .sum = .{ .hi = hi_final, .lo = lo }, .carry = c2 | c3 };
}

/// 减法，返回差与借位
pub inline fn sub(self: U128, other: U128) struct { diff: U128, borrow: u1 } {
const lo, const b1 = @subWithOverflow(self.lo, other.lo);
const hi, const b2 = @subWithOverflow(self.hi, other.hi);
const hi_final, const b3 = @subWithOverflow(hi, b1);
return .{ .diff = .{ .hi = hi_final, .lo = lo }, .borrow = b2 | b3 };
}

/// 按位或
pub inline fn or_(self: U128, other: U128) U128 {
return .{ .hi = self.hi | other.hi, .lo = self.lo | other.lo };
}

/// 按位与
pub inline fn and_(self: U128, other: U128) U128 {
return .{ .hi = self.hi & other.hi, .lo = self.lo & other.lo };
}

/// 按位异或
pub inline fn xor_(self: U128, other: U128) U128 {
return .{ .hi = self.hi ^ other.hi, .lo = self.lo ^ other.lo };
}

/// 按位取反
pub inline fn bitwiseNot(self: U128) U128 {
return .{ .hi = ~self.hi, .lo = ~self.lo };
}

/// 判断是否为零
pub inline fn isZero(self: U128) bool {
return (self.lo | self.hi) == 0;
}

/// 判断是否相等
pub inline fn equals(self: U128, other: U128) bool {
return self.hi == other.hi and self.lo == other.lo;
}

/// 无符号比较
pub inline fn compare(self: U128, other: U128) std.math.Order {
if (self.hi < other.hi) return .lt;
if (self.hi > other.hi) return .gt;
if (self.lo < other.lo) return .lt;
if (self.lo > other.lo) return .gt;
return .eq;
}

/// 二补码取负
pub inline fn negate(self: U128) U128 {
const not_self = U128{ .hi = ~self.hi, .lo = ~self.lo };
return not_self.add(.{ .hi = 0, .lo = 1 }).sum;
}

/// 前导零计数
pub inline fn clz(self: U128) u8 {
if (self.hi != 0) {
return @intCast(@clz(self.hi));
}
return @as(u8, 64) + @as(u8, @intCast(@clz(self.lo)));
}

/// 测试指定位置的比特
pub inline fn testBit(self: U128, pos: u8) bool {
if (pos < 64) {
return (self.lo >> @intCast(pos)) & 1 != 0;
}
return (self.hi >> @intCast(pos - 64)) & 1 != 0;
}

/// 将指定位置的比特置 1
pub inline fn orBit(self: U128, pos: u8) U128 {
if (pos < 64) {
return .{ .hi = self.hi, .lo = self.lo | (@as(u64, 1) << @intCast(pos)) };
}
return .{ .hi = self.hi | (@as(u64, 1) << @intCast(pos - 64)), .lo = self.lo };
}

/// 检查低 width 位是否有非零
pub inline fn lowBitsNonZero(self: U128, width: u32) bool {
if (width == 0) return false;
if (width >= 128) return !self.isZero();
if (width >= 64) {
if (self.lo != 0) return true;
if (width == 64) return false;
const sh: u6 = @intCast(width - 64);
const low_mask: u64 = (@as(u64, 1) << sh) - 1;
return (self.hi & low_mask) != 0;
}
const sh: u6 = @intCast(width);
const low_mask: u64 = (@as(u64, 1) << sh) - 1;
return (self.lo & low_mask) != 0;
}

/// 左移 n 位
pub inline fn shiftLeft(self: U128, n: u8) U128 {
if (n == 0) return self;
if (n >= 128) return .{ .hi = 0, .lo = 0 };
if (n < 64) {
const sh: u6 = @intCast(n);
const right_sh: u6 = @intCast(64 - n);
return .{
.hi = (self.hi << sh) | (self.lo >> right_sh),
.lo = self.lo << sh,
};
}
if (n == 64) return .{ .hi = self.lo, .lo = 0 };
const sh: u6 = @intCast(n - 64);
return .{ .hi = self.lo << sh, .lo = 0 };
}

/// 右移 n 位，arithmetic 为 true 时执行算术右移（符号位扩展）
pub inline fn shiftRight(self: U128, n: u8, arithmetic: bool) U128 {
if (n == 0) return self;
const sign_bit = (self.hi >> 63) != 0;
const fill: u64 = if (arithmetic and sign_bit) ~@as(u64, 0) else 0;
if (n >= 128) return .{ .hi = fill, .lo = fill };
if (n < 64) {
const sh: u6 = @intCast(n);
const left_sh: u6 = @intCast(64 - n);
return .{
.hi = (self.hi >> sh) | (fill << left_sh),
.lo = (self.lo >> sh) | (self.hi << left_sh),
};
}
if (n == 64) return .{ .hi = fill, .lo = self.hi };
const sh: u6 = @intCast(n - 64);
const left_sh: u6 = @intCast(128 - n);
return .{
.hi = fill,
.lo = (self.hi >> sh) | (fill << left_sh),
};
}

/// 右移 1 位，从最高位注入 carry_in
pub inline fn shiftRight1(self: U128, carry_in: u1) U128 {
const lsb_hi: u1 = @truncate(self.hi & 1);
return .{
.hi = (self.hi >> 1) | (@as(u64, carry_in) << 63),
.lo = (self.lo >> 1) | (@as(u64, lsb_hi) << 63),
};
}

/// 左移 1 位，从最低位注入 bit_in，返回结果和溢出的最高位
pub inline fn shiftLeft1WithBit(self: U128, bit_in: u1) struct { result: U128, carry: u1 } {
const carry_from_lo: u1 = @truncate(self.lo >> 63);
const msb: u1 = @truncate(self.hi >> 63);
return .{
.result = .{
.lo = (self.lo << 1) | @as(u64, bit_in),
.hi = (self.hi << 1) | @as(u64, carry_from_lo),
},
.carry = msb,
};
}

/// 右移并保留粘滞位（sticky bit）：移出的任何非零位都会使结果的最低位置 1
pub inline fn shiftRightWithSticky(self: U128, shift: u32) U128 {
if (shift == 0) return self;
if (shift >= 128) return if (!self.isZero()) U128.fromU64(1) else U128.zero();
if (shift < 64) {
const sh: u6 = @intCast(shift);
const lost_mask: u64 = (@as(u64, 1) << sh) - 1;
const lost: u64 = self.lo & lost_mask;
const right_sh: u6 = @intCast(64 - shift);
return .{
.hi = self.hi >> sh,
.lo = (self.lo >> sh) | (self.hi << right_sh) | (if (lost != 0) @as(u64, 1) else 0),
};
}
if (shift == 64) {
const lost: u64 = self.lo;
return .{
.hi = 0,
.lo = self.hi | (if (lost != 0) @as(u64, 1) else 0),
};
}
const sh: u6 = @intCast(shift - 64);
const lost_mask: u64 = (@as(u64, 1) << sh) - 1;
const lost: u64 = self.lo | (self.hi & lost_mask);
return .{
.hi = 0,
.lo = (self.hi >> sh) | (if (lost != 0) @as(u64, 1) else 0),
};
}

/// 左移扩展到 256 位
pub inline fn shiftLeftWide(self: U128, n: u8) U256 {
std.debug.assert(n <= 128);
if (n == 0) return U256.fromU128(self);
if (n == 128) return .{ .hi = self, .lo = U128.zero() };
return .{
.hi = self.shiftRight(@intCast(128 - n), false),
.lo = self.shiftLeft(n),
};
}

/// 乘法，返回 256 位结果
pub inline fn multiply(self: U128, other: U128) U256 {
const ll = mulU64ToU128(self.lo, other.lo);
const lh = mulU64ToU128(self.lo, other.hi);
const hl = mulU64ToU128(self.hi, other.lo);
const hh = mulU64ToU128(self.hi, other.hi);
const r0: u64 = ll.lo;
const r1_sum, const c1a = @addWithOverflow(ll.hi, lh.lo);
const r1, const c1b = @addWithOverflow(r1_sum, hl.lo);
const carry1: u64 = @as(u64, c1a) + @as(u64, c1b);
const r2_sum, const c2a = @addWithOverflow(hh.lo, lh.hi);
const r2_sum2, const c2b = @addWithOverflow(r2_sum, hl.hi);
const r2, const c2c = @addWithOverflow(r2_sum2, carry1);
const carry2: u64 = @as(u64, c2a) + @as(u64, c2b) + @as(u64, c2c);
const r3, const c3 = @addWithOverflow(hh.hi, carry2);
std.debug.assert(c3 == 0);
return .{
.lo = .{ .hi = r1, .lo = r0 },
.hi = .{ .hi = r3, .lo = r2 },
};
}
};

/// 256 位无符号整数，由高低两个 U128 组成
pub const U256 = struct {
hi: U128,
lo: U128,

/// 零值
pub inline fn zero() U256 {
return .{ .hi = U128.zero(), .lo = U128.zero() };
}

/// 从 U128 构造，高位部分为零
pub inline fn fromU128(lo: U128) U256 {
return .{ .hi = U128.zero(), .lo = lo };
}

/// 判断是否为零
pub inline fn isZero(self: U256) bool {
return self.hi.isZero() and self.lo.isZero();
}

/// 测试指定位置的比特
pub inline fn bit(self: U256, pos: u32) bool {
if (pos < 128) return self.lo.testBit(@intCast(pos));
return self.hi.testBit(@intCast(pos - 128));
}

/// 左移 1 位，从最低位注入 bit_in，返回溢出的最高位
pub inline fn shiftLeft1InPlace(self: *U256, bit_in: u1) u1 {
const lo_shift = self.lo.shiftLeft1WithBit(bit_in);
self.lo = lo_shift.result;
const hi_shift = self.hi.shiftLeft1WithBit(lo_shift.carry);
self.hi = hi_shift.result;
return hi_shift.carry;
}

/// 右移 1 位
pub inline fn shiftRight1(self: U256) U256 {
const carry: u1 = @truncate(self.hi.lo & 1);
return .{
.hi = self.hi.shiftRight1(0),
.lo = self.lo.shiftRight1(carry),
};
}

/// 右移 1 位并保留粘滞位
pub inline fn shiftRight1WithSticky(self: U256) U256 {
const lost: u1 = @truncate(self.lo.lo & 1);
var result = self.shiftRight1();
if (lost == 1) result.lo.lo |= 1;
return result;
}

/// 除以 U128，返回商和余数
pub inline fn divideByU128(self: U256, divisor: U128) struct { quotient: U128, remainder: U128 } {
var dividend: U256 = self;
var rem: U128 = U128.zero();
var rem_carry: u1 = 0;
var quot_lo: U128 = U128.zero();
var quot_hi: U128 = U128.zero();
var i: u32 = 0;
while (i < 256) : (i += 1) {
const msb: u1 = @truncate(dividend.hi.hi >> 63);
_ = dividend.shiftLeft1InPlace(0);
rem_carry = @truncate(rem.hi >> 63);
rem = rem.shiftLeft1WithBit(msb).result;
if (rem_carry == 1 or rem.compare(divisor) != .lt) {
rem = rem.sub(divisor).diff;
rem_carry = 0;
if (i < 128) {
quot_hi = quot_hi.orBit(@intCast(127 - i));
} else {
quot_lo = quot_lo.orBit(@intCast(255 - i));
}
}
}
std.debug.assert(quot_hi.isZero());
return .{ .quotient = quot_lo, .remainder = rem };
}

/// 从指定起始位提取 128 位
pub inline fn extractU128(self: U256, start: u32) U128 {
std.debug.assert(start <= 128);
if (start == 0) return self.lo;
if (start == 128) return self.hi;
const sh: u8 = @intCast(start);
const left_sh: u8 = @intCast(128 - start);
return self.lo.shiftRight(sh, false).or_(self.hi.shiftLeft(left_sh));
}
};

test "mulU64ToU128 basic" {
const r1 = mulU64ToU128(0, 0);
try std.testing.expectEqual(@as(u64, 0), r1.lo);
try std.testing.expectEqual(@as(u64, 0), r1.hi);
const r2 = mulU64ToU128(1, 1);
try std.testing.expectEqual(@as(u64, 1), r2.lo);
try std.testing.expectEqual(@as(u64, 0), r2.hi);
const r3 = mulU64ToU128(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
try std.testing.expectEqual(@as(u64, 1), r3.lo);
try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), r3.hi);
const r4 = mulU64ToU128(0x100000000, 0x100000000);
try std.testing.expectEqual(@as(u64, 0), r4.lo);
try std.testing.expectEqual(@as(u64, 1), r4.hi);
}

test "U128.add/sub" {
const a = U128.fromU64Pair(1, 2);
const b = U128.fromU64Pair(0, 3);
const r_add = a.add(b);
try std.testing.expectEqual(U128.fromU64Pair(1, 5), r_add.sum);
try std.testing.expectEqual(@as(u1, 0), r_add.carry);
const r_sub = a.sub(b);
try std.testing.expectEqual(U128.fromU64Pair(0, 0xFFFFFFFFFFFFFFFF), r_sub.diff);
try std.testing.expectEqual(@as(u1, 0), r_sub.borrow);
const r_sub_swap = b.sub(a);
try std.testing.expectEqual(U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 1), r_sub_swap.diff);
try std.testing.expectEqual(@as(u1, 1), r_sub_swap.borrow);
const max = U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
const one = U128.fromU64(1);
const r_of = max.add(one);
try std.testing.expectEqual(U128.zero(), r_of.sum);
try std.testing.expectEqual(@as(u1, 1), r_of.carry);
}

test "U128.clz" {
try std.testing.expectEqual(@as(u8, 128), U128.zero().clz());
try std.testing.expectEqual(@as(u8, 127), U128.fromU64(1).clz());
try std.testing.expectEqual(@as(u8, 127), U128.fromU64Pair(0, 1).clz());
try std.testing.expectEqual(@as(u8, 0), U128.fromU64Pair(0x8000000000000000, 0).clz());
}

test "U128.testBit/orBit" {
const a = U128.fromU64(0b1010);
try std.testing.expect(a.testBit(1));
try std.testing.expect(!a.testBit(0));
try std.testing.expect(a.testBit(3));
const b = a.orBit(0);
try std.testing.expect(b.testBit(0));
const c = a.orBit(100);
try std.testing.expect(c.testBit(100));
}

test "U128.shiftLeft/shiftRight" {
const a = U128.fromU64(0xFF);
try std.testing.expectEqual(U128.fromU64(0x1FE), a.shiftLeft(1));
try std.testing.expectEqual(U128.fromU64(0xFF00), a.shiftLeft(8));
try std.testing.expectEqual(U128.fromU64Pair(0xFF, 0), a.shiftLeft(64));
try std.testing.expectEqual(U128.zero(), a.shiftLeft(128));
try std.testing.expectEqual(U128.fromU64(0x7F), a.shiftRight(1, false));
const signed = U128.fromU64Pair(0x8000000000000000, 0);
try std.testing.expectEqual(U128.fromU64Pair(0xC000000000000000, 0), signed.shiftRight(1, true));
}

test "U128.shiftRightWithSticky" {
const a = U128.fromU64(0xFF);
try std.testing.expectEqual(U128.fromU64(0xF), a.shiftRightWithSticky(4));
const b = U128.fromU64(0x10);
try std.testing.expectEqual(U128.fromU64(1), b.shiftRightWithSticky(4));
const c = U128.fromU64(0x11);
try std.testing.expectEqual(U128.fromU64(1), c.shiftRightWithSticky(4));
try std.testing.expectEqual(U128.fromU64(1), U128.fromU64(1).shiftRightWithSticky(128));
try std.testing.expectEqual(U128.zero(), U128.zero().shiftRightWithSticky(128));
}

test "U128.multiply" {
try std.testing.expect(U128.zero().multiply(U128.zero()).isZero());
const a = U128.fromU64Pair(1, 0);
const r1 = a.multiply(a);
try std.testing.expectEqual(U128.zero(), r1.lo);
try std.testing.expectEqual(U128.fromU64(1), r1.hi);
const b = U128.fromU64(0xFFFFFFFFFFFFFFFF);
const r2 = b.multiply(b);
try std.testing.expectEqual(@as(u64, 1), r2.lo.lo);
try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), r2.lo.hi);
try std.testing.expectEqual(@as(u64, 0), r2.hi.lo);
try std.testing.expectEqual(@as(u64, 0), r2.hi.hi);
}

test "U256.divideByU128" {
const dividend = U256.fromU128(U128.fromU64(256));
const divisor = U128.fromU64(1);
const r = dividend.divideByU128(divisor);
try std.testing.expectEqual(U128.fromU64(256), r.quotient);
try std.testing.expectEqual(U128.zero(), r.remainder);
const r2 = U256.fromU128(U128.fromU64(256)).divideByU128(U128.fromU64(7));
try std.testing.expectEqual(U128.fromU64(36), r2.quotient);
try std.testing.expectEqual(U128.fromU64(4), r2.remainder);
const r3 = U256.fromU128(U128.fromU64Pair(1, 0)).divideByU128(U128.fromU64(0x100000000));
try std.testing.expectEqual(U128.fromU64(0x100000000), r3.quotient);
try std.testing.expectEqual(U128.zero(), r3.remainder);
}

test "U256.bit/shiftRight1WithSticky" {
const a = U256.fromU128(U128.fromU64(0xFF));
try std.testing.expect(a.bit(0));
try std.testing.expect(a.bit(7));
try std.testing.expect(!a.bit(8));
const r = a.shiftRight1WithSticky();
try std.testing.expectEqual(@as(u64, 0x7F), r.lo.lo);
}

test "U128.mask edge cases" {
try std.testing.expect(U128.mask(0).isZero());
try std.testing.expectEqual(U128.fromU64(1), U128.mask(1));
try std.testing.expectEqual(U128.fromU64(0x7FFFFFFFFFFFFFFF), U128.mask(63));
try std.testing.expectEqual(U128.fromU64(0xFFFFFFFFFFFFFFFF), U128.mask(64));
try std.testing.expectEqual(U128.fromU64Pair(1, 0xFFFFFFFFFFFFFFFF), U128.mask(65));
try std.testing.expectEqual(U128.fromU64Pair(0x7FFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF), U128.mask(127));
try std.testing.expectEqual(U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF), U128.mask(128));
}

test "U128.shiftLeftWide" {
try std.testing.expect(U128.zero().shiftLeftWide(0).isZero());
const a = U128.fromU64(0xFF);
const r0 = a.shiftLeftWide(0);
try std.testing.expectEqual(a, r0.lo);
try std.testing.expect(r0.hi.isZero());
const r64 = a.shiftLeftWide(64);
try std.testing.expectEqual(U128.fromU64Pair(0xFF, 0), r64.lo);
try std.testing.expect(r64.hi.isZero());
const r128 = a.shiftLeftWide(128);
try std.testing.expectEqual(U128.zero(), r128.lo);
try std.testing.expectEqual(a, r128.hi);
const r70 = a.shiftLeftWide(70);
try std.testing.expectEqual(U128.fromU64Pair(0xFF << 6, 0), r70.lo);
try std.testing.expect(r70.hi.isZero());
}

test "U256.extractU128" {
const v = U256{ .hi = U128.fromU64(0xFF), .lo = U128.fromU64(0xFF) };
try std.testing.expectEqual(U128.fromU64(0xFF), v.extractU128(0));
try std.testing.expectEqual(U128.fromU64(0xFF), v.extractU128(128));
const r64 = v.extractU128(64);
try std.testing.expectEqual(U128.fromU64Pair(0xFF, 0), r64);
}
