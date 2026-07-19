//! Glue IR 元数据表
//!
//! 按 op 类型分表存储，避免 union 膨胀，同类 meta 连续访问缓存友好。
//! 设计参考：docs/glue-ir-design.md 第 3.5 节
//!
//! Phase 1 实现：ScalarMeta / CallMeta
//! Phase 2 添加：VectorMeta / VecOp
//! Phase 3 添加：GateMeta / RouteMeta / RaceMeta / CleanupMeta

const std = @import("std");
const scalar = @import("value").scalar;
const node_mod = @import("node.zig");
const channel_mod = @import("channel.zig");

/// 标量元数据：描述 const_i/const_f/int_*/float_*/cmp_*/cast 等节点的类型信息
pub const ScalarMeta = struct {
    /// 值类别：区分整数/浮点/布尔/字符
    kind: ScalarKind,
    /// 整数子类型（kind == .int 时有效）
    int_kind: scalar.IntKind = .i64,
    /// 浮点子类型（kind == .float 时有效）
    float_kind: scalar.FloatKind = .f64,
    /// 编译期常量值（const_i/const_f 节点使用，其他节点忽略）
    /// 用 i128 作为最大容器，浮点通过 @bitCast 存入
    const_val: ?ConstVal = null,
};

/// 标量值类别
pub const ScalarKind = enum(u4) {
    int, // 整数（int_kind 进一步区分宽度）
    float, // 浮点（float_kind 进一步区分宽度）
    bool, // 布尔
    char, // 字符（u21）
    unit, // unit 类型
    null_, // null 类型（避免与关键字冲突）
    str, // 字符串引用（meta_index 指向字符串池）
    ref, // 堆引用
};

/// 编译期常量值容器
///
/// const_i 节点存 int_val，const_f 节点存 float_val（通过 @bitCast 转为 u128），
/// const_bool 存 bool_val，const_char 存 char_val。
pub const ConstVal = union(enum) {
    int_val: i128,
    float_val: u128, // f16/f32/f64/f128 的位模式，按 float_kind 解释
    bool_val: bool,
    char_val: u21,
};

/// 调用元数据：描述 call 节点的函数索引与参数信息
pub const CallMeta = struct {
    func_index: u16, // 被调用函数在 functions 表中的索引
    arg_count: u8, // 实际参数个数
    tail_call: bool = false, // 是否在尾位置（用于 TCO 判定）
    /// Memoization 槽位索引。0 = 不缓存，>0 = 对应 Engine 中的 memo_cache 槽位。
    /// 纯函数 + 标量参数/返回类型时由 IRBuilder 分配。
    memo_slot: u16 = 0,
    /// 泛型函数的类型实参（type_id 列表，1-indexed；空切片表示非泛型调用）
    /// typeof(T) 在泛型函数内通过哨兵 meta_index=0x8000|param_idx 查此切片
    /// 由调用点从显式 type_args 或参数类型推断填充
    type_args: []const u16 = &.{},
};

/// halt 种类：控制 cleanup 的触发时机
pub const HaltKind = enum(u4) {
    return_halt, // 正常返回触发
    throw_halt, // 抛出错误触发
    panic_halt, // panic 触发
    any_halt, // 任何 halt 都触发
};

/// 函数定义：每个函数是一个 Glue IR 子图
pub const Function = struct {
    name: []const u8, // 函数名
    node_start: u32, // 节点流起始索引
    node_count: u32, // 节点数量
    param_channels: []const u16, // 参数通道索引列表
    return_channel: u16, // 返回值通道索引
    is_entry: bool = false, // 是否为入口函数（main）
    is_async: bool = false, // 是否为异步函数（Phase 5）
    /// 函数局部通道范围起始索引（参数+中间通道，不含 return_channel）
    local_chan_start: u16 = 0,
    /// 函数局部通道数量
    local_chan_count: u16 = 0,
    /// 逃逸分析结果：true 表示函数内分配的对象不逃逸出函数作用域。
    /// 引擎可在此类函数返回时 reset ShadowArena（当前为预留字段，
    /// 实际启用需配合分配点分流：非逃逸对象进 ShadowArena 而非 RC 堆）
    no_escape: bool = false,
};

