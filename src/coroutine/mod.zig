//! 协程调度模块入口。
//!
//! 图驱动协程调度（Orbit-as-Coroutine）：async 函数体编译为状态机，
//! orbit IR 节点既是状态机切分点也是调度单元，N 个 worker 线程
//! 跑 work-stealing 调度器，实现 M:N 协程并发。
//!
//! 模块结构（按数据流职责分文件）：
//! - frame.zig：协程帧结构与帧池（第四分配器）
//! - scheduler.zig：work-stealing 调度器
//! - worker.zig：worker 线程主循环
//! - state_machine.zig：状态机段执行器（驱动 IR 段）
//! - suspend_registry.zig：挂起目标注册表
//! - bridge.zig：Io 原语与协程桥接
//! - cancel.zig：cancel 语义处理
//!
//! 参考：docs/superpowers/specs/2026-07-25-coroutine-graph-driven-design.md

pub const frame = @import("frame.zig");
pub const deque = @import("deque.zig");
pub const scheduler = @import("scheduler.zig");
pub const worker = @import("worker.zig");
pub const state_machine = @import("state_machine.zig");
pub const suspend_registry = @import("suspend_registry.zig");
pub const bridge = @import("bridge.zig");
pub const cancel = @import("cancel.zig");

// 重导出常用类型
pub const CoroutineFrame = frame.CoroutineFrame;
pub const FramePool = frame.FramePool;
pub const WorkStealingDeque = deque.WorkStealingDeque;
pub const Scheduler = scheduler.Scheduler;
pub const EngineContext = scheduler.EngineContext;
pub const Worker = worker.Worker;
pub const SuspendRegistry = suspend_registry.SuspendRegistry;
pub const EnqueueFn = suspend_registry.EnqueueFn;
