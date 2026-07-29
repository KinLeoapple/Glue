//! OpTable 多维属性表（v3 阶段 5）
//!
//! 单张表覆盖 NodeOp 的所有静态属性维度，替代 5-9 处散落的 switch：
//! - node.zig isScalar/isVector/isHalt（node.zig:151/161/171）
//! - engine.zig precomputeNodeTags（engine.zig:1571）
//! - engine.zig nodeOpToBatchBinOp/UnaryOp（engine.zig:1880/1972）
//! - optimizer.zig isConstantOp/foldBinaryOp（optimizer.zig:164/207）
//! - engine.zig "has_nested" 检查（engine.zig:6244）
//!
//! 注意：exec_fn（执行函数）不在此表，因为 ir 模块不能依赖 engine 模块
//! （engine imports ir，反向依赖会成环）。Engine 层维护自己的 exec_fn 分派表。
//!
//! 属性来源（ground truth）：
//! - is_scalar/is_vector/is_halt：node.zig 的 isScalar/isVector/isHalt
//! - foldable：optimizer.zig 的 isConstantOp（const_*）+ foldBinaryOp 成功分支
//!   （int_add/sub/mul/div/mod/and/or/xor + cmp_* + bool_and/or）。
//!   int_shl/int_shr 返回 null（不折叠），float_* 不折叠，一元 op 不参与。
//! - batch_bin_op/batch_unary_op：engine.zig nodeOpToBatchBinOp/UnaryOp
//! - has_nested：engine.zig:6244 子图节点检查
//!   （vec_map/vec_map2/vec_fold/vec_scan/vec_filter/vec_take_while/
//!    cleanup_register/route_dispatch/scalar_loop/closure_make）

const std = @import("std");
const node_mod = @import("node.zig");
const NodeOp = node_mod.NodeOp;
const batch = @import("value").batch;
const BatchBinOp = batch.BinOp;
const BatchUnaryOp = batch.UnaryOp;

/// Op 分类（单一主分类，与谓词字段互补）
pub const OpCategory = enum { scalar, vector, halt, nested, other };

pub const OpEntry = struct {
    op: NodeOp,
    name: []const u8,
    category: OpCategory,
    is_scalar: bool = false,
    is_vector: bool = false,
    is_halt: bool = false,
    has_nested: bool = false,
    foldable: bool = false,
    batch_bin_op: ?BatchBinOp = null,
    batch_unary_op: ?BatchUnaryOp = null,
};