// ════════════════════════════════════════════════════════════════
// Phase 2: 向量元数据
// ════════════════════════════════════════════════════════════════

/// 向量操作子类型：区分 vec_source 的源类型 / vec_sink 的收集方式
pub const VecOp = enum(u4) {
    // vec_source 子类型
    range_source, // range(start, end) → 向量
    array_source, // 数组 → 向量
    repeat_source, // repeat(val, n) → 向量
    string_source, // 字符串 → Unicode 标量值向量
    // vec_sink 子类型
    sink_last, // 取最后一个元素
    sink_first, // 取第一个元素
    sink_count, // 计数
    sink_to_array, // 收集为数组
    // vec_map/vec_map2/vec_fold/vec_scan 不区分子类型，由 NodeOp 本身区分
};

/// 向量元数据：描述 vec_* 节点的信息
///
/// 设计支持两种循环体编码：
/// 1. 内联标量模式：循环体是单个标量运算（如 x + 1），inner_op 直接引用
/// 2. 子图模式：循环体是复杂表达式，body_start/body_len 引用节点流中的一段
///
/// vec_source 用 source_kind 区分源类型，vec_sink 用 sink_kind 区分收集方式。
pub const VectorMeta = struct {
    /// 向量子操作（source/sink 子类型）
    vec_op: VecOp = .range_source,
    /// 内联标量 op（简单 map/fold 用，如 int_add）
    inner_op: node_mod.NodeOp = .const_i,
    /// 内联标量 op 的 meta 索引
    inner_meta: u16 = 0,
    /// 子图模式：循环体节点序列在主节点流中的起始索引
    body_start: u32 = 0,
    /// 子图模式：循环体节点数量
    body_len: u32 = 0,
    /// 向量长度（编译期已知则填充，未知为 null）
    length: ?u32 = null,
    /// 元素通道类型
    elem_type: channel_mod.ChanType = .i64_chan,
};

// ════════════════════════════════════════════════════════════════
// Phase 3: 门控/路由/竞争/清理元数据
// ════════════════════════════════════════════════════════════════

/// 门控元数据：描述 ? 短路 / 错误传播链
///
/// gate_check 检查值是否 Ok，gate_propagate OR 传播错误掩码，
/// gate_select 按 mask 选择值，gate_get_ok/gate_get_err 提取值。
pub const GateMeta = struct {
    /// 错误类型索引（字符串池中的错误类型名）
    error_type: u32 = 0,
    /// 上游错误掩码通道（gate_propagate 的第二个输入）
    propagate_from: u16 = 0,
    /// 门控操作子类型
    gate_kind: GateKind = .check,
};

/// 门控操作子类型
pub const GateKind = enum(u3) {
    check, // gate_check：检查 is_ok
    get_ok, // gate_get_ok：提取 Ok 值
    get_err, // gate_get_err：提取 Error 值
    propagate, // gate_propagate：OR 传播错误掩码
    select, // gate_select：按 mask 选择值
    make_ok, // gate_make_ok：构造 Ok
    make_err, // gate_make_err：构造 Error
};

/// 路由元数据：描述 Trait 动态分派
///
/// route_get_tag 读取值的 tag，route_dispatch 按 tag 索引分派表，
/// route_merge 合并分派结果。
pub const RouteMeta = struct {
    /// Trait 标识（字符串池索引）
    trait_id: u32 = 0,
    /// 方法标识（字符串池索引）
    method_id: u32 = 0,
    /// 各实现的函数索引列表（独立函数模式，Phase 5 暂未使用）
    targets: []const u16 = &.{},
    /// 实现数量
    target_count: u8 = 0,
    /// 子图模式：每个分支的 body 起始节点索引（全局）
    body_starts: []const u32 = &.{},
    /// 子图模式：每个分支的 body 节点数量
    body_lens: []const u32 = &.{},
};

