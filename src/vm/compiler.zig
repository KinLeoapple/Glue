//! Glue 字节码 VM — 编译器（M1a：模块级 AST → Program）
//!
//! 设计见 docs/bytecode-vm-plan.md §5。M1a 覆盖：
//! - 模块编译：两遍——先给每个顶层 fun_decl 分配 func_idx 建函数表，再逐个编译函数体。
//! - 表达式：字面量 / 一元 / 二元（含 && || 短路）/ if / block / 顶层具名函数调用。
//! - 语句：val/var/赋值 / while / return / 表达式语句。
//! - 标识符解析：先查 local（参数 + 块内 val/var，slot 数组）；否则报 Unsupported
//!   （顶层函数名仅在 call 的 callee 位置识别，不作一等函数值——留 M1c）。
//!
//! 自包含：local 按**名字字符串**编译期解析（不依赖 resolve 预pass 的 name_id），
//! 顶层函数按名字查函数表。闭包 / 一等函数值 / match / 复合值 / break-continue 留 M1+。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const opcode = @import("opcode.zig");
const chunk_mod = @import("chunk.zig");
const analysis_db_mod = @import("analysis_db");

/// 公开再导出，供 bench 驱动 / 外部入口通过本模块拿到 VM 与 Program（避免新建 build 图模块）。
pub const VM = @import("vm.zig").VM;
pub const chunk = chunk_mod;
pub const lexer = @import("lexer");
pub const parser = @import("parser");

const OpCode = opcode.OpCode;
const Chunk = chunk_mod.Chunk;
const Function = chunk_mod.Function;
pub const Program = chunk_mod.Program;
const Value = value.Value;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Pattern = ast.Pattern;

pub const CompileError = error{
    OutOfMemory,
    Unsupported,
};

const Local = struct {
    name: []const u8,
    slot: u16,
    is_var: bool,
    builtin_type: ?[]const u8 = null,
    /// letrec lambda 绑定时存的形参基础类型（borrow AST），供 op_call_value 路径 caller-side coerce。
    /// null 表示非闭包或无注解；元素 null 表示该参数无注解。
    closure_param_types: ?[]const ?[]const u8 = null,
};

/// 闭包 upvalue 描述符（clox 风格静态解析）。
/// is_local=true：捕获 enclosing 帧的 local[index]；false：捕获 enclosing 闭包的 upvalue[index]。
const Upvalue = struct {
    name: []const u8,
    index: u16,
    is_local: bool,
    /// letrec lambda 绑定时存的形参基础类型（borrow AST），供 op_call_value 路径 caller-side coerce。
    closure_param_types: ?[]const ?[]const u8 = null,
};

/// 循环上下文（M3b）：break/continue 跳转回填。
/// continue_target：continue 回跳的绝对地址（while=条件起点，loop=体起点）。
/// breaks：本循环内所有 break 的 OP_JUMP 占位待回填到循环末尾。
const LoopCtx = struct {
    continue_target: usize,
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    /// 进入循环时的 defer 作用域深度。break/continue 须重放循环体内（深度 ≥ 此值）的 defer。
    defer_depth: usize = 0,
    /// 【LICM】本循环 hoist 的表达式指针列表。退出循环时据此清理 hoisted_slots，
    /// 防止循环外引用同名表达式时读到循环前的缓存值（其中变量可能已被修改）。
    hoisted_exprs: std.ArrayListUnmanaged(*const ast.Expr) = .empty,
};

/// 顶层函数名 → func_idx 映射（编译期识别 call 的 callee）。arity 用于尾调用合格性判定。
const FnEntry = struct {
    name: []const u8,
    idx: u16,
    arity: u16,
    param_types: []const ?[]const u8 = &.{},
    /// 【JIT Phase 3】该纯函数的 memoization slot。
    /// 0xFFFF = 未分配（非纯函数或尚未调用）；纯函数首次被调用时懒分配，所有调用点共享。
    memo_slot: u16 = 0xFFFF,
    /// 【内联】函数 body AST（borrow），null = 不可内联（lambda/递归/过大）。
    /// 仅顶层 fun_decl 可内联；canInline 在注册时判断（arity ≤ 4 + 节点数 ≤ 32 + 无 nested lambda）。
    body: ?*const ast.Expr = null,
    /// 【内联】形参 AST（borrow），内联展开时绑定参数名到临时 local。
    params: []const ast.Param = &.{},
};

/// ADT 构造器名 → (program.adt_ctors 索引, arity)。编译期识别裸名构造器调用 + match 校验。
const CtorEntry = struct {
    name: []const u8,
    idx: u16,
    arity: u8,
};

/// 顶层全局变量登记项（M5g）：name → globals 数组索引 + 可变性（var 可重新赋值，val 不可）。
const GlobalEntry = struct {
    name: []const u8,
    idx: u16,
    is_mutable: bool,
    /// 【P1-7】全局变量的命名类型名（从类型注解提取）。用于 exprBuiltinType 推断，
    /// 使全局变量参与的算术/比较可走类型特化路径（与 local 的 builtin_type 对称）。
    builtin_type: ?[]const u8 = null,
};

/// 模块编译器：消费 ast.Module，产出 Program（持有所有 Function）。
pub const ModuleCompiler = struct {
    program: Program,
    allocator: std.mem.Allocator,
    /// 顶层函数表（两遍编译：先填名字→idx，再编译体）。
    fn_table: std.ArrayListUnmanaged(FnEntry) = .empty,
    /// ADT 构造器表（第一遍登记）。
    ctor_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    /// Newtype 构造器表（第一遍登记）：构造器名 == type_name，arity 恒 1。
    newtype_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    /// 自定义错误类型构造器表（M5e，第一遍登记）：构造器名 == type_name，arity 恒 1（str 消息）。
    error_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    /// 顶层全局变量表（M5g，第一遍登记）：name → globals 数组索引 + 是否可变（var）。
    global_table: std.ArrayListUnmanaged(GlobalEntry) = .empty,
    /// 【优化】符号查找索引：name → fn_table 中的下标。registerDecls 末尾一次性构建。
    fn_map: std.StringHashMap(u16),
    ctor_map: std.StringHashMap(u16),
    newtype_map: std.StringHashMap(u16),
    error_map: std.StringHashMap(u16),
    global_map: std.StringHashMap(u16),
    method_name_set: std.StringHashMap(void),
    /// trait 方法名集合（M5i，第一遍登记）：用于把裸名调用 `compare(a,b)`（with-clause 约束的
    /// trait 方法作自由函数）解析为 receiver=arg0 的 OP_CALL_METHOD 分派。
    method_names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 零参 trait 方法表（M5k）：`zero()` 无 receiver 无法按类型分派，按名字直接解析到 trait 方法函数
    /// （name → func_idx，首个生效）。供 emitCall 的 argc==0 裸名调用。
    nullary_methods: std.ArrayListUnmanaged(struct { name: []const u8, func_idx: u16 }) = .empty,
    /// 模块值表（M5o，文档 §4.6.2）：需构建为运行时模块值（trait_value vtable）的依赖模块。
    /// 仅目录模块（有 pub pack）及其 pub pack 子模块——扁平 stdlib（List/Compare 等）不入，避免与
    /// 类型名抢全局。module_decls 借 deps AST（构造 init 时遍历其 pub fun/pub pack）。global_idx 是
    /// 该模块值在 globals 数组的槽位。
    module_values: std.ArrayListUnmanaged(struct { name: []const u8, global_idx: u16, decls: []const ast.Decl }) = .empty,
    /// 【JIT Phase 2】分析数据库引用（null = 禁用所有优化）。
    analysis_db: ?*const analysis_db_mod.AnalysisDB = null,
    /// 【JIT Phase 3】memoization slot 分配计数器。
    /// 每个发射的 op_call_memoized 调用点分配唯一 slot，VM 用此索引 memo_cache。
    next_memo_slot: u16 = 0,
    /// func_idx → 形参基础类型数组（borrow AST 字节，外层数组 owned）。
    /// 仅存 trait 方法/默认方法的 param_types（顶层函数的 param_types 已在 fn_table 中）。
    /// 供 uniqueTraitMethod / op_call_method 路径 caller-side coerce，修复 i8 字面量传入
    /// 宽类型形参未 coerce 导致的算术溢出（与 op_call_value 路径对称）。
    func_param_types: std.AutoHashMapUnmanaged(u16, []const ?[]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) ModuleCompiler {
        return .{
            .program = Program.init(allocator),
            .allocator = allocator,
            .fn_map = std.StringHashMap(u16).init(allocator),
            .ctor_map = std.StringHashMap(u16).init(allocator),
            .newtype_map = std.StringHashMap(u16).init(allocator),
            .error_map = std.StringHashMap(u16).init(allocator),
            .global_map = std.StringHashMap(u16).init(allocator),
            .method_name_set = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleCompiler) void {
        // 释放 trait 方法 param_types 外层数组（内含字符串借用 AST 不释放）
        var it = self.func_param_types.valueIterator();
        while (it.next()) |pts| self.allocator.free(pts.*);
        self.func_param_types.deinit(self.allocator);
        self.fn_table.deinit(self.allocator);
        self.ctor_table.deinit(self.allocator);
        self.newtype_table.deinit(self.allocator);
        self.error_table.deinit(self.allocator);
        self.global_table.deinit(self.allocator);
        self.method_names.deinit(self.allocator);
        self.nullary_methods.deinit(self.allocator);
        self.module_values.deinit(self.allocator);
        self.fn_map.deinit();
        self.ctor_map.deinit();
        self.newtype_map.deinit();
        self.error_map.deinit();
        self.global_map.deinit();
        self.method_name_set.deinit();
        // program 所有权移交调用方；此处不 deinit。
    }

    pub fn lookupFn(self: *ModuleCompiler, name: []const u8) ?u16 {
        if (self.fn_map.get(name)) |idx| return self.fn_table.items[idx].idx;
        return null;
    }

    /// 查 ADT 构造器登记（裸名构造器调用 / match constructor pattern 用）。
    pub fn lookupCtor(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.ctor_map.get(name)) |idx| return self.ctor_table.items[idx];
        return null;
    }

    /// 查 newtype 构造器登记（裸名 newtype 构造 / match newtype pattern 用）。
    pub fn lookupNewtype(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.newtype_map.get(name)) |idx| return self.newtype_table.items[idx];
        return null;
    }

    /// 查自定义错误类型构造器登记（裸名 ErrorType("msg") 调用用）。
    pub fn lookupError(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.error_map.get(name)) |idx| return self.error_table.items[idx];
        return null;
    }

    /// 查顶层全局变量登记（自由标识符 / 赋值目标解析用）。
    pub fn lookupGlobal(self: *ModuleCompiler, name: []const u8) ?GlobalEntry {
        if (self.global_map.get(name)) |idx| return self.global_table.items[idx];
        return null;
    }

    /// M5i：登记一个 trait 方法名（去重）。
    fn registerMethodName(self: *ModuleCompiler, name: []const u8) CompileError!void {
        if (self.method_name_set.contains(name)) return;
        try self.method_name_set.put(name, {});
        try self.method_names.append(self.allocator, name);
    }

    /// M5i：name 是否为已知 trait 方法名（裸名调用作自由函数 trait 方法分派判定用）。
    pub fn isMethodName(self: *ModuleCompiler, name: []const u8) bool {
        return self.method_name_set.contains(name);
    }

    /// 查顶层函数的 (idx, arity)，供尾调用合格性判定（argc==arity 才发 OP_TAIL_CALL）。
    pub fn lookupFnEntry(self: *ModuleCompiler, name: []const u8) ?FnEntry {
        if (self.fn_map.get(name)) |idx| return self.fn_table.items[idx];
        return null;
    }

    /// 【JIT Phase 2】查询函数是否纯（用于 memoization 决策）
    pub fn isPureFn(self: *const ModuleCompiler, name: []const u8) bool {
        if (self.analysis_db) |db| {
            return db.purity.isPure(name);
        }
        return false;
    }

    /// 【JIT Phase 3】获取或分配纯函数的 memo_slot（per-function，所有调用点共享）。
    /// 返回 null 表示该函数不是纯函数或未注册。
    /// hashValueRecursive 对所有值类型（含 ADT/record/array/newtype）按内容递归 hash，
    /// 引用类型（cell/channel/spawn/atomic 等）在 VM 运行时守卫中跳过 memoization。
    /// 无类型注解的参数也允许——hash 基于运行时 Value，与编译期类型无关。
    pub fn getOrAssignMemoSlot(self: *ModuleCompiler, name: []const u8) ?u16 {
        if (!self.isPureFn(name)) return null;
        for (self.fn_table.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                if (entry.memo_slot == 0xFFFF) {
                    entry.memo_slot = self.next_memo_slot;
                    self.next_memo_slot += 1;
                }
                return entry.memo_slot;
            }
        }
        return null;
    }

    /// 【JIT Phase 5】查询 if_expr 的分支可达性信息。
    /// 返回 always_true/always_false 时编译器可跳过死分支（减少指令数）。
    /// 返回 null 或 runtime 时按常规双分支发射。
    pub fn branchInfo(self: *const ModuleCompiler, if_expr: *const ast.Expr) ?analysis_db_mod.BranchInfo {
        if (self.analysis_db) |db| {
            return db.branch_reach.lookup(if_expr);
        }
        return null;
    }

    /// 【JIT Phase 4】查询循环语句的大小信息（is_small/est_size）。
    /// 用于决定是否展开循环体。
    pub fn loopInfo(self: *const ModuleCompiler, stmt: *const ast.Stmt) ?analysis_db_mod.LoopInfo {
        if (self.analysis_db) |db| {
            return db.loop_invariant.lookup(stmt);
        }
        return null;
    }

    /// 【JIT Phase 4】查询表达式的常量值（从 ConstPropPass 结果）。
    /// 用于循环展开时获取 range 上下界的编译期值。
    pub fn constValue(self: *const ModuleCompiler, expr: *const ast.Expr) ?analysis_db_mod.ConstValue {
        if (self.analysis_db) |db| {
            return db.const_prop.lookup(expr);
        }
        return null;
    }

    /// 【LICM】查询表达式是否是某循环的已登记不变量。返回该循环 stmt 指针。
    /// FnCompiler.emitHoistedInvariants 遍历 hoist_table 找出属于某循环的所有表达式。
    pub fn hoistInfo(self: *const ModuleCompiler, expr: *const ast.Expr) ?*const ast.Stmt {
        if (self.analysis_db) |db| {
            return db.hoist_table.lookup(expr);
        }
        return null;
    }

    /// 编译整个模块。返回的 Program（self.program）持有所有函数；调用方取走。
    pub fn compileModule(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        return self.compileModuleWithDeps(module, &.{});
    }

    /// M5j：编译入口模块 + 其 `use` 依赖模块（已解析 AST，定义先于使用顺序）。依赖的顶层函数/
    /// trait/类型/构造器**合并进同一 Program**（VM 按名字字符串解析，扁平 trait 方法表，天然合并）。
    /// 注册顺序：先依赖后入口（入口可前向引用，但同名时入口的 fn_table 在后——lookupFn 取首个匹配，
    /// 故依赖优先；stdlib 名字不与用户 main 冲突，无歧义）。顶层 val/var 仅入口模块支持（依赖 stdlib
    /// 是纯 trait/fun，无顶层 val/var）。
    pub fn compileModuleWithDeps(self: *ModuleCompiler, module: *const ast.Module, deps: []const ast.Module) CompileError!void {
        // 第一遍：登记所有模块（依赖在前）的顶层函数/构造器/方法名/全局。
        for (deps) |*dep| try self.registerDecls(dep);
        try self.registerDecls(module);
        // M5o：登记模块值全局（文档 §4.6.2）——目录模块（有 pub pack）及其 pub pack 子模块需构建为
        // 运行时模块值（trait_value vtable）。在 global_count 定稿前登记，使模块名标识符解析到全局。
        try self.registerModuleValues(deps);
        self.program.global_count = @intCast(self.global_table.items.len);
        // 第二遍：编译所有模块的函数体 + trait 方法。
        for (deps) |*dep| try self.compileBodies(dep);
        try self.compileBodies(module);
        // M5k：检测同一 (type_name, method_name) 多个 trait 方法 —— 触发 trait 冲突消解/override 语义
        //（文档 §2.7.2），VM 扁平表只取首个 → 语义不符。整体回退树遍历器，避免静默错误输出。
        try self.checkNoConflictingTraitMethods();
        // M5g：仅入口模块的顶层 val/var 进全局初始化（依赖 stdlib 无顶层 val/var）。
        // M5o：模块值构造也在全局初始化函数里（在 main 前运行）。
        if (self.global_table.items.len > 0 or self.module_values.items.len > 0) {
            try self.compileGlobalsInit(module);
        }
        if (self.lookupFn("main")) |m| self.program.entry = m;
    }

    /// M5o：登记需构建模块值的依赖模块（文档 §4.6.2）。判定：模块自身有 pub pack（目录模块如 Store）
    /// 或被某模块 pub pack 指名（子模块如 Memory）。为每个分配 globals 槽，子模块**先于**父模块登记
    /// （槽位更低 → 父模块值构造时可 OP_GET_GLOBAL 引用已建好的子模块值）。扁平 stdlib 不入此表。
    fn registerModuleValues(self: *ModuleCompiler, deps: []const ast.Module) CompileError!void {
        // 收集所有 pub pack 子模块名（被指名者需模块值）。
        var pack_targets = std.ArrayListUnmanaged([]const u8).empty;
        defer pack_targets.deinit(self.allocator);
        for (deps) |dep| {
            for (dep.declarations) |d| {
                if (d == .pack_decl and d.pack_decl.visibility == .public)
                    try pack_targets.append(self.allocator, d.pack_decl.name);
            }
        }
        // 子模块（pack 目标）先登记，父模块（含 pub pack）后登记 —— 保证子模块全局槽位在前。
        for (deps) |dep| {
            if (self.isPackTarget(pack_targets.items, dep.name) and !self.hasModuleValue(dep.name))
                try self.addModuleValue(dep);
        }
        for (deps) |dep| {
            if (self.declaresPubPack(dep) and !self.hasModuleValue(dep.name))
                try self.addModuleValue(dep);
        }
    }

    fn isPackTarget(self: *ModuleCompiler, targets: []const []const u8, name: []const u8) bool {
        _ = self;
        for (targets) |t| if (std.mem.eql(u8, t, name)) return true;
        return false;
    }

    fn declaresPubPack(self: *ModuleCompiler, dep: ast.Module) bool {
        _ = self;
        for (dep.declarations) |d|
            if (d == .pack_decl and d.pack_decl.visibility == .public) return true;
        return false;
    }

    fn hasModuleValue(self: *ModuleCompiler, name: []const u8) bool {
        for (self.module_values.items) |mv| if (std.mem.eql(u8, mv.name, name)) return true;
        return false;
    }

    fn addModuleValue(self: *ModuleCompiler, dep: ast.Module) CompileError!void {
        const idx: u16 = @intCast(self.global_table.items.len);
        // 模块名绑定为不可变全局（限定访问 Module.member 入口）。同名已存在则不重复（首个生效）。
        if (self.lookupGlobal(dep.name) != null) return;
        try self.global_table.append(self.allocator, .{ .name = dep.name, .idx = idx, .is_mutable = false });
        try self.global_map.put(dep.name, idx);
        try self.module_values.append(self.allocator, .{ .name = dep.name, .global_idx = idx, .decls = dep.declarations });
    }

    /// M5k：若任意 (type_name, method_name) 对出现多次（同类型同方法多 trait 实现），说明依赖 trait 组合/
    /// override 冲突消解。M5n：VM 现已实现组合分派——若该 method 被某组合 Trait 用 override/委托消解
    /// （在 trait_resolves 中），则放行（组合分派会在扁平查找前选出正确实现）。否则仍 Unsupported 回退
    /// （扁平表只取首个匹配，与 eval 的 first-match 一致性无保证）。
    fn checkNoConflictingTraitMethods(self: *ModuleCompiler) CompileError!void {
        const items = self.program.trait_methods.items;
        for (items, 0..) |a, i| {
            for (items[i + 1 ..]) |b| {
                // 修复：检查应该包含 trait_name，只有三者都相同时才是真正的冲突
                // 多个 trait 实现时，同一个方法会为每个 trait 注册一次（trait_name 不同）
                if (std.mem.eql(u8, a.method_name, b.method_name) and
                    std.mem.eql(u8, a.type_name, b.type_name) and
                    std.mem.eql(u8, a.trait_name, b.trait_name))
                {
                    if (!self.methodResolvedByComposition(a.method_name)) return error.Unsupported;
                }
            }
        }
    }

    /// M5n：method 是否被某组合 Trait 用 override/委托消解（trait_resolves 含该方法名）。
    fn methodResolvedByComposition(self: *ModuleCompiler, method_name: []const u8) bool {
        for (self.program.trait_resolves.items) |r| {
            if (std.mem.eql(u8, r.method_name, method_name)) return true;
        }
        return false;
    }

    /// 第一遍：登记一个模块的顶层函数（预占 program 槽）/ADT·newtype·error 构造器/全局 val·var/方法名。
    fn registerDecls(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 同名顶层函数已登记（如依赖与入口重名）→ 跳过重复预占（首个生效）。
                    if (self.fn_map.contains(fd.name)) continue;
                    const idx: u16 = @intCast(self.fn_table.items.len);
                    const param_types = try extractParamTypes(self.allocator, fd.params);
                    // 【内联】判断可内联性：arity ≤ 4 + body 节点数 ≤ 32 + 无 nested lambda/spawn + 非递归
                    const can_inline = canInlineFn(fd.name, fd.params.len, fd.body);
                    try self.fn_table.append(self.allocator, .{
                        .name = fd.name,
                        .idx = idx,
                        .arity = @intCast(fd.params.len),
                        .param_types = param_types,
                        .body = if (can_inline) fd.body else null,
                        .params = if (can_inline) fd.params else &.{},
                    });
                    try self.fn_map.put(fd.name, idx);
                    _ = try self.program.addFunction(.{ .chunk = Chunk.init(self.allocator), .arity = 0, .slot_count = 0, .name = fd.name });
                },
                .type_decl => |td| {
                    switch (td.def) {
                        .adt => |a| {
                            for (a.constructors) |con| {
                                var fnames = try self.allocator.alloc(?[]const u8, con.fields.len);
                                defer self.allocator.free(fnames);
                                var ftypes = try self.allocator.alloc(?[]const u8, con.fields.len);
                                defer self.allocator.free(ftypes);
                                for (con.fields, 0..) |f, i| {
                                    fnames[i] = f.name;
                                    ftypes[i] = builtinNumericTypeOf(f.ty);
                                }
                                const cidx = try self.program.addAdtCtor(td.name, con.name, fnames, ftypes);
                                const local_idx: u16 = @intCast(self.ctor_table.items.len);
                                try self.ctor_table.append(self.allocator, .{ .name = con.name, .idx = cidx, .arity = @intCast(con.fields.len) });
                                try self.ctor_map.put(con.name, local_idx);
                            }
                        },
                        .newtype => |nt| {
                            const ntidx = try self.program.addNewtypeCtor(td.name);
                            const local_idx: u16 = @intCast(self.newtype_table.items.len);
                            try self.newtype_table.append(self.allocator, .{ .name = nt.name, .idx = ntidx, .arity = 1 });
                            try self.newtype_map.put(nt.name, local_idx);
                        },
                        .error_newtype => |en| {
                            // 从 prefix 方法中提取前缀字符串
                            var prefix: []const u8 = td.name;
                            if (en.methods.len > 0) {
                                for (en.methods) |m| {
                                    if (std.mem.eql(u8, m.name, "prefix") and m.body != null) {
                                        // 尝试从方法体中提取字符串字面量
                                        const body = m.body.?;
                                        // 方法体可能是 block { "string" } 或直接是 string_literal
                                        if (body.* == .block and body.block.statements.len == 0 and body.block.trailing_expr != null) {
                                            // { "string" } 形式
                                            const expr = body.block.trailing_expr.?;
                                            if (expr.* == .string_literal) {
                                                prefix = expr.string_literal.value;
                                            }
                                        } else if (body.* == .string_literal) {
                                            // 直接字符串字面量
                                            prefix = body.string_literal.value;
                                        }
                                        break;
                                    }
                                }
                            }
                            const eidx = try self.program.addErrorCtor(td.name, prefix);
                            const local_idx: u16 = @intCast(self.error_table.items.len);
                            try self.error_table.append(self.allocator, .{ .name = td.name, .idx = eidx, .arity = 1 });
                            try self.error_map.put(td.name, local_idx);

                            // 注册 Error trait 的内置方法：message() 和 type_name()
                            try self.registerErrorTraitMethods(td.name);
                        },
                        else => {},
                    }
                },
                .expr_decl => |ed| {
                    if (ed.stmt) |s| {
                        const idx: u16 = @intCast(self.global_table.items.len);
                        switch (s.*) {
                            .val_decl => |vd| {
                                try self.global_table.append(self.allocator, .{ .name = vd.name, .idx = idx, .is_mutable = false, .builtin_type = builtinTypeOf(vd.type_annotation) });
                                try self.global_map.put(vd.name, idx);
                            },
                            .var_decl => |vd| {
                                try self.global_table.append(self.allocator, .{ .name = vd.name, .idx = idx, .is_mutable = true, .builtin_type = builtinTypeOf(vd.type_annotation) });
                                try self.global_map.put(vd.name, idx);
                            },
                            else => {},
                        }
                    }
                },
                .trait_decl => |td| {
                    for (td.methods) |m| try self.registerMethodName(m.name);
                },
                else => {},
            }
        }
    }

    /// 第二遍：编译一个模块的 trait 方法体（先，使裸名/nullary 方法表就绪）+ 函数体。
    fn compileBodies(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        // trait/type 方法先编译：填 nullary_methods 表，使后续 fun 体（含 main）的 `zero()` 裸名可解析。
        for (module.declarations) |decl| {
            switch (decl) {
                .trait_decl => |td| try self.compileTraitDefaults(td),
                .type_decl => |td| try self.compileTypeMethods(td),
                else => {},
            }
        }
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| try self.compileFunction(fd),
                else => {},
            }
        }
    }

    /// M5i：编译 type 声明中所有带 body 的方法体。每个编成顶层 Function（self+params 占
    /// slot 0..），登记进 program.trait_methods（type_name + method_name 分派键）。
    fn compileTypeMethods(self: *ModuleCompiler, td: @TypeOf(@as(ast.Decl, undefined).type_decl)) CompileError!void {
        // 检查是否是 error_newtype 并且有方法
        if (td.def == .error_newtype and td.def.error_newtype.methods.len > 0) {
            // 编译 error_newtype 的方法
            for (td.def.error_newtype.methods) |m| {
                const body = m.body orelse continue;
                const func_idx = try self.compileMethodBody(m, body);

                // 为 Error trait 注册此方法
                try self.program.addTraitMethod(td.name, m.name, "Error", func_idx);

                // 零参方法也注册
                if (m.params.len == 0) try self.registerNullaryMethod(m.name, func_idx);
            }
            return;
        }

        if (td.methods.len == 0) return;

        // 为每个实现的 trait 注册方法
        for (td.methods) |m| {
            const body = m.body orelse continue;
            const func_idx = try self.compileMethodBody(m, body);

            // 为每个实现的 trait 注册此方法
            for (td.implemented_traits) |trait_bound| {
                try self.program.addTraitMethod(td.name, m.name, trait_bound.trait_name, func_idx);
            }

            // 如果没有实现任何 trait，也注册方法（作为类型的固有方法）
            if (td.implemented_traits.len == 0) {
                try self.program.addTraitMethod(td.name, m.name, "", func_idx);
            }

            // M5k：零参方法（self 也无）无 receiver，登记按名直接解析（首个生效）。
            if (m.params.len == 0) try self.registerNullaryMethod(m.name, func_idx);
        }
    }

    /// M5k：登记一个零参方法名 → func_idx（首个生效，去重）。
    fn registerNullaryMethod(self: *ModuleCompiler, name: []const u8, func_idx: u16) CompileError!void {
        for (self.nullary_methods.items) |e| if (std.mem.eql(u8, e.name, name)) return;
        try self.nullary_methods.append(self.allocator, .{ .name = name, .func_idx = func_idx });
    }

    /// M5k：查零参方法名 → func_idx。
    pub fn lookupNullaryMethod(self: *ModuleCompiler, name: []const u8) ?u16 {
        for (self.nullary_methods.items) |e| if (std.mem.eql(u8, e.name, name)) return e.func_idx;
        return null;
    }

    /// M5k：若某方法名在 program.trait_methods 中**恰有一个** trait 实现，返回其 func_idx（用于自由函数式
    /// trait 方法调用 `compare(a,b)`——单实现时直接调用，镜像 eval 把 trait 方法注册为环境函数的动态
    /// 类型语义，不受 receiver 类型限制）。多实现（如 stdlib show 覆盖 i64/f64/...）返回 null → 退回
    /// receiver 类型分派。
    pub fn uniqueTraitMethod(self: *ModuleCompiler, name: []const u8) ?u16 {
        var found: ?u16 = null;
        for (self.program.trait_methods.items) |d| {
            if (std.mem.eql(u8, d.method_name, name)) {
                if (found != null) return null; // 多实现 → 不唯一
                found = d.func_idx;
            }
        }
        return found;
    }

    /// 取 trait 方法的形参基础类型数组（borrow AST 字节）。
    /// 同一 trait 方法名的所有实现应共享相同形参签名（trait 声明约束），
    /// 故取首个匹配实现即可。供 op_call_method 路径 caller-side coerce。
    /// 查找顺序：trait_methods → trait_defaults。
    pub fn traitMethodParamTypes(self: *ModuleCompiler, method_name: []const u8) ?[]const ?[]const u8 {
        for (self.program.trait_methods.items) |d| {
            if (std.mem.eql(u8, d.method_name, method_name)) {
                if (self.func_param_types.get(d.func_idx)) |pt| return pt;
            }
        }
        for (self.program.trait_defaults.items) |d| {
            if (std.mem.eql(u8, d.method_name, method_name)) {
                if (self.func_param_types.get(d.func_idx)) |pt| return pt;
            }
        }
        return null;
    }

    /// 为 Error 类型注册内置方法：message() 和 type_name()
    /// 这些方法作为 Error trait 的一部分，由 VM 在运行时提供实现
    fn registerErrorTraitMethods(self: *ModuleCompiler, type_name: []const u8) CompileError!void {
        _ = type_name;
        // 注册 message() 方法
        try self.registerMethodName("message");

        // 注册 type_name() 方法
        try self.registerMethodName("type_name");

        // 注意：这些方法不需要 func_idx，因为它们由 VM 的 OP_CALL_METHOD 特殊处理
        // VM 会检查是否是 Error 类型的 message/type_name 调用，并直接返回对应的字段值
    }

    /// M5i：编译 trait 块中带默认 body 的方法，登记进 program.trait_defaults（类型未覆写时回退）。
    /// M5n：组合 Trait（有 parents）的冲突消解——override 方法体编译后登记 trait_resolves（override_func），
    /// 委托方法登记 trait_resolves（delegate_trait/method），父关系登记 trait_parents，trait 名入 trait_order。
    /// override/委托方法**不**进 trait_defaults（它们经组合分派触发，非普通默认回退）。
    fn compileTraitDefaults(self: *ModuleCompiler, td: @TypeOf(@as(ast.Decl, undefined).trait_decl)) CompileError!void {
        const is_composed = td.parents.len > 0;
        if (is_composed) {
            try self.program.addTraitOrder(td.name);
            for (td.parents) |parent| try self.program.addTraitParent(td.name, parent.trait_name);
        }
        for (td.methods) |m| {
            // 委托方法：fun to_string(self): str = Serializable.to_string（无 body）。
            if (m.delegate) |del| {
                if (is_composed) try self.program.addTraitResolve(.{
                    .trait_name = td.name,
                    .method_name = m.name,
                    .delegate_trait = del.trait_name,
                    .delegate_method = del.method_name,
                });
                continue;
            }
            const body = m.body orelse continue;
            const func_idx = try self.compileMethodBody(m, body);
            if (is_composed and m.is_override) {
                // override 方法：组合分派调用其体，覆盖父 Trait 实现。不进普通默认表。
                try self.program.addTraitResolve(.{
                    .trait_name = td.name,
                    .method_name = m.name,
                    .override_func = func_idx,
                });
            } else {
                // 普通默认方法（含非组合 Trait 的默认体）：类型未覆写时回退。
                try self.program.addTraitDefault(td.name, m.name, func_idx);
            }
        }
    }

    /// M5k：把一个方法（self+params）编成顶层零捕获 Function，返回 func_idx。
    /// 顶层 trait 方法不在词法闭包内，故 enclosing=null（自由变量解析为顶层函数/全局/构造器）。
    fn compileMethodBody(self: *ModuleCompiler, m: ast.MethodDecl, body: *ast.Expr) CompileError!u16 {
        if (m.params.len > 255) return error.Unsupported;
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();

        for (m.params) |p| {
            _ = try fc.declareLocal(p.name, p.is_var, typeNeedsRelease(p.type_annotation), builtinTypeOf(p.type_annotation));
        }

        try fc.emitTail(body);
        const f = Function{
            .chunk = fc.chunk,
            .arity = @intCast(m.params.len),
            .slot_count = fc.slot_count,
            .release_mask = fc.release_mask,
            .name = m.name,
        };
        fc.chunk = Chunk.init(self.allocator);
        const func_idx = try self.program.addFunction(f);
        // 存形参类型，供 uniqueTraitMethod / op_call_method 路径 caller-side coerce
        // （修复 i8 字面量传入宽类型形参未 coerce 导致的算术溢出，与 op_call_value 路径对称）
        const param_types = try extractParamTypes(self.allocator, m.params);
        try self.func_param_types.put(self.allocator, func_idx, param_types);
        return func_idx;
    }

    /// M5k：合成一个 arity 参的「构造器包装」Function：取各参数 slot 压栈 + OP_MAKE_ADT + RETURN。
    /// 供有参构造器作一等值（`val mk = Circle`；mk(5.0) 即 Circle(5.0)）。返回 func_idx。
    fn ctorWrapperFunc(self: *ModuleCompiler, ctor_idx: u16, arity: u8, name: []const u8, loc: ast.SourceLocation) CompileError!u16 {
        // 【缓存】预占位拿 func_idx
        const placeholder = Function{
            .chunk = Chunk.init(self.allocator),
            .arity = arity,
            .slot_count = 0,
            .name = name,
        };
        const placeholder_idx = try self.program.addFunction(placeholder);
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        var i: u8 = 0;
        while (i < arity) : (i += 1) {
            fc.slot_count = @max(fc.slot_count, @as(u16, i) + 1);
            try fc.emitSlotOp(.op_get_local, i, loc);
        }
        try fc.chunk.writeOp(.op_make_adt, loc);
        try fc.chunk.writeU16(ctor_idx);
        try fc.chunk.writeByte(arity);
        try fc.chunk.writeOp(.op_return, loc);
        const f = Function{
            .chunk = fc.chunk,
            .arity = arity,
            .slot_count = fc.slot_count,
            .release_mask = fc.release_mask,
            .name = name,
        };
        fc.chunk = Chunk.init(self.allocator);
        self.program.functions.items[placeholder_idx].deinit();
        self.program.functions.items[placeholder_idx] = f;
        return placeholder_idx;
    }
    /// 但不支持引用尚未初始化的后续全局——镜像 eval 的顺序求值语义）。
    fn compileGlobalsInit(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        // 【缓存】预占位拿 func_idx（globals_init 在 functions 列表中的 idx）
        const placeholder = Function{
            .chunk = Chunk.init(self.allocator),
            .arity = 0,
            .slot_count = 0,
            .name = "<globals_init>",
        };
        const placeholder_idx = try self.program.addFunction(placeholder);
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        // M5o：先构建模块值（文档 §4.6.2）——按登记顺序（子模块先于父模块），每个建 trait_value
        // vtable 写入其全局槽。父模块值的 pub pack 成员 OP_GET_GLOBAL 引用已建好的子模块值。
        for (self.module_values.items) |mv| {
            try self.emitModuleValue(&fc, mv.decls, mv.global_idx);
        }
        for (module.declarations) |decl| {
            if (decl != .expr_decl) continue;
            const ed = decl.expr_decl;
            const s = ed.stmt orelse continue;
            const gv: struct { name: []const u8, value: *ast.Expr, ann: ?*ast.TypeNode } = switch (s.*) {
                .val_decl => |vd| .{ .name = vd.name, .value = vd.value, .ann = vd.type_annotation },
                .var_decl => |vd| .{ .name = vd.name, .value = vd.value, .ann = vd.type_annotation },
                else => continue,
            };
            const ge = self.lookupGlobal(gv.name).?;
            try fc.emitExpr(gv.value);
            // 注解隐式定型（i8 字面量 → i32 全局），镜像形参/局部协调。
            try fc.emitCoerceFromAnnotation(gv.ann, gv.value, ed.location);
            try fc.chunk.writeOp(.op_set_global, ed.location);
            try fc.chunk.writeU16(ge.idx);
        }
        try fc.chunk.writeOp(.op_unit, .{ .line = 0, .column = 0 });
        try fc.chunk.writeOp(.op_return, .{ .line = 0, .column = 0 });
        const f = Function{
            .chunk = fc.chunk,
            .arity = 0,
            .slot_count = fc.slot_count,
            .release_mask = fc.release_mask,
            .name = "<globals_init>",
        };
        fc.chunk = Chunk.init(self.allocator);
        self.program.functions.items[placeholder_idx].deinit();
        self.program.functions.items[placeholder_idx] = f;
        self.program.globals_init = placeholder_idx;
    }

    /// M5o：发射一个模块值构造（文档 §4.6.2）。pub fun → [name 常量, OP_CLOSURE func_idx]（零捕获
    /// 顶层函数）；pub pack → [name 常量, OP_GET_GLOBAL 子模块值槽]。末尾 OP_MAKE_TRAIT <count> 建
    /// vtable，OP_SET_GLOBAL 写入模块全局槽。镜像 eval buildAndBindModuleValue。
    fn emitModuleValue(self: *ModuleCompiler, fc: *FnCompiler, decls: []const ast.Decl, global_idx: u16) CompileError!void {
        const loc = ast.SourceLocation{ .line = 0, .column = 0 };
        var count: u16 = 0;
        for (decls) |d| {
            switch (d) {
                .fun_decl => |f| {
                    if (f.visibility != .public) continue;
                    const fn_idx = self.lookupFn(f.name) orelse continue;
                    const name_v = try Value.fromStringBytes(self.allocator, f.name);
                    try fc.emitConst(try fc.chunk.addConstant(name_v), loc);
                    try fc.chunk.writeOp(.op_closure, loc);
                    try fc.chunk.writeU16(fn_idx);
                    try fc.chunk.writeByte(0); // 零捕获（顶层函数）
                    count += 1;
                },
                .pack_decl => |pd| {
                    if (pd.visibility != .public) continue;
                    const sub = self.lookupGlobal(pd.name) orelse continue; // 子模块值全局（已登记）
                    const name_v = try Value.fromStringBytes(self.allocator, pd.name);
                    try fc.emitConst(try fc.chunk.addConstant(name_v), loc);
                    try fc.chunk.writeOp(.op_get_global, loc);
                    try fc.chunk.writeU16(sub.idx);
                    count += 1;
                },
                else => {},
            }
        }
        if (count > 255) return error.Unsupported;
        try fc.chunk.writeOp(.op_make_trait, loc);
        try fc.chunk.writeByte(@intCast(count));
        try fc.chunk.writeOp(.op_set_global, loc);
        try fc.chunk.writeU16(global_idx);
    }

    fn compileFunction(self: *ModuleCompiler, fd: @TypeOf(@as(ast.Decl, undefined).fun_decl)) CompileError!void {
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        // 参数占 slot 0..arity-1。
        for (fd.params) |p| _ = try fc.declareLocal(p.name, p.is_var, typeNeedsRelease(p.type_annotation), builtinTypeOf(p.type_annotation));
        try fc.emitTail(fd.body); // 函数体在尾位置：尾调用→OP_TAIL_CALL，否则 emitExpr+OP_RETURN
        // 移交 chunk 所有权给 Function；fc.deinit 只清 locals。
        const f = Function{
            .chunk = fc.chunk,
            .arity = @intCast(fd.params.len),
            .slot_count = fc.slot_count,
            .release_mask = fc.release_mask,
            .name = fd.name,
        };
        fc.chunk = Chunk.init(self.allocator); // 移走真 chunk 后置空壳：fc.deinit 释放空壳（无分配）
        // 覆盖第一遍预留的占位槽（释放占位空 chunk）。
        const idx = self.lookupFn(fd.name).?;
        self.program.functions.items[idx].deinit();
        self.program.functions.items[idx] = f;
    }
};

