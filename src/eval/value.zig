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
    CircularDependency,
    FileNotFound,
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
    /// 是否为 Error 的子类型（文档 2.4.3: FileError <: Error）
    /// 自定义错误类型（type X = Error("...")）自动是 Error 的子类型
    is_error_subtype: bool = false,
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
// ADT 值（代数数据类型的运行时表示）
// ============================================================

/// ADT 构造器字段
pub const AdtField = struct {
    /// 字段名（位置参数为 null）
    name: ?[]const u8,
    value: Value,
};

/// ADT 值 — 代数数据类型构造器的运行时实例
///
/// 如 `Circle(3.14)` 创建 AdtValue{ .type_name = "Shape", .constructor = "Circle", .fields = [...] }
/// 如 `Cons(1, Nil)` 创建 AdtValue{ .type_name = "List", .constructor = "Cons", .fields = [...] }
/// 如 `Lt` 创建 AdtValue{ .type_name = "Ordering", .constructor = "Lt", .fields = [] }
pub const AdtValue = struct {
    /// 类型名（如 Shape, List, Ordering）
    type_name: []const u8,
    /// 构造器名（如 Circle, Cons, Lt）
    constructor: []const u8,
    /// 构造器字段值
    fields: []AdtField,
};

// ============================================================
// Newtype 值（零开销包装类型的运行时表示）
// ============================================================

