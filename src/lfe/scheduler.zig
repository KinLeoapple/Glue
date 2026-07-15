//! M:N 协程调度器
//!
//! async 函数编译为子图（LaminarGraph），async_create 将子图包装为 LfeTask
//! 提交到调度器。N 个 Worker 线程从全局队列窃取任务执行。
//!
//! 协程切换不需要保存栈——LFE 的执行上下文完全由 (channels[], pc) 描述。
//! 阻塞操作（await 未完成任务 / channel.recv 无数据）挂起当前 task，
//! 条件满足时通过 Condition 唤醒 Worker 重新调度。
//!
//! Lamina 派发逻辑在 Engine 中，Scheduler 只负责任务队列和线程管理。
//! Engine.runTaskSlice 执行单个 task 的 laminas，遇到阻塞 op 时返回 .suspend_。

const std = @import("std");
const sync = @import("sync");
const mem = @import("mem");
const value = @import("value");
const lamina_mod = @import("lamina.zig");

const Mutex = sync.Mutex;
const Condition = sync.Condition;
const ChannelRegion = mem.ChannelRegion;
const LaminarGraph = lamina_mod.LaminarGraph;
const PhysicalChannel = lamina_mod.PhysicalChannel;
const Value = value.Value;
const ObjHeader = value.obj_header.ObjHeader;
const concurrent = value.concurrent;

/// 协程状态
pub const TaskState = enum(u8) {
    pending = 0,
    running = 1,
    suspended = 2,
    completed = 3,
    failed = 4,
};

