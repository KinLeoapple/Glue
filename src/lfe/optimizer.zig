//! 层流图优化器
//!
//! 阶段 3 范围：
//! - 常量折叠：编译期计算全常量输入的层
//! - 死通道消除：移除未被引用且无副作用的层
//! - 层融合：合并相邻层（scale_add / fma 模式）
//! - 通道活跃区间分析 + 物理槽位复用
//!
//! 所有 pass 产生新的 LaminarGraph，不修改原图。

const std = @import("std");
const lamina_mod = @import("lamina.zig");

const Lamina = lamina_mod.Lamina;
const LaminaOp = lamina_mod.LaminaOp;
const LaminarGraph = lamina_mod.LaminarGraph;
const ChannelMeta = lamina_mod.ChannelMeta;
const ScalarChanType = lamina_mod.ScalarChanType;
const IntKind = lamina_mod.IntKind;
const FloatKind = lamina_mod.FloatKind;
const NativeIntType = lamina_mod.NativeIntType;
const NativeFloatType = lamina_mod.NativeFloatType;
const Orbit = lamina_mod.Orbit;
const OrbitHub = lamina_mod.OrbitHub;
const OrbitEntry = lamina_mod.OrbitEntry;

const ALL_INT_KINDS = [_]IntKind{
    .i8, .i16, .i32, .i64, .i128,
    .u8, .u16, .u32, .u64, .u128,
};

const ALL_FLOAT_KINDS = [_]FloatKind{
    .f16, .f32, .f64, .f128,
};

/// 优化器错误
pub const OptError = error{
    OutOfMemory,
};

/// 常量值跟踪：记录通道是否持有常量及其值
const ConstValue = struct {
    is_const: bool = false,
    val: i64 = 0,
    int_kind: ?IntKind = null,
    float_kind: ?FloatKind = null,
};

/// 判断操作是否有副作用（不可消除）
fn hasSideEffect(op: LaminaOp) bool {
    return switch (op) {
        .debug_print,
        .halt_return,
        .halt_throw,
        .halt_break,
        .halt_continue,
        .extern_call,
        .extern_call_batch,
        .cell_set,
        .cell_swap,
        .atomic_store,
        .atomic_cas,
        .channel_send,
        .channel_close,
        .sender_send,
        .sender_close,
        .array_set,
        .array_push,
        .record_set,
        // 星轨模型操作均有副作用
        .orbit_hub,
        .orbit_hub_async,
        .orbit_join,
        .defer_register,
        .defer_execute,
        .stack_push,
        .stack_pop,
        .stack_peek,
        .stack_depth,
        .range_make,
        .iter_next,
        => true,
        else => false,
    };
}

/// 主优化入口：对层流图执行全部优化 pass
pub fn optimize(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    var g = try constantFold(allocator, graph);
    g = try deadChannelElim(allocator, &g);
    g = try layerFusion(allocator, &g);
    g = try channelLiveness(allocator, &g);
    // 星轨专用 pass：提升 → 合并 → 死轨道消除
    g = try staticHoisting(allocator, &g);
    g = try orbitMerging(allocator, &g);
    g = try orbitDeadCode(allocator, &g);
    return g;
}

// ══════════════════════════════════════════════════════
// Pass 1: 常量折叠
// ══════════════════════════════════════════════════════

/// 常量折叠：对所有输入为常量的层，在编译期计算结果并替换为 constant 层
pub fn constantFold(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.channel_count == 0 or graph.laminas.len == 0) {
        return cloneGraph(allocator, graph);
    }

    // 追踪每个通道的常量状态
    const const_vals = try allocator.alloc(ConstValue, graph.channel_count);
    defer allocator.free(const_vals);
    for (const_vals) |*cv| cv.* = .{};

    // 新层列表（可能在折叠中改变）
    var new_laminas = std.ArrayList(Lamina).empty;
    defer new_laminas.deinit(allocator);

    for (graph.laminas) |lam| {
        var folded_lam = lam;

        switch (lam.op) {
            .constant => {
                // 标记输出通道为常量
                const_vals[lam.output].is_const = true;
                const_vals[lam.output].val = lam.const_val orelse 0;
                const_vals[lam.output].int_kind = lam.int_kind;
                const_vals[lam.output].float_kind = lam.float_kind;
            },

            .int_add, .int_sub, .int_mul, .int_div, .int_mod,
            .int_and, .int_or, .int_xor,
            => {
                if (try foldIntBinary(const_vals, &folded_lam)) {
                    // 折叠成功，folded_lam 已更新为 constant 层
                }
            },

            .int_neg, .int_abs, .int_not => {
                if (try foldIntUnary(const_vals, &folded_lam)) {
                    // 折叠成功
                }
            },

            .float_add, .float_sub, .float_mul, .float_div => {
                if (try foldFloatBinary(const_vals, &folded_lam)) {
                    // 折叠成功
                }
            },

            .float_neg, .float_abs => {
                if (try foldFloatUnary(const_vals, &folded_lam)) {
                    // 折叠成功
                }
            },

            else => {},
        }

        try new_laminas.append(allocator, folded_lam);
    }

    return rebuildGraph(allocator, graph, new_laminas.items);
}

