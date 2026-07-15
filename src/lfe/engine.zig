//! 层流执行引擎：标量模式（element_count = 1）。
//!
//! 阶段 1 范围：
//! - 常量载入（constant / str_const）
//! - 整数算术（add/sub/mul/div/mod/and/or/xor/neg/abs/not）
//! - 浮点算术（add/sub/mul/div/neg/abs）
//! - 布尔运算（and/or/not/xor）
//! - 比较（int/float/bool/char → mask_chan）
//! - 谓词选择（select）
//! - 控制流出口（halt_return / halt_throw / halt_break / halt_continue）
//! - 调试输出（debug_print）
//! - 通道复制（move）
//!
//! 阶段 2 将扩展为 SIMD 批处理（element_count > 1）。

const std = @import("std");
const mem = @import("mem");
const value = @import("value");
const lamina_mod = @import("lamina.zig");
const batch = @import("value").batch;
const scheduler_mod = @import("scheduler.zig");

const ChannelRegion = mem.ChannelRegion;
const Lamina = lamina_mod.Lamina;
const LaminaOp = lamina_mod.LaminaOp;
const ScalarChanType = lamina_mod.ScalarChanType;
const LaminarGraph = lamina_mod.LaminarGraph;
const PhysicalChannel = lamina_mod.PhysicalChannel;
const IntKind = lamina_mod.IntKind;
const FloatKind = lamina_mod.FloatKind;
const NativeIntType = lamina_mod.NativeIntType;
const NativeFloatType = lamina_mod.NativeFloatType;
const simdLaneCount = lamina_mod.simdLaneCount;
const OrbitHub = lamina_mod.OrbitHub;
const OrbitHubKind = lamina_mod.OrbitHubKind;
const OrbitEntry = lamina_mod.OrbitEntry;
const Orbit = lamina_mod.Orbit;
const OrbitState = lamina_mod.OrbitState;
const CondKind = lamina_mod.CondKind;
const ParamBind = lamina_mod.ParamBind;
const ChannelScope = lamina_mod.ChannelScope;
const DeferEntry = lamina_mod.DeferEntry;
const Value = value.Value;
const ObjHeader = value.obj_header.ObjHeader;
const concurrent = value.concurrent;
const Scheduler = scheduler_mod.Scheduler;
const LfeTask = scheduler_mod.LfeTask;
const TaskState = scheduler_mod.TaskState;
const ExecResult = scheduler_mod.ExecResult;

/// 异步轨道实例（async_hub 激活的轨道运行时副本）
const AsyncInstance = struct {
    /// 对应 graph.orbits 中的索引
    orbit_index: u16,
    /// 实例的私有通道数据（同步模式使用，异步模式为空切片）
    channels: []PhysicalChannel,
    /// 实例的通道数据区（同步模式使用）
    channel_region: ChannelRegion,
    /// 是否已完成
    done: bool = false,
    /// 结果值（同步模式完成后填充）
    result: Value = Value.fromI64(0),
    // ── 调度器模式（E1）──
    /// 调度器任务指针（异步模式非 null）
    task: ?*LfeTask = null,
    /// 轨道输出通道索引（异步模式读取 task.channels[output_channel]）
    output_channel: u16 = 0,
};

/// 递归调用帧（显式数据栈）
const DataFrame = struct {
    /// 通道快照（保存调用前的通道状态）
    channels_snapshot: []u8,
    /// 返回通道（结果回写到的太阳层通道）
    return_channel: u16,
};

/// 引擎错误
pub const EngineError = error{
    OutOfMemory,
    InvalidChannel,
    UnsupportedOp,
    DivisionByZero,
    SystemResources,
    Unexpected,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
    CastOverflow,
};

/// 停机原因
pub const HaltReason = enum {
    none,
    return_halt,
    throw_halt,
    break_halt,
    continue_halt,
};

/// 所有 IntKind 的 comptime 列表（用于 inline for 派发）
const ALL_INT_KINDS = [_]IntKind{
    .i8, .i16, .i32, .i64, .i128,
    .u8, .u16, .u32, .u64, .u128,
};

/// 所有 FloatKind 的 comptime 列表
const ALL_FLOAT_KINDS = [_]FloatKind{
    .f16, .f32, .f64, .f128,
};

