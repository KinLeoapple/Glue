//! 自定义整数类型——Type 枚举 + Int 结构体
//!
//! 存储布局：{type: Type, lo: u64, hi: u64}
//! - ≤64 位类型（i8..i64, u8..u64）：lo 持符号/零扩展后的值，hi = 0
//! - 128 位类型（i128, u128）：{lo, hi} 作为 U128（小端：lo = 低 64 位，hi = 高 64 位）
//!
//! 核心优化：≤64 位算术直接用原生 u64 wrapping 指令（@addWithOverflow 等），
//! 绕过旧的 [16]u8 字节缓冲 + loadWord/storeWord 字节拼装开销。
//! 128 位算术委托给 wide.zig 的 U128 软件实现。
//!
//! 不变量：构造后 lo 始终保持正确的符号/零扩展。算术结果通过 canonicalize() 重新规范化。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const wide = @import("wide.zig");
const U128 = wide.U128;
const mulU64ToU128 = wide.mulU64ToU128;

/// 整数类型枚举：10 个变体
pub const Type = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,

    /// i* → true, u* → false
    pub fn isSigned(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            .u8, .u16, .u32, .u64, .u128 => false,
        };
    }

    /// i8/u8 → 1, i16/u16 → 2, ..., i128/u128 → 16
    pub fn byteLength(self: Type) u8 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32 => 4,
            .i64, .u64 => 8,
            .i128, .u128 => 16,
        };
    }

    /// i8 → 8, ..., i128 → 128
    pub fn bitWidth(self: Type) u8 {
        return switch (self) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64 => 64,
            .i128, .u128 => 128,
        };
    }

    /// 检查 u128 位表示是否落在 self 类型的表示范围内
    /// 对有符号类型：把 val 解析为 i128，检查在 [minInt, maxInt] 内
    /// 对无符号类型：检查 val <= maxInt
    pub fn inRange(self: Type, val: u128) bool {
        return switch (self) {
            inline .i8, .i16, .i32, .i64, .i128 => |tag| {
                const signed_val: i128 = @bitCast(val);
                const signed_min: i128 = switch (tag) {
                    .i8 => std.math.minInt(i8),
                    .i16 => std.math.minInt(i16),
                    .i32 => std.math.minInt(i32),
                    .i64 => std.math.minInt(i64),
                    .i128 => std.math.minInt(i128),
                    else => unreachable,
                };
                const signed_max: i128 = switch (tag) {
                    .i8 => std.math.maxInt(i8),
                    .i16 => std.math.maxInt(i16),
                    .i32 => std.math.maxInt(i32),
                    .i64 => std.math.maxInt(i64),
                    .i128 => std.math.maxInt(i128),
                    else => unreachable,
                };
                return signed_val >= signed_min and signed_val <= signed_max;
            },
            inline .u8, .u16, .u32, .u64, .u128 => |tag| {
                const unsigned_max: u128 = switch (tag) {
                    .u8 => std.math.maxInt(u8),
                    .u16 => std.math.maxInt(u16),
                    .u32 => std.math.maxInt(u32),
                    .u64 => std.math.maxInt(u64),
                    .u128 => std.math.maxInt(u128),
                    else => unreachable,
                };
                return val <= unsigned_max;
            },
        };
    }

    /// 字节级范围检查：16 字节缓冲（已符号/零扩展）是否落在 self 类型范围内。
    /// 不依赖 Zig 128 位类型，纯字节比较。
    /// 有符号类型：高位填充字节必须与符号扩展一致（负数 0xFF / 正数 0x00）。
    /// 无符号类型：高位填充字节必须全为 0x00（值非负且不超出 n 字节表示范围）。
    pub fn inRangeBytes(self: Type, buf: *const [16]u8) bool {
        const n = self.byteLength();
        if (self.isSigned()) {
            const sign_byte: u8 = if ((buf[n - 1] & 0x80) != 0) 0xFF else 0x00;
            for (buf[n..16]) |b| {
                if (b != sign_byte) return false;
            }
        } else {
            for (buf[n..16]) |b| {
                if (b != 0x00) return false;
            }
        }
        return true;
    }

    /// 从类型名构造（"i8"/"i16"/.../"u128"），不匹配返回 null
    pub fn fromName(name: []const u8) ?Type {
        if (std.mem.eql(u8, name, "i8")) return .i8;
        if (std.mem.eql(u8, name, "i16")) return .i16;
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i64")) return .i64;
        if (std.mem.eql(u8, name, "i128")) return .i128;
        if (std.mem.eql(u8, name, "u8")) return .u8;
        if (std.mem.eql(u8, name, "u16")) return .u16;
        if (std.mem.eql(u8, name, "u32")) return .u32;
        if (std.mem.eql(u8, name, "u64")) return .u64;
        if (std.mem.eql(u8, name, "u128")) return .u128;
        return null;
    }
};

/// 加减乘结果（命名结构体，避免各函数匿名结构体类型不匹配）
pub const OverflowResult = struct { result: Int, overflow: bool };

/// 除法结果（命名结构体，避免各函数匿名结构体类型不匹配）
pub const DivModResult = struct { quotient: Int, remainder: Int };

/// 将 lo 重新规范化为类型 t 的正确符号/零扩展表示。
/// ≤64 位类型：截断到类型位宽，然后符号/零扩展到 u64。
/// 128 位类型：无操作（lo 是完整的 u64）。
inline fn canonicalize(lo: u64, t: Type) u64 {
    return switch (t) {
        .i8 => signExtend(lo, 8),
        .i16 => signExtend(lo, 16),
        .i32 => signExtend(lo, 32),
        .i64 => lo,
        .i128 => lo,
        .u8 => @as(u64, @as(u8, @truncate(lo))),
        .u16 => @as(u64, @as(u16, @truncate(lo))),
        .u32 => @as(u64, @as(u32, @truncate(lo))),
        .u64 => lo,
        .u128 => lo,
    };
}

/// 将 lo 的低 `bits` 位符号扩展到 u64。
/// 原理：左移 (64-bits) 使符号位到 bit63，转 i64 后算术右移回原位置，自动填充符号位。
inline fn signExtend(lo: u64, bits: u8) u64 {
    const shift_u8: u8 = 64 - bits;
    const shift: u6 = @intCast(shift_u8);
    const shifted: u64 = lo << shift;
    const signed: i64 = @bitCast(shifted);
    const extended: i64 = signed >> shift;
    return @bitCast(extended);
}

