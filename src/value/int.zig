//! 自定义整数类型——Type 枚举 + Int 结构体
//!
//! 用 [16]u8 小端补码字节数组（定长）存储所有整数类型（i8/i16/i32/i64/i128,
//! u8/u16/u32/u64/u128）。同一位宽的 signed/unsigned 共用同一 [16]u8 缓冲，
//! 符号性由 Type 字段区分；有效字节数 = type.byteLength()，高位字节不参与运算
//! （构造时清零，读取只取前 N 字节）。运算时解包到同一 [16]u8 缓冲统一处理。
//!
//! 注：原 ByteArray union(tag + 变长 [N]u8) 与 Type 字段冗余编码位宽，已移除；
//! byte_array.zig 仅保留字节 IO 原语（loadWord/storeWord/loadU128/storeU128）。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const byte_array = @import("byte_array.zig");
const wide = @import("wide.zig");
const U128 = wide.U128;
const loadWord = wide.loadWord;
const storeWord = wide.storeWord;
const mulU64ToU128 = wide.mulU64ToU128;
const multiplyU64Schoolbook = wide.multiplyU64Schoolbook;

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

/// 单一 Int 结构体：type + bytes + 运算方法
pub const Int = struct {
    type: Type,
    bytes: [16]u8,

    /// 有效字节切片（只读）。长度由 type.byteLength() 决定，等价于旧的 ByteArray.slice()
    /// 但无 union tag 分派，直接取定长缓冲的前 N 字节。
    pub inline fn slice(self: *const Int) []const u8 {
        return self.bytes[0..self.type.byteLength()];
    }

    /// 有效字节切片（可变）
    pub inline fn sliceMutable(self: *Int) []u8 {
        return self.bytes[0..self.type.byteLength()];
    }

    /// 全零值
    pub fn zero(t: Type) Int {
        return .{ .type = t, .bytes = [_]u8{0} ** 16 };
    }

    /// 从原生值构造（内存拷贝，不触发原生算术 codegen）
    /// 要求 @sizeOf(@TypeOf(v)) >= t.byteLength()
    pub fn fromNative(t: Type, v: anytype) Int {
        const nbytes = t.byteLength();
        const src: [*]const u8 = @ptrCast(&v);
        var result: Int = .{ .type = t, .bytes = [_]u8{0} ** 16 };
        @memcpy(result.bytes[0..nbytes], src[0..nbytes]);
        return result;
    }

    /// 从 U128 构造（零拷贝：直接写入定长缓冲，截取低 t.byteLength() 字节）
    /// 供 Float.toInt 使用，绕过 u128 形参的 IO 边界例外
    pub fn fromU128Unchecked(t: Type, val: U128) Int {
        var result = Int.zero(t);
        byte_array.storeU128(result.bytes[0..t.byteLength()], val);
        return result;
    }

    /// 转为原生值（内存拷贝 + 符号/零扩展）
    /// 匹配类型时直接拷贝；宽化时按 signedness 扩展高位；窄化时截断低位。
    pub fn toNative(self: Int, comptime T: type) T {
        var result: T = std.mem.zeroes(T);
        const dst: [*]u8 = @ptrCast(&result);
        const src = self.slice();
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
        return comparePortable(self, other);
    }

    fn comparePortable(self: Int, other: Int) std.math.Order {
        const signed = self.type.isSigned();
        const a = self.slice();
        const b = other.slice();

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
        const src = self.slice();
        @memcpy(buf[0..nbytes], src);
        const fill: u8 = if (self.type.isSigned() and (src[nbytes - 1] & 0x80) != 0) 0xFF else 0x00;
        @memset(buf[nbytes..16], fill);
        return nbytes;
    }

    /// 从 [16]u8 缓冲区打包回 Int（拷贝全 16 字节；仅前 N 字节有效）
    pub fn fromBytes(t: Type, buf: *const [16]u8) Int {
        return .{ .type = t, .bytes = buf.* };
    }

    /// 从 [16]u8 缓冲区打包回 Int（内部别名，向后兼容）
    fn packFromBuffer(t: Type, buf: *const [16]u8) Int {
        return fromBytes(t, buf);
    }

    // —— 算术（S3-S5 实现）——

    /// 加法。要求 self.type == other.type，结果 type 同。
    pub fn add(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return addPortable(self, other);
    }

    fn addPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;
        const signed = t.isSigned();
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const b = other.slice();
        const r = result_bytes[0..t.byteLength()];

        const unsigned_overflow = switch (t.byteLength()) {
            1 => addWordN(u8, r, a, b),
            2 => addWordN(u16, r, a, b),
            4 => addWordN(u32, r, a, b),
            8 => addWordN(u64, r, a, b),
            16 => blk: {
                const av = U128.load(a);
                const bv = U128.load(b);
                const result = av.add(bv);
                result.sum.store(r);
                break :blk result.carry != 0;
            },
            else => unreachable,
        };

        if (signed) {
            const a_sign = (a[a.len - 1] & 0x80) != 0;
            const b_sign = (b[b.len - 1] & 0x80) != 0;
            const r_sign = (r[r.len - 1] & 0x80) != 0;
            return .{
                .result = .{ .type = t, .bytes = result_bytes },
                .overflow = (a_sign == b_sign) and (r_sign != a_sign),
            };
        }
        return .{ .result = .{ .type = t, .bytes = result_bytes }, .overflow = unsigned_overflow };
    }

    /// 减法。要求 self.type == other.type，结果 type 同。
    pub fn subtract(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return subtractPortable(self, other);
    }

    fn subtractPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;
        const signed = t.isSigned();
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const b = other.slice();
        const r = result_bytes[0..t.byteLength()];

        const unsigned_overflow = switch (t.byteLength()) {
            1 => subWordN(u8, r, a, b),
            2 => subWordN(u16, r, a, b),
            4 => subWordN(u32, r, a, b),
            8 => subWordN(u64, r, a, b),
            16 => blk: {
                const av = U128.load(a);
                const bv = U128.load(b);
                const result = av.sub(bv);
                result.diff.store(r);
                break :blk result.borrow != 0;
            },
            else => unreachable,
        };

        if (signed) {
            const a_sign = (a[a.len - 1] & 0x80) != 0;
            const b_sign = (b[b.len - 1] & 0x80) != 0;
            const r_sign = (r[r.len - 1] & 0x80) != 0;
            return .{
                .result = .{ .type = t, .bytes = result_bytes },
                .overflow = (a_sign != b_sign) and (r_sign != a_sign),
            };
        }
        return .{ .result = .{ .type = t, .bytes = result_bytes }, .overflow = unsigned_overflow };
    }

    /// 是否为负数（无符号类型恒为 false）
    pub fn isNegative(self: Int) bool {
        if (!self.type.isSigned()) return false;
        const a = self.slice();
        return (a[a.len - 1] & 0x80) != 0;
    }

    /// 取负（补码取反加一）。minInt 取负溢出返回自身（two's complement 回绕）。
    /// 字块化：用 u8/u16/u32/u64/U128 替代逐字节循环。
    pub fn negate(self: Int) Int {
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const r = result_bytes[0..self.type.byteLength()];
        switch (self.type.byteLength()) {
            1 => negateWordN(u8, r, a),
            2 => negateWordN(u16, r, a),
            4 => negateWordN(u32, r, a),
            8 => negateWordN(u64, r, a),
            16 => {
                const av = U128.load(a);
                av.negate().store(r);
            },
            else => unreachable,
        }
        return .{ .type = self.type, .bytes = result_bytes };
    }

    /// 乘法。要求 self.type == other.type，结果 type 同。
    pub fn multiply(self: Int, other: Int) OverflowResult {
        std.debug.assert(self.type == other.type);
        return multiplyPortable(self, other);
    }

    fn multiplyPortable(self: Int, other: Int) OverflowResult {
        const t = self.type;
        const n = t.byteLength();
        const signed = t.isSigned();

        // 绝对值（无符号即自身）
        var abs_a_buf: [16]u8 = [_]u8{0} ** 16;
        var abs_b_buf: [16]u8 = [_]u8{0} ** 16;
        @memcpy(abs_a_buf[0..n], self.slice());
        @memcpy(abs_b_buf[0..n], other.slice());
        if (signed and self.isNegative()) negateBytesInPlace(abs_a_buf[0..n]);
        if (signed and other.isNegative()) negateBytesInPlace(abs_b_buf[0..n]);

        // 完整乘积（2N 字节，用于溢出判定）
        var magnitude: [32]u8 = [_]u8{0} ** 32;
        const a = abs_a_buf[0..n];
        const b = abs_b_buf[0..n];
        const m = magnitude[0 .. n * 2];

        switch (n) {
            1 => {
                const prod: u16 = @as(u16, a[0]) * @as(u16, b[0]);
                m[0] = @truncate(prod);
                m[1] = @truncate(prod >> 8);
            },
            2 => {
                const av: u16 = loadWord(u16, a);
                const bv: u16 = loadWord(u16, b);
                const prod: u32 = @as(u32, av) * @as(u32, bv);
                storeWord(u32, m, prod);
            },
            4 => {
                const av: u32 = loadWord(u32, a);
                const bv: u32 = loadWord(u32, b);
                const prod: u64 = @as(u64, av) * @as(u64, bv);
                storeWord(u64, m, prod);
            },
            8 => {
                const av: u64 = loadWord(u64, a);
                const bv: u64 = loadWord(u64, b);
                const prod = mulU64ToU128(av, bv);
                storeWord(u64, m[0..8], prod.lo);
                storeWord(u64, m[8..16], prod.hi);
            },
            16 => multiplyU64Schoolbook(m, a, b),
            else => unreachable,
        }

        // 结果容器（直接写入定长缓冲前 N 字节）
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const r = result_bytes[0..n];
        @memcpy(r, magnitude[0..n]);
        const result_sign = signed and (self.isNegative() != other.isNegative());
        if (result_sign) negateBytesInPlace(r);

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

        return .{ .result = .{ .type = t, .bytes = result_bytes }, .overflow = overflow };
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
        const n = t.byteLength();
        const signed = t.isSigned();

        // 除零检测
        if (isAllZero(other.slice())) return error.DivideByZero;

        // minInt / -1 边界：返回 minInt（商），0（余数），与 Zig @divTrunc/@mod 一致
        // 必须在调用汇编前拦截（≤64位 idiv 会 #DE）
        if (signed) {
            var neg_one_buf: [16]u8 = [_]u8{0} ** 16;
            @memset(neg_one_buf[0..n], 0xFF);
            const other_is_neg_one = (compareBytes(other.slice(), neg_one_buf[0..n]) == .eq);
            var min_int_buf: [16]u8 = [_]u8{0} ** 16;
            min_int_buf[n - 1] = 0x80;
            const self_is_min_int = (compareBytes(self.slice(), min_int_buf[0..n]) == .eq);
            if (other_is_neg_one and self_is_min_int) {
                return .{ .quotient = self, .remainder = Int.zero(t) };
            }
        }

        return divideWithRemainderPortable(self, other);
    }

    fn divideWithRemainderPortable(self: Int, other: Int) DivModResult {
        const t = self.type;
        const n = t.byteLength();
        const signed = t.isSigned();

        // 取绝对值
        var abs_a_buf: [16]u8 = [_]u8{0} ** 16;
        var abs_b_buf: [16]u8 = [_]u8{0} ** 16;
        @memcpy(abs_a_buf[0..n], self.slice());
        @memcpy(abs_b_buf[0..n], other.slice());
        const a_neg = signed and self.isNegative();
        const b_neg = signed and other.isNegative();
        if (a_neg) negateBytesInPlace(abs_a_buf[0..n]);
        if (b_neg) negateBytesInPlace(abs_b_buf[0..n]);

        const a = abs_a_buf[0..n];
        const b = abs_b_buf[0..n];

        // 结果容器（直接写入定长缓冲前 N 字节）
        var quotient_bytes: [16]u8 = [_]u8{0} ** 16;
        var remainder_bytes: [16]u8 = [_]u8{0} ** 16;
        const q = quotient_bytes[0..n];
        const r = remainder_bytes[0..n];

        switch (n) {
            1 => {
                const av: u8 = a[0];
                const bv: u8 = b[0];
                q[0] = av / bv;
                r[0] = av % bv;
            },
            2 => {
                const av: u16 = loadWord(u16, a);
                const bv: u16 = loadWord(u16, b);
                storeWord(u16, q, av / bv);
                storeWord(u16, r, av % bv);
            },
            4 => {
                const av: u32 = loadWord(u32, a);
                const bv: u32 = loadWord(u32, b);
                storeWord(u32, q, av / bv);
                storeWord(u32, r, av % bv);
            },
            8 => {
                const av: u64 = loadWord(u64, a);
                const bv: u64 = loadWord(u64, b);
                storeWord(u64, q, av / bv);
                storeWord(u64, r, av % bv);
            },
            16 => {
                // u128/u128：unsignedDivide128 直接写入 q/r（均 16 字节），无需临时缓冲。
                // 快路径（除数 fit u64）走 2 次原生 u64 除法，慢路径走 U128 位级长除法。
                unsignedDivide128(a, b, q, r);
            },
            else => unreachable,
        }

        // 修正符号（截断除法：商符号 = 异号；余数符号 = 同被除数）
        if (a_neg != b_neg) negateBytesInPlace(q);
        if (a_neg) negateBytesInPlace(r);

        return .{
            .quotient = .{ .type = t, .bytes = quotient_bytes },
            .remainder = .{ .type = t, .bytes = remainder_bytes },
        };
    }

    // —— 位运算（S6 实现）——

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
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const b = other.slice();
        const r = result_bytes[0..t.byteLength()];
        switch (t.byteLength()) {
            1 => bitwiseWordN(u8, r, a, b, op),
            2 => bitwiseWordN(u16, r, a, b, op),
            4 => bitwiseWordN(u32, r, a, b, op),
            8 => bitwiseWordN(u64, r, a, b, op),
            16 => {
                const av = U128.load(a);
                const bv = U128.load(b);
                const result = switch (op) {
                    .and_op => U128{ .hi = av.hi & bv.hi, .lo = av.lo & bv.lo },
                    .or_op => U128{ .hi = av.hi | bv.hi, .lo = av.lo | bv.lo },
                    .xor_op => U128{ .hi = av.hi ^ bv.hi, .lo = av.lo ^ bv.lo },
                };
                result.store(r);
            },
            else => unreachable,
        }
        return .{ .type = t, .bytes = result_bytes };
    }

    /// 按位取反（逐字节 ~）。对有符号类型等价于 -x - 1。
    pub fn bitwiseNot(self: Int) Int {
        return bitwiseNotPortable(self);
    }

    fn bitwiseNotPortable(self: Int) Int {
        const t = self.type;
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const r = result_bytes[0..t.byteLength()];
        switch (t.byteLength()) {
            1 => notWordN(u8, r, a),
            2 => notWordN(u16, r, a),
            4 => notWordN(u32, r, a),
            8 => notWordN(u64, r, a),
            16 => {
                const av = U128.load(a);
                const not_av = U128{ .hi = ~av.hi, .lo = ~av.lo };
                not_av.store(r);
            },
            else => unreachable,
        }
        return .{ .type = t, .bytes = result_bytes };
    }

    /// 逻辑左移 n 位（无符号与有符号语义一致，低位补 0）。
    /// n >= bitWidth 时返回 zero。
    pub fn shiftLeft(self: Int, n: u8) Int {
        return shiftLeftPortable(self, n);
    }

    fn shiftLeftPortable(self: Int, n: u8) Int {
        const t = self.type;
        const bit_width = t.bitWidth();
        if (n >= bit_width) return Int.zero(t);
        const nbytes = t.byteLength();
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const r = result_bytes[0..nbytes];
        switch (nbytes) {
            1 => shiftLeftWordN(u8, r, a, n),
            2 => shiftLeftWordN(u16, r, a, n),
            4 => shiftLeftWordN(u32, r, a, n),
            8 => shiftLeftWordN(u64, r, a, n),
            16 => {
                const av = U128.load(a);
                av.shiftLeft(n).store(r);
            },
            else => unreachable,
        }
        return .{ .type = t, .bytes = result_bytes };
    }

    /// 右移 n 位。无符号类型为逻辑右移（高位补 0）；有符号类型为算术右移（高位补符号位）。
    /// n >= bitWidth 时：无符号返回 zero；有符号返回 0（正数）或 -1（负数）。
    pub fn shiftRight(self: Int, n: u8) Int {
        return shiftRightPortable(self, n);
    }

    fn shiftRightPortable(self: Int, n: u8) Int {
        const t = self.type;
        const signed = t.isSigned();
        var result_bytes: [16]u8 = [_]u8{0} ** 16;
        const a = self.slice();
        const r = result_bytes[0..t.byteLength()];
        switch (t.byteLength()) {
            1 => shiftRightWordN(u8, r, a, n, signed),
            2 => shiftRightWordN(u16, r, a, n, signed),
            4 => shiftRightWordN(u32, r, a, n, signed),
            8 => shiftRightWordN(u64, r, a, n, signed),
            16 => {
                const av = U128.load(a);
                av.shiftRight(n, signed).store(r);
            },
            else => unreachable,
        }
        return .{ .type = t, .bytes = result_bytes };
    }

    /// 类型转换：将 self 转为 target 类型表示。
    /// 全软件字节级：先符号/零扩展到 16 字节，再用 inRangeBytes 检查是否在目标范围内，
    /// 最后截取低 target.byteLength() 字节打包。超出范围返回 null（调用方处理溢出）。
    /// 同类型直接返回 self；宽化总是成功；窄化仅在值落在目标范围内时成功。
    pub fn coerceTo(self: Int, target: Type) ?Int {
        if (self.type == target) return self;
        var buf: [16]u8 = [_]u8{0} ** 16;
        _ = self.unpackToBuffer(&buf);
        if (!target.inRangeBytes(&buf)) return null;
        return packFromBuffer(target, &buf);
    }

    /// 是否为零（全字节为 0）
    pub fn isZero(self: Int) bool {
        return isAllZero(self.slice());
    }

    /// 十进制格式化：将 self 写入 buf，返回写入的切片。
    /// 全软件字节级：负数取绝对值后，反复除以 10 收集余数（数字），最后反转。
    /// 不依赖 Zig 原生 i128/u128，不丢失精度。
    /// buf 需至少 41 字节（u128 最大 39 位 + 符号 + 空终止余量）。
    pub fn formatDecimal(self: Int, buf: []u8) []const u8 {
        const a = self.slice();
        if (isAllZero(a)) {
            buf[0] = '0';
            return buf[0..1];
        }

        // 提取绝对值到可变缓冲
        var mag: [16]u8 = [_]u8{0} ** 16;
        const n = a.len;
        @memcpy(mag[0..n], a);
        var negative = false;
        if (self.type.isSigned() and (mag[n - 1] & 0x80) != 0) {
            negative = true;
            negateBytesInPlace(mag[0..n]);
        }

        // 反复除以 10，收集数字（逆序）
        var pos: usize = 0;
        while (!isAllZero(mag[0..n])) {
            var rem: u16 = 0;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                const val: u16 = @as(u16, rem) * 256 + @as(u16, mag[i]);
                mag[i] = @truncate(val / 10);
                rem = val % 10;
            }
            buf[pos] = '0' + @as(u8, @intCast(rem));
            pos += 1;
        }
        if (negative) {
            buf[pos] = '-';
            pos += 1;
        }
        std.mem.reverse(u8, buf[0..pos]);
        return buf[0..pos];
    }

    // —— 浮点尾数运算辅助（S8+ 实现，供 float.zig 委托）——
    // fn addExtended(self: Int, other: Int) struct { result: Int, carry: bool }
    // fn addOne(self: Int) Int
    // fn leastSignificantBit(self: Int) u8
};

