//! 状态机变换 pass：async 函数体 → CoroutineMeta。
//!
//! 扫描 async 函数的 IR 节点序列，在 orbit 挂起节点之后插入段边界，
//! 产出 SegmentDesc 表 + FrameLayout + DeferTable/CatchTable/LoopTable。
//!
//! 阶段 1b：
//! - FrameLayout 从 ChannelSpace + Function 推导
//! - DeferTable 扫描 cleanup_register
//! - LoopTable 扫描 scalar_loop
//! - CatchTable 扫描 route_dispatch（Glue 的 try-catch 等价物）
//!
//! Glue 错误处理是数据流而非控制流异常：
//! - propagate(?) = gate_check + route_dispatch（arm0=Err 短路，arm1=Ok 提取）
//! - throw = gate_make_err + halt_return（Throw 返回函数）
//! - match on Throw = gate_check + route_dispatch（模式匹配 Ok/Error）
//! - ThrowValue 作为 Value 在通道流动，非 error 异常
//!
//! 注：本 pass 逻辑上属于 IR 变换层（操作 Node/IR 结构，不依赖 sema 的 TypeInferencer），
//! 故放在 ir 模块内，避免 ir ↔ sema 循环依赖。

const std = @import("std");
const meta_mod = @import("meta.zig");
const node_mod = @import("node.zig");
const channel_mod = @import("channel.zig");
const CoroutineMeta = meta_mod.CoroutineMeta;
const SegmentDesc = meta_mod.SegmentDesc;
const SuspendKind = meta_mod.SuspendKind;
const FrameLayout = meta_mod.FrameLayout;
const SlotDesc = meta_mod.SlotDesc;
const SlotRegion = meta_mod.SlotRegion;
const DeferTable = meta_mod.DeferTable;
const DeferEntry = meta_mod.DeferEntry;
const CatchTable = meta_mod.CatchTable;
const CatchEntry = meta_mod.CatchEntry;
const LoopTable = meta_mod.LoopTable;
const LoopEntry = meta_mod.LoopEntry;
const Function = meta_mod.Function;
const CleanupMeta = meta_mod.CleanupMeta;
const LoopMeta = meta_mod.LoopMeta;
const RouteMeta = meta_mod.RouteMeta;
const HaltKind = meta_mod.HaltKind;
const Node = node_mod.Node;
const ChannelSpace = channel_mod.ChannelSpace;

/// 挂起节点 op 集合：orbit_async_join / orbit_chan_recv / orbit_chan_send
fn isSuspendNode(op: node_mod.NodeOp) bool {
    return switch (op) {
        .orbit_async_join, .orbit_chan_recv, .orbit_chan_send => true,
        else => false,
    };
}

/// 段末挂起类型
fn suspendKindOf(op: node_mod.NodeOp) SuspendKind {
    return switch (op) {
        .orbit_chan_recv => .chan_recv,
        .orbit_chan_send => .chan_send,
        .orbit_async_join => .async_join,
        else => .none,
    };
}

/// 通道转换为帧 slot 索引。
/// - 局部通道（含参数）：slot = chan - local_chan_start
/// - 返回通道：slot = local_chan_count（return_channel 排在 slots 末尾）
/// - 其他：null（非本帧通道，如全局常量通道）
fn chanToSlot(chan: u16, func: *const Function) ?u16 {
    if (chan == func.return_channel) return func.local_chan_count;
    if (chan >= func.local_chan_start and chan < func.local_chan_start + func.local_chan_count) {
        return chan - func.local_chan_start;
    }
    return null;
}

/// 向有序去重列表插入 slot 索引（线性去重，defer 块体小，O(n²) 可接受）
fn insertUnique(list: *std.ArrayList(u16), arena: std.mem.Allocator, val: u16) !void {
    for (list.items) |v| if (v == val) return;
    try list.append(arena, val);
}

