//! 寄存器式 VM 执行引擎。
//! 全局寄存器池：单个大 Value 数组，帧通过 base_offset 划分。
//! 每帧占用 register_count 个连续槽位：[base, base+register_count)
//!
//! 与栈式 vm.zig 的 doArith/doCompare 镜像，但操作数从寄存器读取而非操作数栈弹栈。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const reg_opcode = @import("reg_opcode.zig");
const reg_chunk = @import("reg_chunk.zig");
const profiler_mod = @import("profiler");
const slab_allocator = @import("slab_allocator");

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
} || std.mem.Allocator.Error;

/// 全局寄存器池大小（1M 个 Value 槽）
const REG_POOL_SIZE: usize = 1024 * 1024;
/// 最大帧深度
const MAX_FRAMES: usize = 64 * 1024;
/// 无效 memo_slot 标记
const MEMO_SLOT_NONE: u16 = 0xFFFF;

/// 调用帧
const RegFrame = struct {
    func: *const reg_chunk.RegFunction,
    ip: usize, // 指令索引（非字节偏移）
    base: usize, // 本帧在全局寄存器池中的基址
    upvalues: []const value.Value, // 闭包捕获值
    memo_slot: u16, // MEMO_SLOT_NONE = 非 memoized
    memo_arg_hash: u64,
    /// 调用者帧中存放返回值的基址
    return_base: usize,
    /// 调用者帧中存放返回值的寄存器号
    return_reg: u8,
};

const MemoKey = struct {
    slot: u16,
    arg_hash: u64,
};

