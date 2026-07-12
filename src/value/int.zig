//! 整数值类型模块
//!
//! 定义 Glue 语言的整数类型系统，支持 i8/i16/i32/i64/i128 和
//! u8/u16/u32/u64/u128 共十种宽度。Int 结构体以低 64 位 + 高 64 位
//! 表示 128 位以内整数，提供加减乘除、取模、位运算、移位、比较、
//! 类型转换和格式化等运算，所有运算均检测溢出。

const std = @import("std");
const wide = @import("wide.zig");
const U128 = wide.U128;
const mulU64ToU128 = wide.mulU64ToU128;

/// 整数类型枚举，涵盖有符号与无符号的 8/16/32/64/128 位变体
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

/// 是否为有符号类型
pub fn isSigned(self: Type) bool {
return switch (self) {
.i8, .i16, .i32, .i64, .i128 => true,
.u8, .u16, .u32, .u64, .u128 => false,
};
}

/// 该类型占用的字节数
pub fn byteLength(self: Type) u8 {
return switch (self) {
.i8, .u8 => 1,
.i16, .u16 => 2,
.i32, .u32 => 4,
.i64, .u64 => 8,
.i128, .u128 => 16,
};
}

/// 该类型的位宽
pub fn bitWidth(self: Type) u8 {
return switch (self) {
.i8, .u8 => 8,
.i16, .u16 => 16,
.i32, .u32 => 32,
.i64, .u64 => 64,
.i128, .u128 => 128,
};
}

/// 判断 u128 原始值是否落在该类型的合法范围内
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

/// 判断 16 字节小端序缓冲区表示的值是否落在该类型范围内
/// （通过检查有效字节之外的高位是否全为符号扩展或零）
pub fn inRangeBytes(self: Type, buf: *const [16]u8) bool {
const n = self.byteLength();
if (self.isSigned()) {
// 有符号：高位字节必须与符号位一致
const sign_byte: u8 = if ((buf[n - 1] & 0x80) != 0) 0xFF else 0x00;
for (buf[n..16]) |b| {
if (b != sign_byte) return false;
}
} else {
// 无符号：高位字节必须全为零
for (buf[n..16]) |b| {
if (b != 0x00) return false;
}
}
return true;
}

/// 从类型名字符串解析为 Type，无法识别时返回 null
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

/// 算术运算结果，携带结果值和是否溢出的标志
pub const OverflowResult = struct { result: Int, overflow: bool };

/// 除法运算结果，携带商和余数
pub const DivModResult = struct { quotient: Int, remainder: Int };

/// 将低 64 位按类型规范化：有符号类型做符号扩展，无符号类型做零截断
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

/// 对低 64 位的低 bits 位做符号扩展到完整 64 位
inline fn signExtend(lo: u64, bits: u8) u64 {
const shift_u8: u8 = 64 - bits;
const shift: u6 = @intCast(shift_u8);
const shifted: u64 = lo << shift;
const signed: i64 = @bitCast(shifted);
const extended: i64 = signed >> shift;
return @bitCast(extended);
}

