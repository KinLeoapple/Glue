//! Glue 语言模式匹配求值
//!
//! 处理模式匹配逻辑，支持：
//! - 通配符模式（_）
//! - 字面量模式（int, float, bool, char, string, null）
//! - 变量绑定模式
//! - 构造器模式（Ok, Error 等 ADT 构造器）
//! - 记录模式（(field: pattern, ...)）
//! - 或模式（pattern1 | pattern2）
//! - 守卫模式（pattern if condition）

const std = @import("std");
const value = @import("value");
const env = @import("env");
const ast = @import("ast");

/// 模式匹配错误集
pub const PatternError = value.EvalError || value.ControlFlow;

/// 守卫条件求值函数类型
/// ctx: 求值器上下文（*Evaluator 通过 @ptrCast 传递）
/// condition: 守卫条件表达式
/// environment: 当前环境（守卫条件中的变量从此环境查找）
/// 返回 true 表示守卫条件满足
pub const GuardEvalFn = *const fn (*anyopaque, *const ast.Expr, *env.Environment) PatternError!bool;

/// 守卫求值上下文
pub const GuardEvalCtx = struct {
    fn_ptr: GuardEvalFn,
    ctx: *anyopaque,
};

/// 将模式与值进行匹配，在环境中绑定变量。
/// 返回 true 表示匹配成功。
/// guard_eval: 可选的守卫条件求值回调，为 null 时遇到守卫模式返回 error.UnsupportedOperation
pub fn matchPattern(pattern: *const ast.Pattern, val: value.Value, environment: *env.Environment, guard_eval: ?GuardEvalCtx) PatternError!bool {
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
                // Newtype 构造器：无子模式的构造器名匹配
                if (val == .newtype and std.mem.eql(u8, v.name, val.newtype.type_name)) {
                    return true;
                }
                return false;
            }
            // 小写开头：变量绑定，始终匹配。name_id 由 resolve 预pass 填充（整数键）。
            try environment.define(v.name_id, val, false);
            return true;
        },
        .constructor => |con| matchConstructorPattern(con, val, environment, guard_eval),
        .record => |rec| matchRecordPattern(rec, val, environment, guard_eval),
        .or_pattern => |or_p| {
            // 保存环境状态，左侧匹配失败时回滚已绑定的变量
            const saved_count = environment.values.count();
            if (try matchPattern(or_p.left, val, environment, guard_eval)) return true;
            // 左侧失败，回滚左侧绑定的变量
            rollbackEnvironment(environment, saved_count);
            return matchPattern(or_p.right, val, environment, guard_eval);
        },
        .guard => |g| {
            // 先匹配内部模式
            if (!try matchPattern(g.pattern, val, environment, guard_eval)) return false;
            // 然后求值守卫条件
            if (guard_eval) |ge| {
                return ge.fn_ptr(ge.ctx, g.condition, environment);
            }
            // 无守卫求值回调时返回 UnsupportedOperation
            return error.UnsupportedOperation;
        },
    };
}