/// 寄存器式 VM
pub const RegVM = struct {
    allocator: std.mem.Allocator,
    /// 全局寄存器池
    reg_pool: []value.Value,
    /// 帧栈
    frames: std.ArrayListUnmanaged(RegFrame) = .empty,
    /// 程序指针
    program: ?*const reg_chunk.RegProgram = null,
    /// 全局变量区
    globals: std.ArrayListUnmanaged(value.Value) = .empty,
    /// IC slot 池（方法分派缓存）
    ic_slots: std.ArrayListUnmanaged(IcSlot) = .empty,
    /// memoization 缓存
    memo_cache: std.AutoHashMapUnmanaged(MemoKey, value.Value) = .empty,
    /// memo slot miss 计数
    memo_slot_misses: std.AutoHashMapUnmanaged(u16, u32) = .empty,
    /// 被禁用的 memo slot
    memo_disabled_slots: std.AutoHashMapUnmanaged(u16, void) = .empty,
    /// profiler
    profiler: ?*profiler_mod.Profiler = null,
    /// 诊断字段（与栈式 VM 保持兼容）
    err_msg: ?[]const u8 = null,
    err_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
    /// stop_depth（spawn 边界）
    stop_depth: usize = 0,

    const IcSlot = struct {
        cached_tag: u8 = 0,
        method_id: u8 = 0,
        is_builtin: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) RegVM {
        const pool = allocator.alloc(value.Value, REG_POOL_SIZE) catch unreachable;
        @memset(pool, value.Value.fromNull());
        return .{
            .allocator = allocator,
            .reg_pool = pool,
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) RegVM {
        _ = io;
        return init(allocator);
    }

    pub fn initWithCache(cache: *slab_allocator.ThreadCache, io: std.Io) RegVM {
        _ = io;
        return init(cache.allocator());
    }

    pub fn setProfiler(self: *RegVM, p: *profiler_mod.Profiler) void {
        self.profiler = p;
    }

    pub fn deinit(self: *RegVM) void {
        self.allocator.free(self.reg_pool);
        self.frames.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.ic_slots.deinit(self.allocator);
        self.memo_cache.deinit(self.allocator);
        self.memo_slot_misses.deinit(self.allocator);
        self.memo_disabled_slots.deinit(self.allocator);
        // err_msg 指向字符串字面量，无需 free
    }

    /// 主入口：调用函数
    pub fn call(self: *RegVM, program: *const reg_chunk.RegProgram, entry: u16, args: []const value.Value) VMError!value.Value {
        self.program = program;
        // 运行全局初始化
        if (program.globals_init) |gi| {
            try self.globals.resize(self.allocator, program.global_count);
            @memset(self.globals.items, value.Value.fromNull());
            try self.setupFrame(&program.functions.items[gi], &.{}, 0, 0);
            self.stop_depth = 1;
            _ = try self.runLoop();
        }
        // 建立入口帧
        const func = &program.functions.items[entry];
        try self.setupFrame(func, args, 0, 0);
        self.stop_depth = self.frames.items.len;
        return try self.runLoop();
    }

    /// 建立新帧。return_base/return_reg 指示调用者存放返回值的位置。
    /// args 中的 Value 会被 retain（callee 帧持有自己的引用）。
    fn setupFrame(self: *RegVM, func: *const reg_chunk.RegFunction, args: []const value.Value, return_base: usize, return_reg: u8) VMError!void {
        if (self.frames.items.len >= MAX_FRAMES) return error.StackOverflow;
        // 分配寄存器区间：紧接上一帧之后
        const base = if (self.frames.items.len == 0) 0 else blk: {
            const prev = &self.frames.items[self.frames.items.len - 1];
            break :blk prev.base + prev.func.register_count;
        };
        if (base + func.register_count > self.reg_pool.len) return error.StackOverflow;

        // 参数放入寄存器 [base, base+arity)，retain 确保 callee 持有独立引用
        for (args, 0..) |a, i| {
            if (i >= func.arity) break;
            self.reg_pool[base + i] = a.retain();
        }
        // 其余寄存器初始化为 unit
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

    /// 主执行循环
    fn runLoop(self: *RegVM) VMError!value.Value {
        var result: value.Value = value.Value.fromUnit();
        while (self.frames.items.len >= self.stop_depth) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const func = frame.func;
            const code = func.chunk.code.items;
            const base = frame.base;
            const ip = frame.ip;
            if (ip >= code.len) return error.InvalidInstruction;
            const inst = code[ip];
            const op = reg_opcode.getOp(inst);
            const a = reg_opcode.getA(inst);
            const b = reg_opcode.getB(inst);
            const c = reg_opcode.getC(inst);
            const bx = reg_opcode.getBx(inst);
            const sbx = reg_opcode.getsBx(inst);
            const loc = func.chunk.locAt(ip);
            frame.ip = ip + 1; // 预推进

            switch (op) {
                // ── 加载/常量 ──
                .load_const => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = func.chunk.constants.items[bx].retain();
                },
                .load_null => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromNull();
                },
                .load_unit => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromUnit();
                },
                .load_true => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(true);
                },
                .load_false => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(false);
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

                // ── 寄存器间移动 ──
                .move, .bind, .assign => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = self.reg_pool[base + b].retain();
                },
                .move_raw => {
                    // 不 retain（用于 atomic 透明读），仅覆盖槽位
                    self.reg_pool[base + a] = self.reg_pool[base + b];
                },
                .bind_letrec => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = self.reg_pool[base + b].retain();
                },

                // ── 算术（二元）──
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor => {
                    const result_val = try self.doArith(op, self.reg_pool[base + b], self.reg_pool[base + c], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 算术（一元）──
                .neg => {
                    const result_val = try self.doNegate(self.reg_pool[base + b], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 比较 ──
                .eq, .neq, .lt, .gt, .le, .ge => {
                    const result_val = try self.doCompare(op, self.reg_pool[base + b], self.reg_pool[base + c], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 逻辑非 ──
                .not_op => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(!self.reg_pool[base + b].asBool());
                },

                // ── 跳转 ──
                .jump => {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                },
                .jump_if_false => {
                    if (!self.reg_pool[base + a].asBool()) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_true => {
                    if (self.reg_pool[base + a].asBool()) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_null => {
                    if (self.reg_pool[base + a] == .null_val) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_not_null => {
                    if (self.reg_pool[base + a] != .null_val) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },

                // ── 调用 ──
                .call => {
                    const func_idx = bx;
                    const argc = c;
                    // 参数在 [base+a+1, base+a+1+argc)
                    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
                    const callee = &self.program.?.functions.items[func_idx];
                    // setupFrame 会 retain 参数，callee 帧持有独立引用
                    try self.setupFrame(callee, args_slice, base, a);
                },

                // ── 返回 ──
                .return_op => {
                    const ret_val = self.reg_pool[base + a].retain();
                    try self.frameReturn();
                    if (self.frames.items.len < self.stop_depth) {
                        result = ret_val;
                        break;
                    }
                    // 返回值放入调用者的目标寄存器
                    const caller = &self.frames.items[self.frames.items.len - 1];
                    self.reg_pool[caller.return_base + caller.return_reg].release(self.allocator);
                    self.reg_pool[caller.return_base + caller.return_reg] = ret_val;
                },
                .return_unit => {
                    try self.frameReturn();
                    if (self.frames.items.len < self.stop_depth) {
                        result = value.Value.fromUnit();
                        break;
                    }
                    const caller = &self.frames.items[self.frames.items.len - 1];
                    self.reg_pool[caller.return_base + caller.return_reg].release(self.allocator);
                    self.reg_pool[caller.return_base + caller.return_reg] = value.Value.fromUnit();
                },

                // ── 显式释放 ──
                .release => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromNull();
                },

                // ── 其余 opcode 后续阶段实现 ──
                else => return error.InvalidInstruction,
            }
        }
        return result;
    }

    /// 帧返回：释放本帧寄存器
    fn frameReturn(self: *RegVM) VMError!void {
        const frame = self.frames.items[self.frames.items.len - 1];
        const func = frame.func;
        const base = frame.base;
        // 释放本帧寄存器（release_mask 优化：仅释放持 boxed 值的寄存器）
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

    // ============================================================
    // helper 函数
    // ============================================================

    fn fail(self: *RegVM, loc: ast.SourceLocation, msg: []const u8, e: VMError) VMError {
        self.err_loc = loc;
        self.err_msg = msg;
        return e;
    }

    /// 算术运算（二元）。镜像栈式 VM 的 doArith，但操作数直接从寄存器读取。
    fn doArith(self: *RegVM, op: reg_opcode.Op, left: value.Value, right: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        // 整数运算
        if (left.isInteger() and right.isInteger()) {
            const left_int = left.asInt();
            const right_int = right.asInt();

            // 位运算（保留 left 类型）
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

        // 浮点运算（含 int↔float 混合，提升为 float）
        if ((left.isFloat() or left.isInteger()) and (right.isFloat() or right.isInteger())) {
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

        return self.fail(loc, "arithmetic requires numeric operands", error.TypeMismatch);
    }

    /// 一元取负。镜像栈式 VM 的 doNegate。
    fn doNegate(self: *RegVM, v: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        if (v.isInteger()) {
            const int_val = v.asInt();
            const result = int_val.negate();
            // minInt 取负回绕：输入负但结果仍负 → 溢出
            if (int_val.type.isSigned() and int_val.isNegative() and result.isNegative()) {
                return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
            }
            return value.Value.fromInt(result);
        }
        if (v.isFloat()) {
            return value.Value.fromFloat(v.asFloat().negate());
        }
        return self.fail(loc, "'-' requires numeric operand", error.TypeMismatch);
    }

    /// 比较：== != < > <= >=。镜像栈式 VM 的 doCompare。
    fn doCompare(self: *RegVM, op: reg_opcode.Op, left: value.Value, right: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        // == / !=：数值按 promoteIntTypes 后按值比较（忽略 type_tag）
        if (op == .eq or op == .neq) {
            if (left.isInteger() and right.isInteger()) {
                const left_int = left.asInt();
                const right_int = right.asInt();
                const rt = value.promoteIntTypes(left_int.type, right_int.type);
                const lc = left_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
                const rc = right_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
                const eq = lc.compare(rc) == .eq;
                return value.Value.fromBool(if (op == .eq) eq else !eq);
            }
            if (left.isFloat() and right.isFloat()) {
                const lf = left.asFloat();
                const rf = right.asFloat();
                const tag: value.FloatType = if (@intFromEnum(lf.type) > @intFromEnum(rf.type)) lf.type else rf.type;
                const eq = lf.toFloatType(tag).compare(rf.toFloatType(tag)) == .eq;
                return value.Value.fromBool(if (op == .eq) eq else !eq);
            }
            const eq = value.equals(left, right);
            return value.Value.fromBool(if (op == .eq) eq else !eq);
        }

        // < > <= >=
        if (left.isInteger() and right.isInteger()) {
            const left_int = left.asInt();
            const right_int = right.asInt();
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
        // 字符串字典序比较
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
        // char 序比较
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
};
