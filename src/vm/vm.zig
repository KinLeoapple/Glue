//! Glue 字节码 VM — 执行引擎（M0 骨架）
//!
//! 设计见 docs/bytecode-vm-plan.md §3/§6。M0 单帧执行（无 CALL/RETURN 跨帧），
//! 验证操作数栈 + dispatch 循环 + 算术核 + 局部变量 slot + 跳转。
//!
//! 栈所有权不变式（§6.1）：栈上每个 Value 持有一份 owned 引用。
//! 压栈即 +1（retain/retainOwned），弹栈消费即 -1（release）。
//! 局部变量住在操作数栈 slot_base + slot 处（M0 slot_base=0）。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const opcode = @import("opcode.zig");
const chunk_mod = @import("chunk.zig");

const OpCode = opcode.OpCode;
const Chunk = chunk_mod.Chunk;
const Function = chunk_mod.Function;
const Program = chunk_mod.Program;
const Value = value.Value;
const IntValue = value.IntValue;
const FloatValue = value.FloatValue;

pub const VMError = error{
    OutOfMemory,
    StackUnderflow,
    TypeMismatch,
    DivisionByZero,
    ArithmeticOverflow,
    WrongArity,
    StackOverflow,
    Unsupported,
};

/// 调用帧（M1a/M1b）。局部变量住操作数栈 slot_base..slot_base+slot_count-1。
/// ip 是本帧在其函数 chunk 内的指令指针。
/// func 直接存 *const Function（OP_CALL 与 OP_CALL_VALUE 两路统一）。
/// frame_base：返回时栈回退到的位置 + 结果压入处。
///   - OP_CALL（callee 不在栈上）：frame_base == slot_base。
///   - OP_CALL_VALUE（callee 在 args 下方）：frame_base == slot_base - 1，stack[frame_base] 为 callee，
///     返回时额外 release。
/// upvalues：闭包捕获值（M1b-1 恒空，M1b-2 填充）。
pub const CallFrame = struct {
    func: *const Function,
    ip: usize,
    slot_base: usize,
    frame_base: usize,
    upvalues: []const Value = &.{},
};

/// 调用深度上限（防爆栈 / 无限递归）。
const MAX_FRAMES: usize = 64 * 1024;

/// 字面量模式比较（OP_TEST_LIT 语义，对齐树遍历器 matchLiteralPattern）：
/// int/float 仅比值（忽略 type_tag），bool/char/string/null 按内容。类型不符即 false。
fn literalPatternEq(pat: Value, obj: Value) bool {
    return switch (pat) {
        .integer => |pv| obj == .integer and obj.integer.value == pv.value,
        .float => |pv| obj == .float and obj.float.value == pv.value,
        .boolean => |b| obj == .boolean and obj.boolean == b,
        .char_val => |c| obj == .char_val and obj.char_val == c,
        .string => |s| obj == .string and std.mem.eql(u8, obj.string, s),
        .null_val => obj.isNull(),
        else => false,
    };
}

