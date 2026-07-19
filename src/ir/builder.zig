//! Glue IR 图构建器
//!
//! 从 AST 构建 GlueIR（共享内存图）。这是前端（parse + sema）的核心产物。
//! 设计参考：docs/glue-ir-design.md 第 4 章前端设计
//!
//! Phase 1 覆盖：
//!   - 标量表达式：字面量、变量、算术、位运算、比较、一元
//!   - 基础控制流：block、val/var 声明、return、函数调用
//! 后续 Phase：if/match（vec_select）、for/while（vec_source/map）、? 传播（gate）等

const std = @import("std");
const ast = @import("ast");
const scalar = @import("value").scalar;
const glue_builtin = @import("glue_builtin");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const ir_mod = @import("ir.zig");
const sema_output_mod = @import("sema_output.zig");
const analysis_db_mod = @import("analysis_db");

/// sema 产出的表达式类型映射契约（驱动式接入：sema 填充、builder 消费）
const SemaResult = sema_output_mod.SemaResult;

pub const Node = node_mod.Node;
pub const NodeOp = node_mod.NodeOp;
pub const ScalarMeta = meta_mod.ScalarMeta;
pub const ScalarKind = meta_mod.ScalarKind;
pub const ConstVal = meta_mod.ConstVal;
pub const CallMeta = meta_mod.CallMeta;
pub const Function = meta_mod.Function;
pub const VectorMeta = meta_mod.VectorMeta;
pub const VecOp = meta_mod.VecOp;
pub const GateMeta = meta_mod.GateMeta;
pub const GateKind = meta_mod.GateKind;
pub const RouteMeta = meta_mod.RouteMeta;
pub const RaceMeta = meta_mod.RaceMeta;
pub const CleanupMeta = meta_mod.CleanupMeta;
pub const OrbitMeta = meta_mod.OrbitMeta;
pub const LoopMeta = meta_mod.LoopMeta;
pub const ClosureMeta = meta_mod.ClosureMeta;
pub const LoopKind = meta_mod.LoopKind;
pub const HaltKind = meta_mod.HaltKind;
pub const TypeMetadata = meta_mod.TypeMetadata;
pub const TypeMetadataTable = meta_mod.TypeMetadataTable;
pub const TypeKind = meta_mod.TypeKind;
pub const TypeStructure = meta_mod.TypeStructure;
pub const LayoutInfo = meta_mod.LayoutInfo;
pub const TraitImplInfo = meta_mod.TraitImplInfo;
pub const FieldMeta = meta_mod.FieldMeta;
pub const ConstructorMeta = meta_mod.ConstructorMeta;
pub const TypeParamMeta = meta_mod.TypeParamMeta;
pub const MethodMeta = meta_mod.MethodMeta;
pub const FuncSigMeta = meta_mod.FuncSigMeta;
pub const TraitMeta = meta_mod.TraitMeta;
pub const AssociatedTypeMeta = meta_mod.AssociatedTypeMeta;
pub const ChanType = channel_mod.ChanType;
pub const ChannelSpace = channel_mod.ChannelSpace;
pub const GlueIR = ir_mod.GlueIR;
pub const IntKind = scalar.IntKind;
pub const FloatKind = scalar.FloatKind;

/// 图构建错误
pub const BuildError = error{
    OutOfMemory,
    UnsupportedExpr,
    UnsupportedStmt,
    UnsupportedDecl,
    UnsupportedType,
    InvalidLiteral,
    UnboundVariable,
    UndefinedFunction,
};

/// 变量绑定
const VarBinding = struct {
    name: []const u8,
    chan: u16, // 通道索引
    is_cell: bool, // var 变量是 Cell（可变）
    ast_expr: ?*const ast.Expr = null, // 用于类型推断的 AST 表达式
    type_annotation: ?*ast.TypeNode = null, // 类型标注（函数参数/val/var 声明）
};

/// 作用域
const Scope = struct {
    bindings: std.ArrayList(VarBinding),
};

/// 构造器字段信息
const CtorField = struct {
    name: []const u8, // 位置参数合成名 _0, _1, ...；命名字段用原名
    type_node: ?*ast.TypeNode,
};

/// 构造器信息
const CtorInfo = struct {
    name: []const u8, // 构造器名
    type_name: []const u8, // 所属类型名
    tag: u8, // 在类型构造器列表中的索引（用于 match 分派）
    fields: []const CtorField, // 字段列表
    is_newtype: bool = false, // 是否为 newtype 构造器
    return_type: ?*ast.TypeNode = null, // GADT 构造器返回类型注解（如 Expr<i32>）
};

/// 类型信息
const TypeInfo = struct {
    name: []const u8,
    kind: enum { adt, record, alias, newtype, error_newtype },
    constructors: []const CtorInfo, // ADT/newtype 的构造器列表
    type_params: []const ast.TypeParam = &.{}, // 类型参数列表（用于非 GADT 泛型类型的类型推断）
};

/// Trait 方法签名
const TraitMethodSig = struct {
    name: []const u8,
    param_count: u8,
    return_type: ?*ast.TypeNode,
    body: ?*ast.Expr = null,
    params: []const ast.Param = &.{},
};

/// Trait 信息
const TraitInfo = struct {
    name: []const u8,
    methods: []const TraitMethodSig,
};

/// 函数泛型信息：用于泛型函数调用的类型推断
const FuncGenericInfo = struct {
    type_params: []const ast.TypeParam,
    params: []const ast.Param,
    return_type: ?*ast.TypeNode,
};

/// 特化符号表：并行数组存储 key/value，线性查找
/// 适用于 build 期小规模（<256）符号表，内存连续 cache 友好，无哈希开销
/// put 时若 key 已存在则更新值（覆盖语义，与 StringHashMap 一致）
fn SymTable(comptime V: type) type {
    return struct {
        keys: std.ArrayList([]const u8) = .empty,
        values: std.ArrayList(V) = .empty,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.keys.deinit(self.allocator);
            self.values.deinit(self.allocator);
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            for (self.keys.items, self.values.items) |k, v| {
                if (std.mem.eql(u8, k, key)) return v;
            }
            return null;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.get(key) != null;
        }

        pub fn put(self: *Self, key: []const u8, value: V) !void {
            for (self.keys.items, self.values.items) |k, *v| {
                if (std.mem.eql(u8, k, key)) {
                    v.* = value;
                    return;
                }
            }
            try self.keys.append(self.allocator, key);
            try self.values.append(self.allocator, value);
        }
    };
}

/// 线性递归信息：识别 fib(n) = fib(n-1) op fib(n-2) 模式
/// 转换为 vec_scan 式迭代，O(2^N) → O(N) 且 O(1) dispatch
const LinearRecurrenceInfo = struct {
    op: NodeOp, // 递归运算（int_add / int_mul / int_and / int_or / int_xor）
    init_a: i64, // 状态 a 初值（= f(0)）
    init_b: i64, // 状态 b 初值（= f(1)）
    elem_type: ChanType, // 运算元素类型
};