/// 单一 Int 结构体：type + {lo, hi} + 运算方法
pub const Int = struct {
    type: Type,
    lo: u64,
    hi: u64,

    /// 全零值
    pub inline fn zero(t: Type) Int {
        return .{ .type = t, .lo = 0, .hi = 0 };
    }

    /// 从原生值构造（≤64 位用 comptime 分支按 v 的符号性取位模式，再 canonicalize 规范化）
    /// 要求 @sizeOf(@TypeOf(v)) >= t.byteLength()
    pub fn fromNative(t: Type, v: anytype) Int {
        const nbytes = t.byteLength();
        if (nbytes <= 8) {
            // comptime 分支按 v 自身的符号性取位模式，避免 @as 跨符号性失败
            const V = @TypeOf(v);
            const v_signed = @typeInfo(V) == .int and @typeInfo(V).int.signedness == .signed;
            const lo: u64 = if (v_signed)
                @bitCast(@as(i64, @intCast(v)))
            else
                @as(u64, @intCast(v));
            return .{ .type = t, .lo = canonicalize(lo, t), .hi = 0 };
        } else {
            // 128 位：memcpy 避免 LLVM i128 codegen bug
            var result: Int = .{ .type = t, .lo = 0, .hi = 0 };
            const src: [*]const u8 = @ptrCast(&v);
            @memcpy(@as([*]u8, @ptrCast(&result.lo))[0..8], src[0..8]);
            @memcpy(@as([*]u8, @ptrCast(&result.hi))[0..8], src[8..16]);
            return result;
        }
    }

    /// 从 U128 构造（截取低 t.byteLength() 字节，≤64 位规范化）
    /// 供 Float.toInt 使用，绕过 u128 形参的 IO 边界例外
    pub fn fromU128Unchecked(t: Type, val: U128) Int {
        if (t.byteLength() <= 8) {
            return .{ .type = t, .lo = canonicalize(val.lo, t), .hi = 0 };
        }
        return .{ .type = t, .lo = val.lo, .hi = val.hi };
    }

    /// 转为原生值（≤64 位截断 lo 到 T 位宽，128 位 memcpy）
    pub fn toNative(self: Int, comptime T: type) T {
        const sz = @sizeOf(T);
        if (sz <= 8) {
            // ≤64 位：lo 已符号/零扩展，截断到 T 的无符号等价再 @bitCast 回 T
            const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
            const truncated: UT = @truncate(self.lo);
            return @bitCast(truncated);
        } else {
            // 128 位：memcpy
            var result: T = undefined;
            const dst: [*]u8 = @ptrCast(&result);
            @memcpy(dst[0..8], @as([*]const u8, @ptrCast(&self.lo))[0..8]);
            @memcpy(dst[8..16], @as([*]const u8, @ptrCast(&self.hi))[0..8]);
            return result;
        }
    }

    /// 写入 16 字节小端缓冲区（符号/零扩展填满 16 字节）。
    /// 供 coerceTo / 外部字节级代码使用。
    pub fn toBytes(self: Int, buf: *[16]u8) void {
        const n = self.type.byteLength();
        if (n <= 8) {
            // ≤64 位：写 lo 到前 8 字节，符号/零扩展填满 16 字节
            std.mem.writeInt(u64, buf[0..8], self.lo, .little);
            const fill: u8 = if (self.type.isSigned() and (self.lo >> 63) & 1 == 1) 0xFF else 0x00;
            @memset(buf[8..16], fill);
        } else {
            // 128 位：lo → [0..8], hi → [8..16]
            std.mem.writeInt(u64, buf[0..8], self.lo, .little);
            std.mem.writeInt(u64, buf[8..16], self.hi, .little);
        }
    }

    /// 从 16 字节小端缓冲区构造（≤64 位规范化，保证不变量）
    pub fn fromBytes(t: Type, buf: *const [16]u8) Int {
        const lo = std.mem.readInt(u64, buf[0..8], .little);
        const hi = std.mem.readInt(u64, buf[8..16], .little);
        if (t.byteLength() <= 8) {
            return .{ .type = t, .lo = canonicalize(lo, t), .hi = 0 };
        }
        return .{ .type = t, .lo = lo, .hi = hi };
    }

    /// 比较两个 Int（要求 self.type == other.type）
    pub inline fn compare(self: Int, other: Int) std.math.Order {
        const t = self.type;
        const signed = t.isSigned();
        if (t.byteLength() <= 8) {
            if (signed) {
                const a: i64 = @bitCast(self.lo);
                const b: i64 = @bitCast(other.lo);
                if (a < b) return .lt;
                if (a > b) return .gt;
                return .eq;
            } else {
                if (self.lo < other.lo) return .lt;
                if (self.lo > other.lo) return .gt;
                return .eq;
            }
        } else {
            const av = U128{ .hi = self.hi, .lo = self.lo };
            const bv = U128{ .hi = other.hi, .lo = other.lo };
            if (signed) {
                const a_neg = (self.hi >> 63) != 0;
                const b_neg = (other.hi >> 63) != 0;
                if (a_neg != b_neg) return if (a_neg) .lt else .gt;
            }
            return av.compare(bv);
        }
    }

    // —— 算术 ——

    /// 加法。要求 self.type == other.type，结果 type 同。
    pub inline fn add(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return addPortable(self, other);
    }

    inline fn addPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;
        const signed = t.isSigned();

        if (t.byteLength() <= 8) {
            const sum, const carry = @addWithOverflow(self.lo, other.lo);
            const canon = canonicalize(sum, t);
            const sign_sh: u6 = @intCast(t.bitWidth() - 1);
            var overflow: bool = undefined;
            if (signed) {
                const a_sign = (self.lo >> sign_sh) & 1;
                const b_sign = (other.lo >> sign_sh) & 1;
                const r_sign = (canon >> sign_sh) & 1;
                overflow = (a_sign == b_sign) and (r_sign != a_sign);
            } else {
                // u64 carry 检测 u64 溢出；sum != canon 检测 u8/u16/u32 截断溢出
                overflow = (carry != 0) or (sum != canon);
            }
            return .{ .result = .{ .type = t, .lo = canon, .hi = 0 }, .overflow = overflow };
        } else {
            const av = U128{ .hi = self.hi, .lo = self.lo };
            const bv = U128{ .hi = other.hi, .lo = other.lo };
            const result = av.add(bv);
            var overflow: bool = undefined;
            if (signed) {
                const a_sign = (self.hi >> 63) & 1;
                const b_sign = (other.hi >> 63) & 1;
                const r_sign = (result.sum.hi >> 63) & 1;
                overflow = (a_sign == b_sign) and (r_sign != a_sign);
            } else {
                overflow = result.carry != 0;
            }
            return .{ .result = .{ .type = t, .lo = result.sum.lo, .hi = result.sum.hi }, .overflow = overflow };
        }
    }

    /// 减法。要求 self.type == other.type，结果 type 同。
    pub inline fn subtract(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return subtractPortable(self, other);
    }

    inline fn subtractPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;
        const signed = t.isSigned();

        if (t.byteLength() <= 8) {
            const diff, const borrow = @subWithOverflow(self.lo, other.lo);
            const canon = canonicalize(diff, t);
            const sign_sh: u6 = @intCast(t.bitWidth() - 1);
            var overflow: bool = undefined;
            if (signed) {
                const a_sign = (self.lo >> sign_sh) & 1;
                const b_sign = (other.lo >> sign_sh) & 1;
                const r_sign = (canon >> sign_sh) & 1;
                overflow = (a_sign != b_sign) and (r_sign != a_sign);
            } else {
                overflow = borrow != 0;
            }
            return .{ .result = .{ .type = t, .lo = canon, .hi = 0 }, .overflow = overflow };
        } else {
            const av = U128{ .hi = self.hi, .lo = self.lo };
            const bv = U128{ .hi = other.hi, .lo = other.lo };
            const result = av.sub(bv);
            var overflow: bool = undefined;
            if (signed) {
                const a_sign = (self.hi >> 63) & 1;
                const b_sign = (other.hi >> 63) & 1;
                const r_sign = (result.diff.hi >> 63) & 1;
                overflow = (a_sign != b_sign) and (r_sign != a_sign);
            } else {
                overflow = result.borrow != 0;
            }
            return .{ .result = .{ .type = t, .lo = result.diff.lo, .hi = result.diff.hi }, .overflow = overflow };
        }
    }

    /// 是否为负数（无符号类型恒为 false）
    pub inline fn isNegative(self: Int) bool {
        if (!self.type.isSigned()) return false;
        if (self.type.byteLength() <= 8) {
            const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
            return (self.lo >> sign_sh) & 1 == 1;
        }
        return (self.hi >> 63) & 1 == 1;
    }

    /// 取负（补码取反加一）。minInt 取负溢出返回自身（two's complement 回绕）。
    pub inline fn negate(self: Int) Int {
        const t = self.type;
        if (t.byteLength() <= 8) {
            // 0 -% lo：wrapping subtract 实现两补取负
            return .{ .type = t, .lo = canonicalize(0 -% self.lo, t), .hi = 0 };
        }
        const av = U128{ .hi = self.hi, .lo = self.lo };
        const neg = av.negate();
        return .{ .type = t, .lo = neg.lo, .hi = neg.hi };
    }

    /// 乘法。要求 self.type == other.type，结果 type 同。
    pub fn multiply(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return multiplyPortable(self, other);
    }

    fn multiplyPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;

        // ≤64 位：用 inline for 展开各原生类型，entry.T 为 comptime 已知类型
        const Entry = struct { t: Type, T: type, signed: bool };
        const entries = [_]Entry{
            .{ .t = .i8, .T = i8, .signed = true },
            .{ .t = .i16, .T = i16, .signed = true },
            .{ .t = .i32, .T = i32, .signed = true },
            .{ .t = .i64, .T = i64, .signed = true },
            .{ .t = .u8, .T = u8, .signed = false },
            .{ .t = .u16, .T = u16, .signed = false },
            .{ .t = .u32, .T = u32, .signed = false },
            .{ .t = .u64, .T = u64, .signed = false },
        };
        inline for (entries) |entry| {
            if (t == entry.t) {
                const UT = std.meta.Int(.unsigned, @bitSizeOf(entry.T));
                const a: entry.T = @bitCast(@as(UT, @truncate(self.lo)));
                const b: entry.T = @bitCast(@as(UT, @truncate(other.lo)));
                const prod, const ovf = @mulWithOverflow(a, b);
                const lo: u64 = if (entry.signed) @bitCast(@as(i64, prod)) else @as(u64, prod);
                return .{ .result = .{ .type = t, .lo = lo, .hi = 0 }, .overflow = ovf != 0 };
            }
        }

        // 128 位：U128 路径
        if (t == .i128) {
            const av = U128{ .hi = self.hi, .lo = self.lo };
            const bv = U128{ .hi = other.hi, .lo = other.lo };
            const a_neg = (self.hi >> 63) != 0;
            const b_neg = (other.hi >> 63) != 0;
            const result_neg = a_neg != b_neg;

            const abs_a = if (a_neg) av.negate() else av;
            const abs_b = if (b_neg) bv.negate() else bv;
            const product: wide.U256 = abs_a.multiply(abs_b);

            // 溢出判定：bit 127 of product (256-bit)
            const bit_127_set = (product.lo.hi >> 63) != 0;
            const lower_nonzero = (product.lo.hi & 0x7FFFFFFFFFFFFFFF) != 0 or product.lo.lo != 0;

            const overflow = if (result_neg)
                bit_127_set and lower_nonzero
            else
                bit_127_set;

            const final = if (result_neg) product.lo.negate() else product.lo;
            return .{ .result = .{ .type = t, .lo = final.lo, .hi = final.hi }, .overflow = overflow };
        }

        // u128
        const av = U128{ .hi = self.hi, .lo = self.lo };
        const bv = U128{ .hi = other.hi, .lo = other.lo };
        const product: wide.U256 = av.multiply(bv);
        const overflow = !product.hi.isZero();
        return .{ .result = .{ .type = t, .lo = product.lo.lo, .hi = product.lo.hi }, .overflow = overflow };
    }

    /// 截断除法（商向零取整，余数符号同被除数）。
    /// 除零 → error.DivideByZero。minInt / -1 → 回绕返回 minInt（与 Zig @divTrunc 一致）。
    pub fn divideTruncating(self: Int, other: Int) error{DivideByZero}!Int {
        const r = try self.divideWithRemainder(other);
        return r.quotient;
    }

    /// 截断除法的余数（符号同被除数）。除零 → error.DivideByZero。
    /// minInt % -1 → 0（与 Zig @mod 一致）。
    pub fn remainder(self: Int, other: Int) error{DivideByZero}!Int {
        const r = try self.divideWithRemainder(other);
        return r.remainder;
    }

    /// 内部：同时返回 quotient 和 remainder。
    /// minInt/-1 和除零在分派前统一拦截（≤64位 idiv 会 #DE）。
    fn divideWithRemainder(self: Int, other: Int) error{DivideByZero}!DivModResult {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const signed = t.isSigned();

        // 除零检测
        if (other.lo == 0 and (t.byteLength() > 8) and other.hi == 0) return error.DivideByZero;
        if (t.byteLength() <= 8 and other.lo == 0) return error.DivideByZero;

        // minInt / -1 边界：返回 minInt（商），0（余数）
        if (signed) {
            const is_min_int = if (t.byteLength() <= 8) blk: {
                const sign_sh: u6 = @intCast(t.bitWidth() - 1);
                // minInt: sign bit set, all others 0
                const min_lo: u64 = @as(u64, 1) << sign_sh;
                break :blk self.lo == min_lo;
            } else blk: {
                break :blk self.hi == 0x8000000000000000 and self.lo == 0;
            };
            const is_neg_one = if (t.byteLength() <= 8) blk: {
                const sign_sh: u6 = @intCast(t.bitWidth() - 1);
                const neg_one: u64 = ~@as(u64, 0) << sign_sh | ((@as(u64, 1) << sign_sh) - 1);
                break :blk other.lo == neg_one and other.hi == 0;
            } else blk: {
                break :blk other.lo == ~@as(u64, 0) and other.hi == ~@as(u64, 0);
            };
            if (is_min_int and is_neg_one) {
                return .{ .quotient = self, .remainder = Int.zero(t) };
            }
        }

        return divideWithRemainderPortable(self, other);
    }

    fn divideWithRemainderPortable(self: Int, other: Int) DivModResult {
        const t = self.type;

        // ≤64 位：用 inline for 展开各原生类型
        const Entry = struct { t: Type, T: type, signed: bool };
        const entries = [_]Entry{
            .{ .t = .i8, .T = i8, .signed = true },
            .{ .t = .i16, .T = i16, .signed = true },
            .{ .t = .i32, .T = i32, .signed = true },
            .{ .t = .i64, .T = i64, .signed = true },
            .{ .t = .u8, .T = u8, .signed = false },
            .{ .t = .u16, .T = u16, .signed = false },
            .{ .t = .u32, .T = u32, .signed = false },
            .{ .t = .u64, .T = u64, .signed = false },
        };
        inline for (entries) |entry| {
            if (t == entry.t) {
                const UT = std.meta.Int(.unsigned, @bitSizeOf(entry.T));
                const a: entry.T = @bitCast(@as(UT, @truncate(self.lo)));
                const b: entry.T = @bitCast(@as(UT, @truncate(other.lo)));
                if (entry.signed) {
                    const q = @divTrunc(a, b);
                    const r = @rem(a, b);
                    return .{
                        .quotient = .{ .type = t, .lo = @bitCast(@as(i64, q)), .hi = 0 },
                        .remainder = .{ .type = t, .lo = @bitCast(@as(i64, r)), .hi = 0 },
                    };
                } else {
                    const q = a / b;
                    const r = a % b;
                    return .{
                        .quotient = .{ .type = t, .lo = @as(u64, q), .hi = 0 },
                        .remainder = .{ .type = t, .lo = @as(u64, r), .hi = 0 },
                    };
                }
            }
        }

        // 128 位：U128 路径
        if (t == .i128) {
            const av = U128{ .hi = self.hi, .lo = self.lo };
            const bv = U128{ .hi = other.hi, .lo = other.lo };
            const a_neg = (self.hi >> 63) != 0;
            const b_neg = (other.hi >> 63) != 0;
            const q_neg = a_neg != b_neg;
            const r_neg = a_neg;

            const abs_a = if (a_neg) av.negate() else av;
            const abs_b = if (b_neg) bv.negate() else bv;
            const div_result = unsignedDivide128(abs_a, abs_b);
            const final_q = if (q_neg) div_result.quotient.negate() else div_result.quotient;
            const final_r = if (r_neg) div_result.remainder.negate() else div_result.remainder;
            return .{
                .quotient = .{ .type = t, .lo = final_q.lo, .hi = final_q.hi },
                .remainder = .{ .type = t, .lo = final_r.lo, .hi = final_r.hi },
            };
        }

        // u128
        const av = U128{ .hi = self.hi, .lo = self.lo };
        const bv = U128{ .hi = other.hi, .lo = other.lo };
        const div_result = unsignedDivide128(av, bv);
        return .{
            .quotient = .{ .type = t, .lo = div_result.quotient.lo, .hi = div_result.quotient.hi },
            .remainder = .{ .type = t, .lo = div_result.remainder.lo, .hi = div_result.remainder.hi },
        };
    }

    // —— 位运算 ——

    /// 按位与。要求 self.type == other.type。
    pub fn bitwiseAnd(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        return bitwisePortable(self, other, .and_op);
    }

    /// 按位或。要求 self.type == other.type。
    pub fn bitwiseOr(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        return bitwisePortable(self, other, .or_op);
    }

    /// 按位异或。要求 self.type == other.type。
    pub fn bitwiseXor(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        return bitwisePortable(self, other, .xor_op);
    }

    fn bitwisePortable(self: Int, other: Int, op: BitwiseOp) Int {
        const t = self.type;
        if (t.byteLength() <= 8) {
            const result_lo = switch (op) {
                .and_op => self.lo & other.lo,
                .or_op => self.lo | other.lo,
                .xor_op => self.lo ^ other.lo,
            };
            return .{ .type = t, .lo = canonicalize(result_lo, t), .hi = 0 };
        }
        const result = switch (op) {
            .and_op => U128{ .hi = self.hi & other.hi, .lo = self.lo & other.lo },
            .or_op => U128{ .hi = self.hi | other.hi, .lo = self.lo | other.lo },
            .xor_op => U128{ .hi = self.hi ^ other.hi, .lo = self.lo ^ other.lo },
        };
        return .{ .type = t, .lo = result.lo, .hi = result.hi };
    }

    /// 按位取反（逐字节 ~）。对有符号类型等价于 -x - 1。
    pub fn bitwiseNot(self: Int) Int {
        const t = self.type;
        if (t.byteLength() <= 8) {
            return .{ .type = t, .lo = canonicalize(~self.lo, t), .hi = 0 };
        }
        return .{ .type = t, .lo = ~self.lo, .hi = ~self.hi };
    }

    /// 逻辑左移 n 位（无符号与有符号语义一致，低位补 0）。
    /// n >= bitWidth 时返回 zero。
    pub fn shiftLeft(self: Int, n: u8) Int {
        const t = self.type;
        const bit_width = t.bitWidth();
        if (n >= bit_width) return Int.zero(t);
        if (t.byteLength() <= 8) {
            const sh: u6 = @intCast(n);
            return .{ .type = t, .lo = canonicalize(self.lo << sh, t), .hi = 0 };
        }
        const av = U128{ .hi = self.hi, .lo = self.lo };
        const result = av.shiftLeft(n);
        return .{ .type = t, .lo = result.lo, .hi = result.hi };
    }

    /// 右移 n 位。无符号类型为逻辑右移（高位补 0）；有符号类型为算术右移（高位补符号位）。
    /// n >= bitWidth 时：无符号返回 zero；有符号返回 0（正数）或 -1（负数）。
    pub fn shiftRight(self: Int, n: u8) Int {
        const t = self.type;
        const signed = t.isSigned();
        const bit_width = t.bitWidth();

        if (n >= bit_width) {
            if (signed) {
                if (t.byteLength() <= 8) {
                    const sign_sh: u6 = @intCast(bit_width - 1);
                    const sign = (self.lo >> sign_sh) & 1;
                    const fill: u64 = if (sign == 1) ~@as(u64, 0) else 0;
                    return .{ .type = t, .lo = canonicalize(fill, t), .hi = 0 };
                }
                if ((self.hi >> 63) & 1 == 1) return .{ .type = t, .lo = ~@as(u64, 0), .hi = ~@as(u64, 0) };
                return Int.zero(t);
            }
            return Int.zero(t);
        }

        if (t.byteLength() <= 8) {
            const sh: u6 = @intCast(n);
            if (signed) {
                const val: i64 = @bitCast(self.lo);
                const shifted: i64 = val >> sh;
                return .{ .type = t, .lo = canonicalize(@bitCast(shifted), t), .hi = 0 };
            }
            return .{ .type = t, .lo = canonicalize(self.lo >> sh, t), .hi = 0 };
        }
        const av = U128{ .hi = self.hi, .lo = self.lo };
        const result = av.shiftRight(n, signed);
        return .{ .type = t, .lo = result.lo, .hi = result.hi };
    }

    /// 类型转换：将 self 转为 target 类型表示。
    /// 同类型直接返回 self；宽化总是成功；窄化仅在值落在目标范围内时成功。
    /// 超出范围返回 null（调用方处理溢出）。
    pub inline fn coerceTo(self: Int, target: Type) ?Int {
        if (self.type == target) return self;
        // 用 toBytes + inRangeBytes 做字节级范围检查（正确处理跨符号情况）
        var buf: [16]u8 = undefined;
        self.toBytes(&buf);
        if (!target.inRangeBytes(&buf)) return null;
        return fromBytes(target, &buf);
    }

    /// 是否为零
    pub inline fn isZero(self: Int) bool {
        if (self.type.byteLength() <= 8) return self.lo == 0;
        return self.lo == 0 and self.hi == 0;
    }

    /// 十进制格式化：将 self 写入 buf，返回写入的切片。
    /// ≤64 位用原生 u64 除以 10；128 位用 U128 除法。
    /// buf 需至少 41 字节（u128 最大 39 位 + 符号 + 空终止余量）。
    pub fn formatDecimal(self: Int, buf: []u8) []const u8 {
        if (self.type.byteLength() <= 8) {
            if (self.lo == 0) {
                buf[0] = '0';
                return buf[0..1];
            }
            var val: u64 = self.lo;
            var negative = false;
            if (self.type.isSigned() and (self.lo >> 63) & 1 == 1) {
                negative = true;
                val = 0 -% val;
            }
            var pos: usize = 0;
            while (val != 0) {
                buf[pos] = '0' + @as(u8, @intCast(val % 10));
                val /= 10;
                pos += 1;
            }
            if (negative) {
                buf[pos] = '-';
                pos += 1;
            }
            std.mem.reverse(u8, buf[0..pos]);
            return buf[0..pos];
        }
        // 128 位
        if (self.lo == 0 and self.hi == 0) {
            buf[0] = '0';
            return buf[0..1];
        }
        var mag = U128{ .hi = self.hi, .lo = self.lo };
        var negative = false;
        if (self.type.isSigned() and (self.hi >> 63) & 1 == 1) {
            negative = true;
            mag = mag.negate();
        }
        const ten = U128.fromU64(10);
        var pos: usize = 0;
        while (!mag.isZero()) {
            const result = unsignedDivide128(mag, ten);
            buf[pos] = '0' + @as(u8, @intCast(result.remainder.lo));
            mag = result.quotient;
            pos += 1;
        }
        if (negative) {
            buf[pos] = '-';
            pos += 1;
        }
        std.mem.reverse(u8, buf[0..pos]);
        return buf[0..pos];
    }
};

