//! 非反射 builtin 执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 ok / error / eq / ref_eq / str / type / typeof / syscall /
//! error_message / obj_type_name 等 builtin 执行函数。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");
const mem = @import("mem");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

const syscall_dispatch = @import("syscall");

const Node = ir_mod.Node;
const TypeMetadata = ir_mod.meta_mod.TypeMetadata;
const ThreadContext = mem.ThreadContext;

/// 从 RecordValue 按 field_names 查找 "msg" 字段，提取字符串。
/// 用于 error_message 节点（向后兼容，Trait 分派就绪后随 execErrorMessage 一起删除）。
/// 查找策略：优先按 field_names 查找 "msg"；找不到回退到 fields[0]（CastError 的 msg 在 index 0）。
fn extractMsgFromRecord(r: *value.RecordValue) []const u8 {
    // 按 field_names 查找 "msg"
    if (r.field_names.len > 0) {
        for (r.field_names, 0..) |opt_name, i| {
            if (opt_name) |n| if (std.mem.eql(u8, n, "msg")) {
                if (i < r.fields.len) {
                    const fv = r.fields[i];
                    if (fv == .ref and fv.ref.type_tag == .str) {
                        const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fv.ref));
                        return fs.bytes();
                    }
                }
            };
        }
    }
    // 回退：fields[0]（CastError 的 msg 在 index 0；IOError 的 msg 在 index 1）
    // 注意：此回退不精确，将在 Task 6 中随函数删除而消除
    if (r.fields.len > 0) {
        const fv = r.fields[0];
        if (fv == .ref and fv.ref.type_tag == .str) {
            const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fv.ref));
            return fs.bytes();
        }
    }
    return "";
}

