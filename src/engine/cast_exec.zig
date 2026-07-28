//! cast 执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execCast / scalarBytesToValue / execCastTo / execCastTryTo /
//! execCastTryToStrNumeric / constructCastErrorThrow / constructCastErrorThrowStr /
//! emitCastErrorThrow / scalarKindToTag / isInfResult 等执行函数。
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
const ScalarKind = ir_mod.ScalarKind;

const scalar = value.scalar;
const ScalarTag = scalar.ScalarTag;
const cast_mod = value.cast;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 类型转换（复用 value.cast）
    // ════════════════════════════════════════════

    /// cast/cast_safe：标量类型转换
    /// meta_index 指向 ScalarMeta，描述目标类型
    /// inputs[0] = 源通道
    pub fn execCast(self: *Engine, node: *const Node, safe: bool) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);
        const src_tag = engine_mod.Engine.chanToScalarTag(src_meta) orelse return error.UnsupportedOp;
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

    /// 从 ScalarTag + [16]u8 字节直接构造 Value（不经过通道）
    /// 用于 cast_try_to 成功路径：避免在通道上用 chanToValue 误读标量字节为指针
    pub fn scalarBytesToValue(tag: ScalarTag, bytes: [16]u8) value.Value {
        return switch (tag) {
            .boolean => value.Value.fromBool(bytes[0] != 0),
            .char => value.Value.fromChar(.{ .codepoint = @bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*) }),
            .i8 => value.Value.fromI8(@bitCast(bytes[0])),
            .i16 => value.Value.fromI16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .i32 => value.Value.fromI32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .i64 => value.Value.fromI64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .i128 => value.Value.fromI128(@bitCast(bytes)),
            .u8 => value.Value.fromU8(bytes[0]),
            .u16 => value.Value.fromU16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .u32 => value.Value.fromU32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .u64 => value.Value.fromU64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .u128 => value.Value.fromU128(@bitCast(bytes)),
            .isize => blk: {
                const arr: [@sizeOf(isize)]u8 = @as(*const [@sizeOf(isize)]u8, @ptrCast(&bytes)).*;
                break :blk value.Value.fromIsize(@bitCast(arr));
            },
            .usize => blk: {
                const arr: [@sizeOf(usize)]u8 = @as(*const [@sizeOf(usize)]u8, @ptrCast(&bytes)).*;
                break :blk value.Value.fromUsize(@bitCast(arr));
            },
            .f16 => value.Value.fromF16(@bitCast(@as(*const [2]u8, @ptrCast(&bytes)).*)),
            .f32 => value.Value.fromF32(@bitCast(@as(*const [4]u8, @ptrCast(&bytes)).*)),
            .f64 => value.Value.fromF64(@bitCast(@as(*const [8]u8, @ptrCast(&bytes)).*)),
            .f128 => value.Value.fromF128(@bitCast(bytes)),
        };
    }

    /// cast_to：cast(x).to(T) Phase 3 新语法
    /// 行为（spec §4.3 决策 #28/#30）：
    ///   - 数值→数值：wrap on overflow（复用 cast()）
    ///   - f→f 窄化产生 Inf → panic（D61 强化）
    ///   - str→数值：暂不支持（panic 提示）；数值→str 在 IR 已分派到 builtin_str
    ///   - 其他路径同 cast()
    pub fn execCastTo(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);
        const src_tag = engine_mod.Engine.chanToScalarTag(src_meta) orelse return error.UnsupportedOp;
        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        // str→数值 在 to 模式 panic（决策 #27）
        if (self.runtime.isRef(src_chan)) {
            return error.Panic;
        }

        const a = self.readChanBytes(src_chan);
        const result = value.cast.cast(src_tag, dst_tag, a);

        // D61 强化：f→f 窄化产生 Inf → panic
        if (cast_mod.isFloatTag(src_tag) and cast_mod.isFloatTag(dst_tag)) {
            if (isInfResult(dst_tag, result)) return error.Panic;
        }

        self.writeChanBytes(node.output, result);
    }

    /// cast_try_to：cast(x).try_to(T) Phase 3 新语法
    /// 行为（spec §4.3 决策 #29/#30）：
    ///   - 成功 → ThrowValue.ok(T)
    ///   - 越界/产生 Inf/解析失败 → ThrowValue.err(CastError)
    /// 输出：通道（ThrowValue 指针）
    pub fn execCastTryTo(self: *Engine, node: *const Node) EngineError!void {
        if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) return error.InvalidMetaIndex;
        const meta = self.ir.scalar_metas[node.meta_index];

        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);

        // str→数值：解析失败时构造 CastError
        // 数值→str：IR 中已分派 builtin_str，但 try_to 模式仍走此节点包装为 Throw.ok
        // 这里处理两种情况
        if (meta.kind == .str) {
            // 数值→str：永不失败，直接包装为 Throw.ok(str)
            // src_chan 已经是 str 引用（IR 中先 builtin_str 再 cast_try_to）
            const v = self.chanToValue(src_chan);
            const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
            _ = v.retain(self.tctx.?);
            try self.trackObj(throw_v.asRef());
            _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
            return;
        }

        const dst_tag = scalarKindToTag(meta.kind, meta.int_kind, meta.float_kind) orelse return error.UnsupportedOp;

        // str→数值 解析路径：src 为通道 (Str)，需在 chanToScalarTag 之前处理
        // 因为通道不能转换为 ScalarTag
        if (self.runtime.isRef(src_chan)) {
            // 读取源字符串
            const s = self.readStr(src_chan) orelse return error.UnsupportedOp;
            const str_bytes = s.bytes();
            return self.execCastTryToStrNumeric(node, str_bytes, dst_tag);
        }

        const src_tag = engine_mod.Engine.chanToScalarTag(src_meta) orelse return error.UnsupportedOp;

        // 数值→数值：走 tryCast
        const a = self.readChanBytes(src_chan);
        const result = value.cast.tryCast(src_tag, dst_tag, a) catch {
            // 转换失败 → 构造 CastError
            return self.constructCastErrorThrow(node, src_tag, dst_tag, a);
        };

        // D61 强化：f→f 窄化产生 Inf → CastError
        if (cast_mod.isFloatTag(src_tag) and cast_mod.isFloatTag(dst_tag)) {
            if (isInfResult(dst_tag, result)) {
                return self.constructCastErrorThrow(node, src_tag, dst_tag, a);
            }
        }

        // 成功 → ThrowValue.ok(T)
        // 直接从字节构造 Value，避免通道上 chanToValue 把标量字节误读为指针
        const ok_v = scalarBytesToValue(dst_tag, result);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = ok_v }) catch return error.OutOfMemory;
        _ = ok_v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// str→数值 的 try_to 实现
    /// 解析字符串为目标数值类型，失败构造 CastError
    pub fn execCastTryToStrNumeric(self: *Engine, node: *const Node, str_bytes: []const u8, dst_tag: ScalarTag) EngineError!void {
        // 解析字符串
        const parse_result = cast_mod.parseStrToNumeric(str_bytes, dst_tag) catch {
            // 解析失败 → CastError
            // src_tag 用 .boolean 作为占位（实际是 str）
            return self.constructCastErrorThrowStr(node, str_bytes, dst_tag);
        };

        // 成功 → 直接从字节构造 Value，包装为 Throw.ok
        const ok_v = scalarBytesToValue(dst_tag, parse_result);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = ok_v }) catch return error.OutOfMemory;
        _ = ok_v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// 构造 CastError RecordValue + ThrowValue.err，写入 output 通道
    /// 字段顺序：msg / from / to / value（与 src/builtin/error/CastError.glue 一致）
    pub fn constructCastErrorThrow(self: *Engine, node: *const Node, src_tag: ScalarTag, dst_tag: ScalarTag, src_bytes: [16]u8) EngineError!void {
        const alloc = self.tctx.?.backing;
        const from_str = cast_mod.tagName(src_tag);
        const to_str = cast_mod.tagName(dst_tag);
        const value_str = cast_mod.formatScalarValue(alloc, src_tag, src_bytes) catch return error.OutOfMemory;
        defer alloc.free(value_str);
        const msg_str = std.fmt.allocPrint(alloc, "cannot cast '{s}' from {s} to {s}", .{ value_str, from_str, to_str }) catch return error.OutOfMemory;
        defer alloc.free(msg_str);
        return self.emitCastErrorThrow(node, msg_str, from_str, to_str, value_str);
    }

    /// str→数值 失败时构造 CastError
    pub fn constructCastErrorThrowStr(self: *Engine, node: *const Node, str_bytes: []const u8, dst_tag: ScalarTag) EngineError!void {
        const alloc = self.tctx.?.backing;
        const from_str = "str";
        const to_str = cast_mod.tagName(dst_tag);
        const value_str = alloc.dupe(u8, str_bytes) catch return error.OutOfMemory;
        defer alloc.free(value_str);
        const msg_str = std.fmt.allocPrint(alloc, "cannot cast \"{s}\" from str to {s} (parse failed)", .{ str_bytes, to_str }) catch return error.OutOfMemory;
        defer alloc.free(msg_str);
        return self.emitCastErrorThrow(node, msg_str, from_str, to_str, value_str);
    }

    /// 实际构造 CastError RecordValue（4 字段：msg/from/to/value）+ ThrowValue.err，写入 output
    pub fn emitCastErrorThrow(self: *Engine, node: *const Node, msg_str: []const u8, from_str: []const u8, to_str: []const u8, value_str: []const u8) EngineError!void {
        // 分配 4 个 str Value
        const msg_obj = value.str_mod.Str.createContiguous(self.tctx.?, msg_str) catch return error.OutOfMemory;
        try self.trackObj(&msg_obj.header);
        const from_obj = value.str_mod.Str.createContiguous(self.tctx.?, from_str) catch return error.OutOfMemory;
        try self.trackObj(&from_obj.header);
        const to_obj = value.str_mod.Str.createContiguous(self.tctx.?, to_str) catch return error.OutOfMemory;
        try self.trackObj(&to_obj.header);
        const value_obj = value.str_mod.Str.createContiguous(self.tctx.?, value_str) catch return error.OutOfMemory;
        try self.trackObj(&value_obj.header);

        const msg_v: value.Value = .{ .ref = &msg_obj.header };
        const from_v: value.Value = .{ .ref = &from_obj.header };
        const to_v: value.Value = .{ .ref = &to_obj.header };
        const value_v: value.Value = .{ .ref = &value_obj.header };

        // 构造 CastError RecordValue（带字段名，使 message() 默认实现能按名查找 msg）
        var fields_buf: [4]value.Value = .{ msg_v, from_v, to_v, value_v };
        const field_names: [4]?[]const u8 = .{ "msg", "from", "to", "value" };
        const cast_err_v = value.Value.makeRecordWithNames(self.tctx.?, "CastError", &fields_buf, &field_names) catch return error.OutOfMemory;
        try self.trackObj(cast_err_v.asRef());
        // 4 字段：retain 引用计数（makeRecordWithNames 窃取引用，需 retain）
        for (fields_buf) |fv| _ = value.obj_header.retain(fv.asRef(), self.tctx.?);

        // ThrowValue.err 直接持有 CastError RecordValue
        const rec_ptr: *value.RecordValue = @alignCast(@fieldParentPtr("header", cast_err_v.asRef()));
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = rec_ptr }) catch return error.OutOfMemory;
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// 从 ScalarKind + IntKind/FloatKind 推导 ScalarTag
    pub fn scalarKindToTag(kind: ScalarKind, int_kind: scalar.IntKind, float_kind: scalar.FloatKind) ?ScalarTag {
        return switch (kind) {
            .int => switch (int_kind) {
                .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
                .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
                .isize => .isize, .usize => .usize,
            },
            .float => switch (float_kind) {
                .f16 => .f16, .f32 => .f32, .f64 => .f64, .f128 => .f128,
            },
            .bool => .boolean,
            .char => .char,
            else => null,
        };
    }

    /// 检查 cast 结果是否为 Inf（仅用于 f→f 窄化产生 Inf 判断）
    /// 通过 inline switch 在编译期展开各 float tag 的判断
    pub fn isInfResult(dst_tag: ScalarTag, result: [16]u8) bool {
        return switch (dst_tag) {
            .f16 => {
                const v: f16 = @bitCast(result[0..2].*);
                return std.math.isInf(v);
            },
            .f32 => {
                const v: f32 = @bitCast(result[0..4].*);
                return std.math.isInf(v);
            },
            .f64 => {
                const v: f64 = @bitCast(result[0..8].*);
                return std.math.isInf(v);
            },
            .f128 => {
                const v: f128 = @bitCast(result[0..16].*);
                return std.math.isInf(v);
            },
            else => false,
        };
    }
};