pub const VM = struct {
    /// 操作数栈：局部变量也住这里（slot_base + slot 索引）。
    stack: std.ArrayListUnmanaged(Value) = .empty,
    /// 调用帧栈（堆上，不吃 Zig 原生栈 → 深递归不爆 Zig 栈）。
    frames: std.ArrayListUnmanaged(CallFrame) = .empty,
    /// 值分配器（与求值器 value_allocator 同源，refcount 字节走这里）。
    allocator: std.mem.Allocator,
    /// 运行期错误位置（panic 报告用）。
    err_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
    err_msg: ?[]const u8 = null,
    /// IO 句柄（原生 println/print 输出到 stdout）；null 时回退 std.debug.print。
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) VM {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *VM) void {
        // 退出时栈上残留值 release（正常执行后栈应为空或仅留结果）。
        for (self.stack.items) |v| v.release(self.allocator);
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn push(self: *VM, v: Value) VMError!void {
        try self.stack.append(self.allocator, v);
    }

    fn pop(self: *VM) Value {
        return self.stack.pop().?;
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    /// string 须 dupe 独立 owned（retain 对 string 是 no-op，见 §6.3）。
    fn retainOwned(self: *VM, v: Value) VMError!Value {
        if (v == .string) return Value{ .string = try self.allocator.dupe(u8, v.string) };
        return v.retain();
    }

    fn fail(self: *VM, loc: ast.SourceLocation, msg: []const u8, e: VMError) VMError {
        self.err_loc = loc;
        self.err_msg = msg;
        return e;
    }

    /// 执行 program 中索引为 entry 的函数，args 为实参（owned，所有权移交给 VM）。
    /// 返回该函数的返回值（owned，调用方负责 release）。
    /// M1a：跨帧 CALL/RETURN，callee 用 func_idx 立即数（无一等函数值）。
    pub fn call(self: *VM, program: *const Program, entry: u16, args: []const Value) VMError!Value {
        const f = &program.functions.items[entry];
        if (args.len != f.arity) return self.fail(.{ .line = 0, .column = 0 }, "wrong number of arguments", error.WrongArity);
        // 建立入口帧：实参占 slot 0..arity-1，其余局部槽补 unit 占位。
        const slot_base = self.stack.items.len;
        for (args) |a| try self.push(a); // 所有权移交栈（slot）
        var s: u16 = f.arity;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = slot_base, .frame_base = slot_base });
        return self.runLoop(program);
    }

    /// 主 dispatch 循环。从当前帧（frames 顶）取码执行，CALL 压帧、RETURN 弹帧。
    /// 当入口帧 RETURN（frames 清空）时返回其结果。
    fn runLoop(self: *VM, program: *const Program) VMError!Value {
        while (true) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const func = frame.func;
            const code = func.chunk.code.items;
            const op: OpCode = @enumFromInt(code[frame.ip]);
            const loc = func.chunk.lines.items[frame.ip];
            frame.ip += 1;
            switch (op) {
                .op_const => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.push(try self.retainOwned(func.chunk.constants.items[idx]));
                },
                .op_null => try self.push(Value.null_val),
                .op_unit => try self.push(Value.unit),
                .op_true => try self.push(Value{ .boolean = true }),
                .op_false => try self.push(Value{ .boolean = false }),

                .op_get_local => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cur = self.stack.items[frame.slot_base + slot];
                    // 透明解 cell：被闭包捕获的 local 已就地 box 成 *Cell，读其 inner。
                    const v = if (cur == .cell_val) cur.cell_val.inner else cur;
                    try self.push(try self.retainOwned(v));
                },
                .op_set_local => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const dst = frame.slot_base + slot;
                    const cur = self.stack.items[dst];
                    if (cur == .cell_val) {
                        // 透明写 cell：mutation 对共享该 cell 的闭包可见。
                        cur.cell_val.inner.release(self.allocator);
                        cur.cell_val.inner = v;
                    } else {
                        cur.release(self.allocator); // 释放旧值
                        self.stack.items[dst] = v; // 所有权从栈转移到 slot
                    }
                },
                .op_get_upvalue => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cell = frame.upvalues[idx].cell_val;
                    try self.push(try self.retainOwned(cell.inner));
                },
                .op_set_upvalue => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const cell = frame.upvalues[idx].cell_val;
                    cell.inner.release(self.allocator);
                    cell.inner = v;
                },

                .op_add, .op_sub, .op_mul, .op_div, .op_mod, .op_bit_and, .op_bit_or, .op_bit_xor => {
                    const right = self.pop();
                    const left = self.pop();
                    defer left.release(self.allocator);
                    defer right.release(self.allocator);
                    try self.push(try self.arith(op, left, right, loc));
                },
                .op_eq, .op_neq, .op_lt, .op_gt, .op_le, .op_ge => {
                    const right = self.pop();
                    const left = self.pop();
                    defer left.release(self.allocator);
                    defer right.release(self.allocator);
                    try self.push(try self.compare(op, left, right, loc));
                },
                .op_neg => {
                    const v = self.pop();
                    defer v.release(self.allocator);
                    try self.push(try self.negate(v, loc));
                },
                .op_not => {
                    const v = self.pop();
                    defer v.release(self.allocator);
                    const b = v.asBoolean() catch return self.fail(loc, "'!' requires boolean operand", error.TypeMismatch);
                    try self.push(Value{ .boolean = !b });
                },

                .op_jump => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                .op_jump_if_false => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    const cond = self.peek(0).asBoolean() catch return self.fail(loc, "condition must be boolean", error.TypeMismatch);
                    if (!cond) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                .op_jump_if_true => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    const cond = self.peek(0).asBoolean() catch return self.fail(loc, "condition must be boolean", error.TypeMismatch);
                    if (cond) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },

                .op_pop => self.pop().release(self.allocator),
                .op_pop_n => {
                    const n = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    var k: u16 = 0;
                    while (k < n) : (k += 1) self.pop().release(self.allocator);
                },
                .op_dup => try self.push(try self.retainOwned(self.peek(0))),

                .op_call => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doCall(program, func_idx, argc, loc);
                    // doCall 压入新帧；下轮循环自然切换到 callee（frame 指针失效，循环顶部重取）。
                },

                .op_tail_call => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doTailCall(program, func_idx, argc, loc);
                    // 复用当前帧（不增 frames）；下轮循环顶部重取 frame（已就地改写）。
                },

                .op_closure => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const n = code[frame.ip + 2];
                    frame.ip += 3;
                    const f = &program.functions.items[func_idx];
                    const ups: []Value = if (n > 0) try self.allocator.alloc(Value, n) else &.{};
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        const is_local = code[frame.ip] == 1;
                        const index = opcode.readU16(code, frame.ip + 1);
                        frame.ip += 3;
                        if (is_local) {
                            // 捕获 enclosing(当前)帧的 local[index]：就地 box 成 *Cell（若尚非 cell），
                            // 闭包与帧共享同一 cell（mutation 双向可见，cell rc 独立于帧 → 逃逸存活）。
                            const dst = frame.slot_base + index;
                            const cur = self.stack.items[dst];
                            if (cur != .cell_val) {
                                const cell = try self.allocator.create(value.Cell);
                                cell.* = .{ .inner = cur, .rc = 1 }; // 接管 slot 原 owned 值
                                self.stack.items[dst] = Value{ .cell_val = cell };
                            }
                            ups[k] = (Value{ .cell_val = self.stack.items[dst].cell_val }).retain();
                        } else {
                            // 捕获 enclosing 闭包的 upvalue[index]：共享同一 cell。
                            ups[k] = (Value{ .cell_val = frame.upvalues[index].cell_val }).retain();
                        }
                    }
                    const vc = try self.allocator.create(value.VmClosure);
                    vc.* = .{ .func = f, .arity = f.arity, .upvalues = ups, .rc = 1, .allocator = self.allocator };
                    try self.push(Value{ .vm_closure = vc });
                },

                .op_call_value => {
                    const argc = code[frame.ip];
                    frame.ip += 1;
                    try self.doCallValue(argc, loc);
                    // 足参→压新帧（下轮切换）；不足→partial 已压栈，继续本帧。
                },

                .op_call_native => {
                    const nid = code[frame.ip];
                    const argc = code[frame.ip + 1];
                    frame.ip += 2;
                    try self.doCallNative(@enumFromInt(nid), argc, loc);
                },

                // M2a：复合值 / 模式匹配。
                .op_make_adt => {
                    const ctor_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doMakeAdt(program, ctor_idx, argc, loc);
                },
                .op_get_field => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const field = func.chunk.constants.items[name_idx].string;
                    try self.doGetField(field, loc);
                },
                .op_get_adt_field => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const obj = self.pop();
                    defer obj.release(self.allocator);
                    if (obj != .adt or idx >= obj.adt.fields.len)
                        return self.fail(loc, "OP_GET_ADT_FIELD on non-adt or out-of-range", error.TypeMismatch);
                    try self.push(try self.retainOwned(obj.adt.fields[idx].value));
                },
                .op_test_ctor => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const want = func.chunk.constants.items[name_idx].string;
                    const obj = self.pop();
                    defer obj.release(self.allocator);
                    const matched = obj == .adt and std.mem.eql(u8, obj.adt.constructor, want);
                    try self.push(Value{ .boolean = matched });
                },
                .op_match_fail => return self.fail(loc, "match: no arm matched", error.TypeMismatch),

                // M2b：数组 / 记录字面量 / 索引。
                .op_make_array => {
                    const n = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const elems = self.allocator.alloc(Value, n) catch return error.OutOfMemory;
                    const base = self.stack.items.len - n;
                    @memcpy(elems, self.stack.items[base..][0..n]); // 接管 owned
                    self.stack.shrinkRetainingCapacity(base);
                    const arr = value.Value.makeArray(self.allocator, elems, null) catch return error.OutOfMemory;
                    try self.push(arr);
                },
                .op_make_record => {
                    const shape_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.doMakeRecord(program, shape_idx);
                },
                .op_index => {
                    const index_val = self.pop();
                    defer index_val.release(self.allocator);
                    const object = self.pop();
                    defer object.release(self.allocator);
                    try self.doIndex(object, index_val, loc);
                },

                // M2c：全模式 match / 记录扩展 / newtype。
                .op_test_lit => {
                    const cidx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const pat = func.chunk.constants.items[cidx];
                    const obj = self.pop();
                    defer obj.release(self.allocator);
                    try self.push(Value{ .boolean = literalPatternEq(pat, obj) });
                },
                .op_record_extend => {
                    const shape_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.doRecordExtend(program, shape_idx, loc);
                },
                .op_make_newtype => {
                    const nt_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const inner = self.pop(); // 接管 owned
                    const nv = self.allocator.create(value.NewtypeValue) catch return error.OutOfMemory;
                    nv.* = .{ .type_name = program.newtype_ctors.items[nt_idx].type_name, .inner = inner, .rc = 1 };
                    try self.push(Value{ .newtype = nv });
                },
                .op_test_newtype => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const want = func.chunk.constants.items[name_idx].string;
                    const obj = self.pop();
                    defer obj.release(self.allocator);
                    const matched = obj == .newtype and std.mem.eql(u8, obj.newtype.type_name, want);
                    try self.push(Value{ .boolean = matched });
                },
                .op_get_newtype_inner => {
                    const obj = self.pop();
                    defer obj.release(self.allocator);
                    if (obj != .newtype) return self.fail(loc, "OP_GET_NEWTYPE_INNER on non-newtype", error.TypeMismatch);
                    try self.push(try self.retainOwned(obj.newtype.inner));
                },

                .op_return => {
                    const result = self.pop();
                    // 释放本帧局部槽（slot_base..slot_base+slot_count-1）。
                    const base = frame.slot_base;
                    var s: u16 = 0;
                    while (s < frame.func.slot_count) : (s += 1) self.stack.items[base + s].release(self.allocator);
                    const fbase = frame.frame_base;
                    // OP_CALL_VALUE 帧：frame_base 下方是 callee 值，须 release。
                    if (fbase < base) {
                        var i = fbase;
                        while (i < base) : (i += 1) self.stack.items[i].release(self.allocator);
                    }
                    self.stack.shrinkRetainingCapacity(fbase); // 弹掉本帧 [callee?, 局部槽]
                    _ = self.frames.pop();
                    if (self.frames.items.len == 0) {
                        return result; // 入口帧返回：结果交给调用方
                    }
                    try self.push(result); // 返回值压回调用者栈（所有权移交）
                },
            }
        }
    }

    /// 执行一次 OP_CALL（M1a 快路径）：argc 个实参已在栈顶，callee 不在栈上。
    /// argc==arity 建帧；argc<arity 产生部分应用的 vm_closure（默认柯里化）；argc>arity → WrongArity。
    fn doCall(self: *VM, program: *const Program, func_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee = &program.functions.items[func_idx];
        if (argc < callee.arity) {
            // 不足参：收集栈顶 argc 个实参为 bound_args，建部分应用 vm_closure 压栈。
            const bound = try self.allocator.alloc(Value, argc);
            const args_start = self.stack.items.len - argc;
            var i: usize = 0;
            while (i < argc) : (i += 1) bound[i] = self.stack.items[args_start + i]; // 接管 owned
            self.stack.shrinkRetainingCapacity(args_start);
            const vc = try self.allocator.create(value.VmClosure);
            vc.* = .{ .func = callee, .arity = callee.arity, .upvalues = &.{}, .bound_args = bound, .rc = 1, .allocator = self.allocator };
            try self.push(Value{ .vm_closure = vc });
            return;
        }
        if (argc > callee.arity) return self.fail(loc, "wrong number of arguments", error.WrongArity);
        if (self.frames.items.len >= MAX_FRAMES) return self.fail(loc, "stack overflow: call depth exceeded", error.StackOverflow);
        // 实参当前位于栈顶 argc 个槽，正好作为 callee 的 slot 0..arity-1（slot_base 指向它们）。
        const slot_base = self.stack.items.len - argc;
        var s: u16 = callee.arity;
        while (s < callee.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = callee, .ip = 0, .slot_base = slot_base, .frame_base = slot_base });
    }

    /// 执行 OP_TAIL_CALL：复用当前帧调用顶层 program.functions[func_idx]，不压新帧。
    /// 编译器保证仅在尾位置且 argc==callee.arity 时发射，故无柯里化/超参分支。
    /// 栈布局（调用前）：[..本帧 frame_base..局部槽.., arg0..arg_{argc-1}]，args 在栈顶。
    /// 步骤：暂存 args → 释放本帧局部槽(+callee box，若 frame_base<slot_base) → shrink 到 frame_base
    ///       → 写回 args 到 frame_base → 补 unit 到 slot_count → 就地改写帧(func,ip=0,slot_base=
    ///       frame_base,upvalues 清空)。
    fn doTailCall(self: *VM, program: *const Program, func_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee = &program.functions.items[func_idx];
        if (argc != callee.arity) return self.fail(loc, "wrong number of arguments", error.WrongArity);
        const frame = &self.frames.items[self.frames.items.len - 1];
        const fbase = frame.frame_base;
        const sbase = frame.slot_base;
        // 1) 暂存栈顶 argc 个实参（owned）到定长缓冲（argc ≤ 255）。
        var argbuf: [256]Value = undefined;
        const args_start = self.stack.items.len - argc;
        var i: usize = 0;
        while (i < argc) : (i += 1) argbuf[i] = self.stack.items[args_start + i];
        // 2) 释放本帧局部槽（slot_base..slot_base+slot_count）。args 在其上方，不在此列。
        var s: u16 = 0;
        while (s < frame.func.slot_count) : (s += 1) self.stack.items[sbase + s].release(self.allocator);
        // 3) OP_CALL_VALUE 帧：frame_base..slot_base 之间是 callee box，须 release。
        if (fbase < sbase) {
            var k = fbase;
            while (k < sbase) : (k += 1) self.stack.items[k].release(self.allocator);
        }
        // 4) 回退栈到 frame_base，写回 args（接管 owned），补 unit 到 slot_count。
        self.stack.shrinkRetainingCapacity(fbase);
        i = 0;
        while (i < argc) : (i += 1) try self.push(argbuf[i]);
        var p: u16 = callee.arity;
        while (p < callee.slot_count) : (p += 1) try self.push(Value.unit);
        // 5) 就地改写当前帧为 callee（slot_base==frame_base==fbase；callee 为顶层函数，无 upvalue）。
        frame.func = callee;
        frame.ip = 0;
        frame.slot_base = fbase;
        frame.frame_base = fbase;
        frame.upvalues = &.{};
    }

    /// 执行 OP_CALL_NATIVE：弹 argc 个实参，按 native_id 分派内建，压返回值（多数为 unit）。
    /// println/print 用 Value.format（与 eval 同一格式化路径）写 stdout。
    fn doCallNative(self: *VM, nat: opcode.Native, argc: u8, loc: ast.SourceLocation) VMError!void {
        switch (nat) {
            .println, .print => {
                if (argc != 1) return self.fail(loc, "println/print expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.release(self.allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                v.format(&buf, self.allocator, false) catch return error.OutOfMemory;
                if (nat == .println) buf.append(self.allocator, '\n') catch {};
                if (self.io) |io| {
                    var out_buf: [4096]u8 = undefined;
                    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
                    w.interface.print("{s}", .{buf.items}) catch {};
                    w.flush() catch {};
                } else {
                    std.debug.print("{s}", .{buf.items});
                }
                try self.push(Value.unit);
            },
        }
    }

    /// 执行 OP_MAKE_ADT：弹栈顶 argc 个字段值（owned，接管），按 program.adt_ctors[ctor_idx]
    /// 建 AdtValue（fields[i].name 取 desc.field_names[i]，type_name/constructor 借用 desc），压栈。
    fn doMakeAdt(self: *VM, program: *const Program, ctor_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const desc = program.adt_ctors.items[ctor_idx];
        if (desc.arity != argc) return self.fail(loc, "ADT constructor arity mismatch", error.WrongArity);
        const fields = self.allocator.alloc(value.AdtField, argc) catch return error.OutOfMemory;
        // 栈顶 argc 个值依次对应 field[0..argc]（先压的是 field0）。接管 owned。
        const base = self.stack.items.len - argc;
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            fields[i] = .{ .name = desc.field_names[i], .value = self.stack.items[base + i] };
        }
        self.stack.shrinkRetainingCapacity(base);
        const av = self.allocator.create(value.AdtValue) catch return error.OutOfMemory;
        av.* = .{ .type_name = desc.type_name, .constructor = desc.ctor_name, .fields = fields, .rc = 1 };
        try self.push(Value{ .adt = av });
    }

    /// 执行 OP_GET_FIELD：弹对象，按名读 adt/record 字段，retainOwned 压栈，release 对象。
    fn doGetField(self: *VM, field: []const u8, loc: ast.SourceLocation) VMError!void {
        const obj = self.pop();
        defer obj.release(self.allocator);
        switch (obj) {
            .adt => |av| {
                for (av.fields) |f| {
                    if (f.name) |n| {
                        if (std.mem.eql(u8, n, field)) {
                            try self.push(try self.retainOwned(f.value));
                            return;
                        }
                    }
                }
                return self.fail(loc, "no such field on adt", error.TypeMismatch);
            },
            .record => |rec| {
                if (rec.fields.get(field)) |v| {
                    try self.push(try self.retainOwned(v));
                    return;
                }
                return self.fail(loc, "no such field on record", error.TypeMismatch);
            },
            else => return self.fail(loc, "field access on non-record/adt", error.TypeMismatch),
        }
    }

    /// 执行 OP_MAKE_RECORD：弹栈顶 n 个值（n=shape.field_names.len），建 RecordValue（key dupe，
    /// value 接管 owned）压栈。匿名记录 type_name=""（与树遍历器 evalRecordLiteral 一致）。
    fn doMakeRecord(self: *VM, program: *const Program, shape_idx: u16) VMError!void {
        const shape = program.record_shapes.items[shape_idx];
        const n = shape.field_names.len;
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.*.release(self.allocator);
            }
            map.deinit();
        }
        const base = self.stack.items.len - n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = self.allocator.dupe(u8, shape.field_names[i]) catch return error.OutOfMemory;
            // put 可能覆盖同名 key（重复字段）：释放旧值 + 复用旧 key，避免泄漏。
            const gop = map.getOrPut(key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.*.release(self.allocator);
            }
            gop.value_ptr.* = self.stack.items[base + i];
        }
        self.stack.shrinkRetainingCapacity(base);
        const rec = value.Value.makeRecord(self.allocator, "", map) catch return error.OutOfMemory;
        try self.push(rec);
    }

    /// 执行 OP_RECORD_EXTEND：栈布局 [base, u0..u_{n-1}]（base 在 n 个 update 值之下）。
    /// 浅拷 base 字段（dupe key + retain value）+ updates 覆盖/新增，建新 RecordValue 压栈。
    fn doRecordExtend(self: *VM, program: *const Program, shape_idx: u16, loc: ast.SourceLocation) VMError!void {
        const shape = program.record_shapes.items[shape_idx];
        const n = shape.field_names.len;
        const ubase = self.stack.items.len - n;
        const base_val = self.stack.items[ubase - 1];
        if (base_val != .record) return self.fail(loc, "record extend base must be a record", error.TypeMismatch);

        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.*.release(self.allocator);
            }
            map.deinit();
        }
        // 浅拷 base 字段（retain value，dupe key）。
        var bit = base_val.record.fields.iterator();
        while (bit.next()) |e| {
            const key = self.allocator.dupe(u8, e.key_ptr.*) catch return error.OutOfMemory;
            map.put(key, try self.retainOwned(e.value_ptr.*)) catch return error.OutOfMemory;
        }
        // updates 覆盖/新增（接管栈上 owned 值）。
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = self.allocator.dupe(u8, shape.field_names[i]) catch return error.OutOfMemory;
            const gop = map.getOrPut(key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.*.release(self.allocator); // 释放被覆盖的 base 字段拷贝
            }
            gop.value_ptr.* = self.stack.items[ubase + i];
        }
        // 弹 n 个 update + base（base 用完 release）。
        self.stack.shrinkRetainingCapacity(ubase - 1);
        base_val.release(self.allocator);
        const rec = value.Value.makeRecord(self.allocator, "", map) catch return error.OutOfMemory;
        try self.push(rec);
    }

    /// 执行 OP_INDEX：array 整数索引（边界检查）、string codepoint 索引，retainOwned 元素压栈。
    fn doIndex(self: *VM, object: Value, index_val: Value, loc: ast.SourceLocation) VMError!void {
        switch (object) {
            .array => |arr| {
                if (index_val != .integer) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
                const iv = index_val.integer;
                const i: i128 = if (iv.type_tag.isSigned()) iv.signedValue() else @intCast(iv.value);
                if (i < 0 or i >= @as(i128, @intCast(arr.elements.len)))
                    return self.fail(loc, "index out of bounds", error.TypeMismatch);
                try self.push(try self.retainOwned(arr.elements[@intCast(i)]));
            },
            .string => |s| {
                if (index_val != .integer) return self.fail(loc, "string index must be an integer", error.TypeMismatch);
                const iv = index_val.integer;
                const i: i128 = if (iv.type_tag.isSigned()) iv.signedValue() else @intCast(iv.value);
                if (i < 0) return self.fail(loc, "index out of bounds", error.TypeMismatch);
                const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
                var iter = view.iterator();
                var ci: i128 = 0;
                while (iter.nextCodepoint()) |cp| : (ci += 1) {
                    if (ci == i) {
                        try self.push(Value{ .char_val = @intCast(cp) });
                        return;
                    }
                }
                return self.fail(loc, "index out of bounds", error.TypeMismatch);
            },
            else => return self.fail(loc, "cannot index into this type", error.TypeMismatch),
        }
    }

    /// 执行一次 OP_CALL_VALUE（M1b）：栈布局 [callee, arg0..]，callee 在 args 下方。默认柯里化：
    /// total == arity → 建帧调用；< → 产生 bound_args 更长的新 vm_closure；> → WrongArity。
    fn doCallValue(self: *VM, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee_idx = self.stack.items.len - argc - 1;
        const callee = self.stack.items[callee_idx];
        if (callee != .vm_closure) return self.fail(loc, "value is not callable", error.TypeMismatch);
        const vc = callee.vm_closure;
        const total = vc.bound_args.len + argc;
        if (total == vc.arity) {
            try self.enterClosure(vc, callee_idx, argc, loc);
        } else if (total < vc.arity) {
            try self.makeBoundClosure(vc, callee_idx, argc);
        } else {
            return self.fail(loc, "wrong number of arguments", error.WrongArity);
        }
    }

    /// 足参调用：建 callee 帧。栈上 [callee, new_arg0..]；若 callee 有 bound_args，
    /// 须把 bound_args 插到 new_args 前面，组成完整的 arity 个 slot。
    /// 为统一栈布局，重排：把 callee 槽之上重建为 [bound..., new...]（共 arity 个），slot_base 指向首个。
    fn enterClosure(self: *VM, vc: *value.VmClosure, callee_idx: usize, argc: u8, loc: ast.SourceLocation) VMError!void {
        if (self.frames.items.len >= MAX_FRAMES) return self.fail(loc, "stack overflow: call depth exceeded", error.StackOverflow);
        const func: *const Function = @ptrCast(@alignCast(vc.func));
        const nbound = vc.bound_args.len;
        if (nbound > 0) {
            // 在 callee 槽与 new_args 之间插入 bound_args（各 retainOwned 一份独立 owned）。
            // 当前栈：[callee, new0..new_{argc-1}]。目标：[callee, bound0..,new0..]。
            // 先把 new_args 整体后移 nbound 格，再填 bound。
            var k: usize = 0;
            while (k < nbound) : (k += 1) try self.push(Value.unit); // 扩容 nbound 格
            const args_start = callee_idx + 1;
            // new_args 原占 [args_start, args_start+argc)，后移到 [args_start+nbound, ...)
            var i: usize = argc;
            while (i > 0) {
                i -= 1;
                self.stack.items[args_start + nbound + i] = self.stack.items[args_start + i];
            }
            // 填入 bound_args（retainOwned，因 vc 仍持有母本，调用结束帧 release 各 slot）
            for (vc.bound_args, 0..) |ba, j| {
                self.stack.items[args_start + j] = try self.retainOwned(ba);
            }
        }
        const slot_base = callee_idx + 1;
        var s: u16 = vc.arity;
        while (s < func.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = func, .ip = 0, .slot_base = slot_base, .frame_base = callee_idx, .upvalues = vc.upvalues });
    }

    /// 不足参：产生 bound_args 更长的新 vm_closure，替换栈上 [callee, args..] 为单个新闭包。
    fn makeBoundClosure(self: *VM, vc: *value.VmClosure, callee_idx: usize, argc: u8) VMError!void {
        const nbound = vc.bound_args.len;
        const new_bound = try self.allocator.alloc(Value, nbound + argc);
        // 复制旧 bound（retainOwned）+ 新实参（直接接管栈上 owned）。
        for (vc.bound_args, 0..) |ba, j| new_bound[j] = try self.retainOwned(ba);
        const args_start = callee_idx + 1;
        var i: usize = 0;
        while (i < argc) : (i += 1) new_bound[nbound + i] = self.stack.items[args_start + i];
        // 新闭包共享 func + upvalues（retainOwned upvalues）。M1b-1 upvalues 恒空。
        const new_uv: []Value = if (vc.upvalues.len > 0) try self.allocator.alloc(Value, vc.upvalues.len) else &.{};
        for (vc.upvalues, 0..) |uv, j| new_uv[j] = try self.retainOwned(uv);
        const nvc = try self.allocator.create(value.VmClosure);
        nvc.* = .{ .func = vc.func, .arity = vc.arity, .upvalues = new_uv, .bound_args = new_bound, .rc = 1, .allocator = self.allocator };
        // 弹掉 [callee, args..]（callee release，args 所有权已转入 new_bound 不 release），压入新闭包。
        self.stack.items[callee_idx].release(self.allocator);
        self.stack.shrinkRetainingCapacity(callee_idx);
        try self.push(Value{ .vm_closure = nvc });
    }

    /// 算术 + 位运算。语义镜像 eval.zig evalAdd/Sub/...（复用 value.zig promote/inRange）。
    fn arith(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        if (left == .integer and right == .integer) {
            const lt = left.integer.type_tag;
            const rt = right.integer.type_tag;
            switch (op) {
                .op_bit_and, .op_bit_or, .op_bit_xor => {
                    const result_type = lt; // 位运算保留 left 类型（与 evalBinary 一致）
                    const result: u128 = switch (op) {
                        .op_bit_and => left.integer.value & right.integer.value,
                        .op_bit_or => left.integer.value | right.integer.value,
                        .op_bit_xor => left.integer.value ^ right.integer.value,
                        else => unreachable,
                    };
                    if (!result_type.inRange(result)) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
                    return Value{ .integer = .{ .value = result, .type_tag = result_type } };
                },
                else => {},
            }
            const result_type = value.promoteIntTypes(lt, rt);
            const signed = result_type.isSigned();
            const lv: i128 = @bitCast(left.integer.value);
            const rv: i128 = @bitCast(right.integer.value);
            const result: u128 = switch (op) {
                .op_add => if (signed) @bitCast(lv +% rv) else left.integer.value +% right.integer.value,
                .op_sub => if (signed) @bitCast(lv -% rv) else left.integer.value -% right.integer.value,
                .op_mul => if (signed) @bitCast(lv *% rv) else left.integer.value *% right.integer.value,
                .op_div => blk: {
                    if (right.integer.value == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk if (signed) @bitCast(@divTrunc(lv, rv)) else left.integer.value / right.integer.value;
                },
                .op_mod => blk: {
                    if (right.integer.value == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk if (signed) @bitCast(@rem(lv, rv)) else left.integer.value % right.integer.value;
                },
                else => unreachable,
            };
            if (!result_type.inRange(result)) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
            return Value{ .integer = .{ .value = result, .type_tag = result_type } };
        }
        return self.arithFloat(op, left, right, loc);
    }

    /// 浮点参与的算术（int↔float 混合按 evalBinary 提升为 float）。
    fn arithFloat(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        if ((left == .float or left == .integer) and (right == .float or right == .integer)) {
            const lf: f128 = if (left == .float) left.float.value else intToFloat(left.integer);
            const rf: f128 = if (right == .float) right.float.value else intToFloat(right.integer);
            const tag: value.FloatType = if (left == .float and right == .float)
                value.promoteFloatTypes(left.float.type_tag, right.float.type_tag)
            else if (left == .float) left.float.type_tag else right.float.type_tag;
            const result: f128 = switch (op) {
                .op_add => lf + rf,
                .op_sub => lf - rf,
                .op_mul => lf * rf,
                .op_div => lf / rf,
                .op_mod => @rem(lf, rf),
                else => return self.fail(loc, "bitwise op requires integer operands", error.TypeMismatch),
            };
            if (std.math.isNan(result) or std.math.isInf(result)) return self.fail(loc, "arithmetic overflow: floating-point operation out of range", error.ArithmeticOverflow);
            return Value{ .float = .{ .value = result, .type_tag = tag } };
        }
        return self.fail(loc, "arithmetic requires numeric operands", error.TypeMismatch);
    }

    fn intToFloat(iv: IntValue) f128 {
        return if (iv.type_tag.isSigned()) @floatFromInt(@as(i128, @bitCast(iv.value))) else @floatFromInt(iv.value);
    }

    /// 比较：== != < > <= >=。返回 bool。
    fn compare(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        if (op == .op_eq) return Value{ .boolean = left.equals(right) };
        if (op == .op_neq) return Value{ .boolean = !left.equals(right) };
        if (left == .integer and right == .integer) {
            const result_type = value.promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            const lv: i128 = if (result_type.isSigned()) @bitCast(left.integer.value) else @intCast(left.integer.value);
            const rv: i128 = if (result_type.isSigned()) @bitCast(right.integer.value) else @intCast(right.integer.value);
            return Value{ .boolean = ordCmp(op, lv, rv) };
        }
        if ((left == .float or left == .integer) and (right == .float or right == .integer)) {
            const lf: f128 = if (left == .float) left.float.value else intToFloat(left.integer);
            const rf: f128 = if (right == .float) right.float.value else intToFloat(right.integer);
            return Value{ .boolean = ordCmp(op, lf, rf) };
        }
        return self.fail(loc, "comparison requires numeric operands", error.TypeMismatch);
    }

    fn ordCmp(op: OpCode, l: anytype, r: anytype) bool {
        return switch (op) {
            .op_lt => l < r,
            .op_gt => l > r,
            .op_le => l <= r,
            .op_ge => l >= r,
            else => unreachable,
        };
    }

    fn negate(self: *VM, v: Value, loc: ast.SourceLocation) VMError!Value {
        if (v == .integer) {
            const t = v.integer.type_tag;
            const neg: i128 = -@as(i128, @bitCast(v.integer.value));
            const result: u128 = @bitCast(neg);
            if (!t.inRange(result)) return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
            return Value{ .integer = .{ .value = result, .type_tag = t } };
        }
        if (v == .float) return Value{ .float = .{ .value = -v.float.value, .type_tag = v.float.type_tag } };
        return self.fail(loc, "'-' requires numeric operand", error.TypeMismatch);
    }
};

test "vm arithmetic: (2 + 3) * 4 = 20" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const k2 = try chunk.addConstant(Value{ .integer = .{ .value = 2, .type_tag = .i32 } });
    const k3 = try chunk.addConstant(Value{ .integer = .{ .value = 3, .type_tag = .i32 } });
    const k4 = try chunk.addConstant(Value{ .integer = .{ .value = 4, .type_tag = .i32 } });
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k2);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k3);
    try chunk.writeOp(.op_add, loc);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k4);
    try chunk.writeOp(.op_mul, loc);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 0);
    defer result.release(allocator);
    try std.testing.expectEqual(@as(u128, 20), result.integer.value);
}

