//! AST 类型谓词与转换辅助（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含从 AST TypeNode / Expr / Stmt 推导通道类型、类型名、布局等纯函数，
//! 以及 break/continue 检测、累加器模式识别等 AST 遍历辅助。
//! 这些函数不依赖 IRBuilder 运行时状态，可独立测试与复用。
//!
//! 同时承载 BuildError 错误类型，避免 builder.zig ↔ ast_traits.zig 循环依赖。

const std = @import("std");
const ast = @import("ast");
const scalar = @import("value").scalar;
const syscall = @import("syscall");
const sema = @import("sema");

const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const type_descriptor_mod = @import("type_descriptor.zig");
const builtin_type_names = @import("builtin_type_names.zig");

const SemaResult = sema.sema_output.SemaResult;
const sema_type_resolver = sema.type_resolver;

const NodeOp = node_mod.NodeOp;
const ChannelSpace = channel_mod.ChannelSpace;
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const LayoutInfo = meta_mod.LayoutInfo;
const IntKind = scalar.IntKind;
const FloatKind = scalar.FloatKind;

/// 图构建错误（从 builder.zig 迁入，避免循环依赖）
pub const BuildError = error{
    OutOfMemory,
    UnsupportedExpr,
    UnsupportedStmt,
    UnsupportedDecl,
    UnsupportedType,
    InvalidLiteral,
    UnboundVariable,
    UndefinedFunction,
    TransformFailed,
};

// ════════════════════════════════════════════════════════════════
// 字面量解析辅助
// ════════════════════════════════════════════════════════════════

/// 过滤数字字面量中的下划线，返回干净数字字符串
pub fn filterDigits(raw: []const u8, buf: *[64]u8) []const u8 {
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// 解包无语句 block：若 expr 为 block 且 statements 为空且有 trailing_expr，则返回 trailing_expr；否则返回 expr 本身
pub fn unwrapBlockExpr(expr: *const ast.Expr) *const ast.Expr {
    if (expr.* == .block) {
        const b = expr.block;
        if (b.statements.len == 0 and b.trailing_expr != null) {
            return b.trailing_expr.?;
        }
    }
    return expr;
}

/// 整数后缀 → IntKind
pub fn intKindFromSuffix(suffix: ?[]const u8) ?IntKind {
    const s = suffix orelse return null;
    return builtin_type_names.intKindFromName(s);
}

/// 浮点后缀 → FloatKind
pub fn floatKindFromSuffix(suffix: ?[]const u8) ?FloatKind {
    const s = suffix orelse return null;
    return builtin_type_names.floatKindFromName(s);
}

// ════════════════════════════════════════════════════════════════
// 运算符映射
// ════════════════════════════════════════════════════════════════

/// BinaryOp + 操作数类型 → NodeOp
pub fn binaryOpToNodeOp(op: ast.BinaryOp, operand_type: *const TypeDescriptor) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    const is_ref = operand_type.isRef();
    return switch (op) {
        .add => if (is_int) .int_add else if (is_float) .float_add else if (is_ref) .string_concat else return error.UnsupportedType,
        .sub => if (is_int) .int_sub else if (is_float) .float_sub else return error.UnsupportedType,
        .mul => if (is_int) .int_mul else if (is_float) .float_mul else return error.UnsupportedType,
        .div => if (is_int) .int_div else if (is_float) .float_div else return error.UnsupportedType,
        .mod => if (is_int) .int_mod else if (is_float) .float_mod else return error.UnsupportedType,
        .bit_and => if (is_int) .int_and else return error.UnsupportedType,
        .bit_or => if (is_int) .int_or else return error.UnsupportedType,
        .bit_xor => if (is_int) .int_xor else return error.UnsupportedType,
        .shl => if (is_int) .int_shl else return error.UnsupportedType,
        .shr => if (is_int) .int_shr else return error.UnsupportedType,
        .eq => .cmp_eq,
        .not_eq => .cmp_ne,
        .ref_eq => .builtin_ref_eq,
        .lt => .cmp_lt,
        .gt => .cmp_gt,
        .lt_eq => .cmp_le,
        .gt_eq => .cmp_ge,
        .and_op => .bool_and,
        .or_op => .bool_or,
        .concat_list => if (is_ref) .string_concat else return error.UnsupportedType,
        else => return error.UnsupportedExpr,
    };
}

