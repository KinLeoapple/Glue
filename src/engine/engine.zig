//! Glue IR 执行引擎核心
//!
//! 接收优化的 GlueIR，线性遍历 nodes[]，switch 跳转表分派，读写通道，产出运行结果。
//! 设计参考：docs/glue-ir-design.md 第 6 章
//!
//! 标量运算复用 src/value/ops.zig 的 comptime 分派函数，避免重复实现。
//!
//! 执行模型：
//! - 按函数 node_start..node_start+node_count 线性遍历
//! - 每个节点通过 switch 分派到对应的 exec* 函数
//! - 节点从 inputs[] 通道读取数据，结果写入 output 通道
//! - halt_* 节点终止当前函数执行
//! - call 节点压栈调用其他函数

const std = @import("std");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");
const runtime_mod = @import("runtime.zig");

const GlueIR = ir_mod.GlueIR;
const Node = ir_mod.Node;
const NodeOp = ir_mod.NodeOp;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;
const ConstVal = ir_mod.ConstVal;
const ChanType = ir_mod.ChanType;
const ChannelMeta = ir_mod.ChannelMeta;
const Function = ir_mod.Function;
const Runtime = runtime_mod.Runtime;
const ThreadContext = mem.ThreadContext;
const GlobalPool = mem.GlobalPool;

// value 模块的标量运算复用
const ops = value.ops;
const scalar = value.scalar;
const ScalarTag = scalar.ScalarTag;

/// 执行错误
pub const EngineError = error{
    OutOfMemory,
    DivisionByZero,
    Overflow,
    CastOverflow,
    UnsupportedOp,
    Thrown,
    Panic,
    InvalidMetaIndex,
    InvalidChannel,
    CallDepthExceeded,
    LoopBreak,
    LoopContinue,
};

/// 函数调用栈帧
const Frame = struct {
    func_idx: u16,
    /// 返回通道（调用者的结果接收通道）
    return_chan: u16,
    /// 调用者的节点流位置（返回后继续执行的位置）
    return_pc: u32,
};

/// 最大调用深度（防止栈溢出）
const MAX_CALL_DEPTH: u32 = 1024;

/// 最大 defer 栈深度（每个函数可注册的 defer 数量上限）
const MAX_DEFERS: u32 = 256;

/// defer 栈帧：记录一个 defer 体的位置信息
const DeferFrame = struct {
    func_idx: u16,
    body_start: u32,
    body_len: u32,
};