/// 字面量模式匹配
fn matchLiteralPattern(lit: ast.PatternLiteral, val: value.Value) PatternError!bool {
    return switch (lit) {
        .int => |raw| {
            const pat_val = parseInt(u128, raw) catch return false;
            if (val == .integer) return val.integer.value == pat_val;
            return false;
        },
        .float => |raw| {
            const pat_val = parseFloat(f128, raw) catch return false;
            if (val == .float) return val.float.value == pat_val;
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
fn matchConstructorPattern(con: @TypeOf(@as(ast.Pattern, undefined).constructor), val: value.Value, environment: *env.Environment, guard_eval: ?GuardEvalCtx) PatternError!bool {
    // Ok/Error 构造器模式匹配 Throw<T, E> 值
    if (std.mem.eql(u8, con.name, "Ok")) {
        if (val == .throw_val) {
            switch (val.throw_val.*) {
                .ok => |v| {
                    if (con.patterns.len == 1) {
                        return matchPattern(con.patterns[0], v.*, environment, guard_eval);
                    }
                    return true;
                },
                .err => return false,
            }
        }
        // 非 throw_val 的 Ok 匹配：直接匹配值本身
        if (con.patterns.len == 1) {
            return matchPattern(con.patterns[0], val, environment, guard_eval);
        }
        return true;
    }
    if (std.mem.eql(u8, con.name, "Error")) {
        if (val == .throw_val) {
            switch (val.throw_val.*) {
                .ok => return false,
                .err => |e| {
                    // 文档 2.4.3: Error(p) 匹配所有 Error 子类型
                    // FileError <: Error，所以 Error(e) 也能匹配 FileError
                    if (!std.mem.eql(u8, e.type_name, "Error") and !e.is_error_subtype) return false;
                    if (con.patterns.len == 1) {
                        // 将错误值作为 ErrorValue 记录匹配
                        const err_record = value.Value{ .error_val = e };
                        return matchPattern(con.patterns[0], err_record, environment, guard_eval);
                    }
                    return true;
                },
            }
        }
        // 兼容旧的 error_val
        if (val == .error_val) {
            const e = val.error_val;
            // 文档 2.4.3: Error(p) 匹配所有 Error 子类型
            if (!std.mem.eql(u8, e.type_name, "Error") and !e.is_error_subtype) return false;
            if (con.patterns.len == 1) {
                return matchPattern(con.patterns[0], val, environment, guard_eval);
            }
            return true;
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
            if (!try matchPattern(pat, val.adt.fields[i].value, environment, guard_eval)) {
                return false;
            }
        }
        return true;
    }
    // 自定义错误构造器模式匹配（文档 2.4.3: FileError <: Error）
    // match result { FileError(e) => ... } 匹配 ThrowValue.err{ type_name = "FileError" }
    if (val == .throw_val) {
        switch (val.throw_val.*) {
            .ok => return false,
            .err => |e| {
                if (!std.mem.eql(u8, e.type_name, con.name)) return false;
                if (con.patterns.len == 0) return true;
                if (con.patterns.len == 1) {
                    // 将错误值作为 ErrorValue 记录匹配
                    const err_record = value.Value{ .error_val = e };
                    return matchPattern(con.patterns[0], err_record, environment, guard_eval);
                }
                return false;
            },
        }
    }
    // 兼容旧的 error_val 路径：自定义错误构造器匹配
    if (val == .error_val) {
        const e = val.error_val;
        if (!std.mem.eql(u8, e.type_name, con.name)) return false;
        if (con.patterns.len == 0) return true;
        if (con.patterns.len == 1) {
            return matchPattern(con.patterns[0], val, environment, guard_eval);
        }
        return false;
    }
    // Newtype 构造器模式匹配
    // type UserId = UserId(i32)
    // match uid { UserId(v) => v } — 解包内部值
    if (val == .newtype) {
        if (!std.mem.eql(u8, val.newtype.type_name, con.name)) return false;
        if (con.patterns.len == 0) return true;
        if (con.patterns.len == 1) {
            return matchPattern(con.patterns[0], val.newtype.inner, environment, guard_eval);
        }
        return false;
    }
    // 记录类型构造器模式匹配
    // type User = (name: str, age: i32)
    // match u { User(name, age) => ... } — 按位置解构记录字段
    if (val == .record) {
        if (val.record.type_name.len > 0 and !std.mem.eql(u8, val.record.type_name, con.name)) return false;
        // 按位置匹配字段：构造器模式中的子模式与记录字段按插入顺序对应
        if (con.patterns.len == 0) return true;
        var field_iter = val.record.fields.iterator();
        var pattern_idx: usize = 0;
        while (field_iter.next()) |entry| {
            if (pattern_idx >= con.patterns.len) break;
            if (!try matchPattern(con.patterns[pattern_idx], entry.value_ptr.*, environment, guard_eval)) {
                return false;
            }
            pattern_idx += 1;
        }
        return pattern_idx == con.patterns.len;
    }
    return false;
}

/// 记录模式匹配
fn matchRecordPattern(rec: @TypeOf(@as(ast.Pattern, undefined).record), val: value.Value, environment: *env.Environment, guard_eval: ?GuardEvalCtx) PatternError!bool {
    if (val != .record) return false;

    for (rec.fields) |field| {
        if (val.record.fields.get(field.name)) |field_val| {
            if (!try matchPattern(field.pattern, field_val, environment, guard_eval)) {
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

/// 回滚环境到指定条目数，移除之后新增的变量绑定。
/// 用于或模式左侧匹配失败时清理已绑定的变量。
fn rollbackEnvironment(environment: *env.Environment, saved_count: usize) void {
    while (environment.values.count() > saved_count) {
        var iter = environment.values.iterator();
        // 找到最后插入的条目并移除。key 现为 u32 id（无所有权，不再 free）。
        var last_key: ?env.NameId = null;
        while (iter.next()) |entry| {
            last_key = entry.key_ptr.*;
        }
        if (last_key) |key| {
            if (environment.values.fetchRemove(key)) |_| {
                // 注意：不 release removed.value.value，因为值可能被其他引用共享
            }
        } else break;
    }
}

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

    // 去除整数类型后缀（仅形如 i8/u32/i128：i/u 后跟十进制数字）。
    // 不能盲目剥离尾部字母，否则会把十六进制数字 A–F 误当作后缀。
    var end = raw.len;
    {
        var j = end;
        while (j > i and raw[j - 1] >= '0' and raw[j - 1] <= '9') {
            j -= 1;
        }
        if (j > i and j < end and (raw[j - 1] == 'i' or raw[j - 1] == 'u' or raw[j - 1] == 'I' or raw[j - 1] == 'U')) {
            end = j - 1;
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
