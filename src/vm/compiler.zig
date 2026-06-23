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
    /// trait/impl 方法名集合（M5i，第一遍登记）：用于把裸名调用 `compare(a,b)`（with-clause 约束的
    /// trait 方法作自由函数）解析为 receiver=arg0 的 OP_CALL_METHOD 分派。
    method_names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 零参 trait/impl 方法表（M5k）：`zero()` 无 receiver 无法按类型分派，按名字直接解析到 impl 函数
    /// （name → func_idx，首个 impl 生效）。供 emitCall 的 argc==0 裸名调用。
    nullary_methods: std.ArrayListUnmanaged(struct { name: []const u8, func_idx: u16 }) = .empty,

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

    /// M5i：登记一个 trait/impl 方法名（去重）。
    fn registerMethodName(self: *ModuleCompiler, name: []const u8) CompileError!void {
        for (self.method_names.items) |n| if (std.mem.eql(u8, n, name)) return;
        try self.method_names.append(self.allocator, name);
    }

    /// M5i：name 是否为已知 trait/impl 方法名（裸名调用作自由函数 trait 方法分派判定用）。
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

    /// 编译整个模块。返回的 Program（self.program）持有所有函数；调用方取走。
    pub fn compileModule(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        return self.compileModuleWithDeps(module, &.{});
    }

    /// M5j：编译入口模块 + 其 `use` 依赖模块（已解析 AST，定义先于使用顺序）。依赖的顶层函数/
    /// impl/trait/类型/构造器**合并进同一 Program**（VM 按名字字符串解析，扁平 impl 表，天然合并）。
    /// 注册顺序：先依赖后入口（入口可前向引用，但同名时入口的 fn_table 在后——lookupFn 取首个匹配，
    /// 故依赖优先；stdlib 名字不与用户 main 冲突，无歧义）。顶层 val/var 仅入口模块支持（依赖 stdlib
    /// 是纯 trait/impl/fun，无顶层 val/var）。
    pub fn compileModuleWithDeps(self: *ModuleCompiler, module: *const ast.Module, deps: []const ast.Module) CompileError!void {
        // 第一遍：登记所有模块（依赖在前）的顶层函数/构造器/方法名/全局。
        for (deps) |*dep| try self.registerDecls(dep);
        try self.registerDecls(module);
        self.program.global_count = @intCast(self.global_table.items.len);
        // 第二遍：编译所有模块的函数体 + impl/trait 方法。
        for (deps) |*dep| try self.compileBodies(dep);
        try self.compileBodies(module);
        // M5k：检测同一 (type_name, method_name) 多个 impl —— 触发 trait 冲突消解/override 语义
        //（文档 §2.7.2），VM 扁平表只取首个 → 语义不符。整体回退树遍历器，避免静默错误输出。
        try self.checkNoConflictingImpls();
        // M5g：仅入口模块的顶层 val/var 进全局初始化（依赖 stdlib 无顶层 val/var）。
        if (self.global_table.items.len > 0) {
            try self.compileGlobalsInit(module);
        }
        if (self.lookupFn("main")) |m| self.program.entry = m;
    }

    /// M5k：若任意 (type_name, method_name) 对出现多次（同类型同方法多 impl），说明依赖 trait 组合/
    /// override 冲突消解（VM 未实现，扁平 impl 表只取首个匹配）→ Unsupported，整体回退。
    fn checkNoConflictingImpls(self: *ModuleCompiler) CompileError!void {
        const items = self.program.impl_methods.items;
        for (items, 0..) |a, i| {
            for (items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.method_name, b.method_name) and
                    std.mem.eql(u8, a.type_name, b.type_name))
                    return error.Unsupported;
            }
        }
    }

    /// 第一遍：登记一个模块的顶层函数（预占 program 槽）/ADT·newtype·error 构造器/全局 val·var/方法名。
    fn registerDecls(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 同名顶层函数已登记（如依赖与入口重名）→ 跳过重复预占（首个生效）。
                    if (self.lookupFn(fd.name) != null) continue;
                    const idx: u16 = @intCast(self.fn_table.items.len);
                    try self.fn_table.append(self.allocator, .{ .name = fd.name, .idx = idx, .arity = @intCast(fd.params.len) });
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
                            const eidx = try self.program.addErrorCtor(td.name, en.message);
                            try self.error_table.append(self.allocator, .{ .name = td.name, .idx = eidx, .arity = 1 });
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
                .impl_decl => |id| {
                    for (id.methods) |m| try self.registerMethodName(m.name);
                },
                .trait_decl => |td| {
                    for (td.methods) |m| try self.registerMethodName(m.name);
                },
                else => {},
            }
        }
    }

    /// 第二遍：编译一个模块的 impl/trait 方法体（先，使裸名/nullary 方法表就绪）+ 函数体。
    fn compileBodies(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        // impl/trait 方法先编译：填 nullary_methods 表，使后续 fun 体（含 main）的 `zero()` 裸名可解析。
        for (module.declarations) |decl| {
            switch (decl) {
                .impl_decl => |id| try self.compileImplMethods(id),
                .trait_decl => |td| try self.compileTraitDefaults(td),
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

    /// M5i：编译一个 impl 块的所有方法体（有 body 的）。每个编成顶层 Function（self+params 占
    /// slot 0..），登记进 program.impl_methods（type_name + method_name 分派键）。镜像 eval impl_decl。
    fn compileImplMethods(self: *ModuleCompiler, id: @TypeOf(@as(ast.Decl, undefined).impl_decl)) CompileError!void {
        for (id.methods) |m| {
            const body = m.body orelse continue;
            const func_idx = try self.compileMethodBody(m, body);
            try self.program.addImplMethod(id.type_name, m.name, id.trait_name, func_idx);
            // M5k：零参方法（self 也无，如 `fun zero(): i32`）无 receiver，登记按名直接解析（首个生效）。
            if (m.params.len == 0) try self.registerNullaryMethod(m.name, func_idx);
        }
    }

    /// M5k：登记一个零参方法名 → func_idx（首个 impl 生效，去重）。
    fn registerNullaryMethod(self: *ModuleCompiler, name: []const u8, func_idx: u16) CompileError!void {
        for (self.nullary_methods.items) |e| if (std.mem.eql(u8, e.name, name)) return;
        try self.nullary_methods.append(self.allocator, .{ .name = name, .func_idx = func_idx });
    }

    /// M5k：查零参方法名 → func_idx。
    pub fn lookupNullaryMethod(self: *ModuleCompiler, name: []const u8) ?u16 {
        for (self.nullary_methods.items) |e| if (std.mem.eql(u8, e.name, name)) return e.func_idx;
        return null;
    }

    /// M5k：若某方法名在 program.impl_methods 中**恰有一个** impl，返回其 func_idx（用于自由函数式
    /// trait 方法调用 `compare(a,b)`——单 impl 时直接调用，镜像 eval 把 impl 方法注册为环境函数的动态
    /// 类型语义，不受 receiver 类型限制）。多 impl（如 stdlib show 覆盖 i64/f64/...）返回 null → 退回
    /// receiver 类型分派。
    pub fn uniqueImplMethod(self: *ModuleCompiler, name: []const u8) ?u16 {
        var found: ?u16 = null;
        for (self.program.impl_methods.items) |d| {
            if (std.mem.eql(u8, d.method_name, name)) {
                if (found != null) return null; // 多 impl → 不唯一
                found = d.func_idx;
            }
        }
        return found;
    }

    /// M5i：编译 trait 块中带默认 body 的方法，登记进 program.trait_defaults（impl 未覆写时回退）。
    fn compileTraitDefaults(self: *ModuleCompiler, td: @TypeOf(@as(ast.Decl, undefined).trait_decl)) CompileError!void {
        for (td.methods) |m| {
            const body = m.body orelse continue;
            const func_idx = try self.compileMethodBody(m, body);
            try self.program.addTraitDefault(td.name, m.name, func_idx);
        }
    }

    /// M5k：把一个方法（self+params）编成顶层零捕获 Function，返回 func_idx。
    /// 顶层 impl/trait 方法不在词法闭包内，故 enclosing=null（自由变量解析为顶层函数/全局/构造器）。
    fn compileMethodBody(self: *ModuleCompiler, m: ast.MethodDecl, body: *ast.Expr) CompileError!u16 {
        if (m.params.len > 255) return error.Unsupported;
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        for (m.params) |p| _ = try fc.declareLocal(p.name, p.is_var);
        // 形参隐式定型（i8 实参 → i32 形参），镜像 compileFunction。
        try fc.emitParamCoercions(m.params, ast.exprLocation(body));
        try fc.emitTail(body);
        const f = Function{
            .chunk = fc.chunk,
            .arity = @intCast(m.params.len),
            .slot_count = fc.slot_count,
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
            .name = name,
        };
        fc.chunk = Chunk.init(self.allocator);
        return try self.program.addFunction(f);
    }
    /// 但不支持引用尚未初始化的后续全局——镜像 eval 的顺序求值语义）。
    fn compileGlobalsInit(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
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
            try fc.emitCoerceFromAnnotation(gv.ann, ed.location);
            try fc.chunk.writeOp(.op_set_global, ed.location);
            try fc.chunk.writeU16(ge.idx);
        }
        try fc.chunk.writeOp(.op_unit, .{ .line = 0, .column = 0 });
        try fc.chunk.writeOp(.op_return, .{ .line = 0, .column = 0 });
        const f = Function{
            .chunk = fc.chunk,
            .arity = 0,
            .slot_count = fc.slot_count,
            .name = "<globals_init>",
        };
        fc.chunk = Chunk.init(self.allocator);
        self.program.globals_init = try self.program.addFunction(f);
    }

    fn compileFunction(self: *ModuleCompiler, fd: @TypeOf(@as(ast.Decl, undefined).fun_decl)) CompileError!void {
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        // 参数占 slot 0..arity-1。
        for (fd.params) |p| _ = try fc.declareLocal(p.name, p.is_var);
        // M5：对带 builtin 数值注解的形参，入口处把实参协调到声明类型（i8 实参→i32 形参）。
        try fc.emitParamCoercions(fd.params, ast.exprLocation(fd.body));
        try fc.emitTail(fd.body); // 函数体在尾位置：尾调用→OP_TAIL_CALL，否则 emitExpr+OP_RETURN
        // 移交 chunk 所有权给 Function；fc.deinit 只清 locals。
        const f = Function{
            .chunk = fc.chunk,
            .arity = @intCast(fd.params.len),
            .slot_count = fc.slot_count,
            .name = fd.name,
        };
        fc.chunk = Chunk.init(self.allocator); // 移走真 chunk 后置空壳：fc.deinit 释放空壳（无分配）
        // 覆盖第一遍预留的占位槽（释放占位空 chunk）。
        const idx = self.lookupFn(fd.name).?;
        self.program.functions.items[idx].deinit();
        self.program.functions.items[idx] = f;
    }
};

/// 单函数编译器：编译一个函数体到一个 Chunk。
const FnCompiler = struct {
    chunk: Chunk,
    allocator: std.mem.Allocator,
    module: *ModuleCompiler,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    slot_count: u16 = 0,
    /// 外层函数编译器（嵌套 lambda 用于 upvalue 解析）；顶层函数为 null。
    enclosing: ?*FnCompiler = null,
    /// 本函数捕获的 upvalue（clox 静态解析；运行时 OP_CLOSURE 据此 box/共享 cell）。
    upvalues: std.ArrayListUnmanaged(Upvalue) = .empty,
    /// 循环上下文栈（break/continue 跳转回填）。嵌套循环 push/pop。
    loops: std.ArrayListUnmanaged(LoopCtx) = .empty,
    /// defer 作用域栈（M3c-defer）：每个含 defer 的 block push 一层，存本层 defer 表达式（按出现顺序）。
    /// block 退出（正常/return/throw）按 LIFO 重放。每层 defer 体内联发射（读当前 slot，见当前局部值）。
    defer_scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*const Expr)) = .empty,

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

    fn declareLocal(self: *FnCompiler, name: []const u8, is_var: bool) CompileError!u16 {
        const slot: u16 = @intCast(self.locals.items.len);
        try self.locals.append(self.allocator, .{ .name = name, .slot = slot, .is_var = is_var });
        if (self.locals.items.len > self.slot_count) self.slot_count = @intCast(self.locals.items.len);
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
                const v = parseIntLiteral(lit) orelse return error.Unsupported;
                try self.emitConst(try self.chunk.addConstant(v), loc);
            },
            .float_literal => |lit| {
                const v = parseFloatLiteral(lit) orelse return error.Unsupported;
                try self.emitConst(try self.chunk.addConstant(v), loc);
            },
            .bool_literal => |lit| try self.chunk.writeOp(if (lit.value) .op_true else .op_false, loc),
            .null_literal => try self.chunk.writeOp(.op_null, loc),
            .unit_literal => try self.chunk.writeOp(.op_unit, loc),
            // M3a：字符串字面量 → 常量池（dupe owned），OP_CONST。
            .string_literal => |lit| {
                const s = Value{ .string = try self.allocator.dupe(u8, lit.value) };
                try self.emitConst(try self.chunk.addConstant(s), loc);
            },
            // M3a：字符字面量 → 常量池，OP_CONST。
            .char_literal => |lit| {
                try self.emitConst(try self.chunk.addConstant(Value{ .char_val = lit.value }), loc);
            },
            // M3a：字符串插值 → 各段（literal 文本压 string 常量、expression 求值）压栈 + OP_INTERP <n>。
            .string_interpolation => |interp| {
                if (interp.parts.len > 65535) return error.Unsupported;
                for (interp.parts) |part| {
                    switch (part) {
                        .literal => |txt| {
                            const s = Value{ .string = try self.allocator.dupe(u8, txt) };
                            try self.emitConst(try self.chunk.addConstant(s), loc);
                        },
                        .expression => |e| try self.emitExpr(e),
                    }
                }
                try self.chunk.writeOp(.op_interp, loc);
                try self.chunk.writeU16(@intCast(interp.parts.len));
            },
            .identifier => |id| {
                if (self.resolveLocal(id.name)) |slot| {
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
                    .neg => .op_neg,
                    .not => .op_not,
                }, loc);
            },
            .binary => |bin| try self.emitBinary(bin, loc),
            .if_expr => |ie| try self.emitIf(ie, loc),
            .block => |blk| try self.emitBlock(blk, loc),
            .call => |c| try self.emitCall(c, loc),
            .lambda => |lam| try self.emitLambda(lam, loc),
            // M2a：字段访问 p.x → OP_GET_FIELD <字段名常量>。
            .field_access => |fa| {
                try self.emitExpr(fa.object);
                const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, fa.field) });
                try self.chunk.writeOp(.op_get_field, loc);
                try self.chunk.writeU16(name_const);
            },
            // M3d：方法调用 obj.m(args) → 压 receiver + 实参 + OP_CALL_METHOD <name><argc>。
            .method_call => |mc| {
                if (mc.arguments.len > 255) return error.Unsupported;
                // M4a：方法接收者若是 identifier，用 raw 读取（不透明 load atomic，cas/swap 需原始 Atomic）。
                try self.emitMethodReceiver(mc.object);
                for (mc.arguments) |arg| try self.emitExpr(arg);
                const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, mc.method) });
                try self.chunk.writeOp(.op_call_method, loc);
                try self.chunk.writeU16(name_const);
                try self.chunk.writeByte(@intCast(mc.arguments.len));
            },
            // M3d：安全字段访问 obj?.field —— receiver null 短路返回 null，否则 OP_GET_FIELD。
            .safe_access => |sa| {
                try self.emitExpr(sa.object);
                // peek：null → 跳过字段访问（栈顶 null 即结果）；非 null → 弹后取字段。
                const skip = try self.chunk.emitJump(.op_jump_if_null, loc);
                const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, sa.field) });
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
                const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, smc.method) });
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
                const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, tname) });
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
                    try self.chunk.writeOp(.op_set_local, a.location);
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
    fn emitLambda(self: *FnCompiler, lam: @TypeOf(@as(Expr, undefined).lambda), loc: ast.SourceLocation) CompileError!void {
        if (lam.params.len > 255) return error.Unsupported;
        var sub = FnCompiler.init(self.allocator, self.module);
        sub.enclosing = self;
        defer sub.deinit();
        for (lam.params) |p| _ = try sub.declareLocal(p.name, p.is_var);
        const body_expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        try sub.emitParamCoercions(lam.params, loc); // M5：lambda 形参数值注解协调
        try sub.emitExpr(body_expr);
        try sub.chunk.writeOp(.op_return, loc);
        const f = Function{
            .chunk = sub.chunk,
            .arity = @intCast(lam.params.len),
            .slot_count = sub.slot_count,
            .name = "<lambda>",
        };
        sub.chunk = Chunk.init(self.allocator); // 防 deinit 误碰
        const func_idx = try self.module.program.addFunction(f);
        // 发 OP_CLOSURE + 描述符。注意：描述符在 *本* 函数(enclosing)上下文展开。
        try self.chunk.writeOp(.op_closure, loc);
        try self.chunk.writeU16(@intCast(func_idx));
        try self.chunk.writeByte(@intCast(sub.upvalues.items.len));
        for (sub.upvalues.items) |uv| {
            try self.chunk.writeByte(if (uv.is_local) 1 else 0);
            try self.chunk.writeU16(uv.index);
        }
    }

    /// M4c：spawn { body } —— body 编译成零参 Function（自动捕获 enclosing 变量为 upvalue），
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
                        const slot = try self.declareLocal(bname, false);
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
                        const slot = try self.declareLocal(bname, false);
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
            const name_v = Value{ .string = try self.allocator.dupe(u8, method.name) };
            try self.emitConst(try self.chunk.addConstant(name_v), method.location);
            // 方法体编成带 arity 的 Function（params 占 slot 0..；自动捕获 enclosing）。
            var sub = FnCompiler.init(self.allocator, self.module);
            sub.enclosing = self;
            defer sub.deinit();
            for (method.params) |p| _ = try sub.declareLocal(p.name, p.is_var);
            try sub.emitExpr(body);
            try sub.chunk.writeOp(.op_return, method.location);
            const f = Function{
                .chunk = sub.chunk,
                .arity = @intCast(method.params.len),
                .slot_count = sub.slot_count,
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

    /// M5：按类型注解发射隐式数值定型（OP_COERCE）。仅当注解是 builtin 数值类型名（i*/u*/f*）
    /// 时发射；str/bool/泛型/用户类型/无注解 → 不发射（隐式协调只管数值宽度，镜像 eval 在形参/
    /// val/var 绑定处对 builtin 数值类型调 castValue 的行为）。作用于栈顶值（就地协调）。
    fn emitCoerceFromAnnotation(self: *FnCompiler, ann: ?*const ast.TypeNode, loc: ast.SourceLocation) CompileError!void {
        const ta = ann orelse return;
        const tname = switch (ta.*) {
            .named => |n| n.name,
            else => return, // 泛型/可空/函数类型等：不隐式协调
        };
        if (!isBuiltinNumericType(tname)) return; // str/bool/用户类型：不协调
        const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, tname) });
        try self.chunk.writeOp(.op_coerce, loc);
        try self.chunk.writeU16(name_const);
    }

    /// M5：在函数/lambda 入口为带 builtin 数值注解的形参发射 OP_GET_LOCAL+COERCE+SET_LOCAL，
    /// 把传入实参（可能是 inferIntType 的最小类型）协调到声明类型（如 i32）。
    /// 镜像 eval callFunction 在绑定形参时对 param.type_annotation 调 castValue 的逻辑。
    fn emitParamCoercions(self: *FnCompiler, params: []const ast.Param, loc: ast.SourceLocation) CompileError!void {
        for (params) |p| {
            const ta = p.type_annotation orelse continue;
            const tname = switch (ta.*) {
                .named => |n| n.name,
                else => continue,
            };
            if (!isBuiltinNumericType(tname)) continue;
            const slot = self.resolveLocal(p.name).?; // 刚 declareLocal，必存在
            const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, tname) });
            try self.chunk.writeOp(.op_get_local, loc);
            try self.chunk.writeU16(slot);
            try self.chunk.writeOp(.op_coerce, loc);
            try self.chunk.writeU16(name_const);
            try self.chunk.writeOp(.op_set_local, loc);
            try self.chunk.writeU16(slot);
        }
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
                try self.emitExpr(ie.condition);
                const else_jump = try self.chunk.emitJump(.op_jump_if_false, loc);
                try self.chunk.writeOp(.op_pop, loc); // then：弹 cond
                try self.emitTail(ie.then_branch); // 分支尾自带 RETURN/TAIL_CALL
                // then 分支已 RETURN，无需 end_jump 跳过 else。
                self.chunk.patchJump(else_jump);
                try self.chunk.writeOp(.op_pop, loc); // else：弹 cond
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
        for (c.arguments) |arg| try self.emitExpr(arg);
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
            // 被 local 或 upvalue 绑定遮蔽（如递归局部函数 go 在自身体内是 upvalue）→ 走通用
            // op_call_value 路径，不当顶层函数/构造器/内建处理。
            const shadowed = self.resolveLocal(name) != null or (try self.resolveUpvalue(name)) != null;
            if (!shadowed) {
                if (self.module.lookupFn(name)) |func_idx| {
                    for (c.arguments) |arg| try self.emitExpr(arg);
                    try self.chunk.writeOp(.op_call, loc);
                    try self.chunk.writeU16(func_idx);
                    try self.chunk.writeByte(argc);
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
                // M5e：自定义错误类型构造器裸名调用 → OP_MAKE_ERROR（arity 恒 1，str 消息）。
                if (self.module.lookupError(name)) |ee| {
                    if (argc != 1) return error.Unsupported;
                    try self.emitExpr(c.arguments[0]);
                    try self.chunk.writeOp(.op_make_error, loc);
                    try self.chunk.writeU16(ee.idx);
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
                    // 单 impl 方法：直接调用其函数（镜像 eval 动态类型语义，不受 receiver 类型限制，
                    // 如 `compare(1.5,2.5)` 调用唯一的 Comparable<i32> impl）。多 impl → receiver 类型分派。
                    if (self.module.uniqueImplMethod(name)) |fidx| {
                        for (c.arguments) |arg| try self.emitExpr(arg);
                        try self.chunk.writeOp(.op_call, loc);
                        try self.chunk.writeU16(fidx);
                        try self.chunk.writeByte(argc);
                        return;
                    }
                    const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, name) });
                    for (c.arguments) |arg| try self.emitExpr(arg); // [recv, rest...]
                    try self.chunk.writeOp(.op_call_method, loc);
                    try self.chunk.writeU16(name_const);
                    try self.chunk.writeByte(argc - 1);
                    return;
                }
                // M5k：零参 trait 方法裸名调用（`zero()`）→ 无 receiver 不能按类型分派，直接解析到
                // 登记的 impl 函数（OP_CALL func_idx，argc=0）。返回类型导向分派在 VM 不可得，单 impl 即解析。
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

    fn emitIf(self: *FnCompiler, ie: @TypeOf(@as(Expr, undefined).if_expr), loc: ast.SourceLocation) CompileError!void {
        try self.emitExpr(ie.condition);
        const else_jump = try self.chunk.emitJump(.op_jump_if_false, loc);
        try self.chunk.writeOp(.op_pop, loc); // then：弹 cond
        try self.emitExpr(ie.then_branch);
        const end_jump = try self.chunk.emitJump(.op_jump, loc);
        self.chunk.patchJump(else_jump);
        try self.chunk.writeOp(.op_pop, loc); // else：弹 cond
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
        const scrut_slot = try self.declareLocal("$scrut", false);
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
                    const slot = try self.declareLocal(v.name, false);
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
                    const tmp = try self.declareLocal("$thr", false);
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
                    const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, ctor.name) });
                    try self.chunk.writeOp(.op_test_newtype, loc);
                    try self.chunk.writeU16(name_const);
                    try fail_jumps.append(self.allocator, try self.chunk.emitJump(.op_jump_if_false, loc));
                    try self.chunk.writeOp(.op_pop, loc);
                    // 解 inner 进临时 slot 递归。
                    const tmp = try self.declareLocal("$nt", false);
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
                        const tmp = try self.declareLocal("$fld", false);
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
                    const tmp = try self.declareLocal("$rf", false);
                    try self.chunk.writeOp(.op_get_local, loc);
                    try self.chunk.writeU16(scrut_slot);
                    const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, f.name) });
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
        const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, name) });
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
                    const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, v.name) });
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
                // 局部函数 fun go(){...go()...}）。slot 先置 unit 占位并 box 成 cell，lambda 经
                // OP_CLOSURE is_local 捕获同一 cell；随后 set_local 写 cell.inner=闭包，递归调用
                // 经 upvalue 读到该 cell 即得闭包本身（镜像 eval 的 letrec 弱自引用）。
                if (d.value.* == .lambda) {
                    const slot = try self.declareLocal(d.name, false);
                    try self.chunk.writeOp(.op_unit, d.location);
                    try self.chunk.writeOp(.op_set_local, d.location);
                    try self.chunk.writeU16(slot);
                    try self.emitExpr(d.value); // lambda 可解析到 slot（已声明）
                    try self.chunk.writeOp(.op_set_local_letrec, d.location);
                    try self.chunk.writeU16(slot);
                } else {
                    try self.emitBindingRhs(d.value);
                    try self.emitCoerceFromAnnotation(d.type_annotation, d.location); // M5：val a: i32 = ...
                    const slot = try self.declareLocal(d.name, false);
                    try self.chunk.writeOp(.op_set_local, d.location);
                    try self.chunk.writeU16(slot);
                }
            },
            .var_decl => |d| {
                try self.emitBindingRhs(d.value);
                try self.emitCoerceFromAnnotation(d.type_annotation, d.location); // M5：var a: i32 = ...
                const slot = try self.declareLocal(d.name, true);
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
                if (self.resolveLocal(name)) |slot| {
                    try self.emitExpr(a.value);
                    try self.chunk.writeOp(.op_set_local, a.location);
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
            .for_stmt => |f| try self.emitFor(f),
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
                try self.emitExpr(t.expr);
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
    fn emitFor(self: *FnCompiler, f: @TypeOf(@as(Stmt, undefined).for_stmt)) CompileError!void {
        const loc = f.location;
        const saved = self.locals.items.len;
        // 隐藏 slot：iterable 值 + index（i64，初始 0）。
        try self.emitExpr(f.iterable);
        const iter_slot = try self.declareLocal("$iter", false);
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(iter_slot);
        const idx_const = try self.chunk.addConstant(Value{ .integer = .{ .value = 0, .type_tag = .i64 } });
        try self.emitConst(idx_const, loc);
        const idx_slot = try self.declareLocal("$idx", true);
        try self.chunk.writeOp(.op_set_local, loc);
        try self.chunk.writeU16(idx_slot);
        // 循环变量 slot（每轮 OP_FOR_NEXT 压元素后 set_local 绑定）。
        const var_slot = try self.declareLocal(f.name, true);

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
        const name_const = try self.chunk.addConstant(Value{ .string = try self.allocator.dupe(u8, fa.field) });
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

/// 解析整数字面量为 Value（镜像 eval.zig evalIntLiteral 的默认最小类型推断）。
fn parseIntLiteral(lit: @TypeOf(@as(Expr, undefined).int_literal)) ?Value {
    const int_val: u128 = std.fmt.parseInt(u128, lit.raw, 0) catch
        @bitCast(std.fmt.parseInt(i128, lit.raw, 0) catch return null);
    if (lit.suffix) |s| {
        const t = value.IntType.fromName(s) orelse return null;
        if (!t.inRange(int_val)) return null;
        return Value{ .integer = .{ .value = int_val, .type_tag = t } };
    }
    const t = value.inferIntType(int_val);
    if (!t.inRange(int_val)) return null;
    return Value{ .integer = .{ .value = int_val, .type_tag = t } };
}

fn parseFloatLiteral(lit: @TypeOf(@as(Expr, undefined).float_literal)) ?Value {
    const fv = std.fmt.parseFloat(f128, lit.raw) catch return null;
    if (std.math.isNan(fv) or std.math.isInf(fv)) return null;
    if (lit.suffix) |s| {
        const t = value.FloatType.fromName(s) orelse return null;
        return Value{ .float = .{ .value = fv, .type_tag = t } };
    }
    return Value{ .float = .{ .value = fv, .type_tag = value.inferFloatType(fv) } };
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

/// M5c：若 TypeNode 是 builtin 数值类型，返回其名（借用 AST 字节）；否则 null。
/// 供 ADT 字段隐式定型用（仅数值字段需协调 type_tag）。
fn builtinNumericTypeOf(ty: *const ast.TypeNode) ?[]const u8 {
    return switch (ty.*) {
        .named => |n| if (isBuiltinNumericType(n.name)) n.name else null,
        else => null,
    };
}

/// 模式字面量 → Value 常量（供 OP_TEST_LIT 比较）。int 用 u128 位模式（负数 bitcast，
/// 与 OP_TEST_LIT 仅比值忽略 tag 一致）。string 须 dupe（常量池随 chunk deinit 释放）。
/// 不支持的字面量（解析失败）返回 null → 调用方 Unsupported（回退树遍历器）。
/// 注：pattern 的 int/float 原始文本含类型后缀（如 "1i64"/"2.0f32"），须剥离后再 parse。
fn patternLiteralToValue(allocator: std.mem.Allocator, lit: ast.PatternLiteral) CompileError!?Value {
    return switch (lit) {
        .int => |raw| blk: {
            const iv = parsePatternInt(raw) orelse break :blk null;
            break :blk Value{ .integer = .{ .value = iv, .type_tag = .i64 } };
        },
        .float => |raw| blk: {
            const end = floatBodyEnd(raw);
            const fv = std.fmt.parseFloat(f128, raw[0..end]) catch break :blk null;
            break :blk Value{ .float = .{ .value = fv, .type_tag = .f64 } };
        },
        .bool => |b| Value{ .boolean = b },
        .char => |c| Value{ .char_val = c },
        .string => |s| Value{ .string = try allocator.dupe(u8, s) },
        .null => Value.null_val,
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

/// 解析 pattern 整数字面量（含进制前缀 0x/0o/0b、i/u 类型后缀、下划线），返回 u128 位模式。
fn parsePatternInt(raw: []const u8) ?u128 {
    var i: usize = 0;
    var base: u8 = 10;
    if (raw.len > 2 and raw[0] == '0') {
        switch (raw[1]) {
            'x', 'X' => { base = 16; i = 2; },
            'o', 'O' => { base = 8; i = 2; },
            'b', 'B' => { base = 2; i = 2; },
            else => {},
        }
    }
    // 剥离 i/u 类型后缀（仅 i/u 后跟十进制数字，避免误剥十六进制 A–F）。
    var end = raw.len;
    var j = end;
    while (j > i and raw[j - 1] >= '0' and raw[j - 1] <= '9') j -= 1;
    if (j > i and j < end and (raw[j - 1] == 'i' or raw[j - 1] == 'u' or raw[j - 1] == 'I' or raw[j - 1] == 'U')) end = j - 1;
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (i < end) : (i += 1) {
        if (raw[i] == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = raw[i];
        n += 1;
    }
    if (n == 0) return 0;
    if (std.fmt.parseInt(u128, buf[0..n], base)) |v| return v else |_| {}
    if (std.fmt.parseInt(i128, buf[0..n], base)) |v| return @bitCast(v) else |_| {}
    return null;
}

// ============================================================
// 测试
// ============================================================

const vm_mod = @import("vm.zig");

test {
    std.testing.refAllDecls(@import("disasm.zig"));
    std.testing.refAllDecls(@import("cast.zig"));
}

/// 测试 harness：source → 解析 → 编译 → 调用 entry_name(args)，返回结果整数值。
/// 解析用 arena（与 main.zig 真实管线一致：AST 节点/子切片一次性释放）。
/// Program/VM 用传入 allocator（值字节走 refcount，须精确配对，验证无泄漏）。
fn compileAndCall(allocator: std.mem.Allocator, source: []const u8, entry_name: []const u8, args: []const Value) !u128 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var lex = lexer.Lexer.init(aa, source);
    const tokens = try lex.tokenize();

    var p = parser.Parser.init(aa, tokens);
    var module = try p.parseModule("test");

    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModule(&module);

    const idx = mc.lookupFn(entry_name) orelse return error.MissingFunction;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    const result = try vm.call(&mc.program, idx, args);
    defer result.releaseVM(allocator);
    // bool 结果（contains/is_empty 等）coerce 为 1/0，便于测试统一用 u128 断言。
    if (result == .boolean) return if (result.boolean) 1 else 0;
    return result.integer.value;
}

/// M5j：编译入口源 + 一个依赖源（依赖在前注册），跑 entry_name，返回整数结果。
fn compileAndCallWithDep(allocator: std.mem.Allocator, dep_source: []const u8, entry_source: []const u8, entry_name: []const u8) !u128 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var dlex = lexer.Lexer.init(aa, dep_source);
    const dtokens = try dlex.tokenize();
    var dp = parser.Parser.init(aa, dtokens);
    const dep_module = try dp.parseModule("Dep");

    var elex = lexer.Lexer.init(aa, entry_source);
    const etokens = try elex.tokenize();
    var ep = parser.Parser.init(aa, etokens);
    var entry_module = try ep.parseModule("test");

    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModuleWithDeps(&entry_module, &.{dep_module});

    const idx = mc.lookupFn(entry_name) orelse return error.MissingFunction;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    const result = try vm.call(&mc.program, idx, &.{});
    defer result.releaseVM(allocator);
    if (result == .boolean) return if (result.boolean) 1 else 0;
    return result.integer.value;
}

/// M5e：编译并执行 entry，返回原始 Value（调用方负责 releaseVM）。供检查 throw_val/string 等
/// 非整数结果的测试。arena 在返回前 deinit，故结果不可借用 AST 字节（error_newtype 走 dupe 安全）。
fn compileAndValue(allocator: std.mem.Allocator, program_out: *Program, source: []const u8, entry_name: []const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var lex = lexer.Lexer.init(aa, source);
    const tokens = try lex.tokenize();
    var p = parser.Parser.init(aa, tokens);
    var module = try p.parseModule("test");
    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    try mc.compileModule(&module);
    program_out.* = mc.program; // 移交 program 所有权给调用方（持有 error_ctors 等借用 AST 的描述）
    const idx = mc.lookupFn(entry_name) orelse return error.MissingFunction;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    return try vm.call(program_out, idx, &.{});
}

test "M1a fib(10) = 55" {
    const allocator = std.testing.allocator;
    const src =
        \\fun fib(n: i64): i64 {
        \\    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
        \\}
    ;
    const arg = Value{ .integer = .{ .value = 10, .type_tag = .i64 } };
    try std.testing.expectEqual(@as(u128, 55), try compileAndCall(allocator, src, "fib", &.{arg}));
}

test "M1a fib(20) = 6765" {
    const allocator = std.testing.allocator;
    const src =
        \\fun fib(n: i64): i64 {
        \\    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
        \\}
    ;
    const arg = Value{ .integer = .{ .value = 20, .type_tag = .i64 } };
    try std.testing.expectEqual(@as(u128, 6765), try compileAndCall(allocator, src, "fib", &.{arg}));
}

test "M1a lookup compute: while loop + locals + call" {
    const allocator = std.testing.allocator;
    // lookup bench 的 compute 函数。注意：独立编译器**不跑 type_check**，
    // 故字面量按"最小容纳类型"推断（0→i8）。真实管线会按 `:i64` 标注 castValue 强转，
    // 这里用 i64 后缀显式锁定类型，诚实验证 VM 实际行为（while/局部/取模/算术）。
    const src =
        \\fun compute(seed: i64): i64 {
        \\    val a: i64 = seed + 1i64
        \\    val b: i64 = seed + 2i64
        \\    val c: i64 = seed + 3i64
        \\    val d: i64 = seed + 4i64
        \\    var acc: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val t: i64 = (a + b + c + d + i) % 1024i64
        \\        acc = (acc + t) % 1048576i64
        \\        i = i + 1i64
        \\    }
        \\    acc
        \\}
    ;
    // compute(0): 每轮 t=(10+i)%1024, acc 累加。sum_{i=0}^{999}(10+i)=10000+499500=509500，
    // 全程 t<1024、acc<1048576 未触模上限 → 509500。
    const arg = Value{ .integer = .{ .value = 0, .type_tag = .i64 } };
    try std.testing.expectEqual(@as(u128, 509500), try compileAndCall(allocator, src, "compute", &.{arg}));
}

// ── M1b-1：一等函数值 + 栈式调用 + 默认柯里化 ──

test "M1b-1 first-class fn value: val f = fib; f(10)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun fib(n: i64): i64 { if (n < 2) { n } else { fib(n - 1) + fib(n - 2) } }
        \\fun run(): i64 { val f = fib; f(10) }
    ;
    try std.testing.expectEqual(@as(u128, 55), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-1 higher-order: apply(g, x) { g(x) }; apply(fib, 10)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun fib(n: i64): i64 { if (n < 2) { n } else { fib(n - 1) + fib(n - 2) } }
        \\fun apply(g, x): i64 { g(x) }
        \\fun run(): i64 { apply(fib, 10) }
    ;
    try std.testing.expectEqual(@as(u128, 55), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-1 currying: bind partial then apply == 8" {
    const allocator = std.testing.allocator;
    // 语言禁止链式调用 f(a)(b)（parser），柯里化须经变量绑定 —— 这是 Glue 既定惯用法。
    const src =
        \\fun add(a: i64, b: i64): i64 { a + b }
        \\fun run(): i64 { val add5 = add(5i64); add5(3i64) }
    ;
    try std.testing.expectEqual(@as(u128, 8), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-1 currying via local: val add5 = add(5); add5(3) == 8" {
    const allocator = std.testing.allocator;
    const src =
        \\fun add(a: i64, b: i64): i64 { a + b }
        \\fun run(): i64 { val add5 = add(5i64); add5(3i64) }
    ;
    try std.testing.expectEqual(@as(u128, 8), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-1 currying 3-arg stepwise: bind each partial == 6" {
    const allocator = std.testing.allocator;
    const src =
        \\fun add3(a: i64, b: i64, c: i64): i64 { a + b + c }
        \\fun run(): i64 { val f = add3(1i64); val g = f(2i64); g(3i64) }
    ;
    try std.testing.expectEqual(@as(u128, 6), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-1 wrong arity: add(1,2,3) errors" {
    const allocator = std.testing.allocator;
    const src =
        \\fun add(a: i64, b: i64): i64 { a + b }
        \\fun run(): i64 { add(1i64, 2i64, 3i64) }
    ;
    try std.testing.expectError(error.WrongArity, compileAndCall(allocator, src, "run", &.{}));
}

// ── M1b-2：闭包 upvalue 捕获 + cell 共享可变状态 ──

test "M1b-2 capture var: external mutation visible (read-after-mutate)" {
    const allocator = std.testing.allocator;
    // read 闭包捕获 x；x 后续被改，闭包读到新值（cell 共享）。
    const src =
        \\fun run(): i64 {
        \\    var x: i64 = 10i64
        \\    val read = fun() { x }
        \\    x = 20i64
        \\    read()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 20), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-2 closure mutates captured var, visible outside" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var y: i64 = 0i64
        \\    val inc = fun() { y = y + 1i64 }
        \\    inc()
        \\    inc()
        \\    y
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 2), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-2 nested closures share the same captured var" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var count: i64 = 0i64
        \\    val outer = fun() {
        \\        val inner = fun() { count = count + 1i64 }
        \\        inner()
        \\        inner()
        \\    }
        \\    outer()
        \\    outer()
        \\    count
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 4), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-2 escaping closure: makeCounter state persists across calls" {
    const allocator = std.testing.allocator;
    // 逃逸闭包：捕获的 cell 寿命独立于 makeCounter 帧，返回后仍可变。
    const src =
        \\fun makeCounter(): i64 {
        \\    var n: i64 = 0i64
        \\    fun() { n = n + 1i64  n }
        \\}
        \\fun run(): i64 {
        \\    val c = makeCounter()
        \\    c()
        \\    c()
        \\    c()
        \\}
    ;
    // makeCounter 返回的是闭包（i64 标注仅占位，VM 不跑 type_check）；c() 三次 → 3。
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-2 two counters are independent" {
    const allocator = std.testing.allocator;
    const src =
        \\fun makeCounter(): i64 {
        \\    var n: i64 = 0i64
        \\    fun() { n = n + 1i64  n }
        \\}
        \\fun run(): i64 {
        \\    val a = makeCounter()
        \\    val b = makeCounter()
        \\    a()
        \\    a()
        \\    val bv = b()
        \\    val av = a()
        \\    av * 10i64 + bv
        \\}
    ;
    // a 调 3 次 → av=3；b 调 1 次 → bv=1；结果 31（独立计数）。
    try std.testing.expectEqual(@as(u128, 31), try compileAndCall(allocator, src, "run", &.{}));
}

test "disasm run" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var x: i64 = 10i64
        \\    val read = fun() { x }
        \\    x = 20i64
        \\    read()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 20), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M1b-3：尾调用优化 OP_TAIL_CALL（尾位置复用帧，深尾递归不爆栈）──

test "M1b-3 deep tail recursion does not overflow (countDown 1M)" {
    const allocator = std.testing.allocator;
    // 100 万层尾递归；无 TCO 必爆 MAX_FRAMES(64K)。TCO 复用单帧 → 返回 0。
    const src =
        \\fun countDown(n: i64): i64 { if (n <= 0i64) { 0i64 } else { countDown(n - 1i64) } }
        \\fun run(): i64 { countDown(1000000i64) }
    ;
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-3 tail-recursive accumulator sumTo(100)=5050" {
    const allocator = std.testing.allocator;
    const src =
        \\fun sumTo(n: i64, acc: i64): i64 { if (n <= 0i64) { acc } else { sumTo(n - 1i64, acc + n) } }
        \\fun run(): i64 { sumTo(100i64, 0i64) }
    ;
    try std.testing.expectEqual(@as(u128, 5050), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-3 tail-recursive factorial fact(5,1)=120 (deep arg eval ok)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun fact(n: i64, acc: i64): i64 { if (n <= 1i64) { acc } else { fact(n - 1i64, acc * n) } }
        \\fun run(): i64 { fact(5i64, 1i64) }
    ;
    try std.testing.expectEqual(@as(u128, 120), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-3 mutual tail recursion isEven(1M)=1, isOdd via tail" {
    const allocator = std.testing.allocator;
    // 互递归尾调用各 100 万层；TCO 使两者都复用单帧。
    const src =
        \\fun isEven(n: i64): i64 { if (n == 0i64) { 1i64 } else { isOdd(n - 1i64) } }
        \\fun isOdd(n: i64): i64 { if (n == 0i64) { 0i64 } else { isEven(n - 1i64) } }
        \\fun run(): i64 { isEven(1000000i64) }
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M1b-3 non-tail call still works (returns via OP_RETURN)" {
    const allocator = std.testing.allocator;
    // f(x)+1 中 f(x) 非尾位置（结果还要 +1）→ 走 OP_CALL+OP_RETURN，不退化。
    const src =
        \\fun dbl(n: i64): i64 { n * 2i64 }
        \\fun run(): i64 { dbl(10i64) + 1i64 }
    ;
    try std.testing.expectEqual(@as(u128, 21), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M2a：复合值 / 模式匹配 ──

test "M2a ADT construct + named field access: Point(3,4).x == 3" {
    const allocator = std.testing.allocator;
    const src =
        \\type Point = Point(x: i64, y: i64)
        \\fun run(): i64 { val p = Point(3i64, 4i64); p.x }
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2a ADT field access second field: Point(3,4).y == 4" {
    const allocator = std.testing.allocator;
    const src =
        \\type Point = Point(x: i64, y: i64)
        \\fun run(): i64 { val p = Point(3i64, 4i64); p.y }
    ;
    try std.testing.expectEqual(@as(u128, 4), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2a single-constructor match binds fields: dist2(Point(3,4)) == 25" {
    const allocator = std.testing.allocator;
    const src =
        \\type Point = Point(x: i64, y: i64)
        \\fun dist2(p: Point): i64 { match p { Point(x, y) => x * x + y * y } }
        \\fun run(): i64 { dist2(Point(3i64, 4i64)) }
    ;
    try std.testing.expectEqual(@as(u128, 25), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2a match wildcard field + variable whole-binding" {
    const allocator = std.testing.allocator;
    const src =
        \\type Point = Point(x: i64, y: i64)
        \\fun getx(p: Point): i64 { match p { Point(x, _) => x } }
        \\fun run(): i64 { getx(Point(7i64, 9i64)) }
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2a record bench kernel: sum over 1000 iterations" {
    const allocator = std.testing.allocator;
    // record bench 的缩小版（1000 次而非百万），验证构造+字段+match 组合正确。
    const src =
        \\type Point = Point(x: i64, y: i64)
        \\fun dist2(p: Point): i64 { match p { Point(x, y) => x * x + y * y } }
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val p = Point(i, i + 1i64)
        \\        sum = sum + dist2(p) + p.x - p.y
        \\        i = i + 1i64
        \\    }
        \\    sum
        \\}
    ;
    // sum = Σ_{i=0}^{999} (i² + (i+1)² + i - (i+1)) = Σ (i² + (i+1)² - 1)
    var expected: i128 = 0;
    var i: i128 = 0;
    while (i < 1000) : (i += 1) expected += i * i + (i + 1) * (i + 1) + i - (i + 1);
    try std.testing.expectEqual(@as(u128, @intCast(expected)), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M2b：数组 / 记录字面量 / 索引 ──

test "M2b array literal + index: [10,20,30][1] == 20" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a = [10i64, 20i64, 30i64]; a[1i64] }
    ;
    try std.testing.expectEqual(@as(u128, 20), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2b array index with computed index expr" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a = [5i64, 6i64, 7i64, 8i64]; val i = 1i64 + 2i64; a[i] }
    ;
    try std.testing.expectEqual(@as(u128, 8), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2b record literal + field access: (x:7,y:9).y == 9" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val r = (x: 7i64, y: 9i64); r.y }
    ;
    try std.testing.expectEqual(@as(u128, 9), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2b record field read both + arithmetic" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val r = (a: 3i64, b: 4i64); r.a * r.b }
    ;
    try std.testing.expectEqual(@as(u128, 12), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2b nested array of records: sum field across elements" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val arr = [(v: 10i64), (v: 20i64), (v: 30i64)]
        \\    arr[0i64].v + arr[1i64].v + arr[2i64].v
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 60), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2b array churn under leak-checked allocator (loop builds + indexes)" {
    const allocator = std.testing.allocator;
    // 反复构造数组 + 索引，验证 --gpa 干净（无 leak/double-free）。
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val a = [i, i + 1i64, i + 2i64]
        \\        sum = sum + a[0i64] + a[1i64] + a[2i64]
        \\        i = i + 1i64
        \\    }
        \\    sum
        \\}
    ;
    // Σ_{i=0}^{999} (i + (i+1) + (i+2)) = Σ (3i + 3)
    var expected: i128 = 0;
    var i: i128 = 0;
    while (i < 1000) : (i += 1) expected += 3 * i + 3;
    try std.testing.expectEqual(@as(u128, @intCast(expected)), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M2c：全模式 match / 记录扩展 / newtype ──

test "M2c literal pattern int: match 2 => 20" {
    const allocator = std.testing.allocator;
    const src =
        \\fun classify(n: i64): i64 { match n { 1i64 => 10i64, 2i64 => 20i64, _ => 0i64 } }
        \\fun run(): i64 { classify(2i64) }
    ;
    try std.testing.expectEqual(@as(u128, 20), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c literal pattern fallthrough to wildcard" {
    const allocator = std.testing.allocator;
    const src =
        \\fun classify(n: i64): i64 { match n { 1i64 => 10i64, 2i64 => 20i64, _ => 99i64 } }
        \\fun run(): i64 { classify(7i64) }
    ;
    try std.testing.expectEqual(@as(u128, 99), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c or-pattern: 0 | 1 | 2 => small(1) else 0" {
    const allocator = std.testing.allocator;
    const src =
        \\fun sz(n: i64): i64 { match n { 0i64 | 1i64 | 2i64 => 1i64, _ => 0i64 } }
        \\fun run(): i64 { sz(1i64) + sz(2i64) + sz(5i64) }
    ;
    // sz(1)=1, sz(2)=1, sz(5)=0 → 2
    try std.testing.expectEqual(@as(u128, 2), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c nullary ctor enum match: Red|Green|Blue" {
    const allocator = std.testing.allocator;
    const src =
        \\type Color = | Red | Green | Blue
        \\fun code(c: Color): i64 { match c { Red => 1i64, Green => 2i64, Blue => 3i64 } }
        \\fun run(): i64 { code(Green) }
    ;
    try std.testing.expectEqual(@as(u128, 2), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c multi-constructor ADT match with field binding" {
    const allocator = std.testing.allocator;
    const src =
        \\type Shape = | Circle(r: i64) | Rect(w: i64, h: i64)
        \\fun area(s: Shape): i64 { match s { Circle(r) => 3i64 * r * r, Rect(w, h) => w * h } }
        \\fun run(): i64 { area(Circle(2i64)) + area(Rect(3i64, 4i64)) }
    ;
    // Circle(2): 3*4=12, Rect(3,4): 12 → 24
    try std.testing.expectEqual(@as(u128, 24), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c nested constructor pattern" {
    const allocator = std.testing.allocator;
    const src =
        \\type Inner = Inner(v: i64)
        \\type Outer = Outer(i: Inner, k: i64)
        \\fun get(o: Outer): i64 { match o { Outer(Inner(v), k) => v + k } }
        \\fun run(): i64 { get(Outer(Inner(10i64), 5i64)) }
    ;
    try std.testing.expectEqual(@as(u128, 15), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c guard pattern: x if x > 5" {
    const allocator = std.testing.allocator;
    const src =
        \\fun g(n: i64): i64 { match n { x if x > 5i64 => 100i64, _ => 0i64 } }
        \\fun run(): i64 { g(8i64) + g(3i64) }
    ;
    // g(8)=100 (guard true), g(3)=0 → 100
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c record pattern destructure" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val p = (x: 3i64, y: 4i64)
        \\    match p { (x: a, y: b) => a * 10i64 + b }
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 34), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c record extend: override + add field" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val base = (x: 1i64, y: 2i64)
        \\    val ext = (...base, y: 20i64, z: 30i64)
        \\    ext.x + ext.y + ext.z
        \\}
    ;
    // x=1 (kept), y=20 (overridden), z=30 (added) → 51
    try std.testing.expectEqual(@as(u128, 51), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c newtype construct + match destructure" {
    const allocator = std.testing.allocator;
    const src =
        \\type Handle = Handle(i64)
        \\fun unwrap(h: Handle): i64 { match h { Handle(v) => v } }
        \\fun run(): i64 { unwrap(Handle(42i64)) }
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M2c match churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\type Shape = | Circle(r: i64) | Rect(w: i64, h: i64)
        \\fun area(s: Shape): i64 { match s { Circle(r) => r * r, Rect(w, h) => w * h } }
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val s = if (i % 2i64 == 0i64) { Circle(i) } else { Rect(i, i + 1i64) }
        \\        sum = sum + area(s)
        \\        i = i + 1i64
        \\    }
        \\    sum
        \\}
    ;
    var expected: i128 = 0;
    var i: i128 = 0;
    while (i < 1000) : (i += 1) expected += if (@mod(i, 2) == 0) i * i else i * (i + 1);
    try std.testing.expectEqual(@as(u128, @intCast(expected)), try compileAndCall(allocator, src, "run", &.{}));
}


// ── M3a：字符串插值 / 类型转换 ──

/// 测试 harness（字符串结果版）：返回 entry 的字符串返回值（调用方持有，须 free）。
fn compileAndCallStr(allocator: std.mem.Allocator, source: []const u8, entry_name: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var lex = lexer.Lexer.init(aa, source);
    const tokens = try lex.tokenize();
    var p = parser.Parser.init(aa, tokens);
    var module = try p.parseModule("test");
    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModule(&module);
    const idx = mc.lookupFn(entry_name) orelse return error.MissingFunction;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    const result = try vm.call(&mc.program, idx, &.{});
    defer result.releaseVM(allocator);
    if (result != .string) return error.NotAString;
    return allocator.dupe(u8, result.string);
}

test "M3a string literal returned" {
    const allocator = std.testing.allocator;
    const s = try compileAndCallStr(allocator, "fun run(): str { \"hello\" }", "run");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "M3a string interpolation: int + text" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): str { val x: i64 = 42i64; "value is {x}!" }
    ;
    const s = try compileAndCallStr(allocator, src, "run");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("value is 42!", s);
}

test "M3a string interpolation: multiple exprs" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): str { val a: i64 = 3i64; val b: i64 = 4i64; "{a} + {b} = {a + b}" }
    ;
    const s = try compileAndCallStr(allocator, src, "run");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("3 + 4 = 7", s);
}

test "M3a type_cast int widening i32->i64 (value preserved)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val x: i32 = 100i32; i64(x) }
    ;
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3a type_cast float->int truncates" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val x: f64 = 3.9f64; i64(x) }
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3a type_cast int->str" {
    const allocator = std.testing.allocator;
    const s = try compileAndCallStr(allocator, "fun run(): str { str(255i64) }", "run");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("255", s);
}

test "M3a type_cast narrowing overflow panics" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): u8 { val x: i64 = 300i64; u8(x) }
    ;
    try std.testing.expectError(error.ArithmeticOverflow, compileAndCall(allocator, src, "run", &.{}));
}

test "M3a string interpolation churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val s: str = "iter {i} of many"
        \\        i = i + 1i64
        \\    }
        \\    i
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 1000), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M3b：break/continue/loop + 复合赋值 + 字段赋值 ──

test "M3b while + break: stop at 5" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var i: i64 = 0i64
        \\    while i < 100i64 {
        \\        if (i == 5i64) { break }
        \\        i = i + 1i64
        \\    }
        \\    i
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b while + continue: sum evens 0..9 = 20" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var i: i64 = 0i64
        \\    var sum: i64 = 0i64
        \\    while i < 10i64 {
        \\        i = i + 1i64
        \\        if ((i - 1i64) % 2i64 == 1i64) { continue }
        \\        sum = sum + (i - 1i64)
        \\    }
        \\    sum
        \\}
    ;
    // i-1 over 0..9; add when even → 0+2+4+6+8 = 20
    try std.testing.expectEqual(@as(u128, 20), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b loop + break: count to 7" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var i: i64 = 0i64
        \\    loop {
        \\        i = i + 1i64
        \\        if (i == 7i64) { break }
        \\    }
        \\    i
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b nested loops with break" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 5i64 {
        \\        var j: i64 = 0i64
        \\        while j < 100i64 {
        \\            if (j == 3i64) { break }
        \\            total = total + 1i64
        \\            j = j + 1i64
        \\        }
        \\        i = i + 1i64
        \\    }
        \\    total
        \\}
    ;
    // inner adds 3 per outer iter (j=0,1,2), 5 outer → 15
    try std.testing.expectEqual(@as(u128, 15), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b compound assign += -= *= %=" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var x: i64 = 10i64
        \\    x += 5i64
        \\    x -= 2i64
        \\    x *= 3i64
        \\    x %= 7i64
        \\    x
        \\}
    ;
    // ((10+5-2)*3) % 7 = 39 % 7 = 4
    try std.testing.expectEqual(@as(u128, 4), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b field assignment on record" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var p = (x: 1i64, y: 2i64)
        \\    p.x = 100i64
        \\    p.x + p.y
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 102), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b field assignment value semantics (COW)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var a = (x: 1i64, y: 2i64)
        \\    var b = a
        \\    b.x = 99i64
        \\    a.x + b.x
        \\}
    ;
    // a.x stays 1 (COW), b.x = 99 → 100
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3b loop churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var i: i64 = 0i64
        \\    var hits: i64 = 0i64
        \\    while i < 1000i64 {
        \\        var p = (x: i, y: i)
        \\        p.x = i + 1i64
        \\        hits += p.x
        \\        i += 1i64
        \\    }
        \\    hits
        \\}
    ;
    var expected: i128 = 0;
    var i: i128 = 0;
    while (i < 1000) : (i += 1) expected += i + 1;
    try std.testing.expectEqual(@as(u128, @intCast(expected)), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M3c：异常 / 传播 / 非空断言 / elvis ──

test "M3c elvis ?? on null/non-null" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a: i64? = null; a ?? 42i64 }
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c elvis ?? non-null uses left" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a: i64? = 7i64; a ?? 42i64 }
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c elvis chain right-assoc" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a: i64? = null; val b: i64? = null; a ?? b ?? 9i64 }
    ;
    try std.testing.expectEqual(@as(u128, 9), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c non-null assert on non-null" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a: i64? = 5i64; a! }
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c non-null assert on null panics" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a: i64? = null; a! }
    ;
    try std.testing.expectError(error.NonNullAssertFailed, compileAndCall(allocator, src, "run", &.{}));
}

test "M3c Ok + match unwraps value" {
    const allocator = std.testing.allocator;
    const src =
        \\fun mk(): Throw<i64, Error> { Ok(99i64) }
        \\fun run(): i64 { match mk() { Ok(v) => v, Error(e) => -1i64 } }
    ;
    try std.testing.expectEqual(@as(u128, 99), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c throw + match Error branch" {
    const allocator = std.testing.allocator;
    const src =
        \\fun mk(): Throw<i64, Error> { throw Error("boom") }
        \\fun run(): i64 { match mk() { Ok(v) => v, Error(e) => -1i64 } }
    ;
    // -1 as u64 bit pattern
    const r = try compileAndCall(allocator, src, "run", &.{});
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(@as(u64, @truncate(r)))));
}

test "M5 implicit param coercion: i8 literal arg -> i32 param (no overflow loop)" {
    const allocator = std.testing.allocator;
    // countDown 终止依赖 n==0：n 协调成 i32，字面量 0 是 i8，== 须按值比较（非 tag-strict）。
    const src =
        \\fun countDown(n: i32): i32 {
        \\    if (n == 0) { 0 } else { countDown(n - 1) }
        \\}
    ;
    const arg = Value{ .integer = .{ .value = 100, .type_tag = .i8 } };
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "countDown", &.{arg}));
}

