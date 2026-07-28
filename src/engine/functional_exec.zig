//! 闭包/偏应用执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execClosureMake / execPartialMake / execPartialApplicationCall 等执行函数，
//! 负责闭包构造、偏应用构造与偏应用调用。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;
const MAX_CALL_DEPTH = engine_mod.MAX_CALL_DEPTH;

const Node = ir_mod.Node;
const Function = ir_mod.Function;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 闭包与偏应用
    // ════════════════════════════════════════════

    /// closure_make：创建 Closure 值，存储 func_idx + 上值
    /// inputs[0..N] = 上值通道
    /// meta_index 指向 ClosureMeta（func_index, upvalue_count, result_type）
    /// output = ref_chan（Closure 指针）
    /// 逃逸分析驱动：非逃逸函数内的闭包走 ShadowArena，endFunction 时 O(1) reset
    pub fn execClosureMake(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.closure_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.closure_metas[node.meta_index - 1];

        // 连续内存分配：[Closure header | upvalues[upvalue_count]]
        // 先创建 Closure 对象（upvalues 暂为空），并写入输出通道
        // 这样自引用闭包（递归 lambda）能在收集上值时读取到自身指针
        const upvalue_count = @as(usize, @min(cm.upvalue_count, node.input_count));
        const total = @sizeOf(value.Closure) + upvalue_count * @sizeOf(value.Value);
        const use_arena = self.currentFuncUseArena();
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(total) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(total) catch return error.OutOfMemory;
        const closure: *value.Closure = @ptrCast(@alignCast(buf.ptr));
        closure.* = .{
            .func = @ptrFromInt(@as(usize, cm.func_index)),
            .arity = @intCast(upvalue_count),
            .upvalues = &.{},
            .upvalue_ref_bits = cm.upvalue_ref_bits,
            .cell_upvalues = cm.cell_upvalues,
        };
        value.obj_header.initObjHeader(&closure.header, .closure, total, use_arena, self.tctx.?);
        try self.trackObj(&closure.header);
        self.runtime.writePtr(node.output, @ptrCast(&closure.header));

        // 现在收集上值（自引用闭包可从 output 通道读到自身指针）
        // upvalues 缓冲区已随 Closure 连续分配，此处仅填充数据
        if (upvalue_count > 0) {
            const uv_ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr + @sizeOf(value.Closure)));
            const upvalues = uv_ptr[0..upvalue_count];
            for (0..upvalue_count) |i| {
                const v = self.chanToValue(node.inputs[i]);
                const is_cell = (cm.cell_upvalues >> @intCast(i)) & 1 == 1;
                const is_ref = (cm.upvalue_ref_bits >> @intCast(i)) & 1 == 1;
                if (is_cell or is_ref) {
                    // cell / &T / *T 上值保持引用语义，共享原对象
                    upvalues[i] = v;
                    _ = upvalues[i].retain(self.tctx.?);
                } else {
                    // 普通复合类型上值：深拷贝以获得独立所有权
                    const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                    try self.trackValueTree(copied);
                    upvalues[i] = copied;
                }
            }
            closure.upvalues = upvalues;
        }
    }

    /// partial_make：构造 PartialApplication 值
    /// meta_index 指向 PartialMeta（func_index + 已绑定实参通道 + 剩余参数个数）
    /// output = ref_chan（PartialApplication 指针）
    pub fn execPartialMake(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.partial_metas.len) return error.InvalidMetaIndex;
        const pm = self.ir.partial_metas[node.meta_index - 1];

        const bound_count = pm.bound_arg_channels.len;
        var bound_args: [16]value.Value = undefined;
        for (0..bound_count) |i| {
            const arg_chan = pm.bound_arg_channels[i];
            const v = self.chanToValue(arg_chan);
            const is_ref = (pm.bound_arg_ref_bits >> @intCast(i)) & 1 == 1;
            if (is_ref) {
                bound_args[i] = v.retain(self.tctx.?);
            } else {
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                bound_args[i] = copied;
            }
        }

        const func_ptr: *const anyopaque = @ptrFromInt(@as(usize, pm.func_index) + 1);
        const partial_v = value.Value.makePartial(
            self.tctx.?,
            func_ptr,
            bound_args[0..bound_count],
            pm.remaining_arity,
            pm.bound_arg_ref_bits,
        ) catch return error.OutOfMemory;
        try self.trackObj(partial_v.ref);
        self.runtime.writePtr(node.output, @ptrCast(partial_v.ref));
    }

    /// 执行 PartialApplication 的调用：将已绑定参数与新实参合并后调用原函数
    /// 双 Region 架构：统一走 enterFunction/leaveFunction，Runtime 管理通道保存/恢复。
    pub fn execPartialApplicationCall(
        self: *Engine,
        node: *const Node,
        call_meta: ir_mod.CallMeta,
        callee_func: Function,
        func_idx: u16,
        pa: *value.PartialApplication,
    ) EngineError!void {
        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        const arg_count = @as(usize, call_meta.arg_count) - 1;
        const args = node.inputs[1 .. 1 + arg_count];
        const bound = pa.bound_args;
        const total_params = callee_func.param_channels.len;

        // SCC 问题：自递归 partial application 调用时，enterFunction 覆盖实参通道的 chan_ptrs。
        const is_self_recursive = (func_idx == self.current_func_idx);

        if (is_self_recursive) {
            // ── 自递归：保存显式实参值（含深拷贝） ──
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

            // 复制已绑定参数到被调用函数参数通道
            const bound_count = @min(bound.len, total_params);
            for (0..bound_count) |i| {
                const dst_chan = callee_func.param_channels[i];
                self.writeScalarValue(dst_chan, bound[i]);
            }

            // 写入显式实参到后续参数通道
            const explicit_count = @min(arg_count, if (total_params > bound_count) total_params - bound_count else 0);
            for (0..explicit_count) |i| {
                self.valueToChan(callee_func.param_channels[bound_count + i], saved_arg_values[i]);
            }
        } else {
            // ── 非递归：enterFunction 不触碰实参通道 ──
            try self.runtime.enterFunction(func_idx, &callee_func, &[_]u16{});
            errdefer self.runtime.leaveFunction();

            // 复制已绑定参数到被调用函数参数通道
            const bound_count = @min(bound.len, total_params);
            for (0..bound_count) |i| {
                const dst_chan = callee_func.param_channels[i];
                self.writeScalarValue(dst_chan, bound[i]);
            }

            // 复制新的显式实参到后续参数通道
            const explicit_count = @min(arg_count, if (total_params > bound_count) total_params - bound_count else 0);
            for (0..explicit_count) |i| {
                const dst_chan = callee_func.param_channels[bound_count + i];
                const is_ref = ((call_meta.arg_ref_bits >> @intCast(i)) & 1) != 0;
                try self.copyArgToParam(args[i], dst_chan, is_ref);
            }
        }

        // 压栈并调用原函数
        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, callee_func.param_channels);
        self.current_func_idx = saved_func_idx;

        // ── leaveFunction 前暂存结果 ──
        const saved_result = try self.saveCallResult(result_chan, call_meta.ret_is_ref);

        self.runtime.leaveFunction();

        // ── leaveFunction 后写入结果（chan_ptrs 已恢复为 caller） ──
        try self.writeCallResult(node.output, saved_result);
    }

    // ════════════════════════════════════════════
    // 惰性求值执行（Lazy<T>）
    // ════════════════════════════════════════════

    /// lazy_make：构造 LazyValue 对象
    /// inputs[0] = thunk closure (ref_chan)，output = ref_chan
    pub fn execLazyMake(self: *Engine, node: *const Node) EngineError!void {
        const closure_ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(closure_ptr));
        if (header.type_tag != .closure) return error.InvalidChannel;
        const closure: *value.Closure = @alignCast(@fieldParentPtr("header", header));

        const use_arena = self.currentFuncUseArena();
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(@sizeOf(value.LazyValue)) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(@sizeOf(value.LazyValue)) catch return error.OutOfMemory;
        const lazy: *value.LazyValue = @ptrCast(@alignCast(buf.ptr));
        lazy.* = .{
            .expr = undefined,
            .env = undefined,
            .thunk = closure,
        };
        value.obj_header.initObjHeader(&lazy.header, .lazy_val, @sizeOf(value.LazyValue), use_arena, self.tctx.?);
        try self.trackObj(&lazy.header);
        // LazyValue 持有 thunk 闭包的一次引用
        _ = (value.Value{ .ref = &closure.header }).retain(self.tctx.?);
        self.runtime.writePtr(node.output, @ptrCast(&lazy.header));
    }

    /// lazy_force：强制求值 Lazy<T>，或对非 LazyValue 的 ref_chan 做透传。
    /// inputs[0] = ref_chan（LazyValue 或其他堆对象引用），output = 值通道
    /// IR 的 forceLazyIfRef 对所有 ref_chan 统一发射 lazy_force；运行时按 type_tag 分派：
    /// - LazyValue → 强制求值 thunk 并缓存
    /// - 其他 ref（Cell/Record/Str/Array/Closure 等）→ 直接读值写出到 output
    pub fn execLazyForce(self: *Engine, node: *const Node) EngineError!void {
        // 非 LazyValue 的 ref_chan：直接读取底层值并透传到 output
        if (self.readLazyValue(node.inputs[0])) |lazy| {
            if (lazy.forced) {
                if (lazy.cached) |c| {
                    self.writeScalarValue(node.output, c);
                }
                return;
            }
            const result = try self.forceLazyValue(lazy);
            self.writeScalarValue(node.output, result);
            return;
        }
        // 非 LazyValue：ref_chan 透传（Cell 标量装箱 / 堆对象引用直接复制指针）
        const v = self.chanToValue(node.inputs[0]);
        self.writeScalarValue(node.output, v);
    }

    /// 读取 ref_chan 中的 LazyValue 指针
    pub fn readLazyValue(self: *Engine, chan: u16) ?*value.LazyValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .lazy_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 强制求值 LazyValue：调用 thunk 闭包并缓存结果
    pub fn forceLazyValue(self: *Engine, lazy: *value.LazyValue) EngineError!value.Value {
        if (lazy.forced) return lazy.cached orelse value.Value.fromNull();
        const closure: *value.Closure = @ptrCast(@alignCast(lazy.thunk));
        const func_idx: u16 = @intCast(@intFromPtr(closure.func));
        if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
        const callee_func = self.ir.functions[func_idx];

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        // enterFunction 在 CallStackRegion 中分配 thunk 函数的本地通道
        try self.runtime.enterFunction(func_idx, &callee_func, &[_]u16{});
        errdefer self.runtime.leaveFunction();

        // thunk 无显式参数，只需把上值写入 param_channels 尾部
        const total_params = callee_func.param_channels.len;
        const uv_count = @min(closure.upvalues.len, total_params);
        for (0..uv_count) |i| {
            self.writeScalarValue(callee_func.param_channels[i], closure.upvalues[i]);
        }

        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = callee_func.return_channel,
            .return_pc = 0,
        };
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, &.{});
        self.current_func_idx = saved_func_idx;

        // 在 leaveFunction 之前读取结果（leaveFunction 会 resetTo 回收通道内存）
        const result = try self.readScalarValue(result_chan);
        self.runtime.leaveFunction();

        // 缓存结果，避免重复求值
        lazy.forced = true;
        lazy.cached = result;
        _ = result.retain(self.tctx.?);
        return result;
    }
};
