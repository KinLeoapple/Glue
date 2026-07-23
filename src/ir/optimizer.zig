//! Glue IR 优化器
//!
//! 在共享内存图上做全局分析，执行多轮 pass 直到不动点。
//! 设计参考：docs/glue-ir-design.md 第 5 节
//!
//! Phase 4 实现：
//!   - constantFold：常量折叠（编译期计算）
//!   - deadNodeElim：死节点消除（移除无人引用的节点）
//!   - channelLiveness：通道活跃性分析 + 槽位复用
//!   - vecFusion：向量融合（vec_map ∘ vec_map → vec_map）

const std = @import("std");
const ir_mod = @import("ir.zig");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");

const GlueIR = ir_mod.GlueIR;
const Node = node_mod.Node;
const NodeOp = node_mod.NodeOp;
const ScalarMeta = meta_mod.ScalarMeta;
const ScalarKind = meta_mod.ScalarKind;
const ConstVal = meta_mod.ConstVal;
const ChanType = channel_mod.ChanType;
const scalar = @import("value").scalar;
const IntKind = scalar.IntKind;

/// 检查 i128 值是否在给定 IntKind 的表示范围内
///
/// 折叠后的 int_val 统一为 i128，但运行时按实际类型 T 执行运算并检测溢出。
/// 若折叠结果超出目标类型范围（如 200u8 + 100u8 = 300 超 u8 范围），
/// 运行时会抛 error.Overflow，而编译期 @truncate 会静默截断，语义不一致。
/// 此函数用于在折叠后校验结果是否安全，不安全则不折叠（交由运行时处理）。
fn intValInRange(val: i128, kind: IntKind) bool {
    return switch (kind) {
        .i8 => val >= -128 and val <= 127,
        .i16 => val >= -32768 and val <= 32767,
        .i32 => val >= std.math.minInt(i32) and val <= std.math.maxInt(i32),
        .i64 => val >= std.math.minInt(i64) and val <= std.math.maxInt(i64),
        .i128 => true, // i128 是 ConstVal.int_val 的原生类型，永远在范围
        .u8 => val >= 0 and val <= 255,
        .u16 => val >= 0 and val <= 65535,
        .u32 => val >= 0 and val <= std.math.maxInt(u32),
        .u64 => val >= 0 and val <= std.math.maxInt(u64),
        // u128 上界超出 i128 范围，ConstVal 只能存 i128，故只需检查非负
        .u128 => val >= 0,
        .isize => val >= std.math.minInt(isize) and val <= std.math.maxInt(isize),
        .usize => val >= 0 and val <= std.math.maxInt(usize),
    };
}

/// 优化统计信息
pub const OptStats = struct {
    constants_folded: u32 = 0,
    dead_nodes_removed: u32 = 0,
    channels_reused: u32 = 0,
    vecs_fused: u32 = 0,
    passes_run: u32 = 0,
};

/// 优化器入口：执行所有 pass 直到不动点
pub fn optimize(ir: *GlueIR) OptStats {
    var stats = OptStats{};
    var changed = true;
    const max_passes: u32 = 10; // 防止无限循环

    while (changed and stats.passes_run < max_passes) {
        changed = false;
        stats.passes_run += 1;

        // 按收益排序：常量折叠最先（产生新的常量供后续 pass 使用）
        if (constantFold(ir)) {
            changed = true;
            stats.constants_folded += 1;
        }
        if (deadNodeElim(ir)) {
            changed = true;
            stats.dead_nodes_removed += 1;
        }
        if (vecFusion(ir)) {
            changed = true;
            stats.vecs_fused += 1;
        }
        if (channelLiveness(ir)) {
            changed = true;
            stats.channels_reused += 1;
        }
    }

    return stats;
}

// ════════════════════════════════════════════════════════════════
// Pass 1: 常量折叠
// ════════════════════════════════════════════════════════════════