/// 尝试折叠整数二元运算
fn foldIntBinary(const_vals: []ConstValue, lam: *Lamina) OptError!bool {
    if (lam.input_count < 2) return false;
    const a_cv = &const_vals[lam.inputs[0]];
    const b_cv = &const_vals[lam.inputs[1]];
    if (!a_cv.is_const or !b_cv.is_const) return false;

    const kind = lam.int_kind orelse return false;
    const a = a_cv.val;
    const b = b_cv.val;

    const result: ?i64 = switch (lam.op) {
        .int_add => a +% b,
        .int_sub => a -% b,
        .int_mul => a *% b,
        .int_div => if (b == 0) null else @divTrunc(a, b),
        .int_mod => if (b == 0) null else @rem(a, b),
        .int_and => a & b,
        .int_or => a | b,
        .int_xor => a ^ b,
        else => null,
    };

    if (result) |r| {
        lam.op = .constant;
        lam.const_val = r;
        lam.input_count = 0;
        const_vals[lam.output].is_const = true;
        const_vals[lam.output].val = r;
        const_vals[lam.output].int_kind = kind;
        return true;
    }
    return false;
}

/// 尝试折叠整数一元运算
fn foldIntUnary(const_vals: []ConstValue, lam: *Lamina) OptError!bool {
    if (lam.input_count > 1) return false;
    const a_cv = &const_vals[lam.inputs[0]];
    if (!a_cv.is_const) return false;

    const kind = lam.int_kind orelse return false;
    const a = a_cv.val;

    const result: i64 = switch (lam.op) {
        .int_neg => 0 -% a,
        .int_abs => if (a < 0) (0 -% a) else a,
        .int_not => ~a,
        else => return false,
    };

    lam.op = .constant;
    lam.const_val = result;
    lam.input_count = 0;
    const_vals[lam.output].is_const = true;
    const_vals[lam.output].val = result;
    const_vals[lam.output].int_kind = kind;
    return true;
}

/// 尝试折叠浮点二元运算
fn foldFloatBinary(const_vals: []ConstValue, lam: *Lamina) OptError!bool {
    if (lam.input_count < 2) return false;
    const a_cv = &const_vals[lam.inputs[0]];
    const b_cv = &const_vals[lam.inputs[1]];
    if (!a_cv.is_const or !b_cv.is_const) return false;

    const kind = lam.float_kind orelse return false;
    const a: f64 = @bitCast(a_cv.val);
    const b: f64 = @bitCast(b_cv.val);

    const result: f64 = switch (lam.op) {
        .float_add => a + b,
        .float_sub => a - b,
        .float_mul => a * b,
        .float_div => if (b == 0) return false else a / b,
        else => return false,
    };

    lam.op = .constant;
    lam.const_val = @bitCast(result);
    lam.input_count = 0;
    const_vals[lam.output].is_const = true;
    const_vals[lam.output].val = @bitCast(result);
    const_vals[lam.output].float_kind = kind;
    return true;
}

/// 尝试折叠浮点一元运算
fn foldFloatUnary(const_vals: []ConstValue, lam: *Lamina) OptError!bool {
    if (lam.input_count > 1) return false;
    const a_cv = &const_vals[lam.inputs[0]];
    if (!a_cv.is_const) return false;

    const kind = lam.float_kind orelse return false;
    const a: f64 = @bitCast(a_cv.val);

    const result: f64 = switch (lam.op) {
        .float_neg => -a,
        .float_abs => @abs(a),
        else => return false,
    };

    lam.op = .constant;
    lam.const_val = @bitCast(result);
    lam.input_count = 0;
    const_vals[lam.output].is_const = true;
    const_vals[lam.output].val = @bitCast(result);
    const_vals[lam.output].float_kind = kind;
    return true;
}

// ══════════════════════════════════════════════════════
// Pass 2: 死通道消除
// ══════════════════════════════════════════════════════

