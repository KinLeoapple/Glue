//! 类型解析器：alias/绑定展开 → TypeDescriptor
//!
//! v3 spec §5.1: 迁自 builder.zig 的 chanTypeFrom* 系列。
//! 职责：将 AST 类型节点 + type_args 绑定上下文解析为 TypeDescriptor。

const std = @import("std");
const ast = @import("ast");
const ir_mod = @import("ir");
const type_descriptor_mod = @import("type_descriptor.zig");
const concrete_type = @import("concrete_type.zig");
const builtin_types = @import("builtin_types.zig");

const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const ScalarKind = type_descriptor_mod.ScalarKind;

/// 内置标量名 → ScalarKind 映射
/// v3 阶段 10：委托给 builtin_types.zig 的 comptime 注册表
fn scalarKindFromName(name: []const u8) ?ScalarKind {
    return builtin_types.scalarKindFromName(name);
}

/// 引用语义类型的 TypeDescriptor（ref_chan，8 字节指针）
/// 用于 str/record/adt/array/fn/generic/trait/ref_type/raw_ptr 等堆引用类型
/// scalar_ops 引用 ir 侧的 ref_ops，使 readChannel/writeChannel 能处理 ref_chan
pub const ref_type_descriptor: TypeDescriptor = .{
    .size = 8,
    .alignment = 8,
    .is_ref = true,
    .scalar_ops = &ir_mod.type_descriptor_mod.ref_ops,
    .slots = &.{},
    .slot_kind = .none,
    .type_id = 0,
    .type_name = "ref",
};

/// null 类型的 TypeDescriptor
pub const null_type_descriptor: TypeDescriptor = .{
    .size = 0,
    .alignment = 1,
    .is_ref = false,
    .scalar_ops = &ir_mod.type_descriptor_mod.null_ops,
    .slots = &.{},
    .slot_kind = .none,
    .type_id = 17,
    .type_name = "null",
};

/// unit 类型的 TypeDescriptor
pub const unit_type_descriptor: TypeDescriptor = .{
    .size = 0,
    .alignment = 1,
    .is_ref = false,
    .scalar_ops = &ir_mod.type_descriptor_mod.unit_ops,
    .slots = &.{},
    .slot_kind = .none,
    .type_id = 18,
    .type_name = "void",
};

/// 将 AST 类型节点解析为 TypeDescriptor
/// 迁自 builder.zig:10438 chanTypeFromTypeNode（自由函数）
/// 合并了 chanTypeFromTypeNodeBound/Resolved 的逻辑（type_args 绑定通过参数传入）
pub fn resolveTypeNode(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    return switch (tn.*) {
        .named => |n| {
            // 优先查 type_args 绑定（泛型类型参数）
            for (type_args) |*ta| {
                if (std.mem.eql(u8, ta.type_name, n.name)) return ta;
            }
            // 内置标量类型
            if (scalarKindFromName(n.name)) |kind| {
                return type_descriptor_mod.lookupByScalarKind(kind);
            }
            // str → ref_chan
            if (std.mem.eql(u8, n.name, "str")) return &ref_type_descriptor;
            // unit → unit_chan
            if (std.mem.eql(u8, n.name, "void")) return &unit_type_descriptor;
            // 用户自定义类型（ADT/record/newtype/alias）→ ref_chan（堆引用）
            return &ref_type_descriptor;
        },
        .generic => |g| {
            // 泛型类型如 List<T>、Channel<T>、Atomic<T> → ref_chan
            _ = g;
            return &ref_type_descriptor;
        },
        .nullable => |nb| {
            // nullable 类型：返回内部类型的 TypeDescriptor
            // 调用方可用于 allocNullable（内部类型决定通道布局）
            return resolveTypeNode(nb.inner, type_args) orelse &ref_type_descriptor;
        },
        // 借用引用 &T：通道存指针，固定 8 字节 ref_chan
        .ref_type => &ref_type_descriptor,
        // 裸指针 *T：通道存指针，固定 8 字节 ref_chan
        .raw_ptr => &ref_type_descriptor,
        // 记录类型（含元组）：堆分配的 RecordValue → ref_chan
        .record => &ref_type_descriptor,
        // 函数类型：Callable 引用 → ref_chan
        .function => &ref_type_descriptor,
        // 数组类型：堆分配的 ArrayValue → ref_chan
        .array => &ref_type_descriptor,
        // self_type：无法静态推断，退化为 ref_chan
        .self_type => &ref_type_descriptor,
        // kind_annotated：递归内部
        .kind_annotated => |ka| resolveTypeNode(ka.inner, type_args) orelse &ref_type_descriptor,
    };
}

