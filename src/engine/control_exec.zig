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
    /// inputs[0] = 值通道（ThrowValue 或普通值）
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
        // 非 ThrowValue：通过 readChannel 读取，非 null 则 Ok
        const v = self.runtime.readChannel(val_chan) orelse {
            self.runtime.writeBool(node.output, false);
            return;
        };
        const is_ok = v != .null_val;
        self.runtime.writeBool(node.output, is_ok);
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
                    _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
                    return;
                },
            }
        }
        // 非 ThrowValue：通过统一通道复制（readChannel + writeChannel）
        if (self.runtime.readChannel(val_chan)) |v| {
            _ = self.runtime.writeChannel(node.output, v);
        } else {
            _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
        }
    }

    /// gate_get_err：从 ThrowValue 中提取 Error RecordValue
    /// inputs[0] = ThrowValue 通道
    /// output = RecordValue 指针通道
    pub fn execGateGetErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .err => |rec_ptr| {
                    _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(&rec_ptr.header)));
                    return;
                },
                .ok => {
                    _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
                    return;
                },
            }
        }
        _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
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
        // 统一通道复制
        if (self.runtime.readChannel(src_chan)) |v| {
            _ = self.runtime.writeChannel(node.output, v);
        } else {
            _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
        }
    }

    /// gate_make_ok：构造 Ok 类型的 ThrowValue
    /// inputs[0] = 值通道
    /// output = ThrowValue 指针通道
    pub fn execGateMakeOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        // 读取值并构造 ThrowValue{ .ok = value }
        const v = try self.readScalarValue(val_chan);
        const vn = @tagName(v);
        std.debug.print("DEBUG gate_make_ok: val_chan={d} variant={s}\n", .{ val_chan, vn });
        if (v == .ref) {
            std.debug.print("  ref type_tag={s}\n", .{@tagName(v.ref.type_tag)});
        } else if (v == .i64) {
            const iv: i64 = @bitCast(v.i64);
            std.debug.print("  i64 value={d}\n", .{iv});
        }
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// gate_make_err：构造 ThrowValue(err)，err 持有 RecordValue
    /// inputs[0] = 错误值通道（Str / RecordValue）
    /// output = ThrowValue 指针通道
    ///
    /// Str 输入：构造 Error(msg) RecordValue（通用错误类型）
    /// RecordValue 输入：error_newtype 实例（IOError/CastError 等），直接持有
    pub fn execGateMakeErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const v = self.runtime.readChannel(val_chan) orelse return error.InvalidChannel;
        if (v != .ref) return error.InvalidChannel;
        const header = v.ref;

        const rec_ptr: *value.RecordValue = switch (header.type_tag) {
            .str => blk: {
                // 字符串输入：构造 Error(msg) RecordValue
                const msg_val = v;
                var fields: [1]value.Value = .{msg_val};
                const field_names: [1]?[]const u8 = .{"msg"};
                const rec_val = value.Value.makeRecordWithNames(self.tctx.?, "Error", &fields, &field_names) catch return error.OutOfMemory;
                _ = value.obj_header.retain(header, self.tctx.?); // record 窃取 msg 引用，需 retain
                try self.trackObj(rec_val.asRef());
                break :blk @alignCast(@fieldParentPtr("header", rec_val.asRef()));
            },
            .record => blk: {
                // error_newtype RecordValue：直接持有
                _ = value.obj_header.retain(header, self.tctx.?);
                try self.trackObj(header);
                break :blk @alignCast(@fieldParentPtr("header", header));
            },
            else => return error.InvalidChannel,
        };

        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = rec_ptr }) catch return error.OutOfMemory;
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
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
            // 堆对象：通过 readChannel 读取，再取 type_tag
            if (self.runtime.readChannel(val_chan)) |v| {
                if (v == .ref) {
                    const tag_val: i64 = @intFromEnum(v.ref.type_tag);
                    self.runtime.writeI64(node.output, tag_val);
                    return;
                }
            }
            self.runtime.writeI64(node.output, 0);
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

        // 统一通道复制：readChannel + writeChannel
        // nullable 自动包装：body 输出非 null → writeChannel 让 nullable vtable 设 flag=0
        //                   body 输出为 null  → writeChannel(null_val) 让 nullable vtable 设 flag=1
        if (self.runtime.readChannel(body_out_chan)) |v| {
            _ = self.runtime.writeChannel(node.output, v);
        } else {
            _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
        }
        return null;
    }

    /// route_merge：合并多分支结果（Phase 5 简化：直接拷贝第一个输入）
    pub fn execRouteMerge(self: *Engine, node: *const Node) EngineError!void {
        if (node.input_count == 0) return;
        const src_chan = node.inputs[0];
        if (self.runtime.readChannel(src_chan)) |v| {
            _ = self.runtime.writeChannel(node.output, v);
        } else {
            _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
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
    /// inputs[0] = 值通道（如果为 null 指针或 null 类型，则包装为 null）
    /// output = nullable_chan
    pub fn execNullableMake(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        // 通过 readChannel 读取值，writeChannel 让 nullable vtable 自动处理 null flag
        const v = self.runtime.readChannel(val_chan) orelse value.Value.fromNull();
        _ = self.runtime.writeChannel(node.output, v);
    }

    /// nullable_is_null：检查 Nullable<T> 是否为 null
    /// inputs[0] = nullable_chan
    /// output = bool_chan
    pub fn execNullableIsNull(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        // nullable vtable 读取：null 时返回 null_val，非 null 返回 inner Value
        const v = self.runtime.readChannel(src_chan) orelse value.Value.fromNull();
        const is_null = v == .null_val;
        self.runtime.writeBool(node.output, is_null);
    }

    /// nullable_unwrap：提取 Nullable<T> 的内部值（null 时写零，由调用方通过 is_null 判断）
    /// inputs[0] = nullable_chan
    /// output = inner 值通道
    pub fn execNullableUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        // nullable vtable 读取：null 返回 null_val，非 null 返回 inner
        const v = self.runtime.readChannel(src_chan) orelse value.Value.fromNull();
        // null 时 writeChannel 让目标 vtable 处理零值
        _ = self.runtime.writeChannel(node.output, v);
    }

    /// nullable_unwrap_or：提取值，null 时返回默认值
    /// inputs[0] = nullable_chan, inputs[1] = default 值通道
    /// output = inner 值通道
    pub fn execNullableUnwrapOr(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const default_chan = node.inputs[1];

        const v = self.runtime.readChannel(src_chan) orelse value.Value.fromNull();
        const result = if (v == .null_val) blk: {
            break :blk self.runtime.readChannel(default_chan) orelse value.Value.fromNull();
        } else v;
        _ = self.runtime.writeChannel(node.output, result);
    }

    // ════════════════════════════════════════════
    // 内存管理执行（Phase 6：unsafe 手动分配）
    // ════════════════════════════════════════════

    /// alloc：在堆上分配内存（通过 ThreadContext 对象池）
    /// meta_index 指向 ScalarMeta，const_val.int_val 存储分配字节数
    /// output = 分配内存指针通道
    pub fn execAlloc(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const sm = self.ir.scalar_metas[node.meta_index - 1];
        const cv = sm.const_val orelse return error.InvalidMetaIndex;
        const size: usize = @intCast(cv.int_val);

        if (size == 0) {
            _ = self.runtime.writeChannel(node.output, value.Value.fromNull());
            return;
        }

        // 通过 ThreadContext 的对象池分配
        const tctx = self.tctx orelse return error.OutOfMemory;
        const buf = tctx.allocBySize(size) catch return error.OutOfMemory;
        @memset(buf, 0);
        // 裸内存地址存为 i64 位模式（非 ObjHeader，不能用 fromRef）
        _ = self.runtime.writeChannel(node.output, value.Value.fromI64(@bitCast(@intFromPtr(buf.ptr))));
    }

    /// free：释放堆内存（简化：不实际释放，由 arena reset 统一回收）
    /// inputs[0] = ref_chan（指向要释放的内存）
    pub fn execFree(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        // 简化：arena 分配器不支持单个释放，由函数级/作用域级 reset 统一回收
    }
};
