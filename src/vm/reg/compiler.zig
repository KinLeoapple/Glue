//! 寄存器式编译器：AST → RegChunk。
//! 与栈式 compiler.zig 对应，但 emitExpr 返回目标寄存器号而非压栈。
//! 每个表达式求值结果写入一个 VReg，由寄存器分配器映射到 PReg。
//! 简化方案：先假设 VReg < 256，直接用 VReg 低字节作 PReg（后续分配器优化）。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");
/// 再导出 reg_chunk，使外部模块（main.zig）可访问 RegProgram 等类型
pub const reg_chunk_mod = reg_chunk;
const reg_alloc = @import("alloc.zig");
const shared = @import("shared");
const method_mod = shared.method_mod;
const analysis_db_mod = @import("analysis_db");

/// 再导出 reg_vm，使本模块作为 root_source_file 时 vm.zig 可达
pub const reg_vm = @import("vm.zig");
/// 再导出 reg_passes / reg_optimizer，使外部模块可达
pub const reg_passes = @import("passes.zig");
pub const reg_optimizer = @import("optimizer.zig");

/// 内建 Error trait 名（error_newtype 的方法注册到此 trait）
/// error_newtype 默认 prefix
const ERROR_DEFAULT_PREFIX = "error";
/// 内建类型名常量（集中定义于 ast.type_names）
const type_names = ast.type_names;

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
    /// 非 null = 该 local 持有闭包，指向 program.functions[func_idx]（caller-side coerce 用）
    func_idx: ?u16 = null,
};

const UpvalueInfo = struct {
    name: []const u8,
    is_local: bool,
    index: u8,
    /// 非 null = 该 upvalue 持有闭包，指向 program.functions[func_idx]
    func_idx: ?u16 = null,
};

/// 函数 AST 缓存项（内联用）：body 表达式 + 参数列表，借用 AST 生命周期。
const FnAstEntry = struct {
    body: *const ast.Expr,
    params: []const ast.Param,
};

/// 顶层全局声明条目（globals_init 编译用）：借用 AST 生命周期。
/// is_var_decl=true → var_decl/val_decl，需注册全局槽并 store_global；
/// is_var_decl=false → 普通顶层语句/表达式，直接 emit。
const GlobalInitEntry = struct {
    name: []const u8 = "", // 全局名（is_var_decl=true 时有效）
    is_var_decl: bool,
    type_ann: ?*const ast.TypeNode = null,
    init_expr: *const ast.Expr, // 初始化表达式（var_decl/val_decl 的 value；否则为 expr_decl.expr）
    stmt: ?*const ast.Stmt = null, // 顶层语句（assignment/for/while 等）；null = 纯表达式
    loc: ast.SourceLocation,
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
    /// LICM: 已外提到循环前的不变量 expr → 寄存器映射（同一循环内多次引用只 emit 一次）
    hoisted_regs: std.AutoHashMapUnmanaged(*const ast.Expr, reg_alloc.VReg) = .{},
    /// CSE: canonical expr → 寄存器映射（redundant 直接读此寄存器）
    cse_regs: std.AutoHashMapUnmanaged(*const ast.Expr, reg_alloc.VReg) = .{},
    /// 内联：被内联函数的参数名 → 实参寄存器映射（emit 期间临时绑定，结束移除）
    inline_param_regs: std.StringHashMapUnmanaged(reg_alloc.VReg) = .{},

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
        self.hoisted_regs.deinit(self.allocator);
        self.cse_regs.deinit(self.allocator);
        self.inline_param_regs.deinit(self.allocator);
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

    /// 查找局部变量的 func_idx（闭包 local → program.functions 索引；非闭包返回 null）
    pub fn findLocalFuncIdx(self: *RegFnCompiler, name: []const u8) ?u16 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                return self.locals.items[i].func_idx;
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

    /// 查找 upvalue 的 func_idx（闭包 upvalue → program.functions 索引；非闭包返回 null）
    pub fn findUpvalueFuncIdx(self: *RegFnCompiler, name: []const u8) ?u16 {
        for (self.upvalues.items) |uv| {
            if (std.mem.eql(u8, uv.name, name)) return uv.func_idx;
        }
        return null;
    }

    /// 添加 upvalue
    pub fn addUpvalue(self: *RegFnCompiler, name: []const u8, is_local: bool, index: u8, func_idx: ?u16) !u8 {
        const idx: u8 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{
            .name = name,
            .is_local = is_local,
            .index = index,
            .func_idx = func_idx,
        });
        return idx;
    }

    /// 递归解析 upvalue：先查已有 upvalue（去重），再沿 enclosing 链查找。
    /// is_local=true → 捕获外层局部（index=寄存器号）；
    /// is_local=false → 捕获外层 upvalue（index=upvalue 索引）。
    pub fn resolveUpvalueRecursive(self: *RegFnCompiler, name: []const u8) !?u8 {
        // 去重：已在本函数 upvalue 表中
        if (self.resolveUpvalue(name)) |idx| return idx;
        const enc = self.enclosing orelse return null;
        // 查外层局部
        if (enc.resolveLocal(name)) |vreg| {
            const fidx = enc.findLocalFuncIdx(name);
            return try self.addUpvalue(name, true, @intCast(vreg & 0xFF), fidx);
        }
        // 递归查外层 upvalue
        if (try enc.resolveUpvalueRecursive(name)) |uv_idx| {
            const fidx = enc.findUpvalueFuncIdx(name);
            return try self.addUpvalue(name, false, uv_idx, fidx);
        }
        return null;
    }
};

// ── 表达式发射 ──
// emitExpr 返回存放结果的 VReg。
// 调用方负责通过 getPReg 映射到物理寄存器后写入指令。

/// 将 ConstProp 的 ConstValue 转为运行时 Value（仅 int/float/bool；unknown 返回 null）。
/// 用于常量折叠：命中时直接 load_const，跳过子树求值。
fn constValueToValue(cv: analysis_db_mod.ConstValue) ?value.Value {
    return switch (cv) {
        .int_val => |i| value.Value.fromInt(value.Int.fromNative(.i128, i)),
        .float_val => |f| value.Value.fromFloat(value.Float.fromNative(.f64, f)),
        .bool_val => |b| value.Value.fromBool(b),
        .unknown => null,
    };
}

// ── 函数内联辅助 ──