/// IR 构建器：从 AST 构建 GlueIR
pub const IRBuilder = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    nodes: std.ArrayList(Node),
    scalar_metas: std.ArrayList(ScalarMeta),
    call_metas: std.ArrayList(CallMeta),
    vector_metas: std.ArrayList(VectorMeta),
    gate_metas: std.ArrayList(GateMeta),
    route_metas: std.ArrayList(RouteMeta),
    race_metas: std.ArrayList(RaceMeta),
    cleanup_metas: std.ArrayList(CleanupMeta),
    orbit_metas: std.ArrayList(OrbitMeta),
    loop_metas: std.ArrayList(LoopMeta),
    closure_metas: std.ArrayList(ClosureMeta),
    functions: std.ArrayList(Function),
    string_pool: std.ArrayList([]const u8),
    channels: ChannelSpace,

    scope_stack: std.ArrayList(Scope),
    func_table: SymTable(u16), // 函数名 -> 函数索引
    type_table: std.StringHashMap(TypeInfo), // 类型名 -> 类型信息
    ctor_table: std.StringHashMap(CtorInfo), // 构造器名 -> 构造器信息
    trait_table: std.StringHashMap(TraitInfo), // trait 名 -> trait 信息
    func_returns_str: std.StringHashMap(void), // 返回 str 的函数名集合
    func_generic_info: std.StringHashMap(FuncGenericInfo), // 函数名 -> 泛型信息（用于类型推断）
    lambda_returns_throw: std.StringHashMap(void), // 返回 Throw 的 lambda 变量名集合（跨作用域持久）
    imported_modules: std.StringHashMap(void), // 已导入的顶层模块名集合（用于模块引用识别）
    /// 字段名 → field_id 映射：key = "type_name\x00field_name"，value = field_id
    /// ADT/newtype/error_newtype：__tag=0，字段从 1 开始
    /// Record literal：字段按声明顺序 0..N-1
    field_id_map: std.StringHashMap(u16),
    /// 线性递归识别：函数名 → LinearRecurrenceInfo
    linear_rec_map: std.StringHashMap(LinearRecurrenceInfo),

    current_return_chan: ?u16 = null,
    /// 当前编译的表达式是否在尾位置（用于标记 tail_call）
    in_tail_position: bool = false,
    /// 当前函数返回类型是否为 Throw<T, E>（决定是否需要包装返回值为 ThrowValue）
    current_returns_throw: bool = false,
    /// 当前函数 Throw<T, E> 返回类型的 Ok 值通道类型（用于 ? 传播提取 Ok 值）
    current_throw_ok_chan_type: ChanType = .i64_chan,
    /// 当前编译的方法所属类型名（用于 self 的类型推断）
    current_type_context: ?[]const u8 = null,
    /// GADT 类型绑定栈：match arm 内的类型参数绑定（如 T → i32_chan）
    /// 每个 match arm 压入一个绑定表，arm 结束后弹出
    gadt_binding_stack: std.ArrayList(std.StringHashMap(ChanType)) = .empty,
    /// 当前函数名（用于判断递归调用）
    current_func_name: ?[]const u8 = null,
    /// 当前函数的参数类型注解（用于 GADT 类型推断）
    current_func_param_types: ?[]const ast.Param = null,
    /// 当前函数的类型参数（用于 typeof(T) 哨兵发射）
    current_func_type_params: ?[]const ast.TypeParam = null,
    /// 当前 trait default 方法中的 Self 类型名（用于 typeof(Self) 解析）
    current_self_type_name: ?[]const u8 = null,
    /// 当前模式绑定的类型提示（从构造器字段类型继承）
    pattern_type_hint: ?*ast.TypeNode = null,
    /// lambda 计数器（生成匿名函数名 __lambda_N）
    lambda_counter: u32 = 0,
    /// 预声明 lambda 名栈（支持递归 lambda：val go = fun(...) { go(...) }）
    /// 在 val_decl 编译 lambda 前 push 名字，compileLambda 读取并预绑定到输出通道
    pre_declared_lambda_names: std.ArrayList([]const u8) = .empty,
    /// arena 所有权标志：build() 成功后转交给 GlueIR，置为 false
    arena_owned: bool = true,
    /// sema 输出契约（驱动式接入）：若非 null，inferChanTypeFromExpr 优先从此处
    /// 查询表达式类型，fallback 到自建推导。所有权归调用方，build 期间不得释放。
    sema_result: ?*const SemaResult = null,
    /// 纯度表（驱动式接入）：若非 null，compileCall 查询函数纯度决定是否分配 memo_slot。
    /// 所有权归调用方，build 期间不得释放。
    purity_db: ?*const analysis_db_mod.PurityTable = null,
    /// memo_slot 分配计数器（0 保留为"不缓存"，从 1 开始递增）
    memo_slot_counter: u16 = 1,
    /// 函数名 → memo_slot 映射（纯函数首次调用分配，后续相同函数复用同一 slot）
    func_memo_slots: std.StringHashMapUnmanaged(u16) = .empty,
    /// TypeMetadata 条目收集（typeof 反射机制）：1-indexed，type_id = index + 1
    /// 在 registerTypeDecl 中收集，build() 完成时转交给 GlueIR.type_metadata_table
    type_metadata_entries: std.ArrayList(TypeMetadata) = .empty,
    /// 类型名 → type_id 映射（1-indexed，0 = 未找到/泛型参数）
    /// typeof 编译时查找：具体类型返回 type_id，泛型参数返回 0（运行时查表）
    type_name_to_id: std.StringHashMapUnmanaged(u16) = .empty,
    /// Alias 类型名 → target 类型名（resolveTypeMetadataRefs 使用，处理递归）
    pending_alias_targets: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// 初始化构建器
    pub fn init(allocator: std.mem.Allocator) !IRBuilder {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var builder = IRBuilder{
            .allocator = allocator,
            .arena = arena,
            .nodes = .empty,
            .scalar_metas = .empty,
            .call_metas = .empty,
            .vector_metas = .empty,
            .gate_metas = .empty,
            .route_metas = .empty,
            .race_metas = .empty,
            .cleanup_metas = .empty,
            .orbit_metas = .empty,
            .loop_metas = .empty,
            .closure_metas = .empty,
            .functions = .empty,
            .string_pool = .empty,
            .channels = ChannelSpace.init(arena.allocator()),
            .scope_stack = .empty,
            .func_table = SymTable(u16).init(allocator),
            .type_table = std.StringHashMap(TypeInfo).init(allocator),
            .ctor_table = std.StringHashMap(CtorInfo).init(allocator),
            .trait_table = std.StringHashMap(TraitInfo).init(allocator),
            .func_returns_str = std.StringHashMap(void).init(allocator),
            .func_generic_info = std.StringHashMap(FuncGenericInfo).init(allocator),
            .lambda_returns_throw = std.StringHashMap(void).init(allocator),
            .imported_modules = std.StringHashMap(void).init(allocator),
            .field_id_map = std.StringHashMap(u16).init(allocator),
            .linear_rec_map = std.StringHashMap(LinearRecurrenceInfo).init(allocator),
        };
        // meta_index=0 保留为"无元数据"占位
        try builder.scalar_metas.append(arena.allocator(), .{ .kind = .unit });
        // 注册 TypeInfo 反射类型的 field_id（0-indexed，无 __tag）
        try builder.registerTypeInfoFields();
        return builder;
    }

    /// 注册 TypeInfo 类型的 field_id 映射（反射机制）
    ///
    /// TypeInfo 是 builtin typeof 的返回类型，包含 7 个顶层字段。
    /// 字段顺序与 meta.TypeMetadata 字段定义保持一致（0-indexed）。
    /// 工作原理：info.name → record_get(info, field_id=0)
    fn registerTypeInfoFields(self: *IRBuilder) !void {
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
    fn registerLayoutInfoFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "size", "alignment" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("LayoutInfo", fname, @intCast(idx));
        }
    }

    /// TraitImplInfo 字段：(parent_traits, implemented_traits, methods, associated_types)
    fn registerTraitImplInfoFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "parent_traits", "implemented_traits", "methods", "associated_types" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TraitImplInfo", fname, @intCast(idx));
        }
    }

    /// FieldMeta 字段：(name, type_name, is_nullable, index)
    fn registerFieldMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "type_name", "is_nullable", "index" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("FieldMeta", fname, @intCast(idx));
        }
    }

    /// ConstructorMeta 字段：(name, fields, is_unit, index)
    fn registerConstructorMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "fields", "is_unit", "index" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("ConstructorMeta", fname, @intCast(idx));
        }
    }

    /// TypeParamMeta 字段：(name, constraints, is_specialized, specialization)
    fn registerTypeParamMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "constraints", "is_specialized", "specialization" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TypeParamMeta", fname, @intCast(idx));
        }
    }

    /// MethodMeta 字段：(name, signature, is_override, is_delegate, delegate_trait, is_async)
    fn registerMethodMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "signature", "is_override", "is_delegate", "delegate_trait", "is_async" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("MethodMeta", fname, @intCast(idx));
        }
    }

    /// FuncSigMeta 字段：(param_types, return_type, is_async)
    fn registerFuncSigMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "param_types", "return_type", "is_async" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("FuncSigMeta", fname, @intCast(idx));
        }
    }

    /// TraitMeta 字段：(name, module, type_params, parent_traits, associated_types, method_names)
    fn registerTraitMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "module", "type_params", "parent_traits", "associated_types", "method_names" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("TraitMeta", fname, @intCast(idx));
        }
    }

    /// AssociatedTypeMeta 字段：(name, is_specified, default_type)
    fn registerAssociatedTypeMetaFields(self: *IRBuilder) !void {
        const fields = [_][]const u8{ "name", "is_specified", "default_type" };
        for (fields, 0..) |fname, idx| {
            self.registerFieldId("AssociatedTypeMeta", fname, @intCast(idx));
        }
    }
    /// 注入 sema 输出契约（驱动式接入）。必须在 build() 之前调用。
    /// 设置后，inferChanTypeFromExpr 会优先从 SemaResult.expr_types 查询表达式类型，
    /// 查不到再 fallback 到自建推导。传入 null 可恢复纯自建推导模式。
    pub fn setSemaResult(self: *IRBuilder, sr: ?*const SemaResult) void {
        self.sema_result = sr;
    }

    /// 注入纯度表（驱动式接入）。必须在 build() 之前调用。
    /// 设置后，compileCall 会查询函数纯度，对纯函数 + 标量参数分配 memo_slot。
    pub fn setPurityDB(self: *IRBuilder, db: ?*const analysis_db_mod.PurityTable) void {
        self.purity_db = db;
    }

    /// 释放构建器资源（不释放产出的 IR，IR 由 GlueIR.deinit 管理）
    /// 注意：build() 成功后 arena 所有权转交给 GlueIR，此函数不再释放 arena
    pub fn deinit(self: *IRBuilder) void {
        self.scope_stack.deinit(self.allocator);
        self.func_table.deinit();
        self.type_table.deinit();
        self.ctor_table.deinit();
        self.trait_table.deinit();
        self.func_returns_str.deinit();
        self.func_generic_info.deinit();
        self.lambda_returns_throw.deinit();
        self.imported_modules.deinit();
        self.field_id_map.deinit();
        self.linear_rec_map.deinit();
        self.func_memo_slots.deinit(self.allocator);
        for (self.gadt_binding_stack.items) |*m| m.deinit();
        self.gadt_binding_stack.deinit(self.allocator);
        self.pre_declared_lambda_names.deinit(self.allocator);
        if (self.arena_owned) {
            // type_metadata_entries/type_name_to_id/pending_alias_targets 用 arena 分配
            // 由 arena.deinit() 统一释放，无需单独 deinit
            self.arena.deinit();
            self.allocator.destroy(self.arena);
            self.arena_owned = false;
        }
    }

    /// 构建完整 IR：遍历模块声明，编译所有函数
    pub fn build(self: *IRBuilder, module: ast.Module) BuildError!GlueIR {
        const arena_alloc = self.arena.allocator();

        // 全局作用域（scope_stack[0]）：顶层 val/var 在此注册，所有函数可见
        try self.pushScope();

        // 反射：注册内建类型（i32/str/bool/char/f64 等）到 TypeMetadataTable
        // 使 typeof(i32) 等返回 Primitive kind + 正确 name/layout，而非占位 "?"
        try self.registerBuiltinTypeMetadata(arena_alloc);
        // 注册 builtin error_newtype 构造器（CastError 等）—— 从 glue_builtin 元信息表加载
        // builtin 类型无 AST，但代码生成需要 ctor_table/type_table/field_id_map 条目
        // 决策 #18：sema 启动时全加载类型定义，代码生成阶段按需编译方法体
        try self.registerBuiltinErrorTypes(arena_alloc);

        // 第一遍：注册所有函数名 + 预分配 Function 占位条目
        // 同时注册 type_decl（类型+构造器）和 trait_decl
        // 占位条目包含 is_async/return_type 信息，供 compileCall 在被调用函数尚未编译时查询
        var func_count: u16 = 0;
        var has_global_init = false;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    try self.func_table.put(fd.name, func_count);
                    // 记录返回类型为 str 的函数（供 compileVecSource 判断 string_source）
                    if (fd.return_type) |rt| {
                        if (isStringTypeNode(rt)) {
                            try self.func_returns_str.put(fd.name, {});
                        }
                    }
                    // 存储泛型信息（用于泛型函数调用的类型推断）
                    try self.func_generic_info.put(fd.name, .{
                        .type_params = fd.type_params,
                        .params = fd.params,
                        .return_type = fd.return_type,
                    });
                    // 预分配占位 Function：返回通道暂为 0，编译时更新
                    const placeholder_return_chan = try allocChanFromTypeNode(&self.channels, fd.return_type);
                    try self.functions.append(arena_alloc, .{
                        .name = fd.name,
                        .node_start = 0,
                        .node_count = 0,
                        .param_channels = &.{},
                        .return_channel = placeholder_return_chan,
                        .is_entry = fd.is_entry,
                        .is_async = fd.is_async,
                    });
                    // 线性递归模式检测：fib(n) = fib(n-1) op fib(n-2) → 迭代化
                    if (try self.tryDetectLinearRecurrence(fd.name, fd)) |info| {
                        try self.linear_rec_map.put(fd.name, info);
                    }
                    func_count += 1;
                },
                .type_decl => |td| try self.registerTypeDecl(td, arena_alloc, &func_count),
                .trait_decl => |trd| try self.registerTraitDecl(trd, arena_alloc),
                .import_decl => |imp| {
                    // 注册导入的顶层模块名（用于 field_access 识别模块引用）
                    if (imp.module_path.len > 0) {
                        try self.imported_modules.put(imp.module_path[0], {});
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |stmt| {
                        switch (stmt.*) {
                            .val_decl => |vd| {
                                const chan_type = if (vd.type_annotation) |tn|
                                    chanTypeFromTypeNode(tn) orelse .i64_chan
                                else
                                    .ref_chan;
                                const chan = try self.allocChannel(chan_type);
                                try self.defineVar(vd.name, chan, false);
                                has_global_init = true;
                            },
                            .var_decl => |vd| {
                                const chan_type = if (vd.type_annotation) |tn|
                                    chanTypeFromTypeNode(tn) orelse .i64_chan
                                else
                                    .ref_chan;
                                const cell_chan = try self.allocCellChannel(chan_type);
                                try self.defineVar(vd.name, cell_chan, true);
                                has_global_init = true;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // 编译 __init 函数（顶层 val/var 初始化代码，run() 时先执行）
        var init_idx: ?u16 = null;
        if (has_global_init) {
            const init_node_start: u32 = @intCast(self.nodes.items.len);
            const init_chan_start: u16 = self.channels.count();
            init_idx = func_count;
            const init_return_chan = try self.allocChannel(.unit_chan);
            try self.functions.append(arena_alloc, .{
                .name = "__init",
                .node_start = init_node_start,
                .node_count = 0,
                .param_channels = &.{},
                .return_channel = init_return_chan,
                .is_entry = false,
                .is_async = false,
            });
            func_count += 1;

            for (module.declarations) |decl| {
                switch (decl) {
                    .expr_decl => |ed| {
                        if (ed.stmt) |stmt| {
                            switch (stmt.*) {
                                .val_decl => |vd| {
                                    const binding = self.lookupVar(vd.name) orelse continue;
                                    const value_chan = try self.compileExpr(vd.value);
                                    try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
                                },
                                .var_decl => |vd| {
                                    const binding = self.lookupVar(vd.name) orelse continue;
                                    const value_chan = try self.compileExpr(vd.value);
                                    try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            const unit_chan = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeSink(.const_unit, unit_chan, 0));
            try self.emit(Node.makeUnary(.halt_return, init_return_chan, 0, unit_chan));

            const init_node_count: u32 = @intCast(self.nodes.items.len - init_node_start);
            const init_chan_end: u16 = self.channels.count();
            self.functions.items[init_idx.?].node_start = init_node_start;
            self.functions.items[init_idx.?].node_count = init_node_count;
            self.functions.items[init_idx.?].local_chan_start = init_chan_start;
            self.functions.items[init_idx.?].local_chan_count = init_chan_end - init_chan_start;
        }

        // 第二遍：编译每个函数（更新占位条目的 node_start/node_count/param_channels）
        var entry_idx: u16 = 0;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 通过函数名查找正确的 func_idx（type_decl 方法也会占用 func_table）
                    const idx = self.func_table.get(fd.name) orelse return error.UndefinedFunction;
                    _ = try self.compileFunction(fd, idx);
                    if (fd.is_entry) entry_idx = idx;
                },
                .type_decl => |td| try self.compileTypeMethods(td),
                else => {},
            }
        }

        // 释放全局作用域
        self.popScope();

        // 反射：解析所有 TypeMetadata 的 inner/target 引用（处理递归类型）
        self.resolveTypeMetadataRefs();
        // 反射：计算所有 TypeMetadata 的 size/alignment（类型布局 pass）
        self.computeTypeLayout();

        // 组装 IR（arena 所有权转交给 GlueIR）
        self.arena_owned = false;
        // 反射：构建 TypeMetadataTable（entries 由 arena 拥有，name_to_id 用 backing 分配）
        var type_metadata_table = TypeMetadataTable{
            .entries = try self.type_metadata_entries.toOwnedSlice(arena_alloc),
            .name_to_id = std.StringHashMap(u16).init(self.allocator),
        };
        try type_metadata_table.initNameMap(self.allocator);
        return GlueIR{
            .nodes = try self.nodes.toOwnedSlice(arena_alloc),
            .scalar_metas = try self.scalar_metas.toOwnedSlice(arena_alloc),
            .call_metas = try self.call_metas.toOwnedSlice(arena_alloc),
            .vector_metas = try self.vector_metas.toOwnedSlice(arena_alloc),
            .gate_metas = try self.gate_metas.toOwnedSlice(arena_alloc),
            .route_metas = try self.route_metas.toOwnedSlice(arena_alloc),
            .race_metas = try self.race_metas.toOwnedSlice(arena_alloc),
            .cleanup_metas = try self.cleanup_metas.toOwnedSlice(arena_alloc),
            .orbit_metas = try self.orbit_metas.toOwnedSlice(arena_alloc),
            .loop_metas = try self.loop_metas.toOwnedSlice(arena_alloc),
            .closure_metas = try self.closure_metas.toOwnedSlice(arena_alloc),
            .functions = try self.functions.toOwnedSlice(arena_alloc),
            .string_pool = try self.string_pool.toOwnedSlice(arena_alloc),
            .channels = self.channels,
            .entry_index = entry_idx,
            .init_index = init_idx,
            .arena = self.arena,
            .backing = self.allocator,
            .type_metadata_table = type_metadata_table,
        };
    }

    // ════════════════════════════════════════════
    // 通道与元数据分配
    // ════════════════════════════════════════════

    fn allocChannel(self: *IRBuilder, chan_type: ChanType) !u16 {
        return self.channels.alloc(chan_type);
    }

    fn allocCellChannel(self: *IRBuilder, chan_type: ChanType) !u16 {
        return self.channels.allocCell(chan_type);
    }

    /// 添加标量元数据，返回 1-based meta_index
    fn addScalarMeta(self: *IRBuilder, meta: ScalarMeta) !u16 {
        try self.scalar_metas.append(self.arena.allocator(), meta);
        return @intCast(self.scalar_metas.items.len - 1); // 0 是占位，从 1 开始
    }

    /// 添加调用元数据，返回 1-based meta_index
    fn addCallMeta(self: *IRBuilder, meta: CallMeta) !u16 {
        try self.call_metas.append(self.arena.allocator(), meta);
        return @intCast(self.call_metas.items.len);
    }

    /// 添加向量元数据，返回 1-based meta_index
    fn addVectorMeta(self: *IRBuilder, meta: VectorMeta) !u16 {
        try self.vector_metas.append(self.arena.allocator(), meta);
        return @intCast(self.vector_metas.items.len);
    }

    /// 添加门控元数据，返回 1-based meta_index
    fn addGateMeta(self: *IRBuilder, meta: GateMeta) !u16 {
        try self.gate_metas.append(self.arena.allocator(), meta);
        return @intCast(self.gate_metas.items.len);
    }

    /// 添加路由元数据，返回 1-based meta_index
    fn addRouteMeta(self: *IRBuilder, meta: RouteMeta) !u16 {
        try self.route_metas.append(self.arena.allocator(), meta);
        return @intCast(self.route_metas.items.len);
    }

    /// 添加竞争元数据，返回 1-based meta_index
    fn addRaceMeta(self: *IRBuilder, meta: RaceMeta) !u16 {
        try self.race_metas.append(self.arena.allocator(), meta);
        return @intCast(self.race_metas.items.len);
    }

    /// 添加清理元数据，返回 1-based meta_index
    fn addCleanupMeta(self: *IRBuilder, meta: CleanupMeta) !u16 {
        try self.cleanup_metas.append(self.arena.allocator(), meta);
        return @intCast(self.cleanup_metas.items.len);
    }

    /// 添加星轨元数据，返回 1-based meta_index
    fn addOrbitMeta(self: *IRBuilder, meta: OrbitMeta) !u16 {
        try self.orbit_metas.append(self.arena.allocator(), meta);
        return @intCast(self.orbit_metas.items.len);
    }

    /// 添加循环元数据，返回 1-based meta_index
    fn addLoopMeta(self: *IRBuilder, meta: LoopMeta) !u16 {
        try self.loop_metas.append(self.arena.allocator(), meta);
        return @intCast(self.loop_metas.items.len);
    }

    /// 添加闭包元数据，返回 1-based meta_index
    fn addClosureMeta(self: *IRBuilder, meta: ClosureMeta) !u16 {
        try self.closure_metas.append(self.arena.allocator(), meta);
        return @intCast(self.closure_metas.items.len);
    }

    /// 检测 AST 表达式或语句中是否含 break/continue
    fn containsBreakOrContinue(self: *IRBuilder, expr: *const ast.Expr) bool {
        _ = self;
        return astContainsBreakOrContinueExpr(expr);
    }

    /// 检测语句列表中是否含 break/continue
    fn stmtsContainBreakOrContinue(self: *IRBuilder, stmts: []const *ast.Stmt) bool {
        _ = self;
        for (stmts) |s| {
            if (astContainsBreakOrContinueStmt(s)) return true;
        }
        return false;
    }

    fn emit(self: *IRBuilder, node: Node) !void {
        try self.nodes.append(self.arena.allocator(), node);
    }

    // ════════════════════════════════════════════
    // 作用域管理
    // ════════════════════════════════════════════

    fn pushScope(self: *IRBuilder) !void {
        try self.scope_stack.append(self.allocator, .{ .bindings = .empty });
    }

    fn popScope(self: *IRBuilder) void {
        if (self.scope_stack.pop()) |scope| {
            var s = scope;
            s.bindings.deinit(self.allocator);
        }
    }

    fn defineVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool) !void {
        try self.scopeVar(name, chan, is_cell, null);
    }

    fn scopeVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool, ast_expr: ?*const ast.Expr) !void {
        try self.scopeVarTyped(name, chan, is_cell, ast_expr, null);
    }

    fn scopeVarTyped(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool, ast_expr: ?*const ast.Expr, type_annotation: ?*ast.TypeNode) !void {
        try self.scope_stack.items[self.scope_stack.items.len - 1].bindings.append(
            self.allocator,
            .{ .name = name, .chan = chan, .is_cell = is_cell, .ast_expr = ast_expr, .type_annotation = type_annotation },
        );
    }

    fn lookupVar(self: *IRBuilder, name: []const u8) ?VarBinding {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scope_stack.items[i].bindings.items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b;
            }
        }
        return null;
    }

    /// 更新已有绑定的 ast_expr 字段（用于预声明 lambda 后补充类型推断信息）
    fn updateVarAstExpr(self: *IRBuilder, name: []const u8, ast_expr: *const ast.Expr) void {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scope_stack.items[i].bindings.items) |*b| {
                if (std.mem.eql(u8, b.name, name)) {
                    b.ast_expr = ast_expr;
                    return;
                }
            }
        }
    }

    // ════════════════════════════════════════════
    // 类型/Trait 注册（P0-b）
    // ════════════════════════════════════════════

    /// 注册 type_decl：注册类型名、构造器、方法
    fn registerTypeDecl(self: *IRBuilder, td: anytype, arena_alloc: std.mem.Allocator, func_count: *u16) BuildError!void {
        switch (td.def) {
            .adt => |adt| {
                // 为每个构造器合成字段信息
                const ctors = try arena_alloc.alloc(CtorInfo, adt.constructors.len);
                for (adt.constructors, 0..) |cdef, idx| {
                    const fields = try arena_alloc.alloc(CtorField, cdef.fields.len);
                    for (cdef.fields, 0..) |cf, fi| {
                        const fname = cf.name orelse try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                        fields[fi] = .{
                            .name = fname,
                            .type_node = cf.ty,
                        };
                        // 注册 field_id：__tag=0，字段从 1 开始
                        self.registerFieldId(td.name, fname, @intCast(fi + 1));
                    }
                    ctors[idx] = .{
                        .name = cdef.name,
                        .type_name = td.name,
                        .tag = @intCast(idx),
                        .fields = fields,
                        .return_type = cdef.return_type,
                    };
                    try self.ctor_table.put(cdef.name, ctors[idx]);
                }
                // __tag 字段：所有 ADT 共用 field_id=0
                self.registerFieldId(td.name, "__tag", 0);
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .adt,
                    .constructors = ctors,
                    .type_params = td.type_params,
                });
            },
            .newtype => |nt| {
                // Newtype：单字段构造器，构造器名 = newtype name
                const fields = try arena_alloc.alloc(CtorField, 1);
                fields[0] = .{ .name = "_0", .type_node = nt.inner };
                const ctor = CtorInfo{
                    .name = nt.name,
                    .type_name = td.name,
                    .tag = 0,
                    .fields = fields,
                    .is_newtype = true,
                };
                try self.ctor_table.put(nt.name, ctor);
                const ctors = try arena_alloc.alloc(CtorInfo, 1);
                ctors[0] = ctor;
                // __tag=0，_0=1
                self.registerFieldId(td.name, "__tag", 0);
                self.registerFieldId(td.name, "_0", 1);
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .newtype,
                    .constructors = ctors,
                });
            },
            .error_newtype => |en| {
                // Error newtype：构造器名 = error_newtype name，参数来自 params
                // error_newtype 实例用 RecordValue 表示（保持 match 兼容性），
                // type_name 通过 RecordValue.type_name 携带，message 通过 field_id=1 访问
                const fields = try arena_alloc.alloc(CtorField, en.params.len);
                for (en.params, 0..) |p, fi| {
                    const fname = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                    fields[fi] = .{
                        .name = fname,
                        .type_node = p.type_annotation,
                    };
                    self.registerFieldId(td.name, fname, @intCast(fi + 1));
                }
                const ctor = CtorInfo{
                    .name = en.name,
                    .type_name = td.name,
                    .tag = 0,
                    .fields = fields,
                };
                try self.ctor_table.put(en.name, ctor);
                const ctors = try arena_alloc.alloc(CtorInfo, 1);
                ctors[0] = ctor;
                self.registerFieldId(td.name, "__tag", 0);
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .error_newtype,
                    .constructors = ctors,
                });
            },
            .record => {
                // Record 类型：无构造器，使用 record_literal 创建
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .record,
                    .constructors = &.{},
                });
            },
            .alias => {
                // 类型别名：无构造器
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .alias,
                    .constructors = &.{},
                });
            },
        }

        // 注册方法为函数（方法名 mangle 为 "TypeName.method_name"）
        for (td.methods) |method| {
            if (method.body == null) continue; // trait 声明中的方法无体，跳过
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            try self.func_table.put(mangled, func_count.*);
            const placeholder_return_chan = try allocChanFromTypeNode(&self.channels, method.return_type);
            try self.functions.append(arena_alloc, .{
                .name = mangled,
                .node_start = 0,
                .node_count = 0,
                .param_channels = &.{},
                .return_channel = placeholder_return_chan,
                .is_entry = false,
                .is_async = false,
            });
            func_count.* += 1;
        }

        // 注册继承的 trait 默认方法（有 body 但未被 type 覆盖的 trait 方法）
        for (td.implemented_traits) |tb| {
            if (self.trait_table.get(tb.trait_name)) |trait_info| {
                for (trait_info.methods) |tm| {
                    if (tm.body == null) continue; // 无默认实现，跳过
                    const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, tm.name });
                    if (self.func_table.contains(mangled)) continue; // 已被 type 覆盖
                    try self.func_table.put(mangled, func_count.*);
                    const placeholder_return_chan = try allocChanFromTypeNode(&self.channels, tm.return_type);
                    try self.functions.append(arena_alloc, .{
                        .name = mangled,
                        .node_start = 0,
                        .node_count = 0,
                        .param_channels = &.{},
                        .return_channel = placeholder_return_chan,
                        .is_entry = false,
                        .is_async = false,
                    });
                    func_count.* += 1;
                }
            }
        }

        // 收集 TypeMetadata（typeof 反射机制）：在类型注册完成后调用
        try self.collectTypeMetadata(td, arena_alloc);
    }

    /// 注册 trait_decl：记录 trait 名和方法签名
    fn registerTraitDecl(self: *IRBuilder, trd: anytype, arena_alloc: std.mem.Allocator) BuildError!void {
        const methods = try arena_alloc.alloc(TraitMethodSig, trd.methods.len);
        for (trd.methods, 0..) |m, i| {
            methods[i] = .{
                .name = m.name,
                .param_count = @intCast(m.params.len),
                .return_type = m.return_type,
                .body = m.body,
                .params = m.params,
            };
        }
        try self.trait_table.put(trd.name, .{
            .name = trd.name,
            .methods = methods,
        });
    }

    /// 注册内建类型到 TypeMetadataTable（使 typeof(i32) 等返回正确 TypeInfo）
    ///
    /// 内建类型不通过 AST type_decl 声明，但 typeof(i32) / typeof(str) 等需要返回
    /// Primitive kind + 正确 name + 正确 layout 的 TypeInfo。
    /// 在 build() 开头调用，先于用户类型注册。
    fn registerBuiltinTypeMetadata(self: *IRBuilder, arena_alloc: std.mem.Allocator) !void {
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
            .{ .n = "str" },     .{ .n = "unit" },
        };
        for (builtins) |b| {
            // layout 由 primitiveLayout 计算（保证与字段布局一致）
            const layout = primitiveLayout(b.n) orelse LayoutInfo{ .size = 0, .alignment = 1 };
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

    /// 注册 builtin error_newtype 构造器（决策 #18/#23）
    ///
    /// 从 glue_builtin.BUILTIN_TYPES 元信息表读取所有 builtin error_newtype 类型定义，
    /// 注册到 ctor_table / type_table / field_id_map，使代码生成阶段能像用户自定义
    /// error_newtype 一样处理 CastError 等类型。
    ///
    /// 字段命名规则与用户自定义 error_newtype 一致（builder.zig:853-881）：
    ///   - _<idx>（位置参数别名，field_id = idx + 1）
    ///   - __tag（field_id = 0）
    ///   - 用户源码字段名（field_id 同 _<idx>，便于 record_get 按名查询）
    fn registerBuiltinErrorTypes(self: *IRBuilder, arena_alloc: std.mem.Allocator) !void {
        inline for (glue_builtin.BUILTIN_TYPES) |bt| {
            switch (bt.kind) {
                .error_newtype => {
                    // 构造器字段（位置参数别名 _0/_1/...，type_node 为 null 因为 builtin 无 AST）
                    const fields = try arena_alloc.alloc(CtorField, bt.fields.len);
                    for (bt.fields, 0..) |f, fi| {
                        const fname = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi});
                        fields[fi] = .{
                            .name = fname,
                            .type_node = null,
                        };
                        // 位置别名 field_id = fi + 1（与 error_newtype 一致，0 是 __tag）
                        self.registerFieldId(bt.name, fname, @intCast(fi + 1));
                        // 用户源码字段名作为同义 field_id（便于 record_get(type, "msg") 查询）
                        self.registerFieldId(bt.name, f.name, @intCast(fi + 1));
                    }
                    const ctor = CtorInfo{
                        .name = bt.constructor_name,
                        .type_name = bt.name,
                        .tag = 0,
                        .fields = fields,
                    };
                    try self.ctor_table.put(bt.constructor_name, ctor);
                    const ctors = try arena_alloc.alloc(CtorInfo, 1);
                    ctors[0] = ctor;
                    self.registerFieldId(bt.name, "__tag", 0);
                    try self.type_table.put(bt.name, .{
                        .name = bt.name,
                        .kind = .error_newtype,
                        .constructors = ctors,
                    });
                },
            }
        }
    }

    /// 收集类型元数据（typeof 反射机制）
    ///
    /// 在 registerTypeDecl 中调用，为每个类型创建 TypeMetadata 条目。
    /// inner/target 的 type_id 引用在 build() 结束时通过 resolveTypeMetadataRefs 解析。
    /// 这样可以处理递归类型（如 type List<T> = | Nil | Cons(T, List<T>)）。
    fn collectTypeMetadata(self: *IRBuilder, td: anytype, arena_alloc: std.mem.Allocator) BuildError!void {
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
                            .type_name = try typeNameFromTypeNode(cf.ty, arena_alloc),
                            .is_nullable = isNullableTypeNode(cf.ty),
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
                        .type_name = try typeNameFromTypeNode(f.ty, arena_alloc),
                        .is_nullable = isNullableTypeNode(f.ty),
                        .index = @intCast(fi),
                    };
                }
                structure = .{ .record = fields };
            },
            .newtype => |nt| {
                kind = .newtype;
                inner_type_name = try typeNameFromTypeNode(nt.inner, arena_alloc);
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
                target_type_name = try typeNameFromTypeNode(a.target, arena_alloc);
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
                    try typeNameFromTypeNode(tn, arena_alloc)
                else
                    "unknown";
            }
            const return_type = if (m.return_type) |rt|
                try typeNameFromTypeNode(rt, arena_alloc)
            else
                "unit";
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
    fn resolveTypeMetadataRefs(self: *IRBuilder) void {
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
    fn computeTypeLayout(self: *IRBuilder) void {
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
    fn computeLayoutForEntry(self: *IRBuilder, entry: *const TypeMetadata) ?LayoutInfo {
        switch (entry.structure) {
            .primitive => {
                // 基础类型：按名字判断大小
                const layout = primitiveLayout(entry.name) orelse return null;
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
                    size = alignUp(size, flayout.alignment);
                    size += flayout.size;
                    if (flayout.alignment > align_max) align_max = flayout.alignment;
                }
                // 总 size 对齐到最大对齐
                size = alignUp(size, align_max);
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
                        variant_size = alignUp(variant_size, flayout.alignment);
                        variant_size += flayout.size;
                        if (flayout.alignment > variant_align) variant_align = flayout.alignment;
                    }
                    variant_size = alignUp(variant_size, variant_align);
                    if (variant_size > max_variant_size) max_variant_size = variant_size;
                    if (variant_align > align_max) align_max = variant_align;
                }
                // 总布局：tag (1B) + padding + variant
                const tag_size: u32 = 1;
                const total = alignUp(tag_size, align_max) + max_variant_size;
                return .{ .size = alignUp(total, align_max), .alignment = @max(align_max, 1) };
            },
            .newtype => |inner_id| {
                // Newtype：inner type 的布局
                // inner_id == 0：inner 是原始类型（i32/str/bool 等，未注册到 type_name_to_id）
                // 通过 pending_alias_targets 查 inner type name，再用 primitiveLayout 查布局
                if (inner_id == 0) {
                    if (self.pending_alias_targets.get(entry.name)) |inner_name| {
                        if (primitiveLayout(inner_name)) |pl| {
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
    fn layoutOfTypeName(self: *IRBuilder, name: []const u8) ?LayoutInfo {
        // 基础类型快速路径
        if (primitiveLayout(name)) |l| return l;
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
    fn lookupTypeId(self: *const IRBuilder, type_name: []const u8) u16 {
        return self.type_name_to_id.get(type_name) orelse 0;
    }

    /// 编译 type_decl 的方法体（第二遍）
    fn compileTypeMethods(self: *IRBuilder, td: anytype) BuildError!void {
        const arena_alloc = self.arena.allocator();
        const prev_type_ctx = self.current_type_context;
        self.current_type_context = td.name;
        defer self.current_type_context = prev_type_ctx;

        for (td.methods) |method| {
            if (method.body == null) continue;
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            const func_idx = self.func_table.get(mangled) orelse continue;

            // 构造等价的 fun_decl 结构来复用 compileFunction（compileFunction 用 anytype）
            const fd = .{
                .params = method.params,
                .body = method.body.?,
            };
            _ = try self.compileFunction(fd, func_idx);
        }

        // 编译继承的 trait 默认方法体
        // 注意：trait default 方法体可能引用 typeof(Self)，需设置 current_self_type_name
        // 使 builder 在解析 typeof(Self) 时能查到 type_id
        const prev_self_type = self.current_self_type_name;
        self.current_self_type_name = td.name;
        defer self.current_self_type_name = prev_self_type;

        for (td.implemented_traits) |tb| {
            if (self.trait_table.get(tb.trait_name)) |trait_info| {
                for (trait_info.methods) |tm| {
                    if (tm.body == null) continue;
                    const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, tm.name });
                    // 仅编译未被 type 覆盖的默认方法（覆盖的已在上面编译）
                    if (self.isMethodOverridden(td, tm.name)) continue;
                    const func_idx = self.func_table.get(mangled) orelse continue;
                    const fd = .{
                        .params = tm.params,
                        .body = tm.body.?,
                    };
                    _ = try self.compileFunction(fd, func_idx);
                }
            }
        }
    }

    /// 检查类型是否自己覆盖了某方法
    fn isMethodOverridden(self: *IRBuilder, td: anytype, method_name: []const u8) bool {
        for (td.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name) and method.body != null) return true;
        }
        _ = self;
        return false;
    }

    // ════════════════════════════════════════════
    // 函数编译
    // ════════════════════════════════════════════

    fn compileFunction(self: *IRBuilder, fd: anytype, func_idx: u16) BuildError!u16 {
        const node_start: u32 = @intCast(self.nodes.items.len);
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        defer self.popScope();

        // 设置当前函数上下文（用于 GADT 类型推断 + typeof(T) 哨兵发射）
        const prev_func_name = self.current_func_name;
        const prev_param_types = self.current_func_param_types;
        const prev_type_params = self.current_func_type_params;
        if (@hasField(@TypeOf(fd), "name")) {
            self.current_func_name = fd.name;
        }
        if (@hasField(@TypeOf(fd), "params")) {
            self.current_func_param_types = fd.params;
        }
        if (@hasField(@TypeOf(fd), "type_params")) {
            self.current_func_type_params = fd.type_params;
        }
        defer {
            self.current_func_name = prev_func_name;
            self.current_func_param_types = prev_param_types;
            self.current_func_type_params = prev_type_params;
        }

        // 分配参数通道
        const arena_alloc = self.arena.allocator();
        var param_channels = try arena_alloc.alloc(u16, fd.params.len);
        for (fd.params, 0..) |param, i| {
            // 支持 nullable 类型参数：T? → nullable_chan
            const chan = if (param.type_annotation) |tn| switch (tn.*) {
                .nullable => |nb| try self.channels.allocNullable(chanTypeFromTypeNode(nb.inner) orelse .i64_chan),
                else => try self.allocChannel(chanTypeFromTypeNode(tn) orelse .i64_chan),
            } else try self.allocChannel(.i64_chan);
            param_channels[i] = chan;
            try self.scopeVarTyped(param.name, chan, param.is_var, null, param.type_annotation);
        }

        // 使用第一遍预分配的返回通道（保证 compileCall 引用的是最终通道）
        const return_chan = self.functions.items[func_idx].return_channel;
        self.current_return_chan = return_chan;
        self.current_returns_throw = if (@hasField(@TypeOf(fd), "return_type")) isThrowType(fd.return_type) else false;
        // 提取 Throw<T, E> 的 Ok 值通道类型，供 ? 传播使用
        if (self.current_returns_throw and @hasField(@TypeOf(fd), "return_type")) {
            self.current_throw_ok_chan_type = throwOkChanType(fd.return_type) orelse .i64_chan;
        }

        // 编译函数体（函数体在尾位置）
        self.in_tail_position = true;
        const body_chan = try self.compileExpr(fd.body);
        self.in_tail_position = false;

        // 若函数返回 Throw<T, E> 且函数体不是直接产生 ThrowValue 的表达式（如 Ok(...)），
        // 则包装结果为 ThrowValue(ok)
        const throw_wrapped = if (self.current_returns_throw and !self.exprIsThrowValue(fd.body)) blk: {
            const wrap_out = try self.allocChannel(.ref_chan);
            const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
            try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, body_chan));
            break :blk wrap_out;
        } else body_chan;

        // 若函数返回 nullable 类型且函数体未产生 nullable_chan，则包装为 nullable
        const return_meta = self.channels.get(return_chan);
        const final_chan = if (return_meta.chan_type == .nullable_chan) blk: {
            const body_meta = self.channels.get(throw_wrapped);
            if (body_meta.chan_type == .nullable_chan) {
                break :blk throw_wrapped; // 已是 nullable
            }
            // 需要包装（null_chan 或其他类型 → nullable_make）
            const nc = try self.channels.allocNullable(return_meta.inner_type);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, throw_wrapped));
            break :blk nc;
        } else throw_wrapped;

        // 发射 halt_return
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, final_chan));

        const node_count: u32 = @intCast(self.nodes.items.len - node_start);
        const chan_end: u16 = self.channels.count();
        // 更新占位条目（保留第一遍设置的 return_channel/is_entry/is_async）
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = param_channels;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;

        self.current_return_chan = null;
        self.current_returns_throw = false;
        self.current_throw_ok_chan_type = .i64_chan;
        return func_idx;
    }

    // ════════════════════════════════════════════
    // 表达式编译
    // ════════════════════════════════════════════

    fn compileExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 尾位置传播：保存当前尾位置状态，函数返回时恢复
        // 尾位置传播的表达式（if/match/block/propagate/call）保持 in_tail_position，
        // 其他表达式清除 in_tail_position（其子表达式不在尾位置）
        const saved_tail = self.in_tail_position;
        defer self.in_tail_position = saved_tail;
        switch (expr.*) {
            .if_expr, .match, .block, .propagate, .call => {}, // 尾位置传播
            else => self.in_tail_position = false, // 非尾位置：子表达式不在尾位置
        }
        switch (expr.*) {
            .int_literal => |il| return self.compileIntLiteral(il.raw, il.suffix),
            .float_literal => |fl| return self.compileFloatLiteral(fl.raw, fl.suffix),
            .bool_literal => |bl| {
                const out = try self.allocChannel(.bool_chan);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .bool,
                    .const_val = .{ .bool_val = bl.value },
                });
                try self.emit(Node.makeSink(.const_bool, out, meta_idx));
                return out;
            },
            .char_literal => |cl| {
                const out = try self.allocChannel(.char_chan);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .char,
                    .const_val = .{ .char_val = cl.value },
                });
                try self.emit(Node.makeSink(.const_char, out, meta_idx));
                return out;
            },
            .null_literal => {
                const out = try self.allocChannel(.null_chan);
                try self.emit(Node.makeSink(.const_null, out, 0));
                return out;
            },
            .unit_literal => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.const_unit, out, 0));
                return out;
            },
            .string_literal => |sl| {
                const out = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(sl.value);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                return out;
            },
            .array_literal => |al| {
                // 编译所有元素，然后创建数组
                // Phase 2.5 简化：array_make 接收长度，然后逐个 array_set
                const elem_count = al.elements.len;
                // 长度常量
                const len_chan = try self.allocChannel(.i64_chan);
                const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(elem_count) } });
                try self.emit(Node.makeSink(.const_i, len_chan, len_meta));
                // 创建数组
                const arr_chan = try self.allocChannel(.ref_chan);
                try self.emit(Node.makeUnary(.array_make, arr_chan, 0, len_chan));
                // 逐个设置元素
                for (al.elements, 0..) |elem_expr, i| {
                    const elem_chan = try self.compileExpr(elem_expr);
                    const idx_chan = try self.allocChannel(.i64_chan);
                    const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
                    try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
                    // array_set(arr, idx, value) — 使用 makeTernary
                    try self.emit(Node.makeTernary(.array_set, arr_chan, 0, arr_chan, idx_chan, elem_chan));
                }
                return arr_chan;
            },
            .identifier => |id| {
                // 先查变量绑定
                if (self.lookupVar(id.name)) |binding| return binding.chan;
                // 再查构造器表：无参构造器如 Leaf 可直接作为 identifier 引用
                if (self.ctor_table.get(id.name)) |ctor| {
                    if (ctor.fields.len == 0) {
                        return try self.compileConstructorCall(ctor, &.{});
                    }
                }
                return error.UnboundVariable;
            },
            .binary => |b| return self.compileBinary(b.op, b.left, b.right),
            .unary => |u| return self.compileUnary(u.op, u.operand),
            .block => |blk| return self.compileBlock(blk.statements, blk.trailing_expr),
            .call => |c| return self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args),
            .if_expr => |ie| return self.compileIf(ie),
            .propagate => |p| return self.compilePropagate(p.expr),
            .select => |s| return self.compileSelect(s.arms),
            .type_cast => |tc| return self.compileTypeCast(tc),
            .cast_builder => |cb| return self.compileCastBuilder(cb),
            .record_literal => |rl| return self.compileRecordLiteral(rl.fields),
            .record_extend => |re| return self.compileRecordExtend(re.base, re.updates),
            .field_access => |fa| return self.compileFieldAccess(fa.object, fa.field, expr),
            .index => |idx| return self.compileIndex(idx.object, idx.index),
            .string_interpolation => |si| return self.compileStringInterpolation(si.parts),
            .non_null_assert => |nn| return self.compileNonNullAssert(nn.expr),
            .safe_access => |sa| return self.compileSafeAccess(sa.object, sa.field, expr),
            .method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, false),
            .safe_method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, true),
            .lambda => |lam| return self.compileLambda(lam),
            .match => |m| return self.compileMatch(m.scrutinee, m.arms),
            .assignment_expr => |a| return self.compileAssignmentExpr(a.target, a.value),
            .compound_assign => |ca| return self.compileCompoundAssignExpr(ca.op, ca.target, ca.value),
            .atomic_expr => |ae| return self.compileAtomicExpr(ae.value),
            .lazy => |lz| return self.compileLazyExpr(lz.expr),
            .spawn_expr => |se| return self.compileSpawnExpr(se.expr),
            .inline_trait_value => |itv| return self.compileInlineTraitValue(itv.methods),
        }
    }

    /// 编译整数字面量
    fn compileIntLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8) BuildError!u16 {
        const int_kind = intKindFromSuffix(suffix) orelse .i64;
        const chan_type = ChanType.fromIntKind(int_kind);

        // 解析整数值（过滤下划线）
        var clean_buf: [64]u8 = undefined;
        const clean = filterDigits(raw, &clean_buf);

        // 检测进制前缀：0x/0X=十六进制, 0o/0O=八进制, 0b/0B=二进制
        const base: u8 = blk: {
            if (clean.len >= 2 and clean[0] == '0') {
                switch (clean[1]) {
                    'x', 'X' => break :blk 16,
                    'o', 'O' => break :blk 8,
                    'b', 'B' => break :blk 2,
                    else => {},
                }
            }
            break :blk 10;
        };
        const digits = if (base != 10) clean[2..] else clean;

        const value: i128 = std.fmt.parseInt(i128, digits, base) catch return error.InvalidLiteral;

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = int_kind,
            .const_val = .{ .int_val = value },
        });
        try self.emit(Node.makeSink(.const_i, out, meta_idx));
        return out;
    }

    /// 编译浮点字面量
    fn compileFloatLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8) BuildError!u16 {
        const float_kind = floatKindFromSuffix(suffix) orelse .f64;
        const chan_type = ChanType.fromFloatKind(float_kind);

        const value: f64 = std.fmt.parseFloat(f64, raw) catch return error.InvalidLiteral;
        const bits: u64 = @bitCast(value);

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .float,
            .float_kind = float_kind,
            .const_val = .{ .float_val = bits }, // f64 位模式存入 u128
        });
        try self.emit(Node.makeSink(.const_f, out, meta_idx));
        return out;
    }

    /// 编译二元运算
    fn compileBinary(self: *IRBuilder, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) BuildError!u16 {
        // Elvis 操作符 (??) 特殊处理：编译为 nullable_unwrap_or
        if (op == .elvis) {
            return self.compileElvis(left, right);
        }

        // Range 操作符 (.. / ..=) 特殊处理：创建数组
        if (op == .range or op == .range_inclusive) {
            return self.compileRangeExpr(left, right, op == .range_inclusive);
        }

        // 短路逻辑运算符 && / || ：用 route_dispatch 实现惰性求值
        if (op == .and_op or op == .or_op) {
            return self.compileShortCircuit(op, left, right);
        }

        // concat_list (++) 特殊处理：区分字符串拼接和数组拼接
        if (op == .concat_list) {
            const left_chan = try self.compileExpr(left);
            const right_chan = try self.compileExpr(right);
            const out = try self.allocChannel(.ref_chan);
            const is_string = self.isStringExpr(left);
            const node_op: NodeOp = if (is_string) .string_concat else .array_concat;
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(node_op, out, meta_idx, left_chan, right_chan));
            return out;
        }

        // ref_neq (!==) 特殊处理：发射 builtin_ref_eq + bool_not
        if (op == .ref_neq) {
            const left_chan = try self.compileExpr(left);
            const right_chan = try self.compileExpr(right);
            const eq_out = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeBinary(.builtin_ref_eq, eq_out, 0, left_chan, right_chan));
            const out = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.bool_not, out, 0, eq_out));
            return out;
        }

        const left_chan = try self.compileExpr(left);
        return self.compileBinaryOpWithChan(op, left_chan, right);
    }

    /// 编译短路逻辑运算符 && / ||
    /// a && b: a 为 false 时直接返回 false，不评估 b
    /// a || b: a 为 true 时直接返回 true，不评估 b
    fn compileShortCircuit(self: *IRBuilder, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) BuildError!u16 {
        const left_chan = try self.compileExpr(left);

        // 条件转 winner 索引：bool cast 为 i64（true=1, false=0）
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, left_chan));

        const arena_alloc = self.arena.allocator();

        // arm 0 = left is false, arm 1 = left is true
        // For &&: arm 0 → false (skip right), arm 1 → evaluate right
        // For ||: arm 0 → evaluate right, arm 1 → true (skip right)
        const short_circuit_arm: u8 = if (op == .and_op) 0 else 1;

        const arm0_start: u32 = @intCast(self.nodes.items.len);
        const arm0_chan: u16 = if (short_circuit_arm == 0) try self.emitConstBool(op == .or_op) else try self.compileExpr(right);
        if (self.nodes.items.len == arm0_start) {
            const load_chan = try self.allocChannel(self.channels.get(arm0_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, arm0_chan));
        }
        const arm0_len: u32 = @intCast(self.nodes.items.len - arm0_start);

        const arm1_start: u32 = @intCast(self.nodes.items.len);
        const arm1_chan: u16 = if (short_circuit_arm == 1) try self.emitConstBool(op == .or_op) else try self.compileExpr(right);
        if (self.nodes.items.len == arm1_start) {
            const load_chan = try self.allocChannel(self.channels.get(arm1_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, arm1_chan));
        }
        const arm1_len: u32 = @intCast(self.nodes.items.len - arm1_start);

        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = arm0_start;
        body_lens[0] = arm0_len;
        body_starts[1] = arm1_start;
        body_lens[1] = arm1_len;

        const result_chan = try self.allocChannel(.bool_chan);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译 range 表达式：start..end 或 start..=end → array
    fn compileRangeExpr(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr, inclusive: bool) BuildError!u16 {
        const start_chan = try self.compileExpr(left);
        const end_chan = try self.compileExpr(right);

        // 计算长度：end - start (或 end - start + 1 if inclusive)
        const diff_chan = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeBinary(.int_sub, diff_chan, meta_idx, end_chan, start_chan));

        var len_chan = diff_chan;
        if (inclusive) {
            const one_chan = try self.allocChannel(.i64_chan);
            const one_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 1 } });
            try self.emit(Node.makeSink(.const_i, one_chan, one_meta));
            const incl_len = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeBinary(.int_add, incl_len, meta_idx, diff_chan, one_chan));
            len_chan = incl_len;
        }

        // 创建数组
        const arr_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.array_make, arr_chan, 0, len_chan));

        // 使用 vec_source + vec_sink 填充数组
        // 简化：直接返回空数组（长度已设置），元素通过 vec_source 填充
        // 完整实现需要 vec_source 从 start 到 end 生成值
        return arr_chan;
    }

    /// 编译二元运算（左操作数已编译为通道）
    fn compileBinaryOpWithChan(self: *IRBuilder, op: ast.BinaryOp, left_chan: u16, right: *ast.Expr) BuildError!u16 {
        if (op == .elvis) return error.UnsupportedExpr;

        const right_chan = try self.compileExpr(right);
        const left_meta = self.channels.get(left_chan);
        const result_type = binaryResultType(op, left_meta.chan_type);
        const out = try self.allocChannel(result_type);

        const node_op = try binaryOpToNodeOp(op, left_meta.chan_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else if (result_type == .ref_chan) .ref else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeBinary(node_op, out, meta_idx, left_chan, right_chan));
        return out;
    }

    /// 编译一元运算
    fn compileUnary(self: *IRBuilder, op: ast.UnaryOp, operand: *ast.Expr) BuildError!u16 {
        const operand_chan = try self.compileExpr(operand);
        const operand_meta = self.channels.get(operand_chan);
        const result_type = operand_meta.chan_type;
        const out = try self.allocChannel(result_type);

        const node_op = try unaryOpToNodeOp(op, result_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeUnary(node_op, out, meta_idx, operand_chan));
        return out;
    }

    /// 编译 if 表达式（惰性分支：then/else 作为子图，由 route_dispatch 按条件执行）
    fn compileIf(self: *IRBuilder, ie: anytype) BuildError!u16 {
        const cond_chan = try self.compileExpr(ie.condition);

        // 条件转 winner 索引：bool cast 为 i64（true=1, false=0）
        // arm 0 = else, arm 1 = then → true→1→then, false→0→else
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, cond_chan));

        // 编译 else/then 为子图（惰性求值，由 route_dispatch 按条件执行）
        // 注意：子图必须至少有一个节点，否则 route_dispatch 无法读取 body 输出
        // 如果表达式编译后没有发射节点（如纯 identifier），补一个 load 节点

        // arm 0 = else 子图
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_body_chan = if (ie.else_branch) |eb| try self.compileExpr(eb) else blk: {
            const ch = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeSink(.const_unit, ch, 0));
            break :blk ch;
        };
        if (self.nodes.items.len == else_start) {
            // 子图为空（纯 identifier 等），补 load 节点
            const load_chan = try self.allocChannel(self.channels.get(else_body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_body_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图
        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_body_chan = try self.compileExpr(ie.then_branch);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // 获取两个分支的实际输出通道类型
        const else_out_chan = self.nodes.items[else_start + else_len - 1].output;
        const then_out_chan = self.nodes.items[then_start + then_len - 1].output;
        const else_type = self.channels.get(else_out_chan).chan_type;
        const then_type = self.channels.get(then_out_chan).chan_type;

        // 类型统一：如果一个分支是 null_chan 而另一个是值类型，
        // 结果应为 nullable_chan（execRouteDispatch 会自动处理类型转换）
        const result_type: ChanType = blk: {
            if (else_type == .null_chan and then_type != .null_chan and then_type != .nullable_chan) {
                break :blk .nullable_chan;
            }
            if (then_type == .null_chan and else_type != .null_chan and else_type != .nullable_chan) {
                break :blk .nullable_chan;
            }
            // 默认：取 then 分支类型
            break :blk then_type;
        };

        // 复制到 arena 分配的 slice
        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        // route_dispatch 按 winner 索引执行对应子图
        const result_chan = if (result_type == .nullable_chan) blk: {
            const inner_ct = if (then_type != .null_chan and then_type != .nullable_chan) then_type
                else if (else_type != .null_chan and else_type != .nullable_chan) else_type
                else .i64_chan;
            break :blk try self.channels.allocNullable(inner_ct);
        } else try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译类型转换（type_cast）
    /// safe=false: i32(big) — 不安全转换，wrap/饱和
    /// safe=true:  i32(x)?  — 安全转换，越界抛出错误（? 传播）
    fn compileTypeCast(self: *IRBuilder, tc: anytype) BuildError!u16 {
        const src_chan = try self.compileExpr(tc.expr);
        const dst_chan_type = chanTypeFromTypeNode(tc.target_type) orelse return error.UnsupportedType;

        // str(x) 是内置函数调用，不是类型转换
        if (dst_chan_type == .ref_chan) {
            if (tc.target_type.* == .named and std.mem.eql(u8, tc.target_type.named.name, "str")) {
                const out = try self.allocChannel(.ref_chan);
                try self.emit(Node.makeUnary(.builtin_str, out, 0, src_chan));
                return out;
            }
        }

        const out = try self.allocChannel(dst_chan_type);

        // 构造目标类型的 ScalarMeta
        const kind: ScalarKind = if (dst_chan_type.isInt()) .int else if (dst_chan_type.isFloat()) .float else if (dst_chan_type == .bool_chan) .bool else if (dst_chan_type == .char_chan) .char else .ref;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_chan_type.toIntKind() orelse .i64,
            .float_kind = dst_chan_type.toFloatKind() orelse .f64,
        });

        const op: NodeOp = if (tc.safe) .cast_safe else .cast;
        try self.emit(Node.makeUnary(op, out, meta_idx, src_chan));
        return out;
    }

    /// 编译 cast builder 表达式（Phase 3）：cast(expr).to(T) / cast(expr).try_to(T)
    ///
    /// to 模式：
    ///   - 输出通道 = T 类型通道
    ///   - op = .cast_to（engine 在产生 Inf / str 解析失败时 panic，否则 wrap）
    ///   - str 目标：复用 .builtin_str 节点（永不失败）
    ///
    /// try_to 模式：
    ///   - 输出通道 = ref_chan（ThrowValue 引用）
    ///   - op = .cast_try_to（engine 在失败时构造 CastError + ThrowValue.err，成功时 ThrowValue.ok）
    ///   - str 目标：直接构造 Throw.ok(str)
    fn compileCastBuilder(self: *IRBuilder, cb: anytype) BuildError!u16 {
        const src_chan = try self.compileExpr(cb.expr);
        const dst_chan_type = chanTypeFromTypeNode(cb.target_type) orelse return error.UnsupportedType;
        const target_is_str = blk: {
            if (cb.target_type.* == .named) {
                if (std.mem.eql(u8, cb.target_type.named.name, "str")) break :blk true;
            }
            break :blk false;
        };

        // str 目标：数值→str 永不失败，直接走 builtin_str，再按 mode 包装 Throw
        if (target_is_str) {
            const str_out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_str, str_out, 0, src_chan));
            switch (cb.mode) {
                .to => return str_out,
                .try_to => {
                    // 包装为 Throw.ok(str)
                    const throw_out = try self.allocChannel(.ref_chan);
                    const meta_idx = try self.addScalarMeta(.{
                        .kind = .str,
                    });
                    try self.emit(Node.makeUnary(.cast_try_to, throw_out, meta_idx, str_out));
                    return throw_out;
                },
            }
        }

        // 构造目标类型的 ScalarMeta（描述 dst 类型，engine 据此分派转换路径）
        const kind: ScalarKind = if (dst_chan_type.isInt()) .int else if (dst_chan_type.isFloat()) .float else if (dst_chan_type == .bool_chan) .bool else if (dst_chan_type == .char_chan) .char else .ref;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_chan_type.toIntKind() orelse .i64,
            .float_kind = dst_chan_type.toFloatKind() orelse .f64,
        });

        switch (cb.mode) {
            .to => {
                // 输出类型 = T
                const out = try self.allocChannel(dst_chan_type);
                try self.emit(Node.makeUnary(.cast_to, out, meta_idx, src_chan));
                return out;
            },
            .try_to => {
                // 输出类型 = ref_chan（ThrowValue 引用）
                const out = try self.allocChannel(.ref_chan);
                try self.emit(Node.makeUnary(.cast_try_to, out, meta_idx, src_chan));
                return out;
            },
        }
    }

    /// 编译记录字面量：{ field1: val1, field2: val2 }
    /// → record_make(field_count=N) + 逐个 record_set(field_id=i)
    /// 字段按声明顺序分配 field_id = 0..N-1
    fn compileRecordLiteral(self: *IRBuilder, fields: []ast.RecordFieldExpr) BuildError!u16 {
        const rec_chan = try self.allocChannel(.ref_chan);
        // record_make：meta 编码 (field_count << 32) | type_name_idx
        // record literal 无类型名，用空字符串
        const make_meta = try self.addRecordMakeMeta("", @intCast(fields.len));
        try self.emit(Node.makeSink(.record_make, rec_chan, make_meta));
        // 为每个字段分配 field_id 并注册（type_name 为空，用全局映射）
        for (fields, 0..) |field, i| {
            const val_chan = try self.compileExpr(field.value);
            const field_id: u16 = @intCast(i);
            self.registerFieldId("", field.name, field_id);
            const field_meta_idx = try self.addFieldIdMeta(field_id);
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta_idx, rec_chan, val_chan));
        }
        return rec_chan;
    }

    /// 编译记录扩展：(...base, field: value, ...)
    /// → record_clone_extend(base, extra_count) → record_set(new_rec, field_id, value) ...
    /// record_clone 的 meta 编码扩展字段数：运行时分配 base.fields.len + extra 个槽位
    /// 已存在字段的 field_id 保持不变（复用 base 的），新字段从 base.fields.len 开始追加
    fn compileRecordExtend(self: *IRBuilder, base: *ast.Expr, updates: []ast.RecordFieldExpr) BuildError!u16 {
        const base_chan = try self.compileExpr(base);
        // 统计 base 的字段数（用于新字段 field_id 分配）
        const base_field_count = self.countRecordFields(base);
        // 克隆 base 记录并扩展 extra 个槽位
        const new_chan = try self.allocChannel(.ref_chan);
        const clone_meta = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, @intCast(updates.len)) },
        });
        try self.emit(Node.makeUnary(.record_clone, new_chan, clone_meta, base_chan));
        // 应用更新字段：已存在的复用 base field_id，新字段追加在末尾
        var new_field_idx: u16 = @intCast(base_field_count);
        for (updates) |field| {
            const val_chan = try self.compileExpr(field.value);
            // 若字段已在 base 中注册，复用其 field_id；否则分配新 field_id
            const field_id: u16 = self.lookupFieldId("", field.name) orelse blk: {
                self.registerFieldId("", field.name, new_field_idx);
                const id = new_field_idx;
                new_field_idx += 1;
                break :blk id;
            };
            const field_meta_idx = try self.addFieldIdMeta(field_id);
            try self.emit(Node.makeBinary(.record_set, new_chan, field_meta_idx, new_chan, val_chan));
        }
        return new_chan;
    }

    /// 统计 record 表达式的字段数（用于 record_extend 的 field_id 分配）
    fn countRecordFields(self: *IRBuilder, expr: *const ast.Expr) usize {
        switch (expr.*) {
            .record_literal => |rl| return rl.fields.len,
            .record_extend => |re| {
                var base_count = self.countRecordFields(re.base);
                // 统计 updates 中的新字段（不在 base 中的）
                for (re.updates) |u| {
                    if (self.lookupFieldId("", u.name) == null) base_count += 1;
                }
                return base_count;
            },
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |e| return self.countRecordFields(e);
                }
                return 0;
            },
            .call => |c| {
                if (c.callee.* == .identifier) {
                    if (self.ctor_table.get(c.callee.identifier.name)) |ctor| {
                        // ADT: __tag + 字段数
                        return ctor.fields.len + 1;
                    }
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// 编译赋值表达式：target = value（作为表达式，返回 value）
    fn compileAssignmentExpr(self: *IRBuilder, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
        const value_chan = try self.compileExpr(value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return value_chan;
    }

    /// 编译复合赋值表达式：target op= value（作为表达式，返回结果）
    fn compileCompoundAssignExpr(self: *IRBuilder, op: ast.CompoundAssignOp, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
        const bin_op: ast.BinaryOp = switch (op) {
            .add_assign => .add,
            .sub_assign => .sub,
            .mul_assign => .mul,
            .div_assign => .div,
            .mod_assign => .mod,
            .bit_and_assign => .bit_and,
            .bit_or_assign => .bit_or,
            .bit_xor_assign => .bit_xor,
            .shl_assign => .shl,
            .shr_assign => .shr,
        };
        const result_chan = try self.compileBinary(bin_op, target, value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, result_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return result_chan;
    }

    /// 编译字段访问：obj.field
    /// → record_get(obj, field_id) 或 channel_sender/channel_receiver
    /// field_id 通过 field_id_map 查找：先推断 obj 的 type_name，再查映射
    fn compileFieldAccess(self: *IRBuilder, object: *ast.Expr, field: []const u8, field_access_expr: *const ast.Expr) BuildError!u16 {
        // channel 的 sender/receiver 字段特殊处理
        if (std.mem.eql(u8, field, "sender")) {
            const obj_chan = try self.compileExpr(object);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.channel_sender, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, field, "receiver")) {
            const obj_chan = try self.compileExpr(object);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.channel_receiver, out, 0, obj_chan));
            return out;
        }
        const obj_chan = try self.compileExpr(object);
        // 解析 field_id：先尝试从 obj 推断 type_name，再查 field_id_map
        // fallback：用全局 "" 类型名查（record literal 的字段）
        const inferred_type = self.inferTypeNameFromExpr(object);
        const field_id: u16 = blk: {
            if (std.mem.eql(u8, field, "__tag")) break :blk 0; // __tag 固定 field_id=0
            if (inferred_type) |type_name| {
                if (self.lookupFieldId(type_name, field)) |id| break :blk id;
            }
            if (self.lookupFieldId("", field)) |id| break :blk id;
            // 未注册字段：fallback 用 0（运行时可能因越界失败，但保留旧行为兼容）
            break :blk 0;
        };
        const meta_idx = try self.addFieldIdMeta(field_id);
        // 优先从 sema 查询 field_access 表达式本身的 chan_type
        // 这能正确处理 ref 对象的 scalar 字段（如 g.v 中 g 是 ref 但 v 是 i32）
        // 以及 ref 对象的 ref 字段（如 self.inner 中 self 是 ref 且 inner 也是 ref）
        const sema_ct: ?ChanType = blk: {
            if (self.sema_result) |sr| {
                if (sr.getExpr(@intFromPtr(field_access_expr))) |info| {
                    if (info.chan_type != .null_chan) break :blk info.chan_type;
                }
            }
            break :blk null;
        };
        const chan_type: ChanType = sema_ct orelse self.inferFieldType(object, field) orelse .i64_chan;
        const out = try self.allocChannel(chan_type);
        try self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan));
        return out;
    }

    /// 从 AST 推断字段类型（无 sema 时的简易类型推导）
    /// 通过回溯对象表达式找到 record_literal/record_extend/构造器调用，再查字段值类型
    fn inferFieldType(self: *IRBuilder, object: *const ast.Expr, field: []const u8) ?ChanType {
        // typeof(TypeName) 返回 TypeInfo，字段类型按字段名推导
        // 不能进入下面的 .call 分支（ctor_table 无 typeof 条目）
        if (object.* == .call and object.call.callee.* == .identifier and
            std.mem.eql(u8, object.call.callee.identifier.name, "typeof"))
        {
            return typeInfoFieldType(field);
        }
        // 如果是 identifier，查找其定义
        const obj_expr = switch (object.*) {
            .identifier => |id| blk: {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |e| break :blk e;
                }
                break :blk null;
            },
            else => object,
        } orelse return null;

        // 变量绑定的 typeof 表达式
        if (obj_expr.* == .call and obj_expr.call.callee.* == .identifier and
            std.mem.eql(u8, obj_expr.call.callee.identifier.name, "typeof"))
        {
            return typeInfoFieldType(field);
        }

        switch (obj_expr.*) {
            .record_literal => |rl| {
                for (rl.fields) |f| {
                    if (std.mem.eql(u8, f.name, field)) {
                        return self.inferChanTypeFromExpr(f.value);
                    }
                }
            },
            .record_extend => |re| {
                // 先查 updates
                for (re.updates) |f| {
                    if (std.mem.eql(u8, f.name, field)) {
                        return self.inferChanTypeFromExpr(f.value);
                    }
                }
                // 再查 base
                return self.inferFieldType(re.base, field);
            },
            .call => |c| {
                // 构造器调用：Pair(1, "one") → 查 ctor_table 获取字段名，按位置匹配
                const ctor_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => return null,
                };
                const ctor = self.ctor_table.get(ctor_name) orelse return null;
                for (ctor.fields, 0..) |cf, i| {
                    if (std.mem.eql(u8, cf.name, field)) {
                        if (i < c.arguments.len) {
                            return self.inferChanTypeFromExpr(c.arguments[i]);
                        }
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// TypeInfo 字段名 → 通道类型（用于 typeof(TypeName).field 的字段访问）
    ///
    /// 新设计：7 个顶层字段，字段顺序与 IRBuilder.registerTypeInfoFields 和 engine.execBuiltinTypeof 一致：
    ///   0: name (str) → ref_chan
    ///   1: module (str) → ref_chan
    ///   2: kind (TypeKind，str 表示 ADT 构造器名) → ref_chan
    ///   3: structure (TypeStructure ADT) → ref_chan
    ///   4: layout (LayoutInfo) → ref_chan
    ///   5: impls (TraitImplInfo) → ref_chan
    ///   6: type_params (Array<TypeParamMeta>) → ref_chan
    /// 所有顶层字段都是引用类型（字符串或嵌套 RecordValue/Array）
    fn typeInfoFieldType(field: []const u8) ?ChanType {
        const ref_fields = [_][]const u8{
            "name", "module", "kind", "structure", "layout", "impls", "type_params",
        };
        for (ref_fields) |f| if (std.mem.eql(u8, field, f)) return .ref_chan;
        return null;
    }

    /// 从表达式推断通道类型
    fn inferChanTypeFromExpr(self: *IRBuilder, expr: *ast.Expr) ?ChanType {
        // 驱动式接入：优先从 sema 产出的表达式类型映射查询（key = AST 表达式指针地址）。
        // sema 与 builder 遍历同一 ast.Module，AST 节点地址一致，故可精确匹配。
        if (self.sema_result) |sr| {
            if (sr.getExpr(@intFromPtr(expr))) |info| {
                return info.chan_type;
            }
        }
        // fallback：自建推导（仅处理字面量与标识符，其余返回 null）
        switch (expr.*) {
            .int_literal => |il| {
                const int_kind = intKindFromSuffix(il.suffix) orelse .i64;
                return ChanType.fromIntKind(int_kind);
            },
            .float_literal => |fl| {
                const float_kind = floatKindFromSuffix(fl.suffix) orelse .f64;
                return ChanType.fromFloatKind(float_kind);
            },
            .bool_literal => return .bool_chan,
            .char_literal => return .char_chan,
            .string_literal, .string_interpolation => return .ref_chan,
            .array_literal => return .ref_chan,
            .record_literal, .record_extend => return .ref_chan,
            .null_literal => return .null_chan,
            .unit_literal => return .unit_chan,
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    return self.channels.get(binding.chan).chan_type;
                }
                return null;
            },
            else => return null,
        }
    }

    /// 编译索引访问：obj[index]
    /// 数组 → array_get，字符串 → string_index
    fn compileIndex(self: *IRBuilder, object: *ast.Expr, index: *ast.Expr) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const idx_chan = try self.compileExpr(index);
        // 通过 AST 节点类型推断 + 参数类型标注
        const is_string = self.isStringExpr(object) or self.isStringParam(object);
        if (is_string) {
            const out = try self.allocChannel(.char_chan);
            try self.emit(Node.makeBinary(.string_index, out, 0, obj_chan, idx_chan));
            return out;
        }
        // 默认数组索引
        const out = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeBinary(.array_get, out, 0, obj_chan, idx_chan));
        return out;
    }

    /// 编译字符串插值："...${expr}..."
    /// → 逐段 string_concat 链
    fn compileStringInterpolation(self: *IRBuilder, parts: []ast.InterpolationPart) BuildError!u16 {
        if (parts.len == 0) {
            // 空插值 → 空字符串
            const out = try self.allocChannel(.ref_chan);
            const str_idx = self.addString("");
            const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
            try self.emit(Node.makeSink(.const_str, out, meta_idx));
            return out;
        }
        // 第一段
        var current_chan: u16 = switch (parts[0]) {
            .literal => |s| blk: {
                const out = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(s);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                break :blk out;
            },
            .expression => |e| try self.exprToStringChan(e),
        };
        // 后续段逐个 concat
        for (parts[1..]) |part| {
            const next_chan: u16 = switch (part) {
                .literal => |s| blk: {
                    const out = try self.allocChannel(.ref_chan);
                    const str_idx = self.addString(s);
                    const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                    try self.emit(Node.makeSink(.const_str, out, meta_idx));
                    break :blk out;
                },
                .expression => |e| try self.exprToStringChan(e),
            };
            const out = try self.allocChannel(.ref_chan);
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(.string_concat, out, meta_idx, current_chan, next_chan));
            current_chan = out;
        }
        return current_chan;
    }

    /// 将表达式编译为字符串通道（非字符串表达式先 builtin_str 转换）
    fn exprToStringChan(self: *IRBuilder, e: *const ast.Expr) BuildError!u16 {
        const chan = try self.compileExpr(e);
        const meta = self.channels.get(chan);
        // 字符串/引用类型直接使用
        if (meta.chan_type == .ref_chan) return chan;
        // 其他类型通过 builtin_str 转换
        const out = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.builtin_str, out, 0, chan));
        return out;
    }

    /// 编译函数调用
    fn compileCall(self: *IRBuilder, callee: *ast.Expr, arguments: []*ast.Expr) BuildError!u16 {
        return try self.compileCallWithTypeArgs(callee, arguments, null);
    }

    /// typeof 参数解析为 meta_index
    ///
    /// 递归处理 propagate 节点（typeof(T?) 形式）：
    /// - identifier "TypeName" → 查 type_name_to_id / 泛型参数 / Self → type_id 或 0x8000|idx 或 0
    /// - propagate(inner) → 0x4000 | resolveTypeofMetaIndex(inner)
    ///
    /// meta_index 编码（u16）：
    /// - bit 15 (0x8000): 泛型参数哨兵
    /// - bit 14 (0x4000): nullable 包装哨兵
    /// - bit 0-13: type_id 或 param_idx
    fn resolveTypeofMetaIndex(self: *IRBuilder, arg: *ast.Expr) BuildError!u16 {
        switch (arg.*) {
            .propagate => |p| {
                // typeof(T?) — nullable 包装
                const inner_meta = try self.resolveTypeofMetaIndex(p.expr);
                if (inner_meta == 0) return 0; // inner 未识别，整体返回 0
                const nullable_meta: u16 = 0x4000 | inner_meta;
                return nullable_meta;
            },
            .identifier => |id| {
                const type_name = id.name;
                // 1. 具体类型：查 type_name_to_id
                if (self.type_name_to_id.get(type_name)) |tid| return tid;
                // 2. Self：在 trait default 方法中
                if (std.mem.eql(u8, type_name, "Self")) {
                    if (self.current_self_type_name) |self_name| {
                        if (self.type_name_to_id.get(self_name)) |tid| return tid;
                    }
                    return 0; // Self 未解析
                }
                // 3. 泛型参数 T
                if (self.current_func_type_params) |tps| {
                    for (tps, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.name, type_name)) {
                            const sentinel: u16 = @intCast(0x8000 | idx);
                            return sentinel;
                        }
                    }
                }
                // 4. 未识别类型
                return 0;
            },
            else => return error.UnsupportedExpr,
        }
    }

    /// 编译函数调用，附带显式类型实参（来自 `func[T](args)` 形式）
    /// type_args_hint != null 时优先使用显式类型实参；否则从参数类型推断
    fn compileCallWithTypeArgs(
        self: *IRBuilder,
        callee: *ast.Expr,
        arguments: []*ast.Expr,
        type_args_hint: ?[]*ast.TypeNode,
    ) BuildError!u16 {
        // 只支持直接函数名调用
        const func_name = switch (callee.*) {
            .identifier => |id| id.name,
            else => return error.UnsupportedExpr,
        };

        // 内置函数：print / println
        if (std.mem.eql(u8, func_name, "print") or std.mem.eql(u8, func_name, "println")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.unit_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "println")) .builtin_println else .builtin_print;
            try self.emit(Node.makeUnary(op, out, 0, arg_chan));
            return out;
        }

        // 内置函数：eprint / eprintln（stderr 输出）
        if (std.mem.eql(u8, func_name, "eprint") or std.mem.eql(u8, func_name, "eprintln")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.unit_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "eprintln")) .builtin_eprintln else .builtin_eprint;
            try self.emit(Node.makeUnary(op, out, 0, arg_chan));
            return out;
        }

        // 内置函数：scan / scanln（stdin 读取）
        if (std.mem.eql(u8, func_name, "scan") or std.mem.eql(u8, func_name, "scanln")) {
            const out = try self.allocChannel(.ref_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "scanln")) .builtin_scanln else .builtin_scan;
            try self.emit(Node.makeSink(op, out, 0));
            return out;
        }

        // 内置函数：type(x) → 运行时类型名
        if (std.mem.eql(u8, func_name, "type")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_type, out, 0, arg_chan));
            return out;
        }

        // 内置函数：typeof(TypeName) → 编译期类型反射，返回 TypeInfo RecordValue
        // 参数是类型名（在值位置传递类型），不是表达式值
        // meta_index 编码：
        //   1..N             = 具体类型 type_id（查 TypeMetadataTable）
        //   0x8000|param_idx = 泛型参数哨兵（运行时查 frame.type_args[param_idx]）
        //   0x4000|inner_meta = nullable 包装（typeof(T?)，运行时构造 Nullable kind）
        //   0                 = 未识别（运行时返回占位 TypeInfo）
        if (std.mem.eql(u8, func_name, "typeof")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const meta_idx = try self.resolveTypeofMetaIndex(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeSink(.builtin_typeof, out, meta_idx));
            return out;
        }

        // 内置函数：Panic(msg) → 触发 panic
        if (std.mem.eql(u8, func_name, "Panic")) {
            const out = try self.allocChannel(.unit_chan);
            if (arguments.len == 0) {
                try self.emit(Node.makeSink(.builtin_panic, out, 0));
            } else {
                // 有消息参数：先打印再 panic
                const arg_chan = try self.compileExpr(arguments[0]);
                try self.emit(Node.makeUnary(.builtin_eprint, try self.allocChannel(.unit_chan), 0, arg_chan));
                try self.emit(Node.makeSink(.builtin_panic, out, 0));
            }
            return out;
        }

        // 内置构造器：Ok(value) → 构造 ThrowValue(ok)
        if (std.mem.eql(u8, func_name, "Ok")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_ok, out, 0, arg_chan));
            return out;
        }

        // 内置构造器：Error(msg) → 构造 ThrowValue(err) + ErrorValue
        if (std.mem.eql(u8, func_name, "Error")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_error, out, 0, arg_chan));
            return out;
        }

        // 内置函数：str(x) → 转字符串
        if (std.mem.eql(u8, func_name, "str")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_str, out, 0, arg_chan));
            return out;
        }

        // 内置函数：channel(buffer_size) → 创建 ChannelValue
        if (std.mem.eql(u8, func_name, "channel")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.channel_create, out, 0, arg_chan));
            return out;
        }

        // 构造器调用：Node(5, Leaf, Leaf) → record_make + record_set __tag + 各字段
        if (self.ctor_table.get(func_name)) |ctor| {
            return try self.compileConstructorCall(ctor, arguments);
        }

        const func_idx = self.func_table.get(func_name) orelse {
            // 不在 func_table 中：检查是否为变量（lambda 调用）
            if (self.lookupVar(func_name)) |binding| {
                // 从绑定的 type_annotation 推断闭包返回类型
                // 对于函数类型 (A) -> R，返回类型是 R，不是 ref_chan
                const ret_chan_type = blk: {
                    if (binding.type_annotation) |tn| {
                        switch (tn.*) {
                            .function => |f| break :blk chanTypeFromTypeNode(f.return_type) orelse .i64_chan,
                            else => break :blk chanTypeFromTypeNode(tn) orelse .i64_chan,
                        }
                    }
                    break :blk .i64_chan;
                };
                return try self.compileCallIndirect(binding.chan, arguments, ret_chan_type);
            }
            return error.UndefinedFunction;
        };

        // 线性递归优化：fib(n) 等模式 → 迭代 scalar_loop（O(N) 替代 O(2^N)）
        if (self.linear_rec_map.get(func_name)) |rec_info| {
            if (arguments.len == 1) {
                const arg_chan = try self.compileExpr(arguments[0]);
                return try self.compileLinearRecurrenceCall(rec_info, arg_chan);
            }
        }

        // 编译参数
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        // 读取尾位置标志（参数不在尾位置）
        const tail_call = self.in_tail_position;
        self.in_tail_position = false;
        // 获取被调用函数的参数信息（用于判断参数是否为 trait 类型）
        const func_info = self.func_generic_info.get(func_name);
        for (arguments, 0..) |arg, i| {
            // 检查是否为模块引用且参数类型为 trait → 构造 trait 值
            if (func_info) |fi| {
                if (i < fi.params.len) {
                    if (fi.params[i].type_annotation) |tn| {
                        if (tn.* == .named) {
                            if (self.trait_table.contains(tn.named.name)) {
                                if (self.isModuleReference(arg)) |mod_ref| {
                                    arg_chans[i] = try self.compileModuleTraitValue(mod_ref, tn.named.name);
                                    continue;
                                }
                            }
                        }
                    }
                }
            }
            arg_chans[i] = try self.compileExpr(arg);
        }

        const func = self.functions.items[func_idx];

        // async 函数：发射 orbit_async_create 返回 AsyncHandle（不自动 await）
        // 用户需显式调用 .await() 获取结果，.status() 查询状态
        if (func.is_async) {
            return try self.emitOrbitCreate(func_idx, arg_chans, func);
        }

        // 普通函数：发射 call 节点
        const ret_meta = self.channels.get(func.return_channel);
        // 泛型函数：尝试从实参类型推断返回类型
        const inferred_ret_type = self.inferGenericCallReturnType(func_name, arguments);
        const ret_chan_type = inferred_ret_type orelse ret_meta.chan_type;
        const out = if (ret_chan_type == .nullable_chan)
            try self.channels.allocNullable(ret_meta.inner_type)
        else
            try self.allocChannel(ret_chan_type);
        // 计算泛型类型实参（type_args）用于 typeof(T) 运行时查表
        const type_args = try self.inferCallTypeArgs(func_name, arguments, type_args_hint);
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arguments.len),
            .tail_call = tail_call,
            .memo_slot = self.tryAssignMemoSlot(func_name, arg_chans, ret_chan_type, ret_meta.inner_type),
            .type_args = type_args,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .call,
            .input_count = @intCast(@min(arguments.len, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 推导调用点的泛型类型实参（type_id 列表）
    ///
    /// 用于 typeof(T) 在泛型函数内的运行时查表：
    ///   - 非泛型函数：返回空切片
    ///   - 显式类型实参：从 type_args_hint 解析类型名 → type_id
    ///   - 隐式推断：从参数类型注解匹配实参类型，再映射到 type_id
    ///   - 递归调用：从 GADT 绑定栈继承当前函数的类型绑定
    ///
    /// 返回切片由 arena 拥有，与 IR 生命周期一致
    fn inferCallTypeArgs(
        self: *IRBuilder,
        func_name: []const u8,
        arguments: []*ast.Expr,
        type_args_hint: ?[]*ast.TypeNode,
    ) ![]const u16 {
        const arena_alloc = self.arena.allocator();
        const info = self.func_generic_info.get(func_name) orelse return &.{};
        if (info.type_params.len == 0) return &.{};

        // 1. 显式类型实参：直接从 type_args_hint 解析类型名 → type_id
        if (type_args_hint) |hints| {
            if (hints.len > 0) {
                const args = try arena_alloc.alloc(u16, hints.len);
                for (hints, 0..) |tn, i| {
                    const name = typeNameFromTypeNodeConst(tn);
                    args[i] = self.lookupTypeId(name);
                }
                return args;
            }
        }

        // 2. 隐式推断：构建类型参数名 → type_id 的绑定表
        //    先从参数类型注解中匹配类型参数名，再用实参的构造器/类型推断 type_id
        var name_to_typeid = std.StringHashMap(u16).init(self.allocator);
        defer name_to_typeid.deinit();

        // 递归调用：从 GADT 绑定栈继承当前函数的类型绑定
        if (self.current_func_name) |cfn| {
            if (std.mem.eql(u8, cfn, func_name) and self.gadt_binding_stack.items.len > 0) {
                // 递归调用时，type_args 与当前函数一致——从 current_func_type_params 提取
                if (self.current_func_type_params) |tps| {
                    const args = try arena_alloc.alloc(u16, tps.len);
                    for (tps, 0..) |tp, i| {
                        // 递归调用：类型实参 = 当前函数的类型参数（发出哨兵）
                        // 但这里需要 type_id，所以用 lookupTypeId
                        args[i] = self.lookupTypeId(tp.name);
                    }
                    return args;
                }
            }
        }

        // 从参数类型注解匹配类型参数名，并从实参提取 type_id
        const param_count = @min(info.params.len, arguments.len);
        for (0..param_count) |i| {
            const param_type = info.params[i].type_annotation orelse continue;
            try self.matchTypeParamToTypeId(param_type, arguments[i], &name_to_typeid);
        }

        // 按函数定义的 type_params 顺序输出 type_id
        const args = try arena_alloc.alloc(u16, info.type_params.len);
        for (info.type_params, 0..) |tp, i| {
            args[i] = name_to_typeid.get(tp.name) orelse 0;
        }
        return args;
    }

    /// 从参数类型注解匹配类型参数名，并从实参提取对应的 type_id
    /// 例如：参数注解 T，实参 typeof(Point) → name_to_typeid["T"] = Point 的 type_id
    fn matchTypeParamToTypeId(
        self: *IRBuilder,
        param_type: *ast.TypeNode,
        arg_expr: *const ast.Expr,
        name_to_typeid: *std.StringHashMap(u16),
    ) !void {
        // 实参解引用：若实参是变量绑定，则替换为其绑定的表达式
        const resolved_expr: *const ast.Expr = blk: {
            if (arg_expr.* == .identifier) {
                if (self.lookupVar(arg_expr.identifier.name)) |binding| {
                    if (binding.ast_expr) |var_expr| break :blk var_expr;
                }
            }
            break :blk arg_expr;
        };
        switch (param_type.*) {
            .named => |n| {
                if (!self.isTypeParamName(n.name)) return;
                if (name_to_typeid.contains(n.name)) return;
                // 从实参推断类型名
                if (self.inferTypeNameFromExpr(resolved_expr)) |type_name| {
                    const tid = self.lookupTypeId(type_name);
                    if (tid != 0) {
                        try name_to_typeid.put(n.name, tid);
                    }
                }
            },
            .generic => |g| {
                // 泛型类型如 Box<T>：从构造器调用参数递归推断 T 的具体类型
                // 例如：参数类型 Box<T>，实参 Box(Point(1, 2))
                // → 查 Box 的字段定义（value: T），用第 0 个实参 Point(1, 2) 递归匹配 T
                if (resolved_expr.* == .call) {
                    if (resolved_expr.call.callee.* == .identifier) {
                        const ctor_name = resolved_expr.call.callee.identifier.name;
                        if (self.ctor_table.get(ctor_name)) |ctor| {
                            // 1. 优先：GADT 构造器，从 return_type 显式提取具体类型
                            if (ctor.return_type) |rt| {
                                if (rt.* == .generic and rt.generic.args.len > 0) {
                                    for (g.args, 0..) |param_arg, idx| {
                                        if (param_arg.* != .named) continue;
                                        if (!self.isTypeParamName(param_arg.named.name)) continue;
                                        if (idx >= rt.generic.args.len) continue;
                                        const concrete_name = typeNameFromTypeNodeConst(rt.generic.args[idx]);
                                        const tid = self.lookupTypeId(concrete_name);
                                        if (tid != 0) {
                                            try name_to_typeid.put(param_arg.named.name, tid);
                                        }
                                    }
                                }
                            }
                            // 2. 通用：递归匹配构造器字段类型与构造器实参
                            //    Box<T> 的字段 value: T，实参 arg → 递归匹配 T 与 arg
                            const ctor_args = resolved_expr.call.arguments;
                            for (ctor.fields, 0..) |cf, fi| {
                                if (cf.type_node) |ftn| {
                                    if (fi >= ctor_args.len) break;
                                    try self.matchTypeParamToTypeId(ftn, ctor_args[fi], name_to_typeid);
                                }
                            }
                        }
                    }
                }
            },
            .nullable => |nb| try self.matchTypeParamToTypeId(nb.inner, resolved_expr, name_to_typeid),
            else => {},
        }
    }

    /// 判断通道类型是否为标量（无堆指针，可安全作为 memo key/val）
    /// 标量：整数、浮点、布尔、字符。排除 ref/nullable/null/unit（后者无信息量或含堆指针）
    fn isScalarChanType(ct: ChanType) bool {
        return switch (ct) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan,
            .isize_chan, .usize_chan,
            .f16_chan, .f32_chan, .f64_chan, .f128_chan,
            .bool_chan, .char_chan => true,
            else => false,
        };
    }

    /// 可 memoize 的通道类型：标量 + nullable_chan
    /// 排除 ref_chan（指针哈希命中率低，deepCopy 返回值开销巨大）
    /// 排除 unit_chan/null_chan（无数据）和 mask_chan（内部状态）
    /// nullable_chan 仅当 inner_type 为标量时才有效（Engine 层处理）
    fn isMemoizableChanType(ct: ChanType) bool {
        return switch (ct) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan,
            .isize_chan, .usize_chan,
            .f16_chan, .f32_chan, .f64_chan, .f128_chan,
            .bool_chan, .char_chan,
            .nullable_chan => true,
            else => false,
        };
    }

    /// 尝试为纯函数分配 memo_slot。
    /// 条件：purity_db 可用 + 函数为 pure + 所有实参通道为标量 + 返回类型为标量。
    /// 同一函数名复用同一 slot（per-function memo，非 per-call-site）。
    /// 返回 0 表示不可 memoize，>0 表示 slot 索引。
    fn tryAssignMemoSlot(self: *IRBuilder, func_name: []const u8, arg_chans: []const u16, ret_chan_type: ChanType, ret_inner_type: ChanType) u16 {
        const pdb = self.purity_db orelse return 0;
        if (!pdb.isPure(func_name)) return 0;
        // 仅对递归函数启用 memoization
        // 非递归纯函数的参数通常每次不同，哈希开销 > 收益
        if (!pdb.isRecursive(func_name)) return 0;
        // 返回类型必须为可 memoize 类型（标量/nullable<标量>）
        if (!isMemoizableChanType(ret_chan_type)) return 0;
        // nullable 返回的 inner_type 必须为标量（排除 nullable<ref>）
        if (ret_chan_type == .nullable_chan and !isScalarChanType(ret_inner_type)) return 0;
        // 所有实参通道必须为可 memoize 类型
        for (arg_chans) |ch| {
            const meta = self.channels.get(ch);
            if (!isMemoizableChanType(meta.chan_type)) return 0;
            // nullable 的 inner_type 必须为标量（排除 nullable<ref>）
            if (meta.chan_type == .nullable_chan and !isScalarChanType(meta.inner_type)) return 0;
        }
        // per-function memo_slot：同函数名复用同一 slot
        if (self.func_memo_slots.get(func_name)) |slot| return slot;
        const slot = self.memo_slot_counter;
        self.memo_slot_counter += 1;
        // hashmap 内部存储用 self.allocator（与 deinit 一致）
        self.func_memo_slots.put(self.allocator, func_name, slot) catch return 0;
        return slot;
    }

    /// 推断 Throw 表达式的 Ok 值通道类型
    /// 用于 match Ok(pattern) 和 ? 操作符，避免对 ref 类型硬编码 i64_chan
    fn inferThrowOkChanType(self: *IRBuilder, expr: *const ast.Expr) ?ChanType {
        switch (expr.*) {
            .call => |c| {
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => return null,
                };
                // 普通函数调用：查 func_generic_info 的 return_type
                if (self.func_generic_info.get(func_name)) |fgi| {
                    return throwOkChanType(fgi.return_type);
                }
                return null;
            },
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.type_annotation) |ta| {
                        return throwOkChanType(ta);
                    }
                    // 无类型注解：回溯到变量声明的初始表达式，递归推断 Throw Ok 类型
                    // 用于 val h = cast(x).try_to(T); match h { ... } 这种间接绑定
                    if (binding.ast_expr) |src_expr| {
                        return self.inferThrowOkChanType(src_expr);
                    }
                }
                return null;
            },
            // Phase 3 cast builder：cast(x).try_to(T) 的 Ok 值类型 = T
            .cast_builder => |cb| {
                if (cb.mode != .try_to) return null;
                return chanTypeFromTypeNode(cb.target_type);
            },
            else => return null,
        }
    }

    /// 推断表达式的通道类型（用于泛型类型参数推断）
    /// 支持：构造器调用（用 ctor.return_type）、字面量、标识符
    fn inferExprChanType(self: *IRBuilder, expr: *const ast.Expr) ?ChanType {
        switch (expr.*) {
            .call => |c| {
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => return null,
                };
                // 构造器调用：用 return_type 推断（含 GADT 类型参数推断）
                if (self.ctor_table.get(func_name)) |ctor| {
                    return self.inferConstructorChanType(ctor, c.arguments);
                }
                // 普通函数调用：查 return_channel
                if (self.func_table.get(func_name)) |func_idx| {
                    const func = self.functions.items[func_idx];
                    return self.channels.get(func.return_channel).chan_type;
                }
                return null;
            },
            .int_literal => return .i64_chan,
            .float_literal => return .f64_chan,
            .bool_literal => return .bool_chan,
            .string_literal => return .ref_chan,
            .char_literal => return .char_chan,
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    // 如果有类型注解，用类型注解推导（比通道类型更精确）
                    if (binding.type_annotation) |ta| {
                        if (chanTypeFromTypeNode(ta)) |ct| {
                            return ct;
                        }
                    }
                    return self.channels.get(binding.chan).chan_type;
                }
                return null;
            },
            .binary => |b| {
                // 比较运算返回 mask/bool
                return switch (b.op) {
                    .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => .mask_chan,
                    .and_op, .or_op => .bool_chan,
                    else => blk: {
                        // 算术运算继承操作数类型
                        const lt = self.inferExprChanType(b.left) orelse break :blk null;
                        break :blk lt;
                    },
                };
            },
            else => return null,
        }
    }

    /// 检查类型节点是否包含类型参数（单字母大写名）
    fn typeNodeHasTypeParam(type_node: *ast.TypeNode) bool {
        return switch (type_node.*) {
            .named => |n| isTypeNameParam(n.name),
            .generic => |g| {
                for (g.args) |arg| {
                    if (typeNodeHasTypeParam(arg)) return true;
                }
                return false;
            },
            .nullable => |nb| typeNodeHasTypeParam(nb.inner),
            else => false,
        };
    }

    /// 检查名称是否为类型参数（单字母大写名或 T1, T2 等）
    fn isTypeNameParam(name: []const u8) bool {
        if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return true;
        if (name.len == 2 and name[0] >= 'A' and name[0] <= 'Z' and (name[1] >= '0' and name[1] <= '9')) return true;
        return false;
    }

    /// 推断构造器调用的通道类型（含 GADT 类型参数推断）
    /// 对于 If(Expr<bool>, Expr<T>, Expr<T>) : Expr<T>，
    /// 当实参为 (BoolLit, IntLit, IntLit) 时，T=i32，返回 Expr<i32> 的通道类型
    fn inferConstructorChanType(self: *IRBuilder, ctor: CtorInfo, arguments: []*ast.Expr) ?ChanType {
        const rt = ctor.return_type orelse return .ref_chan;

        // 如果返回类型不含类型参数，直接返回
        if (!typeNodeHasTypeParam(rt)) {
            return chanTypeFromTypeNode(rt);
        }

        // 构建类型参数绑定：从字段类型和实参类型推断
        var bindings = std.StringHashMap(ChanType).init(self.allocator);
        defer bindings.deinit();

        const field_count = @min(ctor.fields.len, arguments.len);
        for (0..field_count) |i| {
            const field_type = ctor.fields[i].type_node orelse continue;
            const arg_type = self.inferExprChanType(arguments[i]) orelse continue;
            self.matchTypeParamBinding(field_type, arg_type, &bindings);

            // GADT 路径：从实参的构造器返回类型提取绑定
            self.extractCtorTypeBinding(arguments[i], field_type, &bindings);
        }

        // 用绑定推导返回类型
        return chanTypeWithTypeNode(rt, bindings);
    }

    /// 使用 GADT 绑定栈解析类型节点的通道类型
    /// 从栈顶向下查找类型参数绑定，找到则返回具体类型，否则用 chanTypeFromTypeNode
    fn resolveFieldTypeWithBindings(self: *IRBuilder, type_node: ?*ast.TypeNode) ChanType {
        const tn = type_node orelse return .ref_chan;
        // 如果是命名类型且是类型参数，从绑定栈查找
        if (tn.* == .named) {
            const name = tn.named.name;
            if (self.isTypeParamName(name)) {
                // 从栈顶向下查找绑定
                var i: usize = self.gadt_binding_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.gadt_binding_stack.items[i].get(name)) |ct| return ct;
                }
                // 未找到绑定，默认 i64_chan（兼容值类型和引用类型，i64 能容纳 i32/i64/f64 指针）
                return .i64_chan;
            }
            return chanTypeFromTypeNode(tn) orelse .ref_chan;
        }
        // 泛型类型（如 List<T>）→ ref_chan
        return chanTypeFromTypeNode(tn) orelse .ref_chan;
    }

    /// 从 AST 类型节点 + 泛型绑定映射推导通道类型
    /// type_bindings: 类型参数名 → 具体通道类型（如 "T" → .i32_chan）
    fn chanTypeWithTypeNode(type_node: ?*ast.TypeNode, type_bindings: std.StringHashMap(ChanType)) ?ChanType {
        const tn = type_node orelse return null;
        return switch (tn.*) {
            .named => |n| {
                // 检查是否为泛型类型参数
                if (type_bindings.get(n.name)) |ct| return ct;
                // 否则用普通 chanTypeFromTypeNode
                return chanTypeFromTypeNode(tn);
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "Channel")) return .ref_chan;
                if (std.mem.eql(u8, g.name, "Atomic")) {
                    if (g.args.len > 0) {
                        return chanTypeWithTypeNode(g.args[0], type_bindings);
                    }
                    return .i64_chan;
                }
                // 其他泛型类型如 Expr<T>、List<T> → ref_chan
                return .ref_chan;
            },
            .nullable => |nb| return chanTypeWithTypeNode(nb.inner, type_bindings),
            else => return chanTypeFromTypeNode(tn),
        };
    }

    /// 推断泛型函数调用的返回通道类型
    /// 通过匹配参数类型注解与实参类型，推断类型参数绑定
    fn inferGenericCallReturnType(self: *IRBuilder, func_name: []const u8, arguments: []*ast.Expr) ?ChanType {
        const info = self.func_generic_info.get(func_name) orelse return null;
        if (info.type_params.len == 0) return null; // 非泛型函数

        // 构建类型参数绑定表
        var bindings = std.StringHashMap(ChanType).init(self.allocator);
        defer bindings.deinit();

        // 如果是递归调用当前函数，从 GADT 绑定栈中获取已有的类型参数绑定
        if (self.current_func_name) |cfn| {
            if (std.mem.eql(u8, cfn, func_name)) {
                // 递归调用：从绑定栈顶获取类型参数绑定
                if (self.gadt_binding_stack.items.len > 0) {
                    const top = &self.gadt_binding_stack.items[self.gadt_binding_stack.items.len - 1];
                    var it = top.iterator();
                    while (it.next()) |entry| {
                        bindings.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
                    }
                }
            }
        }

        // 遍历参数，匹配类型注解与实参类型
        const param_count = @min(info.params.len, arguments.len);
        for (0..param_count) |i| {
            const param_type = info.params[i].type_annotation orelse continue;
            const arg_type = self.inferExprChanType(arguments[i]) orelse continue;

            // 尝试从参数类型注解中提取类型参数绑定
            self.matchTypeParamBinding(param_type, arg_type, &bindings);

            // GADT 路径：从构造器返回类型提取绑定
            self.extractCtorTypeBinding(arguments[i], param_type, &bindings);
        }

        // 用绑定推导返回类型
        const result = chanTypeWithTypeNode(info.return_type, bindings);
        return result;
    }

    /// 递归匹配类型参数绑定
    /// param_type: 参数的类型注解（可能含泛型参数 T）
    /// arg_type: 实参的通道类型
    /// bindings: 输出——类型参数名 → 通道类型
    fn matchTypeParamBinding(self: *IRBuilder, param_type: *ast.TypeNode, arg_type: ChanType, bindings: *std.StringHashMap(ChanType)) void {
        switch (param_type.*) {
            .named => |n| {
                // 简单命名类型：检查是否为类型参数
                // 如果参数类型是 T（单字母或已知类型参数名），直接绑定
                if (self.isTypeParamName(n.name)) {
                    if (!bindings.contains(n.name)) {
                        bindings.put(n.name, arg_type) catch {};
                    }
                    return;
                }
                // 已知类型（i32, bool 等）：不绑定
            },
            .generic => {
                // 泛型类型如 Expr<T>：arg_type 是 ref_chan（所有 ADT 都是 ref_chan）
                // 类型参数绑定由 extractCtorTypeBinding 处理（从构造器返回类型提取）
            },
            .nullable => |nb| {
                self.matchTypeParamBinding(nb.inner, arg_type, bindings);
            },
            else => {},
        }
    }

    /// 检查名称是否为类型参数（委托给 isTypeNameParam）
    fn isTypeParamName(self: *IRBuilder, name: []const u8) bool {
        _ = self;
        return isTypeNameParam(name);
    }

    /// 从构造器调用表达式或带类型注解的标识符提取 GADT 类型参数绑定
    /// 例如：Add(IntLit(3), IntLit(4)) 的 return_type 是 Expr<i32>
    /// 匹配参数类型 Expr<T> → T = i32
    /// 对于 If(BoolLit, IntLit, IntLit) : Expr<T>，先从字段类型推断 T=i32，再匹配
    fn extractCtorTypeBinding(self: *IRBuilder, expr: *const ast.Expr, param_type: ?*ast.TypeNode, bindings: *std.StringHashMap(ChanType)) void {
        if (param_type == null) return;
        const pt = param_type.?;

        // 获取实参的类型注解：
        // 1. 构造器调用 → 构造器的 return_type（含类型参数推断）
        // 2. 标识符 → 变量绑定的 type_annotation
        var arg_type_node: ?*ast.TypeNode = null;

        if (expr.* == .call) {
            const func_name = switch (expr.call.callee.*) {
                .identifier => |id| id.name,
                else => return,
            };
            const ctor = self.ctor_table.get(func_name) orelse return;
            const ctor_rt = ctor.return_type orelse return;

            // 如果构造器返回类型含类型参数，先从字段类型和实参推断绑定
            if (typeNodeHasTypeParam(ctor_rt)) {
                // 从字段类型和实参推断构造器自身的类型参数绑定
                const field_count = @min(ctor.fields.len, expr.call.arguments.len);
                for (0..field_count) |i| {
                    const field_type = ctor.fields[i].type_node orelse continue;
                    // 递归提取子构造器的类型绑定
                    self.extractCtorTypeBinding(expr.call.arguments[i], field_type, bindings);
                }
            }

            // 构造器返回类型本身可能含类型参数（如 Expr<T>）
            // 但我们已经从字段推断出了 T 的绑定，所以用 chanTypeWithTypeNode 推导
            // 如果 T 已绑定，chanTypeWithTypeNode 会返回正确的类型
            // 但这里我们需要 TypeNode 而非 ChanType，所以直接用 ctor_rt
            arg_type_node = ctor_rt;
        } else if (expr.* == .identifier) {
            const id = expr.identifier;
            if (self.lookupVar(id.name)) |binding| {
                arg_type_node = binding.type_annotation;
            }
        }
        const arg_tn = arg_type_node orelse return;

        // 参数类型和实参类型都应该是泛型类型如 Expr<T> 和 Expr<i32>
        if (pt.* != .generic or arg_tn.* != .generic) return;
        if (!std.mem.eql(u8, pt.generic.name, arg_tn.generic.name)) return;

        // 匹配类型参数
        const param_args = pt.generic.args;
        const arg_args = arg_tn.generic.args;
        const count = @min(param_args.len, arg_args.len);
        for (0..count) |i| {
            const pa = param_args[i];
            const ca = arg_args[i];
            if (pa.* == .named and ca.* == .named) {
                const tp_name = pa.named.name;
                if (self.isTypeParamName(tp_name)) {
                    // 如果实参的类型实参也是同一个类型参数（如 Expr<T> vs Expr<T>），
                    // 不做绑定（T 未被细化），依赖已从字段推断的绑定
                    if (std.mem.eql(u8, ca.named.name, tp_name)) continue;
                    // 从实参类型的类型实参提取通道类型
                    const ct = chanTypeFromTypeNode(ca) orelse continue;
                    if (!bindings.contains(tp_name)) {
                        bindings.put(tp_name, ct) catch {};
                    }
                }
            }
        }
    }

    /// 编译构造器调用：Ctor(args...) → record_make(type_name, field_count=N+1) + record_set(__tag=0, tag) + record_set(field_id=i+1, val)...
    /// ADT 值用 record 表示，__tag 字段（field_id=0）存储构造器索引（用于 match 分派）
    fn compileConstructorCall(self: *IRBuilder, ctor: CtorInfo, arguments: []*ast.Expr) BuildError!u16 {
        // 构造器参数不在尾位置：防止参数中的函数调用被错误标记为 tail_call
        // （如 BNode(n, bstInsert(lo, v), hi) 中的 bstInsert 不是尾调用）
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        defer self.in_tail_position = saved_tail;

        // Newtype 构造器：在无 sema 时仍用 record 表示（保持字段访问兼容性）
        // 当 sema 接入后，可改用 newtype_wrap 节点
        const rec_chan = try self.allocChannel(.ref_chan);
        // record_make：field_count = __tag(1) + 构造器字段数
        const field_count: u32 = @intCast(ctor.fields.len + 1);
        const make_meta = try self.addRecordMakeMeta(ctor.type_name, field_count);
        try self.emit(Node.makeSink(.record_make, rec_chan, make_meta));

        // 设置 __tag 字段（field_id=0，构造器索引，用于 match 分派）
        const tag_chan = try self.allocChannel(.i64_chan);
        const tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = ctor.tag } });
        try self.emit(Node.makeSink(.const_i, tag_chan, tag_meta));
        const tag_field_meta = try self.addFieldIdMeta(0);
        try self.emit(Node.makeBinary(.record_set, rec_chan, tag_field_meta, rec_chan, tag_chan));

        // 设置各字段（field_id = i+1，因为 0 是 __tag）
        const arg_count = @min(arguments.len, ctor.fields.len);
        for (0..arg_count) |i| {
            const val_chan = try self.compileExpr(arguments[i]);
            const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta, rec_chan, val_chan));
        }
        return rec_chan;
    }

    // ════════════════════════════════════════════
    // match 表达式编译（P0-c）
    // ════════════════════════════════════════════

    /// 为 match arm 推送 GADT 类型绑定
    /// 如果 pattern 是构造器模式（如 Add(a, b)）且构造器有 return_type 注解（如 Expr<i32>），
    /// 且被匹配值的类型包含类型参数（如 Expr<T>），则推断 T 的绑定
    fn pushGadtBindingsForArm(self: *IRBuilder, scrutinee: *ast.Expr, pattern: *const ast.Pattern) void {
        // 类型参数推断：不仅适用于泛型函数，也适用于非泛型函数匹配泛型类型的构造器
        // 例如 filterL(l: List<i32>) 匹配 Cons(x, tail) 时，需推断 T → i32_chan

        // 获取被匹配值的类型注解
        // scrutinee 通常是函数参数（如 expr），查找其类型注解
        var scrutinee_type: ?*ast.TypeNode = null;
        if (scrutinee.* == .identifier) {
            const name = scrutinee.identifier.name;
            // 在当前函数参数中查找类型注解
            if (self.current_func_param_types) |params| {
                for (params) |p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        scrutinee_type = p.type_annotation;
                        break;
                    }
                }
            }
            // 也检查作用域中的变量绑定
            if (scrutinee_type == null) {
                if (self.lookupVar(name)) |binding| {
                    if (binding.type_annotation) |ta| {
                        scrutinee_type = ta;
                    }
                }
            }
        }
        if (scrutinee_type == null) return;

        // 获取 pattern 的构造器名和构造器信息
        const ctor_name = switch (pattern.*) {
            .constructor => |c| c.name,
            else => return, // 非构造器模式：不推送绑定
        };
        const ctor = self.ctor_table.get(ctor_name) orelse return;

        // 获取构造器返回类型（GADT 注解）或从类型表推断
        // GADT 情况：ctor.return_type 存在（如 Expr<i32>），直接与 scrutinee_type 匹配
        // 非 GADT 情况：ctor.return_type 为 null，使用类型表的 type_params 与 scrutinee_type 匹配
        const scrutinee_generic = switch (scrutinee_type.?.*) {
            .generic => |g| g,
            else => return, // scrutinee 不是泛型类型，无法推断
        };

        var bindings = std.StringHashMap(ChanType).init(self.allocator);
        var has_binding = false;

        if (ctor.return_type) |ctor_rt| {
            // GADT 情况：ctor_rt 如 Expr<i32>，scrutinee_type 如 Expr<T>
            if (ctor_rt.* != .generic) {
                bindings.deinit();
                return;
            }
            const ctor_rt_generic = ctor_rt.generic;
            if (!std.mem.eql(u8, scrutinee_generic.name, ctor_rt_generic.name)) {
                bindings.deinit();
                return;
            }
            // 匹配 scrutinee_type 的类型参数（可能为 T）与 ctor_rt 的类型实参（如 i32）
            const param_args = scrutinee_generic.args;
            const ctor_args = ctor_rt_generic.args;
            const count = @min(param_args.len, ctor_args.len);
            for (0..count) |i| {
                const pa = param_args[i];
                const ca = ctor_args[i];
                if (pa.* == .named and ca.* == .named) {
                    const tp_name = pa.named.name;
                    if (self.isTypeParamName(tp_name)) {
                        // 如果构造器返回类型的实参也是同一个类型参数（如 Expr<T> vs Expr<T>），
                        // 则不做绑定（T 未被细化）
                        if (std.mem.eql(u8, ca.named.name, tp_name)) continue;
                        const ct = chanTypeFromTypeNode(ca) orelse continue;
                        bindings.put(tp_name, ct) catch {};
                        has_binding = true;
                    }
                }
            }
        } else {
            // 非 GADT 情况：使用类型表的 type_params 推断
            // scrutinee_type 如 List<i32>，类型 List 有 type_params [T] → T = i32
            const type_info = self.type_table.get(ctor.type_name) orelse {
                bindings.deinit();
                return;
            };
            if (!std.mem.eql(u8, scrutinee_generic.name, type_info.name)) {
                bindings.deinit();
                return;
            }
            const type_params = type_info.type_params;
            const scrutinee_args = scrutinee_generic.args;
            const count = @min(type_params.len, scrutinee_args.len);
            for (0..count) |i| {
                const tp_name = type_params[i].name;
                if (!self.isTypeParamName(tp_name)) continue;
                const ca = scrutinee_args[i];
                const ct = chanTypeFromTypeNode(ca) orelse continue;
                bindings.put(tp_name, ct) catch {};
                has_binding = true;
            }
        }

        if (has_binding) {
            self.gadt_binding_stack.append(self.allocator, bindings) catch {
                bindings.deinit();
            };
        } else {
            bindings.deinit();
        }
    }

    /// 弹出 GADT 类型绑定栈顶
    fn popGadtBindings(self: *IRBuilder) void {
        if (self.gadt_binding_stack.pop()) |*bindings| {
            var b = bindings.*;
            b.deinit();
        }
    }

    /// 编译 match 表达式：match scrutinee { arm1 => body1, ... }
    /// 策略：转换为嵌套 if-else 链，每个 arm 用 route_dispatch 选择
    fn compileMatch(self: *IRBuilder, scrutinee: *ast.Expr, arms: []const ast.MatchArm) BuildError!u16 {
        const scrutinee_chan = try self.compileExpr(scrutinee);
        // 推断 scrutinee 的 Throw Ok 类型，用于 Ok(pattern) 中 ok_val_chan 的类型
        // 避免 ref 类型 Ok 值被硬编码为 i64_chan 导致指针丢失
        const saved_ok_type = self.current_throw_ok_chan_type;
        if (self.inferThrowOkChanType(scrutinee)) |ok_type| {
            self.current_throw_ok_chan_type = ok_type;
        }
        defer self.current_throw_ok_chan_type = saved_ok_type;
        return try self.compileMatchArms(scrutinee, scrutinee_chan, arms, 0);
    }

    /// 判断模式是否总是匹配（无需 route_dispatch 条件选择）
    /// wildcard/变量绑定/单构造器类型的构造器模式（含全变量子模式）总是匹配
    fn patternAlwaysMatches(self: *IRBuilder, pattern: *const ast.Pattern) bool {
        switch (pattern.*) {
            .wildcard => return true,
            .variable => |v| {
                if (self.ctor_table.get(v.name)) |ctor| {
                    if (ctor.fields.len != 0) return false;
                    if (self.type_table.get(ctor.type_name)) |ti| return ti.constructors.len == 1;
                    return false;
                }
                return true;
            },
            .constructor => |c| {
                const ctor = self.ctor_table.get(c.name) orelse return false;
                const ti = self.type_table.get(ctor.type_name) orelse return false;
                if (ti.constructors.len != 1) return false;
                for (c.patterns) |sub| {
                    if (!self.patternAlwaysMatches(sub)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// 跳表优化：所有 arms 都是同一 ADT 构造器模式时，用 __tag 直接索引替代线性比较
    /// 条件：arms >= 2，全部为构造器模式（或无参构造器变量），无 guard，子模式为变量/通配符
    /// 优化效果：O(N) 嵌套 route_dispatch 链 → O(1) tag 索引分派
    /// 适用场景：枚举分派（如 colorToValue、tokenWeight、exprDepth）
    fn tryCompileJumpTableMatch(self: *IRBuilder, scrutinee: *ast.Expr, scrutinee_chan: u16, arms: []const ast.MatchArm) BuildError!?u16 {
        // 条件 1: 至少 2 个 arms
        if (arms.len < 2) return null;

        // 条件 2: 所有 arms 为构造器模式（或无参构造器变量），无 guard，子模式为变量/通配符
        var common_type_name: ?[]const u8 = null;
        for (arms) |arm| {
            if (arm.guard != null) return null;
            const ctor_name: ?[]const u8 = switch (arm.pattern.*) {
                .constructor => |c| blk: {
                    for (c.patterns) |sub| {
                        switch (sub.*) {
                            .wildcard, .variable => {},
                            else => break :blk null,
                        }
                    }
                    break :blk c.name;
                },
                .variable => |v| blk: {
                    if (self.ctor_table.get(v.name)) |ctor| {
                        if (ctor.fields.len == 0) break :blk v.name;
                    }
                    break :blk null;
                },
                else => null,
            };
            if (ctor_name == null) return null;

            const ctor = self.ctor_table.get(ctor_name.?) orelse return null;
            if (common_type_name) |ctn| {
                if (!std.mem.eql(u8, ctn, ctor.type_name)) return null;
            } else {
                common_type_name = ctor.type_name;
            }
        }

        const type_name = common_type_name orelse return null;
        const type_info = self.type_table.get(type_name) orelse return null;

        // 条件 3: ADT 有 > 1 个构造器（单构造器已有优化路径），且不超过 u8 容量
        if (type_info.constructors.len <= 1) return null;
        if (type_info.constructors.len > 255) return null;

        const arena_alloc = self.arena.allocator();
        const ctor_count = type_info.constructors.len;

        // 读取 __tag（field_id=0）一次，作为 route_dispatch 的 winner 索引
        const tag_field_meta = try self.addFieldIdMeta(0);
        const tag_chan = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeUnary(.record_get, tag_chan, tag_field_meta, scrutinee_chan));

        // 为每个构造器编译 body 子图（按 tag 索引）
        const body_starts = try arena_alloc.alloc(u32, ctor_count);
        const body_lens = try arena_alloc.alloc(u32, ctor_count);

        var result_type: ?ChanType = null;

        for (type_info.constructors, 0..) |ctor, tag_idx| {
            // 查找该构造器对应的 arm（线性搜索，arm 数量通常 < 10）
            var found_arm_idx: ?usize = null;
            for (arms, 0..) |arm, i| {
                const name_match = switch (arm.pattern.*) {
                    .constructor => |c| std.mem.eql(u8, c.name, ctor.name),
                    .variable => |v| std.mem.eql(u8, v.name, ctor.name),
                    else => false,
                };
                if (name_match) {
                    found_arm_idx = i;
                    break;
                }
            }

            const body_start: u32 = @intCast(self.nodes.items.len);

            if (found_arm_idx) |arm_idx| {
                const arm = arms[arm_idx];

                try self.pushScope();
                self.pushGadtBindingsForArm(scrutinee, arm.pattern);

                // 读取字段并绑定变量（子模式已确认为变量/通配符，总是匹配）
                const sub_patterns: []*ast.Pattern = switch (arm.pattern.*) {
                    .constructor => |c| c.patterns,
                    else => &.{}, // 无参构造器变量模式
                };
                const sub_count = @min(sub_patterns.len, ctor.fields.len);
                for (0..sub_count) |i| {
                    const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                    const field_chan_type = self.resolveFieldTypeWithBindings(ctor.fields[i].type_node);
                    const field_chan = try self.allocChannel(field_chan_type);
                    try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                    const prev_hint = self.pattern_type_hint;
                    self.pattern_type_hint = ctor.fields[i].type_node;
                    _ = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                    self.pattern_type_hint = prev_hint;
                }

                // 编译 body（追踪 body 表达式起始，若 body 无节点则补 load 确保最后节点是 body 输出）
                const body_expr_start: u32 = @intCast(self.nodes.items.len);
                const body_chan = try self.compileExpr(arm.body);
                if (self.nodes.items.len == body_expr_start) {
                    const load_chan = try self.allocChannel(self.channels.get(body_chan).chan_type);
                    try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
                }

                self.popGadtBindings();
                self.popScope();

                // 记录结果类型（取第一个真实 arm 的 body 最后节点输出类型）
                if (result_type == null) {
                    const body_len_tmp: u32 = @intCast(self.nodes.items.len - body_start);
                    result_type = self.channels.get(self.nodes.items[body_start + body_len_tmp - 1].output).chan_type;
                }
            } else {
                // 该构造器无对应 arm — default body 返回 unit（仅非穷尽 match 触发，sema 应拒绝）
                const unit_chan = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.const_unit, unit_chan, 0));
            }

            const body_len: u32 = @intCast(self.nodes.items.len - body_start);
            body_starts[tag_idx] = body_start;
            body_lens[tag_idx] = body_len;
        }

        // 结果通道
        const result_chan = try self.allocChannel(result_type orelse .unit_chan);

        // route_dispatch with N entries indexed by tag
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = @intCast(ctor_count),
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, tag_chan));

        return result_chan;
    }

    /// 递归编译 match arms：当前 arm + 剩余 arms（else 分支）
    fn compileMatchArms(self: *IRBuilder, scrutinee: *ast.Expr, scrutinee_chan: u16, arms: []const ast.MatchArm, start_idx: usize) BuildError!u16 {
        // 跳表优化入口：首层 match 且所有 arms 为同一 ADT 构造器模式时，用 __tag 直接索引
        if (start_idx == 0) {
            if (try self.tryCompileJumpTableMatch(scrutinee, scrutinee_chan, arms)) |result_chan| {
                return result_chan;
            }
        }

        if (start_idx >= arms.len) {
            // 无匹配 arm：返回 unit（实际应由 wildcard 兜底）
            const out = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeSink(.const_unit, out, 0));
            return out;
        }

        const arm = arms[start_idx];

        // 单 arm 无 guard 且 pattern 总是匹配时，跳过 route_dispatch
        // 直接编译 pattern check（绑定变量）+ body，无需条件选择
        if (start_idx == arms.len - 1 and arm.guard == null and self.patternAlwaysMatches(arm.pattern)) {
            try self.pushScope();
            self.pushGadtBindingsForArm(scrutinee, arm.pattern);
            _ = try self.compilePatternCheck(scrutinee_chan, arm.pattern);
            const then_start: u32 = @intCast(self.nodes.items.len);
            const body_chan = try self.compileExpr(arm.body);
            if (self.nodes.items.len == then_start) {
                const load_chan = try self.allocChannel(self.channels.get(body_chan).chan_type);
                try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
            }
            self.popGadtBindings();
            self.popScope();
            return body_chan;
        }

        const arena_alloc = self.arena.allocator();

        // push scope for pattern variables（check 和 then body 共享）
        try self.pushScope();

        // GADT 类型推断：在 pattern check 之前推送类型参数绑定
        // 这样 compileConstructorPattern 中的 resolveFieldTypeWithBindings 能查到绑定
        var pushed_bindings = false;
        self.pushGadtBindingsForArm(scrutinee, arm.pattern);
        pushed_bindings = true;
        defer if (pushed_bindings) self.popGadtBindings();

        // 编译 pattern check → cond_chan（bool），同时绑定模式变量
        const pat_cond_chan = try self.compilePatternCheck(scrutinee_chan, arm.pattern);

        // 处理 guard：cond = pattern_match AND guard
        const final_cond_chan = if (arm.guard) |guard| blk: {
            const guard_chan = try self.compileExpr(guard);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta_idx = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta_idx, pat_cond_chan, guard_chan));
            break :blk and_chan;
        } else pat_cond_chan;

        // arm 1 = then 子图（pattern 变量在作用域内）
        const then_start: u32 = @intCast(self.nodes.items.len);
        const body_chan = try self.compileExpr(arm.body);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // pop scope（pattern 变量不再按名可见）
        self.popScope();

        // arm 0 = else 子图（剩余 arms，无 pattern 变量）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_chan = try self.compileMatchArms(scrutinee, scrutinee_chan, arms, start_idx + 1);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(self.channels.get(else_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // winner: bool → i64（true=1→then, false=0→else）
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, final_cond_chan));

        // 结果类型继承 then 分支
        const then_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_chan = try self.allocChannel(then_type);

        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译模式检查：返回 bool 通道（是否匹配），同时绑定模式变量到作用域
    fn compilePatternCheck(self: *IRBuilder, scrutinee_chan: u16, pattern: *const ast.Pattern) BuildError!u16 {
        switch (pattern.*) {
            .wildcard => {
                return try self.emitConstBool(true);
            },
            .variable => |v| {
                // 如果变量名是已知构造器（enum variant），作为无参构造器模式处理
                if (self.ctor_table.get(v.name)) |ctor| {
                    if (ctor.fields.len == 0) {
                        return try self.compileConstructorPattern(scrutinee_chan, v.name, &.{});
                    }
                }
                // 绑定变量到 scrutinee，附带类型提示（从构造器字段类型继承）
                try self.scopeVarTyped(v.name, scrutinee_chan, false, null, self.pattern_type_hint);
                return try self.emitConstBool(true);
            },
            .literal => |lit| {
                return try self.compileLiteralPattern(scrutinee_chan, lit);
            },
            .constructor => |c| {
                return try self.compileConstructorPattern(scrutinee_chan, c.name, c.patterns);
            },
            .record => |r| {
                return try self.compileRecordPattern(scrutinee_chan, r.fields);
            },
            .or_pattern => |op| {
                // left OR right（变量绑定在两侧都发生，应绑定同名变量）
                const left_chan = try self.compilePatternCheck(scrutinee_chan, op.left);
                const right_chan = try self.compilePatternCheck(scrutinee_chan, op.right);
                const out = try self.allocChannel(.bool_chan);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_or, out, meta, left_chan, right_chan));
                return out;
            },
            .guard => |g| {
                // pattern AND condition
                const pat_chan = try self.compilePatternCheck(scrutinee_chan, g.pattern);
                const cond_chan = try self.compileExpr(g.condition);
                const out = try self.allocChannel(.bool_chan);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, out, meta, pat_chan, cond_chan));
                return out;
            },
        }
    }

    /// 发射 const_bool 节点
    fn emitConstBool(self: *IRBuilder, val: bool) BuildError!u16 {
        const out = try self.allocChannel(.bool_chan);
        const meta = try self.addScalarMeta(.{ .kind = .bool, .const_val = .{ .bool_val = val } });
        try self.emit(Node.makeSink(.const_bool, out, meta));
        return out;
    }

    /// 编译字面量模式：scrutinee == literal
    fn compileLiteralPattern(self: *IRBuilder, scrutinee_chan: u16, lit: ast.PatternLiteral) BuildError!u16 {
        switch (lit) {
            .int => |raw| {
                const lit_chan = try self.compileIntLiteral(raw, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .float => |raw| {
                const lit_chan = try self.compileFloatLiteral(raw, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .bool => |b| {
                const lit_chan = try self.emitConstBool(b);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .char => |c| {
                const lit_chan = try self.allocChannel(.char_chan);
                const meta = try self.addScalarMeta(.{ .kind = .char, .const_val = .{ .char_val = c } });
                try self.emit(Node.makeSink(.const_char, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .string => |s| {
                const lit_chan = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(s);
                const meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .null => {
                // null 检查：nullable_is_null（仅对 nullable_chan 有效）
                const out = try self.allocChannel(.bool_chan);
                try self.emit(Node.makeUnary(.nullable_is_null, out, 0, scrutinee_chan));
                return out;
            },
        }
    }

    /// 发射 cmp_eq 节点：left == right → mask_chan
    fn emitCmpEq(self: *IRBuilder, left_chan: u16, right_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(.mask_chan);
        const meta = try self.addScalarMeta(.{ .kind = .bool });
        try self.emit(Node.makeBinary(.cmp_eq, out, meta, left_chan, right_chan));
        return out;
    }

    /// 编译构造器模式：Ctor(sub_patterns...)
    /// 检查 __tag == ctor.tag，然后递归检查各字段子模式
    fn compileConstructorPattern(self: *IRBuilder, scrutinee_chan: u16, ctor_name: []const u8, sub_patterns: []*ast.Pattern) BuildError!u16 {
        // 内置构造器模式：Ok(...) / Error(...) — ThrowValue 解构
        if (std.mem.eql(u8, ctor_name, "Ok")) {
            // gate_check → is_ok
            const is_ok_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            if (sub_patterns.len == 0) return is_ok_chan;
            // gate_get_ok → 绑定到子模式（使用 current_throw_ok_chan_type 推断类型）
            const ok_val_chan = try self.allocChannel(self.current_throw_ok_chan_type);
            try self.emit(Node.makeUnary(.gate_get_ok, ok_val_chan, 0, scrutinee_chan));
            const sub_check = try self.compilePatternCheck(ok_val_chan, sub_patterns[0]);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_ok_chan, sub_check));
            return and_chan;
        }
        if (std.mem.eql(u8, ctor_name, "Error")) {
            // gate_check → is_ok, 然后 not is_ok → is_err
            const is_ok_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            const is_err_chan = try self.allocChannel(.bool_chan);
            const not_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeUnary(.bool_not, is_err_chan, not_meta, is_ok_chan));
            if (sub_patterns.len == 0) return is_err_chan;
            // gate_get_err → 绑定到子模式
            const err_val_chan = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.gate_get_err, err_val_chan, 0, scrutinee_chan));
            const sub_check = try self.compilePatternCheck(err_val_chan, sub_patterns[0]);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_err_chan, sub_check));
            return and_chan;
        }

        const ctor = self.ctor_table.get(ctor_name) orelse return error.UndefinedFunction;

        // 单构造器类型优化：若类型只有一个构造器，__tag 永远为 0，tag 检查恒为真
        // 跳过 record_get(__tag) + const_i + cmp_eq + cast + route_dispatch + const_bool(false)
        // 直接读取字段并 AND 子模式检查
        const is_single_ctor = blk: {
            if (self.type_table.get(ctor.type_name)) |type_info| {
                break :blk type_info.constructors.len == 1;
            }
            break :blk false;
        };
        if (is_single_ctor) {
            const sub_count = @min(sub_patterns.len, ctor.fields.len);
            if (sub_count == 0) return try self.emitConstBool(true);
            // 全变量/通配符子模式：跳过 AND 链，直接读取字段并绑定
            // Point(x, y) 等 destructure 模式的子模式总是变量绑定，AND 链冗余
            var all_var = true;
            for (sub_patterns[0..sub_count]) |sub| {
                switch (sub.*) {
                    .wildcard, .variable => {},
                    else => all_var = false,
                }
            }
            if (all_var) {
                for (0..sub_count) |i| {
                    const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                    const field_chan_type = self.resolveFieldTypeWithBindings(ctor.fields[i].type_node);
                    const field_chan = try self.allocChannel(field_chan_type);
                    try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                    const prev_hint = self.pattern_type_hint;
                    self.pattern_type_hint = ctor.fields[i].type_node;
                    _ = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                    self.pattern_type_hint = prev_hint;
                }
                return try self.emitConstBool(true);
            }
            var result_chan = try self.emitConstBool(true);
            for (0..sub_count) |i| {
                const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                const field_chan_type = self.resolveFieldTypeWithBindings(ctor.fields[i].type_node);
                const field_chan = try self.allocChannel(field_chan_type);
                try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                const prev_hint = self.pattern_type_hint;
                self.pattern_type_hint = ctor.fields[i].type_node;
                const sub_check_chan = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                self.pattern_type_hint = prev_hint;
                const and_chan = try self.allocChannel(.bool_chan);
                const and_meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, result_chan, sub_check_chan));
                result_chan = and_chan;
            }
            return result_chan;
        }

        const arena_alloc = self.arena.allocator();

        // 读取 __tag 字段（field_id=0）
        const tag_field_meta = try self.addFieldIdMeta(0);
        const tag_chan = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeUnary(.record_get, tag_chan, tag_field_meta, scrutinee_chan));

        // 期望的 tag 值
        const expected_tag_chan = try self.allocChannel(.i64_chan);
        const expected_tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = ctor.tag } });
        try self.emit(Node.makeSink(.const_i, expected_tag_chan, expected_tag_meta));

        // 比较 tag → tag_cond
        const tag_cond = try self.emitCmpEq(tag_chan, expected_tag_chan);

        // 无子模式：直接返回 tag 检查结果（不需要读字段）
        const sub_count = @min(sub_patterns.len, ctor.fields.len);
        if (sub_count == 0) return tag_cond;

        // 有子模式：字段读取在 tag 匹配时才执行
        // 用 route_dispatch 条件执行（与 compileIf 相同的子图模式）
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, tag_cond));

        // arm 0 = else 子图（tag 不匹配 → false）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const false_chan = try self.emitConstBool(false);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.load, load_chan, 0, false_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图（tag 匹配 → 读字段，检查子模式）
        const then_start: u32 = @intCast(self.nodes.items.len);
        var result_chan = try self.emitConstBool(true);
        for (0..sub_count) |i| {
            // 读取字段值（field_id = i+1，因为 0 是 __tag）
            const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
            // 字段类型：用 type_node 推导，类型参数通过 GADT 绑定栈解析
            const field_chan_type = self.resolveFieldTypeWithBindings(ctor.fields[i].type_node);
            const field_chan = try self.allocChannel(field_chan_type);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            // 设置模式类型提示（供变量绑定使用类型注解）
            const prev_hint = self.pattern_type_hint;
            self.pattern_type_hint = ctor.fields[i].type_node;

            // 递归检查子模式（同时绑定模式变量）
            const sub_check_chan = try self.compilePatternCheck(field_chan, sub_patterns[i]);

            // 恢复类型提示
            self.pattern_type_hint = prev_hint;

            // AND 到当前结果
            const and_chan = try self.allocChannel(.bool_chan);
            const and_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, result_chan, sub_check_chan));
            result_chan = and_chan;
        }
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.load, load_chan, 0, result_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // route_dispatch 按 winner 索引执行对应子图
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const result_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_out = try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_out, route_meta_idx, winner_chan));
        return result_out;
    }

    /// 编译记录模式：(field1: pat1, field2: pat2, ...)
    /// 字段名通过 field_id_map 解析为 field_id（record literal 的字段按声明顺序 0..N-1）
    fn compileRecordPattern(self: *IRBuilder, scrutinee_chan: u16, fields: []const ast.PatternRecordField) BuildError!u16 {
        if (fields.len == 0) return try self.emitConstBool(true);

        var result_chan: ?u16 = null;
        for (fields, 0..) |field, i| {
            // 查找 field_id；若未注册（匿名 record literal 模式），按声明顺序用 i
            const field_id: u16 = self.lookupFieldId("", field.name) orelse @intCast(i);
            const field_meta = try self.addFieldIdMeta(field_id);
            const field_chan = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            const sub_check = try self.compilePatternCheck(field_chan, field.pattern);

            if (result_chan) |rc| {
                const and_chan = try self.allocChannel(.bool_chan);
                const and_meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, rc, sub_check));
                result_chan = and_chan;
            } else {
                result_chan = sub_check;
            }
        }
        return result_chan.?;
    }

    // ════════════════════════════════════════════
    // 星轨编译（async/spawn，Phase 5）
    // ════════════════════════════════════════════

    /// 发射 orbit_async_create 节点：创建异步轨道，返回 handle 通道
    fn emitOrbitCreate(self: *IRBuilder, func_idx: u16, arg_chans: []const u16, func: Function) BuildError!u16 {
        // handle 通道：ref_chan 存储轨道句柄
        const handle_chan = try self.allocChannel(.ref_chan);
        const result_type = self.channels.get(func.return_channel).chan_type;

        const orbit_meta_idx = try self.addOrbitMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arg_chans.len),
            .result_type = result_type,
            .is_spawn = false,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .orbit_async_create,
            .input_count = @intCast(@min(arg_chans.len, 4)),
            .output = handle_chan,
            .meta_index = orbit_meta_idx,
            .inputs = inputs,
        });
        return handle_chan;
    }

    /// 发射 orbit_async_join 节点：等待轨道完成，返回结果通道
    pub fn emitOrbitJoin(self: *IRBuilder, handle_chan: u16, orbit_meta_idx: u16) BuildError!u16 {
        const orbit_meta = self.orbit_metas.items[orbit_meta_idx - 1];
        const result_chan = try self.allocChannel(orbit_meta.result_type);
        try self.emit(Node.makeUnary(.orbit_async_join, result_chan, orbit_meta_idx, handle_chan));
        return result_chan;
    }

    /// 发射 orbit_chan_send 节点：向轨道通道发送值
    pub fn emitOrbitSend(self: *IRBuilder, handle_chan: u16, val_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeBinary(.orbit_chan_send, out, 0, handle_chan, val_chan));
        return out;
    }

    /// 发射 orbit_chan_recv 节点：从轨道通道接收值（阻塞）
    pub fn emitOrbitRecv(self: *IRBuilder, handle_chan: u16, result_type: ChanType) BuildError!u16 {
        const out = try self.allocChannel(result_type);
        try self.emit(Node.makeUnary(.orbit_chan_recv, out, 0, handle_chan));
        return out;
    }

    /// 发射 orbit_chan_try_recv 节点：非阻塞接收，返回 nullable
    pub fn emitOrbitTryRecv(self: *IRBuilder, handle_chan: u16, inner_type: ChanType) BuildError!u16 {
        const out = try self.allocChannel(.nullable_chan);
        _ = inner_type;
        try self.emit(Node.makeUnary(.orbit_chan_try_recv, out, 0, handle_chan));
        return out;
    }

    // ════════════════════════════════════════════
    // 语句编译
    // ════════════════════════════════════════════

    fn compileBlock(self: *IRBuilder, statements: []*ast.Stmt, trailing_expr: ?*ast.Expr) BuildError!u16 {
        try self.pushScope();
        defer self.popScope();

        // statements 不在尾位置：防止 val_decl 中的函数调用被错误标记为 tail_call
        // 只有 trailing_expr 继承尾位置
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        var last_stmt_chan: ?u16 = null;
        for (statements) |stmt| {
            last_stmt_chan = try self.compileStmt(stmt);
        }
        self.in_tail_position = saved_tail;

        if (trailing_expr) |te| {
            return self.compileExpr(te);
        }
        // 无尾表达式：如果最后一条语句产生了值（for/while），使用它
        if (last_stmt_chan) |ch| return ch;
        // 否则返回 unit
        const out = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.const_unit, out, 0));
        return out;
    }

    fn compileStmt(self: *IRBuilder, stmt: *const ast.Stmt) BuildError!?u16 {
        switch (stmt.*) {
            .val_decl => |vd| {
                // 对于 lambda 值，预声明名字以支持递归引用
                if (vd.value.* == .lambda) {
                    self.pre_declared_lambda_names.append(self.allocator, vd.name) catch return error.OutOfMemory;
                    const chan = try self.compileExpr(vd.value);
                    _ = self.pre_declared_lambda_names.pop();
                    // lambda 编译时已在 compileLambda 中预声明了名字，
                    // 但仍需确保 binding 存储了 ast_expr（用于类型推断）
                    // 查找已有 binding 并更新 ast_expr
                    self.updateVarAstExpr(vd.name, vd.value);
                    _ = chan;
                } else {
                    var chan = try self.compileExpr(vd.value);
                    // 类型标注为 nullable 时，将值包装为 nullable_chan
                    if (vd.type_annotation) |tn| {
                        if (tn.* == .nullable) {
                            const value_meta = self.channels.get(chan);
                            if (value_meta.chan_type == .null_chan) {
                                // null_literal → 分配 nullable 通道，nullable_make 会写入 null flag
                                const inner_ct = chanTypeFromTypeNode(tn.nullable.inner) orelse .ref_chan;
                                const nc = try self.channels.allocNullable(inner_ct);
                                try self.emit(Node.makeUnary(.nullable_make, nc, 0, chan));
                                chan = nc;
                            } else if (value_meta.chan_type != .nullable_chan) {
                                // 非 null 值 → 包装为 nullable
                                const nc = try self.channels.allocNullable(value_meta.chan_type);
                                try self.emit(Node.makeUnary(.nullable_make, nc, 0, chan));
                                chan = nc;
                            }
                        }
                    }
                    try self.scopeVarTyped(vd.name, chan, false, vd.value, vd.type_annotation);
                }
            },
            .var_decl => |vd| {
                var value_chan = try self.compileExpr(vd.value);
                var value_meta = self.channels.get(value_chan);
                // 类型标注为 nullable 时，将值包装为 nullable_chan
                if (vd.type_annotation) |tn| {
                    if (tn.* == .nullable) {
                        if (value_meta.chan_type == .null_chan) {
                            const inner_ct = chanTypeFromTypeNode(tn.nullable.inner) orelse .ref_chan;
                            const nc = try self.channels.allocNullable(inner_ct);
                            try self.emit(Node.makeUnary(.nullable_make, nc, 0, value_chan));
                            value_chan = nc;
                            value_meta = self.channels.get(value_chan);
                        } else if (value_meta.chan_type != .nullable_chan) {
                            const nc = try self.channels.allocNullable(value_meta.chan_type);
                            try self.emit(Node.makeUnary(.nullable_make, nc, 0, value_chan));
                            value_chan = nc;
                            value_meta = self.channels.get(value_chan);
                        }
                    }
                }
                // 优先使用类型标注的 chan_type 作为 cell 类型；
                // 这避免了字面量默认类型（如 usize）与标注类型（如 i32）不匹配时
                // 引发的跨通道字节宽度错误（execCmp 读取超过源通道实际宽度）。
                const cell_ct = blk: {
                    if (vd.type_annotation) |tn| {
                        if (tn.* != .nullable) {
                            if (chanTypeFromTypeNode(tn)) |ct| break :blk ct;
                        }
                    }
                    break :blk value_meta.chan_type;
                };
                const cell_chan = try self.allocCellChannel(cell_ct);
                try self.emit(Node.makeUnary(.load, cell_chan, 0, value_chan));
                try self.scopeVarTyped(vd.name, cell_chan, true, vd.value, vd.type_annotation);
            },
            .assignment => |as| {
                switch (as.target.*) {
                    .identifier => |id| {
                        const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                        const value_chan = try self.compileExpr(as.value);
                        try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
                    },
                    .field_access => |fa| {
                        // obj.field = value → record_set(obj, field_id, value)
                        const obj_chan = try self.compileExpr(fa.object);
                        const value_chan = try self.compileExpr(as.value);
                        const field_id: u16 = blk: {
                            if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                            if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                                if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                            }
                            if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                            break :blk 0;
                        };
                        const field_idx_meta = try self.addFieldIdMeta(field_id);
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, value_chan));
                    },
                    .index => |idx| {
                        // arr[i] = value → array_set(arr, idx, value)
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const value_chan = try self.compileExpr(as.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, value_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .compound_assignment => |ca| {
                switch (ca.target.*) {
                    .identifier => |id| {
                        const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                        const bin_op: ast.BinaryOp = switch (ca.op) {
                            .add_assign => .add,
                            .sub_assign => .sub,
                            .mul_assign => .mul,
                            .div_assign => .div,
                            .mod_assign => .mod,
                            .bit_and_assign => .bit_and,
                            .bit_or_assign => .bit_or,
                            .bit_xor_assign => .bit_xor,
                            .shl_assign => .shl,
                            .shr_assign => .shr,
                        };
                        const result_chan = try self.compileBinary(bin_op, ca.target, ca.value);
                        try self.emit(Node.makeUnary(.store, binding.chan, 0, result_chan));
                    },
                    .field_access => |fa| {
                        // obj.field op= value → record_get + op + record_set
                        const obj_chan = try self.compileExpr(fa.object);
                        const old_val_chan = try self.compileFieldAccess(fa.object, fa.field, ca.target);
                        const bin_op: ast.BinaryOp = switch (ca.op) {
                            .add_assign => .add,
                            .sub_assign => .sub,
                            .mul_assign => .mul,
                            .div_assign => .div,
                            .mod_assign => .mod,
                            .bit_and_assign => .bit_and,
                            .bit_or_assign => .bit_or,
                            .bit_xor_assign => .bit_xor,
                            .shl_assign => .shl,
                            .shr_assign => .shr,
                        };
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        // 解析 field_id
                        const field_id: u16 = blk: {
                            if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                            if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                                if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                            }
                            if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                            break :blk 0;
                        };
                        const field_idx_meta = try self.addFieldIdMeta(field_id);
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, result_chan));
                    },
                    .index => |idx| {
                        // arr[i] op= value → array_get + op + array_set
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const old_val_chan = try self.allocChannel(.ref_chan);
                        try self.emit(Node.makeBinary(.array_get, old_val_chan, 0, obj_chan, idx_chan));
                        const bin_op: ast.BinaryOp = switch (ca.op) {
                            .add_assign => .add,
                            .sub_assign => .sub,
                            .mul_assign => .mul,
                            .div_assign => .div,
                            .mod_assign => .mod,
                            .bit_and_assign => .bit_and,
                            .bit_or_assign => .bit_or,
                            .bit_xor_assign => .bit_xor,
                            .shl_assign => .shl,
                            .shr_assign => .shr,
                        };
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, result_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .expression => |es| {
                _ = try self.compileExpr(es.expr);
            },
            .return_stmt => |rs| {
                const ret_chan = self.current_return_chan orelse return error.UnsupportedStmt;
                const raw_chan = if (rs.value) |v| try self.compileExpr(v) else blk: {
                    const ch = try self.allocChannel(.unit_chan);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                };
                const throw_wrapped = if (self.current_returns_throw and rs.value != null and !self.exprIsThrowValue(rs.value.?)) blk: {
                    const wrap_out = try self.allocChannel(.ref_chan);
                    const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
                    try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, raw_chan));
                    break :blk wrap_out;
                } else raw_chan;
                // 若返回通道为 nullable，包装返回值
                const ret_meta = self.channels.get(ret_chan);
                const value_chan = if (ret_meta.chan_type == .nullable_chan) blk: {
                    const body_meta = self.channels.get(throw_wrapped);
                    if (body_meta.chan_type == .nullable_chan) break :blk throw_wrapped;
                    const nc = try self.channels.allocNullable(ret_meta.inner_type);
                    try self.emit(Node.makeUnary(.nullable_make, nc, 0, throw_wrapped));
                    break :blk nc;
                } else throw_wrapped;
                try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, value_chan));
            },
            .for_stmt => |fs| return try self.compileFor(fs),
            .while_stmt => |ws| return try self.compileWhile(ws),
            .loop_stmt => |ls| return try self.compileLoop(ls),
            .break_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_break, out, 0));
                return out;
            },
            .continue_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_continue, out, 0));
                return out;
            },
            .defer_stmt => |ds| try self.compileDefer(ds),
            .throw_stmt => |ts| return try self.compileThrow(ts),
            .field_assignment => |fa| {
                const obj_chan = try self.compileExpr(fa.object);
                const val_chan = try self.compileExpr(fa.value);
                // 解析 field_id
                const field_id: u16 = blk: {
                    if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                    if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                        if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                    }
                    if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                    break :blk 0;
                };
                const field_meta_idx = try self.addFieldIdMeta(field_id);
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeBinary(.record_set, out, field_meta_idx, obj_chan, val_chan));
            },
        }
        return null;
    }

    // ════════════════════════════════════════════
    // 辅助函数
    // ════════════════════════════════════════════

    fn addString(self: *IRBuilder, s: []const u8) usize {
        const idx = self.string_pool.items.len;
        self.string_pool.append(self.arena.allocator(), s) catch {};
        return idx;
    }

    // ── field_id 映射辅助 ──

    /// 构造 field_id_map 的 key："type_name\x00field_name"
    /// 用 NUL 分隔避免歧义（标识符不含 NUL）
    /// key 从 arena 分配以持久化（StringHashMap 存储 key 切片引用）
    fn makeFieldKey(self: *IRBuilder, type_name: []const u8, field_name: []const u8) ![]u8 {
        const arena_alloc = self.arena.allocator();
        const key = try arena_alloc.alloc(u8, type_name.len + 1 + field_name.len);
        @memcpy(key[0..type_name.len], type_name);
        key[type_name.len] = 0;
        @memcpy(key[type_name.len + 1 ..], field_name);
        return key;
    }

    /// 注册 field_id 映射（已存在则覆盖）
    fn registerFieldId(self: *IRBuilder, type_name: []const u8, field_name: []const u8, field_id: u16) void {
        const key = self.makeFieldKey(type_name, field_name) catch return;
        self.field_id_map.put(key, field_id) catch return;
    }

    /// 查找 field_id（找不到返回 null）
    fn lookupFieldId(self: *IRBuilder, type_name: []const u8, field_name: []const u8) ?u16 {
        var key_buf: [256]u8 = undefined;
        const total_len = type_name.len + 1 + field_name.len;
        if (total_len > key_buf.len) {
            const key = self.makeFieldKey(type_name, field_name) catch return null;
            return self.field_id_map.get(key);
        }
        @memcpy(key_buf[0..type_name.len], type_name);
        key_buf[type_name.len] = 0;
        @memcpy(key_buf[type_name.len + 1 .. total_len], field_name);
        const key = key_buf[0..total_len];
        return self.field_id_map.get(key);
    }

    /// 构造 record_make 的 meta：编码 (field_count << 32) | type_name_pool_idx
    fn addRecordMakeMeta(self: *IRBuilder, type_name: []const u8, field_count: u32) !u16 {
        const type_name_idx = self.addString(type_name);
        const packed_val: u64 = (@as(u64, field_count) << 32) | @as(u64, @intCast(type_name_idx));
        const signed_val: i64 = @bitCast(packed_val);
        return try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, signed_val) },
        });
    }

    /// 构造 record_get/set 的 field_id meta
    fn addFieldIdMeta(self: *IRBuilder, field_id: u16) !u16 {
        return try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, field_id) },
        });
    }

    // ════════════════════════════════════════════
    // 向量编译（Phase 2）
    // ════════════════════════════════════════════

    /// 编译 for 循环为向量 op
    ///
    /// 支持形式：
    ///   for i in start..end { body }  → vec_source(range) |> vec_map(body) |> vec_sink
    ///   for i in array { body }       → vec_source(array) |> vec_map(body) |> vec_sink
    ///
    /// dispatch 从 O(N) 降为 O(1)：1 次 vec_source + 1 次 vec_map + 1 次 vec_sink
    fn compileFor(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 含 break/continue 时尝试数据化（纯函数条件转 take_while/filter）
        if (self.containsBreakOrContinue(fs.body)) {
            if (try self.tryCompileForDataflow(fs)) |result| {
                return result;
            }
            return try self.compileForScalar(fs);
        }

        // 编译 iterable → vec_source 节点
        const src_vec_chan = try self.compileVecSource(fs.iterable);

        // 记录循环体起始位置
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 在新作用域中编译循环体，绑定循环变量
        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到 vec_source 的元素通道
        try self.defineVar(fs.name, src_vec_chan, false);

        // 编译循环体（结果通道由 body 子图的最后一个节点决定）
        _ = try self.compileExpr(fs.body);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 vec_map 节点（引用循环体子图）
        const map_meta_idx = try self.addVectorMeta(.{
            .inner_op = .const_i, // 占位，实际由 body_start/body_len 决定
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });

        const map_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

        // 发射 vec_sink 节点（取最后一个元素作为 for 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });
        const sink_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, map_out));

        return sink_out;
    }

    /// 尝试将含 break/continue 的 for 循环编译为数据流 IR
    ///
    /// 支持形式：
    ///   for i in iterable {
    ///       if cond_break { break }
    ///       if cond_continue { continue }
    ///       body
    ///   }
    ///
    /// 转换为：vec_source |> [vec_take_while(¬cond_break)] |> [vec_filter(¬cond_continue)] |> vec_map(body) |> vec_sink
    ///
    /// 条件：break/continue 条件必须是纯函数（只引用 loop_var 和外部不可变 val 变量）
    /// 不满足时返回 null，回退到标量循环
    fn tryCompileForDataflow(self: *IRBuilder, fs: anytype) BuildError!?u16 {
        if (fs.body.* != .block) return null;
        const block = fs.body.block;

        // 1. 扫描 statements，提取 break/continue 条件
        var break_cond: ?*const ast.Expr = null;
        var continue_cond: ?*const ast.Expr = null;
        var break_count: u32 = 0;
        var continue_count: u32 = 0;

        for (block.statements) |stmt| {
            const bc = tryExtractBreakContinueCond(stmt) orelse continue;
            if (bc.is_break) {
                break_count += 1;
                break_cond = bc.cond;
            } else {
                continue_count += 1;
                continue_cond = bc.cond;
            }
        }

        if (break_count == 0 and continue_count == 0) return null;
        if (break_count > 1 or continue_count > 1) return null;

        // 1.5 验证剩余 body（非 break/continue if 的语句）不含嵌套的 break/continue
        // 嵌套在其他 if/match 中的 break/continue 无法数据化，回退 scalar
        for (block.statements) |stmt| {
            if (tryExtractBreakContinueCond(stmt) != null) continue;
            if (astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (astContainsBreakOrContinueExpr(te)) return null;
        }

        // 2. 验证条件是纯函数（只引用 loop_var 和外部不可变 val 变量）
        if (break_cond) |bc| {
            if (!self.isPureCondition(bc, fs.name)) return null;
        }
        if (continue_cond) |cc| {
            if (!self.isPureCondition(cc, fs.name)) return null;
        }

        // 3. 编译 vec_source
        const src_vec_chan = try self.compileVecSource(fs.iterable);
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        var cur_chan = src_vec_chan;

        // 4. [可选] vec_take_while(¬break_cond)
        if (break_cond) |bc| {
            cur_chan = try self.emitTakeWhileNegCond(cur_chan, bc, fs.name);
        }

        // 5. [可选] vec_filter(¬continue_cond)
        if (continue_cond) |cc| {
            cur_chan = try self.emitFilterNegCond(cur_chan, cc, fs.name);
        }

        // 6. vec_map(pure_body) — 编译 body 语句，跳过 break/continue if
        const body_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(fs.name, cur_chan, false);

        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        for (block.statements) |stmt| {
            if (tryExtractBreakContinueCond(stmt) != null) continue;
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            self.in_tail_position = saved_tail;
            _ = try self.compileExpr(te);
        }
        self.in_tail_position = saved_tail;

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // body 非空时发射 vec_map；为空（只有 break/continue if）则跳过
        if (body_len > 0) {
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, cur_chan));
            cur_chan = map_out;
        }

        // 7. vec_sink（取最后一个元素作为 for 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, cur_chan));

        return sink_out;
    }

    /// 发射 vec_take_while(¬break_cond) 节点
    /// break_cond 为 true 时终止循环，取反后作为 take_while 谓词
    fn emitTakeWhileNegCond(
        self: *IRBuilder,
        src_chan: u16,
        break_cond: *const ast.Expr,
        loop_var: []const u8,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_chan).chan_type;

        // 编译条件体（在 loop_var 作用域中，loop_var 绑定到 src_chan 当前元素）
        const cond_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(loop_var, src_chan, false);

        const cond_chan = try self.compileExpr(break_cond);
        // 取反：¬break_cond
        const not_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.bool_not, not_chan, 0, cond_chan));

        const cond_len: u32 = @intCast(self.nodes.items.len - cond_start);

        const tw_meta_idx = try self.addVectorMeta(.{
            .body_start = cond_start,
            .body_len = cond_len,
            .elem_type = .bool_chan,
        });
        const tw_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_take_while, tw_out, tw_meta_idx, src_chan));
        return tw_out;
    }

    /// 发射 vec_filter(¬continue_cond) 节点
    /// continue_cond 为 true 时跳过当前元素，取反后作为 filter 谓词
    fn emitFilterNegCond(
        self: *IRBuilder,
        src_chan: u16,
        continue_cond: *const ast.Expr,
        loop_var: []const u8,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_chan).chan_type;

        const cond_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(loop_var, src_chan, false);

        const cond_chan = try self.compileExpr(continue_cond);
        const not_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.bool_not, not_chan, 0, cond_chan));

        const cond_len: u32 = @intCast(self.nodes.items.len - cond_start);

        const filt_meta_idx = try self.addVectorMeta(.{
            .body_start = cond_start,
            .body_len = cond_len,
            .elem_type = .bool_chan,
        });
        const filt_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_filter, filt_out, filt_meta_idx, src_chan));
        return filt_out;
    }

    /// 检查条件是否为纯函数（只引用 loop_var 和外部不可变 val 变量）
    /// 不允许 call/method_call/field_access/index/赋值等副作用操作
    fn isPureCondition(self: *IRBuilder, expr: *const ast.Expr, loop_var: []const u8) bool {
        switch (expr.*) {
            .int_literal, .float_literal, .bool_literal, .char_literal, .string_literal, .null_literal, .unit_literal => return true,
            .identifier => |id| {
                if (std.mem.eql(u8, id.name, loop_var)) return true;
                // 外部变量必须是 val（不可变，is_cell=false）
                if (self.lookupVar(id.name)) |binding| {
                    return !binding.is_cell;
                }
                return false;
            },
            .binary => |b| return self.isPureCondition(b.left, loop_var) and self.isPureCondition(b.right, loop_var),
            .unary => |u| return self.isPureCondition(u.operand, loop_var),
            else => return false,
        }
    }

    /// 编译 while 循环
    ///
    /// 优先尝试模式识别：`while var < end { body; var = var + 1 }` → vec_source + vec_map
    /// 不匹配时回退到标量循环
    fn compileWhile(self: *IRBuilder, ws: anytype) BuildError!u16 {
        if (try self.tryCompileWhileAsVecMap(ws)) |result| {
            return result;
        }
        // 分块向量化：while var < end { body 含 break/continue } → vec_source + vec_take_while + vec_filter + vec_map + vec_sink
        if (try self.tryCompileWhileChunked(ws)) |result| {
            return result;
        }
        return try self.compileWhileScalar(ws);
    }

    /// 分块向量化：while var < end { body; var += 1 }（body 含 break/continue）
    ///
    /// 条件：
    /// - condition 是 `var < end`（仅支持 <）
    /// - body 是 block，最后一条语句是 `var = var + 1` 或 `var += 1`
    /// - body 含 break/continue（否则由 tryCompileWhileAsVecMap 处理）
    /// - break/continue 条件是纯函数（仅依赖 var 和外部不可变变量）
    /// - var 是整数类型
    ///
    /// 转换为：vec_source(range, var, end) |> [vec_take_while(¬break_cond)] |> [vec_filter(¬continue_cond)] |> vec_map(body) |> vec_sink
    /// dispatch 从 O(N) 降到 O(1)（向量 op 一次 dispatch 处理整个向量）
    fn tryCompileWhileChunked(self: *IRBuilder, ws: anytype) BuildError!?u16 {
        // 1. 解析 condition: var < end
        if (ws.condition.* != .binary) return null;
        const bin = ws.condition.binary;
        if (bin.op != .lt) return null;
        if (bin.left.* != .identifier) return null;
        const var_name = bin.left.identifier.name;
        const end_expr = bin.right;

        // 2. 解析 body: block，最后一条是 var = var + 1 或 var += 1
        if (ws.body.* != .block) return null;
        const block = ws.body.block;
        if (block.statements.len == 0) return null;

        const last_stmt = block.statements[block.statements.len - 1];
        const body_stmts = block.statements[0 .. block.statements.len - 1];

        // 检查递增模式（与 tryCompileWhileAsVecMap 相同）
        var is_increment = false;
        if (last_stmt.* == .assignment) {
            const assign = last_stmt.assignment;
            if (assign.target.* == .identifier and
                std.mem.eql(u8, assign.target.identifier.name, var_name))
            {
                if (assign.value.* == .binary) {
                    const inc = assign.value.binary;
                    if (inc.op == .add) {
                        if (inc.left.* == .identifier and
                            std.mem.eql(u8, inc.left.identifier.name, var_name) and
                            inc.right.* == .int_literal and
                            std.mem.eql(u8, inc.right.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        } else if (inc.right.* == .identifier and
                            std.mem.eql(u8, inc.right.identifier.name, var_name) and
                            inc.left.* == .int_literal and
                            std.mem.eql(u8, inc.left.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        }
                    }
                }
            }
        } else if (last_stmt.* == .compound_assignment) {
            const ca = last_stmt.compound_assignment;
            if (ca.target.* == .identifier and
                std.mem.eql(u8, ca.target.identifier.name, var_name) and
                ca.op == .add_assign and
                ca.value.* == .int_literal and
                std.mem.eql(u8, ca.value.int_literal.raw, "1"))
            {
                is_increment = true;
            }
        }
        if (!is_increment) return null;

        // 3. 提取 break/continue 条件
        var break_cond: ?*const ast.Expr = null;
        var continue_cond: ?*const ast.Expr = null;
        var break_count: u32 = 0;
        var continue_count: u32 = 0;

        for (body_stmts) |stmt| {
            const bc = tryExtractBreakContinueCond(stmt) orelse continue;
            if (bc.is_break) {
                break_count += 1;
                break_cond = bc.cond;
            } else {
                continue_count += 1;
                continue_cond = bc.cond;
            }
        }

        // 必须含 break/continue（否则由 tryCompileWhileAsVecMap 处理）
        if (break_count == 0 and continue_count == 0) return null;
        if (break_count > 1 or continue_count > 1) return null;

        // 4. 验证剩余 body 不含嵌套 break/continue
        for (body_stmts) |stmt| {
            if (tryExtractBreakContinueCond(stmt) != null) continue;
            if (astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (astContainsBreakOrContinueExpr(te)) return null;
        }

        // 5. 验证 break/continue 条件是纯函数
        if (break_cond) |bc| {
            if (!self.isPureCondition(bc, var_name)) return null;
        }
        if (continue_cond) |cc| {
            if (!self.isPureCondition(cc, var_name)) return null;
        }

        // 6. 获取 var 的当前通道（外部作用域）
        const var_binding = self.lookupVar(var_name) orelse return null;
        const start_chan = var_binding.chan;
        const var_chan = var_binding.chan;
        const elem_type = self.channels.get(start_chan).chan_type;
        if (!elem_type.isInt()) return null;

        // 7. 编译 end 表达式
        const end_chan = try self.compileExpr(end_expr);

        // 8. 生成 vec_source(range, start, end)
        var length: ?u32 = null;
        if (self.findConstVal(start_chan)) |sv| {
            if (self.findConstVal(end_chan)) |ev| {
                const s_val: i64 = @intCast(sv);
                const e_val: i64 = @intCast(ev);
                const len: i64 = e_val - s_val;
                if (len >= 0) length = @intCast(len);
            }
        }

        const source_meta_idx = try self.addVectorMeta(.{
            .vec_op = .range_source,
            .length = length,
            .elem_type = elem_type,
        });
        const src_vec_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));
        var cur_chan = src_vec_chan;

        // 9. [可选] vec_take_while(¬break_cond)
        if (break_cond) |bc| {
            cur_chan = try self.emitTakeWhileNegCond(cur_chan, bc, var_name);
        }

        // 10. [可选] vec_filter(¬continue_cond)
        if (continue_cond) |cc| {
            cur_chan = try self.emitFilterNegCond(cur_chan, cc, var_name);
        }

        // 11. vec_map(body) — 编译 body 语句，跳过 break/continue if
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(var_name, cur_chan, false);

        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        const body_start: u32 = @intCast(self.nodes.items.len);
        for (body_stmts) |stmt| {
            if (tryExtractBreakContinueCond(stmt) != null) continue;
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            self.in_tail_position = saved_tail;
            _ = try self.compileExpr(te);
        }
        self.in_tail_position = saved_tail;

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        if (body_len > 0) {
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, cur_chan));
            cur_chan = map_out;
        }

        // 12. vec_sink（取最后一个元素）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, cur_chan));

        // 13. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
        try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

        return sink_out;
    }

    /// 模式识别：while var < end { body; var = var + 1 } → vec_source(range) + vec_map(body)
    ///
    /// 条件：
    /// - condition 是 `var < end`（仅支持 <，不支持 <=）
    /// - body 是 block，最后一条语句是 `var = var + 1` 或 `var += 1`
    /// - body 不含 break/continue
    /// - var 是整数类型
    ///
    /// 转换后：dispatch 从 O(N) 降到 O(1)（vec_map 一次 dispatch 处理整个向量）
    /// 循环后更新 var = end（语义保持）
    fn tryCompileWhileAsVecMap(self: *IRBuilder, ws: anytype) BuildError!?u16 {
        // 1. 解析 condition: var < end
        if (ws.condition.* != .binary) return null;
        const bin = ws.condition.binary;
        if (bin.op != .lt) return null;
        if (bin.left.* != .identifier) return null;
        const var_name = bin.left.identifier.name;
        const end_expr = bin.right;

        // 2. 解析 body: block，最后一条是 var = var + 1 或 var += 1
        if (ws.body.* != .block) return null;
        const block = ws.body.block;
        if (block.statements.len == 0) return null;

        const last_stmt = block.statements[block.statements.len - 1];
        const body_stmts = block.statements[0 .. block.statements.len - 1];

        // 检查递增模式
        var is_increment = false;

        // 情况 1: assignment (var = var + 1)
        if (last_stmt.* == .assignment) {
            const assign = last_stmt.assignment;
            if (assign.target.* == .identifier and
                std.mem.eql(u8, assign.target.identifier.name, var_name))
            {
                if (assign.value.* == .binary) {
                    const inc = assign.value.binary;
                    if (inc.op == .add) {
                        // var + 1 或 1 + var
                        if (inc.left.* == .identifier and
                            std.mem.eql(u8, inc.left.identifier.name, var_name) and
                            inc.right.* == .int_literal and
                            std.mem.eql(u8, inc.right.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        } else if (inc.right.* == .identifier and
                            std.mem.eql(u8, inc.right.identifier.name, var_name) and
                            inc.left.* == .int_literal and
                            std.mem.eql(u8, inc.left.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        }
                    }
                }
            }
        }
        // 情况 2: compound_assignment (var += 1)
        else if (last_stmt.* == .compound_assignment) {
            const ca = last_stmt.compound_assignment;
            if (ca.target.* == .identifier and
                std.mem.eql(u8, ca.target.identifier.name, var_name) and
                ca.op == .add_assign and
                ca.value.* == .int_literal and
                std.mem.eql(u8, ca.value.int_literal.raw, "1"))
            {
                is_increment = true;
            }
        }

        if (!is_increment) return null;

        // 3. 检查 body 不含 break/continue
        for (body_stmts) |stmt| {
            if (astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (astContainsBreakOrContinueExpr(te)) return null;
        }

        // 3.5 累加器模式检测：检测 body 是否为「纯表达式 + 单一累加器更新」结构
        // 若累加器更新是简单结合运算（acc = acc + expr / acc += expr / acc *= expr 等），
        // 则可拆分为 vec_map(expr) + vec_fold(op, init, t_vec)，实现真正的 O(1) dispatch。
        // 非简单结合运算（含 %、/ 等）或多个累加器 → 回退标量循环。
        var acc_info: ?struct { name: []const u8, op: NodeOp } = null;
        for (body_stmts) |stmt| {
            if (astContainsBreakOrContinueStmt(stmt)) return null;
            // 尝试匹配 acc = acc OP expr 或 acc OP= expr
            if (extractAccumulatorPattern(stmt, var_name)) |ap| {
                if (acc_info) |existing| {
                    if (!std.mem.eql(u8, existing.name, ap.acc_name)) return null;
                    if (existing.op != ap.fold_op) return null;
                } else {
                    acc_info = .{ .name = ap.acc_name, .op = ap.fold_op };
                }
            } else {
                // 非累加器语句：检查是否有其他外部赋值
                if (astContainsExternalAssignStmt(stmt, var_name)) return null;
            }
        }
        if (block.trailing_expr) |te| {
            if (astContainsBreakOrContinueExpr(te)) return null;
            if (astContainsExternalAssignExpr(te, var_name)) return null;
        }

        // 4. 获取 var 的当前通道（外部作用域）
        const var_binding = self.lookupVar(var_name) orelse return null;
        const start_chan = var_binding.chan;
        const var_chan = var_binding.chan;

        // 4.5 累加器模式：获取 init 值和拆分 body
        // 仅支持简单结合运算（add/mul/band/bor/bxor）→ vec_fold
        // 非结合运算（sub/div/mod）→ 回退标量循环（保持原行为）
        if (acc_info) |ai| {
            const fold_op = ai.op;
            // 仅 add/mul/and/or/xor 可安全 vec_fold（结合律）
            const is_associative = switch (fold_op) {
                .int_add, .int_mul, .int_and, .int_or, .int_xor => true,
                else => false,
            };
            if (!is_associative) return null;

            // 获取累加器通道和初始值
            const acc_binding = self.lookupVar(ai.name) orelse return null;
            const acc_chan = acc_binding.chan;
            const acc_type = self.channels.get(acc_chan).chan_type;

            // 5. 编译 end 表达式
            const end_chan = try self.compileExpr(end_expr);

            // 6. 获取元素类型
            const elem_type = self.channels.get(start_chan).chan_type;
            if (!elem_type.isInt()) return null;
            if (acc_type != elem_type) return null; // 类型必须一致

            // 7. 生成 vec_source(range)
            var length: ?u32 = null;
            if (self.findConstVal(start_chan)) |sv| {
                if (self.findConstVal(end_chan)) |ev| {
                    const s_val: i64 = @intCast(sv);
                    const e_val: i64 = @intCast(ev);
                    const len: i64 = e_val - s_val;
                    if (len >= 0) length = @intCast(len);
                }
            }

            const source_meta_idx = try self.addVectorMeta(.{
                .vec_op = .range_source,
                .length = length,
                .elem_type = elem_type,
            });
            const src_vec_chan = try self.allocChannel(elem_type);
            try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));

            // 8. 在新作用域中编译 body 表达式部分（排除累加器赋值语句）
            // body_expr 提取累加器更新中的右值表达式，编译为 vec_map
            try self.pushScope();
            defer self.popScope();
            try self.defineVar(var_name, src_vec_chan, false);

            const body_start: u32 = @intCast(self.nodes.items.len);
            // 编译非累加器语句
            for (body_stmts) |stmt| {
                if (extractAccumulatorPattern(stmt, var_name)) |ap| {
                    // 累加器语句：编译右值表达式（f(i) 部分）
                    _ = try self.compileExpr(ap.value_expr);
                } else {
                    _ = try self.compileStmt(stmt);
                }
            }
            if (block.trailing_expr) |te| {
                _ = try self.compileExpr(te);
            }
            const body_len: u32 = @intCast(self.nodes.items.len - body_start);

            // 9. 生成 vec_map（body 表达式 → t_vec）
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

            // 10. 生成 vec_fold（init OP t_vec → result）
            // vec_fold 的 init 来自循环前的 acc 值，需要读取当前 acc 通道值
            const init_chan = try self.allocChannel(acc_type);
            try self.emit(Node.makeUnary(.load, init_chan, 0, acc_chan));

            const fold_result = try self.compileFold(fold_op, init_chan, map_out);

            // 11. 更新 acc 通道为 fold 结果（语义保持：循环后 acc = 最终累加值）
            try self.emit(Node.makeUnary(.store, acc_chan, 0, fold_result));

            // 12. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
            try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

            // 13. while 表达式的值 = acc 最终值
            const result_chan = try self.allocChannel(acc_type);
            try self.emit(Node.makeUnary(.load, result_chan, 0, acc_chan));
            return result_chan;
        }

        // 5. 编译 end 表达式
        const end_chan = try self.compileExpr(end_expr);

        // 6. 获取元素类型，检查是整数
        const elem_type = self.channels.get(start_chan).chan_type;
        if (!elem_type.isInt()) return null;

        // 7. 生成 vec_source(range, start, end)
        var length: ?u32 = null;
        if (self.findConstVal(start_chan)) |sv| {
            if (self.findConstVal(end_chan)) |ev| {
                const s_val: i64 = @intCast(sv);
                const e_val: i64 = @intCast(ev);
                const len: i64 = e_val - s_val;
                if (len >= 0) length = @intCast(len);
            }
        }

        const source_meta_idx = try self.addVectorMeta(.{
            .vec_op = .range_source,
            .length = length,
            .elem_type = elem_type,
        });
        const src_vec_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));

        // 8. 在新作用域中将 var 绑定到 src_vec_chan
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(var_name, src_vec_chan, false);

        // 9. 编译 body（不含最后的递增语句）
        const body_start: u32 = @intCast(self.nodes.items.len);
        for (body_stmts) |stmt| {
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            _ = try self.compileExpr(te);
        }
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 10. 生成 vec_map
        const map_meta_idx = try self.addVectorMeta(.{
            .inner_op = .const_i, // 占位
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = elem_type,
        });
        const map_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

        // 11. 生成 vec_sink（取最后一个元素作为 while 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, map_out));

        // 12. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
        try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

        return sink_out;
    }

    /// 编译 loop { body } 无限循环（含 break 退出）
    fn compileLoop(self: *IRBuilder, ls: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        _ = try self.compileExpr(ls.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .loop,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 for 循环（含 break/continue）
    fn compileForScalar(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 编译 iterable → 向量通道
        const src_vec_chan = try self.compileVecSource(fs.iterable);
        const elem_type = self.channels.get(src_vec_chan).chan_type;

        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到向量元素通道（engine 执行时 pin 到当前元素）
        const iter_chan = try self.allocChannel(elem_type);
        try self.defineVar(fs.name, iter_chan, false);
        _ = try self.compileExpr(fs.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .for_loop,
            .cond_chan = src_vec_chan,
            .iter_chan = iter_chan,
            .elem_type = elem_type,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 while 循环（含 break/continue）
    fn compileWhileScalar(self: *IRBuilder, ws: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        const cond_chan = try self.compileExpr(ws.condition);
        const cond_len: u32 = @intCast(self.nodes.items.len - body_start);
        _ = try self.compileExpr(ws.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .while_loop,
            .cond_len = cond_len,
            .cond_chan = cond_chan,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 编译 iterable 表达式为 vec_source 节点
    fn compileVecSource(self: *IRBuilder, iterable: *ast.Expr) BuildError!u16 {
        switch (iterable.*) {
            .binary => |b| {
                if (b.op == .range or b.op == .range_inclusive) {
                    // range 表达式：start..end 或 start..=end
                    const start_chan = try self.compileExpr(b.left);
                    const end_chan = try self.compileExpr(b.right);

                    // 尝试从常量推导长度
                    var length: ?u32 = null;
                    const start_meta = self.channels.get(start_chan);
                    if (start_meta.chan_type.isInt()) {
                        // 查找常量值
                        if (self.findConstVal(start_chan)) |sv| {
                            if (self.findConstVal(end_chan)) |ev| {
                                const s_val: i64 = @intCast(sv);
                                const e_val: i64 = @intCast(ev);
                                const len: i64 = if (b.op == .range_inclusive) e_val - s_val + 1 else e_val - s_val;
                                if (len >= 0) length = @intCast(len);
                            }
                        }
                    }

                    const elem_type = self.channels.get(start_chan).chan_type;
                    const meta_idx = try self.addVectorMeta(.{
                        .vec_op = .range_source,
                        .length = length,
                        .elem_type = elem_type,
                    });

                    const out = try self.allocChannel(elem_type);
                    try self.emit(Node.makeBinary(.vec_source, out, meta_idx, start_chan, end_chan));
                    return out;
                }
                if (b.op == .concat_list) {
                    // a ++ b：编译为 array_concat，得到 ref_chan，再 vec_source(array_source)
                    const ref_chan = try self.compileExpr(iterable);
                    return try self.emitArraySource(ref_chan, null);
                }
                return error.UnsupportedExpr;
            },
            .array_literal => {
                // 数组字面量：先编译为 array_make（返回 ref_chan），再 vec_source(array_source)
                const arr_chan = try self.compileExpr(iterable);
                const length: ?u32 = null; // 长度由运行时从 ArrayValue 读取
                return try self.emitArraySource(arr_chan, length);
            },
            .string_literal => {
                // 字符串字面量 → vec_source(string_source)，迭代 Unicode 标量值
                const str_chan = try self.compileExpr(iterable);
                const meta_idx = try self.addVectorMeta(.{
                    .vec_op = .string_source,
                    .elem_type = .char_chan,
                });
                const out = try self.allocChannel(.char_chan);
                try self.emit(Node.makeUnary(.vec_source, out, meta_idx, str_chan));
                return out;
            },
            .identifier, .call, .method_call, .index, .field_access => {
                // 检查是否为字符串表达式 → string_source（迭代 Unicode 标量值）
                if (self.isStringExpr(iterable) or self.isStringParam(iterable)) {
                    const str_chan = try self.compileExpr(iterable);
                    const meta_idx = try self.addVectorMeta(.{
                        .vec_op = .string_source,
                        .elem_type = .char_chan,
                    });
                    const out = try self.allocChannel(.char_chan);
                    try self.emit(Node.makeUnary(.vec_source, out, meta_idx, str_chan));
                    return out;
                }
                // 标识符/调用/方法调用/索引/字段访问：编译为 ref_chan，再 vec_source(array_source)
                const ref_chan = try self.compileExpr(iterable);
                return try self.emitArraySource(ref_chan, null);
            },
            else => return error.UnsupportedExpr,
        }
    }

    /// 发射 array_source vec_source 节点
    /// inputs[0] = arr_chan（ref_chan 指向 ArrayValue）
    fn emitArraySource(self: *IRBuilder, arr_chan: u16, length: ?u32) BuildError!u16 {
        const meta_idx = try self.addVectorMeta(.{
            .vec_op = .array_source,
            .length = length,
            .elem_type = .i64_chan,
        });
        const out = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeUnary(.vec_source, out, meta_idx, arr_chan));
        return out;
    }

    /// 从通道查找编译期常量值
    fn findConstVal(self: *IRBuilder, chan: u16) ?i128 {
        // 遍历节点流，找到 output == chan 的 const_i 节点
        for (self.nodes.items) |n| {
            if (n.output == chan and n.op == .const_i) {
                if (n.meta_index > 0 and n.meta_index < self.scalar_metas.items.len) {
                    const meta = self.scalar_metas.items[n.meta_index];
                    if (meta.const_val) |cv| {
                        return switch (cv) {
                            .int_val => |v| v,
                            else => null,
                        };
                    }
                }
            }
        }
        return null;
    }

    /// 编译归约表达式（vec_fold）
    /// 用于 sum(range) / max(range) / min(range) 等场景
    fn compileFold(
        self: *IRBuilder,
        fold_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = fold_op,
            .elem_type = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        // vec_fold 是二元节点：inputs[0] = src_vec, inputs[1] = init_val
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_fold,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译前缀计算（vec_scan）
    /// 用于递归线性化：fib(n) → scan(step, (0,1)) |> take(n) |> last
    fn compileScan(
        self: *IRBuilder,
        scan_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = scan_op,
            .elem_type = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_scan,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    // ════════════════════════════════════════════
    // Phase 3: 门控/路由/竞争/清理编译
    // ════════════════════════════════════════════

    /// 编译 ? 传播表达式
    ///
    /// expr? 编译为门控节点链：
    ///   N0: ch_val = <expr>
    ///   N1: ch_ok = gate_check(ch_val)       // 检查 is_ok
    ///   N2: ch_inner = gate_get_ok(ch_val)   // 提取 Ok 值
    ///
    /// 后续 ? 点的 gate_propagate 会 OR 传播错误掩码。
    /// gate_select 在链尾按 mask 选择最终结果。
    fn compilePropagate(self: *IRBuilder, inner_expr: *ast.Expr) BuildError!u16 {
        // 编译内部表达式
        const val_chan = try self.compileExpr(inner_expr);
        const val_meta = self.channels.get(val_chan);

        // null_literal 传播：a? 返回 null → 传播 null（返回零值通道）
        if (val_meta.chan_type == .null_chan) {
            // null 传播：返回一个零值通道（后续使用时会有问题，但 ?? 会短路）
            // 简化：直接返回 null_chan，由调用方处理
            return val_chan;
        }

        // nullable 传播：a? — unwrap nullable，null 时返回零值（简化：不做短路返回）
        if (val_meta.chan_type == .nullable_chan) {
            const inner_type = val_meta.inner_type;
            const unwrapped_chan = try self.allocChannel(inner_type);
            try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, val_chan));
            return unwrapped_chan;
        }

        // Throw 传播：a? — 检查 is_ok，is_err 时函数返回 error，is_ok 时提取 Ok 值
        // 推断 inner_expr 的 Throw Ok 类型，避免使用 current_throw_ok_chan_type（当前函数返回类型）
        // 当 ? 应用于其他函数返回值时，Ok 类型可能不同
        const ok_val_type = self.inferThrowOkChanType(inner_expr) orelse self.current_throw_ok_chan_type;

        // gate_check：检查 is_ok，输出 mask_chan
        const check_meta_idx = try self.addGateMeta(.{
            .gate_kind = .check,
            .error_type = 0,
        });
        const ok_chan = try self.allocChannel(.mask_chan);
        try self.emit(Node.makeUnary(.gate_check, ok_chan, check_meta_idx, val_chan));

        // 使用 route_dispatch 实现短路：Err → halt_return，Ok → gate_get_ok
        const ret_chan = self.current_return_chan orelse {
            // 无返回通道（不应在 Throw 返回函数中出现）：退化为不短路
            const get_ok_meta_idx_fallback = try self.addGateMeta(.{ .gate_kind = .get_ok });
            const inner_chan_fb = try self.allocChannel(ok_val_type);
            try self.emit(Node.makeUnary(.gate_get_ok, inner_chan_fb, get_ok_meta_idx_fallback, val_chan));
            return inner_chan_fb;
        };

        // cast bool → i64 (true=1=Ok→arm1, false=0=Err→arm0)
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, ok_chan));

        // arm 0 = Err: halt_return with original ThrowValue（传播错误）
        const err_arm_start: u32 = @intCast(self.nodes.items.len);
        try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, val_chan));
        const err_arm_len: u32 = @intCast(self.nodes.items.len - err_arm_start);

        // arm 1 = Ok: gate_get_ok（提取 Ok 值）
        const ok_arm_start: u32 = @intCast(self.nodes.items.len);
        const get_ok_meta_idx = try self.addGateMeta(.{ .gate_kind = .get_ok });
        const inner_chan = try self.allocChannel(ok_val_type);
        try self.emit(Node.makeUnary(.gate_get_ok, inner_chan, get_ok_meta_idx, val_chan));
        const ok_arm_len: u32 = @intCast(self.nodes.items.len - ok_arm_start);

        // route_dispatch 按 winner 索引执行对应子图
        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = err_arm_start;
        body_lens[0] = err_arm_len;
        body_starts[1] = ok_arm_start;
        body_lens[1] = ok_arm_len;

        const result_chan = try self.allocChannel(ok_val_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译 defer 语句
    ///
    /// defer expr 编译为：
    ///   1. 记录 defer 体节点序列的起始位置
    ///   2. 编译 defer 体表达式
    ///   3. 发射 cleanup_register 节点，meta 记录体范围
    ///   4. halt 时 LIFO 执行
    fn compileDefer(self: *IRBuilder, ds: anytype) BuildError!void {
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 编译 defer 体（表达式语句）
        _ = try self.compileExpr(ds.expr);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 cleanup_register 节点
        const cleanup_meta_idx = try self.addCleanupMeta(.{
            .trigger = .any_halt,
            .body_start = body_start,
            .body_len = body_len,
            .order = @intCast(self.cleanup_metas.items.len),
        });

        // cleanup_register 不产生值，输出到 unit 通道
        const unit_chan = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.cleanup_register, unit_chan, cleanup_meta_idx));
    }

    /// 编译 throw 语句
    ///
    /// 当函数返回 Throw<T, E> 时，throw expr 产生 ThrowValue(err) 并正常返回（halt_return），
    /// 调用者可通过 match 捕获。否则编译为 halt_throw，运行时返回 error.Thrown。
    fn compileThrow(self: *IRBuilder, ts: anytype) BuildError!?u16 {
        const err_chan = try self.compileExpr(ts.expr);

        if (self.current_returns_throw) {
            // Throw 返回函数：构造 ThrowValue 并正常返回
            const ret_chan = self.current_return_chan orelse {
                const out = try self.allocChannel(.ref_chan);
                const gate_meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
                try self.emit(Node.makeUnary(.halt_throw, out, gate_meta_idx, err_chan));
                return out;
            };
            const value_chan = if (self.exprIsThrowValue(ts.expr)) err_chan else blk: {
                // 非 ThrowValue 输入：用 gate_make_err 构造 ThrowValue(err)
                const wrap_out = try self.allocChannel(.ref_chan);
                const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
                try self.emit(Node.makeUnary(.gate_make_err, wrap_out, meta_idx, err_chan));
                break :blk wrap_out;
            };
            try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, value_chan));
            return ret_chan;
        } else {
            // 非 Throw 返回函数：halt_throw 运行时返回 error.Thrown
            const out = try self.allocChannel(.ref_chan);
            const gate_meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
            try self.emit(Node.makeUnary(.halt_throw, out, gate_meta_idx, err_chan));
            return out;
        }
    }

    /// 编译 select 多路复用
    ///
    /// select { ch1.recv() => v => body1; ch2.recv() => v => body2 }
    /// 编译为竞争图：
    ///   N0: race_source(ch1)          // 检查 ch1 就绪性
    ///   N1: race_source(ch2)          // 检查 ch2 就绪性
    ///   N2: race_select(r1, r2) → winner  // 选第一个就绪的
    ///   N3: route_dispatch(winner)    // 按 winner 索引执行对应 body 子图
    ///   body1 子图节点...（被 body_skip 跳过，由 route_dispatch 按需执行）
    ///   body2 子图节点...（同上）
    fn compileSelect(self: *IRBuilder, arms: []const ast.SelectArm) BuildError!u16 {
        if (arms.len == 0) return error.UnsupportedExpr;

        const arena_alloc = self.arena.allocator();
        const arm_count = arms.len;

        // 1. 提取每个分支的通道（从 cha.recv() 中提取 cha），发射 race_source
        var race_source_chans = try arena_alloc.alloc(u16, arm_count);
        var arm_chans = try arena_alloc.alloc(u16, arm_count);
        for (arms, 0..) |arm, i| {
            // channel_expr 可能是 cha.recv() 调用，需要提取通道对象
            const chan_expr = switch (arm) {
                .receive => |r| blk: {
                    switch (r.channel_expr.*) {
                        .method_call => |mc| {
                            if (std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv")) {
                                break :blk mc.object;
                            }
                            break :blk r.channel_expr;
                        },
                        .safe_method_call => |mc| {
                            if (std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv")) {
                                break :blk mc.object;
                            }
                            break :blk r.channel_expr;
                        },
                        else => break :blk r.channel_expr,
                    }
                },
                .timeout => |t| t.duration,
            };
            const src_chan = try self.compileExpr(chan_expr);
            arm_chans[i] = src_chan;

            const race_meta_idx = try self.addRaceMeta(.{
                .source_count = 1,
                .timeout_ms = null,
            });
            const race_out = try self.allocChannel(.mask_chan);
            try self.emit(Node.makeUnary(.race_source, race_out, race_meta_idx, src_chan));
            race_source_chans[i] = race_out;
        }

        // 2. 发射 race_select 节点（选择第一个就绪的）
        const select_meta_idx = try self.addRaceMeta(.{
            .source_count = @intCast(arm_count),
            .timeout_ms = null,
        });

        const winner_chan = try self.allocChannel(.mask_chan);
        // race_select 的输入是所有 race_source 的输出（最多 4 个）
        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        const count = @min(arm_count, 4);
        for (0..count) |i| {
            inputs[i] = race_source_chans[i];
        }
        try self.emit(Node{
            .op = .race_select,
            .input_count = @intCast(count),
            .output = winner_chan,
            .meta_index = select_meta_idx,
            .inputs = inputs,
        });

        // 3. 编译每个 arm 的 body 为子图，记录起始位置和长度
        var body_starts = try arena_alloc.alloc(u32, arm_count);
        var body_lens = try arena_alloc.alloc(u32, arm_count);
        for (arms, 0..) |arm, i| {
            body_starts[i] = @intCast(self.nodes.items.len);
            if (arm == .receive) {
                // 判断 channel_expr 是否为真正的 recv()/tryRecv() 调用
                const is_chan_recv = switch (arm.receive.channel_expr.*) {
                    .method_call => |mc| std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv"),
                    .safe_method_call => |mc| std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv"),
                    else => false,
                };

                if (is_chan_recv) {
                    // 真正的通道接收：发射 orbit_chan_recv 消费值
                    const recv_out = try self.allocChannel(.i64_chan);
                    try self.emit(Node.makeUnary(.orbit_chan_recv, recv_out, 0, arm_chans[i]));

                    if (arm.receive.binding != null) {
                        try self.pushScope();
                        try self.defineVar(arm.receive.binding.?, recv_out, false);
                    }
                } else if (arm.receive.binding != null) {
                    // 非通道源（标量等）：直接绑定源值
                    try self.pushScope();
                    try self.defineVar(arm.receive.binding.?, arm_chans[i], false);
                }
            }
            const body_out = try self.compileExpr(switch (arm) {
                .receive => |r| r.body,
                .timeout => |t| t.body,
            });
            if (arm == .receive and arm.receive.binding != null) {
                self.popScope();
            }
            body_lens[i] = @intCast(self.nodes.items.len - body_starts[i]);
            _ = body_out;
        }

        // 4. 发射 route_dispatch 节点（按 winner 索引执行对应 body 子图）
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = @intCast(arm_count),
            .body_starts = body_starts,
            .body_lens = body_lens,
        });

        const result_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));

        return result_chan;
    }

    /// 编译 non_null_assert (expr!)：断言 nullable 非 null，提取内部值
    /// 等价于 nullable_unwrap，null 时 panic
    fn compileNonNullAssert(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        const src_chan = try self.compileExpr(expr);
        const src_meta = self.channels.get(src_chan);

        // 如果已经是 nullable_chan，直接 unwrap
        if (src_meta.chan_type == .nullable_chan) {
            const out = try self.allocChannel(src_meta.inner_type);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, src_chan));
            return out;
        }

        // 如果是 ref_chan，包装为 nullable 后 unwrap（null 时 panic）
        if (src_meta.chan_type == .ref_chan) {
            const nullable_chan = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nullable_chan, 0, src_chan));
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, nullable_chan));
            return out;
        }

        // 其他类型：直接传递（不可能为 null）
        return src_chan;
    }

    /// 编译 safe_access (obj?.field)：null 时返回 null，否则访问字段
    fn compileSafeAccess(self: *IRBuilder, object: *const ast.Expr, field: []const u8, safe_access_expr: *const ast.Expr) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const obj_meta = self.channels.get(obj_chan);

        // 从 sema 查询 safe_access 表达式的字段类型
        // safe_access 的 chan_type 是 nullable_chan，inner_type 是字段的实际类型
        const sema_field_ct: ?ChanType = blk: {
            if (self.sema_result) |sr| {
                if (sr.getExpr(@intFromPtr(safe_access_expr))) |info| {
                    if (info.chan_type == .nullable_chan and info.inner_type != .null_chan) {
                        break :blk info.inner_type;
                    }
                    if (info.chan_type != .null_chan and info.chan_type != .nullable_chan) {
                        break :blk info.chan_type;
                    }
                }
            }
            break :blk null;
        };

        // null_literal：直接返回 null_chan（结果确定为 null）
        if (obj_meta.chan_type == .null_chan) {
            const null_result = try self.allocChannel(.null_chan);
            try self.emit(Node.makeSink(.const_null, null_result, 0));
            return null_result;
        }

        // 如果是 ref_chan，先包装为 nullable
        const nullable_chan = if (obj_meta.chan_type == .nullable_chan)
            obj_chan
        else if (obj_meta.chan_type == .ref_chan) blk: {
            const nc = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        } else obj_chan;

        // 如果不是 nullable（例如基本类型），直接做字段访问
        if (obj_meta.chan_type != .nullable_chan and obj_meta.chan_type != .ref_chan and obj_meta.chan_type != .null_chan) {
            return self.compileFieldAccessOnChan(obj_chan, field, object, sema_field_ct);
        }

        // 检查是否为 null
        const is_null_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));

        // unwrap 后访问字段（null 时 unwrap 写零，record_get 需安全处理）
        const inner_type = if (obj_meta.chan_type == .nullable_chan) obj_meta.inner_type else obj_meta.chan_type;
        const unwrapped_chan = try self.allocChannel(inner_type);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // 在 unwrapped 上做字段访问
        const field_chan = self.compileFieldAccessOnChan(unwrapped_chan, field, object, sema_field_ct);
        const field_meta = self.channels.get(field_chan);
        const field_ct = field_meta.chan_type;

        // 结果为 nullable<field_type>
        const result_chan = try self.channels.allocNullable(field_ct);

        // null 分支：nullable_make(null_chan) → null flag = 1
        const null_input = try self.allocChannel(.null_chan);
        try self.emit(Node.makeSink(.const_null, null_input, 0));
        const null_nullable_chan = try self.channels.allocNullable(field_ct);
        try self.emit(Node.makeUnary(.nullable_make, null_nullable_chan, 0, null_input));

        // field 分支：nullable_make(field_chan) → null flag = 0
        const field_nullable_chan = try self.channels.allocNullable(field_ct);
        try self.emit(Node.makeUnary(.nullable_make, field_nullable_chan, 0, field_chan));

        // vec_select: inputs[0]=then_val(cond=true→is_null→null), inputs[1]=else_val(cond=false→not null→field), inputs[2]=cond
        const sel_inputs: [4]u16 = .{ null_nullable_chan, field_nullable_chan, is_null_chan, 0 };
        try self.emit(Node{
            .op = .vec_select,
            .input_count = 3,
            .output = result_chan,
            .meta_index = 0,
            .inputs = sel_inputs,
        });

        return result_chan;
    }

    /// 在已有通道上编译字段访问（复用 record_get 逻辑）
    fn compileFieldAccessOnChan(self: *IRBuilder, obj_chan: u16, field: []const u8, object: *const ast.Expr, sema_chan_type: ?ChanType) u16 {
        // 解析 field_id（与 compileFieldAccess 相同逻辑）
        const field_id: u16 = blk: {
            if (std.mem.eql(u8, field, "__tag")) break :blk 0;
            if (self.inferTypeNameFromExpr(object)) |type_name| {
                if (self.lookupFieldId(type_name, field)) |id| break :blk id;
            }
            if (self.lookupFieldId("", field)) |id| break :blk id;
            break :blk 0;
        };
        const meta_idx = self.addFieldIdMeta(field_id) catch return obj_chan;
        // 优先使用调用方传入的 sema chan_type（来自 field_access 或 safe_access 的 inner_type）
        const chan_type: ChanType = sema_chan_type orelse self.inferFieldType(object, field) orelse .i64_chan;
        const out = self.allocChannel(chan_type) catch return obj_chan;
        self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan)) catch return obj_chan;
        return out;
    }

    /// 从表达式推断类型名（用于用户自定义方法调用 obj.method()）
    /// 仅支持构造器调用和标识符引用构造器的场景
    fn inferTypeNameFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        // 优先接入 sema：若 sema_result 记录了表达式的 type_name（adt/generic），
        // 直接返回。这覆盖了 method_call 返回值、self.field 等场景。
        if (self.sema_result) |sr| {
            if (sr.getExpr(@intFromPtr(expr))) |info| {
                if (info.type_name) |tn| {
                    return tn;
                }
            }
        }
        switch (expr.*) {
            .call => |c| {
                if (c.callee.* == .identifier) {
                    // typeof(TypeName) 返回 TypeInfo RecordValue
                    if (std.mem.eql(u8, c.callee.identifier.name, "typeof")) {
                        return "TypeInfo";
                    }
                    if (self.ctor_table.get(c.callee.identifier.name)) |ctor| {
                        return ctor.type_name;
                    }
                }
                return null;
            },
            .identifier => |id| {
                // 构造器名（enum variant）
                if (self.ctor_table.get(id.name)) |ctor| {
                    if (ctor.fields.len == 0) return ctor.type_name;
                }
                // 变量：通过 ast_expr 递归推断类型
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |var_expr| {
                        return self.inferTypeNameFromExpr(var_expr);
                    }
                    // self 参数：使用当前类型上下文
                    if (std.mem.eql(u8, id.name, "self")) {
                        if (self.current_type_context) |tc| return tc;
                    }
                }
                return null;
            },
            .field_access => |fa| {
                // 情况 0：base 是 TypeInfo，反射子结构字段访问
                // info.layout → LayoutInfo，info.impls → TraitImplInfo
                // structure 字段类型名因 kind 而异（Adt/Record/Newtype/...），无法静态确定
                if (self.inferTypeNameFromExpr(fa.object)) |base_type| {
                    if (std.mem.eql(u8, base_type, "TypeInfo")) {
                        if (std.mem.eql(u8, fa.field, "layout")) return "LayoutInfo";
                        if (std.mem.eql(u8, fa.field, "impls")) return "TraitImplInfo";
                    }
                }
                // 情况 1：base 是命名类型，从构造器字段查字段类型
                if (self.inferTypeNameFromExpr(fa.object)) |base_type| {
                    if (self.type_table.get(base_type)) |ti| {
                        for (ti.constructors) |ctor| {
                            for (ctor.fields) |f| {
                                if (std.mem.eql(u8, f.name, fa.field)) {
                                    if (f.type_node) |tn| {
                                        if (tn.* == .named) return tn.named.name;
                                    }
                                }
                            }
                        }
                    }
                }
                // 情况 2：base 是 record_literal（直接或通过变量绑定），从字段值推断类型
                const base_expr: ?*const ast.Expr = switch (fa.object.*) {
                    .record_literal => fa.object,
                    .identifier => |id| blk: {
                        if (self.lookupVar(id.name)) |binding| {
                            if (binding.ast_expr) |var_expr| {
                                if (var_expr.* == .record_literal) break :blk var_expr;
                            }
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (base_expr) |be| {
                    for (be.record_literal.fields) |rf| {
                        if (std.mem.eql(u8, rf.name, fa.field)) {
                            return self.inferTypeNameFromExpr(rf.value);
                        }
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// 从表达式推断 Trait 类型名（用于一等 Trait 值的方法分派）
    /// 通过变量绑定的类型标注查找 trait_table
    fn inferTraitNameFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.type_annotation) |tn| {
                        if (tn.* == .named) {
                            if (self.trait_table.contains(tn.named.name)) {
                                return tn.named.name;
                            }
                        }
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// 判断表达式是否为字符串类型（直接字面量或绑定了字符串字面量的变量）
    fn isStringExpr(self: *IRBuilder, expr: *const ast.Expr) bool {
        switch (expr.*) {
            .string_literal, .string_interpolation => return true,
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |var_expr| {
                        return self.isStringExpr(var_expr);
                    }
                    // 检查类型标注
                    if (binding.type_annotation) |tn| {
                        return isStringTypeNode(tn);
                    }
                }
                return false;
            },
            .field_access => |fa| {
                // base 是 record_literal（直接或通过变量绑定），查字段的值是否为字符串
                const base_expr: ?*const ast.Expr = switch (fa.object.*) {
                    .record_literal => fa.object,
                    .identifier => |id| blk: {
                        if (self.lookupVar(id.name)) |binding| {
                            if (binding.ast_expr) |var_expr| {
                                if (var_expr.* == .record_literal) break :blk var_expr;
                            }
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (base_expr) |be| {
                    for (be.record_literal.fields) |rf| {
                        if (std.mem.eql(u8, rf.name, fa.field)) {
                            return self.isStringExpr(rf.value);
                        }
                    }
                }
                return false;
            },
            .binary => |b| {
                // 字符串拼接：+ 或 ++ 且至少一侧为字符串
                if (b.op == .add or b.op == .concat_list) {
                    return self.isStringExpr(b.left) or self.isStringExpr(b.right);
                }
                return false;
            },
            .block => |blk| {
                if (blk.trailing_expr) |te| return self.isStringExpr(te);
                return false;
            },
            .if_expr => |ie| {
                // if-else 两侧都为字符串时结果为字符串
                if (ie.else_branch) |else_b| {
                    return self.isStringExpr(ie.then_branch) and self.isStringExpr(else_b);
                }
                return false;
            },
            .match => |m| {
                // 所有 arm 都为字符串时结果为字符串
                for (m.arms) |arm| {
                    if (!self.isStringExpr(arm.body)) return false;
                }
                return true;
            },
            .call => |c| {
                // 检查是否为返回 str 的函数调用
                switch (c.callee.*) {
                    .identifier => |id| {
                        return self.func_returns_str.contains(id.name);
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// 检查表达式是否为字符串（通过变量绑定的类型标注推断）
    /// 用于处理函数参数带 str 类型标注的情况
    fn isStringParam(self: *IRBuilder, expr: *const ast.Expr) bool {
        switch (expr.*) {
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.type_annotation) |tn| {
                        return isStringTypeNode(tn);
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// 编译方法调用：obj.method(args)
    /// safe=true 时为 obj?.method(args)，先做 null 检查
    fn compileMethodCall(self: *IRBuilder, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr, safe: bool) BuildError!u16 {
        // 模块引用方法调用：Module.Sub.method(args) → 直接调用模块函数，不需要 obj_chan
        if (!safe and self.isModuleReference(object) != null) {
            return try self.dispatchMethodCall(0, object, method, arguments);
        }

        const obj_chan = try self.compileExpr(object);

        // safe_method_call：obj?.method(args) — obj 为 null 时返回 null
        if (safe) {
            return try self.compileSafeMethodCall(obj_chan, object, method, arguments);
        }

        return try self.dispatchMethodCall(obj_chan, object, method, arguments);
    }

    /// 安全方法调用：obj?.method(args)
    /// obj 为 null 时返回 null，否则调用方法
    fn compileSafeMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr) BuildError!u16 {
        const obj_meta = self.channels.get(obj_chan);
        // 非 nullable/ref 直接调用
        if (obj_meta.chan_type != .nullable_chan and obj_meta.chan_type != .ref_chan) {
            return try self.dispatchMethodCall(obj_chan, object, method, arguments);
        }
        // 包装为 nullable
        const nullable_chan = if (obj_meta.chan_type == .nullable_chan)
            obj_chan
        else blk: {
            const nc = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        };
        const is_null_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));
        const unwrapped_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // then 子图：unwrapped.method(args)
        const else_start: u32 = @intCast(self.nodes.items.len);
        const null_out = try self.allocChannel(.null_chan);
        try self.emit(Node.makeSink(.const_null, null_out, 0));
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_out = try self.dispatchMethodCall(unwrapped_chan, object, method, arguments);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_out).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_out));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, is_null_chan));

        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const result_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_out = try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_out, route_meta_idx, winner_chan));
        return result_out;
    }

    /// 模块引用：{ module_name, sub_name }
    const ModuleRef = struct {
        module_name: []const u8,
        sub_name: []const u8,
    };

    /// 检查表达式是否为模块引用（field_access(identifier(已导入模块名), 子模块名)）
    fn isModuleReference(self: *IRBuilder, expr: *const ast.Expr) ?ModuleRef {
        switch (expr.*) {
            .field_access => |fa| {
                switch (fa.object.*) {
                    .identifier => |id| {
                        if (self.imported_modules.contains(id.name)) {
                            return .{ .module_name = id.name, .sub_name = fa.field };
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        return null;
    }

    /// 按方法名分派：用户自定义方法优先，其次内置方法
    fn dispatchMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr) BuildError!u16 {
        // ── 模块引用方法调用：Module.Sub.method(args) → call("Module.Sub.method", args) ──
        if (self.isModuleReference(object)) |mod_ref| {
            const arena_alloc = self.arena.allocator();
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}.{s}", .{ mod_ref.module_name, mod_ref.sub_name, method });
            if (self.func_table.get(mangled)) |func_idx| {
                const func = self.functions.items[func_idx];
                var arg_chans = try arena_alloc.alloc(u16, arguments.len);
                for (arguments, 0..) |arg, i| {
                    arg_chans[i] = try self.compileExpr(arg);
                }
                const out = try self.allocChannel(self.channels.get(func.return_channel).chan_type);
                const call_meta_idx = try self.addCallMeta(.{
                    .func_index = func_idx,
                    .arg_count = @intCast(arg_chans.len),
                });
                var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                for (arg_chans, 0..) |ch, i| {
                    if (i < 4) inputs[i] = ch;
                }
                try self.emit(Node{
                    .op = .call,
                    .input_count = @intCast(@min(arg_chans.len, 4)),
                    .output = out,
                    .meta_index = call_meta_idx,
                    .inputs = inputs,
                });
                return out;
            }
        }

        // ── 用户自定义方法优先：obj.method(args) → call("TypeName.method", [obj, ...args]) ──
        if (self.inferTypeNameFromExpr(object)) |type_name| {
            const arena_alloc = self.arena.allocator();
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ type_name, method });
            if (self.func_table.get(mangled)) |func_idx| {
                const func = self.functions.items[func_idx];
                var arg_chans = try arena_alloc.alloc(u16, arguments.len + 1);
                arg_chans[0] = obj_chan;
                for (arguments, 0..) |arg, i| {
                    arg_chans[i + 1] = try self.compileExpr(arg);
                }
                const out = try self.allocChannel(self.channels.get(func.return_channel).chan_type);
                const call_meta_idx = try self.addCallMeta(.{
                    .func_index = func_idx,
                    .arg_count = @intCast(arg_chans.len),
                });
                var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                for (arg_chans, 0..) |ch, i| {
                    if (i < 4) inputs[i] = ch;
                }
                try self.emit(Node{
                    .op = .call,
                    .input_count = @intCast(@min(arg_chans.len, 4)),
                    .output = out,
                    .meta_index = call_meta_idx,
                    .inputs = inputs,
                });
                return out;
            }
        }

        // ── Trait 值方法分派：obj.method(args) → array_get(obj, method_idx) + call_indirect ──
        // 一等 Trait 值（inline_trait_value）编译为闭包数组，按方法索引存储
        if (self.inferTraitNameFromExpr(object)) |trait_name| {
            if (self.trait_table.get(trait_name)) |trait_info| {
                // 查找方法在 trait 中的索引
                var method_idx: ?usize = null;
                for (trait_info.methods, 0..) |m, i| {
                    if (std.mem.eql(u8, m.name, method)) {
                        method_idx = i;
                        break;
                    }
                }
                if (method_idx) |idx| {
                    const arena_alloc = self.arena.allocator();
                    // array_get(obj_chan, idx) → closure_chan
                    const idx_chan = try self.allocChannel(.i64_chan);
                    const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(idx) } });
                    try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
                    const closure_chan = try self.allocChannel(.ref_chan);
                    try self.emit(Node.makeBinary(.array_get, closure_chan, 0, obj_chan, idx_chan));

                    // call_indirect(closure_chan, args)
                    var arg_chans = try arena_alloc.alloc(u16, arguments.len);
                    for (arguments, 0..) |arg, i| {
                        arg_chans[i] = try self.compileExpr(arg);
                    }

                    // 结果类型：从 trait 方法返回类型推断
                    const ret_chan_type = if (trait_info.methods[idx].return_type) |rt|
                        chanTypeFromTypeNode(rt) orelse .i64_chan
                    else
                        .i64_chan;
                    const out = try self.allocChannel(ret_chan_type);
                    const call_meta_idx = try self.addCallMeta(.{
                        .func_index = 0,
                        .arg_count = @intCast(arguments.len + 1),
                    });

                    var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                    inputs[0] = closure_chan;
                    for (arg_chans, 0..) |ch, i| {
                        if (i + 1 < 4) inputs[i + 1] = ch;
                    }
                    try self.emit(Node{
                        .op = .call_indirect,
                        .input_count = @intCast(@min(arguments.len + 1, 4)),
                        .output = out,
                        .meta_index = call_meta_idx,
                        .inputs = inputs,
                    });
                    return out;
                }
            }
        }

        // ── 内置方法（按名称分派） ──
        if (std.mem.eql(u8, method, "await")) {
            // obj.await() → orbit_async_join
            // 结果类型默认 i64（无类型追踪，大多数 async 函数返回标量）
            // engine 的 execOrbitAsyncJoin 不依赖 meta_index，直接从 handle 读取结果
            const out = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.orbit_async_join, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "status")) {
            // obj.status() → orbit_async_status，返回 i64
            const out = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.orbit_async_status, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "send")) {
            // ch.send(v) → orbit_chan_send
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            return try self.emitOrbitSend(obj_chan, val_chan);
        }
        if (std.mem.eql(u8, method, "recv")) {
            // ch.recv() → orbit_chan_recv，结果类型默认 i64
            return try self.emitOrbitRecv(obj_chan, .i64_chan);
        }
        if (std.mem.eql(u8, method, "tryRecv")) {
            // ch.tryRecv() → orbit_chan_try_recv，返回 nullable
            return try self.emitOrbitTryRecv(obj_chan, .i64_chan);
        }
        if (std.mem.eql(u8, method, "close")) {
            // ch.close() → channel_close，返回 unit
            const out = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeUnary(.channel_close, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "swap")) {
            // atm.swap(v) → atomic_swap，返回旧值
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const obj_meta = self.channels.get(obj_chan);
            const out = try self.allocChannel(obj_meta.chan_type);
            try self.emit(Node.makeBinary(.atomic_swap, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "cas")) {
            // atm.cas(expected, new) → atomic_cas，返回 bool
            if (arguments.len != 2) return error.UnsupportedExpr;
            const expected_chan = try self.compileExpr(arguments[0]);
            const new_chan = try self.compileExpr(arguments[1]);
            const out = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeTernary(.atomic_cas, out, 0, obj_chan, expected_chan, new_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "len")) {
            // obj.len() → string_len 或 array_len（按 AST 推断 + 参数类型标注）
            // Phase 5: 返回类型从 i64 改为 usize（spec §8.1）
            const is_string = self.isStringExpr(object) or self.isStringParam(object);
            if (is_string) {
                const out = try self.allocChannel(.usize_chan);
                try self.emit(Node.makeUnary(.string_len, out, 0, obj_chan));
                return out;
            }
            const out = try self.allocChannel(.usize_chan);
            try self.emit(Node.makeUnary(.array_len, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "push")) {
            // arr.push(v) → array_push，返回数组引用（支持 result = arr.push(x)）
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeBinary(.array_push, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "pop")) {
            // arr.pop() → array_pop，返回弹出的元素（ref）
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.array_pop, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "first")) {
            // arr.first() → array_first，返回 nullable i64（可能为空数组）
            const out = try self.channels.allocNullable(.i64_chan);
            try self.emit(Node.makeUnary(.array_first, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "last")) {
            // arr.last() → array_last，返回 nullable i64（可能为空数组）
            const out = try self.channels.allocNullable(.i64_chan);
            try self.emit(Node.makeUnary(.array_last, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "is_empty")) {
            // arr.is_empty() / s.is_empty() → len == 0 → bool
            const is_string = self.isStringExpr(object);
            const len_op: NodeOp = if (is_string) .string_len else .array_len;
            // Phase 5: len 返回 usize
            const len_chan = try self.allocChannel(.usize_chan);
            try self.emit(Node.makeUnary(len_op, len_chan, 0, obj_chan));
            // 创建常量 0 通道用于比较
            const zero_chan = try self.allocChannel(.usize_chan);
            const zero_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .usize, .const_val = .{ .int_val = 0 } });
            try self.emit(Node.makeSink(.const_i, zero_chan, zero_meta));
            const out = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeBinary(.cmp_eq, out, 0, len_chan, zero_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // arr.contains(v) / s.contains(ch) → array_contains / string_contains
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.bool_chan);
            const is_string = self.isStringExpr(object);
            const op: NodeOp = if (is_string) .string_contains else .array_contains;
            try self.emit(Node.makeBinary(op, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "drop_last")) {
            // arr.drop_last() → array_drop_last，返回新数组（ref）
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.array_drop_last, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "get")) {
            // arr.get(i) → array_get_safe，返回 nullable（安全索引）
            if (arguments.len != 1) return error.UnsupportedExpr;
            const idx_chan = try self.compileExpr(arguments[0]);
            const out = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeBinary(.array_get_safe, out, 0, obj_chan, idx_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "message")) {
            // e.message() → error_message，返回 str ref
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.error_message, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "type_name")) {
            // obj.type_name() → obj_type_name，返回 str ref
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.obj_type_name, out, 0, obj_chan));
            return out;
        }

        return error.UnsupportedExpr;
    }

    /// 收集表达式中的自由变量（不在 param_names 中的标识符）
    fn collectFreeVars(self: *IRBuilder, expr: *const ast.Expr, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (expr.*) {
            .identifier => |id| {
                // 排除 lambda 参数
                for (param_names) |pn| {
                    if (std.mem.eql(u8, pn, id.name)) return;
                }
                // 只收集当前作用域中存在的变量（可捕获的）
                if (self.lookupVar(id.name) != null) {
                    out.put(id.name, {}) catch {};
                }
            },
            .binary => |b| {
                self.collectFreeVars(b.left, param_names, out);
                self.collectFreeVars(b.right, param_names, out);
            },
            .unary => |u| self.collectFreeVars(u.operand, param_names, out),
            .call => |c| {
                self.collectFreeVars(c.callee, param_names, out);
                for (c.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .if_expr => |ie| {
                self.collectFreeVars(ie.condition, param_names, out);
                self.collectFreeVars(ie.then_branch, param_names, out);
                if (ie.else_branch) |eb| self.collectFreeVars(eb, param_names, out);
            },
            .block => |blk| {
                for (blk.statements) |s| self.collectFreeVarsStmt(s, param_names, out);
                if (blk.trailing_expr) |te| self.collectFreeVars(te, param_names, out);
            },
            .method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .field_access => |fa| self.collectFreeVars(fa.object, param_names, out),
            .index => |idx| {
                self.collectFreeVars(idx.object, param_names, out);
                self.collectFreeVars(idx.index, param_names, out);
            },
            .match => |m| {
                self.collectFreeVars(m.scrutinee, param_names, out);
                for (m.arms) |arm| self.collectFreeVars(arm.body, param_names, out);
            },
            .propagate => |p| self.collectFreeVars(p.expr, param_names, out),
            .non_null_assert => |nn| self.collectFreeVars(nn.expr, param_names, out),
            .safe_access => |sa| self.collectFreeVars(sa.object, param_names, out),
            .safe_method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .assignment_expr => |a| {
                self.collectFreeVars(a.target, param_names, out);
                self.collectFreeVars(a.value, param_names, out);
            },
            .compound_assign => |ca| {
                self.collectFreeVars(ca.target, param_names, out);
                self.collectFreeVars(ca.value, param_names, out);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) self.collectFreeVars(part.expression, param_names, out);
                }
            },
            else => {},
        }
    }

    fn collectFreeVarsStmt(self: *IRBuilder, stmt: *const ast.Stmt, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (stmt.*) {
            .val_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .var_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .expression => |es| self.collectFreeVars(es.expr, param_names, out),
            .defer_stmt => |ds| self.collectFreeVars(ds.expr, param_names, out),
            else => {},
        }
    }

    /// 编译 lambda 表达式为匿名函数 + closure_make 节点
    /// 1. 收集自由变量（捕获上值）
    /// 2. 注册匿名函数（params = lambda参数 + 上值参数）
    /// 3. 编译函数体
    /// 4. 发射 closure_make 节点（携带上值通道）
    fn compileLambda(self: *IRBuilder, lam: anytype) BuildError!u16 {
        const arena_alloc = self.arena.allocator();

        // 提前分配 closure_make 的输出通道，以便预声明递归 lambda 名
        const closure_out_chan = try self.allocChannel(.ref_chan);
        // 如果有预声明的 lambda 名（val name = fun(...) { ... } 形式），先绑定到输出通道
        // 这样 lambda body 内可以递归引用自身
        var pre_decl_name: ?[]const u8 = null;
        if (self.pre_declared_lambda_names.items.len > 0) {
            pre_decl_name = self.pre_declared_lambda_names.items[self.pre_declared_lambda_names.items.len - 1];
            // 将 lambda 返回类型作为 type_annotation 存储，供 compileCall 推断间接调用返回类型
            try self.scopeVarTyped(pre_decl_name.?, closure_out_chan, false, null, lam.return_type);
            // 如果 lambda 返回 Throw，记录到持久集合（跨作用域有效，供 exprIsThrowValue 查询）
            if (isThrowType(lam.return_type)) {
                try self.lambda_returns_throw.put(pre_decl_name.?, {});
            }
        }

        // 1. 收集自由变量
        var free_vars = std.StringHashMap(void).init(arena_alloc);
        defer free_vars.deinit();
        const body_expr: *const ast.Expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        // 构造参数名列表
        var param_names = std.ArrayList([]const u8).empty;
        defer param_names.deinit(arena_alloc);
        for (lam.params) |p| param_names.append(arena_alloc, p.name) catch return error.OutOfMemory;
        self.collectFreeVars(body_expr, param_names.items, &free_vars);

        // 2. 收集上值通道（按插入顺序）
        var upvalue_names = std.ArrayList([]const u8).empty;
        defer upvalue_names.deinit(arena_alloc);
        var upvalue_chans = std.ArrayList(u16).empty;
        defer upvalue_chans.deinit(arena_alloc);
        var fv_it = free_vars.iterator();
        while (fv_it.next()) |entry| {
            if (self.lookupVar(entry.key_ptr.*)) |binding| {
                upvalue_names.append(arena_alloc, entry.key_ptr.*) catch return error.OutOfMemory;
                upvalue_chans.append(arena_alloc, binding.chan) catch return error.OutOfMemory;
            }
        }

        // 3. 注册匿名函数
        const lambda_counter = self.lambda_counter;
        self.lambda_counter += 1;
        const func_name = std.fmt.allocPrint(arena_alloc, "__lambda_{d}", .{lambda_counter}) catch return error.OutOfMemory;
        const func_idx: u16 = @intCast(self.functions.items.len);
        try self.func_table.put(func_name, func_idx);

        // 返回类型
        const return_type = chanTypeFromTypeNode(lam.return_type) orelse .i64_chan;
        const placeholder_return_chan = try self.allocChannel(return_type);
        try self.functions.append(arena_alloc, .{
            .name = func_name,
            .node_start = 0,
            .node_count = 0,
            .param_channels = &.{},
            .return_channel = placeholder_return_chan,
            .is_entry = false,
            .is_async = lam.is_async,
        });

        // 4. 编译函数体（params = lambda参数 + 上值参数）
        const saved_return_chan = self.current_return_chan;
        const saved_returns_throw = self.current_returns_throw;
        const saved_throw_ok_chan_type = self.current_throw_ok_chan_type;
        const lambda_body_start: u32 = @intCast(self.nodes.items.len);
        const node_start: u32 = lambda_body_start;
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        // 分配参数通道
        var all_param_chans = try arena_alloc.alloc(u16, lam.params.len + upvalue_names.items.len);
        for (lam.params, 0..) |param, i| {
            const chan_type = if (param.type_annotation) |tn|
                chanTypeFromTypeNode(tn) orelse .i64_chan
            else
                .i64_chan;
            const chan = try self.allocChannel(chan_type);
            all_param_chans[i] = chan;
            try self.defineVar(param.name, chan, false);
        }
        // 上值参数通道
        for (upvalue_names.items, 0..) |name, i| {
            const idx = lam.params.len + i;
            const upval_chan_type = self.channels.get(upvalue_chans.items[i]).chan_type;
            const chan = try self.allocChannel(upval_chan_type);
            all_param_chans[idx] = chan;
            // 从原始绑定继承类型标注与 ast_expr（用于 isStringExpr 等类型推断）
            const orig_binding = self.lookupVar(name);
            try self.scopeVarTyped(name, chan, false, if (orig_binding) |b| b.ast_expr else null, if (orig_binding) |b| b.type_annotation else null);
        }
        const return_chan = placeholder_return_chan;
        self.current_return_chan = return_chan;
        self.current_returns_throw = isThrowType(lam.return_type);
        if (self.current_returns_throw) {
            self.current_throw_ok_chan_type = throwOkChanType(lam.return_type) orelse .i64_chan;
        }

        // 编译函数体
        const body_chan = try self.compileExpr(body_expr);
        const final_chan = if (self.current_returns_throw and !self.exprIsThrowValue(body_expr)) blk: {
            const wrap_out = try self.allocChannel(.ref_chan);
            const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
            try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, body_chan));
            break :blk wrap_out;
        } else body_chan;
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, final_chan));

        self.current_return_chan = saved_return_chan;
        self.current_returns_throw = saved_returns_throw;
        self.current_throw_ok_chan_type = saved_throw_ok_chan_type;
        self.popScope();

        const node_count: u32 = @intCast(self.nodes.items.len - node_start);
        const chan_end: u16 = self.channels.count();
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = all_param_chans;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;

        // 5. 发射 closure_make 节点
        // 标记哪些 upvalue 是 cell 通道（var 变量，引用语义）
        var cell_upvalues: u8 = 0;
        for (upvalue_chans.items, 0..) |ch, i| {
            if (i >= 8) break;
            if (self.channels.get(ch).is_cell) cell_upvalues |= @as(u8, 1) << @intCast(i);
        }
        const closure_meta_idx = try self.addClosureMeta(.{
            .func_index = func_idx,
            .upvalue_count = @intCast(upvalue_chans.items.len),
            .result_type = return_type,
            .body_start = lambda_body_start,
            .body_len = node_count,
            .cell_upvalues = cell_upvalues,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (upvalue_chans.items, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .closure_make,
            .input_count = @intCast(@min(upvalue_chans.items.len, 4)),
            .output = closure_out_chan,
            .meta_index = closure_meta_idx,
            .inputs = inputs,
        });
        return closure_out_chan;
    }

    /// 检测线性递归模式：fun f(n: T): T { if n < 2 { n } else { f(n-1) op f(n-2) } }
    /// 支持 op ∈ {add, mul, bit_and, bit_or, bit_xor}（结合律保证 vec_scan 正确）
    /// 返回 LinearRecurrenceInfo（init_a=0, init_b=1 对应 base case f(0)=0, f(1)=1）
    fn tryDetectLinearRecurrence(self: *IRBuilder, func_name: []const u8, fd: anytype) !?LinearRecurrenceInfo {
        // 必须恰好 1 个参数
        if (fd.params.len != 1) return null;
        const param = fd.params[0];
        const param_name = param.name;
        // 参数必须是整数类型
        const chan_type = if (param.type_annotation) |tn|
            chanTypeFromTypeNode(tn) orelse .i64_chan
        else
            .i64_chan;
        if (!chan_type.isInt()) return null;

        // 函数体必须是 if_expr（允许包裹在无语句的 block 中）
        const body_expr = unwrapBlockExpr(fd.body);
        if (body_expr.* != .if_expr) return null;
        const ie = body_expr.if_expr;

        // 条件必须是 param < 2 或 param <= 1
        if (ie.condition.* != .binary) return null;
        const cond_bin = ie.condition.binary;
        var digit_buf: [64]u8 = undefined;
        const threshold: i64 = blk: {
            if (cond_bin.op == .lt) {
                if (cond_bin.left.* == .identifier and
                    std.mem.eql(u8, cond_bin.left.identifier.name, param_name) and
                    cond_bin.right.* == .int_literal)
                {
                    break :blk std.fmt.parseInt(i64, filterDigits(cond_bin.right.int_literal.raw, &digit_buf), 10) catch return null;
                }
            } else if (cond_bin.op == .lt_eq) {
                if (cond_bin.left.* == .identifier and
                    std.mem.eql(u8, cond_bin.left.identifier.name, param_name) and
                    cond_bin.right.* == .int_literal)
                {
                    const v = std.fmt.parseInt(i64, filterDigits(cond_bin.right.int_literal.raw, &digit_buf), 10) catch return null;
                    break :blk v + 1; // n <= 1 等价于 n < 2
                }
            }
            return null;
        };
        if (threshold != 2) return null; // 仅支持 K=2

        // then 分支必须是 identifier(param_name)（允许包裹在无语句 block 中）
        const then_expr = unwrapBlockExpr(ie.then_branch);
        if (then_expr.* != .identifier) return null;
        if (!std.mem.eql(u8, then_expr.identifier.name, param_name)) return null;

        // else 分支必须是 binary(op, call, call)（允许包裹在无语句 block 中）
        if (ie.else_branch == null) return null;
        const else_expr = unwrapBlockExpr(ie.else_branch.?);
        if (else_expr.* != .binary) return null;
        const rec_bin = else_expr.binary;

        // 映射运算符
        const node_op: NodeOp = switch (rec_bin.op) {
            .add => .int_add,
            .mul => .int_mul,
            .bit_and => .int_and,
            .bit_or => .int_or,
            .bit_xor => .int_xor,
            else => return null,
        };

        // 两个操作数必须是 f(n-1) 和 f(n-2)
        const left_is_rec = self.isSelfCallWithOffset(rec_bin.left, func_name, param_name, 1);
        const right_is_rec = self.isSelfCallWithOffset(rec_bin.right, func_name, param_name, 2);
        const left_is_rec2 = self.isSelfCallWithOffset(rec_bin.left, func_name, param_name, 2);
        const right_is_rec1 = self.isSelfCallWithOffset(rec_bin.right, func_name, param_name, 1);
        if (!((left_is_rec and right_is_rec) or (left_is_rec2 and right_is_rec1))) return null;

        return LinearRecurrenceInfo{
            .op = node_op,
            .init_a = 0, // f(0) = 0
            .init_b = 1, // f(1) = 1
            .elem_type = chan_type,
        };
    }

    /// 检查 expr 是否为 f(param - offset) 形式的自递归调用
    fn isSelfCallWithOffset(self: *IRBuilder, expr: *const ast.Expr, func_name: []const u8, param_name: []const u8, offset: i64) bool {
        _ = self;
        if (expr.* != .call) return false;
        const call = expr.call;
        if (call.callee.* != .identifier) return false;
        if (!std.mem.eql(u8, call.callee.identifier.name, func_name)) return false;
        if (call.arguments.len != 1) return false;
        const arg = call.arguments[0];
        if (arg.* != .binary) return false;
        const sub = arg.binary;
        if (sub.op != .sub) return false;
        // param - offset
        if (sub.left.* == .identifier and
            std.mem.eql(u8, sub.left.identifier.name, param_name) and
            sub.right.* == .int_literal)
        {
            var buf: [64]u8 = undefined;
            const v = std.fmt.parseInt(i64, filterDigits(sub.right.int_literal.raw, &buf), 10) catch return false;
            return v == offset;
        }
        return false;
    }

    /// 编译线性递归为迭代 scalar_loop：
    /// 状态 (a, b) 初始 (init_a, init_b)，每次 (a, b) → (b, a op b)，循环 n 次后返回 a
    fn compileLinearRecurrenceCall(self: *IRBuilder, info: LinearRecurrenceInfo, n_chan: u16) BuildError!u16 {
        const elem_type = info.elem_type;

        // 分配 cell 通道：a, b, i（可变状态）
        const a_chan = try self.allocCellChannel(elem_type);
        const b_chan = try self.allocCellChannel(elem_type);
        const i_chan = try self.allocCellChannel(elem_type);

        // 初始化：a = init_a, b = init_b, i = 0
        const init_a_chan = try self.emitConstInt(info.init_a, elem_type);
        try self.emit(Node.makeUnary(.store, a_chan, 0, init_a_chan));
        const init_b_chan = try self.emitConstInt(info.init_b, elem_type);
        try self.emit(Node.makeUnary(.store, b_chan, 0, init_b_chan));
        const init_i_chan = try self.emitConstInt(0, elem_type);
        try self.emit(Node.makeUnary(.store, i_chan, 0, init_i_chan));

        // 编译 1 常量（供 i += 1 使用）
        const one_chan = try self.emitConstInt(1, elem_type);

        // scalar_loop body:
        //   cond: i < n  → cond_chan (bool)
        //   body: temp = a op b; store a = b; store b = temp; i_new = i + 1; store i = i_new
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 条件子图：cmp_lt(i_chan, n_chan)
        const cond_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeBinary(.cmp_lt, cond_chan, 0, i_chan, n_chan));
        const cond_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 循环体：temp = a op b
        const temp_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(info.op, temp_chan, 0, a_chan, b_chan));
        // store a = b
        try self.emit(Node.makeUnary(.store, a_chan, 0, b_chan));
        // store b = temp
        try self.emit(Node.makeUnary(.store, b_chan, 0, temp_chan));
        // i_new = i + 1
        const i_new_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.int_add, i_new_chan, 0, i_chan, one_chan));
        // store i = i_new
        try self.emit(Node.makeUnary(.store, i_chan, 0, i_new_chan));

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 scalar_loop
        const loop_out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .while_loop,
            .cond_len = cond_len,
            .cond_chan = cond_chan,
        });
        try self.emit(Node.makeSink(.scalar_loop, loop_out, meta_idx));

        // 结果 = a_chan（load 到新通道）
        const result_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.load, result_chan, 0, a_chan));

        return result_chan;
    }

    /// 发射整数常量到指定类型通道
    fn emitConstInt(self: *IRBuilder, value: i64, chan_type: ChanType) BuildError!u16 {
        const int_kind = chan_type.toIntKind() orelse .i64;
        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = int_kind,
            .const_val = .{ .int_val = @as(i128, value) },
        });
        try self.emit(Node.makeSink(.const_i, out, meta_idx));
        return out;
    }

    /// 编译间接调用（通过 closure 值调用）
    /// inputs[0] = closure_chan, inputs[1..M] = arg_channels
    fn compileCallIndirect(self: *IRBuilder, closure_chan: u16, arguments: []*ast.Expr, ret_chan_type: ChanType) BuildError!u16 {
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 使用传入的返回类型分配输出通道
        const out = try self.allocChannel(ret_chan_type);
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = 0, // 运行时从 closure 值读取
            .arg_count = @intCast(arguments.len + 1), // +1 for closure_chan
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        inputs[0] = closure_chan;
        for (arg_chans, 0..) |ch, i| {
            if (i + 1 < 4) inputs[i + 1] = ch;
        }
        try self.emit(Node{
            .op = .call_indirect,
            .input_count = @intCast(@min(arguments.len + 1, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译 atomic 表达式：atomic value → Cell 通道（线程安全的可变引用）
    /// 实现为 alloc + store，将值存储在堆上
    fn compileAtomicExpr(self: *IRBuilder, value_expr: *const ast.Expr) BuildError!u16 {
        const val_chan = try self.compileExpr(value_expr);
        const val_meta = self.channels.get(val_chan);
        // 分配 Cell 通道（与 var_decl 相同的模式）
        const cell_chan = try self.allocCellChannel(val_meta.chan_type);
        try self.emit(Node.makeUnary(.load, cell_chan, 0, val_chan));
        return cell_chan;
    }

    /// 编译 lazy 表达式：lazy expr → 延迟计算的 thunk（闭包）
    /// 实现为无参闭包，首次调用时计算 expr
    fn compileLazyExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 简化实现：直接编译表达式，返回其通道
        // 完整实现需要创建一个 thunk 闭包，在首次访问时才计算
        // 当前 Glue IR 没有 thunk 节点，使用直接求值（不影响正确性，只影响惰性语义）
        return try self.compileExpr(expr);
    }

    /// 编译 spawn 表达式：spawn expr → orbit_async_create（不自动 await）
    /// expr 应为 async 函数调用或 lambda
    fn compileSpawnExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 如果是函数调用，编译为 async create（不 join）
        switch (expr.*) {
            .call => |c| {
                // 检查是否为已注册的 async 函数
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => {
                        // 非函数名调用：先编译为 lambda 变量，然后 spawn
                        const lambda_chan = try self.compileExpr(expr);
                        return lambda_chan;
                    },
                };

                if (self.func_table.get(func_name)) |func_idx| {
                    const func = self.functions.items[func_idx];
                    if (func.is_async) {
                        // 编译参数为通道
                        var arg_chans_buf: [4]u16 = .{ 0, 0, 0, 0 };
                        const arg_count = @min(c.arguments.len, 4);
                        for (0..arg_count) |ai| {
                            arg_chans_buf[ai] = try self.compileExpr(c.arguments[ai]);
                        }
                        return try self.emitOrbitCreate(func_idx, arg_chans_buf[0..arg_count], func);
                    }
                    // 非 async 函数：包装为 async lambda 后 spawn
                    // 简化：直接调用（同步执行）
                    return try self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args);
                }

                // 未知函数：尝试构造器或内置
                return try self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args);
            },
            .lambda => |lam| {
                // 编译 lambda 为 async 闭包，然后 spawn
                const lambda_chan = try self.compileLambda(lam);
                // 对于 spawn，直接返回 lambda 通道
                // 完整实现需要将 lambda 包装为 async task
                return lambda_chan;
            },
            else => {
                // 其他表达式：直接编译（可能只是引用一个已有的 async handle）
                return try self.compileExpr(expr);
            },
        }
    }

    /// 编译 inline_trait_value：trait { methods } → record of closures
    /// 每个方法编译为闭包，存储在 record 字段中
    fn compileInlineTraitValue(self: *IRBuilder, methods: []ast.MethodDecl) BuildError!u16 {
        // 创建一个 record，每个方法作为一个字段
        const field_count = methods.len;
        const len_chan = try self.allocChannel(.i64_chan);
        const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(field_count) } });
        try self.emit(Node.makeSink(.const_i, len_chan, len_meta));

        const record_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.array_make, record_chan, 0, len_chan));

        // 为每个方法创建闭包并存储到 record
        for (methods, 0..) |*method, i| {
            // 编译方法体为 lambda
            const method_chan = blk: {
                if (method.body) |body| {
                    // 有方法体：构造 lambda Expr 并编译
                    const lam_expr = self.allocator.create(ast.Expr) catch return error.OutOfMemory;
                    lam_expr.* = .{ .lambda = .{
                        .params = method.params,
                        .body = .{ .block = body },
                        .is_async = false,
                        .return_type = method.return_type,
                    } };
                    break :blk try self.compileExpr(lam_expr);
                } else {
                    // 无方法体：存储 unit
                    const ch = try self.allocChannel(.unit_chan);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                }
            };

            const idx_chan = try self.allocChannel(.i64_chan);
            const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
            try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
            try self.emit(Node.makeTernary(.array_set, record_chan, 0, record_chan, idx_chan, method_chan));
        }

        return record_chan;
    }

    /// 编译模块引用为 trait 值：Module.Sub → record of closures
    /// 按 trait 方法顺序，为每个方法创建闭包包装对应的模块函数
    fn compileModuleTraitValue(self: *IRBuilder, mod_ref: ModuleRef, trait_name: []const u8) BuildError!u16 {
        const arena_alloc = self.arena.allocator();
        const trait_info = self.trait_table.get(trait_name) orelse return error.UndefinedFunction;
        const method_count = trait_info.methods.len;

        // 创建数组：array_make(count)
        const len_chan = try self.allocChannel(.i64_chan);
        const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(method_count) } });
        try self.emit(Node.makeSink(.const_i, len_chan, len_meta));

        const record_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.array_make, record_chan, 0, len_chan));

        // 为每个 trait 方法创建闭包包装器
        for (trait_info.methods, 0..) |method, i| {
            // 查找模块函数
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}.{s}", .{ mod_ref.module_name, mod_ref.sub_name, method.name });
            const target_func_idx = self.func_table.get(mangled) orelse return error.UndefinedFunction;
            const target_func = self.functions.items[target_func_idx];

            // 创建匿名包装函数
            const wrapper_name = try std.fmt.allocPrint(arena_alloc, "__mod_trait_{d}", .{self.lambda_counter});
            self.lambda_counter += 1;
            const wrapper_idx: u16 = @intCast(self.functions.items.len);
            try self.func_table.put(wrapper_name, wrapper_idx);

            const return_type = chanTypeFromTypeNode(method.return_type) orelse .i64_chan;
            const wrapper_return_chan = try self.allocChannel(return_type);
            try self.functions.append(arena_alloc, .{
                .name = wrapper_name,
                .node_start = 0,
                .node_count = 0,
                .param_channels = &.{},
                .return_channel = wrapper_return_chan,
                .is_entry = false,
                .is_async = false,
            });

            // 编译函数体
            const saved_return_chan = self.current_return_chan;
            const saved_returns_throw = self.current_returns_throw;
            const saved_throw_ok_chan_type = self.current_throw_ok_chan_type;
            const node_start: u32 = @intCast(self.nodes.items.len);
            const chan_start: u16 = self.channels.count();

            try self.pushScope();

            // 分配参数通道（匹配 trait 方法签名）
            var param_chans = try arena_alloc.alloc(u16, method.params.len);
            for (method.params, 0..) |param, j| {
                const chan_type = if (param.type_annotation) |tn|
                    chanTypeFromTypeNode(tn) orelse .i64_chan
                else
                    .i64_chan;
                const chan = try self.allocChannel(chan_type);
                param_chans[j] = chan;
                try self.defineVar(param.name, chan, false);
            }

            self.current_return_chan = wrapper_return_chan;
            self.current_returns_throw = isThrowType(method.return_type);
            if (self.current_returns_throw) {
                self.current_throw_ok_chan_type = throwOkChanType(method.return_type) orelse .i64_chan;
            }

            // 发射 call 节点：调用模块函数
            const target_ret_type = self.channels.get(target_func.return_channel).chan_type;
            const call_out = try self.allocChannel(target_ret_type);
            const call_meta_idx = try self.addCallMeta(.{
                .func_index = target_func_idx,
                .arg_count = @intCast(param_chans.len),
            });
            var call_inputs: [4]u16 = .{ 0, 0, 0, 0 };
            for (param_chans, 0..) |ch, j| {
                if (j < 4) call_inputs[j] = ch;
            }
            try self.emit(Node{
                .op = .call,
                .input_count = @intCast(@min(param_chans.len, 4)),
                .output = call_out,
                .meta_index = call_meta_idx,
                .inputs = call_inputs,
            });

            // 处理 Throw 返回类型
            const final_chan = if (self.current_returns_throw) blk: {
                const wrap_out = try self.allocChannel(.ref_chan);
                const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, call_out));
                break :blk wrap_out;
            } else call_out;

            // 发射 halt_return
            try self.emit(Node.makeUnary(.halt_return, wrapper_return_chan, 0, final_chan));

            self.current_return_chan = saved_return_chan;
            self.current_returns_throw = saved_returns_throw;
            self.current_throw_ok_chan_type = saved_throw_ok_chan_type;
            self.popScope();

            const node_count: u32 = @intCast(self.nodes.items.len - node_start);
            const chan_end: u16 = self.channels.count();
            self.functions.items[wrapper_idx].node_start = node_start;
            self.functions.items[wrapper_idx].node_count = node_count;
            self.functions.items[wrapper_idx].param_channels = param_chans;
            self.functions.items[wrapper_idx].local_chan_start = chan_start;
            self.functions.items[wrapper_idx].local_chan_count = chan_end - chan_start;

            // 发射 closure_make（无上值）
            const closure_meta_idx = try self.addClosureMeta(.{
                .func_index = wrapper_idx,
                .upvalue_count = 0,
                .result_type = return_type,
                .body_start = node_start,
                .body_len = node_count,
                .cell_upvalues = 0,
            });

            const closure_chan = try self.allocChannel(.ref_chan);
            try self.emit(Node{
                .op = .closure_make,
                .input_count = 0,
                .output = closure_chan,
                .meta_index = closure_meta_idx,
                .inputs = .{ 0, 0, 0, 0 },
            });

            // 存入数组：array_set(record, idx, closure)
            const idx_chan = try self.allocChannel(.i64_chan);
            const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
            try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
            try self.emit(Node.makeTernary(.array_set, record_chan, 0, record_chan, idx_chan, closure_chan));
        }

        return record_chan;
    }

    /// 编译 Elvis 操作符 (left ?? right)：left 非 null 取 left，否则取 right
    /// 等价于 nullable_unwrap_or
    fn compileElvis(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr) BuildError!u16 {
        const left_chan = try self.compileExpr(left);
        const right_chan = try self.compileExpr(right);
        const left_meta = self.channels.get(left_chan);

        // null_literal：直接返回 right（值确定为 null）
        if (left_meta.chan_type == .null_chan) {
            return right_chan;
        }

        // 如果 left 不是 nullable/ref，直接返回 left（不可能为 null）
        if (left_meta.chan_type != .nullable_chan and left_meta.chan_type != .ref_chan) {
            return left_chan;
        }

        // 如果是 ref_chan，包装为 nullable
        const nullable_chan = if (left_meta.chan_type == .nullable_chan)
            left_chan
        else blk: {
            const nc = try self.channels.allocNullable(left_meta.chan_type);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, left_chan));
            break :blk nc;
        };

        // nullable_unwrap_or(nullable_chan, right_chan)
        const inner_type = if (left_meta.chan_type == .nullable_chan) left_meta.inner_type else left_meta.chan_type;
        const out = try self.allocChannel(inner_type);
        try self.emit(Node.makeBinary(.nullable_unwrap_or, out, 0, nullable_chan, right_chan));
        return out;
    }

    /// 判断表达式是否直接产生 ThrowValue（无需再包装）
    /// Ok(...) / Error(...) 内建构造器产生 ThrowValue；throw 语句本身是 halt 不返回值
    /// 调用返回 Throw 的函数/lambda 也产生 ThrowValue
    fn exprIsThrowValue(self: *IRBuilder, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .call => |c| switch (c.callee.*) {
                .identifier => |id| blk: {
                    if (std.mem.eql(u8, id.name, "Ok") or std.mem.eql(u8, id.name, "Error")) break :blk true;
                    // 检查是否为返回 Throw 的函数调用
                    if (self.func_generic_info.get(id.name)) |fgi| {
                        if (fgi.return_type) |rt| {
                            if (isThrowType(rt)) break :blk true;
                        }
                    }
                    // 检查是否为返回 Throw 的 lambda 变量调用（跨作用域持久集合）
                    if (self.lambda_returns_throw.contains(id.name)) break :blk true;
                    // 也检查当前作用域中的变量绑定（同作用域内有效）
                    if (self.lookupVar(id.name)) |binding| {
                        if (binding.type_annotation) |ta| {
                            if (isThrowType(ta)) break :blk true;
                        }
                    }
                    break :blk false;
                },
                else => false,
            },
            // 块表达式：检查 trailing_expr 或最后一条语句是否为 throw
            .block => |b| blk: {
                if (b.trailing_expr) |te| {
                    if (self.exprIsThrowValue(te)) break :blk true;
                }
                // 检查最后一条语句是否为 throw_stmt
                if (b.statements.len > 0) {
                    if (b.statements[b.statements.len - 1].* == .throw_stmt) break :blk true;
                }
                break :blk false;
            },
            // if 表达式：任一分支产生 ThrowValue 则整体为 ThrowValue
            .if_expr => |ie| blk: {
                if (self.exprIsThrowValue(ie.then_branch)) break :blk true;
                if (ie.else_branch) |eb| {
                    if (self.exprIsThrowValue(eb)) break :blk true;
                }
                break :blk false;
            },
            // match 表达式：任一 arm 的 body 产生 ThrowValue 则整体为 ThrowValue
            .match => |m| blk: {
                for (m.arms) |arm| {
                    if (self.exprIsThrowValue(arm.body)) break :blk true;
                }
                break :blk false;
            },
            // propagate (? 操作符)：内部表达式为 ThrowValue
            .propagate => |p| self.exprIsThrowValue(p.expr),
            else => false,
        };
    }
};