// —— 字块化运算辅助（用 u8/u16/u32/u64 作为字块替代逐字节循环）——
// loadWord/storeWord/mulU64ToU128/multiplyU64Schoolbook/U128 等基础原语从 wide.zig 导入。

/// 字块加法：r = a + b，返回 carry（1=无符号溢出）
fn addWordN(comptime Word: type, r: []u8, a: []const u8, b: []const u8) bool {
    const av = loadWord(Word, a);
    const bv = loadWord(Word, b);
    const sum, const carry = @addWithOverflow(av, bv);
    storeWord(Word, r, sum);
    return carry != 0;
}

/// 字块减法：r = a - b，返回 borrow（1=无符号下溢）
fn subWordN(comptime Word: type, r: []u8, a: []const u8, b: []const u8) bool {
    const av = loadWord(Word, a);
    const bv = loadWord(Word, b);
    const diff, const borrow = @subWithOverflow(av, bv);
    storeWord(Word, r, diff);
    return borrow != 0;
}

/// 字块取负：r = -a（补码取反加一，0 - a）
fn negateWordN(comptime Word: type, r: []u8, a: []const u8) void {
    const av = loadWord(Word, a);
    storeWord(Word, r, ~av +% 1);
}

/// 位运算种类（命名枚举，供 bitwisePortable / bitwiseWordN 共用，避免匿名枚举类型不匹配）
const BitwiseOp = enum { and_op, or_op, xor_op };

