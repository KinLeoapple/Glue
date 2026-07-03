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
const type_table_mod = @import("type_table");
const analysis_db_mod = @import("analysis_db");

/// 公开再导出，供 bench 驱动 / 外部入口通过本模块拿到 VM 与 Program（避免新建 build 图模块）。
pub const VM = @import("vm.zig").VM;
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
};

/// 闭包 upvalue 描述符（clox 风格静态解析）。
/// is_local=true：捕获 enclosing 帧的 local[index]；false：捕获 enclosing 闭包的 upvalue[index]。
const Upvalue = struct {
    name: []const u8,
    index: u16,
    is_local: bool,
};

/// 循环上下文（M3b）：break/continue 跳转回填。
/// continue_target：continue 回跳的绝对地址（while=条件起点，loop=体起点）。
/// breaks：本循环内所有 break 的 OP_JUMP 占位待回填到循环末尾。
const LoopCtx = struct {
    continue_target: usize,
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    /// 进入循环时的 defer 作用域深度。break/continue 须重放循环体内（深度 ≥ 此值）的 defer。
    defer_depth: usize = 0,
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
    /// 【JIT Phase 1】类型表引用（null = 禁用特化，发射通用 opcode）。
    /// 由 main.zig 在编译前从 TypeInferencer.type_table 设置。
    type_table: ?*const type_table_mod.TypeTable = null,
    /// 【JIT Phase 2】分析数据库引用（null = 禁用所有优化）。
    /// 优先使用 analysis_db，type_table 作为 Phase 1 向后兼容回退。
    analysis_db: ?*const analysis_db_mod.AnalysisDB = null,
    /// 【JIT Phase 3】memoization slot 分配计数器。
    /// 每个发射的 op_call_memoized 调用点分配唯一 slot，VM 用此索引 memo_cache。
    next_memo_slot: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) ModuleCompiler {
        return .{ .program = Program.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *ModuleCompiler) void {
        self.fn_table.deinit(self.allocator);
        self.ctor_table.deinit(self.allocator);
        self.newtype_table.deinit(self.allocator);
        self.error_table.deinit(self.allocator);
        self.global_table.deinit(self.allocator);
        self.method_names.deinit(self.allocator);
        self.nullary_methods.deinit(self.allocator);
        self.module_values.deinit(self.allocator);
        // program 所有权移交调用方；此处不 deinit。
    }

    pub fn lookupFn(self: *ModuleCompiler, name: []const u8) ?u16 {
        for (self.fn_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.idx;
        }
        return null;
    }

    /// 查 ADT 构造器登记（裸名构造器调用 / match constructor pattern 用）。
    pub fn lookupCtor(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        for (self.ctor_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// 查 newtype 构造器登记（裸名 newtype 构造 / match newtype pattern 用）。
    pub fn lookupNewtype(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        for (self.newtype_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// 查自定义错误类型构造器登记（裸名 ErrorType("msg") 调用用）。
    pub fn lookupError(self: *ModuleCompiler, name: []const u8) ?CtorEntry {
        for (self.error_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// 查顶层全局变量登记（自由标识符 / 赋值目标解析用）。
    pub fn lookupGlobal(self: *ModuleCompiler, name: []const u8) ?GlobalEntry {
        for (self.global_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// M5i：登记一个 trait 方法名（去重）。
    fn registerMethodName(self: *ModuleCompiler, name: []const u8) CompileError!void {
        for (self.method_names.items) |n| if (std.mem.eql(u8, n, name)) return;
        try self.method_names.append(self.allocator, name);
    }

    /// M5i：name 是否为已知 trait 方法名（裸名调用作自由函数 trait 方法分派判定用）。
    pub fn isMethodName(self: *ModuleCompiler, name: []const u8) bool {
        for (self.method_names.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// 查顶层函数的 (idx, arity)，供尾调用合格性判定（argc==arity 才发 OP_TAIL_CALL）。
    pub fn lookupFnEntry(self: *ModuleCompiler, name: []const u8) ?FnEntry {
        for (self.fn_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// 【JIT Phase 2】查询表达式类型种类（优先从 analysis_db，回退到 type_table）
    pub fn exprTypeKind(self: *const ModuleCompiler, expr: *const ast.Expr) ?type_table_mod.TypeKind {
        if (self.analysis_db) |db| {
            if (db.type_table) |tt| return tt.lookup(expr);
        }
        if (self.type_table) |tt| return tt.lookup(expr);
        return null;
    }

    /// 【JIT Phase 2】查询函数是否纯（用于 memoization 决策）
    pub fn isPureFn(self: *const ModuleCompiler, name: []const u8) bool {
        if (self.analysis_db) |db| {
            return db.purity.isPure(name);
        }
        return false;
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

    /// 【JIT Phase 3】获取或分配纯函数的 memo_slot（per-function，所有调用点共享）。
    /// 返回 null 表示该函数不是纯函数、未注册、或参数含非原始类型（不可安全 memoize）。
    /// 仅当所有参数类型为基础类型（数值/bool/char/str）时才分配 slot，
    /// 因为 hashArgs 对装箱复合类型（ADT/record/array）按指针 hash，会导致错误命中。
    pub fn getOrAssignMemoSlot(self: *ModuleCompiler, name: []const u8) ?u16 {
        if (!self.isPureFn(name)) return null;
        for (self.fn_table.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                // 安全检查：所有参数必须为基础类型（可按值 hash）
                if (!allParamsMemoizable(entry.param_types)) return null;
                if (entry.memo_slot == 0xFFFF) {
                    entry.memo_slot = self.next_memo_slot;
                    self.next_memo_slot += 1;
                }
                return entry.memo_slot;
            }
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
                    if (self.lookupFn(fd.name) != null) continue;
                    const idx: u16 = @intCast(self.fn_table.items.len);
                    const param_types = try extractParamTypes(self.allocator, fd.params);
                    try self.fn_table.append(self.allocator, .{ .name = fd.name, .idx = idx, .arity = @intCast(fd.params.len), .param_types = param_types });
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
                                try self.ctor_table.append(self.allocator, .{ .name = con.name, .idx = cidx, .arity = @intCast(con.fields.len) });
                            }
                        },
                        .newtype => |nt| {
                            const ntidx = try self.program.addNewtypeCtor(td.name);
                            try self.newtype_table.append(self.allocator, .{ .name = nt.name, .idx = ntidx, .arity = 1 });
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
                            try self.error_table.append(self.allocator, .{ .name = td.name, .idx = eidx, .arity = 1 });

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
                            .val_decl => |vd| try self.global_table.append(self.allocator, .{ .name = vd.name, .idx = idx, .is_mutable = false }),
                            .var_decl => |vd| try self.global_table.append(self.allocator, .{ .name = vd.name, .idx = idx, .is_mutable = true }),
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
        return try self.program.addFunction(f);
    }

    /// M5k：合成一个 arity 参的「构造器包装」Function：取各参数 slot 压栈 + OP_MAKE_ADT + RETURN。
    /// 供有参构造器作一等值（`val mk = Circle`；mk(5.0) 即 Circle(5.0)）。返回 func_idx。
    fn ctorWrapperFunc(self: *ModuleCompiler, ctor_idx: u16, arity: u8, name: []const u8, loc: ast.SourceLocation) CompileError!u16 {
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        var i: u8 = 0;
        while (i < arity) : (i += 1) {
            fc.slot_count = @max(fc.slot_count, @as(u16, i) + 1);
            try fc.chunk.writeOp(.op_get_local, loc);
            try fc.chunk.writeU16(i);
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
        return try self.program.addFunction(f);
    }
    /// 但不支持引用尚未初始化的后续全局——镜像 eval 的顺序求值语义）。
    fn compileGlobalsInit(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
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
        self.program.globals_init = try self.program.addFunction(f);
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

    fn init(allocator: std.mem.Allocator, module: *ModuleCompiler) FnCompiler {
        return .{ .chunk = Chunk.init(allocator), .allocator = allocator, .module = module };
    }

    fn deinit(self: *FnCompiler) void {
        self.locals.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.loops.deinit(self.allocator);
        for (self.defer_scopes.items) |*s| s.deinit(self.allocator);
        self.defer_scopes.deinit(self.allocator);
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
            return try self.addUpvalue(name, slot, true);
        }
        if (try enc.resolveUpvalue(name)) |uv_idx| {
            return try self.addUpvalue(name, uv_idx, false);
        }
        return null;
    }

    /// 登记一个 upvalue（去重）。返回其在 upvalues 列表中的索引。
    fn addUpvalue(self: *FnCompiler, name: []const u8, index: u16, is_local: bool) CompileError!u16 {
        for (self.upvalues.items, 0..) |uv, i| {
            if (uv.index == index and uv.is_local == is_local) return @intCast(i);
        }
        if (self.upvalues.items.len >= 255) return error.Unsupported;
        const idx: u16 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{ .name = name, .index = index, .is_local = is_local });
        return idx;
    }

    fn emitExpr(self: *FnCompiler, expr: *const Expr) CompileError!void {
        const loc = ast.exprLocation(expr);
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
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(slot);
                } else if (try self.resolveUpvalue(id.name)) |uv_idx| {
                    try self.chunk.writeOp(.op_get_upvalue, loc);
                    try self.chunk.writeU16(uv_idx);
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
                try self.emitExpr(un.operand);
                try self.chunk.writeOp(switch (un.op) {
                    .neg => self.pickSpecOp(un.operand, .op_neg_int, .op_neg_float, .op_neg),
                    .not => .op_not,
                }, loc);
            },
            .binary => |bin| try self.emitBinary(bin, loc),
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
                for (mc.arguments) |arg| try self.emitExpr(arg);
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
                for (smc.arguments) |arg| try self.emitExpr(arg);
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
                    try self.chunk.writeOp(.op_set_local_assign, a.location);
                    try self.chunk.writeU16(slot);
                } else if (try self.resolveUpvalue(name)) |uv_idx| {
                    try self.chunk.writeOp(.op_set_upvalue, a.location);
                    try self.chunk.writeU16(uv_idx);
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
        // letrec 自递归：先占位注册 Function 拿 func_idx，供体内 OP_CALL_REC 引用。
        var placeholder_idx: ?u16 = null;
        if (rec_name != null) {
            const placeholder = Function{
                .chunk = Chunk.init(self.allocator),
                .arity = @intCast(lam.params.len),
                .slot_count = 0,
                .name = rec_name.?,
            };
            placeholder_idx = try self.module.program.addFunction(placeholder);
            sub.rec_func_idx = placeholder_idx.?;
        }
        for (lam.params) |p| _ = try sub.declareLocal(p.name, p.is_var, typeNeedsRelease(p.type_annotation), builtinTypeOf(p.type_annotation));
        const body_expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        try sub.emitExpr(body_expr);
        try sub.chunk.writeOp(.op_return, loc);
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
        // letrec：覆盖占位 Function；普通：append 新 Function。
        const func_idx = if (placeholder_idx) |idx| blk: {
            self.module.program.functions.items[idx].deinit();
            self.module.program.functions.items[idx] = f;
            break :blk idx;
        } else try self.module.program.addFunction(f);
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
        const func_idx = try self.module.program.addFunction(f);
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
        const func_idx = try self.module.program.addFunction(f);
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
                        try self.chunk.writeOp(.op_set_local, ra.location); // value → slot
                        try self.chunk.writeU16(slot);
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
                        try self.chunk.writeOp(.op_set_local, ra.location);
                        try self.chunk.writeU16(slot);
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
            const func_idx = try self.module.program.addFunction(f);
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
        try self.chunk.writeOp(.op_const, loc);
        try self.chunk.writeU16(k);
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
            .identifier => |id| if (self.resolveLocal(id.name)) |slot|
                self.locals.items[slot].builtin_type
            else
                null,
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

    /// M5：变量绑定（val/var）的 RHS 发射。RHS 是裸 identifier 时用 raw 读取，保留 atomic/lazy
    /// **引用**（不透明 load/force），镜像 eval 把 atomic 当引用类型绑定的语义：`val c = counter`
    /// 后 c 与 counter 共享同一 atomic，`spawn { c += 1 }` 的累加对 counter 可见。
    /// 非引用类型（int/array/record 等）raw 与普通读取等价；非 identifier RHS 照常 emitExpr。
    fn emitBindingRhs(self: *FnCompiler, expr: *const Expr) CompileError!void {
        if (expr.* == .identifier) {
            const name = expr.identifier.name;
            if (self.resolveLocal(name)) |slot| {
                try self.chunk.writeOp(.op_get_local_raw, expr.identifier.location);
                try self.chunk.writeU16(slot);
                return;
            } else if (try self.resolveUpvalue(name)) |uv| {
                try self.chunk.writeOp(.op_get_upvalue_raw, expr.identifier.location);
                try self.chunk.writeU16(uv);
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
                try self.chunk.writeOp(.op_get_local_raw, obj.identifier.location);
                try self.chunk.writeU16(slot);
                return;
            } else if (try self.resolveUpvalue(name)) |uv| {
                try self.chunk.writeOp(.op_get_upvalue_raw, obj.identifier.location);
                try self.chunk.writeU16(uv);
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
                        for (c.arguments) |arg| try self.emitExpr(arg);
                        try self.chunk.writeOp(.op_call, loc);
                        try self.chunk.writeU16(fidx);
                        try self.chunk.writeByte(argc);
                        return;
                    }
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, name));
                    for (c.arguments) |arg| try self.emitExpr(arg); // [recv, rest...]
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
        for (c.arguments) |arg| try self.emitExpr(arg);
        try self.chunk.writeOp(.op_call_value, loc);
        try self.chunk.writeByte(argc);
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
        // JIT Phase 1: type_table driven opcode specialization
        const op: OpCode = switch (bin.op) {
            .add => self.pickSpecOp(bin.left, .op_add_int, .op_add_float, .op_add),
            .sub => self.pickSpecOp(bin.left, .op_sub_int, .op_sub_float, .op_sub),
            .mul => self.pickSpecOp(bin.left, .op_mul_int, .op_mul_float, .op_mul),
            .div => self.pickSpecOp(bin.left, .op_div_int, .op_div_float, .op_div),
            .mod => self.pickSpecOp(bin.left, .op_mod_int, null, .op_mod),
            .eq => self.pickSpecOp(bin.left, .op_eq_int, .op_eq_float, .op_eq),
            .not_eq => self.pickSpecOp(bin.left, .op_neq_int, .op_neq_float, .op_neq),
            .lt => self.pickSpecOp(bin.left, .op_lt_int, .op_lt_float, .op_lt),
            .gt => self.pickSpecOp(bin.left, .op_gt_int, .op_gt_float, .op_gt),
            .lt_eq => self.pickSpecOp(bin.left, .op_le_int, .op_le_float, .op_le),
            .gt_eq => self.pickSpecOp(bin.left, .op_ge_int, .op_ge_float, .op_ge),
            .bit_and => .op_bit_and,
            .bit_or => .op_bit_or,
            .bit_xor => .op_bit_xor,
            else => return error.Unsupported,
        };
        try self.chunk.writeOp(op, loc);
    }

    /// JIT Phase 1: pick specialized opcode by type_table annotation.
    fn pickSpecOp(self: *FnCompiler, expr: *const ast.Expr, int_op: OpCode, float_op: ?OpCode, fallback: OpCode) OpCode {
        if (self.module.type_table) |tt| {
            if (tt.isInt(expr)) return int_op;
            if (tt.isFloat(expr)) {
                if (float_op) |fo| return fo;
            }
        }
        return fallback;
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
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(scrut_slot);

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
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    try self.chunk.writeOp(.op_set_local, loc);
                    try self.chunk.writeU16(slot);
                }
            },
            .literal => |lit| {
                const v = (try patternLiteralToValue(self.allocator, lit)) orelse return error.Unsupported;
                const cidx = try self.chunk.addConstant(v);
                try self.chunk.writeOp(.op_get_local, loc);
                try self.chunk.writeU16(scrut_slot);
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
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    try self.chunk.writeOp(.op_test_throw, loc);
                    try self.chunk.writeByte(want_ok);
                    try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                    try self.chunk.writeOp(.op_pop, loc); // 命中：弹 true
                    // 解包内值（Ok→inner / Error→error_val）进临时 slot 递归。
                    const tmp = try self.declareLocal("$thr", false, true, null);
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    try self.chunk.writeOp(if (want_ok == 1) .op_get_throw_ok else .op_get_throw_err, loc);
                    try self.chunk.writeOp(.op_set_local, loc);
                    try self.chunk.writeU16(tmp);
                    try self.emitPatternMatch(ctor.patterns[0], tmp, fail_jumps, loc);
                } else if (self.module.lookupNewtype(ctor.name)) |_| {
                    // newtype 构造器模式 Handle(p)：测 type_name + 解 inner 递归。
                    if (ctor.patterns.len != 1) return error.Unsupported;
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, ctor.name));
                    try self.chunk.writeOp(.op_test_newtype, loc);
                    try self.chunk.writeU16(name_const);
                    try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                    try self.chunk.writeOp(.op_pop, loc);
                    // 解 inner 进临时 slot 递归。
                    const tmp = try self.declareLocal("$nt", false, true, null);
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    try self.chunk.writeOp(.op_get_newtype_inner, loc);
                    try self.chunk.writeOp(.op_set_local, loc);
                    try self.chunk.writeU16(tmp);
                    try self.emitPatternMatch(ctor.patterns[0], tmp, fail_jumps, loc);
                } else {
                    // ADT 构造器模式：测构造器名 + 按位置解字段递归。
                    try self.emitCtorTest(scrut_slot, ctor.name, fail_jumps, loc);
                    for (ctor.patterns, 0..) |sub, i| {
                        const tmp = try self.declareLocal("$fld", false, true, null);
                        try self.chunk.writeOp(.op_get_local, loc);
                        try self.chunk.writeU16(scrut_slot);
                        try self.chunk.writeOp(.op_get_adt_field, loc);
                        try self.chunk.writeU16(@intCast(i));
                        try self.chunk.writeOp(.op_set_local, loc);
                        try self.chunk.writeU16(tmp);
                        try self.emitPatternMatch(sub, tmp, fail_jumps, loc);
                    }
                }
            },
            .record => |rec| {
                // 记录模式：无标签测试，按名解字段递归绑定。
                for (rec.fields) |f| {
                    const tmp = try self.declareLocal("$rf", false, true, null);
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    const name_const = try self.chunk.addConstant(try Value.fromStringBytes(self.allocator, f.name));
                    try self.chunk.writeOp(.op_get_field, loc);
                    try self.chunk.writeU16(name_const);
                    try self.chunk.writeOp(.op_set_local, loc);
                    try self.chunk.writeU16(tmp);
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
        try self.chunk.writeOp(.op_get_local, loc);
        try self.chunk.writeU16(scrut_slot);
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
                try self.chunk.writeOp(.op_get_local, loc);
                try self.chunk.writeU16(scrut_slot);
                try self.chunk.writeOp(.op_test_lit, loc);
                try self.chunk.writeU16(cidx);
            },
            .variable => |v| {
                if (v.name.len > 0 and v.name[0] >= 'A' and v.name[0] <= 'Z') {
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
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
                    try self.chunk.writeOp(.op_unit, d.location);
                    try self.chunk.writeOp(.op_set_local, d.location);
                    try self.chunk.writeU16(slot);
                    const has_self_uv = try self.emitLambda(d.value.lambda, d.location, d.name);
                    if (has_self_uv) {
                        try self.chunk.writeOp(.op_set_local_letrec, d.location);
                    } else {
                        try self.chunk.writeOp(.op_set_local, d.location);
                    }
                    try self.chunk.writeU16(slot);
                } else {
                    try self.emitBindingRhs(d.value);
                    try self.emitCoerceFromAnnotation(d.type_annotation, d.value, d.location); // M5：val a: i32 = ...
                    const slot = try self.declareLocal(d.name, false, typeNeedsRelease(d.type_annotation), builtinTypeOf(d.type_annotation));
                    try self.chunk.writeOp(.op_set_local, d.location);
                    try self.chunk.writeU16(slot);
                }
            },
            .var_decl => |d| {
                try self.emitBindingRhs(d.value);
                try self.emitCoerceFromAnnotation(d.type_annotation, d.value, d.location); // M5：var a: i32 = ...
                const slot = try self.declareLocal(d.name, true, typeNeedsRelease(d.type_annotation), builtinTypeOf(d.type_annotation));
                try self.chunk.writeOp(.op_set_local, d.location);
                try self.chunk.writeU16(slot);
            },
            .expression => |e| {
                try self.emitExpr(e.expr);
                try self.chunk.writeOp(.op_pop, e.location);
            },
            .assignment => |a| {
                // M5f：index 目标 arr[i] = v —— 镜像 eval：identifier 数组目标 COW 后写回绑定槽。
                if (a.target.* == .index) {
                    try self.emitIndexAssign(a.target.index, a.value, a.location);
                    return;
                }
                if (a.target.* != .identifier) return error.Unsupported;
                const name = a.target.identifier.name;
                // op_push_inplace 优化：arr = arr.push(expr) 模式（仅 local，rc==1 时 VM 原地扩容）
                if (a.value.* == .method_call) blk: {
                    const mc = a.value.method_call;
                    if (!(std.mem.eql(u8, mc.method, "push") and mc.arguments.len == 1)) break :blk;
                    if (mc.object.* != .identifier) break :blk;
                    if (!std.mem.eql(u8, mc.object.identifier.name, name)) break :blk;
                    const slot = self.resolveLocal(name) orelse break :blk;
                    try self.emitExpr(mc.arguments[0]);
                    try self.chunk.writeOp(.op_push_inplace, a.location);
                    try self.chunk.writeU16(slot);
                    try self.chunk.writeOp(.op_set_local_assign, a.location);
                    try self.chunk.writeU16(slot);
                    return;
                }
                if (self.resolveLocal(name)) |slot| {
                    try self.emitExpr(a.value);
                    try self.chunk.writeOp(.op_set_local_assign, a.location);
                    try self.chunk.writeU16(slot);
                } else if (try self.resolveUpvalue(name)) |uv_idx| {
                    try self.emitExpr(a.value);
                    try self.chunk.writeOp(.op_set_upvalue, a.location);
                    try self.chunk.writeU16(uv_idx);
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
            .while_stmt => |w| try self.emitWhile(w),
            .loop_stmt => |l| try self.emitLoop(l),
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

    fn emitWhile(self: *FnCompiler, w: @TypeOf(@as(Stmt, undefined).while_stmt)) CompileError!void {
        // loop_start: cond; jump_if_false->end; pop cond(true); body; pop body; jump loop_start; end: pop cond(false)
        const loop_start = self.chunk.here();
        // continue 回跳到条件重新求值处（loop_start）。
        try self.loops.append(self.allocator, .{ .continue_target = loop_start, .defer_depth = self.defer_scopes.items.len });
        try self.emitExpr(w.condition);
        const exit_jump = try self.chunk.emitJump(.op_jump_if_false, w.location);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(true)
        try self.emitExpr(w.body);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 body 值（while 体值丢弃）
        try self.emitLoopBack(loop_start, w.location);
        self.chunk.patchJump(exit_jump);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(false)
        // break 跳到此处（cond 已弹，栈平衡）。
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
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
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(iter_slot);
        const idx_const = try self.chunk.addConstant(Value.fromInt(value.Int.fromNative(.i64, @as(i64, 0))));
        try self.emitConst(idx_const, loc);
        const idx_slot = try self.declareLocal("$idx", true, false, null);
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(idx_slot);
        // 循环变量 slot（每轮 OP_FOR_NEXT 压元素后 set_local 绑定）。
        const var_slot = try self.declareLocal(f.name, true, true, null);

        const loop_start = self.chunk.here();
        try self.loops.append(self.allocator, .{ .continue_target = loop_start, .defer_depth = self.defer_scopes.items.len });
        // OP_FOR_NEXT <iter_slot><idx_slot><i32 exit_off>：耗尽跳 exit；否则压当前元素 + idx++。
        try self.chunk.writeOp(.op_for_next, loc);
        try self.chunk.writeU16(iter_slot);
        try self.chunk.writeU16(idx_slot);
        const exit_at = self.chunk.here();
        try self.chunk.writeI32(0); // 占位，循环末回填
        // 绑定循环变量（弹元素写 var_slot）。
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(var_slot);
        // 循环体（值丢弃）。
        try self.emitExpr(f.body);
        try self.chunk.writeOp(.op_pop, loc);
        try self.emitLoopBack(loop_start, loc);
        // exit 落点：FOR_NEXT 耗尽跳到此（未压元素，栈平衡）。
        self.chunk.patchJump(exit_at);
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
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

        // 5. 安全限制：1..=8 次迭代（0 次 = 空循环直接跳过 body）
        if (count == 0) return; // 空循环：不发射任何指令（常量 range 无副作用）
        if (count > 8) return error.SkipUnroll;

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
            try self.chunk.writeOp(.op_set_local, loc);
            try self.chunk.writeU16(var_slot);
            // 循环体（值丢弃）
            try self.emitExpr(f.body);
            try self.chunk.writeOp(.op_pop, loc);
        }
    }

    /// loop { body }：无限循环，仅 break 退出。
    /// loop_start: body; pop body; jump loop_start; end:(break 落点)
    fn emitLoop(self: *FnCompiler, l: @TypeOf(@as(Stmt, undefined).loop_stmt)) CompileError!void {
        const loop_start = self.chunk.here();
        try self.loops.append(self.allocator, .{ .continue_target = loop_start, .defer_depth = self.defer_scopes.items.len });
        try self.emitExpr(l.body);
        try self.chunk.writeOp(.op_pop, l.location); // 弹 body 值
        try self.emitLoopBack(loop_start, l.location);
        var lc = self.loops.pop().?;
        defer lc.breaks.deinit(self.allocator);
        for (lc.breaks.items) |j| self.chunk.patchJump(j);
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
                try self.chunk.writeOp(.op_get_local, fa.location);
                try self.chunk.writeU16(slot);
                try self.emitExpr(fa.value);
                try self.chunk.writeOp(.op_set_field, fa.location);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeOp(.op_set_local, fa.location);
                try self.chunk.writeU16(slot);
                return;
            } else if (try self.resolveUpvalue(oname)) |uv| {
                try self.chunk.writeOp(.op_get_upvalue, fa.location);
                try self.chunk.writeU16(uv);
                try self.emitExpr(fa.value);
                try self.chunk.writeOp(.op_set_field, fa.location);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeOp(.op_set_upvalue, fa.location);
                try self.chunk.writeU16(uv);
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
                try self.chunk.writeOp(.op_get_local, loc);
                try self.chunk.writeU16(slot);
                try self.emitExpr(idx.index);
                try self.emitExpr(rhs);
                try self.chunk.writeOp(.op_set_index, loc);
                try self.chunk.writeOp(.op_set_local, loc);
                try self.chunk.writeU16(slot);
                return;
            } else if (try self.resolveUpvalue(oname)) |uv| {
                try self.chunk.writeOp(.op_get_upvalue, loc);
                try self.chunk.writeU16(uv);
                try self.emitExpr(idx.index);
                try self.emitExpr(rhs);
                try self.chunk.writeOp(.op_set_index, loc);
                try self.chunk.writeOp(.op_set_upvalue, loc);
                try self.chunk.writeU16(uv);
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

/// 判断类型名是否为 Glue 基础类型（数值 + bool + char）。
fn isBuiltinType(name: []const u8) bool {
    if (isBuiltinNumericType(name)) return true;
    return std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "char");
}

/// 【JIT Phase 3】判断类型名是否可安全 memoize（按值 hash，不含指针）。
/// 基础类型 + str（String 的 bytes() 内容 hash）均为安全。
fn isMemoizableType(name: []const u8) bool {
    return isBuiltinType(name) or std.mem.eql(u8, name, "str");
}

/// 【JIT Phase 3】检查函数所有参数类型是否均可安全 memoize。
/// param_types[i] 为 null 表示无类型注解（动态类型），保守视为不安全。
fn allParamsMemoizable(param_types: []const ?[]const u8) bool {
    for (param_types) |pt| {
        const t = pt orelse return false;
        if (!isMemoizableType(t)) return false;
    }
    return true;
}

/// 从类型注解提取基础类型名（非基础类型/无注解返回 null）。
fn builtinTypeOf(ta: ?*const ast.TypeNode) ?[]const u8 {
    const t = ta orelse return null;
    return switch (t.*) {
        .named => |n| if (isBuiltinType(n.name)) n.name else null,
        else => null,
    };
}

/// 从形参列表提取基础类型名数组。
fn extractParamTypes(allocator: std.mem.Allocator, params: []const ast.Param) ![]const ?[]const u8 {
    const result = try allocator.alloc(?[]const u8, params.len);
    for (params, 0..) |p, i| result[i] = builtinTypeOf(p.type_annotation);
    return result;
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