// ════════════════════════════════════════════════════════════════
// 类型推导辅助函数
// ════════════════════════════════════════════════════════════════

/// 过滤数字字面量中的下划线，返回干净数字字符串
fn filterDigits(raw: []const u8, buf: *[64]u8) []const u8 {
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// 解包无语句 block：若 expr 为 block 且 statements 为空且有 trailing_expr，则返回 trailing_expr；否则返回 expr 本身
fn unwrapBlockExpr(expr: *const ast.Expr) *const ast.Expr {
    if (expr.* == .block) {
        const b = expr.block;
        if (b.statements.len == 0 and b.trailing_expr != null) {
            return b.trailing_expr.?;
        }
    }
    return expr;
}

/// 整数后缀 → IntKind
fn intKindFromSuffix(suffix: ?[]const u8) ?IntKind {
    const s = suffix orelse return null;
    if (std.mem.eql(u8, s, "i8")) return .i8;
    if (std.mem.eql(u8, s, "i16")) return .i16;
    if (std.mem.eql(u8, s, "i32")) return .i32;
    if (std.mem.eql(u8, s, "i64")) return .i64;
    if (std.mem.eql(u8, s, "i128")) return .i128;
    if (std.mem.eql(u8, s, "u8")) return .u8;
    if (std.mem.eql(u8, s, "u16")) return .u16;
    if (std.mem.eql(u8, s, "u32")) return .u32;
    if (std.mem.eql(u8, s, "u64")) return .u64;
    if (std.mem.eql(u8, s, "u128")) return .u128;
    return null;
}

/// 浮点后缀 → FloatKind
fn floatKindFromSuffix(suffix: ?[]const u8) ?FloatKind {
    const s = suffix orelse return null;
    if (std.mem.eql(u8, s, "f16")) return .f16;
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    if (std.mem.eql(u8, s, "f128")) return .f128;
    return null;
}

/// BinaryOp + 操作数类型 → NodeOp
fn binaryOpToNodeOp(op: ast.BinaryOp, operand_type: ChanType) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    const is_ref = operand_type == .ref_chan;
    return switch (op) {
        .add => if (is_int) .int_add else if (is_float) .float_add else if (is_ref) .string_concat else return error.UnsupportedType,
        .sub => if (is_int) .int_sub else if (is_float) .float_sub else return error.UnsupportedType,
        .mul => if (is_int) .int_mul else if (is_float) .float_mul else return error.UnsupportedType,
        .div => if (is_int) .int_div else if (is_float) .float_div else return error.UnsupportedType,
        .mod => if (is_int) .int_mod else if (is_float) .float_mod else return error.UnsupportedType,
        .bit_and => if (is_int) .int_and else return error.UnsupportedType,
        .bit_or => if (is_int) .int_or else return error.UnsupportedType,
        .bit_xor => if (is_int) .int_xor else return error.UnsupportedType,
        .shl => if (is_int) .int_shl else return error.UnsupportedType,
        .shr => if (is_int) .int_shr else return error.UnsupportedType,
        .eq => .cmp_eq,
        .not_eq => .cmp_ne,
        .ref_eq => .builtin_ref_eq,
        .lt => .cmp_lt,
        .gt => .cmp_gt,
        .lt_eq => .cmp_le,
        .gt_eq => .cmp_ge,
        .and_op => .bool_and,
        .or_op => .bool_or,
        .concat_list => if (is_ref) .string_concat else return error.UnsupportedType,
        else => return error.UnsupportedExpr,
    };
}