/// 【JIT Phase 4】递归检测表达式是否含 break/continue（属于当前循环上下文）。
/// 不深入嵌套 for/while/loop（其 break/continue 属于嵌套循环）和 lambda（独立作用域）。
fn exprHasBreakOrContinue(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (stmtHasBreakOrContinue(s)) return true;
            }
            if (b.trailing_expr) |te| return exprHasBreakOrContinue(te);
            return false;
        },
        .if_expr => |i| {
            if (exprHasBreakOrContinue(i.condition)) return true;
            if (exprHasBreakOrContinue(i.then_branch)) return true;
            if (i.else_branch) |e| return exprHasBreakOrContinue(e);
            return false;
        },
        .binary => |bn| return exprHasBreakOrContinue(bn.left) or exprHasBreakOrContinue(bn.right),
        .unary => |u| return exprHasBreakOrContinue(u.operand),
        .call => |c| {
            if (exprHasBreakOrContinue(c.callee)) return true;
            for (c.arguments) |a| {
                if (exprHasBreakOrContinue(a)) return true;
            }
            return false;
        },
        .match => |m| {
            if (exprHasBreakOrContinue(m.scrutinee)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (exprHasBreakOrContinue(g)) return true;
                if (exprHasBreakOrContinue(arm.body)) return true;
            }
            return false;
        },
        // lambda 体是独立作用域，其中的 break/continue 不属于当前循环
        .lambda => return false,
        else => return false,
    }
}

fn stmtHasBreakOrContinue(stmt: *const ast.Stmt) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return true,
        .val_decl => |v| return exprHasBreakOrContinue(v.value),
        .var_decl => |v| return exprHasBreakOrContinue(v.value),
        .assignment => |a| return exprHasBreakOrContinue(a.value),
        .field_assignment => |fa| return exprHasBreakOrContinue(fa.value),
        .compound_assignment => |ca| return exprHasBreakOrContinue(ca.value),
        .expression => |e| return exprHasBreakOrContinue(e.expr),
        .return_stmt => |r| if (r.value) |v| return exprHasBreakOrContinue(v) else return false,
        .defer_stmt => |d| return exprHasBreakOrContinue(d.expr),
        .throw_stmt => |t| return exprHasBreakOrContinue(t.expr),
        // 嵌套循环：break/continue 属于嵌套循环本身，不属于当前循环
        .for_stmt, .while_stmt, .loop_stmt => return false,
    }
}

/// 【指令融合】递归检测表达式是否无副作用（可安全消除）。
/// 无副作用的表达式：字面量、变量读取、算术、比较、逻辑、字段访问、if（纯分支）、block（纯语句）。
/// 有副作用的表达式：调用（call/method_call）、赋值、throw、spawn、lazy、赋值类二元（concat_list 中的 COW）。
/// 注意：field_access 在 record 上是纯读取（COW 下不修改原值），但 record 本身可能触发 retain。
/// 为安全起见，仅对"值产生"类表达式返回 true，排除所有可能分配/释放/IO/异常的表达式。
fn exprHasNoSideEffects(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal,
        => return true,

        .identifier => return true,

        .unary => |u| return exprHasNoSideEffects(u.operand),

        .binary => |b| {
            // concat_list (++ 数组) 和 range 涉及分配，视为有副作用
            switch (b.op) {
                .concat_list, .range, .range_inclusive => return false,
                .and_op, .or_op, .elvis => {}, // 短路求值，本身无副作用
                else => {},
            }
            return exprHasNoSideEffects(b.left) and exprHasNoSideEffects(b.right);
        },

        .if_expr => |i| {
            if (!exprHasNoSideEffects(i.condition)) return false;
            if (!exprHasNoSideEffects(i.then_branch)) return false;
            if (i.else_branch) |e| if (!exprHasNoSideEffects(e)) return false;
            return true;
        },

        .block => |b| {
            for (b.statements) |s| {
                if (!stmtHasNoSideEffects(s)) return false;
            }
            if (b.trailing_expr) |te| return exprHasNoSideEffects(te);
            return true;
        },

        .field_access => |fa| return exprHasNoSideEffects(fa.object),
        .safe_access => |sa| return exprHasNoSideEffects(sa.object),

        // 有副作用或可能抛异常/分配的表达式
        .call, .method_call, .safe_method_call, .string_interpolation,
        .index, .record_literal, .record_extend, .array_literal,
        .lambda, .match, .select, .spawn, .lazy,
        .assignment_expr, .compound_assign, .propagate, .non_null_assert,
        .atomic_expr, .type_cast, .inline_trait_value,
        => return false,
    }
}

fn stmtHasNoSideEffects(stmt: *const ast.Stmt) bool {
    switch (stmt.*) {
        .expression => |e| return exprHasNoSideEffects(e.expr),
        .val_decl => |v| return exprHasNoSideEffects(v.value),
        .var_decl => |v| return exprHasNoSideEffects(v.value),
        // 赋值/返回/break/continue/throw/defer 都有副作用
        else => return false,
    }
}

