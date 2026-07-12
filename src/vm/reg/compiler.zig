//! 寄存器 VM 字节码编译器。
//!
//! 将 AST 编译为 RegProgram（函数表 + ADT/trait 描述符 + 全局初始化）。
//! 支持内联展开、循环展开、代数化简、公共子表达式消除、循环不变量提升、
//! letrec 绑定、尾调用优化与记忆化调用，并依赖 analysis_db 提供的
//! 常量传播、分支可达性与死代码分析结果做编译期决策。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
pub const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");

pub const reg_chunk_mod = reg_chunk;

const reg_alloc = @import("alloc.zig");
const shared = @import("shared");
const method_mod = shared.method_mod;
const analysis_db_mod = @import("analysis_db");

pub const reg_vm = @import("vm.zig");
pub const reg_passes = @import("passes.zig");
pub const reg_optimizer = @import("optimizer.zig");

/// 错误构造器的默认前缀。
const ERROR_DEFAULT_PREFIX = "error";
const type_names = ast.type_names;

/// 编译期可能产生的错误集合。
pub const CompileError = error{
    Unsupported,
    OutOfMemory,
    TooManyLocals,
    TooManyConstants,
    InvalidJump,
} || std.mem.Allocator.Error;

/// 局部变量描述，记录虚拟寄存器、可变性、装箱状态与存活区间。
const Local = struct {
    name: []const u8,
    vreg: reg_alloc.VReg,
    is_var: bool,
    boxed: bool,
    def_inst: u32,
    last_use: u32,
    builtin_type: ?[]const u8 = null,
    func_idx: ?u16 = null,
};

/// upvalue 捕获信息，is_local 标识捕获的是直接外层局部还是更外层的 upvalue。
const UpvalueInfo = struct {
    name: []const u8,
    is_local: bool,
    index: u8,
    func_idx: ?u16 = null,
};

/// 函数 AST 条目，缓存函数体与参数以便内联展开时复用。
const FnAstEntry = struct {
    body: *const ast.Expr,
    params: []const ast.Param,
};

/// 全局初始化条目，记录待编译的全局变量声明或表达式语句。
const GlobalInitEntry = struct {
    name: []const u8 = "",
    is_var_decl: bool,
    type_ann: ?*const ast.TypeNode = null,
    init_expr: *const ast.Expr,
    stmt: ?*const ast.Stmt = null,
    loc: ast.SourceLocation,
};

