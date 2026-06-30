//! 宽整数算术基础模块（Int/Float/Char 共享）
//!
//! 提供 U128（{hi: u64, lo: u64}）和 U256（{hi: U128, lo: U128}）结构体，
//! 替代 Zig 原生 u128/i128 类型，避免平台相关 codegen bug。
//! 所有方法标 `inline fn`，ReleaseFast 下编译器内联为单条指令。
//!
//! 设计原则：
//! - 不使用 @bitCast（手动小端序，语义明确）
//! - 不使用 Zig 原生 u128/i128 算术（全部用 u64 字块）
//! - mulU64ToU128 用 32 位半字 schoolbook，避免 u128 平台行为

const std = @import("std");

/// u64 × u64 → u128（拆为 hi/lo 两个 u64 返回）
/// 32 位半字 schoolbook，避免依赖 Zig u128 平台行为
pub inline fn mulU64ToU128(a: u64, b: u64) struct { lo: u64, hi: u64 } {
    const a_lo: u32 = @truncate(a & 0xFFFFFFFF);
    const a_hi: u32 = @truncate(a >> 32);
    const b_lo: u32 = @truncate(b & 0xFFFFFFFF);
    const b_hi: u32 = @truncate(b >> 32);

    const ll: u64 = @as(u64, a_lo) * @as(u64, b_lo);
    const lh: u64 = @as(u64, a_lo) * @as(u64, b_hi);
    const hl: u64 = @as(u64, a_hi) * @as(u64, b_lo);
    const hh: u64 = @as(u64, a_hi) * @as(u64, b_hi);

    const mid: u64 = (ll >> 32) + (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF);
    const lo: u64 = (ll & 0xFFFFFFFF) | (mid << 32);
    const hi: u64 = hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
    return .{ .lo = lo, .hi = hi };
}

/// u64 字块 schoolbook 乘法：r[0..2N] = a[0..N] * b[0..N]
/// N 必须是 8 的倍数；r 长度须为 2N。本函数清零 r 后写入。
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

/// 从字节数组读取指定宽度的无符号整数（小端序，手动拼接）
pub inline fn loadWord(comptime Word: type, bytes: []const u8) Word {
    const n = @sizeOf(Word);
    std.debug.assert(bytes.len >= n);
    var result: Word = 0;
    inline for (0..n) |i| {
        result |= @as(Word, bytes[i]) << @intCast(i * 8);
    }
    return result;
}

/// 将无符号整数写入字节数组（小端序，手动拆分）
pub inline fn storeWord(comptime Word: type, bytes: []u8, val: Word) void {
    const n = @sizeOf(Word);
    std.debug.assert(bytes.len >= n);
    inline for (0..n) |i| {
        bytes[i] = @truncate(val >> @intCast(i * 8));
    }
}

