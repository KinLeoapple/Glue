//! OpHandler 分派表与包装函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 OpHandler 类型定义、通用包装器（wrapVoid / wrapPureVoid / wrapSignal /
//! wrapIntBin / wrapIntShift / wrapIntUn / wrapFloatBin / wrapFloatUn / wrapCmp /
//! wrapBoolBin / wrapCast）、halt 处理器（handleHaltReturn / handleHaltThrow /
//! handleHaltPanic / handleHaltBreak / handleHaltContinue / handleUnsupported）、
//! op_handler_table 分派表（NodeOp → OpHandler 映射）、以及标量直接调用包装函数
//! （wrapConstI / wrapIntAdd / wrapCmpEq 等，用于 CompiledBody.insts 数组）。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

const Node = ir_mod.Node;
const NodeOp = ir_mod.NodeOp;

// 标量算术枚举从 scalar_exec.zig 引入
const IntBinOpKind = @import("scalar_exec.zig").IntBinOpKind;
const IntShiftKind = @import("scalar_exec.zig").IntShiftKind;
const IntUnOpKind = @import("scalar_exec.zig").IntUnOpKind;
const FloatBinOpKind = @import("scalar_exec.zig").FloatBinOpKind;
const FloatUnOpKind = @import("scalar_exec.zig").FloatUnOpKind;
const CmpKind = @import("scalar_exec.zig").CmpKind;
const BoolBinOpKind = @import("scalar_exec.zig").BoolBinOpKind;

