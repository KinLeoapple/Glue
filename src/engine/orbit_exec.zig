//! 星轨/通道/异步执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execOrbitAsync* / execOrbitChan* / execChannel* 等执行函数，
//! 负责异步任务创建/汇合、通道收发与状态查询。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const ir_mod = @import("ir");
const value = @import("value");
const coroutine = @import("coroutine");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

const Node = ir_mod.Node;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 星轨执行（Phase 7：async/spawn）
    // ════════════════════════════════════════════
    // 设计要点：
    // - orbit_async_create：在独立线程中执行 async 函数，返回 AsyncHandle
    // - orbit_async_join：阻塞等待异步任务完成，提取结果
    // - orbit_chan_send/recv/try_recv：通过 ChannelValue 进行线程间通信
    // - 异步函数在独立线程中执行，拥有自己的 Engine 实例（共享 IR，独立 Runtime）

    /// orbit_async_create：在独立线程中执行 async 函数
    /// inputs[0..N] = 参数通道
    /// meta_index 指向 OrbitMeta（记录 func_index, arg_count, result_type）
    /// output = ref_chan（AsyncHandle 指针）
    pub fn execOrbitAsyncCreate(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.orbit_metas.len) return error.InvalidMetaIndex;
        const om = &self.ir.orbit_metas[node.meta_index - 1];

        // 协程调度路径是唯一路径：scheduler 由 run() 惰性启动，
        // 所有 async 函数都有 CoroutineMeta（builder 阶段对所有 is_async 函数生成）
        const sched = self.scheduler orelse return error.SchedulerNotStarted;
        if (self.ir.getCoroutineMeta(om.func_index) == null) return error.InvalidMetaIndex;
        return self.execOrbitAsyncCreateViaScheduler(node, om, sched);
    }

    /// 协程调度路径：通过 Scheduler.spawn 创建协程帧并入就绪队列。
    /// 参数从 IR 通道读取为 Value 切片，写入帧 locals 参数槽。
    /// AsyncHandle 输出到 node.output，状态设为 Running（worker 执行完会写结果）。
    pub fn execOrbitAsyncCreateViaScheduler(
        self: *Engine,
        node: *const Node,
        om: *const ir_mod.meta_mod.OrbitMeta,
        sched: *coroutine.Scheduler,
    ) EngineError!void {
        const meta = self.ir.getCoroutineMeta(om.func_index) orelse return error.InvalidMetaIndex;

        // 创建 AsyncHandle
        const handle = self.tctx.?.createObj(value.AsyncHandle) catch return error.OutOfMemory;
        handle.* = value.AsyncHandle.init();
        value.obj_header.initObjHeader(&handle.header, .async_val, @sizeOf(value.AsyncHandle), false, self.tctx.?);
        try self.trackObj(&handle.header);
        handle.setStatus(.Running);

        // 读取参数为 Value 切片（参数数量无上限，按 om.arg_count 分配）
        const arg_count = om.arg_count;
        const args = self.tctx.?.backing.alloc(value.Value, arg_count) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(args);
        for (0..arg_count) |i| {
            args[i] = self.readScalarValue(node.inputs[i]) catch value.Value.fromUnit();
        }

        // 解析 type_args（从 OrbitMeta 获取，解析泛型参数引用当前 sync 帧）
        const resolved_type_args = try self.materializeTypeArgs(om.type_args);

        // spawn 协程：分配帧 + 写参数 + state=0 + 入就绪队列
        const frame = sched.spawn(meta, args, resolved_type_args) catch return error.OutOfMemory;
        // 帧与 handle 关联（complete 时 worker 写结果到 handle）
        frame.async_handle = handle;

        // 输出 AsyncHandle 指针
        self.runtime.writePtr(node.output, @ptrCast(&handle.header));
    }

    /// orbit_async_join：阻塞等待异步任务完成，提取结果
    /// inputs[0] = handle 通道（ref_chan）
    /// output = 结果通道
    /// 值语义：普通复合类型返回值深拷贝到主线程，&T / *T 保持共享
    ///
    /// 跨线程结果传递协议：
    /// 1. join() 获取 result_val（指向 worker tctx 中的有效内存）
    /// 2. deepCopy 到主线程 tctx（读取 worker 内存，需 worker tctx 存活）
    /// 3. migrateRefParamValues 迁移 worker 通过 &T 写入主线程对象的堆值
    /// 4. signalConsumed 通知 worker 可以清理
    /// 5. waitWorkerDone 确保 worker 完全退出（避免泄漏检测竞态）
    pub fn execOrbitAsyncJoin(self: *Engine, node: *const Node) EngineError!void {
        const handle = self.readAsyncHandle(node.inputs[0]) orelse {
            return error.InvalidChannel;
        };

        // 阻塞等待完成
        const result_val = handle.join();

        // 确保无论如何都通知 worker 并等待其退出（避免 worker 永久阻塞）
        defer {
            handle.signalConsumed();
            handle.waitWorkerDone();
        }

        // 将结果写入 output 通道
        if (result_val) |v| {
            const out_meta = self.ir.channels.get(node.output);
            const out_val = if (self.runtime.isRef(node.output) and !out_meta.type_desc.is_ref) blk: {
                // 深拷贝到主线程 tctx：此时 worker tctx 仍存活，读取安全
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                break :blk copied;
            } else v;
            self.writeScalarValue(node.output, out_val);
        } else {
            // 任务失败或无结果：写入 0
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
        }

        // 迁移 worker 通过 &T 引用写入主线程对象的堆值到主线程 tctx。
        // worker 分配的对象在 worker tctx 中，worker 退出后变为悬垂指针。
        // 必须在 signalConsumed 之前完成（此时 worker tctx 仍存活，deepCopy 安全）。
        self.migrateRefParamValues(handle);
    }

    /// orbit_chan_send：向通道发送值（阻塞直到接收方就绪）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// inputs[1] = 值通道
    /// 值语义：普通复合类型 ref_chan 深拷贝后发送，&T / *T 保持共享
    pub fn execOrbitChanSend(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const val = try self.readScalarValue(node.inputs[1]);
        const val_meta = self.ir.channels.get(node.inputs[1]);
        const sent_val = if (self.runtime.isRef(node.inputs[1]) and !val_meta.type_desc.is_ref) blk: {
            const copied = val.deepCopy(self.tctx.?) catch return error.OutOfMemory;
            try self.trackValueTree(copied);
            break :blk copied;
        } else val;

        const sent = ch.send(sent_val) catch return error.Panic;
        if (!sent) return error.Thrown; // 通道已关闭
    }

    /// orbit_chan_recv：从通道接收值（阻塞直到有数据）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// output = 结果通道
    pub fn execOrbitChanRecv(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;

        const result_val = ch.recv() orelse {
            // 通道已关闭且无数据
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
            return;
        };

        self.writeScalarValue(node.output, result_val);
    }

    /// orbit_chan_try_recv：非阻塞接收，返回 nullable
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// output = nullable_chan
    pub fn execOrbitChanTryRecv(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse {
            // 无效通道：写入 null
            const inner_w = self.nullableInnerWidth(node.output);
            const dst = self.runtime.rawPtr(node.output);
            dst[inner_w] = 1; // null flag
            return;
        };

        const result_val = ch.tryRecv();
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);

        if (result_val) |v| {
            // 有值：写入 inner 值 + null flag = 0
            // 简化：将 Value 的 i64 表示写入
            const tmp_buf = self.readScalarValueToBytes(v);
            if (inner_w > 0) {
                @memcpy(dst[0..inner_w], tmp_buf[0..inner_w]);
            }
            dst[inner_w] = 0;
        } else {
            // 无值：null flag = 1
            dst[inner_w] = 1;
        }
    }

    /// orbit_async_status：查询异步任务状态（非阻塞）
    /// inputs[0] = handle 通道（ref_chan）
    /// output = i64 通道（0=Pending, 1=Running, 2=Completed, 3=Cancelled, 4=Failed）
    pub fn execOrbitAsyncStatus(self: *Engine, node: *const Node) EngineError!void {
        const handle = self.readAsyncHandle(node.inputs[0]) orelse return error.InvalidChannel;
        const status = handle.getStatus();
        const code: i64 = switch (status) {
            .Pending => 0,
            .Running => 1,
            .Completed => 2,
            .Cancelled => 3,
            .Failed => 4,
        };
        self.runtime.writeI64(node.output, code);
    }

    /// channel_close：关闭通道
    /// inputs[0] = channel 通道（ref_chan）
    /// output = unit_chan
    pub fn execChannelClose(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        ch.close();
    }

    /// channel_create：创建带缓冲的 ChannelValue
    pub fn execChannelCreate(self: *Engine, node: *const Node) EngineError!void {
        const capacity = try self.readIntAsI64(node.inputs[0]);
        const cap: usize = if (capacity < 0) 0 else @intCast(capacity);
        const ch = value.ChannelValue.create(self.tctx.?, cap) catch return error.OutOfMemory;
        try self.trackObj(&ch.header);
        self.runtime.writePtr(node.output, @ptrCast(&ch.header));
    }

    /// channel_sender：从 ChannelValue 创建 SenderValue
    pub fn execChannelSender(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const sender = self.tctx.?.createObj(value.SenderValue) catch return error.OutOfMemory;
        sender.* = .{ .channel = ch };
        value.obj_header.initObjHeader(&sender.header, .sender_val, @sizeOf(value.SenderValue), false, self.tctx.?);
        _ = value.obj_header.retain(&ch.header, self.tctx.?);
        try self.trackObj(&sender.header);
        self.runtime.writePtr(node.output, @ptrCast(&sender.header));
    }

    /// channel_receiver：从 ChannelValue 创建 ReceiverValue
    pub fn execChannelReceiver(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const receiver = self.tctx.?.createObj(value.ReceiverValue) catch return error.OutOfMemory;
        receiver.* = .{ .channel = ch };
        value.obj_header.initObjHeader(&receiver.header, .receiver_val, @sizeOf(value.ReceiverValue), false, self.tctx.?);
        _ = value.obj_header.retain(&ch.header, self.tctx.?);
        try self.trackObj(&receiver.header);
        self.runtime.writePtr(node.output, @ptrCast(&receiver.header));
    }

    // ════════════════════════════════════════════
    // 星轨执行辅助（Phase 7：async/spawn）
    // ════════════════════════════════════════════
    // 设计要点：
    // - orbit_async_create：在独立线程中执行 async 函数，返回 AsyncHandle
    // - orbit_async_join：阻塞等待异步任务完成，提取结果
    // - orbit_chan_send/recv/try_recv：通过 ChannelValue 进行线程间通信
    // - 异步函数在独立线程中执行，拥有自己的 Engine 实例（共享 IR，独立 Runtime）

    /// 读取 ref_chan 中的 AsyncHandle 指针
    pub fn readAsyncHandle(self: *Engine, chan: u16) ?*value.AsyncHandle {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .async_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 读取 ref_chan 中的 ChannelValue 指针
    /// 支持 ChannelValue、SenderValue、ReceiverValue 三种引用类型
    pub fn readChannelValue(self: *Engine, chan: u16) ?*value.ChannelValue {
        const header = self.readRefObj(chan) orelse return null;
        return switch (header.type_tag) {
            .channel_val => @alignCast(@fieldParentPtr("header", header)),
            .sender_val => blk: {
                const sender: *value.SenderValue = @alignCast(@fieldParentPtr("header", header));
                break :blk sender.channel;
            },
            .receiver_val => blk: {
                const receiver: *value.ReceiverValue = @alignCast(@fieldParentPtr("header", header));
                break :blk receiver.channel;
            },
            else => null,
        };
    }

    /// 读取 AtomicValue 指针（ref_chan → *AtomicValue）
    pub fn readAtomicValue(self: *Engine, chan: u16) ?*value.AtomicValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .atomic_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 迁移 worker 通过 &T 引用写入主线程对象的堆值到主线程 tctx。
    ///
    /// 背景：async 函数的 &T 参数让 worker 直接修改主线程对象。当 worker 分配
    /// 新堆值（如 self.rbuf = chunk）并存入主线程对象字段时，这些值位于 worker
    /// tctx，worker 退出后变为悬垂指针，下次访问触发 use-after-free。
    ///
    /// 本方法在 join 后、signalConsumed 前调用（worker tctx 仍存活）：
    /// 1. 遍历 handle.ref_param_objs 中的主线程对象
    /// 2. 对每个对象的字段，检查是否带 WORKER_ALLOCATED 标志
    /// 3. 若是，deepCopy 到主线程 tctx 并替换字段指针
    /// 4. worker 的原对象由 worker tracked_objs 清理，不会双重释放
    pub fn migrateRefParamValues(self: *Engine, handle: *value.AsyncHandle) void {
        const count = handle.ref_param_count;
        if (count == 0) return;
        for (0..count) |i| {
            const obj = handle.ref_param_objs[i] orelse continue;
            self.migrateObjFieldsWorker(obj);
        }
    }

    /// 递归迁移对象字段中的 worker 分配堆值。
    /// 仅遍历主线程分配的容器对象（非 WORKER_ALLOCATED），对其字段中的
    /// WORKER_ALLOCATED 引用执行 deepCopy 迁移。不递归进入已迁移的值
    /// （deepCopy 已完整复制子树）。
    pub fn migrateObjFieldsWorker(self: *Engine, obj: *value.obj_header.ObjHeader) void {
        // worker 分配的容器不应出现在 ref_param_objs 中（引用参数本身是主线程对象）
        if (obj.isWorkerAllocated()) return;

        switch (obj.type_tag) {
            .record => {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", obj));
                for (rec.fields) |*field| {
                    if (field.* == .ref and field.ref.isWorkerAllocated()) {
                        const copied = field.deepCopy(self.tctx.?) catch continue;
                        self.trackValueTree(copied) catch {};
                        field.* = copied;
                    }
                }
            },
            .adt => {
                const adt: *value.AdtValue = @alignCast(@fieldParentPtr("header", obj));
                for (adt.fields) |*f| {
                    if (f.value == .ref and f.value.ref.isWorkerAllocated()) {
                        const copied = f.value.deepCopy(self.tctx.?) catch continue;
                        self.trackValueTree(copied) catch {};
                        f.value = copied;
                    }
                }
            },
            .newtype => {
                const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
                if (nt.inner == .ref and nt.inner.ref.isWorkerAllocated()) {
                    const copied = nt.inner.deepCopy(self.tctx.?) catch return;
                    self.trackValueTree(copied) catch {};
                    nt.inner = copied;
                }
            },
            else => {},
        }
    }

    /// atomic_make：构造 AtomicValue 堆对象
    /// inputs[0] = 初始值，output = ref_chan（AtomicValue 指针）
    pub fn execAtomicMake(self: *Engine, node: *const Node) EngineError!void {
        const init_val = self.chanToValue(node.inputs[0]);
        const av = self.tctx.?.createObj(value.AtomicValue) catch return error.OutOfMemory;
        av.* = .{ .data = init_val, .mutex = .{} };
        value.obj_header.initObjHeader(&av.header, .atomic_val, @sizeOf(value.AtomicValue), false, self.tctx.?);
        try self.trackObj(&av.header);
        self.runtime.writePtr(node.output, @ptrCast(&av.header));
    }

    /// atomic_fetch_add：原子加/减法，返回旧值
    /// inputs[0] = Atomic ref_chan，inputs[1] = 增量值
    /// _pad=0 为 add，_pad=1 为 sub
    pub fn execAtomicFetchAdd(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const delta = self.chanToValue(node.inputs[1]);
        const old = if (node._pad == 1) av.fetchSub(delta) else av.fetchAdd(delta);
        self.valueToChan(node.output, old);
    }

    /// atomic_swap：原子交换，返回旧值
    /// inputs[0] = Atomic ref_chan，inputs[1] = 新值
    pub fn execAtomicSwap(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const new_val = self.chanToValue(node.inputs[1]);
        const old = av.xchg(new_val);
        self.valueToChan(node.output, old);
    }

    /// atomic_cas：原子比较并交换
    /// inputs[0] = Atomic ref_chan，inputs[1] = expected，inputs[2] = new
    pub fn execAtomicCas(self: *Engine, node: *const Node) EngineError!void {
        const av = self.readAtomicValue(node.inputs[0]) orelse return error.InvalidChannel;
        const expected = self.chanToValue(node.inputs[1]);
        const new_val = self.chanToValue(node.inputs[2]);
        const ok = av.cas(expected, new_val);
        self.runtime.writeBool(node.output, ok);
    }
};
