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
const syscall = @import("syscall");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const type_descriptor_mod = @import("type_descriptor.zig");
const builtin_registry = @import("builtin_registry.zig");
const builtin_type_names = @import("builtin_type_names.zig");
const ir_mod = @import("ir.zig");
const sema_output_mod = @import("sema").sema_output;
const analysis_db_mod = @import("analysis_db");
const sema = @import("sema");

/// sema 产出的表达式类型映射契约（驱动式接入：sema 填充、builder 消费）
const SemaResult = sema_output_mod.SemaResult;
const TypeDefInfo = sema_output_mod.TypeDefInfo;
const CtorDefInfo = sema_output_mod.CtorDefInfo;
const TypeDefKind = sema_output_mod.TypeDefKind;
const TraitDefInfo = sema_output_mod.TraitDefInfo;
const TraitMethodSig = sema_output_mod.TraitMethodSig;

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
pub const CoroutineMeta = meta_mod.CoroutineMeta;
pub const LoopMeta = meta_mod.LoopMeta;
pub const ClosureMeta = meta_mod.ClosureMeta;
pub const PartialMeta = meta_mod.PartialMeta;
pub const LoopKind = meta_mod.LoopKind;
pub const SyscallId = syscall.SyscallId;
pub const SyscallMeta = meta_mod.SyscallMeta;
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
pub const ChannelSpace = channel_mod.ChannelSpace;
pub const GlueIR = ir_mod.GlueIR;
pub const IntKind = scalar.IntKind;
pub const FloatKind = scalar.FloatKind;

/// 图构建错误（v3 阶段 4：定义已物理拆分到 ast_traits.zig）
pub const BuildError = @import("ast_traits.zig").BuildError;

/// 变量绑定
pub const VarBinding = struct {
    name: []const u8,
    chan: u16, // 通道索引
    is_cell: bool, // var 变量是 Cell（可变）
    ast_expr: ?*const ast.Expr = null, // 用于类型推断的 AST 表达式
    type_annotation: ?*ast.TypeNode = null, // 类型标注（函数参数/val/var 声明）
    is_atomic: bool = false, // Atomic<T> 变量：chan 存储 AtomicValue 指针
};

