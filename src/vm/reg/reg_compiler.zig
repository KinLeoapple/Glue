//! 寄存器式编译器：AST → RegChunk。
//! 与栈式 compiler.zig 对应，但 emitExpr 返回目标寄存器号而非压栈。
//! 每个表达式求值结果写入一个 VReg，由寄存器分配器映射到 PReg。
//! 简化方案：先假设 VReg < 256，直接用 VReg 低字节作 PReg（后续分配器优化）。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const reg_opcode = @import("reg_opcode.zig");
const reg_chunk = @import("reg_chunk.zig");
/// 再导出 reg_chunk，使外部模块（main.zig）可访问 RegProgram 等类型
pub const reg_chunk_mod = reg_chunk;
const reg_alloc = @import("reg_alloc.zig");
const compiler = @import("vm");

/// 再导出 reg_vm，使本模块作为 root_source_file 时 reg_vm.zig 可达
pub const reg_vm = @import("reg_vm.zig");

pub const CompileError = error{
    Unsupported,
    OutOfMemory,
    TooManyLocals,
    TooManyConstants,
    InvalidJump,
} || std.mem.Allocator.Error;

/// 局部变量信息
const Local = struct {
    name: []const u8,
    vreg: reg_alloc.VReg, // 虚拟寄存器号
    is_var: bool, // var（可变）vs val（不可变）
    boxed: bool, // 是否持 boxed 值（用于 release_mask）
    def_inst: u32, // 该 local 的活跃区间起点（指令索引）
    last_use: u32, // 最后使用点（指令索引）
    builtin_type: ?[]const u8 = null, // 声明类型名（用于 exprBuiltinType 推断）
};

const UpvalueInfo = struct {
    name: []const u8,
    is_local: bool,
    index: u8,
};

const LoopCtx = struct {
    continue_target: usize, // continue 跳回的指令索引
    breaks: std.ArrayListUnmanaged(usize), // break 跳转指令索引列表
    defer_depth: u32,
};

/// 函数级编译器
pub const RegFnCompiler = struct {
    chunk: reg_chunk.RegChunk,
    allocator: std.mem.Allocator,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    /// VReg 计数器（每个 val/var/param/临时分配唯一 VReg）
    next_vreg: reg_alloc.VReg = 0,
    /// 分配器
    alloc: reg_alloc.RegAllocator,
    /// 最终分配结果（color 后填充）
    allocation: ?reg_alloc.Allocation = null,
    /// upvalue 描述符
    upvalues: std.ArrayListUnmanaged(UpvalueInfo) = .empty,
    /// 外层函数引用（upvalue 解析）
    enclosing: ?*RegFnCompiler = null,
    /// 循环上下文栈
    loops: std.ArrayListUnmanaged(LoopCtx) = .empty,
    /// 函数名（调试用）
    name: []const u8 = "",
    /// arity（参数数）
    arity: u8 = 0,
    /// 所属模块编译器（用于函数名查找；null = 独立函数编译）
    module: ?*RegModuleCompiler = null,

    pub fn init(allocator: std.mem.Allocator) RegFnCompiler {
        return .{
            .chunk = reg_chunk.RegChunk.init(allocator),
            .allocator = allocator,
            .alloc = reg_alloc.RegAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *RegFnCompiler) void {
        self.chunk.deinit();
        self.locals.deinit(self.allocator);
        self.alloc.deinit();
        if (self.allocation) |*a| a.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        for (self.loops.items) |*lc| lc.breaks.deinit(self.allocator);
        self.loops.deinit(self.allocator);
    }

    /// 分配一个新的 VReg
    pub fn newVReg(self: *RegFnCompiler) reg_alloc.VReg {
        const v = self.next_vreg;
        self.next_vreg += 1;
        return v;
    }

    /// 分配一个临时 VReg（表达式求值用）
    pub fn newTemp(self: *RegFnCompiler) reg_alloc.VReg {
        return self.newVReg();
    }

    /// 声明局部变量
    pub fn declareLocal(self: *RegFnCompiler, name: []const u8, is_var: bool, boxed: bool, builtin_type: ?[]const u8) !reg_alloc.VReg {
        const vreg = self.newVReg();
        const here: u32 = @intCast(self.chunk.here());
        try self.locals.append(self.allocator, .{
            .name = name,
            .vreg = vreg,
            .is_var = is_var,
            .boxed = boxed,
            .def_inst = here,
            .last_use = here,
            .builtin_type = builtin_type,
        });
        return vreg;
    }

    /// 查找局部变量，返回 VReg
    pub fn resolveLocal(self: *RegFnCompiler, name: []const u8) ?reg_alloc.VReg {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                self.locals.items[i].last_use = @intCast(self.chunk.here());
                return self.locals.items[i].vreg;
            }
        }
        return null;
    }

    /// 查找局部变量的声明类型名（用于 exprBuiltinType 推断）
    pub fn resolveLocalType(self: *RegFnCompiler, name: []const u8) ?[]const u8 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                return self.locals.items[i].builtin_type;
            }
        }
        return null;
    }

    /// 查找 upvalue，返回索引（不存在返回 null）
    pub fn resolveUpvalue(self: *RegFnCompiler, name: []const u8) ?u8 {
        for (self.upvalues.items, 0..) |uv, i| {
            if (std.mem.eql(u8, uv.name, name)) return @intCast(i);
        }
        return null;
    }

    /// 添加 upvalue
    pub fn addUpvalue(self: *RegFnCompiler, name: []const u8, is_local: bool, index: u8) !u8 {
        const idx: u8 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{
            .name = name,
            .is_local = is_local,
            .index = index,
        });
        return idx;
    }
};