/// 死通道消除：移除输出未被引用且无副作用的层
pub fn deadChannelElim(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.laminas.len == 0) return cloneGraph(allocator, graph);

    // 标记被引用的通道
    const used = try allocator.alloc(bool, graph.channel_count);
    defer allocator.free(used);
    @memset(used, false);

    // 输出通道一定保留
    used[graph.output_channel] = true;

    // 扫描太阳层所有层的输入引用
    for (graph.laminas) |lam| {
        for (lam.inputs[0..lam.input_count]) |in| {
            if (in < graph.channel_count) used[in] = true;
        }
        if (lam.predicate) |p| {
            if (p < graph.channel_count) used[p] = true;
        }
    }

    // 扫描轨道内所有层的输入引用（轨道内通道不能被误判为死通道）
    for (graph.orbits) |orbit| {
        for (orbit.laminas) |lam| {
            for (lam.inputs[0..lam.input_count]) |in| {
                if (in < graph.channel_count) used[in] = true;
            }
            if (lam.predicate) |p| {
                if (p < graph.channel_count) used[p] = true;
            }
            // 轨道输出通道和 continue_channel 必须保留
            used[orbit.output_channel] = true;
            if (orbit.continue_channel) |cc| {
                if (cc < graph.channel_count) used[cc] = true;
            }
        }
    }

    // 扫描 OrbitHub 的 cond_channel 和 param_mapping 引用
    for (graph.orbit_hubs) |hub| {
        if (hub.cond_channel) |cc| {
            if (cc < graph.channel_count) used[cc] = true;
        }
        used[hub.output_channel] = true;
        for (hub.param_mapping) |pm| {
            if (pm.src < graph.channel_count) used[pm.src] = true;
            if (pm.dst < graph.channel_count) used[pm.dst] = true;
        }
    }

    // 扫描 defer_entries 引用的轨道
    for (graph.defer_entries) |de| {
        if (de.orbit_index < graph.orbits.len) {
            const orbit = graph.orbits[de.orbit_index];
            used[orbit.output_channel] = true;
        }
    }

    // 过滤层：保留有副作用或输出被引用的层
    var new_laminas = std.ArrayList(Lamina).empty;
    defer new_laminas.deinit(allocator);

    for (graph.laminas) |lam| {
        if (hasSideEffect(lam.op) or used[lam.output]) {
            try new_laminas.append(allocator, lam);
        }
    }

    return rebuildGraph(allocator, graph, new_laminas.items);
}

// ══════════════════════════════════════════════════════
// Pass 3: 层融合
// ══════════════════════════════════════════════════════

/// 层融合：合并相邻层
/// - int_mul(a, const_k) → int_add(result, const_c)  ==>  int_scale_add(a, k, c)
/// - int_mul(a, b) → int_add(result, c)              ==>  int_fma(a, b, c)
pub fn layerFusion(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.laminas.len < 2) return cloneGraph(allocator, graph);

    // 构建通道 → 定义层索引映射
    const def_of = try allocator.alloc(?usize, graph.channel_count);
    defer allocator.free(def_of);
    @memset(def_of, null);

    for (graph.laminas, 0..) |lam, i| {
        def_of[lam.output] = i;
    }

    var new_laminas = std.ArrayList(Lamina).empty;
    defer new_laminas.deinit(allocator);

    const fused = try allocator.alloc(bool, graph.laminas.len);
    defer allocator.free(fused);
    @memset(fused, false);

    for (graph.laminas, 0..) |lam, i| {
        if (fused[i]) continue;

        // 模式 1: int_add(int_mul(a, const_k), const_c) → int_scale_add(a, k, c)
        if (lam.op == .int_add and lam.input_count == 2) {
            const lhs_def = def_of[lam.inputs[0]];
            const rhs_cv = isConstChannel(graph, lam.inputs[1]);

            if (lhs_def != null and rhs_cv != null and !fused[lhs_def.?]) {
                const mul_lam = graph.laminas[lhs_def.?];
                if (mul_lam.op == .int_mul and mul_lam.input_count == 2) {
                    const k_cv = isConstChannel(graph, mul_lam.inputs[1]);
                    if (k_cv != null) {
                        // 融合为 int_scale_add
                        var fused_lam = Lamina{
                            .op = .int_scale_add,
                            .inputs = .{ mul_lam.inputs[0], 0, 0 },
                            .output = lam.output,
                            .const_val = k_cv.?,
                            .const_val2 = rhs_cv.?,
                            .int_kind = lam.int_kind,
                            .input_count = 1,
                        };
                        try new_laminas.append(allocator, fused_lam);
                        fused[lhs_def.?] = true;
                        _ = &fused_lam;
                        continue;
                    }
                }
            }
        }

        // 模式 2: int_add(int_mul(a, b), c) → int_fma(a, b, c)（c 为常量）
        if (lam.op == .int_add and lam.input_count == 2) {
            const lhs_def = def_of[lam.inputs[0]];
            const rhs_cv = isConstChannel(graph, lam.inputs[1]);

            if (lhs_def != null and rhs_cv != null and !fused[lhs_def.?]) {
                const mul_lam = graph.laminas[lhs_def.?];
                if (mul_lam.op == .int_mul and mul_lam.input_count == 2) {
                    // 两个非常量输入 + 一个常量加数 → int_fma
                    if (isConstChannel(graph, mul_lam.inputs[1]) == null) {
                        var fused_lam = Lamina{
                            .op = .int_fma,
                            .inputs = .{ mul_lam.inputs[0], mul_lam.inputs[1], 0 },
                            .output = lam.output,
                            .const_val = rhs_cv.?,
                            .int_kind = lam.int_kind,
                            .input_count = 2,
                        };
                        try new_laminas.append(allocator, fused_lam);
                        fused[lhs_def.?] = true;
                        _ = &fused_lam;
                        continue;
                    }
                }
            }
        }

        // 无融合，保留原层
        try new_laminas.append(allocator, lam);
    }

    return rebuildGraph(allocator, graph, new_laminas.items);
}