test "M5 val annotation coercion widens to i64" {
    const allocator = std.testing.allocator;
    // 大数累加：若 sum 不协调成 i64 会在 i8/i16 溢出 panic。
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0
        \\    var i: i64 = 0
        \\    while i < 1000 { sum = sum + i; i = i + 1 }
        \\    sum
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 499500), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5 string concatenation with +" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): str { "foo" + "bar" }
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var lx = lexer.Lexer.init(aa, src);
    const toks = try lx.tokenize();
    var p = parser.Parser.init(aa, toks);
    var module = try p.parseModule("t");
    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModule(&module);
    const idx = mc.lookupFn("run").?;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    const result = try vm.call(&mc.program, idx, &.{});
    defer result.releaseVM(allocator);
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("foobar", result.string);
}

test "M5 string ordering comparison" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): bool { "apple" < "banana" }
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5 bare value matches Ok pattern (implicit Throw)" {
    const allocator = std.testing.allocator;
    // checked 返回裸值 5（非 Ok 包装），match Ok(v) 须绑定裸值本身（镜像 eval）。
    const src =
        \\fun checked(x: i32): Throw<i32, Error> { if (x >= 0) { x } else { throw Error("neg") } }
        \\fun run(): i32 { match checked(5) { Ok(v) => v, Error(e) => -1 } }
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5b array concat ++ length" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val a = [1i64, 2i64]
        \\    val b = [3i64, 4i64, 5i64]
        \\    val c = a ++ b
        \\    c.len()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5b atomic aliased via val binding preserves reference" {
    const allocator = std.testing.allocator;
    // val c = counter 须保留 atomic 引用：c += 1 对 counter 可见（镜像 eval atomic 引用语义）。
    const src =
        \\fun run(): i64 {
        \\    var counter = atomic 0i64
        \\    val c = counter
        \\    c += 1i64
        \\    counter
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5b for-loop var captured by closure (cell-boxed idx)" {
    const allocator = std.testing.allocator;
    // 循环体内闭包捕获使 slot box 成 cell；doForNext 须透明解包 idx/iter。
    const src =
        \\fun run(): i64 {
        \\    var sum = atomic 0i64
        \\    for i in 1..=5 {
        \\        val s = sum
        \\        val f = fun() { s += 1i64 }
        \\        f()
        \\    }
        \\    sum
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5c recursive local function (letrec)" {
    const allocator = std.testing.allocator;
    // 嵌套 fun go 递归求和 1..=n；go 在自身体内是 upvalue，须经 letrec 自引用解析。
    const src =
        \\fun sumTo(n: i64): i64 {
        \\    fun go(i: i64, acc: i64): i64 {
        \\        if (i == 0i64) { acc } else { go(i - 1i64, acc + i) }
        \\    }
        \\    go(n, 0i64)
        \\}
    ;
    const arg = Value{ .integer = .{ .value = 10, .type_tag = .i64 } };
    try std.testing.expectEqual(@as(u128, 55), try compileAndCall(allocator, src, "sumTo", &.{arg}));
}

test "M5c ADT field coercion widens i8 literal to declared i32" {
    const allocator = std.testing.allocator;
    // Emp(.., salary: i32)：实参 100 推断成 i8，构造时须协调成 i32，否则 s*pct 溢出 i8。
    const src =
        \\type Emp = Emp(id: i32, salary: i32)
        \\fun raise(e: Emp): i32 { match e { Emp(_, s) => s + s * 50 / 100 } }
        \\fun run(): i32 { raise(Emp(1, 100)) }
    ;
    try std.testing.expectEqual(@as(u128, 150), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5b type() builtin returns runtime type name" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): str { type(42i32) }
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var lx = lexer.Lexer.init(aa, src);
    const toks = try lx.tokenize();
    var p = parser.Parser.init(aa, toks);
    var module = try p.parseModule("t");
    var mc = ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModule(&module);
    const idx = mc.lookupFn("run").?;
    var vm = vm_mod.VM.init(allocator);
    defer vm.deinit();
    const result = try vm.call(&mc.program, idx, &.{});
    defer result.releaseVM(allocator);
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("i32", result.string);
}

test "M5d eq structural equality on arrays" {
    const allocator = std.testing.allocator;
    // eq 深比较：两独立数组结构相等 → true（VM Value.equals 是引用相等，eq 须深比较）。
    const src =
        \\fun run(): bool { eq([1i64, 2i64, 3i64], [1i64, 2i64, 3i64]) }
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c conditional throw: Ok path" {
    const allocator = std.testing.allocator;
    const src =
        \\fun checkedDiv(a: i64, b: i64): Throw<i64, Error> {
        \\    if (b == 0i64) { throw Error("div by zero") }
        \\    Ok(a / b)
        \\}
        \\fun run(): i64 { match checkedDiv(20i64, 4i64) { Ok(v) => v, Error(e) => -1i64 } }
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c propagate ? chains through Ok, short-circuits Error" {
    const allocator = std.testing.allocator;
    const src =
        \\fun checkedDiv(a: i64, b: i64): Throw<i64, Error> {
        \\    if (b == 0i64) { throw Error("div by zero") }
        \\    Ok(a / b)
        \\}
        \\fun chain(a: i64, b: i64, c: i64): Throw<i64, Error> {
        \\    val r1 = checkedDiv(a, b)?
        \\    val r2 = checkedDiv(r1, c)?
        \\    Ok(r2)
        \\}
        \\fun run(): i64 { match chain(100i64, 5i64, 2i64) { Ok(v) => v, Error(e) => -1i64 } }
    ;
    // 100/5=20, 20/2=10
    try std.testing.expectEqual(@as(u128, 10), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c propagate ? short-circuits on first Error" {
    const allocator = std.testing.allocator;
    const src =
        \\fun checkedDiv(a: i64, b: i64): Throw<i64, Error> {
        \\    if (b == 0i64) { throw Error("div by zero") }
        \\    Ok(a / b)
        \\}
        \\fun chain(a: i64, b: i64, c: i64): Throw<i64, Error> {
        \\    val r1 = checkedDiv(a, b)?
        \\    val r2 = checkedDiv(r1, c)?
        \\    Ok(r2)
        \\}
        \\fun run(): i64 { match chain(100i64, 0i64, 2i64) { Ok(v) => v, Error(e) => -1i64 } }
    ;
    const r = try compileAndCall(allocator, src, "run", &.{});
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(@as(u64, @truncate(r)))));
}

test "M3c match Error binds message via field access" {
    const allocator = std.testing.allocator;
    const src =
        \\fun mk(): Throw<i64, Error> { throw Error("not found") }
        \\fun run(): str { match mk() { Ok(v) => "ok", Error(e) => e.message } }
    ;
    const s = try compileAndCallStr(allocator, src, "run");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("not found", s);
}

test "M3c Ok/Error churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun checkedDiv(a: i64, b: i64): Throw<i64, Error> {
        \\    if (b == 0i64) { throw Error("div by zero") }
        \\    Ok(a / b)
        \\}
        \\fun run(): i64 {
        \\    var i: i64 = 1i64
        \\    var sum: i64 = 0i64
        \\    while i < 1000i64 {
        \\        val r = match checkedDiv(1000i64, i) { Ok(v) => v, Error(e) => 0i64 }
        \\        sum = sum + r
        \\        i = i + 1i64
        \\    }
        \\    sum
        \\}
    ;
    var expected: i128 = 0;
    var i: i128 = 1;
    while (i < 1000) : (i += 1) expected += @divTrunc(1000, i);
    try std.testing.expectEqual(@as(u128, @intCast(expected)), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M3c-defer：block 作用域 / LIFO / 见当前值 / return / throw / 循环 ──

test "M3c-defer runs on normal block exit" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var result: i64 = 0i64
        \\    {
        \\        defer result = result + 10i64
        \\        result = 5i64
        \\    }
        \\    result
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 15), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer sees current value at exit (not snapshot)" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var x: i64 = 1i64
        \\    var seen: i64 = 0i64
        \\    {
        \\        defer seen = x
        \\        x = 2i64
        \\    }
        \\    seen
        \\}
    ;
    // defer 读 x 在退出时 = 2（非登记时的 1）
    try std.testing.expectEqual(@as(u128, 2), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer LIFO order" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var r: i64 = 0i64
        \\    {
        \\        defer r = r * 2i64
        \\        defer r = r + 3i64
        \\    }
        \\    r
        \\}
    ;
    // LIFO：先 r=0+3=3，再 r=3*2=6
    try std.testing.expectEqual(@as(u128, 6), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer runs before function return" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var flag: i64 = 0i64
        \\    defer flag = 100i64
        \\    return flag
        \\}
    ;
    // return 求值 flag(0) 后跑 defer（flag=100），返回的是已求值的 0
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer function-body scope normal exit" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var r: i64 = 1i64
        \\    defer r = r + 41i64
        \\    r = 0i64
        \\    r
        \\}
    ;
    // trailing expr r 求值=0，defer 跑（r=41），但返回值是已求值的 0
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer runs on throw path" {
    const allocator = std.testing.allocator;
    const src =
        \\fun mk(flag_holder: i64): Throw<i64, Error> {
        \\    var local: i64 = flag_holder
        \\    defer local = 99i64
        \\    throw Error("x")
        \\}
        \\fun run(): i64 { match mk(0i64) { Ok(v) => v, Error(e) => 7i64 } }
    ;
    // defer 在 throw 前执行（局部副作用不可观测于外，但验证编译/运行不崩、throw 仍生效）
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer in loop body runs each iteration" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 5i64 {
        \\        defer total = total + 1i64
        \\        i = i + 1i64
        \\    }
        \\    total
        \\}
    ;
    // 每轮 block 退出跑一次 defer → total=5
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3c-defer churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    var i: i64 = 0i64
        \\    while i < 1000i64 {
        \\        {
        \\            defer sum = sum + 2i64
        \\            defer sum = sum + 1i64
        \\        }
        \\        i = i + 1i64
        \\    }
        \\    sum
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 3000), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M3d：方法调用 + safe access + for 循环 ──

