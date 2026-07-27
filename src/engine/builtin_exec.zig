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

pub const Methods = struct {
    /// builtin_ok：构造 ThrowValue(ok payload)
    /// inputs[0] = 值通道
    pub fn execBuiltinOk(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const v = self.chanToValue(val_chan);
        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .ok = v }) catch return error.OutOfMemory;
        _ = v.retain(self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
    }

    /// builtin_error：构造 ThrowValue(err payload) + ErrorValue
    /// inputs[0] = 消息通道（ref_chan 指向 StringValue）
    pub fn execBuiltinError(self: *Engine, node: *const Node) EngineError!void {
        const msg_chan = node.inputs[0];
        const msg_bytes = if (self.readStr(msg_chan)) |s| s.bytes() else "";

        const err_v = value.Value.makeError(self.tctx.?, "Error", msg_bytes, false) catch return error.OutOfMemory;
        try self.trackObj(err_v.asRef());
        const err_val: *value.ErrorValue = @alignCast(@fieldParentPtr("header", err_v.asRef()));

        const throw_v = value.Value.makeThrow(self.tctx.?, .{ .err = err_val }) catch return error.OutOfMemory;
        _ = value.obj_header.retain(&err_val.header, self.tctx.?);
        try self.trackObj(throw_v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(throw_v.asRef()));
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
    pub fn execBuiltinStr(self: *Engine, node: *const Node) EngineError!void {
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
            .isize_chan => blk: {
                const ptr: *isize = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .usize_chan => blk: {
                const ptr: *usize = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
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
            .f128_chan => blk: {
                const ptr: *f128 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .i128_chan => blk: {
                const ptr: *i128 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
                break :blk std.fmt.bufPrint(&buf, "{d}", .{ptr.*}) catch "";
            },
            .u128_chan => blk: {
                const ptr: *u128 = @ptrCast(@alignCast(self.runtime.rawPtr(val_chan)));
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
            .ref_chan => blk: {
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
                        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
                        return;
                    }
                    // 非标量数组格式化由 std.reflect.format_array 处理
                    break :blk "[array]";
                }
                // 标量引用（tagged pointer，bit 0 = 1）：
                // ref_of 节点把标量编码为 tagged pointer，存储原始通道索引。
                // 解码通道索引，再按通道的 chan_type 格式化标量值。
                // 注意：ref_chan 可能持有标量值（如 array_pop 把 i32 写入 ref_chan），
                // 标量值位模式可能 bit 0 = 1，必须用 tryDecodeScalarRef 验证合法性。
                if (self.runtime.readPtr(val_chan)) |obj_ptr| {
                    const addr = @intFromPtr(obj_ptr);
                    // 标量引用：解码通道索引并按源通道类型格式化
                    if (self.tryDecodeScalarRef(addr)) |src_chan| {
                        const src_meta = self.ir.channels.get(src_chan);
                        const src_ptr = self.runtime.rawPtr(src_chan);
                        break :blk switch (src_meta.chan_type) {
                            .i64_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*i64, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .i32_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*i32, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .i16_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*i16, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .i8_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*i8, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .u64_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*u64, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .u32_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*u32, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .u16_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*u16, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .u8_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*u8, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .isize_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*isize, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .usize_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*usize, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .f64_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*f64, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .f32_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*f32, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .f16_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*f16, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .f128_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*f128, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .i128_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*i128, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .u128_chan => std.fmt.bufPrint(&buf, "{d}", .{@as(*u128, @ptrCast(@alignCast(src_ptr))).*}) catch "",
                            .bool_chan, .mask_chan => if (@as(*bool, @ptrCast(@alignCast(src_ptr))).*) "true" else "false",
                            .char_chan => blk2: {
                                const cp: u21 = @intCast(@as(*u32, @ptrCast(@alignCast(src_ptr))).*);
                                if (cp < 128) {
                                    buf[0] = @intCast(cp);
                                    break :blk2 buf[0..1];
                                }
                                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                                break :blk2 buf[0..n];
                            },
                            .unit_chan => "()",
                            .null_chan => "null",
                            else => "<obj>",
                        };
                    }
                    if (addr >= 0x1000 and addr % @alignOf(value.obj_header.ObjHeader) == 0) {
                        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(obj_ptr));
                        // 其他堆对象类型（throw_val/error_val/closure 等）：
                        // 复杂类型格式化由 std.reflect.format 处理，此处返回占位
                        const tag_name = value.ref_kind_table.displayName(header.type_tag);
                        break :blk tag_name;
                    }
                }
                // gate_get_ok 可能把标量值写入 ref_chan（i32/i64 等）
                // 尝试读取为 i64
                const iv = self.runtime.readI64(val_chan);
                if (iv != 0) {
                    break :blk std.fmt.bufPrint(&buf, "{d}", .{iv}) catch "null";
                }
                break :blk "null";
            },
            .unit_chan => "()",
            .null_chan => "null",
            else => "",
        };

        // 创建 Str 并写入输出通道
        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, slice) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
    }

    /// builtin_type：返回值的运行时类型名
    /// inputs[0] = 值通道
    /// output = ref_chan（Str 指针）
    pub fn execBuiltinType(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const meta = self.ir.channels.get(val_chan);
        const type_name: []const u8 = switch (meta.chan_type) {
            .i8_chan => "i8",
            .i16_chan => "i16",
            .i32_chan => "i32",
            .i64_chan => "i64",
            .i128_chan => "i128",
            .u8_chan => "u8",
            .u16_chan => "u16",
            .u32_chan => "u32",
            .u64_chan => "u64",
            .u128_chan => "u128",
            .isize_chan => "isize",
            .usize_chan => "usize",
            .f16_chan => "f16",
            .f32_chan => "f32",
            .f64_chan => "f64",
            .f128_chan => "f128",
            .bool_chan, .mask_chan => "bool",
            .char_chan => "char",
            .unit_chan => "unit",
            .null_chan => "null",
            .ref_chan => blk: {
                const header = self.readRefObj(val_chan);
                if (header) |h| {
                    break :blk value.ref_kind_table.typeName(h.type_tag);
                }
                break :blk "null";
            },
            .nullable_chan => "nullable",
        };

        const str_obj = value.str_mod.Str.createContiguous(self.tctx.?, type_name) catch return error.OutOfMemory;
        try self.trackObj(&str_obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&str_obj.header));
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
                self.runtime.writePtr(node.output, @ptrCast(obj));
            },
        }
    }

    /// error_message：提取错误值的消息字符串
    /// inputs[0] = error ref 通道
    /// output = ref_chan（Str 指针）
    /// 支持：
    /// - .error_val：读取 ErrorValue.message
    /// - .throw_val：读取 ThrowValue.payload.err.message
    /// - .record：error_newtype 实例用 RecordValue 表示，读取 field_id=1（第一个构造器字段，即 msg）
    pub fn execErrorMessage(self: *Engine, node: *const Node) EngineError!void {
        const in_chan = node.inputs[0];
        const ptr = self.runtime.readPtr(in_chan);
        const real_ptr = ptr orelse return error.InvalidChannel;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(real_ptr));
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
            .record => blk: {
                // error_newtype 实例（RecordValue）：field_id=1 是第一个构造器字段（msg）
                const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                if (r.fields.len > 1) {
                    const field_val = r.fields[1];
                    if (field_val == .ref) {
                        const fh: *value.obj_header.ObjHeader = @ptrCast(@alignCast(field_val.ref));
                        if (fh.type_tag == .str) {
                            const fs: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", fh));
                            break :blk fs.bytes();
                        }
                    }
                }
                break :blk "not an error";
            },
            else => "not an error",
        };
        const v = value.Value.fromStringBytes(self.tctx.?, msg) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// obj_type_name：获取值的类型名
    /// inputs[0] = ref 通道
    /// output = ref_chan（Str 指针）
    pub fn execObjTypeName(self: *Engine, node: *const Node) EngineError!void {
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
        const v = value.Value.fromStringBytes(self.tctx.?, name) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }
};