/// 将 ConcreteType 转换为 TypeDescriptor
/// 迁自 type_check.zig:50 semaTypeToChanType（升级为返回 TypeDescriptor）
pub fn fromConcreteType(ct: concrete_type.ConcreteType) ?*const TypeDescriptor {
    return switch (ct) {
        .i8_type => type_descriptor_mod.lookupByScalarKind(.i8),
        .i16_type => type_descriptor_mod.lookupByScalarKind(.i16),
        .i32_type => type_descriptor_mod.lookupByScalarKind(.i32),
        .i64_type => type_descriptor_mod.lookupByScalarKind(.i64),
        .i128_type => type_descriptor_mod.lookupByScalarKind(.i128),
        .u8_type => type_descriptor_mod.lookupByScalarKind(.u8),
        .u16_type => type_descriptor_mod.lookupByScalarKind(.u16),
        .u32_type => type_descriptor_mod.lookupByScalarKind(.u32),
        .u64_type => type_descriptor_mod.lookupByScalarKind(.u64),
        .u128_type => type_descriptor_mod.lookupByScalarKind(.u128),
        .isize_type => type_descriptor_mod.lookupByScalarKind(.isize),
        .usize_type => type_descriptor_mod.lookupByScalarKind(.usize),
        .f16_type => type_descriptor_mod.lookupByScalarKind(.f16),
        .f32_type => type_descriptor_mod.lookupByScalarKind(.f32),
        .f64_type => type_descriptor_mod.lookupByScalarKind(.f64),
        .f128_type => type_descriptor_mod.lookupByScalarKind(.f128),
        .bool_type => type_descriptor_mod.lookupByScalarKind(.bool),
        .char_type => type_descriptor_mod.lookupByScalarKind(.char),
        .str_type => &ref_type_descriptor,
        .null_type => &null_type_descriptor,
        .unit_type => &unit_type_descriptor,
        // 复合类型 → ref_chan（堆引用）
        .record_type,
        .adt_type,
        .array_type,
        .fn_type,
        .generic_type,
        .trait_type,
        => &ref_type_descriptor,
        // 包装类型：递归取内部
        .nullable_type => |inner| fromConcreteType(inner.*) orelse &ref_type_descriptor,
        .ref_type => &ref_type_descriptor,
        .throw_type => |tt| fromConcreteType(tt.value_type.*) orelse &ref_type_descriptor,
        // 类型变量/未知/never：无法静态确定
        .type_var,
        .unknown_type,
        .never_type,
        => null,
    };
}

/// 便捷方法：将 AST 类型节点解析为 TypeDescriptor（委托 resolveTypeNode）
/// 兼容现有 IRBuilder 调用
pub fn resolveChanType(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
) ?*const TypeDescriptor {
    return resolveTypeNode(type_node, type_args);
}

