//! 状态机段执行器：驱动 IR 节点子序列，orbit 挂起节点 try-first。
//!
//! 段执行协议（spec 2.3 / 3.1）：
//! 1. 遍历 seg.start_node..seg.end_node 的 IR 节点
//! 2. orbit 挂起节点（chan_recv/chan_send/async_join）try-first：
//!    - chan_recv：tryRecv，成功写 output 继续，失败注册 registry 挂起
//!    - chan_send：trySend，成功继续，失败注册 registry 挂起
//!    - async_join：isFinished，完成读 result 写 output，失败注册 registry 挂起
//! 3. 非 orbit 节点：委托 SegmentContext.exec_node（Engine 实现）
//! 4. 段末根据 suspend_kind 决定 advance/complete
//!
//! 依赖反转：coroutine 模块不能导入 engine（循环依赖），
//! 通过 SegmentContext vtable 让 Engine 注入节点执行与通道访问能力。

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const CoroutineStatus = frame_mod.CoroutineStatus;
const ir_mod = @import("ir");
const Node = ir_mod.Node;
const SegmentDesc = ir_mod.SegmentDesc;
const SuspendKind = ir_mod.SuspendKind;
const value_mod = @import("value");
const Value = value_mod.Value;
const ChannelValue = value_mod.ChannelValue;
const AsyncHandle = value_mod.AsyncHandle;
const suspend_registry_mod = @import("suspend_registry.zig");
const SuspendRegistry = suspend_registry_mod.SuspendRegistry;

/// 节点执行错误集（与 EngineError 对齐，由 Engine 的 exec_node 回调产生）
pub const SegmentError = error{
    OutOfMemory,
    Overflow,
    TooManyPools,
    AllocFailed,
    DivisionByZero,
    CastOverflow,
    UnsupportedOp,
    Thrown,
    Panic,
    InvalidMetaIndex,
    InvalidChannel,
    CallDepthExceeded,
    LoopBreak,
    LoopContinue,
    InvalidUtf8,
    IoNotInitialized,
    SchedulerNotStarted,
};

/// 段执行结果：决定 worker 段末如何处理帧
pub const SegmentResult = union(enum) {
    /// 段正常完成，推进到下一段（state += 1）
    advance,
    /// 段末挂起，帧已注册到等待队列，worker 应让出
    suspend_: void,
    /// 状态机执行完毕（终态段 ret），帧已完成，worker 写结果 + 唤醒 join 等待者
    complete,
    /// 段内异常未捕获，panic_buf 已填充
    failed: []const u8,
};

/// 段执行上下文：由 Engine 实现，通过 vtable 注入节点执行与通道访问能力。
///
/// 依赖反转：coroutine 模块不依赖 engine，Engine 构造此结构传入 runSegment。
/// - exec_node：执行非 orbit 节点（委托 engine.execNode）
/// - read_channel：从通道索引读 ChannelValue 指针（orbit_chan_recv/send 用）
/// - read_async_handle：从通道索引读 AsyncHandle 指针（orbit_async_join 用）
/// - read_value：从通道索引读 Value（orbit_chan_send 的输入值用）
/// - write_value：写 Value 到通道索引（orbit_chan_recv 的输出用）
/// - install_frame：将帧的 locals 区安装到 worker Engine 的 runtime.chan_ptrs，
///   使该函数的本地通道指针指向帧内持久化的通道数据（帧自带通道空间方案）
pub const SegmentContext = struct {
    ctx: *anyopaque,
    exec_node: *const fn (ctx: *anyopaque, node: *const Node) SegmentError!?u16,
    read_channel: *const fn (ctx: *anyopaque, chan_idx: u16) ?*ChannelValue,
    read_async_handle: *const fn (ctx: *anyopaque, chan_idx: u16) ?*AsyncHandle,
    read_value: *const fn (ctx: *anyopaque, chan_idx: u16) Value,
    write_value: *const fn (ctx: *anyopaque, chan_idx: u16, val: Value) void,
    install_frame: *const fn (ctx: *anyopaque, frame: *CoroutineFrame) void,
};