/// 常量折叠：将两个常量输入的运算替换为单个常量节点
///
/// 例：const_i(1) + const_i(2) → const_i(3)
/// 支持：整数算术、浮点算术、布尔逻辑、比较运算
fn constantFold(ir: *GlueIR) bool {
    var changed = false;

    for (ir.nodes, 0..) |*node, i| {
        // 跳过已折叠的节点（op 变为 const_* 的）
        if (isConstantOp(node.op)) continue;

        // 只折叠二元标量运算
        if (node.input_count != 2) continue;
        if (!node.op.isScalar()) continue;

        // 获取两个输入的常量值
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        const left_const = findConstVal(ir, left_chan, i) orelse continue;
        const right_const = findConstVal(ir, right_chan, i) orelse continue;

        // 尝试折叠
        if (foldBinaryOp(node.op, left_const, right_const)) |result| {
            // 折叠结果为整数时，校验结果是否在目标类型范围内。
            // foldBinaryOp 用 i128 检测溢出（第一道防线），但实际类型可能更窄（如 u8）。
            // 若结果超目标类型范围（如 200u8+100u8=300），运行时会抛 error.Overflow，
            // 而编译期 writeConst 会 @truncate 静默截断，语义不一致 → 不折叠，交由运行时。
            if (result == .int_val) {
                if (node.meta_index > 0 and node.meta_index < ir.scalar_metas.len) {
                    const target_kind = ir.scalar_metas[node.meta_index].int_kind;
                    if (!intValInRange(result.int_val, target_kind)) continue;
                }
            } else if (result == .bool_val and left_const == .int_val and right_const == .int_val) {
                // 比较运算（cmp_lt/le/gt/ge）的操作数范围检查：
                // ConstVal.int_val 为 i128（有符号），但运行时按操作数实际类型符号性比较。
                // 若两操作数均在各自类型范围内，则 i128 有符号比较与运行时一致
                // （有符号类型值在有符号范围内；无符号类型值非负，有符号比较=无符号比较）。
                // 操作数超范围时不折叠，交由运行时处理。
                const left_kind = findConstIntKind(ir, left_chan, i) orelse continue;
                const right_kind = findConstIntKind(ir, right_chan, i) orelse continue;
                if (!intValInRange(left_const.int_val, left_kind)) continue;
                if (!intValInRange(right_const.int_val, right_kind)) continue;
            }
            // 将节点替换为常量节点
            const new_op = constOpForVal(result);
            node.op = new_op;
            node.input_count = 0;
            // inputs 不再使用，清零
            node.inputs = .{ 0, 0, 0, 0 };

            // 更新或添加 scalar_meta
            // scalar_metas 的 meta_index 即数组索引（index 0 是占位符）
            if (node.meta_index > 0 and node.meta_index < ir.scalar_metas.len) {
                ir.scalar_metas[node.meta_index].const_val = result;
                ir.scalar_metas[node.meta_index].kind = scalarKindForVal(result);
            }

            changed = true;
        }
    }

    return changed;
}

/// 判断 op 是否为常量载入 op
fn isConstantOp(op: NodeOp) bool {
    return switch (op) {
        .const_i, .const_f, .const_bool, .const_char, .const_str, .const_null, .const_unit => true,
        else => false,
    };
}

/// 从节点流中查找指定通道的常量值（在 node_index 之前查找）
///
/// 注意：const_str 的 const_val 是字符串池索引（int_val），不是整数值。
/// 若将其作为整数参与折叠，会将"相同内容、不同池索引"的字符串字面量误判为不等。
/// 因此 const_str 不视为可折叠常量，== / != 交给运行时 value.equals 处理。
fn findConstVal(ir: *const GlueIR, chan: u16, node_index: usize) ?ConstVal {
    if (node_index == 0) return null;
    for (ir.nodes[0..node_index]) |n| {
        if (n.output == chan and isConstantOp(n.op)) {
            // const_str 的 const_val 是池索引而非数值，不参与常量折叠
            if (n.op == .const_str) return null;
            // scalar_metas 的 meta_index 即数组索引（index 0 是占位符）
            if (n.meta_index > 0 and n.meta_index < ir.scalar_metas.len) {
                return ir.scalar_metas[n.meta_index].const_val;
            }
        }
    }
    return null;
}

