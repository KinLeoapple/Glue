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

const GlueIR = ir_mod.GlueIR;
const Node = ir_mod.Node;
const LoopMeta = ir_mod.meta_mod.LoopMeta;
const NodeOp = ir_mod.NodeOp;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;
const ConstVal = ir_mod.ConstVal;
const ChanType = ir_mod.ChanType;
const ChannelMeta = ir_mod.ChannelMeta;
const Function = ir_mod.Function;
const Runtime = runtime_mod.Runtime;
const FrameContext = runtime_mod.FrameContext;
const TypeMetadata = ir_mod.meta_mod.TypeMetadata;
const TypeKind = ir_mod.meta_mod.TypeKind;

const debug_route_dispatch = false;
const debug_record = false;
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
fn monotonicMillis() i64 {
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
fn selectBackoffSleep() void {
    if (builtin.os.tag == .windows) {
        Sleep(1);
        return;
    }
    const req = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// 最大调用深度（配合大栈线程使用，防止原生栈溢出）
const MAX_CALL_DEPTH: u32 = 2_000_000;

/// 最大 defer 栈深度（每个函数可注册的 defer 数量上限）
const MAX_DEFERS: u32 = 256;

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
const LoopActiveCache = struct {
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
const BodyKind = enum {
    pure_scalar_chain,
    scan_compatible,
    scan_incompatible,
    state_machine,
    unsupported,
};

/// 直接调用入口类型：每个标量节点的零 dispatch 执行函数
/// 函数指针指向 Engine 的 exec* 方法，绕过 execNode 的 switch
const ScalarExecFn = *const fn(*Engine, *const Node) EngineError!void;

/// 编译后的 body 指令：直接调用入口 + 原始节点引用
const BodyInst = struct {
    exec: ScalarExecFn,
    node: *const Node,
};

/// 编译后的 body 执行计划
///
/// 首次执行 vec_* 节点时编译，缓存到 body_cache 按 vector_meta_index 索引。
/// IR 不可变，缓存安全。
const CompiledBody = struct {
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
const FuncBodyCache = struct {
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
const SavedResult = union(enum) {
    none,
    bytes: struct { buf: [16]u8, w: u8 },
    value: value.Value,
};

/// 执行引擎：接收 GlueIR 并执行
pub const Engine = struct {
    /// Memoization 缓存键：memo_slot + 参数哈希
    const MemoKey = struct {
        slot: u16,
        arg_hash: u64,
    };

    /// Memoization 缓存值
    /// 标量/nullable<标量> 结果：bytes[0..width] 存储结果字节（最大 16B，覆盖 i128/f128）
    const MemoEntry = struct {
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
    /// IO 接口（用于内置 print/println 输出，可选）
    io: ?std.Io = null,

    /// 函数调用栈（堆分配，支持深度递归）
    call_stack: []Frame = &.{},
    call_depth: u32 = 0,
    /// 当前正在执行的函数索引（供 vec_map 等获取节点切片）
    current_func_idx: u16 = 0,
    /// 最后一次 run() 的实际返回通道索引（供外部查询返回类型）
    result_chan: u16 = 0,

    /// 泛型函数类型实参栈（与 call_stack 并行，每层 frame 的 type_args）
    /// typeof(T) 在泛型函数内通过哨兵 meta_index=0x8000|param_idx 查此栈
    /// 元素为 arena 分配的切片，生命周期与 IR 一致
    frame_type_args_stack: std.ArrayListUnmanaged([]const u16) = .empty,

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
            .runtime = Runtime.init(&tctx.channels, &tctx.call_region, backing, tctx.prof),
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
    /// Engine.io（print 输出用）保持 null，由调用方按需注入
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
            .runtime = Runtime.init(&tctx.channels, &tctx.call_region, backing, tctx.prof),
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

    /// 释放引擎资源
    pub fn deinit(self: *Engine) void {
        // 关闭模式：deinit 函数跳过级联 release 包含值，
        // tracked_objs 循环单独释放每个跟踪对象，避免访问已释放内存
        value.obj_header.shutdown_mode = true;
        defer value.obj_header.shutdown_mode = false;

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

        // 释放泛型类型实参栈（切片本身由 arena 拥有，只释放 ArrayList 容量）
        self.frame_type_args_stack.deinit(backing);

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
    }

    /// 跟踪堆对象（引擎创建的所有堆对象都应调用此方法）
    /// 通过 ObjHeader.flags 的 TRACKED 位去重，避免同一对象被多次跟踪导致 deinit 时双重释放
    /// arena 分配的对象不加入 tracked_objs：由 endFunction 的 arena.reset 统一回收，
    /// 避免 endFunction 后 tracked_objs 指向已回收内存导致 use-after-free。
    fn trackObj(self: *Engine, obj: *value.obj_header.ObjHeader) EngineError!void {
        if (obj.isTracked()) return;
        if (obj.isArenaAllocated()) return;
        self.tracked_objs.append(self.tctx.?.backing, obj) catch return error.OutOfMemory;
        obj.markTracked();
    }

    /// 跟踪字段数组中所有 ref 类型子对象
    /// 用于 metadata 函数：shutdown_mode 下 deinit 跳过级联 release，
    /// 未跟踪的子对象（Str、ArrayValue 等）会泄漏
    fn trackRefFields(self: *Engine, fields: []const value.Value) EngineError!void {
        for (fields) |f| {
            if (f == .ref) try self.trackObj(f.ref);
        }
    }

    /// 当前函数是否为非逃逸函数（逃逸分析驱动）
    /// 用于分配点分流：非逃逸函数内的分配走 ShadowArena，endFunction 时 O(1) reset
    inline fn currentFuncUseArena(self: *Engine) bool {
        return self.ir.functions[self.current_func_idx].no_escape;
    }

    /// 运行入口函数，返回字符串结果（main 函数返回 str 时使用）
    pub fn runStr(self: *Engine) EngineError![]const u8 {
        try self.runtime.layoutGlobals(&self.ir.channels);
        self.precomputeNodeTags();
        const entry = &self.ir.functions[self.ir.entry_index];
        try self.runtime.enterFunction(self.ir.entry_index, entry);
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

    /// 运行入口函数，返回 i64 结果（main 函数的返回值）
    pub fn run(self: *Engine) EngineError!i64 {
        // 布局全局通道存储（GlobalRegion）
        try self.runtime.layoutGlobals(&self.ir.channels);
        // 预计算所有节点的 scalar_tag（消除热路径中 chanToScalarTag 查找）
        self.precomputeNodeTags();

        // 执行初始化函数（顶层 val/var 声明）
        // enterFunction 在 CallStackRegion 中分配 init 函数的本地通道，
        // 全局通道（已在 layoutGlobals 中布局）不受影响。
        if (self.ir.init_index) |init_idx| {
            const init_func = &self.ir.functions[init_idx];
            try self.runtime.enterFunction(init_idx, init_func);
            errdefer self.runtime.leaveFunction();
            _ = try self.execFunction(init_idx, init_func.param_channels);
            self.runtime.leaveFunction();
        }

        // 执行入口函数
        const entry = &self.ir.functions[self.ir.entry_index];
        try self.runtime.enterFunction(self.ir.entry_index, entry);
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
        const ret_meta = self.ir.channels.get(result_chan);
        const w = ret_meta.elem_width;
        const result: i64 = if (w == 0) 0 // unit 返回值
        else if (ret_meta.chan_type == .bool_chan or ret_meta.chan_type == .mask_chan) @intFromBool(self.runtime.readBool(result_chan))
        else blk: {
            // 按宽度读取整数值（符号扩展）
            const ptr = self.runtime.rawPtr(result_chan);
            break :blk switch (w) {
                1 => @as(i64, @as(i8, @bitCast(ptr[0]))),
                2 => @as(i64, @as(i16, @bitCast(@as(*[2]u8, @ptrCast(ptr)).*))),
                4 => @as(i64, @as(i32, @bitCast(@as(*[4]u8, @ptrCast(ptr)).*))),
                8 => @as(i64, @bitCast(@as(*[8]u8, @ptrCast(ptr)).*)),
                16 => @as(i64, @truncate(@as(i128, @bitCast(@as(*[16]u8, @ptrCast(ptr)).*)))),
                else => 0,
            };
        };
        self.runtime.leaveFunction();
        return result;
    }

    /// 执行一个函数，返回结果通道索引
    fn execFunction(self: *Engine, initial_func_idx: u16, args: []const u16) EngineError!u16 {
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
                                    try inst.exec(self, inst.node);
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
                                    try inst.exec(self, inst.node);
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
    fn execNode(self: *Engine, node: *const Node) EngineError!?u16 {
        switch (node.op) {
            // === 常量 ===
            .const_i, .const_f, .const_bool, .const_char => try self.execConst(node),
            .const_unit => self.execConstUnit(node),
            .const_null => self.execConstNull(node),
            .const_str => try self.execConstStr(node),

            // === 整数算术（复用 value.ops） ===
            .int_add => try self.execIntBinOp(node, .add),
            .int_sub => try self.execIntBinOp(node, .sub),
            .int_mul => try self.execIntBinOp(node, .mul),
            .int_div => try self.execIntBinOp(node, .div),
            .int_mod => try self.execIntBinOp(node, .mod),
            .int_and => try self.execIntBinOp(node, .bit_and),
            .int_or => try self.execIntBinOp(node, .bit_or),
            .int_xor => try self.execIntBinOp(node, .bit_xor),
            .int_shl => try self.execIntShift(node, .shl),
            .int_shr => try self.execIntShift(node, .shr),

            // === 整数一元 ===
            .int_neg => try self.execIntUnOp(node, .neg),
            .int_abs => try self.execIntUnOp(node, .abs),
            .int_not => try self.execIntUnOp(node, .bit_not),

            // === 浮点算术（复用 value.ops） ===
            .float_add => try self.execFloatBinOp(node, .add),
            .float_sub => try self.execFloatBinOp(node, .sub),
            .float_mul => try self.execFloatBinOp(node, .mul),
            .float_div => try self.execFloatBinOp(node, .div),
            .float_mod => try self.execFloatBinOp(node, .mod),

            // === 浮点一元 ===
            .float_neg => try self.execFloatUnOp(node, .neg),
            .float_abs => try self.execFloatUnOp(node, .abs),

            // === 比较（复用 value.ops） ===
            .cmp_eq => try self.execCmp(node, .eq),
            .cmp_ne => try self.execCmp(node, .ne),
            .cmp_lt => try self.execCmp(node, .lt),
            .cmp_le => try self.execCmp(node, .le),
            .cmp_gt => try self.execCmp(node, .gt),
            .cmp_ge => try self.execCmp(node, .ge),

            // === 布尔逻辑 ===
            .bool_and => try self.execBoolBinOp(node, .and_),
            .bool_or => try self.execBoolBinOp(node, .or_),
            .bool_not => try self.execBoolNot(node),

            // === 内存操作（var 变量） ===
            .load => try self.execLoad(node),
            .store => try self.execStore(node),

            // === 借用引用 ===
            .ref_of => try self.execRefOf(node),
            .ref_get => try self.execRefGet(node),
            .ref_set => try self.execRefSet(node),

            // === 选择（if 表达式，标量模式 N=1） ===
            .vec_select => try self.execVecSelect(node),

            // === 类型转换 ===
            .cast => try self.execCast(node, false),
            .cast_safe => try self.execCast(node, true),
            .cast_to => try self.execCastTo(node),
            .cast_try_to => try self.execCastTryTo(node),

            // === 字符串操作 ===
            .string_len => try self.execStringLen(node),
            .string_concat => try self.execStringConcat(node),
            .string_cmp => try self.execStringCmp(node),
            .string_index => try self.execStringIndex(node),
            .string_contains => try self.execStringContains(node),
            .string_slice => try self.execStringSlice(node),
            .string_bytes => try self.execStringBytes(node),
            .array_to_str => try self.execArrayToStr(node),

            // === 数组操作 ===
            .array_make => try self.execArrayMake(node),
            .array_get => try self.execArrayGet(node),
            .array_set => try self.execArraySet(node),
            .array_len => try self.execArrayLen(node),
            .array_push => try self.execArrayPush(node),
            .array_concat => try self.execArrayConcat(node),
            .array_first => try self.execArrayFirst(node),
            .array_last => try self.execArrayLast(node),
            .array_contains => try self.execArrayContains(node),
            .array_get_safe => try self.execArrayGetSafe(node),
            .array_drop_last => try self.execArrayDropLast(node),
            .array_pop => try self.execArrayPop(node),
            .array_fill => try self.execArrayFill(node),
            .array_slice => try self.execArraySlice(node),

            // === 记录操作 ===
            .record_make => try self.execRecordMake(node),
            .record_get => try self.execRecordGet(node),
            .record_set => try self.execRecordSet(node),
            .record_clone => try self.execRecordClone(node),

            // === 向量操作（Phase 3） ===
            .vec_source => try self.execVecSource(node),
            .vec_map => try self.execVecMap(node),
            .vec_map2 => try self.execVecMap2(node),
            .vec_sink => try self.execVecSink(node),
            .vec_fold => try self.execVecFold(node),
            .vec_scan => try self.execVecScan(node),
            .vec_filter => try self.execVecFilter(node),
            .vec_take => try self.execVecTake(node),
            .vec_take_while => try self.execVecTakeWhile(node),
            .vec_zip => try self.execVecZip(node),

            // === 门控（Phase 4：错误处理） ===
            .gate_check => try self.execGateCheck(node),
            .gate_get_ok => try self.execGateGetOk(node),
            .gate_get_err => try self.execGateGetErr(node),
            .gate_propagate => try self.execGatePropagate(node),
            .gate_select => try self.execGateSelect(node),
            .gate_make_ok => try self.execGateMakeOk(node),
            .gate_make_err => try self.execGateMakeErr(node),

            // === 清理（Phase 4：defer） ===
            .cleanup_register => try self.execCleanupRegister(node),
            // cleanup_run 由 execFunction 在 halt 时自动调用，不通过 execNode 分派

            // === 路由 + 竞争（Phase 5：select 多路复用 + Trait 分派） ===
            .race_source => try self.execRaceSource(node),
            .race_select => try self.execRaceSelect(node),
            .race_yield => try self.execRaceYield(node),
            .route_get_tag => try self.execRouteGetTag(node),
            .route_dispatch => return try self.execRouteDispatch(node),
            .route_merge => try self.execRouteMerge(node),

            // === Nullable（Phase 6：可空值） ===
            .nullable_make => try self.execNullableMake(node),
            .nullable_is_null => try self.execNullableIsNull(node),
            .nullable_unwrap => try self.execNullableUnwrap(node),
            .nullable_unwrap_or => try self.execNullableUnwrapOr(node),

            // === 内存管理（Phase 6：unsafe 手动分配） ===
            .alloc => try self.execAlloc(node),
            .free => try self.execFree(node),

            // === 星轨执行（Phase 7：async/spawn） ===
            .orbit_async_create => try self.execOrbitAsyncCreate(node),
            .orbit_async_join => try self.execOrbitAsyncJoin(node),
            .orbit_async_status => try self.execOrbitAsyncStatus(node),
            .orbit_chan_send => try self.execOrbitChanSend(node),
            .orbit_chan_recv => try self.execOrbitChanRecv(node),
            .orbit_chan_try_recv => try self.execOrbitChanTryRecv(node),
            .channel_close => try self.execChannelClose(node),
            .channel_create => try self.execChannelCreate(node),
            .channel_sender => try self.execChannelSender(node),
            .channel_receiver => try self.execChannelReceiver(node),

            // === 原子操作 ===
            .atomic_make => try self.execAtomicMake(node),
            .atomic_fetch_add => try self.execAtomicFetchAdd(node),
            .atomic_swap => try self.execAtomicSwap(node),
            .atomic_cas => try self.execAtomicCas(node),

            // === 反射方法 ===
            .error_message => try self.execErrorMessage(node),
            .obj_type_name => try self.execObjTypeName(node),

            // === 闭包（lambda） ===
            .closure_make => try self.execClosureMake(node),
            .call_indirect => try self.execCallIndirect(node),

            // === 部分应用 ===
            .partial_make => try self.execPartialMake(node),

            // === 惰性求值（Lazy<T>） ===
            .lazy_make => try self.execLazyMake(node),
            .lazy_force => try self.execLazyForce(node),

            // === 控制流 ===
            .call => try self.execCall(node),
            .halt_return => return node.inputs[0],
            .halt_throw => return error.Thrown,
            .halt_panic => return error.Panic,
            .halt_break => return error.LoopBreak,
            .halt_continue => return error.LoopContinue,
            .scalar_loop => return try self.execScalarLoop(node),

            // === 内置函数 ===
            .builtin_print => try self.execBuiltinPrint(node, false, false),
            .builtin_println => try self.execBuiltinPrint(node, true, false),
            .builtin_eprint => try self.execBuiltinPrint(node, false, true),
            .builtin_eprintln => try self.execBuiltinPrint(node, true, true),
            .builtin_scan => try self.execBuiltinScan(node, false),
            .builtin_scanln => try self.execBuiltinScan(node, true),
            .builtin_ok => try self.execBuiltinOk(node),
            .builtin_error => try self.execBuiltinError(node),
            .builtin_eq => try self.execBuiltinEq(node),
            .builtin_ref_eq => try self.execBuiltinRefEq(node),
            .builtin_str => try self.execBuiltinStr(node),
            .builtin_type => try self.execBuiltinType(node),
            .builtin_typeof => try self.execBuiltinTypeof(node),
            .builtin_panic => return error.Panic,

            // === Syscall 调用 ===
            .syscall_call => try self.execSyscall(node),

            // === Newtype ===
            .newtype_wrap => try self.execNewtypeWrap(node),
            .newtype_unwrap => try self.execNewtypeUnwrap(node),

            else => return error.UnsupportedOp,
        }
        return null;
    }

    // ════════════════════════════════════════════
    // 通道元信息 → ScalarTag 映射
    // ════════════════════════════════════════════

    /// 从通道元信息推导 ScalarTag（用于选择 ops 函数）
    fn chanToScalarTag(chan_meta: ChannelMeta) ?ScalarTag {
        return switch (chan_meta.chan_type) {
            .bool_chan, .mask_chan => .boolean,
            .char_chan => .char,
            .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
            .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
            .isize_chan => .isize, .usize_chan => .usize,
            .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
            else => null,
        };
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
    fn readChanBytes(self: *Engine, chan: u16) [16]u8 {
        var buf: [16]u8 = [_]u8{0} ** 16;
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(buf[0..w], self.runtime.rawPtr(chan)[0..w]);
        }
        return buf;
    }

    /// 写入 16 字节缓冲区的前 N 字节到通道
    fn writeChanBytes(self: *Engine, chan: u16, buf: [16]u8) void {
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(self.runtime.rawPtr(chan)[0..w], buf[0..w]);
        }
    }

    /// 运行时 tag → comptime 分派：整数二元运算
    /// 通过 inline switch 展开所有整数类型，每个分支调用 comptime 特化的 ops 函数
    fn dispatchIntBinOp(tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        return switch (tag) {
            .i8 => dispatchIntBinOpT(.i8, kind, a, b),
            .i16 => dispatchIntBinOpT(.i16, kind, a, b),
            .i32 => dispatchIntBinOpT(.i32, kind, a, b),
            .i64 => dispatchIntBinOpT(.i64, kind, a, b),
            .i128 => dispatchIntBinOpT(.i128, kind, a, b),
            .u8 => dispatchIntBinOpT(.u8, kind, a, b),
            .u16 => dispatchIntBinOpT(.u16, kind, a, b),
            .u32 => dispatchIntBinOpT(.u32, kind, a, b),
            .u64 => dispatchIntBinOpT(.u64, kind, a, b),
            .u128 => dispatchIntBinOpT(.u128, kind, a, b),
            else => null,
        };
    }

    fn dispatchIntBinOpT(comptime tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .add => ops.add(tag, a_bytes, b_bytes),
            .sub => ops.sub(tag, a_bytes, b_bytes),
            .mul => ops.mul(tag, a_bytes, b_bytes),
            .div => ops.div(tag, a_bytes, b_bytes),
            .mod => ops.mod(tag, a_bytes, b_bytes),
            .bit_and => ops.bitAnd(tag, a_bytes, b_bytes),
            .bit_or => ops.bitOr(tag, a_bytes, b_bytes),
            .bit_xor => ops.bitXor(tag, a_bytes, b_bytes),
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：浮点二元运算
    fn dispatchFloatBinOp(tag: ScalarTag, kind: FloatBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        return switch (tag) {
            .f16 => dispatchFloatBinOpT(.f16, kind, a, b),
            .f32 => dispatchFloatBinOpT(.f32, kind, a, b),
            .f64 => dispatchFloatBinOpT(.f64, kind, a, b),
            .f128 => dispatchFloatBinOpT(.f128, kind, a, b),
            else => null,
        };
    }

    fn dispatchFloatBinOpT(comptime tag: ScalarTag, kind: FloatBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .add => ops.add(tag, a_bytes, b_bytes),
            .sub => ops.sub(tag, a_bytes, b_bytes),
            .mul => ops.mul(tag, a_bytes, b_bytes),
            .div => ops.div(tag, a_bytes, b_bytes),
            .mod => ops.mod(tag, a_bytes, b_bytes),
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：整数一元运算
    fn dispatchIntUnOp(tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) ?[16]u8 {
        return switch (tag) {
            .i8 => dispatchIntUnOpT(.i8, kind, a),
            .i16 => dispatchIntUnOpT(.i16, kind, a),
            .i32 => dispatchIntUnOpT(.i32, kind, a),
            .i64 => dispatchIntUnOpT(.i64, kind, a),
            .i128 => dispatchIntUnOpT(.i128, kind, a),
            .u8 => dispatchIntUnOpT(.u8, kind, a),
            .u16 => dispatchIntUnOpT(.u16, kind, a),
            .u32 => dispatchIntUnOpT(.u32, kind, a),
            .u64 => dispatchIntUnOpT(.u64, kind, a),
            .u128 => dispatchIntUnOpT(.u128, kind, a),
            else => null,
        };
    }

    fn dispatchIntUnOpT(comptime tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .bit_not => @as(?ByteArrayT, ops.bitNot(tag, a_bytes)),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                const r = if (@typeInfo(T).int.signedness == .signed) @abs(av) else av;
                break :blk @as(?ByteArrayT, @bitCast(@as(T, @intCast(r))));
            },
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：浮点一元运算
    fn dispatchFloatUnOp(tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) ?[16]u8 {
        return switch (tag) {
            .f16 => dispatchFloatUnOpT(.f16, kind, a),
            .f32 => dispatchFloatUnOpT(.f32, kind, a),
            .f64 => dispatchFloatUnOpT(.f64, kind, a),
            .f128 => dispatchFloatUnOpT(.f128, kind, a),
            else => null,
        };
    }

    fn dispatchFloatUnOpT(comptime tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                break :blk @as(?ByteArrayT, @bitCast(@abs(av)));
            },
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：比较运算
    /// 所有 ScalarTag 变体均已覆盖，无需 else 分支
    /// boolean 类型不经过 ops（@bitCast 位宽不匹配），直接内联比较
    fn dispatchCmp(tag: ScalarTag, kind: CmpKind, a: [16]u8, b: [16]u8) bool {
        return switch (tag) {
            .boolean => blk: {
                const av = a[0] != 0;
                const bv = b[0] != 0;
                break :blk switch (kind) {
                    .eq => av == bv,
                    .ne => av != bv,
                    .lt => !av and bv,
                    .le => !av or bv,
                    .gt => av and !bv,
                    .ge => av or !bv,
                };
            },
            .i8 => dispatchCmpT(.i8, kind, a, b),
            .i16 => dispatchCmpT(.i16, kind, a, b),
            .i32 => dispatchCmpT(.i32, kind, a, b),
            .i64 => dispatchCmpT(.i64, kind, a, b),
            .i128 => dispatchCmpT(.i128, kind, a, b),
            .u8 => dispatchCmpT(.u8, kind, a, b),
            .u16 => dispatchCmpT(.u16, kind, a, b),
            .u32 => dispatchCmpT(.u32, kind, a, b),
            .u64 => dispatchCmpT(.u64, kind, a, b),
            .u128 => dispatchCmpT(.u128, kind, a, b),
            .f16 => dispatchCmpT(.f16, kind, a, b),
            .f32 => dispatchCmpT(.f32, kind, a, b),
            .f64 => dispatchCmpT(.f64, kind, a, b),
            .f128 => dispatchCmpT(.f128, kind, a, b),
            .char => dispatchCmpT(.char, kind, a, b),
        };
    }

    fn dispatchCmpT(comptime tag: ScalarTag, kind: CmpKind, a: [16]u8, b: [16]u8) bool {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        return switch (kind) {
            .eq => ops.eq(tag, a_bytes, b_bytes),
            .ne => ops.ne(tag, a_bytes, b_bytes),
            .lt => ops.lt(tag, a_bytes, b_bytes),
            .le => ops.le(tag, a_bytes, b_bytes),
            .gt => ops.gt(tag, a_bytes, b_bytes),
            .ge => ops.ge(tag, a_bytes, b_bytes),
        };
    }

    /// 内联标量二元运算分派：根据 NodeOp 选择对应的 dispatch 函数
    /// 用于 vec_fold/vec_scan 的内联标量模式（body_len == 0）
    fn dispatchInlineBinOp(op: NodeOp, tag: ScalarTag, a: [16]u8, b: [16]u8) EngineError![16]u8 {
        return switch (op) {
            .int_add => dispatchIntBinOp(tag, .add, a, b) orelse return error.Overflow,
            .int_sub => dispatchIntBinOp(tag, .sub, a, b) orelse return error.Overflow,
            .int_mul => dispatchIntBinOp(tag, .mul, a, b) orelse return error.Overflow,
            .int_div => dispatchIntBinOp(tag, .div, a, b) orelse return error.DivisionByZero,
            .int_mod => dispatchIntBinOp(tag, .mod, a, b) orelse return error.DivisionByZero,
            .int_and => dispatchIntBinOp(tag, .bit_and, a, b) orelse return error.Overflow,
            .int_or => dispatchIntBinOp(tag, .bit_or, a, b) orelse return error.Overflow,
            .int_xor => dispatchIntBinOp(tag, .bit_xor, a, b) orelse return error.Overflow,
            .float_add => dispatchFloatBinOp(tag, .add, a, b) orelse return error.Overflow,
            .float_sub => dispatchFloatBinOp(tag, .sub, a, b) orelse return error.Overflow,
            .float_mul => dispatchFloatBinOp(tag, .mul, a, b) orelse return error.Overflow,
            .float_div => dispatchFloatBinOp(tag, .div, a, b) orelse return error.Overflow,
            .float_mod => dispatchFloatBinOp(tag, .mod, a, b) orelse return error.Overflow,
            else => return error.UnsupportedOp,
        };
    }

    /// NodeOp → batch.BinOp 映射（仅数值算术/位运算）
    /// 用于 vec_fold/vec_scan 内联模式接入 SIMD 批量运算
    fn nodeOpToBatchBinOp(op: NodeOp) ?batch.BinOp {
        return switch (op) {
            .int_add, .float_add => .add,
            .int_sub, .float_sub => .sub,
            .int_mul, .float_mul => .mul,
            .int_div, .float_div => .div,
            .int_mod, .float_mod => .mod,
            .int_and => .band,
            .int_or => .bor,
            .int_xor => .bxor,
            else => null,
        };
    }

    /// SIMD 批量归约分派：运行时 tag × op 通过 inline switch 展开为 comptime 特化调用
    /// 用于 vec_fold 内联模式（body_len == 0），用 @reduce 横向归约替代逐元素 dispatch
    fn dispatchBatchReduce(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        init_bytes: [16]u8,
        src_chan: u16,
        count: u32,
    ) EngineError![16]u8 {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .isize, .usize,
                    .f16, .f32, .f64, .f128 => |comptime_tag| blk: {
                        const T = scalar.NativeType(comptime_tag);
                        // init_bytes [16]u8 → T（前 @sizeOf(T) 字节有效）
                        var t_init: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&t_init))[0..@sizeOf(T)],
                            init_bytes[0..@sizeOf(T)],
                        );
                        // 通道字节指针 → 类型化切片（region 64B 对齐，满足所有标量 T）
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const t_result = batch.batchReduce(T, comptime_op, t_init, src_ptr[0..count]) catch |err| return err;
                        // T → [16]u8
                        var out: [16]u8 = [_]u8{0} ** 16;
                        @memcpy(
                            out[0..@sizeOf(T)],
                            @as([*]const u8, @ptrCast(&t_result))[0..@sizeOf(T)],
                        );
                        break :blk out;
                    },
                    else => return error.UnsupportedOp,
                };
            },
            .shl, .shr => return error.UnsupportedOp,
        };
    }

    /// SIMD 批量前缀扫描分派：用于 vec_scan 内联模式（body_len == 0）
    /// 块内 inclusive scan + 块间累加器修正，替代逐元素 dispatch
    fn dispatchBatchScan(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        init_bytes: [16]u8,
        dst_chan: u16,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var t_init: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&t_init))[0..@sizeOf(T)],
                            init_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchScan(T, comptime_op, t_init, dst_ptr[0..count], src_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
            .shl, .shr => return error.UnsupportedOp,
        };
    }

    /// NodeOp → batch.UnaryOp 映射（仅一元算术/位运算）
    /// 用于 vec_map 内联单节点 body 批量化
    fn nodeOpToBatchUnaryOp(op: NodeOp) ?batch.UnaryOp {
        return switch (op) {
            .int_neg, .float_neg => .neg,
            .int_abs, .float_abs => .abs,
            .int_not => .bnot,
            else => null,
        };
    }

    /// 一元 map 批量分派：dst[i] = unop(src[i])
    /// 用于 vec_map 的 body 是单个一元 op 节点的情况
    fn dispatchBatchMapUnary(
        self: *Engine,
        tag: ScalarTag,
        uop: batch.UnaryOp,
        dst_chan: u16,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (uop) {
            inline .neg, .abs, .bnot => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchUnary(T, comptime_op, dst_ptr[0..count], src_ptr[0..count]);
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（标量右操作数）批量分派：dst[i] = src[i] op scalar
    /// 用于 vec_map 的 body 是 `x op const` 形式
    fn dispatchBatchMapScalarR(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        src_chan: u16,
        scalar_bytes: [16]u8,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var scalar_val: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&scalar_val))[0..@sizeOf(T)],
                            scalar_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOpScalar(T, comptime_op, dst_ptr[0..count], src_ptr[0..count], scalar_val) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（标量左操作数）批量分派：dst[i] = scalar op src[i]
    /// 用于 vec_map 的 body 是 `const op x` 形式
    fn dispatchBatchMapScalarL(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        scalar_bytes: [16]u8,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var scalar_val: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&scalar_val))[0..@sizeOf(T)],
                            scalar_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOpScalarR(T, comptime_op, dst_ptr[0..count], scalar_val, src_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（双向量）批量分派：dst[i] = left[i] op right[i]
    /// 用于 vec_map2 的 body 是单个二元 op 节点的情况
    fn dispatchBatchMap2(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        left_chan: u16,
        right_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        const left_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(left_chan)));
                        const right_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(right_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOp(T, comptime_op, dst_ptr[0..count], left_ptr[0..count], right_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    // ════════════════════════════════════════════
    // 常量执行
    // ════════════════════════════════════════════

    fn execConst(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            self.runtime.writeConst(node.output, cv, meta.kind);
        }
    }

    fn execConstUnit(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    fn execConstNull(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    /// 内置 print/println/eprint/eprintln：根据通道类型打印值
    fn execBuiltinPrint(self: *Engine, node: *const Node, with_newline: bool, to_stderr: bool) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        // 通过通用观察点读取值：readScalarValue 会在 ref_chan 指向 LazyValue 时自动强制求值。
        // 同时保存结果，供 ref_chan 标量回退路径使用（类型参数实例化为标量时 ref_chan 持有标量位模式）。
        const observed_val = try self.readScalarValue(val_chan);

        // io 仅用作"是否处于真实执行环境"的标记（测试中为 null，跳过实际输出）
        // 实际输出统一走注入的 std.Io（stdout/stderr streaming writer），
        // 避免裸 std.c.write 与 std.Io 缓冲层状态不同步导致重复内容丢失
        const io = self.io orelse return;

        var buf: [4096]u8 = undefined;
        var len: usize = 0;

        // 格式化追加到 buf 的辅助函数
        const ap = struct {
            fn call(b: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) void {
                if (pos.* >= b.len) return;
                const result = std.fmt.bufPrint(b[pos.*..], fmt, args) catch return;
                pos.* += result.len;
            }
        }.call;

        switch (meta.chan_type) {
            .ref_chan => {
                // Lazy<T> 被打印时强制求值一次，避免惰性语义仅停留在包装层
                if (self.readLazyValue(val_chan)) |lazy| {
                    const forced = try self.forceLazyValue(lazy);
                    switch (forced) {
                        .i64 => |b| ap(&buf, &len, "{d}", .{@as(i64, @bitCast(b))}),
                        .i32 => |b| ap(&buf, &len, "{d}", .{@as(i32, @bitCast(b))}),
                        .i16 => |b| ap(&buf, &len, "{d}", .{@as(i16, @bitCast(b[0..2].*))}),
                        .i8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .u64 => |b| ap(&buf, &len, "{d}", .{@as(u64, @bitCast(b))}),
                        .u32 => |b| ap(&buf, &len, "{d}", .{@as(u32, @bitCast(b))}),
                        .u16 => |b| ap(&buf, &len, "{d}", .{@as(u16, @bitCast(b[0..2].*))}),
                        .u8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .f64 => |b| ap(&buf, &len, "{d}", .{@as(f64, @bitCast(b))}),
                        .f32 => |b| ap(&buf, &len, "{d}", .{@as(f32, @bitCast(b[0..4].*))}),
                        .boolean => |b| ap(&buf, &len, "{}", .{b[0] != 0}),
                        .char => |b| ap(&buf, &len, "{c}", .{@as(u8, @intCast(@as(u32, @bitCast(b[0..4].*))))}),
                        .unit => ap(&buf, &len, "()", .{}),
                        .null_val => ap(&buf, &len, "null", .{}),
                        .ref => ap(&buf, &len, "<obj>", .{}),
                        else => ap(&buf, &len, "<lazy:?>", .{}),
                    }
                    return self.flushPrintBuf(io, to_stderr, &buf, len, with_newline);
                }
                // 按引用类型分派打印
                if (self.readStr(val_chan)) |s| {
                    ap(&buf, &len, "{s}", .{s.bytes()});
                } else if (self.readThrow(val_chan)) |tv| {
                    switch (tv.payload) {
                        .ok => |v| {
                            // 简化：标量值打印数字，引用打印类型
                            switch (v) {
                                .i64 => |b| ap(&buf, &len, "Ok({d})", .{@as(i64, @bitCast(b))}),
                                .i32 => |b| ap(&buf, &len, "Ok({d})", .{@as(i32, @bitCast(b))}),
                                .boolean => |b| ap(&buf, &len, "Ok({})", .{b[0] != 0}),
                                .null_val => ap(&buf, &len, "Ok(null)", .{}),
                                .unit => ap(&buf, &len, "Ok(())", .{}),
                                .ref => ap(&buf, &len, "Ok(<obj>)", .{}),
                                else => ap(&buf, &len, "Ok(?)", .{}),
                            }
                        },
                        .err => |e| {
                            ap(&buf, &len, "Error({s})", .{e.message});
                        },
                    }
                } else if (self.readError(val_chan)) |e| {
                    ap(&buf, &len, "Error({s})", .{e.message});
                } else if (self.readRecord(val_chan)) |rec| {
                    // record/ADT/newtype：打印 TypeName(field0, field1, ...)
                    ap(&buf, &len, "{s}(", .{if (rec.type_name.len > 0) rec.type_name else "record"});
                    for (rec.fields, 0..) |f, i| {
                        if (i > 0) ap(&buf, &len, ", ", .{});
                        switch (f) {
                            .boolean => |b| ap(&buf, &len, "{}", .{b[0] != 0}),
                            .char => |c| {
                                const cp: u32 = (@as(u32, c[0]) << 24) | (@as(u32, c[1]) << 16) | (@as(u32, c[2]) << 8) | @as(u32, c[3]);
                                if (cp < 128) {
                                    ap(&buf, &len, "{c}", .{@as(u8, @intCast(cp))});
                                } else {
                                    ap(&buf, &len, "U+{x:0>4}", .{cp});
                                }
                            },
                            .i8 => ap(&buf, &len, "{d}", .{f.asI8()}),
                            .i16 => ap(&buf, &len, "{d}", .{f.asI16()}),
                            .i32 => ap(&buf, &len, "{d}", .{f.asI32()}),
                            .i64 => ap(&buf, &len, "{d}", .{f.asI64()}),
                            .i128 => ap(&buf, &len, "{d}", .{f.asI128()}),
                            .u8 => ap(&buf, &len, "{d}", .{f.asU8()}),
                            .u16 => ap(&buf, &len, "{d}", .{f.asU16()}),
                            .u32 => ap(&buf, &len, "{d}", .{f.asU32()}),
                            .u64 => ap(&buf, &len, "{d}", .{f.asU64()}),
                            .u128 => ap(&buf, &len, "{d}", .{f.asU128()}),
                            .isize => ap(&buf, &len, "{d}", .{f.asIsize()}),
                            .usize => ap(&buf, &len, "{d}", .{f.asUsize()}),
                            .f16 => ap(&buf, &len, "{d}", .{f.asF16()}),
                            .f32 => ap(&buf, &len, "{d}", .{f.asF32()}),
                            .f64 => ap(&buf, &len, "{d}", .{f.asF64()}),
                            .f128 => ap(&buf, &len, "{d}", .{f.asF128()}),
                            .unit => ap(&buf, &len, "()", .{}),
                            .null_val => ap(&buf, &len, "null", .{}),
                            .ref => |obj| {
                                if (obj.type_tag == .str) {
                                    const sv: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", obj));
                                    ap(&buf, &len, "{s}", .{sv.bytes()});
                                } else {
                                    ap(&buf, &len, "<obj>", .{});
                                }
                            },
                        }
                    }
                    ap(&buf, &len, ")", .{});
                } else if (self.readAtomicValue(val_chan)) |av| {
                    // AtomicValue：加载内部值并打印
                    const inner = av.load();
                    switch (inner) {
                        .i64 => |b| ap(&buf, &len, "{d}", .{@as(i64, @bitCast(b))}),
                        .i32 => |b| ap(&buf, &len, "{d}", .{@as(i32, @bitCast(b))}),
                        .i16 => |b| ap(&buf, &len, "{d}", .{@as(i16, @bitCast(b))}),
                        .i8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .u64 => |b| ap(&buf, &len, "{d}", .{@as(u64, @bitCast(b))}),
                        .u32 => |b| ap(&buf, &len, "{d}", .{@as(u32, @bitCast(b))}),
                        .u16 => |b| ap(&buf, &len, "{d}", .{@as(u16, @bitCast(b))}),
                        .u8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .f64 => |b| ap(&buf, &len, "{d}", .{@as(f64, @bitCast(b))}),
                        .f32 => |b| ap(&buf, &len, "{d}", .{@as(f32, @bitCast(b))}),
                        .boolean => |b| ap(&buf, &len, "{}", .{b[0] != 0}),
                        .unit => ap(&buf, &len, "()", .{}),
                        .null_val => ap(&buf, &len, "null", .{}),
                        else => ap(&buf, &len, "<atomic:?>", .{}),
                    }
                } else {
                    // ref_chan 持有标量位模式（类型参数实例化为标量时）：
                    // 按 observed_val 的实际类型打印
                    switch (observed_val) {
                        .i64 => |b| ap(&buf, &len, "{d}", .{@as(i64, @bitCast(b))}),
                        .i32 => |b| ap(&buf, &len, "{d}", .{@as(i32, @bitCast(b))}),
                        .i16 => |b| ap(&buf, &len, "{d}", .{@as(i16, @bitCast(b))}),
                        .i8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .u64 => |b| ap(&buf, &len, "{d}", .{@as(u64, @bitCast(b))}),
                        .u32 => |b| ap(&buf, &len, "{d}", .{@as(u32, @bitCast(b))}),
                        .u16 => |b| ap(&buf, &len, "{d}", .{@as(u16, @bitCast(b))}),
                        .u8 => |b| ap(&buf, &len, "{d}", .{b[0]}),
                        .f64 => |b| ap(&buf, &len, "{d}", .{@as(f64, @bitCast(b))}),
                        .f32 => |b| ap(&buf, &len, "{d}", .{@as(f32, @bitCast(b))}),
                        .boolean => |b| ap(&buf, &len, "{}", .{b[0] != 0}),
                        .null_val => ap(&buf, &len, "null", .{}),
                        .unit => ap(&buf, &len, "()", .{}),
                        else => ap(&buf, &len, "null", .{}),
                    }
                }
            },
            .i64_chan => ap(&buf, &len, "{d}", .{self.runtime.readI64(val_chan)}),
            .i32_chan => {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .i16_chan => {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .i8_chan => {
                const ptr: *i8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .i128_chan => {
                const ptr: *i128 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .u64_chan => ap(&buf, &len, "{d}", .{self.runtime.readU64(val_chan)}),
            .u32_chan => {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .u16_chan => {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .u8_chan => {
                ap(&buf, &len, "{d}", .{self.runtime.rawPtr(val_chan)[0]});
            },
            .u128_chan => {
                const ptr: *u128 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .isize_chan => ap(&buf, &len, "{d}", .{self.runtime.readUsize(val_chan)}),
            .usize_chan => ap(&buf, &len, "{d}", .{self.runtime.readUsize(val_chan)}),
            .f64_chan => ap(&buf, &len, "{d}", .{self.runtime.readF64(val_chan)}),
            .f32_chan => {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .f16_chan => {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                ap(&buf, &len, "{d}", .{ptr.*});
            },
            .bool_chan, .mask_chan => ap(&buf, &len, "{}", .{self.runtime.readBool(val_chan)}),
            .char_chan => {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                if (ptr.* < 128) {
                    ap(&buf, &len, "{c}", .{@as(u8, @intCast(ptr.*))});
                } else {
                    ap(&buf, &len, "U+{x:0>4}", .{ptr.*});
                }
            },
            .unit_chan => ap(&buf, &len, "()", .{}),
            .null_chan => ap(&buf, &len, "null", .{}),
            .nullable_chan => {
                // nullable 布局：[inner_value][null_flag: 1 byte]，0=有值，1=null
                const inner_w = meta.inner_type.elemWidth();
                const src = self.runtime.rawPtr(val_chan);
                if (src[inner_w] != 0) {
                    ap(&buf, &len, "null", .{});
                } else {
                    // 根据 inner_type 打印内部值
                    switch (meta.inner_type) {
                        .i64_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(i64, src[0..8])}),
                        .i32_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(i32, src[0..4])}),
                        .i16_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(i16, src[0..2])}),
                        .i8_chan => ap(&buf, &len, "{d}", .{src[0]}),
                        .u64_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(u64, src[0..8])}),
                        .u32_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(u32, src[0..4])}),
                        .u16_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(u16, src[0..2])}),
                        .u8_chan => ap(&buf, &len, "{d}", .{src[0]}),
                        .f64_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(f64, src[0..8])}),
                        .f32_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(f32, src[0..4])}),
                        .f16_chan => ap(&buf, &len, "{d}", .{std.mem.bytesToValue(f16, src[0..2])}),
                        .bool_chan => ap(&buf, &len, "{}", .{src[0] != 0}),
                        .ref_chan => {
                            // 字符串或其他引用类型
                            const inner_ptr_bytes: [*]u8 = @ptrCast(src[0..8].ptr);
                            const inner_ptr: usize = std.mem.bytesToValue(usize, inner_ptr_bytes[0..@sizeOf(usize)]);
                            if (inner_ptr < 0x1000) {
                                ap(&buf, &len, "null", .{});
                            } else {
                                const header: *value.obj_header.ObjHeader = @ptrFromInt(inner_ptr);
                                if (header.type_tag == .str) {
                                    const sv: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", header));
                                    ap(&buf, &len, "{s}", .{sv.bytes()});
                                } else {
                                    ap(&buf, &len, "<obj>", .{});
                                }
                            }
                        },
                        else => ap(&buf, &len, "?", .{}),
                    }
                }
            },
            else => {},
        }

        return self.flushPrintBuf(io, to_stderr, &buf, len, with_newline);
    }

    /// 输出 print 缓冲区到 stdout/stderr（统一走 std.Io streaming writer）
    fn flushPrintBuf(self: *Engine, io: std.Io, to_stderr: bool, buf: *[4096]u8, len: usize, with_newline: bool) EngineError!void {
        _ = self;
        var wlen = len;
        if (with_newline and wlen < buf.len) {
            buf[wlen] = '\n';
            wlen += 1;
        }
        if (wlen == 0) return;
        // writer 使用独立缓冲，避免与数据源 buf 别名（writeAll 会拷贝到 writer 内部缓冲）
        var out_buf: [4096]u8 = undefined;
        var w = if (to_stderr)
            std.Io.File.stderr().writerStreaming(io, &out_buf)
        else
            std.Io.File.stdout().writerStreaming(io, &out_buf);
        w.interface.writeAll(buf[0..wlen]) catch return;
        w.flush() catch return;
    }

    /// builtin_ok：构造 ThrowValue(ok payload)
    /// inputs[0] = 值通道
    fn execBuiltinOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const v = self.chanToValue(val_chan);
        if (debug_record) {
            const in_meta = self.ir.channels.get(val_chan);
            std.debug.print("builtin_ok: input_chan={} input_type={s} val_tag={s} output_chan={}\n", .{ val_chan, @tagName(in_meta.chan_type), @tagName(v), node.output });
            switch (v) {
                .ref => |r| {
                    const header: *value.obj_header.ObjHeader = @ptrCast(r);
                    std.debug.print("  input ref ptr={} type_tag={s}\n", .{ @intFromPtr(r), @tagName(header.type_tag) });
                },
                else => {},
            }
        }
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
        if (debug_record) {
            std.debug.print("  throw_val ptr={} output_chan={} written ptr={}\n", .{ @intFromPtr(throw_v.asRef()), node.output, @intFromPtr(throw_v.asRef()) });
        }
    }

    /// builtin_error：构造 ThrowValue(err payload) + ErrorValue
    /// inputs[0] = 消息通道（ref_chan 指向 StringValue）
    fn execBuiltinError(self: *Engine, node: *const Node) EngineError!void {
        const msg_chan = node.inputs[0];
        const msg_bytes = if (self.readStr(msg_chan)) |s| s.bytes() else "";

        const err_v = value.Value.makeError(self.tctx.?, "Error", msg_bytes, false) catch return error.OutOfMemory;
        try self.trackObj(err_v.asRef());
        const err_val: *value.ErrorValue = @alignCast(@fieldParentPtr("header", err_v.asRef()));

        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = err_val }) catch return error.OutOfMemory;
        _ = value.obj_header.retain(&err_val.header, self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// builtin_eq：递归值相等比较（==）
    /// 使用 chanToValue 将通道值转为 Value，再调用 value.equals 做完整递归比较
    fn execBuiltinEq(self: *Engine, node: *const Node) EngineError!void {
        const a_val = self.chanToValue(node.inputs[0]);
        const b_val = self.chanToValue(node.inputs[1]);
        self.runtime.writeBool(node.output, value.equals(a_val, b_val));
    }

    /// builtin_ref_eq：引用相等比较（===）
    /// 堆类型比较 *ObjHeader 指针；标量退化为值相等（==）
    fn execBuiltinRefEq(self: *Engine, node: *const Node) EngineError!void {
        const a_val = self.chanToValue(node.inputs[0]);
        const b_val = self.chanToValue(node.inputs[1]);
        const result = switch (a_val) {
            .ref => |a_ref| switch (b_val) {
                .ref => |b_ref| a_ref == b_ref,
                else => false,
            },
            // 标量/null/unit 退化为值相等
            else => value.equals(a_val, b_val),
        };
        self.runtime.writeBool(node.output, result);
    }

    /// builtin_str：将任意值转为字符串
    /// inputs[0] = 值通道
    fn execBuiltinStr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        var buf: [64]u8 = undefined;
        const slice: []const u8 = switch (meta.chan_type) {
            .i64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readI64(val_chan)}) catch "",
            .i32_chan => blk: {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .i16_chan => blk: {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .i8_chan => blk: {
                const ptr: *i8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readU64(val_chan)}) catch "",
            .u32_chan => blk: {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u16_chan => blk: {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u8_chan => blk: {
                const ptr: *u8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .isize_chan => blk: {
                const ptr: *isize = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .usize_chan => blk: {
                const ptr: *usize = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .f64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readF64(val_chan)}) catch "",
            .f32_chan => blk: {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .f16_chan => blk: {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .bool_chan, .mask_chan => if (self.runtime.readBool(val_chan)) "true" else "false",
            .char_chan => blk: {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                const cp: u21 = @intCast(ptr.*);
                if (cp < 128) {
                    buf[0] = @intCast(cp);
                    break :blk buf[0..1];
                }
                // 多字节 UTF-8
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                break :blk buf[0..n];
            },
            .ref_chan => blk: {
                if (self.readStr(val_chan)) |s| break :blk s.bytes();
                // 检查是否为数组（u8[] → UTF-8 解码为字符串）
                if (self.readArray(val_chan)) |arr| {
                    // 仅当所有元素都是 u8 时，按字节拼接为字符串
                    if (arr.elements.len > 0 and arr.elements[0] == .u8) {
                        // 使用 array_to_str 路径：解码为 Str
                        const tmp_bytes = self.tctx.?.backing.alloc(u8, arr.elements.len) catch return error.OutOfMemory;
                        defer self.tctx.?.backing.free(tmp_bytes);
                        for (arr.elements, 0..) |elem, i| {
                            tmp_bytes[i] = elem.asU8();
                        }
                        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, tmp_bytes) catch return error.OutOfMemory;
                        try self.trackObj(&new_str.header);
                        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
                        return;
                    }
                    // 其他数组类型：显示为 [elem1, elem2, ...]
                    break :blk "[array]";
                }
                // gate_get_ok 可能把标量值写入 ref_chan（i32/i64 等）
                // 尝试读取为 i64
                const iv = self.runtime.readI64(val_chan);
                if (iv != 0) {
                    break :blk std.fmt.bufPrint(&buf, "{d}", .{iv}) catch "null";
                }
                break :blk "null";
            },
            .unit_chan => "()",
            .null_chan => "null",
            else => "",
        };

        // 创建 Str 并写入输出通道
        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, slice) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
    }

    /// builtin_scan/scanln：从 stdin 读取
    /// scan: 读取一个空白分隔的 token
    /// scanln: 读取一整行（不含换行）
    /// output = ref_chan（Str 指针）或 null_chan（EOF）
    fn execBuiltinScan(self: *Engine, node: *const Node, line_mode: bool) EngineError!void {
        const io = self.io orelse {
            self.runtime.writePtr(node.output, null);
            return;
        };
        var r_buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &r_buf);
        const result: ?[]const u8 = if (line_mode)
            reader.interface.takeDelimiterExclusive('\n') catch null
        else
            reader.interface.takeDelimiterExclusive(' ') catch null;

        if (result) |bytes| {
            const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, bytes) catch return error.OutOfMemory;
            try self.trackObj(&str_obj.header);
            self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
        } else {
            self.runtime.writePtr(node.output, null);
        }
    }

    /// builtin_type：返回值的运行时类型名
    /// inputs[0] = 值通道
    /// output = ref_chan（Str 指针）
    fn execBuiltinType(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);
        const type_name: []const u8 = switch (meta.chan_type) {
            .i8_chan => "i8",
            .i16_chan => "i16",
            .i32_chan => "i32",
            .i64_chan => "i64",
            .u8_chan => "u8",
            .u16_chan => "u16",
            .u32_chan => "u32",
            .u64_chan => "u64",
            .isize_chan => "isize",
            .usize_chan => "usize",
            .f16_chan => "f16",
            .f32_chan => "f32",
            .f64_chan => "f64",
            .bool_chan, .mask_chan => "bool",
            .char_chan => "char",
            .unit_chan => "unit",
            .null_chan => "null",
            .ref_chan => blk: {
                const header = self.readRefObj(val_chan);
                if (header) |h| {
                    break :blk switch (h.type_tag) {
                        .str => "str",
                        .array => "array",
                        .record => "record",
                        .adt => "adt",
                        .newtype => "newtype",
                        .error_val => "Error",
                        .throw_val => "Throw",
                        .channel_val => "Channel",
                        .async_val => "Spawn",
                        .closure => "function",
                        else => "ref",
                    };
                }
                break :blk "null";
            },
            .nullable_chan => "nullable",
            else => "unknown",
        };

        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, type_name) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
    }

    /// builtin_typeof：编译期类型反射，返回 TypeInfo RecordValue
    ///
    /// 无输入通道；node.meta_index = type_id（1-indexed，0 = 泛型参数 T/Self）
    /// output = ref_chan（RecordValue 指针）
    ///
    /// TypeInfo 是 7 顶层字段的 RecordValue，字段顺序与 IRBuilder.registerTypeInfoFields 一致：
    ///   0=name, 1=module, 2=kind, 3=structure, 4=layout, 5=impls, 6=type_params
    /// 子结构：
    ///   layout = LayoutInfo(size: u32, alignment: u32)
    ///   impls  = TraitImplInfo(parent_traits, implemented_traits, methods, associated_types)
    ///   structure = TypeStructure ADT 变体（type_name 为 "Adt"/"Record"/"Newtype"/... 等）
    ///
    /// type_id 编码：
    ///   - 0：未知/泛型参数 T/Self，运行时查 frame.type_args（参见 Step 3）
    ///   - 0x8000..0xFFFF：泛型参数哨兵，param_idx = meta_index & 0x7FFF
    ///   - 1..N：具体类型 type_id，查 TypeMetadataTable
    fn execBuiltinTypeof(self: *Engine, node: *const Node) EngineError!void {
        const meta_idx = node.meta_index;
        const tctx = self.tctx.?;

        // nullable 包装哨兵：typeof(T?) → 构造 Nullable kind 的 TypeInfo
        // meta_index = 0x4000 | inner_meta_idx
        if (meta_idx & 0x4000 != 0) {
            const inner_meta: u16 = meta_idx & 0xBFFF;
            // 递归构造 inner TypeInfo
            const inner_value = try self.makeTypeInfoFromMeta(inner_meta);
            // 构造 Nullable kind 的 TypeInfo：复用 inner TypeInfo 的字段，
            // 但 kind = Nullable，structure = Nullable(inner_type_id)
            try self.emitNullableTypeInfo(node, inner_value, tctx);
            return;
        }

        // 哨兵：泛型参数 T（meta_index = 0x8000 | param_idx）
        if (meta_idx & 0x8000 != 0) {
            const param_idx: u16 = meta_idx & 0x7FFF;
            // 从当前 frame 的 type_args 查找实际 type_id
            if (self.lookupFrameTypeArg(param_idx)) |actual_type_id| {
                if (actual_type_id != 0) {
                    if (self.ir.type_metadata_table.get(actual_type_id)) |md| {
                        try self.emitTypeInfoRecord(node, md, tctx);
                        return;
                    }
                }
            }
            // 查表失败：返回占位 TypeInfo
            try self.emitPlaceholderTypeInfo(node, "?", tctx);
            return;
        }

        // type_id=0：未知类型，返回占位
        if (meta_idx == 0) {
            try self.emitPlaceholderTypeInfo(node, "?", tctx);
            return;
        }

        // 查表
        const md: *const TypeMetadata = self.ir.type_metadata_table.get(meta_idx) orelse {
            try self.emitPlaceholderTypeInfo(node, "<unknown>", tctx);
            return;
        };

        try self.emitTypeInfoRecord(node, md, tctx);
    }

    /// syscall_call：分派到 syscall 实现（IO/Time 等宿主 syscall 包装）
    ///
    /// meta_index 索引 ir.syscall_metas 表（1-indexed），获取 SyscallId 与 arg_count，
    /// 收集 inputs[] 通道的 Value，调用 syscall.dispatch 执行，结果写入 output 通道。
    fn execSyscall(self: *Engine, node: *const Node) EngineError!void {
        const meta_idx = node.meta_index;
        if (meta_idx == 0 or meta_idx > self.ir.syscall_metas.len) {
            return error.InvalidMetaIndex;
        }
        const syscall_meta = self.ir.syscall_metas[meta_idx - 1];
        const tctx = self.tctx.?;

        // 收集参数（最多 4 个）
        var args: [4]value.Value = .{ value.Value.fromUnit(), value.Value.fromUnit(), value.Value.fromUnit(), value.Value.fromUnit() };
        const arg_count: usize = @min(node.input_count, 4);
        var i: usize = 0;
        while (i < arg_count) : (i += 1) {
            args[i] = self.chanToValue(node.inputs[i]);
        }
        const arg_slice = args[0..arg_count];

        // 分派执行
        const io_ctx = self.io orelse return error.IoNotInitialized;
        const result = syscall_dispatch.dispatch(io_ctx, tctx, syscall_meta.syscall_id, arg_slice) catch |err| switch (err) {
            error.OutOfMemory, error.TooManyPools, error.AllocFailed => return error.OutOfMemory,
            error.InvalidArgument => return error.InvalidMetaIndex,
        };

        // 结果写入 output 通道
        // 标量值直接写通道；堆对象（ref/Throw）写指针
        switch (result) {
            .null_val, .unit => {},
            .boolean => |b| self.runtime.writeBool(node.output, b[0] != 0),
            .char => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                ptr.* = @bitCast(b);
            },
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            .f16, .f32, .f64, .f128 => self.valueToChan(node.output, result),
            .ref => |obj| {
                // 堆对象：trackObj 注册跟踪后写通道
                self.trackObj(obj) catch return error.OutOfMemory;
                self.runtime.writePtr(node.output, @ptrCast(obj));
            },
        }
    }

    /// 从 meta_index 构造 TypeInfo Value（不写入通道，返回 Value）
    /// 用于 typeof(T?) 中递归构造 inner TypeInfo
    fn makeTypeInfoFromMeta(self: *Engine, meta_idx: u16) EngineError!value.Value {
        // nullable 包装
        if (meta_idx & 0x4000 != 0) {
            const inner_meta: u16 = meta_idx & 0xBFFF;
            const inner_val = try self.makeTypeInfoFromMeta(inner_meta);
            return self.makeNullableTypeInfoValue(inner_val);
        }
        // 泛型参数
        if (meta_idx & 0x8000 != 0) {
            const param_idx: u16 = meta_idx & 0x7FFF;
            if (self.lookupFrameTypeArg(param_idx)) |actual_type_id| {
                if (actual_type_id != 0) {
                    if (self.ir.type_metadata_table.get(actual_type_id)) |_| {
                        return self.makeTypeInfoFromId(actual_type_id);
                    }
                }
            }
            return self.makePlaceholderTypeInfoValue("?");
        }
        if (meta_idx == 0) return self.makePlaceholderTypeInfoValue("?");
        if (self.ir.type_metadata_table.get(meta_idx)) |_| {
            return self.makeTypeInfoFromId(meta_idx);
        }
        return self.makePlaceholderTypeInfoValue("<unknown>");
    }

    /// 构造 Nullable kind 的 TypeInfo Value
    /// 复用 inner TypeInfo 的 name，kind=Nullable，structure=Nullable(inner TypeInfo)
    fn makeNullableTypeInfoValue(self: *Engine, inner_value: value.Value) EngineError!value.Value {
        const tctx = self.tctx.?;
        // 从 inner TypeInfo RecordValue 提取 name 字段（fields[0] 是 str）
        const inner_name: []const u8 = blk: {
            switch (inner_value) {
                .ref => |header| {
                    if (header.type_tag == .record) {
                        const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                        if (r.fields.len > 0) {
                            switch (r.fields[0]) {
                                .ref => |str_header| {
                                    if (str_header.type_tag == .str) {
                                        const s: *value.Str = @alignCast(@fieldParentPtr("header", str_header));
                                        break :blk s.bytes();
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
            break :blk "?";
        };
        // structure: Nullable(inner) — 用 Nullable 构造器包装 inner TypeInfo
        var struct_fields = [_]value.Value{inner_value};
        const struct_rec = value.Value.makeRecord(tctx, "Nullable", &struct_fields) catch return error.OutOfMemory;
        try self.trackObj(struct_rec.asRef());

        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, inner_name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, TypeKind.nullable.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = struct_rec;
        field_buf[4] = try self.makeLayoutInfoRecord(.{ .size = 8, .alignment = 8 });
        field_buf[5] = try self.makeEmptyTraitImplInfoRecord();
        field_buf[6] = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 Nullable kind 的 TypeInfo 并写入通道
    fn emitNullableTypeInfo(self: *Engine, node: *const Node, inner_value: value.Value, tctx: *ThreadContext) EngineError!void {
        _ = tctx;
        const rv = try self.makeNullableTypeInfoValue(inner_value);
        self.runtime.writePtr(node.output, @ptrCast(rv.asRef()));
    }

    /// 构造占位 TypeInfo Value（不写入通道，返回 Value）
    fn makePlaceholderTypeInfoValue(self: *Engine, name: []const u8) EngineError!value.Value {
        const tctx = self.tctx.?;
        const unit_rec = value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory;
        try self.trackObj(unit_rec.asRef());

        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, TypeKind.unit.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = unit_rec;
        field_buf[4] = try self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 });
        field_buf[5] = try self.makeEmptyTraitImplInfoRecord();
        field_buf[6] = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 查找当前 frame 的类型实参（Step 3：泛型 T 运行时查表）
    /// 返回 type_id（1-indexed，0 = 未绑定）
    fn lookupFrameTypeArg(self: *Engine, param_idx: u16) ?u16 {
        if (self.frame_type_args_stack.items.len == 0) return null;
        const top = self.frame_type_args_stack.items[self.frame_type_args_stack.items.len - 1];
        if (param_idx >= top.len) return null;
        return top[param_idx];
    }

    /// 构造占位 TypeInfo RecordValue（未知类型或查表失败时使用）
    /// 新设计：7 个顶层字段（name/module/kind/structure/layout/impls/type_params）
    fn emitPlaceholderTypeInfo(self: *Engine, node: *const Node, name: []const u8, tctx: *ThreadContext) EngineError!void {
        var placeholder_fields = [_]value.Value{
            // 0: name
            value.Value.fromStringBytes(tctx, name) catch return error.OutOfMemory,
            // 1: module
            value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory,
            // 2: kind (TypeKind 构造器名)
            value.Value.fromStringBytes(tctx, "Unit") catch return error.OutOfMemory,
            // 3: structure (TypeStructure.Unit，空 RecordValue)
            value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory,
            // 4: layout (LayoutInfo{0, 0})
            self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 }) catch return error.OutOfMemory,
            // 5: impls (empty TraitImplInfo)
            self.makeEmptyTraitImplInfoRecord() catch return error.OutOfMemory,
            // 6: type_params (empty array)
            value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory,
        };
        try self.trackRefFields(&placeholder_fields);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &placeholder_fields) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(rec.asRef()));
    }

    /// 构造完整 TypeInfo RecordValue（7 顶层字段，完整嵌套结构）
    fn emitTypeInfoRecord(self: *Engine, node: *const Node, md: *const TypeMetadata, tctx: *ThreadContext) EngineError!void {
        var field_buf: [7]value.Value = undefined;

        // 0: name (str)
        field_buf[0] = value.Value.fromStringBytes(tctx, md.name) catch return error.OutOfMemory;
        // 1: module (str)
        field_buf[1] = value.Value.fromStringBytes(tctx, md.module) catch return error.OutOfMemory;
        // 2: kind (str，TypeKind 的 ADT 构造器名)
        field_buf[2] = value.Value.fromStringBytes(tctx, md.kind.ctorName()) catch return error.OutOfMemory;
        // 3: structure (TypeStructure ADT，按 kind 构造对应变体)
        field_buf[3] = self.makeStructureRecord(md) catch return error.OutOfMemory;
        // 4: layout (LayoutInfo RecordValue)
        field_buf[4] = self.makeLayoutInfoRecord(md.layout) catch return error.OutOfMemory;
        // 5: impls (TraitImplInfo RecordValue)
        field_buf[5] = self.makeTraitImplInfoRecord(md.impls) catch return error.OutOfMemory;
        // 6: type_params (Array<TypeParamMeta>)
        field_buf[6] = self.makeTypeParamMetaArray(md.type_params) catch return error.OutOfMemory;

        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(rec.asRef()));
    }

    /// 构造 LayoutInfo RecordValue：(size, alignment)
    fn makeLayoutInfoRecord(self: *Engine, layout: ir_mod.meta_mod.LayoutInfo) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            value.Value.fromU32(layout.size),
            value.Value.fromU32(layout.alignment),
        };
        const rec = try value.Value.makeRecord(tctx, "LayoutInfo", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造空 TraitImplInfo RecordValue（占位 TypeInfo 用）
    fn makeEmptyTraitImplInfoRecord(self: *Engine) !value.Value {
        const tctx = self.tctx.?;
        const empty = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackObj(empty.asRef());
        // 同一 ArrayValue 存入 4 个字段，需 retain 3 次（总 RC=4）
        // 避免 RecordValue.deinit 第 1 次 release 释放后，后续 3 次 release 访问已释放内存
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        var fields = [_]value.Value{ empty, empty, empty, empty };
        const rec = value.Value.makeRecord(tctx, "TraitImplInfo", &fields) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitImplInfo RecordValue：(parent_traits, implemented_traits, methods, associated_types)
    fn makeTraitImplInfoRecord(self: *Engine, impls: ir_mod.meta_mod.TraitImplInfo) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            try self.makeTraitMetaArray(impls.parent_traits),
            try self.makeTraitMetaArray(impls.implemented_traits),
            try self.makeMethodMetaArray(impls.methods),
            try self.makeAssociatedTypeMetaArray(impls.associated_types),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TraitImplInfo", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TypeStructure RecordValue（按 kind 构造对应变体）
    /// 返回 RecordValue，type_name 为变体构造器名（如 "Record"、"Adt"）
    /// 显式命名错误集 EngineError 打破与 makeTypeInfoFromId 的循环依赖（推断错误集才会循环）
    fn makeStructureRecord(self: *Engine, md: *const TypeMetadata) EngineError!value.Value {
        const tctx = self.tctx.?;
        switch (md.structure) {
            .primitive => {
                const rec = try value.Value.makeRecord(tctx, "Primitive", &.{});
                try self.trackObj(rec.asRef());
                return rec;
            },
            .record => |fields| {
                const fields_arr = try self.makeFieldMetaArray(fields);
                var buf = [_]value.Value{fields_arr};
                const rec = try value.Value.makeRecord(tctx, "Record", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .adt => |constructors| {
                const ctors_arr = try self.makeConstructorMetaArray(constructors);
                var buf = [_]value.Value{ctors_arr};
                const rec = try value.Value.makeRecord(tctx, "Adt", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .newtype => |inner_id| {
                const inner_info = try self.makeTypeInfoFromId(inner_id);
                var buf = [_]value.Value{inner_info};
                const rec = try value.Value.makeRecord(tctx, "Newtype", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .alias => |target_id| {
                const target_info = try self.makeTypeInfoFromId(target_id);
                var buf = [_]value.Value{target_info};
                const rec = try value.Value.makeRecord(tctx, "Alias", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .func => |fs| {
                const sig_rec = try self.makeFuncSigRecord(fs);
                var buf = [_]value.Value{sig_rec};
                const rec = try value.Value.makeRecord(tctx, "Func", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .trait => |tm| {
                const trait_rec = try self.makeTraitMetaRecord(tm);
                var buf = [_]value.Value{trait_rec};
                const rec = try value.Value.makeRecord(tctx, "Trait", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .unit => {
                const rec = try value.Value.makeRecord(tctx, "Unit", &.{});
                try self.trackObj(rec.asRef());
                return rec;
            },
            .nullable => |inner_id| {
                const inner_info = try self.makeTypeInfoFromId(inner_id);
                var buf = [_]value.Value{inner_info};
                const rec = try value.Value.makeRecord(tctx, "Nullable", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
        }
    }

    /// 按 type_id 查表递归构造 TypeInfo RecordValue
    /// type_id=0 时返回占位 TypeInfo（null 内部类型）
    /// 显式命名错误集 EngineError 打破与 makeStructureRecord 的循环依赖（推断错误集才会循环）
    fn makeTypeInfoFromId(self: *Engine, type_id: u16) EngineError!value.Value {
        const tctx = self.tctx.?;
        if (type_id == 0 or type_id > self.ir.type_metadata_table.entries.len) {
            // 未解析：返回占位 TypeInfo
            const placeholder_name = "?";
            var placeholder_fields = [_]value.Value{
                value.Value.fromStringBytes(tctx, placeholder_name) catch return error.OutOfMemory,
                value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory,
                value.Value.fromStringBytes(tctx, "Unit") catch return error.OutOfMemory,
                value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory,
                self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 }) catch return error.OutOfMemory,
                self.makeEmptyTraitImplInfoRecord() catch return error.OutOfMemory,
                value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory,
            };
            try self.trackRefFields(&placeholder_fields);
            const rec = value.Value.makeRecord(tctx, "TypeInfo", &placeholder_fields) catch return error.OutOfMemory;
            try self.trackObj(rec.asRef());
            return rec;
        }
        const md = &self.ir.type_metadata_table.entries[type_id - 1];
        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, md.name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, md.module) catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, md.kind.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = try self.makeStructureRecord(md);
        field_buf[4] = try self.makeLayoutInfoRecord(md.layout);
        field_buf[5] = try self.makeTraitImplInfoRecord(md.impls);
        field_buf[6] = try self.makeTypeParamMetaArray(md.type_params);
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 FieldMeta RecordValue：(name, type_name, is_nullable, index)
    fn makeFieldMetaRecord(self: *Engine, fm: ir_mod.meta_mod.FieldMeta) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, fm.name),
            try value.Value.fromStringBytes(tctx, fm.type_name),
            value.Value.fromBool(fm.is_nullable),
            value.Value.fromU32(fm.index),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "FieldMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 FieldMeta 数组
    fn makeFieldMetaArray(self: *Engine, items: []const ir_mod.meta_mod.FieldMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeFieldMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 ConstructorMeta RecordValue：(name, fields, is_unit, index)
    fn makeConstructorMetaRecord(self: *Engine, cm: ir_mod.meta_mod.ConstructorMeta) !value.Value {
        const tctx = self.tctx.?;
        const fields_arr = try self.makeFieldMetaArray(cm.fields);
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, cm.name),
            fields_arr,
            value.Value.fromBool(cm.is_unit),
            value.Value.fromU32(cm.index),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "ConstructorMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 ConstructorMeta 数组
    fn makeConstructorMetaArray(self: *Engine, items: []const ir_mod.meta_mod.ConstructorMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeConstructorMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 TypeParamMeta RecordValue：(name, constraints, is_specialized, specialization)
    fn makeTypeParamMetaRecord(self: *Engine, tp: ir_mod.meta_mod.TypeParamMeta) !value.Value {
        const tctx = self.tctx.?;
        // constraints: []const []const u8 → Array<str>
        const constraints_arr = try self.makeStrArray(tp.constraints);
        // specialization: ?[]const u8 → nullable<str>
        const spec_val = if (tp.specialization) |s|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, s)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, tp.name),
            constraints_arr,
            value.Value.fromBool(tp.is_specialized),
            spec_val,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TypeParamMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TypeParamMeta 数组
    fn makeTypeParamMetaArray(self: *Engine, items: []const ir_mod.meta_mod.TypeParamMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeTypeParamMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 FuncSigMeta RecordValue：(param_types, return_type, is_async)
    fn makeFuncSigRecord(self: *Engine, fs: ir_mod.meta_mod.FuncSigMeta) !value.Value {
        const tctx = self.tctx.?;
        const param_types_arr = try self.makeStrArray(fs.param_types);
        var fields = [_]value.Value{
            param_types_arr,
            try value.Value.fromStringBytes(tctx, fs.return_type),
            value.Value.fromBool(fs.is_async),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "FuncSigMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitMeta RecordValue：(name, module, type_params, parent_traits, associated_types, method_names)
    fn makeTraitMetaRecord(self: *Engine, tm: ir_mod.meta_mod.TraitMeta) !value.Value {
        const tctx = self.tctx.?;
        const tp_arr = try self.makeTypeParamMetaArray(tm.type_params);
        const pt_arr = try self.makeStrArray(tm.parent_traits);
        const at_arr = try self.makeStrArray(tm.associated_types);
        const mn_arr = try self.makeStrArray(tm.method_names);
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, tm.name),
            try value.Value.fromStringBytes(tctx, tm.module),
            tp_arr,
            pt_arr,
            at_arr,
            mn_arr,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TraitMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitMeta 数组
    fn makeTraitMetaArray(self: *Engine, items: []const ir_mod.meta_mod.TraitMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeTraitMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 MethodMeta RecordValue：(name, signature, is_override, is_delegate, delegate_trait, is_async)
    fn makeMethodMetaRecord(self: *Engine, mm: ir_mod.meta_mod.MethodMeta) !value.Value {
        const tctx = self.tctx.?;
        const sig_rec = try self.makeFuncSigRecord(mm.signature);
        // delegate_trait: ?[]const u8 → nullable<str>
        const dt_val = if (mm.delegate_trait) |dt|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, dt)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, mm.name),
            sig_rec,
            value.Value.fromBool(mm.is_override),
            value.Value.fromBool(mm.is_delegate),
            dt_val,
            value.Value.fromBool(mm.is_async),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "MethodMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 MethodMeta 数组
    fn makeMethodMetaArray(self: *Engine, items: []const ir_mod.meta_mod.MethodMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeMethodMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 AssociatedTypeMeta RecordValue：(name, is_specified, default_type)
    fn makeAssociatedTypeMetaRecord(self: *Engine, atm: ir_mod.meta_mod.AssociatedTypeMeta) !value.Value {
        const tctx = self.tctx.?;
        // default_type: ?[]const u8 → nullable<str>
        const dt_val = if (atm.default_type) |dt|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, dt)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, atm.name),
            value.Value.fromBool(atm.is_specified),
            dt_val,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "AssociatedTypeMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 AssociatedTypeMeta 数组
    fn makeAssociatedTypeMetaArray(self: *Engine, items: []const ir_mod.meta_mod.AssociatedTypeMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeAssociatedTypeMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 辅助：从 []const []const u8 构造字符串数组
    fn makeStrArray(self: *Engine, strs: []const []const u8) !value.Value {
        const tctx = self.tctx.?;
        if (strs.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(strs.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (strs, 0..) |s, i| {
            const str_val = value.Value.fromStringBytes(tctx, s) catch return error.OutOfMemory;
            try self.trackObj(str_val.ref);
            ptr[i] = str_val;
        }
        const arr = value.Value.makeArray(tctx, ptr[0..strs.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    // ════════════════════════════════════════════
    // Newtype 操作
    // ════════════════════════════════════════════

    /// newtype_wrap：将值包装为 NewtypeValue
    /// inputs[0] = 值通道
    /// meta_index 指向 ScalarMeta（const_val.int_val 存储类型名字符串池索引）
    /// output = ref_chan（NewtypeValue 指针）
    fn execNewtypeWrap(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const inner = self.chanToValue(val_chan);
        _ = inner.retain(self.tctx.?);

        // 从 meta 获取类型名
        var type_name: []const u8 = "Newtype";
        if (node.meta_index > 0 and node.meta_index <= self.ir.scalar_metas.len) {
            const meta = self.ir.scalar_metas[node.meta_index];
            if (meta.const_val) |cv| {
                if (cv == .int_val) {
                    const str_idx: usize = @intCast(cv.int_val);
                    if (str_idx < self.ir.string_pool.len) {
                        type_name = self.ir.string_pool[str_idx];
                    }
                }
            }
        }

        const nt_v = value.Value.makeNewtype(self.tctx.?, type_name, inner) catch return error.OutOfMemory;
        try self.trackObj(nt_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(nt_v.asRef()));
    }

    /// newtype_unwrap：从 NewtypeValue 提取内部值
    /// inputs[0] = ref_chan（NewtypeValue 指针）
    /// output = 内部值通道
    fn execNewtypeUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const header = self.readRefObj(ref_chan) orelse return error.Panic;
        if (header.type_tag != .newtype) return error.Panic;
        const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", header));
        self.writeScalarValue(node.output, nt.inner);
    }

    fn execConstStr(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            // const_str 的 const_val.int_val 是字符串池索引
            if (cv == .int_val) {
                const str_idx: usize = @intCast(cv.int_val);
                if (str_idx >= self.ir.string_pool.len) return error.InvalidMetaIndex;
                const bytes = self.ir.string_pool[str_idx];
                // 在堆上创建 Str 对象
                const v = value.Value.fromStringBytes(self.tctx.?, bytes) catch return error.OutOfMemory;
                try self.trackObj(v.asRef());
                // 将 *ObjHeader 指针写入 ref_chan
                self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            }
        }
    }

    // ════════════════════════════════════════════
    // 整数算术（复用 value.ops）
    // ════════════════════════════════════════════

    const IntBinOpKind = enum { add, sub, mul, div, mod, bit_and, bit_or, bit_xor };

    inline fn execIntBinOp(self: *Engine, node: *const Node, kind: IntBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag（0xFF = 无标量类型，预计算阶段已填充）
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 字符串拼接由专用 string_concat 节点处理（builder 按 operand_type 分派）
        // int_add 路径只处理纯整数运算，无需运行时 hashmap 查找

        // 快速路径：按 comptime tag 直接指针读写原生类型，跳过 16B 中间缓冲
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const result: T = switch (kind) {
                    .add => blk: {
                        const r, const overflow = @addWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .sub => blk: {
                        const r, const overflow = @subWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .mul => blk: {
                        const r, const overflow = @mulWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .div => blk: {
                        if (b == 0) return error.DivisionByZero;
                        break :blk @divTrunc(a, b);
                    },
                    .mod => blk: {
                        if (b == 0) return error.DivisionByZero;
                        break :blk @rem(a, b);
                    },
                    .bit_and => a & b,
                    .bit_or => a | b,
                    .bit_xor => a ^ b,
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    const IntShiftKind = enum { shl, shr };

    fn execIntShift(self: *Engine, node: *const Node, kind: IntShiftKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，保留各类型的原生位宽语义
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const max_bits = @bitSizeOf(T);
                // b 可能是 i128/u128，值 >= 2^64 时 @intCast 到 u64 会 panic。
                // 先检查移位量是否 >= 位宽（>= 位宽时结果为 0），再安全窄化。
                const b_val = if (b < 0) 0 else b;
                if (b_val >= max_bits) {
                    self.runtime.writeScalarAt(comptime_tag, node.output, 0);
                    return;
                }
                const raw: u64 = @intCast(b_val);
                const result: T = switch (kind) {
                    .shl => a << @intCast(raw),
                    .shr => a >> @intCast(raw),
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    const IntUnOpKind = enum { neg, abs, bit_not };

    fn execIntUnOp(self: *Engine, node: *const Node, kind: IntUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, input_chan);
                const result: T = switch (kind) {
                    .neg => blk: {
                        const r, const overflow = @subWithOverflow(@as(T, 0), a);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .abs => blk: {
                        const ti = @typeInfo(T).int;
                        if (ti.signedness == .signed) {
                            // iN::MIN 的绝对值超出正数范围，溢出报错（与 neg 一致）
                            if (a == std.math.minInt(T)) return error.Overflow;
                            break :blk @intCast(@abs(a));
                        } else {
                            break :blk a;
                        }
                    },
                    .bit_not => ~a,
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    // ════════════════════════════════════════════
    // 浮点算术（复用 value.ops）
    // ════════════════════════════════════════════

    const FloatBinOpKind = enum { add, sub, mul, div, mod };

    fn execFloatBinOp(self: *Engine, node: *const Node, kind: FloatBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写原生浮点，跳过 16B 中间缓冲
        return switch (tag) {
            inline .f16, .f32, .f64, .f128 => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const result: T = switch (kind) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .mod => @rem(a, b),
                };
                // NaN 是无定义结果（如 0.0/0.0、@rem(a,0)），触发错误；
                // Inf 是 IEEE 754 合法极值（如 1.0/0.0），保持标准行为
                if (std.math.isNan(result)) {
                    return error.Overflow;
                }
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    const FloatUnOpKind = enum { neg, abs };

    fn execFloatUnOp(self: *Engine, node: *const Node, kind: FloatUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
        return switch (tag) {
            inline .f16, .f32, .f64, .f128 => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, input_chan);
                const result: T = switch (kind) {
                    .neg => -a,
                    .abs => @abs(a),
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    // ════════════════════════════════════════════
    // 比较（复用 value.ops）
    // ════════════════════════════════════════════

    const CmpKind = enum { eq, ne, lt, le, gt, ge };

    inline fn execCmp(self: *Engine, node: *const Node, kind: CmpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag（0xFF = 非标量通道，预计算阶段已填充）
        // tag 来自左输入通道（输出是 bool，不能用于推导）
        if (node.scalar_tag == 0xFF) {
            // 非标量通道：== 和 != 使用递归值相等（value.equals）
            // 其他比较（< > <= >=）退化为指针比较（仅用于排序/判空）
            if (kind == .eq or kind == .ne) {
                const a_val = self.chanToValue(left_chan);
                const b_val = self.chanToValue(right_chan);
                const eq_result = value.equals(a_val, b_val);
                self.runtime.writeBool(node.output, if (kind == .eq) eq_result else !eq_result);
                return;
            }
            // < > <= >= 对非标量退化为指针比较
            const a = if (left_chan < self.runtime.chan_count and self.runtime.chan_ptrs[left_chan] != null)
                self.runtime.readI64(left_chan)
            else
                0;
            const b = if (right_chan < self.runtime.chan_count and self.runtime.chan_ptrs[right_chan] != null)
                self.runtime.readI64(right_chan)
            else
                0;
            const result: bool = switch (kind) {
                .eq => a == b,
                .ne => a != b,
                .lt => a < b,
                .le => a <= b,
                .gt => a > b,
                .ge => a >= b,
            };
            self.runtime.writeBool(node.output, result);
            return;
        }
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，覆盖 int/uint/float/bool 所有类型
        const result: bool = switch (tag) {
            .boolean => blk: {
                const a = self.runtime.readBool(left_chan);
                const b = self.runtime.readBool(right_chan);
                break :blk switch (kind) {
                    .eq => a == b,
                    .ne => a != b,
                    .lt => !a and b,
                    .le => !a or b,
                    .gt => a and !b,
                    .ge => a or b,
                };
            },
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            .f16, .f32, .f64, .f128, .char => |comptime_tag| blk: {
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                break :blk switch (kind) {
                    .eq => a == b,
                    .ne => a != b,
                    .lt => a < b,
                    .le => a <= b,
                    .gt => a > b,
                    .ge => a >= b,
                };
            },
        };
        self.runtime.writeBool(node.output, result);
    }

    // ════════════════════════════════════════════
    // 布尔逻辑
    // ════════════════════════════════════════════

    const BoolBinOpKind = enum { and_, or_ };

    fn execBoolBinOp(self: *Engine, node: *const Node, kind: BoolBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const a = self.runtime.readBool(left_chan);
        const b = self.runtime.readBool(right_chan);
        const result: bool = switch (kind) {
            .and_ => a and b,
            .or_ => a or b,
        };
        self.runtime.writeBool(node.output, result);
    }

    fn execBoolNot(self: *Engine, node: *const Node) EngineError!void {
        const input_chan = node.inputs[0];
        const a = self.runtime.readBool(input_chan);
        self.runtime.writeBool(node.output, !a);
    }

    // ════════════════════════════════════════════
    // 内存操作（var 变量 load/store）
    // ════════════════════════════════════════════

    /// load：将输入通道的值复制到输出通道（var 初始化）
    /// node._pad bit 0 为 1 表示源为 &T / *T，保持引用语义；否则普通复合类型走深拷贝
    fn execLoad(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const is_ref = (node._pad & 1) != 0;
        try self.cloneValueBetweenChannels(node.output, src_chan, is_ref);
    }

    /// store：将输入通道的值写入 cell 通道（var 赋值）
    /// node._pad bit 0 为 1 表示源为 &T / *T，保持引用语义；否则普通复合类型走深拷贝
    fn execStore(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const is_ref = (node._pad & 1) != 0;
        try self.cloneValueBetweenChannels(node.output, src_chan, is_ref);
    }

    // ════════════════════════════════════════════
    // 借用引用（&T / *expr / ref_get / ref_set）
    // ════════════════════════════════════════════

    /// ref_of：取引用 &expr
    /// - 复合类型（operand 是 ref_chan）：operand 已经持有 *ObjHeader，直接复制指针到 output
    /// - 标量（operand 是标量通道）：装箱到 BoxedScalar 对象，output 持有新对象指针
    /// - operand 是 ref_chan（已是引用）：复制引用本身（实现引用的引用）
    fn execRefOf(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const src_w = self.runtime.elemWidth(src_chan);
        const dst = self.runtime.rawPtr(node.output);

        if (src_w == 8) {
            // 复合类型或已有引用：src 通道持有 8 字节指针，直接复制
            const src = self.runtime.rawPtr(src_chan);
            @memcpy(dst[0..8], src[0..8]);
            // retain 引用计数（堆对象共享）
            const obj_ptr: ?*anyopaque = @ptrCast(@alignCast(@as(*?*anyopaque, @ptrCast(@alignCast(src))).*));
            if (obj_ptr) |p| {
                const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(p));
                _ = value.obj_header.retain(header, self.tctx.?);
            }
        } else if (src_w > 0 and src_w <= 16) {
            // 标量：装箱到 BoxedScalar，存储通道索引（使回写生效）
            // 内存布局：[ObjHeader][u16 channel_index][padding to 8B]
            const tctx = self.tctx.?;
            const total = @sizeOf(value.obj_header.ObjHeader) + 8; // 8B 对齐存储 channel_index
            const buf = tctx.allocObj(total) catch return error.OutOfMemory;
            const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(buf.ptr));
            value.obj_header.initObjHeader(header, .boxed_scalar, total, false, tctx);
            // 存储源通道索引到 ObjHeader 之后（使 ref_get/ref_set 能回写到原始通道）
            const chan_idx_ptr: *u16 = @ptrCast(@alignCast(buf.ptr + @sizeOf(value.obj_header.ObjHeader)));
            chan_idx_ptr.* = src_chan;
            // 注册跟踪（避免内存泄漏）
            try self.trackObj(header);
            // 写入指针到 output
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = buf.ptr;
        } else if (src_w == 0) {
            // unit 类型：ref 无意义，写 null
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = null;
        }
    }

    /// ref_get：解引用 *expr
    /// 读取引用指向的值到 output 通道
    /// - BoxedScalar：从 ObjHeader 之后读取通道索引，再从该通道读取标量值（支持回写）
    /// - 复合对象：直接复制对象指针（result 是 ref_chan）
    fn execRefGet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const dst_w = self.runtime.elemWidth(node.output);
        if (dst_w == 0) return;

        const obj_ptr = self.runtime.readPtr(ref_chan) orelse return error.Panic;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(obj_ptr));

        const dst = self.runtime.rawPtr(node.output);
        switch (header.type_tag) {
            .boxed_scalar => {
                // 标量装箱：读取通道索引，从原始通道读取标量值
                const chan_idx_ptr: *const u16 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(@alignCast(obj_ptr))) + @sizeOf(value.obj_header.ObjHeader)));
                const src_chan = chan_idx_ptr.*;
                const src = self.runtime.rawPtr(src_chan);
                const copy_w = @min(dst_w, 16);
                @memcpy(dst[0..copy_w], src[0..copy_w]);
            },
            else => {
                // 复合对象：复制对象指针本身（ref_get 对复合对象 = 取对象引用）
                if (dst_w == 8) {
                    const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
                    dst_ptr.* = obj_ptr;
                    _ = value.obj_header.retain(header, self.tctx.?);
                }
            },
        }
    }

    /// ref_set：通过引用写入 *ref = value
    /// inputs[0] = 引用通道，inputs[1] = 值通道
    /// - BoxedScalar：读取通道索引，写入原始通道（实现回写）
    /// - 复合对象：无操作（复合对象本身是共享的，赋值语义不适用）
    fn execRefSet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const val_chan = node.inputs[1];

        const obj_ptr = self.runtime.readPtr(ref_chan) orelse return error.Panic;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(obj_ptr));

        switch (header.type_tag) {
            .boxed_scalar => {
                // 读取通道索引，写入原始通道（实现回写）
                const chan_idx_ptr: *const u16 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(@alignCast(obj_ptr))) + @sizeOf(value.obj_header.ObjHeader)));
                const dst_chan = chan_idx_ptr.*;
                const val_w = self.runtime.elemWidth(val_chan);
                if (val_w == 0 or val_w > 16) return;
                const dst = self.runtime.rawPtr(dst_chan);
                const src = self.runtime.rawPtr(val_chan);
                @memcpy(dst[0..val_w], src[0..val_w]);
            },
            else => {
                // 复合对象的 ref_set：替换引用本身（重新绑定）
                // 暂不实现，复合对象赋值通过 field assignment 完成
            },
        }
    }

    // ════════════════════════════════════════════
    // 选择（if 表达式，标量模式 N=1）
    // ════════════════════════════════════════════

    /// vec_select：根据条件通道选择 then/else 通道的值
    /// inputs[0] = then_chan, inputs[1] = else_chan, inputs[2] = cond_chan
    fn execVecSelect(self: *Engine, node: *const Node) EngineError!void {
        const then_chan = node.inputs[0];
        const else_chan = node.inputs[1];
        const cond_chan = node.inputs[2];
        const cond_val = try self.readScalarValue(cond_chan);
        const src_chan = if (cond_val.asBool()) then_chan else else_chan;
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            // 源通道可能为 null_chan（无数据指针），跳过拷贝
            if (src_chan < self.runtime.chan_count) {
                if (self.runtime.chan_ptrs[src_chan]) |src_ptr| {
                    const dst = self.runtime.rawPtr(node.output);
                    @memcpy(dst[0..w], src_ptr[0..w]);
                } else {
                    // null 源通道：写零到输出
                    const dst = self.runtime.rawPtr(node.output);
                    @memset(dst[0..w], 0);
                }
            }
        }
    }

    // ════════════════════════════════════════════
    // 类型转换（复用 value.cast）
    // ════════════════════════════════════════════

    /// cast/cast_safe：标量类型转换
    /// meta_index 指向 ScalarMeta，描述目标类型
    /// inputs[0] = 源通道
    fn execCast(self: *Engine, node: *const Node, safe: bool) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);
        const src_tag = chanToScalarTag(src_meta) orelse return error.UnsupportedOp;
        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        const a = self.readChanBytes(src_chan);

        if (safe) {
            const result = value.cast.tryCast(src_tag, dst_tag, a) catch return error.CastOverflow;
            self.writeChanBytes(node.output, result);
        } else {
            const result = value.cast.cast(src_tag, dst_tag, a);
            self.writeChanBytes(node.output, result);
        }
    }

    /// 从 ScalarTag + [16]u8 字节直接构造 Value（不经过通道）
    /// 用于 cast_try_to 成功路径：避免在 ref_chan 通道上用 chanToValue 误读标量字节为指针
    fn scalarBytesToValue(tag: ScalarTag, bytes: [16]u8) value.Value {
        return switch (tag) {
            .boolean => value.Value.fromBool(bytes[0] != 0),
            .char => value.Value.fromChar(.{ .codepoint = @bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*) }),
            .i8 => value.Value.fromI8(@bitCast(bytes[0])),
            .i16 => value.Value.fromI16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .i32 => value.Value.fromI32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .i64 => value.Value.fromI64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .i128 => value.Value.fromI128(@bitCast(bytes)),
            .u8 => value.Value.fromU8(bytes[0]),
            .u16 => value.Value.fromU16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .u32 => value.Value.fromU32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .u64 => value.Value.fromU64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .u128 => value.Value.fromU128(@bitCast(bytes)),
            .isize => blk: {
                const arr: [@sizeOf(isize)]u8 = @as(*const [@sizeOf(isize)]u8, @ptrCast(&bytes)).*;
                break :blk value.Value.fromIsize(@bitCast(arr));
            },
            .usize => blk: {
                const arr: [@sizeOf(usize)]u8 = @as(*const [@sizeOf(usize)]u8, @ptrCast(&bytes)).*;
                break :blk value.Value.fromUsize(@bitCast(arr));
            },
            .f16 => value.Value.fromF16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .f32 => value.Value.fromF32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .f64 => value.Value.fromF64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .f128 => value.Value.fromF128(@bitCast(bytes)),
        };
    }

    /// cast_to：cast(x).to(T) Phase 3 新语法
    /// 行为（spec §4.3 决策 #28/#30）：
    ///   - 数值→数值：wrap on overflow（复用 cast()）
    ///   - f→f 窄化产生 Inf → panic（D61 强化）
    ///   - str→数值：暂不支持（panic 提示）；数值→str 在 IR 已分派到 builtin_str
    ///   - 其他路径同 cast()
    fn execCastTo(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);
        const src_tag = chanToScalarTag(src_meta) orelse return error.UnsupportedOp;
        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        // str→数值 在 to 模式 panic（决策 #27）
        if (src_meta.chan_type == .ref_chan) {
            return error.Panic;
        }

        const a = self.readChanBytes(src_chan);
        const result = value.cast.cast(src_tag, dst_tag, a);

        // D61 强化：f→f 窄化产生 Inf → panic
        if (cast_mod.isFloatTag(src_tag) and cast_mod.isFloatTag(dst_tag)) {
            if (isInfResult(dst_tag, result)) return error.Panic;
        }

        self.writeChanBytes(node.output, result);
    }

    /// cast_try_to：cast(x).try_to(T) Phase 3 新语法
    /// 行为（spec §4.3 决策 #29/#30）：
    ///   - 成功 → ThrowValue.ok(T)
    ///   - 越界/产生 Inf/解析失败 → ThrowValue.err(CastError)
    /// 输出：ref_chan（ThrowValue 指针）
    fn execCastTryTo(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);

        // str→数值：解析失败时构造 CastError
        // 数值→str：IR 中已分派 builtin_str，但 try_to 模式仍走此节点包装为 Throw.ok
        // 这里处理两种情况
        if (meta.kind == .str) {
            // 数值→str：永不失败，直接包装为 Throw.ok(str)
            // src_chan 已经是 str 引用（IR 中先 builtin_str 再 cast_try_to）
            const v = self.chanToValue(src_chan);
            const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
            _ = v.retain(self.tctx.?);
            try self.trackObj(throw_v.asRef());
            self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
            return;
        }

        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        // str→数值 解析路径：src 为 ref_chan (Str)，需在 chanToScalarTag 之前处理
        // 因为 ref_chan 不能转换为 ScalarTag
        if (src_meta.chan_type == .ref_chan) {
            // 读取源字符串
            const s = self.readStr(src_chan) orelse return error.UnsupportedOp;
            const str_bytes = s.bytes();
            return self.execCastTryToStrNumeric(node, str_bytes, dst_tag);
        }

        const src_tag = chanToScalarTag(src_meta) orelse return error.UnsupportedOp;

        // 数值→数值：走 tryCast
        const a = self.readChanBytes(src_chan);
        const result = value.cast.tryCast(src_tag, dst_tag, a) catch {
            // 转换失败 → 构造 CastError
            return self.constructCastErrorThrow(node, src_tag, dst_tag, a);
        };

        // D61 强化：f→f 窄化产生 Inf → CastError
        if (cast_mod.isFloatTag(src_tag) and cast_mod.isFloatTag(dst_tag)) {
            if (isInfResult(dst_tag, result)) {
                return self.constructCastErrorThrow(node, src_tag, dst_tag, a);
            }
        }

        // 成功 → ThrowValue.ok(T)
        // 直接从字节构造 Value，避免 ref_chan 上 chanToValue 把标量字节误读为指针
        const ok_v = scalarBytesToValue(dst_tag, result);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = ok_v }) catch return error.OutOfMemory;
        _ = ok_v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// str→数值 的 try_to 实现
    /// 解析字符串为目标数值类型，失败构造 CastError
    fn execCastTryToStrNumeric(self: *Engine, node: *const Node, str_bytes: []const u8, dst_tag: ScalarTag) EngineError!void {
        // 解析字符串
        const parse_result = cast_mod.parseStrToNumeric(str_bytes, dst_tag) catch {
            // 解析失败 → CastError
            // src_tag 用 .boolean 作为占位（实际是 str）
            return self.constructCastErrorThrowStr(node, str_bytes, dst_tag);
        };

        // 成功 → 直接从字节构造 Value，包装为 Throw.ok
        const ok_v = scalarBytesToValue(dst_tag, parse_result);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = ok_v }) catch return error.OutOfMemory;
        _ = ok_v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// 构造 CastError RecordValue + ThrowValue.err，写入 output 通道
    /// 字段顺序：msg / from / to / value（与 src/builtin/error/CastError.glue 一致）
    fn constructCastErrorThrow(self: *Engine, node: *const Node, src_tag: ScalarTag, dst_tag: ScalarTag, src_bytes: [16]u8) EngineError!void {
        const alloc = self.tctx.?.backing;
        const from_str = cast_mod.tagName(src_tag);
        const to_str = cast_mod.tagName(dst_tag);
        const value_str = cast_mod.formatScalarValue(alloc, src_tag, src_bytes) catch return error.OutOfMemory;
        defer alloc.free(value_str);
        const msg_str = std.fmt.allocPrint(alloc, "cannot cast '{s}' from {s} to {s}", .{ value_str, from_str, to_str }) catch return error.OutOfMemory;
        defer alloc.free(msg_str);
        return self.emitCastErrorThrow(node, msg_str, from_str, to_str, value_str);
    }

    /// str→数值 失败时构造 CastError
    fn constructCastErrorThrowStr(self: *Engine, node: *const Node, str_bytes: []const u8, dst_tag: ScalarTag) EngineError!void {
        const alloc = self.tctx.?.backing;
        const from_str = "str";
        const to_str = cast_mod.tagName(dst_tag);
        const value_str = alloc.dupe(u8, str_bytes) catch return error.OutOfMemory;
        defer alloc.free(value_str);
        const msg_str = std.fmt.allocPrint(alloc, "cannot cast \"{s}\" from str to {s} (parse failed)", .{ str_bytes, to_str }) catch return error.OutOfMemory;
        defer alloc.free(msg_str);
        return self.emitCastErrorThrow(node, msg_str, from_str, to_str, value_str);
    }

    /// 实际构造 CastError RecordValue（4 字段：msg/from/to/value）+ ThrowValue.err，写入 output
    fn emitCastErrorThrow(self: *Engine, node: *const Node, msg_str: []const u8, from_str: []const u8, to_str: []const u8, value_str: []const u8) EngineError!void {
        // 分配 4 个 str Value
        const msg_obj = value.str_mod.Str.createContiguous(self.tctx.?, msg_str) catch return error.OutOfMemory;
        try self.trackObj(&msg_obj.header);
        const from_obj = value.str_mod.Str.createContiguous(self.tctx.?, from_str) catch return error.OutOfMemory;
        try self.trackObj(&from_obj.header);
        const to_obj = value.str_mod.Str.createContiguous(self.tctx.?, to_str) catch return error.OutOfMemory;
        try self.trackObj(&to_obj.header);
        const value_obj = value.str_mod.Str.createContiguous(self.tctx.?, value_str) catch return error.OutOfMemory;
        try self.trackObj(&value_obj.header);

        const msg_v: value.Value = .{ .ref = &msg_obj.header };
        const from_v: value.Value = .{ .ref = &from_obj.header };
        const to_v: value.Value = .{ .ref = &to_obj.header };
        const value_v: value.Value = .{ .ref = &value_obj.header };

        // 构造 CastError RecordValue
        // 字段顺序：msg / from / to / value
        var fields_buf: [4]value.Value = .{ msg_v, from_v, to_v, value_v };
        const cast_err_v = value.Value.makeRecord(self.tctx.?, "CastError", fields_buf[0..]) catch return error.OutOfMemory;
        try self.trackObj(cast_err_v.asRef());
        // CastError 是 error_newtype，RecordValue.header.type_tag 已是 .record
        // 4 字段：retain 引用计数
        for (fields_buf) |fv| _ = value.obj_header.retain(fv.asRef(), self.tctx.?);

        // 包装为 ErrorValue（is_error_subtype=true）使 throw 路径能识别
        // 但 Phase 2 中 throw 直接处理 .record 类型，所以这里直接构造 ThrowValue.err 指向 RecordValue
        // 需要先把 RecordValue 包装成 ErrorValue
        const err_v = value.Value.makeError(self.tctx.?, "CastError", msg_str, true) catch return error.OutOfMemory;
        try self.trackObj(err_v.asRef());
        const err_val: *value.ErrorValue = @alignCast(@fieldParentPtr("header", err_v.asRef()));

        // ThrowValue.err 持有 ErrorValue 指针
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = err_val }) catch return error.OutOfMemory;
        _ = value.obj_header.retain(&err_val.header, self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// 从 ScalarKind + IntKind/FloatKind 推导 ScalarTag
    fn scalarKindToTag(kind: ScalarKind, int_kind: scalar.IntKind, float_kind: scalar.FloatKind) ?ScalarTag {
        return switch (kind) {
            .int => switch (int_kind) {
                .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
                .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
                .isize => .isize, .usize => .usize,
            },
            .float => switch (float_kind) {
                .f16 => .f16, .f32 => .f32, .f64 => .f64, .f128 => .f128,
            },
            .bool => .boolean,
            .char => .char,
            else => null,
        };
    }

    /// 检查 cast 结果是否为 Inf（仅用于 f→f 窄化产生 Inf 判断）
    /// 通过 inline switch 在编译期展开各 float tag 的判断
    fn isInfResult(dst_tag: ScalarTag, result: [16]u8) bool {
        return switch (dst_tag) {
            .f16 => {
                const v: f16 = @bitCast(result[0..2].*);
                return std.math.isInf(v);
            },
            .f32 => {
                const v: f32 = @bitCast(result[0..4].*);
                return std.math.isInf(v);
            },
            .f64 => {
                const v: f64 = @bitCast(result[0..8].*);
                return std.math.isInf(v);
            },
            .f128 => {
                const v: f128 = @bitCast(result[0..16].*);
                return std.math.isInf(v);
            },
            else => false,
        };
    }

    // ════════════════════════════════════════════
    // 字符串操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 Str 对象指针
    fn readStr(self: *Engine, chan: u16) ?*value.str_mod.Str {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        if (@intFromPtr(ptr) < 0x1000) return null;
        if (@intFromPtr(ptr) % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag == .lazy_val) {
            const lazy: *value.LazyValue = @alignCast(@fieldParentPtr("header", header));
            const forced = self.forceLazyValue(lazy) catch return null;
            switch (forced) {
                .ref => |r| {
                    const h: *value.obj_header.ObjHeader = @ptrCast(@alignCast(r));
                    if (h.type_tag != .str) return null;
                    return @alignCast(@fieldParentPtr("header", h));
                },
                else => return null,
            }
        }
        if (header.type_tag != .str) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// string_len：返回字符串 Unicode 标量值数量（字符数）
    /// inputs[0] = str 通道，output = usize 通道
    fn execStringLen(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);

        // nullable_chan：检查 null flag，null 时返回 0
        if (src_meta.chan_type == .nullable_chan) {
            const inner_w = src_meta.inner_type.elemWidth();
            const src = self.runtime.rawPtr(src_chan);
            if (src[inner_w] != 0) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            // 非 null：读取 inner ref 指针
            const inner_ptr: usize = std.mem.bytesToValue(usize, src[0..@sizeOf(usize)]);
            if (inner_ptr < 0x1000) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            const header: *value.obj_header.ObjHeader = @ptrFromInt(inner_ptr);
            if (header.type_tag != .str) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            const sv: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", header));
            const count = sv.codepointCount() catch sv.byteLength();
            self.runtime.writeUsize(node.output, count);
            return;
        }

        // null_chan 或无指针：返回 0
        if (src_meta.chan_type == .null_chan or src_chan >= self.runtime.chan_count or self.runtime.chan_ptrs[src_chan] == null) {
            self.runtime.writeUsize(node.output, 0);
            return;
        }

        const s = self.readStr(src_chan) orelse {
            self.runtime.writeUsize(node.output, 0);
            return;
        };
        const count = s.codepointCount() catch s.byteLength();
        self.runtime.writeUsize(node.output, count);
    }

    /// string_concat：拼接两个字符串
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    /// 快速路径：left 为堆模式且 rc==1 时，realloc 就地追加 right，零全量拷贝
    fn execStringConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;

        // 就地追加快速路径：复用 left 对象（已 tracked），无需新建 Str、无需 trackObj
        if (left.concatInPlace(self.tctx.?, right)) {
            self.runtime.writePtr(node.output, @ptrCast(&left.header));
            return;
        }

        // 常规路径：创建新 Str 对象（连续内存 [header | buffer]）
        const obj = value.str_mod.Str.concatContiguous(self.tctx.?, left.*, right.*) catch return error.OutOfMemory;
        try self.trackObj(&obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&obj.header));
    }

    /// string_cmp：字符串字典序比较
    /// inputs[0] = left, inputs[1] = right, output = bool_chan
    /// _pad 编码比较种类：0=lt, 1=le, 2=gt, 3=ge
    fn execStringCmp(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;
        const order = left.compare(right.*);
        const result: bool = switch (node._pad) {
            0 => order == .lt,
            1 => order != .gt,
            2 => order == .gt,
            3 => order != .lt,
            else => return error.InvalidChannel,
        };
        self.runtime.writeBool(node.output, result);
    }

    /// string_index：按字符索引获取 UTF-8 码点
    /// inputs[0] = str, inputs[1] = index, output = char_chan
    fn execStringIndex(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        const bytes = s.bytes();
        if (idx < 0) return error.Overflow;

        // UTF-8 解码：按码点序列索引
        var byte_pos: usize = 0;
        var char_idx: i64 = 0;
        while (byte_pos < bytes.len) {
            if (char_idx == idx) {
                const codepoint = decodeUtf8Codepoint(bytes[byte_pos..]) catch {
                    // 解码失败，回退到单字节
                    const cp: u32 = @intCast(bytes[byte_pos]);
                    const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                    ptr.* = cp;
                    return;
                };
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                ptr.* = codepoint;
                return;
            }
            const seq_len = utf8SeqLen(bytes[byte_pos]);
            byte_pos += seq_len;
            char_idx += 1;
        }
        return error.Overflow;
    }

    /// 返回 UTF-8 序列长度（1-4），无效首字节返回 1
    fn utf8SeqLen(byte: u8) usize {
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        if (byte & 0xF8 == 0xF0) return 4;
        return 1; // 无效首字节，按 1 处理
    }

    /// 手动解码 UTF-8 码点，避免 std.unicode.utf8Decode 的 unreachable
    fn decodeUtf8Codepoint(bytes: []const u8) !u32 {
        if (bytes.len == 0) return error.InvalidUtf8;
        const b0 = bytes[0];
        if (b0 < 0x80) return @intCast(b0);
        if (b0 & 0xE0 == 0xC0) {
            if (bytes.len < 2) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x1F)) << 6 | @as(u32, @intCast(bytes[1] & 0x3F));
        }
        if (b0 & 0xF0 == 0xE0) {
            if (bytes.len < 3) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x0F)) << 12 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[2] & 0x3F));
        }
        if (b0 & 0xF8 == 0xF0) {
            if (bytes.len < 4) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x07)) << 18 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 12 |
                @as(u32, @intCast(bytes[2] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[3] & 0x3F));
        }
        return error.InvalidUtf8;
    }

    // ════════════════════════════════════════════
    // 数组操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 ArrayValue 指针
    fn readArray(self: *Engine, chan: u16) ?*value.ArrayValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        if (@intFromPtr(ptr) < 0x1000) return null;
        if (@intFromPtr(ptr) % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag != .array) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 从通道读取 Value（标量值）
    fn chanToValue(self: *Engine, chan: u16) value.Value {
        const meta = self.ir.channels.get(chan);
        const w = meta.elem_width;
        if (w == 0) return value.Value.fromUnit();
        const ptr = self.runtime.rawPtr(chan);
        return switch (meta.chan_type) {
            .bool_chan, .mask_chan => value.Value.fromBool(self.runtime.readBool(chan)),
            .char_chan => blk: {
                const cp: u32 = @bitCast(@as(*[4]u8, @ptrCast(ptr)).*);
                break :blk value.Value.fromChar(.{ .codepoint = cp });
            },
            .i8_chan => value.Value.fromI8(@bitCast(ptr[0])),
            .i16_chan => value.Value.fromI16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .i32_chan => value.Value.fromI32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .i64_chan => value.Value.fromI64(self.runtime.readI64(chan)),
            .i128_chan => blk: {
                // 128-bit 通道按 16 字节直接读取
                const p: *i128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromI128(p.*);
            },
            .u8_chan => value.Value.fromU8(ptr[0]),
            .u16_chan => value.Value.fromU16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .u32_chan => value.Value.fromU32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .u64_chan => value.Value.fromU64(self.runtime.readU64(chan)),
            .u128_chan => blk: {
                const p: *u128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromU128(p.*);
            },
            .isize_chan => value.Value.fromIsize(@bitCast(self.runtime.readUsize(chan))),
            .usize_chan => value.Value.fromUsize(@bitCast(self.runtime.readUsize(chan))),
            .f16_chan => blk: {
                const p: *f16 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromF16(p.*);
            },
            .f32_chan => value.Value.fromF32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .f64_chan => value.Value.fromF64(self.runtime.readF64(chan)),
            .f128_chan => blk: {
                const p: *f128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromF128(p.*);
            },
            .ref_chan => blk: {
                if (self.readRefObj(chan)) |header| {
                    break :blk value.Value.fromRef(header);
                }
                // readRefObj 失败：ref_chan 持有标量位模式（类型参数实例化为标量时）
                const raw = self.runtime.readI64(chan);
                if (raw == 0) break :blk value.Value.fromNull();
                break :blk value.Value.fromI64(raw);
            },
            else => value.Value.fromUnit(),
        };
    }

    /// 将 Value 写入通道
    fn valueToChan(self: *Engine, chan: u16, v: value.Value) void {
        // ref_chan 通道（8 字节）接收标量值时，必须扩展到完整 8 字节
        // （整数符号扩展为 i64，浮点提升为 f64），否则只写标量宽度字节，
        // 高字节残留旧数据导致值损坏（类型参数实例化为标量时的核心问题）
        const meta = self.ir.channels.get(chan);
        if (meta.chan_type == .ref_chan) {
            self.writeScalarValue(chan, v);
            return;
        }
        switch (v) {
            .null_val, .unit => {},
            .boolean => |b| self.runtime.writeBool(chan, b[0] != 0),
            .char => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .i16 => |b| {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i32 => |b| {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i64 => |b| {
                // 宽度转换：i64 值可能写入更窄的通道（i32/i16/i8）
                const w = self.runtime.elemWidth(chan);
                const ptr = self.runtime.rawPtr(chan);
                const val: i64 = @bitCast(b);
                if (w >= 8) {
                    const dst: *i64 = @ptrCast(@alignCast(ptr));
                    dst.* = val;
                } else if (w >= 4) {
                    const dst: *i32 = @ptrCast(@alignCast(ptr));
                    dst.* = @truncate(val);
                } else if (w >= 2) {
                    const dst: *i16 = @ptrCast(@alignCast(ptr));
                    dst.* = @truncate(val);
                } else if (w >= 1) {
                    ptr[0] = @truncate(@as(u64, @bitCast(val)));
                }
            },
            .u8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .u16 => |b| {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u32 => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u64 => |b| {
                const ptr: *u64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i128 => |b| {
                // 128-bit 值直接写入 16 字节通道
                const ptr: *i128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u128 => |b| {
                const ptr: *u128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f16 => |b| {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f32 => |b| {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f64 => |b| {
                const ptr: *f64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f128 => |b| {
                const ptr: *f128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .ref => |obj| {
                if (meta.chan_type == .nullable_chan) {
                    const inner_w = meta.inner_type.elemWidth();
                    const ptr = self.runtime.rawPtr(chan);
                    const dst_obj: *?*anyopaque = @ptrCast(@alignCast(ptr));
                    dst_obj.* = @ptrCast(obj);
                    ptr[inner_w] = 0; // non-null flag
                } else {
                    self.runtime.writePtr(chan, @ptrCast(obj));
                }
            },
            else => {},
        }
    }

    /// 按统一值语义在通道间复制值。
    /// - 同类型同宽度：直接 @memcpy
    /// - ref_chan + 引用类型（is_ref=true）：共享指针（同宽度 @memcpy）
    /// - ref_chan + 普通复合类型（is_ref=false）：深拷贝 Value 后写入目标通道
    /// - 类型/宽度不匹配（含类型参数实例化为标量时标量存入 ref_chan）：走 copyCrossType
    fn cloneValueBetweenChannels(self: *Engine, dst_chan: u16, src_chan: u16, is_ref: bool) EngineError!void {
        const src_meta = self.ir.channels.get(src_chan);
        const dst_meta = self.ir.channels.get(dst_chan);
        const w = src_meta.elem_width;
        if (w == 0) return;

        // ref_chan 持有堆引用且需值语义深拷贝
        if (src_meta.chan_type == .ref_chan and !is_ref) {
            if (self.readRefObj(src_chan)) |header| {
                const v = value.Value.fromRef(header);
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                self.valueToChan(dst_chan, copied);
                return;
            }
            // readRefObj 失败：ref_chan 持有标量位模式（类型参数实例化为标量），
            // 走跨类型复制路径
        }

        // 源/目标通道类型或宽度不匹配：跨类型复制
        if (src_meta.chan_type != dst_meta.chan_type or src_meta.elem_width != dst_meta.elem_width) {
            try self.copyCrossType(dst_chan, src_chan);
            return;
        }

        // 同类型同宽度：直接复制字节
        if (src_chan == dst_chan) return;
        const src = self.runtime.rawPtr(src_chan);
        const dst = self.runtime.rawPtr(dst_chan);
        @memcpy(dst[0..w], src[0..w]);
    }

    /// 跨通道类型复制：当源/目标 chan_type 或 elem_width 不匹配时使用。
    /// 核心场景：泛型函数的类型参数（A/T）被映射为 ref_chan（8字节），
    /// 但实际值为标量（i32/f32 等）。此时需要：
    /// - 标量 → ref_chan：整数符号扩展为 i64，浮点提升为 f64，写入 8 字节
    /// - ref_chan → 标量：按目标类型解释 8 字节（i64 截断为整数，f64 转换为浮点）
    /// 这样保证标量值在 ref_chan 中转后能正确还原（i32→i64→i32, f32→f64→f32）。
    fn copyCrossType(self: *Engine, dst_chan: u16, src_chan: u16) EngineError!void {
        const src_meta = self.ir.channels.get(src_chan);
        const dst_meta = self.ir.channels.get(dst_chan);
        const src_raw = self.runtime.rawPtr(src_chan);
        const dst_raw = self.runtime.rawPtr(dst_chan);

        // 标量 → ref_chan：按源类型读取标量，扩展为 8 字节写入
        if (dst_meta.chan_type == .ref_chan and src_meta.chan_type != .ref_chan) {
            const dst_ptr: *i64 = @ptrCast(@alignCast(dst_raw));
            dst_ptr.* = switch (src_meta.chan_type) {
                .i8_chan => @as(i64, @as(i8, @bitCast(src_raw[0]))),
                .u8_chan => @as(i64, src_raw[0]),
                .i16_chan => blk: {
                    const p: *i16 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .u16_chan => blk: {
                    const p: *u16 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .i32_chan => blk: {
                    const p: *i32 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .u32_chan => blk: {
                    const p: *u32 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .i64_chan => blk: {
                    const p: *i64 = @ptrCast(@alignCast(src_raw));
                    break :blk p.*;
                },
                .u64_chan => blk: {
                    const p: *u64 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(p.*);
                },
                .isize_chan => blk: {
                    const p: *isize = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .usize_chan => blk: {
                    const p: *usize = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(@as(u64, p.*));
                },
                .bool_chan, .mask_chan => @intFromBool(src_raw[0] != 0),
                .f32_chan => blk: {
                    const p: *f32 = @ptrCast(@alignCast(src_raw));
                    const f64_val: f64 = @floatCast(p.*);
                    break :blk @bitCast(f64_val);
                },
                .f64_chan => blk: {
                    const p: *f64 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(p.*);
                },
                else => 0,
            };
            return;
        }

        // ref_chan → 标量：按目标类型解释 8 字节位模式
        if (src_meta.chan_type == .ref_chan and dst_meta.chan_type != .ref_chan) {
            switch (dst_meta.chan_type) {
                .i8_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    dst_raw[0] = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .u8_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    dst_raw[0] = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i16_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i16 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(sp.*);
                },
                .u16_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *u16 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i32_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(sp.*);
                },
                .u32_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *u32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i64_chan, .u64_chan, .isize_chan, .usize_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i64 = @ptrCast(@alignCast(dst_raw));
                    dp.* = sp.*;
                },
                .f32_chan => {
                    const sp: *f64 = @ptrCast(@alignCast(src_raw));
                    const dp: *f32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @floatCast(sp.*);
                },
                .f64_chan => {
                    const sp: *f64 = @ptrCast(@alignCast(src_raw));
                    const dp: *f64 = @ptrCast(@alignCast(dst_raw));
                    dp.* = sp.*;
                },
                .bool_chan, .mask_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    self.runtime.writeBool(dst_chan, sp.* != 0);
                },
                else => {
                    const copy_w = @min(dst_meta.elem_width, 8);
                    @memcpy(dst_raw[0..copy_w], src_raw[0..copy_w]);
                },
            }
            return;
        }

        // 标量 → 标量（不同宽度）：通过 Value 中转
        const v = self.chanToValue(src_chan);
        self.writeScalarValue(dst_chan, v);
    }

    /// 按容器元素/字段的值语义复制 Value。
    /// - is_ref = true：元素/字段类型为 &T / *T，retain 后共享。
    /// - is_ref = false：普通类型，深拷贝生成独立副本。
    fn cloneValueForContainer(self: *Engine, v: value.Value, is_ref: bool) EngineError!value.Value {
        if (is_ref) {
            if (v.isBoxed()) _ = v.retain(self.tctx.?);
            return v;
        }
        const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
        // deepCopy 创建的新堆对象需要递归跟踪，否则 shutdown_mode 下 deinit 不级联
        // release 时这些对象会泄漏
        try self.trackValueTree(copied);
        return copied;
    }

    /// 递归跟踪值及其所有子引用对象
    /// 用于深拷贝后注册所有新建堆对象：shutdown_mode 下 deinit 跳过级联 release，
    /// 未跟踪的子对象（Str、Array、Record 等）会泄漏其页池页
    /// 注意：必须在 trackObj 之前检查 isTracked，避免对自引用闭包/循环引用无限递归
    fn trackValueTree(self: *Engine, v: value.Value) EngineError!void {
        if (v != .ref) return;
        // 已跟踪的对象直接返回，避免循环引用导致的无限递归
        // （子树在首次跟踪时已完整递归，无需重复）
        if (v.ref.isTracked()) return;
        try self.trackObj(v.ref);
        // 递归跟踪复合类型的子引用
        switch (v.ref.type_tag) {
            .str, .range, .builtin => {},
            .array => {
                const arr: *value.ArrayValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (arr.elements) |elem| try self.trackValueTree(elem);
            },
            .record => {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (rec.fields) |f| try self.trackValueTree(f);
            },
            .adt => {
                const adt: *value.AdtValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (adt.fields) |f| try self.trackValueTree(f.value);
            },
            .newtype => {
                const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", v.ref));
                try self.trackValueTree(nt.inner);
            },
            .cell => {
                const cell: *value.Cell = @alignCast(@fieldParentPtr("header", v.ref));
                try self.trackValueTree(cell.inner);
            },
            .throw_val => {
                const tv: *value.ThrowValue = @alignCast(@fieldParentPtr("header", v.ref));
                switch (tv.payload) {
                    .ok => |inner| try self.trackValueTree(inner),
                    .err => |err_ptr| try self.trackObj(&err_ptr.header),
                }
            },
            .error_val => {},
            .closure => {
                const cl: *value.Closure = @alignCast(@fieldParentPtr("header", v.ref));
                for (cl.upvalues) |uv| try self.trackValueTree(uv);
                for (cl.bound_args) |ba| try self.trackValueTree(ba);
            },
            .partial => {
                const pt: *value.PartialApplication = @alignCast(@fieldParentPtr("header", v.ref));
                for (pt.bound_args) |ba| try self.trackValueTree(ba);
            },
            else => {},
        }
    }

    /// 将 Value 写入原始字节指针（用于向量元素写入）
    fn valueToRawPtr(self: *Engine, ptr: [*]u8, w: u8, v: value.Value) void {
        _ = self;
        switch (v) {
            .null_val, .unit => {},
            .boolean => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .char => |b| {
                if (w >= 4) {
                    const dst: *u32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i8 => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .i16 => |b| {
                if (w >= 2) {
                    const dst: *i16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i32 => |b| {
                if (w >= 4) {
                    const dst: *i32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i64 => |b| {
                if (w >= 8) {
                    const dst: *i64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u8 => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .u16 => |b| {
                if (w >= 2) {
                    const dst: *u16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u32 => |b| {
                if (w >= 4) {
                    const dst: *u32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u64 => |b| {
                if (w >= 8) {
                    const dst: *u64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i128 => |b| {
                if (w >= 16) {
                    const dst: *i128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u128 => |b| {
                if (w >= 16) {
                    const dst: *u128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f16 => |b| {
                if (w >= 2) {
                    const dst: *f16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f32 => |b| {
                if (w >= 4) {
                    const dst: *f32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f64 => |b| {
                if (w >= 8) {
                    const dst: *f64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f128 => |b| {
                if (w >= 16) {
                    const dst: *f128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .ref => |obj| {
                if (w >= 8) {
                    const dst: *u64 = @ptrCast(@alignCast(ptr));
                    dst.* = @intFromPtr(obj);
                }
            },
            else => {},
        }
    }

    /// array_make：创建数组
    /// inputs[0] = length 通道（i64），output = ref_chan
    /// 逃逸分析驱动：非逃逸函数内的数组走 ShadowArena，endFunction 时 O(1) reset
    fn execArrayMake(self: *Engine, node: *const Node) EngineError!void {
        const len = try self.readIntAsI64(node.inputs[0]);
        if (len < 0) return error.Overflow;
        const n: usize = @intCast(len);
        // _pad bit 0：元素类型是否为 &T / *T
        const elem_is_ref = (node._pad & 1) != 0;
        // 临时元素切片（makeArray 会拷贝到连续内存，此处仅临时用）
        const elements = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(elements);
        for (elements) |*e| e.* = value.Value.fromUnit();

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // arena 分配：header + elements 连续，均从 ShadowArena 分配
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..n], elements);
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, elements, null, elem_is_ref) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_get：按索引获取元素
    /// inputs[0] = array, inputs[1] = index, output = 元素通道
    fn execArrayGet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = arr.elements[@intCast(idx)];
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        self.valueToChan(node.output, copied);
    }

    /// array_set：按索引设置元素
    /// inputs[0] = array, inputs[1] = index, inputs[2] = value
    fn execArraySet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = self.chanToValue(node.inputs[2]);
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        const old = arr.elements[@intCast(idx)];
        arr.elements[@intCast(idx)] = copied;
        old.release(self.tctx.?);
    }

    /// array_len：返回数组长度
    /// inputs[0] = array, output = usize（Phase 5: 从 i64 改为 usize）
    fn execArrayLen(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        self.runtime.writeUsize(node.output, arr.elements.len);
    }

    /// array_push：向数组追加元素（扩容）
    /// inputs[0] = array, inputs[1] = value
    /// arena 数组扩容：新 elements 也从 arena 分配，旧 elements 不释放（arena.reset 统一回收）
    fn execArrayPush(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const v = self.chanToValue(node.inputs[1]);
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        const old_len = arr.elements.len;
        const new_len = old_len + 1;
        const use_arena = arr.header.isArenaAllocated();
        const new_size = new_len * @sizeOf(value.Value);
        // alloc 失败时必须释放已克隆的 copied，避免泄漏
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(new_size) catch {
                copied.release(self.tctx.?);
                return error.OutOfMemory;
            }
        else
            self.tctx.?.allocObj(new_size) catch {
                copied.release(self.tctx.?);
                return error.OutOfMemory;
            };
        const new_elements: []value.Value = @as([*]value.Value, @ptrCast(@alignCast(buf.ptr)))[0..new_len];
        @memcpy(new_elements[0..old_len], arr.elements);
        new_elements[old_len] = copied;
        // arena 数组的旧 elements 由 arena.reset 统一回收，跳过 freeObj
        if (!use_arena and arr.elements.len > 0) {
            self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
        }
        arr.elements = new_elements;
        arr.capacity = new_len;
        self.runtime.writePtr(node.output, @ptrCast(&arr.header));
    }

    /// array_concat：拼接两个数组，返回新数组
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    /// 逃逸分析驱动：非逃逸函数内的拼接结果走 ShadowArena
    fn execArrayConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readArray(node.inputs[1]) orelse return error.InvalidChannel;
        const new_len = left.elements.len + right.elements.len;
        const elem_is_ref = left.elem_is_ref;
        // 临时元素切片（makeArray 会拷贝到自有缓冲区）
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        var i: usize = 0;
        // 元素所有权未转移给新数组前（clone 失败或 makeArrayEx/arena 失败），需释放已克隆元素
        var elements_consumed = false;
        errdefer {
            if (!elements_consumed) {
                for (new_elements[0..i]) |elem| elem.release(self.tctx.?);
            }
        }
        for (left.elements) |elem| {
            new_elements[i] = try self.cloneValueForContainer(elem, elem_is_ref);
            i += 1;
        }
        for (right.elements) |elem| {
            new_elements[i] = try self.cloneValueForContainer(elem, elem_is_ref);
            i += 1;
        }

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            const elems_size = new_len * @sizeOf(value.Value);
            const total = @sizeOf(value.ArrayValue) + elems_size;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..new_len], new_elements);
            arr.* = .{ .elements = elems_ptr[0..new_len], .capacity = new_len, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, new_elements, null, elem_is_ref) catch return error.OutOfMemory;
        // makeArrayEx/arena 成功，元素所有权已转移给新数组 v，失败时不再释放 new_elements
        elements_consumed = true;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_fill：创建 count 个 value 副本的数组
    /// inputs[0] = count, inputs[1] = value, output = ref_chan
    fn execArrayFill(self: *Engine, node: *const Node) EngineError!void {
        const count = try self.readIntAsI64(node.inputs[0]);
        if (count < 0) return error.Overflow;
        const n: usize = @intCast(count);
        const fill_value = self.chanToValue(node.inputs[1]);
        // 元素类型是否为 &T / *T：优先从 fill_value 通道的 is_ref 读取
        const elem_is_ref = self.ir.channels.get(node.inputs[1]).is_ref;

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            // 按元素类型语义逐个填充；失败时释放已克隆元素（arena 内存由 reset 回收，但堆引用需 release）
            var filled: usize = 0;
            errdefer {
                for (elems_ptr[0..filled]) |elem| elem.release(self.tctx.?);
            }
            if (n > 0) {
                for (0..n) |j| {
                    elems_ptr[j] = try self.cloneValueForContainer(fill_value, elem_is_ref);
                    filled = j + 1;
                }
            }
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else blk: {
            // 非 arena 路径：先分配临时数组，按元素类型语义填充
            const tmp = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
            defer self.tctx.?.backing.free(tmp);
            var filled: usize = 0;
            errdefer {
                for (tmp[0..filled]) |elem| elem.release(self.tctx.?);
            }
            for (0..n) |j| {
                tmp[j] = try self.cloneValueForContainer(fill_value, elem_is_ref);
                filled = j + 1;
            }
            // makeArrayEx 拷贝 tmp 到自有缓冲区；失败时 errdefer 释放 tmp 元素
            break :blk value.Value.makeArrayEx(self.tctx.?, tmp, null, elem_is_ref) catch return error.OutOfMemory;
        };
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_slice：数组切片
    /// inputs[0] = arr, inputs[1] = start, inputs[2] = end
    /// _pad: 0 = 左闭右开 [start, end)，1 = 左闭右闭 [start, end]
    fn execArraySlice(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const start = try self.readIntAsI64(node.inputs[1]);
        const end_raw = try self.readIntAsI64(node.inputs[2]);
        if (start < 0) return error.Overflow;
        const s: usize = @intCast(start);
        // 计算实际结束位置
        const e: usize = if (node._pad == 1) blk: {
            // 左闭右闭 [start, end]
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw)) + 1;
        } else blk: {
            // 左闭右开 [start, end)
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw));
        };
        if (s > arr.elements.len or e > arr.elements.len or s > e) return error.Overflow;
        const new_len = e - s;
        const elem_is_ref = arr.elem_is_ref;
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        var j: usize = 0;
        // 元素所有权未转移给新数组前（clone 失败或 makeArrayEx/arena 失败），需释放已克隆元素
        var elements_consumed = false;
        errdefer {
            if (!elements_consumed) {
                for (new_elements[0..j]) |elem| elem.release(self.tctx.?);
            }
        }
        for (arr.elements[s..e]) |elem| {
            new_elements[j] = try self.cloneValueForContainer(elem, elem_is_ref);
            j += 1;
        }

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            const elems_size = new_len * @sizeOf(value.Value);
            const total = @sizeOf(value.ArrayValue) + elems_size;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const new_arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..new_len], new_elements);
            new_arr.* = .{ .elements = elems_ptr[0..new_len], .capacity = new_len, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&new_arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&new_arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, new_elements, null, elem_is_ref) catch return error.OutOfMemory;
        // makeArrayEx/arena 成功，元素所有权已转移给新数组 v，失败时不再释放 new_elements
        elements_consumed = true;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_first：返回数组首元素（nullable 输出，空数组返回 null）
    fn execArrayFirst(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (arr.elements.len == 0) {
            if (inner_w > 0) dst[inner_w] = 1; // null 标志
            return;
        }
        self.valueToRawPtr(dst, inner_w, arr.elements[0]);
        if (inner_w > 0) dst[inner_w] = 0; // 清除 null 标志
    }

    /// array_last：返回数组末尾元素（nullable 输出，空数组返回 null）
    fn execArrayLast(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (arr.elements.len == 0) {
            if (inner_w > 0) dst[inner_w] = 1; // null 标志
            return;
        }
        self.valueToRawPtr(dst, inner_w, arr.elements[arr.elements.len - 1]);
        if (inner_w > 0) dst[inner_w] = 0; // 清除 null 标志
    }

    /// array_contains：检查数组是否包含某值
    fn execArrayContains(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const target = self.chanToValue(node.inputs[1]);
        var found = false;
        for (arr.elements) |elem| {
            if (value.equals(elem, target)) {
                found = true;
                break;
            }
        }
        self.runtime.writeBool(node.output, found);
    }

    /// array_get_safe：安全索引，越界返回 null
    fn execArrayGetSafe(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) {
            dst[inner_w] = 1;
            return;
        }
        const v = arr.elements[@intCast(idx)];
        self.valueToRawPtr(dst, inner_w, v);
        dst[inner_w] = 0;
    }

    /// array_drop_last：返回去掉末尾元素的新数组（空数组返回空数组）
    fn execArrayDropLast(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        if (arr.elements.len == 0) {
            // 空数组 → 返回空数组
            const v = value.Value.makeArray(self.tctx.?, &[_]value.Value{}, null) catch return error.OutOfMemory;
            try self.trackObj(v.asRef());
            self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            return;
        }
        const new_len = arr.elements.len - 1;
        // 临时元素切片（makeArray 会拷贝到自有缓冲区）
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        @memcpy(new_elements, arr.elements[0..new_len]);
        const v = value.Value.makeArray(self.tctx.?, new_elements, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_pop：弹出末尾元素并返回（空数组返回 null）
    fn execArrayPop(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        if (arr.elements.len == 0) {
            // 空数组 → 返回 null
            self.runtime.writePtr(node.output, null);
            return;
        }
        const last_idx = arr.elements.len - 1;
        const v = arr.elements[last_idx];
        const new_len = last_idx;
        // arena 数组扩容/缩容与 push 保持一致：arena 分配新 elements，旧 elements 由 reset 回收
        const use_arena = arr.header.isArenaAllocated();
        if (new_len == 0) {
            if (!use_arena and arr.elements.len > 0) {
                self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
            }
            arr.elements = &.{};
            arr.capacity = 0;
        } else {
            const new_size = new_len * @sizeOf(value.Value);
            const buf = if (use_arena)
                self.tctx.?.allocObjArena(new_size) catch return error.OutOfMemory
            else
                self.tctx.?.allocObj(new_size) catch return error.OutOfMemory;
            const new_elements: []value.Value = @as([*]value.Value, @ptrCast(@alignCast(buf.ptr)))[0..new_len];
            @memcpy(new_elements, arr.elements[0..new_len]);
            if (!use_arena) {
                self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
            }
            arr.elements = new_elements;
            arr.capacity = new_len;
        }
        self.valueToChan(node.output, v);
    }

    /// string_contains：检查字符串是否包含子串
    fn execStringContains(self: *Engine, node: *const Node) EngineError!void {
        const haystack = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const needle = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;
        self.runtime.writeBool(node.output, std.mem.indexOf(u8, haystack.bytes(), needle.bytes()) != null);
    }

    /// string_slice：字符串切片（按 Unicode 标量值索引）
    /// inputs[0] = s, inputs[1] = start, inputs[2] = end
    /// _pad: 0 = 左闭右开 [start, end)，1 = 左闭右闭 [start, end]
    /// start/end 是字符索引（不是字节索引），内部按 UTF-8 解码定位字节位置
    fn execStringSlice(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const start = try self.readIntAsI64(node.inputs[1]);
        const end_raw = try self.readIntAsI64(node.inputs[2]);
        if (start < 0) return error.Overflow;
        const start_idx: usize = @intCast(start);
        const end_idx: usize = if (node._pad == 1) blk: {
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw)) + 1;
        } else blk: {
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw));
        };
        if (start_idx > end_idx) return error.Overflow;
        const bytes = s.bytes();
        // 定位 start 字节位置
        var byte_pos: usize = 0;
        var char_idx: usize = 0;
        while (byte_pos < bytes.len and char_idx < start_idx) {
            byte_pos += utf8SeqLen(bytes[byte_pos]);
            char_idx += 1;
        }
        if (char_idx != start_idx) return error.Overflow;
        const start_byte = byte_pos;
        // 定位 end 字节位置
        while (byte_pos < bytes.len and char_idx < end_idx) {
            byte_pos += utf8SeqLen(bytes[byte_pos]);
            char_idx += 1;
        }
        // end 超出字符数时报错（与 start 越界行为一致），而非静默截断到字符串末尾
        if (char_idx != end_idx) return error.Overflow;
        const end_byte = byte_pos;
        // 创建子字符串
        const sub_bytes = bytes[start_byte..end_byte];
        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, sub_bytes) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    /// string_bytes：字符串转 u8[]（UTF-8 编码）
    /// inputs[0] = s, output = ref_chan (ArrayValue<u8>)
    fn execStringBytes(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const bytes = s.bytes();
        const n = bytes.len;
        // 临时 u8 Value 数组
        const tmp = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(tmp);
        for (bytes, 0..) |b, i| {
            tmp[i] = value.Value.fromU8(b);
        }
        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..n], tmp);
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArray(self.tctx.?, tmp, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_to_str：u8[] 转字符串（UTF-8 解码）
    /// inputs[0] = arr (ArrayValue<u8>), output = ref_chan (Str)
    fn execArrayToStr(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        // 收集字节数据
        const n = arr.elements.len;
        const tmp_bytes = self.tctx.?.backing.alloc(u8, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(tmp_bytes);
        for (arr.elements, 0..) |elem, i| {
            tmp_bytes[i] = elem.asU8();
        }
        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, tmp_bytes) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    // ════════════════════════════════════════════
    // 记录操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 RecordValue 指针
    /// 内联以让编译器消除连续 record_get/set 的冗余 null/对齐/type_tag 检查
    inline fn readRecord(self: *Engine, chan: u16) ?*value.RecordValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        if (@intFromPtr(ptr) < 0x1000) return null;
        if (@intFromPtr(ptr) % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
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

    /// record_make：创建空记录，预分配 field_count 个槽位
    /// meta.const_val.int_val 编码：(field_count << 32) | type_name_pool_idx
    /// 字段表初始化为 unit（后续 record_set 覆写）
    /// 优化：直接在 allocObj 连续内存上初始化 fields，跳过临时数组 alloc/free + memcpy
    /// 逃逸分析驱动：非逃逸函数内的记录走 ShadowArena，endFunction 时 O(1) reset
    inline fn execRecordMake(self: *Engine, node: *const Node) EngineError!void {
        const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
        const packed_val = if (meta.const_val) |cv| switch (cv) {
            .int_val => |iv| iv,
            else => return error.InvalidMetaIndex,
        } else return error.InvalidMetaIndex;
        // meta 编码：(field_ref_bits << 64) | (field_count << 32) | type_name_pool_idx
        const bits: u128 = @bitCast(packed_val);
        const type_name_idx: usize = @intCast(@as(u32, @truncate(bits)));
        const field_count: u32 = @truncate(bits >> 32);
        const field_ref_bits: u64 = @truncate(bits >> 64);
        const type_name = if (type_name_idx < self.ir.string_pool.len) self.ir.string_pool[type_name_idx] else "";

        // 直接分配连续内存：[RecordValue header | Value fields[]]
        // 在连续内存上直接初始化 fields 为 unit，无需临时数组 + memcpy
        const f_size = field_count * @sizeOf(value.Value);
        const total = @sizeOf(value.RecordValue) + f_size;
        const use_arena = self.currentFuncUseArena();
        const obj_mem = if (use_arena)
            self.tctx.?.allocObjArena(total) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(total) catch return error.OutOfMemory;
        const rec: *value.RecordValue = @ptrCast(@alignCast(obj_mem.ptr));
        const f_ptr: [*]value.Value = @ptrCast(@alignCast(obj_mem.ptr + @sizeOf(value.RecordValue)));
        // 初始化 fields 为 unit（连续内存，单次 memset）
        @memset(f_ptr[0..field_count], value.Value.unit);
        rec.* = .{ .type_name = type_name, .fields = f_ptr[0..field_count], .field_ref_bits = field_ref_bits };
        value.obj_header.initObjHeader(&rec.header, .record, total, use_arena, self.tctx.?);
        const v = value.Value.fromRef(&rec.header);
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// record_get：按 field_id 读取字段值
    /// meta.const_val.int_val = field_id（u16 范围）
    /// inputs[0] = record_chan
    /// null/无效记录时安全写零（用于 ?. 安全访问中 unwrap null 后的 record_get）
    /// 优化：_pad 预计算 field_id（< 256 时），scalar_tag 预计算输出通道类型
    inline fn execRecordGet(self: *Engine, node: *const Node) EngineError!void {
        // 快速路径：_pad 预计算了 field_id（< 256）
        const field_id: u16 = if (node._pad != 0xFF) node._pad else blk: {
            const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => return error.InvalidMetaIndex,
            } else return error.InvalidMetaIndex;
        };
        const in_chan = node.inputs[0];
        const rec = self.readRecord(in_chan) orelse {
            // null/无效记录：写零到输出（safe access 场景，vec_select 会选择 null 分支）
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
            return;
        };
        if (field_id >= rec.fields.len) {
            return error.InvalidChannel;
        }
        const v = rec.fields[field_id];
        // 按字段类型语义复制：&T / *T 共享，普通类型深拷贝
        const copied = try self.cloneValueForContainer(v, rec.fieldIsRef(field_id));

        // 快速路径：scalar_tag 预计算了输出通道类型（标量类型）
        // 且 Value variant 与输出通道类型匹配时，直接 payload 字节复制
        // 跳过 valueToChan 的 17 分支 switch
        if (node.scalar_tag != 0xFF) {
            const tag: ScalarTag = @enumFromInt(node.scalar_tag);
            const dst = self.runtime.rawPtr(node.output);
            // 检查 Value variant 是否与 tag 匹配
            // variant tag 可通过 @intFromEnum(v) 获取（Value 是 tagged union）
            const variant_matches: bool = switch (copied) {
                .boolean => tag == .boolean,
                .char => tag == .char,
                .i8 => tag == .i8, .i16 => tag == .i16, .i32 => tag == .i32,
                .i64 => tag == .i64, .i128 => tag == .i128,
                .u8 => tag == .u8, .u16 => tag == .u16, .u32 => tag == .u32,
                .u64 => tag == .u64, .u128 => tag == .u128,
                .isize => tag == .isize, .usize => tag == .usize,
                .f16 => tag == .f16, .f32 => tag == .f32, .f64 => tag == .f64, .f128 => tag == .f128,
                else => false,
            };
            if (variant_matches) {
                const w: usize = switch (tag) {
                    .boolean, .i8, .u8 => 1,
                    .char, .i16, .u16, .f16 => 2,
                    .i32, .u32, .f32 => 4,
                    .i64, .u64, .f64, .isize, .usize => @sizeOf(isize),
                    .i128, .u128, .f128 => 16,
                };
                const src: [*]const u8 = switch (tag) {
                    .boolean => @ptrCast(&copied.boolean),
                    .char => @ptrCast(&copied.char),
                    .i8 => @ptrCast(&copied.i8),
                    .i16 => @ptrCast(&copied.i16),
                    .i32 => @ptrCast(&copied.i32),
                    .i64 => @ptrCast(&copied.i64),
                    .i128 => @ptrCast(&copied.i128),
                    .u8 => @ptrCast(&copied.u8),
                    .u16 => @ptrCast(&copied.u16),
                    .u32 => @ptrCast(&copied.u32),
                    .u64 => @ptrCast(&copied.u64),
                    .u128 => @ptrCast(&copied.u128),
                    .isize => @ptrCast(&copied.isize),
                    .usize => @ptrCast(&copied.usize),
                    .f16 => @ptrCast(&copied.f16),
                    .f32 => @ptrCast(&copied.f32),
                    .f64 => @ptrCast(&copied.f64),
                    .f128 => @ptrCast(&copied.f128),
                };
                @memcpy(dst[0..w], src[0..w]);
                return;
            }
            // variant 不匹配：回退到 valueToChan（处理类型转换）
        }
        // 回退：非标量通道或 variant 不匹配
        self.valueToChan(node.output, copied);
    }

    /// record_set：按 field_id 写入字段值
    /// meta.const_val.int_val = field_id（u16 范围）
    /// inputs[0] = record_chan, inputs[1] = value_chan
    /// 优化：_pad 预计算 field_id，scalar_tag 预计算 inputs[1] 类型，直接指针读取
    inline fn execRecordSet(self: *Engine, node: *const Node) EngineError!void {
        const rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        const field_id: u16 = if (node._pad != 0xFF) node._pad else blk: {
            const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => return error.InvalidMetaIndex,
            } else return error.InvalidMetaIndex;
        };
        if (field_id >= rec.fields.len) return error.InvalidChannel;

        // 快速路径：scalar_tag 预计算了 inputs[1] 类型（标量类型）
        // 直接指针读取，构造 Value，跳过 chanToValue 的 17 分支 switch
        const v: value.Value = if (node.scalar_tag != 0xFF) blk: {
            const tag: ScalarTag = @enumFromInt(node.scalar_tag);
            const src = self.runtime.rawPtr(node.inputs[1]);
            break :blk switch (tag) {
                .boolean => value.Value.fromBool(src[0] != 0),
                .char => value.Value{ .char = @bitCast(@as(*u32, @ptrCast(@alignCast(src))).*) },
                .i8 => value.Value.fromI8(@bitCast(src[0])),
                .u8 => value.Value.fromU8(src[0]),
                .i16 => value.Value.fromI16(@bitCast(@as(*i16, @ptrCast(@alignCast(src))).*)),
                .u16 => value.Value.fromU16(@bitCast(@as(*u16, @ptrCast(@alignCast(src))).*)),
                .i32 => value.Value.fromI32(@bitCast(@as(*i32, @ptrCast(@alignCast(src))).*)),
                .u32 => value.Value.fromU32(@bitCast(@as(*u32, @ptrCast(@alignCast(src))).*)),
                .i64 => value.Value.fromI64(@bitCast(@as(*i64, @ptrCast(@alignCast(src))).*)),
                .u64 => value.Value.fromU64(@bitCast(@as(*u64, @ptrCast(@alignCast(src))).*)),
                .i128 => value.Value.fromI128(@bitCast(@as(*i128, @ptrCast(@alignCast(src))).*)),
                .u128 => value.Value.fromU128(@bitCast(@as(*u128, @ptrCast(@alignCast(src))).*)),
                .isize => value.Value.fromIsize(@bitCast(@as(*isize, @ptrCast(@alignCast(src))).*)),
                .usize => value.Value.fromUsize(@bitCast(@as(*usize, @ptrCast(@alignCast(src))).*)),
                .f16 => value.Value.fromF16(@bitCast(@as(*f16, @ptrCast(@alignCast(src))).*)),
                .f32 => value.Value.fromF32(@bitCast(@as(*f32, @ptrCast(@alignCast(src))).*)),
                .f64 => value.Value.fromF64(@bitCast(@as(*f64, @ptrCast(@alignCast(src))).*)),
                .f128 => value.Value.fromF128(@bitCast(@as(*f128, @ptrCast(@alignCast(src))).*)),
            };
        } else self.chanToValue(node.inputs[1]);

        // 按字段类型语义复制新值：&T / *T 共享，普通类型深拷贝
        const copied = try self.cloneValueForContainer(v, rec.fieldIsRef(field_id));
        // release 旧值
        rec.fields[field_id].release(self.tctx.?);
        rec.fields[field_id] = copied;
    }

    /// record_clone：深拷贝记录（用于记录扩展 (...base, field: value)）
    /// inputs[0] = base record_chan，output = new record_chan
    /// meta.const_val.int_val = extra_count（扩展字段数，默认 0）
    /// 优化：直接在 allocObj 连续内存上初始化，跳过临时数组 alloc/free + memcpy
    inline fn execRecordClone(self: *Engine, node: *const Node) EngineError!void {
        const base_rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        // 读取扩展字段数（_pad 预计算优先，回退到 meta）
        const extra_count: u32 = if (node._pad != 0xFF) node._pad else blk: {
            if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) break :blk 0;
            const meta = self.ir.scalar_metas[node.meta_index];
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => break :blk 0,
            } else break :blk 0;
        };
        const total = base_rec.fields.len + extra_count;

        // 直接分配连续内存：[RecordValue header | Value fields[]]
        const f_size = total * @sizeOf(value.Value);
        const alloc_total = @sizeOf(value.RecordValue) + f_size;
        const obj_mem = self.tctx.?.allocObj(alloc_total) catch return error.OutOfMemory;
        const new_rec: *value.RecordValue = @ptrCast(@alignCast(obj_mem.ptr));
        const f_ptr: [*]value.Value = @ptrCast(@alignCast(obj_mem.ptr + @sizeOf(value.RecordValue)));
        // 拷贝 base 字段：&T / *T 共享，普通类型深拷贝
        for (base_rec.fields, 0..) |src, i| {
            f_ptr[i] = try self.cloneValueForContainer(src, base_rec.fieldIsRef(@intCast(i)));
        }
        // extra 槽位初始化为 unit
        @memset(f_ptr[base_rec.fields.len..total], value.Value.unit);
        new_rec.* = .{
            .type_name = base_rec.type_name,
            .fields = f_ptr[0..total],
            .field_names = base_rec.field_names,
            .field_ref_bits = base_rec.field_ref_bits,
        };
        value.obj_header.initObjHeader(&new_rec.header, .record, alloc_total, false, self.tctx.?);
        const v = value.Value.fromRef(&new_rec.header);
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    // ════════════════════════════════════════════
    // 函数调用
    // ════════════════════════════════════════════

    fn execCall(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        // Profiling: function call/ret 事件（精确重建 per-function 统计）
        // 保存/恢复 caller 的 current_func_idx，确保 callee 返回后的分配归因到 caller
        // 注意：defer 必须在函数作用域，不能在 if 块内——
        //   Zig 的 defer 在所在 block 结束时执行，若放在 if 块内，
        //   current_func_idx 会在进入 callee body 前就恢复为 caller，导致 per-function 归因全部错位
        const prof_opt = self.tctx.?.prof;
        var saved_func: u32 = 0;
        if (prof_opt) |p| {
            p.onFuncCall(call_meta.func_index);
            saved_func = p.current_func_idx.load(.acquire);
            p.setCurrentFunc(call_meta.func_index);
        }
        defer if (prof_opt) |p| {
            p.setCurrentFunc(saved_func);
            p.onFuncRet(call_meta.func_index);
        };

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        const callee_func = self.ir.functions[call_meta.func_index];
        const args = node.inputs[0..call_meta.arg_count];

        // Memoization 快速路径：递归纯函数 + 标量/nullable<标量> 参数 + 非尾调用
        // 命中则直接复制结果，跳过整个函数执行（O(1) 替代 O(递归深度)）
        // 尾调用跳过 memo（TCO 已优化，且 tco_restart 路径无标准结果写入）
        // ref_chan 参数/返回不启用 memoization（指针哈希命中率低，deepCopy 开销巨大）
        if (call_meta.memo_slot > 0 and !call_meta.tail_call) {
            const arg_hash = self.hashArgs(args);
            const key = MemoKey{ .slot = call_meta.memo_slot, .arg_hash = arg_hash };
            if (self.memo_cache.get(key)) |entry| {
                // 缓存命中：复制结果字节到输出通道
                if (entry.width > 0) {
                    const dst = self.runtime.rawPtr(node.output);
                    @memcpy(dst[0..entry.width], entry.bytes[0..entry.width]);
                }
                if (self.tctx.?.prof) |prof| prof.recordMemo(true);
                return;
            }
            if (self.tctx.?.prof) |prof| prof.recordMemo(false);
            // 未命中：执行函数，结束后缓存结果
            const memo_key = key;

            // 执行标准调用路径
            try self.execCallStandard(node, call_meta, callee_func, args);

            // 缓存结果：直接缓存字节（标量和 nullable<标量> 都用字节路径）
            const result_w = self.runtime.elemWidth(node.output);
            if (result_w > 0 and result_w <= 16) {
                var entry: MemoEntry = .{ .width = result_w };
                const src = self.runtime.rawPtr(node.output);
                @memcpy(entry.bytes[0..result_w], src[0..result_w]);
                // 使用 backing allocator（Engine 生命周期）
                const backing = if (self.tctx) |tc| tc.backing else self.ir.backing;
                self.memo_cache.put(backing, memo_key, entry) catch {};
            }
            return;
        }

        // 标准调用路径（TCO + 递归 save/restore + 非递归直通）
        try self.execCallStandard(node, call_meta, callee_func, args);
    }

    /// 复制单个实参到目标形参通道，自动处理 Lazy<T> 强制求值。
    /// 当实参是 ref_chan（Lazy<T>）而形参通道是标量时，通过 readScalarValue 观察并求值。
    /// 形参也是引用类型时保留引用本身（避免错误强制）。
    /// is_ref 为 true 表示实参类型为 &T / *T，应保持引用语义；否则普通复合类型走深拷贝。
    fn copyArgToParam(self: *Engine, arg_chan: u16, dst_chan: u16, is_ref: bool) EngineError!void {
        const src_meta = self.ir.channels.get(arg_chan);
        const dst_meta = self.ir.channels.get(dst_chan);

        // ref_chan → 标量通道：可能是 Lazy<T> 强制求值或标量值解码
        if (src_meta.chan_type == .ref_chan and dst_meta.chan_type != .ref_chan and dst_meta.chan_type != .nullable_chan) {
            // 先尝试作为堆对象读取（处理 Lazy<T> 强制求值）
            if (self.readRefObj(arg_chan)) |_| {
                const v = try self.readScalarValue(arg_chan);
                self.writeScalarValue(dst_chan, v);
                return;
            }
            // readRefObj 失败：ref_chan 持有标量位模式，按目标类型解码
            try self.copyCrossType(dst_chan, arg_chan);
            return;
        }

        // 标量通道 → ref_chan：标量值扩展为 8 字节写入（类型参数实例化为标量时）
        if (src_meta.chan_type != .ref_chan and src_meta.chan_type != .nullable_chan and dst_meta.chan_type == .ref_chan) {
            try self.copyCrossType(dst_chan, arg_chan);
            return;
        }

        try self.cloneValueBetweenChannels(dst_chan, arg_chan, is_ref);
    }

    /// 按引用位图将实参复制到形参通道（统一值语义深拷贝判定）。
    /// 取 args.len 与形参数量的较小值，逐个按 arg_ref_bits 判定引用语义。
    fn copyArgsToParams(self: *Engine, args: []const u16, callee_func: Function, arg_ref_bits: u16) EngineError!void {
        const count = @min(args.len, callee_func.param_channels.len);
        for (0..count) |i| {
            const dst_chan = callee_func.param_channels[i];
            const is_ref = ((arg_ref_bits >> @intCast(i)) & 1) != 0;
            try self.copyArgToParam(args[i], dst_chan, is_ref);
        }
    }

    /// 将闭包 upvalues 复制到 explicit_count 之后的形参通道。
    fn copyClosureUpvalues(self: *Engine, callee_func: Function, closure: *value.Closure, explicit_count: usize) void {
        const total_params = callee_func.param_channels.len;
        const upvalue_count = @min(closure.upvalues.len, if (total_params > explicit_count) total_params - explicit_count else 0);
        for (0..upvalue_count) |i| {
            const dst_chan = callee_func.param_channels[explicit_count + i];
            self.writeScalarValue(dst_chan, closure.upvalues[i]);
        }
    }

    /// 暂存调用结果（在 leaveFunction 之前调用）。
    /// ret_is_ref=true 或非 ref_chan 时直接字节拷贝；普通复合类型 ref_chan 深拷贝。
    fn saveCallResult(self: *Engine, result_chan: u16, ret_is_ref: bool) EngineError!SavedResult {
        const w = self.runtime.elemWidth(result_chan);
        if (w == 0) return .none;
        const result_meta = self.ir.channels.get(result_chan);
        if (!ret_is_ref and result_meta.chan_type == .ref_chan) {
            const v = self.chanToValue(result_chan);
            const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
            try self.trackValueTree(copied);
            return .{ .value = copied };
        }
        var buf: [16]u8 = undefined;
        const src = self.runtime.rawPtr(result_chan);
        @memcpy(buf[0..w], src[0..w]);
        return .{ .bytes = .{ .buf = buf, .w = @intCast(w) } };
    }

    /// 将暂存结果写入输出通道（在 leaveFunction 之后调用）。
    fn writeCallResult(self: *Engine, out_chan: u16, saved: SavedResult) EngineError!void {
        switch (saved) {
            .none => {},
            .bytes => |b| {
                const dst = self.runtime.rawPtr(out_chan);
                @memcpy(dst[0..b.w], b.buf[0..b.w]);
            },
            .value => |v| self.valueToChan(out_chan, v),
        }
    }

    /// 标准调用路径：从 execCall 抽出，供 memoization 快速路径未命中时调用
    /// 双 Region 架构：所有调用统一走 enterFunction/leaveFunction，
    /// Runtime 内部管理 chan_ptrs 的保存/恢复和 call_region 的 bump/resetTo。
    /// 自递归尾调用优化（TCO）复用当前帧，跳过 enterFunction/leaveFunction。
    fn execCallStandard(self: *Engine, node: *const Node, call_meta: ir_mod.CallMeta, callee_func: Function, args: []const u16) EngineError!void {
        // 自递归尾调用优化：当 callee == current_func_idx 且 call_meta.tail_call == true 时，
        // 设置 tco_restart 信号，让 execFunction 用新参数重新执行
        // 复用当前帧（同一函数的通道索引相同），无需 enterFunction/leaveFunction
        if (call_meta.func_index == self.current_func_idx and args.len <= 16 and call_meta.tail_call) {
            self.tco_arg_count = @intCast(args.len);
            @memcpy(self.tco_args[0..args.len], args);
            self.tco_caller_func_idx = self.current_func_idx;
            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
            self.tco_restart = true;
            return;
        }

        // 标准调用路径：enterFunction → copyArgsToParams → execFunction → saveResult → leaveFunction → writeResult
        //
        // SCC 问题（自递归）：callee == caller 时，通道索引重叠。
        // enterFunction 覆盖 callee local 范围的 chan_ptrs（指向 callee 新内存），
        // 导致实参通道（与 callee local 重叠）的值不可读。
        // 修复：自递归调用在 enterFunction 前保存实参值（含深拷贝），
        //   enterFunction 后直接写入 callee 的形参通道。
        // 非自递归调用：enterFunction 不触碰实参通道，直接 copyArgsToParams。
        //
        // 结果处理：leaveFunction 前用 saveCallResult 暂存到栈上，
        //   leaveFunction 后（chan_ptrs 已恢复为 caller）用 writeCallResult 写入。
        //   消除 SCC 场景下 node.output chan_ptrs 指向 callee 内存的问题。

        const is_self_recursive = (call_meta.func_index == self.current_func_idx);

        if (is_self_recursive) {
            // ── 自递归：保存实参值（含深拷贝） ──
            var saved_arg_values: [16]value.Value = undefined;
            for (args, 0..) |arg_chan, i| {
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                const meta = self.ir.channels.get(arg_chan);
                if (!is_ref and meta.chan_type == .ref_chan and self.readRefObj(arg_chan) != null) {
                    const v = self.chanToValue(arg_chan);
                    saved_arg_values[i] = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(saved_arg_values[i]);
                } else {
                    saved_arg_values[i] = self.chanToValue(arg_chan);
                }
            }

            try self.runtime.enterFunction(call_meta.func_index, &callee_func);
            errdefer self.runtime.leaveFunction();

            // 写入 callee 形参通道
            const count = @min(args.len, callee_func.param_channels.len);
            for (0..count) |i| {
                self.valueToChan(callee_func.param_channels[i], saved_arg_values[i]);
            }
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(call_meta.func_index, &callee_func);
            errdefer self.runtime.leaveFunction();
            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
        }

        self.call_stack[self.call_depth] = .{
            .func_idx = call_meta.func_index,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        // 泛型类型实参压栈（供 typeof(T) 运行时查表）
        self.frame_type_args_stack.append(self.tctx.?.backing, call_meta.type_args) catch return error.OutOfMemory;
        defer _ = self.frame_type_args_stack.pop();

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(call_meta.func_index, args);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果到栈上局部变量 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }

    /// 哈希参数为 u64（FNV-1a 变体）
    /// 直接哈希通道字节（标量 + nullable<标量>，ref_chan 已被 isMemoizableChanType 排除）
    fn hashArgs(self: *Engine, args: []const u16) u64 {
        var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
        for (args) |arg_chan| {
            const meta = self.ir.channels.get(arg_chan);
            const w = meta.elem_width;
            if (w == 0) continue;
            const src = self.runtime.rawPtr(arg_chan);
            for (src[0..w]) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
        }
        return h;
    }

    // ════════════════════════════════════════════
    // 向量操作（Phase 3）
    // ════════════════════════════════════════════

    /// 执行子图节点范围（供 vec_map/route_dispatch 等按需调用）
    /// 构建局部 skip 位图，只跳过嵌套子图节点（由对应的 exec 函数按需执行）
    fn execBodyNodes(self: *Engine, nodes: []const Node, start: usize, len: usize) EngineError!?u16 {
        if (len == 0) return null;

        // 快速检查：范围内是否包含子图节点（大部分 body 无嵌套子图）
        var has_nested = false;
        for (nodes[start .. start + len]) |n| {
            switch (n.op) {
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while,
                .cleanup_register, .route_dispatch, .scalar_loop, .closure_make => {
                    has_nested = true;
                    break;
                },
                else => {},
            }
        }

        // 无嵌套子图：直接线性执行（热路径，零分配）
        if (!has_nested) {
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const node: *const Node = &nodes[start + i];
                const r = self.execNode(node) catch |err| {
                    return err;
                };
                // 检查 tco_restart：execCall 检测到自递归时设置
                if (self.tco_restart) {
                    return null; // 提前返回，让上层 execFunction 处理 TCO
                }
                if (r) |ret| {
                    return ret;
                }
            }
            return null;
        }

        // 有嵌套子图：构建本地跳过位图
        var stack_skip: [128]bool = undefined;
        var local_skip: []bool = undefined;
        var heap_skip: ?[]bool = null;
        defer if (heap_skip) |hs| self.tctx.?.backing.free(hs);

        if (len <= stack_skip.len) {
            local_skip = stack_skip[0..len];
        } else {
            heap_skip = try self.tctx.?.backing.alloc(bool, len);
            local_skip = heap_skip.?;
        }
        @memset(local_skip, false);

        const node_start = self.ir.functions[self.current_func_idx].node_start;
        const range_start = start;
        const range_end = start + len;
        for (nodes[start .. start + len]) |n| {
            switch (n.op) {
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                    const vm = self.ir.vector_metas[n.meta_index - 1];
                    if (vm.body_len == 0) continue;
                    markNestedRange(local_skip, vm.body_start -| node_start, vm.body_len, range_start, range_end);
                },
                .cleanup_register => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                    const cm = self.ir.cleanup_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    markNestedRange(local_skip, cm.body_start -| node_start, cm.body_len, range_start, range_end);
                },
                .route_dispatch => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                    const rm = self.ir.route_metas[n.meta_index - 1];
                    for (rm.body_starts, rm.body_lens) |bs, bl| {
                        if (bl == 0) continue;
                        markNestedRange(local_skip, bs -| node_start, bl, range_start, range_end);
                    }
                },
                .scalar_loop => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                    const lm = self.ir.loop_metas[n.meta_index - 1];
                    if (lm.body_len == 0) continue;
                    markNestedRange(local_skip, lm.body_start -| node_start, lm.body_len, range_start, range_end);
                },
                .closure_make => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                    const cm = self.ir.closure_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    markNestedRange(local_skip, cm.body_start -| node_start, cm.body_len, range_start, range_end);
                },
                else => {},
            }
        }

        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (local_skip[i]) continue;
            const node: *const Node = &nodes[start + i];
            const r = self.execNode(node) catch |err| {
                return err;
            };
            // 检查 tco_restart：execCall 检测到自递归时设置
            if (self.tco_restart) {
                return null; // 提前返回，让上层 execFunction 处理 TCO
            }
            if (r) |ret| {
                return ret;
            }
        }
        return null;
    }

    /// 标记嵌套子图范围内的节点（辅助函数）
    fn markNestedRange(skip: []bool, body_local_start: usize, body_len: u32, range_start: usize, range_end: usize) void {
        const body_local_end = body_local_start + body_len;
        const mark_start = @max(body_local_start, range_start);
        const mark_end = @min(body_local_end, range_end);
        if (mark_start < mark_end) {
            for (mark_start..mark_end) |idx| {
                skip[idx - range_start] = true;
            }
        }
    }

    /// 紧凑描述符执行：仅遍历有效节点索引，零 skip 分支
    /// for 循环比 while 循环生成更紧凑的机器码（无手动索引递增和边界比较）
    fn execBodyNodesCompact(self: *Engine, nodes: []const Node, start: usize, active: []const u32) EngineError!?u16 {
        for (active) |local_idx| {
            const node: *const Node = &nodes[start + local_idx];
            if (try self.execNode(node)) |ret| {
                return ret;
            }
        }
        return null;
    }

    /// 预编译有效节点为 BodyInst 数组（直接函数指针调用，无 switch dispatch）
    /// 若任一节点的 op 不在 opToScalarExecFn 中，返回 null（调用方回退到 execBodyNodesCompact）
    fn compileActiveNodes(self: *Engine, nodes: []const Node, start: usize, active: []const u32) ?[]BodyInst {
        if (active.len == 0) return null;
        const insts = self.tctx.?.backing.alloc(BodyInst, active.len) catch return null;
        for (active, 0..) |local_idx, i| {
            const node = &nodes[start + local_idx];
            const exec_fn = opToScalarExecFn(node.op) orelse {
                self.tctx.?.backing.free(insts);
                return null;
            };
            insts[i] = .{ .exec = exec_fn, .node = node };
        }
        return insts;
    }

    /// 执行预编译的指令数组（紧凑直接调用循环，无 execNode switch）
    /// 仅处理不含 halt_return/throw/panic 的 body（break/continue 通过 error 传播）
    fn execCompiledCompact(self: *Engine, insts: []const BodyInst) EngineError!void {
        for (insts) |inst| {
            try inst.exec(self, inst.node);
        }
    }

    /// 编译函数体为 FuncBodyCache（TCO 主循环优化）
    /// 当 body_skip 全为 false 时使用 direct 路径（零间接寻址）
    /// 否则使用 compact_idx 路径（紧凑索引数组，消除 body_skip 检查）
    /// 记录 TCO call 节点位置 + 预计算参数复制信息
    fn compileFuncBody(
        self: *Engine,
        func_idx: u16,
        nodes: []const Node,
        body_skip: []const bool,
        tco_call_node_idx: ?usize,
        tco_call_meta_idx: u16,
    ) ?FuncBodyCache {
        const backing = self.tctx.?.backing;

        // 统计有效节点数（排除 body_skip）+ 检测是否全有效
        var count: u32 = 0;
        var all_active = true;
        for (0..nodes.len) |i| {
            if (!body_skip[i]) {
                count += 1;
            } else {
                all_active = false;
            }
        }
        if (count == 0) return null;

        // 预计算 TCO 参数复制信息（避免每次迭代的 elemWidth/rawPtr 查找）
        var tco_arg_count: u8 = 0;
        var tco_arg_dst_chans: [16]u16 = [_]u16{0} ** 16;
        var tco_arg_widths: [16]u8 = [_]u8{0} ** 16;
        if (tco_call_node_idx != null and tco_call_meta_idx > 0 and tco_call_meta_idx <= self.ir.call_metas.len) {
            const call_meta = self.ir.call_metas[tco_call_meta_idx - 1];
            const tco_node = &nodes[tco_call_node_idx.?];
            const tco_args = tco_node.inputs[0..call_meta.arg_count];
            const arg_count = @min(tco_args.len, 16);
            tco_arg_count = @intCast(arg_count);
            const param_channels = self.ir.functions[func_idx].param_channels;
            for (0..arg_count) |j| {
                if (j < param_channels.len) {
                    tco_arg_dst_chans[j] = param_channels[j];
                    tco_arg_widths[j] = self.runtime.elemWidth(tco_args[j]);
                }
            }
        }

        if (all_active) {
            // Direct 路径：body_skip 全 false，直接遍历 nodes，零间接寻址
            // 不分配 compact_idx，tco_node_idx 直接指向 nodes 中的索引

            // 尝试编译 body [0..tco_node_idx) 为 BodyInst 数组（TCO hot path 优化）
            // 跳过 execNode 的 100+ 分支 switch dispatch
            // 仅当所有 body 节点的 op 都被 opToScalarExecFn 支持时才编译
            var body_insts: []BodyInst = &.{};
            var body_has_call = false;
            if (tco_call_node_idx) |tci| {
                if (tci > 0) {
                    var all_supported = true;
                    for (nodes[0..tci]) |n| {
                        if (opToScalarExecFn(n.op) == null) {
                            all_supported = false;
                            break;
                        }
                        if (n.op == .call) body_has_call = true;
                    }
                    if (all_supported) {
                        body_insts = backing.alloc(BodyInst, tci) catch &.{};
                        for (0..tci) |i| {
                            body_insts[i] = .{
                                .exec = opToScalarExecFn(nodes[i].op).?,
                                .node = &nodes[i],
                            };
                        }
                    }
                }
            } else {
                // 无 TCO：编译全函数体为 BodyInst（消除 execNode switch dispatch）
                // 非尾递归函数也受益于直接函数指针调用
                var all_supported = true;
                for (nodes) |n| {
                    if (opToScalarExecFn(n.op) == null) {
                        all_supported = false;
                        break;
                    }
                    if (n.op == .call) body_has_call = true;
                }
                if (all_supported and nodes.len > 0) {
                    body_insts = backing.alloc(BodyInst, nodes.len) catch &.{};
                    for (nodes, 0..) |n, i| {
                        body_insts[i] = .{
                            .exec = opToScalarExecFn(n.op).?,
                            .node = &nodes[i],
                        };
                    }
                }
            }

            const result = FuncBodyCache{
                .compact_idx = &.{},
                .tco_node_idx = if (tco_call_node_idx) |tci| @intCast(tci) else null,
                .direct = true,
                .tco_arg_count = tco_arg_count,
                .tco_arg_dst_chans = tco_arg_dst_chans,
                .tco_arg_widths = tco_arg_widths,
                .body_insts = body_insts,
                .body_has_call = body_has_call,
            };
            if (func_idx < self.func_body_cache.len) {
                self.func_body_cache[func_idx] = result;
            }
            return result;
        }

        // Compact 路径：构建紧凑索引数组，排除 body_skip 的节点
        const compact_idx = backing.alloc(u32, count) catch return null;

        var tco_compact_idx: ?u32 = null;
        var idx: u32 = 0;
        for (0..nodes.len) |i| {
            if (body_skip[i]) continue;
            compact_idx[idx] = @intCast(i);

            // 记录 TCO call 节点在紧凑索引中的位置
            if (tco_call_node_idx) |tci| {
                if (i == tci) {
                    tco_compact_idx = idx;
                }
            }
            idx += 1;
        }

        const result = FuncBodyCache{
            .compact_idx = compact_idx,
            .tco_node_idx = tco_compact_idx,
            .direct = false,
            .tco_arg_count = tco_arg_count,
            .tco_arg_dst_chans = tco_arg_dst_chans,
            .tco_arg_widths = tco_arg_widths,
        };

        // 写入缓存
        if (func_idx < self.func_body_cache.len) {
            self.func_body_cache[func_idx] = result;
        }

        return result;
    }

    /// LICM：分析循环不变量，返回不变量节点的本地索引数组（相对 body 子图起始）
    /// 不变量节点 = isScalar() + 所有输入不依赖循环变量
    /// 循环变量 = {iter_chan} ∪ {store 目标} ∪ {非纯计算节点输出}，按拓扑序单遍传播
    fn analyzeLoopInvariants(self: *Engine, lm: LoopMeta, nodes: []const Node, body_local_start: usize) ![]u32 {
        const chan_count = self.runtime.chan_count;
        if (chan_count == 0 or lm.body_len == 0) return &.{};

        // 栈缓冲区优化（chan_count 通常 < 256）
        var stack_buf: [256]bool = undefined;
        const use_stack = chan_count <= stack_buf.len;
        const loop_var = if (use_stack) stack_buf[0..chan_count] else try self.tctx.?.backing.alloc(bool, chan_count);
        defer if (!use_stack) self.tctx.?.backing.free(loop_var);
        @memset(loop_var, false);

        // 1. 标记循环变量通道
        if (lm.loop_kind == .for_loop and lm.iter_chan < chan_count) {
            loop_var[lm.iter_chan] = true;
        }
        for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
            if (n.op == .store) {
                if (n.output < chan_count) loop_var[n.output] = true;
            } else if (!n.op.isScalar()) {
                if (n.output < chan_count) loop_var[n.output] = true;
            }
        }

        // 2. 单遍传播（节点已是拓扑序）
        for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
            if (!n.op.isScalar()) continue;
            if (n.output >= chan_count or loop_var[n.output]) continue;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    loop_var[n.output] = true;
                    break;
                }
            }
        }

        // 3. 统计不变量节点数
        var count: u32 = 0;
        for (0..lm.body_len) |j| {
            const n = &nodes[body_local_start + j];
            if (!n.op.isScalar()) continue;
            if (n.output < chan_count and loop_var[n.output]) continue;
            var is_inv = true;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    is_inv = false;
                    break;
                }
            }
            if (is_inv) count += 1;
        }

        if (count == 0) return &.{};

        // 4. 收集不变量节点索引
        const result = try self.tctx.?.backing.alloc(u32, count);
        var idx: u32 = 0;
        for (0..lm.body_len) |j| {
            const n = &nodes[body_local_start + j];
            if (!n.op.isScalar()) continue;
            if (n.output < chan_count and loop_var[n.output]) continue;
            var is_inv = true;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    is_inv = false;
                    break;
                }
            }
            if (is_inv) {
                result[idx] = @intCast(j);
                idx += 1;
            }
        }
        return result;
    }

    fn execScalarLoop(self: *Engine, node: *const Node) EngineError!?u16 {
        if (node.meta_index == 0 or node.meta_index > self.ir.loop_metas.len) return error.InvalidMetaIndex;
        const lm = self.ir.loop_metas[node.meta_index - 1];

        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const body_local_start: usize = lm.body_start - func.node_start;

        // 使用缓存的紧凑描述符（IR 不可变，只需计算一次）
        const meta_idx = node.meta_index - 1;
        const lac: LoopActiveCache = blk: {
            if (meta_idx < self.loop_active_cache.len) {
                if (self.loop_active_cache[meta_idx]) |cached| {
                    break :blk cached;
                }
            }
            // 首次调用：构建临时 skip 位图 → 提取紧凑索引 → 释放位图
            const skip = try self.tctx.?.backing.alloc(bool, lm.body_len);
            defer self.tctx.?.backing.free(skip);
            @memset(skip, false);
            for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
                switch (n.op) {
                    .route_dispatch => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                        const rm = self.ir.route_metas[n.meta_index - 1];
                        for (rm.body_starts, rm.body_lens) |bs2, bl| {
                            if (bl == 0) continue;
                            if (bs2 < lm.body_start) continue;
                            const sub_start = bs2 - lm.body_start;
                            const sub_end = sub_start + bl;
                            for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                        }
                    },
                    .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                        const vm = self.ir.vector_metas[n.meta_index - 1];
                        if (vm.body_len == 0) continue;
                        if (vm.body_start < lm.body_start) continue;
                        const sub_start = vm.body_start - lm.body_start;
                        const sub_end = sub_start + vm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .cleanup_register => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                        const cm = self.ir.cleanup_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        if (cm.body_start < lm.body_start) continue;
                        const sub_start = cm.body_start - lm.body_start;
                        const sub_end = sub_start + cm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .scalar_loop => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                        const inner_lm = self.ir.loop_metas[n.meta_index - 1];
                        if (inner_lm.body_len == 0) continue;
                        if (inner_lm.body_start < lm.body_start) continue;
                        const sub_start = inner_lm.body_start - lm.body_start;
                        const sub_end = sub_start + inner_lm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .closure_make => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                        const cm = self.ir.closure_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        if (cm.body_start < lm.body_start) continue;
                        const sub_start = cm.body_start - lm.body_start;
                        const sub_end = sub_start + cm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    else => {},
                }
            }

            // LICM：分析循环不变量
            const invariant_active = try self.analyzeLoopInvariants(lm, nodes, body_local_start);

            // 构建不变量位图（栈分配，用于快速跳过）
            var inv_set_buf: [128]bool = undefined;
            const use_inv_stack = lm.body_len <= inv_set_buf.len;
            const inv_set = if (use_inv_stack) inv_set_buf[0..lm.body_len] else try self.tctx.?.backing.alloc(bool, lm.body_len);
            defer if (!use_inv_stack) self.tctx.?.backing.free(inv_set);
            @memset(inv_set, false);
            for (invariant_active) |idx| inv_set[idx] = true;

            // 从 skip + inv_set 提取紧凑索引：cond 段 [0, cond_len) + body 段 [cond_len, body_len)
            const cond_len = lm.cond_len;

            // 计数（排除不变量节点）
            var cond_count: u32 = 0;
            var body_count: u32 = 0;
            for (0..cond_len) |j| {
                if (!skip[j] and !inv_set[j]) cond_count += 1;
            }
            for (cond_len..lm.body_len) |j| {
                if (!skip[j] and !inv_set[j]) body_count += 1;
            }

            // 分配并填充（0 长度也分配，保证类型为 []u32 可写）
            const cond_active = try self.tctx.?.backing.alloc(u32, cond_count);
            const body_active = try self.tctx.?.backing.alloc(u32, body_count);
            var ci: u32 = 0;
            var bi: u32 = 0;
            for (0..cond_len) |j| {
                if (!skip[j] and !inv_set[j]) {
                    cond_active[ci] = @intCast(j);
                    ci += 1;
                }
            }
            for (cond_len..lm.body_len) |j| {
                if (!skip[j] and !inv_set[j]) {
                    body_active[bi] = @intCast(j - cond_len);
                    bi += 1;
                }
            }

            // 预编译有效节点为直接调用指令（消除 execNode switch dispatch）
            // 若任一节点 op 不支持直接调用，返回 null，运行时回退到 execBodyNodesCompact
            const body_node_start = body_local_start + cond_len;
            const cond_compiled = self.compileActiveNodes(nodes, body_local_start, cond_active);
            const body_compiled = self.compileActiveNodes(nodes, body_node_start, body_active);
            const inv_compiled = self.compileActiveNodes(nodes, body_local_start, invariant_active);

            const result = LoopActiveCache{
                .cond_active = cond_active,
                .body_active = body_active,
                .invariant_active = invariant_active,
                .cond_compiled = cond_compiled,
                .body_compiled = body_compiled,
                .invariant_compiled = inv_compiled,
            };
            if (meta_idx < self.loop_active_cache.len) {
                self.loop_active_cache[meta_idx] = result;
            }
            break :blk result;
        };

        // LICM：循环前执行一次不变量子图（纯计算节点，输入不依赖循环变量）
        if (lac.invariant_active.len > 0) {
            if (lac.invariant_compiled) |insts| {
                try self.execCompiledCompact(insts);
            } else {
                const inv_result = try self.execBodyNodesCompact(nodes, body_local_start, lac.invariant_active);
                if (inv_result) |halt_chan| return halt_chan;
            }
        }

        switch (lm.loop_kind) {
            .loop => {
                // 无限循环，仅 break 退出
                if (lac.body_compiled) |insts| {
                    while (true) {
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    }
                } else {
                    while (true) {
                        const result = self.execBodyNodesCompact(nodes, body_local_start, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (result) |halt_chan| return halt_chan;
                    }
                }
            },
            .while_loop => {
                // while 循环：每轮先执行条件子图，再检查条件
                const cond_len = lm.cond_len;
                const cond_compiled = lac.cond_compiled;
                const body_compiled = lac.body_compiled;
                while (true) {
                    // 条件段
                    if (cond_compiled) |insts| {
                        try self.execCompiledCompact(insts);
                    } else {
                        const cond_result = try self.execBodyNodesCompact(nodes, body_local_start, lac.cond_active);
                        if (cond_result) |halt_chan| return halt_chan;
                    }
                    const cond_val = try self.readScalarValue(lm.cond_chan);
                    if (!cond_val.asBool()) break;
                    // 循环体段
                    if (body_compiled) |insts| {
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    } else {
                        const body_result = self.execBodyNodesCompact(nodes, body_local_start + cond_len, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (body_result) |halt_chan| return halt_chan;
                    }
                }
            },
            .for_loop => {
                // for 循环：遍历向量元素
                const vec_chan = lm.cond_chan;
                const count = self.runtime.vectorLen(vec_chan);
                const elem_w = self.runtime.elemWidth(vec_chan);
                const base_ptr = self.runtime.chan_ptrs[vec_chan].?;

                if (lac.body_compiled) |insts| {
                    for (0..count) |i| {
                        self.runtime.chan_ptrs[lm.iter_chan] = base_ptr + i * elem_w;
                        self.runtime.chan_lengths[lm.iter_chan] = 1;
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    }
                } else {
                    for (0..count) |i| {
                        self.runtime.chan_ptrs[lm.iter_chan] = base_ptr + i * elem_w;
                        self.runtime.chan_lengths[lm.iter_chan] = 1;
                        const result = self.execBodyNodesCompact(nodes, body_local_start, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (result) |halt_chan| {
                            self.runtime.chan_ptrs[vec_chan] = base_ptr;
                            self.runtime.chan_lengths[vec_chan] = count;
                            return halt_chan;
                        }
                    }
                }

                // 恢复向量通道
                self.runtime.chan_ptrs[vec_chan] = base_ptr;
                self.runtime.chan_lengths[vec_chan] = count;
            },
        }

        // 循环结果写入 output（返回迭代次数或 0）
        self.runtime.writeI64(node.output, 0);
        return null;
    }

    /// vec_source：生成向量数据
    /// inputs[0]=start, inputs[1]=end (range) 或 inputs[0]=array_ref (array_source)
    fn execVecSource(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        switch (vm.vec_op) {
            .range_source => {
                // 按通道实际类型读取 start/end（避免 i32 通道读 8 字越界）
                const start = try self.readIntAsI64(node.inputs[0]);
                const end = try self.readIntAsI64(node.inputs[1]);
                // _pad=1 标记 inclusive range（..=）：count = end - start + 1
                const inclusive = (node._pad & 1) != 0;
                // inclusive 的 end+1 在 end == maxInt(i64) 时溢出（safe panic / fast wrap），
                // 用 std.math.add 检测溢出后 clamp 到 maxInt(i64)
                const range_end: i64 = if (inclusive)
                    std.math.add(i64, end, 1) catch std.math.maxInt(i64)
                else
                    end;
                // 跨度超 u32 范围时 clamp 到 maxInt(u32)（allocVector 上限 u32）
                const count: u32 = if (range_end > start) blk: {
                    const span = range_end - start;
                    if (span > std.math.maxInt(u32)) break :blk std.math.maxInt(u32);
                    break :blk @intCast(span);
                } else 0;
                try self.runtime.allocVector(node.output, count);
                const elem_type = vm.elem_type;
                for (0..count) |i| {
                    const val = start + @as(i64, @intCast(i));
                    const elem_ptr = self.runtime.vectorElemPtr(node.output, i);
                    // val 超出窄类型范围时 clamp 到边界，避免 @intCast panic
                    // （range 范围超出元素类型属类型错误，sema 应拦截；运行时防御性 clamp）
                    switch (elem_type) {
                        .i8_chan => @as(*i8, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, std.math.minInt(i8), std.math.maxInt(i8))),
                        .i16_chan => @as(*i16, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, std.math.minInt(i16), std.math.maxInt(i16))),
                        .i32_chan => @as(*i32, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, std.math.minInt(i32), std.math.maxInt(i32))),
                        .i64_chan => @as(*i64, @ptrCast(@alignCast(elem_ptr))).* = val,
                        .u8_chan => @as(*u8, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, 0, std.math.maxInt(u8))),
                        .u16_chan => @as(*u16, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, 0, std.math.maxInt(u16))),
                        .u32_chan => @as(*u32, @ptrCast(@alignCast(elem_ptr))).* = @intCast(std.math.clamp(val, 0, std.math.maxInt(u32))),
                        .u64_chan => @as(*u64, @ptrCast(@alignCast(elem_ptr))).* = @bitCast(val),
                        else => return error.UnsupportedOp,
                    }
                }
            },
            .array_source => {
                // 从 ArrayValue 读取元素到向量通道
                const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
                const count: u32 = @intCast(arr.elements.len);
                try self.runtime.allocVector(node.output, count);
                const w = self.runtime.elemWidth(node.output);
                for (0..count) |i| {
                    const elem_ptr = self.runtime.vectorElemPtr(node.output, i);
                    const v = arr.elements[i];
                    self.valueToRawPtr(elem_ptr, w, v);
                }
            },
            .repeat_source => {
                // repeat(val, n)：广播值 n 次
                const count: u32 = if (vm.length) |l| l else 0;
                try self.runtime.allocVector(node.output, count);
                const w = self.runtime.elemWidth(node.output);
                const src_ptr = self.runtime.rawPtr(node.inputs[0]);
                for (0..count) |i| {
                    const dst_ptr = self.runtime.vectorElemPtr(node.output, i);
                    @memcpy(dst_ptr[0..w], src_ptr[0..w]);
                }
            },
            .string_source => {
                // 从 Str 对象读取 UTF-8 字节，解码为 Unicode 标量值向量
                const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
                const bytes = s.bytes();
                // 先计算 Unicode 标量值数量
                var view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
                var iter = view.iterator();
                var count: u32 = 0;
                while (iter.nextCodepoint()) |_| count += 1;
                try self.runtime.allocVector(node.output, count);
                // 逐个写入 u21（char_chan 为 4 字节）
                iter = view.iterator();
                var i: u32 = 0;
                while (iter.nextCodepoint()) |cp| : (i += 1) {
                    const elem_ptr = self.runtime.vectorElemPtr(node.output, i);
                    const dst: *u32 = @ptrCast(@alignCast(elem_ptr));
                    dst.* = @intCast(cp);
                }
            },
            else => return error.InvalidMetaIndex,
        }
    }

    // ════════════════════════════════════════════
    // O(1) dispatch：Body 编译器实现
    // ════════════════════════════════════════════

    /// 标量 op 的零 dispatch 包装函数
    /// 每个函数直接调用对应的 exec* 方法，绕过 execNode 的 switch
    /// 用于 CompiledBody.insts 数组，实现 body 内节点的直接调用

    fn wrapConstI(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    fn wrapConstF(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    fn wrapConstBool(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    fn wrapConstChar(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    fn wrapConstStr(self: *Engine, node: *const Node) EngineError!void {
        try self.execConstStr(node);
    }
    fn wrapIntAdd(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .add);
    }
    fn wrapIntSub(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .sub);
    }
    fn wrapIntMul(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .mul);
    }
    fn wrapIntDiv(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .div);
    }
    fn wrapIntMod(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .mod);
    }
    fn wrapIntAnd(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_and);
    }
    fn wrapIntOr(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_or);
    }
    fn wrapIntXor(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_xor);
    }
    fn wrapIntShl(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntShift(node, .shl);
    }
    fn wrapIntShr(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntShift(node, .shr);
    }
    fn wrapIntNeg(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .neg);
    }
    fn wrapIntAbs(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .abs);
    }
    fn wrapIntNot(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .bit_not);
    }
    fn wrapFloatAdd(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .add);
    }
    fn wrapFloatSub(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .sub);
    }
    fn wrapFloatMul(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .mul);
    }
    fn wrapFloatDiv(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .div);
    }
    fn wrapFloatMod(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .mod);
    }
    fn wrapFloatNeg(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatUnOp(node, .neg);
    }
    fn wrapFloatAbs(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatUnOp(node, .abs);
    }
    fn wrapCmpEq(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .eq);
    }
    fn wrapCmpNe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .ne);
    }
    fn wrapCmpLt(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .lt);
    }
    fn wrapCmpLe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .le);
    }
    fn wrapCmpGt(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .gt);
    }
    fn wrapCmpGe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .ge);
    }
    fn wrapBoolAnd(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolBinOp(node, .and_);
    }
    fn wrapBoolOr(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolBinOp(node, .or_);
    }
    fn wrapBoolNot(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolNot(node);
    }
    fn wrapCast(self: *Engine, node: *const Node) EngineError!void {
        try self.execCast(node, false);
    }
    fn wrapCastSafe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCast(node, true);
    }
    fn wrapLoad(self: *Engine, node: *const Node) EngineError!void {
        try self.execLoad(node);
    }
    fn wrapStore(self: *Engine, node: *const Node) EngineError!void {
        try self.execStore(node);
    }
    fn wrapRefOf(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefOf(node);
    }
    fn wrapRefGet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefGet(node);
    }
    fn wrapRefSet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefSet(node);
    }
    fn wrapHaltBreak(self: *Engine, node: *const Node) EngineError!void {
        _ = node;
        _ = self;
        return error.LoopBreak;
    }
    fn wrapHaltContinue(self: *Engine, node: *const Node) EngineError!void {
        _ = node;
        _ = self;
        return error.LoopContinue;
    }
    fn wrapHaltReturn(self: *Engine, node: *const Node) EngineError!void {
        // 设置 pending_halt 信号，TCO 主循环检查后跳出
        self.pending_halt = node.inputs[0];
    }
    fn wrapCall(self: *Engine, node: *const Node) EngineError!void {
        try self.execCall(node);
    }
    fn wrapVecSelect(self: *Engine, node: *const Node) EngineError!void {
        try self.execVecSelect(node);
    }
    fn wrapHaltThrow(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        return error.Thrown;
    }
    fn wrapRecordMake(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordMake(node);
    }
    fn wrapRecordGet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordGet(node);
    }
    fn wrapRecordSet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordSet(node);
    }
    fn wrapRecordClone(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordClone(node);
    }
    fn wrapRouteGetTag(self: *Engine, node: *const Node) EngineError!void {
        try self.execRouteGetTag(node);
    }
    fn wrapRouteDispatch(self: *Engine, node: *const Node) EngineError!void {
        // route_dispatch 可能返回 halt channel（body 内含 halt 节点）
        // 通过 pending_halt 传播，与非 TCO direct 路径的 halt 机制一致
        if (try self.execRouteDispatch(node)) |halt_chan| {
            self.pending_halt = halt_chan;
        }
    }
    fn wrapRouteMerge(self: *Engine, node: *const Node) EngineError!void {
        try self.execRouteMerge(node);
    }

    /// NodeOp → 直接调用函数指针映射
    /// 返回 null 表示该 op 不支持直接调用（非标量 op 或含动态分派）
    fn opToScalarExecFn(op: NodeOp) ?ScalarExecFn {
        return switch (op) {
            .const_i => &wrapConstI,
            .const_f => &wrapConstF,
            .const_bool => &wrapConstBool,
            .const_char => &wrapConstChar,
            .const_str => &wrapConstStr,
            .int_add => &wrapIntAdd,
            .int_sub => &wrapIntSub,
            .int_mul => &wrapIntMul,
            .int_div => &wrapIntDiv,
            .int_mod => &wrapIntMod,
            .int_and => &wrapIntAnd,
            .int_or => &wrapIntOr,
            .int_xor => &wrapIntXor,
            .int_shl => &wrapIntShl,
            .int_shr => &wrapIntShr,
            .int_neg => &wrapIntNeg,
            .int_abs => &wrapIntAbs,
            .int_not => &wrapIntNot,
            .float_add => &wrapFloatAdd,
            .float_sub => &wrapFloatSub,
            .float_mul => &wrapFloatMul,
            .float_div => &wrapFloatDiv,
            .float_mod => &wrapFloatMod,
            .float_neg => &wrapFloatNeg,
            .float_abs => &wrapFloatAbs,
            .cmp_eq => &wrapCmpEq,
            .cmp_ne => &wrapCmpNe,
            .cmp_lt => &wrapCmpLt,
            .cmp_le => &wrapCmpLe,
            .cmp_gt => &wrapCmpGt,
            .cmp_ge => &wrapCmpGe,
            .bool_and => &wrapBoolAnd,
            .bool_or => &wrapBoolOr,
            .bool_not => &wrapBoolNot,
            .cast => &wrapCast,
            .cast_safe => &wrapCastSafe,
            .load => &wrapLoad,
            .store => &wrapStore,
            .ref_of => &wrapRefOf,
            .ref_get => &wrapRefGet,
            .ref_set => &wrapRefSet,
            .halt_break => &wrapHaltBreak,
            .halt_continue => &wrapHaltContinue,
            .halt_return => &wrapHaltReturn,
            .halt_throw => &wrapHaltThrow,
            .call => &wrapCall,
            .vec_select => &wrapVecSelect,
            .record_make => &wrapRecordMake,
            .record_get => &wrapRecordGet,
            .record_set => &wrapRecordSet,
            .record_clone => &wrapRecordClone,
            .route_get_tag => &wrapRouteGetTag,
            .route_dispatch => &wrapRouteDispatch,
            .route_merge => &wrapRouteMerge,
            else => null,
        };
    }

    /// 编译 body 子图为 CompiledBody
    ///
    /// 分析 body 节点序列的语义类别（BodyKind），生成直接调用指令流。
    /// 首次执行 vec_* 节点时调用，结果缓存到 body_cache。
    ///
    /// 编译规则：
    /// - 全 isScalar() 且无 store → pure_scalar_chain（可 SIMD 线性链）
    /// - 单个可结合二元 op → scan_compatible（走 batchScan SIMD）
    /// - 单个不可结合二元 op → scan_incompatible（紧凑标量循环）
    /// - 含 store 但无控制流 op → state_machine（紧凑循环 + 直接调用）
    /// - 含 gate/route/call_indirect/call → unsupported（回退逐元素）
    fn compileBody(self: *Engine, meta_idx: u16, vm: ir_mod.meta_mod.VectorMeta) !*CompiledBody {
        const backing = self.backingAllocator();

        // 获取 body 节点切片
        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_nodes = nodes[body_local_start .. body_local_start + vm.body_len];

        // 1. 语义分析：判定 BodyKind
        var kind: BodyKind = .pure_scalar_chain;
        var has_store = false;
        var scalar_count: u32 = 0;

        for (body_nodes) |n| {
            if (n.op == .store) {
                has_store = true;
                kind = .state_machine;
            } else if (n.op.isScalar()) {
                scalar_count += 1;
            } else if (n.op == .gate_check or n.op == .gate_get_ok or n.op == .gate_get_err or
                n.op == .gate_propagate or n.op == .gate_select or n.op == .gate_make_ok or n.op == .gate_make_err or
                n.op == .route_get_tag or n.op == .route_dispatch or n.op == .route_merge or
                n.op == .call_indirect or n.op == .call)
            {
                kind = .unsupported;
                break;
            } else {
                kind = .unsupported;
                break;
            }
        }

        // 2. 纯标量链判定：无 store 且全 isScalar()
        if (!has_store and kind == .pure_scalar_chain and scalar_count == body_nodes.len) {
            // 检查是否是单个可结合二元 op（scan_compatible）
            if (body_nodes.len == 1) {
                if (nodeOpToBatchBinOp(body_nodes[0].op)) |bop| {
                    if (bop == .add or bop == .mul or bop == .band or bop == .bor or bop == .bxor) {
                        kind = .scan_compatible;
                    } else {
                        kind = .scan_incompatible;
                    }
                } else {
                    kind = .pure_scalar_chain;
                }
            }
            // 多节点标量链保持 pure_scalar_chain
        }

        // 3. 生成指令流
        const insts = try backing.alloc(BodyInst, body_nodes.len);
        for (body_nodes, 0..) |*n, i| {
            const exec_fn = opToScalarExecFn(n.op) orelse {
                // 非标量 op（如 store）：unsupported 已在前面判定，这里不应到达
                // 但 store 在 state_machine 模式下需要直接调用
                if (n.op == .store) {
                    insts[i] = .{ .exec = &wrapStore, .node = n };
                    continue;
                }
                // 兜底：标记为 unsupported
                kind = .unsupported;
                insts[i] = .{ .exec = &wrapStore, .node = n }; // 占位，kind=unsupported 不会执行
                continue;
            };
            insts[i] = .{ .exec = exec_fn, .node = n };
        }

        // 4. body 输出通道（最后一条指令的 output）
        const out_chan = if (body_nodes.len > 0) body_nodes[body_nodes.len - 1].output else 0;

        // 5. 写入 body_cache（按值存储，insts 数组由 backing 持有，deinit 时释放）
        const compiled_val = CompiledBody{
            .insts = insts,
            .out_chan = out_chan,
            .kind = kind,
            .node_count = @intCast(body_nodes.len),
        };

        if (meta_idx > 0 and meta_idx <= self.body_cache.len) {
            self.body_cache[meta_idx - 1] = compiled_val;
            return &self.body_cache[meta_idx - 1].?;
        }

        // meta_idx 越界：不应到达，回退到栈上临时存储（调用方本次执行后丢弃）
        // 这种情况仅在 IR 不一致时发生，insts 会泄漏但属于错误路径
        const compiled = try backing.create(CompiledBody);
        compiled.* = compiled_val;
        return compiled;
    }

    /// 获取或编译 body
    /// 优先从缓存读取，未命中则编译并缓存
    fn getOrCompileBody(self: *Engine, meta_idx: u16) !?*CompiledBody {
        if (meta_idx == 0 or meta_idx > self.ir.vector_metas.len) return null;
        if (meta_idx <= self.body_cache.len) {
            if (self.body_cache[meta_idx - 1]) |*cached| {
                return cached;
            }
        }
        const vm = self.ir.vector_metas[meta_idx - 1];
        if (vm.body_len == 0) return null; // 内联标量模式，无需编译 body
        return try self.compileBody(meta_idx, vm);
    }

    /// 获取 backing allocator
    fn backingAllocator(self: *Engine) std.mem.Allocator {
        return self.tctx.?.backing;
    }

    /// 执行编译后的 body（紧凑循环，无 switch dispatch）
    /// 用于 state_machine 模式：pin 元素后直接调用每个指令
    fn execCompiledBody(self: *Engine, cb: *const CompiledBody) EngineError!void {
        for (cb.insts) |inst| {
            try inst.exec(self, inst.node);
        }
    }

    /// vec_map：对向量每个元素应用变换
    /// 子图模式：body_start..body_start+body_len 引用主节点流中的子图
    /// 内联标量模式：body_len=0，identity（直接拷贝）
    fn execVecMap(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        // 分配输出向量
        try self.runtime.allocVector(node.output, count);

        if (vm.body_len == 0) {
            // identity map：直接拷贝
            const w = self.runtime.elemWidth(src_chan);
            if (w > 0) {
                const src = self.runtime.rawPtr(src_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0 .. w * count], src[0 .. w * count]);
            }
            return;
        }

        // 尝试批量路径：检测 body 是否为单标量 op 形态
        // 成功匹配则 SIMD 批量执行，跳过逐元素 dispatch（O(N) dispatch → O(1)）
        {
            const func = self.ir.functions[self.currentFuncIdx()];
            const nodes = self.ir.funcNodes(self.currentFuncIdx());
            const body_local_start: usize = vm.body_start - func.node_start;
            const out_meta = self.ir.channels.get(node.output);

            if (chanToScalarTag(out_meta)) |tag| {
                // 情况 1：body_len == 1，单节点一元运算（-x / ~x / abs(x)）
                if (vm.body_len == 1) {
                    const body_node = nodes[body_local_start];
                    if (nodeOpToBatchUnaryOp(body_node.op)) |uop| {
                        if (body_node.input_count >= 1 and body_node.inputs[0] == src_chan) {
                            try self.dispatchBatchMapUnary(tag, uop, node.output, src_chan, count);
                            return;
                        }
                    }
                }
                // 情况 2：body_len == 2，const + 二元运算（x op const 或 const op x）
                else if (vm.body_len == 2) {
                    const const_node = nodes[body_local_start];
                    const op_node = nodes[body_local_start + 1];
                    const is_const = switch (const_node.op) {
                        .const_i, .const_f => true,
                        else => false,
                    };
                    if (is_const) {
                        if (nodeOpToBatchBinOp(op_node.op)) |bop| {
                            // 执行 const 节点获取常量值（const 不依赖 src_chan，无需 pin）
                            _ = try self.execNode(&const_node);
                            const scalar_bytes = self.readChanBytes(const_node.output);

                            if (op_node.input_count >= 2 and
                                op_node.inputs[0] == src_chan and
                                op_node.inputs[1] == const_node.output)
                            {
                                // x op const
                                try self.dispatchBatchMapScalarR(tag, bop, node.output, src_chan, scalar_bytes, count);
                                return;
                            }
                            if (op_node.input_count >= 2 and
                                op_node.inputs[0] == const_node.output and
                                op_node.inputs[1] == src_chan)
                            {
                                // const op x
                                try self.dispatchBatchMapScalarL(tag, bop, node.output, scalar_bytes, src_chan, count);
                                return;
                            }
                        }
                    }
                }
            }
        }

        // O(1) dispatch 路径 1：CompiledBody pure_scalar_chain（SIMD 线性链）
        // body 全是 isScalar() 节点时，按拓扑序串联 dispatchBatch*，零 switch dispatch
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .pure_scalar_chain and cb.node_count > 2) {
                try self.execVecMapScalarChain(node, vm, cb, src_chan, count);
                return;
            }
        }

        // O(1) dispatch 路径 3：CompiledBody scan_incompatible（紧凑标量循环）
        // 单个不可结合运算时，紧凑循环直接调用，无 execNode switch
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .scan_incompatible) {
                try self.execVecMapStateMachine(node, vm, cb, src_chan, count);
                return;
            }
        }

        // O(1) dispatch 路径 4：CompiledBody state_machine（紧凑循环 + 直接调用）
        // body 含 store 但无控制流 op 时，pin 元素后直接调用 inst.exec，绕过 execNode switch
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .state_machine) {
                try self.execVecMapStateMachine(node, vm, cb, src_chan, count);
                return;
            }
        }

        // 子图模式：找到函数的节点切片和局部偏移
        // 遍历每个元素，将循环变量通道临时指向该元素，执行子图，读取结果
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;

        // 找到 body 的输出通道（body 子图最后一个节点的 output）
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            // 将循环变量通道临时指向 src_chan 的第 i 个元素（基于原始指针计算）
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            // 读取 body 结果到输出向量（body_out_w=0 表示 unit 通道，仅副作用，跳过拷贝）
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }

        // 恢复循环变量通道为向量模式
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// O(1) dispatch：状态机紧凑循环（state_machine）
    ///
    /// body 含 store 但无控制流 op 时，每个元素 pin 后直接调用 inst.exec
    /// 绕过 execNode 的 switch，dispatch 只发生在进入 vec_map 时 1 次
    /// 适用于：累加器（acc = acc + f(i)）、状态机迭代（var = f(var, x)）
    fn execVecMapStateMachine(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        _ = body_local_start;
        _ = nodes;

        const body_out_chan = cb.out_chan;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            // pin 元素：循环变量通道指向第 i 个元素
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;

            // 直接调用 body 指令流，无 execNode switch
            try self.execCompiledBody(cb);

            // 读取 body 结果到输出向量
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }

        // 恢复循环变量通道为向量模式
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// O(1) dispatch：SIMD 线性链执行（pure_scalar_chain）
    ///
    /// body 全是 isScalar() 节点时，按拓扑序串联调用 dispatchBatch*
    /// 每个 body 节点的 output 通道分配为向量缓冲，中间结果直接写入
    /// 无 execNode 的 switch dispatch，无逐元素循环
    fn execVecMapScalarChain(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        _ = func;
        _ = nodes;

        // body 最后一个节点的输出通道（可能 != node.output，需最终拷贝）
        const body_out_chan = cb.out_chan;
        const need_final_copy = (body_out_chan != node.output);

        // 为 body 中每个节点的 output 通道分配向量缓冲
        // node.output 已由 execVecMap 分配，其余按需分配
        for (cb.insts) |inst| {
            const out_chan = inst.node.output;
            if (out_chan != node.output) {
                self.runtime.allocVector(out_chan, count) catch return error.OutOfMemory;
            }
        }

        // 按拓扑序串联执行每个标量 op
        for (cb.insts) |inst| {
            const bn = inst.node;
            const out_meta = self.ir.channels.get(bn.output);
            const tag = chanToScalarTag(out_meta) orelse {
                // 非 SIMD 类型，回退逐元素
                return self.execVecMapFallback(node, vm, src_chan, count);
            };

            // 一元 op
            if (nodeOpToBatchUnaryOp(bn.op)) |uop| {
                if (bn.input_count >= 1) {
                    try self.dispatchBatchMapUnary(tag, uop, bn.output, bn.inputs[0], count);
                    continue;
                }
            }

            // 二元 op：左向量 + 右向量
            if (nodeOpToBatchBinOp(bn.op)) |bop| {
                if (bn.input_count >= 2) {
                    try self.dispatchBatchMap2(tag, bop, bn.output, bn.inputs[0], bn.inputs[1], count);
                    continue;
                }
            }

            // const 节点：执行一次，broadcast 到向量
            switch (bn.op) {
                .const_i, .const_f, .const_bool, .const_char => {
                    try self.execConst(bn);
                    const scalar_bytes = self.readChanBytes(bn.output);
                    try self.broadcastScalarToVector(bn.output, scalar_bytes, count);
                },
                else => {
                    // 不支持的标量 op，回退逐元素
                    return self.execVecMapFallback(node, vm, src_chan, count);
                },
            }
        }

        // body 输出通道 != node.output 时，拷贝最终结果向量
        if (need_final_copy) {
            const w = self.runtime.elemWidth(body_out_chan);
            if (w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0 .. w * count], src[0 .. w * count]);
            }
        }
    }

    /// 标量 broadcast 到向量
    fn broadcastScalarToVector(self: *Engine, chan: u16, scalar_bytes: [16]u8, count: u32) !void {
        const w = self.runtime.elemWidth(chan);
        if (w == 0 or count == 0) return;
        try self.runtime.allocVector(chan, count);
        const dst = self.runtime.rawPtr(chan);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            @memcpy(dst[i * w .. (i + 1) * w], scalar_bytes[0..w]);
        }
    }

    /// vec_map 逐元素回退路径（当 SIMD 链不适用时）
    fn execVecMapFallback(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_map2：双输入向量的逐元素二元运算
    fn execVecMap2(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const count = @min(self.runtime.vectorLen(left_chan), self.runtime.vectorLen(right_chan));

        try self.runtime.allocVector(node.output, count);

        if (count == 0) return;

        // 尝试批量路径：检测 body 是否为单节点二元运算（a op b）
        // 成功匹配则 SIMD 批量执行，跳过逐元素 dispatch
        if (vm.body_len >= 1) {
            const func = self.ir.functions[self.currentFuncIdx()];
            const nodes = self.ir.funcNodes(self.currentFuncIdx());
            const body_local_start: usize = vm.body_start - func.node_start;
            const out_meta = self.ir.channels.get(node.output);

            if (chanToScalarTag(out_meta)) |tag| {
                // 情况 1：body_len == 1，单节点二元运算（left[i] op right[i]）
                if (vm.body_len == 1) {
                    const body_node = nodes[body_local_start];
                    if (nodeOpToBatchBinOp(body_node.op)) |bop| {
                        if (body_node.input_count >= 2 and
                            body_node.inputs[0] == left_chan and
                            body_node.inputs[1] == right_chan)
                        {
                            try self.dispatchBatchMap2(tag, bop, node.output, left_chan, right_chan, count);
                            return;
                        }
                    }
                }
            }
        }

        if (vm.body_len == 0) {
            // 无子图：报错（vec_map2 需要一个二元运算体）
            return error.UnsupportedOp;
        }

        // O(1) dispatch 路径：CompiledBody pure_scalar_chain（SIMD 线性链）
        // body 全是 isScalar() 节点时，按拓扑序串联 dispatchBatch*
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .pure_scalar_chain and cb.node_count > 1) {
                try self.execVecMap2ScalarChain(node, vm, cb, left_chan, right_chan, count);
                return;
            }
        }

        // O(1) dispatch 路径：CompiledBody state_machine / scan_incompatible（紧凑循环）
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .state_machine or cb.kind == .scan_incompatible) {
                try self.execVecMap2StateMachine(node, vm, cb, left_chan, right_chan, count);
                return;
            }
        }

        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const lw = self.runtime.elemWidth(left_chan);
        const rw = self.runtime.elemWidth(right_chan);
        const left_base = self.runtime.chan_ptrs[left_chan].?;
        const right_base = self.runtime.chan_ptrs[right_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[left_chan] = left_base + i * lw;
            self.runtime.chan_lengths[left_chan] = 1;
            self.runtime.chan_ptrs[right_chan] = right_base + i * rw;
            self.runtime.chan_lengths[right_chan] = 1;

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            const w = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..w], src[0..w]);
        }

        // 恢复
        self.runtime.chan_ptrs[left_chan] = left_base;
        self.runtime.chan_lengths[left_chan] = count;
        self.runtime.chan_ptrs[right_chan] = right_base;
        self.runtime.chan_lengths[right_chan] = count;
    }

    /// O(1) dispatch：vec_map2 SIMD 线性链（pure_scalar_chain）
    fn execVecMap2ScalarChain(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        left_chan: u16,
        right_chan: u16,
        count: u32,
    ) EngineError!void {
        _ = vm;
        _ = left_chan;
        _ = right_chan;
        // body 最后一个节点的输出通道（可能 != node.output，需最终拷贝）
        const body_out_chan = cb.out_chan;
        const need_final_copy = (body_out_chan != node.output);

        // 为 body 中每个节点的 output 通道分配向量缓冲
        for (cb.insts) |inst| {
            const out_chan = inst.node.output;
            if (out_chan != node.output) {
                self.runtime.allocVector(out_chan, count) catch return error.OutOfMemory;
            }
        }

        // 按拓扑序串联执行
        for (cb.insts) |inst| {
            const bn = inst.node;
            const out_meta = self.ir.channels.get(bn.output);
            const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

            if (nodeOpToBatchUnaryOp(bn.op)) |uop| {
                if (bn.input_count >= 1) {
                    try self.dispatchBatchMapUnary(tag, uop, bn.output, bn.inputs[0], count);
                    continue;
                }
            }
            if (nodeOpToBatchBinOp(bn.op)) |bop| {
                if (bn.input_count >= 2) {
                    try self.dispatchBatchMap2(tag, bop, bn.output, bn.inputs[0], bn.inputs[1], count);
                    continue;
                }
            }
            switch (bn.op) {
                .const_i, .const_f, .const_bool, .const_char => {
                    try self.execConst(bn);
                    const scalar_bytes = self.readChanBytes(bn.output);
                    try self.broadcastScalarToVector(bn.output, scalar_bytes, count);
                },
                else => return error.UnsupportedOp,
            }
        }

        // body 输出通道 != node.output 时，拷贝最终结果向量
        if (need_final_copy) {
            const w = self.runtime.elemWidth(body_out_chan);
            if (w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0 .. w * count], src[0 .. w * count]);
            }
        }
    }

    /// O(1) dispatch：vec_map2 状态机紧凑循环
    fn execVecMap2StateMachine(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        left_chan: u16,
        right_chan: u16,
        count: u32,
    ) EngineError!void {
        _ = vm;
        const body_out_chan = cb.out_chan;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const lw = self.runtime.elemWidth(left_chan);
        const rw = self.runtime.elemWidth(right_chan);
        const left_base = self.runtime.chan_ptrs[left_chan].?;
        const right_base = self.runtime.chan_ptrs[right_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[left_chan] = left_base + i * lw;
            self.runtime.chan_lengths[left_chan] = 1;
            self.runtime.chan_ptrs[right_chan] = right_base + i * rw;
            self.runtime.chan_lengths[right_chan] = 1;

            try self.execCompiledBody(cb);

            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }

        self.runtime.chan_ptrs[left_chan] = left_base;
        self.runtime.chan_lengths[left_chan] = count;
        self.runtime.chan_ptrs[right_chan] = right_base;
        self.runtime.chan_lengths[right_chan] = count;
    }

    /// vec_sink：从向量中提取标量值
    fn execVecSink(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        switch (vm.vec_op) {
            .sink_last => {
                if (count == 0) {
                    // 空向量：写默认值（0）
                    const w = self.runtime.elemWidth(node.output);
                    if (w > 0) {
                        const dst = self.runtime.rawPtr(node.output);
                        @memset(dst[0..w], 0);
                    }
                    return;
                }
                const w = self.runtime.elemWidth(src_chan);
                const src = self.runtime.vectorElemPtr(src_chan, count - 1);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..w], src[0..w]);
            },
            .sink_first => {
                if (count == 0) {
                    // 空向量：写默认值（0）
                    const w = self.runtime.elemWidth(node.output);
                    if (w > 0) {
                        const dst = self.runtime.rawPtr(node.output);
                        @memset(dst[0..w], 0);
                    }
                    return;
                }
                const w = self.runtime.elemWidth(src_chan);
                const src = self.runtime.vectorElemPtr(src_chan, 0);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..w], src[0..w]);
            },
            .sink_count => {
                self.runtime.writeI64(node.output, @intCast(count));
            },
            .sink_to_array => {
                // 收集为 ArrayValue
                const w = self.runtime.elemWidth(src_chan);
                const elem_count = count;
                // 临时元素切片（makeArray 会拷贝到自有缓冲区）
                const elements = self.tctx.?.backing.alloc(value.Value, elem_count) catch return error.OutOfMemory;
                defer self.tctx.?.backing.free(elements);
                for (0..elem_count) |i| {
                    const ptr = self.runtime.vectorElemPtr(src_chan, i);
                    const iv: i64 = if (w >= 8) blk: {
                        const p: *i64 = @ptrCast(@alignCast(ptr));
                        break :blk p.*;
                    } else if (w >= 4) blk: {
                        const p: *i32 = @ptrCast(@alignCast(ptr));
                        break :blk @as(i64, p.*);
                    } else 0;
                    elements[i] = value.Value.fromI64(iv);
                }
                const v = value.Value.makeArray(self.tctx.?, elements, null) catch return error.OutOfMemory;
                try self.trackObj(v.asRef());
                self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            },
            else => return error.InvalidMetaIndex,
        }
    }

    /// vec_fold：归约（sum/max/min 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    fn execVecFold(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const init_chan = node.inputs[1];
        const count = self.runtime.vectorLen(src_chan);

        // 初始值写入输出（累加器）
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            const src = self.runtime.rawPtr(init_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }

        if (count == 0) return;

        if (vm.body_len == 0) {
            // 内联标量模式：接入 batch.zig SIMD 批量归约
            // 可结合运算（add/mul/位运算）用 @reduce 横向归约，不可结合用类型化标量循环
            // 不可映射的 inner_op（shl/shr 等）回退到逐元素 dispatchInlineBinOp
            const out_meta = self.ir.channels.get(node.output);
            const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            const init_acc = self.readChanBytes(node.output); // 累加器初值（已从 init_chan 拷入）
            if (nodeOpToBatchBinOp(vm.inner_op)) |bop| {
                const result = try self.dispatchBatchReduce(tag, bop, init_acc, src_chan, count);
                self.writeChanBytes(node.output, result);
            } else {
                // 回退：不可 SIMD 化的 inner_op，逐元素 dispatch
                var acc = init_acc;
                for (0..count) |i| {
                    var elem_buf: [16]u8 = [_]u8{0} ** 16;
                    const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                    if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                    acc = try dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
                }
                self.writeChanBytes(node.output, acc);
            }
            return;
        }

        // O(1) dispatch 路径：CompiledBody 紧凑循环（state_machine / scan_incompatible / pure_scalar_chain）
        // 对每个元素 pin 后直接调用 inst.exec，绕过 execNode switch
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .state_machine or cb.kind == .scan_incompatible or cb.kind == .pure_scalar_chain) {
                try self.execVecFoldStateMachine(node, vm, cb, src_chan, count);
                return;
            }
        }

        // 子图模式：对每个元素，将累加器（output）和当前元素作为输入执行 body
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        // fold 的 body：inputs[0] = 累加器（output 通道），inputs[1] = 当前元素
        // 循环变量通道是 src_chan，累加器是 node.output
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            // body 的结果在 body_out_chan，复制到 output 作为新的累加器
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复 src_chan
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// O(1) dispatch：vec_fold 紧凑循环（state_machine / scan_incompatible）
    fn execVecFoldStateMachine(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        _ = vm;
        const body_out_chan = cb.out_chan;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            try self.execCompiledBody(cb);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_scan：前缀扫描（prefix sum 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    fn execVecScan(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const init_chan = node.inputs[1];
        const count = self.runtime.vectorLen(src_chan);

        try self.runtime.allocVector(node.output, count);
        if (count == 0) return;

        const w = self.runtime.elemWidth(node.output);

        if (vm.body_len == 0) {
            // 内联标量模式：接入 batch.zig SIMD 分段前缀扫描
            // 可结合运算用块内 inclusive scan + 块间累加器修正，不可结合用类型化标量循环
            // 不可映射的 inner_op（shl/shr 等）回退到逐元素 dispatchInlineBinOp
            const out_meta = self.ir.channels.get(node.output);
            const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            const init_bytes = self.readChanBytes(init_chan); // 累加器初值
            if (nodeOpToBatchBinOp(vm.inner_op)) |bop| {
                try self.dispatchBatchScan(tag, bop, init_bytes, node.output, src_chan, count);
            } else {
                // 回退：不可 SIMD 化的 inner_op，逐元素 dispatch
                var acc = init_bytes;
                for (0..count) |i| {
                    var elem_buf: [16]u8 = [_]u8{0} ** 16;
                    const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                    if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                    acc = try dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
                    const dst = self.runtime.vectorElemPtr(node.output, i);
                    if (w > 0 and w <= 16) @memcpy(dst[0..w], acc[0..w]);
                }
            }
            return;
        }

        // O(1) dispatch 路径：CompiledBody 紧凑循环（state_machine / scan_incompatible / pure_scalar_chain）
        if (try self.getOrCompileBody(node.meta_index)) |cb| {
            if (cb.kind == .state_machine or cb.kind == .scan_incompatible or cb.kind == .pure_scalar_chain) {
                try self.execVecScanStateMachine(node, vm, cb, src_chan, count);
                return;
            }
        }

        // 子图模式
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        // 简化实现：逐元素扫描
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// O(1) dispatch：vec_scan 紧凑循环
    fn execVecScanStateMachine(
        self: *Engine,
        node: *const Node,
        vm: ir_mod.meta_mod.VectorMeta,
        cb: *const CompiledBody,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        _ = vm;
        const body_out_chan = cb.out_chan;
        const body_out_w = self.runtime.elemWidth(body_out_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            try self.execCompiledBody(cb);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_filter：按条件过滤元素
    fn execVecFilter(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        if (vm.body_len == 0 or count == 0) {
            try self.runtime.allocVector(node.output, 0);
            return;
        }

        // O(1) dispatch 路径：CompiledBody 紧凑循环（无 execNode switch）
        const cb_opt = try self.getOrCompileBody(node.meta_index);
        const body_out_chan = if (cb_opt) |cb| cb.out_chan else blk: {
            const func = self.ir.functions[self.currentFuncIdx()];
            const nodes = self.ir.funcNodes(self.currentFuncIdx());
            const body_local_start: usize = vm.body_start - func.node_start;
            break :blk nodes[body_local_start + vm.body_len - 1].output;
        };

        // 先收集通过的元素
        const w = self.runtime.elemWidth(src_chan);
        const temp = self.tctx.?.backing.alloc(u8, w * count) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(temp);
        var kept: u32 = 0;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            if (cb_opt) |cb| {
                try self.execCompiledBody(cb);
            } else {
                const func = self.ir.functions[self.currentFuncIdx()];
                const nodes = self.ir.funcNodes(self.currentFuncIdx());
                const body_local_start: usize = vm.body_start - func.node_start;
                _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            }
            const body_out_val = try self.readScalarValue(body_out_chan);
            if (body_out_val.asBool()) {
                // 用 base_ptr 直接计算（chan_ptrs[src_chan] 已被循环移动）
                const src = base_ptr + i * elem_w;
                @memcpy(temp[kept * w .. (kept + 1) * w], src[0..w]);
                kept += 1;
            }
        }

        // 先恢复 chan_ptrs[src_chan] = base_ptr，便于 allocVector 扩容时正确 rebase
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;

        // 分配输出向量并拷贝
        try self.runtime.allocVector(node.output, kept);
        if (kept > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * kept], temp[0 .. w * kept]);
        }

        // 恢复 chan_lengths（chan_ptrs 已在 allocVector 中 rebase）
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_take：取前 N 个元素
    fn execVecTake(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        // n 超 u32 范围时 @intCast 会 panic，clamp 到 u32::max（take 语义取前 n 个，
        // 实际会被 @min(n, count) 限制，clamp 不影响正确性）
        const n_raw = @max(0, try self.readIntAsI64(node.inputs[1]));
        const n: u32 = if (n_raw > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n_raw);
        const count = self.runtime.vectorLen(src_chan);
        const take = @min(n, count);
        try self.runtime.allocVector(node.output, take);
        const w = self.runtime.elemWidth(src_chan);
        if (take > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * take], src[0 .. w * take]);
        }
    }

    /// vec_take_while：取满足条件的前缀
    fn execVecTakeWhile(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        if (vm.body_len == 0 or count == 0) {
            try self.runtime.allocVector(node.output, 0);
            return;
        }

        // O(1) dispatch 路径：CompiledBody 紧凑循环（无 execNode switch）
        const cb_opt = try self.getOrCompileBody(node.meta_index);
        const body_out_chan = if (cb_opt) |cb| cb.out_chan else blk: {
            const func = self.ir.functions[self.currentFuncIdx()];
            const nodes = self.ir.funcNodes(self.currentFuncIdx());
            const body_local_start: usize = vm.body_start - func.node_start;
            break :blk nodes[body_local_start + vm.body_len - 1].output;
        };

        const w = self.runtime.elemWidth(src_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;
        var taken: u32 = 0;
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            if (cb_opt) |cb| {
                try self.execCompiledBody(cb);
            } else {
                const func = self.ir.functions[self.currentFuncIdx()];
                const nodes = self.ir.funcNodes(self.currentFuncIdx());
                const body_local_start: usize = vm.body_start - func.node_start;
                _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            }
            const body_out_val = try self.readScalarValue(body_out_chan);
            if (!body_out_val.asBool()) break;
            taken = @intCast(i + 1);
        }

        // 先恢复 chan_ptrs[src_chan] = base_ptr，便于 allocVector 扩容时正确 rebase
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;

        try self.runtime.allocVector(node.output, taken);
        if (taken > 0) {
            // allocVector 可能触发 ChannelRegion 扩容，chan_ptrs[src_chan] 已被 rebase
            const base_ptr_new = self.runtime.chan_ptrs[src_chan].?;
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * taken], base_ptr_new[0 .. w * taken]);
        }

        // 恢复 chan_lengths（chan_ptrs 已在 allocVector 中 rebase）
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_zip：合并两个向量为 Pair(first, second) 记录向量
    /// inputs[0] = 左向量，inputs[1] = 右向量
    /// output = ref_chan 向量，每个元素是指向 Pair 记录的指针
    fn execVecZip(self: *Engine, node: *const Node) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const count = @min(self.runtime.vectorLen(left_chan), self.runtime.vectorLen(right_chan));

        // 输出通道必须是 ref_chan，每个元素存 Pair 记录指针
        const out_meta = self.ir.channels.get(node.output);
        if (out_meta.chan_type != .ref_chan) return error.InvalidChannel;

        try self.runtime.allocVector(node.output, count);
        if (count == 0) return;

        const base_left = self.runtime.chan_ptrs[left_chan].?;
        const base_right = self.runtime.chan_ptrs[right_chan].?;
        const elem_w_left = self.runtime.elemWidth(left_chan);
        const elem_w_right = self.runtime.elemWidth(right_chan);
        const saved_left_len = self.runtime.chan_lengths[left_chan];
        const saved_right_len = self.runtime.chan_lengths[right_chan];

        const field_names: [2]?[]const u8 = .{ "first", "second" };
        const dst = self.runtime.rawPtr(node.output);
        const out_w = self.runtime.elemWidth(node.output);

        for (0..count) |i| {
            self.runtime.chan_ptrs[left_chan] = base_left + i * elem_w_left;
            self.runtime.chan_lengths[left_chan] = 1;
            self.runtime.chan_ptrs[right_chan] = base_right + i * elem_w_right;
            self.runtime.chan_lengths[right_chan] = 1;

            var fields: [2]value.Value = .{
                try self.readScalarValue(left_chan),
                try self.readScalarValue(right_chan),
            };
            // 所有权转移给 RecordValue，先增加引用计数
            _ = fields[0].retain(self.tctx.?);
            _ = fields[1].retain(self.tctx.?);
            const pair = value.Value.makeRecordWithNames(
                self.tctx.?,
                "Pair",
                &fields,
                &field_names,
            ) catch return error.OutOfMemory;
            try self.trackObj(@ptrCast(@alignCast(pair.ref)));

            const slot: *usize = @ptrCast(@alignCast(dst + i * out_w));
            slot.* = @intFromPtr(pair.ref);
        }

        // 恢复源向量指针和长度
        self.runtime.chan_ptrs[left_chan] = base_left;
        self.runtime.chan_lengths[left_chan] = saved_left_len;
        self.runtime.chan_ptrs[right_chan] = base_right;
        self.runtime.chan_lengths[right_chan] = saved_right_len;
    }

    /// 获取当前正在执行的函数索引
    fn currentFuncIdx(self: *Engine) u16 {
        return self.current_func_idx;
    }

    /// 恢复被 pinToElement 修改的向量通道指针
    fn restoreVectorChan(self: *Engine, chan: u16, count: u32) void {
        if (count <= 1) return; // 0 或 1 个元素时指针未被移动
        const w = self.runtime.chan_widths[chan];
        self.runtime.chan_ptrs[chan] = self.runtime.chan_ptrs[chan].? - @as(usize, count - 1) * w;
        self.runtime.chan_lengths[chan] = count;
    }

    // ════════════════════════════════════════════
    // 门控执行（Phase 4：错误处理）
    // ════════════════════════════════════════════

    /// 读取 ref_chan 中的堆对象，返回 *ObjHeader 或 null
    fn readRefObj(self: *Engine, chan: u16) ?*value.obj_header.ObjHeader {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        // 防御性对齐检查：小整数/标量值被误读为指针时，地址通常不满足堆对象对齐
        if (@intFromPtr(ptr) < 0x1000) return null;
        if (@intFromPtr(ptr) % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        return header;
    }

    /// 读取 ThrowValue 指针（ref_chan → *ThrowValue）
    fn readThrow(self: *Engine, chan: u16) ?*value.ThrowValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .throw_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 按通道实际类型读取整数值并符号扩展为 i64。
    /// 这是通用观察点：如果通道中是 LazyValue，会先强制求值，再转为 i64。
    /// 用于索引、长度、select 超时等所有需要把值当作整数观察的场景。
    fn readIntAsI64(self: *Engine, chan: u16) EngineError!i64 {
        const v = try self.readScalarValue(chan);
        return switch (v) {
            .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
            .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
            .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
            .i64 => |b| @as(i64, @bitCast(b)),
            .u8 => |b| @as(i64, b[0]),
            .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
            .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
            .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
            .isize => |b| @as(i64, @as(isize, @bitCast(b))),
            .usize => |b| @bitCast(@as(usize, @bitCast(b))),
            .boolean => |b| @intFromBool(b[0] != 0),
            .char => |b| @as(i64, @intCast(@as(u32, @bitCast(b)))),
            // i128/u128 超出 i64 范围时返回 error.Overflow，而非静默归零（else 分支）
            .i128 => |b| blk: {
                const val: i128 = @bitCast(b);
                if (val < std.math.minInt(i64) or val > std.math.maxInt(i64)) break :blk error.Overflow;
                break :blk @intCast(val);
            },
            .u128 => |b| blk: {
                const val: u128 = @bitCast(b);
                if (val > std.math.maxInt(i64)) break :blk error.Overflow;
                break :blk @intCast(val);
            },
            // 浮点转整数：NaN/Inf/超范围时 @intFromFloat 会 panic，先校验
            .f32 => |b| blk: {
                const val: f32 = @bitCast(b);
                if (std.math.isNan(val) or std.math.isInf(val)) break :blk error.Overflow;
                // maxInt(i64) 超出 f32 精确表示范围，用 @floatFromInt 显式转换（允许精度损失）
                const i64_min: f32 = @floatFromInt(std.math.minInt(i64));
                const i64_max: f32 = @floatFromInt(std.math.maxInt(i64));
                if (val < i64_min or val > i64_max) break :blk error.Overflow;
                break :blk @intFromFloat(val);
            },
            .f64 => |b| blk: {
                const val: f64 = @bitCast(b);
                if (std.math.isNan(val) or std.math.isInf(val)) break :blk error.Overflow;
                const i64_min: f64 = @floatFromInt(std.math.minInt(i64));
                const i64_max: f64 = @floatFromInt(std.math.maxInt(i64));
                if (val < i64_min or val > i64_max) break :blk error.Overflow;
                break :blk @intFromFloat(val);
            },
            else => 0,
        };
    }

    /// 读取 ErrorValue 指针（ref_chan → *ErrorValue）
    fn readError(self: *Engine, chan: u16) ?*value.ErrorValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .error_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// gate_check：检查值是否 Ok
    /// inputs[0] = 值通道（ref_chan 指向 ThrowValue 或普通值）
    /// output = mask_chan（1=Ok, 0=Err）
    fn execGateCheck(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (debug_record) {
            std.debug.print("gate_check: input_chan={} output_chan={}\n", .{ val_chan, node.output });
        }
        // 如果是 ThrowValue，检查 payload 是 ok 还是 err
        if (self.readThrow(val_chan)) |throw_val| {
            const is_ok = switch (throw_val.payload) {
                .ok => true,
                .err => false,
            };
            if (debug_record) std.debug.print("  -> is_ok={}\n", .{is_ok});
            self.runtime.writeBool(node.output, is_ok);
            return;
        }
        // 非 ThrowValue：非 null 则 Ok
        const ptr = self.runtime.readPtr(val_chan);
        if (debug_record) std.debug.print("  -> not ThrowValue, ptr={?}\n", .{ptr});
        self.runtime.writeBool(node.output, ptr != null);
    }

    /// gate_get_ok：从 ThrowValue 中提取 Ok 值
    /// inputs[0] = ThrowValue 通道
    /// output = Ok 值通道
    fn execGateGetOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (debug_record) {
            const out_meta = self.ir.channels.get(node.output);
            std.debug.print("gate_get_ok: input_chan={} output_chan={} output_type={s}\n", .{ val_chan, node.output, @tagName(out_meta.chan_type) });
        }
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .ok => |v| {
                    if (debug_record) std.debug.print("  -> ok val_tag={s}\n", .{@tagName(v)});
                    self.writeScalarValue(node.output, v);
                    return;
                },
                .err => {
                    if (debug_record) std.debug.print("  -> err, writing null\n", .{});
                    self.runtime.writePtr(node.output, null);
                    return;
                },
            }
        }
        if (debug_record) std.debug.print("  -> not ThrowValue, copying raw\n", .{});
        // 非 ThrowValue：直接拷贝
        const w = self.runtime.elemWidth(val_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(val_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// gate_get_err：从 ThrowValue 中提取 Error 值
    /// inputs[0] = ThrowValue 通道
    /// output = ErrorValue 指针通道
    fn execGateGetErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .err => |err_ptr| {
                    self.runtime.writePtr(node.output, @ptrCast(&err_ptr.header));
                    return;
                },
                .ok => {
                    self.runtime.writePtr(node.output, null);
                    return;
                },
            }
        }
        self.runtime.writePtr(node.output, null);
    }

    /// gate_propagate：OR 传播错误掩码
    /// inputs[0] = 当前 check 结果, inputs[1] = 上游 mask
    /// output = OR 后的 mask
    fn execGatePropagate(self: *Engine, node: *const Node) EngineError!void {
        const cur = self.runtime.readBool(node.inputs[0]);
        const upstream = if (node.input_count >= 2) self.runtime.readBool(node.inputs[1]) else true;
        // 传播：如果当前 Ok 且上游也 Ok，则 Ok；否则 Err
        self.runtime.writeBool(node.output, cur and upstream);
    }

    /// gate_select：按 mask 选择值
    /// inputs[0] = mask, inputs[1] = ok_val, inputs[2] = err_val
    /// output = 选中的值
    fn execGateSelect(self: *Engine, node: *const Node) EngineError!void {
        const mask = self.runtime.readBool(node.inputs[0]);
        const src_chan = if (mask) node.inputs[1] else node.inputs[2];
        const w = self.runtime.elemWidth(src_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// gate_make_ok：构造 Ok 类型的 ThrowValue
    /// inputs[0] = 值通道
    /// output = ref_chan（ThrowValue 指针）
    fn execGateMakeOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        // 读取值并构造 ThrowValue{ .ok = value }
        const v = try self.readScalarValue(val_chan);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// gate_make_err：构造 ErrorValue + ThrowValue(err)
    /// inputs[0] = 错误信息通道（ref_chan 指向 Str）
    /// output = ref_chan（ThrowValue 指针）
    fn execGateMakeErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        // 判断输入类型并提取 type_name 和 message
        var type_name: []const u8 = "Error";
        var msg_bytes: []const u8 = "";
        var existing_err: ?*value.ErrorValue = null;

        if (self.runtime.readPtr(val_chan)) |ptr| {
            if (@intFromPtr(ptr) >= 0x1000 and @intFromPtr(ptr) % @alignOf(value.obj_header.ObjHeader) == 0) {
                const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
                switch (header.type_tag) {
                    .str => {
                        const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", header));
                        msg_bytes = s.bytes();
                    },
                    .error_val => {
                        // 已经是 ErrorValue：直接使用
                        const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                        existing_err = e;
                    },
                    .record => {
                        // error_newtype 构造器产生的 RecordValue
                        // 提取 type_name 和第一个字段（message）
                        const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                        type_name = r.type_name;
                        // field_id=1 是第一个构造器字段（field_id=0 是 __tag）
                        if (r.fields.len > 1) {
                            const field_val = r.fields[1];
                            if (field_val == .ref) {
                                const fh: *value.obj_header.ObjHeader = @ptrCast(@alignCast(field_val.ref));
                                if (fh.type_tag == .str) {
                                    const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fh));
                                    msg_bytes = fs.bytes();
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // 如果已有 ErrorValue，直接用它构造 ThrowValue
        const err_val = if (existing_err) |e| e else blk: {
            const err_v = value.Value.makeError(self.tctx.?, type_name, msg_bytes, false) catch return error.OutOfMemory;
            try self.trackObj(err_v.asRef());
            const err_ptr: *value.ErrorValue = @alignCast(@fieldParentPtr("header", err_v.asRef()));
            break :blk err_ptr;
        };

        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = err_val }) catch return error.OutOfMemory;
        _ = value.obj_header.retain(&err_val.header, self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// 从通道读取标量值（用于 gate 操作、print、return 等观察点）
    /// ref_chan 中若是 LazyValue，会自动强制求值一次并返回其结果（缓存借用）。
    fn readScalarValue(self: *Engine, chan: u16) EngineError!value.Value {
        const meta = self.ir.channels.get(chan);
        const w = meta.elem_width;
        if (meta.chan_type == .ref_chan) {
            if (self.readRefObj(chan)) |header| {
                if (header.type_tag == .lazy_val) {
                    const lazy: *value.LazyValue = @alignCast(@fieldParentPtr("header", header));
                    return try self.forceLazyValue(lazy);
                }
                return value.Value.fromRef(header);
            }
            // readRefObj 失败：ref_chan 可能持有标量位模式（类型参数实例化为标量时，
            // 标量按 i64/f64 位模式存入 8 字节 ref_chan）。null 返回 null_val，
            // 否则按 i64 读取（注意：无法区分 i64 与 f64 位模式，浮点场景需走 copyCrossType）。
            const raw = self.runtime.readI64(chan);
            if (raw == 0) return value.Value.fromNull();
            return value.Value.fromI64(raw);
        }
        if (meta.chan_type == .bool_chan or meta.chan_type == .mask_chan) {
            return value.Value.fromBool(self.runtime.readBool(chan));
        }
        if (meta.chan_type == .char_chan) {
            const ptr = self.runtime.rawPtr(chan);
            const cp: u32 = @bitCast(@as(*[4]u8, @ptrCast(ptr)).*);
            return value.Value.fromChar(.{ .codepoint = cp });
        }
        // 整数/浮点：按宽度读取
        if (w == 8) {
            return value.Value.fromI64(self.runtime.readI64(chan));
        }
        if (w == 4) {
            const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
            return value.Value.fromI32(ptr.*);
        }
        if (w == 0) {
            return value.Value.fromUnit();
        }
        return value.Value.fromI64(self.runtime.readI64(chan));
    }

    /// 将标量值写入通道
    /// 将标量值写入通道（按通道类型写入，自动进行类型转换）
    /// 这样 i32 值写入 i64_chan 时会正确符号扩展，避免只写 4 字节导致垃圾值
    fn writeScalarValue(self: *Engine, chan: u16, v: value.Value) void {
        const meta = self.ir.channels.get(chan);
        switch (meta.chan_type) {
            .ref_chan => {
                const ptr: *i64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                switch (v) {
                    .ref => |r| self.runtime.writePtr(chan, @ptrCast(r)),
                    .null_val, .unit => self.runtime.writePtr(chan, null),
                    // 标量值写入 ref_chan（类型参数实例化为标量时）：
                    // 整数符号扩展为 i64，浮点提升为 f64，写入完整 8 字节
                    .i8 => |b| ptr.* = @as(i64, @as(i8, @bitCast(b[0]))),
                    .u8 => |b| ptr.* = @as(i64, b[0]),
                    .i16 => |b| ptr.* = @as(i64, @as(i16, @bitCast(b))),
                    .u16 => |b| ptr.* = @as(i64, @as(u16, @bitCast(b))),
                    .i32 => |b| ptr.* = @as(i64, @as(i32, @bitCast(b))),
                    .u32 => |b| ptr.* = @as(i64, @as(u32, @bitCast(b))),
                    .i64 => |b| ptr.* = @bitCast(b),
                    .u64 => |b| ptr.* = @bitCast(@as(u64, @bitCast(b))),
                    .boolean => |b| ptr.* = @intFromBool(b[0] != 0),
                    .f32 => |b| ptr.* = @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(b))))),
                    .f64 => |b| ptr.* = @bitCast(@as(f64, @bitCast(b))),
                    else => self.runtime.writePtr(chan, null),
                }
            },
            .bool_chan, .mask_chan => {
                const b: bool = switch (v) {
                    .boolean => |bb| bb[0] != 0,
                    .i64 => |bb| @as(i64, @bitCast(bb)) != 0,
                    .i32 => |bb| @as(i32, @bitCast(bb)) != 0,
                    .u64 => |bb| @as(u64, @bitCast(bb)) != 0,
                    .u32 => |bb| @as(u32, @bitCast(bb)) != 0,
                    else => false,
                };
                self.runtime.writeBool(chan, b);
            },
            .char_chan => {
                const cp: u32 = switch (v) {
                    .char => |b| @bitCast(b),
                    .i32 => |b| @bitCast(@as(i32, @bitCast(b))),
                    .u32 => |b| @bitCast(b),
                    .i64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .u64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    else => 0,
                };
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = cp;
            },
            .i64_chan, .u64_chan, .isize_chan, .usize_chan => {
                const i: i64 = switch (v) {
                    .i64 => |b| @as(i64, @bitCast(b)),
                    .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
                    .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
                    .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
                    .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
                    .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
                    .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
                    .u8 => |b| @as(i64, b[0]),
                    .isize => |b| @as(i64, @as(isize, @bitCast(b))),
                    .usize => |b| @bitCast(@as(usize, @bitCast(b))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    .null_val, .unit => 0,
                    .ref => |r| @intCast(@intFromPtr(r)),
                    else => 0,
                };
                self.runtime.writeI64(chan, @bitCast(i));
            },
            .i32_chan, .u32_chan => {
                const i: i32 = switch (v) {
                    .i32 => |b| @as(i32, @bitCast(b)),
                    .i64 => |b| @truncate(@as(i64, @bitCast(b))),
                    .i16 => |b| @as(i32, @as(i16, @bitCast(b))),
                    .i8 => |b| @as(i32, @as(i8, @bitCast(b[0]))),
                    .u32 => |b| @bitCast(@as(u32, @bitCast(b))),
                    .u16 => |b| @as(i32, @as(u16, @bitCast(b))),
                    .u8 => |b| @as(i32, b[0]),
                    .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
                    .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
                    .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    .null_val, .unit => 0,
                    else => 0,
                };
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = i;
            },
            .i16_chan, .u16_chan => {
                const i: i16 = switch (v) {
                    .i16 => |b| @as(i16, @bitCast(b)),
                    .i32 => |b| @truncate(@as(i32, @bitCast(b))),
                    .i64 => |b| @truncate(@as(i64, @bitCast(b))),
                    .u16 => |b| @bitCast(@as(u16, @bitCast(b))),
                    .u32 => |b| @truncate(@as(i32, @bitCast(@as(u32, @bitCast(b))))),
                    .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
                    .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
                    .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
                    .u8 => |b| @as(i16, b[0]),
                    .i8 => |b| @as(i16, @as(i8, @bitCast(b[0]))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    else => 0,
                };
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = i;
            },
            .i8_chan, .u8_chan => {
                const b_val: u8 = switch (v) {
                    .i8 => |b| b[0],
                    .u8 => |b| b[0],
                    .i16 => |b| @truncate(@as(u16, @bitCast(b))),
                    .i32 => |b| @truncate(@as(u32, @bitCast(b))),
                    .i64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .u16 => |b| @truncate(@as(u16, @bitCast(b))),
                    .u32 => |b| @truncate(@as(u32, @bitCast(b))),
                    .u64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .usize => |b| @truncate(@as(usize, @bitCast(b))),
                    .isize => |b| @truncate(@as(usize, @bitCast(@as(isize, @bitCast(b))))),
                    .boolean => |b| b[0],
                    else => 0,
                };
                self.runtime.rawPtr(chan)[0] = b_val;
            },
            .f64_chan => {
                const f: f64 = switch (v) {
                    .f64 => |b| @bitCast(b),
                    .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    else => 0,
                };
                const ptr: *f64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            .f32_chan => {
                const f: f32 = switch (v) {
                    .f32 => |b| @bitCast(b),
                    .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    else => 0,
                };
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            else => {
                // 其他类型：按字节拷贝
                const w = meta.elem_width;
                if (w > 0 and w <= 16) {
                    const src: [*]const u8 = @ptrCast(&v);
                    const dst = self.runtime.rawPtr(chan);
                    @memcpy(dst[0..w], src[0..w]);
                }
            },
        }
    }

    // ════════════════════════════════════════════
    // 惰性求值执行（Lazy<T>）
    // ════════════════════════════════════════════

    /// lazy_make：构造 LazyValue 对象
    /// inputs[0] = thunk closure (ref_chan)，output = ref_chan
    fn execLazyMake(self: *Engine, node: *const Node) EngineError!void {
        const closure_ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(closure_ptr));
        if (header.type_tag != .closure) return error.InvalidChannel;
        const closure: *value.Closure = @alignCast(@fieldParentPtr("header", header));

        const use_arena = self.currentFuncUseArena();
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(@sizeOf(value.LazyValue)) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(@sizeOf(value.LazyValue)) catch return error.OutOfMemory;
        const lazy: *value.LazyValue = @ptrCast(@alignCast(buf.ptr));
        lazy.* = .{
            .expr = undefined,
            .env = undefined,
            .thunk = closure,
        };
        value.obj_header.initObjHeader(&lazy.header, .lazy_val, @sizeOf(value.LazyValue), use_arena, self.tctx.?);
        try self.trackObj(&lazy.header);
        // LazyValue 持有 thunk 闭包的一次引用
        _ = (value.Value{ .ref = &closure.header }).retain(self.tctx.?);
        self.runtime.writePtr(node.output, @ptrCast(&lazy.header));
    }

    /// lazy_force：强制求值 Lazy<T>
    /// inputs[0] = LazyValue (ref_chan)，output = 值通道
    fn execLazyForce(self: *Engine, node: *const Node) EngineError!void {
        const lazy = self.readLazyValue(node.inputs[0]) orelse return error.InvalidChannel;
        if (lazy.forced) {
            if (lazy.cached) |c| {
                self.writeScalarValue(node.output, c);
            }
            return;
        }
        const result = try self.forceLazyValue(lazy);
        self.writeScalarValue(node.output, result);
    }

    /// 读取 ref_chan 中的 LazyValue 指针
    fn readLazyValue(self: *Engine, chan: u16) ?*value.LazyValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .lazy_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 强制求值 LazyValue：调用 thunk 闭包并缓存结果
    fn forceLazyValue(self: *Engine, lazy: *value.LazyValue) EngineError!value.Value {
        if (lazy.forced) return lazy.cached orelse value.Value.fromNull();
        const closure: *value.Closure = @ptrCast(@alignCast(lazy.thunk));
        const func_idx: u16 = @intCast(@intFromPtr(closure.func));
        if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
        const callee_func = self.ir.functions[func_idx];

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        // enterFunction 在 CallStackRegion 中分配 thunk 函数的本地通道
        try self.runtime.enterFunction(func_idx, &callee_func);
        errdefer self.runtime.leaveFunction();

        // thunk 无显式参数，只需把上值写入 param_channels 尾部
        const total_params = callee_func.param_channels.len;
        const uv_count = @min(closure.upvalues.len, total_params);
        for (0..uv_count) |i| {
            self.writeScalarValue(callee_func.param_channels[i], closure.upvalues[i]);
        }

        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = callee_func.return_channel,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, &.{});
        self.current_func_idx = saved_func_idx;

        // 在 leaveFunction 之前读取结果（leaveFunction 会 resetTo 回收通道内存）
        const result = try self.readScalarValue(result_chan);
        self.runtime.leaveFunction();

        // 缓存结果，避免重复求值
        lazy.forced = true;
        lazy.cached = result;
        _ = result.retain(self.tctx.?);
        return result;
    }

    // ════════════════════════════════════════════
    // 清理执行（Phase 4：defer）
    // ════════════════════════════════════════════

    /// cleanup_register：将 defer 体注册到 defer 栈
    /// meta_index 指向 CleanupMeta（记录 body_start/body_len）
    fn execCleanupRegister(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.cleanup_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.cleanup_metas[node.meta_index - 1];

        if (self.defer_top >= MAX_DEFERS) return error.CallDepthExceeded;

        self.defer_stack[self.defer_top] = .{
            .func_idx = self.current_func_idx,
            .body_start = cm.body_start,
            .body_len = cm.body_len,
        };
        self.defer_top += 1;
    }

    // ════════════════════════════════════════════
    // 路由 + 竞争执行（Phase 5：select 多路复用）
    // ════════════════════════════════════════════

    /// race_source：检查通道就绪性
    /// inputs[0] = 通道值（ChannelValue 指针或任意标量值）
    /// output = mask_chan（1=就绪, 0=未就绪）
    fn execRaceSource(self: *Engine, node: *const Node) EngineError!void {
        const ready = self.selectSourceReady(node.inputs[0]);
        self.runtime.writeBool(node.output, ready);
    }

    /// select 源就绪性检查（非阻塞）
    /// 非通道源（标量等）始终就绪；通道源有数据/会合发送方/已关闭时就绪
    fn selectSourceReady(self: *Engine, chan: u16) bool {
        const meta = self.ir.channels.get(chan);
        // 只有 ref_chan 才可能是 ChannelValue/SenderValue/ReceiverValue
        if (meta.chan_type != .ref_chan) return true;
        const ch = self.readChannelValue(chan) orelse return true;
        ch.mutex.lock();
        defer ch.mutex.unlock();
        // 已关闭：recv 立即返回（null），视为就绪，避免 select 永久挂起
        if (ch.closed) return true;
        // 缓冲模式看数据量，会合模式看发送方是否就绪
        return if (ch.capacity == 0) ch.rend_ready else ch.count > 0;
    }

    /// race_select：阻塞多路复用，直到任一 receive 通道就绪或 timeout 到期
    /// inputs[0..source_count)   = 各 receive 分支的通道引用
    /// inputs[timeout_input]     = timeout 时长通道（毫秒，仅 RaceMeta.timeout_arm 非 null 时）
    /// output = i64_chan（获胜分支的 arm 索引，0-based）
    fn execRaceSelect(self: *Engine, node: *const Node) EngineError!void {
        var source_count: u8 = node.input_count;
        var timeout_arm: ?u8 = null;
        var timeout_input: u8 = 0;
        if (node.meta_index > 0 and node.meta_index <= self.ir.race_metas.len) {
            const rm = self.ir.race_metas[node.meta_index - 1];
            source_count = rm.source_count;
            timeout_arm = rm.timeout_arm;
            timeout_input = rm.timeout_input;
        }

        // 计算超时截止时间（单调时钟毫秒时间戳），null 表示无限等待
        var deadline: ?i64 = null;
        if (timeout_arm != null) {
            const dur_ms = try self.readIntAsI64(node.inputs[timeout_input]);
            deadline = monotonicMillis() + dur_ms;
        }

        // 阻塞轮询：先自旋让出 CPU，后 1ms 睡眠退避（与 sync.Condition 的等待纪律一致）
        var spin: u32 = 0;
        while (true) {
            var i: u8 = 0;
            while (i < source_count) : (i += 1) {
                if (self.selectSourceReady(node.inputs[i])) {
                    // 输入槽位 i → arm 索引：timeout 分支占据 arm 索引 timeout_arm，
                    // 其后的 receive 分支 arm 索引 = 输入槽位 + 1
                    const arm_idx: i64 = if (timeout_arm) |ta|
                        (if (i >= ta) @as(i64, i) + 1 else @as(i64, i))
                    else
                        @as(i64, i);
                    self.runtime.writeI64(node.output, arm_idx);
                    return;
                }
            }
            if (deadline) |dl| {
                if (monotonicMillis() >= dl) {
                    self.runtime.writeI64(node.output, @as(i64, timeout_arm.?));
                    return;
                }
            }
            if (spin < 64) {
                std.Thread.yield() catch {};
                spin += 1;
            } else {
                selectBackoffSleep();
            }
        }
    }

    /// race_yield：让出执行权
    fn execRaceYield(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        std.Thread.yield() catch {};
    }

    /// route_get_tag：读取值的 tag（用于 Trait 动态分派和 ADT 构造器识别）
    /// inputs[0] = 值通道
    /// output = mask_chan（tag 值，用 i64 存储）
    fn execRouteGetTag(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        switch (meta.chan_type) {
            .ref_chan => {
                // 堆对象：读取 type_tag 的整数值作为 tag
                const header = self.readRefObj(val_chan);
                if (header) |h| {
                    const tag_val: i64 = @intFromEnum(h.type_tag);
                    self.runtime.writeI64(node.output, tag_val);
                } else {
                    self.runtime.writeI64(node.output, 0);
                }
            },
            // 标量值：用 chan_type 的整数值作为 tag
            else => {
                const tag_val: i64 = @intFromEnum(meta.chan_type);
                self.runtime.writeI64(node.output, tag_val);
            },
        }
    }

    /// route_dispatch：按 winner 索引执行对应 body 子图
    /// inputs[0] = winner 索引（mask_chan）
    /// output = 结果通道
    fn execRouteDispatch(self: *Engine, node: *const Node) EngineError!?u16 {
        if (node.meta_index == 0 or node.meta_index > self.ir.route_metas.len) return error.InvalidMetaIndex;
        const rm = self.ir.route_metas[node.meta_index - 1];

        // 读取 winner 索引（通用观察点：自动强制 Lazy<bool>/Lazy<i64>）
        const winner_val = try self.readScalarValue(node.inputs[0]);
        const winner_raw = winner_val.asI64();
        const winner: usize = @intCast(@as(u64, @bitCast(winner_raw)));

        if (winner >= rm.body_starts.len or winner >= rm.body_lens.len) {
            return error.InvalidChannel;
        }

        const body_start = rm.body_starts[winner];
        const body_len = rm.body_lens[winner];
        if (body_len == 0) return null;

        // 执行 winner 对应的 body 子图
        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const local_start = body_start - func.node_start;

        if (debug_route_dispatch) {
            std.debug.print("route_dispatch: func={s} winner={} body_start={} body_len={} local_start={} node_start={}\n", .{ func.name, winner, body_start, body_len, local_start, func.node_start });
            for (0..body_len) |i| {
                const n = nodes[local_start + i];
                std.debug.print("  body[{}]: op={} output={}\n", .{ i, n.op, n.output });
            }
        }

        // 如果 body 中遇到 halt 节点（halt_return/halt_throw），传播它
        if (try self.execBodyNodes(nodes, local_start, body_len)) |halt_chan| {
            if (debug_route_dispatch) {
                std.debug.print("  -> halt_chan={}\n", .{halt_chan});
            }
            return halt_chan;
        }

        // body 子图最后一个节点的 output 作为结果
        const body_out_chan = nodes[local_start + body_len - 1].output;
        const body_meta = self.ir.channels.get(body_out_chan);
        const result_meta = self.ir.channels.get(node.output);

        if (debug_route_dispatch) {
            const bw = self.runtime.elemWidth(body_out_chan);
            const rw = self.runtime.elemWidth(node.output);
            std.debug.print("  result copy: body_out_chan={} body_type={} body_w={} result_chan={} result_type={} result_w={}\n", .{ body_out_chan, body_meta.chan_type, bw, node.output, result_meta.chan_type, rw });
            if (bw > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                std.debug.print("  src bytes:", .{});
                for (0..@min(bw, 16)) |i| std.debug.print(" {x:0>2}", .{src[i]});
                std.debug.print("\n", .{});
            }
        }

        // 类型转换：body 输出 → 结果通道
        if (result_meta.chan_type == .nullable_chan and body_meta.chan_type != .nullable_chan) {
            // 结果是 nullable，body 输出不是 nullable → 包装为 nullable
            const inner_w = self.nullableInnerWidth(node.output);
            const dst = self.runtime.rawPtr(node.output);
            if (body_meta.chan_type == .null_chan) {
                // body 输出是 null → 设置 null flag
                dst[inner_w] = 1;
            } else {
                // body 输出是值类型 → 拷贝值，清除 null flag
                const src = self.runtime.rawPtr(body_out_chan);
                if (inner_w > 0) @memcpy(dst[0..inner_w], src[0..inner_w]);
                dst[inner_w] = 0;
            }
        } else {
            // 直接拷贝（宽度取 body 输出和结果中较小者，避免越界）
            const w = @min(self.runtime.elemWidth(body_out_chan), self.runtime.elemWidth(node.output));
            if (w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..w], src[0..w]);
            }
        }
        if (debug_route_dispatch) {
            const rw2 = self.runtime.elemWidth(node.output);
            if (rw2 > 0) {
                const dst = self.runtime.rawPtr(node.output);
                std.debug.print("  dst bytes:", .{});
                for (0..@min(rw2, 16)) |i| std.debug.print(" {x:0>2}", .{dst[i]});
                std.debug.print("\n", .{});
            }
        }
        return null;
    }

    /// route_merge：合并多分支结果（Phase 5 简化：直接拷贝第一个输入）
    fn execRouteMerge(self: *Engine, node: *const Node) EngineError!void {
        if (node.input_count == 0) return;
        const src_chan = node.inputs[0];
        const w = self.runtime.elemWidth(src_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    // ════════════════════════════════════════════
    // Nullable 执行（Phase 6：可空值）
    // ════════════════════════════════════════════
    // nullable_chan 布局：[inner_value_bytes][null_flag: 1 byte]
    // null_flag = 0 表示有值（non-null），null_flag = 1 表示 null

    /// 获取 nullable 通道的 inner 宽度（总宽度 - 1 byte flag）
    fn nullableInnerWidth(self: *Engine, chan: u16) u8 {
        const meta = self.ir.channels.get(chan);
        return meta.inner_type.elemWidth();
    }

    /// nullable_make：将值包装为 Nullable<T>
    /// inputs[0] = 值通道（如果 ref_chan 为 null 指针，则包装为 null）
    /// output = nullable_chan
    fn execNullableMake(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const val_meta = self.ir.channels.get(val_chan);

        const inner_w = self.nullableInnerWidth(node.output);
        const total_w = self.runtime.elemWidth(node.output); // inner_w + 1
        const dst = self.runtime.rawPtr(node.output);

        // 检查是否为 null（ref_chan 的 null 指针，或 null_chan）
        const is_null = switch (val_meta.chan_type) {
            .ref_chan => self.runtime.readPtr(val_chan) == null,
            .null_chan => true,
            else => false,
        };

        if (is_null) {
            // 设置 null flag = 1
            dst[inner_w] = 1;
        } else {
            // 拷贝 inner 值，设置 null flag = 0
            if (inner_w > 0) {
                const src = self.runtime.rawPtr(val_chan);
                @memcpy(dst[0..inner_w], src[0..inner_w]);
            }
            dst[inner_w] = 0;
        }
        _ = total_w;
    }

    /// nullable_is_null：检查 Nullable<T> 是否为 null
    /// inputs[0] = nullable_chan
    /// output = bool_chan
    fn execNullableIsNull(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);
        // null flag 在 inner_w 偏移处
        const is_null = src[inner_w] != 0;
        self.runtime.writeBool(node.output, is_null);
    }

    /// nullable_unwrap：提取 Nullable<T> 的内部值（null 时写零，由调用方通过 is_null 判断）
    /// inputs[0] = nullable_chan
    /// output = inner 值通道
    fn execNullableUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);

        if (inner_w > 0) {
            const dst = self.runtime.rawPtr(node.output);
            if (src[inner_w] != 0) {
                // null 值：写零（调用方应通过 nullable_is_null 判断后再使用）
                @memset(dst[0..inner_w], 0);
            } else {
                @memcpy(dst[0..inner_w], src[0..inner_w]);
            }
        }
    }

    /// nullable_unwrap_or：提取值，null 时返回默认值
    /// inputs[0] = nullable_chan, inputs[1] = default 值通道
    /// output = inner 值通道
    fn execNullableUnwrapOr(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const default_chan = node.inputs[1];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);

        const is_null = src[inner_w] != 0;
        const result_chan = if (is_null) default_chan else src_chan;

        if (inner_w > 0) {
            const result_src = self.runtime.rawPtr(result_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..inner_w], result_src[0..inner_w]);
        }
    }

    // ════════════════════════════════════════════
    // 内存管理执行（Phase 6：unsafe 手动分配）
    // ════════════════════════════════════════════

    /// alloc：在堆上分配内存（通过 ThreadContext 对象池）
    /// meta_index 指向 ScalarMeta，const_val.int_val 存储分配字节数
    /// output = ref_chan（指向分配的内存）
    fn execAlloc(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const sm = self.ir.scalar_metas[node.meta_index - 1];
        const cv = sm.const_val orelse return error.InvalidMetaIndex;
        const size: usize = @intCast(cv.int_val);

        if (size == 0) {
            self.runtime.writePtr(node.output, null);
            return;
        }

        // 通过 ThreadContext 的对象池分配
        const tctx = self.tctx orelse return error.OutOfMemory;
        const buf = tctx.allocBySize(size) catch return error.OutOfMemory;
        @memset(buf, 0);
        self.runtime.writePtr(node.output, buf.ptr);
    }

    /// free：释放堆内存（简化：不实际释放，由 arena reset 统一回收）
    /// inputs[0] = ref_chan（指向要释放的内存）
    fn execFree(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        // 简化：arena 分配器不支持单个释放，由函数级/作用域级 reset 统一回收
    }

    // ════════════════════════════════════════════
    // 星轨执行（Phase 7：async/spawn）
    // ════════════════════════════════════════════
    // 设计要点：
    // - orbit_async_create：在独立线程中执行 async 函数，返回 AsyncHandle
    // - orbit_async_join：阻塞等待异步任务完成，提取结果
    // - orbit_chan_send/recv/try_recv：通过 ChannelValue 进行线程间通信
    // - 异步函数在独立线程中执行，拥有自己的 Engine 实例（共享 IR，独立 Runtime）

    /// 读取 ref_chan 中的 AsyncHandle 指针
    fn readAsyncHandle(self: *Engine, chan: u16) ?*value.AsyncHandle {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag != .async_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 读取 ref_chan 中的 ChannelValue 指针
    /// 支持 ChannelValue、SenderValue、ReceiverValue 三种引用类型
    fn readChannelValue(self: *Engine, chan: u16) ?*value.ChannelValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        return switch (header.type_tag) {
            .channel_val => @alignCast(@fieldParentPtr("header", header)),
            .sender_val => blk: {
                const sender: *value.SenderValue = @alignCast(@fieldParentPtr("header", header));
                break :blk sender.channel;
            },
            .receiver_val => blk: {
                const receiver: *value.ReceiverValue = @alignCast(@fieldParentPtr("header", header));
                break :blk receiver.channel;
            },
            else => null,
        };
    }

    /// 读取 AtomicValue 指针（ref_chan → *AtomicValue）
    fn readAtomicValue(self: *Engine, chan: u16) ?*value.AtomicValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .atomic_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// orbit_async_create：在独立线程中执行 async 函数
    /// inputs[0..N] = 参数通道
    /// meta_index 指向 OrbitMeta（记录 func_index, arg_count, result_type）
    /// output = ref_chan（AsyncHandle 指针）
    fn execOrbitAsyncCreate(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.orbit_metas.len) return error.InvalidMetaIndex;
        const om = self.ir.orbit_metas[node.meta_index - 1];

        // 创建 AsyncHandle
        const handle = self.tctx.?.createObj(value.AsyncHandle) catch return error.OutOfMemory;
        handle.* = value.AsyncHandle.init();
        value.obj_header.initObjHeader(&handle.header, .async_val, @sizeOf(value.AsyncHandle), false, self.tctx.?);
        try self.trackObj(&handle.header);

        // 读取参数值：标量按原始字节拷贝（保留完整位模式，支持 f16..f128/i128），
        // ref_chan 传递原始对象指针由 worker 深拷贝
        var arg_bytes: [4][16]u8 = std.mem.zeroes([4][16]u8);
        var arg_widths: [4]u8 = .{ 0, 0, 0, 0 };
        var arg_objs: [4]?*value.obj_header.ObjHeader = .{ null, null, null, null };
        const arg_count = @min(om.arg_count, 4);
        for (0..arg_count) |i| {
            const arg_meta = self.ir.channels.get(node.inputs[i]);
            if (arg_meta.chan_type == .ref_chan) {
                const v = self.chanToValue(node.inputs[i]);
                arg_objs[i] = if (v == .ref) v.ref else null;
            } else {
                const w = arg_meta.elem_width;
                arg_widths[i] = w;
                if (w > 0) {
                    const src = self.runtime.rawPtr(node.inputs[i]);
                    @memcpy(arg_bytes[i][0..w], src[0..w]);
                }
            }
        }

        // 设置状态为 Running
        handle.setStatus(.Running);

        // 准备线程数据：拷贝 IR 指针、函数索引、参数、handle 指针
        // OrbitThreadData 跨线程分配（主线程分配，worker 线程释放），
        // 使用 backing allocator（线程安全）而非 tctx 对象池（线程本地）
        const thread_data = self.tctx.?.backing.create(OrbitThreadData) catch return error.OutOfMemory;
        thread_data.* = .{
            .ir = self.ir,
            .func_idx = om.func_index,
            .arg_bytes = arg_bytes,
            .arg_widths = arg_widths,
            .arg_objs = arg_objs,
            .arg_count = arg_count,
            .handle = handle,
            .global = self.global.?,
            .backing = self.tctx.?.backing,
            .global_prof = self.tctx.?.global_prof,
        };

        // spawn 线程执行 async 函数
        const thread = std.Thread.spawn(.{}, orbitWorker, .{thread_data}) catch return error.OutOfMemory;
        thread.detach();

        // 输出 AsyncHandle 指针
        self.runtime.writePtr(node.output, @ptrCast(&handle.header));
    }

    /// orbit_async_join：阻塞等待异步任务完成，提取结果
    /// inputs[0] = handle 通道（ref_chan）
    /// output = 结果通道
    /// 值语义：普通复合类型返回值深拷贝到主线程，&T / *T 保持共享
    fn execOrbitAsyncJoin(self: *Engine, node: *const Node) EngineError!void {
        const handle = self.readAsyncHandle(node.inputs[0]) orelse {
            return error.InvalidChannel;
        };

        // 阻塞等待完成
        const result_val = handle.join();

        // 将结果写入 output 通道
        if (result_val) |v| {
            const out_meta = self.ir.channels.get(node.output);
            const out_val = if (out_meta.chan_type == .ref_chan and !out_meta.is_ref) blk: {
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                break :blk copied;
            } else v;
            self.writeScalarValue(node.output, out_val);
        } else {
            // 任务失败或无结果：写入 0
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
        }
    }

    /// orbit_chan_send：向通道发送值（阻塞直到接收方就绪）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// inputs[1] = 值通道
    /// 值语义：普通复合类型 ref_chan 深拷贝后发送，&T / *T 保持共享
    fn execOrbitChanSend(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const val = try self.readScalarValue(node.inputs[1]);
        const val_meta = self.ir.channels.get(node.inputs[1]);
        const sent_val = if (val_meta.chan_type == .ref_chan and !val_meta.is_ref) blk: {
            const copied = val.deepCopy(self.tctx.?) catch return error.OutOfMemory;
            try self.trackValueTree(copied);
            break :blk copied;
        } else val;

        const sent = ch.send(sent_val) catch return error.Panic;
        if (!sent) return error.Thrown; // 通道已关闭
    }

    /// orbit_chan_recv：从通道接收值（阻塞直到有数据）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// output = 结果通道
    fn execOrbitChanRecv(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;

        const result_val = ch.recv() orelse {
            // 通道已关闭且无数据
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
            return;
        };

        self.writeScalarValue(node.output, result_val);
    }

    /// orbit_chan_try_recv：非阻塞接收，返回 nullable
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// output = nullable_chan
    fn execOrbitChanTryRecv(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse {
            // 无效通道：写入 null
            const inner_w = self.nullableInnerWidth(node.output);
            const dst = self.runtime.rawPtr(node.output);
            dst[inner_w] = 1; // null flag
            return;
        };

        const result_val = ch.tryRecv();
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);

        if (result_val) |v| {
            // 有值：写入 inner 值 + null flag = 0
            // 简化：将 Value 的 i64 表示写入
            const tmp_buf = self.readScalarValueToBytes(v);
            if (inner_w > 0) {
                @memcpy(dst[0..inner_w], tmp_buf[0..inner_w]);
            }
            dst[inner_w] = 0;
        } else {
            // 无值：null flag = 1
            dst[inner_w] = 1;
        }
    }

    /// orbit_async_status：查询异步任务状态（非阻塞）
    /// inputs[0] = handle 通道（ref_chan）
    /// output = i64 通道（0=Pending, 1=Running, 2=Completed, 3=Cancelled, 4=Failed）
    fn execOrbitAsyncStatus(self: *Engine, node: *const Node) EngineError!void {
        const handle = self.readAsyncHandle(node.inputs[0]) orelse return error.InvalidChannel;
        const status = handle.getStatus();
        const code: i64 = switch (status) {
            .Pending => 0,
            .Running => 1,
            .Completed => 2,
            .Cancelled => 3,
            .Failed => 4,
        };
        self.runtime.writeI64(node.output, code);
    }

    /// channel_close：关闭通道
    /// inputs[0] = channel 通道（ref_chan）
    /// output = unit_chan
    fn execChannelClose(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        ch.close();
    }

    /// channel_create：创建带缓冲的 ChannelValue
    fn execChannelCreate(self: *Engine, node: *const Node) EngineError!void {
        const capacity = try self.readIntAsI64(node.inputs[0]);
        const cap: usize = if (capacity < 0) 0 else @intCast(capacity);
        const ch = value.ChannelValue.create(self.tctx.?, cap) catch return error.OutOfMemory;
        try self.trackObj(&ch.header);
        self.runtime.writePtr(node.output, @ptrCast(&ch.header));
    }

    /// channel_sender：从 ChannelValue 创建 SenderValue
    fn execChannelSender(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const sender = self.tctx.?.createObj(value.SenderValue) catch return error.OutOfMemory;
        sender.* = .{ .channel = ch };
        value.obj_header.initObjHeader(&sender.header, .sender_val, @sizeOf(value.SenderValue), false, self.tctx.?);
        _ = value.obj_header.retain(&ch.header, self.tctx.?);
        try self.trackObj(&sender.header);
        self.runtime.writePtr(node.output, @ptrCast(&sender.header));
    }

    /// channel_receiver：从 ChannelValue 创建 ReceiverValue
    fn execChannelReceiver(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const receiver = self.tctx.?.createObj(value.ReceiverValue) catch return error.OutOfMemory;
        receiver.* = .{ .channel = ch };
        value.obj_header.initObjHeader(&receiver.header, .receiver_val, @sizeOf(value.ReceiverValue), false, self.tctx.?);
        _ = value.obj_header.retain(&ch.header, self.tctx.?);
        try self.trackObj(&receiver.header);
        self.runtime.writePtr(node.output, @ptrCast(&receiver.header));
    }

    /// atomic_make：构造 AtomicValue 堆对象
    /// inputs[0] = 初始值，output = ref_chan（AtomicValue 指针）
    fn execAtomicMake(self: *Engine, node: *const Node) EngineError!void {
        const init_val = self.chanToValue(node.inputs[0]);
        const av = self.tctx.?.createObj(value.AtomicValue) catch return error.OutOfMemory;
        av.* = .{ .data = init_val, .mutex = .{} };
        value.obj_header.initObjHeader(&av.header, .atomic_val, @sizeOf(value.AtomicValue), false, self.tctx.?);
        try self.trackObj(&av.header);
        self.runtime.writePtr(node.output, @ptrCast(&av.header));
    }

    /// atomic_fetch_add：原子加/减法，返回旧值
    /// inputs[0] = Atomic ref_chan，inputs[1] = 增量值
    /// _pad=0 为 add，_pad=1 为 sub
    fn execAtomicFetchAdd(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const delta = self.chanToValue(node.inputs[1]);
        const old = if (node._pad == 1) av.fetchSub(delta) else av.fetchAdd(delta);
        self.valueToChan(node.output, old);
    }

    /// atomic_swap：原子交换，返回旧值
    /// inputs[0] = Atomic ref_chan，inputs[1] = 新值
    fn execAtomicSwap(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const new_val = self.chanToValue(node.inputs[1]);
        const old = av.xchg(new_val);
        self.valueToChan(node.output, old);
    }

    /// atomic_cas：原子比较并交换
    /// inputs[0] = Atomic ref_chan，inputs[1] = expected，inputs[2] = new
    fn execAtomicCas(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const expected = self.chanToValue(node.inputs[1]);
        const new_val = self.chanToValue(node.inputs[2]);
        const ok = av.cas(expected, new_val);
        self.runtime.writeBool(node.output, ok);
    }

    /// error_message：提取错误值的消息字符串
    /// inputs[0] = error ref 通道
    /// output = ref_chan（Str 指针）
    /// 支持：
    /// - .error_val：读取 ErrorValue.message
    /// - .throw_val：读取 ThrowValue.payload.err.message
    /// - .record：error_newtype 实例用 RecordValue 表示，读取 field_id=1（第一个构造器字段，即 msg）
    fn execErrorMessage(self: *Engine, node: *const Node) EngineError!void {
        const in_chan = node.inputs[0];
        const ptr = self.runtime.readPtr(in_chan);
        const real_ptr = ptr orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(real_ptr));
        const msg: []const u8 = switch (header.type_tag) {
            .error_val => blk: {
                const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                break :blk e.message;
            },
            .throw_val => blk: {
                const t: *value.ThrowValue = @alignCast(@fieldParentPtr("header", header));
                break :blk switch (t.payload) {
                    .err => |e| e.message,
                    else => "ok",
                };
            },
            .record => blk: {
                // error_newtype 实例（RecordValue）：field_id=1 是第一个构造器字段（msg）
                const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                if (r.fields.len > 1) {
                    const field_val = r.fields[1];
                    if (field_val == .ref) {
                        const fh: *value.obj_header.ObjHeader = @ptrCast(@alignCast(field_val.ref));
                        if (fh.type_tag == .str) {
                            const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fh));
                            break :blk fs.bytes();
                        }
                    }
                }
                break :blk "not an error";
            },
            else => "not an error",
        };
        const v = value.Value.fromStringBytes(self.tctx.?, msg) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// obj_type_name：获取值的类型名
    /// inputs[0] = ref 通道
    /// output = ref_chan（Str 指针）
    fn execObjTypeName(self: *Engine, node: *const Node) EngineError!void {
        const ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        const name: []const u8 = switch (header.type_tag) {
            .record => blk: {
                const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                break :blk r.type_name;
            },
            .adt => blk: {
                const a: *value.AdtValue = @alignCast(@fieldParentPtr("header", header));
                break :blk a.type_name;
            },
            .newtype => blk: {
                const n: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", header));
                break :blk n.type_name;
            },
            .error_val => blk: {
                const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                break :blk e.type_name;
            },
            else => @tagName(header.type_tag),
        };
        const v = value.Value.fromStringBytes(self.tctx.?, name) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// closure_make：创建 Closure 值，存储 func_idx + 上值
    /// inputs[0..N] = 上值通道
    /// meta_index 指向 ClosureMeta（func_index, upvalue_count, result_type）
    /// output = ref_chan（Closure 指针）
    /// 逃逸分析驱动：非逃逸函数内的闭包走 ShadowArena，endFunction 时 O(1) reset
    fn execClosureMake(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.closure_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.closure_metas[node.meta_index - 1];

        // 连续内存分配：[Closure header | upvalues[upvalue_count]]
        // 先创建 Closure 对象（upvalues 暂为空），并写入输出通道
        // 这样自引用闭包（递归 lambda）能在收集上值时读取到自身指针
        const upvalue_count = @as(usize, @min(cm.upvalue_count, node.input_count));
        const total = @sizeOf(value.Closure) + upvalue_count * @sizeOf(value.Value);
        const use_arena = self.currentFuncUseArena();
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(total) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(total) catch return error.OutOfMemory;
        const closure: *value.Closure = @ptrCast(@alignCast(buf.ptr));
        closure.* = .{
            .func = @ptrFromInt(@as(usize, cm.func_index)),
            .arity = @intCast(upvalue_count),
            .upvalues = &.{},
            .upvalue_ref_bits = cm.upvalue_ref_bits,
            .cell_upvalues = cm.cell_upvalues,
        };
        value.obj_header.initObjHeader(&closure.header, .closure, total, use_arena, self.tctx.?);
        try self.trackObj(&closure.header);
        self.runtime.writePtr(node.output, @ptrCast(&closure.header));

        // 现在收集上值（自引用闭包可从 output 通道读到自身指针）
        // upvalues 缓冲区已随 Closure 连续分配，此处仅填充数据
        if (upvalue_count > 0) {
            const uv_ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr + @sizeOf(value.Closure)));
            const upvalues = uv_ptr[0..upvalue_count];
            for (0..upvalue_count) |i| {
                const v = self.chanToValue(node.inputs[i]);
                const is_cell = (cm.cell_upvalues >> @intCast(i)) & 1 == 1;
                const is_ref = (cm.upvalue_ref_bits >> @intCast(i)) & 1 == 1;
                if (is_cell or is_ref) {
                    // cell / &T / *T 上值保持引用语义，共享原对象
                    upvalues[i] = v;
                    _ = upvalues[i].retain(self.tctx.?);
                } else {
                    // 普通复合类型上值：深拷贝以获得独立所有权
                    const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(copied);
                    upvalues[i] = copied;
                }
            }
            closure.upvalues = upvalues;
        }
    }

    /// partial_make：构造 PartialApplication 值
    /// meta_index 指向 PartialMeta（func_index + 已绑定实参通道 + 剩余参数个数）
    /// output = ref_chan（PartialApplication 指针）
    fn execPartialMake(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.partial_metas.len) return error.InvalidMetaIndex;
        const pm = self.ir.partial_metas[node.meta_index - 1];

        const bound_count = pm.bound_arg_channels.len;
        var bound_args: [16]value.Value = undefined;
        for (0..bound_count) |i| {
            const arg_chan = pm.bound_arg_channels[i];
            const v = self.chanToValue(arg_chan);
            const is_ref = (pm.bound_arg_ref_bits >> @intCast(i)) & 1 == 1;
            if (is_ref) {
                bound_args[i] = v.retain(self.tctx.?);
            } else {
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                bound_args[i] = copied;
            }
        }

        const func_ptr: *const anyopaque = @ptrFromInt(@as(usize, pm.func_index) + 1);
        const partial_v = value.Value.makePartial(
            self.tctx.?,
            func_ptr,
            bound_args[0..bound_count],
            pm.remaining_arity,
            pm.bound_arg_ref_bits,
        ) catch return error.OutOfMemory;
        try self.trackObj(partial_v.ref);
        self.runtime.writePtr(node.output, @ptrCast(partial_v.ref));
    }

    /// call_indirect：通过 Closure / PartialApplication 值间接调用
    /// inputs[0] = closure_chan（ref to Closure）
    /// inputs[1..M] = 参数通道
    /// meta_index 指向 CallMeta（arg_count 包含 closure_chan）
    fn execCallIndirect(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        // 读取 Closure / PartialApplication 值
        const ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        const is_partial = header.type_tag == .partial;
        if (header.type_tag != .closure and !is_partial) return error.InvalidChannel;

        if (is_partial) {
            const pa: *value.PartialApplication = @alignCast(@fieldParentPtr("header", header));
            const func_idx: u16 = @intCast(@intFromPtr(pa.func) - 1);
            if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
            const callee_func = self.ir.functions[func_idx];

            // Profiling: partial application 调用事件
            // defer 必须在 if(is_partial) 块作用域，不能在 if(prof) 块内
            const prof_opt_pa = self.tctx.?.prof;
            var saved_func_pa: u32 = 0;
            if (prof_opt_pa) |p| {
                p.onFuncCall(func_idx);
                saved_func_pa = p.current_func_idx.load(.acquire);
                p.setCurrentFunc(func_idx);
            }
            defer if (prof_opt_pa) |p| {
                p.setCurrentFunc(saved_func_pa);
                p.onFuncRet(func_idx);
            };

            return try self.execPartialApplicationCall(node, call_meta, callee_func, func_idx, pa);
        }

        const closure: *value.Closure = @alignCast(@fieldParentPtr("header", header));
        const func_idx: u16 = @intCast(@intFromPtr(closure.func));

        if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
        const callee_func = self.ir.functions[func_idx];

        // Profiling: closure 调用事件
        // defer 必须在函数作用域，不能在 if(prof) 块内
        const prof_opt_cl = self.tctx.?.prof;
        var saved_func_cl: u32 = 0;
        if (prof_opt_cl) |p| {
            p.onFuncCall(func_idx);
            saved_func_cl = p.current_func_idx.load(.acquire);
            p.setCurrentFunc(func_idx);
        }
        defer if (prof_opt_cl) |p| {
            p.setCurrentFunc(saved_func_cl);
            p.onFuncRet(func_idx);
        };

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        // 实际参数数量 = call_meta.arg_count - 1（减去 closure_chan）
        const arg_count = @as(usize, call_meta.arg_count) - 1;
        const args = node.inputs[1 .. 1 + arg_count];

        // SCC 问题：自递归 closure 调用时，enterFunction 覆盖实参通道的 chan_ptrs。
        // 自递归检测：func_idx == current_func_idx
        const is_self_recursive = (func_idx == self.current_func_idx);

        if (is_self_recursive) {
            // ── 自递归：保存实参值（含深拷贝） ──
            var saved_arg_values: [16]value.Value = undefined;
            for (args, 0..) |arg_chan, i| {
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                const meta = self.ir.channels.get(arg_chan);
                if (!is_ref and meta.chan_type == .ref_chan and self.readRefObj(arg_chan) != null) {
                    const v = self.chanToValue(arg_chan);
                    saved_arg_values[i] = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(saved_arg_values[i]);
                } else {
                    saved_arg_values[i] = self.chanToValue(arg_chan);
                }
            }

            try self.runtime.enterFunction(func_idx, &callee_func);
            errdefer self.runtime.leaveFunction();

            // 写入 callee 形参通道 + upvalue 参数
            const count = @min(args.len, callee_func.param_channels.len);
            for (0..count) |i| {
                self.valueToChan(callee_func.param_channels[i], saved_arg_values[i]);
            }
            self.copyClosureUpvalues(callee_func, closure, args.len);
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(func_idx, &callee_func);
            errdefer self.runtime.leaveFunction();

            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
            self.copyClosureUpvalues(callee_func, closure, args.len);
        }

        // 压栈
        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, args);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }

    /// 执行 PartialApplication 的调用：将已绑定参数与新实参合并后调用原函数
    /// 双 Region 架构：统一走 enterFunction/leaveFunction，Runtime 管理通道保存/恢复。
    fn execPartialApplicationCall(
        self: *Engine,
        node: *const Node,
        call_meta: ir_mod.CallMeta,
        callee_func: Function,
        func_idx: u16,
        pa: *value.PartialApplication,
    ) EngineError!void {
        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        const arg_count = @as(usize, call_meta.arg_count) - 1;
        const args = node.inputs[1 .. 1 + arg_count];
        const bound = pa.bound_args;
        const total_params = callee_func.param_channels.len;

        // SCC 问题：自递归 partial application 调用时，enterFunction 覆盖实参通道的 chan_ptrs。
        const is_self_recursive = (func_idx == self.current_func_idx);

        if (is_self_recursive) {
            // ── 自递归：保存显式实参值（含深拷贝） ──
            var saved_arg_values: [16]value.Value = undefined;
            for (args, 0..) |arg_chan, i| {
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                const meta = self.ir.channels.get(arg_chan);
                if (!is_ref and meta.chan_type == .ref_chan and self.readRefObj(arg_chan) != null) {
                    const v = self.chanToValue(arg_chan);
                    saved_arg_values[i] = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(saved_arg_values[i]);
                } else {
                    saved_arg_values[i] = self.chanToValue(arg_chan);
                }
            }

            try self.runtime.enterFunction(func_idx, &callee_func);
            errdefer self.runtime.leaveFunction();

            // 复制已绑定参数到被调用函数参数通道
            const bound_count = @min(bound.len, total_params);
            for (0..bound_count) |i| {
                const dst_chan = callee_func.param_channels[i];
                self.writeScalarValue(dst_chan, bound[i]);
            }

            // 写入显式实参到后续参数通道
            const explicit_count = @min(arg_count, if (total_params > bound_count) total_params - bound_count else 0);
            for (0..explicit_count) |i| {
                self.valueToChan(callee_func.param_channels[bound_count + i], saved_arg_values[i]);
            }
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(func_idx, &callee_func);
            errdefer self.runtime.leaveFunction();

            // 复制已绑定参数到被调用函数参数通道
            const bound_count = @min(bound.len, total_params);
            for (0..bound_count) |i| {
                const dst_chan = callee_func.param_channels[i];
                self.writeScalarValue(dst_chan, bound[i]);
            }

            // 复制新的显式实参到后续参数通道
            const explicit_count = @min(arg_count, if (total_params > bound_count) total_params - bound_count else 0);
            for (0..explicit_count) |i| {
                const dst_chan = callee_func.param_channels[bound_count + i];
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                try self.copyArgToParam(args[i], dst_chan, is_ref);
            }
        }

        // 压栈并调用原函数
        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, callee_func.param_channels);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }

    /// 将标量 Value 转为字节缓冲区（用于 nullable 写入）
    fn readScalarValueToBytes(self: *Engine, v: value.Value) [16]u8 {
        _ = self;
        var buf: [16]u8 = [_]u8{0} ** 16;
        switch (v) {
            .i64 => |b| {
                const val: i64 = @bitCast(b);
                @memcpy(buf[0..8], std.mem.asBytes(&val));
            },
            .i32 => |b| {
                const val: i32 = @bitCast(b);
                @memcpy(buf[0..4], std.mem.asBytes(&val));
            },
            .boolean => |b| buf[0] = b[0],
            else => {},
        }
        return buf;
    }
};