/// 单函数编译器：编译一个函数体到一个 Chunk。
const FnCompiler = struct {
    chunk: Chunk,
    allocator: std.mem.Allocator,
    module: *ModuleCompiler,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    slot_count: u16 = 0,
    /// bit i=1 表示 slot i 可能持 boxed 值需 release。declareLocal 时根据类型注解置位。
    release_mask: u64 = 0,
    /// 外层函数编译器（嵌套 lambda 用于 upvalue 解析）；顶层函数为 null。
    enclosing: ?*FnCompiler = null,
    /// 本函数捕获的 upvalue（clox 静态解析；运行时 OP_CLOSURE 据此 box/共享 cell）。
    upvalues: std.ArrayListUnmanaged(Upvalue) = .empty,
    /// 循环上下文栈（break/continue 跳转回填）。嵌套循环 push/pop。
    loops: std.ArrayListUnmanaged(LoopCtx) = .empty,
    /// defer 作用域栈（M3c-defer）：每个含 defer 的 block push 一层，存本层 defer 表达式（按出现顺序）。
    /// block 退出（正常/return/throw）按 LIFO 重放。每层 defer 体内联发射（读当前 slot，见当前局部值）。
    defer_scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*const Expr)) = .empty,
    /// letrec 自递归名字（val f = fun(){...f()...}）：编译 lambda 体时设为 f。
    /// emitCall 遇 callee.name == rec_name → emit OP_CALL_REC（不走 cell + upvalue，断循环引用）。
    /// 值位置引用 rec_name 仍走 upvalue（罕见，退化到原 letrec 路径）。
    rec_name: ?[]const u8 = null,
    /// letrec lambda 在 program.functions 中的索引（先占位再覆盖），供 OP_CALL_REC 使用。
    rec_func_idx: u16 = 0,
    /// 【内联】当前内联展开深度（0 = 非内联上下文）。限制 ≤ 3 防止无限展开。
    inline_depth: u8 = 0,
    /// 【LICM】已 hoist 的表达式 → 临时 slot 映射。循环入口处求值一次并缓存，
    /// 循环体内 emitExpr 命中此表则发 op_get_local 替代重算。
    /// 退出循环时据 LoopCtx.hoisted_exprs 清理本循环的映射。
    hoisted_slots: std.AutoHashMapUnmanaged(*const ast.Expr, u16) = .{},

    fn init(allocator: std.mem.Allocator, module: *ModuleCompiler) FnCompiler {
        var fc = FnCompiler{
            .chunk = Chunk.init(allocator),
            .allocator = allocator,
            .module = module,
        };
        // 【优化】预分配字节码容量，避免典型函数 ~100 字节码的多次 2x 增长 + memcpy
        fc.chunk.code.ensureTotalCapacity(allocator, 128) catch {};
        fc.chunk.lines.ensureTotalCapacity(allocator, 128) catch {};
        return fc;
    }

    /// 发射 slot/idx 立即数指令（writeOp + writeU16）。
    /// slot < 256 时自动选择 u8 窄变体（op_get_local/op_set_local），
    /// 省一字节立即数 + VM 解码省一次移位/或运算。绝大多数函数局部 < 256，命中率极高。
    inline fn emitSlotOp(self: *FnCompiler, op: OpCode, slot: u16, loc: ast.SourceLocation) !void {
        if (slot < 256) {
            switch (op) {
                .op_get_local => {
                    try self.chunk.writeOp(.op_get_local_u8, loc);
                    try self.chunk.writeByte(@intCast(slot));
                    return;
                },
                .op_set_local => {
                    try self.chunk.writeOp(.op_set_local_u8, loc);
                    try self.chunk.writeByte(@intCast(slot));
                    return;
                },
                else => {},
            }
        }
        try self.chunk.writeOp(op, loc);
        try self.chunk.writeU16(slot);
    }

    fn deinit(self: *FnCompiler) void {
        self.locals.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.loops.deinit(self.allocator);
        for (self.defer_scopes.items) |*s| s.deinit(self.allocator);
        self.defer_scopes.deinit(self.allocator);
        self.hoisted_slots.deinit(self.allocator);
        // 拥有 chunk：正常路径下 compileFunction 已把真 chunk 移走并置空 chunk（deinit 释放空壳）；
        // 错误路径（emit 中途 Unsupported/OOM）下释放半成品 chunk，防泄漏。
        self.chunk.deinit();
    }

    fn declareLocal(self: *FnCompiler, name: []const u8, is_var: bool, needs_release: bool, builtin_type: ?[]const u8) CompileError!u16 {
        const slot: u16 = @intCast(self.locals.items.len);
        try self.locals.append(self.allocator, .{ .name = name, .slot = slot, .is_var = is_var, .builtin_type = builtin_type });
        if (self.locals.items.len > self.slot_count) self.slot_count = @intCast(self.locals.items.len);
        if (slot < 64 and needs_release) self.release_mask |= (@as(u64, 1) << @intCast(slot));
        return slot;
    }

    /// 从内向外查 local（同名 shadow 取最近）。找不到返回 null。
    fn resolveLocal(self: *FnCompiler, name: []const u8) ?u16 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i].slot;
        }
        return null;
    }

    /// clox 风格 upvalue 解析：在 enclosing 链中查 name。
    /// - enclosing 有该 local → addUpvalue(is_local=true, slot)。
    /// - 否则递归 enclosing.resolveUpvalue → addUpvalue(is_local=false, 上层 upvalue idx)。
    /// 返回本函数 upvalues 中的索引；无 enclosing 或查不到返回 null。
    fn resolveUpvalue(self: *FnCompiler, name: []const u8) CompileError!?u16 {
        const enc = self.enclosing orelse return null;
        if (enc.resolveLocal(name)) |slot| {
            const cpt = if (slot < enc.locals.items.len) enc.locals.items[slot].closure_param_types else null;
            return try self.addUpvalue(name, slot, true, cpt);
        }
        if (try enc.resolveUpvalue(name)) |uv_idx| {
            const cpt = if (uv_idx < enc.upvalues.items.len) enc.upvalues.items[uv_idx].closure_param_types else null;
            return try self.addUpvalue(name, uv_idx, false, cpt);
        }
        return null;
    }

    /// 登记一个 upvalue（去重）。返回其在 upvalues 列表中的索引。
    fn addUpvalue(self: *FnCompiler, name: []const u8, index: u16, is_local: bool, cpt: ?[]const ?[]const u8) CompileError!u16 {
        for (self.upvalues.items, 0..) |uv, i| {
            if (uv.index == index and uv.is_local == is_local) return @intCast(i);
        }
        if (self.upvalues.items.len >= 255) return error.Unsupported;
        const idx: u16 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{ .name = name, .index = index, .is_local = is_local, .closure_param_types = cpt });
        return idx;
    }

    fn emitExpr(self: *FnCompiler, expr: *const Expr) CompileError!void {
        const loc = ast.exprLocation(expr);
        // 【LICM】如果是已 hoist 的循环不变量，直接读缓存 slot 替代重算
        if (self.hoisted_slots.get(expr)) |slot| {
            try self.emitSlotOp(.op_get_local, slot, loc);
            return;
        }
        switch (expr.*) {
            .int_literal => |lit| {
                const v = try parseIntLiteral(self.allocator, lit) orelse return error.Unsupported;
                try self.emitConst(try self.chunk.addConstant(v), loc);
            },
            .float_literal => |lit| {
                const v = try parseFloatLiteral(self.allocator, lit) orelse return error.Unsupported;
                try self.emitConst(try self.chunk.addConstant(v), loc);
            },
            .bool_literal => |lit| try self.chunk.writeOp(if (lit.value) .op_true else .op_false, loc),
            .null_literal => try self.chunk.writeOp(.op_null, loc),
            .unit_literal => try self.chunk.writeOp(.op_unit, loc),
            // M3a：字符串字面量 → 常量池（dupe owned），OP_CONST。
            .string_literal => |lit| {
                const s = try Value.fromStringBytes(self.allocator, lit.value);
                try self.emitConst(try self.chunk.addConstant(s), loc);
            },
            // M3a：字符字面量 → 常量池，OP_CONST。
            .char_literal => |lit| {
                try self.emitConst(try self.chunk.addConstant(Value.fromChar(value.Char.fromNative(lit.value) catch unreachable)), loc);
            },
            // M3a：字符串插值 → 各段（literal 文本压 string 常量、expression 求值）压栈 + OP_INTERP <n>。
            .string_interpolation => |interp| {
                if (interp.parts.len > 65535) return error.Unsupported;
                for (interp.parts) |part| {
                    switch (part) {
                        .literal => |txt| {
                            const s = try Value.fromStringBytes(self.allocator, txt);
                            try self.emitConst(try self.chunk.addConstant(s), loc);
                        },
                        .expression => |e| try self.emitExpr(e),
                    }
                }
                try self.chunk.writeOp(.op_interp, loc);
                try self.chunk.writeU16(@intCast(interp.parts.len));
            },
            .identifier => |id| {
                // 检查是否是限定名（module.name）
                if (std.mem.indexOf(u8, id.name, ".")) |dot_pos| {
                    // 限定名：拆分为模块路径和符号名
                    const module_name = id.name[0..dot_pos];
                    const symbol_name = id.name[dot_pos + 1 ..];

                    // 尝试作为模块访问：module.symbol
                    // 首先检查 module 是否是已导入的模块
                    if (self.module.lookupGlobal(module_name)) |ge| {
                        // 模块找到，生成：GET_GLOBAL(module) + GET_FIELD(symbol)
                        try self.chunk.writeOp(.op_get_global, loc);
                        try self.chunk.writeU16(ge.idx);

                        const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, symbol_name));
                        try self.chunk.writeOp(.op_get_field, loc);
                        try self.chunk.writeU16(name_const);
                    } else {
                        // 模块未找到，报错
                        return error.Unsupported;
                    }
                } else if (self.resolveLocal(id.name)) |slot| {
                    try self.emitSlotOp(.op_get_local, slot, loc);
                } else if (try self.resolveUpvalue(id.name)) |uv_idx| {
                    try self.emitSlotOp(.op_get_upvalue, uv_idx, loc);
                } else if (self.module.lookupFn(id.name)) |func_idx| {
                    // 顶层函数名出现在值位置（非直接 call）→ 包成 vm_closure 一等值。
                    try self.chunk.writeOp(.op_closure, loc);
                    try self.chunk.writeU16(func_idx);
                    try self.chunk.writeByte(0); // n_upvalues=0
                } else if (self.module.lookupCtor(id.name)) |ce| {
                    // 裸名 nullary ADT 构造器（如 Red/Green/Nil）作为值 → OP_MAKE_ADT argc=0。
                    if (ce.arity == 0) {
                        try self.chunk.writeOp(.op_make_adt, loc);
                        try self.chunk.writeU16(ce.idx);
                        try self.chunk.writeByte(0);
                    } else {
                        // M5k：有参构造器作一等值（`val mk = Circle`）→ 合成 arity 参的包装 Function
                        //（取各参数 slot + OP_MAKE_ADT），OP_CLOSURE 压栈。调用时即构造 ADT。
                        const wrap_idx = try self.module.ctorWrapperFunc(ce.idx, ce.arity, id.name, loc);
                        try self.chunk.writeOp(.op_closure, loc);
                        try self.chunk.writeU16(wrap_idx);
                        try self.chunk.writeByte(0); // n_upvalues=0
                    }
                } else if (self.module.lookupGlobal(id.name)) |ge| {
                    // M5g：顶层 val/var 全局变量读 → OP_GET_GLOBAL。
                    try self.chunk.writeOp(.op_get_global, loc);
                    try self.chunk.writeU16(ge.idx);
                } else return error.Unsupported;
            },
            .unary => |un| {
                // 常量折叠：编译期求值一元运算（仅 neg，not 已由字面量路径处理）
                if (try self.tryEmitConstFoldedUnary(un, expr, loc)) return;
                try self.emitExpr(un.operand);
                try self.chunk.writeOp(switch (un.op) {
                    .neg => .op_neg,
                    .not => .op_not,
                }, loc);
            },
            .binary => |bin| {
                // 常量折叠：编译期求值二元算术/比较（命中则直接发射 op_const，跳过左右子树求值）
                if (try self.tryEmitConstFoldedBinary(bin, expr, loc)) {
                    return;
                }
                // 指令融合：代数简化（x+0→x、x*1→x、x*0→0、x&&true→x 等）
                if (try self.tryEmitAlgebraicSimplify(bin, loc)) {
                    return;
                }
                try self.emitBinary(bin, loc);
            },
            .if_expr => |ie| try self.emitIf(ie, expr, loc),
            .block => |blk| try self.emitBlock(blk, loc),
            .call => |c| try self.emitCall(c, loc),
            .lambda => |lam| _ = try self.emitLambda(lam, loc, null),
            // M2a：字段访问 p.x → OP_GET_FIELD <字段名常量>。
            .field_access => |fa| {
                try self.emitExpr(fa.object);
                const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, fa.field));
                try self.chunk.writeOp(.op_get_field, loc);
                try self.chunk.writeU16(name_const);
            },
            // M3d：方法调用 obj.m(args) → 压 receiver + 实参 + OP_CALL_METHOD <name><argc>。
            .method_call => |mc| {
                if (mc.arguments.len > 255) return error.Unsupported;
                // M4a：方法接收者若是 identifier，用 raw 读取（不透明 load atomic，cas/swap 需原始 Atomic）。
                try self.emitMethodReceiver(mc.object);
                // caller-side coerce：按 trait 方法形参类型协调实参。param_types[0]=self（通常非数值跳过），
                // param_types[i+1]=explicit arg i。修复 i8 字面量传入宽类型形参未 coerce 导致的算术溢出。
                const callee_pts = self.module.traitMethodParamTypes(mc.method);
                for (mc.arguments, 0..) |arg, i| {
                    try self.emitExpr(arg);
                    if (callee_pts) |pts| {
                        const pi = i + 1;
                        if (pi < pts.len) {
                            if (pts[pi]) |pt| {
                                if (isBuiltinNumericType(pt)) {
                                    const at = self.exprBuiltinType(arg);
                                    if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                }
                            }
                        }
                    }
                }
                const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, mc.method));
                try self.chunk.writeOp(.op_call_method, loc);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeByte(@intCast(mc.arguments.len));
            },
            // M3d：安全字段访问 obj?.field —— receiver null 短路返回 null，否则 OP_GET_FIELD。
            .safe_access => |sa| {
                try self.emitExpr(sa.object);
                // peek：null → 跳过字段访问（栈顶 null 即结果）；非 null → 弹后取字段。
                const skip = try self.chunk.emitJump(.op_jump_if_null, loc);
                const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, sa.field));
                try self.chunk.writeOp(.op_get_field, loc);
                try self.chunk.writeU16(name_const);
                self.chunk.patchJump(skip); // null 分支落点：栈顶仍是 null
            },
            // M3d：安全方法调用 obj?.m(args) —— receiver null 短路返回 null，否则正常方法调用。
            .safe_method_call => |smc| {
                if (smc.arguments.len > 255) return error.Unsupported;
                try self.emitExpr(smc.object);
                const skip = try self.chunk.emitJump(.op_jump_if_null, loc);
                // caller-side coerce：同 .method_call 路径（null 检查后、OP_CALL_METHOD 前协调实参）。
                const callee_pts = self.module.traitMethodParamTypes(smc.method);
                for (smc.arguments, 0..) |arg, i| {
                    try self.emitExpr(arg);
                    if (callee_pts) |pts| {
                        const pi = i + 1;
                        if (pi < pts.len) {
                            if (pts[pi]) |pt| {
                                if (isBuiltinNumericType(pt)) {
                                    const at = self.exprBuiltinType(arg);
                                    if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                }
                            }
                        }
                    }
                }
                const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, smc.method));
                try self.chunk.writeOp(.op_call_method, loc);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeByte(@intCast(smc.arguments.len));
                self.chunk.patchJump(skip); // null 分支落点：栈顶仍是 null
            },
            .match => |m| try self.emitMatch(m, loc),
            // M2b：数组字面量 [a, b, ...] → 各元素压栈 + OP_MAKE_ARRAY <n>。
            .array_literal => |al| {
                if (al.elements.len > 65535) return error.Unsupported;
                for (al.elements) |elem| try self.emitExpr(elem);
                try self.chunk.writeOp(.op_make_array, loc);
                try self.chunk.writeU16(@intCast(al.elements.len));
            },
            // M2b：记录字面量 {f: v, ...} → 各字段值压栈 + 登记形状 + OP_MAKE_RECORD <shape_idx>。
            .record_literal => |rl| {
                if (rl.fields.len > 65535) return error.Unsupported;
                var names = try self.allocator.alloc([]const u8, rl.fields.len);
                defer self.allocator.free(names);
                for (rl.fields, 0..) |f, i| names[i] = f.name;
                for (rl.fields) |f| try self.emitExpr(f.value);
                const shape_idx = try self.module.program.addRecordShape(names);
                try self.chunk.writeOp(.op_make_record, loc);
                try self.chunk.writeU16(shape_idx);
            },
            // M2b：索引 a[i] → object 压栈 + index 压栈 + OP_INDEX。
            .index => |ix| {
                try self.emitExpr(ix.object);
                try self.emitExpr(ix.index);
                try self.chunk.writeOp(.op_index, loc);
            },
            // M2c：记录扩展 (...base, f: v) → base 压栈 + update 值压栈 + OP_RECORD_EXTEND <shape>。
            .record_extend => |re| {
                if (re.updates.len > 65535) return error.Unsupported;
                try self.emitExpr(re.base);
                var names = try self.allocator.alloc([]const u8, re.updates.len);
                defer self.allocator.free(names);
                for (re.updates, 0..) |u, i| names[i] = u.name;
                for (re.updates) |u| try self.emitExpr(u.value);
                const shape_idx = try self.module.program.addRecordShape(names);
                try self.chunk.writeOp(.op_record_extend, loc);
                try self.chunk.writeU16(shape_idx);
            },
            // M3a：类型转换 Type(expr) → 求值 expr + OP_CAST <type_name 常量>。
            .type_cast => |tc| {
                const tname = switch (tc.target_type.*) {
                    .named => |n| n.name,
                    else => return error.Unsupported,
                };
                try self.emitExpr(tc.expr);
                const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, tname));
                try self.chunk.writeOp(.op_cast, loc);
                try self.chunk.writeU16(name_const);
            },
            // M3c：非空断言 expr! —— 求值 + OP_NON_NULL（null→panic，否则原样）。
            .non_null_assert => |nna| {
                try self.emitExpr(nna.expr);
                try self.chunk.writeOp(.op_non_null, nna.location);
            },
            // M3c：传播 expr? —— 求值 + OP_PROPAGATE（null/err 提前返回，ok 解包）。
            .propagate => |prop| {
                // 早退在 OP_PROPAGATE 内部完成，绕过 defer 重放。有活跃 defer 时退回 eval（正确性优先）。
                if (self.defer_scopes.items.len > 0) return error.Unsupported;
                try self.emitExpr(prop.expr);
                try self.chunk.writeOp(.op_propagate, prop.location);
            },
            // M3c-defer：赋值表达式（defer x = v 解析为此）。求值 v→写 local/upvalue/global→留 v 在栈顶。
            .assignment_expr => |a| {
                if (a.target.* != .identifier) return error.Unsupported;
                const name = a.target.identifier.name;
                try self.emitExpr(a.value); // 栈顶：v
                try self.chunk.writeOp(.op_dup, a.location); // 复制 v（一份写回，一份作表达式值）
                if (self.resolveLocal(name)) |slot| {
                    try self.emitSlotOp(.op_set_local_assign, slot, a.location);
                } else if (try self.resolveUpvalue(name)) |uv_idx| {
                    try self.emitSlotOp(.op_set_upvalue, uv_idx, a.location);
                } else if (self.module.lookupGlobal(name)) |ge| {
                    // M5g：赋值表达式写顶层 var 全局。
                    try self.chunk.writeOp(.op_set_global, a.location);
                    try self.chunk.writeU16(ge.idx);
                } else return error.Unsupported;
            },
            // M4a：atomic e —— 求值 e + OP_MAKE_ATOMIC（包成 AtomicValue）。
            .atomic_expr => |ae| {
                try self.emitExpr(ae.value);
                try self.chunk.writeOp(.op_make_atomic, ae.location);
            },
            // M4c：spawn { body } —— body 编译成零参闭包（自动捕获），OP_SPAWN 起协程。
            .spawn => |sp| {
                try self.emitSpawn(sp);
            },
            // M4d：lazy expr —— expr 编译成零参闭包（自动捕获），OP_MAKE_LAZY 包成 thunk，透明 force。
            .lazy => |lz| {
                try self.emitLazy(lz);
            },
            // M4d：select 多路复用 —— 镜像 eval：poll 各 recv arm 取首个就绪；否则首 timeout body；否则阻塞首 arm。
            .select => |sel| {
                try self.emitSelect(sel, expr.select.location);
            },
            // M4d：inline trait 值 —— 各方法体编译成闭包，OP_MAKE_TRAIT 建 vtable。
            .inline_trait_value => |itv| {
                try self.emitInlineTrait(itv, expr.inline_trait_value.location);
            },
            else => return error.Unsupported,
        }
    }

    /// 编译 lambda 为新 Function（append 进 program），再发 OP_CLOSURE func_idx + upvalue 描述符。
    /// upvalue 在子编译器编译体时静态解析（resolveUpvalue 沿 enclosing 链），运行时 OP_CLOSURE
    /// 据描述符 box/共享 cell。
    /// rec_name 非 null 时为 letrec 自递归 lambda：先注册占位 Function 拿 func_idx 供体内
    /// OP_CALL_REC 引用，编译完成后再覆盖占位为真实 chunk。
    /// 返回 true 若 lambda 体内值位置引用了 rec_name（产生 self-upvalue），调用方据此选择
    /// OP_SET_LOCAL_LETREC（断环）或 OP_SET_LOCAL（无循环）。
    fn emitLambda(self: *FnCompiler, lam: @TypeOf(@as(Expr, undefined).lambda), loc: ast.SourceLocation, rec_name: ?[]const u8) CompileError!bool {
        if (lam.params.len > 255) return error.Unsupported;
        var sub = FnCompiler.init(self.allocator, self.module);
        sub.enclosing = self;
        sub.rec_name = rec_name;
        defer sub.deinit();
        // 预占位拿 func_idx：letrec 自递归引用需编译前确定 idx。
        const placeholder = Function{
            .chunk = Chunk.init(self.allocator),
            .arity = @intCast(lam.params.len),
            .slot_count = 0,
            .name = if (rec_name) |n| n else "<lambda>",
        };
        const placeholder_idx = try self.module.program.addFunction(placeholder);
        sub.rec_func_idx = placeholder_idx;
        for (lam.params) |p| _ = try sub.declareLocal(p.name, p.is_var, typeNeedsRelease(p.type_annotation), builtinTypeOf(p.type_annotation));
        const body_expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        // 用 emitTail 编译 body：lambda body 本身就是尾位置，emitTail 能识别 match/if/block/call
        // 的尾位置发 TCO（op_tail_call / op_tail_call_rec），避免深度递归栈溢出 + 帧建立开销。
        try sub.emitTail(body_expr);
        // 检测值位置自引用：rec_name 出现在 upvalues 中（非 call 位置）→ 需要 cell 路径断环。
        var has_self_uv = false;
        if (rec_name) |rn| {
            for (sub.upvalues.items) |uv| {
                if (std.mem.eql(u8, uv.name, rn)) {
                    has_self_uv = true;
                    break;
                }
            }
        }
        const f = Function{
            .chunk = sub.chunk,
            .arity = @intCast(lam.params.len),
            .slot_count = sub.slot_count,
            .release_mask = sub.release_mask,
            .name = if (rec_name) |n| n else "<lambda>",
        };
        sub.chunk = Chunk.init(self.allocator); // 防 deinit 误碰
        // 覆盖占位 Function。
        self.module.program.functions.items[placeholder_idx].deinit();
        self.module.program.functions.items[placeholder_idx] = f;
        const func_idx = placeholder_idx;
        // 发 OP_CLOSURE + 描述符。注意：描述符在 *本* 函数(enclosing)上下文展开。
        try self.chunk.writeOp(.op_closure, loc);
        try self.chunk.writeU16(@intCast(func_idx));
        try self.chunk.writeByte(@intCast(sub.upvalues.items.len));
        for (sub.upvalues.items) |uv| {
            try self.chunk.writeByte(if (uv.is_local) 1 else 0);
            try self.chunk.writeU16(uv.index);
        }
        return has_self_uv;
    }

    /// 发 OP_CLOSURE 在本帧实例化（捕获当前 local/upvalue），再 OP_SPAWN 弹闭包起协程压 spawn_val。
    fn emitSpawn(self: *FnCompiler, sp: @TypeOf(@as(Expr, undefined).spawn)) CompileError!void {
        var sub = FnCompiler.init(self.allocator, self.module);
        sub.enclosing = self;
        defer sub.deinit();
        // 【缓存】预占位拿 func_idx
        const placeholder = Function{
            .chunk = Chunk.init(self.allocator),
            .arity = 0,
            .slot_count = 0,
            .name = "<spawn>",
        };
        const placeholder_idx = try self.module.program.addFunction(placeholder);
        try sub.emitExpr(sp.body);
        try sub.chunk.writeOp(.op_return, sp.location);
        const f = Function{
            .chunk = sub.chunk,
            .arity = 0,
            .slot_count = sub.slot_count,
            .release_mask = sub.release_mask,
            .name = "<spawn>",
        };
        sub.chunk = Chunk.init(self.allocator); // 防 deinit 误碰
        self.module.program.functions.items[placeholder_idx].deinit();
        self.module.program.functions.items[placeholder_idx] = f;
        const func_idx = placeholder_idx;
        try self.chunk.writeOp(.op_closure, sp.location);
        try self.chunk.writeU16(@intCast(func_idx));
        try self.chunk.writeByte(@intCast(sub.upvalues.items.len));
        for (sub.upvalues.items) |uv| {
            try self.chunk.writeByte(if (uv.is_local) 1 else 0);
            try self.chunk.writeU16(uv.index);
        }
        try self.chunk.writeOp(.op_spawn, sp.location);
    }

    /// M4d：lazy expr —— expr 编译成零参 Function（自动捕获 enclosing 变量为 upvalue），
    /// 发 OP_CLOSURE 实例化 + OP_MAKE_LAZY 包成 thunk。镜像 emitSpawn 结构。
    fn emitLazy(self: *FnCompiler, lz: @TypeOf(@as(Expr, undefined).lazy)) CompileError!void {
        var sub = FnCompiler.init(self.allocator, self.module);
        sub.enclosing = self;
        defer sub.deinit();
        // 【缓存】预占位拿 func_idx
        const placeholder = Function{
            .chunk = Chunk.init(self.allocator),
            .arity = 0,
            .slot_count = 0,
            .name = "<lazy>",
        };
        const placeholder_idx = try self.module.program.addFunction(placeholder);
        try sub.emitExpr(lz.expr);
        try sub.chunk.writeOp(.op_return, lz.location);
        const f = Function{
            .chunk = sub.chunk,
            .arity = 0,
            .slot_count = sub.slot_count,
            .release_mask = sub.release_mask,
            .name = "<lazy>",
        };
        sub.chunk = Chunk.init(self.allocator); // 防 deinit 误碰
        self.module.program.functions.items[placeholder_idx].deinit();
        self.module.program.functions.items[placeholder_idx] = f;
        const func_idx = placeholder_idx;
        try self.chunk.writeOp(.op_closure, lz.location);
        try self.chunk.writeU16(@intCast(func_idx));
        try self.chunk.writeByte(@intCast(sub.upvalues.items.len));
        for (sub.upvalues.items) |uv| {
            try self.chunk.writeByte(if (uv.is_local) 1 else 0);
            try self.chunk.writeU16(uv.index);
        }
        try self.chunk.writeOp(.op_make_lazy, lz.location);
    }

    /// M4d：从 recv arm 的 channel_expr 发射出 channel 操作数到栈顶。`ch.recv()` 取 object（ch），
    /// 否则直接求值（期望 channel/sender/receiver）。镜像 eval 的 getChannelFromExpr。
    fn emitChannelOperand(self: *FnCompiler, channel_expr: *Expr) CompileError!void {
        if (channel_expr.* == .method_call) {
            const mc = channel_expr.method_call;
            if (std.mem.eql(u8, mc.method, "recv")) {
                try self.emitExpr(mc.object);
                return;
            }
        }
        try self.emitExpr(channel_expr);
    }

    /// M4d：编译 select。镜像 eval 三段式：① poll 各 recv arm（非阻塞），首个就绪绑定+执行 body；
    /// ② 无就绪则首个 timeout arm 的 body；③ 无 timeout 则阻塞 recv 首个 recv arm。结果留栈顶。
    fn emitSelect(self: *FnCompiler, sel: @TypeOf(@as(Expr, undefined).select), loc: ast.SourceLocation) CompileError!void {
        var end_jumps = std.ArrayListUnmanaged(usize).empty;
        defer end_jumps.deinit(self.allocator);

        // ① poll 各 recv arm。
        for (sel.arms) |arm| {
            switch (arm) {
                .receive => |ra| {
                    try self.emitChannelOperand(ra.channel_expr);
                    try self.chunk.writeOp(.op_try_recv, ra.location); // → [value, flag]
                    const not_ready = try self.chunk.emitJump(.op_jump_if_false, ra.location);
                    // 就绪：弹 flag，绑定/丢弃 value，执行 body。
                    try self.chunk.writeOp(.op_pop, ra.location); // 弹 flag
                    const saved = self.locals.items.len;
                    if (ra.binding) |bname| {
                        const slot = try self.declareLocal(bname, false, true, null);
                        try self.emitSlotOp(.op_set_local, slot, ra.location); // value → slot
                    } else {
                        try self.chunk.writeOp(.op_pop, ra.location); // 丢弃 value
                    }
                    try self.emitExpr(ra.body); // → result
                    self.locals.shrinkRetainingCapacity(saved);
                    const ej = try self.chunk.emitJump(.op_jump, ra.location);
                    try end_jumps.append(self.allocator, ej);
                    // 未就绪落点：弹 flag + value，继续下一 arm。
                    self.chunk.patchJump(not_ready);
                    try self.chunk.writeOp(.op_pop, ra.location); // 弹 flag
                    try self.chunk.writeOp(.op_pop, ra.location); // 弹 value(unit)
                },
                .timeout => {},
            }
        }

        // ② 无就绪：首个 timeout arm 的 body。
        var has_timeout = false;
        for (sel.arms) |arm| {
            if (arm == .timeout) {
                // duration 表达式求值并丢弃（语义占位：VM 无定时器，超时即默认分支）。
                try self.emitExpr(arm.timeout.duration);
                try self.chunk.writeOp(.op_pop, arm.timeout.location);
                try self.emitExpr(arm.timeout.body);
                has_timeout = true;
                break;
            }
        }

        // ③ 无 timeout：阻塞 recv 首个 recv arm。
        if (!has_timeout) {
            var blocked = false;
            for (sel.arms) |arm| {
                if (arm == .receive) {
                    const ra = arm.receive;
                    try self.emitChannelOperand(ra.channel_expr);
                    try self.chunk.writeOp(.op_recv, ra.location); // → value
                    const saved = self.locals.items.len;
                    if (ra.binding) |bname| {
                        const slot = try self.declareLocal(bname, false, true, null);
                        try self.emitSlotOp(.op_set_local, slot, ra.location);
                    } else {
                        try self.chunk.writeOp(.op_pop, ra.location);
                    }
                    try self.emitExpr(ra.body);
                    self.locals.shrinkRetainingCapacity(saved);
                    blocked = true;
                    break;
                }
            }
            if (!blocked) try self.chunk.writeOp(.op_unit, loc); // 空 select：unit
        }

        // 收束所有就绪分支跳转。
        for (end_jumps.items) |ej| self.chunk.patchJump(ej);
    }

    /// M4d：编译 inline trait 值 `trait { fun m(p) { ... } ... }`。每个有 body 的方法编成带 arity 的
    /// Function（自动捕获 enclosing 变量为 upvalue），按 [name(const), OP_CLOSURE] 顺序压栈，
    /// 末尾 OP_MAKE_TRAIT <count> 建 vtable。抽象方法（body==null）跳过。
    fn emitInlineTrait(self: *FnCompiler, itv: @TypeOf(@as(Expr, undefined).inline_trait_value), loc: ast.SourceLocation) CompileError!void {
        var count: u8 = 0;
        for (itv.methods) |method| {
            const body = method.body orelse continue;
            if (method.params.len > 255) return error.Unsupported;
            // 方法名常量。
            const name_v = try Value.fromStringBytes(self.allocator, method.name);
            try self.emitConst(try self.chunk.addConstant(name_v), method.location);
            // 方法体编成带 arity 的 Function（params 占 slot 0..；自动捕获 enclosing）。
            var sub = FnCompiler.init(self.allocator, self.module);
            sub.enclosing = self;
            defer sub.deinit();
            // 【缓存】预占位拿 func_idx
            const placeholder = Function{
                .chunk = Chunk.init(self.allocator),
                .arity = @intCast(method.params.len),
                .slot_count = 0,
                .name = method.name,
            };
            const placeholder_idx = try self.module.program.addFunction(placeholder);
            for (method.params) |p| _ = try sub.declareLocal(p.name, p.is_var, typeNeedsRelease(p.type_annotation), builtinTypeOf(p.type_annotation));
            try sub.emitExpr(body);
            try sub.chunk.writeOp(.op_return, method.location);
            const f = Function{
                .chunk = sub.chunk,
                .arity = @intCast(method.params.len),
                .slot_count = sub.slot_count,
                .release_mask = sub.release_mask,
                .name = method.name,
            };
            sub.chunk = Chunk.init(self.allocator);
            self.module.program.functions.items[placeholder_idx].deinit();
            self.module.program.functions.items[placeholder_idx] = f;
            const func_idx = placeholder_idx;
            try self.chunk.writeOp(.op_closure, method.location);
            try self.chunk.writeU16(@intCast(func_idx));
            try self.chunk.writeByte(@intCast(sub.upvalues.items.len));
            for (sub.upvalues.items) |uv| {
                try self.chunk.writeByte(if (uv.is_local) 1 else 0);
                try self.chunk.writeU16(uv.index);
            }
            count += 1;
        }
        try self.chunk.writeOp(.op_make_trait, loc);
        try self.chunk.writeByte(count);
    }

    fn emitConst(self: *FnCompiler, k: u16, loc: ast.SourceLocation) CompileError!void {
        // k < 256 时用 u8 窄变体，省一字节立即数 + VM 解码省一次移位/或运算。
        // 常量池前 256 项多为高频字面量（0/1/空串/常用 int），命中率极高。
        if (k < 256) {
            try self.chunk.writeOp(.op_const_u8, loc);
            try self.chunk.writeByte(@intCast(k));
        } else {
            try self.chunk.writeOp(.op_const, loc);
            try self.chunk.writeU16(k);
        }
    }

    /// 推断表达式的基础类型名（int/float/bool/char literal + identifier 可推断；binary/unary 算术递归左操作数；其他返回 null）。
    fn exprBuiltinType(self: *FnCompiler, expr: *const Expr) ?[]const u8 {
        return switch (expr.*) {
            .int_literal => |il| blk: {
                if (il.suffix) |s| break :blk s;
                const parsed = parseIntSoftware(il.raw) orelse break :blk null;
                break :blk @tagName(parsed.type);
            },
            .float_literal => |fl| if (fl.suffix) |s| s else "f64",
            .bool_literal => "bool",
            .char_literal => "char",
            .identifier => |id| blk: {
                // 【P1-7】先查局部变量，再查全局变量（与 resolveIdentifier 的查找顺序一致）
                if (self.resolveLocal(id.name)) |slot| break :blk self.locals.items[slot].builtin_type;
                if (self.module.lookupGlobal(id.name)) |g| break :blk g.builtin_type;
                break :blk null;
            },
            .binary => |bin| if (isArithmeticOp(bin.op)) self.exprBuiltinType(bin.left) else null,
            .unary => |u| self.exprBuiltinType(u.operand),
            else => null,
        };
    }

    /// 发射 op_coerce 到指定类型名（栈顶值协调）。仅对数值类型有效（bool/char 的 op_coerce 是 no-op）。
    fn emitCoerceForType(self: *FnCompiler, tname: []const u8, loc: ast.SourceLocation) CompileError!void {
        const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, tname));
        try self.chunk.writeOp(.op_coerce, loc);
        try self.chunk.writeU16(name_const);
    }

    /// M5：按类型注解发射隐式数值定型（OP_COERCE）。仅当注解是 builtin 数值类型名（i*/u*/f*）
    /// 时发射；str/bool/泛型/用户类型/无注解 → 不发射（隐式协调只管数值宽度，镜像 eval 在形参/
    /// val/var 绑定处对 builtin 数值类型调 castValue 的行为）。作用于栈顶值（就地协调）。
    /// caller-side 优化：若 RHS 表达式推断类型与注解匹配，跳过 op_coerce 发射。
    fn emitCoerceFromAnnotation(self: *FnCompiler, ann: ?*const ast.TypeNode, expr: *const Expr, loc: ast.SourceLocation) CompileError!void {
        const tname = builtinTypeOf(ann) orelse return;
        if (!isBuiltinNumericType(tname)) return; // bool/char/用户类型：不协调
        if (self.exprBuiltinType(expr)) |rt| {
            if (std.mem.eql(u8, rt, tname)) return; // 类型匹配，跳过
        }
        try self.emitCoerceForType(tname, loc);
    }

    /// 调用派发（M1b）：
    /// - callee 是顶层函数名（非 local）：OP_CALL func_idx 快路径（M1a，callee 不上栈）。
    /// - 其它（local 标识符 / 柯里化结果 / 任意求值出函数的表达式）：求值 callee 上栈 + OP_CALL_VALUE。
    /// 尾位置发射：expr 的值即本函数返回值。
    /// - 合格尾调用（具名顶层函数、未被 local 遮蔽、argc==arity）→ OP_TAIL_CALL（复用帧，不增栈）。
    /// - if 表达式 → 两分支各自 emitTail（分支尾也是尾位置）。
    /// - block → 前序语句正常发射，trailing_expr 走 emitTail（无 trailing 则 unit+RETURN）。
    /// - 其它 → emitExpr + OP_RETURN。
    /// 不合格的 call（闭包/柯里化/超参/被遮蔽）落到 else 分支：emitExpr 内部走 OP_CALL_VALUE 等，
    /// 再 OP_RETURN，语义正确，仅不享 TCO。
    fn emitTail(self: *FnCompiler, expr: *const Expr) CompileError!void {
        const loc = ast.exprLocation(expr);
        switch (expr.*) {
            .call => |c| {
                if (try self.tryEmitTailCall(c, loc)) return;
                // letrec 自递归尾调用 TCO：callee 是当前 letrec 名字 → emit OP_TAIL_CALL_REC。
                // 复用当前帧（upvalues 保留），避免深度递归栈溢出 + 帧建立开销。
                // 通用方案：任何 letrec lambda 在尾位置自递归都受益（match/if/block 尾位置均经 emitTail）。
                if (try self.tryEmitTailCallRec(c, loc)) return;
                try self.emitExpr(expr);
                try self.chunk.writeOp(.op_return, loc);
            },
            .if_expr => |ie| {
                // JIT Phase 5：尾位置也查询分支可达性，跳过死分支。
                if (self.module.branchInfo(expr)) |info| {
                    if (info == .always_true) {
                        try self.emitTail(ie.then_branch);
                        return;
                    }
                    if (info == .always_false) {
                        if (ie.else_branch) |eb| {
                            try self.emitTail(eb);
                        } else {
                            try self.chunk.writeOp(.op_unit, loc);
                            try self.chunk.writeOp(.op_return, loc);
                        }
                        return;
                    }
                }
                try self.emitExpr(ie.condition);
                // if 语句 cond 总是消费：false 跳 else，两条路径各 pop。
                const else_jump = try self.chunk.emitJump(.op_jump_if_false, loc);
                try self.chunk.writeOp(.op_pop, loc); // true 路径 pop cond
                try self.emitTail(ie.then_branch); // 分支尾自带 RETURN/TAIL_CALL
                // then 分支已 RETURN，无需 end_jump 跳过 else。
                self.chunk.patchJump(else_jump);
                try self.chunk.writeOp(.op_pop, loc); // false 路径 pop cond
                if (ie.else_branch) |eb| {
                    try self.emitTail(eb);
                } else {
                    try self.chunk.writeOp(.op_unit, loc);
                    try self.chunk.writeOp(.op_return, loc);
                }
            },
            .block => |blk| {
                const saved = self.locals.items.len;
                const has_defer = blockHasDefer(blk);
                if (has_defer) try self.defer_scopes.append(self.allocator, .empty);
                for (blk.statements) |stmt| try self.emitStmt(stmt);
                if (blk.trailing_expr) |te| {
                    if (has_defer) {
                        // 有 defer：禁尾调用，求值结果 + 重放本层 defer + RETURN（结果在栈顶下方不受扰）。
                        try self.emitExpr(te);
                        try self.replayTopDeferScope(loc);
                        try self.chunk.writeOp(.op_return, loc);
                    } else {
                        try self.emitTail(te);
                    }
                } else {
                    if (has_defer) try self.replayTopDeferScope(loc);
                    try self.chunk.writeOp(.op_unit, loc);
                    try self.chunk.writeOp(.op_return, loc);
                }
                self.locals.shrinkRetainingCapacity(saved);
            },
            .match => |m| try self.emitMatchTail(m, loc),
            else => {
                try self.emitExpr(expr);
                try self.chunk.writeOp(.op_return, loc);
            },
        }
    }

    /// 尝试把 call 发射为 OP_TAIL_CALL；不合格返回 false（调用方退回 emitExpr+RETURN）。
    fn tryEmitTailCall(self: *FnCompiler, c: @TypeOf(@as(Expr, undefined).call), loc: ast.SourceLocation) CompileError!bool {
        if (c.arguments.len > 255) return false;
        if (c.callee.* != .identifier) return false;
        const name = c.callee.identifier.name;
        if (self.resolveLocal(name) != null) return false; // 被 local 遮蔽 → 非顶层
        const entry = self.module.lookupFnEntry(name) orelse return false;
        if (entry.arity != c.arguments.len) return false; // 仅足参直调可复用帧
        for (c.arguments, 0..) |arg, i| {
            try self.emitExpr(arg);
            if (i < entry.param_types.len) {
                if (entry.param_types[i]) |pt| {
                    if (isBuiltinNumericType(pt)) {
                        const at = self.exprBuiltinType(arg);
                        if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                    }
                }
            }
        }
        try self.chunk.writeOp(.op_tail_call, loc);
        try self.chunk.writeU16(entry.idx);
        try self.chunk.writeByte(@intCast(c.arguments.len));
        return true;
    }

    /// letrec 自递归尾调用 TCO：callee 是当前 lambda 的 letrec 名字 → emit OP_TAIL_CALL_REC。
    /// 与 tryEmitTailCall（顶层函数）对称，复用当前帧但 upvalues 保留（letrec 闭包继承）。
    /// 失败返回 false（调用方退回 emitExpr+RETURN，走 op_call_rec/op_call_value 建帧）。
    fn tryEmitTailCallRec(self: *FnCompiler, c: @TypeOf(@as(Expr, undefined).call), loc: ast.SourceLocation) CompileError!bool {
        if (c.arguments.len > 255) return false;
        if (c.callee.* != .identifier) return false;
        const name = c.callee.identifier.name;
        const rn = self.rec_name orelse return false;
        if (!std.mem.eql(u8, rn, name)) return false;
        // callee 是 letrec 自递归名。发实参 + caller-side coerce + OP_TAIL_CALL_REC。
        // coerce 逻辑与 emitCall 的 letrec 路径一致（比对 self.locals 前 N 项的 builtin_type）。
        for (c.arguments, 0..) |arg, i| {
            try self.emitExpr(arg);
            if (i < self.locals.items.len) {
                if (self.locals.items[i].builtin_type) |pt| {
                    if (isBuiltinNumericType(pt)) {
                        const at = self.exprBuiltinType(arg);
                        if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                    }
                }
            }
        }
        // JIT Phase 3: 纯递归函数仍走 op_call_memoized（memo 优先于 TCO，命中缓存省整个函数体）
        if (self.module.getOrAssignMemoSlot(name)) |memo_slot| {
            try self.chunk.writeOp(.op_call_memoized, loc);
            try self.chunk.writeU16(self.rec_func_idx);
            try self.chunk.writeByte(@intCast(c.arguments.len));
            try self.chunk.writeU16(memo_slot);
        } else {
            try self.chunk.writeOp(.op_tail_call_rec, loc);
            try self.chunk.writeU16(self.rec_func_idx);
            try self.chunk.writeByte(@intCast(c.arguments.len));
        }
        return true;
    }

    /// 【内联】尝试在调用点展开小函数 body。成功返回 true（已发射，调用方 return）。
    /// 通用方案：任何 canInlineFn 的顶层 fun_decl 都可内联，非特例。
    /// 语义：求值实参 → 绑定参数名到临时 local → emitExpr(body) → shrink locals。
    /// body 是 Expr（无 return 语句），内联安全。深度限制 ≤ 3 防止互递归无限展开。
    fn tryEmitInlineCall(self: *FnCompiler, c: @TypeOf(@as(Expr, undefined).call), entry: FnEntry, loc: ast.SourceLocation) CompileError!bool {
        if (entry.body == null) return false;
        if (entry.arity != c.arguments.len) return false;
        if (self.inline_depth >= 3) return false; // 深度限制
        // 尾位置的内联：尾调用优化优先于内联（TCO 省 50000 帧 > 内联省 1 帧）
        // 但非尾位置的调用内联收益更大（省帧建立 + return）

        const saved_locals = self.locals.items.len;
        const saved_inline_depth = self.inline_depth;
        defer self.locals.shrinkRetainingCapacity(saved_locals);
        defer self.inline_depth = saved_inline_depth;

        self.inline_depth += 1;

        // 求值实参 + 绑定参数名到临时 local（caller-side coerce 同 emitCall 顶层路径）
        for (c.arguments, 0..) |arg, i| {
            try self.emitExpr(arg);
            if (i < entry.param_types.len) {
                if (entry.param_types[i]) |pt| {
                    if (isBuiltinNumericType(pt)) {
                        const at = self.exprBuiltinType(arg);
                        if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                    }
                }
            }
            const param = entry.params[i];
            const slot = try self.declareLocal(param.name, param.is_var, typeNeedsRelease(param.type_annotation), builtinTypeOf(param.type_annotation));
            try self.emitSlotOp(.op_set_local, slot, loc);
        }

        // 展开 body：body 中的 identifier(param_name) 会 resolveLocal 找到临时 slot
        try self.emitExpr(entry.body.?);
        return true;
    }

    /// M5：变量绑定（val/var）的 RHS 发射。RHS 是裸 identifier 时用 raw 读取，保留 atomic/lazy
    /// **引用**（不透明 load/force），镜像 eval 把 atomic 当引用类型绑定的语义：`val c = counter`
    /// 后 c 与 counter 共享同一 atomic，`spawn { c += 1 }` 的累加对 counter 可见。
    /// 非引用类型（int/array/record 等）raw 与普通读取等价；非 identifier RHS 照常 emitExpr。
    fn emitBindingRhs(self: *FnCompiler, expr: *const Expr) CompileError!void {
        if (expr.* == .identifier) {
            const name = expr.identifier.name;
            if (self.resolveLocal(name)) |slot| {
                try self.emitSlotOp(.op_get_local_raw, slot, expr.identifier.location);
                return;
            } else if (try self.resolveUpvalue(name)) |uv| {
                try self.emitSlotOp(.op_get_upvalue_raw, uv, expr.identifier.location);
                return;
            }
        }
        try self.emitExpr(expr);
    }

    /// M4a：方法接收者求值 —— identifier（local/upvalue）用 raw 读取，避免对 atomic 透明 load
    /// （cas/swap 等需原始 Atomic 值；标量方法 len/push 等 raw 与普通读取等价）。其它表达式照常。
    fn emitMethodReceiver(self: *FnCompiler, obj: *Expr) CompileError!void {
        if (obj.* == .identifier) {
            const name = obj.identifier.name;
            if (self.resolveLocal(name)) |slot| {
                try self.emitSlotOp(.op_get_local_raw, slot, obj.identifier.location);
                return;
            } else if (try self.resolveUpvalue(name)) |uv| {
                try self.emitSlotOp(.op_get_upvalue_raw, uv, obj.identifier.location);
                return;
            }
        }
        try self.emitExpr(obj);
    }

    fn emitCall(self: *FnCompiler, c: @TypeOf(@as(Expr, undefined).call), loc: ast.SourceLocation) CompileError!void {
        if (c.arguments.len > 255) return error.Unsupported;
        const argc: u8 = @intCast(c.arguments.len);
        // 快路径：直接具名顶层函数（且非被 local/upvalue 遮蔽）。
        if (c.callee.* == .identifier) {
            const name = c.callee.identifier.name;
            // letrec 自递归快路径：callee 是当前 lambda 的 letrec 名字 → emit OP_CALL_REC。
            // 必须在 resolveUpvalue 之前判断，否则 rec_name 被加入 upvalues 形成 cell 循环引用。
            if (self.rec_name) |rn| {
                if (std.mem.eql(u8, rn, name)) {
                    for (c.arguments, 0..) |arg, i| {
                        try self.emitExpr(arg);
                        // caller-side coerce：比对实参类型与形参类型（形参是 self.locals 的前 N 项）
                        if (i < self.locals.items.len) {
                            if (self.locals.items[i].builtin_type) |pt| {
                                if (isBuiltinNumericType(pt)) {
                                    const at = self.exprBuiltinType(arg);
                                    if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                }
                            }
                        }
                    }
                    // JIT Phase 3: 纯递归函数 → op_call_memoized（自递归也受益）
                    if (self.module.getOrAssignMemoSlot(name)) |memo_slot| {
                        try self.chunk.writeOp(.op_call_memoized, loc);
                        try self.chunk.writeU16(self.rec_func_idx);
                        try self.chunk.writeByte(argc);
                        try self.chunk.writeU16(memo_slot);
                    } else {
                        try self.chunk.writeOp(.op_call_rec, loc);
                        try self.chunk.writeU16(self.rec_func_idx);
                        try self.chunk.writeByte(argc);
                    }
                    return;
                }
            }
            // 被 local 或 upvalue 绑定遮蔽（如递归局部函数 go 在自身体内是 upvalue）→ 走通用
            // op_call_value 路径，不当顶层函数/构造器/内建处理。
            const shadowed = self.resolveLocal(name) != null or (try self.resolveUpvalue(name)) != null;
            if (!shadowed) {
                // 先检查自定义错误类型（优先级高于 Native）
                if (self.module.lookupError(name)) |ee| {
                    if (argc != 1) return error.Unsupported;
                    try self.emitExpr(c.arguments[0]);
                    try self.chunk.writeOp(.op_make_error, loc);
                    try self.chunk.writeU16(ee.idx);
                    return;
                }

                if (self.module.lookupFn(name)) |func_idx| {
                    const entry = self.module.lookupFnEntry(name).?;
                    // 【内联】可内联小函数 → 在调用点展开 body（省 op_call + 帧 + return）
                    if (try self.tryEmitInlineCall(c, entry, loc)) return;
                    for (c.arguments, 0..) |arg, i| {
                        try self.emitExpr(arg);
                        if (i < entry.param_types.len) {
                            if (entry.param_types[i]) |pt| {
                                if (isBuiltinNumericType(pt)) {
                                    const at = self.exprBuiltinType(arg);
                                    if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                }
                            }
                        }
                    }
                    // JIT Phase 3: 纯函数 → op_call_memoized
                    if (self.module.getOrAssignMemoSlot(name)) |memo_slot| {
                        try self.chunk.writeOp(.op_call_memoized, loc);
                        try self.chunk.writeU16(func_idx);
                        try self.chunk.writeByte(argc);
                        try self.chunk.writeU16(memo_slot);
                    } else {
                        try self.chunk.writeOp(.op_call, loc);
                        try self.chunk.writeU16(func_idx);
                        try self.chunk.writeByte(argc);
                    }
                    return;
                }
                // M2a：ADT 构造器裸名调用 → OP_MAKE_ADT。
                if (self.module.lookupCtor(name)) |ce| {
                    if (ce.arity != argc) return error.Unsupported; // 柯里化构造器留后续
                    for (c.arguments) |arg| try self.emitExpr(arg);
                    try self.chunk.writeOp(.op_make_adt, loc);
                    try self.chunk.writeU16(ce.idx);
                    try self.chunk.writeByte(argc);
                    return;
                }
                // M2c：newtype 构造器裸名调用 → OP_MAKE_NEWTYPE（arity 恒 1）。
                if (self.module.lookupNewtype(name)) |ne| {
                    if (argc != 1) return error.Unsupported;
                    try self.emitExpr(c.arguments[0]);
                    try self.chunk.writeOp(.op_make_newtype, loc);
                    try self.chunk.writeU16(ne.idx);
                    return;
                }
                // 原生内建（println/print 等）：bench 驱动端到端跑完整 main。
                if (opcode.Native.fromName(name)) |nat| {
                    for (c.arguments) |arg| try self.emitExpr(arg);
                    try self.chunk.writeOp(.op_call_native, loc);
                    try self.chunk.writeByte(@intFromEnum(nat));
                    try self.chunk.writeByte(argc);
                    return;
                }
                // M5i：裸名 trait 方法调用（with-clause 约束的自由函数式 trait 方法，如 `compare(a,b)`）→
                // 以 arg0 为 receiver 发 OP_CALL_METHOD（argc 减 1，receiver 在 args 下方）。
                if (self.module.isMethodName(name) and argc >= 1) {
                    // 单 trait 实现：直接调用其函数（镜像 eval 动态类型语义，不受 receiver 类型限制，
                    // 如 `compare(1.5,2.5)` 调用唯一的 Comparable<i32> 实现）。多实现 → receiver 类型分派。
                    if (self.module.uniqueTraitMethod(name)) |fidx| {
                        // caller-side coerce：按 trait 方法形参类型协调实参（含 receiver=arg0，self 通常非数值跳过）。
                        // 修复 i8 字面量传入宽类型形参未 coerce 导致的算术溢出，与 op_call/op_call_value 路径对称。
                        const callee_pts = self.module.func_param_types.get(fidx);
                        for (c.arguments, 0..) |arg, i| {
                            try self.emitExpr(arg);
                            if (callee_pts) |pts| {
                                if (i < pts.len) {
                                    if (pts[i]) |pt| {
                                        if (isBuiltinNumericType(pt)) {
                                            const at = self.exprBuiltinType(arg);
                                            if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                        }
                                    }
                                }
                            }
                        }
                        try self.chunk.writeOp(.op_call, loc);
                        try self.chunk.writeU16(fidx);
                        try self.chunk.writeByte(argc);
                        return;
                    }
                    // 多实现 → receiver 类型分派。同一 trait 方法名的实现共享相同形参签名，
                    // 取首个匹配实现的 param_types 做 caller-side coerce（best-effort，无则跳过）。
                    const callee_pts = self.module.traitMethodParamTypes(name);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, name));
                    for (c.arguments, 0..) |arg, i| {
                        try self.emitExpr(arg); // [recv, rest...]
                        if (callee_pts) |pts| {
                            if (i < pts.len) {
                                if (pts[i]) |pt| {
                                    if (isBuiltinNumericType(pt)) {
                                        const at = self.exprBuiltinType(arg);
                                        if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                                    }
                                }
                            }
                        }
                    }
                    try self.chunk.writeOp(.op_call_method, loc);
                    try self.chunk.writeU16(name_const);
                    try self.chunk.writeByte(argc - 1);
                    return;
                }
                // M5k：零参 trait 方法裸名调用（`zero()`）→ 无 receiver 不能按类型分派，直接解析到
                // 登记的 trait 方法函数（OP_CALL func_idx，argc=0）。返回类型导向分派在 VM 不可得，单实现即解析。
                if (argc == 0) {
                    if (self.module.lookupNullaryMethod(name)) |fidx| {
                        try self.chunk.writeOp(.op_call, loc);
                        try self.chunk.writeU16(fidx);
                        try self.chunk.writeByte(0);
                        return;
                    }
                }
                // M5k：裸名是顶层全局（持函数/构造器闭包值，如 `val mk = Circle; mk(7.0)`）→ 不报错，
                // 落到下方通用 op_call_value 路径（求值 callee 全局 + 实参 + 动态调用）。
                if (self.module.lookupGlobal(name) == null) return error.Unsupported; // 未知裸名
            }
        }
        // 通用路径：先压 callee（求值出 vm_closure），再压实参，OP_CALL_VALUE。
        try self.emitExpr(c.callee);
        // caller-side coerce：若 callee 是已知 letrec lambda（local/upvalue），按形参类型协调实参。
        // 修复 i8 字面量传入 i64 形参未 coerce 导致的算术溢出（op_call_value 路径原本缺失此步骤）。
        const callee_param_types: ?[]const ?[]const u8 = blk: {
            if (c.callee.* == .identifier) {
                const cn = c.callee.identifier.name;
                if (self.resolveLocal(cn)) |slot| {
                    if (slot < self.locals.items.len) break :blk self.locals.items[slot].closure_param_types;
                } else if (try self.resolveUpvalue(cn)) |uv_idx| {
                    if (uv_idx < self.upvalues.items.len) break :blk self.upvalues.items[uv_idx].closure_param_types;
                }
            }
            break :blk null;
        };
        for (c.arguments, 0..) |arg, i| {
            try self.emitExpr(arg);
            if (callee_param_types) |pts| {
                if (i < pts.len) {
                    if (pts[i]) |pt| {
                        if (isBuiltinNumericType(pt)) {
                            const at = self.exprBuiltinType(arg);
                            if (at == null or !std.mem.eql(u8, at.?, pt)) try self.emitCoerceForType(pt, loc);
                        }
                    }
                }
            }
        }
        try self.chunk.writeOp(.op_call_value, loc);
        try self.chunk.writeByte(argc);
    }

    /// 常量折叠：查询表达式在 ConstTable 中的编译期常量值。
    /// 返回非 null 时，调用方负责把该值转成合适类型的 Value 并发射 op_const。
    /// 注意：返回的 ConstValue 丢失了原始类型宽度信息（i128/f64/bool），调用方需结合
    /// type_table / exprBuiltinType 重建正确类型，以保证运行时算术语义（溢出 panic 等）不变。
    fn lookupConstValue(self: *const FnCompiler, expr: *const Expr) ?analysis_db_mod.ConstValue {
        if (self.module.analysis_db) |db| {
            return db.const_prop.lookup(expr);
        }
        return null;
    }

    /// 把折叠出的 i128 值按 left 表达式的目标类型构造为 Int Value。
    /// 语义保持：用 coerceTo 做范围检查，若 i128 结果超出目标类型范围（运行时会 panic），
    /// 返回 null（放弃折叠，回退运行时让 panic 自然发生）。
    fn foldedIntToValue(target_type: value.IntType, i128_val: i128) ?Value {
        // i128 → 16 字节小端
        var buf: [16]u8 = undefined;
        const u128_val: u128 = @bitCast(i128_val);
        std.mem.writeInt(u64, buf[0..8], @truncate(u128_val), .little);
        std.mem.writeInt(u64, buf[8..16], @truncate(u128_val >> 64), .little);
        // fromBytes 后用 coerceTo 检查目标类型范围
        const generic = value.Int.fromBytes(.i128, &buf);
        const typed = generic.coerceTo(target_type) orelse return null;
        return Value.fromInt(typed);
    }

    /// 把折叠出的 f64 值按 left 表达式的目标类型构造为 Float Value。
    /// 浮点无溢出 panic，直接 fromNative 即可（窄化是舍入，与运行时 doArithFloat 一致）。
    fn foldedFloatToValue(target_type: value.FloatType, f64_val: f64) Value {
        return Value.fromFloat(value.Float.fromNative(target_type, f64_val));
    }

    /// 常量折叠二元运算。命中返回 true（已发射 op_const），未命中返回 false。
    /// 仅折叠算术（add/sub/mul/div/mod/bit_and/bit_or/bit_xor）和比较（eq/ne/lt/gt/le/ge）。
    /// 短路逻辑（and_op/or_op）、elvis、range、concat_list 由 emitBinary 原路径处理（保留副作用顺序）。
    fn tryEmitConstFoldedBinary(
        self: *FnCompiler,
        bin: @TypeOf(@as(Expr, undefined).binary),
        expr: *const Expr,
        loc: ast.SourceLocation,
    ) CompileError!bool {
        const cv = self.lookupConstValue(expr) orelse return false;
        switch (cv) {
            .int_val => |i128_val| {
                // 目标类型：算术结果取 left 类型；比较结果固定 bool
                const is_comparison = switch (bin.op) {
                    .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq => true,
                    else => false,
                };
                if (is_comparison) {
                    // 比较结果 bool，无溢出风险
                    // 注意：cv 已经是 evalBinary 在 i128 域比较的结果（bool_val），
                    // 但此处 cv 是 int_val，说明 evalBinary 返回的是 int——只对算术成立。
                    // 比较运算的 cv 应是 bool_val，不会进到此分支。安全起见 return false。
                    return false;
                }
                // 算术：取 left 的目标类型
                const target_tname = self.exprBuiltinType(bin.left) orelse return false;
                const target_type = value.IntType.fromName(target_tname) orelse return false;
                const v = foldedIntToValue(target_type, i128_val) orelse return false;
                const cidx = try self.chunk.addConstant(v);
                try self.emitConst(cidx, loc);
                return true;
            },
            .float_val => |f64_val| {
                const is_comparison = switch (bin.op) {
                    .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq => true,
                    else => false,
                };
                if (is_comparison) return false; // 同上，比较 cv 应是 bool_val
                const target_tname = self.exprBuiltinType(bin.left) orelse return false;
                const target_type = value.FloatType.fromName(target_tname) orelse return false;
                const v = foldedFloatToValue(target_type, f64_val);
                const cidx = try self.chunk.addConstant(v);
                try self.emitConst(cidx, loc);
                return true;
            },
            .bool_val => |b| {
                // 布尔比较（== !=）的结果；and_op/or_op 因短路语义不走此路径
                const cidx = try self.chunk.addConstant(Value.fromBool(b));
                try self.emitConst(cidx, loc);
                return true;
            },
            .unknown => return false,
        }
    }

    /// 【指令融合】代数简化 peephole：识别 x op k 或 k op x 模式（k 为编译期常量），
    /// 折叠为更简形式。命中返回 true（已发射），未命中返回 false。
    ///
    /// 安全性：
    /// - 加法/乘法单位元（0/+，1/*，1//，0-）→ 仅 emit 另一操作数，无副作用问题
    /// - 零化简（x*0 → 0）→ 仅当另一操作数是"纯表达式"才简化（避免丢副作用）
    /// - 逻辑短路化简（x&&true → x，x||false → x）→ 仅 emit 另一操作数
    /// - 逻辑恒值化简（x&&false → false，x||true → true）→ 仅当另一操作数是"纯表达式"
    ///   （因为原 && / || 短路：若 x 假，x&&false 不求值右操作数；hoist 后右操作数仍不求值，
    ///   但 x 必须求值——若 x 有副作用，化简为 false 会丢副作用，故要求 x 纯）
    fn tryEmitAlgebraicSimplify(
        self: *FnCompiler,
        bin: @TypeOf(@as(Expr, undefined).binary),
        loc: ast.SourceLocation,
    ) CompileError!bool {
        // 不处理字符串拼接 / 数组拼接 / range / elvis（语义不适用）
        switch (bin.op) {
            .add, .sub, .mul, .div, .bit_and, .bit_or, .bit_xor,
            .and_op, .or_op => {},
            else => return false,
        }

        // 查常量值（左右任一为常量即可）
        const lv = self.lookupConstValue(bin.left);
        const rv = self.lookupConstValue(bin.right);
        if (lv == null and rv == null) return false;

        // 辅助：判定操作数是否"纯"（无副作用）——字面量 + identifier 视为纯。
        // 化简为常量时（如 x*0→0），另一操作数必须纯，否则丢副作用。
        const isPure = struct {
            fn check(e: *const Expr) bool {
                return switch (e.*) {
                    .int_literal, .float_literal, .bool_literal,
                    .char_literal, .string_literal, .null_literal, .unit_literal,
                    .identifier,
                    => true,
                    .unary => |u| check(u.operand),
                    .binary => |b| check(b.left) and check(b.right),
                    else => false,
                };
            }
        }.check;

        // 辅助：判定常量是否为整数 0 / 1 或浮点 0.0 / 1.0 或布尔 true / false
        const isZero = struct {
            fn check(cv: ?analysis_db_mod.ConstValue) bool {
                if (cv) |v| return switch (v) {
                    .int_val => |i| i == 0,
                    .float_val => |f| f == 0.0,
                    else => false,
                };
                return false;
            }
        }.check;
        const isOne = struct {
            fn check(cv: ?analysis_db_mod.ConstValue) bool {
                if (cv) |v| return switch (v) {
                    .int_val => |i| i == 1,
                    .float_val => |f| f == 1.0,
                    else => false,
                };
                return false;
            }
        }.check;
        const isBool = struct {
            fn check(cv: ?analysis_db_mod.ConstValue, want: bool) bool {
                if (cv) |v| return switch (v) {
                    .bool_val => |b| b == want,
                    else => false,
                };
                return false;
            }
        }.check;

        switch (bin.op) {
            // x + 0 / 0 + x → x
            .add => {
                if (isZero(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isZero(lv)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
            },
            // x - 0 → x（注意：0 - x 不化简，因为 -x 是 neg）
            .sub => {
                if (isZero(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
            },
            // x * 1 / 1 * x → x；x * 0 / 0 * x → 0（另一操作数须纯）
            .mul => {
                if (isOne(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isOne(lv)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
                if (isZero(rv) and isPure(bin.left)) {
                    try self.emitZeroConstant(bin.left, loc);
                    return true;
                }
                if (isZero(lv) and isPure(bin.right)) {
                    try self.emitZeroConstant(bin.right, loc);
                    return true;
                }
            },
            // x / 1 → x
            .div => {
                if (isOne(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
            },
            // x & 0 → 0（位运算零化简，另一操作数须纯）；x & -1（全 1）不化简（需类型宽度信息）
            .bit_and => {
                if (isZero(rv) and isPure(bin.left)) {
                    try self.emitZeroConstant(bin.left, loc);
                    return true;
                }
                if (isZero(lv) and isPure(bin.right)) {
                    try self.emitZeroConstant(bin.right, loc);
                    return true;
                }
            },
            // x | 0 → x（位运算单位元）
            .bit_or => {
                if (isZero(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isZero(lv)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
            },
            // x ^ 0 → x
            .bit_xor => {
                if (isZero(rv)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isZero(lv)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
            },
            // x && true / true && x → x；x && false → false（x 须纯）；false && x → false（x 须纯）
            .and_op => {
                if (isBool(rv, true)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isBool(lv, true)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
                if (isBool(rv, false) and isPure(bin.left)) {
                    try self.chunk.writeOp(.op_false, loc);
                    return true;
                }
                if (isBool(lv, false) and isPure(bin.right)) {
                    try self.chunk.writeOp(.op_false, loc);
                    return true;
                }
            },
            // x || false / false || x → x；x || true → true（x 须纯）；true || x → true（x 须纯）
            .or_op => {
                if (isBool(rv, false)) {
                    try self.emitExpr(bin.left);
                    return true;
                }
                if (isBool(lv, false)) {
                    try self.emitExpr(bin.right);
                    return true;
                }
                if (isBool(rv, true) and isPure(bin.left)) {
                    try self.chunk.writeOp(.op_true, loc);
                    return true;
                }
                if (isBool(lv, true) and isPure(bin.right)) {
                    try self.chunk.writeOp(.op_true, loc);
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// 辅助：发射与 `ty_expr` 同类型的零常量（int 0 / float 0.0）。
    /// 用于 x*0 / x&0 等化简。ty_expr 仅用于类型推断。
    fn emitZeroConstant(self: *FnCompiler, ty_expr: *const Expr, loc: ast.SourceLocation) CompileError!void {
        // 优先用 ty_expr 的类型注解；int→0，float→0.0，否则退化到 i64 0
        const tname = self.exprBuiltinType(ty_expr);
        if (tname) |tn| {
            if (value.IntType.fromName(tn)) |it| {
                const v = Value.fromInt(value.Int.fromNative(it, 0));
                try self.emitConst(try self.chunk.addConstant(v), loc);
                return;
            }
            if (value.FloatType.fromName(tn)) |ft| {
                const v = Value.fromFloat(value.Float.fromNative(ft, 0.0));
                try self.emitConst(try self.chunk.addConstant(v), loc);
                return;
            }
        }
        // 默认 i64 0
        const v = Value.fromInt(value.Int.fromNative(.i64, 0));
        try self.emitConst(try self.chunk.addConstant(v), loc);
    }

    /// 常量折叠一元运算（neg）。not 已由字面量 + op_not 处理，这里只处理 neg。
    fn tryEmitConstFoldedUnary(
        self: *FnCompiler,
        un: @TypeOf(@as(Expr, undefined).unary),
        expr: *const Expr,
        loc: ast.SourceLocation,
    ) CompileError!bool {
        if (un.op != .neg) return false;
        const cv = self.lookupConstValue(expr) orelse return false;
        switch (cv) {
            .int_val => |i128_val| {
                const target_tname = self.exprBuiltinType(un.operand) orelse return false;
                const target_type = value.IntType.fromName(target_tname) orelse return false;
                const v = foldedIntToValue(target_type, i128_val) orelse return false;
                const cidx = try self.chunk.addConstant(v);
                try self.emitConst(cidx, loc);
                return true;
            },
            .float_val => |f64_val| {
                const target_tname = self.exprBuiltinType(un.operand) orelse return false;
                const target_type = value.FloatType.fromName(target_tname) orelse return false;
                const v = foldedFloatToValue(target_type, f64_val);
                const cidx = try self.chunk.addConstant(v);
                try self.emitConst(cidx, loc);
                return true;
            },
            else => return false,
        }
    }

    fn emitBinary(self: *FnCompiler, bin: @TypeOf(@as(Expr, undefined).binary), loc: ast.SourceLocation) CompileError!void {
        switch (bin.op) {
            .and_op => {
                try self.emitExpr(bin.left);
                const j = try self.chunk.emitJump(.op_jump_if_false, loc);
                try self.chunk.writeOp(.op_pop, loc);
                try self.emitExpr(bin.right);
                self.chunk.patchJump(j);
                return;
            },
            .or_op => {
                try self.emitExpr(bin.left);
                const j = try self.chunk.emitJump(.op_jump_if_true, loc);
                try self.chunk.writeOp(.op_pop, loc);
                try self.emitExpr(bin.right);
                self.chunk.patchJump(j);
                return;
            },
            // M3c：elvis `??` —— left 非 null 则用 left（短路），否则弹 left 求值 right。
            .elvis => {
                try self.emitExpr(bin.left);
                const j = try self.chunk.emitJump(.op_jump_if_not_null, loc);
                try self.chunk.writeOp(.op_pop, loc); // 弹 left(null)
                try self.emitExpr(bin.right);
                self.chunk.patchJump(j);
                return;
            },
            // M3d：范围 `a..b` / `a..=b` —— 压 start,end + OP_MAKE_RANGE <inclusive>。
            .range => {
                try self.emitExpr(bin.left);
                try self.emitExpr(bin.right);
                try self.chunk.writeOp(.op_make_range, loc);
                try self.chunk.writeByte(0);
                return;
            },
            .range_inclusive => {
                try self.emitExpr(bin.left);
                try self.emitExpr(bin.right);
                try self.chunk.writeOp(.op_make_range, loc);
                try self.chunk.writeByte(1);
                return;
            },
            // M5：数组拼接 `++` —— 压 left,right + OP_CONCAT_LIST（镜像 eval evalConcatList）。
            .concat_list => {
                try self.emitExpr(bin.left);
                try self.emitExpr(bin.right);
                try self.chunk.writeOp(.op_concat_list, loc);
                return;
            },
            else => {},
        }
        try self.emitExpr(bin.left);
        try self.emitExpr(bin.right);
        const op: OpCode = switch (bin.op) {
            .add => .op_add,
            .sub => .op_sub,
            .mul => .op_mul,
            .div => .op_div,
            .mod => .op_mod,
            .eq => .op_eq,
            .not_eq => .op_neq,
            .lt => .op_lt,
            .gt => .op_gt,
            .lt_eq => .op_le,
            .gt_eq => .op_ge,
            .bit_and => .op_bit_and,
            .bit_or => .op_bit_or,
            .bit_xor => .op_bit_xor,
            else => return error.Unsupported,
        };
        try self.chunk.writeOp(op, loc);
    }

    fn emitIf(self: *FnCompiler, ie: @TypeOf(@as(Expr, undefined).if_expr), if_expr_ptr: *const Expr, loc: ast.SourceLocation) CompileError!void {
        // JIT Phase 5：查询分支可达性，若条件为编译期常量则跳过死分支。
        if (self.module.branchInfo(if_expr_ptr)) |info| {
            if (info == .always_true) {
                // 条件恒真：只编译 then 分支（不发射 cond/jump/else）
                try self.emitExpr(ie.then_branch);
                return;
            }
            if (info == .always_false) {
                // 条件恒假：只编译 else 分支（或 unit）
                if (ie.else_branch) |eb| {
                    try self.emitExpr(eb);
                } else {
                    try self.chunk.writeOp(.op_unit, loc);
                }
                return;
            }
        }
        // 运行时分支：常规双分支发射
        try self.emitExpr(ie.condition);
        // if 语句 cond 总是消费：false 跳 else，两条路径各 pop。
        const else_jump = try self.chunk.emitJump(.op_jump_if_false, loc);
        try self.chunk.writeOp(.op_pop, loc); // true 路径 pop cond
        try self.emitExpr(ie.then_branch);
        const end_jump = try self.chunk.emitJump(.op_jump, loc);
        self.chunk.patchJump(else_jump);
        try self.chunk.writeOp(.op_pop, loc); // false 路径 pop cond
        if (ie.else_branch) |eb| {
            try self.emitExpr(eb);
        } else {
            try self.chunk.writeOp(.op_unit, loc);
        }
        self.chunk.patchJump(end_jump);
    }

    /// 重放深度 ≥ from_depth 的所有活跃 defer 作用域（LIFO），不弹出（break/continue 用）。
    fn replayDefersFrom(self: *FnCompiler, from_depth: usize, loc: ast.SourceLocation) CompileError!void {
        var s: usize = self.defer_scopes.items.len;
        while (s > from_depth) {
            s -= 1;
            const scope = self.defer_scopes.items[s];
            var i: usize = scope.items.len;
            while (i > 0) {
                i -= 1;
                try self.emitExpr(scope.items[i]);
                try self.chunk.writeOp(.op_pop, loc);
            }
        }
    }

    fn emitBlock(self: *FnCompiler, blk: @TypeOf(@as(Expr, undefined).block), loc: ast.SourceLocation) CompileError!void {
        const saved = self.locals.items.len;
        const has_defer = blockHasDefer(blk);
        if (has_defer) try self.defer_scopes.append(self.allocator, .empty);
        for (blk.statements) |stmt| try self.emitStmt(stmt);
        if (blk.trailing_expr) |te| {
            try self.emitExpr(te);
        } else {
            try self.chunk.writeOp(.op_unit, loc);
        }
        // 正常退出：LIFO 重放本层 defer（结果在栈顶下方，defer 体 push+pop 平衡，不扰动结果）。
        if (has_defer) try self.replayTopDeferScope(loc);
        self.locals.shrinkRetainingCapacity(saved);
    }

    /// 求值表达式并丢弃结果（用于循环体、表达式语句等"值位置"上下文）。
    /// 当 expr 是 block 时，镜像 emitBlock 逻辑但跳过无 trailing_expr 时的 op_unit 发射，
    /// 省去 op_unit + op_pop 一对指令（循环体每次迭代浪费 2 条指令）。
    /// 含 defer 的 block 仍正确重放 defer（defer 体 push+pop 平衡，不扰动栈）。
    fn emitExprDiscard(self: *FnCompiler, expr: *const Expr) CompileError!void {
        // DCE：无副作用表达式完全消除（含无 trailing_expr 且语句全纯的 block）
        if (exprHasNoSideEffects(expr)) return;
        const loc = ast.exprLocation(expr);
        if (expr.* == .block) {
            const blk = expr.block;
            const saved = self.locals.items.len;
            const has_defer = blockHasDefer(blk);
            if (has_defer) try self.defer_scopes.append(self.allocator, .empty);
            for (blk.statements) |stmt| try self.emitStmt(stmt);
            if (blk.trailing_expr) |te| {
                try self.emitExpr(te);
                try self.chunk.writeOp(.op_pop, loc);
            }
            // 无 trailing_expr：省略 op_unit（结果丢弃，不入栈则无需 pop）
            if (has_defer) try self.replayTopDeferScope(loc);
            self.locals.shrinkRetainingCapacity(saved);
        } else {
            try self.emitExpr(expr);
            try self.chunk.writeOp(.op_pop, loc);
        }
    }

    /// block 是否（直接，非嵌套）含 defer 语句。嵌套 block 由各自 emitBlock 处理。
    fn blockHasDefer(blk: @TypeOf(@as(Expr, undefined).block)) bool {
        for (blk.statements) |stmt| {
            if (stmt.* == .defer_stmt) return true;
        }
        return false;
    }

    /// 重放并弹出最顶层 defer 作用域（LIFO）。用于 block 正常退出。
    fn replayTopDeferScope(self: *FnCompiler, loc: ast.SourceLocation) CompileError!void {
        var scope = self.defer_scopes.pop().?;
        defer scope.deinit(self.allocator);
        var i: usize = scope.items.len;
        while (i > 0) {
            i -= 1;
            try self.emitExpr(scope.items[i]);
            try self.chunk.writeOp(.op_pop, loc); // defer 体结果丢弃
        }
    }

    /// 重放所有活跃 defer 作用域（LIFO，从内到外），不弹出（提前退出 return/throw 用）。
    /// 退出后栈顶返回值不受扰（defer 体 push+pop 平衡）。
    fn replayAllDefers(self: *FnCompiler, loc: ast.SourceLocation) CompileError!void {
        var s: usize = self.defer_scopes.items.len;
        while (s > 0) {
            s -= 1;
            const scope = self.defer_scopes.items[s];
            var i: usize = scope.items.len;
            while (i > 0) {
                i -= 1;
                try self.emitExpr(scope.items[i]);
                try self.chunk.writeOp(.op_pop, loc);
            }
        }
    }

    /// 编译 match（M2c：全模式）：scrutinee 存隐藏 slot；逐 arm 递归测试 + 绑定 + 体。
    /// 栈净效果：+1（match 结果）。各 arm 体压 1 个结果后跳 match 末尾。
    /// 不变式：emitPatternMatch 不匹配时跳 fail_label，跳转瞬间栈顶恰有 1 个 false bool；
    /// fail_label 处统一 pop 该 bool 再试下一 arm。恒匹配模式（wildcard/小写变量/record）不产 fail jump。
    fn emitMatch(self: *FnCompiler, m: @TypeOf(@as(Expr, undefined).match), loc: ast.SourceLocation) CompileError!void {
        try self.emitExpr(m.scrutinee);
        const saved_scrut = self.locals.items.len;
        const scrut_slot = try self.declareLocal("$scrut", false, true, null);
        try self.emitSlotOp(.op_set_local, scrut_slot, loc);

        var end_jumps = std.ArrayListUnmanaged(usize).empty;
        defer end_jumps.deinit(self.allocator);

        for (m.arms) |arm| {
            const arm_base = self.locals.items.len;
            var fail_jumps = std.ArrayListUnmanaged(usize).empty;
            defer fail_jumps.deinit(self.allocator);

            try self.emitPatternMatch(arm.pattern, scrut_slot, &fail_jumps, loc);
            // arm 级守卫：pattern if cond（绑定后求值条件）。
            if (arm.guard) |guard| {
                try self.emitExpr(guard);
                try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                try self.chunk.writeOp(.op_pop, loc); // 通过：弹 true
            }
            try self.emitExpr(arm.body);
            try end_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump, loc));
            // fail 落点：弹残留 false bool（恒匹配 arm 无 fail jump → 跳过 pop）。
            if (fail_jumps.items.len > 0) {
                for (fail_jumps.items) |j| self.chunk.patchJump(j);
                try self.chunk.writeOp(.op_pop, loc);
            }
            self.locals.shrinkRetainingCapacity(arm_base);
        }
        try self.chunk.writeOp(.op_match_fail, loc);
        for (end_jumps.items) |j| self.chunk.patchJump(j);
        self.locals.shrinkRetainingCapacity(saved_scrut);
    }

    /// 尾位置 match 发射：与 emitMatch 区别在于 arm body 走 emitTail（自带 RETURN/TAIL_CALL），
    /// 无需 end_jump 跳到 match end。arm body 若是 call 会经 tryEmitTailCall 发 OP_TAIL_CALL，
    /// 复用当前帧避免栈增长。通用方案：任何 match 在尾位置都受益，非特例。
    /// 控制流：pattern 成功 → emitTail(body) → return（函数退出）；pattern 失败 → fail_label → pop → 下个 arm。
    fn emitMatchTail(self: *FnCompiler, m: @TypeOf(@as(Expr, undefined).match), loc: ast.SourceLocation) CompileError!void {
        try self.emitExpr(m.scrutinee);
        const saved_scrut = self.locals.items.len;
        const scrut_slot = try self.declareLocal("$scrut", false, true, null);
        try self.emitSlotOp(.op_set_local, scrut_slot, loc);

        for (m.arms) |arm| {
            const arm_base = self.locals.items.len;
            var fail_jumps = std.ArrayListUnmanaged(usize).empty;
            defer fail_jumps.deinit(self.allocator);

            try self.emitPatternMatch(arm.pattern, scrut_slot, &fail_jumps, loc);
            if (arm.guard) |guard| {
                try self.emitExpr(guard);
                try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                try self.chunk.writeOp(.op_pop, loc);
            }
            // 尾位置：arm body 走 emitTail（发 RETURN 或 TAIL_CALL，函数退出/复用帧）
            try self.emitTail(arm.body);
            // fail 落点：弹残留 false bool（emitTail 后代码不可达，fail_jumps 跳到这里）
            if (fail_jumps.items.len > 0) {
                for (fail_jumps.items) |j| self.chunk.patchJump(j);
                try self.chunk.writeOp(.op_pop, loc);
            }
            self.locals.shrinkRetainingCapacity(arm_base);
        }
        try self.chunk.writeOp(.op_match_fail, loc);
        self.locals.shrinkRetainingCapacity(saved_scrut);
    }

    /// 递归发射模式测试 + 绑定。值取自 scrut_slot（一个 local slot）。
    /// 不匹配时发 OP_JUMP_IF_FALSE 进 fail_jumps（栈顶留 false bool，调用方 fail 落点 pop）；
    /// 匹配时 pop true、绑定变量到新 slot、栈净零落下。
    fn emitPatternMatch(self: *FnCompiler, pat: *const Pattern, scrut_slot: u16, fail_jumps: *std.ArrayListUnmanaged(usize), loc: ast.SourceLocation) CompileError!void {
        switch (pat.*) {
            .wildcard => {}, // 恒匹配，无绑定
            .variable => |v| {
                if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                    // 大写开头：nullary ADT 构造器模式（如 Red/Green/Blue）。
                    try self.emitCtorTest(scrut_slot, v.name, fail_jumps, loc);
                } else {
                    // 小写：变量绑定，恒匹配。
                    const slot = try self.declareLocal(v.name, false, true, null);
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    try self.emitSlotOp(.op_set_local, slot, loc);
                }
            },
            .literal => |lit| {
                const v = (try patternLiteralToValue(self.allocator, lit)) orelse return error.Unsupported;
                const cidx = try self.chunk.addConstant(v);
                try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                try self.chunk.writeOp(.op_test_lit, loc);
                try self.chunk.writeU16(cidx);
                try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                try self.chunk.writeOp(.op_pop, loc); // 命中：弹 true
            },
            .constructor => |ctor| {
                if (std.mem.eql(u8, ctor.name, "Ok") or std.mem.eql(u8, ctor.name, "Error")) {
                    // M3c：Throw 的 Ok(v)/Error(e) 模式 —— OP_TEST_THROW + 解包绑定。
                    if (ctor.patterns.len != 1) return error.Unsupported;
                    const want_ok: u8 = if (ctor.name[0] == 'O') 1 else 0;
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    try self.chunk.writeOp(.op_test_throw, loc);
                    try self.chunk.writeByte(want_ok);
                    try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                    try self.chunk.writeOp(.op_pop, loc); // 命中：弹 true
                    // 解包内值（Ok→inner / Error→error_val）进临时 slot 递归。
                    const tmp = try self.declareLocal("$thr", false, true, null);
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    try self.chunk.writeOp(if (want_ok == 1) .op_get_throw_ok else .op_get_throw_err, loc);
                    try self.emitSlotOp(.op_set_local, tmp, loc);
                    try self.emitPatternMatch(ctor.patterns[0], tmp, fail_jumps, loc);
                } else if (self.module.lookupNewtype(ctor.name)) |_| {
                    // newtype 构造器模式 Handle(p)：测 type_name + 解 inner 递归。
                    if (ctor.patterns.len != 1) return error.Unsupported;
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, ctor.name));
                    try self.chunk.writeOp(.op_test_newtype, loc);
                    try self.chunk.writeU16(name_const);
                    try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                    try self.chunk.writeOp(.op_pop, loc);
                    // 解 inner 进临时 slot 递归。
                    const tmp = try self.declareLocal("$nt", false, true, null);
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    try self.chunk.writeOp(.op_get_newtype_inner, loc);
                    try self.emitSlotOp(.op_set_local, tmp, loc);
                    try self.emitPatternMatch(ctor.patterns[0], tmp, fail_jumps, loc);
                } else {
                    // ADT 构造器模式：测构造器名 + 按位置解字段递归。
                    try self.emitCtorTest(scrut_slot, ctor.name, fail_jumps, loc);
                    for (ctor.patterns, 0..) |sub, i| {
                        const tmp = try self.declareLocal("$fld", false, true, null);
                        try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                        try self.chunk.writeOp(.op_get_adt_field, loc);
                        try self.chunk.writeU16(@intCast(i));
                        try self.emitSlotOp(.op_set_local, tmp, loc);
                        try self.emitPatternMatch(sub, tmp, fail_jumps, loc);
                    }
                }
            },
            .record => |rec| {
                // 记录模式：无标签测试，按名解字段递归绑定。
                for (rec.fields) |f| {
                    const tmp = try self.declareLocal("$rf", false, true, null);
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, f.name));
                    try self.chunk.writeOp(.op_get_field, loc);
                    try self.chunk.writeU16(name_const);
                    try self.emitSlotOp(.op_set_local, tmp, loc);
                    try self.emitPatternMatch(f.pattern, tmp, fail_jumps, loc);
                }
            },
            .or_pattern => {
                // 或模式（仅非绑定子模式）：emitPatternBool 得单 bool，不中跳 fail。
                try self.emitPatternBool(pat, scrut_slot, loc);
                try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                try self.chunk.writeOp(.op_pop, loc);
            },
            .guard => |g| {
                // 模式守卫 pat if cond：先匹配内部模式（绑定），再测条件。
                try self.emitPatternMatch(g.pattern, scrut_slot, fail_jumps, loc);
                try self.emitExpr(g.condition);
                try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                try self.chunk.writeOp(.op_pop, loc);
            },
        }
    }

    /// 发 nullary/有参 ADT 构造器名测试：get scrut → OP_TEST_CTOR → jump_if_false 进 fail → pop true。
    fn emitCtorTest(self: *FnCompiler, scrut_slot: u16, name: []const u8, fail_jumps: *std.ArrayListUnmanaged(usize), loc: ast.SourceLocation) CompileError!void {
        try self.emitSlotOp(.op_get_local, scrut_slot, loc);
        const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, name));
        try self.chunk.writeOp(.op_test_ctor, loc);
        try self.chunk.writeU16(name_const);
        try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
        try self.chunk.writeOp(.op_pop, loc);
    }

    /// 发"非绑定"模式的布尔测试，栈顶留 1 个 bool（不绑定任何变量）。
    /// 仅支持 wildcard/literal/大写 nullary ctor/或模式（递归）；含绑定的子模式 → Unsupported。
    fn emitPatternBool(self: *FnCompiler, pat: *const Pattern, scrut_slot: u16, loc: ast.SourceLocation) CompileError!void {
        switch (pat.*) {
            .wildcard => try self.chunk.writeOp(.op_true, loc),
            .literal => |lit| {
                const v = (try patternLiteralToValue(self.allocator, lit)) orelse return error.Unsupported;
                const cidx = try self.chunk.addConstant(v);
                try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                try self.chunk.writeOp(.op_test_lit, loc);
                try self.chunk.writeU16(cidx);
            },
            .variable => |v| {
                if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                    try self.emitSlotOp(.op_get_local, scrut_slot, loc);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, v.name));
                    try self.chunk.writeOp(.op_test_ctor, loc);
                    try self.chunk.writeU16(name_const);
                } else return error.Unsupported; // 或模式中的绑定变量不支持
            },
            .or_pattern => |orp| {
                // 短路 OR：left bool；true 则跳 done 留 true；false 则弹后算 right。
                try self.emitPatternBool(orp.left, scrut_slot, loc);
                const done = try self.chunk.emitJump(.op_jump_if_true, loc);
                try self.chunk.writeOp(.op_pop, loc);
                try self.emitPatternBool(orp.right, scrut_slot, loc);
                self.chunk.patchJump(done);
            },
            else => return error.Unsupported,
        }
    }


    fn emitStmt(self: *FnCompiler, stmt: *const Stmt) CompileError!void {
        switch (stmt.*) {
            .val_decl => |d| {
                // M5c：letrec —— RHS 是 lambda 时先声明 slot，使 lambda 体内可引用自身（递归
                // 局部函数 fun go(){...go()...}）。slot 先置 unit 占位并 box 成 cell。
                // 方案 A：emitLambda 传 rec_name=d.name，编译期识别 f() 自递归调用 → OP_CALL_REC
                // （不走 cell + upvalue，从根本消除循环引用）。仅当 lambda 体内值位置引用了
                // rec_name（has_self_uv=true）才退回原 letrec 路径（op_set_local_letrec 断环）。
                if (d.value.* == .lambda) {
                    const slot = try self.declareLocal(d.name, false, true, null);
                    // 存形参类型，供 op_call_value 路径 caller-side coerce（修复 i8 字面量传入 i64 形参未 coerce 的 bug）
                    self.locals.items[slot].closure_param_types = try extractParamTypes(self.allocator, d.value.lambda.params);
                    try self.chunk.writeOp(.op_unit, d.location);
                    try self.emitSlotOp(.op_set_local, slot, d.location);
                    const has_self_uv = try self.emitLambda(d.value.lambda, d.location, d.name);
                    if (has_self_uv) {
                        try self.emitSlotOp(.op_set_local_letrec, slot, d.location);
                    } else {
                        try self.emitSlotOp(.op_set_local, slot, d.location);
                    }
                } else {
                    try self.emitBindingRhs(d.value);
                    try self.emitCoerceFromAnnotation(d.type_annotation, d.value, d.location); // M5：val a: i32 = ...
                    const slot = try self.declareLocal(d.name, false, typeNeedsRelease(d.type_annotation), builtinTypeOf(d.type_annotation));
                    try self.emitSlotOp(.op_set_local, slot, d.location);
                }
            },
            .var_decl => |d| {
                try self.emitBindingRhs(d.value);
                try self.emitCoerceFromAnnotation(d.type_annotation, d.value, d.location); // M5：var a: i32 = ...
                const slot = try self.declareLocal(d.name, true, typeNeedsRelease(d.type_annotation), builtinTypeOf(d.type_annotation));
                try self.emitSlotOp(.op_set_local, slot, d.location);
            },
            .expression => |e| {
                // 求值并丢弃（DCE + block 无 trailing_expr 时省 op_unit+op_pop）
                try self.emitExprDiscard(e.expr);
            },
            .assignment => |a| {
                // M5f：index 目标 arr[i] = v —— 镜像 eval：identifier 数组目标 COW 后写回绑定槽。
                if (a.target.* == .index) {
                    try self.emitIndexAssign(a.target.index, a.value, a.location);
                    return;
                }
                if (a.target.* != .identifier) return error.Unsupported;
                const name = a.target.identifier.name;
                // op_push_inplace_set 优化：arr = arr.push(expr) 融合指令
                // 合并 op_push_inplace + op_set_local_assign，消除 fast path 的 retain+release 往返
                if (a.value.* == .method_call) blk: {
                    const mc = a.value.method_call;
                    if (!(std.mem.eql(u8, mc.method, "push") and mc.arguments.len == 1)) break :blk;
                    if (mc.object.* != .identifier) break :blk;
                    if (!std.mem.eql(u8, mc.object.identifier.name, name)) break :blk;
                    const slot = self.resolveLocal(name) orelse break :blk;
                    try self.emitExpr(mc.arguments[0]);
                    if (slot < 256) {
                        try self.chunk.writeOp(.op_push_inplace_set_u8, a.location);
                        try self.chunk.writeByte(@intCast(slot));
                    } else {
                        try self.chunk.writeOp(.op_push_inplace_set, a.location);
                        try self.chunk.writeU16(slot);
                    }
                    return;
                }
                if (self.resolveLocal(name)) |slot| {
                    try self.emitExpr(a.value);
                    try self.emitSlotOp(.op_set_local_assign, slot, a.location);
                } else if (try self.resolveUpvalue(name)) |uv_idx| {
                    try self.emitExpr(a.value);
                    try self.emitSlotOp(.op_set_upvalue, uv_idx, a.location);
                } else if (self.module.lookupGlobal(name)) |ge| {
                    // M5g：顶层 var 重新赋值 → OP_SET_GLOBAL（val 不可变性由 type_check 保证）。
                    try self.emitExpr(a.value);
                    try self.chunk.writeOp(.op_set_global, a.location);
                    try self.chunk.writeU16(ge.idx);
                } else return error.Unsupported;
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    if (self.defer_scopes.items.len > 0) {
                        // 有活跃 defer：禁尾调用（defer 须在返回前跑），求值 + 重放所有 defer + RETURN。
                        try self.emitExpr(v);
                        try self.replayAllDefers(r.location);
                        try self.chunk.writeOp(.op_return, r.location);
                    } else {
                        try self.emitTail(v); // emitTail 自带 OP_RETURN / OP_TAIL_CALL
                    }
                } else {
                    if (self.defer_scopes.items.len > 0) try self.replayAllDefers(r.location);
                    try self.chunk.writeOp(.op_unit, r.location);
                    try self.chunk.writeOp(.op_return, r.location);
                }
            },
            .while_stmt => |w| {
                // 常量边界 while 循环完全展开（`while i < N { ...; i = i + 1 }` 模式）
                if (self.tryUnrollWhile(w, stmt)) |_| {
                    return;
                } else |_| {}
                try self.emitWhile(w, stmt);
            },
            .loop_stmt => |l| try self.emitLoop(l, stmt),
            .for_stmt => |f| try self.emitFor(f, stmt),
            .break_stmt => |b| {
                if (self.loops.items.len == 0) return error.Unsupported;
                const lc = &self.loops.items[self.loops.items.len - 1];
                try self.replayDefersFrom(lc.defer_depth, b.location); // 重放循环体内 defer
                const j = try self.chunk.emitJump(.op_jump, b.location);
                try lc.breaks.append(self.allocator, j);
            },
            .continue_stmt => |c| {
                if (self.loops.items.len == 0) return error.Unsupported;
                const lc = self.loops.items[self.loops.items.len - 1];
                try self.replayDefersFrom(lc.defer_depth, c.location); // 重放循环体内 defer
                try self.emitLoopBack(lc.continue_target, c.location);
            },
            .compound_assignment => |ca| try self.emitCompoundAssign(ca),
            .field_assignment => |fa| try self.emitFieldAssign(fa),
            // M3c-defer：登记 defer 体到当前作用域（emitBlock 已为含 defer 的 block push 了层）。
            .defer_stmt => |def| {
                if (self.defer_scopes.items.len == 0) return error.Unsupported; // 顶层 defer 暂不支持
                try self.defer_scopes.items[self.defer_scopes.items.len - 1].append(self.allocator, def.expr);
            },
            // M3c：throw e —— 重放所有活跃 defer + 求值 e（throw_val.err / error_val）+ OP_THROW。
            .throw_stmt => |t| {
                // 文档 §2.4.5: throw 只能抛出满足 Error trait 的值
                // throw "error" 等价于 throw Error("error")

                // 检查表达式是否已经是 Error/自定义错误 调用
                const is_error_call = blk: {
                    if (t.expr.* != .call) break :blk false;
                    if (t.expr.call.callee.* != .identifier) break :blk false;
                    const name = t.expr.call.callee.identifier.name;
                    // Error 或自定义错误类型（FileError, NetworkError 等）
                    if (std.mem.eql(u8, name, "Error")) break :blk true;
                    if (self.module.lookupError(name) != null) break :blk true;
                    break :blk false;
                };

                if (!is_error_call) {
                    // 包装为 Error(expr)：先压 expr，再发 OP_CALL_NATIVE Error
                    try self.emitExpr(t.expr);
                    if (opcode.Native.fromName("Error")) |nat| {
                        try self.chunk.writeOp(.op_call_native, t.location);
                        try self.chunk.writeByte(@intFromEnum(nat));
                        try self.chunk.writeByte(1); // argc = 1
                    } else {
                        return error.Unsupported;
                    }
                } else {
                    // 已经是 Error(...) 或 FileError(...) 调用，直接求值
                    try self.emitExpr(t.expr);
                }

                try self.replayAllDefers(t.location);
                try self.chunk.writeOp(.op_throw, t.location);
            },
        }
    }

    /// 【LICM】在循环入口前发射所有属于该循环的 hoist 不变量。
    /// 遍历模块级 hoist_table，找出 owner_loop == stmt 的表达式，
    /// 对每个：emitExpr 求值一次 → declareLocal 分配临时 slot → op_set_local 缓存 → 登记 hoisted_slots。
    /// 登记的 expr* 记录到当前 LoopCtx.hoisted_exprs，供退出循环时清理。
    /// 必须在 push LoopCtx 之后、loop_start 之前调用（hoist 代码在循环前执行一次，不在每轮重执行）。
    fn emitHoistedInvariants(self: *FnCompiler, stmt: *const ast.Stmt, loc: ast.SourceLocation) CompileError!void {
        const db = self.module.analysis_db orelse return;
        if (db.hoist_table.isEmpty()) return;
        if (self.loops.items.len == 0) return;
        const lc = &self.loops.items[self.loops.items.len - 1];
        var it = db.hoist_table.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != stmt) continue;
            const expr = entry.key_ptr.*;
            // 求值不变量表达式（emitExpr 入口查 hoisted_slots，但此时还没登记，正常求值）
            try self.emitExpr(expr);
            // 分配临时 slot 缓存结果（needs_release=true：位运算/比较结果可能是 Value 引用）
            const slot = try self.declareLocal("$hoist", false, true, null);
            try self.emitSlotOp(.op_set_local, slot, loc);
            try self.hoisted_slots.put(self.allocator, expr, slot);
            try lc.hoisted_exprs.append(self.allocator, expr);
        }
    }

    fn emitWhile(self: *FnCompiler, w: @TypeOf(@as(Stmt, undefined).while_stmt), stmt: *const Stmt) CompileError!void {
        // loop_start: cond; jump_if_false->end; pop cond(true); body; pop body; jump loop_start; end: pop cond(false)
        // 先 push LoopCtx（emitHoistedInvariants 往 hoisted_exprs 登记），continue_target 暂设 0，loop_start 定了再修正
        try self.loops.append(self.allocator, .{ .continue_target = 0, .defer_depth = self.defer_scopes.items.len });
        // 【LICM】在 loop_start 之前 hoist 不变量（循环前执行一次）
        try self.emitHoistedInvariants(stmt, w.location);
        const loop_start = self.chunk.here();
        self.loops.items[self.loops.items.len - 1].continue_target = loop_start;
        // continue 回跳到条件重新求值处（loop_start）。
        try self.emitExpr(w.condition);
        const exit_jump = try self.chunk.emitJump(.op_jump_if_false, w.location);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(true)
        try self.emitExprDiscard(w.body); // while 体值丢弃（block 无 trailing_expr 时省 op_unit+op_pop）
        try self.emitLoopBack(loop_start, w.location);
        self.chunk.patchJump(exit_jump);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(false)
        // break 跳到此处（cond 已弹，栈平衡）。
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        defer lc.hoisted_exprs.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
        // 【LICM】清理本循环的 hoisted_slots 映射（循环外引用同名表达式时不应读循环前缓存值）
        for (lc.hoisted_exprs.items) |e| _ = self.hoisted_slots.remove(e);
    }

    /// for x in iter { body }（M3d）：iter 求值存隐藏 slot，index slot 初始化 0；
    /// loop_start(=continue 目标): OP_FOR_NEXT iter,idx,exit → 耗尽跳 exit；否则压元素 → 绑 x → body → 弹 → 回跳。
    /// iter 支持 array/range/string（VM doForNext 运行时分派）。复用 break/continue 机制。
    fn emitFor(self: *FnCompiler, f: @TypeOf(@as(Stmt, undefined).for_stmt), stmt: *const Stmt) CompileError!void {
        // JIT Phase 4：小循环 + 常量 range → 展开（消除 op_for_next / 循环跳转开销）
        if (self.tryUnrollFor(f, stmt)) |_| {
            return;
        } else |_| {}
        const loc = f.location;
        const saved = self.locals.items.len;
        // 隐藏 slot：iterable 值 + index（i64，初始 0）。
        try self.emitExpr(f.iterable);
        const iter_slot = try self.declareLocal("$iter", false, true, null);
        try self.emitSlotOp(.op_set_local, iter_slot, loc);
        const idx_const = try self.chunk.addConstant(Value.fromInt(value.Int.fromNative(.i64, @as(i64, 0))));
        try self.emitConst(idx_const, loc);
        const idx_slot = try self.declareLocal("$idx", true, false, null);
        try self.emitSlotOp(.op_set_local, idx_slot, loc);
        // 循环变量 slot（每轮 OP_FOR_NEXT 压元素后 set_local 绑定）。
        const var_slot = try self.declareLocal(f.name, true, true, null);

        // 先 push LoopCtx（emitHoistedInvariants 往 hoisted_exprs 登记），continue_target 暂设 0
        try self.loops.append(self.allocator, .{ .continue_target = 0, .defer_depth = self.defer_scopes.items.len });
        // 【LICM】在 loop_start 之前 hoist 不变量（循环前执行一次）
        try self.emitHoistedInvariants(stmt, loc);
        const loop_start = self.chunk.here();
        self.loops.items[self.loops.items.len - 1].continue_target = loop_start;
        // OP_FOR_NEXT <iter_slot><idx_slot><i32 exit_off>：耗尽跳 exit；否则压当前元素 + idx++。
        try self.chunk.writeOp(.op_for_next, loc);
        try self.chunk.writeU16(iter_slot);
        try self.chunk.writeU16(idx_slot);
        const exit_at = self.chunk.here();
        try self.chunk.writeI32(0); // 占位，循环末回填
        // 绑定循环变量（弹元素写 var_slot）。
        try self.emitSlotOp(.op_set_local, var_slot, loc);
        // 循环体（值丢弃，block 无 trailing_expr 时省 op_unit+op_pop）。
        try self.emitExprDiscard(f.body);
        try self.emitLoopBack(loop_start, loc);
        // exit 落点：FOR_NEXT 耗尽跳到此（未压元素，栈平衡）。
        self.chunk.patchJump(exit_at);
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        defer lc.hoisted_exprs.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
        // 【LICM】清理 hoisted_slots 映射（须在 shrinkRetainingCapacity 前，避免 slot 被复用后误读）
        for (lc.hoisted_exprs.items) |e| _ = self.hoisted_slots.remove(e);
        self.locals.shrinkRetainingCapacity(saved);
    }

    /// 【JIT Phase 4】尝试展开常量 range 小循环。
    /// 条件：iterable 为 a..b / a..=b 且 a,b 均为编译期整常量；
    ///       循环体 is_small（≤32 估计指令）；迭代次数 1..=8；无 break/continue。
    /// 成功展开返回，失败返回 error.SkipUnroll（调用方回退到标准 emitFor）。
    const UnrollError = error{ SkipUnroll, OutOfMemory, Unsupported };

    fn tryUnrollFor(self: *FnCompiler, f: @TypeOf(@as(Stmt, undefined).for_stmt), stmt: *const Stmt) UnrollError!void {
        // 1. 检查循环体是否小到可展开
        const info = self.module.loopInfo(stmt) orelse return error.SkipUnroll;
        if (!info.is_small) return error.SkipUnroll;

        // 2. 检查 iterable 是否为 range / range_inclusive 二元表达式
        if (f.iterable.* != .binary) return error.SkipUnroll;
        const bin = f.iterable.binary;
        const is_inclusive = switch (bin.op) {
            .range => false,
            .range_inclusive => true,
            else => return error.SkipUnroll,
        };

        // 3. 查询上下界的常量值（必须为整常量）
        const start_cv = self.module.constValue(bin.left) orelse return error.SkipUnroll;
        const end_cv = self.module.constValue(bin.right) orelse return error.SkipUnroll;
        if (start_cv != .int_val or end_cv != .int_val) return error.SkipUnroll;

        // 4. 转为 i64 并计算迭代次数
        const start_i128 = start_cv.int_val;
        const end_i128 = end_cv.int_val;
        // 拒绝超出 i64 范围的常量（保守）
        if (start_i128 < std.math.minInt(i64) or start_i128 > std.math.maxInt(i64)) return error.SkipUnroll;
        if (end_i128 < std.math.minInt(i64) or end_i128 > std.math.maxInt(i64)) return error.SkipUnroll;
        const start: i64 = @intCast(start_i128);
        const end: i64 = @intCast(end_i128);

        const count: u64 = if (is_inclusive)
            if (end < start) 0 else @intCast(end - start + 1)
        else
            if (end <= start) 0 else @intCast(end - start);

        // 5. 安全限制：1..=16 次迭代（0 次 = 空循环直接跳过 body）
        if (count == 0) return; // 空循环：不发射任何指令（常量 range 无副作用）
        if (count > 16) return error.SkipUnroll;

        // 6. 检查 body 不含 break/continue（展开后跳转语义不兼容）
        if (exprHasBreakOrContinue(f.body)) return error.SkipUnroll;

        // 7. 展开：声明循环变量 slot，逐轮发射 const + set_local + body + pop
        const loc = f.location;
        const saved = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(saved);
        const var_slot = try self.declareLocal(f.name, true, true, null);

        var i: i64 = start;
        const last: i64 = if (is_inclusive) end else end - 1;
        while (i <= last) : (i += 1) {
            // 绑定循环变量 = i
            const val = Value.fromInt(value.Int.fromNative(.i64, i));
            const cidx = try self.chunk.addConstant(val);
            try self.emitConst(cidx, loc);
            try self.emitSlotOp(.op_set_local, var_slot, loc);
            // 循环体（值丢弃，block 无 trailing_expr 时省 op_unit+op_pop）
            try self.emitExprDiscard(f.body);
        }
    }

    /// 常量边界 while 循环完全展开。
    /// 识别模式：`while i < N { body; i = i + 1 }` 或 `while i <= N { body; i = i + 1 }`
    /// 其中 i 是 local identifier，初始值和 N 都是编译期整常量，步长 1。
    /// 迭代次数 ≤ 16 时完全展开；body 无 break/continue。
    /// 语义保持：循环变量 i 在展开每轮被设置为对应常量值，与运行时 `i = i + 1` 等价。
    fn tryUnrollWhile(self: *FnCompiler, w: @TypeOf(@as(Stmt, undefined).while_stmt), stmt: *const Stmt) UnrollError!void {
        // 1. 检查循环体是否小到可展开
        const info = self.module.loopInfo(stmt) orelse return error.SkipUnroll;
        if (!info.is_small) return error.SkipUnroll;

        // 2. 条件必须是 binary 比较运算 i < N 或 i <= N
        if (w.condition.* != .binary) return error.SkipUnroll;
        const cond_bin = w.condition.binary;
        const is_inclusive: bool = switch (cond_bin.op) {
            .lt => false,
            .lt_eq => true,
            else => return error.SkipUnroll,
        };

        // 3. 左操作数必须是 identifier（循环变量）
        if (cond_bin.left.* != .identifier) return error.SkipUnroll;
        const var_name = cond_bin.left.identifier.name;
        const var_slot = self.resolveLocal(var_name) orelse return error.SkipUnroll;

        // 4. 右操作数 N 必须是编译期整常量
        const n_cv = self.module.constValue(cond_bin.right) orelse return error.SkipUnroll;
        if (n_cv != .int_val) return error.SkipUnroll;
        if (n_cv.int_val < std.math.minInt(i64) or n_cv.int_val > std.math.maxInt(i64)) return error.SkipUnroll;
        const n_val: i64 = @intCast(n_cv.int_val);

        // 5. 循环变量 i 的初始值必须是编译期整常量（查 ConstTable 中 identifier 的值）
        const init_cv = self.module.constValue(cond_bin.left) orelse return error.SkipUnroll;
        if (init_cv != .int_val) return error.SkipUnroll;
        if (init_cv.int_val < std.math.minInt(i64) or init_cv.int_val > std.math.maxInt(i64)) return error.SkipUnroll;
        const init_val: i64 = @intCast(init_cv.int_val);

        // 6. 循环体必须是 block，且最后一个语句是 `i = i + 1`（步长 1 的自增）
        if (w.body.* != .block) return error.SkipUnroll;
        const body_block = w.body.block;
        if (body_block.statements.len == 0) return error.SkipUnroll;
        const last_stmt = body_block.statements[body_block.statements.len - 1];
        if (last_stmt.* != .assignment) return error.SkipUnroll;
        const last_assign = last_stmt.assignment;
        if (last_assign.target.* != .identifier) return error.SkipUnroll;
        if (!std.mem.eql(u8, last_assign.target.identifier.name, var_name)) return error.SkipUnroll;
        if (last_assign.value.* != .binary) return error.SkipUnroll;
        const step_bin = last_assign.value.binary;
        if (step_bin.op != .add) return error.SkipUnroll;
        // RHS 必须是整常量 1
        const step_cv = self.module.constValue(step_bin.right) orelse return error.SkipUnroll;
        if (step_cv != .int_val or step_cv.int_val != 1) return error.SkipUnroll;
        // LHS 必须是同一 identifier
        if (step_bin.left.* != .identifier) return error.SkipUnroll;
        if (!std.mem.eql(u8, step_bin.left.identifier.name, var_name)) return error.SkipUnroll;

        // 7. 计算迭代次数
        const count: u64 = if (is_inclusive)
            if (n_val < init_val) 0 else @intCast(n_val - init_val + 1)
        else
            if (n_val <= init_val) 0 else @intCast(n_val - init_val);

        if (count == 0) return; // 空循环：不发射任何指令
        if (count > 16) return error.SkipUnroll;

        // 8. body 不含 break/continue（步长语句本身的 assignment 不含）
        // 检查 body 除最后一句外的部分 + 最后一句
        if (exprHasBreakOrContinue(w.body)) return error.SkipUnroll;

        // 9. 展开：每轮设置 i = 当前值，执行 body（除最后一句自增），最后 pop body 值
        const loc = w.location;
        // body 去掉最后一句自增后的"有效部分"——直接逐轮发射
        var iter: i64 = init_val;
        const last_iter: i64 = if (is_inclusive) n_val else n_val - 1;
        while (iter <= last_iter) : (iter += 1) {
            // 绑定循环变量 = iter
            const val = Value.fromInt(value.Int.fromNative(.i64, iter));
            const cidx = try self.chunk.addConstant(val);
            try self.emitConst(cidx, loc);
            try self.emitSlotOp(.op_set_local, var_slot, loc);
            // 执行 body 中除最后一句自增外的所有语句
            for (body_block.statements[0 .. body_block.statements.len - 1]) |s| {
                try self.emitStmt(s);
            }
            // body 的 trailing_expr（若有）求值后丢弃
            if (body_block.trailing_expr) |te| {
                try self.emitExpr(te);
                try self.chunk.writeOp(.op_pop, loc);
            }
            // 无 trailing_expr：省略 op_unit + op_pop（结果丢弃，不入栈则无需 pop）
        }
    }

    /// loop { body }：无限循环，仅 break 退出。
    /// loop_start: body; pop body; jump loop_start; end:(break 落点)
    fn emitLoop(self: *FnCompiler, l: @TypeOf(@as(Stmt, undefined).loop_stmt), stmt: *const Stmt) CompileError!void {
        // 先 push LoopCtx（emitHoistedInvariants 往 hoisted_exprs 登记），continue_target 暂设 0
        try self.loops.append(self.allocator, .{ .continue_target = 0, .defer_depth = self.defer_scopes.items.len });
        // 【LICM】在 loop_start 之前 hoist 不变量（循环前执行一次）
        try self.emitHoistedInvariants(stmt, l.location);
        const loop_start = self.chunk.here();
        self.loops.items[self.loops.items.len - 1].continue_target = loop_start;
        try self.emitExprDiscard(l.body); // 弹 body 值（block 无 trailing_expr 时省 op_unit+op_pop）
        try self.emitLoopBack(loop_start, l.location);
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        defer lc.hoisted_exprs.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
        // 【LICM】清理本循环的 hoisted_slots 映射
        for (lc.hoisted_exprs.items) |e| _ = self.hoisted_slots.remove(e);
    }

    /// 复合赋值 x op= v → x = x op v（local/upvalue target）。Atomic 透明操作留 M4。
    fn emitCompoundAssign(self: *FnCompiler, ca: @TypeOf(@as(Stmt, undefined).compound_assignment)) CompileError!void {
        if (ca.target.* != .identifier) return error.Unsupported;
        const name = ca.target.identifier.name;
        const bin_op: ast.BinaryOp = switch (ca.op) {
            .add_assign => .add,
            .sub_assign => .sub,
            .mul_assign => .mul,
            .div_assign => .div,
            .mod_assign => .mod,
            .bit_and_assign => .bit_and,
            .bit_or_assign => .bit_or,
        };
        const arith: OpCode = switch (bin_op) {
            .add => .op_add, .sub => .op_sub, .mul => .op_mul, .div => .op_div, .mod => .op_mod,
            .bit_and => .op_bit_and, .bit_or => .op_bit_or, else => unreachable,
        };
        if (self.resolveLocal(name)) |slot| {
            // M4a：OP_COMPOUND_LOCAL 运行时分派 —— slot 持 atomic 则原子 fetch<op>，否则常规读改写。
            try self.emitExpr(ca.value); // rhs
            try self.chunk.writeOp(.op_compound_local, ca.location);
            try self.chunk.writeU16(slot);
            try self.chunk.writeByte(@intFromEnum(arith));
        } else if (try self.resolveUpvalue(name)) |uv| {
            // M4c：OP_COMPOUND_UPVALUE 运行时分派 —— cell.inner 持 atomic 则原子 fetch<op>，否则常规读改写。
            // spawn body 捕获的 Atomic 复合赋值（counter += 1）必经此路，不可退化为标量覆盖。
            try self.emitExpr(ca.value); // rhs
            try self.chunk.writeOp(.op_compound_upvalue, ca.location);
            try self.chunk.writeU16(uv);
            try self.chunk.writeByte(@intFromEnum(arith));
        } else if (self.module.lookupGlobal(name)) |ge| {
            // M5g：顶层 var 复合赋值 g op= v → g = g op v（读改写，无 atomic 透明：顶层全局非 spawn 捕获）。
            try self.chunk.writeOp(.op_get_global, ca.location);
            try self.chunk.writeU16(ge.idx);
            try self.emitExpr(ca.value);
            try self.chunk.writeOp(arith, ca.location);
            try self.chunk.writeOp(.op_set_global, ca.location);
            try self.chunk.writeU16(ge.idx);
        } else return error.Unsupported;
    }

    /// 字段赋值 obj.f = v。镜像 eval：identifier 目标 COW 后写回绑定槽。
    /// OP_SET_FIELD 栈效果 [record, val] → [new_record]（COW 产新 record 或原地改）。
    /// identifier target：GET_LOCAL → val → SET_FIELD → SET_LOCAL 写回。
    /// 其它（临时对象）：obj → val → SET_FIELD → POP 丢弃。
    fn emitFieldAssign(self: *FnCompiler, fa: @TypeOf(@as(Stmt, undefined).field_assignment)) CompileError!void {
        const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, fa.field));
        if (fa.object.* == .identifier) {
            const oname = fa.object.identifier.name;
            if (self.resolveLocal(oname)) |slot| {
                try self.emitSlotOp(.op_get_local, slot, fa.location);
                try self.emitExpr(fa.value);
                try self.chunk.writeOp(.op_set_field, fa.location);
                try self.chunk.writeU16(name_const);
                try self.emitSlotOp(.op_set_local, slot, fa.location);
                return;
            } else if (try self.resolveUpvalue(oname)) |uv| {
                try self.emitSlotOp(.op_get_upvalue, uv, fa.location);
                try self.emitExpr(fa.value);
                try self.chunk.writeOp(.op_set_field, fa.location);
                try self.chunk.writeU16(name_const);
                try self.emitSlotOp(.op_set_upvalue, uv, fa.location);
                return;
            } else if (self.module.lookupGlobal(oname)) |ge| {
                // M5g：顶层 var 记录字段赋值 g.f = v（COW 写回全局槽）。
                try self.chunk.writeOp(.op_get_global, fa.location);
                try self.chunk.writeU16(ge.idx);
                try self.emitExpr(fa.value);
                try self.chunk.writeOp(.op_set_field, fa.location);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeOp(.op_set_global, fa.location);
                try self.chunk.writeU16(ge.idx);
                return;
            }
        }
        // 临时对象：改动随即丢弃（与 eval else 分支语义一致）。
        try self.emitExpr(fa.object);
        try self.emitExpr(fa.value);
        try self.chunk.writeOp(.op_set_field, fa.location);
        try self.chunk.writeU16(name_const);
        try self.chunk.writeOp(.op_pop, fa.location);
    }

    /// 索引赋值 arr[i] = v。镜像 eval assignment 的 .index 分支：identifier 数组目标 COW 后写回绑定槽。
    /// OP_SET_INDEX 栈效果 [array, index, val] → [new_array]（COW 产新 array 或原地改）。
    /// identifier target：GET_LOCAL → index → val → SET_INDEX → SET_LOCAL 写回。
    /// 其它（临时对象）：obj → index → val → SET_INDEX → POP 丢弃。
    fn emitIndexAssign(self: *FnCompiler, idx: @TypeOf(@as(Expr, undefined).index), rhs: *Expr, loc: ast.SourceLocation) CompileError!void {
        if (idx.object.* == .identifier) {
            const oname = idx.object.identifier.name;
            if (self.resolveLocal(oname)) |slot| {
                try self.emitSlotOp(.op_get_local, slot, loc);
                try self.emitExpr(idx.index);
                try self.emitExpr(rhs);
                try self.chunk.writeOp(.op_set_index, loc);
                try self.emitSlotOp(.op_set_local, slot, loc);
                return;
            } else if (try self.resolveUpvalue(oname)) |uv| {
                try self.emitSlotOp(.op_get_upvalue, uv, loc);
                try self.emitExpr(idx.index);
                try self.emitExpr(rhs);
                try self.chunk.writeOp(.op_set_index, loc);
                try self.emitSlotOp(.op_set_upvalue, uv, loc);
                return;
            } else if (self.module.lookupGlobal(oname)) |ge| {
                // M5g：顶层 var 数组元素赋值 g[i] = v（COW 写回全局槽）。
                try self.chunk.writeOp(.op_get_global, loc);
                try self.chunk.writeU16(ge.idx);
                try self.emitExpr(idx.index);
                try self.emitExpr(rhs);
                try self.chunk.writeOp(.op_set_index, loc);
                try self.chunk.writeOp(.op_set_global, loc);
                try self.chunk.writeU16(ge.idx);
                return;
            }
        }
        // 临时对象：改动随即丢弃。
        try self.emitExpr(idx.object);
        try self.emitExpr(idx.index);
        try self.emitExpr(rhs);
        try self.chunk.writeOp(.op_set_index, loc);
        try self.chunk.writeOp(.op_pop, loc);
    }

    /// 回跳到 target（已知地址，在当前指令之前）的无条件 jump。
    fn emitLoopBack(self: *FnCompiler, target: usize, loc: ast.SourceLocation) CompileError!void {
        try self.chunk.writeOp(.op_jump, loc);
        const operand_at = self.chunk.here();
        const after = operand_at + 4; // 相对基准 = 立即数之后，与解码 ip 一致
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(after)));
        try self.chunk.writeI32(rel);
    }
};

