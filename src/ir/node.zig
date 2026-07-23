//! Glue IR 节点定义
//!
//! Node 是 Glue IR 的最小计算单元，固定 16 字节，连续存储，CPU 缓存友好。
//! 所有节点共享同一通道空间，全局通道索引，无跨图映射。
//!
//! 设计参考：docs/glue-ir-design.md 第 3.2-3.3 节

const std = @import("std");

/// 节点操作类型枚举
///
/// 覆盖 Glue 全部语义：标量计算、向量计算、门控、路由、竞争、清理、控制流、星轨。
/// Phase 1 先实现标量 + 基础控制流部分，其余 op 在后续 Phase 接入执行引擎。
pub const NodeOp = enum(u8) {
    // === 标量计算 ===
    const_i, const_f, const_bool, const_char, const_str, const_null, const_unit,
    int_add, int_sub, int_mul, int_div, int_mod,
    int_and, int_or, int_xor, int_shl, int_shr, int_not,
    int_neg, int_abs,
    float_add, float_sub, float_mul, float_div, float_mod,
    float_neg, float_abs,
    cmp_eq, cmp_ne, cmp_lt, cmp_le, cmp_gt, cmp_ge,
    bool_and, bool_or, bool_not,
    cast, cast_safe,
    /// Phase 3 cast builder：cast(x).to(T) — wrap on overflow，产生 Inf 时 panic，str→数值非法 panic
    cast_to,
    /// Phase 3 cast builder：cast(x).try_to(T) — 失败时返回 Throw<T, CastError>
    cast_try_to,

    // === 数据结构 ===
    array_make, array_get, array_set, array_len, array_push, array_concat,
    array_first, array_last, array_contains, array_get_safe, array_drop_last, array_pop,
    /// 数组填充：array_fill(output, count, value) — 创建 count 个 value 副本的数组
    array_fill,
    /// 数组切片：array_slice(output, arr, start, end) — _pad=0 左闭右开，_pad=1 左闭右闭
    array_slice,
    record_make, record_get, record_set, record_clone,
    string_concat, string_len, string_index, string_contains,
    /// 字符串字典序比较：string_cmp(output, left, right)
    /// _pad 编码比较种类：0=lt, 1=le, 2=gt, 3=ge，output 为 bool_chan
    string_cmp,
    /// 字符串切片：string_slice(output, s, start, end) — _pad=0 左闭右开，_pad=1 左闭右闭
    /// start/end 为字符索引（Unicode 标量值）
    string_slice,
    /// 字符串转 u8[]：string_bytes(output, s) — UTF-8 编码
    string_bytes,
    /// u8[] 转字符串：array_to_str(output, arr) — UTF-8 解码
    array_to_str,
    newtype_wrap, newtype_unwrap,

    // === 向量计算（处理循环/递归，Phase 2） ===
    vec_source, vec_map, vec_map2, vec_fold, vec_scan,
    vec_filter, vec_select, vec_take, vec_take_while,
    vec_zip, vec_sink,

    // === 门控（? 短路 / 错误传播，Phase 3） ===
    gate_check, gate_get_ok, gate_get_err, gate_propagate,
    gate_select, gate_make_ok, gate_make_err,

    // === 路由（Trait 动态分派，Phase 3） ===
    route_get_tag, route_dispatch, route_merge,

    // === 竞争（select 多路复用，Phase 3） ===
    race_source, race_select, race_yield,

    // === 清理（defer，Phase 3） ===
    cleanup_register, cleanup_run,

    // === Nullable ===
    nullable_make, nullable_is_null, nullable_unwrap, nullable_unwrap_or,

    // === 内存管理 ===
    alloc, free, load, store,
    /// 借用引用：ref_get 读取 *ref 的值到 output 通道
    /// inputs[0] = 引用通道（ref_chan，持有 *ObjHeader）
    /// output = 值通道（按引用指向的类型分配）
    ref_get,
    /// 借用引用：ref_set 将 value 写入 *ref 指向的位置
    /// inputs[0] = 引用通道，inputs[1] = 值通道
    /// output = unit
    ref_set,
    /// 取引用：ref_of 将 expr 的地址包装为引用通道
    /// inputs[0] = expr 通道（标量装箱或复合直接取址）
    /// output = ref_chan
    ref_of,

    // === 控制流（最小化） ===
    call, halt_return, halt_throw, halt_panic,
    halt_break, halt_continue,
    scalar_loop,

    // === 内置函数 ===
    builtin_print, builtin_println,
    builtin_eprint, builtin_eprintln,
    builtin_scan, builtin_scanln,
    builtin_ok, builtin_error, builtin_eq, builtin_str,
    builtin_ref_eq,
    builtin_type, builtin_panic,
    builtin_typeof,

    // === Syscall 调用（IO/Time 等宿主 syscall 包装）===
    /// meta_index 索引到 syscall_metas 表（1-indexed）
    /// inputs[] 为参数通道，output 为结果通道
    syscall_call,

    // === 星轨（async/spawn，Phase 5） ===
    orbit_async_create, orbit_async_join, orbit_async_status,
    orbit_chan_send, orbit_chan_recv, orbit_chan_try_recv, channel_close,
    channel_create, channel_sender, channel_receiver,

    // === 原子操作 ===
    /// 构造 AtomicValue：inputs[0] = 初始值，output = ref_chan（AtomicValue 指针）
    atomic_make,
    /// 原子 fetch_add：inputs[0] = Atomic ref_chan，inputs[1] = 增量值
    /// output = 旧值。_pad=0 为 add，_pad=1 为 sub
    atomic_fetch_add,
    atomic_swap, atomic_cas,

    // === 反射方法（.message() / .type_name()） ===
    error_message, obj_type_name,

    // === 闭包（lambda） ===
    closure_make, call_indirect,

    // === 部分应用 ===
    /// 构造 PartialApplication：meta_index 指向 PartialMeta，output = ref_chan
    partial_make,

    // === 惰性求值（Lazy<T>） ===
    /// 构造 LazyValue：inputs[0] = thunk closure (ref_chan)，output = ref_chan
    lazy_make,
    /// 强制求值：inputs[0] = LazyValue (ref_chan)，output = 值通道
    lazy_force,

    /// 返回该 op 是否为 halt 节点（终止执行）
    pub fn isHalt(self: NodeOp) bool {
        return switch (self) {
            .halt_return, .halt_throw, .halt_panic,
            .halt_break, .halt_continue => true,
            else => false,
        };
    }

    /// 返回该 op 是否为向量 op
    pub fn isVector(self: NodeOp) bool {
        return switch (self) {
            .vec_source, .vec_map, .vec_map2, .vec_fold, .vec_scan,
            .vec_filter, .vec_select, .vec_take, .vec_take_while,
            .vec_zip, .vec_sink => true,
            else => false,
        };
    }

    /// 返回该 op 是否为标量计算 op
    pub fn isScalar(self: NodeOp) bool {
        return switch (self) {
            .const_i, .const_f, .const_bool, .const_char, .const_str, .const_null, .const_unit,
            .int_add, .int_sub, .int_mul, .int_div, .int_mod,
            .int_and, .int_or, .int_xor, .int_shl, .int_shr, .int_not,
            .int_neg, .int_abs,
            .float_add, .float_sub, .float_mul, .float_div, .float_mod,
            .float_neg, .float_abs,
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge,
            .bool_and, .bool_or, .bool_not,
            .cast, .cast_safe, .cast_to, .cast_try_to => true,
            else => false,
        };
    }
};