/// 从 TypeNode 提取类型名（用于变量绑定的类型推断）
/// 迁自 builder.zig typeNameFromTypeNodeSimple
/// 对 &T / *T 递归到 inner，对泛型返回基类名
pub fn typeNameFromNode(type_node: ?*const ast.TypeNode) ?[]const u8 {
    const tn = type_node orelse return null;
    const effective_tn = switch (tn.*) {
        .ref_type => tn.ref_type.inner,
        .raw_ptr => tn.raw_ptr.inner,
        else => tn,
    };
    return switch (effective_tn.*) {
        .named => |n| n.name,
        .generic => |g| g.name,
        else => null,
    };
}

// ════════════════════════════════════════════════════════════
// TypeDescriptor 全局表注册（v3 阶段 1）
// ════════════════════════════════════════════════════════════

const SemaResult = ir_mod.SemaResult;

/// 注册 TypeDescriptor 到 SemaResult.type_descriptors 全局表
/// 去重：相同 type_id 不重复注册
pub fn registerTypeDescriptor(sema_result: *SemaResult, td: TypeDescriptor) !void {
    for (sema_result.type_descriptors.items) |existing| {
        if (existing.type_id == td.type_id) return;
    }
    try sema_result.type_descriptors.append(sema_result.allocator, td);
}

/// 注册所有内置标量 TypeDescriptor 到全局表
/// 在 collectMonomorphInstances 开头调用一次
pub fn registerBuiltinTypeDescriptors(sema_result: *SemaResult) !void {
    // 内置标量
    inline for (std.meta.fields(type_descriptor_mod.ScalarKind)) |field| {
        const kind: type_descriptor_mod.ScalarKind = @enumFromInt(field.value);
        const td = type_descriptor_mod.lookupByScalarKind(kind).*;
        try registerTypeDescriptor(sema_result, td);
    }
    // 引用/null/unit
    try registerTypeDescriptor(sema_result, ref_type_descriptor);
    try registerTypeDescriptor(sema_result, null_type_descriptor);
    try registerTypeDescriptor(sema_result, unit_type_descriptor);
}

/// 带 sema_result 的类型节点解析（支持 alias/newtype 链展开）
///
/// 迁自 builder.zig:9673 chanTypeFromTypeNodeResolved
/// 与 resolveTypeNode 的差异：named 分支查询 sema_result.type_defs，
/// 若为 alias/newtype 且 target_chan_type 已知，递归解析到具体标量类型。
///
/// 用于需要穿透 alias 链获取最终标量通道类型的场景（如 field_value 标量单态化）。
/// 无 sema_result 上下文时退化为 resolveTypeNode。
pub fn resolveTypeNodeResolved(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
    sema_result: ?*const ir_mod.SemaResult,
) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    return switch (tn.*) {
        .named => |n| blk: {
            // 1. 优先查 type_args 绑定（泛型类型参数）
            for (type_args) |*ta| {
                if (std.mem.eql(u8, ta.type_name, n.name)) break :blk ta;
            }
            // 2. 内置标量类型
            if (scalarKindFromName(n.name)) |kind| {
                break :blk type_descriptor_mod.lookupByScalarKind(kind);
            }
            // 3. str/unit
            if (std.mem.eql(u8, n.name, "str")) break :blk &ref_type_descriptor;
            if (std.mem.eql(u8, n.name, "void")) break :blk &unit_type_descriptor;
            // 4. 查 sema_result.type_defs 解析 alias/newtype 链
            if (sema_result) |sr| {
                if (sr.getTypeDef(n.name)) |td| {
                    if (td.target_type_desc) |inner_td| {
                        // alias/newtype 有目标 TypeDescriptor：直接返回
                        break :blk inner_td;
                    }
                    // target_type_name 已知但 target_type_desc 未知：递归解析
                    if (td.target_type_name) |ttn| {
                        var tmp: ast.TypeNode = .{ .named = .{ .name = ttn } };
                        break :blk resolveTypeNodeResolved(&tmp, type_args, sema_result) orelse &ref_type_descriptor;
                    }
                }
            }
            // 5. 其他用户自定义类型 → ref_chan
            break :blk &ref_type_descriptor;
        },
        .generic => |g| {
            // Lazy<T>：递归解析内部类型（与 IRBuilder chanTypeFromTypeNodeResolved 一致）
            if (std.mem.eql(u8, g.name, "Lazy")) {
                if (g.args.len > 0) {
                    return resolveTypeNodeResolved(g.args[0], type_args, sema_result) orelse resolveTypeNode(tn, type_args);
                }
            }
            return resolveTypeNode(tn, type_args);
        },
        .nullable => |nb| {
            // nullable<T>：递归解析 inner
            return resolveTypeNodeResolved(nb.inner, type_args, sema_result) orelse resolveTypeNode(tn, type_args);
        },
        // 其他类型与 resolveTypeNode 一致
        else => resolveTypeNode(tn, type_args),
    };
}