/// 整数值，由类型标记和高低 64 位组成，128 位以内整数统一表示
pub const Int = struct {
type: Type,
lo: u64,
hi: u64,

/// 构造零值
pub inline fn zero(t: Type) Int {
return .{ .type = t, .lo = 0, .hi = 0 };
}

/// 从原生整数构造，自动处理有符号/无符号和 64/128 位宽度
pub fn fromNative(t: Type, v: anytype) Int {
const nbytes = t.byteLength();
if (nbytes <= 8) {
const V = @TypeOf(v);
const v_signed = @typeInfo(V) == .int and @typeInfo(V).int.signedness == .signed;
const lo: u64 = if (v_signed)
@bitCast(@as(i64, @intCast(v)))
else
@as(u64, @intCast(v));
return .{ .type = t, .lo = canonicalize(lo, t), .hi = 0 };
} else {
// 128 位：直接按字节拷贝
var result: Int = .{ .type = t, .lo = 0, .hi = 0 };
const src: [*]const u8 = @ptrCast(&v);
@memcpy(@as([*]u8, @ptrCast(&result.lo))[0..8], src[0..8]);
@memcpy(@as([*]u8, @ptrCast(&result.hi))[0..8], src[8..16]);
return result;
}
}

/// 从 U128 构造，不做范围检查（调用方需保证合法）
pub fn fromU128Unchecked(t: Type, val: U128) Int {
if (t.byteLength() <= 8) {
return .{ .type = t, .lo = canonicalize(val.lo, t), .hi = 0 };
}
return .{ .type = t, .lo = val.lo, .hi = val.hi };
}

/// 转换为原生整数类型
pub fn toNative(self: Int, comptime T: type) T {
const sz = @sizeOf(T);
if (sz <= 8) {
const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
const truncated: UT = @truncate(self.lo);
return @bitCast(truncated);
} else {
var result: T = undefined;
const dst: [*]u8 = @ptrCast(&result);
@memcpy(dst[0..8], @as([*]const u8, @ptrCast(&self.lo))[0..8]);
@memcpy(dst[8..16], @as([*]const u8, @ptrCast(&self.hi))[0..8]);
return result;
}
}

/// 序列化为 16 字节小端序缓冲区，高位用符号扩展或零填充
pub fn toBytes(self: Int, buf: *[16]u8) void {
const n = self.type.byteLength();
if (n <= 8) {
std.mem.writeInt(u64, buf[0..8], self.lo, .little);
const fill: u8 = if (self.type.isSigned() and (self.lo >> 63) & 1 == 1) 0xFF else 0x00;
@memset(buf[8..16], fill);
} else {
std.mem.writeInt(u64, buf[0..8], self.lo, .little);
std.mem.writeInt(u64, buf[8..16], self.hi, .little);
}
}

/// 从 16 字节小端序缓冲区反序列化
pub fn fromBytes(t: Type, buf: *const [16]u8) Int {
const lo = std.mem.readInt(u64, buf[0..8], .little);
const hi = std.mem.readInt(u64, buf[8..16], .little);
if (t.byteLength() <= 8) {
return .{ .type = t, .lo = canonicalize(lo, t), .hi = 0 };
}
return .{ .type = t, .lo = lo, .hi = hi };
}

/// 比较两个整数的大小，返回 lt/gt/eq
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
// 有符号比较：先按符号位判断正负
if (signed) {
const a_neg = (self.hi >> 63) != 0;
const b_neg = (other.hi >> 63) != 0;
if (a_neg != b_neg) return if (a_neg) .lt else .gt;
}
return av.compare(bv);
}
}

// ── 算术运算 ──

/// 加法，返回结果与溢出标志
pub inline fn add(self: Int, other: Int) OverflowResult {
std.debug.assert(self.type == other.type);
return addPortable(self, other);
}