/// 竞争元数据：描述 select 多路复用
///
/// race_source 检查通道就绪性，race_select 选择第一个就绪的，
/// race_yield 无就绪时让出执行权。
pub const RaceMeta = struct {
    /// 竞争源数量
    source_count: u8 = 0,
    /// 超时时间（毫秒），null 表示无限等待
    timeout_ms: ?u64 = null,
};

/// 清理元数据：描述 defer 清理链
///
/// cleanup_register 注册 defer 体到 LIFO 栈，
/// halt 时 cleanup_run LIFO 执行所有已注册的 defer。
pub const CleanupMeta = struct {
    /// 触发条件：return/throw/panic/any
    trigger: HaltKind = .any_halt,
    /// defer 体节点序列在主节点流中的起始索引
    body_start: u32 = 0,
    /// defer 体节点数量
    body_len: u32 = 0,
    /// 注册顺序（LIFO 执行，小序号后执行）
    order: u32 = 0,
};

// ════════════════════════════════════════════════════════════════
// Phase 5: 星轨元数据
// ════════════════════════════════════════════════════════════════

/// 星轨元数据：描述 async/spawn 的异步轨道
///
/// orbit_async_create 创建轨道实例（返回 handle），
/// orbit_async_join 等待轨道完成并取结果，
/// orbit_chan_send/recv 通过桥接通道与轨道通信。
pub const OrbitMeta = struct {
    /// 异步函数索引（functions 表中的索引）
    func_index: u16,
    /// 参数数量
    arg_count: u8,
    /// 结果通道类型（orbit_async_join 的输出类型）
    result_type: channel_mod.ChanType = .i64_chan,
    /// 是否为 spawn（fire-and-forget，无 join）
    is_spawn: bool = false,
};

/// 循环元数据：描述标量循环（含 break/continue 的 for/while/loop）
///
/// scalar_loop 节点逐元素执行循环体子图，
/// halt_break/halt_continue 在体子图内终止当前迭代或整个循环。
pub const LoopMeta = struct {
    /// 循环体子图起始节点索引（全局）
    body_start: u32 = 0,
    /// 循环体子图节点数量
    body_len: u32 = 0,
    /// 循环类型
    loop_kind: LoopKind = .loop,
    /// while 条件子图长度（body 子图前 cond_len 个节点为条件求值）
    /// loop/for 不使用（为 0）
    cond_len: u32 = 0,
    /// 条件通道（while 的条件输出通道；for 的迭代器向量通道）
    cond_chan: u16 = 0,
    /// 循环变量通道（for 专用，绑定当前元素）
    iter_chan: u16 = 0,
    /// 元素类型（for 专用）
    elem_type: channel_mod.ChanType = .i64_chan,
};

/// 循环类型
pub const LoopKind = enum(u2) {
    loop, // 无限循环（仅 break 退出）
    while_loop, // while 循环（条件为 false 退出）
    for_loop, // for 循环（遍历完退出）
};

// ════════════════════════════════════════════════════════════════
// 闭包元数据（lambda 编译）
// ════════════════════════════════════════════════════════════════

/// 闭包元数据：描述 lambda 编译为匿名函数后的信息
///
/// closure_make 节点引用此元数据，在运行时创建 Closure 值，
/// 存储 func_index 和捕获的上值列表。
/// body_start/body_len 记录 lambda 函数体在主节点流中的位置，
/// 使外层函数执行时可以跳过这些内联节点（类似 vec_map 的 body 子图）。
pub const ClosureMeta = struct {
    /// 匿名函数在 functions 表中的索引
    func_index: u16,
    /// 上值（捕获变量）数量
    upvalue_count: u8,
    /// 结果通道类型（call_indirect 的输出类型）
    result_type: channel_mod.ChanType = .i64_chan,
    /// lambda 函数体节点序列在主节点流中的起始索引（全局）
    body_start: u32 = 0,
    /// lambda 函数体节点数量
    body_len: u32 = 0,
    /// 每个 upvalue 是否为 cell 通道（var 变量，引用语义），最多 8 个 upvalue
    /// cell upvalue 在 call_indirect 时直接共享通道指针，而非拷贝值
    cell_upvalues: u8 = 0,
};