/// 检查通道是否持有常量值（通过查找 constant 层定义）
fn isConstChannel(graph: *const LaminarGraph, chan: u16) ?i64 {
    for (graph.laminas) |lam| {
        if (lam.output == chan and lam.op == .constant) {
            return lam.const_val;
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════
// Pass 4: 通道活跃区间分析 + 物理槽位复用
// ══════════════════════════════════════════════════════

/// 通道活跃区间分析：计算每个通道的 [定义点, 最后使用点]
/// 非重叠的通道共享物理槽位，减少总物理通道数
/// 注意：含轨道的图跳过槽位复用（轨道内通道引用不会被重映射）
pub fn channelLiveness(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.laminas.len == 0 or graph.channel_count == 0) {
        return cloneGraph(allocator, graph);
    }
    // 含轨道时跳过槽位复用，避免破坏轨道内通道引用
    if (graph.orbits.len > 0) {
        return cloneGraph(allocator, graph);
    }

    const n_chans = graph.channel_count;

    // 计算每个通道的最后使用索引
    const last_use = try allocator.alloc(usize, n_chans);
    defer allocator.free(last_use);
    @memset(last_use, 0);

    const first_def = try allocator.alloc(usize, n_chans);
    defer allocator.free(first_def);
    @memset(first_def, std.math.maxInt(usize));

    for (graph.laminas, 0..) |lam, i| {
        // 定义点
        if (lam.output < n_chans and first_def[lam.output] == std.math.maxInt(usize)) {
            first_def[lam.output] = i;
        }
        // 使用点
        for (lam.inputs[0..lam.input_count]) |in| {
            if (in < n_chans) last_use[in] = i;
        }
        if (lam.predicate) |p| {
            if (p < n_chans) last_use[p] = i;
        }
    }
    // 输出通道的最后使用 = 最后一个层
    last_use[graph.output_channel] = graph.laminas.len;

    // 贪心着色：为每个通道分配物理槽位
    // 遍历通道，找到第一个在 [first_def, last_use] 区间内空闲且类型相同的槽位
    // 类型不同（如 i64_chan vs f64_chan）的通道不能共享槽位，
    // 否则 chan_type 元数据会被覆盖，导致执行时类型解释错误
    const slot_map = try allocator.alloc(u16, n_chans);
    defer allocator.free(slot_map);

    var slot_free_at = std.ArrayList(usize).empty;
    defer slot_free_at.deinit(allocator);
    var slot_types = std.ArrayList(ScalarChanType).empty;
    defer slot_types.deinit(allocator);

    for (0..n_chans) |chan| {
        if (first_def[chan] == std.math.maxInt(usize)) {
            // 未定义的通道（如输入参数），分配槽位 0
            slot_map[chan] = 0;
            continue;
        }

        const chan_type = graph.channel_metas[chan].chan_type;
        // 找到第一个在定义时刻已空闲且类型相同的槽位
        var assigned: ?u16 = null;
        for (slot_free_at.items, 0..) |*free_at, slot| {
            if (free_at.* <= first_def[chan] and slot_types.items[slot] == chan_type) {
                assigned = @intCast(slot);
                free_at.* = last_use[chan] + 1;
                break;
            }
        }

        if (assigned == null) {
            assigned = @intCast(slot_free_at.items.len);
            try slot_free_at.append(allocator, last_use[chan] + 1);
            try slot_types.append(allocator, chan_type);
        }

        slot_map[chan] = assigned.?;
    }

    const physical_count: u16 = @intCast(slot_free_at.items.len);

    // 如果没有减少通道数，直接返回克隆
    if (physical_count >= n_chans) {
        return cloneGraph(allocator, graph);
    }

    // 重写所有层中的通道索引
    var new_laminas = try allocator.alloc(Lamina, graph.laminas.len);
    for (graph.laminas, 0..) |lam, i| {
        new_laminas[i] = lam;
        new_laminas[i].output = slot_map[lam.output];
        for (new_laminas[i].inputs[0..lam.input_count]) |*in| {
            in.* = slot_map[in.*];
        }
        if (lam.predicate) |p| {
            new_laminas[i].predicate = slot_map[p];
        }
    }

    // 构建新的通道元数据
    // 同一槽位的所有通道具有相同 chan_type（由槽位分配保证），
    // 取任意一个的元数据即可；保留 is_cell 标记
    var new_metas = try allocator.alloc(ChannelMeta, physical_count);
    @memset(new_metas, .{ .chan_type = .null_chan, .elem_width = 0 });
    for (0..n_chans) |chan| {
        const meta = graph.channel_metas[chan];
        const slot = slot_map[chan];
        // 首次设置该槽位，或保留 is_cell 标记
        if (new_metas[slot].elem_width == 0) {
            new_metas[slot] = meta;
        } else if (meta.is_cell) {
            new_metas[slot].is_cell = true;
        }
    }

    const result = LaminarGraph{
        .laminas = new_laminas,
        .channel_metas = new_metas,
        .channel_count = physical_count,
        .input_channels = try remapChannels(allocator, graph.input_channels, slot_map),
        .output_channel = slot_map[graph.output_channel],
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .arena = null, // 新图不持有 arena，由调用者管理
    };
    return result;
}

/// 重映射通道索引列表
fn remapChannels(allocator: std.mem.Allocator, chans: []const u16, slot_map: []const u16) OptError![]u16 {
    if (chans.len == 0) return &.{};
    var result = try allocator.alloc(u16, chans.len);
    for (chans, 0..) |c, i| {
        result[i] = slot_map[c];
    }
    return result;
}

// ══════════════════════════════════════════════════════
// Pass 5: 死轨道消除（orbitDeadCode）
// ══════════════════════════════════════════════════════

/// 死轨道消除：移除未被任何活跃 OrbitHub 引用的轨道，并重索引
/// 活跃 OrbitHub = 太阳层中有 orbit_hub lamina 引用的 hub
pub fn orbitDeadCode(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.orbits.len == 0) return cloneGraph(allocator, graph);

    // 标记活跃的 orbit_hub 索引（太阳层中有 lamina 引用的）
    const active_hubs = try allocator.alloc(bool, graph.orbit_hubs.len);
    defer allocator.free(active_hubs);
    @memset(active_hubs, false);

    // 扫描太阳层 laminas 中的 orbit_hub 引用
    for (graph.laminas) |lam| {
        if (lam.op == .orbit_hub or lam.op == .orbit_hub_async) {
            if (lam.hub_index) |hi| {
                if (hi < graph.orbit_hubs.len) active_hubs[hi] = true;
            }
        }
    }
    // 扫描轨道内 laminas 中的嵌套 orbit_hub 引用
    // （函数调用轨道嵌套在循环轨道内时，其 hub lamina 在父轨道的 laminas 里）
    for (graph.orbits) |orbit| {
        for (orbit.laminas) |lam| {
            if (lam.op == .orbit_hub or lam.op == .orbit_hub_async) {
                if (lam.hub_index) |hi| {
                    if (hi < graph.orbit_hubs.len) active_hubs[hi] = true;
                }
            }
        }
    }

    // 标记所有被活跃 hub 引用的轨道索引
    const referenced = try allocator.alloc(bool, graph.orbits.len);
    defer allocator.free(referenced);
    @memset(referenced, false);

    for (graph.orbit_hubs, 0..) |hub, hi| {
        if (!active_hubs[hi]) continue;
        for (hub.orbit_table) |entry| {
            if (entry.orbit_index < graph.orbits.len) {
                referenced[entry.orbit_index] = true;
            }
        }
    }

    // 检查是否有死轨道
    var has_dead = false;
    for (referenced) |r| {
        if (!r) {
            has_dead = true;
            break;
        }
    }
    if (!has_dead) return cloneGraph(allocator, graph);

    // 构建重索引映射和新轨道列表
    const reindex = try allocator.alloc(?u16, graph.orbits.len);
    defer allocator.free(reindex);
    @memset(reindex, null);

    var new_orbits = std.ArrayList(Orbit).empty;
    defer new_orbits.deinit(allocator);

    for (graph.orbits, 0..) |orbit, i| {
        if (referenced[i]) {
            reindex[i] = @intCast(new_orbits.items.len);
            try new_orbits.append(allocator, orbit);
        }
    }

    // 重索引 OrbitHub 的 orbit_table
    var new_hubs = std.ArrayList(OrbitHub).empty;
    defer new_hubs.deinit(allocator);

    for (graph.orbit_hubs) |hub| {
        var new_hub = hub;
        if (hub.orbit_table.len > 0) {
            const new_table = try allocator.alloc(OrbitEntry, hub.orbit_table.len);
            for (hub.orbit_table, 0..) |entry, i| {
                new_table[i] = entry;
                if (entry.orbit_index < graph.orbits.len) {
                    if (reindex[entry.orbit_index]) |new_idx| {
                        new_table[i].orbit_index = new_idx;
                    }
                }
            }
            new_hub.orbit_table = new_table;
        }
        try new_hubs.append(allocator, new_hub);
    }

    // 重索引 defer_entries 的 orbit_index
    var new_defers = graph.defer_entries;
    if (new_defers.len > 0) {
        const defers_copy = try allocator.dupe(lamina_mod.DeferEntry, new_defers);
        for (defers_copy) |*de| {
            if (de.orbit_index < graph.orbits.len) {
                if (reindex[de.orbit_index]) |new_idx| {
                    de.orbit_index = new_idx;
                }
            }
        }
        new_defers = defers_copy;
    }

    const lam_copy = try allocator.dupe(Lamina, graph.laminas);
    const metas_copy = try allocator.dupe(ChannelMeta, graph.channel_metas);
    const inputs_copy = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = lam_copy,
        .channel_metas = metas_copy,
        .channel_count = graph.channel_count,
        .input_channels = inputs_copy,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = try allocator.dupe(Orbit, new_orbits.items),
        .orbit_hubs = try allocator.dupe(OrbitHub, new_hubs.items),
        .defer_entries = new_defers,
        .channel_scopes = graph.channel_scopes,
        .arena = null,
    };
}

