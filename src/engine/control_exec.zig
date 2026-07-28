//! gate / route / race / nullable / alloc / free 执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 gate_check / gate_get_ok / gate_get_err / gate_propagate / gate_select /
//! gate_make_ok / gate_make_err / cleanup_register / race_source / race_select /
//! race_yield / route_get_tag / route_dispatch / route_merge / nullable_make /
//! nullable_is_null / nullable_unwrap / nullable_unwrap_or / alloc / free 等执行函数。
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

pub const Methods = struct {
    // ════════════════════════════════════════════
    // Gate 执行（Phase 3：ThrowValue 门控）
    // ════════════════════════════════════════════

    /// gate_check：检查值是否 Ok
    /// inputs[0] = 值通道（ref_chan 指向 ThrowValue 或普通值）
    /// output = mask_chan（1=Ok, 0=Err）
    pub fn execGateCheck(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        // 如果是 ThrowValue，检查 payload 是 ok 还是 err
        if (self.readThrow(val_chan)) |throw_val| {
            const is_ok = switch (throw_val.payload) {
                .ok => true,
                .err => false,
            };
            self.runtime.writeBool(node.output, is_ok);
            return;
        }
        // 非 ThrowValue：非 null 则 Ok
        const ptr = self.runtime.readPtr(val_chan);
        self.runtime.writeBool(node.output, ptr != null);
    }

    /// gate_get_ok：从 ThrowValue 中提取 Ok 值
    /// inputs[0] = ThrowValue 通道
    /// output = Ok 值通道
    pub fn execGateGetOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .ok => |v| {
                    self.writeScalarValue(node.output, v);
                    return;
                },
                .err => {
                    self.runtime.writePtr(node.output, null);
                    return;
                },
            }
        }
        // 非 ThrowValue：直接拷贝
        const w = self.runtime.elemWidth(val_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(val_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// gate_get_err：从 ThrowValue 中提取 Error 值
    /// inputs[0] = ThrowValue 通道
    /// output = ErrorValue 指针通道
    pub fn execGateGetErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .err => |err_ptr| {
                    self.runtime.writePtr(node.output, @ptrCast(&err_ptr.header));
                    return;
                },
                .ok => {
                    self.runtime.writePtr(node.output, null);
                    return;
                },
            }
        }
        self.runtime.writePtr(node.output, null);
    }

    /// gate_propagate：OR 传播错误掩码
    /// inputs[0] = 当前 check 结果, inputs[1] = 上游 mask
    /// output = OR 后的 mask
    pub fn execGatePropagate(self: *Engine, node: *const Node) EngineError!void {
        const cur = self.runtime.readBool(node.inputs[0]);
        const upstream = if (node.input_count >= 2) self.runtime.readBool(node.inputs[1]) else true;
        // 传播：如果当前 Ok 且上游也 Ok，则 Ok；否则 Err
        self.runtime.writeBool(node.output, cur and upstream);
    }

    /// gate_select：按 mask 选择值
    /// inputs[0] = mask, inputs[1] = ok_val, inputs[2] = err_val
    /// output = 选中的值
    pub fn execGateSelect(self: *Engine, node: *const Node) EngineError!void {
        const mask = self.runtime.readBool(node.inputs[0]);
        const src_chan = if (mask) node.inputs[1] else node.inputs[2];
        const w = self.runtime.elemWidth(src_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// gate_make_ok：构造 Ok 类型的 ThrowValue
    /// inputs[0] = 值通道
    /// output = ref_chan（ThrowValue 指针）
    pub fn execGateMakeOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        // 读取值并构造 ThrowValue{ .ok = value }
        const v = try self.readScalarValue(val_chan);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// gate_make_err：构造 ErrorValue + ThrowValue(err)
    /// inputs[0] = 错误信息通道（ref_chan 指向 Str）
    /// output = ref_chan（ThrowValue 指针）
    pub fn execGateMakeErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        // 判断输入类型并提取 type_name 和 message
        var type_name: []const u8 = "Error";
        var msg_bytes: []const u8 = "";
        var existing_err: ?*value.ErrorValue = null;

        if (self.readRefObj(val_chan)) |header| {
            switch (header.type_tag) {
                .str => {
                    const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", header));
                    msg_bytes = s.bytes();
                },
                .error_val => {
                    // 已经是 ErrorValue：直接使用
                    const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                    existing_err = e;
                },
                .record => {
                    // error_newtype 构造器产生的 RecordValue
                    // 提取 type_name 和第一个字段（message）
                    const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                    type_name = r.type_name;
                    // field_id=1 是第一个构造器字段（field_id=0 是 __tag）
                    if (r.fields.len > 1) {
                        const field_val = r.fields[1];
                        if (field_val == .ref) {
                            const fh: *value.obj_header.ObjHeader = @ptrCast(@alignCast(field_val.ref));
                            if (fh.type_tag == .str) {
                                const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fh));
                                msg_bytes = fs.bytes();
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // 如果已有 ErrorValue，直接用它构造 ThrowValue
        const err_val = if (existing_err) |e| e else blk: {
            const err_v = value.Value.makeError(self.tctx.?, type_name, msg_bytes, false) catch return error.OutOfMemory;
            try self.trackObj(err_v.asRef());
            const err_ptr: *value.ErrorValue = @alignCast(@fieldParentPtr("header", err_v.asRef()));
            break :blk err_ptr;
        };

        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = err_val }) catch return error.OutOfMemory;
        _ = value.obj_header.retain(&err_val.header, self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    // ════════════════════════════════════════════
    // 清理执行（Phase 4：defer）
    // ════════════════════════════════════════════

    /// cleanup_register：将 defer 体注册到 defer 栈
    /// meta_index 指向 CleanupMeta（记录 body_start/body_len）
    pub fn execCleanupRegister(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.cleanup_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.cleanup_metas[node.meta_index - 1];

        if (self.defer_top >= engine_mod.MAX_DEFERS) return error.CallDepthExceeded;

        self.defer_stack[self.defer_top] = .{
            .func_idx = self.current_func_idx,
            .body_start = cm.body_start,
            .body_len = cm.body_len,
        };
        self.defer_top += 1;
    }

    // ════════════════════════════════════════════
    // 路由 + 竞争执行（Phase 5：select 多路复用）
    // ════════════════════════════════════════════

    /// race_source：检查通道就绪性
    /// inputs[0] = 通道值（ChannelValue 指针或任意标量值）
    /// output = mask_chan（1=就绪, 0=未就绪）
    pub fn execRaceSource(self: *Engine, node: *const Node) EngineError!void {
        const ready = self.selectSourceReady(node.inputs[0]);
        self.runtime.writeBool(node.output, ready);
    }

    /// select 源就绪性检查（非阻塞）
    /// 非通道源（标量等）始终就绪；通道源有数据/会合发送方/已关闭时就绪
    pub fn selectSourceReady(self: *Engine, chan: u16) bool {
        // 只有 ref_chan 才可能是 ChannelValue/SenderValue/ReceiverValue
        if (!self.runtime.isRef(chan)) return true;
        const ch = self.readChannelValue(chan) orelse return true;
        ch.mutex.lock();
        defer ch.mutex.unlock();
        // 已关闭：recv 立即返回（null），视为就绪，避免 select 永久挂起
        if (ch.closed) return true;
        // 缓冲模式看数据量，会合模式看发送方是否就绪
        return if (ch.capacity == 0) ch.rend_ready else ch.count > 0;
    }

    /// race_select：阻塞多路复用，直到任一 receive 通道就绪或 timeout 到期
    /// inputs[0..source_count)   = 各 receive 分支的通道引用
    /// inputs[timeout_input]     = timeout 时长通道（毫秒，仅 RaceMeta.timeout_arm 非 null 时）
    /// output = i64_chan（获胜分支的 arm 索引，0-based）
    pub fn execRaceSelect(self: *Engine, node: *const Node) EngineError!void {
        var source_count: u8 = node.input_count;
        var timeout_arm: ?u8 = null;
        var timeout_input: u8 = 0;
        if (node.meta_index > 0 and node.meta_index <= self.ir.race_metas.len) {
            const rm = self.ir.race_metas[node.meta_index - 1];
            source_count = rm.source_count;
            timeout_arm = rm.timeout_arm;
            timeout_input = rm.timeout_input;
        }

        // 计算超时截止时间（单调时钟毫秒时间戳），null 表示无限等待
        var deadline: ?i64 = null;
        if (timeout_arm != null) {
            const dur_ms = try self.readIntAsI64(node.inputs[timeout_input]);
            deadline = engine_mod.monotonicMillis() + dur_ms;
        }

        // 阻塞轮询：先自旋让出 CPU，后 1ms 睡眠退避（与 sync.Condition 的等待纪律一致）
        var spin: u32 = 0;
        while (true) {
            var i: u8 = 0;
            while (i < source_count) : (i += 1) {
                if (self.selectSourceReady(node.inputs[i])) {
                    // 输入槽位 i → arm 索引：timeout 分支占据 arm 索引 timeout_arm，
                    // 其后的 receive 分支 arm 索引 = 输入槽位 + 1
                    const arm_idx: i64 = if (timeout_arm) |ta|
                        (if (i >= ta) @as(i64, i) + 1 else @as(i64, i))
                    else
                        @as(i64, i);
                    self.runtime.writeI64(node.output, arm_idx);
                    return;
                }
            }
            if (deadline) |dl| {
                if (engine_mod.monotonicMillis() >= dl) {
                    self.runtime.writeI64(node.output, @as(i64, timeout_arm.?));
                    return;
                }
            }
            if (spin < 64) {
                std.Thread.yield() catch {};
                spin += 1;
            } else {
                engine_mod.selectBackoffSleep();
            }
        }
    }

    /// race_yield：让出执行权
    pub fn execRaceYield(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        std.Thread.yield() catch {};
    }

    /// route_get_tag：读取值的 tag（用于 Trait 动态分派和 ADT 构造器识别）
    /// inputs[0] = 值通道
    /// output = mask_chan（tag 值，用 i64 存储）
    pub fn execRouteGetTag(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        if (self.runtime.isRef(val_chan)) {
            // 堆对象：读取 type_tag 的整数值作为 tag
            const header = self.readRefObj(val_chan);
            if (header) |h| {
                const tag_val: i64 = @intFromEnum(h.type_tag);
                self.runtime.writeI64(node.output, tag_val);
            } else {
                self.runtime.writeI64(node.output, 0);
            }
        } else {
            // 标量值：用 type_desc.type_id 作为 tag（替代旧的 @intFromEnum(chan_type)）
            const tag_val: i64 = @intCast(self.runtime.typeDesc(val_chan).type_id);
            self.runtime.writeI64(node.output, tag_val);
        }
    }

    /// route_dispatch：按 winner 索引执行对应 body 子图
    /// inputs[0] = winner 索引（mask_chan）
    /// output = 结果通道
    pub fn execRouteDispatch(self: *Engine, node: *const Node) EngineError!?u16 {
        if (node.meta_index == 0 or node.meta_index > self.ir.route_metas.len) return error.InvalidMetaIndex;
        const rm = self.ir.route_metas[node.meta_index - 1];

        // 读取 winner 索引（通用观察点：自动强制 Lazy<bool>/Lazy<i64>）
        const winner_val = try self.readScalarValue(node.inputs[0]);
        const winner_raw = winner_val.asI64();
        const winner: usize = @intCast(@as(u64, @bitCast(winner_raw)));

        if (winner >= rm.body_starts.len or winner >= rm.body_lens.len) {
            return error.InvalidChannel;
        }

        const body_start = rm.body_starts[winner];
        const body_len = rm.body_lens[winner];
        if (body_len == 0) return null;

        // 执行 winner 对应的 body 子图
        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const local_start = body_start - func.node_start;

        // 如果 body 中遇到 halt 节点（halt_return/halt_throw），传播它
        const halt_result = try self.execBodyNodes(nodes, local_start, body_len);
        if (halt_result) |halt_chan| {
            return halt_chan;
        }

        // body 子图最后一个节点的 output 作为结果
        const body_out_chan = nodes[local_start + body_len - 1].output;

        // 类型转换：body 输出 → 结果通道
        if (self.runtime.isNullable(node.output) and !self.runtime.isNullable(body_out_chan)) {
            // 结果是 nullable，body 输出不是 nullable → 包装为 nullable
            const inner_w = self.nullableInnerWidth(node.output);
            const dst = self.runtime.rawPtr(node.output);
            if (self.runtime.isNull(body_out_chan)) {
                // body 输出是 null → 设置 null flag
                dst[inner_w] = 1;
            } else {
                // body 输出是值类型 → 拷贝值，清除 null flag
                const src = self.runtime.rawPtr(body_out_chan);
                if (inner_w > 0) @memcpy(dst[0..inner_w], src[0..inner_w]);
                dst[inner_w] = 0;
            }
        } else {
            // 直接拷贝（宽度取 body 输出和结果中较小者，避免越界）
            const w = @min(self.runtime.elemWidth(body_out_chan), self.runtime.elemWidth(node.output));
            if (w > 0) {
                const src = self.runtime.rawPtr(body_out_chan);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..w], src[0..w]);
            }
        }
        return null;
    }

    /// route_merge：合并多分支结果（Phase 5 简化：直接拷贝第一个输入）
    pub fn execRouteMerge(self: *Engine, node: *const Node) EngineError!void {
        if (node.input_count == 0) return;
        const src_chan = node.inputs[0];
        const w = self.runtime.elemWidth(src_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    // ════════════════════════════════════════════
    // Nullable 执行（Phase 6：可空值）
    // ════════════════════════════════════════════
    // nullable_chan 布局：[inner_value_bytes][null_flag: 1 byte]
    // null_flag = 0 表示有值（non-null），null_flag = 1 表示 null

    /// 获取 nullable 通道的 inner 宽度（总宽度 - 1 byte flag）
    /// 统一通过 runtime.elemWidth 获取，不再依赖 ChannelMeta.inner_type
    pub fn nullableInnerWidth(self: *Engine, chan: u16) u8 {
        return self.runtime.elemWidth(chan) - 1;
    }

    /// nullable_make：将值包装为 Nullable<T>
    /// inputs[0] = 值通道（如果 ref_chan 为 null 指针，则包装为 null）
    /// output = nullable_chan
    pub fn execNullableMake(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        const inner_w = self.nullableInnerWidth(node.output);
        const total_w = self.runtime.elemWidth(node.output); // inner_w + 1
        const dst = self.runtime.rawPtr(node.output);

        // 检查是否为 null（ref_chan 的 null 指针，或 null_chan）
        const is_null = blk: {
            if (self.runtime.isRef(val_chan)) break :blk self.runtime.readPtr(val_chan) == null;
            if (self.runtime.isNull(val_chan)) break :blk true;
            break :blk false;
        };

        if (is_null) {
            // 设置 null flag = 1
            dst[inner_w] = 1;
        } else {
            // 拷贝 inner 值，设置 null flag = 0
            if (inner_w > 0) {
                const src = self.runtime.rawPtr(val_chan);
                @memcpy(dst[0..inner_w], src[0..inner_w]);
            }
            dst[inner_w] = 0;
        }
        _ = total_w;
    }

    /// nullable_is_null：检查 Nullable<T> 是否为 null
    /// inputs[0] = nullable_chan
    /// output = bool_chan
    pub fn execNullableIsNull(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);
        // null flag 在 inner_w 偏移处
        const is_null = src[inner_w] != 0;
        self.runtime.writeBool(node.output, is_null);
    }

    /// nullable_unwrap：提取 Nullable<T> 的内部值（null 时写零，由调用方通过 is_null 判断）
    /// inputs[0] = nullable_chan
    /// output = inner 值通道
    pub fn execNullableUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);

        if (inner_w > 0) {
            const dst = self.runtime.rawPtr(node.output);
            if (src[inner_w] != 0) {
                // null 值：写零（调用方应通过 nullable_is_null 判断后再使用）
                @memset(dst[0..inner_w], 0);
            } else {
                @memcpy(dst[0..inner_w], src[0..inner_w]);
            }
        }
    }

    /// nullable_unwrap_or：提取值，null 时返回默认值
    /// inputs[0] = nullable_chan, inputs[1] = default 值通道
    /// output = inner 值通道
    pub fn execNullableUnwrapOr(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const default_chan = node.inputs[1];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);

        const is_null = src[inner_w] != 0;
        const result_chan = if (is_null) default_chan else src_chan;

        if (inner_w > 0) {
            const result_src = self.runtime.rawPtr(result_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..inner_w], result_src[0..inner_w]);
        }
    }

    // ════════════════════════════════════════════
    // 内存管理执行（Phase 6：unsafe 手动分配）
    // ════════════════════════════════════════════

    /// alloc：在堆上分配内存（通过 ThreadContext 对象池）
    /// meta_index 指向 ScalarMeta，const_val.int_val 存储分配字节数
    /// output = ref_chan（指向分配的内存）
    pub fn execAlloc(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const sm = self.ir.scalar_metas[node.meta_index - 1];
        const cv = sm.const_val orelse return error.InvalidMetaIndex;
        const size: usize = @intCast(cv.int_val);

        if (size == 0) {
            self.runtime.writePtr(node.output, null);
            return;
        }

        // 通过 ThreadContext 的对象池分配
        const tctx = self.tctx orelse return error.OutOfMemory;
        const buf = tctx.allocBySize(size) catch return error.OutOfMemory;
        @memset(buf, 0);
        self.runtime.writePtr(node.output, buf.ptr);
    }

    /// free：释放堆内存（简化：不实际释放，由 arena reset 统一回收）
    /// inputs[0] = ref_chan（指向要释放的内存）
    pub fn execFree(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        // 简化：arena 分配器不支持单个释放，由函数级/作用域级 reset 统一回收
    }
};