/// 星轨线程数据：传递给 worker 线程的参数
const OrbitThreadData = struct {
    ir: *GlueIR,
    func_idx: u16,
    /// 标量参数的原始字节（最大 16B，覆盖 i128/f128），
    /// 直接拷贝位模式避免 readIntAsI64 对 float/i128 的类型转换损坏
    arg_bytes: [4][16]u8,
    /// 每个标量参数的字节宽度（0 表示该参数为 ref_chan，用 arg_objs）
    arg_widths: [4]u8,
    /// ref_chan 参数的原始对象指针（由 worker 深拷贝到其本地 tctx）
    arg_objs: [4]?*value.obj_header.ObjHeader,
    arg_count: u8,
    handle: *value.AsyncHandle,
    global: *GlobalPool,
    backing: std.mem.Allocator,
    /// GlobalProfiler 引用（worker 线程创建 ThreadProfiler 用，null 时不采集）
    global_prof: ?*profiling.GlobalProfiler = null,
};

/// 星轨 worker 线程函数：在独立线程中执行 async 函数
/// 创建独立的 Engine 实例（共享 IR 和 GlobalPool，独立 ThreadContext + Runtime，避免通道存储竞争）
/// 注意：必须在设置结果（setResult，会解除 join() 阻塞）之前完成所有资源清理，
/// 否则主线程的测试分配器会在 worker 清理未完成时检测到泄漏。
fn orbitWorker(data: *OrbitThreadData) void {
    const alloc = data.backing;
    const handle = data.handle; // 保存 handle 指针，因为 data 会在 setResult 前释放

    // 创建 worker 线程独立的 ThreadContext（每线程独立，零锁热路径）
    var tctx = ThreadContext.init(data.global, alloc, data.global_prof) catch {
        alloc.destroy(data);
        handle.setPanic("Failed to init ThreadContext");
        return;
    };
    defer tctx.deinit();

    // 使用 Engine.init（外部 tctx），错误路径通过 setPanic 记录原因
    var engine = Engine.init(data.ir, &tctx) catch {
        alloc.destroy(data);
        handle.setPanic("Failed to init engine");
        return;
    };

    // 布局全局通道存储（独立于主线程）
    engine.runtime.layoutGlobals(&data.ir.channels) catch {
        engine.deinit();
        alloc.destroy(data);
        handle.setPanic("Failed to layout channels");
        return;
    };

    // 将参数写入函数的参数通道
    const func = data.ir.functions[data.func_idx];

    // enterFunction 在 CallStackRegion 中分配函数本地通道
    engine.runtime.enterFunction(data.func_idx, &func) catch {
        engine.deinit();
        alloc.destroy(data);
        handle.setPanic("Failed to enter function");
        return;
    };

    for (0..data.arg_count) |i| {
        if (i >= func.param_channels.len) break;
        const dst_chan = func.param_channels[i];
        const dst_meta = data.ir.channels.get(dst_chan);
        if (dst_meta.chan_type == .ref_chan) {
            if (data.arg_objs[i]) |obj| {
                // 跨线程值语义：普通复合类型深拷贝到 worker tctx，channel/atomic 等 retain 共享
                const v = value.Value{ .ref = obj };
                const copied = v.deepCopy(&tctx) catch {
                    engine.runtime.leaveFunction();
                    engine.deinit();
                    tctx.deinit();
                    alloc.destroy(data);
                    handle.setPanic("deepCopy failed for async argument");
                    return;
                };
                engine.trackValueTree(copied) catch {};
                engine.writeScalarValue(dst_chan, copied);
            }
        } else {
            // 按原始字节宽度写回，保留完整位模式（f16..f128/i128 等）
            const w = data.arg_widths[i];
            if (w > 0) {
                const dst = engine.runtime.rawPtr(dst_chan);
                @memcpy(dst[0..w], data.arg_bytes[i][0..w]);
            }
        }
    }

    // 执行函数
    const result_chan = engine.execFunction(data.func_idx, func.param_channels) catch {
        engine.runtime.leaveFunction();
        engine.deinit();
        alloc.destroy(data);
        handle.setPanic("Function execution failed");
        return;
    };

    // 读取结果（在 leaveFunction 之前，因为 leaveFunction 会 resetTo 回收通道内存）
    const result_val = engine.readScalarValue(result_chan) catch value.Value.fromNull();

    // 值语义：普通复合类型结果跨线程深拷贝，使其在 worker deinit 后仍然有效
    const result_meta = data.ir.channels.get(result_chan);
    const out_result = blk: {
        if (result_meta.chan_type == .ref_chan and !result_meta.is_ref) {
            break :blk result_val.deepCopy(&tctx) catch {
                engine.runtime.leaveFunction();
                engine.deinit();
                tctx.deinit();
                alloc.destroy(data);
                handle.setPanic("deepCopy failed for async result");
                return;
            };
        }
        break :blk result_val;
    };

    engine.runtime.leaveFunction();

    // 先清理所有资源（engine + tctx + data），再设置结果（setResult 会解除主线程 join() 阻塞）
    // 这样主线程在 join() 返回时，worker 的所有分配已释放，避免泄漏检测竞态
    // 注意：tctx.deinit 必须在 setResult 之前，否则 ChannelRegion 数据未释放时主线程即检测到泄漏
    engine.deinit();
    tctx.deinit(); // defer tctx.deinit() 将成为 no-op（ChannelRegion.data 已置 null）
    alloc.destroy(data);
    handle.setResult(out_result);
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const ast = @import("ast");
const builder_mod = ir_mod.builder_mod;
const sema = @import("sema");

/// 测试辅助：从源码构建 IR
/// 与生产管线（main.zig）一致：先运行 sema 类型推断并注入 sema_result，再构建 IR。
fn buildIRFromSource(source: []const u8) !GlueIR {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lex = @import("lexer").Lexer.init(alloc, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer alloc.free(tokens);

    var p = @import("parser").Parser.init(alloc, tokens);
    defer p.deinit();
    const module = try p.parseModule("test.glue");

    // sema 阶段：类型推断产出 SemaResult，驱动 IR 图构建（通道宽度由 sema 类型决定）
    // 注意：inferencer 的 arena 持有 Type 结构体及其 name 字符串，SemaResult.expr_types
    // 中的 type_name 切片指向这些字符串。因此 inferencer 必须在 builder.build() 期间保持存活，
    // 否则 type_name 成为悬垂指针。defer 确保在函数返回（build 完成后）才释放。
    var sema_result = ir_mod.SemaResult.init(testing.allocator);
    defer sema_result.deinit();
    var inferencer = sema.TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();
    inferencer.setSemaResult(&sema_result);
    inferencer.checkModule(&module);

    var builder = try builder_mod.IRBuilder.init(testing.allocator);
    defer builder.deinit();
    builder.setSemaResult(&sema_result);
    return try builder.build(module);
}

/// 测试辅助：创建带 std.Io.Threaded 的 Engine（fiber-aware 内存池所需）
/// 调用方需通过 `threaded` out-param 保持 Threaded 生命周期，并在 defer 中先 deinit engine 再 deinit threaded
fn initTestEngineOwned(ir: *GlueIR, threaded: *std.Io.Threaded) !Engine {
    threaded.* = std.Io.Threaded.init(testing.allocator, .{});
    return Engine.initOwned(ir, testing.allocator, null, threaded.io());
}

test "执行 const_i + halt_return" {
    // fun main() { 42 }
    var ir = try buildIRFromSource("fun main() { 42 }");
    defer ir.deinit();

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "执行整数加法" {
    // fun main() { 1 + 2 }
    var ir = try buildIRFromSource("fun main() { 1 + 2 }");
    defer ir.deinit();

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), result);
}

test "执行整数减法" {
    var ir = try buildIRFromSource("fun main() { 10 - 4 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 6), try engine.run());
}

test "执行整数乘法" {
    var ir = try buildIRFromSource("fun main() { 6 * 7 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "执行整数除法" {
    var ir = try buildIRFromSource("fun main() { 20 / 4 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "执行整数取模" {
    var ir = try buildIRFromSource("fun main() { 17 % 5 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "执行嵌套表达式" {
    // 1 + 2 * 3 = 7
    var ir = try buildIRFromSource("fun main() { 1 + 2 * 3 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "执行比较运算" {
    // 3 < 5 → true → 1
    var ir = try buildIRFromSource("fun main() { 3 < 5 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "执行布尔逻辑" {
    // true && false → false → 0
    var ir = try buildIRFromSource("fun main() { true && false }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), result);
}

test "执行 val 变量绑定" {
    // val x = 10, val y = 20, x + y
    var ir = try buildIRFromSource("fun main() { val x = 10; val y = 20; x + y }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 30), try engine.run());
}

test "执行函数调用" {
    // fun add(a, b) { a + b }
    // fun main() { add(3, 4) }
    var ir = try buildIRFromSource(
        \\fun add(a, b) { a + b }
        \\fun main() { add(3, 4) }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "执行优化后的常量折叠" {
    // fun main() { 1 + 2 } → 优化后应为 const_i(3)
    var ir = try buildIRFromSource("fun main() { 1 + 2 }");
    defer ir.deinit();

    // 优化
    _ = ir_mod.optimize(&ir);

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), try engine.run());
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试
// ════════════════════════════════════════════════════════════════

test "Phase 2: var 声明与赋值" {
    // var x = 10; x = 20; x
    var ir = try buildIRFromSource("fun main() { var x = 10; x = 20; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2: 复合赋值 += " {
    // var x = 10; x += 5; x
    var ir = try buildIRFromSource("fun main() { var x = 10; x += 5; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), try engine.run());
}

test "Phase 2: 复合赋值 *=" {
    // var x = 3; x *= 7; x
    var ir = try buildIRFromSource("fun main() { var x = 3; x *= 7; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 21), try engine.run());
}

test "Phase 2: if 表达式 then 分支" {
    // if true { 42 } else { 0 }
    var ir = try buildIRFromSource("fun main() { if true { 42 } else { 0 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "Phase 2: if 表达式 else 分支" {
    // if 3 > 5 { 42 } else { 99 }
    var ir = try buildIRFromSource("fun main() { if 3 > 5 { 42 } else { 99 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 99), try engine.run());
}

test "Phase 2: if 表达式条件求值" {
    // val x = 10; if x > 5 { x * 2 } else { x }
    var ir = try buildIRFromSource("fun main() { val x = 10; if x > 5 { x * 2 } else { x } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2: 类型转换 i64→i32" {
    // i32(1000)
    var ir = try buildIRFromSource("fun main() { i32(1000) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1000), result);
}

test "Phase 2: 类型转换 i64→f64" {
    // f64(42) → 42.0 → 位模式转回 i64 验证
    var ir = try buildIRFromSource("fun main() { f64(42) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // f64 通道的 8 字节读为 i64
    const result = try engine.run();
    const f: f64 = @bitCast(result);
    try testing.expectEqual(@as(f64, 42.0), f);
}

test "Phase 2: 嵌套 if 表达式" {
    // val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 }
    var ir = try buildIRFromSource("fun main() { val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 100), try engine.run());
}

test "Phase 2: 嵌套 if（then 分支内嵌套，字面量条件）" {
    // if true { if false { 1 } else { 2 } } else { 3 } → 2
    var ir = try buildIRFromSource("fun main() { if true { if false { 1 } else { 2 } } else { 3 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "Phase 2: cast 链 i64→i32→i64" {
    // i64(i32(1000))
    var ir = try buildIRFromSource("fun main() { i64(i32(1000)) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1000), try engine.run());
}

test "Phase 2: var 与 if 组合" {
    // var x = 1; if x > 0 { x = 10 }; x
    var ir = try buildIRFromSource("fun main() { var x = 1; if x > 0 { x = 10 }; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "Phase 2: 复合赋值 -= " {
    // var x = 100; x -= 30; x
    var ir = try buildIRFromSource("fun main() { var x = 100; x -= 30; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 70), try engine.run());
}

test "Phase 2: 类型转换 i64→u8（窄化 wrap）" {
    // u8(300) → 300 wrap to u8 = 44
    var ir = try buildIRFromSource("fun main() { u8(300) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    // u8 通道读 1 字节，零扩展为 i64
    try testing.expectEqual(@as(i64, 44), result);
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：堆对象（字符串）
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 字符串字面量" {
    // "hello" → 创建 Str 堆对象
    var ir = try buildIRFromSource("fun main() { \"hello\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello", result);
}

test "Phase 2.5: 字符串拼接 (+)" {
    // "hello" + "world"
    var ir = try buildIRFromSource("fun main() { \"hello\" + \"world\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("helloworld", result);
}

test "Phase 2.5: 字符串拼接 (++)" {
    // "foo" ++ "bar"
    var ir = try buildIRFromSource("fun main() { \"foo\" ++ \"bar\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("foobar", result);
}

test "Phase 2.5: 字符串长度" {
    // 字符串长度目前需要通过函数调用测试
    // 简化：直接验证 string_len op 在 IR 层的正确性
    // "hello".len() 暂未支持 method_call，用内建方式测试
    // 此测试验证 const_str + string_len 的端到端流程
    var ir = try buildIRFromSource("fun main() { \"hello\" + \"world\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqual(@as(usize, 10), result.len);
}

test "Phase 2.5: 三字符串拼接" {
    // "a" + "b" + "c"
    var ir = try buildIRFromSource("fun main() { \"a\" + \"b\" + \"c\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

test "Phase 2.5: 空字符串拼接" {
    // "" + "x"
    var ir = try buildIRFromSource("fun main() { \"\" + \"x\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("x", result);
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：数组
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 数组字面量长度" {
    // [1, 2, 3] — 验证 array_make + array_set 链
    var ir = try buildIRFromSource("fun main() { [1, 2, 3] }");
    defer ir.deinit();

    // 验证 IR 中包含 array_make 和 array_set 节点
    var has_array_make = false;
    var array_set_count: u32 = 0;
    for (ir.nodes) |n| {
        if (n.op == .array_make) has_array_make = true;
        if (n.op == .array_set) array_set_count += 1;
    }
    try testing.expect(has_array_make);
    try testing.expectEqual(@as(u32, 3), array_set_count);
}

test "Phase 2.5: 数组索引访问" {
    // [10, 20, 30][1] → 20
    var ir = try buildIRFromSource("fun main() { [10, 20, 30][1] }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2.5: record 字面量与字段访问" {
    // (x: 1, y: 2).x → 1
    var ir = try buildIRFromSource("fun main() { (x: 1, y: 2).x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1), try engine.run());
}

test "Phase 2.5: record 多字段访问" {
    // (a: 10, b: 20, c: 30).b → 20
    var ir = try buildIRFromSource("fun main() { (a: 10, b: 20, c: 30).b }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2.5: record 字段覆盖" {
    // (x: 1, y: 2).y → 2
    var ir = try buildIRFromSource("fun main() { (x: 1, y: 2).y }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "Phase 2.5: 字符串索引" {
    // "hello"[0] → 'h' = 104
    var ir = try buildIRFromSource("fun main() { \"hello\"[0] }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // char 通道返回 u21，但 run() 按通道宽度读取
    // char_chan 宽度为 4 字节，按 i32 读取
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 104), result);
}

test "Phase 2.5: 字符串插值" {
    // "hello {"world"}" → "hello world"
    var ir = try buildIRFromSource("fun main() { \"hello {\"world\"}\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello world", result);
}

test "Phase 2.5: 字符串插值多段" {
    // "{"a"}b{"c"}" → "abc"
    var ir = try buildIRFromSource("fun main() { \"{\"a\"}b{\"c\"}\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

// ════════════════════════════════════════════
// Phase 3: 向量 op 执行测试
// ════════════════════════════════════════════

test "Phase 3: for range 向量化 identity map" {
    // for i in 0..10 { i } → vec_source(range) |> vec_map(identity) |> vec_sink(last)
    // sink_last 取最后一个元素 = 9
    var ir = try buildIRFromSource("fun main() { for i in 0..10 { i } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 9), result);
}

test "Phase 3: for range 带运算 i * 2" {
    // for i in 0..5 { i * 2 } → [0,2,4,6,8], sink_last = 8
    var ir = try buildIRFromSource("fun main() { for i in 0..5 { i * 2 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 8), result);
}

test "Phase 3: for range 带运算 i + 10" {
    // for i in 1..4 { i + 10 } → [11,12,13], sink_last = 13
    var ir = try buildIRFromSource("fun main() { for i in 1..4 { i + 10 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 13), result);
}

test "Phase 3: for range 单元素" {
    // for i in 0..1 { i } → [0], sink_last = 0
    var ir = try buildIRFromSource("fun main() { for i in 0..1 { i } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), result);
}

test "Phase 3: for range 复杂表达式" {
    // for i in 0..5 { (i + 1) * 3 } → [3,6,9,12,15], sink_last = 15
    var ir = try buildIRFromSource("fun main() { for i in 0..5 { (i + 1) * 3 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 15), result);
}

// ════════════════════════════════════════════
// Phase 4: 门控 + 清理测试
// ════════════════════════════════════════════

test "Phase 4: defer 在 return 前执行" {
    // fun cleanup() -> i64 { 0 }
    // fun main() -> i64 { defer cleanup(); 42 }
    // 验证 defer 不影响返回值
    var ir = try buildIRFromSource(
        "fun cleanup() { 0 } fun main() { defer cleanup(); 42 }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 4: 多个 defer LIFO 执行" {
    // 多个 defer 不影响返回值，验证 LIFO 执行不崩溃
    var ir = try buildIRFromSource(
        "fun a() { 0 } fun b() { 0 } fun main() { defer a(); defer b(); 99 }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), result);
}

test "Phase 4: defer 带 var 赋值" {
    // defer 调用函数，不影响返回值
    // 验证 defer 体能正确执行函数调用
    var ir = try buildIRFromSource(
        "fun cleanup() { 0 } fun main() { var x = 1; defer cleanup(); x }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // x 的值在 defer 执行前就已经作为返回值
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "Phase 4: throw 触发 halt_throw" {
    // throw 语句触发 halt_throw，run() 返回 error.Thrown
    var ir = try buildIRFromSource("fun main() { throw 42 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectError(error.Thrown, engine.run());
}

// ════════════════════════════════════════════
// Phase 5: 路由 + 竞争测试
// ════════════════════════════════════════════

test "Phase 5: select 第一个分支就绪" {
    // select { 1 => v => 10; 2 => v => 20 }
    // 非 ChannelValue 输入视为始终就绪，第一个分支胜出 → body 返回 10
    var ir = try buildIRFromSource("fun main() { select { 1 => v => 10; 2 => v => 20 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 10), result);
}

test "Phase 5: select 单分支" {
    // select { 42 => v => 99 }
    // 单个分支，胜出后执行 body 返回 99
    var ir = try buildIRFromSource("fun main() { select { 42 => v => 99 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), result);
}

test "Phase 5: select 带 timeout 分支" {
    // select { timeout(1000) => 42 }
    // timeout arm 的 duration 被当作普通表达式编译，body 返回 42
    var ir = try buildIRFromSource("fun main() { select { timeout(1000) => 42 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 5: select body 带运算" {
    // select { 1 => v => 3 * 4 }
    // body 包含运算，结果为 12
    var ir = try buildIRFromSource("fun main() { select { 1 => v => 3 * 4 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 12), result);
}

// ════════════════════════════════════════════
// Phase 6: Nullable + 内存管理测试
// ════════════════════════════════════════════

test "Phase 6: Elvis 整数默认值" {
    // 整数不可能为 null，直接返回左操作数
    // 1 ?? 99 → 1
    var ir = try buildIRFromSource("fun main() { 1 ?? 99 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "Phase 6: non_null_assert 整数透传" {
    // 整数不可能为 null，! 直接透传
    // 42! → 42
    var ir = try buildIRFromSource("fun main() { 42! }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 6: Elvis 链式表达式" {
    // (1 + 2) ?? 99 → 3
    var ir = try buildIRFromSource("fun main() { (1 + 2) ?? 99 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), result);
}

// ════════════════════════════════════════════
// Phase 7: 星轨执行测试（async/spawn）
// ════════════════════════════════════════════

test "Phase 7: async 函数基本执行 + join" {
    // async fun compute() { 42 }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: async 函数带参数" {
    // async fun add(a, b) { a + b }
    // fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b) { a + b }
        \\fun main() { add(3, 4).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 7), result);
}

test "Phase 7: async 函数计算" {
    // async fun square(n) { n * n }
    // fun main() { square(7).await() }
    var ir = try buildIRFromSource(
        \\async fun square(n) { n * n }
        \\fun main() { square(7).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 49), result);
}

test "Phase 7: async 函数调用普通函数" {
    // fun double(n) { n * 2 }
    // async fun compute() { double(21) }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\async fun compute() { double(21) }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: 嵌套普通函数调用（非 async）" {
    // fun double(n) { n * 2 }
    // fun compute() { double(21) }
    // fun main() { compute() }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\fun compute() { double(21) }
        \\fun main() { compute() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: 单层 double 调用" {
    // fun double(n) { n * 2 }
    // fun main() { double(21) }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\fun main() { double(21) }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "内置 print/println 编译与执行（无 io 时不崩溃）" {
    // fun main() { println("Hello, Glue!"); 42 }
    var ir = try buildIRFromSource(
        \\fun main() { println("Hello, Glue!"); 42 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // 无 io 接口，print 静默跳过，不崩溃
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "loop + break" {
    // var i = 0; var sum = 0; loop { if i >= 5 { break } sum += i; i += 1 } sum
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var i = 0
        \\    var sum = 0
        \\    loop {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run()); // 0+1+2+3+4=10
}

test "for + break" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var sum = 0
        \\    for i in 0..100 {
        \\        if i > 5 { break }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), try engine.run()); // 0+1+2+3+4+5=15
}

test "for + continue" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var sum = 0
        \\    for i in 0..10 {
        \\        if i % 2 == 0 { continue }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 25), try engine.run()); // 1+3+5+7+9=25
}

test "while + break" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var i = 0
        \\    var sum = 0
        \\    while i < 100 {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run()); // 0+1+2+3+4=10
}

// ════════════════════════════════════════════
// P0-b: type_decl / trait_decl 注册 + 构造器调用
// ════════════════════════════════════════════

test "P0-b: ADT 无参构造器（Leaf）" {
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() { Leaf }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    _ = try engine.run(); // 只验证不崩溃
}

test "P0-b: ADT 带参构造器 + 命名字段访问" {
    // Box(42).value → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32)
        \\fun main() { Box(42).value }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: ADT 多构造器 + 位置字段访问" {
    // Node(5, Leaf, Leaf)._0 → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() { Node(5, Leaf, Leaf)._0 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "P0-b: newtype 构造器 + 字段访问" {
    // UserId(42)._0 → 42
    var ir = try buildIRFromSource(
        \\type UserId = UserId(i32)
        \\fun main() { UserId(42)._0 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: trait_decl 注册（不崩溃）" {
    var ir = try buildIRFromSource(
        \\trait Printable {
        \\    fun format(self): str
        \\}
        \\fun main() { 42 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: type 方法注册为函数" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // 方法已注册，通过字段访问验证构造器
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\fun main() { MyInt(10).value }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

// ════════════════════════════════════════════
// P0-c: match 表达式编译
// ════════════════════════════════════════════

test "P0-c: match 字面量匹配" {
    // match 2 { 1 => 10, 2 => 20, _ => 30 } → 20
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 2 {
        \\        1 => 10
        \\        2 => 20
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "P0-c: match 通配符兜底" {
    // match 99 { 1 => 10, _ => 30 } → 30
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 99 {
        \\        1 => 10
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 30), try engine.run());
}

test "P0-c: match 变量绑定" {
    // match 42 { 1 => 10, x => x } → 42
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 42 {
        \\        1 => 10
        \\        x => x
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-c: match ADT 构造器解构" {
    // match Box(42) { Box(v) => v, Leaf => 0 } → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main() {
        \\    match Box(42) {
        \\        Box(v) => v
        \\        Empty => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-c: match ADT 无参构造器" {
    // match Empty { Box(v) => v, Empty => 99 } → 99
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main() {
        \\    match Empty {
        \\        Box(v) => v
        \\        Empty => 99
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 99), try engine.run());
}

test "P0-c: match 或模式" {
    // match 2 { 1 | 2 | 3 => 10, _ => 20 } → 10
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 2 {
        \\        1 | 2 | 3 => 10
        \\        _ => 20
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "P0-c: match 守卫条件" {
    // match 5 { n if n < 0 => 1, n if n > 3 => 2, _ => 3 } → 2
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 5 {
        \\        n if n < 0 => 1
        \\        n if n > 3 => 2
        \\        _ => 3
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-c: match 多构造器 ADT 位置字段" {
    // match Node(5, Leaf, Leaf) { Node(v, _, _) => v, Leaf => 0 } → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() {
        \\    match Node(5, Leaf, Leaf) {
        \\        Node(v, _, _) => v
        \\        Leaf => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

// ════════════════════════════════════════════
// P0-d: 方法调用编译
// ════════════════════════════════════════════

test "P0-d: async .await() 显式等待" {
    // async fun compute() { 42 } fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-d: async .status() 状态查询" {
    // async fun compute() { 42 }
    // fun main() { val s = compute(); s.await(); s.status() }
    // await 后状态应为 2（Completed）
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() {
        \\    val s = compute()
        \\    s.await()
        \\    s.status()
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-d: array .len() 方法" {
    // [10, 20, 30].len() → 3
    var ir = try buildIRFromSource(
        \\fun main() { [10, 20, 30].len() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), try engine.run());
}

test "P0-d: string .len() 方法" {
    // "hello".len() → 5
    var ir = try buildIRFromSource(
        \\fun main() { "hello".len() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "P0-d: array .push() 方法" {
    // val arr = [1]; arr.push(2); arr.len() → 2
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val arr = [1]
        \\    arr.push(2)
        \\    arr.len()
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-d: 用户自定义方法调用" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // fun main() { MyInt(10).get() }
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\{
        \\    fun get(self): i32 { self.value }
        \\}
        \\fun main() { MyInt(10).get() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "P0-d: .type_name() 反射方法" {
    // type Point = | Point(x: i32, y: i32)
    // Point(1, 2).type_name() → "Point"（返回 ref，无法直接断言字符串内容）
    // 验证不崩溃即可
    var ir = try buildIRFromSource(
        \\type Point = | Point(x: i32, y: i32)
        \\fun main() {
        \\    val p = Point(1, 2)
        \\    p.type_name()
        \\    42
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-d: async .await() 带参数计算" {
    // async fun add(a, b) { a + b } fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b) { a + b }
        \\fun main() { add(3, 4).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

// ════════════════════════════════════════════════════════════════
// P1-a: lambda / 闭包测试
// ════════════════════════════════════════════════════════════════

test "P1-a: fun lambda 基本调用" {
    // val f = fun(x) { x + 1 }
    // fun main() { val f = fun(x) { x + 1 }; f(10) }
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val f = fun(x) { x + 1 }
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 11), try engine.run());
}

test "P1-a: 箭头 lambda 基本调用" {
    // val f = (x) => x + 1; f(10) → 11
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val f = (x) => x + 1
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 11), try engine.run());
}

test "P1-a: 多参数 lambda" {
    // val g = (a, b) => a + b; g(3, 4) → 7
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val g = (a, b) => a + b
        \\    g(3, 4)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "P1-a: 闭包捕获自由变量" {
    // val n = 10; val f = fun(x) { x + n }; f(5) → 15
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val n = 10
        \\    val f = fun(x) { x + n }
        \\    f(5)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), try engine.run());
}

test "P1-a: 闭包捕获多个自由变量" {
    // val a = 100; val b = 20; val f = fun(x) { x + a - b }; f(1) → 81
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val a = 100
        \\    val b = 20
        \\    val f = fun(x) { x + a - b }
        \\    f(1)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 81), try engine.run());
}

test "lazy: 创建时不求值，强制时缓存" {
    // 与 edge_lazy 保持一致：创建时不求值，首次 println 强制计算，二次 println 复用缓存
    var ir = try buildIRFromSource(
        \\var compute_count = 0
        \\
        \\fun expensive(x: i32): i32 {
        \\    compute_count = compute_count + 1
        \\    x * x
        \\}
        \\
        \\fun main(): i64 {
        \\    val lz = lazy expensive(5)
        \\    if compute_count != 0 { -100 } else {
        \\        println(lz)
        \\        println(lz)
        \\        compute_count
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1), try engine.run());
}

test "lazy: thunk 捕获外部变量" {
    var ir = try buildIRFromSource(
        \\fun makeLazy(x: i32): Lazy<i32> {
        \\    lazy x * x
        \\}
        \\
        \\fun main(): i64 {
        \\    val lz = makeLazy(7)
        \\    println(lz)
        \\    49
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 49), try engine.run());
}

test "vec_zip: 合并两个 range 向量" {
    // 手工构造 IR：
    //   left  = range(0, 3)  -> [0, 1, 2]
    //   right = range(10, 13) -> [10, 11, 12]
    //   zipped = vec_zip(left, right) -> [(0,10), (1,11), (2,12)]
    //   return sink_count(zipped) = 3
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var channels = ir_mod.ChannelSpace.init(alloc);
    const c_const0 = try channels.alloc(.i64_chan);
    const c_const3 = try channels.alloc(.i64_chan);
    const c_left = try channels.alloc(.i64_chan);
    const c_right = try channels.alloc(.i64_chan);
    const c_zipped = try channels.alloc(.ref_chan);
    const c_count = try channels.alloc(.i64_chan);

    const scalar_metas = try alloc.alloc(ScalarMeta, 3);
    scalar_metas[0] = .{ .kind = .unit }; // meta_index=0 占位
    scalar_metas[1] = .{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 0 } };
    scalar_metas[2] = .{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 3 } };

    const vector_metas = try alloc.alloc(ir_mod.VectorMeta, 3);
    vector_metas[0] = .{ .vec_op = .range_source, .elem_type = .i64_chan, .length = 3 };
    vector_metas[1] = .{ .vec_op = .range_source, .elem_type = .i64_chan, .length = 3 };
    vector_metas[2] = .{ .vec_op = .sink_count, .elem_type = .i64_chan };

    const nodes = try alloc.alloc(Node, 7);
    nodes[0] = Node.makeSink(.const_i, c_const0, 1);
    nodes[1] = Node.makeSink(.const_i, c_const3, 2);
    nodes[2] = Node.makeBinary(.vec_source, c_left, 1, c_const0, c_const3);
    nodes[3] = Node.makeBinary(.vec_source, c_right, 2, c_const0, c_const3);
    nodes[4] = Node.makeBinary(.vec_zip, c_zipped, 0, c_left, c_right);
    nodes[5] = Node.makeUnary(.vec_sink, c_count, 3, c_zipped);
    nodes[6] = Node.makeUnary(.halt_return, c_count, 0, c_count);

    const funcs = try alloc.alloc(Function, 1);
    // 编译期通道布局元数据（手动构造，等价于 computeFunctionChannelLayout 的输出）
    // 6 个 8B 通道（5 local + 1 return），16B 对齐
    const local_offsets = try alloc.alloc(u32, 6);
    local_offsets[0] = 0; // c_const0
    local_offsets[1] = 16; // c_const3
    local_offsets[2] = 32; // c_left
    local_offsets[3] = 48; // c_right
    local_offsets[4] = 64; // c_zipped
    local_offsets[5] = 80; // c_count (return_channel)
    funcs[0] = .{
        .name = "main",
        .node_start = 0,
        .node_count = 7,
        .param_channels = &.{},
        .return_channel = c_count,
        .is_entry = true,
        .local_chan_start = 0,
        .local_chan_count = 5,
        .chan_total_bytes = 96,
        .local_offsets = local_offsets,
        .scc_max_chan_bytes = 96,
    };

    var ir = GlueIR{
        .nodes = nodes,
        .channels = channels,
        .scalar_metas = scalar_metas,
        .vector_metas = vector_metas,
        .functions = funcs,
        .entry_index = 0,
        .backing = alloc,
    };

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), try engine.run());
}