/// Newtype 值 — 单字段 ADT，创建语义不同但运行时零开销的新类型
///
/// 如 `type UserId = UserId(i32)` 声明后，`UserId(42)` 创建
/// NewtypeValue{ .type_name = "UserId", .inner = Value{ .integer = IntValue{ .value = 42 } } }
///
/// 文档 2.14: Newtype — 创建新类型，运行时零开销
/// 术语表: Newtype — 单字段 ADT，创建语义不同但运行时无开销的新类型
pub const NewtypeValue = struct {
    /// 类型名（如 UserId, Celsius）
    type_name: []const u8,
    /// 内部被包装的值
    inner: Value,
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
// 迭代器值（Iterable/Iterator 协议的运行时表示）
// ============================================================

/// 数组迭代器
pub const ArrayIterator = struct {
    array: []Value,
    index: usize,
};

/// 字符串迭代器（UTF-8 码点）
pub const StringIterator = struct {
    string: []const u8,
    byte_offset: usize,
};

/// 范围迭代器
pub const RangeIterator = struct {
    current: i128,
    end: i128,
    inclusive: bool,
};

// ============================================================
// 整数类型标签
// ============================================================

/// 整数具体类型标签，用于运行时溢出检查
pub const IntType = enum {
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

    /// 返回该整数类型的最小值
    pub fn minInt(self: IntType) i128 {
        return switch (self) {
            .i8 => std.math.minInt(i8),
            .i16 => std.math.minInt(i16),
            .i32 => std.math.minInt(i32),
            .i64 => std.math.minInt(i64),
            .i128 => std.math.minInt(i128),
            .u8, .u16, .u32, .u64, .u128 => 0,
        };
    }

    /// 返回该整数类型的最大值
    pub fn maxInt(self: IntType) i128 {
        return switch (self) {
            .i8 => std.math.maxInt(i8),
            .i16 => std.math.maxInt(i16),
            .i32 => std.math.maxInt(i32),
            .i64 => std.math.maxInt(i64),
            .i128 => std.math.maxInt(i128),
            .u8 => std.math.maxInt(u8),
            .u16 => std.math.maxInt(u16),
            .u32 => std.math.maxInt(u32),
            .u64 => std.math.maxInt(u64),
            .u128 => std.math.maxInt(i128), // i128 无法表示 u128::MAX，取 i128::MAX
        };
    }

    /// 检查值是否在该类型的范围内
    pub fn inRange(self: IntType, val: i128) bool {
        return val >= self.minInt() and val <= self.maxInt();
    }

    /// 从类型名称字符串解析
    pub fn fromName(name: []const u8) ?IntType {
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

/// 带类型标签的整数值
pub const IntValue = struct {
    value: i128,
    type_tag: IntType = .i32, // 默认 i32（文档：默认整数字面量为 i32）
};

// ============================================================
// 运行时值
// ============================================================

pub const Value = union(enum) {
    // 基本类型
    integer: IntValue,
    float: f64,
    boolean: bool,
    char_val: u21,
    string: []const u8,
    null_val,
    unit,

    // 复合类型
    array: []Value,
    record: std.StringHashMap(Value),

    // ADT 值（代数数据类型构造器实例）
    adt: *AdtValue,

    // Newtype 值（零开销包装类型实例）
    newtype: *NewtypeValue,

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

    // 迭代器（Iterable/Iterator 协议的运行时表示）
    /// 数组迭代器
    array_iterator: *ArrayIterator,
    /// 字符串迭代器（UTF-8 码点）
    string_iterator: *StringIterator,
    /// 范围迭代器
    range_iterator: *RangeIterator,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |arr| {
                for (arr) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
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
            .adt => {
                // ADT 值由 Evaluator 统一管理（通过 arena allocator），
                // 不在此释放，避免同一 *AdtValue 被多个 Value 引用导致 double-free
            },
            .newtype => {
                // Newtype 值由 Evaluator 统一管理，不在此释放
            },
            .array_iterator, .string_iterator, .range_iterator => {
                // 迭代器由 Evaluator 统一管理，不在此释放
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
                var new_arr = try allocator.alloc(Value, arr.len);
                for (arr, 0..) |item, i| {
                    new_arr[i] = try item.clone(allocator);
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
            .adt => |av| {
                const new_av = try allocator.create(AdtValue);
                new_av.* = AdtValue{
                    .type_name = try allocator.dupe(u8, av.type_name),
                    .constructor = try allocator.dupe(u8, av.constructor),
                    .fields = try allocator.alloc(AdtField, av.fields.len),
                };
                for (av.fields, 0..) |f, i| {
                    new_av.fields[i] = AdtField{
                        .name = if (f.name) |n| try allocator.dupe(u8, n) else null,
                        .value = try f.value.clone(allocator),
                    };
                }
                return Value{ .adt = new_av };
            },
            .newtype => |nv| {
                const new_nv = try allocator.create(NewtypeValue);
                new_nv.* = NewtypeValue{
                    .type_name = try allocator.dupe(u8, nv.type_name),
                    .inner = try nv.inner.clone(allocator),
                };
                return Value{ .newtype = new_nv };
            },
            .error_val => |e| Value{ .error_val = ErrorValue{
                .type_name = try allocator.dupe(u8, e.type_name),
                .message = try allocator.dupe(u8, e.message),
                .is_error_subtype = e.is_error_subtype,
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
            .array_iterator => |ai| Value{ .array_iterator = ai }, // 引用相等
            .string_iterator => |si| Value{ .string_iterator = si }, // 引用相等
            .range_iterator => |ri| Value{ .range_iterator = ri }, // 引用相等
        };
    }

    /// debug=false: display 模式（顶层字符串无引号，用户友好）
    /// debug=true: repr 模式（字符串带引号，结构化表示）
    pub fn format(self: Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, debug: bool) !void {
        switch (self) {
            .integer => |iv| try buf.print(allocator, "{}", .{iv.value}),
            .float => |f| try buf.print(allocator, "{d}", .{f}),
            .boolean => |b| try buf.print(allocator, "{}", .{b}),
            .char_val => |c| try buf.print(allocator, "{u}", .{c}),
            .string => |s| if (debug) {
                try buf.print(allocator, "\"{s}\"", .{s});
            } else {
                try buf.print(allocator, "{s}", .{s});
            },
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
                for (arr, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try item.format(buf, allocator, true);
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
                    try entry.value_ptr.*.format(buf, allocator, true);
                }
                try buf.appendSlice(allocator, ")");
            },
            .closure => try buf.appendSlice(allocator, "<closure>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .adt => |av| {
                try buf.print(allocator, "{s}", .{av.constructor});
                if (av.fields.len > 0) {
                    try buf.appendSlice(allocator, "(");
                    for (av.fields, 0..) |f, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        if (f.name) |n| {
                            try buf.print(allocator, "{s}: ", .{n});
                        }
                        try f.value.format(buf, allocator, true);
                    }
                    try buf.appendSlice(allocator, ")");
                }
            },
            .newtype => |nv| {
                try buf.print(allocator, "{s}(", .{nv.type_name});
                try nv.inner.format(buf, allocator, true);
                try buf.appendSlice(allocator, ")");
            },
            .error_val => |e| try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message }),
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        try buf.appendSlice(allocator, "Ok(");
                        try v.format(buf, allocator, true);
                        try buf.appendSlice(allocator, ")");
                    },
                    .err => |e| {
                        try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message });
                    },
                }
            },
            .array_iterator => try buf.appendSlice(allocator, "<array_iterator>"),
            .string_iterator => try buf.appendSlice(allocator, "<string_iterator>"),
            .range_iterator => try buf.appendSlice(allocator, "<range_iterator>"),
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;
        return switch (self) {
            .integer => |iv| iv.value == other.integer.value,
            .float => |f| f == other.float,
            .boolean => |b| b == other.boolean,
            .char_val => |c| c == other.char_val,
            .string => |s| std.mem.eql(u8, s, other.string),
            .null_val => true,
            .unit => true,
            .range => |r| r.start == other.range.start and r.end == other.range.end and r.inclusive == other.range.inclusive,
            // 引用相等
            .array => |a| a.ptr == other.array.ptr,
            .record => |r| @intFromPtr(&r) == @intFromPtr(&other.record),
            .adt => |av| av == other.adt, // 引用相等
            .newtype => |nv| nv == other.newtype, // 引用相等
            .closure => |c| c == other.closure,
            .builtin => |b_val| b_val.fn_ptr == other.builtin.fn_ptr and b_val.user_ctx == other.builtin.user_ctx,
            .error_val => |e| std.mem.eql(u8, e.type_name, other.error_val.type_name) and std.mem.eql(u8, e.message, other.error_val.message),
            .throw_val => |tv| tv == other.throw_val, // 引用相等
            .array_iterator => |ai| ai == other.array_iterator, // 引用相等
            .string_iterator => |si| si == other.string_iterator, // 引用相等
            .range_iterator => |ri| ri == other.range_iterator, // 引用相等
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |iv| iv.value != 0,
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
            .integer => |iv| iv.value,
            else => error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |iv| @floatFromInt(iv.value),
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