// ── 表达式发射 ──
// emitExpr 返回存放结果的 VReg。
// 调用方负责通过 getPReg 映射到物理寄存器后写入指令。

pub fn emitExpr(fc: *RegFnCompiler, expr: *const ast.Expr) CompileError!reg_alloc.VReg {
    const loc = ast.exprLocation(expr);
    return switch (expr.*) {
        .int_literal => |il| try emitIntLiteral(fc, il, loc),
        .float_literal => |fl| try emitFloatLiteral(fc, fl, loc),
        .bool_literal => |bl| try emitBoolLiteral(fc, bl.value, loc),
        .null_literal => try emitNullLiteral(fc, loc),
        .unit_literal => try emitUnitLiteral(fc, loc),
        .string_literal => |sl| try emitStringLiteral(fc, sl.value, loc),
        .char_literal => |cl| try emitCharLiteral(fc, cl.value, loc),
        .identifier => |id| try emitIdentifier(fc, id.name, loc),
        .binary => |bin| try emitBinary(fc, bin.op, bin.left, bin.right, loc),
        .unary => |un| try emitUnary(fc, un.op, un.operand, loc),
        .if_expr => |ie| try emitIf(fc, ie.condition, ie.then_branch, ie.else_branch, loc),
        .block => |blk| try emitBlock(fc, blk.statements, blk.trailing_expr, loc),
        .call => |c| try emitCall(fc, c.callee, c.arguments, loc),
        .lambda => try emitLambda(fc, loc),
        .field_access => |fa| try emitFieldAccess(fc, fa.object, fa.field, loc),
        .method_call => |mc| try emitMethodCall(fc, mc.object, mc.method, mc.arguments, loc),
        .match => |m| try emitMatch(fc, m.scrutinee, m.arms, loc),
        .array_literal => |al| try emitArrayLiteral(fc, al.elements, loc),
        .record_literal => |rl| try emitRecordLiteral(fc, rl.fields, loc),
        .index => |idx| try emitIndex(fc, idx.object, idx.index, loc),
        .atomic_expr => |ae| try emitAtomicExpr(fc, ae.value, loc),
        .lazy => |lz| try emitLazyExpr(fc, lz.expr, loc),
        .non_null_assert => |nna| try emitNonNullAssert(fc, nna.expr, loc),
        .propagate => |pr| try emitPropagate(fc, pr.expr, loc),
        .string_interpolation => |si| try emitStringInterp(fc, si.parts, loc),
        .type_cast => |tc| try emitTypeCast(fc, tc.expr, tc.target_type, loc),
        else => return error.Unsupported,
    };
}

// ── 类型推断 / 隐式定型（镜像栈式 compiler.zig 的 caller-side coerce）──

/// 从类型注解提取参数类型名（.named/.generic 的 base name；其他 null）。
fn paramTypeName(ta: ?*const ast.TypeNode) ?[]const u8 {
    const t = ta orelse return null;
    return switch (t.*) {
        .named => |n| n.name,
        .generic => |g| g.name,
        else => null,
    };
}

/// builtin 数值类型名判定（i*/u*/f*）。
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

/// 推断表达式的 builtin 类型名（int/float/bool/char literal + identifier 可推断；
/// binary/unary 算术递归左操作数；其他返回 null）。用于 caller-side coerce 判定。
fn exprBuiltinType(fc: *RegFnCompiler, expr: *const ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .int_literal => |il| blk: {
            if (il.suffix) |s| break :blk s;
            const parsed = compiler.parseIntSoftware(il.raw) orelse break :blk null;
            break :blk @tagName(parsed.type);
        },
        .float_literal => |fl| if (fl.suffix) |s| s else "f64",
        .bool_literal => "bool",
        .char_literal => "char",
        .identifier => |id| blk: {
            if (fc.resolveLocalType(id.name)) |bt| break :blk bt;
            break :blk null;
        },
        .binary => |bin| if (isArithmeticOp(bin.op)) exprBuiltinType(fc, bin.left) else null,
        .unary => |u| exprBuiltinType(fc, u.operand),
        else => null,
    };
}

fn isArithmeticOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

// ── 字面量发射 ──

fn emitIntLiteral(fc: *RegFnCompiler, il: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    const v = compiler.parseIntLiteral(fc.allocator, il) catch return error.Unsupported;
    if (v == null) return error.Unsupported;
    const k = try fc.chunk.addConstant(v.?);
    try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
    return dst;
}

fn emitFloatLiteral(fc: *RegFnCompiler, fl: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    const v = compiler.parseFloatLiteral(fc.allocator, fl) catch return error.Unsupported;
    if (v == null) return error.Unsupported;
    const k = try fc.chunk.addConstant(v.?);
    try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
    return dst;
}

