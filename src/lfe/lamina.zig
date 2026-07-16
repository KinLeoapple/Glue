//! LFE 核心类型定义：层（Lamina）、层操作枚举、通道类型、层流图。
//!
//! 层是 LFE 中最小的计算单元，描述数据如何从输入通道流向输出通道。
//! 层流图是 Glue 函数编译后的 DAG 表示，执行时展平为层序列。
//!
//! 平台无关：所有类型定义不包含任何架构相关信息。

const std = @import("std");
const value = @import("value");
const scalar = value.scalar;

// 复用 value 模块已有的子类型定义
pub const IntKind = scalar.IntKind;
pub const FloatKind = scalar.FloatKind;
pub const NativeIntType = scalar.NativeIntType;
pub const NativeFloatType = scalar.NativeFloatType;

/// SIMD 基准位宽：128-bit（所有平台原生支持的最小 SIMD 宽度）
/// Zig 的 @Vector 是平台无关抽象，编译器自动映射到目标指令（SSE/NEON/LSX/RVV）
pub const SIMD_BITS: usize = 128;

/// 按类型计算最优 SIMD 通道数：SIMD_BITS / bitSizeOf(T)
/// 例：i32 → 4 通道，i64 → 2 通道，i8 → 16 通道
/// 大于 128 位的类型（i128/u128/f128）返回 1，退化为标量
pub inline fn simdLaneCount(comptime T: type) usize {
    const bits = @bitSizeOf(T);
    if (bits >= SIMD_BITS) return 1;
    return SIMD_BITS / bits;
}

/// 标量通道类型（按实际宽度分类）
pub const ScalarChanType = enum(u5) {
    // 整数（10 种）
    i8_chan, i16_chan, i32_chan, i64_chan, i128_chan,
    u8_chan, u16_chan, u32_chan, u64_chan, u128_chan,
    // 浮点（4 种，无 f8）
    f16_chan, f32_chan, f64_chan, f128_chan,
    // 其他标量
    bool_chan, char_chan, null_chan, unit_chan,
    // 堆引用与谓词
    ref_chan, mask_chan,
    // Nullable<T>：值域 [inner_value_bytes][null_flag: 1 byte]，inner_type 记录内部类型
    nullable_chan,
};

/// 堆引用子类型（复用 obj_header 的 RefKind）
pub const RefKind = value.obj_header.RefKind;

/// 通道类型 → 元素字节宽度
/// nullable_chan 返回 0：实际宽度依赖 inner_type，需通过 nullableElemWidth 计算
pub fn chanElemWidth(chan_type: ScalarChanType) u8 {
    return switch (chan_type) {
        .null_chan, .unit_chan, .nullable_chan => 0,
        .i8_chan, .u8_chan, .bool_chan, .mask_chan => 1,
        .i16_chan, .u16_chan, .f16_chan => 2,
        .i32_chan, .u32_chan, .f32_chan, .char_chan => 4,
        .i64_chan, .u64_chan, .f64_chan, .ref_chan => 8,
        .i128_chan, .u128_chan, .f128_chan => 16,
    };
}

/// Nullable<T> 通道元素字节宽度 = inner_width + 1（1 byte null 标志）
pub inline fn nullableElemWidth(inner_type: ScalarChanType) u8 {
    return chanElemWidth(inner_type) + 1;
}

/// 将 sema.Type 映射为 ScalarChanType
/// 需要外部传入 Type 类型，避免直接依赖 sema 模块
pub fn chanTypeFromIntKind(kind: IntKind) ScalarChanType {
    return switch (kind) {
        .i8 => .i8_chan, .i16 => .i16_chan, .i32 => .i32_chan, .i64 => .i64_chan, .i128 => .i128_chan,
        .u8 => .u8_chan, .u16 => .u16_chan, .u32 => .u32_chan, .u64 => .u64_chan, .u128 => .u128_chan,
    };
}

pub fn chanTypeFromFloatKind(kind: FloatKind) ScalarChanType {
    return switch (kind) {
        .f16 => .f16_chan, .f32 => .f32_chan, .f64 => .f64_chan, .f128 => .f128_chan,
    };
}

/// 通道类型 → IntKind（反向映射）
pub fn intKindFromChanType(ct: ScalarChanType) IntKind {
    return switch (ct) {
        .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
        .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
        else => .i64,
    };
}