/// 字块位运算：r = a op b
fn bitwiseWordN(comptime Word: type, r: []u8, a: []const u8, b: []const u8, op: BitwiseOp) void {
    const av = loadWord(Word, a);
    const bv = loadWord(Word, b);
    storeWord(Word, r, switch (op) {
        .and_op => av & bv,
        .or_op => av | bv,
        .xor_op => av ^ bv,
    });
}

/// 字块取反：r = ~a
fn notWordN(comptime Word: type, r: []u8, a: []const u8) void {
    const av = loadWord(Word, a);
    storeWord(Word, r, ~av);
}

/// 字块左移：r = a << n（n >= bit_width 时 r = 0）
fn shiftLeftWordN(comptime Word: type, r: []u8, a: []const u8, n: u8) void {
    const av = loadWord(Word, a);
    const bit_width: u8 = @intCast(@bitSizeOf(Word));
    if (n >= bit_width) {
        storeWord(Word, r, 0);
        return;
    }
    const ShiftType = std.math.Log2Int(Word);
    storeWord(Word, r, av << @as(ShiftType, @intCast(n)));
}

/// 字块右移：r = a >> n。
/// arithmetic=true 时按补码符号位填充高位（算术右移），否则补 0（逻辑右移）。
/// n >= bit_width 时：算术右移且符号位为 1 → 全 1；否则全 0。
fn shiftRightWordN(comptime Word: type, r: []u8, a: []const u8, n: u8, arithmetic: bool) void {
    const av = loadWord(Word, a);
    const bit_width: u8 = @intCast(@bitSizeOf(Word));
    const sign_bit_set = (av >> @intCast(bit_width - 1)) != 0;
    if (n >= bit_width) {
        const fill: Word = if (arithmetic and sign_bit_set) ~@as(Word, 0) else 0;
        storeWord(Word, r, fill);
        return;
    }
    const ShiftType = std.math.Log2Int(Word);
    const sh: ShiftType = @intCast(n);
    const shifted = av >> sh;
    if (arithmetic and sign_bit_set and n > 0) {
        // 高 n 位填充符号位 1（n=0 时无需填充，shifted 已是原值）
        const fill_mask: Word = ~@as(Word, 0) << @intCast(bit_width - n);
        storeWord(Word, r, shifted | fill_mask);
        return;
    }
    storeWord(Word, r, shifted);
}

