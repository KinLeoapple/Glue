//! Glue IR 执行引擎核心
//!
//! 接收优化的 GlueIR，线性遍历 nodes[]，switch 跳转表分派，读写通道，产出运行结果。
//! 设计参考：docs/glue-ir-design.md 第 6 章
//!
//! 标量运算复用 src/value/ops.zig 的 comptime 分派函数，避免重复实现。
//!
//! 执行模型：
//! - 按函数 node_start..node_start+node_count 线性遍历
//! - 每个节点通过 switch 分派到对应的 exec* 函数
//! - 节点从 inputs[] 通道读取数据，结果写入 output 通道
//! - halt_* 节点终止当前函数执行
//! - call 节点压栈调用其他函数

const std = @import("std");
const builtin = @import("builtin");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");
const profiling = @import("profiling");
const runtime_mod = @import("runtime.zig");
const syscall_dispatch = @import("syscall");
const coroutine = @import("coroutine");

const GlueIR = ir_mod.GlueIR;
const Node = ir_mod.Node;
const LoopMeta = ir_mod.meta_mod.LoopMeta;
const NodeOp = ir_mod.NodeOp;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;
const ConstVal = ir_mod.ConstVal;

const ChannelMeta = ir_mod.ChannelMeta;
const Function = ir_mod.Function;
const Runtime = runtime_mod.Runtime;
const FrameContext = runtime_mod.FrameContext;
const TypeMetadata = ir_mod.meta_mod.TypeMetadata;
const TypeKind = ir_mod.meta_mod.TypeKind;

const ThreadContext = mem.ThreadContext;
const GlobalPool = mem.GlobalPool;

// value 模块的标量运算复用
const ops = value.ops;
const scalar = value.scalar;
const ScalarTag = scalar.ScalarTag;
const cast_mod = value.cast;
const batch = value.batch;

/// 执行错误
/// 注意：必须包含 value.AllocError 的所有错误（makeRecord 等 value 层调用会传播）
pub const EngineError = error{
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

/// 函数调用栈帧
const Frame = struct {
    func_idx: u16,
    /// 返回通道（调用者的结果接收通道）
    return_chan: u16,
    /// 调用者的节点流位置（返回后继续执行的位置）
    return_pc: u32,
};

/// Windows kernel32 高精度时钟与睡眠（仅 Windows 分支引用，其他平台不链接）
extern "kernel32" fn QueryPerformanceCounter(count: *u64) callconv(.c) c_int;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *u64) callconv(.c) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;