fn emitBoolLiteral(fc: *RegFnCompiler, bl: bool, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    try fc.chunk.writeABC(if (bl) .load_true else .load_false, @intCast(dst & 0xFF), 0, 0, loc);
    return dst;
}

fn emitNullLiteral(fc: *RegFnCompiler, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
    return dst;
}

fn emitUnitLiteral(fc: *RegFnCompiler, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
    return dst;
}

fn emitStringLiteral(fc: *RegFnCompiler, raw: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    const k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, raw));
    try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
    return dst;
}

fn emitCharLiteral(fc: *RegFnCompiler, codepoint: u21, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    const ch = value.Char.fromCodePoint(codepoint) catch return error.Unsupported;
    const k = try fc.chunk.addConstant(value.Value.fromChar(ch));
    try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
    return dst;
}

// ── identifier 发射 ──

fn emitIdentifier(fc: *RegFnCompiler, name: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 1. 查 local
    if (fc.resolveLocal(name)) |vreg| {
        return vreg; // 直接返回 VReg（引用同一寄存器，无需 MOVE）
    }
    // 2. 查 upvalue
    if (fc.resolveUpvalue(name)) |uv_idx| {
        const dst = fc.newTemp();
        try fc.chunk.writeABC(.get_upvalue, @intCast(dst & 0xFF), uv_idx, 0, loc);
        return dst;
    }
    // 3. 查全局/函数/构造器 — 需要 ModuleCompiler 支持，此处返回 Unsupported
    return error.Unsupported;
}

// ── 二元运算发射 ──

fn emitBinary(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 短路运算需特殊处理
    switch (op) {
        .and_op, .or_op => return try emitShortCircuit(fc, op, left, right, loc),
        .elvis => return try emitElvis(fc, left, right, loc),
        .range, .range_inclusive => return try emitRange(fc, op, left, right, loc),
        .concat_list => return try emitConcatList(fc, left, right, loc),
        .concat => return try emitStringConcat(fc, left, right, loc),
        else => {},
    }

    // 算术/比较/位运算
    const left_vreg = try emitExpr(fc, left);
    const right_vreg = try emitExpr(fc, right);
    const dst = fc.newTemp();

    const reg_op: reg_opcode.Op = switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .eq => .eq,
        .not_eq => .neq,
        .lt => .lt,
        .gt => .gt,
        .lt_eq => .le,
        .gt_eq => .ge,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        else => unreachable,
    };

    try fc.chunk.writeABC(reg_op, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
    return dst;
}

fn emitShortCircuit(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const is_and = op == .and_op;
    const left_vreg = try emitExpr(fc, left);
    const dst = fc.newTemp();
    // MOVE dst, left
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), 0, loc);
    // JUMP_IF_FALSE/JUMP_IF_TRUE dst, skip
    const jump_op: reg_opcode.Op = if (is_and) .jump_if_false else .jump_if_true;
    const skip_idx = try fc.chunk.emitJump(jump_op, @intCast(dst & 0xFF), loc);
    // 右操作数求值
    const right_vreg = try emitExpr(fc, right);
    // MOVE dst, right（覆盖左值）
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(right_vreg & 0xFF), 0, loc);
    // skip 落点
    fc.chunk.patchJump(skip_idx, fc.chunk.here());
    return dst;
}

fn emitElvis(fc: *RegFnCompiler, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const left_vreg = try emitExpr(fc, left);
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), 0, loc);
    const skip_idx = try fc.chunk.emitJump(.jump_if_not_null, @intCast(dst & 0xFF), loc);
    const right_vreg = try emitExpr(fc, right);
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(right_vreg & 0xFF), 0, loc);
    fc.chunk.patchJump(skip_idx, fc.chunk.here());
    return dst;
}

fn emitRange(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const left_vreg = try emitExpr(fc, left);
    const right_vreg = try emitExpr(fc, right);
    const dst = fc.newTemp();
    // A 的 bit0 编码 inclusive 标志
    const a: u8 = @intCast((dst & 0xFF) | (if (op == .range_inclusive) @as(u32, 1) else 0));
    try fc.chunk.writeABC(.make_range, a, @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
    return dst;
}

fn emitConcatList(fc: *RegFnCompiler, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const left_vreg = try emitExpr(fc, left);
    const right_vreg = try emitExpr(fc, right);
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.concat_list, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
    return dst;
}

fn emitStringConcat(fc: *RegFnCompiler, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 字符串拼接复用 concat_list 指令（VM 中按类型分派）
    return try emitConcatList(fc, left, right, loc);
}

// ── 一元运算 ──

fn emitUnary(fc: *RegFnCompiler, op: ast.UnaryOp, operand: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const operand_vreg = try emitExpr(fc, operand);
    const dst = fc.newTemp();
    const reg_op: reg_opcode.Op = switch (op) {
        .neg => .neg,
        .not => .not_op,
    };
    try fc.chunk.writeABC(reg_op, @intCast(dst & 0xFF), @intCast(operand_vreg & 0xFF), 0, loc);
    return dst;
}

// ── if 表达式 ──

fn emitIf(fc: *RegFnCompiler, condition: *const ast.Expr, then_branch: *const ast.Expr, else_branch: ?*const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const cond_vreg = try emitExpr(fc, condition);
    const dst = fc.newTemp();
    // JUMP_IF_FALSE cond, else
    const else_jump = try fc.chunk.emitJump(.jump_if_false, @intCast(cond_vreg & 0xFF), loc);
    // then 分支
    const then_vreg = try emitExpr(fc, then_branch);
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(then_vreg & 0xFF), 0, loc);
    const end_jump = try fc.chunk.emitJump(.jump, 0, loc);
    // else 分支
    fc.chunk.patchJump(else_jump, fc.chunk.here());
    if (else_branch) |eb| {
        const else_vreg = try emitExpr(fc, eb);
        try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(else_vreg & 0xFF), 0, loc);
    } else {
        try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
    }
    fc.chunk.patchJump(end_jump, fc.chunk.here());
    return dst;
}

