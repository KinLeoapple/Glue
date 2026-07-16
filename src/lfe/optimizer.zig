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
const ChannelScope = lamina_mod.ChannelScope;
const ParamBind = lamina_mod.ParamBind;
const TraitMethodEntry = lamina_mod.TraitMethodEntry;

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
/// 顺序遵循设计文档 7.6：
///   第一轮：太阳层优化（常量折叠 → 死通道消除 → 层融合）
///   第二轮：星轨层优化（静态提升 → 轨道合并 → 死轨道消除）
///   第三轮：联合优化（跨层通道活跃性 → 常量折叠）
pub fn optimize(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    // 第一轮：太阳层优化
    var g = try constantFold(allocator, graph);
    g = try deadChannelElim(allocator, &g);
    g = try layerFusion(allocator, &g);

    // 第二轮：星轨层优化
    g = try staticHoisting(allocator, &g);
    g = try orbitMerging(allocator, &g);
    g = try orbitDeadCode(allocator, &g);

    // 第三轮：联合优化
    g = try channelLiveness(allocator, &g);
    g = try constantFold(allocator, &g);
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
// Pass 4: 跨层通道活跃区间分析 + 物理槽位复用（D4）
// ══════════════════════════════════════════════════════

/// 跨层通道活跃区间分析：计算每个通道的 [定义点, 最后使用点]
/// 非重叠的通道共享物理槽位，减少总物理通道数。
///
/// 活跃区间计算策略（设计文档 7.5 + 风险点约束"只分析太阳层 + 当前轨道"）：
/// - solar 通道：基于太阳层 laminas 线性索引
/// - orbit/bridge 通道：映射到 OrbitHub 在太阳层的位置
///   - 非环形轨道：活跃区间 = [hub_pos, hub_pos]（点区间）
///   - 环形轨道/async 轨道：活跃区间 = [hub_pos, 太阳层末尾]（可能长时间执行）
pub fn channelLiveness(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.laminas.len == 0 or graph.channel_count == 0) {
        return cloneGraph(allocator, graph);
    }

    // 检测 stack_push/stack_pop：递归调用使用通道范围保存/恢复现场，
    // 槽位复用会破坏通道范围连续性，导致 stack_pop 越界。
    // 含递归调用的图跳过槽位复用，保证正确性。
    for (graph.laminas) |lam| {
        if (lam.op == .stack_push or lam.op == .stack_pop) {
            return cloneGraph(allocator, graph);
        }
    }
    for (graph.orbits) |orbit| {
        for (orbit.laminas) |lam| {
            if (lam.op == .stack_push or lam.op == .stack_pop) {
                return cloneGraph(allocator, graph);
            }
        }
    }

    const n_chans = graph.channel_count;
    const n_lams = graph.laminas.len;

    // ── 1. 构建 orbit → hub_positions 映射 ──
    //    记录每个轨道被激活的位置
    //    太阳层 orbit_hub lamina → 用太阳层 lamina 索引
    //    轨道内嵌套 orbit_hub lamina → 继承父轨道的 hub 位置
    var orbit_hub_positions = std.AutoHashMap(u16, struct { min: usize, max: usize, is_async: bool }).init(allocator);
    defer orbit_hub_positions.deinit();

    // 1a. 太阳层 orbit_hub laminas
    for (graph.laminas, 0..) |lam, i| {
        if (lam.op != .orbit_hub and lam.op != .orbit_hub_async) continue;
        const hi = lam.hub_index orelse continue;
        if (hi >= graph.orbit_hubs.len) continue;
        const hub = &graph.orbit_hubs[hi];
        const is_async = (hub.kind == .async_hub);
        for (hub.orbit_table) |entry| {
            const gop = try orbit_hub_positions.getOrPut(entry.orbit_index);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .min = i, .max = i, .is_async = is_async };
            } else {
                gop.value_ptr.min = @min(gop.value_ptr.min, i);
                gop.value_ptr.max = @max(gop.value_ptr.max, i);
                gop.value_ptr.is_async = gop.value_ptr.is_async or is_async;
            }
        }
    }

    // 1b. 轨道内嵌套 orbit_hub laminas（递归传播父轨道的 hub 位置）
    //     多轮传播直到不再变化（处理多层嵌套）
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.orbits, 0..) |orbit, orbit_idx| {
            // 父轨道必须已有 hub 位置
            const parent_pos = orbit_hub_positions.get(@intCast(orbit_idx)) orelse continue;
            for (orbit.laminas) |lam| {
                if (lam.op != .orbit_hub and lam.op != .orbit_hub_async) continue;
                const hi = lam.hub_index orelse continue;
                if (hi >= graph.orbit_hubs.len) continue;
                const hub = &graph.orbit_hubs[hi];
                const is_async = (hub.kind == .async_hub);
                for (hub.orbit_table) |entry| {
                    const gop = try orbit_hub_positions.getOrPut(entry.orbit_index);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .min = parent_pos.min, .max = parent_pos.max, .is_async = is_async or parent_pos.is_async };
                        changed = true;
                    } else {
                        const new_min = @min(gop.value_ptr.min, parent_pos.min);
                        const new_max = @max(gop.value_ptr.max, parent_pos.max);
                        const new_async = gop.value_ptr.is_async or is_async or parent_pos.is_async;
                        if (new_min != gop.value_ptr.min or new_max != gop.value_ptr.max or new_async != gop.value_ptr.is_async) {
                            gop.value_ptr.min = new_min;
                            gop.value_ptr.max = new_max;
                            gop.value_ptr.is_async = new_async;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    // ── 2. 计算每个通道的活跃区间 [first_def, last_use] ──
    const first_def = try allocator.alloc(usize, n_chans);
    defer allocator.free(first_def);
    @memset(first_def, std.math.maxInt(usize));

    const last_use = try allocator.alloc(usize, n_chans);
    defer allocator.free(last_use);
    @memset(last_use, 0);

    // 2a. 太阳层 laminas 的通道引用
    for (graph.laminas, 0..) |lam, i| {
        if (lam.output < n_chans and first_def[lam.output] == std.math.maxInt(usize)) {
            first_def[lam.output] = i;
        }
        for (lam.inputs[0..lam.input_count]) |in| {
            if (in < n_chans) last_use[in] = i;
        }
        if (lam.predicate) |p| {
            if (p < n_chans) last_use[p] = i;
        }
    }
    // 输出通道的最后使用 = 最后一个层
    if (graph.output_channel < n_chans) {
        last_use[graph.output_channel] = n_lams;
    }

    // 2b. OrbitHub 引用的太阳层通道（cond_channel, output_channel, param_mapping.src, orbit_table.cond_channel）
    for (graph.laminas, 0..) |lam, i| {
        if (lam.op != .orbit_hub and lam.op != .orbit_hub_async) continue;
        const hi = lam.hub_index orelse continue;
        if (hi >= graph.orbit_hubs.len) continue;
        const hub = &graph.orbit_hubs[hi];

        if (hub.cond_channel) |cc| {
            if (cc < n_chans) {
                first_def[cc] = @min(first_def[cc], i);
                last_use[cc] = @max(last_use[cc], i);
            }
        }
        if (hub.output_channel < n_chans) {
            first_def[hub.output_channel] = @min(first_def[hub.output_channel], i);
            last_use[hub.output_channel] = @max(last_use[hub.output_channel], i);
        }
        if (hub.continue_channel) |cc| {
            if (cc < n_chans) {
                first_def[cc] = @min(first_def[cc], i);
                last_use[cc] = @max(last_use[cc], i);
            }
        }
        for (hub.param_mapping) |pm| {
            if (pm.src < n_chans) {
                first_def[pm.src] = @min(first_def[pm.src], i);
                last_use[pm.src] = @max(last_use[pm.src], i);
            }
            // dst（bridge_in 通道）在 hub 位置被写入，标记活跃以防被误判为未定义通道
            if (pm.dst < n_chans) {
                first_def[pm.dst] = @min(first_def[pm.dst], i);
                last_use[pm.dst] = @max(last_use[pm.dst], i);
            }
        }
        for (hub.orbit_table) |entry| {
            if (entry.cond_channel) |cc| {
                if (cc < n_chans) {
                    first_def[cc] = @min(first_def[cc], i);
                    last_use[cc] = @max(last_use[cc], i);
                }
            }
        }
    }

    // 2c. 轨道内通道和 bridge 通道的活跃区间
    //     映射到 OrbitHub 在太阳层的位置
    for (graph.orbits, 0..) |orbit, orbit_idx| {
        const pos = orbit_hub_positions.get(@intCast(orbit_idx)) orelse continue;
        // 环形轨道和异步轨道的活跃区间扩展到太阳层末尾
        const effective_last = if (orbit.is_cyclic or pos.is_async) n_lams else pos.max;

        // 轨道内 laminas 的通道引用
        for (orbit.laminas) |lam| {
            if (lam.output < n_chans) {
                first_def[lam.output] = @min(first_def[lam.output], pos.min);
                last_use[lam.output] = @max(last_use[lam.output], effective_last);
            }
            for (lam.inputs[0..lam.input_count]) |in| {
                if (in < n_chans) {
                    first_def[in] = @min(first_def[in], pos.min);
                    last_use[in] = @max(last_use[in], effective_last);
                }
            }
            if (lam.predicate) |p| {
                if (p < n_chans) {
                    first_def[p] = @min(first_def[p], pos.min);
                    last_use[p] = @max(last_use[p], effective_last);
                }
            }
        }
        // 轨道元数据中的通道引用
        if (orbit.output_channel < n_chans) {
            first_def[orbit.output_channel] = @min(first_def[orbit.output_channel], pos.min);
            last_use[orbit.output_channel] = @max(last_use[orbit.output_channel], effective_last);
        }
        if (orbit.continue_channel) |cc| {
            if (cc < n_chans) {
                first_def[cc] = @min(first_def[cc], pos.min);
                last_use[cc] = @max(last_use[cc], effective_last);
            }
        }
        for (orbit.input_channels) |ic| {
            if (ic < n_chans) {
                first_def[ic] = @min(first_def[ic], pos.min);
                last_use[ic] = @max(last_use[ic], effective_last);
            }
        }
        for (orbit.capture_channels) |cc| {
            if (cc < n_chans) {
                first_def[cc] = @min(first_def[cc], pos.min);
                last_use[cc] = @max(last_use[cc], effective_last);
            }
        }

        // 2c-嵌套. 轨道内 OrbitHub 引用的通道（嵌套 hub 的 param_mapping/cond_channel/output_channel）
        for (orbit.laminas) |lam| {
            if (lam.op != .orbit_hub and lam.op != .orbit_hub_async) continue;
            const hi = lam.hub_index orelse continue;
            if (hi >= graph.orbit_hubs.len) continue;
            const nested_hub = &graph.orbit_hubs[hi];
            if (nested_hub.cond_channel) |cc| {
                if (cc < n_chans) {
                    first_def[cc] = @min(first_def[cc], pos.min);
                    last_use[cc] = @max(last_use[cc], effective_last);
                }
            }
            if (nested_hub.output_channel < n_chans) {
                first_def[nested_hub.output_channel] = @min(first_def[nested_hub.output_channel], pos.min);
                last_use[nested_hub.output_channel] = @max(last_use[nested_hub.output_channel], effective_last);
            }
            if (nested_hub.continue_channel) |cc| {
                if (cc < n_chans) {
                    first_def[cc] = @min(first_def[cc], pos.min);
                    last_use[cc] = @max(last_use[cc], effective_last);
                }
            }
            for (nested_hub.param_mapping) |pm| {
                if (pm.src < n_chans) {
                    first_def[pm.src] = @min(first_def[pm.src], pos.min);
                    last_use[pm.src] = @max(last_use[pm.src], effective_last);
                }
                if (pm.dst < n_chans) {
                    first_def[pm.dst] = @min(first_def[pm.dst], pos.min);
                    last_use[pm.dst] = @max(last_use[pm.dst], effective_last);
                }
            }
            for (nested_hub.orbit_table) |entry| {
                if (entry.cond_channel) |cc| {
                    if (cc < n_chans) {
                        first_def[cc] = @min(first_def[cc], pos.min);
                        last_use[cc] = @max(last_use[cc], effective_last);
                    }
                }
            }
        }
    }

    // 2d. TraitMethodEntry 引用的通道（轨道内通道，通过 orbit_index 找 hub 位置）
    for (graph.trait_method_table) |tme| {
        const pos = orbit_hub_positions.get(tme.orbit_index) orelse continue;
        for (tme.param_channels) |pc| {
            if (pc < n_chans) {
                first_def[pc] = @min(first_def[pc], pos.min);
                last_use[pc] = @max(last_use[pc], pos.max);
            }
        }
        if (tme.self_channel < n_chans) {
            first_def[tme.self_channel] = @min(first_def[tme.self_channel], pos.min);
            last_use[tme.self_channel] = @max(last_use[tme.self_channel], pos.max);
        }
        if (tme.output_channel < n_chans) {
            first_def[tme.output_channel] = @min(first_def[tme.output_channel], pos.min);
            last_use[tme.output_channel] = @max(last_use[tme.output_channel], pos.max);
        }
    }

    // ── 3. 贪心着色：为每个通道分配物理槽位 ──
    // 类型不同（如 i64_chan vs f64_chan）的通道不能共享槽位
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

    // ── 4. 重映射所有通道引用 ──

    // 4a. 太阳层 laminas
    var new_laminas = try allocator.alloc(Lamina, n_lams);
    for (graph.laminas, 0..) |lam, i| {
        new_laminas[i] = remapLamina(lam, slot_map);
    }

    // 4b. 通道元数据
    var new_metas = try allocator.alloc(ChannelMeta, physical_count);
    @memset(new_metas, .{ .chan_type = .null_chan, .elem_width = 0 });
    for (0..n_chans) |chan| {
        const meta = graph.channel_metas[chan];
        const slot = slot_map[chan];
        if (new_metas[slot].elem_width == 0) {
            new_metas[slot] = meta;
        } else if (meta.is_cell) {
            new_metas[slot].is_cell = true;
        }
    }

    // 4c. 通道 scope（重映射到新槽位）
    var new_scopes: []const ChannelScope = &.{};
    if (graph.channel_scopes.len > 0) {
        const scopes_copy = try allocator.alloc(ChannelScope, physical_count);
        @memset(scopes_copy, .solar);
        for (0..n_chans) |chan| {
            scopes_copy[slot_map[chan]] = graph.channel_scopes[chan];
        }
        new_scopes = scopes_copy;
    }

    // 4d. 轨道（重映射轨道内所有通道引用）
    var new_orbits: []const Orbit = &.{};
    if (graph.orbits.len > 0) {
        const orbits_copy = try allocator.alloc(Orbit, graph.orbits.len);
        for (graph.orbits, 0..) |orbit, i| {
            orbits_copy[i] = remapOrbit(allocator, orbit, slot_map) catch orbit;
        }
        new_orbits = orbits_copy;
    }

    // 4e. OrbitHub（重映射 cond_channel, output_channel, param_mapping, orbit_table）
    var new_hubs: []const OrbitHub = &.{};
    if (graph.orbit_hubs.len > 0) {
        const hubs_copy = try allocator.alloc(OrbitHub, graph.orbit_hubs.len);
        for (graph.orbit_hubs, 0..) |hub, i| {
            hubs_copy[i] = remapOrbitHub(allocator, hub, slot_map) catch hub;
        }
        new_hubs = hubs_copy;
    }

    // 4f. TraitMethodTable（重映射 param_channels, self_channel, output_channel）
    var new_trait_table: []const TraitMethodEntry = &.{};
    if (graph.trait_method_table.len > 0) {
        const trait_copy = try allocator.alloc(TraitMethodEntry, graph.trait_method_table.len);
        for (graph.trait_method_table, 0..) |tme, i| {
            trait_copy[i] = remapTraitMethod(allocator, tme, slot_map) catch tme;
        }
        new_trait_table = trait_copy;
    }

    const result = LaminarGraph{
        .laminas = new_laminas,
        .channel_metas = new_metas,
        .channel_count = physical_count,
        .input_channels = try remapChannels(allocator, graph.input_channels, slot_map),
        .output_channel = slot_map[graph.output_channel],
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = new_orbits,
        .orbit_hubs = new_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = new_scopes,
        .trait_method_table = new_trait_table,
        .arena = null,
    };
    return result;
}

/// 重映射单个 Lamina 中的所有通道索引
fn remapLamina(lam: Lamina, slot_map: []const u16) Lamina {
    var result = lam;
    if (lam.output < slot_map.len) result.output = slot_map[lam.output];
    var j: usize = 0;
    while (j < lam.input_count) : (j += 1) {
        if (lam.inputs[j] < slot_map.len) result.inputs[j] = slot_map[lam.inputs[j]];
    }
    if (lam.predicate) |p| {
        if (p < slot_map.len) result.predicate = slot_map[p];
    }
    // stack_push/stack_pop 的 const_val 存储参数通道起始索引，需随 slot_map 重映射
    if (lam.op == .stack_push or lam.op == .stack_pop) {
        if (lam.const_val) |cv| {
            const start: usize = @intCast(cv);
            if (start < slot_map.len) result.const_val = @intCast(slot_map[start]);
        }
    }
    return result;
}

/// 重映射 Orbit 中的所有通道引用
fn remapOrbit(allocator: std.mem.Allocator, orbit: Orbit, slot_map: []const u16) OptError!Orbit {
    var result = orbit;

    // 重映射 laminas
    const new_lams = try allocator.alloc(Lamina, orbit.laminas.len);
    for (orbit.laminas, 0..) |lam, i| {
        new_lams[i] = remapLamina(lam, slot_map);
    }
    result.laminas = new_lams;

    // 重映射 output_channel
    if (orbit.output_channel < slot_map.len) result.output_channel = slot_map[orbit.output_channel];

    // 重映射 continue_channel
    if (orbit.continue_channel) |cc| {
        if (cc < slot_map.len) result.continue_channel = slot_map[cc];
    }

    // 重映射 input_channels
    if (orbit.input_channels.len > 0) {
        result.input_channels = try remapChannels(allocator, orbit.input_channels, slot_map);
    }

    // 重映射 capture_channels
    if (orbit.capture_channels.len > 0) {
        result.capture_channels = try remapChannels(allocator, orbit.capture_channels, slot_map);
    }

    return result;
}

/// 重映射 OrbitHub 中的所有通道引用
fn remapOrbitHub(allocator: std.mem.Allocator, hub: OrbitHub, slot_map: []const u16) OptError!OrbitHub {
    var result = hub;

    if (hub.cond_channel) |cc| {
        if (cc < slot_map.len) result.cond_channel = slot_map[cc];
    }
    if (hub.output_channel < slot_map.len) result.output_channel = slot_map[hub.output_channel];
    if (hub.continue_channel) |cc| {
        if (cc < slot_map.len) result.continue_channel = slot_map[cc];
    }

    // 重映射 param_mapping
    if (hub.param_mapping.len > 0) {
        const new_pm = try allocator.alloc(ParamBind, hub.param_mapping.len);
        for (hub.param_mapping, 0..) |pm, i| {
            new_pm[i] = .{
                .src = if (pm.src < slot_map.len) slot_map[pm.src] else pm.src,
                .dst = if (pm.dst < slot_map.len) slot_map[pm.dst] else pm.dst,
            };
        }
        result.param_mapping = new_pm;
    }

    // 重映射 orbit_table 中的 cond_channel
    if (hub.orbit_table.len > 0) {
        const new_table = try allocator.alloc(OrbitEntry, hub.orbit_table.len);
        for (hub.orbit_table, 0..) |entry, i| {
            new_table[i] = entry;
            if (entry.cond_channel) |cc| {
                if (cc < slot_map.len) new_table[i].cond_channel = slot_map[cc];
            }
        }
        result.orbit_table = new_table;
    }

    return result;
}

/// 重映射 TraitMethodEntry 中的所有通道引用
fn remapTraitMethod(allocator: std.mem.Allocator, tme: TraitMethodEntry, slot_map: []const u16) OptError!TraitMethodEntry {
    var result = tme;

    if (tme.self_channel < slot_map.len) result.self_channel = slot_map[tme.self_channel];
    if (tme.output_channel < slot_map.len) result.output_channel = slot_map[tme.output_channel];

    if (tme.param_channels.len > 0) {
        result.param_channels = try remapChannels(allocator, tme.param_channels, slot_map);
    }

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

/// 静态提升：将轨道内静态代码提升到太阳层
///
/// 提升条件（全部满足）：
/// 1. 无谓词门控（predicate == null）
/// 2. 无副作用（不含 halt/orbit_hub/defer/stack 等）
/// 3. 非 .move（move 是轨道出口回写，必须留在轨道内）
/// 4. 环形轨道：仅提升 .constant（保证循环不变性）
/// 5. 非环形轨道：所有输入通道均为太阳层通道（scope == .solar 或 .bridge_out）
///
/// 提升的 lamina 插入太阳层中第一个 orbit_hub 之前（确保输入通道已定义）
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
            if (isHoistable(lam, orbit, graph)) {
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

    // 找到太阳层中第一个 orbit_hub 的位置，将提升的 laminas 插入其前
    var insert_pos: usize = graph.laminas.len;
    for (graph.laminas, 0..) |lam, i| {
        if (lam.op == .orbit_hub or lam.op == .orbit_hub_async) {
            insert_pos = i;
            break;
        }
    }

    var new_solar = std.ArrayList(Lamina).empty;
    defer new_solar.deinit(allocator);
    try new_solar.appendSlice(allocator, graph.laminas[0..insert_pos]);
    try new_solar.appendSlice(allocator, hoisted_laminas.items);
    try new_solar.appendSlice(allocator, graph.laminas[insert_pos..]);

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

/// 判断轨道内 lamina 是否可提升到太阳层
fn isHoistable(lam: Lamina, orbit: Orbit, graph: *const LaminarGraph) bool {
    // 1. 必须无谓词门控
    if (lam.predicate != null) return false;
    // 2. 必须无副作用
    if (hasSideEffect(lam.op)) return false;
    // 3. 不能是控制流出口
    switch (lam.op) {
        .halt_return, .halt_throw, .halt_break, .halt_continue => return false,
        .orbit_hub, .orbit_hub_async, .orbit_join => return false,
        .defer_register, .defer_execute => return false,
        .stack_push, .stack_pop, .stack_peek, .stack_depth => return false,
        .move => return false, // move 是轨道出口回写，必须留在轨道内
        else => {},
    }
    // 4. 环形轨道：仅提升 constant（保证循环不变性）
    if (orbit.is_cyclic) {
        return lam.op == .constant;
    }
    // 5. 非环形轨道：所有输入通道必须是太阳层通道
    for (lam.inputs[0..lam.input_count]) |in| {
        if (in < graph.channel_scopes.len) {
            const scope = graph.channel_scopes[in];
            if (scope == .bridge_in or scope == .orbit) return false;
        }
    }
    return true;
}

// ══════════════════════════════════════════════════════
// Pass 7: 极简轨道合并（orbitMerging）
// ══════════════════════════════════════════════════════

/// 极简轨道合并：将结构相同、仅常量不同的极简轨道（≤4轨道、每条≤3 lamina、
/// 无副作用、无嵌套）合并为 select 层，避免轨道激活开销
///
/// 合并策略：
/// - 2 轨道（if-else 模式）：select(cond, r0, r1)
/// - 3-4 轨道（match 模式）：constant(expected) + int_eq + 嵌套 select
pub fn orbitMerging(allocator: std.mem.Allocator, graph: *const LaminarGraph) OptError!LaminarGraph {
    if (graph.orbit_hubs.len == 0) return cloneGraph(allocator, graph);

    var solar_changed = false;
    var new_solar = std.ArrayList(Lamina).empty;
    defer new_solar.deinit(allocator);
    var used_orbit = try allocator.alloc(bool, graph.orbits.len);
    defer allocator.free(used_orbit);
    @memset(used_orbit, false);

    // 合并过程中可能需要分配新通道（比较常量、mask、中间 select 结果）
    var new_metas = std.ArrayList(ChannelMeta).empty;
    defer new_metas.deinit(allocator);
    var next_chan: u16 = graph.channel_count;

    for (graph.laminas) |lam| {
        if (lam.op == .orbit_hub) {
            const hub_idx = lam.hub_index orelse {
                try new_solar.append(allocator, lam);
                continue;
            };
            const hub = graph.orbit_hubs[hub_idx];

            if (try tryMergeHub(allocator, hub, graph.orbits, graph, &new_metas, &next_chan)) |merge_result| {
                solar_changed = true;
                for (hub.orbit_table) |entry| {
                    if (entry.orbit_index < used_orbit.len) used_orbit[entry.orbit_index] = true;
                }
                try new_solar.appendSlice(allocator, merge_result);
                continue;
            }
        }
        try new_solar.append(allocator, lam);
    }

    if (!solar_changed) return cloneGraph(allocator, graph);

    // 合并 channel_metas 和 channel_scopes（新通道标记为 solar）
    const final_chan_count = next_chan;
    const metas_copy = try allocator.alloc(ChannelMeta, final_chan_count);
    @memcpy(metas_copy[0..graph.channel_metas.len], graph.channel_metas);
    for (new_metas.items, 0..) |m, i| {
        metas_copy[graph.channel_metas.len + i] = m;
    }

    const scopes_copy = try allocator.alloc(lamina_mod.ChannelScope, final_chan_count);
    if (graph.channel_scopes.len > 0) {
        @memcpy(scopes_copy[0..graph.channel_scopes.len], graph.channel_scopes);
    }
    for (graph.channel_scopes.len..final_chan_count) |i| {
        scopes_copy[i] = .solar;
    }

    const inputs_copy = try allocator.dupe(u16, graph.input_channels);
    return .{
        .laminas = try allocator.dupe(Lamina, new_solar.items),
        .channel_metas = metas_copy,
        .channel_count = final_chan_count,
        .input_channels = inputs_copy,
        .output_channel = graph.output_channel,
        .string_table = graph.string_table,
        .name_table = graph.name_table,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = scopes_copy,
        .arena = null,
    };
}

const MergeResult = []const Lamina;

/// 分配新通道（合并过程中用于比较常量、mask 等）
fn allocMergeChan(
    new_metas: *std.ArrayList(ChannelMeta),
    next_chan: *u16,
    allocator: std.mem.Allocator,
    chan_type: ScalarChanType,
) !u16 {
    const idx = next_chan.*;
    next_chan.* += 1;
    try new_metas.append(allocator, .{
        .chan_type = chan_type,
        .elem_width = lamina_mod.chanElemWidth(chan_type),
    });
    return idx;
}

fn tryMergeHub(
    allocator: std.mem.Allocator,
    hub: OrbitHub,
    orbits: []const Orbit,
    graph: *const LaminarGraph,
    new_metas: *std.ArrayList(ChannelMeta),
    next_chan: *u16,
) OptError!?MergeResult {
    const table = hub.orbit_table;
    if (table.len < 2 or table.len > 4) return null;
    if (hub.is_cyclic) return null;

    const cond_chan = hub.cond_channel orelse return null;
    const out_chan = hub.output_channel;
    const n = table.len;

    // 验证所有轨道结构一致：[constant, move?] 或 [constant]
    const first_lams = orbits[table[0].orbit_index].laminas;
    if (first_lams.len < 1 or first_lams.len > 3) return null;
    if (first_lams[0].op != .constant) return null;
    if (first_lams[0].predicate != null) return null;

    // 检查所有轨道结构一致 + 无副作用 + 无谓词
    for (table[1..]) |entry| {
        const olams = orbits[entry.orbit_index].laminas;
        if (olams.len != first_lams.len) return null;
        for (olams, first_lams) |olam, flam| {
            if (olam.op != flam.op) return null;
            if (olam.input_count != flam.input_count) return null;
            if (olam.predicate != null) return null;
            if (hasSideEffect(olam.op)) return null;
        }
    }

    // 提取每个轨道的结果通道（move 的 input[0]，或最后一个 lamina 的 output）
    const n_orbits = n;
    var result_chans = try allocator.alloc(u16, n_orbits);
    defer allocator.free(result_chans);
    for (table, 0..) |entry, i| {
        const olams = orbits[entry.orbit_index].laminas;
        if (olams.len > 0 and olams[olams.len - 1].op == .move) {
            result_chans[i] = olams[olams.len - 1].inputs[0];
        } else if (olams.len > 0) {
            result_chans[i] = olams[olams.len - 1].output;
        } else {
            return null;
        }
    }

    var result = std.ArrayList(Lamina).empty;
    errdefer result.deinit(allocator);

    // 发射所有轨道的非 move laminas 到太阳层（保留各自的 const_val）
    for (table) |entry| {
        const olams = orbits[entry.orbit_index].laminas;
        for (olams) |olam| {
            if (olam.op != .move) {
                try result.append(allocator, olam);
            }
        }
    }

    // 结果值类型（从第一个轨道的 constant 推断）
    const result_type = graph.channel_metas[first_lams[0].output].chan_type;

    if (n == 2) {
        // 2 轨道：直接 select(cond, r0, r1)
        try result.append(allocator, .{
            .op = .select,
            .inputs = .{ cond_chan, result_chans[0], result_chans[1] },
            .output = out_chan,
            .input_count = 3,
        });
    } else {
        // 3-4 轨道：比较常量 + int_eq + 嵌套 select
        const cond_meta = graph.channel_metas[cond_chan];
        const cond_int_kind = lamina_mod.intKindFromChanType(cond_meta.chan_type);
        const cond_chan_type = cond_meta.chan_type;

        // 为前 n-1 个 arm 生成 constant(expected) + int_eq(cond, expected) → mask
        var mask_chans = try allocator.alloc(u16, n - 1);
        defer allocator.free(mask_chans);

        for (table[0 .. n - 1], 0..) |entry, i| {
            const exp_chan = try allocMergeChan(new_metas, next_chan, allocator, cond_chan_type);
            try result.append(allocator, .{
                .op = .constant,
                .const_val = entry.expected_val,
                .output = exp_chan,
                .int_kind = cond_int_kind,
                .input_count = 0,
            });
            const mask_chan = try allocMergeChan(new_metas, next_chan, allocator, .mask_chan);
            try result.append(allocator, .{
                .op = .int_eq,
                .inputs = .{ cond_chan, exp_chan, 0 },
                .output = mask_chan,
                .int_kind = cond_int_kind,
                .input_count = 2,
            });
            mask_chans[i] = mask_chan;
        }

        // 嵌套 select：select(mask[0], r0, select(mask[1], r1, ... select(mask[n-2], r[n-2], r[n-1])))
        var current_chan = result_chans[n - 1];
        var i: usize = n - 1;
        while (i > 1) : (i -= 1) {
            const tmp_chan = try allocMergeChan(new_metas, next_chan, allocator, result_type);
            try result.append(allocator, .{
                .op = .select,
                .inputs = .{ mask_chans[i - 1], result_chans[i - 1], current_chan },
                .output = tmp_chan,
                .input_count = 3,
            });
            current_chan = tmp_chan;
        }
        // 最外层 select → out_chan
        try result.append(allocator, .{
            .op = .select,
            .inputs = .{ mask_chans[0], result_chans[0], current_chan },
            .output = out_chan,
            .input_count = 3,
        });
    }

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
        .subgraphs = graph.subgraphs,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .trait_method_table = graph.trait_method_table,
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
        .subgraphs = graph.subgraphs,
        .orbits = graph.orbits,
        .orbit_hubs = graph.orbit_hubs,
        .defer_entries = graph.defer_entries,
        .channel_scopes = graph.channel_scopes,
        .trait_method_table = graph.trait_method_table,
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

test "跨层活跃性: 含轨道的图通道复用" {
    // 太阳层:
    //   lam0: constant(1) → chan0  [def=0, last_use=1]
    //   lam1: int_add(chan0, chan0) → chan1  [def=1, last_use=2]  (chan0 死于此后)
    //   lam2: orbit_hub(hub=0) → chan2  [hub_pos=2, 激活 orbit 0]
    //   lam3: halt_return(chan2) → chan3  [def=3, last_use=3]
    // 轨道 0:
    //   lam0: move(chan4) → chan5  (bridge_in → bridge_out)
    // OrbitHub 0:
    //   cond_channel=chan1, output=chan2, param_mapping=[{src=chan1, dst=chan4}]
    //
    // 活跃区间:
    //   chan0 [0,1]  ← 可与 chan2/chan3/chan4/chan5 复用
    //   chan1 [0,2]  ← 被 hub 引用
    //   chan2 [2,3]
    //   chan3 [3,3]
    //   chan4 [2,2]  ← bridge_in, hub_pos=2
    //   chan5 [2,2]  ← bridge_out, hub_pos=2
    // 6 个逻辑通道应压缩到 < 6 个物理槽位

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const metas = [_]ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan0 solar
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan1 solar
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan2 solar
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan3 solar
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan4 bridge_in
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // chan5 bridge_out
    };
    const scopes = [_]ChannelScope{
        .solar, .solar, .solar, .solar, .bridge_in, .bridge_out,
    };

    const solar_lams = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 0, 0, 0 }, .output = 1, .int_kind = .i64, .input_count = 1 },
        .{ .op = .orbit_hub, .hub_index = 0, .output = 2, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 3, .input_count = 1 },
    };
    const orbit_lams = [_]Lamina{
        .{ .op = .move, .inputs = .{ 4, 0, 0 }, .output = 5, .input_count = 1 },
    };

    const orbit_table = [_]OrbitEntry{
        .{ .cond_channel = 1, .cond_kind = .eq, .expected_val = 1, .orbit_index = 0 },
    };
    const param_mapping = [_]ParamBind{
        .{ .src = 1, .dst = 4 },
    };
    const hubs = [_]OrbitHub{
        .{ .kind = .if_hub, .cond_channel = 1, .orbit_table = &orbit_table, .output_channel = 2, .param_mapping = &param_mapping },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_lams, .output_channel = 5 },
    };

    const graph = LaminarGraph{
        .laminas = &solar_lams,
        .channel_metas = &metas,
        .channel_count = 6,
        .input_channels = &.{},
        .output_channel = 3,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &hubs,
        .channel_scopes = &scopes,
        .arena = null,
    };

    const optimized = try channelLiveness(a, &graph);
    // arena.deinit() 释放所有分配，无需手动 free

    // 6 个逻辑通道应被压缩到 < 6 个物理槽位
    try testing.expect(optimized.channel_count < 6);
    // 验证重映射后轨道和 hub 数据完整
    try testing.expect(optimized.orbits.len == 1);
    try testing.expect(optimized.orbit_hubs.len == 1);
}