/// 循环上下文，记录 continue 目标地址与待回填的 break 跳转列表。
const LoopCtx = struct {
    continue_target: usize,
    breaks: std.ArrayListUnmanaged(usize),
    defer_depth: u32,
};
/// 单函数编译器，负责将一个函数体编译为 RegChunk 字节码。
/// 管理局部变量表、upvalue 捕获、循环跳转、内联参数与 CSE/不变量寄存器缓存。
pub const RegFnCompiler = struct {
chunk: reg_chunk.RegChunk,
allocator: std.mem.Allocator,
locals: std.ArrayListUnmanaged(Local) = .empty,
next_vreg: reg_alloc.VReg = 0,
alloc: reg_alloc.RegAllocator,
allocation: ?reg_alloc.Allocation = null,
upvalues: std.ArrayListUnmanaged(UpvalueInfo) = .empty,
enclosing: ?*RegFnCompiler = null,
loops: std.ArrayListUnmanaged(LoopCtx) = .empty,
name: []const u8 = "",
arity: u8 = 0,
module: ?*RegModuleCompiler = null,
hoisted_regs: std.AutoHashMapUnmanaged(*const ast.Expr, reg_alloc.VReg) = .{},
cse_regs: std.AutoHashMapUnmanaged(*const ast.Expr, reg_alloc.VReg) = .{},
inline_param_regs: std.StringHashMapUnmanaged(reg_alloc.VReg) = .{},

/// 初始化函数编译器，创建空 chunk 与寄存器分配器。
pub fn init(allocator: std.mem.Allocator) RegFnCompiler {
return .{
.chunk = reg_chunk.RegChunk.init(allocator),
.allocator = allocator,
.alloc = reg_alloc.RegAllocator.init(allocator),
};
}
/// 释放函数编译器持有的所有资源。
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
/// 分配一个新的虚拟寄存器编号。
pub fn newVReg(self: *RegFnCompiler) reg_alloc.VReg {
const v = self.next_vreg;
self.next_vreg += 1;
return v;
}

/// 分配一个临时虚拟寄存器（语义同 newVReg，强调临时用途）。
pub fn newTemp(self: *RegFnCompiler) reg_alloc.VReg {
return self.newVReg();
}

/// 声明一个局部变量，返回分配的虚拟寄存器并记录存活起点。
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
/// 按名查找局部变量，找到时更新 last_use 并返回虚拟寄存器。
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
/// 查找局部变量的内建类型标注（如 i32、f64），用于数值强制转换。
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
/// 查找局部变量关联的函数索引（用于 letrec 绑定与尾调用参数类型推导）。
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
/// 查找已捕获的 upvalue 索引，未捕获时返回 null。
pub fn resolveUpvalue(self: *RegFnCompiler, name: []const u8) ?u8 {
for (self.upvalues.items, 0..) |uv, i| {
if (std.mem.eql(u8, uv.name, name)) return @intCast(i);
}
return null;
}
/// 查找 upvalue 关联的函数索引。
pub fn findUpvalueFuncIdx(self: *RegFnCompiler, name: []const u8) ?u16 {
for (self.upvalues.items) |uv| {
if (std.mem.eql(u8, uv.name, name)) return uv.func_idx;
}
return null;
}
/// 添加一个 upvalue 捕获条目，返回其索引。
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
/// 递归查找 upvalue：先查自身，再查外层局部，最后递归外层 upvalue。
/// 找到外层局部或 upvalue 时在本层登记新的 upvalue 捕获。
pub fn resolveUpvalueRecursive(self: *RegFnCompiler, name: []const u8) !?u8 {
if (self.resolveUpvalue(name)) |idx| return idx;
const enc = self.enclosing orelse return null;
if (enc.resolveLocal(name)) |vreg| {
const fidx = enc.findLocalFuncIdx(name);
return try self.addUpvalue(name, true, @intCast(vreg & 0xFF), fidx);
}
if (try enc.resolveUpvalueRecursive(name)) |uv_idx| {
const fidx = enc.findUpvalueFuncIdx(name);
return try self.addUpvalue(name, false, uv_idx, fidx);
}
return null;
}
};
/// 将分析数据库的 ConstValue 转换为运行期 Value，unknown 返回 null。
fn constValueToValue(cv: analysis_db_mod.ConstValue) ?value.Value {
return switch (cv) {
.int_val => |i| value.Value.fromInt(value.Int.fromNative(.i128, i)),
.float_val => |f| value.Value.fromFloat(value.Float.fromNative(.f64, f)),
.bool_val => |b| value.Value.fromBool(b),
.unknown => null,
};
}
/// 递归统计表达式中的 AST 节点数，用于判断函数体是否足够小可内联。
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
.lambda => 1,
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
/// 统计语句中的 AST 节点数（countExprNodes 的语句版本）。
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
/// 判断表达式是否包含控制流（if/match/lambda/select 等），用于内联可行性检查。
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
/// 判断语句是否包含控制流（hasControlFlow 的语句版本）。
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
/// 递归判断表达式是否调用了名为 name 的函数，用于禁止递归函数内联。
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
/// 判断语句是否调用了名为 name 的函数（callsSelf 的语句版本）。
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
/// 判断函数是否满足内联条件：参数≤3、节点数≤8、无控制流、无自递归。
fn canInlineFn(name: []const u8, arity: usize, body: *const ast.Expr) bool {
if (arity > 3) return false;
if (countExprNodes(body) > 8) return false;
if (hasControlFlow(body)) return false;
if (callsSelf(body, name)) return false;
return true;
}
/// 尝试将函数调用内联展开：将参数绑定到 inline_param_regs 后直接编译函数体。
/// 不满足内联条件或参数数不匹配时返回 null。
fn tryEmitInlineCall(
fc: *RegFnCompiler,
callee_name: []const u8,
arguments: []*ast.Expr,
entry: FnAstEntry,
loc: ast.SourceLocation,
) !?reg_alloc.VReg {
if (!canInlineFn(callee_name, entry.params.len, entry.body)) return null;
if (entry.params.len != arguments.len) return null;
var arg_regs: std.ArrayListUnmanaged(reg_alloc.VReg) = .empty;
defer arg_regs.deinit(fc.allocator);
for (arguments) |arg| {
const arg_vreg = try emitExpr(fc, arg);
try arg_regs.append(fc.allocator, arg_vreg);
}
for (entry.params, 0..) |p, i| {
if (p.is_var) {
const copy_vreg = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(copy_vreg & 0xFF), @intCast(arg_regs.items[i] & 0xFF), 0, loc);
try fc.inline_param_regs.put(fc.allocator, p.name, copy_vreg);
} else {
try fc.inline_param_regs.put(fc.allocator, p.name, arg_regs.items[i]);
}
}
const result = try emitExpr(fc, entry.body);
for (entry.params) |p| _ = fc.inline_param_regs.remove(p.name);
return result;
}
/// 递归判断表达式是否包含 break/continue，用于禁止含跳转的循环展开。
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
.lambda => false,
else => false,
};
}
/// 判断语句是否包含 break/continue（exprHasBreakOrContinue 的语句版本）。
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
/// 尝试对常量范围的 for 循环做完全展开（迭代数 1~16）。
/// 仅当起止值为编译期常量且循环体不含 break/continue 时才展开。
fn tryUnrollFor(
fc: *RegFnCompiler,
stmt: *const ast.Stmt,
fs: anytype,
loc: ast.SourceLocation,
) !bool {
const m = fc.module orelse return false;
const li = m.loopInfo(stmt) orelse return false;
if (!li.is_small) return false;
if (fs.iterable.* != .binary) return false;
const bin = fs.iterable.binary;
const inclusive = (bin.op == .range_inclusive);
if (bin.op != .range and bin.op != .range_inclusive) return false;
const start_cv = m.constValue(bin.left) orelse return false;
const end_cv = m.constValue(bin.right) orelse return false;
if (start_cv != .int_val or end_cv != .int_val) return false;
const start = start_cv.int_val;
const end = end_cv.int_val;
const count = if (inclusive) end - start + 1 else end - start;
if (count < 1 or count > 16) return false;
if (exprHasBreakOrContinue(fs.body)) return false;
var i = start;
const end_iter = if (inclusive) end + 1 else end;
while (i < end_iter) : (i += 1) {
_ = try fc.declareLocal(fs.name, false, false, null);
const var_vreg = fc.resolveLocal(fs.name).?;
const k = try fc.chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i128, i)));
const tmp = fc.newTemp();
try fc.chunk.writeABx(.load_const, @intCast(tmp & 0xFF), k, loc);
try fc.chunk.writeABC(.move, @intCast(var_vreg & 0xFF), @intCast(tmp & 0xFF), 0, loc);
_ = try emitExpr(fc, fs.body);
}
return true;
}
/// 编译表达式为字节码，返回存放结果的虚拟寄存器。
/// 对二元表达式先尝试 hoisted/CSE/常量折叠优化，再回退到常规编译。
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
if (fc.hoisted_regs.get(expr)) |hvreg| break :blk hvreg;
if (fc.module) |m| {
if (m.cseCanonical(expr)) |canonical| {
if (fc.cse_regs.get(canonical)) |cvreg| break :blk cvreg;
}
}
if (fc.module) |m| {
if (m.constValue(expr)) |cv| {
if (constValueToValue(cv)) |v| {
const dst = fc.newTemp();
const k = try fc.chunk.addConstant(v);
try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
if (m.isCseCanonical(expr)) try fc.cse_regs.put(fc.allocator, expr, dst);
break :blk dst;
}
}
}
const dst = try emitBinary(fc, bin.op, bin.left, bin.right, loc);
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
try emitAssignment(fc, ae.target, ae.value, loc);
const dst = fc.newTemp();
try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
break :blk dst;
},
.inline_trait_value => |itv| try emitInlineTraitValue(fc, itv.methods, loc),
else => return error.Unsupported,
};
}
/// 从类型注解节点提取类型名字符串（named 或 generic），否则返回 null。
fn paramTypeName(ta: ?*const ast.TypeNode) ?[]const u8 {
const t = ta orelse return null;
return switch (t.*) {
.named => |n| n.name,
.generic => |g| g.name,
else => null,
};
}
/// 内建数值类型枚举，用于编译期数值类型推导与强制转换判断。
pub const NumericType = enum {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f128,

    /// 判断是否为浮点类型。
    pub fn isFloat(self: NumericType) bool {
return switch (self) {
.f16, .f32, .f64, .f128 => true,
else => false,
};
}
    /// 判断是否为无符号整数类型。
    pub fn isUnsigned(self: NumericType) bool {
return switch (self) {
.u8, .u16, .u32, .u64, .u128 => true,
else => false,
};
}
    /// 判断是否为有符号整数类型。
    pub fn isSignedInt(self: NumericType) bool {
return switch (self) {
.i8, .i16, .i32, .i64, .i128 => true,
else => false,
};
}
};
/// 按名称解析内建数值类型，未匹配时返回 null。
fn parseNumericType(name: []const u8) ?NumericType {
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
/// 判断名称是否为内建数值类型。
fn isBuiltinNumericType(name: []const u8) bool {
return parseNumericType(name) != null;
}
/// 从类型节点提取内建数值类型名，非数值类型返回 null。
fn builtinNumericTypeOf(ty: *const ast.TypeNode) ?[]const u8 {
return switch (ty.*) {
.named => |n| if (isBuiltinNumericType(n.name)) n.name else null,
else => null,
};
}
/// 推导表达式的内建数值类型，用于自动强制转换。
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
/// 判断二元运算符是否为算术运算（加减乘除取模）。
fn isArithmeticOp(op: ast.BinaryOp) bool {
return switch (op) {
.add, .sub, .mul, .div, .mod => true,
else => false,
};
}
/// 编译整数字面量：解析后作为常量加载到临时寄存器。
fn emitIntLiteral(fc: *RegFnCompiler, il: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
const v = shared.parse_mod.parseIntLiteral(fc.allocator, il) catch return error.Unsupported;
if (v == null) return error.Unsupported;
const k = try fc.chunk.addConstant(v.?);
try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
return dst;
}

/// 编译浮点字面量：解析后作为常量加载到临时寄存器。
fn emitFloatLiteral(fc: *RegFnCompiler, fl: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
const v = shared.parse_mod.parseFloatLiteral(fc.allocator, fl) catch return error.Unsupported;
if (v == null) return error.Unsupported;
const k = try fc.chunk.addConstant(v.?);
try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
return dst;
}

/// 编译布尔字面量：发出 load_true 或 load_false 指令。
fn emitBoolLiteral(fc: *RegFnCompiler, bl: bool, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
try fc.chunk.writeABC(if (bl) .load_true else .load_false, @intCast(dst & 0xFF), 0, 0, loc);
return dst;
}

/// 编译 null 字面量：发出 load_null 指令。
fn emitNullLiteral(fc: *RegFnCompiler, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
return dst;
}

/// 编译 unit 字面量：发出 load_unit 指令。
fn emitUnitLiteral(fc: *RegFnCompiler, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
return dst;
}

/// 编译字符串字面量：创建 Value 后作为常量加载。
fn emitStringLiteral(fc: *RegFnCompiler, raw: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
const k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, raw));
try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
return dst;
}

/// 编译字符字面量：将码点转为 Char 后作为常量加载。
fn emitCharLiteral(fc: *RegFnCompiler, codepoint: u21, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
const ch = value.Char.fromCodePoint(codepoint) catch return error.Unsupported;
const k = try fc.chunk.addConstant(value.Value.fromChar(ch));
try fc.chunk.writeABx(.load_const, @intCast(dst & 0xFF), k, loc);
return dst;
}