// ── block 表达式 ──

fn emitBlock(fc: *RegFnCompiler, statements: []*ast.Stmt, trailing_expr: ?*const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    for (statements) |stmt| {
        try emitStmt(fc, stmt);
    }
    if (trailing_expr) |te| {
        return try emitExpr(fc, te);
    }
    // 无 trailing expr → 返回 unit
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
    return dst;
}

// ── call 发射 ──

fn emitCall(fc: *RegFnCompiler, callee: *const ast.Expr, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 命名函数调用：通过 ModuleCompiler 查找 func_idx
    if (callee.* == .identifier) {
        const name = callee.identifier.name;
        const dst = fc.newTemp();
        // 内建函数（println/print 等）：先求值参数再 CALL_NATIVE
        if (compiler.opcode_mod.Native.fromName(name)) |nat| {
            for (arguments, 0..) |arg, i| {
                const arg_vreg = try emitExpr(fc, arg);
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
            }
            try fc.chunk.writeABC(.call_native, @intCast(dst & 0xFF), @intFromEnum(nat), @intCast(arguments.len & 0xFF), loc);
            return dst;
        }
        // 从 ModuleCompiler 查找函数索引
        const func_idx: u16 = if (fc.module) |m|
            (m.lookupFn(name) orelse return error.Unsupported)
        else
            return error.Unsupported;
        // caller-side coerce：参数类型注解为 builtin 数值类型且与实参推断类型不符时发射 .coerce
        const param_types: []const ?[]const u8 = if (fc.module) |m|
            m.program.functions.items[func_idx].param_types
        else
            &.{};
        // 求值参数到连续寄存器 dst+1, dst+2, ...
        for (arguments, 0..) |arg, i| {
            var arg_vreg = try emitExpr(fc, arg);
            if (i < param_types.len) if (param_types[i]) |ptn| {
                if (isBuiltinNumericType(ptn)) {
                    const at = exprBuiltinType(fc, arg);
                    if (at == null or !std.mem.eql(u8, at.?, ptn)) {
                        const coerced = fc.newTemp();
                        const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, ptn));
                        try fc.chunk.writeABC(.coerce, @intCast(coerced & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
                        arg_vreg = coerced;
                    }
                }
            };
            try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
        }
        // CALL A Bx — A=dst(结果寄存器), Bx=func_idx；argc 由 VM 从 callee.arity 读取
        try fc.chunk.writeABx(.call, @intCast(dst & 0xFF), func_idx, loc);
        return dst;
    }
    // callee 为非 identifier 的表达式 → CALL_VALUE
    const callee_vreg = try emitExpr(fc, callee);
    const dst = fc.newTemp();
    // callee 放 dst，args 放 dst+1...
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(callee_vreg & 0xFF), 0, loc);
    for (arguments, 0..) |arg, i| {
        const arg_vreg = try emitExpr(fc, arg);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
    }
    try fc.chunk.writeABC(.call_value, @intCast(dst & 0xFF), 0, @intCast(arguments.len), loc);
    return dst;
}

// ── field_access ──

fn emitFieldAccess(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
    const obj_vreg = try emitExpr(fc, object);
    const dst = fc.newTemp();
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
    try fc.chunk.writeABC(.get_field, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), @intCast(name_k & 0xFF), loc);
    return dst;
}

// ── method_call ──

fn emitMethodCall(fc: *RegFnCompiler, object: *const ast.Expr, method: []const u8, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const recv_vreg = try emitExpr(fc, object);
    const dst = fc.newTemp();
    // receiver 放 dst，args 放 dst+1, dst+2...
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(recv_vreg & 0xFF), 0, loc);
    for (arguments, 0..) |arg, i| {
        const arg_vreg = try emitExpr(fc, arg);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
    }
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, method));
    // CALL_METHOD A=dst, B=name_k_low, C=argc
    try fc.chunk.writeABC(.call_method, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(arguments.len), loc);
    return dst;
}

// ── array_literal ──

fn emitArrayLiteral(fc: *RegFnCompiler, elements: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    for (elements, 0..) |elem, i| {
        const elem_vreg = try emitExpr(fc, elem);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(elem_vreg & 0xFF), 0, loc);
    }
    try fc.chunk.writeABC(.make_array, @intCast(dst & 0xFF), @intCast(elements.len & 0xFF), 0, loc);
    return dst;
}

// ── record_literal ──