/// 位运算种类（命名枚举，供 bitwisePortable 共用）
const BitwiseOp = enum { and_op, or_op, xor_op };

/// 将无符号整数字符串解析为 [16]u8 小端缓冲（软件乘加，不依赖 u128/i128）。
/// 输入：纯数字字符串（已去除符号、进制前缀、类型后缀、下划线）。
/// 返回有效字节数（1-16），溢出（>128 位）或解析失败返回 null。
/// buf 由调用方提供，函数内清零后写入。
pub fn parseUnsignedBytes(buf: *[16]u8, raw: []const u8, base: u8) ?u8 {
    @memset(buf, 0);
    if (raw.len == 0) return null;

    for (raw) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;

        // buf = buf * base + digit（u64 字块乘加）
        var carry: u64 = digit;
        var i: usize = 0;
        while (i < 16) : (i += 8) {
            const word = std.mem.readInt(u64, buf[i..][0..8], .little);
            const product = mulU64ToU128(word, @as(u64, base));
            const sum_lo, const c1 = @addWithOverflow(product.lo, carry);
            std.mem.writeInt(u64, buf[i..][0..8], sum_lo, .little);
            carry = product.hi +% c1;
        }
        if (carry != 0) return null; // 超出 128 位
    }

    // 计算有效字节数
    var n: u8 = 16;
    while (n > 1 and buf[n - 1] == 0) n -= 1;
    return n;
}