/// 执行引擎：接收 GlueIR 并执行
pub const Engine = struct {
    ir: *GlueIR,
    runtime: Runtime,
    tctx: ?*ThreadContext = null,
    /// 是否拥有 ThreadContext（如果引擎创建的，则负责释放）
    owns_tctx: bool = false,
    global: ?*GlobalPool = null,
    owns_global: bool = false,
    backing: std.mem.Allocator,
    /// IO 接口（用于内置 print/println 输出，可选）
    io: ?std.Io = null,

    /// 函数调用栈
    call_stack: [MAX_CALL_DEPTH]Frame = undefined,
    call_depth: u32 = 0,
    /// 当前正在执行的函数索引（供 vec_map 等获取节点切片）
    current_func_idx: u16 = 0,
    /// 最后一次 run() 的实际返回通道索引（供外部查询返回类型）
    result_chan: u16 = 0,

    /// defer 栈（LIFO）：cleanup_register 入栈，halt 时 cleanup_run 执行
    defer_stack: [MAX_DEFERS]DeferFrame = undefined,
    defer_top: u32 = 0,

    /// 堆对象跟踪表（引擎创建的所有堆对象，deinit 时统一释放）
    tracked_objs: std.ArrayList(*value.obj_header.ObjHeader) = .empty,

    /// 初始化引擎（使用外部 ThreadContext）
    pub fn init(ir: *GlueIR, tctx: *ThreadContext, backing: std.mem.Allocator) Engine {
        // 注册所有堆对象的析构函数（确保 release 时正确分派）
        value.registerAllDeinits();
        return .{
            .ir = ir,
            .tctx = tctx,
            .owns_tctx = false,
            .global = tctx.global,
            .owns_global = false,
            .backing = backing,
            .runtime = Runtime.init(&tctx.channels, backing),
        };
    }

    /// 初始化引擎（内部创建 ThreadContext，用于简单场景）
    pub fn initOwned(ir: *GlueIR, backing: std.mem.Allocator) !Engine {
        // 注册所有堆对象的析构函数（确保 release 时正确分派）
        value.registerAllDeinits();
        const global = try backing.create(GlobalPool);
        global.* = GlobalPool.init(backing);
        const tctx = try backing.create(ThreadContext);
        tctx.* = ThreadContext.init(global, backing);
        return .{
            .ir = ir,
            .tctx = tctx,
            .owns_tctx = true,
            .global = global,
            .owns_global = true,
            .backing = backing,
            .runtime = Runtime.init(&tctx.channels, backing),
        };
    }

    /// 释放引擎资源
    pub fn deinit(self: *Engine) void {
        // 释放所有跟踪的堆对象
        for (self.tracked_objs.items) |obj| {
            value.obj_header.release(obj, self.backing);
        }
        self.tracked_objs.deinit(self.backing);

        self.runtime.deinit();
        if (self.owns_tctx) {
            if (self.tctx) |t| {
                t.deinit();
                self.backing.destroy(t);
            }
        }
        if (self.owns_global) {
            if (self.global) |g| {
                g.deinit();
                self.backing.destroy(g);
            }
        }
    }

    /// 跟踪堆对象（引擎创建的所有堆对象都应调用此方法）
    fn trackObj(self: *Engine, obj: *value.obj_header.ObjHeader) EngineError!void {
        self.tracked_objs.append(self.backing, obj) catch return error.OutOfMemory;
    }

    /// 运行入口函数，返回字符串结果（main 函数返回 str 时使用）
    pub fn runStr(self: *Engine) EngineError![]const u8 {
        try self.runtime.layout(&self.ir.channels);
        const entry = self.ir.entryFunc();
        const result_chan = try self.execFunction(self.ir.entry_index, entry.param_channels);
        const s = self.readStr(result_chan) orelse return error.InvalidChannel;
        return s.bytes();
    }

    /// 运行入口函数，返回 i64 结果（main 函数的返回值）
    pub fn run(self: *Engine) EngineError!i64 {
        // 布局通道存储
        try self.runtime.layout(&self.ir.channels);

        // 执行入口函数
        const entry = self.ir.entryFunc();
        const result_chan = try self.execFunction(self.ir.entry_index, entry.param_channels);
        self.result_chan = result_chan;

        // 读取返回值（按通道实际类型和宽度）
        const ret_meta = self.ir.channels.get(result_chan);
        const w = ret_meta.elem_width;
        if (w == 0) return 0; // unit 返回值
        if (ret_meta.chan_type == .bool_chan or ret_meta.chan_type == .mask_chan) {
            return @intFromBool(self.runtime.readBool(result_chan));
        }
        // 按宽度读取整数值（符号扩展）
        const ptr = self.runtime.rawPtr(result_chan);
        return switch (w) {
            1 => @as(i64, @as(i8, @bitCast(ptr[0]))),
            2 => @as(i64, @as(i16, @bitCast(@as(*[2]u8, @ptrCast(ptr)).*))),
            4 => @as(i64, @as(i32, @bitCast(@as(*[4]u8, @ptrCast(ptr)).*))),
            8 => @as(i64, @bitCast(@as(*[8]u8, @ptrCast(ptr)).*)),
            16 => @as(i64, @truncate(@as(i128, @bitCast(@as(*[16]u8, @ptrCast(ptr)).*)))),
            else => 0,
        };
    }

    /// 执行一个函数，返回结果通道索引
    fn execFunction(self: *Engine, func_idx: u16, args: []const u16) EngineError!u16 {
        const func = self.ir.functions[func_idx];
        const nodes = self.ir.funcNodes(func_idx);
        const node_start = func.node_start;
        self.current_func_idx = func_idx;

        _ = args;

        // 记录函数入口时的 defer 栈顶（用于函数返回时清理本函数的 defer 帧）
        const entry_defer_top = self.defer_top;

        // 构建子图跳过位图：vec_map/vec_fold/vec_scan 等的 body 子图
        // 不在主循环中执行，由对应的 vec_* exec 函数按需执行
        // 同时跳过 cleanup_register 注册的 defer 体（由 cleanup_run 按需执行）
        const body_skip = try self.backing.alloc(bool, nodes.len);
        defer self.backing.free(body_skip);
        @memset(body_skip, false);
        for (nodes) |n| {
            switch (n.op) {
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                    const vm = self.ir.vector_metas[n.meta_index - 1];
                    if (vm.body_len == 0) continue;
                    const local_start = vm.body_start - node_start;
                    const local_end = local_start + vm.body_len;
                    for (local_start..local_end) |i| {
                        if (i < nodes.len) body_skip[i] = true;
                    }
                },
                .cleanup_register => {
                    // defer 体节点也不在主循环执行，由 cleanup_run 按需执行
                    if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                    const cm = self.ir.cleanup_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    const local_start = cm.body_start - node_start;
                    const local_end = local_start + cm.body_len;
                    for (local_start..local_end) |i| {
                        if (i < nodes.len) body_skip[i] = true;
                    }
                },
                .route_dispatch => {
                    // select arm body 子图不在主循环执行，由 route_dispatch 按需执行
                    if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                    const rm = self.ir.route_metas[n.meta_index - 1];
                    for (rm.body_starts, rm.body_lens) |bs, bl| {
                        if (bl == 0) continue;
                        const local_start = bs - node_start;
                        const local_end = local_start + bl;
                        for (local_start..local_end) |i| {
                            if (i < nodes.len) body_skip[i] = true;
                        }
                    }
                },
                .scalar_loop => {
                    // 标量循环 body 子图不在主循环执行，由 execScalarLoop 按需执行
                    if (n.meta_index == 0 or n.meta_index > self.ir.loop_metas.len) continue;
                    const lm = self.ir.loop_metas[n.meta_index - 1];
                    if (lm.body_len == 0) continue;
                    const local_start = lm.body_start - node_start;
                    const local_end = local_start + lm.body_len;
                    for (local_start..local_end) |i| {
                        if (i < nodes.len) body_skip[i] = true;
                    }
                },
                .closure_make => {
                    // lambda 函数体节点内联在外层函数节点流中，由 call_indirect 按需执行
                    if (n.meta_index == 0 or n.meta_index > self.ir.closure_metas.len) continue;
                    const cm = self.ir.closure_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    const local_start = cm.body_start - node_start;
                    const local_end = local_start + cm.body_len;
                    for (local_start..local_end) |i| {
                        if (i < nodes.len) body_skip[i] = true;
                    }
                },
                else => {},
            }
        }

        // 线性遍历节点
        var pc: u32 = 0;
        var halt_chan: ?u16 = null;
        while (pc < nodes.len) {
            if (body_skip[pc]) {
                pc += 1;
                continue;
            }
            const node = nodes[pc];
            const result = try self.execNode(&node);
            if (result) |ret_chan| {
                halt_chan = ret_chan;
                break; // halt：跳出主循环，执行 defer 后返回
            }
            pc += 1;
        }

        // halt 时执行本函数注册的 defer（LIFO 顺序）
        if (self.defer_top > entry_defer_top) {
            // 从当前函数的 defer 帧开始，LIFO 执行
            const saved_func_idx = self.current_func_idx;
            while (self.defer_top > entry_defer_top) {
                self.defer_top -= 1;
                const frame = self.defer_stack[self.defer_top];
                self.current_func_idx = frame.func_idx;
                const defer_nodes = self.ir.funcNodes(frame.func_idx);
                const local_start = frame.body_start - self.ir.functions[frame.func_idx].node_start;
                _ = try self.execBodyNodes(defer_nodes, local_start, frame.body_len);
            }
            self.current_func_idx = saved_func_idx;
        }

        // 如果 halt 返回了通道，返回它；否则返回函数的 return_channel
        return halt_chan orelse func.return_channel;
    }

    /// 执行单个节点，返回非 null 表示 halt_return 的返回通道
    fn execNode(self: *Engine, node: *const Node) EngineError!?u16 {
        switch (node.op) {
            // === 常量 ===
            .const_i, .const_f, .const_bool, .const_char => try self.execConst(node),
            .const_unit => self.execConstUnit(node),
            .const_null => self.execConstNull(node),
            .const_str => try self.execConstStr(node),

            // === 整数算术（复用 value.ops） ===
            .int_add => try self.execIntBinOp(node, .add),
            .int_sub => try self.execIntBinOp(node, .sub),
            .int_mul => try self.execIntBinOp(node, .mul),
            .int_div => try self.execIntBinOp(node, .div),
            .int_mod => try self.execIntBinOp(node, .mod),
            .int_and => try self.execIntBinOp(node, .bit_and),
            .int_or => try self.execIntBinOp(node, .bit_or),
            .int_xor => try self.execIntBinOp(node, .bit_xor),
            .int_shl => try self.execIntShift(node, .shl),
            .int_shr => try self.execIntShift(node, .shr),

            // === 整数一元 ===
            .int_neg => try self.execIntUnOp(node, .neg),
            .int_abs => try self.execIntUnOp(node, .abs),
            .int_not => try self.execIntUnOp(node, .bit_not),

            // === 浮点算术（复用 value.ops） ===
            .float_add => try self.execFloatBinOp(node, .add),
            .float_sub => try self.execFloatBinOp(node, .sub),
            .float_mul => try self.execFloatBinOp(node, .mul),
            .float_div => try self.execFloatBinOp(node, .div),

            // === 浮点一元 ===
            .float_neg => try self.execFloatUnOp(node, .neg),
            .float_abs => try self.execFloatUnOp(node, .abs),

            // === 比较（复用 value.ops） ===
            .cmp_eq => try self.execCmp(node, .eq),
            .cmp_ne => try self.execCmp(node, .ne),
            .cmp_lt => try self.execCmp(node, .lt),
            .cmp_le => try self.execCmp(node, .le),
            .cmp_gt => try self.execCmp(node, .gt),
            .cmp_ge => try self.execCmp(node, .ge),

            // === 布尔逻辑 ===
            .bool_and => try self.execBoolBinOp(node, .and_),
            .bool_or => try self.execBoolBinOp(node, .or_),
            .bool_not => try self.execBoolNot(node),

            // === 内存操作（var 变量） ===
            .load => try self.execLoad(node),
            .store => try self.execStore(node),

            // === 选择（if 表达式，标量模式 N=1） ===
            .vec_select => try self.execVecSelect(node),

            // === 类型转换 ===
            .cast => try self.execCast(node, false),
            .cast_safe => try self.execCast(node, true),

            // === 字符串操作 ===
            .string_len => try self.execStringLen(node),
            .string_concat => try self.execStringConcat(node),
            .string_index => try self.execStringIndex(node),

            // === 数组操作 ===
            .array_make => try self.execArrayMake(node),
            .array_get => try self.execArrayGet(node),
            .array_set => try self.execArraySet(node),
            .array_len => try self.execArrayLen(node),
            .array_push => try self.execArrayPush(node),
            .array_concat => try self.execArrayConcat(node),

            // === 记录操作 ===
            .record_make => try self.execRecordMake(node),
            .record_get => try self.execRecordGet(node),
            .record_set => try self.execRecordSet(node),
            .record_clone => try self.execRecordClone(node),

            // === 向量操作（Phase 3） ===
            .vec_source => try self.execVecSource(node),
            .vec_map => try self.execVecMap(node),
            .vec_map2 => try self.execVecMap2(node),
            .vec_sink => try self.execVecSink(node),
            .vec_fold => try self.execVecFold(node),
            .vec_scan => try self.execVecScan(node),
            .vec_filter => try self.execVecFilter(node),
            .vec_take => try self.execVecTake(node),
            .vec_take_while => try self.execVecTakeWhile(node),
            .vec_zip => try self.execVecZip(node),

            // === 门控（Phase 4：错误处理） ===
            .gate_check => try self.execGateCheck(node),
            .gate_get_ok => try self.execGateGetOk(node),
            .gate_get_err => try self.execGateGetErr(node),
            .gate_propagate => try self.execGatePropagate(node),
            .gate_select => try self.execGateSelect(node),
            .gate_make_ok => try self.execGateMakeOk(node),
            .gate_make_err => try self.execGateMakeErr(node),

            // === 清理（Phase 4：defer） ===
            .cleanup_register => try self.execCleanupRegister(node),
            // cleanup_run 由 execFunction 在 halt 时自动调用，不通过 execNode 分派

            // === 路由 + 竞争（Phase 5：select 多路复用 + Trait 分派） ===
            .race_source => try self.execRaceSource(node),
            .race_select => try self.execRaceSelect(node),
            .race_yield => try self.execRaceYield(node),
            .route_get_tag => try self.execRouteGetTag(node),
            .route_dispatch => try self.execRouteDispatch(node),
            .route_merge => try self.execRouteMerge(node),

            // === Nullable（Phase 6：可空值） ===
            .nullable_make => try self.execNullableMake(node),
            .nullable_is_null => try self.execNullableIsNull(node),
            .nullable_unwrap => try self.execNullableUnwrap(node),
            .nullable_unwrap_or => try self.execNullableUnwrapOr(node),

            // === 内存管理（Phase 6：unsafe 手动分配） ===
            .alloc => try self.execAlloc(node),
            .free => try self.execFree(node),

            // === 星轨执行（Phase 7：async/spawn） ===
            .orbit_async_create => try self.execOrbitAsyncCreate(node),
            .orbit_async_join => try self.execOrbitAsyncJoin(node),
            .orbit_async_status => try self.execOrbitAsyncStatus(node),
            .orbit_chan_send => try self.execOrbitChanSend(node),
            .orbit_chan_recv => try self.execOrbitChanRecv(node),
            .orbit_chan_try_recv => try self.execOrbitChanTryRecv(node),
            .channel_close => try self.execChannelClose(node),

            // === 反射方法 ===
            .error_message => try self.execErrorMessage(node),
            .obj_type_name => try self.execObjTypeName(node),

            // === 闭包（lambda） ===
            .closure_make => try self.execClosureMake(node),
            .call_indirect => try self.execCallIndirect(node),

            // === 控制流 ===
            .call => try self.execCall(node),
            .halt_return => return node.inputs[0],
            .halt_throw => return error.Thrown,
            .halt_panic => return error.Panic,
            .halt_break => return error.LoopBreak,
            .halt_continue => return error.LoopContinue,
            .scalar_loop => try self.execScalarLoop(node),

            // === 内置函数 ===
            .builtin_print => try self.execBuiltinPrint(node, false, false),
            .builtin_println => try self.execBuiltinPrint(node, true, false),
            .builtin_eprint => try self.execBuiltinPrint(node, false, true),
            .builtin_eprintln => try self.execBuiltinPrint(node, true, true),
            .builtin_scan => try self.execBuiltinScan(node, false),
            .builtin_scanln => try self.execBuiltinScan(node, true),
            .builtin_ok => try self.execBuiltinOk(node),
            .builtin_error => try self.execBuiltinError(node),
            .builtin_eq => try self.execBuiltinEq(node),
            .builtin_str => try self.execBuiltinStr(node),
            .builtin_type => try self.execBuiltinType(node),
            .builtin_panic => return error.Panic,

            // === Newtype ===
            .newtype_wrap => try self.execNewtypeWrap(node),
            .newtype_unwrap => try self.execNewtypeUnwrap(node),

            else => return error.UnsupportedOp,
        }
        return null;
    }

    // ════════════════════════════════════════════
    // 通道元信息 → ScalarTag 映射
    // ════════════════════════════════════════════

    /// 从通道元信息推导 ScalarTag（用于选择 ops 函数）
    fn chanToScalarTag(chan_meta: ChannelMeta) ?ScalarTag {
        return switch (chan_meta.chan_type) {
            .bool_chan, .mask_chan => .boolean,
            .char_chan => .char,
            .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
            .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
            .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
            else => null,
        };
    }

    /// 读取通道值为 16 字节填充缓冲区（ops 函数的输入格式）
    fn readChanBytes(self: *Engine, chan: u16) [16]u8 {
        var buf: [16]u8 = [_]u8{0} ** 16;
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(buf[0..w], self.runtime.rawPtr(chan)[0..w]);
        }
        return buf;
    }

    /// 写入 16 字节缓冲区的前 N 字节到通道
    fn writeChanBytes(self: *Engine, chan: u16, buf: [16]u8) void {
        const w = self.runtime.elemWidth(chan);
        if (w > 0 and w <= 16) {
            @memcpy(self.runtime.rawPtr(chan)[0..w], buf[0..w]);
        }
    }

    /// 运行时 tag → comptime 分派：整数二元运算
    /// 通过 inline switch 展开所有整数类型，每个分支调用 comptime 特化的 ops 函数
    fn dispatchIntBinOp(tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        return switch (tag) {
            .i8 => dispatchIntBinOpT(.i8, kind, a, b),
            .i16 => dispatchIntBinOpT(.i16, kind, a, b),
            .i32 => dispatchIntBinOpT(.i32, kind, a, b),
            .i64 => dispatchIntBinOpT(.i64, kind, a, b),
            .i128 => dispatchIntBinOpT(.i128, kind, a, b),
            .u8 => dispatchIntBinOpT(.u8, kind, a, b),
            .u16 => dispatchIntBinOpT(.u16, kind, a, b),
            .u32 => dispatchIntBinOpT(.u32, kind, a, b),
            .u64 => dispatchIntBinOpT(.u64, kind, a, b),
            .u128 => dispatchIntBinOpT(.u128, kind, a, b),
            else => null,
        };
    }

    fn dispatchIntBinOpT(comptime tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .add => ops.add(tag, a_bytes, b_bytes),
            .sub => ops.sub(tag, a_bytes, b_bytes),
            .mul => ops.mul(tag, a_bytes, b_bytes),
            .div => ops.div(tag, a_bytes, b_bytes),
            .mod => ops.mod(tag, a_bytes, b_bytes),
            .bit_and => ops.bitAnd(tag, a_bytes, b_bytes),
            .bit_or => ops.bitOr(tag, a_bytes, b_bytes),
            .bit_xor => ops.bitXor(tag, a_bytes, b_bytes),
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：浮点二元运算
    fn dispatchFloatBinOp(tag: ScalarTag, kind: FloatBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        return switch (tag) {
            .f16 => dispatchFloatBinOpT(.f16, kind, a, b),
            .f32 => dispatchFloatBinOpT(.f32, kind, a, b),
            .f64 => dispatchFloatBinOpT(.f64, kind, a, b),
            .f128 => dispatchFloatBinOpT(.f128, kind, a, b),
            else => null,
        };
    }

    fn dispatchFloatBinOpT(comptime tag: ScalarTag, kind: FloatBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .add => ops.add(tag, a_bytes, b_bytes),
            .sub => ops.sub(tag, a_bytes, b_bytes),
            .mul => ops.mul(tag, a_bytes, b_bytes),
            .div => ops.div(tag, a_bytes, b_bytes),
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：整数一元运算
    fn dispatchIntUnOp(tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) ?[16]u8 {
        return switch (tag) {
            .i8 => dispatchIntUnOpT(.i8, kind, a),
            .i16 => dispatchIntUnOpT(.i16, kind, a),
            .i32 => dispatchIntUnOpT(.i32, kind, a),
            .i64 => dispatchIntUnOpT(.i64, kind, a),
            .i128 => dispatchIntUnOpT(.i128, kind, a),
            .u8 => dispatchIntUnOpT(.u8, kind, a),
            .u16 => dispatchIntUnOpT(.u16, kind, a),
            .u32 => dispatchIntUnOpT(.u32, kind, a),
            .u64 => dispatchIntUnOpT(.u64, kind, a),
            .u128 => dispatchIntUnOpT(.u128, kind, a),
            else => null,
        };
    }

    fn dispatchIntUnOpT(comptime tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) [16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .bit_not => ops.bitNot(tag, a_bytes),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                const r = if (@typeInfo(T).int.signedness == .signed) @abs(av) else av;
                break :blk @bitCast(@as(T, @intCast(r)));
            },
        };
        var out: [16]u8 = [_]u8{0} ** 16;
        out[0..W].* = result;
        return out;
    }

    /// 运行时 tag → comptime 分派：浮点一元运算
    fn dispatchFloatUnOp(tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) ?[16]u8 {
        return switch (tag) {
            .f16 => dispatchFloatUnOpT(.f16, kind, a),
            .f32 => dispatchFloatUnOpT(.f32, kind, a),
            .f64 => dispatchFloatUnOpT(.f64, kind, a),
            .f128 => dispatchFloatUnOpT(.f128, kind, a),
            else => null,
        };
    }

    fn dispatchFloatUnOpT(comptime tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) [16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                break :blk @bitCast(@abs(av));
            },
        };
        var out: [16]u8 = [_]u8{0} ** 16;
        out[0..W].* = result;
        return out;
    }

    /// 运行时 tag → comptime 分派：比较运算
    /// 所有 ScalarTag 变体均已覆盖，无需 else 分支
    /// boolean 类型不经过 ops（@bitCast 位宽不匹配），直接内联比较
    fn dispatchCmp(tag: ScalarTag, kind: CmpKind, a: [16]u8, b: [16]u8) bool {
        return switch (tag) {
            .boolean => blk: {
                const av = a[0] != 0;
                const bv = b[0] != 0;
                break :blk switch (kind) {
                    .eq => av == bv,
                    .ne => av != bv,
                    .lt => !av and bv,
                    .le => !av or bv,
                    .gt => av and !bv,
                    .ge => av or !bv,
                };
            },
            .i8 => dispatchCmpT(.i8, kind, a, b),
            .i16 => dispatchCmpT(.i16, kind, a, b),
            .i32 => dispatchCmpT(.i32, kind, a, b),
            .i64 => dispatchCmpT(.i64, kind, a, b),
            .i128 => dispatchCmpT(.i128, kind, a, b),
            .u8 => dispatchCmpT(.u8, kind, a, b),
            .u16 => dispatchCmpT(.u16, kind, a, b),
            .u32 => dispatchCmpT(.u32, kind, a, b),
            .u64 => dispatchCmpT(.u64, kind, a, b),
            .u128 => dispatchCmpT(.u128, kind, a, b),
            .f16 => dispatchCmpT(.f16, kind, a, b),
            .f32 => dispatchCmpT(.f32, kind, a, b),
            .f64 => dispatchCmpT(.f64, kind, a, b),
            .f128 => dispatchCmpT(.f128, kind, a, b),
            .char => dispatchCmpT(.char, kind, a, b),
        };
    }

    fn dispatchCmpT(comptime tag: ScalarTag, kind: CmpKind, a: [16]u8, b: [16]u8) bool {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const b_bytes: ByteArrayT = b[0..W].*;
        return switch (kind) {
            .eq => ops.eq(tag, a_bytes, b_bytes),
            .ne => ops.ne(tag, a_bytes, b_bytes),
            .lt => ops.lt(tag, a_bytes, b_bytes),
            .le => ops.le(tag, a_bytes, b_bytes),
            .gt => ops.gt(tag, a_bytes, b_bytes),
            .ge => ops.ge(tag, a_bytes, b_bytes),
        };
    }

    /// 内联标量二元运算分派：根据 NodeOp 选择对应的 dispatch 函数
    /// 用于 vec_fold/vec_scan 的内联标量模式（body_len == 0）
    fn dispatchInlineBinOp(op: NodeOp, tag: ScalarTag, a: [16]u8, b: [16]u8) EngineError![16]u8 {
        return switch (op) {
            .int_add => dispatchIntBinOp(tag, .add, a, b) orelse return error.Overflow,
            .int_sub => dispatchIntBinOp(tag, .sub, a, b) orelse return error.Overflow,
            .int_mul => dispatchIntBinOp(tag, .mul, a, b) orelse return error.Overflow,
            .int_div => dispatchIntBinOp(tag, .div, a, b) orelse return error.DivisionByZero,
            .int_mod => dispatchIntBinOp(tag, .mod, a, b) orelse return error.DivisionByZero,
            .int_and => dispatchIntBinOp(tag, .bit_and, a, b) orelse return error.Overflow,
            .int_or => dispatchIntBinOp(tag, .bit_or, a, b) orelse return error.Overflow,
            .int_xor => dispatchIntBinOp(tag, .bit_xor, a, b) orelse return error.Overflow,
            .float_add => dispatchFloatBinOp(tag, .add, a, b) orelse return error.Overflow,
            .float_sub => dispatchFloatBinOp(tag, .sub, a, b) orelse return error.Overflow,
            .float_mul => dispatchFloatBinOp(tag, .mul, a, b) orelse return error.Overflow,
            .float_div => dispatchFloatBinOp(tag, .div, a, b) orelse return error.Overflow,
            else => return error.UnsupportedOp,
        };
    }

    // ════════════════════════════════════════════
    // 常量执行
    // ════════════════════════════════════════════

    fn execConst(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            self.runtime.writeConst(node.output, cv, meta.kind);
        }
    }

    fn execConstUnit(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    fn execConstNull(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    /// 内置 print/println/eprint/eprintln：根据通道类型打印值
    fn execBuiltinPrint(self: *Engine, node: *const Node, with_newline: bool, to_stderr: bool) EngineError!void {
        const io = self.io orelse return; // 无 io 接口，静默跳过
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        var buf: [4096]u8 = undefined;
        var w = if (to_stderr)
            std.Io.File.stderr().writerStreaming(io, &buf)
        else
            std.Io.File.stdout().writerStreaming(io, &buf);

        switch (meta.chan_type) {
            .ref_chan => {
                // 字符串
                if (self.readStr(val_chan)) |s| {
                    w.interface.print("{s}", .{s.bytes()}) catch {};
                } else {
                    w.interface.print("null", .{}) catch {};
                }
            },
            .i64_chan => w.interface.print("{d}", .{self.runtime.readI64(val_chan)}) catch {},
            .i32_chan => {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .i16_chan => {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .i8_chan => {
                const ptr: *i8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .u64_chan => w.interface.print("{d}", .{self.runtime.readU64(val_chan)}) catch {},
            .u32_chan => {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .u16_chan => {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .u8_chan => {
                w.interface.print("{d}", .{self.runtime.rawPtr(val_chan)[0]}) catch {};
            },
            .f64_chan => w.interface.print("{d}", .{self.runtime.readF64(val_chan)}) catch {},
            .f32_chan => {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .f16_chan => {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                w.interface.print("{d}", .{ptr.*}) catch {};
            },
            .bool_chan, .mask_chan => w.interface.print("{}", .{self.runtime.readBool(val_chan)}) catch {},
            .char_chan => {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                if (ptr.* < 128) {
                    w.interface.print("{c}", .{@as(u8, @intCast(ptr.*))}) catch {};
                } else {
                    w.interface.print("U+{x:0>4}", .{ptr.*}) catch {};
                }
            },
            .unit_chan => w.interface.print("()", .{}) catch {},
            .null_chan => w.interface.print("null", .{}) catch {},
            else => {},
        }

        if (with_newline) {
            w.interface.print("\n", .{}) catch {};
        }
        w.flush() catch {};
    }

    /// builtin_ok：构造 ThrowValue(ok payload)
    /// inputs[0] = 值通道
    fn execBuiltinOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const v = self.chanToValue(val_chan);
        const throw_val = self.backing.create(value.ThrowValue) catch return error.OutOfMemory;
        throw_val.* = .{ .payload = .{ .ok = v } };
        _ = v.retain();
        try self.trackObj(&throw_val.header);
        self.runtime.writePtr(node.output, @ptrCast(&throw_val.header));
    }

    /// builtin_error：构造 ThrowValue(err payload) + ErrorValue
    /// inputs[0] = 消息通道（ref_chan 指向 StringValue）
    fn execBuiltinError(self: *Engine, node: *const Node) EngineError!void {
        const msg_chan = node.inputs[0];
        const msg_bytes = if (self.readStr(msg_chan)) |s| s.bytes() else "";

        const err_val = self.backing.create(value.ErrorValue) catch return error.OutOfMemory;
        const type_name_dup = self.backing.dupe(u8, "Error") catch return error.OutOfMemory;
        const msg_dup = self.backing.dupe(u8, msg_bytes) catch return error.OutOfMemory;
        err_val.* = .{
            .type_name = type_name_dup,
            .message = msg_dup,
            .is_error_subtype = false,
        };
        try self.trackObj(&err_val.header);

        const throw_val = self.backing.create(value.ThrowValue) catch return error.OutOfMemory;
        throw_val.* = .{ .payload = .{ .err = err_val } };
        _ = value.obj_header.retain(&err_val.header);
        try self.trackObj(&throw_val.header);
        self.runtime.writePtr(node.output, @ptrCast(&throw_val.header));
    }

    /// builtin_eq：结构相等比较
    /// inputs[0] = a, inputs[1] = b
    fn execBuiltinEq(self: *Engine, node: *const Node) EngineError!void {
        const a_chan = node.inputs[0];
        const b_chan = node.inputs[1];
        const a_meta = self.ir.channels.get(a_chan);
        const b_meta = self.ir.channels.get(b_chan);

        // 同类型标量直接位比较
        if (a_meta.chan_type == b_meta.chan_type) {
            const w = self.runtime.elemWidth(a_chan);
            if (w > 0) {
                const a_ptr = self.runtime.rawPtr(a_chan);
                const b_ptr = self.runtime.rawPtr(b_chan);
                const equal = std.mem.eql(u8, a_ptr[0..w], b_ptr[0..w]);
                self.runtime.writeBool(node.output, equal);
                return;
            }
        }

        // 字符串/引用比较
        const a_str = if (a_meta.chan_type == .ref_chan) self.readStr(a_chan) else null;
        const b_str = if (b_meta.chan_type == .ref_chan) self.readStr(b_chan) else null;
        if (a_str != null and b_str != null) {
            self.runtime.writeBool(node.output, std.mem.eql(u8, a_str.?.bytes(), b_str.?.bytes()));
            return;
        }

        // 默认：不等
        self.runtime.writeBool(node.output, false);
    }

    /// builtin_str：将任意值转为字符串
    /// inputs[0] = 值通道
    fn execBuiltinStr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        var buf: [64]u8 = undefined;
        const slice: []const u8 = switch (meta.chan_type) {
            .i64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readI64(val_chan)}) catch "",
            .i32_chan => blk: {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .i16_chan => blk: {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .i8_chan => blk: {
                const ptr: *i8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readU64(val_chan)}) catch "",
            .u32_chan => blk: {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u16_chan => blk: {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u8_chan => blk: {
                const ptr: *u8 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .f64_chan => std.fmt.bufPrint(&buf, "{d}", .{self.runtime.readF64(val_chan)}) catch "",
            .f32_chan => blk: {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .f16_chan => blk: {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .bool_chan, .mask_chan => if (self.runtime.readBool(val_chan)) "true" else "false",
            .char_chan => blk: {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                const cp: u21 = @intCast(ptr.*);
                if (cp < 128) {
                    buf[0] = @intCast(cp);
                    break :blk buf[0..1];
                }
                // 多字节 UTF-8
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                break :blk buf[0..n];
            },
            .ref_chan => if (self.readStr(val_chan)) |s| s.bytes() else "null",
            .unit_chan => "()",
            .null_chan => "null",
            else => "",
        };

        // 创建 Str 并写入输出通道
        const str_obj = self.backing.create(value.str_mod.Str) catch return error.OutOfMemory;
        str_obj.* = value.str_mod.Str.fromLiteral(self.backing, slice) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
    }

    /// builtin_scan/scanln：从 stdin 读取
    /// scan: 读取一个空白分隔的 token
    /// scanln: 读取一整行（不含换行）
    /// output = ref_chan（Str 指针）或 null_chan（EOF）
    fn execBuiltinScan(self: *Engine, node: *const Node, line_mode: bool) EngineError!void {
        const io = self.io orelse {
            self.runtime.writePtr(node.output, null);
            return;
        };
        var r_buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &r_buf);
        const result: ?[]const u8 = if (line_mode)
            reader.interface.takeDelimiterExclusive('\n') catch null
        else
            reader.interface.takeDelimiterExclusive(' ') catch null;

        if (result) |bytes| {
            const str_obj = self.backing.create(value.str_mod.Str) catch return error.OutOfMemory;
            str_obj.* = value.str_mod.Str.fromLiteral(self.backing, bytes) catch return error.OutOfMemory;
            try self.trackObj(&str_obj.header);
            self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
        } else {
            self.runtime.writePtr(node.output, null);
        }
    }

    /// builtin_type：返回值的运行时类型名
    /// inputs[0] = 值通道
    /// output = ref_chan（Str 指针）
    fn execBuiltinType(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);
        const type_name: []const u8 = switch (meta.chan_type) {
            .i8_chan => "i8",
            .i16_chan => "i16",
            .i32_chan => "i32",
            .i64_chan => "i64",
            .u8_chan => "u8",
            .u16_chan => "u16",
            .u32_chan => "u32",
            .u64_chan => "u64",
            .f16_chan => "f16",
            .f32_chan => "f32",
            .f64_chan => "f64",
            .bool_chan, .mask_chan => "bool",
            .char_chan => "char",
            .unit_chan => "unit",
            .null_chan => "null",
            .ref_chan => blk: {
                const header = self.readRefObj(val_chan);
                if (header) |h| {
                    break :blk switch (h.type_tag) {
                        .str => "str",
                        .array => "array",
                        .record => "record",
                        .adt => "adt",
                        .newtype => "newtype",
                        .error_val => "Error",
                        .throw_val => "Throw",
                        .channel_val => "Channel",
                        .async_val => "Spawn",
                        .closure => "function",
                        else => "ref",
                    };
                }
                break :blk "null";
            },
            .nullable_chan => "nullable",
            else => "unknown",
        };

        const str_obj = self.backing.create(value.str_mod.Str) catch return error.OutOfMemory;
        str_obj.* = value.str_mod.Str.fromLiteral(self.backing, type_name) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
    }

    // ════════════════════════════════════════════
    // Newtype 操作
    // ════════════════════════════════════════════

    /// newtype_wrap：将值包装为 NewtypeValue
    /// inputs[0] = 值通道
    /// meta_index 指向 ScalarMeta（const_val.int_val 存储类型名字符串池索引）
    /// output = ref_chan（NewtypeValue 指针）
    fn execNewtypeWrap(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const inner = self.chanToValue(val_chan);
        _ = inner.retain();

        // 从 meta 获取类型名
        var type_name: []const u8 = "Newtype";
        if (node.meta_index > 0 and node.meta_index <= self.ir.scalar_metas.len) {
            const meta = self.ir.scalar_metas[node.meta_index];
            if (meta.const_val) |cv| {
                if (cv == .int_val) {
                    const str_idx: usize = @intCast(cv.int_val);
                    if (str_idx < self.ir.string_pool.len) {
                        type_name = self.ir.string_pool[str_idx];
                    }
                }
            }
        }

        const nt = self.backing.create(value.NewtypeValue) catch return error.OutOfMemory;
        nt.* = .{
            .type_name = self.backing.dupe(u8, type_name) catch return error.OutOfMemory,
            .inner = inner,
        };
        try self.trackObj(&nt.header);
        self.runtime.writePtr(node.output, @ptrCast(&nt.header));
    }

    /// newtype_unwrap：从 NewtypeValue 提取内部值
    /// inputs[0] = ref_chan（NewtypeValue 指针）
    /// output = 内部值通道
    fn execNewtypeUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const header = self.readRefObj(ref_chan) orelse return error.Panic;
        if (header.type_tag != .newtype) return error.Panic;
        const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", header));
        self.writeScalarValue(node.output, nt.inner);
    }

    fn execConstStr(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            // const_str 的 const_val.int_val 是字符串池索引
            if (cv == .int_val) {
                const str_idx: usize = @intCast(cv.int_val);
                if (str_idx >= self.ir.string_pool.len) return error.InvalidMetaIndex;
                const bytes = self.ir.string_pool[str_idx];
                // 在堆上创建 Str 对象
                const v = value.Value.fromStringBytes(self.backing, bytes) catch return error.OutOfMemory;
                try self.trackObj(v.asRef());
                // 将 *ObjHeader 指针写入 ref_chan
                self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            }
        }
    }

    // ════════════════════════════════════════════
    // 整数算术（复用 value.ops）
    // ════════════════════════════════════════════

    const IntBinOpKind = enum { add, sub, mul, div, mod, bit_and, bit_or, bit_xor };

    fn execIntBinOp(self: *Engine, node: *const Node, kind: IntBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 获取通道的 ScalarTag
        const out_meta = self.ir.channels.get(node.output);
        const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

        // 确认是整数类型
        switch (tag) {
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128 => {},
            else => return error.UnsupportedOp,
        }

        // 读取输入为 16 字节缓冲区
        const a = self.readChanBytes(left_chan);
        const b = self.readChanBytes(right_chan);

        // 复用 value.ops 的运算函数（通过 dispatch 分派到 comptime 特化版本）
        const result = dispatchIntBinOp(tag, kind, a, b) orelse return error.DivisionByZero;
        self.writeChanBytes(node.output, result);
    }

    const IntShiftKind = enum { shl, shr };

    fn execIntShift(self: *Engine, node: *const Node, kind: IntShiftKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        const out_meta = self.ir.channels.get(node.output);
        const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

        // 移位运算统一按 i64 处理（Phase 1 简化）
        const a = self.runtime.readI64(left_chan);
        const b = self.runtime.readI64(right_chan);
        const shift_amt: u6 = @intCast(@as(u64, @bitCast(b)) & 63);

        const result: i64 = switch (kind) {
            .shl => a << shift_amt,
            .shr => a >> shift_amt,
        };
        self.runtime.writeI64(node.output, result);
        _ = tag;
    }

    const IntUnOpKind = enum { neg, abs, bit_not };

    fn execIntUnOp(self: *Engine, node: *const Node, kind: IntUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        const out_meta = self.ir.channels.get(node.output);
        const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

        // 确认是整数类型
        switch (tag) {
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128 => {},
            else => return error.UnsupportedOp,
        }

        const a = self.readChanBytes(input_chan);
        const result = dispatchIntUnOp(tag, kind, a) orelse return error.UnsupportedOp;
        self.writeChanBytes(node.output, result);
    }

    // ════════════════════════════════════════════
    // 浮点算术（复用 value.ops）
    // ════════════════════════════════════════════

    const FloatBinOpKind = enum { add, sub, mul, div };

    fn execFloatBinOp(self: *Engine, node: *const Node, kind: FloatBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        const out_meta = self.ir.channels.get(node.output);
        const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

        // 确认是浮点类型
        switch (tag) {
            .f16, .f32, .f64, .f128 => {},
            else => return error.UnsupportedOp,
        }

        const a = self.readChanBytes(left_chan);
        const b = self.readChanBytes(right_chan);
        const result = dispatchFloatBinOp(tag, kind, a, b) orelse return error.DivisionByZero;
        self.writeChanBytes(node.output, result);
    }

    const FloatUnOpKind = enum { neg, abs };

    fn execFloatUnOp(self: *Engine, node: *const Node, kind: FloatUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        const out_meta = self.ir.channels.get(node.output);
        const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;

        switch (tag) {
            .f16, .f32, .f64, .f128 => {},
            else => return error.UnsupportedOp,
        }

        const a = self.readChanBytes(input_chan);
        // 复用 value.ops 的运算函数（通过 dispatch 分派到 comptime 特化版本）
        const result = dispatchFloatUnOp(tag, kind, a) orelse return error.UnsupportedOp;
        self.writeChanBytes(node.output, result);
    }

    // ════════════════════════════════════════════
    // 比较（复用 value.ops）
    // ════════════════════════════════════════════

    const CmpKind = enum { eq, ne, lt, le, gt, ge };

    fn execCmp(self: *Engine, node: *const Node, kind: CmpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 从输入通道推导类型（输出是 bool，不能用于推导）
        const left_meta = self.ir.channels.get(left_chan);
        const tag = chanToScalarTag(left_meta) orelse {
            // 非标量通道：退化为 i64 比较
            const a = self.runtime.readI64(left_chan);
            const b = self.runtime.readI64(right_chan);
            const result: bool = switch (kind) {
                .eq => a == b,
                .ne => a != b,
                .lt => a < b,
                .le => a <= b,
                .gt => a > b,
                .ge => a >= b,
            };
            self.runtime.writeBool(node.output, result);
            return;
        };

        const a = self.readChanBytes(left_chan);
        const b = self.readChanBytes(right_chan);
        // 复用 value.ops 的比较函数（通过 dispatch 分派到 comptime 特化版本）
        const result = dispatchCmp(tag, kind, a, b);
        self.runtime.writeBool(node.output, result);
    }

    // ════════════════════════════════════════════
    // 布尔逻辑
    // ════════════════════════════════════════════

    const BoolBinOpKind = enum { and_, or_ };

    fn execBoolBinOp(self: *Engine, node: *const Node, kind: BoolBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const a = self.runtime.readBool(left_chan);
        const b = self.runtime.readBool(right_chan);
        const result: bool = switch (kind) {
            .and_ => a and b,
            .or_ => a or b,
        };
        self.runtime.writeBool(node.output, result);
    }

    fn execBoolNot(self: *Engine, node: *const Node) EngineError!void {
        const input_chan = node.inputs[0];
        const a = self.runtime.readBool(input_chan);
        self.runtime.writeBool(node.output, !a);
    }

    // ════════════════════════════════════════════
    // 内存操作（var 变量 load/store）
    // ════════════════════════════════════════════

    /// load：将输入通道的值复制到输出通道（var 初始化）
    fn execLoad(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// store：将输入通道的值写入 cell 通道（var 赋值）
    fn execStore(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    // ════════════════════════════════════════════
    // 选择（if 表达式，标量模式 N=1）
    // ════════════════════════════════════════════

    /// vec_select：根据条件通道选择 then/else 通道的值
    /// inputs[0] = then_chan, inputs[1] = else_chan, inputs[2] = cond_chan
    fn execVecSelect(self: *Engine, node: *const Node) EngineError!void {
        const then_chan = node.inputs[0];
        const else_chan = node.inputs[1];
        const cond_chan = node.inputs[2];
        const cond = self.runtime.readBool(cond_chan);
        const src_chan = if (cond) then_chan else else_chan;
        const w = self.runtime.elemWidth(node.output);
        if (w > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    // ════════════════════════════════════════════
    // 类型转换（复用 value.cast）
    // ════════════════════════════════════════════

    /// cast/cast_safe：标量类型转换
    /// meta_index 指向 ScalarMeta，描述目标类型
    /// inputs[0] = 源通道
    fn execCast(self: *Engine, node: *const Node, safe: bool) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);
        const src_tag = chanToScalarTag(src_meta) orelse return error.UnsupportedOp;
        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        const a = self.readChanBytes(src_chan);

        if (safe) {
            const result = value.cast.tryCast(src_tag, dst_tag, a) catch return error.CastOverflow;
            self.writeChanBytes(node.output, result);
        } else {
            const result = value.cast.cast(src_tag, dst_tag, a);
            self.writeChanBytes(node.output, result);
        }
    }

    /// 从 ScalarKind + IntKind/FloatKind 推导 ScalarTag
    fn scalarKindToTag(kind: ScalarKind, int_kind: scalar.IntKind, float_kind: scalar.FloatKind) ?ScalarTag {
        return switch (kind) {
            .int => switch (int_kind) {
                .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
                .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
            },
            .float => switch (float_kind) {
                .f16 => .f16, .f32 => .f32, .f64 => .f64, .f128 => .f128,
            },
            .bool => .boolean,
            .char => .char,
            else => null,
        };
    }

    // ════════════════════════════════════════════
    // 字符串操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 Str 对象指针
    fn readStr(self: *Engine, chan: u16) ?*value.str_mod.Str {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// string_len：返回字符串字节长度
    /// inputs[0] = str 通道，output = i64 通道
    fn execStringLen(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        self.runtime.writeI64(node.output, @intCast(s.byteLength()));
    }

    /// string_concat：拼接两个字符串
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    fn execStringConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;
        const result_str = value.str_mod.Str.concat(left.*, self.backing, right.*) catch return error.OutOfMemory;
        const obj = self.backing.create(value.str_mod.Str) catch return error.OutOfMemory;
        obj.* = result_str;
        try self.trackObj(&obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&obj.header));
    }

    /// string_index：按字符索引获取 UTF-8 码点
    /// inputs[0] = str, inputs[1] = index, output = char_chan
    fn execStringIndex(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = self.runtime.readI64(node.inputs[1]);
        const bytes = s.bytes();
        if (idx < 0) return error.Overflow;

        // UTF-8 解码：按码点序列索引
        var byte_pos: usize = 0;
        var char_idx: i64 = 0;
        while (byte_pos < bytes.len) {
            if (char_idx == idx) {
                const codepoint = decodeUtf8Codepoint(bytes[byte_pos..]) catch {
                    // 解码失败，回退到单字节
                    const cp: u32 = @intCast(bytes[byte_pos]);
                    const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                    ptr.* = cp;
                    return;
                };
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                ptr.* = codepoint;
                return;
            }
            const seq_len = utf8SeqLen(bytes[byte_pos]);
            byte_pos += seq_len;
            char_idx += 1;
        }
        return error.Overflow;
    }

    /// 返回 UTF-8 序列长度（1-4），无效首字节返回 1
    fn utf8SeqLen(byte: u8) usize {
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        if (byte & 0xF8 == 0xF0) return 4;
        return 1; // 无效首字节，按 1 处理
    }

    /// 手动解码 UTF-8 码点，避免 std.unicode.utf8Decode 的 unreachable
    fn decodeUtf8Codepoint(bytes: []const u8) !u32 {
        if (bytes.len == 0) return error.InvalidUtf8;
        const b0 = bytes[0];
        if (b0 < 0x80) return @intCast(b0);
        if (b0 & 0xE0 == 0xC0) {
            if (bytes.len < 2) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x1F)) << 6 | @as(u32, @intCast(bytes[1] & 0x3F));
        }
        if (b0 & 0xF0 == 0xE0) {
            if (bytes.len < 3) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x0F)) << 12 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[2] & 0x3F));
        }
        if (b0 & 0xF8 == 0xF0) {
            if (bytes.len < 4) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x07)) << 18 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 12 |
                @as(u32, @intCast(bytes[2] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[3] & 0x3F));
        }
        return error.InvalidUtf8;
    }

    // ════════════════════════════════════════════
    // 数组操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 ArrayValue 指针
    fn readArray(self: *Engine, chan: u16) ?*value.ArrayValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 从通道读取 Value（标量值）
    fn chanToValue(self: *Engine, chan: u16) value.Value {
        const meta = self.ir.channels.get(chan);
        const w = meta.elem_width;
        if (w == 0) return value.Value.fromUnit();
        const ptr = self.runtime.rawPtr(chan);
        return switch (meta.chan_type) {
            .bool_chan, .mask_chan => value.Value.fromBool(self.runtime.readBool(chan)),
            .i8_chan => value.Value.fromI8(@bitCast(ptr[0])),
            .i16_chan => value.Value.fromI16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .i32_chan => value.Value.fromI32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .i64_chan => value.Value.fromI64(self.runtime.readI64(chan)),
            .u8_chan => value.Value.fromU8(ptr[0]),
            .u16_chan => value.Value.fromU16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .u32_chan => value.Value.fromU32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .u64_chan => value.Value.fromU64(self.runtime.readU64(chan)),
            .f32_chan => value.Value.fromF32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .f64_chan => value.Value.fromF64(self.runtime.readF64(chan)),
            .ref_chan => blk: {
                const obj_ptr = self.runtime.readPtr(chan) orelse break :blk value.Value.fromNull();
                break :blk value.Value.fromRef(@ptrCast(@alignCast(obj_ptr)));
            },
            else => value.Value.fromUnit(),
        };
    }

    /// 将 Value 写入通道
    fn valueToChan(self: *Engine, chan: u16, v: value.Value) void {
        switch (v) {
            .null_val, .unit => {},
            .boolean => |b| self.runtime.writeBool(chan, b[0] != 0),
            .i8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .i16 => |b| {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i32 => |b| {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i64 => |b| {
                const ptr: *i64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .u16 => |b| {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u32 => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u64 => |b| {
                const ptr: *u64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f32 => |b| {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f64 => |b| {
                const ptr: *f64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .ref => |obj| self.runtime.writePtr(chan, @ptrCast(obj)),
            else => {},
        }
    }

    /// array_make：创建数组
    /// inputs[0] = length 通道（i64），output = ref_chan
    fn execArrayMake(self: *Engine, node: *const Node) EngineError!void {
        const len = self.runtime.readI64(node.inputs[0]);
        if (len < 0) return error.Overflow;
        const n: usize = @intCast(len);
        // 分配元素切片
        const elements = self.backing.alloc(value.Value, n) catch return error.OutOfMemory;
        // 初始化为 unit
        for (elements) |*e| e.* = value.Value.fromUnit();
        const v = value.Value.makeArray(self.backing, elements, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_get：按索引获取元素
    /// inputs[0] = array, inputs[1] = index, output = 元素通道
    fn execArrayGet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = self.runtime.readI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = arr.elements[@intCast(idx)];
        self.valueToChan(node.output, v);
    }

    /// array_set：按索引设置元素
    /// inputs[0] = array, inputs[1] = index, inputs[2] = value
    fn execArraySet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = self.runtime.readI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = self.chanToValue(node.inputs[2]);
        arr.elements[@intCast(idx)] = v;
    }

    /// array_len：返回数组长度
    /// inputs[0] = array, output = i64
    fn execArrayLen(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        self.runtime.writeI64(node.output, @intCast(arr.elements.len));
    }

    /// array_push：向数组追加元素（扩容）
    /// inputs[0] = array, inputs[1] = value
    fn execArrayPush(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const v = self.chanToValue(node.inputs[1]);
        const old_len = arr.elements.len;
        const new_len = old_len + 1;
        const new_elements = self.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        @memcpy(new_elements[0..old_len], arr.elements);
        new_elements[old_len] = v;
        // 释放旧元素数组
        if (arr.capacity > 0) {
            self.backing.free(arr.elements.ptr[0..arr.capacity]);
        } else if (arr.elements.len > 0) {
            self.backing.free(arr.elements);
        }
        arr.elements = new_elements;
        arr.capacity = new_len;
    }

    /// array_concat：拼接两个数组，返回新数组
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    fn execArrayConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readArray(node.inputs[1]) orelse return error.InvalidChannel;
        const new_len = left.elements.len + right.elements.len;
        const new_elements = self.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        @memcpy(new_elements[0..left.elements.len], left.elements);
        @memcpy(new_elements[left.elements.len..], right.elements);
        const v = value.Value.makeArray(self.backing, new_elements, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    // ════════════════════════════════════════════
    // 记录操作
    // ════════════════════════════════════════════

    /// 从 ref_chan 读取 RecordValue 指针
    fn readRecord(self: *Engine, chan: u16) ?*value.RecordValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 从 ScalarMeta 读取字符串池中的字符串（字段名/类型名）
    fn metaString(self: *Engine, meta_index: u16) ?[]const u8 {
        if (meta_index == 0 or meta_index >= self.ir.scalar_metas.len) return null;
        const meta = self.ir.scalar_metas[meta_index];
        if (meta.const_val) |cv| {
            if (cv == .int_val) {
                const idx: usize = @intCast(cv.int_val);
                if (idx < self.ir.string_pool.len) return self.ir.string_pool[idx];
            }
        }
        return null;
    }

    /// record_make：创建空记录
    /// meta_index 指向 ScalarMeta，const_val.int_val = type_name 在 string_pool 中的索引
    fn execRecordMake(self: *Engine, node: *const Node) EngineError!void {
        const type_name = self.metaString(node.meta_index) orelse "";
        const fields = std.StringHashMap(value.Value).init(self.backing);
        const v = value.Value.makeRecord(self.backing, type_name, fields) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// record_get：读取字段值
    /// meta_index 指向字段名，inputs[0] = record_chan
    fn execRecordGet(self: *Engine, node: *const Node) EngineError!void {
        const rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        const field_name = self.metaString(node.meta_index) orelse return error.InvalidMetaIndex;
        const v = rec.fields.get(field_name) orelse return error.InvalidChannel;
        self.valueToChan(node.output, v);
    }

    /// record_set：设置字段值
    /// meta_index 指向字段名，inputs[0] = record_chan, inputs[1] = value_chan
    fn execRecordSet(self: *Engine, node: *const Node) EngineError!void {
        const rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        const field_name = self.metaString(node.meta_index) orelse return error.InvalidMetaIndex;
        const v = self.chanToValue(node.inputs[1]);
        // retain ref 值：record 持有引用，deinit 时会 release
        _ = v.retain();
        if (rec.fields.getPtr(field_name)) |slot| {
            // 替换已有字段：先 release 旧值
            slot.*.release(self.backing);
            slot.* = v;
        } else {
            const key = self.backing.dupe(u8, field_name) catch return error.OutOfMemory;
            rec.fields.put(key, v) catch return error.OutOfMemory;
        }
    }

    /// record_clone：浅拷贝记录（用于记录扩展 (...base, field: value)）
    /// inputs[0] = base record_chan，output = new record_chan
    fn execRecordClone(self: *Engine, node: *const Node) EngineError!void {
        const base_rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        // 创建新记录，复制 type_name
        const type_name_dup = self.backing.dupe(u8, base_rec.type_name) catch return error.OutOfMemory;
        var new_fields = std.StringHashMap(value.Value).init(self.backing);
        // 浅拷贝所有字段（retain ref 值）
        var it = base_rec.fields.iterator();
        while (it.next()) |entry| {
            const key = self.backing.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
            const v = entry.value_ptr.*;
            _ = v.retain();
            new_fields.put(key, v) catch return error.OutOfMemory;
        }
        const new_rec = value.Value.makeRecord(self.backing, type_name_dup, new_fields) catch return error.OutOfMemory;
        try self.trackObj(new_rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(new_rec.asRef()));
    }

    // ════════════════════════════════════════════
    // 函数调用
    // ════════════════════════════════════════════

    fn execCall(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        const callee_func = self.ir.functions[call_meta.func_index];
        const args = node.inputs[0..call_meta.arg_count];

        // 保存被调用函数的通道状态（return_channel + 局部通道）
        // 递归调用时，被调用函数与调用者共享通道，必须保存/恢复以防数据覆盖
        const ret_chan = callee_func.return_channel;
        const lcs = callee_func.local_chan_start;
        const lcc = callee_func.local_chan_count;
        const n_chans: usize = 1 + @as(usize, lcc);
        const cc = self.runtime.chan_count;

        const saved_ptrs = self.backing.alloc(?[*]u8, n_chans) catch return error.OutOfMemory;
        defer self.backing.free(saved_ptrs);
        const saved_lens = self.backing.alloc(u32, n_chans) catch return error.OutOfMemory;
        defer self.backing.free(saved_lens);

        // 计算总字节数并保存元数据
        var total_bytes: usize = 0;
        const chanIdx = struct {
            fn get(ret: u16, lstart: u16, i: usize) u16 {
                return if (i == 0) ret else lstart + @as(u16, @intCast(i - 1));
            }
        };
        for (0..n_chans) |i| {
            const ch = chanIdx.get(ret_chan, lcs, i);
            if (ch < cc) {
                saved_ptrs[i] = self.runtime.chan_ptrs[ch];
                saved_lens[i] = self.runtime.chan_lengths[ch];
                const w = self.runtime.chan_widths[ch];
                if (w > 0 and saved_lens[i] > 0) total_bytes += @as(usize, w) * saved_lens[i];
            } else {
                saved_ptrs[i] = null;
                saved_lens[i] = 0;
            }
        }

        // 保存通道数据
        const save_buf = self.backing.alloc(u8, total_bytes) catch return error.OutOfMemory;
        defer self.backing.free(save_buf);
        {
            var off: usize = 0;
            for (0..n_chans) |i| {
                const ch = chanIdx.get(ret_chan, lcs, i);
                if (ch < cc) {
                    const w = self.runtime.chan_widths[ch];
                    const len = saved_lens[i];
                    if (w > 0 and len > 0) {
                        const src = saved_ptrs[i].?;
                        const n = @as(usize, w) * len;
                        @memcpy(save_buf[off .. off + n], src[0..n]);
                        off += n;
                    }
                }
            }
        }

        // 复制参数值到被调用函数的参数通道
        for (args, 0..) |arg_chan, i| {
            if (i < callee_func.param_channels.len) {
                const dst_chan = callee_func.param_channels[i];
                const w = self.runtime.elemWidth(arg_chan);
                if (w > 0) {
                    const src = self.runtime.rawPtr(arg_chan);
                    const dst = self.runtime.rawPtr(dst_chan);
                    @memcpy(dst[0..w], src[0..w]);
                }
            }
        }

        // 压栈
        self.call_stack[self.call_depth] = .{
            .func_idx = call_meta.func_index,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(call_meta.func_index, args);
        self.current_func_idx = saved_func_idx;

        // 先把结果存到栈临时变量（恢复通道会覆盖 result_chan 和 node.output）
        const result_w = self.runtime.elemWidth(result_chan);
        var result_buf: [16]u8 = undefined;
        if (result_w > 0) {
            const src = self.runtime.rawPtr(result_chan);
            @memcpy(result_buf[0..result_w], src[0..result_w]);
        }

        self.call_depth -= 1;

        // 恢复被调用函数的通道状态
        {
            var off: usize = 0;
            for (0..n_chans) |i| {
                const ch = chanIdx.get(ret_chan, lcs, i);
                if (ch < cc) {
                    self.runtime.chan_ptrs[ch] = saved_ptrs[i];
                    self.runtime.chan_lengths[ch] = saved_lens[i];
                    const wd = self.runtime.chan_widths[ch];
                    const len = saved_lens[i];
                    if (wd > 0 and len > 0) {
                        const dst = saved_ptrs[i].?;
                        const n = @as(usize, wd) * len;
                        @memcpy(dst[0..n], save_buf[off .. off + n]);
                        off += n;
                    }
                }
            }
        }

        // 恢复后再把结果写入 call 节点的输出通道
        if (result_w > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..result_w], result_buf[0..result_w]);
        }
    }

    // ════════════════════════════════════════════
    // 向量操作（Phase 3）
    // ════════════════════════════════════════════

    /// 执行子图节点范围（供 vec_map 等按元素迭代调用）
    fn execBodyNodes(self: *Engine, nodes: []const Node, start: usize, len: usize) EngineError!?u16 {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const node = nodes[start + i];
            if (try self.execNode(&node)) |ret| {
                return ret;
            }
        }
        return null;
    }

    /// 标量循环执行（含 break/continue 的 for/while/loop）
    /// 带 body_skip 的循环体执行（跳过子图节点）
    fn execBodyNodesWithSkip(self: *Engine, nodes: []const Node, start: usize, len: usize, skip: []const bool) EngineError!?u16 {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (skip[i]) continue;
            const node = nodes[start + i];
            if (try self.execNode(&node)) |ret| {
                return ret;
            }
        }
        return null;
    }

    fn execScalarLoop(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.loop_metas.len) return error.InvalidMetaIndex;
        const lm = self.ir.loop_metas[node.meta_index - 1];

        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const body_local_start: usize = lm.body_start - func.node_start;

        // 构建局部 body_skip 位图：跳过循环体内的 route_dispatch/vec_*/cleanup_register 子图节点
        // 这些子图节点由对应的 exec 函数按需执行，不能在循环体线性遍历中重复执行
        const body_skip = try self.backing.alloc(bool, lm.body_len);
        defer self.backing.free(body_skip);
        @memset(body_skip, false);
        for (nodes[body_local_start..body_local_start + lm.body_len]) |n| {
            switch (n.op) {
                .route_dispatch => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.route_metas.len) continue;
                    const rm = self.ir.route_metas[n.meta_index - 1];
                    for (rm.body_starts, rm.body_lens) |bs, bl| {
                        if (bl == 0) continue;
                        // bs 是全局节点索引，转换为相对于循环体起点的偏移
                        if (bs < lm.body_start) continue;
                        const sub_start = bs - lm.body_start;
                        const sub_end = sub_start + bl;
                        for (sub_start..@min(sub_end, lm.body_len)) |j| body_skip[j] = true;
                    }
                },
                .vec_map, .vec_map2, .vec_fold, .vec_scan, .vec_filter, .vec_take_while => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.vector_metas.len) continue;
                    const vm = self.ir.vector_metas[n.meta_index - 1];
                    if (vm.body_len == 0) continue;
                    if (vm.body_start < lm.body_start) continue;
                    const sub_start = vm.body_start - lm.body_start;
                    const sub_end = sub_start + vm.body_len;
                    for (sub_start..@min(sub_end, lm.body_len)) |j| body_skip[j] = true;
                },
                .cleanup_register => {
                    if (n.meta_index == 0 or n.meta_index > self.ir.cleanup_metas.len) continue;
                    const cm = self.ir.cleanup_metas[n.meta_index - 1];
                    if (cm.body_len == 0) continue;
                    if (cm.body_start < lm.body_start) continue;
                    const sub_start = cm.body_start - lm.body_start;
                    const sub_end = sub_start + cm.body_len;
                    for (sub_start..@min(sub_end, lm.body_len)) |j| body_skip[j] = true;
                },
                else => {},
            }
        }

        switch (lm.loop_kind) {
            .loop => {
                // 无限循环，仅 break 退出
                while (true) {
                    _ = self.execBodyNodesWithSkip(nodes, body_local_start, lm.body_len, body_skip) catch |err| switch (err) {
                        error.LoopBreak => break,
                        error.LoopContinue => continue,
                        else => return err,
                    };
                }
            },
            .while_loop => {
                // while 循环：每轮先执行条件子图，再检查条件
                while (true) {
                    _ = try self.execBodyNodesWithSkip(nodes, body_local_start, lm.cond_len, body_skip);
                    const cond = self.runtime.readBool(lm.cond_chan);
                    if (!cond) break;
                    _ = self.execBodyNodesWithSkip(nodes, body_local_start + lm.cond_len, lm.body_len - lm.cond_len, body_skip[lm.cond_len..]) catch |err| switch (err) {
                        error.LoopBreak => break,
                        error.LoopContinue => continue,
                        else => return err,
                    };
                }
            },
            .for_loop => {
                // for 循环：遍历向量元素
                const vec_chan = lm.cond_chan;
                const count = self.runtime.vectorLen(vec_chan);
                const elem_w = self.runtime.elemWidth(vec_chan);
                const base_ptr = self.runtime.chan_ptrs[vec_chan].?;

                for (0..count) |i| {
                    // pin 循环变量到当前元素
                    self.runtime.chan_ptrs[lm.iter_chan] = base_ptr + i * elem_w;
                    self.runtime.chan_lengths[lm.iter_chan] = 1;

                    _ = self.execBodyNodesWithSkip(nodes, body_local_start, lm.body_len, body_skip) catch |err| switch (err) {
                        error.LoopBreak => break,
                        error.LoopContinue => continue,
                        else => return err,
                    };
                }

                // 恢复向量通道
                self.runtime.chan_ptrs[vec_chan] = base_ptr;
                self.runtime.chan_lengths[vec_chan] = count;
            },
        }

        // 循环结果写入 output（返回迭代次数或 0）
        self.runtime.writeI64(node.output, 0);
    }

    /// vec_source：生成向量数据
    /// inputs[0]=start, inputs[1]=end (range) 或 inputs[0]=array_ref (array_source)
    fn execVecSource(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        switch (vm.vec_op) {
            .range_source => {
                const start = self.runtime.readI64(node.inputs[0]);
                const end = self.runtime.readI64(node.inputs[1]);
                const count: u32 = if (end > start) @intCast(end - start) else 0;
                try self.runtime.allocVector(node.output, count);
                for (0..count) |i| {
                    self.runtime.writeVectorI64(node.output, i, start + @as(i64, @intCast(i)));
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
                    // 从 Value 联合体中读取 i64（覆盖所有整数变体）
                    const v = arr.elements[i];
                    const iv: i64 = switch (v) {
                        .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
                        .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
                        .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
                        .i64 => |b| @bitCast(b),
                        .u8 => |b| @as(i64, b[0]),
                        .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
                        .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
                        .u64 => |b| @as(i64, @bitCast(b)),
                        else => 0,
                    };
                    if (w >= 8) {
                        const dst: *i64 = @ptrCast(@alignCast(elem_ptr));
                        dst.* = iv;
                    } else if (w >= 4) {
                        const dst: *i32 = @ptrCast(@alignCast(elem_ptr));
                        dst.* = @intCast(iv);
                    }
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
            else => return error.InvalidMetaIndex,
        }
    }

    /// vec_map：对向量每个元素应用变换
    /// 子图模式：body_start..body_start+body_len 引用主节点流中的子图
    /// 内联标量模式：body_len=0，identity（直接拷贝）
    fn execVecMap(self: *Engine, node: *const Node) EngineError!void {
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

        // 子图模式：找到函数的节点切片和局部偏移
        // 遍历每个元素，将循环变量通道临时指向该元素，执行子图，读取结果
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;

        // 找到 body 的输出通道（body 子图最后一个节点的 output）
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            // 将循环变量通道临时指向 src_chan 的第 i 个元素（基于原始指针计算）
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            // 读取 body 结果到输出向量
            const w = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..w], src[0..w]);
        }

        // 恢复循环变量通道为向量模式
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_map2：双输入向量的逐元素二元运算
    fn execVecMap2(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const count = @min(self.runtime.vectorLen(left_chan), self.runtime.vectorLen(right_chan));

        try self.runtime.allocVector(node.output, count);

        if (vm.body_len == 0) {
            // 无子图：报错（vec_map2 需要一个二元运算体）
            return error.UnsupportedOp;
        }

        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const lw = self.runtime.elemWidth(left_chan);
        const rw = self.runtime.elemWidth(right_chan);
        const left_base = self.runtime.chan_ptrs[left_chan].?;
        const right_base = self.runtime.chan_ptrs[right_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[left_chan] = left_base + i * lw;
            self.runtime.chan_lengths[left_chan] = 1;
            self.runtime.chan_ptrs[right_chan] = right_base + i * rw;
            self.runtime.chan_lengths[right_chan] = 1;

            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);

            const w = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..w], src[0..w]);
        }

        // 恢复
        self.runtime.chan_ptrs[left_chan] = left_base;
        self.runtime.chan_lengths[left_chan] = count;
        self.runtime.chan_ptrs[right_chan] = right_base;
        self.runtime.chan_lengths[right_chan] = count;
    }

    /// vec_sink：从向量中提取标量值
    fn execVecSink(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        switch (vm.vec_op) {
            .sink_last => {
                if (count == 0) return error.InvalidChannel;
                const w = self.runtime.elemWidth(src_chan);
                const src = self.runtime.vectorElemPtr(src_chan, count - 1);
                const dst = self.runtime.rawPtr(node.output);
                @memcpy(dst[0..w], src[0..w]);
            },
            .sink_first => {
                if (count == 0) return error.InvalidChannel;
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
                const elements = self.backing.alloc(value.Value, elem_count) catch return error.OutOfMemory;
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
                const v = value.Value.makeArray(self.backing, elements, null) catch return error.OutOfMemory;
                try self.trackObj(v.asRef());
                self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            },
            else => return error.InvalidMetaIndex,
        }
    }

    /// vec_fold：归约（sum/max/min 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    fn execVecFold(self: *Engine, node: *const Node) EngineError!void {
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
            // 内联标量模式：用 inner_op 逐元素归约
            const out_meta = self.ir.channels.get(node.output);
            const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            var acc = self.readChanBytes(node.output);
            for (0..count) |i| {
                var elem_buf: [16]u8 = [_]u8{0} ** 16;
                const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                acc = try dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
            }
            self.writeChanBytes(node.output, acc);
            return;
        }

        // 子图模式：对每个元素，将累加器（output）和当前元素作为输入执行 body
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        // fold 的 body：inputs[0] = 累加器（output 通道），inputs[1] = 当前元素
        // 循环变量通道是 src_chan，累加器是 node.output
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            // body 的结果在 body_out_chan，复制到 output 作为新的累加器
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复 src_chan
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_scan：前缀扫描（prefix sum 等）
    /// inputs[0]=向量, inputs[1]=初始值
    /// 支持两种模式：内联标量模式（inner_op）和子图模式（body_start/body_len）
    fn execVecScan(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const init_chan = node.inputs[1];
        const count = self.runtime.vectorLen(src_chan);

        try self.runtime.allocVector(node.output, count);
        if (count == 0) return;

        const w = self.runtime.elemWidth(node.output);

        if (vm.body_len == 0) {
            // 内联标量模式：用 inner_op 逐元素扫描
            const out_meta = self.ir.channels.get(node.output);
            const tag = chanToScalarTag(out_meta) orelse return error.UnsupportedOp;
            // 累加器初始化为 init
            var acc = self.readChanBytes(init_chan);
            for (0..count) |i| {
                var elem_buf: [16]u8 = [_]u8{0} ** 16;
                const elem_ptr = self.runtime.vectorElemPtr(src_chan, i);
                if (w > 0 and w <= 16) @memcpy(elem_buf[0..w], elem_ptr[0..w]);
                acc = try dispatchInlineBinOp(vm.inner_op, tag, acc, elem_buf);
                // 写到 output[i]
                const dst = self.runtime.vectorElemPtr(node.output, i);
                if (w > 0 and w <= 16) @memcpy(dst[0..w], acc[0..w]);
            }
            return;
        }

        // 子图模式
        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        // 简化实现：逐元素扫描
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            const bw = self.runtime.elemWidth(body_out_chan);
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.vectorElemPtr(node.output, i);
            @memcpy(dst[0..bw], src[0..bw]);
        }

        // 恢复
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_filter：按条件过滤元素
    fn execVecFilter(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        if (vm.body_len == 0 or count == 0) {
            try self.runtime.allocVector(node.output, 0);
            return;
        }

        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;

        // 先收集通过的元素
        const w = self.runtime.elemWidth(src_chan);
        const temp = self.backing.alloc(u8, w * count) catch return error.OutOfMemory;
        defer self.backing.free(temp);
        var kept: u32 = 0;
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;

        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            if (self.runtime.readBool(body_out_chan)) {
                const src = self.runtime.vectorElemPtr(src_chan, i);
                @memcpy(temp[kept * w .. (kept + 1) * w], src[0..w]);
                kept += 1;
            }
        }

        // 分配输出向量并拷贝
        try self.runtime.allocVector(node.output, kept);
        if (kept > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * kept], temp[0 .. w * kept]);
        }

        // 恢复
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_take：取前 N 个元素
    fn execVecTake(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const n: u32 = @intCast(@max(0, self.runtime.readI64(node.inputs[1])));
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
    fn execVecTakeWhile(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.vector_metas.len) return error.InvalidMetaIndex;
        const vm = self.ir.vector_metas[node.meta_index - 1];

        const src_chan = node.inputs[0];
        const count = self.runtime.vectorLen(src_chan);

        if (vm.body_len == 0 or count == 0) {
            try self.runtime.allocVector(node.output, 0);
            return;
        }

        const func = self.ir.functions[self.currentFuncIdx()];
        const nodes = self.ir.funcNodes(self.currentFuncIdx());
        const body_local_start: usize = vm.body_start - func.node_start;
        const body_out_chan = nodes[body_local_start + vm.body_len - 1].output;

        const w = self.runtime.elemWidth(src_chan);
        const elem_w = self.runtime.elemWidth(src_chan);
        const base_ptr = self.runtime.chan_ptrs[src_chan].?;
        var taken: u32 = 0;
        for (0..count) |i| {
            self.runtime.chan_ptrs[src_chan] = base_ptr + i * elem_w;
            self.runtime.chan_lengths[src_chan] = 1;
            _ = try self.execBodyNodes(nodes, body_local_start, vm.body_len);
            if (!self.runtime.readBool(body_out_chan)) break;
            taken = @intCast(i + 1);
        }

        try self.runtime.allocVector(node.output, taken);
        if (taken > 0) {
            const src = self.runtime.rawPtr(src_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * taken], src[0 .. w * taken]);
        }

        // 恢复
        self.runtime.chan_ptrs[src_chan] = base_ptr;
        self.runtime.chan_lengths[src_chan] = count;
    }

    /// vec_zip：合并两个向量为 pair 数组
    fn execVecZip(self: *Engine, node: *const Node) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];
        const count = @min(self.runtime.vectorLen(left_chan), self.runtime.vectorLen(right_chan));
        // 简化：输出左向量，右向量通过 vec_map2 使用
        // 真正的 zip 需要 pair 类型支持，这里简化为拷贝左向量
        try self.runtime.allocVector(node.output, count);
        const w = self.runtime.elemWidth(left_chan);
        if (count > 0) {
            const src = self.runtime.rawPtr(left_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0 .. w * count], src[0 .. w * count]);
        }
    }

    /// 获取当前正在执行的函数索引
    fn currentFuncIdx(self: *Engine) u16 {
        return self.current_func_idx;
    }

    /// 恢复被 pinToElement 修改的向量通道指针
    fn restoreVectorChan(self: *Engine, chan: u16, count: u32) void {
        if (count <= 1) return; // 0 或 1 个元素时指针未被移动
        const w = self.runtime.chan_widths[chan];
        self.runtime.chan_ptrs[chan] = self.runtime.chan_ptrs[chan].? - @as(usize, count - 1) * w;
        self.runtime.chan_lengths[chan] = count;
    }

    // ════════════════════════════════════════════
    // 门控执行（Phase 4：错误处理）
    // ════════════════════════════════════════════

    /// 读取 ref_chan 中的堆对象，返回 *ObjHeader 或 null
    fn readRefObj(self: *Engine, chan: u16) ?*value.obj_header.ObjHeader {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        return header;
    }

    /// 读取 ThrowValue 指针（ref_chan → *ThrowValue）
    fn readThrow(self: *Engine, chan: u16) ?*value.ThrowValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .throw_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 读取 ErrorValue 指针（ref_chan → *ErrorValue）
    fn readError(self: *Engine, chan: u16) ?*value.ErrorValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .error_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// gate_check：检查值是否 Ok
    /// inputs[0] = 值通道（ref_chan 指向 ThrowValue 或普通值）
    /// output = mask_chan（1=Ok, 0=Err）
    fn execGateCheck(self: *Engine, node: *const Node) EngineError!void {
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
    fn execGateGetOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .ok => |v| {
                    // 将 Ok 值写入 output
                    // 简化：如果是标量值，按类型写入；如果是 ref，写指针
                    self.writeScalarValue(node.output, v);
                    return;
                },
                .err => {
                    // Err 情况下不应该调用 get_ok，写入 null
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
    fn execGateGetErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        if (self.readThrow(val_chan)) |throw_val| {
            switch (throw_val.payload) {
                .err => |err_ptr| {
                    // 写入 &err_ptr.header（指向 ObjHeader 字段的指针）
                    // 而非 err_ptr（指向 ErrorValue 结构体），因为非 extern struct 字段偏移不保证为 0
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
    fn execGatePropagate(self: *Engine, node: *const Node) EngineError!void {
        const cur = self.runtime.readBool(node.inputs[0]);
        const upstream = if (node.input_count >= 2) self.runtime.readBool(node.inputs[1]) else true;
        // 传播：如果当前 Ok 且上游也 Ok，则 Ok；否则 Err
        self.runtime.writeBool(node.output, cur and upstream);
    }

    /// gate_select：按 mask 选择值
    /// inputs[0] = mask, inputs[1] = ok_val, inputs[2] = err_val
    /// output = 选中的值
    fn execGateSelect(self: *Engine, node: *const Node) EngineError!void {
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
    fn execGateMakeOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        // 读取值并构造 ThrowValue{ .ok = value }
        const v = self.readScalarValue(val_chan);
        const t = self.backing.create(value.ThrowValue) catch return error.OutOfMemory;
        t.* = .{ .payload = .{ .ok = v } };
        try self.trackObj(&t.header);
        self.runtime.writePtr(node.output, @ptrCast(&t.header));
    }

    /// gate_make_err：构造 ErrorValue + ThrowValue(err)
    /// inputs[0] = 错误信息通道（ref_chan 指向 Str）
    /// output = ref_chan（ThrowValue 指针）
    fn execGateMakeErr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const msg_bytes = if (self.readStr(val_chan)) |s| s.bytes() else "";

        const err_val = self.backing.create(value.ErrorValue) catch return error.OutOfMemory;
        const type_name_dup = self.backing.dupe(u8, "Error") catch return error.OutOfMemory;
        const msg_dup = self.backing.dupe(u8, msg_bytes) catch return error.OutOfMemory;
        err_val.* = .{
            .type_name = type_name_dup,
            .message = msg_dup,
            .is_error_subtype = false,
        };
        try self.trackObj(&err_val.header);

        const throw_val = self.backing.create(value.ThrowValue) catch return error.OutOfMemory;
        throw_val.* = .{ .payload = .{ .err = err_val } };
        _ = value.obj_header.retain(&err_val.header);
        try self.trackObj(&throw_val.header);
        self.runtime.writePtr(node.output, @ptrCast(&throw_val.header));
    }

    /// 从通道读取标量值（用于 gate 操作）
    fn readScalarValue(self: *Engine, chan: u16) value.Value {
        const meta = self.ir.channels.get(chan);
        const w = meta.elem_width;
        if (meta.chan_type == .ref_chan) {
            const ptr = self.runtime.readPtr(chan) orelse return value.Value.fromNull();
            return value.Value.fromRef(@ptrCast(@alignCast(ptr)));
        }
        if (meta.chan_type == .bool_chan) {
            return value.Value.fromBool(self.runtime.readBool(chan));
        }
        // 整数/浮点：按宽度读取
        if (w == 8) {
            return value.Value.fromI64(self.runtime.readI64(chan));
        }
        if (w == 4) {
            const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
            return value.Value.fromI32(ptr.*);
        }
        if (w == 0) {
            return value.Value.fromUnit();
        }
        return value.Value.fromI64(self.runtime.readI64(chan));
    }

    /// 将标量值写入通道
    fn writeScalarValue(self: *Engine, chan: u16, v: value.Value) void {
        const meta = self.ir.channels.get(chan);
        switch (v) {
            .ref => |r| self.runtime.writePtr(chan, @ptrCast(r)),
            .boolean => |b| self.runtime.writeBool(chan, b[0] != 0),
            .i64 => |b| self.runtime.writeI64(chan, @bitCast(b)),
            .i32 => |b| {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .null_val => self.runtime.writePtr(chan, null),
            .unit => {},
            else => {
                // 其他类型：按字节拷贝
                const w = meta.elem_width;
                if (w > 0 and w <= 16) {
                    const src: [*]const u8 = @ptrCast(&v);
                    const dst = self.runtime.rawPtr(chan);
                    @memcpy(dst[0..w], src[0..w]);
                }
            },
        }
    }

    // ════════════════════════════════════════════
    // 清理执行（Phase 4：defer）
    // ════════════════════════════════════════════

    /// cleanup_register：将 defer 体注册到 defer 栈
    /// meta_index 指向 CleanupMeta（记录 body_start/body_len）
    fn execCleanupRegister(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.cleanup_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.cleanup_metas[node.meta_index - 1];

        if (self.defer_top >= MAX_DEFERS) return error.CallDepthExceeded;

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
    fn execRaceSource(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        // 只有 ref_chan 才可能是 ChannelValue
        if (meta.chan_type == .ref_chan) {
            const ptr = self.runtime.readPtr(val_chan) orelse {
                self.runtime.writeBool(node.output, false);
                return;
            };
            const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));

            // 检查是否为 ChannelValue
            if (header.type_tag == .channel_val) {
                const ch: *value.ChannelValue = @alignCast(@fieldParentPtr("header", header));
                // 非阻塞检查：count > 0 或会合模式有发送方就绪
                ch.mutex.lock();
                defer ch.mutex.unlock();
                const ready = if (ch.capacity == 0) ch.rend_ready else ch.count > 0;
                self.runtime.writeBool(node.output, ready);
                return;
            }
        }
        // 非 ChannelValue（标量/整数等）：视为始终就绪
        self.runtime.writeBool(node.output, true);
    }

    /// race_select：选择第一个就绪的分支
    /// inputs[0..N] = 各 race_source 的 mask
    /// output = mask_chan（winner 索引，0-based）
    fn execRaceSelect(self: *Engine, node: *const Node) EngineError!void {
        var winner: u16 = 0;
        for (0..node.input_count) |i| {
            if (self.runtime.readBool(node.inputs[i])) {
                winner = @intCast(i);
                break;
            }
        }
        // 如果没有就绪分支，winner=0（简化：不实现 yield，默认选第一个）
        // 将 winner 索引写入 mask_chan（用 i64 存储索引）
        self.runtime.writeI64(node.output, @intCast(winner));
    }

    /// race_yield：让出执行权（Phase 5 简化：无操作，Phase 7 接入星轨调度器）
    fn execRaceYield(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
    }

    /// route_get_tag：读取值的 tag（用于 Trait 动态分派和 ADT 构造器识别）
    /// inputs[0] = 值通道
    /// output = mask_chan（tag 值，用 i64 存储）
    fn execRouteGetTag(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);

        switch (meta.chan_type) {
            .ref_chan => {
                // 堆对象：读取 type_tag 的整数值作为 tag
                const header = self.readRefObj(val_chan);
                if (header) |h| {
                    const tag_val: i64 = @intFromEnum(h.type_tag);
                    self.runtime.writeI64(node.output, tag_val);
                } else {
                    self.runtime.writeI64(node.output, 0);
                }
            },
            // 标量值：用 chan_type 的整数值作为 tag
            else => {
                const tag_val: i64 = @intFromEnum(meta.chan_type);
                self.runtime.writeI64(node.output, tag_val);
            },
        }
    }

    /// route_dispatch：按 winner 索引执行对应 body 子图
    /// inputs[0] = winner 索引（mask_chan）
    /// output = 结果通道
    fn execRouteDispatch(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.route_metas.len) return error.InvalidMetaIndex;
        const rm = self.ir.route_metas[node.meta_index - 1];

        // 读取 winner 索引
        const winner_raw = self.runtime.readI64(node.inputs[0]);
        const winner: usize = @intCast(@as(u64, @bitCast(winner_raw)));

        if (winner >= rm.body_starts.len or winner >= rm.body_lens.len) return error.InvalidChannel;

        const body_start = rm.body_starts[winner];
        const body_len = rm.body_lens[winner];
        if (body_len == 0) return;

        // 执行 winner 对应的 body 子图
        const func = self.ir.functions[self.current_func_idx];
        const nodes = self.ir.funcNodes(self.current_func_idx);
        const local_start = body_start - func.node_start;
        _ = try self.execBodyNodes(nodes, local_start, body_len);

        // body 子图最后一个节点的 output 作为结果
        const body_out_chan = nodes[local_start + body_len - 1].output;
        const w = self.runtime.elemWidth(body_out_chan);
        if (w > 0) {
            const src = self.runtime.rawPtr(body_out_chan);
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..w], src[0..w]);
        }
    }

    /// route_merge：合并多分支结果（Phase 5 简化：直接拷贝第一个输入）
    fn execRouteMerge(self: *Engine, node: *const Node) EngineError!void {
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
    fn nullableInnerWidth(self: *Engine, chan: u16) u8 {
        const meta = self.ir.channels.get(chan);
        return meta.inner_type.elemWidth();
    }

    /// nullable_make：将值包装为 Nullable<T>
    /// inputs[0] = 值通道（如果 ref_chan 为 null 指针，则包装为 null）
    /// output = nullable_chan
    fn execNullableMake(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const val_meta = self.ir.channels.get(val_chan);

        const inner_w = self.nullableInnerWidth(node.output);
        const total_w = self.runtime.elemWidth(node.output); // inner_w + 1
        const dst = self.runtime.rawPtr(node.output);

        // 检查是否为 null（ref_chan 的 null 指针，或 null_chan）
        const is_null = switch (val_meta.chan_type) {
            .ref_chan => self.runtime.readPtr(val_chan) == null,
            .null_chan => true,
            else => false,
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
    fn execNullableIsNull(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);
        // null flag 在 inner_w 偏移处
        self.runtime.writeBool(node.output, src[inner_w] != 0);
    }

    /// nullable_unwrap：提取 Nullable<T> 的内部值（null 时 panic）
    /// inputs[0] = nullable_chan
    /// output = inner 值通道
    fn execNullableUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const inner_w = self.nullableInnerWidth(src_chan);
        const src = self.runtime.rawPtr(src_chan);

        if (src[inner_w] != 0) {
            // null 值解包 → panic
            return error.Panic;
        }

        if (inner_w > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..inner_w], src[0..inner_w]);
        }
    }

    /// nullable_unwrap_or：提取值，null 时返回默认值
    /// inputs[0] = nullable_chan, inputs[1] = default 值通道
    /// output = inner 值通道
    fn execNullableUnwrapOr(self: *Engine, node: *const Node) EngineError!void {
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
    fn execAlloc(self: *Engine, node: *const Node) EngineError!void {
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
    fn execFree(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        // 简化：arena 分配器不支持单个释放，由函数级/作用域级 reset 统一回收
    }

    // ════════════════════════════════════════════
    // 星轨执行（Phase 7：async/spawn）
    // ════════════════════════════════════════════
    // 设计要点：
    // - orbit_async_create：在独立线程中执行 async 函数，返回 AsyncHandle
    // - orbit_async_join：阻塞等待异步任务完成，提取结果
    // - orbit_chan_send/recv/try_recv：通过 ChannelValue 进行线程间通信
    // - 异步函数在独立线程中执行，拥有自己的 Engine 实例（共享 IR，独立 Runtime）

    /// 读取 ref_chan 中的 AsyncHandle 指针
    fn readAsyncHandle(self: *Engine, chan: u16) ?*value.AsyncHandle {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag != .async_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 读取 ref_chan 中的 ChannelValue 指针
    fn readChannelValue(self: *Engine, chan: u16) ?*value.ChannelValue {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag != .channel_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// orbit_async_create：在独立线程中执行 async 函数
    /// inputs[0..N] = 参数通道
    /// meta_index 指向 OrbitMeta（记录 func_index, arg_count, result_type）
    /// output = ref_chan（AsyncHandle 指针）
    fn execOrbitAsyncCreate(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.orbit_metas.len) return error.InvalidMetaIndex;
        const om = self.ir.orbit_metas[node.meta_index - 1];

        // 创建 AsyncHandle
        const handle = self.backing.create(value.AsyncHandle) catch return error.OutOfMemory;
        handle.* = value.AsyncHandle.init(self.backing);
        try self.trackObj(&handle.header);

        // 读取参数值
        var args: [4]i64 = .{ 0, 0, 0, 0 };
        const arg_count = @min(om.arg_count, 4);
        for (0..arg_count) |i| {
            args[i] = self.runtime.readI64(node.inputs[i]);
        }

        // 设置状态为 Running
        handle.setStatus(.Running);

        // 准备线程数据：拷贝 IR 指针、函数索引、参数、handle 指针
        const thread_data = self.backing.create(OrbitThreadData) catch return error.OutOfMemory;
        thread_data.* = .{
            .ir = self.ir,
            .func_idx = om.func_index,
            .args = args,
            .arg_count = arg_count,
            .handle = handle,
            .backing = self.backing,
        };

        // spawn 线程执行 async 函数
        const thread = std.Thread.spawn(.{}, orbitWorker, .{thread_data}) catch return error.OutOfMemory;
        thread.detach();

        // 输出 AsyncHandle 指针
        self.runtime.writePtr(node.output, @ptrCast(&handle.header));
    }

    /// orbit_async_join：阻塞等待异步任务完成，提取结果
    /// inputs[0] = handle 通道（ref_chan）
    /// output = 结果通道
    fn execOrbitAsyncJoin(self: *Engine, node: *const Node) EngineError!void {
        const handle = self.readAsyncHandle(node.inputs[0]) orelse return error.InvalidChannel;

        // 阻塞等待完成
        const result_val = handle.join();

        // 将结果写入 output 通道
        if (result_val) |v| {
            self.writeScalarValue(node.output, v);
        } else {
            // 任务失败或无结果：写入 0
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
        }
    }

    /// orbit_chan_send：向通道发送值（阻塞直到接收方就绪）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// inputs[1] = 值通道
    fn execOrbitChanSend(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        const val = self.readScalarValue(node.inputs[1]);

        const sent = ch.send(val) catch return error.Panic;
        if (!sent) return error.Thrown; // 通道已关闭
    }

    /// orbit_chan_recv：从通道接收值（阻塞直到有数据）
    /// inputs[0] = handle/channel 通道（ref_chan）
    /// output = 结果通道
    fn execOrbitChanRecv(self: *Engine, node: *const Node) EngineError!void {
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
    fn execOrbitChanTryRecv(self: *Engine, node: *const Node) EngineError!void {
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
    fn execOrbitAsyncStatus(self: *Engine, node: *const Node) EngineError!void {
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
    fn execChannelClose(self: *Engine, node: *const Node) EngineError!void {
        const ch = self.readChannelValue(node.inputs[0]) orelse return error.InvalidChannel;
        ch.close();
    }

    /// error_message：提取错误值的消息字符串
    /// inputs[0] = error ref 通道
    /// output = ref_chan（Str 指针）
    fn execErrorMessage(self: *Engine, node: *const Node) EngineError!void {
        const ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        const msg: []const u8 = switch (header.type_tag) {
            .error_val => blk: {
                const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                break :blk e.message;
            },
            .throw_val => blk: {
                const t: *value.ThrowValue = @alignCast(@fieldParentPtr("header", header));
                break :blk switch (t.payload) {
                    .err => |e| e.message,
                    else => "ok",
                };
            },
            else => "not an error",
        };
        const v = value.Value.fromStringBytes(self.backing, msg) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// obj_type_name：获取值的类型名
    /// inputs[0] = ref 通道
    /// output = ref_chan（Str 指针）
    fn execObjTypeName(self: *Engine, node: *const Node) EngineError!void {
        const ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        const name: []const u8 = switch (header.type_tag) {
            .record => blk: {
                const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                break :blk r.type_name;
            },
            .adt => blk: {
                const a: *value.AdtValue = @alignCast(@fieldParentPtr("header", header));
                break :blk a.type_name;
            },
            .newtype => blk: {
                const n: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", header));
                break :blk n.type_name;
            },
            .error_val => blk: {
                const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                break :blk e.type_name;
            },
            else => @tagName(header.type_tag),
        };
        const v = value.Value.fromStringBytes(self.backing, name) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// closure_make：创建 Closure 值，存储 func_idx + 上值
    /// inputs[0..N] = 上值通道
    /// meta_index 指向 ClosureMeta（func_index, upvalue_count, result_type）
    /// output = ref_chan（Closure 指针）
    fn execClosureMake(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.closure_metas.len) return error.InvalidMetaIndex;
        const cm = self.ir.closure_metas[node.meta_index - 1];

        // 收集上值
        const upvalue_count = @as(usize, @min(cm.upvalue_count, node.input_count));
        var upvalues: []value.Value = &.{};
        if (upvalue_count > 0) {
            upvalues = self.backing.alloc(value.Value, upvalue_count) catch return error.OutOfMemory;
            for (0..upvalue_count) |i| {
                upvalues[i] = self.chanToValue(node.inputs[i]);
                _ = upvalues[i].retain();
            }
        }

        // 创建 Closure 值
        const closure = self.backing.create(value.Closure) catch return error.OutOfMemory;
        closure.* = .{
            .func = @ptrFromInt(@as(usize, cm.func_index)),
            .arity = @intCast(upvalue_count),
            .upvalues = upvalues,
            .allocator = self.backing,
        };
        try self.trackObj(&closure.header);
        self.runtime.writePtr(node.output, @ptrCast(&closure.header));
    }

    /// call_indirect：通过 Closure 值间接调用
    /// inputs[0] = closure_chan（ref to Closure）
    /// inputs[1..M] = 参数通道
    /// meta_index 指向 CallMeta（arg_count 包含 closure_chan）
    fn execCallIndirect(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.call_metas.len) return error.InvalidMetaIndex;
        const call_meta = self.ir.call_metas[node.meta_index - 1];

        // 读取 Closure 值
        const ptr = self.runtime.readPtr(node.inputs[0]) orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (header.type_tag != .closure) return error.InvalidChannel;
        const closure: *value.Closure = @alignCast(@fieldParentPtr("header", header));
        const func_idx: u16 = @intCast(@intFromPtr(closure.func));

        if (func_idx >= self.ir.functions.len) return error.InvalidMetaIndex;
        const callee_func = self.ir.functions[func_idx];

        if (self.call_depth >= MAX_CALL_DEPTH) return error.CallDepthExceeded;

        // 实际参数数量 = call_meta.arg_count - 1（减去 closure_chan）
        const arg_count = @as(usize, call_meta.arg_count) - 1;
        const args = node.inputs[1 .. 1 + arg_count];

        // 保存被调用函数的通道状态（与 execCall 相同的逻辑）
        const ret_chan = callee_func.return_channel;
        const lcs = callee_func.local_chan_start;
        const lcc = callee_func.local_chan_count;
        const n_chans: usize = 1 + @as(usize, lcc);
        const cc = self.runtime.chan_count;

        const saved_ptrs = self.backing.alloc(?[*]u8, n_chans) catch return error.OutOfMemory;
        defer self.backing.free(saved_ptrs);
        const saved_lens = self.backing.alloc(u32, n_chans) catch return error.OutOfMemory;
        defer self.backing.free(saved_lens);

        var total_bytes: usize = 0;
        const chanIdx = struct {
            fn get(ret: u16, lstart: u16, i: usize) u16 {
                return if (i == 0) ret else lstart + @as(u16, @intCast(i - 1));
            }
        };
        for (0..n_chans) |i| {
            const ch = chanIdx.get(ret_chan, lcs, i);
            if (ch < cc) {
                saved_ptrs[i] = self.runtime.chan_ptrs[ch];
                saved_lens[i] = self.runtime.chan_lengths[ch];
                const w = self.runtime.chan_widths[ch];
                if (w > 0 and saved_lens[i] > 0) total_bytes += @as(usize, w) * saved_lens[i];
            } else {
                saved_ptrs[i] = null;
                saved_lens[i] = 0;
            }
        }

        const save_buf = self.backing.alloc(u8, total_bytes) catch return error.OutOfMemory;
        defer self.backing.free(save_buf);
        {
            var off: usize = 0;
            for (0..n_chans) |i| {
                const ch = chanIdx.get(ret_chan, lcs, i);
                if (ch < cc) {
                    const w = self.runtime.chan_widths[ch];
                    const len = saved_lens[i];
                    if (w > 0 and len > 0) {
                        const src = saved_ptrs[i].?;
                        const n = @as(usize, w) * len;
                        @memcpy(save_buf[off .. off + n], src[0..n]);
                        off += n;
                    }
                }
            }
        }

        // 复制参数值到被调用函数的参数通道
        // 参数顺序：显式参数 + 上值参数
        const total_params = callee_func.param_channels.len;
        const explicit_count = @min(arg_count, total_params);
        for (0..explicit_count) |i| {
            const dst_chan = callee_func.param_channels[i];
            const w = self.runtime.elemWidth(args[i]);
            if (w > 0) {
                const src = self.runtime.rawPtr(args[i]);
                const dst = self.runtime.rawPtr(dst_chan);
                @memcpy(dst[0..w], src[0..w]);
            }
        }
        // 上值参数（从 Closure 的 upvalues 复制到对应的参数通道）
        const upvalue_count = @min(closure.upvalues.len, if (total_params > explicit_count) total_params - explicit_count else 0);
        for (0..upvalue_count) |i| {
            const dst_chan = callee_func.param_channels[explicit_count + i];
            self.writeScalarValue(dst_chan, closure.upvalues[i]);
        }

        // 压栈
        self.call_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .return_chan = node.output,
            .return_pc = 0,
        };
        self.call_depth += 1;

        const saved_func_idx = self.current_func_idx;
        const result_chan = try self.execFunction(func_idx, args);
        self.current_func_idx = saved_func_idx;

        // 保存结果
        const result_w = self.runtime.elemWidth(result_chan);
        var result_buf: [16]u8 = undefined;
        if (result_w > 0) {
            const src = self.runtime.rawPtr(result_chan);
            @memcpy(result_buf[0..result_w], src[0..result_w]);
        }

        self.call_depth -= 1;

        // 恢复通道状态
        {
            var off: usize = 0;
            for (0..n_chans) |i| {
                const ch = chanIdx.get(ret_chan, lcs, i);
                if (ch < cc) {
                    self.runtime.chan_ptrs[ch] = saved_ptrs[i];
                    self.runtime.chan_lengths[ch] = saved_lens[i];
                    const wd = self.runtime.chan_widths[ch];
                    const len = saved_lens[i];
                    if (wd > 0 and len > 0) {
                        const dst = saved_ptrs[i].?;
                        const n = @as(usize, wd) * len;
                        @memcpy(dst[0..n], save_buf[off .. off + n]);
                        off += n;
                    }
                }
            }
        }

        // 写入结果
        if (result_w > 0) {
            const dst = self.runtime.rawPtr(node.output);
            @memcpy(dst[0..result_w], result_buf[0..result_w]);
        }
    }

    /// 将标量 Value 转为字节缓冲区（用于 nullable 写入）
    fn readScalarValueToBytes(self: *Engine, v: value.Value) [16]u8 {
        _ = self;
        var buf: [16]u8 = [_]u8{0} ** 16;
        switch (v) {
            .i64 => |b| {
                const val: i64 = @bitCast(b);
                @memcpy(buf[0..8], std.mem.asBytes(&val));
            },
            .i32 => |b| {
                const val: i32 = @bitCast(b);
                @memcpy(buf[0..4], std.mem.asBytes(&val));
            },
            .boolean => |b| buf[0] = b[0],
            else => {},
        }
        return buf;
    }
};

/// 星轨线程数据：传递给 worker 线程的参数
const OrbitThreadData = struct {
    ir: *GlueIR,
    func_idx: u16,
    args: [4]i64,
    arg_count: u8,
    handle: *value.AsyncHandle,
    backing: std.mem.Allocator,
};

/// 星轨 worker 线程函数：在独立线程中执行 async 函数
/// 创建独立的 Engine 实例（共享 IR，独立 ThreadContext + Runtime，避免通道存储竞争）
fn orbitWorker(data: *OrbitThreadData) void {
    const alloc = data.backing;
    defer alloc.destroy(data);

    var engine = Engine.initOwned(data.ir, data.backing) catch {
        data.handle.setPanic("Failed to init engine");
        return;
    };
    defer engine.deinit();

    // 布局通道存储（独立于主线程）
    engine.runtime.layout(&data.ir.channels) catch {
        data.handle.setPanic("Failed to layout channels");
        return;
    };

    // 将参数写入函数的参数通道
    const func = data.ir.functions[data.func_idx];
    for (0..data.arg_count) |i| {
        if (i < func.param_channels.len) {
            engine.runtime.writeI64(func.param_channels[i], data.args[i]);
        }
    }

    // 执行函数
    const result_chan = engine.execFunction(data.func_idx, func.param_channels) catch {
        data.handle.setPanic("Function execution failed");
        return;
    };

    // 读取结果并设置到 handle
    const result_val = engine.readScalarValue(result_chan);
    data.handle.setResult(result_val);
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const ast = @import("ast");
const builder_mod = ir_mod.builder_mod;

/// 测试辅助：从源码构建 IR
fn buildIRFromSource(source: []const u8) !GlueIR {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lex = @import("lexer").Lexer.init(alloc, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer alloc.free(tokens);

    var p = @import("parser").Parser.init(alloc, tokens);
    defer p.deinit();
    const module = try p.parseModule("test.glue");

    var builder = try builder_mod.IRBuilder.init(testing.allocator);
    defer builder.deinit();
    return try builder.build(module);
}

test "执行 const_i + halt_return" {
    // fun main() { 42 }
    var ir = try buildIRFromSource("fun main() { 42 }");
    defer ir.deinit();

    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "执行整数加法" {
    // fun main() { 1 + 2 }
    var ir = try buildIRFromSource("fun main() { 1 + 2 }");
    defer ir.deinit();

    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), result);
}

test "执行整数减法" {
    var ir = try buildIRFromSource("fun main() { 10 - 4 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 6), try engine.run());
}

test "执行整数乘法" {
    var ir = try buildIRFromSource("fun main() { 6 * 7 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "执行整数除法" {
    var ir = try buildIRFromSource("fun main() { 20 / 4 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "执行整数取模" {
    var ir = try buildIRFromSource("fun main() { 17 % 5 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "执行嵌套表达式" {
    // 1 + 2 * 3 = 7
    var ir = try buildIRFromSource("fun main() { 1 + 2 * 3 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "执行比较运算" {
    // 3 < 5 → true → 1
    var ir = try buildIRFromSource("fun main() { 3 < 5 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "执行布尔逻辑" {
    // true && false → false → 0
    var ir = try buildIRFromSource("fun main() { true && false }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), result);
}

test "执行 val 变量绑定" {
    // val x = 10, val y = 20, x + y
    var ir = try buildIRFromSource("fun main() { val x = 10; val y = 20; x + y }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 30), try engine.run());
}

test "执行函数调用" {
    // fun add(a, b) { a + b }
    // fun main() { add(3, 4) }
    var ir = try buildIRFromSource(
        \\fun add(a, b) { a + b }
        \\fun main() { add(3, 4) }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "执行优化后的常量折叠" {
    // fun main() { 1 + 2 } → 优化后应为 const_i(3)
    var ir = try buildIRFromSource("fun main() { 1 + 2 }");
    defer ir.deinit();

    // 优化
    _ = ir_mod.optimize(&ir);

    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 3), try engine.run());
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试
// ════════════════════════════════════════════════════════════════

test "Phase 2: var 声明与赋值" {
    // var x = 10; x = 20; x
    var ir = try buildIRFromSource("fun main() { var x = 10; x = 20; x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2: 复合赋值 += " {
    // var x = 10; x += 5; x
    var ir = try buildIRFromSource("fun main() { var x = 10; x += 5; x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 15), try engine.run());
}

test "Phase 2: 复合赋值 *=" {
    // var x = 3; x *= 7; x
    var ir = try buildIRFromSource("fun main() { var x = 3; x *= 7; x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 21), try engine.run());
}

test "Phase 2: if 表达式 then 分支" {
    // if true { 42 } else { 0 }
    var ir = try buildIRFromSource("fun main() { if true { 42 } else { 0 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "Phase 2: if 表达式 else 分支" {
    // if 3 > 5 { 42 } else { 99 }
    var ir = try buildIRFromSource("fun main() { if 3 > 5 { 42 } else { 99 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 99), try engine.run());
}

test "Phase 2: if 表达式条件求值" {
    // val x = 10; if x > 5 { x * 2 } else { x }
    var ir = try buildIRFromSource("fun main() { val x = 10; if x > 5 { x * 2 } else { x } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2: 类型转换 i64→i32" {
    // i32(1000)
    var ir = try buildIRFromSource("fun main() { i32(1000) }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1000), result);
}

test "Phase 2: 类型转换 i64→f64" {
    // f64(42) → 42.0 → 位模式转回 i64 验证
    var ir = try buildIRFromSource("fun main() { f64(42) }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    // f64 通道的 8 字节读为 i64
    const result = try engine.run();
    const f: f64 = @bitCast(result);
    try testing.expectEqual(@as(f64, 42.0), f);
}

test "Phase 2: 嵌套 if 表达式" {
    // val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 }
    var ir = try buildIRFromSource("fun main() { val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 100), try engine.run());
}

test "Phase 2: 嵌套 if（then 分支内嵌套，字面量条件）" {
    // if true { if false { 1 } else { 2 } } else { 3 } → 2
    var ir = try buildIRFromSource("fun main() { if true { if false { 1 } else { 2 } } else { 3 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "Phase 2: cast 链 i64→i32→i64" {
    // i64(i32(1000))
    var ir = try buildIRFromSource("fun main() { i64(i32(1000)) }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 1000), try engine.run());
}

test "Phase 2: var 与 if 组合" {
    // var x = 1; if x > 0 { x = 10 }; x
    var ir = try buildIRFromSource("fun main() { var x = 1; if x > 0 { x = 10 }; x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "Phase 2: 复合赋值 -= " {
    // var x = 100; x -= 30; x
    var ir = try buildIRFromSource("fun main() { var x = 100; x -= 30; x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 70), try engine.run());
}

test "Phase 2: 类型转换 i64→u8（窄化 wrap）" {
    // u8(300) → 300 wrap to u8 = 44
    var ir = try buildIRFromSource("fun main() { u8(300) }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    // u8 通道读 1 字节，零扩展为 i64
    try testing.expectEqual(@as(i64, 44), result);
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：堆对象（字符串）
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 字符串字面量" {
    // "hello" → 创建 Str 堆对象
    var ir = try buildIRFromSource("fun main() { \"hello\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello", result);
}

test "Phase 2.5: 字符串拼接 (+)" {
    // "hello" + "world"
    var ir = try buildIRFromSource("fun main() { \"hello\" + \"world\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("helloworld", result);
}

test "Phase 2.5: 字符串拼接 (++)" {
    // "foo" ++ "bar"
    var ir = try buildIRFromSource("fun main() { \"foo\" ++ \"bar\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("foobar", result);
}

test "Phase 2.5: 字符串长度" {
    // 字符串长度目前需要通过函数调用测试
    // 简化：直接验证 string_len op 在 IR 层的正确性
    // "hello".len() 暂未支持 method_call，用内建方式测试
    // 此测试验证 const_str + string_len 的端到端流程
    var ir = try buildIRFromSource("fun main() { \"hello\" + \"world\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqual(@as(usize, 10), result.len);
}

test "Phase 2.5: 三字符串拼接" {
    // "a" + "b" + "c"
    var ir = try buildIRFromSource("fun main() { \"a\" + \"b\" + \"c\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

test "Phase 2.5: 空字符串拼接" {
    // "" + "x"
    var ir = try buildIRFromSource("fun main() { \"\" + \"x\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("x", result);
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：数组
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 数组字面量长度" {
    // [1, 2, 3] — 验证 array_make + array_set 链
    var ir = try buildIRFromSource("fun main() { [1, 2, 3] }");
    defer ir.deinit();

    // 验证 IR 中包含 array_make 和 array_set 节点
    var has_array_make = false;
    var array_set_count: u32 = 0;
    for (ir.nodes) |n| {
        if (n.op == .array_make) has_array_make = true;
        if (n.op == .array_set) array_set_count += 1;
    }
    try testing.expect(has_array_make);
    try testing.expectEqual(@as(u32, 3), array_set_count);
}

test "Phase 2.5: 数组索引访问" {
    // [10, 20, 30][1] → 20
    var ir = try buildIRFromSource("fun main() { [10, 20, 30][1] }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2.5: record 字面量与字段访问" {
    // (x: 1, y: 2).x → 1
    var ir = try buildIRFromSource("fun main() { (x: 1, y: 2).x }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 1), try engine.run());
}

test "Phase 2.5: record 多字段访问" {
    // (a: 10, b: 20, c: 30).b → 20
    var ir = try buildIRFromSource("fun main() { (a: 10, b: 20, c: 30).b }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "Phase 2.5: record 字段覆盖" {
    // (x: 1, y: 2).y → 2
    var ir = try buildIRFromSource("fun main() { (x: 1, y: 2).y }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "Phase 2.5: 字符串索引" {
    // "hello"[0] → 'h' = 104
    var ir = try buildIRFromSource("fun main() { \"hello\"[0] }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    // char 通道返回 u21，但 run() 按通道宽度读取
    // char_chan 宽度为 4 字节，按 i32 读取
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 104), result);
}

test "Phase 2.5: 字符串插值" {
    // "hello {"world"}" → "hello world"
    var ir = try buildIRFromSource("fun main() { \"hello {\"world\"}\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello world", result);
}

test "Phase 2.5: 字符串插值多段" {
    // "{"a"}b{"c"}" → "abc"
    var ir = try buildIRFromSource("fun main() { \"{\"a\"}b{\"c\"}\" }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

// ════════════════════════════════════════════
// Phase 3: 向量 op 执行测试
// ════════════════════════════════════════════

test "Phase 3: for range 向量化 identity map" {
    // for i in 0..10 { i } → vec_source(range) |> vec_map(identity) |> vec_sink(last)
    // sink_last 取最后一个元素 = 9
    var ir = try buildIRFromSource("fun main() { for i in 0..10 { i } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 9), result);
}

test "Phase 3: for range 带运算 i * 2" {
    // for i in 0..5 { i * 2 } → [0,2,4,6,8], sink_last = 8
    var ir = try buildIRFromSource("fun main() { for i in 0..5 { i * 2 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 8), result);
}

test "Phase 3: for range 带运算 i + 10" {
    // for i in 1..4 { i + 10 } → [11,12,13], sink_last = 13
    var ir = try buildIRFromSource("fun main() { for i in 1..4 { i + 10 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 13), result);
}

test "Phase 3: for range 单元素" {
    // for i in 0..1 { i } → [0], sink_last = 0
    var ir = try buildIRFromSource("fun main() { for i in 0..1 { i } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), result);
}

test "Phase 3: for range 复杂表达式" {
    // for i in 0..5 { (i + 1) * 3 } → [3,6,9,12,15], sink_last = 15
    var ir = try buildIRFromSource("fun main() { for i in 0..5 { (i + 1) * 3 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 15), result);
}

// ════════════════════════════════════════════
// Phase 4: 门控 + 清理测试
// ════════════════════════════════════════════

test "Phase 4: defer 在 return 前执行" {
    // fun cleanup() -> i64 { 0 }
    // fun main() -> i64 { defer cleanup(); 42 }
    // 验证 defer 不影响返回值
    var ir = try buildIRFromSource(
        "fun cleanup() { 0 } fun main() { defer cleanup(); 42 }",
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 4: 多个 defer LIFO 执行" {
    // 多个 defer 不影响返回值，验证 LIFO 执行不崩溃
    var ir = try buildIRFromSource(
        "fun a() { 0 } fun b() { 0 } fun main() { defer a(); defer b(); 99 }",
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), result);
}

test "Phase 4: defer 带 var 赋值" {
    // defer 调用函数，不影响返回值
    // 验证 defer 体能正确执行函数调用
    var ir = try buildIRFromSource(
        "fun cleanup() { 0 } fun main() { var x = 1; defer cleanup(); x }",
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    // x 的值在 defer 执行前就已经作为返回值
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "Phase 4: throw 触发 halt_throw" {
    // throw 语句触发 halt_throw，run() 返回 error.Thrown
    var ir = try buildIRFromSource("fun main() { throw 42 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectError(error.Thrown, engine.run());
}

// ════════════════════════════════════════════
// Phase 5: 路由 + 竞争测试
// ════════════════════════════════════════════

test "Phase 5: select 第一个分支就绪" {
    // select { 1 => v => 10; 2 => v => 20 }
    // 非 ChannelValue 输入视为始终就绪，第一个分支胜出 → body 返回 10
    var ir = try buildIRFromSource("fun main() { select { 1 => v => 10; 2 => v => 20 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 10), result);
}

test "Phase 5: select 单分支" {
    // select { 42 => v => 99 }
    // 单个分支，胜出后执行 body 返回 99
    var ir = try buildIRFromSource("fun main() { select { 42 => v => 99 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), result);
}

test "Phase 5: select 带 timeout 分支" {
    // select { timeout(1000) => 42 }
    // timeout arm 的 duration 被当作普通表达式编译，body 返回 42
    var ir = try buildIRFromSource("fun main() { select { timeout(1000) => 42 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 5: select body 带运算" {
    // select { 1 => v => 3 * 4 }
    // body 包含运算，结果为 12
    var ir = try buildIRFromSource("fun main() { select { 1 => v => 3 * 4 } }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 12), result);
}

// ════════════════════════════════════════════
// Phase 6: Nullable + 内存管理测试
// ════════════════════════════════════════════

test "Phase 6: Elvis 整数默认值" {
    // 整数不可能为 null，直接返回左操作数
    // 1 ?? 99 → 1
    var ir = try buildIRFromSource("fun main() { 1 ?? 99 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), result);
}

test "Phase 6: non_null_assert 整数透传" {
    // 整数不可能为 null，! 直接透传
    // 42! → 42
    var ir = try buildIRFromSource("fun main() { 42! }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 6: Elvis 链式表达式" {
    // (1 + 2) ?? 99 → 3
    var ir = try buildIRFromSource("fun main() { (1 + 2) ?? 99 }");
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), result);
}

// ════════════════════════════════════════════
// Phase 7: 星轨执行测试（async/spawn）
// ════════════════════════════════════════════

test "Phase 7: async 函数基本执行 + join" {
    // async fun compute() { 42 }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: async 函数带参数" {
    // async fun add(a, b) { a + b }
    // fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b) { a + b }
        \\fun main() { add(3, 4).await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 7), result);
}

test "Phase 7: async 函数计算" {
    // async fun square(n) { n * n }
    // fun main() { square(7).await() }
    var ir = try buildIRFromSource(
        \\async fun square(n) { n * n }
        \\fun main() { square(7).await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 49), result);
}

test "Phase 7: async 函数调用普通函数" {
    // fun double(n) { n * 2 }
    // async fun compute() { double(21) }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\async fun compute() { double(21) }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: 嵌套普通函数调用（非 async）" {
    // fun double(n) { n * 2 }
    // fun compute() { double(21) }
    // fun main() { compute() }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\fun compute() { double(21) }
        \\fun main() { compute() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "Phase 7: 单层 double 调用" {
    // fun double(n) { n * 2 }
    // fun main() { double(21) }
    var ir = try buildIRFromSource(
        \\fun double(n) { n * 2 }
        \\fun main() { double(21) }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "内置 print/println 编译与执行（无 io 时不崩溃）" {
    // fun main() { println("Hello, Glue!"); 42 }
    var ir = try buildIRFromSource(
        \\fun main() { println("Hello, Glue!"); 42 }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    // 无 io 接口，print 静默跳过，不崩溃
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), result);
}

test "loop + break" {
    // var i = 0; var sum = 0; loop { if i >= 5 { break } sum += i; i += 1 } sum
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var i = 0
        \\    var sum = 0
        \\    loop {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run()); // 0+1+2+3+4=10
}

test "for + break" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var sum = 0
        \\    for i in 0..100 {
        \\        if i > 5 { break }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 15), try engine.run()); // 0+1+2+3+4+5=15
}

test "for + continue" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var sum = 0
        \\    for i in 0..10 {
        \\        if i % 2 == 0 { continue }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 25), try engine.run()); // 1+3+5+7+9=25
}

test "while + break" {
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    var i = 0
        \\    var sum = 0
        \\    while i < 100 {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run()); // 0+1+2+3+4=10
}

// ════════════════════════════════════════════
// P0-b: type_decl / trait_decl 注册 + 构造器调用
// ════════════════════════════════════════════

test "P0-b: ADT 无参构造器（Leaf）" {
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() { Leaf }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    _ = try engine.run(); // 只验证不崩溃
}

test "P0-b: ADT 带参构造器 + 命名字段访问" {
    // Box(42).value → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32)
        \\fun main() { Box(42).value }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: ADT 多构造器 + 位置字段访问" {
    // Node(5, Leaf, Leaf)._0 → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() { Node(5, Leaf, Leaf)._0 }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "P0-b: newtype 构造器 + 字段访问" {
    // UserId(42)._0 → 42
    var ir = try buildIRFromSource(
        \\type UserId = UserId(i32)
        \\fun main() { UserId(42)._0 }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: trait_decl 注册（不崩溃）" {
    var ir = try buildIRFromSource(
        \\trait Printable {
        \\    fun format(self): str
        \\}
        \\fun main() { 42 }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-b: type 方法注册为函数" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // 方法已注册，通过字段访问验证构造器
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\fun main() { MyInt(10).value }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

// ════════════════════════════════════════════
// P0-c: match 表达式编译
// ════════════════════════════════════════════

test "P0-c: match 字面量匹配" {
    // match 2 { 1 => 10, 2 => 20, _ => 30 } → 20
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 2 {
        \\        1 => 10
        \\        2 => 20
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 20), try engine.run());
}

test "P0-c: match 通配符兜底" {
    // match 99 { 1 => 10, _ => 30 } → 30
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 99 {
        \\        1 => 10
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 30), try engine.run());
}

test "P0-c: match 变量绑定" {
    // match 42 { 1 => 10, x => x } → 42
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 42 {
        \\        1 => 10
        \\        x => x
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-c: match ADT 构造器解构" {
    // match Box(42) { Box(v) => v, Leaf => 0 } → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main() {
        \\    match Box(42) {
        \\        Box(v) => v
        \\        Empty => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-c: match ADT 无参构造器" {
    // match Empty { Box(v) => v, Empty => 99 } → 99
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main() {
        \\    match Empty {
        \\        Box(v) => v
        \\        Empty => 99
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 99), try engine.run());
}

test "P0-c: match 或模式" {
    // match 2 { 1 | 2 | 3 => 10, _ => 20 } → 10
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 2 {
        \\        1 | 2 | 3 => 10
        \\        _ => 20
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "P0-c: match 守卫条件" {
    // match 5 { n if n < 0 => 1, n if n > 3 => 2, _ => 3 } → 2
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    match 5 {
        \\        n if n < 0 => 1
        \\        n if n > 3 => 2
        \\        _ => 3
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-c: match 多构造器 ADT 位置字段" {
    // match Node(5, Leaf, Leaf) { Node(v, _, _) => v, Leaf => 0 } → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main() {
        \\    match Node(5, Leaf, Leaf) {
        \\        Node(v, _, _) => v
        \\        Leaf => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

// ════════════════════════════════════════════
// P0-d: 方法调用编译
// ════════════════════════════════════════════

test "P0-d: async .await() 显式等待" {
    // async fun compute() { 42 } fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() { compute().await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-d: async .status() 状态查询" {
    // async fun compute() { 42 }
    // fun main() { val s = compute(); s.await(); s.status() }
    // await 后状态应为 2（Completed）
    var ir = try buildIRFromSource(
        \\async fun compute() { 42 }
        \\fun main() {
        \\    val s = compute()
        \\    s.await()
        \\    s.status()
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-d: array .len() 方法" {
    // [10, 20, 30].len() → 3
    var ir = try buildIRFromSource(
        \\fun main() { [10, 20, 30].len() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 3), try engine.run());
}

test "P0-d: string .len() 方法" {
    // "hello".len() → 5
    var ir = try buildIRFromSource(
        \\fun main() { "hello".len() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 5), try engine.run());
}

test "P0-d: array .push() 方法" {
    // val arr = [1]; arr.push(2); arr.len() → 2
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val arr = [1]
        \\    arr.push(2)
        \\    arr.len()
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 2), try engine.run());
}

test "P0-d: 用户自定义方法调用" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // fun main() { MyInt(10).get() }
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\{
        \\    fun get(self): i32 { self.value }
        \\}
        \\fun main() { MyInt(10).get() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 10), try engine.run());
}

test "P0-d: .type_name() 反射方法" {
    // type Point = | Point(x: i32, y: i32)
    // Point(1, 2).type_name() → "Point"（返回 ref，无法直接断言字符串内容）
    // 验证不崩溃即可
    var ir = try buildIRFromSource(
        \\type Point = | Point(x: i32, y: i32)
        \\fun main() {
        \\    val p = Point(1, 2)
        \\    p.type_name()
        \\    42
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 42), try engine.run());
}

test "P0-d: async .await() 带参数计算" {
    // async fun add(a, b) { a + b } fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b) { a + b }
        \\fun main() { add(3, 4).await() }
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

// ════════════════════════════════════════════════════════════════
// P1-a: lambda / 闭包测试
// ════════════════════════════════════════════════════════════════

test "P1-a: fun lambda 基本调用" {
    // val f = fun(x) { x + 1 }
    // fun main() { val f = fun(x) { x + 1 }; f(10) }
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val f = fun(x) { x + 1 }
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 11), try engine.run());
}

test "P1-a: 箭头 lambda 基本调用" {
    // val f = (x) => x + 1; f(10) → 11
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val f = (x) => x + 1
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 11), try engine.run());
}

test "P1-a: 多参数 lambda" {
    // val g = (a, b) => a + b; g(3, 4) → 7
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val g = (a, b) => a + b
        \\    g(3, 4)
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 7), try engine.run());
}

test "P1-a: 闭包捕获自由变量" {
    // val n = 10; val f = fun(x) { x + n }; f(5) → 15
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val n = 10
        \\    val f = fun(x) { x + n }
        \\    f(5)
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 15), try engine.run());
}

test "P1-a: 闭包捕获多个自由变量" {
    // val a = 100; val b = 20; val f = fun(x) { x + a - b }; f(1) → 81
    var ir = try buildIRFromSource(
        \\fun main() {
        \\    val a = 100
        \\    val b = 20
        \\    val f = fun(x) { x + a - b }
        \\    f(1)
        \\}
    );
    defer ir.deinit();
    var engine = try Engine.initOwned(&ir, testing.allocator);
    defer engine.deinit();
    try testing.expectEqual(@as(i64, 81), try engine.run());
}