/// UnaryOp + 操作数类型 → NodeOp
pub fn unaryOpToNodeOp(op: ast.UnaryOp, operand_type: *const TypeDescriptor) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    return switch (op) {
        .neg => if (is_int) .int_neg else if (is_float) .float_neg else return error.UnsupportedType,
        .bit_not => if (is_int) .int_not else return error.UnsupportedType,
        .not => .bool_not,
    };
}

/// 二元运算结果类型
pub fn binaryResultType(op: ast.BinaryOp, operand_type: *const TypeDescriptor) *const TypeDescriptor {
    return switch (op) {
        .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => type_descriptor_mod.bool_descriptor, // 比较输出 bool
        .and_op, .or_op => type_descriptor_mod.bool_descriptor,
        .concat_list => operand_type, // 字符串/数组拼接继承操作数类型
        else => operand_type, // 算术/位运算继承操作数类型
    };
}

/// BinaryOp → NodeOp 映射（仅算术和位运算，用于累加器模式识别）
pub fn binOpToNodeOp(op: ast.BinaryOp) ?NodeOp {
    return switch (op) {
        .add => .int_add,
        .sub => .int_sub,
        .mul => .int_mul,
        .div => .int_div,
        .mod => .int_mod,
        .bit_and => .int_and,
        .bit_or => .int_or,
        .bit_xor => .int_xor,
        else => null,
    };
}

// ════════════════════════════════════════════════════════════════
// TypeNode 谓词与拆包
// ════════════════════════════════════════════════════════════════

/// 判断类型节点是否为 Throw<T, E>
pub fn isThrowType(type_node: ?*ast.TypeNode) bool {
    const tn = type_node orelse return false;
    return switch (tn.*) {
        .generic => |g| std.mem.eql(u8, g.name, "Throw"),
        else => false,
    };
}

/// 若 type_node 为 Async<X>，返回 X；否则返回 type_node 本身。
/// async 函数返回 Async<T>，但函数体实际产出 T，throw/Ok 语义按 T 处理。
pub fn unwrapAsyncType(type_node: ?*ast.TypeNode) ?*ast.TypeNode {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "Async") and g.args.len > 0) {
                return g.args[0];
            }
        },
        else => {},
    }
    return type_node;
}

/// 从 Async<T> 类型节点提取内部类型 T
pub fn asyncInnerTypeNode(type_node: ?*ast.TypeNode) ?*ast.TypeNode {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Async")) return null;
            if (g.args.len < 1) return null;
            return g.args[0];
        },
        else => return null,
    }
}

/// 从 Throw<T, E> 类型节点提取 Ok 值的类型节点 T
pub fn throwOkTypeNode(type_node: ?*ast.TypeNode) ?*ast.TypeNode {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Throw")) return null;
            if (g.args.len < 1) return null;
            return g.args[0];
        },
        else => return null,
    }
}

/// 从 Throw<T, E> 类型节点提取 Ok 值的类型描述符
/// 无回退实现：委托 sema/type_resolver.resolveTypeNodeConcrete
pub fn throwOkChanType(type_node: ?*ast.TypeNode, sema_result: *SemaResult) ?*const TypeDescriptor {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Throw")) return null;
            if (g.args.len < 1) return null;
            return sema_type_resolver.resolveTypeNodeConcrete(g.args[0], &.{}, sema_result);
        },
        else => return null,
    }
}

/// 从 `Throw<T, E>` TypeNode 提取 Ok 值的类型名（T 的简单类型名）。
/// 用于 `val r = obj.method()?` 后对 r 做字段访问时推断类型。
/// 支持泛型参数为 .named（如 DateTime）和嵌套 nullable/kind_annotated。
pub fn throwOkTypeName(type_node: ?*ast.TypeNode) ?[]const u8 {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Throw")) return null;
            if (g.args.len < 1) return null;
            const ok_tn = g.args[0];
            return switch (ok_tn.*) {
                .named => |n| n.name,
                .self_type => "Self",
                .nullable => |nb| throwOkTypeName(nb.inner),
                .kind_annotated => |ka| throwOkTypeName(ka.inner),
                else => null,
            };
        },
        else => return null,
    }
}