/// 通道类型 → FloatKind（反向映射）
pub fn floatKindFromChanType(ct: ScalarChanType) FloatKind {
    return switch (ct) {
        .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
        else => .f64,
    };
}

/// ScalarChanType → value.ScalarTag 映射（用于 type_cast lamina）
/// 返回 null 表示不可转换的通道类型（null/unit/mask/ref）
pub fn chanTypeToScalarTag(ct: ScalarChanType) ?value.scalar.ScalarTag {
    return switch (ct) {
        .bool_chan => .boolean,
        .char_chan => .char,
        .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
        .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
        .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
        .null_chan, .unit_chan, .mask_chan, .ref_chan, .nullable_chan => null,
    };
}

/// 层操作枚举：覆盖 Glue 全部语义
pub const LaminaOp = enum(u8) {
    // ═══ 常量与载入 ═══
    constant,          // 编译期常量广播到通道
    broadcast_input,   // 标量输入广播
    move,              // 通道复制（identity）

    // ═══ 整数算术（int_kind 标注子类型）═══
    int_add, int_sub, int_mul, int_div, int_mod,
    int_neg, int_abs,
    int_scale,         // a * k（k = const_val）
    int_scale_add,     // a * k + c
    int_fma,           // a * b + c
    int_and, int_or, int_xor, int_shl, int_shr, int_not,

    // ═══ 浮点算术（float_kind 标注子类型）═══
    float_add, float_sub, float_mul, float_div,
    float_neg, float_abs,
    float_sqrt, float_floor, float_ceil, float_round,
    float_sin, float_cos, float_tan, float_log, float_exp,
    float_pow,
    float_scale, float_scale_add, float_fma,

    // ═══ 布尔运算 ═══
    bool_and, bool_or, bool_not, bool_xor,

    // ═══ 字符运算 ═══
    char_to_int, int_to_char,
    char_is_alpha, char_is_digit, char_is_whitespace,

    // ═══ 比较（输出 mask_chan）═══
    int_lt, int_gt, int_eq, int_ne, int_le, int_ge,
    float_lt, float_gt, float_eq, float_ne, float_le, float_ge,
    bool_eq, bool_ne,
    char_lt, char_gt, char_eq, char_ne, char_le, char_ge,

    // ═══ 谓词与掩码 ═══
    select,            // mask ? true_val : false_val
    mask_and, mask_or, mask_not, mask_zero,

    // ═══ 类型转换 ═══
    int_widen, int_narrow,
    int_to_float, float_to_int,
    float_widen, float_narrow,
    int_reinterpret,
    null_to_nullable,
    /// 统一标量类型转换：src_chan → output_chan
    /// const_val 存 dst ScalarTag（@intFromEnum），src_tag 从输入通道元数据推断
    type_cast,
    /// 安全标量转换：src_chan → output_chan（标量）
    /// const_val 存 dst ScalarTag，转换越界时抛出错误（halt_reason = throw_halt），成功输出标量值
    type_cast_safe,

    // ═══ 字符串操作 ═══
    str_const, str_concat, str_len, str_char_at, str_slice,
    str_to_chars, chars_to_str,
    str_eq, str_starts_with, str_contains,

    // ═══ 数组操作 ═══
    array_make, array_len, array_get, array_set, array_push,
    array_map, array_filter, array_reduce,
    array_concat, array_slice,
    array_to_stream, stream_to_array,

    // ═══ 记录操作 ═══
    record_make, record_get, record_set, record_has, record_extend,

    // ═══ ADT 操作 ═══
    adt_make, adt_get_ctor, adt_get_field, adt_test_ctor, adt_match,

    // ═══ Newtype 操作 ═══
    newtype_wrap, newtype_unwrap,

    // ═══ Cell 操作 ═══
    cell_make, cell_get, cell_set, cell_swap,

    // ═══ Range 操作 ═══
    range_make, range_start, range_end, range_len, range_to_stream,

    // ═══ 闭包操作 ═══
    closure_make, closure_call, closure_capture,

    // ═══ 部分应用 ═══
    partial_make, partial_call,

    // ═══ 内置函数 ═══
    builtin_call,

    // ═══ 错误与异常 ═══
    error_make, throw_make,
    throw_is_ok, throw_is_err, throw_get_ok, throw_get_err, throw_propagate,

    // ═══ 迭代器 ═══
    iter_has_next, iter_next, iter_to_stream,

    // ═══ 并发 ═══
    atomic_make, atomic_load, atomic_store, atomic_cas,
    atomic_swap, atomic_fetch_add, atomic_fetch_sub,
    async_create, async_join, async_yield, async_status,
    channel_make, channel_split, channel_send, channel_recv,
    channel_try_recv, channel_close,
    channel_get_sender, channel_get_receiver,
    sender_send, sender_close,
    receiver_recv, receiver_try_recv, receiver_close,

    // ═══ Trait ═══
    trait_make, trait_call_method, trait_downcast,

    // ═══ 惰性值 ═══
    lazy_make, lazy_force, lazy_is_forced,

    // ═══ Nullable ═══
    nullable_make, nullable_is_null, nullable_unwrap, nullable_unwrap_or,

    // ═══ 聚合 ═══
    reduce_sum, reduce_min, reduce_max, reduce_prod, reduce_count,

    // ═══ 流控制 ═══
    compress, expand, concat, slice, duplicate, length,

    // ═══ 控制流出口 ═══
    halt_return, halt_throw, halt_break, halt_continue,

    // ═══ 动态分派 ═══
    switch_lamina,

    // ═══ 轨道枢纽（星轨模型）═══
    orbit_hub,          // sync_hub：同步轨道激活，主 DAG 等待输出
    orbit_hub_async,    // async_hub：异步轨道激活，主 DAG 不等待
    orbit_join,         // 等待异步轨道完成并读取结果

    // ═══ defer 栈 ═══
    defer_register,     // 注册 defer 体到 LIFO 栈
    defer_execute,      // halt 时 LIFO 执行所有已注册的 defer

    // ═══ 显式数据栈（递归用）═══
    stack_push,         // 压栈（保存调用帧）
    stack_pop,          // 出栈（恢复调用帧）
    stack_peek,         // 查看栈顶（不出栈）
    stack_depth,        // 栈深度

    // ═══ 调试输出 ═══
    debug_print,        // stdout 输出
    debug_print_err,    // stderr 输出
};