/// 软件解析整数字面量字符串 → Int（不依赖 u128/i128）。
/// 支持符号（+/-）、进制前缀（0x/0o/0b）、下划线。不处理类型后缀。
fn parseIntSoftware(raw: []const u8) ?value.Int {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    var base: u8 = 10;
    if (s.len > 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => { base = 16; s = s[2..]; },
            'o', 'O' => { base = 8; s = s[2..]; },
            'b', 'B' => { base = 2; s = s[2..]; },
            else => {},
        }
    }
    var digits: [128]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= digits.len) return null;
        digits[n] = c;
        n += 1;
    }
    if (n == 0) return null;

    var buf: [16]u8 = undefined;
    _ = value.int.parseUnsignedBytes(&buf, digits[0..n], base) orelse return null;

    const t = value.inferIntTypeBytes(&buf, negative);

    if (negative) {
        // 补码取负：~buf + 1（16 字节全量，自动符号扩展）
        var carry: u16 = 1;
        for (buf[0..16]) |*b| {
            const inv: u16 = ~b.*;
            const sum = inv + carry;
            b.* = @truncate(sum);
            carry = sum >> 8;
        }
    }

    return value.Int.fromBytes(t, &buf);
}

/// 解析整数字面量为 Value（镜像 eval.zig evalIntLiteral 的默认最小类型推断）。
/// 全软件：用 parseIntSoftware（不依赖 u128/i128）。
fn parseIntLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(Expr, undefined).int_literal)) !?Value {
    _ = allocator;

    if (lit.suffix) |s| {
        const target = value.IntType.fromName(s) orelse return null;
        // 有后缀：解析后用 coerceTo 检查范围
        const parsed = parseIntSoftware(lit.raw) orelse return null;
        const coerced = parsed.coerceTo(target) orelse return null;
        return Value.fromInt(coerced);
    }

    // 无后缀：类型推断
    const parsed = parseIntSoftware(lit.raw) orelse return null;
    return Value.fromInt(parsed);
}