/// 128/64 无符号除法：(hi:lo) / d → (quot, rem)。
/// 要求 d != 0 且 hi < d（保证商 ≤ u64 最大值）且 hi < 2^32（保证 (hi<<32)|... 不溢出 u64）。
/// 用 2 次原生 u64 除法实现（高 32 位 / 低 32 位 各一次），仅用于 d ≤ 2^32 的快路径。
fn divmod128by64(hi: u64, lo: u64, d: u64) struct { quot: u64, rem: u64 } {
    std.debug.assert(d != 0);
    std.debug.assert(hi < d);
    std.debug.assert(hi < 0x100000000); // hi < 2^32，保证 (hi << 32) | ... 不溢出
    // 高 32 位字块：combined_hi = (hi << 32) | (lo >> 32)，因 hi < 2^32 故 combined_hi < 2^64
    const combined_hi: u64 = (hi << 32) | (lo >> 32);
    const q_hi32: u64 = combined_hi / d;
    const r2: u64 = combined_hi % d;
    // 低 32 位字块：combined_lo = (r2 << 32) | (lo & 0xFFFFFFFF)，因 r2 < d ≤ 2^32 故 r2 < 2^32
    const combined_lo: u64 = (r2 << 32) | (lo & 0xFFFFFFFF);
    const q_lo32: u64 = combined_lo / d;
    const r_final: u64 = combined_lo % d;
    return .{ .quot = (q_hi32 << 32) | q_lo32, .rem = r_final };
}

/// 无符号 128/128 除法：a / b = quotient ... remainder。
/// 三条路径（按除数大小）：
///   1) b.hi != 0（除数 > 64 位）：U128 位级长除法，128 次迭代。
///   2) b.hi == 0 且 d ≤ 2^32：2 次原生 u64 除法（divmod128by64）。最快。
///   3) b.hi == 0 且 d > 2^32：位级长除法（64 次迭代）。约 256 次 u64 操作。
/// 调用方保证 b != 0。
fn unsignedDivide128(a: U128, b: U128) struct { quotient: U128, remainder: U128 } {
    std.debug.assert(!b.isZero());

    // 路径 2/3：除数 fit u64（b.hi == 0）
    if (b.hi == 0) {
        const d: u64 = b.lo;
        const q_hi: u64 = a.hi / d;
        const rem: u64 = a.hi % d; // rem < d

        var q_lo: u64 = 0;
        var r_final: u64 = undefined;
        if (d <= 0x100000000) {
            // 路径 2：d ≤ 2^32，rem < d ≤ 2^32，divmod128by64 前置条件满足
            const result = divmod128by64(rem, a.lo, d);
            q_lo = result.quot;
            r_final = result.rem;
        } else {
            // 路径 3：d > 2^32，rem 可能 ≥ 2^32，位级长除法处理低 64 位（64 次迭代）
            r_final = rem;
            var bit: u8 = 64;
            while (bit > 0) {
                bit -= 1;
                const shift_amt: u6 = @intCast(bit);
                const a_bit: u1 = @truncate((a.lo >> shift_amt) & 1);
                const overflow = (r_final >> 63) != 0;
                r_final = (r_final << 1) | a_bit;
                if (overflow or r_final >= d) {
                    r_final -%= d;
                    q_lo |= (@as(u64, 1) << shift_amt);
                }
            }
        }

        return .{
            .quotient = .{ .lo = q_lo, .hi = q_hi },
            .remainder = .{ .lo = r_final, .hi = 0 },
        };
    }

    // 路径 1：除数 > 64 位 → U128 位级二进制长除法（128 次迭代）
    var rem = U128.zero();
    var quot = U128.zero();
    var bit: u8 = 128;
    while (bit > 0) {
        bit -= 1;
        // rem 左移 1 位，最低位填入 a 的 bit 位
        const a_bit: u1 = if (a.testBit(bit)) 1 else 0;
        const shifted = rem.shiftLeft1WithBit(a_bit);
        rem = shifted.result;
        // 若 rem >= b：rem -= b，quotient 对应位置 1
        if (rem.compare(b) != .lt) {
            const sub_result = rem.sub(b);
            rem = sub_result.diff;
            quot = quot.orBit(bit);
        }
    }
    return .{ .quotient = quot, .remainder = rem };
}

// ============================================================
// 测试
// ============================================================

test "Type.isSigned" {
    try std.testing.expect(Type.i8.isSigned());
    try std.testing.expect(Type.i128.isSigned());
    try std.testing.expect(!Type.u8.isSigned());
    try std.testing.expect(!Type.u128.isSigned());
}

test "Type.byteLength" {
    try std.testing.expectEqual(@as(u8, 1), Type.i8.byteLength());
    try std.testing.expectEqual(@as(u8, 1), Type.u8.byteLength());
    try std.testing.expectEqual(@as(u8, 2), Type.i16.byteLength());
    try std.testing.expectEqual(@as(u8, 4), Type.i32.byteLength());
    try std.testing.expectEqual(@as(u8, 8), Type.i64.byteLength());
    try std.testing.expectEqual(@as(u8, 16), Type.i128.byteLength());
    try std.testing.expectEqual(@as(u8, 16), Type.u128.byteLength());
}

test "Type.bitWidth" {
    try std.testing.expectEqual(@as(u8, 8), Type.i8.bitWidth());
    try std.testing.expectEqual(@as(u8, 128), Type.i128.bitWidth());
    try std.testing.expectEqual(@as(u8, 64), Type.u64.bitWidth());
}

test "Type.inRange" {
    // i8: 范围 [-128, 127]
    try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, 0)))));
    try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, 127)))));
    try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, -128)))));
    try std.testing.expect(!Type.i8.inRange(@as(u128, @bitCast(@as(i128, 128)))));
    try std.testing.expect(!Type.i8.inRange(@as(u128, @bitCast(@as(i128, -129)))));

    // u8: 范围 [0, 255]
    try std.testing.expect(Type.u8.inRange(0));
    try std.testing.expect(Type.u8.inRange(255));
    try std.testing.expect(!Type.u8.inRange(256));

    // i128/u128 边界
    try std.testing.expect(Type.i128.inRange(@as(u128, @bitCast(@as(i128, std.math.maxInt(i128))))));
    try std.testing.expect(Type.i128.inRange(@as(u128, @bitCast(@as(i128, std.math.minInt(i128))))));
    try std.testing.expect(Type.u128.inRange(std.math.maxInt(u128)));
}

