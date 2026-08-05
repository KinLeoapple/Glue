//! 数据流调度核心：SIMD/rayon 批量化、就绪调度自由函数、run_frame_nodes、process_frame。

use super::*;
use crate::ir::Ir::*;
use crate::ir::Ir::Frame;
use crate::Value::Value;
use crate::ir::Compute::char_from_u32_or_nul;

// =========================================================================
// SIMD/rayon 批量化调度 — 模块级宏 + 自由函数
// =========================================================================

/// 批量提取二元运算输入 → SIMD/rayon 批算 → 写回 value_table。
macro_rules! exec_bin_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $ctor:ident, $acc:ident, $batch_fn:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        let mut b: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
            b.push($frame.get_value_by_global(inp[1]).$acc());
        }
        let mut dst = vec![0 as $rust; n];
        crate::Value::$batch_fn(&mut dst, &a, &b, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::$ctor(dst[i]), cc);
        }
    }};
}

/// 批量提取比较运算输入 → SIMD/rayon 批算 → 写回 value_table（结果为 bool）。
macro_rules! exec_cmp_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $acc:ident, $batch_fn:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        let mut b: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
            b.push($frame.get_value_by_global(inp[1]).$acc());
        }
        let mut mask = vec![0u8; n];
        crate::Value::$batch_fn(&mut mask, &a, &b, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::bool_val(mask[i] != 0), cc);
        }
    }};
}

/// 批量提取一元运算输入 → SIMD/rayon 批算 → 写回 value_table。
macro_rules! exec_unary_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $ctor:ident, $acc:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
        }
        let mut dst = vec![0 as $rust; n];
        crate::Value::batch_unaryop(&mut dst, &a, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::$ctor(dst[i]), cc);
        }
    }};
}

