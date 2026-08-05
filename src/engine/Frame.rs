//! Frame 生命周期管理：分配、初始化、循环迭代重置、帧链指针。

use super::*;
use crate::ir::Ir::*;
use crate::ir::Ir::Frame;

// =========================================================================
// impl<S: LockStrategy> Engine<S> — Frame 管理方法
// =========================================================================

impl<S: LockStrategy> Engine<S> {
    /// 分配帧 id
    pub(super) fn alloc_frame_id(&self) -> FrameId {
        let mut next = self.next_frame_id.lock();
        let id = *next;
        assert!(next.0 < u32::MAX, "FrameId overflow: too many frames allocated");
        next.0 += 1;
        id
    }

    /// 初始化帧：分配 + 预填充。返回 FrameId（帧已插入 frames）。
    pub(super) fn init_frame(&self, subgraph_id: SubGraphId) -> FrameId {
        let (node_start, node_end) = self.graph.subgraphs[subgraph_id.0 as usize].node_range;
        let node_count = (node_end.0 - node_start.0) as usize;
        let fid = self.alloc_frame_id();
        let mut frame = Frame::new(fid, subgraph_id, node_count, self.graph.clone());
        self.prepare_frame(&mut frame);
        self.frames.lock().insert(fid, Box::new(frame));
        fid
    }

    /// 帧节点初始化：重置 + 预填充。
    pub(super) fn prepare_frame(&self, frame: &mut Frame) {
        // 重置帧状态（帧复用时必须重置，避免旧值残留）
        frame.value_table.reset_all();
        frame.ready_queue.clear();
        frame.control_signal = ControlSignal::None;
        frame.pending = None;
        // 以下用 prepare_frame_nodes 设置 node_offset + pending_inputs + Const 预填充
        prepare_frame_nodes(frame, &self.graph);
    }

    /// 循环迭代重置：body_sg 完成后重置循环帧 + 复用 body_sg 帧。
    /// 从 Engine 版本移植，改为 &self + &mut Frame 参数
    pub(super) fn reset_loop_iteration(
        &self,
        loop_frame: &mut Frame,
        loop_fid: FrameId,
        body_frame: &mut Frame,
    ) {
        let loop_sg_id = loop_frame.subgraph_id;
        let (loop_kind, cond_node, return_node, iter_next_node) = {
            let sg = &self.graph.subgraphs[loop_sg_id.0 as usize];
            (sg.loop_kind, sg.cond_node, sg.return_node, sg.iter_next_node)
        };
        // 使用 loop_frame.node_offset 而非 subgraph.node_range.0（同函数分支帧修正）
        let loop_offset = loop_frame.node_offset;

        // 1. For 循环：额外重置 iter_next_node
        if loop_kind == crate::ir::Ir::LoopKind::For {
            if let Some(next_node) = iter_next_node {
                let next_local = NodeId(next_node.0.wrapping_sub(loop_offset));
                Self::reset_node_ready(loop_frame, next_local);
                loop_frame.push_ready(next_local);
            }
        }

        // 2. 重置 cond_node
        if let Some(cond_node) = cond_node {
            let cond_local = NodeId(cond_node.0.wrapping_sub(loop_offset));
            if loop_kind == crate::ir::Ir::LoopKind::For {
                Self::reset_node_pending(loop_frame, cond_local, 1);
            } else {
                Self::reset_node_ready(loop_frame, cond_local);
                // Const cond_node 重新预填充
                if self.graph.nodes[cond_node.0 as usize].kind == crate::ir::Ir::NodeKind::Const {
                    if let Some(cv) = self.graph.const_values[cond_node.0 as usize] {
                        let handle = super::Schedule::alloc_const_value(cv);
                        let consumer_count =
                            self.graph.downstreams[cond_node.0 as usize].len() as u16;
                        loop_frame.set_value(cond_local, handle, consumer_count);
                    }
                }
                loop_frame.push_ready(cond_local);
            }
        }

        // 3. 重置 Gate 节点（pending=1，等 cond notify）
        let gate_local = NodeId(return_node.0.wrapping_sub(loop_offset));
        Self::reset_node_pending(loop_frame, gate_local, 1);

        // 4. 重置 body_sg 帧（复用）
        body_frame.value_table.reset_all();
        body_frame.ready_queue.clear();
        body_frame.control_signal = ControlSignal::None;
        body_frame.pending = None;
        prepare_frame_nodes(body_frame, &self.graph);
        // body_sg 帧重新绑定 caller
        body_frame.caller =
            Some((loop_fid, NodeId(return_node.0.wrapping_sub(loop_offset))));
        // 帧链指针设为 null（HashMap 地址不稳定）
        body_frame.root_frame_ptr = std::ptr::null_mut();
        body_frame.parent_frame_ptr = std::ptr::null_mut();

        // 5. 重置循环帧状态
        loop_frame.control_signal = ControlSignal::None;
        loop_frame.state = FrameState::Ready;
        loop_frame.suspend_state = SuspendState::NotSuspended;
        loop_frame.suspend_event = None;
        loop_frame.pending = None;
    }