test "Type.fromName" {
    try std.testing.expectEqual(@as(?Type, .i8), Type.fromName("i8"));
    try std.testing.expectEqual(@as(?Type, .i128), Type.fromName("i128"));
    try std.testing.expectEqual(@as(?Type, .u64), Type.fromName("u64"));
    try std.testing.expectEqual(@as(?Type, null), Type.fromName("f32"));
    try std.testing.expectEqual(@as(?Type, null), Type.fromName("xyz"));
}

test "Int.fromNative/toNative roundtrip" {
    {
        const cases = [_]i8{ 0, 1, -1, 127, -128 };
        for (cases) |v| {
            const x = Int.fromNative(.i8, @as(i8, v));
            try std.testing.expectEqual(v, x.toNative(i8));
        }
    }
    {
        const cases = [_]i32{ 0, 1, -1, 123456789, -123456789, std.math.maxInt(i32), std.math.minInt(i32) };
        for (cases) |v| {
            const x = Int.fromNative(.i32, @as(i32, v));
            try std.testing.expectEqual(v, x.toNative(i32));
        }
    }
    {
        const cases = [_]i64{ 0, 1, -1, std.math.maxInt(i64), std.math.minInt(i64) };
        for (cases) |v| {
            const x = Int.fromNative(.i64, @as(i64, v));
            try std.testing.expectEqual(v, x.toNative(i64));
        }
    }
    {
        const cases = [_]i128{ 0, 1, -1, std.math.maxInt(i128), std.math.minInt(i128) };
        for (cases) |v| {
            const x = Int.fromNative(.i128, @as(i128, v));
            try std.testing.expectEqual(v, x.toNative(i128));
        }
    }
    try std.testing.expectEqual(@as(u8, 200), Int.fromNative(.u8, @as(u8, 200)).toNative(u8));
    try std.testing.expectEqual(@as(u16, 0xBEEF), Int.fromNative(.u16, @as(u16, 0xBEEF)).toNative(u16));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), Int.fromNative(.u32, @as(u32, 0xDEADBEEF)).toNative(u32));
    try std.testing.expectEqual(std.math.maxInt(u64), Int.fromNative(.u64, @as(u64, std.math.maxInt(u64))).toNative(u64));
    try std.testing.expectEqual(std.math.maxInt(u128), Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).toNative(u128));
}

test "Int.compare" {
    // i32 同号正数
    try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, 5)).compare(Int.fromNative(.i32, @as(i32, 3))));
    try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, 3)).compare(Int.fromNative(.i32, @as(i32, 5))));
    try std.testing.expectEqual(.eq, Int.fromNative(.i32, @as(i32, 5)).compare(Int.fromNative(.i32, @as(i32, 5))));
    // i32 同号负数
    try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, -5)).compare(Int.fromNative(.i32, @as(i32, -3))));
    try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, -3)).compare(Int.fromNative(.i32, @as(i32, -5))));
    try std.testing.expectEqual(.eq, Int.fromNative(.i32, @as(i32, -5)).compare(Int.fromNative(.i32, @as(i32, -5))));
    // i32 异号
    try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, -1)).compare(Int.fromNative(.i32, @as(i32, 1))));
    try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, 1)).compare(Int.fromNative(.i32, @as(i32, -1))));
    // i8 边界
    try std.testing.expectEqual(.lt, Int.fromNative(.i8, @as(i8, std.math.minInt(i8))).compare(Int.fromNative(.i8, @as(i8, std.math.maxInt(i8)))));
    try std.testing.expectEqual(.gt, Int.fromNative(.i8, @as(i8, std.math.maxInt(i8))).compare(Int.fromNative(.i8, @as(i8, std.math.minInt(i8)))));
    // u32 无符号
    try std.testing.expectEqual(.lt, Int.fromNative(.u32, @as(u32, 3)).compare(Int.fromNative(.u32, @as(u32, 5))));
    try std.testing.expectEqual(.gt, Int.fromNative(.u32, @as(u32, 0xFFFFFFFF)).compare(Int.fromNative(.u32, @as(u32, 0))));
    // i64 / i128 边界
    try std.testing.expectEqual(.lt, Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).compare(Int.fromNative(.i64, @as(i64, std.math.maxInt(i64)))));
    try std.testing.expectEqual(.lt, Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).compare(Int.fromNative(.i128, @as(i128, std.math.maxInt(i128)))));
}