// ══════════════════════════════════════════════════════
// Pass 6: 静态提升（staticHoisting）
// ══════════════════════════════════════════════════════

/// 静态提升：将轨道内无谓词门控的 constant 层提升到太阳层
/// 仅提升 .constant 层（无输入、无谓词、无副作用），安全且有效
pub fn staticHoisting(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.orbits.len == 0) return cloneGraph(allocator, graph);

    var any_hoisted = false;
    var new_orbits = std.ArrayList(Orbit).empty;
    defer new_orbits.deinit(allocator);
    var hoisted_laminas = std.ArrayList(Lamina).empty;
    defer hoisted_laminas.deinit(allocator);

    for (graph.orbits) |orbit| {
        var kept = std.ArrayList(Lamina).empty;
        var orbit_hoisted = false;

        for (orbit.laminas) |lam| {
            if (lam.op == .constant and lam.predicate == null) {
                try hoisted_laminas.append(allocator, lam);
                any_hoisted = true;
                orbit_hoisted = true;
            } else {
                try kept.append(allocator, lam);
            }
        }

        var new_orbit = orbit;
        if (orbit_hoisted) {
            new_orbit.laminas = try allocator.dupe(Lamina, kept.items);
        }
        try new_orbits.append(allocator, new_orbit);
        kept.deinit(allocator);
    }

    if (!any_hoisted) return cloneGraph(allocator, graph);

    // 将提升的 laminas 插入太阳层开头（constant 无依赖，位置不影响正确性）
    var new_solar = std.ArrayList(Lamina).empty;
    defer new_solar.deinit(allocator);
    try new_solar.appendSlice(allocator, hoisted_laminas.items);
    try new_solar.appendSlice(allocator, graph.laminas);

    const metas_copy = try allocator.dupe(ChannelMeta, graph.channel_metas);
    const inputs_copy = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = try allocator.dupe(Lamina, new_solar.items),
        .channel_metas = metas_copy,
        .channel_count = graph.channel_count,
        .input_channels = inputs_copy,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = try allocator.dupe(Orbit, new_orbits.items),
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .arena = null,
    };
}

