//! Work-stealing 调度器（基于 Zio 运行时）
//!
//! Phase 4 实现：并发原语
//! 文档 §3.7: M:N 调度，少量 OS 线程上运行大量轻量级协程
//! 文档 §5.3: Work-stealing 调度器，每个 worker 线程有本地任务队列，空闲 worker 从其他 worker 偷任务
//! 文档 §5.4: 运行时层次 — 并行原语 → 一等 Trait → Work-Stealing 调度器 → Per-Heap GC → OS 线程池
//!
//! 使用 Zio 库提供：
//! - 栈式协程（fibers），用户态上下文切换
//! - 多线程调度，协程可跨线程迁移（enable_task_migration）
//! - 支持 Linux (io_uring), Windows (IOCP), macOS (kqueue)
//! - 可增长栈（通过虚拟内存预留自动扩展）
//! - Work-stealing 调度器

const std = @import("std");
const zio = @import("zio");

pub const Scheduler = struct {
    runtime: *zio.Runtime,
    allocator: std.mem.Allocator,

    /// 初始化调度器
    /// 文档 §3.7: M:N 调度，executors 数量默认等于 CPU 核心数
    /// 文档 §5.3: Worker 数量默认等于 CPU 核心数
    /// enable_task_migration = true: 协程可跨线程迁移（work-stealing）
    /// enable_main_executor = true: 主线程也参与调度
    pub fn init(allocator: std.mem.Allocator) !Scheduler {
        const runtime = try zio.Runtime.init(allocator, .{
            .executors = .auto,
            .enable_task_migration = true,
            .enable_main_executor = true,
        });
        return Scheduler{
            .runtime = runtime,
            .allocator = allocator,
        };
    }

    /// 初始化调度器（指定 executor 数量）
    pub fn initWithExecutors(allocator: std.mem.Allocator, num_executors: u8) !Scheduler {
        const runtime = try zio.Runtime.init(allocator, .{
            .executors = zio.Runtime.ExecutorCount.exact(num_executors),
            .enable_task_migration = true,
            .enable_main_executor = true,
        });
        return Scheduler{
            .runtime = runtime,
            .allocator = allocator,
        };
    }

    /// 关闭调度器
    pub fn deinit(self: *Scheduler) void {
        self.runtime.deinit();
    }

    /// 获取 Zio Runtime 引用
    pub fn getRuntime(self: *Scheduler) *zio.Runtime {
        return self.runtime;
    }

    /// 获取 std.Io 上下文（由 Zio Runtime 支持）
    pub fn getIo(self: *Scheduler) std.Io {
        return self.runtime.io();
    }

    /// 从 Zio Runtime 恢复 Scheduler 引用
    /// 注意：Scheduler 必须是全局单例，此函数返回全局实例
    pub fn fromRuntime(rt: *zio.Runtime) *Scheduler {
        // Scheduler 是全局单例，runtime 字段是第一个字段
        // 通过指针偏移获取 Scheduler
        return @fieldParentPtr("runtime", rt);
    }

    /// 提交协程到调度器
    /// 文档 §3.2: spawn 创建协程，立即返回 Spawn<T>，不阻塞当前代码
    /// 文档 §3.7: Spawn<T>.await() 挂起当前协程，让出执行权
    ///
    /// 返回 zio.JoinHandle(T)，可用于 join（挂起等待）或 cancel
    pub fn spawn(
        self: *Scheduler,
        comptime func: anytype,
        args: anytype,
    ) !@typeInfo(@TypeOf(zio.Runtime.spawn)).@"fn".return_type.? {
        return self.runtime.spawn(func, args);
    }

    /// 提交阻塞任务到线程池
    /// 用于需要在 OS 线程上执行阻塞操作的场景
    pub fn spawnBlocking(
        self: *Scheduler,
        comptime func: anytype,
        args: anytype,
    ) !@typeInfo(@TypeOf(zio.Runtime.spawnBlocking)).@"fn".return_type.? {
        return self.runtime.spawnBlocking(func, args);
    }

    /// 协作式让出执行权
    /// 文档 §3.7: await 挂起当前协程，让出执行权
    pub fn yield() zio.Cancelable!void {
        return zio.yield();
    }

    /// 休眠当前协程
    pub fn sleep(duration: zio.Duration) zio.Cancelable!void {
        return zio.sleep(duration);
    }
};