/// 处理一批同质批量化节点（相同 ValueTag + BatchOp），使用 SIMD/rayon 批算。
///
/// 从 value_table 提取输入到连续 typed 数组，调用 Value.rs 的 batch 函数，
/// 写回结果并通知下游。仅适用于 BinOp/UnOp/Cmp 标量运算节点。
fn process_batch_group(
    frame: &mut Frame,
    graph: &DataFlowGraph,
    locals: &[NodeId],
    node_start: NodeId,
    info: BatchInfo,
) -> bool {
    use crate::Value::{ValueTag, BinOp, CmpOp, UnaryOp};
    let _ = (BinOp::Add, CmpOp::Eq, UnaryOp::Neg); // 抑制 unused import

    if locals.is_empty() { return false; }

    match info {
        BatchInfo { tag, op: BatchOp::Bin(op) } => {
            match tag {
                ValueTag::I32 => exec_bin_batch!(frame, graph, locals, node_start, i32, i32, as_i32, batch_binop_i32, op),
                ValueTag::I64 => exec_bin_batch!(frame, graph, locals, node_start, i64, i64, as_i64, batch_binop_i64, op),
                ValueTag::F32 => exec_bin_batch!(frame, graph, locals, node_start, f32, f32, as_f32, batch_binop_f32, op),
                ValueTag::F64 => exec_bin_batch!(frame, graph, locals, node_start, f64, f64, as_f64, batch_binop_f64, op),
                ValueTag::I8 => exec_bin_batch!(frame, graph, locals, node_start, i8, i8, as_i8, batch_binop, op),
                ValueTag::I16 => exec_bin_batch!(frame, graph, locals, node_start, i16, i16, as_i16, batch_binop, op),
                ValueTag::U8 => exec_bin_batch!(frame, graph, locals, node_start, u8, u8, as_u8, batch_binop, op),
                ValueTag::U16 => exec_bin_batch!(frame, graph, locals, node_start, u16, u16, as_u16, batch_binop, op),
                ValueTag::U32 => exec_bin_batch!(frame, graph, locals, node_start, u32, u32, as_u32, batch_binop, op),
                ValueTag::U64 => exec_bin_batch!(frame, graph, locals, node_start, u64, u64, as_u64, batch_binop, op),
                ValueTag::I128 => exec_bin_batch!(frame, graph, locals, node_start, i128, i128, as_i128, batch_binop, op),
                ValueTag::U128 => exec_bin_batch!(frame, graph, locals, node_start, u128, u128, as_u128, batch_binop, op),
                ValueTag::Isize => exec_bin_batch!(frame, graph, locals, node_start, isize, isize_val, as_isize, batch_binop, op),
                ValueTag::Usize => exec_bin_batch!(frame, graph, locals, node_start, usize, usize_val, as_usize, batch_binop, op),
                _ => return false, // F16/F128/Bool/Char → 不支持，回退到单节点路径
            }
        }
        BatchInfo { tag, op: BatchOp::Cmp(op) } => {
            match tag {
                ValueTag::F32 => exec_cmp_batch!(frame, graph, locals, node_start, f32, as_f32, batch_cmp_f32, op),
                ValueTag::F64 => exec_cmp_batch!(frame, graph, locals, node_start, f64, as_f64, batch_cmp_f64, op),
                ValueTag::I32 => exec_cmp_batch!(frame, graph, locals, node_start, i32, as_i32, batch_cmp, op),
                ValueTag::I64 => exec_cmp_batch!(frame, graph, locals, node_start, i64, as_i64, batch_cmp, op),
                ValueTag::I8 => exec_cmp_batch!(frame, graph, locals, node_start, i8, as_i8, batch_cmp, op),
                ValueTag::I16 => exec_cmp_batch!(frame, graph, locals, node_start, i16, as_i16, batch_cmp, op),
                ValueTag::U8 => exec_cmp_batch!(frame, graph, locals, node_start, u8, as_u8, batch_cmp, op),
                ValueTag::U16 => exec_cmp_batch!(frame, graph, locals, node_start, u16, as_u16, batch_cmp, op),
                ValueTag::U32 => exec_cmp_batch!(frame, graph, locals, node_start, u32, as_u32, batch_cmp, op),
                ValueTag::U64 => exec_cmp_batch!(frame, graph, locals, node_start, u64, as_u64, batch_cmp, op),
                ValueTag::I128 => exec_cmp_batch!(frame, graph, locals, node_start, i128, as_i128, batch_cmp, op),
                ValueTag::U128 => exec_cmp_batch!(frame, graph, locals, node_start, u128, as_u128, batch_cmp, op),
                ValueTag::Isize => exec_cmp_batch!(frame, graph, locals, node_start, isize, as_isize, batch_cmp, op),
                ValueTag::Usize => exec_cmp_batch!(frame, graph, locals, node_start, usize, as_usize, batch_cmp, op),
                _ => return false, // F16/F128/Bool/Char → 不支持，回退到单节点路径
            }
        }
        BatchInfo { tag, op: BatchOp::Unary(op) } => {
            match tag {
                ValueTag::I32 => exec_unary_batch!(frame, graph, locals, node_start, i32, i32, as_i32, op),
                ValueTag::I64 => exec_unary_batch!(frame, graph, locals, node_start, i64, i64, as_i64, op),
                ValueTag::I8 => exec_unary_batch!(frame, graph, locals, node_start, i8, i8, as_i8, op),
                ValueTag::I16 => exec_unary_batch!(frame, graph, locals, node_start, i16, i16, as_i16, op),
                ValueTag::U8 => exec_unary_batch!(frame, graph, locals, node_start, u8, u8, as_u8, op),
                ValueTag::U16 => exec_unary_batch!(frame, graph, locals, node_start, u16, u16, as_u16, op),
                ValueTag::U32 => exec_unary_batch!(frame, graph, locals, node_start, u32, u32, as_u32, op),
                ValueTag::U64 => exec_unary_batch!(frame, graph, locals, node_start, u64, u64, as_u64, op),
                ValueTag::I128 => exec_unary_batch!(frame, graph, locals, node_start, i128, i128, as_i128, op),
                ValueTag::U128 => exec_unary_batch!(frame, graph, locals, node_start, u128, u128, as_u128, op),
                ValueTag::Isize => exec_unary_batch!(frame, graph, locals, node_start, isize, isize_val, as_isize, op),
                ValueTag::Usize => exec_unary_batch!(frame, graph, locals, node_start, usize, usize_val, as_usize, op),
                _ => return false, // F16/F128/F32/F64/Bool/Char → 不支持，回退到单节点路径
            }
        }
    }

    // 通知所有批处理节点的下游
    for &lid in locals {
        let gid = NodeId(lid.0 + node_start.0);
        notify_downstream(frame, graph, lid, gid, node_start);
    }
    true
}

/// 尝试批量化处理就绪队列中的节点。
///
/// drain ready_queue → 按 (ValueTag, BatchOp) 分组 → 对 2+ 节点的组
/// 调用 process_batch_group 做 SIMD/rayon 批算 → 非批量化节点推回 ready_queue。
/// 返回 true 表示执行了批处理（调用方应 continue 重新检查新就绪节点）。
fn try_batch_nodes(frame: &mut Frame, graph: &DataFlowGraph) -> bool {
    let qlen = frame.ready_queue.len();
    if qlen < 2 { return false; }

    let node_start = frame.node_offset;
    let wave: Vec<NodeId> = frame.ready_queue.drain(..).collect();

    // 分区：batchable（有 BatchInfo 且未预填充）vs rest
    let mut groups: Vec<(BatchInfo, Vec<NodeId>)> = Vec::new();
    let mut rest: Vec<NodeId> = Vec::new();

    for lid in wave {
        if frame.value_table.ready[lid.0 as usize] {
            rest.push(lid);
            continue;
        }
        let gid = NodeId(lid.0 + node_start);
        let batch_info = graph.batch_infos[gid.0 as usize];
        if let Some(info) = batch_info {
            if let Some(g) = groups.iter_mut().find(|(k, _)| *k == info) {
                g.1.push(lid);
            } else {
                groups.push((info, vec![lid]));
            }
        } else {
            rest.push(lid);
        }
    }

    // 处理 2+ 节点的组
    let mut batch_done = false;
    for (info, locals) in groups {
        if locals.len() >= 2 {
            let processed = process_batch_group(frame, graph, &locals, NodeId(node_start), info);
            if processed {
                batch_done = true;
            } else {
                // 批处理不支持此类型，节点回退到单节点路径
                for lid in locals {
                    rest.push(lid);
                }
            }
        } else {
            rest.push(locals[0]);
        }
    }

    // 非批量化节点推回 ready_queue
    for n in rest {
        frame.push_ready(n);
    }

    batch_done
}