// ══════════════════════════════════════════════════════
// Pass 7: 极简轨道合并（orbitMerging）
// ══════════════════════════════════════════════════════

/// 极简轨道合并：将结构相同、仅常量不同的极简轨道（≤4轨道、每条≤3 lamina、
/// 无副作用、无嵌套）合并为 select 层，避免轨道激活开销
pub fn orbitMerging(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.orbit_hubs.len == 0) return cloneGraph(allocator, graph);

    var solar_changed = false;
    var new_solar = std.ArrayList(Lamina).empty;
    defer new_solar.deinit(allocator);
    var used_orbit = try allocator.alloc(bool, graph.orbits.len);
    defer allocator.free(used_orbit);
    @memset(used_orbit, false);

    for (graph.laminas) |lam| {
        if (lam.op == .orbit_hub) {
            const hub_idx = lam.hub_index orelse {
                try new_solar.append(allocator, lam);
                continue;
            };
            const hub = graph.orbit_hubs[hub_idx];

            // 尝试合并：仅处理 if_hub / match_hub，≤4 轨道
            if (try tryMergeHub(allocator, hub, graph.orbits)) |merge_result| {
                solar_changed = true;
                // 标记被合并的轨道为已用（将在 orbitDeadCode 中消除）
                for (hub.orbit_table) |entry| {
                    used_orbit[entry.orbit_index] = true;
                }
                // 用合并后的 laminas 替换 orbit_hub
                try new_solar.appendSlice(allocator, merge_result);
                continue;
            }
        }
        try new_solar.append(allocator, lam);
    }

    if (!solar_changed) return cloneGraph(allocator, graph);

    const metas_copy = try allocator.dupe(ChannelMeta, graph.channel_metas);
    const inputs_copy = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = try allocator.dupe(Lamina, new_solar.items),
        .channel_metas = metas_copy,
        .channel_count = graph.channel_count,
        .input_channels = inputs_copy,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .arena = null,
    };
}

