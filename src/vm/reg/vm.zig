//! 寄存器 VM 执行引擎。
//!
//! 负责执行 RegProgram 字节码：指令分发、寄存器管理、帧栈维护、
//! 全局变量初始化、方法分派、内建函数调用、类型转换、算术/比较运算、
//! 通道与 spawn 操作、异常传播以及纯函数记忆化缓存。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");
const profiler_mod = @import("profiler");
const slab_allocator = @import("slab_allocator");
const shared = @import("shared");
const jit_mod = @import("jit");
const opcode = shared.native_mod;
const cast = shared.cast_mod;
const method = shared.method_mod;

/// VM 执行期间可能产生的错误集合。
pub const VMError = error{
OutOfMemory,
TypeMismatch,
WrongArity,
NoSuchMethod,
NoSuchFunction,
DivisionByZero,
ArithmeticOverflow,
InvalidInstruction,
InvalidJump,
ChannelClosed,
StackOverflow,
InvalidSpawn,
InvalidUpvalue,
Unsupported,
} || std.mem.Allocator.Error;
/// 寄存器池初始大小（64K 个 Value 槽位）。
const REG_POOL_INITIAL: usize = 64 * 1024;

/// 寄存器池最大大小（1M 个 Value 槽位），超出则报 StackOverflow。
const REG_POOL_MAX: usize = 1024 * 1024;

/// 最大调用帧数（64K），超出则报 StackOverflow。
const MAX_FRAMES: usize = 64 * 1024;

/// JIT 桥接嵌套深度上限：超过此值时跳过 JIT 快速路径，回退到解释器。
/// 每层桥接约消耗 2-3KB 原生栈，上限 50 层 ≈ 150KB，远低于 8MB 栈限制。
const BRIDGE_DEPTH_LIMIT: u32 = 50;

/// 记忆化槽位"无"标记值。
const MEMO_SLOT_NONE: u16 = 0xFFFF;

const type_names = ast.type_names;

