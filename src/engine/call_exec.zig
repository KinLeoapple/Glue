//! 函数调用执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execCall / execCallStandard / execCallIndirect 等函数调用分派与执行函数，
//! 以及调用辅助函数 copyArgToParam / copyArgsToParams / copyClosureUpvalues /
//! saveCallResult / writeCallResult / hashArgs。
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
const Function = ir_mod.Function;

const SavedResult = engine_mod.SavedResult;
const MAX_CALL_DEPTH = engine_mod.MAX_CALL_DEPTH;
const MemoKey = Engine.MemoKey;
const MemoEntry = Engine.MemoEntry;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 函数调用执行
    // ════════════════════════════════════════════

    pub fn execCall(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        // Profiling: function call/ret 事件（精确重建 per-function 统计）
        // 保存/恢复 caller 的 current_func_idx，确保 callee 返回后的分配归因到 caller
        // 注意：defer 必须在函数作用域，不能在 if 块内——
        //   Zig 的 defer 在所在 block 结束时执行，若放在 if 块内，
        //   current_func_idx 会在进入 callee body 前就恢复为 caller，导致 per-function 归因全部错位
        const prof_opt = self.tctx.?.prof;
        var saved_func: u32 = 0;
        if (prof_opt) |p| {
            p.onFuncCall(call_meta.func_index);
            saved_func = p.current_func_idx.load(.acquire);
            p.setCurrentFunc(call_meta.func_index);
        }
        defer if (prof_opt) |p| {
            p.setCurrentFunc(saved_func);
            p.onFuncRet(call_meta.func_index);
        };

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        const callee_func = self.ir.functions[call_meta.func_index];
        const args = node.inputs[0..call_meta.arg_count];

        // Memoization 快速路径：递归纯函数 + 标量/nullable<标量> 参数 + 非尾调用
        // 命中则直接复制结果，跳过整个函数执行（O(1) 替代 O(递归深度)）
        // 尾调用跳过 memo（TCO 已优化，且 tco_restart 路径无标准结果写入）
        // ref_chan 参数/返回不启用 memoization（指针哈希命中率低，deepCopy 开销巨大）
        if (call_meta.memo_slot > 0 and !call_meta.tail_call) {
            const arg_hash = self.hashArgs(args);
            const key = MemoKey{ .slot = call_meta.memo_slot, .arg_hash = arg_hash };
            if (self.memo_cache.get(key)) |entry| {
                // 缓存命中：复制结果字节到输出通道
                if (entry.width > 0) {
                    const dst = self.runtime.rawPtr(node.output);
                    @memcpy(dst[0..entry.width], entry.bytes[0..entry.width]);
                }
                if (self.tctx.?.prof) |prof| prof.recordMemo(true);
                return;
            }
            if (self.tctx.?.prof) |prof| prof.recordMemo(false);
            // 未命中：执行函数，结束后缓存结果
            const memo_key = key;

            // 执行标准调用路径
            try self.execCallStandard(node, call_meta, callee_func, args);

            // 缓存结果：直接缓存字节（标量和 nullable<标量> 都用字节路径）
            const result_w = self.runtime.elemWidth(node.output);
            if (result_w > 0 and result_w <= 16) {
                var entry: MemoEntry = .{ .width = result_w };
                const src = self.runtime.rawPtr(node.output);
                @memcpy(entry.bytes[0..result_w], src[0..result_w]);
                // 使用 backing allocator（Engine 生命周期）
                const backing = if (self.tctx) |tc| tc.backing else self.ir.backing;
                self.memo_cache.put(backing, memo_key, entry) catch {};
            }
            return;
        }

        // 标准调用路径（TCO + 递归 save/restore + 非递归直通）
        try self.execCallStandard(node, call_meta, callee_func, args);
    }

    /// 复制单个实参到目标形参通道，自动处理 Lazy<T> 强制求值。
    /// 当实参是 ref_chan（Lazy<T>）而形参通道是标量时，通过 readScalarValue 观察并求值。
    /// 形参也是引用类型时保留引用本身（避免错误强制）。
    /// is_ref 为 true 表示实参类型为 &T / *T，应保持引用语义；否则普通复合类型走深拷贝。
    pub fn copyArgToParam(self: *Engine, arg_chan: u16, dst_chan: u16, is_ref: bool) EngineError!void {
        const src_is_ref = self.runtime.isRef(arg_chan);
        const dst_is_ref = self.runtime.isRef(dst_chan);
        const src_is_nullable = self.runtime.isNullable(arg_chan);
        const dst_is_nullable = self.runtime.isNullable(dst_chan);
        if (src_is_ref and dst_is_ref) {
            _ = self.runtime.readPtr(arg_chan);
        }

        // ref_chan → 标量通道：可能是 Lazy<T> 强制求值或标量值解码
        if (src_is_ref and !dst_is_ref and !dst_is_nullable) {
            // 先尝试作为堆对象读取（处理 Lazy<T> 强制求值）
            if (self.readRefObj(arg_chan)) |_| {
                const v = try self.readScalarValue(arg_chan);
                self.writeScalarValue(dst_chan, v);
                return;
            }
            // readRefObj 失败：ref_chan 持有标量位模式，按目标类型解码
            try self.copyCrossType(dst_chan, arg_chan);
            return;
        }

        // 标量通道 → ref_chan：标量值扩展为 8 字节写入（类型参数实例化为标量时）
        if (!src_is_ref and !src_is_nullable and dst_is_ref) {
            try self.copyCrossType(dst_chan, arg_chan);
            return;
        }

        try self.cloneValueBetweenChannels(dst_chan, arg_chan, is_ref);
    }

    /// 按引用位图将实参复制到形参通道（统一值语义深拷贝判定）。
    /// 取 args.len 与形参数量的较小值，逐个按 arg_ref_bits 判定引用语义。
    pub fn copyArgsToParams(self: *Engine, args: []const u16, callee_func: Function, arg_ref_bits: u16) EngineError!void {
        const count = @min(args.len, callee_func.param_channels.len);
        for (0..count) |i| {
            const dst_chan = callee_func.param_channels[i];
            const is_ref = ((arg_ref_bits >> @intCast(i)) & 1) != 0;
            try self.copyArgToParam(args[i], dst_chan, is_ref);
        }
    }

    /// 将闭包 upvalues 复制到 explicit_count 之后的形参通道。
    pub fn copyClosureUpvalues(self: *Engine, callee_func: Function, closure: *value.Closure, explicit_count: usize) void {
        const total_params = callee_func.param_channels.len;
        const upvalue_count = @min(closure.upvalues.len, if (total_params > explicit_count) total_params - explicit_count else 0);
        for (0..upvalue_count) |i| {
            const dst_chan = callee_func.param_channels[explicit_count + i];
            self.writeScalarValue(dst_chan, closure.upvalues[i]);
        }
    }

    /// 暂存调用结果（在 leaveFunction 之前调用）。
    /// ret_is_ref=true 或非 ref_chan 时直接字节拷贝；普通复合类型 ref_chan 深拷贝。
    pub fn saveCallResult(self: *Engine, result_chan: u16, ret_is_ref: bool) EngineError!SavedResult {
        const w = self.runtime.elemWidth(result_chan);
        if (w == 0) return .none;
        if (!ret_is_ref and self.runtime.isRef(result_chan)) {
            const v = self.chanToValue(result_chan);
            const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
            try self.trackValueTree(copied);
            return .{ .value = copied };
        }
        var buf: [16]u8 = undefined;
        const src = self.runtime.rawPtr(result_chan);
        @memcpy(buf[0..w], src[0..w]);
        return .{ .bytes = .{ .buf = buf, .w = @intCast(w) } };
    }

    /// 将暂存结果写入输出通道（在 leaveFunction 之后调用）。
    pub fn writeCallResult(self: *Engine, out_chan: u16, saved: SavedResult) EngineError!void {
        switch (saved) {
            .none => {},
            .bytes => |b| {
                const dst = self.runtime.rawPtr(out_chan);
                @memcpy(dst[0..b.w], b.buf[0..b.w]);
            },
            .value => |v| self.valueToChan(out_chan, v),
        }
    }

    /// 标准调用路径：从 execCall 抽出，供 memoization 快速路径未命中时调用
    /// 双 Region 架构：所有调用统一走 enterFunction/leaveFunction，
    /// Runtime 内部管理 chan_ptrs 的保存/恢复和 scalar_area 的 bump/resetTo。
    /// 自递归尾调用优化（TCO）复用当前帧，跳过 enterFunction/leaveFunction。
    pub fn execCallStandard(self: *Engine, node: *const Node, call_meta: ir_mod.CallMeta, callee_func: Function, args: []const u16) EngineError!void {
        // 自递归尾调用优化：当 callee == current_func_idx 且 call_meta.tail_call == true 时，
        // 设置 tco_restart 信号，让 execFunction 用新参数重新执行
        // 复用当前帧（同一函数的通道索引相同），无需 enterFunction/leaveFunction
        if (call_meta.func_index == self.current_func_idx and args.len <= 16 and call_meta.tail_call) {
            self.tco_arg_count = @intCast(args.len);
            @memcpy(self.tco_args[0..args.len], args);
            self.tco_caller_func_idx = self.current_func_idx;
            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
            self.tco_restart = true;
            return;
        }

        // 标准调用路径：enterFunction → copyArgsToParams → execFunction → saveResult → leaveFunction → writeResult
        //
        // SCC 问题（自递归）：callee == caller 时，通道索引重叠。
        // enterFunction 覆盖 callee local 范围的 chan_ptrs（指向 callee 新内存），
        // 导致实参通道（与 callee local 重叠）的值不可读。
        // 修复：自递归调用在 enterFunction 前保存实参值（含深拷贝），
        //   enterFunction 后直接写入 callee 的形参通道。
        // 非自递归调用：enterFunction 不触碰实参通道，直接 copyArgsToParams。
        //
        // 结果处理：leaveFunction 前用 saveCallResult 暂存到栈上，
        //   leaveFunction 后（chan_ptrs 已恢复为 caller）用 writeCallResult 写入。
        //   消除 SCC 场景下 node.output chan_ptrs 指向 callee 内存的问题。

        const is_self_recursive = (call_meta.func_index == self.current_func_idx);

        // 泛型类型实参解析（供 typeof(T) 运行时查表）
        // 解析 type_args 中的泛型参数引用（0x8000|param_idx）：从父帧查实际 type_id
        // 必须在 enterFunction 之前解析（此时 frame_stack 栈顶是父帧）
        const resolved_type_args = try self.materializeTypeArgs(call_meta.type_args);

        if (is_self_recursive) {
            // ── 自递归：保存实参值（含深拷贝） ──
            var saved_arg_values: [16]value.Value = undefined;
            for (args, 0..) |arg_chan, i| {
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                if (!is_ref and self.runtime.isRef(arg_chan) and self.readRefObj(arg_chan) != null) {
                    const v = self.chanToValue(arg_chan);
                    saved_arg_values[i] = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(saved_arg_values[i]);
                } else {
                    saved_arg_values[i] = self.chanToValue(arg_chan);
                }
            }

            try self.runtime.enterFunction(call_meta.func_index, &callee_func, resolved_type_args);
            errdefer self.runtime.leaveFunction();

            // 写入 callee 形参通道
            const count = @min(args.len, callee_func.param_channels.len);
            for (0..count) |i| {
                self.valueToChan(callee_func.param_channels[i], saved_arg_values[i]);
            }
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(call_meta.func_index, &callee_func, resolved_type_args);
            errdefer self.runtime.leaveFunction();
            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
        }

        self.call_stack[self.call_depth] = .{
            .func_idx = call_meta.func_index,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(call_meta.func_index, args);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果到栈上局部变量 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }

    /// 哈希参数为 u64（FNV-1a 变体）
    /// 直接哈希通道字节（标量 + nullable<标量>，ref_chan 已被 isMemoizableChanType 排除）
    pub fn hashArgs(self: *Engine, args: []const u16) u64 {
        var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
        for (args) |arg_chan| {
            const meta = self.ir.channels.get(arg_chan);
            const w = meta.elem_width;
            if (w == 0) continue;
            const src = self.runtime.rawPtr(arg_chan);
            for (src[0..w]) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
        }
        return h;
    }

    /// 间接调用（Closure / PartialApplication）：读取闭包值后分派到标准调用路径或
    /// PartialApplication 调用。自递归闭包调用同样需要保存实参值（含深拷贝）。
    pub fn execCallIndirect(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        // 读取 Closure / PartialApplication 值
        const closure_chan = node.inputs[0];
        const raw_ptr = self.runtime.readPtr(closure_chan);
        const ptr = raw_ptr orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        const is_partial = header.type_tag == .partial;
        if (header.type_tag != .closure and !is_partial) return error.InvalidChannel;

        if (is_partial) {
            const pa: *value.PartialApplication = @alignCast(@fieldParentPtr("header", header));
            const func_idx: u16 = @intCast(@intFromPtr(pa.func) - 1);
            if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
            const callee_func = self.ir.functions[func_idx];

            // Profiling: partial application 调用事件
            // defer 必须在 if(is_partial) 块作用域，不能在 if(prof) 块内
            const prof_opt_pa = self.tctx.?.prof;
            var saved_func_pa: u32 = 0;
            if (prof_opt_pa) |p| {
                p.onFuncCall(func_idx);
                saved_func_pa = p.current_func_idx.load(.acquire);
                p.setCurrentFunc(func_idx);
            }
            defer if (prof_opt_pa) |p| {
                p.setCurrentFunc(saved_func_pa);
                p.onFuncRet(func_idx);
            };

            return try self.execPartialApplicationCall(node, call_meta, callee_func, func_idx, pa);
        }

        const closure: *value.Closure = @alignCast(@fieldParentPtr("header", header));
        const func_idx: u16 = @intCast(@intFromPtr(closure.func));

        if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
        const callee_func = self.ir.functions[func_idx];

        // Profiling: closure 调用事件
        // defer 必须在函数作用域，不能在 if(prof) 块内
        const prof_opt_cl = self.tctx.?.prof;
        var saved_func_cl: u32 = 0;
        if (prof_opt_cl) |p| {
            p.onFuncCall(func_idx);
            saved_func_cl = p.current_func_idx.load(.acquire);
            p.setCurrentFunc(func_idx);
        }
        defer if (prof_opt_cl) |p| {
            p.setCurrentFunc(saved_func_cl);
            p.onFuncRet(func_idx);
        };

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        // 实际参数数量 = call_meta.arg_count - 1（减去 closure_chan）
        const arg_count = @as(usize, call_meta.arg_count) - 1;
        const args = node.inputs[1 .. 1 + arg_count];

        // SCC 问题：自递归 closure 调用时，enterFunction 覆盖实参通道的 chan_ptrs。
        // 自递归检测：func_idx == current_func_idx
        const is_self_recursive = (func_idx == self.current_func_idx);

        if (is_self_recursive) {
            // ── 自递归：保存实参值（含深拷贝） ──
            var saved_arg_values: [16]value.Value = undefined;
            for (args, 0..) |arg_chan, i| {
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                if (!is_ref and self.runtime.isRef(arg_chan) and self.readRefObj(arg_chan) != null) {
                    const v = self.chanToValue(arg_chan);
                    saved_arg_values[i] = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(saved_arg_values[i]);
                } else {
                    saved_arg_values[i] = self.chanToValue(arg_chan);
                }
            }

            try self.runtime.enterFunction(func_idx, &callee_func, &[_]u16{});
            errdefer self.runtime.leaveFunction();

            // 写入 callee 形参通道 + upvalue 参数
            const count = @min(args.len, callee_func.param_channels.len);
            for (0..count) |i| {
                self.valueToChan(callee_func.param_channels[i], saved_arg_values[i]);
            }
            self.copyClosureUpvalues(callee_func, closure, args.len);
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(func_idx, &callee_func, &[_]u16{});
            errdefer self.runtime.leaveFunction();

            try self.copyArgsToParams(args, callee_func, call_meta.arg_ref_bits);
            self.copyClosureUpvalues(callee_func, closure, args.len);
        }

        // 压栈
        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, args);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }
};