// ════════════════════════════════════════════════════════════════
// 反射元数据：TypeInfo<T> 静态类型描述符
// ════════════════════════════════════════════════════════════════

/// 类型形态枚举（对应 Glue TypeKind ADT 的 9 个变体，含 Nullable）
/// 纯枚举，仅用于 == 判断，不携带数据
pub const TypeKind = enum(u4) {
    primitive, // 基础类型（i32/f64/bool/char/str/()）
    record, // 记录（Product Type，命名字段）
    adt, // 代数数据类型（Sum Type，多个构造器）
    newtype, // Newtype（单字段包装）
    alias, // 类型别名
    func, // 函数类型
    trait, // Trait 类型
    unit, // 单位类型（）
    nullable, // 可空类型注解（typeof(T?) 的返回值）

    /// 转换为 TypeKind ADT 的构造器名（与 Glue 源码一致）
    pub fn ctorName(self: TypeKind) []const u8 {
        return switch (self) {
            .primitive => "Primitive",
            .record => "Record",
            .adt => "Adt",
            .newtype => "Newtype",
            .alias => "Alias",
            .func => "Func",
            .trait => "Trait",
            .unit => "Unit",
            .nullable => "Nullable",
        };
    }
};

/// 字段元信息（对应 Glue FieldInfo 类型的静态部分）
pub const FieldMeta = struct {
    name: []const u8,
    type_name: []const u8,
    is_nullable: bool,
    index: u32,
};

/// 构造器元信息（对应 Glue ConstructorInfo 类型的静态部分）
pub const ConstructorMeta = struct {
    name: []const u8,
    fields: []const FieldMeta,
    is_unit: bool,
    index: u32,
};

/// 类型参数元信息（对应 Glue TypeParamInfo 类型的静态部分）
pub const TypeParamMeta = struct {
    name: []const u8,
    constraints: []const []const u8, // Trait 名列表
    is_specialized: bool,
    specialization: ?[]const u8, // 具体类型名（特化时）
};

/// 函数签名元信息（对应 Glue FuncSig 类型的静态部分）
pub const FuncSigMeta = struct {
    param_types: []const []const u8,
    return_type: []const u8,
    is_async: bool,
};

/// Trait 元信息（对应 Glue TraitInfo 类型的静态部分）
pub const TraitMeta = struct {
    name: []const u8,
    module: []const u8,
    type_params: []const TypeParamMeta,
    parent_traits: []const []const u8, // 父 Trait 名列表
    associated_types: []const []const u8, // 关联类型名列表
    method_names: []const []const u8, // 方法名列表
};

/// 关联类型元信息（对应 Glue AssociatedTypeInfo 类型的静态部分）
pub const AssociatedTypeMeta = struct {
    name: []const u8,
    is_specified: bool,
    default_type: ?[]const u8,
};

/// 方法元信息（对应 Glue MethodInfo 类型的静态部分）
pub const MethodMeta = struct {
    name: []const u8,
    signature: FuncSigMeta,
    is_override: bool,
    is_delegate: bool,
    delegate_trait: ?[]const u8,
    is_async: bool,
};

/// 布局信息子结构（对应 Glue LayoutInfo）
/// size/alignment 用 u32：天然非负，范围足够（4GB）
pub const LayoutInfo = struct {
    size: u32,
    alignment: u32,
};

/// Trait 实现信息子结构（对应 Glue TraitImplInfo）
/// 与 LayoutInfo 对称，从 TypeInfo 剥离
pub const TraitImplInfo = struct {
    parent_traits: []const TraitMeta,
    implemented_traits: []const TraitMeta,
    methods: []const MethodMeta,
    associated_types: []const AssociatedTypeMeta,
};