/// 执行状态机段：驱动 IR 节点子序列。
///
/// try-first 模式：挂起节点先 try（非阻塞），成功则继续，失败才挂起。
/// sync 函数调用借用 worker 临时栈执行（由 Engine.exec_node 处理）。
///
/// 参数：
/// - frame：协程帧（读写 state / locals / suspend_target / status）
/// - seg：段描述（节点范围 + 挂起类型）
/// - nodes：全局 IR 节点流（seg.start_node..seg.end_node 索引其中）
/// - sctx：段执行上下文（Engine 注入的 vtable）
/// - registry：挂起注册表（try-first 失败时注册帧）
pub fn runSegment(
    frame: *CoroutineFrame,
    seg: SegmentDesc,
    nodes: []const Node,
    sctx: SegmentContext,
    registry: *SuspendRegistry,
) SegmentError!SegmentResult {
    // 捕获 halt_return 的返回通道索引（exec_node 返回非 null 时记录）
    var halt_ret_chan: ?u16 = null;

    var i = seg.start_node;
    while (i <= seg.end_node and i < nodes.len) : (i += 1) {
        const node = &nodes[i];
        switch (node.op) {
            // ── orbit 挂起节点：try-first ──
            .orbit_chan_recv => {
                const chan = sctx.read_channel(sctx.ctx, node.inputs[0]) orelse {
                    frame.setPanic("orbit_chan_recv: invalid channel");
                    return .{ .failed = frame.getPanic() };
                };
                if (chan.tryRecv()) |val| {
                    // try-first 成功：写值到 output，继续段内下一节点
                    sctx.write_value(sctx.ctx, node.output, val);
                } else {
                    // try-first 失败：注册挂起，让出
                    frame.suspend_target = .{ .chan_recv = @ptrCast(chan) };
                    frame.setStatus(.suspended);
                    registry.registerChanRecv(chan, frame);
                    return .suspend_;
                }
            },
            .orbit_chan_send => {
                const chan = sctx.read_channel(sctx.ctx, node.inputs[0]) orelse {
                    frame.setPanic("orbit_chan_send: invalid channel");
                    return .{ .failed = frame.getPanic() };
                };
                const val = sctx.read_value(sctx.ctx, node.inputs[1]);
                if (chan.trySend(val)) {
                    // try-first 成功：继续段内下一节点
                } else {
                    // try-first 失败：注册挂起，让出
                    frame.suspend_target = .{ .chan_send = @ptrCast(chan) };
                    frame.setStatus(.suspended);
                    registry.registerChanSend(chan, frame);
                    return .suspend_;
                }
            },
            .orbit_async_join => {
                const handle = sctx.read_async_handle(sctx.ctx, node.inputs[0]) orelse {
                    frame.setPanic("orbit_async_join: invalid handle");
                    return .{ .failed = frame.getPanic() };
                };
                if (handle.isFinished()) {
                    // try-first 成功：读结果写 output
                    if (handle.join()) |result| {
                        sctx.write_value(sctx.ctx, node.output, result);
                    } else {
                        // 结果已被消费或无结果：写零值
                        sctx.write_value(sctx.ctx, node.output, Value.fromUnit());
                    }
                } else {
                    // try-first 失败：注册挂起，让出
                    frame.suspend_target = .{ .async_join = @ptrCast(handle) };
                    frame.setStatus(.suspended);
                    registry.registerAsyncJoin(handle, frame);
                    return .suspend_;
                }
            },
            // ── 非 orbit 节点：委托 Engine.exec_node ──
            else => {
                const ret = try sctx.exec_node(sctx.ctx, node);
                if (ret) |chan| {
                    halt_ret_chan = chan;
                }
            },
        }
    }

    // 段内所有节点执行完毕，根据 suspend_kind 决定段末动作
    const r: SegmentResult = switch (seg.suspend_kind) {
        .none => .advance,
        .chan_recv, .chan_send, .async_join => .advance,
        .terminal => blk: {
            // 终态段完成：从返回通道读取结果值到 frame.result
            if (halt_ret_chan) |chan| {
                frame.result = sctx.read_value(sctx.ctx, chan);
            } else {
            }
            break :blk .complete;
        },
    };
    return r;
}