/// 扫描节点范围，收集所有引用的本帧局部通道 slot 索引（去重）。
/// 用于推导 defer 块体捕获的 locals（captured_locals）。
fn collectCapturedLocals(
    arena: std.mem.Allocator,
    nodes: []const Node,
    body_start: u32,
    body_len: u32,
    func: *const Function,
) ![]const u16 {
    if (body_len == 0 or body_start >= nodes.len) return &.{};
    var slots = std.ArrayList(u16).empty;
    const end = @min(body_start + body_len, @as(u32, @intCast(nodes.len)));
    var i: u32 = body_start;
    while (i < end) : (i += 1) {
        const node = nodes[i];
        if (chanToSlot(node.output, func)) |s| try insertUnique(&slots, arena, s);
        var j: u8 = 0;
        while (j < node.input_count and j < 4) : (j += 1) {
            if (chanToSlot(node.inputs[j], func)) |s| try insertUnique(&slots, arena, s);
        }
    }
    return try slots.toOwnedSlice(arena);
}

/// 扫描节点序列，在挂起节点之后插入段边界。
fn buildSegments(
    arena: std.mem.Allocator,
    nodes: []const Node,
) ![]SegmentDesc {
    var segments = std.ArrayList(SegmentDesc).empty;

    if (nodes.len == 0) {
        try segments.append(arena, .{
            .start_node = 0,
            .end_node = 0,
            .suspend_kind = .terminal,
        });
        return try segments.toOwnedSlice(arena);
    }

    var seg_start: u32 = 0;
    var i: u32 = 0;
    while (i < nodes.len) : (i += 1) {
        if (isSuspendNode(nodes[i].op)) {
            try segments.append(arena, .{
                .start_node = seg_start,
                .end_node = i,
                .suspend_kind = suspendKindOf(nodes[i].op),
            });
            seg_start = i + 1;
        }
    }

    if (seg_start < nodes.len) {
        try segments.append(arena, .{
            .start_node = seg_start,
            .end_node = @intCast(nodes.len - 1),
            .suspend_kind = .terminal,
        });
    }

    return try segments.toOwnedSlice(arena);
}

/// 从 ChannelSpace 和 Function 推导协程帧布局。
///
/// 复用 computeFunctionChannelLayout 已计算的 local_offsets 和 ChannelMeta：
/// - param_region: 参数通道区
/// - local_region: 局部通道区
/// - temp_region: 暂未单独划分（与 local_region 合并）
/// - slots: 每个通道一个 SlotDesc
pub fn buildFrameLayout(
    arena: std.mem.Allocator,
    func: *const Function,
    channels: *const ChannelSpace,
) !FrameLayout {
    const param_count = func.param_channels.len;
    const total_local = func.local_chan_count;
    const slot_count = total_local + 1; // +1 for return_channel

    var slots = try arena.alloc(SlotDesc, slot_count);

    for (0..slot_count) |i| {
        const chan: u16 = if (i < total_local)
            func.local_chan_start + @as(u16, @intCast(i))
        else
            func.return_channel;
        const cm = channels.get(chan);
        const offset: u32 = if (i < func.local_offsets.len) func.local_offsets[i] else 0;
        slots[i] = .{
            .offset = offset,
            .size = cm.elem_width,
            .is_ref = cm.is_ref,
        };
    }

    const param_size: u32 = if (param_count > 0 and param_count <= func.local_offsets.len)
        func.local_offsets[param_count]
    else
        0;
    const local_size: u32 = if (total_local < func.local_offsets.len and total_local > 0)
        func.local_offsets[total_local] - param_size
    else
        0;

    return FrameLayout{
        .total_size = func.chan_total_bytes,
        .param_region = .{ .start = 0, .size = param_size },
        .local_region = .{ .start = param_size, .size = local_size },
        .temp_region = .{ .start = param_size + local_size, .size = 0 },
        .slots = slots,
    };
}