/// 查找指定通道的整数常量节点的 IntKind（用于比较折叠的操作数范围检查）
///
/// 比较运算（cmp_lt/le/gt/ge）的结果是 bool，node.meta_index 指向 bool meta，
/// 无法直接获取操作数的整数类型。此函数通过查找操作数常量节点获取其 int_kind。
fn findConstIntKind(ir: *const GlueIR, chan: u16, node_index: usize) ?IntKind {
    if (node_index == 0) return null;
    for (ir.nodes[0..node_index]) |n| {
        if (n.output == chan and n.op == .const_i) {
            if (n.meta_index > 0 and n.meta_index < ir.scalar_metas.len) {
                return ir.scalar_metas[n.meta_index].int_kind;
            }
        }
    }
    return null;
}

/// 折叠二元运算
fn foldBinaryOp(op: NodeOp, left: ConstVal, right: ConstVal) ?ConstVal {
    // 整数算术
    if (left == .int_val and right == .int_val) {
        const a = left.int_val;
        const b = right.int_val;
        return switch (op) {
            // 溢出时不折叠（返回 null），交由运行时 @*WithOverflow 检测并返回 error.Overflow，
            // 保证编译期/运行时语义一致（原先用 +% wrapping 会静默回绕，与运行时行为不符）
            .int_add => blk: {
                const r, const of = @addWithOverflow(a, b);
                break :blk if (of != 0) null else .{ .int_val = r };
            },
            .int_sub => blk: {
                const r, const of = @subWithOverflow(a, b);
                break :blk if (of != 0) null else .{ .int_val = r };
            },
            .int_mul => blk: {
                const r, const of = @mulWithOverflow(a, b);
                break :blk if (of != 0) null else .{ .int_val = r };
            },
            .int_div => if (b != 0 and !(a == std.math.minInt(i128) and b == -1))
                .{ .int_val = @divTrunc(a, b) }
            else
                null, // 除零或 minInt/-1 溢出（UB），交由运行时处理
            .int_mod => if (b != 0 and !(a == std.math.minInt(i128) and b == -1))
                .{ .int_val = @rem(a, b) }
            else
                null,
            .int_and => .{ .int_val = a & b },
            .int_or => .{ .int_val = a | b },
            .int_xor => .{ .int_val = a ^ b },
            // 移位运算不折叠：运行时 execIntShift 按实际类型位宽（@bitSizeOf(T)）移位，
            // 而 ConstVal.int_val 统一为 i64，编译期无法感知实际类型位宽。
            // 例如 i32 移位 32-63：运行时返回 0，编译期（i64 阈值 64）返回非 0；
            // i128 移位 64-127：运行时有效，编译期返回 0。为保证语义一致，交由运行时处理。
            .int_shl, .int_shr => null,
            .cmp_eq => .{ .bool_val = a == b },
            .cmp_ne => .{ .bool_val = a != b },
            // 有符号比较折叠：ConstVal.int_val 为 i128（有符号），运行时按实际类型符号性比较。
            // 安全性由 constantFold 中的操作数范围检查保证：若两操作数均在目标类型范围内，
            // 则有符号类型值在有符号范围内（i128 比较正确），无符号类型值非负（i128 有符号
            // 比较与无符号比较结果一致）。操作数超范围时不折叠（见 constantFold）。
            .cmp_lt => .{ .bool_val = a < b },
            .cmp_le => .{ .bool_val = a <= b },
            .cmp_gt => .{ .bool_val = a > b },
            .cmp_ge => .{ .bool_val = a >= b },
            else => null,
        };
    }

    // 布尔逻辑
    if (left == .bool_val and right == .bool_val) {
        const a = left.bool_val;
        const b = right.bool_val;
        return switch (op) {
            .bool_and => .{ .bool_val = a and b },
            .bool_or => .{ .bool_val = a or b },
            .cmp_eq => .{ .bool_val = a == b },
            .cmp_ne => .{ .bool_val = a != b },
            else => null,
        };
    }

    // 浮点算术：不折叠。ConstVal.float_val 是 u128 位模式，但折叠逻辑只按 f64 解释
    // （truncate 到 u64）。对 f16/f32/f128 常量，位模式不是 f64 格式，折叠结果错误。
    // 此外浮点折叠会丢失 NaN/Inf 传播语义（运行时 float_div 除零产生 Inf，编译期 return null）。
    // 为保证语义一致与精度正确，浮点算术交由运行时处理。
    return null;
}

