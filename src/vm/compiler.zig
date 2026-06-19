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

    pub fn init(allocator: std.mem.Allocator) ModuleCompiler {
        return .{ .program = Program.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *ModuleCompiler) void {
        self.fn_table.deinit(self.allocator);
        self.ctor_table.deinit(self.allocator);
        self.newtype_table.deinit(self.allocator);
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

    /// 查顶层函数的 (idx, arity)，供尾调用合格性判定（argc==arity 才发 OP_TAIL_CALL）。
    pub fn lookupFnEntry(self: *ModuleCompiler, name: []const u8) ?FnEntry {
        for (self.fn_table.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// 编译整个模块。返回的 Program（self.program）持有所有函数；调用方取走。
    pub fn compileModule(self: *ModuleCompiler, module: *const ast.Module) CompileError!void {
        // 第一遍：给每个 fun_decl 预占一个 func_idx + 在 program.functions 预留同索引的占位槽。
        // 关键：lambda 在编译期经 addFunction 追加到 program.functions 末尾，会插在顶层函数之间，
        // 故顶层函数必须**预占** program 槽位，使 fn_table.idx == program.functions 索引一致
        // （否则 entry/OP_CALL 的 func_idx 指向错误的函数，如把 lambda 当成 run 执行）。
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    const idx: u16 = @intCast(self.fn_table.items.len);
                    try self.fn_table.append(self.allocator, .{ .name = fd.name, .idx = idx, .arity = @intCast(fd.params.len) });
                    // 预留占位（空 chunk）；第二遍用真正编译结果覆盖。
                    _ = try self.program.addFunction(.{ .chunk = Chunk.init(self.allocator), .arity = 0, .slot_count = 0, .name = fd.name });
                },
                // M2a：登记 ADT 构造器（type T = Ctor(field: T, ...) | ...）。
                .type_decl => |td| {
                    switch (td.def) {
                        .adt => |a| {
                            for (a.constructors) |con| {
                                // 收集字段名（位置字段 name=null）。借用 AST 字节。
                                var fnames = try self.allocator.alloc(?[]const u8, con.fields.len);
                                defer self.allocator.free(fnames);
                                for (con.fields, 0..) |f, i| fnames[i] = f.name;
                                const cidx = try self.program.addAdtCtor(td.name, con.name, fnames);
                                try self.ctor_table.append(self.allocator, .{ .name = con.name, .idx = cidx, .arity = @intCast(con.fields.len) });
                            }
                        },
                        .newtype => |nt| {
                            // type Handle = Handle(i32)：构造器名 == type_name，arity 1。
                            const ntidx = try self.program.addNewtypeCtor(td.name);
                            try self.newtype_table.append(self.allocator, .{ .name = nt.name, .idx = ntidx, .arity = 1 });
                        },
                        else => {}, // record/alias/gadt 等留后续片
                    }
                },
                else => {}, // trait/impl/use 等 M2a 不处理（遇到引用时 Unsupported）
            }
        }
        // 第二遍：逐个编译函数体，覆盖预留槽（idx 对齐）。lambda 追加到末尾（idx ≥ 顶层函数数）。
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| try self.compileFunction(fd),
                else => {},
            }
        }
        if (self.lookupFn("main")) |m| self.program.entry = m;
    }

    fn compileFunction(self: *ModuleCompiler, fd: @TypeOf(@as(ast.Decl, undefined).fun_decl)) CompileError!void {
        var fc = FnCompiler.init(self.allocator, self);
        defer fc.deinit();
        // 参数占 slot 0..arity-1。
        for (fd.params) |p| _ = try fc.declareLocal(p.name, p.is_var);
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

    fn init(allocator: std.mem.Allocator, module: *ModuleCompiler) FnCompiler {
        return .{ .chunk = Chunk.init(allocator), .allocator = allocator, .module = module };
    }

    fn deinit(self: *FnCompiler) void {
        self.locals.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
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
                    if (ce.arity != 0) return error.Unsupported; // 有参构造器须带实参调用
                    try self.chunk.writeOp(.op_make_adt, loc);
                    try self.chunk.writeU16(ce.idx);
                    try self.chunk.writeByte(0);
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

    fn emitConst(self: *FnCompiler, k: u16, loc: ast.SourceLocation) CompileError!void {
        try self.chunk.writeOp(.op_const, loc);
        try self.chunk.writeU16(k);
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
                for (blk.statements) |stmt| try self.emitStmt(stmt);
                if (blk.trailing_expr) |te| {
                    try self.emitTail(te);
                } else {
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

    fn emitCall(self: *FnCompiler, c: @TypeOf(@as(Expr, undefined).call), loc: ast.SourceLocation) CompileError!void {
        if (c.arguments.len > 255) return error.Unsupported;
        const argc: u8 = @intCast(c.arguments.len);
        // 快路径：直接具名顶层函数（且非被 local 遮蔽）。
        if (c.callee.* == .identifier) {
            const name = c.callee.identifier.name;
            if (self.resolveLocal(name) == null) {
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
                // 原生内建（println/print 等）：bench 驱动端到端跑完整 main。
                if (opcode.Native.fromName(name)) |nat| {
                    for (c.arguments) |arg| try self.emitExpr(arg);
                    try self.chunk.writeOp(.op_call_native, loc);
                    try self.chunk.writeByte(@intFromEnum(nat));
                    try self.chunk.writeByte(argc);
                    return;
                }
                return error.Unsupported; // 未知裸名
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

    fn emitBlock(self: *FnCompiler, blk: @TypeOf(@as(Expr, undefined).block), loc: ast.SourceLocation) CompileError!void {
        const saved = self.locals.items.len;
        for (blk.statements) |stmt| try self.emitStmt(stmt);
        if (blk.trailing_expr) |te| {
            try self.emitExpr(te);
        } else {
            try self.chunk.writeOp(.op_unit, loc);
        }
        self.locals.shrinkRetainingCapacity(saved);
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
                if (self.module.lookupNewtype(ctor.name)) |_| {
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
                try self.emitExpr(d.value);
                const slot = try self.declareLocal(d.name, false);
                try self.chunk.writeOp(.op_set_local, d.location);
                try self.chunk.writeU16(slot);
            },
            .var_decl => |d| {
                try self.emitExpr(d.value);
                const slot = try self.declareLocal(d.name, true);
                try self.chunk.writeOp(.op_set_local, d.location);
                try self.chunk.writeU16(slot);
            },
            .expression => |e| {
                try self.emitExpr(e.expr);
                try self.chunk.writeOp(.op_pop, e.location);
            },
            .assignment => |a| {
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
                } else return error.Unsupported;
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    try self.emitTail(v); // emitTail 自带 OP_RETURN / OP_TAIL_CALL
                } else {
                    try self.chunk.writeOp(.op_unit, r.location);
                    try self.chunk.writeOp(.op_return, r.location);
                }
            },
            .while_stmt => |w| try self.emitWhile(w),
            else => return error.Unsupported,
        }
    }

    fn emitWhile(self: *FnCompiler, w: @TypeOf(@as(Stmt, undefined).while_stmt)) CompileError!void {
        // loop_start: cond; jump_if_false->end; pop cond(true); body; pop body; jump loop_start; end: pop cond(false)
        const loop_start = self.chunk.here();
        try self.emitExpr(w.condition);
        const exit_jump = try self.chunk.emitJump(.op_jump_if_false, w.location);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(true)
        try self.emitExpr(w.body);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 body 值（while 体值丢弃）
        try self.emitLoopBack(loop_start, w.location);
        self.chunk.patchJump(exit_jump);
        try self.chunk.writeOp(.op_pop, w.location); // 弹 cond(false)
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
    defer result.release(allocator);
    return result.integer.value;
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

