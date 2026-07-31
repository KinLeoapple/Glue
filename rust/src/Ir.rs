//! Ir.rs — 数据流就绪调度执行模型的 IR 核心数据结构
//!
//! 基于 Sema.rs 的 SemaResult 产出，定义：
//! - Node（固定 16B，存拓扑引用，不存值）
//! - InputsPool（独立连续输入池）
//! - ValueSlot / Frame（运行时值表，本阶段仅定义结构）
//! - SubGraph（函数=子图）
//! - EventSource（channel/async/timer/子图完成事件源声明）
//! - DataFlowGraph（全局图容器）
//! - ComputeFn（构建期绑定的计算函数索引，消除 dispatch）
//!
//! 设计原则（见 docs/superpowers/specs/2026-07-31-dataflow-engine-design.md）：
//! - 节点固定 16B，只存拓扑引用，output 隐含 = 节点自身 id
//! - kind 只有 6 种，仅用于调度器就绪判定，不用于运算分派
//! - compute_fn 是构建期按类型特化绑定的函数索引，运行时数组索引取出调用
//! - 值表槽使用 Value.rs 的 ValueHandle（4B DOD 句柄），非 Value enum
//! - 独立输入池连续存储所有节点输入，缓存友好

use crate::Value::ValueHandle;

// =========================================================================
// 索引 newtype — 保证类型安全的句柄
// =========================================================================

/// 节点 id（全局连续，值表按此索引）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NodeId(pub u32);

/// 子图 id（函数=子图）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SubGraphId(pub u32);

/// 函数 id（与 SubGraphId 一一对应，语义别名）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FuncId(pub u32);

/// 子图实例 id（运行时，每次调用一个实例）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SubgraphInstanceId(pub u32);

/// 帧 id（运行时）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FrameId(pub u32);

/// 计算函数索引（指向 COMPUTE_FN_TABLE）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ComputeFnId(pub u32);

// =========================================================================
// NodeKind — 节点种类（非 op，仅 8 种用于就绪判定）
// =========================================================================

/// 节点种类：仅用于调度器判断"如何就绪判定"，不用于运算分派。
///
/// 与传统 IR 的 op（100+ 操作码）根本区别：kind 不参与 dispatch。
/// 具体运算（加减乘除等）由 compute_fn 构建期绑定决定。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum NodeKind {
    /// 纯计算：常量
    Const = 0,
    /// 纯计算：二元运算（输入就绪即执行）
    BinOp = 1,
    /// 纯计算：一元运算
    UnOp = 2,
    /// 纯计算：字段访问
    FieldAccess = 3,
    /// 函数调用：启动子图 + 等完成事件
    Call = 4,
    /// 事件源消费：等待事件（channel/async/timer）
    Await = 5,
    /// 控制流：条件选择，激活选中子图
    Gate = 6,
    /// 事件源声明：不执行计算，声明外部事件接入点
    EventSource = 7,
}

// =========================================================================
// Node — 固定大小节点（只存拓扑引用，不存值）
// =========================================================================

/// 数据流图节点：固定大小，只存拓扑引用。
///
/// - `kind`：节点种类（仅就绪判定用，不参与运算分派）
/// - `input_count`：输入数量（任意，实际输入在 InputsPool）
/// - `inputs_offset`：在 InputsPool.data 中的起始位置
/// - `compute_fn`：计算函数索引（构建期绑定，运行时数组索引调用）
///
/// output 隐含 = 节点自身 NodeId（值表按 NodeId 索引）。
/// 具体运算由 compute_fn 决定，调度器不关心。
#[repr(C, align(16))]
#[derive(Debug, Clone, Copy)]
pub struct Node {
    pub kind: NodeKind,
    pub input_count: u8,
    pub inputs_offset: u32,
    pub compute_fn: ComputeFnId,
}
// 布局：kind(1) + input_count(1) + pad(2) + inputs_offset(4) + compute_fn(4) = 12B
// align(16) 强制对齐 16B，size 向上取整为 16B（尾部 pad 4 字节）
const _: () = assert!(std::mem::size_of::<Node>() == 16);

// =========================================================================
// InputsPool — 独立连续输入池
// =========================================================================

/// 独立输入池：连续存储所有节点的输入 NodeId。
///
/// 节点 N 的输入 = `data[N.inputs_offset .. N.inputs_offset + N.input_count]`。
/// 连续存储保证缓存友好，可批量 SIMD 扫描就绪状态。
pub struct InputsPool {
    pub data: Vec<NodeId>,
}

impl InputsPool {
    pub fn new() -> Self {
        Self { data: Vec::new() }
    }

    /// 推入一组输入，返回起始 offset。
    pub fn push(&mut self, inputs: &[NodeId]) -> u32 {
        let offset = self.data.len() as u32;
        self.data.extend_from_slice(inputs);
        offset
    }

    /// 读取指定位置的输入切片。
    pub fn get(&self, offset: u32, count: u8) -> &[NodeId] {
        let start = offset as usize;
        let end = start + count as usize;
        &self.data[start..end]
    }

    /// 当前池长度。
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// 是否为空。
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

impl Default for InputsPool {
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// ValueSlot — 值表槽（运行时，每帧一个值表）
// =========================================================================

/// 值表槽：存储节点产出值 + 就绪状态 + 槽级 RC 计数。
///
/// - `value`：产出值（ValueHandle，4B DOD 句柄）
/// - `ready`：是否已产出
/// - `refcount`：剩余下游消费者数量（双层 RC 的槽级，0 表示可回收）
///
/// 槽级 RC：节点产出时设 refcount = 下游数量，每个下游消费时 -1，归零可清槽。
/// 帧级兜底：帧结束时所有未归零槽统一回收（堆对象 decref）。
#[derive(Clone, Copy)]
pub struct ValueSlot {
    pub value: ValueHandle,
    pub ready: bool,
    pub refcount: u16,
}

impl ValueSlot {
    /// 创建未就绪的空槽。
    pub fn unready() -> Self {
        Self {
            value: ValueHandle::NULL,
            ready: false,
            refcount: 0,
        }
    }

    /// 设置产出值 + 下游消费者数量。
    pub fn set_value(&mut self, value: ValueHandle, consumer_count: u16) {
        self.value = value;
        self.ready = true;
        self.refcount = consumer_count;
    }

    /// 消费一次（下游读取）。返回 true 表示 refcount 仍 >0（未归零），
    /// 返回 false 表示已归零可回收。
    pub fn consume(&mut self) -> bool {
        if self.refcount > 0 {
            self.refcount -= 1;
        }
        self.refcount > 0
    }

    /// 是否已被所有消费者消费完（refcount 归零）。
    pub fn is_consumed(&self) -> bool {
        self.ready && self.refcount == 0
    }
}

impl std::fmt::Debug for ValueSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ValueSlot")
            .field("value", &self.value.to_raw())
            .field("ready", &self.ready)
            .field("refcount", &self.refcount)
            .finish()
    }
}

// =========================================================================
// ConstValue — 编译期常量原始值（IrBuilder 存储，Engine 分配 ValueHandle）
// =========================================================================

/// 编译期常量原始值（IrBuilder 存储，Engine 分配 ValueHandle）。
///
/// IrBuilder 在编译 Const 节点时将原始值存入 graph.const_values[NodeId]，
/// Engine 在帧初始化时用 ValueArena 分配 ValueHandle 并预填充到 value_table。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ConstValue {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
    Bool(bool),
    Str(&'static str),
    Null,
    Void,
}

/// Gate 节点的分支信息。
///
/// Gate 节点根据条件值选择激活哪个分支子图。
/// `condition_input` 是条件值的 NodeId（全局）。
/// `branches` 是分支列表，每个分支携带自己的 inputs（全局 NodeId，值从父帧读取）。
/// 不同分支可有不同数量的 inputs（对应不同 param_count 的子图）。
#[derive(Debug, Clone)]
pub struct GateBranches {
    /// 条件输入节点（全局 NodeId）
    pub condition_input: NodeId,
    /// 分支列表：(条件值, 子图id, 参数节点列表)
    pub branches: Vec<(bool, SubGraphId, Vec<NodeId>)>,
}

/// select 表达式分支信息（按 Gate 节点 NodeId 索引到 select_infos）。
#[derive(Debug, Clone)]
pub struct SelectInfo {
    /// 每个 Receive/Timeout 分支的信息
    pub branches: Vec<SelectBranch>,
}

/// select 表达式的单个分支信息。
#[derive(Debug, Clone)]
pub struct SelectBranch {
    /// 分支子图 id（执行分支 body）
    pub subgraph_id: SubGraphId,
    /// 事件源类型（Channel 或 Timer）
    pub event_kind: EventSourceKind,
    /// 事件源值节点（channel handle 或 timer handle 的 NodeId，全局）
    pub event_source_node: NodeId,
}

// =========================================================================
// ControlSignal — 控制信号（非局部跳转的统一表达）
// =========================================================================

/// 控制信号：非局部跳转的统一表达。
///
/// run_ready_nodes 每次循环检查此字段，非 None 则停止处理。
/// 由 control_signal_nodes 表标记的节点触发。
#[derive(Debug, Clone, Copy, Default)]
pub enum ControlSignal {
    /// 无信号，正常执行
    #[default]
    None,
    /// return 语句触发：子图提前返回该值
    Return(ValueHandle),
    /// break 语句触发：循环跳出
    Break,
    /// continue 语句触发：循环下一轮
    Continue,
}

/// 信号种类标记（编译期，IrBuilder 设置）。
///
/// control_signal_nodes 表按 NodeId 索引，标记哪些节点执行后触发何种信号。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalKind {
    /// return 语句：节点值作为返回值
    Return,
    /// break 语句
    Break,
    /// continue 语句
    Continue,
}

// =========================================================================
// FrameState — 帧状态
// =========================================================================

/// 帧状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameState {
    /// 就绪可执行（有就绪节点）
    Ready,
    /// 正在执行
    Running,
    /// 挂起等事件（async，阶段5实现）
    Suspended,
    /// 取消中（阶段5实现）
    Cancelling,
    /// 完成
    Completed,
    /// 失败
    Failed,
}

// =========================================================================
// SuspendState — 帧挂起状态（偏差 2：call/await 统一挂起模型）
// =========================================================================

/// 帧挂起状态。
///
/// 帧执行到 call/await 节点时挂起，等待事件恢复：
/// - `NotSuspended`：正常运行
/// - `WaitingSubgraph(FrameId)`：等待子图帧完成（sync call 节点用）
/// - `WaitingEvent(NodeId)`：等待 channel/timer/async 事件（await 节点用，NodeId 是 await 节点）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuspendState {
    NotSuspended,
    WaitingSubgraph(FrameId),
    WaitingEvent(NodeId),
}

// =========================================================================
// RuntimeEvent — 运行时事件（子图完成等）
// =========================================================================

/// 运行时事件：驱动挂起帧恢复执行。
///
/// spec 4.4 on_event_arrived 统一处理所有事件源。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RuntimeEvent {
    /// 子图执行完成（sync call 节点等待的事件）
    SubgraphComplete(FrameId),
    /// channel 有数据可读（await channel.recv() 等待的事件）
    ChannelReady(ChannelId),
    /// timer 到期触发（await timer.sleep() 等待的事件）
    TimerFired(TimerId),
    /// async 调用完成（await async_handle.await() 等待的事件）
    AsyncJoin(AsyncHandleId),
}

// =========================================================================
// PendingCall — 待发起的子图调用（call 节点执行时构造）
// =========================================================================

/// 待发起的子图调用。
///
/// call 节点 compute_fn 执行时构造，调度器消费后启动子图帧。
/// - `is_async=false`：sync call，当前帧挂起等 SubgraphComplete
/// - `is_async=true`：async call，当前帧不挂起，call 节点写 AsyncHandle + 通知下游
#[derive(Debug, Clone)]
pub struct PendingCall {
    /// 目标子图 id
    pub target_sg: SubGraphId,
    /// 调用参数（值句柄列表）
    pub args: Vec<crate::Value::ValueHandle>,
    /// 发起调用的节点（帧内局部 NodeId，子图完成后回写返回值）
    pub call_node_local: NodeId,
    /// async call 标记：true=不挂起当前帧，返回 AsyncHandle
    pub is_async: bool,
}

// =========================================================================
// PendingAwait — 待处理的 await 挂起（await 节点执行时构造）
// =========================================================================

/// 待处理的 await 挂起。
///
/// await 节点 compute_fn 执行时构造，核心循环消费后检查事件源就绪状态：
/// 就绪→注入值继续执行，未就绪→注册 event_waiters + 帧挂起。
#[derive(Debug, Clone)]
pub struct PendingAwait {
    /// await 节点（帧内局部 NodeId，事件到达时回写值）
    pub await_node_local: NodeId,
    /// 事件对象值（AsyncHandle/Channel/Timer 的 ValueHandle）
    pub event_obj: crate::Value::ValueHandle,
    /// 事件种类（决定如何检查就绪 + 如何解析事件源 id）
    pub event_kind: EventSourceKind,
}

// =========================================================================
// Frame — 执行帧（一次函数调用的运行时状态）
// =========================================================================

/// 执行帧：一次函数调用的运行时状态。
///
/// - `value_table`：按 NodeId 索引的值表（每节点一个槽）
/// - `pending_inputs`：每节点剩余未就绪输入数
/// - `ready_queue`：就绪待执行节点队列
/// - `state`：帧状态
/// - `subgraph_id`：所属子图
/// - `caller`：调用方帧+call节点（子图完成时回写返回值）
///
/// 帧级回收：帧结束时整个 value_table 释放，堆对象走 ValueArena RC。
pub struct Frame {
    /// 值表（按帧内局部 NodeId 索引，从 0 开始）
    pub value_table: Vec<ValueSlot>,
    /// 每节点剩余未就绪输入数
    pub pending_inputs: Vec<u8>,
    /// 就绪待执行节点队列
    pub ready_queue: std::collections::VecDeque<NodeId>,
    /// 帧状态
    pub state: FrameState,
    /// 所属子图 id
    pub subgraph_id: SubGraphId,
    /// 调用方帧+call节点（None = 顶层帧）
    pub caller: Option<(FrameId, NodeId)>,
    /// 帧 id
    pub id: FrameId,
    /// 子图节点起始偏移（全局 NodeId = 局部 NodeId + node_offset）
    pub node_offset: u32,
    /// 控制信号（return/break/continue 触发）
    pub control_signal: ControlSignal,
    /// 挂起状态（call/await 节点挂起时设置）
    pub suspend_state: SuspendState,
    /// defer 栈（运行时，帧释放时 LIFO 执行）
    pub defer_stack: Vec<DeferEntry>,
    /// 待发起的子图调用（call 节点 compute_fn 产出，调度器消费）
    pub pending_call: Option<PendingCall>,
    /// 待处理的 await 挂起（await 节点 compute_fn 产出，调度器消费）
    pub pending_await: Option<PendingAwait>,
    /// 挂起事件（子图完成等，驱动帧恢复）
    pub suspend_event: Option<RuntimeEvent>,
    /// 待取消的 async handle（cancel 方法调用设置，run_ready_nodes 消费）
    pub pending_cancel: Option<crate::Ir::AsyncHandleId>,
    /// 待启动的 select 分支子图（run_ready_nodes 检查就绪后设置）
    pub pending_select: Option<SubGraphId>,
    /// 待挂起的 select 等待（无就绪分支时设置，NodeId 是 Gate 节点局部 id）
    pub pending_select_wait: Option<NodeId>,
}