/// 判断类型节点是否为字符串类型（str 或 str?）
pub fn isStringTypeNode(type_node: *const ast.TypeNode) bool {
    return switch (type_node.*) {
        .named => |n| std.mem.eql(u8, n.name, "str"),
        .nullable => |nb| isStringTypeNode(nb.inner),
        else => false,
    };
}

/// 判断类型节点是否为 nullable 类型（T?）
pub fn isNullableTypeNode(type_node: *const ast.TypeNode) bool {
    return switch (type_node.*) {
        .nullable => true,
        else => false,
    };
}

// ════════════════════════════════════════════════════════════════
// TypeNode → 类型名 / TypeDescriptor / 布局
// ════════════════════════════════════════════════════════════════

/// 从 TypeNode 提取类型名（不分配，用于快速查表）
/// 包装类型（nullable/ref_type/raw_ptr/kind_annotated）递归取内部名，
/// 复杂类型（function/record/array）返回 "?"。
pub fn typeNameFromTypeNodeConst(type_node: *const ast.TypeNode) []const u8 {
    return switch (type_node.*) {
        .named => |n| n.name,
        .self_type => "Self",
        // 泛型类型取基础名（如 Array<i32> → "Array"），args 信息由 type_desc 承载
        .generic => |g| g.name,
        // 包装类型递归取内部名：nullable/ref_type/raw_ptr/kind_annotated
        // 注：格式化时 nullable/ref 由 type_desc.is_nullable/is_ref 检测，
        // type_name 仅用于内部值的类型分派，返回内部名即可正确递归。
        .nullable => |nb| typeNameFromTypeNodeConst(nb.inner),
        .ref_type => |rb| typeNameFromTypeNodeConst(rb.inner),
        .raw_ptr => |rb| typeNameFromTypeNodeConst(rb.inner),
        .kind_annotated => |kb| typeNameFromTypeNodeConst(kb.inner),
        // 复杂类型（function/record/array）无法用单一名称表达
        else => "?",
    };
}

/// 从 TypeNode 提取类型名字符串（用于 TypeMetadata）
///
/// 分配在 arena_alloc 上，生命周期与 IRBuilder 一致。
/// 处理所有 TypeNode 变体：named、self_type、generic、nullable、function、record、array、kind_annotated。
pub fn typeNameFromTypeNode(
    type_node: *const ast.TypeNode,
    arena_alloc: std.mem.Allocator,
) ![]const u8 {
    return switch (type_node.*) {
        .named => |n| n.name,
        .self_type => "Self",
        .generic => |g| blk: {
            // 构造 "Name<arg1, arg2, ...>" 形式的字符串
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(arena_alloc);
            try buf.appendSlice(arena_alloc, g.name);
            try buf.append(arena_alloc, '<');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(arena_alloc, ", ");
                const arg_name = try typeNameFromTypeNode(arg, arena_alloc);
                try buf.appendSlice(arena_alloc, arg_name);
            }
            try buf.append(arena_alloc, '>');
            break :blk try buf.toOwnedSlice(arena_alloc);
        },
        .nullable => |nb| blk: {
            const inner_name = try typeNameFromTypeNode(nb.inner, arena_alloc);
            break :blk try std.fmt.allocPrint(arena_alloc, "{s}?", .{inner_name});
        },
        .ref_type => |rt| blk: {
            const inner_name = try typeNameFromTypeNode(rt.inner, arena_alloc);
            break :blk try std.fmt.allocPrint(arena_alloc, "&{s}", .{inner_name});
        },
        .raw_ptr => |rp| blk: {
            const inner_name = try typeNameFromTypeNode(rp.inner, arena_alloc);
            break :blk try std.fmt.allocPrint(arena_alloc, "*{s}", .{inner_name});
        },
        .function => "fn",
        .record => "Record",
        .array => "Array",
        .kind_annotated => |ka| try typeNameFromTypeNode(ka.inner, arena_alloc),
    };
}

