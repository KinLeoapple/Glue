//! 类型/元数据注册与查询（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含 type/Trait 注册、TypeMetadata 收集/解析、类型布局计算、
//! Tarjan SCC 以及反射辅助类型的 field_id 注册等方法。
//! 通过 pub const 别名混入 IRBuilder（Zig 0.16 已移除 usingnamespace）。

const std = @import("std");
const ast = @import("ast");
const glue_builtin = @import("glue_builtin");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const type_descriptor_mod = @import("type_descriptor.zig");
const builder_mod = @import("builder.zig");
const sema_output_mod = @import("sema").sema_output;
const builtin_type_names = @import("builtin_type_names.zig");

const IRBuilder = builder_mod.IRBuilder;
const BuildError = builder_mod.BuildError;
const ChannelSpace = channel_mod.ChannelSpace;
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const TypeMetadata = meta_mod.TypeMetadata;
const TypeKind = meta_mod.TypeKind;
const TypeStructure = meta_mod.TypeStructure;
const LayoutInfo = meta_mod.LayoutInfo;
const TraitImplInfo = meta_mod.TraitImplInfo;
const FieldMeta = meta_mod.FieldMeta;
const ConstructorMeta = meta_mod.ConstructorMeta;
const TypeParamMeta = meta_mod.TypeParamMeta;
const MethodMeta = meta_mod.MethodMeta;
const CtorDefInfo = sema_output_mod.CtorDefInfo;
const TraitMethodSig = sema_output_mod.TraitMethodSig;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 反射辅助类型 field_id 注册
    // ════════════════════════════════════════════

    /// 注册 TypeInfo 类型的 field_id 映射（反射机制）
    ///
    /// TypeInfo 是 builtin typeof 的返回类型，包含 7 个顶层字段。
    /// 字段顺序与 meta.TypeMetadata 字段定义保持一致（0-indexed）。
    /// 工作原理：info.name → record_get(info, field_id=0)
    pub fn registerTypeInfoFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{
            "name",          // 0
            "module",        // 1
            "kind",          // 2
            "structure",     // 3
            "layout",        // 4
            "impls",         // 5
            "type_params",   // 6
        };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TypeInfo", fname, @intCast(idx));
        }
        // 注册子结构 field_id
        try self.registerLayoutInfoFields();
        try self.registerTraitImplInfoFields();
        // 注册反射辅助类型的 field_id（嵌套 RecordValue 使用）
        try self.registerFieldMetaFields();
        try self.registerConstructorMetaFields();
        try self.registerTypeParamMetaFields();
        try self.registerMethodMetaFields();
        try self.registerFuncSigMetaFields();
        try self.registerTraitMetaFields();
        try self.registerAssociatedTypeMetaFields();
    }

    /// LayoutInfo 字段：(size, alignment)
    pub fn registerLayoutInfoFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "size", "alignment" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("LayoutInfo", fname, @intCast(idx));
        }
    }

    /// TraitImplInfo 字段：(parent_traits, implemented_traits, methods, associated_types)
    pub fn registerTraitImplInfoFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "parent_traits", "implemented_traits", "methods", "associated_types" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TraitImplInfo", fname, @intCast(idx));
        }
    }

    /// FieldMeta 字段：(name, type_name, is_nullable, index)
    pub fn registerFieldMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "type_name", "is_nullable", "index" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("FieldMeta", fname, @intCast(idx));
        }
    }

    /// ConstructorMeta 字段：(name, fields, is_unit, index)
    pub fn registerConstructorMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "fields", "is_unit", "index" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("ConstructorMeta", fname, @intCast(idx));
        }
    }

    /// TypeParamMeta 字段：(name, constraints, is_specialized, specialization)
    pub fn registerTypeParamMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "constraints", "is_specialized", "specialization" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TypeParamMeta", fname, @intCast(idx));
        }
    }

    /// MethodMeta 字段：(name, signature, is_override, is_delegate, delegate_trait, is_async)
    pub fn registerMethodMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "signature", "is_override", "is_delegate", "delegate_trait", "is_async" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("MethodMeta", fname, @intCast(idx));
        }
    }

    /// FuncSigMeta 字段：(param_types, return_type, is_async)
    pub fn registerFuncSigMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "param_types", "return_type", "is_async" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("FuncSigMeta", fname, @intCast(idx));
        }
    }

    /// TraitMeta 字段：(name, module, type_params, parent_traits, associated_types, method_names)
    pub fn registerTraitMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "module", "type_params", "parent_traits", "associated_types", "method_names" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TraitMeta", fname, @intCast(idx));
        }
    }

    /// AssociatedTypeMeta 字段：(name, is_specified, default_type)
    pub fn registerAssociatedTypeMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "is_specified", "default_type" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("AssociatedTypeMeta", fname, @intCast(idx));
        }
    }

    // ════════════════════════════════════════════
    // Tarjan 强连通分量（SCC）—— 用于函数调用图循环检测
    // ════════════════════════════════════════════

    pub fn tarjanSCCVisit(
        self: *IRBuilder,
        v: u16,
        index_counter: *u32,
        stack: *std.ArrayList(u16),
        on_stack: []bool,
        indices: []?u32,
        lowlinks: []u32,
        scc_id: []u32,
        scc_counter: *u32,
    ) !void {
        const vi: usize = v;
        indices[vi] = index_counter.*;
        lowlinks[vi] = index_counter.*;
        index_counter.* += 1;
        try stack.append(self.allocator, v);
        on_stack[vi] = true;

        // 遍历 v 的所有 call 节点，获取 callee func_index
        const func = self.functions.items[vi];
        const nodes_slice = self.nodes.items[func.node_start .. func.node_start + func.node_count];
        for (nodes_slice) |node| {
            if (node.op != .call) continue;
            if (node.meta_index == 0) continue;
            const call_meta = self.call_metas.items[node.meta_index - 1];
            const w = call_meta.func_index;
            const wi: usize = w;
            if (wi >= self.functions.items.len) continue;

            if (indices[wi] == null) {
                try self.tarjanSCCVisit(w, index_counter, stack, on_stack, indices, lowlinks, scc_id, scc_counter);
                lowlinks[vi] = @min(lowlinks[vi], lowlinks[wi]);
            } else if (on_stack[wi]) {
                lowlinks[vi] = @min(lowlinks[vi], indices[wi].?);
            }
        }

        // 如果 v 是 SCC 的根
        if (lowlinks[vi] == indices[vi].?) {
            while (true) {
                const w_top = stack.pop().?;
                on_stack[w_top] = false;
                scc_id[w_top] = scc_counter.*;
                if (w_top == v) break;
            }
            scc_counter.* += 1;
        }
    }

    // ════════════════════════════════════════════
    // 类型/Trait 注册（P0-b）
    // ════════════════════════════════════════════

    /// 注册 type_decl：注册 field_id_map 条目和方法（类型/构造器定义由 sema 填充到 sema_result）
    pub fn registerTypeDecl(self: *IRBuilder, td: anytype, arena_alloc: std.mem.Allocator, func_count: *u16) BuildError!void {
        switch (td.def) {
            .adt => |adt| {
                // 注册 field_id_map：__tag=0，构造器字段从 1 开始
                for (adt.constructors) |cdef| {
                    for (cdef.fields, 0..) |cf, fi| {
                        const fname = cf.name orelse try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                        self.registerFieldId(td.name, fname, @intCast(fi + 1));
                    }
                }
                self.registerFieldId(td.name, "__tag", 0);
            },
            .newtype => {
                // __tag=0，_0=1
                self.registerFieldId(td.name, "__tag", 0);
                self.registerFieldId(td.name, "_0", 1);
            },
            .error_newtype => |en| {
                // error_newtype 字段：同时注册位置名 _<idx> 和实际字段名（如 msg），
                // 与 builtin error_newtype 注册逻辑一致（见 registerBuiltinErrorNewtypes）
                for (en.params, 0..) |p, fi| {
                    const positional = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                    self.registerFieldId(td.name, positional, @intCast(fi + 1));
                    self.registerFieldId(td.name, p.name, @intCast(fi + 1));
                }
                self.registerFieldId(td.name, "__tag", 0);
            },
            .record => {},
            .alias => {},
        }

        // 注册方法为函数（方法名 mangle 为 "TypeName.method_name"）
        for (td.methods) |method| {
            if (method.body == null) continue; // trait 声明中的方法无体，跳过
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            try self.func_table.put(mangled, func_count.*);
            const placeholder_return_chan = try builder_mod.allocChanFromTypeNode(&self.channels, method.return_type);
            const placeholder_param_channels = try self.allocParamChannels(method.params, arena_alloc);
            try self.functions.append(arena_alloc, .{
                .name = mangled,
                .node_start = 0,
                .node_count = 0,
                .param_channels = placeholder_param_channels,
                .return_channel = placeholder_return_chan,
                .is_entry = false,
                .is_async = false,
            });
            func_count.* += 1;
        }

        // 注册继承的 trait 默认方法（有 body 但未被 type 覆盖的 trait 方法）
        for (td.implemented_traits) |tb| {
            if (self.sema_result.getTraitDef(tb.trait_name) == null) continue;
            const trait_methods = self.findTraitMethodsAst(tb.trait_name) orelse continue;
            for (trait_methods) |tm| {
                if (tm.body == null) continue; // 无默认实现，跳过
                const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, tm.name });
                if (self.func_table.contains(mangled)) continue; // 已被 type 覆盖
                try self.func_table.put(mangled, func_count.*);
                const placeholder_return_chan = try builder_mod.allocChanFromTypeNode(&self.channels, tm.return_type);
                const placeholder_param_channels = try self.allocParamChannels(tm.params, arena_alloc);
                try self.functions.append(arena_alloc, .{
                    .name = mangled,
                    .node_start = 0,
                    .node_count = 0,
                    .param_channels = placeholder_param_channels,
                    .return_channel = placeholder_return_chan,
                    .is_entry = false,
                    .is_async = false,
                });
                func_count.* += 1;
            }
        }

        // 收集 TypeMetadata（typeof 反射机制）：在类型注册完成后调用
        try self.collectTypeMetadata(td, arena_alloc);
    }

    /// 注册内建类型到 TypeMetadataTable（使 typeof(i32) 等返回正确 TypeInfo）
    ///
    /// 内建类型不通过 AST type_decl 声明，但 typeof(i32) / typeof(str) 等需要返回
    /// Primitive kind + 正确 name + 正确 layout 的 TypeInfo。
    /// 在 build() 开头调用，先于用户类型注册。
    pub fn registerBuiltinTypeMetadata(self: *IRBuilder, arena_alloc: std.mem.Allocator) !void {
        const Builtin = struct { n: []const u8 };
        const builtins = [_]Builtin{
            .{ .n = "bool" },    .{ .n = "char" },
            .{ .n = "i8" },      .{ .n = "u8" },
            .{ .n = "i16" },     .{ .n = "u16" },
            .{ .n = "i32" },     .{ .n = "u32" },
            .{ .n = "i64" },     .{ .n = "u64" },
            .{ .n = "i128" },    .{ .n = "u128" },
            .{ .n = "f16" },     .{ .n = "f32" },
            .{ .n = "f64" },     .{ .n = "f128" },
            .{ .n = "str" },     .{ .n = "void" },
        };
        for (builtins) |b| {
            // layout 由 primitiveLayout 计算（保证与字段布局一致）
            const layout = builder_mod.primitiveLayout(b.n) orelse LayoutInfo{ .size = 0, .alignment = 1 };
            const entry = TypeMetadata{
                .name = b.n,
                .module = "",
                .kind = .primitive,
                .structure = .primitive,
                .layout = layout,
                .impls = .{
                    .parent_traits = &.{},
                    .implemented_traits = &.{},
                    .methods = &.{},
                    .associated_types = &.{},
                },
                .type_params = &.{},
            };
            try self.type_metadata_entries.append(arena_alloc, entry);
            const type_id: u16 = @intCast(self.type_metadata_entries.items.len); // 1-indexed
            try self.type_name_to_id.put(arena_alloc, b.n, type_id);
        }
    }

    /// 从类型名字符串推导 TypeDescriptor（用于 builtin 类型注册）
    pub fn chanTypeFromTypeName(type_name: []const u8) *const TypeDescriptor {
        // 内置标量 + str/unit → TypeDescriptor
        if (builtin_type_names.typeDescFromBuiltinName(type_name)) |td| return td;
        // nullable 类型 "T?" → 返回内部类型的 TypeDescriptor
        if (type_name.len > 1 and type_name[type_name.len - 1] == '?') {
            return chanTypeFromTypeName(type_name[0 .. type_name.len - 1]);
        }
        // 用户自定义类型（ADT/record/newtype）→ ref
        return type_descriptor_mod.ref_descriptor;
    }

    /// 从类型名字符串推导 TypeDescriptor（chanTypeFromTypeName 的别名）
    pub fn typeDescFromTypeName(type_name: []const u8) *const TypeDescriptor {
        return chanTypeFromTypeName(type_name);
    }

    /// 从 sema_result 查找构造器的 return_type TypeNode（GADT 专用）
    pub fn getCtorAstReturnType(self: *IRBuilder, ctor_name: []const u8) ?*ast.TypeNode {
        const ctor = self.sema_result.getCtorDef(ctor_name) orelse return null;
        if (ctor.return_type_node) |rtn| return @constCast(rtn);
        return null;
    }

    /// 从 sema_result 查找构造器字段的 TypeNode
    pub fn getCtorAstFieldTypeNode(self: *IRBuilder, ctor_name: []const u8, field_idx: usize) ?*ast.TypeNode {
        const ctor = self.sema_result.getCtorDef(ctor_name) orelse return null;
        if (field_idx >= ctor.field_type_nodes.len) return null;
        if (ctor.field_type_nodes[field_idx]) |ftn| return @constCast(ftn);
        return null;
    }

    /// 设计必需的 AST 访问：从 current_module 查找 trait_decl 的方法列表
    ///
    /// sema_result.getTraitDef 提供压平后的方法签名（含继承方法），但 trait 值分派和
    /// 默认方法体编译需要与方法声明顺序一致的索引和 AST body/params。
    /// 这是 IR 编译对 AST 的根本依赖，非双轨制残留。
    pub fn findTraitMethodsAst(self: *IRBuilder, trait_name: []const u8) ?[]ast.MethodDecl {
        const mod = self.current_module orelse return null;
        for (mod.declarations) |decl| {
            switch (decl) {
                .trait_decl => |trd| {
                    if (std.mem.eql(u8, trd.name, trait_name)) return trd.methods;
                },
                else => {},
            }
        }
        return null;
    }

    /// 设计必需的 AST 访问：从 current_module 查找函数或方法的参数列表
    ///
    /// sema_result.getFuncSig 提供 param_type_descs（压平 TypeDescriptor）和 param_type_names，
    /// 但泛型类型参数推断（matchTypeParamToTypeId/matchTypeParamBinding）需要完整的
    /// AST type_annotation TypeNode 进行结构化匹配，字符串类型名无法替代。
    /// 这是 IR 编译对 AST 的根本依赖，非双轨制残留。
    pub fn findFuncParamsAst(self: *IRBuilder, name: []const u8) ?[]ast.Param {
        const mod = self.current_module orelse return null;
        const dot = std.mem.indexOfScalar(u8, name, '.');
        if (dot) |idx| {
            // mangled "Type.method"：先在 type_decl 的方法中查找
            const type_name = name[0..idx];
            const method_name = name[idx + 1 ..];
            for (mod.declarations) |decl| {
                switch (decl) {
                    .type_decl => |td| {
                        if (!std.mem.eql(u8, td.name, type_name)) continue;
                        for (td.methods) |m| {
                            if (std.mem.eql(u8, m.name, method_name)) return m.params;
                        }
                    },
                    else => {},
                }
            }
            // 多段 mangled 名（如 "std.pack.sub.func"）是 fun_decl，按全名精确匹配
            // 单段 "Type.method" 不走此路径：type 方法在 type_decl.methods 中
            if (std.mem.indexOfScalar(u8, method_name, '.') != null) {
                for (mod.declarations) |decl| {
                    switch (decl) {
                        .fun_decl => |fd| {
                            if (std.mem.eql(u8, fd.name, name)) return fd.params;
                        },
                        else => {},
                    }
                }
            }
        } else {
            // 普通函数名
            for (mod.declarations) |decl| {
                switch (decl) {
                    .fun_decl => |fd| {
                        if (std.mem.eql(u8, fd.name, name)) return fd.params;
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    /// AST 访问：从 current_module 查找函数声明的完整 AST（含 type_params/params/return_type/body）
    /// 用于单态化实例化器（单态化需要完整 AST body，sema 仅存签名无法替代）。
    /// name 为普通函数名、mangled 名 "Type.method" 或 stdlib mangled 名。
    /// 返回 fun_decl payload 的只读引用
    pub fn findFunDeclAst(self: *IRBuilder, name: []const u8) ?*const @FieldType(ast.Decl, "fun_decl") {
        const mod = self.current_module orelse return null;
        const dot = std.mem.indexOfScalar(u8, name, '.');
        if (dot) |idx| {
            // mangled "Type.method"：先在 type_decl 的方法中查找
            const type_name = name[0..idx];
            const method_name = name[idx + 1 ..];
            for (mod.declarations) |*decl| {
                switch (decl.*) {
                    .type_decl => |*td| {
                        if (!std.mem.eql(u8, td.name, type_name)) continue;
                        for (td.methods) |*m| {
                            if (std.mem.eql(u8, m.name, method_name)) {
                                // 方法没有独立 fun_decl，返回 null（单态化暂不支持类型方法）
                                return null;
                            }
                        }
                    },
                    else => {},
                }
            }
            // 多段 mangled 名（如 "std.pack.sub.func"）是 fun_decl，按全名精确匹配
            if (std.mem.indexOfScalar(u8, method_name, '.') != null) {
                for (mod.declarations) |*decl| {
                    switch (decl.*) {
                        .fun_decl => |*fd| {
                            if (std.mem.eql(u8, fd.name, name)) return fd;
                        },
                        else => {},
                    }
                }
            }
        } else {
            // 普通函数名
            for (mod.declarations) |*decl| {
                switch (decl.*) {
                    .fun_decl => |*fd| {
                        if (std.mem.eql(u8, fd.name, name)) return fd;
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    /// 查询构造器在其所属类型的 constructors 数组中的索引（即 __tag 值）
    /// sema_result 的 ctor_def_index 已将 ctor_idx 编码在低 16 位，直接复用
    pub fn getCtorTag(self: *IRBuilder, ctor_name: []const u8) ?u32 {
        const sr = self.sema_result;
        const packed_idx = sr.ctor_def_index.get(ctor_name) orelse return null;
        return packed_idx & 0xFFFF;
    }

    /// 注册 builtin error_newtype 构造器（决策 #18/#23）
    ///
    /// 从 glue_builtin.BUILTIN_TYPES 元信息表读取所有 builtin error_newtype 类型定义，
    /// 注册到 sema_result / field_id_map，使代码生成阶段能像用户自定义
    /// error_newtype 一样处理 CastError 等类型。
    ///
    /// 字段命名规则与用户自定义 error_newtype 一致：
    ///   - _<idx>（位置参数别名，field_id = idx + 1）
    ///   - __tag（field_id = 0）
    ///   - 用户源码字段名（field_id 同 _<idx>，便于 record_get 按名查询）
    pub fn registerBuiltinErrorTypes(self: *IRBuilder, arena_alloc: std.mem.Allocator) !void {
        const sr = self.sema_result;
        inline for (glue_builtin.BUILTIN_TYPES) |bt| {
            // 已由 sema 注册的类型跳过（sema 接入时 builtin 类型可能已注册）
            if (sr.getTypeDef(bt.name) != null) {
                // 仍需注册 field_id_map（sema 不负责 field_id_map）
                switch (bt.kind) {
                    .error_newtype => {
                        for (bt.fields, 0..) |f, fi| {
                            const fname = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                            self.registerFieldId(bt.name, fname, @intCast(fi + 1));
                            self.registerFieldId(bt.name, f.name, @intCast(fi + 1));
                        }
                        self.registerFieldId(bt.name, "__tag", 0);
                    },
                    .adt => {
                        self.registerFieldId(bt.name, "__tag", 0);
                    },
                }
            } else {
                switch (bt.kind) {
                    .error_newtype => {
                        // 构造器字段（位置参数别名 _0/_1/...）
                        const field_names = try arena_alloc.alloc(?[]const u8, bt.fields.len);
                        const field_type_descs = try arena_alloc.alloc(*const TypeDescriptor, bt.fields.len);
                        const field_type_names = try arena_alloc.alloc(?[]const u8, bt.fields.len);
                        for (bt.fields, 0..) |f, fi| {
                            const fname = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                            field_names[fi] = fname;
                            field_type_descs[fi] = chanTypeFromTypeName(f.type_name);
                            field_type_names[fi] = f.type_name;
                            // 位置别名 field_id = fi + 1（与 error_newtype 一致，0 是 __tag）
                            self.registerFieldId(bt.name, fname, @intCast(fi + 1));
                            // 用户源码字段名作为同义 field_id（便于 record_get(type, "msg") 查询）
                            self.registerFieldId(bt.name, f.name, @intCast(fi + 1));
                        }
                        self.registerFieldId(bt.name, "__tag", 0);
                        const ctors = try arena_alloc.alloc(CtorDefInfo, 1);
                        ctors[0] = .{
                            .name = bt.constructor_name,
                            .type_name = bt.name,
                            .field_names = field_names,
                            .field_type_descs = field_type_descs,
                            .field_type_names = field_type_names,
                        };
                        try sr.putTypeDef(.{
                            .name = bt.name,
                            .kind = .error_newtype,
                            .constructors = ctors,
                            .type_params = &.{},
                        });
                    },
                    .adt => {
                        // 关联 ADT（如 IOErrorKind / TimeErrorKind）：注册所有 unit constructor
                        const ctors = try arena_alloc.alloc(CtorDefInfo, bt.constructors.len);
                        for (bt.constructors, 0..) |con, i| {
                            ctors[i] = .{
                                .name = con,
                                .type_name = bt.name,
                                .field_names = &.{},
                                .field_type_descs = &.{},
                                .field_type_names = &.{},
                            };
                        }
                        self.registerFieldId(bt.name, "__tag", 0);
                        try sr.putTypeDef(.{
                            .name = bt.name,
                            .kind = .adt,
                            .constructors = ctors,
                            .type_params = &.{},
                        });
                    },
                }
            }
        }
    }

    /// 收集类型元数据（typeof 反射机制）
    ///
    /// 在 registerTypeDecl 中调用，为每个类型创建 TypeMetadata 条目。
    /// inner/target 的 type_id 引用在 build() 结束时通过 resolveTypeMetadataRefs 解析。
    /// 这样可以处理递归类型（如 type List<T> = | Nil | Cons(T, List<T>)）。
    pub fn collectTypeMetadata(self: *IRBuilder, td: anytype, arena_alloc: std.mem.Allocator) BuildError!void {
        // 判断 TypeKind 并构造 TypeStructure ADT
        var kind: TypeKind = .unit;
        var structure: TypeStructure = .unit;
        var inner_type_name: ?[]const u8 = null;
        var target_type_name: ?[]const u8 = null;

        switch (td.def) {
            .adt => |adt| {
                kind = .adt;
                // 收集构造器元信息
                const constructors = try arena_alloc.alloc(ConstructorMeta, adt.constructors.len);
                for (adt.constructors, 0..) |cdef, ci| {
                    const ctor_fields = try arena_alloc.alloc(FieldMeta, cdef.fields.len);
                    for (cdef.fields, 0..) |cf, fi| {
                        const fname = cf.name orelse try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                        ctor_fields[fi] = .{
                            .name = fname,
                            .type_name = try builder_mod.typeNameFromTypeNode(cf.ty, arena_alloc),
                            .is_nullable = builder_mod.isNullableTypeNode(cf.ty),
                            .index = @intCast(fi),
                        };
                    }
                    constructors[ci] = .{
                        .name = cdef.name,
                        .fields = ctor_fields,
                        .is_unit = cdef.fields.len == 0,
                        .index = @intCast(ci),
                    };
                }
                structure = .{ .adt = constructors };
            },
            .record => |r| {
                kind = .record;
                const fields = try arena_alloc.alloc(FieldMeta, r.fields.len);
                for (r.fields, 0..) |f, fi| {
                    fields[fi] = .{
                        .name = f.name,
                        .type_name = try builder_mod.typeNameFromTypeNode(f.ty, arena_alloc),
                        .is_nullable = builder_mod.isNullableTypeNode(f.ty),
                        .index = @intCast(fi),
                    };
                }
                structure = .{ .record = fields };
            },
            .newtype => |nt| {
                kind = .newtype;
                inner_type_name = try builder_mod.typeNameFromTypeNode(nt.inner, arena_alloc);
                // structure.newtype 是 inner 的 type_id（由 resolveTypeMetadataRefs 填充）
                // 此处先填 0，后续 resolveTypeMetadataRefs 会查 inner_type_name 设置正确 type_id
                structure = .{ .newtype = 0 };
            },
            .error_newtype => |en| {
                kind = .newtype;
                // Error newtype 也作为 newtype 处理
                // 内部 type_id 由 resolveTypeMetadataRefs 填充（用 error_newtype 自身的 type_id）
                _ = en;
                structure = .{ .newtype = 0 };
            },
            .alias => |a| {
                kind = .alias;
                target_type_name = try builder_mod.typeNameFromTypeNode(a.target, arena_alloc);
                structure = .{ .alias = 0 }; // 由 resolveTypeMetadataRefs 填充
            },
        }

        // alias: 记录到 pending_alias_targets 表，供 resolveTypeMetadataRefs 查询
        if (target_type_name) |tn| {
            try self.pending_alias_targets.put(self.arena.allocator(), td.name, tn);
        }
        // newtype: 记录 inner type name，供 resolveTypeMetadataRefs 查询
        if (inner_type_name) |tn| {
            try self.pending_alias_targets.put(self.arena.allocator(), td.name, tn);
        }

        // 收集类型参数元信息
        const type_params = try arena_alloc.alloc(TypeParamMeta, td.type_params.len);
        for (td.type_params, 0..) |tp, ti| {
            const constraints = try arena_alloc.alloc([]const u8, tp.bounds.len);
            for (tp.bounds, 0..) |b, bi| {
                constraints[bi] = b.trait_name;
            }
            type_params[ti] = .{
                .name = tp.name,
                .constraints = constraints,
                .is_specialized = false,
                .specialization = null,
            };
        }

        // 收集方法元信息
        const methods_meta = try arena_alloc.alloc(MethodMeta, td.methods.len);
        for (td.methods, 0..) |m, mi| {
            const param_types = try arena_alloc.alloc([]const u8, m.params.len);
            for (m.params, 0..) |p, pi| {
                param_types[pi] = if (p.type_annotation) |tn|
                    try builder_mod.typeNameFromTypeNode(tn, arena_alloc)
                else
                    "unknown";
            }
            const return_type = if (m.return_type) |rt|
                try builder_mod.typeNameFromTypeNode(rt, arena_alloc)
            else
                "void";
            methods_meta[mi] = .{
                .name = m.name,
                .signature = .{
                    .param_types = param_types,
                    .return_type = return_type,
                    .is_async = false,
                },
                .is_override = m.is_override,
                .is_delegate = m.delegate != null,
                .delegate_trait = if (m.delegate) |d| d.trait_name else null,
                .is_async = false,
            };
        }

        // 构造子结构：layout 初始为 {0, 0}（由 computeTypeLayout 填充）
        const layout = LayoutInfo{ .size = 0, .alignment = 0 };
        // 构造子结构：impls（Trait 实现信息）
        const impls = TraitImplInfo{
            .parent_traits = &.{},
            .implemented_traits = &.{},
            .methods = methods_meta,
            .associated_types = &.{},
        };

        const entry = TypeMetadata{
            .name = td.name,
            .module = "",
            .kind = kind,
            .structure = structure,
            .layout = layout,
            .impls = impls,
            .type_params = type_params,
        };
        try self.type_metadata_entries.append(self.arena.allocator(), entry);
        const type_id: u16 = @intCast(self.type_metadata_entries.items.len); // 1-indexed
        try self.type_name_to_id.put(self.arena.allocator(), td.name, type_id);
    }

    /// 解析 TypeMetadata 中 TypeStructure 的 type_id 引用
    ///
    /// 在所有类型注册完成后调用，处理递归类型引用。
    /// 处理：
    ///   - structure.newtype：Newtype 的 inner type_id（从 pending_alias_targets 取 inner type name）
    ///   - structure.alias：Alias 的 target type_id
    /// 未找到的类型保留 type_id = 0（运行时返回 null TypeInfo）。
    pub fn resolveTypeMetadataRefs(self: *IRBuilder) void {
        for (self.type_metadata_entries.items) |*entry| {
            switch (entry.structure) {
                .newtype => |*inner_id| {
                    // 从 pending_alias_targets 查 inner type name
                    if (self.pending_alias_targets.get(entry.name)) |inner_name| {
                        if (self.type_name_to_id.get(inner_name)) |tid| {
                            inner_id.* = tid;
                        }
                    }
                },
                .alias => |*target_id| {
                    if (self.pending_alias_targets.get(entry.name)) |target_name| {
                        if (self.type_name_to_id.get(target_name)) |tid| {
                            target_id.* = tid;
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// 计算所有 TypeMetadata 的 layout.size 和 layout.alignment（类型布局 pass）
    ///
    /// 在 resolveTypeMetadataRefs 之后调用，递归计算类型内存布局。
    /// 处理：
    ///   - 基础类型：i8→1, i16→2, i32→4, i64→8, i128→16, f16→2, f32→4, f64→8, f128→16
    ///   - bool→1, char→4, str→16 (ref 指针)
    ///   - Record：字段对齐 padding + 累加 size
    ///   - ADT：1 字节 tag + 最大构造器 size（含 padding 对齐到 tag 对齐）
    ///   - Newtype：inner type 的 size/alignment
    ///   - Alias：target type 的 size/alignment
    ///   - 递归类型：使用 ref 指针大小（8 字节，64-bit 系统）
    ///   - Trait/Func：指针大小（8 字节）
    pub fn computeTypeLayout(self: *IRBuilder) void {
        if (self.type_metadata_entries.items.len == 0) return;
        // 多次迭代直到收敛（处理递归类型的间接依赖）
        // 简单策略：迭代 N 次（N = 类型数量），每次处理未计算的类型
        const n = self.type_metadata_entries.items.len;
        var iteration: usize = 0;
        while (iteration < n + 1) : (iteration += 1) {
            var progress = false;
            for (self.type_metadata_entries.items) |*entry| {
                if (entry.layout.size != 0) continue; // 已计算
                const layout = self.computeLayoutForEntry(entry);
                if (layout) |l| {
                    entry.layout = l;
                    progress = true;
                }
            }
            if (!progress) break;
        }
    }

    /// 计算单个类型的布局
    /// 返回 null 表示依赖未解决（递归类型的间接引用未计算）
    pub fn computeLayoutForEntry(self: *IRBuilder, entry: *const TypeMetadata) ?LayoutInfo {
        switch (entry.structure) {
            .primitive => {
                // 基础类型：按名字判断大小
                const layout = builder_mod.primitiveLayout(entry.name) orelse return null;
                return .{ .size = layout.size, .alignment = layout.alignment };
            },
            .unit => return .{ .size = 0, .alignment = 1 },
            .record => |fields| {
                // 记录：累加字段 size，按最大对齐对齐
                var size: u32 = 0;
                var align_max: u32 = 1;
                for (fields) |f| {
                    const flayout = self.layoutOfTypeName(f.type_name) orelse return null;
                    // 对齐到字段对齐
                    size = builder_mod.alignUp(size, flayout.alignment);
                    size += flayout.size;
                    if (flayout.alignment > align_max) align_max = flayout.alignment;
                }
                // 总 size 对齐到最大对齐
                size = builder_mod.alignUp(size, align_max);
                return .{ .size = size, .alignment = align_max };
            },
            .adt => |constructors| {
                // ADT：1 字节 tag + 最大构造器 size
                var max_variant_size: u32 = 0;
                var align_max: u32 = 1;
                for (constructors) |ctor| {
                    var variant_size: u32 = 0;
                    var variant_align: u32 = 1;
                    for (ctor.fields) |f| {
                        const flayout = self.layoutOfTypeName(f.type_name) orelse return null;
                        variant_size = builder_mod.alignUp(variant_size, flayout.alignment);
                        variant_size += flayout.size;
                        if (flayout.alignment > variant_align) variant_align = flayout.alignment;
                    }
                    variant_size = builder_mod.alignUp(variant_size, variant_align);
                    if (variant_size > max_variant_size) max_variant_size = variant_size;
                    if (variant_align > align_max) align_max = variant_align;
                }
                // 总布局：tag (1B) + padding + variant
                const tag_size: u32 = 1;
                const total = builder_mod.alignUp(tag_size, align_max) + max_variant_size;
                return .{ .size = builder_mod.alignUp(total, align_max), .alignment = @max(align_max, 1) };
            },
            .newtype => |inner_id| {
                // Newtype：inner type 的布局
                // inner_id == 0：inner 是原始类型（i32/str/bool 等，未注册到 type_name_to_id）
                // 通过 pending_alias_targets 查 inner type name，再用 primitiveLayout 查布局
                if (inner_id == 0) {
                    if (self.pending_alias_targets.get(entry.name)) |inner_name| {
                        if (builder_mod.primitiveLayout(inner_name)) |pl| {
                            return .{ .size = pl.size, .alignment = pl.alignment };
                        }
                        // inner 是其他用户类型但未解析（如递归类型）→ null 等下一轮
                        if (self.type_name_to_id.get(inner_name) != null) return null;
                    }
                    return .{ .size = 0, .alignment = 1 };
                }
                if (inner_id <= self.type_metadata_entries.items.len) {
                    const inner = &self.type_metadata_entries.items[inner_id - 1];
                    if (inner.layout.size == 0) return null; // 依赖未计算
                    return .{ .size = inner.layout.size, .alignment = inner.layout.alignment };
                }
                return .{ .size = 0, .alignment = 1 };
            },
            .alias => |target_id| {
                // Alias：target type 的布局
                if (target_id == 0) {
                    // 未解析或基础类型别名
                    if (self.pending_alias_targets.get(entry.name)) |target_name| {
                        return self.layoutOfTypeName(target_name);
                    }
                    return .{ .size = 0, .alignment = 1 };
                }
                if (target_id <= self.type_metadata_entries.items.len) {
                    const target = &self.type_metadata_entries.items[target_id - 1];
                    if (target.layout.size == 0) return null; // 依赖未计算
                    return .{ .size = target.layout.size, .alignment = target.layout.alignment };
                }
                return .{ .size = 0, .alignment = 1 };
            },
            .func, .trait => {
                // 函数/Trait：指针大小（64-bit 假设 8 字节）
                return .{ .size = 8, .alignment = 8 };
            },
            .nullable => {
                // Nullable：指针大小（8 字节）
                return .{ .size = 8, .alignment = 8 };
            },
        }
    }

    /// 按类型名查询布局（递归查 TypeMetadata 或基础类型表）
    pub fn layoutOfTypeName(self: *IRBuilder, name: []const u8) ?LayoutInfo {
        // 基础类型快速路径
        if (builder_mod.primitiveLayout(name)) |l| return l;
        // nullable 类型：指针大小（8 字节）
        if (std.mem.endsWith(u8, name, "?")) {
            return .{ .size = 8, .alignment = 8 };
        }
        // 用户类型：查 type_metadata_entries
        if (self.type_name_to_id.get(name)) |tid| {
            if (tid <= self.type_metadata_entries.items.len) {
                const entry = &self.type_metadata_entries.items[tid - 1];
                if (entry.layout.size == 0) return null; // 递归类型未计算
                return .{ .size = entry.layout.size, .alignment = entry.layout.alignment };
            }
        }
        // 未识别：指针大小（可能是构造器引用，递归类型如 List）
        return .{ .size = 8, .alignment = 8 };
    }
    /// build() 中调用：解析引用后计算布局

    /// 查找类型 ID（typeof 编译时使用）
    ///
    /// 返回 1-indexed type_id；0 表示未找到（可能是泛型参数 T 或 Self）。
    /// 对于未找到的情况，IRBuilder 发出 meta_index=0 的 builtin_typeof，
    /// 引擎运行时通过类型参数上下文查表。
    pub fn lookupTypeId(self: *const IRBuilder, type_name: []const u8) u16 {
        return self.type_name_to_id.get(type_name) orelse 0;
    }
};
