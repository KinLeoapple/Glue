//! 标量算术执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含标量分派函数（dispatchXxx / dispatchBatchXxx / nodeOpToBatchXxx）、
//! 整数/浮点/比较/布尔算术枚举与 exec 函数（execIntBinOp / execFloatBinOp /
//! execCmp / execBoolBinOp / execBoolNot 等）、以及常量执行函数
//! （execConst / execConstUnit / execConstNull / execConstStr）。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;
const ScalarExecFn = engine_mod.ScalarExecFn;

const Node = ir_mod.Node;
const NodeOp = ir_mod.NodeOp;

const scalar = value.scalar;
const ScalarTag = scalar.ScalarTag;
const ops = value.ops;
const batch = value.batch;

// ════════════════════════════════════════════
// 标量算术枚举（跨文件可见，engine.zig 通过 pub const 别名引用）
// ════════════════════════════════════════════

pub const IntBinOpKind = enum { add, sub, mul, div, mod, bit_and, bit_or, bit_xor };
pub const IntShiftKind = enum { shl, shr };
pub const IntUnOpKind = enum { neg, abs, bit_not };
pub const FloatBinOpKind = enum { add, sub, mul, div, mod };
pub const FloatUnOpKind = enum { neg, abs };
pub const CmpKind = enum { eq, ne, lt, le, gt, ge };
pub const BoolBinOpKind = enum { and_, or_ };

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 标量分派函数（comptime 泛型 + 批量运算）
    // ════════════════════════════════════════════

    /// 运行时 tag → comptime 分派：整数二元运算
    /// 通过 inline switch 展开所有整数类型，每个分支调用 comptime 特化的 ops 函数
    pub fn dispatchIntBinOp(tag: ScalarTag, kind: IntBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
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
    pub fn dispatchFloatBinOp(tag: ScalarTag, kind: FloatBinOpKind, a: [16]u8, b: [16]u8) ?[16]u8 {
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
            .mod => ops.mod(tag, a_bytes, b_bytes),
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：整数一元运算
    pub fn dispatchIntUnOp(tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) ?[16]u8 {
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

    fn dispatchIntUnOpT(comptime tag: ScalarTag, kind: IntUnOpKind, a: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .bit_not => @as(?ByteArrayT, ops.bitNot(tag, a_bytes)),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                const r = if (@typeInfo(T).int.signedness == .signed) @abs(av) else av;
                break :blk @as(?ByteArrayT, @bitCast(@as(T, @intCast(r))));
            },
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：浮点一元运算
    pub fn dispatchFloatUnOp(tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) ?[16]u8 {
        return switch (tag) {
            .f16 => dispatchFloatUnOpT(.f16, kind, a),
            .f32 => dispatchFloatUnOpT(.f32, kind, a),
            .f64 => dispatchFloatUnOpT(.f64, kind, a),
            .f128 => dispatchFloatUnOpT(.f128, kind, a),
            else => null,
        };
    }

    fn dispatchFloatUnOpT(comptime tag: ScalarTag, kind: FloatUnOpKind, a: [16]u8) ?[16]u8 {
        const W = comptime scalar.byteWidth(tag);
        const ByteArrayT = scalar.ByteArray(tag);
        const a_bytes: ByteArrayT = a[0..W].*;
        const result: ?ByteArrayT = switch (kind) {
            .neg => ops.neg(tag, a_bytes),
            .abs => blk: {
                const T = scalar.NativeType(tag);
                const av: T = @bitCast(a_bytes);
                break :blk @as(?ByteArrayT, @bitCast(@abs(av)));
            },
        };
        if (result) |r| {
            var out: [16]u8 = [_]u8{0} ** 16;
            out[0..W].* = r;
            return out;
        }
        return null;
    }

    /// 运行时 tag → comptime 分派：比较运算
    /// 所有 ScalarTag 变体均已覆盖，无需 else 分支
    /// boolean 类型不经过 ops（@bitCast 位宽不匹配），直接内联比较
    pub fn dispatchCmp(tag: ScalarTag, kind: CmpKind, a: [16]u8, b: [16]u8) bool {
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
    pub fn dispatchInlineBinOp(op: NodeOp, tag: ScalarTag, a: [16]u8, b: [16]u8) EngineError![16]u8 {
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
            .float_mod => dispatchFloatBinOp(tag, .mod, a, b) orelse return error.Overflow,
            else => return error.UnsupportedOp,
        };
    }

    /// NodeOp → batch.BinOp 映射（仅数值算术/位运算）
    /// 用于 vec_fold/vec_scan 内联模式接入 SIMD 批量运算
    /// v3 阶段 5：委托给 ir/op_table.zig 的 OpTable.batchBinOp
    pub fn nodeOpToBatchBinOp(op: NodeOp) ?batch.BinOp {
        return ir_mod.OpTable.batchBinOp(op);
    }

    /// SIMD 批量归约分派：运行时 tag × op 通过 inline switch 展开为 comptime 特化调用
    /// 用于 vec_fold 内联模式（body_len == 0），用 @reduce 横向归约替代逐元素 dispatch
    pub fn dispatchBatchReduce(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        init_bytes: [16]u8,
        src_chan: u16,
        count: u32,
    ) EngineError![16]u8 {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .isize, .usize,
                    .f16, .f32, .f64, .f128 => |comptime_tag| blk: {
                        const T = scalar.NativeType(comptime_tag);
                        // init_bytes [16]u8 → T（前 @sizeOf(T) 字节有效）
                        var t_init: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&t_init))[0..@sizeOf(T)],
                            init_bytes[0..@sizeOf(T)],
                        );
                        // 通道字节指针 → 类型化切片（region 64B 对齐，满足所有标量 T）
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const t_result = batch.batchReduce(T, comptime_op, t_init, src_ptr[0..count]) catch |err| return err;
                        // T → [16]u8
                        var out: [16]u8 = [_]u8{0} ** 16;
                        @memcpy(
                            out[0..@sizeOf(T)],
                            @as([*]const u8, @ptrCast(&t_result))[0..@sizeOf(T)],
                        );
                        break :blk out;
                    },
                    else => return error.UnsupportedOp,
                };
            },
            .shl, .shr => return error.UnsupportedOp,
        };
    }

    /// SIMD 批量前缀扫描分派：用于 vec_scan 内联模式（body_len == 0）
    /// 块内 inclusive scan + 块间累加器修正，替代逐元素 dispatch
    pub fn dispatchBatchScan(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        init_bytes: [16]u8,
        dst_chan: u16,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var t_init: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&t_init))[0..@sizeOf(T)],
                            init_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchScan(T, comptime_op, t_init, dst_ptr[0..count], src_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
            .shl, .shr => return error.UnsupportedOp,
        };
    }

    /// NodeOp → batch.UnaryOp 映射（仅一元算术/位运算）
    /// 用于 vec_map 内联单节点 body 批量化
    /// v3 阶段 5：委托给 ir/op_table.zig 的 OpTable.batchUnaryOp
    pub fn nodeOpToBatchUnaryOp(op: NodeOp) ?batch.UnaryOp {
        return ir_mod.OpTable.batchUnaryOp(op);
    }

    /// 一元 map 批量分派：dst[i] = unop(src[i])
    /// 用于 vec_map 的 body 是单个一元 op 节点的情况
    pub fn dispatchBatchMapUnary(
        self: *Engine,
        tag: ScalarTag,
        uop: batch.UnaryOp,
        dst_chan: u16,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (uop) {
            inline .neg, .abs, .bnot => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchUnary(T, comptime_op, dst_ptr[0..count], src_ptr[0..count]);
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（标量右操作数）批量分派：dst[i] = src[i] op scalar
    /// 用于 vec_map 的 body 是 `x op const` 形式
    pub fn dispatchBatchMapScalarR(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        src_chan: u16,
        scalar_bytes: [16]u8,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var scalar_val: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&scalar_val))[0..@sizeOf(T)],
                            scalar_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOpScalar(T, comptime_op, dst_ptr[0..count], src_ptr[0..count], scalar_val) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（标量左操作数）批量分派：dst[i] = scalar op src[i]
    /// 用于 vec_map 的 body 是 `const op x` 形式
    pub fn dispatchBatchMapScalarL(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        scalar_bytes: [16]u8,
        src_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        var scalar_val: T = undefined;
                        @memcpy(
                            @as([*]u8, @ptrCast(&scalar_val))[0..@sizeOf(T)],
                            scalar_bytes[0..@sizeOf(T)],
                        );
                        const src_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(src_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOpScalarR(T, comptime_op, dst_ptr[0..count], scalar_val, src_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    /// 二元 map（双向量）批量分派：dst[i] = left[i] op right[i]
    /// 用于 vec_map2 的 body 是单个二元 op 节点的情况
    pub fn dispatchBatchMap2(
        self: *Engine,
        tag: ScalarTag,
        bop: batch.BinOp,
        dst_chan: u16,
        left_chan: u16,
        right_chan: u16,
        count: u32,
    ) EngineError!void {
        return switch (bop) {
            inline .add, .sub, .mul, .div, .mod, .band, .bor, .bxor, .shl, .shr => |comptime_op| {
                return switch (tag) {
                    inline .i8, .i16, .i32, .i64, .i128,
                    .u8, .u16, .u32, .u64, .u128,
                    .f16, .f32, .f64, .f128 => |comptime_tag| {
                        const T = scalar.NativeType(comptime_tag);
                        const left_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(left_chan)));
                        const right_ptr: [*]const T = @ptrCast(@alignCast(self.runtime.rawPtr(right_chan)));
                        const dst_ptr: [*]T = @ptrCast(@alignCast(self.runtime.rawPtr(dst_chan)));
                        batch.batchBinOp(T, comptime_op, dst_ptr[0..count], left_ptr[0..count], right_ptr[0..count]) catch |err| return err;
                    },
                    else => return error.UnsupportedOp,
                };
            },
        };
    }

    // ════════════════════════════════════════════
    // 常量执行
    // ════════════════════════════════════════════

    pub fn execConst(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            self.runtime.writeConst(node.output, cv, meta.kind);
        }
    }

    pub fn execConstUnit(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    pub fn execConstNull(self: *Engine, node: *const Node) void {
        _ = self;
        _ = node;
    }

    pub fn execConstStr(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index > self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];
        if (meta.const_val) |cv| {
            // const_str 的 const_val.int_val 是字符串池索引
            if (cv == .int_val) {
                const str_idx: usize = @intCast(cv.int_val);
                if (str_idx >= self.ir.string_pool.len) return error.InvalidMetaIndex;
                const bytes = self.ir.string_pool[str_idx];
                // 在堆上创建 Str 对象
                const v = value.Value.fromStringBytes(self.tctx.?, bytes) catch return error.OutOfMemory;
                try self.trackObj(v.asRef());
                // 将 *ObjHeader 指针写入通道
                _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(v.asRef())));
            }
        }
    }

    // ════════════════════════════════════════════
    // 整数算术（复用 value.ops）
    // ════════════════════════════════════════════

    pub inline fn execIntBinOp(self: *Engine, node: *const Node, kind: IntBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag（0xFF = 无标量类型，预计算阶段已填充）
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 字符串拼接由专用 string_concat 节点处理（builder 按 operand_type 分派）
        // int_add 路径只处理纯整数运算，无需运行时 hashmap 查找

        // 快速路径：按 comptime tag 直接指针读写原生类型，跳过 16B 中间缓冲
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const result: T = switch (kind) {
                    .add => blk: {
                        const r, const overflow = @addWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .sub => blk: {
                        const r, const overflow = @subWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .mul => blk: {
                        const r, const overflow = @mulWithOverflow(a, b);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .div => blk: {
                        if (b == 0) return error.DivisionByZero;
                        break :blk @divTrunc(a, b);
                    },
                    .mod => blk: {
                        if (b == 0) return error.DivisionByZero;
                        break :blk @rem(a, b);
                    },
                    .bit_and => a & b,
                    .bit_or => a | b,
                    .bit_xor => a ^ b,
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    pub fn execIntShift(self: *Engine, node: *const Node, kind: IntShiftKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，保留各类型的原生位宽语义
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const max_bits = @bitSizeOf(T);
                // b 可能是 i128/u128，值 >= 2^64 时 @intCast 到 u64 会 panic。
                // 先检查移位量是否 >= 位宽（>= 位宽时结果为 0），再安全窄化。
                const b_val = if (b < 0) 0 else b;
                if (b_val >= max_bits) {
                    self.runtime.writeScalarAt(comptime_tag, node.output, 0);
                    return;
                }
                const raw: u64 = @intCast(b_val);
                const result: T = switch (kind) {
                    .shl => a << @intCast(raw),
                    .shr => a >> @intCast(raw),
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    pub fn execIntUnOp(self: *Engine, node: *const Node, kind: IntUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
        return switch (tag) {
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, input_chan);
                const result: T = switch (kind) {
                    .neg => blk: {
                        const r, const overflow = @subWithOverflow(@as(T, 0), a);
                        if (overflow != 0) return error.Overflow;
                        break :blk r;
                    },
                    .abs => blk: {
                        const ti = @typeInfo(T).int;
                        if (ti.signedness == .signed) {
                            // iN::MIN 的绝对值超出正数范围，溢出报错（与 neg 一致）
                            if (a == std.math.minInt(T)) return error.Overflow;
                            break :blk @intCast(@abs(a));
                        } else {
                            break :blk a;
                        }
                    },
                    .bit_not => ~a,
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    // ════════════════════════════════════════════
    // 浮点算术（复用 value.ops）
    // ════════════════════════════════════════════

    pub fn execFloatBinOp(self: *Engine, node: *const Node, kind: FloatBinOpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写原生浮点，跳过 16B 中间缓冲
        return switch (tag) {
            inline .f16, .f32, .f64, .f128 => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                const result: T = switch (kind) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .mod => @rem(a, b),
                };
                // NaN 是无定义结果（如 0.0/0.0、@rem(a,0)），触发错误；
                // Inf 是 IEEE 754 合法极值（如 1.0/0.0），保持标准行为
                if (std.math.isNan(result)) {
                    return error.Overflow;
                }
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    pub fn execFloatUnOp(self: *Engine, node: *const Node, kind: FloatUnOpKind) EngineError!void {
        const input_chan = node.inputs[0];

        // 读取预计算的 ScalarTag
        if (node.scalar_tag == 0xFF) return error.UnsupportedOp;
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
        return switch (tag) {
            inline .f16, .f32, .f64, .f128 => |comptime_tag| {
                const T = scalar.NativeType(comptime_tag);
                const a = self.runtime.readScalarAt(comptime_tag, input_chan);
                const result: T = switch (kind) {
                    .neg => -a,
                    .abs => @abs(a),
                };
                self.runtime.writeScalarAt(comptime_tag, node.output, result);
            },
            else => return error.UnsupportedOp,
        };
    }

    // ════════════════════════════════════════════
    // 比较（复用 value.ops）
    // ════════════════════════════════════════════

    pub inline fn execCmp(self: *Engine, node: *const Node, kind: CmpKind) EngineError!void {
        const left_chan = node.inputs[0];
        const right_chan = node.inputs[1];

        // 读取预计算的 ScalarTag（0xFF = 非标量通道，预计算阶段已填充）
        // tag 来自左输入通道（输出是 bool，不能用于推导）
        if (node.scalar_tag == 0xFF) {
            // 非标量通道：== 和 != 使用递归值相等（value.equals）
            // 其他比较（< > <= >=）退化为指针比较（仅用于排序/判空）
            if (kind == .eq or kind == .ne) {
                const a_val = self.chanToValue(left_chan);
                const b_val = self.chanToValue(right_chan);
                const eq_result = value.equals(a_val, b_val);
                self.runtime.writeBool(node.output, if (kind == .eq) eq_result else !eq_result);
                return;
            }
            // < > <= >= 对非标量退化为指针比较
            const a = if (left_chan < self.runtime.chan_count and self.runtime.chanPtrs(left_chan) != null)
                self.runtime.readI64(left_chan)
            else
                0;
            const b = if (right_chan < self.runtime.chan_count and self.runtime.chanPtrs(right_chan) != null)
                self.runtime.readI64(right_chan)
            else
                0;
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
        }
        const tag: ScalarTag = @enumFromInt(node.scalar_tag);

        // 快速路径：按 comptime tag 直接指针读写，覆盖 int/uint/float/bool 所有类型
        const result: bool = switch (tag) {
            .boolean => blk: {
                const a = self.runtime.readBool(left_chan);
                const b = self.runtime.readBool(right_chan);
                break :blk switch (kind) {
                    .eq => a == b,
                    .ne => a != b,
                    .lt => !a and b,
                    .le => !a or b,
                    .gt => a and !b,
                    .ge => a or b,
                };
            },
            inline .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            .f16, .f32, .f64, .f128, .char => |comptime_tag| blk: {
                const a = self.runtime.readScalarAt(comptime_tag, left_chan);
                const b = self.runtime.readScalarAt(comptime_tag, right_chan);
                break :blk switch (kind) {
                    .eq => a == b,
                    .ne => a != b,
                    .lt => a < b,
                    .le => a <= b,
                    .gt => a > b,
                    .ge => a >= b,
                };
            },
        };
        self.runtime.writeBool(node.output, result);
    }

    // ════════════════════════════════════════════
    // 布尔逻辑
    // ════════════════════════════════════════════

    pub fn execBoolBinOp(self: *Engine, node: *const Node, kind: BoolBinOpKind) EngineError!void {
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

    pub fn execBoolNot(self: *Engine, node: *const Node) EngineError!void {
        const input_chan = node.inputs[0];
        const a = self.runtime.readBool(input_chan);
        self.runtime.writeBool(node.output, !a);
    }

    // ════════════════════════════════════════════
    // 直接调用映射
    // ════════════════════════════════════════════

    /// NodeOp → 直接调用函数指针映射
    /// 返回 null 表示该 op 不支持直接调用（非标量 op 或含动态分派）
    pub fn opToScalarExecFn(op: NodeOp) ?ScalarExecFn {
        return switch (op) {
            .const_i => &Engine.wrapConstI,
            .const_f => &Engine.wrapConstF,
            .const_bool => &Engine.wrapConstBool,
            .const_char => &Engine.wrapConstChar,
            .const_str => &Engine.wrapConstStr,
            .int_add => &Engine.wrapIntAdd,
            .int_sub => &Engine.wrapIntSub,
            .int_mul => &Engine.wrapIntMul,
            .int_div => &Engine.wrapIntDiv,
            .int_mod => &Engine.wrapIntMod,
            .int_and => &Engine.wrapIntAnd,
            .int_or => &Engine.wrapIntOr,
            .int_xor => &Engine.wrapIntXor,
            .int_shl => &Engine.wrapIntShl,
            .int_shr => &Engine.wrapIntShr,
            .int_neg => &Engine.wrapIntNeg,
            .int_abs => &Engine.wrapIntAbs,
            .int_not => &Engine.wrapIntNot,
            .float_add => &Engine.wrapFloatAdd,
            .float_sub => &Engine.wrapFloatSub,
            .float_mul => &Engine.wrapFloatMul,
            .float_div => &Engine.wrapFloatDiv,
            .float_mod => &Engine.wrapFloatMod,
            .float_neg => &Engine.wrapFloatNeg,
            .float_abs => &Engine.wrapFloatAbs,
            .cmp_eq => &Engine.wrapCmpEq,
            .cmp_ne => &Engine.wrapCmpNe,
            .cmp_lt => &Engine.wrapCmpLt,
            .cmp_le => &Engine.wrapCmpLe,
            .cmp_gt => &Engine.wrapCmpGt,
            .cmp_ge => &Engine.wrapCmpGe,
            .bool_and => &Engine.wrapBoolAnd,
            .bool_or => &Engine.wrapBoolOr,
            .bool_not => &Engine.wrapBoolNot,
            .cast => &Engine.wrapCastDirect,
            .cast_safe => &Engine.wrapCastSafeDirect,
            .load => &Engine.wrapLoad,
            .store => &Engine.wrapStore,
            .ref_of => &Engine.wrapRefOf,
            .ref_get => &Engine.wrapRefGet,
            .ref_set => &Engine.wrapRefSet,
            .halt_break => &Engine.wrapHaltBreak,
            .halt_continue => &Engine.wrapHaltContinue,
            .halt_return => &Engine.wrapHaltReturn,
            .halt_throw => &Engine.wrapHaltThrow,
            .call => &Engine.wrapCall,
            .vec_select => &Engine.wrapVecSelect,
            .record_make => &Engine.wrapRecordMake,
            .record_get => &Engine.wrapRecordGet,
            .record_set => &Engine.wrapRecordSet,
            .record_clone => &Engine.wrapRecordClone,
            .route_get_tag => &Engine.wrapRouteGetTag,
            .route_dispatch => &Engine.wrapRouteDispatch,
            .route_merge => &Engine.wrapRouteMerge,
            else => null,
        };
    }
};