/// 调用帧，记录当前函数、指令指针、寄存器基址、upvalue 与返回信息。
const RegFrame = struct {
func: *const reg_chunk.RegFunction,
ip: usize,
base: usize,
upvalues: []value.Value,
memo_slot: u16,
memo_arg_hash: u64,
return_base: usize,
return_reg: u8,
};
/// 记忆化缓存键，由槽位号与参数哈希组合而成。
const MemoKey = struct {
slot: u16,
arg_hash: u64,
};
/// 返回 Value 对应的类型名称字符串，用于错误报告与类型检查。
fn regValueTypeName(val: value.Value) []const u8 {
return switch (val) {
.int => @tagName(val.asInt().type),
.float => @tagName(val.asFloat().type),
.boolean => "bool",
.char => "char",
.string => "str",
.null_val => "null",
.unit => "unit",
.array => "array",
.record => "record",
.adt => val.adt.type_name,
.newtype => val.newtype.type_name,
.range => "range",
.error_val => val.error_val.type_name,
.throw_val => "Throw",
.partial => "partial",
.array_iterator => "array_iterator",
.string_iterator => "string_iterator",
.range_iterator => "range_iterator",
.atomic_val => "Atomic",
.spawn_val => "Spawn",
.channel_val => "Channel",
.sender_val => "Sender",
.receiver_val => "Receiver",
.trait_value => blk: {
const tv = val.trait_value;
break :blk if (tv.trait_name.len > 0) tv.trait_name else "trait";
},
.lazy_val => "Lazy",
.cell => regValueTypeName(val.cell.inner),
.builtin, .vm_closure => "function",
};
}
/// 结构化相等比较，委托到 value.equals。
fn regStructuralEquals(a: value.Value, b: value.Value) bool {
return value.equals(a, b);
}
/// 判断值是否为标量（无需引用计数的内联值）。
/// 标量值的 release/retain 为空操作，可直接覆写无需引用计数维护。
inline fn isScalarValue(v: value.Value) bool {
return switch (v) {
.null_val, .unit, .boolean, .char, .int, .float => true,
else => false,
};
}
/// i64 同类型算术快速路径：若两个操作数都是 i64 整数则直接原生运算，
/// 返回结果 Value；溢出/除零/非 i64 返回 null，由调用方回退到 doArith。
inline fn fastI64Arith(op: reg_opcode.Op, lv: value.Value, rv: value.Value) ?value.Value {
if (lv != .int or rv != .int) return null;
if (lv.int.type != .i64 or rv.int.type != .i64) return null;
const li = @as(i64, @bitCast(lv.int.lo));
const ri = @as(i64, @bitCast(rv.int.lo));
return switch (op) {
.add => blk: {
const r = @addWithOverflow(li, ri);
if (r[1] != 0) break :blk null;
break :blk value.Value.fromInt(value.Int.fromNative(.i64, r[0]));
},
.sub => blk: {
const r = @subWithOverflow(li, ri);
if (r[1] != 0) break :blk null;
break :blk value.Value.fromInt(value.Int.fromNative(.i64, r[0]));
},
.mul => blk: {
const r = @mulWithOverflow(li, ri);
if (r[1] != 0) break :blk null;
break :blk value.Value.fromInt(value.Int.fromNative(.i64, r[0]));
},
.div => if (ri == 0) null else value.Value.fromInt(value.Int.fromNative(.i64, @divTrunc(li, ri))),
.mod => if (ri == 0) null else value.Value.fromInt(value.Int.fromNative(.i64, @rem(li, ri))),
.bit_and => value.Value.fromInt(value.Int.fromNative(.i64, li & ri)),
.bit_or => value.Value.fromInt(value.Int.fromNative(.i64, li | ri)),
.bit_xor => value.Value.fromInt(value.Int.fromNative(.i64, li ^ ri)),
else => null,
};
}
/// i64 同类型比较快速路径：若两个操作数都是 i64 整数则直接原生比较，
/// 返回布尔 Value；非 i64 返回 null，由调用方回退到 doCompare。
inline fn fastI64Compare(op: reg_opcode.Op, lv: value.Value, rv: value.Value) ?value.Value {
if (lv != .int or rv != .int) return null;
if (lv.int.type != .i64 or rv.int.type != .i64) return null;
const li = @as(i64, @bitCast(lv.int.lo));
const ri = @as(i64, @bitCast(rv.int.lo));
return switch (op) {
.eq => value.Value.fromBool(li == ri),
.neq => value.Value.fromBool(li != ri),
.lt => value.Value.fromBool(li < ri),
.gt => value.Value.fromBool(li > ri),
.le => value.Value.fromBool(li <= ri),
.ge => value.Value.fromBool(li >= ri),
else => null,
};
}
/// i64 取反快速路径：若操作数是 i64 则直接原生取反，
/// 最小值取反溢出或非 i64 返回 null。
inline fn fastI64Negate(v: value.Value) ?value.Value {
if (v != .int or v.int.type != .i64) return null;
const vi = @as(i64, @bitCast(v.int.lo));
if (vi == std.math.minInt(i64)) return null;
return value.Value.fromInt(value.Int.fromNative(.i64, -vi));
}
/// 寄存器 VM 主体，管理寄存器池、调用帧栈、全局变量、记忆化缓存与内联缓存。
pub const RegVM = struct {
allocator: std.mem.Allocator,
reg_pool: []value.Value,
frames: std.ArrayListUnmanaged(RegFrame) = .empty,
program: ?*const reg_chunk.RegProgram = null,
globals: std.ArrayListUnmanaged(value.Value) = .empty,
ic_slots: std.ArrayListUnmanaged(IcSlot) = .empty,
memo_cache: std.AutoHashMapUnmanaged(MemoKey, value.Value) = .empty,
memo_slot_misses: std.AutoHashMapUnmanaged(u16, u32) = .empty,
memo_disabled_slots: std.AutoHashMapUnmanaged(u16, void) = .empty,
profiler: ?*profiler_mod.Profiler = null,
jit_engine: ?jit_mod.JitEngine = null,
err_msg: ?[]const u8 = null,
err_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
stop_depth: usize = 0,
io: ?std.Io = null,
// ── JIT 桥接：单步执行支持 ──
/// 单步模式标志：为 true 时 runLoop 执行一条指令后返回。
single_step: bool = false,
/// 当前 runLoop 调用中已执行的指令数（用于单步模式判断）。
step_count: u32 = 0,
/// 单步返回时，函数是否真正返回（frames < stop_depth）。
step_did_return: bool = false,
/// JIT 桥接嵌套深度：callBridge 调用时递增，返回时递减。
/// 超过阈值时跳过 JIT 快速路径，避免原生栈溢出。
bridge_depth: u32 = 0,
/// 内联缓存槽，缓存方法分派的类型标签与方法 ID 以加速后续调用。
const IcSlot = struct {
cached_tag: u8 = 0,
method_id: u8 = 0,
is_builtin: bool = false,
};
/// 初始化 VM，分配初始寄存器池并填充为 null。
pub fn init(allocator: std.mem.Allocator) RegVM {
const pool = allocator.alloc(value.Value, REG_POOL_INITIAL) catch unreachable;
@memset(pool, value.Value.fromNull());
return .{
.allocator = allocator,
.reg_pool = pool,
};
}
/// 扩容寄存器池至 needed，最大不超过 REG_POOL_MAX，新增部分填充为 null。
fn ensureCapacity(self: *RegVM, needed: usize) VMError!void {
if (needed <= self.reg_pool.len) return;
if (needed > REG_POOL_MAX) return error.StackOverflow;
const new_len = @min(needed * 2, REG_POOL_MAX);
const new_pool = self.allocator.realloc(self.reg_pool, new_len) catch return error.OutOfMemory;
@memset(new_pool[self.reg_pool.len..], value.Value.fromNull());
self.reg_pool = new_pool;
}
/// 初始化 VM 并绑定 I/O 上下文（用于文件操作等）。
pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) RegVM {
var vm = init(allocator);
vm.io = io;
return vm;
}
/// 初始化 VM，使用线程缓存的分配器并绑定 I/O 上下文。
pub fn initWithCache(cache: *slab_allocator.ThreadCache, io: std.Io) RegVM {
var vm = init(cache.allocator());
vm.io = io;
return vm;
}
/// 绑定性能分析器实例。
pub fn setProfiler(self: *RegVM, p: *profiler_mod.Profiler) void {
self.profiler = p;
}
/// 启用 JIT 编译引擎，后续热点函数将自动编译为原生机器码。
pub fn enableJit(self: *RegVM) void {
    self.jit_engine = jit_mod.JitEngine.init(self.allocator);
}
/// 释放寄存器池、帧栈、全局变量、内联缓存与记忆化缓存。
pub fn deinit(self: *RegVM) void {
self.allocator.free(self.reg_pool);
self.frames.deinit(self.allocator);
self.globals.deinit(self.allocator);
self.ic_slots.deinit(self.allocator);
self.memo_cache.deinit(self.allocator);
self.memo_slot_misses.deinit(self.allocator);
self.memo_disabled_slots.deinit(self.allocator);
if (self.jit_engine) |*je| je.deinit();
}
// ── JIT 桥接接口 ──
/// JIT 单步执行：执行当前帧的一条指令。
/// 调用前需确保 frame.ip 指向待执行指令。
/// 返回 null 表示指令已执行、函数未返回；
/// 返回 Value 表示函数已返回（该值为返回值）。
pub fn jitStepOnce(self: *RegVM) VMError!?value.Value {
// 保存外层 runLoop 的单步状态（callBridge 可能重入 runLoop）
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
self.single_step = true;
self.step_count = 0;
self.step_did_return = false;
const result = try self.runLoop();
const did_return = self.step_did_return;
// 恢复外层状态
self.single_step = saved_single_step;
self.step_count = saved_step_count;
if (did_return) return result;
return null;
}
/// JIT 桥接：运行主循环直到帧栈回退到 stop_depth 以下。
/// 供 rt_step 在被调用函数需要运行至完成时调用。
/// 保存并清除单步状态，确保 runLoop 能正常运行至完成。
pub fn jitRunLoop(self: *RegVM) VMError!value.Value {
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
self.single_step = false;
self.step_count = 0;
defer {
    self.single_step = saved_single_step;
    self.step_count = saved_step_count;
}
return try self.runLoop();
}
/// JIT 调用任意函数（JIT 编译或解释执行）。
/// 设置新帧并运行，返回函数结果。
/// return_base/return_reg 记录在帧中供 VM 内部返回路径使用；
/// 当被调用函数返回导致 runLoop 退出时，结果通过返回值传递（不写回 return 槽位）。
pub fn jitCallFunction(self: *RegVM, func_idx: u32, args: []const value.Value, return_base: usize, return_reg: u8) VMError!value.Value {
if (self.program == null) return error.InvalidInstruction;
const program = self.program.?;
if (func_idx >= program.functions.items.len) return error.NoSuchFunction;
const callee = &program.functions.items[func_idx];
const saved_stop = self.stop_depth;
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
defer self.stop_depth = saved_stop;
defer self.single_step = saved_single_step;
defer self.step_count = saved_step_count;
self.single_step = false;
self.step_count = 0;
try self.setupFrame(callee, args, return_base, return_reg);
self.stop_depth = self.frames.items.len;
return try self.runLoop();
}
/// 调用程序入口函数：先执行全局初始化函数，再设置入口帧并运行主循环。
pub fn call(self: *RegVM, program: *const reg_chunk.RegProgram, entry: u16, args: []const value.Value) VMError!value.Value {
self.program = program;
// 绑定函数列表到 JIT 引擎（用于 call_memoized/tail_call 的 callee 查找）
if (self.jit_engine) |*je| {
je.setFunctions(program.functions.items);
}
if (program.globals_init) |gi| {
try self.globals.resize(self.allocator, program.global_count);
@memset(self.globals.items, value.Value.fromNull());
try self.setupFrame(&program.functions.items[gi], &.{}, 0, 0);
self.stop_depth = 1;
_ = try self.runLoop();
}
const func = &program.functions.items[entry];
try self.setupFrame(func, args, 0, 0);
self.stop_depth = self.frames.items.len;
return try self.runLoop();
}
/// 设置新调用帧：计算寄存器基址（前一帧基址 + 寄存器数），
/// 拷贝参数到参数寄存器，剩余寄存器填充为 unit，压入帧栈。
pub fn setupFrame(self: *RegVM, func: *const reg_chunk.RegFunction, args: []const value.Value, return_base: usize, return_reg: u8) VMError!void {
if (self.frames.items.len >= MAX_FRAMES) return error.StackOverflow;
const base = if (self.frames.items.len == 0) 0 else blk: {
const prev = &self.frames.items[self.frames.items.len - 1];
break :blk prev.base + prev.func.register_count;
};
if (base + func.register_count > self.reg_pool.len) {
try self.ensureCapacity(base + func.register_count);
}
for (args, 0..) |a, i| {
if (i >= func.arity) break;
self.reg_pool[base + i] = a.retain();
}
var i: usize = func.arity;
while (i < func.register_count) : (i += 1) {
self.reg_pool[base + i] = value.Value.fromUnit();
}
try self.frames.append(self.allocator, .{
.func = func,
.ip = 0,
.base = base,
.upvalues = &.{},
.memo_slot = MEMO_SLOT_NONE,
.memo_arg_hash = 0,
.return_base = return_base,
.return_reg = return_reg,
});
}
/// 为记忆化缓存计算参数哈希：仅对基本类型（null/unit/bool/char/int/float/string）计算，
/// 含复合类型的参数返回 null 表示不可记忆化。
fn hashArgsForMemo(args: []const value.Value) ?u64 {
var hasher = std.hash.Wyhash.init(0);
for (args) |a| {
switch (a) {
.null_val => hasher.update(&[_]u8{0}),
.unit => hasher.update(&[_]u8{1}),
.boolean => |b| hasher.update(&[_]u8{ if (b) 2 else 3 }),
.char => |c| {
hasher.update(&[_]u8{4});
var cp_bytes: [4]u8 = undefined;
std.mem.writeInt(u32, &cp_bytes, c.codepoint, .little);
hasher.update(&cp_bytes);
},
.int => |i| {
hasher.update(&[_]u8{5});
hasher.update(&[_]u8{@intFromEnum(i.type)});
var lo_bytes: [8]u8 = undefined;
var hi_bytes: [8]u8 = undefined;
std.mem.writeInt(u64, &lo_bytes, i.lo, .little);
std.mem.writeInt(u64, &hi_bytes, i.hi, .little);
hasher.update(&lo_bytes);
hasher.update(&hi_bytes);
},
.float => |f| {
hasher.update(&[_]u8{6});
hasher.update(&[_]u8{@intFromEnum(f.type)});
var b_bytes: [8]u8 = undefined;
var e_bytes: [8]u8 = undefined;
std.mem.writeInt(u64, &b_bytes, f.bits, .little);
std.mem.writeInt(u64, &e_bytes, f.extra, .little);
hasher.update(&b_bytes);
hasher.update(&e_bytes);
},
.string => |s| {
hasher.update(&[_]u8{7});
hasher.update(s.bytes());
},
else => return null,
}
}
return hasher.final();
}
/// 主指令分发循环：逐条取指、解码并执行，直到帧栈回退到 stop_depth 以下。
/// 涵盖所有 opcode 的运行时语义：加载/存储、算术/比较、跳转、调用/返回、
/// 构造/访问、通道操作、异常处理、记忆化与尾调用等。
fn runLoop(self: *RegVM) VMError!value.Value {
@setEvalBranchQuota(20000);
var result: value.Value = value.Value.fromUnit();
while (self.frames.items.len >= self.stop_depth) {
// 单步模式：已执行一条指令，返回（continue 也会到达此处）
if (self.single_step and self.step_count > 0) {
self.single_step = false;
self.step_count = 0;
self.step_did_return = false;
return result;
}
const frame = &self.frames.items[self.frames.items.len - 1];
const func = frame.func;
const code = func.chunk.code.items;
const base = frame.base;
const ip = frame.ip;
if (ip >= code.len) return error.InvalidInstruction;
const inst = code[ip];
const op = reg_opcode.getOp(inst);
if (self.profiler) |p| p.recordOpcode(@intFromEnum(op));
const a = reg_opcode.getA(inst);
const b = reg_opcode.getB(inst);
const c = reg_opcode.getC(inst);
const bx = reg_opcode.getBx(inst);
const sbx = reg_opcode.getsBx(inst);
// loc 延迟解码：57% 的指令不需要 loc，仅在需要错误定位的 case 中调用 func.chunk.locAt(ip)
frame.ip = ip + 1;
self.step_count += 1; // 单步计数（在 switch 前递增，continue 不会绕过）
switch (op) {
.load_const => {
const slot = &self.reg_pool[base + a];
const kv = func.chunk.constants.items[bx];
if (isScalarValue(slot.*) and isScalarValue(kv)) {
slot.* = kv;
} else {
slot.release(self.allocator);
slot.* = kv.retain();
}
},
.load_null => {
const slot = &self.reg_pool[base + a];
if (slot.* == .null_val) {} else if (isScalarValue(slot.*)) {
slot.* = value.Value.fromNull();
} else {
slot.release(self.allocator);
slot.* = value.Value.fromNull();
}
},
.load_unit => {
const slot = &self.reg_pool[base + a];
if (slot.* == .unit) {} else if (isScalarValue(slot.*)) {
slot.* = value.Value.fromUnit();
} else {
slot.release(self.allocator);
slot.* = value.Value.fromUnit();
}
},
.load_true => {
const slot = &self.reg_pool[base + a];
if (slot.* == .boolean and slot.boolean) {} else if (isScalarValue(slot.*)) {
slot.* = value.Value.fromBool(true);
} else {
slot.release(self.allocator);
slot.* = value.Value.fromBool(true);
}
},
.load_false => {
const slot = &self.reg_pool[base + a];
if (slot.* == .boolean and !slot.boolean) {} else if (isScalarValue(slot.*)) {
slot.* = value.Value.fromBool(false);
} else {
slot.release(self.allocator);
slot.* = value.Value.fromBool(false);
}
},
.load_global => {
if (self.globals.items.len <= bx) return error.InvalidInstruction;
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = self.globals.items[bx].retain();
},
.store_global => {
if (self.globals.items.len <= bx) return error.InvalidInstruction;
self.globals.items[bx].release(self.allocator);
self.globals.items[bx] = self.reg_pool[base + a].retain();
},
.move, .bind => {
const dst = &self.reg_pool[base + a];
const src = self.reg_pool[base + b];
if (isScalarValue(dst.*) and isScalarValue(src)) {
dst.* = src;
} else {
dst.release(self.allocator);
dst.* = src.retain();
}
},
.assign => {
const cur = self.reg_pool[base + a];
if (cur == .atomic_val) {
cur.atomic_val.store(unwrapTransparent(self.reg_pool[base + b]));
} else if (cur == .cell and cur.cell.inner == .atomic_val) {
cur.cell.inner.atomic_val.store(unwrapTransparent(self.reg_pool[base + b]));
} else {
const src = self.reg_pool[base + b];
if (isScalarValue(cur) and isScalarValue(src)) {
self.reg_pool[base + a] = src;
} else {
cur.release(self.allocator);
self.reg_pool[base + a] = src.retain();
}
}
},
.move_raw => {
self.reg_pool[base + a] = self.reg_pool[base + b];
},
.bind_letrec => {
const closure_val = self.reg_pool[base + b];
if (closure_val == .vm_closure) {
const cl = closure_val.vm_closure;
if (c < cl.upvalues.len) {
const uv = cl.upvalues[c];
if (uv == .cell) {
uv.cell.inner.release(self.allocator);
uv.cell.inner = closure_val.retain();
}
}
}
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = closure_val.retain();
},
.coerce => {
const src = self.reg_pool[base + b];
const tname = func.chunk.constants.items[c].string.bytes();
const slot = &self.reg_pool[base + a];
if (src.isInteger() or src.isFloat()) {
if (cast.castNumeric(self.allocator, src, tname)) |coerced| {
if (isScalarValue(slot.*)) {
slot.* = coerced;
} else {
slot.release(self.allocator);
slot.* = coerced;
}
} else |_| {
if (isScalarValue(slot.*)) {
slot.* = src;
} else {
slot.release(self.allocator);
slot.* = src.retain();
}
}
} else {
if (isScalarValue(slot.*)) {
slot.* = src;
} else {
slot.release(self.allocator);
slot.* = src.retain();
}
}
},
.add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor => {
const lv = self.reg_pool[base + b];
const rv = self.reg_pool[base + c];
// i64 同类型快速路径：跳过 doArith 函数调用与内部类型分派
const result_val = fastI64Arith(op, lv, rv) orelse blk: {
const loc = func.chunk.locAt(ip);
break :blk try self.doArith(op, lv, rv, loc);
};
const slot = &self.reg_pool[base + a];
if (isScalarValue(slot.*)) {
slot.* = result_val;
} else {
slot.release(self.allocator);
slot.* = result_val;
}
},
.neg => {
const src = self.reg_pool[base + b];
const result_val = fastI64Negate(src) orelse blk: {
const loc = func.chunk.locAt(ip);
break :blk try self.doNegate(src, loc);
};
const slot = &self.reg_pool[base + a];
if (isScalarValue(slot.*)) {
slot.* = result_val;
} else {
slot.release(self.allocator);
slot.* = result_val;
}
},
.eq, .neq, .lt, .gt, .le, .ge => {
const lv = self.reg_pool[base + b];
const rv = self.reg_pool[base + c];
// i64 同类型快速路径：跳过 doCompare 函数调用与内部类型分派
const result_val = fastI64Compare(op, lv, rv) orelse blk: {
const loc = func.chunk.locAt(ip);
break :blk try self.doCompare(op, lv, rv, loc);
};
const slot = &self.reg_pool[base + a];
if (isScalarValue(slot.*)) {
slot.* = result_val;
} else {
slot.release(self.allocator);
slot.* = result_val;
}
},
.not_op => {
const src = self.reg_pool[base + b];
if (src != .boolean) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "logical not expects a bool", error.TypeMismatch);
}
const slot = &self.reg_pool[base + a];
if (isScalarValue(slot.*)) {
slot.* = value.Value.fromBool(!src.boolean);
} else {
slot.release(self.allocator);
slot.* = value.Value.fromBool(!src.boolean);
}
},
.jump => {
const new_ip: i64 = @as(i64, @intCast(frame.ip)) + sbx;
frame.ip = @intCast(new_ip);
},
.jump_if_false => {
const cond = self.reg_pool[base + a];
if (cond != .boolean) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "condition is not a bool", error.TypeMismatch);
}
if (!cond.boolean) {
const new_ip: i64 = @as(i64, @intCast(frame.ip)) + sbx;
frame.ip = @intCast(new_ip);
}
},
.jump_if_true => {
const cond = self.reg_pool[base + a];
if (cond != .boolean) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "condition is not a bool", error.TypeMismatch);
}
if (cond.boolean) {
const new_ip: i64 = @as(i64, @intCast(frame.ip)) + sbx;
frame.ip = @intCast(new_ip);
}
},
.jump_if_null => {
if (self.reg_pool[base + a] == .null_val) {
const new_ip: i64 = @as(i64, @intCast(frame.ip)) + sbx;
frame.ip = @intCast(new_ip);
}
},
.jump_if_not_null => {
if (self.reg_pool[base + a] != .null_val) {
const new_ip: i64 = @as(i64, @intCast(frame.ip)) + sbx;
frame.ip = @intCast(new_ip);
}
},
.call => {
    const func_idx = bx;
    const callee = &self.program.?.functions.items[func_idx];
    const argc = callee.arity;
    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
    // JIT 快速路径：桥接深度超限时跳过，避免原生栈溢出（如深度递归）
    if (self.bridge_depth < BRIDGE_DEPTH_LIMIT) jit_check: {
        const je = &(self.jit_engine orelse break :jit_check);
        if (je.recordCall(@intCast(func_idx))) |cfn| {
            if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
            jit_mod.invokeJit(self, cfn, args_slice, base, a);
            continue;
        } else if (je.shouldCompile(@intCast(func_idx))) {
            if (je.compileFunction(@intCast(func_idx), callee)) |cfn| {
                if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
                jit_mod.invokeJit(self, cfn, args_slice, base, a);
                continue;
            }
        }
    }
    try self.setupFrame(callee, args_slice, base, a);
},
.call_native => {
const nat: opcode.Native = @enumFromInt(b);
const argc: usize = c;
const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
const loc = func.chunk.locAt(ip);
const result_val = try self.doCallNative(nat, argc, args_slice, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.return_op => {
const ret_val = self.reg_pool[base + a].retain();
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
const m_slot = frame.memo_slot;
const m_hash = frame.memo_arg_hash;
if (m_slot != MEMO_SLOT_NONE and ret_val.isMemoizableValue()) {
self.memo_cache.put(self.allocator, .{ .slot = m_slot, .arg_hash = m_hash }, ret_val.retain()) catch {};
}
try self.frameReturn();
// 始终写入返回槽位（break 路径也写），避免 rt_step 桥接时丢失返回值
self.reg_pool[ret_base + ret_reg].release(self.allocator);
self.reg_pool[ret_base + ret_reg] = ret_val;
if (self.frames.items.len < self.stop_depth) {
result = ret_val.retain();
break;
}
},
.return_unit => {
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
const m_slot = frame.memo_slot;
const m_hash = frame.memo_arg_hash;
if (m_slot != MEMO_SLOT_NONE) {
self.memo_cache.put(self.allocator, .{ .slot = m_slot, .arg_hash = m_hash }, value.Value.fromUnit().retain()) catch {};
}
try self.frameReturn();
self.reg_pool[ret_base + ret_reg].release(self.allocator);
self.reg_pool[ret_base + ret_reg] = value.Value.fromUnit();
if (self.frames.items.len < self.stop_depth) {
result = value.Value.fromUnit();
break;
}
},
.release => {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromNull();
},
.cast => {
const src = self.reg_pool[base + b];
const tname = func.chunk.constants.items[c].string.bytes();
const loc = func.chunk.locAt(ip);
const result_val = try self.doCast(src, tname, loc);
const slot = &self.reg_pool[base + a];
if (isScalarValue(slot.*)) {
slot.* = result_val;
} else {
slot.release(self.allocator);
slot.* = result_val;
}
},
.concat_list => {
const left = self.reg_pool[base + b];
const right = self.reg_pool[base + c];
if (left == .array and right == .array) {
const la = left.array.elements;
const ra = right.array.elements;
const elems = self.allocator.alloc(value.Value, la.len + ra.len) catch return error.OutOfMemory;
for (la, 0..) |e, i| elems[i] = e.retain();
for (ra, 0..) |e, i| elems[la.len + i] = e.retain();
const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
arr_ptr.* = .{ .elements = elems, .capacity = elems.len, .fixed_size = null };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
} else if (left == .string and right == .string) {
const ls = left.string.bytes();
const rs = right.string.bytes();
const total = ls.len + rs.len;
const buf = self.allocator.alloc(u8, total) catch return error.OutOfMemory;
@memcpy(buf[0..ls.len], ls);
@memcpy(buf[ls.len..total], rs);
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, buf);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .string = s };
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "operator '++' requires array or string operands", error.TypeMismatch);
}
},
.make_array => {
const n: usize = b;
const elems = self.allocator.alloc(value.Value, n) catch return error.OutOfMemory;
for (0..n) |i| elems[i] = self.reg_pool[base + a + 1 + i].retain();
const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
arr_ptr.* = .{ .elements = elems, .capacity = elems.len, .fixed_size = null };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
},
.index_op => {
const obj = self.reg_pool[base + b];
const idx_val = self.reg_pool[base + c];
const loc = func.chunk.locAt(ip);
const result_val = try self.doIndex(obj, idx_val, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.get_field => {
const obj = self.reg_pool[base + b];
const field_name = func.chunk.constants.items[c].string.bytes();
const loc = func.chunk.locAt(ip);
const result_val = try self.doGetField(obj, field_name, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.get_adt_field => {
const obj = self.reg_pool[base + a];
if (obj != .adt) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "ADT field access on non-adt value", error.TypeMismatch);
}
const field_idx: usize = bx;
if (field_idx >= obj.adt.fields.len) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "ADT field index out of bounds", error.TypeMismatch);
}
const result_val = obj.adt.fields[field_idx].value.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.set_field => {
const obj = self.reg_pool[base + a];
const field_name = func.chunk.constants.items[b].string.bytes();
const new_val = self.reg_pool[base + c];
const loc = func.chunk.locAt(ip);
const result_val = try self.doSetField(obj, field_name, new_val, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.set_index => {
const obj = self.reg_pool[base + a];
const idx_val = self.reg_pool[base + b];
const new_val = self.reg_pool[base + c];
const loc = func.chunk.locAt(ip);
const result_val = try self.doSetIndex(obj, idx_val, new_val, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.call_method, .call_method_ic => {
const recv = self.reg_pool[base + a];
const method_name = func.chunk.constants.items[b].string.bytes();
const argc: usize = c;
const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
const loc = func.chunk.locAt(ip);
const result_val = try self.doCallMethod(recv, method_name, args_slice, loc);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.make_adt => {
const ctor_idx: usize = b;
const argc: usize = c;
const desc = self.program.?.adt_ctors.items[ctor_idx];
const fields = self.allocator.alloc(value.AdtField, argc) catch return error.OutOfMemory;
for (0..argc) |i| {
var fv = self.reg_pool[base + a + 1 + i].retain();
if (i < desc.field_types.len) if (desc.field_types[i]) |tn| {
if (fv.isInteger() or fv.isFloat()) {
if (cast.castNumeric(self.allocator, fv, tn)) |coerced| {
fv.release(self.allocator);
fv = coerced;
} else |_| {}
}
};
fields[i] = .{ .name = if (i < desc.field_names.len) desc.field_names[i] else null, .value = fv };
}
const adt_ptr = self.allocator.create(value.AdtValue) catch return error.OutOfMemory;
adt_ptr.* = .{ .type_name = desc.type_name, .constructor = desc.ctor_name, .fields = fields };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .adt = adt_ptr };
},
.make_newtype => {
const inner = self.reg_pool[base + b].retain();
const nt_idx: usize = c;
const desc = self.program.?.newtype_ctors.items[nt_idx];
const nt_ptr = self.allocator.create(value.NewtypeValue) catch return error.OutOfMemory;
nt_ptr.* = .{ .type_name = desc.type_name, .inner = inner };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .newtype = nt_ptr };
},
.make_error => {
const inner = self.reg_pool[base + b].retain();
defer inner.release(self.allocator);
const err_idx: usize = c;
const desc = self.program.?.error_ctors.items[err_idx];
var msg: std.ArrayListUnmanaged(u8) = .empty;
errdefer msg.deinit(self.allocator);
try msg.appendSlice(self.allocator, desc.default_prefix);
try msg.appendSlice(self.allocator, ": ");
if (inner == .string) {
try msg.appendSlice(self.allocator, inner.string.bytes());
} else {
const formatted = inner.formatAlloc(self.allocator) catch return error.OutOfMemory;
defer self.allocator.free(formatted);
try msg.appendSlice(self.allocator, formatted);
}
const e = self.allocator.create(value.ErrorValue) catch return error.OutOfMemory;
e.* = .{
.type_name = self.allocator.dupe(u8, desc.type_name) catch return error.OutOfMemory,
.message = try msg.toOwnedSlice(self.allocator),
.is_error_subtype = true,
};
const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
tv.* = .{ .payload = .{ .err = e } };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .throw_val = tv };
},
.make_record => {
const shape_idx: usize = b;
const field_count: usize = c;
const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
var map = std.StringHashMap(value.Value).init(self.allocator);
const field_names = if (shape_idx < self.program.?.record_shapes.items.len)
self.program.?.record_shapes.items[shape_idx].field_names
else
&[_][]const u8{};
for (0..field_count) |i| {
const val = self.reg_pool[base + a + 1 + i].retain();
const fname = if (i < field_names.len) field_names[i] else "";
const key = self.allocator.dupe(u8, fname) catch return error.OutOfMemory;
map.put(key, val) catch return error.OutOfMemory;
}
rec_ptr.* = .{ .type_name = "", .fields = map };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .record = rec_ptr };
},
.make_range, .make_range_incl => |op_tag| {
const left_val = self.reg_pool[base + b];
const right_val = self.reg_pool[base + c];
const inclusive = op_tag == .make_range_incl;
if (!left_val.isInteger() or !right_val.isInteger()) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "range requires integer bounds", error.TypeMismatch);
}
const start_int = left_val.asInt();
const end_int = right_val.asInt();
const start_i64 = if (start_int.coerceTo(.i64)) |s| s.toNative(i64) else null;
const end_i64 = if (end_int.coerceTo(.i64)) |e| e.toNative(i64) else null;
const r = self.allocator.create(value.Range) catch return error.OutOfMemory;
r.* = .{ .start = start_int, .end = end_int, .inclusive = inclusive, .start_i64 = start_i64, .end_i64 = end_i64 };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .range = r };
},
.make_atomic => {
const inner = self.reg_pool[base + b];
const av = self.allocator.create(value.AtomicValue) catch return error.OutOfMemory;
av.* = value.AtomicValue.init(inner);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .atomic_val = av };
},
.make_lazy => {
const inner = self.reg_pool[base + b].retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
},
.make_trait => {
const count: usize = b;
const tv = self.allocator.create(value.TraitValue) catch return error.OutOfMemory;
tv.* = .{
.trait_name = "",
.methods = std.StringHashMap(value.Value).init(self.allocator),
.allocator = self.allocator,
.vm_owned = true,
};
var i: usize = 0;
while (i < count) : (i += 1) {
const name_reg = a + 1 + i * 2;
const closure_reg = a + 1 + i * 2 + 1;
const name_val = self.reg_pool[base + name_reg];
const closure_val = self.reg_pool[base + closure_reg].retain();
const name_str = if (name_val == .string) name_val.string.bytes() else "";
const name_copy = self.allocator.dupe(u8, name_str) catch return error.OutOfMemory;
tv.methods.put(name_copy, closure_val) catch return error.OutOfMemory;
}
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .trait_value = tv };
},
.non_null => {
if (self.reg_pool[base + a] == .null_val) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "non-null assertion failed", error.TypeMismatch);
}
},
.propagate => {
const v = self.reg_pool[base + a];
if (v == .null_val) {
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
try self.frameReturn();
self.reg_pool[ret_base + ret_reg].release(self.allocator);
self.reg_pool[ret_base + ret_reg] = value.Value.fromNull();
if (self.frames.items.len < self.stop_depth) {
result = value.Value.fromNull();
break;
}
} else if (v == .throw_val and v.throw_val.payload == .err) {
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
const err_val = v.retain();
try self.frameReturn();
self.reg_pool[ret_base + ret_reg].release(self.allocator);
self.reg_pool[ret_base + ret_reg] = err_val;
if (self.frames.items.len < self.stop_depth) {
result = err_val.retain();
break;
}
}
if (self.reg_pool[base + a] == .throw_val and self.reg_pool[base + a].throw_val.payload == .ok) {
const inner = self.reg_pool[base + a].throw_val.payload.ok.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
}
},
.throw_op => {
const v = self.reg_pool[base + a].retain();
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
try self.frameReturn();
self.reg_pool[ret_base + ret_reg].release(self.allocator);
self.reg_pool[ret_base + ret_reg] = v;
if (self.frames.items.len < self.stop_depth) {
result = v.retain();
break;
}
},
.match_fail => {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "match failed: no matching pattern", error.TypeMismatch);
},
.test_ctor => {
const obj = self.reg_pool[base + a];
const ctor_idx: usize = bx;
const desc = self.program.?.adt_ctors.items[ctor_idx];
const matched = (obj == .adt) and std.mem.eql(u8, obj.adt.constructor, desc.ctor_name) and std.mem.eql(u8, obj.adt.type_name, desc.type_name);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromBool(matched);
},
.test_lit => {
const obj = self.reg_pool[base + b];
const lit = func.chunk.constants.items[c];
const matched = value.equals(obj, lit);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromBool(matched);
},
.test_newtype => {
const obj = self.reg_pool[base + a];
const nt_idx: usize = bx;
const desc = self.program.?.newtype_ctors.items[nt_idx];
const matched = (obj == .newtype) and std.mem.eql(u8, obj.newtype.type_name, desc.type_name);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromBool(matched);
},
.test_throw => {
const obj = self.reg_pool[base + a];
const want_ok = (b != 0);
const matched = if (obj == .throw_val)
(if (want_ok) obj.throw_val.payload == .ok else obj.throw_val.payload == .err)
else
want_ok;
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromBool(matched);
},
.get_throw_ok => {
const obj = self.reg_pool[base + b];
if (obj != .throw_val) {
const inner = obj.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
} else {
if (obj.throw_val.payload != .ok) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "GET_THROW_OK on non-Ok", error.TypeMismatch);
}
const inner = obj.throw_val.payload.ok.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
}
},
.get_throw_err => {
const obj = self.reg_pool[base + b];
if (obj != .throw_val) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "GET_THROW_ERR on non-Error", error.TypeMismatch);
}
if (obj.throw_val.payload != .err) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "GET_THROW_ERR on non-Error", error.TypeMismatch);
}
const e = obj.throw_val.payload.err;
const type_name = self.allocator.dupe(u8, e.type_name) catch return error.OutOfMemory;
const message = self.allocator.dupe(u8, e.message) catch return error.OutOfMemory;
const result_val = try value.Value.makeError(self.allocator, type_name, message, e.is_error_subtype);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
},
.get_newtype_inner => {
const obj = self.reg_pool[base + b];
if (obj != .newtype) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "not a newtype value", error.TypeMismatch);
}
const inner = obj.newtype.inner.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
},
.compound_local => {
const arith_op: reg_opcode.Op = @enumFromInt(b);
const lv = self.reg_pool[base + a];
const rv = self.reg_pool[base + c];
// i64 同类型快速路径
const result_val = fastI64Arith(arith_op, lv, rv) orelse blk: {
const loc = func.chunk.locAt(ip);
break :blk try self.doArith(arith_op, lv, rv, loc);
};
if (isScalarValue(lv)) {
self.reg_pool[base + a] = result_val;
} else {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = result_val;
}
},
.closure => {
const func_idx: u16 = @intCast(bx);
const callee = &self.program.?.functions.items[func_idx];
var ups: []value.Value = &.{};
if (callee.upvalue_specs.items.len > 0) {
ups = self.allocator.alloc(value.Value, callee.upvalue_specs.items.len) catch return error.OutOfMemory;
for (callee.upvalue_specs.items, 0..) |spec, i| {
if (spec.is_local) {
const src_val = self.reg_pool[base + spec.index].retain();
const cell_ptr = self.allocator.create(value.Cell) catch return error.OutOfMemory;
cell_ptr.* = .{ .inner = src_val };
ups[i] = value.Value{ .cell = cell_ptr };
} else {
if (spec.index < frame.upvalues.len) {
ups[i] = frame.upvalues[spec.index].retain();
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
}
}
}
}
const cl = self.allocator.create(value.VmClosure) catch return error.OutOfMemory;
cl.* = .{ .func = callee, .arity = callee.arity, .upvalues = ups, .allocator = self.allocator };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .vm_closure = cl };
},
.get_upvalue => {
if (frame.upvalues.len > b) {
const uv = frame.upvalues[b];
const inner = if (uv == .cell) uv.cell.inner.retain() else uv.retain();
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = inner;
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
}
},
.set_upvalue => {
if (frame.upvalues.len > b) {
const uv = &frame.upvalues[b];
if (uv.* == .cell) {
uv.cell.inner.release(self.allocator);
uv.cell.inner = self.reg_pool[base + a].retain();
} else {
uv.release(self.allocator);
uv.* = self.reg_pool[base + a].retain();
}
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
}
},
.get_upvalue_raw => {
if (frame.upvalues.len > b) {
const uv = frame.upvalues[b];
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = uv.retain();
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
}
},
.call_value => {
const argc: usize = c;
const callee_val = self.reg_pool[base + a];
if (callee_val != .vm_closure) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "value is not callable", error.TypeMismatch);
}
const vc = callee_val.vm_closure;
const total = vc.bound_args.len + argc;
if (total != vc.arity) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "wrong number of arguments", error.WrongArity);
}
const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
defer self.allocator.free(all_args);
for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
for (0..argc) |i| all_args[vc.bound_args.len + i] = self.reg_pool[base + a + 1 + i];
const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
try self.setupFrame(callee, all_args, base, a);
self.frames.items[self.frames.items.len - 1].upvalues = vc.upvalues;
},
.tail_call => {
const func_idx: u16 = @intCast(bx);
const callee = &self.program.?.functions.items[func_idx];
const argc: usize = callee.arity;
// frameReturn 会释放当前帧所有寄存器（release_mask），需先 retain 参数
var argbuf: [256]value.Value = undefined;
for (0..argc) |i| argbuf[i] = self.reg_pool[base + a + 1 + i].retain();
const args = argbuf[0..argc];
// JIT 快速路径：尾调用如果已编译，直接执行原生代码并返回
// 桥接深度超限时跳过，避免原生栈溢出（如深度尾递归）
if (self.bridge_depth < BRIDGE_DEPTH_LIMIT) jit_check: {
    const je = &(self.jit_engine orelse break :jit_check);
    if (je.recordCall(@intCast(func_idx))) |cfn| {
        const ret_base = frame.return_base;
        const ret_reg = frame.return_reg;
        try self.frameReturn();
        if (cfn.bridge) try self.setupFrame(callee, args, ret_base, ret_reg);
        jit_mod.invokeJit(self, cfn, args, ret_base, ret_reg);
        for (args) |v| v.release(self.allocator);
        continue;
    } else if (je.shouldCompile(@intCast(func_idx))) {
        if (je.compileFunction(@intCast(func_idx), callee)) |cfn| {
            const ret_base = frame.return_base;
            const ret_reg = frame.return_reg;
            try self.frameReturn();
            if (cfn.bridge) try self.setupFrame(callee, args, ret_base, ret_reg);
            jit_mod.invokeJit(self, cfn, args, ret_base, ret_reg);
            for (args) |v| v.release(self.allocator);
            continue;
        }
    }
}
const ret_base = frame.return_base;
const ret_reg = frame.return_reg;
try self.frameReturn();
try self.setupFrame(callee, args, ret_base, ret_reg);
for (args) |v| v.release(self.allocator);
},
.interp => {
const part_count: usize = c;
var buf = std.ArrayList(u8).empty;
defer buf.deinit(self.allocator);
for (0..part_count) |i| {
const part = self.reg_pool[base + a + 1 + i];
if (part == .string) {
buf.appendSlice(self.allocator, part.string.bytes()) catch return error.OutOfMemory;
} else {
part.format(self.allocator, &buf) catch return error.OutOfMemory;
}
}
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .string = s };
},
.push_inplace => {
const arr_val = self.reg_pool[base + a];
const new_elem = self.reg_pool[base + c];
if (arr_val != .array) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "push_inplace on non-array", error.TypeMismatch);
}
const old_elems = arr_val.array.elements;
const new_elems = self.allocator.alloc(value.Value, old_elems.len + 1) catch return error.OutOfMemory;
for (old_elems, 0..) |e, i| new_elems[i] = e.retain();
new_elems[old_elems.len] = new_elem.retain();
const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
arr_ptr.* = .{ .elements = new_elems, .capacity = new_elems.len, .fixed_size = null };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
},
.for_next => {
const elem_reg = a;
const iter_reg = b;
const idx_reg = c;
const iterable = self.reg_pool[base + iter_reg];
const idx = self.reg_pool[base + idx_reg];
var exhausted = false;
// 快速提取循环索引：VM 自身生成的索引总是 i64，直接取值避免 coerceTo 开销
const idx_i64: ?i64 = if (idx == .int and idx.int.type == .i64)
idx.int.toNative(i64)
else if (idx.isInteger())
(if (idx.asInt().coerceTo(.i64)) |ic| ic.toNative(i64) else null)
else
null;
if (iterable == .array) {
const i: usize = if (idx_i64) |v| @intCast(v) else 0;
if (i < iterable.array.elements.len) {
self.reg_pool[base + elem_reg].release(self.allocator);
self.reg_pool[base + elem_reg] = iterable.array.elements[i].retain();
self.reg_pool[base + idx_reg].release(self.allocator);
self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, @as(i64, @intCast(i + 1))));
} else {
exhausted = true;
}
} else if (iterable == .range) {
const r = iterable.range;
const loc = func.chunk.locAt(ip);
const start_i = r.start_i64 orelse return self.fail(loc, "range start out of i64 range", error.ArithmeticOverflow);
const end_i = r.end_i64 orelse return self.fail(loc, "range end out of i64 range", error.ArithmeticOverflow);
const off: i64 = idx_i64 orelse 0;
const cur: i64 = start_i + off;
const past = if (r.inclusive) cur > end_i else cur >= end_i;
if (!past) {
self.reg_pool[base + elem_reg].release(self.allocator);
self.reg_pool[base + elem_reg] = value.Value.fromInt(value.Int.fromNative(.i64, cur));
self.reg_pool[base + idx_reg].release(self.allocator);
self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, off + 1));
} else {
exhausted = true;
}
} else if (iterable == .string) {
const s = iterable.string.bytes();
const ci_target: i64 = idx_i64 orelse 0;
const view = std.unicode.Utf8View.init(s) catch {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
};
var it = view.iterator();
var ci: i64 = 0;
var found = false;
while (it.nextCodepoint()) |cp| : (ci += 1) {
if (ci == ci_target) {
self.reg_pool[base + elem_reg].release(self.allocator);
self.reg_pool[base + elem_reg] = value.Value.fromChar(value.Char.fromNative(cp) catch unreachable);
self.reg_pool[base + idx_reg].release(self.allocator);
self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, ci_target + 1));
found = true;
break;
}
}
if (!found) exhausted = true;
} else {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "for_next on non-iterable", error.TypeMismatch);
}
if (!exhausted) {
frame.ip += 1;
}
},
.spawn => {
const closure_val = self.reg_pool[base + b];
const argc: usize = c;
if (closure_val != .vm_closure) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "spawn on non-closure", error.InvalidSpawn);
}
const vc = closure_val.vm_closure;
const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
defer self.allocator.free(all_args);
for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
for (0..argc) |i| all_args[vc.bound_args.len + i] = self.reg_pool[base + b + 1 + i];
const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
const saved_stop = self.stop_depth;
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
defer self.stop_depth = saved_stop;
defer self.single_step = saved_single_step;
defer self.step_count = saved_step_count;
self.single_step = false;
self.step_count = 0;
try self.setupFrame(callee, all_args, 0, 0);
self.stop_depth = self.frames.items.len;
const spawn_result = try self.runLoop();
const spawn_handle = self.allocator.create(value.SpawnHandle) catch return error.OutOfMemory;
spawn_handle.* = value.SpawnHandle.init(self.allocator);
spawn_handle.result = spawn_result;
spawn_handle.status.store(.Completed, .release);
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .spawn_val = spawn_handle };
},
.recv => {
const ch_val = self.reg_pool[base + b];
if (ch_val != .channel_val) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "recv on non-channel", error.TypeMismatch);
}
const ch = ch_val.channel_val;
const recv_result = ch.recv();
if (recv_result) |v| {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = v;
} else {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromNull();
}
},
.try_recv => {
const ch_val = self.reg_pool[base + b];
if (ch_val != .channel_val) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "try_recv on non-channel", error.TypeMismatch);
}
const ch = ch_val.channel_val;
const recv_result = ch.tryRecv();
if (recv_result) |v| {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = v;
self.reg_pool[base + a + 1].release(self.allocator);
self.reg_pool[base + a + 1] = value.Value.fromBool(true);
} else {
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value.fromNull();
self.reg_pool[base + a + 1].release(self.allocator);
self.reg_pool[base + a + 1] = value.Value.fromBool(false);
}
},
.record_extend => {
const src = self.reg_pool[base + a];
if (src != .record) {
const loc = func.chunk.locAt(ip);
return self.fail(loc, "record_extend on non-record", error.TypeMismatch);
}
const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
var map = std.StringHashMap(value.Value).init(self.allocator);
var it = src.record.fields.iterator();
while (it.next()) |entry| {
const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
map.put(key, entry.value_ptr.*.retain()) catch return error.OutOfMemory;
}
rec_ptr.* = .{ .type_name = src.record.type_name, .fields = map };
self.reg_pool[base + a].release(self.allocator);
self.reg_pool[base + a] = value.Value{ .record = rec_ptr };
},
.call_memoized => {
    const func_idx = bx;
    const callee = &self.program.?.functions.items[func_idx];
    const argc = callee.arity;
    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
    // 1. 检查记忆化缓存（命中则直接返回，最快路径）
    if (callee.memo_slot != MEMO_SLOT_NONE) {
    if (hashArgsForMemo(args_slice)) |arg_hash| {
    if (self.memo_cache.get(.{ .slot = callee.memo_slot, .arg_hash = arg_hash })) |cached| {
    self.reg_pool[base + a].release(self.allocator);
    self.reg_pool[base + a] = cached.retain();
    continue;
    }
    // 缓存未命中，JIT 或解释器（桥接深度超限时跳过 JIT，避免原生栈溢出）
    if (self.bridge_depth < BRIDGE_DEPTH_LIMIT) jit_check: {
        const je = &(self.jit_engine orelse break :jit_check);
        if (je.recordCall(@intCast(func_idx))) |cfn| {
            if (cfn.bridge) {
                // 桥接模式：return_op 会自动缓存结果
                try self.setupFrame(callee, args_slice, base, a);
                const new_frame = &self.frames.items[self.frames.items.len - 1];
                new_frame.memo_slot = callee.memo_slot;
                new_frame.memo_arg_hash = arg_hash;
            }
            jit_mod.invokeJit(self, cfn, args_slice, base, a);
            if (!cfn.bridge) {
                self.memo_cache.put(self.allocator, .{ .slot = callee.memo_slot, .arg_hash = arg_hash }, self.reg_pool[base + a].retain()) catch {};
            }
            continue;
        } else if (je.shouldCompile(@intCast(func_idx))) {
            if (je.compileFunction(@intCast(func_idx), callee)) |cfn| {
                if (cfn.bridge) {
                    try self.setupFrame(callee, args_slice, base, a);
                    const new_frame = &self.frames.items[self.frames.items.len - 1];
                    new_frame.memo_slot = callee.memo_slot;
                    new_frame.memo_arg_hash = arg_hash;
                }
                jit_mod.invokeJit(self, cfn, args_slice, base, a);
                if (!cfn.bridge) {
                    self.memo_cache.put(self.allocator, .{ .slot = callee.memo_slot, .arg_hash = arg_hash }, self.reg_pool[base + a].retain()) catch {};
                }
                continue;
            }
        }
    }
    try self.setupFrame(callee, args_slice, base, a);
    const new_frame = &self.frames.items[self.frames.items.len - 1];
    new_frame.memo_slot = callee.memo_slot;
    new_frame.memo_arg_hash = arg_hash;
    } else {
    // 参数不可记忆化，走 JIT 或解释器（桥接深度超限时跳过 JIT）
    if (self.bridge_depth < BRIDGE_DEPTH_LIMIT) jit_check: {
        const je = &(self.jit_engine orelse break :jit_check);
        if (je.recordCall(@intCast(func_idx))) |cfn| {
            if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
            jit_mod.invokeJit(self, cfn, args_slice, base, a);
            continue;
        } else if (je.shouldCompile(@intCast(func_idx))) {
            if (je.compileFunction(@intCast(func_idx), callee)) |cfn| {
                if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
                jit_mod.invokeJit(self, cfn, args_slice, base, a);
                continue;
            }
        }
    }
    try self.setupFrame(callee, args_slice, base, a);
    }
    } else {
    // 无 memo slot，走 JIT 或解释器（桥接深度超限时跳过 JIT）
    if (self.bridge_depth < BRIDGE_DEPTH_LIMIT) jit_check: {
        const je = &(self.jit_engine orelse break :jit_check);
        if (je.recordCall(@intCast(func_idx))) |cfn| {
            if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
            jit_mod.invokeJit(self, cfn, args_slice, base, a);
            continue;
        } else if (je.shouldCompile(@intCast(func_idx))) {
            if (je.compileFunction(@intCast(func_idx), callee)) |cfn| {
                if (cfn.bridge) try self.setupFrame(callee, args_slice, base, a);
                jit_mod.invokeJit(self, cfn, args_slice, base, a);
                continue;
            }
        }
    }
    try self.setupFrame(callee, args_slice, base, a);
    }
},
}
}
// 正常退出：frames < stop_depth（函数返回）
if (self.single_step) {
self.single_step = false;
self.step_count = 0;
self.step_did_return = true;
}
return result;
}
/// 帧返回：弹出当前帧，释放 upvalue，恢复前一帧的执行上下文。
fn frameReturn(self: *RegVM) VMError!void {
const frame = self.frames.items[self.frames.items.len - 1];
const func = frame.func;
const base = frame.base;
if (func.register_count <= 64 and func.release_mask != 0) {
var mask = func.release_mask;
while (mask != 0) {
const bit = @ctz(mask);
mask &= mask - 1;
if (bit < func.register_count) {
self.reg_pool[base + bit].release(self.allocator);
self.reg_pool[base + bit] = value.Value.fromNull();
}
}
} else {
for (0..func.register_count) |i| {
self.reg_pool[base + i].release(self.allocator);
self.reg_pool[base + i] = value.Value.fromNull();
}
}
_ = self.frames.pop();
}
/// 记录错误位置与消息后返回错误码。
fn fail(self: *RegVM, loc: ast.SourceLocation, msg: []const u8, e: VMError) VMError {
self.err_loc = loc;
self.err_msg = msg;
return e;
}
/// 执行内建函数调用：根据 Native 枚举分派到对应的内建实现。
fn doCallNative(self: *RegVM, nat: opcode.Native, argc: usize, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
switch (nat) {
.println, .print => {
if (argc != 1) return self.fail(loc, "println/print expects 1 argument", error.WrongArity);
const v = unwrapTransparent(args[0]);
var buf = std.ArrayList(u8).empty;
defer buf.deinit(self.allocator);
if (v == .string) {
buf.appendSlice(self.allocator, v.string.bytes()) catch return error.OutOfMemory;
} else {
v.format(self.allocator, &buf) catch return error.OutOfMemory;
}
if (nat == .println) buf.append(self.allocator, '\n') catch {};
if (self.io) |io| {
var out_buf: [4096]u8 = undefined;
var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
w.interface.print("{s}", .{buf.items}) catch {};
w.flush() catch {};
} else {
std.debug.print("{s}", .{buf.items});
}
return value.Value.fromUnit();
},
.eprintln, .eprint => {
if (argc != 1) return self.fail(loc, "eprintln/eprint expects 1 argument", error.WrongArity);
const v = args[0];
var buf = std.ArrayList(u8).empty;
defer buf.deinit(self.allocator);
if (v == .string) {
buf.appendSlice(self.allocator, v.string.bytes()) catch return error.OutOfMemory;
} else {
v.format(self.allocator, &buf) catch return error.OutOfMemory;
}
if (nat == .eprintln) buf.append(self.allocator, '\n') catch {};
if (self.io) |io| {
var err_buf: [4096]u8 = undefined;
var w = std.Io.File.stderr().writerStreaming(io, &err_buf);
w.interface.print("{s}", .{buf.items}) catch {};
w.flush() catch {};
} else {
std.debug.print("{s}", .{buf.items});
}
return value.Value.fromUnit();
},
.type => {
if (argc != 1) return self.fail(loc, "type expects 1 argument", error.WrongArity);
const v = args[0];
const name = regValueTypeName(v);
return try value.Value.fromStringBytes(self.allocator, name);
},
.eq => {
if (argc != 2) return self.fail(loc, "eq expects 2 arguments", error.WrongArity);
return value.Value.fromBool(regStructuralEquals(args[0], args[1]));
},
.panic => {
if (argc != 1) return self.fail(loc, "Panic expects 1 argument", error.WrongArity);
const v = args[0];
const msg = if (v == .string)
self.allocator.dupe(u8, v.string.bytes()) catch return error.OutOfMemory
else
v.formatAlloc(self.allocator) catch return error.OutOfMemory;
defer self.allocator.free(msg);
return self.fail(loc, msg, error.Unsupported);
},
.ok => {
if (argc != 1) return self.fail(loc, "Ok expects 1 argument", error.WrongArity);
const inner = args[0].retain();
const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
tv.* = .{ .payload = .{ .ok = inner } };
return value.Value{ .throw_val = tv };
},
.err => {
if (argc != 1) return self.fail(loc, "Error expects 1 argument", error.WrongArity);
const v = args[0];
if (v != .string) return self.fail(loc, "Error expects a str argument", error.TypeMismatch);
const str = v.string.bytes();
const e = self.allocator.create(value.ErrorValue) catch return error.OutOfMemory;
e.* = .{
.type_name = self.allocator.dupe(u8, type_names.error_type) catch return error.OutOfMemory,
.message = self.allocator.dupe(u8, str) catch return error.OutOfMemory,
};
const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
tv.* = .{ .payload = .{ .err = e } };
return value.Value{ .throw_val = tv };
},
.channel => {
if (argc != 1) return self.fail(loc, "channel expects 1 argument", error.WrongArity);
const v = args[0];
if (!v.isInteger()) return self.fail(loc, "channel expects an integer capacity", error.TypeMismatch);
const int_val = v.asInt();
const coerced = int_val.coerceTo(.i64) orelse return self.fail(loc, "channel capacity out of range", error.ArithmeticOverflow);
const cap_v = coerced.toNative(i64);
if (cap_v < 0) return self.fail(loc, "channel capacity cannot be negative", error.ArithmeticOverflow);
const cap: usize = @intCast(cap_v);
const ch = self.allocator.create(value.ChannelValue) catch return error.OutOfMemory;
ch.* = value.ChannelValue.init(self.allocator, cap) catch {
self.allocator.destroy(ch);
return error.OutOfMemory;
};
return value.Value{ .channel_val = ch };
},
.scan, .scanln => return self.fail(loc, "scan/scanln not supported in reg VM", error.Unsupported),
}
}
/// 透传解包：剥离 Lazy/Cell/Atomic 等透明包装，返回内部值。
fn unwrapTransparent(v: value.Value) value.Value {
return switch (v) {
.atomic_val => v.atomic_val.load(),
.cell => v.cell.inner,
else => v,
};
}