/// 加法的可移植实现：64 位用原生溢出检测，128 位用 U128 运算
inline fn addPortable(self: Int, other: Int) OverflowResult {
const t = self.type;
const signed = t.isSigned();
if (t.byteLength() <= 8) {
const sum, const carry = @addWithOverflow(self.lo, other.lo);
const canon = canonicalize(sum, t);
const sign_sh: u6 = @intCast(t.bitWidth() - 1);
var overflow: bool = undefined;
// 有符号溢出：两操作数同号但结果异号
if (signed) {
const a_sign = (self.lo >> sign_sh) & 1;
const b_sign = (other.lo >> sign_sh) & 1;
const r_sign = (canon >> sign_sh) & 1;
overflow = (a_sign == b_sign) and (r_sign != a_sign);
} else {
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

/// 减法，返回结果与溢出标志
pub inline fn subtract(self: Int, other: Int) OverflowResult {
std.debug.assert(self.type == other.type);
return subtractPortable(self, other);
}

/// 减法的可移植实现
inline fn subtractPortable(self: Int, other: Int) OverflowResult {
const t = self.type;
const signed = t.isSigned();
if (t.byteLength() <= 8) {
const diff, const borrow = @subWithOverflow(self.lo, other.lo);
const canon = canonicalize(diff, t);
const sign_sh: u6 = @intCast(t.bitWidth() - 1);
var overflow: bool = undefined;
// 有符号溢出：两操作数异号但结果与被减数异号
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

/// 判断是否为负数（仅对有符号类型有意义）
pub inline fn isNegative(self: Int) bool {
if (!self.type.isSigned()) return false;
if (self.type.byteLength() <= 8) {
const sign_sh: u6 = @intCast(self.type.bitWidth() - 1);
return (self.lo >> sign_sh) & 1 == 1;
}
return (self.hi >> 63) & 1 == 1;
}

/// 二补码取负
pub inline fn negate(self: Int) Int {
const t = self.type;
if (t.byteLength() <= 8) {
return .{ .type = t, .lo = canonicalize(0 -% self.lo, t), .hi = 0 };
}
const av = U128{ .hi = self.hi, .lo = self.lo };
const neg = av.negate();
return .{ .type = t, .lo = neg.lo, .hi = neg.hi };
}

/// 乘法，返回结果与溢出标志
pub fn multiply(self: Int, other: Int) OverflowResult {
std.debug.assert(self.type == other.type);
return multiplyPortable(self, other);
}

/// 乘法的可移植实现：窄宽度用原生运算，128 位用 U256 中间结果
fn multiplyPortable(self: Int, other: Int) OverflowResult {
const t = self.type;
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
if (t == .i128) {
const av = U128{ .hi = self.hi, .lo = self.lo };
const bv = U128{ .hi = other.hi, .lo = other.lo };
const a_neg = (self.hi >> 63) != 0;
const b_neg = (other.hi >> 63) != 0;
const result_neg = a_neg != b_neg;
const abs_a = if (a_neg) av.negate() else av;
const abs_b = if (b_neg) bv.negate() else bv;
const product: wide.U256 = abs_a.multiply(abs_b);
const bit_127_set = (product.lo.hi >> 63) != 0;
const lower_nonzero = (product.lo.hi & 0x7FFFFFFFFFFFFFFF) != 0 or product.lo.lo != 0;
const overflow = if (result_neg)
bit_127_set and lower_nonzero
else
bit_127_set;
const final = if (result_neg) product.lo.negate() else product.lo;
return .{ .result = .{ .type = t, .lo = final.lo, .hi = final.hi }, .overflow = overflow };
}
const av = U128{ .hi = self.hi, .lo = self.lo };
const bv = U128{ .hi = other.hi, .lo = other.lo };
const product: wide.U256 = av.multiply(bv);
const overflow = !product.hi.isZero();
return .{ .result = .{ .type = t, .lo = product.lo.lo, .hi = product.lo.hi }, .overflow = overflow };
}
/// 截断除法，返回商
pub fn divideTruncating(self: Int, other: Int) error{DivideByZero}!Int {
const r = try self.divideWithRemainder(other);
return r.quotient;
}

/// 取余，返回余数
pub fn remainder(self: Int, other: Int) error{DivideByZero}!Int {
const r = try self.divideWithRemainder(other);
return r.remainder;
}

/// 带余除法的入口：检查除零和最小值除以 -1 的边界情况
fn divideWithRemainder(self: Int, other: Int) error{DivideByZero}!DivModResult {
std.debug.assert(self.type == other.type);
const t = self.type;
const signed = t.isSigned();
if (other.lo == 0 and (t.byteLength() > 8) and other.hi == 0) return error.DivideByZero;
if (t.byteLength() <= 8 and other.lo == 0) return error.DivideByZero;
if (signed) {
// 检测最小有符号整数除以 -1（结果溢出，返回自身）
const is_min_int = if (t.byteLength() <= 8) blk: {
const sign_sh: u6 = @intCast(t.bitWidth() - 1);
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

/// 带余除法的可移植实现：窄宽度用原生运算，128 位转换为无符号除法后修正符号
fn divideWithRemainderPortable(self: Int, other: Int) DivModResult {
const t = self.type;
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
// i128：取绝对值做无符号除法，再按符号修正
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
// u128：直接无符号除法
const av = U128{ .hi = self.hi, .lo = self.lo };
const bv = U128{ .hi = other.hi, .lo = other.lo };
const div_result = unsignedDivide128(av, bv);
return .{
.quotient = .{ .type = t, .lo = div_result.quotient.lo, .hi = div_result.quotient.hi },
.remainder = .{ .type = t, .lo = div_result.remainder.lo, .hi = div_result.remainder.hi },
};
}

// ── 位运算 ──

/// 按位与
pub fn bitwiseAnd(self: Int, other: Int) Int {
std.debug.assert(self.type == other.type);
return bitwisePortable(self, other, .and_op);
}

/// 按位或
pub fn bitwiseOr(self: Int, other: Int) Int {
std.debug.assert(self.type == other.type);
return bitwisePortable(self, other, .or_op);
}

/// 按位异或
pub fn bitwiseXor(self: Int, other: Int) Int {
std.debug.assert(self.type == other.type);
return bitwisePortable(self, other, .xor_op);
}

/// 位运算的可移植实现，按宽度分派
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

/// 按位取反
pub fn bitwiseNot(self: Int) Int {
const t = self.type;
if (t.byteLength() <= 8) {
return .{ .type = t, .lo = canonicalize(~self.lo, t), .hi = 0 };
}
return .{ .type = t, .lo = ~self.lo, .hi = ~self.hi };
}

/// 左移 n 位，超出位宽返回零
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

/// 右移 n 位，有符号类型执行算术右移（符号位扩展）
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
/// 类型转换：成功返回转换后的值，超出目标范围返回 null
pub inline fn coerceTo(self: Int, target: Type) ?Int {
if (self.type == target) return self;
var buf: [16]u8 = undefined;
self.toBytes(&buf);
if (!target.inRangeBytes(&buf)) return null;
return fromBytes(target, &buf);
}

/// 判断是否为零
pub inline fn isZero(self: Int) bool {
if (self.type.byteLength() <= 8) return self.lo == 0;
return self.lo == 0 and self.hi == 0;
}

/// 格式化为十进制字符串，写入 buf 并返回有效切片
pub fn formatDecimal(self: Int, buf: []u8) []const u8 {
if (self.type.byteLength() <= 8) {
if (self.lo == 0) {
buf[0] = '0';
return buf[0..1];
}
var val: u64 = self.lo;
var negative = false;
// 有符号负数：取绝对值并标记负号
if (self.type.isSigned() and (self.lo >> 63) & 1 == 1) {
negative = true;
val = 0 -% val;
}
var pos: usize = 0;
// 逐位提取，逆序写入后翻转
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
// 128 位路径
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

/// 位运算操作类型标记
const BitwiseOp = enum { and_op, or_op, xor_op };

// ── 模块级工具函数 ──

/// 将字符串按指定进制解析为无符号整数，写入 16 字节小端序缓冲区
/// 返回有效字节数，解析失败（空串、非法字符、溢出）返回 null
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
// 逐字符累加：buf = buf * base + digit
var carry: u64 = digit;
var i: usize = 0;
while (i < 16) : (i += 8) {
const word = std.mem.readInt(u64, buf[i..][0..8], .little);
const product = mulU64ToU128(word, @as(u64, base));
const sum_lo, const c1 = @addWithOverflow(product.lo, carry);
std.mem.writeInt(u64, buf[i..][0..8], sum_lo, .little);
carry = product.hi +% c1;
}
if (carry != 0) return null;
}
// 计算有效字节数（去除前导零字节）
var n: u8 = 16;
while (n > 1 and buf[n - 1] == 0) n -= 1;
return n;
}

/// 128 位除以 64 位的快速路径：将 128 位被除数拆为高低两部分逐步除
fn divmod128by64(hi: u64, lo: u64, d: u64) struct { quot: u64, rem: u64 } {
std.debug.assert(d != 0);
std.debug.assert(hi < d);
std.debug.assert(hi < 0x100000000);
const combined_hi: u64 = (hi << 32) | (lo >> 32);
const q_hi32: u64 = combined_hi / d;
const r2: u64 = combined_hi % d;
const combined_lo: u64 = (r2 << 32) | (lo & 0xFFFFFFFF);
const q_lo32: u64 = combined_lo / d;
const r_final: u64 = combined_lo % d;
return .{ .quot = (q_hi32 << 32) | q_lo32, .rem = r_final };
}

/// 无符号 128 位除法，返回商和余数
/// 除数为 64 位时走快速路径，否则用逐位长除法
fn unsignedDivide128(a: U128, b: U128) struct { quotient: U128, remainder: U128 } {
std.debug.assert(!b.isZero());
if (b.hi == 0) {
// 除数仅 64 位：直接用原生除法
const d: u64 = b.lo;
const q_hi: u64 = a.hi / d;
const rem: u64 = a.hi % d;
var q_lo: u64 = 0;
var r_final: u64 = undefined;
if (d <= 0x100000000) {
// 除数不超过 32 位：用 divmod128by64 快速路径
const result = divmod128by64(rem, a.lo, d);
q_lo = result.quot;
r_final = result.rem;
} else {
// 除数超过 32 位：逐位长除法
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
// 除数超过 64 位：128 位逐位长除法
var rem = U128.zero();
var quot = U128.zero();
var bit: u8 = 128;
while (bit > 0) {
bit -= 1;
const a_bit: u1 = if (a.testBit(bit)) 1 else 0;
const shifted = rem.shiftLeft1WithBit(a_bit);
rem = shifted.result;
if (rem.compare(b) != .lt) {
const sub_result = rem.sub(b);
rem = sub_result.diff;
quot = quot.orBit(bit);
}
}
return .{ .quotient = quot, .remainder = rem };
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
try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, 0)))));
try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, 127)))));
try std.testing.expect(Type.i8.inRange(@as(u128, @bitCast(@as(i128, -128)))));
try std.testing.expect(!Type.i8.inRange(@as(u128, @bitCast(@as(i128, 128)))));
try std.testing.expect(!Type.i8.inRange(@as(u128, @bitCast(@as(i128, -129)))));
try std.testing.expect(Type.u8.inRange(0));
try std.testing.expect(Type.u8.inRange(255));
try std.testing.expect(!Type.u8.inRange(256));
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
try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, 5)).compare(Int.fromNative(.i32, @as(i32, 3))));
try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, 3)).compare(Int.fromNative(.i32, @as(i32, 5))));
try std.testing.expectEqual(.eq, Int.fromNative(.i32, @as(i32, 5)).compare(Int.fromNative(.i32, @as(i32, 5))));
try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, -5)).compare(Int.fromNative(.i32, @as(i32, -3))));
try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, -3)).compare(Int.fromNative(.i32, @as(i32, -5))));
try std.testing.expectEqual(.eq, Int.fromNative(.i32, @as(i32, -5)).compare(Int.fromNative(.i32, @as(i32, -5))));
try std.testing.expectEqual(.lt, Int.fromNative(.i32, @as(i32, -1)).compare(Int.fromNative(.i32, @as(i32, 1))));
try std.testing.expectEqual(.gt, Int.fromNative(.i32, @as(i32, 1)).compare(Int.fromNative(.i32, @as(i32, -1))));
try std.testing.expectEqual(.lt, Int.fromNative(.i8, @as(i8, std.math.minInt(i8))).compare(Int.fromNative(.i8, @as(i8, std.math.maxInt(i8)))));
try std.testing.expectEqual(.gt, Int.fromNative(.i8, @as(i8, std.math.maxInt(i8))).compare(Int.fromNative(.i8, @as(i8, std.math.minInt(i8)))));
try std.testing.expectEqual(.lt, Int.fromNative(.u32, @as(u32, 3)).compare(Int.fromNative(.u32, @as(u32, 5))));
try std.testing.expectEqual(.gt, Int.fromNative(.u32, @as(u32, 0xFFFFFFFF)).compare(Int.fromNative(.u32, @as(u32, 0))));
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
{
var buf: [16]u8 = undefined;
const v = Int.fromNative(.i32, @as(i32, -1));
v.toBytes(&buf);
try std.testing.expectEqual(@as(u8, 4), v.type.byteLength());
for (buf) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);
const back = Int.fromBytes(.i32, &buf);
try std.testing.expectEqual(.eq, v.compare(back));
}
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
{
var buf: [16]u8 = undefined;
const v = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
v.toBytes(&buf);
try std.testing.expectEqual(@as(u8, 16), v.type.byteLength());
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
{
const a = Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)));
const r = a.add(Int.fromNative(.i32, @as(i32, 1)));
const native_result, const native_ovf = @addWithOverflow(@as(i32, std.math.maxInt(i32)), @as(i32, 1));
try std.testing.expectEqual(native_result, r.result.toNative(i32));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
{
const a = Int.fromNative(.i64, @as(i64, std.math.minInt(i64)));
const r = a.add(Int.fromNative(.i64, @as(i64, -1)));
const native_result, const native_ovf = @addWithOverflow(@as(i64, std.math.minInt(i64)), @as(i64, -1));
try std.testing.expectEqual(native_result, r.result.toNative(i64));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
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
{
const a = Int.fromNative(.i128, @as(i128, std.math.minInt(i128)));
const r = a.subtract(Int.fromNative(.i128, @as(i128, 1)));
const native_result, const native_ovf = @subWithOverflow(@as(i128, std.math.minInt(i128)), @as(i128, 1));
try std.testing.expectEqual(native_result, r.result.toNative(i128));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
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
try std.testing.expect(!Int.fromNative(.u8, @as(u8, 255)).isNegative());
try std.testing.expect(!Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).isNegative());
try std.testing.expect(Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).isNegative());
try std.testing.expect(!Int.fromNative(.i128, @as(i128, std.math.maxInt(i128))).isNegative());
}
test "Int.negate" {
try std.testing.expectEqual(@as(i8, -5), Int.fromNative(.i8, @as(i8, 5)).negate().toNative(i8));
try std.testing.expectEqual(@as(i8, 5), Int.fromNative(.i8, @as(i8, -5)).negate().toNative(i8));
try std.testing.expectEqual(@as(i8, 0), Int.fromNative(.i8, @as(i8, 0)).negate().toNative(i8));
try std.testing.expectEqual(std.math.minInt(i8), Int.fromNative(.i8, @as(i8, std.math.minInt(i8))).negate().toNative(i8));
try std.testing.expectEqual(std.math.minInt(i64), Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).negate().toNative(i64));
try std.testing.expectEqual(std.math.minInt(i128), Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).negate().toNative(i128));
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
{
const a = Int.fromNative(.i32, @as(i32, 1 << 16));
const r = a.multiply(Int.fromNative(.i32, @as(i32, 1 << 16)));
const native_result, const native_ovf = @mulWithOverflow(@as(i32, 1 << 16), @as(i32, 1 << 16));
try std.testing.expectEqual(native_result, r.result.toNative(i32));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
{
const a = Int.fromNative(.i64, @as(i64, std.math.maxInt(i64)));
const r = a.multiply(Int.fromNative(.i64, @as(i64, 2)));
const native_result, const native_ovf = @mulWithOverflow(@as(i64, std.math.maxInt(i64)), @as(i64, 2));
try std.testing.expectEqual(native_result, r.result.toNative(i64));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
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
{
const a = Int.fromNative(.u128, @as(u128, std.math.maxInt(u128)));
const r = a.multiply(Int.fromNative(.u128, @as(u128, 2)));
const native_result, const native_ovf = @mulWithOverflow(@as(u128, std.math.maxInt(u128)), @as(u128, 2));
try std.testing.expectEqual(native_result, r.result.toNative(u128));
try std.testing.expectEqual(native_ovf != 0, r.overflow);
}
}
test "Int.divideTruncating/remainder match native @divTrunc/@rem" {
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
{
const a = Int.fromNative(.i64, @as(i64, std.math.minInt(i64)));
const q1 = try a.divideTruncating(Int.fromNative(.i64, @as(i64, 1)));
try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), q1.toNative(i64));
const q2 = try a.divideTruncating(Int.fromNative(.i64, @as(i64, -1)));
try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), q2.toNative(i64));
const r2 = try a.remainder(Int.fromNative(.i64, @as(i64, -1)));
try std.testing.expectEqual(@as(i64, 0), r2.toNative(i64));
}
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
{
const cases = [_]struct { a: i128, b: i128 }{
.{ .a = std.math.maxInt(i128), .b = 7 },
.{ .a = std.math.minInt(i128) + 1, .b = 7 },
.{ .a = std.math.maxInt(i128), .b = -7 },
.{ .a = std.math.minInt(i128) + 1, .b = -7 },
.{ .a = std.math.maxInt(i128), .b = 1 },
.{ .a = std.math.maxInt(i128), .b = 0x100000000 },
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
{
const cases = [_]struct { a: i128, b: i128 }{
.{ .a = std.math.maxInt(i128), .b = @as(i128, 1) << 60 },
.{ .a = std.math.minInt(i128) + 1, .b = @as(i128, 1) << 60 },
.{ .a = std.math.maxInt(i128), .b = -(@as(i128, 1) << 60) },
.{ .a = std.math.minInt(i128) + 1, .b = -(@as(i128, 1) << 60) },
.{ .a = std.math.maxInt(i128), .b = @as(i128, 1) << 33 },
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
{
const cases = [_]struct { a: u128, b: u128 }{
.{ .a = std.math.maxInt(u128), .b = @as(u128, 1) << 100 },
.{ .a = std.math.maxInt(u128), .b = @as(u128, 1) << 127 },
.{ .a = std.math.maxInt(u128), .b = std.math.maxInt(u128) },
.{ .a = std.math.maxInt(u128) - 1, .b = std.math.maxInt(u128) },
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
{
var n: u8 = 0;
while (n < 64) : (n += 1) {
const shift: u6 = @intCast(n);
const expected: i64 = @as(i64, 1) << shift;
try std.testing.expectEqual(expected, Int.fromNative(.i64, @as(i64, 1)).shiftLeft(n).toNative(i64));
}
}
{
try std.testing.expectEqual(@as(i128, 1) << 100, Int.fromNative(.i128, @as(i128, 1)).shiftLeft(100).toNative(i128));
try std.testing.expectEqual(@as(i128, 0), Int.fromNative(.i128, @as(i128, 1)).shiftLeft(128).toNative(i128));
}
}
test "Int.shiftRight matches native >> (arithmetic for signed, logical for unsigned)" {
const i8_cases = [_]i8{ 0, 1, -1, 5, -5, 64, -64, 127, -128 };
for (i8_cases) |av| {
var n: u8 = 0;
while (n < 8) : (n += 1) {
const shift: u3 = @intCast(n);
const expected: i8 = @as(i8, av) >> shift;
const actual = Int.fromNative(.i8, @as(i8, av)).shiftRight(n).toNative(i8);
try std.testing.expectEqual(expected, actual);
}
const expected_big: i8 = if (av < 0) -1 else 0;
try std.testing.expectEqual(expected_big, Int.fromNative(.i8, @as(i8, av)).shiftRight(8).toNative(i8));
try std.testing.expectEqual(expected_big, Int.fromNative(.i8, @as(i8, av)).shiftRight(16).toNative(i8));
}
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
{
var n: u8 = 0;
while (n < 64) : (n += 1) {
const shift: u6 = @intCast(n);
const expected: i64 = @as(i64, std.math.minInt(i64)) >> shift;
try std.testing.expectEqual(expected, Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).shiftRight(n).toNative(i64));
}
try std.testing.expectEqual(@as(i64, -1), Int.fromNative(.i64, @as(i64, std.math.minInt(i64))).shiftRight(64).toNative(i64));
}
{
try std.testing.expectEqual(@as(i128, std.math.maxInt(i128)) >> 100, Int.fromNative(.i128, @as(i128, std.math.maxInt(i128))).shiftRight(100).toNative(i128));
try std.testing.expectEqual(@as(i128, -1), Int.fromNative(.i128, @as(i128, std.math.minInt(i128))).shiftRight(128).toNative(i128));
}
{
try std.testing.expectEqual(@as(u128, std.math.maxInt(u128)) >> 100, Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).shiftRight(100).toNative(u128));
try std.testing.expectEqual(@as(u128, 0), Int.fromNative(.u128, @as(u128, std.math.maxInt(u128))).shiftRight(128).toNative(u128));
}
}
test "Int.coerceTo same type returns self" {
const v = Int.fromNative(.i32, @as(i32, 42));
const r = v.coerceTo(.i32).?;
try std.testing.expectEqual(@as(i32, 42), r.toNative(i32));
}
test "Int.coerceTo widening always succeeds" {
{
const v = Int.fromNative(.i8, @as(i8, -1));
try std.testing.expectEqual(@as(i16, -1), v.coerceTo(.i16).?.toNative(i16));
try std.testing.expectEqual(@as(i32, -1), v.coerceTo(.i32).?.toNative(i32));
try std.testing.expectEqual(@as(i64, -1), v.coerceTo(.i64).?.toNative(i64));
try std.testing.expectEqual(@as(i128, -1), v.coerceTo(.i128).?.toNative(i128));
}
{
const v = Int.fromNative(.u8, @as(u8, 200));
try std.testing.expectEqual(@as(u16, 200), v.coerceTo(.u16).?.toNative(u16));
try std.testing.expectEqual(@as(u32, 200), v.coerceTo(.u32).?.toNative(u32));
try std.testing.expectEqual(@as(u64, 200), v.coerceTo(.u64).?.toNative(u64));
try std.testing.expectEqual(@as(u128, 200), v.coerceTo(.u128).?.toNative(u128));
}
{
try std.testing.expectEqual(@as(i16, 127), Int.fromNative(.i8, @as(i8, 127)).coerceTo(.i16).?.toNative(i16));
try std.testing.expectEqual(@as(i16, -128), Int.fromNative(.i8, @as(i8, -128)).coerceTo(.i16).?.toNative(i16));
}
{
try std.testing.expectEqual(@as(u16, 255), Int.fromNative(.u8, @as(u8, 255)).coerceTo(.u16).?.toNative(u16));
}
}
test "Int.coerceTo narrowing in-range succeeds" {
{
const v = Int.fromNative(.i32, @as(i32, 100));
try std.testing.expectEqual(@as(i8, 100), v.coerceTo(.i8).?.toNative(i8));
}
{
try std.testing.expectEqual(@as(i8, 127), Int.fromNative(.i32, @as(i32, 127)).coerceTo(.i8).?.toNative(i8));
try std.testing.expectEqual(@as(i8, -128), Int.fromNative(.i32, @as(i32, -128)).coerceTo(.i8).?.toNative(i8));
}
{
const v = Int.fromNative(.i64, @as(i64, 1_000_000));
try std.testing.expectEqual(@as(i32, 1_000_000), v.coerceTo(.i32).?.toNative(i32));
}
{
const v = Int.fromNative(.u32, @as(u32, 200));
try std.testing.expectEqual(@as(u8, 200), v.coerceTo(.u8).?.toNative(u8));
}
}
test "Int.coerceTo narrowing out-of-range returns null" {
{
const v = Int.fromNative(.i32, @as(i32, 128));
try std.testing.expect(v.coerceTo(.i8) == null);
}
{
const v = Int.fromNative(.i32, @as(i32, -129));
try std.testing.expect(v.coerceTo(.i8) == null);
}
{
const v = Int.fromNative(.i64, @as(i64, std.math.maxInt(i32) + 1));
try std.testing.expect(v.coerceTo(.i32) == null);
}
{
const v = Int.fromNative(.u32, @as(u32, 256));
try std.testing.expect(v.coerceTo(.u8) == null);
}
{
const v = Int.fromNative(.i128, @as(i128, std.math.maxInt(i64) + 1));
try std.testing.expect(v.coerceTo(.i64) == null);
}
{
const v = Int.fromNative(.i128, @as(i128, std.math.minInt(i64) - 1));
try std.testing.expect(v.coerceTo(.i64) == null);
}
{
const v = Int.fromNative(.u128, @as(u128, std.math.maxInt(i64) + 1));
try std.testing.expect(v.coerceTo(.i64) == null);
}
}
test "Int.coerceTo cross-sign narrowing" {
{
const v = Int.fromNative(.i32, @as(i32, -1));
try std.testing.expect(v.coerceTo(.u32) == null);
}
{
const v = Int.fromNative(.i32, @as(i32, 42));
try std.testing.expectEqual(@as(u32, 42), v.coerceTo(.u32).?.toNative(u32));
}
{
const v = Int.fromNative(.u32, @as(u32, std.math.maxInt(i32) + 1));
try std.testing.expect(v.coerceTo(.i32) == null);
}
{
const v = Int.fromNative(.u32, @as(u32, 100));
try std.testing.expectEqual(@as(i32, 100), v.coerceTo(.i32).?.toNative(i32));
}
}