// ════════════════════════════════════════════════════════════
// chanTypeFrom* 系列（Task 3.11 迁移）
// ════════════════════════════════════════════════════════════

/// 类型名 → TypeDescriptor
/// 迁自 builder.zig:1482 chanTypeFromTypeName
/// 纯函数，无状态依赖
pub fn chanTypeFromTypeName(type_name: []const u8) *const TypeDescriptor {
    if (scalarKindFromName(type_name)) |kind| {
        return type_descriptor_mod.lookupByScalarKind(kind);
    }
    if (std.mem.eql(u8, type_name, "str")) return &ref_type_descriptor;
    if (std.mem.eql(u8, type_name, "void")) return &unit_type_descriptor;
    // nullable 类型 "T?" → 返回内部类型的 TypeDescriptor
    if (type_name.len > 1 and type_name[type_name.len - 1] == '?') {
        return chanTypeFromTypeName(type_name[0 .. type_name.len - 1]);
    }
    // 用户自定义类型（ADT/record/newtype）→ ref
    return &ref_type_descriptor;
}

/// type_id → TypeDescriptor
/// 迁自 builder.zig:9811 chanTypeFromTypeId
/// 依赖 sema_result.type_descriptors 全局表（v3 阶段 2 已产出）
/// type_id=0 → ref；其他 type_id 查 type_descriptors 表
pub fn chanTypeFromTypeId(sema_result: *const ir_mod.SemaResult, type_id: u16) *const TypeDescriptor {
    if (type_id == 0) return &ref_type_descriptor;
    for (sema_result.type_descriptors.items) |*td| {
        if (td.type_id == type_id) return td;
    }
    return &ref_type_descriptor;
}

/// 带类型绑定的 TypeNode → TypeDescriptor 解析
/// 迁自 builder.zig:9725 chanTypeFromTypeNodeBound
/// 优先查 TypeBindingContext（type_param 名 → 具体类型），
/// 未命中委托 resolveTypeNode（保持原行为）
pub fn chanTypeFromTypeNodeBound(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
    type_binding_ctx: ?*const TypeBindingContext,
) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .named => |n| {
            // 1. 先查类型绑定栈（type_param 名）
            if (type_binding_ctx) |ctx| {
                if (ctx.lookup(n.name)) |bt| return bt.type_desc;
            }
            // 2. 未命中委托 resolveTypeNode
            return resolveTypeNode(tn, type_args);
        },
        .nullable => |nb| {
            return chanTypeFromTypeNodeBound(nb.inner, type_args, type_binding_ctx) orelse resolveTypeNode(tn, type_args);
        },
        .ref_type, .raw_ptr => return &ref_type_descriptor,
        .kind_annotated => |ka| {
            return chanTypeFromTypeNodeBound(ka.inner, type_args, type_binding_ctx) orelse resolveTypeNode(tn, type_args);
        },
        else => return resolveTypeNode(tn, type_args),
    }
}

// 前向声明：TypeBindingContext 定义在 inference.zig，此处仅用于 chanTypeFromTypeNodeBound 签名
const TypeBindingContext = @import("inference.zig").TypeBindingContext;