/// 尝试合并一个 OrbitHub 的轨道
/// 条件：≤4 轨道、每条 ≤3 lamina、结构相同仅常量不同、无副作用、无嵌套
/// 合并策略：每个轨道是 [constant → move(output)] 模式时，合并为 select
const MergeResult = []const Lamina;

fn tryMergeHub(allocator: std.mem.Allocator, hub: OrbitHub, orbits: []const Orbit) OptError!?MergeResult {
    const table = hub.orbit_table;
    if (table.len < 2 or table.len > 4) return null;
    if (hub.is_cyclic) return null; // 环形轨道不合并

    // 检查每个轨道是否是极简模式：[constant, move]
    // 所有轨道的 lamina 结构必须相同（同 op、同 input_count），仅 const_val 不同
    const first_orbit = orbits[table[0].orbit_index];
    if (first_orbit.laminas.len != 2) return null;
    if (first_orbit.laminas[0].op != .constant) return null;
    if (first_orbit.laminas[1].op != .move) return null;

    // 检查所有轨道结构一致
    for (table[1..]) |entry| {
        const orbit = orbits[entry.orbit_index];
        if (orbit.laminas.len != 2) return null;
        if (orbit.laminas[0].op != .constant) return null;
        if (orbit.laminas[1].op != .move) return null;
        // 无副作用、无谓词门控
        for (orbit.laminas) |olam| {
            if (hasSideEffect(olam.op)) return null;
            if (olam.predicate != null) return null;
        }
    }

    // 仅处理 2 轨道合并（if-else 模式）
    if (table.len != 2) return null;

    const cond_chan = hub.cond_channel orelse return null;
    const out_chan = hub.output_channel;

    // 提取每个轨道的常量值和临时通道
    // 轨道结构: [constant(val) → val_chan, move(val_chan → out_chan)]
    const orbit0 = orbits[table[0].orbit_index];
    const orbit1 = orbits[table[1].orbit_index];
    const val_chan0 = orbit0.laminas[0].output;
    const val_chan1 = orbit1.laminas[0].output;

    // 合并为: constant(val0) → val_chan0, constant(val1) → val_chan1,
    //         select(cond, val_chan0, val_chan1) → out_chan
    var result = std.ArrayList(Lamina).empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, orbit0.laminas[0]); // constant 0
    try result.append(allocator, orbit1.laminas[0]); // constant 1
    try result.append(allocator, .{
        .op = .select,
        .inputs = .{ cond_chan, val_chan0, val_chan1 },
        .output = out_chan,
        .input_count = 3,
    });

    return try allocator.dupe(Lamina, result.items);
}

// ══════════════════════════════════════════════════════
// 辅助函数
// ══════════════════════════════════════════════════════