test "M3d array len method" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a = [10i64, 20i64, 30i64]; a.len() }
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d string len counts codepoints" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val s = "héllo"; s.len() }
    ;
    // h é l l o = 5 码点
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d array push returns new array" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var a = [1i64, 2i64]
        \\    a = a.push(3i64)
        \\    a.len()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d array contains" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): bool { val a = [1i64, 2i64, 3i64]; a.contains(2i64) }
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d array is_empty false" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): bool { val a = [1i64]; a.is_empty() }
    ;
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d chained methods drop_last then len" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a = [1i64, 2i64, 3i64, 4i64]; a.drop_last().len() }
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d unknown method panics" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val a = [1i64]; a.bogus() }
    ;
    try std.testing.expectError(error.TypeMismatch, compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for-in-array sums elements" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    for x in [10i64, 20i64, 30i64] { sum = sum + x }
        \\    sum
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 60), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for-in-range exclusive" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    for i in 0i64..5i64 { sum = sum + i }
        \\    sum
        \\}
    ;
    // 0+1+2+3+4 = 10
    try std.testing.expectEqual(@as(u128, 10), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for-in-range inclusive" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    for i in 1i64..=5i64 { sum = sum + i }
        \\    sum
        \\}
    ;
    // 1+2+3+4+5 = 15
    try std.testing.expectEqual(@as(u128, 15), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for with break" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    for i in 0i64..100i64 {
        \\        if (i == 5i64) { break }
        \\        sum = sum + i
        \\    }
        \\    sum
        \\}
    ;
    // 0+1+2+3+4 = 10
    try std.testing.expectEqual(@as(u128, 10), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for with continue" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var sum: i64 = 0i64
        \\    for i in 0i64..6i64 {
        \\        if (i % 2i64 == 0i64) { continue }
        \\        sum = sum + i
        \\    }
        \\    sum
        \\}
    ;
    // 1+3+5 = 9
    try std.testing.expectEqual(@as(u128, 9), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d nested for loops" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var count: i64 = 0i64
        \\    for i in 0i64..3i64 {
        \\        for j in 0i64..3i64 { count = count + 1i64 }
        \\    }
        \\    count
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 9), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d safe access on non-null record" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 { val p = (x: 7i64, y: 2i64); p?.x }
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d safe access on null short-circuits" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val p: i64? = null
        \\    val r = p?.x ?? 99i64
        \\    r
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 99), try compileAndCall(allocator, src, "run", &.{}));
}