/// UnaryOp + 操作数类型 → NodeOp
fn unaryOpToNodeOp(op: ast.UnaryOp, operand_type: ChanType) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    return switch (op) {
        .neg => if (is_int) .int_neg else if (is_float) .float_neg else return error.UnsupportedType,
        .bit_not => if (is_int) .int_not else return error.UnsupportedType,
        .not => .bool_not,
    };
}

/// 二元运算结果类型
fn binaryResultType(op: ast.BinaryOp, operand_type: ChanType) ChanType {
    return switch (op) {
        .eq, .not_eq, .ref_eq, .ref_neq, .lt, .gt, .lt_eq, .gt_eq => .mask_chan, // 比较输出 mask
        .and_op, .or_op => .bool_chan,
        .concat_list => .ref_chan, // 字符串/数组拼接返回引用
        else => operand_type, // 算术/位运算继承操作数类型
    };
}

/// 判断类型节点是否为 Throw<T, E>
fn isThrowType(type_node: ?*ast.TypeNode) bool {
    const tn = type_node orelse return false;
    return switch (tn.*) {
        .generic => |g| std.mem.eql(u8, g.name, "Throw"),
        else => false,
    };
}

/// 从 Throw<T, E> 类型节点提取 Ok 值的通道类型
fn throwOkChanType(type_node: ?*ast.TypeNode) ?ChanType {
    const tn = type_node orelse return null;
    switch (tn.*) {
        .generic => |g| {
            if (!std.mem.eql(u8, g.name, "Throw")) return null;
            if (g.args.len < 1) return null;
            return chanTypeFromTypeNode(g.args[0]);
        },
        else => return null,
    }
}

