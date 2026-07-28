//! RefKind 描述符表：按 RefKind 索引的统一属性表
//!
//! v3 spec 阶段 7：消除 type_tag switch 分派。
//! 数据字段（type_name/display_name/is_memoizable）comptime 填充，
//! 函数指针（deep_copy/format/equals）运行时注册（同 deinit_table 模式）。
//!
//! 本模块仅依赖 obj_header.zig，不导入 value 子模块，避免循环依赖。
//! 函数指针签名使用 *ObjHeader 而非 Value，由 mod.zig 提供适配包装。

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const RefKind = obj_header.RefKind;
const ThreadContext = obj_header.ThreadContext;
const ref_kind_count = obj_header.ref_kind_count;

/// 深拷贝函数指针：返回新对象的 ObjHeader 指针
/// 调用方负责将返回值包装为 Value{ .ref = ... }。
/// null 表示引用语义（retain 即可，如迭代器/并发类型/协程帧/装箱标量）。
pub const DeepCopyFn = *const fn (*ObjHeader, *ThreadContext) anyerror!*ObjHeader;

/// 格式化函数指针：将对象可读形式追加到 buf
/// 使用 tctx.backing 作为 ArrayList 分配器。
/// null 表示追加 display_name（如 "<closure>"）。
pub const FormatFn = *const fn (*ObjHeader, *ThreadContext, *std.ArrayList(u8)) anyerror!void;

/// 相等性比较函数指针：比较两个同类型对象的内容
/// null 表示按引用相等（指针比较）。
pub const EqualsFn = *const fn (*ObjHeader, *ObjHeader) bool;

/// RefKind 描述符：统一承载类型属性与操作函数
pub const RefKindDescriptor = struct {
    /// 语义类型名（用于 builtin_type 反射）："str", "array", "Error", etc.
    type_name: []const u8,
    /// 格式化显示名："<closure>", "<partial>", etc.
    /// 用于无自定义 format_fn 的类型，或作为占位符。
    display_name: []const u8,
    /// 是否可作为 memo 表键（不可变且可序列化）
    is_memoizable: bool,
    /// 深拷贝函数（null = retain 语义）
    deep_copy_fn: ?DeepCopyFn = null,
    /// 格式化函数（null = 追加 display_name）
    format_fn: ?FormatFn = null,
    /// 相等性比较函数（null = 引用相等）
    equals_fn: ?EqualsFn = null,
};

/// comptime 生成各 RefKind 的数据字段（函数指针初始为 null）
fn descriptorFor(comptime kind: RefKind) RefKindDescriptor {
    return switch (kind) {
        // 复合类型
        .str => .{ .type_name = "str", .display_name = "<str>", .is_memoizable = true },
        .array => .{ .type_name = "array", .display_name = "<array>", .is_memoizable = true },
        .record => .{ .type_name = "record", .display_name = "<record>", .is_memoizable = true },
        .adt => .{ .type_name = "adt", .display_name = "<adt>", .is_memoizable = true },
        .newtype => .{ .type_name = "newtype", .display_name = "<newtype>", .is_memoizable = true },
        .cell => .{ .type_name = "cell", .display_name = "<cell>", .is_memoizable = false },
        .range => .{ .type_name = "range", .display_name = "<range>", .is_memoizable = true },
        // 可调用类型
        .closure => .{ .type_name = "function", .display_name = "<closure>", .is_memoizable = false },
        .partial => .{ .type_name = "partial", .display_name = "<partial>", .is_memoizable = false },
        .builtin => .{ .type_name = "builtin", .display_name = "<builtin>", .is_memoizable = false },
        .trait_val => .{ .type_name = "trait", .display_name = "<trait>", .is_memoizable = false },
        .lazy_val => .{ .type_name = "lazy", .display_name = "<lazy>", .is_memoizable = false },
        // 控制流类型
        .error_val => .{ .type_name = "Error", .display_name = "<error>", .is_memoizable = true },
        .throw_val => .{ .type_name = "Throw", .display_name = "<throw>", .is_memoizable = true },
        // 迭代器类型
        .array_iter => .{ .type_name = "array_iter", .display_name = "<array_iter>", .is_memoizable = false },
        .string_iter => .{ .type_name = "string_iter", .display_name = "<string_iter>", .is_memoizable = false },
        .range_iter => .{ .type_name = "range_iter", .display_name = "<range_iter>", .is_memoizable = false },
        // 并发类型
        .atomic_val => .{ .type_name = "atomic", .display_name = "<atomic>", .is_memoizable = false },
        .async_val => .{ .type_name = "Spawn", .display_name = "<async>", .is_memoizable = false },
        .channel_val => .{ .type_name = "Channel", .display_name = "<channel>", .is_memoizable = false },
        .sender_val => .{ .type_name = "sender", .display_name = "<sender>", .is_memoizable = false },
        .receiver_val => .{ .type_name = "receiver", .display_name = "<receiver>", .is_memoizable = false },
        .coroutine_frame => .{ .type_name = "coroutine", .display_name = "<coroutine>", .is_memoizable = false },
    };
}

/// RefKind 描述符表：按 RefKind 枚举值索引
///
/// 数据字段 comptime 填充，函数指针初始为 null，
/// 由 registerDeepCopyFn/registerFormatFn/registerEqualsFn 运行时注册。
pub var ref_kind_table: [ref_kind_count]RefKindDescriptor = init: {
    var table: [ref_kind_count]RefKindDescriptor = undefined;
    for (std.meta.fields(RefKind)) |field| {
        const kind: RefKind = @enumFromInt(field.value);
        table[@intFromEnum(kind)] = descriptorFor(kind);
    }
    break :init table;
};

/// 注册深拷贝函数
pub fn registerDeepCopyFn(kind: RefKind, fn_ptr: DeepCopyFn) void {
    ref_kind_table[@intFromEnum(kind)].deep_copy_fn = fn_ptr;
}

/// 注册格式化函数
pub fn registerFormatFn(kind: RefKind, fn_ptr: FormatFn) void {
    ref_kind_table[@intFromEnum(kind)].format_fn = fn_ptr;
}

/// 注册相等性比较函数
pub fn registerEqualsFn(kind: RefKind, fn_ptr: EqualsFn) void {
    ref_kind_table[@intFromEnum(kind)].equals_fn = fn_ptr;
}

/// 查询描述符（只读）
pub inline fn descriptor(kind: RefKind) *const RefKindDescriptor {
    return &ref_kind_table[@intFromEnum(kind)];
}

/// 查询类型名
pub inline fn typeName(kind: RefKind) []const u8 {
    return ref_kind_table[@intFromEnum(kind)].type_name;
}

/// 查询显示名
pub inline fn displayName(kind: RefKind) []const u8 {
    return ref_kind_table[@intFromEnum(kind)].display_name;
}

/// 查询是否可记忆化
pub inline fn isMemoizable(kind: RefKind) bool {
    return ref_kind_table[@intFromEnum(kind)].is_memoizable;
}