// ════════════════════════════════════════════════════════════════════
// 星轨模型数据结构
// ════════════════════════════════════════════════════════════════════

/// 轨道枢纽类型
pub const OrbitHubKind = enum(u4) {
    match_hub,       // match 表达式
    if_hub,          // if-else
    loop_hub,        // while/for/loop
    trait_hub,       // 动态 trait 分派
    closure_hub,     // 动态闭包调用
    error_hub,       // ? 传播 / try-catch
    nullable_hub,    // ?. / ?? / !
    select_hub,      // select 多路复用
    async_hub,       // async fun / async lambda
};

/// 条件比较方式
pub const CondKind = enum(u3) {
    always,   // 无条件匹配（wildcard / default）
    eq,       // ==
    ne,       // !=
    gt,       // >
    lt,       // <
};

/// 轨道表条目：条件 → 轨道索引的映射
pub const OrbitEntry = struct {
    /// 条件值通道（null = always_match）
    cond_channel: ?u16 = null,
    /// 比较方式
    cond_kind: CondKind = .always,
    /// 期望值（ADT tag / bool / int 值）
    expected_val: i64 = 0,
    /// 对应轨道索引
    orbit_index: u16,
};

/// 参数绑定：太阳层通道 → 轨道入口通道
pub const ParamBind = struct {
    src: u16,   // 太阳层通道索引
    dst: u16,   // 轨道入口通道索引
};

/// 轨道枢纽：连接太阳层与星轨层
pub const OrbitHub = struct {
    /// 枢纽类型
    kind: OrbitHubKind,
    /// 条件值所在通道（async_hub 时无）
    cond_channel: ?u16 = null,
    /// 轨道表（编译期确定）
    orbit_table: []const OrbitEntry,
    /// 输出回写通道（async_hub 时输出句柄）
    output_channel: u16,
    /// 参数绑定：太阳层通道 → 轨道入口通道
    param_mapping: []const ParamBind = &.{},
    /// 是否环形（循环）
    is_cyclic: bool = false,
    /// 继续条件通道（环形轨道用）
    continue_channel: ?u16 = null,
};

/// 轨道运行时状态
pub const OrbitState = enum(u2) {
    inactive,   // 未激活——零开销
    running,    // 正在执行
    done,       // 执行完毕
};