/// 基础类型布局查询
/// 返回 null 表示不是基础类型（交由 layoutOfTypeName 处理用户类型）
/// 返回 meta.LayoutInfo（与 TypeMetadata.layout 同类型）
pub fn primitiveLayout(name: []const u8) ?LayoutInfo {
    const Entry = struct { n: []const u8, s: u32, a: u32 };
    const table = [_]Entry{
        .{ .n = "bool", .s = 1, .a = 1 },
        .{ .n = "char", .s = 4, .a = 4 },
        .{ .n = "i8", .s = 1, .a = 1 },
        .{ .n = "u8", .s = 1, .a = 1 },
        .{ .n = "i16", .s = 2, .a = 2 },
        .{ .n = "u16", .s = 2, .a = 2 },
        .{ .n = "i32", .s = 4, .a = 4 },
        .{ .n = "u32", .s = 4, .a = 4 },
        .{ .n = "i64", .s = 8, .a = 8 },
        .{ .n = "u64", .s = 8, .a = 8 },
        .{ .n = "i128", .s = 16, .a = 16 },
        .{ .n = "u128", .s = 16, .a = 16 },
        .{ .n = "f16", .s = 2, .a = 2 },
        .{ .n = "f32", .s = 4, .a = 4 },
        .{ .n = "f64", .s = 8, .a = 8 },
        .{ .n = "f128", .s = 16, .a = 16 },
        .{ .n = "str", .s = 16, .a = 8 }, // Str 对象指针 + 长度
        .{ .n = "void", .s = 0, .a = 1 },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.n, name)) {
            return .{ .size = e.s, .alignment = e.a };
        }
    }
    return null;
}

/// 对齐到指定对齐值
pub fn alignUp(offset: u32, alignment: u32) u32 {
    if (alignment <= 1) return offset;
    const mask = alignment - 1;
    return (offset + mask) & ~mask;
}

/// SyscallRetKind → TypeDescriptor 转换（ir 层独有，将 syscall 模块的返回类型分类映射到 IR 类型描述符）
///
/// 这是从 syscall.SyscallRetKind 到 ir TypeDescriptor 的唯一适配点。
/// syscall 模块不依赖 ir（不知道 TypeDescriptor），故此转换在 ir 层完成。
pub fn retKindToChanType(kind: syscall.SyscallRetKind) *const TypeDescriptor {
    return switch (kind) {
        .ref => type_descriptor_mod.ref_descriptor,
        .i128 => type_descriptor_mod.i128_descriptor,
        .i32 => type_descriptor_mod.i32_descriptor,
        .unit => type_descriptor_mod.unit_descriptor,
    };
}

/// 从 TypeNode 推导类型描述符
/// 无回退实现：委托 sema/type_resolver.resolveTypeNodeConcrete（通过 getOrCreateRefDesc 为用户类型创建具名描述符）
pub fn chanTypeFromTypeNode(type_node: ?*ast.TypeNode, sema_result: *SemaResult) ?*const TypeDescriptor {
    return sema_type_resolver.resolveTypeNodeConcrete(type_node, &.{}, sema_result);
}

/// 分配类型节点对应的通道（正确处理 nullable 类型）
/// 返回通道索引
pub fn allocChanFromTypeNode(channels: *ChannelSpace, type_node: ?*ast.TypeNode, sema_result: *SemaResult) !u16 {
    const tn = type_node orelse return try channels.alloc(type_descriptor_mod.i64_descriptor);
    return switch (tn.*) {
        .nullable => |nb| {
            const inner_td = chanTypeFromTypeNode(nb.inner, sema_result) orelse sema_result.getOrCreateRefDesc("unknown") catch unreachable;
            return try channels.allocNullable(inner_td);
        },
        else => {
            const td = chanTypeFromTypeNode(tn, sema_result) orelse type_descriptor_mod.i64_descriptor;
            return try channels.alloc(td);
        },
    };
}