/// 类型结构形态 ADT（对应 Glue TypeStructure）
/// kind-dependent 字段的 ADT 化，编译器保证字段存在
/// inner/target/nullable_inner 通过 type_id 引用其他 TypeMetadata（1-indexed，0 = None）
pub const TypeStructure = union(enum) {
    primitive,
    record: []const FieldMeta,
    adt: []const ConstructorMeta,
    /// Newtype 的内部类型 type_id
    newtype: u16,
    /// Alias 的目标类型 type_id
    alias: u16,
    /// 函数类型签名
    func: FuncSigMeta,
    /// Trait 元信息
    trait: TraitMeta,
    unit,
    /// Nullable 包装的内部类型 type_id（typeof(T?) 使用）
    nullable: u16,
};

/// 完整的类型描述符（对应 Glue TypeInfo<T> 的 7 个顶层字段）
///
/// 由 IRBuilder 在编译期收集，存入 GlueIR.type_metadata_table。
/// Engine 执行 builtin_typeof 时按 type_id 查表，构造 RecordValue。
/// kind 是快速标签，structure 是携带数据的 ADT（kind 决定哪个变体有效）。
/// layout/impls 是剥离的子结构（与 layout/impls 对称）。
pub const TypeMetadata = struct {
    name: []const u8,
    module: []const u8,
    kind: TypeKind,
    structure: TypeStructure,
    layout: LayoutInfo,
    impls: TraitImplInfo,
    type_params: []const TypeParamMeta,
};

/// 类型元数据表：按 type_id（1-indexed）索引
///
/// type_id 0 保留为 "无类型" 哨兵。
/// name_to_id 提供 "Point" → type_id 的反向查询。
/// builtin_typeof 节点的 meta_index 即 type_id，Engine 查表构造 TypeInfo。
pub const TypeMetadataTable = struct {
    /// 1-indexed 条目：entries[type_id - 1]
    entries: []const TypeMetadata = &.{},
    /// 类型名 → type_id 映射（不区分类型参数）
    name_to_id: std.StringHashMap(u16) = undefined,

    /// 按名称查询 type_id（找不到返回 0）
    pub fn getIdByName(self: *const TypeMetadataTable, name: []const u8) u16 {
        return self.name_to_id.get(name) orelse 0;
    }

    /// 按 type_id 查询元数据（id=0 或越界返回 null）
    pub fn get(self: *const TypeMetadataTable, type_id: u16) ?*const TypeMetadata {
        if (type_id == 0 or type_id > self.entries.len) return null;
        return &self.entries[type_id - 1];
    }

    /// 初始化 name_to_id 映射（必须在 entries 填充后调用一次）
    pub fn initNameMap(self: *TypeMetadataTable, allocator: std.mem.Allocator) !void {
        self.name_to_id = std.StringHashMap(u16).init(allocator);
        for (self.entries, 0..) |entry, i| {
            try self.name_to_id.put(entry.name, @intCast(i + 1));
        }
    }

    /// 释放 name_to_id 占用的内存
    pub fn deinit(self: *TypeMetadataTable) void {
        if (self.entries.len > 0) {
            self.name_to_id.deinit();
        }
    }
};

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "ScalarMeta 默认值" {
    const m = ScalarMeta{ .kind = .int, .int_kind = .i32 };
    try testing.expectEqual(ScalarKind.int, m.kind);
    try testing.expectEqual(scalar.IntKind.i32, m.int_kind);
    try testing.expectEqual(@as(?ConstVal, null), m.const_val);
}

test "ConstVal 整数存储" {
    const m = ScalarMeta{
        .kind = .int,
        .int_kind = .i64,
        .const_val = .{ .int_val = 42 },
    };
    try testing.expectEqual(@as(i128, 42), m.const_val.?.int_val);
}

test "HaltKind 触发条件" {
    try testing.expectEqual(HaltKind.return_halt, .return_halt);
    try testing.expectEqual(HaltKind.any_halt, .any_halt);
}

