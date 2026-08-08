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

    /// 初始化 defer body 帧：same_function 分支帧设置（Bug #52）。
    ///
    /// defer body 子图编译为 same_function 分支子图（function_id = 父函数），
    /// 但 `init_frame` 用 defer body 自身的 node_range 创建帧，
    /// node_offset 和 value_table 大小不匹配父函数，导致 WriteBack
    /// 计算的 local 索引越界（`writeback target out of current frame range`）。
    ///
    /// 此方法用父帧的 node_offset 和 value_table 大小创建帧，
    /// 复制父帧已就绪的值，再用 `prepare_same_function_frame` 设置 pending_inputs，
    /// 使 defer body 能正确读写父函数的局部变量。
    pub(super) fn init_defer_frame(
        &self,
        body_subgraph: SubGraphId,
        parent_frame: &Frame,
    ) -> FrameId {
        let parent_start = parent_frame.node_offset;
        let parent_node_count = parent_frame.value_table.len();
        let child_sg = &self.graph.subgraphs[body_subgraph.0 as usize];
        let (branch_start, branch_end) = child_sg.node_range;

        let fid = self.alloc_frame_id();
        let mut frame = Frame::new(fid, body_subgraph, parent_node_count, self.graph.clone());
        frame.node_offset = parent_start;

        // 复制父帧已就绪的值（跳过 defer body 范围内的节点）
        for i in 0..parent_node_count {
            let gid = (parent_start as usize + i) as u32;
            let in_child = gid >= branch_start.0 && gid < branch_end.0;
            if in_child {
                continue;
            }
            if parent_frame.value_table.ready[i] {
                frame.value_table.values[i] = parent_frame.value_table.values[i].clone();
                frame.value_table.ready[i] = true;
                frame.value_table.refcounts[i] = 0;
            }
        }

        // 设置 pending_inputs + 预填充 Const + 0-input 节点入队
        self.prepare_same_function_frame(&mut frame);

        // 帧链指针：defer body 通过帧链穿透访问外层变量（Bug #47）
        let parent_ptr = parent_frame as *const Frame as *mut Frame;
        let parent_root = if !parent_frame.root_frame_ptr.is_null() {
            parent_frame.root_frame_ptr
        } else {
            parent_ptr
        };
        frame.parent_frame_ptr = parent_ptr;
        frame.root_frame_ptr = parent_root;

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

        // 0. 清空 ready_queue（必须在步骤 1-3 push cond/iter_next/gate 之前）
        // 若不清空，旧就绪条目残留，会先于 cond/iter_next 执行，引用过时值
        loop_frame.ready_queue.clear();

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
                // While/Loop：递归重置条件依赖树。
                // cond_node 可能是复合表达式（如 `i < 10 && i < 5`），其输入节点
                // （lt1, lt2）在上一轮已求值，若不重置会保持陈旧值，导致 cond_node
                // 读取旧比较结果（条件恒 true → 死循环）。
                self.reset_condition_tree(loop_frame, loop_sg_id, cond_node, loop_offset);
            }
        }

        // 3. 重置 Gate 节点（pending=1，等 cond notify）
        let gate_local = NodeId(return_node.0.wrapping_sub(loop_offset));
        Self::reset_node_pending(loop_frame, gate_local, 1);

        // 4. 重置 body_sg 帧（复用）
        // body 帧是 same_function 分支帧：node_offset = 父函数 node_start，
        // value_table 扩展到父函数大小。不能调用 prepare_frame_nodes（它会将
        // node_offset 重置为 body 子图的 node_range.0，导致值表索引错位，
        // WriteBack 的 target - node_offset 计算出错误 local，跳过 body 帧）。
        body_frame.value_table.reset_all();
        body_frame.ready_queue.clear();
        body_frame.select_timers.clear();
        body_frame.body_frame_id = None;
        body_frame.control_signal = ControlSignal::None;
        body_frame.pending = None;
        self.prepare_same_function_frame(body_frame);

        // 从 loop_frame 重新拷贝外层变量值（与 start_subgraph 逻辑一致）。
        // prepare_same_function_frame 只设置 pending_inputs + 预填充 Const，
        // 不拷贝外层变量。若不拷贝，分支子图（if/else）从 body 帧拷贝时拿不到
        // ready 的 sum1/i1 等外层变量，导致计算节点 pending > 0、WriteBack
        // 永不触发（复现：循环内 if 分支累加只在首轮生效）。
        let body_sg = &self.graph.subgraphs[body_frame.subgraph_id.0 as usize];
        let (body_branch_start, body_branch_end) = body_sg.node_range;
        let copy_count = loop_frame.value_table.len().min(body_frame.value_table.len());
        for i in 0..copy_count {
            let gid = (loop_frame.node_offset as usize + i) as u32;
            let in_body = gid >= body_branch_start.0 && gid < body_branch_end.0;
            if in_body {
                continue;
            }
            if loop_frame.value_table.ready[i] {
                body_frame.value_table.values[i] = loop_frame.value_table.values[i].clone();
                body_frame.value_table.ready[i] = true;
                body_frame.value_table.refcounts[i] = 0;
            }
        }

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

    /// same_function 分支帧重置：保持 node_offset（= 父函数 node_start），
    /// 设置 pending_inputs + 预填充 Const + 0-input 节点入队。
    ///
    /// 与 prepare_frame_nodes 的区别：prepare_frame_nodes 将 node_offset 重置为
    /// 子图自身的 node_range.0，适用于跨函数调用帧。same_function 分支帧的
    /// node_offset 是父函数的 node_start（值表扩展到父函数大小），必须保持不变。
    fn prepare_same_function_frame(&self, frame: &mut Frame) {
        let parent_start = frame.node_offset;
        let parent_node_count = frame.value_table.len();
        let sg_id = frame.subgraph_id;
        let sg = &self.graph.subgraphs[sg_id.0 as usize];
        let branch_start = sg.node_range.0 .0;
        let branch_end = sg.node_range.1 .0;
        let branch_param_count = sg.param_count as usize;

        // 收集分支内嵌套子图范围
        let nested_ranges: Vec<(u32, u32)> = self
            .graph
            .subgraphs
            .iter()
            .filter(|s| {
                s.id != sg_id
                    && s.node_range.0 .0 >= branch_start
                    && s.node_range.1 .0 <= branch_end
            })
            .map(|s| (s.node_range.0 .0, s.node_range.1 .0))
            .collect();
        let is_nested = |gid: u32| nested_ranges.iter().any(|&(s, e)| gid >= s && gid < e);

        // 1. 设置 pending_inputs
        for i in 0..parent_node_count {
            let gid = (parent_start as usize + i) as u32;
            let in_branch = gid >= branch_start && gid < branch_end;
            if !in_branch || is_nested(gid) {
                frame.pending_inputs[i] = PENDING_EXTERNAL;
                continue;
            }
            let node = &self.graph.nodes[gid as usize];
            if node.kind == NodeKind::EventSource {
                frame.pending_inputs[i] = PENDING_EXTERNAL;
            } else if node.kind == NodeKind::Gate
                && self.graph.select_infos[gid as usize].is_some()
            {
                frame.pending_inputs[i] = 0;
            } else {
                let inputs =
                    self.graph
                        .inputs_pool
                        .get(node.inputs_offset, node.input_count);
                let mut pending = 0u16;
                for &inp in inputs {
                    let il = inp.0.wrapping_sub(parent_start) as usize;
                    if il < parent_node_count {
                        let inp_gid = (parent_start as usize + il) as u32;
                        let inp_in_branch = inp_gid >= branch_start && inp_gid < branch_end;
                        // 分支内节点：未就绪则计入 pending
                        // 外层变量（!in_branch）：通过帧链穿透访问，不计 pending
                        if inp_in_branch && !frame.value_table.ready[il] {
                            pending += 1;
                        }
                    }
                    // 帧范围外 → 帧链穿透，不计 pending
                }
                frame.pending_inputs[i] = pending;
            }
        }

        // 2. 预填充分支内 Const 节点
        for i in 0..parent_node_count {
            let gid = (parent_start as usize + i) as u32;
            let in_branch = gid >= branch_start && gid < branch_end;
            if !in_branch || is_nested(gid) {
                continue;
            }
            if self.graph.nodes[gid as usize].kind == NodeKind::Const {
                if let Some(cv) = self.graph.const_values[gid as usize] {
                    let handle = super::Schedule::alloc_const_value(cv);
                    let cc = self.graph.downstreams[gid as usize].len() as u16;
                    frame.set_value(NodeId(i as u32), handle, cc);
                    frame.push_ready(NodeId(i as u32));
                }
            }
        }

        // 3. 分支内 0-input 非 Const 非 Param 节点入队
        for i in 0..parent_node_count {
            let gid = (parent_start as usize + i) as u32;
            let in_branch = gid >= branch_start && gid < branch_end;
            if !in_branch || is_nested(gid) {
                continue;
            }
            let local_in_branch = (gid - branch_start) as usize;
            if local_in_branch < branch_param_count {
                continue;
            }
            if self.graph.nodes[gid as usize].kind == NodeKind::Const {
                continue;
            }
            if frame.pending_inputs[i] == 0 && !frame.value_table.ready[i] {
                frame.push_ready(NodeId(i as u32));
            }
        }
    }

    /// 递归重置条件依赖树（While/Loop 循环迭代重置）。
    ///
    /// `reset_loop_iteration` 只重置顶层 cond_node 时，cond_node 的输入节点
    /// （如 `&&`/`||` 的比较操作数 `lt1`/`lt2`）保持上一轮的陈旧值，导致
    /// cond_node 读取陈旧比较结果（条件恒 true → 死循环）。
    ///
    /// 此方法递归收集 cond_node 依赖树中所有位于循环子图内（排除嵌套子图
    /// body_sg/void_sg 和 Gate 节点）的节点，重置其值并按依赖关系设置
    /// pending_inputs，确保每轮迭代从头重新求值。
    fn reset_condition_tree(
        &self,
        loop_frame: &mut Frame,
        loop_sg_id: SubGraphId,
        cond_node: NodeId,
        loop_offset: u32,
    ) {
        let sg = &self.graph.subgraphs[loop_sg_id.0 as usize];
        let (sg_start, sg_end) = sg.node_range;

        // 收集嵌套子图范围（body_sg, void_sg）
        let nested_ranges: Vec<(u32, u32)> = self
            .graph
            .subgraphs
            .iter()
            .filter(|s| {
                s.id != loop_sg_id
                    && s.node_range.0 .0 >= sg_start.0
                    && s.node_range.1 .0 <= sg_end.0
            })
            .map(|s| (s.node_range.0 .0, s.node_range.1 .0))
            .collect();
        let is_nested = |gid: u32| nested_ranges.iter().any(|&(s, e)| gid >= s && gid < e);
        let is_in_sg = |gid: u32| gid >= sg_start.0 && gid < sg_end.0 && !is_nested(gid);

        // DFS 收集 cond_node 依赖树中所有位于循环子图内的节点（排除 Gate）
        let mut visited: std::collections::HashSet<u32> = std::collections::HashSet::new();
        let mut stack = vec![cond_node];
        let mut cond_nodes: Vec<NodeId> = Vec::new();
        while let Some(gid) = stack.pop() {
            if !visited.insert(gid.0) {
                continue;
            }
            if !is_in_sg(gid.0) {
                continue;
            }
            if self.graph.nodes[gid.0 as usize].kind == NodeKind::Gate {
                continue;
            }
            cond_nodes.push(gid);
            let node = &self.graph.nodes[gid.0 as usize];
            let inputs = self
                .graph
                .inputs_pool
                .get(node.inputs_offset, node.input_count);
            for &inp in inputs {
                stack.push(inp);
            }
        }

        // 阶段 1：重置每个节点的值 + 设置 pending_inputs
        for &gid in &cond_nodes {
            let local = NodeId(gid.0.wrapping_sub(loop_offset));
            let node = &self.graph.nodes[gid.0 as usize];
            let inputs = self
                .graph
                .inputs_pool
                .get(node.inputs_offset, node.input_count);

            // pending = 依赖树内的输入数（这些输入将被重新求值）
            // 外部输入（如循环外变量）通过帧链访问，已就绪，不计 pending
            let pending: u16 = inputs
                .iter()
                .filter(|&&inp| {
                    visited.contains(&inp.0)
                        && is_in_sg(inp.0)
                        && self.graph.nodes[inp.0 as usize].kind != NodeKind::Gate
                })
                .count() as u16;

            Self::reset_node_pending(loop_frame, local, pending);

            // 预填充 Const 节点
            if node.kind == NodeKind::Const {
                if let Some(cv) = self.graph.const_values[gid.0 as usize] {
                    let handle = super::Schedule::alloc_const_value(cv);
                    let consumer_count =
                        self.graph.downstreams[gid.0 as usize].len() as u16;
                    loop_frame.set_value(local, handle, consumer_count);
                }
            }
        }

        // 阶段 2：入队（Const 节点 + 0-pending 非 Const 节点）
        for &gid in &cond_nodes {
            let local = NodeId(gid.0.wrapping_sub(loop_offset));
            let i = local.0 as usize;
            let is_const = self.graph.nodes[gid.0 as usize].kind == NodeKind::Const;
            let pending = if i < loop_frame.pending_inputs.len() {
                loop_frame.pending_inputs[i]
            } else {
                0
            };
            if is_const || pending == 0 {
                loop_frame.push_ready(local);
            }
        }
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
    pub(super) fn reset_node_pending(frame: &mut Frame, node_local: NodeId, pending: u16) {
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