/// 克隆层流图（深拷贝层列表和元数据，共享字符串表与轨道数据）
fn cloneGraph(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    const new_laminas = try allocator.dupe(Lamina, graph.laminas);
    const new_metas = try allocator.dupe(ChannelMeta, graph.channel_metas);
    const new_inputs = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = new_laminas,
        .channel_metas = new_metas,
        .channel_count = graph.channel_count,
        .input_channels = new_inputs,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .arena = null,
    };
}

/// 用新层列表重建层流图（保留轨道数据）
fn rebuildGraph(allocator: std.mem.Allocator, graph: *const LaminarGraph, new_laminas: []const Lamina) OptError!LaminarGraph {
    const lam_copy = try allocator.dupe(Lamina, new_laminas);
    const metas_copy = try allocator.dupe(ChannelMeta, graph.channel_metas);
    const inputs_copy = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = lam_copy,
        .channel_metas = metas_copy,
        .channel_count = graph.channel_count,
        .input_channels = inputs_copy,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .arena = null,
    };
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "常量折叠: (10 + 20) * 3 = 90" {
    const metas = [_]ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 20, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
        .{ .op = .constant, .output = 3, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_mul, .inputs = .{ 2, 3, 0 }, .output = 4, .int_kind = .i64, .input_count = 2 },
    };
    const graph = LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 4,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    };

    const optimized = try constantFold(testing.allocator, &graph);
    defer testing.allocator.free(optimized.laminas);
    defer testing.allocator.free(optimized.channel_metas);
    defer testing.allocator.free(optimized.input_channels);

    // 常量折叠后，所有层都应变成 constant
    for (optimized.laminas) |lam| {
        try testing.expectEqual(LaminaOp.constant, lam.op);
    }

    // 最后一层的常量值应为 90
    try testing.expectEqual(@as(i64, 90), optimized.laminas[optimized.laminas.len - 1].const_val.?);
}

test "死通道消除: 移除未使用的常量层" {
    const metas = [_]ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: unused constant
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: used constant
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 999, .int_kind = .i64, .input_count = 0 }, // 未使用
        .{ .op = .constant, .output = 1, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 1, 0, 0 }, .output = 2, .input_count = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 3,
        .input_channels = &.{},
        .output_channel = 2,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    };

    const optimized = try deadChannelElim(testing.allocator, &graph);
    defer testing.allocator.free(optimized.laminas);
    defer testing.allocator.free(optimized.channel_metas);
    defer testing.allocator.free(optimized.input_channels);

    // 应移除未使用的 constant(999) 层，保留 2 层
    try testing.expectEqual(@as(usize, 2), optimized.laminas.len);
}

test "层融合: a * 2 + 3 → scale_add" {
    const metas = [_]ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: a
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: const 2
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: a*2
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: const 3
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: a*2+3
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 2, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_mul, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
        .{ .op = .constant, .output = 3, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 2, 3, 0 }, .output = 4, .int_kind = .i64, .input_count = 2 },
    };
    const graph = LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 4,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    };

    const optimized = try layerFusion(testing.allocator, &graph);
    defer testing.allocator.free(optimized.laminas);
    defer testing.allocator.free(optimized.channel_metas);
    defer testing.allocator.free(optimized.input_channels);

    // 应有一个 int_scale_add 层
    var found_scale_add = false;
    for (optimized.laminas) |lam| {
        if (lam.op == .int_scale_add) {
            found_scale_add = true;
            try testing.expectEqual(@as(i64, 2), lam.const_val.?); // k
            try testing.expectEqual(@as(i64, 3), lam.const_val2.?); // c
        }
    }
    try testing.expect(found_scale_add);
}

test "通道活跃区间: 非重叠通道共享槽位" {
    // chan0 = constant(1)  [def=0, last_use=1]
    // chan1 = chan0 + 1    [def=1, last_use=2]
    // chan2 = constant(10) [def=2, last_use=3]  ← chan0 已死，可复用
    // chan3 = chan1 + chan2 [def=3, last_use=3]
    const metas = [_]ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 0, 0, 0 }, .output = 1, .int_kind = .i64, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 1, 2, 0 }, .output = 3, .int_kind = .i64, .input_count = 2 },
    };
    const graph = LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 4,
        .input_channels = &.{},
        .output_channel = 3,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    };

    const optimized = try channelLiveness(testing.allocator, &graph);
    defer if (optimized.arena == null) {
        testing.allocator.free(optimized.laminas);
        testing.allocator.free(optimized.channel_metas);
        if (optimized.input_channels.len > 0) testing.allocator.free(optimized.input_channels);
    };

    // 4 个逻辑通道应被压缩到 ≤ 3 个物理槽位
    try testing.expect(optimized.channel_count < 4);
}