/// 简化版：从 TypeNode 提取类型名（不分配，用于快速查表）
/// 复杂类型（generic/nullable/function/record/array）返回 "?"
fn typeNameFromTypeNodeConst(type_node: *const ast.TypeNode) []const u8 {
    return switch (type_node.*) {
        .named => |n| n.name,
        .self_type => "Self",
        else => "?",
    };
}

/// 判断类型节点是否为字符串类型（str 或 str?）
fn isStringTypeNode(type_node: *const ast.TypeNode) bool {
    return switch (type_node.*) {
        .named => |n| std.mem.eql(u8, n.name, "str"),
        .nullable => |nb| isStringTypeNode(nb.inner),
        else => false,
    };
}

/// 基础类型布局查询
/// 返回 null 表示不是基础类型（交由 layoutOfTypeName 处理用户类型）
/// 返回 meta.LayoutInfo（与 TypeMetadata.layout 同类型）
fn primitiveLayout(name: []const u8) ?LayoutInfo {
    const Entry = struct { n: []const u8, s: u32, a: u32 };
    const table = [_]Entry{
        .{ .n = "bool", .s = 1, .a = 1 },
        .{ .n = "char", .s = 4, .a = 4 },
        .{ .n = "i8", .s = 1, .a = 1 },
        .{ .n = "u8", .s = 1, .a = 1 },
        .{ .n = "i16", .s = 2, .a = 2 },
        .{ .n = "u16", .s = 2, .a = 2 },
        .{ .n = "i32", .s = 4, .a = 4 },
        .{ .n = "u32", .s = 4, .a = 4 },
        .{ .n = "i64", .s = 8, .a = 8 },
        .{ .n = "u64", .s = 8, .a = 8 },
        .{ .n = "i128", .s = 16, .a = 16 },
        .{ .n = "u128", .s = 16, .a = 16 },
        .{ .n = "f16", .s = 2, .a = 2 },
        .{ .n = "f32", .s = 4, .a = 4 },
        .{ .n = "f64", .s = 8, .a = 8 },
        .{ .n = "f128", .s = 16, .a = 16 },
        .{ .n = "str", .s = 16, .a = 8 }, // Str 对象指针 + 长度
        .{ .n = "unit", .s = 0, .a = 1 },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.n, name)) {
            return .{ .size = e.s, .alignment = e.a };
        }
    }
    return null;
}