/// 统一 Op 执行函数签名：返回 ?u16（null=继续执行，非 null=控制流信号）
pub const OpHandler = *const fn (*Engine, *const Node) EngineError!?u16;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 通用包装器（comptime 泛型）
    // ════════════════════════════════════════════

    /// 通用包装器：调用返回 EngineError!void 的方法，然后返回 null
    pub fn wrapVoid(comptime f: anytype) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try f(e, n);
                return null;
            }
        }.call;
    }

    /// 通用包装器：调用返回 void 的方法（无错误），然后返回 null
    pub fn wrapPureVoid(comptime f: anytype) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                f(e, n);
                return null;
            }
        }.call;
    }

    /// 信号包装器：调用返回 EngineError!?u16 的方法，直接返回结果
    pub fn wrapSignal(comptime f: anytype) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                return try f(e, n);
            }
        }.call;
    }

    /// 整数二元运算包装器
    pub fn wrapIntBin(comptime kind: IntBinOpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execIntBinOp(n, kind);
                return null;
            }
        }.call;
    }

    /// 整数移位包装器
    pub fn wrapIntShift(comptime kind: IntShiftKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execIntShift(n, kind);
                return null;
            }
        }.call;
    }

    /// 整数一元运算包装器
    pub fn wrapIntUn(comptime kind: IntUnOpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execIntUnOp(n, kind);
                return null;
            }
        }.call;
    }

    /// 浮点二元运算包装器
    pub fn wrapFloatBin(comptime kind: FloatBinOpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execFloatBinOp(n, kind);
                return null;
            }
        }.call;
    }

    /// 浮点一元运算包装器
    pub fn wrapFloatUn(comptime kind: FloatUnOpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execFloatUnOp(n, kind);
                return null;
            }
        }.call;
    }

    /// 比较运算包装器
    pub fn wrapCmp(comptime kind: CmpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execCmp(n, kind);
                return null;
            }
        }.call;
    }

    /// 布尔二元运算包装器
    pub fn wrapBoolBin(comptime kind: BoolBinOpKind) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execBoolBinOp(n, kind);
                return null;
            }
        }.call;
    }

    /// cast 包装器（带 safe 参数）
    pub fn wrapCast(comptime safe: bool) OpHandler {
        return struct {
            fn call(e: *Engine, n: *const Node) EngineError!?u16 {
                try e.execCast(n, safe);
                return null;
            }
        }.call;
    }

    // ════════════════════════════════════════════
    // halt 处理器
    // ════════════════════════════════════════════

    /// halt_return 处理器：返回 inputs[0]
    pub fn handleHaltReturn(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        return n.inputs[0];
    }

    /// halt_throw 处理器
    pub fn handleHaltThrow(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        _ = n;
        return error.Thrown;
    }

    /// halt_panic / builtin_panic 处理器
    pub fn handleHaltPanic(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        _ = n;
        return error.Panic;
    }

    /// halt_break 处理器
    pub fn handleHaltBreak(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        _ = n;
        return error.LoopBreak;
    }

    /// halt_continue 处理器
    pub fn handleHaltContinue(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        _ = n;
        return error.LoopContinue;
    }

    /// 不支持的操作处理器（cleanup_run 等不通过 execNode 分派的 op）
    pub fn handleUnsupported(e: *Engine, n: *const Node) EngineError!?u16 {
        _ = e;
        _ = n;
        return error.UnsupportedOp;
    }

    // ════════════════════════════════════════════
    // 标量 op 的零 dispatch 包装函数
    // ════════════════════════════════════════════

    /// 每个函数直接调用对应的 exec* 方法，绕过 execNode 的 switch
    /// 用于 CompiledBody.insts 数组，实现 body 内节点的直接调用

    pub fn wrapConstI(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    pub fn wrapConstF(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    pub fn wrapConstBool(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    pub fn wrapConstChar(self: *Engine, node: *const Node) EngineError!void {
        try self.execConst(node);
    }
    pub fn wrapConstStr(self: *Engine, node: *const Node) EngineError!void {
        try self.execConstStr(node);
    }
    pub fn wrapIntAdd(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .add);
    }
    pub fn wrapIntSub(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .sub);
    }
    pub fn wrapIntMul(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .mul);
    }
    pub fn wrapIntDiv(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .div);
    }
    pub fn wrapIntMod(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .mod);
    }
    pub fn wrapIntAnd(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_and);
    }
    pub fn wrapIntOr(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_or);
    }
    pub fn wrapIntXor(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntBinOp(node, .bit_xor);
    }
    pub fn wrapIntShl(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntShift(node, .shl);
    }
    pub fn wrapIntShr(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntShift(node, .shr);
    }
    pub fn wrapIntNeg(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .neg);
    }
    pub fn wrapIntAbs(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .abs);
    }
    pub fn wrapIntNot(self: *Engine, node: *const Node) EngineError!void {
        try self.execIntUnOp(node, .bit_not);
    }
    pub fn wrapFloatAdd(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .add);
    }
    pub fn wrapFloatSub(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .sub);
    }
    pub fn wrapFloatMul(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .mul);
    }
    pub fn wrapFloatDiv(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .div);
    }
    pub fn wrapFloatMod(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatBinOp(node, .mod);
    }
    pub fn wrapFloatNeg(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatUnOp(node, .neg);
    }
    pub fn wrapFloatAbs(self: *Engine, node: *const Node) EngineError!void {
        try self.execFloatUnOp(node, .abs);
    }
    pub fn wrapCmpEq(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .eq);
    }
    pub fn wrapCmpNe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .ne);
    }
    pub fn wrapCmpLt(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .lt);
    }
    pub fn wrapCmpLe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .le);
    }
    pub fn wrapCmpGt(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .gt);
    }
    pub fn wrapCmpGe(self: *Engine, node: *const Node) EngineError!void {
        try self.execCmp(node, .ge);
    }
    pub fn wrapBoolAnd(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolBinOp(node, .and_);
    }
    pub fn wrapBoolOr(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolBinOp(node, .or_);
    }
    pub fn wrapBoolNot(self: *Engine, node: *const Node) EngineError!void {
        try self.execBoolNot(node);
    }
    pub fn wrapCastDirect(self: *Engine, node: *const Node) EngineError!void {
        try self.execCast(node, false);
    }
    pub fn wrapCastSafeDirect(self: *Engine, node: *const Node) EngineError!void {
        try self.execCast(node, true);
    }
    pub fn wrapLoad(self: *Engine, node: *const Node) EngineError!void {
        try self.execLoad(node);
    }
    pub fn wrapStore(self: *Engine, node: *const Node) EngineError!void {
        try self.execStore(node);
    }
    pub fn wrapRefOf(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefOf(node);
    }
    pub fn wrapRefGet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefGet(node);
    }
    pub fn wrapRefSet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRefSet(node);
    }
    pub fn wrapHaltBreak(self: *Engine, node: *const Node) EngineError!void {
        _ = node;
        _ = self;
        return error.LoopBreak;
    }
    pub fn wrapHaltContinue(self: *Engine, node: *const Node) EngineError!void {
        _ = node;
        _ = self;
        return error.LoopContinue;
    }
    pub fn wrapHaltReturn(self: *Engine, node: *const Node) EngineError!void {
        // 设置 pending_halt 信号，TCO 主循环检查后跳出
        self.pending_halt = node.inputs[0];
    }
    pub fn wrapCall(self: *Engine, node: *const Node) EngineError!void {
        try self.execCall(node);
    }
    pub fn wrapVecSelect(self: *Engine, node: *const Node) EngineError!void {
        try self.execVecSelect(node);
    }
    pub fn wrapHaltThrow(self: *Engine, node: *const Node) EngineError!void {
        _ = self;
        _ = node;
        return error.Thrown;
    }
    pub fn wrapRecordMake(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordMake(node);
    }
    pub fn wrapRecordGet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordGet(node);
    }
    pub fn wrapRecordSet(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordSet(node);
    }
    pub fn wrapRecordClone(self: *Engine, node: *const Node) EngineError!void {
        try self.execRecordClone(node);
    }
    pub fn wrapRouteGetTag(self: *Engine, node: *const Node) EngineError!void {
        try self.execRouteGetTag(node);
    }
    pub fn wrapRouteDispatch(self: *Engine, node: *const Node) EngineError!void {
        // route_dispatch 可能返回 halt channel（body 内含 halt 节点）
        // 通过 pending_halt 传播，与非 TCO direct 路径的 halt 机制一致
        if (try self.execRouteDispatch(node)) |halt_chan| {
            self.pending_halt = halt_chan;
        }
    }
    pub fn wrapRouteMerge(self: *Engine, node: *const Node) EngineError!void {
        try self.execRouteMerge(node);
    }
};

