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

/// 带 TypeDescriptorPool 的类型节点解析（废除 ref_chan：为用户类型创建具体描述符）
/// 无回退实现：所有用户类型通过 getOrCreateRefDesc 创建具名描述符
/// 不返回 null（除非 type_node 本身为 null），OOM 通过 unreachable 触发 panic
///（arena allocator 在 64 位系统上不会 OOM）
pub fn resolveTypeNodeConcrete(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
    sema_result: *ir_mod.SemaResult,
) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    const unit_desc = ir_mod.type_descriptor_mod.unit_descriptor;
    const str_desc = ir_mod.type_descriptor_mod.str_descriptor;
    return switch (tn.*) {
        .named => |n| {
            // 优先查 type_args 绑定（泛型类型参数，按类型参数名匹配）
            for (type_args) |*ta| {
                if (std.mem.eql(u8, ta.type_name, n.name)) return ta;
            }
            // 内置标量类型
            if (scalarKindFromName(n.name)) |kind| {
                return type_descriptor_mod.lookupByScalarKind(kind);
            }
            // str → str_descriptor
            if (std.mem.eql(u8, n.name, "str")) return str_desc;
            // unit → unit_chan
            if (std.mem.eql(u8, n.name, "void")) return unit_desc;
            // 用户自定义类型 → pool 创建具体引用描述符
            return sema_result.getOrCreateRefDesc(n.name) catch unreachable;
        },
        .generic => |g| {
            // 泛型类型如 Lst<T> → "Lst" 具体引用描述符
            return sema_result.getOrCreateRefDesc(g.name) catch unreachable;
        },
        .nullable => |nb| {
            return resolveTypeNodeConcrete(nb.inner, type_args, sema_result);
        },
        .ref_type => |rt| {
            // &T → 具体引用描述符（按 inner 类型名）
            const inner_name = typeNameFromNode(rt.inner) orelse "ref";
            return sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .raw_ptr => |rp| {
            const inner_name = typeNameFromNode(rp.inner) orelse "ptr";
            return sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .record => sema_result.getOrCreateRefDesc("record") catch unreachable,
        .function => sema_result.getOrCreateRefDesc("fn") catch unreachable,
        .array => sema_result.getOrCreateRefDesc("array") catch unreachable,
        .self_type => sema_result.getOrCreateRefDesc("Self") catch unreachable,
        .kind_annotated => |ka| resolveTypeNodeConcrete(ka.inner, type_args, sema_result),
    };
}

/// 将 ConcreteType 转换为 TypeDescriptor
/// 迁自 type_check.zig:50 semaTypeToChanType（升级为返回 TypeDescriptor）
/// 无回退实现：命名用户类型（adt/generic/trait）通过 getOrCreateRefDesc 创建具名描述符
pub fn fromConcreteType(ct: concrete_type.ConcreteType, sema_result: *SemaResult) ?*const TypeDescriptor {
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
        .str_type => ir_mod.type_descriptor_mod.str_descriptor,
        .null_type => ir_mod.type_descriptor_mod.null_descriptor,
        .unit_type => ir_mod.type_descriptor_mod.unit_descriptor,
        // 命名用户类型 → getOrCreateRefDesc（具名描述符，无回退）
        .adt_type => |at| sema_result.getOrCreateRefDesc(at.name) catch unreachable,
        .generic_type => |gt| sema_result.getOrCreateRefDesc(gt.name) catch unreachable,
        .trait_type => |tt| sema_result.getOrCreateRefDesc(tt.name) catch unreachable,
        // 匿名复合类型 → 具名描述符（无回退到 ref_descriptor）
        .record_type => sema_result.getOrCreateRefDesc("record") catch unreachable,
        .array_type => sema_result.getOrCreateRefDesc("array") catch unreachable,
        .fn_type => sema_result.getOrCreateRefDesc("fn") catch unreachable,
        // 包装类型：递归取内部，无回退（用 "unknown" 具名描述符）
        .nullable_type => |inner| fromConcreteType(inner.*, sema_result) orelse sema_result.getOrCreateRefDesc("unknown") catch unreachable,
        .ref_type => sema_result.getOrCreateRefDesc("ref") catch unreachable,
        .throw_type => |tt| fromConcreteType(tt.value_type.*, sema_result) orelse sema_result.getOrCreateRefDesc("unknown") catch unreachable,
        // 类型变量/未知/never：无法静态确定
        .type_var,
        .unknown_type,
        .never_type,
        => null,
    };
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
/// 无回退实现：所有用户类型通过 getOrCreateRefDesc 创建具名描述符。
pub fn resolveTypeNodeResolved(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
    sema_result: *ir_mod.SemaResult,
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
            // 3. str → str_descriptor（具体引用类型，type_id=19）
            if (std.mem.eql(u8, n.name, "str")) break :blk ir_mod.type_descriptor_mod.str_descriptor;
            if (std.mem.eql(u8, n.name, "void")) break :blk &unit_type_descriptor;
            // 4. 查 sema_result.type_defs 解析 alias/newtype 链
            if (sema_result.getTypeDef(n.name)) |td| {
                if (td.target_type_desc) |inner_td| {
                    // alias/newtype 有目标 TypeDescriptor：直接返回
                    break :blk inner_td;
                }
                // target_type_name 已知但 target_type_desc 未知：递归解析
                if (td.target_type_name) |ttn| {
                    var tmp: ast.TypeNode = .{ .named = .{ .name = ttn } };
                    break :blk resolveTypeNodeResolved(&tmp, type_args, sema_result) orelse
                        sema_result.getOrCreateRefDesc(ttn) catch unreachable;
                }
            }
            // 5. 其他用户自定义类型 → 创建具名描述符（无回退）
            break :blk sema_result.getOrCreateRefDesc(n.name) catch unreachable;
        },
        .generic => |g| blk: {
            // Lazy<T>：递归解析内部类型
            if (std.mem.eql(u8, g.name, "Lazy")) {
                if (g.args.len > 0) {
                    break :blk resolveTypeNodeResolved(g.args[0], type_args, sema_result) orelse
                        sema_result.getOrCreateRefDesc("Lazy") catch unreachable;
                }
            }
            // 泛型类型如 Lst<T> → 创建具名描述符
            break :blk sema_result.getOrCreateRefDesc(g.name) catch unreachable;
        },
        .nullable => |nb| resolveTypeNodeResolved(nb.inner, type_args, sema_result),
        .ref_type => |rt| blk: {
            const inner_name = typeNameFromNode(rt.inner) orelse "ref";
            break :blk sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .raw_ptr => |rp| blk: {
            const inner_name = typeNameFromNode(rp.inner) orelse "ptr";
            break :blk sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .record => sema_result.getOrCreateRefDesc("record") catch unreachable,
        .function => sema_result.getOrCreateRefDesc("fn") catch unreachable,
        .array => sema_result.getOrCreateRefDesc("array") catch unreachable,
        .self_type => sema_result.getOrCreateRefDesc("Self") catch unreachable,
        .kind_annotated => |ka| resolveTypeNodeResolved(ka.inner, type_args, sema_result),
    };
}

// ════════════════════════════════════════════════════════════
// chanTypeFrom* 系列（Task 3.11 迁移）
// ════════════════════════════════════════════════════════════

/// 类型名 → TypeDescriptor
/// 迁自 builder.zig:1482 chanTypeFromTypeName
/// 无回退实现：用户自定义类型通过 getOrCreateRefDesc 创建具名描述符
pub fn chanTypeFromTypeName(type_name: []const u8, sema_result: *ir_mod.SemaResult) *const TypeDescriptor {
    if (scalarKindFromName(type_name)) |kind| {
        return type_descriptor_mod.lookupByScalarKind(kind);
    }
    if (std.mem.eql(u8, type_name, "str")) return ir_mod.type_descriptor_mod.str_descriptor;
    if (std.mem.eql(u8, type_name, "void")) return &unit_type_descriptor;
    // nullable 类型 "T?" → 返回内部类型的 TypeDescriptor
    if (type_name.len > 1 and type_name[type_name.len - 1] == '?') {
        return chanTypeFromTypeName(type_name[0 .. type_name.len - 1], sema_result);
    }
    // 用户自定义类型（ADT/record/newtype）→ 创建具名描述符（无回退）
    return sema_result.getOrCreateRefDesc(type_name) catch unreachable;
}

/// type_id → TypeDescriptor
/// 迁自 builder.zig:9811 chanTypeFromTypeId
/// 依赖 sema_result.type_descriptors 全局表（v3 阶段 2 已产出）
/// type_id=0 → 具名 "unknown" 描述符；其他 type_id 查 type_descriptors 表
pub fn chanTypeFromTypeId(sema_result: *ir_mod.SemaResult, type_id: u16) *const TypeDescriptor {
    if (type_id == 0) return sema_result.getOrCreateRefDesc("unknown") catch unreachable;
    // str 描述符（type_id=19）
    if (type_id == 19) return ir_mod.type_descriptor_mod.str_descriptor;
    // 标量描述符 (type_id 1-18)
    if (type_id >= 1 and type_id <= 18) {
        if (type_descriptor_mod.lookupByTypeId(type_id)) |td| return td;
    }
    // 动态描述符 (type_id 20+)：查 type_descriptors 表
    for (sema_result.type_descriptors.items) |*td| {
        if (td.type_id == type_id) return td;
    }
    // 查 type_desc_pool
    var it = sema_result.type_desc_pool.cache.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.type_id == type_id) return entry.value_ptr.*;
    }
    // 未找到 → 创建具名 "unknown" 描述符（无回退到 ref_descriptor）
    return sema_result.getOrCreateRefDesc("unknown") catch unreachable;
}