fn emitRecordLiteral(fc: *RegFnCompiler, fields: []ast.RecordFieldExpr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    for (fields, 0..) |field, i| {
        const val_vreg = try emitExpr(fc, field.value);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    }
    // shape_idx 需要 ModuleCompiler 查找，此处用占位 0
    const shape_idx: u16 = 0; // TODO
    try fc.chunk.writeABC(.make_record, @intCast(dst & 0xFF), @intCast(shape_idx & 0xFF), @intCast(fields.len & 0xFF), loc);
    return dst;
}

// ── index ──

fn emitIndex(fc: *RegFnCompiler, object: *const ast.Expr, index: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const obj_vreg = try emitExpr(fc, object);
    const index_vreg = try emitExpr(fc, index);
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.index_op, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), @intCast(index_vreg & 0xFF), loc);
    return dst;
}

// ── atomic_expr ──

fn emitAtomicExpr(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const val_vreg = try emitExpr(fc, inner);
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.make_atomic, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    return dst;
}

// ── lazy ──

fn emitLazyExpr(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    // lazy 需要闭包支持，简化为直接求值
    const val_vreg = try emitExpr(fc, inner);
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.make_lazy, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    return dst;
}

// ── non_null_assert ──

fn emitNonNullAssert(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const val_vreg = try emitExpr(fc, inner);
    // NON_NULL val — if null panic
    try fc.chunk.writeABC(.non_null, @intCast(val_vreg & 0xFF), 0, 0, loc);
    return val_vreg;
}

// ── propagate ──

fn emitPropagate(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const val_vreg = try emitExpr(fc, inner);
    // PROPAGATE val — if null/err return val; else val = val.ok
    try fc.chunk.writeABC(.propagate, @intCast(val_vreg & 0xFF), 0, 0, loc);
    return val_vreg;
}

// ── string_interpolation ──

fn emitStringInterp(fc: *RegFnCompiler, parts: []ast.InterpolationPart, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    var count: u8 = 0;
    for (parts) |part| {
        switch (part) {
            .literal => |lit| {
                const k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, lit));
                try fc.chunk.writeABx(.load_const, @intCast((dst + 1 + count) & 0xFF), k, loc);
                count += 1;
            },
            .expression => |expr| {
                const part_vreg = try emitExpr(fc, expr);
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + count) & 0xFF), @intCast(part_vreg & 0xFF), 0, loc);
                count += 1;
            },
        }
    }
    try fc.chunk.writeABC(.interp, @intCast(dst & 0xFF), count, count, loc);
    return dst;
}

// ── type_cast ──

fn emitTypeCast(fc: *RegFnCompiler, inner: *const ast.Expr, target_type: *ast.TypeNode, loc: ast.SourceLocation) !reg_alloc.VReg {
    const val_vreg = try emitExpr(fc, inner);
    const dst = fc.newTemp();
    // type_name_idx 需要从 target_type 提取，简化为 0
    _ = target_type;
    try fc.chunk.writeABC(.cast, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    return dst;
}

// ── match ──

fn emitMatch(fc: *RegFnCompiler, scrutinee: *const ast.Expr, arms: []ast.MatchArm, loc: ast.SourceLocation) !reg_alloc.VReg {
    const scrut_vreg = try emitExpr(fc, scrutinee);
    const dst = fc.newTemp();
    var end_jumps = std.ArrayListUnmanaged(usize).empty;
    defer end_jumps.deinit(fc.allocator);

    for (arms) |arm| {
        // 模式测试：不匹配则跳到下一个 arm
        const fail_jump = try emitPatternTest(fc, arm.pattern, scrut_vreg, loc);
        // guard 检查
        if (arm.guard) |guard_expr| {
            const guard_vreg = try emitExpr(fc, guard_expr);
            const guard_fail = try fc.chunk.emitJump(.jump_if_false, @intCast(guard_vreg & 0xFF), loc);
            if (fail_jump) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
            // 匹配 + guard 通过：求值 body
            const body_vreg = try emitExpr(fc, arm.body);
            try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, loc);
            try end_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump, 0, loc));
            fc.chunk.patchJump(guard_fail, fc.chunk.here());
        } else {
            // 匹配：求值 body
            const body_vreg = try emitExpr(fc, arm.body);
            try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, loc);
            try end_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump, 0, loc));
            // fail 落点
            if (fail_jump) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
        }
    }
    // 全部不匹配
    try fc.chunk.writeABC(.match_fail, 0, 0, 0, loc);
    // end 落点
    for (end_jumps.items) |ej| fc.chunk.patchJump(ej, fc.chunk.here());
    return dst;
}