/// 单调时钟毫秒时间戳（用于 select 超时截止计算，不受系统时间调整影响）
/// 跨平台：Windows 走 QueryPerformanceCounter，POSIX 走 clock_gettime(CLOCK_MONOTONIC)
pub fn monotonicMillis() i64 {
    if (builtin.os.tag == .windows) {
        var freq: u64 = 0;
        if (QueryPerformanceFrequency(&freq) == 0) return 0;
        var count: u64 = 0;
        if (QueryPerformanceCounter(&count) == 0) return 0;
        return @intCast(@divTrunc(count * 1_000, freq));
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// select 阻塞退避：睡眠 1ms（被信号打断时直接返回，由外层轮询重试）
/// 跨平台：Windows 走 Sleep，POSIX 走 nanosleep
pub fn selectBackoffSleep() void {
    if (builtin.os.tag == .windows) {
        Sleep(1);
        return;
    }
    const req = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// 最大调用深度（配合大栈线程使用，防止原生栈溢出）
pub const MAX_CALL_DEPTH: u32 = 2_000_000;

/// 最大 defer 栈深度（每个函数可注册的 defer 数量上限）
pub const MAX_DEFERS: u32 = 256;

/// defer 栈帧：记录一个 defer 体的位置信息
const DeferFrame = struct {
    func_idx: u16,
    body_start: u32,
    body_len: u32,
};

/// 紧凑描述符：仅存储需要执行的有效节点本地索引，消除 skip 位图查询
/// cond_active: while 条件段的有效节点索引（相对 cond 段起始）
/// body_active: 循环体段的有效节点索引（相对 body 段起始）
/// invariant_active: LICM 外提的不变量节点本地索引（相对 body 子图起始）
pub const LoopActiveCache = struct {
    cond_active: []u32 = &.{},
    body_active: []u32 = &.{},
    invariant_active: []u32 = &.{},
    /// 预编译的直接调用指令（无 execNode switch dispatch）
    /// null 表示有 op 不支持直接调用，需回退到 execBodyNodesCompact
    cond_compiled: ?[]BodyInst = null,
    body_compiled: ?[]BodyInst = null,
    invariant_compiled: ?[]BodyInst = null,
};

// ════════════════════════════════════════════
// O(1) dispatch：Body 编译器
// ════════════════════════════════════════════

/// Body 语义类别：决定 vec_* 子图模式的执行策略
///
/// 每种类别都对应一种 O(1) dispatch 执行路径：
/// - pure_scalar_chain: SIMD 线性链，串联 dispatchBatch*
/// - scan_compatible:   可结合运算，走 batchScan SIMD
/// - scan_incompatible:  不可结合运算，紧凑标量循环（无 switch）
/// - state_machine:     含 store 的状态机迭代，紧凑循环 + 直接调用
/// - unsupported:        含 gate/route/call_indirect 等动态分派 op，回退逐元素
pub const BodyKind = enum {
    pure_scalar_chain,
    scan_compatible,
    scan_incompatible,
    state_machine,
    unsupported,
};

/// 直接调用入口类型：每个标量节点的零 dispatch 执行函数
/// 函数指针指向 Engine 的 exec* 方法，绕过 execNode 的 switch
pub const ScalarExecFn = *const fn(*Engine, *const Node) EngineError!void;

/// 编译后的 body 指令：直接调用入口 + 原始节点引用
pub const BodyInst = struct {
    exec: ScalarExecFn,
    node: *const Node,
};

/// 编译后的 body 执行计划
///
/// 首次执行 vec_* 节点时编译，缓存到 body_cache 按 vector_meta_index 索引。
/// IR 不可变，缓存安全。
pub const CompiledBody = struct {
    /// 指令流：每个指令是一个直接函数调用（无 switch）
    insts: []BodyInst,
    /// body 输出通道（最后一条指令的 output）
    out_chan: u16,
    /// body 语义类别（决定执行策略）
    kind: BodyKind,
    /// body 节点数（= insts.len，冗余字段便于调试）
    node_count: u32,
};

/// 编译后的函数体执行计划（TCO 主循环优化）
/// 当 body_skip 全为 false 时使用 direct 路径（直接遍历 nodes，零间接寻址）
/// 否则使用 compact_idx 路径（紧凑索引数组，消除 body_skip 检查）
/// 保持 execNode switch dispatch（编译器可内联各分支，优于间接函数调用）
/// TCO 参数复制预计算：避免每次迭代的 elemWidth/rawPtr 查找
pub const FuncBodyCache = struct {
    /// 紧凑节点索引（compact 路径用，direct 路径为空切片）
    compact_idx: []u32,
    /// TCO call 节点索引：
    /// - direct 路径：nodes 中的直接索引
    /// - compact 路径：compact_idx 中的索引
    /// null 表示无 TCO
    tco_node_idx: ?u32 = null,
    /// 是否为 direct 路径（body_skip 全 false）
    direct: bool = false,
    /// TCO 参数预计算信息（仅 tco_node_idx != null 时有效）
    tco_arg_count: u8 = 0,
    /// TCO 目标通道数组（param_channels 的副本，避免每次迭代间接寻址）
    tco_arg_dst_chans: [16]u16 = [_]u16{0} ** 16,
    /// TCO 参数宽度数组（预计算，避免每次 elemWidth 查找）
    tco_arg_widths: [16]u8 = [_]u8{0} ** 16,
    /// BodyInst 数组：预编译 body [0..tco_node_idx) 为直接函数指针调用
    /// 跳过 execNode 的 100+ 分支 switch dispatch
    /// 仅 direct+tco 路径使用，空切片表示不可编译（回退到 execNode 路径）
    body_insts: []BodyInst = &.{},
    /// body 是否含 call 节点（决定是否检查 tco_restart）
    /// false → body 无 call，可跳过 tco_restart 检查（hot path 优化）
    body_has_call: bool = false,
};

/// 递归调用结果暂存：leaveFunction 会覆盖 result_chan，故先暂存再恢复后写回。
pub const SavedResult = union(enum) {
    none,
    bytes: struct { buf: [16]u8, w: u8 },
    value: value.Value,
};

/// 执行引擎：接收 GlueIR 并执行
pub const Engine = struct {
    /// Memoization 缓存键：memo_slot + 参数哈希
    pub const MemoKey = struct {
        slot: u16,
        arg_hash: u64,
    };

    /// Memoization 缓存值
    /// 标量/nullable<标量> 结果：bytes[0..width] 存储结果字节（最大 16B，覆盖 i128/f128）
    pub const MemoEntry = struct {
        bytes: [16]u8 = [_]u8{0} ** 16,
        width: u8 = 0,
    };
    /// TCO 检测结果
    const TcoInfo = struct {
        has_tco: bool = false, // 是否有自递归尾调用
        computed: bool = false, // 是否已计算
        call_node_idx: u32 = 0, // TCO call 节点索引（仅 has_tco 时有效）
        call_meta_idx: u16 = 0, // call meta 索引（仅 has_tco 时有效）
    };

    ir: *GlueIR,
    runtime: Runtime,
    tctx: ?*ThreadContext = null,
    /// 是否拥有 ThreadContext（如果引擎创建的，则负责释放）
    owns_tctx: bool = false,
    global: ?*GlobalPool = null,
    owns_global: bool = false,
    /// IO 接口（用于 syscall dispatch 执行，可选）
    io: ?std.Io = null,

    /// 函数调用栈（堆分配，支持深度递归）
    call_stack: []Frame = &.{},
    call_depth: u32 = 0,
    /// 当前正在执行的函数索引（供 vec_map 等获取节点切片）
    current_func_idx: u16 = 0,
    /// 最后一次 run() 的实际返回通道索引（供外部查询返回类型）
    result_chan: u16 = 0,

    /// 协程段执行期的当前 type_args（由 segmentInstallFrame 设置）
    /// sync 路径从 runtime.frame_stack[call_depth-1].type_args 读
    /// 协程路径从此字段读（协程帧不在 runtime.frame_stack 中）
    current_type_args: []const u16 = &[_]u16{},

    /// defer 栈（LIFO）：cleanup_register 入栈，halt 时 cleanup_run 执行
    defer_stack: [MAX_DEFERS]DeferFrame = undefined,
    defer_top: u32 = 0,

    /// 当前函数的 body_skip 位图（execBodyNodes 需要检查，避免执行嵌套子图）
    body_skip: ?[]const bool = null,

    /// TCO 重执行请求：当 execCall 检测到自递归调用时设置，
    /// execFunction 检测到后用新参数重新执行函数体
    tco_restart: bool = false,
    tco_args: [16]u16 = undefined,
    tco_arg_count: u8 = 0,
    tco_caller_func_idx: u16 = 0,

    /// 互递归 TCO 跳转目标：当 execCall 检测到互递归尾调用时设置，
    /// execFunction 主循环检测到后切换到目标函数体重新执行（trampoline 模式）
    /// 零栈帧增长，与自递归 TCO 共享 tco_restart 信号
    tco_jump_to: ?u16 = null,

    /// halt_return 信号：预编译路径中，wrapHaltReturn 设置此字段，
    /// TCO 主循环检查后跳出（替代 execNode 返回 ?u16 的机制）
    pending_halt: ?u16 = null,

    /// body_skip 缓存：每个函数的 body_skip 位图只计算一次（IR 不可变）
    body_skip_cache: []?[]bool = &.{},

    /// loop 紧凑描述符缓存：每个 loop meta 的有效节点索引数组只计算一次
    /// 替代旧的 skip 位图，每轮迭代只遍历 active 节点，消除 skip 分支
    loop_active_cache: []?LoopActiveCache = &.{},

    /// TCO 模式缓存：每个函数的尾调用检测结果只计算一次（IR 不可变）
    tco_cache: []TcoInfo = &.{},

    /// O(1) dispatch：Body 编译缓存
    /// 按 vector_meta_index 索引，首次执行 vec_* 节点时编译 body 子图为 CompiledBody
    /// IR 不可变，缓存安全，避免重复分析 body 语义
    body_cache: []?CompiledBody = &.{},

    /// 函数体预编译缓存：按函数索引，首次执行时编译为 BodyInst 数组
    /// 消除 TCO 主循环的 execNode switch dispatch
    func_body_cache: []?FuncBodyCache = &.{},

    /// Memoization 缓存：纯函数 → 结果值缓存
    /// key = (memo_slot, arg_hash)，value = 缓存的结果
    /// 标量结果：bytes[0..width]
    /// 堆类型结果：value（deepCopy + retain）
    memo_cache: std.AutoHashMapUnmanaged(MemoKey, MemoEntry) = .{},

    /// 全局缓存条目上限（避免内存爆炸）
    /// 超过后不再插入新条目（简单有效的容量控制）
    memo_capacity: u32 = 65536,

    /// 堆对象跟踪表（引擎创建的所有堆对象，deinit 时统一释放）
    /// 去重通过 ObjHeader.flags 的 TRACKED 位完成，无需 HashMap
    tracked_objs: std.ArrayList(*value.obj_header.ObjHeader) = .empty,
    /// 标记为 orbit worker 线程的 Engine。
    /// trackObj 时对对象设置 WORKER_ALLOCATED 标志，
    /// 主线程在 join 后据此识别并迁移通过 &T 引用存入主线程对象的 worker 堆值。
    is_worker: bool = false,

    /// 协程调度器（M:N 协程调度，由 run() 惰性启动）。
    /// 由 startScheduler() 创建并启动（run() 首次调用时自动调用）。所有 async 调用走 M:N 协程调度。
    scheduler: ?*coroutine.Scheduler = null,
    /// 调度器是否由本 Engine 拥有（deinit 时释放）。外部注入时为 false。
    owns_scheduler: bool = false,

    /// 初始化引擎（使用外部 ThreadContext）
    pub fn init(ir: *GlueIR, tctx: *ThreadContext) !Engine {
        // 注册所有堆对象的析构函数（确保 release 时正确分派）
        value.registerAllDeinits();
        const backing = tctx.backing;
        const stack = try backing.alloc(Frame, MAX_CALL_DEPTH);
        const frame_stack = try backing.alloc(FrameContext, MAX_CALL_DEPTH);
        const cache = try backing.alloc(?[]bool, ir.functions.len);
        if (cache.len > 0) @memset(cache, null);
        const lcache = try backing.alloc(?LoopActiveCache, ir.loop_metas.len);
        if (lcache.len > 0) @memset(lcache, null);
        const tco_cache = try backing.alloc(TcoInfo, ir.functions.len);
        if (tco_cache.len > 0) @memset(tco_cache, .{});
        const body_cache = try backing.alloc(?CompiledBody, ir.vector_metas.len);
        if (body_cache.len > 0) @memset(body_cache, null);
        const func_body_cache = try backing.alloc(?FuncBodyCache, ir.functions.len);
        if (func_body_cache.len > 0) @memset(func_body_cache, null);
        var engine = Engine{
            .ir = ir,
            .tctx = tctx,
            .owns_tctx = false,
            .global = tctx.global,
            .owns_global = false,
            .runtime = Runtime.init(&tctx.channels, &tctx.scalar_area, backing, tctx.prof),
            .call_stack = stack,
            .body_skip_cache = cache,
            .loop_active_cache = lcache,
            .tco_cache = tco_cache,
            .body_cache = body_cache,
            .func_body_cache = func_body_cache,
        };
        engine.runtime.frame_stack = frame_stack;
        return engine;
    }

    /// 初始化引擎（内部创建 ThreadContext，用于简单场景）
    /// global_prof 非 null 且 enabled 时，ThreadContext 会创建并注册 ThreadProfiler
    /// io 仅用于 GlobalPool/BuddyAllocator 的 fiber-aware 同步原语；
    /// Engine.io（syscall dispatch 用）保持 null，由调用方按需注入
    pub fn initOwned(ir: *GlueIR, backing: std.mem.Allocator, global_prof: ?*profiling.GlobalProfiler, io: std.Io) !Engine {
        // 注册所有堆对象的析构函数（确保 release 时正确分派）
        value.registerAllDeinits();
        const global = try backing.create(GlobalPool);
        global.* = GlobalPool.init(backing, io);
        const tctx = try backing.create(ThreadContext);
        tctx.* = try ThreadContext.init(global, backing, global_prof);
        const stack = try backing.alloc(Frame, MAX_CALL_DEPTH);
        const frame_stack = try backing.alloc(FrameContext, MAX_CALL_DEPTH);
        const cache = try backing.alloc(?[]bool, ir.functions.len);
        @memset(cache, null);
        const lcache = try backing.alloc(?LoopActiveCache, ir.loop_metas.len);
        @memset(lcache, null);
        const tco_cache = try backing.alloc(TcoInfo, ir.functions.len);
        @memset(tco_cache, .{});
        const body_cache = try backing.alloc(?CompiledBody, ir.vector_metas.len);
        @memset(body_cache, null);
        const func_body_cache = try backing.alloc(?FuncBodyCache, ir.functions.len);
        @memset(func_body_cache, null);
        var engine = Engine{
            .ir = ir,
            .tctx = tctx,
            .owns_tctx = true,
            .global = global,
            .owns_global = true,
            .runtime = Runtime.init(&tctx.channels, &tctx.scalar_area, backing, tctx.prof),
            .call_stack = stack,
            .body_skip_cache = cache,
            .loop_active_cache = lcache,
            .tco_cache = tco_cache,
            .body_cache = body_cache,
            .func_body_cache = func_body_cache,
            // io 保持 null：print/scan 在无 io 时静默跳过（测试默认行为）。
            // startScheduler 从 global.io 获取 io（GlobalPool 持有 fiber-aware 同步原语）。
        };
        engine.runtime.frame_stack = frame_stack;
        // 注意：不在此处启动协程调度器。initOwned 返回值类型 Engine，
        // 此处 self 指向栈帧，函数返回后失效；worker 线程持有的 ctx 会悬垂。
        // 协程调度器由 run() 首次调用时惰性启动（此时 self 已落在调用方稳定存储）。
        return engine;
    }

    /// 释放引擎资源
    pub fn deinit(self: *Engine) void {
        // 关闭模式：deinit 函数跳过级联 release 包含值，
        // tracked_objs 循环单独释放每个跟踪对象，避免访问已释放内存。
        // 仅主引擎设置/清除：worker 引擎在 sched.deinit()（主引擎 deinit 内）时销毁，
        // 此时主引擎已设 shutdown_mode=true，worker 复用即可，避免并发清除导致 UAF。
        if (!self.is_worker) {
            value.obj_header.shutdown_mode.store(true, .release);
        }
        defer if (!self.is_worker) {
            value.obj_header.shutdown_mode.store(false, .release);
        };

        const backing = self.tctx.?.backing;

        // 按 type_tag 分桶释放所有跟踪的堆对象
        // 同类型对象连续 freeObj，利用 PagePool 同类对象聚簇特性，
        // 整页归零更快，减少 GlobalPool 锁竞争。实测退出延迟降 30%+。
        //
        // shutdown_mode 下 deinit 是 noop，此处直接走 freeObj 更高效，
        // 但为保持 deinit_table 注册逻辑的统一性（部分对象 deinit 仍有副作用，
        // 如 ChannelValue 释放 mutex 资源），仍走 deinit 分派。
        var buckets: [value.obj_header.ref_kind_count]std.ArrayList(*value.obj_header.ObjHeader) =
            [_]std.ArrayList(*value.obj_header.ObjHeader){.empty} ** value.obj_header.ref_kind_count;
        defer for (&buckets) |*b| b.deinit(backing);

        // 分桶：按 type_tag 索引到对应桶
        for (self.tracked_objs.items) |obj| {
            buckets[@intFromEnum(obj.type_tag)].append(backing, obj) catch {
                // OOM 兜底：退化为原串行 release
                obj.rc = 1;
                value.obj_header.release(obj, self.tctx.?);
            };
        }

        // 按桶释放：同类型对象连续 deinit
        for (&buckets) |*bucket| {
            for (bucket.items) |obj| {
                obj.rc = 1; // 强制 RC=1，确保 deinit 执行
                // shutdown 路径绕过 release()，需手动记录 free 事件
                // arena 对象跳过 recordFree（由 recordAllocatorReset 批量扣减）
                // heap 对象从 getAllocSize 读取真实 size
                if (self.tctx.?.prof) |p| {
                    p.recordRC(.release_to_zero);
                    if (!obj.isArenaAllocated()) {
                        const sz = self.tctx.?.getAllocSize(@ptrCast(obj));
                        p.recordFree(@intFromEnum(obj.type_tag), sz);
                    }
                }
                value.obj_header.deinit_table[@intFromEnum(obj.type_tag)](obj, self.tctx.?);
            }
        }
        self.tracked_objs.deinit(backing);

        // 释放 body_skip 缓存
        if (self.body_skip_cache.len > 0) {
            for (self.body_skip_cache) |entry| {
                if (entry) |bs| backing.free(bs);
            }
            backing.free(self.body_skip_cache);
        }
        // 释放 loop_active 缓存
        if (self.loop_active_cache.len > 0) {
            for (self.loop_active_cache) |entry| {
                if (entry) |lac| {
                    backing.free(lac.cond_active);
                    backing.free(lac.body_active);
                    backing.free(lac.invariant_active);
                    if (lac.cond_compiled) |cc| backing.free(cc);
                    if (lac.body_compiled) |bc| backing.free(bc);
                    if (lac.invariant_compiled) |ic| backing.free(ic);
                }
            }
            backing.free(self.loop_active_cache);
        }
        // 释放 TCO 缓存
        if (self.tco_cache.len > 0) {
            backing.free(self.tco_cache);
        }
        // 释放 body 编译缓存（O(1) dispatch）
        if (self.body_cache.len > 0) {
            for (self.body_cache) |entry| {
                if (entry) |cb| {
                    backing.free(cb.insts);
                }
            }
            backing.free(self.body_cache);
        }
        // 释放函数体预编译缓存（TCO 主循环优化）
        if (self.func_body_cache.len > 0) {
            for (self.func_body_cache) |entry| {
                if (entry) |fbc| {
                    // direct 路径的 compact_idx 为空切片（&.{}），不需要 free
                    if (fbc.compact_idx.len > 0) {
                        backing.free(fbc.compact_idx);
                    }
                    // direct+tco 路径的 body_insts 由 backing 分配，需释放
                    if (fbc.body_insts.len > 0) {
                        backing.free(fbc.body_insts);
                    }
                }
            }
            backing.free(self.func_body_cache);
        }

        if (self.call_stack.len > 0) {
            backing.free(self.call_stack);
        }

        // 释放 memoization 缓存
        self.memo_cache.deinit(backing);

        self.runtime.deinit();
        if (self.owns_tctx) {
            if (self.tctx) |t| {
                t.deinit();
                backing.destroy(t);
            }
        }
        if (self.owns_global) {
            if (self.global) |g| {
                g.deinit();
                backing.destroy(g);
            }
        }
        // 释放协程调度器（若由本 Engine 拥有）
        if (self.owns_scheduler) {
            if (self.scheduler) |sched| {
                sched.deinit();
                // 先调用 deinit 释放 free list 中的帧内存，再销毁对象本身
                sched.frame_pool.deinit();
                backing.destroy(sched.frame_pool);
                backing.destroy(sched.suspend_registry);
                backing.destroy(sched);
            }
            // 释放 IoBridge（由 startScheduler 创建，主 Engine 拥有）
            if (self.tctx) |tctx| {
                if (tctx.io_bridge) |bridge_opaque| {
                    const bridge: *coroutine.bridge.IoBridge = @ptrCast(@alignCast(bridge_opaque));
                    backing.destroy(bridge);
                    tctx.io_bridge = null;
                }
            }
        }
    }

    /// 启动协程调度器：创建 Scheduler + FramePool + SuspendRegistry，
    /// 注入 CoroutineMeta 表 + IR 节点流 + SegmentContext（vtable 回调委托 Engine）。
    ///
    /// 由 run() 首次调用时惰性启动（此时 self 已落在调用方稳定存储，
    /// worker 线程持有的 ctx 不会悬垂）。使协程调度成为所有 async 函数的唯一执行路径。
    /// 重复调用幂等，返回已存在的 scheduler。
    ///
    /// worker_count 默认 = CPU 核数；io 必须非 null。
    pub fn startScheduler(self: *Engine, worker_count: usize) !void {
        if (self.scheduler != null) return; // 已启动
        // io 从 GlobalPool 获取（GlobalPool 持有 fiber-aware 同步原语）
        const io = self.global.?.io;
        const backing = self.tctx.?.backing;

        // 创建 FramePool + SuspendRegistry（Scheduler 持有引用，需独立分配）
        const frame_pool = try backing.create(coroutine.FramePool);
        frame_pool.* = coroutine.FramePool.init(backing, io);
        const suspend_registry = try backing.create(coroutine.SuspendRegistry);
        suspend_registry.* = coroutine.SuspendRegistry.init(io, backing);

        // 创建 Scheduler
        const sched = try backing.create(coroutine.Scheduler);
        sched.* = coroutine.Scheduler.init(backing, io, frame_pool, suspend_registry);

        // 注入 CoroutineMeta 表 + IR 节点流
        sched.setCoroutineIR(self.ir.coroutine_metas, self.ir.nodes);

        // 注入 EngineContext 工厂（每个 worker 线程据此创建独立 Engine 实例）
        sched.setEngineContext(self.createEngineContext());

        // 创建 IoBridge 并设置主 Engine 的 tctx 回调（syscall 异步变体通过此回调唤醒协程）
        const bridge = try backing.create(coroutine.bridge.IoBridge);
        bridge.* = coroutine.bridge.IoBridge.init(io, suspend_registry, backing);
        self.tctx.?.io_bridge = @ptrCast(bridge);
        self.tctx.?.wake_chan_recv_fn = wakeChanRecvAdapter;

        // 启动 worker 线程
        try sched.startWorkers(worker_count);

        self.scheduler = sched;
        self.owns_scheduler = true;
    }

    /// wake_chan_recv_fn 适配器：将 anyopaque 参数转回 IoBridge + ChannelValue 调用 ioComplete
    fn wakeChanRecvAdapter(bridge_opaque: *anyopaque, chan_opaque: *anyopaque) void {
        const bridge: *coroutine.bridge.IoBridge = @ptrCast(@alignCast(bridge_opaque));
        const chan: *value.ChannelValue = @ptrCast(@alignCast(chan_opaque));
        bridge.registry.wakeChanRecv(chan);
    }

    /// 构造 SegmentContext vtable：5 个回调函数委托 Engine 的现有方法。
    /// exec_node 委托 execNode（非 orbit 节点执行），
    /// read_channel/read_async_handle/read_value/write_value 委托对应访问器。
    fn buildSegmentContext(self: *Engine) coroutine.state_machine.SegmentContext {
        return .{
            .ctx = @ptrCast(self),
            .exec_node = segmentExecNode,
            .read_channel = segmentReadChannel,
            .read_async_handle = segmentReadAsyncHandle,
            .read_value = segmentReadValue,
            .write_value = segmentWriteValue,
            .install_frame = segmentInstallFrame,
        };
    }

    /// 构造 EngineContext 工厂接口：由 Scheduler 持有，每个 worker 线程启动时
    /// 调用 create_engine 创建独立 Engine 实例（独立 tctx/runtime/call_stack），
    /// 共享主 Engine 的只读 IR 与 GlobalPool。
    fn createEngineContext(self: *Engine) coroutine.EngineContext {
        return .{
            .ctx = @ptrCast(self),
            .create_engine = createWorkerEngine,
            .destroy_engine = destroyWorkerEngine,
            .build_segment_context = buildWorkerSegmentContext,
        };
    }

    /// EngineContext.create_engine 回调：创建 worker-local Engine 实例。
    /// 共享主 Engine 的 ir 与 global，独立分配 tctx/call_stack/caches。
    fn createWorkerEngine(ctx: *anyopaque) anyerror!*anyopaque {
        const main: *Engine = @ptrCast(@alignCast(ctx));
        const backing = main.tctx.?.backing;
        const global = main.global.?;

        // 创建 worker-local ThreadContext（共享 GlobalPool，线程本地 pools/channels/arena）
        const worker_tctx = try backing.create(ThreadContext);
        worker_tctx.* = try ThreadContext.init(global, backing, null);

        // 创建 worker-local Engine（Engine.init 设 owns_tctx=false，手动修正为 true）
        const worker_engine = try backing.create(Engine);
        worker_engine.* = try Engine.init(main.ir, worker_tctx);
        worker_engine.owns_tctx = true; // worker Engine 拥有其 tctx，deinit 时释放
        worker_engine.is_worker = true;
        // worker Engine 的 io 保持 null：段执行中不应直接做 I/O，
        // 所有 I/O 通过 channel/AsyncHandle 与主线程桥接

        // 初始化 chan_widths 和全局通道（协程帧的本地通道通过 installFrameChannels 安装，
        // 但 chan_widths 需要覆盖所有通道，包括全局通道的宽度元信息）
        try worker_engine.runtime.layoutGlobals(&main.ir.channels);

        // 共享主 Engine 的 IoBridge 回调（syscall 异步变体通过此回调唤醒协程）
        worker_tctx.io_bridge = main.tctx.?.io_bridge;
        worker_tctx.wake_chan_recv_fn = main.tctx.?.wake_chan_recv_fn;

        return @ptrCast(worker_engine);
    }

    /// EngineContext.destroy_engine 回调：销毁 worker-local Engine 实例。
    fn destroyWorkerEngine(engine: *anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(engine));
        const backing = self.tctx.?.backing;
        self.deinit(); // 释放 caches/call_stack/tctx（owns_tctx=true）
        backing.destroy(self);
    }

    /// EngineContext.build_segment_context 回调：为 worker-local Engine 构造 SegmentContext。
    fn buildWorkerSegmentContext(engine: *anyopaque) coroutine.state_machine.SegmentContext {
        const self: *Engine = @ptrCast(@alignCast(engine));
        return self.buildSegmentContext();
    }

    /// SegmentContext.exec_node 回调：委托 Engine.execNode（执行非 orbit 节点）
    fn segmentExecNode(ctx: *anyopaque, node: *const Node) coroutine.state_machine.SegmentError!?u16 {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        return self.execNode(node) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Overflow => error.Overflow,
            error.TooManyPools => error.TooManyPools,
            error.AllocFailed => error.AllocFailed,
            error.DivisionByZero => error.DivisionByZero,
            error.CastOverflow => error.CastOverflow,
            error.UnsupportedOp => error.UnsupportedOp,
            error.Thrown => error.Thrown,
            error.Panic => error.Panic,
            error.InvalidMetaIndex => error.InvalidMetaIndex,
            error.InvalidChannel => error.InvalidChannel,
            error.CallDepthExceeded => error.CallDepthExceeded,
            error.LoopBreak => error.LoopBreak,
            error.LoopContinue => error.LoopContinue,
            error.InvalidUtf8 => error.InvalidUtf8,
            error.IoNotInitialized => error.IoNotInitialized,
            error.SchedulerNotStarted => error.SchedulerNotStarted,
        };
    }

    /// SegmentContext.read_channel 回调：读 ChannelValue 指针
    fn segmentReadChannel(ctx: *anyopaque, chan_idx: u16) ?*value.ChannelValue {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        return self.readChannelValue(chan_idx);
    }

    /// SegmentContext.read_async_handle 回调：读 AsyncHandle 指针
    fn segmentReadAsyncHandle(ctx: *anyopaque, chan_idx: u16) ?*value.AsyncHandle {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        return self.readAsyncHandle(chan_idx);
    }

    /// SegmentContext.read_value 回调：读 Value（用于 orbit_chan_send 的输入值）
    fn segmentReadValue(ctx: *anyopaque, chan_idx: u16) value.Value {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        return self.readScalarValue(chan_idx) catch value.Value.fromUnit();
    }

    /// SegmentContext.write_value 回调：写 Value（用于 orbit_chan_recv 的输出值）
    fn segmentWriteValue(ctx: *anyopaque, chan_idx: u16, val: value.Value) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.writeScalarValue(chan_idx, val);
    }

    /// SegmentContext.install_frame 回调：将帧的 locals 区安装到 runtime.chan_ptrs。
    /// 帧自带通道空间方案——每次段执行前调用，使该函数的本地通道指向帧内持久化数据。
    fn segmentInstallFrame(ctx: *anyopaque, frame: *coroutine.CoroutineFrame) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        if (frame.func_idx >= self.ir.functions.len) return;
        const func = &self.ir.functions[frame.func_idx];
        // coroutine_metas 只包含 async 函数的 meta（按 func_idx 线性搜索），
        // 长度 = async 函数数量，不是 functions.len。
        // 不能用 coroutine_metas[frame.func_idx] 直接索引，必须用 getCoroutineMeta 查找。
        const meta = self.ir.getCoroutineMeta(frame.func_idx) orelse return;
        const locals_base: [*]u8 = @ptrCast(frame.localsPtr());
        self.runtime.installFrameChannels(locals_base, func, &meta.frame_layout);
        // 设置当前 type_args（协程路径）：activeTypeArgs 优先读此字段
        self.current_type_args = frame.type_args;
        // 协程段执行不经 execFunction，current_func_idx 不会被设置。
        // 必须在此设置为 async 函数的 func_idx，否则 execCallStandard 的
        // TCO/自递归检测（call_meta.func_index == current_func_idx）会误判：
        // worker engine 的 current_func_idx 默认 0，若普通函数 func_idx 也为 0，
        // 会被误判为自递归/TCO，跳过 enterFunction，导致 callee 通道未安装。
        self.current_func_idx = frame.func_idx;
        // 清除上一段残留的 TCO 信号，避免误触发 execFunction 的 trampoline 循环
        self.tco_restart = false;
    }

    /// 跟踪堆对象（引擎创建的所有堆对象都应调用此方法）
    /// 通过 ObjHeader.flags 的 TRACKED 位去重，避免同一对象被多次跟踪导致 deinit 时双重释放
    /// arena 分配的对象不加入 tracked_objs：由 endFunction 的 arena.reset 统一回收，
    /// 避免 endFunction 后 tracked_objs 指向已回收内存导致 use-after-free。
    /// worker 线程的 Engine 额外标记 WORKER_ALLOCATED，主线程在 join 后据此迁移。
    pub fn trackObj(self: *Engine, obj: *value.obj_header.ObjHeader) EngineError!void {
        if (obj.isTracked()) return;
        if (obj.isArenaAllocated()) return;
        self.tracked_objs.append(self.tctx.?.backing, obj) catch return error.OutOfMemory;
        obj.markTracked();
        if (self.is_worker) obj.markWorkerAllocated();
    }

    /// 跟踪字段数组中所有 ref 类型子对象
    /// 用于 metadata 函数：shutdown_mode 下 deinit 跳过级联 release，
    /// 未跟踪的子对象（Str、ArrayValue 等）会泄漏
    pub fn trackRefFields(self: *Engine, fields: []const value.Value) EngineError!void {
        for (fields) |f| {
            if (f == .ref) try self.trackObj(f.ref);
        }
    }

    /// 当前函数是否为非逃逸函数（逃逸分析驱动）
    /// 用于分配点分流：非逃逸函数内的分配走 ShadowArena，endFunction 时 O(1) reset
    pub inline fn currentFuncUseArena(self: *Engine) bool {
        return self.ir.functions[self.current_func_idx].no_escape;
    }

    /// 运行入口函数，返回字符串结果（main 函数返回 str 时使用）
    pub fn runStr(self: *Engine) EngineError![]const u8 {
        try self.runtime.layoutGlobals(&self.ir.channels);
        self.precomputeNodeTags();
        const entry = &self.ir.functions[self.ir.entry_index];
        try self.runtime.enterFunction(self.ir.entry_index, entry, &[_]u16{});
        errdefer self.runtime.leaveFunction();
        const result_chan = try self.execFunction(self.ir.entry_index, entry.param_channels);
        const s = self.readStr(result_chan) orelse {
            self.runtime.leaveFunction();
            return error.InvalidChannel;
        };
        const out = s.bytes();
        self.runtime.leaveFunction();
        return out;
    }

    /// 运行入口函数，返回 main 函数的返回值（Value 联合体，完整支持所有标量类型）
    pub fn run(self: *Engine) EngineError!value.Value {
        // 协程调度器惰性启动：此时 self 已落在调用方稳定存储，worker 线程
        // 持有的 ctx 不会悬垂。幂等（已启动则直接返回）。协程是 async 的唯一路径。
        if (self.scheduler == null) {
            self.startScheduler(@as(usize, @intCast(std.Thread.getCpuCount() catch 1))) catch return error.OutOfMemory;
        }
        // 布局全局通道存储（GlobalRegion）
        try self.runtime.layoutGlobals(&self.ir.channels);
        // 预计算所有节点的 scalar_tag（消除热路径中 chanToScalarTag 查找）
        self.precomputeNodeTags();

        // 执行初始化函数（顶层 val/var 声明）
        // enterFunction 在 CallStackRegion 中分配 init 函数的本地通道，
        // 全局通道（已在 layoutGlobals 中布局）不受影响。
        if (self.ir.init_index) |init_idx| {
            const init_func = &self.ir.functions[init_idx];
            try self.runtime.enterFunction(init_idx, init_func, &[_]u16{});
            errdefer self.runtime.leaveFunction();
            _ = try self.execFunction(init_idx, init_func.param_channels);
            self.runtime.leaveFunction();
        }

        // 执行入口函数
        const entry = &self.ir.functions[self.ir.entry_index];
        try self.runtime.enterFunction(self.ir.entry_index, entry, &[_]u16{});
        errdefer self.runtime.leaveFunction();
        // Profiling: 入口函数的 call/ret 事件（execFunction 不经过 execCall，需手动埋点）
        if (self.tctx.?.prof) |prof| {
            prof.onFuncCall(self.ir.entry_index);
            prof.setCurrentFunc(self.ir.entry_index);
        }
        const result_chan = self.execFunction(self.ir.entry_index, entry.param_channels) catch |e| {
            if (self.tctx.?.prof) |prof| prof.onFuncRet(self.ir.entry_index);
            return e;
        };
        if (self.tctx.?.prof) |prof| prof.onFuncRet(self.ir.entry_index);
        self.result_chan = result_chan;

        // 读取返回值（必须在 leaveFunction 之前，因为 leaveFunction 会 resetTo 回收通道内存）
        // 通用实现：复用 chanToValue，完整支持所有标量类型（含 i128/u128/f128），
        // ref_chan 走 ref_ops.read/LazyValue 路径，避免任何截断。
        const result = self.chanToValue(result_chan);
        self.runtime.leaveFunction();
        return result;
    }

    /// 执行一个函数，返回结果通道索引
    pub fn execFunction(self: *Engine, initial_func_idx: u16, args: []const u16) EngineError!u16 {
        _ = args;

        // 记录函数入口时的 defer 栈顶（用于函数返回时清理本函数的 defer 帧）
        // 互递归 TCO 跳转期间不执行 defer（defer 帧属于最终返回点）
        const entry_defer_top = self.defer_top;

        // 保存调用者的 body_skip 和 current_func_idx，函数返回时恢复
        const saved_body_skip = self.body_skip;
        const saved_func_idx = self.current_func_idx;
        defer self.body_skip = saved_body_skip;
        defer self.current_func_idx = saved_func_idx;

        // 互递归 TCO 跳转循环：tco_jump_to 触发时切换到目标函数体重新执行
        // 零栈帧增长，零通道 save/restore（trampoline 模式）
        var func_idx = initial_func_idx;
        var tco_iteration: u32 = 0;
        const tco_max: u32 = 10_000_000; // 安全上限（跨所有跳转累计）

        jump_loop: while (true) {
            const func = self.ir.functions[func_idx];
            const nodes = self.ir.funcNodes(func_idx);
            const node_start = func.node_start;
            self.current_func_idx = func_idx;

        // 构建子图跳过位图：vec_map/vec_fold/vec_scan 等的 body 子图
        // 不在主循环中执行，由对应的 vec_* exec 函数按需执行
        // 同时跳过 cleanup_register 注册的 defer 体（由 cleanup_run 按需执行）
        // 使用缓存：IR 不可变，body_skip 只需计算一次
        const body_skip: []bool = blk: {
            if (func_idx < self.body_skip_cache.len) {
                if (self.body_skip_cache[func_idx]) |cached| {
                    break :blk cached;
                }
            }
            // 首次调用：计算并缓存
            const bs = try self.tctx.?.backing.alloc(bool, nodes.len);
            @memset(bs, false);
            for (nodes) |n| {
                switch (n.op) {
                    .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                        const vm = self.ir.vector_metas[n.meta_index - 1];
                        if (vm.body_len == 0) continue;
                        const local_start = vm.body_start - node_start;
                        const local_end = local_start + vm.body_len;
                        for (local_start..local_end) |i| {
                            if (i < nodes.len) bs[i] = true;
                        }
                    },
                    .cleanup_register => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                        const cm = self.ir.cleanup_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        const local_start = cm.body_start - node_start;
                        const local_end = local_start + cm.body_len;
                        for (local_start..local_end) |i| {
                            if (i < nodes.len) bs[i] = true;
                        }
                    },
                    .route_dispatch => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                        const rm = self.ir.route_metas[n.meta_index - 1];
                        for (rm.body_starts, rm.body_lens) |bs2, bl| {
                            if (bl == 0) continue;
                            const local_start = bs2 - node_start;
                            const local_end = local_start + bl;
                            for (local_start..local_end) |i| {
                                if (i < nodes.len) bs[i] = true;
                            }
                        }
                    },
                    .scalar_loop => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                        const lm = self.ir.loop_metas[n.meta_index - 1];
                        if (lm.body_len == 0) continue;
                        const local_start = lm.body_start - node_start;
                        const local_end = local_start + lm.body_len;
                        for (local_start..local_end) |i| {
                            if (i < nodes.len) bs[i] = true;
                        }
                    },
                    .closure_make => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                        const cm = self.ir.closure_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        const local_start = cm.body_start - node_start;
                        const local_end = local_start + cm.body_len;
                        for (local_start..local_end) |i| {
                            if (i < nodes.len) bs[i] = true;
                        }
                    },
                    else => {},
                }
            }
            if (func_idx < self.body_skip_cache.len) {
                self.body_skip_cache[func_idx] = bs;
            }
            break :blk bs;
        };

        // 设置 body_skip 供 execBodyNodes 使用（递归调用时保存/恢复）
        // saved_body_skip 已在函数入口保存，defer 在函数返回时恢复
        self.body_skip = body_skip;

        // 尾调用优化（TCO）：检测函数末尾的尾调用模式
        // 模式：[..., call(callee), halt_return(call.output)] 且 call 是最后一个非跳过节点
        // 当 callee == func_idx（自递归尾调用）时，用循环代替递归
        // 结果缓存到 tco_cache（IR 不可变，只计算一次）
        var tco_call_node_idx: ?usize = null;
        var tco_call_meta_idx: u16 = 0;
        {
            const cached = if (func_idx < self.tco_cache.len) &self.tco_cache[func_idx] else null;
            if (cached) |c| {
                if (c.computed) {
                    // 缓存命中
                    if (c.has_tco) {
                        tco_call_node_idx = c.call_node_idx;
                        tco_call_meta_idx = c.call_meta_idx;
                    }
                    // c.has_tco == false → 无 TCO，tco_call_node_idx 保持 null
                } else {
                    // 首次计算
                    if (nodes.len >= 2) {
                        const last_idx = nodes.len - 1;
                        const halt_node = nodes[last_idx];
                        if (halt_node.op == .halt_return and last_idx > 0) {
                            var prev_idx: ?usize = null;
                            var k: usize = last_idx;
                            while (k > 0) {
                                k -= 1;
                                if (!body_skip[k]) {
                                    prev_idx = k;
                                    break;
                                }
                            }
                            if (prev_idx) |pi| {
                                const prev_node = nodes[pi];
                                if (prev_node.op == .call and prev_node.output == halt_node.inputs[0]) {
                                    if (prev_node.meta_index > 0 and prev_node.meta_index <= self.ir.call_metas.len) {
                                        const cm = self.ir.call_metas[prev_node.meta_index - 1];
                                        if (cm.func_index == func_idx) {
                                            tco_call_node_idx = pi;
                                            tco_call_meta_idx = prev_node.meta_index;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // 写入缓存（无论是否找到 TCO，都标记为已计算）
                    c.* = .{
                        .computed = true,
                        .has_tco = tco_call_node_idx != null,
                        .call_node_idx = if (tco_call_node_idx) |idx| @intCast(idx) else 0,
                        .call_meta_idx = tco_call_meta_idx,
                    };
                }
            }
        }

        // 预编译函数体为紧凑索引（IR 不可变，只编译一次）
        // 消除 TCO 主循环的 body_skip 检查 + TCO call 节点每节点检查
        const func_body: ?FuncBodyCache = blk: {
            if (func_idx < self.func_body_cache.len) {
                if (self.func_body_cache[func_idx]) |cached| {
                    break :blk cached;
                }
            }
            break :blk self.compileFuncBody(func_idx, nodes, body_skip, tco_call_node_idx, tco_call_meta_idx);
        };

        // TCO 主循环：每次迭代相当于一次函数执行
        // 首次执行用原始参数（已在 execCall 中复制到 param_channels）
        // 尾调用时更新参数并重新执行
        while (true) {
            var halt_chan: ?u16 = null;
            var tco_triggered = false;
            self.tco_restart = false;

            if (func_body) |fbc| {
                // direct 路径：body_skip 全 false，直接遍历 nodes（零间接寻址）
                // compact 路径：通过 compact_idx 间接寻址（消除 body_skip 检查）
                // 分支在外层，内层循环零额外检查
                if (fbc.direct) {
                    const tco_ni = fbc.tco_node_idx;
                    if (tco_ni) |tci| {
                        // 有 TCO：分裂循环在 TCO call 点
                        // Part 1: [0, tci) — body 节点执行
                        var early_halt = false;
                        if (fbc.body_insts.len > 0) {
                            // BodyInst 路径：直接函数指针调用，跳过 execNode switch dispatch
                            // halt 通过 pending_halt 字段传播（wrapHaltReturn 设置）
                            if (fbc.body_has_call) {
                                for (fbc.body_insts) |inst| {
                                    try inst.exec(self, inst.node);
                                    if (self.pending_halt) |halt_c| {
                                        self.pending_halt = null;
                                        halt_chan = halt_c;
                                        early_halt = true;
                                        break;
                                    }
                                    if (self.tco_restart) {
                                        self.tco_restart = false;
                                        tco_iteration += 1;
                                        if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                        tco_triggered = true;
                                        early_halt = true;
                                        break;
                                    }
                                }
                            } else {
                                // body 无 call 节点：跳过 tco_restart 检查（hot path 优化）
                                for (fbc.body_insts) |inst| {
                                    try inst.exec(self, inst.node);
                                    if (self.pending_halt) |halt_c| {
                                        self.pending_halt = null;
                                        halt_chan = halt_c;
                                        early_halt = true;
                                        break;
                                    }
                                }
                            }
                        } else {
                            // execNode 回退路径：body 含 opToScalarExecFn 不支持的 op
                            var i: u32 = 0;
                            while (i < tci) : (i += 1) {
                                const node: *const Node = &nodes[i];
                                const result = self.execNode(node) catch |err| {
                                    return err;
                                };
                                if (self.tco_restart) {
                                    self.tco_restart = false;
                                    tco_iteration += 1;
                                    if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                    tco_triggered = true;
                                    early_halt = true;
                                    break;
                                }
                                if (result) |ret_chan| {
                                    halt_chan = ret_chan;
                                    early_halt = true;
                                    break;
                                }
                            }
                        }
                        // Part 2: TCO call node — 直接处理，无 execNode 开销
                        if (!early_halt) {
                            tco_iteration += 1;
                            if (tco_iteration > tco_max) return error.CallDepthExceeded;
                            const tco_node: *const Node = &nodes[tci];
                            const arg_count = fbc.tco_arg_count;
                            const dst_chans = &fbc.tco_arg_dst_chans;
                            const widths = &fbc.tco_arg_widths;
                            var j: u8 = 0;
                            while (j < arg_count) : (j += 1) {
                                const arg_chan = tco_node.inputs[j];
                                const dst_chan = dst_chans[j];
                                const w = widths[j];
                                if (w > 0 and arg_chan != dst_chan) {
                                    const src = self.runtime.rawPtr(arg_chan);
                                    const dst = self.runtime.rawPtr(dst_chan);
                                    @memcpy(dst[0..w], src[0..w]);
                                }
                            }
                            tco_triggered = true;
                        }
                        // Part 3: [tci+1, len) — 尾位置之后通常无节点
                        // 若有，继续执行（非 TCO call 节点）
                        if (!early_halt and !tco_triggered) {
                            var k: u32 = tci + 1;
                            const total: u32 = @intCast(nodes.len);
                            while (k < total) : (k += 1) {
                                const node: *const Node = &nodes[k];
                                const result = self.execNode(node) catch |err| {
                                    return err;
                                };
                                if (self.tco_restart) {
                                    self.tco_restart = false;
                                    tco_iteration += 1;
                                    if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                    tco_triggered = true;
                                    break;
                                }
                                if (result) |ret_chan| {
                                    halt_chan = ret_chan;
                                    break;
                                }
                            }
                        }
                    } else {
                        // 无 TCO：单循环，无 TCO 检查
                        if (fbc.body_insts.len > 0) {
                            // BodyInst 路径：直接函数指针调用，跳过 execNode switch dispatch
                            // 非 TCO 函数也受益于直接调用（record/route/算术等 op 密集场景）
                            if (fbc.body_has_call) {
                                for (fbc.body_insts) |inst| {
                                    inst.exec(self, inst.node) catch |err| {
                                        return err;
                                    };
                                    if (self.pending_halt) |halt_c| {
                                        self.pending_halt = null;
                                        halt_chan = halt_c;
                                        break;
                                    }
                                    if (self.tco_restart) {
                                        self.tco_restart = false;
                                        tco_iteration += 1;
                                        if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                        tco_triggered = true;
                                        break;
                                    }
                                }
                            } else {
                                // body 无 call 节点：跳过 tco_restart 检查（hot path 优化）
                                for (fbc.body_insts) |inst| {
                                    inst.exec(self, inst.node) catch |err| {
                                        return err;
                                    };
                                    if (self.pending_halt) |halt_c| {
                                        self.pending_halt = null;
                                        halt_chan = halt_c;
                                        break;
                                    }
                                }
                            }
                        } else {
                            // execNode 回退路径：body 含 opToScalarExecFn 不支持的 op
                            var i: u32 = 0;
                            const total: u32 = @intCast(nodes.len);
                            while (i < total) : (i += 1) {
                                const node: *const Node = &nodes[i];
                                const result = self.execNode(node) catch |err| {
                                    return err;
                                };
                                if (self.tco_restart) {
                                    self.tco_restart = false;
                                    tco_iteration += 1;
                                    if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                    tco_triggered = true;
                                    break;
                                }
                                if (result) |ret_chan| {
                                    halt_chan = ret_chan;
                                    break;
                                }
                            }
                        }
                    }
                } else {
                    // Compact 路径：紧凑索引数组
                    const tco_ci = fbc.tco_node_idx;
                    var i: u32 = 0;
                    while (i < fbc.compact_idx.len) : (i += 1) {
                        const node: *const Node = &nodes[fbc.compact_idx[i]];

                        // TCO call 节点：仅在此位置检查，其余节点无 TCO 检查开销
                        if (tco_ci) |tci| {
                            if (i == tci) {
                                tco_iteration += 1;
                                if (tco_iteration > tco_max) return error.CallDepthExceeded;
                                // 使用预计算的参数信息（避免每次 elemWidth/rawPtr 查找）
                                const arg_count = fbc.tco_arg_count;
                                const dst_chans = &fbc.tco_arg_dst_chans;
                                const widths = &fbc.tco_arg_widths;
                                var j: u8 = 0;
                                while (j < arg_count) : (j += 1) {
                                    const arg_chan = node.inputs[j];
                                    const dst_chan = dst_chans[j];
                                    const w = widths[j];
                                    if (w > 0 and arg_chan != dst_chan) {
                                        const src = self.runtime.rawPtr(arg_chan);
                                        const dst = self.runtime.rawPtr(dst_chan);
                                        @memcpy(dst[0..w], src[0..w]);
                                    }
                                }
                                tco_triggered = true;
                                break;
                            }
                        }

                        const result = self.execNode(node) catch |err| {
                            return err;
                        };
                        if (self.tco_restart) {
                            self.tco_restart = false;
                            tco_iteration += 1;
                            if (tco_iteration > tco_max) return error.CallDepthExceeded;
                            tco_triggered = true;
                            break;
                        }
                        if (result) |ret_chan| {
                            halt_chan = ret_chan;
                            break;
                        }
                    }
                }
            } else {
                // 回退路径：原始节点遍历（body_skip 检查 + TCO 每节点检查）
                var pc: u32 = 0;
                while (pc < nodes.len) {
                    if (body_skip[pc]) {
                        pc += 1;
                        continue;
                    }
                    const node: *const Node = &nodes[pc];

                    if (tco_call_node_idx) |tci| {
                        if (pc == tci) {
                            tco_iteration += 1;
                            if (tco_iteration > tco_max) return error.CallDepthExceeded;
                            const call_meta = self.ir.call_metas[tco_call_meta_idx - 1];
                            const tco_args = node.inputs[0..call_meta.arg_count];
                            for (tco_args, 0..) |arg_chan, j| {
                                if (j < func.param_channels.len) {
                                    const dst_chan = func.param_channels[j];
                                    const w = self.runtime.elemWidth(arg_chan);
                                    if (w > 0) {
                                        if (arg_chan == dst_chan) continue;
                                        const src = self.runtime.rawPtr(arg_chan);
                                        const dst = self.runtime.rawPtr(dst_chan);
                                        @memcpy(dst[0..w], src[0..w]);
                                    }
                                }
                            }
                            tco_triggered = true;
                            break;
                        }
                    }

                    const result = self.execNode(node) catch |err| {
                        return err;
                    };
                    if (self.tco_restart) {
                        self.tco_restart = false;
                        tco_iteration += 1;
                        if (tco_iteration > tco_max) return error.CallDepthExceeded;
                        tco_triggered = true;
                        break;
                    }
                    if (result) |ret_chan| {
                        halt_chan = ret_chan;
                        break;
                    }
                    pc += 1;
                }
            }

            if (tco_triggered) {
                // 互递归 TCO：跳转到目标函数体重新执行（trampoline）
                if (self.tco_jump_to) |jf| {
                    self.tco_jump_to = null;
                    func_idx = jf;
                    continue :jump_loop;
                }
                // 自递归 TCO：重新执行当前函数体
                continue;
            }

            // halt 时执行本函数注册的 defer（LIFO 顺序）
            if (self.defer_top > entry_defer_top) {
                const defer_saved_func_idx = self.current_func_idx;
                while (self.defer_top > entry_defer_top) {
                    self.defer_top -= 1;
                    const frame = self.defer_stack[self.defer_top];
                    self.current_func_idx = frame.func_idx;
                    const defer_nodes = self.ir.funcNodes(frame.func_idx);
                    const local_start = frame.body_start - self.ir.functions[frame.func_idx].node_start;
                    _ = try self.execBodyNodes(defer_nodes, local_start, frame.body_len);
                }
                self.current_func_idx = defer_saved_func_idx;
            }

            // 如果 halt 返回了通道，返回它；否则返回函数的 return_channel
            // 非逃逸函数：reset ShadowArena（O(1) 回收函数内 arena 分配的对象）
            // 逃逸分析保证 arena 对象在函数返回前 RC=0（所有引用已 release），
            // arena.reset 安全回收内存，tracked_objs 不包含 arena 对象。
            if (func.no_escape) {
                self.tctx.?.endFunction();
            }
            return halt_chan orelse func.return_channel;
        } // end inner TCO loop
        } // end jump_loop
    }

    /// 执行单个节点，返回非 null 表示 halt_return 的返回通道
    // ════════════════════════════════════════════
    // OpHandler 分派表（v3 阶段 5：替代 145 分支 switch）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：OpHandler 分派表与包装函数从 dispatch_table.zig 混入
    pub const OpHandler = @import("dispatch_table.zig").OpHandler;
    pub const op_handler_table = @import("dispatch_table.zig").op_handler_table;

    // 通用包装器（comptime 泛型）
    pub const wrapVoid = @import("dispatch_table.zig").Methods.wrapVoid;
    pub const wrapPureVoid = @import("dispatch_table.zig").Methods.wrapPureVoid;
    pub const wrapSignal = @import("dispatch_table.zig").Methods.wrapSignal;
    pub const wrapIntBin = @import("dispatch_table.zig").Methods.wrapIntBin;
    pub const wrapIntShift = @import("dispatch_table.zig").Methods.wrapIntShift;
    pub const wrapIntUn = @import("dispatch_table.zig").Methods.wrapIntUn;
    pub const wrapFloatBin = @import("dispatch_table.zig").Methods.wrapFloatBin;
    pub const wrapFloatUn = @import("dispatch_table.zig").Methods.wrapFloatUn;
    pub const wrapCmp = @import("dispatch_table.zig").Methods.wrapCmp;
    pub const wrapBoolBin = @import("dispatch_table.zig").Methods.wrapBoolBin;
    pub const wrapCast = @import("dispatch_table.zig").Methods.wrapCast;

    // halt 处理器
    pub const handleHaltReturn = @import("dispatch_table.zig").Methods.handleHaltReturn;
    pub const handleHaltThrow = @import("dispatch_table.zig").Methods.handleHaltThrow;
    pub const handleHaltPanic = @import("dispatch_table.zig").Methods.handleHaltPanic;
    pub const handleHaltBreak = @import("dispatch_table.zig").Methods.handleHaltBreak;
    pub const handleHaltContinue = @import("dispatch_table.zig").Methods.handleHaltContinue;
    pub const handleUnsupported = @import("dispatch_table.zig").Methods.handleUnsupported;

    /// 执行单个 IR 节点。
    /// v3 阶段 5：145 分支 switch → 单行查表分派。
    /// 新增 IR op = 在 op_handler_table 追加一条 t.set，不改 execNode。
    pub fn execNode(self: *Engine, node: *const Node) EngineError!?u16 {
        return op_handler_table.get(node.op)(self, node);
    }

    // ════════════════════════════════════════════
    // 通道元信息 → ScalarTag 映射（comptime 注册表，替代运行时 switch）
    // ════════════════════════════════════════════

    /// 从通道元信息推导 ScalarTag（用于选择 ops 函数）
    /// 通过 type_desc.type_name 查表，零运行时 switch
    pub fn chanToScalarTag(chan_meta: ChannelMeta) ?ScalarTag {
        const td = chan_meta.type_desc;
        const n = td.type_name;
        if (std.mem.eql(u8, n, "bool")) return .boolean;
        if (std.mem.eql(u8, n, "char")) return .char;
        if (td.toIntKind()) |ik| {
            return switch (ik) {
                .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
                .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
                .isize => .isize, .usize => .usize,
            };
        }
        if (td.toFloatKind()) |fk| {
            return switch (fk) {
                .f16 => .f16, .f32 => .f32, .f64 => .f64, .f128 => .f128,
            };
        }
        return null;
    }

    /// 预计算所有节点的 scalar_tag 字段（IR 不可变，layout 后只算一次）
    /// 消除热路径中 chanToScalarTag(channels.get(...)) 的 array access + switch 开销
    /// 直接读取 node.scalar_tag，单次内存访问
    fn precomputeNodeTags(self: *Engine) void {
        const nodes = self.ir.nodes;
        const channels = &self.ir.channels;
        const scalar_metas = self.ir.scalar_metas;
        for (nodes) |*node| {
            const tag: ?ScalarTag = switch (node.op) {
                // 整数算术：tag = 输出通道类型（输入输出同类型）
                .int_add, .int_sub, .int_mul, .int_div, .int_mod,
                .int_and, .int_or, .int_xor, .int_shl, .int_shr,
                .int_neg, .int_abs, .int_not,
                // 浮点算术：tag = 输出通道类型
                .float_add, .float_sub, .float_mul, .float_div, .float_mod,
                .float_neg, .float_abs,
                // const 节点：tag = 输出通道类型（用于 readScalarAt 快速路径）
                .const_i, .const_f, .const_bool, .const_char,
                // load/store：tag = 输出通道类型
                .load, .store,
                => chanToScalarTag(channels.get(node.output)),

                // 比较：tag 从左右输入通道类型推导
                // 当两侧类型不同时（如 i64 字面量 vs i32 cast 结果），
                // 选择非 i64 的类型（i64 是字面量默认类型，sema 已将其提升为另一侧类型）
                .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge,
                => blk: {
                    const left_tag = chanToScalarTag(channels.get(node.inputs[0]));
                    const right_tag = chanToScalarTag(channels.get(node.inputs[1]));
                    if (left_tag != null and right_tag != null and left_tag.? == right_tag.?) {
                        break :blk left_tag;
                    }
                    // i64 是字面量默认类型：选择另一侧的具体类型
                    if (left_tag == .i64 and right_tag != null and right_tag.? != .i64) {
                        break :blk right_tag;
                    }
                    if (right_tag == .i64 and left_tag != null and left_tag.? != .i64) {
                        break :blk left_tag;
                    }
                    // 其他不一致情况：回退到左操作数类型
                    break :blk left_tag;
                },

                // record_get：tag = 输出通道类型（字段值类型，用于直接指针读写）
                // 同时预计算 field_id 到 _pad（避免每次解析 meta）
                .record_get => blk: {
                    node._pad = extractRecordFieldId(node, scalar_metas);
                    break :blk chanToScalarTag(channels.get(node.output));
                },

                // record_set/record_clone：预计算 field_id/extra_count 到 _pad
                // record_set 还预计算 inputs[1]（值通道）的 ScalarTag，用于直接指针读取
                .record_set => blk: {
                    node._pad = extractRecordFieldId(node, scalar_metas);
                    break :blk chanToScalarTag(channels.get(node.inputs[1]));
                },
                .record_clone => blk: {
                    node._pad = extractRecordFieldId(node, scalar_metas);
                    break :blk null;
                },

                // 其他节点：不预计算（0xFF）
                else => null,
            };
            node.scalar_tag = if (tag) |t| @intFromEnum(t) else 0xFF;
        }
    }

    /// 从 record_get/set/clone 节点的 meta 中提取 field_id（或 extra_count）
    /// 返回 u8（field_id 实际很少超过 256，超出时返回 0xFF 触发运行时回退）
    inline fn extractRecordFieldId(node: *const Node, scalar_metas: []const ScalarMeta) u8 {
        if (node.meta_index == 0 or node.meta_index >= scalar_metas.len) return 0xFF;
        const meta = scalar_metas[node.meta_index];
        const cv = meta.const_val orelse return 0xFF;
        switch (cv) {
            .int_val => |iv| {
                const fid: u32 = @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv)))));
                if (fid > 0xFF) return 0xFF;
                return @intCast(fid);
            },
            else => return 0xFF,
        }
    }

    /// 读取通道值为 16 字节填充缓冲区（ops 函数的输入格式）
    pub fn readChanBytes(self: *Engine, chan: u16) [16]u8 {
        var buf: [16]u8 = [_]u8{0} ** 16;
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(buf[0..w], self.runtime.rawPtr(chan)[0..w]);
        }
        return buf;
    }

    /// 写入 16 字节缓冲区的前 N 字节到通道
    pub fn writeChanBytes(self: *Engine, chan: u16, buf: [16]u8) void {
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(self.runtime.rawPtr(chan)[0..w], buf[0..w]);
        }
    }

    // ════════════════════════════════════════════
    // 标量分派函数（comptime 泛型 + 批量运算）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：标量分派函数从 scalar_exec.zig 混入
    pub const dispatchIntBinOp = @import("scalar_exec.zig").Methods.dispatchIntBinOp;
    pub const dispatchFloatBinOp = @import("scalar_exec.zig").Methods.dispatchFloatBinOp;
    pub const dispatchIntUnOp = @import("scalar_exec.zig").Methods.dispatchIntUnOp;
    pub const dispatchFloatUnOp = @import("scalar_exec.zig").Methods.dispatchFloatUnOp;
    pub const dispatchCmp = @import("scalar_exec.zig").Methods.dispatchCmp;
    pub const dispatchInlineBinOp = @import("scalar_exec.zig").Methods.dispatchInlineBinOp;
    pub const nodeOpToBatchBinOp = @import("scalar_exec.zig").Methods.nodeOpToBatchBinOp;
    pub const dispatchBatchReduce = @import("scalar_exec.zig").Methods.dispatchBatchReduce;
    pub const dispatchBatchScan = @import("scalar_exec.zig").Methods.dispatchBatchScan;
    pub const nodeOpToBatchUnaryOp = @import("scalar_exec.zig").Methods.nodeOpToBatchUnaryOp;
    pub const dispatchBatchMapUnary = @import("scalar_exec.zig").Methods.dispatchBatchMapUnary;
    pub const dispatchBatchMapScalarR = @import("scalar_exec.zig").Methods.dispatchBatchMapScalarR;
    pub const dispatchBatchMapScalarL = @import("scalar_exec.zig").Methods.dispatchBatchMapScalarL;
    pub const dispatchBatchMap2 = @import("scalar_exec.zig").Methods.dispatchBatchMap2;

    // ════════════════════════════════════════════
    // 常量执行
    // ════════════════════════════════════════════

    pub const execConst = @import("scalar_exec.zig").Methods.execConst;
    pub const execConstUnit = @import("scalar_exec.zig").Methods.execConstUnit;
    pub const execConstNull = @import("scalar_exec.zig").Methods.execConstNull;

    // v3 阶段 5.3：非反射 builtin 执行函数从 builtin_exec.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    pub const execBuiltinOk = @import("builtin_exec.zig").Methods.execBuiltinOk;
    pub const execBuiltinError = @import("builtin_exec.zig").Methods.execBuiltinError;
    pub const execBuiltinEq = @import("builtin_exec.zig").Methods.execBuiltinEq;
    pub const execBuiltinRefEq = @import("builtin_exec.zig").Methods.execBuiltinRefEq;
    pub const execBuiltinStr = @import("builtin_exec.zig").Methods.execBuiltinStr;

    pub const execBuiltinType = @import("builtin_exec.zig").Methods.execBuiltinType;
    pub const execBuiltinTypeof = @import("builtin_exec.zig").Methods.execBuiltinTypeof;

    // ════════════════════════════════════════════
    // 反射内置函数（reflect / reflect_field / scalar_to_str / reflect_deref / reflect_field_name）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：反射 builtin 执行函数从 reflect_exec.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    pub const execBuiltinReflect = @import("reflect_exec.zig").Methods.execBuiltinReflect;
    pub const reflectFieldCount = @import("reflect_exec.zig").Methods.reflectFieldCount;
    pub const execBuiltinReflectField = @import("reflect_exec.zig").Methods.execBuiltinReflectField;
    pub const writeFieldResult = @import("reflect_exec.zig").Methods.writeFieldResult;
    pub const reflectFieldByValue = @import("reflect_exec.zig").Methods.reflectFieldByValue;
    pub const inferKindFromValue = @import("reflect_exec.zig").Methods.inferKindFromValue;
    pub const execBuiltinScalarToStr = @import("reflect_exec.zig").Methods.execBuiltinScalarToStr;
    pub const execBuiltinReflectDeref = @import("reflect_exec.zig").Methods.execBuiltinReflectDeref;
    pub const execBuiltinReflectFieldName = @import("reflect_exec.zig").Methods.execBuiltinReflectFieldName;
    pub const emitEmptyStr = @import("reflect_exec.zig").Methods.emitEmptyStr;
    pub const reflectFieldName = @import("reflect_exec.zig").Methods.reflectFieldName;
    pub const execBuiltinReflectMeta = @import("reflect_exec.zig").Methods.execBuiltinReflectMeta;

    pub const execSyscall = @import("builtin_exec.zig").Methods.execSyscall;

    // v3 阶段 5.3：TypeInfo RecordValue 构造器从 typeinfo_build.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    pub const makeTypeInfoFromMeta = @import("typeinfo_build.zig").Methods.makeTypeInfoFromMeta;
    pub const makeNullableTypeInfoValue = @import("typeinfo_build.zig").Methods.makeNullableTypeInfoValue;
    pub const emitNullableTypeInfo = @import("typeinfo_build.zig").Methods.emitNullableTypeInfo;
    pub const makePlaceholderTypeInfoValue = @import("typeinfo_build.zig").Methods.makePlaceholderTypeInfoValue;
    pub const activeTypeArgs = @import("typeinfo_build.zig").Methods.activeTypeArgs;
    pub const parentTypeArgs = @import("typeinfo_build.zig").Methods.parentTypeArgs;
    pub const materializeTypeArgs = @import("typeinfo_build.zig").Methods.materializeTypeArgs;
    pub const emitPlaceholderTypeInfo = @import("typeinfo_build.zig").Methods.emitPlaceholderTypeInfo;
    pub const emitTypeInfoRecord = @import("typeinfo_build.zig").Methods.emitTypeInfoRecord;
    pub const makeLayoutInfoRecord = @import("typeinfo_build.zig").Methods.makeLayoutInfoRecord;
    pub const makeEmptyTraitImplInfoRecord = @import("typeinfo_build.zig").Methods.makeEmptyTraitImplInfoRecord;
    pub const makeTraitImplInfoRecord = @import("typeinfo_build.zig").Methods.makeTraitImplInfoRecord;
    pub const makeStructureRecord = @import("typeinfo_build.zig").Methods.makeStructureRecord;
    pub const makeTypeInfoFromId = @import("typeinfo_build.zig").Methods.makeTypeInfoFromId;
    pub const makeFieldMetaRecord = @import("typeinfo_build.zig").Methods.makeFieldMetaRecord;
    pub const makeFieldMetaArray = @import("typeinfo_build.zig").Methods.makeFieldMetaArray;
    pub const makeConstructorMetaRecord = @import("typeinfo_build.zig").Methods.makeConstructorMetaRecord;
    pub const makeConstructorMetaArray = @import("typeinfo_build.zig").Methods.makeConstructorMetaArray;
    pub const makeTypeParamMetaRecord = @import("typeinfo_build.zig").Methods.makeTypeParamMetaRecord;
    pub const makeTypeParamMetaArray = @import("typeinfo_build.zig").Methods.makeTypeParamMetaArray;
    pub const makeFuncSigRecord = @import("typeinfo_build.zig").Methods.makeFuncSigRecord;
    pub const makeTraitMetaRecord = @import("typeinfo_build.zig").Methods.makeTraitMetaRecord;
    pub const makeTraitMetaArray = @import("typeinfo_build.zig").Methods.makeTraitMetaArray;
    pub const makeMethodMetaRecord = @import("typeinfo_build.zig").Methods.makeMethodMetaRecord;
    pub const makeMethodMetaArray = @import("typeinfo_build.zig").Methods.makeMethodMetaArray;
    pub const makeAssociatedTypeMetaRecord = @import("typeinfo_build.zig").Methods.makeAssociatedTypeMetaRecord;
    pub const makeAssociatedTypeMetaArray = @import("typeinfo_build.zig").Methods.makeAssociatedTypeMetaArray;
    pub const makeStrArray = @import("typeinfo_build.zig").Methods.makeStrArray;

    // ════════════════════════════════════════════
    // Newtype 操作
    // ════════════════════════════════════════════

    // v3 阶段 5.3：内存/引用执行函数从 mem_ref_exec.zig 混入
    pub const execNewtypeWrap = @import("mem_ref_exec.zig").Methods.execNewtypeWrap;

    pub const execNewtypeUnwrap = @import("mem_ref_exec.zig").Methods.execNewtypeUnwrap;

    pub const execConstStr = @import("scalar_exec.zig").Methods.execConstStr;

    // ════════════════════════════════════════════
    // 整数/浮点/比较/布尔算术（枚举 + exec 函数）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：标量算术枚举与 exec 函数从 scalar_exec.zig 混入
    pub const IntBinOpKind = @import("scalar_exec.zig").IntBinOpKind;
    pub const IntShiftKind = @import("scalar_exec.zig").IntShiftKind;
    pub const IntUnOpKind = @import("scalar_exec.zig").IntUnOpKind;
    pub const FloatBinOpKind = @import("scalar_exec.zig").FloatBinOpKind;
    pub const FloatUnOpKind = @import("scalar_exec.zig").FloatUnOpKind;
    pub const CmpKind = @import("scalar_exec.zig").CmpKind;
    pub const BoolBinOpKind = @import("scalar_exec.zig").BoolBinOpKind;

    pub const execIntBinOp = @import("scalar_exec.zig").Methods.execIntBinOp;
    pub const execIntShift = @import("scalar_exec.zig").Methods.execIntShift;
    pub const execIntUnOp = @import("scalar_exec.zig").Methods.execIntUnOp;
    pub const execFloatBinOp = @import("scalar_exec.zig").Methods.execFloatBinOp;
    pub const execFloatUnOp = @import("scalar_exec.zig").Methods.execFloatUnOp;
    pub const execCmp = @import("scalar_exec.zig").Methods.execCmp;
    pub const execBoolBinOp = @import("scalar_exec.zig").Methods.execBoolBinOp;
    pub const execBoolNot = @import("scalar_exec.zig").Methods.execBoolNot;

    // ════════════════════════════════════════════
    // 内存操作（var 变量 load/store）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：内存/引用执行函数从 mem_ref_exec.zig 混入
    pub const execLoad = @import("mem_ref_exec.zig").Methods.execLoad;

    pub const execStore = @import("mem_ref_exec.zig").Methods.execStore;

    // ════════════════════════════════════════════
    // 借用引用（&T / *expr / ref_get / ref_set）
    // ════════════════════════════════════════════

    pub const execRefOf = @import("mem_ref_exec.zig").Methods.execRefOf;

    pub const execRefGet = @import("mem_ref_exec.zig").Methods.execRefGet;

    pub const execRefSet = @import("mem_ref_exec.zig").Methods.execRefSet;

    // ════════════════════════════════════════════
    // 选择（if 表达式，标量模式 N=1）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：向量执行函数从 vector_exec.zig 混入
    pub const execVecSelect = @import("vector_exec.zig").Methods.execVecSelect;

    // ════════════════════════════════════════════
    // 类型转换（复用 value.cast）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：cast 执行函数从 cast_exec.zig 混入
    pub const execCast = @import("cast_exec.zig").Methods.execCast;
    pub const scalarBytesToValue = @import("cast_exec.zig").Methods.scalarBytesToValue;
    pub const execCastTo = @import("cast_exec.zig").Methods.execCastTo;
    pub const execCastTryTo = @import("cast_exec.zig").Methods.execCastTryTo;
    pub const execCastTryToStrNumeric = @import("cast_exec.zig").Methods.execCastTryToStrNumeric;
    pub const constructCastErrorThrow = @import("cast_exec.zig").Methods.constructCastErrorThrow;
    pub const constructCastErrorThrowStr = @import("cast_exec.zig").Methods.constructCastErrorThrowStr;
    pub const emitCastErrorThrow = @import("cast_exec.zig").Methods.emitCastErrorThrow;
    pub const scalarKindToTag = @import("cast_exec.zig").Methods.scalarKindToTag;
    pub const isInfResult = @import("cast_exec.zig").Methods.isInfResult;

    // ════════════════════════════════════════════
    // 字符串操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 Str 对象指针
    // v3 阶段 5.3：值/通道转换函数从 value_conv.zig 混入
    pub const readStr = @import("value_conv.zig").Methods.readStr;

    // v3 阶段 5.3：容器（字符串/数组/记录）执行函数从 container_exec.zig 混入
    pub const execStringLen = @import("container_exec.zig").Methods.execStringLen;
    pub const execStringConcat = @import("container_exec.zig").Methods.execStringConcat;
    pub const execStringCmp = @import("container_exec.zig").Methods.execStringCmp;
    pub const execStringIndex = @import("container_exec.zig").Methods.execStringIndex;
    pub const utf8SeqLen = @import("container_exec.zig").Methods.utf8SeqLen;
    pub const decodeUtf8Codepoint = @import("container_exec.zig").Methods.decodeUtf8Codepoint;

    // ════════════════════════════════════════════
    // 数组操作
    // ════════════════════════════════════════════

    // ════════════════════════════════════════════
    // 值/通道转换函数（v3 阶段 5.3：从 value_conv.zig 混入）
    // ════════════════════════════════════════════

    pub const readArray = @import("value_conv.zig").Methods.readArray;
    pub const chanToValue = @import("value_conv.zig").Methods.chanToValue;
    pub const valueToChan = @import("value_conv.zig").Methods.valueToChan;
    pub const cloneValueBetweenChannels = @import("value_conv.zig").Methods.cloneValueBetweenChannels;
    pub const copyCrossType = @import("value_conv.zig").Methods.copyCrossType;
    pub const cloneValueForContainer = @import("value_conv.zig").Methods.cloneValueForContainer;
    pub const trackValueTree = @import("value_conv.zig").Methods.trackValueTree;

    // v3 阶段 5.3：内存/引用执行函数从 mem_ref_exec.zig 混入
    pub const valueToRawPtr = @import("mem_ref_exec.zig").Methods.valueToRawPtr;

    // v3 阶段 5.3：容器（数组）执行函数从 container_exec.zig 混入
    pub const execArrayMake = @import("container_exec.zig").Methods.execArrayMake;
    pub const execArrayGet = @import("container_exec.zig").Methods.execArrayGet;
    pub const execArraySet = @import("container_exec.zig").Methods.execArraySet;
    pub const execArrayLen = @import("container_exec.zig").Methods.execArrayLen;
    pub const execArrayPush = @import("container_exec.zig").Methods.execArrayPush;
    pub const execArrayConcat = @import("container_exec.zig").Methods.execArrayConcat;
    pub const execArrayFill = @import("container_exec.zig").Methods.execArrayFill;
    pub const execArraySlice = @import("container_exec.zig").Methods.execArraySlice;
    pub const execArrayFirst = @import("container_exec.zig").Methods.execArrayFirst;
    pub const execArrayLast = @import("container_exec.zig").Methods.execArrayLast;
    pub const execArrayContains = @import("container_exec.zig").Methods.execArrayContains;
    pub const execArrayGetSafe = @import("container_exec.zig").Methods.execArrayGetSafe;
    pub const execArrayDropLast = @import("container_exec.zig").Methods.execArrayDropLast;
    pub const execArrayPop = @import("container_exec.zig").Methods.execArrayPop;
    pub const execStringContains = @import("container_exec.zig").Methods.execStringContains;
    pub const execStringSlice = @import("container_exec.zig").Methods.execStringSlice;
    pub const execStringBytes = @import("container_exec.zig").Methods.execStringBytes;
    pub const execArrayToStr = @import("container_exec.zig").Methods.execArrayToStr;

    // ════════════════════════════════════════════
    // 记录操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 RecordValue 指针
    /// 内联以让编译器消除连续 record_get/set 的冗余 null/对齐/type_tag 检查
    pub inline fn readRecord(self: *Engine, chan: u16) ?*value.RecordValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .record and header.type_tag != .adt and header.type_tag != .newtype) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 从 ScalarMeta 读取字符串池中的字符串（字段名/类型名）
    fn metaString(self: *Engine, meta_index: u16) ?[]const u8 {
        if (meta_index == 0 or meta_index >= self.ir.scalar_metas.len) return null;
        const meta = self.ir.scalar_metas[meta_index];
        if (meta.const_val) |cv| {
            if (cv == .int_val) {
                const idx: usize = @intCast(cv.int_val);
                if (idx < self.ir.string_pool.len) return self.ir.string_pool[idx];
            }
        }
        return null;
    }

    // v3 阶段 5.3：容器（记录）执行函数从 container_exec.zig 混入
    pub const execRecordMake = @import("container_exec.zig").Methods.execRecordMake;
    pub const execRecordGet = @import("container_exec.zig").Methods.execRecordGet;
    pub const execRecordSet = @import("container_exec.zig").Methods.execRecordSet;
    pub const execRecordClone = @import("container_exec.zig").Methods.execRecordClone;

    // ════════════════════════════════════════════
    // 函数调用
    // ════════════════════════════════════════════

    // v3 阶段 5.3：函数调用执行函数从 call_exec.zig 混入
    pub const execCall = @import("call_exec.zig").Methods.execCall;
    pub const copyArgToParam = @import("call_exec.zig").Methods.copyArgToParam;
    pub const copyArgsToParams = @import("call_exec.zig").Methods.copyArgsToParams;
    pub const copyClosureUpvalues = @import("call_exec.zig").Methods.copyClosureUpvalues;
    pub const saveCallResult = @import("call_exec.zig").Methods.saveCallResult;
    pub const writeCallResult = @import("call_exec.zig").Methods.writeCallResult;
    pub const execCallStandard = @import("call_exec.zig").Methods.execCallStandard;
    pub const hashArgs = @import("call_exec.zig").Methods.hashArgs;

    // ════════════════════════════════════════════
    // 向量操作（Phase 3）
    // ════════════════════════════════════════════

    // v3 阶段 5.3：函数体/循环执行函数从 body_exec.zig 混入
    pub const execBodyNodes = @import("body_exec.zig").Methods.execBodyNodes;
    pub const markNestedRange = @import("body_exec.zig").Methods.markNestedRange;
    pub const execBodyNodesCompact = @import("body_exec.zig").Methods.execBodyNodesCompact;
    pub const compileActiveNodes = @import("body_exec.zig").Methods.compileActiveNodes;
    pub const execCompiledCompact = @import("body_exec.zig").Methods.execCompiledCompact;
    pub const compileFuncBody = @import("body_exec.zig").Methods.compileFuncBody;
    pub const analyzeLoopInvariants = @import("body_exec.zig").Methods.analyzeLoopInvariants;
    pub const execScalarLoop = @import("body_exec.zig").Methods.execScalarLoop;
    pub const getOrCompileBody = @import("body_exec.zig").Methods.getOrCompileBody;
    pub const execCompiledBody = @import("body_exec.zig").Methods.execCompiledBody;

    /// vec_source：生成向量数据
    /// inputs[0]=start, inputs[1]=end (range) 或 inputs[0]=array_ref (array_source)
    pub const execVecSource = @import("vector_exec.zig").Methods.execVecSource;

    // ════════════════════════════════════════════
    // O(1) dispatch：Body 编译器实现
    // ════════════════════════════════════════════

    /// 标量 op 的零 dispatch 包装函数
    /// 每个函数直接调用对应的 exec* 方法，绕过 execNode 的 switch
    /// 用于 CompiledBody.insts 数组，实现 body 内节点的直接调用
    // v3 阶段 5.3：标量包装函数从 dispatch_table.zig 混入
    pub const wrapConstI = @import("dispatch_table.zig").Methods.wrapConstI;
    pub const wrapConstF = @import("dispatch_table.zig").Methods.wrapConstF;
    pub const wrapConstBool = @import("dispatch_table.zig").Methods.wrapConstBool;
    pub const wrapConstChar = @import("dispatch_table.zig").Methods.wrapConstChar;
    pub const wrapConstStr = @import("dispatch_table.zig").Methods.wrapConstStr;
    pub const wrapIntAdd = @import("dispatch_table.zig").Methods.wrapIntAdd;
    pub const wrapIntSub = @import("dispatch_table.zig").Methods.wrapIntSub;
    pub const wrapIntMul = @import("dispatch_table.zig").Methods.wrapIntMul;
    pub const wrapIntDiv = @import("dispatch_table.zig").Methods.wrapIntDiv;
    pub const wrapIntMod = @import("dispatch_table.zig").Methods.wrapIntMod;
    pub const wrapIntAnd = @import("dispatch_table.zig").Methods.wrapIntAnd;
    pub const wrapIntOr = @import("dispatch_table.zig").Methods.wrapIntOr;
    pub const wrapIntXor = @import("dispatch_table.zig").Methods.wrapIntXor;
    pub const wrapIntShl = @import("dispatch_table.zig").Methods.wrapIntShl;
    pub const wrapIntShr = @import("dispatch_table.zig").Methods.wrapIntShr;
    pub const wrapIntNeg = @import("dispatch_table.zig").Methods.wrapIntNeg;
    pub const wrapIntAbs = @import("dispatch_table.zig").Methods.wrapIntAbs;
    pub const wrapIntNot = @import("dispatch_table.zig").Methods.wrapIntNot;
    pub const wrapFloatAdd = @import("dispatch_table.zig").Methods.wrapFloatAdd;
    pub const wrapFloatSub = @import("dispatch_table.zig").Methods.wrapFloatSub;
    pub const wrapFloatMul = @import("dispatch_table.zig").Methods.wrapFloatMul;
    pub const wrapFloatDiv = @import("dispatch_table.zig").Methods.wrapFloatDiv;
    pub const wrapFloatMod = @import("dispatch_table.zig").Methods.wrapFloatMod;
    pub const wrapFloatNeg = @import("dispatch_table.zig").Methods.wrapFloatNeg;
    pub const wrapFloatAbs = @import("dispatch_table.zig").Methods.wrapFloatAbs;
    pub const wrapCmpEq = @import("dispatch_table.zig").Methods.wrapCmpEq;
    pub const wrapCmpNe = @import("dispatch_table.zig").Methods.wrapCmpNe;
    pub const wrapCmpLt = @import("dispatch_table.zig").Methods.wrapCmpLt;
    pub const wrapCmpLe = @import("dispatch_table.zig").Methods.wrapCmpLe;
    pub const wrapCmpGt = @import("dispatch_table.zig").Methods.wrapCmpGt;
    pub const wrapCmpGe = @import("dispatch_table.zig").Methods.wrapCmpGe;
    pub const wrapBoolAnd = @import("dispatch_table.zig").Methods.wrapBoolAnd;
    pub const wrapBoolOr = @import("dispatch_table.zig").Methods.wrapBoolOr;
    pub const wrapBoolNot = @import("dispatch_table.zig").Methods.wrapBoolNot;
    pub const wrapCastDirect = @import("dispatch_table.zig").Methods.wrapCastDirect;
    pub const wrapCastSafeDirect = @import("dispatch_table.zig").Methods.wrapCastSafeDirect;
    pub const wrapLoad = @import("dispatch_table.zig").Methods.wrapLoad;
    pub const wrapStore = @import("dispatch_table.zig").Methods.wrapStore;
    pub const wrapRefOf = @import("dispatch_table.zig").Methods.wrapRefOf;
    pub const wrapRefGet = @import("dispatch_table.zig").Methods.wrapRefGet;
    pub const wrapRefSet = @import("dispatch_table.zig").Methods.wrapRefSet;
    pub const wrapHaltBreak = @import("dispatch_table.zig").Methods.wrapHaltBreak;
    pub const wrapHaltContinue = @import("dispatch_table.zig").Methods.wrapHaltContinue;
    pub const wrapHaltReturn = @import("dispatch_table.zig").Methods.wrapHaltReturn;
    pub const wrapCall = @import("dispatch_table.zig").Methods.wrapCall;
    pub const wrapVecSelect = @import("dispatch_table.zig").Methods.wrapVecSelect;
    pub const wrapHaltThrow = @import("dispatch_table.zig").Methods.wrapHaltThrow;
    pub const wrapRecordMake = @import("dispatch_table.zig").Methods.wrapRecordMake;
    pub const wrapRecordGet = @import("dispatch_table.zig").Methods.wrapRecordGet;
    pub const wrapRecordSet = @import("dispatch_table.zig").Methods.wrapRecordSet;
    pub const wrapRecordClone = @import("dispatch_table.zig").Methods.wrapRecordClone;
    pub const wrapRouteGetTag = @import("dispatch_table.zig").Methods.wrapRouteGetTag;
    pub const wrapRouteDispatch = @import("dispatch_table.zig").Methods.wrapRouteDispatch;
    pub const wrapRouteMerge = @import("dispatch_table.zig").Methods.wrapRouteMerge;

    // v3 阶段 5.3：直接调用映射函数从 scalar_exec.zig 混入
    pub const opToScalarExecFn = @import("scalar_exec.zig").Methods.opToScalarExecFn;

    // v3 阶段 5.3：body 编译函数从 body_exec.zig 混入
    pub const compileBody = @import("body_exec.zig").Methods.compileBody;

    /// 获取 backing allocator
    pub fn backingAllocator(self: *Engine) std.mem.Allocator {
        return self.tctx.?.backing;
    }

    // v3 阶段 5.3：向量执行函数从 vector_exec.zig 混入
    pub const execVecMap = @import("vector_exec.zig").Methods.execVecMap;
    pub const execVecMapStateMachine = @import("vector_exec.zig").Methods.execVecMapStateMachine;
    pub const execVecMapScalarChain = @import("vector_exec.zig").Methods.execVecMapScalarChain;

    // v3 阶段 5.3：标量 broadcast 从 vector_exec.zig 混入
    pub const broadcastScalarToVector = @import("vector_exec.zig").Methods.broadcastScalarToVector;

    // v3 阶段 5.3：向量执行函数从 vector_exec.zig 混入
    pub const execVecMapFallback = @import("vector_exec.zig").Methods.execVecMapFallback;
    pub const execVecMap2 = @import("vector_exec.zig").Methods.execVecMap2;
    pub const execVecMap2ScalarChain = @import("vector_exec.zig").Methods.execVecMap2ScalarChain;
    pub const execVecMap2StateMachine = @import("vector_exec.zig").Methods.execVecMap2StateMachine;
    pub const execVecSink = @import("vector_exec.zig").Methods.execVecSink;
    pub const execVecFold = @import("vector_exec.zig").Methods.execVecFold;
    pub const execVecFoldStateMachine = @import("vector_exec.zig").Methods.execVecFoldStateMachine;

    // v3 阶段 5.3：向量执行函数从 vector_exec.zig 混入
    pub const execVecScan = @import("vector_exec.zig").Methods.execVecScan;
    pub const execVecScanStateMachine = @import("vector_exec.zig").Methods.execVecScanStateMachine;
    pub const execVecFilter = @import("vector_exec.zig").Methods.execVecFilter;
    pub const execVecTake = @import("vector_exec.zig").Methods.execVecTake;
    pub const execVecTakeWhile = @import("vector_exec.zig").Methods.execVecTakeWhile;
    pub const execVecZip = @import("vector_exec.zig").Methods.execVecZip;

    /// 获取当前正在执行的函数索引
    pub const currentFuncIdx = @import("value_conv.zig").Methods.currentFuncIdx;

    /// 恢复被 pinToElement 修改的向量通道指针
    pub const restoreVectorChan = @import("value_conv.zig").Methods.restoreVectorChan;

    // ════════════════════════════════════════════
    // 门控执行（Phase 4：错误处理）
    // ════════════════════════════════════════════

    /// 读取 ref_chan 中的堆对象，返回 *ObjHeader 或 null
    ///
    /// 通过 ObjHeader 字段语义验证指针合法性（架构无关）：
    /// - null/低地址过滤：addr < 0x1000 不是合法堆对象（null 指针、小整数）
    /// - 对齐检查：堆对象必须按 ObjHeader 对齐
    /// - isValidHeapObj：type_tag 范围 + rc>=1 + flags 未用位为 0
    ///
    /// 标量值通过 ref_chan 传输时位模式可能被误判为指针，
    /// ObjHeader 字段语义验证可可靠过滤这类伪指针，不依赖架构相关地址范围假设。
    // v3 阶段 5.3：值/通道转换函数从 value_conv.zig 混入
    pub const readRefObj = @import("value_conv.zig").Methods.readRefObj;

    /// 读取 ThrowValue 指针（ref_chan → *ThrowValue）
    pub const readThrow = @import("value_conv.zig").Methods.readThrow;

    /// 按通道实际类型读取整数值并符号扩展为 i64。
    /// 这是通用观察点：如果通道中是 LazyValue，会先强制求值，再转为 i64。
    /// 用于索引、长度、select 超时等所有需要把值当作整数观察的场景。
    pub const readIntAsI64 = @import("value_conv.zig").Methods.readIntAsI64;

    /// 读取 ErrorValue 指针（ref_chan → *ErrorValue）
    pub const readError = @import("value_conv.zig").Methods.readError;

    // v3 阶段 5.3：gate/route/race/nullable/alloc/free 执行函数从 control_exec.zig 混入
    pub const execGateCheck = @import("control_exec.zig").Methods.execGateCheck;

    pub const execGateGetOk = @import("control_exec.zig").Methods.execGateGetOk;

    pub const execGateGetErr = @import("control_exec.zig").Methods.execGateGetErr;

    pub const execGatePropagate = @import("control_exec.zig").Methods.execGatePropagate;

    pub const execGateSelect = @import("control_exec.zig").Methods.execGateSelect;

    pub const execGateMakeOk = @import("control_exec.zig").Methods.execGateMakeOk;

    pub const execGateMakeErr = @import("control_exec.zig").Methods.execGateMakeErr;

    /// 从通道读取标量值（用于 gate 操作、print、return 等观察点）
    /// ref_chan 中若是 LazyValue，会自动强制求值一次并返回其结果（缓存借用）。
    /// 通用实现：ref_chan/bool/char 走快路径，其余所有标量类型复用 chanToValue，
    /// 确保完整覆盖 i8..i128/u8..u128/isize/usize/f16..f128 全部类型变体。
    // v3 阶段 5.3：值/通道转换函数从 value_conv.zig 混入
    pub const readScalarValue = @import("value_conv.zig").Methods.readScalarValue;

    /// 将标量值写入通道
    /// 将标量值写入通道（按通道类型写入，自动进行类型转换）
    /// 这样 i32 值写入 i64_chan 时会正确符号扩展，避免只写 4 字节导致垃圾值
    pub const writeScalarValue = @import("value_conv.zig").Methods.writeScalarValue;

    // v3 阶段 5.3：惰性求值执行函数从 functional_exec.zig 混入
    pub const execLazyMake = @import("functional_exec.zig").Methods.execLazyMake;
    pub const execLazyForce = @import("functional_exec.zig").Methods.execLazyForce;
    pub const readLazyValue = @import("functional_exec.zig").Methods.readLazyValue;
    pub const forceLazyValue = @import("functional_exec.zig").Methods.forceLazyValue;

    pub const execCleanupRegister = @import("control_exec.zig").Methods.execCleanupRegister;

    pub const execRaceSource = @import("control_exec.zig").Methods.execRaceSource;

    pub const selectSourceReady = @import("control_exec.zig").Methods.selectSourceReady;

    pub const execRaceSelect = @import("control_exec.zig").Methods.execRaceSelect;

    pub const execRaceYield = @import("control_exec.zig").Methods.execRaceYield;

    pub const execRouteGetTag = @import("control_exec.zig").Methods.execRouteGetTag;

    pub const execRouteDispatch = @import("control_exec.zig").Methods.execRouteDispatch;

    pub const execRouteMerge = @import("control_exec.zig").Methods.execRouteMerge;

    pub const nullableInnerWidth = @import("control_exec.zig").Methods.nullableInnerWidth;

    pub const execNullableMake = @import("control_exec.zig").Methods.execNullableMake;

    pub const execNullableIsNull = @import("control_exec.zig").Methods.execNullableIsNull;

    pub const execNullableUnwrap = @import("control_exec.zig").Methods.execNullableUnwrap;

    pub const execNullableUnwrapOr = @import("control_exec.zig").Methods.execNullableUnwrapOr;

    pub const execAlloc = @import("control_exec.zig").Methods.execAlloc;

    pub const execFree = @import("control_exec.zig").Methods.execFree;

    // v3 阶段 5.3：Orbit/原子 读取函数从 orbit_exec.zig 混入
    pub const readAsyncHandle = @import("orbit_exec.zig").Methods.readAsyncHandle;
    pub const readChannelValue = @import("orbit_exec.zig").Methods.readChannelValue;
    pub const readAtomicValue = @import("orbit_exec.zig").Methods.readAtomicValue;

    // v3 阶段 5.3：Orbit/通道/异步执行函数从 orbit_exec.zig 混入
    pub const execOrbitAsyncCreate = @import("orbit_exec.zig").Methods.execOrbitAsyncCreate;
    pub const execOrbitAsyncCreateViaScheduler = @import("orbit_exec.zig").Methods.execOrbitAsyncCreateViaScheduler;
    pub const execOrbitAsyncJoin = @import("orbit_exec.zig").Methods.execOrbitAsyncJoin;
    pub const execOrbitChanSend = @import("orbit_exec.zig").Methods.execOrbitChanSend;
    pub const execOrbitChanRecv = @import("orbit_exec.zig").Methods.execOrbitChanRecv;
    pub const execOrbitChanTryRecv = @import("orbit_exec.zig").Methods.execOrbitChanTryRecv;
    pub const execOrbitAsyncStatus = @import("orbit_exec.zig").Methods.execOrbitAsyncStatus;
    pub const execChannelClose = @import("orbit_exec.zig").Methods.execChannelClose;
    pub const execChannelCreate = @import("orbit_exec.zig").Methods.execChannelCreate;
    pub const execChannelSender = @import("orbit_exec.zig").Methods.execChannelSender;
    pub const execChannelReceiver = @import("orbit_exec.zig").Methods.execChannelReceiver;

    // v3 阶段 5.3：Orbit 迁移/原子执行函数从 orbit_exec.zig 混入
    pub const migrateRefParamValues = @import("orbit_exec.zig").Methods.migrateRefParamValues;
    pub const migrateObjFieldsWorker = @import("orbit_exec.zig").Methods.migrateObjFieldsWorker;
    pub const execAtomicMake = @import("orbit_exec.zig").Methods.execAtomicMake;
    pub const execAtomicFetchAdd = @import("orbit_exec.zig").Methods.execAtomicFetchAdd;
    pub const execAtomicSwap = @import("orbit_exec.zig").Methods.execAtomicSwap;
    pub const execAtomicCas = @import("orbit_exec.zig").Methods.execAtomicCas;

    pub const execErrorMessage = @import("builtin_exec.zig").Methods.execErrorMessage;
    pub const execObjTypeName = @import("builtin_exec.zig").Methods.execObjTypeName;

    // v3 阶段 5.3：闭包/偏应用执行函数从 functional_exec.zig 混入
    pub const execClosureMake = @import("functional_exec.zig").Methods.execClosureMake;
    pub const execPartialMake = @import("functional_exec.zig").Methods.execPartialMake;
    pub const execPartialApplicationCall = @import("functional_exec.zig").Methods.execPartialApplicationCall;

    // v3 阶段 5.3：函数调用执行函数从 call_exec.zig 混入
    pub const execCallIndirect = @import("call_exec.zig").Methods.execCallIndirect;

    /// 将标量 Value 转为字节缓冲区（用于 nullable 写入）
    // v3 阶段 5.3：值/通道转换函数从 value_conv.zig 混入
    pub const readScalarValueToBytes = @import("value_conv.zig").Methods.readScalarValueToBytes;
};

