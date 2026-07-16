//! 内置函数与方法注册表
//!
//! 使用 comptime StaticStringMap 实现 O(1) 名称→枚举查找，替代 compileCall/compileMethodCall
//! 中的线性 if-else 链。编译器对枚举 switch 自动优化为跳转表。
//!
//! 两类注册表：
//! - builtin_functions：全局函数调用（如 println/atomic/channel）
//! - builtin_methods：对象方法调用（按 RefKind 分组，如 array.len/channel.send）
//!
//! 扩展步骤：
//! 1. 在枚举中添加新值
//! 2. 在 StaticStringMap 中添加 名称→枚举 映射
//! 3. 在 compiler.zig 的 switch 中添加编译逻辑

const std = @import("std");
const value = @import("value");

const RefKind = value.obj_header.RefKind;

// ══════════════════════════════════════════════════════
// Builtin 函数枚举（全局调用 fn(x)）
// ══════════════════════════════════════════════════════

pub const BuiltinFnKind = enum {
    // I/O 输出
    println,
    print,
    eprintln,
    eprint,
    // I/O 输入
    scanln,
    scan,
    // 并发
    atomic,
    channel,
    // 工具
    eq,
    type_name,
    panic_fn,
};

/// 全局 builtin 函数注册表
/// compileCall 在检查 func_table 之前先查此表
pub const builtin_functions = std.StaticStringMap(BuiltinFnKind).initComptime(&.{
    .{ "println", .println },
    .{ "print", .print },
    .{ "eprintln", .eprintln },
    .{ "eprint", .eprint },
    .{ "scanln", .scanln },
    .{ "scan", .scan },
    .{ "atomic", .atomic },
    .{ "channel", .channel },
    .{ "eq", .eq },
    .{ "type", .type_name },
    .{ "Panic", .panic_fn },
});

// ══════════════════════════════════════════════════════
// Builtin 方法枚举（对象调用 obj.method(x)）
// ══════════════════════════════════════════════════════

pub const BuiltinMethodKind = enum {
    // 数组方法（RefKind.array）
    array_len,
    array_push,
    array_get,
    array_set,

    // 字符串方法（RefKind.str）
    string_len,
    string_char_at,
    string_slice,

    // Channel 方法（RefKind.channel_val）
    channel_send,
    channel_recv,
    channel_try_recv,
    channel_close,
    channel_sender,
    channel_receiver,

    // Atomic 方法（RefKind.atomic_val）
    atomic_load,
    atomic_store,
    atomic_swap,
    atomic_compare_swap,

    // Async 方法（RefKind.async_val）
    async_await,
    async_status,

    // 通用方法（任意 ref 类型）
    universal_println,
};

/// 数组方法表（RefKind.array）
pub const array_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "len", .array_len },
    .{ "push", .array_push },
    .{ "get", .array_get },
    .{ "set", .array_set },
});

/// 字符串方法表（RefKind.str）
pub const string_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "len", .string_len },
    .{ "char_at", .string_char_at },
    .{ "slice", .string_slice },
});

/// Channel 方法表（RefKind.channel_val）
pub const channel_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "send", .channel_send },
    .{ "recv", .channel_recv },
    .{ "tryRecv", .channel_try_recv },
    .{ "close", .channel_close },
    .{ "sender", .channel_sender },
    .{ "receiver", .channel_receiver },
});

/// Atomic 方法表（RefKind.atomic_val）
pub const atomic_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "load", .atomic_load },
    .{ "store", .atomic_store },
    .{ "swap", .atomic_swap },
    .{ "compare_swap", .atomic_compare_swap },
});

/// Async 方法表（RefKind.async_val）
pub const async_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "await", .async_await },
    .{ "status", .async_status },
});

/// 通用方法表（任意 ref 类型）
pub const universal_methods = std.StaticStringMap(BuiltinMethodKind).initComptime(&.{
    .{ "println", .universal_println },
});

// ══════════════════════════════════════════════════════
// 查找接口
// ══════════════════════════════════════════════════════

/// 按 RefKind 查找方法表
/// 返回 null 表示该类型无专用方法表
pub fn methodTableFor(kind: RefKind) ?std.StaticStringMap(BuiltinMethodKind) {
    return switch (kind) {
        .array => array_methods,
        .str => string_methods,
        .channel_val => channel_methods,
        .atomic_val => atomic_methods,
        .async_val => async_methods,
        else => null,
    };
}

/// 查找 builtin 方法
/// 1. 先按 ref_kind 查类型专用表
/// 2. 再查通用表（universal_methods）
/// 返回 null 表示未找到
pub fn lookupMethod(ref_kind: ?RefKind, method_name: []const u8) ?BuiltinMethodKind {
    if (ref_kind) |kind| {
        if (methodTableFor(kind)) |table| {
            if (table.get(method_name)) |kind_val| return kind_val;
        }
    }
    return universal_methods.get(method_name);
}

/// 查找 builtin 函数
pub fn lookupFunction(fn_name: []const u8) ?BuiltinFnKind {
    return builtin_functions.get(fn_name);
}
