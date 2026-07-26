//! work-stealing 协程调度器：管理 worker 线程池与帧池。
//!
//! M:N 调度——固定 N 个 worker 线程（默认 = CPU 核数），
//! 可跑任意多协程。work-stealing 跨 worker 偷协程。
//!
//! spawn 流程（spec 2.3）：
//! 1. 从帧池分配帧 + 写参数 + state=0
//! 2. 选目标 worker（轮询或最闲），入其就绪队列
//! 3. 帧状态设 Ready
//!
//! 主循环（注入到 Worker）：
//! - popLocal → trySteal(随机 victim) → waitForWork(backoff)
//! - 拿到帧后执行段（state_machine.runSegment）
//! - SegmentResult 处理：advance→pushReady / suspend→让出 / complete→回池 / failed→回池

const std = @import("std");
const frame_mod = @import("frame.zig");
const CoroutineFrame = frame_mod.CoroutineFrame;
const CoroutineStatus = frame_mod.CoroutineStatus;
const FramePool = frame_mod.FramePool;
const suspend_registry_mod = @import("suspend_registry.zig");
const SuspendRegistry = suspend_registry_mod.SuspendRegistry;
const worker_mod = @import("worker.zig");
const Worker = worker_mod.Worker;
const ir_mod = @import("ir");
const Node = ir_mod.Node;
const CoroutineMeta = ir_mod.CoroutineMeta;
const Value = @import("value").Value;
const profiling_stats = @import("profiling").stats;
const state_machine = @import("state_machine.zig");
const SegmentContext = state_machine.SegmentContext;
const SegmentResult = state_machine.SegmentResult;
const cancel_mod = @import("cancel.zig");

/// Engine 工厂接口：由 Engine 实现，通过 vtable 注入 Scheduler。
///
/// 依赖反转：coroutine 模块不能 import engine（循环依赖），
/// 通过此接口让 Scheduler 为每个 worker 线程创建独立 Engine 实例。
///
/// 每个 worker 线程需要独立 Engine：
/// - 共享 ir（只读 IR）
/// - 独立 tctx/runtime/call_stack（线程本地执行状态）
/// - 共享 global（对象池）
///
/// worker 线程启动时调用 createEngine 创建 Engine，
/// 结束时调用 destroyEngine 释放。
/// buildSegmentContext 为 worker-local Engine 构造 SegmentContext。
pub const EngineContext = struct {
    ctx: *anyopaque,
    /// 创建 worker-local Engine 实例（每个 worker 线程调用一次）
    create_engine: *const fn (ctx: *anyopaque) anyerror!*anyopaque,
    /// 销毁 worker-local Engine 实例（worker 线程退出时调用）
    destroy_engine: *const fn (engine: *anyopaque) void,
    /// 为 worker-local Engine 构造 SegmentContext（vtable 回调委托该 Engine）
    build_segment_context: *const fn (engine: *anyopaque) SegmentContext,
};

