//! 自定义整数类型——Type 枚举 + Int 结构体
//!
//! 用 [N]u8 小端补码字节数组存储所有整数类型（i8/i16/i32/i64/i128, u8/u16/u32/u64/u128）。
//! 同一位宽的 signed/unsigned 共用同一 ByteArray union 变体，符号性由 Type 字段区分。
//! 运算时解包到 [16]u8 固定缓冲区统一处理，避免 5×5 union 组合 switch 嵌套。
//!
//! ByteArray 定义在 byte_array.zig（与 float.zig 共用）。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const ByteArray = @import("byte_array.zig").ByteArray;

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

/// 单一 Int 结构体：type + bytes + 运算方法
///
/// 所有算术/位运算内部统一走"解包到 [16]u8 → 字节运算 → 打包回 union"三步：
/// - unpackToBuffer: 把 union 变体拷到 buf 前 N 字节，剩余 16-N 字节按符号扩展或零扩展填满
/// - 运算: 基于 [16]u8 + 有效字节数 + 符号性，逐字节进位链/schoolbook/位移长除法
/// - packFromBuffer: 按 type.byteLength() 截取前 N 字节构造对应 union 变体
pub const Int = struct {
    type: Type,
    bytes: ByteArray,

    /// 全零值
    pub fn zero(t: Type) Int {
        return .{ .type = t, .bytes = switch (t.byteLength()) {
            1 => .{ .b1 = [_]u8{0} },
            2 => .{ .b2 = [_]u8{0} ** 2 },
            4 => .{ .b4 = [_]u8{0} ** 4 },
            8 => .{ .b8 = [_]u8{0} ** 8 },
            16 => .{ .b16 = [_]u8{0} ** 16 },
            else => unreachable,
        } };
    }

    /// 从原生值构造（内存拷贝，不触发原生算术 codegen）
    /// 要求 @sizeOf(@TypeOf(v)) >= t.byteLength()
    pub fn fromNative(t: Type, v: anytype) Int {
        const nbytes = t.byteLength();
        const src: [*]const u8 = @ptrCast(&v);
        return .{ .type = t, .bytes = switch (nbytes) {
            1 => .{ .b1 = src[0..1].* },
            2 => .{ .b2 = src[0..2].* },
            4 => .{ .b4 = src[0..4].* },
            8 => .{ .b8 = src[0..8].* },
            16 => .{ .b16 = src[0..16].* },
            else => unreachable,
        } };
    }

    /// 转为原生值（内存拷贝 + 符号/零扩展）
    /// 匹配类型时直接拷贝；宽化时按 signedness 扩展高位；窄化时截断低位。
    pub fn toNative(self: Int, comptime T: type) T {
        var result: T = std.mem.zeroes(T);
        const dst: [*]u8 = @ptrCast(&result);
        const src = self.bytes.slice();
        const n = src.len;
        const sz = @sizeOf(T);
        if (n <= sz) {
            @memcpy(dst[0..n], src);
            if (n < sz and self.type.isSigned() and (src[n - 1] & 0x80) != 0) {
                @memset(dst[n..sz], 0xFF);
            }
        } else {
            @memcpy(dst[0..sz], src[0..sz]);
        }
        return result;
    }

    /// 比较两个 Int（要求 self.type == other.type）
    pub fn compare(self: Int, other: Int) std.math.Order {
        const signed = self.type.isSigned();
        const a = self.bytes.slice();
        const b = other.bytes.slice();

        if (signed) {
            const a_neg = (a[a.len - 1] & 0x80) != 0;
            const b_neg = (b[b.len - 1] & 0x80) != 0;
            if (a_neg != b_neg) {
                return if (a_neg) .lt else .gt;
            }
        }
        return compareBytes(a, b);
    }

    /// 解包到 [16]u8 固定缓冲区（高位按符号扩展或零扩展填满）
    /// 返回有效字节数
    fn unpackToBuffer(self: Int, buf: *[16]u8) u8 {
        const nbytes = self.type.byteLength();
        const src = self.bytes.slice();
        @memcpy(buf[0..nbytes], src);
        const fill: u8 = if (self.type.isSigned() and (src[nbytes - 1] & 0x80) != 0) 0xFF else 0x00;
        @memset(buf[nbytes..16], fill);
        return nbytes;
    }

    /// 从 [16]u8 缓冲区打包回 union（截取前 N 字节）
    fn packFromBuffer(t: Type, buf: *const [16]u8) Int {
        const nbytes = t.byteLength();
        return .{ .type = t, .bytes = switch (nbytes) {
            1 => .{ .b1 = buf[0..1].* },
            2 => .{ .b2 = buf[0..2].* },
            4 => .{ .b4 = buf[0..4].* },
            8 => .{ .b8 = buf[0..8].* },
            16 => .{ .b16 = buf[0..16].* },
            else => unreachable,
        } };
    }

    // —— 算术（S3-S5 实现）——

    /// 加法（补码逐字节进位链）。要求 self.type == other.type，结果 type 同。
    /// 溢出判定：无符号看最高字节进位输出；有符号看"同号得异号"。
    pub fn add(self: Int, other: Int) struct { result: Int, overflow: bool } {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const a = self.bytes.slice();
        const b = other.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var carry: u16 = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const sum: u16 = @as(u16, a[i]) + @as(u16, b[i]) + carry;
            r16[i] = @truncate(sum);
            carry = sum >> 8;
        }
        const unsigned_overflow = carry != 0;
        const signed = t.isSigned();
        var signed_overflow = false;
        if (signed) {
            const a_sign = (a[a.len - 1] & 0x80) != 0;
            const b_sign = (b[b.len - 1] & 0x80) != 0;
            const r_sign = (r16[a.len - 1] & 0x80) != 0;
            signed_overflow = (a_sign == b_sign) and (r_sign != a_sign);
        }
        return .{
            .result = Int.packFromBuffer(t, &r16),
            .overflow = if (signed) signed_overflow else unsigned_overflow,
        };
    }

    /// 减法（a - b = a + ~b + 1，复用进位链）。要求 self.type == other.type，结果 type 同。
    /// 溢出判定：无符号看借位（carry==0 表示 a<b）；有符号看"异号得非 a 号"。
    pub fn subtract(self: Int, other: Int) struct { result: Int, overflow: bool } {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const a = self.bytes.slice();
        const b = other.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var carry: u16 = 1; // +1 完成补码取反
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const inv_b: u8 = ~b[i];
            const sum: u16 = @as(u16, a[i]) + @as(u16, inv_b) + carry;
            r16[i] = @truncate(sum);
            carry = sum >> 8;
        }
        const unsigned_overflow = (carry == 0);
        const signed = t.isSigned();
        var signed_overflow = false;
        if (signed) {
            const a_sign = (a[a.len - 1] & 0x80) != 0;
            const b_sign = (b[b.len - 1] & 0x80) != 0;
            const r_sign = (r16[a.len - 1] & 0x80) != 0;
            signed_overflow = (a_sign != b_sign) and (r_sign != a_sign);
        }
        return .{
            .result = Int.packFromBuffer(t, &r16),
            .overflow = if (signed) signed_overflow else unsigned_overflow,
        };
    }

    /// 是否为负数（无符号类型恒为 false）
    pub fn isNegative(self: Int) bool {
        if (!self.type.isSigned()) return false;
        const a = self.bytes.slice();
        return (a[a.len - 1] & 0x80) != 0;
    }

    /// 取负（补码取反加一）。minInt 取负溢出返回自身（two's complement 回绕）。
    pub fn negate(self: Int) Int {
        const a = self.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var carry: u16 = 1;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const inv: u8 = ~a[i];
            const sum: u16 = @as(u16, inv) + carry;
            r16[i] = @truncate(sum);
            carry = sum >> 8;
        }
        return Int.packFromBuffer(self.type, &r16);
    }

    /// 乘法（schoolbook 逐字节乘法 + 绝对值法）。
    /// 有符号：取绝对值相乘得 magnitude，结果按符号修正；溢出判定基于 magnitude 与 2^(8N-1) 比较。
    /// 无符号：直接相乘，高位非零即溢出。
    pub fn multiply(self: Int, other: Int) struct { result: Int, overflow: bool } {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const n = t.byteLength();
        const signed = t.isSigned();

        // 绝对值（无符号即自身）
        var abs_a_buf: [16]u8 = [_]u8{0} ** 16;
        var abs_b_buf: [16]u8 = [_]u8{0} ** 16;
        @memcpy(abs_a_buf[0..n], self.bytes.slice());
        @memcpy(abs_b_buf[0..n], other.bytes.slice());
        if (signed and self.isNegative()) negateBytesInPlace(abs_a_buf[0..n]);
        if (signed and other.isNegative()) negateBytesInPlace(abs_b_buf[0..n]);

        var magnitude: [32]u8 = undefined;
        schoolbookMultiply(abs_a_buf[0..n], abs_b_buf[0..n], magnitude[0 .. n * 2]);

        // 结果 = magnitude 低 N 字节；有符号且结果为负时取负
        var r16: [16]u8 = [_]u8{0} ** 16;
        @memcpy(r16[0..n], magnitude[0..n]);
        const result_sign = signed and (self.isNegative() != other.isNegative());
        if (result_sign) negateBytesInPlace(r16[0..n]);

        // 溢出判定
        var overflow = false;
        if (signed) {
            // 阈值 2^(8N-1)：byte[n-1]=0x80，其余 0（在 2N 字节缓冲区中）
            var threshold: [32]u8 = [_]u8{0} ** 32;
            threshold[n - 1] = 0x80;
            const cmp = compareBytes(magnitude[0 .. n * 2], threshold[0 .. n * 2]);
            if (result_sign) {
                // 负结果：|minInt| = 2^(8N-1)，magnitude > 阈值 才溢出
                overflow = (cmp == .gt);
            } else {
                // 正结果：maxInt = 2^(8N-1)-1，magnitude >= 阈值 即溢出
                overflow = (cmp != .lt);
            }
        } else {
            for (magnitude[n .. n * 2]) |byte| {
                if (byte != 0) {
                    overflow = true;
                    break;
                }
            }
        }

        return .{ .result = Int.packFromBuffer(t, &r16), .overflow = overflow };
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
    /// 算法：取绝对值做无符号恢复式长除法，再按符号修正商/余数。
    fn divideWithRemainder(self: Int, other: Int) error{DivideByZero}!struct { quotient: Int, remainder: Int } {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const n = t.byteLength();
        const signed = t.isSigned();

        // 除零检测
        if (isAllZero(other.bytes.slice())) return error.DivideByZero;

        // minInt / -1 边界：返回 minInt（商），0（余数），与 Zig @divTrunc/@mod 一致
        if (signed) {
            // 检测 other == -1（所有字节 0xFF）
            var neg_one_buf: [16]u8 = [_]u8{0} ** 16;
            @memset(neg_one_buf[0..n], 0xFF);
            const other_is_neg_one = (compareBytes(other.bytes.slice(), neg_one_buf[0..n]) == .eq);
            // 检测 self == minInt（最高字节 0x80，其余 0x00）
            var min_int_buf: [16]u8 = [_]u8{0} ** 16;
            min_int_buf[n - 1] = 0x80;
            const self_is_min_int = (compareBytes(self.bytes.slice(), min_int_buf[0..n]) == .eq);
            if (other_is_neg_one and self_is_min_int) {
                return .{ .quotient = self, .remainder = Int.zero(t) };
            }
        }

        // 取绝对值
        var abs_a_buf: [16]u8 = [_]u8{0} ** 16;
        var abs_b_buf: [16]u8 = [_]u8{0} ** 16;
        @memcpy(abs_a_buf[0..n], self.bytes.slice());
        @memcpy(abs_b_buf[0..n], other.bytes.slice());
        const a_neg = signed and self.isNegative();
        const b_neg = signed and other.isNegative();
        if (a_neg) negateBytesInPlace(abs_a_buf[0..n]);
        if (b_neg) negateBytesInPlace(abs_b_buf[0..n]);

        // 无符号恢复式长除法
        var quotient_buf: [16]u8 = [_]u8{0} ** 16;
        var remainder_buf: [17]u8 = [_]u8{0} ** 17; // 多 1 字节防左移溢出
        unsignedDivide(abs_a_buf[0..n], abs_b_buf[0..n], quotient_buf[0..n], remainder_buf[0 .. n + 1]);

        // 修正符号
        // 截断除法：商符号 = 异号；余数符号 = 同被除数
        const quotient_neg = a_neg != b_neg;
        if (quotient_neg) negateBytesInPlace(quotient_buf[0..n]);
        if (a_neg) negateBytesInPlace(remainder_buf[0..n]);

        var rem16: [16]u8 = [_]u8{0} ** 16;
        @memcpy(rem16[0..n], remainder_buf[0..n]);
        return .{
            .quotient = Int.packFromBuffer(t, &quotient_buf),
            .remainder = Int.packFromBuffer(t, &rem16),
        };
    }

    // —— 位运算（S6 实现）——

    /// 按位与。要求 self.type == other.type。
    pub fn bitwiseAnd(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const n = t.byteLength();
        const a = self.bytes.slice();
        const b = other.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 0;
        while (i < n) : (i += 1) r16[i] = a[i] & b[i];
        return Int.packFromBuffer(t, &r16);
    }

    /// 按位或。要求 self.type == other.type。
    pub fn bitwiseOr(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const n = t.byteLength();
        const a = self.bytes.slice();
        const b = other.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 0;
        while (i < n) : (i += 1) r16[i] = a[i] | b[i];
        return Int.packFromBuffer(t, &r16);
    }

    /// 按位异或。要求 self.type == other.type。
    pub fn bitwiseXor(self: Int, other: Int) Int {
        std.debug.assert(self.type == other.type);
        const t = self.type;
        const n = t.byteLength();
        const a = self.bytes.slice();
        const b = other.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 0;
        while (i < n) : (i += 1) r16[i] = a[i] ^ b[i];
        return Int.packFromBuffer(t, &r16);
    }

    /// 按位取反（逐字节 ~）。对有符号类型等价于 -x - 1。
    pub fn bitwiseNot(self: Int) Int {
        const t = self.type;
        const n = t.byteLength();
        const a = self.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 0;
        while (i < n) : (i += 1) r16[i] = ~a[i];
        return Int.packFromBuffer(t, &r16);
    }

    /// 逻辑左移 n 位（无符号与有符号语义一致，低位补 0）。
    /// n >= bitWidth 时返回 zero。
    pub fn shiftLeft(self: Int, n: u8) Int {
        const t = self.type;
        const bit_width = t.bitWidth();
        if (n >= bit_width) return Int.zero(t);
        const nbytes = t.byteLength();
        const a = self.bytes.slice();
        var r16: [16]u8 = [_]u8{0} ** 16;
        const byte_shift: usize = n / 8;
        const bit_shift: u3 = @intCast(n % 8);
        var i: usize = 0;
        while (i < nbytes) : (i += 1) {
            const dst = i + byte_shift;
            if (dst >= nbytes) break;
            const v: u16 = @as(u16, a[i]) << bit_shift;
            r16[dst] |= @truncate(v);
            // 高位部分进入下一字节
            if (bit_shift != 0 and dst + 1 < nbytes) {
                r16[dst + 1] |= @truncate(v >> 8);
            }
        }
        return Int.packFromBuffer(t, &r16);
    }

    /// 右移 n 位。无符号类型为逻辑右移（高位补 0）；有符号类型为算术右移（高位补符号位）。
    /// n >= bitWidth 时：无符号返回 zero；有符号返回 0（正数）或 -1（负数）。
    pub fn shiftRight(self: Int, n: u8) Int {
        const t = self.type;
        const bit_width = t.bitWidth();
        const nbytes = t.byteLength();
        const a = self.bytes.slice();

        if (n >= bit_width) {
            if (t.isSigned() and (a[nbytes - 1] & 0x80) != 0) {
                // 负数算术右移 >= 位宽 → 全 1（-1）
                var r16: [16]u8 = [_]u8{0} ** 16;
                @memset(r16[0..nbytes], 0xFF);
                return Int.packFromBuffer(t, &r16);
            }
            return Int.zero(t);
        }

        const byte_shift: usize = n / 8;
        const bit_shift: u3 = @intCast(n % 8);
        const fill: u8 = if (t.isSigned() and (a[nbytes - 1] & 0x80) != 0) 0xFF else 0x00;
        var r16: [16]u8 = [_]u8{0} ** 16;

        var i: usize = 0;
        while (i < nbytes) : (i += 1) {
            const src_idx = i + byte_shift;
            const src_byte: u8 = if (src_idx < nbytes) a[src_idx] else fill;
            const next_byte: u8 = if (src_idx + 1 < nbytes) a[src_idx + 1] else fill;
            if (bit_shift == 0) {
                r16[i] = src_byte;
            } else {
                const low: u16 = @as(u16, src_byte) >> bit_shift;
                const high: u16 = @as(u16, next_byte) << @intCast(8 - @as(u8, bit_shift));
                r16[i] = @truncate(low | high);
            }
        }
        return Int.packFromBuffer(t, &r16);
    }

    // —— 浮点尾数运算辅助（S8+ 实现，供 float.zig 委托）——
    // fn addExtended(self: Int, other: Int) struct { result: Int, carry: bool }
    // fn addOne(self: Int) Int
    // fn leastSignificantBit(self: Int) u8
};