/// 作用域
pub const Scope = struct {
    bindings: std.ArrayList(VarBinding),
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
pub const LinearRecurrenceInfo = struct {
    op: NodeOp, // 递归运算（int_add / int_mul / int_and / int_or / int_xor）
    init_a: i64, // 状态 a 初值（= f(0)）
    init_b: i64, // 状态 b 初值（= f(1)）
    elem_type: *const type_descriptor_mod.TypeDescriptor, // 运算元素类型
};

// TypeBinding/BoundType 已删除：sema 侧 inference.zig 的 TypeBindingContext 是唯一权威来源
// IR 侧不再维护独立类型绑定栈，current_type_args 直接引用 sema instance.type_args

/// 延迟实例化请求：泛型函数调用时不内联编译，而是排队延迟处理
const DeferredInstantiation = struct {
    func_name: []const u8,
    instance_id: u32,
    func_idx: u16,
};

/// IR 构建器：从 AST 构建 GlueIR
pub const IRBuilder = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    nodes: std.ArrayList(Node),
    /// 节点源码位置表：与 nodes 平行，emit 时同步追加
    node_locs: std.ArrayList(ast.SourceLocation) = .empty,
    /// 当前编译位置（由 compileExpr/compileStmt 入口设置）
    current_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
    scalar_metas: std.ArrayList(ScalarMeta),
    call_metas: std.ArrayList(CallMeta),
    vector_metas: std.ArrayList(VectorMeta),
    gate_metas: std.ArrayList(GateMeta),
    route_metas: std.ArrayList(RouteMeta),
    race_metas: std.ArrayList(RaceMeta),
    cleanup_metas: std.ArrayList(CleanupMeta),
    orbit_metas: std.ArrayList(OrbitMeta),
    /// 协程元数据表（async 函数状态机变换产物，Phase 6）
    coroutine_metas: std.ArrayList(CoroutineMeta) = .empty,
    loop_metas: std.ArrayList(LoopMeta),
    closure_metas: std.ArrayList(ClosureMeta),
    /// 部分应用元数据表（partial_make 节点引用，1-indexed）
    partial_metas: std.ArrayList(PartialMeta),
    /// Syscall 元数据表（syscall_call 节点引用，1-indexed）
    syscall_metas: std.ArrayList(SyscallMeta),
    functions: std.ArrayList(Function),
    string_pool: std.ArrayList([]const u8),
    channels: ChannelSpace,

    scope_stack: std.ArrayList(Scope),
    func_table: SymTable(u16), // 函数名 -> 函数索引
    func_returns_str: std.StringHashMap(void), // 返回 str 的函数名集合
    lambda_returns_throw: std.StringHashMap(void), // 返回 Throw 的 lambda 变量名集合（跨作用域持久）
    imported_modules: std.StringHashMap(void), // 已导入的顶层模块名集合（用于模块引用识别）
    /// 模块短名 → 完整模块路径（从 SemaResult.import_aliases 的 .module 变体提取）
    module_alias_map: std.StringHashMap([]const u8),
    /// 函数/常量短名 → mangled 名（从 SemaResult.import_aliases 的 .symbol 变体提取）
    symbol_alias_map: std.StringHashMap([]const u8),
    /// 字段名 → field_id 映射：key = "type_name\x00field_name"，value = field_id
    /// ADT/newtype/error_newtype：__tag=0，字段从 1 开始
    /// Record literal：字段按声明顺序 0..N-1
    field_id_map: std.StringHashMap(u16),
    /// 线性递归识别：函数名 → LinearRecurrenceInfo
    linear_rec_map: std.StringHashMap(LinearRecurrenceInfo),
    /// async handle 通道 → orbit_meta_idx 映射
    /// emitOrbitCreate 时记录，await 时查询以获取 result_type
    async_handle_meta: std.AutoHashMap(u16, u16),

    current_return_chan: ?u16 = null,
    /// 当前编译的表达式是否在尾位置（用于标记 tail_call）
    in_tail_position: bool = false,
    /// 当前函数返回类型是否为 Throw<T, E>（决定是否需要包装返回值为 ThrowValue）
    current_returns_throw: bool = false,
    /// 当前函数 Throw<T, E> 返回类型的 Ok 值类型描述符（用于 ? 传播提取 Ok 值）
    current_throw_ok_type_desc: *const type_descriptor_mod.TypeDescriptor = type_descriptor_mod.i64_descriptor,
    /// 当前编译的方法所属类型名（用于 self 的类型推断）
    current_type_context: ?[]const u8 = null,
    /// GADT 类型绑定栈：match arm 内的类型参数绑定（如 T → i32_descriptor）
    /// 每个 match arm 压入一个绑定表，arm 结束后弹出
    gadt_binding_stack: std.ArrayList(std.StringHashMap(*const type_descriptor_mod.TypeDescriptor)) = .empty,
    /// 当前函数名（用于判断递归调用）
    current_func_name: ?[]const u8 = null,
    /// 调试用：记录最后编译的函数/val名（不恢复，用于错误定位）
    debug_error_func_name: ?[]const u8 = null,
    /// 调试用：记录最后编译的表达式种类（不恢复，用于错误定位）
    debug_last_expr_tag: []const u8 = "",
    /// 当前函数的参数类型注解（用于 GADT 类型推断）
    current_func_param_types: ?[]const ast.Param = null,
    /// 当前函数的类型参数（用于 typeof(T) 哨兵发射）
    current_func_type_params: ?[]const ast.TypeParam = null,
    /// 当前 trait default 方法中的 Self 类型名（用于 typeof(Self) 解析）
    current_self_type_name: ?[]const u8 = null,
    /// 当前正在编译的 sema 单态化实例 ID（null = 顶层非泛型函数）
    /// 存储 instance_id 而非指针，因为 monomorph_instances ArrayList 可能在递归
    /// 编译过程中扩容并移动，指针会悬垂。通过 ID 每次从 items 查询始终有效。
    current_instance_id: ?u32 = null,
    /// 当前实例的类型实参（空切片 = 非泛型上下文）
    /// 直接引用避免重复解引用；chanTypeFromTypeNodeBound 委托 sema type_resolver 时传入
    current_type_args: []const type_descriptor_mod.TypeDescriptor = &.{},
    /// sema MonomorphInstance.instance_id → IR func_table 索引
    /// 替代原 monomorph_cache，复用 sema 的实例缓存
    instance_func_map: std.AutoHashMap(u32, u16),
    /// 正在编译的实例（递归循环检测，替代原 monomorph_in_progress）
    /// key = sema instance_id，value = 预占的 func_idx
    /// 同时用于标记"已排队等待延迟编译"的实例，避免同一实例被重复排队
    instances_in_progress: std.AutoHashMap(u32, u16),
    /// 延迟实例化队列：instantiateFunction 不再内联编译函数体，
    /// 而是将实例化请求排队，在所有顶层函数编译完成后统一处理。
    /// 这避免了被实例化函数的体节点与调用者函数的体节点交错，
    /// 导致调用者 node_range 错误包含被实例化函数的节点。
    deferred_instantiations: std.ArrayList(DeferredInstantiation) = .empty,
    /// 当前模式绑定的类型提示（从构造器字段类型继承）
    pattern_type_hint: ?*ast.TypeNode = null,
    /// 当前 match 的 scrutinee AST 表达式（用于 variable pattern 绑定时推断类型名）
    current_match_scrutinee: ?*const ast.Expr = null,
    /// lambda 计数器（生成匿名函数名 __lambda_N）
    lambda_counter: u32 = 0,
    /// 预声明 lambda 名栈（支持递归 lambda：val go = fun(...) { go(...) }）
    /// 在 val_decl 编译 lambda 前 push 名字，compileLambda 读取并预绑定到输出通道
    pre_declared_lambda_names: std.ArrayList([]const u8) = .empty,
    /// arena 所有权标志：build() 成功后转交给 GlueIR，置为 false
    arena_owned: bool = true,
    /// sema 输出契约（必需）：inferChanTypeFromExpr 从此处查询表达式类型。
    /// 所有权归调用方，build 期间不得释放。
    /// 可变指针：builder 在 registerBuiltinErrorTypes 中向其注册 builtin 类型定义。
    /// 必须在 build() 之前通过 setSemaResult 注入。
    sema_result: *SemaResult = undefined,
    /// 纯度表（驱动式接入）：若非 null，compileCall 查询函数纯度决定是否分配 memo_slot。
    /// 所有权归调用方，build 期间不得释放。
    purity_db: ?*const analysis_db_mod.PurityTable = null,
    /// 逃逸分析表（驱动式注入），用于设置 Function.no_escape
    escape_table: ?*const analysis_db_mod.EscapeTable = null,
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
    /// 当前编译的模块（build() 入口设置），用于 GADT return_type / field type_node 的 AST 访问
    current_module: ?ast.Module = null,

    // v3 阶段 4：pattern/match 编译方法从 pattern_compiler.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    pub const pushGadtBindingsForArm = @import("pattern_compiler.zig").Methods.pushGadtBindingsForArm;
    pub const popGadtBindings = @import("pattern_compiler.zig").Methods.popGadtBindings;
    pub const compileMatch = @import("pattern_compiler.zig").Methods.compileMatch;
    pub const patternAlwaysMatches = @import("pattern_compiler.zig").Methods.patternAlwaysMatches;
    pub const tryCompileJumpTableMatch = @import("pattern_compiler.zig").Methods.tryCompileJumpTableMatch;
    pub const compileMatchArms = @import("pattern_compiler.zig").Methods.compileMatchArms;
    pub const compilePatternCheck = @import("pattern_compiler.zig").Methods.compilePatternCheck;
    pub const emitConstBool = @import("pattern_compiler.zig").Methods.emitConstBool;
    pub const compileLiteralPattern = @import("pattern_compiler.zig").Methods.compileLiteralPattern;
    pub const emitCmpEq = @import("pattern_compiler.zig").Methods.emitCmpEq;
    pub const compileConstructorPattern = @import("pattern_compiler.zig").Methods.compileConstructorPattern;
    pub const compileRecordPattern = @import("pattern_compiler.zig").Methods.compileRecordPattern;

    // v3 阶段 4：类型/元数据注册与查询方法从 decl_collector.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    // Group 1: 反射辅助类型 field_id 注册
    pub const registerTypeInfoFields = @import("decl_collector.zig").Methods.registerTypeInfoFields;
    pub const registerLayoutInfoFields = @import("decl_collector.zig").Methods.registerLayoutInfoFields;
    pub const registerTraitImplInfoFields = @import("decl_collector.zig").Methods.registerTraitImplInfoFields;
    pub const registerFieldMetaFields = @import("decl_collector.zig").Methods.registerFieldMetaFields;
    pub const registerConstructorMetaFields = @import("decl_collector.zig").Methods.registerConstructorMetaFields;
    pub const registerTypeParamMetaFields = @import("decl_collector.zig").Methods.registerTypeParamMetaFields;
    pub const registerMethodMetaFields = @import("decl_collector.zig").Methods.registerMethodMetaFields;
    pub const registerFuncSigMetaFields = @import("decl_collector.zig").Methods.registerFuncSigMetaFields;
    pub const registerTraitMetaFields = @import("decl_collector.zig").Methods.registerTraitMetaFields;
    pub const registerAssociatedTypeMetaFields = @import("decl_collector.zig").Methods.registerAssociatedTypeMetaFields;
    // Group 2: Tarjan SCC
    pub const tarjanSCCVisit = @import("decl_collector.zig").Methods.tarjanSCCVisit;
    // Group 3: 类型/ctor 注册与查询
    pub const registerTypeDecl = @import("decl_collector.zig").Methods.registerTypeDecl;
    pub const registerBuiltinTypeMetadata = @import("decl_collector.zig").Methods.registerBuiltinTypeMetadata;
    /// 从 AST 模块填充 sema_result 的类型/函数/Trait 定义表
    /// v3 阶段 3：委托到 sema.populate.populateSemaResultFromAst
    pub fn populateSemaResultFromAst(self: *IRBuilder, module: ast.Module) !void {
        const sr = self.sema_result;
        try sema.populate.populateSemaResultFromAst(sr, module, self.arena.allocator());
    }
    pub const chanTypeFromTypeName = @import("decl_collector.zig").Methods.chanTypeFromTypeName;
    pub const getCtorAstReturnType = @import("decl_collector.zig").Methods.getCtorAstReturnType;
    pub const getCtorAstFieldTypeNode = @import("decl_collector.zig").Methods.getCtorAstFieldTypeNode;
    pub const findTraitMethodsAst = @import("decl_collector.zig").Methods.findTraitMethodsAst;
    pub const findFuncParamsAst = @import("decl_collector.zig").Methods.findFuncParamsAst;
    /// 查找函数/方法的返回类型 TypeNode（委托 sema/inference，消除 IR 侧重复实现）
    pub fn findFuncReturnTypeAst(self: *IRBuilder, name: []const u8) ?*ast.TypeNode {
        const mod = self.current_module orelse return null;
        return sema.inference.findFuncReturnTypeAst(&mod, name);
    }
    pub const findFunDeclAst = @import("decl_collector.zig").Methods.findFunDeclAst;
    pub const getCtorTag = @import("decl_collector.zig").Methods.getCtorTag;
    pub const collectTypeMetadata = @import("decl_collector.zig").Methods.collectTypeMetadata;
    pub const resolveTypeMetadataRefs = @import("decl_collector.zig").Methods.resolveTypeMetadataRefs;
    pub const computeTypeLayout = @import("decl_collector.zig").Methods.computeTypeLayout;
    pub const computeLayoutForEntry = @import("decl_collector.zig").Methods.computeLayoutForEntry;
    pub const layoutOfTypeName = @import("decl_collector.zig").Methods.layoutOfTypeName;
    pub const lookupTypeId = @import("decl_collector.zig").Methods.lookupTypeId;

    // v3 阶段 4：语句编译方法从 stmt_compiler.zig 混入
    //（Zig 0.16 已移除 usingnamespace，改用 pub const 别名注入方法命名空间）
    pub const compileBlock = @import("stmt_compiler.zig").Methods.compileBlock;
    pub const compileStmt = @import("stmt_compiler.zig").Methods.compileStmt;
    pub const compileFor = @import("stmt_compiler.zig").Methods.compileFor;
    pub const tryCompileForDataflow = @import("stmt_compiler.zig").Methods.tryCompileForDataflow;
    pub const emitTakeWhileNegCond = @import("stmt_compiler.zig").Methods.emitTakeWhileNegCond;
    pub const emitFilterNegCond = @import("stmt_compiler.zig").Methods.emitFilterNegCond;
    pub const isPureCondition = @import("stmt_compiler.zig").Methods.isPureCondition;
    pub const compileWhile = @import("stmt_compiler.zig").Methods.compileWhile;
    pub const tryCompileWhileChunked = @import("stmt_compiler.zig").Methods.tryCompileWhileChunked;
    pub const tryCompileWhileAsVecMap = @import("stmt_compiler.zig").Methods.tryCompileWhileAsVecMap;
    pub const compileLoop = @import("stmt_compiler.zig").Methods.compileLoop;
    pub const compileForScalar = @import("stmt_compiler.zig").Methods.compileForScalar;
    pub const compileWhileScalar = @import("stmt_compiler.zig").Methods.compileWhileScalar;
    pub const compileDefer = @import("stmt_compiler.zig").Methods.compileDefer;
    pub const compileThrow = @import("stmt_compiler.zig").Methods.compileThrow;
    pub const compileSelect = @import("stmt_compiler.zig").Methods.compileSelect;

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
            .partial_metas = .empty,
            .syscall_metas = .empty,
            .functions = .empty,
            .string_pool = .empty,
            .channels = ChannelSpace.init(arena.allocator()),
            .scope_stack = .empty,
            .func_table = SymTable(u16).init(allocator),
            .func_returns_str = std.StringHashMap(void).init(allocator),
            .lambda_returns_throw = std.StringHashMap(void).init(allocator),
            .imported_modules = std.StringHashMap(void).init(allocator),
            .module_alias_map = std.StringHashMap([]const u8).init(allocator),
            .symbol_alias_map = std.StringHashMap([]const u8).init(allocator),
            .field_id_map = std.StringHashMap(u16).init(allocator),
            .linear_rec_map = std.StringHashMap(LinearRecurrenceInfo).init(allocator),
            .async_handle_meta = std.AutoHashMap(u16, u16).init(allocator),
            .instance_func_map = std.AutoHashMap(u32, u16).init(allocator),
            .instances_in_progress = std.AutoHashMap(u32, u16).init(allocator),
        };
        // meta_index=0 保留为"无元数据"占位
        try builder.scalar_metas.append(arena.allocator(), .{ .kind = .unit });
        // syscall_metas meta_index=0 同样保留为占位（syscall_id=0 对应 REGISTRY[0]，
        // 但 meta_index=0 是哨兵，Engine 不会访问此条目）
        try builder.syscall_metas.append(arena.allocator(), .{
            .syscall_id = 0,
            .arg_count = 0,
        });
        // 注册 TypeInfo 反射类型的 field_id（0-indexed，无 __tag）
        try builder.registerTypeInfoFields();
        return builder;
    }

    /// 注入 sema 输出契约（必需）。必须在 build() 之前调用。
    /// 设置后，inferChanTypeFromExpr 从 SemaResult.expr_types 查询表达式类型。
    pub fn setSemaResult(self: *IRBuilder, sr: *SemaResult) void {
        self.sema_result = sr;
        self.channels.pool = &sr.type_desc_pool;
    }

    /// 注入纯度表（驱动式接入）。必须在 build() 之前调用。
    /// 设置后，compileCall 会查询函数纯度，对纯函数 + 标量参数分配 memo_slot。
    pub fn setPurityDB(self: *IRBuilder, db: ?*const analysis_db_mod.PurityTable) void {
        self.purity_db = db;
    }

    /// 注入逃逸分析表（驱动式接入）。必须在 build() 之前调用。
    /// 设置后，compileFunction 会查询函数逃逸性，设置 Function.no_escape 字段。
    pub fn setEscapeTable(self: *IRBuilder, et: ?*const analysis_db_mod.EscapeTable) void {
        self.escape_table = et;
    }

    /// 释放构建器资源（不释放产出的 IR，IR 由 GlueIR.deinit 管理）
    /// 注意：build() 成功后 arena 所有权转交给 GlueIR，此函数不再释放 arena
    pub fn deinit(self: *IRBuilder) void {
        self.scope_stack.deinit(self.allocator);
        self.func_table.deinit();
        self.func_returns_str.deinit();
        self.lambda_returns_throw.deinit();
        self.imported_modules.deinit();
        self.module_alias_map.deinit();
        self.symbol_alias_map.deinit();
        self.field_id_map.deinit();
        self.linear_rec_map.deinit();
        self.async_handle_meta.deinit();
        self.func_memo_slots.deinit(self.allocator);
        for (self.gadt_binding_stack.items) |*m| m.deinit();
        self.gadt_binding_stack.deinit(self.allocator);
        self.pre_declared_lambda_names.deinit(self.allocator);
        // current_instance_id/current_type_args 不拥有资源（指向 sema_result），无需 deinit
        self.instance_func_map.deinit();
        self.instances_in_progress.deinit();
        self.deferred_instantiations.deinit(self.allocator);
        if (self.arena_owned) {
            // type_metadata_entries/type_name_to_id/pending_alias_targets 用 arena 分配
            // 由 arena.deinit() 统一释放，无需单独 deinit
            self.arena.deinit();
            self.allocator.destroy(self.arena);
            self.arena_owned = false;
        }
    }

    /// 构建完整 IR：遍历模块声明，编译所有函数
    /// 前置条件：必须先通过 setSemaResult 注入 SemaResult
    pub fn build(self: *IRBuilder, module: ast.Module) BuildError!GlueIR {
        const arena_alloc = self.arena.allocator();
        self.current_module = module;

        // 全局作用域（scope_stack[0]）：顶层 val/var 在此注册，所有函数可见
        try self.pushScope();

        // 反射：注册内建类型（i32/str/bool/char/f64 等）到 TypeMetadataTable
        // 使 typeof(i32) 等返回 Primitive kind + 正确 name/layout，而非占位 "?"
        try self.registerBuiltinTypeMetadata(arena_alloc);

        // 第一遍：注册所有函数名 + 预分配 Function 占位条目
        // 同时注册 type_decl（类型+构造器）和 trait_decl
        // 占位条目包含 is_async/return_type 信息，供 compileCall 在被调用函数尚未编译时查询
        // builtin error 类型（Err/Error/CastError/IOError/TimeError 等）由 module_loader
        // 从 @embedFile 嵌入的 .glue 文件解析为 AST，走通用 registerTypeDecl 路径注册
        var func_count: u16 = @intCast(self.functions.items.len);
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
                    // 预分配占位 Function：返回通道暂为 0，编译时更新
                    // 预分配 param_channels：参数通道类型从 AST 类型注解推导，
                    // 使函数 A 调用尚未编译的函数 B 时可正确访问 B.param_channels
                    const placeholder_return_chan = try allocChanFromTypeNode(&self.channels, fd.return_type, self.sema_result);
                    const placeholder_param_channels = try self.allocParamChannels(fd.params, arena_alloc);
                    try self.functions.append(arena_alloc, .{
                        .name = fd.name,
                        .node_start = 0,
                        .node_count = 0,
                        .param_channels = placeholder_param_channels,
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
                .import_decl => |imp| {
                    // 注册导入的顶层模块名（用于 field_access 识别模块引用）
                    if (imp.module_path.len > 0) {
                        try self.imported_modules.put(imp.module_path[0], {});
                    }
                    // 从 sema_result 读取 import 别名，填充 alias map
                    {
                        const sr = self.sema_result;
                        var alias_iter = sr.import_aliases.iterator();
                        while (alias_iter.next()) |entry| {
                            const short_name = entry.key_ptr.*;
                            const target = entry.value_ptr.*;
                            switch (target) {
                                .module => |full_path| {
                                    self.module_alias_map.put(short_name, full_path) catch {};
                                    // 让 isModuleReference 能识别短名
                                    self.imported_modules.put(short_name, {}) catch {};
                                },
                                .symbol => |mangled| {
                                    self.symbol_alias_map.put(short_name, mangled) catch {};
                                },
                            }
                        }
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |stmt| {
                        switch (stmt.*) {
                            .val_decl => |vd| {
                                const chan_type = if (vd.type_annotation) |tn|
                                    self.chanTypeFromTypeNodeResolved(tn) orelse unreachable
                                else
                                    self.inferChanTypeFromExpr(vd.value) orelse self.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
                                const chan = try self.allocChannel(chan_type);
                                // 保留 type_annotation：使 inferTypeNameFromExpr 可通过
                                // binding.type_annotation 推断全局 val 的类型（如 UNIX_EPOCH: SystemTime）
                                try self.scopeVarTyped(vd.name, chan, false, null, vd.type_annotation);
                                has_global_init = true;
                            },
                            .var_decl => |vd| {
                                const chan_type = if (vd.type_annotation) |tn|
                                    self.chanTypeFromTypeNodeResolved(tn) orelse unreachable
                                else
                                    self.inferChanTypeFromExpr(vd.value) orelse self.sema_result.getOrCreateRefDesc("unknown") catch unreachable;
                                const cell_chan = try self.allocCellChannel(chan_type);
                                try self.scopeVarTyped(vd.name, cell_chan, true, null, vd.type_annotation);
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
            const init_return_chan = try self.allocChannel(type_descriptor_mod.unit_descriptor);
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
                                    self.debug_error_func_name = vd.name;
                                    const value_chan = try self.compileExpr(vd.value);
                                    var store_node = Node.makeUnary(.store, binding.chan, 0, value_chan);
                                    store_node._pad = if (self.isRefExpr(vd.value)) 1 else 0;
                                    try self.emit(store_node);
                                },
                                .var_decl => |vd| {
                                    const binding = self.lookupVar(vd.name) orelse continue;
                                    self.current_func_name = vd.name;
                                    const value_chan = try self.compileExpr(vd.value);
                                    var store_node = Node.makeUnary(.store, binding.chan, 0, value_chan);
                                    store_node._pad = if (self.isRefExpr(vd.value)) 1 else 0;
                                    try self.emit(store_node);
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            const unit_chan = try self.allocChannel(type_descriptor_mod.unit_descriptor);
            try self.emit(Node.makeSink(.const_unit, unit_chan, 0));
            try self.emit(Node.makeUnary(.halt_return, init_return_chan, 0, unit_chan));

            const init_node_count: u32 = @intCast(self.nodes.items.len - init_node_start);
            const init_chan_end: u16 = self.channels.count();
            self.functions.items[init_idx.?].node_start = init_node_start;
            self.functions.items[init_idx.?].node_count = init_node_count;
            self.functions.items[init_idx.?].local_chan_start = init_chan_start;
            self.functions.items[init_idx.?].local_chan_count = init_chan_end - init_chan_start;
        }

        // 第二遍前：预扫描所有函数体与类型方法体，预注册全局 record_literal 字段
        // 原因：函数编译顺序由声明顺序决定，若 main 在 from_julian_day 之前编译，
        // main 中的 d.year/d.month/d.day 访问会因 "" 命名空间下字段未注册而 fallback 到 field_id=0，
        // 导致所有字段访问都返回第一个字段的值。
        // 预扫描以 "" 命名空间为全局键，把所有出现的 record 字段名按出现顺序注册到全局字段映射。
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| self.preRegisterRecordFields(fd.body),
                .type_decl => |td| {
                    for (td.methods) |method| {
                        if (method.body) |body| self.preRegisterRecordFields(body);
                    }
                },
                else => {},
            }
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

        // 第三遍：处理延迟实例化队列（泛型函数单态化体编译）
        // 在所有顶层函数编译完成后统一处理，避免被实例化函数的体节点
        // 与调用者函数的体节点交错导致 node_range 错误。
        try self.processDeferredInstantiations();

        // 释放全局作用域
        self.popScope();

        // 反射：解析所有 TypeMetadata 的 inner/target 引用（处理递归类型）
        self.resolveTypeMetadataRefs();
        // 反射：计算所有 TypeMetadata 的 size/alignment（类型布局 pass）
        self.computeTypeLayout();

        // 编译期元数据计算 pass
        try self.computeFunctionChannelLayout();
        try self.finalizeCoroutineFrameLayouts();
        try self.computeSCC();
        self.finalizeGlobalCount(init_idx);

        // 组装 IR（arena 所有权转交给 GlueIR）
        self.arena_owned = false;
        // 反射：构建 TypeMetadataTable（entries 由 arena 拥有，name_to_id 用 backing 分配）
        var type_metadata_table = TypeMetadataTable{
            .entries = try self.type_metadata_entries.toOwnedSlice(arena_alloc),
            .name_to_id = std.StringHashMap(u16).init(self.allocator),
        };
        try type_metadata_table.initNameMap(self.allocator);
        // type_desc_pool 所有权转移：channels.type_desc 指针引用此 pool 分配的内存，
        // pool 必须与 GlueIR 同生命周期，否则 sema_result.deinit() 会释放悬垂指针
        const type_desc_pool = self.sema_result.takeTypeDescPool();

        // 确保 node_locs 与 nodes 等长：编译器生成的节点（未经 emit）填充 {0, 0}
        while (self.node_locs.items.len < self.nodes.items.len) {
            try self.node_locs.append(arena_alloc, .{ .line = 0, .column = 0 });
        }
        return GlueIR{
            .nodes = try self.nodes.toOwnedSlice(arena_alloc),
            .node_locs = try self.node_locs.toOwnedSlice(arena_alloc),
            .scalar_metas = try self.scalar_metas.toOwnedSlice(arena_alloc),
            .call_metas = try self.call_metas.toOwnedSlice(arena_alloc),
            .vector_metas = try self.vector_metas.toOwnedSlice(arena_alloc),
            .gate_metas = try self.gate_metas.toOwnedSlice(arena_alloc),
            .route_metas = try self.route_metas.toOwnedSlice(arena_alloc),
            .race_metas = try self.race_metas.toOwnedSlice(arena_alloc),
            .cleanup_metas = try self.cleanup_metas.toOwnedSlice(arena_alloc),
            .orbit_metas = try self.orbit_metas.toOwnedSlice(arena_alloc),
            .coroutine_metas = try self.coroutine_metas.toOwnedSlice(arena_alloc),
            .loop_metas = try self.loop_metas.toOwnedSlice(arena_alloc),
            .closure_metas = try self.closure_metas.toOwnedSlice(arena_alloc),
            .partial_metas = try self.partial_metas.toOwnedSlice(arena_alloc),
            .syscall_metas = try self.syscall_metas.toOwnedSlice(arena_alloc),
            .functions = try self.functions.toOwnedSlice(arena_alloc),
            .string_pool = try self.string_pool.toOwnedSlice(arena_alloc),
            .channels = self.channels,
            .entry_index = entry_idx,
            .init_index = init_idx,
            .arena = self.arena,
            .backing = self.allocator,
            .type_metadata_table = type_metadata_table,
            .type_desc_pool = type_desc_pool,
        };
    }

    // ════════════════════════════════════════════════════════════════
    // 编译期元数据计算 pass
    // ════════════════════════════════════════════════════════════════

    /// IR 构建完成后计算每个函数的通道布局（chan_total_bytes + local_offsets）
    /// 必须在 build() 的 toOwnedSlice 之前调用
    pub fn computeFunctionChannelLayout(self: *IRBuilder) !void {
        const arena_alloc = self.arena.allocator();

        for (self.functions.items) |*func| {
            // 收集本函数所有本地通道 + return_channel
            const chan_count = @as(usize, func.local_chan_count) + 1;
            const all_chans = try arena_alloc.alloc(u16, chan_count);
            for (0..func.local_chan_count) |i| {
                all_chans[i] = func.local_chan_start + @as(u16, @intCast(i));
            }
            all_chans[func.local_chan_count] = func.return_channel;

            // 按对齐顺序计算偏移
            const offsets = try arena_alloc.alloc(u32, chan_count);
            var current_offset: usize = 0;

            for (all_chans, 0..) |chan, i| {
                const meta = self.channels.get(chan);
                const w = meta.elem_width;
                if (w == 0) {
                    offsets[i] = @intCast(current_offset);
                    continue;
                }
                current_offset = std.mem.alignForward(usize, current_offset, 16);
                offsets[i] = @intCast(current_offset);
                current_offset += w;
            }

            func.local_offsets = offsets;
            func.chan_total_bytes = @intCast(std.mem.alignForward(usize, current_offset, 16));
        }
    }

    /// 重新计算所有 CoroutineMeta 的 frame_layout。
    ///
    /// 必须在 computeFunctionChannelLayout 之后调用：transformToStateMachine 在
    /// compileFunction 阶段（layout 计算之前）生成 CoroutineMeta，此时
    /// func.chan_total_bytes 与 func.local_offsets 还是 0/空，frame_layout 不正确。
    /// 本函数用计算后的 func 数据重新构建 frame_layout，修正参数区/局部区布局。
    pub fn finalizeCoroutineFrameLayouts(self: *IRBuilder) !void {
        const arena_alloc = self.arena.allocator();
        const smt = @import("state_machine_transform.zig");
        for (self.coroutine_metas.items) |*cm| {
            if (cm.func_idx >= self.functions.items.len) continue;
            const func = &self.functions.items[cm.func_idx];
            cm.frame_layout = try smt.buildFrameLayout(arena_alloc, func, &self.channels);
        }
    }

    /// 互递归 SCC 分析：使用 Tarjan 算法识别强连通分量
    /// 必须在 computeFunctionChannelLayout 之后调用
    pub fn computeSCC(self: *IRBuilder) !void {
        const n = self.functions.items.len;
        if (n == 0) return;

        const allocator = self.allocator;
        const scc_id = try allocator.alloc(u32, n);
        defer allocator.free(scc_id);
        @memset(scc_id, std.math.maxInt(u32));

        var index_counter: u32 = 0;
        var stack = std.ArrayList(u16).empty;
        defer stack.deinit(allocator);
        const on_stack = try allocator.alloc(bool, n);
        defer allocator.free(on_stack);
        @memset(on_stack, false);
        const indices = try allocator.alloc(?u32, n);
        defer allocator.free(indices);
        @memset(indices, null);
        const lowlinks = try allocator.alloc(u32, n);
        defer allocator.free(lowlinks);
        @memset(lowlinks, 0);
        var scc_counter: u32 = 0;

        for (self.functions.items, 0..) |_, fi| {
            if (indices[fi] != null) continue;
            try self.tarjanSCCVisit(@intCast(fi), &index_counter, &stack, on_stack, indices, lowlinks, scc_id, &scc_counter);
        }

        // 按 SCC 分组，计算每个 SCC 的 max(chan_total_bytes)
        var scc_maxes = std.AutoHashMap(u32, u32).init(allocator);
        defer scc_maxes.deinit();

        for (self.functions.items, 0..) |func, i| {
            const sid = scc_id[i];
            const current_max = scc_maxes.get(sid) orelse 0;
            try scc_maxes.put(sid, @max(current_max, func.chan_total_bytes));
        }

        // 填充 scc_max_chan_bytes
        for (self.functions.items, 0..) |*func, i| {
            const sid = scc_id[i];
            func.scc_max_chan_bytes = scc_maxes.get(sid).?;
        }
    }

    /// 确定 global_count：全局通道数量
    /// 必须在 build() 末尾、channels 所有权转交前调用
    pub fn finalizeGlobalCount(self: *IRBuilder, init_index: ?u16) void {
        if (init_index) |init_idx| {
            self.channels.global_count = self.functions.items[init_idx].local_chan_start;
        } else {
            self.channels.global_count = 0;
        }
    }

    // ════════════════════════════════════════════
    // 通道与元数据分配
    // ════════════════════════════════════════════

    pub fn allocChannel(self: *IRBuilder, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.channels.alloc(type_desc);
    }

    /// 分配带 inner_type_desc 的通道（Lazy<T>/Channel<T> 等容器）
    pub fn allocChannelWithInner(self: *IRBuilder, type_desc: *const type_descriptor_mod.TypeDescriptor, inner_type_desc: ?*const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.channels.allocWithInner(type_desc, inner_type_desc);
    }

    pub fn allocRef(self: *IRBuilder, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.channels.allocRef(type_desc);
    }

    pub fn allocCellChannel(self: *IRBuilder, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.channels.allocCell(type_desc);
    }

    /// 从 cell 通道读取当前值，返回普通值通道
    pub fn emitLoad(self: *IRBuilder, cell_chan: u16) BuildError!u16 {
        const meta = self.channels.get(cell_chan);
        const load_chan = try self.allocChannel(meta.type_desc);
        try self.emit(Node.makeUnary(.load, load_chan, 0, cell_chan));
        return load_chan;
    }

    /// 添加标量元数据，返回 1-based meta_index
    pub fn addScalarMeta(self: *IRBuilder, meta: ScalarMeta) !u16 {
        try self.scalar_metas.append(self.arena.allocator(), meta);
        return @intCast(self.scalar_metas.items.len - 1); // 0 是占位，从 1 开始
    }

    /// 添加调用元数据，返回 1-based meta_index
    pub fn addCallMeta(self: *IRBuilder, meta: CallMeta) !u16 {
        try self.call_metas.append(self.arena.allocator(), meta);
        return @intCast(self.call_metas.items.len);
    }

    /// 添加向量元数据，返回 1-based meta_index
    pub fn addVectorMeta(self: *IRBuilder, meta: VectorMeta) !u16 {
        try self.vector_metas.append(self.arena.allocator(), meta);
        return @intCast(self.vector_metas.items.len);
    }

    /// 添加门控元数据，返回 1-based meta_index
    pub fn addGateMeta(self: *IRBuilder, meta: GateMeta) !u16 {
        try self.gate_metas.append(self.arena.allocator(), meta);
        return @intCast(self.gate_metas.items.len);
    }

    /// 添加路由元数据，返回 1-based meta_index
    pub fn addRouteMeta(self: *IRBuilder, meta: RouteMeta) !u16 {
        try self.route_metas.append(self.arena.allocator(), meta);
        return @intCast(self.route_metas.items.len);
    }

    /// 添加竞争元数据，返回 1-based meta_index
    pub fn addRaceMeta(self: *IRBuilder, meta: RaceMeta) !u16 {
        try self.race_metas.append(self.arena.allocator(), meta);
        return @intCast(self.race_metas.items.len);
    }

    /// 添加清理元数据，返回 1-based meta_index
    pub fn addCleanupMeta(self: *IRBuilder, meta: CleanupMeta) !u16 {
        try self.cleanup_metas.append(self.arena.allocator(), meta);
        return @intCast(self.cleanup_metas.items.len);
    }

    /// 添加星轨元数据，返回 1-based meta_index
    pub fn addOrbitMeta(self: *IRBuilder, meta: OrbitMeta) !u16 {
        try self.orbit_metas.append(self.arena.allocator(), meta);
        return @intCast(self.orbit_metas.items.len);
    }

    /// 添加协程元数据，返回 1-based meta_index
    pub fn addCoroutineMeta(self: *IRBuilder, meta: CoroutineMeta) !u16 {
        try self.coroutine_metas.append(self.arena.allocator(), meta);
        return @intCast(self.coroutine_metas.items.len);
    }

    /// 为协程的 defer/catch 块体创建独立 sync Function，回填 func_idx。
    ///
    /// 阶段 1b 完善：defer 块体和 catch handler 编译为独立 sync 函数，
    /// 调度器可通过 func_idx 直接调用执行，运行时通过 captured_locals
    /// 访问主协程帧的 slot（无需内联重复展开块体节点）。
    ///
    /// 独立函数共享主节点流的子范围（node_start/count 指向 block_body_*），
    /// 无独立参数通道（通过 captured_locals slot 索引访问主帧），
    /// 返回 unit_chan。
    pub fn materializeCoroutineSyncFunctions(self: *IRBuilder, cm: *CoroutineMeta) !void {
        const arena_alloc = self.arena.allocator();
        const func_idx = cm.func_idx;

        // defer 块体独立函数化
        var defer_n: u32 = 0;
        for (cm.defer_table.entries) |*entry| {
            defer_n += 1;
            if (entry.block_body_len == 0) continue;
            const name = std.fmt.allocPrint(arena_alloc, "__defer_{d}_{d}", .{ func_idx, defer_n }) catch return error.OutOfMemory;
            const ret_chan = try self.channels.alloc(type_descriptor_mod.unit_descriptor);
            const new_func_idx: u16 = @intCast(self.functions.items.len);
            try self.func_table.put(name, new_func_idx);
            try self.functions.append(arena_alloc, .{
                .name = name,
                .node_start = entry.block_body_start,
                .node_count = entry.block_body_len,
                .param_channels = &.{},
                .return_channel = ret_chan,
                .is_entry = false,
                .is_async = false,
            });
            entry.block_func_idx = new_func_idx;
        }

        // catch handler 独立函数化
        var catch_n: u32 = 0;
        for (cm.catch_table.entries) |*entry| {
            catch_n += 1;
            if (entry.handler_body_len == 0) continue;
            const name = std.fmt.allocPrint(arena_alloc, "__catch_{d}_{d}", .{ func_idx, catch_n }) catch return error.OutOfMemory;
            const ret_chan = try self.channels.alloc(type_descriptor_mod.unit_descriptor);
            const new_func_idx: u16 = @intCast(self.functions.items.len);
            try self.func_table.put(name, new_func_idx);
            try self.functions.append(arena_alloc, .{
                .name = name,
                .node_start = entry.handler_body_start,
                .node_count = entry.handler_body_len,
                .param_channels = &.{},
                .return_channel = ret_chan,
                .is_entry = false,
                .is_async = false,
            });
            entry.handler_func_idx = new_func_idx;
        }
    }

    /// 添加循环元数据，返回 1-based meta_index
    pub fn addLoopMeta(self: *IRBuilder, meta: LoopMeta) !u16 {
        try self.loop_metas.append(self.arena.allocator(), meta);
        return @intCast(self.loop_metas.items.len);
    }

    /// 添加闭包元数据，返回 1-based meta_index
    pub fn addClosureMeta(self: *IRBuilder, meta: ClosureMeta) !u16 {
        try self.closure_metas.append(self.arena.allocator(), meta);
        return @intCast(self.closure_metas.items.len);
    }

    /// 添加部分应用元数据，返回 1-based meta_index
    pub fn addPartialMeta(self: *IRBuilder, meta: PartialMeta) !u16 {
        try self.partial_metas.append(self.arena.allocator(), meta);
        return @intCast(self.partial_metas.items.len);
    }

    /// 添加 syscall 元数据，返回 1-based meta_index
    pub fn addSyscallMeta(self: *IRBuilder, meta: SyscallMeta) !u16 {
        try self.syscall_metas.append(self.arena.allocator(), meta);
        return @intCast(self.syscall_metas.items.len);
    }

    /// 检测 AST 表达式或语句中是否含 break/continue
    pub fn containsBreakOrContinue(self: *IRBuilder, expr: *const ast.Expr) bool {
        _ = self;
        return astContainsBreakOrContinueExpr(expr);
    }

    /// 检测语句列表中是否含 break/continue
    pub fn stmtsContainBreakOrContinue(self: *IRBuilder, stmts: []const *ast.Stmt) bool {
        _ = self;
        for (stmts) |s| {
            if (astContainsBreakOrContinueStmt(s)) return true;
        }
        return false;
    }

    pub fn emit(self: *IRBuilder, node: Node) !void {
        try self.nodes.append(self.arena.allocator(), node);
        try self.node_locs.append(self.arena.allocator(), self.current_loc);
    }

    // ════════════════════════════════════════════
    // 作用域管理
    // ════════════════════════════════════════════

    pub fn pushScope(self: *IRBuilder) !void {
        try self.scope_stack.append(self.allocator, .{ .bindings = .empty });
    }

    pub fn popScope(self: *IRBuilder) void {
        if (self.scope_stack.pop()) |scope| {
            var s = scope;
            s.bindings.deinit(self.allocator);
        }
    }

    pub fn defineVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool) !void {
        try self.scopeVar(name, chan, is_cell, null);
    }

    pub fn scopeVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool, ast_expr: ?*const ast.Expr) !void {
        try self.scopeVarTyped(name, chan, is_cell, ast_expr, null);
    }

    /// 在 arena 中分配一个 .named TypeNode（用于循环变量等需要类型名推断的场景）
    /// 返回的指针在 build() 期间有效（arena 生命周期）
    pub fn makeNamedTypeNode(self: *IRBuilder, type_name: []const u8) !*ast.TypeNode {
        const slot = try self.arena.allocator().create(ast.NodeSlot(ast.TypeNode));
        slot.* = .{
            .loc = .{ .line = 0, .column = 0 },
            .node = .{ .named = .{ .name = type_name } },
        };
        return &slot.node;
    }

    /// 从数组类型名剥离 "[]" 后缀得到元素类型名
    /// "DirEntry[]" → "DirEntry"，"u8[]" → "u8"；非数组类型返回 null
    pub fn arrayElemTypeName(type_name: []const u8) ?[]const u8 {
        if (std.mem.endsWith(u8, type_name, "[]")) {
            return type_name[0 .. type_name.len - 2];
        }
        return null;
    }

    pub fn scopeVarTyped(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool, ast_expr: ?*const ast.Expr, type_annotation: ?*ast.TypeNode) !void {
        try self.scope_stack.items[self.scope_stack.items.len - 1].bindings.append(
            self.allocator,
            .{ .name = name, .chan = chan, .is_cell = is_cell, .ast_expr = ast_expr, .type_annotation = type_annotation },
        );
    }

    /// 将当前作用域最后一条绑定标记为 Atomic（用于 var/val/param 传播 is_atomic）
    pub fn markLastBindingAtomic(self: *IRBuilder) void {
        const bindings = &self.scope_stack.items[self.scope_stack.items.len - 1].bindings;
        if (bindings.items.len > 0) {
            bindings.items[bindings.items.len - 1].is_atomic = true;
        }
    }

    /// 检查类型节点是否为 Atomic<T>
    pub fn isAtomicType(type_node: ?*const ast.TypeNode) bool {
        const tn = type_node orelse return false;
        return switch (tn.*) {
            .generic => |g| std.mem.eql(u8, g.name, "Atomic"),
            else => false,
        };
    }

    /// 检查标识符对应的绑定是否为 Atomic
    pub fn isAtomicBinding(self: *IRBuilder, name: []const u8) bool {
        if (self.lookupVar(name)) |binding| return binding.is_atomic;
        return false;
    }

    pub fn lookupVar(self: *IRBuilder, name: []const u8) ?VarBinding {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scope_stack.items[i].bindings.items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b;
            }
        }
        return null;
    }

    // ════════════════════════════════════════════════════════════
    // v3 阶段 3：sema 适配器层
    // 构造 sema.inference.InferContext/InferContextExt，使 builder.zig
    // 的 infer*/chanTypeFrom* 方法委托到 sema 侧实现。
    // ════════════════════════════════════════════════════════════

    /// var_lookup 适配器回调：将 IRBuilder.VarBinding 转换为 sema.inference.VarBinding
    fn varLookupAdapter(ctx: *anyopaque, name: []const u8) ?sema.inference.VarBinding {
        const builder: *IRBuilder = @ptrCast(@alignCast(ctx));
        if (builder.lookupVar(name)) |binding| {
            return .{
                .type_annotation = binding.type_annotation,
                .ast_expr = binding.ast_expr,
            };
        }
        return null;
    }

    /// 构造 sema InferContext（栈上）
    pub fn inferContext(self: *const IRBuilder) ?sema.inference.InferContext {
        if (self.current_module == null) return null;
        return sema.inference.InferContext{
            .sema_result = self.sema_result,
            .module = &self.current_module.?,
            .arena = self.arena.allocator(),
        };
    }

    /// 构造 sema InferContextExt（栈上，带 var_lookup 回调）
    pub fn inferContextExt(self: *IRBuilder, ctx: *sema.inference.InferContext) sema.inference.InferContextExt {
        return .{
            .base = ctx,
            .var_lookup_ctx = @ptrCast(self),
            .var_lookup_fn = varLookupAdapter,
        };
    }

    /// 构造 sema GadtContext（栈上，封装 GADT 推断所需的所有依赖）
    /// gadt_binding_stack/current_func_param_types/current_func_name 仍由 IRBuilder 持有
    pub fn gadtContext(self: *IRBuilder) sema.inference.GadtContext {
        return .{
            .allocator = self.allocator,
            .sema_result = self.sema_result,
            .current_type_args = self.current_type_args,
            .current_module = if (self.current_module) |*m| m else null,
            .binding_stack = &self.gadt_binding_stack,
            .func_param_types = self.current_func_param_types,
            .func_name = self.current_func_name,
            .var_lookup_ctx = @ptrCast(self),
            .var_lookup_fn = varLookupAdapter,
        };
    }

    /// 更新已有绑定的 ast_expr 字段（用于预声明 lambda 后补充类型推断信息）
    pub fn updateVarAstExpr(self: *IRBuilder, name: []const u8, ast_expr: *const ast.Expr) void {
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
    // 函数编译（v3 阶段 4：方法体已物理拆分到 func_compiler.zig）
    // ════════════════════════════════════════════

    /// 编译 type_decl 的方法体（第二遍）
    pub const compileTypeMethods = @import("func_compiler.zig").Methods.compileTypeMethods;
    /// 检查类型是否自己覆盖了某方法
    pub const isMethodOverridden = @import("func_compiler.zig").Methods.isMethodOverridden;
    /// 从 AST 参数列表预分配参数通道
    pub const allocParamChannels = @import("func_compiler.zig").Methods.allocParamChannels;
    pub const compileFunction = @import("func_compiler.zig").Methods.compileFunction;

    // ════════════════════════════════════════════
    // 表达式编译
    // ════════════════════════════════════════════

    pub const compileExpr = @import("expr_compiler.zig").Methods.compileExpr;

    /// 编译整数字面量
    pub const compileIntLiteral = @import("expr_compiler.zig").Methods.compileIntLiteral;

    /// 编译浮点字面量
    pub const compileFloatLiteral = @import("expr_compiler.zig").Methods.compileFloatLiteral;

    /// 编译二元运算
    pub const compileBinary = @import("expr_compiler.zig").Methods.compileBinary;

    /// 编译短路逻辑运算符 && / ||
    /// a && b: a 为 false 时直接返回 false，不评估 b
    /// a || b: a 为 true 时直接返回 true，不评估 b
    pub const compileShortCircuit = @import("expr_compiler.zig").Methods.compileShortCircuit;

    /// 编译 range 表达式：start..end 或 start..=end → array
    pub const compileRangeExpr = @import("expr_compiler.zig").Methods.compileRangeExpr;

    /// 编译二元运算（左操作数已编译为通道）
    pub const compileBinaryOpWithChan = @import("expr_compiler.zig").Methods.compileBinaryOpWithChan;

    /// 发射标量类型转换节点（int→int, float→float, int→float, float→int）
    /// 用于二元运算前统一操作数类型
    pub const emitScalarCast = @import("expr_compiler.zig").Methods.emitScalarCast;

    /// 发射 lazy_force 节点：将 Lazy<T> 强制求值为标量 T。
    /// 用于二元/一元运算等严格上下文：ref_chan 操作数在参与标量运算前先被观察。
    pub const emitLazyForce = @import("expr_compiler.zig").Methods.emitLazyForce;

    /// 从 sema expr_types 查询 lazy 表达式的元素类型 T（Lazy<T> 中的 T）
    pub const lazyElemTypeFromExpr = @import("expr_compiler.zig").Methods.lazyElemTypeFromExpr;

    /// 从 sema expr_types 查询 channel 方法调用的元素类型 T（Channel<T> 的 recv/tryRecv）
    pub const channelElemTypeFromExpr = @import("expr_compiler.zig").Methods.channelElemTypeFromExpr;

    /// 通用观察辅助：当通道是 ref_chan（Lazy<T> 或其他引用）且当前上下文需要标量值时，
    /// 发射 lazy_force 节点强制求值。若已是标量通道则原样返回。
    pub const forceLazyIfRef = @import("expr_compiler.zig").Methods.forceLazyIfRef;

    /// 函数参数观察辅助：实参通道传入目标形参通道前，若实参是 Lazy<T>（ref_chan）
    /// 而形参通道期望标量/nullable，则强制求值到目标类型；若目标也是引用类型则保留引用。
    pub const forceLazyArgIfNeeded = @import("expr_compiler.zig").Methods.forceLazyArgIfNeeded;

    /// 编译一元运算
    pub const compileUnary = @import("expr_compiler.zig").Methods.compileUnary;

    /// 编译取引用 &expr
    /// - 复合类型（ref_chan）：operand 已经是指针，ref_of 直接复制指针到新的 ref_chan
    /// - 标量（i32/f64 等）：operand 是内联值，ref_of 装箱为 Cell 写入 ref_chan
    ///   标量引用统一通过 Cell 装箱实现回写语义
    /// - ref_chan（已经是引用）：ref_of 复制引用本身（引用的引用）
    pub const compileRefOf = @import("expr_compiler.zig").Methods.compileRefOf;

    /// 编译解引用 *expr
    /// 读取引用指向的值到新通道，output 通道类型由 sema 推断的 inner 类型决定
    pub const compileDeref = @import("expr_compiler.zig").Methods.compileDeref;

    /// 编译 if 表达式（惰性分支：then/else 作为子图，由 route_dispatch 按条件执行）
    pub const compileIf = @import("expr_compiler.zig").Methods.compileIf;

    /// 编译类型转换（type_cast）
    /// safe=false: i32(big) — 不安全转换，wrap/饱和
    /// safe=true:  i32(x)?  — 安全转换，越界抛出错误（? 传播）
    pub const compileTypeCast = @import("expr_compiler.zig").Methods.compileTypeCast;

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
    pub const compileCastBuilder = @import("expr_compiler.zig").Methods.compileCastBuilder;

    /// 预扫描 AST 表达式，为所有 record_literal / record_extend 字段注册全局 field_id
    /// 用于解决函数编译顺序导致的全局字段映射缺失问题（详见 build() 注释）
    /// 仅以 "" 命名空间注册，与 compileRecordLiteral/compileRecordExtend 的运行时注册保持一致
    pub const preRegisterRecordFields = @import("expr_compiler.zig").Methods.preRegisterRecordFields;

    /// preRegisterRecordFields 的语句版：递归到语句内的表达式与子语句
    pub const preRegisterStmtFields = @import("expr_compiler.zig").Methods.preRegisterStmtFields;

    /// 编译记录字面量：{ field1: val1, field2: val2 }
    /// → record_make(field_count=N) + 逐个 record_set(field_id=i)
    /// 字段按声明顺序分配 field_id = 0..N-1
    pub const compileRecordLiteral = @import("expr_compiler.zig").Methods.compileRecordLiteral;

    /// 编译记录扩展：(...base, field: value, ...)
    /// → record_clone_extend(base, extra_count) → record_set(new_rec, field_id, value) ...
    /// record_clone 的 meta 编码扩展字段数：运行时分配 base.fields.len + extra 个槽位
    /// 已存在字段的 field_id 保持不变（复用 base 的），新字段从 base.fields.len 开始追加
    pub const compileRecordExtend = @import("expr_compiler.zig").Methods.compileRecordExtend;

    /// 统计 record 表达式的字段数（用于 record_extend 的 field_id 分配）
    pub const countRecordFields = @import("expr_compiler.zig").Methods.countRecordFields;

    /// 编译赋值表达式：target = value（作为表达式，返回 value）
    pub const compileAssignmentExpr = @import("expr_compiler.zig").Methods.compileAssignmentExpr;

    /// 编译复合赋值表达式：target op= value（作为表达式，返回结果）
    pub const compileCompoundAssignExpr = @import("expr_compiler.zig").Methods.compileCompoundAssignExpr;

    /// 编译字段访问：obj.field
    /// → record_get(obj, field_id) 或 channel_sender/channel_receiver
    /// field_id 通过 field_id_map 查找：先推断 obj 的 type_name，再查映射
    pub const compileFieldAccess = @import("expr_compiler.zig").Methods.compileFieldAccess;

    /// 通过类型名查 sema_result 获取字段类型（用于 method_call 返回值等场景）
    /// v3 阶段 3：委托到 sema.inference.inferFieldTypeByCtor
    pub fn inferFieldTypeByCtor(self: *IRBuilder, type_name: []const u8, field: []const u8) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return null;
        return sema.inference.inferFieldTypeByCtor(&ctx, type_name, field);
    }

    /// 从 AST 推断字段类型（无 sema 时的简易类型推导）
    /// 通过回溯对象表达式找到 record_literal/record_extend/构造器调用，再查字段值类型
    /// v3 阶段 3：委托到 sema.inference.inferFieldType
    pub fn inferFieldType(self: *IRBuilder, object: *const ast.Expr, field: []const u8) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferFieldType(&ext, object, field);
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
    pub const typeInfoFieldType = @import("expr_compiler.zig").Methods.typeInfoFieldType;

    /// 从表达式推断通道类型
    /// v3 阶段 3：委托到 sema.inference.inferChanTypeFromExpr
    pub fn inferChanTypeFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return null;
        return sema.inference.inferChanTypeFromExpr(&ctx, expr);
    }

    /// 判断表达式是否为引用类型（&T / *T）
    /// v3 阶段 3：委托到 sema.inference.isRefExpr
    pub fn isRefExpr(self: *IRBuilder, expr: *const ast.Expr) bool {
        var ctx = self.inferContext() orelse return false;
        return sema.inference.isRefExpr(&ctx, expr);
    }

    /// 编译索引访问：obj[index]
    /// 数组 → array_get，字符串 → string_index
    pub const compileIndex = @import("expr_compiler.zig").Methods.compileIndex;

    /// 编译切片表达式 obj[start..end] 或 obj[start..=end]
    /// 根据 object 类型分派到 array_slice 或 string_slice NodeOp
    /// inclusive=true 时 end 包含在结果中（start..=end）
    pub const compileSlice = @import("expr_compiler.zig").Methods.compileSlice;

    /// 编译字符串插值："...${expr}..."
    /// → 逐段 string_concat 链
    pub const compileStringInterpolation = @import("expr_compiler.zig").Methods.compileStringInterpolation;

    /// 将表达式编译为字符串通道（非字符串表达式先 builtin_str 转换）
    pub const exprToStringChan = @import("expr_compiler.zig").Methods.exprToStringChan;

    /// 发射字符串常量通道（const_str 节点）。
    /// 复用字符串字面量编译方式：addString + const_str sink 节点。
    pub const emitStrConstant = @import("expr_compiler.zig").Methods.emitStrConstant;

    /// 发射字符串拼接 IR（string_concat 节点），返回结果通道。
    pub const emitStrConcat = @import("expr_compiler.zig").Methods.emitStrConcat;

    /// 通过类型名 + 字段名生成字段访问 IR（record_get 节点）。
    /// 复用 lookupFieldId / addFieldIdMeta，与 compileFieldAccess 同机制。
    pub const compileFieldAccessByChan = @import("expr_compiler.zig").Methods.compileFieldAccessByChan;

    /// 编译函数调用
    pub const compileCall = @import("expr_compiler.zig").Methods.compileCall;

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
    pub const resolveTypeofMetaIndex = @import("expr_compiler.zig").Methods.resolveTypeofMetaIndex;

    /// reflect(x) 参数解析为 meta_index
    ///
    /// 与 typeof 不同，reflect 接收值表达式而非类型表达式。
    /// 解析策略：
    /// 1. 若 arg 是标识符且匹配当前函数的某个参数名：
    ///    a. 检查该参数的 type_annotation，若是 `.named` 且匹配某个类型参数 T，
    ///       发射哨兵 `0x8000|param_idx`（运行时从 frame.type_args 解析）
    ///    b. 若 type_annotation 是具体类型名，查 type_name_to_id 返回 type_id
    /// 2. 其他情况：从 sema 获取实参 type_name 查表，未找到返回 0
    pub const resolveReflectMetaIndex = @import("expr_compiler.zig").Methods.resolveReflectMetaIndex;

    /// 编译函数调用，附带显式类型实参（来自 `func[T](args)` 形式）
    /// type_args_hint != null 时优先使用显式类型实参；否则从参数类型推断
    pub const compileCallWithTypeArgs = @import("expr_compiler.zig").Methods.compileCallWithTypeArgs;

    /// 从 sema call_instantiations 查询调用点的 instance_id（消费 sema 产出）
    pub const instanceIdFromCallExpr = @import("expr_compiler.zig").Methods.instanceIdFromCallExpr;

    /// 从 instance_id 提取 type_args（u16 切片，用于 CallMeta/OrbitMeta）
    pub const typeArgsFromInstanceId = @import("expr_compiler.zig").Methods.typeArgsFromInstanceId;

    /// 从 sema call_instantiations 查询调用点的 type_args（消费 sema 产出）
    pub const typeArgsFromCallExpr = @import("expr_compiler.zig").Methods.typeArgsFromCallExpr;

    /// 从当前单态化实例提取 type_args（直接递归调用使用）
    pub const typeArgsFromCurrentInstance = @import("expr_compiler.zig").Methods.typeArgsFromCurrentInstance;

    /// 从参数类型注解匹配类型参数名，并从实参提取对应的 type_id
    /// 例如：参数注解 T，实参 typeof(Point) → name_to_typeid["T"] = Point 的 type_id
    ///
    /// 单态化上下文：当外层泛型函数被实例化时（如 println<i32>），其参数 x: T
    /// 的类型参数 T 已在 sema instance.type_args 中绑定到具体 type_id。
    /// 内层调用 format(x) 时，实参 x 的类型注解仍是 T，此时从 current_type_args
    /// 查找 T 的具体 type_id，使内层泛型函数也能正确单态化。
    pub const matchTypeParamToTypeId = @import("expr_compiler.zig").Methods.matchTypeParamToTypeId;

    /// 判断通道类型是否为标量（无堆指针，可安全作为 memo key/val）
    /// 标量：整数、浮点、布尔、字符。排除 ref/nullable/null/unit（后者无信息量或含堆指针）
    pub const isScalarChanType = @import("expr_compiler.zig").Methods.isScalarChanType;

    /// 可 memoize 的通道类型：标量 + nullable_chan
    /// 排除 ref_chan（指针哈希命中率低，deepCopy 返回值开销巨大）
    /// 排除 unit_chan/null_chan（无数据）和 mask_chan（内部状态）
    /// nullable_chan 仅当 inner_type 为标量时才有效（Engine 层处理）
    pub const isMemoizableChanType = @import("expr_compiler.zig").Methods.isMemoizableChanType;

    /// 尝试为纯函数分配 memo_slot。
    /// 条件：purity_db 可用 + 函数为 pure + 所有实参通道为标量 + 返回类型为标量。
    /// 同一函数名复用同一 slot（per-function memo，非 per-call-site）。
    /// 返回 0 表示不可 memoize，>0 表示 slot 索引。
    pub const tryAssignMemoSlot = @import("expr_compiler.zig").Methods.tryAssignMemoSlot;

    /// 推断表达式对应的函数返回类型 AST 节点。
    /// 用于追踪 val x = func(args) 或 val x = obj.method(args) 中 x 的类型。
    /// v3 阶段 3：委托到 sema.inference.inferReturnTypeAst
    pub fn inferReturnTypeAst(self: *IRBuilder, expr: *const ast.Expr) ?*ast.TypeNode {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferReturnTypeAst(&ext, expr);
    }

    /// 推断 Throw 表达式的 Ok 值类型节点（TypeNode）。
    /// 用于 Ok(pattern) 中 pattern 变量的类型标注，使方法分派能正确找到用户自定义方法。
    /// 支持 await（Async<Throw<T,E>> → T）、? 操作符、普通函数调用和方法调用。
    /// v3 阶段 3：委托到 sema.inference.inferThrowOkTypeNode
    pub fn inferThrowOkTypeNode(self: *IRBuilder, expr: *const ast.Expr) ?*ast.TypeNode {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferThrowOkTypeNode(&ext, expr);
    }

    /// 推断 Throw 表达式的 Ok 值通道类型
    /// 用于 match Ok(pattern) 和 ? 操作符，避免对 ref 类型硬编码 i64_chan
    /// v3 阶段 3：委托到 sema.inference.inferThrowOkChanType
    pub fn inferThrowOkChanType(self: *IRBuilder, expr: *const ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferThrowOkChanType(&ext, expr);
    }

    /// 推断 `expr?`（propagate）表达式中 Ok 值的类型名。
    /// 用于 `val r = obj.method()?; r.field` 场景下推断 r 的类型。
    /// 与 inferThrowOkChanType 平行，但返回类型名而非 TypeDescriptor。
    /// v3 阶段 3：委托到 sema.inference.inferThrowOkTypeName
    pub fn inferThrowOkTypeName(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferThrowOkTypeName(&ext, expr);
    }

    /// 推断表达式的通道类型（用于泛型类型参数推断）
    /// 支持：构造器调用（用 return_type 推断）、字面量、标识符
    pub const inferExprChanType = @import("expr_compiler.zig").Methods.inferExprChanType;

    /// 检查类型节点是否包含类型参数（单字母大写名）
    pub const typeNodeHasTypeParam = @import("expr_compiler.zig").Methods.typeNodeHasTypeParam;

    /// 检查名称是否为类型参数（单字母大写名或 T1, T2 等）
    pub const isTypeNameParam = @import("expr_compiler.zig").Methods.isTypeNameParam;

    /// 推断构造器调用的通道类型（含 GADT 类型参数推断）
    /// 对于 If(Expr<bool>, Expr<T>, Expr<T>) : Expr<T>，
    /// 当实参为 (BoolLit, IntLit, IntLit) 时，T=i32，返回 Expr<i32> 的通道类型
    pub const inferConstructorChanType = @import("expr_compiler.zig").Methods.inferConstructorChanType;

    /// 使用 GADT 绑定栈解析类型节点的通道类型
    /// 从栈顶向下查找类型参数绑定，找到则返回具体类型，否则用 chanTypeFromTypeNode
    pub const resolveFieldTypeWithBindings = @import("expr_compiler.zig").Methods.resolveFieldTypeWithBindings;

    /// 从 AST 类型节点 + 泛型绑定映射推导通道类型（统一路径：委托 sema/type_resolver.resolveTypeNodeConcrete）
    pub const chanTypeWithTypeNode = @import("expr_compiler.zig").Methods.chanTypeWithTypeNode;

    /// 推断泛型函数调用的返回通道类型
    /// 通过匹配参数类型注解与实参类型，推断类型参数绑定
    pub const inferGenericCallReturnType = @import("expr_compiler.zig").Methods.inferGenericCallReturnType;

    /// 递归匹配类型参数绑定
    /// param_type: 参数的类型注解（可能含泛型参数 T）
    /// arg_type: 实参的通道类型
    /// bindings: 输出——类型参数名 → 通道类型
    pub const matchTypeParamBinding = @import("expr_compiler.zig").Methods.matchTypeParamBinding;

    /// 检查名称是否为类型参数（委托给 isTypeNameParam）
    pub const isTypeParamName = @import("expr_compiler.zig").Methods.isTypeParamName;

    /// 从构造器调用表达式或带类型注解的标识符提取 GADT 类型参数绑定
    /// 例如：Add(IntLit(3), IntLit(4)) 的 return_type 是 Expr<i32>
    /// 匹配参数类型 Expr<T> → T = i32
    /// 对于 If(BoolLit, IntLit, IntLit) : Expr<T>，先从字段类型推断 T=i32，再匹配
    pub const extractCtorTypeBinding = @import("expr_compiler.zig").Methods.extractCtorTypeBinding;

    /// 编译构造器调用：Ctor(args...) → record_make(type_name, field_count=N+1) + record_set(__tag=0, tag) + record_set(field_id=i+1, val)...
    /// ADT 值用 record 表示，__tag 字段（field_id=0）存储构造器索引（用于 match 分派）
    pub const compileConstructorCall = @import("expr_compiler.zig").Methods.compileConstructorCall;

    // ════════════════════════════════════════════
    // 星轨编译（async，Phase 5）
    // ════════════════════════════════════════════

    /// 发射 orbit_async_create 节点：创建异步轨道，返回 handle 通道
    pub const emitOrbitCreate = @import("expr_compiler.zig").Methods.emitOrbitCreate;

    /// 发射 orbit_async_join 节点：等待轨道完成，返回结果通道
    pub fn emitOrbitJoin(self: *IRBuilder, handle_chan: u16, orbit_meta_idx: u16) BuildError!u16 {
        const orbit_meta = self.orbit_metas.items[orbit_meta_idx - 1];
        const result_chan = try self.allocChannel(orbit_meta.result_type_desc);
        try self.emit(Node.makeUnary(.orbit_async_join, result_chan, orbit_meta_idx, handle_chan));
        return result_chan;
    }

    /// 发射 orbit_chan_send 节点：向轨道通道发送值
    pub fn emitOrbitSend(self: *IRBuilder, handle_chan: u16, val_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(type_descriptor_mod.unit_descriptor);
        try self.emit(Node.makeBinary(.orbit_chan_send, out, 0, handle_chan, val_chan));
        return out;
    }

    /// 发射 orbit_chan_recv 节点：从轨道通道接收值（阻塞）
    pub fn emitOrbitRecv(self: *IRBuilder, handle_chan: u16, result_type: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const out = try self.allocChannel(result_type);
        try self.emit(Node.makeUnary(.orbit_chan_recv, out, 0, handle_chan));
        return out;
    }

    /// 发射 orbit_chan_try_recv 节点：非阻塞接收，返回 nullable
    pub fn emitOrbitTryRecv(self: *IRBuilder, handle_chan: u16, inner_type: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const out = try self.channels.allocNullable(inner_type);
        try self.emit(Node.makeUnary(.orbit_chan_try_recv, out, 0, handle_chan));
        return out;
    }

    // ════════════════════════════════════════════
    // 辅助函数
    // ════════════════════════════════════════════

    pub fn addString(self: *IRBuilder, s: []const u8) usize {
        const idx = self.string_pool.items.len;
        self.string_pool.append(self.arena.allocator(), s) catch {};
        return idx;
    }

    // ── field_id 映射辅助 ──

    /// 构造 field_id_map 的 key："type_name\x00field_name"
    /// 用 NUL 分隔避免歧义（标识符不含 NUL）
    /// key 从 arena 分配以持久化（StringHashMap 存储 key 切片引用）
    pub fn makeFieldKey(self: *IRBuilder, type_name: []const u8, field_name: []const u8) ![]u8 {
        const arena_alloc = self.arena.allocator();
        const key = try arena_alloc.alloc(u8, type_name.len + 1 + field_name.len);
        @memcpy(key[0..type_name.len], type_name);
        key[type_name.len] = 0;
        @memcpy(key[type_name.len + 1 ..], field_name);
        return key;
    }

    /// 注册 field_id 映射（已存在则覆盖）
    /// 仅用于内置类型（TypeInfo 等）和匿名 record（type_name=""），
    /// 用户自定义类型的 field_id 由 sema_result.field_id_map 提供
    pub fn registerFieldId(self: *IRBuilder, type_name: []const u8, field_name: []const u8, field_id: u16) void {
        const key = self.makeFieldKey(type_name, field_name) catch return;
        self.field_id_map.put(key, field_id) catch return;
    }

    /// 查找 field_id（找不到返回 null）
    /// 优先查 sema_result.field_id_map（用户类型），回退到本地 field_id_map（内置类型/匿名 record）
    pub fn lookupFieldId(self: *IRBuilder, type_name: []const u8, field_name: []const u8) ?u16 {
        // 1. 优先从 sema_result 查询（用户自定义类型）
        {
            const sr = self.sema_result;
            if (sr.lookupFieldId(type_name, field_name)) |id| return id;
        }
        // 2. 回退到本地 field_id_map（内置类型 TypeInfo/LayoutInfo 等 + 匿名 record）
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

    /// 构造 record_make 的 meta：编码 (field_ref_bits << 64) | (field_count << 32) | type_name_pool_idx
    /// field_ref_bits 第 i 位为 1 表示第 i 个字段类型为 &T / *T。
    pub fn addRecordMakeMeta(self: *IRBuilder, type_name: []const u8, field_count: u32, field_ref_bits: u64) !u16 {
        const type_name_idx = self.addString(type_name);
        const packed_val: u128 = (@as(u128, field_ref_bits) << 64) | (@as(u128, field_count) << 32) | @as(u128, @intCast(type_name_idx));
        return try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, @bitCast(packed_val)) },
        });
    }

    /// 构造 record_get/set 的 field_id meta
    pub fn addFieldIdMeta(self: *IRBuilder, field_id: u16) !u16 {
        return try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, field_id) },
        });
    }

    // ════════════════════════════════════════════
    // 向量编译（Phase 2）
    // ════════════════════════════════════════════

    /// 编译 iterable 表达式为 vec_source 节点
    pub const compileVecSource = @import("expr_compiler.zig").Methods.compileVecSource;

    /// 发射 array_source vec_source 节点
    /// inputs[0] = arr_chan（ref_chan 指向 ArrayValue）
    /// elem_type 为编译期推断的元素通道类型（无法精确推断时回退 i64_chan）
    pub const emitArraySource = @import("expr_compiler.zig").Methods.emitArraySource;

    /// 从数组字面量推断元素通道类型
    /// 仅根据第一个元素的 AST 节点粗略推断，无法精确推断时回退 i64_chan
    pub const inferArrayLiteralElemType = sema.inference.inferArrayLiteralElemType;

    /// 从数组表达式推断元素通道类型
    /// 支持 method_call（如 s.bytes() → u8_chan）、identifier（从 var 类型推断）、array_literal
    /// v3 阶段 3：委托到 sema.inference.inferArrayElemType
    pub fn inferArrayElemType(self: *IRBuilder, expr: *const ast.Expr) *const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return sema.inference.inferArrayLiteralElemType(expr, self.sema_result);
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferArrayElemType(&ext, expr);
    }

    /// 推断 newtype/record 字段的数组元素类型（如 self.segments → str[] 的元素类型 str）
    /// v3 阶段 3：委托到 sema.inference.inferFieldArrayElemType
    pub fn inferFieldArrayElemType(self: *IRBuilder, object: *const ast.Expr, field: []const u8) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferFieldArrayElemType(&ext, object, field);
    }

    /// 从通道查找编译期常量值
    pub const findConstVal = @import("expr_compiler.zig").Methods.findConstVal;

    /// 编译归约表达式（vec_fold）
    /// 用于 sum(range) / max(range) / min(range) 等场景
    pub const compileFold = @import("expr_compiler.zig").Methods.compileFold;

    /// 编译前缀计算（vec_scan）
    /// 用于递归线性化：fib(n) → scan(step, (0,1)) |> take(n) |> last
    pub const compileScan = @import("expr_compiler.zig").Methods.compileScan;

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
    pub const compilePropagate = @import("expr_compiler.zig").Methods.compilePropagate;

    /// 编译 non_null_assert (expr!)：断言 nullable 非 null，提取内部值
    /// 等价于 nullable_unwrap，null 时 panic
    pub const compileNonNullAssert = @import("expr_compiler.zig").Methods.compileNonNullAssert;

    /// 编译 safe_access (obj?.field)：null 时返回 null，否则访问字段
    pub const compileSafeAccess = @import("expr_compiler.zig").Methods.compileSafeAccess;

    /// 在已有通道上编译字段访问（复用 record_get 逻辑）
    pub const compileFieldAccessOnChan = @import("expr_compiler.zig").Methods.compileFieldAccessOnChan;

    /// 从 TypeNode 提取简单类型名（不构造泛型字符串）。
    /// 用于参数/字段的类型标注 → 类型名映射（dispatchMethodCall 用）。
    /// .named → n.name；.generic → g.name（去掉泛型参数）；
    /// .nullable → 递归 inner；.self_type → "Self"；其他返回 null。
    pub const typeNameFromTypeNodeSimple = @import("expr_compiler.zig").Methods.typeNameFromTypeNodeSimple;

    /// 从表达式推断类型名（用于用户自定义方法调用 obj.method()）
    /// 仅查 sema_result：若 sema 记录了表达式的 type_name，直接返回。
    /// v3 阶段 3：委托到 sema.inference.inferTypeNameFromExprComplete
    pub fn inferTypeNameFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        // trait default 方法中的 self 参数：类型为 current_self_type_name（实现 trait 的类型）
        // trait 方法声明的 self 无类型标注，需在此补全以支持 self.method() 分派
        if (expr.* == .identifier and self.current_self_type_name != null) {
            if (std.mem.eql(u8, expr.identifier.name, "self")) {
                return self.current_self_type_name;
            }
        }
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferTypeNameFromExprComplete(&ext, expr);
    }

    /// 从表达式推断 Trait 类型名（用于一等 Trait 值的方法分派）
    /// 通过变量绑定的类型标注查找 sema_result 中的 trait 定义
    /// v3 阶段 3：委托到 sema.inference.inferTraitNameFromExprComplete
    pub fn inferTraitNameFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        var ctx = self.inferContext() orelse return null;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferTraitNameFromExprComplete(&ext, expr);
    }

    /// 判断表达式是否为字符串类型（直接字面量或绑定了字符串字面量的变量）
    pub const isStringExpr = @import("expr_compiler.zig").Methods.isStringExpr;

    /// 检查表达式是否为字符串（通过变量绑定的类型标注推断）
    /// 用于处理函数参数带 str 类型标注的情况
    pub const isStringParam = @import("expr_compiler.zig").Methods.isStringParam;

    /// 编译 Reflect 方法调用：r.field_value(i) / r.field_name(i) / r.deref() / ...
    /// obj_chan 是 reflect(x) 返回的 Reflect RecordValue 通道
    /// 根据 method 名生成对应 IR 节点
    pub const compileReflectMethod = @import("expr_compiler.zig").Methods.compileReflectMethod;

    /// 从常量表达式解析 usize 索引（用于 Reflect 方法参数）
    pub const resolveConstIndex = @import("expr_compiler.zig").Methods.resolveConstIndex;

    /// 编译方法调用：obj.method(args)
    /// safe=true 时为 obj?.method(args)，先做 null 检查
    pub const compileMethodCall = @import("expr_compiler.zig").Methods.compileMethodCall;

    /// 安全方法调用：obj?.method(args)
    /// obj 为 null 时返回 null，否则调用方法
    pub const compileSafeMethodCall = @import("expr_compiler.zig").Methods.compileSafeMethodCall;

    /// 模块引用：完整模块路径（如 "Store.Memory"、"std.time.Calendar"）
    /// 由 isModuleReference 递归收集多层 field_access 拼接得到
    pub const ModuleRef = struct {
        full_path: []const u8,
    };

    /// 检查表达式是否为模块引用，递归收集多层 field_access 路径
    /// 支持：
    ///   - identifier(已导入模块名)                          → "Module"
    ///   - field_access(模块引用, sub)                        → "Module.Sub"
    ///   - field_access(field_access(模块引用, a), b)          → "Module.a.b"
    ///   - 任意深度嵌套（如 std.time.Calendar）                → "std.time.Calendar"
    /// safe_access 不进入模块路径（保持 `foo?.bar` 的常规语义）
    pub const isModuleReference = @import("expr_compiler.zig").Methods.isModuleReference;

    /// 按方法名分派：用户自定义方法优先，其次内置方法
    pub const dispatchMethodCall = @import("expr_compiler.zig").Methods.dispatchMethodCall;

    /// 在 func_table 中后缀扫描方法：查找以 ".{type_name}.{method}" 结尾的键。
    /// 用于 stdlib：func_table 存的是 mangled name（如 "std.time.DateTime.to_components"），
    /// 当对象类型只能推断出短名（如 "DateTime"）时，通过后缀匹配定位 mangled 函数。
    /// 若后缀匹配失败，回退到参数类型匹配：扫描所有函数，检查函数名以 ".{method}" 结尾
    /// 且第一个参数的类型名与 type_name 一致（处理类型名与模块名不同的情况，
    /// 如 BufReader 类型定义在 std.io.Buffered 模块中）。
    /// 返回 func_idx 或 null（未找到）。
    pub const lookupMethodBySuffix = @import("expr_compiler.zig").Methods.lookupMethodBySuffix;

    /// 发射用户自定义方法调用节点：call("Type.method", [obj, ...args])
    /// 已知 func_idx 时构造 call node，obj_chan 作为第一个参数。
    pub const emitUserMethodCall = @import("expr_compiler.zig").Methods.emitUserMethodCall;

    /// 收集表达式中的自由变量（不在 param_names 中的标识符）
    pub const collectFreeVars = @import("expr_compiler.zig").Methods.collectFreeVars;

    pub const collectFreeVarsStmt = @import("expr_compiler.zig").Methods.collectFreeVarsStmt;

    /// 编译 lambda 表达式为匿名函数 + closure_make 节点
    /// 1. 收集自由变量（捕获上值）
    /// 2. 注册匿名函数（params = lambda参数 + 上值参数）
    /// 3. 编译函数体
    /// 4. 发射 closure_make 节点（携带上值通道）
    pub const compileLambda = @import("expr_compiler.zig").Methods.compileLambda;

    // ════════════════════════════════════════════
    // 线性递归识别与编译（v3 阶段 4：方法体已物理拆分到 func_compiler.zig）
    // ════════════════════════════════════════════

    /// 检测线性递归模式
    pub const tryDetectLinearRecurrence = @import("func_compiler.zig").Methods.tryDetectLinearRecurrence;
    /// 检查 expr 是否为 f(param - offset) 形式的自递归调用
    pub const isSelfCallWithOffset = @import("func_compiler.zig").Methods.isSelfCallWithOffset;
    /// 编译线性递归为迭代 scalar_loop
    pub const compileLinearRecurrenceCall = @import("func_compiler.zig").Methods.compileLinearRecurrenceCall;

    /// 发射整数常量到指定类型通道
    pub fn emitConstInt(self: *IRBuilder, value: i64, type_desc: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const int_kind = type_desc.toIntKind() orelse .i64;
        const out = try self.allocChannel(type_desc);
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
    pub const compileCallIndirect = @import("expr_compiler.zig").Methods.compileCallIndirect;

    /// 编译 atomic 表达式：atomic value → AtomicValue 堆对象（ref_chan 指针）
    /// 跨线程共享，所有操作通过 mutex 保护
    pub const compileAtomicExpr = @import("expr_compiler.zig").Methods.compileAtomicExpr;

    /// 编译 lazy 表达式：lazy expr → LazyValue（包装无参 thunk 闭包）
    /// thunk 捕获 lazy 表达式所在作用域的自由变量，body 直接返回 expr 的值。
    pub const compileLazyExpr = @import("expr_compiler.zig").Methods.compileLazyExpr;

    /// 编译 inline_trait_value：trait { methods } → record of closures
    /// 每个方法编译为闭包，存储在 record 字段中
    pub const compileInlineTraitValue = @import("expr_compiler.zig").Methods.compileInlineTraitValue;

    /// 编译模块引用为 trait 值：Module.Sub → record of closures
    /// 按 trait 方法顺序，为每个方法创建闭包包装对应的模块函数
    /// 支持任意深度路径：std.time.Calendar → 为 "std.time.Calendar.<method>" 创建包装器
    pub const compileModuleTraitValue = @import("expr_compiler.zig").Methods.compileModuleTraitValue;

    /// 编译 Elvis 操作符 (left ?? right)：left 非 null 取 left，否则取 right
    /// 等价于 nullable_unwrap_or
    pub const compileElvis = @import("expr_compiler.zig").Methods.compileElvis;

    /// 判断表达式是否直接产生 ThrowValue（无需再包装）
    /// Ok(...) / Error(...) 内建构造器产生 ThrowValue；throw 语句本身是 halt 不返回值
    /// 调用返回 Throw 的函数/lambda 也产生 ThrowValue
    pub const exprIsThrowValue = @import("expr_compiler.zig").Methods.exprIsThrowValue;

    /// 解析 type alias 后再推导通道类型
    /// 委托 sema type_resolver.resolveTypeNodeResolved，传入 current_type_args + sema_result
    pub const chanTypeFromTypeNodeResolved = @import("expr_compiler.zig").Methods.chanTypeFromTypeNodeResolved;

    /// 单态化：带类型绑定的 TypeNode → TypeDescriptor 解析
    /// 委托 sema type_resolver.chanTypeFromTypeNodeBound，传入 current_type_args
    pub const chanTypeFromTypeNodeBound = @import("expr_compiler.zig").Methods.chanTypeFromTypeNodeBound;

    /// field_value 标量单态化：从 current_type_args 解析 T 的标量 inner 类型
    pub const resolveFieldValueChanType = @import("expr_compiler.zig").Methods.resolveFieldValueChanType;

    /// 单态化：type_id → TypeDescriptor
    /// 委托 sema type_resolver.chanTypeFromTypeId，查 sema_result.type_descriptors
    pub const chanTypeFromTypeId = @import("expr_compiler.zig").Methods.chanTypeFromTypeId;

    /// 单态化：TypeDescriptor → type_id（反查 type_name_to_id）
    /// 用于从实参的 type_desc 直接推导 type_id，处理 int_literal 等无 type_name 的表达式
    pub const chanTypeToTypeId = @import("expr_compiler.zig").Methods.chanTypeToTypeId;

    /// 单态化：从 field_access 表达式推导 type_id
    /// 对于泛型记录的字段访问（如 p1.first where p1: Pair<i32, str>），
    /// sema 不记录 ExprInfo（类型变量无法转 TypeDescriptor），需手动解析：
    /// 1. 从对象表达式推导基类型名 + 类型实参
    /// 2. 查类型定义获取字段的声明类型
    /// 3. 若字段类型是类型参数，用类型实参替换
    /// v3 阶段 3：委托到 sema.inference.inferFieldAccessTypeId
    pub fn inferFieldAccessTypeId(self: *IRBuilder, fa: anytype) u16 {
        var ctx = self.inferContext() orelse return 0;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferFieldAccessTypeId(&ext, fa);
    }

    /// 单态化：从实参表达式推导 type_id
    /// 优先用 inferTypeNameFromExpr → lookupTypeId（处理 ADT/构造器），
    /// 失败时从 sema ExprInfo.type_desc 直接反查（处理 int_literal 等原始类型）
    /// v3 阶段 3：委托到 sema.inference.inferTypeIdFromExpr
    pub fn inferTypeIdFromExpr(self: *IRBuilder, expr: *const ast.Expr) u16 {
        var ctx = self.inferContext() orelse return 0;
        var ext = self.inferContextExt(&ctx);
        return sema.inference.inferTypeIdFromExpr(&ext, expr);
    }

    /// 单态化核心：实例化泛型函数，返回特化函数索引
    ///
    /// 对每个 (func_name, type_args) 组合生成一份特化代码：
    /// 1. 查缓存命中 → 直接返回
    /// 2. 查进行中（递归）→ 返回预占索引
    /// 3. 查找函数 AST，预占 Function 索引
    /// 4. push type binding（type_param 名 → 具体 TypeDescriptor + type_id）
    /// 5. 预分配占位 Function（return channel 用 bound 版本解析）
    /// 6. 调用 compileFunction 编译函数体（chanTypeFromTypeNodeBound 查绑定栈）
    /// 7. pop type binding，写入缓存
    ///
    /// 非泛型函数（type_params.len == 0）直接返回原 func_table 索引，不做单态化。
    pub const instantiateFunction = @import("func_compiler.zig").Methods.instantiateFunction;
    pub const processDeferredInstantiations = @import("func_compiler.zig").Methods.processDeferredInstantiations;
};