/// 全局协程调度器：管理 worker 线程池与帧池。
pub const Scheduler = struct {
    workers: []Worker,
    frame_pool: *FramePool,
    suspend_registry: *SuspendRegistry,
    io: std.Io,
    shutdown: std.atomic.Value(bool),
    backing: std.mem.Allocator,
    /// 轮询分配计数器（spawn 时选 worker 用）
    next_worker: std.atomic.Value(u32),
    /// worker 句柄数组（init 时分配，deinit 时释放）
    workers_storage: ?[]Worker = null,
    /// CoroutineMeta 表（按 func_idx 索引），由 Engine 在启动协程前注入
    /// 未注入 func_idx 对应的 meta 时，spawn 返回 error.MissingMeta
    coroutine_metas: ?[]const CoroutineMeta = null,
    /// IR 节点流引用（runSegment 遍历段内节点用），由 Engine 注入
    ir_nodes: ?[]const Node = null,
    /// Engine 工厂接口（由 Engine 注入，用于创建 worker-local Engine 实例）
    engine_ctx: ?EngineContext = null,

    /// 创建调度器（不启动 worker 线程，需调用 startWorkers）
    pub fn init(
        backing: std.mem.Allocator,
        io: std.Io,
        frame_pool: *FramePool,
        suspend_registry: *SuspendRegistry,
    ) Scheduler {
        return .{
            .workers = &.{},
            .frame_pool = frame_pool,
            .suspend_registry = suspend_registry,
            .io = io,
            .shutdown = std.atomic.Value(bool).init(false),
            .backing = backing,
            .next_worker = std.atomic.Value(u32).init(0),
        };
    }

    /// 注入 CoroutineMeta 表与 IR 节点流（Engine 启动协程前调用）
    pub fn setCoroutineIR(self: *Scheduler, metas: []const CoroutineMeta, nodes: []const Node) void {
        self.coroutine_metas = metas;
        self.ir_nodes = nodes;
    }

    /// 注入 Engine 工厂接口（Engine 构造后调用，用于创建 worker-local Engine 实例）
    pub fn setEngineContext(self: *Scheduler, ectx: EngineContext) void {
        self.engine_ctx = ectx;
    }

    /// 启动 worker 线程池（N = worker_count，默认 CPU 核数）
    pub fn startWorkers(self: *Scheduler, worker_count: usize) !void {
        const n = if (worker_count == 0) std.Thread.getCpuCount() catch 1 else worker_count;
        const storage = try self.backing.alloc(Worker, n);
        self.workers_storage = storage;
        for (storage, 0..) |*w, i| {
            w.* = try Worker.init(@intCast(i), self.backing);
            w.scheduler = @ptrCast(self);
        }
        self.workers = storage;
        // 注入唤醒回调
        self.suspend_registry.setEnqueueCallback(@ptrCast(self), enqueueFrame);
        // 启动所有 worker 线程
        for (storage) |*w| {
            try w.start(workerRun);
        }
    }

    /// 释放调度器资源：通知 worker 退出 + join + 释放 workers 数组
    pub fn deinit(self: *Scheduler) void {
        self.requestShutdown();
        for (self.workers) |*w| {
            w.join();
            w.deinit();
        }
        if (self.workers_storage) |storage| {
            self.backing.free(storage);
            self.workers_storage = null;
            self.workers = &.{};
        }
    }

    /// 提交协程：分配帧 + 写参数 + state=0 + 入就绪队列
    pub fn spawn(self: *Scheduler, coroutine_meta: *const CoroutineMeta, args: []const Value) !*CoroutineFrame {
        const frame = try self.frame_pool.alloc(coroutine_meta.func_idx, coroutine_meta.frame_layout);
        // 写参数到帧的 locals 区参数槽
        // 参数按 FrameLayout.slots 布局写入：标量内联 payload，引用存指针字节
        const locals = frame.localsPtr();
        const slots = coroutine_meta.frame_layout.slots;
        var i: usize = 0;
        while (i < args.len and i < slots.len) : (i += 1) {
            const slot = slots[i];
            if (slot.size == 0) continue;
            const src = args[i].payloadBytes();
            if (src.len == 0) continue;
            // payload 字节数 ≤ slot.size（标量宽度匹配，引用 = 指针大小）
            const dst = locals + slot.offset;
            const n = @min(src.len, slot.size);
            @memcpy(dst[0..n], src[0..n]);
            // slot 比 payload 大时高位填零（类型扩展）
            if (slot.size > n) @memset(dst[n..slot.size], 0);
        }
        frame.state = 0;
        frame.setStatus(.ready);
        // 选目标 worker（轮询，均匀分配）
        const idx = self.next_worker.fetchAdd(1, .monotonic) % self.workers.len;
        self.workers[idx].pushReady(frame);
        return frame;
    }

    /// 通知所有 worker 关闭
    pub fn requestShutdown(self: *Scheduler) void {
        self.shutdown.store(true, .release);
    }

    /// 调度器注入的入队回调（SuspendRegistry 唤醒时调用）
    /// 选最闲的 worker（就绪队列最短）入队，均衡负载
    fn enqueueFrame(ctx: *anyopaque, frame: *CoroutineFrame) void {
        const self: *Scheduler = @ptrCast(@alignCast(ctx));
        if (self.workers.len == 0) return;
        // 找就绪队列最短的 worker
        var min_idx: usize = 0;
        var min_count: u64 = self.workers[0].readyCount();
        for (self.workers[1..], 1..) |*w, i| {
            const c = w.readyCount();
            if (c < min_count) {
                min_count = c;
                min_idx = i;
            }
        }
        self.workers[min_idx].pushReady(frame);
    }
};