/// 扫描 cleanup_register 节点，构建 DeferTable。
///
/// cleanup_register 的 meta_index 指向 cleanup_metas，
/// CleanupMeta 携带 trigger（return/throw/panic/any）、body_start/body_len、order。
/// defer 块体在节点流中（body_start..body_start+body_len），独立函数化时由 builder 创建 Function。
/// captured_locals 通过扫描块体节点引用的本帧局部通道推导（slot 索引去重列表）。
fn buildDeferTable(
    arena: std.mem.Allocator,
    nodes: []const Node,
    cleanup_metas: []const CleanupMeta,
    func: *const Function,
) !DeferTable {
    var entries = std.ArrayList(DeferEntry).empty;

    for (nodes, 0..) |node, i| {
        if (node.op == .cleanup_register) {
            if (node.meta_index == 0 or node.meta_index > cleanup_metas.len) continue;
            const cm = cleanup_metas[node.meta_index - 1];

            // 推导 captured_locals：扫描 defer 块体节点引用的本帧 slot
            const captured = try collectCapturedLocals(arena, nodes, cm.body_start, cm.body_len, func);

            try entries.append(arena, .{
                .register_node = @intCast(i),
                .block_func_idx = 0, // 由 builder 后处理回填（独立函数化）
                .captured_locals = captured,
                .trigger = cm.trigger,
                .block_body_start = cm.body_start,
                .block_body_len = cm.body_len,
                .order = cm.order,
            });
        }
    }

    return DeferTable{
        .entries = try entries.toOwnedSlice(arena),
    };
}

/// 扫描 scalar_loop 节点，构建 LoopTable。
///
/// scalar_loop 的 meta_index 指向 loop_metas，
/// 循环体切分为段后，head_segment = 循环体起始段。
fn buildLoopTable(
    arena: std.mem.Allocator,
    nodes: []const Node,
    loop_metas: []const LoopMeta,
    segments: []const SegmentDesc,
) !LoopTable {
    var entries = std.ArrayList(LoopEntry).empty;

    for (nodes, 0..) |node, i| {
        if (node.op == .scalar_loop) {
            if (node.meta_index == 0 or node.meta_index > loop_metas.len) continue;
            const lm = loop_metas[node.meta_index - 1];
            _ = i;

            // 查找循环体起始节点所在的段（head_segment）
            var head_segment: u16 = 0;
            for (segments, 0..) |seg, si| {
                if (lm.body_start >= seg.start_node and lm.body_start <= seg.end_node) {
                    head_segment = @intCast(si);
                    break;
                }
            }

            // 查找循环体结束后的段（after_segment）
            const body_end = lm.body_start + lm.body_len;
            var after_segment: u16 = if (segments.len > 0) @intCast(segments.len - 1) else 0;
            for (segments, 0..) |seg, si| {
                if (seg.start_node >= body_end) {
                    after_segment = @intCast(si);
                    break;
                }
            }

            try entries.append(arena, .{
                .head_segment = head_segment,
                .body_segments = &.{},
                .after_segment = after_segment,
                .nesting_level = 0,
            });
        }
    }

    return LoopTable{
        .entries = try entries.toOwnedSlice(arena),
    };
}