/// 对齐到指定对齐值
fn alignUp(offset: u32, alignment: u32) u32 {
    if (alignment <= 1) return offset;
    const mask = alignment - 1;
    return (offset + mask) & ~mask;
}

/// 判断类型节点是否为 nullable 类型（T?）
fn isNullableTypeNode(type_node: *const ast.TypeNode) bool {
    return switch (type_node.*) {
        .nullable => true,
        else => false,
    };
}

/// 从 TypeNode 提取类型名字符串（用于 TypeMetadata）
///
/// 分配在 arena_alloc 上，生命周期与 IRBuilder 一致。
/// 处理所有 TypeNode 变体：named、self_type、generic、nullable、function、record、array、kind_annotated。
fn typeNameFromTypeNode(
    type_node: *const ast.TypeNode,
    arena_alloc: std.mem.Allocator,
) ![]const u8 {
    return switch (type_node.*) {
        .named => |n| n.name,
        .self_type => "Self",
        .generic => |g| blk: {
            // 构造 "Name<arg1, arg2, ...>" 形式的字符串
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(arena_alloc);
            try buf.appendSlice(arena_alloc, g.name);
            try buf.append(arena_alloc, '<');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(arena_alloc, ", ");
                const arg_name = try typeNameFromTypeNode(arg, arena_alloc);
                try buf.appendSlice(arena_alloc, arg_name);
            }
            try buf.append(arena_alloc, '>');
            break :blk try buf.toOwnedSlice(arena_alloc);
        },
        .nullable => |nb| blk: {
            const inner_name = try typeNameFromTypeNode(nb.inner, arena_alloc);
            break :blk try std.fmt.allocPrint(arena_alloc, "{s}?", .{inner_name});
        },
        .function => "fn",
        .record => "Record",
        .array => "Array",
        .kind_annotated => |ka| try typeNameFromTypeNode(ka.inner, arena_alloc),
    };
}