/// 递归统计表达式节点数（lambda 体不计入：独立作用域）。
fn countExprNodes(expr: *const ast.Expr) u32 {
    return switch (expr.*) {
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal, .identifier,
        => 1,

        .binary => |b| 1 + countExprNodes(b.left) + countExprNodes(b.right),
        .unary => |u| 1 + countExprNodes(u.operand),
        .if_expr => |i| 1 + countExprNodes(i.condition) + countExprNodes(i.then_branch) +
            (if (i.else_branch) |e| countExprNodes(e) else 0),
        .block => |blk| blk: {
            var n: u32 = 1;
            for (blk.statements) |s| n += countExprNodesStmt(s);
            if (blk.trailing_expr) |te| n += countExprNodes(te);
            break :blk n;
        },
        .call => |c| blk: {
            var n: u32 = 1 + countExprNodes(c.callee);
            for (c.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .lambda => 1, // 不递归 lambda 体（独立作用域）
        .field_access => |f| 1 + countExprNodes(f.object),
        .method_call => |mc| blk: {
            var n: u32 = 1 + countExprNodes(mc.object);
            for (mc.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .match => |m| blk: {
            var n: u32 = 1 + countExprNodes(m.scrutinee);
            for (m.arms) |arm| {
                if (arm.guard) |g| n += countExprNodes(g);
                n += countExprNodes(arm.body);
            }
            break :blk n;
        },
        .array_literal => |al| blk: {
            var n: u32 = 1;
            for (al.elements) |e| n += countExprNodes(e);
            break :blk n;
        },
        .record_literal => |rl| blk: {
            var n: u32 = 1;
            for (rl.fields) |f| n += countExprNodes(f.value);
            break :blk n;
        },
        .index => |idx| 1 + countExprNodes(idx.object) + countExprNodes(idx.index),
        .atomic_expr => |ae| 1 + countExprNodes(ae.value),
        .lazy => |lz| 1 + countExprNodes(lz.expr),
        .non_null_assert => |nna| 1 + countExprNodes(nna.expr),
        .propagate => |pr| 1 + countExprNodes(pr.expr),
        .string_interpolation => |si| blk: {
            var n: u32 = 1;
            for (si.parts) |part| {
                if (part == .expression) n += countExprNodes(part.expression);
            }
            break :blk n;
        },
        .type_cast => |tc| 1 + countExprNodes(tc.expr),
        .record_extend => |re| blk: {
            var n: u32 = 1 + countExprNodes(re.base);
            for (re.updates) |u| n += countExprNodes(u.value);
            break :blk n;
        },
        .safe_access => |sa| 1 + countExprNodes(sa.object),
        .safe_method_call => |smc| blk: {
            var n: u32 = 1 + countExprNodes(smc.object);
            for (smc.arguments) |a| n += countExprNodes(a);
            break :blk n;
        },
        .select => |sel| blk: {
            var n: u32 = 1;
            for (sel.arms) |arm| switch (arm) {
                .receive => |r| {
                    n += countExprNodes(r.channel_expr);
                    n += countExprNodes(r.body);
                },
                .timeout => |t| {
                    n += countExprNodes(t.duration);
                    n += countExprNodes(t.body);
                },
            };
            break :blk n;
        },
        .assignment_expr => |a| 1 + countExprNodes(a.target) + countExprNodes(a.value),
        .compound_assign => |c| 1 + countExprNodes(c.target) + countExprNodes(c.value),
        else => 1,
    };
}

fn countExprNodesStmt(stmt: *const ast.Stmt) u32 {
    return switch (stmt.*) {
        .val_decl => |v| 1 + countExprNodes(v.value),
        .var_decl => |v| 1 + countExprNodes(v.value),
        .assignment => |a| 1 + countExprNodes(a.target) + countExprNodes(a.value),
        .field_assignment => |f| 1 + countExprNodes(f.object) + countExprNodes(f.value),
        .compound_assignment => |c| 1 + countExprNodes(c.target) + countExprNodes(c.value),
        .expression => |e| 1 + countExprNodes(e.expr),
        .return_stmt => |r| 1 + (if (r.value) |v| countExprNodes(v) else 0),
        .defer_stmt => |d| 1 + countExprNodes(d.expr),
        .throw_stmt => |t| 1 + countExprNodes(t.expr),
        .break_stmt, .continue_stmt => 1,
        .for_stmt => |f| 1 + countExprNodes(f.iterable) + countExprNodes(f.body),
        .while_stmt => |w| 1 + countExprNodes(w.condition) + countExprNodes(w.body),
        .loop_stmt => |l| 1 + countExprNodes(l.body),
    };
}

/// 检测表达式是否含控制流结构（if/match/lambda/循环/return/break/continue/throw）。
/// 内联这些结构需额外处理跳转重映射，简化起见一律拒绝内联。
fn hasControlFlow(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .if_expr, .match, .lambda, .select => return true,

        .binary => |b| return hasControlFlow(b.left) or hasControlFlow(b.right),
        .unary => |u| return hasControlFlow(u.operand),
        .block => |blk| {
            for (blk.statements) |s| if (hasControlFlowStmt(s)) return true;
            if (blk.trailing_expr) |te| return hasControlFlow(te);
            return false;
        },
        .call => |c| {
            if (hasControlFlow(c.callee)) return true;
            for (c.arguments) |a| if (hasControlFlow(a)) return true;
            return false;
        },
        .field_access => |f| return hasControlFlow(f.object),
        .method_call => |mc| {
            if (hasControlFlow(mc.object)) return true;
            for (mc.arguments) |a| if (hasControlFlow(a)) return true;
            return false;
        },
        .array_literal => |al| {
            for (al.elements) |e| if (hasControlFlow(e)) return true;
            return false;
        },
        .record_literal => |rl| {
            for (rl.fields) |f| if (hasControlFlow(f.value)) return true;
            return false;
        },
        .index => |idx| return hasControlFlow(idx.object) or hasControlFlow(idx.index),
        .atomic_expr => |ae| return hasControlFlow(ae.value),
        .lazy => |lz| return hasControlFlow(lz.expr),
        .non_null_assert => |nna| return hasControlFlow(nna.expr),
        .propagate => |pr| return hasControlFlow(pr.expr),
        .string_interpolation => |si| {
            for (si.parts) |part| if (part == .expression) if (hasControlFlow(part.expression)) return true;
            return false;
        },
        .type_cast => |tc| return hasControlFlow(tc.expr),
        .record_extend => |re| {
            if (hasControlFlow(re.base)) return true;
            for (re.updates) |u| if (hasControlFlow(u.value)) return true;
            return false;
        },
        .safe_access => return true,
        .safe_method_call => return true,
        .assignment_expr => |a| return hasControlFlow(a.target) or hasControlFlow(a.value),
        .compound_assign => |c| return hasControlFlow(c.target) or hasControlFlow(c.value),

        else => return false,
    }
}

fn hasControlFlowStmt(stmt: *const ast.Stmt) bool {
    return switch (stmt.*) {
        .return_stmt, .break_stmt, .continue_stmt, .throw_stmt => true,
        .for_stmt, .while_stmt, .loop_stmt => true,
        .val_decl => |v| hasControlFlow(v.value),
        .var_decl => |v| hasControlFlow(v.value),
        .assignment => |a| hasControlFlow(a.target) or hasControlFlow(a.value),
        .field_assignment => |f| hasControlFlow(f.object) or hasControlFlow(f.value),
        .compound_assignment => |c| hasControlFlow(c.target) or hasControlFlow(c.value),
        .expression => |e| hasControlFlow(e.expr),
        .defer_stmt => |d| hasControlFlow(d.expr),
    };
}

/// 检测函数体是否含对自身的直接调用（递归）。lambda 内部作用域不计（名字被遮蔽）。
fn callsSelf(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .call => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier.name, name)) break :blk true;
            if (callsSelf(c.callee, name)) break :blk true;
            for (c.arguments) |a| if (callsSelf(a, name)) break :blk true;
            break :blk false;
        },
        .binary => |b| callsSelf(b.left, name) or callsSelf(b.right, name),
        .unary => |u| callsSelf(u.operand, name),
        .block => |blk| blk: {
            for (blk.statements) |s| if (callsSelfStmt(s, name)) break :blk true;
            if (blk.trailing_expr) |te| {
                if (callsSelf(te, name)) break :blk true;
            }
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (callsSelf(i.condition, name)) break :blk true;
            if (callsSelf(i.then_branch, name)) break :blk true;
            if (i.else_branch) |e| if (callsSelf(e, name)) break :blk true;
            break :blk false;
        },
        .field_access => |f| callsSelf(f.object, name),
        .method_call => |mc| blk: {
            if (callsSelf(mc.object, name)) break :blk true;
            for (mc.arguments) |a| if (callsSelf(a, name)) break :blk true;
            break :blk false;
        },
        .array_literal => |al| blk: {
            for (al.elements) |e| if (callsSelf(e, name)) break :blk true;
            break :blk false;
        },
        .record_literal => |rl| blk: {
            for (rl.fields) |f| if (callsSelf(f.value, name)) break :blk true;
            break :blk false;
        },
        .index => |idx| callsSelf(idx.object, name) or callsSelf(idx.index, name),
        .atomic_expr => |ae| callsSelf(ae.value, name),
        .lazy => |lz| callsSelf(lz.expr, name),
        .non_null_assert => |nna| callsSelf(nna.expr, name),
        .propagate => |pr| callsSelf(pr.expr, name),
        .string_interpolation => |si| blk: {
            for (si.parts) |part| {
                if (part == .expression) if (callsSelf(part.expression, name)) break :blk true;
            }
            break :blk false;
        },
        .type_cast => |tc| callsSelf(tc.expr, name),
        .record_extend => |re| blk: {
            if (callsSelf(re.base, name)) break :blk true;
            for (re.updates) |u| if (callsSelf(u.value, name)) break :blk true;
            break :blk false;
        },
        .safe_access => |sa| callsSelf(sa.object, name),
        .safe_method_call => |smc| blk: {
            if (callsSelf(smc.object, name)) break :blk true;
            for (smc.arguments) |a| if (callsSelf(a, name)) break :blk true;
            break :blk false;
        },
        .assignment_expr => |a| callsSelf(a.target, name) or callsSelf(a.value, name),
        .compound_assign => |c| callsSelf(c.target, name) or callsSelf(c.value, name),
        // match 的 scrutinee/arms body 递归检查；lambda 不递归（遮蔽）
        .match => |m| blk: {
            if (callsSelf(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (callsSelf(g, name)) break :blk true;
                if (callsSelf(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .lambda => false,
        .select => |sel| blk: {
            for (sel.arms) |arm| switch (arm) {
                .receive => |r| {
                    if (callsSelf(r.channel_expr, name)) break :blk true;
                    if (callsSelf(r.body, name)) break :blk true;
                },
                .timeout => |t| {
                    if (callsSelf(t.duration, name)) break :blk true;
                    if (callsSelf(t.body, name)) break :blk true;
                },
            };
            break :blk false;
        },
        else => false,
    };
}

fn callsSelfStmt(stmt: *const ast.Stmt, name: []const u8) bool {
    return switch (stmt.*) {
        .val_decl => |v| callsSelf(v.value, name),
        .var_decl => |v| callsSelf(v.value, name),
        .assignment => |a| callsSelf(a.target, name) or callsSelf(a.value, name),
        .field_assignment => |f| callsSelf(f.object, name) or callsSelf(f.value, name),
        .compound_assignment => |c| callsSelf(c.target, name) or callsSelf(c.value, name),
        .expression => |e| callsSelf(e.expr, name),
        .return_stmt => |r| if (r.value) |v| callsSelf(v, name) else false,
        .defer_stmt => |d| callsSelf(d.expr, name),
        .throw_stmt => |t| callsSelf(t.expr, name),
        .for_stmt => |f| callsSelf(f.iterable, name) or callsSelf(f.body, name),
        .while_stmt => |w| callsSelf(w.condition, name) or callsSelf(w.body, name),
        .loop_stmt => |l| callsSelf(l.body, name),
        .break_stmt, .continue_stmt => false,
    };
}

/// 内联合格性：函数体小（≤8 节点）、无控制流（无 if/match/loop/return 等）、非递归、arity ≤ 3。
fn canInlineFn(name: []const u8, arity: usize, body: *const ast.Expr) bool {
    if (arity > 3) return false;
    if (countExprNodes(body) > 8) return false;
    if (hasControlFlow(body)) return false;
    if (callsSelf(body, name)) return false;
    return true;
}

/// 函数内联：将函数体直接内联到调用点，参数名绑定到实参寄存器（inline_param_regs）。
/// 成功内联返回结果寄存器；不可内联返回 null。
fn tryEmitInlineCall(
    fc: *RegFnCompiler,
    callee_name: []const u8,
    arguments: []*ast.Expr,
    entry: FnAstEntry,
    loc: ast.SourceLocation,
) !?reg_alloc.VReg {
    if (!canInlineFn(callee_name, entry.params.len, entry.body)) return null;
    if (entry.params.len != arguments.len) return null;
    // 求值实参并绑定到 inline_param_regs（emitIdentifier 优先查此表）
    // 先全部求值再绑定，避免参数间 emitExpr 时 inline_param_regs 被部分填充导致提前引用
    var arg_regs: std.ArrayListUnmanaged(reg_alloc.VReg) = .empty;
    defer arg_regs.deinit(fc.allocator);
    for (arguments) |arg| {
        const arg_vreg = try emitExpr(fc, arg);
        try arg_regs.append(fc.allocator, arg_vreg);
    }
    // 绑定参数名 → 寄存器
    // var 参数需拷贝到独立寄存器，避免赋值写穿调用方变量（值语义）
    for (entry.params, 0..) |p, i| {
        if (p.is_var) {
            const copy_vreg = fc.newTemp();
            try fc.chunk.writeABC(.move, @intCast(copy_vreg & 0xFF), @intCast(arg_regs.items[i] & 0xFF), 0, loc);
            try fc.inline_param_regs.put(fc.allocator, p.name, copy_vreg);
        } else {
            try fc.inline_param_regs.put(fc.allocator, p.name, arg_regs.items[i]);
        }
    }
    // emit 函数体（emitIdentifier 会查 inline_param_regs）
    const result = try emitExpr(fc, entry.body);
    // 清理绑定
    for (entry.params) |p| _ = fc.inline_param_regs.remove(p.name);
    return result;
}

// ── 循环展开辅助 ──

/// 检测表达式是否含 break/continue 语句（递归进入 block 的语句列表）。
/// lambda 内部作用域不计（break/continue 作用于外层循环）。
fn exprHasBreakOrContinue(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .block => |blk| {
            for (blk.statements) |s| if (stmtHasBreakOrContinue(s)) return true;
            if (blk.trailing_expr) |te| return exprHasBreakOrContinue(te);
            return false;
        },
        .if_expr => |i| exprHasBreakOrContinue(i.condition) or exprHasBreakOrContinue(i.then_branch) or
            (if (i.else_branch) |e| exprHasBreakOrContinue(e) else false),
        .binary => |b| exprHasBreakOrContinue(b.left) or exprHasBreakOrContinue(b.right),
        .unary => |u| exprHasBreakOrContinue(u.operand),
        .call => |c| blk: {
            if (exprHasBreakOrContinue(c.callee)) break :blk true;
            for (c.arguments) |a| if (exprHasBreakOrContinue(a)) break :blk true;
            break :blk false;
        },
        .match => |m| blk: {
            if (exprHasBreakOrContinue(m.scrutinee)) break :blk true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (exprHasBreakOrContinue(g)) break :blk true;
                if (exprHasBreakOrContinue(arm.body)) break :blk true;
            }
            break :blk false;
        },
        .lambda => false, // 独立作用域，break/continue 不穿透
        else => false,
    };
}

fn stmtHasBreakOrContinue(stmt: *const ast.Stmt) bool {
    return switch (stmt.*) {
        .break_stmt, .continue_stmt => true,
        .expression => |e| exprHasBreakOrContinue(e.expr),
        .val_decl => |v| exprHasBreakOrContinue(v.value),
        .var_decl => |v| exprHasBreakOrContinue(v.value),
        .assignment => |a| exprHasBreakOrContinue(a.target) or exprHasBreakOrContinue(a.value),
        .return_stmt => |r| if (r.value) |v| exprHasBreakOrContinue(v) else false,
        .field_assignment => |f| exprHasBreakOrContinue(f.object) or exprHasBreakOrContinue(f.value),
        .compound_assignment => |c| exprHasBreakOrContinue(c.target) or exprHasBreakOrContinue(c.value),
        .defer_stmt => |d| exprHasBreakOrContinue(d.expr),
        .throw_stmt => |t| exprHasBreakOrContinue(t.expr),
        .for_stmt => |f| exprHasBreakOrContinue(f.iterable) or exprHasBreakOrContinue(f.body),
        .while_stmt => |w| exprHasBreakOrContinue(w.condition) or exprHasBreakOrContinue(w.body),
        .loop_stmt => |l| exprHasBreakOrContinue(l.body),
    };
}

/// 循环展开：常量 range 小循环（1..=16 次，body 小，无 break/continue）编译期展开。
/// 返回 true 表示已展开（调用方跳过正常循环 emit）；false 表示不可展开。
fn tryUnrollFor(
    fc: *RegFnCompiler,
    stmt: *const ast.Stmt,
    fs: anytype,
    loc: ast.SourceLocation,
) !bool {
    const m = fc.module orelse return false;
    // 查询循环大小
    const li = m.loopInfo(stmt) orelse return false;
    if (!li.is_small) return false;
    // iterable 必须是 range 表达式（binary .range / .range_inclusive）
    if (fs.iterable.* != .binary) return false;
    const bin = fs.iterable.binary;
    const inclusive = (bin.op == .range_inclusive);
    if (bin.op != .range and bin.op != .range_inclusive) return false;
    // 查询 range 上下界（ConstProp）
    const start_cv = m.constValue(bin.left) orelse return false;
    const end_cv = m.constValue(bin.right) orelse return false;
    if (start_cv != .int_val or end_cv != .int_val) return false;
    const start = start_cv.int_val;
    const end = end_cv.int_val;
    const count = if (inclusive) end - start + 1 else end - start;
    if (count < 1 or count > 16) return false;
    // 检查无 break/continue
    if (exprHasBreakOrContinue(fs.body)) return false;
    // 展开循环：为每次迭代声明循环变量并 emit body
    var i = start;
    const end_iter = if (inclusive) end + 1 else end;
    while (i < end_iter) : (i += 1) {
        // 声明循环变量并加载当前迭代值
        _ = try fc.declareLocal(fs.name, false, false, null);
        const var_vreg = fc.resolveLocal(fs.name).?;
        const k = try fc.chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i128, i)));
        const tmp = fc.newTemp();
        try fc.chunk.writeABx(.load_const, @intCast(tmp & 0xFF), k, loc);
        try fc.chunk.writeABC(.move, @intCast(var_vreg & 0xFF), @intCast(tmp & 0xFF), 0, loc);
        // emit body（结果丢弃）
        _ = try emitExpr(fc, fs.body);
    }
    return true;
}

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
        .binary => |bin| blk: {
            // LICM: 若本表达式已外提到循环前寄存器，直接返回该寄存器
            if (fc.hoisted_regs.get(expr)) |hvreg| break :blk hvreg;
            // CSE: 若本表达式是 redundant，返回其 canonical 的已缓存寄存器
            if (fc.module) |m| {
                if (m.cseCanonical(expr)) |canonical| {
                    if (fc.cse_regs.get(canonical)) |cvreg| break :blk cvreg;
                    // canonical 尚未 emit（顺序问题）→ 回退到正常 emit
                }
            }
            // 常量折叠：ConstProp 已确定整个 binary 为常量 → 直接 load_const
            if (fc.module) |m| {
                if (m.constValue(expr)) |cv| {
                    if (constValueToValue(cv)) |v| {
                        const dst = fc.newTemp();
                        const k = try fc.chunk.addConstant(v);
                        try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
                        // CSE: 若本表达式是 canonical，缓存寄存器供后续 redundant 读取
                        if (m.isCseCanonical(expr)) try fc.cse_regs.put(fc.allocator, expr, dst);
                        break :blk dst;
                    }
                }
            }
            const dst = try emitBinary(fc, bin.op, bin.left, bin.right, loc);
            // CSE: 若本表达式是 canonical，缓存寄存器供后续 redundant 读取
            if (fc.module) |m| {
                if (m.isCseCanonical(expr)) try fc.cse_regs.put(fc.allocator, expr, dst);
            }
            break :blk dst;
        },
        .unary => |un| try emitUnary(fc, un.op, un.operand, loc),
        .if_expr => |ie| try emitIf(fc, ie.condition, ie.then_branch, ie.else_branch, loc),
        .block => |blk| try emitBlock(fc, blk.statements, blk.trailing_expr, loc),
        .call => |c| try emitCall(fc, c.callee, c.arguments, loc),
        .lambda => |lam| try emitLambda(fc, lam, loc),
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
        .record_extend => |re| try emitRecordExtend(fc, re.base, re.updates, loc),
        .safe_access => |sa| try emitSafeAccess(fc, sa.object, sa.field, loc),
        .safe_method_call => |smc| try emitSafeMethodCall(fc, smc.object, smc.method, smc.arguments, loc),
        .select => |sel| try emitSelect(fc, sel.arms, loc),
        .assignment_expr => |ae| blk: {
            // defer 中的赋值包装为 assignment_expr；作为表达式求值，返回 unit
            try emitAssignment(fc, ae.target, ae.value, loc);
            const dst = fc.newTemp();
            try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
            break :blk dst;
        },
        .inline_trait_value => |itv| try emitInlineTraitValue(fc, itv.methods, loc),
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