/// 扫描 route_dispatch 节点，构建 CatchTable。
///
/// Glue 的错误处理通过 route_dispatch 实现：
/// - propagate(?) 的 route_dispatch：arm0=Err 短路 halt_return，arm1=Ok 提取值
/// - match on Throw 的 route_dispatch：arm0=不匹配/Err，arm1=匹配/Ok
///
/// route_dispatch 的 meta_index 指向 route_metas，
/// 每个 RouteMeta 含 body_starts/body_lens（各 arm 的节点范围）。
/// arm0（Err 路径）的节点范围作为 catch handler body。
///
/// 字段推导：
/// - protected_start/end = route_dispatch 节点位置到 arm0 body 开始
/// - handler_body_start/len = arm0 body 范围（独立函数化用）
/// - exception_slot = route_dispatch output 通道在帧中的 slot 索引
/// - resume_segment = arm0 body 结束后的下一个段索引（catch 完成后恢复正常流程）
fn buildCatchTable(
    arena: std.mem.Allocator,
    nodes: []const Node,
    route_metas: []const RouteMeta,
    func: *const Function,
    segments: []const SegmentDesc,
) !CatchTable {
    var entries = std.ArrayList(CatchEntry).empty;

    for (nodes, 0..) |node, i| {
        if (node.op == .route_dispatch) {
            if (node.meta_index == 0 or node.meta_index > route_metas.len) continue;
            const rm = route_metas[node.meta_index - 1];

            // route_dispatch 至少有 2 个 arm
            if (rm.body_starts.len < 2 or rm.body_lens.len < 2) continue;

            // arm0 = Err/catch 路径，arm1 = Ok/正常路径
            const catch_body_start = rm.body_starts[0];
            const catch_body_len = rm.body_lens[0];
            const arm0_end = catch_body_start + catch_body_len;

            // exception_slot：route_dispatch output 通道转 slot
            // （分派结果通道，catch handler 从此 slot 读取异常值）
            const exception_slot = chanToSlot(node.output, func) orelse 0;

            // resume_segment：arm0 body 结束后的下一个段
            // （catch handler 执行完后恢复到的段索引）
            var resume_seg: u16 = 0;
            var found = false;
            for (segments, 0..) |seg, si| {
                if (seg.start_node >= arm0_end) {
                    resume_seg = @intCast(si);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // arm0 body 末尾已无后续段（如 arm0 以 halt_throw 终止），
                // resume_segment 指向终态段
                resume_seg = if (segments.len > 0) @intCast(segments.len - 1) else 0;
            }

            try entries.append(arena, .{
                .protected_start = @intCast(i),
                .protected_end = catch_body_start,
                .handler_func_idx = 0, // 由 builder 后处理回填（独立函数化）
                .exception_slot = exception_slot,
                .resume_segment = resume_seg,
                .handler_body_start = catch_body_start,
                .handler_body_len = catch_body_len,
            });
        }
    }

    return CatchTable{
        .entries = try entries.toOwnedSlice(arena),
    };
}

/// 状态机变换入口。
///
/// 扫描 async 函数的 IR 节点序列，产出 CoroutineMeta。
pub fn transformToStateMachine(
    arena: std.mem.Allocator,
    func_idx: u16,
    nodes: []const Node,
    func: *const Function,
    channels: *const ChannelSpace,
    cleanup_metas: []const CleanupMeta,
    loop_metas: []const LoopMeta,
    route_metas: []const RouteMeta,
) !CoroutineMeta {
    const segments = try buildSegments(arena, nodes);
    const frame_layout = try buildFrameLayout(arena, func, channels);
    const defer_table = try buildDeferTable(arena, nodes, cleanup_metas, func);
    const loop_table = try buildLoopTable(arena, nodes, loop_metas, segments);
    const catch_table = try buildCatchTable(arena, nodes, route_metas, func, segments);
    return CoroutineMeta{
        .func_idx = func_idx,
        .segment_count = @intCast(segments.len),
        .segments = segments,
        .frame_layout = frame_layout,
        .defer_table = defer_table,
        .catch_table = catch_table,
        .loop_table = loop_table,
    };
}

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

/// 构造测试用 Function（局部通道范围 [local_start, local_start+local_count)，return=return_chan）
fn makeTestFunc(return_chan: u16, local_start: u16, local_count: u16) Function {
    return Function{
        .name = "test",
        .node_start = 0,
        .node_count = 0,
        .param_channels = &.{},
        .return_channel = return_chan,
        .is_async = true,
        .local_chan_start = local_start,
        .local_chan_count = local_count,
        .chan_total_bytes = @as(u32, local_count) * 8,
        .local_offsets = &.{},
    };
}

test "buildSegments 空函数" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const segs = try buildSegments(arena.allocator(), &.{});
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(SuspendKind.terminal, segs[0].suspend_kind);
}

test "buildSegments 无挂起节点" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 1, .meta_index = 0 },
    };
    const segs = try buildSegments(arena.allocator(), &nodes);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(SuspendKind.terminal, segs[0].suspend_kind);
    try testing.expectEqual(@as(u32, 0), segs[0].start_node);
    try testing.expectEqual(@as(u32, 1), segs[0].end_node);
}

