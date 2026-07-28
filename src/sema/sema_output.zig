//! SemaResult：sema 的图构建元信息输出
//!
//! sema 从"检查器"升级为"图构建驱动器"，输出不再是"检查通过/失败"，
//! 而是图构建所需的全部元信息。设计参考：docs/glue-ir-design.md 第 4.2 节
//!
//! Phase 1：定义结构骨架，图构建器暂自行做简单类型推导（从字面量/运算符推导通道类型）。
//! 后续 Phase：sema 完成完整类型分析后填充此结构，图构建器从中读取类型/分派信息。
//!
//! v3 阶段 3：从 ir/ 迁入 sema/（设计文档 §5.1 要求）。
//! 依赖 ir 模块的 ConstVal/TypeDescriptor/CoroutineMeta（通过 @import("ir") 跨模块引用）。

const std = @import("std");
const ast = @import("ast");
const ir_mod = @import("ir");
const meta_mod = ir_mod.meta_mod;
const type_descriptor_mod = ir_mod.type_descriptor_mod;

pub const ConstVal = meta_mod.ConstVal;
pub const TypeDescriptor = type_descriptor_mod.TypeDescriptor;

/// 单个表达式的语义信息
pub const ExprInfo = struct {
    /// 表达式的类型描述符（决定通道宽度与读写 vtable）
    type_desc: *const TypeDescriptor,
    /// Nullable 内部类型描述符（type_desc.is_nullable 时有效）
    inner_type_desc: ?*const TypeDescriptor = null,
    /// 编译期常量值（若表达式是常量）
    const_val: ?ConstVal = null,
    /// 表达式的 AST 指针地址（用作 key）
    expr_id: u64 = 0,
    /// 表达式的类型名（若类型是 adt_type/generic_type，用于 IRBuilder 的 field_id 查找）
    /// 解决 method_call 返回值等场景下 inferTypeNameFromExpr 无法从 AST 回溯类型名的问题
    type_name: ?[]const u8 = null,
    /// true 表示表达式类型为 &T / *T，运行时应对 ref_chan 保持引用语义而不深拷贝
    is_ref_type: bool = false,
    /// 区分 &T(false) 与 *T(true)；仅 is_ref_type=true 时有效
    is_raw_ref: bool = false,
    /// 泛型实参的类型名列表（仅 generic_type 的方法调用/构造器调用有效）
    type_args: ?[]const []const u8 = null,
    /// 函数签名（仅对 callee 表达式有效，用于调用点推断返回类型）
    fn_sig: ?FnSigRef = null,
};

/// 类型定义种类
pub const TypeDefKind = enum {
    adt,
    record,
    alias,
    newtype,
    error_newtype,
};

/// 构造器定义信息（压平后的 sema AdtInfo 构造器）
pub const CtorDefInfo = struct {
    name: []const u8,
    type_name: []const u8,
    field_names: []const ?[]const u8,
    field_type_descs: []const *const TypeDescriptor,
    field_type_names: []const ?[]const u8,
    is_newtype: bool = false,
    /// GADT 构造器返回类型名（仅 GADT 有效）
    return_type_name: ?[]const u8 = null,
    /// GADT 构造器返回类型 TypeNode（仅 GADT 有效，消除 IR 侧 AST 回退）
    return_type_node: ?*const ast.TypeNode = null,
    /// 构造器字段的 TypeNode（消除 IR 侧 AST 回退）
    /// 长度与 field_names 一致，无类型信息的字段为 null
    field_type_nodes: []const ?*const ast.TypeNode = &.{},
};

/// 类型定义信息（替代 IRBuilder 的 type_table + ctor_table）
pub const TypeDefInfo = struct {
    name: []const u8,
    kind: TypeDefKind,
    /// adt/newtype/error_newtype：构造器列表
    /// record：constructors[0] 存字段（name == type_name）
    /// alias：空切片
    constructors: []const CtorDefInfo,
    type_params: []const []const u8,
    /// 仅 alias/newtype：目标类型名
    target_type_name: ?[]const u8 = null,
    /// 仅 alias/newtype：目标类型描述符
    target_type_desc: ?*const TypeDescriptor = null,
};