/// 统一节点结构：固定 16 字节
///
/// 字段布局（按对齐优化）：
///   op: 1B + input_count: 1B + output: 2B + meta_index: 2B + inputs: 8B
///   + scalar_tag: 1B + _pad: 1B = 16B
///
/// scalar_tag: 预计算的 ScalarTag(u8)，0xFF 表示无标量类型（非数值节点）。
/// 由引擎 layout 后一次性预计算，避免热路径中 chanToScalarTag 的 switch 分派。
pub const Node = struct {
    op: NodeOp, // 操作类型
    input_count: u8, // 实际输入数（0-4）
    output: u16, // 输出通道索引（全局）
    meta_index: u16, // 元数据表索引（指向对应 meta 表，0 表示无元数据）
    inputs: [4]u16 = .{ 0, 0, 0, 0 }, // 输入通道索引（全局）
    /// 预计算的 ScalarTag（@intFromEnum(scalar.ScalarTag)），0xFF = 无标量类型
    /// 热路径直接读取，避免 chanToScalarTag 运行时 switch
    scalar_tag: u8 = 0xFF,
    _pad: u8 = 0, // 显式填充至 16 字节（缓存行友好）

    /// 构造一个节点
    pub fn make(
        op: NodeOp,
        output: u16,
        meta_index: u16,
        inputs: []const u16,
    ) Node {
        var node = Node{
            .op = op,
            .input_count = @intCast(inputs.len),
            .output = output,
            .meta_index = meta_index,
        };
        var i: usize = 0;
        while (i < inputs.len and i < 4) : (i += 1) {
            node.inputs[i] = inputs[i];
        }
        return node;
    }

    /// 无输入节点（常量等）
    pub fn makeSink(op: NodeOp, output: u16, meta_index: u16) Node {
        return Node{
            .op = op,
            .input_count = 0,
            .output = output,
            .meta_index = meta_index,
        };
    }

    /// 一元节点
    pub fn makeUnary(op: NodeOp, output: u16, meta_index: u16, in0: u16) Node {
        return Node{
            .op = op,
            .input_count = 1,
            .output = output,
            .meta_index = meta_index,
            .inputs = .{ in0, 0, 0, 0 },
        };
    }

    /// 二元节点
    pub fn makeBinary(op: NodeOp, output: u16, meta_index: u16, in0: u16, in1: u16) Node {
        return Node{
            .op = op,
            .input_count = 2,
            .output = output,
            .meta_index = meta_index,
            .inputs = .{ in0, in1, 0, 0 },
        };
    }

    /// 三元节点（如 vec_select）
    pub fn makeTernary(op: NodeOp, output: u16, meta_index: u16, in0: u16, in1: u16, in2: u16) Node {
        return Node{
            .op = op,
            .input_count = 3,
            .output = output,
            .meta_index = meta_index,
            .inputs = .{ in0, in1, in2, 0 },
        };
    }
};

comptime {
    // 编译期断言：Node 必须恰好 16 字节
    if (@sizeOf(Node) != 16) {
        @compileError("Node must be exactly 16 bytes, got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Node)}));
    }
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "Node 尺寸为 16 字节" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Node));
}

test "Node.make 构造二元节点" {
    const n = Node.makeBinary(.int_add, 10, 1, 5, 7);
    try testing.expectEqual(NodeOp.int_add, n.op);
    try testing.expectEqual(@as(u8, 2), n.input_count);
    try testing.expectEqual(@as(u16, 10), n.output);
    try testing.expectEqual(@as(u16, 1), n.meta_index);
    try testing.expectEqual(@as(u16, 5), n.inputs[0]);
    try testing.expectEqual(@as(u16, 7), n.inputs[1]);
}

test "NodeOp.isHalt/isVector/isScalar 分类" {
    try testing.expect(NodeOp.halt_return.isHalt());
    try testing.expect(!NodeOp.int_add.isHalt());
    try testing.expect(NodeOp.vec_map.isVector());
    try testing.expect(!NodeOp.int_add.isVector());
    try testing.expect(NodeOp.int_add.isScalar());
    try testing.expect(!NodeOp.call.isScalar());
}
