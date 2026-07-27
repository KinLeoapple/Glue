//! TypeInfo RecordValue 构造器（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 27 个 make*/emit* 函数，构造反射系统所需的 TypeInfo、LayoutInfo、
//! TraitImplInfo、FieldMeta、ConstructorMeta、TypeParamMeta、FuncSigMeta、
//! TraitMeta、MethodMeta、AssociatedTypeMeta 等 RecordValue。
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
const TypeKind = ir_mod.meta_mod.TypeKind;
const ThreadContext = mem.ThreadContext;

pub const Methods = struct {
    /// 从 meta_index 构造 TypeInfo Value（不写入通道，返回 Value）
    /// 用于 typeof(T?) 中递归构造 inner TypeInfo
    pub fn makeTypeInfoFromMeta(self: *Engine, meta_idx: u16) EngineError!value.Value {
        // nullable 包装
        if (meta_idx & 0x4000 != 0) {
            const inner_meta: u16 = meta_idx & 0xBFFF;
            const inner_val = try self.makeTypeInfoFromMeta(inner_meta);
            return self.makeNullableTypeInfoValue(inner_val);
        }
        // 泛型参数引用（0x8000|param_idx）：从当前帧 type_args 查实际 type_id
        if (meta_idx & 0x8000 != 0) {
            const param_idx: u16 = meta_idx & 0x7FFF;
            const type_args = self.activeTypeArgs();
            if (param_idx < type_args.len) {
                const actual_type_id = type_args[param_idx];
                if (actual_type_id != 0) {
                    if (self.ir.type_metadata_table.get(actual_type_id)) |_| {
                        return self.makeTypeInfoFromId(actual_type_id);
                    }
                }
            }
            return self.makePlaceholderTypeInfoValue("?");
        }
        if (meta_idx == 0) return self.makePlaceholderTypeInfoValue("?");
        if (self.ir.type_metadata_table.get(meta_idx)) |_| {
            return self.makeTypeInfoFromId(meta_idx);
        }
        return self.makePlaceholderTypeInfoValue("<unknown>");
    }

    /// 构造 Nullable kind 的 TypeInfo Value
    /// 复用 inner TypeInfo 的 name，kind=Nullable，structure=Nullable(inner TypeInfo)
    pub fn makeNullableTypeInfoValue(self: *Engine, inner_value: value.Value) EngineError!value.Value {
        const tctx = self.tctx.?;
        // 从 inner TypeInfo RecordValue 提取 name 字段（fields[0] 是 str）
        const inner_name: []const u8 = blk: {
            switch (inner_value) {
                .ref => |header| {
                    if (header.type_tag == .record) {
                        const r: *value.RecordValue = @alignCast(@fieldParentPtr("header", header));
                        if (r.fields.len > 0) {
                            switch (r.fields[0]) {
                                .ref => |str_header| {
                                    if (str_header.type_tag == .str) {
                                        const s: *value.Str = @alignCast(@fieldParentPtr("header", str_header));
                                        break :blk s.bytes();
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
            break :blk "?";
        };
        // structure: Nullable(inner) — 用 Nullable 构造器包装 inner TypeInfo
        var struct_fields = [_]value.Value{inner_value};
        const struct_rec = value.Value.makeRecord(tctx, "Nullable", &struct_fields) catch return error.OutOfMemory;
        try self.trackObj(struct_rec.asRef());

        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, inner_name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, TypeKind.nullable.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = struct_rec;
        field_buf[4] = try self.makeLayoutInfoRecord(.{ .size = 8, .alignment = 8 });
        field_buf[5] = try self.makeEmptyTraitImplInfoRecord();
        field_buf[6] = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 Nullable kind 的 TypeInfo 并写入通道
    pub fn emitNullableTypeInfo(self: *Engine, node: *const Node, inner_value: value.Value, tctx: *ThreadContext) EngineError!void {
        _ = tctx;
        const rv = try self.makeNullableTypeInfoValue(inner_value);
        self.runtime.writePtr(node.output, @ptrCast(rv.asRef()));
    }

    /// 构造占位 TypeInfo Value（不写入通道，返回 Value）
    pub fn makePlaceholderTypeInfoValue(self: *Engine, name: []const u8) EngineError!value.Value {
        const tctx = self.tctx.?;
        const unit_rec = value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory;
        try self.trackObj(unit_rec.asRef());

        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, TypeKind.unit.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = unit_rec;
        field_buf[4] = try self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 });
        field_buf[5] = try self.makeEmptyTraitImplInfoRecord();
        field_buf[6] = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 获取当前活跃的 type_args 切片（v3 阶段 9：哨兵协议废除后直接读帧）
    /// 协程路径（call_depth == 0）：从 current_type_args 读（由 segmentInstallFrame 设置）
    /// sync 路径（call_depth > 0）：从 runtime.frame_stack 的当前帧读
    pub fn activeTypeArgs(self: *const Engine) []const u16 {
        return if (self.runtime.call_depth > 0)
            self.runtime.frame_stack[self.runtime.call_depth - 1].type_args
        else
            self.current_type_args;
    }

    /// 获取父帧的 type_args（用于 call/spawn 边界解析泛型参数引用）
    /// sync 路径：frame_stack 栈顶是当前调用者（enterFunction 之前）
    /// 协程路径：current_type_args 是当前协程帧
    pub fn parentTypeArgs(self: *const Engine) []const u16 {
        return self.activeTypeArgs();
    }

    /// 解析 type_args 列表中的泛型参数引用（0x8000|param_idx）
    ///
    /// 当泛型函数 A<T> 调用另一个泛型函数 B<T> 时，B 的 type_args 中可能包含
    /// 泛型参数引用 0x8000|param_idx（表示"使用调用者 A 的第 param_idx 个类型实参"）。
    /// 此方法从父帧查找实际 type_id 并替换。非引用值（具体 type_id 或 0）原样返回。
    /// 返回的切片由 scratch arena 分配，调用方负责管理生命周期。
    pub fn materializeTypeArgs(self: *Engine, type_args: []const u16) EngineError![]const u16 {
        var has_ref = false;
        for (type_args) |ta| {
            if (ta & 0x8000 != 0) {
                has_ref = true;
                break;
            }
        }
        if (!has_ref) {
            return type_args;
        }

        const tctx = self.tctx.?;
        const resolved = tctx.backing.alloc(u16, type_args.len) catch return error.OutOfMemory;
        const parent_args = self.parentTypeArgs();
        for (type_args, 0..) |ta, i| {
            if (ta & 0x8000 != 0) {
                const param_idx: u16 = ta & 0x7FFF;
                if (param_idx < parent_args.len) {
                    resolved[i] = parent_args[param_idx];
                } else {
                    resolved[i] = 0;
                }
            } else {
                resolved[i] = ta;
            }
        }
        return resolved;
    }

    /// 构造占位 TypeInfo RecordValue（未知类型或查表失败时使用）
    /// 新设计：7 个顶层字段（name/module/kind/structure/layout/impls/type_params）
    pub fn emitPlaceholderTypeInfo(self: *Engine, node: *const Node, name: []const u8, tctx: *ThreadContext) EngineError!void {
        var placeholder_fields = [_]value.Value{
            // 0: name
            value.Value.fromStringBytes(tctx, name) catch return error.OutOfMemory,
            // 1: module
            value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory,
            // 2: kind (TypeKind 构造器名)
            value.Value.fromStringBytes(tctx, "Unit") catch return error.OutOfMemory,
            // 3: structure (TypeStructure.Unit，空 RecordValue)
            value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory,
            // 4: layout (LayoutInfo{0, 0})
            self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 }) catch return error.OutOfMemory,
            // 5: impls (empty TraitImplInfo)
            self.makeEmptyTraitImplInfoRecord() catch return error.OutOfMemory,
            // 6: type_params (empty array)
            value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory,
        };
        try self.trackRefFields(&placeholder_fields);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &placeholder_fields) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(rec.asRef()));
    }

    /// 构造完整 TypeInfo RecordValue（7 顶层字段，完整嵌套结构）
    pub fn emitTypeInfoRecord(self: *Engine, node: *const Node, md: *const TypeMetadata, tctx: *ThreadContext) EngineError!void {
        var field_buf: [7]value.Value = undefined;

        // 0: name (str)
        field_buf[0] = value.Value.fromStringBytes(tctx, md.name) catch return error.OutOfMemory;
        // 1: module (str)
        field_buf[1] = value.Value.fromStringBytes(tctx, md.module) catch return error.OutOfMemory;
        // 2: kind (str，TypeKind 的 ADT 构造器名)
        field_buf[2] = value.Value.fromStringBytes(tctx, md.kind.ctorName()) catch return error.OutOfMemory;
        // 3: structure (TypeStructure ADT，按 kind 构造对应变体)
        field_buf[3] = self.makeStructureRecord(md) catch return error.OutOfMemory;
        // 4: layout (LayoutInfo RecordValue)
        field_buf[4] = self.makeLayoutInfoRecord(md.layout) catch return error.OutOfMemory;
        // 5: impls (TraitImplInfo RecordValue)
        field_buf[5] = self.makeTraitImplInfoRecord(md.impls) catch return error.OutOfMemory;
        // 6: type_params (Array<TypeParamMeta>)
        field_buf[6] = self.makeTypeParamMetaArray(md.type_params) catch return error.OutOfMemory;

        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        self.runtime.writePtr(node.output, @ptrCast(rec.asRef()));
    }

    /// 构造 LayoutInfo RecordValue：(size, alignment)
    pub fn makeLayoutInfoRecord(self: *Engine, layout: ir_mod.meta_mod.LayoutInfo) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            value.Value.fromU32(layout.size),
            value.Value.fromU32(layout.alignment),
        };
        const rec = try value.Value.makeRecord(tctx, "LayoutInfo", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造空 TraitImplInfo RecordValue（占位 TypeInfo 用）
    pub fn makeEmptyTraitImplInfoRecord(self: *Engine) !value.Value {
        const tctx = self.tctx.?;
        const empty = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
        try self.trackObj(empty.asRef());
        // 同一 ArrayValue 存入 4 个字段，需 retain 3 次（总 RC=4）
        // 避免 RecordValue.deinit 第 1 次 release 释放后，后续 3 次 release 访问已释放内存
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        _ = value.obj_header.retain(empty.ref, self.tctx.?);
        var fields = [_]value.Value{ empty, empty, empty, empty };
        const rec = value.Value.makeRecord(tctx, "TraitImplInfo", &fields) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitImplInfo RecordValue：(parent_traits, implemented_traits, methods, associated_types)
    pub fn makeTraitImplInfoRecord(self: *Engine, impls: ir_mod.meta_mod.TraitImplInfo) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            try self.makeTraitMetaArray(impls.parent_traits),
            try self.makeTraitMetaArray(impls.implemented_traits),
            try self.makeMethodMetaArray(impls.methods),
            try self.makeAssociatedTypeMetaArray(impls.associated_types),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TraitImplInfo", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TypeStructure RecordValue（按 kind 构造对应变体）
    /// 返回 RecordValue，type_name 为变体构造器名（如 "Record"、"Adt"）
    /// 显式命名错误集 EngineError 打破与 makeTypeInfoFromId 的循环依赖（推断错误集才会循环）
    pub fn makeStructureRecord(self: *Engine, md: *const TypeMetadata) EngineError!value.Value {
        const tctx = self.tctx.?;
        switch (md.structure) {
            .primitive => {
                const rec = try value.Value.makeRecord(tctx, "Primitive", &.{});
                try self.trackObj(rec.asRef());
                return rec;
            },
            .record => |fields| {
                const fields_arr = try self.makeFieldMetaArray(fields);
                var buf = [_]value.Value{fields_arr};
                const rec = try value.Value.makeRecord(tctx, "Record", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .adt => |constructors| {
                const ctors_arr = try self.makeConstructorMetaArray(constructors);
                var buf = [_]value.Value{ctors_arr};
                const rec = try value.Value.makeRecord(tctx, "Adt", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .newtype => |inner_id| {
                const inner_info = try self.makeTypeInfoFromId(inner_id);
                var buf = [_]value.Value{inner_info};
                const rec = try value.Value.makeRecord(tctx, "Newtype", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .alias => |target_id| {
                const target_info = try self.makeTypeInfoFromId(target_id);
                var buf = [_]value.Value{target_info};
                const rec = try value.Value.makeRecord(tctx, "Alias", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .func => |fs| {
                const sig_rec = try self.makeFuncSigRecord(fs);
                var buf = [_]value.Value{sig_rec};
                const rec = try value.Value.makeRecord(tctx, "Func", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .trait => |tm| {
                const trait_rec = try self.makeTraitMetaRecord(tm);
                var buf = [_]value.Value{trait_rec};
                const rec = try value.Value.makeRecord(tctx, "Trait", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
            .unit => {
                const rec = try value.Value.makeRecord(tctx, "Unit", &.{});
                try self.trackObj(rec.asRef());
                return rec;
            },
            .nullable => |inner_id| {
                const inner_info = try self.makeTypeInfoFromId(inner_id);
                var buf = [_]value.Value{inner_info};
                const rec = try value.Value.makeRecord(tctx, "Nullable", &buf);
                try self.trackObj(rec.asRef());
                return rec;
            },
        }
    }

    /// 按 type_id 查表递归构造 TypeInfo RecordValue
    /// type_id=0 时返回占位 TypeInfo（null 内部类型）
    /// 显式命名错误集 EngineError 打破与 makeStructureRecord 的循环依赖（推断错误集才会循环）
    pub fn makeTypeInfoFromId(self: *Engine, type_id: u16) EngineError!value.Value {
        const tctx = self.tctx.?;
        if (type_id == 0 or type_id > self.ir.type_metadata_table.entries.len) {
            // 未解析：返回占位 TypeInfo
            const placeholder_name = "?";
            var placeholder_fields = [_]value.Value{
                value.Value.fromStringBytes(tctx, placeholder_name) catch return error.OutOfMemory,
                value.Value.fromStringBytes(tctx, "") catch return error.OutOfMemory,
                value.Value.fromStringBytes(tctx, "Unit") catch return error.OutOfMemory,
                value.Value.makeRecord(tctx, "Unit", &.{}) catch return error.OutOfMemory,
                self.makeLayoutInfoRecord(.{ .size = 0, .alignment = 0 }) catch return error.OutOfMemory,
                self.makeEmptyTraitImplInfoRecord() catch return error.OutOfMemory,
                value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory,
            };
            try self.trackRefFields(&placeholder_fields);
            const rec = value.Value.makeRecord(tctx, "TypeInfo", &placeholder_fields) catch return error.OutOfMemory;
            try self.trackObj(rec.asRef());
            return rec;
        }
        const md = &self.ir.type_metadata_table.entries[type_id - 1];
        var field_buf: [7]value.Value = undefined;
        field_buf[0] = value.Value.fromStringBytes(tctx, md.name) catch return error.OutOfMemory;
        field_buf[1] = value.Value.fromStringBytes(tctx, md.module) catch return error.OutOfMemory;
        field_buf[2] = value.Value.fromStringBytes(tctx, md.kind.ctorName()) catch return error.OutOfMemory;
        field_buf[3] = try self.makeStructureRecord(md);
        field_buf[4] = try self.makeLayoutInfoRecord(md.layout);
        field_buf[5] = try self.makeTraitImplInfoRecord(md.impls);
        field_buf[6] = try self.makeTypeParamMetaArray(md.type_params);
        try self.trackRefFields(&field_buf);
        const rec = value.Value.makeRecord(tctx, "TypeInfo", &field_buf) catch return error.OutOfMemory;
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 FieldMeta RecordValue：(name, type_name, is_nullable, index)
    pub fn makeFieldMetaRecord(self: *Engine, fm: ir_mod.meta_mod.FieldMeta) !value.Value {
        const tctx = self.tctx.?;
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, fm.name),
            try value.Value.fromStringBytes(tctx, fm.type_name),
            value.Value.fromBool(fm.is_nullable),
            value.Value.fromU32(fm.index),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "FieldMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 FieldMeta 数组
    pub fn makeFieldMetaArray(self: *Engine, items: []const ir_mod.meta_mod.FieldMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeFieldMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 ConstructorMeta RecordValue：(name, fields, is_unit, index)
    pub fn makeConstructorMetaRecord(self: *Engine, cm: ir_mod.meta_mod.ConstructorMeta) !value.Value {
        const tctx = self.tctx.?;
        const fields_arr = try self.makeFieldMetaArray(cm.fields);
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, cm.name),
            fields_arr,
            value.Value.fromBool(cm.is_unit),
            value.Value.fromU32(cm.index),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "ConstructorMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 ConstructorMeta 数组
    pub fn makeConstructorMetaArray(self: *Engine, items: []const ir_mod.meta_mod.ConstructorMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeConstructorMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 TypeParamMeta RecordValue：(name, constraints, is_specialized, specialization)
    pub fn makeTypeParamMetaRecord(self: *Engine, tp: ir_mod.meta_mod.TypeParamMeta) !value.Value {
        const tctx = self.tctx.?;
        // constraints: []const []const u8 → Array<str>
        const constraints_arr = try self.makeStrArray(tp.constraints);
        // specialization: ?[]const u8 → nullable<str>
        const spec_val = if (tp.specialization) |s|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, s)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, tp.name),
            constraints_arr,
            value.Value.fromBool(tp.is_specialized),
            spec_val,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TypeParamMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TypeParamMeta 数组
    pub fn makeTypeParamMetaArray(self: *Engine, items: []const ir_mod.meta_mod.TypeParamMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeTypeParamMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 FuncSigMeta RecordValue：(param_types, return_type, is_async)
    pub fn makeFuncSigRecord(self: *Engine, fs: ir_mod.meta_mod.FuncSigMeta) !value.Value {
        const tctx = self.tctx.?;
        const param_types_arr = try self.makeStrArray(fs.param_types);
        var fields = [_]value.Value{
            param_types_arr,
            try value.Value.fromStringBytes(tctx, fs.return_type),
            value.Value.fromBool(fs.is_async),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "FuncSigMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitMeta RecordValue：(name, module, type_params, parent_traits, associated_types, method_names)
    pub fn makeTraitMetaRecord(self: *Engine, tm: ir_mod.meta_mod.TraitMeta) !value.Value {
        const tctx = self.tctx.?;
        const tp_arr = try self.makeTypeParamMetaArray(tm.type_params);
        const pt_arr = try self.makeStrArray(tm.parent_traits);
        const at_arr = try self.makeStrArray(tm.associated_types);
        const mn_arr = try self.makeStrArray(tm.method_names);
        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, tm.name),
            try value.Value.fromStringBytes(tctx, tm.module),
            tp_arr,
            pt_arr,
            at_arr,
            mn_arr,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "TraitMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 TraitMeta 数组
    pub fn makeTraitMetaArray(self: *Engine, items: []const ir_mod.meta_mod.TraitMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeTraitMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 MethodMeta RecordValue：(name, signature, is_override, is_delegate, delegate_trait, is_async)
    pub fn makeMethodMetaRecord(self: *Engine, mm: ir_mod.meta_mod.MethodMeta) !value.Value {
        const tctx = self.tctx.?;
        const sig_rec = try self.makeFuncSigRecord(mm.signature);
        // delegate_trait: ?[]const u8 → nullable<str>
        const dt_val = if (mm.delegate_trait) |dt|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, dt)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, mm.name),
            sig_rec,
            value.Value.fromBool(mm.is_override),
            value.Value.fromBool(mm.is_delegate),
            dt_val,
            value.Value.fromBool(mm.is_async),
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "MethodMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 MethodMeta 数组
    pub fn makeMethodMetaArray(self: *Engine, items: []const ir_mod.meta_mod.MethodMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeMethodMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 构造 AssociatedTypeMeta RecordValue：(name, is_specified, default_type)
    pub fn makeAssociatedTypeMetaRecord(self: *Engine, atm: ir_mod.meta_mod.AssociatedTypeMeta) !value.Value {
        const tctx = self.tctx.?;
        // default_type: ?[]const u8 → nullable<str>
        const dt_val = if (atm.default_type) |dt|
            value.Value{ .ref = (try value.Value.fromStringBytes(tctx, dt)).ref }
        else
            value.Value.fromNull();

        var fields = [_]value.Value{
            try value.Value.fromStringBytes(tctx, atm.name),
            value.Value.fromBool(atm.is_specified),
            dt_val,
        };
        try self.trackRefFields(&fields);
        const rec = try value.Value.makeRecord(tctx, "AssociatedTypeMeta", &fields);
        try self.trackObj(rec.asRef());
        return rec;
    }

    /// 构造 AssociatedTypeMeta 数组
    pub fn makeAssociatedTypeMetaArray(self: *Engine, items: []const ir_mod.meta_mod.AssociatedTypeMeta) !value.Value {
        const tctx = self.tctx.?;
        if (items.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(items.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (items, 0..) |it, i| {
            ptr[i] = try self.makeAssociatedTypeMetaRecord(it);
        }
        const arr = value.Value.makeArray(tctx, ptr[0..items.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }

    /// 辅助：从 []const []const u8 构造字符串数组
    pub fn makeStrArray(self: *Engine, strs: []const []const u8) !value.Value {
        const tctx = self.tctx.?;
        if (strs.len == 0) {
            const arr = value.Value.makeArray(tctx, &.{}, null) catch return error.OutOfMemory;
            try self.trackObj(arr.asRef());
            return arr;
        }
        const buf = try tctx.allocObj(strs.len * @sizeOf(value.Value));
        defer tctx.freeObj(buf.ptr);
        const ptr: [*]value.Value = @ptrCast(@alignCast(buf.ptr));
        for (strs, 0..) |s, i| {
            const str_val = value.Value.fromStringBytes(tctx, s) catch return error.OutOfMemory;
            try self.trackObj(str_val.ref);
            ptr[i] = str_val;
        }
        const arr = value.Value.makeArray(tctx, ptr[0..strs.len], null) catch return error.OutOfMemory;
        try self.trackObj(arr.asRef());
        return arr;
    }
};