pub const Methods = struct {
    /// builtin_ok：构造 ThrowValue(ok payload)
    /// inputs[0] = 值通道
    pub fn execBuiltinOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const v = self.chanToValue(val_chan);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// builtin_error：构造 ThrowValue(err)，err 持有 Error(msg) RecordValue
    /// inputs[0] = 消息通道（ref_chan 指向 StringValue）
    pub fn execBuiltinError(self: *Engine, node: *const Node) EngineError!void {
        const msg_chan = node.inputs[0];
        const msg_val = if (self.runtime.readChannel(msg_chan)) |v| v else return error.InvalidChannel;

        // 构造 Error(msg) RecordValue
        var fields: [1]value.Value = .{msg_val};
        const field_names: [1]?[]const u8 = .{"msg"};
        const rec_val = value.Value.makeRecordWithNames(self.tctx.?, "Error", &fields, &field_names) catch return error.OutOfMemory;
        if (msg_val == .ref) _ = value.obj_header.retain(msg_val.ref, self.tctx.?);
        try self.trackObj(rec_val.asRef());

        const rec_ptr: *value.RecordValue = @alignCast(@fieldParentPtr("header", rec_val.asRef()));
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = rec_ptr }) catch return error.OutOfMemory;
        try self.trackObj(throw_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(throw_v.asRef())));
    }

    /// builtin_eq：递归值相等比较（==）
    /// 使用 chanToValue 将通道值转为 Value，再调用 value.equals 做完整递归比较
    pub fn execBuiltinEq(self: *Engine, node: *const Node) EngineError!void {
        const a_val = self.chanToValue(node.inputs[0]);
        const b_val = self.chanToValue(node.inputs[1]);
        self.runtime.writeBool(node.output, value.equals(a_val, b_val));
    }

    /// builtin_ref_eq：引用相等比较（===）
    /// 堆类型比较 *ObjHeader 指针；标量退化为值相等（==）
    pub fn execBuiltinRefEq(self: *Engine, node: *const Node) EngineError!void {
        const a_val = self.chanToValue(node.inputs[0]);
        const b_val = self.chanToValue(node.inputs[1]);
        const result = switch (a_val) {
            .ref => |a_ref| switch (b_val) {
                .ref => |b_ref| a_ref == b_ref,
                else => false,
            },
            // 标量/null/unit 退化为值相等
            else => value.equals(a_val, b_val),
        };
        self.runtime.writeBool(node.output, result);
    }

    /// builtin_str：标量值转字符串（复杂类型格式化由 std.reflect.format 接管）
    /// inputs[0] = 值通道，output = ref_chan（Str 指针）
    /// 标量类型走 runtime.formatChannel（scalar_ops.format vtable），零运行时 switch；
    /// ref_chan 跳过 formatChannel（ref_ops.format 返回 "ref:0x..." 不适用），
    /// 按 Str/Array/Cell/堆对象/标量位模式顺序处理；unit/null 走字面量。
    pub fn execBuiltinStr(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];

        var buf: [64]u8 = undefined;
        const slice: []const u8 = blk: {
            // 标量类型（非 ref_chan）：走 vtable format 快路径
            // ref_chan 的 ref_ops.format 返回 "ref:0x..."，不适用于 builtin_str，需特殊处理
            if (!self.runtime.isRef(val_chan)) {
                if (self.runtime.formatChannel(val_chan, &buf)) |s| break :blk s;
            }

            if (self.runtime.isRef(val_chan)) {
                if (self.readStr(val_chan)) |s| break :blk s.bytes();
                // 检查是否为数组（u8[] → UTF-8 解码为字符串）
                if (self.readArray(val_chan)) |arr| {
                    // 仅当所有元素都是 u8 时，按字节拼接为字符串（字节→str 语义转换）
                    if (arr.elements.len > 0 and arr.elements[0] == .u8) {
                        const tmp_bytes = self.tctx.?.backing.alloc(u8, arr.elements.len) catch return error.OutOfMemory;
                        defer self.tctx.?.backing.free(tmp_bytes);
                        for (arr.elements, 0..) |elem, i| {
                            tmp_bytes[i] = elem.asU8();
                        }
                        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, tmp_bytes) catch return error.OutOfMemory;
                        try self.trackObj(&new_str.header);
                        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(&new_str.header)));
                        return;
                    }
                    // 非标量数组格式化由 std.reflect.format_array 处理
                    break :blk "[array]";
                }
                // 通过 ref_ops.read 读取 Value（统一处理堆对象/null/标量位模式）
                if (self.runtime.readChannel(val_chan)) |v| {
                    switch (v) {
                        .ref => |header| {
                            // Cell（标量引用）：格式化 inner 值
                            if (header.type_tag == .cell) {
                                const cell: *value.Cell = @alignCast(@fieldParentPtr("header", header));
                                const formatted = cell.inner.formatAlloc(self.tctx.?) catch return error.OutOfMemory;
                                defer self.tctx.?.backing.free(formatted);
                                const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, formatted) catch return error.OutOfMemory;
                                try self.trackObj(&str_obj.header);
                                _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(&str_obj.header)));
                                return;
                            }
                            // 其他堆对象类型（throw_val/error_val/closure 等）
                            break :blk value.ref_kind_table.displayName(header.type_tag);
                        },
                        .null_val => break :blk "null",
                        .i64 => |b| break :blk std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @bitCast(b))}) catch "null",
                        else => break :blk "<scalar>",
                    }
                }
                break :blk "null";
            }
            if (self.runtime.isUnit(val_chan)) break :blk "void";
            if (self.runtime.isNull(val_chan)) break :blk "null";
            break :blk "";
        };

        // 创建 Str 并写入输出通道
        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, slice) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(&str_obj.header)));
    }

    /// builtin_type：返回值的运行时类型名
    /// inputs[0] = 值通道
    /// output = ref_chan（Str 指针）
    /// 标量类型名直接从 runtime.typeDesc().type_name 获取（builtin_chan_descriptors 已填充），
    /// 零运行时 switch；ref_chan 走 ref_kind_table.typeName；unit/null/nullable 走字面量。
    pub fn execBuiltinType(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const type_name: []const u8 = blk: {
            if (self.runtime.isRef(val_chan)) {
                if (self.runtime.readChannel(val_chan)) |v| {
                    if (v == .ref) {
                        break :blk value.ref_kind_table.typeName(v.ref.type_tag);
                    }
                }
                break :blk "null";
            }
            if (self.runtime.isUnit(val_chan)) break :blk "void";
            if (self.runtime.isNull(val_chan)) break :blk "null";
            if (self.runtime.isNullable(val_chan)) break :blk "nullable";
            // 标量（含 mask_chan）：type_desc.type_name 已含正确语义名称
            // mask_chan 的 type_name 已统一为 "bool"（与 bool_chan 一致）
            break :blk self.runtime.typeDesc(val_chan).type_name;
        };

        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, type_name) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(&str_obj.header)));
    }

    /// builtin_typeof：编译期类型反射，返回 TypeInfo RecordValue
    ///
    /// 无输入通道；node.meta_index = type_id（1-indexed，0 = 泛型参数 T/Self）
    /// output = ref_chan（RecordValue 指针）
    ///
    /// TypeInfo 是 7 顶层字段的 RecordValue，字段顺序与 IRBuilder.registerTypeInfoFields 一致：
    ///   0=name, 1=module, 2=kind, 3=structure, 4=layout, 5=impls, 6=type_params
    /// 子结构：
    ///   layout = LayoutInfo(size: u32, alignment: u32)
    ///   impls  = TraitImplInfo(parent_traits, implemented_traits, methods, associated_types)
    ///   structure = TypeStructure ADT 变体（type_name 为 "Adt"/"Record"/"Newtype"/... 等）
    ///
    /// type_id 编码：
    ///   - 0：未知/泛型参数 T/Self，运行时查 frame.type_args（参见 Step 3）
    ///   - 0x8000..0xFFFF：泛型参数哨兵，param_idx = meta_index & 0x7FFF
    ///   - 1..N：具体类型 type_id，查 TypeMetadataTable
    pub fn execBuiltinTypeof(self: *Engine, node: *const Node) EngineError!void {
        const meta_idx = node.meta_index;
        const tctx = self.tctx.?;

        // nullable 包装哨兵：typeof(T?) → 构造 Nullable kind 的 TypeInfo
        // meta_index = 0x4000 | inner_meta_idx
        if (meta_idx & 0x4000 != 0) {
            const inner_meta: u16 = meta_idx & 0xBFFF;
            // 递归构造 inner TypeInfo
            const inner_value = try self.makeTypeInfoFromMeta(inner_meta);
            // 构造 Nullable kind 的 TypeInfo：复用 inner TypeInfo 的字段，
            // 但 kind = Nullable，structure = Nullable(inner_type_id)
            try self.emitNullableTypeInfo(node, inner_value, tctx);
            return;
        }

        // 泛型参数引用（0x8000|param_idx）：从当前帧 type_args 查实际 type_id
        if (meta_idx & 0x8000 != 0) {
            const param_idx: u16 = meta_idx & 0x7FFF;
            const type_args = self.activeTypeArgs();
            if (param_idx < type_args.len) {
                const actual_type_id = type_args[param_idx];
                if (actual_type_id != 0) {
                    if (self.ir.type_metadata_table.get(actual_type_id)) |md| {
                        try self.emitTypeInfoRecord(node, md, tctx);
                        return;
                    }
                }
            }
            // 查表失败：返回占位 TypeInfo
            try self.emitPlaceholderTypeInfo(node, "?", tctx);
            return;
        }

        // type_id=0：未知类型，返回占位
        if (meta_idx == 0) {
            try self.emitPlaceholderTypeInfo(node, "?", tctx);
            return;
        }

        // 查表
        const md: *const TypeMetadata = self.ir.type_metadata_table.get(meta_idx) orelse {
            try self.emitPlaceholderTypeInfo(node, "<unknown>", tctx);
            return;
        };

        try self.emitTypeInfoRecord(node, md, tctx);
    }

    /// syscall_call：分派到 syscall 实现（IO/Time 等宿主 syscall 包装）
    ///
    /// meta_index 索引 ir.syscall_metas 表（1-indexed），获取 syscall_id（u16）与 arg_count，
    /// 收集 inputs[] 通道的 Value，调用 syscall.dispatch 执行，结果写入 output 通道。
    pub fn execSyscall(self: *Engine, node: *const Node) EngineError!void {
        const meta_idx = node.meta_index;
        if (meta_idx == 0 or meta_idx > self.ir.syscall_metas.len) {
            return error.InvalidMetaIndex;
        }
        const syscall_meta = self.ir.syscall_metas[meta_idx - 1];
        const tctx = self.tctx.?;

        // 收集参数（最多 4 个）
        var args: [4]value.Value = .{ value.Value.fromUnit(), value.Value.fromUnit(), value.Value.fromUnit(), value.Value.fromUnit() };
        const arg_count: usize = @min(node.input_count, 4);
        var i: usize = 0;
        while (i < arg_count) : (i += 1) {
            args[i] = self.chanToValue(node.inputs[i]);
        }
        const arg_slice = args[0..arg_count];

        // 分派执行（SyscallMeta.syscall_id 存为 u16，转 SyscallId enum 传给 dispatch）
        const io_ctx = self.io orelse return error.IoNotInitialized;
        const sid: syscall_dispatch.SyscallId = @enumFromInt(syscall_meta.syscall_id);
        const result = syscall_dispatch.dispatch(io_ctx, tctx, sid, arg_slice) catch |err| switch (err) {
            error.OutOfMemory, error.TooManyPools, error.AllocFailed => return error.OutOfMemory,
            error.InvalidArgument => return error.InvalidMetaIndex,
        };

        // 结果写入 output 通道
        // 标量值直接写通道；堆对象（ref/Throw）写指针
        switch (result) {
            .null_val, .unit => {},
            .boolean => |b| self.runtime.writeBool(node.output, b[0] != 0),
            .char => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                ptr.* = @bitCast(b);
            },
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            .f16, .f32, .f64, .f128 => self.valueToChan(node.output, result),
            .ref => |obj| {
                // 堆对象：trackObj 注册跟踪后写通道
                self.trackObj(obj) catch return error.OutOfMemory;
                _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(obj)));
            },
        }
    }

    /// error_message：提取错误值的消息字符串
    /// inputs[0] = error ref 通道
    /// output = ref_chan（Str 指针）
    /// 支持：
    /// - .throw_val：从 ThrowValue.err 的 RecordValue 按 field_names 查找 "msg"
    /// - .record：error_newtype 实例，按 field_names 查找 "msg"
    /// - .error_val：遗留 ErrorValue，读取 .message 字段（向后兼容）
    pub fn execErrorMessage(self: *Engine, node: *const Node) EngineError!void {
        const in_chan = node.inputs[0];
        const in_val = self.runtime.readChannel(in_chan) orelse return error.InvalidChannel;
        if (in_val != .ref) return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = in_val.ref;
        const msg: []const u8 = switch (header.type_tag) {
            .error_val => blk: {
                const e: *value.ErrorValue = @alignCast(@fieldParentPtr("header", header));
                break :blk e.message;
            },
            .throw_val => blk: {
                const t: *value.ThrowValue = @alignCast(@fieldParentPtr("header", header));
                break :blk switch (t.payload) {
                    .err => |rec_ptr| extractMsgFromRecord(rec_ptr),
                    else => "ok",
                };
            },
            .record => blk: {
                const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                break :blk extractMsgFromRecord(r);
            },
            else => "not an error",
        };
        const v = value.Value.fromStringBytes(self.tctx.?, msg) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(v.asRef())));
    }

    /// obj_type_name：获取值的类型名
    /// inputs[0] = ref 通道
    /// output = ref_chan（Str 指针）
    pub fn execObjTypeName(self: *Engine, node: *const Node) EngineError!void {
        const in_val = self.runtime.readChannel(node.inputs[0]) orelse return error.InvalidChannel;
        if (in_val != .ref) return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = in_val.ref;
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
        const v = value.Value.fromStringBytes(self.tctx.?, name) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(v.asRef())));
    }
};