/// u64×u64→u128 与 u128*u128→u256 的 schoolbook 乘法基础原语从 wide.zig 导入。
/// multiplyPortable 使用 multiplyU64Schoolbook 完成 u128*u128→u256（4 次 64×64 部分积累加）。
/// mulU64ToU128 用 32 位半字 schoolbook，避免依赖 Zig u128 平台行为。

/// 从高位到低位比较（无符号语义，要求等长）。u64 字块化：每次比较 8 字节，
/// 命中差异立即返回；剩余不足 8 字节退化为逐字节。
fn compareBytes(a: []const u8, b: []const u8) std.math.Order {
    std.debug.assert(a.len == b.len);
    var i = a.len;
    while (i >= 8) {
        i -= 8;
        const av = loadWord(u64, a[i..][0..8]);
        const bv = loadWord(u64, b[i..][0..8]);
        if (av != bv) return if (av < bv) .lt else .gt;
    }
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return .eq;
}

/// 检查所有字节是否为 0。u64 字块化：每次检查 8 字节，命中非零立即返回。
fn isAllZero(s: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        if (loadWord(u64, s[i..][0..8]) != 0) return false;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] != 0) return false;
    }
    return true;
}

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
            const word = loadWord(u64, buf[i..][0..8]);
            const product = mulU64ToU128(word, @as(u64, base));
            const sum_lo, const c1 = @addWithOverflow(product.lo, carry);
            storeWord(u64, buf[i..][0..8], sum_lo);
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