/// 内建数值类型枚举：替代字符串名列表，避免大小写/前缀判断。
pub const NumericType = enum {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f128,

    pub fn isFloat(self: NumericType) bool {
        return switch (self) {
            .f16, .f32, .f64, .f128 => true,
            else => false,
        };
    }
    pub fn isUnsigned(self: NumericType) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .u128 => true,
            else => false,
        };
    }
    pub fn isSignedInt(self: NumericType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            else => false,
        };
    }
};

/// builtin 数值类型名 → NumericType 枚举（精确匹配，无前缀判断）。
fn parseNumericType(name: []const u8) ?NumericType {
    // 整数类型（按长度分组减少比较次数）
    switch (name.len) {
        2 => {
            if (name[0] == 'i' and name[1] == '8') return .i8;
            if (name[0] == 'u' and name[1] == '8') return .u8;
        },
        3 => {
            if (name[0] == 'i' and name[1] == '1' and name[2] == '6') return .i16;
            if (name[0] == 'u' and name[1] == '1' and name[2] == '6') return .u16;
            if (name[0] == 'i' and name[1] == '3' and name[2] == '2') return .i32;
            if (name[0] == 'u' and name[1] == '3' and name[2] == '2') return .u32;
            if (name[0] == 'i' and name[1] == '6' and name[2] == '4') return .i64;
            if (name[0] == 'u' and name[1] == '6' and name[2] == '4') return .u64;
            if (name[0] == 'f' and name[1] == '1' and name[2] == '6') return .f16;
            if (name[0] == 'f' and name[1] == '3' and name[2] == '2') return .f32;
            if (name[0] == 'f' and name[1] == '6' and name[2] == '4') return .f64;
        },
        4 => {
            if (name[0] == 'i' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .i128;
            if (name[0] == 'u' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .u128;
            if (name[0] == 'f' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .f128;
        },
        else => {},
    }
    return null;
}

/// builtin 数值类型名判定（委托 parseNumericType）。
fn isBuiltinNumericType(name: []const u8) bool {
    return parseNumericType(name) != null;
}

/// 从 TypeNode 提取 builtin 数值类型名（用于 ADT 字段类型注解）
fn builtinNumericTypeOf(ty: *const ast.TypeNode) ?[]const u8 {
    return switch (ty.*) {
        .named => |n| if (isBuiltinNumericType(n.name)) n.name else null,
        else => null,
    };
}

/// 推断表达式的 builtin 类型名（int/float/bool/char literal + identifier 可推断；
/// binary/unary 算术递归左操作数；其他返回 null）。用于 caller-side coerce 判定。
fn exprBuiltinType(fc: *RegFnCompiler, expr: *const ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .int_literal => |il| blk: {
            if (il.suffix) |s| break :blk s;
            const parsed = shared.parse_mod.parseIntSoftware(il.raw) orelse break :blk null;
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
    const v = shared.parse_mod.parseIntLiteral(fc.allocator, il) catch return error.Unsupported;
    if (v == null) return error.Unsupported;
    const k = try fc.chunk.addConstant(v.?);
    try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
    return dst;
}

fn emitFloatLiteral(fc: *RegFnCompiler, fl: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp();
    const v = shared.parse_mod.parseFloatLiteral(fc.allocator, fl) catch return error.Unsupported;
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
    // 0. 内联参数：被内联函数的形参直接返回绑定寄存器（最高优先级，遮蔽外层同名）
    if (fc.inline_param_regs.get(name)) |vreg| return vreg;
    // 1. 查 local
    if (fc.resolveLocal(name)) |vreg| {
        return vreg;
    }
    // 2. 递归解析 upvalue（去重 + 沿 enclosing 链查找）
    if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
        const dst = fc.newTemp();
        try fc.chunk.writeABC(.get_upvalue, @intCast(dst & 0xFF), uv_idx, 0, loc);
        return dst;
    }
    // 3. 查顶层函数 → 包成 closure
    if (fc.module) |m| {
        // 3a. 查全局变量 → load_global
        if (m.lookupGlobal(name)) |gidx| {
            const dst = fc.newTemp();
            try fc.chunk.writeABx(.load_global, @intCast(dst & 0xFF), gidx, loc);
            return dst;
        }
        if (m.lookupFn(name)) |func_idx| {
            const dst = fc.newTemp();
            try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), func_idx, loc);
            return dst;
        }
        // 4. 查 ADT 构造器
        if (m.lookupCtor(name)) |ce| {
            const dst = fc.newTemp();
            if (ce.arity == 0) {
                // nullary 构造器 → 直接 make_adt
                try fc.chunk.writeABC(.make_adt, @intCast(dst & 0xFF), @intCast(ce.idx & 0xFF), 0, loc);
            } else {
                // 有参构造器 → 合成包装函数 + closure
                const wrap_idx = try m.regCtorWrapperFunc(ce.idx, ce.arity, name, loc);
                try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), wrap_idx, loc);
            }
            return dst;
        }
        // 5. 查 newtype 构造器
        if (m.lookupNewtype(name)) |ce| {
            const dst = fc.newTemp();
            const wrap_idx = try m.regNewtypeWrapperFunc(ce.idx, name, loc);
            try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), wrap_idx, loc);
            return dst;
        }
        // 6. 查模块表 → 构造模块值（trait_value，含导出函数 + 子模块）
        if (m.lookupModule(name)) |me| {
            return try emitModuleValue(fc, me, loc);
        }
    }
    return error.Unsupported;
}

/// 构造模块值：生成 make_trait 指令，把模块的导出函数（作为 closure）+
/// 子模块（作为嵌套 trait_value）打包成一个 trait_value。
/// make_trait 编码：A=dst, B=count, methods 在 R[A+1..A+B*2]（name_const, value 交替）
fn emitModuleValue(fc: *RegFnCompiler, me: ModuleEntry, loc: ast.SourceLocation) !reg_alloc.VReg {
    const m = fc.module orelse return error.Unsupported;
    const dst = fc.newTemp();

    // 方法数 = 导出函数 + 子模块
    const fn_count = me.exported_fns.len;
    const sub_count = me.submodules.len;
    const total: u8 = @intCast(fn_count + sub_count);
    if (total == 0 or total > 127) return error.Unsupported;

    // 为每个方法预留两个寄存器（name_const + value），位于 dst+1..dst+total*2
    var idx: u8 = 0;
    while (idx < total * 2) : (idx += 1) _ = fc.newTemp();

    // 导出函数：name_const + closure
    for (me.exported_fns, 0..) |fn_name, i| {
        const name_reg: u8 = @intCast(dst + 1 + i * 2);
        const val_reg: u8 = @intCast(dst + 2 + i * 2);
        const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, fn_name));
        try fc.chunk.writeABx(.load_const, name_reg, name_k, loc);
        // 查函数索引 → closure
        if (m.lookupFn(fn_name)) |func_idx| {
            try fc.chunk.writeABx(.closure, val_reg, func_idx, loc);
        } else {
            return error.Unsupported;
        }
    }

    // 子模块：name_const + 递归构造子模块的 trait_value
    for (me.submodules, 0..) |sub_name, i| {
        const name_reg: u8 = @intCast(dst + 1 + (fn_count + i) * 2);
        const val_reg: u8 = @intCast(dst + 2 + (fn_count + i) * 2);
        const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, sub_name));
        try fc.chunk.writeABx(.load_const, name_reg, name_k, loc);
        // 子模块也是模块值：查 module_map 取其 ModuleEntry 递归构造
        if (m.lookupModule(sub_name)) |sub_me| {
            const sub_vreg = try emitModuleValue(fc, sub_me, loc);
            try fc.chunk.writeABC(.move, val_reg, @intCast(sub_vreg & 0xFF), 0, loc);
        } else {
            // 子模块未登记 → 加载 null（运行时 get_field 返回 null）
            try fc.chunk.writeABC(.load_null, val_reg, 0, 0, loc);
        }
    }

    // make_trait A=dst B=count C=0
    try fc.chunk.writeABC(.make_trait, @intCast(dst & 0xFF), total, 0, loc);
    return dst;
}

/// 代数简化 + 强度削减：x+0→x, x-0→x, x*1→x, x/1→x, x*0→0（int）,
/// x%2^k→x&(2^k-1)（仅无符号整数）。命中返回 VReg，否则 null。
fn tryEmitAlgebraicSimplify(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !?reg_alloc.VReg {
    const m = fc.module orelse return null;
    // 右操作数为整数常量时的简化
    if (m.constValue(right)) |rv| {
        if (rv == .int_val) {
            const rval = rv.int_val;
            // x + 0 → x, x - 0 → x（int/float 均成立）
            if (rval == 0 and (op == .add or op == .sub)) {
                return try emitExpr(fc, left);
            }
            // x * 1 → x, x / 1 → x（int/float 均成立）
            if (rval == 1 and (op == .mul or op == .div)) {
                return try emitExpr(fc, left);
            }
            // x * 0 → 0（仅整数安全；float 的 inf*0=NaN）
            if (rval == 0 and op == .mul) {
                if (exprBuiltinType(fc, left)) |lt| {
                    if (parseNumericType(lt)) |nt| {
                        if (!nt.isFloat()) {
                            const dst = fc.newTemp();
                            const k = try fc.chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i128, 0)));
                            try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
                            return dst;
                        }
                    }
                }
            }
            // x % 2^k → x & (2^k - 1)（强度削减，仅无符号整数安全）
            if (op == .mod and rval > 0 and isPowerOfTwo(rval)) {
                if (exprBuiltinType(fc, left)) |lt| {
                    if (parseNumericType(lt)) |nt| {
                        if (nt.isUnsigned()) {
                            const mask = rval - 1;
                            const left_vreg = try emitExpr(fc, left);
                            const dst = fc.newTemp();
                            const mask_k = try fc.chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i128, mask)));
                            const mask_reg = fc.newTemp();
                            try fc.chunk.writeABx(.load_const, @intCast(mask_reg & 0xFF), mask_k, loc);
                            try fc.chunk.writeABC(.bit_and, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(mask_reg & 0xFF), loc);
                            return dst;
                        }
                    }
                }
            }
        }
    }
    return null;
}