/// 128 位无符号整数（hi/lo 拆分，避免 Zig u128 平台行为）
pub const U128 = struct {
    hi: u64,
    lo: u64,

    /// 全零
    pub inline fn zero() U128 {
        return .{ .hi = 0, .lo = 0 };
    }

    /// 从 u64 构造（高位补 0）
    pub inline fn fromU64(lo: u64) U128 {
        return .{ .hi = 0, .lo = lo };
    }

    /// 从 hi/lo 构造
    pub inline fn fromU64Pair(hi: u64, lo: u64) U128 {
        return .{ .hi = hi, .lo = lo };
    }

    /// 构造低 width 位全 1 的掩码（width: 0-128）
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

    /// 从 16 字节数组构造
    pub inline fn load(bytes: []const u8) U128 {
        return .{
            .lo = loadWord(u64, bytes[0..8]),
            .hi = loadWord(u64, bytes[8..16]),
        };
    }

    /// 写入 16 字节数组
    pub inline fn store(self: U128, bytes: []u8) void {
        storeWord(u64, bytes[0..8], self.lo);
        storeWord(u64, bytes[8..16], self.hi);
    }

    /// 加法，返回 sum 和 carry
    pub inline fn add(self: U128, other: U128) struct { sum: U128, carry: u1 } {
        const lo, const c1 = @addWithOverflow(self.lo, other.lo);
        const hi, const c2 = @addWithOverflow(self.hi, other.hi);
        const hi_final, const c3 = @addWithOverflow(hi, c1);
        return .{ .sum = .{ .hi = hi_final, .lo = lo }, .carry = c2 | c3 };
    }

    /// 减法，返回 diff 和 borrow
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

    /// 是否为全零
    pub inline fn isZero(self: U128) bool {
        return (self.lo | self.hi) == 0;
    }

    /// 相等
    pub inline fn equals(self: U128, other: U128) bool {
        return self.hi == other.hi and self.lo == other.lo;
    }

    /// 比较（无符号）
    pub inline fn compare(self: U128, other: U128) std.math.Order {
        if (self.hi < other.hi) return .lt;
        if (self.hi > other.hi) return .gt;
        if (self.lo < other.lo) return .lt;
        if (self.lo > other.lo) return .gt;
        return .eq;
    }

    /// 取负（补码取反加一）
    pub inline fn negate(self: U128) U128 {
        const not_self = U128{ .hi = ~self.hi, .lo = ~self.lo };
        return not_self.add(.{ .hi = 0, .lo = 1 }).sum;
    }

    /// 前导零计数（0-128）
    pub inline fn clz(self: U128) u8 {
        if (self.hi != 0) {
            return @intCast(@clz(self.hi));
        }
        return @as(u8, 64) + @as(u8, @intCast(@clz(self.lo)));
    }

    /// 测试指定位（pos: 0-127）
    pub inline fn testBit(self: U128, pos: u8) bool {
        if (pos < 64) {
            return (self.lo >> @intCast(pos)) & 1 != 0;
        }
        return (self.hi >> @intCast(pos - 64)) & 1 != 0;
    }

    /// 设置指定位，返回新值（pos: 0-127）
    pub inline fn orBit(self: U128, pos: u8) U128 {
        if (pos < 64) {
            return .{ .hi = self.hi, .lo = self.lo | (@as(u64, 1) << @intCast(pos)) };
        }
        return .{ .hi = self.hi | (@as(u64, 1) << @intCast(pos - 64)), .lo = self.lo };
    }

    /// 检查低 width 位是否非零（width: 0-128）
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

    /// 逻辑左移 n 位（n >= 128 返回 0）
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

    /// 右移 n 位。arithmetic=true 时高位补符号位，否则补 0。
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

    /// 右移 1 位，carry_in 进入 MSB（bit 127）
    pub inline fn shiftRight1(self: U128, carry_in: u1) U128 {
        const lsb_hi: u1 = @truncate(self.hi & 1);
        return .{
            .hi = (self.hi >> 1) | (@as(u64, carry_in) << 63),
            .lo = (self.lo >> 1) | (@as(u64, lsb_hi) << 63),
        };
    }

    /// 左移 1 位，bit_in 进入 LSB，返回新值和被移出的 MSB
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

    /// 右移并保留 sticky（丢失的位 OR 到 bit 0）
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
        // 64 < shift < 128
        const sh: u6 = @intCast(shift - 64);
        const lost_mask: u64 = (@as(u64, 1) << sh) - 1;
        const lost: u64 = self.lo | (self.hi & lost_mask);
        return .{
            .hi = 0,
            .lo = (self.hi >> sh) | (if (lost != 0) @as(u64, 1) else 0),
        };
    }

    /// 左移 n 位并扩展到 U256（n: 0-128）
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

        // bits [0, 64)
        const r0: u64 = ll.lo;

        // bits [64, 128) = ll.hi + lh.lo + hl.lo
        const r1_sum, const c1a = @addWithOverflow(ll.hi, lh.lo);
        const r1, const c1b = @addWithOverflow(r1_sum, hl.lo);
        const carry1: u64 = @as(u64, c1a) + @as(u64, c1b);

        // bits [128, 192) = hh.lo + lh.hi + hl.hi + carry1
        const r2_sum, const c2a = @addWithOverflow(hh.lo, lh.hi);
        const r2_sum2, const c2b = @addWithOverflow(r2_sum, hl.hi);
        const r2, const c2c = @addWithOverflow(r2_sum2, carry1);
        const carry2: u64 = @as(u64, c2a) + @as(u64, c2b) + @as(u64, c2c);

        // bits [192, 256) = hh.hi + carry2
        const r3, const c3 = @addWithOverflow(hh.hi, carry2);
        std.debug.assert(c3 == 0);

        return .{
            .lo = .{ .hi = r1, .lo = r0 },
            .hi = .{ .hi = r3, .lo = r2 },
        };
    }
};