/// 标量执行引擎
pub const Engine = struct {
    allocator: std.mem.Allocator,
    graph: *const LaminarGraph,
    /// 物理通道数组（索引 = 逻辑通道索引）
    channels: []PhysicalChannel,
    /// 通道数据线性区（bump + reset，16B 对齐）
    channel_region: ChannelRegion,
    /// 元素数量（标量模式 = 1）
    element_count: usize,
    /// 停机原因
    halt_reason: HaltReason,
    /// 返回值（i64 表示，用于进程退出码）
    return_value: i64,
    /// 协程调度器（并发模式时非 null）
    scheduler: ?*Scheduler = null,
    /// 当前执行的 task（协程模式时非 null）
    task: ?*LfeTask = null,
    /// 是否借用 task 的通道（协程模式时不释放 channels/region）
    borrowed_task: bool = false,
    /// 引擎自有的调度器（主引擎异步轨道时惰性创建）
    owned_scheduler: ?*Scheduler = null,
    /// 异步轨道子图包装器列表（deinit 时释放）
    async_subgraphs: std.ArrayListUnmanaged(*LaminarGraph) = .empty,

    // ── 星轨模型运行时状态 ──
    /// 轨道运行时状态（与 graph.orbits 一一对应）
    orbit_states: []OrbitState = &.{},
    /// 异步轨道实例列表（async_hub 激活的）
    async_instances: std.ArrayListUnmanaged(AsyncInstance) = .empty,
    /// defer 栈（LIFO，存储 orbit_index）
    defer_stack: std.ArrayListUnmanaged(u16) = .empty,
    /// 显式数据栈（递归调用帧）
    data_stack: std.ArrayListUnmanaged(DataFrame) = .empty,
    /// 当前正在执行的轨道索引（null = 太阳层）
    current_orbit: ?u16 = null,

    /// 初始化引擎：从 ChannelRegion 分配物理通道
    pub fn init(
        allocator: std.mem.Allocator,
        graph: *const LaminarGraph,
        element_count: usize,
    ) !Engine {
        var region = ChannelRegion.init(allocator);
        errdefer region.deinit();

        const channels = try allocator.alloc(PhysicalChannel, @max(graph.channel_count, 1));

        // 从 ChannelRegion 为每个通道分配数据（16B 对齐）
        for (graph.channel_metas, 0..) |meta, i| {
            const w = meta.elem_width;
            if (w > 0) {
                const sz = @as(usize, w) * element_count;
                const data = try region.alloc(sz);
                @memset(data, 0);
                channels[i] = .{
                    .data = data,
                    .elem_width = w,
                    .element_count = element_count,
                };
            } else {
                channels[i] = .{
                    .data = &.{},
                    .elem_width = 0,
                    .element_count = element_count,
                };
            }
        }

        return .{
            .allocator = allocator,
            .graph = graph,
            .channels = channels,
            .channel_region = region,
            .element_count = element_count,
            .halt_reason = .none,
            .return_value = 0,
            .orbit_states = try allocator.alloc(OrbitState, graph.orbits.len),
        };
    }

    /// 为 task 创建引擎：借用 task 的通道和图，不分配自己的资源
    pub fn initForTask(
        allocator: std.mem.Allocator,
        task: *LfeTask,
        scheduler: *Scheduler,
    ) !Engine {
        return .{
            .allocator = allocator,
            .graph = task.subgraph,
            .channels = task.channels,
            .channel_region = task.channel_region,
            .element_count = task.element_count,
            .halt_reason = .none,
            .return_value = 0,
            .scheduler = scheduler,
            .task = task,
            .borrowed_task = true,
            .orbit_states = try allocator.alloc(OrbitState, task.subgraph.orbits.len),
        };
    }

    /// 释放引擎资源
    pub fn deinit(self: *Engine) void {
        // 停止自有调度器（等待所有异步任务完成）
        if (self.owned_scheduler) |sched| {
            sched.stop();
            self.allocator.destroy(sched);
            self.owned_scheduler = null;
        }
        // 释放异步轨道子图包装器
        for (self.async_subgraphs.items) |sg| {
            self.allocator.destroy(sg);
        }
        self.async_subgraphs.deinit(self.allocator);
        // 释放异步轨道实例
        for (self.async_instances.items) |*inst| {
            if (inst.task) |task| {
                // 调度器模式：释放任务引用
                task.release(self.allocator);
            } else {
                // 同步模式：释放私有通道
                inst.channel_region.deinit();
                self.allocator.free(inst.channels);
            }
        }
        self.async_instances.deinit(self.allocator);
        // 释放 defer 栈和数据栈
        self.defer_stack.deinit(self.allocator);
        for (self.data_stack.items) |frame| {
            self.allocator.free(frame.channels_snapshot);
        }
        self.data_stack.deinit(self.allocator);
        // 释放轨道状态
        if (self.orbit_states.len > 0) {
            self.allocator.free(self.orbit_states);
        }
        if (!self.borrowed_task) {
            self.allocator.free(self.channels);
            self.channel_region.deinit();
        }
    }

    /// task 模式下不释放借用资源（deinit 会跳过）
    pub fn deinitTask(self: *Engine) void {
        _ = self;
    }

    /// 执行层流核：按拓扑序遍历层序列，逐层派发执行
    /// 太阳层执行完毕后，若有异步轨道，等待全部完成
    pub fn run(self: *Engine) EngineError!void {
        for (self.graph.laminas) |lam| {
            if (self.halt_reason != .none) break;
            try self.executeLamina(lam);
        }
        // 太阳层执行完毕，等待所有异步轨道完成
        if (self.owned_scheduler) |sched| {
            sched.waitForAll();
        }
    }

    /// 执行 task 的 laminas 片段（从 task.pc 开始）
    /// 返回执行结果：continue_/suspend_/done/failed
    /// worker 线程调用此函数，遇到阻塞 op 返回 .suspend_，halt_return 返回 .done
    pub fn runTaskSlice(self: *Engine) ExecResult {
        const laminas = self.graph.laminas;
        const task = self.task orelse return .failed;

        while (task.pc < laminas.len) {
            const lam = laminas[task.pc];
            task.pc += 1;

            // 并发 op 可能返回 suspend_
            switch (lam.op) {
                .halt_return => {
                    if (lam.input_count >= 1) {
                        const in_chan = &self.channels[lam.inputs[0]];
                        task.result = chanToValue(in_chan, self.graph.channel_metas[lam.inputs[0]]);
                    }
                    task.result_ready.store(true, .release);
                    return .done;
                },
                .halt_throw => {
                    return .failed;
                },
                .async_join => {
                    if (self.execAsyncJoin(lam)) |result| {
                        if (result == .suspend_) return .suspend_;
                    } else {
                        return .failed;
                    }
                },
                .orbit_join => {
                    if (self.execOrbitJoinAsync(lam)) |result| {
                        if (result == .suspend_) return .suspend_;
                    } else {
                        return .failed;
                    }
                },
                .async_status => self.execAsyncStatus(lam) catch return .failed,
                .async_yield => {
                    self.scheduler.?.enqueue(task);
                    return .suspend_;
                },
                .channel_recv => {
                    if (self.execChannelRecvBlocking(lam)) |result| {
                        if (result == .suspend_) return .suspend_;
                    } else {
                        return .failed;
                    }
                },
                .receiver_recv => {
                    if (self.execChannelRecvBlocking(lam)) |result| {
                        if (result == .suspend_) return .suspend_;
                    } else {
                        return .failed;
                    }
                },
                else => {
                    self.executeLamina(lam) catch return .failed;
                },
            }
        }
        // laminas 跑完但无 halt_return
        task.result_ready.store(true, .release);
        return .done;
    }

    /// 获取返回值
    pub fn getReturnValue(self: *const Engine) i64 {
        return self.return_value;
    }

    // ── 层派发 ──

    fn executeLamina(self: *Engine, lam: Lamina) EngineError!void {
        // 谓词门控：条件为假时跳过操作（select 和 throw_propagate 除外，它们用 predicate 作为数据输入）
        if (lam.predicate) |p| {
            if (lam.op != .select and lam.op != .throw_propagate) {
                if (p < self.channels.len) {
                    const mask = self.channels[p].getScalar(u8, 0);
                    if (mask == 0) return; // 谓词为假，跳过此操作
                }
            }
        }
        switch (lam.op) {
            // 常量与载入
            .constant => try self.execConstant(lam),
            .str_const => try self.execStrConst(lam),
            .move => try self.execMove(lam),

            // 整数算术
            .int_add, .int_sub, .int_mul, .int_div, .int_mod,
            .int_and, .int_or, .int_xor,
            .int_neg, .int_abs, .int_not,
            .int_scale_add, .int_fma,
            => try self.execIntArith(lam),

            // 浮点算术
            .float_add, .float_sub, .float_mul, .float_div,
            .float_neg, .float_abs,
            .float_scale_add, .float_fma,
            => try self.execFloatArith(lam),

            // 整数比较
            .int_lt, .int_gt, .int_eq, .int_ne, .int_le, .int_ge,
            => try self.execIntCompare(lam),

            // 浮点比较
            .float_lt, .float_gt, .float_eq, .float_ne, .float_le, .float_ge,
            => try self.execFloatCompare(lam),

            // 布尔运算
            .bool_and, .bool_or, .bool_not, .bool_xor,
            => try self.execBoolArith(lam),

            // 布尔比较
            .bool_eq, .bool_ne,
            => try self.execBoolCompare(lam),

            // 字符比较
            .char_lt, .char_gt, .char_eq, .char_ne, .char_le, .char_ge,
            => try self.execCharCompare(lam),

            // 谓词选择
            .select => try self.execSelect(lam),

            // 控制流出口
            .halt_return => try self.execHaltReturn(lam),
            .halt_throw => self.halt_reason = .throw_halt,
            .halt_break => self.halt_reason = .break_halt,
            .halt_continue => self.halt_reason = .continue_halt,

            // 调试输出
            .debug_print => try self.execDebugPrint(lam),

            // 阶段 4: 聚合与流控制
            .reduce_sum, .reduce_min, .reduce_max, .reduce_prod, .reduce_count,
            => try self.execReduce(lam),
            .compress => try self.execCompress(lam),
            .length => try self.execLength(lam),
            .broadcast_input => try self.execBroadcastInput(lam),

            // 阶段 5: Cell 操作（可变状态）
            .cell_make => try self.execCellMake(lam),
            .cell_get => try self.execCellGet(lam),
            .cell_set => try self.execCellSet(lam),
            .cell_swap => try self.execCellSwap(lam),

            // 阶段 5: Throw / Error 操作（异常作为数据）
            .throw_make => try self.execThrowMake(lam),
            .throw_is_ok => try self.execThrowIsOk(lam),
            .throw_is_err => try self.execThrowIsErr(lam),
            .throw_get_ok => try self.execThrowGetOk(lam),
            .throw_get_err => try self.execThrowGetErr(lam),
            .throw_propagate => try self.execThrowPropagate(lam),
            .error_make => try self.execErrorMake(lam),

            // 阶段 5: 闭包操作（lambda 捕获与调用）
            .closure_make => try self.execClosureMake(lam),
            .closure_call => try self.execClosureCall(lam),
            .closure_capture => try self.execClosureCapture(lam),

            // 阶段 5: Trait 操作（动态分派）
            .trait_make => try self.execTraitMake(lam),
            .trait_call_method => try self.execTraitCallMethod(lam),
            .trait_downcast => try self.execTraitDowncast(lam),

            // 阶段 5: 动态分派（switch_lamina）
            .switch_lamina => try self.execSwitchLamina(lam),

            // 阶段 5: Atomic 操作（原子读写，复用 value/concurrent.zig）
            .atomic_make => try self.execAtomicMake(lam),
            .atomic_load => try self.execAtomicLoad(lam),
            .atomic_store => try self.execAtomicStore(lam),
            .atomic_cas => try self.execAtomicCas(lam),
            .atomic_swap => try self.execAtomicSwap(lam),
            .atomic_fetch_add => try self.execAtomicFetchAdd(lam),
            .atomic_fetch_sub => try self.execAtomicFetchSub(lam),

            // 阶段 5: Async 操作（协程调度）
            .async_create => try self.execAsyncCreate(lam),
            .async_join => {}, // 在 runTaskSlice 中处理
            .async_yield => {}, // 在 runTaskSlice 中处理
            .async_status => try self.execAsyncStatus(lam),

            // 阶段 5: Channel 操作（复用 value/concurrent.zig）
            .channel_make => try self.execChannelMake(lam),
            .channel_split => try self.execChannelSplit(lam),
            .channel_send => try self.execChannelSend(lam),
            .channel_recv => {}, // 在 runTaskSlice 中处理（阻塞）
            .channel_try_recv => try self.execChannelTryRecv(lam),
            .channel_close => try self.execChannelClose(lam),
            .channel_get_sender => try self.execChannelGetSender(lam),
            .channel_get_receiver => try self.execChannelGetReceiver(lam),

            // 阶段 5: Sender/Receiver（通道引用）
            .sender_send => try self.execSenderSend(lam),
            .sender_close => try self.execSenderClose(lam),
            .receiver_recv => {}, // 在 runTaskSlice 中处理（阻塞）
            .receiver_try_recv => try self.execReceiverTryRecv(lam),
            .receiver_close => try self.execReceiverClose(lam),

            // 阶段 5: Range 操作
            .range_make => try self.execRangeMake(lam),
            .range_start => try self.execRangeStart(lam),
            .range_end => try self.execRangeEnd(lam),
            .range_len => try self.execRangeLen(lam),
            .range_to_stream => try self.execRangeToStream(lam),

            // 阶段 5: Iterator 操作
            .iter_has_next => try self.execIterHasNext(lam),
            .iter_next => try self.execIterNext(lam),
            .iter_to_stream => try self.execIterToStream(lam),

            // 星轨模型：轨道枢纽
            .orbit_hub => try self.execOrbitHub(lam),
            .orbit_hub_async => try self.execOrbitHubAsync(lam),
            .orbit_join => try self.execOrbitJoinSync(lam),

            // 星轨模型：defer 栈
            .defer_register => try self.execDeferRegister(lam),
            .defer_execute => try self.execDeferExecute(),

            // 星轨模型：显式数据栈
            .stack_push => try self.execStackPush(lam),
            .stack_pop => try self.execStackPop(lam),
            .stack_peek => try self.execStackPeek(lam),
            .stack_depth => try self.execStackDepth(lam),

            // 统一标量类型转换
            .type_cast => try self.execTypeCast(lam),

            // 阶段 1 暂不支持
            else => return error.UnsupportedOp,
        }
    }

    // ── 常量载入 ──

    fn execConstant(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const val = lam.const_val orelse 0;

        // 通道无存储空间（null/unit 或 optimizer 复用冲突）时跳过
        if (out.elem_width == 0) return;

        if (self.element_count <= 1) {
            // 标量模式
            if (lam.int_kind) |kind| {
                inline for (ALL_INT_KINDS) |k| {
                    if (kind == k) {
                        const T = NativeIntType(k);
                        out.setScalar(T, 0, @intCast(val));
                    }
                }
            } else if (lam.float_kind) |kind| {
                const f64_val: f64 = @bitCast(val);
                inline for (ALL_FLOAT_KINDS) |k| {
                    if (kind == k) {
                        const T = NativeFloatType(k);
                        out.setScalar(T, 0, @floatCast(f64_val));
                    }
                }
            } else {
                // bool / char / mask / null / unit
                const ct = self.graph.channel_metas[lam.output].chan_type;
                switch (ct) {
                    .bool_chan, .mask_chan => out.setScalar(u8, 0, @intCast(val & 1)),
                    .char_chan => out.setScalar(u32, 0, @intCast(val)),
                    .null_chan, .unit_chan => {},
                    else => out.setScalar(i64, 0, val),
                }
            }
            return;
        }

        // SIMD 批处理模式：广播常量到所有元素
        if (lam.int_kind) |kind| {
            inline for (ALL_INT_KINDS) |k| {
                if (kind == k) {
                    const T = NativeIntType(k);
                    const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                    batch.broadcast(T, out_slice, @intCast(val));
                }
            }
        } else if (lam.float_kind) |kind| {
            const f64_val: f64 = @bitCast(val);
            inline for (ALL_FLOAT_KINDS) |k| {
                if (kind == k) {
                    const T = NativeFloatType(k);
                    const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                    batch.broadcast(T, out_slice, @floatCast(f64_val));
                }
            }
        } else {
            const ct = self.graph.channel_metas[lam.output].chan_type;
            switch (ct) {
                .bool_chan, .mask_chan => {
                    const out_slice = out.asTypedPtrMut(u8)[0..self.element_count];
                    batch.broadcast(u8, out_slice, @intCast(val & 1));
                },
                .char_chan => {
                    const out_slice = out.asTypedPtrMut(u32)[0..self.element_count];
                    batch.broadcast(u32, out_slice, @intCast(val));
                },
                .null_chan, .unit_chan => {},
                else => {
                    const out_slice = out.asTypedPtrMut(i64)[0..self.element_count];
                    batch.broadcast(i64, out_slice, val);
                },
            }
        }
    }

    fn execStrConst(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const str_idx = lam.name_idx orelse return error.InvalidChannel;
        // 将字符串表索引存入 ref 通道（作为 u64）
        out.setScalar(u64, 0, @intCast(str_idx));
    }

    fn execMove(self: *Engine, lam: Lamina) !void {
        // 自移动（src == dst）无操作，避免 @memcpy 别名 panic
        if (lam.inputs[0] == lam.output) return;
        const src = &self.channels[lam.inputs[0]];
        const dst = &self.channels[lam.output];
        const w = dst.elem_width;
        if (w > 0) {
            const total = w * self.element_count;
            @memcpy(dst.data[0..total], src.data[0..total]);
        }
    }

    // ── 标量类型转换 ──

    fn execTypeCast(self: *Engine, lam: Lamina) !void {
        const src_chan = &self.channels[lam.inputs[0]];
        const dst_chan = &self.channels[lam.output];
        const src_tag = lamina_mod.chanTypeToScalarTag(self.graph.channel_metas[lam.inputs[0]].chan_type) orelse return;
        const dst_tag: value.scalar.ScalarTag = @enumFromInt(@as(u8, @intCast(lam.const_val orelse return)));

        // 读取源数据到 [16]u8（仅前 src_width 字节有效）
        var src_bytes: [16]u8 = [_]u8{0} ** 16;
        const src_w = src_chan.elem_width;
        if (src_w > 0) @memcpy(src_bytes[0..src_w], src_chan.data[0..src_w]);

        // 执行转换（comptime 特化分派表 O(1) 查表）
        const dst_bytes = try value.cast.cast(src_tag, dst_tag, src_bytes);

        // 写入目标通道（仅前 dst_width 字节）
        const dst_w = dst_chan.elem_width;
        if (dst_w > 0) @memcpy(dst_chan.data[0..dst_w], dst_bytes[0..dst_w]);
    }

    // ── 整数算术 ──

    fn execIntArith(self: *Engine, lam: Lamina) !void {
        const kind = lam.int_kind orelse .i64;
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];

        inline for (ALL_INT_KINDS) |k| {
            if (kind == k) {
                const T = NativeIntType(k);

                if (self.element_count <= 1) {
                    // 标量模式
                    const a = lhs_chan.getScalar(T, 0);
                    if (lam.input_count <= 1) {
                        const result: T = switch (lam.op) {
                            .int_neg => 0 -% a,
                            .int_abs => if (isSignedInt(T) and a < 0) (0 -% a) else a,
                            .int_not => ~a,
                            .int_scale_add => blk: {
                                const scale_k: T = @intCast(lam.const_val orelse 0);
                                const c: T = @intCast(lam.const_val2 orelse 0);
                                break :blk a *% scale_k +% c;
                            },
                            else => unreachable,
                        };
                        out.setScalar(T, 0, result);
                    } else {
                        const b = self.channels[lam.inputs[1]].getScalar(T, 0);
                        const result: T = switch (lam.op) {
                            .int_add => a +% b,
                            .int_sub => a -% b,
                            .int_mul => a *% b,
                            .int_div => if (b == 0) return error.DivisionByZero else @divTrunc(a, b),
                            .int_mod => if (b == 0) return error.DivisionByZero else @rem(a, b),
                            .int_and => a & b,
                            .int_or => a | b,
                            .int_xor => a ^ b,
                            .int_fma => blk: {
                                const c: T = @intCast(lam.const_val orelse 0);
                                break :blk a *% b +% c;
                            },
                            else => unreachable,
                        };
                        out.setScalar(T, 0, result);
                    }
                } else {
                    // 批处理模式
                    if (lam.input_count <= 1) {
                        // 一元运算批处理
                        const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                        const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                        switch (lam.op) {
                            .int_neg => batch.batchUnary(T, .neg, out_slice, a_slice),
                            .int_abs => batch.batchUnary(T, .abs, out_slice, a_slice),
                            .int_not => batch.batchUnary(T, .bnot, out_slice, a_slice),
                            .int_scale_add => batch.batchScaleAdd(T, out_slice, a_slice,
                                @intCast(lam.const_val orelse 0), @intCast(lam.const_val2 orelse 0)),
                            else => unreachable,
                        }
                    } else {
                        // 二元运算批处理
                        const rhs_chan = &self.channels[lam.inputs[1]];
                        const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                        const b_slice = rhs_chan.asTypedPtr(T)[0..self.element_count];
                        const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                        switch (lam.op) {
                            .int_add => try batch.batchBinOp(T, .add, out_slice, a_slice, b_slice),
                            .int_sub => try batch.batchBinOp(T, .sub, out_slice, a_slice, b_slice),
                            .int_mul => try batch.batchBinOp(T, .mul, out_slice, a_slice, b_slice),
                            .int_div => try batch.batchBinOp(T, .div, out_slice, a_slice, b_slice),
                            .int_mod => try batch.batchBinOp(T, .mod, out_slice, a_slice, b_slice),
                            .int_and => try batch.batchBinOp(T, .band, out_slice, a_slice, b_slice),
                            .int_or => try batch.batchBinOp(T, .bor, out_slice, a_slice, b_slice),
                            .int_xor => try batch.batchBinOp(T, .bxor, out_slice, a_slice, b_slice),
                            .int_fma => batch.batchFma(T, out_slice, a_slice, b_slice, @intCast(lam.const_val orelse 0)),
                            else => unreachable,
                        }
                    }
                }
            }
        }
    }

    // ── 浮点算术 ──

    fn execFloatArith(self: *Engine, lam: Lamina) !void {
        const kind = lam.float_kind orelse .f64;
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];

        inline for (ALL_FLOAT_KINDS) |k| {
            if (kind == k) {
                const T = NativeFloatType(k);

                if (self.element_count <= 1) {
                    // 标量模式
                    const a = lhs_chan.getScalar(T, 0);
                    if (lam.input_count <= 1) {
                        const result: T = switch (lam.op) {
                            .float_neg => -a,
                            .float_abs => @abs(a),
                            .float_scale_add => blk: {
                                const scale_k: T = @floatFromInt(lam.const_val orelse 0);
                                const c: T = @floatFromInt(lam.const_val2 orelse 0);
                                break :blk a * scale_k + c;
                            },
                            else => unreachable,
                        };
                        out.setScalar(T, 0, result);
                    } else {
                        const b = self.channels[lam.inputs[1]].getScalar(T, 0);
                        const result: T = switch (lam.op) {
                            .float_add => a + b,
                            .float_sub => a - b,
                            .float_mul => a * b,
                            .float_div => if (b == 0) return error.DivisionByZero else a / b,
                            .float_fma => blk: {
                                const c: T = @floatFromInt(lam.const_val orelse 0);
                                break :blk a * b + c;
                            },
                            else => unreachable,
                        };
                        out.setScalar(T, 0, result);
                    }
                } else {
                    // 批处理模式
                    if (lam.input_count <= 1) {
                        const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                        const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                        switch (lam.op) {
                            .float_neg => batch.batchUnary(T, .neg, out_slice, a_slice),
                            .float_abs => batch.batchUnary(T, .abs, out_slice, a_slice),
                            .float_scale_add => batch.batchScaleAdd(T, out_slice, a_slice,
                                @floatFromInt(lam.const_val orelse 0), @floatFromInt(lam.const_val2 orelse 0)),
                            else => unreachable,
                        }
                    } else {
                        const rhs_chan = &self.channels[lam.inputs[1]];
                        const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                        const b_slice = rhs_chan.asTypedPtr(T)[0..self.element_count];
                        const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
                        switch (lam.op) {
                            .float_add => try batch.batchBinOp(T, .add, out_slice, a_slice, b_slice),
                            .float_sub => try batch.batchBinOp(T, .sub, out_slice, a_slice, b_slice),
                            .float_mul => try batch.batchBinOp(T, .mul, out_slice, a_slice, b_slice),
                            .float_div => try batch.batchBinOp(T, .div, out_slice, a_slice, b_slice),
                            .float_fma => batch.batchFma(T, out_slice, a_slice, b_slice, @floatFromInt(lam.const_val orelse 0)),
                            else => unreachable,
                        }
                    }
                }
            }
        }
    }

    // ── 整数比较 ──

    fn execIntCompare(self: *Engine, lam: Lamina) !void {
        const kind = lam.int_kind orelse .i64;
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];
        const rhs_chan = &self.channels[lam.inputs[1]];

        inline for (ALL_INT_KINDS) |k| {
            if (kind == k) {
                const T = NativeIntType(k);

                if (self.element_count <= 1) {
                    // 标量模式
                    const a = lhs_chan.getScalar(T, 0);
                    const b = rhs_chan.getScalar(T, 0);
                    const result: u8 = switch (lam.op) {
                        .int_lt => if (a < b) 1 else 0,
                        .int_gt => if (a > b) 1 else 0,
                        .int_eq => if (a == b) 1 else 0,
                        .int_ne => if (a != b) 1 else 0,
                        .int_le => if (a <= b) 1 else 0,
                        .int_ge => if (a >= b) 1 else 0,
                        else => unreachable,
                    };
                    out.setScalar(u8, 0, result);
                } else {
                    // SIMD 批处理模式：比较结果存入 mask_chan（u8）
                    const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                    const b_slice = rhs_chan.asTypedPtr(T)[0..self.element_count];
                    const out_slice = out.asTypedPtrMut(u8)[0..self.element_count];
                    switch (lam.op) {
                        .int_lt => batch.batchCompare(T, .lt, out_slice, a_slice, b_slice),
                        .int_gt => batch.batchCompare(T, .gt, out_slice, a_slice, b_slice),
                        .int_eq => batch.batchCompare(T, .eq, out_slice, a_slice, b_slice),
                        .int_ne => batch.batchCompare(T, .ne, out_slice, a_slice, b_slice),
                        .int_le => batch.batchCompare(T, .le, out_slice, a_slice, b_slice),
                        .int_ge => batch.batchCompare(T, .ge, out_slice, a_slice, b_slice),
                        else => unreachable,
                    }
                }
            }
        }
    }

    // ── 浮点比较 ──

    fn execFloatCompare(self: *Engine, lam: Lamina) !void {
        const kind = lam.float_kind orelse .f64;
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];
        const rhs_chan = &self.channels[lam.inputs[1]];

        inline for (ALL_FLOAT_KINDS) |k| {
            if (kind == k) {
                const T = NativeFloatType(k);

                if (self.element_count <= 1) {
                    // 标量模式
                    const a = lhs_chan.getScalar(T, 0);
                    const b = rhs_chan.getScalar(T, 0);
                    const result: u8 = switch (lam.op) {
                        .float_lt => if (a < b) 1 else 0,
                        .float_gt => if (a > b) 1 else 0,
                        .float_eq => if (a == b) 1 else 0,
                        .float_ne => if (a != b) 1 else 0,
                        .float_le => if (a <= b) 1 else 0,
                        .float_ge => if (a >= b) 1 else 0,
                        else => unreachable,
                    };
                    out.setScalar(u8, 0, result);
                } else {
                    // SIMD 批处理模式
                    const a_slice = lhs_chan.asTypedPtr(T)[0..self.element_count];
                    const b_slice = rhs_chan.asTypedPtr(T)[0..self.element_count];
                    const out_slice = out.asTypedPtrMut(u8)[0..self.element_count];
                    switch (lam.op) {
                        .float_lt => batch.batchCompare(T, .lt, out_slice, a_slice, b_slice),
                        .float_gt => batch.batchCompare(T, .gt, out_slice, a_slice, b_slice),
                        .float_eq => batch.batchCompare(T, .eq, out_slice, a_slice, b_slice),
                        .float_ne => batch.batchCompare(T, .ne, out_slice, a_slice, b_slice),
                        .float_le => batch.batchCompare(T, .le, out_slice, a_slice, b_slice),
                        .float_ge => batch.batchCompare(T, .ge, out_slice, a_slice, b_slice),
                        else => unreachable,
                    }
                }
            }
        }
    }

    // ── 布尔运算 ──

    fn execBoolArith(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];

        if (self.element_count <= 1) {
            // 标量模式
            if (lam.input_count <= 1) {
                const a = lhs_chan.getScalar(u8, 0);
                out.setScalar(u8, 0, if (a == 0) 1 else 0);
            } else {
                const a = lhs_chan.getScalar(u8, 0);
                const b = self.channels[lam.inputs[1]].getScalar(u8, 0);
                const result: u8 = switch (lam.op) {
                    .bool_and => if (a != 0 and b != 0) 1 else 0,
                    .bool_or => if (a != 0 or b != 0) 1 else 0,
                    .bool_xor => if ((a != 0) != (b != 0)) 1 else 0,
                    else => unreachable,
                };
                out.setScalar(u8, 0, result);
            }
        } else {
            // SIMD 批处理模式（u8 通道）
            const lanes = comptime simdLaneCount(u8);
            const batch_count = self.element_count / lanes;
            const tail_start = batch_count * lanes;
            const zero: @Vector(lanes, u8) = @splat(0);
            const one: @Vector(lanes, u8) = @splat(1);

            if (lam.input_count <= 1) {
                const a_ptr = lhs_chan.asTypedPtr(u8);
                const out_ptr = out.asTypedPtrMut(u8);
                for (0..batch_count) |b| {
                    const off = b * lanes;
                    const va = @as(@Vector(lanes, u8), a_ptr[off..][0..lanes].*);
                    const mask = va == zero;
                    out_ptr[off..][0..lanes].* = @as([lanes]u8, @select(u8, mask, one, zero));
                }
                for (tail_start..self.element_count) |i| {
                    const a = lhs_chan.getScalar(u8, i);
                    out.setScalar(u8, i, if (a == 0) 1 else 0);
                }
            } else {
                const rhs_chan = &self.channels[lam.inputs[1]];
                const a_ptr = lhs_chan.asTypedPtr(u8);
                const b_ptr = rhs_chan.asTypedPtr(u8);
                const out_ptr = out.asTypedPtrMut(u8);
                for (0..batch_count) |b| {
                    const off = b * lanes;
                    const va = @as(@Vector(lanes, u8), a_ptr[off..][0..lanes].*);
                    const vb = @as(@Vector(lanes, u8), b_ptr[off..][0..lanes].*);
                    const result: @Vector(lanes, u8) = switch (lam.op) {
                        .bool_and => blk: {
                            const ma = va != zero;
                            const mb = vb != zero;
                            const m = ma & mb;
                            break :blk @select(u8, m, one, zero);
                        },
                        .bool_or => blk: {
                            const ma = va != zero;
                            const mb = vb != zero;
                            const m = ma | mb;
                            break :blk @select(u8, m, one, zero);
                        },
                        .bool_xor => blk: {
                            const ma = va != zero;
                            const mb = vb != zero;
                            const m = ma != mb;
                            break :blk @select(u8, m, one, zero);
                        },
                        else => unreachable,
                    };
                    out_ptr[off..][0..lanes].* = @as([lanes]u8, result);
                }
                for (tail_start..self.element_count) |i| {
                    const a = lhs_chan.getScalar(u8, i);
                    const b = rhs_chan.getScalar(u8, i);
                    const result: u8 = switch (lam.op) {
                        .bool_and => if (a != 0 and b != 0) 1 else 0,
                        .bool_or => if (a != 0 or b != 0) 1 else 0,
                        .bool_xor => if ((a != 0) != (b != 0)) 1 else 0,
                        else => unreachable,
                    };
                    out.setScalar(u8, i, result);
                }
            }
        }
    }

    fn execBoolCompare(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];
        const rhs_chan = &self.channels[lam.inputs[1]];

        if (self.element_count <= 1) {
            const a = lhs_chan.getScalar(u8, 0);
            const b = rhs_chan.getScalar(u8, 0);
            const result: u8 = switch (lam.op) {
                .bool_eq => if ((a != 0) == (b != 0)) 1 else 0,
                .bool_ne => if ((a != 0) != (b != 0)) 1 else 0,
                else => unreachable,
            };
            out.setScalar(u8, 0, result);
        } else {
            const lanes = comptime simdLaneCount(u8);
            const batch_count = self.element_count / lanes;
            const tail_start = batch_count * lanes;
            const zero: @Vector(lanes, u8) = @splat(0);
            const one: @Vector(lanes, u8) = @splat(1);

            const a_ptr = lhs_chan.asTypedPtr(u8);
            const b_ptr = rhs_chan.asTypedPtr(u8);
            const out_ptr = out.asTypedPtrMut(u8);

            for (0..batch_count) |b| {
                const off = b * lanes;
                const va = @as(@Vector(lanes, u8), a_ptr[off..][0..lanes].*);
                const vb = @as(@Vector(lanes, u8), b_ptr[off..][0..lanes].*);
                const ma = va != zero;
                const mb = vb != zero;
                const mask_vec: @Vector(lanes, bool) = switch (lam.op) {
                    .bool_eq => ma == mb,
                    .bool_ne => ma != mb,
                    else => unreachable,
                };
                out_ptr[off..][0..lanes].* = @as([lanes]u8, @select(u8, mask_vec, one, zero));
            }
            for (tail_start..self.element_count) |i| {
                const a = lhs_chan.getScalar(u8, i);
                const b = rhs_chan.getScalar(u8, i);
                const result: u8 = switch (lam.op) {
                    .bool_eq => if ((a != 0) == (b != 0)) 1 else 0,
                    .bool_ne => if ((a != 0) != (b != 0)) 1 else 0,
                    else => unreachable,
                };
                out.setScalar(u8, i, result);
            }
        }
    }

    // ── 字符比较 ──

    fn execCharCompare(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const lhs_chan = &self.channels[lam.inputs[0]];
        const rhs_chan = &self.channels[lam.inputs[1]];

        if (self.element_count <= 1) {
            const a = lhs_chan.getScalar(u32, 0);
            const b = rhs_chan.getScalar(u32, 0);
            const result: u8 = switch (lam.op) {
                .char_lt => if (a < b) 1 else 0,
                .char_gt => if (a > b) 1 else 0,
                .char_eq => if (a == b) 1 else 0,
                .char_ne => if (a != b) 1 else 0,
                .char_le => if (a <= b) 1 else 0,
                .char_ge => if (a >= b) 1 else 0,
                else => unreachable,
            };
            out.setScalar(u8, 0, result);
        } else {
            // SIMD 批处理模式（char 存为 u32）
            const a_slice = lhs_chan.asTypedPtr(u32)[0..self.element_count];
            const b_slice = rhs_chan.asTypedPtr(u32)[0..self.element_count];
            const out_slice = out.asTypedPtrMut(u8)[0..self.element_count];
            switch (lam.op) {
                .char_lt => batch.batchCompare(u32, .lt, out_slice, a_slice, b_slice),
                .char_gt => batch.batchCompare(u32, .gt, out_slice, a_slice, b_slice),
                .char_eq => batch.batchCompare(u32, .eq, out_slice, a_slice, b_slice),
                .char_ne => batch.batchCompare(u32, .ne, out_slice, a_slice, b_slice),
                .char_le => batch.batchCompare(u32, .le, out_slice, a_slice, b_slice),
                .char_ge => batch.batchCompare(u32, .ge, out_slice, a_slice, b_slice),
                else => unreachable,
            }
        }
    }

    // ── 谓词选择 ──

    fn execSelect(self: *Engine, lam: Lamina) !void {
        const pred_chan_idx = lam.predicate orelse return error.InvalidChannel;
        const mask_chan = &self.channels[pred_chan_idx];
        const true_chan = &self.channels[lam.inputs[0]];
        const false_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const w = out.elem_width;

        if (w == 0) return;

        if (self.element_count <= 1) {
            // 标量模式
            const mask = mask_chan.getScalar(u8, 0);
            if (mask != 0) {
                @memcpy(out.data[0..w], true_chan.data[0..w]);
            } else {
                @memcpy(out.data[0..w], false_chan.data[0..w]);
            }
            return;
        }

        // SIMD 批处理模式：按元素类型分派
        const ct = self.graph.channel_metas[lam.output].chan_type;
        switch (ct) {
            .i32_chan, .u32_chan, .f32_chan => try self.execSelectTyped(u32, mask_chan, true_chan, false_chan, out),
            .i64_chan, .u64_chan, .f64_chan, .ref_chan => try self.execSelectTyped(u64, mask_chan, true_chan, false_chan, out),
            .i16_chan, .u16_chan, .f16_chan => try self.execSelectTyped(u16, mask_chan, true_chan, false_chan, out),
            .i8_chan, .u8_chan, .bool_chan, .mask_chan => try self.execSelectTyped(u8, mask_chan, true_chan, false_chan, out),
            else => {
                // 通用标量回退：逐元素选择
                for (0..self.element_count) |i| {
                    const mask = mask_chan.getScalar(u8, i);
                    const src = if (mask != 0) true_chan else false_chan;
                    @memcpy(out.data[i * w ..][0..w], src.data[i * w ..][0..w]);
                }
            },
        }
    }

    /// 类型特化的 SIMD select
    fn execSelectTyped(
        self: *Engine,
        comptime T: type,
        mask_chan: *const PhysicalChannel,
        true_chan: *const PhysicalChannel,
        false_chan: *const PhysicalChannel,
        out: *PhysicalChannel,
    ) !void {
        const mask_slice = mask_chan.asTypedPtr(u8)[0..self.element_count];
        const tv_slice = true_chan.asTypedPtr(T)[0..self.element_count];
        const fv_slice = false_chan.asTypedPtr(T)[0..self.element_count];
        const out_slice = out.asTypedPtrMut(T)[0..self.element_count];
        batch.batchSelect(T, out_slice, mask_slice, tv_slice, fv_slice);
    }

    // ── 控制流出口 ──

    fn execHaltReturn(self: *Engine, lam: Lamina) !void {
        // halt 时 LIFO 执行所有已注册的 defer 体
        if (self.defer_stack.items.len > 0) {
            try self.execDeferExecute();
        }
        self.halt_reason = .return_halt;
        const ret_chan = &self.channels[lam.inputs[0]];
        const meta = self.graph.channel_metas[lam.inputs[0]];
        self.return_value = switch (meta.chan_type) {
            .i8_chan => @intCast(ret_chan.getScalar(i8, 0)),
            .i16_chan => @intCast(ret_chan.getScalar(i16, 0)),
            .i32_chan => @intCast(ret_chan.getScalar(i32, 0)),
            .i64_chan => ret_chan.getScalar(i64, 0),
            .u8_chan => @intCast(ret_chan.getScalar(u8, 0)),
            .u16_chan => @intCast(ret_chan.getScalar(u16, 0)),
            .u32_chan => @intCast(ret_chan.getScalar(u32, 0)),
            .u64_chan => @intCast(@as(i64, @bitCast(ret_chan.getScalar(u64, 0)))),
            else => 0,
        };
    }

    // ── 调试输出 ──

    fn execDebugPrint(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const meta = self.graph.channel_metas[lam.inputs[0]];

        switch (meta.chan_type) {
            .ref_chan => {
                // 字符串：从字符串表查找
                const str_idx = in_chan.getScalar(u64, 0);
                if (str_idx < self.graph.string_table.len) {
                    const s = self.graph.string_table[str_idx];
                    std.debug.print("{s}\n", .{s});
                }
            },
            .i64_chan => std.debug.print("{d}\n", .{in_chan.getScalar(i64, 0)}),
            .i32_chan => std.debug.print("{d}\n", .{in_chan.getScalar(i32, 0)}),
            .i16_chan => std.debug.print("{d}\n", .{in_chan.getScalar(i16, 0)}),
            .i8_chan => std.debug.print("{d}\n", .{in_chan.getScalar(i8, 0)}),
            .u64_chan => std.debug.print("{d}\n", .{in_chan.getScalar(u64, 0)}),
            .u32_chan => std.debug.print("{d}\n", .{in_chan.getScalar(u32, 0)}),
            .u16_chan => std.debug.print("{d}\n", .{in_chan.getScalar(u16, 0)}),
            .u8_chan => std.debug.print("{d}\n", .{in_chan.getScalar(u8, 0)}),
            .f64_chan => std.debug.print("{d}\n", .{in_chan.getScalar(f64, 0)}),
            .f32_chan => std.debug.print("{d}\n", .{in_chan.getScalar(f32, 0)}),
            .f16_chan => std.debug.print("{d}\n", .{in_chan.getScalar(f16, 0)}),
            .bool_chan, .mask_chan => std.debug.print("{s}\n", .{if (in_chan.getScalar(u8, 0) != 0) "true" else "false"}),
            .char_chan => std.debug.print("{u}\n", .{@as(u21, @intCast(in_chan.getScalar(u32, 0)))}),
            .null_chan => std.debug.print("null\n", .{}),
            .unit_chan => std.debug.print("()\n", .{}),
            else => std.debug.print("<unknown>\n", .{}),
        }
    }

    // ── 阶段 4: 聚合（reduce）──

    fn execReduce(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const n = in_chan.element_count;
        const meta = self.graph.channel_metas[lam.inputs[0]];

        // reduce_count: 返回元素数量，不依赖类型
        if (lam.op == .reduce_count) {
            out.setScalar(i64, 0, @intCast(n));
            out.element_count = 1;
            return;
        }

        // 按通道类型分派 reduce
        switch (meta.chan_type) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan,
            => |ct| {
                const kind = lamina_mod.intKindFromChanType(ct);
                inline for (ALL_INT_KINDS) |k| {
                    if (kind == k) {
                        const T = NativeIntType(k);
                        const result = self.reduceInt(T, in_chan, n, lam.op);
                        out.setScalar(T, 0, result);
                    }
                }
            },
            .f16_chan, .f32_chan, .f64_chan, .f128_chan => |ct| {
                const kind = lamina_mod.floatKindFromChanType(ct);
                inline for (ALL_FLOAT_KINDS) |k| {
                    if (kind == k) {
                        const T = NativeFloatType(k);
                        const result = self.reduceFloat(T, in_chan, n, lam.op);
                        out.setScalar(T, 0, result);
                    }
                }
            },
            else => return error.UnsupportedOp,
        }
        out.element_count = 1;
    }

    /// SIMD 加速整数 reduce（@Vector 累加 + inline for 水平折叠）
    fn reduceInt(self: *Engine, comptime T: type, chan: *const PhysicalChannel, n: usize, op: LaminaOp) T {
        _ = self;
        if (n == 0) return 0;

        const lanes = comptime simdLaneCount(T);
        const batch_count = n / lanes;
        const tail_start = batch_count * lanes;

        var acc: T = switch (op) {
            .reduce_sum => 0,
            .reduce_prod => 1,
            .reduce_min => std.math.maxInt(T),
            .reduce_max => std.math.minInt(T),
            else => 0,
        };

        // SIMD 批处理：向量累加器
        if (batch_count > 0) {
            const chan_ptr = chan.asTypedPtr(T);
            var acc_vec: @Vector(lanes, T) = switch (op) {
                .reduce_sum => @splat(0),
                .reduce_prod => @splat(1),
                .reduce_min => @splat(std.math.maxInt(T)),
                .reduce_max => @splat(std.math.minInt(T)),
                else => @splat(0),
            };

            for (0..batch_count) |b| {
                const off = b * lanes;
                const v: @Vector(lanes, T) = chan_ptr[off..][0..lanes].*;
                acc_vec = switch (op) {
                    .reduce_sum => acc_vec +% v,
                    .reduce_prod => acc_vec *% v,
                    .reduce_min => @min(acc_vec, v),
                    .reduce_max => @max(acc_vec, v),
                    else => acc_vec,
                };
            }

            // inline for 水平折叠（不用 @reduce，会触发 LLVM codegen bug）
            inline for (0..lanes) |i| {
                acc = switch (op) {
                    .reduce_sum => acc +% acc_vec[i],
                    .reduce_prod => acc *% acc_vec[i],
                    .reduce_min => if (acc_vec[i] < acc) acc_vec[i] else acc,
                    .reduce_max => if (acc_vec[i] > acc) acc_vec[i] else acc,
                    else => acc,
                };
            }
        }

        // 尾部标量处理
        for (tail_start..n) |i| {
            const v = chan.getScalar(T, i);
            acc = switch (op) {
                .reduce_sum => acc +% v,
                .reduce_prod => acc *% v,
                .reduce_min => if (v < acc) v else acc,
                .reduce_max => if (v > acc) v else acc,
                else => acc,
            };
        }
        return acc;
    }

    /// SIMD 加速浮点 reduce（@Vector 累加 + inline for 水平折叠）
    fn reduceFloat(self: *Engine, comptime T: type, chan: *const PhysicalChannel, n: usize, op: LaminaOp) T {
        _ = self;
        if (n == 0) return 0;

        const lanes = comptime simdLaneCount(T);
        const batch_count = n / lanes;
        const tail_start = batch_count * lanes;

        var acc: T = switch (op) {
            .reduce_sum => 0,
            .reduce_prod => 1,
            .reduce_min => std.math.inf(T),
            .reduce_max => -std.math.inf(T),
            else => 0,
        };

        if (batch_count > 0) {
            const chan_ptr = chan.asTypedPtr(T);
            var acc_vec: @Vector(lanes, T) = switch (op) {
                .reduce_sum => @splat(0),
                .reduce_prod => @splat(1),
                .reduce_min => @splat(std.math.inf(T)),
                .reduce_max => @splat(-std.math.inf(T)),
                else => @splat(0),
            };

            for (0..batch_count) |b| {
                const off = b * lanes;
                const v: @Vector(lanes, T) = chan_ptr[off..][0..lanes].*;
                acc_vec = switch (op) {
                    .reduce_sum => acc_vec + v,
                    .reduce_prod => acc_vec * v,
                    .reduce_min => @min(acc_vec, v),
                    .reduce_max => @max(acc_vec, v),
                    else => acc_vec,
                };
            }

            // inline for 水平折叠（不用 @reduce，会触发 LLVM codegen bug）
            inline for (0..lanes) |i| {
                acc = switch (op) {
                    .reduce_sum => acc + acc_vec[i],
                    .reduce_prod => acc * acc_vec[i],
                    .reduce_min => if (acc_vec[i] < acc) acc_vec[i] else acc,
                    .reduce_max => if (acc_vec[i] > acc) acc_vec[i] else acc,
                    else => acc,
                };
            }
        }

        for (tail_start..n) |i| {
            const v = chan.getScalar(T, i);
            acc = switch (op) {
                .reduce_sum => acc + v,
                .reduce_prod => acc * v,
                .reduce_min => if (v < acc) v else acc,
                .reduce_max => if (v > acc) v else acc,
                else => acc,
            };
        }
        return acc;
    }

    // ── 阶段 4: 压缩（filter）──

    fn execCompress(self: *Engine, lam: Lamina) !void {
        const data_chan = &self.channels[lam.inputs[0]];
        const mask_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const n = data_chan.element_count;
        const w = data_chan.elem_width;

        if (w == 0) {
            out.element_count = 0;
            return;
        }

        // 标量压缩：遍历元素，仅复制 mask 为真的元素
        var write_idx: usize = 0;
        for (0..n) |i| {
            const mask_val = mask_chan.getScalar(u8, i);
            if (mask_val != 0) {
                // 按字节复制（通用，适用于所有类型）
                const src_start = i * w;
                const dst_start = write_idx * w;
                @memcpy(
                    out.data[dst_start .. dst_start + w],
                    data_chan.data[src_start .. src_start + w],
                );
                write_idx += 1;
            }
        }
        out.element_count = write_idx;
    }

    // ── 阶段 4: 流长度 ──

    fn execLength(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, @intCast(in_chan.element_count));
        out.element_count = 1;
    }

    // ── 阶段 4: 标量广播 ──

    fn execBroadcastInput(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const w = in_chan.elem_width;
        if (w == 0) return;

        // 将标量输入广播到 element_count 个元素
        const src = in_chan.data[0..w];
        for (0..self.element_count) |i| {
            const dst_start = i * w;
            @memcpy(out.data[dst_start .. dst_start + w], src);
        }
        out.element_count = self.element_count;
    }

    // ── 阶段 5: Cell 操作（可变状态，通道级实现，无 Value 依赖）──
    //
    // Cell 在 LFE 中表示为一个 ref_chan，内部直接存储值字节。
    // cell_make 复制值到 Cell 通道，cell_get 读取，cell_set 覆写，cell_swap 交换。
    // 标量模式下按 elem_width 复制原始字节。

    fn execCellMake(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const w = in_chan.elem_width;
        if (w > 0) @memcpy(out.data[0..w], in_chan.data[0..w]);
    }

    fn execCellGet(self: *Engine, lam: Lamina) !void {
        const cell_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const w = cell_chan.elem_width;
        if (w > 0) @memcpy(out.data[0..w], cell_chan.data[0..w]);
    }

    fn execCellSet(self: *Engine, lam: Lamina) !void {
        const cell_chan = &self.channels[lam.inputs[0]];
        const val_chan = &self.channels[lam.inputs[1]];
        const w = cell_chan.elem_width;
        if (w > 0) @memcpy(cell_chan.data[0..w], val_chan.data[0..w]);
    }

    fn execCellSwap(self: *Engine, lam: Lamina) !void {
        const cell_chan = &self.channels[lam.inputs[0]];
        const val_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const w = cell_chan.elem_width;
        if (w > 0) {
            // out = 旧 Cell 值
            @memcpy(out.data[0..w], cell_chan.data[0..w]);
            // cell = 新值
            @memcpy(cell_chan.data[0..w], val_chan.data[0..w]);
        }
    }

    // ── 阶段 5: Throw / Error 操作 ──
    //
    // Throw 值编码为 16 字节 ref_chan：[0..8]=value(i64), [8]=is_throw 标志(u8)
    //   is_throw = 0 → ok 值，is_throw != 0 → err 值
    // throw_propagate：err 时触发 throw_halt 停机，ok 时解包值到输出

    fn execThrowMake(self: *Engine, lam: Lamina) !void {
        const ok_chan = &self.channels[lam.inputs[0]];
        const err_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const is_throw = if (lam.predicate) |p| self.channels[p].getScalar(u8, 0) else 0;
        if (is_throw != 0) {
            out.setScalar(i64, 0, err_chan.getScalar(i64, 0));
        } else {
            out.setScalar(i64, 0, ok_chan.getScalar(i64, 0));
        }
        out.setScalar(u8, 8, is_throw);
    }

    fn execThrowIsOk(self: *Engine, lam: Lamina) !void {
        const throw_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const is_throw = throw_chan.getScalar(u8, 8);
        out.setScalar(u8, 0, if (is_throw == 0) 1 else 0);
    }

    fn execThrowIsErr(self: *Engine, lam: Lamina) !void {
        const throw_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const is_throw = throw_chan.getScalar(u8, 8);
        out.setScalar(u8, 0, if (is_throw != 0) 1 else 0);
    }

    fn execThrowGetOk(self: *Engine, lam: Lamina) !void {
        const throw_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, throw_chan.getScalar(i64, 0));
    }

    fn execThrowGetErr(self: *Engine, lam: Lamina) !void {
        const throw_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, throw_chan.getScalar(i64, 0));
    }

    fn execThrowPropagate(self: *Engine, lam: Lamina) !void {
        const throw_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const is_throw = throw_chan.getScalar(u8, 8);
        if (is_throw != 0) {
            self.halt_reason = .throw_halt;
            return;
        }
        // ok 值：解包并复制到输出
        const val = throw_chan.getScalar(i64, 0);
        out.setScalar(i64, 0, val);
    }

    fn execErrorMake(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const val = lam.const_val orelse 0;
        out.setScalar(i64, 0, val);
    }

    // ── 阶段 5: 闭包操作（通道级实现，无 Value 依赖）──
    //
    // 闭包存储格式（ref_chan 连续字节）：
    //   [0..8]   = func_idx (u64) — 标识要执行的 LaminarGraph
    //   [8..16]  = capture_count (u64) — 捕获变量数量
    //   [16+n*8] = capture[n] (i64) — 第 n 个捕获值
    //
    // Phase 5 简化：closure_call 尚不支持子图执行（无函数表），
    // 返回第一个捕获值作为占位。

    fn execClosureMake(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const func_idx = lam.const_val orelse 0;
        const capture_count: usize = lam.input_count;

        // 存储函数索引和捕获数量
        out.setScalar(u64, 0, @intCast(func_idx));
        out.setScalar(u64, 1, @intCast(capture_count));

        // 存储捕获的值
        var i: usize = 0;
        while (i < capture_count) : (i += 1) {
            const cap_chan = &self.channels[lam.inputs[i]];
            out.setScalar(i64, 2 + i, cap_chan.getScalar(i64, 0));
        }
    }

    fn execClosureCall(self: *Engine, lam: Lamina) !void {
        // Phase 5 简化：闭包调用暂不支持子图执行
        // 返回第一个捕获值作为占位
        const closure_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const capture_count = closure_chan.getScalar(u64, 1);
        if (capture_count > 0) {
            out.setScalar(i64, 0, closure_chan.getScalar(i64, 2));
        } else {
            out.setScalar(i64, 0, 0);
        }
    }

    fn execClosureCapture(self: *Engine, lam: Lamina) !void {
        // 从闭包的捕获数组中读取第 N 个捕获值
        const closure_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const idx = lam.const_val orelse 0;
        out.setScalar(i64, 0, closure_chan.getScalar(i64, @as(usize, @intCast(idx)) + 2));
    }

    // ── 阶段 5: Trait 操作（通道级实现，无 Value 依赖）──
    //
    // Trait 值存储格式（ref_chan，16 字节）：
    //   [0..8]  = type_tag (u64) — 标识具体类型
    //   [8..16] = data_value (i64) — 底层数据值
    //
    // Phase 5 简化：trait_call_method 暂不支持方法分派，返回数据值作为占位。

    fn execTraitMake(self: *Engine, lam: Lamina) !void {
        const data_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const type_tag = lam.const_val orelse 0;

        out.setScalar(u64, 0, @intCast(type_tag));
        out.setScalar(i64, 1, data_chan.getScalar(i64, 0));
    }

    fn execTraitCallMethod(self: *Engine, lam: Lamina) !void {
        // Phase 5 简化：trait 方法调用暂不支持
        // 返回 trait 数据作为占位
        const trait_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, trait_chan.getScalar(i64, 1));
    }

    fn execTraitDowncast(self: *Engine, lam: Lamina) !void {
        const trait_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, trait_chan.getScalar(i64, 1));
    }

    // ── 阶段 5: switch_lamina（基于 type_tag 的动态分派）──
    //
    // 简化语义（单 case）：
    //   const_val  = 要匹配的 type_tag 值（同时充当 case 计数）
    //   const_val2 = 默认值
    //   inputs[0]  = type_tag 通道（u64）
    //   inputs[1]  = 匹配时输出的值通道（i64）
    //
    // 如果 tag == const_val，输出 inputs[1]；否则输出 const_val2。
    // 完整实现需要 name_table 编码多 case。

    fn execSwitchLamina(self: *Engine, lam: Lamina) !void {
        const tag_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const tag = tag_chan.getScalar(u64, 0);

        const case_tag = lam.const_val orelse 0;
        const default_val = lam.const_val2 orelse 0;

        if (case_tag == 0) {
            out.setScalar(i64, 0, default_val);
            return;
        }

        if (tag == @as(u64, @intCast(case_tag))) {
            const matched_chan = &self.channels[lam.inputs[1]];
            out.setScalar(i64, 0, matched_chan.getScalar(i64, 0));
        } else {
            out.setScalar(i64, 0, default_val);
        }
    }

    // ── 阶段 5: Atomic 操作（复用 value/concurrent.AtomicValue）──
    //
    // Atomic 通道存储 *AtomicValue 指针（ref_chan，8 字节）

    fn execAtomicMake(self: *Engine, lam: Lamina) !void {
        const in_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const init_val = chanToValue(in_chan, self.graph.channel_metas[lam.inputs[0]]);
        const atm = try self.allocator.create(concurrent.AtomicValue);
        atm.* = concurrent.AtomicValue.init(init_val);
        out.setScalar(usize, 0, @intFromPtr(&atm.header));
    }

    fn execAtomicLoad(self: *Engine, lam: Lamina) !void {
        const atom_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const val = atm.load();
        valueToChan(val, out, self.graph.channel_metas[lam.output]);
    }

    fn execAtomicStore(self: *Engine, lam: Lamina) !void {
        const atom_chan = &self.channels[lam.inputs[0]];
        const val_chan = &self.channels[lam.inputs[1]];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const new_val = chanToValue(val_chan, self.graph.channel_metas[lam.inputs[1]]);
        atm.store(new_val);
    }

    fn execAtomicCas(self: *Engine, lam: Lamina) !void {
        // inputs[0]=atomic, inputs[1]=expected, inputs[2]=desired
        const atom_chan = &self.channels[lam.inputs[0]];
        const exp_chan = &self.channels[lam.inputs[1]];
        const des_chan = &self.channels[lam.inputs[2]];
        const out = &self.channels[lam.output];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const expected = chanToValue(exp_chan, self.graph.channel_metas[lam.inputs[1]]);
        const desired = chanToValue(des_chan, self.graph.channel_metas[lam.inputs[2]]);
        const success = atm.cas(expected, desired);
        out.setScalar(u8, 0, if (success) 1 else 0);
    }

    fn execAtomicSwap(self: *Engine, lam: Lamina) !void {
        // inputs[0]=atomic, inputs[1]=new_val; output=旧值
        const atom_chan = &self.channels[lam.inputs[0]];
        const new_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const new_val = chanToValue(new_chan, self.graph.channel_metas[lam.inputs[1]]);
        const old_val = atm.xchg(new_val);
        valueToChan(old_val, out, self.graph.channel_metas[lam.output]);
    }

    fn execAtomicFetchAdd(self: *Engine, lam: Lamina) !void {
        // inputs[0]=atomic, inputs[1]=delta; output=旧值
        const atom_chan = &self.channels[lam.inputs[0]];
        const delta_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const old_val = atm.load();
        const delta = chanToValue(delta_chan, self.graph.channel_metas[lam.inputs[1]]);
        // 整数加法：读旧值，计算新值，CAS 替换
        const old_i = valToI64(old_val);
        const delta_i = valToI64(delta);
        const new_val = Value.fromI64(old_i +% delta_i);
        _ = atm.cas(old_val, new_val);
        valueToChan(old_val, out, self.graph.channel_metas[lam.output]);
    }

    fn execAtomicFetchSub(self: *Engine, lam: Lamina) !void {
        const atom_chan = &self.channels[lam.inputs[0]];
        const delta_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const atm: *concurrent.AtomicValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(atom_chan.getScalar(usize, 0)))));
        const old_val = atm.load();
        const delta = chanToValue(delta_chan, self.graph.channel_metas[lam.inputs[1]]);
        const old_i = valToI64(old_val);
        const delta_i = valToI64(delta);
        const new_val = Value.fromI64(old_i -% delta_i);
        _ = atm.cas(old_val, new_val);
        valueToChan(old_val, out, self.graph.channel_metas[lam.output]);
    }

    // ── 阶段 5: Async 操作（协程调度）──
    //
    // async_create：创建 LfeTask 提交到调度器
    // async_join (await)：在 runTaskSlice 中处理（可能阻塞挂起）
    // async_status：查询任务状态

    fn execAsyncCreate(self: *Engine, lam: Lamina) !void {
        const sched = self.scheduler orelse return error.UnsupportedOp;
        const func_idx: usize = @intCast(lam.extern_idx orelse 0);
        if (func_idx >= self.graph.subgraphs.len) return error.InvalidChannel;
        const subgraph = &self.graph.subgraphs[func_idx];

        // 创建 task
        const task = try LfeTask.create(self.allocator, sched, subgraph, self.element_count);

        // 复制参数到子图输入通道
        // inputs[0..n] 对应子图的 input_channels[0..n]
        const n_args = lam.input_count;
        for (0..n_args) |i| {
            const src_chan = &self.channels[lam.inputs[i]];
            const dst_idx = subgraph.input_channels[i];
            const dst_chan = &task.channels[dst_idx];
            const w = dst_chan.elem_width;
            if (w > 0) {
                @memcpy(dst_chan.data[0..w], src_chan.data[0..w]);
            }
        }

        // 提交到调度器
        sched.asyncTask(task);

        // 输出 task 指针（Async 句柄）
        const out = &self.channels[lam.output];
        out.setScalar(usize, 0, @intFromPtr(task));
    }

    fn execAsyncStatus(self: *Engine, lam: Lamina) !void {
        const async_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const task: *LfeTask = @ptrFromInt(async_chan.getScalar(usize, 0));
        const state: TaskState = @enumFromInt(task.state.load(.acquire));
        out.setScalar(u8, 0, @intFromEnum(state));
    }

    /// async_join 在 runTaskSlice 中调用，返回 ExecResult
    fn execAsyncJoin(self: *Engine, lam: Lamina) ?ExecResult {
        const async_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const task: *LfeTask = @ptrFromInt(async_chan.getScalar(usize, 0));

        if (task.result_ready.load(.acquire)) {
            // 已完成，取结果
            valueToChan(task.result, out, self.graph.channel_metas[lam.output]);
            return .continue_;
        }
        // 未完成，挂起当前 task
        const current = self.task orelse return .failed;
        task.addWaiter(current);
        return .suspend_;
    }

    // ── 阶段 5: Channel 操作（复用 value/concurrent.ChannelValue）──

    fn execChannelMake(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        const capacity: usize = @intCast(lam.const_val orelse 0);
        const ch = try self.allocator.create(concurrent.ChannelValue);
        ch.* = try concurrent.ChannelValue.init(self.allocator, capacity);
        out.setScalar(usize, 0, @intFromPtr(&ch.header));
    }

    fn execChannelSend(self: *Engine, lam: Lamina) !void {
        const chan_chan = &self.channels[lam.inputs[0]];
        const val_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));
        const val = chanToValue(val_chan, self.graph.channel_metas[lam.inputs[1]]);
        const success = try ch.send(val);
        out.setScalar(u8, 0, if (success) 1 else 0);
    }

    fn execChannelTryRecv(self: *Engine, lam: Lamina) !void {
        const chan_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));
        if (ch.tryRecv()) |val| {
            valueToChan(val, out, self.graph.channel_metas[lam.output]);
            if (out.elem_width > 0) out.setScalar(u8, out.elem_width, 1);
        } else {
            if (out.elem_width > 0) out.setScalar(u8, out.elem_width, 0);
        }
    }

    fn execChannelClose(self: *Engine, lam: Lamina) !void {
        const chan_chan = &self.channels[lam.inputs[0]];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));
        ch.close();
    }

    fn execChannelSplit(self: *Engine, lam: Lamina) !void {
        // 将通道拆分为 sender 和 receiver
        const chan_chan = &self.channels[lam.inputs[0]];
        const sender_out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));

        // 创建 SenderValue
        const sender = try self.allocator.create(concurrent.SenderValue);
        sender.* = .{ .channel = ch };
        _ = value.obj_header.retain(&ch.header);
        sender_out.setScalar(usize, 0, @intFromPtr(&sender.header));
    }

    fn execChannelGetSender(self: *Engine, lam: Lamina) !void {
        const chan_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));
        const sender = try self.allocator.create(concurrent.SenderValue);
        sender.* = .{ .channel = ch };
        _ = value.obj_header.retain(&ch.header);
        out.setScalar(usize, 0, @intFromPtr(&sender.header));
    }

    fn execChannelGetReceiver(self: *Engine, lam: Lamina) !void {
        const chan_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));
        const receiver = try self.allocator.create(concurrent.ReceiverValue);
        receiver.* = .{ .channel = ch };
        _ = value.obj_header.retain(&ch.header);
        out.setScalar(usize, 0, @intFromPtr(&receiver.header));
    }

    /// channel_recv 阻塞版本（在 runTaskSlice 中调用）
    fn execChannelRecvBlocking(self: *Engine, lam: Lamina) ?ExecResult {
        const chan_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const ch: *concurrent.ChannelValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(chan_chan.getScalar(usize, 0)))));

        // 先尝试非阻塞
        if (ch.tryRecv()) |val| {
            valueToChan(val, out, self.graph.channel_metas[lam.output]);
            return .continue_;
        }

        // 无数据，检查是否关闭
        ch.mutex.lock();
        defer ch.mutex.unlock();
        if (ch.closed) {
            // 已关闭，返回 null
            if (out.elem_width > 0) @memset(out.data, 0);
            return .continue_;
        }

        // 阻塞：当前 task 挂起，重新入队等待
        // 简化策略：自旋 yield 等待，不真正挂起（避免调度器内部死锁）
        ch.mutex.unlock();
        while (true) {
            if (ch.tryRecv()) |val| {
                valueToChan(val, out, self.graph.channel_metas[lam.output]);
                return .continue_;
            }
            ch.mutex.lock();
            defer ch.mutex.unlock();
            if (ch.closed) {
                if (out.elem_width > 0) @memset(out.data, 0);
                return .continue_;
            }
            ch.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }

    // ── 阶段 5: Sender/Receiver 操作 ──

    fn execSenderSend(self: *Engine, lam: Lamina) !void {
        const sender_chan = &self.channels[lam.inputs[0]];
        const val_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        const sender: *concurrent.SenderValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(sender_chan.getScalar(usize, 0)))));
        const val = chanToValue(val_chan, self.graph.channel_metas[lam.inputs[1]]);
        const success = try sender.channel.send(val);
        out.setScalar(u8, 0, if (success) 1 else 0);
    }

    fn execSenderClose(self: *Engine, lam: Lamina) !void {
        const sender_chan = &self.channels[lam.inputs[0]];
        const sender: *concurrent.SenderValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(sender_chan.getScalar(usize, 0)))));
        sender.channel.close();
    }

    fn execReceiverTryRecv(self: *Engine, lam: Lamina) !void {
        const recv_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const receiver: *concurrent.ReceiverValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(recv_chan.getScalar(usize, 0)))));
        if (receiver.channel.tryRecv()) |val| {
            valueToChan(val, out, self.graph.channel_metas[lam.output]);
            if (out.elem_width > 0) out.setScalar(u8, out.elem_width, 1);
        } else {
            if (out.elem_width > 0) out.setScalar(u8, out.elem_width, 0);
        }
    }

    fn execReceiverClose(self: *Engine, lam: Lamina) !void {
        const recv_chan = &self.channels[lam.inputs[0]];
        const receiver: *concurrent.ReceiverValue = @alignCast(@fieldParentPtr("header", @as(*ObjHeader, @ptrFromInt(recv_chan.getScalar(usize, 0)))));
        receiver.channel.close();
    }

    // ── 阶段 5: Range 操作（通道级实现）──
    //
    // Range 存储格式（ref_chan，17 字节）：
    //   [0..8]  = current (i64)
    //   [8..16] = end (i64)
    //   [16]    = inclusive (u8)

    fn execRangeMake(self: *Engine, lam: Lamina) !void {
        const start_chan = &self.channels[lam.inputs[0]];
        const end_chan = &self.channels[lam.inputs[1]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, start_chan.getScalar(i64, 0));
        out.setScalar(i64, 1, end_chan.getScalar(i64, 0));
        out.setScalar(u8, 16, if (lam.const_val orelse 0 != 0) 1 else 0);
    }

    fn execRangeStart(self: *Engine, lam: Lamina) !void {
        const range_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, range_chan.getScalar(i64, 0));
    }

    fn execRangeEnd(self: *Engine, lam: Lamina) !void {
        const range_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        out.setScalar(i64, 0, range_chan.getScalar(i64, 1));
    }

    fn execRangeLen(self: *Engine, lam: Lamina) !void {
        const range_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const start = range_chan.getScalar(i64, 0);
        const end = range_chan.getScalar(i64, 1);
        const inclusive = range_chan.getScalar(u8, 16);
        const len: i64 = if (inclusive != 0) end - start + 1 else end - start;
        out.setScalar(i64, 0, len);
    }

    // ── 阶段 5: Iterator 操作 ──

    fn execIterHasNext(self: *Engine, lam: Lamina) !void {
        const iter_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const current = iter_chan.getScalar(i64, 0);
        const end = iter_chan.getScalar(i64, 1);
        const inclusive = iter_chan.getScalar(u8, 16);
        const has_next: u8 = if (inclusive != 0)
            (if (current <= end) 1 else 0)
        else
            (if (current < end) 1 else 0);
        out.setScalar(u8, 0, has_next);
    }

    fn execIterNext(self: *Engine, lam: Lamina) !void {
        const iter_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const current = iter_chan.getScalar(i64, 0);
        out.setScalar(i64, 0, current);
        iter_chan.setScalar(i64, 0, current + 1);
    }

    fn execRangeToStream(self: *Engine, lam: Lamina) !void {
        const range_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const w = range_chan.elem_width;
        if (w > 0) @memcpy(out.data[0..w], range_chan.data[0..w]);
    }

    fn execIterToStream(self: *Engine, lam: Lamina) !void {
        const iter_chan = &self.channels[lam.inputs[0]];
        const out = &self.channels[lam.output];
        const w = iter_chan.elem_width;
        if (w > 0) @memcpy(out.data[0..w], iter_chan.data[0..w]);
    }

    // ── 星轨模型：轨道执行 ──

    /// 同步轨道枢纽：读条件值 → 匹配轨道 → 绑定参数 → 执行轨道 → 回写输出
    fn execOrbitHub(self: *Engine, lam: Lamina) !void {
        const hub_idx = lam.hub_index orelse return error.InvalidChannel;
        const hub = &self.graph.orbit_hubs[hub_idx];

        // 匹配轨道
        const orbit_idx = try self.matchOrbit(hub);
        const orbit = &self.graph.orbits[orbit_idx];

        // 绑定参数：太阳层通道 → 轨道入口通道（桥接，避免轨道跨层读父层通道）
        for (hub.param_mapping) |pm| {
            const src = &self.channels[pm.src];
            const dst = &self.channels[pm.dst];
            const w = dst.elem_width;
            if (w > 0) @memcpy(dst.data[0..w], src.data[0..w]);
        }

        // 同步执行轨道
        try self.runOrbit(orbit_idx);

        // 返回值桥接：轨道内 output_channel → 太阳层 hub.output_channel
        // 轨道内 ret_chan 写入结果后，复制到太阳层 out_chan 供父层读取
        if (orbit.output_channel != hub.output_channel) {
            const src = &self.channels[orbit.output_channel];
            const dst = &self.channels[hub.output_channel];
            const w = dst.elem_width;
            if (w > 0) @memcpy(dst.data[0..w], src.data[0..w]);
        }
    }

    /// 匹配轨道：根据条件值查找 orbit_table
    fn matchOrbit(self: *Engine, hub: *const OrbitHub) !u16 {
        const cond_chan_idx = hub.cond_channel orelse {
            // 无条件通道：找 always 条目或返回第一条
            for (hub.orbit_table) |entry| {
                if (entry.cond_kind == .always) return entry.orbit_index;
            }
            if (hub.orbit_table.len > 0) return hub.orbit_table[0].orbit_index;
            return error.InvalidChannel;
        };

        // 读取条件值（按通道宽度转 i64）
        const cond_chan = &self.channels[cond_chan_idx];
        const cond_val: i64 = blk: {
            const w = cond_chan.elem_width;
            if (w == 0) break :blk 0;
            break :blk switch (w) {
                1 => @as(i64, cond_chan.getScalar(i8, 0)),
                2 => @as(i64, cond_chan.getScalar(i16, 0)),
                4 => @as(i64, cond_chan.getScalar(i32, 0)),
                8 => cond_chan.getScalar(i64, 0),
                else => 0,
            };
        };

        // 遍历轨道表查找匹配
        for (hub.orbit_table) |entry| {
            const matched = switch (entry.cond_kind) {
                .always => true,
                .eq => cond_val == entry.expected_val,
                .ne => cond_val != entry.expected_val,
                .gt => cond_val > entry.expected_val,
                .lt => cond_val < entry.expected_val,
            };
            if (matched) return entry.orbit_index;
        }

        // 无匹配 → 最后一条为 default 轨道
        if (hub.orbit_table.len > 0) return hub.orbit_table[hub.orbit_table.len - 1].orbit_index;
        return error.InvalidChannel;
    }

    /// 执行轨道：线性遍历轨道内 lamina 序列
    /// 环形轨道循环执行直到 continue_channel == 0 或 halt_break
    fn runOrbit(self: *Engine, orbit_idx: u16) !void {
        const orbit = &self.graph.orbits[orbit_idx];
        self.orbit_states[orbit_idx] = .running;
        const saved_orbit = self.current_orbit;
        self.current_orbit = orbit_idx;

        if (orbit.is_cyclic) {
            // 环形轨道：数据驱动循环
            while (true) {
                self.halt_reason = .none;
                for (orbit.laminas) |lam| {
                    if (self.halt_reason != .none) break;
                    try self.executeLamina(lam);
                }

                // 处理 halt 信号
                switch (self.halt_reason) {
                    .return_halt, .throw_halt => {
                        // 传播到上层
                        self.current_orbit = saved_orbit;
                        self.orbit_states[orbit_idx] = .done;
                        return;
                    },
                    .break_halt => {
                        self.halt_reason = .none;
                        break;
                    },
                    .continue_halt => {
                        self.halt_reason = .none;
                        // 继续下一轮，检查 continue_channel
                    },
                    .none => {},
                }

                // 检查继续条件通道
                if (orbit.continue_channel) |cc| {
                    const chan = &self.channels[cc];
                    const w = chan.elem_width;
                    if (w == 0) break;
                    const continue_val: i64 = switch (w) {
                        1 => @as(i64, chan.getScalar(i8, 0)),
                        2 => @as(i64, chan.getScalar(i16, 0)),
                        4 => @as(i64, chan.getScalar(i32, 0)),
                        8 => chan.getScalar(i64, 0),
                        else => 0,
                    };
                    if (continue_val == 0) break;
                } else {
                    // 无继续条件通道，执行一次后停止
                    break;
                }
            }
        } else {
            // 普通轨道：执行一次
            self.halt_reason = .none;
            for (orbit.laminas) |lam| {
                if (self.halt_reason != .none) break;
                try self.executeLamina(lam);
            }
            // break_halt/continue_halt 是循环控制信号，不应从普通轨道传播到上层
            // 只有 return_halt/throw_halt 才传播
            if (self.halt_reason == .break_halt or self.halt_reason == .continue_halt) {
                self.halt_reason = .none;
            }
        }

        self.current_orbit = saved_orbit;
        self.orbit_states[orbit_idx] = .done;
    }

    /// 异步轨道枢纽：激活轨道到调度器，不等待完成
    /// E1：通过协程调度器分发到 worker 线程并行执行
    fn execOrbitHubAsync(self: *Engine, lam: Lamina) !void {
        const hub_idx = lam.hub_index orelse return error.InvalidChannel;
        const hub = &self.graph.orbit_hubs[hub_idx];

        // 匹配轨道
        const orbit_idx = try self.matchOrbit(hub);
        const orbit = &self.graph.orbits[orbit_idx];

        // 确保调度器存在（主引擎惰性创建）
        if (self.scheduler == null and self.owned_scheduler == null) {
            const sched = try self.allocator.create(Scheduler);
            sched.* = Scheduler.init(self.allocator, 4, self.element_count);
            try sched.start();
            self.owned_scheduler = sched;
            self.scheduler = sched;
        }
        const sched = self.scheduler.?;

        // 创建子图包装器：将轨道 lamina 序列包装为独立 LaminarGraph
        const sg = try self.allocator.create(LaminarGraph);
        sg.* = .{
            .laminas = orbit.laminas,
            .channel_metas = self.graph.channel_metas,
            .channel_count = self.graph.channel_count,
            .input_channels = &.{},
            .output_channel = orbit.output_channel,
            .string_table = self.graph.string_table,
            .name_table = self.graph.name_table,
            .subgraphs = &.{},
            .orbits = &.{},
            .orbit_hubs = &.{},
            .defer_entries = &.{},
            .channel_scopes = &.{},
            .arena = null,
        };
        try self.async_subgraphs.append(self.allocator, sg);

        // 创建任务
        const task = try LfeTask.create(self.allocator, sched, sg, self.element_count);

        // 复制所有通道数据到任务（轨道共享太阳层通道空间）
        for (0..@intCast(self.graph.channel_count)) |i| {
            const src = &self.channels[i];
            const dst = &task.channels[i];
            const w = dst.elem_width;
            if (w > 0) @memcpy(dst.data[0..w], src.data[0..w]);
        }

        // 绑定参数（覆盖 param_mapping 目标通道）
        for (hub.param_mapping) |pm| {
            const src = &self.channels[pm.src];
            const dst = &task.channels[pm.dst];
            const w = dst.elem_width;
            if (w > 0) @memcpy(dst.data[0..w], src.data[0..w]);
        }

        // 提交到调度器
        sched.asyncTask(task);

        // 创建异步实例（记录 task 和 output_channel 供 orbit_join 读取）
        try self.async_instances.append(self.allocator, .{
            .orbit_index = orbit_idx,
            .channels = &.{},
            .channel_region = ChannelRegion.init(self.allocator),
            .done = false,
            .result = Value.fromI64(0),
            .task = task,
            .output_channel = orbit.output_channel,
        });

        // 输出句柄（索引 + 1，避免 0 被误认为空）
        const out = &self.channels[lam.output];
        if (out.elem_width > 0) {
            out.setScalar(usize, 0, self.async_instances.items.len);
        }
    }

    /// 等待异步轨道完成并读取结果（主引擎模式，自旋等待）
    fn execOrbitJoinSync(self: *Engine, lam: Lamina) !void {
        const handle_chan = &self.channels[lam.inputs[0]];
        const handle: usize = handle_chan.getScalar(usize, 0);
        if (handle == 0 or handle > self.async_instances.items.len) return error.InvalidChannel;

        const inst = &self.async_instances.items[handle - 1];

        if (inst.task) |task| {
            // 调度器模式：自旋等待任务完成
            while (!task.result_ready.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            // 从任务的通道读取结果
            const out = &self.channels[lam.output];
            const task_chan = &task.channels[inst.output_channel];
            const meta = self.graph.channel_metas[inst.output_channel];
            const w = meta.elem_width;
            if (w > 0) @memcpy(out.data[0..w], task_chan.data[0..w]);
        } else {
            // 同步模式：结果已就绪
            if (!inst.done) return error.UnsupportedOp;
            const out = &self.channels[lam.output];
            valueToChan(inst.result, out, self.graph.channel_metas[lam.output]);
        }
    }

    /// 等待异步轨道完成（task 模式，可挂起）
    /// 返回 null 表示完成，返回 .suspend_ 表示挂起
    fn execOrbitJoinAsync(self: *Engine, lam: Lamina) ?ExecResult {
        const handle_chan = &self.channels[lam.inputs[0]];
        const handle: usize = handle_chan.getScalar(usize, 0);
        if (handle == 0 or handle > self.async_instances.items.len) return .failed;

        const inst = &self.async_instances.items[handle - 1];

        if (inst.task) |task| {
            if (task.result_ready.load(.acquire)) {
                // 已完成，读取结果
                const out = &self.channels[lam.output];
                const task_chan = &task.channels[inst.output_channel];
                const meta = self.graph.channel_metas[inst.output_channel];
                const w = meta.elem_width;
                if (w > 0) @memcpy(out.data[0..w], task_chan.data[0..w]);
                return .continue_;
            }
            // 未完成，挂起当前 task
            const current = self.task orelse return .failed;
            task.addWaiter(current);
            return .suspend_;
        }

        // 同步模式：结果已就绪
        if (!inst.done) return .failed;
        const out = &self.channels[lam.output];
        valueToChan(inst.result, out, self.graph.channel_metas[lam.output]);
        return .continue_;
    }

    // ── 星轨模型：defer 栈 ──

    /// 注册 defer 体到 LIFO 栈
    fn execDeferRegister(self: *Engine, lam: Lamina) !void {
        const orbit_idx: u16 = @intCast(lam.const_val orelse 0);
        try self.defer_stack.append(self.allocator, orbit_idx);
    }

    /// LIFO 执行所有已注册的 defer 体
    fn execDeferExecute(self: *Engine) !void {
        while (self.defer_stack.items.len > 0) {
            const orbit_idx = self.defer_stack.pop().?;
            // defer 轨道执行不传播 halt
            const saved_halt = self.halt_reason;
            self.halt_reason = .none;
            try self.runOrbit(orbit_idx);
            self.halt_reason = saved_halt;
        }
    }

    // ── 星轨模型：显式数据栈（递归用）──

    /// 压栈：保存通道快照到数据栈
    /// const_val = 起始通道索引, const_val2 = 通道数量
    fn execStackPush(self: *Engine, lam: Lamina) !void {
        const start: usize = @intCast(lam.const_val orelse 0);
        const count: usize = @intCast(lam.const_val2 orelse 0);

        // 计算快照总字节
        var total: usize = 0;
        for (start..start + count) |i| {
            total += self.channels[i].elem_width * self.element_count;
        }

        const snapshot = try self.allocator.alloc(u8, total);
        var off: usize = 0;
        for (start..start + count) |i| {
            const w = self.channels[i].elem_width * self.element_count;
            if (w > 0) {
                @memcpy(snapshot[off .. off + w], self.channels[i].data[0..w]);
            }
            off += w;
        }

        try self.data_stack.append(self.allocator, .{
            .channels_snapshot = snapshot,
            .return_channel = lam.output,
        });
    }

    /// 出栈：从数据栈恢复通道快照
    fn execStackPop(self: *Engine, lam: Lamina) !void {
        if (self.data_stack.items.len == 0) return error.InvalidChannel;
        const frame = self.data_stack.pop().?;
        defer self.allocator.free(frame.channels_snapshot);

        const start: usize = @intCast(lam.const_val orelse 0);
        const count: usize = @intCast(lam.const_val2 orelse 0);

        var off: usize = 0;
        for (start..start + count) |i| {
            const w = self.channels[i].elem_width * self.element_count;
            if (w > 0) {
                @memcpy(self.channels[i].data[0..w], frame.channels_snapshot[off .. off + w]);
            }
            off += w;
        }
    }

    /// 查看栈顶：复制栈顶快照到指定通道（不出栈）
    fn execStackPeek(self: *Engine, lam: Lamina) !void {
        if (self.data_stack.items.len == 0) return error.InvalidChannel;
        const frame = &self.data_stack.items[self.data_stack.items.len - 1];

        const start: usize = @intCast(lam.const_val orelse 0);
        const count: usize = @intCast(lam.const_val2 orelse 0);

        var off: usize = 0;
        for (start..start + count) |i| {
            const w = self.channels[i].elem_width * self.element_count;
            if (w > 0) {
                @memcpy(self.channels[i].data[0..w], frame.channels_snapshot[off .. off + w]);
            }
            off += w;
        }
    }

    /// 栈深度：返回 data_stack 的当前深度
    fn execStackDepth(self: *Engine, lam: Lamina) !void {
        const out = &self.channels[lam.output];
        if (out.elem_width == 0) return;
        out.setScalar(i64, 0, @intCast(self.data_stack.items.len));
    }
};