/// worker 主循环（Scheduler 注入到 Worker.start）
/// 拿到帧后执行当前段（state_machine.runSegment），按 SegmentResult 决定下一步：
/// - advance：state += 1，重新入就绪队列执行下一段
/// - suspend：帧已注册到挂起队列，让出
/// - complete：终态段完成，标记 completed，回帧池
/// - failed：异常，标记 failed，回帧池
fn workerRun(worker: *Worker) void {
    const sched: *Scheduler = @ptrCast(@alignCast(worker.scheduler.?));

    // 线程启动：通过 EngineContext 工厂创建 worker-local Engine + SegmentContext
    // 每个 worker 线程拥有独立 Engine（独立 tctx/runtime/call_stack），共享只读 IR 与 GlobalPool
    var worker_engine: ?*anyopaque = null;
    var sctx: ?SegmentContext = null;
    if (sched.engine_ctx) |ectx| {
        worker_engine = ectx.create_engine(ectx.ctx) catch {
            return;
        };
        if (worker_engine) |we| {
            sctx = ectx.build_segment_context(we);
        }
    }
    defer {
        // 线程退出：销毁 worker-local Engine（释放 tctx/caches/call_stack）
        if (worker_engine) |we| {
            if (sched.engine_ctx) |ectx| {
                ectx.destroy_engine(we);
            }
        }
    }

    while (worker.isAlive()) {
        if (sched.shutdown.load(.acquire)) break;

        // 1. 本地就绪队列 pop（LIFO）
        var frame = worker.popLocal();

        // 2. 本地空 → 偷取
        if (frame == null) {
            frame = trySteal(sched, worker);
        }

        // 3. 仍无 → backoff 让出
        if (frame == null) {
            worker.steal_fail_count +%= 1;
            // 简单 backoff：短让出，避免空转
            std.Thread.yield() catch {};
            // 连续失败过多时 sleep 一段（减少 CPU 占用）
            if (worker.steal_fail_count > 1000) {
                profiling_stats.sleepNs(1_000); // 1us
                worker.steal_fail_count = 0;
            }
            continue;
        }

        worker.steal_fail_count = 0;
        const f = frame.?;

        // cancel 帧优先走 cancel 路径（状态已是 cancelled，由 cancelFrame 设置）
        if (f.getStatus() == .cancelled) {
            cancel_mod.runCancelPath(f);
            sched.frame_pool.free(f);
            continue;
        }

        f.setStatus(.running);

        // 段执行：需 CoroutineMeta + IR nodes + SegmentContext 全部注入
        // 未注入时走空执行占位（保持调度基础设施可独立测试）
        if (sched.coroutine_metas == null or sched.ir_nodes == null or sctx == null) {
            // 空执行占位：直接标记 completed（调度基础设施测试用）
            f.setStatus(.completed);
            sched.frame_pool.free(f);
            continue;
        }

        const metas = sched.coroutine_metas.?;
        const nodes = sched.ir_nodes.?;
        const ctx = sctx.?;

        // coroutine_metas 只包含 async 函数的 meta（按 func_idx 线性搜索），
        // 长度 = async 函数数量，不是 functions.len。
        // 不能用 metas[f.func_idx] 直接索引（func_idx 较大的 async 函数会越界），
        // 必须线性搜索匹配 m.func_idx == f.func_idx。
        var meta_opt: ?*const CoroutineMeta = null;
        for (metas) |*m| {
            if (m.func_idx == f.func_idx) {
                meta_opt = m;
                break;
            }
        }
        const meta = meta_opt orelse {
            f.setPanic("workerRun: no coroutine meta for func_idx");
            f.setStatus(.failed);
            sched.frame_pool.free(f);
            // 通知 handle
            if (f.async_handle) |hp| {
                const AsyncHandle = @import("value").AsyncHandle;
                const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                handle.setPanic("no coroutine meta for func_idx");
                handle.signalWorkerDone();
            }
            continue;
        };
        if (f.state >= meta.segment_count) {
            f.setPanic("workerRun: state out of range");
            f.setStatus(.failed);
            sched.frame_pool.free(f);
            if (f.async_handle) |hp| {
                const AsyncHandle = @import("value").AsyncHandle;
                const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                handle.setPanic("state out of range");
                handle.signalWorkerDone();
            }
            continue;
        }
        const seg = meta.segments[f.state];

        // 段执行前：将帧的 locals 区安装到 worker Engine 的 runtime.chan_ptrs
        // 帧自带通道空间方案——通道状态在帧中跨段持久化，每次段执行前重新安装指针
        ctx.install_frame(ctx.ctx, f);

        // 保存 async_handle 指针：所有退出路径需通知 handle，否则主线程 join 永久阻塞
        const handle_ptr = f.async_handle;

        const result = state_machine.runSegment(f, seg, nodes, ctx, sched.suspend_registry) catch |err| {
            f.setPanic(@errorName(err));
            f.setStatus(.failed);
            sched.frame_pool.free(f);
            // 通知 handle：段执行出错，主线程 join 不应永久阻塞
            if (handle_ptr) |hp| {
                const AsyncHandle = @import("value").AsyncHandle;
                const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                handle.setPanic(@errorName(err));
                handle.signalWorkerDone();
            }
            continue;
        };

        switch (result) {
            .advance => {
                // 推进到下一段，重新入就绪队列
                f.state += 1;
                f.setStatus(.ready);
                worker.pushReady(f);
            },
            .suspend_ => {
                // 帧已注册到挂起队列，worker 让出（不回池、不入就绪队列）
                // suspend_target 与 status 已由 runSegment 设置
            },
            .complete => {
                // 终态段完成：写结果到 AsyncHandle + 唤醒 join 等待者，回帧池
                if (handle_ptr) |hp| {
                    const AsyncHandle = @import("value").AsyncHandle;
                    const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                    if (f.result) |r| {
                        handle.setResult(r);
                    } else {
                        handle.setResult(Value.fromUnit());
                    }
                }
                f.setStatus(.completed);
                sched.frame_pool.free(f);
                // signalWorkerDone 必须在 free(f) 之后：主线程的 waitWorkerDone
                // 返回后可能立即 deinit scheduler/frame_pool，若先 signal 再 free
                // 会导致 use-after-free。协程调度路径中 worker-local Engine 生命周期
                // 由 worker 线程管理，result 是 Value 值拷贝已安全。
                if (handle_ptr) |hp| {
                    const AsyncHandle = @import("value").AsyncHandle;
                    const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                    handle.signalWorkerDone();
                }
            },
            .failed => {
                // 段内异常：标记 failed，回帧池
                f.setStatus(.failed);
                sched.frame_pool.free(f);
                // 通知 handle：段内异常，主线程 join 不应永久阻塞
                if (handle_ptr) |hp| {
                    const AsyncHandle = @import("value").AsyncHandle;
                    const handle: *AsyncHandle = @ptrCast(@alignCast(hp));
                    if (f.panic_len > 0) {
                        handle.setPanic(f.getPanic());
                    } else {
                        handle.setPanic("segment failed");
                    }
                    handle.signalWorkerDone();
                }
            },
        }
    }
}