/// 256 位无符号整数（Float 乘除法中间值）
pub const U256 = struct {
    hi: U128,
    lo: U128,

    /// 全零
    pub inline fn zero() U256 {
        return .{ .hi = U128.zero(), .lo = U128.zero() };
    }

    /// 从 U128 构造（高位补 0）
    pub inline fn fromU128(lo: U128) U256 {
        return .{ .hi = U128.zero(), .lo = lo };
    }

    /// 是否为全零
    pub inline fn isZero(self: U256) bool {
        return self.hi.isZero() and self.lo.isZero();
    }

    /// 测试指定位（pos: 0-255）
    pub inline fn bit(self: U256, pos: u32) bool {
        if (pos < 128) return self.lo.testBit(@intCast(pos));
        return self.hi.testBit(@intCast(pos - 128));
    }

    /// 左移 1 位，bit_in 进入 LSB，返回被移出的 MSB
    pub inline fn shiftLeft1InPlace(self: *U256, bit_in: u1) u1 {
        const lo_shift = self.lo.shiftLeft1WithBit(bit_in);
        self.lo = lo_shift.result;
        const hi_shift = self.hi.shiftLeft1WithBit(lo_shift.carry);
        self.hi = hi_shift.result;
        return hi_shift.carry;
    }

    /// 右移 1 位（逻辑移位）
    pub inline fn shiftRight1(self: U256) U256 {
        const carry: u1 = @truncate(self.hi.lo & 1);
        return .{
            .hi = self.hi.shiftRight1(0),
            .lo = self.lo.shiftRight1(carry),
        };
    }

    /// 右移 1 位并保留 sticky（丢失的 bit 0 OR 到结果的 bit 0）
    pub inline fn shiftRight1WithSticky(self: U256) U256 {
        const lost: u1 = @truncate(self.lo.lo & 1);
        var result = self.shiftRight1();
        if (lost == 1) result.lo.lo |= 1;
        return result;
    }

    /// 256 位 / 128 位 → 128 位商 + 128 位余数
    /// shift-subtract 长除法，256 次迭代。要求商不超过 128 位（调用方保证）。
    pub inline fn divideByU128(self: U256, divisor: U128) struct { quotient: U128, remainder: U128 } {
        var dividend: U256 = self;
        var rem: U128 = U128.zero();
        var rem_carry: u1 = 0;
        var quot_lo: U128 = U128.zero();
        var quot_hi: U128 = U128.zero();

        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            // 取被除数 MSB（bit 255）
            const msb: u1 = @truncate(dividend.hi.hi >> 63);
            // 被除数左移 1 位
            _ = dividend.shiftLeft1InPlace(0);

            // 余数左移 1 位，MSB 移出为 rem_carry，bit 进入 LSB
            rem_carry = @truncate(rem.hi >> 63);
            rem = rem.shiftLeft1WithBit(msb).result;

            // 若 rem 溢出（rem_carry=1）或 rem >= divisor，则减去除数
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

    /// 从 bit start 起取 128 位作为 U128（start: 0-128）
    /// 用于 Float 乘法提取 mant：result = (full >> start) 的低 128 位
    pub inline fn extractU128(self: U256, start: u32) U128 {
        std.debug.assert(start <= 128);
        if (start == 0) return self.lo;
        if (start == 128) return self.hi;
        // 0 < start < 128: (lo >> start) | (hi << (128 - start))
        const sh: u8 = @intCast(start);
        const left_sh: u8 = @intCast(128 - start);
        return self.lo.shiftRight(sh, false).or_(self.hi.shiftLeft(left_sh));
    }
};

// —— 测试 ——

test "mulU64ToU128 basic" {
    const r1 = mulU64ToU128(0, 0);
    try std.testing.expectEqual(@as(u64, 0), r1.lo);
    try std.testing.expectEqual(@as(u64, 0), r1.hi);

    const r2 = mulU64ToU128(1, 1);
    try std.testing.expectEqual(@as(u64, 1), r2.lo);
    try std.testing.expectEqual(@as(u64, 0), r2.hi);

    const r3 = mulU64ToU128(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
    // (2^64 - 1)^2 = 2^128 - 2^65 + 1
    try std.testing.expectEqual(@as(u64, 1), r3.lo);
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), r3.hi);

    const r4 = mulU64ToU128(0x100000000, 0x100000000);
    // 2^32 * 2^32 = 2^64
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
    try std.testing.expectEqual(@as(u1, 0), r_sub.borrow); // a > b，无 borrow

    // b < a：有 borrow，结果 = -(2^64 - 1) 的无符号表示
    const r_sub_swap = b.sub(a);
    try std.testing.expectEqual(U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 1), r_sub_swap.diff);
    try std.testing.expectEqual(@as(u1, 1), r_sub_swap.borrow);

    // 溢出加法
    const max = U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
    const one = U128.fromU64(1);
    const r_of = max.add(one);
    try std.testing.expectEqual(U128.zero(), r_of.sum);
    try std.testing.expectEqual(@as(u1, 1), r_of.carry);
}

