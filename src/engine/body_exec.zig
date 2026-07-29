//! 函数体 / 循环执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含函数体节点执行（execBodyNodes / execBodyNodesCompact）、
//! 预编译指令执行（compileActiveNodes / execCompiledCompact）、
//! TCO 函数体编译（compileFuncBody）、LICM 循环不变量分析（analyzeLoopInvariants）、
//! 标量循环执行（execScalarLoop），以及编译 body 的缓存与执行入口
//! （getOrCompileBody / execCompiledBody）。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

const Node = ir_mod.Node;
const LoopMeta = ir_mod.meta_mod.LoopMeta;

// 从 engine.zig 引入的 body 编译相关类型（v3 阶段 5.3 已升级为 pub）
const BodyInst = engine_mod.BodyInst;
const CompiledBody = engine_mod.CompiledBody;
const FuncBodyCache = engine_mod.FuncBodyCache;
const LoopActiveCache = engine_mod.LoopActiveCache;
const BodyKind = engine_mod.BodyKind;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 函数体节点执行
    // ════════════════════════════════════════════

    /// 执行子图节点范围（供 vec_map/route_dispatch 等按需调用）
    /// 构建局部 skip 位图，只跳过嵌套子图节点（由对应的 exec 函数按需执行）
    pub fn execBodyNodes(self: *Engine, nodes: []const Node, start: usize, len: usize) EngineError!?u16 {
        if (len == 0) return null;

        // 快速检查：范围内是否包含子图节点（大部分 body 无嵌套子图）
        var has_nested = false;
        for (nodes[start .. start + len]) |n| {
            switch (n.op) {
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while,
                .cleanup_register, .route_dispatch, .scalar_loop, .closure_make => {
                    has_nested = true;
                    break;
                },
                else => {},
            }
        }

        // 无嵌套子图：直接线性执行（热路径，零分配）
        if (!has_nested) {
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const node: *const Node = &nodes[start + i];
                const r = self.execNode(node) catch |err| {
                    return err;
                };
                // 检查 tco_restart：execCall 检测到自递归时设置
                if (self.tco_restart) {
                    return null; // 提前返回，让上层 execFunction 处理 TCO
                }
                if (r) |ret| {
                    return ret;
                }
            }
            return null;
        }

        // 有嵌套子图：构建本地跳过位图
        var stack_skip: [128]bool = undefined;
        var local_skip: []bool = undefined;
        var heap_skip: ?[]bool = null;
        defer if (heap_skip) |hs| self.tctx.?.backing.free(hs);

        if (len <= stack_skip.len) {
            local_skip = stack_skip[0..len];
        } else {
            heap_skip = try self.tctx.?.backing.alloc(bool, len);
            local_skip = heap_skip.?;
        }
        @memset(local_skip, false);

        const node_start = self.ir.functions[self.current_func_idx].node_start;
        const range_start = start;
        const range_end = start + len;
        for (nodes[start .. start + len]) |n| {
            switch (n.op) {
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                    const vm = self.ir.vector_metas[n.meta_index - 1];
                    if (vm.body_len == 0) continue;
                    markNestedRange(local_skip, vm.body_start -| node_start, vm.body_len, range_start, range_end);
                },
                .cleanup_register => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                    const cm = self.ir.cleanup_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    markNestedRange(local_skip, cm.body_start -| node_start, cm.body_len, range_start, range_end);
                },
                .route_dispatch => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                    const rm = self.ir.route_metas[n.meta_index - 1];
                    for (rm.body_starts, rm.body_lens) |bs, bl| {
                        if (bl == 0) continue;
                        markNestedRange(local_skip, bs -| node_start, bl, range_start, range_end);
                    }
                },
                .scalar_loop => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                    const lm = self.ir.loop_metas[n.meta_index - 1];
                    if (lm.body_len == 0) continue;
                    markNestedRange(local_skip, lm.body_start -| node_start, lm.body_len, range_start, range_end);
                },
                .closure_make => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                    const cm = self.ir.closure_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    markNestedRange(local_skip, cm.body_start -| node_start, cm.body_len, range_start, range_end);
                },
                else => {},
            }
        }

        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (local_skip[i]) continue;
            const node: *const Node = &nodes[start + i];
            const r = self.execNode(node) catch |err| {
                return err;
            };
            // 检查 tco_restart：execCall 检测到自递归时设置
            if (self.tco_restart) {
                return null; // 提前返回，让上层 execFunction 处理 TCO
            }
            if (r) |ret| {
                return ret;
            }
        }
        return null;
    }

    /// 标记嵌套子图范围内的节点（辅助函数）
    pub fn markNestedRange(skip: []bool, body_local_start: usize, body_len: u32, range_start: usize, range_end: usize) void {
        const body_local_end = body_local_start + body_len;
        const mark_start = @max(body_local_start, range_start);
        const mark_end = @min(body_local_end, range_end);
        if (mark_start < mark_end) {
            for (mark_start..mark_end) |idx| {
                skip[idx - range_start] = true;
            }
        }
    }

    /// 紧凑描述符执行：仅遍历有效节点索引，零 skip 分支
    /// for 循环比 while 循环生成更紧凑的机器码（无手动索引递增和边界比较）
    pub fn execBodyNodesCompact(self: *Engine, nodes: []const Node, start: usize, active: []const u32) EngineError!?u16 {
        for (active) |local_idx| {
            const node: *const Node = &nodes[start + local_idx];
            if (try self.execNode(node)) |ret| {
                return ret;
            }
        }
        return null;
    }

    /// 预编译有效节点为 BodyInst 数组（直接函数指针调用，无 switch dispatch）
    /// 若任一节点的 op 不在 opToScalarExecFn 中，返回 null（调用方回退到 execBodyNodesCompact）
    pub fn compileActiveNodes(self: *Engine, nodes: []const Node, start: usize, active: []const u32) ?[]BodyInst {
        if (active.len == 0) return null;
        const insts = self.tctx.?.backing.alloc(BodyInst, active.len) catch return null;
        for (active, 0..) |local_idx, i| {
            const node = &nodes[start + local_idx];
            const exec_fn = Engine.opToScalarExecFn(node.op) orelse {
                self.tctx.?.backing.free(insts);
                return null;
            };
            insts[i] = .{ .exec = exec_fn, .node = node };
        }
        return insts;
    }

    /// 执行预编译的指令数组（紧凑直接调用循环，无 execNode switch）
    /// 仅处理不含 halt_return/throw/panic 的 body（break/continue 通过 error 传播）
    pub fn execCompiledCompact(self: *Engine, insts: []const BodyInst) EngineError!void {
        for (insts) |inst| {
            try inst.exec(self, inst.node);
        }
    }

    /// 编译函数体为 FuncBodyCache（TCO 主循环优化）
    /// 当 body_skip 全为 false 时使用 direct 路径（零间接寻址）
    /// 否则使用 compact_idx 路径（紧凑索引数组，消除 body_skip 检查）
    /// 记录 TCO call 节点位置 + 预计算参数复制信息
    pub fn compileFuncBody(
        self: *Engine,
        func_idx: u16,
        nodes: []const Node,
        body_skip: []const bool,
        tco_call_node_idx: ?usize,
        tco_call_meta_idx: u16,
    ) ?FuncBodyCache {
        const backing = self.tctx.?.backing;

        // 统计有效节点数（排除 body_skip）+ 检测是否全有效
        var count: u32 = 0;
        var all_active = true;
        for (0..nodes.len) |i| {
            if (!body_skip[i]) {
                count += 1;
            } else {
                all_active = false;
            }
        }
        if (count == 0) return null;

        // 预计算 TCO 参数复制信息（避免每次迭代的 elemWidth/rawPtr 查找）
        var tco_arg_count: u8 = 0;
        var tco_arg_dst_chans: [16]u16 = [_]u16{0} ** 16;
        var tco_arg_widths: [16]u8 = [_]u8{0} ** 16;
        if (tco_call_node_idx != null and tco_call_meta_idx > 0 and tco_call_meta_idx <= self.ir.call_metas.len) {
            const call_meta = self.ir.call_metas[tco_call_meta_idx - 1];
            const tco_node = &nodes[tco_call_node_idx.?];
            var tco_args_buf: [16]u16 = undefined;
            const tco_args = ir_mod.buildNodeArgs(tco_node, call_meta.extra_args, 0, call_meta.arg_count, &tco_args_buf);
            const arg_count = @min(tco_args.len, 16);
            tco_arg_count = @intCast(arg_count);
            const param_channels = self.ir.functions[func_idx].param_channels;
            for (0..arg_count) |j| {
                if (j < param_channels.len) {
                    tco_arg_dst_chans[j] = param_channels[j];
                    tco_arg_widths[j] = self.runtime.elemWidth(tco_args[j]);
                }
            }
        }

        if (all_active) {
            // Direct 路径：body_skip 全 false，直接遍历 nodes，零间接寻址
            // 不分配 compact_idx，tco_node_idx 直接指向 nodes 中的索引

            // 尝试编译 body [0..tco_node_idx) 为 BodyInst 数组（TCO hot path 优化）
            // 跳过 execNode 的 100+ 分支 switch dispatch
            // 仅当所有 body 节点的 op 都被 opToScalarExecFn 支持时才编译
            var body_insts: []BodyInst = &.{};
            var body_has_call = false;
            if (tco_call_node_idx) |tci| {
                if (tci > 0) {
                    var all_supported = true;
                    for (nodes[0..tci]) |n| {
                        if (Engine.opToScalarExecFn(n.op) == null) {
                            all_supported = false;
                            break;
                        }
                        if (n.op == .call) body_has_call = true;
                    }
                    if (all_supported) {
                        body_insts = backing.alloc(BodyInst, tci) catch &.{};
                        for (0..tci) |i| {
                            body_insts[i] = .{
                                .exec = Engine.opToScalarExecFn(nodes[i].op).?,
                                .node = &nodes[i],
                            };
                        }
                    }
                }
            } else {
                // 无 TCO：编译全函数体为 BodyInst（消除 execNode switch dispatch）
                // 非尾递归函数也受益于直接函数指针调用
                var all_supported = true;
                for (nodes) |n| {
                    if (Engine.opToScalarExecFn(n.op) == null) {
                        all_supported = false;
                        break;
                    }
                    if (n.op == .call) body_has_call = true;
                }
                if (all_supported and nodes.len > 0) {
                    body_insts = backing.alloc(BodyInst, nodes.len) catch &.{};
                    for (nodes, 0..) |n, i| {
                        body_insts[i] = .{
                            .exec = Engine.opToScalarExecFn(n.op).?,
                            .node = &nodes[i],
                        };
                    }
                }
            }

            const result = FuncBodyCache{
                .compact_idx = &.{},
                .tco_node_idx = if (tco_call_node_idx) |tci| @intCast(tci) else null,
                .direct = true,
                .tco_arg_count = tco_arg_count,
                .tco_arg_dst_chans = tco_arg_dst_chans,
                .tco_arg_widths = tco_arg_widths,
                .body_insts = body_insts,
                .body_has_call = body_has_call,
            };
            if (func_idx < self.func_body_cache.len) {
                self.func_body_cache[func_idx] = result;
            }
            return result;
        }

        // Compact 路径：构建紧凑索引数组，排除 body_skip 的节点
        const compact_idx = backing.alloc(u32, count) catch return null;

        var tco_compact_idx: ?u32 = null;
        var idx: u32 = 0;
        for (0..nodes.len) |i| {
            if (body_skip[i]) continue;
            compact_idx[idx] = @intCast(i);

            // 记录 TCO call 节点在紧凑索引中的位置
            if (tco_call_node_idx) |tci| {
                if (i == tci) {
                    tco_compact_idx = idx;
                }
            }
            idx += 1;
        }

        const result = FuncBodyCache{
            .compact_idx = compact_idx,
            .tco_node_idx = tco_compact_idx,
            .direct = false,
            .tco_arg_count = tco_arg_count,
            .tco_arg_dst_chans = tco_arg_dst_chans,
            .tco_arg_widths = tco_arg_widths,
        };

        // 写入缓存
        if (func_idx < self.func_body_cache.len) {
            self.func_body_cache[func_idx] = result;
        }

        return result;
    }

    /// LICM：分析循环不变量，返回不变量节点的本地索引数组（相对 body 子图起始）
    /// 不变量节点 = isScalar() + 所有输入不依赖循环变量
    /// 循环变量 = {iter_chan} ∪ {store 目标} ∪ {非纯计算节点输出}，按拓扑序单遍传播
    pub fn analyzeLoopInvariants(self: *Engine, lm: LoopMeta, nodes: []const Node, body_local_start: usize) ![]u32 {
        const chan_count = self.runtime.chan_count;
        if (chan_count == 0 or lm.body_len == 0) return &.{};

        // 栈缓冲区优化（chan_count 通常 < 256）
        var stack_buf: [256]bool = undefined;
        const use_stack = chan_count <= stack_buf.len;
        const loop_var = if (use_stack) stack_buf[0..chan_count] else try self.tctx.?.backing.alloc(bool, chan_count);
        defer if (!use_stack) self.tctx.?.backing.free(loop_var);
        @memset(loop_var, false);

        // 1. 标记循环变量通道
        if (lm.loop_kind == .for_loop and lm.iter_chan < chan_count) {
            loop_var[lm.iter_chan] = true;
        }
        for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
            if (n.op == .store) {
                if (n.output < chan_count) loop_var[n.output] = true;
            } else if (!ir_mod.op_table.isScalar(n.op)) {
                if (n.output < chan_count) loop_var[n.output] = true;
            }
        }

        // 2. 单遍传播（节点已是拓扑序）
        for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
            if (!ir_mod.op_table.isScalar(n.op)) continue;
            if (n.output >= chan_count or loop_var[n.output]) continue;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    loop_var[n.output] = true;
                    break;
                }
            }
        }

        // 3. 统计不变量节点数
        var count: u32 = 0;
        for (0..lm.body_len) |j| {
            const n = &nodes[body_local_start + j];
            if (!ir_mod.op_table.isScalar(n.op)) continue;
            if (n.output < chan_count and loop_var[n.output]) continue;
            var is_inv = true;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    is_inv = false;
                    break;
                }
            }
            if (is_inv) count += 1;
        }

        if (count == 0) return &.{};

        // 4. 收集不变量节点索引
        const result = try self.tctx.?.backing.alloc(u32, count);
        var idx: u32 = 0;
        for (0..lm.body_len) |j| {
            const n = &nodes[body_local_start + j];
            if (!ir_mod.op_table.isScalar(n.op)) continue;
            if (n.output < chan_count and loop_var[n.output]) continue;
            var is_inv = true;
            for (n.inputs[0..n.input_count]) |in_chan| {
                if (in_chan < chan_count and loop_var[in_chan]) {
                    is_inv = false;
                    break;
                }
            }
            if (is_inv) {
                result[idx] = @intCast(j);
                idx += 1;
            }
        }
        return result;
    }

    pub fn execScalarLoop(self: *Engine, node: *const Node) EngineError!?u16 {
        if (node.meta_index == 0 or node.meta_index > self.ir.loop_metas.len) return error.InvalidMetaIndex;
        const lm = self.ir.loop_metas[node.meta_index - 1];

        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const body_local_start: usize = lm.body_start - func.node_start;

        // 使用缓存的紧凑描述符（IR 不可变，只需计算一次）
        const meta_idx = node.meta_index - 1;
        const lac: LoopActiveCache = blk: {
            if (meta_idx < self.loop_active_cache.len) {
                if (self.loop_active_cache[meta_idx]) |cached| {
                    break :blk cached;
                }
            }
            // 首次调用：构建临时 skip 位图 → 提取紧凑索引 → 释放位图
            const skip = try self.tctx.?.backing.alloc(bool, lm.body_len);
            defer self.tctx.?.backing.free(skip);
            @memset(skip, false);
            for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
                switch (n.op) {
                    .route_dispatch => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                        const rm = self.ir.route_metas[n.meta_index - 1];
                        for (rm.body_starts, rm.body_lens) |bs2, bl| {
                            if (bl == 0) continue;
                            if (bs2 < lm.body_start) continue;
                            const sub_start = bs2 - lm.body_start;
                            const sub_end = sub_start + bl;
                            for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                        }
                    },
                    .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                        const vm = self.ir.vector_metas[n.meta_index - 1];
                        if (vm.body_len == 0) continue;
                        if (vm.body_start < lm.body_start) continue;
                        const sub_start = vm.body_start - lm.body_start;
                        const sub_end = sub_start + vm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .cleanup_register => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                        const cm = self.ir.cleanup_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        if (cm.body_start < lm.body_start) continue;
                        const sub_start = cm.body_start - lm.body_start;
                        const sub_end = sub_start + cm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .scalar_loop => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                        const inner_lm = self.ir.loop_metas[n.meta_index - 1];
                        if (inner_lm.body_len == 0) continue;
                        if (inner_lm.body_start < lm.body_start) continue;
                        const sub_start = inner_lm.body_start - lm.body_start;
                        const sub_end = sub_start + inner_lm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    .closure_make => {
                        if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                        const cm = self.ir.closure_metas[n.meta_index - 1];
                        if (cm.body_len == 0) continue;
                        if (cm.body_start < lm.body_start) continue;
                        const sub_start = cm.body_start - lm.body_start;
                        const sub_end = sub_start + cm.body_len;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| skip[j] = true;
                    },
                    else => {},
                }
            }

            // LICM：分析循环不变量
            const invariant_active = try self.analyzeLoopInvariants(lm, nodes, body_local_start);

            // 构建不变量位图（栈分配，用于快速跳过）
            var inv_set_buf: [128]bool = undefined;
            const use_inv_stack = lm.body_len <= inv_set_buf.len;
            const inv_set = if (use_inv_stack) inv_set_buf[0..lm.body_len] else try self.tctx.?.backing.alloc(bool, lm.body_len);
            defer if (!use_inv_stack) self.tctx.?.backing.free(inv_set);
            @memset(inv_set, false);
            for (invariant_active) |idx| inv_set[idx] = true;

            // 从 skip + inv_set 提取紧凑索引：cond 段 [0, cond_len) + body 段 [cond_len, body_len)
            const cond_len = lm.cond_len;

            // 计数（排除不变量节点）
            var cond_count: u32 = 0;
            var body_count: u32 = 0;
            for (0..cond_len) |j| {
                if (!skip[j] and !inv_set[j]) cond_count += 1;
            }
            for (cond_len..lm.body_len) |j| {
                if (!skip[j] and !inv_set[j]) body_count += 1;
            }

            // 分配并填充（0 长度也分配，保证类型为 []u32 可写）
            const cond_active = try self.tctx.?.backing.alloc(u32, cond_count);
            const body_active = try self.tctx.?.backing.alloc(u32, body_count);
            var ci: u32 = 0;
            var bi: u32 = 0;
            for (0..cond_len) |j| {
                if (!skip[j] and !inv_set[j]) {
                    cond_active[ci] = @intCast(j);
                    ci += 1;
                }
            }
            for (cond_len..lm.body_len) |j| {
                if (!skip[j] and !inv_set[j]) {
                    body_active[bi] = @intCast(j - cond_len);
                    bi += 1;
                }
            }

            // 预编译有效节点为直接调用指令（消除 execNode switch dispatch）
            // 若任一节点 op 不支持直接调用，返回 null，运行时回退到 execBodyNodesCompact
            const body_node_start = body_local_start + cond_len;
            const cond_compiled = self.compileActiveNodes(nodes, body_local_start, cond_active);
            const body_compiled = self.compileActiveNodes(nodes, body_node_start, body_active);
            const inv_compiled = self.compileActiveNodes(nodes, body_local_start, invariant_active);

            const result = LoopActiveCache{
                .cond_active = cond_active,
                .body_active = body_active,
                .invariant_active = invariant_active,
                .cond_compiled = cond_compiled,
                .body_compiled = body_compiled,
                .invariant_compiled = inv_compiled,
            };
            if (meta_idx < self.loop_active_cache.len) {
                self.loop_active_cache[meta_idx] = result;
            }
            break :blk result;
        };

        // LICM：循环前执行一次不变量子图（纯计算节点，输入不依赖循环变量）
        if (lac.invariant_active.len > 0) {
            if (lac.invariant_compiled) |insts| {
                try self.execCompiledCompact(insts);
            } else {
                const inv_result = try self.execBodyNodesCompact(nodes, body_local_start, lac.invariant_active);
                if (inv_result) |halt_chan| return halt_chan;
            }
        }

        switch (lm.loop_kind) {
            .loop => {
                // 无限循环，仅 break 退出
                if (lac.body_compiled) |insts| {
                    while (true) {
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    }
                } else {
                    while (true) {
                        const result = self.execBodyNodesCompact(nodes, body_local_start, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (result) |halt_chan| return halt_chan;
                    }
                }
            },
            .while_loop => {
                // while 循环：每轮先执行条件子图，再检查条件
                const cond_len = lm.cond_len;
                const cond_compiled = lac.cond_compiled;
                const body_compiled = lac.body_compiled;
                while (true) {
                    // 条件段
                    if (cond_compiled) |insts| {
                        try self.execCompiledCompact(insts);
                    } else {
                        const cond_result = try self.execBodyNodesCompact(nodes, body_local_start, lac.cond_active);
                        if (cond_result) |halt_chan| return halt_chan;
                    }
                    const cond_val = try self.readScalarValue(lm.cond_chan);
                    if (!cond_val.asBool()) break;
                    // 循环体段
                    if (body_compiled) |insts| {
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    } else {
                        const body_result = self.execBodyNodesCompact(nodes, body_local_start + cond_len, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (body_result) |halt_chan| return halt_chan;
                    }
                }
            },
            .for_loop => {
                // for 循环：遍历向量元素
                const vec_chan = lm.cond_chan;
                const count = self.runtime.vectorLen(vec_chan);
                const elem_w = self.runtime.elemWidth(vec_chan);
                const base_ptr = self.runtime.chanPtrs(vec_chan).?;

                if (lac.body_compiled) |insts| {
                    for (0..count) |i| {
                        self.runtime.setChanPtr(lm.iter_chan, base_ptr + i * elem_w);
                        self.runtime.setChanLength(lm.iter_chan, 1);
                        self.execCompiledCompact(insts) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                    }
                } else {
                    for (0..count) |i| {
                        self.runtime.setChanPtr(lm.iter_chan, base_ptr + i * elem_w);
                        self.runtime.setChanLength(lm.iter_chan, 1);
                        const result = self.execBodyNodesCompact(nodes, body_local_start, lac.body_active) catch |err| switch (err) {
                            error.LoopBreak => break,
                            error.LoopContinue => continue,
                            else => return err,
                        };
                        if (result) |halt_chan| {
                            self.runtime.setChanPtr(vec_chan, base_ptr);
                            self.runtime.setChanLength(vec_chan, count);
                            return halt_chan;
                        }
                    }
                }

                // 恢复向量通道
                self.runtime.setChanPtr(vec_chan, base_ptr);
                self.runtime.setChanLength(vec_chan, count);
            },
        }

        // 循环结果写入 output（返回迭代次数或 0）
        self.runtime.writeI64(node.output, 0);
        return null;
    }

    // ════════════════════════════════════════════
    // 编译 body 缓存入口
    // ════════════════════════════════════════════

    /// 获取或编译 body
    /// 优先从缓存读取，未命中则编译并缓存
    pub fn getOrCompileBody(self: *Engine, meta_idx: u16) !?*CompiledBody {
        if (meta_idx == 0 or meta_idx > self.ir.vector_metas.len) return null;
        if (meta_idx <= self.body_cache.len) {
            if (self.body_cache[meta_idx - 1]) |*cached| {
                return cached;
            }
        }
        const vm = self.ir.vector_metas[meta_idx - 1];
        if (vm.body_len == 0) return null; // 内联标量模式，无需编译 body
        return try self.compileBody(meta_idx, vm);
    }

    /// 执行编译后的 body（紧凑循环，无 switch dispatch）
    /// 用于 state_machine 模式：pin 元素后直接调用每个指令
    pub fn execCompiledBody(self: *Engine, cb: *const CompiledBody) EngineError!void {
        for (cb.insts) |inst| {
            try inst.exec(self, inst.node);
        }
    }

    /// 编译 body 子图为 CompiledBody
    ///
    /// 分析 body 节点序列的语义类别（BodyKind），生成直接调用指令流。
    /// 首次执行 vec_* 节点时调用，结果缓存到 body_cache。
    ///
    /// 编译规则：
    /// - 全 isScalar() 且无 store → pure_scalar_chain（可 SIMD 线性链）
    /// - 单个可结合二元 op → scan_compatible（走 batchScan SIMD）
    /// - 单个不可结合二元 op → scan_incompatible（紧凑标量循环）
    /// - 含 store 但无控制流 op → state_machine（紧凑循环 + 直接调用）
    /// - 含 gate/route/call_indirect/call → unsupported（回退逐元素）
    pub fn compileBody(self: *Engine, meta_idx: u16, vm: ir_mod.meta_mod.VectorMeta) !*CompiledBody {
        const backing = self.backingAllocator();

        // 获取 body 节点切片
        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_nodes = nodes[body_local_start .. body_local_start + vm.body_len];

        // 1. 语义分析：判定 BodyKind
        var kind: BodyKind = .pure_scalar_chain;
        var has_store = false;
        var scalar_count: u32 = 0;

        for (body_nodes) |n| {
            if (n.op == .store) {
                has_store = true;
                kind = .state_machine;
            } else if (ir_mod.op_table.isScalar(n.op)) {
                scalar_count += 1;
            } else if (n.op == .gate_check or n.op == .gate_get_ok or n.op == .gate_get_err or
                n.op == .gate_propagate or n.op == .gate_select or n.op == .gate_make_ok or n.op == .gate_make_err or
                n.op == .route_get_tag or n.op == .route_dispatch or n.op == .route_merge or
                n.op == .call_indirect or n.op == .call)
            {
                kind = .unsupported;
                break;
            } else {
                kind = .unsupported;
                break;
            }
        }

        // 2. 纯标量链判定：无 store 且全 isScalar()
        if (!has_store and kind == .pure_scalar_chain and scalar_count == body_nodes.len) {
            // 检查是否是单个可结合二元 op（scan_compatible）
            if (body_nodes.len == 1) {
                if (Engine.nodeOpToBatchBinOp(body_nodes[0].op)) |bop| {
                    if (bop == .add or bop == .mul or bop == .band or bop == .bor or bop == .bxor) {
                        kind = .scan_compatible;
                    } else {
                        kind = .scan_incompatible;
                    }
                } else {
                    kind = .pure_scalar_chain;
                }
            }
            // 多节点标量链保持 pure_scalar_chain
        }

        // 3. 生成指令流
        const insts = try backing.alloc(BodyInst, body_nodes.len);
        for (body_nodes, 0..) |*n, i| {
            const exec_fn = Engine.opToScalarExecFn(n.op) orelse {
                // 非标量 op（如 store）：unsupported 已在前面判定，这里不应到达
                // 但 store 在 state_machine 模式下需要直接调用
                if (n.op == .store) {
                    insts[i] = .{ .exec = &Engine.wrapStore, .node = n };
                    continue;
                }
                // 兜底：标记为 unsupported
                kind = .unsupported;
                insts[i] = .{ .exec = &Engine.wrapStore, .node = n }; // 占位，kind=unsupported 不会执行
                continue;
            };
            insts[i] = .{ .exec = exec_fn, .node = n };
        }

        // 4. body 输出通道（最后一条指令的 output）
        const out_chan = if (body_nodes.len > 0) body_nodes[body_nodes.len - 1].output else 0;

        // 5. 写入 body_cache（按值存储，insts 数组由 backing 持有，deinit 时释放）
        const compiled_val = CompiledBody{
            .insts = insts,
            .out_chan = out_chan,
            .kind = kind,
            .node_count = @intCast(body_nodes.len),
        };

        if (meta_idx > 0 and meta_idx <= self.body_cache.len) {
            self.body_cache[meta_idx - 1] = compiled_val;
            return &self.body_cache[meta_idx - 1].?;
        }

        // meta_idx 越界：不应到达，回退到栈上临时存储（调用方本次执行后丢弃）
        // 这种情况仅在 IR 不一致时发生，insts 会泄漏但属于错误路径
        const compiled = try backing.create(CompiledBody);
        compiled.* = compiled_val;
        return compiled;
    }
};