impl Frame {
    /// 创建新帧，值表和 pending_inputs 按子图节点数初始化。
    pub fn new(id: FrameId, subgraph_id: SubGraphId, node_count: usize) -> Self {
        Self {
            value_table: vec![ValueSlot::unready(); node_count],
            pending_inputs: vec![0; node_count],
            ready_queue: std::collections::VecDeque::new(),
            state: FrameState::Ready,
            subgraph_id,
            caller: None,
            id,
            node_offset: 0,
            control_signal: ControlSignal::None,
            suspend_state: SuspendState::NotSuspended,
            defer_stack: Vec::new(),
            pending_call: None,
            pending_await: None,
            suspend_event: None,
            pending_cancel: None,
            pending_select: None,
            pending_select_wait: None,
        }
    }

    /// 设置节点的产出值（局部 NodeId）。
    pub fn set_value(&mut self, node: NodeId, value: ValueHandle, consumer_count: u16) {
        self.value_table[node.0 as usize].set_value(value, consumer_count);
    }

    /// 获取节点的产出值（局部 NodeId）。
    pub fn get_value(&self, node: NodeId) -> ValueHandle {
        self.value_table[node.0 as usize].value
    }

    /// 获取节点的产出值（全局 NodeId，自动转换为局部索引）。
    /// compute_fn 读取输入时使用此方法（inputs_pool 存全局 NodeId）。
    pub fn get_value_by_global(&self, global_node: NodeId) -> ValueHandle {
        let local = global_node.0 - self.node_offset;
        self.value_table[local as usize].value
    }

    /// 检查节点是否就绪（所有输入已产出）。
    pub fn is_node_ready(&self, node: NodeId) -> bool {
        self.pending_inputs[node.0 as usize] == 0
    }

    /// 入就绪队列。
    pub fn push_ready(&mut self, node: NodeId) {
        self.ready_queue.push_back(node);
    }

    /// 弹出就绪节点。
    pub fn pop_ready(&mut self) -> Option<NodeId> {
        self.ready_queue.pop_front()
    }
}

// =========================================================================
// EventSource — 事件源（图外运行时对象，产出值注入 await 节点输入边）
// =========================================================================

/// Channel id（运行时）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ChannelId(pub u32);

/// Timer id（运行时）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimerId(pub u32);

/// Async handle id（运行时，async 调用完成事件）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AsyncHandleId(pub u32);

/// 事件源：图外运行时对象，产出值注入到 await 节点的输入边。
///
/// - await 节点的某个输入边指向 EventSource 声明节点
/// - EventSource 声明节点在运行时绑定到具体 EventSource 实例
/// - 事件到达时，事件源把值写到 await 节点对应输入的值表槽
///
/// call 节点等"子图完成事件"，await 节点等"channel/timer/async 事件"——
/// 两者执行引擎无差别处理，这就是 call 和 await 的统一。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventSource {
    /// channel 有数据可读/可写
    Channel(ChannelId),
    /// async 调用完成
    AsyncJoin(AsyncHandleId),
    /// 定时器到期
    Timer(TimerId),
    /// 子图执行完成（用于 call 节点）
    SubgraphComplete(SubgraphInstanceId),
}

// =========================================================================
// DeferEntry — defer 块（帧 Drop 语义）
// =========================================================================

/// defer 块定义：编译为独立子图，帧释放时按 LIFO 执行。
///
/// 解决 Zig 痛点：defer 挂在帧上，任何帧释放路径都执行
/// （正常返回、错误传播、取消），统一无特例。
#[derive(Debug, Clone)]
pub struct DeferEntry {
    /// defer 注册点（触发节点）
    pub trigger_node: NodeId,
    /// defer 块体子图
    pub body_subgraph: SubGraphId,
    /// 捕获的变量（注册时快照的 NodeId 列表）
    pub captured_inputs: Vec<NodeId>,
    /// 是否已注册到帧的 defer_stack（运行时标记，避免重复执行）
    pub registered: bool,
}

// =========================================================================
// RecordLitInfo — 记录构造信息（RecordLit 节点用）
// =========================================================================

/// 记录构造信息（RecordLit 节点用）。
///
/// RecordLit 编译为构造节点，compute_fn 从输入收集字段值构造 RecordValue。
/// type_name 和 field_names 存入此表（按 NodeId 索引）。
#[derive(Debug, Clone)]
pub struct RecordLitInfo {
    pub type_name: String,
    pub field_names: Vec<Option<String>>,
}

/// 闭包构造节点的信息（按 NodeId 索引，非闭包构造节点为 None）。
///
/// 闭包构造节点（compute_fn = 40）运行时从 closure_infos 取子图 id + arity，
/// 合并 inputs（捕获值）构造 Closure 堆对象。
#[derive(Debug, Clone, Copy)]
pub struct ClosureInfo {
    /// 闭包子图 id
    pub subgraph_id: SubGraphId,
    /// lambda 参数数（不含捕获的 upvalues）
    pub arity: u8,
}

// =========================================================================
// EventSourceDecl — 事件源声明（静态，编译期）
// =========================================================================

/// 事件源声明：在子图中声明外部事件接入点。
///
/// await 节点的某个输入边指向 EventSource 声明节点，
/// 运行时绑定到具体 EventSource 实例。
#[derive(Debug, Clone)]
pub struct EventSourceDecl {
    /// 声明所在节点
    pub node: NodeId,
    /// 事件源种类（运行时绑定实例）
    pub kind: EventSourceKind,
}

/// 事件源种类（静态声明，运行时绑定实例）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventSourceKind {
    /// channel 事件
    Channel,
    /// async join 事件
    AsyncJoin,
    /// timer 事件
    Timer,
    /// 子图完成事件
    SubgraphComplete,
}

// =========================================================================
// SubGraph — 函数子图（静态，编译期生成）
// =========================================================================

/// 函数子图：每个函数（含单态化实例）编译为一个 SubGraph。
///
/// - `node_range`：节点 id 范围 [start, end)
/// - `entry_node`：入口节点（接收参数）
/// - `return_node`：返回节点（产出返回值）
/// - `has_suspend`：是否有挂起点（async=true）
///
/// sync 函数 = 子图无挂起点，同步跑完立即产完成事件
/// async 函数 = 子图有挂起点（await 节点连事件源）
/// 区别仅在子图是否有 await 节点，执行引擎无差别处理。
#[derive(Debug, Clone)]
pub struct SubGraph {
    /// 子图 id
    pub id: SubGraphId,
    /// 节点 id 范围 [start, end)
    pub node_range: (NodeId, NodeId),
    /// 参数数（入口节点的输入数）
    pub param_count: u8,
    /// 入口节点（接收参数）
    pub entry_node: NodeId,
    /// 返回节点（产出返回值）
    pub return_node: NodeId,
    /// 是否有挂起点（async=true）
    pub has_suspend: bool,
    /// 声明的事件源（channel/timer 等）
    pub event_source_decls: Vec<EventSourceDecl>,
    /// defer 块子图定义
    pub defer_table: Vec<DeferEntry>,
}

// =========================================================================
// ComputeFn — 计算函数（构建期绑定，消除 dispatch）
// =========================================================================

/// 计算函数签名：接收帧 + 值 arena + 图 + 节点 id，返回产出值。
///
/// 构建期绑定索引（ComputeFnId），运行时通过计算函数表索引调用。
/// 每种运算+类型组合一个特化函数，运行时无类型检查、无 op 查表。
pub type ComputeFn = fn(
    frame: &mut Frame,
    arena: &mut crate::Value::ValueArena,
    graph: &DataFlowGraph,
    node: NodeId,
) -> ValueHandle;

/// 占位计算函数表（Ir.rs 内部测试用，Engine.rs 有真实表）。
pub const COMPUTE_FN_TABLE: &[ComputeFn] = &[noop_compute];

/// 占位计算函数（Const 节点不需要 compute_fn，帧初始化时预填充）。
fn noop_compute(
    _frame: &mut Frame,
    _arena: &mut crate::Value::ValueArena,
    _graph: &DataFlowGraph,
    _node: NodeId,
) -> ValueHandle {
    ValueHandle::VOID
}

/// 获取计算函数表（测试用）。
pub fn compute_fn_table() -> &'static [ComputeFn] {
    COMPUTE_FN_TABLE
}

/// 构建真实计算函数表（引用 Engine 模块的 compute_* 函数）。
///
/// 索引与 ComputeFnId 一一对应，IrBuilder::build() 末尾填充到 graph.compute_fns。
pub fn build_compute_fn_table() -> Vec<ComputeFn> {
    vec![
        crate::Engine::noop_compute_real,
        crate::Engine::compute_add_i32,
        crate::Engine::compute_add_f64,
        crate::Engine::compute_mul_i32,
        crate::Engine::compute_le_i32,
        crate::Engine::compute_sub_i32,
        crate::Engine::compute_div_i32,
        crate::Engine::compute_mod_i32,
        crate::Engine::compute_eq_i32,
        crate::Engine::compute_ne_i32,
        crate::Engine::compute_lt_i32,
        crate::Engine::compute_gt_i32,
        crate::Engine::compute_ge_i32,
        crate::Engine::compute_sub_f64,
        crate::Engine::compute_mul_f64,
        crate::Engine::compute_div_f64,
        crate::Engine::compute_eq_f64,
        crate::Engine::compute_ne_f64,
        crate::Engine::compute_lt_f64,
        crate::Engine::compute_gt_f64,
        crate::Engine::compute_le_f64,
        crate::Engine::compute_ge_f64,
        crate::Engine::compute_and_bool,
        crate::Engine::compute_or_bool,
        crate::Engine::compute_not_bool,
        crate::Engine::compute_neg_i32,
        crate::Engine::compute_neg_f64,
        crate::Engine::compute_eq_bool,
        crate::Engine::compute_throw_wrap_err,
        crate::Engine::compute_record_construct,
        crate::Engine::compute_record_field_get,
        crate::Engine::compute_array_construct,
        crate::Engine::compute_array_index,
        crate::Engine::compute_record_field_set,
        crate::Engine::compute_is_null,
        crate::Engine::compute_array_len,
        crate::Engine::compute_call_launch,   // 36
        crate::Engine::compute_gate_launch,   // 37
        crate::Engine::compute_await,         // 38
        crate::Engine::compute_async_call_launch, // 39
        crate::Engine::compute_closure_construct, // 40
        crate::Engine::compute_closure_call,      // 41
        crate::Engine::compute_cancel_async_handle, // 42
        crate::Engine::compute_select_gate,         // 43
    ]
}

// =========================================================================
// DataFlowGraph — 全局图容器
// =========================================================================

/// 数据流图：全局只读容器，所有 worker 共享。
///
/// - `nodes`：所有节点（全局连续）
/// - `inputs_pool`：所有输入（连续存储）
/// - `subgraphs`：所有函数子图
/// - `entry_subgraph`：程序入口子图
/// - `downstreams`：每节点的下游列表（fan-out 统计，用于槽级 RC）
pub struct DataFlowGraph {
    /// 所有节点（全局连续，按 NodeId 索引）
    pub nodes: Vec<Node>,
    /// 独立输入池
    pub inputs_pool: InputsPool,
    /// 所有函数子图
    pub subgraphs: Vec<SubGraph>,
    /// 程序入口子图
    pub entry_subgraph: Option<SubGraphId>,
    /// 计算函数表（构建期填充，运行时按 ComputeFnId 索引调用）
    pub compute_fns: Vec<ComputeFn>,
    /// 每节点的下游列表（fan-out 统计，downstreams[n] = 以节点 n 为输入的下游节点列表）
    pub downstreams: Vec<Vec<NodeId>>,
    /// 常量节点的原始值（按 NodeId 索引，非 Const 节点为 None）
    pub const_values: Vec<Option<ConstValue>>,
    /// Call 节点的目标子图（按 NodeId 索引，非 Call 节点为 None）
    pub call_targets: Vec<Option<SubGraphId>>,
    /// Gate 节点的分支信息（按 NodeId 索引，非 Gate 节点为 None）
    pub gate_branches: Vec<Option<GateBranches>>,
    /// 控制信号节点标记（按 NodeId 索引，None=普通节点）
    pub control_signal_nodes: Vec<Option<SignalKind>>,
    /// 字段访问信息（按 NodeId 索引，存 field_idx）
    pub field_access_infos: Vec<Option<u16>>,
    /// 记录构造信息（按 NodeId 索引）
    pub record_lit_infos: Vec<Option<RecordLitInfo>>,
    /// 字段赋值信息（按 NodeId 索引，存字段名，用于 compute_record_field_set）
    pub field_set_names: Vec<Option<String>>,
    /// vtable 动态分派 Call 节点的方法名（按 NodeId 索引，None=静态调用）
    /// 当 Call 节点有 vtable 方法名时，运行时从 TraitVal 查方法子图 id
    pub vtable_call_methods: Vec<Option<String>>,
    /// Await 节点对应的 EventSource 声明节点（按 NodeId 索引，非 Await 节点为 None）
    /// 解耦：EventSource 节点不参与数据流就绪判定，仅作为元数据引用
    pub await_event_sources: Vec<Option<NodeId>>,
    /// 闭包构造节点信息（按 NodeId 索引，非闭包构造节点为 None）
    pub closure_infos: Vec<Option<ClosureInfo>>,
    /// select 表达式分支信息（按 NodeId 索引，非 select gate 节点为 None）
    pub select_infos: Vec<Option<SelectInfo>>,
}