test "M3d for-in-array churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var n: i64 = 0i64
        \\    while n < 500i64 {
        \\        for x in [1i64, 2i64, 3i64] { total = total + x }
        \\        n = n + 1i64
        \\    }
        \\    total
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 3000), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4a：atomic（构造 + 透明读取 + 复合赋值 + cas/swap）──

test "M4a atomic read transparency loads scalar" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val c = atomic 42i64
        \\    c
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic compound add in place" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var c = atomic 0i64
        \\    c += 5i64
        \\    c += 3i64
        \\    c
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 8), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic compound sub" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var c = atomic 100i64
        \\    c -= 30i64
        \\    c
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 70), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic cas success" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): bool {
        \\    val c = atomic 10i64
        \\    c.cas(10i64, 20i64)
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic cas failure" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): bool {
        \\    val c = atomic 10i64
        \\    c.cas(99i64, 20i64)
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 0), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic swap returns old value" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val c = atomic 7i64
        \\    c.swap(99i64)
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic cas then read new value" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var c = atomic 10i64
        \\    val ok = c.cas(10i64, 55i64)
        \\    c
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 55), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4a atomic in loop churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var c = atomic 0i64
        \\    var n: i64 = 0i64
        \\    while n < 1000i64 {
        \\        c += 1i64
        \\        n = n + 1i64
        \\    }
        \\    c
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 1000), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4b：channel（构造 + send/recv/close + sender/receiver 方向类型）──