/// 从高位到低位逐字节比较（无符号语义，要求等长）
fn compareBytes(a: []const u8, b: []const u8) std.math.Order {
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return .lt;
        if (a[i] > b[i]) return .gt;
    }
    return .eq;
}

/// 检查所有字节是否为 0
fn isAllZero(s: []const u8) bool {
    for (s) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// 原地左移一位（带跨字节进位）
fn shiftLeftOneBit(s: []u8) void {
    var carry: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const new_byte: u8 = (s[i] << 1) | carry;
        carry = s[i] >> 7;
        s[i] = new_byte;
    }
}

/// 原地无符号减法 a -= b（假定 a >= b，调用方负责保证）。b 不足 a.len 的高位按 0 处理。
fn subtractBytesInPlace(a: []u8, b: []const u8) void {
    var borrow: i16 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const bi: u16 = if (i < b.len) b[i] else 0;
        const diff: i16 = @as(i16, a[i]) - @as(i16, @intCast(bi)) - borrow;
        if (diff < 0) {
            a[i] = @intCast(diff + 256);
            borrow = 1;
        } else {
            a[i] = @intCast(diff);
            borrow = 0;
        }
    }
}

/// 无符号恢复式长除法：a / b = quotient ... remainder。
/// quotient 长度 = a.len；remainder 长度须为 a.len + 1（防左移溢出）。
/// 调用前 quotient/remainder 会被清零。
fn unsignedDivide(a: []const u8, b: []const u8, quotient: []u8, remainder: []u8) void {
    @memset(quotient, 0);
    @memset(remainder, 0);

    const total_bits = a.len * 8;
    var bit: usize = total_bits;
    while (bit > 0) {
        bit -= 1;
        // remainder 左移 1 位
        shiftLeftOneBit(remainder);
        // 把 a 的 bit 位拉到 remainder 的 LSB
        const byte_idx = bit / 8;
        const bit_idx: u3 = @intCast(bit % 8);
        if ((a[byte_idx] >> bit_idx) & 1 != 0) {
            remainder[0] |= 1;
        }
        // 试减：若 remainder >= b 则减，quotient 对应位置 1
        // remainder 用前 b.len 字节与 b 比较（高位 remainder[b.len..] 在 remainder < 2*b 的过程中最多进位 1 字节）
        if (compareBytes(remainder[0..b.len], b) != .lt) {
            subtractBytesInPlace(remainder[0..b.len], b);
            quotient[byte_idx] |= (@as(u8, 1) << bit_idx);
        }
    }
}