/// 原生整数算术快速路径（comptime 泛型）：对 i8..i64 / u8..u64 同类型操作数
/// 直接使用 CPU 原生指令运算，跳过 coerceTo / promoteIntTypes / 128 位通用路径。
fn nativeIntArith(
    comptime T: type,
    self: *RegVM,
    int_type: value.IntType,
    op: reg_opcode.Op,
    left_int: value.Int,
    right_int: value.Int,
    loc: ast.SourceLocation,
) VMError!value.Value {
    const lv = left_int.toNative(T);
    const rv = right_int.toNative(T);
    switch (op) {
        .add => {
            const r = @addWithOverflow(lv, rv);
            if (r[1] != 0) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
            return value.Value.fromInt(value.Int.fromNative(int_type, r[0]));
        },
        .sub => {
            const r = @subWithOverflow(lv, rv);
            if (r[1] != 0) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
            return value.Value.fromInt(value.Int.fromNative(int_type, r[0]));
        },
        .mul => {
            const r = @mulWithOverflow(lv, rv);
            if (r[1] != 0) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
            return value.Value.fromInt(value.Int.fromNative(int_type, r[0]));
        },
        .div => {
            if (rv == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
            return value.Value.fromInt(value.Int.fromNative(int_type, @divTrunc(lv, rv)));
        },
        .mod => {
            if (rv == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
            return value.Value.fromInt(value.Int.fromNative(int_type, @rem(lv, rv)));
        },
        .bit_and => return value.Value.fromInt(value.Int.fromNative(int_type, lv & rv)),
        .bit_or => return value.Value.fromInt(value.Int.fromNative(int_type, lv | rv)),
        .bit_xor => return value.Value.fromInt(value.Int.fromNative(int_type, lv ^ rv)),
        else => return self.fail(loc, "unsupported integer operation", error.TypeMismatch),
    }
}

/// 原生浮点算术快速路径（comptime 泛型）：对 f32 / f64 同类型操作数
/// 直接使用 CPU 原生浮点指令运算，跳过 addPortable 等可移植软浮点实现。
fn nativeFloatArith(
    comptime T: type,
    float_type: value.FloatType,
    op: reg_opcode.Op,
    lf: value.Float,
    rf: value.Float,
) VMError!value.Value {
    const lv = lf.toNative(T);
    const rv = rf.toNative(T);
    switch (op) {
        .add => {
            const r = lv + rv;
            if (std.math.isNan(r) or std.math.isInf(r)) @panic("float operation produced NaN or Infinity");
            return value.Value.fromFloat(value.Float.fromNative(float_type, r));
        },
        .sub => {
            const r = lv - rv;
            if (std.math.isNan(r) or std.math.isInf(r)) @panic("float operation produced NaN or Infinity");
            return value.Value.fromFloat(value.Float.fromNative(float_type, r));
        },
        .mul => {
            const r = lv * rv;
            if (std.math.isNan(r) or std.math.isInf(r)) @panic("float operation produced NaN or Infinity");
            return value.Value.fromFloat(value.Float.fromNative(float_type, r));
        },
        .div => {
            if (rv == 0.0) return error.DivisionByZero;
            const r = lv / rv;
            if (std.math.isNan(r) or std.math.isInf(r)) @panic("float operation produced NaN or Infinity");
            return value.Value.fromFloat(value.Float.fromNative(float_type, r));
        },
        .mod => {
            if (rv == 0.0) return error.DivisionByZero;
            const q = @trunc(lv / rv);
            const r = lv - rv * q;
            if (std.math.isNan(r) or std.math.isInf(r)) @panic("float operation produced NaN or Infinity");
            return value.Value.fromFloat(value.Float.fromNative(float_type, r));
        },
        else => return error.TypeMismatch,
    }
}

/// 执行算术运算（加减乘除取模、位与或异或）：先解包透明包装，
/// 再按整数/浮点分派，整数为 128 位宽，溢出时报 ArithmeticOverflow。
fn doArith(self: *RegVM, op: reg_opcode.Op, left_in: value.Value, right_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
const left = unwrapTransparent(left_in);
const right = unwrapTransparent(right_in);
if (left.isInteger() and right.isInteger()) {
const left_int = left.asInt();
const right_int = right.asInt();
// 原生整数快速路径：同类型 i8..i64 / u8..u64 直接走原生算术，跳过 coerceTo / promoteIntTypes
if (left_int.type == right_int.type) {
switch (left_int.type) {
.i8 => return try nativeIntArith(i8, self, left_int.type, op, left_int, right_int, loc),
.i16 => return try nativeIntArith(i16, self, left_int.type, op, left_int, right_int, loc),
.i32 => return try nativeIntArith(i32, self, left_int.type, op, left_int, right_int, loc),
.i64 => return try nativeIntArith(i64, self, left_int.type, op, left_int, right_int, loc),
.u8 => return try nativeIntArith(u8, self, left_int.type, op, left_int, right_int, loc),
.u16 => return try nativeIntArith(u16, self, left_int.type, op, left_int, right_int, loc),
.u32 => return try nativeIntArith(u32, self, left_int.type, op, left_int, right_int, loc),
.u64 => return try nativeIntArith(u64, self, left_int.type, op, left_int, right_int, loc),
.i128, .u128 => {}, // 128 位走通用路径
}
}
switch (op) {
.bit_and => {
const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
return value.Value.fromInt(left_int.bitwiseAnd(right_coerced));
},
.bit_or => {
const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
return value.Value.fromInt(left_int.bitwiseOr(right_coerced));
},
.bit_xor => {
const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
return value.Value.fromInt(left_int.bitwiseXor(right_coerced));
},
else => {},
}
const result_type = value.promoteIntTypes(left_int.type, right_int.type);
const left_coerced = left_int.coerceTo(result_type) orelse return self.fail(loc, "arithmetic overflow: operand out of range", error.ArithmeticOverflow);
const right_coerced = right_int.coerceTo(result_type) orelse return self.fail(loc, "arithmetic overflow: operand out of range", error.ArithmeticOverflow);
return switch (op) {
.add => blk: {
const r = left_coerced.add(right_coerced);
if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
break :blk value.Value.fromInt(r.result);
},
.sub => blk: {
const r = left_coerced.subtract(right_coerced);
if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
break :blk value.Value.fromInt(r.result);
},
.mul => blk: {
const r = left_coerced.multiply(right_coerced);
if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
break :blk value.Value.fromInt(r.result);
},
.div => blk: {
const r = left_coerced.divideTruncating(right_coerced) catch return self.fail(loc, "division by zero", error.DivisionByZero);
break :blk value.Value.fromInt(r);
},
.mod => blk: {
const r = left_coerced.remainder(right_coerced) catch return self.fail(loc, "division by zero", error.DivisionByZero);
break :blk value.Value.fromInt(r);
},
else => return self.fail(loc, "unsupported integer operation", error.TypeMismatch),
};
}
if ((left.isFloat() or left.isInteger()) and (right.isFloat() or right.isInteger())) {
// 原生浮点快速路径：同为 f32 或 f64 时直接走原生浮点运算，跳过 addPortable 等可移植实现
if (left == .float and right == .float and left.float.type == right.float.type) {
switch (left.float.type) {
.f32 => return try nativeFloatArith(f32, left.float.type, op, left.float, right.float),
.f64 => return try nativeFloatArith(f64, left.float.type, op, left.float, right.float),
.f16, .f128 => {}, // 非原生宽度走通用路径
}
}
const tag: value.FloatType = if (left.isFloat() and right.isFloat()) blk: {
const lt = left.asFloat().type;
const rt = right.asFloat().type;
break :blk if (@intFromEnum(lt) > @intFromEnum(rt)) lt else rt;
} else if (left.isFloat()) left.asFloat().type else right.asFloat().type;
const lf: value.Float = if (left.isFloat()) left.asFloat().toFloatType(tag) else value.Float.fromInt(tag, left.asInt());
const rf: value.Float = if (right.isFloat()) right.asFloat().toFloatType(tag) else value.Float.fromInt(tag, right.asInt());
const result: value.Float = switch (op) {
.add => lf.add(rf),
.sub => lf.subtract(rf),
.mul => lf.multiply(rf),
.div => lf.divide(rf),
.mod => blk: {
if (rf.isZero()) return self.fail(loc, "float modulo by zero", error.DivisionByZero);
const q = lf.divide(rf);
const q_int = q.toInt(.i128) catch return self.fail(loc, "float modulo overflow", error.ArithmeticOverflow);
const q_float = value.Float.fromInt(tag, q_int);
break :blk lf.subtract(rf.multiply(q_float));
},
else => return self.fail(loc, "bitwise op requires integer operands", error.TypeMismatch),
};
return value.Value.fromFloat(result);
}
if (op == .add and left == .string and right == .string) {
const left_str = left.string.bytes();
const right_str = right.string.bytes();
if (value.Str.canConcatSso(left_str.len, right_str.len)) {
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.concatSso(left_str, right_str);
return value.Value{ .string = s };
}
const total = left_str.len + right_str.len;
const buf = self.allocator.alloc(u8, total) catch return error.OutOfMemory;
@memcpy(buf[0..left_str.len], left_str);
@memcpy(buf[left_str.len..total], right_str);
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, buf);
return value.Value{ .string = s };
}
return self.fail(loc, "arithmetic requires numeric operands", error.TypeMismatch);
}
/// 原生整数取反快速路径（comptime 泛型）：对有符号原生宽度类型直接原生取反。
fn nativeIntNegate(
    comptime T: type,
    self: *RegVM,
    int_type: value.IntType,
    int_val: value.Int,
    loc: ast.SourceLocation,
) VMError!value.Value {
    const n = int_val.toNative(T);
    if (n == std.math.minInt(T)) return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
    return value.Value.fromInt(value.Int.fromNative(int_type, -n));
}

/// 原生整数相等比较快速路径（comptime 泛型）。
fn nativeIntEq(comptime T: type, left_int: value.Int, right_int: value.Int) bool {
    return left_int.toNative(T) == right_int.toNative(T);
}

/// 原生整数大小比较快速路径（comptime 泛型）。
fn nativeIntOrd(comptime T: type, op: reg_opcode.Op, left_int: value.Int, right_int: value.Int) value.Value {
    const lv = left_int.toNative(T);
    const rv = right_int.toNative(T);
    return value.Value.fromBool(switch (op) {
        .lt => lv < rv,
        .gt => lv > rv,
        .le => lv <= rv,
        .ge => lv >= rv,
        else => unreachable,
    });
}

/// 执行一元取负：整数取反溢出时报错，浮点直接取反。
fn doNegate(self: *RegVM, v_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
const v = unwrapTransparent(v_in);
if (v.isInteger()) {
const int_val = v.asInt();
// 原生整数快速路径：有符号原生宽度直接原生取反
switch (int_val.type) {
.i8 => return try nativeIntNegate(i8, self, int_val.type, int_val, loc),
.i16 => return try nativeIntNegate(i16, self, int_val.type, int_val, loc),
.i32 => return try nativeIntNegate(i32, self, int_val.type, int_val, loc),
.i64 => return try nativeIntNegate(i64, self, int_val.type, int_val, loc),
else => {}, // 无符号或 128 位走通用路径
}
const result = int_val.negate();
if (int_val.type.isSigned() and int_val.isNegative() and result.isNegative()) {
return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
}
return value.Value.fromInt(result);
}
if (v.isFloat()) {
const f = v.asFloat();
// 原生浮点快速路径：f32 / f64 直接原生取反
switch (f.type) {
.f32 => return value.Value.fromFloat(value.Float.fromNative(.f32, -f.toNative(f32))),
.f64 => return value.Value.fromFloat(value.Float.fromNative(.f64, -f.toNative(f64))),
else => {}, // f16/f128 走通用路径
}
return value.Value.fromFloat(f.negate());
}
return self.fail(loc, "'-' requires numeric operand", error.TypeMismatch);
}
/// 执行比较运算（==/!=/</>/≤/≥）：先解包透明包装，再按类型分派。
/// 整数与浮点支持跨类型比较，字符串按字典序，其他类型用结构化相等。
fn doCompare(self: *RegVM, op: reg_opcode.Op, left_in: value.Value, right_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
const left = unwrapTransparent(left_in);
const right = unwrapTransparent(right_in);
if (op == .eq or op == .neq) {
// 原生整数快速路径：同类型 i8..i64 / u8..u64 直接原生比较
if (left.isInteger() and right.isInteger()) {
const left_int = left.asInt();
const right_int = right.asInt();
if (left_int.type == right_int.type) {
const eq: bool = switch (left_int.type) {
.i8 => nativeIntEq(i8, left_int, right_int),
.i16 => nativeIntEq(i16, left_int, right_int),
.i32 => nativeIntEq(i32, left_int, right_int),
.i64 => nativeIntEq(i64, left_int, right_int),
.u8 => nativeIntEq(u8, left_int, right_int),
.u16 => nativeIntEq(u16, left_int, right_int),
.u32 => nativeIntEq(u32, left_int, right_int),
.u64 => nativeIntEq(u64, left_int, right_int),
else => blk: {
const rt = value.promoteIntTypes(left_int.type, right_int.type);
const lc = left_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
const rc = right_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
break :blk lc.compare(rc) == .eq;
},
};
return value.Value.fromBool(if (op == .eq) eq else !eq);
}
const rt = value.promoteIntTypes(left_int.type, right_int.type);
const lc = left_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
const rc = right_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
const eq = lc.compare(rc) == .eq;
return value.Value.fromBool(if (op == .eq) eq else !eq);
}
if (left.isFloat() and right.isFloat()) {
const lf = left.asFloat();
const rf = right.asFloat();
// 原生浮点快速路径：同类型 f32 / f64 直接原生比较
if (lf.type == rf.type) {
const eq: bool = switch (lf.type) {
.f32 => lf.toNative(f32) == rf.toNative(f32),
.f64 => lf.toNative(f64) == rf.toNative(f64),
else => blk: {
const tag: value.FloatType = if (@intFromEnum(lf.type) > @intFromEnum(rf.type)) lf.type else rf.type;
break :blk lf.toFloatType(tag).compare(rf.toFloatType(tag)) == .eq;
},
};
return value.Value.fromBool(if (op == .eq) eq else !eq);
}
const tag: value.FloatType = if (@intFromEnum(lf.type) > @intFromEnum(rf.type)) lf.type else rf.type;
const eq = lf.toFloatType(tag).compare(rf.toFloatType(tag)) == .eq;
return value.Value.fromBool(if (op == .eq) eq else !eq);
}
const eq = value.equals(left, right);
return value.Value.fromBool(if (op == .eq) eq else !eq);
}
if (left.isInteger() and right.isInteger()) {
const left_int = left.asInt();
const right_int = right.asInt();
// 原生整数快速路径：同类型 i8..i64 / u8..u64 直接原生比较
if (left_int.type == right_int.type) {
switch (left_int.type) {
.i8 => return nativeIntOrd(i8, op, left_int, right_int),
.i16 => return nativeIntOrd(i16, op, left_int, right_int),
.i32 => return nativeIntOrd(i32, op, left_int, right_int),
.i64 => return nativeIntOrd(i64, op, left_int, right_int),
.u8 => return nativeIntOrd(u8, op, left_int, right_int),
.u16 => return nativeIntOrd(u16, op, left_int, right_int),
.u32 => return nativeIntOrd(u32, op, left_int, right_int),
.u64 => return nativeIntOrd(u64, op, left_int, right_int),
.i128, .u128 => {}, // 128 位走通用路径
}
}
const result_type = value.promoteIntTypes(left_int.type, right_int.type);
const lc = left_int.coerceTo(result_type) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
const rc = right_int.coerceTo(result_type) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
const ord = lc.compare(rc);
return value.Value.fromBool(switch (op) {
.lt => ord == .lt,
.gt => ord == .gt,
.le => ord != .gt,
.ge => ord != .lt,
else => unreachable,
});
}
if ((left.isFloat() or left.isInteger()) and (right.isFloat() or right.isInteger())) {
// 原生浮点快速路径：两操作数同为 f32 或 f64 时直接原生比较
if (left == .float and right == .float and left.float.type == right.float.type) {
switch (left.float.type) {
.f32 => {
const lv = left.float.toNative(f32);
const rv = right.float.toNative(f32);
return value.Value.fromBool(switch (op) {
.lt => lv < rv,
.gt => lv > rv,
.le => lv <= rv,
.ge => lv >= rv,
else => unreachable,
});
},
.f64 => {
const lv = left.float.toNative(f64);
const rv = right.float.toNative(f64);
return value.Value.fromBool(switch (op) {
.lt => lv < rv,
.gt => lv > rv,
.le => lv <= rv,
.ge => lv >= rv,
else => unreachable,
});
},
.f16, .f128 => {}, // 非原生宽度走通用路径
}
}
const tag: value.FloatType = if (left.isFloat() and right.isFloat()) blk: {
const lt = left.asFloat().type;
const rt = right.asFloat().type;
break :blk if (@intFromEnum(lt) > @intFromEnum(rt)) lt else rt;
} else if (left.isFloat()) left.asFloat().type else right.asFloat().type;
const lf: value.Float = if (left.isFloat()) left.asFloat().toFloatType(tag) else value.Float.fromInt(tag, left.asInt());
const rf: value.Float = if (right.isFloat()) right.asFloat().toFloatType(tag) else value.Float.fromInt(tag, right.asInt());
const ord = lf.compare(rf);
return value.Value.fromBool(switch (op) {
.lt => ord == .lt,
.gt => ord == .gt,
.le => ord != .gt,
.ge => ord != .lt,
else => unreachable,
});
}
if (left == .string and right == .string) {
const ord = std.mem.order(u8, left.string.bytes(), right.string.bytes());
return value.Value.fromBool(switch (op) {
.lt => ord == .lt,
.gt => ord == .gt,
.le => ord != .gt,
.ge => ord != .lt,
else => unreachable,
});
}
if (left == .char and right == .char) {
const lc = left.asChar().toNative();
const rc = right.asChar().toNative();
const ord: std.math.Order = if (lc < rc) .lt else if (lc > rc) .gt else .eq;
return value.Value.fromBool(switch (op) {
.lt => ord == .lt,
.gt => ord == .gt,
.le => ord != .gt,
.ge => ord != .lt,
else => unreachable,
});
}
return self.fail(loc, "comparison requires comparable operands", error.TypeMismatch);
}
/// 执行类型转换：数值类型走 castNumeric，其他类型按目标名分派。
fn doCast(self: *RegVM, src: value.Value, tname: []const u8, loc: ast.SourceLocation) VMError!value.Value {
if (std.mem.eql(u8, tname, type_names.str_type)) {
if (src == .char) {
const c = src.asChar().toNative();
var utf8_buf: [4]u8 = undefined;
const len = std.unicode.utf8Encode(c, &utf8_buf) catch return self.fail(loc, "invalid char codepoint", error.Unsupported);
const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
@memcpy(buf, utf8_buf[0..len]);
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, buf);
return value.Value{ .string = s };
}
if (src == .string) {
const dup = self.allocator.dupe(u8, src.string.bytes()) catch return error.OutOfMemory;
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, dup);
return value.Value{ .string = s };
}
const owned = src.formatAlloc(self.allocator) catch return error.OutOfMemory;
const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
s.* = value.Str.fromOwnedBytes(self.allocator, @constCast(owned));
return value.Value{ .string = s };
}
const result = cast.castNumeric(self.allocator, src, tname) catch |e| switch (e) {
error.CastOverflow => return self.fail(loc, "arithmetic overflow: narrowing conversion out of range", error.ArithmeticOverflow),
error.CastTypeMismatch => return self.fail(loc, "invalid type conversion", error.TypeMismatch),
error.OutOfMemory => return error.OutOfMemory,
};
return result;
}
/// 执行索引访问：数组按整数下标，字符串按字节范围，range 按 step 迭代。
fn doIndex(self: *RegVM, obj: value.Value, idx_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
switch (obj) {
.array => {
const arr = obj.array;
if (!idx_val.isInteger()) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
const iv = idx_val.asInt();
const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
const i = idx_coerced.toNative(i64);
if (i < 0 or i >= @as(i64, @intCast(arr.elements.len)))
return self.fail(loc, "index out of bounds", error.TypeMismatch);
return arr.elements[@intCast(i)].retain();
},
.string => {
const s = obj.string.bytes();
if (!idx_val.isInteger()) return self.fail(loc, "string index must be an integer", error.TypeMismatch);
const iv = idx_val.asInt();
const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
const i = idx_coerced.toNative(i64);
if (i < 0) return self.fail(loc, "index out of bounds", error.TypeMismatch);
const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
var iter = view.iterator();
var ci: i64 = 0;
while (iter.nextCodepoint()) |cp| : (ci += 1) {
if (ci == i) {
return value.Value.fromChar(value.Char.fromNative(cp) catch unreachable);
}
}
return self.fail(loc, "index out of bounds", error.TypeMismatch);
},
else => return self.fail(loc, "cannot index into this type", error.TypeMismatch),
}
}
/// 执行字段访问：记录按字段名查找，ADT 按字段名查找，其他类型报错。
fn doGetField(self: *RegVM, obj: value.Value, field: []const u8, loc: ast.SourceLocation) VMError!value.Value {
switch (obj) {
.adt => {
const av = obj.adt;
for (av.fields) |f| {
if (f.name) |n| {
if (std.mem.eql(u8, n, field)) {
return f.value.retain();
}
}
}
return self.fail(loc, "no such field on adt", error.TypeMismatch);
},
.record => {
const rec = obj.record;
if (rec.fields.get(field)) |v| {
return v.retain();
}
return self.fail(loc, "no such field on record", error.TypeMismatch);
},
.trait_value => {
const tv = obj.trait_value;
if (tv.methods.get(field)) |v| {
return v.retain();
}
return self.fail(loc, "no such member on module value", error.TypeMismatch);
},
.channel_val => {
const cv_ptr = obj.channel_val;
const fid = method.MethodId.fromName(field);
switch (fid) {
.sender => {
cv_ptr.ref();
const sv = self.allocator.create(value.SenderValue) catch return error.OutOfMemory;
sv.* = .{ .channel = cv_ptr };
return value.Value{ .sender_val = sv };
},
.receiver => {
cv_ptr.ref();
const rv = self.allocator.create(value.ReceiverValue) catch return error.OutOfMemory;
rv.* = .{ .channel = cv_ptr };
return value.Value{ .receiver_val = rv };
},
else => return self.fail(loc, "no such field on Channel (only 'sender'/'receiver')", error.TypeMismatch),
}
},
else => {
    return self.fail(loc, "field access on non-record/adt", error.TypeMismatch);
},
}
}
/// 执行字段赋值：记录复制后更新字段，ADT 复制后替换字段值。
fn doSetField(self: *RegVM, obj: value.Value, field: []const u8, new_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
if (obj != .record) return self.fail(loc, "cannot assign field on non-record", error.TypeMismatch);
const old_rec = obj.record;
var new_map = std.StringHashMap(value.Value).init(self.allocator);
var it = old_rec.fields.iterator();
while (it.next()) |e| {
const key = self.allocator.dupe(u8, e.key_ptr.*) catch return error.OutOfMemory;
new_map.put(key, e.value_ptr.*.retain()) catch return error.OutOfMemory;
}
if (new_map.getPtr(field)) |existing| {
existing.*.release(self.allocator);
existing.* = new_val.retain();
} else {
const key = self.allocator.dupe(u8, field) catch return error.OutOfMemory;
new_map.put(key, new_val.retain()) catch return error.OutOfMemory;
}
const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
rec_ptr.* = .{ .type_name = old_rec.type_name, .fields = new_map };
return value.Value{ .record = rec_ptr };
}
/// 执行索引赋值：数组按整数下标替换元素。
fn doSetIndex(self: *RegVM, obj: value.Value, idx_val: value.Value, new_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
if (obj != .array) return self.fail(loc, "cannot index-assign on non-array", error.TypeMismatch);
if (!idx_val.isInteger()) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
const iv = idx_val.asInt();
const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
const i = idx_coerced.toNative(i64);
const old_elems = obj.array.elements;
if (i < 0 or i >= @as(i64, @intCast(old_elems.len)))
return self.fail(loc, "index out of bounds", error.TypeMismatch);
const new_elems = self.allocator.alloc(value.Value, old_elems.len) catch return error.OutOfMemory;
for (old_elems, 0..) |e, k| new_elems[k] = e.retain();
new_elems[@intCast(i)].release(self.allocator);
new_elems[@intCast(i)] = new_val.retain();
const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
arr_ptr.* = .{ .elements = new_elems, .capacity = new_elems.len, .fixed_size = obj.array.fixed_size };
return value.Value{ .array = arr_ptr };
}
/// 执行方法调用：依次尝试内建方法（array/string/atomic/channel/spawn）、
/// trait 方法分派、闭包值调用与 VM 函数调用，支持内联缓存加速。
fn doCallMethod(self: *RegVM, recv: value.Value, name: []const u8, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
const method_id = method.MethodId.fromName(name);
if (method_id != .unknown) {
if (recv != .spawn_val and recv != .trait_value) {
const result_opt = method.dispatchById(self.allocator, recv, method_id, args) catch |err| switch (err) {
error.NoSuchMethod => null,
error.WrongArity => return self.fail(loc, "method called with wrong number of arguments", error.WrongArity),
error.TypeMismatch => return self.fail(loc, "method not available on this type", error.TypeMismatch),
error.ChannelClosed => return self.fail(loc, "channel: send on closed channel", error.TypeMismatch),
error.ArithmeticOverflow => return self.fail(loc, "method result out of range", error.ArithmeticOverflow),
error.OutOfMemory => return error.OutOfMemory,
};
if (result_opt) |result| return result;
}
}
if (recv == .spawn_val) {
return try self.doSpawnMethod(recv.spawn_val, name, args, loc);
}
if (recv == .trait_value) {
const tv = recv.trait_value;
if (tv.methods.get(name)) |method_val| {
return try self.invokeClosure(method_val, args, loc);
}
return self.fail(loc, "no such method on trait", error.TypeMismatch);
}
const err_mid = method.MethodId.fromName(name);
if (err_mid == .message or err_mid == .type_name) {
if (args.len != 0) return self.fail(loc, "Error trait method expects 0 arguments", error.WrongArity);
switch (recv) {
.error_val => {
const e = recv.error_val;
const field_value = if (err_mid == .message) e.message else e.type_name;
return value.Value.fromStringBytes(self.allocator, field_value) catch error.OutOfMemory;
},
.throw_val => {
const tv = recv.throw_val;
if (tv.payload == .err) {
const e = tv.payload.err;
const field_value = if (err_mid == .message) e.message else e.type_name;
return value.Value.fromStringBytes(self.allocator, field_value) catch error.OutOfMemory;
} else {
return self.fail(loc, "cannot call Error method on Ok value", error.TypeMismatch);
}
},
else => {},
}
}
if (self.program) |prog| {
const recv_type = regValueTypeName(recv);
if (findRegTraitMethod(prog, recv_type, name)) |func_idx| {
return try self.invokeRegMethodBody(prog, func_idx, recv, args, loc);
}
if (findRegTraitDefault(prog, name)) |func_idx| {
return try self.invokeRegMethodBody(prog, func_idx, recv, args, loc);
}
}
const result = method.dispatch(self.allocator, recv, name, args) catch |err| switch (err) {
error.NoSuchMethod => return self.fail(loc, "no such method on this type", error.TypeMismatch),
error.WrongArity => return self.fail(loc, "method called with wrong number of arguments", error.WrongArity),
error.TypeMismatch => return self.fail(loc, "method not available on this type", error.TypeMismatch),
error.ChannelClosed => return self.fail(loc, "channel: send on closed channel", error.TypeMismatch),
error.ArithmeticOverflow => return self.fail(loc, "method result out of range", error.ArithmeticOverflow),
error.OutOfMemory => return error.OutOfMemory,
};
return result;
}
/// 调用 RegProgram 中的方法体：设置新帧，接收者作为 self 参数传入。
fn invokeRegMethodBody(self: *RegVM, program: *const reg_chunk.RegProgram, func_idx: u16, recv: value.Value, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
const f = &program.functions.items[func_idx];
const total: usize = 1 + args.len;
if (total != f.arity) return self.fail(loc, "trait method arity mismatch", error.WrongArity);
const all_args = self.allocator.alloc(value.Value, f.arity) catch return error.OutOfMemory;
defer self.allocator.free(all_args);
all_args[0] = recv;
for (args, 0..) |a, i| all_args[1 + i] = a;
const saved_stop = self.stop_depth;
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
defer self.stop_depth = saved_stop;
defer self.single_step = saved_single_step;
defer self.step_count = saved_step_count;
try self.setupFrame(f, all_args, 0, 0);
self.stop_depth = self.frames.items.len;
self.single_step = false;
self.step_count = 0;
return try self.runLoop();
}
/// 调用闭包值：从闭包提取函数与 upvalue，设置新帧后运行。
fn invokeClosure(self: *RegVM, closure_val: value.Value, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
if (closure_val != .vm_closure) return self.fail(loc, "trait method is not callable", error.TypeMismatch);
const vc = closure_val.vm_closure;
const total = vc.bound_args.len + args.len;
if (total != vc.arity) return self.fail(loc, "trait method arity mismatch", error.WrongArity);
const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
defer self.allocator.free(all_args);
for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
for (args, 0..) |a, i| all_args[vc.bound_args.len + i] = a;
const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
const saved_stop = self.stop_depth;
const saved_single_step = self.single_step;
const saved_step_count = self.step_count;
defer self.stop_depth = saved_stop;
defer self.single_step = saved_single_step;
defer self.step_count = saved_step_count;
try self.setupFrame(callee, all_args, 0, 0);
self.frames.items[self.frames.items.len - 1].upvalues = vc.upvalues;
self.stop_depth = self.frames.items.len;
self.single_step = false;
self.step_count = 0;
return try self.runLoop();
}
/// 执行 Spawn 值的方法调用：await/cancel/status 等异步控制操作。
fn doSpawnMethod(self: *RegVM, handle: *value.SpawnHandle, name: []const u8, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
const mid = method.MethodId.fromName(name);
switch (mid) {
.await_op => {
if (args.len != 0) return self.fail(loc, "await expects 0 arguments", error.WrongArity);
handle.mutex.lock();
const child_result = handle.result;
handle.consumed.store(true, .seq_cst);
const failed = handle.status.load(.seq_cst) == .Failed;
handle.mutex.unlock();
if (failed) {
const msg = handle.panic_message orelse "spawn: coroutine failed";
return self.fail(loc, msg, error.InvalidSpawn);
}
return if (child_result) |r| r.retain() else value.Value.fromUnit();
},
.cancel => {
if (args.len != 0) return self.fail(loc, "cancel expects 0 arguments", error.WrongArity);
handle.mutex.lock();
handle.status.store(.Cancelled, .seq_cst);
handle.consumed.store(true, .seq_cst);
handle.condition.broadcast();
handle.mutex.unlock();
return value.Value.fromUnit();
},
.status => {
if (args.len != 0) return self.fail(loc, "status expects 0 arguments", error.WrongArity);
const s = handle.status.load(.seq_cst);
const ctor: []const u8 = @tagName(s);
return value.Value.makeAdt(self.allocator, type_names.spawn_status_type, ctor, &[_]value.AdtField{}) catch error.OutOfMemory;
},
else => return self.fail(loc, "no such method on Spawn", error.TypeMismatch),
}
}
};
/// 内建数值类型枚举，用于 trait 方法分派时的数值类型匹配。
const NumericType = enum {
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
fn isNumericTypeName(name: []const u8) bool {
return parseNumericType(name) != null;
}
/// 判断两个数值类型名是否同类（同为整数或同为浮点）。
fn numericKindMatches(a: []const u8, b: []const u8) bool {
const na = parseNumericType(a) orelse return false;
const nb = parseNumericType(b) orelse return false;
return na.isFloat() == nb.isFloat();
}
/// 判断接收者类型是否匹配目标 trait 类型：空目标通配，同名匹配，数值同类匹配。
fn regTraitTypeMatches(recv: []const u8, target_ty: []const u8) bool {
if (target_ty.len == 0) return true;
if (std.mem.eql(u8, recv, target_ty)) return true;
return isNumericTypeName(recv) and isNumericTypeName(target_ty) and numericKindMatches(recv, target_ty);
}
/// 在 trait 方法表中查找匹配接收者类型与方法名的函数索引。
fn findRegTraitMethod(program: *const reg_chunk.RegProgram, recv_type: []const u8, method_name: []const u8) ?u16 {
for (program.trait_methods.items) |d| {
if (std.mem.eql(u8, d.method_name, method_name) and regTraitTypeMatches(recv_type, d.type_name)) return d.func_idx;
}
return null;
}
/// 在 trait 默认实现表中查找匹配方法名的函数索引。
fn findRegTraitDefault(program: *const reg_chunk.RegProgram, method_name: []const u8) ?u16 {
for (program.trait_defaults.items) |d| {
if (std.mem.eql(u8, d.method_name, method_name)) return d.func_idx;
}
return null;
}