    /// 重置节点为就绪状态（pending=0，清值，不入队）。关联函数。
    pub(super) fn reset_node_ready(frame: &mut Frame, node_local: NodeId) {
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = 0;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 重置节点为待定状态（pending=N，清值）。关联函数。
    pub(super) fn reset_node_pending(frame: &mut Frame, node_local: NodeId, pending: u8) {
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = pending;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 设置帧链指针：从 HashMap 中查找 caller 链，设置 parent_frame_ptr/root_frame_ptr。
    ///
    /// 必须在帧从 HashMap remove 后、执行前调用（此时所有父帧仍在 HashMap 中，
    /// Box<Frame> 的堆地址稳定，即使 HashMap rehash 也不会移动）。
    ///
    /// 同函数子图（if-else/match arm/loop body）：parent_frame_ptr 指向直接调用方帧，
    /// root_frame_ptr 指向函数根帧（沿 caller 链向上查找同函数的最远帧）。
    /// 跨函数调用：两个指针均为 null（不允许跨函数访问外层变量）。
    ///
    /// 如果 caller 帧不在 HashMap 中（正在被其他 worker 执行），保持已有指针不变
    /// （start_subgraph 已在创建时设置了初始指针）。
    pub(super) fn setup_frame_chain(&self, frame: &mut Frame) {
        let Some((caller_fid, _)) = frame.caller else {
            return; // 顶层帧，无父帧
        };

        let frames = self.frames.lock();
        let Some(caller_box) = frames.get(&caller_fid) else {
            return; // caller 不在 HashMap 中（正在执行），保持已有指针
        };

        let frame_fn_id = self.graph.subgraphs[frame.subgraph_id.0 as usize].function_id;
        let caller_fn_id =
            self.graph.subgraphs[caller_box.subgraph_id.0 as usize].function_id;

        // 跨函数调用：不设置帧链指针
        if caller_fn_id != frame_fn_id {
            return;
        }

        let caller_ptr = caller_box.as_ref() as *const Frame as *mut Frame;
        frame.parent_frame_ptr = caller_ptr;

        // root_frame_ptr：沿 caller 链向上查找同函数的最远帧
        let mut root_ptr = caller_ptr;
        let mut current_box = caller_box;
        loop {
            match current_box.caller {
                Some((grandparent_fid, _)) => {
                    match frames.get(&grandparent_fid) {
                        Some(gp_box) => {
                            let gp_fn_id =
                                self.graph.subgraphs[gp_box.subgraph_id.0 as usize].function_id;
                            if gp_fn_id != frame_fn_id {
                                break; // 跨函数边界
                            }
                            root_ptr = gp_box.as_ref() as *const Frame as *mut Frame;
                            current_box = gp_box;
                        }
                        None => break, // 祖父帧不在 HashMap 中
                    }
                }
                None => break, // 到达同函数链顶
            }
        }
        frame.root_frame_ptr = root_ptr;
    }
}
