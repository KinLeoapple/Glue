//! 整数与浮点字面量的软件解析。
//!
//! 提供 parseIntSoftware / parseFloatSoftware 两个核心函数，
//! 支持 2/8/10/16 进制、下划线分隔、类型后缀及大数推断，
//! 供编译器将 AST 字面量节点转换为运行期 Value。

const std = @import("std");
const value = @import("value");
const ast = @import("ast");

const Value = value.Value;

/// 以软件方式解析整数字面量，支持符号、进制前缀与下划线。
/// 返回推断出的 Int 类型，无法解析时返回 null。
pub fn parseIntSoftware(raw: []const u8) ?value.Int {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    // 识别进制前缀 0x/0o/0b
    var base: u8 = 10;
    if (s.len > 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => { base = 16; s = s[2..]; },
            'o', 'O' => { base = 8; s = s[2..]; },
            'b', 'B' => { base = 2; s = s[2..]; },
            else => {},
        }
    }
    // 去除下划线分隔符
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
    // 负数：对补码取反再加一
    if (negative) {
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

/// 解析带后缀的整数字面量 AST 节点，返回对应的 Value。
/// 无后缀时按推断类型返回；有后缀时强转为指定类型。
pub fn parseIntLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) !?Value {
    _ = allocator;
    if (lit.suffix) |s| {
        const target = value.IntType.fromName(s) orelse return null;
        const parsed = parseIntSoftware(lit.raw) orelse return null;
        const coerced = parsed.coerceTo(target) orelse return null;
        return Value.fromInt(coerced);
    }
    const parsed = parseIntSoftware(lit.raw) orelse return null;
    return Value.fromInt(parsed);
}

/// 以软件方式解析浮点字面量，支持十进制科学计数法。
/// 内部使用 f128 计算，可安全处理大数与精度需求。
pub fn parseFloatSoftware(raw: []const u8) ?value.Float {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;

    // 分离尾数与指数部分
    var e_pos: usize = s.len;
    for (s, 0..) |c, i| {
        if (c == 'e' or c == 'E') {
            e_pos = i;
            break;
        }
    }
    const mantissa_str = s[0..e_pos];
    const exp_str = if (e_pos < s.len) s[e_pos + 1 ..] else "";
    var exp: i32 = 0;
    if (exp_str.len > 0) {
        exp = std.fmt.parseInt(i32, exp_str, 10) catch return null;
    }

    // 拆分整数与小数部分
    var int_part: []const u8 = "";
    var frac_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, mantissa_str, '.')) |dot_pos| {
        int_part = mantissa_str[0..dot_pos];
        frac_part = mantissa_str[dot_pos + 1 ..];
    } else {
        int_part = mantissa_str;
    }

    // 收集有效数字并统计小数位数
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

    var decimal_exp = exp - frac_digit_count;

    // 去除前导零
    var start: usize = 0;
    while (start < digits_len and digits_buf[start] == '0') start += 1;
    if (start == digits_len) {
        // 全零：直接返回带符号的 0
        var z = value.Float.zero(.f128);
        if (negative) z = z.negate();
        return z;
    }

    // 去除尾随零并相应调整指数
    var end: usize = digits_len;
    while (end > start and digits_buf[end - 1] == '0') {
        end -= 1;
        decimal_exp += 1;
    }
    const digits = digits_buf[start..end];

    // 将数字串转为整数（超过 39 位时截断并四舍五入）
    var int_val: value.Int = undefined;
    if (digits.len <= 39) {
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
    } else {
        const trunc_len: usize = 39;
        var trunc_digits: [39]u8 = undefined;
        @memcpy(&trunc_digits, digits[0..trunc_len]);
        // 对截断后的尾数做四舍五入
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
                trunc_digits[0] = '1';
                decimal_exp += 1;
            }
        }
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, &trunc_digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
        decimal_exp += @as(i32, @intCast(digits.len - trunc_len));
    }

    var result = value.Float.fromInt(.f128, int_val);
    if (decimal_exp != 0) {
        result = applyDecimalExp(result, decimal_exp);
        if (result.isInfinite() or result.isNan()) return null;
    }
    if (negative) result = result.negate();
    return result;
}

/// 通过快速幂将 base 乘以 10^exp，用于浮点小数点对齐。
fn applyDecimalExp(base: value.Float, exp: i32) value.Float {
    if (exp == 0) return base;
    const ten = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 10)));
    const abs_e: u32 = @intCast(if (exp < 0) -exp else exp);
    var ten_pow = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 1)));
    var factor = ten;
    var bits = abs_e;
    // 二进制快速幂
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

/// 解析带后缀的浮点字面量 AST 节点，返回对应的 Value。
/// NaN/Inf 视为非法返回 null；无后缀时降为 f64。
pub fn parseFloatLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) !?Value {
    _ = allocator;
    const fv = parseFloatSoftware(lit.raw) orelse return null;
    if (fv.isNan() or fv.isInfinite()) return null;
    if (lit.suffix) |s| {
        const t = value.FloatType.fromName(s) orelse return null;
        const result = fv.toFloatType(t);
        if (result.isInfinite()) return null;
        return Value.fromFloat(result);
    }
    return Value.fromFloat(fv.toFloatType(.f64));
}