// ════════════════════════════════════════════════════════════════
// AST 遍历辅助：break/continue 检测
// ════════════════════════════════════════════════════════════════

pub fn astContainsBreakOrContinueExpr(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (astContainsBreakOrContinueStmt(s)) return true;
            }
            if (b.trailing_expr) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .if_expr => |ie| {
            if (astContainsBreakOrContinueExpr(ie.then_branch)) return true;
            if (ie.else_branch) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .binary => |b| {
            return astContainsBreakOrContinueExpr(b.left) or astContainsBreakOrContinueExpr(b.right);
        },
        .unary => |u| return astContainsBreakOrContinueExpr(u.operand),
        .ref_of => |r| return astContainsBreakOrContinueExpr(r.operand),
        .deref => |d| return astContainsBreakOrContinueExpr(d.operand),
        .call => |c| {
            if (astContainsBreakOrContinueExpr(c.callee)) return true;
            for (c.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .safe_method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .field_access => |fa| return astContainsBreakOrContinueExpr(fa.object),
        .safe_access => |sa| return astContainsBreakOrContinueExpr(sa.object),
        .index => |idx| return astContainsBreakOrContinueExpr(idx.object) or astContainsBreakOrContinueExpr(idx.index),
        .slice => |sl| return astContainsBreakOrContinueExpr(sl.object) or astContainsBreakOrContinueExpr(sl.start) or astContainsBreakOrContinueExpr(sl.end),
        .non_null_assert => |nn| return astContainsBreakOrContinueExpr(nn.expr),
        .propagate => |p| return astContainsBreakOrContinueExpr(p.expr),
        .assignment_expr => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .compound_assign => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .match => |m| {
            if (astContainsBreakOrContinueExpr(m.scrutinee)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (astContainsBreakOrContinueExpr(g)) return true;
                if (astContainsBreakOrContinueExpr(arm.body)) return true;
            }
            return false;
        },
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    if (astContainsBreakOrContinueExpr(r.channel_expr)) return true;
                    if (astContainsBreakOrContinueExpr(r.body)) return true;
                },
                .timeout => |t| {
                    if (astContainsBreakOrContinueExpr(t.duration)) return true;
                    if (astContainsBreakOrContinueExpr(t.body)) return true;
                },
            };
            return false;
        },
        .type_cast => |tc| return astContainsBreakOrContinueExpr(tc.expr),
        .atomic_expr => |ae| return astContainsBreakOrContinueExpr(ae.value),
        .lazy => |l| return astContainsBreakOrContinueExpr(l.expr),
        .spawn_expr => |se| return astContainsBreakOrContinueExpr(se.expr),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (astContainsBreakOrContinueExpr(e)) return true;
            }
            return false;
        },
        .record_literal => |rl| {
            for (rl.fields) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .record_extend => |re| {
            if (astContainsBreakOrContinueExpr(re.base)) return true;
            for (re.updates) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .string_interpolation => |si| {
            for (si.parts) |p| switch (p) {
                .literal => {},
                .expression => |e| if (astContainsBreakOrContinueExpr(e)) return true,
            };
            return false;
        },
        .lambda => return false, // lambda 体不在当前循环上下文中
        .inline_trait_value => return false,
        else => return false,
    }
}

pub fn astContainsBreakOrContinueStmt(stmt: *const ast.Stmt) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return true,
        .expression => |e| return astContainsBreakOrContinueExpr(e.expr),
        .val_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .var_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .assignment => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .field_assignment => |fa| return astContainsBreakOrContinueExpr(fa.object) or astContainsBreakOrContinueExpr(fa.value),
        .compound_assignment => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .return_stmt => |rs| if (rs.value) |v| return astContainsBreakOrContinueExpr(v),
        .defer_stmt => |ds| return astContainsBreakOrContinueExpr(ds.expr),
        .throw_stmt => |ts| return astContainsBreakOrContinueExpr(ts.expr),
        .for_stmt => |fs| return astContainsBreakOrContinueExpr(fs.body) or astContainsBreakOrContinueExpr(fs.iterable),
        .while_stmt => |ws| return astContainsBreakOrContinueExpr(ws.body) or astContainsBreakOrContinueExpr(ws.condition),
        .loop_stmt => |ls| return astContainsBreakOrContinueExpr(ls.body),
    }
    return false;
}