/// 带类型绑定的 TypeNode → TypeDescriptor 解析
/// 迁自 builder.zig:9725 chanTypeFromTypeNodeBound
/// 优先查 TypeBindingContext（type_param 名 → 具体类型），
/// 未命中委托 resolveTypeNodeConcrete（无回退实现）
pub fn chanTypeFromTypeNodeBound(
    type_node: ?*const ast.TypeNode,
    type_args: []const TypeDescriptor,
    type_binding_ctx: ?*const TypeBindingContext,
    sema_result: *ir_mod.SemaResult,
) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    return switch (tn.*) {
        .named => |n| blk: {
            // 1. 先查类型绑定栈（type_param 名）
            if (type_binding_ctx) |ctx| {
                if (ctx.lookup(n.name)) |bt| break :blk bt.type_desc;
            }
            // 2. 查 type_args 绑定（泛型类型参数，按 type_name 匹配）
            for (type_args) |*ta| {
                if (std.mem.eql(u8, ta.type_name, n.name)) break :blk ta;
            }
            // 3. 内置标量类型
            if (scalarKindFromName(n.name)) |kind| {
                break :blk type_descriptor_mod.lookupByScalarKind(kind);
            }
            // 4. str/unit
            if (std.mem.eql(u8, n.name, "str")) break :blk ir_mod.type_descriptor_mod.str_descriptor;
            if (std.mem.eql(u8, n.name, "void")) break :blk &unit_type_descriptor;
            // 5. 用户自定义类型 → 创建具名描述符（无回退）
            break :blk sema_result.getOrCreateRefDesc(n.name) catch unreachable;
        },
        .nullable => |nb| chanTypeFromTypeNodeBound(nb.inner, type_args, type_binding_ctx, sema_result),
        .generic => |g| sema_result.getOrCreateRefDesc(g.name) catch unreachable,
        .ref_type => |rt| blk: {
            const inner_name = typeNameFromNode(rt.inner) orelse "ref";
            break :blk sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .raw_ptr => |rp| blk: {
            const inner_name = typeNameFromNode(rp.inner) orelse "ptr";
            break :blk sema_result.getOrCreateRefDesc(inner_name) catch unreachable;
        },
        .record => sema_result.getOrCreateRefDesc("record") catch unreachable,
        .function => sema_result.getOrCreateRefDesc("fn") catch unreachable,
        .array => sema_result.getOrCreateRefDesc("array") catch unreachable,
        .self_type => sema_result.getOrCreateRefDesc("Self") catch unreachable,
        .kind_annotated => |ka| chanTypeFromTypeNodeBound(ka.inner, type_args, type_binding_ctx, sema_result),
    };
}

// 前向声明：TypeBindingContext 定义在 inference.zig，此处仅用于 chanTypeFromTypeNodeBound 签名
const TypeBindingContext = @import("inference.zig").TypeBindingContext;