/// Trait 方法签名（压平后的 sema TraitInfo 方法）
pub const TraitMethodSig = struct {
    name: []const u8,
    param_count: u8,
    return_type_desc: *const TypeDescriptor,
    is_async: bool = false,
    /// 是否有 default 实现体（IRBuilder 据此决定是否从 AST 取 body）
    has_body: bool,
};

/// Trait 定义信息（替代 IRBuilder 的 trait_table 签名部分）
pub const TraitDefInfo = struct {
    name: []const u8,
    methods: []const TraitMethodSig,
};

/// 函数签名引用（嵌入 ExprInfo，仅对 callee 表达式有效）
pub const FnSigRef = struct {
    param_type_descs: []const *const TypeDescriptor,
    return_type_desc: *const TypeDescriptor,
    is_async: bool = false,
    is_throwing: bool = false,
};

/// 函数签名信息（替代 IRBuilder 的 func_generic_info）
pub const FuncSigInfo = struct {
    /// 函数名或 mangled 名（TypeName.method）
    name: []const u8,
    type_params: []const []const u8,
    param_type_descs: []const *const TypeDescriptor,
    return_type_desc: *const TypeDescriptor,
    /// 每个参数是否为 &T 引用语义
    param_is_ref: []const bool,
    return_is_ref: bool = false,
    is_async: bool = false,
    is_throwing: bool = false,
    /// 参数类型名（消除 IR 侧 findFuncParamsAst AST 回退）
    /// 用于判断参数是否为 trait 类型（配合 getTraitDef 查询）
    /// null 表示该参数无类型注解或类型推断产生
    param_type_names: []const ?[]const u8 = &.{},
};

/// Import 别名目标（区分模块引用和符号引用）
pub const AliasTarget = union(enum) {
    /// 模块短名 → 完整模块路径
    /// import std.time.Calendar → "Calendar" → .{ .module = "std.time.Calendar" }
    /// import std.time { Calendar } → "Calendar" → .{ .module = "std.time.Calendar" }
    /// 类型即模块：import std.time.DateTime → "DateTime" → .{ .module = "std.time.DateTime" }
    module: []const u8,
    /// 函数/常量短名 → mangled 名
    /// import std.time.Calendar { is_leap_year } → "is_leap_year" → .{ .symbol = "std.time.Calendar.is_leap_year" }
    /// import std.time.Calendar { is_leap_year as ily } → "ily" → .{ .symbol = "std.time.Calendar.is_leap_year" }
    symbol: []const u8,
};

// ════════════════════════════════════════════════════════════════
// v3 新增：单态化 / TypeDescriptor / 反射元信息类型
// ════════════════════════════════════════════════════════════════

/// 单态化实例（一个泛型函数 + 一组 type_args → 一个实例）
pub const MonomorphInstance = struct {
    instance_id: u32,
    func_name: []const u8,
    type_args: []const TypeDescriptor,
    chan_layout: ChanLayout,
    return_type: *const TypeDescriptor,
    is_async: bool,
    /// 实例本地表达式类型表（key = AST Expr 指针地址）
    /// 用具体 type_args 解析函数体内所有表达式的类型，解决泛型字段访问的类型解析
    /// IRBuilder 编译实例体时优先从此表查询，回退到全局 sema_result.expr_types
    expr_types: std.AutoHashMap(u64, ExprInfo) = undefined,
    /// 字段访问元信息（key = AST field_access Expr 指针地址）
    /// 用具体 type_args 解析字段类型，替代 IRBuilder 的 inferFieldType
    field_accesses: std.AutoHashMap(u64, FieldAccessInfo) = undefined,
};

/// 通道布局（单态化实例的通道分配方案）
pub const ChanLayout = struct {
    local_chan_count: u16,
    return_channel: u16,
    local_offsets: []const u32,
    chan_type_descs: []const *const TypeDescriptor,
    chan_total_bytes: u32,
};