/// 无符号 128/128 除法：a / b = quotient ... remainder（均 16 字节小端）。
/// 三条路径（按除数大小）：
///   1) b.hi != 0（除数 > 64 位）：U128 位级长除法，128 次迭代，每次 ~3 次 u64 操作。
///   2) b.hi == 0 且 d ≤ 2^32：2 次原生 u64 除法（divmod128by64），约 10 次 u64 操作。最快。
///   3) b.hi == 0 且 d > 2^32：位级长除法（64 次迭代，u64 操作），约 256 次 u64 操作。
/// 调用方保证 b != 0（除零由 divideWithRemainder 拦截）。
fn unsignedDivide128(a: []const u8, b: []const u8, quotient: []u8, remainder: []u8) void {
    std.debug.assert(a.len == 16 and b.len == 16);
    std.debug.assert(quotient.len == 16 and remainder.len >= 16);
    @memset(quotient, 0);
    @memset(remainder[0..16], 0);

    const av = U128.load(a);
    const bv = U128.load(b);
    std.debug.assert(!bv.isZero());

    // 路径 2/3：除数 fit u64（bv.hi == 0）
    if (bv.hi == 0) {
        const d: u64 = bv.lo;
        // 高 64 位：av.hi / d（av.hi 可能 ≥ d，q_hi 拿到 av.hi / d，余数 rem < d）
        const q_hi: u64 = av.hi / d;
        const rem: u64 = av.hi % d; // rem < d

        var q_lo: u64 = 0;
        var r_final: u64 = undefined;
        if (d <= 0x100000000) {
            // 路径 2：d ≤ 2^32，rem < d ≤ 2^32，divmod128by64 前置条件满足
            const result = divmod128by64(rem, av.lo, d);
            q_lo = result.quot;
            r_final = result.rem;
        } else {
            // 路径 3：d > 2^32，rem 可能 ≥ 2^32，位级长除法处理低 64 位（64 次迭代）
            r_final = rem;
            var bit: u8 = 64;
            while (bit > 0) {
                bit -= 1;
                const shift_amt: u6 = @intCast(bit);
                const a_bit: u1 = @truncate((av.lo >> shift_amt) & 1);
                // 检测 rem<<1 是否溢出（bit 63 在移位前是否为 1）
                const overflow = (r_final >> 63) != 0;
                r_final = (r_final << 1) | a_bit;
                // overflow 时真值 = r_final + 2^64 ≥ d 必减；否则比较 r_final 与 d
                // wrapping sub 在两种情形都给出正确的 u64 余数
                if (overflow or r_final >= d) {
                    r_final -%= d;
                    q_lo |= (@as(u64, 1) << shift_amt);
                }
            }
        }

        storeWord(u64, quotient[0..8], q_lo);
        storeWord(u64, quotient[8..16], q_hi);
        storeWord(u64, remainder[0..8], r_final);
        return;
    }

    // 路径 1：除数 > 64 位 → U128 位级二进制长除法（128 次迭代）
    var rem = U128.zero();
    var quot = U128.zero();
    var bit: u8 = 128;
    while (bit > 0) {
        bit -= 1;
        // rem 左移 1 位，最低位填入 a 的 bit 位
        const a_bit: u1 = if (av.testBit(bit)) 1 else 0;
        const shifted = rem.shiftLeft1WithBit(a_bit);
        rem = shifted.result;
        // 若 rem >= b：rem -= b，quotient 对应位置 1
        if (rem.compare(bv) != .lt) {
            const sub_result = rem.sub(bv);
            rem = sub_result.diff;
            quot = quot.orBit(bit);
        }
    }
    quot.store(quotient);
    rem.store(remainder);
}

/// 原地补码取负（取反加一）。u64 字块化：每次处理 8 字节，跨字块用 u64 carry；
/// 剩余不足 8 字节退化为逐字节。
fn negateBytesInPlace(s: []u8) void {
    var carry: u64 = 1;
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        const av = loadWord(u64, s[i..][0..8]);
        const inv = ~av;
        const sum, const overflow = @addWithOverflow(inv, carry);
        storeWord(u64, s[i..][0..8], sum);
        carry = overflow;
    }
    while (i < s.len) : (i += 1) {
        const inv: u8 = ~s[i];
        const sum, const overflow = @addWithOverflow(inv, @as(u8, @truncate(carry)));
        s[i] = sum;
        carry = overflow;
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

test "Int.divideTruncating i128 covers unsignedDivide128 three paths" {
    // 路径 2：除数 fit u64 且 d ≤ 2^32（divmod128by64 2 次原生除法）
    // 覆盖 i128 正/负被除数 × 正/负除数 四种符号组合，确保符号修正后仍命中路径 2。
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