fn emitPatternTest(fc: *RegFnCompiler, pat: *const ast.Pattern, scrut_vreg: reg_alloc.VReg, loc: ast.SourceLocation) CompileError!?usize {
    return switch (pat.*) {
        .wildcard => null, // 通配符总是匹配
        .variable => |v| blk: {
            // 变量绑定：声明局部并 MOVE scrut → local
            _ = try fc.declareLocal(v.name, false, false, null);
            const local_vreg = fc.resolveLocal(v.name).?;
            try fc.chunk.writeABC(.move, @intCast(local_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
            break :blk null;
        },
        .literal => |lit| blk: {
            // 字面量模式：TEST_LIT
            const dst = fc.newTemp();
            const k = try addPatternLiteralConstant(fc, lit);
            try fc.chunk.writeABC(.test_lit, @intCast(dst & 0xFF), @intCast(scrut_vreg & 0xFF), @intCast(k & 0xFF), loc);
            const fail = try fc.chunk.emitJump(.jump_if_false, @intCast(dst & 0xFF), loc);
            break :blk fail;
        },
        else => null, // 其他模式（constructor/record/or/guard）后续实现
    };
}

fn addPatternLiteralConstant(fc: *RegFnCompiler, lit: ast.PatternLiteral) !u16 {
    return switch (lit) {
        .int => |raw| blk: {
            const parsed = compiler.parseIntSoftware(raw) orelse return error.Unsupported;
            break :blk try fc.chunk.addConstant(value.Value.fromInt(parsed));
        },
        .float => |raw| blk: {
            const parsed = compiler.parseFloatSoftware(raw) orelse return error.Unsupported;
            break :blk try fc.chunk.addConstant(value.Value.fromFloat(parsed));
        },
        .bool => |b| try fc.chunk.addConstant(value.Value.fromBool(b)),
        .char => |c| blk: {
            const ch = value.Char.fromCodePoint(c) catch return error.Unsupported;
            break :blk try fc.chunk.addConstant(value.Value.fromChar(ch));
        },
        .string => |s| try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, s)),
        .null => try fc.chunk.addConstant(value.Value.fromNull()),
    };
}

// ── lambda（简化：TODO 闭包编译）──

fn emitLambda(fc: *RegFnCompiler, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 简化：创建闭包占位，func_idx=0
    const dst = fc.newTemp();
    const func_idx: u16 = 0; // TODO: 子编译器编译 lambda body
    try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), func_idx, loc);
    return dst;
}

// ── 语句发射 ──

pub fn emitStmt(fc: *RegFnCompiler, stmt: *const ast.Stmt) CompileError!void {
    const loc = stmt.getLocation();
    switch (stmt.*) {
        .val_decl => |vd| try emitValDecl(fc, vd.name, vd.value, loc),
        .var_decl => |vd| try emitVarDecl(fc, vd.name, vd.value, loc),
        .expression => |e| {
            _ = try emitExpr(fc, e.expr);
        },
        .return_stmt => |rs| try emitReturn(fc, rs.value, loc),
        .while_stmt => |ws| try emitWhile(fc, ws.condition, ws.body, loc),
        .for_stmt => |fs| try emitFor(fc, fs.name, fs.iterable, fs.body, loc),
        .break_stmt => try emitBreak(fc, loc),
        .continue_stmt => try emitContinue(fc, loc),
        .assignment => |a| try emitAssignment(fc, a.target, a.value, loc),
        .field_assignment => |fa| try emitFieldAssignment(fc, fa.object, fa.field, fa.value, loc),
        .compound_assignment => |ca| try emitCompoundAssignment(fc, ca.target, ca.op, ca.value, loc),
        .throw_stmt => |ts| try emitThrow(fc, ts.expr, loc),
        .defer_stmt => |ds| try emitDefer(fc, ds.expr, loc),
        .loop_stmt => |ls| try emitLoop(fc, ls.body, loc),
    }
}

