//! 内置函数注册表
//!
//! v3 spec §6 阶段 4：将 builder.zig:3994 compileCallWithTypeArgs 的 9 个 if 分支
//! 替换为注册表查询。每个 BuiltinEntry 描述一个内置函数的名称、参数数量、
//! 输出通道类型和节点形状（unary/sink/none）。
//!
//! 查询：lookupBuiltin(name) → ?BuiltinEntry
//! 编译：IRBuilder 根据 entry.shape 生成对应的 Node

const std = @import("std");
const node_mod = @import("node.zig");
const type_descriptor_mod = @import("type_descriptor.zig");

const Node = node_mod.Node;
const NodeOp = node_mod.NodeOp;
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;

/// 内置函数种类（对应 NodeOp）
pub const BuiltinKind = enum {
    reflect,
    scalar_to_str,
    type_name,
    typeof_meta,
    panic,
    ok,
    error_ctor,
    str,
    channel_create,
};

/// 节点形状
pub const BuiltinShape = enum {
    /// unary：1 个输入通道 + meta_index，输出到新通道
    /// Node.makeUnary(op, out, meta_idx, in0)
    unary,
    /// sink_unary：1 个输入通道但使用 makeSink（meta_idx only，无输入）
    /// 用于 typeof/panic 等特殊节点
    sink,
    /// sink_optional：0 或 1 个输入通道（panic 支持无参数）
    /// 调用方特殊处理
    sink_optional,
};

/// meta_index 来源
pub const MetaSource = enum {
    /// meta_idx = 0
    zero,
    /// meta_idx = resolveReflectMetaIndex(arg_expr)
    reflect,
    /// meta_idx = resolveTypeofMetaIndex(arg_expr)
    typeof,
};

/// 内置函数注册条目
pub const BuiltinEntry = struct {
    name: []const u8,
    kind: BuiltinKind,
    /// 预期参数数量（null = 变参）
    arg_count: ?u8,
    /// 输出通道类型描述符
    out_type_desc: *const TypeDescriptor,
    /// 节点形状
    shape: BuiltinShape,
    /// meta_index 来源
    meta_source: MetaSource,
    /// 对应的 NodeOp
    op: NodeOp,
};

/// 内置函数表
pub const BUILTIN_TABLE = [_]BuiltinEntry{
    .{
        .name = "reflect",
        .kind = .reflect,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .reflect,
        .op = .builtin_reflect,
    },
    .{
        .name = "__scalar_to_str",
        .kind = .scalar_to_str,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .builtin_scalar_to_str,
    },
    .{
        .name = "type",
        .kind = .type_name,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .builtin_type,
    },
    .{
        .name = "typeof",
        .kind = .typeof_meta,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .sink,
        .meta_source = .typeof,
        .op = .builtin_typeof,
    },
    .{
        .name = "Panic",
        .kind = .panic,
        .arg_count = null, // 0 或 1 个参数
        .out_type_desc = type_descriptor_mod.unit_descriptor,
        .shape = .sink_optional,
        .meta_source = .zero,
        .op = .builtin_panic,
    },
    .{
        .name = "Ok",
        .kind = .ok,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .builtin_ok,
    },
    .{
        .name = "Error",
        .kind = .error_ctor,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .builtin_error,
    },
    .{
        .name = "str",
        .kind = .str,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .builtin_str,
    },
    .{
        .name = "channel",
        .kind = .channel_create,
        .arg_count = 1,
        .out_type_desc = type_descriptor_mod.ref_descriptor,
        .shape = .unary,
        .meta_source = .zero,
        .op = .channel_create,
    },
};

/// 按名称查找内置函数
/// 返回 BuiltinEntry 的 const 指针（数据在静态表中，无需释放）
pub fn lookupBuiltin(name: []const u8) ?*const BuiltinEntry {
    for (&BUILTIN_TABLE) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

// ════════════════════════════════════════════════════════════
// 编译期分析强制引用 + 冒烟测试
// ════════════════════════════════════════════════════════════

test "builtin_registry: lookupBuiltin 查询" {
    const reflect_entry = lookupBuiltin("reflect").?;
    try std.testing.expectEqual(BuiltinKind.reflect, reflect_entry.kind);
    try std.testing.expectEqual(@as(?u8, 1), reflect_entry.arg_count);
    try std.testing.expectEqual(type_descriptor_mod.ref_descriptor, reflect_entry.out_type_desc);
    try std.testing.expectEqual(BuiltinShape.unary, reflect_entry.shape);
    try std.testing.expectEqual(MetaSource.reflect, reflect_entry.meta_source);

    const panic_entry = lookupBuiltin("Panic").?;
    try std.testing.expectEqual(BuiltinKind.panic, panic_entry.kind);
    try std.testing.expectEqual(@as(?u8, null), panic_entry.arg_count);
    try std.testing.expectEqual(BuiltinShape.sink_optional, panic_entry.shape);
    try std.testing.expectEqual(MetaSource.zero, panic_entry.meta_source);

    const typeof_entry = lookupBuiltin("typeof").?;
    try std.testing.expectEqual(BuiltinShape.sink, typeof_entry.shape);
    try std.testing.expectEqual(MetaSource.typeof, typeof_entry.meta_source);

    // 不存在的函数
    try std.testing.expect(lookupBuiltin("not_a_builtin") == null);
}

test "builtin_registry: 表完整性" {
    // 确保所有 9 个内置函数都在表中
    try std.testing.expect(lookupBuiltin("reflect") != null);
    try std.testing.expect(lookupBuiltin("__scalar_to_str") != null);
    try std.testing.expect(lookupBuiltin("type") != null);
    try std.testing.expect(lookupBuiltin("typeof") != null);
    try std.testing.expect(lookupBuiltin("Panic") != null);
    try std.testing.expect(lookupBuiltin("Ok") != null);
    try std.testing.expect(lookupBuiltin("Error") != null);
    try std.testing.expect(lookupBuiltin("str") != null);
    try std.testing.expect(lookupBuiltin("channel") != null);

    try std.testing.expectEqual(@as(usize, 9), BUILTIN_TABLE.len);
}