test "M4b buffered channel send then recv" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    ch.send(42i64)
        \\    ch.recv()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b channel FIFO order" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    ch.send(1i64)
        \\    ch.send(2i64)
        \\    ch.send(3i64)
        \\    val a = ch.recv()
        \\    val b = ch.recv()
        \\    val c = ch.recv()
        \\    a * 100i64 + b * 10i64 + c
        \\}
    ;
    // 1,2,3 → 123
    try std.testing.expectEqual(@as(u128, 123), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b recv on closed empty channel returns null" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(2)
        \\    ch.sender.close()
        \\    val v = ch.recv() ?? -1i64
        \\    v
        \\}
    ;
    try std.testing.expectEqual(@as(u128, @bitCast(@as(i128, -1))), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b sender.send and receiver.recv" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    val tx = ch.sender
        \\    val rx = ch.receiver
        \\    tx.send(7i64)
        \\    rx.recv()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b drain buffered channel after close" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    ch.send(10i64)
        \\    ch.send(20i64)
        \\    ch.sender.close()
        \\    val a = ch.recv()
        \\    val b = ch.recv()
        \\    a + b
        \\}
    ;
    // 关闭后仍可排空缓冲区：10+20 = 30
    try std.testing.expectEqual(@as(u128, 30), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b string channel under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    ch.send("hello")
        \\    val s = ch.recv()
        \\    s.len()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 5), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b channel churn does not leak" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var n: i64 = 0i64
        \\    while n < 500i64 {
        \\        val ch = channel(2)
        \\        ch.send(n)
        \\        total = total + ch.recv()
        \\        n = n + 1i64
        \\    }
        \\    total
        \\}
    ;
    // 0+1+...+499 = 124750
    try std.testing.expectEqual(@as(u128, 124750), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4b dropped channel with unconsumed buffer does not leak" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(4)
        \\    ch.send(1i64)
        \\    ch.send(2i64)
        \\    99i64
        \\}
    ;
    // ch 离开作用域时缓冲区仍有 2 个未消费元素 —— releaseVM → deinit 须清理无泄漏。
    try std.testing.expectEqual(@as(u128, 99), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4c：spawn（协程隔离 + await + 捕获快照 + atomic 共享）──

test "M4c spawn pure compute and await" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val s = spawn { 10i64 * 10i64 }
        \\    s.await()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c multiple independent spawns" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val s1 = spawn { 10i64 * 10i64 }
        \\    val s2 = spawn { 20i64 + 5i64 }
        \\    val s3 = spawn { 100i64 - 1i64 }
        \\    s1.await() + s2.await() + s3.await()
        \\}
    ;
    // 100 + 25 + 99 = 224
    try std.testing.expectEqual(@as(u128, 224), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn captures local by deep-copy snapshot" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val base: i64 = 7i64
        \\    val s = spawn { base * 6i64 }
        \\    s.await()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn shares atomic across threads" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val counter = atomic 0i64
        \\    val s1 = spawn { counter.swap(counter.swap(0i64)) }
        \\    s1.await()
        \\    counter += 100i64
        \\    val s2 = spawn { counter.cas(100i64, 200i64) }
        \\    s2.await()
        \\    counter
        \\}
    ;
    // s1 no-op churn; counter += 100 → 100; s2 cas(100→200); 读 200
    try std.testing.expectEqual(@as(u128, 200), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn atomic concurrent increment" {
    const allocator = std.testing.allocator;
    const src =
        \\fun worker(c: i64): i64 {
        \\    var n: i64 = 0i64
        \\    n
        \\}
        \\fun run(): i64 {
        \\    val counter = atomic 0i64
        \\    val s1 = spawn {
        \\        var i: i64 = 0i64
        \\        while i < 1000i64 { counter += 1i64; i = i + 1i64 }
        \\        0i64
        \\    }
        \\    val s2 = spawn {
        \\        var j: i64 = 0i64
        \\        while j < 1000i64 { counter += 1i64; j = j + 1i64 }
        \\        0i64
        \\    }
        \\    s1.await()
        \\    s2.await()
        \\    counter
        \\}
    ;
    // 两协程各 +1000，原子操作无丢失 → 2000
    try std.testing.expectEqual(@as(u128, 2000), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn string result deep-copied across threads" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val s = spawn { "hello world" }
        \\    val r = s.await()
        \\    r.len()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 11), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var n: i64 = 0i64
        \\    while n < 50i64 {
        \\        val s = spawn { 3i64 }
        \\        total = total + s.await()
        \\        n = n + 1i64
        \\    }
        \\    total
        \\}
    ;
    // 50 * 3 = 150
    try std.testing.expectEqual(@as(u128, 150), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4c spawn through channel handoff" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(1)
        \\    val tx = ch.sender
        \\    val producer = spawn {
        \\        tx.send(77i64)
        \\        0i64
        \\    }
        \\    val v = ch.recv()
        \\    producer.await()
        \\    v
        \\}
    ;
    // 真并行：producer 线程 send，主线程 recv → 77
    try std.testing.expectEqual(@as(u128, 77), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4d：lazy（透明 force + 缓存）──

test "M4d lazy forces on read" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val x = lazy { 6i64 * 7i64 }
        \\    x
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d lazy caches — thunk runs once" {
    const allocator = std.testing.allocator;
    // counter 捕获进 thunk；每次 force +1。读两次 x，若缓存则 counter 只 +1。
    const src =
        \\fun run(): i64 {
        \\    val counter = atomic 0i64
        \\    val x = lazy { counter += 1i64; 5i64 }
        \\    val a = x
        \\    val b = x
        \\    counter
        \\}
    ;
    // 缓存生效：thunk 仅首次 force 跑一次 → counter == 1
    try std.testing.expectEqual(@as(u128, 1), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d lazy value used in arithmetic" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val a = lazy { 10i64 + 5i64 }
        \\    val b = lazy { 100i64 }
        \\    a + b + a
        \\}
    ;
    // a=15 (cached), b=100 → 15 + 100 + 15 = 130
    try std.testing.expectEqual(@as(u128, 130), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d lazy captures local by reference snapshot" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val base: i64 = 9i64
        \\    val x = lazy { base * base }
        \\    x
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 81), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d lazy never forced — no leak" {
    const allocator = std.testing.allocator;
    // x 从不读取；leak-checked allocator 须无泄漏（thunk 闭包 + 箱体 release 干净）。
    const src =
        \\fun run(): i64 {
        \\    val x = lazy { 999i64 }
        \\    7i64
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d lazy churn under leak-checked allocator" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var n: i64 = 0i64
        \\    while n < 50i64 {
        \\        val x = lazy { 2i64 }
        \\        total = total + x
        \\        n = n + 1i64
        \\    }
        \\    total
        \\}
    ;
    // 50 * 2 = 100
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4d：select 多路复用 ──

test "M4d select picks ready channel" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(2)
        \\    val tx = ch.sender
        \\    tx.send(42i64)
        \\    select {
        \\        ch.recv() => v => v
        \\    }
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d select dual channel — first ready wins" {
    const allocator = std.testing.allocator;
    // 仅 ch2 有数据 → 命中第二 arm。
    const src =
        \\fun run(): i64 {
        \\    val ch1 = channel(1)
        \\    val ch2 = channel(1)
        \\    val tx2 = ch2.sender
        \\    tx2.send(99i64)
        \\    select {
        \\        ch1.recv() => a => a + 1i64
        \\        ch2.recv() => b => b + 2i64
        \\    }
        \\}
    ;
    // ch1 空，ch2=99 就绪 → 99 + 2 = 101
    try std.testing.expectEqual(@as(u128, 101), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d select timeout when none ready" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(1)
        \\    select {
        \\        ch.recv() => v => v
        \\        timeout(100i64) => 7i64
        \\    }
        \\}
    ;
    // ch 空，无就绪 → timeout body → 7
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d select blocks on spawn producer" {
    const allocator = std.testing.allocator;
    // 无 timeout，主线程阻塞 recv；spawn 的 producer 送值解除阻塞。
    const src =
        \\fun run(): i64 {
        \\    val ch = channel(1)
        \\    val tx = ch.sender
        \\    val producer = spawn {
        \\        tx.send(55i64)
        \\        0i64
        \\    }
        \\    val r = select {
        \\        ch.recv() => v => v * 2i64
        \\    }
        \\    producer.await()
        \\    r
        \\}
    ;
    // producer 送 55，select 阻塞 recv → 55 * 2 = 110
    try std.testing.expectEqual(@as(u128, 110), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d select first ready among two both-ready" {
    const allocator = std.testing.allocator;
    // 两通道都就绪 → 取第一 arm（确定性，镜像 eval 顺序 poll）。
    const src =
        \\fun run(): i64 {
        \\    val ch1 = channel(1)
        \\    val ch2 = channel(1)
        \\    val tx1 = ch1.sender
        \\    val tx2 = ch2.sender
        \\    tx1.send(10i64)
        \\    tx2.send(20i64)
        \\    val first = select {
        \\        ch1.recv() => a => a
        \\        ch2.recv() => b => b
        \\    }
        \\    val second = ch2.recv()
        \\    first + second
        \\}
    ;
    // ch1 先就绪 → first=10；ch2 仍有 20 → second=20 → 30
    try std.testing.expectEqual(@as(u128, 30), try compileAndCall(allocator, src, "run", &.{}));
}

// ── M4d：inline trait 值（方法分派）──

test "M4d inline trait method dispatch" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val obj = trait {
        \\        fun add(a: i64, b: i64): i64 { a + b }
        \\    }
        \\    obj.add(3i64, 4i64)
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d inline trait multiple methods" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val m = trait {
        \\        fun double(x: i64): i64 { x * 2i64 }
        \\        fun triple(x: i64): i64 { x * 3i64 }
        \\    }
        \\    m.double(5i64) + m.triple(5i64)
        \\}
    ;
    // 10 + 15 = 25
    try std.testing.expectEqual(@as(u128, 25), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d inline trait captures enclosing local" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val base: i64 = 100i64
        \\    val obj = trait {
        \\        fun bumped(x: i64): i64 { x + base }
        \\    }
        \\    obj.bumped(7i64)
        \\}
    ;
    // 7 + 100 = 107
    try std.testing.expectEqual(@as(u128, 107), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d inline trait churn — no leak" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var total: i64 = 0i64
        \\    var n: i64 = 0i64
        \\    while n < 30i64 {
        \\        val o = trait { fun id(x: i64): i64 { x } }
        \\        total = total + o.id(2i64)
        \\        n = n + 1i64
        \\    }
        \\    total
        \\}
    ;
    // 30 * 2 = 60
    try std.testing.expectEqual(@as(u128, 60), try compileAndCall(allocator, src, "run", &.{}));
}