impl DataFlowGraph {
    /// 创建空图。
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),
            inputs_pool: InputsPool::new(),
            subgraphs: Vec::new(),
            entry_subgraph: None,
            compute_fns: build_compute_fn_table(),
            downstreams: Vec::new(),
            const_values: Vec::new(),
            call_targets: Vec::new(),
            gate_branches: Vec::new(),
            control_signal_nodes: Vec::new(),
            field_access_infos: Vec::new(),
            record_lit_infos: Vec::new(),
            field_set_names: Vec::new(),
            vtable_call_methods: Vec::new(),
            await_event_sources: Vec::new(),
            closure_infos: Vec::new(),
            select_infos: Vec::new(),
        }
    }

    /// 添加节点，返回其 NodeId。
    pub fn add_node(&mut self, node: Node) -> NodeId {
        let id = NodeId(self.nodes.len() as u32);
        self.nodes.push(node);
        self.downstreams.push(Vec::new());
        self.const_values.push(None);
        self.call_targets.push(None);
        self.gate_branches.push(None);
        self.control_signal_nodes.push(None);
        self.field_access_infos.push(None);
        self.record_lit_infos.push(None);
        self.field_set_names.push(None);
        self.vtable_call_methods.push(None);
        self.await_event_sources.push(None);
        self.closure_infos.push(None);
        self.select_infos.push(None);
        id
    }

    /// 设置 Call 节点的目标子图。
    pub fn set_call_target(&mut self, node: NodeId, target: SubGraphId) {
        self.call_targets[node.0 as usize] = Some(target);
    }

    /// 标记节点为控制信号触发点。
    pub fn set_control_signal(&mut self, node: NodeId, kind: SignalKind) {
        self.control_signal_nodes[node.0 as usize] = Some(kind);
    }

    /// 设置节点的字段访问信息。
    pub fn set_field_access_info(&mut self, node: NodeId, field_idx: u16) {
        self.field_access_infos[node.0 as usize] = Some(field_idx);
    }

    /// 设置节点的记录构造信息。
    pub fn set_record_lit_info(&mut self, node: NodeId, info: RecordLitInfo) {
        self.record_lit_infos[node.0 as usize] = Some(info);
    }

    /// 设置节点的字段赋值信息（字段名）。
    pub fn set_field_set_name(&mut self, node: NodeId, field_name: String) {
        self.field_set_names[node.0 as usize] = Some(field_name);
    }

    /// 标记 Call 节点为 vtable 动态分派，存储方法名。
    /// 运行时 Engine 从 TraitVal 的 method_names 查方法，取 Closure.func_id 为子图 id。
    pub fn set_vtable_call(&mut self, node: NodeId, method_name: String) {
        self.vtable_call_methods[node.0 as usize] = Some(method_name);
    }

    /// 设置 Await 节点对应的 EventSource 声明节点。
    pub fn set_await_event_source(&mut self, node: NodeId, es_node: NodeId) {
        self.await_event_sources[node.0 as usize] = Some(es_node);
    }

    /// 设置 Gate 节点的分支信息。
    pub fn set_gate_branches(&mut self, node: NodeId, branches: GateBranches) {
        self.gate_branches[node.0 as usize] = Some(branches);
    }

    /// 设置闭包构造节点的信息（子图 id + arity）。
    pub fn set_closure_info(&mut self, node: NodeId, info: ClosureInfo) {
        self.closure_infos[node.0 as usize] = Some(info);
    }

    /// 设置 select gate 节点的分支信息。
    pub fn set_select_info(&mut self, node: NodeId, info: SelectInfo) {
        self.select_infos[node.0 as usize] = Some(info);
    }

    /// 添加子图，返回其 SubGraphId。
    pub fn add_subgraph(&mut self, sg: SubGraph) -> SubGraphId {
        let id = SubGraphId(self.subgraphs.len() as u32);
        self.subgraphs.push(sg);
        id
    }

    /// 设置程序入口子图。
    pub fn set_entry_subgraph(&mut self, id: SubGraphId) {
        self.entry_subgraph = Some(id);
    }

    /// 计算所有节点的下游列表（fan-out 统计）。
    ///
    /// 遍历每个节点的输入，把该节点注册到各输入节点的 downstreams 列表。
    /// 用于槽级 RC：节点产出时 refcount = downstreams[n].len()。
    pub fn compute_downstreams(&mut self) {
        // 先清空
        for ds in &mut self.downstreams {
            ds.clear();
        }
        // 遍历节点，注册下游关系（inputs_pool 中的输入边）
        for nid in 0..self.nodes.len() {
            let node = self.nodes[nid];
            let inputs = self.inputs_pool.get(node.inputs_offset, node.input_count);
            for &input in inputs {
                self.downstreams[input.0 as usize].push(NodeId(nid as u32));
            }
        }
        // Gate 节点的 condition_input → Gate 边（Gate 就绪依赖条件值被计算）
        for nid in 0..self.nodes.len() {
            if let Some(gb) = &self.gate_branches[nid] {
                self.downstreams[gb.condition_input.0 as usize].push(NodeId(nid as u32));
            }
        }
    }
}

impl Default for DataFlowGraph {
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// expr_id_to_key — ExprId → expr_types 的 key 转换
// =========================================================================

/// ExprId → expr_types 的 key（u64）。
///
/// Sema 的 expr_types key 是 "AST Expr 句柄地址"，
/// 经研究 key = ExprId.0 as u64（AstArena.exprs 下标）。
#[inline]
pub fn expr_id_to_key(id: crate::Ast::ExprId) -> u64 {
    id.0 as u64
}

// =========================================================================
// LoopContext — 循环上下文（continue 跳转目标 + For 循环迭代器节点）
// =========================================================================

/// 循环上下文：压入 loop_stack 供 continue/break 语义使用。
///
/// - `sg`：递归子图 id（continue 跳转目标）
/// - `iter_node`：For 循环 body_sg 中的迭代器参数节点（continue 需传递给尾递归；
///   None = While/Loop，param_count=0 无需传参）
#[derive(Debug, Clone, Copy)]
pub struct LoopContext {
    pub sg: SubGraphId,
    pub iter_node: Option<NodeId>,
}

// =========================================================================
// IrBuilder — 从 SemaResult + Module 构建 DataFlowGraph
// =========================================================================

/// IR 构建器：遍历 AST，生成 Node + InputsPool + SubGraph。
///
/// 以函数为单位编译子图：
/// 1. 注册所有函数为 SubGraph
/// 2. 编译每个函数的函数体
/// 3. 计算 fan-out（downstreams）
///
/// 本阶段实现核心 Expr 变体编译（Const/BinOp/Call/FieldAccess/Ident/Block）。
/// 控制流（If/Match/Loop）留到阶段 4。
/// compute_fn 用 noop_compute 占位，Engine 阶段替换为类型特化函数。
pub struct IrBuilder<'a> {
    pub sema: &'a crate::Sema::SemaResult,
    pub module: &'a crate::Ast::Module<'a>,
    /// builtin 模块列表（预编译，函数注册到 func_subgraphs）
    pub builtin_modules: Vec<&'a crate::Ast::Module<'a>>,
    /// 当前正在编译的 builtin 模块（None = 用户模块）
    pub compiling_builtin: Option<&'a crate::Ast::Module<'a>>,
    pub graph: DataFlowGraph,
    /// 函数名 → 子图 id 映射（Call 编译时查找绑定 call_target）
    pub func_subgraphs: std::collections::HashMap<String, SubGraphId>,
    /// 当前正在编译的函数子图 id（defer 注册用）
    pub current_function_sg: Option<SubGraphId>,
    /// 循环上下文栈：栈顶为当前循环的上下文（continue 跳转目标 + For 迭代器节点）
    pub loop_stack: Vec<LoopContext>,
    /// 变量作用域栈：变量名 → 产出该变量值的 NodeId
    pub scope_stack: Vec<std::collections::HashMap<String, NodeId>>,
}

impl<'a> IrBuilder<'a> {
    /// 创建构建器。
    pub fn new(sema: &'a crate::Sema::SemaResult, module: &'a crate::Ast::Module<'a>) -> Self {
        Self {
            sema,
            module,
            builtin_modules: Vec::new(),
            compiling_builtin: None,
            graph: DataFlowGraph::new(),
            func_subgraphs: std::collections::HashMap::new(),
            current_function_sg: None,
            loop_stack: Vec::new(),
            scope_stack: Vec::new(),
        }
    }

    /// 设置 builtin 模块列表（builder 风格，链式调用）。
    pub fn with_builtins(
        mut self,
        modules: Vec<&'a crate::Ast::Module<'a>>,
    ) -> Self {
        self.builtin_modules = modules;
        self
    }

    /// 返回当前正在编译的模块（builtin 优先，否则用户模块）。
    fn current_module(&self) -> &'a crate::Ast::Module<'a> {
        self.compiling_builtin.unwrap_or(self.module)
    }

    /// 进入新作用域。
    fn enter_scope(&mut self) {
        self.scope_stack.push(std::collections::HashMap::new());
    }

    /// 退出作用域。
    fn exit_scope(&mut self) {
        self.scope_stack.pop();
    }

    /// 绑定变量名到 NodeId（当前作用域）。
    fn bind_var(&mut self, name: &str, node_id: NodeId) {
        if let Some(scope) = self.scope_stack.last_mut() {
            scope.insert(name.to_string(), node_id);
        }
    }

    /// 查找变量绑定的 NodeId（从内到外查）。
    fn lookup_var(&self, name: &str) -> Option<NodeId> {
        for scope in self.scope_stack.iter().rev() {
            if let Some(&node_id) = scope.get(name) {
                return Some(node_id);
            }
        }
        None
    }

    /// CompoundAssignOp → 对应二元运算的 ComputeFnId。
    ///
    /// 位运算（bitand/bitor/bitxor/shl/shr）尚未有专门 compute_fn，暂用 noop(0) 占位。
    fn compound_assign_op_to_compute_fn(&self, op: crate::Ast::CompoundAssignOp) -> ComputeFnId {
        use crate::Ast::CompoundAssignOp;
        match op {
            CompoundAssignOp::AddAssign => ComputeFnId(1),  // add_i32
            CompoundAssignOp::SubAssign => ComputeFnId(5),  // sub_i32
            CompoundAssignOp::MulAssign => ComputeFnId(3),  // mul_i32
            CompoundAssignOp::DivAssign => ComputeFnId(6),  // div_i32
            CompoundAssignOp::ModAssign => ComputeFnId(7),  // mod_i32
            CompoundAssignOp::BitAndAssign => ComputeFnId(22), // and_bool（暂复用）
            CompoundAssignOp::BitOrAssign => ComputeFnId(23),  // or_bool（暂复用）
            CompoundAssignOp::BitXorAssign => ComputeFnId(0),  // noop（未实现）
            CompoundAssignOp::ShlAssign => ComputeFnId(0),     // noop
            CompoundAssignOp::ShrAssign => ComputeFnId(0),     // noop
        }
    }

    /// 注册占位子图（节点范围待编译后填充）。
    pub fn register_subgraph_placeholder(
        &mut self,
        _name: &str,
        param_count: u8,
        is_async: bool,
    ) -> SubGraphId {
        let id = SubGraphId(self.graph.subgraphs.len() as u32);
        let sg = SubGraph {
            id,
            node_range: (NodeId(0), NodeId(0)),
            param_count,
            entry_node: NodeId(0),
            return_node: NodeId(0),
            has_suspend: is_async,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        };
        self.graph.subgraphs.push(sg);
        id
    }

    /// 编译表达式为 Node，返回其 NodeId。
    pub fn compile_expr(&mut self, expr_id: crate::Ast::ExprId) -> NodeId {
        let spanned = self.current_module().arena.expr(expr_id);
        let expr = &spanned.node;
        match expr {
            // 常量
            crate::Ast::Expr::IntLit { .. }
            | crate::Ast::Expr::FloatLit { .. }
            | crate::Ast::Expr::BoolLit(_)
            | crate::Ast::Expr::CharLit(_)
            | crate::Ast::Expr::StrLit(_)
            | crate::Ast::Expr::NullLit
            | crate::Ast::Expr::VoidLit => self.compile_const_with_value(expr_id),

            // 变量引用
            crate::Ast::Expr::Ident(name) => match self.lookup_var(name) {
                Some(node_id) => node_id,
                None => self.compile_const(),
            },

            // 二元运算
            crate::Ast::Expr::Binary { op, lhs, rhs } => {
                self.compile_binary(*op, *lhs, *rhs)
            }

            // 函数调用
            crate::Ast::Expr::Call { callee, args, .. } => self.compile_call(*callee, args),
            crate::Ast::Expr::MethodCall { recv, method, args, .. } => {
                self.compile_method_call(*recv, method, args)
            }

            // 字段访问
            crate::Ast::Expr::FieldAccess { recv, field }
            | crate::Ast::Expr::SafeAccess { recv, field } => {
                self.compile_field_access(expr_id, *recv, field)
            }
            crate::Ast::Expr::Index { recv, index } => self.compile_index(*recv, *index),

            // Block 表达式
            crate::Ast::Expr::Block { stmts, trailing } => self.compile_block(stmts, trailing),

            // If 表达式 → Gate 节点 + 分支子图
            crate::Ast::Expr::If {
                cond,
                then_branch,
                else_branch,
            } => self.compile_if(*cond, *then_branch, *else_branch),

            // Match 表达式 → Gate 链
            crate::Ast::Expr::Match { scrutinee, arms } => {
                self.compile_match(*scrutinee, arms)
            }

            // 记录构造
            crate::Ast::Expr::RecordLit(fields) => self.compile_record_lit(fields),

            // Lambda 表达式 → 闭包子图 + 闭包构造节点
            crate::Ast::Expr::Lambda { params, body, is_async, .. } => {
                self.compile_lambda(params, body, *is_async)
            }

            // 数组构造
            crate::Ast::Expr::ArrayLit { elements, .. } => {
                self.compile_array_lit(elements)
            }

            // 赋值表达式：target = value
            crate::Ast::Expr::Assign { target, value } => {
                let val_node = self.compile_expr(*value);
                let target_expr = &self.current_module().arena.expr(*target).node;
                match target_expr {
                    crate::Ast::Expr::Ident(name) => {
                        self.bind_var(name, val_node);
                    }
                    crate::Ast::Expr::FieldAccess { recv: obj, field }
                    | crate::Ast::Expr::SafeAccess { recv: obj, field } => {
                        let obj_node = self.compile_expr(*obj);
                        let off = self.graph.inputs_pool.push(&[obj_node, val_node]);
                        let set_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: ComputeFnId(33), // record_field_set
                        });
                        self.graph.set_field_set_name(set_node, field.to_string());
                    }
                    _ => {}
                }
                self.compile_void_const()
            }