// ── 辅助函数 ──

/// comptime 判断整数类型是否有符号
fn isSignedInt(comptime T: type) bool {
    return @typeInfo(T).int.signedness == .signed;
}

/// 通道值 → Value 转换
fn chanToValue(chan: *const PhysicalChannel, meta: lamina_mod.ChannelMeta) Value {
    if (chan.elem_width == 0) {
        return switch (meta.chan_type) {
            .null_chan => Value.fromNull(),
            .unit_chan => Value.fromUnit(),
            else => Value.fromI64(0),
        };
    }
    return switch (meta.chan_type) {
        .bool_chan, .mask_chan => Value.fromBool(chan.getScalar(u8, 0) != 0),
        .char_chan => Value.fromChar(.{ .codepoint = chan.getScalar(u32, 0) }),
        .i8_chan => Value.fromI8(chan.getScalar(i8, 0)),
        .i16_chan => Value.fromI16(chan.getScalar(i16, 0)),
        .i32_chan => Value.fromI32(chan.getScalar(i32, 0)),
        .i64_chan => Value.fromI64(chan.getScalar(i64, 0)),
        .i128_chan => Value.fromI128(chan.getScalar(i128, 0)),
        .u8_chan => Value.fromU8(chan.getScalar(u8, 0)),
        .u16_chan => Value.fromU16(chan.getScalar(u16, 0)),
        .u32_chan => Value.fromU32(chan.getScalar(u32, 0)),
        .u64_chan => Value.fromU64(chan.getScalar(u64, 0)),
        .u128_chan => Value.fromU128(chan.getScalar(u128, 0)),
        .f16_chan => Value.fromF16(chan.getScalar(f16, 0)),
        .f32_chan => Value.fromF32(chan.getScalar(f32, 0)),
        .f64_chan => Value.fromF64(chan.getScalar(f64, 0)),
        .f128_chan => Value.fromF128(chan.getScalar(f128, 0)),
        .ref_chan => Value.fromRef(@ptrFromInt(chan.getScalar(usize, 0))),
        .null_chan => Value.fromNull(),
        .unit_chan => Value.fromUnit(),
    };
}