test "M4d inline trait repeated calls with capture" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    val k: i64 = 5i64
        \\    val o = trait {
        \\        fun f(x: i64): i64 { x * x + k }
        \\    }
        \\    o.f(3i64) + o.f(4i64)
        \\}
    ;
    // (9+5)+(16+5) = 35
    try std.testing.expectEqual(@as(u128, 35), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5e error_newtype: FileError(msg) -> throw_val.err with prefixed message" {
    const allocator = std.testing.allocator;
    const src =
        \\type FileError = Error("file error")
        \\fun run() {
        \\    FileError("config.json missing")
        \\}
    ;
    var program: Program = undefined;
    const result = try compileAndValue(allocator, &program, src, "run");
    defer program.deinit();
    defer result.releaseVM(allocator);
    try std.testing.expect(result == .throw_val);
    try std.testing.expect(result.throw_val.* == .err);
    const e = result.throw_val.err;
    try std.testing.expectEqualStrings("FileError", e.type_name);
    try std.testing.expectEqualStrings("file error: config.json missing", e.message);
    try std.testing.expect(e.is_error_subtype);
}

test "M5e error_newtype: .message field access" {
    const allocator = std.testing.allocator;
    const src =
        \\type NetworkError = Error("network error")
        \\fun run(): str {
        \\    val ne = NetworkError("timeout")
        \\    ne.message
        \\}
    ;
    var program: Program = undefined;
    const result = try compileAndValue(allocator, &program, src, "run");
    defer program.deinit();
    defer result.releaseVM(allocator);
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("network error: timeout", result.string);
}

