//! 反射 builtin 执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 reflect / reflect_field / scalar_to_str / reflect_deref /
//! reflect_field_name / reflect_meta 等 builtin 执行函数，以及运行时
//! 值反射所需的辅助函数（reflectFieldCount / writeFieldResult /
//! reflectFieldByValue / inferKindFromValue / emitEmptyStr / reflectFieldName）。
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

const Node = ir_mod.Node;
const TypeMetadata = ir_mod.meta_mod.TypeMetadata;
const ThreadContext = mem.ThreadContext;

/// type_id 未知时从 Value 变体推断 kind/type_name/field_count
pub const InferredKind = struct {
    kind: []const u8,
    type_name: []const u8,
    field_count: usize,
};

pub const Methods = struct {
    /// builtin_reflect：运行时值反射，构造 Reflect RecordValue
    ///
    /// inputs[0] = 值通道，meta_index = type_id
    /// output = ref_chan（Reflect RecordValue 指针）
    ///
    /// Reflect RecordValue 5 字段：
    ///   0=type_name (str), 1=kind (str), 2=field_count (usize)
    ///   3=__target (Value，隐藏), 4=__type_id (u16，隐藏)
    pub fn execBuiltinReflect(self: *Engine, node: *const Node) EngineError!void {
        const tctx = self.tctx.?;
        const val_chan = node.inputs[0];
        const meta_idx = node.meta_index;
        var target_value = self.chanToValue(val_chan);

        // chanToValue 已通过 ref_ops.read 处理 ref_chan（堆对象/null/标量位模式），
        // target_value 已是带类型信息的 Value，无需额外解箱。

        // 解析 meta_idx：可能是具体 type_id 或泛型参数引用 0x8000|param_idx
        var type_id: u16 = meta_idx;
        if (meta_idx & 0x8000 != 0) {
            const param_idx: u16 = meta_idx & 0x7FFF;
            const type_args = self.activeTypeArgs();
            type_id = if (param_idx < type_args.len) type_args[param_idx] else 0;
        }

        // 泛型 ref_chan 中的标量值类型恢复
        // 标量通过 ref_of 装箱为 Cell，readRef 返回 Value.fromRef(cell_header)。
        // 反射需解包 Cell 提取内部标量 Value，否则 __scalar_to_str 看到 .ref 而非标量。
        if (target_value == .ref and target_value.ref.type_tag == .cell) {
            const cell: *value.Cell = @alignCast(@fieldParentPtr("header", target_value.ref));
            target_value = cell.inner;
        }

        // type_id 未知时（泛型递归格式化：field_value 返回 freshTypeVar，
        // 编译期无法解析 type_id），从目标 RecordValue 的 type_name 反查 type_id。
        // 这使递归 ADT 格式化能正确获取 kind/构造器名/字段名，无需哨兵传播。
        if (type_id == 0) {
            if (target_value == .ref and target_value.ref.type_tag == .record) {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                type_id = self.ir.type_metadata_table.getIdByName(rec.type_name);
            }
        }

        // 确定 type_name / kind / field_count
        var type_name: []const u8 = "?";
        var kind: []const u8 = "Primitive";
        var field_count: usize = 0;

        if (type_id != 0) {
            if (self.ir.type_metadata_table.get(type_id)) |md| {
                type_name = md.name;
                kind = md.kind.ctorName();
                field_count = self.reflectFieldCount(md, target_value);
            }
        }

        // str 特殊处理：target 是 str 引用时，kind 覆盖为 "Str"
        // （str 的 TypeKind 可能是 primitive，但 std.reflect.format 需区分 "Str"）
        if (target_value == .ref and target_value.ref.type_tag == .str) {
            kind = "Str";
            if (type_id == 0) {
                type_name = "str";
            }
        } else if (type_id == 0) {
            // type_id 未知时从 Value 变体推断 kind
            const inferred = inferKindFromValue(target_value);
            kind = inferred.kind;
            type_name = inferred.type_name;
            field_count = inferred.field_count;
        }

        // 构造 5 字段
        var fields = [_]value.Value{
            value.Value.fromStringBytes(tctx, type_name) catch return error.OutOfMemory,
            value.Value.fromStringBytes(tctx, kind) catch return error.OutOfMemory,
            value.Value.fromUsize(field_count),
            target_value,
            value.Value.fromU16(type_id),
        };
        // __target 是引用时需 retain（RecordValue.deinit 会 release）
        if (target_value.isBoxed()) _ = target_value.retain(tctx);
        // 字段 0/1 是新建 Str（需跟踪），字段 3 可能是 ref（已 retain，需跟踪）
        try self.trackRefFields(&fields);
        // field_ref_bits: 仅当 __target (field 3) 是引用类型时标记为 ref
        const field_ref_bits: u64 = if (target_value.isBoxed()) 0b1000 else 0;
        const rec = value.Value.makeRecordEx(tctx, "Reflect", &fields, field_ref_bits) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(rec.asRef()));
    }

    /// 根据 TypeMetadata 和目标值计算 field_count
    pub fn reflectFieldCount(self: *Engine, md: *const TypeMetadata, target: value.Value) usize {
        _ = self;
        const result: usize = switch (md.structure) {
            .primitive => 0,
            .record => |fields| fields.len,
            .adt => |ctors| blk: {
                // ADT: 读 __tag 决定当前构造器，返回该构造器的字段数
                // __tag 字段是 i64 类型，需通过 asI64 读取再转型（asUsize 要求 usize active field）
                if (target == .ref and target.ref.type_tag == .record) {
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target.ref));
                    if (rec.fields.len > 0) {
                        const tag: usize = @intCast(rec.fields[0].asI64());
                        if (tag < ctors.len) {
                            break :blk ctors[tag].fields.len;
                        }
                    }
                }
                break :blk 0;
            },
            .nullable => if (target == .null_val) 0 else 1,
            .newtype => 1,
            else => 0,
        };
        return result;
    }

    /// builtin_reflect_field：从 Reflect 取字段值
    ///
    /// inputs[0] = Reflect 通道，meta_index = field_idx
    /// output = 字段值通道
    pub fn execBuiltinReflectField(self: *Engine, node: *const Node) EngineError!void {
        const reflect_chan = node.inputs[0];
        // meta_index >= 0xFFFE: 特殊编码（adt_tag）；否则从 inputs[1] 读取运行时索引
        const field_idx: usize = if (node.meta_index >= 0xFFFE)
            node.meta_index
        else
            self.chanToValue(node.inputs[1]).asUsize();

        // 从 Reflect RecordValue 读取 __target (field 3) 和 __type_id (field 4)
        const reflect_rec = self.readRecord(reflect_chan) orelse {
            self.valueToChan(node.output, value.Value.fromUnit());
            return;
        };
        if (reflect_rec.fields.len < 5) {
            self.valueToChan(node.output, value.Value.fromUnit());
            return;
        }
        const target_value = reflect_rec.fields[3];
        const type_id: u16 = reflect_rec.fields[4].asU16();

        // 特殊编码：meta_index=0xFFFE → 返回 target 的 __tag（ADT 构造器索引，field 0）
        if (field_idx == 0xFFFE) {
            if (target_value == .ref and target_value.ref.type_tag == .record) {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                if (rec.fields.len > 0) {
                    self.valueToChan(node.output, rec.fields[0]);
                    return;
                }
            }
            self.valueToChan(node.output, value.Value.fromUsize(0));
            return;
        }

        // type_id 未知时按 Value 变体分派
        if (type_id == 0) {
            const result = self.reflectFieldByValue(target_value, field_idx) catch value.Value.fromUnit();
            try self.writeFieldResult(node.output, result);
            return;
        }

        const md: *const TypeMetadata = self.ir.type_metadata_table.get(type_id) orelse {
            self.valueToChan(node.output, value.Value.fromUnit());
            return;
        };

        const result: value.Value = switch (md.structure) {
            .record => blk: {
                // Record: field_id=0 是 __tag，1..N 是构造器字段
                if (target_value != .ref or target_value.ref.type_tag != .record) break :blk value.Value.fromUnit();
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                const target_idx = field_idx + 1; // 跳过 __tag
                if (target_idx >= rec.fields.len) break :blk value.Value.fromUnit();
                break :blk rec.fields[target_idx];
            },
            .adt => |ctors| blk: {
                if (target_value != .ref or target_value.ref.type_tag != .record) break :blk value.Value.fromUnit();
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                if (rec.fields.len == 0) break :blk value.Value.fromUnit();
                const tag: usize = @intCast(rec.fields[0].asI64());
                if (tag >= ctors.len) break :blk value.Value.fromUnit();
                const target_idx = field_idx + 1; // 跳过 __tag
                if (target_idx >= rec.fields.len) break :blk value.Value.fromUnit();
                break :blk rec.fields[target_idx];
            },
            .nullable => blk: {
                if (field_idx != 0) break :blk value.Value.fromUnit();
                if (target_value == .null_val) break :blk value.Value.fromNull();
                break :blk target_value;
            },
            .newtype => blk: {
                if (field_idx != 0) break :blk value.Value.fromUnit();
                if (target_value != .ref or target_value.ref.type_tag != .record) break :blk value.Value.fromUnit();
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                // newtype 存储为 RecordValue：field 0 是 __tag，field 1 是 inner value
                const target_idx = field_idx + 1;
                if (target_idx >= rec.fields.len) break :blk value.Value.fromUnit();
                break :blk rec.fields[target_idx];
            },
            else => value.Value.fromUnit(),
        };

        try self.writeFieldResult(node.output, result);
    }

    /// 将 field_value 结果写入输出通道。
    /// 标量值写入 ref_chan 时按位模式存储（类型信息由后续 reflect/format 通过
    /// chanToValue 的标量引用路径恢复，或通过标量通道单态化避免 ref_chan 中转）。
    /// 引用类型（.ref）直接写指针，零宽值（unit/null）按原逻辑写。
    pub fn writeFieldResult(self: *Engine, out_chan: u16, v: value.Value) EngineError!void {
        self.valueToChan(out_chan, v);
    }

    /// type_id 未知时按 Value 变体分派取字段
    pub fn reflectFieldByValue(self: *Engine, target: value.Value, field_idx: usize) EngineError!value.Value {
        _ = self;
        if (target == .ref) {
            switch (target.ref.type_tag) {
                .array => {
                    const arr: *value.ArrayValue = @alignCast(@fieldParentPtr("header", target.ref));
                    if (field_idx >= arr.elements.len) return value.Value.fromUnit();
                    return arr.elements[field_idx];
                },
                .record, .adt => {
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target.ref));
                    const target_idx = field_idx + 1; // 跳过 __tag
                    if (target_idx >= rec.fields.len) return value.Value.fromUnit();
                    return rec.fields[target_idx];
                },
                else => return value.Value.fromUnit(),
            }
        }
        if (target == .null_val and field_idx == 0) return value.Value.fromNull();
        return value.Value.fromUnit();
    }

    pub fn inferKindFromValue(v: value.Value) InferredKind {
        return switch (v) {
            .null_val => .{ .kind = "Nullable", .type_name = "null", .field_count = 0 },
            .unit => .{ .kind = "Void", .type_name = "void", .field_count = 0 },
            .boolean => .{ .kind = "Primitive", .type_name = "bool", .field_count = 0 },
            .char => .{ .kind = "Primitive", .type_name = "char", .field_count = 0 },
            .i8, .i16, .i32, .i64, .i128 => .{ .kind = "Primitive", .type_name = "int", .field_count = 0 },
            .u8, .u16, .u32, .u64, .u128 => .{ .kind = "Primitive", .type_name = "uint", .field_count = 0 },
            .isize => .{ .kind = "Primitive", .type_name = "isize", .field_count = 0 },
            .usize => .{ .kind = "Primitive", .type_name = "usize", .field_count = 0 },
            .f16, .f32, .f64, .f128 => .{ .kind = "Primitive", .type_name = "float", .field_count = 0 },
            .ref => |obj| switch (obj.type_tag) {
                .str => .{ .kind = "Str", .type_name = "str", .field_count = 0 },
                .array => blk: {
                    const arr: *value.ArrayValue = @alignCast(@fieldParentPtr("header", obj));
                    break :blk .{ .kind = "Array", .type_name = "array", .field_count = arr.elements.len };
                },
                .record => blk: {
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", obj));
                    // __tag 在 field 0，构造器字段从 1 开始
                    const fc = if (rec.fields.len > 0) rec.fields.len - 1 else 0;
                    break :blk .{ .kind = "Record", .type_name = rec.type_name, .field_count = fc };
                },
                .adt => blk: {
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", obj));
                    const fc = if (rec.fields.len > 0) rec.fields.len - 1 else 0;
                    break :blk .{ .kind = "Adt", .type_name = rec.type_name, .field_count = fc };
                },
                else => .{ .kind = "Primitive", .type_name = "?", .field_count = 0 },
            },
        };
    }

    /// builtin_scalar_to_str：标量转字符串
    ///
    /// inputs[0] = Reflect 对象通道（ref_chan → RecordValue），
    /// 从 fields[3]（__target）读取原始标量 Value 并格式化。
    /// 直接从 Reflect 读取避免标量通过 ref_chan 中转时位模式被误判为指针。
    pub fn execBuiltinScalarToStr(self: *Engine, node: *const Node) EngineError!void {
        const tctx = self.tctx.?;
        const reflect_chan = node.inputs[0];

        // 从 Reflect RecordValue 读取 __target (field 3)
        const reflect_rec = self.readRecord(reflect_chan) orelse {
            const fallback = value.Str.createContiguous(tctx, "<null>") catch return error.OutOfMemory;
            try self.trackObj(&fallback.header);
            self.runtime.writePtr(node.output, @ptrCast(&fallback.header));
            return;
        };
        if (reflect_rec.fields.len < 5) {
            const fallback = value.Str.createContiguous(tctx, "<null>") catch return error.OutOfMemory;
            try self.trackObj(&fallback.header);
            self.runtime.writePtr(node.output, @ptrCast(&fallback.header));
            return;
        }
        const v = reflect_rec.fields[3];

        var buf: [64]u8 = undefined;
        const slice: []const u8 = switch (v) {
            .boolean => if (v.boolean[0] != 0) "true" else "false",
            .char => blk: {
                const cp: u32 = @bitCast(v.char);
                const codepoint: u21 = @intCast(cp);
                const n = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                break :blk buf[0..n];
            },
            .i8 => blk: {
                const x: i8 = @bitCast(v.i8[0]);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<i8>";
            },
            .u8 => blk: {
                break :blk std.fmt.bufPrint(&buf, "{d}", .{v.u8[0]}) catch "<u8>";
            },
            .i16 => blk: {
                const x: i16 = @bitCast(v.i16[0..2].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<i16>";
            },
            .u16 => blk: {
                const x: u16 = @bitCast(v.u16[0..2].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<u16>";
            },
            .i32 => blk: {
                const x: i32 = @bitCast(v.i32[0..4].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<i32>";
            },
            .u32 => blk: {
                const x: u32 = @bitCast(v.u32[0..4].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<u32>";
            },
            .i64 => blk: {
                const x: i64 = @bitCast(v.i64[0..8].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<i64>";
            },
            .u64 => blk: {
                const x: u64 = @bitCast(v.u64[0..8].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<u64>";
            },
            .i128 => blk: {
                const x: i128 = @bitCast(v.i128[0..16].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<i128>";
            },
            .u128 => blk: {
                const x: u128 = @bitCast(v.u128[0..16].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<u128>";
            },
            .isize => blk: {
                const x: isize = @bitCast(v.isize);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<isize>";
            },
            .usize => blk: {
                const x: usize = @bitCast(v.usize);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<usize>";
            },
            .f16 => blk: {
                const x: f16 = @bitCast(v.f16[0..2].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<f16>";
            },
            .f32 => blk: {
                const x: f32 = @bitCast(v.f32[0..4].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<f32>";
            },
            .f64 => blk: {
                const x: f64 = @bitCast(v.f64[0..8].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<f64>";
            },
            .f128 => blk: {
                const x: f128 = @bitCast(v.f128[0..16].*);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{x}) catch "<f128>";
            },
            .null_val => "null",
            .unit => "void",
            .ref => blk: {
                // str 直接返回字节；其他引用返回 <obj>
                if (v.ref.type_tag == .str) {
                    const s: *value.Str = @alignCast(@fieldParentPtr("header", v.ref));
                    break :blk s.bytes();
                }
                break :blk "<obj>";
            },
        };

        const new_str = value.Str.createContiguous(tctx, slice) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    /// builtin_reflect_deref：返回 Reflect.__target
    pub fn execBuiltinReflectDeref(self: *Engine, node: *const Node) EngineError!void {
        const reflect_chan = node.inputs[0];
        const reflect_rec = self.readRecord(reflect_chan) orelse {
            self.valueToChan(node.output, value.Value.fromUnit());
            return;
        };
        if (reflect_rec.fields.len < 5) {
            self.valueToChan(node.output, value.Value.fromUnit());
            return;
        }
        const target_value = reflect_rec.fields[3];
        try self.writeFieldResult(node.output, target_value);
    }

    /// builtin_reflect_field_name：返回 Reflect 第 i 个字段名
    ///
    /// meta_index = 0xFFFF 时返回 ADT 构造器名
    pub fn execBuiltinReflectFieldName(self: *Engine, node: *const Node) EngineError!void {
        const tctx = self.tctx.?;
        const reflect_chan = node.inputs[0];
        // meta_index >= 0xFFFE: 特殊编码（adt_constructor）；否则从 inputs[1] 读取运行时索引
        const field_idx: usize = if (node.meta_index >= 0xFFFE)
            node.meta_index
        else
            self.chanToValue(node.inputs[1]).asUsize();
        const reflect_rec = self.readRecord(reflect_chan) orelse {
            self.emitEmptyStr(node);
            return;
        };
        if (reflect_rec.fields.len < 5) {
            self.emitEmptyStr(node);
            return;
        }
        const target_value = reflect_rec.fields[3];
        var type_id: u16 = reflect_rec.fields[4].asU16();

        // type_id 未知时（泛型递归格式化：field_value 返回 freshTypeVar，
        // 编译期无法解析 type_id），从目标 RecordValue 的 type_name 反查 type_id。
        // 这使递归 ADT 格式化能正确获取构造器名和字段名，无需哨兵传播。
        if (type_id == 0) {
            if (target_value == .ref and target_value.ref.type_tag == .record) {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                type_id = self.ir.type_metadata_table.getIdByName(rec.type_name);
            }
        }

        const name: []const u8 = blk: {
            if (type_id == 0) break :blk "";
            const md: *const TypeMetadata = self.ir.type_metadata_table.get(type_id) orelse break :blk "";
            if (field_idx == 0xFFFF) {
                // Newtype: 构造器名 = 类型名
                if (md.structure == .newtype) break :blk md.name;
                // ADT 构造器名：从 __tag 查
                if (target_value == .ref and target_value.ref.type_tag == .record) {
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                    if (rec.fields.len > 0) {
                        const tag: usize = @intCast(rec.fields[0].asI64());
                        break :blk switch (md.structure) {
                            .adt => |ctors| if (tag < ctors.len) ctors[tag].name else "",
                            .record => md.name,
                            else => "",
                        };
                    }
                }
                break :blk "";
            }
            break :blk switch (md.structure) {
                .record => |fields| if (field_idx < fields.len)
                    reflectFieldName(fields[field_idx].name)
                else
                    "",
                .adt => |ctors| blk2: {
                    if (target_value != .ref or target_value.ref.type_tag != .record) break :blk2 "";
                    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", target_value.ref));
                    if (rec.fields.len == 0) break :blk2 "";
                    const tag: usize = @intCast(rec.fields[0].asI64());
                    if (tag >= ctors.len) break :blk2 "";
                    const ctor = ctors[tag];
                    if (field_idx >= ctor.fields.len) break :blk2 "";
                    break :blk2 reflectFieldName(ctor.fields[field_idx].name);
                },
                // newtype 的唯一字段始终是位置参数，返回空字符串
                .newtype => "",
                else => "",
            };
        };

        const new_str = value.Str.createContiguous(tctx, name) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    /// 辅助：发射空字符串到输出通道
    pub fn emitEmptyStr(self: *Engine, node: *const Node) void {
        const tctx = self.tctx.?;
        const new_str = value.Str.createContiguous(tctx, "") catch return;
        self.trackObj(&new_str.header) catch return;
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    /// 反射字段名归一化：位置参数占位符（`_0`、`_1` 等）返回空字符串，
    /// 使格式化输出 `Some(10)` 而非 `Some(_0: 10)`。
    /// 判定规则：以 `_` 开头且后续全为 ASCII 数字。
    pub fn reflectFieldName(name: []const u8) []const u8 {
        if (name.len < 2 or name[0] != '_') return name;
        for (name[1..]) |c| {
            if (c < '0' or c > '9') return name;
        }
        return "";
    }

    /// builtin_reflect_meta：读取 Reflect 自身的元信息字段
    ///
    /// inputs[0] = Reflect 通道，meta_index = 字段索引
    /// 0=type_name(str), 1=kind(str), 2=field_count(usize)
    /// output = ref_chan（str）或 usize_chan（field_count）
    pub fn execBuiltinReflectMeta(self: *Engine, node: *const Node) EngineError!void {
        const reflect_chan = node.inputs[0];
        const field_idx: usize = node.meta_index;
        const reflect_rec = self.readRecord(reflect_chan) orelse {
            if (field_idx == 2) {
                self.valueToChan(node.output, value.Value.fromUsize(0));
            } else {
                self.emitEmptyStr(node);
            }
            return;
        };
        if (reflect_rec.fields.len < 5) {
            if (field_idx == 2) {
                self.valueToChan(node.output, value.Value.fromUsize(0));
            } else {
                self.emitEmptyStr(node);
            }
            return;
        }
        const result = reflect_rec.fields[field_idx];
        self.valueToChan(node.output, result);
    }
};