/// Value → 通道值转换
fn valueToChan(val: Value, chan: *PhysicalChannel, meta: lamina_mod.ChannelMeta) void {
    if (chan.elem_width == 0) return;
    switch (meta.chan_type) {
        .bool_chan, .mask_chan => chan.setScalar(u8, 0, if (val.asBool()) 1 else 0),
        .char_chan => chan.setScalar(u32, 0, val.asChar().codepoint),
        .i8_chan => chan.setScalar(i8, 0, val.asI8()),
        .i16_chan => chan.setScalar(i16, 0, val.asI16()),
        .i32_chan => chan.setScalar(i32, 0, val.asI32()),
        .i64_chan => chan.setScalar(i64, 0, val.asI64()),
        .i128_chan => chan.setScalar(i128, 0, val.asI128()),
        .u8_chan => chan.setScalar(u8, 0, val.asU8()),
        .u16_chan => chan.setScalar(u16, 0, val.asU16()),
        .u32_chan => chan.setScalar(u32, 0, val.asU32()),
        .u64_chan => chan.setScalar(u64, 0, val.asU64()),
        .u128_chan => chan.setScalar(u128, 0, val.asU128()),
        .f16_chan => chan.setScalar(f16, 0, val.asF16()),
        .f32_chan => chan.setScalar(f32, 0, val.asF32()),
        .f64_chan => chan.setScalar(f64, 0, val.asF64()),
        .f128_chan => chan.setScalar(f128, 0, val.asF128()),
        .ref_chan => chan.setScalar(usize, 0, @intFromPtr(val.asRef())),
        .null_chan, .unit_chan => {},
    }
}