// ════════════════════════════════════════════════════════════════
// 类型推导辅助函数（v3 阶段 4：已物理拆分到 ast_traits.zig）
// ════════════════════════════════════════════════════════════════

pub const stmt_compoundAssignOpToBinaryOp = @import("stmt_compiler.zig").Methods.compoundAssignOpToBinaryOp;

pub const filterDigits = @import("ast_traits.zig").filterDigits;
pub const unwrapBlockExpr = @import("ast_traits.zig").unwrapBlockExpr;
pub const intKindFromSuffix = @import("ast_traits.zig").intKindFromSuffix;
pub const floatKindFromSuffix = @import("ast_traits.zig").floatKindFromSuffix;
pub const binaryOpToNodeOp = @import("ast_traits.zig").binaryOpToNodeOp;
pub const unaryOpToNodeOp = @import("ast_traits.zig").unaryOpToNodeOp;
pub const binaryResultType = @import("ast_traits.zig").binaryResultType;
pub const binOpToNodeOp = @import("ast_traits.zig").binOpToNodeOp;
pub const isThrowType = @import("ast_traits.zig").isThrowType;
pub const unwrapAsyncType = @import("ast_traits.zig").unwrapAsyncType;
pub const asyncInnerTypeNode = @import("ast_traits.zig").asyncInnerTypeNode;
pub const throwOkTypeNode = @import("ast_traits.zig").throwOkTypeNode;
pub const throwOkChanType = @import("ast_traits.zig").throwOkChanType;
pub const throwOkTypeName = @import("ast_traits.zig").throwOkTypeName;
pub const typeNameFromTypeNodeConst = @import("ast_traits.zig").typeNameFromTypeNodeConst;
pub const isStringTypeNode = @import("ast_traits.zig").isStringTypeNode;
pub const isNullableTypeNode = @import("ast_traits.zig").isNullableTypeNode;
pub const typeNameFromTypeNode = @import("ast_traits.zig").typeNameFromTypeNode;
pub const primitiveLayout = @import("ast_traits.zig").primitiveLayout;
pub const alignUp = @import("ast_traits.zig").alignUp;
pub const retKindToChanType = @import("ast_traits.zig").retKindToChanType;
pub const chanTypeFromTypeNode = @import("ast_traits.zig").chanTypeFromTypeNode;
pub const chanTypeFromExprAst = sema.inference.chanTypeFromExprAst;
pub const allocChanFromTypeNode = @import("ast_traits.zig").allocChanFromTypeNode;
pub const astContainsBreakOrContinueExpr = @import("ast_traits.zig").astContainsBreakOrContinueExpr;
pub const astContainsBreakOrContinueStmt = @import("ast_traits.zig").astContainsBreakOrContinueStmt;
pub const AccumulatorPattern = @import("ast_traits.zig").AccumulatorPattern;
pub const extractAccumulatorPattern = @import("ast_traits.zig").extractAccumulatorPattern;
pub const BreakContinueCond = @import("ast_traits.zig").BreakContinueCond;
pub const tryExtractBreakContinueCond = @import("ast_traits.zig").tryExtractBreakContinueCond;
pub const astContainsExternalAssignExpr = @import("ast_traits.zig").astContainsExternalAssignExpr;
pub const astContainsExternalAssignStmt = @import("ast_traits.zig").astContainsExternalAssignStmt;