            // 复合赋值：target op= value
            crate::Ast::Expr::CompoundAssign { op, target, value } => {
                let val_node = self.compile_expr(*value);
                let target_expr = &self.current_module().arena.expr(*target).node;
                let bin_compute = self.compound_assign_op_to_compute_fn(*op);
                match target_expr {
                    crate::Ast::Expr::Ident(name) => {
                        let cur_node = self
                            .lookup_var(name)
                            .unwrap_or_else(|| self.compile_placeholder());
                        let off = self.graph.inputs_pool.push(&[cur_node, val_node]);
                        let result_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: bin_compute,
                        });
                        self.bind_var(name, result_node);
                        result_node
                    }
                    crate::Ast::Expr::FieldAccess { recv: obj, field }
                    | crate::Ast::Expr::SafeAccess { recv: obj, field } => {
                        let obj_node = self.compile_expr(*obj);
                        // 读当前字段值
                        let get_off = self.graph.inputs_pool.push(&[obj_node]);
                        let get_node = self.graph.add_node(Node {
                            kind: NodeKind::FieldAccess,
                            input_count: 1,
                            inputs_offset: get_off,
                            compute_fn: ComputeFnId(30), // record_field_get
                        });
                        // 运算
                        let bin_off = self.graph.inputs_pool.push(&[get_node, val_node]);
                        let result_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: bin_off,
                            compute_fn: bin_compute,
                        });
                        // 写回
                        let set_off = self.graph.inputs_pool.push(&[obj_node, result_node]);
                        let set_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: set_off,
                            compute_fn: ComputeFnId(33), // record_field_set
                        });
                        self.graph.set_field_set_name(set_node, field.to_string());
                        result_node
                    }
                    _ => self.compile_void_const(),
                }
            }

            // select 表达式 → Gate 节点（compute_select_gate）+ 每分支独立子图
            crate::Ast::Expr::Select(arms) => self.compile_select(arms),

            // 其他本阶段占位
            _ => self.compile_placeholder(),
        }
    }

    /// 编译常量表达式（无输入）。
    fn compile_const(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        })
    }

    /// 编译 void 常量节点（return/break/continue 无值时用）。
    fn compile_void_const(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        });
        self.graph.const_values[n.0 as usize] = Some(ConstValue::Void);
        n
    }

    /// 编译带原始值的常量表达式，填充 const_values。
    fn compile_const_with_value(&mut self, expr_id: crate::Ast::ExprId) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let node_id = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        });
        let const_val = self.parse_const_value(expr_id);
        self.graph.const_values[node_id.0 as usize] = const_val;
        node_id
    }

    /// 从 AST 表达式解析常量值。
    fn parse_const_value(&self, expr_id: crate::Ast::ExprId) -> Option<ConstValue> {
        let spanned = self.current_module().arena.expr(expr_id);
        match &spanned.node {
            crate::Ast::Expr::IntLit { raw, suffix } => match suffix {
                None | Some("i32") => raw.parse::<i32>().ok().map(ConstValue::I32),
                Some("i64") => raw.parse::<i64>().ok().map(ConstValue::I64),
                _ => raw.parse::<i32>().ok().map(ConstValue::I32),
            },
            crate::Ast::Expr::FloatLit { raw, suffix } => match suffix {
                None | Some("f64") => raw.parse::<f64>().ok().map(ConstValue::F64),
                Some("f32") => raw.parse::<f32>().ok().map(ConstValue::F32),
                _ => raw.parse::<f64>().ok().map(ConstValue::F64),
            },
            crate::Ast::Expr::BoolLit(b) => Some(ConstValue::Bool(*b)),
            crate::Ast::Expr::NullLit => Some(ConstValue::Null),
            crate::Ast::Expr::VoidLit => Some(ConstValue::Void),
            _ => None,
        }
    }

    /// 编译占位节点（本阶段未实现的 Expr 变体）。
    fn compile_placeholder(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        })
    }

    /// 编译 If 表达式为 Gate 节点 + 两个分支子图。
    ///
    /// cond 编译为条件节点，then/else 各编译为独立子图。
    /// Gate 节点的 condition_input 指向 cond 节点，branches 携带分支子图 id。
    /// 分支子图无参数（闭包变量捕获留到后续阶段）。
    fn compile_if(
        &mut self,
        cond: crate::Ast::ExprId,
        then_branch: crate::Ast::ExprId,
        else_branch: Option<crate::Ast::ExprId>,
    ) -> NodeId {
        let cond_node = self.compile_expr(cond);
        let then_sg = self.compile_branch_subgraph(then_branch);
        let else_sg = match else_branch {
            Some(e) => self.compile_branch_subgraph(e),
            None => self.compile_void_subgraph(),
        };
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(37),
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: cond_node,
                branches: vec![
                    (true, then_sg, vec![]),
                    (false, else_sg, vec![]),
                ],
            },
        );
        gate_node
    }

    /// 编译分支表达式为子图（If 的 then/else 分支）。
    fn compile_branch_subgraph(&mut self, expr: crate::Ast::ExprId) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let return_node = self.compile_expr(expr);
        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });
        sg_id
    }

    /// 编译 void 子图（无 else 分支时用）。
    fn compile_void_subgraph(&mut self) -> SubGraphId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        });
        self.graph.const_values[node.0 as usize] = Some(ConstValue::Void);
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (node, NodeId(node.0 + 1)),
            param_count: 0,
            entry_node: node,
            return_node: node,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });
        sg_id
    }

    /// 编译 select 表达式。
    ///
    /// 每个 SelectArm 编译为独立子图（含事件源检查 + body）。
    /// Gate 节点（compute_select_gate）选第一个就绪分支：有就绪分支 → 启动该分支子图；
    /// 无就绪分支 → 帧挂起，注册所有事件源等待，任一事件到达时唤醒重新检查。
    fn compile_select(&mut self, arms: &[crate::Ast::SelectArm<'_>]) -> NodeId {
        let mut branches = Vec::with_capacity(arms.len());

        for arm in arms {
            let (event_kind, event_source_node, body_expr) = match arm {
                crate::Ast::SelectArm::Receive { channel_expr, body, .. } => {
                    let ch_node = self.compile_expr(*channel_expr);
                    (EventSourceKind::Channel, ch_node, *body)
                }
                crate::Ast::SelectArm::Timeout { duration, body } => {
                    let dur_node = self.compile_expr(*duration);
                    (EventSourceKind::Timer, dur_node, *body)
                }
            };

            // 为每个分支创建子图：先注册占位（node_range 待编译后回填）
            let node_start = self.graph.nodes.len() as u32;
            let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
            self.graph.add_subgraph(SubGraph {
                id: sg_id,
                node_range: (NodeId(node_start), NodeId(node_start)),
                param_count: 0,
                entry_node: NodeId(node_start),
                return_node: NodeId(node_start),
                has_suspend: true,
                event_source_decls: Vec::new(),
                defer_table: Vec::new(),
            });

            let prev_sg = self.current_function_sg;
            self.current_function_sg = Some(sg_id);
            self.enter_scope();

            // 编译 body（body 中的变量绑定在子图作用域内）
            let result_node = self.compile_expr(body_expr);

            self.exit_scope();
            self.current_function_sg = prev_sg;

            let node_end = self.graph.nodes.len() as u32;
            let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
            sg.node_range = (NodeId(node_start), NodeId(node_end));
            sg.return_node = result_node;

            branches.push(SelectBranch {
                subgraph_id: sg_id,
                event_kind,
                event_source_node,
            });
        }

        // 创建 Gate 节点（select 的核心：选第一个就绪分支）
        let gate_off = self.graph.inputs_pool.push(&[]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: gate_off,
            compute_fn: ComputeFnId(43), // compute_select_gate
        });
        self.graph.set_select_info(gate_node, SelectInfo { branches });

        gate_node
    }

    /// 编译 Lambda 表达式为闭包子图 + 闭包构造节点。
    ///
    /// 追加参数模型：捕获变量追加到子图参数列表末尾。
    /// - 子图 param_count = lambda 参数数 + 捕获变量数
    /// - 子图前 N 个节点 = lambda 参数节点，后续 = 捕获 upvalue 参数节点
    /// - 当前作用域创建闭包构造节点（compute_fn 40），inputs = 捕获值节点
    /// - Lambda 表达式的值 = 闭包构造节点（运行时产出 Closure 堆对象）
    fn compile_lambda(
        &mut self,
        params: &[crate::Ast::Param<'_>],
        body: &crate::Ast::LambdaBody,
        is_async: bool,
    ) -> NodeId {
        use crate::Ast::LambdaBody;

        let body_expr = match body {
            LambdaBody::Block(e) | LambdaBody::Expression(e) => *e,
        };

        // 1. 自由变量分析：收集 body 中引用的外层变量（排除 lambda 自身参数）
        let param_names: std::collections::HashSet<&str> =
            params.iter().map(|p| p.name).collect();
        let mut ident_names: Vec<String> = Vec::new();
        self.collect_free_idents_expr(body_expr, &mut ident_names);
        let mut captured: Vec<(String, NodeId)> = Vec::new();
        for name in &ident_names {
            if param_names.contains(name.as_str()) {
                continue;
            }
            if let Some(node) = self.lookup_var(name) {
                if !captured.iter().any(|(n, _)| n == name) {
                    captured.push((name.clone(), node));
                }
            }
        }

        let param_count = (params.len() + captured.len()) as u8;

        // 2. 注册占位子图（节点范围待编译后填充）
        let sg_id = self.register_subgraph_placeholder("", param_count, is_async);
        let node_start = self.graph.nodes.len() as u32;

        // 3. 进入 lambda 作用域：先创建 lambda 参数节点，再创建捕获 upvalue 参数节点，
        //    全部 bind_var（捕获节点在 lambda 作用域内遮蔽外层同名绑定）
        self.enter_scope();
        for param in params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: ComputeFnId(0),
            });
            self.bind_var(param.name, param_node);
        }
        for (name, _outer_node) in &captured {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let upvalue_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: ComputeFnId(0),
            });
            self.bind_var(name, upvalue_node);
        }

        // 4. 编译 body 得到返回节点
        let return_node = self.compile_expr(body_expr);
        self.exit_scope();

        // 5. 更新子图 node_range + return_node
        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;

        // 6. 在当前作用域创建闭包构造节点（inputs = 捕获值外层节点，compute_fn 40）
        let upvalue_nodes: Vec<NodeId> = captured.iter().map(|(_, n)| *n).collect();
        let inputs_offset = self.graph.inputs_pool.push(&upvalue_nodes);
        let construct_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: upvalue_nodes.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(40), // compute_closure_construct
        });
        self.graph.set_closure_info(
            construct_node,
            ClosureInfo {
                subgraph_id: sg_id,
                arity: params.len() as u8,
            },
        );
        construct_node
    }

    /// 递归收集表达式中的所有 Ident 名称（去重，保留首次出现顺序）。
    ///
    /// 简化版自由变量分析：遍历常见 Expr 变体收集标识符引用，
    /// 由调用方排除 lambda 参数并检查外层作用域绑定。
    fn collect_free_idents_expr(&self, expr_id: crate::Ast::ExprId, names: &mut Vec<String>) {
        use crate::Ast::LambdaBody;
        let spanned = self.current_module().arena.expr(expr_id);
        match &spanned.node {
            crate::Ast::Expr::Ident(name) => {
                if !names.iter().any(|n| n == name) {
                    names.push((*name).to_string());
                }
            }
            crate::Ast::Expr::Binary { lhs, rhs, .. } => {
                self.collect_free_idents_expr(*lhs, names);
                self.collect_free_idents_expr(*rhs, names);
            }
            crate::Ast::Expr::Unary { operand, .. } => {
                self.collect_free_idents_expr(*operand, names);
            }
            crate::Ast::Expr::Call { callee, args, .. } => {
                self.collect_free_idents_expr(*callee, names);
                for &a in args {
                    self.collect_free_idents_expr(a, names);
                }
            }
            crate::Ast::Expr::MethodCall { recv, args, .. } => {
                self.collect_free_idents_expr(*recv, names);
                for &a in args {
                    self.collect_free_idents_expr(a, names);
                }
            }
            crate::Ast::Expr::FieldAccess { recv, .. }
            | crate::Ast::Expr::SafeAccess { recv, .. } => {
                self.collect_free_idents_expr(*recv, names);
            }
            crate::Ast::Expr::Index { recv, index } => {
                self.collect_free_idents_expr(*recv, names);
                self.collect_free_idents_expr(*index, names);
            }
            crate::Ast::Expr::Assign { target, value } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Expr::CompoundAssign { target, value, .. } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Expr::ArrayLit { elements, .. } => {
                for &e in elements {
                    self.collect_free_idents_expr(e, names);
                }
            }
            crate::Ast::Expr::RecordLit(fields) => {
                for f in fields {
                    self.collect_free_idents_expr(f.value, names);
                }
            }
            crate::Ast::Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                self.collect_free_idents_expr(*cond, names);
                self.collect_free_idents_expr(*then_branch, names);
                if let Some(e) = else_branch {
                    self.collect_free_idents_expr(*e, names);
                }
            }
            crate::Ast::Expr::Block { stmts, trailing } => {
                for &s in stmts {
                    self.collect_free_idents_stmt(s, names);
                }
                if let Some(t) = trailing {
                    self.collect_free_idents_expr(*t, names);
                }
            }
            crate::Ast::Expr::Lambda { body, .. } => {
                let inner = match body {
                    LambdaBody::Block(e) | LambdaBody::Expression(e) => *e,
                };
                self.collect_free_idents_expr(inner, names);
            }
            crate::Ast::Expr::Match { scrutinee, arms } => {
                self.collect_free_idents_expr(*scrutinee, names);
                for arm in arms {
                    if let Some(g) = arm.guard {
                        self.collect_free_idents_expr(g, names);
                    }
                    self.collect_free_idents_expr(arm.body, names);
                }
            }
            _ => {}
        }
    }

    /// 递归收集语句中的 Ident 名称（collect_free_idents_expr 的语句版本）。
    fn collect_free_idents_stmt(&self, stmt_id: crate::Ast::StmtId, names: &mut Vec<String>) {
        let spanned = self.current_module().arena.stmt(stmt_id);
        match &spanned.node {
            crate::Ast::Stmt::ValDecl { value, .. }
            | crate::Ast::Stmt::VarDecl { value, .. } => {
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Stmt::Expression { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::Ast::Stmt::Assignment { target, value } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Stmt::FieldAssignment { object, value, .. } => {
                self.collect_free_idents_expr(*object, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Stmt::CompoundAssignment { target, value, .. } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::Ast::Stmt::Return { value } => {
                if let Some(v) = value {
                    self.collect_free_idents_expr(*v, names);
                }
            }
            crate::Ast::Stmt::Throw { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::Ast::Stmt::For { iterable, body, .. } => {
                self.collect_free_idents_expr(*iterable, names);
                self.collect_free_idents_expr(*body, names);
            }
            crate::Ast::Stmt::While { condition, body } => {
                self.collect_free_idents_expr(*condition, names);
                self.collect_free_idents_expr(*body, names);
            }
            crate::Ast::Stmt::Loop { body } => {
                self.collect_free_idents_expr(*body, names);
            }
            crate::Ast::Stmt::Defer { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::Ast::Stmt::Break | crate::Ast::Stmt::Continue => {}
        }
    }

    /// 创建指向 `target_sg` 的 Call 节点（无输入依赖，立即就绪）。
    ///
    /// 用于循环的初始调用与 continue 跳转。
    fn compile_recursive_call(&mut self, target_sg: SubGraphId) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(36),
        });
        self.graph.set_call_target(call_node, target_sg);
        call_node
    }

    /// 创建指向 `target_sg` 的 Call 节点，依赖 `after_node` 完成后才就绪。
    ///
    /// 用于循环体的尾递归调用：body 执行完毕后才递归下一轮，保证语句顺序。
    /// `after_node` 仅作数据依赖边（顺序约束），target_sg 的 param_count=0 故不注入参数。
    fn compile_recursive_call_after(
        &mut self,
        target_sg: SubGraphId,
        after_node: NodeId,
    ) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[after_node]);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset,
            compute_fn: ComputeFnId(36),
        });
        self.graph.set_call_target(call_node, target_sg);
        call_node
    }

    /// 创建指向 `target_sg` 的 Call 节点，传入指定参数节点。
    fn make_call(&mut self, target_sg: SubGraphId, arg_nodes: &[NodeId]) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(arg_nodes);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: arg_nodes.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(36),
        });
        self.graph.set_call_target(call_node, target_sg);
        call_node
    }

    /// 创建指向函数名的 Call 节点（通过 func_subgraphs 查找目标）。
    fn make_call_by_name(&mut self, name: &str, arg_nodes: &[NodeId]) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(arg_nodes);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: arg_nodes.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(36),
        });
        if let Some(&target_sg) = self.func_subgraphs.get(name) {
            self.graph.set_call_target(call_node, target_sg);
        }
        call_node
    }

    /// 创建 vtable 动态分派 Call 节点（trait 值的方法调用）。
    ///
    /// 与 make_call_by_name 区别：目标子图 id 运行时从 TraitVal 的 vtable 查询，
    /// 而非编译期绑定。用于 For 循环 iterable 是 trait 值（Iterator<T>）时。
    fn make_vtable_call(&mut self, recv_node: NodeId, method_name: &str) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset,
            compute_fn: ComputeFnId(36),
        });
        self.graph.set_vtable_call(call_node, method_name.to_string());
        call_node
    }

    /// 从 Sema 查询表达式的类型名（用于 For 循环静态分派）。
    /// 返回类型名字符串（如 "ArrayIter"、"RangeIterator"），未知返回 "Iterator"。
    fn lookup_expr_type_name(&self, expr: crate::Ast::ExprId) -> String {
        let expr_addr = expr.0 as u64;
        if let Some(info) = self.sema.expr_types.get(&expr_addr) {
            if let Some(ref tn) = info.type_name {
                return tn.to_string();
            }
        }
        // 未知类型默认 "Iterator"（走动态分派或报错）
        "Iterator".to_string()
    }

    /// 注册 For 循环子图（递归子图，param_count=1 接收迭代器）。
    ///
    /// 结构：
    /// - for_sg (param_count=1): 接收迭代器
    ///   - param_0 = 迭代器
    ///   - next_call = Call("Iterator.next", [param_0])  // 返回 T?
    ///   - is_null_node = UnOp(is_null, [next_call])
    ///   - body_sg (param_count=2): 迭代器 + 当前值（bind name, 编译 body, 尾递归 for_sg）
    ///   - void_sg (param_count=0): 退出
    ///   - gate = Gate(is_null_node): true→void_sg(退出), false→body_sg(继续)
    ///
    /// 执行：next() 返回非 null → body_sg 执行后尾递归 for_sg；返回 null → void_sg 退出。
    /// Break 信号终止 body_sg 帧 → Gate 完成 → for_sg 结束。
    /// Continue 编译为 Call(for_sg, [iter_param]) + Return 信号 → 尾递归下一轮。
    fn register_for_subgraph(
        &mut self,
        name: &str,
        body: crate::Ast::ExprId,
        iter_type_name: &str,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        // 占位注册（先占 id，便于递归引用）
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 1,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });

        // param_0 = 迭代器
        let iter_off = self.graph.inputs_pool.push(&[]);
        let iter_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: iter_off,
            compute_fn: ComputeFnId(0),
        });

        // next_call = Call("{iter_type_name}.next", [iter_param]) → T?
        // 动态分派：iter_type_name == "Iterator" 时走 vtable（运行时从 TraitVal 查 next）
        // 静态分派：其他类型按具体类型名 mangled 绑定（如 "ArrayIter.next"）
        let next_call = if iter_type_name == "Iterator" {
            self.make_vtable_call(iter_param, "next")
        } else {
            let next_method = format!("{}.next", iter_type_name);
            self.make_call_by_name(&next_method, &[iter_param])
        };

        // is_null_node = UnOp(is_null, [next_call])
        let is_null_off = self.graph.inputs_pool.push(&[next_call]);
        let is_null_node = self.graph.add_node(Node {
            kind: NodeKind::UnOp,
            input_count: 1,
            inputs_offset: is_null_off,
            compute_fn: ComputeFnId(34), // is_null
        });

        // body_sg (param_count=2: 迭代器 + 当前值)
        let body_sg = self.compile_for_body_subgraph(body, sg_id, name);

        // void_sg (退出)
        let void_sg = self.compile_void_subgraph();

        // gate = Gate(is_null_node): true→void_sg, false→body_sg(inputs=[iter_param, next_call])
        let gate_off = self.graph.inputs_pool.push(&[]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: gate_off,
            compute_fn: ComputeFnId(37),
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: is_null_node,
                branches: vec![
                    (true, void_sg, vec![]),
                    (false, body_sg, vec![iter_param, next_call]),
                ],
            },
        );

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = gate_node;
        sg_id
    }

    /// 编译 For 循环体子图（param_count=2: 迭代器 + 当前值）。
    ///
    /// - param_0 = 迭代器（尾递归用）
    /// - param_1 = 当前值（绑定到循环变量 name）
    /// - 编译 body，末尾尾递归 Call(for_sg, [param_0])（依赖 body_last 保证顺序）
    fn compile_for_body_subgraph(
        &mut self,
        body: crate::Ast::ExprId,
        for_sg: SubGraphId,
        name: &str,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;

        // param_0 = 迭代器（body_sg 内的节点，由 Gate branch inputs 注入）
        let iter_off = self.graph.inputs_pool.push(&[]);
        let iter_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: iter_off,
            compute_fn: ComputeFnId(0),
        });

        // param_1 = 当前值（绑定到循环变量 name）
        let val_off = self.graph.inputs_pool.push(&[]);
        let val_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: val_off,
            compute_fn: ComputeFnId(0),
        });

        self.enter_scope();
        self.bind_var(name, val_param);
        self.loop_stack.push(LoopContext {
            sg: for_sg,
            iter_node: Some(iter_param),
        });

        let body_last = self.compile_expr(body);

        self.loop_stack.pop();
        self.exit_scope();

        // 尾递归 Call(for_sg, [iter_param])，依赖 body_last 保证 body 完成后才递归
        // input_count=2: inputs[0]=iter_param(参数), inputs[1]=body_last(顺序依赖)
        // execute_call 按 for_sg.param_count=1 只注入 inputs[0]
        let tail_inputs = self.graph.inputs_pool.push(&[iter_param, body_last]);
        let tail_call = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 2,
            inputs_offset: tail_inputs,
            compute_fn: ComputeFnId(36),
        });
        self.graph.set_call_target(tail_call, for_sg);

        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 2,
            entry_node: NodeId(node_start),
            return_node: tail_call,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });
        sg_id
    }

    /// 注册 While 循环子图（递归子图）。
    ///
    /// 结构：
    /// - cond_node = compile_expr(condition)
    /// - gate_node = Gate(cond): true → body_sg(尾递归), false → void_sg(退出)
    /// - body_sg: 编译 body，末尾 Call 回 while_sg（依赖 body 末尾节点保证顺序）
    ///
    /// 执行：cond 为 true 时 body_sg 执行后尾递归 while_sg；false 时 void_sg 退出。
    /// Break 信号终止 body_sg 帧 → while_sg 的 Gate 完成 → 循环结束。
    /// Continue 编译为 Call(while_sg) + Return 信号 → 尾递归下一轮（跳过 body 剩余）。
    fn register_while_subgraph(
        &mut self,
        condition: crate::Ast::ExprId,
        body: crate::Ast::ExprId,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        // 占位注册（先占 id，便于递归引用）
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });

        // 编译 condition
        let cond_node = self.compile_expr(condition);
        // body 子图（末尾尾递归调用 while_sg）
        let body_sg = self.compile_loop_body_subgraph(body, sg_id);
        // void 子图（false 分支，循环结束）
        let void_sg = self.compile_void_subgraph();

        // Gate 节点：cond true → body_sg, false → void_sg
        let gate_off = self.graph.inputs_pool.push(&[]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: gate_off,
            compute_fn: ComputeFnId(37),
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: cond_node,
                branches: vec![
                    (true, body_sg, vec![]),
                    (false, void_sg, vec![]),
                ],
            },
        );

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = gate_node;
        sg_id
    }

    /// 注册 Loop 循环子图（无 condition，靠 Break 终止）。
    ///
    /// 结构：
    /// - loop_sg: Call(body_sg) 作为 return_node
    /// - body_sg: 编译 body，末尾尾递归调用 loop_sg
    ///
    /// 无 condition，body 执行后尾递归 loop_sg；Break 信号终止；Continue 尾递归下一轮。
    fn register_loop_subgraph(&mut self, body: crate::Ast::ExprId) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });

        // body 子图（末尾尾递归调用 loop_sg）
        let body_sg = self.compile_loop_body_subgraph(body, sg_id);

        // loop_sg 直接 Call body_sg
        let call_node = self.compile_recursive_call(body_sg);

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = call_node;
        sg_id
    }

    /// 编译循环体子图：编译 body，末尾尾递归调用 loop_sg。
    ///
    /// `loop_sg` 为 While 的 while_sg 或 Loop 的 loop_sg。
    /// 尾递归 Call 依赖 body 末尾节点，保证 body 完成后才递归下一轮。
    fn compile_loop_body_subgraph(
        &mut self,
        body: crate::Ast::ExprId,
        loop_sg: SubGraphId,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        // 压入循环上下文（continue 跳转目标，While/Loop 无迭代器参数）
        self.loop_stack.push(LoopContext {
            sg: loop_sg,
            iter_node: None,
        });
        let body_last = self.compile_expr(body);
        self.loop_stack.pop();
        // 尾递归调用 loop_sg（依赖 body_last 保证顺序）
        let call_node = self.compile_recursive_call_after(loop_sg, body_last);
        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: call_node,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        });
        sg_id
    }

    /// 编译 Match 表达式为 Gate 链。
    ///
    /// 每个 arm 编译为一个 Gate：
    /// - 判别节点 = 模式匹配结果（bool），作为 Gate 的 condition_input
    /// - Gate(true) → arm body 子图
    /// - Gate(false) → 下一个 arm 的 Gate 子图（作为 else 分支）
    ///
    /// 链式结构（从最后一个 arm 往前构建）：每个非首个 arm 的 Gate + pattern 包装为独立
    /// 子图（param_count=1，接收 scrutinee 作为参数），作为前一个 arm 的 else 分支。
    ///首个 arm 的 Gate 留在父帧，return_node = 该 Gate。
    ///
    /// scrutinee 通过 Gate 的 branch inputs 逐层注入到 wrap 子图的 param 节点，
    /// 使每个 wrap 子图内的 pattern 判别能访问 scrutinee。
    ///
    /// 最后一个 arm 的判别恒 true（穷尽保证）。
    /// 本阶段模式支持：Wildcard/Variable → const(true)，Literal → eq(scrutinee, lit)，
    /// 其他复杂模式保守放行（判别 true）。
    fn compile_match(
        &mut self,
        scrutinee: crate::Ast::ExprId,
        arms: &[crate::Ast::MatchArm],
    ) -> NodeId {
        let scrutinee_node = self.compile_expr(scrutinee);

        // 编译每个 arm 的 body 为子图（param_count=0，本阶段不绑定 scrutinee）
        let arm_body_subgraphs: Vec<SubGraphId> = arms
            .iter()
            .map(|arm| self.compile_branch_subgraph(arm.body))
            .collect();

        // 从最后一个 arm 往前构建 Gate 链。
        // pending_else_sg：上一个迭代（i+1）创建的 wrap 子图，作为当前 arm 的 else 分支。
        let mut pending_else_sg: Option<SubGraphId> = None;
        let mut result_gate: Option<NodeId> = None;

        for (i, arm) in arms.iter().enumerate().rev() {
            let wrap_start = self.graph.nodes.len() as u32;

            // 当前帧的 scrutinee 来源：首个 arm（i==0）在父帧直接用 scrutinee_node；
            // 其余 arm 在 wrap 子图内用 param 节点（由 else 分支输入注入）。
            let scrutinee_in_frame = if i == 0 {
                scrutinee_node
            } else {
                let off = self.graph.inputs_pool.push(&[]);
                self.graph.add_node(Node {
                    kind: NodeKind::Const,
                    input_count: 0,
                    inputs_offset: off,
                    compute_fn: ComputeFnId(0),
                })
            };

            let is_last = i == arms.len() - 1;
            let pattern_node = if is_last {
                self.compile_bool_const(true)
            } else {
                self.compile_pattern_match(scrutinee_in_frame, arm.pattern)
            };

            // false 分支：有 pending_else（来自 i+1）则用之并传入当前帧的 scrutinee；
            // 否则（最后一个 arm）用 void_sg。
            let (false_sg, false_inputs) = match pending_else_sg {
                Some(else_sg) => (else_sg, vec![scrutinee_in_frame]),
                None => (self.compile_void_subgraph(), Vec::new()),
            };

            let gate_off = self.graph.inputs_pool.push(&[]);
            let gate_node = self.graph.add_node(Node {
                kind: NodeKind::Gate,
                input_count: 0,
                inputs_offset: gate_off,
                compute_fn: ComputeFnId(37),
            });
            self.graph.set_gate_branches(
                gate_node,
                GateBranches {
                    condition_input: pattern_node,
                    branches: vec![
                        (true, arm_body_subgraphs[i], vec![scrutinee_in_frame]),
                        (false, false_sg, false_inputs),
                    ],
                },
            );

            let wrap_end = self.graph.nodes.len() as u32;

            if i == 0 {
                // 首个 arm：Gate 留在父帧，作为 Match 的结果节点
                result_gate = Some(gate_node);
            } else {
                // 包装为子图（param_count=1，scrutinee 参数），作为前一个 arm 的 else 分支
                let wrap_sg = SubGraphId(self.graph.subgraphs.len() as u32);
                self.graph.add_subgraph(SubGraph {
                    id: wrap_sg,
                    node_range: (NodeId(wrap_start), NodeId(wrap_end)),
                    param_count: 1,
                    entry_node: NodeId(wrap_start),
                    return_node: gate_node,
                    has_suspend: false,
                    event_source_decls: Vec::new(),
                    defer_table: Vec::new(),
                });
                pending_else_sg = Some(wrap_sg);
            }
        }

        result_gate.expect("match must have at least one arm")
    }

    /// 编译 bool 常量节点（Match 最后一个 arm 的穷尽判别用）。
    fn compile_bool_const(&mut self, b: bool) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        });
        self.graph.const_values[n.0 as usize] = Some(ConstValue::Bool(b));
        n
    }

    /// 编译模式匹配判别节点（返回 bool）。
    ///
    /// 本阶段：Wildcard/Variable → const(true)，Literal → eq(scrutinee, lit)，
    /// 其他复杂模式保守放行（判别 true，留后续阶段）。
    fn compile_pattern_match(
        &mut self,
        scrutinee_node: NodeId,
        pattern_id: crate::Ast::PatternId,
    ) -> NodeId {
        let pattern = self.current_module().arena.pattern(pattern_id);
        match &pattern.node {
            crate::Ast::Pattern::Wildcard | crate::Ast::Pattern::Variable { .. } => {
                self.compile_bool_const(true)
            }
            crate::Ast::Pattern::Literal(pl) => {
                // 字面量模式：eq(scrutinee, lit)
                let lit_node = self.compile_pattern_literal(pl);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, lit_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    // 默认 eq_i32（索引 8），字面量类型差异留后续阶段特化
                    compute_fn: ComputeFnId(8),
                })
            }
            // 其他复杂模式本阶段保守放行（判别 true）
            _ => self.compile_bool_const(true),
        }
    }

    /// 编译字面量模式为 Const 节点。
    fn compile_pattern_literal(&mut self, pl: &crate::Ast::PatternLiteral) -> NodeId {
        let const_val = match pl {
            crate::Ast::PatternLiteral::Int(s) => s.parse::<i32>().ok().map(ConstValue::I32),
            crate::Ast::PatternLiteral::Float(s) => s.parse::<f64>().ok().map(ConstValue::F64),
            crate::Ast::PatternLiteral::Bool(b) => Some(ConstValue::Bool(*b)),
            crate::Ast::PatternLiteral::String(_) => {
                // Str 常量需 'static，模式串来自 arena 非静态
                // 本阶段字符串模式判别保守放行，留后续阶段
                Some(ConstValue::Bool(true))
            }
            crate::Ast::PatternLiteral::Char(c) => Some(ConstValue::I32(*c as i32)),
            crate::Ast::PatternLiteral::Null => Some(ConstValue::Null),
        };
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: ComputeFnId(0),
        });
        self.graph.const_values[n.0 as usize] = const_val;
        n
    }

    /// 查询表达式的类型名（来自 Sema）。
    ///
    /// 优先取 ExprInfo.type_name（adt/generic 等场景），回退到 type_desc.type_name。
    fn expr_type_name(&self, expr_id: crate::Ast::ExprId) -> Option<&str> {
        let key = expr_id_to_key(expr_id);
        self.sema.expr_types.get(&key).map(|info| {
            info.type_name
                .as_deref()
                .unwrap_or(info.type_desc.type_name)
        })
    }

    /// 根据 op + 表达式类型选择 compute_fn id。
    fn select_binary_compute_fn(
        &self,
        op: crate::Ast::BinaryOp,
        lhs_expr: crate::Ast::ExprId,
    ) -> ComputeFnId {
        let ty_name = self.expr_type_name(lhs_expr).unwrap_or("i32");
        match op {
            crate::Ast::BinaryOp::Add => match ty_name {
                "f64" | "f32" => ComputeFnId(2),  // add_f64
                _ => ComputeFnId(1),              // add_i32
            },
            crate::Ast::BinaryOp::Sub => match ty_name {
                "f64" | "f32" => ComputeFnId(13), // sub_f64
                _ => ComputeFnId(5),              // sub_i32
            },
            crate::Ast::BinaryOp::Mul => match ty_name {
                "f64" | "f32" => ComputeFnId(14), // mul_f64
                _ => ComputeFnId(3),              // mul_i32
            },
            crate::Ast::BinaryOp::Div => match ty_name {
                "f64" | "f32" => ComputeFnId(15), // div_f64
                _ => ComputeFnId(6),              // div_i32
            },
            crate::Ast::BinaryOp::Mod => ComputeFnId(7),  // mod_i32
            crate::Ast::BinaryOp::Eq => match ty_name {
                "f64" | "f32" => ComputeFnId(16), // eq_f64
                "bool" => ComputeFnId(27),        // eq_bool
                _ => ComputeFnId(8),              // eq_i32
            },
            crate::Ast::BinaryOp::NotEq => match ty_name {
                "f64" | "f32" => ComputeFnId(17), // ne_f64
                _ => ComputeFnId(9),              // ne_i32
            },
            crate::Ast::BinaryOp::Lt => match ty_name {
                "f64" | "f32" => ComputeFnId(18), // lt_f64
                _ => ComputeFnId(10),             // lt_i32
            },
            crate::Ast::BinaryOp::Gt => match ty_name {
                "f64" | "f32" => ComputeFnId(19), // gt_f64
                _ => ComputeFnId(11),             // gt_i32
            },
            crate::Ast::BinaryOp::LtEq => match ty_name {
                "f64" | "f32" => ComputeFnId(20), // le_f64
                _ => ComputeFnId(4),              // le_i32
            },
            crate::Ast::BinaryOp::GtEq => match ty_name {
                "f64" | "f32" => ComputeFnId(21), // ge_f64
                _ => ComputeFnId(12),             // ge_i32
            },
            crate::Ast::BinaryOp::And => ComputeFnId(22), // and_bool
            crate::Ast::BinaryOp::Or => ComputeFnId(23),  // or_bool
            // 其他运算（RefEq/BitAnd/Shl/Range 等）本阶段用 noop，留后续
            _ => ComputeFnId(0),
        }
    }

    /// 编译二元运算。
    fn compile_binary(
        &mut self,
        op: crate::Ast::BinaryOp,
        lhs: crate::Ast::ExprId,
        rhs: crate::Ast::ExprId,
    ) -> NodeId {
        let lhs_node = self.compile_expr(lhs);
        let rhs_node = self.compile_expr(rhs);
        let inputs_offset = self.graph.inputs_pool.push(&[lhs_node, rhs_node]);
        let compute_fn = self.select_binary_compute_fn(op, lhs);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset,
            compute_fn,
        })
    }

    /// 编译函数调用。
    ///
    /// 若 callee 是已知函数名 → Call 节点 + set_call_target。
    /// 若 callee 是类型名（如 `Iterator(arr, 0)`）→ 编译为记录构造节点。
    fn compile_call(
        &mut self,
        callee: crate::Ast::ExprId,
        args: &[crate::Ast::ExprId],
    ) -> NodeId {
        let callee_expr = self.current_module().arena.expr(callee);

        // 类型构造器检测：callee 是 Ident 且不是已知函数，但在类型声明中找到
        if let crate::Ast::Expr::Ident(name) = &callee_expr.node {
            if !self.func_subgraphs.contains_key(*name) {
                if let Some(field_names) = self.lookup_type_field_names(name) {
                    // 编译为记录构造（compute_record_construct = 29）
                    let mut inputs = Vec::with_capacity(args.len());
                    for &arg in args {
                        inputs.push(self.compile_expr(arg));
                    }
                    let inputs_offset = self.graph.inputs_pool.push(&inputs);
                    let node = self.graph.add_node(Node {
                        kind: NodeKind::BinOp,
                        input_count: inputs.len() as u8,
                        inputs_offset,
                        compute_fn: ComputeFnId(29), // record_construct
                    });
                    self.graph.set_record_lit_info(node, RecordLitInfo {
                        type_name: name.to_string(),
                        field_names: field_names.into_iter().map(Some).collect(),
                    });
                    return node;
                }
            }
        }

        // 闭包调用检测：callee 是 Ident，非已知函数，但在作用域中绑定（变量持有 Closure）
        // → 用 compute_closure_call（idx 41），inputs[0] = 闭包值节点，inputs[1..] = 调用参数
        if let crate::Ast::Expr::Ident(name) = &callee_expr.node {
            if !self.func_subgraphs.contains_key(*name) {
                if let Some(closure_node) = self.lookup_var(name) {
                    let mut inputs = Vec::with_capacity(args.len() + 1);
                    inputs.push(closure_node);
                    for &arg in args {
                        inputs.push(self.compile_expr(arg));
                    }
                    let inputs_offset = self.graph.inputs_pool.push(&inputs);
                    return self.graph.add_node(Node {
                        kind: NodeKind::Call,
                        input_count: inputs.len() as u8,
                        inputs_offset,
                        compute_fn: ComputeFnId(41), // compute_closure_call
                    });
                }
            }
        }

        // 普通函数调用
        let mut inputs = Vec::with_capacity(args.len());
        for &arg in args {
            inputs.push(self.compile_expr(arg));
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        // 默认 sync call compute_fn（idx 36），async 函数用 compute_async_call_launch（idx 39）
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(36), // compute_call_launch（sync）
        });

        // 绑定目标子图（如果 callee 是已知函数名）
        if let crate::Ast::Expr::Ident(name) = &callee_expr.node {
            if let Some(&target_sg) = self.func_subgraphs.get(*name) {
                self.graph.set_call_target(call_node, target_sg);
                // async 函数：切换 compute_fn 为 compute_async_call_launch（idx 39）
                if let Some(sg) = self.graph.subgraphs.get(target_sg.0 as usize) {
                    if sg.has_suspend {
                        self.graph.nodes[call_node.0 as usize].compute_fn = ComputeFnId(39);
                    }
                }
            } else {
                eprintln!("DEBUG: compile_call: no target for callee '{}' (node {})", name, call_node.0);
            }
        }

        call_node
    }

    /// 查找类型声明的字段名列表（按声明顺序）。
    ///
    /// 在用户模块和 builtin 模块中搜索 TypeDecl，返回 Record 或单构造器 ADT 的字段名。
    /// 用于类型构造器调用（如 `Iterator(arr, 0)`）编译为记录构造。
    fn lookup_type_field_names(&self, type_name: &str) -> Option<Vec<String>> {
        let extract = |def: &crate::Ast::TypeDef<'_>| -> Option<Vec<String>> {
            match def {
                crate::Ast::TypeDef::Record { fields } => {
                    Some(fields.iter().map(|f| f.name.to_string()).collect())
                }
                crate::Ast::TypeDef::Adt { constructors } if constructors.len() == 1 => {
                    let ctor = &constructors[0];
                    Some(ctor.fields.iter()
                        .map(|f| f.name.unwrap_or("_").to_string())
                        .collect())
                }
                _ => None,
            }
        };
        // 搜索用户模块
        for d in &self.module.declarations {
            if let crate::Ast::Decl::TypeDecl { name, def, .. } = &d.node {
                if *name == type_name {
                    if let Some(names) = extract(def) {
                        return Some(names);
                    }
                }
            }
        }
        // 搜索 builtin 模块
        for m in &self.builtin_modules {
            for d in &m.declarations {
                if let crate::Ast::Decl::TypeDecl { name, def, .. } = &d.node {
                    if *name == type_name {
                        if let Some(names) = extract(def) {
                            return Some(names);
                        }
                    }
                }
            }
        }
        None
    }

    /// 编译方法调用。
    ///
    /// 内置方法（len/is_empty 等）编译为专用 compute_fn 节点。
    /// 类型方法编译为 Call 节点，通过 mangled name ("TypeName.method") 查找 call_target。
    fn compile_method_call(
        &mut self,
        recv: crate::Ast::ExprId,
        method: &str,
        args: &[crate::Ast::ExprId],
    ) -> NodeId {
        let recv_node = self.compile_expr(recv);

        // await 方法：编译为 Await 节点 + EventSource 声明节点
        // spec 4.5：await 等待事件源就绪，未就绪→帧挂起
        if method == "await" && args.is_empty() {
            // 创建 EventSource 声明节点（input_count=0，永不就绪）
            let es_inputs_offset = self.graph.inputs_pool.push(&[]);
            let es_node = self.graph.add_node(Node {
                kind: NodeKind::EventSource,
                input_count: 0,
                inputs_offset: es_inputs_offset,
                compute_fn: ComputeFnId(0), // noop
            });

            // 事件种类判定：从 recv 类型推断
            // Async<T> → AsyncJoin, Channel<T>/Receiver<T> → Channel, Timer → Timer
            // 简化：默认 AsyncJoin（5a-2 主要支持 await async handle）
            let event_kind = self.infer_event_source_kind(recv);
            let current_sg = self.current_function_sg;
            let es_decl = EventSourceDecl {
                node: es_node,
                kind: event_kind,
            };
            // 注册到当前子图的 event_source_decls
            if let Some(sg_id) = current_sg {
                if let Some(sg) = self.graph.subgraphs.get_mut(sg_id.0 as usize) {
                    sg.event_source_decls.push(es_decl);
                }
            }

            // 创建 Await 节点（inputs=[recv_node], compute_fn=compute_await idx 38）
            // EventSource 节点作为元数据引用存储在 await_event_sources 表，不参与就绪判定
            let await_inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
            let await_node = self.graph.add_node(Node {
                kind: NodeKind::Await,
                input_count: 1,
                inputs_offset: await_inputs_offset,
                compute_fn: ComputeFnId(38), // compute_await
            });
            self.graph.set_await_event_source(await_node, es_node);
            await_node
        } else if method == "cancel" && args.is_empty() {
            // cancel 方法：async_handle.cancel() → 标记 pending_cancel
            let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
            self.graph.add_node(Node {
                kind: NodeKind::UnOp,
                input_count: 1,
                inputs_offset,
                compute_fn: ComputeFnId(42), // cancel_async_handle
            })
        } else if method == "len" && args.is_empty() {
            let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
            self.graph.add_node(Node {
                kind: NodeKind::UnOp,
                input_count: 1,
                inputs_offset,
                compute_fn: ComputeFnId(35), // array_len
            })
        } else {
            // 类型/trait 方法：编译为 Call 节点，按以下优先级绑定目标：
            //   路径3  — trait 静态分派（recv 类型已知 → witness_table → func_subgraphs）
            //   路径3b — trait object 动态分派（vtable，运行时从 TraitVal 查方法子图）
            //   路径2  — 类型自有方法（func_subgraphs 后缀匹配）
            let mut inputs = Vec::with_capacity(1 + args.len());
            inputs.push(recv_node);
            for &arg in args {
                inputs.push(self.compile_expr(arg));
            }
            let inputs_offset = self.graph.inputs_pool.push(&inputs);
            let call_node = self.graph.add_node(Node {
                kind: NodeKind::Call,
                input_count: inputs.len() as u8,
                inputs_offset,
                compute_fn: ComputeFnId(36),
            });

            // 路径3：trait 方法静态分派
            if let Some(target_sg) = self.try_trait_static_dispatch(recv, method) {
                self.graph.set_call_target(call_node, target_sg);
                return call_node;
            }

            // 路径3b：trait object 动态分派（vtable）
            if self.is_trait_object_recv(recv) {
                self.graph.set_vtable_call(call_node, method.to_string());
                return call_node;
            }

            // 路径2：类型自有方法（mangled name 后缀匹配）
            let suffix = format!(".{}", method);
            for (key, &target_sg) in &self.func_subgraphs {
                if key.ends_with(&suffix) {
                    self.graph.set_call_target(call_node, target_sg);
                    break;
                }
            }

            call_node
        }
    }

    /// 尝试 trait 静态分派：recv 类型已知 → witness_table → func_subgraphs。
    ///
    /// 遍历常见 trait 名，对 recv 的 type_id 查询 witness_table 是否实现了
    /// 含该 method 的 trait；若命中则用 "TypeName.method" 形式查找已注册子图。
    fn try_trait_static_dispatch(&self, recv: crate::Ast::ExprId, method: &str) -> Option<SubGraphId> {
        let type_id = self.expr_type_id(recv)?;
        for trait_name in &["Show", "Eq", "Iterator", "Error", "Ord", "Hash"] {
            if let Some(mangled) = self
                .sema
                .witness_table
                .resolve_method_subgraph_name(trait_name, type_id, method)
            {
                if let Some(&sg) = self.func_subgraphs.get(&mangled) {
                    return Some(sg);
                }
            }
        }
        None
    }

    /// 判断 recv 是否是 trait object（需运行时动态分派）。
    ///
    /// 查 recv 的类型名，若为已知 trait 名则需走 vtable 动态分派。
    fn is_trait_object_recv(&self, recv: crate::Ast::ExprId) -> bool {
        let key = expr_id_to_key(recv);
        if let Some(info) = self.sema.expr_types.get(&key) {
            if let Some(tn) = &info.type_name {
                return matches!(
                    &**tn,
                    "Iterator" | "Show" | "Eq" | "Error" | "Ord" | "Hash"
                );
            }
        }
        false
    }

    /// 获取表达式的 type_id（从 SemaResult.expr_types 查询）。
    ///
    /// type_id 计算与 populate_witness_table 一致：type_def_index[name] + 22。
    fn expr_type_id(&self, expr: crate::Ast::ExprId) -> Option<u16> {
        let key = expr_id_to_key(expr);
        let info = self.sema.expr_types.get(&key)?;
        let type_name = info.type_name.as_deref()?;
        self.sema.type_def_index.get(type_name).map(|&idx| idx + 22)
    }

    /// 从 recv 表达式推断事件源种类。
    ///
    /// Async<T> → AsyncJoin, Channel<T>/Receiver<T> → Channel, Timer → Timer
    /// 默认 → AsyncJoin（5a-2 主要支持 await async handle）
    fn infer_event_source_kind(&self, recv: crate::Ast::ExprId) -> EventSourceKind {
        // 查 Sema expr_types 获取 recv 的类型名
        let key = expr_id_to_key(recv);
        if let Some(info) = self.sema.expr_types.get(&key) {
            if let Some(ref tn) = info.type_name {
                let tn = tn.as_ref();
                if tn.starts_with("Async") {
                    return EventSourceKind::AsyncJoin;
                }
                if tn.starts_with("Channel") || tn.starts_with("Receiver") {
                    return EventSourceKind::Channel;
                }
                if tn.contains("Timer") {
                    return EventSourceKind::Timer;
                }
            }
        }
        EventSourceKind::AsyncJoin
    }

    /// 编译字段访问。
    ///
    /// 查 Sema field_accesses 获取 field_idx，绑定 compute_record_field_get。
    fn compile_field_access(
        &mut self,
        expr_id: crate::Ast::ExprId,
        recv: crate::Ast::ExprId,
        _field: &str,
    ) -> NodeId {
        let recv_node = self.compile_expr(recv);
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::FieldAccess,
            input_count: 1,
            inputs_offset,
            compute_fn: ComputeFnId(30), // record_field_get
        });
        // 查 Sema field_accesses 获取 field_idx
        let key = expr_id_to_key(expr_id);
        let field_idx = self
            .sema
            .field_accesses
            .get(&key)
            .map(|info| info.field_idx)
            .unwrap_or(0);
        self.graph.set_field_access_info(node, field_idx);
        node
    }

    /// 编译索引访问。
    fn compile_index(&mut self, recv: crate::Ast::ExprId, index: crate::Ast::ExprId) -> NodeId {
        let recv_node = self.compile_expr(recv);
        let index_node = self.compile_expr(index);
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node, index_node]);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset,
            compute_fn: ComputeFnId(32), // array_index
        })
    }

    /// 编译记录构造表达式。
    fn compile_record_lit(&mut self, fields: &[crate::Ast::RecordFieldExpr<'_>]) -> NodeId {
        let mut inputs = Vec::with_capacity(fields.len());
        let mut field_names = Vec::with_capacity(fields.len());
        for field in fields {
            inputs.push(self.compile_expr(field.value));
            field_names.push(Some(field.name.to_string()));
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(29), // record_construct
        });
        self.graph.set_record_lit_info(
            node,
            RecordLitInfo {
                type_name: "Record".to_string(),
                field_names,
            },
        );
        node
    }

    /// 编译数组构造表达式。
    fn compile_array_lit(&mut self, elements: &[crate::Ast::ExprRef]) -> NodeId {
        let mut inputs = Vec::with_capacity(elements.len());
        for &elem in elements {
            inputs.push(self.compile_expr(elem));
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: ComputeFnId(31), // array_construct
        })
    }

    /// 编译 Block 表达式。
    ///
    /// 依次编译 stmts，trailing 表达式的 NodeId 作为 Block 产出。
    fn compile_block(
        &mut self,
        stmts: &[crate::Ast::StmtId],
        trailing: &Option<crate::Ast::ExprId>,
    ) -> NodeId {
        self.enter_scope();
        for &stmt_id in stmts {
            self.compile_stmt(stmt_id);
        }
        let result = match trailing {
            Some(expr_id) => self.compile_expr(*expr_id),
            None => {
                let inputs_offset = self.graph.inputs_pool.push(&[]);
                self.graph.add_node(Node {
                    kind: NodeKind::Const,
                    input_count: 0,
                    inputs_offset,
                    compute_fn: ComputeFnId(0),
                })
            }
        };
        self.exit_scope();
        result
    }

    /// 编译语句。
    fn compile_stmt(&mut self, stmt_id: crate::Ast::StmtId) {
        let spanned = self.current_module().arena.stmt(stmt_id);
        let stmt = &spanned.node;
        match stmt {
            crate::Ast::Stmt::ValDecl { name, value, .. }
            | crate::Ast::Stmt::VarDecl { name, value, .. } => {
                let value_node = self.compile_expr(*value);
                self.bind_var(name, value_node);
            }
            crate::Ast::Stmt::Expression { expr } => {
                let _ = self.compile_expr(*expr);
            }
            crate::Ast::Stmt::Assignment { target, value } => {
                let val_node = self.compile_expr(*value);
                // 简单变量赋值：rebind 变量名到新值节点
                let target_expr = &self.current_module().arena.expr(*target).node;
                if let crate::Ast::Expr::Ident(name) = target_expr {
                    self.bind_var(name, val_node);
                }
            }
            crate::Ast::Stmt::FieldAssignment { object, field, value } => {
                let obj_node = self.compile_expr(*object);
                let val_node = self.compile_expr(*value);
                let inputs_offset = self.graph.inputs_pool.push(&[obj_node, val_node]);
                let set_node = self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset,
                    compute_fn: ComputeFnId(33), // record_field_set
                });
                self.graph.set_field_set_name(set_node, field.to_string());
            }
            crate::Ast::Stmt::CompoundAssignment { target, op, value } => {
                let val_node = self.compile_expr(*value);
                let target_expr = &self.current_module().arena.expr(*target).node;
                let bin_compute = self.compound_assign_op_to_compute_fn(*op);
                if let crate::Ast::Expr::Ident(name) = target_expr {
                    let cur_node = self
                        .lookup_var(name)
                        .unwrap_or_else(|| self.compile_placeholder());
                    let off = self.graph.inputs_pool.push(&[cur_node, val_node]);
                    let result_node = self.graph.add_node(Node {
                        kind: NodeKind::BinOp,
                        input_count: 2,
                        inputs_offset: off,
                        compute_fn: bin_compute,
                    });
                    self.bind_var(name, result_node);
                }
            }
            crate::Ast::Stmt::Return { value } => {
                let return_node = match value {
                    Some(expr_id) => self.compile_expr(*expr_id),
                    None => self.compile_void_const(),
                };
                self.graph.set_control_signal(return_node, SignalKind::Return);
            }
            crate::Ast::Stmt::Throw { expr } => {
                let expr_node = self.compile_expr(*expr);
                // 包装为 ThrowVal(Err)
                let wrap_off = self.graph.inputs_pool.push(&[expr_node]);
                let wrap_node = self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset: wrap_off,
                    compute_fn: ComputeFnId(28), // throw_wrap_err
                });
                // throw = 提前返回 ThrowVal
                self.graph.set_control_signal(wrap_node, SignalKind::Return);
            }
            crate::Ast::Stmt::Break => {
                let n = self.compile_void_const();
                self.graph.set_control_signal(n, SignalKind::Break);
            }
            crate::Ast::Stmt::Continue => {
                // continue = 尾递归调用当前循环子图 + Return 信号
                // 跳过 body 剩余，直接进入下一轮（Sema 保证 continue 必在循环内）
                if let Some(ctx) = self.loop_stack.last().copied() {
                    let call_node = match ctx.iter_node {
                        // For 循环：需传迭代器参数给尾递归
                        Some(iter_node) => {
                            let inputs_offset = self.graph.inputs_pool.push(&[iter_node]);
                            let call_node = self.graph.add_node(Node {
                                kind: NodeKind::Call,
                                input_count: 1,
                                inputs_offset,
                                compute_fn: ComputeFnId(36),
                            });
                            self.graph.set_call_target(call_node, ctx.sg);
                            call_node
                        }
                        // While/Loop：param_count=0，无参数
                        None => self.compile_recursive_call(ctx.sg),
                    };
                    self.graph.set_control_signal(call_node, SignalKind::Return);
                } else {
                    // 无循环上下文（Sema 应已拦截）：保守终止当前帧
                    let n = self.compile_void_const();
                    self.graph.set_control_signal(n, SignalKind::Continue);
                }
            }
            crate::Ast::Stmt::While { condition, body } => {
                let while_sg = self.register_while_subgraph(*condition, *body);
                let call_node = self.compile_recursive_call(while_sg);
                let _ = call_node;
            }
            crate::Ast::Stmt::Loop { body } => {
                let loop_sg = self.register_loop_subgraph(*body);
                let call_node = self.compile_recursive_call(loop_sg);
                let _ = call_node;
            }
            crate::Ast::Stmt::For {
                name,
                iterable,
                body,
            } => {
                // For 循环 = iterable（已是迭代器）→ 递归子图 (next() + is_null + body)
                let iterable_node = self.compile_expr(*iterable);
                // 从 Sema 获取 iterable 类型名（决定静态分派目标）
                let iter_type_name = self.lookup_expr_type_name(*iterable);
                // 注册 For 循环子图（静态分派：按类型名绑定 next()）
                let for_sg = self.register_for_subgraph(name, *body, &iter_type_name);
                // 启动循环：Call(for_sg, [iterable_node])
                let _ = self.make_call(for_sg, &[iterable_node]);
            }
            crate::Ast::Stmt::Defer { expr } => {
                // defer expr → 编译 expr 为独立子图，注册到当前函数子图的 defer_table
                let body_sg = self.compile_branch_subgraph(*expr);
                let trigger = self.compile_void_const();
                if let Some(cur_sg) = self.current_function_sg {
                    let entry = DeferEntry {
                        trigger_node: trigger,
                        body_subgraph: body_sg,
                        captured_inputs: vec![],
                        registered: false,
                    };
                    self.graph.subgraphs[cur_sg.0 as usize]
                        .defer_table
                        .push(entry);
                }
            }
        }
    }

    /// 在用户模块和 builtin 模块中查找函数位置。
    /// 返回 None = 用户模块，Some(i) = builtin_modules[i]。
    fn find_function_location(&self, name: &str) -> Option<Option<usize>> {
        if self.module.find_function(name).is_some() {
            return Some(None);
        }
        for (i, builtin_mod) in self.builtin_modules.iter().enumerate() {
            if builtin_mod.find_function(name).is_some() {
                return Some(Some(i));
            }
        }
        None
    }

    /// 编译函数为子图（支持跨模块：用户模块 + builtin 模块）。
    pub fn compile_function(&mut self, name: &str) -> SubGraphId {
        let location = self
            .find_function_location(name)
            .unwrap_or_else(|| panic!("function {} not found", name));

        let module = match location {
            None => self.module,
            Some(i) => self.builtin_modules[i],
        };

        // 设置当前编译模块（compile_expr 通过 current_module() 访问 AST arena）
        let prev_builtin = self.compiling_builtin;
        self.compiling_builtin = match location {
            None => None,
            Some(i) => Some(self.builtin_modules[i]),
        };

        let (body_expr, is_async, params) = match module.find_function(name) {
            Some(d) => match &d.node {
                crate::Ast::Decl::FunDecl {
                    body,
                    is_async,
                    params,
                    ..
                } => (*body, *is_async, params.clone()),
                _ => panic!("{} is not a function", name),
            },
            None => panic!("function {} not found", name),
        };
        let param_count = params.len();

        let sg_id = self.register_subgraph_placeholder(name, param_count as u8, is_async);
        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.enter_scope();

        // 创建参数节点（Const 占位，值在运行时由 start_subgraph 注入）
        // 这些节点必须是子图的前 param_count 个节点
        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: ComputeFnId(0),
            });
            self.bind_var(param.name, param_node);
        }

        let return_node = self.compile_expr(body_expr);
        self.exit_scope();
        self.current_function_sg = None;
        self.compiling_builtin = prev_builtin;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;

        self.func_subgraphs.insert(name.to_string(), sg_id);
        sg_id
    }

    /// 编译 builtin 模块中 TypeDecl 的方法为子图（mangled name = "TypeName.method"）。
    fn compile_builtin_method(&mut self, type_name: &str, method_name: &str) {
        // 在 builtin 模块中查找方法
        let found = self.builtin_modules.iter().enumerate().find_map(|(mod_i, m)| {
            for d in &m.declarations {
                if let crate::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                    if *name == type_name {
                        for (method_i, method) in methods.iter().enumerate() {
                            if method.name == method_name && method.body.is_some() {
                                return Some((mod_i, method_i));
                            }
                        }
                    }
                }
            }
            None
        });

        let (mod_i, method_i) = match found {
            Some(x) => x,
            None => return,
        };

        let m = self.builtin_modules[mod_i];

        // 提取方法数据（避免借用冲突）
        let (body_expr, is_async, params) = {
            let mut result = None;
            for d in &m.declarations {
                if let crate::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                    if *name == type_name {
                        let method = &methods[method_i];
                        result = Some((
                            method.body.unwrap(),
                            method.is_async,
                            method.params.clone(),
                        ));
                        break;
                    }
                }
            }
            result.expect("method not found after location found")
        };

        let mangled = format!("{}.{}", type_name, method_name);
        let param_count = params.len();

        let prev = self.compiling_builtin;
        self.compiling_builtin = Some(m);

        let sg_id = self.register_subgraph_placeholder(&mangled, param_count as u8, is_async);
        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.enter_scope();

        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: ComputeFnId(0),
            });
            self.bind_var(param.name, param_node);
        }

        let return_node = self.compile_expr(body_expr);
        self.exit_scope();
        self.current_function_sg = None;
        self.compiling_builtin = prev;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;

        self.func_subgraphs.insert(mangled, sg_id);
    }

    /// 完整构建流程：编译 builtin 函数 + 用户函数 + 计算 fan-out。
    pub fn build(mut self) -> DataFlowGraph {
        // 1. 先编译 builtin 模块的函数（注册到 func_subgraphs 供用户代码调用）
        let builtin_fun_names: Vec<(Box<str>, usize)> = self
            .builtin_modules
            .iter()
            .enumerate()
            .flat_map(|(i, m)| {
                m.declarations.iter().filter_map(move |d| match &d.node {
                    crate::Ast::Decl::FunDecl { name, .. } => {
                        Some((name.to_string().into_boxed_str(), i))
                    }
                    _ => None,
                })
            })
            .collect();
        for (name, _mod_idx) in &builtin_fun_names {
            self.compile_function(name);
        }

        // 1b. 编译 builtin 模块中 TypeDecl 的方法（mangled name "TypeName.method"）
        let builtin_methods: Vec<(String, String)> = self
            .builtin_modules
            .iter()
            .flat_map(|m| {
                m.declarations.iter().flat_map(|d| {
                    if let crate::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                        methods
                            .iter()
                            .filter(|mt| mt.body.is_some())
                            .map(|mt| (name.to_string(), mt.name.to_string()))
                            .collect::<Vec<_>>()
                    } else {
                        Vec::new()
                    }
                })
            })
            .collect();
        for (type_name, method_name) in &builtin_methods {
            self.compile_builtin_method(type_name, method_name);
        }
        eprintln!("DEBUG: func_subgraphs keys after builtins: {:?}", self.func_subgraphs.keys().collect::<Vec<_>>());

        // 2. 收集用户模块函数名
        let fun_names: Vec<Box<str>> = self
            .module
            .declarations
            .iter()
            .filter_map(|d| match &d.node {
                crate::Ast::Decl::FunDecl { name, .. } => Some(name.to_string().into_boxed_str()),
                _ => None,
            })
            .collect();

        // 3. 编译用户模块函数
        let user_sg_start = self.graph.subgraphs.len() as u32;
        for name in &fun_names {
            self.compile_function(name);
        }

        // 计算 fan-out
        self.graph.compute_downstreams();

        // 设置入口子图（is_entry=true 的函数，在用户模块中查找）
        let mut entry_offset = 0u32;
        let mut found_entry = false;
        for (i, d) in self.module.declarations.iter().enumerate() {
            if let crate::Ast::Decl::FunDecl { is_entry: true, .. } = &d.node {
                entry_offset = i as u32;
                found_entry = true;
                break;
            }
        }
        if found_entry {
            let entry_idx = user_sg_start + entry_offset;
            if entry_idx < self.graph.subgraphs.len() as u32 {
                self.graph.entry_subgraph = Some(SubGraphId(entry_idx));
            }
        }

        // 构建期填充计算函数表（运行时按 ComputeFnId 索引调用）
        self.graph.compute_fns = build_compute_fn_table();

        self.graph
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_index_types_are_distinct() {
        let n: NodeId = NodeId(0);
        let s: SubGraphId = SubGraphId(0);
        let f: FuncId = FuncId(0);
        assert_eq!(n.0, 0);
        assert_eq!(s.0, 0);
        assert_eq!(f.0, 0);
    }

    #[test]
    fn test_node_kind_repr_u8() {
        assert_eq!(std::mem::size_of::<NodeKind>(), 1);
        assert_eq!(NodeKind::Const as u8, 0);
        assert_eq!(NodeKind::BinOp as u8, 1);
        assert_eq!(NodeKind::UnOp as u8, 2);
        assert_eq!(NodeKind::FieldAccess as u8, 3);
        assert_eq!(NodeKind::Call as u8, 4);
        assert_eq!(NodeKind::Await as u8, 5);
        assert_eq!(NodeKind::Gate as u8, 6);
        assert_eq!(NodeKind::EventSource as u8, 7);
    }

    #[test]
    fn test_node_size_is_16_bytes() {
        let size = std::mem::size_of::<Node>();
        assert!(size <= 16, "Node size {size} exceeds 16 bytes");
        assert_eq!(size % 4, 0, "Node size must be 4-byte aligned");
    }

    #[test]
    fn test_node_construction() {
        let node = Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: 100,
            compute_fn: ComputeFnId(5),
        };
        assert_eq!(node.kind, NodeKind::BinOp);
        assert_eq!(node.input_count, 2);
        assert_eq!(node.inputs_offset, 100);
        assert_eq!(node.compute_fn, ComputeFnId(5));
    }

    #[test]
    fn test_inputs_pool_push_and_get() {
        let mut pool = InputsPool::new();
        assert_eq!(pool.len(), 0);

        let offset = pool.push(&[NodeId(10), NodeId(20), NodeId(30)]);
        assert_eq!(offset, 0);
        assert_eq!(pool.len(), 3);

        let inputs = pool.get(offset, 3);
        assert_eq!(inputs, &[NodeId(10), NodeId(20), NodeId(30)]);

        let offset2 = pool.push(&[NodeId(40)]);
        assert_eq!(offset2, 3);
        assert_eq!(pool.get(offset2, 1), &[NodeId(40)]);
    }

    #[test]
    fn test_inputs_pool_empty_push() {
        let mut pool = InputsPool::new();
        let offset = pool.push(&[]);
        assert_eq!(offset, 0);
        assert_eq!(pool.len(), 0);
    }

    #[test]
    fn test_value_slot_unready() {
        let slot = ValueSlot::unready();
        assert!(!slot.ready);
        assert_eq!(slot.refcount, 0);
    }

    #[test]
    fn test_value_slot_set_ready() {
        use crate::Value::{ValueHandle, ValueTag};
        let mut slot = ValueSlot::unready();
        let handle = ValueHandle::new(ValueTag::I32, 42);
        slot.set_value(handle, 2);
        assert!(slot.ready);
        assert_eq!(slot.value, handle);
        assert_eq!(slot.refcount, 2);
    }

    #[test]
    fn test_value_slot_decref() {
        let mut slot = ValueSlot::unready();
        slot.set_value(ValueHandle::NULL, 2);
        assert!(slot.consume()); // refcount 1，未归零
        assert!(!slot.is_consumed());
        assert!(!slot.consume()); // refcount 0，归零
        assert!(slot.is_consumed());
    }

    #[test]
    fn test_event_source_variants() {
        let ch = EventSource::Channel(ChannelId(1));
        let timer = EventSource::Timer(TimerId(2));
        let join = EventSource::AsyncJoin(AsyncHandleId(3));
        let sub = EventSource::SubgraphComplete(SubgraphInstanceId(4));
        assert_eq!(ch, EventSource::Channel(ChannelId(1)));
        assert_ne!(ch, timer);
        assert!(matches!(ch, EventSource::Channel(_)));
        assert!(matches!(timer, EventSource::Timer(_)));
        assert!(matches!(join, EventSource::AsyncJoin(_)));
        assert!(matches!(sub, EventSource::SubgraphComplete(_)));
    }

    #[test]
    fn test_subgraph_construction() {
        let sg = SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(10)),
            param_count: 2,
            entry_node: NodeId(0),
            return_node: NodeId(9),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        };
        assert_eq!(sg.id, SubGraphId(0));
        assert_eq!(sg.node_range, (NodeId(0), NodeId(10)));
        assert_eq!(sg.param_count, 2);
        assert!(!sg.has_suspend);
    }

    #[test]
    fn test_subgraph_async_marker() {
        let sg = SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(0), NodeId(5)),
            param_count: 1,
            entry_node: NodeId(0),
            return_node: NodeId(4),
            has_suspend: true,
            event_source_decls: vec![EventSourceDecl {
                node: NodeId(2),
                kind: EventSourceKind::Channel,
            }],
            defer_table: Vec::new(),
        };
        assert!(sg.has_suspend);
        assert_eq!(sg.event_source_decls.len(), 1);
        assert_eq!(sg.event_source_decls[0].kind, EventSourceKind::Channel);
    }

    #[test]
    fn test_compute_fn_table_not_empty() {
        let table = compute_fn_table();
        assert!(!table.is_empty());
    }

    #[test]
    fn test_compute_fn_id_lookup() {
        let table = compute_fn_table();
        let id = ComputeFnId(0);
        let f = table[id.0 as usize];
        let _ = f as usize;
    }

    #[test]
    fn test_dataflow_graph_construction() {
        let mut graph = DataFlowGraph::new();
        assert!(graph.nodes.is_empty());
        assert!(graph.inputs_pool.is_empty());
        assert!(graph.subgraphs.is_empty());

        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        assert_eq!(n0, NodeId(0));

        let n1 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        assert_eq!(n1, NodeId(1));
        assert_eq!(graph.nodes.len(), 2);
    }

    #[test]
    fn test_dataflow_graph_add_subgraph() {
        let mut graph = DataFlowGraph::new();
        let sg = SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(2)),
            param_count: 0,
            entry_node: NodeId(0),
            return_node: NodeId(1),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        };
        let sid = graph.add_subgraph(sg);
        assert_eq!(sid, SubGraphId(0));
        assert_eq!(graph.subgraphs.len(), 1);
        assert_eq!(graph.entry_subgraph, None);
    }

    #[test]
    fn test_dataflow_graph_set_entry() {
        let mut graph = DataFlowGraph::new();
        let sg = SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: NodeId(0),
            return_node: NodeId(0),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
        };
        let sid = graph.add_subgraph(sg);
        graph.set_entry_subgraph(sid);
        assert_eq!(graph.entry_subgraph, Some(sid));
    }

    #[test]
    fn test_dataflow_graph_downstreams() {
        let mut graph = DataFlowGraph::new();
        // N0 产出，N1 和 N2 都消费 N0（fan-out）
        graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n0 = NodeId(0);
        graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset: 1,
            compute_fn: ComputeFnId(0),
        });
        graph.inputs_pool.push(&[n0]);
        graph.inputs_pool.push(&[n0]);

        graph.compute_downstreams();
        assert_eq!(graph.downstreams.len(), 3);
        assert!(graph.downstreams[0].contains(&NodeId(1)));
        assert!(graph.downstreams[0].contains(&NodeId(2)));
        assert!(graph.downstreams[1].is_empty());
    }

    // ── 阶段 2：IrBuilder 测试 ──

    #[test]
    fn test_expr_id_to_key_basic() {
        let id = crate::Ast::ExprId(42);
        let key = expr_id_to_key(id);
        assert_eq!(key, 42);
    }

    fn make_test_module<'a>(arena: crate::Ast::AstArena<'a>, declarations: Vec<crate::Ast::Spanned<crate::Ast::Decl<'a>>>) -> crate::Ast::Module<'a> {
        crate::Ast::Module {
            name: "test",
            source_path: None,
            arena,
            declarations,
        }
    }

    #[test]
    fn test_ir_builder_create_empty() {
        let sema = crate::Sema::SemaResult::new();
        let module = make_test_module(crate::Ast::AstArena::new(), Vec::new());
        let builder = IrBuilder::new(&sema, &module);
        assert_eq!(builder.graph.nodes.len(), 0);
        assert_eq!(builder.graph.subgraphs.len(), 0);
    }

    #[test]
    fn test_ir_builder_register_subgraph() {
        let sema = crate::Sema::SemaResult::new();
        let module = make_test_module(crate::Ast::AstArena::new(), Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let sg_id = builder.register_subgraph_placeholder("main", 0, false);
        assert_eq!(sg_id, SubGraphId(0));
        assert_eq!(builder.graph.subgraphs.len(), 1);
        assert_eq!(builder.graph.subgraphs[0].id, SubGraphId(0));
        assert!(!builder.graph.subgraphs[0].has_suspend);
    }

    #[test]
    fn test_compile_int_literal() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let expr_id = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "42", suffix: None },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(expr_id);
        assert_eq!(node_id, NodeId(0));
        assert_eq!(builder.graph.nodes.len(), 1);
        assert_eq!(builder.graph.nodes[0].kind, NodeKind::Const);
        assert_eq!(builder.graph.nodes[0].input_count, 0);
    }

    #[test]
    fn test_compile_multiple_literals() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let e1 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let e2 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let n1 = builder.compile_expr(e1);
        let n2 = builder.compile_expr(e2);
        assert_eq!(n1, NodeId(0));
        assert_eq!(n2, NodeId(1));
        assert_eq!(builder.graph.nodes.len(), 2);
    }

    #[test]
    fn test_compile_binary_add() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let lhs = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let rhs = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let bin = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Binary {
                op: crate::Ast::BinaryOp::Add,
                lhs,
                rhs,
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(bin);
        assert_eq!(node_id, NodeId(2));
        assert_eq!(builder.graph.nodes.len(), 3);
        let bin_node = &builder.graph.nodes[2];
        assert_eq!(bin_node.kind, NodeKind::BinOp);
        assert_eq!(bin_node.input_count, 2);
        let inputs = builder.graph.inputs_pool.get(bin_node.inputs_offset, 2);
        assert_eq!(inputs, &[NodeId(0), NodeId(1)]);
    }

    #[test]
    fn test_compile_call() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let arg1 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let arg2 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let callee = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("add"),
        );
        let call = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Call {
                callee,
                args: vec![arg1, arg2],
                type_args: None,
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(call);
        // callee 不作为输入节点也不创建节点，只有 2 个参数节点 + 1 个 call 节点 = 3 个节点
        assert_eq!(node_id, NodeId(2));
        assert_eq!(builder.graph.nodes.len(), 3);
        let call_node = &builder.graph.nodes[2];
        assert_eq!(call_node.kind, NodeKind::Call);
        // input_count 只计参数，不含 callee
        assert_eq!(call_node.input_count, 2);
    }

    #[test]
    fn test_compile_field_access() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let recv = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("obj"),
        );
        let access = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::FieldAccess { recv, field: "x" },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(access);
        assert_eq!(node_id, NodeId(1));
        let node = &builder.graph.nodes[1];
        assert_eq!(node.kind, NodeKind::FieldAccess);
        assert_eq!(node.input_count, 1);
    }

    #[test]
    fn test_compile_ident() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let ident = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("x"),
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(ident);
        assert_eq!(node_id, NodeId(0));
        assert_eq!(builder.graph.nodes[0].kind, NodeKind::Const);
        assert_eq!(builder.graph.nodes[0].input_count, 0);
    }

    #[test]
    fn test_compile_block_with_trailing() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let val = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "42", suffix: None },
        );
        let block = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Block {
                stmts: vec![],
                trailing: Some(val),
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(block);
        assert_eq!(node_id, NodeId(0));
        assert_eq!(builder.graph.nodes.len(), 1);
    }

    #[test]
    fn test_compile_block_with_stmts() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let val = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let stmt = arena.alloc_stmt(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Stmt::ValDecl {
                name: "x",
                type_annotation: None,
                value: val,
                visibility: crate::Ast::Visibility::Private,
            },
        );
        let trailing = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("x"),
        );
        let block = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Block {
                stmts: vec![stmt],
                trailing: Some(trailing),
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(block);
        // Ident("x") 直接返回 ValDecl 的值节点 NodeId(0)，不创建新节点
        assert_eq!(node_id, NodeId(0));
        assert_eq!(builder.graph.nodes.len(), 1);
    }

    #[test]
    fn test_compile_simple_function() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let a = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("a"),
        );
        let b = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("b"),
        );
        let body = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Binary {
                op: crate::Ast::BinaryOp::Add,
                lhs: a,
                rhs: b,
            },
        );
        let fun_decl = crate::Ast::Decl::FunDecl {
            visibility: crate::Ast::Visibility::Private,
            name: "add",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body,
            is_async: false,
            is_entry: false,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = make_test_module(
            arena,
            vec![crate::Ast::Spanned {
                span: crate::Ast::Span { line: 1, column: 1 },
                node: fun_decl,
            }],
        );
        let mut builder = IrBuilder::new(&sema, &module);
        let sg_id = builder.compile_function("add");
        assert_eq!(sg_id, SubGraphId(0));
        assert_eq!(builder.graph.subgraphs[0].node_range, (NodeId(0), NodeId(3)));
        assert_eq!(builder.graph.subgraphs[0].return_node, NodeId(2));
        assert!(!builder.graph.subgraphs[0].has_suspend);
    }

    #[test]
    fn test_build_fanout_calculation() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let a_ref1 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("a"),
        );
        let a_ref2 = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Ident("a"),
        );
        let add = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Binary {
                op: crate::Ast::BinaryOp::Add,
                lhs: a_ref1,
                rhs: a_ref2,
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let _ = builder.compile_expr(add);
        assert_eq!(builder.graph.nodes.len(), 3);
        builder.graph.compute_downstreams();
        assert!(builder.graph.downstreams[2].is_empty());
        assert!(builder.graph.downstreams[0].contains(&NodeId(2)));
        assert!(builder.graph.downstreams[1].contains(&NodeId(2)));
    }

    // ── 阶段 3：const_values 测试 ──

    #[test]
    fn test_const_values_int_literal() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let expr_id = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "42", suffix: None },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(expr_id);
        assert_eq!(
            builder.graph.const_values[node_id.0 as usize],
            Some(ConstValue::I32(42))
        );
    }

    #[test]
    fn test_const_values_bool_literal() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let expr_id = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::BoolLit(true),
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let node_id = builder.compile_expr(expr_id);
        assert_eq!(
            builder.graph.const_values[node_id.0 as usize],
            Some(ConstValue::Bool(true))
        );
    }

    #[test]
    fn test_control_signal_default_is_none() {
        let frame = Frame::new(FrameId(0), SubGraphId(0), 0);
        assert!(matches!(frame.control_signal, ControlSignal::None));
    }

    #[test]
    fn test_control_signal_nodes_table() {
        let mut graph = DataFlowGraph::new();
        let n = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        assert_eq!(graph.control_signal_nodes[n.0 as usize], None);
        graph.set_control_signal(n, SignalKind::Return);
        assert_eq!(
            graph.control_signal_nodes[n.0 as usize],
            Some(SignalKind::Return)
        );
    }

    #[test]
    fn test_compile_binary_binds_compute_fn() {
        // 无 Sema 类型信息时，i32 Add → ComputeFnId(1) = add_i32
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let lhs = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let rhs = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let bin = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Binary {
                op: crate::Ast::BinaryOp::Add,
                lhs,
                rhs,
            },
        );
        let module = make_test_module(arena, Vec::new());
        let mut builder = IrBuilder::new(&sema, &module);
        let n = builder.compile_expr(bin);
        assert_eq!(
            builder.graph.nodes[n.0 as usize].compute_fn,
            ComputeFnId(1)
        );
    }

    #[test]
    fn test_compile_return_marks_signal() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let val = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::IntLit { raw: "42", suffix: None },
        );
        let ret_stmt = arena.alloc_stmt(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Stmt::Return { value: Some(val) },
        );
        let body = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Block {
                stmts: vec![ret_stmt],
                trailing: None,
            },
        );
        let fun_decl = crate::Ast::Decl::FunDecl {
            visibility: crate::Ast::Visibility::Private,
            name: "main",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body,
            is_async: false,
            is_entry: true,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = make_test_module(
            arena,
            vec![crate::Ast::Spanned {
                span: crate::Ast::Span { line: 1, column: 1 },
                node: fun_decl,
            }],
        );
        let mut builder = IrBuilder::new(&sema, &module);
        builder.compile_function("main");
        let has_return_signal = builder
            .graph
            .control_signal_nodes
            .iter()
            .any(|n| *n == Some(SignalKind::Return));
        assert!(has_return_signal);
    }

    #[test]
    fn test_compile_break_marks_signal() {
        let sema = crate::Sema::SemaResult::new();
        let mut arena = crate::Ast::AstArena::new();
        let break_stmt = arena.alloc_stmt(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Stmt::Break,
        );
        let body = arena.alloc_expr(
            crate::Ast::Span { line: 1, column: 1 },
            crate::Ast::Expr::Block {
                stmts: vec![break_stmt],
                trailing: None,
            },
        );
        let fun_decl = crate::Ast::Decl::FunDecl {
            visibility: crate::Ast::Visibility::Private,
            name: "main",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body,
            is_async: false,
            is_entry: true,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = make_test_module(
            arena,
            vec![crate::Ast::Spanned {
                span: crate::Ast::Span { line: 1, column: 1 },
                node: fun_decl,
            }],
        );
        let mut builder = IrBuilder::new(&sema, &module);
        builder.compile_function("main");
        let has_break = builder
            .graph
            .control_signal_nodes
            .iter()
            .any(|n| *n == Some(SignalKind::Break));
        assert!(has_break);
    }
}