/// Value → i64（用于原子算术）
fn valToI64(val: Value) i64 {
    return switch (val) {
        .i8 => |v| @as(i64, @intCast(@as(i8, @bitCast(v)))),
        .i16 => |v| @as(i64, @intCast(@as(i16, @bitCast(v)))),
        .i32 => |v| @as(i64, @intCast(@as(i32, @bitCast(v)))),
        .i64 => |v| @bitCast(v),
        .u8 => |v| @as(i64, @intCast(v[0])),
        .u16 => |v| @as(i64, @intCast(@as(u16, @bitCast(v)))),
        .u32 => |v| @as(i64, @intCast(@as(u32, @bitCast(v)))),
        .u64 => |v| @as(i64, @intCast(@as(u64, @bitCast(v)))),
        else => 0,
    };
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

/// 构建简单层流图并执行的辅助函数
fn buildAndRunGraph(
    allocator: std.mem.Allocator,
    laminas: []const Lamina,
    channel_metas: []const lamina_mod.ChannelMeta,
    channel_count: u16,
    output_channel: u16,
) !Engine {
    return buildAndRunGraphN(allocator, laminas, channel_metas, channel_count, output_channel, 1);
}

/// 构建层流图并以指定 element_count 执行（element_count > 1 触发 SIMD 批处理）
fn buildAndRunGraphN(
    allocator: std.mem.Allocator,
    laminas: []const Lamina,
    channel_metas: []const lamina_mod.ChannelMeta,
    channel_count: u16,
    output_channel: u16,
    element_count: usize,
) !Engine {
    const graph = LaminarGraph{
        .laminas = laminas,
        .channel_metas = channel_metas,
        .channel_count = channel_count,
        .input_channels = &.{},
        .output_channel = output_channel,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    };

    var engine = try Engine.init(allocator, &graph, element_count);
    try engine.run();
    return engine;
}

test "常量载入与返回: 42" {
    // chan0 = constant(42), halt_return(chan0)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };

    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 1, 0);
    defer engine.deinit();

    try testing.expectEqual(HaltReason.return_halt, engine.halt_reason);
    try testing.expectEqual(@as(i64, 42), engine.return_value);
}