fn isPowerOfTwo(n: i128) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

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

    // 代数简化 + 强度削减
    if (try tryEmitAlgebraicSimplify(fc, op, left, right, loc)) |dst| return dst;

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
    const range_op: reg_opcode.Op = if (op == .range_inclusive) .make_range_incl else .make_range;
    try fc.chunk.writeABC(range_op, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
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
    // BranchReach: 编译期已知条件 → 只发活跃分支
    if (fc.module) |m| {
        if (m.branchInfo(condition)) |bi| {
            switch (bi) {
                .always_true => return try emitExpr(fc, then_branch),
                .always_false => {
                    if (else_branch) |eb| return try emitExpr(fc, eb);
                    const dst = fc.newTemp();
                    try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
                    return dst;
                },
                .runtime => {},
            }
        }
    }

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

/// 参数类型注解为 builtin 数值类型且与实参推断类型不符时，发射 .coerce 指令。
/// 返回（可能 coerce 后的）arg vreg。param_type 为 null 或非数值类型时原样返回。
fn coerceArgIfNeeded(fc: *RegFnCompiler, arg: *const ast.Expr, arg_vreg: reg_alloc.VReg, param_type: ?[]const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
    if (param_type) |ptn| {
        if (isBuiltinNumericType(ptn)) {
            const at = exprBuiltinType(fc, arg);
            if (at == null or !std.mem.eql(u8, at.?, ptn)) {
                const coerced = fc.newTemp();
                const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, ptn));
                try fc.chunk.writeABC(.coerce, @intCast(coerced & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
                return coerced;
            }
        }
    }
    return arg_vreg;
}

/// 从 func_idx 获取 param_types（无 module 或越界时返回空切片）
fn funcParamTypes(fc: *RegFnCompiler, func_idx: ?u16) []const ?[]const u8 {
    if (func_idx) |fidx| {
        if (fc.module) |m| {
            if (fidx < m.program.functions.items.len) {
                return m.program.functions.items[fidx].param_types;
            }
        }
    }
    return &.{};
}

fn emitCall(fc: *RegFnCompiler, callee: *const ast.Expr, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    // 命名函数调用：通过 ModuleCompiler 查找 func_idx
    if (callee.* == .identifier) {
        const name = callee.identifier.name;
        // 内联参数调用：被内联函数的形参（可能是闭包）→ call_value
        if (fc.inline_param_regs.get(name)) |vreg| {
            const dst = fc.newTemp();
            for (0..arguments.len) |_| _ = fc.newTemp();
            try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(vreg & 0xFF), 0, loc);
            for (arguments, 0..) |arg, i| {
                const arg_vreg = try emitExpr(fc, arg);
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
            }
            try fc.chunk.writeABC(.call_value, @intCast(dst & 0xFF), 0, @intCast(arguments.len & 0xFF), loc);
            return dst;
        }
        // 闭包值调用：local → call_value（须在 native/ctor/fn 查找之前，local 可遮蔽同名函数）
        if (fc.resolveLocal(name)) |local_vreg| {
            const dst = fc.newTemp();
            for (0..arguments.len) |_| _ = fc.newTemp();
            try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(local_vreg & 0xFF), 0, loc);
            // caller-side coerce：闭包 local 可能持 func_idx，用其 param_types 做数值类型转换
            const param_types = funcParamTypes(fc, fc.findLocalFuncIdx(name));
            for (arguments, 0..) |arg, i| {
                var arg_vreg = try emitExpr(fc, arg);
                if (i < param_types.len) {
                    arg_vreg = try coerceArgIfNeeded(fc, arg, arg_vreg, param_types[i], loc);
                }
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
            }
            try fc.chunk.writeABC(.call_value, @intCast(dst & 0xFF), 0, @intCast(arguments.len & 0xFF), loc);
            return dst;
        }
        // 闭包值调用：upvalue → call_value
        if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
            const dst = fc.newTemp();
            for (0..arguments.len) |_| _ = fc.newTemp();
            try fc.chunk.writeABC(.get_upvalue, @intCast(dst & 0xFF), uv_idx, 0, loc);
            // caller-side coerce：闭包 upvalue 可能持 func_idx，用其 param_types 做数值类型转换
            const param_types = funcParamTypes(fc, fc.findUpvalueFuncIdx(name));
            for (arguments, 0..) |arg, i| {
                var arg_vreg = try emitExpr(fc, arg);
                if (i < param_types.len) {
                    arg_vreg = try coerceArgIfNeeded(fc, arg, arg_vreg, param_types[i], loc);
                }
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
            }
            try fc.chunk.writeABC(.call_value, @intCast(dst & 0xFF), 0, @intCast(arguments.len & 0xFF), loc);
            return dst;
        }
        const dst = fc.newTemp();
        // 预留参数寄存器 dst+1..dst+argc，避免后续 emitExpr 的 temp 覆盖
        for (0..arguments.len) |_| _ = fc.newTemp();
        // 内建函数（println/print 等）：先求值参数再 CALL_NATIVE
        if (shared.native_mod.Native.fromName(name)) |nat| {
            for (arguments, 0..) |arg, i| {
                const arg_vreg = try emitExpr(fc, arg);
                try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
            }
            try fc.chunk.writeABC(.call_native, @intCast(dst & 0xFF), @intFromEnum(nat), @intCast(arguments.len & 0xFF), loc);
            return dst;
        }
        if (fc.module) |m| {
            // ADT 构造器裸名调用 → make_adt
            if (m.lookupCtor(name)) |ce| {
                if (ce.arity == arguments.len) {
                    for (arguments, 0..) |arg, i| {
                        const arg_vreg = try emitExpr(fc, arg);
                        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
                    }
                    try fc.chunk.writeABC(.make_adt, @intCast(dst & 0xFF), @intCast(ce.idx & 0xFF), @intCast(arguments.len & 0xFF), loc);
                    return dst;
                }
            }
            // newtype 构造器裸名调用 → make_newtype (iABC: A=dst, B=src, C=nt_idx)
            if (m.lookupNewtype(name)) |ne| {
                if (arguments.len == 1) {
                    const arg_vreg = try emitExpr(fc, arguments[0]);
                    try fc.chunk.writeABC(.make_newtype, @intCast(dst & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(ne.idx & 0xFF), loc);
                    return dst;
                }
            }
            // error newtype 构造器裸名调用 → make_error (iABC: A=dst, B=src, C=err_idx)
            if (m.lookupError(name)) |ee| {
                if (arguments.len == 1) {
                    const arg_vreg = try emitExpr(fc, arguments[0]);
                    try fc.chunk.writeABC(.make_error, @intCast(dst & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(ee.idx & 0xFF), loc);
                    return dst;
                }
            }
        }
        // 从 ModuleCompiler 查找函数索引
        const func_idx: u16 = if (fc.module) |m|
            (m.lookupFn(name) orelse return error.Unsupported)
        else
            return error.Unsupported;
        // 函数内联：小函数（arity ≤ 3, body ≤ 8 节点, 无控制流, 非递归）直接内联到调用点。
        // async 函数不能内联（需 spawn 语义保留 Spawn<T> 句柄）。
        // 注：dst 和 arg 寄存器已预分配，内联时忽略它们（VReg 空洞由分配器处理）。
        if (fc.module) |m| {
            const is_async = m.program.functions.items[func_idx].is_async;
            if (!is_async) {
                if (m.fn_asts.get(name)) |entry| {
                    if (try tryEmitInlineCall(fc, name, arguments, entry, loc)) |inline_dst| {
                        return inline_dst;
                    }
                }
            }
        }
        // async 函数：closure（零捕获，顶层函数无 upvalue）+ args + spawn → Spawn<T>
        if (fc.module) |m| {
            if (m.program.functions.items[func_idx].is_async) {
                const closure_reg = fc.newTemp();
                for (0..arguments.len) |_| _ = fc.newTemp(); // arg regs at closure_reg+1..
                try fc.chunk.writeABx(.closure, @intCast(closure_reg & 0xFF), func_idx, loc);
                // caller-side coerce（与普通 call 一致）
                const param_types_async: []const ?[]const u8 = m.program.functions.items[func_idx].param_types;
                for (arguments, 0..) |arg, i| {
                    var arg_vreg = try emitExpr(fc, arg);
                    if (i < param_types_async.len) if (param_types_async[i]) |ptn| {
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
                    try fc.chunk.writeABC(.move, @intCast((closure_reg + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
                }
                // SPAWN A B C — A=dst(spawn_val), B=closure_reg, C=argc；args 在 R[B+1..B+C]
                try fc.chunk.writeABC(.spawn, @intCast(dst & 0xFF), @intCast(closure_reg & 0xFF), @intCast(arguments.len & 0xFF), loc);
                return dst;
            }
        }
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
        // 纯函数 memoization：发 call_memoized（约定与 call 相同：A=dst, Bx=func_idx），
        // VM 据 callee.memo_slot 决定是否查/写缓存。
        const use_memo = if (fc.module) |m| (m.getOrAssignMemoSlot(name) != null) else false;
        try fc.chunk.writeABx(if (use_memo) .call_memoized else .call, @intCast(dst & 0xFF), func_idx, loc);
        return dst;
    }
    // callee 为非 identifier 的表达式 → CALL_VALUE
    const callee_vreg = try emitExpr(fc, callee);
    const dst = fc.newTemp();
    // 预留 callee + 参数寄存器 dst..dst+argc（dst 存 callee，dst+1.. 存 args）
    for (0..arguments.len) |_| _ = fc.newTemp();
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
    // 预留参数寄存器 dst+1..dst+argc
    for (0..arguments.len) |_| _ = fc.newTemp();
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
    // 预留元素寄存器 dst+1..dst+n，避免后续 emitExpr 的 temp 覆盖
    for (0..elements.len) |_| _ = fc.newTemp();
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
    // 预留字段寄存器
    for (0..fields.len) |_| _ = fc.newTemp();
    for (fields, 0..) |field, i| {
        const val_vreg = try emitExpr(fc, field.value);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
    }
    // 收集字段名并登记 shape
    const m = fc.module orelse return error.Unsupported;
    const names = fc.allocator.alloc([]const u8, fields.len) catch return error.OutOfMemory;
    defer fc.allocator.free(names);
    for (fields, 0..) |field, i| names[i] = field.name;
    const shape_idx: u16 = blk: {
        const idx: u16 = @intCast(m.program.record_shapes.items.len);
        const fn_copy = m.program.allocator.dupe([]const u8, names) catch return error.OutOfMemory;
        m.program.record_shapes.append(m.allocator, .{ .field_names = fn_copy }) catch return error.OutOfMemory;
        break :blk idx;
    };
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

// ── select ──

/// 从 recv arm 的 channel_expr 发射 channel 操作数到寄存器，返回 vreg。
/// `ch.recv()` 取 object（ch），否则直接求值。镜像栈式 emitChannelOperand。
fn emitChannelOperand(fc: *RegFnCompiler, channel_expr: *const ast.Expr) !reg_alloc.VReg {
    if (channel_expr.* == .method_call) {
        const mc = channel_expr.method_call;
        if (method_mod.MethodId.fromName(mc.method) == .recv) {
            return try emitExpr(fc, mc.object);
        }
    }
    return try emitExpr(fc, channel_expr);
}

/// 编译 select：① poll 各 recv arm（非阻塞），首个就绪绑定+执行 body；
/// ② 无就绪则首个 timeout arm body；③ 无 timeout 则阻塞 recv 首个 recv arm。
/// 镜像栈式 emitSelect 三段式。
fn emitSelect(fc: *RegFnCompiler, arms: []const ast.SelectArm, loc: ast.SourceLocation) !reg_alloc.VReg {
    const dst = fc.newTemp(); // select 结果寄存器
    var end_jumps = std.ArrayListUnmanaged(usize).empty;
    defer end_jumps.deinit(fc.allocator);

    // ① poll 各 recv arm
    for (arms) |arm| {
        switch (arm) {
            .receive => |ra| {
                const ch_vreg = try emitChannelOperand(fc, ra.channel_expr);
                const val_dst = fc.newTemp(); // value
                _ = fc.newTemp(); // flag (val_dst+1)
                // TRY_RECV A B — R[A]=value, R[A+1]=flag；B=channel
                try fc.chunk.writeABC(.try_recv, @intCast(val_dst & 0xFF), @intCast(ch_vreg & 0xFF), 0, ra.location);
                const not_ready = try fc.chunk.emitJump(.jump_if_false, @intCast((val_dst + 1) & 0xFF), ra.location);
                // 就绪：绑定/丢弃 value，执行 body
                if (ra.binding) |bname| {
                    _ = try fc.declareLocal(bname, false, false, null);
                    const local_vreg = fc.resolveLocal(bname).?;
                    try fc.chunk.writeABC(.move, @intCast(local_vreg & 0xFF), @intCast(val_dst & 0xFF), 0, ra.location);
                }
                const body_vreg = try emitExpr(fc, ra.body);
                try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, ra.location);
                const ej = try fc.chunk.emitJump(.jump, 0, ra.location);
                try end_jumps.append(fc.allocator, ej);
                // 未就绪落点
                fc.chunk.patchJump(not_ready, fc.chunk.here());
            },
            .timeout => {},
        }
    }

    // ② 无就绪：首个 timeout arm 的 body
    var has_timeout = false;
    for (arms) |arm| {
        if (arm == .timeout) {
            _ = try emitExpr(fc, arm.timeout.duration); // 求值并丢弃
            const body_vreg = try emitExpr(fc, arm.timeout.body);
            try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, arm.timeout.location);
            has_timeout = true;
            break;
        }
    }

    // ③ 无 timeout：阻塞 recv 首个 recv arm
    if (!has_timeout) {
        for (arms) |arm| {
            if (arm == .receive) {
                const ra = arm.receive;
                const ch_vreg = try emitChannelOperand(fc, ra.channel_expr);
                const val_dst = fc.newTemp();
                // RECV A B — R[A]=recv(R[B])
                try fc.chunk.writeABC(.recv, @intCast(val_dst & 0xFF), @intCast(ch_vreg & 0xFF), 0, ra.location);
                if (ra.binding) |bname| {
                    _ = try fc.declareLocal(bname, false, false, null);
                    const local_vreg = fc.resolveLocal(bname).?;
                    try fc.chunk.writeABC(.move, @intCast(local_vreg & 0xFF), @intCast(val_dst & 0xFF), 0, ra.location);
                }
                const body_vreg = try emitExpr(fc, ra.body);
                try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, ra.location);
                break;
            }
        }
    }

    // patch all end jumps
    for (end_jumps.items) |ej| fc.chunk.patchJump(ej, fc.chunk.here());
    _ = loc;
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
    // 预留 part 寄存器
    for (0..parts.len) |_| _ = fc.newTemp();
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
    const tname = paramTypeName(target_type) orelse "";
    const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, tname));
    try fc.chunk.writeABC(.cast, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
    return dst;
}

// ── record_extend ──

fn emitRecordExtend(fc: *RegFnCompiler, base_expr: *const ast.Expr, updates: []ast.RecordFieldExpr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const base_vreg = try emitExpr(fc, base_expr);
    // 先 record_extend 复制 base record 到 dst（深拷贝，不影响源）
    const dst = fc.newTemp();
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(base_vreg & 0xFF), 0, loc);
    try fc.chunk.writeABC(.record_extend, @intCast(dst & 0xFF), 0, 0, loc);
    // 对每个更新字段发 set_field：先求值 val 到临时，再 set_field
    for (updates) |field| {
        const val_vreg = try emitExpr(fc, field.value);
        const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field.name));
        const tmp = fc.newTemp();
        try fc.chunk.writeABC(.move, @intCast(tmp & 0xFF), @intCast(dst & 0xFF), 0, loc);
        try fc.chunk.writeABC(.set_field, @intCast(tmp & 0xFF), @intCast(name_k & 0xFF), @intCast(val_vreg & 0xFF), loc);
        try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(tmp & 0xFF), 0, loc);
    }
    return dst;
}

// ── safe_access (expr?.field) ──

fn emitSafeAccess(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
    const obj_vreg = try emitExpr(fc, object);
    const dst = fc.newTemp();
    // move dst, obj（若 obj 非 null 则 get_field，否则保持 null）
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
    // jump_if_not_null dst, skip → 若非 null 则继续 get_field
    const skip = try fc.chunk.emitJump(.jump_if_not_null, @intCast(dst & 0xFF), loc);
    // null 路径：load_null dst（保持 null）
    try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
    const end = try fc.chunk.emitJump(.jump, 0, loc);
    // 非 null 路径：get_field
    fc.chunk.patchJump(skip, fc.chunk.here());
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
    try fc.chunk.writeABC(.get_field, @intCast(dst & 0xFF), @intCast(dst & 0xFF), @intCast(name_k & 0xFF), loc);
    fc.chunk.patchJump(end, fc.chunk.here());
    return dst;
}

// ── safe_method_call (expr?.method(args)) ──

fn emitSafeMethodCall(fc: *RegFnCompiler, object: *const ast.Expr, method: []const u8, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
    const obj_vreg = try emitExpr(fc, object);
    const dst = fc.newTemp();
    // move dst, obj
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
    // jump_if_not_null dst, skip → 若非 null 则继续 method call
    const skip = try fc.chunk.emitJump(.jump_if_not_null, @intCast(dst & 0xFF), loc);
    // null 路径：load_null dst
    try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
    const end = try fc.chunk.emitJump(.jump, 0, loc);
    // 非 null 路径：call_method
    fc.chunk.patchJump(skip, fc.chunk.here());
    // 预留参数寄存器 dst+1..dst+argc
    for (0..arguments.len) |_| _ = fc.newTemp();
    for (arguments, 0..) |arg, i| {
        const arg_vreg = try emitExpr(fc, arg);
        try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
    }
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, method));
    try fc.chunk.writeABC(.call_method, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(arguments.len), loc);
    fc.chunk.patchJump(end, fc.chunk.here());
    return dst;
}

// ── match ──