// ════════════════════════════════════════════════════════════════
// 累加器模式 / break-continue 条件提取
// ════════════════════════════════════════════════════════════════

/// 累加器模式提取结果
pub const AccumulatorPattern = struct {
    acc_name: []const u8,
    fold_op: NodeOp,
    value_expr: *const ast.Expr,
};

/// 从语句中提取累加器模式：acc = acc OP expr 或 acc OP= expr
/// 仅匹配直接赋值和复合赋值，不匹配字段赋值或 if 内的条件赋值
/// 返回 null 表示不是累加器模式
pub fn extractAccumulatorPattern(stmt: *const ast.Stmt, loop_var: []const u8) ?AccumulatorPattern {
    switch (stmt.*) {
        // 复合赋值：acc += expr, acc -= expr, acc *= expr
        .compound_assignment => |ca| {
            if (ca.target.* != .identifier) return null;
            const name = ca.target.identifier.name;
            if (std.mem.eql(u8, name, loop_var)) return null; // 循环变量自身，不算累加器
            const fold_op: NodeOp = switch (ca.op) {
                .add_assign => .int_add,
                .sub_assign => .int_sub,
                .mul_assign => .int_mul,
                else => return null, // div/mod/等暂不支持
            };
            return .{
                .acc_name = name,
                .fold_op = fold_op,
                .value_expr = ca.value,
            };
        },
        // 直接赋值：acc = acc OP expr 或 acc = expr OP acc
        .assignment => |a| {
            if (a.target.* != .identifier) return null;
            const name = a.target.identifier.name;
            if (std.mem.eql(u8, name, loop_var)) return null;
            if (a.value.* != .binary) return null;
            const bin = a.value.binary;

            // acc = acc OP expr
            if (bin.left.* == .identifier and std.mem.eql(u8, bin.left.identifier.name, name)) {
                const fold_op = binOpToNodeOp(bin.op) orelse return null;
                return .{
                    .acc_name = name,
                    .fold_op = fold_op,
                    .value_expr = bin.right,
                };
            }
            // acc = expr OP acc（仅交换律运算：add/mul/and/or/xor）
            if (bin.right.* == .identifier and std.mem.eql(u8, bin.right.identifier.name, name)) {
                const fold_op = binOpToNodeOp(bin.op) orelse return null;
                // 非交换律（sub/div/mod/shr）不允许左右交换
                switch (fold_op) {
                    .int_sub, .int_div, .int_mod => return null,
                    else => {},
                }
                return .{
                    .acc_name = name,
                    .fold_op = fold_op,
                    .value_expr = bin.left,
                };
            }
            return null;
        },
        else => return null,
    }
}

/// break/continue 条件提取结果
pub const BreakContinueCond = struct {
    is_break: bool,
    cond: *const ast.Expr,
};

/// 从 if 语句中提取 break/continue 条件
/// 支持形式：`if cond { break }` 或 `if cond { continue }`
/// 要求 then 分支只有一个 break/continue 语句，无 else 分支，无 trailing_expr
/// 返回 null 表示不是可提取的 break/continue if 模式
pub fn tryExtractBreakContinueCond(stmt: *const ast.Stmt) ?BreakContinueCond {
    if (stmt.* != .expression) return null;
    const expr = stmt.expression.expr;
    if (expr.* != .if_expr) return null;
    const ie = expr.if_expr;
    if (ie.else_branch != null) return null;
    // then 分支必须是 block 且只有一个 break/continue 语句
    if (ie.then_branch.* != .block) return null;
    const then_block = ie.then_branch.block;
    if (then_block.statements.len != 1) return null;
    if (then_block.trailing_expr != null) return null;
    const inner = then_block.statements[0];
    const is_break = inner.* == .break_stmt;
    const is_continue = inner.* == .continue_stmt;
    if (!is_break and !is_continue) return null;
    return BreakContinueCond{
        .is_break = is_break,
        .cond = ie.condition,
    };
}