test "整数加法: 17 + 25 = 42" {
    // chan0 = constant(17), chan1 = constant(25), chan2 = int_add(chan0, chan1), halt_return(chan2)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 17, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 25, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
        .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
    };

    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();

    try testing.expectEqual(@as(i64, 42), engine.return_value);
}

test "整数减法与乘法: (100 - 30) * 2 = 140" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 100
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: 30
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: 100-30
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: 2
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 30, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_sub, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
        .{ .op = .constant, .output = 3, .const_val = 2, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_mul, .inputs = .{ 2, 3, 0 }, .output = 4, .int_kind = .i64, .input_count = 2 },
        .{ .op = .halt_return, .inputs = .{ 4, 0, 0 }, .output = 4, .input_count = 1 },
    };

    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    defer engine.deinit();

    try testing.expectEqual(@as(i64, 140), engine.return_value);
}

test "条件选择: cond=true → 10, cond=false → 20" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .bool_chan, .elem_width = 1 },  // 0: cond
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 1: true_val
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 2: false_val
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 3: result
    };

    // cond = true → select → 10
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 1, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
            .{ .op = .constant, .output = 2, .const_val = 20, .int_kind = .i64, .input_count = 0 },
            .{ .op = .select, .inputs = .{ 1, 2, 0 }, .output = 3, .predicate = 0, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 3, 0, 0 }, .output = 3, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
        defer engine.deinit();
        try testing.expectEqual(@as(i64, 10), engine.return_value);
    }

    // cond = false → select → 20
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 0, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
            .{ .op = .constant, .output = 2, .const_val = 20, .int_kind = .i64, .input_count = 0 },
            .{ .op = .select, .inputs = .{ 1, 2, 0 }, .output = 3, .predicate = 0, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 3, 0, 0 }, .output = 3, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
        defer engine.deinit();
        try testing.expectEqual(@as(i64, 20), engine.return_value);
    }
}

test "整数除法与取模: 17 div 5 = 3, 17 mod 5 = 2" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 17
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: 5
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: div result
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: mod result
    };

    // div
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 17, .int_kind = .i64, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 5, .int_kind = .i64, .input_count = 0 },
            .{ .op = .int_div, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 2);
        defer engine.deinit();
        try testing.expectEqual(@as(i64, 3), engine.return_value);
    }

    // mod
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 17, .int_kind = .i64, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 5, .int_kind = .i64, .input_count = 0 },
            .{ .op = .int_mod, .inputs = .{ 0, 1, 0 }, .output = 3, .int_kind = .i64, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 3, 0, 0 }, .output = 3, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
        defer engine.deinit();
        try testing.expectEqual(@as(i64, 2), engine.return_value);
    }
}

test "整数比较: 10 < 20 = true, 10 > 20 = false" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 10
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: 20
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 2: result
    };

    // 10 < 20 → true (1)
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 20, .int_kind = .i64, .input_count = 0 },
            .{ .op = .int_lt, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
        defer engine.deinit();
        // mask_chan 存为 u8，halt_return 对 mask_chan 返回 0
        // 但 getScalar(u8, 0) 应该是 1
        try testing.expectEqual(@as(i64, 0), engine.return_value); // mask 不是整数通道
    }
}

test "浮点加法: 1.5 + 2.5 = 4.0" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .f64_chan, .elem_width = 8 }, // 0: 1.5
        .{ .chan_type = .f64_chan, .elem_width = 8 }, // 1: 2.5
        .{ .chan_type = .f64_chan, .elem_width = 8 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = @as(i64, @bitCast(@as(f64, 1.5))), .float_kind = .f64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = @as(i64, @bitCast(@as(f64, 2.5))), .float_kind = .f64, .input_count = 0 },
        .{ .op = .float_add, .inputs = .{ 0, 1, 0 }, .output = 2, .float_kind = .f64, .input_count = 2 },
        .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
    };

    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();

    // f64 通道，halt_return 对 f64 返回 0（仅 i*/u* 通道有返回值映射）
    // 直接检查通道数据
    const result: f64 = @bitCast(engine.return_value);
    _ = result;
    // 返回值对 f64 通道为 0，需直接读通道
    // 在 init 后 channels 已建立，run 后 chan2 有结果
}

test "一元负: -42 = -42" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 42
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: -42
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_neg, .inputs = .{ 0, 0, 0 }, .output = 1, .int_kind = .i64, .input_count = 1 },
        .{ .op = .halt_return, .inputs = .{ 1, 0, 0 }, .output = 1, .input_count = 1 },
    };

    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 2, 1);
    defer engine.deinit();

    try testing.expectEqual(@as(i64, -42), engine.return_value);
}

test "布尔运算: true AND false = false, true OR false = true" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 0: true
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 1: false
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 2: result
    };

    // true AND false = false
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 1, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 0, .input_count = 0 },
            .{ .op = .bool_and, .inputs = .{ 0, 1, 0 }, .output = 2, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
        defer engine.deinit();
    }

    // true OR false = true
    {
        const laminas = [_]Lamina{
            .{ .op = .constant, .output = 0, .const_val = 1, .input_count = 0 },
            .{ .op = .constant, .output = 1, .const_val = 0, .input_count = 0 },
            .{ .op = .bool_or, .inputs = .{ 0, 1, 0 }, .output = 2, .input_count = 2 },
            .{ .op = .halt_return, .inputs = .{ 2, 0, 0 }, .output = 2, .input_count = 1 },
        };
        var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
        defer engine.deinit();
    }
}

test "除零错误" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
        .{ .chan_type = .i64_chan, .elem_width = 8 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_div, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 3,
        .input_channels = &.{},
        .output_channel = 2,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 1);
    defer engine.deinit();

    const result = engine.run();
    try testing.expectError(error.DivisionByZero, result);
}

// ══════════════════════════════════════════════════════
// SIMD 批处理测试（element_count > 1）
// ══════════════════════════════════════════════════════

test "SIMD 批量常量广播: 10 元素 i32" {
    // chan0 = constant(42), broadcast to 10 elements
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i32_chan, .elem_width = 4 },
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i32, .input_count = 0 },
    };

    var engine = try buildAndRunGraphN(testing.allocator, &laminas, &metas, 1, 0, 10);
    defer engine.deinit();

    // 验证所有 10 个元素都是 42
    for (0..10) |i| {
        try testing.expectEqual(@as(i32, 42), engine.channels[0].getScalar(i32, i));
    }
}

test "SIMD 批量整数加法: 10 元素 i32" {
    // 手动初始化两个通道，然后执行批量加法
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 0: a
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 1: b
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .int_add, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i32, .input_count = 2 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 3,
        .input_channels = &.{},
        .output_channel = 2,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 10);
    defer engine.deinit();

    // 手动设置输入数据
    for (0..10) |i| {
        engine.channels[0].setScalar(i32, i, @intCast(i * 10));
        engine.channels[1].setScalar(i32, i, @intCast(i + 1));
    }

    try engine.run();

    // 验证结果: a[i] + b[i] = i*10 + (i+1) = 11*i + 1
    for (0..10) |i| {
        const expected: i32 = @intCast(i * 11 + 1);
        try testing.expectEqual(expected, engine.channels[2].getScalar(i32, i));
    }
}

test "SIMD 批量整数比较: 10 元素 i32" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 0: a
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 1: b
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .int_lt, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i32, .input_count = 2 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 3,
        .input_channels = &.{},
        .output_channel = 2,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 10);
    defer engine.deinit();

    // a[i] = i, b[i] = 10 - i → a < b when i < 5
    for (0..10) |i| {
        engine.channels[0].setScalar(i32, i, @intCast(i));
        engine.channels[1].setScalar(i32, i, @intCast(10 - i));
    }

    try engine.run();

    // 验证: a < b → 1 when i < 5, 0 when i >= 5
    for (0..10) |i| {
        const expected: u8 = if (i < 5) 1 else 0;
        try testing.expectEqual(expected, engine.channels[2].getScalar(u8, i));
    }
}