/// 软件解析浮点字面量字符串 → Float(.f128)（不依赖 f128 原生算术）。
/// 支持符号、小数点、十进制指数（e/E）、下划线。
/// 算法：解析为 digits + decimal_exp，digits 解析为 u128 Int，fromInt 转 f128，
/// 再用快速幂乘/除 10^|decimal_exp|，最后应用符号。全精度，不丢精度。
fn parseFloatSoftware(raw: []const u8) ?value.Float {
    var s = raw;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;

    // 找 e/E 分割尾数和指数
    var e_pos: usize = s.len;
    for (s, 0..) |c, i| {
        if (c == 'e' or c == 'E') {
            e_pos = i;
            break;
        }
    }
    const mantissa_str = s[0..e_pos];
    const exp_str = if (e_pos < s.len) s[e_pos + 1 ..] else "";

    // 解析十进制指数
    var exp: i32 = 0;
    if (exp_str.len > 0) {
        exp = std.fmt.parseInt(i32, exp_str, 10) catch return null;
    }

    // 分割整数/小数部分
    var int_part: []const u8 = "";
    var frac_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, mantissa_str, '.')) |dot_pos| {
        int_part = mantissa_str[0..dot_pos];
        frac_part = mantissa_str[dot_pos + 1 ..];
    } else {
        int_part = mantissa_str;
    }

    // 合并数字（去除下划线），记录小数位数
    var digits_buf: [128]u8 = undefined;
    var digits_len: usize = 0;
    var frac_digit_count: i32 = 0;
    for (int_part) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') return null;
        if (digits_len >= digits_buf.len) return null;
        digits_buf[digits_len] = c;
        digits_len += 1;
    }
    for (frac_part) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') return null;
        if (digits_len >= digits_buf.len) return null;
        digits_buf[digits_len] = c;
        digits_len += 1;
        frac_digit_count += 1;
    }

    if (digits_len == 0) return null;

    // 十进制指数 = 字面指数 - 小数位数
    var decimal_exp = exp - frac_digit_count;

    // 去除前导零（不影响 decimal_exp）
    var start: usize = 0;
    while (start < digits_len and digits_buf[start] == '0') start += 1;
    if (start == digits_len) {
        // 全零：值为 0
        var z = value.Float.zero(.f128);
        if (negative) z = z.negate();
        return z;
    }

    // 去除尾随零（每去一个，decimal_exp += 1）
    var end: usize = digits_len;
    while (end > start and digits_buf[end - 1] == '0') {
        end -= 1;
        decimal_exp += 1;
    }

    const digits = digits_buf[start..end];

    // 解析 digits 为 Int(.u128)（u128 最大 39 位十进制）
    // 如果 digits 太长，截断到 39 位并四舍五入（f128 也只能保留 ~34 位有效十进制）
    var int_val: value.Int = undefined;
    if (digits.len <= 39) {
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
    } else {
        const trunc_len: usize = 39;
        var trunc_digits: [39]u8 = undefined;
        @memcpy(&trunc_digits, digits[0..trunc_len]);
        // 四舍五入：第 40 位 >= '5' 则进位
        if (digits[trunc_len] >= '5') {
            var i: usize = trunc_len;
            while (i > 0) {
                i -= 1;
                if (trunc_digits[i] < '9') {
                    trunc_digits[i] += 1;
                    break;
                }
                trunc_digits[i] = '0';
            }
            if (i == 0 and trunc_digits[0] == '0') {
                // 全进位：999...9 + 1 = 1000...0
                trunc_digits[0] = '1';
                decimal_exp += 1;
            }
        }
        var buf: [16]u8 = undefined;
        _ = value.int.parseUnsignedBytes(&buf, &trunc_digits, 10) orelse return null;
        int_val = value.Int.fromBytes(.u128, &buf);
        decimal_exp += @as(i32, @intCast(digits.len - trunc_len));
    }

    // 转换为 f128
    var result = value.Float.fromInt(.f128, int_val);

    // 应用十进制指数（快速幂）
    if (decimal_exp != 0) {
        result = applyDecimalExp(result, decimal_exp);
        if (result.isInfinite() or result.isNan()) return null;
    }

    // 应用符号
    if (negative) result = result.negate();

    return result;
}