test "Int.zero" {
    try std.testing.expectEqual(.eq, Int.zero(.i8).compare(Int.fromNative(.i8, @as(i8, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.i16).compare(Int.fromNative(.i16, @as(i16, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.i32).compare(Int.fromNative(.i32, @as(i32, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.i64).compare(Int.fromNative(.i64, @as(i64, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.i128).compare(Int.fromNative(.i128, @as(i128, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.u8).compare(Int.fromNative(.u8, @as(u8, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.u32).compare(Int.fromNative(.u32, @as(u32, 0))));
    try std.testing.expectEqual(.eq, Int.zero(.u128).compare(Int.fromNative(.u128, @as(u128, 0))));
}

test "Int.toBytes/fromBytes roundtrip" {
    // i32 -1：符号扩展填满 0xFF
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.i32, @as(i32, -1));
        v.toBytes(&buf);
        try std.testing.expectEqual(@as(u8, 4), v.type.byteLength());
        for (buf) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);
        const back = Int.fromBytes(.i32, &buf);
        try std.testing.expectEqual(.eq, v.compare(back));
    }
    // u32 0xDEADBEEF：零扩展填满 0x00
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.u32, @as(u32, 0xDEADBEEF));
        v.toBytes(&buf);
        try std.testing.expectEqual(@as(u8, 4), v.type.byteLength());
        try std.testing.expectEqual(@as(u8, 0xEF), buf[0]);
        try std.testing.expectEqual(@as(u8, 0xBE), buf[1]);
        try std.testing.expectEqual(@as(u8, 0xAD), buf[2]);
        try std.testing.expectEqual(@as(u8, 0xDE), buf[3]);
        for (buf[4..16]) |b| try std.testing.expectEqual(@as(u8, 0x00), b);
        const back = Int.fromBytes(.u32, &buf);
        try std.testing.expectEqual(.eq, v.compare(back));
    }
    // i128 边界：16 字节无填充
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        v.toBytes(&buf);
        try std.testing.expectEqual(@as(u8, 16), v.type.byteLength());
        // minInt(i128)：低 15 字节 0x00，高字节 0x80
        for (buf[0..15]) |b| try std.testing.expectEqual(@as(u8, 0x00), b);
        try std.testing.expectEqual(@as(u8, 0x80), buf[15]);
        const back = Int.fromBytes(.i128, &buf);
        try std.testing.expectEqual(.eq, v.compare(back));
    }
}

test "Int.add matches native @addWithOverflow" {
    const i8_cases = [_]i8{ 0, 1, -1, 50, -50, 100, -100, 127, -128 };
    for (i8_cases) |av| {
        for (i8_cases) |bv| {
            const a = Int.fromNative(.i8, @as(i8, av));
            const b = Int.fromNative(.i8, @as(i8, bv));
            const r = a.add(b);
            const native_result, const native_ovf = @addWithOverflow(@as(i8, av), @as(i8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(i8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    const u8_cases = [_]u8{ 0, 1, 100, 200, 255 };
    for (u8_cases) |av| {
        for (u8_cases) |bv| {
            const a = Int.fromNative(.u8, @as(u8, av));
            const b = Int.fromNative(.u8, @as(u8, bv));
            const r = a.add(b);
            const native_result, const native_ovf = @addWithOverflow(@as(u8, av), @as(u8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(u8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    // i32 边界
    {
        const a = Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)));
        const r = a.add(Int.fromNative(.i32, @as(i32, 1)));
        const native_result, const native_ovf = @addWithOverflow(@as(i32, std.math.maxInt(i32)), @as(i32, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(i32));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // i64 边界
    {
        const a = Int.fromNative(.i64, @as(i64, std.math.minInt(i64)));
        const r = a.add(Int.fromNative(.i64, @as(i64, -1)));
        const native_result, const native_ovf = @addWithOverflow(@as(i64, std.math.minInt(i64)), @as(i64, -1));
        try std.testing.expectEqual(native_result, r.result.toNative(i64));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // i128 / u128 边界
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.maxInt(i128)));
        const r = a.add(Int.fromNative(.i128, @as(i128, 1)));
        const native_result, const native_ovf = @addWithOverflow(@as(i128, std.math.maxInt(i128)), @as(i128, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(i128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    {
        const a = Int.fromNative(.u128, @as(u128, std.math.maxInt(u128)));
        const r = a.add(Int.fromNative(.u128, @as(u128, 1)));
        const native_result, const native_ovf = @addWithOverflow(@as(u128, std.math.maxInt(u128)), @as(u128, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(u128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
}

test "Int.subtract matches native @subWithOverflow" {
    const i8_cases = [_]i8{ 0, 1, -1, 50, -50, 100, -100, 127, -128 };
    for (i8_cases) |av| {
        for (i8_cases) |bv| {
            const a = Int.fromNative(.i8, @as(i8, av));
            const b = Int.fromNative(.i8, @as(i8, bv));
            const r = a.subtract(b);
            const native_result, const native_ovf = @subWithOverflow(@as(i8, av), @as(i8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(i8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    const u8_cases = [_]u8{ 0, 1, 100, 200, 255 };
    for (u8_cases) |av| {
        for (u8_cases) |bv| {
            const a = Int.fromNative(.u8, @as(u8, av));
            const b = Int.fromNative(.u8, @as(u8, bv));
            const r = a.subtract(b);
            const native_result, const native_ovf = @subWithOverflow(@as(u8, av), @as(u8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(u8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    // i128 边界：minInt - 1 溢出
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const r = a.subtract(Int.fromNative(.i128, @as(i128, 1)));
        const native_result, const native_ovf = @subWithOverflow(@as(i128, std.math.minInt(i128)), @as(i128, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(i128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // u64 边界：0 - 1 借位
    {
        const a = Int.fromNative(.u64, @as(u64, 0));
        const r = a.subtract(Int.fromNative(.u64, @as(u64, 1)));
        const native_result, const native_ovf = @subWithOverflow(@as(u64, 0), @as(u64, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(u64));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
}

test "Int.isNegative" {
    try std.testing.expect(!Int.fromNative(.i8, @as(i8, 5)).isNegative());
    try std.testing.expect(Int.fromNative(.i8, @as(i8, -5)).isNegative());
    try std.testing.expect(!Int.fromNative(.i8, @as(i8, 0)).isNegative());
    try std.testing.expect(Int.fromNative(.i8, @as(i8, std.math.minInt(i8))).isNegative());
    try std.testing.expect(!Int.fromNative(.i8, @as(i8, std.math.maxInt(i8))).isNegative());
    // 无符号恒为 false
    try std.testing.expect(!Int.fromNative(.u8, @as(u8, 255)).isNegative());
    try std.testing.expect(!Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).isNegative());
    // i128 边界
    try std.testing.expect(Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).isNegative());
    try std.testing.expect(!Int.fromNative(.i128, @as(i128, std.math.maxInt(i128))).isNegative());
}

test "Int.negate" {
    try std.testing.expectEqual(@as(i8, -5), Int.fromNative(.i8, @as(i8, 5)).negate().toNative(i8));
    try std.testing.expectEqual(@as(i8, 5), Int.fromNative(.i8, @as(i8, -5)).negate().toNative(i8));
    try std.testing.expectEqual(@as(i8, 0), Int.fromNative(.i8, @as(i8, 0)).negate().toNative(i8));
    // minInt 取负回绕为自身
    try std.testing.expectEqual(std.math.minInt(i8), Int.fromNative(.i8, @as(i8, std.math.minInt(i8))).negate().toNative(i8));
    try std.testing.expectEqual(std.math.minInt(i64), Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).negate().toNative(i64));
    try std.testing.expectEqual(std.math.minInt(i128), Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).negate().toNative(i128));
    // 无符号取负（补码）
    try std.testing.expectEqual(@as(u8, 256 - 5), Int.fromNative(.u8, @as(u8, 5)).negate().toNative(u8));
}

test "Int.multiply matches native @mulWithOverflow" {
    const i8_cases = [_]i8{ 0, 1, -1, 2, -2, 16, -16, 64, -64, 100, -100, 127, -128 };
    for (i8_cases) |av| {
        for (i8_cases) |bv| {
            const a = Int.fromNative(.i8, @as(i8, av));
            const b = Int.fromNative(.i8, @as(i8, bv));
            const r = a.multiply(b);
            const native_result, const native_ovf = @mulWithOverflow(@as(i8, av), @as(i8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(i8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    const u8_cases = [_]u8{ 0, 1, 2, 16, 100, 200, 255 };
    for (u8_cases) |av| {
        for (u8_cases) |bv| {
            const a = Int.fromNative(.u8, @as(u8, av));
            const b = Int.fromNative(.u8, @as(u8, bv));
            const r = a.multiply(b);
            const native_result, const native_ovf = @mulWithOverflow(@as(u8, av), @as(u8, bv));
            try std.testing.expectEqual(native_result, r.result.toNative(u8));
            try std.testing.expectEqual(native_ovf != 0, r.overflow);
        }
    }
    // i32 边界
    {
        const a = Int.fromNative(.i32, @as(i32, 1 << 16));
        const r = a.multiply(Int.fromNative(.i32, @as(i32, 1 << 16)));
        const native_result, const native_ovf = @mulWithOverflow(@as(i32, 1 << 16), @as(i32, 1 << 16));
        try std.testing.expectEqual(native_result, r.result.toNative(i32));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // i64 边界
    {
        const a = Int.fromNative(.i64, @as(i64, std.math.maxInt(i64)));
        const r = a.multiply(Int.fromNative(.i64, @as(i64, 2)));
        const native_result, const native_ovf = @mulWithOverflow(@as(i64, std.math.maxInt(i64)), @as(i64, 2));
        try std.testing.expectEqual(native_result, r.result.toNative(i64));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // i128 边界：minInt * -1 溢出；minInt * 1 不溢出；-1 * -1 = 1
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const r = a.multiply(Int.fromNative(.i128, @as(i128, -1)));
        const native_result, const native_ovf = @mulWithOverflow(@as(i128, std.math.minInt(i128)), @as(i128, -1));
        try std.testing.expectEqual(native_result, r.result.toNative(i128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const r = a.multiply(Int.fromNative(.i128, @as(i128, 1)));
        const native_result, const native_ovf = @mulWithOverflow(@as(i128, std.math.minInt(i128)), @as(i128, 1));
        try std.testing.expectEqual(native_result, r.result.toNative(i128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    {
        const r = Int.fromNative(.i128, @as(i128, -1)).multiply(Int.fromNative(.i128, @as(i128, -1)));
        const native_result, const native_ovf = @mulWithOverflow(@as(i128, -1), @as(i128, -1));
        try std.testing.expectEqual(native_result, r.result.toNative(i128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
    // u128 边界
    {
        const a = Int.fromNative(.u128, @as(u128, std.math.maxInt(u128)));
        const r = a.multiply(Int.fromNative(.u128, @as(u128, 2)));
        const native_result, const native_ovf = @mulWithOverflow(@as(u128, std.math.maxInt(u128)), @as(u128, 2));
        try std.testing.expectEqual(native_result, r.result.toNative(u128));
        try std.testing.expectEqual(native_ovf != 0, r.overflow);
    }
}

test "Int.divideTruncating/remainder match native @divTrunc/@rem" {
    // i8 穷举（跳过 b==0 和 (minInt, -1)：Zig safe 模式 panic）
    const i8_cases = [_]i8{ 0, 1, -1, 2, -2, 5, -5, 50, -50, 100, -100, 127, -128 };
    for (i8_cases) |av| {
        for (i8_cases) |bv| {
            if (bv == 0) continue;
            if (av == std.math.minInt(i8) and bv == -1) continue;
            const a = Int.fromNative(.i8, @as(i8, av));
            const b = Int.fromNative(.i8, @as(i8, bv));
            const q = try a.divideTruncating(b);
            const r = try a.remainder(b);
            try std.testing.expectEqual(@divTrunc(@as(i8, av), @as(i8, bv)), q.toNative(i8));
            try std.testing.expectEqual(@rem(@as(i8, av), @as(i8, bv)), r.toNative(i8));
        }
    }
    // u8 穷举（跳过 b==0）
    const u8_cases = [_]u8{ 0, 1, 2, 16, 100, 200, 255 };
    for (u8_cases) |av| {
        for (u8_cases) |bv| {
            if (bv == 0) continue;
            const a = Int.fromNative(.u8, @as(u8, av));
            const b = Int.fromNative(.u8, @as(u8, bv));
            const q = try a.divideTruncating(b);
            const r = try a.remainder(b);
            try std.testing.expectEqual(@divTrunc(@as(u8, av), @as(u8, bv)), q.toNative(u8));
            try std.testing.expectEqual(@rem(@as(u8, av), @as(u8, bv)), r.toNative(u8));
        }
    }
    // i32 边界
    {
        const a = Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)));
        const q = try a.divideTruncating(Int.fromNative(.i32, @as(i32, 1)));
        const r = try a.remainder(Int.fromNative(.i32, @as(i32, 1)));
        try std.testing.expectEqual(@divTrunc(@as(i32, std.math.maxInt(i32)), @as(i32, 1)), q.toNative(i32));
        try std.testing.expectEqual(@rem(@as(i32, std.math.maxInt(i32)), @as(i32, 1)), r.toNative(i32));
    }
    {
        const a = Int.fromNative(.i32, @as(i32, -123456789));
        const b = Int.fromNative(.i32, @as(i32, 1000));
        const q = try a.divideTruncating(b);
        const r = try a.remainder(b);
        try std.testing.expectEqual(@divTrunc(@as(i32, -123456789), @as(i32, 1000)), q.toNative(i32));
        try std.testing.expectEqual(@rem(@as(i32, -123456789), @as(i32, 1000)), r.toNative(i32));
    }
    // i64 边界：minInt / 1、minInt / -1（回绕）、minInt % -1（=0）
    {
        const a = Int.fromNative(.i64, @as(i64, std.math.minInt(i64)));
        const q1 = try a.divideTruncating(Int.fromNative(.i64, @as(i64, 1)));
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), q1.toNative(i64));
        const q2 = try a.divideTruncating(Int.fromNative(.i64, @as(i64, -1)));
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), q2.toNative(i64));
        const r2 = try a.remainder(Int.fromNative(.i64, @as(i64, -1)));
        try std.testing.expectEqual(@as(i64, 0), r2.toNative(i64));
    }
    // i128 边界：minInt / -1（回绕）、minInt % -1（=0）
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const q = try a.divideTruncating(Int.fromNative(.i128, @as(i128, -1)));
        try std.testing.expectEqual(@as(i128, std.math.minInt(i128)), q.toNative(i128));
        const r = try a.remainder(Int.fromNative(.i128, @as(i128, -1)));
        try std.testing.expectEqual(@as(i128, 0), r.toNative(i128));
    }
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.maxInt(i128)));
        const b = Int.fromNative(.i128, @as(i128, 1 << 60));
        const q = try a.divideTruncating(b);
        const r = try a.remainder(b);
        try std.testing.expectEqual(@divTrunc(@as(i128, std.math.maxInt(i128)), @as(i128, 1 << 60)), q.toNative(i128));
        try std.testing.expectEqual(@rem(@as(i128, std.math.maxInt(i128)), @as(i128, 1 << 60)), r.toNative(i128));
    }
    // u128 边界
    {
        const a = Int.fromNative(.u128, @as(u128, std.math.maxInt(u128)));
        const b = Int.fromNative(.u128, @as(u128, 1 << 100));
        const q = try a.divideTruncating(b);
        const r = try a.remainder(b);
        try std.testing.expectEqual(@divTrunc(@as(u128, std.math.maxInt(u128)), @as(u128, 1 << 100)), q.toNative(u128));
        try std.testing.expectEqual(@rem(@as(u128, std.math.maxInt(u128)), @as(u128, 1 << 100)), r.toNative(u128));
    }
}

test "Int.divideTruncating/remainder divide by zero" {
    try std.testing.expectError(error.DivideByZero, Int.fromNative(.i8, @as(i8, 5)).divideTruncating(Int.fromNative(.i8, @as(i8, 0))));
    try std.testing.expectError(error.DivideByZero, Int.fromNative(.i8, @as(i8, 5)).remainder(Int.fromNative(.i8, @as(i8, 0))));
    try std.testing.expectError(error.DivideByZero, Int.fromNative(.i32, @as(i32, 100)).divideTruncating(Int.fromNative(.i32, @as(i32, 0))));
    try std.testing.expectError(error.DivideByZero, Int.fromNative(.i128, @as(i128, -1)).remainder(Int.fromNative(.i128, @as(i128, 0))));
    try std.testing.expectError(error.DivideByZero, Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).divideTruncating(Int.fromNative(.u128, @as(u128, 0))));
}

test "Int.divideTruncating i128 covers unsignedDivide128 three paths" {
    // 路径 2：除数 fit u64 且 d ≤ 2^32（divmod128by64 2 次原生除法）
    {
        const cases = [_]struct { a: i128, b: i128 }{
            .{ .a = std.math.maxInt(i128), .b = 7 },
            .{ .a = std.math.minInt(i128) + 1, .b = 7 },
            .{ .a = std.math.maxInt(i128), .b = -7 },
            .{ .a = std.math.minInt(i128) + 1, .b = -7 },
            .{ .a = std.math.maxInt(i128), .b = 1 }, // d=1，边界
            .{ .a = std.math.maxInt(i128), .b = 0x100000000 }, // d=2^32，路径 2 上界
        };
        for (cases) |c| {
            const a = Int.fromNative(.i128, @as(i128, c.a));
            const b = Int.fromNative(.i128, @as(i128, c.b));
            const q = try a.divideTruncating(b);
            const r = try a.remainder(b);
            try std.testing.expectEqual(@divTrunc(@as(i128, c.a), @as(i128, c.b)), q.toNative(i128));
            try std.testing.expectEqual(@rem(@as(i128, c.a), @as(i128, c.b)), r.toNative(i128));
        }
    }
    // 路径 3：除数 fit u64 且 d > 2^32（位级长除法 64 次迭代）
    {
        const cases = [_]struct { a: i128, b: i128 }{
            .{ .a = std.math.maxInt(i128), .b = @as(i128, 1) << 60 }, // d=2^60
            .{ .a = std.math.minInt(i128) + 1, .b = @as(i128, 1) << 60 },
            .{ .a = std.math.maxInt(i128), .b = -(@as(i128, 1) << 60) },
            .{ .a = std.math.minInt(i128) + 1, .b = -(@as(i128, 1) << 60) },
            .{ .a = std.math.maxInt(i128), .b = @as(i128, 1) << 33 }, // d=2^33，路径 3 下界
        };
        for (cases) |c| {
            const a = Int.fromNative(.i128, @as(i128, c.a));
            const b = Int.fromNative(.i128, @as(i128, c.b));
            const q = try a.divideTruncating(b);
            const r = try a.remainder(b);
            try std.testing.expectEqual(@divTrunc(@as(i128, c.a), @as(i128, c.b)), q.toNative(i128));
            try std.testing.expectEqual(@rem(@as(i128, c.a), @as(i128, c.b)), r.toNative(i128));
        }
    }
    // 路径 1：除数 > 64 位（U128 位级长除法 128 次迭代）
    {
        const cases = [_]struct { a: u128, b: u128 }{
            .{ .a = std.math.maxInt(u128), .b = @as(u128, 1) << 100 },
            .{ .a = std.math.maxInt(u128), .b = @as(u128, 1) << 127 }, // 仅最高位
            .{ .a = std.math.maxInt(u128), .b = std.math.maxInt(u128) }, // 商=1
            .{ .a = std.math.maxInt(u128) - 1, .b = std.math.maxInt(u128) }, // 商=0
        };
        for (cases) |c| {
            const a = Int.fromNative(.u128, @as(u128, c.a));
            const b = Int.fromNative(.u128, @as(u128, c.b));
            const q = try a.divideTruncating(b);
            const r = try a.remainder(b);
            try std.testing.expectEqual(@divTrunc(@as(u128, c.a), @as(u128, c.b)), q.toNative(u128));
            try std.testing.expectEqual(@rem(@as(u128, c.a), @as(u128, c.b)), r.toNative(u128));
        }
    }
}

test "Int.bitwiseAnd/Or/Xor/Not match native" {
    const i8_cases = [_]i8{ 0, 1, -1, 5, -5, 85, -86, 127, -128 };
    for (i8_cases) |av| {
        for (i8_cases) |bv| {
            const a = Int.fromNative(.i8, @as(i8, av));
            const b = Int.fromNative(.i8, @as(i8, bv));
            try std.testing.expectEqual(@as(i8, av & bv), a.bitwiseAnd(b).toNative(i8));
            try std.testing.expectEqual(@as(i8, av | bv), a.bitwiseOr(b).toNative(i8));
            try std.testing.expectEqual(@as(i8, av ^ bv), a.bitwiseXor(b).toNative(i8));
        }
        try std.testing.expectEqual(~@as(i8, av), Int.fromNative(.i8, @as(i8, av)).bitwiseNot().toNative(i8));
    }
    const u8_cases = [_]u8{ 0, 1, 0x55, 0xAA, 200, 255 };
    for (u8_cases) |av| {
        for (u8_cases) |bv| {
            const a = Int.fromNative(.u8, @as(u8, av));
            const b = Int.fromNative(.u8, @as(u8, bv));
            try std.testing.expectEqual(@as(u8, av & bv), a.bitwiseAnd(b).toNative(u8));
            try std.testing.expectEqual(@as(u8, av | bv), a.bitwiseOr(b).toNative(u8));
            try std.testing.expectEqual(@as(u8, av ^ bv), a.bitwiseXor(b).toNative(u8));
        }
        try std.testing.expectEqual(~@as(u8, av), Int.fromNative(.u8, @as(u8, av)).bitwiseNot().toNative(u8));
    }
    // i128 边界
    {
        const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const b = Int.fromNative(.i128, @as(i128, std.math.maxInt(i128)));
        try std.testing.expectEqual(@as(i128, std.math.minInt(i128) & std.math.maxInt(i128)), a.bitwiseAnd(b).toNative(i128));
        try std.testing.expectEqual(@as(i128, std.math.minInt(i128) | std.math.maxInt(i128)), a.bitwiseOr(b).toNative(i128));
        try std.testing.expectEqual(@as(i128, std.math.minInt(i128) ^ std.math.maxInt(i128)), a.bitwiseXor(b).toNative(i128));
        try std.testing.expectEqual(~@as(i128, std.math.minInt(i128)), a.bitwiseNot().toNative(i128));
    }
}

test "Int.shiftLeft matches native <<" {
    const i8_cases = [_]i8{ 0, 1, -1, 5, -5, 64, -64, 127, -128 };
    for (i8_cases) |av| {
        var n: u8 = 0;
        while (n < 8) : (n += 1) {
            const shift: u3 = @intCast(n);
            const expected: i8 = @as(i8, av) << shift;
            const actual = Int.fromNative(.i8, @as(i8, av)).shiftLeft(n).toNative(i8);
            try std.testing.expectEqual(expected, actual);
        }
        // n >= bit_width → 0
        try std.testing.expectEqual(@as(i8, 0), Int.fromNative(.i8, @as(i8, av)).shiftLeft(8).toNative(i8));
        try std.testing.expectEqual(@as(i8, 0), Int.fromNative(.i8, @as(i8, av)).shiftLeft(16).toNative(i8));
    }
    const u8_cases = [_]u8{ 0, 1, 0x55, 0xAA, 200, 255 };
    for (u8_cases) |av| {
        var n: u8 = 0;
        while (n < 8) : (n += 1) {
            const shift: u3 = @intCast(n);
            const expected: u8 = @as(u8, av) << shift;
            const actual = Int.fromNative(.u8, @as(u8, av)).shiftLeft(n).toNative(u8);
            try std.testing.expectEqual(expected, actual);
        }
        try std.testing.expectEqual(@as(u8, 0), Int.fromNative(.u8, @as(u8, av)).shiftLeft(8).toNative(u8));
    }
    // i64 边界
    {
        var n: u8 = 0;
        while (n < 64) : (n += 1) {
            const shift: u6 = @intCast(n);
            const expected: i64 = @as(i64, 1) << shift;
            try std.testing.expectEqual(expected, Int.fromNative(.i64, @as(i64, 1)).shiftLeft(n).toNative(i64));
        }
    }
    // i128 边界
    {
        try std.testing.expectEqual(@as(i128, 1) << 100, Int.fromNative(.i128, @as(i128, 1)).shiftLeft(100).toNative(i128));
        try std.testing.expectEqual(@as(i128, 0), Int.fromNative(.i128, @as(i128, 1)).shiftLeft(128).toNative(i128));
    }
}

test "Int.shiftRight matches native >> (arithmetic for signed, logical for unsigned)" {
    // i8：算术右移（保留符号位）
    const i8_cases = [_]i8{ 0, 1, -1, 5, -5, 64, -64, 127, -128 };
    for (i8_cases) |av| {
        var n: u8 = 0;
        while (n < 8) : (n += 1) {
            const shift: u3 = @intCast(n);
            const expected: i8 = @as(i8, av) >> shift;
            const actual = Int.fromNative(.i8, @as(i8, av)).shiftRight(n).toNative(i8);
            try std.testing.expectEqual(expected, actual);
        }
        // n >= bit_width：负数 → -1，非负 → 0
        const expected_big: i8 = if (av < 0) -1 else 0;
        try std.testing.expectEqual(expected_big, Int.fromNative(.i8, @as(i8, av)).shiftRight(8).toNative(i8));
        try std.testing.expectEqual(expected_big, Int.fromNative(.i8, @as(i8, av)).shiftRight(16).toNative(i8));
    }
    // u8：逻辑右移
    const u8_cases = [_]u8{ 0, 1, 0x55, 0xAA, 200, 255 };
    for (u8_cases) |av| {
        var n: u8 = 0;
        while (n < 8) : (n += 1) {
            const shift: u3 = @intCast(n);
            const expected: u8 = @as(u8, av) >> shift;
            const actual = Int.fromNative(.u8, @as(u8, av)).shiftRight(n).toNative(u8);
            try std.testing.expectEqual(expected, actual);
        }
        try std.testing.expectEqual(@as(u8, 0), Int.fromNative(.u8, @as(u8, av)).shiftRight(8).toNative(u8));
    }
    // i64 边界
    {
        var n: u8 = 0;
        while (n < 64) : (n += 1) {
            const shift: u6 = @intCast(n);
            const expected: i64 = @as(i64, std.math.minInt(i64)) >> shift;
            try std.testing.expectEqual(expected, Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).shiftRight(n).toNative(i64));
        }
        // n >= 64：minInt 是负数 → -1
        try std.testing.expectEqual(@as(i64, -1), Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).shiftRight(64).toNative(i64));
    }
    // i128 边界
    {
        try std.testing.expectEqual(@as(i128, std.math.maxInt(i128)) >> 100, Int.fromNative(.i128, @as(i128, std.math.maxInt(i128))).shiftRight(100).toNative(i128));
        try std.testing.expectEqual(@as(i128, -1), Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).shiftRight(128).toNative(i128));
    }
    // u128 边界
    {
        try std.testing.expectEqual(@as(u128, std.math.maxInt(u128)) >> 100, Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).shiftRight(100).toNative(u128));
        try std.testing.expectEqual(@as(u128, 0), Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).shiftRight(128).toNative(u128));
    }
}

// ============================================================
// coerceTo 测试：支撑 §2.15 类型转换规范（widening 总是成功，narrowing 范围检查）
// ============================================================

test "Int.coerceTo same type returns self" {
    const v = Int.fromNative(.i32, @as(i32, 42));
    const r = v.coerceTo(.i32).?;
    try std.testing.expectEqual(@as(i32, 42), r.toNative(i32));
}

test "Int.coerceTo widening always succeeds" {
    // 有符号 widening：i8 → i16/i32/i64/i128
    {
        const v = Int.fromNative(.i8, @as(i8, -1));
        try std.testing.expectEqual(@as(i16, -1), v.coerceTo(.i16).?.toNative(i16));
        try std.testing.expectEqual(@as(i32, -1), v.coerceTo(.i32).?.toNative(i32));
        try std.testing.expectEqual(@as(i64, -1), v.coerceTo(.i64).?.toNative(i64));
        try std.testing.expectEqual(@as(i128, -1), v.coerceTo(.i128).?.toNative(i128));
    }
    // 无符号 widening：u8 → u16/u32/u64/u128
    {
        const v = Int.fromNative(.u8, @as(u8, 200));
        try std.testing.expectEqual(@as(u16, 200), v.coerceTo(.u16).?.toNative(u16));
        try std.testing.expectEqual(@as(u32, 200), v.coerceTo(.u32).?.toNative(u32));
        try std.testing.expectEqual(@as(u64, 200), v.coerceTo(.u64).?.toNative(u64));
        try std.testing.expectEqual(@as(u128, 200), v.coerceTo(.u128).?.toNative(u128));
    }
    // 边界值 widening：i8 max/min → i16
    {
        try std.testing.expectEqual(@as(i16, 127), Int.fromNative(.i8, @as(i8, 127)).coerceTo(.i16).?.toNative(i16));
        try std.testing.expectEqual(@as(i16, -128), Int.fromNative(.i8, @as(i8, -128)).coerceTo(.i16).?.toNative(i16));
    }
    // u8 max → u16
    {
        try std.testing.expectEqual(@as(u16, 255), Int.fromNative(.u8, @as(u8, 255)).coerceTo(.u16).?.toNative(u16));
    }
}

test "Int.coerceTo narrowing in-range succeeds" {
    // i32 → i8，值在 i8 范围内
    {
        const v = Int.fromNative(.i32, @as(i32, 100));
        try std.testing.expectEqual(@as(i8, 100), v.coerceTo(.i8).?.toNative(i8));
    }
    // i32 → i8 边界值
    {
        try std.testing.expectEqual(@as(i8, 127), Int.fromNative(.i32, @as(i32, 127)).coerceTo(.i8).?.toNative(i8));
        try std.testing.expectEqual(@as(i8, -128), Int.fromNative(.i32, @as(i32, -128)).coerceTo(.i8).?.toNative(i8));
    }
    // i64 → i32
    {
        const v = Int.fromNative(.i64, @as(i64, 1_000_000));
        try std.testing.expectEqual(@as(i32, 1_000_000), v.coerceTo(.i32).?.toNative(i32));
    }
    // u32 → u8
    {
        const v = Int.fromNative(.u32, @as(u32, 200));
        try std.testing.expectEqual(@as(u8, 200), v.coerceTo(.u8).?.toNative(u8));
    }
}

test "Int.coerceTo narrowing out-of-range returns null" {
    // i32 → i8 超范围
    {
        const v = Int.fromNative(.i32, @as(i32, 128));
        try std.testing.expect(v.coerceTo(.i8) == null);
    }
    {
        const v = Int.fromNative(.i32, @as(i32, -129));
        try std.testing.expect(v.coerceTo(.i8) == null);
    }
    // i64 → i32 超范围
    {
        const v = Int.fromNative(.i64, @as(i64, std.math.maxInt(i32) + 1));
        try std.testing.expect(v.coerceTo(.i32) == null);
    }
    // u32 → u8 超范围
    {
        const v = Int.fromNative(.u32, @as(u32, 256));
        try std.testing.expect(v.coerceTo(.u8) == null);
    }
    // i128 → i64 超范围（F4 场景：doForNext 索引 narrowing）
    {
        const v = Int.fromNative(.i128, @as(i128, std.math.maxInt(i64) + 1));
        try std.testing.expect(v.coerceTo(.i64) == null);
    }
    {
        const v = Int.fromNative(.i128, @as(i128, std.math.minInt(i64) - 1));
        try std.testing.expect(v.coerceTo(.i64) == null);
    }
    // u128 → i64 超范围（无符号大值 → 有符号窄类型）
    {
        const v = Int.fromNative(.u128, @as(u128, std.math.maxInt(i64) + 1));
        try std.testing.expect(v.coerceTo(.i64) == null);
    }
}

test "Int.coerceTo cross-sign narrowing" {
    // 负数 i → u：返回 null（负值不在无符号范围内）
    {
        const v = Int.fromNative(.i32, @as(i32, -1));
        try std.testing.expect(v.coerceTo(.u32) == null);
    }
    // 正数 i → u：在范围内成功
    {
        const v = Int.fromNative(.i32, @as(i32, 42));
        try std.testing.expectEqual(@as(u32, 42), v.coerceTo(.u32).?.toNative(u32));
    }
    // 大 u → i：超范围返回 null
    {
        const v = Int.fromNative(.u32, @as(u32, std.math.maxInt(i32) + 1));
        try std.testing.expect(v.coerceTo(.i32) == null);
    }
    // u → i：在范围内成功
    {
        const v = Int.fromNative(.u32, @as(u32, 100));
        try std.testing.expectEqual(@as(i32, 100), v.coerceTo(.i32).?.toNative(i32));
    }
}