fn emitMatch(fc: *RegFnCompiler, scrutinee: *const ast.Expr, arms: []ast.MatchArm, loc: ast.SourceLocation) !reg_alloc.VReg {
    const scrut_vreg = try emitExpr(fc, scrutinee);
    const dst = fc.newTemp();
    var end_jumps = std.ArrayListUnmanaged(usize).empty;
    defer end_jumps.deinit(fc.allocator);

    for (arms) |arm| {
        // 记录 arm 开始时的 local 数量（arm 结束时弹回）
        const arm_base = fc.locals.items.len;
        var fail_jumps = std.ArrayListUnmanaged(usize).empty;
        defer fail_jumps.deinit(fc.allocator);

        // 模式测试：不匹配则收集 fail_jumps
        try emitPatternTest(fc, arm.pattern, scrut_vreg, &fail_jumps, loc);
        // guard 检查
        if (arm.guard) |guard_expr| {
            const guard_vreg = try emitExpr(fc, guard_expr);
            try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(guard_vreg & 0xFF), loc));
        }
        // 匹配 + guard 通过：求值 body
        const body_vreg = try emitExpr(fc, arm.body);
        try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, loc);
        try end_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump, 0, loc));
        // fail 落点
        for (fail_jumps.items) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
        // 弹出 arm 内声明的 local
        fc.locals.shrinkRetainingCapacity(arm_base);
    }
    // 全部不匹配
    try fc.chunk.writeABC(.match_fail, 0, 0, 0, loc);
    // end 落点
    for (end_jumps.items) |ej| fc.chunk.patchJump(ej, fc.chunk.here());
    return dst;
}