/// 轨道：独立的 lamina 序列
pub const Orbit = struct {
    /// 轨道内 lamina 序列（连续内存）
    laminas: []const Lamina,
    /// 入口通道（从太阳层接收数据）
    input_channels: []const u16 = &.{},
    /// 出口通道（结果回写太阳层）
    output_channel: u16 = 0,
    /// 是否环形轨道（循环）
    is_cyclic: bool = false,
    /// 环形轨道的继续条件通道
    continue_channel: ?u16 = null,
    /// 轨道内嵌套的 OrbitHub 索引列表
    nested_hubs: []const u16 = &.{},
    /// 运行时状态
    state: OrbitState = .inactive,
    /// 轨道私有通道数量
    private_channel_count: u16 = 0,
    /// E2: 闭包捕获 bridge_in 通道列表（closure_hub 运行时绑定用）
    capture_channels: []const u16 = &.{},
};

/// 通道归属层级
pub const ChannelScope = enum(u2) {
    solar,       // 太阳层通道（主 DAG）
    orbit,       // 轨道内部通道（特定轨道私有）
    bridge_in,   // 桥接入口（太阳层 → 轨道）
    bridge_out,  // 桥接出口（轨道 → 太阳层）
};

/// defer 条目
pub const DeferEntry = struct {
    /// defer 体的轨道索引（defer 体编译为轨道）
    orbit_index: u16,
    /// 注册顺序（LIFO 执行）
    order: u32,
};

/// E2: Trait 方法分派表条目（运行时 trait_hub 查找用）
pub const TraitMethodEntry = struct {
    /// trait 值的 type_tag（构造时分配的唯一标识）
    type_tag: u64,
    /// 方法名索引（name_table 中的索引）
    method_name_id: u16,
    /// 方法体编译的轨道索引
    orbit_index: u16,
    /// 方法参数 bridge_in 通道（轨道内）
    param_channels: []const u16 = &.{},
    /// self 数据 bridge_in 通道（轨道内，trait 数据入口）
    self_channel: u16 = 0,
    /// 输出 bridge_out 通道（轨道内）
    output_channel: u16 = 0,
};

/// 层：平台无关的计算单元
pub const Lamina = struct {
    op: LaminaOp,
    /// 输入通道索引（最多 3 个）
    inputs: [3]u16 = .{ 0, 0, 0 },
    /// 输出通道索引
    output: u16 = 0,
    /// 谓词掩码通道（可选，用于条件执行）
    predicate: ?u16 = null,
    /// 编译期常量 1（多用途：常量值、scale 乘数、字段索引等）
    const_val: ?i64 = null,
    /// 编译期常量 2（用于 scale_add 的加数）
    const_val2: ?i64 = null,
    /// 整数子类型
    int_kind: ?IntKind = null,
    /// 浮点子类型
    float_kind: ?FloatKind = null,
    /// 堆引用子类型
    ref_kind: ?RefKind = null,
    /// 外部函数索引
    extern_idx: ?u16 = null,
    /// 字段名/构造器名索引
    name_idx: ?u16 = null,
    /// 输入通道数量（1/2/3）
    input_count: u2 = 2,
    /// OrbitHub 索引（op == .orbit_hub / .orbit_hub_async 时有效）
    hub_index: ?u16 = null,
};

/// 通道元数据：编译期确定的类型信息
pub const ChannelMeta = struct {
    chan_type: ScalarChanType,
    elem_width: u8,
    /// 标记该通道是否为 Cell（可变引用）通道
    /// var_decl 创建的通道会设为 true，identifier 查找时据此发射 cell_get
    is_cell: bool = false,
    /// Cell 内部值类型（var_decl 时记录，cell_get 时用于输出通道类型）
    inner_type: ScalarChanType = .unit_chan,
    /// ref_chan 的子类型（用于 builtin 方法按类型分派）
    /// 仅当 chan_type == .ref_chan 时有效，null 表示未指定
    ref_kind: ?RefKind = null,
};