test "U128.clz" {
    try std.testing.expectEqual(@as(u8, 128), U128.zero().clz());
    try std.testing.expectEqual(@as(u8, 127), U128.fromU64(1).clz());
    try std.testing.expectEqual(@as(u8, 127), U128.fromU64Pair(0, 1).clz()); // 值 = 1，127 个前导零
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
    // 0xFF >> 4 with sticky: lost = 0xF, result = 0xF | 1 = 0xF
    const a = U128.fromU64(0xFF);
    try std.testing.expectEqual(U128.fromU64(0xF), a.shiftRightWithSticky(4));

    // 0x10 >> 4: lost = 0, result = 1
    const b = U128.fromU64(0x10);
    try std.testing.expectEqual(U128.fromU64(1), b.shiftRightWithSticky(4));

    // 0x11 >> 4: lost = 1, result = 1 | 1 = 1
    const c = U128.fromU64(0x11);
    try std.testing.expectEqual(U128.fromU64(1), c.shiftRightWithSticky(4));

    // shift >= 128
    try std.testing.expectEqual(U128.fromU64(1), U128.fromU64(1).shiftRightWithSticky(128));
    try std.testing.expectEqual(U128.zero(), U128.zero().shiftRightWithSticky(128));
}

test "U128.multiply" {
    // 0 * 0 = 0
    try std.testing.expect(U128.zero().multiply(U128.zero()).isZero());

    // 2^64 * 2^64 = 2^128
    const a = U128.fromU64Pair(1, 0);
    const r1 = a.multiply(a);
    try std.testing.expectEqual(U128.zero(), r1.lo);
    try std.testing.expectEqual(U128.fromU64(1), r1.hi);

    // (2^64 - 1)^2 = 2^128 - 2^65 + 1
    const b = U128.fromU64(0xFFFFFFFFFFFFFFFF);
    const r2 = b.multiply(b);
    // lo = 1, hi.lo = 0xFFFFFFFFFFFFFFFE, hi.hi = 0
    try std.testing.expectEqual(@as(u64, 1), r2.lo.lo);
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), r2.lo.hi);
    try std.testing.expectEqual(@as(u64, 0), r2.hi.lo);
    try std.testing.expectEqual(@as(u64, 0), r2.hi.hi);
}