/// 编译标识符引用：依次查找内联参数、局部变量、upvalue、全局变量、
/// 函数闭包、ADT 构造器、newtype 构造器和子模块值。
fn emitIdentifier(fc: *RegFnCompiler, name: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
if (fc.inline_param_regs.get(name)) |vreg| return vreg;
if (fc.resolveLocal(name)) |vreg| {
return vreg;
}
if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
const dst = fc.newTemp();
try fc.chunk.writeABC(.get_upvalue, @intCast(dst & 0xFF), uv_idx, 0, loc);
return dst;
}
if (fc.module) |m| {
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
if (m.lookupCtor(name)) |ce| {
const dst = fc.newTemp();
if (ce.arity == 0) {
try fc.chunk.writeABC(.make_adt, @intCast(dst & 0xFF), @intCast(ce.idx & 0xFF), 0, loc);
} else {
const wrap_idx = try m.regCtorWrapperFunc(ce.idx, ce.arity, name, loc);
try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), wrap_idx, loc);
}
return dst;
}
if (m.lookupNewtype(name)) |ce| {
const dst = fc.newTemp();
const wrap_idx = try m.regNewtypeWrapperFunc(ce.idx, name, loc);
try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), wrap_idx, loc);
return dst;
}
if (m.lookupModule(name)) |me| {
return try emitModuleValue(fc, me, loc);
}
}
return error.Unsupported;
}
/// 编译模块值：将导出函数与子模块打包为 trait 对象（make_trait）。
/// 每个条目占用两个寄存器：名称常量 + 值（闭包或子模块 trait）。
fn emitModuleValue(fc: *RegFnCompiler, me: ModuleEntry, loc: ast.SourceLocation) !reg_alloc.VReg {
const m = fc.module orelse return error.Unsupported;
const dst = fc.newTemp();
const fn_count = me.exported_fns.len;
const sub_count = me.submodules.len;
const total: u8 = @intCast(fn_count + sub_count);
if (total == 0 or total > 127) return error.Unsupported;
var idx: u8 = 0;
while (idx < total * 2) : (idx += 1) _ = fc.newTemp();
for (me.exported_fns, 0..) |fn_name, i| {
const name_reg: u8 = @intCast(dst + 1 + i * 2);
const val_reg: u8 = @intCast(dst + 2 + i * 2);
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, fn_name));
try fc.chunk.writeABx(.load_const, name_reg, name_k, loc);
if (m.lookupFn(fn_name)) |func_idx| {
try fc.chunk.writeABx(.closure, val_reg, func_idx, loc);
} else {
return error.Unsupported;
}
}
for (me.submodules, 0..) |sub_name, i| {
const name_reg: u8 = @intCast(dst + 1 + (fn_count + i) * 2);
const val_reg: u8 = @intCast(dst + 2 + (fn_count + i) * 2);
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, sub_name));
try fc.chunk.writeABx(.load_const, name_reg, name_k, loc);
if (m.lookupModule(sub_name)) |sub_me| {
const sub_vreg = try emitModuleValue(fc, sub_me, loc);
try fc.chunk.writeABC(.move, val_reg, @intCast(sub_vreg & 0xFF), 0, loc);
} else {
try fc.chunk.writeABC(.load_null, val_reg, 0, 0, loc);
}
}
try fc.chunk.writeABC(.make_trait, @intCast(dst & 0xFF), total, 0, loc);
return dst;
}
/// 尝试对算术表达式做编译期代数化简：
/// x+0/x-0 → x，x*1/x/1 → x，x*0 → 0，无符号 x%2^n → x & (2^n-1)。
/// 成功化简时返回结果寄存器，否则返回 null。
fn tryEmitAlgebraicSimplify(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !?reg_alloc.VReg {
const m = fc.module orelse return null;
if (m.constValue(right)) |rv| {
if (rv == .int_val) {
const rval = rv.int_val;
if (rval == 0 and (op == .add or op == .sub)) {
return try emitExpr(fc, left);
}
if (rval == 1 and (op == .mul or op == .div)) {
return try emitExpr(fc, left);
}
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
/// 判断 i128 是否为 2 的幂（正数且仅一位为 1）。
fn isPowerOfTwo(n: i128) bool {
return n > 0 and (n & (n - 1)) == 0;
}
/// 编译二元运算：短路逻辑、elvis、范围、拼接走专用路径，其余先尝试代数化简。
fn emitBinary(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
switch (op) {
.and_op, .or_op => return try emitShortCircuit(fc, op, left, right, loc),
.elvis => return try emitElvis(fc, left, right, loc),
.range, .range_inclusive => return try emitRange(fc, op, left, right, loc),
.concat_list => return try emitConcatList(fc, left, right, loc),
.concat => return try emitStringConcat(fc, left, right, loc),
else => {},
}
if (try tryEmitAlgebraicSimplify(fc, op, left, right, loc)) |dst| return dst;
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
/// 编译短路逻辑运算（and/or）：左值先赋给结果，条件跳过右值求值。
fn emitShortCircuit(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const is_and = op == .and_op;
const left_vreg = try emitExpr(fc, left);
const dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), 0, loc);
const jump_op: reg_opcode.Op = if (is_and) .jump_if_false else .jump_if_true;
const skip_idx = try fc.chunk.emitJump(jump_op, @intCast(dst & 0xFF), loc);
const right_vreg = try emitExpr(fc, right);
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(right_vreg & 0xFF), 0, loc);
fc.chunk.patchJump(skip_idx, fc.chunk.here());
return dst;
}
/// 编译 elvis 运算（?:）：左值非 null 时取左值，否则取右值。
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
/// 编译范围表达式：发出 make_range 或 make_range_incl 指令。
fn emitRange(fc: *RegFnCompiler, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const left_vreg = try emitExpr(fc, left);
const right_vreg = try emitExpr(fc, right);
const dst = fc.newTemp();
const range_op: reg_opcode.Op = if (op == .range_inclusive) .make_range_incl else .make_range;
try fc.chunk.writeABC(range_op, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
return dst;
}
/// 编译列表拼接：发出 concat_list 指令。
fn emitConcatList(fc: *RegFnCompiler, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const left_vreg = try emitExpr(fc, left);
const right_vreg = try emitExpr(fc, right);
const dst = fc.newTemp();
try fc.chunk.writeABC(.concat_list, @intCast(dst & 0xFF), @intCast(left_vreg & 0xFF), @intCast(right_vreg & 0xFF), loc);
return dst;
}
/// 编译字符串拼接：语义同 concat_list，委托到 emitConcatList。
fn emitStringConcat(fc: *RegFnCompiler, left: *const ast.Expr, right: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
return try emitConcatList(fc, left, right, loc);
}
/// 编译一元运算：neg → 取负，not → 逻辑非。
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
/// 编译 if 表达式：利用分支可达性分析消除恒真/恒假分支。
fn emitIf(fc: *RegFnCompiler, condition: *const ast.Expr, then_branch: *const ast.Expr, else_branch: ?*const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
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
const else_jump = try fc.chunk.emitJump(.jump_if_false, @intCast(cond_vreg & 0xFF), loc);
const then_vreg = try emitExpr(fc, then_branch);
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(then_vreg & 0xFF), 0, loc);
const end_jump = try fc.chunk.emitJump(.jump, 0, loc);
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
/// 编译块表达式：逐条编译语句，trailing_expr 作为块的值，无尾表达式时返回 unit。
fn emitBlock(fc: *RegFnCompiler, statements: []*ast.Stmt, trailing_expr: ?*const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
for (statements) |stmt| {
try emitStmt(fc, stmt);
}
if (trailing_expr) |te| {
return try emitExpr(fc, te);
}
const dst = fc.newTemp();
try fc.chunk.writeABC(.load_unit, @intCast(dst & 0xFF), 0, 0, loc);
return dst;
}
/// 当参数类型与形参内建数值类型不一致时，插入 coerce 指令做强制转换。
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
/// 获取函数索引对应的参数类型列表，用于调用时数值强制转换。
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
/// 编译函数调用：依次尝试内联参数、局部值调用、upvalue 调用、native 函数、
/// 构造器、新类型、错误构造器、async spawn、内联展开与普通/记忆化调用。
fn emitCall(fc: *RegFnCompiler, callee: *const ast.Expr, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
if (callee.* == .identifier) {
const name = callee.identifier.name;
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
if (fc.resolveLocal(name)) |local_vreg| {
const dst = fc.newTemp();
for (0..arguments.len) |_| _ = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(local_vreg & 0xFF), 0, loc);
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
if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
const dst = fc.newTemp();
for (0..arguments.len) |_| _ = fc.newTemp();
try fc.chunk.writeABC(.get_upvalue, @intCast(dst & 0xFF), uv_idx, 0, loc);
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
for (0..arguments.len) |_| _ = fc.newTemp();
if (shared.native_mod.Native.fromName(name)) |nat| {
for (arguments, 0..) |arg, i| {
const arg_vreg = try emitExpr(fc, arg);
try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
}
try fc.chunk.writeABC(.call_native, @intCast(dst & 0xFF), @intFromEnum(nat), @intCast(arguments.len & 0xFF), loc);
return dst;
}
if (fc.module) |m| {
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
if (m.lookupNewtype(name)) |ne| {
if (arguments.len == 1) {
const arg_vreg = try emitExpr(fc, arguments[0]);
try fc.chunk.writeABC(.make_newtype, @intCast(dst & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(ne.idx & 0xFF), loc);
return dst;
}
}
if (m.lookupError(name)) |ee| {
if (arguments.len == 1) {
const arg_vreg = try emitExpr(fc, arguments[0]);
try fc.chunk.writeABC(.make_error, @intCast(dst & 0xFF), @intCast(arg_vreg & 0xFF), @intCast(ee.idx & 0xFF), loc);
return dst;
}
}
}
const func_idx: u16 = if (fc.module) |m|
(m.lookupFn(name) orelse return error.Unsupported)
else
return error.Unsupported;
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
if (fc.module) |m| {
if (m.program.functions.items[func_idx].is_async) {
const closure_reg = fc.newTemp();
for (0..arguments.len) |_| _ = fc.newTemp();
try fc.chunk.writeABx(.closure, @intCast(closure_reg & 0xFF), func_idx, loc);
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
try fc.chunk.writeABC(.spawn, @intCast(dst & 0xFF), @intCast(closure_reg & 0xFF), @intCast(arguments.len & 0xFF), loc);
return dst;
}
}
const param_types: []const ?[]const u8 = if (fc.module) |m|
m.program.functions.items[func_idx].param_types
else
&.{};
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
const use_memo = if (fc.module) |m| (m.getOrAssignMemoSlot(name) != null) else false;
try fc.chunk.writeABx(if (use_memo) .call_memoized else .call, @intCast(dst & 0xFF), func_idx, loc);
return dst;
}
const callee_vreg = try emitExpr(fc, callee);
const dst = fc.newTemp();
for (0..arguments.len) |_| _ = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(callee_vreg & 0xFF), 0, loc);
for (arguments, 0..) |arg, i| {
const arg_vreg = try emitExpr(fc, arg);
try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
}
try fc.chunk.writeABC(.call_value, @intCast(dst & 0xFF), 0, @intCast(arguments.len), loc);
return dst;
}
/// 编译字段访问：发出 get_field 指令，字段名作为常量。
fn emitFieldAccess(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
const obj_vreg = try emitExpr(fc, object);
const dst = fc.newTemp();
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
try fc.chunk.writeABC(.get_field, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), @intCast(name_k & 0xFF), loc);
return dst;
}
/// 编译方法调用：接收者放入结果寄存器，参数依次放入后续寄存器，发出 call_method。
fn emitMethodCall(fc: *RegFnCompiler, object: *const ast.Expr, method: []const u8, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const recv_vreg = try emitExpr(fc, object);
const dst = fc.newTemp();
for (0..arguments.len) |_| _ = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(recv_vreg & 0xFF), 0, loc);
for (arguments, 0..) |arg, i| {
const arg_vreg = try emitExpr(fc, arg);
try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(arg_vreg & 0xFF), 0, loc);
}
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, method));
try fc.chunk.writeABC(.call_method, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(arguments.len), loc);
return dst;
}
/// 编译数组字面量：各元素放入连续寄存器后发出 make_array。
fn emitArrayLiteral(fc: *RegFnCompiler, elements: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
for (0..elements.len) |_| _ = fc.newTemp();
for (elements, 0..) |elem, i| {
const elem_vreg = try emitExpr(fc, elem);
try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(elem_vreg & 0xFF), 0, loc);
}
try fc.chunk.writeABC(.make_array, @intCast(dst & 0xFF), @intCast(elements.len & 0xFF), 0, loc);
return dst;
}
/// 编译记录字面量：收集字段名到 record_shapes 表，各值放入连续寄存器后发出 make_record。
fn emitRecordLiteral(fc: *RegFnCompiler, fields: []ast.RecordFieldExpr, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
for (0..fields.len) |_| _ = fc.newTemp();
for (fields, 0..) |field, i| {
const val_vreg = try emitExpr(fc, field.value);
try fc.chunk.writeABC(.move, @intCast((dst + 1 + i) & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
}
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
/// 编译索引访问：发出 index_op 指令。
fn emitIndex(fc: *RegFnCompiler, object: *const ast.Expr, index: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const obj_vreg = try emitExpr(fc, object);
const index_vreg = try emitExpr(fc, index);
const dst = fc.newTemp();
try fc.chunk.writeABC(.index_op, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), @intCast(index_vreg & 0xFF), loc);
return dst;
}
/// 编译原子表达式：将内部值包装为 Atomic 值。
fn emitAtomicExpr(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const val_vreg = try emitExpr(fc, inner);
const dst = fc.newTemp();
try fc.chunk.writeABC(.make_atomic, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
return dst;
}
/// 编译通道操作数：若为 chan.recv() 方法调用则提取通道对象本身，否则直接编译表达式。
fn emitChannelOperand(fc: *RegFnCompiler, channel_expr: *const ast.Expr) !reg_alloc.VReg {
if (channel_expr.* == .method_call) {
const mc = channel_expr.method_call;
if (method_mod.MethodId.fromName(mc.method) == .recv) {
return try emitExpr(fc, mc.object);
}
}
return try emitExpr(fc, channel_expr);
}
/// 编译 select 表达式：逐 arm 尝试接收或超时，匹配 arm 的结果通过 end_jumps 跳到汇合点。
/// 超时 arm 用计时器，接收 arm 用 try_recv 探测就绪状态。
fn emitSelect(fc: *RegFnCompiler, arms: []const ast.SelectArm, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
var end_jumps = std.ArrayListUnmanaged(usize).empty;
defer end_jumps.deinit(fc.allocator);
for (arms) |arm| {
switch (arm) {
.receive => |ra| {
const ch_vreg = try emitChannelOperand(fc, ra.channel_expr);
const val_dst = fc.newTemp();
_ = fc.newTemp();
try fc.chunk.writeABC(.try_recv, @intCast(val_dst & 0xFF), @intCast(ch_vreg & 0xFF), 0, ra.location);
const not_ready = try fc.chunk.emitJump(.jump_if_false, @intCast((val_dst + 1) & 0xFF), ra.location);
if (ra.binding) |bname| {
_ = try fc.declareLocal(bname, false, false, null);
const local_vreg = fc.resolveLocal(bname).?;
try fc.chunk.writeABC(.move, @intCast(local_vreg & 0xFF), @intCast(val_dst & 0xFF), 0, ra.location);
}
const body_vreg = try emitExpr(fc, ra.body);
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, ra.location);
const ej = try fc.chunk.emitJump(.jump, 0, ra.location);
try end_jumps.append(fc.allocator, ej);
fc.chunk.patchJump(not_ready, fc.chunk.here());
},
.timeout => {},
}
}
var has_timeout = false;
for (arms) |arm| {
if (arm == .timeout) {
_ = try emitExpr(fc, arm.timeout.duration);
const body_vreg = try emitExpr(fc, arm.timeout.body);
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, arm.timeout.location);
has_timeout = true;
break;
}
}
if (!has_timeout) {
for (arms) |arm| {
if (arm == .receive) {
const ra = arm.receive;
const ch_vreg = try emitChannelOperand(fc, ra.channel_expr);
const val_dst = fc.newTemp();
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
for (end_jumps.items) |ej| fc.chunk.patchJump(ej, fc.chunk.here());
_ = loc;
return dst;
}
/// 编译惰性表达式：将内部值包装为 Lazy 值。
fn emitLazyExpr(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const val_vreg = try emitExpr(fc, inner);
const dst = fc.newTemp();
try fc.chunk.writeABC(.make_lazy, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
return dst;
}
/// 编译非空断言（!）：发出 non_null 指令，值为 null 时抛出异常。
fn emitNonNullAssert(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const val_vreg = try emitExpr(fc, inner);
try fc.chunk.writeABC(.non_null, @intCast(val_vreg & 0xFF), 0, 0, loc);
return val_vreg;
}
/// 编译传播操作符（?）：发出 propagate 指令，值为错误时提前返回。
fn emitPropagate(fc: *RegFnCompiler, inner: *const ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const val_vreg = try emitExpr(fc, inner);
try fc.chunk.writeABC(.propagate, @intCast(val_vreg & 0xFF), 0, 0, loc);
return val_vreg;
}
/// 编译字符串插值：各部分（字面量与表达式）放入连续寄存器后发出 interp 指令拼接。
fn emitStringInterp(fc: *RegFnCompiler, parts: []ast.InterpolationPart, loc: ast.SourceLocation) !reg_alloc.VReg {
const dst = fc.newTemp();
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
/// 编译类型转换：发出 cast 指令，目标类型名作为常量。
fn emitTypeCast(fc: *RegFnCompiler, inner: *const ast.Expr, target_type: *ast.TypeNode, loc: ast.SourceLocation) !reg_alloc.VReg {
const val_vreg = try emitExpr(fc, inner);
const dst = fc.newTemp();
const tname = paramTypeName(target_type) orelse "";
const type_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, tname));
try fc.chunk.writeABC(.cast, @intCast(dst & 0xFF), @intCast(val_vreg & 0xFF), @intCast(type_k & 0xFF), loc);
return dst;
}
/// 编译记录扩展：先复制基础记录，再逐字段更新（set_field）。
fn emitRecordExtend(fc: *RegFnCompiler, base_expr: *const ast.Expr, updates: []ast.RecordFieldExpr, loc: ast.SourceLocation) !reg_alloc.VReg {
const base_vreg = try emitExpr(fc, base_expr);
const dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(base_vreg & 0xFF), 0, loc);
try fc.chunk.writeABC(.record_extend, @intCast(dst & 0xFF), 0, 0, loc);
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
/// 编译安全字段访问（?.）：对象为 null 时返回 null，否则取字段。
fn emitSafeAccess(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, loc: ast.SourceLocation) !reg_alloc.VReg {
const obj_vreg = try emitExpr(fc, object);
const dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
const skip = try fc.chunk.emitJump(.jump_if_not_null, @intCast(dst & 0xFF), loc);
try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
const end = try fc.chunk.emitJump(.jump, 0, loc);
fc.chunk.patchJump(skip, fc.chunk.here());
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
try fc.chunk.writeABC(.get_field, @intCast(dst & 0xFF), @intCast(dst & 0xFF), @intCast(name_k & 0xFF), loc);
fc.chunk.patchJump(end, fc.chunk.here());
return dst;
}
/// 编译安全方法调用（?.）：对象为 null 时返回 null，否则执行方法调用。
fn emitSafeMethodCall(fc: *RegFnCompiler, object: *const ast.Expr, method: []const u8, arguments: []*ast.Expr, loc: ast.SourceLocation) !reg_alloc.VReg {
const obj_vreg = try emitExpr(fc, object);
const dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
const skip = try fc.chunk.emitJump(.jump_if_not_null, @intCast(dst & 0xFF), loc);
try fc.chunk.writeABC(.load_null, @intCast(dst & 0xFF), 0, 0, loc);
const end = try fc.chunk.emitJump(.jump, 0, loc);
fc.chunk.patchJump(skip, fc.chunk.here());
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
/// 编译 match 表达式：逐 arm 测试模式与可选 guard，匹配成功则编译 body 并跳到结束。
/// 所有 arm 失败后发出 match_fail 指令。
fn emitMatch(fc: *RegFnCompiler, scrutinee: *const ast.Expr, arms: []ast.MatchArm, loc: ast.SourceLocation) !reg_alloc.VReg {
const scrut_vreg = try emitExpr(fc, scrutinee);
const dst = fc.newTemp();
var end_jumps = std.ArrayListUnmanaged(usize).empty;
defer end_jumps.deinit(fc.allocator);
for (arms) |arm| {
const arm_base = fc.locals.items.len;
var fail_jumps = std.ArrayListUnmanaged(usize).empty;
defer fail_jumps.deinit(fc.allocator);
try emitPatternTest(fc, arm.pattern, scrut_vreg, &fail_jumps, loc);
if (arm.guard) |guard_expr| {
const guard_vreg = try emitExpr(fc, guard_expr);
try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(guard_vreg & 0xFF), loc));
}
const body_vreg = try emitExpr(fc, arm.body);
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(body_vreg & 0xFF), 0, loc);
try end_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump, 0, loc));
for (fail_jumps.items) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
fc.locals.shrinkRetainingCapacity(arm_base);
}
try fc.chunk.writeABC(.match_fail, 0, 0, 0, loc);
for (end_jumps.items) |ej| fc.chunk.patchJump(ej, fc.chunk.here());
return dst;
}
/// 编译模式测试：通配符/变量/字面量/构造器/or 模式/记录模式。
/// 测试失败时记录跳转至 fail_jumps，由调用方回填到下一个 arm。
fn emitPatternTest(fc: *RegFnCompiler, pat: *const ast.Pattern, scrut_vreg: reg_alloc.VReg, fail_jumps: *std.ArrayListUnmanaged(usize), loc: ast.SourceLocation) CompileError!void {
switch (pat.*) {
.wildcard => {},
.variable => |v| {
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
if (RegModuleCompiler.lookupBuiltinThrowCtor(v.name)) |bc| {
const want_ok: u8 = if (bc == .ok) 1 else 0;
const test_dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
try fc.chunk.writeABC(.test_throw, @intCast(test_dst & 0xFF), want_ok, 0, loc);
try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
return;
}
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
if (RegModuleCompiler.lookupBuiltinThrowCtor(ctor.name)) |bc| {
if (ctor.patterns.len != 1) return error.Unsupported;
const want_ok: u8 = if (bc == .ok) 1 else 0;
const test_dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(test_dst & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
try fc.chunk.writeABC(.test_throw, @intCast(test_dst & 0xFF), want_ok, 0, loc);
try fail_jumps.append(fc.allocator, try fc.chunk.emitJump(.jump_if_false, @intCast(test_dst & 0xFF), loc));
const inner_vreg = fc.newTemp();
const unwrap_op: reg_opcode.Op = if (want_ok == 1) .get_throw_ok else .get_throw_err;
try fc.chunk.writeABC(unwrap_op, @intCast(inner_vreg & 0xFF), @intCast(scrut_vreg & 0xFF), 0, loc);
try emitPatternTest(fc, ctor.patterns[0], inner_vreg, fail_jumps, loc);
return;
}
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
var left_fails = std.ArrayListUnmanaged(usize).empty;
defer left_fails.deinit(fc.allocator);
try emitPatternTest(fc, or_pat.left, scrut_vreg, &left_fails, loc);
const success_jump = try fc.chunk.emitJump(.jump, 0, loc);
for (left_fails.items) |fj| fc.chunk.patchJump(fj, fc.chunk.here());
try emitPatternTest(fc, or_pat.right, scrut_vreg, fail_jumps, loc);
fc.chunk.patchJump(success_jump, fc.chunk.here());
},
.record => |rec| {
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
/// 将模式中的字面量（int/float/bool/char/string）转为常量索引，用于模式匹配测试。
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
/// 编译 lambda 表达式：创建子函数编译器，捕获 upvalue 后生成 closure 指令。
fn emitLambda(fc: *RegFnCompiler, lam: anytype, loc: ast.SourceLocation) !reg_alloc.VReg {
if (lam.params.len > 254) return error.Unsupported;
const m = fc.module orelse return error.Unsupported;
var ptypes: []?[]const u8 = &.{};
if (lam.params.len > 0) {
ptypes = m.allocator.alloc(?[]const u8, lam.params.len) catch return error.OutOfMemory;
for (lam.params, 0..) |p, i| {
ptypes[i] = paramTypeName(p.type_annotation);
}
}
const placeholder_idx: u16 = @intCast(m.program.functions.items.len);
try m.program.functions.append(m.allocator, .{
.chunk = reg_chunk.RegChunk.init(m.allocator),
.arity = @intCast(lam.params.len),
.name = "<lambda>",
.param_types = ptypes,
});
var sub = RegFnCompiler.init(fc.allocator);
sub.enclosing = fc;
sub.module = fc.module;
sub.name = "<lambda>";
sub.arity = @intCast(lam.params.len);
defer sub.deinit();
for (lam.params) |p| {
_ = try sub.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
}
const body_expr = switch (lam.body) {
.block => |b| b,
.expression => |e| e,
};
try emitTailExpr(&sub, body_expr, loc);
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
const dst = fc.newTemp();
try fc.chunk.writeABx(.closure, @intCast(dst & 0xFF), placeholder_idx, loc);
return dst;
}
/// 编译内联 trait 值：为每个方法生成闭包并以 make_trait 打包。
fn emitInlineTraitValue(fc: *RegFnCompiler, methods: []const ast.MethodDecl, loc: ast.SourceLocation) CompileError!reg_alloc.VReg {
const m = fc.module orelse return error.Unsupported;
if (methods.len == 0 or methods.len > 127) return error.Unsupported;
const dst = fc.newTemp();
const method_base = fc.newTemp();
_ = method_base;
for (0..methods.len * 2 - 1) |_| _ = fc.newTemp();
for (methods, 0..) |md, i| {
if (md.body == null) return error.Unsupported;
const name_vreg = dst + 1 + i * 2;
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, md.name));
try fc.chunk.writeABx(.load_const, @intCast(name_vreg & 0xFF), name_k, loc);
const closure_vreg = dst + 1 + i * 2 + 1;
if (md.params.len > 254) return error.Unsupported;
const placeholder_idx: u16 = @intCast(m.program.functions.items.len);
try m.program.functions.append(m.allocator, .{
.chunk = reg_chunk.RegChunk.init(m.allocator),
.arity = @intCast(md.params.len),
.name = md.name,
});
var sub = RegFnCompiler.init(fc.allocator);
sub.enclosing = fc;
sub.module = fc.module;
sub.name = md.name;
sub.arity = @intCast(md.params.len);
defer sub.deinit();
for (md.params) |p| {
_ = try sub.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
}
try emitTailExpr(&sub, md.body.?, loc);
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
try fc.chunk.writeABx(.closure, @intCast(closure_vreg & 0xFF), placeholder_idx, loc);
}
try fc.chunk.writeABC(.make_trait, @intCast(dst & 0xFF), @intCast(methods.len & 0xFF), 0, loc);
return dst;
}
/// 编译语句：声明、表达式、return、循环、break/continue、赋值、throw、defer。
/// 声明语句先检查死代码分析结果，循环语句先尝试展开与不变量提升。
pub fn emitStmt(fc: *RegFnCompiler, stmt: *const ast.Stmt) CompileError!void {
const loc = stmt.getLocation();
switch (stmt.*) {
.val_decl => |vd| {
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
/// 编译 val 声明：lambda 值走 letrec 绑定路径，数值类型做强制转换后 bind。
fn emitValDecl(fc: *RegFnCompiler, name: []const u8, type_ann: ?*const ast.TypeNode, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
const tname = paramTypeName(type_ann);
const m = fc.module;
var letrec_vreg: ?reg_alloc.VReg = null;
var func_idx_before: ?usize = null;
if (val_expr.* == .lambda and m != null) {
letrec_vreg = try fc.declareLocal(name, false, false, tname);
try fc.chunk.writeABC(.load_unit, @intCast(letrec_vreg.? & 0xFF), 0, 0, loc);
func_idx_before = m.?.program.functions.items.len;
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
_ = try fc.declareLocal(name, false, false, tname);
const local_vreg = fc.resolveLocal(name).?;
try fc.chunk.writeABC(.bind, @intCast(local_vreg & 0xFF), @intCast(rhs_vreg & 0xFF), 0, loc);
}
}
/// 编译 var 声明：与 emitValDecl 类似，但局部标记 is_var=true。
fn emitVarDecl(fc: *RegFnCompiler, name: []const u8, type_ann: ?*const ast.TypeNode, val_expr: *const ast.Expr, loc: ast.SourceLocation) !void {
const tname = paramTypeName(type_ann);
const m = fc.module;
var letrec_vreg: ?reg_alloc.VReg = null;
var func_idx_before: ?usize = null;
if (val_expr.* == .lambda and m != null) {
letrec_vreg = try fc.declareLocal(name, true, false, tname);
try fc.chunk.writeABC(.load_unit, @intCast(letrec_vreg.? & 0xFF), 0, 0, loc);
func_idx_before = m.?.program.functions.items.len;
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
/// 编译 return 语句：有值时先尝试尾调用优化，无值时发出 return_unit。
fn emitReturn(fc: *RegFnCompiler, val_expr: ?*const ast.Expr, loc: ast.SourceLocation) !void {
if (val_expr) |v| {
if (try tryEmitTailCall(fc, v, loc)) return;
const vreg = try emitExpr(fc, v);
try fc.chunk.writeABC(.return_op, @intCast(vreg & 0xFF), 0, 0, loc);
} else {
try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
}
}
/// 尝试将尾位置的直接调用编译为 tail_call 指令以实现尾调用优化。
/// 仅当被调用者是顶层函数且参数数匹配时才生效。
fn tryEmitTailCall(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !bool {
if (expr.* != .call) return false;
const c = expr.call;
if (c.callee.* != .identifier) return false;
const name = c.callee.identifier.name;
if (fc.resolveLocal(name) != null) return false;
const m = fc.module orelse return false;
const func_idx = m.lookupFn(name) orelse return false;
const entry = &m.program.functions.items[func_idx];
if (entry.arity != c.arguments.len) return false;
if (c.arguments.len > 254) return false;
const dst = fc.newTemp();
for (0..c.arguments.len) |_| _ = fc.newTemp();
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
try fc.chunk.writeABx(.tail_call, @intCast(dst & 0xFF), func_idx, loc);
try fc.chunk.writeABC(.return_unit, 0, 0, 0, loc);
return true;
}
/// 编译尾位置表达式：call 尝试尾调用，if/block 递归处理尾位置，其余普通 return。
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
/// 在循环前发出已被分析标记为循环不变量的表达式，缓存到 hoisted_regs。
fn emitHoistedInvariants(fc: *RegFnCompiler, loop_stmt: *const ast.Stmt) !void {
const m = fc.module orelse return;
const db = m.analysis_db orelse return;
var it = db.hoist_table.entries.iterator();
while (it.next()) |entry| {
if (entry.value_ptr.* != loop_stmt) continue;
const expr = entry.key_ptr.*;
if (fc.hoisted_regs.get(expr) != null) continue;
const vreg = try emitExpr(fc, expr);
try fc.hoisted_regs.put(fc.allocator, expr, vreg);
}
}
/// 编译 while 循环：条件假跳出到末尾，循环体末尾回跳到条件检查。
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
const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
try fc.chunk.writesBx(.jump, 0, offset, loc);
fc.chunk.patchJump(exit_jump, fc.chunk.here());
var lc = fc.loops.pop() orelse return error.InvalidJump;
for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
lc.breaks.deinit(fc.allocator);
}
/// 编译 for 循环：用 for_next 推进迭代器，迭代结束跳出到末尾，循环体回跳到迭代检查。
fn emitFor(fc: *RegFnCompiler, var_name: []const u8, iterable: *const ast.Expr, body: *const ast.Expr, loc: ast.SourceLocation) !void {
const iter_vreg = try emitExpr(fc, iterable);
const idx_vreg = fc.newTemp();
const zero_vreg = fc.newTemp();
try fc.chunk.writeABC(.load_null, @intCast(zero_vreg & 0xFF), 0, 0, loc);
try fc.chunk.writeABC(.move, @intCast(idx_vreg & 0xFF), @intCast(zero_vreg & 0xFF), 0, loc);
_ = try fc.declareLocal(var_name, false, false, null);
const var_vreg = fc.resolveLocal(var_name).?;
const loop_start = fc.chunk.here();
try fc.loops.append(fc.allocator, .{
.continue_target = loop_start,
.breaks = .empty,
.defer_depth = 0,
});
try fc.chunk.writeABC(.for_next, @intCast(var_vreg & 0xFF), @intCast(iter_vreg & 0xFF), @intCast(idx_vreg & 0xFF), loc);
const exit_jump = try fc.chunk.emitJump(.jump, 0, loc);
_ = try emitExpr(fc, body);
const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
try fc.chunk.writesBx(.jump, 0, offset, loc);
fc.chunk.patchJump(exit_jump, fc.chunk.here());
var lc = fc.loops.pop() orelse return error.InvalidJump;
for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
lc.breaks.deinit(fc.allocator);
}
/// 编译无限循环（loop）：循环体末尾回跳到起点，仅可通过 break 退出。
fn emitLoop(fc: *RegFnCompiler, body: *const ast.Expr, loc: ast.SourceLocation) !void {
const loop_start = fc.chunk.here();
try fc.loops.append(fc.allocator, .{
.continue_target = loop_start,
.breaks = .empty,
.defer_depth = 0,
});
_ = try emitExpr(fc, body);
const offset: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(fc.chunk.here() + 1)));
try fc.chunk.writesBx(.jump, 0, offset, loc);
var lc = fc.loops.pop() orelse return error.InvalidJump;
for (lc.breaks.items) |br| fc.chunk.patchJump(br, fc.chunk.here());
lc.breaks.deinit(fc.allocator);
}
/// 编译 break：发出待回填的跳转指令，地址记录到当前循环上下文的 breaks 列表。
fn emitBreak(fc: *RegFnCompiler, loc: ast.SourceLocation) !void {
if (fc.loops.items.len == 0) return error.InvalidJump;
const idx = try fc.chunk.emitJump(.jump, 0, loc);
try fc.loops.items[fc.loops.items.len - 1].breaks.append(fc.allocator, idx);
}
/// 编译 continue：发出回跳到当前循环 continue_target 的跳转指令。
fn emitContinue(fc: *RegFnCompiler, loc: ast.SourceLocation) !void {
if (fc.loops.items.len == 0) return error.InvalidJump;
const target = fc.loops.items[fc.loops.items.len - 1].continue_target;
const offset: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fc.chunk.here() + 1)));
try fc.chunk.writesBx(.jump, 0, offset, loc);
}
/// 编译赋值：标识符赋值依次尝试局部/upvalue/全局，索引赋值发出 set_index。
fn emitAssignment(fc: *RegFnCompiler, target: *const ast.Expr, val: *const ast.Expr, loc: ast.SourceLocation) !void {
if (target.* == .identifier) {
const name = target.identifier.name;
const val_vreg = try emitExpr(fc, val);
if (fc.inline_param_regs.get(name)) |vreg| {
try fc.chunk.writeABC(.assign, @intCast(vreg & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
return;
}
if (fc.resolveLocal(name)) |local_vreg| {
try fc.chunk.writeABC(.assign, @intCast(local_vreg & 0xFF), @intCast(val_vreg & 0xFF), 0, loc);
} else if (try fc.resolveUpvalueRecursive(name)) |uv_idx| {
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
/// 编译字段赋值：发出 set_field，若对象是局部变量则将修改后的副本写回。
fn emitFieldAssignment(fc: *RegFnCompiler, object: *const ast.Expr, field: []const u8, val: *const ast.Expr, loc: ast.SourceLocation) !void {
const obj_vreg = try emitExpr(fc, object);
const val_vreg = try emitExpr(fc, val);
const name_k = try fc.chunk.addConstant(try value.Value.fromStringBytes(fc.allocator, field));
const dst = fc.newTemp();
try fc.chunk.writeABC(.move, @intCast(dst & 0xFF), @intCast(obj_vreg & 0xFF), 0, loc);
try fc.chunk.writeABC(.set_field, @intCast(dst & 0xFF), @intCast(name_k & 0xFF), @intCast(val_vreg & 0xFF), loc);
if (object.* == .identifier) {
const name = object.identifier.name;
if (fc.resolveLocal(name)) |local_vreg| {
try fc.chunk.writeABC(.assign, @intCast(local_vreg & 0xFF), @intCast(dst & 0xFF), 0, loc);
}
}
}
/// 编译复合赋值（+=/-= 等）：局部变量用 compound_local 单指令，
/// upvalue 先取值再做算术后写回，内联参数用分离的算术+assign。
fn emitCompoundAssignment(fc: *RegFnCompiler, target: *const ast.Expr, op: ast.CompoundAssignOp, val: *const ast.Expr, loc: ast.SourceLocation) !void {
const val_vreg = try emitExpr(fc, val);
if (target.* == .identifier) {
const name = target.identifier.name;
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
/// 编译 throw 语句：发出 throw_op 指令。
fn emitThrow(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !void {
const vreg = try emitExpr(fc, expr);
try fc.chunk.writeABC(.throw_op, @intCast(vreg & 0xFF), 0, 0, loc);
}
/// 编译 defer 语句：在当前编译上下文中内联执行延迟表达式（VM 层无独立 defer 栈）。
fn emitDefer(fc: *RegFnCompiler, expr: *const ast.Expr, loc: ast.SourceLocation) !void {
_ = try emitExpr(fc, expr);
_ = loc;
}
/// ADT 构造器条目，记录构造器名、全局索引与参数数。
const CtorEntry = struct {
name: []const u8,
idx: u16,
arity: u8,
};
/// 待编译的方法条目，缓存方法声明与已分配的函数索引。
const PendingMethod = struct {
method: ast.MethodDecl,
func_idx: u16,
};
/// 模块值条目，记录模块导出的函数名列表与子模块名列表。
const ModuleEntry = struct {
exported_fns: [][]const u8,
submodules: [][]const u8,
};
/// 模块级编译器，管理整个模块的函数表、构造器表、全局变量表与分析数据。
/// 负责注册声明、收集模块信息、编译函数体与方法体、生成全局初始化函数。
pub const RegModuleCompiler = struct {
program: reg_chunk.RegProgram,
allocator: std.mem.Allocator,
fn_map: std.StringHashMap(u16),
ctor_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
ctor_map: std.StringHashMap(u16),
newtype_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
newtype_map: std.StringHashMap(u16),
error_table: std.ArrayListUnmanaged(CtorEntry) = .empty,
error_map: std.StringHashMap(u16),
pending_methods: std.ArrayListUnmanaged(PendingMethod) = .empty,
analysis_db: ?*const analysis_db_mod.AnalysisDB = null,
next_memo_slot: u16 = 0,
fn_asts: std.StringHashMapUnmanaged(FnAstEntry) = .{},
global_map: std.StringHashMapUnmanaged(u16) = .{},
pending_global_init: std.ArrayListUnmanaged(GlobalInitEntry) = .empty,
module_map: std.StringHashMapUnmanaged(ModuleEntry) = .{},
    /// 初始化模块编译器，创建空程序与各查找表。
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
    /// 释放所有函数表、构造器表、全局变量表与模块映射持有的资源。
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
}
    /// 按名查找函数索引。
    pub fn lookupFn(self: *RegModuleCompiler, name: []const u8) ?u16 {
return self.fn_map.get(name);
}
    /// 按名查找全局变量索引。
    pub fn lookupGlobal(self: *const RegModuleCompiler, name: []const u8) ?u16 {
return self.global_map.get(name);
}
    /// 按名查找 ADT 构造器条目。
    pub fn lookupCtor(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
if (self.ctor_map.get(name)) |idx| return self.ctor_table.items[idx];
return null;
}
    /// 按名查找 newtype 构造器条目。
    pub fn lookupNewtype(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
if (self.newtype_map.get(name)) |idx| return self.newtype_table.items[idx];
return null;
}
    /// 按名查找错误构造器条目。
    pub fn lookupError(self: *RegModuleCompiler, name: []const u8) ?CtorEntry {
if (self.error_map.get(name)) |idx| return self.error_table.items[idx];
return null;
}
    /// 按名查找模块值条目（导出函数与子模块列表）。
    pub fn lookupModule(self: *const RegModuleCompiler, name: []const u8) ?ModuleEntry {
return self.module_map.get(name);
}
    /// 内建 throw 构造器枚举（Ok/Error）。
    pub const BuiltinThrowCtor = enum { ok, err };

    /// 判断名称是否为内建 throw 构造器 Ok 或 Error。
    pub fn lookupBuiltinThrowCtor(name: []const u8) ?BuiltinThrowCtor {
if (name.len == 2 and name[0] == 'O' and name[1] == 'k') return .ok;
if (name.len == 5 and name[0] == 'E' and name[1] == 'r' and name[2] == 'r' and name[3] == 'o' and name[4] == 'r') return .err;
return null;
}
    /// 查询分析数据库判断函数是否为纯函数（无副作用）。
    pub fn isPureFn(self: *const RegModuleCompiler, name: []const u8) bool {
if (self.analysis_db) |db| return db.purity.isPure(name);
return false;
}
    /// 查询 if 表达式的分支可达性信息（恒真/恒假/运行时）。
    pub fn branchInfo(self: *const RegModuleCompiler, if_expr: *const ast.Expr) ?analysis_db_mod.BranchInfo {
if (self.analysis_db) |db| return db.branch_reach.lookup(if_expr);
return null;
}
    /// 查询循环语句的不变量分析信息（是否小循环、可展开等）。
    pub fn loopInfo(self: *const RegModuleCompiler, stmt: *const ast.Stmt) ?analysis_db_mod.LoopInfo {
if (self.analysis_db) |db| return db.loop_invariant.lookup(stmt);
return null;
}
    /// 查询表达式的常量传播结果（编译期已知值）。
    pub fn constValue(self: *const RegModuleCompiler, expr: *const ast.Expr) ?analysis_db_mod.ConstValue {
if (self.analysis_db) |db| return db.const_prop.lookup(expr);
return null;
}
    /// 查询表达式所属的循环语句（用于循环不变量提升）。
    pub fn hoistInfo(self: *const RegModuleCompiler, expr: *const ast.Expr) ?*const ast.Stmt {
if (self.analysis_db) |db| return db.hoist_table.lookup(expr);
return null;
}
    /// 查询声明语句是否被死代码分析标记为死代码。
    pub fn isDeadDecl(self: *const RegModuleCompiler, stmt: *const ast.Stmt) bool {
if (self.analysis_db) |db| return db.dead_code.isDead(stmt);
return false;
}
    /// 查询表达式的 CSE 规范代表（等价表达式组中的唯一代表）。
    pub fn cseCanonical(self: *const RegModuleCompiler, expr: *const ast.Expr) ?*const ast.Expr {
if (self.analysis_db) |db| return db.cse.canonicalOf(expr);
return null;
}
    /// 判断表达式是否为其 CSE 等价组的规范代表。
    pub fn isCseCanonical(self: *const RegModuleCompiler, expr: *const ast.Expr) bool {
if (self.analysis_db) |db| return db.cse.isCanonical(expr);
return false;
}
    /// 为纯函数分配或返回已有的记忆化槽位索引，非纯函数返回 null。
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
    /// 注册 ADT 构造器包装函数：将参数收集后发出 make_adt 并返回。
    fn regCtorWrapperFunc(self: *RegModuleCompiler, ctor_idx: u16, arity: u8, name: []const u8, loc: ast.SourceLocation) CompileError!u16 {
const idx: u16 = @intCast(self.program.functions.items.len);
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
var i: u8 = 0;
while (i < arity) : (i += 1) {
_ = try fc.declareLocal("", false, false, null);
}
const dst = fc.newTemp();
for (0..arity) |j| {
try fc.chunk.writeABC(.move, @intCast((dst + 1 + j) & 0xFF), @intCast(j & 0xFF), 0, loc);
}
try fc.chunk.writeABC(.make_adt, @intCast(dst & 0xFF), @intCast(ctor_idx & 0xFF), arity, loc);
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
    /// 注册 newtype 包装函数：将单个参数包装为 newtype 值并返回。
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
    /// 编译模块及其依赖：先注册所有声明，再收集模块信息，然后编译函数体，
    /// 最后生成全局初始化函数并运行优化器。
    pub fn compileModuleWithDeps(self: *RegModuleCompiler, module: *const ast.Module, deps: []const ast.Module) CompileError!void {
for (deps) |*dep| try self.registerDecls(dep);
try self.registerDecls(module);
try self.collectModules(deps, module);
for (deps) |*dep| try self.compileBodies(dep);
try self.compileBodies(module);
try self.compileGlobalsInit();
_ = try reg_optimizer.optimizeProgram(&self.program, self.allocator);
}
    /// 收集依赖模块与主模块的导出信息。
    fn collectModules(self: *RegModuleCompiler, deps: []const ast.Module, module: *const ast.Module) CompileError!void {
for (deps) |*dep| try self.collectOneModule(dep);
try self.collectOneModule(module);
}
    /// 收集单个模块的导出函数名与子模块名，存入 module_map。
    fn collectOneModule(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
if (module.name.len == 0) return;
if (self.module_map.contains(module.name)) return;
var exported = std.ArrayListUnmanaged([]const u8).empty;
defer exported.deinit(self.allocator);
var submods = std.ArrayListUnmanaged([]const u8).empty;
defer submods.deinit(self.allocator);
for (module.declarations) |decl| {
switch (decl) {
.fun_decl => |fd| {
if (fd.visibility == .public) {
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
    /// 注册模块中的所有声明：函数、ADT 构造器、newtype、错误类型、trait 方法与全局变量。
    /// 为每个声明分配函数索引或全局索引，并将方法体加入待编译队列。
    fn registerDecls(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
for (module.declarations) |decl| {
switch (decl) {
.fun_decl => |fd| {
if (self.fn_map.contains(fd.name)) continue;
const idx: u16 = @intCast(self.program.functions.items.len);
try self.fn_map.put(fd.name, idx);
if (fd.is_entry) self.program.entry = idx;
try self.fn_asts.put(self.allocator, fd.name, .{
.body = fd.body,
.params = fd.params,
});
var ptypes: []?[]const u8 = &.{};
if (fd.params.len > 0) {
ptypes = self.program.allocator.alloc(?[]const u8, fd.params.len) catch return error.OutOfMemory;
for (fd.params, 0..) |p, i| {
ptypes[i] = paramTypeName(p.type_annotation);
}
}
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
var prefix: []const u8 = ERROR_DEFAULT_PREFIX;
for (en.methods) |m| {
if (method_mod.MethodId.fromName(m.name) == .prefix) {
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
if (td.def != .error_newtype) {
for (td.methods) |m| {
if (m.body == null) continue;
const idx: u16 = @intCast(self.program.functions.items.len);
try self.program.functions.append(self.allocator, .{
.chunk = reg_chunk.RegChunk.init(self.allocator),
.arity = @intCast(m.params.len),
.name = m.name,
});
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
try self.pending_global_init.append(self.allocator, .{
.is_var_decl = false,
.init_expr = ed.expr,
.stmt = stmt,
.loc = ed.location,
});
},
}
} else {
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
    /// 编译所有方法体与函数体：先编译 pending_methods 中的方法，再编译模块级函数。
    fn compileBodies(self: *RegModuleCompiler, module: *const ast.Module) CompileError!void {
for (self.pending_methods.items) |pm| {
try self.compileMethodBody(pm.method, pm.func_idx);
}
for (module.declarations) |decl| {
switch (decl) {
.fun_decl => |fd| try self.compileFunction(fd),
else => {},
}
}
}
    /// 编译方法体：声明参数为局部变量，编译函数体为尾位置表达式，设置寄存器数与释放掩码。
    fn compileMethodBody(self: *RegModuleCompiler, m: ast.MethodDecl, func_idx: u16) CompileError!void {
const body = m.body orelse return;
var fc = RegFnCompiler.init(self.allocator);
fc.module = self;
fc.name = m.name;
fc.arity = @intCast(m.params.len);
defer fc.deinit();
for (m.params) |p| {
_ = try fc.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
}
const loc = m.location;
emitTailExpr(&fc, body, loc) catch |err| {
return err;
};
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
    /// 编译函数体：声明参数为局部变量，编译函数体为尾位置表达式，设置寄存器数与释放掩码。
    fn compileFunction(self: *RegModuleCompiler, fd: anytype) CompileError!void {
var fc = RegFnCompiler.init(self.allocator);
fc.module = self;
fc.name = fd.name;
fc.arity = @intCast(fd.params.len);
defer fc.deinit();
for (fd.params) |p| {
_ = try fc.declareLocal(p.name, p.is_var, false, paramTypeName(p.type_annotation));
}
const loc = fd.location;
emitTailExpr(&fc, fd.body, loc) catch |err| {
return err;
};
const idx = self.lookupFn(fd.name).?;
self.program.functions.items[idx].chunk.deinit();
self.program.functions.items[idx].chunk = fc.chunk;
self.program.functions.items[idx].arity = @intCast(fd.params.len);
self.program.functions.items[idx].register_count = @intCast(fc.next_vreg);
const nreg_raw: u32 = @intCast(@min(fc.next_vreg, 64));
if (nreg_raw >= 64) {
self.program.functions.items[idx].release_mask = ~@as(u64, 0);
} else if (nreg_raw > 0) {
self.program.functions.items[idx].release_mask = (@as(u64, 1) << @intCast(nreg_raw)) - 1;
}
fc.chunk = reg_chunk.RegChunk.init(self.allocator);
}
    /// 编译全局初始化函数：逐条编译待初始化的全局变量声明与表达式语句，
    /// 数值类型做强制转换后 store_global，生成 $globals_init 函数。
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
try emitStmt(&fc, stmt);
} else {
_ = try emitExpr(&fc, entry.init_expr);
}
}
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