/// 计算 float × 10^exp（快速幂，软件 f128 乘除法，不依赖 f128 原生算术）。
fn applyDecimalExp(base: value.Float, exp: i32) value.Float {
    if (exp == 0) return base;
    const ten = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 10)));
    const abs_e: u32 = @intCast(if (exp < 0) -exp else exp);

    // 快速幂计算 10^abs_e
    var ten_pow = value.Float.fromInt(.f128, value.Int.fromNative(.i8, @as(i8, 1)));
    var factor = ten;
    var bits = abs_e;
    while (bits > 0) {
        if (bits & 1 == 1) ten_pow = ten_pow.multiply(factor);
        bits >>= 1;
        if (bits > 0) factor = factor.multiply(factor);
    }

    if (exp > 0) {
        return base.multiply(ten_pow);
    } else {
        return base.divide(ten_pow);
    }
}

fn parseFloatLiteral(allocator: std.mem.Allocator, lit: @TypeOf(@as(Expr, undefined).float_literal)) !?Value {
    _ = allocator;
    const fv = parseFloatSoftware(lit.raw) orelse return null;
    if (fv.isNan() or fv.isInfinite()) return null;
    if (lit.suffix) |s| {
        const t = value.FloatType.fromName(s) orelse return null;
        const result = fv.toFloatType(t);
        if (result.isInfinite()) return null; // 溢出
        return Value.fromFloat(result);
    }
    // 默认使用 f64
    return Value.fromFloat(fv.toFloatType(.f64));
}