/// Op 分派表：NodeOp → OpHandler
/// v3 阶段 5：替代 execNode 的 145 分支 switch。新增 op = 追加一条 t.set。
pub const op_handler_table: std.EnumArray(NodeOp, OpHandler) = blk: {
    @setEvalBranchQuota(20000);
    var t = std.EnumArray(NodeOp, OpHandler).initUndefined();

    // === 常量 ===
    t.set(.const_i, Methods.wrapVoid(Engine.execConst));
    t.set(.const_f, Methods.wrapVoid(Engine.execConst));
    t.set(.const_bool, Methods.wrapVoid(Engine.execConst));
    t.set(.const_char, Methods.wrapVoid(Engine.execConst));
    t.set(.const_unit, Methods.wrapPureVoid(Engine.execConstUnit));
    t.set(.const_null, Methods.wrapPureVoid(Engine.execConstNull));
    t.set(.const_str, Methods.wrapVoid(Engine.execConstStr));

    // === 整数算术 ===
    t.set(.int_add, Methods.wrapIntBin(.add));
    t.set(.int_sub, Methods.wrapIntBin(.sub));
    t.set(.int_mul, Methods.wrapIntBin(.mul));
    t.set(.int_div, Methods.wrapIntBin(.div));
    t.set(.int_mod, Methods.wrapIntBin(.mod));
    t.set(.int_and, Methods.wrapIntBin(.bit_and));
    t.set(.int_or, Methods.wrapIntBin(.bit_or));
    t.set(.int_xor, Methods.wrapIntBin(.bit_xor));
    t.set(.int_shl, Methods.wrapIntShift(.shl));
    t.set(.int_shr, Methods.wrapIntShift(.shr));

    // === 整数一元 ===
    t.set(.int_neg, Methods.wrapIntUn(.neg));
    t.set(.int_abs, Methods.wrapIntUn(.abs));
    t.set(.int_not, Methods.wrapIntUn(.bit_not));

    // === 浮点算术 ===
    t.set(.float_add, Methods.wrapFloatBin(.add));
    t.set(.float_sub, Methods.wrapFloatBin(.sub));
    t.set(.float_mul, Methods.wrapFloatBin(.mul));
    t.set(.float_div, Methods.wrapFloatBin(.div));
    t.set(.float_mod, Methods.wrapFloatBin(.mod));

    // === 浮点一元 ===
    t.set(.float_neg, Methods.wrapFloatUn(.neg));
    t.set(.float_abs, Methods.wrapFloatUn(.abs));

    // === 比较 ===
    t.set(.cmp_eq, Methods.wrapCmp(.eq));
    t.set(.cmp_ne, Methods.wrapCmp(.ne));
    t.set(.cmp_lt, Methods.wrapCmp(.lt));
    t.set(.cmp_le, Methods.wrapCmp(.le));
    t.set(.cmp_gt, Methods.wrapCmp(.gt));
    t.set(.cmp_ge, Methods.wrapCmp(.ge));

    // === 布尔逻辑 ===
    t.set(.bool_and, Methods.wrapBoolBin(.and_));
    t.set(.bool_or, Methods.wrapBoolBin(.or_));
    t.set(.bool_not, Methods.wrapVoid(Engine.execBoolNot));

    // === 内存操作 ===
    t.set(.load, Methods.wrapVoid(Engine.execLoad));
    t.set(.store, Methods.wrapVoid(Engine.execStore));

    // === 借用引用 ===
    t.set(.ref_of, Methods.wrapVoid(Engine.execRefOf));
    t.set(.ref_get, Methods.wrapVoid(Engine.execRefGet));
    t.set(.ref_set, Methods.wrapVoid(Engine.execRefSet));

    // === 选择 ===
    t.set(.vec_select, Methods.wrapVoid(Engine.execVecSelect));

    // === 类型转换 ===
    t.set(.cast, Methods.wrapCast(false));
    t.set(.cast_safe, Methods.wrapCast(true));
    t.set(.cast_to, Methods.wrapVoid(Engine.execCastTo));
    t.set(.cast_try_to, Methods.wrapVoid(Engine.execCastTryTo));

    // === 字符串操作 ===
    t.set(.string_len, Methods.wrapVoid(Engine.execStringLen));
    t.set(.string_concat, Methods.wrapVoid(Engine.execStringConcat));
    t.set(.string_cmp, Methods.wrapVoid(Engine.execStringCmp));
    t.set(.string_index, Methods.wrapVoid(Engine.execStringIndex));
    t.set(.string_contains, Methods.wrapVoid(Engine.execStringContains));
    t.set(.string_slice, Methods.wrapVoid(Engine.execStringSlice));
    t.set(.string_bytes, Methods.wrapVoid(Engine.execStringBytes));
    t.set(.array_to_str, Methods.wrapVoid(Engine.execArrayToStr));

    // === 数组操作 ===
    t.set(.array_make, Methods.wrapVoid(Engine.execArrayMake));
    t.set(.array_get, Methods.wrapVoid(Engine.execArrayGet));
    t.set(.array_set, Methods.wrapVoid(Engine.execArraySet));
    t.set(.array_len, Methods.wrapVoid(Engine.execArrayLen));
    t.set(.array_concat, Methods.wrapVoid(Engine.execArrayConcat));
    t.set(.array_fill, Methods.wrapVoid(Engine.execArrayFill));
    t.set(.array_slice, Methods.wrapVoid(Engine.execArraySlice));

    // === 记录操作 ===
    t.set(.record_make, Methods.wrapVoid(Engine.execRecordMake));
    t.set(.record_get, Methods.wrapVoid(Engine.execRecordGet));
    t.set(.record_set, Methods.wrapVoid(Engine.execRecordSet));
    t.set(.record_clone, Methods.wrapVoid(Engine.execRecordClone));

    // === 向量操作 ===
    t.set(.vec_source, Methods.wrapVoid(Engine.execVecSource));
    t.set(.vec_map, Methods.wrapVoid(Engine.execVecMap));
    t.set(.vec_map2, Methods.wrapVoid(Engine.execVecMap2));
    t.set(.vec_sink, Methods.wrapVoid(Engine.execVecSink));
    t.set(.vec_fold, Methods.wrapVoid(Engine.execVecFold));
    t.set(.vec_scan, Methods.wrapVoid(Engine.execVecScan));
    t.set(.vec_filter, Methods.wrapVoid(Engine.execVecFilter));
    t.set(.vec_take, Methods.wrapVoid(Engine.execVecTake));
    t.set(.vec_take_while, Methods.wrapVoid(Engine.execVecTakeWhile));
    t.set(.vec_zip, Methods.wrapVoid(Engine.execVecZip));

    // === 门控 ===
    t.set(.gate_check, Methods.wrapVoid(Engine.execGateCheck));
    t.set(.gate_get_ok, Methods.wrapVoid(Engine.execGateGetOk));
    t.set(.gate_get_err, Methods.wrapVoid(Engine.execGateGetErr));
    t.set(.gate_propagate, Methods.wrapVoid(Engine.execGatePropagate));
    t.set(.gate_select, Methods.wrapVoid(Engine.execGateSelect));
    t.set(.gate_make_ok, Methods.wrapVoid(Engine.execGateMakeOk));
    t.set(.gate_make_err, Methods.wrapVoid(Engine.execGateMakeErr));

    // === 清理 ===
    t.set(.cleanup_register, Methods.wrapVoid(Engine.execCleanupRegister));
    t.set(.cleanup_run, Methods.handleUnsupported); // 由 execFunction 在 halt 时直接调用

    // === 路由 + 竞争 ===
    t.set(.race_source, Methods.wrapVoid(Engine.execRaceSource));
    t.set(.race_select, Methods.wrapVoid(Engine.execRaceSelect));
    t.set(.race_yield, Methods.wrapVoid(Engine.execRaceYield));
    t.set(.route_get_tag, Methods.wrapVoid(Engine.execRouteGetTag));
    t.set(.route_dispatch, Methods.wrapSignal(Engine.execRouteDispatch));
    t.set(.route_merge, Methods.wrapVoid(Engine.execRouteMerge));

    // === Nullable ===
    t.set(.nullable_make, Methods.wrapVoid(Engine.execNullableMake));
    t.set(.nullable_is_null, Methods.wrapVoid(Engine.execNullableIsNull));
    t.set(.nullable_unwrap, Methods.wrapVoid(Engine.execNullableUnwrap));
    t.set(.nullable_unwrap_or, Methods.wrapVoid(Engine.execNullableUnwrapOr));

    // === 内存管理 ===
    t.set(.alloc, Methods.wrapVoid(Engine.execAlloc));
    t.set(.free, Methods.wrapVoid(Engine.execFree));

    // === 星轨执行 ===
    t.set(.orbit_async_create, Methods.wrapVoid(Engine.execOrbitAsyncCreate));
    t.set(.orbit_async_join, Methods.wrapVoid(Engine.execOrbitAsyncJoin));
    t.set(.orbit_async_status, Methods.wrapVoid(Engine.execOrbitAsyncStatus));
    t.set(.orbit_chan_send, Methods.wrapVoid(Engine.execOrbitChanSend));
    t.set(.orbit_chan_recv, Methods.wrapVoid(Engine.execOrbitChanRecv));
    t.set(.orbit_chan_try_recv, Methods.wrapVoid(Engine.execOrbitChanTryRecv));
    t.set(.channel_close, Methods.wrapVoid(Engine.execChannelClose));
    t.set(.channel_create, Methods.wrapVoid(Engine.execChannelCreate));
    t.set(.channel_sender, Methods.wrapVoid(Engine.execChannelSender));
    t.set(.channel_receiver, Methods.wrapVoid(Engine.execChannelReceiver));

    // === 原子操作 ===
    t.set(.atomic_make, Methods.wrapVoid(Engine.execAtomicMake));
    t.set(.atomic_fetch_add, Methods.wrapVoid(Engine.execAtomicFetchAdd));
    t.set(.atomic_swap, Methods.wrapVoid(Engine.execAtomicSwap));
    t.set(.atomic_cas, Methods.wrapVoid(Engine.execAtomicCas));

    // === 反射方法已移除（message/type_name 走 trait 分派） ===

    // === 闭包 ===
    t.set(.closure_make, Methods.wrapVoid(Engine.execClosureMake));
    t.set(.call_indirect, Methods.wrapVoid(Engine.execCallIndirect));

    // === 部分应用 ===
    t.set(.partial_make, Methods.wrapVoid(Engine.execPartialMake));

    // === 惰性求值 ===
    t.set(.lazy_make, Methods.wrapVoid(Engine.execLazyMake));
    t.set(.lazy_force, Methods.wrapVoid(Engine.execLazyForce));

    // === 控制流 ===
    t.set(.call, Methods.wrapVoid(Engine.execCall));
    t.set(.halt_return, Methods.handleHaltReturn);
    t.set(.halt_throw, Methods.handleHaltThrow);
    t.set(.halt_panic, Methods.handleHaltPanic);
    t.set(.halt_break, Methods.handleHaltBreak);
    t.set(.halt_continue, Methods.handleHaltContinue);
    t.set(.scalar_loop, Methods.wrapSignal(Engine.execScalarLoop));

    // === 内置函数 ===
    t.set(.builtin_ok, Methods.wrapVoid(Engine.execBuiltinOk));
    t.set(.builtin_error, Methods.wrapVoid(Engine.execBuiltinError));
    t.set(.builtin_eq, Methods.wrapVoid(Engine.execBuiltinEq));
    t.set(.builtin_ref_eq, Methods.wrapVoid(Engine.execBuiltinRefEq));
    t.set(.builtin_str, Methods.wrapVoid(Engine.execBuiltinStr));
    t.set(.builtin_type, Methods.wrapVoid(Engine.execBuiltinType));
    t.set(.builtin_typeof, Methods.wrapVoid(Engine.execBuiltinTypeof));
    t.set(.builtin_reflect, Methods.wrapVoid(Engine.execBuiltinReflect));
    t.set(.builtin_reflect_field, Methods.wrapVoid(Engine.execBuiltinReflectField));
    t.set(.builtin_scalar_to_str, Methods.wrapVoid(Engine.execBuiltinScalarToStr));
    t.set(.builtin_reflect_deref, Methods.wrapVoid(Engine.execBuiltinReflectDeref));
    t.set(.builtin_reflect_field_name, Methods.wrapVoid(Engine.execBuiltinReflectFieldName));
    t.set(.builtin_reflect_meta, Methods.wrapVoid(Engine.execBuiltinReflectMeta));
    t.set(.builtin_panic, Methods.handleHaltPanic);

    // === Syscall ===
    t.set(.syscall_call, Methods.wrapVoid(Engine.execSyscall));

    // === Newtype ===
    t.set(.newtype_wrap, Methods.wrapVoid(Engine.execNewtypeWrap));
    t.set(.newtype_unwrap, Methods.wrapVoid(Engine.execNewtypeUnwrap));

    break :blk t;
};
