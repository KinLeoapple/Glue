//! Engine 模块 — 数据流就绪调度执行引擎（调度器）
//!
//! 基于 [`crate::ir::Ir::DataFlowGraph`]，实现：
//! - Frame 管理（HashMap + LockStrategy）
//! - 就绪调度（核心循环）
//! - 子图启动（start/complete）
//! - TimerRuntime / AsyncJoinRuntime 图外运行时
//! - 单线程（Single）/ 多线程（Multi）锁策略
//!
//! compute_fn 计算函数表已拆分至 Compute.rs，调度器通过 graph.compute_fns[idx]
//! 间接调用，不直接引用具体 compute_fn。
//!
//! 子模块：
//! - [`AsyncRt`]: 异步运行时（TimerRuntime / AsyncJoinRuntime）+ 事件处理
//! - [`Schedule`]: 数据流调度核心（就绪调度、批量化、run_frame_nodes、process_frame）
//! - [`Frame`]: Frame 生命周期管理（分配、初始化、重置、帧链）
//! - [`Subgraph`]: 子图调用与返回（switch_subgraph、start_subgraph、complete_and_wake_caller）
//! - [`Strategy`]: 并发策略（LockStrategy / Single / Multi / QueueHandle + worker）
//!
//! 设计原则（见 docs/superpowers/specs/2026-07-31-dataflow-engine-design.md）：
//! - 无 dispatch：调度器只认"输入就绪"，节点自带 compute_fn
//! - sync/async 统一：子图有无挂起点
//! - 帧级回收 + 槽级 RC

pub mod AsyncRt;
pub mod Schedule;
pub mod Frame;
pub mod Subgraph;
pub mod Strategy;

pub use Schedule::{prepare_frame_nodes, notify_downstream};
pub use Subgraph::switch_subgraph;
pub use Strategy::{LockStrategy, Lockable, Single, Multi, QueueHandle};
pub use AsyncRt::{TimerRuntime, AsyncJoinRuntime};

use crate::ir::Ir::*;
use crate::value::{Value, ValueArena};
use std::cell::RefCell;
use parking_lot::{Condvar, Mutex as ParkingMutex};
use hashbrown::HashMap;
use crossbeam_deque::Injector;
use std::sync::Arc;

// =========================================================================
// 哨兵常量 — 调度器使用
// =========================================================================

/// `pending_inputs` 槽位哨兵：标记"永不就绪/外部源"（实际入度必须 < 65535）。
const PENDING_EXTERNAL: u16 = u16::MAX;
/// splitmix64 黄金比例散列常量（确保各 worker 的 steal 顺序互异）。
const GOLDEN_RATIO_64: u64 = 0x9E3779B97F4A7C15;

// =========================================================================
// Engine<S> — 统一执行引擎（泛型锁策略）
// =========================================================================

/// 统一引擎：字段类型由 S 决定，业务逻辑只写一份
pub struct Engine<S: LockStrategy> {
    pub graph: Arc<DataFlowGraph>,
    pub frames: S::Mutex<HashMap<FrameId, Box<crate::ir::Ir::Frame>>>,
    pub next_frame_id: S::Mutex<FrameId>,
    pub arena: S::Mutex<ValueArena>,
    pub timer_runtime: S::Mutex<TimerRuntime>,
    pub async_join_runtime: S::Mutex<AsyncJoinRuntime>,
    pub event_waiters: S::Mutex<Vec<(crate::ir::Ir::RuntimeEvent, FrameId)>>,
    pub pending_completions:
        S::Mutex<HashMap<FrameId, Vec<(crate::ir::Ir::NodeId, Value, crate::ir::Ir::ControlSignal)>>>,
    /// 事件投递竞态兜底：事件到达时帧正被 process_frame 处理（不在 HashMap），
    /// 将事件暂存，process_frame insert 帧后消费（与 pending_completions 对称）
    pub pending_events: S::Mutex<HashMap<FrameId, (crate::ir::Ir::RuntimeEvent, Value)>>,
    pub result: S::Mutex<Option<Value>>,
    /// 单线程队列（Multi 模式为 None）
    pub ready_frames: Option<RefCell<std::collections::VecDeque<FrameId>>>,
    /// 多线程调度（Single 模式为 None）
    pub global_queue: Option<Injector<FrameId>>,
    pub wakeup: Option<(ParkingMutex<()>, Condvar)>,
    pub active_count: Option<ParkingMutex<usize>>,
    _strategy: std::marker::PhantomData<S>,
}

// Safety: Frame 含裸指针（root_frame_ptr/parent_frame_ptr），但所有可变字段都在
// ParkingMutex 保护下，同一时刻只有一个线程访问每个字段。
unsafe impl Send for Engine<Multi> {}
unsafe impl Sync for Engine<Multi> {}

// =========================================================================
// EngineRef — 统一工厂（根据 workers 数决定编译期策略）
// =========================================================================

/// 统一工厂：根据 workers 数决定编译期策略
pub enum EngineRef {
    Single(Engine<Single>),
    Multi(Arc<Engine<Multi>>),
}

impl EngineRef {
    /// 创建引擎：workers <= 1 用单线程，> 1 用多 worker
    pub fn new(graph: DataFlowGraph, workers: usize) -> Self {
        if workers <= 1 {
            Self::Single(Engine::<Single>::new_single(graph))
        } else {
            Self::Multi(Arc::new(Engine::<Multi>::new_multi(graph, workers)))
        }
    }

    /// 运行引擎，返回结果值
    pub fn run(self) -> Value {
        match self {
            Self::Single(e) => e.run_single(),
            Self::Multi(e) => Engine::<Multi>::run_multi(e),
        }
    }
}