/// 尝试从其他 worker 偷取（随机选 victim，遍历一圈）
fn trySteal(sched: *Scheduler, self: *Worker) ?*CoroutineFrame {
    if (sched.workers.len <= 1) return null;
    // 简单 PRNG：用线程地址做种子
    var prng = std.Random.DefaultPrng.init(@intCast(@intFromPtr(self)));
    const rand = prng.random();
    const start = rand.uintLessThan(usize, sched.workers.len);
    var i: usize = 0;
    while (i < sched.workers.len) : (i += 1) {
        const idx = (start + i) % sched.workers.len;
        if (idx == self.id) continue; // 不偷自己
        if (sched.workers[idx].stealFrom(self)) |f| return f;
    }
    return null;
}

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

fn emptyLayout() ir_mod.FrameLayout {
    return .{
        .total_size = 0,
        .param_region = .{ .start = 0, .size = 0 },
        .local_region = .{ .start = 0, .size = 0 },
        .temp_region = .{ .start = 0, .size = 0 },
    };
}

test "Scheduler init/deinit 不泄漏" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = FramePool.init(testing.allocator, io);
    defer pool.deinit();
    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var sched = Scheduler.init(testing.allocator, io, &pool, &registry);
    // 不启动 worker，直接 deinit
    sched.deinit();
}