test "Function 基本字段" {
    const params = [_]u16{ 0, 1 };
    const f = Function{
        .name = "add",
        .node_start = 0,
        .node_count = 5,
        .param_channels = &params,
        .return_channel = 2,
        .is_entry = false,
    };
    try testing.expectEqualStrings("add", f.name);
    try testing.expectEqual(@as(u32, 5), f.node_count);
    try testing.expectEqual(@as(u16, 2), f.return_channel);
    try testing.expect(!f.is_entry);
}

test "VectorMeta range_source 默认" {
    const vm = VectorMeta{
        .vec_op = .range_source,
        .length = 10,
        .elem_type = .i64_chan,
    };
    try testing.expectEqual(VecOp.range_source, vm.vec_op);
    try testing.expectEqual(@as(?u32, 10), vm.length);
    try testing.expectEqual(channel_mod.ChanType.i64_chan, vm.elem_type);
}

test "VectorMeta vec_map 内联标量" {
    const vm = VectorMeta{
        .vec_op = .range_source, // vec_map 不使用 vec_op 字段
        .inner_op = .int_add,
        .inner_meta = 3,
        .length = 100,
        .elem_type = .i32_chan,
    };
    try testing.expectEqual(node_mod.NodeOp.int_add, vm.inner_op);
    try testing.expectEqual(@as(u16, 3), vm.inner_meta);
    try testing.expectEqual(@as(?u32, 100), vm.length);
}

test "VectorMeta vec_sink 收集方式" {
    const vm = VectorMeta{
        .vec_op = .sink_last,
        .elem_type = .i64_chan,
    };
    try testing.expectEqual(VecOp.sink_last, vm.vec_op);
}

test "GateMeta ? 传播链" {
    const gm = GateMeta{
        .error_type = 5,
        .propagate_from = 12,
        .gate_kind = .propagate,
    };
    try testing.expectEqual(GateKind.propagate, gm.gate_kind);
    try testing.expectEqual(@as(u32, 5), gm.error_type);
    try testing.expectEqual(@as(u16, 12), gm.propagate_from);
}

test "GateMeta check 提取值" {
    const gm = GateMeta{ .gate_kind = .get_ok };
    try testing.expectEqual(GateKind.get_ok, gm.gate_kind);
}

test "RouteMeta Trait 分派表" {
    const targets = [_]u16{ 3, 7, 11 };
    const rm = RouteMeta{
        .trait_id = 1,
        .method_id = 2,
        .targets = &targets,
        .target_count = 3,
    };
    try testing.expectEqual(@as(u32, 1), rm.trait_id);
    try testing.expectEqual(@as(u8, 3), rm.target_count);
    try testing.expectEqual(@as(u16, 7), rm.targets[1]);
}

test "RaceMeta 多路复用" {
    const rm = RaceMeta{
        .source_count = 3,
        .timeout_ms = 1000,
    };
    try testing.expectEqual(@as(u8, 3), rm.source_count);
    try testing.expectEqual(@as(?u64, 1000), rm.timeout_ms);
}

test "CleanupMeta defer 栈" {
    const cm = CleanupMeta{
        .trigger = .return_halt,
        .body_start = 10,
        .body_len = 3,
        .order = 1,
    };
    try testing.expectEqual(HaltKind.return_halt, cm.trigger);
    try testing.expectEqual(@as(u32, 10), cm.body_start);
    try testing.expectEqual(@as(u32, 3), cm.body_len);
}

test "OrbitMeta async 轨道" {
    const om = OrbitMeta{
        .func_index = 3,
        .arg_count = 2,
        .result_type = .i32_chan,
        .is_spawn = false,
    };
    try testing.expectEqual(@as(u16, 3), om.func_index);
    try testing.expectEqual(@as(u8, 2), om.arg_count);
    try testing.expectEqual(channel_mod.ChanType.i32_chan, om.result_type);
    try testing.expect(!om.is_spawn);
}