/// 从 TypeNode 推导通道类型
/// 原始类型返回精确 ChanType，用户自定义类型（ADT/record/newtype）返回 ref_chan
fn chanTypeFromTypeNode(type_node: ?*ast.TypeNode) ?ChanType {
    const tn = type_node orelse return null;
    return switch (tn.*) {
        .named => |n| {
            if (std.mem.eql(u8, n.name, "i8")) return .i8_chan;
            if (std.mem.eql(u8, n.name, "i16")) return .i16_chan;
            if (std.mem.eql(u8, n.name, "i32")) return .i32_chan;
            if (std.mem.eql(u8, n.name, "i64")) return .i64_chan;
            if (std.mem.eql(u8, n.name, "i128")) return .i128_chan;
            if (std.mem.eql(u8, n.name, "u8")) return .u8_chan;
            if (std.mem.eql(u8, n.name, "u16")) return .u16_chan;
            if (std.mem.eql(u8, n.name, "u32")) return .u32_chan;
            if (std.mem.eql(u8, n.name, "u64")) return .u64_chan;
            if (std.mem.eql(u8, n.name, "u128")) return .u128_chan;
            if (std.mem.eql(u8, n.name, "isize")) return .isize_chan;
            if (std.mem.eql(u8, n.name, "usize")) return .usize_chan;
            if (std.mem.eql(u8, n.name, "f16")) return .f16_chan;
            if (std.mem.eql(u8, n.name, "f32")) return .f32_chan;
            if (std.mem.eql(u8, n.name, "f64")) return .f64_chan;
            if (std.mem.eql(u8, n.name, "f128")) return .f128_chan;
            if (std.mem.eql(u8, n.name, "bool")) return .bool_chan;
            if (std.mem.eql(u8, n.name, "char")) return .char_chan;
            if (std.mem.eql(u8, n.name, "str")) return .ref_chan;
            if (std.mem.eql(u8, n.name, "unit")) return .unit_chan;
            // 用户自定义类型（ADT/record/newtype）→ ref_chan（堆引用）
            return .ref_chan;
        },
        .generic => |g| {
            // 泛型类型如 List<T>、Channel<T> → ref_chan
            if (std.mem.eql(u8, g.name, "Channel")) return .ref_chan;
            // Atomic<T> → 内部类型 T 的 ChanType（atomic 创建 cell 通道，与 T 同类型）
            if (std.mem.eql(u8, g.name, "Atomic")) {
                if (g.args.len > 0) {
                    return chanTypeFromTypeNode(g.args[0]) orelse .i64_chan;
                }
                return .i64_chan;
            }
            return .ref_chan;
        },
        .nullable => |nb| {
            // nullable 类型：返回内部类型的 ChanType，调用方可用于 allocNullable
            return chanTypeFromTypeNode(nb.inner) orelse .ref_chan;
        },
        // 记录类型（含元组）：堆分配的 RecordValue → ref_chan
        .record => .ref_chan,
        // 函数类型：Callable 引用 → ref_chan
        .function => .ref_chan,
        // 数组类型：堆分配的 ArrayValue → ref_chan
        .array => .ref_chan,
        // self_type/kind_annotated：无法静态推断，退化为 ref_chan
        .self_type => .ref_chan,
        .kind_annotated => |ka| chanTypeFromTypeNode(ka.inner) orelse .ref_chan,
    };
}

/// 分配类型节点对应的通道（正确处理 nullable 类型）
/// 返回通道索引
fn allocChanFromTypeNode(channels: *ChannelSpace, type_node: ?*ast.TypeNode) !u16 {
    const tn = type_node orelse return try channels.alloc(.i64_chan);
    return switch (tn.*) {
        .nullable => |nb| {
            const inner_ct = chanTypeFromTypeNode(nb.inner) orelse .ref_chan;
            return try channels.allocNullable(inner_ct);
        },
        else => {
            const ct = chanTypeFromTypeNode(tn) orelse .i64_chan;
            return try channels.alloc(ct);
        },
    };
}

// ════════════════════════════════════════════════════════════════
// AST 遍历辅助：检测 break/continue
// ════════════════════════════════════════════════════════════════