/// M5：builtin 数值类型名判定（隐式定型只协调这些）。bool/str 不在内——它们不参与整数宽度
/// 推断/算术提升，且 castNumeric 不处理；eval 对 bool/str 的隐式协调亦无数值语义影响。
fn isBuiltinNumericType(name: []const u8) bool {
    const nums = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "f16", "f32", "f64", "f128",
    };
    for (nums) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// 【JIT Phase 3】检查函数所有参数是否可安全 memoize。
/// 所有类型（含无类型注解的参数）均允许——hashValueRecursive 基于运行时 Value
/// 按内容递归 hash，引用类型在 VM 运行时守卫中跳过。此函数保留为 noop，未来可加编译期过滤。
fn allParamsMemoizable(param_types: []const ?[]const u8) bool {
    _ = param_types;
    return true;
}

/// 从类型注解提取命名类型名（用于 declareLocal 的 builtin_type 字段与 memoization 类型检查）。
/// 返回任意 .named 类型名（含 i64/f64/bool/char/str 及用户自定义 ADT/record/newtype）。
/// 非命名类型（函数类型、泛型应用等）返回 null。
/// 【P1-6】扩展为任意命名类型：memoization 的 hashValueRecursive 按值 hash 复合类型，
/// 安全支持 ADT/record/array 参数；coercion 路径有 isBuiltinNumericType 守卫，不受影响。
fn builtinTypeOf(ta: ?*const ast.TypeNode) ?[]const u8 {
    const t = ta orelse return null;
    return switch (t.*) {
        .named => |n| n.name,
        else => null,
    };
}