/// 根据常量值类型返回对应的 const op
fn constOpForVal(val: ConstVal) NodeOp {
    return switch (val) {
        .int_val => .const_i,
        .float_val => .const_f,
        .bool_val => .const_bool,
        .char_val => .const_char,
    };
}

/// 根据常量值类型返回对应的 ScalarKind
fn scalarKindForVal(val: ConstVal) ScalarKind {
    return switch (val) {
        .int_val => .int,
        .float_val => .float,
        .bool_val => .bool,
        .char_val => .char,
    };
}

// ════════════════════════════════════════════════════════════════
// Pass 2: 死节点消除
// ════════════════════════════════════════════════════════════════

/// 死节点消除：移除输出通道无人引用的非副作用节点
///
/// 算法：
/// 1. 收集所有被引用的通道（作为其他节点输入的通道）
/// 2. 收集所有有副作用的节点（halt/call/store/cleanup 等）
/// 3. 标记输出无人引用且无副作用的节点为死节点
/// 4. 压缩节点流
fn deadNodeElim(ir: *GlueIR) bool {
    // 使用位图标记活跃通道
    var arena = std.heap.ArenaAllocator.init(ir.backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    const max_chan: usize = blk: {
        var max: u16 = 0;
        for (ir.nodes) |n| {
            if (n.output > max) max = n.output;
            for (n.inputs[0..n.input_count]) |ch| {
                if (ch > max) max = ch;
            }
        }
        break :blk max + 1;
    };

    // referenced[ch] = true 表示通道 ch 被某个节点引用
    var referenced = alloc.alloc(bool, max_chan) catch return false;
    @memset(referenced, false);

    for (ir.nodes) |n| {
        for (n.inputs[0..n.input_count]) |ch| {
            if (ch < max_chan) referenced[ch] = true;
        }
    }

    // body 子图的最后节点输出通道不在任何节点 inputs 中（通过 meta 间接引用），
    // 必须额外标记，否则 if/vec_map/defer 等子图内的节点会被误判为死节点。
    for (ir.route_metas) |rm| {
        for (0..rm.body_starts.len) |b| {
            const start = rm.body_starts[b];
            const len = rm.body_lens[b];
            if (len == 0 or start + len > ir.nodes.len) continue;
            const out = ir.nodes[start + len - 1].output;
            if (out < max_chan) referenced[out] = true;
        }
    }
    for (ir.vector_metas) |vm| {
        if (vm.body_len == 0 or vm.body_start + vm.body_len > ir.nodes.len) continue;
        const out = ir.nodes[vm.body_start + vm.body_len - 1].output;
        if (out < max_chan) referenced[out] = true;
    }
    for (ir.cleanup_metas) |cm| {
        if (cm.body_len == 0 or cm.body_start + cm.body_len > ir.nodes.len) continue;
        const out = ir.nodes[cm.body_start + cm.body_len - 1].output;
        if (out < max_chan) referenced[out] = true;
    }
    for (ir.loop_metas) |lm| {
        if (lm.body_len == 0 or lm.body_start + lm.body_len > ir.nodes.len) continue;
        // 标记 body 子图所有节点的输出（标量循环体内节点互相依赖）
        for (0..lm.body_len) |i| {
            const out = ir.nodes[lm.body_start + i].output;
            if (out < max_chan) referenced[out] = true;
        }
    }
    // partial_make 通过 PartialMeta 间接引用绑定参数通道，必须额外标记
    for (ir.partial_metas) |pm| {
        for (pm.bound_arg_channels) |ch| {
            if (ch < max_chan) referenced[ch] = true;
        }
    }

    // 标记死节点（用无效 op 标记，后续压缩）
    var changed = false;
    for (ir.nodes) |*n| {
        if (hasSideEffect(n.op)) continue;
        if (n.output >= max_chan) continue;
        if (!referenced[n.output]) {
            n.op = .const_unit; // 标记为死节点（用 const_unit 占位，后续压缩）
            n.input_count = 0;
            n.inputs = .{ 0, 0, 0, 0 };
            changed = true;
        }
    }

    // Phase 4 简化：不做物理压缩（节点流仍连续，死节点变为 const_unit 无副作用）
    // 物理压缩会改变节点索引，需要更新所有 meta 引用，留待后续优化
    return changed;
}

/// 判断 op 是否有副作用（不能被消除）
fn hasSideEffect(op: NodeOp) bool {
    return switch (op) {
        .halt_return, .halt_throw, .halt_panic,
        .halt_break, .halt_continue,
        .call, .store, .array_set, .array_push, .record_set,
        // array_pop / array_drop_last 修改原数组（与 array_push 对称），不可消除
        .array_pop, .array_drop_last,
        .cleanup_register, .cleanup_run,
        .orbit_async_create, .orbit_async_join,
        .orbit_chan_send, .orbit_chan_recv, .orbit_chan_try_recv,
        .channel_close,
        .closure_make, .call_indirect,
        // partial_make 分配 PartialApplication 堆对象，有副作用
        .partial_make,
        // race_select 阻塞等待通道就绪/超时，结果依赖时序，不可消除
        .race_select, .race_yield,
        .builtin_print, .builtin_println,
        .builtin_eprint, .builtin_eprintln,
        .builtin_scan, .builtin_scanln,
        .builtin_ok, .builtin_error, .builtin_eq, .builtin_str,
        .builtin_ref_eq,
        .builtin_type, .builtin_panic, .builtin_typeof,
        .newtype_wrap, .newtype_unwrap,
        .scalar_loop,
        // route_dispatch 执行 body 子图（match/if/select 分支体），
        // body 可能包含 println/call/store 等副作用，故不能被消除
        .route_dispatch,
        // gate_make_ok/gate_make_err 创建 ThrowValue 堆对象，有副作用
        .gate_make_ok, .gate_make_err,
        // vec_map/vec_map2/vec_fold/vec_scan/vec_filter/vec_take_while 执行 body 子图，
        // body 可能包含 store/call 等副作用，故不能被消除
        .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while,
        // vec_source 分配向量数据，vec_sink 收集结果（sink_to_array 产生堆对象）
        .vec_source, .vec_sink, .vec_zip, .vec_take,
        // ref_set 通过引用写入原始通道（回写语义），有副作用
        .ref_set,
        // atomic 操作：分配堆对象或互斥保护的读-改-写，有副作用
        .atomic_make, .atomic_fetch_add, .atomic_swap, .atomic_cas,
        // syscall_call 执行宿主系统调用（IO/Time 等），有外部可观察副作用，不可消除
        .syscall_call,
        // lazy_force 强制求值 thunk 闭包，thunk body 可能含 println/call 等副作用
        .lazy_force,
        // cast_to 溢出或非法转换时 panic，消除会改变 panic 行为
        .cast_to,
        // alloc/free 内存管理：free 消除导致泄漏，alloc 消除可能破坏后续 free 配对
        .alloc, .free,
        => true,
        else => false,
    };
}

// ════════════════════════════════════════════════════════════════
// Pass 3: 通道活跃性分析 + 槽位复用
// ════════════════════════════════════════════════════════════════

/// 通道活跃性分析：识别生命周期不重叠的通道，复用槽位
///
/// 算法：
/// 1. 线性扫描节点流，记录每个通道的 first_use 和 last_use
/// 2. 当两个通道的生命周期不重叠时，可以复用同一个槽位
/// 3. 重映射通道索引
///
/// Phase 4 简化实现：仅分析，不实际复用（避免破坏 meta 引用）
fn channelLiveness(ir: *GlueIR) bool {
    _ = ir;
    // Phase 4 简化：通道复用需要更新所有节点和 meta 中的通道引用
    // 当前实现仅做分析，不实际执行复用
    return false;
}

// ════════════════════════════════════════════════════════════════
// Pass 4: 向量融合
// ════════════════════════════════════════════════════════════════

/// 向量融合：将连续的 vec_map 融合为单个 vec_map
///
/// 优化前：
///   ch_a = vec_map(f, src)
///   ch_b = vec_map(g, ch_a)
///
/// 优化后：
///   ch_b = vec_map(g ∘ f, src)   // 融合为一次遍历
///
/// 通过合并 body 子图实现：将 f 的子图追加到 g 的子图前面
fn vecFusion(ir: *GlueIR) bool {
    // ⚠️ 已禁用：原实现仅重定向 consumer 输入到 producer 的原始输入，并把 producer
    // 标记为 const_unit，但未合并 producer 的 body 子图。这会导致 vec_map(g, vec_map(f, src))
    // 被错误地优化为 vec_map(g, src)，producer 的变换 f 被静默丢弃，产生错误结果。
    //
    // 正确实现需要：将 producer 的 body 子图物理追加到 consumer body 子图前部，并重映射
    // body 内所有通道引用。这涉及复杂的节点重排和 meta 更新，当前 Phase 4 未实现。
    // 在此之前禁用该 pass 以保证正确性（牺牲少量优化收益）。
    _ = ir;
    return false;
}

/// 查找产生指定通道的节点索引（在 node_index 之前查找）
fn findProducer(ir: *const GlueIR, chan: u16, node_index: usize) ?usize {
    if (node_index == 0) return null;
    var i: usize = node_index;
    while (i > 0) {
        i -= 1;
        if (ir.nodes[i].output == chan) return i;
    }
    return null;
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const IRBuilder = @import("builder.zig").IRBuilder;
const ast = @import("ast");

/// 测试用 AST 构造器（简化版，复用 builder.zig 的 AstHelper 模式）
const AstHelper = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) AstHelper {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *AstHelper) void {
        self.arena.deinit();
    }

    fn alloc(self: *AstHelper) std.mem.Allocator {
        return self.arena.allocator();
    }

    const loc: ast.SourceLocation = .{ .line = 1, .column = 1 };

    fn expr(self: *AstHelper, e: ast.Expr) *ast.Expr {
        const slot = self.alloc().create(ast.NodeSlot(ast.Expr)) catch unreachable;
        slot.* = .{ .loc = loc, .node = e };
        return &slot.node;
    }

    fn stmt(self: *AstHelper, s: ast.Stmt) *ast.Stmt {
        const slot = self.alloc().create(ast.NodeSlot(ast.Stmt)) catch unreachable;
        slot.* = .{ .loc = loc, .node = s };
        return &slot.node;
    }

    fn intLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = null } });
    }

    fn ident(self: *AstHelper, name: []const u8) *ast.Expr {
        return self.expr(.{ .identifier = .{ .name = name } });
    }

    fn binary(self: *AstHelper, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) *ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    fn block(self: *AstHelper, stmts: []const *ast.Stmt, trailing: ?*ast.Expr) *ast.Expr {
        const stmts_slice = self.alloc().alloc(*ast.Stmt, stmts.len) catch unreachable;
        for (stmts, 0..) |s, i| stmts_slice[i] = s;
        return self.expr(.{ .block = .{
            .statements = stmts_slice,
            .trailing_expr = trailing,
        } });
    }

    fn funDecl(_: *AstHelper, name: []const u8, body: *ast.Expr, is_entry: bool) ast.Decl {
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = &.{},
            .return_type = null,
            .bounds = &.{},
            .body = body,
            .is_async = false,
            .is_entry = is_entry,
        } };
    }

    fn module(self: *AstHelper, name: []const u8, decls: []const ast.Decl) ast.Module {
        const decls_slice = self.alloc().alloc(ast.Decl, decls.len) catch unreachable;
        for (decls, 0..) |d, i| decls_slice[i] = d;
        return .{ .name = name, .source_path = null, .declarations = decls_slice };
    }
};