/// 协程任务：一个 async 函数调用的执行实例
pub const LfeTask = struct {
    /// 子图引用（只读共享，无需锁）
    subgraph: *const LaminarGraph,
    /// 私有物理通道（独立通道区，无需锁）
    channels: []PhysicalChannel,
    /// 通道数据线性区
    channel_region: ChannelRegion,
    /// 当前执行的 lamina 索引
    pc: usize = 0,
    /// 任务状态（原子，其他线程通过此查询）
    state: std.atomic.Value(u8),
    /// 返回值（halt_return 写入，await 读取）
    result: Value,
    /// 结果是否就绪
    result_ready: std.atomic.Value(bool),
    /// 引用计数：async_create 返回的句柄 +1，调度器 +1
    rc: std.atomic.Value(i32),
    /// 等待此任务完成的 waiter 列表（await 它的 task）
    waiters_mutex: Mutex = .{},
    waiters: std.ArrayList(*LfeTask) = .empty,
    /// 所属调度器
    scheduler: *Scheduler,
    /// 元素数量（标量模式 = 1）
    element_count: usize = 1,
    /// 错误值（failed 状态时）
    error_val: ?Value = null,
    /// 所属 Engine（执行期间临时指向当前 engine，非执行期为 null）
    engine: ?*anyopaque = null,

    /// 创建任务（引用计数初始为 2：调度器 + 调用者句柄）
    pub fn create(
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        subgraph: *const LaminarGraph,
        element_count: usize,
    ) !*LfeTask {
        const task = try allocator.create(LfeTask);
        errdefer allocator.destroy(task);

        var region = ChannelRegion.init(allocator);
        errdefer region.deinit();

        const channels = try allocator.alloc(PhysicalChannel, @max(subgraph.channel_count, 1));
        errdefer allocator.free(channels);

        // 为每个通道分配数据
        for (subgraph.channel_metas, 0..) |meta, i| {
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

        task.* = .{
            .subgraph = subgraph,
            .channels = channels,
            .channel_region = region,
            .state = std.atomic.Value(u8).init(@intFromEnum(TaskState.pending)),
            .result = Value.fromUnit(),
            .result_ready = std.atomic.Value(bool).init(false),
            .rc = std.atomic.Value(i32).init(2),
            .scheduler = scheduler,
            .element_count = element_count,
        };
        return task;
    }

    /// 销毁任务（引用计数归零时调用）
    pub fn destroy(self: *LfeTask, allocator: std.mem.Allocator) void {
        self.channel_region.deinit();
        allocator.free(self.channels);
        self.waiters.deinit(allocator);
        self.result.release(allocator);
        if (self.error_val) |e| e.release(allocator);
        allocator.destroy(self);
    }

    /// 增加引用计数
    pub fn retain(self: *LfeTask) *LfeTask {
        _ = self.rc.fetchAdd(1, .monotonic);
        return self;
    }

    /// 减少引用计数，归零时销毁
    pub fn release(self: *LfeTask, allocator: std.mem.Allocator) void {
        const old = self.rc.fetchSub(1, .release);
        if (old == 1) {
            self.destroy(allocator);
        }
    }

    /// 添加 waiter（等待此任务完成的 task）
    pub fn addWaiter(self: *LfeTask, waiter: *LfeTask) void {
        self.waiters_mutex.lock();
        defer self.waiters_mutex.unlock();
        self.waiters.append(self.scheduler.allocator, waiter) catch {};
    }

    /// 唤醒所有 waiter，将它们重新加入调度队列
    pub fn wakeAllWaiters(self: *LfeTask) void {
        self.waiters_mutex.lock();
        const items = self.waiters.toOwnedSlice(self.scheduler.allocator) catch &.{};
        self.waiters_mutex.unlock();
        for (items) |w| {
            self.scheduler.enqueue(w);
        }
        self.scheduler.allocator.free(items);
    }
};

/// M:N 协程调度器
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    /// 工作线程数
    worker_count: usize,
    /// 工作线程
    workers: []Worker = &.{},
    /// 全局任务队列
    global_queue_mutex: Mutex = .{},
    global_queue: std.ArrayList(*LfeTask) = .empty,
    global_queue_cond: Condition = .{},
    /// 活跃任务数（未完成）
    active_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// 所有任务完成的条件变量
    done_cond: Condition = .{},
    done_mutex: Mutex = .{},
    /// 停止标志
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 元素数量
    element_count: usize = 1,
    /// main task（主线程等待它完成）
    main_task: ?*LfeTask = null,

    /// 初始化调度器
    pub fn init(allocator: std.mem.Allocator, worker_count: usize, element_count: usize) Scheduler {
        return .{
            .allocator = allocator,
            .worker_count = worker_count,
            .element_count = element_count,
        };
    }

    /// 启动调度器：创建 worker 线程
    pub fn start(self: *Scheduler) !void {
        self.workers = try self.allocator.alloc(Worker, self.worker_count);
        for (0..self.worker_count) |i| {
            self.workers[i] = .{ .id = i, .scheduler = self };
            self.workers[i].thread = try std.Thread.spawn(.{}, workerMain, .{&self.workers[i]});
        }
    }

    /// 停止调度器：等待所有 worker 完成
    pub fn stop(self: *Scheduler) void {
        self.stopping.store(true, .release);
        self.global_queue_cond.broadcast();
        for (self.workers) |*w| {
            if (w.thread) |t| {
                t.join();
                w.thread = null;
            }
        }
        self.allocator.free(self.workers);
        self.workers = &.{};
        self.global_queue.deinit(self.allocator);
    }

    /// 提交任务到全局队列
    pub fn enqueue(self: *Scheduler, task: *LfeTask) void {
        task.state.store(@intFromEnum(TaskState.pending), .release);
        self.global_queue_mutex.lock();
        self.global_queue.append(self.allocator, task) catch {
            self.global_queue_mutex.unlock();
            return;
        };
        self.global_queue_mutex.unlock();
        self.global_queue_cond.signal();
    }

    /// 提交新任务（async_create 调用）
    pub fn asyncTask(self: *Scheduler, task: *LfeTask) void {
        _ = self.active_tasks.fetchAdd(1, .monotonic);
        self.enqueue(task);
    }

    /// 任务完成时减少活跃计数
    pub fn taskCompleted(self: *Scheduler) void {
        const old = self.active_tasks.fetchSub(1, .release);
        if (old == 1) {
            self.done_mutex.lock();
            self.done_cond.broadcast();
            self.done_mutex.unlock();
        }
    }

    /// 等待指定 task 完成（主线程 await main_task）
    pub fn waitFor(self: *Scheduler, task: *LfeTask) void {
        // 主线程自旋等待 main task 完成
        _ = self;
        while (!task.result_ready.load(.acquire)) {
            std.Thread.yield() catch {};
        }
    }

    /// 等待所有活跃任务完成（主引擎太阳层执行完毕后调用）
    pub fn waitForAll(self: *Scheduler) void {
        // 主线程自旋等待所有任务完成
        while (self.active_tasks.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
    }

    /// 从全局队列取任务
    fn dequeue(self: *Scheduler) ?*LfeTask {
        self.global_queue_mutex.lock();
        defer self.global_queue_mutex.unlock();
        if (self.global_queue.items.len > 0) {
            return self.global_queue.orderedRemove(0);
        }
        return null;
    }

    /// Worker 主循环
    fn workerMain(worker: *Worker) void {
        const sched = worker.scheduler;
        while (!sched.stopping.load(.acquire)) {
            const task = sched.dequeue();
            if (task) |t| {
                runTask(sched, t);
            } else {
                sched.global_queue_mutex.lock();
                if (sched.global_queue.items.len == 0 and !sched.stopping.load(.acquire)) {
                    sched.global_queue_cond.wait(&sched.global_queue_mutex);
                }
                sched.global_queue_mutex.unlock();
            }
        }
    }

    /// 执行任务（由 worker 调用）
    /// 创建临时 Engine 执行 task 的 laminas
    fn runTask(sched: *Scheduler, task: *LfeTask) void {
        task.state.store(@intFromEnum(TaskState.running), .release);

        // 创建临时 Engine 执行此 task
        const Engine = @import("engine.zig").Engine;
        var eng = Engine.initForTask(sched.allocator, task, sched) catch {
            task.state.store(@intFromEnum(TaskState.failed), .release);
            sched.taskCompleted();
            task.wakeAllWaiters();
            task.release(sched.allocator);
            return;
        };
        defer eng.deinitTask();

        const result = eng.runTaskSlice();
        switch (result) {
            .continue_ => {
                // 不应发生（runTaskSlice 总是执行到 done/suspend_/failed）
                task.state.store(@intFromEnum(TaskState.completed), .release);
                task.result_ready.store(true, .release);
                sched.taskCompleted();
                task.wakeAllWaiters();
                task.release(sched.allocator);
            },
            .done => {
                task.state.store(@intFromEnum(TaskState.completed), .release);
                sched.taskCompleted();
                task.wakeAllWaiters();
                // 调度器持有的引用释放
                task.release(sched.allocator);
            },
            .failed => {
                task.state.store(@intFromEnum(TaskState.failed), .release);
                sched.taskCompleted();
                task.wakeAllWaiters();
                task.release(sched.allocator);
            },
            .suspend_ => {
                // task 已挂起，等待被唤醒（不释放引用）
            },
        }
    }
};

/// Worker 线程
pub const Worker = struct {
    id: usize,
    thread: ?std.Thread = null,
    scheduler: *Scheduler,
};

/// lamina 执行结果
pub const ExecResult = enum {
    continue_, // 正常执行
    suspend_, // 阻塞挂起
    done, // halt_return 完成
    failed, // 执行错误
};