/// 原地补码取负（取反加一）
fn negateBytesInPlace(s: []u8) void {
    var carry: u16 = 1;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const inv: u8 = ~s[i];
        const sum: u16 = @as(u16, inv) + carry;
        s[i] = @truncate(sum);
        carry = sum >> 8;
    }
}

/// schoolbook 逐字节乘法。out 长度须为 a.len + b.len，写入前清零由本函数完成。
fn schoolbookMultiply(a: []const u8, b: []const u8, out: []u8) void {
    @memset(out, 0);
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var carry: u16 = 0;
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            const prod: u16 = @as(u16, a[i]) * @as(u16, b[j]) + @as(u16, out[i + j]) + carry;
            out[i + j] = @truncate(prod);
            carry = prod >> 8;
        }
        // 把剩余 carry 向高位传播
        var k: usize = i + b.len;
        while (carry != 0 and k < out.len) : (k += 1) {
            const sum: u16 = @as(u16, out[k]) + carry;
            out[k] = @truncate(sum);
            carry = sum >> 8;
        }
    }
}

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

test "ByteArray.byteLength" {
    const b1 = ByteArray{ .b1 = [_]u8{0} };
    const b2 = ByteArray{ .b2 = [_]u8{ 0, 0 } };
    const b4 = ByteArray{ .b4 = [_]u8{ 0, 0, 0, 0 } };
    const b8 = ByteArray{ .b8 = [_]u8{0} ** 8 };
    const b16 = ByteArray{ .b16 = [_]u8{0} ** 16 };
    try std.testing.expectEqual(@as(u8, 1), b1.byteLength());
    try std.testing.expectEqual(@as(u8, 2), b2.byteLength());
    try std.testing.expectEqual(@as(u8, 4), b4.byteLength());
    try std.testing.expectEqual(@as(u8, 8), b8.byteLength());
    try std.testing.expectEqual(@as(u8, 16), b16.byteLength());
}