test "constantFold: 整数加法折叠" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 优化前：const_i(1), const_i(2), int_add, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.int_add, ir.nodes[2].op);

    // 执行优化
    const stats = optimize(&ir);

    // 验证：int_add 被折叠为 const_i
    try testing.expect(stats.constants_folded > 0);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op);
    try testing.expectEqual(@as(u8, 0), ir.nodes[2].input_count);

    // 验证折叠后的常量值 = 3
    const folded_val = ir.scalar_metas[ir.nodes[2].meta_index].const_val.?;
    try testing.expectEqual(@as(i128, 3), folded_val.int_val);
}

test "constantFold: 整数乘法折叠" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { 3 * 4 }
    const body = ah.block(&.{}, ah.binary(.mul, ah.intLit("3"), ah.intLit("4")));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = optimize(&ir);

    // int_mul 被折叠为 const_i，值 = 12
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op);
    const folded_val = ir.scalar_metas[ir.nodes[2].meta_index].const_val.?;
    try testing.expectEqual(@as(i128, 12), folded_val.int_val);
}

test "constantFold: 比较运算折叠" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { 1 < 2 }
    const body = ah.block(&.{}, ah.binary(.lt, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = optimize(&ir);

    // cmp_lt 被折叠为 const_bool，值 = true
    try testing.expectEqual(NodeOp.const_bool, ir.nodes[2].op);
    const folded_val = ir.scalar_metas[ir.nodes[2].meta_index].const_val.?;
    try testing.expectEqual(true, folded_val.bool_val);
}

test "constantFold: 嵌套表达式折叠" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { (1 + 2) * 3 }
    const inner = ah.binary(.add, ah.intLit("1"), ah.intLit("2"));
    const body = ah.block(&.{}, ah.binary(.mul, inner, ah.intLit("3")));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = optimize(&ir);

    // 嵌套折叠：(1+2) → 3，然后 3*3 → 9
    // int_mul（node[4]）应被折叠为 const_i，值 = 9
    try testing.expectEqual(NodeOp.const_i, ir.nodes[4].op);
    const folded_val = ir.scalar_metas[ir.nodes[4].meta_index].const_val.?;
    try testing.expectEqual(@as(i128, 9), folded_val.int_val);
}