test "buildSegments 单个挂起节点" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .orbit_chan_recv, .input_count = 1, .output = 1, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 2, .meta_index = 0 },
    };
    const segs = try buildSegments(arena.allocator(), &nodes);
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqual(SuspendKind.chan_recv, segs[0].suspend_kind);
    try testing.expectEqual(@as(u32, 0), segs[0].start_node);
    try testing.expectEqual(@as(u32, 1), segs[0].end_node);
    try testing.expectEqual(SuspendKind.terminal, segs[1].suspend_kind);
    try testing.expectEqual(@as(u32, 2), segs[1].start_node);
    try testing.expectEqual(@as(u32, 2), segs[1].end_node);
}

test "buildSegments 多个挂起节点" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .orbit_async_create, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .orbit_chan_recv, .input_count = 1, .output = 1, .meta_index = 0 },
        .{ .op = .orbit_async_join, .input_count = 1, .output = 2, .meta_index = 0 },
        .{ .op = .orbit_chan_send, .input_count = 2, .output = 3, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 4, .meta_index = 0 },
    };
    const segs = try buildSegments(arena.allocator(), &nodes);
    try testing.expectEqual(@as(usize, 4), segs.len);
    try testing.expectEqual(SuspendKind.chan_recv, segs[0].suspend_kind);
    try testing.expectEqual(SuspendKind.async_join, segs[1].suspend_kind);
    try testing.expectEqual(SuspendKind.chan_send, segs[2].suspend_kind);
    try testing.expectEqual(SuspendKind.terminal, segs[3].suspend_kind);
}

test "buildFrameLayout 单参数函数" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var channels = ChannelSpace.init(testing.allocator);
    defer channels.deinit();

    const param_chan = try channels.alloc(.i64_chan);
    const ret_chan = try channels.alloc(.i64_chan);

    const func = Function{
        .name = "test",
        .node_start = 0,
        .node_count = 0,
        .param_channels = &[_]u16{param_chan},
        .return_channel = ret_chan,
        .is_async = true,
        .local_chan_start = param_chan,
        .local_chan_count = 1,
        .chan_total_bytes = 16,
        .local_offsets = &[_]u32{ 0, 16 },
    };

    const layout = try buildFrameLayout(arena.allocator(), &func, &channels);
    try testing.expectEqual(@as(u32, 16), layout.total_size);
    try testing.expectEqual(@as(usize, 2), layout.slots.len);
    // 参数通道 i64 = 8B
    try testing.expectEqual(@as(u16, 8), layout.slots[0].size);
    // return_channel i64 = 8B
    try testing.expectEqual(@as(u16, 8), layout.slots[1].size);
}

test "buildDeferTable 无 defer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 1, .meta_index = 0 },
    };
    const func = makeTestFunc(100, 0, 2);
    const dt = try buildDeferTable(arena.allocator(), &nodes, &.{}, &func);
    try testing.expectEqual(@as(usize, 0), dt.entries.len);
}

test "buildDeferTable 单个 defer 完整字段" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // defer 块体引用通道 0（slot 0）和通道 1（slot 1）
    const nodes = [_]Node{
        .{ .op = .cleanup_register, .input_count = 0, .output = 5, .meta_index = 1 },
        .{ .op = .halt_return, .input_count = 1, .output = 1, .meta_index = 0 },
        // defer 块体节点（body_start=2, body_len=2）
        .{ .op = .builtin_str, .input_count = 1, .output = 2, .meta_index = 0, .inputs = .{ 0, 0, 0, 0 } },
        .{ .op = .halt_return, .input_count = 1, .output = 3, .meta_index = 0, .inputs = .{ 1, 0, 0, 0 } },
    };
    const cleanup_metas = [_]CleanupMeta{
        .{ .trigger = .throw_halt, .body_start = 2, .body_len = 2, .order = 1 },
    };
    const func = makeTestFunc(100, 0, 2);
    const dt = try buildDeferTable(arena.allocator(), &nodes, &cleanup_metas, &func);
    try testing.expectEqual(@as(usize, 1), dt.entries.len);
    const e = dt.entries[0];
    try testing.expectEqual(@as(u32, 0), e.register_node);
    try testing.expectEqual(@as(u16, 0), e.block_func_idx); // builder 后处理回填前为 0
    try testing.expectEqual(HaltKind.throw_halt, e.trigger);
    try testing.expectEqual(@as(u32, 2), e.block_body_start);
    try testing.expectEqual(@as(u32, 2), e.block_body_len);
    try testing.expectEqual(@as(u32, 1), e.order);
    // captured_locals 应含 slot 0 和 slot 1（去重）
    try testing.expectEqual(@as(usize, 2), e.captured_locals.len);
}

