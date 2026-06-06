//! Glue 语言运行时值表示
//!
//! 定义求值过程中的所有运行时值类型，包括：
//! - 求值错误和控制流信号
//! - 范围值 (Range)
//! - 错误值 (ErrorValue)
//! - 内建函数类型 (BuiltinFn)
//! - 闭包 (Closure)
//! - 运行时值 (Value) — 所有求值结果的核心联合类型

const std = @import("std");
const ast = @import("ast");

// ============================================================
// 求值错误
// ============================================================

pub const EvalError = error{
    OutOfMemory,
    TypeMismatch,
    UndefinedVariable,
    ImmutableAssignment,
    NotCallable,
    WrongArity,
    IndexOutOfBounds,
    UnsupportedOperation,
};

/// 控制流信号 — 使用 Zig error 机制实现非局部跳转
pub const ControlFlow = error{
    ReturnValue,
    ThrowValue,
    BreakSignal,
    ContinueSignal,
    /// Glue panic — 不可捕获，但允许 defer 执行
    GluePanic,
    /// 尾调用信号 — TCO trampoline 使用
    TailCall,
};

/// 合并的求值错误集
pub const EvalResult = EvalError || ControlFlow;

// ============================================================
// 范围值
// ============================================================

pub const Range = struct {
    start: i128,
    end: i128,
    inclusive: bool, // true = ..=, false = ..

    pub fn contains(self: Range, val: i128) bool {
        if (self.inclusive) {
            return val >= self.start and val <= self.end;
        } else {
            return val >= self.start and val < self.end;
        }
    }

    pub fn len(self: Range) i128 {
        if (self.inclusive) {
            return self.end - self.start + 1;
        } else {
            return self.end - self.start;
        }
    }
};

// ============================================================
// 错误值
// ============================================================

pub const ErrorValue = struct {
    /// 错误类型名（如 "Error"、"FileError"）
    type_name: []const u8,
    message: []const u8,
};

// ============================================================
// Throw 值（Throw<T, E> 的运行时表示）
// ============================================================

/// Throw<T, E> 的运行时值
/// 文档 2.4.4: Throw<T, E> 的值有两种状态：
/// - Ok(value) — 成功，持有 T 类型的值
/// - Error(message) — 失败，持有错误信息
pub const ThrowValue = union(enum) {
    /// Ok(value) — 成功状态
    ok: *Value,
    /// Error(message) — 失败状态
    err: ErrorValue,
};

// ============================================================
// 内建函数类型
// ============================================================

/// 内建函数指针类型
///
/// 使用 *anyopaque 作为上下文指针以避免与 Evaluator 的循环依赖。
/// 在 eval.zig 中注册内建函数时，将 *Evaluator 转换为 *anyopaque；
/// 调用时，内建函数的 wrapper 将 *anyopaque 转换回 *Evaluator。
pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

/// 内建函数（带用户上下文）
///
/// ctx: *Evaluator（通过 @ptrCast 传递）
/// user_ctx: 可选的用户上下文指针（如 ErrorNewtypeCtx）
pub const Builtin = struct {
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,
};

// ============================================================
// 闭包
// ============================================================

pub const Closure = struct {
    params: []ast.Param,
    body: ast.LambdaBody,
    env: *anyopaque, // *Environment — 使用不透明指针避免循环依赖
    allocator: std.mem.Allocator,
};

// ============================================================
// 运行时值
// ============================================================