test "U256.divideByU128" {
    // 256 / 1 = 256 (fits in 128 bits)
    const dividend = U256.fromU128(U128.fromU64(256));
    const divisor = U128.fromU64(1);
    const r = dividend.divideByU128(divisor);
    try std.testing.expectEqual(U128.fromU64(256), r.quotient);
    try std.testing.expectEqual(U128.zero(), r.remainder);

    // 256 % 7 = 4, 256 / 7 = 36
    const r2 = U256.fromU128(U128.fromU64(256)).divideByU128(U128.fromU64(7));
    try std.testing.expectEqual(U128.fromU64(36), r2.quotient);
    try std.testing.expectEqual(U128.fromU64(4), r2.remainder);

    // 2^128 / 2^64 = 2^64
    const r3 = U256.fromU128(U128.fromU64Pair(1, 0)).divideByU128(U128.fromU64(0x100000000));
    try std.testing.expectEqual(U128.fromU64(0x100000000), r3.quotient);
    try std.testing.expectEqual(U128.zero(), r3.remainder);
}

test "U256.bit/shiftRight1WithSticky" {
    const a = U256.fromU128(U128.fromU64(0xFF));
    try std.testing.expect(a.bit(0));
    try std.testing.expect(a.bit(7));
    try std.testing.expect(!a.bit(8));

    // 0xFF >> 1 with sticky: lost = 1, result = 0x7F | 1 = 0x7F
    const r = a.shiftRight1WithSticky();
    try std.testing.expectEqual(@as(u64, 0x7F), r.lo.lo);
}

test "U128.mask edge cases" {
    // width=0 → 全零
    try std.testing.expect(U128.mask(0).isZero());
    // width=1 → 仅 bit0
    try std.testing.expectEqual(U128.fromU64(1), U128.mask(1));
    // width=63
    try std.testing.expectEqual(U128.fromU64(0x7FFFFFFFFFFFFFFF), U128.mask(63));
    // width=64 → 低 64 位全 1（曾因 1<<64 溢出崩溃）
    try std.testing.expectEqual(U128.fromU64(0xFFFFFFFFFFFFFFFF), U128.mask(64));
    // width=65 → lo 全 1, hi=1
    try std.testing.expectEqual(U128.fromU64Pair(1, 0xFFFFFFFFFFFFFFFF), U128.mask(65));
    // width=127
    try std.testing.expectEqual(U128.fromU64Pair(0x7FFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF), U128.mask(127));
    // width=128 → 全 1
    try std.testing.expectEqual(U128.fromU64Pair(0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF), U128.mask(128));
}

test "U128.shiftLeftWide" {
    // 0 << 0 = 0
    try std.testing.expect(U128.zero().shiftLeftWide(0).isZero());

    // shiftLeftWide(0) = U256{lo: self, hi: 0}
    const a = U128.fromU64(0xFF);
    const r0 = a.shiftLeftWide(0);
    try std.testing.expectEqual(a, r0.lo);
    try std.testing.expect(r0.hi.isZero());

    // shiftLeftWide(64): 0xFF << 64 → bits 落在 lo.hi，hi=0
    const r64 = a.shiftLeftWide(64);
    try std.testing.expectEqual(U128.fromU64Pair(0xFF, 0), r64.lo);
    try std.testing.expect(r64.hi.isZero());

    // shiftLeftWide(128): 全部位移到 hi
    const r128 = a.shiftLeftWide(128);
    try std.testing.expectEqual(U128.zero(), r128.lo);
    try std.testing.expectEqual(a, r128.hi);

    // shiftLeftWide(70): bits 70-77 落在 lo.hi，hi=0
    const r70 = a.shiftLeftWide(70);
    try std.testing.expectEqual(U128.fromU64Pair(0xFF << 6, 0), r70.lo);
    try std.testing.expect(r70.hi.isZero());
}

test "U256.extractU128" {
    // 从 0x_FF_FF (256 位，hi=0xFF, lo=0xFF) 提取
    const v = U256{ .hi = U128.fromU64(0xFF), .lo = U128.fromU64(0xFF) };

    // start=0 → lo
    try std.testing.expectEqual(U128.fromU64(0xFF), v.extractU128(0));
    // start=128 → hi
    try std.testing.expectEqual(U128.fromU64(0xFF), v.extractU128(128));
    // start=64 → (lo >> 64) | (hi << 64) = 0 | 0xFF << 64
    const r64 = v.extractU128(64);
    try std.testing.expectEqual(U128.fromU64Pair(0xFF, 0), r64);
}