fn emitValDecl(fc: *RegFnCompiler, name: []const u8, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    const rhs_vreg = try emitExpr(fc, val_expr);
    _ = try fc.declareLocal(name, false, false, null);
    const local_vreg = fc.resolveLocal(name).?;
    try fc.chunk.writeABC(.bind, @intCast(local_vreg & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
}

fn emitVarDecl(fc: *RegFnCompiler, name: []const u8, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    const rhs_vreg = try emitExpr(fc, val_expr);
    _ = try fc.declareLocal(name, true, false, null);
    const local_vreg = fc.resolveLocal(name).?;
    try fc.chunk.writeABC(.bind, @intCast(local_vreg & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
}

fn emitReturn(fc: *RegFnCompiler, val_expr: ?*const ast.Expr, loc: ast.SourceLocation) !void {
    if (val_expr) |v| {
        const vreg = try emitExpr(fc, v);
        try fc.chunk.writeABC(.return_op, @intCast(vreg & 0xFF), 0, 0, loc);
    } else {
        try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
    }
}

fn emitWhile(fc: *RegFnCompiler, condition: *const ast.Expr, body: *const ast.Expr, loc: ast.SourceLocation) !void {
    const loop_start = fc.chunk.here();
    try fc.loops.append(fc.allocator, .{
        .continue_target = loop_start,
        .breaks = .empty,
        .defer_depth = 0,
    });
    const cond_vreg = try emitExpr(fc, condition);
    const exit_jump = try fc.chunk.emitJump(.jump_if_false, @intCast(cond_vreg & 0xFF), loc);
    _ = try emitExpr(fc, body);
    // 回跳到 loop_start
    const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
    try fc.chunk.writesBx(.jump, 0, offset, loc);
    // exit 落点
    fc.chunk.patchJump(exit_jump, fc.chunk.here());
    // patch breaks
    var lc = fc.loops.pop() orelse return error.InvalidJump;
    for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
    lc.breaks.deinit(fc.allocator);
}

fn emitFor(fc: *RegFnCompiler, var_name: []const u8, iterable: *const ast.Expr, body: *const ast.Expr, loc: ast.SourceLocation) !void {
    // 求值 iterable
    const iter_vreg = try emitExpr(fc, iterable);
    const idx_vreg = fc.newTemp();
    // 初始化 idx = 0
    const zero_vreg = fc.newTemp();
    try fc.chunk.writeABC(.load_null, @intCast(zero_vreg & 0xFF), 0, 0, loc);
    try fc.chunk.writeABC(.move, @intCast(idx_vreg & 0xFF), @intCast(zero_vreg & 0xFF), 0, loc);
    // 声明循环变量
    _ = try fc.declareLocal(var_name, false, false, null);
    const var_vreg = fc.resolveLocal(var_name).?;

    const loop_start = fc.chunk.here();
    try fc.loops.append(fc.allocator, .{
        .continue_target = loop_start,
        .breaks = .empty,
        .defer_depth = 0,
    });
    // FOR_NEXT var, iter, idx — 耗尽时跳过下一条 JUMP
    try fc.chunk.writeABC(.for_next, @intCast(var_vreg & 0xFF), @intCast(iter_vreg & 0xFF), @intCast(idx_vreg & 0xFF), loc);
    const exit_jump = try fc.chunk.emitJump(.jump, 0, loc); // 耗尽时跳过
    _ = try emitExpr(fc, body);
    // 回跳
    const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
    try fc.chunk.writesBx(.jump, 0, offset, loc);
    fc.chunk.patchJump(exit_jump, fc.chunk.here());
    var lc = fc.loops.pop() orelse return error.InvalidJump;
    for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
    lc.breaks.deinit(fc.allocator);
}

fn emitLoop(fc: *RegFnCompiler, body: *const ast.Expr, loc: ast.SourceLocation) !void {
    const loop_start = fc.chunk.here();
    try fc.loops.append(fc.allocator, .{
        .continue_target = loop_start,
        .breaks = .empty,
        .defer_depth = 0,
    });
    _ = try emitExpr(fc, body);
    // 无条件回跳
    const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
    try fc.chunk.writesBx(.jump, 0, offset, loc);
    // break 落点
    var lc = fc.loops.pop() orelse return error.InvalidJump;
    for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
    lc.breaks.deinit(fc.allocator);
}

fn emitBreak(fc: *RegFnCompiler, loc: ast.SourceLocation) !void {
    if (fc.loops.items.len == 0) return error.InvalidJump;
    const idx = try fc.chunk.emitJump(.jump, 0, loc);
    try fc.loops.items[fc.loops.items.len - 1].breaks.append(fc.allocator, idx);
}

fn emitContinue(fc: *RegFnCompiler, loc: ast.SourceLocation) !void {
    if (fc.loops.items.len == 0) return error.InvalidJump;
    const target = fc.loops.items[fc.loops.items.len - 1].continue_target;
    const offset: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fc.chunk.here() + 1)));
    try fc.chunk.writesBx(.jump, 0, offset, loc);
}

fn emitAssignment(fc: *RegFnCompiler, target: *const ast.Expr, val: *const ast.Expr, loc: ast.SourceLocation) !void {
    const val_vreg = try emitExpr(fc, val);
    if (target.* == .identifier) {
        const local_vreg = fc.resolveLocal(target.identifier.name) orelse return error.Unsupported;
        try fc.chunk.writeABC(.assign, @intCast(local_vreg & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    } else {
        return error.Unsupported;
    }
}

fn emitFieldAssignment(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, val: *const ast.Expr, loc: ast.SourceLocation) !void {
    const obj_vreg = try emitExpr(fc, object);
    const val_vreg = try emitExpr(fc, val);
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.set_field, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(val_vreg & 0xFF), loc);
    _ = obj_vreg;
}

fn emitCompoundAssignment(fc: *RegFnCompiler, target: *const ast.Expr, op: ast.CompoundAssignOp, val: *const ast.Expr, loc: ast.SourceLocation) !void {
    const val_vreg = try emitExpr(fc, val);
    if (target.* == .identifier) {
        const local_vreg = fc.resolveLocal(target.identifier.name) orelse return error.Unsupported;
        const arith_op: u8 = switch (op) {
            .add_assign => @intFromEnum(reg_opcode.Op.add),
            .sub_assign => @intFromEnum(reg_opcode.Op.sub),
            .mul_assign => @intFromEnum(reg_opcode.Op.mul),
            .div_assign => @intFromEnum(reg_opcode.Op.div),
            .mod_assign => @intFromEnum(reg_opcode.Op.mod),
            .bit_and_assign => @intFromEnum(reg_opcode.Op.bit_and),
            .bit_or_assign => @intFromEnum(reg_opcode.Op.bit_or),
        };
        try fc.chunk.writeABC(.compound_local, @intCast(local_vreg & 0xFF), arith_op, @intCast(val_vreg & 0xFF), loc);
    } else {
        return error.Unsupported;
    }
}

fn emitThrow(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    const vreg = try emitExpr(fc, expr);
    try fc.chunk.writeABC(.throw_op, @intCast(vreg & 0xFF), 0, 0, loc);
}

fn emitDefer(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    // 简化：defer 直接求值（不延迟执行）
    _ = try emitExpr(fc, expr);
    _ = loc;
}

// ============================================================
// 模块级编译器：AST Module → RegProgram
// ============================================================

/// 模块编译器：消费 ast.Module，产出 RegProgram（持有所有 RegFunction）。
/// 两遍编译：第一遍登记函数名→索引，第二遍编译函数体（使前向引用合法）。
pub const RegModuleCompiler = struct {
    program: reg_chunk.RegProgram,
    allocator: std.mem.Allocator,
    /// 顶层函数表：name → func_idx
    fn_map: std.StringHashMap(u16),

    pub fn init(allocator: std.mem.Allocator) RegModuleCompiler {
        return .{
            .program = reg_chunk.RegProgram.init(allocator),
            .allocator = allocator,
            .fn_map = std.StringHashMap(u16).init(allocator),
        };
    }

    pub fn deinit(self: *RegModuleCompiler) void {
        self.fn_map.deinit();
        // program 所有权移交调用方；此处不 deinit。
    }

    /// 查找顶层函数索引
    pub fn lookupFn(self: *RegModuleCompiler, name: []const u8) ?u16 {
        return self.fn_map.get(name);
    }

    /// 编译入口模块 + 其 `use` 依赖模块。依赖在前，入口在后（入口可前向引用依赖）。
    pub fn compileModuleWithDeps(self: *RegModuleCompiler, module: *const ast.Module, deps: []const ast.Module) CompileError!void {
        // 第一遍：登记所有模块的顶层函数名
        for (deps) |*dep| try self.registerDecls(dep);
        try self.registerDecls(module);
        // 第二遍：编译所有模块的函数体
        for (deps) |*dep| try self.compileBodies(dep);
        try self.compileBodies(module);
        // 设置 entry
        if (self.lookupFn("main")) |m| self.program.entry = m;
    }

    /// 第一遍：登记模块的顶层函数声明
    fn registerDecls(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 同名函数已登记（依赖与入口重名）→ 跳过（首个生效）
                    if (self.fn_map.contains(fd.name)) continue;
                    const idx: u16 = @intCast(self.program.functions.items.len);
                    try self.fn_map.put(fd.name, idx);
                    // 提取参数类型名（caller-side coerce 用；字符串借用 AST 生命周期）
                    var ptypes: []?[]const u8 = &.{};
                    if (fd.params.len > 0) {
                        ptypes = self.program.allocator.alloc(?[]const u8, fd.params.len) catch return error.OutOfMemory;
                        for (fd.params, 0..) |p, i| {
                            ptypes[i] = paramTypeName(p.type_annotation);
                        }
                    }
                    // 预占位：空 chunk，第二遍编译时覆盖
                    try self.program.functions.append(self.allocator, .{
                        .chunk = reg_chunk.RegChunk.init(self.allocator),
                        .arity = @intCast(fd.params.len),
                        .name = fd.name,
                        .param_types = ptypes,
                    });
                },
                else => {},
            }
        }
    }

    /// 第二遍：编译模块的函数体
    fn compileBodies(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| try self.compileFunction(fd),
                else => {},
            }
        }
    }

    /// 编译单个函数体
    fn compileFunction(self: *RegModuleCompiler, fd: anytype) CompileError!void {
        var fc = RegFnCompiler.init(self.allocator);
        fc.module = self;
        fc.name = fd.name;
        fc.arity = @intCast(fd.params.len);
        defer fc.deinit();

        // 声明参数为局部变量（占 VReg 0..arity-1，与 VM setupFrame 的参数布局一致）
        for (fd.params) |p| {
            _ = try fc.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
        }

        // 编译函数体（尾位置）
        const loc = fd.location;
        const body_vreg = try emitExpr(&fc, fd.body);
        // 隐式 return（函数体无显式 return 时执行；有 return 时为死代码）
        try fc.chunk.writeABC(.return_op, @intCast(body_vreg & 0xFF), 0, 0, loc);

        // 覆盖第一遍预留的占位槽
        const idx = self.lookupFn(fd.name).?;
        self.program.functions.items[idx].chunk.deinit(); // 释放占位空 chunk
        self.program.functions.items[idx].chunk = fc.chunk; // 移交所有权
        self.program.functions.items[idx].arity = @intCast(fd.params.len);
        self.program.functions.items[idx].register_count = @intCast(fc.next_vreg);
        // release_mask：简化版 — 标记所有寄存器需 release（bit i=1）
        // release(null/unit/int/float) 是安全的无操作，只有 boxed 值真正减引用计数
        const nreg: u6 = @intCast(@min(fc.next_vreg, 64));
        if (nreg == 64) {
            self.program.functions.items[idx].release_mask = ~@as(u64, 0);
        } else if (nreg > 0) {
            self.program.functions.items[idx].release_mask = (@as(u64, 1) << nreg) - 1;
        }

        // 防止 fc.deinit 释放已移交的 chunk（置空壳）
        fc.chunk = reg_chunk.RegChunk.init(self.allocator);
    }
};