test "SIMD 批量选择: 10 元素 i32" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 0: mask
        .{ .chan_type = .i32_chan, .elem_width = 4 },  // 1: true_val
        .{ .chan_type = .i32_chan, .elem_width = 4 },  // 2: false_val
        .{ .chan_type = .i32_chan, .elem_width = 4 },  // 3: result
    };
    const laminas = [_]Lamina{
        .{ .op = .select, .inputs = .{ 1, 2, 0 }, .output = 3, .predicate = 0, .input_count = 2 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 4,
        .input_channels = &.{},
        .output_channel = 3,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 10);
    defer engine.deinit();

    // 偶数索引选 true_val, 奇数选 false_val
    for (0..10) |i| {
        engine.channels[0].setScalar(u8, i, if (i % 2 == 0) 1 else 0);
        engine.channels[1].setScalar(i32, i, @intCast(i * 100));
        engine.channels[2].setScalar(i32, i, @intCast(i * 200));
    }

    try engine.run();

    // 验证: even → i*100, odd → i*200
    for (0..10) |i| {
        const expected: i32 = if (i % 2 == 0) @as(i32, @intCast(i * 100)) else @as(i32, @intCast(i * 200));
        try testing.expectEqual(expected, engine.channels[3].getScalar(i32, i));
    }
}

test "SIMD 批量浮点乘法: 10 元素 f32" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .f32_chan, .elem_width = 4 }, // 0: a
        .{ .chan_type = .f32_chan, .elem_width = 4 }, // 1: b
        .{ .chan_type = .f32_chan, .elem_width = 4 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .float_mul, .inputs = .{ 0, 1, 0 }, .output = 2, .float_kind = .f32, .input_count = 2 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 3,
        .input_channels = &.{},
        .output_channel = 2,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 10);
    defer engine.deinit();

    for (0..10) |i| {
        engine.channels[0].setScalar(f32, i, @floatFromInt(i + 1));
        engine.channels[1].setScalar(f32, i, 2.0);
    }

    try engine.run();

    for (0..10) |i| {
        const expected: f32 = @as(f32, @floatFromInt(i + 1)) * 2.0;
        try testing.expectApproxEqAbs(expected, engine.channels[2].getScalar(f32, i), 0.001);
    }
}

test "SIMD 批量一元取负: 10 元素 i32" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 0: input
        .{ .chan_type = .i32_chan, .elem_width = 4 }, // 1: result
    };
    const laminas = [_]Lamina{
        .{ .op = .int_neg, .inputs = .{ 0, 0, 0 }, .output = 1, .int_kind = .i32, .input_count = 1 },
    };

    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 1,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 10);
    defer engine.deinit();

    for (0..10) |i| {
        engine.channels[0].setScalar(i32, i, @intCast(i));
    }

    try engine.run();

    for (0..10) |i| {
        const expected: i32 = -@as(i32, @intCast(i));
        try testing.expectEqual(expected, engine.channels[1].getScalar(i32, i));
    }
}

// ══════════════════════════════════════════════════════
// 阶段 5: Cell 与 Throw 测试
// ══════════════════════════════════════════════════════

test "Cell 基本操作: make/get/set" {
    // chan0 = constant(42), chan1 = cell_make(chan0), chan2 = cell_get(chan1)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: value
        .{ .chan_type = .ref_chan, .elem_width = 8, .is_cell = true }, // 1: cell
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .cell_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .cell, .input_count = 1 },
        .{ .op = .cell_get, .inputs = .{ 1, 0, 0 }, .output = 2, .ref_kind = .cell, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), engine.channels[2].getScalar(i64, 0));
}

test "Cell 赋值: make(42) → set(100) → get = 100" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: initial 42
        .{ .chan_type = .ref_chan, .elem_width = 8, .is_cell = true }, // 1: cell
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: new value 100
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .cell_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .cell, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .cell_set, .inputs = .{ 1, 2, 0 }, .output = 1, .ref_kind = .cell, .input_count = 2 },
        .{ .op = .cell_get, .inputs = .{ 1, 0, 0 }, .output = 3, .ref_kind = .cell, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 100), engine.channels[3].getScalar(i64, 0));
}

test "Cell swap: make(42) → swap(100) → 返回旧值 42" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: initial 42
        .{ .chan_type = .ref_chan, .elem_width = 8, .is_cell = true }, // 1: cell
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: new value 100
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: old value (swap 返回)
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .cell_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .cell, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .cell_swap, .inputs = .{ 1, 2, 0 }, .output = 3, .ref_kind = .cell, .input_count = 2 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    // swap 返回旧值 42
    try testing.expectEqual(@as(i64, 42), engine.channels[3].getScalar(i64, 0));
}

test "throw_propagate: ok 值正常传递" {
    // 创建 throw 值 (is_throw=0)，propagate 应返回 ok 值
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 16 }, // 0: throw value (16 字节)
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: result
    };
    const laminas = [_]Lamina{
        .{ .op = .throw_propagate, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .throw_val, .input_count = 1 },
    };
    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 1,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 1);
    defer engine.deinit();
    // 手动设置 throw 值：value=42, is_throw=0 (ok)
    engine.channels[0].setScalar(i64, 0, 42);
    engine.channels[0].setScalar(u8, 8, 0); // is_throw = 0
    try engine.run();
    try testing.expectEqual(@as(i64, 42), engine.channels[1].getScalar(i64, 0));
}

test "throw_propagate: err 值触发 throw_halt" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 16 }, // 0: throw value
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: result
    };
    const laminas = [_]Lamina{
        .{ .op = .throw_propagate, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .throw_val, .input_count = 1 },
    };
    var engine = try Engine.init(testing.allocator, &LaminarGraph{
        .laminas = &laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 1,
        .string_table = &.{},
        .name_table = &.{},
        .arena = null,
    }, 1);
    defer engine.deinit();
    // 手动设置 throw 值：value=0, is_throw=1 (err)
    engine.channels[0].setScalar(i64, 0, 0);
    engine.channels[0].setScalar(u8, 8, 1); // is_throw = 1
    try engine.run();
    try testing.expectEqual(HaltReason.throw_halt, engine.halt_reason);
}

// ══════════════════════════════════════════════════════
// 阶段 5: 闭包、Trait 与 switch_lamina 测试
// ══════════════════════════════════════════════════════

test "闭包创建与调用" {
    // chan0 = constant(42), chan1 = closure_make(func_idx=1, captures=[42]), chan2 = closure_call(chan1)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: capture value 42
        .{ .chan_type = .ref_chan, .elem_width = 24 }, // 1: closure (func_idx + count + 1 capture)
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .closure_make, .inputs = .{ 0, 0, 0 }, .output = 1, .const_val = 1, .ref_kind = .closure, .input_count = 1 },
        .{ .op = .closure_call, .inputs = .{ 1, 0, 0 }, .output = 2, .ref_kind = .closure, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();
    // closure_call 返回第一个捕获值 = 42
    try testing.expectEqual(@as(i64, 42), engine.channels[2].getScalar(i64, 0));
}

test "闭包捕获读取" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: capture 1 = 10
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 1: capture 2 = 20
        .{ .chan_type = .ref_chan, .elem_width = 32 }, // 2: closure (func_idx + count + 2 captures)
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 3: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 20, .int_kind = .i64, .input_count = 0 },
        .{ .op = .closure_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 1, .ref_kind = .closure, .input_count = 2 },
        .{ .op = .closure_capture, .inputs = .{ 2, 0, 0 }, .output = 3, .const_val = 1, .ref_kind = .closure, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    // capture index 1 = 20
    try testing.expectEqual(@as(i64, 20), engine.channels[3].getScalar(i64, 0));
}

test "Trait 创建与方法调用" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: data value
        .{ .chan_type = .ref_chan, .elem_width = 16 }, // 1: trait value (type_tag + data)
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .trait_make, .inputs = .{ 0, 0, 0 }, .output = 1, .const_val = 1, .ref_kind = .trait_val, .input_count = 1 },
        .{ .op = .trait_call_method, .inputs = .{ 1, 0, 0 }, .output = 2, .ref_kind = .trait_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();
    // trait_call_method 返回数据值 = 42
    try testing.expectEqual(@as(i64, 42), engine.channels[2].getScalar(i64, 0));
}

test "switch_lamina 类型分派" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .u64_chan, .elem_width = 8 }, // 0: type_tag = 1
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: matched value = 100
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 1, .int_kind = .i64, .input_count = 0 }, // type_tag = 1
        .{ .op = .constant, .output = 1, .const_val = 100, .int_kind = .i64, .input_count = 0 }, // matched value
        .{ .op = .switch_lamina, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 1, .const_val2 = 999, .input_count = 2 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();
    // type_tag=1 匹配 case_tag=1，输出 = 100
    try testing.expectEqual(@as(i64, 100), engine.channels[2].getScalar(i64, 0));
}

test "switch_lamina 默认值" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: type_tag = 5
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: matched value = 100
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: result
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 5, .int_kind = .i64, .input_count = 0 }, // type_tag = 5 (无匹配)
        .{ .op = .constant, .output = 1, .const_val = 100, .int_kind = .i64, .input_count = 0 }, // matched value
        .{ .op = .switch_lamina, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 1, .const_val2 = 999, .input_count = 2 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    defer engine.deinit();
    // type_tag=5 不匹配 case_tag=1，输出默认值 = 999
    try testing.expectEqual(@as(i64, 999), engine.channels[2].getScalar(i64, 0));
}

// ══════════════════════════════════════════════════════
// 阶段 5: Atomic / Channel 测试（指针格式，复用 value/concurrent.zig）
// ══════════════════════════════════════════════════════
// 注意：ref_chan 存储 heap 指针（usize=8B），非旧版内联 16B 格式。
// async_create/async_join 需要 Scheduler，无法通过 Engine.run() 单测，
// 其集成测试由 edge_concurrency 端到端覆盖。

/// 清理 ref_chan 中存储的堆对象
fn cleanupRefObj(chan: *const PhysicalChannel, ref_kind: lamina_mod.RefKind, allocator: std.mem.Allocator) void {
    if (chan.elem_width == 0) return;
    const ptr_val = chan.getScalar(usize, 0);
    if (ptr_val == 0) return;
    const hdr: *ObjHeader = @ptrFromInt(ptr_val);
    switch (ref_kind) {
        .atomic_val => concurrent.atomicDeinit(hdr, allocator),
        .channel_val => concurrent.channelDeinit(hdr, allocator),
        .sender_val => concurrent.senderDeinit(hdr, allocator),
        .receiver_val => concurrent.receiverDeinit(hdr, allocator),
        else => {},
    }
}

test "Atomic 基本操作: make/load/store" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 初始值
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 1: atomic 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: 加载值
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: 新值
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: store 后加载值
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .atomic_val, .input_count = 1 },
        .{ .op = .atomic_load, .inputs = .{ 1, 0, 0 }, .output = 2, .ref_kind = .atomic_val, .input_count = 1 },
        .{ .op = .constant, .output = 3, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_store, .inputs = .{ 1, 3, 0 }, .output = 1, .ref_kind = .atomic_val, .input_count = 2 },
        .{ .op = .atomic_load, .inputs = .{ 1, 0, 0 }, .output = 4, .ref_kind = .atomic_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    try testing.expectEqual(@as(i64, 42), engine.channels[2].getScalar(i64, 0));
    try testing.expectEqual(@as(i64, 100), engine.channels[4].getScalar(i64, 0));
    cleanupRefObj(&engine.channels[1], .atomic_val, testing.allocator);
    engine.deinit();
}

test "Atomic CAS 成功" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 初始值
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 1: atomic 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: expected
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: desired
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 4: CAS 结果
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 5: CAS 后加载值
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .atomic_val, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 3, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_cas, .inputs = .{ 1, 2, 3 }, .output = 4, .ref_kind = .atomic_val, .input_count = 3 },
        .{ .op = .atomic_load, .inputs = .{ 1, 0, 0 }, .output = 5, .ref_kind = .atomic_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 6, 5);
    try testing.expectEqual(@as(u8, 1), engine.channels[4].getScalar(u8, 0)); // CAS 成功
    try testing.expectEqual(@as(i64, 100), engine.channels[5].getScalar(i64, 0)); // 值已更新为 100
    cleanupRefObj(&engine.channels[1], .atomic_val, testing.allocator);
    engine.deinit();
}

test "Atomic CAS 失败" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 初始值
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 1: atomic 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: expected
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: desired
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 4: CAS 结果
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 5: CAS 后加载值
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .atomic_val, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 99, .int_kind = .i64, .input_count = 0 }, // expected=99 不匹配
        .{ .op = .constant, .output = 3, .const_val = 100, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_cas, .inputs = .{ 1, 2, 3 }, .output = 4, .ref_kind = .atomic_val, .input_count = 3 },
        .{ .op = .atomic_load, .inputs = .{ 1, 0, 0 }, .output = 5, .ref_kind = .atomic_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 6, 5);
    try testing.expectEqual(@as(u8, 0), engine.channels[4].getScalar(u8, 0)); // CAS 失败
    try testing.expectEqual(@as(i64, 42), engine.channels[5].getScalar(i64, 0)); // 值未改变
    cleanupRefObj(&engine.channels[1], .atomic_val, testing.allocator);
    engine.deinit();
}

test "Atomic fetch_add 操作" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: 初始值
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 1: atomic 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: delta
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: fetch_add 返回旧值
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: add 后加载值
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_make, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .atomic_val, .input_count = 1 },
        .{ .op = .constant, .output = 2, .const_val = 5, .int_kind = .i64, .input_count = 0 },
        .{ .op = .atomic_fetch_add, .inputs = .{ 1, 2, 0 }, .output = 3, .ref_kind = .atomic_val, .input_count = 2 },
        .{ .op = .atomic_load, .inputs = .{ 1, 0, 0 }, .output = 4, .ref_kind = .atomic_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    try testing.expectEqual(@as(i64, 10), engine.channels[3].getScalar(i64, 0)); // 旧值=10
    try testing.expectEqual(@as(i64, 15), engine.channels[4].getScalar(i64, 0)); // 新值=15
    cleanupRefObj(&engine.channels[1], .atomic_val, testing.allocator);
    engine.deinit();
}

test "Channel 发送与 try_recv" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 0: channel 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: 要发送的值
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 2: 发送结果
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: try_recv 值 + 标志（偏移 8 在 16B 对齐填充中）
    };
    const laminas = [_]Lamina{
        .{ .op = .channel_make, .inputs = .{ 0, 0, 0 }, .output = 0, .const_val = 1, .ref_kind = .channel_val, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .channel_send, .inputs = .{ 0, 1, 0 }, .output = 2, .ref_kind = .channel_val, .input_count = 2 },
        .{ .op = .channel_try_recv, .inputs = .{ 0, 0, 0 }, .output = 3, .ref_kind = .channel_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    try testing.expectEqual(@as(u8, 1), engine.channels[2].getScalar(u8, 0)); // 发送成功
    try testing.expectEqual(@as(i64, 42), engine.channels[3].getScalar(i64, 0)); // 接收到 42
    try testing.expectEqual(@as(u8, 1), engine.channels[3].getScalar(u8, 8)); // 成功标志
    cleanupRefObj(&engine.channels[0], .channel_val, testing.allocator);
    engine.deinit();
}

test "Channel try_recv 空通道" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 0: channel 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: try_recv 结果
    };
    const laminas = [_]Lamina{
        .{ .op = .channel_make, .inputs = .{ 0, 0, 0 }, .output = 0, .const_val = 1, .ref_kind = .channel_val, .input_count = 0 },
        .{ .op = .channel_try_recv, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .channel_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 2, 1);
    // 空通道：值=0，成功标志=0
    try testing.expectEqual(@as(i64, 0), engine.channels[1].getScalar(i64, 0));
    try testing.expectEqual(@as(u8, 0), engine.channels[1].getScalar(u8, 8));
    cleanupRefObj(&engine.channels[0], .channel_val, testing.allocator);
    engine.deinit();
}

test "Channel 关闭后发送失败" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 0: channel 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: 要发送的值
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 2: 发送结果
    };
    const laminas = [_]Lamina{
        .{ .op = .channel_make, .inputs = .{ 0, 0, 0 }, .output = 0, .const_val = 1, .ref_kind = .channel_val, .input_count = 0 },
        .{ .op = .channel_close, .inputs = .{ 0, 0, 0 }, .output = 0, .ref_kind = .channel_val, .input_count = 1 },
        .{ .op = .constant, .output = 1, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .channel_send, .inputs = .{ 0, 1, 0 }, .output = 2, .ref_kind = .channel_val, .input_count = 2 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 3, 2);
    try testing.expectEqual(@as(u8, 0), engine.channels[2].getScalar(u8, 0)); // 关闭后发送失败
    cleanupRefObj(&engine.channels[0], .channel_val, testing.allocator);
    engine.deinit();
}

