//! VM 共享：字面量软件解析（无 libc strtod/strtoll）。
//! 栈式与寄存器式 VM 共用。

const std = @import("std");
const value = @import("value");
const ast = @import("ast");

const Value = value.Value;

/// 软件解析整数字面量字符串 → Int（不依赖 u128/i128）。
/// 支持符号（+/-）、进制前缀（0x/0o/0b）、下划线。不处理类型后缀。
pub fn parseIntSoftware(raw: []const u8) ?value.Int {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    var base: u8 = 10;
    if (s.len > 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => { base = 16; s = s[2..]; },
            'o', 'O' => { base = 8; s = s[2..]; },
            'b', 'B' => { base = 2; s = s[2..]; },
            else => {},
        }
    }
    var digits: [128]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= digits.len) return null;
        digits[n] = c;
        n += 1;
    }
    if (n == 0) return null;

    var buf: [16]u8 = undefined;
    _ = value.int.parseUnsignedBytes(&buf, digits[0..n], base) orelse return null;

    const t = value.inferIntTypeBytes(&buf, negative);

    if (negative) {
        // 补码取负：~buf + 1（16 字节全量，自动符号扩展）
        var carry: u16 = 1;
        for (buf[0..16]) |*b| {
            const inv: u16 = ~b.*;
            const sum = inv + carry;
            b.* = @truncate(sum);
            carry = sum >> 8;
        }
    }

    return value.Int.fromBytes(t, &buf);
}

/// 解析整数字面量为 Value（镜像 eval.zig evalIntLiteral 的默认最小类型推断）。
/// 全软件：用 parseIntSoftware（不依赖 u128/i128）。
pub fn parseIntLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) !?Value {
    _ = allocator;

    if (lit.suffix) |s| {
        const target = value.IntType.fromName(s) orelse return null;
        // 有后缀：解析后用 coerceTo 检查范围
        const parsed = parseIntSoftware(lit.raw) orelse return null;
        const coerced = parsed.coerceTo(target) orelse return null;
        return Value.fromInt(coerced);
    }

    // 无后缀：类型推断
    const parsed = parseIntSoftware(lit.raw) orelse return null;
    return Value.fromInt(parsed);
}

/// 软件解析浮点字面量字符串 → Float(.f128)（不依赖 f128 原生算术）。
/// 支持符号、小数点、十进制指数（e/E）、下划线。
/// 算法：解析为 digits + decimal_exp，digits 解析为 u128 Int，fromInt 转 f128，
/// 再用快速幂乘/除 10^|decimal_exp|，最后应用符号。全精度，不丢精度。
pub fn parseFloatSoftware(raw: []const u8) ?value.Float {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;

    // 找 e/E 分割尾数和指数
    var e_pos: usize = s.len;
    for (s, 0..) |c, i| {
        if (c == 'e' or c == 'E') {
            e_pos = i;
            break;
        }
    }
    const mantissa_str = s[0..e_pos];
    const exp_str = if (e_pos < s.len) s[e_pos + 1 ..] else "";

    // 解析十进制指数
    var exp: i32 = 0;
    if (exp_str.len > 0) {
        exp = std.fmt.parseInt(i32, exp_str, 10) catch return null;
    }

    // 分割整数/小数部分
    var int_part: []const u8 = "";
    var frac_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, mantissa_str, '.')) |dot_pos| {
        int_part = mantissa_str[0..dot_pos];
        frac_part = mantissa_str[dot_pos + 1 ..];
    } else {
        int_part = mantissa_str;
    }

    // 合并数字（去除下划线），记录小数位数
    var digits_buf: [128]u8 = undefined;
    var digits_len: usize = 0;
    var frac_digit_count: i32 = 0;
    for (int_part) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') return null;
        if (digits_len >= digits_buf.len) return null;
        digits_buf[digits_len] = c;
        digits_len += 1;
    }
    for (frac_part) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') return null;
        if (digits_len >= digits_buf.len) return null;
        digits_buf[digits_len] = c;
        digits_len += 1;
        frac_digit_count += 1;
    }

    if (digits_len == 0) return null;

    // 十进制指数 = 字面指数 - 小数位数
    var decimal_exp = exp - frac_digit_count;

    // 去除前导零（不影响 decimal_exp）
    var start: usize = 0;
    while (start < digits_len and digits_buf[start] == '0') start += 1;
    if (start == digits_len) {
        // 全零：值为 0
        var z = value.Float.zero(.f128);
        if (negative) z = z.negate();
        return z;
    }

    // 去除尾随零（每去一个，decimal_exp += 1）
    var end: usize = digits_len;
    while (end > start and digits_buf[end - 1] == '0') {
        end -= 1;
        decimal_exp += 1;
    }

    const digits = digits_buf[start..end];

    // 解析 digits 为 Int(.u128)（u128 最大 39 位十进制）
    // 如果 digits 太长，截断到 39 位并四舍五入（f128 也只能保留 ~34 位有效十进制）
    var int_val: value.Int = undefined;
    if (digits.len <= 39) {
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
    } else {
        const trunc_len: usize = 39;
        var trunc_digits: [39]u8 = undefined;
        @memcpy(&trunc_digits, digits[0..trunc_len]);
        // 四舍五入：第 40 位 >= '5' 则进位
        if (digits[trunc_len] >= '5') {
            var i: usize = trunc_len;
            while (i > 0) {
                i -= 1;
                if (trunc_digits[i] < '9') {
                    trunc_digits[i] += 1;
                    break;
                }
                trunc_digits[i] = '0';
            }
            if (i == 0 and trunc_digits[0] == '0') {
                // 全进位：999...9 + 1 = 1000...0
                trunc_digits[0] = '1';
                decimal_exp += 1;
            }
        }
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, &trunc_digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
        decimal_exp += @as(i32, @intCast(digits.len - trunc_len));
    }

    // 转换为 f128
    var result = value.Float.fromInt(.f128, int_val);

    // 应用十进制指数（快速幂）
    if (decimal_exp != 0) {
        result = applyDecimalExp(result, decimal_exp);
        if (result.isInfinite() or result.isNan()) return null;
    }

    // 应用符号
    if (negative) result = result.negate();

    return result;
}

/// 计算 float × 10^exp（快速幂，软件 f128 乘除法，不依赖 f128 原生算术）。
fn applyDecimalExp(base: value.Float, exp: i32) value.Float {
    if (exp == 0) return base;
    const ten = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 10)));
    const abs_e: u32 = @intCast(if (exp < 0) -exp else exp);

    // 快速幂计算 10^abs_e
    var ten_pow = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 1)));
    var factor = ten;
    var bits = abs_e;
    while (bits > 0) {
        if (bits & 1 == 1) ten_pow = ten_pow.multiply(factor);
        bits >>= 1;
        if (bits > 0) factor = factor.multiply(factor);
    }

    if (exp > 0) {
        return base.multiply(ten_pow);
    } else {
        return base.divide(ten_pow);
    }
}

pub fn parseFloatLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) !?Value {
    _ = allocator;
    const fv = parseFloatSoftware(lit.raw) orelse return null;
    if (fv.isNan() or fv.isInfinite()) return null;
    if (lit.suffix) |s| {
        const t = value.FloatType.fromName(s) orelse return null;
        const result = fv.toFloatType(t);
        if (result.isInfinite()) return null; // 溢出
        return Value.fromFloat(result);
    }
    // 默认使用 f64
    return Value.fromFloat(fv.toFloatType(.f64));
}