// ════════════════════════════════════════════════════════════════
// 跨迭代依赖检测（向量化安全检查）
// ════════════════════════════════════════════════════════════════

/// 检查表达式中是否包含对 loop_var 之外变量的赋值（跨迭代依赖检测）
/// 用于 while→vec_map 向量化安全检查：body 中不能有对外部变量的赋值
pub fn astContainsExternalAssignExpr(expr: *const ast.Expr, loop_var: []const u8) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (astContainsExternalAssignStmt(s, loop_var)) return true;
            }
            if (b.trailing_expr) |e| return astContainsExternalAssignExpr(e, loop_var);
            return false;
        },
        .if_expr => |ie| {
            if (astContainsExternalAssignExpr(ie.then_branch, loop_var)) return true;
            if (ie.else_branch) |e| return astContainsExternalAssignExpr(e, loop_var);
            return false;
        },
        .binary => |b| return astContainsExternalAssignExpr(b.left, loop_var) or astContainsExternalAssignExpr(b.right, loop_var),
        .unary => |u| return astContainsExternalAssignExpr(u.operand, loop_var),
        .ref_of => |r| return astContainsExternalAssignExpr(r.operand, loop_var),
        .deref => |d| return astContainsExternalAssignExpr(d.operand, loop_var),
        .call => |c| {
            if (astContainsExternalAssignExpr(c.callee, loop_var)) return true;
            for (c.arguments) |a| {
                if (astContainsExternalAssignExpr(a, loop_var)) return true;
            }
            return false;
        },
        .method_call => |mc| {
            if (astContainsExternalAssignExpr(mc.object, loop_var)) return true;
            for (mc.arguments) |a| {
                if (astContainsExternalAssignExpr(a, loop_var)) return true;
            }
            return false;
        },
        .match => |m| {
            if (astContainsExternalAssignExpr(m.scrutinee, loop_var)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (astContainsExternalAssignExpr(g, loop_var)) return true;
                if (astContainsExternalAssignExpr(arm.body, loop_var)) return true;
            }
            return false;
        },
        .assignment_expr => |a| {
            // 赋值表达式本身：检查目标是否是 loop_var 之外的变量
            if (a.target.* == .identifier and !std.mem.eql(u8, a.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(a.value, loop_var);
        },
        .compound_assign => |ca| {
            if (ca.target.* == .identifier and !std.mem.eql(u8, ca.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(ca.value, loop_var);
        },
        else => return false,
    }
}

pub fn astContainsExternalAssignStmt(stmt: *const ast.Stmt, loop_var: []const u8) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return false,
        .expression => |e| return astContainsExternalAssignExpr(e.expr, loop_var),
        .val_decl => |vd| return astContainsExternalAssignExpr(vd.value, loop_var),
        .var_decl => |vd| return astContainsExternalAssignExpr(vd.value, loop_var),
        .assignment => |a| {
            // 对 loop_var 之外变量的赋值 = 跨迭代依赖
            if (a.target.* == .identifier and !std.mem.eql(u8, a.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(a.value, loop_var);
        },
        .field_assignment => {
            // 字段赋值总是跨迭代依赖（修改外部对象状态）
            return true;
        },
        .compound_assignment => |ca| {
            if (ca.target.* == .identifier and !std.mem.eql(u8, ca.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(ca.value, loop_var);
        },
        .return_stmt => |rs| if (rs.value) |v| return astContainsExternalAssignExpr(v, loop_var),
        .defer_stmt => |ds| return astContainsExternalAssignExpr(ds.expr, loop_var),
        .throw_stmt => |ts| return astContainsExternalAssignExpr(ts.expr, loop_var),
        .for_stmt => |fs| return astContainsExternalAssignExpr(fs.body, loop_var) or astContainsExternalAssignExpr(fs.iterable, loop_var),
        .while_stmt => |ws| return astContainsExternalAssignExpr(ws.body, loop_var) or astContainsExternalAssignExpr(ws.condition, loop_var),
        .loop_stmt => |ls| return astContainsExternalAssignExpr(ls.body, loop_var),
    }
    return false;
}