test "Scheduler startWorkers/deinit 空跑退出" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = FramePool.init(testing.allocator, io);
    defer pool.deinit();
    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var sched = Scheduler.init(testing.allocator, io, &pool, &registry);
    try sched.startWorkers(2);
    // 无协程，worker 应空转 backoff
    profiling_stats.sleepNs(1_000_000); // 1ms
    try testing.expectEqual(@as(usize, 2), sched.workers.len);
    sched.deinit();
}

test "Scheduler spawn 入就绪队列" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = FramePool.init(testing.allocator, io);
    defer pool.deinit();
    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var sched = Scheduler.init(testing.allocator, io, &pool, &registry);
    // 不启动 worker 线程（手动验证入队）
    const storage = try testing.allocator.alloc(Worker, 1);
    defer testing.allocator.free(storage);
    storage[0] = try Worker.init(0, testing.allocator);
    defer storage[0].deinit();
    sched.workers = storage;
    sched.suspend_registry.setEnqueueCallback(@ptrCast(&sched), Scheduler.enqueueFrame);

    // 构造最小 CoroutineMeta
    var seg = [_]ir_mod.SegmentDesc{.{ .start_node = 0, .end_node = 0, .suspend_kind = .terminal }};
    const meta = CoroutineMeta{
        .func_idx = 0,
        .segment_count = 1,
        .segments = seg[0..],
        .frame_layout = emptyLayout(),
    };

    const frame = try sched.spawn(&meta, &.{});
    try testing.expectEqual(CoroutineStatus.ready, frame.getStatus());
    try testing.expectEqual(@as(u64, 1), sched.workers[0].readyCount());

    // pop 出来验证
    const popped = sched.workers[0].popLocal().?;
    try testing.expectEqual(frame, popped);
    pool.free(frame);
}

test "Scheduler spawn 参数序列化到帧 locals" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = FramePool.init(testing.allocator, io);
    defer pool.deinit();
    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var sched = Scheduler.init(testing.allocator, io, &pool, &registry);
    const storage = try testing.allocator.alloc(Worker, 1);
    defer testing.allocator.free(storage);
    storage[0] = try Worker.init(0, testing.allocator);
    defer storage[0].deinit();
    sched.workers = storage;
    sched.suspend_registry.setEnqueueCallback(@ptrCast(&sched), Scheduler.enqueueFrame);

    // 构造带参数槽的 FrameLayout：slot0 = i32(4字节)@offset0, slot1 = i64(8字节)@offset8
    var slots = [_]ir_mod.SlotDesc{
        .{ .offset = 0, .size = 4, .is_ref = false },
        .{ .offset = 8, .size = 8, .is_ref = false },
    };
    const layout = ir_mod.FrameLayout{
        .total_size = 16,
        .param_region = .{ .start = 0, .size = 16 },
        .local_region = .{ .start = 16, .size = 0 },
        .temp_region = .{ .start = 16, .size = 0 },
        .slots = slots[0..],
    };
    var seg = [_]ir_mod.SegmentDesc{.{ .start_node = 0, .end_node = 0, .suspend_kind = .terminal }};
    const meta = CoroutineMeta{
        .func_idx = 0,
        .segment_count = 1,
        .segments = seg[0..],
        .frame_layout = layout,
    };

    // 参数：i32=42, i64=999999
    const args = [_]Value{ Value.fromI32(42), Value.fromI64(999999) };
    const frame = try sched.spawn(&meta, &args);

    // 验证参数已写入 locals 区
    const locals = frame.localsPtr();
    const val0: i32 = @bitCast(locals[0..4].*);
    try testing.expectEqual(@as(i32, 42), val0);
    const val1: i64 = @bitCast(locals[8..16].*);
    try testing.expectEqual(@as(i64, 999999), val1);

    // 清理：从就绪队列弹出帧并回池
    const popped = sched.workers[0].popLocal().?;
    try testing.expectEqual(frame, popped);
    pool.free(popped);
}