/// 从形参列表提取基础类型名数组。
fn extractParamTypes(allocator: std.mem.Allocator, params: []const ast.Param) ![]const ?[]const u8 {
    const result = try allocator.alloc(?[]const u8, params.len);
    for (params, 0..) |p, i| result[i] = builtinTypeOf(p.type_annotation);
    return result;
}

/// 【内联】统计 Expr 的 AST 节点数（递归，用于判断可内联性）。
/// 阈值 32：覆盖简单算术/match/字段访问，排除复杂函数体。
fn countExprNodes(expr: *const ast.Expr) u32 {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal, .string_literal, .string_interpolation, .identifier => 1,
        .lambda, .spawn, .atomic_expr, .lazy, .select => 99, // 闭包/协程/并发原语不可内联
        .binary => |b| 1 + countExprNodes(b.left) + countExprNodes(b.right),
        .unary => |u| 1 + countExprNodes(u.operand),
        .call => |c| 1 + countExprNodes(c.callee) + blk: {
            var n: u32 = 0;
            for (c.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .if_expr => |ie| 1 + countExprNodes(ie.condition) + countExprNodes(ie.then_branch) + (if (ie.else_branch) |eb| countExprNodes(eb) else 0),
        .match => |m| blk: {
            var n: u32 = 1;
            n += countExprNodes(m.scrutinee);
            for (m.arms) |arm| n += countExprNodes(arm.body) + (if (arm.guard) |g| countExprNodes(g) else 0);
            break :blk n;
        },
        .block => |blk| blk: {
            var n: u32 = 1;
            for (blk.statements) |s| n += countStmtNodes(s);
            if (blk.trailing_expr) |te| n += countExprNodes(te);
            break :blk n;
        },
        .field_access => |fa| 1 + countExprNodes(fa.object),
        .method_call => |mc| blk: {
            var n: u32 = 1 + countExprNodes(mc.object);
            for (mc.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .index => |ix| 1 + countExprNodes(ix.object) + countExprNodes(ix.index),
        .type_cast => |tc| 1 + countExprNodes(tc.expr),
        .non_null_assert => |nna| 1 + countExprNodes(nna.expr),
        .safe_access => |sa| 1 + countExprNodes(sa.object),
        .safe_method_call => |smc| blk: {
            var n: u32 = 1 + countExprNodes(smc.object);
            for (smc.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .record_extend => |re| blk: {
            var n: u32 = 1 + countExprNodes(re.base);
            for (re.updates) |u| n += countExprNodes(u.value);
            break :blk n;
        },
        .propagate => |p| 1 + countExprNodes(p.expr),
        else => 99, // 未覆盖的变体保守视为不可内联
    };
}

fn countStmtNodes(stmt: *const ast.Stmt) u32 {
    return switch (stmt.*) {
        .val_decl => |d| 1 + countExprNodes(d.value),
        .expression => |e| 1 + countExprNodes(e.expr),
        .assignment => |a| 1 + countExprNodes(a.value),
        else => 1, // return/throw/break/continue/defer 等控制流：保守计 1
    };
}

/// 【内联】判断函数是否可内联：arity ≤ 4 + body 节点数 ≤ 32 + 非递归 + 无控制流。
/// 控制流（return/throw/break/continue/propagate）跨函数边界内联会改变语义，必须排除。
fn canInlineFn(name: []const u8, arity: usize, body: *const ast.Expr) bool {
    if (arity > 4) return false;
    if (countExprNodes(body) > 32) return false;
    if (hasControlFlow(body)) return false;
    return !callsSelf(body, name);
}

/// 【内联】检查 Expr 是否含控制流 Stmt（return/throw/break/continue）或 propagate 表达式。
/// 这些跨函数边界内联会改变异常传播/返回语义，必须排除。
fn hasControlFlow(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .propagate => true,
        .binary => |b| hasControlFlow(b.left) or hasControlFlow(b.right),
        .unary => |u| hasControlFlow(u.operand),
        .call => |c| blk: {
            if (hasControlFlow(c.callee)) break :blk true;
            for (c.arguments) |a| if (hasControlFlow(a)) break :blk true;
            break :blk false;
        },
        .if_expr => |ie| hasControlFlow(ie.condition) or hasControlFlow(ie.then_branch) or (if (ie.else_branch) |eb| hasControlFlow(eb) else false),
        .match => |m| blk: {
            if (hasControlFlow(m.scrutinee)) break :blk true;
            for (m.arms) |arm| {
                if (hasControlFlow(arm.body)) break :blk true;
                if (arm.guard) |g| if (hasControlFlow(g)) break :blk true;
            }
            break :blk false;
        },
        .block => |blk| blk: {
            for (blk.statements) |s| if (hasControlFlowStmt(s)) break :blk true;
            if (blk.trailing_expr) |te| if (hasControlFlow(te)) break :blk true;
            break :blk false;
        },
        .field_access => |fa| hasControlFlow(fa.object),
        .method_call => |mc| blk: {
            if (hasControlFlow(mc.object)) break :blk true;
            for (mc.arguments) |a| if (hasControlFlow(a)) break :blk true;
            break :blk false;
        },
        .index => |ix| hasControlFlow(ix.object) or hasControlFlow(ix.index),
        .type_cast => |tc| hasControlFlow(tc.expr),
        .non_null_assert => |nna| hasControlFlow(nna.expr),
        .safe_access => |sa| hasControlFlow(sa.object),
        .safe_method_call => |smc| blk: {
            if (hasControlFlow(smc.object)) break :blk true;
            for (smc.arguments) |a| if (hasControlFlow(a)) break :blk true;
            break :blk false;
        },
        .record_extend => |re| blk: {
            if (hasControlFlow(re.base)) break :blk true;
            for (re.updates) |u| if (hasControlFlow(u.value)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn hasControlFlowStmt(stmt: *const ast.Stmt) bool {
    return switch (stmt.*) {
        .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
        .val_decl => |d| hasControlFlow(d.value),
        .expression => |e| hasControlFlow(e.expr),
        .assignment => |a| hasControlFlow(a.value),
        else => false,
    };
}

/// 【内联】检查 Expr 是否调用指定函数名（递归）。null name 时检查所有 call（保守起见见下方）。
fn callsSelf(expr: *const ast.Expr, name: ?[]const u8) bool {
    return switch (expr.*) {
        .call => |c| blk: {
            if (c.callee.* == .identifier) {
                if (name) |n| {
                    if (std.mem.eql(u8, n, c.callee.identifier.name)) break :blk true;
                }
            }
            // 检查 callee + args
            if (callsSelf(c.callee, name)) break :blk true;
            for (c.arguments) |a| {
                if (callsSelf(a, name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| callsSelf(b.left, name) or callsSelf(b.right, name),
        .unary => |u| callsSelf(u.operand, name),
        .if_expr => |ie| callsSelf(ie.condition, name) or callsSelf(ie.then_branch, name) or (if (ie.else_branch) |eb| callsSelf(eb, name) else false),
        .match => |m| blk: {
            if (callsSelf(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (callsSelf(arm.body, name)) break :blk true;
                if (arm.guard) |g| if (callsSelf(g, name)) break :blk true;
            }
            break :blk false;
        },
        .block => |blk| blk: {
            for (blk.statements) |s| {
                if (callsSelfStmt(s, name)) break :blk true;
            }
            if (blk.trailing_expr) |te| if (callsSelf(te, name)) break :blk true;
            break :blk false;
        },
        .field_access => |fa| callsSelf(fa.object, name),
        .method_call => |mc| blk: {
            if (callsSelf(mc.object, name)) break :blk true;
            for (mc.arguments) |a| if (callsSelf(a, name)) break :blk true;
            break :blk false;
        },
        .index => |ix| callsSelf(ix.object, name) or callsSelf(ix.index, name),
        .type_cast => |tc| callsSelf(tc.expr, name),
        .non_null_assert => |nna| callsSelf(nna.expr, name),
        .safe_access => |sa| callsSelf(sa.object, name),
        .safe_method_call => |smc| blk: {
            if (callsSelf(smc.object, name)) break :blk true;
            for (smc.arguments) |a| if (callsSelf(a, name)) break :blk true;
            break :blk false;
        },
        .record_extend => |re| blk: {
            if (callsSelf(re.base, name)) break :blk true;
            for (re.updates) |u| if (callsSelf(u.value, name)) break :blk true;
            break :blk false;
        },
        .propagate => |p| callsSelf(p.expr, name),
        else => false,
    };
}

fn callsSelfStmt(stmt: *const ast.Stmt, name: ?[]const u8) bool {
    return switch (stmt.*) {
        .val_decl => |d| callsSelf(d.value, name),
        .expression => |e| callsSelf(e.expr, name),
        .assignment => |a| callsSelf(a.value, name),
        else => false,
    };
}

/// 判断二元运算符是否为算术运算（结果类型 = 左操作数类型）。
fn isArithmeticOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

/// 判断类型注解对应的值是否需要 release（boxed）。
/// null（无注解）→ true（保守）；builtin 数值/bool/char/unit → false（内联）；其他 → true。
fn typeNeedsRelease(ty: ?*const ast.TypeNode) bool {
    const t = ty orelse return true;
    return switch (t.*) {
        .named => |n| blk: {
            if (isBuiltinNumericType(n.name)) break :blk false;
            if (std.mem.eql(u8, n.name, "bool")) break :blk false;
            if (std.mem.eql(u8, n.name, "char")) break :blk false;
            if (std.mem.eql(u8, n.name, "unit")) break :blk false;
            break :blk true;
        },
        .self_type, .generic, .nullable, .function, .record, .array, .kind_annotated => true,
    };
}

/// M5c：若 TypeNode 是 builtin 数值类型，返回其名（借用 AST 字节）；否则 null。
/// 供 ADT 字段隐式定型用（仅数值字段需协调 type_tag）。
fn builtinNumericTypeOf(ty: *const ast.TypeNode) ?[]const u8 {
    return switch (ty.*) {
        .named => |n| if (isBuiltinNumericType(n.name)) n.name else null,
        else => null,
    };
}

/// 模式字面量 → Value 常量（供 OP_TEST_LIT 比较）。int 软件解析存为 i64
/// （与 OP_TEST_LIT 仅比值忽略 tag 一致）。string 须 dupe（常量池随 chunk deinit 释放）。
/// 不支持的字面量（解析失败）返回 null → 调用方 Unsupported（回退树遍历器）。
/// 注：pattern 的 int/float 原始文本含类型后缀（如 "1i64"/"2.0f32"），须剥离后再 parse。
fn patternLiteralToValue(allocator: std.mem.Allocator, lit: ast.PatternLiteral) CompileError!?Value {
    return switch (lit) {
        .int => |raw| blk: {
            const iv = parsePatternInt(raw) orelse break :blk null;
            break :blk Value.fromInt(iv);
        },
        .float => |raw| blk: {
            const end = floatBodyEnd(raw);
            const fv = std.fmt.parseFloat(f64, raw[0..end]) catch break :blk null;
            break :blk Value.fromFloat(value.Float.fromNative(.f64, fv));
        },
        .bool => |b| Value.fromBool(b),
        .char => |c| Value.fromChar(value.Char.fromNative(c) catch unreachable),
        .string => |s| try Value.fromStringBytes(allocator, s),
        .null => Value.fromNull(),
    };
}

/// 剥离 float 后缀（f32/f64），返回数值正文末尾索引。
fn floatBodyEnd(raw: []const u8) usize {
    var end = raw.len;
    var j = end;
    while (j > 0 and raw[j - 1] >= '0' and raw[j - 1] <= '9') j -= 1;
    if (j > 0 and j < end and (raw[j - 1] == 'f' or raw[j - 1] == 'F')) end = j - 1;
    return end;
}

/// 解析 pattern 整数字面量（含进制前缀 0x/0o/0b、i/u 类型后缀、下划线），返回 i64 Int。
/// 全软件：用 parseIntSoftware（不依赖 u128/i128）。
fn parsePatternInt(raw: []const u8) ?value.Int {
    // 剥离 i/u 类型后缀（仅 i/u 后跟十进制数字，避免误剥十六进制 A–F）
    var end = raw.len;
    var j = end;
    while (j > 0 and raw[j - 1] >= '0' and raw[j - 1] <= '9') j -= 1;
    if (j > 0 and j < end and (raw[j - 1] == 'i' or raw[j - 1] == 'u' or raw[j - 1] == 'I' or raw[j - 1] == 'U')) {
        end = j - 1;
    }
    const parsed = parseIntSoftware(raw[0..end]) orelse return null;
    // Pattern ints 存为 i64（截取低 8 字节，与旧代码行为一致）
    return .{ .type = .i64, .lo = parsed.lo, .hi = 0 };
}

// ============================================================
// 测试
// ============================================================

test {
    std.testing.refAllDecls(@import("disasm.zig"));
    std.testing.refAllDecls(@import("cast.zig"));
    std.testing.refAllDecls(@import("method.zig"));
}