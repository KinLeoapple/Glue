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
    /// 检查节点是否在 body_skip 区域内（route_dispatch/vec_map 等的 arm body）。
    /// runSegment 跳过这些节点，由对应的 exec 函数（如 execRouteDispatch）按需执行。
    skip_node: *const fn (ctx: *anyopaque, node_idx: u32) bool,
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
    // 段内恢复点：唤醒后从 resume_node 继续，跳过已执行的前缀（避免段前缀重执行 Bug 12）
    // resume_node = 0 表示首次执行，从段头开始
    var i = if (frame.resume_node != 0) frame.resume_node else seg.start_node;
    // 进入循环前清除 resume_node（段内执行中若再次挂起会重新设置）
    frame.resume_node = 0;
    while (i <= seg.end_node and i < nodes.len) : (i += 1) {
        // 跳过 body_skip 区域内的子图节点（route_dispatch/vec_map 等的 arm body）。
        // 这些节点由对应的 exec 函数（如 execRouteDispatch）按需执行，
        // 段执行不能遍历它们，否则会执行非激活分支导致提前 halt_return。
        if (sctx.skip_node(sctx.ctx, i)) continue;
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
                    // Bug 3 fix: 通知等待发送的协程（通道腾出空间）
                    registry.wakeChanSend(chan);
                } else {
                    // Bug 7 fix: register FIRST (while still .running), then double-check.
                    // 避免 setStatus(.suspended) 在 register 之前导致的丢失唤醒。
                    registry.registerChanRecv(chan, frame);
                    if (chan.tryRecv()) |val| {
                        // 注册后再次检查：若在 register 与 tryRecv 之间有发送方写入，立即消费
                        registry.remove(frame);
                        sctx.write_value(sctx.ctx, node.output, val);
                        registry.wakeChanSend(chan);
                    } else {
                        frame.suspend_target = .{ .chan_recv = @ptrCast(chan) };
                        frame.resume_node = i; // 唤醒后重新执行 recv 节点（tryRecv 重试 + write_value）
                        frame.setStatus(.suspended);
                        return .suspend_;
                    }
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
                    // Bug 3 fix: 通知等待接收的协程（通道有数据可读）
                    registry.wakeChanRecv(chan);
                } else {
                    // Bug 7 fix: register FIRST, then double-check
                    registry.registerChanSend(chan, frame);
                    if (chan.trySend(val)) {
                        registry.remove(frame);
                        registry.wakeChanRecv(chan);
                    } else {
                        frame.suspend_target = .{ .chan_send = @ptrCast(chan) };
                        frame.resume_node = i + 1; // 唤醒后从 send 之后继续
                        frame.setStatus(.suspended);
                        return .suspend_;
                    }
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
                    // Bug 7 fix: register FIRST, then double-check
                    registry.registerAsyncJoin(handle, frame);
                    if (handle.isFinished()) {
                        registry.remove(frame);
                        if (handle.join()) |result| {
                            sctx.write_value(sctx.ctx, node.output, result);
                        } else {
                            sctx.write_value(sctx.ctx, node.output, Value.fromUnit());
                        }
                    } else {
                        frame.suspend_target = .{ .async_join = @ptrCast(handle) };
                        frame.resume_node = i; // 唤醒后重新执行 join 节点（isFinished 重试 + write_value）
                        frame.setStatus(.suspended);
                        return .suspend_;
                    }
                }
            },
            // ── 非 orbit 节点：委托 Engine.exec_node ──
            else => {
                const ret = try sctx.exec_node(sctx.ctx, node);
                if (ret) |chan| {
                    // halt_return/halt_throw：立即终止段执行，设置 frame.result 并返回 complete。
                    // 不能继续执行段内后续节点（会覆盖返回值），也不能 advance 到下一段。
                    frame.result = sctx.read_value(sctx.ctx, chan);
                    return .complete;
                }
            },
        }
    }

    // 段内所有节点执行完毕（未遇到 halt），根据 suspend_kind 决定段末动作
    const r: SegmentResult = switch (seg.suspend_kind) {
        .none => .advance,
        .chan_recv, .chan_send, .async_join => .advance,
        .terminal => .complete,
    };
    return r;
}