test "buildLoopTable 无循环" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 1, .meta_index = 0 },
    };
    const segs = [_]SegmentDesc{
        .{ .start_node = 0, .end_node = 1, .suspend_kind = .terminal },
    };
    const lt = try buildLoopTable(arena.allocator(), &nodes, &.{}, &segs);
    try testing.expectEqual(@as(usize, 0), lt.entries.len);
}

test "buildLoopTable 单个循环" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .orbit_chan_recv, .input_count = 1, .output = 1, .meta_index = 0 },
        .{ .op = .scalar_loop, .input_count = 0, .output = 2, .meta_index = 1 },
        .{ .op = .halt_return, .input_count = 1, .output = 3, .meta_index = 0 },
    };
    const loop_metas = [_]LoopMeta{
        .{ .body_start = 0, .body_len = 1, .loop_kind = .loop },
    };
    const segs = [_]SegmentDesc{
        .{ .start_node = 0, .end_node = 0, .suspend_kind = .chan_recv },
        .{ .start_node = 1, .end_node = 2, .suspend_kind = .terminal },
    };
    const lt = try buildLoopTable(arena.allocator(), &nodes, &loop_metas, &segs);
    try testing.expectEqual(@as(usize, 1), lt.entries.len);
    try testing.expectEqual(@as(u16, 0), lt.entries[0].head_segment);
}

test "buildCatchTable 无 route_dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 0, .meta_index = 0 },
        .{ .op = .halt_return, .input_count = 1, .output = 1, .meta_index = 0 },
    };
    const segs = [_]SegmentDesc{
        .{ .start_node = 0, .end_node = 1, .suspend_kind = .terminal },
    };
    const func = makeTestFunc(100, 0, 2);
    const ct = try buildCatchTable(arena.allocator(), &nodes, &.{}, &func, &segs);
    try testing.expectEqual(@as(usize, 0), ct.entries.len);
}

test "buildCatchTable 单个 propagate 完整字段" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 模拟 propagate(?) 的 IR 结构：
    // node 0: gate_check
    // node 1: route_dispatch (meta_index=1, output=ch2)
    //   arm0 (Err): body_start=2, body_len=1 (halt_return 短路)
    //   arm1 (Ok): body_start=3, body_len=1 (gate_get_ok)
    // node 2: halt_return (arm0 body)
    // node 3: gate_get_ok (arm1 body)
    // node 4: orbit_chan_recv (挂起，段边界)
    // node 5: halt_return (arm0 body 之后的段)
    const nodes = [_]Node{
        .{ .op = .gate_check, .input_count = 1, .output = 1, .meta_index = 0 },
        .{ .op = .route_dispatch, .input_count = 1, .output = 2, .meta_index = 1 },
        .{ .op = .halt_return, .input_count = 1, .output = 3, .meta_index = 0 }, // arm0 body
        .{ .op = .gate_get_ok, .input_count = 1, .output = 4, .meta_index = 0 }, // arm1 body
        .{ .op = .orbit_chan_recv, .input_count = 1, .output = 5, .meta_index = 0 }, // 挂起
        .{ .op = .halt_return, .input_count = 1, .output = 6, .meta_index = 0 },
    };
    const route_metas = [_]RouteMeta{
        .{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = &[_]u32{ 2, 3 },
            .body_lens = &[_]u32{ 1, 1 },
        },
    };
    // 段切分：node 0-3 为段0（含 route_dispatch，无挂起），node 4 挂起，node 5 为终态段
    const segs = [_]SegmentDesc{
        .{ .start_node = 0, .end_node = 3, .suspend_kind = .none },
        .{ .start_node = 4, .end_node = 4, .suspend_kind = .chan_recv },
        .{ .start_node = 5, .end_node = 5, .suspend_kind = .terminal },
    };
    const func = makeTestFunc(100, 0, 5); // 局部通道 0..4，return=100
    const ct = try buildCatchTable(arena.allocator(), &nodes, &route_metas, &func, &segs);
    try testing.expectEqual(@as(usize, 1), ct.entries.len);
    const e = ct.entries[0];
    // protected_start = route_dispatch 节点位置（1）
    try testing.expectEqual(@as(u32, 1), e.protected_start);
    // protected_end = arm0 body_start（2）
    try testing.expectEqual(@as(u32, 2), e.protected_end);
    // handler_func_idx = 0（builder 后处理回填前）
    try testing.expectEqual(@as(u16, 0), e.handler_func_idx);
    // handler_body_start/len = arm0 body 范围
    try testing.expectEqual(@as(u32, 2), e.handler_body_start);
    try testing.expectEqual(@as(u32, 1), e.handler_body_len);
    // exception_slot = route_dispatch output(ch2) 转 slot = 2 - 0 = 2
    try testing.expectEqual(@as(u16, 2), e.exception_slot);
    // resume_segment = arm0 body 结束后(2+1=3)的下一个段
    // arm0_end=3，第一个 start_node>=3 的段是 seg[1]（start_node=4）→ 实际 seg[1].start_node=4>=3
    try testing.expectEqual(@as(u16, 1), e.resume_segment);
}