fn emitPatternTest(fc: *RegFnCompiler, pat: *const ast.Pattern, scrut_vreg: reg_alloc.VReg, fail_jumps: *std.ArrayListUnmanaged(usize), loc: ast.SourceLocation) CompileError!void {
    switch (pat.*) {
        .wildcard => {},
        .variable => |v| {
            // 先查模块表（ADT 构造器 / newtype / error），命中则按构造器模式处理。
            // 无大小写判断：名字是否为构造器由模块表决定，而非首字符大小写。
            if (fc.module) |m| {
                if (m.lookupCtor(v.name)) |ce| {
                    const test_dst = fc.newTemp();
                    try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                    try fc.chunk.writeABx(.test_ctor, @intCast(test_dst & 0xFF), ce.idx, loc);
                    try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                    return;
                }
                if (m.lookupNewtype(v.name)) |ne| {
                    const test_dst = fc.newTemp();
                    try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                    try fc.chunk.writeABx(.test_newtype, @intCast(test_dst & 0xFF), ne.idx, loc);
                    try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                    return;
                }
            }
            // 内建 Throw 构造器（无参形式）：Ok/Error 通过枚举查找，无大小写推断
            if (RegModuleCompiler.lookupBuiltinThrowCtor(v.name)) |bc| {
                const want_ok: u8 = if (bc == .ok) 1 else 0;
                const test_dst = fc.newTemp();
                try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                try fc.chunk.writeABC(.test_throw, @intCast(test_dst & 0xFF), want_ok, 0, loc);
                try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                return;
            }
            // 变量绑定，恒匹配
            _ = try fc.declareLocal(v.name, false, false, null);
            const local_vreg = fc.resolveLocal(v.name).?;
            try fc.chunk.writeABC(.move, @intCast(local_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
        },
        .literal => |lit| {
            const dst = fc.newTemp();
            const k = try addPatternLiteralConstant(fc, lit);
            try fc.chunk.writeABC(.test_lit, @intCast(dst & 0xFF), @intCast(scrut_vreg & 0xFF), @intCast(k & 0xFF), loc);
            try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(dst & 0xFF), loc));
        },
        .constructor => |ctor| {
            // 内建 Throw 构造器：Ok(v) / Error(e) → test_throw + get_throw_ok/err
            if (RegModuleCompiler.lookupBuiltinThrowCtor(ctor.name)) |bc| {
                if (ctor.patterns.len != 1) return error.Unsupported;
                const want_ok: u8 = if (bc == .ok) 1 else 0;
                const test_dst = fc.newTemp();
                try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                try fc.chunk.writeABC(.test_throw, @intCast(test_dst & 0xFF), want_ok, 0, loc);
                try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                // 解包内值
                const inner_vreg = fc.newTemp();
                const unwrap_op: reg_opcode.Op = if (want_ok == 1) .get_throw_ok else .get_throw_err;
                try fc.chunk.writeABC(unwrap_op, @intCast(inner_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                try emitPatternTest(fc, ctor.patterns[0], inner_vreg, fail_jumps, loc);
                return;
            }
            // ADT 构造器模式：test_ctor(iABx) + 按位置解字段
            if (fc.module) |m| {
                if (m.lookupCtor(ctor.name)) |ce| {
                    const test_dst = fc.newTemp();
                    try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                    try fc.chunk.writeABx(.test_ctor, @intCast(test_dst & 0xFF), ce.idx, loc);
                    try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                    for (ctor.patterns, 0..) |sub, i| {
                        const fld_vreg = fc.newTemp();
                        try fc.chunk.writeABC(.move, @intCast(fld_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                        try fc.chunk.writeABx(.get_adt_field, @intCast(fld_vreg & 0xFF), @intCast(i), loc);
                        try emitPatternTest(fc, sub, fld_vreg, fail_jumps, loc);
                    }
                    return;
                }
                // newtype 模式：test_newtype(iABx) + get_newtype_inner(iABC)
                if (m.lookupNewtype(ctor.name)) |ne| {
                    const test_dst = fc.newTemp();
                    try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                    try fc.chunk.writeABx(.test_newtype, @intCast(test_dst & 0xFF), ne.idx, loc);
                    try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
                    if (ctor.patterns.len >= 1) {
                        const inner_vreg = fc.newTemp();
                        try fc.chunk.writeABC(.get_newtype_inner, @intCast(inner_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
                        try emitPatternTest(fc, ctor.patterns[0], inner_vreg, fail_jumps, loc);
                    }
                    return;
                }
            }
            return error.Unsupported;
        },
        .or_pattern => |or_pat| {
            // or 模式：测试左子模式，若失败则跳到测试右子模式
            // 左子模式的 fail_jumps 需要跳到右子模式的测试点
            var left_fails = std.ArrayListUnmanaged(usize).empty;
            defer left_fails.deinit(fc.allocator);
            try emitPatternTest(fc, or_pat.left, scrut_vreg, &left_fails, loc);
            // 左子模式全部通过 → 跳到 end（匹配成功）
            const success_jump = try fc.chunk.emitJump(.jump, 0, loc);
            // 左子模式失败落点 → 测试右子模式
            for (left_fails.items) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
            try emitPatternTest(fc, or_pat.right, scrut_vreg, fail_jumps, loc);
            // 成功落点
            fc.chunk.patchJump(success_jump, fc.chunk.here());
        },
        .record => |rec| {
            // 记录模式：按名解字段递归绑定
            for (rec.fields) |f| {
                const fld_vreg = fc.newTemp();
                const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, f.name));
                try fc.chunk.writeABC(.get_field, @intCast(fld_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), @intCast(name_k & 0xFF), loc);
                try emitPatternTest(fc, f.pattern, fld_vreg, fail_jumps, loc);
            }
        },
        else => return error.Unsupported,
    }
}

fn addPatternLiteralConstant(fc: *RegFnCompiler, lit: ast.PatternLiteral) !u16 {
    return switch (lit) {
        .int => |raw| blk: {
            const parsed = shared.parse_mod.parseIntSoftware(raw) orelse return error.Unsupported;
            break :blk try fc.chunk.addConstant(value.Value.fromInt(parsed));
        },
        .float => |raw| blk: {
            const parsed = shared.parse_mod.parseFloatSoftware(raw) orelse return error.Unsupported;
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

// ── lambda（闭包编译：子编译器 + upvalue 解析 + closure 发射）──

fn emitLambda(fc: *RegFnCompiler, lam: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
    if (lam.params.len > 254) return error.Unsupported;
    const m = fc.module orelse return error.Unsupported;

    // 提取参数类型名（caller-side coerce 用；字符串借用 AST 生命周期）
    var ptypes: []?[]const u8 = &.{};
    if (lam.params.len > 0) {
        ptypes = m.allocator.alloc(?[]const u8, lam.params.len) catch return error.OutOfMemory;
        for (lam.params, 0..) |p, i| {
            ptypes[i] = paramTypeName(p.type_annotation);
        }
    }

    // 预占位拿 func_idx
    const placeholder_idx: u16 = @intCast(m.program.functions.items.len);
    try m.program.functions.append(m.allocator, .{
        .chunk = reg_chunk.RegChunk.init(m.allocator),
        .arity = @intCast(lam.params.len),
        .name = "<lambda>",
        .param_types = ptypes,
    });

    // 子编译器
    var sub = RegFnCompiler.init(fc.allocator);
    sub.enclosing = fc;
    sub.module = fc.module;
    sub.name = "<lambda>";
    sub.arity = @intCast(lam.params.len);
    defer sub.deinit();

    // 声明参数为局部（占 VReg 0..arity-1）
    for (lam.params) |p| {
        _ = try sub.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
    }

    // 编译 body（尾位置，支持 TCO）
    const body_expr = switch (lam.body) {
        .block => |b| b,
        .expression => |e| e,
    };
    try emitTailExpr(&sub, body_expr, loc);

    // 覆盖占位：移交 chunk + upvalue_specs
    const func = &m.program.functions.items[placeholder_idx];
    func.chunk.deinit();
    func.chunk = sub.chunk;
    func.register_count = @intCast(sub.next_vreg);
    for (sub.upvalues.items) |uv| {
        try func.upvalue_specs.append(m.allocator, .{
            .is_local = uv.is_local,
            .index = uv.index,
        });
    }
    // release_mask
    const nreg_raw: u32 = @intCast(@min(sub.next_vreg, 64));
    if (nreg_raw >= 64) {
        func.release_mask = ~@as(u64, 0);
    } else if (nreg_raw > 0) {
        func.release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
    }

    sub.chunk = reg_chunk.RegChunk.init(fc.allocator); // 防误释放

    // 发 closure 指令
    const dst = fc.newTemp();
    try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), placeholder_idx, loc);
    return dst;
}

/// 内联 Trait 值：trait { fun method(params) { body } ... }
/// 为每个方法编译为独立函数 + closure 指令，然后用 make_trait 组装 TraitValue。
/// 编码：MAKE_TRAIT A B C — A=dst, B=方法数, methods 在 R[A+1..A+B*2]（name_const, closure 交替）
fn emitInlineTraitValue(fc: *RegFnCompiler, methods: []const ast.MethodDecl, loc: ast.SourceLocation) CompileError!reg_alloc.VReg {
    const m = fc.module orelse return error.Unsupported;
    if (methods.len == 0 or methods.len > 127) return error.Unsupported;

    const dst = fc.newTemp();
    // 预留方法槽位：每个方法占 2 个寄存器（name_const, closure）
    const method_base = fc.newTemp(); // 这就是 dst+1（确保连续）
    _ = method_base;
    for (0..methods.len * 2 - 1) |_| _ = fc.newTemp();

    for (methods, 0..) |md, i| {
        if (md.body == null) return error.Unsupported;
        // 1. 方法名常量 → R[A + 1 + i*2]
        const name_vreg = dst + 1 + i * 2;
        const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, md.name));
        try fc.chunk.writeABx(.load_const, @intCast(name_vreg & 0xFF), name_k, loc);

        // 2. 编译方法体为独立函数 + closure → R[A + 1 + i*2 + 1]
        const closure_vreg = dst + 1 + i * 2 + 1;
        if (md.params.len > 254) return error.Unsupported;

        // 预占位拿 func_idx
        const placeholder_idx: u16 = @intCast(m.program.functions.items.len);
        try m.program.functions.append(m.allocator, .{
            .chunk = reg_chunk.RegChunk.init(m.allocator),
            .arity = @intCast(md.params.len),
            .name = md.name,
        });

        // 子编译器
        var sub = RegFnCompiler.init(fc.allocator);
        sub.enclosing = fc;
        sub.module = fc.module;
        sub.name = md.name;
        sub.arity = @intCast(md.params.len);
        defer sub.deinit();

        // 声明参数为局部
        for (md.params) |p| {
            _ = try sub.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
        }

        // 编译 body
        try emitTailExpr(&sub, md.body.?, loc);

        // 覆盖占位
        const func = &m.program.functions.items[placeholder_idx];
        func.chunk.deinit();
        func.chunk = sub.chunk;
        func.register_count = @intCast(sub.next_vreg);
        for (sub.upvalues.items) |uv| {
            try func.upvalue_specs.append(m.allocator, .{
                .is_local = uv.is_local,
                .index = uv.index,
            });
        }
        const nreg_raw: u32 = @intCast(@min(sub.next_vreg, 64));
        if (nreg_raw >= 64) {
            func.release_mask = ~@as(u64, 0);
        } else if (nreg_raw > 0) {
            func.release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
        }
        sub.chunk = reg_chunk.RegChunk.init(fc.allocator);

        // 发 closure 指令
        try fc.chunk.writeABx(.closure, @intCast(closure_vreg & 0xFF), placeholder_idx, loc);
    }

    // MAKE_TRAIT A B C — A=dst, B=count
    try fc.chunk.writeABC(.make_trait, @intCast(dst & 0xFF), @intCast(methods.len & 0xFF), 0, loc);
    return dst;
}

// ── 语句发射 ──

pub fn emitStmt(fc: *RegFnCompiler, stmt: *const ast.Stmt) CompileError!void {
    const loc = stmt.getLocation();
    switch (stmt.*) {
        .val_decl => |vd| {
            // DCE: dead decl 跳过（RHS 无副作用且 name 未被读取，由 dead_code pass 保证）
            if (fc.module) |m| if (m.isDeadDecl(stmt)) return;
            try emitValDecl(fc, vd.name, vd.type_annotation, vd.value, loc);
        },
        .var_decl => |vd| {
            if (fc.module) |m| if (m.isDeadDecl(stmt)) return;
            try emitVarDecl(fc, vd.name, vd.type_annotation, vd.value, loc);
        },
        .expression => |e| {
            _ = try emitExpr(fc, e.expr);
        },
        .return_stmt => |rs| try emitReturn(fc, rs.value, loc),
        .while_stmt => |ws| {
            try emitHoistedInvariants(fc, stmt);
            try emitWhile(fc, ws.condition, ws.body, loc);
        },
        .for_stmt => |fs| {
            // 循环展开：常量 range 小循环编译期展开
            if (try tryUnrollFor(fc, stmt, fs, loc)) return;
            try emitHoistedInvariants(fc, stmt);
            try emitFor(fc, fs.name, fs.iterable, fs.body, loc);
        },
        .break_stmt => try emitBreak(fc, loc),
        .continue_stmt => try emitContinue(fc, loc),
        .assignment => |a| try emitAssignment(fc, a.target, a.value, loc),
        .field_assignment => |fa| try emitFieldAssignment(fc, fa.object, fa.field, fa.value, loc),
        .compound_assignment => |ca| try emitCompoundAssignment(fc, ca.target, ca.op, ca.value, loc),
        .throw_stmt => |ts| try emitThrow(fc, ts.expr, loc),
        .defer_stmt => |ds| try emitDefer(fc, ds.expr, loc),
        .loop_stmt => |ls| {
            try emitHoistedInvariants(fc, stmt);
            try emitLoop(fc, ls.body, loc);
        },
    }
}

fn emitValDecl(fc: *RegFnCompiler, name: []const u8, type_ann: ?*const ast.TypeNode, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    const tname = paramTypeName(type_ann);
    const m = fc.module;
    // letrec: lambda 值需预声明 local，使 body 内的自引用能解析为 upvalue
    var letrec_vreg: ?reg_alloc.VReg = null;
    var func_idx_before: ?usize = null;
    if (val_expr.* == .lambda and m != null) {
        letrec_vreg = try fc.declareLocal(name, false, false, tname);
        try fc.chunk.writeABC(.load_unit, @intCast(letrec_vreg.? & 0xFF), 0, 0, loc);
        func_idx_before = m.?.program.functions.items.len;
        // 标记 local 持闭包 func_idx（使 body 内自引用 upvalue + 外部调用均能解析 param_types）
        fc.locals.items[fc.locals.items.len - 1].func_idx = @intCast(func_idx_before.?);
    }

    var rhs_vreg = try emitExpr(fc, val_expr);
    if (tname) |ptn| {
        if (isBuiltinNumericType(ptn)) {
            const at = exprBuiltinType(fc, val_expr);
            if (at == null or !std.mem.eql(u8, at.?, ptn)) {
                const coerced = fc.newTemp();
                const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, ptn));
                try fc.chunk.writeABC(.coerce, @intCast(coerced & 0xFF), @intCast(rhs_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
                rhs_vreg = coerced;
            }
        }
    }

    if (letrec_vreg) |lv| {
        // 查找自引用 upvalue 索引（is_local=true 且 index 匹配预声明寄存器）
        const func = &m.?.program.functions.items[func_idx_before.?];
        var uv_idx: u8 = 0;
        var found = false;
        for (func.upvalue_specs.items, 0..) |spec, i| {
            if (spec.is_local and spec.index == @as(u8, @intCast(lv & 0xFF))) {
                uv_idx = @intCast(i);
                found = true;
                break;
            }
        }
        if (found) {
            try fc.chunk.writeABC(.bind_letrec, @intCast(lv & 0xFF), @intCast(rhs_vreg & 0xFF), uv_idx, loc);
        } else {
            try fc.chunk.writeABC(.bind, @intCast(lv & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
        }
    } else {
        _ = try fc.declareLocal(name, false, false, tname);
        const local_vreg = fc.resolveLocal(name).?;
        try fc.chunk.writeABC(.bind, @intCast(local_vreg & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
    }
}

fn emitVarDecl(fc: *RegFnCompiler, name: []const u8, type_ann: ?*const ast.TypeNode, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    const tname = paramTypeName(type_ann);
    const m = fc.module;
    var letrec_vreg: ?reg_alloc.VReg = null;
    var func_idx_before: ?usize = null;
    if (val_expr.* == .lambda and m != null) {
        letrec_vreg = try fc.declareLocal(name, true, false, tname);
        try fc.chunk.writeABC(.load_unit, @intCast(letrec_vreg.? & 0xFF), 0, 0, loc);
        func_idx_before = m.?.program.functions.items.len;
        // 标记 local 持闭包 func_idx（使 body 内自引用 upvalue + 外部调用均能解析 param_types）
        fc.locals.items[fc.locals.items.len - 1].func_idx = @intCast(func_idx_before.?);
    }

    var rhs_vreg = try emitExpr(fc, val_expr);
    if (tname) |ptn| {
        if (isBuiltinNumericType(ptn)) {
            const at = exprBuiltinType(fc, val_expr);
            if (at == null or !std.mem.eql(u8, at.?, ptn)) {
                const coerced = fc.newTemp();
                const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, ptn));
                try fc.chunk.writeABC(.coerce, @intCast(coerced & 0xFF), @intCast(rhs_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
                rhs_vreg = coerced;
            }
        }
    }

    if (letrec_vreg) |lv| {
        const func = &m.?.program.functions.items[func_idx_before.?];
        var uv_idx: u8 = 0;
        var found = false;
        for (func.upvalue_specs.items, 0..) |spec, i| {
            if (spec.is_local and spec.index == @as(u8, @intCast(lv & 0xFF))) {
                uv_idx = @intCast(i);
                found = true;
                break;
            }
        }
        if (found) {
            try fc.chunk.writeABC(.bind_letrec, @intCast(lv & 0xFF), @intCast(rhs_vreg & 0xFF), uv_idx, loc);
        } else {
            try fc.chunk.writeABC(.bind, @intCast(lv & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
        }
    } else {
        _ = try fc.declareLocal(name, true, false, tname);
        const local_vreg = fc.resolveLocal(name).?;
        try fc.chunk.writeABC(.bind, @intCast(local_vreg & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
    }
}

fn emitReturn(fc: *RegFnCompiler, val_expr: ?*const ast.Expr, loc: ast.SourceLocation) !void {
    if (val_expr) |v| {
        // 尾调用优化：如果返回值是顶层函数调用，发射 tail_call
        if (try tryEmitTailCall(fc, v, loc)) return;
        const vreg = try emitExpr(fc, v);
        try fc.chunk.writeABC(.return_op, @intCast(vreg & 0xFF), 0, 0, loc);
    } else {
        try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
    }
}

/// 尝试将 call 表达式发射为 tail_call。合格返回 true，否则返回 false。
fn tryEmitTailCall(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !bool {
    if (expr.* != .call) return false;
    const c = expr.call;
    if (c.callee.* != .identifier) return false;
    const name = c.callee.identifier.name;
    // 被 local 遮蔽 → 非顶层函数
    if (fc.resolveLocal(name) != null) return false;
    const m = fc.module orelse return false;
    const func_idx = m.lookupFn(name) orelse return false;
    const entry = &m.program.functions.items[func_idx];
    if (entry.arity != c.arguments.len) return false;
    if (c.arguments.len > 254) return false; // 寄存器编码限制

    const dst = fc.newTemp();
    // 预留参数寄存器
    for (0..c.arguments.len) |_| _ = fc.newTemp();
    // 求值参数 + caller-side coerce
    const param_types = entry.param_types;
    for (c.arguments, 0..) |arg, i| {
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
    // TAIL_CALL A Bx C — A=dst, Bx=func_idx, C=argc
    try fc.chunk.writeABx(.tail_call, @intCast(dst & 0xFF), func_idx, loc);
    try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc); // 死代码（tail_call 不返回到此处）
    return true;
}

/// 尾位置表达式发射：传播 TCO 机会通过 if/block，否则 emitExpr + return_op。
fn emitTailExpr(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !void {
    switch (expr.*) {
        .call => {
            if (try tryEmitTailCall(fc, expr, loc)) return;
            const vreg = try emitExpr(fc, expr);
            try fc.chunk.writeABC(.return_op, @intCast(vreg & 0xFF), 0, 0, loc);
        },
        .if_expr => |ie| {
            const cond_vreg = try emitExpr(fc, ie.condition);
            const else_jump = try fc.chunk.emitJump(.jump_if_false, @intCast(cond_vreg & 0xFF), loc);
            try emitTailExpr(fc, ie.then_branch, loc);
            const end_jump = try fc.chunk.emitJump(.jump, 0, loc);
            fc.chunk.patchJump(else_jump, fc.chunk.here());
            if (ie.else_branch) |eb| {
                try emitTailExpr(fc, eb, loc);
            } else {
                try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
            }
            fc.chunk.patchJump(end_jump, fc.chunk.here());
        },
        .block => |b| {
            for (b.statements) |stmt| try emitStmt(fc, stmt);
            if (b.trailing_expr) |te| {
                try emitTailExpr(fc, te, loc);
            } else {
                try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
            }
        },
        else => {
            const vreg = try emitExpr(fc, expr);
            try fc.chunk.writeABC(.return_op, @intCast(vreg & 0xFF), 0, 0, loc);
        },
    }
}

/// LICM: 在循环体前 emit 已登记的不变量表达式，结果存入 hoisted_regs。
/// 循环体内引用同一 expr 时直接读已外提的寄存器（见 emitExpr 的 .binary 分支）。
fn emitHoistedInvariants(fc: *RegFnCompiler, loop_stmt: *const ast.Stmt) !void {
    const m = fc.module orelse return;
    const db = m.analysis_db orelse return;
    // 遍历 hoist_table，找出 owner_loop == loop_stmt 的所有 expr
    var it = db.hoist_table.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != loop_stmt) continue;
        const expr = entry.key_ptr.*;
        // 同一循环内多次引用只 emit 一次
        if (fc.hoisted_regs.get(expr) != null) continue;
        const vreg = try emitExpr(fc, expr);
        try fc.hoisted_regs.put(fc.allocator, expr, vreg);
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
    if (target.* == .identifier) {
        const name = target.identifier.name;
        const val_vreg = try emitExpr(fc, val);
        // 内联参数赋值：var 参数已在 tryEmitInlineCall 中拷贝到独立寄存器
        if (fc.inline_param_regs.get(name)) |vreg| {
            try fc.chunk.writeABC(.assign, @intCast(vreg & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
            return;
        }
        if (fc.resolveLocal(name)) |local_vreg| {
            try fc.chunk.writeABC(.assign, @intCast(local_vreg & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
        } else if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
            // set_upvalue A B — Upvalues[B] = R[A]
            try fc.chunk.writeABC(.set_upvalue, @intCast(val_vreg & 0xFF), uv_idx, 0, loc);
        } else if (fc.module) |m| {
            if (m.lookupGlobal(name)) |gidx| {
                try fc.chunk.writeABx(.store_global, @intCast(val_vreg & 0xFF), gidx, loc);
            } else {
                return error.Unsupported;
            }
        } else {
            return error.Unsupported;
        }
    } else if (target.* == .index) {
        // 数组元素赋值：arr[i] = val → set_index A=obj B=index C=val
        const obj_vreg = try emitExpr(fc, target.index.object);
        const idx_vreg = try emitExpr(fc, target.index.index);
        const val_vreg = try emitExpr(fc, val);
        const dst = fc.newTemp();
        try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
        try fc.chunk.writeABC(.set_index, @intCast(dst & 0xFF), @intCast(idx_vreg & 0xFF), @intCast(val_vreg & 0xFF), loc);
    } else {
        return error.Unsupported;
    }
}

fn emitFieldAssignment(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, val: *const ast.Expr, loc: ast.SourceLocation) !void {
    const obj_vreg = try emitExpr(fc, object);
    const val_vreg = try emitExpr(fc, val);
    const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
    const dst = fc.newTemp();
    // set_field A B C — R[A]=obj(读+写), B=name_k, C=val → 先 move obj 到 dst
    try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
    try fc.chunk.writeABC(.set_field, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(val_vreg & 0xFF), loc);
    // 将结果写回 object 的 local（如果 object 是 identifier）
    if (object.* == .identifier) {
        const name = object.identifier.name;
        if (fc.resolveLocal(name)) |local_vreg| {
            try fc.chunk.writeABC(.assign, @intCast(local_vreg & 0xFF), @intCast(dst & 0xFF), 0, loc);
        }
    }
}

fn emitCompoundAssignment(fc: *RegFnCompiler, target: *const ast.Expr, op: ast.CompoundAssignOp, val: *const ast.Expr, loc: ast.SourceLocation) !void {
    const val_vreg = try emitExpr(fc, val);
    if (target.* == .identifier) {
        const name = target.identifier.name;
        // 内联参数复合赋值：var 参数已在 tryEmitInlineCall 中拷贝到独立寄存器
        if (fc.inline_param_regs.get(name)) |vreg| {
            const arith_op: reg_opcode.Op = switch (op) {
                .add_assign => .add,
                .sub_assign => .sub,
                .mul_assign => .mul,
                .div_assign => .div,
                .mod_assign => .mod,
                .bit_and_assign => .bit_and,
                .bit_or_assign => .bit_or,
            };
            const result_vreg = fc.newTemp();
            try fc.chunk.writeABC(arith_op, @intCast(result_vreg & 0xFF), @intCast(vreg & 0xFF), @intCast(val_vreg & 0xFF), loc);
            try fc.chunk.writeABC(.assign, @intCast(vreg & 0xFF), @intCast(result_vreg & 0xFF), 0, loc);
            return;
        }
        if (fc.resolveLocal(name)) |local_vreg| {
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
        } else if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
            // get_upvalue → arith → set_upvalue
            const cur_vreg = fc.newTemp();
            try fc.chunk.writeABC(.get_upvalue, @intCast(cur_vreg & 0xFF), uv_idx, 0, loc);
            const arith_op: reg_opcode.Op = switch (op) {
                .add_assign => .add,
                .sub_assign => .sub,
                .mul_assign => .mul,
                .div_assign => .div,
                .mod_assign => .mod,
                .bit_and_assign => .bit_and,
                .bit_or_assign => .bit_or,
            };
            const result_vreg = fc.newTemp();
            try fc.chunk.writeABC(arith_op, @intCast(result_vreg & 0xFF), @intCast(cur_vreg & 0xFF), @intCast(val_vreg & 0xFF), loc);
            try fc.chunk.writeABC(.set_upvalue, @intCast(result_vreg & 0xFF), uv_idx, 0, loc);
        } else {
            return error.Unsupported;
        }
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

/// ADT 构造器条目（镜像栈式 CtorEntry）
const CtorEntry = struct {
    name: []const u8,
    idx: u16,
    arity: u8,
};

/// 待编译的方法条目（registerDecls 登记，compileBodies 编译）
const PendingMethod = struct {
    method: ast.MethodDecl,
    func_idx: u16,
};

/// 模块条目：模块名 → 导出函数名列表 + 子模块名列表
/// 用于实现"文件模块作为 trait 值"（文档 §4.6.2）。
const ModuleEntry = struct {
    /// 导出的 pub 函数名（运行时构造 trait_value 时填入 methods）
    exported_fns: [][]const u8,
    /// 子模块名列表（运行时作为嵌套 trait_value 填入 methods）
    submodules: [][]const u8,
};

/// 模块编译器：消费 ast.Module，产出 RegProgram（持有所有 RegFunction）。
/// 两遍编译：第一遍登记函数名→索引，第二遍编译函数体（使前向引用合法）。
pub const RegModuleCompiler = struct {
    program: reg_chunk.RegProgram,
    allocator: std.mem.Allocator,
    /// 顶层函数表：name → func_idx
    fn_map: std.StringHashMap(u16),
    /// ADT 构造器表
    ctor_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    ctor_map: std.StringHashMap(u16),
    /// newtype 构造器表
    newtype_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    newtype_map: std.StringHashMap(u16),
    /// error 构造器表
    error_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
    error_map: std.StringHashMap(u16),
    /// 待编译的 trait 方法列表（registerDecls 填充，compileBodies 消费）
    pending_methods: std.ArrayListUnmanaged(PendingMethod) = .empty,
    /// AST 优化 pass 结果（null = 未接入，所有优化查询返回安全默认值）
    analysis_db: ?*const analysis_db_mod.AnalysisDB = null,
    /// 下一个 memoization slot（纯函数 memoization 用）
    next_memo_slot: u16 = 0,
    /// 函数 AST 缓存（内联用）：函数名 → {body, params}，借用 AST 生命周期
    fn_asts: std.StringHashMapUnmanaged(FnAstEntry) = .{},
    /// 全局变量表：name → global index（load_global/store_global 的 Bx 操作数）
    global_map: std.StringHashMapUnmanaged(u16) = .{},
    /// 顶层全局声明/语句列表（registerDecls 填充，compileGlobalsInit 消费）
    pending_global_init: std.ArrayListUnmanaged(GlobalInitEntry) = .empty,
    /// 模块表：模块名 → ModuleEntry（导出函数 + 子模块名）
    /// registerDecls 遍历 deps 时填充，emitIdentifier 查询。
    module_map: std.StringHashMapUnmanaged(ModuleEntry) = .{},

    pub fn init(allocator: std.mem.Allocator) RegModuleCompiler {
        return .{
            .program = reg_chunk.RegProgram.init(allocator),
            .allocator = allocator,
            .fn_map = std.StringHashMap(u16).init(allocator),
            .ctor_map = std.StringHashMap(u16).init(allocator),
            .newtype_map = std.StringHashMap(u16).init(allocator),
            .error_map = std.StringHashMap(u16).init(allocator),
            .global_map = .{},
        };
    }

    pub fn deinit(self: *RegModuleCompiler) void {
        self.fn_map.deinit();
        self.ctor_table.deinit(self.allocator);
        self.ctor_map.deinit();
        self.newtype_table.deinit(self.allocator);
        self.newtype_map.deinit();
        self.error_table.deinit(self.allocator);
        self.error_map.deinit();
        self.pending_methods.deinit(self.allocator);
        self.fn_asts.deinit(self.allocator);
        self.global_map.deinit(self.allocator);
        self.pending_global_init.deinit(self.allocator);
        var mit = self.module_map.iterator();
        while (mit.next()) |e| {
            self.allocator.free(e.value_ptr.exported_fns);
            self.allocator.free(e.value_ptr.submodules);
        }
        self.module_map.deinit(self.allocator);
        // program 所有权移交调用方；此处不 deinit。
    }

    /// 查找顶层函数索引
    pub fn lookupFn(self: *RegModuleCompiler, name: []const u8) ?u16 {
        return self.fn_map.get(name);
    }

    /// 查找全局变量索引（load_global/store_global 的 Bx 操作数）
    pub fn lookupGlobal(self: *const RegModuleCompiler, name: []const u8) ?u16 {
        return self.global_map.get(name);
    }

    /// 查找 ADT 构造器
    pub fn lookupCtor(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.ctor_map.get(name)) |idx| return self.ctor_table.items[idx];
        return null;
    }

    /// 查找 newtype 构造器
    pub fn lookupNewtype(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.newtype_map.get(name)) |idx| return self.newtype_table.items[idx];
        return null;
    }

    /// 查找 error 构造器
    pub fn lookupError(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
        if (self.error_map.get(name)) |idx| return self.error_table.items[idx];
        return null;
    }

    /// 查找模块条目（导出函数 + 子模块名）
    pub fn lookupModule(self: *const RegModuleCompiler, name: []const u8) ?ModuleEntry {
        return self.module_map.get(name);
    }

    /// 内建 Throw 构造器标识（Ok/Error），不依赖字符串名匹配。
    pub const BuiltinThrowCtor = enum { ok, err };

    /// 查找内建 Throw 构造器。通过指针比较避免字符串字面量判断。
    pub fn lookupBuiltinThrowCtor(name: []const u8) ?BuiltinThrowCtor {
        // 仅两个合法名；用长度+内容精确比较，无大小写推断。
        if (name.len == 2 and name[0] == 'O' and name[1] == 'k') return .ok;
        if (name.len == 5 and name[0] == 'E' and name[1] == 'r' and name[2] == 'r' and name[3] == 'o' and name[4] == 'r') return .err;
        return null;
    }

    // ── AST 优化 pass 查询（镜像栈式 compiler 的消费端）──
    // 所有方法在 analysis_db == null 时返回安全默认值（不优化）。

    /// 【纯函数 memoization】查询函数是否纯
    pub fn isPureFn(self: *const RegModuleCompiler, name: []const u8) bool {
        if (self.analysis_db) |db| return db.purity.isPure(name);
        return false;
    }
    /// 【BranchReach】查询 if_expr 分支可达性
    pub fn branchInfo(self: *const RegModuleCompiler, if_expr: *const ast.Expr) ?analysis_db_mod.BranchInfo {
        if (self.analysis_db) |db| return db.branch_reach.lookup(if_expr);
        return null;
    }
    /// 【LICM】查询循环大小信息
    pub fn loopInfo(self: *const RegModuleCompiler, stmt: *const ast.Stmt) ?analysis_db_mod.LoopInfo {
        if (self.analysis_db) |db| return db.loop_invariant.lookup(stmt);
        return null;
    }
    /// 【ConstProp】查询表达式常量值
    pub fn constValue(self: *const RegModuleCompiler, expr: *const ast.Expr) ?analysis_db_mod.ConstValue {
        if (self.analysis_db) |db| return db.const_prop.lookup(expr);
        return null;
    }
    /// 【LICM】查询表达式是否为循环不变量（返回所属循环 stmt 指针）
    pub fn hoistInfo(self: *const RegModuleCompiler, expr: *const ast.Expr) ?*const ast.Stmt {
        if (self.analysis_db) |db| return db.hoist_table.lookup(expr);
        return null;
    }
    /// 【DCE】查询声明是否被标记 dead
    pub fn isDeadDecl(self: *const RegModuleCompiler, stmt: *const ast.Stmt) bool {
        if (self.analysis_db) |db| return db.dead_code.isDead(stmt);
        return false;
    }
    /// 【CSE】查询表达式的 canonical（redundant → canonical）
    pub fn cseCanonical(self: *const RegModuleCompiler, expr: *const ast.Expr) ?*const ast.Expr {
        if (self.analysis_db) |db| return db.cse.canonicalOf(expr);
        return null;
    }
    /// 【CSE】查询表达式是否为 canonical
    pub fn isCseCanonical(self: *const RegModuleCompiler, expr: *const ast.Expr) bool {
        if (self.analysis_db) |db| return db.cse.isCanonical(expr);
        return false;
    }
    /// 【memoization】为纯函数分配 memo slot（幂等：已分配则返回原 slot）。
    /// 返回 null 表示不可 memoize（非纯函数或未在 fn_map 中）。
    pub fn getOrAssignMemoSlot(self: *RegModuleCompiler, name: []const u8) ?u16 {
        if (!self.isPureFn(name)) return null;
        const idx = self.fn_map.get(name) orelse return null;
        const entry = &self.program.functions.items[idx];
        if (entry.memo_slot == 0xFFFF) {
            entry.memo_slot = self.next_memo_slot;
            self.next_memo_slot += 1;
        }
        return entry.memo_slot;
    }

    /// 合成 ADT 构造器包装函数（有参构造器作为一等值时使用）。
    /// 生成：params → make_adt → return
    fn regCtorWrapperFunc(self: *RegModuleCompiler, ctor_idx: u16, arity: u8, name: []const u8, loc: ast.SourceLocation) CompileError!u16 {
        const idx: u16 = @intCast(self.program.functions.items.len);
        // 预占位
        try self.program.functions.append(self.allocator, .{
            .chunk = reg_chunk.RegChunk.init(self.allocator),
            .arity = arity,
            .name = name,
        });
        var fc = RegFnCompiler.init(self.allocator);
        fc.module = self;
        fc.name = name;
        fc.arity = arity;
        defer fc.deinit();
        // 参数占 VReg 0..arity-1
        var i: u8 = 0;
        while (i < arity) : (i += 1) {
            _ = try fc.declareLocal("", false, false, null);
        }
        // make_adt dst, ctor_idx, arity — 参数在 R[0..arity-1]
        const dst = fc.newTemp();
        // 将参数 move 到 dst+1..dst+arity
        for (0..arity) |j| {
            try fc.chunk.writeABC(.move, @intCast((dst + 1 + j) & 0xFF), @intCast(j & 0xFF), 0, loc);
        }
        try fc.chunk.writeABC(.make_adt, @intCast(dst & 0xFF), @intCast(ctor_idx & 0xFF), arity, loc);
        try fc.chunk.writeABC(.return_op, @intCast(dst & 0xFF), 0, 0, loc);
        // 覆盖占位
        self.program.functions.items[idx].chunk.deinit();
        self.program.functions.items[idx].chunk = fc.chunk;
        self.program.functions.items[idx].register_count = @intCast(fc.next_vreg);
        const nreg: u6 = @intCast(@min(fc.next_vreg, 64));
        if (nreg == 64) {
            self.program.functions.items[idx].release_mask = ~@as(u64, 0);
        } else if (nreg > 0) {
            self.program.functions.items[idx].release_mask = (@as(u64, 1) << nreg) - 1;
        }
        fc.chunk = reg_chunk.RegChunk.init(self.allocator); // 防误释放
        return idx;
    }

    /// 合成 newtype 包装函数
    fn regNewtypeWrapperFunc(self: *RegModuleCompiler, nt_idx: u16, name: []const u8, loc: ast.SourceLocation) CompileError!u16 {
        const idx: u16 = @intCast(self.program.functions.items.len);
        try self.program.functions.append(self.allocator, .{
            .chunk = reg_chunk.RegChunk.init(self.allocator),
            .arity = 1,
            .name = name,
        });
        var fc = RegFnCompiler.init(self.allocator);
        fc.module = self;
        fc.name = name;
        fc.arity = 1;
        defer fc.deinit();
        _ = try fc.declareLocal("", false, false, null);
        const dst = fc.newTemp();
        // make_newtype A=dst, B=src(param 0), C=nt_idx
        try fc.chunk.writeABC(.make_newtype, @intCast(dst & 0xFF), 0, @intCast(nt_idx & 0xFF), loc);
        try fc.chunk.writeABC(.return_op, @intCast(dst & 0xFF), 0, 0, loc);
        self.program.functions.items[idx].chunk.deinit();
        self.program.functions.items[idx].chunk = fc.chunk;
        self.program.functions.items[idx].register_count = @intCast(fc.next_vreg);
        const nreg: u6 = @intCast(@min(fc.next_vreg, 64));
        if (nreg == 64) {
            self.program.functions.items[idx].release_mask = ~@as(u64, 0);
        } else if (nreg > 0) {
            self.program.functions.items[idx].release_mask = (@as(u64, 1) << nreg) - 1;
        }
        fc.chunk = reg_chunk.RegChunk.init(self.allocator);
        return idx;
    }

    /// 编译入口模块 + 其 `use` 依赖模块。依赖在前，入口在后（入口可前向引用依赖）。
    pub fn compileModuleWithDeps(self: *RegModuleCompiler, module: *const ast.Module, deps: []const ast.Module) CompileError!void {
        // 第一遍：登记所有模块的顶层函数名
        for (deps) |*dep| try self.registerDecls(dep);
        try self.registerDecls(module);
        // 收集模块表（导出函数 + 子模块名），供模块标识符解析为 trait_value
        try self.collectModules(deps, module);
        // 第二遍：编译所有模块的函数体
        for (deps) |*dep| try self.compileBodies(dep);
        try self.compileBodies(module);
        // 编译全局初始化函数（顶层 var/val/语句 → globals_init）
        try self.compileGlobalsInit();
        // 第三遍：bytecode 优化 pass（DRE + peephole + redundant move）
        _ = try reg_optimizer.optimizeProgram(&self.program, self.allocator);
    }

    /// 收集模块表：遍历依赖模块和入口模块，对每个有 name 的模块登记其
    /// 导出 pub 函数名和 pack_decl 声明的子模块名（文档 §4.6.2）。
    fn collectModules(self: *RegModuleCompiler, deps: []const ast.Module, module: *const ast.Module) CompileError!void {
        // 依赖模块：可能被 import 引用，需登记
        for (deps) |*dep| try self.collectOneModule(dep);
        // 入口模块本身也可能是模块值来源
        try self.collectOneModule(module);
    }

    fn collectOneModule(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
        // 模块名非空且未登记
        if (module.name.len == 0) return;
        if (self.module_map.contains(module.name)) return;

        var exported = std.ArrayListUnmanaged([]const u8).empty;
        defer exported.deinit(self.allocator);
        var submods = std.ArrayListUnmanaged([]const u8).empty;
        defer submods.deinit(self.allocator);

        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 仅 pub 函数导出为模块方法
                    if (fd.visibility == .public) {
                        // 仅在已注册到 fn_map 时登记（避免登记未编译函数）
                        if (self.fn_map.contains(fd.name)) {
                            exported.append(self.allocator, fd.name) catch return error.OutOfMemory;
                        }
                    }
                },
                .pack_decl => |pd| {
                    submods.append(self.allocator, pd.name) catch return error.OutOfMemory;
                },
                else => {},
            }
        }

        const owned_fns = exported.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_fns);
        const owned_subs = submods.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_subs);

        self.module_map.put(self.allocator, module.name, .{
            .exported_fns = owned_fns,
            .submodules = owned_subs,
        }) catch return error.OutOfMemory;
    }

    /// 第一遍：登记模块的顶层函数声明 + 类型声明
    fn registerDecls(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 同名函数已登记（依赖与入口重名）→ 跳过（首个生效）
                    if (self.fn_map.contains(fd.name)) continue;
                    const idx: u16 = @intCast(self.program.functions.items.len);
                    try self.fn_map.put(fd.name, idx);
                    // 标记入口函数（parser 通过 is_entry 标记，无需字符串查找）
                    if (fd.is_entry) self.program.entry = idx;
                    // 缓存 AST（内联用）：body/params 借用 AST 生命周期
                    try self.fn_asts.put(self.allocator, fd.name, .{
                        .body = fd.body,
                        .params = fd.params,
                    });
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
                        .is_async = fd.is_async,
                    });
                },
                .type_decl => |td| {
                    switch (td.def) {
                        .adt => |a| {
                            for (a.constructors) |con| {
                                if (self.ctor_map.contains(con.name)) continue;
                                // 提取字段名和类型
                                const fnames = self.allocator.alloc(?[]const u8, con.fields.len) catch return error.OutOfMemory;
                                const ftypes = self.allocator.alloc(?[]const u8, con.fields.len) catch return error.OutOfMemory;
                                for (con.fields, 0..) |f, i| {
                                    fnames[i] = f.name;
                                    ftypes[i] = builtinNumericTypeOf(f.ty);
                                }
                                const cidx: u16 = @intCast(self.program.adt_ctors.items.len);
                                try self.program.adt_ctors.append(self.allocator, .{
                                    .type_name = td.name,
                                    .ctor_name = con.name,
                                    .field_names = fnames,
                                    .field_types = ftypes,
                                    .arity = @intCast(con.fields.len),
                                });
                                const local_idx: u16 = @intCast(self.ctor_table.items.len);
                                try self.ctor_table.append(self.allocator, .{ .name = con.name, .idx = cidx, .arity = @intCast(con.fields.len) });
                                try self.ctor_map.put(con.name, local_idx);
                            }
                        },
                        .newtype => |nt| {
                            if (self.newtype_map.contains(nt.name)) continue;
                            const ntidx: u16 = @intCast(self.program.newtype_ctors.items.len);
                            try self.program.newtype_ctors.append(self.allocator, .{
                                .type_name = td.name,
                            });
                            const local_idx: u16 = @intCast(self.newtype_table.items.len);
                            try self.newtype_table.append(self.allocator, .{ .name = nt.name, .idx = ntidx, .arity = 1 });
                            try self.newtype_map.put(nt.name, local_idx);
                        },
                        .error_newtype => |en| {
                            if (self.error_map.contains(en.name)) continue;
                            // 提取 prefix 方法（如有）
                            var prefix: []const u8 = ERROR_DEFAULT_PREFIX;
                            for (en.methods) |m| {
                                if (method_mod.MethodId.fromName(m.name) == .prefix) {
                                    // 简化：使用类型名作为 prefix（实际应编译方法体）
                                    prefix = td.name;
                                    break;
                                }
                            }
                            const eidx: u16 = @intCast(self.program.error_ctors.items.len);
                            try self.program.error_ctors.append(self.allocator, .{
                                .type_name = td.name,
                                .default_prefix = prefix,
                            });
                            const local_idx: u16 = @intCast(self.error_table.items.len);
                            try self.error_table.append(self.allocator, .{ .name = en.name, .idx = eidx, .arity = 1 });
                            try self.error_map.put(en.name, local_idx);
                        },
                        else => {},
                    }
                    // 注册 ADT/record/newtype 类型的 trait 方法（带 body 的方法）
                    if (td.def != .error_newtype) {
                        for (td.methods) |m| {
                            if (m.body == null) continue;
                            const idx: u16 = @intCast(self.program.functions.items.len);
                            // 预占位
                            try self.program.functions.append(self.allocator, .{
                                .chunk = reg_chunk.RegChunk.init(self.allocator),
                                .arity = @intCast(m.params.len),
                                .name = m.name,
                            });
                            // 注册到 trait_methods（每个实现的 trait 名，或 "" 表示固有方法）
                            if (td.implemented_traits.len > 0) {
                                for (td.implemented_traits) |tb| {
                                    try self.program.addTraitMethod(td.name, m.name, tb.trait_name, idx);
                                }
                            } else {
                                try self.program.addTraitMethod(td.name, m.name, "", idx);
                            }
                            try self.pending_methods.append(self.allocator, .{ .method = m, .func_idx = idx });
                        }
                    } else {
                        // error_newtype 的方法注册到 Error trait
                        for (td.def.error_newtype.methods) |m| {
                            if (m.body == null) continue;
                            const idx: u16 = @intCast(self.program.functions.items.len);
                            try self.program.functions.append(self.allocator, .{
                                .chunk = reg_chunk.RegChunk.init(self.allocator),
                                .arity = @intCast(m.params.len),
                                .name = m.name,
                            });
                            try self.program.addTraitMethod(td.name, m.name, type_names.error_type, idx);
                            try self.pending_methods.append(self.allocator, .{ .method = m, .func_idx = idx });
                        }
                    }
                },
                .trait_decl => |td| {
                    // 注册 trait 默认方法（带 body 且非 delegate）
                    for (td.methods) |m| {
                        if (m.delegate != null) continue;
                        if (m.body == null) continue;
                        const idx: u16 = @intCast(self.program.functions.items.len);
                        try self.program.functions.append(self.allocator, .{
                            .chunk = reg_chunk.RegChunk.init(self.allocator),
                            .arity = @intCast(m.params.len),
                            .name = m.name,
                        });
                        try self.program.addTraitDefault(td.name, m.name, idx);
                        try self.pending_methods.append(self.allocator, .{ .method = m, .func_idx = idx });
                    }
                },
                .expr_decl => |ed| {
                    // 顶层表达式声明：可能是 var_decl/val_decl（→ 全局）或顶层语句/表达式
                    if (ed.stmt) |stmt| {
                        switch (stmt.*) {
                            .var_decl => |vd| {
                                if (!self.global_map.contains(vd.name)) {
                                    const gidx: u16 = @intCast(self.pending_global_init.items.len);
                                    try self.global_map.put(self.allocator, vd.name, gidx);
                                    try self.pending_global_init.append(self.allocator, .{
                                        .name = vd.name,
                                        .is_var_decl = true,
                                        .type_ann = vd.type_annotation,
                                        .init_expr = vd.value,
                                        .stmt = stmt,
                                        .loc = ed.location,
                                    });
                                }
                            },
                            .val_decl => |vd| {
                                if (!self.global_map.contains(vd.name)) {
                                    const gidx: u16 = @intCast(self.pending_global_init.items.len);
                                    try self.global_map.put(self.allocator, vd.name, gidx);
                                    try self.pending_global_init.append(self.allocator, .{
                                        .name = vd.name,
                                        .is_var_decl = true,
                                        .type_ann = vd.type_annotation,
                                        .init_expr = vd.value,
                                        .stmt = stmt,
                                        .loc = ed.location,
                                    });
                                }
                            },
                            else => {
                                // 顶层语句（assignment/for/while/defer/throw/return 等）
                                try self.pending_global_init.append(self.allocator, .{
                                    .is_var_decl = false,
                                    .init_expr = ed.expr,
                                    .stmt = stmt,
                                    .loc = ed.location,
                                });
                            },
                        }
                    } else {
                        // 纯顶层表达式
                        try self.pending_global_init.append(self.allocator, .{
                            .is_var_decl = false,
                            .init_expr = ed.expr,
                            .loc = ed.location,
                        });
                    }
                },
                else => {},
            }
        }
    }

    /// 第二遍：编译模块的函数体 + trait 方法体
    fn compileBodies(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
        // 先编译 trait/type 方法（填 trait_methods/trait_defaults 表，使后续 fun 体可调用）
        for (self.pending_methods.items) |pm| {
            try self.compileMethodBody(pm.method, pm.func_idx);
        }
        // 再编译顶层函数
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| try self.compileFunction(fd),
                else => {},
            }
        }
    }

    /// 编译 trait 方法体到已预占位的函数槽
    fn compileMethodBody(self: *RegModuleCompiler, m: ast.MethodDecl, func_idx: u16) CompileError!void {
        const body = m.body orelse return;
        var fc = RegFnCompiler.init(self.allocator);
        fc.module = self;
        fc.name = m.name;
        fc.arity = @intCast(m.params.len);
        defer fc.deinit();

        // 声明参数为局部变量（self 占 VReg 0，其余参数跟后）
        for (m.params) |p| {
            _ = try fc.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
        }

        const loc = m.location;
        emitTailExpr(&fc, body, loc) catch |err| {
            return err;
        };

        // 覆盖预占位槽
        self.program.functions.items[func_idx].chunk.deinit();
        self.program.functions.items[func_idx].chunk = fc.chunk;
        self.program.functions.items[func_idx].arity = @intCast(m.params.len);
        self.program.functions.items[func_idx].register_count = @intCast(fc.next_vreg);
        const nreg_raw: u32 = @intCast(@min(fc.next_vreg, 64));
        if (nreg_raw >= 64) {
            self.program.functions.items[func_idx].release_mask = ~@as(u64, 0);
        } else if (nreg_raw > 0) {
            self.program.functions.items[func_idx].release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
        }
        fc.chunk = reg_chunk.RegChunk.init(self.allocator);
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

        // 编译函数体（尾位置）— 尝试 TCO，失败则 emitExpr + return
        const loc = fd.location;
        emitTailExpr(&fc, fd.body, loc) catch |err| {
            return err;
        };

        // 覆盖第一遍预留的占位槽
        const idx = self.lookupFn(fd.name).?;
        self.program.functions.items[idx].chunk.deinit(); // 释放占位空 chunk
        self.program.functions.items[idx].chunk = fc.chunk; // 移交所有权
        self.program.functions.items[idx].arity = @intCast(fd.params.len);
        self.program.functions.items[idx].register_count = @intCast(fc.next_vreg);
        // release_mask：简化版 — 标记所有寄存器需 release（bit i=1）
        // release(null/unit/int/float) 是安全的无操作，只有 boxed 值真正减引用计数
        const nreg_raw: u32 = @intCast(@min(fc.next_vreg, 64));
        if (nreg_raw >= 64) {
            self.program.functions.items[idx].release_mask = ~@as(u64, 0);
        } else if (nreg_raw > 0) {
            self.program.functions.items[idx].release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
        }

        // 防止 fc.deinit 释放已移交的 chunk（置空壳）
        fc.chunk = reg_chunk.RegChunk.init(self.allocator);
    }

    /// 编译全局初始化函数：将顶层 var/val/语句编译为一个无参函数，
    /// VM 在 call() 入口前执行。var/val 声明 → emit init + store_global；
    /// 其他语句/表达式 → 直接 emit。
    fn compileGlobalsInit(self: *RegModuleCompiler) CompileError!void {
        if (self.pending_global_init.items.len == 0) return;

        const init_idx: u16 = @intCast(self.program.functions.items.len);
        self.program.global_count = @intCast(self.pending_global_init.items.len);

        var fc = RegFnCompiler.init(self.allocator);
        fc.module = self;
        fc.name = "$globals_init";
        fc.arity = 0;
        defer fc.deinit();

        for (self.pending_global_init.items) |entry| {
            if (entry.is_var_decl) {
                // 全局 var/val：emit init 表达式 → store_global
                var rhs_vreg = try emitExpr(&fc, entry.init_expr);
                const tname = paramTypeName(entry.type_ann);
                if (tname) |ptn| {
                    if (isBuiltinNumericType(ptn)) {
                        const at = exprBuiltinType(&fc, entry.init_expr);
                        if (at == null or !std.mem.eql(u8, at.?, ptn)) {
                            const coerced = fc.newTemp();
                            const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, ptn));
                            try fc.chunk.writeABC(.coerce, @intCast(coerced & 0xFF), @intCast(rhs_vreg & 0xFF), @intCast(type_k & 0xFF), entry.loc);
                            rhs_vreg = coerced;
                        }
                    }
                }
                const gidx = self.lookupGlobal(entry.name).?;
                try fc.chunk.writeABx(.store_global, @intCast(rhs_vreg & 0xFF), gidx, entry.loc);
            } else if (entry.stmt) |stmt| {
                // 顶层语句
                try emitStmt(&fc, stmt);
            } else {
                // 纯顶层表达式
                _ = try emitExpr(&fc, entry.init_expr);
            }
        }
        // 返回 unit
        try fc.chunk.writeABC(.return_unit, 0, 0, 0, .{ .line = 0, .column = 0 });

        try self.program.functions.append(self.allocator, .{
            .chunk = fc.chunk,
            .arity = 0,
            .name = "$globals_init",
            .register_count = @intCast(fc.next_vreg),
        });
        const nreg_raw: u32 = @intCast(@min(fc.next_vreg, 64));
        if (nreg_raw >= 64) {
            self.program.functions.items[init_idx].release_mask = ~@as(u64, 0);
        } else if (nreg_raw > 0) {
            self.program.functions.items[init_idx].release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
        }
        self.program.globals_init = init_idx;
        fc.chunk = reg_chunk.RegChunk.init(self.allocator);
    }
};
