//! Glue 语言模式匹配求值
//!
//! 处理模式匹配逻辑，支持：
//! - 通配符模式（_）
//! - 字面量模式（int, float, bool, char, string, null）
//! - 变量绑定模式
//! - 构造器模式（Ok, Error 等 ADT 构造器）
//! - 记录模式（(field: pattern, ...)）
//! - 或模式（pattern1 | pattern2）
//!
//! 注意：守卫模式（pattern if condition）需要调用 evalExpr，
//! 因此守卫求值由 eval.zig 中的 Evaluator 处理，此处不涉及。

const std = @import("std");
const value = @import("value");
const env = @import("env");
const ast = @import("ast");

/// 模式匹配错误集
pub const PatternError = value.EvalError || value.ControlFlow;

/// 将模式与值进行匹配，在环境中绑定变量。
/// 返回 true 表示匹配成功。
pub fn matchPattern(pattern: *const ast.Pattern, val: value.Value, environment: *env.Environment) PatternError!bool {
    return switch (pattern.*) {
        .wildcard => true,
        .literal => |lit| matchLiteralPattern(lit, val),
        .variable => |v| {
            // Glue 约定：大写开头的标识符在模式中视为构造器模式
            // 小写开头的标识符视为变量绑定模式
            if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                // 大写开头：视为构造器模式
                if (val == .adt and std.mem.eql(u8, v.name, val.adt.constructor)) {
                    return true;
                }
                return false;
            }
            // 小写开头：变量绑定，始终匹配
            try environment.define(v.name, val, false);
            return true;
        },
        .constructor => |con| matchConstructorPattern(con, val, environment),
        .record => |rec| matchRecordPattern(rec, val, environment),
        .or_pattern => |or_p| {
            if (try matchPattern(or_p.left, val, environment)) return true;
            return matchPattern(or_p.right, val, environment);
        },
        .guard => {
            // 守卫模式需要 evalExpr 来求值条件表达式，
            // 此处无法处理，应由 Evaluator 在 eval.zig 中处理。
            return error.UnsupportedOperation;
        },
    };
}

/// 字面量模式匹配
fn matchLiteralPattern(lit: ast.PatternLiteral, val: value.Value) PatternError!bool {
    return switch (lit) {
        .int => |raw| {
            const pat_val = parseInt(i128, raw) catch return false;
            if (val == .integer) return val.integer == pat_val;
            return false;
        },
        .float => |raw| {
            const pat_val = parseFloat(f64, raw) catch return false;
            if (val == .float) return val.float == pat_val;
            return false;
        },
        .bool => |b| {
            if (val == .boolean) return val.boolean == b;
            return false;
        },
        .char => |c| {
            if (val == .char_val) return val.char_val == c;
            return false;
        },
        .string => |s| {
            if (val == .string) return std.mem.eql(u8, val.string, s);
            return false;
        },
        .null => {
            return val.isNull();
        },
    };
}

/// 构造器模式匹配
fn matchConstructorPattern(con: @TypeOf(@as(ast.Pattern, undefined).constructor), val: value.Value, environment: *env.Environment) PatternError!bool {
    // Ok/Error 构造器模式匹配 Throw<T, E> 值
    if (std.mem.eql(u8, con.name, "Ok")) {
        if (val == .throw_val) {
            switch (val.throw_val.*) {
                .ok => |v| {
                    if (con.patterns.len == 1) {
                        return matchPattern(con.patterns[0], v.*, environment);
                    }
                    return true;
                },
                .err => return false,
            }
        }
        // 非 throw_val 的 Ok 匹配：直接匹配值本身
        if (con.patterns.len == 1) {
            return matchPattern(con.patterns[0], val, environment);
        }
        return true;
    }
    if (std.mem.eql(u8, con.name, "Error")) {
        if (val == .throw_val) {
            switch (val.throw_val.*) {
                .ok => return false,
                .err => |e| {
                    if (con.patterns.len == 1) {
                        // 将错误值作为 ErrorValue 记录匹配
                        const err_record = value.Value{ .error_val = e };
                        return matchPattern(con.patterns[0], err_record, environment);
                    }
                    return true;
                },
            }
        }
        // 兼容旧的 error_val
        if (val == .error_val and con.patterns.len == 1) {
            return matchPattern(con.patterns[0], val, environment);
        }
        return false;
    }
    // ADT 构造器模式匹配
    if (val == .adt) {
        if (!std.mem.eql(u8, val.adt.constructor, con.name)) return false;
        if (con.patterns.len == 0) return true;
        // 按位置匹配字段
        if (con.patterns.len > val.adt.fields.len) return false;
        for (con.patterns, 0..) |pat, i| {
            if (!try matchPattern(pat, val.adt.fields[i].value, environment)) {
                return false;
            }
        }
        return true;
    }
    return false;
}

/// 记录模式匹配
fn matchRecordPattern(rec: @TypeOf(@as(ast.Pattern, undefined).record), val: value.Value, environment: *env.Environment) PatternError!bool {
    if (val != .record) return false;

    for (rec.fields) |field| {
        if (val.record.get(field.name)) |field_val| {
            if (!try matchPattern(field.pattern, field_val, environment)) {
                return false;
            }
        } else {
            return false;
        }
    }

    return true;
}

// ============================================================
// 辅助函数
// ============================================================

/// 解析整数字面量（支持进制前缀、下划线分隔、类型后缀）
fn parseInt(comptime T: type, raw: []const u8) !T {
    // 去除下划线
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(std.heap.page_allocator);

    var i: usize = 0;

    // 检查进制前缀
    var base: u8 = 10;
    if (raw.len > 2 and raw[0] == '0') {
        if (raw[1] == 'x' or raw[1] == 'X') {
            base = 16;
            i = 2;
        } else if (raw[1] == 'o' or raw[1] == 'O') {
            base = 8;
            i = 2;
        } else if (raw[1] == 'b' or raw[1] == 'B') {
            base = 2;
            i = 2;
        }
    }

    // 去除类型后缀
    var end = raw.len;
    while (end > i) {
        const ch = raw[end - 1];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            end -= 1;
        } else {
            break;
        }
    }

    // 去除下划线
    while (i < end) : (i += 1) {
        if (raw[i] != '_') {
            clean.append(std.heap.page_allocator, raw[i]) catch return error.Overflow;
        }
    }

    const str = clean.items;
    if (str.len == 0) return 0;

    return std.fmt.parseInt(T, str, base) catch error.Overflow;
}

/// 解析浮点字面量（支持类型后缀）
fn parseFloat(comptime T: type, raw: []const u8) !T {
    // 去除类型后缀
    var end = raw.len;
    while (end > 0) {
        const ch = raw[end - 1];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            end -= 1;
        } else {
            break;
        }
    }

    return std.fmt.parseFloat(T, raw[0..end]) catch error.TypeMismatch;
}