pub const Value = union(enum) {
    // 基本类型
    integer: i128,
    float: f64,
    boolean: bool,
    char_val: u21,
    string: []const u8,
    null_val,
    unit,

    // 复合类型
    array: std.ArrayList(Value),
    record: std.StringHashMap(Value),

    // 范围
    range: Range,

    // 闭包
    closure: *Closure,

    // 内建函数
    builtin: Builtin,

    // 错误值（用于 throw 传播）
    error_val: ErrorValue,

    // Throw 值（Throw<T, E> 的运行时表示）
    throw_val: *ThrowValue,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |*arr| {
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            .record => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                map.deinit();
            },
            .string => |s| {
                allocator.free(s);
            },
            .error_val => |e| {
                allocator.free(e.type_name);
                allocator.free(e.message);
            },
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        v.deinit(allocator);
                        allocator.destroy(v);
                    },
                    .err => |e| {
                        allocator.free(e.type_name);
                        allocator.free(e.message);
                    },
                }
                allocator.destroy(tv);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .integer => self,
            .float => self,
            .boolean => self,
            .char_val => self,
            .null_val => self,
            .unit => self,
            .builtin => self,
            .range => self,
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = std.ArrayList(Value).empty;
                for (arr.items) |item| {
                    try new_arr.append(allocator, try item.clone(allocator));
                }
                return Value{ .array = new_arr };
            },
            .record => |map| {
                var new_map = std.StringHashMap(Value).init(allocator);
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const val = try entry.value_ptr.*.clone(allocator);
                    try new_map.put(key, val);
                }
                return Value{ .record = new_map };
            },
            .closure => self,
            .error_val => |e| Value{ .error_val = ErrorValue{
                .type_name = try allocator.dupe(u8, e.type_name),
                .message = try allocator.dupe(u8, e.message),
            } },
            .throw_val => |tv| {
                const new_tv = try allocator.create(ThrowValue);
                switch (tv.*) {
                    .ok => |v| {
                        const cloned_val = try v.clone(allocator);
                        const cloned_ptr = try allocator.create(Value);
                        cloned_ptr.* = cloned_val;
                        new_tv.* = ThrowValue{ .ok = cloned_ptr };
                    },
                    .err => |e| {
                        new_tv.* = ThrowValue{ .err = ErrorValue{
                            .type_name = try allocator.dupe(u8, e.type_name),
                            .message = try allocator.dupe(u8, e.message),
                        } };
                    },
                }
                return Value{ .throw_val = new_tv };
            },
        };
    }

    pub fn format(self: Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        switch (self) {
            .integer => |i| try buf.print(allocator, "{}", .{i}),
            .float => |f| try buf.print(allocator, "{d}", .{f}),
            .boolean => |b| try buf.print(allocator, "{}", .{b}),
            .char_val => |c| try buf.print(allocator, "{u}", .{c}),
            .string => |s| try buf.print(allocator, "{s}", .{s}),
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .range => |r| {
                if (r.inclusive) {
                    try buf.print(allocator, "{}..={}", .{ r.start, r.end });
                } else {
                    try buf.print(allocator, "{}..{}", .{ r.start, r.end });
                }
            },
            .array => |arr| {
                try buf.appendSlice(allocator, "[");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try item.format(buf, allocator);
                }
                try buf.appendSlice(allocator, "]");
            },
            .record => |map| {
                try buf.appendSlice(allocator, "(");
                var iter = map.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try buf.appendSlice(allocator, ", ");
                    first = false;
                    try buf.print(allocator, "{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.*.format(buf, allocator);
                }
                try buf.appendSlice(allocator, ")");
            },
            .closure => try buf.appendSlice(allocator, "<closure>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .error_val => |e| try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message }),
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        try buf.appendSlice(allocator, "Ok(");
                        try v.format(buf, allocator);
                        try buf.appendSlice(allocator, ")");
                    },
                    .err => |e| {
                        try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message });
                    },
                }
            },
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;
        return switch (self) {
            .integer => |i| i == other.integer,
            .float => |f| f == other.float,
            .boolean => |b| b == other.boolean,
            .char_val => |c| c == other.char_val,
            .string => |s| std.mem.eql(u8, s, other.string),
            .null_val => true,
            .unit => true,
            .range => |r| r.start == other.range.start and r.end == other.range.end and r.inclusive == other.range.inclusive,
            // 引用相等
            .array => |a| @intFromPtr(&a) == @intFromPtr(&other.array),
            .record => |r| @intFromPtr(&r) == @intFromPtr(&other.record),
            .closure => |c| c == other.closure,
            .builtin => |b_val| b_val.fn_ptr == other.builtin.fn_ptr and b_val.user_ctx == other.builtin.user_ctx,
            .error_val => |e| std.mem.eql(u8, e.type_name, other.error_val.type_name) and std.mem.eql(u8, e.message, other.error_val.message),
            .throw_val => |tv| tv == other.throw_val, // 引用相等
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .null_val => false,
            .unit => false,
            else => true,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn asInteger(self: Value) !i128 {
        return switch (self) {
            .integer => |i| i,
            else => error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        };
    }

    pub fn asBoolean(self: Value) !bool {
        return switch (self) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn asString(self: Value) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }
};