/// 层流图：一个 Glue 函数编译后的完整表示（太阳层 + 星轨层）
pub const LaminarGraph = struct {
    /// 太阳层层序列（按拓扑序排列）
    laminas: []const Lamina,
    /// 通道元数据（逻辑通道索引 → 类型信息）
    channel_metas: []const ChannelMeta,
    /// 逻辑通道总数
    channel_count: u16,
    /// 输入通道索引列表（函数参数）
    input_channels: []const u16,
    /// 输出通道索引（返回值）
    output_channel: u16,
    /// 字符串常量表（str_const 的 name_idx 索引此表）
    string_table: []const []const u8,
    /// 字段名/构造器名表（record_get/adt_get_field 的 name_idx 索引此表）
    name_table: []const []const u8,
    /// async 函数/lambda 编译的子图列表（async_create 的 extern_idx 索引此表）
    subgraphs: []const LaminarGraph = &.{},

    // ── 星轨层 ──
    /// 所有轨道（Orbit）
    orbits: []const Orbit = &.{},
    /// 所有 OrbitHub 元数据（orbit_hub lamina 的 hub_index 索引此表）
    orbit_hubs: []const OrbitHub = &.{},
    /// defer 条目表（halt 时 LIFO 执行）
    defer_entries: []const DeferEntry = &.{},
    /// 通道归属层级（与 channel_metas 一一对应）
    channel_scopes: []const ChannelScope = &.{},
    /// E2: Trait 方法分派表（trait_hub 运行时查找用）
    trait_method_table: []const TraitMethodEntry = &.{},

    /// 拥有的 arena 指针（所有切片由 arena 分配，deinit 时统一释放）
    arena: ?*std.heap.ArenaAllocator = null,

    /// 释放层流图占用的内存
    /// arena 持有所有切片内存，销毁 arena 即释放全部
    pub fn deinit(self: *LaminarGraph, allocator: std.mem.Allocator) void {
        // 递归释放子图（const cast：subgraph 不可变但需调用 deinit）
        for (self.subgraphs) |*sg_const| {
            const sg: *LaminarGraph = @constCast(sg_const);
            sg.deinit(allocator);
        }
        if (self.arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.arena = null;
        }
    }
};