test "M5f index assign: arr[i] = v then read" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var arr = [10i64, 20i64, 30i64]
        \\    arr[1] = 99i64
        \\    arr[0] + arr[1] + arr[2]
        \\}
    ;
    // 10 + 99 + 30 = 139
    try std.testing.expectEqual(@as(u128, 139), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5f index assign COW: aliased array unaffected" {
    const allocator = std.testing.allocator;
    const src =
        \\fun run(): i64 {
        \\    var arr = [1i64, 2i64, 3i64]
        \\    var c = arr
        \\    c[0] = 99i64
        \\    arr[0] + c[0]
        \\}
    ;
    // 别名独立：arr[0] 仍 1，c[0] 改 99 → 1 + 99 = 100
    try std.testing.expectEqual(@as(u128, 100), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5g global val read from function" {
    const allocator = std.testing.allocator;
    const src =
        \\val base: i64 = 100i64
        \\fun run(): i64 { base + 5i64 }
    ;
    try std.testing.expectEqual(@as(u128, 105), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5g global var mutated across calls" {
    const allocator = std.testing.allocator;
    const src =
        \\var counter: i64 = 0i64
        \\fun bump() { counter = counter + 1i64 }
        \\fun run(): i64 {
        \\    bump()
        \\    bump()
        \\    bump()
        \\    counter
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 3), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5g global var compound assignment" {
    const allocator = std.testing.allocator;
    const src =
        \\var total: i64 = 10i64
        \\fun run(): i64 {
        \\    total += 5i64
        \\    total *= 2i64
        \\    total
        \\}
    ;
    // (10+5)*2 = 30
    try std.testing.expectEqual(@as(u128, 30), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5i impl method dispatch on ADT receiver" {
    const allocator = std.testing.allocator;
    const src =
        \\type Box = Box(n: i64)
        \\trait Show { fun get(self): i64 }
        \\impl Show<Box> {
        \\    fun get(self): i64 { self.n * 2i64 }
        \\}
        \\fun run(): i64 {
        \\    val b = Box(21i64)
        \\    b.get()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5i trait default method falls through when impl omits it" {
    const allocator = std.testing.allocator;
    const src =
        \\type Box = Box(n: i64)
        \\trait Doubler {
        \\    fun base(self): i64
        \\    fun doubled(self): i64 { self.base() + self.base() }
        \\}
        \\impl Doubler<Box> {
        \\    fun base(self): i64 { self.n }
        \\}
        \\fun run(): i64 {
        \\    val b = Box(15i64)
        \\    b.doubled()
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 30), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5i trait method as free function dispatches on first arg" {
    const allocator = std.testing.allocator;
    const src =
        \\type Wrap = Wrap(v: i64)
        \\trait Pick { fun pick(a, b): i64 }
        \\impl Pick<Wrap> {
        \\    fun pick(a, b): i64 { a.v + b }
        \\}
        \\fun run(): i64 {
        \\    pick(Wrap(40i64), 2i64)
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 42), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5j cross-module use: dep impl + fn merged into Program" {
    const allocator = std.testing.allocator;
    const dep =
        \\trait Show { fun show(self): i64 }
        \\impl Show<i64> {
        \\    fun show(self): i64 { self * 10i64 }
        \\}
        \\fun helper(x: i64): i64 { x + 1i64 }
    ;
    const entry =
        \\use Dep
        \\fun run(): i64 {
        \\    val a = (5i64).show()
        \\    a + helper(4i64)
        \\}
    ;
    // 5*10 + (4+1) = 55
    try std.testing.expectEqual(@as(u128, 55), try compileAndCallWithDep(allocator, dep, entry, "run"));
}

test "M5k nullary trait method called as free function" {
    const allocator = std.testing.allocator;
    const src =
        \\trait Numeric { fun zero() }
        \\impl Numeric<i64> {
        \\    fun zero(): i64 { 0i64 }
        \\}
        \\fun run(): i64 { zero() + 7i64 }
    ;
    try std.testing.expectEqual(@as(u128, 7), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5k constructor as first-class value" {
    const allocator = std.testing.allocator;
    const src =
        \\type Box = Box(n: i64)
        \\fun run(): i64 {
        \\    val mk = Box
        \\    val b = mk(33i64)
        \\    b.n
        \\}
    ;
    try std.testing.expectEqual(@as(u128, 33), try compileAndCall(allocator, src, "run", &.{}));
}

test "M5k conflicting impls (same type+method) -> Unsupported fallback" {
    const allocator = std.testing.allocator;
    // 同一 (Box, dup) 两个 impl → trait 冲突消解，VM 回退（compileModule 报 Unsupported）。
    const src =
        \\type Box = Box(n: i64)
        \\trait A { fun dup(self): i64 }
        \\trait B { fun dup(self): i64 }
        \\impl A<Box> { fun dup(self): i64 { self.n } }
        \\impl B<Box> { fun dup(self): i64 { self.n * 2i64 } }
        \\fun run(): i64 { 0i64 }
    ;
    try std.testing.expectError(error.Unsupported, compileAndCall(allocator, src, "run", &.{}));
}