fn astContainsBreakOrContinueExpr(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (astContainsBreakOrContinueStmt(s)) return true;
            }
            if (b.trailing_expr) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .if_expr => |ie| {
            if (astContainsBreakOrContinueExpr(ie.then_branch)) return true;
            if (ie.else_branch) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .binary => |b| {
            return astContainsBreakOrContinueExpr(b.left) or astContainsBreakOrContinueExpr(b.right);
        },
        .unary => |u| return astContainsBreakOrContinueExpr(u.operand),
        .call => |c| {
            if (astContainsBreakOrContinueExpr(c.callee)) return true;
            for (c.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .safe_method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .field_access => |fa| return astContainsBreakOrContinueExpr(fa.object),
        .safe_access => |sa| return astContainsBreakOrContinueExpr(sa.object),
        .index => |idx| return astContainsBreakOrContinueExpr(idx.object) or astContainsBreakOrContinueExpr(idx.index),
        .non_null_assert => |nn| return astContainsBreakOrContinueExpr(nn.expr),
        .propagate => |p| return astContainsBreakOrContinueExpr(p.expr),
        .assignment_expr => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .compound_assign => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .match => |m| {
            if (astContainsBreakOrContinueExpr(m.scrutinee)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (astContainsBreakOrContinueExpr(g)) return true;
                if (astContainsBreakOrContinueExpr(arm.body)) return true;
            }
            return false;
        },
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    if (astContainsBreakOrContinueExpr(r.channel_expr)) return true;
                    if (astContainsBreakOrContinueExpr(r.body)) return true;
                },
                .timeout => |t| {
                    if (astContainsBreakOrContinueExpr(t.duration)) return true;
                    if (astContainsBreakOrContinueExpr(t.body)) return true;
                },
            };
            return false;
        },
        .type_cast => |tc| return astContainsBreakOrContinueExpr(tc.expr),
        .atomic_expr => |ae| return astContainsBreakOrContinueExpr(ae.value),
        .lazy => |l| return astContainsBreakOrContinueExpr(l.expr),
        .spawn_expr => |se| return astContainsBreakOrContinueExpr(se.expr),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (astContainsBreakOrContinueExpr(e)) return true;
            }
            return false;
        },
        .record_literal => |rl| {
            for (rl.fields) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .record_extend => |re| {
            if (astContainsBreakOrContinueExpr(re.base)) return true;
            for (re.updates) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .string_interpolation => |si| {
            for (si.parts) |p| switch (p) {
                .literal => {},
                .expression => |e| if (astContainsBreakOrContinueExpr(e)) return true,
            };
            return false;
        },
        .lambda => return false, // lambda 体不在当前循环上下文中
        .inline_trait_value => return false,
        else => return false,
    }
}

/// 累加器模式提取结果
const AccumulatorPattern = struct {
    acc_name: []const u8,
    fold_op: NodeOp,
    value_expr: *const ast.Expr,
};

/// 从语句中提取累加器模式：acc = acc OP expr 或 acc OP= expr
/// 仅匹配直接赋值和复合赋值，不匹配字段赋值或 if 内的条件赋值
/// 返回 null 表示不是累加器模式
fn extractAccumulatorPattern(stmt: *const ast.Stmt, loop_var: []const u8) ?AccumulatorPattern {
    switch (stmt.*) {
        // 复合赋值：acc += expr, acc -= expr, acc *= expr
        .compound_assignment => |ca| {
            if (ca.target.* != .identifier) return null;
            const name = ca.target.identifier.name;
            if (std.mem.eql(u8, name, loop_var)) return null; // 循环变量自身，不算累加器
            const fold_op: NodeOp = switch (ca.op) {
                .add_assign => .int_add,
                .sub_assign => .int_sub,
                .mul_assign => .int_mul,
                else => return null, // div/mod/等暂不支持
            };
            return .{
                .acc_name = name,
                .fold_op = fold_op,
                .value_expr = ca.value,
            };
        },
        // 直接赋值：acc = acc OP expr 或 acc = expr OP acc
        .assignment => |a| {
            if (a.target.* != .identifier) return null;
            const name = a.target.identifier.name;
            if (std.mem.eql(u8, name, loop_var)) return null;
            if (a.value.* != .binary) return null;
            const bin = a.value.binary;

            // acc = acc OP expr
            if (bin.left.* == .identifier and std.mem.eql(u8, bin.left.identifier.name, name)) {
                const fold_op = binOpToNodeOp(bin.op) orelse return null;
                return .{
                    .acc_name = name,
                    .fold_op = fold_op,
                    .value_expr = bin.right,
                };
            }
            // acc = expr OP acc（仅交换律运算：add/mul/and/or/xor）
            if (bin.right.* == .identifier and std.mem.eql(u8, bin.right.identifier.name, name)) {
                const fold_op = binOpToNodeOp(bin.op) orelse return null;
                // 非交换律（sub/div/mod/shr）不允许左右交换
                switch (fold_op) {
                    .int_sub, .int_div, .int_mod => return null,
                    else => {},
                }
                return .{
                    .acc_name = name,
                    .fold_op = fold_op,
                    .value_expr = bin.left,
                };
            }
            return null;
        },
        else => return null,
    }
}

/// BinaryOp → NodeOp 映射（仅算术和位运算）
fn binOpToNodeOp(op: ast.BinaryOp) ?NodeOp {
    return switch (op) {
        .add => .int_add,
        .sub => .int_sub,
        .mul => .int_mul,
        .div => .int_div,
        .mod => .int_mod,
        .bit_and => .int_and,
        .bit_or => .int_or,
        .bit_xor => .int_xor,
        else => null,
    };
}

fn astContainsBreakOrContinueStmt(stmt: *const ast.Stmt) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return true,
        .expression => |e| return astContainsBreakOrContinueExpr(e.expr),
        .val_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .var_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .assignment => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .field_assignment => |fa| return astContainsBreakOrContinueExpr(fa.object) or astContainsBreakOrContinueExpr(fa.value),
        .compound_assignment => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .return_stmt => |rs| if (rs.value) |v| return astContainsBreakOrContinueExpr(v),
        .defer_stmt => |ds| return astContainsBreakOrContinueExpr(ds.expr),
        .throw_stmt => |ts| return astContainsBreakOrContinueExpr(ts.expr),
        .for_stmt => |fs| return astContainsBreakOrContinueExpr(fs.body) or astContainsBreakOrContinueExpr(fs.iterable),
        .while_stmt => |ws| return astContainsBreakOrContinueExpr(ws.body) or astContainsBreakOrContinueExpr(ws.condition),
        .loop_stmt => |ls| return astContainsBreakOrContinueExpr(ls.body),
    }
    return false;
}

/// break/continue 条件提取结果
const BreakContinueCond = struct {
    is_break: bool,
    cond: *const ast.Expr,
};

/// 从 if 语句中提取 break/continue 条件
/// 支持形式：`if cond { break }` 或 `if cond { continue }`
/// 要求 then 分支只有一个 break/continue 语句，无 else 分支，无 trailing_expr
/// 返回 null 表示不是可提取的 break/continue if 模式
fn tryExtractBreakContinueCond(stmt: *const ast.Stmt) ?BreakContinueCond {
    if (stmt.* != .expression) return null;
    const expr = stmt.expression.expr;
    if (expr.* != .if_expr) return null;
    const ie = expr.if_expr;
    if (ie.else_branch != null) return null;
    // then 分支必须是 block 且只有一个 break/continue 语句
    if (ie.then_branch.* != .block) return null;
    const then_block = ie.then_branch.block;
    if (then_block.statements.len != 1) return null;
    if (then_block.trailing_expr != null) return null;
    const inner = then_block.statements[0];
    const is_break = inner.* == .break_stmt;
    const is_continue = inner.* == .continue_stmt;
    if (!is_break and !is_continue) return null;
    return BreakContinueCond{
        .is_break = is_break,
        .cond = ie.condition,
    };
}

/// 检查表达式中是否包含对 loop_var 之外变量的赋值（跨迭代依赖检测）
/// 用于 while→vec_map 向量化安全检查：body 中不能有对外部变量的赋值
fn astContainsExternalAssignExpr(expr: *const ast.Expr, loop_var: []const u8) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (astContainsExternalAssignStmt(s, loop_var)) return true;
            }
            if (b.trailing_expr) |e| return astContainsExternalAssignExpr(e, loop_var);
            return false;
        },
        .if_expr => |ie| {
            if (astContainsExternalAssignExpr(ie.then_branch, loop_var)) return true;
            if (ie.else_branch) |e| return astContainsExternalAssignExpr(e, loop_var);
            return false;
        },
        .binary => |b| return astContainsExternalAssignExpr(b.left, loop_var) or astContainsExternalAssignExpr(b.right, loop_var),
        .unary => |u| return astContainsExternalAssignExpr(u.operand, loop_var),
        .call => |c| {
            if (astContainsExternalAssignExpr(c.callee, loop_var)) return true;
            for (c.arguments) |a| {
                if (astContainsExternalAssignExpr(a, loop_var)) return true;
            }
            return false;
        },
        .method_call => |mc| {
            if (astContainsExternalAssignExpr(mc.object, loop_var)) return true;
            for (mc.arguments) |a| {
                if (astContainsExternalAssignExpr(a, loop_var)) return true;
            }
            return false;
        },
        .match => |m| {
            if (astContainsExternalAssignExpr(m.scrutinee, loop_var)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (astContainsExternalAssignExpr(g, loop_var)) return true;
                if (astContainsExternalAssignExpr(arm.body, loop_var)) return true;
            }
            return false;
        },
        .assignment_expr => |a| {
            // 赋值表达式本身：检查目标是否是 loop_var 之外的变量
            if (a.target.* == .identifier and !std.mem.eql(u8, a.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(a.value, loop_var);
        },
        .compound_assign => |ca| {
            if (ca.target.* == .identifier and !std.mem.eql(u8, ca.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(ca.value, loop_var);
        },
        else => return false,
    }
}

fn astContainsExternalAssignStmt(stmt: *const ast.Stmt, loop_var: []const u8) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return false,
        .expression => |e| return astContainsExternalAssignExpr(e.expr, loop_var),
        .val_decl => |vd| return astContainsExternalAssignExpr(vd.value, loop_var),
        .var_decl => |vd| return astContainsExternalAssignExpr(vd.value, loop_var),
        .assignment => |a| {
            // 对 loop_var 之外变量的赋值 = 跨迭代依赖
            if (a.target.* == .identifier and !std.mem.eql(u8, a.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(a.value, loop_var);
        },
        .field_assignment => {
            // 字段赋值总是跨迭代依赖（修改外部对象状态）
            return true;
        },
        .compound_assignment => |ca| {
            if (ca.target.* == .identifier and !std.mem.eql(u8, ca.target.identifier.name, loop_var)) return true;
            return astContainsExternalAssignExpr(ca.value, loop_var);
        },
        .return_stmt => |rs| if (rs.value) |v| return astContainsExternalAssignExpr(v, loop_var),
        .defer_stmt => |ds| return astContainsExternalAssignExpr(ds.expr, loop_var),
        .throw_stmt => |ts| return astContainsExternalAssignExpr(ts.expr, loop_var),
        .for_stmt => |fs| return astContainsExternalAssignExpr(fs.body, loop_var) or astContainsExternalAssignExpr(fs.iterable, loop_var),
        .while_stmt => |ws| return astContainsExternalAssignExpr(ws.body, loop_var) or astContainsExternalAssignExpr(ws.condition, loop_var),
        .loop_stmt => |ls| return astContainsExternalAssignExpr(ls.body, loop_var),
    }
    return false;
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "IRBuilder 编译简单算术: 1 + 2" {
    // 构造 AST: fun main() { return 1 + 2 }
    // 使用内联构造测试
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动构造节点验证构建器逻辑
    const ch1 = try builder.allocChannel(.i64_chan);
    const ch2 = try builder.allocChannel(.i64_chan);
    const ch_out = try builder.allocChannel(.i64_chan);

    const meta1 = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 1 } });
    const meta2 = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 2 } });
    const meta_out = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });

    try builder.emit(Node.makeSink(.const_i, ch1, meta1));
    try builder.emit(Node.makeSink(.const_i, ch2, meta2));
    try builder.emit(Node.makeBinary(.int_add, ch_out, meta_out, ch1, ch2));

    try testing.expectEqual(@as(usize, 3), builder.nodes.items.len);
    try testing.expectEqual(NodeOp.const_i, builder.nodes.items[0].op);
    try testing.expectEqual(NodeOp.int_add, builder.nodes.items[2].op);
}

test "intKindFromSuffix 后缀解析" {
    try testing.expectEqual(IntKind.i32, intKindFromSuffix("i32").?);
    try testing.expectEqual(IntKind.u64, intKindFromSuffix("u64").?);
    try testing.expect(intKindFromSuffix(null) == null);
    try testing.expect(intKindFromSuffix("xyz") == null);
}

test "binaryOpToNodeOp 类型分派" {
    try testing.expectEqual(NodeOp.int_add, try binaryOpToNodeOp(.add, .i64_chan));
    try testing.expectEqual(NodeOp.float_add, try binaryOpToNodeOp(.add, .f64_chan));
    try testing.expectEqual(NodeOp.int_and, try binaryOpToNodeOp(.bit_and, .i32_chan));
    try testing.expectEqual(NodeOp.cmp_lt, try binaryOpToNodeOp(.lt, .i64_chan));
    try testing.expectError(error.UnsupportedType, binaryOpToNodeOp(.bit_and, .f64_chan));
}

test "binaryResultType 结果类型推导" {
    try testing.expectEqual(ChanType.mask_chan, binaryResultType(.lt, .i64_chan));
    try testing.expectEqual(ChanType.bool_chan, binaryResultType(.and_op, .bool_chan));
    try testing.expectEqual(ChanType.i64_chan, binaryResultType(.add, .i64_chan));
}

// ════════════════════════════════════════════════════════════════
// 端到端测试：AST → IRBuilder.build() → GlueIR 验证
// ════════════════════════════════════════════════════════════════

/// 测试用 AST 构造器：在 arena 中分配 NodeSlot 包装的 AST 节点
const AstHelper = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) AstHelper {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *AstHelper) void {
        self.arena.deinit();
    }

    fn alloc(self: *AstHelper) std.mem.Allocator {
        return self.arena.allocator();
    }

    const loc: ast.SourceLocation = .{ .line = 1, .column = 1 };

    fn expr(self: *AstHelper, e: ast.Expr) *ast.Expr {
        const slot = self.alloc().create(ast.NodeSlot(ast.Expr)) catch unreachable;
        slot.* = .{ .loc = loc, .node = e };
        return &slot.node;
    }

    fn stmt(self: *AstHelper, s: ast.Stmt) *ast.Stmt {
        const slot = self.alloc().create(ast.NodeSlot(ast.Stmt)) catch unreachable;
        slot.* = .{ .loc = loc, .node = s };
        return &slot.node;
    }

    fn typeNode(self: *AstHelper, t: ast.TypeNode) *ast.TypeNode {
        const slot = self.alloc().create(ast.NodeSlot(ast.TypeNode)) catch unreachable;
        slot.* = .{ .loc = loc, .node = t };
        return &slot.node;
    }

    // 快捷构造：整数字面量
    fn intLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = null } });
    }

    fn intLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：浮点字面量
    fn floatLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = null } });
    }

    fn floatLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：布尔字面量
    fn boolLit(self: *AstHelper, v: bool) *ast.Expr {
        return self.expr(.{ .bool_literal = .{ .value = v } });
    }

    // 快捷构造：标识符引用
    fn ident(self: *AstHelper, name: []const u8) *ast.Expr {
        return self.expr(.{ .identifier = .{ .name = name } });
    }

    // 快捷构造：二元运算
    fn binary(self: *AstHelper, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) *ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    // 快捷构造：一元运算
    fn unary(self: *AstHelper, op: ast.UnaryOp, operand: *ast.Expr) *ast.Expr {
        return self.expr(.{ .unary = .{ .op = op, .operand = operand } });
    }

    // 快捷构造：if 表达式
    fn ifExpr(
        self: *AstHelper,
        cond: *ast.Expr,
        then_b: *ast.Expr,
        else_b: ?*ast.Expr,
    ) *ast.Expr {
        return self.expr(.{ .if_expr = .{
            .condition = cond,
            .then_branch = then_b,
            .else_branch = else_b,
        } });
    }

    // 快捷构造：函数调用
    fn call(self: *AstHelper, func_name: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .call = .{
            .callee = self.ident(func_name),
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：method_call 表达式
    fn methodCall(self: *AstHelper, obj: *ast.Expr, method: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .method_call = .{
            .object = obj,
            .method = method,
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：block 表达式
    fn block(self: *AstHelper, stmts: []const *ast.Stmt, trailing: ?*ast.Expr) *ast.Expr {
        const stmts_slice = self.alloc().alloc(*ast.Stmt, stmts.len) catch unreachable;
        for (stmts, 0..) |s, i| stmts_slice[i] = s;
        return self.expr(.{ .block = .{
            .statements = stmts_slice,
            .trailing_expr = trailing,
        } });
    }

    // 快捷构造：val 声明语句
    fn valDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .val_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：var 声明语句
    fn varDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .var_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：赋值语句
    fn assignment(self: *AstHelper, target_name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .assignment = .{
            .target = self.ident(target_name),
            .value = value,
        } });
    }

    // 快捷构造：return 语句
    fn returnStmt(self: *AstHelper, value: ?*ast.Expr) *ast.Stmt {
        return self.stmt(.{ .return_stmt = .{ .value = value } });
    }

    // 快捷构造：表达式语句
    fn exprStmt(self: *AstHelper, e: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .expression = .{ .expr = e } });
    }

    // 快捷构造：命名类型节点
    fn namedType(self: *AstHelper, name: []const u8) *ast.TypeNode {
        return self.typeNode(.{ .named = .{ .name = name } });
    }

    // 快捷构造：函数参数
    fn param(self: *AstHelper, name: []const u8, type_name: []const u8) ast.Param {
        return .{
            .location = loc,
            .name = name,
            .type_annotation = self.namedType(type_name),
            .is_var = false,
        };
    }

    // 快捷构造：函数声明
    fn funDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
        is_entry: bool,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = false,
            .is_entry = is_entry,
        } };
    }

    /// async 函数声明
    fn asyncFunDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = true,
            .is_entry = false,
        } };
    }

    // 快捷构造：模块
    fn module(self: *AstHelper, name: []const u8, decls: []const ast.Decl) ast.Module {
        const decls_slice = self.alloc().dupe(ast.Decl, decls) catch unreachable;
        return .{ .name = name, .source_path = null, .declarations = decls_slice };
    }
};

// ── 端到端测试用例 ──

test "e2e: 简单算术 fun main() -> i64 { 1 + 2 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：1 个函数、4 个节点（const_i, const_i, int_add, halt_return）
    try testing.expectEqual(@as(usize, 1), ir.functions.len);
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);

    // 节点序列验证
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.int_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // int_add 的输入应连接到两个 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]);
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]);

    // 常量值验证
    try testing.expectEqual(@as(i128, 1), ir.scalar_metas[1].const_val.?.int_val);
    try testing.expectEqual(@as(i128, 2), ir.scalar_metas[2].const_val.?.int_val);

    // 入口函数
    try testing.expectEqual(@as(u16, 0), ir.entry_index);
    try testing.expect(ir.functions[0].is_entry);
    try testing.expectEqualStrings("main", ir.functions[0].name);
}

test "e2e: 变量绑定与使用 fun main() -> i64 { val x = 10; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { val x = 10; x }
    const stmts = [_]*ast.Stmt{
        ah.valDecl("x", ah.intLit("10")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(10), halt_return
    try testing.expectEqual(@as(usize, 2), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[1].op);

    // halt_return 的输入应指向 const_i 的输出（变量 x 绑定到 const_i 通道）
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);

    // 常量值
    try testing.expectEqual(@as(i128, 10), ir.scalar_metas[1].const_val.?.int_val);
}

test "e2e: if 表达式 fun main() -> i64 { if true { 1 } else { 2 } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { if true { 1 } else { 2 } }
    const body = ah.block(&.{}, ah.ifExpr(
        ah.boolLit(true),
        ah.intLit("1"),
        ah.intLit("2"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_bool, cast, const_i(2)[else], const_i(1)[then], route_dispatch, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_bool, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.cast, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op); // else 分支
    try testing.expectEqual(NodeOp.const_i, ir.nodes[3].op); // then 分支
    try testing.expectEqual(NodeOp.route_dispatch, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[5].op);

    // route_dispatch 输入：[winner_chan]
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[4].inputs[0]); // winner
}

test "e2e: 函数定义与调用 add(1, 2)" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST:
    //   fun add(a: i64, b: i64) -> i64 { a + b }
    //   fun main() -> i64 { add(1, 2) }
    const add_body = ah.block(&.{}, ah.binary(.add, ah.ident("a"), ah.ident("b")));
    const add_params = [_]ast.Param{
        ah.param("a", "i64"),
        ah.param("b", "i64"),
    };
    const add_decl = ah.funDecl("add", &add_params, ah.namedType("i64"), add_body, false);

    const main_args = [_]*ast.Expr{ ah.intLit("1"), ah.intLit("2") };
    const main_body = ah.block(&.{}, ah.call("add", &main_args));
    const main_decl = ah.funDecl("main", &.{}, ah.namedType("i64"), main_body, true);

    const decls = [_]ast.Decl{ add_decl, main_decl };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 2 个函数
    try testing.expectEqual(@as(usize, 2), ir.functions.len);
    try testing.expectEqualStrings("add", ir.functions[0].name);
    try testing.expectEqualStrings("main", ir.functions[1].name);
    try testing.expect(ir.functions[1].is_entry);

    // add 函数节点：const_i(1)? 不——参数是 identifier
    // add 节点序列：int_add(a, b), halt_return
    const add_fn_nodes = ir.funcNodes(0);
    try testing.expectEqual(@as(usize, 2), add_fn_nodes.len);
    try testing.expectEqual(NodeOp.int_add, add_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, add_fn_nodes[1].op);

    // main 函数节点：const_i(1), const_i(2), call, halt_return
    const main_fn_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 4), main_fn_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[1].op);
    try testing.expectEqual(NodeOp.call, main_fn_nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, main_fn_nodes[3].op);

    // call 节点输入连接
    try testing.expectEqual(@as(u8, 2), main_fn_nodes[2].input_count);
    try testing.expectEqual(main_fn_nodes[0].output, main_fn_nodes[2].inputs[0]); // arg 1
    try testing.expectEqual(main_fn_nodes[1].output, main_fn_nodes[2].inputs[1]); // arg 2

    // call 元数据
    try testing.expectEqual(@as(u16, 0), ir.call_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.call_metas[0].arg_count);
}

test "e2e: var 声明与赋值 fun main() -> i64 { var x = 1; x = 2; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { var x = 1; x = 2; x }
    const stmts = [_]*ast.Stmt{
        ah.varDecl("x", ah.intLit("1")),
        ah.assignment("x", ah.intLit("2")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(1), load(x_cell), const_i(2), store(x_cell), halt_return
    try testing.expectEqual(@as(usize, 5), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.load, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.store, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[4].op);

    // load 和 store 应指向同一个 cell 通道
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[3].output);

    // var 声明的通道应标记为 cell
    const cell_chan = ir.nodes[1].output;
    try testing.expect(ir.channels.get(cell_chan).is_cell);
}

test "e2e: 类型推导（后缀 + 浮点）" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> f32 { 1.5f32 + 2.5f32 }
    const body = ah.block(&.{}, ah.binary(
        .add,
        ah.floatLitSuf("1.5", "f32"),
        ah.floatLitSuf("2.5", "f32"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("f32"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_f, const_f, float_add, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.float_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // 通道类型应为 f32
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[0].output).chan_type);
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[2].output).chan_type);

    // 元数据中 float_kind 应为 f32
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[1].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[2].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[3].float_kind);
}

test "e2e: 比较运算与 bool 逻辑" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> bool { 1 < 2 }
    const body = ah.block(&.{}, ah.binary(.lt, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("bool"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i, const_i, cmp_lt, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.cmp_lt, ir.nodes[2].op);

    // 比较结果类型应为 mask
    try testing.expectEqual(ChanType.mask_chan, ir.channels.get(ir.nodes[2].output).chan_type);
}

test "e2e: 一元运算 fun main() -> i64 { -5 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { -5 }
    const body = ah.block(&.{}, ah.unary(.neg, ah.intLit("5")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(5), int_neg, halt_return
    try testing.expectEqual(@as(usize, 3), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.int_neg, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[2].op);

    // neg 的输入应连接到 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);
}

test "e2e: IR printer 输出验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 打印 IR
    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证输出包含关键内容
    try testing.expect(std.mem.indexOf(u8, output, "Glue IR") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const_i") != null);
    try testing.expect(std.mem.indexOf(u8, output, "int_add") != null);
    try testing.expect(std.mem.indexOf(u8, output, "halt_return") != null);
    try testing.expect(std.mem.indexOf(u8, output, "main") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[entry]") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试：向量 op
// ════════════════════════════════════════════════════════════════

test "e2e: for 循环 range 向量化 fun main() { for i in 0..10 { i } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(10), vec_source, vec_map, vec_sink, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.vec_sink, ir.nodes[4].op);

    // vec_source 的输入是 start 和 end 通道
    try testing.expectEqual(@as(u8, 2), ir.nodes[2].input_count);
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]); // start
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]); // end

    // vec_map 的输入是 vec_source 的输出
    try testing.expectEqual(ir.nodes[2].output, ir.nodes[3].inputs[0]);

    // vec_sink 的输入是 vec_map 的输出
    try testing.expectEqual(ir.nodes[3].output, ir.nodes[4].inputs[0]);

    // 向量元数据验证（vec_source + vec_map + vec_sink = 3 个）
    try testing.expectEqual(@as(usize, 3), ir.vector_metas.len);

    // vmeta[0]: vec_source (range_source)
    try testing.expectEqual(VecOp.range_source, ir.vector_metas[0].vec_op);
    try testing.expectEqual(@as(?u32, 10), ir.vector_metas[0].length); // 编译期推导长度
    try testing.expectEqual(ChanType.i64_chan, ir.vector_metas[0].elem_type);

    // vmeta[2]: vec_sink (sink_last)
    try testing.expectEqual(VecOp.sink_last, ir.vector_metas[2].vec_op);
}

test "e2e: for 循环 inclusive range 向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..=5 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range_inclusive, ah.intLit("0"), ah.intLit("5")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // range_inclusive 长度 = 5 - 0 + 1 = 6
    try testing.expectEqual(@as(?u32, 6), ir.vector_metas[0].length);
}

test "e2e: for 循环带循环体运算" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..100 { i * 2 }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("100")),
        .body = ah.binary(.mul, ah.ident("i"), ah.intLit("2")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(100), vec_source, const_i(2), int_mul, vec_map, vec_sink, halt_return
    // 循环体子图：const_i(2), int_mul — body_start/body_len 引用这段
    try testing.expectEqual(@as(usize, 8), ir.nodes.len);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.int_mul, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[5].op);

    // vec_map 的 meta 应记录循环体子图范围（vmeta[1] 是 vec_map）
    const map_meta = ir.vector_metas[1];
    try testing.expect(map_meta.body_len > 0); // 循环体非空
    try testing.expectEqual(@as(?u32, 100), ir.vector_metas[0].length);
}

test "e2e: while 循环向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: while true { 1 }
    const while_stmt = ah.stmt(.{ .while_stmt = .{
        .condition = ah.boolLit(true),
        .body = ah.intLit("1"),
    } });
    const body = ah.block(&.{while_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // while 编译为 scalar_loop（while_loop kind）
    const has_scalar_loop = blk: {
        for (ir.nodes) |n| if (n.op == .scalar_loop) break :blk true;
        break :blk false;
    };
    try testing.expect(has_scalar_loop);

    // 验证 scalar_loop 的 loop_meta 为 while_loop kind
    const has_while_loop_meta = blk: {
        for (ir.loop_metas) |lm| if (lm.loop_kind == .while_loop) break :blk true;
        break :blk false;
    };
    try testing.expect(has_while_loop_meta);
}

test "e2e: vec_fold 归约编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // 直接测试 compileFold 方法
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动构造场景：src_vec_chan 和 init_chan
    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const fold_out = try builder.compileFold(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_fold
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_fold, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(fold_out, last_node.output);

    // 验证向量元数据
    const fold_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, fold_meta.inner_op);
    try testing.expectEqual(ChanType.i64_chan, fold_meta.elem_type);
}

test "e2e: vec_scan 前缀计算编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const scan_out = try builder.compileScan(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_scan
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_scan, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(scan_out, last_node.output);

    // 验证向量元数据
    const scan_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, scan_meta.inner_op);
}

test "e2e: for 循环 dispatch 降频验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..1000 { i * 2 + 1 }
    // 传统执行：1000 次 dispatch（mul + add + const）
    // 向量化：3 次 dispatch（vec_source + vec_map + vec_sink）
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("1000")),
        .body = ah.binary(.add, ah.binary(.mul, ah.ident("i"), ah.intLit("2")), ah.intLit("1")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 统计向量 op 数量
    var vec_op_count: usize = 0;
    for (ir.nodes) |n| {
        if (n.op.isVector()) vec_op_count += 1;
    }

    // 向量 op 只有 3 个：vec_source + vec_map + vec_sink
    // 循环体子图（const_i, const_i, int_mul, int_add）是内联的，不算独立 dispatch
    try testing.expectEqual(@as(usize, 3), vec_op_count);

    // 编译期已知长度 1000
    try testing.expectEqual(@as(?u32, 1000), ir.vector_metas[0].length);
}

test "e2e: 向量 meta printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证向量元数据打印输出
    try testing.expect(std.mem.indexOf(u8, output, "向量元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "range_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sink_last") != null);
    try testing.expect(std.mem.indexOf(u8, output, "length=10") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_map") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_sink") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 3 端到端测试：门控/路由/竞争/清理
// ════════════════════════════════════════════════════════════════

test "e2e: ? 传播表达式编译为 gate 节点链" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun f() -> i64 { 0 } fun main() -> i64 { f()? }
    const f_body = ah.block(&.{}, ah.intLit("0"));
    const f_decl = ah.funDecl("f", &.{}, ah.namedType("i64"), f_body, false);
    const body = ah.block(&.{}, ah.expr(.{ .propagate = .{
        .expr = ah.call("f", &.{}),
    } }));
    const decls = [_]ast.Decl{
        f_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：call(f), gate_check, gate_get_ok, const_unit, halt_return
    try testing.expect(ir.nodes.len >= 3);

    // 查找 gate_check 和 gate_get_ok 节点
    var has_gate_check = false;
    var has_gate_get_ok = false;
    for (ir.nodes) |n| {
        if (n.op == .gate_check) has_gate_check = true;
        if (n.op == .gate_get_ok) has_gate_get_ok = true;
    }
    try testing.expect(has_gate_check);
    try testing.expect(has_gate_get_ok);

    // 验证门控元数据
    try testing.expect(ir.gate_metas.len >= 2);
    try testing.expectEqual(GateKind.check, ir.gate_metas[0].gate_kind);
    try testing.expectEqual(GateKind.get_ok, ir.gate_metas[1].gate_kind);
}

test "e2e: defer 语句编译为 cleanup_register" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_body = ah.block(&.{}, ah.intLit("0"));
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), cleanup_body, false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 cleanup_register 节点
    var has_cleanup = false;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) has_cleanup = true;
    }
    try testing.expect(has_cleanup);

    // 验证清理元数据
    try testing.expect(ir.cleanup_metas.len >= 1);
    const cm = ir.cleanup_metas[0];
    try testing.expectEqual(HaltKind.any_halt, cm.trigger);
    try testing.expect(cm.body_len > 0); // defer 体非空
    try testing.expectEqual(@as(u32, 0), cm.order); // 第一个 defer
}

test "e2e: 多个 defer LIFO 顺序" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun a() -> i64 { 0 } fun b() -> i64 { 0 } fun main() -> i64 { defer a(); defer b(); return 0 }
    const a_decl = ah.funDecl("a", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const b_decl = ah.funDecl("b", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_a = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("a", &.{}),
    } });
    const defer_b = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("b", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("0"));
    const body = ah.block(&.{ defer_a, defer_b, return_stmt }, null);
    const decls = [_]ast.Decl{
        a_decl,
        b_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 两个 cleanup_register 节点
    var cleanup_count: usize = 0;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) cleanup_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), cleanup_count);

    // 验证 LIFO 顺序：order 递增
    try testing.expectEqual(@as(u32, 0), ir.cleanup_metas[0].order);
    try testing.expectEqual(@as(u32, 1), ir.cleanup_metas[1].order);
}

test "e2e: throw 语句编译为 halt_throw" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { throw 42 }
    // 简化：throw 一个整数字面量
    const throw_stmt = ah.stmt(.{ .throw_stmt = .{
        .location = .{ .line = 1, .column = 1 },
        .expr = ah.intLit("42"),
    } });
    const body = ah.block(&.{throw_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 halt_throw 节点
    var has_throw = false;
    for (ir.nodes) |n| {
        if (n.op == .halt_throw) has_throw = true;
    }
    try testing.expect(has_throw);

    // 验证门控元数据（make_err）
    try testing.expect(ir.gate_metas.len >= 1);
    var has_make_err = false;
    for (ir.gate_metas) |gm| {
        if (gm.gate_kind == .make_err) has_make_err = true;
    }
    try testing.expect(has_make_err);
}

test "e2e: select 多路复用编译为竞争图" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: select { ch1.recv() => v => 0; ch2.recv() => v => 1 }
    // 简化：使用整数通道，body 返回整数
    const arm1 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("1"), // 简化：用整数代替通道
        .binding = "v",
        .body = ah.intLit("0"),
    } };
    const arm2 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("2"),
        .binding = "v",
        .body = ah.intLit("1"),
    } };

    const arms = ah.alloc().alloc(ast.SelectArm, 2) catch unreachable;
    arms[0] = arm1;
    arms[1] = arm2;

    const body = ah.block(&.{}, ah.expr(.{ .select = .{ .arms = arms } }));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找竞争节点
    var race_source_count: usize = 0;
    var has_race_select = false;
    var has_route_dispatch = false;
    for (ir.nodes) |n| {
        if (n.op == .race_source) race_source_count += 1;
        if (n.op == .race_select) has_race_select = true;
        if (n.op == .route_dispatch) has_route_dispatch = true;
    }

    // 2 个 race_source（每个分支一个）
    try testing.expectEqual(@as(usize, 2), race_source_count);
    try testing.expect(has_race_select);
    try testing.expect(has_route_dispatch);

    // 验证竞争元数据
    try testing.expect(ir.race_metas.len >= 3); // 2 个 race_source + 1 个 race_select

    // 验证路由元数据
    try testing.expect(ir.route_metas.len >= 1);
    try testing.expectEqual(@as(u8, 2), ir.route_metas[0].target_count);
}

test "e2e: Phase 3 元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证 Phase 3 元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "清理元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cleanup_register") != null);
    try testing.expect(std.mem.indexOf(u8, output, "any_halt") != null);
}

// ── Phase 5 星轨扩展端到端测试 ──

test "e2e: async 函数调用编译为 orbit_async_create" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：compute 函数标记为 async
    try testing.expect(ir.functions[0].is_async);
    try testing.expect(!ir.functions[1].is_async);

    // 验证：main 函数中应发射 orbit_async_create + orbit_async_join
    // 节点序列：orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 3), main_nodes.len);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, main_nodes[2].op);

    // 验证：orbit_async_create 的输出是 ref_chan（handle）
    try testing.expectEqual(ChanType.ref_chan, ir.channels.get(main_nodes[0].output).chan_type);

    // 验证：orbit_metas 表有 1 条记录
    try testing.expectEqual(@as(usize, 1), ir.orbit_metas.len);
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 0), ir.orbit_metas[0].arg_count);
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: orbit_async_join 等待异步结果" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 的 meta_index 指向 orbit_metas[0]
    const create_node = ir.funcNodes(1)[0];
    try testing.expectEqual(NodeOp.orbit_async_create, create_node.op);
    try testing.expectEqual(@as(u16, 1), create_node.meta_index);

    // 验证：orbit_metas 记录了结果类型，join 时用此类型分配结果通道
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: async 函数带参数" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun add(x: i64, y: i64) -> i64 { x + y } fun main() -> i64 { add(1, 2).await() }
    const x_param = ah.param("x", "i64");
    const y_param = ah.param("y", "i64");
    const add_decl = ah.asyncFunDecl("add", &.{ x_param, y_param }, ah.namedType("i64"),
        ah.block(&.{}, ah.binary(.add, ah.ident("x"), ah.ident("y"))));
    const body = ah.block(&.{}, ah.methodCall(ah.call("add", &.{ ah.intLit("1"), ah.intLit("2") }), "await", &.{}));
    const decls = [_]ast.Decl{
        add_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 有 2 个输入（参数通道）
    // 节点序列：const_i(1), const_i(2), orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 5), main_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_nodes[1].op);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[2].op);
    try testing.expectEqual(@as(u8, 2), main_nodes[2].input_count);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[3].op);

    // 验证：orbit_metas 记录了正确的函数索引和参数数量
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.orbit_metas[0].arg_count);
}

test "e2e: orbit_chan_send/recv 通道通信" {
    // 直接用 builder 发射 orbit 通信节点（不经过 AST build）
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动发射 orbit_chan_send 和 orbit_chan_recv
    const handle_chan: u16 = 0;
    const val_chan: u16 = 1;
    _ = try builder.emitOrbitSend(handle_chan, val_chan);
    _ = try builder.emitOrbitRecv(handle_chan, .i64_chan);
    _ = try builder.emitOrbitTryRecv(handle_chan, .i64_chan);

    // 验证节点已追加到 builder.nodes
    try testing.expectEqual(@as(usize, 3), builder.nodes.items.len);
    try testing.expectEqual(NodeOp.orbit_chan_send, builder.nodes.items[0].op);
    try testing.expectEqual(NodeOp.orbit_chan_recv, builder.nodes.items[1].op);
    try testing.expectEqual(NodeOp.orbit_chan_try_recv, builder.nodes.items[2].op);

    // 验证 send 节点是二元（handle + value）
    try testing.expectEqual(@as(u8, 2), builder.nodes.items[0].input_count);
    // 验证 recv 节点是一元（handle）
    try testing.expectEqual(@as(u8, 1), builder.nodes.items[1].input_count);
}

test "e2e: 星轨元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.call("compute", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证星轨元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "星轨元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "orbit_async_create") != null);
    try testing.expect(std.mem.indexOf(u8, output, "func=0") != null);
}

test "e2e: 优化器不消除 orbit 副作用节点" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = @import("optimizer.zig").optimize(&ir);

    // orbit_async_create 有副作用，不应被 deadNodeElim 消除
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
}