/// 字段访问元信息（运行时分派 field_id 查找）
pub const FieldAccessInfo = struct {
    obj_type_desc: *const TypeDescriptor,
    field_idx: u16,
    field_type_desc: *const TypeDescriptor,
};

/// 方法分派元信息（trait 方法 → 具体 impl 函数）
pub const DispatchInfo = struct {
    trait_id: u16,
    method_idx: u16,
    impl_fn_idx: u16,
    /// v3 阶段 1：泛型方法调用的单态化实例 ID（非泛型为 0）
    /// 最佳努力匹配时暂存 instance_id，完整 trait 解析后由 impl_fn_idx 取代
    instance_id: u32 = 0,
};

/// typeof 已解析元信息
pub const TypeofMeta = struct {
    type_desc: *const TypeDescriptor,
};

/// reflect 已解析元信息
pub const ReflectMeta = struct {
    type_desc: *const TypeDescriptor,
};

/// sema 产出的图构建元信息
///
/// Phase 1 仅定义结构，图构建器暂不依赖此结构。
/// 后续 Phase 由 sema 填充，图构建器读取。
pub const SemaResult = struct {
    allocator: std.mem.Allocator,
    /// 表达式 → 类型信息（决定通道宽度）
    /// key = AST 表达式指针地址，value = ExprInfo
    expr_types: std.AutoHashMap(u64, ExprInfo),
    /// 编译期错误
    errors: std.ArrayList(SemaError),
    /// 是否有错误
    has_error: bool = false,
    /// 类型定义表（替代 IRBuilder 的 type_table + ctor_table）
    type_defs: std.ArrayList(TypeDefInfo),
    /// 类型名 → type_defs 索引
    type_def_index: std.StringHashMap(u16),
    /// Trait 定义表（替代 IRBuilder 的 trait_table 签名部分）
    trait_defs: std.ArrayList(TraitDefInfo),
    /// Trait 名 → trait_defs 索引
    trait_def_index: std.StringHashMap(u16),
    /// 函数签名表（替代 IRBuilder 的 func_generic_info）
    func_sigs: std.ArrayList(FuncSigInfo),
    /// 函数名 → func_sigs 索引
    func_sig_index: std.StringHashMap(u16),
    /// 协程元数据表（async 函数状态机变换产物，阶段 1）
    coroutine_metas: std.ArrayList(meta_mod.CoroutineMeta) = .empty,
    /// 构造器名 → (type_def_index << 16 | ctor_index)
    ctor_def_index: std.StringHashMap(u32),
    /// import 别名表：短名 → 别名目标
    /// 由 sema 阶段的 buildImportAliases 填充，IRBuilder 读取后构建 module_alias_map 和 symbol_alias_map
    import_aliases: std.StringHashMap(AliasTarget),
    /// 从 TypeInferencer 转移而来的 arena 所有权。
    /// sema_result 中的 type_name / field_chan_types / constructors 等切片
    /// 引用了 inferencer arena 分配的 Type 结构体内存，因此 arena 必须与
    /// sema_result 同生命周期。inferencer.deinit() 时若 sema_result 非空，
    /// 将 arena 所有权转移至此字段，由 sema_result.deinit() 统一释放。
    owned_arena: ?std.heap.ArenaAllocator = null,

    // v3 新增：单态化实例表
    monomorph_instances: std.ArrayList(MonomorphInstance) = .empty,
    monomorph_index: std.StringHashMap(u32),
    // v3 新增：全局 TypeDescriptor 表
    type_descriptors: std.ArrayList(TypeDescriptor) = .empty,
    // 废除 ref_chan：动态类型描述符池，为每个用户类型创建具体引用描述符
    type_desc_pool: type_descriptor_mod.TypeDescriptorPool = undefined,
    // v3 新增：调用点 → 实例映射
    call_instantiations: std.AutoHashMap(u64, u32),
    // v3 新增：字段访问/方法分派元信息
    field_accesses: std.AutoHashMap(u64, FieldAccessInfo),
    method_dispatches: std.AutoHashMap(u64, DispatchInfo),
    // v3 新增：typeof/reflect 已解析元信息（无哨兵）
    typeof_metas: std.AutoHashMap(u64, TypeofMeta),
    reflect_metas: std.AutoHashMap(u64, ReflectMeta),
    resolved_type_descs: std.AutoHashMap(u64, *const TypeDescriptor),
    // v3 新增：字段 ID 映射（key = "type_name\x00field_name" → field_id）
    /// ADT/newtype/error_newtype: __tag=0, 字段从 1 开始
    /// Record: 字段按声明顺序 0..N-1
    /// 由 putTypeDef 自动填充，IRBuilder 从此查询（不再自建 field_id_map）
    field_id_map: std.StringHashMap(u16),

    pub fn init(allocator: std.mem.Allocator) SemaResult {
        return .{
            .allocator = allocator,
            .expr_types = std.AutoHashMap(u64, ExprInfo).init(allocator),
            .errors = .empty,
            .type_defs = .empty,
            .type_def_index = std.StringHashMap(u16).init(allocator),
            .trait_defs = .empty,
            .trait_def_index = std.StringHashMap(u16).init(allocator),
            .func_sigs = .empty,
            .func_sig_index = std.StringHashMap(u16).init(allocator),
            .ctor_def_index = std.StringHashMap(u32).init(allocator),
            .import_aliases = std.StringHashMap(AliasTarget).init(allocator),
            .monomorph_index = std.StringHashMap(u32).init(allocator),
            .call_instantiations = std.AutoHashMap(u64, u32).init(allocator),
            .field_accesses = std.AutoHashMap(u64, FieldAccessInfo).init(allocator),
            .method_dispatches = std.AutoHashMap(u64, DispatchInfo).init(allocator),
            .typeof_metas = std.AutoHashMap(u64, TypeofMeta).init(allocator),
            .reflect_metas = std.AutoHashMap(u64, ReflectMeta).init(allocator),
            .resolved_type_descs = std.AutoHashMap(u64, *const TypeDescriptor).init(allocator),
            .field_id_map = std.StringHashMap(u16).init(allocator),
            .type_desc_pool = type_descriptor_mod.TypeDescriptorPool.init(allocator),
        };
    }

    pub fn deinit(self: *SemaResult) void {
        self.expr_types.deinit();
        self.errors.deinit(self.allocator);
        self.type_defs.deinit(self.allocator);
        self.type_def_index.deinit();
        self.trait_defs.deinit(self.allocator);
        self.trait_def_index.deinit();
        self.func_sigs.deinit(self.allocator);
        self.func_sig_index.deinit();
        self.coroutine_metas.deinit(self.allocator);
        self.ctor_def_index.deinit();
        self.import_aliases.deinit();
        // 释放每个实例的本地 expr_types 和 field_accesses（必须在 monomorph_instances.deinit 前执行，
        // 因为 deinit 会释放 items 数组内存）
        for (self.monomorph_instances.items) |*inst| {
            inst.expr_types.deinit();
            inst.field_accesses.deinit();
        }
        self.monomorph_instances.deinit(self.allocator);
        self.monomorph_index.deinit();
        self.type_descriptors.deinit(self.allocator);
        self.type_desc_pool.deinit();
        self.call_instantiations.deinit();
        self.field_accesses.deinit();
        self.method_dispatches.deinit();
        self.typeof_metas.deinit();
        self.reflect_metas.deinit();
        self.resolved_type_descs.deinit();
        // field_id_map 的 key 由 putFieldId 用 self.allocator 分配，需手动释放
        var it = self.field_id_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.field_id_map.deinit();
        if (self.owned_arena) |*arena| {
            arena.deinit();
            self.owned_arena = null;
        }
    }

    /// 将 type_desc_pool 所有权转移给调用方（IRBuilder.build 成功后调用）。
    /// 转移后 sema_result 持有一个新的空 pool，deinit 不会释放已转移的描述符。
    /// GlueIR.channels 中的 type_desc 指针引用此 pool 分配的内存，
    /// 因此 pool 必须与 GlueIR 同生命周期。
    pub fn takeTypeDescPool(self: *SemaResult) type_descriptor_mod.TypeDescriptorPool {
        const pool = self.type_desc_pool;
        self.type_desc_pool = type_descriptor_mod.TypeDescriptorPool.init(self.allocator);
        return pool;
    }

    /// 记录表达式类型
    pub fn putExpr(self: *SemaResult, expr_id: u64, info: ExprInfo) !void {
        try self.expr_types.put(expr_id, info);
    }

    /// 查询表达式类型
    pub fn getExpr(self: *const SemaResult, expr_id: u64) ?ExprInfo {
        return self.expr_types.get(expr_id);
    }

    /// 获取或创建具名引用类型描述符（废除 ref_chan：每个类型有独立 type_id/type_name）
    /// str → str_descriptor (type_id=19)；用户类型 → 动态分配 (type_id=20+)
    pub fn getOrCreateRefDesc(self: *SemaResult, name: []const u8) !*const TypeDescriptor {
        // str 使用静态描述符（type_id=19）
        if (std.mem.eql(u8, name, "str")) return type_descriptor_mod.str_descriptor;
        return self.type_desc_pool.getOrCreateRefDesc(name);
    }

    /// 注册 import 别名（检测重复）
    pub fn putImportAlias(self: *SemaResult, short_name: []const u8, target: AliasTarget) !void {
        if (self.import_aliases.contains(short_name)) {
            return error.DuplicateImportAlias;
        }
        try self.import_aliases.put(short_name, target);
    }

    /// 查询 import 别名
    pub fn getImportAlias(self: *const SemaResult, short_name: []const u8) ?AliasTarget {
        return self.import_aliases.get(short_name);
    }

    /// 记录错误
    pub fn addError(self: *SemaResult, err: SemaError) !void {
        self.has_error = true;
        try self.errors.append(self.allocator, err);
    }

    /// 添加类型定义并注册 type_def_index 和 ctor_def_index
    /// 同时自动填充 field_id_map（ADT: __tag=0 + 字段从 1 开始；Record: 字段从 0 开始）
    pub fn putTypeDef(self: *SemaResult, def: TypeDefInfo) !void {
        const idx: u16 = @intCast(self.type_defs.items.len);
        try self.type_defs.append(self.allocator, def);
        try self.type_def_index.put(def.name, idx);
        for (def.constructors, 0..) |ctor, ci| {
            const packed_idx: u32 = (@as(u32, idx) << 16) | @as(u32, @intCast(ci));
            try self.ctor_def_index.put(ctor.name, packed_idx);
        }
        // 自动填充 field_id_map
        try self.populateFieldIds(def);
    }

    /// 按 type_def 的 kind 规则填充 field_id_map
    /// - adt/newtype/error_newtype: __tag=0, 字段从 1 开始
    /// - record: 字段按声明顺序 0..N-1
    /// - alias: 无字段
    fn populateFieldIds(self: *SemaResult, def: TypeDefInfo) !void {
        switch (def.kind) {
            .adt => {
                // ADT 多构造器：每个构造器的字段独立编号（__tag=0 + 字段从 1 开始）
                // field_id_map 的 key 是 "type_name\x00field_name"，同名字段跨构造器共享 field_id
                for (def.constructors) |ctor| {
                    for (ctor.field_names, 0..) |fname, fi| {
                        const name = fname orelse continue;
                        const field_id: u16 = @intCast(fi + 1);
                        try self.putFieldId(def.name, name, field_id);
                    }
                }
                // __tag 字段（field_id=0）
                try self.putFieldId(def.name, "__tag", 0);
            },
            .newtype, .error_newtype => {
                // 单构造器：__tag=0, 字段从 1 开始
                for (def.constructors) |ctor| {
                    for (ctor.field_names, 0..) |fname, fi| {
                        const name = fname orelse {
                            // 位置字段（_0）：用位置名
                            const positional = try std.fmt.allocPrint(self.allocator, "_{d}", .{fi});
                            const field_id: u16 = @intCast(fi + 1);
                            try self.putFieldId(def.name, positional, field_id);
                            continue;
                        };
                        const field_id: u16 = @intCast(fi + 1);
                        try self.putFieldId(def.name, name, field_id);
                    }
                }
                try self.putFieldId(def.name, "__tag", 0);
            },
            .record => {
                // Record：字段按声明顺序 0..N-1
                if (def.constructors.len > 0) {
                    for (def.constructors[0].field_names, 0..) |fname, fi| {
                        const name = fname orelse continue;
                        const field_id: u16 = @intCast(fi);
                        try self.putFieldId(def.name, name, field_id);
                    }
                }
            },
            .alias => {},
        }
    }

    /// 构造 field_id_map 的 key 并插入（已存在则覆盖）
    fn putFieldId(self: *SemaResult, type_name: []const u8, field_name: []const u8, field_id: u16) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ type_name, field_name });
        try self.field_id_map.put(key, field_id);
    }

    /// 查询 field_id（找不到返回 null）
    /// key = "type_name\x00field_name"
    pub fn lookupFieldId(self: *const SemaResult, type_name: []const u8, field_name: []const u8) ?u16 {
        var key_buf: [256]u8 = undefined;
        const total_len = type_name.len + 1 + field_name.len;
        if (total_len > key_buf.len) {
            const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ type_name, field_name }) catch return null;
            defer self.allocator.free(key);
            return self.field_id_map.get(key);
        }
        @memcpy(key_buf[0..type_name.len], type_name);
        key_buf[type_name.len] = 0;
        @memcpy(key_buf[type_name.len + 1 .. total_len], field_name);
        return self.field_id_map.get(key_buf[0..total_len]);
    }

    /// 按名查询类型定义
    pub fn getTypeDef(self: *const SemaResult, name: []const u8) ?TypeDefInfo {
        const idx = self.type_def_index.get(name) orelse return null;
        return self.type_defs.items[idx];
    }

    /// 按构造器名查询构造器定义
    pub fn getCtorDef(self: *const SemaResult, name: []const u8) ?CtorDefInfo {
        const packed_idx = self.ctor_def_index.get(name) orelse return null;
        const type_idx: u16 = @intCast(packed_idx >> 16);
        const ctor_idx: u16 = @intCast(packed_idx & 0xFFFF);
        const def = self.type_defs.items[type_idx];
        return def.constructors[ctor_idx];
    }

    /// 添加 trait 定义并注册索引
    pub fn putTraitDef(self: *SemaResult, def: TraitDefInfo) !void {
        const idx: u16 = @intCast(self.trait_defs.items.len);
        try self.trait_defs.append(self.allocator, def);
        try self.trait_def_index.put(def.name, idx);
    }

    /// 按名查询 trait 定义
    pub fn getTraitDef(self: *const SemaResult, name: []const u8) ?TraitDefInfo {
        const idx = self.trait_def_index.get(name) orelse return null;
        return self.trait_defs.items[idx];
    }

    /// 添加函数签名并注册索引
    pub fn putFuncSig(self: *SemaResult, sig: FuncSigInfo) !void {
        const idx: u16 = @intCast(self.func_sigs.items.len);
        try self.func_sigs.append(self.allocator, sig);
        try self.func_sig_index.put(sig.name, idx);
    }

    /// 按名查询函数签名
    pub fn getFuncSig(self: *const SemaResult, name: []const u8) ?FuncSigInfo {
        const idx = self.func_sig_index.get(name) orelse return null;
        return self.func_sigs.items[idx];
    }

    /// 添加协程元数据
    pub fn putCoroutineMeta(self: *SemaResult, meta: meta_mod.CoroutineMeta) !void {
        try self.coroutine_metas.append(self.allocator, meta);
    }

    /// 按 func_idx 查询协程元数据
    pub fn getCoroutineMetaByFuncIdx(self: *const SemaResult, func_idx: u16) ?*const meta_mod.CoroutineMeta {
        for (self.coroutine_metas.items) |*m| {
            if (m.func_idx == func_idx) return m;
        }
        return null;
    }
};

/// 语义错误
pub const SemaError = struct {
    message: []const u8,
    line: u32 = 0,
    column: u32 = 0,
};