pub const OP_TABLE: std.EnumArray(NodeOp, OpEntry) = blk: {
    @setEvalBranchQuota(20000);
    var t = std.EnumArray(NodeOp, OpEntry).initUndefined();

    // === 常量（scalar, is_scalar, foldable） ===
    t.set(.const_i, .{ .op = .const_i, .name = "const_i", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_f, .{ .op = .const_f, .name = "const_f", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_bool, .{ .op = .const_bool, .name = "const_bool", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_char, .{ .op = .const_char, .name = "const_char", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_str, .{ .op = .const_str, .name = "const_str", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_null, .{ .op = .const_null, .name = "const_null", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.const_unit, .{ .op = .const_unit, .name = "const_unit", .category = .scalar, .is_scalar = true, .foldable = true });

    // === 整数算术（scalar, is_scalar） ===
    t.set(.int_add, .{ .op = .int_add, .name = "int_add", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .add });
    t.set(.int_sub, .{ .op = .int_sub, .name = "int_sub", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .sub });
    t.set(.int_mul, .{ .op = .int_mul, .name = "int_mul", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .mul });
    t.set(.int_div, .{ .op = .int_div, .name = "int_div", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .div });
    t.set(.int_mod, .{ .op = .int_mod, .name = "int_mod", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .mod });
    t.set(.int_and, .{ .op = .int_and, .name = "int_and", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .band });
    t.set(.int_or, .{ .op = .int_or, .name = "int_or", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .bor });
    t.set(.int_xor, .{ .op = .int_xor, .name = "int_xor", .category = .scalar, .is_scalar = true, .foldable = true, .batch_bin_op = .bxor });
    // 移位：foldBinaryOp 返回 null（按实际位宽移位，编译期无法感知），nodeOpToBatchBinOp 不映射
    t.set(.int_shl, .{ .op = .int_shl, .name = "int_shl", .category = .scalar, .is_scalar = true });
    t.set(.int_shr, .{ .op = .int_shr, .name = "int_shr", .category = .scalar, .is_scalar = true });
    t.set(.int_not, .{ .op = .int_not, .name = "int_not", .category = .scalar, .is_scalar = true, .batch_unary_op = .bnot });
    t.set(.int_neg, .{ .op = .int_neg, .name = "int_neg", .category = .scalar, .is_scalar = true, .batch_unary_op = .neg });
    t.set(.int_abs, .{ .op = .int_abs, .name = "int_abs", .category = .scalar, .is_scalar = true, .batch_unary_op = .abs });

    // === 浮点算术（scalar, is_scalar, 不折叠） ===
    t.set(.float_add, .{ .op = .float_add, .name = "float_add", .category = .scalar, .is_scalar = true, .batch_bin_op = .add });
    t.set(.float_sub, .{ .op = .float_sub, .name = "float_sub", .category = .scalar, .is_scalar = true, .batch_bin_op = .sub });
    t.set(.float_mul, .{ .op = .float_mul, .name = "float_mul", .category = .scalar, .is_scalar = true, .batch_bin_op = .mul });
    t.set(.float_div, .{ .op = .float_div, .name = "float_div", .category = .scalar, .is_scalar = true, .batch_bin_op = .div });
    t.set(.float_mod, .{ .op = .float_mod, .name = "float_mod", .category = .scalar, .is_scalar = true, .batch_bin_op = .mod });
    t.set(.float_neg, .{ .op = .float_neg, .name = "float_neg", .category = .scalar, .is_scalar = true, .batch_unary_op = .neg });
    t.set(.float_abs, .{ .op = .float_abs, .name = "float_abs", .category = .scalar, .is_scalar = true, .batch_unary_op = .abs });

    // === 比较（scalar, is_scalar, foldable） ===
    t.set(.cmp_eq, .{ .op = .cmp_eq, .name = "cmp_eq", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.cmp_ne, .{ .op = .cmp_ne, .name = "cmp_ne", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.cmp_lt, .{ .op = .cmp_lt, .name = "cmp_lt", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.cmp_le, .{ .op = .cmp_le, .name = "cmp_le", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.cmp_gt, .{ .op = .cmp_gt, .name = "cmp_gt", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.cmp_ge, .{ .op = .cmp_ge, .name = "cmp_ge", .category = .scalar, .is_scalar = true, .foldable = true });

    // === 布尔逻辑（scalar, is_scalar） ===
    t.set(.bool_and, .{ .op = .bool_and, .name = "bool_and", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.bool_or, .{ .op = .bool_or, .name = "bool_or", .category = .scalar, .is_scalar = true, .foldable = true });
    t.set(.bool_not, .{ .op = .bool_not, .name = "bool_not", .category = .scalar, .is_scalar = true });

    // === 类型转换（scalar, is_scalar, 不折叠） ===
    t.set(.cast, .{ .op = .cast, .name = "cast", .category = .scalar, .is_scalar = true });
    t.set(.cast_safe, .{ .op = .cast_safe, .name = "cast_safe", .category = .scalar, .is_scalar = true });
    t.set(.cast_to, .{ .op = .cast_to, .name = "cast_to", .category = .scalar, .is_scalar = true });
    t.set(.cast_try_to, .{ .op = .cast_try_to, .name = "cast_try_to", .category = .scalar, .is_scalar = true });

    // === 数组（other） ===
    t.set(.array_make, .{ .op = .array_make, .name = "array_make", .category = .other });
    t.set(.array_get, .{ .op = .array_get, .name = "array_get", .category = .other });
    t.set(.array_set, .{ .op = .array_set, .name = "array_set", .category = .other });
    t.set(.array_len, .{ .op = .array_len, .name = "array_len", .category = .other });
    t.set(.array_concat, .{ .op = .array_concat, .name = "array_concat", .category = .other });
    t.set(.array_fill, .{ .op = .array_fill, .name = "array_fill", .category = .other });
    t.set(.array_slice, .{ .op = .array_slice, .name = "array_slice", .category = .other });

    // === 记录（other） ===
    t.set(.record_make, .{ .op = .record_make, .name = "record_make", .category = .other });
    t.set(.record_get, .{ .op = .record_get, .name = "record_get", .category = .other });
    t.set(.record_set, .{ .op = .record_set, .name = "record_set", .category = .other });
    t.set(.record_clone, .{ .op = .record_clone, .name = "record_clone", .category = .other });

    // === 字符串（other） ===
    t.set(.string_concat, .{ .op = .string_concat, .name = "string_concat", .category = .other });
    t.set(.string_len, .{ .op = .string_len, .name = "string_len", .category = .other });
    t.set(.string_index, .{ .op = .string_index, .name = "string_index", .category = .other });
    t.set(.string_contains, .{ .op = .string_contains, .name = "string_contains", .category = .other });
    t.set(.string_cmp, .{ .op = .string_cmp, .name = "string_cmp", .category = .other });
    t.set(.string_slice, .{ .op = .string_slice, .name = "string_slice", .category = .other });
    t.set(.string_bytes, .{ .op = .string_bytes, .name = "string_bytes", .category = .other });
    t.set(.array_to_str, .{ .op = .array_to_str, .name = "array_to_str", .category = .other });

    // === Newtype（other） ===
    t.set(.newtype_wrap, .{ .op = .newtype_wrap, .name = "newtype_wrap", .category = .other });
    t.set(.newtype_unwrap, .{ .op = .newtype_unwrap, .name = "newtype_unwrap", .category = .other });

    // === 向量（vector, is_vector；含子图者 has_nested） ===
    t.set(.vec_source, .{ .op = .vec_source, .name = "vec_source", .category = .vector, .is_vector = true });
    t.set(.vec_map, .{ .op = .vec_map, .name = "vec_map", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_map2, .{ .op = .vec_map2, .name = "vec_map2", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_fold, .{ .op = .vec_fold, .name = "vec_fold", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_scan, .{ .op = .vec_scan, .name = "vec_scan", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_filter, .{ .op = .vec_filter, .name = "vec_filter", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_select, .{ .op = .vec_select, .name = "vec_select", .category = .vector, .is_vector = true });
    t.set(.vec_take, .{ .op = .vec_take, .name = "vec_take", .category = .vector, .is_vector = true });
    t.set(.vec_take_while, .{ .op = .vec_take_while, .name = "vec_take_while", .category = .vector, .is_vector = true, .has_nested = true });
    t.set(.vec_zip, .{ .op = .vec_zip, .name = "vec_zip", .category = .vector, .is_vector = true });
    t.set(.vec_sink, .{ .op = .vec_sink, .name = "vec_sink", .category = .vector, .is_vector = true });

    // === 门控（other） ===
    t.set(.gate_check, .{ .op = .gate_check, .name = "gate_check", .category = .other });
    t.set(.gate_get_ok, .{ .op = .gate_get_ok, .name = "gate_get_ok", .category = .other });
    t.set(.gate_get_err, .{ .op = .gate_get_err, .name = "gate_get_err", .category = .other });
    t.set(.gate_propagate, .{ .op = .gate_propagate, .name = "gate_propagate", .category = .other });
    t.set(.gate_select, .{ .op = .gate_select, .name = "gate_select", .category = .other });
    t.set(.gate_make_ok, .{ .op = .gate_make_ok, .name = "gate_make_ok", .category = .other });
    t.set(.gate_make_err, .{ .op = .gate_make_err, .name = "gate_make_err", .category = .other });

    // === 路由（other；route_dispatch 持有分派子图） ===
    t.set(.route_get_tag, .{ .op = .route_get_tag, .name = "route_get_tag", .category = .other });
    t.set(.route_dispatch, .{ .op = .route_dispatch, .name = "route_dispatch", .category = .other, .has_nested = true });
    t.set(.route_merge, .{ .op = .route_merge, .name = "route_merge", .category = .other });

    // === 竞争（other） ===
    t.set(.race_source, .{ .op = .race_source, .name = "race_source", .category = .other });
    t.set(.race_select, .{ .op = .race_select, .name = "race_select", .category = .other });
    t.set(.race_yield, .{ .op = .race_yield, .name = "race_yield", .category = .other });

    // === 清理（other；cleanup_register 持有 defer 子图） ===
    t.set(.cleanup_register, .{ .op = .cleanup_register, .name = "cleanup_register", .category = .other, .has_nested = true });
    t.set(.cleanup_run, .{ .op = .cleanup_run, .name = "cleanup_run", .category = .other });

    // === Nullable（other） ===
    t.set(.nullable_make, .{ .op = .nullable_make, .name = "nullable_make", .category = .other });
    t.set(.nullable_is_null, .{ .op = .nullable_is_null, .name = "nullable_is_null", .category = .other });
    t.set(.nullable_unwrap, .{ .op = .nullable_unwrap, .name = "nullable_unwrap", .category = .other });
    t.set(.nullable_unwrap_or, .{ .op = .nullable_unwrap_or, .name = "nullable_unwrap_or", .category = .other });

    // === 内存与引用（other） ===
    t.set(.alloc, .{ .op = .alloc, .name = "alloc", .category = .other });
    t.set(.free, .{ .op = .free, .name = "free", .category = .other });
    t.set(.load, .{ .op = .load, .name = "load", .category = .other });
    t.set(.store, .{ .op = .store, .name = "store", .category = .other });
    t.set(.ref_get, .{ .op = .ref_get, .name = "ref_get", .category = .other });
    t.set(.ref_set, .{ .op = .ref_set, .name = "ref_set", .category = .other });
    t.set(.ref_of, .{ .op = .ref_of, .name = "ref_of", .category = .other });

    // === 控制流 ===
    t.set(.call, .{ .op = .call, .name = "call", .category = .other });
    t.set(.halt_return, .{ .op = .halt_return, .name = "halt_return", .category = .halt, .is_halt = true });
    t.set(.halt_throw, .{ .op = .halt_throw, .name = "halt_throw", .category = .halt, .is_halt = true });
    t.set(.halt_panic, .{ .op = .halt_panic, .name = "halt_panic", .category = .halt, .is_halt = true });
    t.set(.halt_break, .{ .op = .halt_break, .name = "halt_break", .category = .halt, .is_halt = true });
    t.set(.halt_continue, .{ .op = .halt_continue, .name = "halt_continue", .category = .halt, .is_halt = true });
    // scalar_loop：持有循环体子图，归入 nested 类别
    t.set(.scalar_loop, .{ .op = .scalar_loop, .name = "scalar_loop", .category = .nested, .has_nested = true });

    // === 内置函数（other） ===
    t.set(.builtin_ok, .{ .op = .builtin_ok, .name = "builtin_ok", .category = .other });
    t.set(.builtin_error, .{ .op = .builtin_error, .name = "builtin_error", .category = .other });
    t.set(.builtin_eq, .{ .op = .builtin_eq, .name = "builtin_eq", .category = .other });
    t.set(.builtin_str, .{ .op = .builtin_str, .name = "builtin_str", .category = .other });
    t.set(.builtin_ref_eq, .{ .op = .builtin_ref_eq, .name = "builtin_ref_eq", .category = .other });
    t.set(.builtin_type, .{ .op = .builtin_type, .name = "builtin_type", .category = .other });
    t.set(.builtin_panic, .{ .op = .builtin_panic, .name = "builtin_panic", .category = .other });
    t.set(.builtin_typeof, .{ .op = .builtin_typeof, .name = "builtin_typeof", .category = .other });
    t.set(.builtin_reflect, .{ .op = .builtin_reflect, .name = "builtin_reflect", .category = .other });
    t.set(.builtin_reflect_field, .{ .op = .builtin_reflect_field, .name = "builtin_reflect_field", .category = .other });
    t.set(.builtin_scalar_to_str, .{ .op = .builtin_scalar_to_str, .name = "builtin_scalar_to_str", .category = .other });
    t.set(.builtin_reflect_deref, .{ .op = .builtin_reflect_deref, .name = "builtin_reflect_deref", .category = .other });
    t.set(.builtin_reflect_field_name, .{ .op = .builtin_reflect_field_name, .name = "builtin_reflect_field_name", .category = .other });
    t.set(.builtin_reflect_meta, .{ .op = .builtin_reflect_meta, .name = "builtin_reflect_meta", .category = .other });

    // === Syscall（other） ===
    t.set(.syscall_call, .{ .op = .syscall_call, .name = "syscall_call", .category = .other });

    // === 星轨 / 通道（other） ===
    t.set(.orbit_async_create, .{ .op = .orbit_async_create, .name = "orbit_async_create", .category = .other });
    t.set(.orbit_async_join, .{ .op = .orbit_async_join, .name = "orbit_async_join", .category = .other });
    t.set(.orbit_async_status, .{ .op = .orbit_async_status, .name = "orbit_async_status", .category = .other });
    t.set(.orbit_chan_send, .{ .op = .orbit_chan_send, .name = "orbit_chan_send", .category = .other });
    t.set(.orbit_chan_recv, .{ .op = .orbit_chan_recv, .name = "orbit_chan_recv", .category = .other });
    t.set(.orbit_chan_try_recv, .{ .op = .orbit_chan_try_recv, .name = "orbit_chan_try_recv", .category = .other });
    t.set(.channel_close, .{ .op = .channel_close, .name = "channel_close", .category = .other });
    t.set(.channel_create, .{ .op = .channel_create, .name = "channel_create", .category = .other });
    t.set(.channel_sender, .{ .op = .channel_sender, .name = "channel_sender", .category = .other });
    t.set(.channel_receiver, .{ .op = .channel_receiver, .name = "channel_receiver", .category = .other });

    // === 原子操作（other） ===
    t.set(.atomic_make, .{ .op = .atomic_make, .name = "atomic_make", .category = .other });
    t.set(.atomic_fetch_add, .{ .op = .atomic_fetch_add, .name = "atomic_fetch_add", .category = .other });
    t.set(.atomic_swap, .{ .op = .atomic_swap, .name = "atomic_swap", .category = .other });
    t.set(.atomic_cas, .{ .op = .atomic_cas, .name = "atomic_cas", .category = .other });

    // === 反射方法已移除（message/type_name 走 trait 分派） ===

    // === 闭包（other；closure_make 持有捕获/函数体子图） ===
    t.set(.closure_make, .{ .op = .closure_make, .name = "closure_make", .category = .other, .has_nested = true });
    t.set(.call_indirect, .{ .op = .call_indirect, .name = "call_indirect", .category = .other });

    // === 部分应用（other） ===
    t.set(.partial_make, .{ .op = .partial_make, .name = "partial_make", .category = .other });

    // === 惰性求值（other） ===
    t.set(.lazy_make, .{ .op = .lazy_make, .name = "lazy_make", .category = .other });
    t.set(.lazy_force, .{ .op = .lazy_force, .name = "lazy_force", .category = .other });

    break :blk t;
};

// === 查询 API ===

pub fn entry(op: NodeOp) *const OpEntry {
    return OP_TABLE.getPtrConst(op);
}

pub fn name(op: NodeOp) []const u8 {
    return entry(op).name;
}

pub fn category(op: NodeOp) OpCategory {
    return entry(op).category;
}

pub fn isScalar(op: NodeOp) bool {
    return entry(op).is_scalar;
}

pub fn isVector(op: NodeOp) bool {
    return entry(op).is_vector;
}

pub fn isHalt(op: NodeOp) bool {
    return entry(op).is_halt;
}

pub fn hasNested(op: NodeOp) bool {
    return entry(op).has_nested;
}

pub fn foldable(op: NodeOp) bool {
    return entry(op).foldable;
}

pub fn batchBinOp(op: NodeOp) ?BatchBinOp {
    return entry(op).batch_bin_op;
}

pub fn batchUnaryOp(op: NodeOp) ?BatchUnaryOp {
    return entry(op).batch_unary_op;
}