test "buildCatchTable arm0 终止时 resume_segment 指向终态段" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // arm0 body 在末尾，无后续段（arm0 以 halt_throw 终止）
    const nodes = [_]Node{
        .{ .op = .route_dispatch, .input_count = 1, .output = 1, .meta_index = 1 },
        .{ .op = .halt_throw, .input_count = 1, .output = 2, .meta_index = 0 }, // arm0 body
    };
    const route_metas = [_]RouteMeta{
        .{
            .target_count = 2,
            .body_starts = &[_]u32{ 1, 1 },
            .body_lens = &[_]u32{ 1, 0 },
        },
    };
    const segs = [_]SegmentDesc{
        .{ .start_node = 0, .end_node = 1, .suspend_kind = .terminal },
    };
    const func = makeTestFunc(100, 0, 2);
    const ct = try buildCatchTable(arena.allocator(), &nodes, &route_metas, &func, &segs);
    try testing.expectEqual(@as(usize, 1), ct.entries.len);
    // arm0_end = 1+1 = 2，无段 start_node>=2，fallback 到终态段（segs.len-1=0）
    try testing.expectEqual(@as(u16, 0), ct.entries[0].resume_segment);
}

test "chanToSlot 通道转 slot 索引" {
    const func = makeTestFunc(100, 10, 5); // 局部通道 10..14，return=100
    // 局部通道
    try testing.expectEqual(@as(?u16, 0), chanToSlot(10, &func));
    try testing.expectEqual(@as(?u16, 4), chanToSlot(14, &func));
    // return_channel
    try testing.expectEqual(@as(?u16, 5), chanToSlot(100, &func));
    // 非本帧通道
    try testing.expectEqual(@as(?u16, null), chanToSlot(5, &func));
    try testing.expectEqual(@as(?u16, null), chanToSlot(200, &func));
}

test "collectCapturedLocals 去重与筛选" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 节点引用 ch10(slot0), ch11(slot1), ch100(return slot5), ch200(非本帧)
    const nodes = [_]Node{
        .{ .op = .const_i, .input_count = 0, .output = 10, .meta_index = 0 },
        .{ .op = .int_add, .input_count = 2, .output = 11, .meta_index = 0, .inputs = .{ 10, 200, 0, 0 } },
        .{ .op = .halt_return, .input_count = 1, .output = 100, .meta_index = 0, .inputs = .{ 11, 0, 0, 0 } },
    };
    const func = makeTestFunc(100, 10, 5);
    const captured = try collectCapturedLocals(arena.allocator(), &nodes, 0, 3, &func);
    // 应含 slot 0,1,5（去重，排除 ch200）
    try testing.expectEqual(@as(usize, 3), captured.len);
}