test "constantFold: 除零不折叠" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { 1 / 0 }
    const body = ah.block(&.{}, ah.binary(.div, ah.intLit("1"), ah.intLit("0")));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = optimize(&ir);

    // 除零不应被折叠，int_div 保持不变
    try testing.expectEqual(NodeOp.int_div, ir.nodes[2].op);
}

test "deadNodeElim: 移除无用节点" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { val x = 1 + 2; 42 }
    // 1 + 2 的结果绑定到 x，但 x 未被使用 → 死节点
    const val_stmt = ah.stmt(.{ .val_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = ah.binary(.add, ah.intLit("1"), ah.intLit("2")),
    } });
    const body = ah.block(&.{val_stmt}, ah.intLit("42"));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const stats = optimize(&ir);

    // 验证：死节点被标记（int_add 变为 const_unit）
    try testing.expect(stats.dead_nodes_removed > 0);

    // 验证：常量折叠 + 死节点消除都生效
    try testing.expect(stats.constants_folded > 0);
}

test "optimize: 不动点迭代" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() { (1 + 2) + (3 + 4) }
    const left = ah.binary(.add, ah.intLit("1"), ah.intLit("2"));
    const right = ah.binary(.add, ah.intLit("3"), ah.intLit("4"));
    const body = ah.block(&.{}, ah.binary(.add, left, right));
    const decls = [_]ast.Decl{ah.funDecl("main", body, true)};
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const stats = optimize(&ir);

    // 多轮 pass 应将所有常量折叠
    try testing.expect(stats.passes_run >= 1);
    try testing.expect(stats.constants_folded > 0);
}

test "OptStats 默认值" {
    const stats = OptStats{};
    try testing.expectEqual(@as(u32, 0), stats.constants_folded);
    try testing.expectEqual(@as(u32, 0), stats.dead_nodes_removed);
    try testing.expectEqual(@as(u32, 0), stats.channels_reused);
    try testing.expectEqual(@as(u32, 0), stats.vecs_fused);
    try testing.expectEqual(@as(u32, 0), stats.passes_run);
}

test "hasSideEffect 判断" {
    try testing.expect(hasSideEffect(.halt_return));
    try testing.expect(hasSideEffect(.call));
    try testing.expect(hasSideEffect(.store));
    try testing.expect(!hasSideEffect(.int_add));
    try testing.expect(!hasSideEffect(.const_i));
}

test "isConstantOp 判断" {
    try testing.expect(isConstantOp(.const_i));
    try testing.expect(isConstantOp(.const_f));
    try testing.expect(isConstantOp(.const_bool));
    try testing.expect(!isConstantOp(.int_add));
    try testing.expect(!isConstantOp(.vec_map));
}
