//! 向量执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execVec* 系列执行函数：vec_select / vec_source / vec_map /
//! vec_map2 / vec_sink / vec_fold / vec_scan / vec_filter / vec_take /
//! vec_take_while / vec_zip，以及对应的 state_machine / scalar_chain /
//! fallback 辅助函数。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;
const CompiledBody = engine_mod.CompiledBody;

const Node = ir_mod.Node;
const ScalarTag = value.scalar.ScalarTag;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 选择（if 表达式，标量模式 N=1）
    // ════════════════════════════════════════════

    /// vec_select：根据条件通道选择 then/else 通道的值
    /// inputs[0] = then_chan, inputs[1] = else_chan, inputs[2] = cond_chan
    pub fn execVecSelect(self: *Engine, node: *const Node) EngineError!void {
        const then_chan = node.inputs[0];
        const else_chan = node.inputs[1];
        const cond_chan = node.inputs[2];
        const cond_val = try self.readScalarValue(cond_chan);
        const src_chan = if (cond_val.asBool()) then_chan else else_chan;
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            // 源通道可能为 null_chan（无数据指针），跳过拷贝
            if (src_chan < self.runtime.chan_count) {
                if (self.runtime.chanPtrs(src_chan)) |src_ptr| {
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
    // 向量生成与变换
    // ════════════════════════════════════════════

    /// vec_source：生成向量数据
    /// inputs[0]=start, inputs[1]=end (range) 或 inputs[0]=array_ref (array_source)
    pub fn execVecSource(self: *Engine, node: *const Node) EngineError!void {
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
                const desc = vm.elem_type_desc;
                const ops = desc.ops;
                for (0..count) |i| {
                    const val = start + @as(i64, @intCast(i));
                    const elem_ptr = self.runtime.vectorElemPtr(node.output, i);
                    // val 超出窄类型范围时由 coerce 自动 clamp（截断到目标类型范围）
                    // 走 vtable coerce + write，零运行时 switch
                    const coerced = ops.coerce(value.Value.fromI64(val));
                    ops.write(elem_ptr, coerced);
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
                    self.valueToRawPtr(elem_ptr, w, arr.elements[i]);
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

    /// vec_map：对向量每个元素应用变换
    /// 子图模式：body_start..body_start+body_len 引用主节点流中的子图
    /// 内联标量模式：body_len=0，identity（直接拷贝）
    pub fn execVecMap(self: *Engine, node: *const Node) EngineError!void {
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

            if (Engine.chanToScalarTag(out_meta)) |tag| {
                // 情况 1：body_len == 1，单节点一元运算（-x / ~x / abs(x)）
                if (vm.body_len == 1) {
                    const body_node = nodes[body_local_start];
                    if (Engine.nodeOpToBatchUnaryOp(body_node.op)) |uop| {
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
                        if (Engine.nodeOpToBatchBinOp(op_node.op)) |bop| {
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

        // base_ptr 不能在循环外缓存：body 执行可能触发 scalar_area rebase，
        // 导致 chan_slots[src_chan].ptr 更新到新地址，而缓存的 base_ptr 指向已释放的旧内存。
        // 通过追踪前一次 setChanPtr 的偏移量，每次迭代从当前 chanPtrs 重新推导 base。
        var prev_offset: usize = 0;
        for (0..count) |i| {
            // 从当前通道指针推导 base（rebase 后指针已更新，偏移量保持不变）
            const base = self.runtime.chanPtrs(src_chan).? - prev_offset;
            const offset = i * elem_w;
            self.runtime.setChanPtr(src_chan, base + offset);
            self.runtime.setChanLength(src_chan, 1);
            prev_offset = offset;

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            // 读取 body 结果到输出向量（body_out_w=0 表示 unit 通道，仅副作用，跳过拷贝）
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }

        // 恢复循环变量通道为向量模式（从当前指针推导 base，处理可能的 rebase）
        const final_base = self.runtime.chanPtrs(src_chan).? - prev_offset;
        self.runtime.setChanPtr(src_chan, final_base);
        self.runtime.setChanLength(src_chan, count);
    }

    /// O(1) dispatch：状态机紧凑循环（state_machine）
    ///
    /// body 含 store 但无控制流 op 时，每个元素 pin 后直接调用 inst.exec
    /// 绕过 execNode 的 switch，dispatch 只发生在进入 vec_map 时 1 次
    /// 适用于：累加器（acc = acc + f(i)）、状态机迭代（var = f(var, x)）
    pub fn execVecMapStateMachine(
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

        // base_ptr 不能在循环外缓存：body 执行可能触发 scalar_area rebase
        var prev_offset: usize = 0;
        for (0..count) |i| {
            const base = self.runtime.chanPtrs(src_chan).? - prev_offset;
            const offset = i * elem_w;
            self.runtime.setChanPtr(src_chan, base + offset);
            self.runtime.setChanLength(src_chan, 1);
            prev_offset = offset;

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
        const final_base = self.runtime.chanPtrs(src_chan).? - prev_offset;
        self.runtime.setChanPtr(src_chan, final_base);
        self.runtime.setChanLength(src_chan, count);
    }

    /// O(1) dispatch：SIMD 线性链执行（pure_scalar_chain）
    ///
    /// body 全是 isScalar() 节点时，按拓扑序串联调用 dispatchBatch*
    /// 每个 body 节点的 output 通道分配为向量缓冲，中间结果直接写入
    /// 无 execNode 的 switch dispatch，无逐元素循环
    pub fn execVecMapScalarChain(
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
            const tag = Engine.chanToScalarTag(out_meta) orelse {
                // 非 SIMD 类型，回退逐元素
                return self.execVecMapFallback(node, vm, src_chan, count);
            };

            // 一元 op
            if (Engine.nodeOpToBatchUnaryOp(bn.op)) |uop| {
                if (bn.input_count >= 1) {
                    try self.dispatchBatchMapUnary(tag, uop, bn.output, bn.inputs[0], count);
                    continue;
                }
            }

            // 二元 op：左向量 + 右向量
            if (Engine.nodeOpToBatchBinOp(bn.op)) |bop| {
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

    /// vec_map 逐元素回退路径（当 SIMD 链不适用时）
    pub fn execVecMapFallback(
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

        // base_ptr 不能在循环外缓存：body 执行可能触发 scalar_area rebase，
        // 导致 chan_slots[src_chan].ptr 更新到新地址，而缓存的 base_ptr 指向已释放的旧内存。
        // 通过追踪前一次 setChanPtr 的偏移量，每次迭代从当前 chanPtrs 重新推导 base。
        var prev_offset: usize = 0;
        for (0..count) |i| {
            const base = self.runtime.chanPtrs(src_chan).? - prev_offset;
            const offset = i * elem_w;
            self.runtime.setChanPtr(src_chan, base + offset);
            self.runtime.setChanLength(src_chan, 1);
            prev_offset = offset;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        // 恢复循环变量通道为向量模式（从当前指针推导 base，处理可能的 rebase）
        const final_base = self.runtime.chanPtrs(src_chan).? - prev_offset;
        self.runtime.setChanPtr(src_chan, final_base);
        self.runtime.setChanLength(src_chan, count);
    }

    /// vec_map2：双输入向量的逐元素二元运算
    pub fn execVecMap2(self: *Engine, node: *const Node) EngineError!void {
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

            if (Engine.chanToScalarTag(out_meta)) |tag| {
                // 情况 1：body_len == 1，单节点二元运算（left[i] op right[i]）
                if (vm.body_len == 1) {
                    const body_node = nodes[body_local_start];
                    if (Engine.nodeOpToBatchBinOp(body_node.op)) |bop| {
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
        const left_base = self.runtime.chanPtrs(left_chan).?;
        const right_base = self.runtime.chanPtrs(right_chan).?;

        for (0..count) |i| {
            self.runtime.setChanPtr(left_chan, left_base + i * lw);
            self.runtime.setChanLength(left_chan, 1);
            self.runtime.setChanPtr(right_chan, right_base + i * rw);
            self.runtime.setChanLength(right_chan, 1);

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            const w = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..w], src[0..w]);
        }

        // 恢复
        self.runtime.setChanPtr(left_chan, left_base);
        self.runtime.setChanLength(left_chan, count);
        self.runtime.setChanPtr(right_chan, right_base);
        self.runtime.setChanLength(right_chan, count);
    }

    /// O(1) dispatch：vec_map2 SIMD 线性链（pure_scalar_chain）
    pub fn execVecMap2ScalarChain(
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
            const tag = Engine.chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

            if (Engine.nodeOpToBatchUnaryOp(bn.op)) |uop| {
                if (bn.input_count >= 1) {
                    try self.dispatchBatchMapUnary(tag, uop, bn.output, bn.inputs[0], count);
                    continue;
                }
            }
            if (Engine.nodeOpToBatchBinOp(bn.op)) |bop| {
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
    pub fn execVecMap2StateMachine(
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
        const left_base = self.runtime.chanPtrs(left_chan).?;
        const right_base = self.runtime.chanPtrs(right_chan).?;

        for (0..count) |i| {
            self.runtime.setChanPtr(left_chan, left_base + i * lw);
            self.runtime.setChanLength(left_chan, 1);
            self.runtime.setChanPtr(right_chan, right_base + i * rw);
            self.runtime.setChanLength(right_chan, 1);

            try self.execCompiledBody(cb);

            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }

        self.runtime.setChanPtr(left_chan, left_base);
        self.runtime.setChanLength(left_chan, count);
        self.runtime.setChanPtr(right_chan, right_base);
        self.runtime.setChanLength(right_chan, count);
    }

    /// vec_sink：从向量中提取标量值
    pub fn execVecSink(self: *Engine, node: *const Node) EngineError!void {
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
                _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(v.asRef())));
            },
            else => return error.InvalidMetaIndex,
        }
    }

    /// vec_fold：归约（sum/max/min 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    pub fn execVecFold(self: *Engine, node: *const Node) EngineError!void {
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
            const tag = Engine.chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            const init_acc = self.readChanBytes(node.output); // 累加器初值（已从 init_chan 拷入）
            if (Engine.nodeOpToBatchBinOp(vm.inner_op)) |bop| {
                const result = try self.dispatchBatchReduce(tag, bop, init_acc, src_chan, count);
                self.writeChanBytes(node.output, result);
            } else {
                // 回退：不可 SIMD 化的 inner_op，逐元素 dispatch
                var acc = init_acc;
                for (0..count) |i| {
                    var elem_buf: [16]u8 = [_]u8{0} ** 16;
                    const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                    if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                    acc = try Engine.dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;

        // fold 的 body：inputs[0] = 累加器（output 通道），inputs[1] = 当前元素
        // 循环变量通道是 src_chan，累加器是 node.output
        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            // body 的结果在 body_out_chan，复制到 output 作为新的累加器
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复 src_chan
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);
    }

    /// O(1) dispatch：vec_fold 紧凑循环（state_machine / scan_incompatible）
    pub fn execVecFoldStateMachine(
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;

        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
            try self.execCompiledBody(cb);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);
    }

    /// vec_scan：前缀扫描（prefix sum 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    pub fn execVecScan(self: *Engine, node: *const Node) EngineError!void {
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
            const tag = Engine.chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            const init_bytes = self.readChanBytes(init_chan); // 累加器初值
            if (Engine.nodeOpToBatchBinOp(vm.inner_op)) |bop| {
                try self.dispatchBatchScan(tag, bop, init_bytes, node.output, src_chan, count);
            } else {
                // 回退：不可 SIMD 化的 inner_op，逐元素 dispatch
                var acc = init_bytes;
                for (0..count) |i| {
                    var elem_buf: [16]u8 = [_]u8{0} ** 16;
                    const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                    if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                    acc = try Engine.dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;

        // 简化实现：逐元素扫描
        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);
    }

    /// O(1) dispatch：vec_scan 紧凑循环
    pub fn execVecScanStateMachine(
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;

        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
            try self.execCompiledBody(cb);
            if (body_out_w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.vectorElemPtr(node.output, i);
                @memcpy(dst[0..body_out_w], src[0..body_out_w]);
            }
        }
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);
    }

    /// vec_filter：按条件过滤元素
    pub fn execVecFilter(self: *Engine, node: *const Node) EngineError!void {
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;

        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
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
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);

        // 分配输出向量并拷贝
        try self.runtime.allocVector(node.output, kept);
        if (kept > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * kept], temp[0 .. w * kept]);
        }

        // 恢复 chan_lengths（chan_ptrs 已在 allocVector 中 rebase）
        self.runtime.setChanLength(src_chan, count);
    }

    /// vec_take：取前 N 个元素
    pub fn execVecTake(self: *Engine, node: *const Node) EngineError!void {
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
    pub fn execVecTakeWhile(self: *Engine, node: *const Node) EngineError!void {
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
        const base_ptr = self.runtime.chanPtrs(src_chan).?;
        var taken: u32 = 0;
        for (0..count) |i| {
            self.runtime.setChanPtr(src_chan, base_ptr + i * elem_w);
            self.runtime.setChanLength(src_chan, 1);
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
        self.runtime.setChanPtr(src_chan, base_ptr);
        self.runtime.setChanLength(src_chan, count);

        try self.runtime.allocVector(node.output, taken);
        if (taken > 0) {
            // allocVector 可能触发 ChannelRegion 扩容，chan_ptrs[src_chan] 已被 rebase
            const base_ptr_new = self.runtime.chanPtrs(src_chan).?;
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * taken], base_ptr_new[0 .. w * taken]);
        }

        // 恢复 chan_lengths（chan_ptrs 已在 allocVector 中 rebase）
        self.runtime.setChanLength(src_chan, count);
    }

    /// vec_zip：合并两个向量为 Pair(first, second) 记录向量
    /// inputs[0] = 左向量，inputs[1] = 右向量
    /// output = 引用通道向量，每个元素是指向 Pair 记录的指针
    pub fn execVecZip(self: *Engine, node: *const Node) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const count = @min(self.runtime.vectorLen(left_chan), self.runtime.vectorLen(right_chan));

        // 输出通道必须是引用通道，每个元素存 Pair 记录指针
        if (!self.runtime.isRef(node.output)) return error.InvalidChannel;

        try self.runtime.allocVector(node.output, count);
        if (count == 0) return;

        const base_left = self.runtime.chanPtrs(left_chan).?;
        const base_right = self.runtime.chanPtrs(right_chan).?;
        const elem_w_left = self.runtime.elemWidth(left_chan);
        const elem_w_right = self.runtime.elemWidth(right_chan);
        const saved_left_len = self.runtime.chanLengths(left_chan);
        const saved_right_len = self.runtime.chanLengths(right_chan);

        const field_names: [2]?[]const u8 = .{ "first", "second" };
        const dst = self.runtime.rawPtr(node.output);
        const out_w = self.runtime.elemWidth(node.output);

        for (0..count) |i| {
            self.runtime.setChanPtr(left_chan, base_left + i * elem_w_left);
            self.runtime.setChanLength(left_chan, 1);
            self.runtime.setChanPtr(right_chan, base_right + i * elem_w_right);
            self.runtime.setChanLength(right_chan, 1);

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
        self.runtime.setChanPtr(left_chan, base_left);
        self.runtime.setChanLength(left_chan, saved_left_len);
        self.runtime.setChanPtr(right_chan, base_right);
        self.runtime.setChanLength(right_chan, saved_right_len);
    }

    /// 标量 broadcast 到向量
    pub fn broadcastScalarToVector(self: *Engine, chan: u16, scalar_bytes: [16]u8, count: u32) !void {
        const w = self.runtime.elemWidth(chan);
        if (w == 0 or count == 0) return;
        try self.runtime.allocVector(chan, count);
        const dst = self.runtime.rawPtr(chan);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            @memcpy(dst[i * w .. (i + 1) * w], scalar_bytes[0..w]);
        }
    }
};