test "vm local variable: slot store + load" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    // 局部槽 0 = 10；读 slot0 + 5 = 15
    const k10 = try chunk.addConstant(Value{ .integer = .{ .value = 10, .type_tag = .i32 } });
    const k5 = try chunk.addConstant(Value{ .integer = .{ .value = 5, .type_tag = .i32 } });
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k10);
    try chunk.writeOp(.op_set_local, loc);
    try chunk.writeU16(0);
    try chunk.writeOp(.op_get_local, loc);
    try chunk.writeU16(0);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k5);
    try chunk.writeOp(.op_add, loc);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 1); // 1 个局部槽
    defer result.release(allocator);
    try std.testing.expectEqual(@as(u128, 15), result.integer.value);
}

test "vm jump: if false skips" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    // push false; jump_if_false -> L; push 99 (skipped); L: pop cond; push 7; return
    const k99 = try chunk.addConstant(Value{ .integer = .{ .value = 99, .type_tag = .i32 } });
    const k7 = try chunk.addConstant(Value{ .integer = .{ .value = 7, .type_tag = .i32 } });
    try chunk.writeOp(.op_false, loc);
    const j = try chunk.emitJump(.op_jump_if_false, loc);
    try chunk.writeOp(.op_const, loc); // 被跳过
    try chunk.writeU16(k99);
    chunk.patchJump(j);
    try chunk.writeOp(.op_pop, loc); // 弹 cond(false)
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k7);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 0);
    defer result.release(allocator);
    try std.testing.expectEqual(@as(u128, 7), result.integer.value);
}

/// 测试 helper：把一个裸 chunk 包成单函数 Program（arity=0, slot_count=N）并执行。
/// 接管 chunk 所有权（放入 Program，由 Program.deinit 释放）。
fn runChunkForTest(vm: *VM, allocator: std.mem.Allocator, chunk: Chunk, slot_count: u16) VMError!Value {
    var program = Program.init(allocator);
    defer program.deinit();
    _ = try program.addFunction(.{ .chunk = chunk, .arity = 0, .slot_count = slot_count });
    return vm.call(&program, 0, &.{});
}