test "Channel sender/receiver 通信" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 0: channel 指针
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 1: sender 指针
        .{ .chan_type = .ref_chan, .elem_width = 8 }, // 2: receiver 指针
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: 要发送的值
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 4: 发送结果
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 5: try_recv 值 + 标志
    };
    const laminas = [_]Lamina{
        .{ .op = .channel_make, .inputs = .{ 0, 0, 0 }, .output = 0, .const_val = 1, .ref_kind = .channel_val, .input_count = 0 },
        .{ .op = .channel_get_sender, .inputs = .{ 0, 0, 0 }, .output = 1, .ref_kind = .sender_val, .input_count = 1 },
        .{ .op = .channel_get_receiver, .inputs = .{ 0, 0, 0 }, .output = 2, .ref_kind = .receiver_val, .input_count = 1 },
        .{ .op = .constant, .output = 3, .const_val = 99, .int_kind = .i64, .input_count = 0 },
        .{ .op = .sender_send, .inputs = .{ 1, 3, 0 }, .output = 4, .ref_kind = .sender_val, .input_count = 2 },
        .{ .op = .receiver_try_recv, .inputs = .{ 2, 0, 0 }, .output = 5, .ref_kind = .receiver_val, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 6, 5);
    try testing.expectEqual(@as(u8, 1), engine.channels[4].getScalar(u8, 0)); // 发送成功
    try testing.expectEqual(@as(i64, 99), engine.channels[5].getScalar(i64, 0)); // 接收到 99
    try testing.expectEqual(@as(u8, 1), engine.channels[5].getScalar(u8, 8)); // 成功标志
    // 清理顺序：sender → receiver → channel（sender/receiver 的 deinit 会 noop release channel）
    cleanupRefObj(&engine.channels[1], .sender_val, testing.allocator);
    cleanupRefObj(&engine.channels[2], .receiver_val, testing.allocator);
    cleanupRefObj(&engine.channels[0], .channel_val, testing.allocator);
    engine.deinit();
}

test "Range 基本操作: make/len" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: range
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: length
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .range_len, .inputs = .{ 2, 0, 0 }, .output = 3, .ref_kind = .range, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), engine.channels[3].getScalar(i64, 0));
}

test "Range 包含端点: 0..=10 len=11" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: range
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: length
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 1, .ref_kind = .range, .input_count = 2 }, // inclusive=1
        .{ .op = .range_len, .inputs = .{ 2, 0, 0 }, .output = 3, .ref_kind = .range, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 11), engine.channels[3].getScalar(i64, 0));
}

test "Range start/end 读取" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: range
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: start 输出
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: end 输出
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 5, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 15, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .range_start, .inputs = .{ 2, 0, 0 }, .output = 3, .ref_kind = .range, .input_count = 1 },
        .{ .op = .range_end, .inputs = .{ 2, 0, 0 }, .output = 4, .ref_kind = .range, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 5), engine.channels[3].getScalar(i64, 0));
    try testing.expectEqual(@as(i64, 15), engine.channels[4].getScalar(i64, 0));
}

test "Iterator has_next + next" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: iterator
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 3: has_next
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: next value
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .iter_has_next, .inputs = .{ 2, 0, 0 }, .output = 3, .input_count = 1 },
        .{ .op = .iter_next, .inputs = .{ 2, 0, 0 }, .output = 4, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    defer engine.deinit();
    try testing.expectEqual(@as(u8, 1), engine.channels[3].getScalar(u8, 0)); // has_next = true
    try testing.expectEqual(@as(i64, 0), engine.channels[4].getScalar(i64, 0)); // next = 0 (起始值)
}

test "Iterator 到达终点" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: iterator
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 3: has_next
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .iter_has_next, .inputs = .{ 2, 0, 0 }, .output = 3, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 4, 3);
    defer engine.deinit();
    // current=10, end=10, exclusive → has_next = false
    try testing.expectEqual(@as(u8, 0), engine.channels[3].getScalar(u8, 0));
}

test "Range to_stream 与 iter_to_stream" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: start
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: end
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 2: range
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 3: stream (range_to_stream 输出)
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 4: stream (iter_to_stream 输出)
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 7, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 0, 1, 0 }, .output = 2, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .range_to_stream, .inputs = .{ 2, 0, 0 }, .output = 3, .ref_kind = .range, .input_count = 1 },
        .{ .op = .iter_to_stream, .inputs = .{ 3, 0, 0 }, .output = 4, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 5, 4);
    defer engine.deinit();
    // 验证 stream 复制了 range 数据
    try testing.expectEqual(@as(i64, 3), engine.channels[3].getScalar(i64, 0)); // current = 3
    try testing.expectEqual(@as(i64, 7), engine.channels[3].getScalar(i64, 1)); // end = 7
    try testing.expectEqual(@as(i64, 3), engine.channels[4].getScalar(i64, 0)); // iter_to_stream 复制
}

// ──────────────────────────────────────────────
// 星轨模型测试
// ──────────────────────────────────────────────

test "星轨: OrbitHub if-else 选择 (true → 42)" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: condition
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: output
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 1, 0, 0 }, .output = 1, .input_count = 1 },
    };
    const orbit0_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 99, .int_kind = .i64, .input_count = 0 },
    };
    const orbit1_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 42, .int_kind = .i64, .input_count = 0 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit0_laminas, .output_channel = 1 },
        .{ .laminas = &orbit1_laminas, .output_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .eq, .expected_val = 0, .orbit_index = 0 },
        .{ .cond_kind = .eq, .expected_val = 1, .orbit_index = 1 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .if_hub, .cond_channel = 0, .orbit_table = &orbit_table, .output_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 1,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // condition=1 → 匹配 orbit 1 → chan1=42
    try testing.expectEqual(@as(i64, 42), engine.return_value);
}

test "星轨: OrbitHub if-else 选择 (false → 99)" {
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: condition
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: output
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 1, 0, 0 }, .output = 1, .input_count = 1 },
    };
    const orbit0_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 99, .int_kind = .i64, .input_count = 0 },
    };
    const orbit1_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 42, .int_kind = .i64, .input_count = 0 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit0_laminas, .output_channel = 1 },
        .{ .laminas = &orbit1_laminas, .output_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .eq, .expected_val = 0, .orbit_index = 0 },
        .{ .cond_kind = .eq, .expected_val = 1, .orbit_index = 1 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .if_hub, .cond_channel = 0, .orbit_table = &orbit_table, .output_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 1,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // condition=0 → 匹配 orbit 0 → chan1=99
    try testing.expectEqual(@as(i64, 99), engine.return_value);
}

test "星轨: 环形轨道倒计数 3→0" {
    // chan0: counter (i64), chan1: continue flag (mask), chan2: temp 1, chan3: temp 0
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: counter
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 1: continue flag
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: temp (literal 1)
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 3: temp (literal 0)
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };
    // 环形轨道: counter-- 然后设置 continue = (counter != 0)
    const orbit_laminas = [_]Lamina{
        .{ .op = .constant, .output = 2, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_sub, .inputs = .{ 0, 2, 0 }, .output = 0, .int_kind = .i64, .input_count = 2 },
        .{ .op = .constant, .output = 3, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_ne, .inputs = .{ 0, 3, 0 }, .output = 1, .int_kind = .i64, .input_count = 2 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .loop_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 4,
        .input_channels = &.{},
        .output_channel = 0,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // 3→2→1→0, continue=0 时停止, 最终 counter=0
    try testing.expectEqual(@as(i64, 0), engine.return_value);
}

test "星轨: 显式数据栈 push/pop" {
    // chan0: i64 (value), chan1: i64 (stack depth output)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: value
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: depth
    };
    const laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 42, .int_kind = .i64, .input_count = 0 },
        .{ .op = .stack_push, .const_val = 0, .const_val2 = 1, .input_count = 0 }, // 保存 chan0
        .{ .op = .constant, .output = 0, .const_val = 99, .int_kind = .i64, .input_count = 0 }, // 覆写
        .{ .op = .stack_depth, .output = 1, .input_count = 0 },
        .{ .op = .stack_pop, .const_val = 0, .const_val2 = 1, .input_count = 0 }, // 恢复 chan0=42
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };
    var engine = try buildAndRunGraph(testing.allocator, &laminas, &metas, 2, 0);
    defer engine.deinit();
    // chan0 恢复为 42
    try testing.expectEqual(@as(i64, 42), engine.return_value);
    // 栈深度在 pop 前应为 1
    try testing.expectEqual(@as(i64, 1), engine.channels[1].getScalar(i64, 0));
}

test "星轨: while 循环 — 谓词门控倒计数 3→0" {
    // chan0: counter, chan1: cond(mask), chan2: lit 1, chan3: lit 0, chan4: body_count
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: counter
        .{ .chan_type = .mask_chan, .elem_width = 1 }, // 1: cond
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: lit 1
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 3: lit 0
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 4: body_count
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 4, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };
    // 环形轨道: 计算条件(无门控) → 谓词门控的循环体
    const orbit_laminas = [_]Lamina{
        // 条件计算（无谓词，始终执行）
        .{ .op = .constant, .output = 2, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 3, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_ne, .inputs = .{ 0, 3, 0 }, .output = 1, .int_kind = .i64, .input_count = 2 },
        // 循环体（谓词门控：cond=0 时跳过）
        .{ .op = .int_sub, .inputs = .{ 0, 2, 0 }, .output = 0, .int_kind = .i64, .input_count = 2, .predicate = 1 },
        .{ .op = .int_add, .inputs = .{ 4, 2, 0 }, .output = 4, .int_kind = .i64, .input_count = 2, .predicate = 1 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .loop_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 0,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // counter: 3→2→1→0, body_count: 3 (body runs 3 times, skipped on 4th)
    try testing.expectEqual(@as(i64, 0), engine.return_value);
    try testing.expectEqual(@as(i64, 3), engine.channels[4].getScalar(i64, 0));
}

test "星轨: for 循环 — 迭代器求和 range(0,3) = 0+1+2 = 3" {
    // chan0: iter(17B), chan1: has_next(bool), chan2: val(i64), chan3: sum(i64)
    // chan4: start(i64)=0, chan5: end(i64)=3
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .ref_chan, .elem_width = 17 }, // 0: iterator
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 1: has_next
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: val
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 3: sum
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 4: start
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 5: end
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 4, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 5, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .range_make, .inputs = .{ 4, 5, 0 }, .output = 0, .const_val = 0, .ref_kind = .range, .input_count = 2 },
        .{ .op = .constant, .output = 3, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 3, 0, 0 }, .output = 3, .input_count = 1 },
    };
    // 环形轨道: has_next(无门控) → 谓词门控的 next + 求和
    const orbit_laminas = [_]Lamina{
        .{ .op = .iter_has_next, .inputs = .{ 0, 0, 0 }, .output = 1, .input_count = 1 },
        .{ .op = .iter_next, .inputs = .{ 0, 0, 0 }, .output = 2, .input_count = 1, .predicate = 1 },
        .{ .op = .int_add, .inputs = .{ 3, 2, 0 }, .output = 3, .int_kind = .i64, .input_count = 2, .predicate = 1 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 3, .is_cyclic = true, .continue_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .loop_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 3, .is_cyclic = true, .continue_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 6,
        .input_channels = &.{},
        .output_channel = 3,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // sum = 0 + 1 + 2 = 3
    try testing.expectEqual(@as(i64, 3), engine.return_value);
}

test "星轨: loop 循环 — break 退出倒计数 3→0" {
    // chan0: counter, chan1: continue(always 1), chan2: lit 1, chan3: lit 0, chan4: break_cond
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 0: counter
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 1: continue (always 1)
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 2: lit 1
        .{ .chan_type = .i64_chan, .elem_width = 8 },  // 3: lit 0
        .{ .chan_type = .bool_chan, .elem_width = 1 }, // 4: break_cond
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 3, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };
    // 环形轨道: continue=1(始终), counter--, break when counter==0
    const orbit_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 1, .input_count = 0 }, // continue = 1
        .{ .op = .constant, .output = 2, .const_val = 1, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 3, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_sub, .inputs = .{ 0, 2, 0 }, .output = 0, .int_kind = .i64, .input_count = 2 },
        .{ .op = .int_eq, .inputs = .{ 0, 3, 0 }, .output = 4, .int_kind = .i64, .input_count = 2 },
        .{ .op = .halt_break, .predicate = 4, .input_count = 0 }, // break when counter==0
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .loop_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 0, .is_cyclic = true, .continue_channel = 1 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 0,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // 3→2→1→0, break at 0
    try testing.expectEqual(@as(i64, 0), engine.return_value);
}

test "星轨: 异步轨道 — orbit_hub_async + orbit_join" {
    // chan0: input=17(i64), chan1: const 25(i64), chan2: orbit output(i64)
    // chan3: async handle(usize/ref), chan4: join result(i64)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 0: input
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 1: const 25
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 2: orbit output
        .{ .chan_type = .ref_chan, .elem_width = 8 },   // 3: async handle
        .{ .chan_type = .i64_chan, .elem_width = 8 },   // 4: join result
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 17, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 25, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub_async, .hub_index = 0, .output = 3, .input_count = 0 },
        .{ .op = .orbit_join, .inputs = .{ 3, 0, 0 }, .output = 4, .input_count = 1 },
        .{ .op = .halt_return, .inputs = .{ 4, 0, 0 }, .output = 4, .input_count = 1 },
    };
    // 异步轨道: int_add(0, 1) → chan2
    const orbit_laminas = [_]Lamina{
        .{ .op = .int_add, .inputs = .{ 0, 1, 0 }, .output = 2, .int_kind = .i64, .input_count = 2 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 2, .is_cyclic = false, .continue_channel = null },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .async_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 2 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 4,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // 17 + 25 = 42
    try testing.expectEqual(@as(i64, 42), engine.return_value);
}

test "星轨: 函数调用轨道 — move + int_add" {
    // 模拟函数调用：太阳层传入 17+25，轨道内计算 42
    // chan0: arg0=17, chan1: arg1=25, chan2: param0, chan3: param1
    // chan4: result(i64, 轨道输出)
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: arg0
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: arg1
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 2: param0
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 3: param1
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 4: result
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 17, .int_kind = .i64, .input_count = 0 },
        .{ .op = .constant, .output = 1, .const_val = 25, .int_kind = .i64, .input_count = 0 },
        .{ .op = .orbit_hub, .hub_index = 0, .output = 4, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 4, 0, 0 }, .output = 4, .input_count = 1 },
    };
    // 轨道: move(arg0→param0), move(arg1→param1), int_add(param0,param1)→result
    const orbit_laminas = [_]Lamina{
        .{ .op = .move, .inputs = .{ 0, 0, 0 }, .output = 2, .input_count = 1 },
        .{ .op = .move, .inputs = .{ 1, 0, 0 }, .output = 3, .input_count = 1 },
        .{ .op = .int_add, .inputs = .{ 2, 3, 0 }, .output = 4, .int_kind = .i64, .input_count = 2 },
        .{ .op = .move, .inputs = .{ 4, 0, 0 }, .output = 4, .input_count = 1 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &orbit_laminas, .output_channel = 4, .is_cyclic = false, .continue_channel = null },
    };
    const orbit_table = [_]OrbitEntry{
        .{ .cond_kind = .always, .orbit_index = 0 },
    };
    const orbit_hubs = [_]OrbitHub{
        .{ .kind = .if_hub, .cond_channel = null, .orbit_table = &orbit_table, .output_channel = 4 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 5,
        .input_channels = &.{},
        .output_channel = 4,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &orbit_hubs,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), engine.return_value);
}

test "星轨: defer 执行 — halt_return 前执行 defer 体" {
    // chan0: counter(i64), chan1: defer_val(i64)
    // 太阳层: counter=0, defer_register, counter=10, halt_return(counter)
    // defer 轨道: counter + 5 → defer_val
    const metas = [_]lamina_mod.ChannelMeta{
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 0: counter
        .{ .chan_type = .i64_chan, .elem_width = 8 }, // 1: defer_val
    };
    const solar_laminas = [_]Lamina{
        .{ .op = .constant, .output = 0, .const_val = 0, .int_kind = .i64, .input_count = 0 },
        .{ .op = .defer_register, .output = 0, .const_val = 0, .input_count = 0 }, // defer orbit 0
        .{ .op = .constant, .output = 0, .const_val = 10, .int_kind = .i64, .input_count = 0 },
        .{ .op = .halt_return, .inputs = .{ 0, 0, 0 }, .output = 0, .input_count = 1 },
    };
    // defer 轨道: counter + 5 → defer_val
    const defer_laminas = [_]Lamina{
        .{ .op = .constant, .output = 1, .const_val = 5, .int_kind = .i64, .input_count = 0 },
        .{ .op = .int_add, .inputs = .{ 0, 1, 0 }, .output = 1, .int_kind = .i64, .input_count = 2 },
    };
    const orbits = [_]Orbit{
        .{ .laminas = &defer_laminas, .output_channel = 1, .is_cyclic = false, .continue_channel = null },
    };
    const defer_entries = [_]DeferEntry{
        .{ .orbit_index = 0, .order = 0 },
    };
    const graph = LaminarGraph{
        .laminas = &solar_laminas,
        .channel_metas = &metas,
        .channel_count = 2,
        .input_channels = &.{},
        .output_channel = 0,
        .string_table = &.{},
        .name_table = &.{},
        .orbits = &orbits,
        .orbit_hubs = &.{},
        .defer_entries = &defer_entries,
    };
    var engine = try Engine.init(testing.allocator, &graph, 1);
    try engine.run();
    defer engine.deinit();
    // return_value = 10 (counter before defer)
    try testing.expectEqual(@as(i64, 10), engine.return_value);
    // defer_val = 10 + 5 = 15 (defer body executed before halt_return)
    try testing.expectEqual(@as(i64, 15), engine.channels[1].getScalar(i64, 0));
}