// =========================================================================
// 帧操作辅助函数（纯函数，不依赖 Engine 状态）
// =========================================================================

/// 将 ConstValue 转换为 Value（不使用 arena，直接构造）。
pub(super) fn alloc_const_value(cv: ConstValue) -> Value {
    match cv {
        ConstValue::I8(v) => Value::i8(v),
        ConstValue::I16(v) => Value::i16(v),
        ConstValue::I32(v) => Value::i32(v),
        ConstValue::I64(v) => Value::i64(v),
        ConstValue::I128(v) => Value::i128(v),
        ConstValue::U8(v) => Value::u8(v),
        ConstValue::U16(v) => Value::u16(v),
        ConstValue::U32(v) => Value::u32(v),
        ConstValue::U64(v) => Value::u64(v),
        ConstValue::U128(v) => Value::u128(v),
        ConstValue::Isize(v) => Value::isize_val(v),
        ConstValue::Usize(v) => Value::usize_val(v),
        ConstValue::F32(v) => Value::f32(v),
        ConstValue::F64(v) => Value::f64(v),
        ConstValue::Bool(v) => Value::bool_val(v),
        ConstValue::Char(c) => Value::char_val(char_from_u32_or_nul(c)),
        ConstValue::Null => Value::NULL,
        ConstValue::Void => Value::VOID,
        ConstValue::Str(s) => {
            use crate::Value::{HeapObj, GlueStr};
            Value::ref_val(HeapObj::Str(GlueStr::new(s)))
        }
    }
}