/// 物理通道：执行时的通道访问接口
/// 数据存储为 []u8，通过 @ptrCast + @alignCast 零成本转换为原生类型
pub const PhysicalChannel = struct {
    data: []align(16) u8,
    elem_width: u8,
    element_count: usize,

    /// 泛型标量读
    pub inline fn getScalar(self: *const PhysicalChannel, comptime T: type, idx: usize) T {
        const w = @sizeOf(T);
        const ptr: *const T = @ptrCast(@alignCast(self.data.ptr + idx * w));
        return ptr.*;
    }

    /// 泛型标量写
    pub inline fn setScalar(self: *PhysicalChannel, comptime T: type, idx: usize, val: T) void {
        const w = @sizeOf(T);
        const ptr: *T = @ptrCast(@alignCast(self.data.ptr + idx * w));
        ptr.* = val;
    }

    /// 类型化只读指针（用于 SIMD 切片读写）
    pub inline fn asTypedPtr(self: *const PhysicalChannel, comptime T: type) [*]align(16) const T {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    /// 类型化可写指针（用于 SIMD 切片读写）
    pub inline fn asTypedPtrMut(self: *PhysicalChannel, comptime T: type) [*]align(16) T {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    /// 读取原始字节（用于 Value ↔ 通道转换）
    pub inline fn getBytes(self: *const PhysicalChannel, idx: usize, len: usize) []const u8 {
        return self.data[idx * self.elem_width ..][0..len];
    }

    /// 写入原始字节（用于 Value ↔ 通道转换）
    pub inline fn setBytes(self: *PhysicalChannel, idx: usize, src: []const u8) void {
        @memcpy(self.data[idx * self.elem_width ..][0..src.len], src);
    }
};

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "chanElemWidth 按实际宽度" {
    try testing.expectEqual(@as(u8, 0), chanElemWidth(.null_chan));
    try testing.expectEqual(@as(u8, 0), chanElemWidth(.unit_chan));
    try testing.expectEqual(@as(u8, 1), chanElemWidth(.i8_chan));
    try testing.expectEqual(@as(u8, 1), chanElemWidth(.bool_chan));
    try testing.expectEqual(@as(u8, 2), chanElemWidth(.i16_chan));
    try testing.expectEqual(@as(u8, 4), chanElemWidth(.i32_chan));
    try testing.expectEqual(@as(u8, 4), chanElemWidth(.char_chan));
    try testing.expectEqual(@as(u8, 8), chanElemWidth(.i64_chan));
    try testing.expectEqual(@as(u8, 8), chanElemWidth(.ref_chan));
    try testing.expectEqual(@as(u8, 16), chanElemWidth(.i128_chan));
}

test "chanTypeFromIntKind 映射正确" {
    try testing.expectEqual(ScalarChanType.i8_chan, chanTypeFromIntKind(.i8));
    try testing.expectEqual(ScalarChanType.u64_chan, chanTypeFromIntKind(.u64));
    try testing.expectEqual(ScalarChanType.i128_chan, chanTypeFromIntKind(.i128));
}

test "chanTypeFromFloatKind 映射正确" {
    try testing.expectEqual(ScalarChanType.f16_chan, chanTypeFromFloatKind(.f16));
    try testing.expectEqual(ScalarChanType.f64_chan, chanTypeFromFloatKind(.f64));
}

test "PhysicalChannel 标量读写" {
    var buf: [64]u8 align(16) = [_]u8{0} ** 64;
    var ch = PhysicalChannel{
        .data = &buf,
        .elem_width = 8,
        .element_count = 8,
    };
    ch.setScalar(i64, 0, 42);
    ch.setScalar(i64, 1, -7);
    try testing.expectEqual(@as(i64, 42), ch.getScalar(i64, 0));
    try testing.expectEqual(@as(i64, -7), ch.getScalar(i64, 1));
}

test "PhysicalChannel SIMD 切片读写" {
    var buf: [32]u8 align(16) = [_]u8{0} ** 32;
    var ch = PhysicalChannel{
        .data = &buf,
        .elem_width = 4,
        .element_count = 8,
    };

    const ptr = ch.asTypedPtrMut(i32);
    ptr[0..][0..4].* = .{ 10, 20, 30, 40 };
    const got: [4]i32 = ptr[0..][0..4].*;
    try testing.expectEqual(@as(i32, 10), got[0]);
    try testing.expectEqual(@as(i32, 20), got[1]);
    try testing.expectEqual(@as(i32, 30), got[2]);
    try testing.expectEqual(@as(i32, 40), got[3]);

    ptr[4..][0..4].* = .{ 50, 60, 70, 80 };
    try testing.expectEqual(@as(i32, 50), ch.getScalar(i32, 4));
    try testing.expectEqual(@as(i32, 80), ch.getScalar(i32, 7));
}

test "LaminaOp 枚举完整性" {
    // 确保关键操作存在
    _ = LaminaOp.constant;
    _ = LaminaOp.int_add;
    _ = LaminaOp.float_mul;
    _ = LaminaOp.select;
    _ = LaminaOp.halt_return;
    // 星轨模型 op
    _ = LaminaOp.orbit_hub;
    _ = LaminaOp.orbit_hub_async;
    _ = LaminaOp.orbit_join;
    _ = LaminaOp.defer_register;
    _ = LaminaOp.defer_execute;
    _ = LaminaOp.stack_push;
    _ = LaminaOp.stack_pop;
}

test "星轨数据结构默认值" {
    const entry = OrbitEntry{ .orbit_index = 0 };
    try testing.expectEqual(CondKind.always, entry.cond_kind);
    try testing.expect(entry.cond_channel == null);
    try testing.expectEqual(@as(i64, 0), entry.expected_val);

    const hub = OrbitHub{
        .kind = .if_hub,
        .orbit_table = &.{},
        .output_channel = 0,
    };
    try testing.expect(!hub.is_cyclic);
    try testing.expect(hub.continue_channel == null);
    try testing.expect(hub.cond_channel == null);

    const orbit = Orbit{ .laminas = &.{} };
    try testing.expectEqual(OrbitState.inactive, orbit.state);
    try testing.expect(!orbit.is_cyclic);
    try testing.expectEqual(@as(u16, 0), orbit.private_channel_count);
}

test "Lamina hub_index 字段" {
    var lam = Lamina{ .op = .constant, .input_count = 0 };
    try testing.expect(lam.hub_index == null);
    lam.hub_index = 5;
    try testing.expectEqual(@as(?u16, 5), lam.hub_index);
}

test "LaminarGraph 星轨字段默认值" {
    const graph = LaminarGraph{
        .laminas = &.{},
        .channel_metas = &.{},
        .channel_count = 0,
        .input_channels = &.{},
        .output_channel = 0,
        .string_table = &.{},
        .name_table = &.{},
    };
    try testing.expectEqual(@as(usize, 0), graph.orbits.len);
    try testing.expectEqual(@as(usize, 0), graph.orbit_hubs.len);
    try testing.expectEqual(@as(usize, 0), graph.defer_entries.len);
    try testing.expectEqual(@as(usize, 0), graph.channel_scopes.len);
}