test "ByteArray.slice" {
    var ba = ByteArray{ .b4 = [_]u8{ 0x01, 0x02, 0x03, 0x04 } };
    const s = ba.slice();
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqual(@as(u8, 0x01), s[0]);
    try std.testing.expectEqual(@as(u8, 0x04), s[3]);
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

test "Int.unpackToBuffer/packFromBuffer roundtrip" {
    // i32 -1：符号扩展填满 0xFF
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.i32, @as(i32, -1));
        const n = v.unpackToBuffer(&buf);
        try std.testing.expectEqual(@as(u8, 4), n);
        for (buf) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);
        const back = Int.packFromBuffer(.i32, &buf);
        try std.testing.expectEqual(.eq, v.compare(back));
    }
    // u32 0xDEADBEEF：零扩展填满 0x00
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.u32, @as(u32, 0xDEADBEEF));
        const n = v.unpackToBuffer(&buf);
        try std.testing.expectEqual(@as(u8, 4), n);
        try std.testing.expectEqual(@as(u8, 0xEF), buf[0]);
        try std.testing.expectEqual(@as(u8, 0xBE), buf[1]);
        try std.testing.expectEqual(@as(u8, 0xAD), buf[2]);
        try std.testing.expectEqual(@as(u8, 0xDE), buf[3]);
        for (buf[4..16]) |b| try std.testing.expectEqual(@as(u8, 0x00), b);
        const back = Int.packFromBuffer(.u32, &buf);
        try std.testing.expectEqual(.eq, v.compare(back));
    }
    // i128 边界：16 字节无填充
    {
        var buf: [16]u8 = undefined;
        const v = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
        const n = v.unpackToBuffer(&buf);
        try std.testing.expectEqual(@as(u8, 16), n);
        // minInt(i128)：低 15 字节 0x00，高字节 0x80
        for (buf[0..15]) |b| try std.testing.expectEqual(@as(u8, 0x00), b);
        try std.testing.expectEqual(@as(u8, 0x80), buf[15]);
        const back = Int.packFromBuffer(.i128, &buf);
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