/// 帧节点初始化：设置 node_offset + pending_inputs + 预填充 Const + Gate 入就绪队列。
pub fn prepare_frame_nodes(frame: &mut Frame, graph: &DataFlowGraph) {
    let sg_id = frame.subgraph_id;
    let (node_start, node_end) = graph.subgraphs[sg_id.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;
    let offset = node_start.0 as usize;
    let node_end_global = node_start.0 + node_count as u32;

    // 收集嵌套子图范围
    let nested_ranges: Vec<(u32, u32)> = graph
        .subgraphs
        .iter()
        .filter(|sg| {
            sg.id != sg_id
                && sg.node_range.0 .0 >= node_start.0
                && sg.node_range.1 .0 <= node_end_global
        })
        .map(|sg| (sg.node_range.0 .0, sg.node_range.1 .0))
        .collect();

    let is_nested = |global_idx: u32| -> bool {
        nested_ranges.iter().any(|&(s, e)| global_idx >= s && global_idx < e)
    };

    // 设置 node_offset
    frame.node_offset = node_start.0;

    // 1. 初始化 pending_inputs（select Gate→0；其他节点按实际 in-frame 输入计数）
    for i in 0..node_count {
        if is_nested((offset + i) as u32) {
            frame.pending_inputs[i] = PENDING_EXTERNAL;
        } else {
            let graph_node = &graph.nodes[offset + i];
            if graph_node.kind == NodeKind::EventSource {
                frame.pending_inputs[i] = PENDING_EXTERNAL;
            } else if graph_node.kind == NodeKind::Gate
                && graph.select_infos[offset + i].is_some()
            {
                frame.pending_inputs[i] = 0;
            } else {
                let inputs = graph.inputs_pool.get(
                    graph_node.inputs_offset,
                    graph_node.input_count,
                );
                let in_frame = inputs
                    .iter()
                    .filter(|&&n| (n.0.wrapping_sub(node_start.0) as usize) < node_count)
                    .count() as u8;
                frame.pending_inputs[i] = in_frame;
            }
        }
    }

    // 2. 预填充 Const 节点
    for i in 0..node_count {
        if is_nested((offset + i) as u32) {
            continue;
        }
        let kind = graph.nodes[offset + i].kind;
        if kind == NodeKind::Const {
            if let Some(cv) = graph.const_values[offset + i] {
                let handle = alloc_const_value(cv);
                let local_id = NodeId(i as u32);
                let consumer_count = graph.downstreams[offset + i].len() as u16;
                frame.set_value(local_id, handle, consumer_count);
                frame.push_ready(local_id);
            }
        }
    }

    // 3. 非 Const 节点 with 0 inputs 入就绪队列
    let param_count = graph.subgraphs[sg_id.0 as usize].param_count as usize;
    for i in 0..node_count {
        if i < param_count {
            continue;
        }
        if is_nested((offset + i) as u32) {
            continue;
        }
        let kind = graph.nodes[offset + i].kind;
        if kind == NodeKind::Const {
            continue;
        }
        if frame.pending_inputs[i] == 0 && !frame.value_table.ready[i] {
            frame.push_ready(NodeId(i as u32));
        }
    }
}

/// 通知下游节点：减 pending_inputs，归零则入就绪队列（含边界检查 + 槽级 RC）。
pub fn notify_downstream(
    frame: &mut Frame,
    graph: &DataFlowGraph,
    producer_local: NodeId,
    producer_graph: NodeId,
    node_start: NodeId,
) {
    let downstreams: Vec<NodeId> = graph.downstreams[producer_graph.0 as usize].clone();
    let pending_len = frame.pending_inputs.len();
    for ds_graph_id in downstreams {
        let ds_local_id = NodeId(ds_graph_id.0.wrapping_sub(node_start.0));
        // 边界检查：跳过跨子图下游
        if ds_local_id.0 as usize >= pending_len {
            continue;
        }

        let pidx = producer_local.0 as usize;
        // 消费 producer 的引用计数，但不清除 ready 标记。
        // ready 标记的语义是"此节点已产出值，不需要重新执行"。
        // 清除 ready 会导致节点变成 pending_inputs=0 && ready=false 状态，
        // 当上游被重新触发时，节点会被重新推入 ready_queue 并重复执行，
        // 造成指数级爆炸（尤其影响 call/closure_call 节点）。
        // 值保留在 value_table 中，直到帧结束（帧 drop 时自动释放）
        // 或被 reset_node_ready/reset_node_pending 显式重置（循环体复用场景）。
        let _still_has_consumers = frame.value_table.consume(pidx);

        if frame.pending_inputs[ds_local_id.0 as usize] > 0 {
            frame.pending_inputs[ds_local_id.0 as usize] -= 1;
        }
        if frame.pending_inputs[ds_local_id.0 as usize] == 0
            && !frame.value_table.ready[ds_local_id.0 as usize]
        {
            frame.push_ready(ds_local_id);
        }
    }
}

/// 提取子帧返回值：优先取 control_signal 的 Return 值，否则取 return_node 值。
pub(super) fn extract_child_return(child: &Frame, graph: &DataFlowGraph) -> Value {
    match &child.control_signal {
        ControlSignal::Return(v) => v.clone(),
        ControlSignal::Break | ControlSignal::Continue => Value::VOID,
        ControlSignal::None => {
            let sg = &graph.subgraphs[child.subgraph_id.0 as usize];
            // node_offset = 子图 node_range.0（同函数分支和跨函数调用均如此）
            let return_local = NodeId(sg.return_node.0.wrapping_sub(child.node_offset));
            child.get_value(return_local)
        }
    }
}

// =========================================================================
// impl<S: LockStrategy> Engine<S> — 调度核心方法
// =========================================================================

impl<S: LockStrategy> Engine<S> {
    /// 执行帧内所有就绪节点，直到就绪队列空或帧挂起。
    pub(super) fn run_frame_nodes(&self, frame: &mut Frame, fid: FrameId, queue: &QueueHandle<'_>) {
        let graph = frame.graph.clone();

        let mut iter_guard: u64 = 0;
        loop {
        iter_guard += 1;
        if iter_guard > 500000 {
            return;
        }
            // 检查控制信号（return/break/continue 已触发）
            if !matches!(frame.control_signal, ControlSignal::None) {
                break;
            }
            // 检查帧是否被取消
            if frame.state == FrameState::Cancelling {
                break;
            }
            // 检查帧是否挂起
            if frame.state == FrameState::Suspended {
                return;
            }

            // SIMD/rayon 批量化
            if try_batch_nodes(frame, &graph) {
                continue;
            }

            // 弹出就绪节点（局部 id）
            let local_id = match frame.pop_ready() {
                Some(n) => n,
                None => break,
            };

            let node_start = frame.node_offset;
            let graph_node_id = NodeId(local_id.0 + node_start);
            let node = graph.nodes[graph_node_id.0 as usize];

            // 预填充节点跳过 compute_fn
            let pre_filled = frame.value_table.ready[local_id.0 as usize];
            let value = if pre_filled {
                frame.value_table.values[local_id.0 as usize].clone()
            } else if graph.safe_op_flags[graph_node_id.0 as usize] {
                let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
                if !inputs.is_empty() && matches!(frame.get_value_by_global(inputs[0]), Value::Null) {
                    Value::Null
                } else {
                    let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
                    compute_fn(frame, graph_node_id)
                }
            } else {
                let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
                compute_fn(frame, graph_node_id)
            };

            // vtable 动态分派
            if frame.pending.is_none() {
                if let Some(method_idx) = graph.vtable_call_methods[graph_node_id.0 as usize] {
                    let n = &graph.nodes[graph_node_id.0 as usize];
                    let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                    let recv_val = frame.get_value_by_global(inputs[0]);

                    let (target_sg, upvalues): (crate::ir::Ir::SubGraphId, Vec<Value>) = match recv_val
                        .heap_obj()
                    {
                        Some(crate::Value::HeapObj::TraitVal(tv)) => {
                            let idx = method_idx as usize;
                            match tv.method_values.get(idx).and_then(|v| v.heap_obj()) {
                                Some(crate::Value::HeapObj::Closure(c)) => {
                                    (crate::ir::Ir::SubGraphId(c.func_id), c.upvalues.clone())
                                }
                                _ => panic!("vtable method_idx {} is not a Closure", method_idx),
                            }
                        }
                        _ => panic!("vtable call on non-trait value"),
                    };

                    let arity = (graph.subgraphs[target_sg.0 as usize].param_count as usize)
                        .saturating_sub(upvalues.len());
                    let mut args: Vec<Value> = Vec::with_capacity(arity + upvalues.len());
                    for &in_node in inputs.iter().skip(1).take(arity) {
                        args.push(frame.get_value_by_global(in_node));
                    }
                    args.extend(upvalues);

                    let call_node_local = NodeId(graph_node_id.0.wrapping_sub(frame.node_offset));
                    frame.pending = Some(Pending::Call(PendingCall {
                        target_sg,
                        args,
                        call_node_local,
                        is_async: false,
                        closure_val: None,
                    }));
                }
            }

            // 统一消费 pending
            let pending = frame.pending.take();
            if let Some(pending) = pending {
                match pending {
                    crate::ir::Ir::Pending::Call(pending) => {
                        // 尾调用图跳转
                        let graph_call_id = NodeId(pending.call_node_local.0 + frame.node_offset);
                        if graph.tail_call_flags[graph_call_id.0 as usize] {
                            // 尾调用传播：从 frames 取出 caller 帧并 switch
                            let caller = frame.caller;
                            let propagate_to_parent =
                                if let Some((caller_fid, call_node)) = caller {
                                    let frames = self.frames.lock();
                                    if let Some(caller_frame) = frames.get(&caller_fid) {
                                        let caller_sg_id = caller_frame.subgraph_id;
                                        let caller_loop_kind =
                                            graph.subgraphs[caller_sg_id.0 as usize].loop_kind;
                                        let caller_has_caller = caller_frame.caller.is_some();
                                        let caller_offset = caller_frame.node_offset;
                                        let caller_graph_node =
                                            NodeId(call_node.0 + caller_offset);
                                        let caller_is_gate = graph.nodes[caller_graph_node.0
                                            as usize]
                                            .kind
                                            == NodeKind::Gate;
                                        caller_is_gate
                                            && caller_loop_kind != crate::ir::Ir::LoopKind::LoopBody
                                            && caller_has_caller
                                    } else {
                                        false
                                    }
                                } else {
                                    false
                                };

                            if propagate_to_parent {
                                let (caller_fid, _) = caller.unwrap();
                                let orig_caller = {
                                    let mut frames = self.frames.lock();
                                    frames.remove(&caller_fid).and_then(|cf| cf.caller)
                                };
                                self.event_waiters.lock().retain(|(_, f)| *f != caller_fid);
                                self.pending_completions.lock().remove(&caller_fid);
                                frame.caller = orig_caller;
                                switch_subgraph(
                                    frame,
                                    &graph,
                                    pending.target_sg,
                                    &pending.args,
                                );
                            } else {
                                switch_subgraph(
                                    frame,
                                    &graph,
                                    pending.target_sg,
                                    &pending.args,
                                );
                            }
                            continue;
                        }

                        // LoopBody 帧复用（从 Engine 版本移植）
                        let target_loop_kind =
                            graph.subgraphs[pending.target_sg.0 as usize].loop_kind;
                        let child_fid = if target_loop_kind
                            == crate::ir::Ir::LoopKind::LoopBody
                        {
                            if let Some(bfid) = frame.body_frame_id {
                                // 复用 body_sg 帧：注入参数 + 入就绪队列
                                let target_sg =
                                    &graph.subgraphs[pending.target_sg.0 as usize];
                                let param_count = target_sg.param_count as usize;
                                let mut body_frame = self.frames.lock().remove(&bfid);
                                if let Some(bf) = body_frame.as_mut() {
                                    // 使用 bf.node_offset 计算参数的本地索引：
                                    // 同函数分支帧的 node_offset 是父函数的 node_start，
                                    // 参数在值表中的位置 = branch_start - parent_start + i。
                                    // 跨函数调用时 param_local_offset=0，与原逻辑一致。
                                    let parent_start = bf.node_offset;
                                    let branch_start = target_sg.node_range.0 .0;
                                    let param_local_offset =
                                        (branch_start.wrapping_sub(parent_start)) as usize;
                                    for (i, arg) in
                                        pending.args.iter().enumerate().take(param_count)
                                    {
                                        let local_id =
                                            NodeId((param_local_offset + i) as u32);
                                        let gid = (branch_start as usize) + i;
                                        let consumer_count =
                                            graph.downstreams[gid].len() as u16;
                                        bf.set_value(local_id, arg.clone(), consumer_count);
                                        bf.push_ready(local_id);
                                    }
                                    bf.caller = Some((fid, pending.call_node_local));
                                    bf.parent_frame_ptr = std::ptr::null_mut();
                                    bf.state = FrameState::Ready;
                                }
                                if let Some(bf) = body_frame {
                                    self.frames.lock().insert(bfid, bf);
                                }
                                bfid
                            } else {
                                // 首次创建 body_sg 帧
                                let bfid = self.start_subgraph(
                                    fid,
                                    pending.call_node_local,
                                    pending.target_sg,
                                    &pending.args,
                                    frame,
                                    pending.closure_val.clone(),
                                );
                                frame.body_frame_id = Some(bfid);
                                bfid
                            }
                        } else {
                            // 非 LoopBody：正常 start_subgraph
                            self.start_subgraph(
                                fid,
                                pending.call_node_local,
                                pending.target_sg,
                                &pending.args,
                                frame,
                                pending.closure_val.clone(),
                            )
                        };

                        // 子帧入队
                        queue.push(child_fid);

                        if pending.is_async {
                            // async call：当前帧不挂起，call 节点写 AsyncHandle + 通知下游
                            let async_id = self.async_join_runtime.lock().alloc_id();
                            let async_handle = Value::i32(async_id.0 as i32);
                            self.async_join_runtime.lock().register(async_id, child_fid);

                            let node_start = frame.node_offset;
                            let graph_node_id =
                                NodeId(pending.call_node_local.0 + node_start);
                            let consumer_count =
                                graph.downstreams[graph_node_id.0 as usize].len() as u16;
                            frame.set_value(
                                pending.call_node_local,
                                async_handle,
                                consumer_count,
                            );
                            notify_downstream(
                                frame,
                                &graph,
                                pending.call_node_local,
                                graph_node_id,
                                NodeId(node_start),
                            );
                            continue;
                        } else {
                            // sync call：当前帧挂起等 SubgraphComplete 事件
                            self.event_waiters.lock().push((
                                RuntimeEvent::SubgraphComplete(child_fid),
                                fid,
                            ));
                            frame.state = FrameState::Suspended;
                            frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                            frame.suspend_event =
                                Some(RuntimeEvent::SubgraphComplete(child_fid));
                            return;
                        }
                    }

                    crate::ir::Ir::Pending::ChannelNotify(ch_id) => {
                        self.on_event_arrived(
                            RuntimeEvent::ChannelReady(ch_id),
                            Value::VOID,
                            queue,
                        );
                    }

                    crate::ir::Ir::Pending::Await(pending) => {
                        let (event, ready_value) = self.resolve_and_check_await(&pending);

                        if let Some(value) = ready_value {
                            let node_start = frame.node_offset;
                            let graph_node_id =
                                NodeId(pending.await_node_local.0 + node_start);
                            let consumer_count =
                                graph.downstreams[graph_node_id.0 as usize].len() as u16;
                            frame.set_value(pending.await_node_local, value, consumer_count);
                            notify_downstream(
                                frame,
                                &graph,
                                pending.await_node_local,
                                graph_node_id,
                                NodeId(node_start),
                            );
                            continue;
                        } else {
                            self.event_waiters.lock().push((event, fid));
                            frame.state = FrameState::Suspended;
                            frame.suspend_state =
                                SuspendState::WaitingEvent(pending.await_node_local);
                            frame.suspend_event = Some(event);
                            return;
                        }
                    }

                    crate::ir::Ir::Pending::Cancel(async_id) => {
                        let child_fid = self
                            .async_join_runtime
                            .lock()
                            .find_child_by_async_id(async_id);
                        if let Some(child_fid) = child_fid {
                            self.cancel_frame(child_fid, queue);
                        }
                        let consumer_count =
                            graph.downstreams[graph_node_id.0 as usize].len() as u16;
                        frame.set_value(local_id, Value::VOID, consumer_count);
                        notify_downstream(
                            frame,
                            &graph,
                            local_id,
                            graph_node_id,
                            NodeId(node_start),
                        );
                        continue;
                    }

                    crate::ir::Ir::Pending::SelectWait(gate_local) => {
                        let info = graph.select_infos[graph_node_id.0 as usize].clone();

                        if let Some(info) = info {
                            let mut ready_branch: Option<SubGraphId> = None;
                            for (branch_idx, branch) in info.branches.iter().enumerate() {
                                let event_val =
                                    frame.get_value_by_global(branch.event_source_node);
                                let is_ready = match branch.event_kind {
                                    EventSourceKind::Channel => {
                                        event_val
                                            .heap_obj()
                                            .and_then(|h| h.channel())
                                            .map_or(false, |ch| ch.has_data() || ch.is_closed())
                                    }
                                    EventSourceKind::Timer => {
                                        let timer_id = {
                                            if let Some((_, tid)) = frame
                                                .select_timers
                                                .iter()
                                                .find(|(idx, _)| *idx == branch_idx)
                                            {
                                                *tid
                                            } else {
                                                let duration_ms = event_val.as_i32();
                                                let tid = self.timer_runtime.lock().start(
                                                    std::time::Duration::from_millis(
                                                        duration_ms as u64,
                                                    ),
                                                );
                                                frame.select_timers.push((branch_idx, tid));
                                                tid
                                            }
                                        };
                                        self.timer_runtime.lock().is_fired(timer_id)
                                    }
                                    _ => false,
                                };
                                if is_ready {
                                    ready_branch = Some(branch.subgraph_id);
                                    break;
                                }
                            }

                            if let Some(sg_id) = ready_branch {
                                let child_fid =
                                    self.start_subgraph(fid, gate_local, sg_id, &[], frame, None);
                                queue.push(child_fid);
                                self.event_waiters.lock().push((
                                    RuntimeEvent::SubgraphComplete(child_fid),
                                    fid,
                                ));
                                frame.state = FrameState::Suspended;
                                frame.suspend_state =
                                    SuspendState::WaitingSubgraph(child_fid);
                                frame.suspend_event =
                                    Some(RuntimeEvent::SubgraphComplete(child_fid));
                                return;
                            } else {
                                for (branch_idx, branch) in info.branches.iter().enumerate() {
                                    let event_val = frame
                                        .get_value_by_global(branch.event_source_node);
                                    let event = match branch.event_kind {
                                        EventSourceKind::Channel => {
                                            if let Some(ch) = event_val
                                                .heap_obj()
                                                .and_then(|h| h.channel())
                                            {
                                                RuntimeEvent::ChannelReady(
                                                    crate::ir::Ir::ChannelId(ch.id()),
                                                )
                                            } else {
                                                continue;
                                            }
                                        }
                                        EventSourceKind::Timer => {
                                            let timer_id = frame
                                                .select_timers
                                                .iter()
                                                .find(|(idx, _)| *idx == branch_idx)
                                                .map(|(_, tid)| *tid)
                                                .expect(
                                                    "select timer should be started above",
                                                );
                                            RuntimeEvent::TimerFired(timer_id)
                                        }
                                        _ => continue,
                                    };
                                    self.event_waiters.lock().push((event, fid));
                                }
                                frame.state = FrameState::Suspended;
                                frame.suspend_state =
                                    SuspendState::WaitingEvent(gate_local);
                                frame.suspend_event = None;
                                return;
                            }
                        }
                    }
                }
            }

            // 普通节点：写值表 + 检查控制信号 + 通知下游
            let consumer_count = graph.downstreams[graph_node_id.0 as usize].len() as u16;
            frame.set_value(local_id, value.clone(), consumer_count);

            // 检查控制信号
            let signal_kind = graph.control_signal_nodes[graph_node_id.0 as usize];
            if let Some(kind) = signal_kind {
                frame.control_signal = match kind {
                    SignalKind::Return => ControlSignal::Return(value),
                    SignalKind::Break => ControlSignal::Break,
                    SignalKind::Continue => ControlSignal::Continue,
                };
                break;
            }

            // 通知下游（含槽级 RC）
            notify_downstream(frame, &graph, local_id, graph_node_id, NodeId(node_start));
        }

        // 帧挂起：不执行 defer，不标记 Completed
        if frame.state == FrameState::Suspended {
            return;
        }

        // 帧被取消：执行 defer 清理 + 标记 Failed（spec 5.3）
        if frame.state == FrameState::Cancelling {
            let defer_entries: Vec<DeferEntry> = {
                let sg_id = frame.subgraph_id;
                graph.subgraphs[sg_id.0 as usize].defer_table.clone()
            };
            for entry in defer_entries.iter().rev() {
                let defer_fid = self.init_frame(entry.body_subgraph);
                let mut defer_frame = self.frames.lock().remove(&defer_fid);
                if let Some(df) = defer_frame.as_deref_mut() {
                    self.run_frame_nodes(df, defer_fid, queue);
                }
                if let Some(df) = defer_frame {
                    if df.state != FrameState::Completed {
                        self.frames.lock().insert(defer_fid, df);
                    }
                }
            }
            frame.state = FrameState::Failed;
            return;
        }

        // 执行 defer（LIFO）：任何终止路径都执行 defer
        let defer_entries: Vec<DeferEntry> = {
            let sg_id = frame.subgraph_id;
            graph.subgraphs[sg_id.0 as usize].defer_table.clone()
        };
        for entry in defer_entries.iter().rev() {
            let defer_fid = self.init_frame(entry.body_subgraph);
            let mut defer_frame = self.frames.lock().remove(&defer_fid);
            if let Some(df) = defer_frame.as_deref_mut() {
                self.run_frame_nodes(df, defer_fid, queue);
            }
            if let Some(df) = defer_frame {
                if df.state != FrameState::Completed {
                    self.frames.lock().insert(defer_fid, df);
                }
            }
        }

        // 标记帧完成
        frame.state = FrameState::Completed;
    }

    /// 处理一帧：timer 检查 + run_frame_nodes + 状态转换。
    /// 返回 ()，结果通过 self.result.lock() 传递
    pub(super) fn process_frame(&self, fid: FrameId, queue: &QueueHandle<'_>) {
        // 检查 timer 事件
        self.check_timers(queue);

        // 取出帧（保持 Box 不 unbox：堆地址在 remove/insert 周期中保持稳定，
        // 使其他帧持有的 parent_frame_ptr/root_frame_ptr 不会悬挂）
        let mut frame_box = match self.frames.lock().remove(&fid) {
            Some(b) => b,
            None => return,
        };
        let frame: &mut Frame = &mut *frame_box;

        // 设置帧链指针：从 HashMap 中查找 caller 链，设置 parent_frame_ptr/root_frame_ptr。
        // 此时所有父帧仍在 HashMap 中（Box 地址稳定）。
        self.setup_frame_chain(frame);

        // 执行帧就绪节点（无锁）
        self.run_frame_nodes(frame, fid, queue);

        // 处理帧状态
        let state = frame.state;
        let has_caller = frame.caller.is_some();

        match state {
            FrameState::Suspended => {
                let event = frame.suspend_event;
                // 检查 pending_completions（子帧先完成但父帧尚未 insert 的竞态）
                let pending = self.pending_completions.lock().remove(&fid);
                if let Some((call_node, return_value, child_signal)) = pending {
                    // 有 pending completion：直接消费完成事件
                    if let Some(e) = event {
                        self.event_waiters
                            .lock()
                            .retain(|(we, wf)| !(*we == e && *wf == fid));
                    } else {
                        self.event_waiters
                            .lock()
                            .retain(|(_, wf)| *wf != fid);
                    }
                    let _ = child_signal;
                    // 使用 frame.node_offset 而非 subgraph.node_range.0（同函数分支帧修正）
                    let caller_offset = NodeId(frame.node_offset);
                    let call_graph_id = NodeId(call_node.0 + caller_offset.0);
                    let consumer_count =
                        self.graph.downstreams[call_graph_id.0 as usize].len() as u16;
                    frame.set_value(call_node, return_value, consumer_count);
                    frame.state = FrameState::Ready;
                    frame.suspend_state = SuspendState::NotSuspended;
                    frame.suspend_event = None;
                    notify_downstream(
                        frame,
                        &self.graph,
                        call_node,
                        call_graph_id,
                        caller_offset,
                    );
                    // 放回同一个 Box（地址不变）
                    self.frames.lock().insert(fid, frame_box);
                    queue.push(fid);
                } else {
                    self.frames.lock().insert(fid, frame_box);
                }
            }
            FrameState::Completed => {
                if has_caller {
                    // 区分 sync call vs async call 子帧完成
                    let async_id = self.async_join_runtime.lock().find_by_child(fid);
                    if let Some(async_id) = async_id {
                        // async 子帧完成：设置 result + 触发 AsyncJoin 事件
                        let return_value =
                            extract_child_return(frame, &self.graph);
                        self.async_join_runtime
                            .lock()
                            .set_result(async_id, return_value.clone());
                        // frame_box drop（不放回）
                        self.on_event_arrived(
                            RuntimeEvent::AsyncJoin(async_id),
                            return_value,
                            queue,
                        );
                    } else {
                        // sync 子帧完成：清理 waiter + 回写 + 唤醒调用方
                        self.event_waiters.lock().retain(|(e, _)| {
                            !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                        });
                        // 帧被消费：unbox 传给 complete_and_wake_caller
                        self.complete_and_wake_caller(*frame_box, queue);
                    }
                } else {
                    // 顶层帧完成：返回结果
                    let ret = extract_child_return(frame, &self.graph);
                    *self.result.lock() = Some(ret);
                }
            }
            FrameState::Failed => {
                if has_caller {
                    // Failed 子帧（cancel 后）：清理 waiter + 唤醒调用方
                    self.event_waiters.lock().retain(|(e, _)| {
                        !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                    });
                    self.complete_and_wake_caller(*frame_box, queue);
                } else {
                    // 顶层帧 Failed：返回 NULL
                    *self.result.lock() = Some(Value::NULL);
                }
            }
            _ => {
                // Ready（控制信号触发但未挂起）：放回 + 重新入队
                self.frames.lock().insert(fid, frame_box);
                queue.push(fid);
            }
        }
    }
}
