//! 寄存器式 VM 指令集 —— Lua 5.1 风格 iABC 固定宽度编码。
//! 每条指令 4 字节：Op(8) + A(8) + B(8) + C(8) = 32bit
//! A/B/C 均为寄存器号（0-255）或常量索引（0-255，通过 RK 位区分）
//! 寄存器号 < 256 时直接编码；常量索引 < 256 时用 RK 模式（bit7=1 标记常量）
//! 跳转指令使用 iABx 变体：Op(8) + A(8) + Bx(16)，Bx 为有符号偏移

const std = @import("std");

/// RK 模式标记：B/C 操作数 bit7=1 表示常量索引，bit7=0 表示寄存器号
pub const RK_CONST_FLAG: u8 = 0x80;

/// 将寄存器号编码为 RK 操作数（直接使用，bit7=0）
pub inline fn reg(r: u8) u8 {
    std.debug.assert(r < RK_CONST_FLAG);
    return r;
}

/// 将常量索引编码为 RK 操作数（bit7=1 标记常量）
pub inline fn constk(k_idx: u8) u8 {
    std.debug.assert(k_idx < RK_CONST_FLAG);
    return k_idx | RK_CONST_FLAG;
}

/// 解码 RK 操作数：返回 .{ .reg = r } 或 .{ .const_idx = k }
pub const RKOperand = union(enum) {
    reg: u8,
    const_idx: u8,
};

pub inline fn decodeRK(rk: u8) RKOperand {
    if (rk & RK_CONST_FLAG != 0) {
        return .{ .const_idx = rk & ~RK_CONST_FLAG };
    }
    return .{ .reg = rk };
}

/// 寄存器式 opcode 枚举。每个 opcode 标注其操作数格式。
pub const Op = enum(u8) {
    // ── 加载/常量（A = 目标寄存器）──
    /// LOAD_CONST A Bx — R[A] = Constants[Bx]
    load_const,
    /// LOAD_NULL A — R[A] = null
    load_null,
    /// LOAD_UNIT A — R[A] = unit
    load_unit,
    /// LOAD_TRUE A — R[A] = true
    load_true,
    /// LOAD_FALSE A — R[A] = false
    load_false,
    /// LOAD_GLOBAL A Bx — R[A] = Globals[Bx]
    load_global,
    /// STORE_GLOBAL A Bx — Globals[Bx] = R[A]
    store_global,

    // ── 寄存器间移动 ──
    /// MOVE A B — R[A] = R[B]（retain）
    move,
    /// MOVE_RAW A B — R[A] = R[B]（不 retain，用于 atomic 透明读）
    move_raw,

    // ── 算术（A=dst, B/C=源，RK 模式支持常量操作数）──
    /// ADD A B C — R[A] = R[B] + R[C]
    add,
    /// SUB A B C — R[A] = R[B] - R[C]
    sub,
    /// MUL A B C — R[A] = R[B] * R[C]
    mul,
    /// DIV A B C — R[A] = R[B] / R[C]
    div,
    /// MOD A B C — R[A] = R[B] % R[C]
    mod,
    /// NEG A B — R[A] = -R[B]
    neg,

    // ── 比较（A=dst, B/C=源，结果为 bool）──
    /// EQ A B C — R[A] = (R[B] == R[C])
    eq,
    /// NEQ A B C — R[A] = (R[B] != R[C])
    neq,
    /// LT A B C — R[A] = (R[B] < R[C])
    lt,
    /// GT A B C — R[A] = (R[B] > R[C])
    gt,
    /// LE A B C — R[A] = (R[B] <= R[C])
    le,
    /// GE A B C — R[A] = (R[B] >= R[C])
    ge,
    /// NOT A B — R[A] = !R[B]
    not_op,

    // ── 位运算 ──
    /// BIT_AND A B C
    bit_and,
    /// BIT_OR A B C
    bit_or,
    /// BIT_XOR A B C
    bit_xor,

    // ── 跳转（iABx 变体，Bx=有符号偏移）──
    /// JUMP Bx — ip += Bx
    jump,
    /// JUMP_IF_FALSE A Bx — if (!R[A]) ip += Bx
    jump_if_false,
    /// JUMP_IF_TRUE A Bx — if (R[A]) ip += Bx
    jump_if_true,
    /// JUMP_IF_NULL A Bx — if (R[A] == null) ip += Bx
    jump_if_null,
    /// JUMP_IF_NOT_NULL A Bx — if (R[A] != null) ip += Bx
    jump_if_not_null,

    // ── 调用/返回 ──
    /// CALL A Bx C — R[A] = call(func_idx=Bx, argc=C)，args 在 R[A+1..A+C]
    call,
    /// CALL_VALUE A B C — R[A] = call(callee=R[A], argc=C)，args 在 R[A+1..A+C]
    call_value,
    /// CALL_NATIVE A Bx C — R[A] = native_call(native_id=Bx, argc=C)，args 在 R[A+1..A+C]
    call_native,
    /// CALL_METHOD A Bx C — R[A] = method_call(name_idx=Bx, receiver=R[A], argc=C)，args 在 R[A+1..A+C]
    call_method,
    /// CALL_METHOD_IC A Bx C — 带 Inline Cache 的方法调用，A=ic_slot, Bx=name_idx(16bit), C=argc
    call_method_ic,
    /// TAIL_CALL A Bx C — 尾调用（复用帧）
    tail_call,
    /// CALL_MEMOIZED A B C — A=func_idx, B=memo_slot, C=argc
    call_memoized,
    /// RETURN A — return R[A]
    return_op,
    /// RETURN_UNIT — return unit（无返回值）
    return_unit,

    // ── 闭包/upvalue ──
    /// CLOSURE A Bx — R[A] = makeClosure(func_idx=Bx)，后续每条指令编码一个 upvalue 描述符
    closure,
    /// GET_UPVALUE A B — R[A] = Upvalues[B]
    get_upvalue,
    /// SET_UPVALUE A B — Upvalues[B] = R[A]
    set_upvalue,
    /// GET_UPVALUE_RAW A B — R[A] = Upvalues[B]（不透明 load atomic）
    get_upvalue_raw,

    // ── 复合值构造 ──
    /// MAKE_ADT A Bx C — R[A] = makeAdt(ctor_idx=Bx, argc=C)，fields 在 R[A+1..A+C]
    make_adt,
    /// MAKE_ARRAY A B C — R[A] = makeArray(len=B)，elements 在 R[A+1..A+B]
    make_array,
    /// MAKE_RECORD A Bx C — R[A] = makeRecord(shape_idx=Bx, field_count=C)，values 在 R[A+1..A+C]
    make_record,
    /// MAKE_NEWTYPE A B — R[A] = makeNewtype(R[B])
    make_newtype,
    /// MAKE_RANGE A B C — R[A] = makeRange(R[B], R[C], inclusive=A&1)
    make_range,
    /// MAKE_ATOMIC A B — R[A] = makeAtomic(R[B])
    make_atomic,
    /// MAKE_LAZY A B — R[A] = makeLazy(closure=R[B])
    make_lazy,
    /// MAKE_ERROR A Bx C — R[A] = makeError(Bx, R[C])
    make_error,
    /// MAKE_TRAIT A B C — R[A] = makeTrait(count=B)，methods 在 R[A+1..A+B*2]
    make_trait,

    // ── 字段/索引访问 ──
    /// GET_FIELD A B C — R[A] = getField(R[B], name_idx=C)
    get_field,
    /// SET_FIELD A B C — R[A] = setField(R[A], name_idx=B, value=R[C]) → COW
    set_field,
    /// GET_ADT_FIELD A Bx — R[A] = AdtValue.fields[Bx]
    get_adt_field,
    /// INDEX A B C — R[A] = R[B][R[C]]
    index_op,
    /// SET_INDEX A B C — R[A] = setIndex(R[A], R[B], R[C]) → COW
    set_index,
    /// RECORD_EXTEND A Bx C — R[A] = recordExtend(R[A], shape_idx=Bx, updates=R[A+1..A+C])
    record_extend,
    /// CONCAT_LIST A B C — R[A] = R[B] ++ R[C]
    concat_list,

    // ── 模式匹配测试 ──
    /// TEST_CTOR A Bx — if (R[A].ctor == Bx) { R[A] = true } else { R[A] = false }
    test_ctor,
    /// TEST_LIT A B C — R[A] = (R[B] == Constants[C])
    test_lit,
    /// TEST_NEWTYPE A Bx — R[A] = (R[A].newtype_name == Bx)
    test_newtype,
    /// TEST_THROW A B — R[A] = (R[A].is_ok == B)
    test_throw,
    /// GET_THROW_OK A B — R[A] = R[B].ok_value
    get_throw_ok,
    /// GET_THROW_ERR A B — R[A] = R[B].err_value
    get_throw_err,
    /// GET_NEWTYPE_INNER A B — R[A] = R[B].inner
    get_newtype_inner,
    /// MATCH_FAIL — panic（无匹配 arm）
    match_fail,

    // ── 字符串/转换 ──
    /// INTERP A B C — R[A] = interpolate(parts=R[A+1..A+B], count=C)
    interp,
    /// CAST A B C — R[A] = cast(R[B], type_name_idx=C)
    cast,
    /// COERCE A B C — R[A] = coerce(R[B], type_name_idx=C)
    coerce,

    // ── 异常/传播 ──
    /// NON_NULL A — if (R[A] == null) panic
    non_null,
    /// PROPAGATE A — if (R[A] is null/err) return R[A]; else R[A] = R[A].ok
    propagate,
    /// THROW A — return R[A] as throw value
    throw_op,

    // ── 循环 ──
    /// FOR_NEXT A B C — A=elem_reg, B=iter_reg, C=idx_reg；耗尽跳过下一条 JUMP
    for_next,

    // ── atomic 复合赋值 ──
    /// COMPOUND_LOCAL A B C — R[A] = R[A] op R[C]，op=B（arith op code）
    compound_local,

    // ── spawn/并发 ──
    /// SPAWN A B C — R[A] = spawn(closure=R[B], argc=C)，args 在 R[B+1..B+C]
    spawn,
    /// TRY_RECV A B — R[A] = tryRecv(R[B])；R[A+1] = bool
    try_recv,
    /// RECV A B — R[A] = recv(R[B])
    recv,

    // ── push 就地优化 ──
    /// PUSH_INPLACE A B C — R[A] = R[A].push(R[C])，rc==1 原地扩容
    push_inplace,

    // ── set_local（绑定语义，寄存器式中用于声明/赋值局部变量）──
    /// BIND A B — R[A] = R[B]（绑定语义：不写穿 cell，release 旧值）
    bind,
    /// ASSIGN A B — R[A] = R[B]（赋值语义：atomic 透明 store）
    assign,
    /// BIND_LETREC A B — R[A] = R[B]（letrec 自绑定，断 cell↔closure 循环）
    bind_letrec,

    // ── POP（清理临时寄存器，release 引用）──
    /// RELEASE A — release(R[A])，用于显式释放临时值
    release,
};

// ── 32bit 指令编码/解码 ──

/// 32bit 指令编码：Op(8) + A(8) + B(8) + C(8)
pub const Instruction = u32;

pub inline fn makeABC(op: Op, a: u8, b: u8, c: u8) Instruction {
    return (@as(u32, @intFromEnum(op)) << 24) |
           (@as(u32, a) << 16) |
           (@as(u32, b) << 8) |
           @as(u32, c);
}

pub inline fn makeABx(op: Op, a: u8, bx: u16) Instruction {
    return (@as(u32, @intFromEnum(op)) << 24) |
           (@as(u32, a) << 16) |
           @as(u32, bx);
}

pub inline fn getOp(inst: Instruction) Op {
    return @enumFromInt(@as(u8, @intCast(inst >> 24)));
}

pub inline fn getA(inst: Instruction) u8 {
    return @intCast((inst >> 16) & 0xFF);
}

pub inline fn getB(inst: Instruction) u8 {
    return @intCast((inst >> 8) & 0xFF);
}

pub inline fn getC(inst: Instruction) u8 {
    return @intCast(inst & 0xFF);
}

pub inline fn getBx(inst: Instruction) u16 {
    return @intCast(inst & 0xFFFF);
}

/// 有符号 Bx（用于跳转偏移）：将 0..65535 映射到 -32768..32767
pub inline fn getsBx(inst: Instruction) i32 {
    const bx = getBx(inst);
    return @as(i32, @intCast(bx)) - 32768;
}

pub inline fn makesBx(op: Op, a: u8, offset: i32) Instruction {
    const bx: u16 = @intCast(@as(i32, offset) + 32768);
    return makeABx(op, a, bx);
}

// ── 跳转 patching（基于指令索引，非字节偏移）──
/// patchJump: 回填跳转指令的 Bx 偏移
/// target = 当前指令索引，jump_inst = 跳转指令索引
/// offset = target - (jump_inst + 1)
pub fn patchJump(code: []Instruction, jump_inst_idx: usize, target_idx: usize) void {
    const offset: i32 = @intCast(@as(i64, @intCast(target_idx)) - @as(i64, @intCast(jump_inst_idx + 1)));
    const inst = code[jump_inst_idx];
    const op = getOp(inst);
    const a = getA(inst);
    code[jump_inst_idx] = makesBx(op, a, offset);
}

// ── 单元测试 ──
test "iABC 编码/解码往返" {
    const inst = makeABC(.add, 10, 20, 30);
    try std.testing.expectEqual(Op.add, getOp(inst));
    try std.testing.expectEqual(@as(u8, 10), getA(inst));
    try std.testing.expectEqual(@as(u8, 20), getB(inst));
    try std.testing.expectEqual(@as(u8, 30), getC(inst));
}

test "iABx 编码/解码往返" {
    const inst = makeABx(.load_const, 5, 1000);
    try std.testing.expectEqual(Op.load_const, getOp(inst));
    try std.testing.expectEqual(@as(u8, 5), getA(inst));
    try std.testing.expectEqual(@as(u16, 1000), getBx(inst));
}

test "iAsBx 有符号偏移往返" {
    const inst = makesBx(.jump, 0, -100);
    try std.testing.expectEqual(Op.jump, getOp(inst));
    try std.testing.expectEqual(@as(i32, -100), getsBx(inst));

    const inst2 = makesBx(.jump_if_false, 3, 200);
    try std.testing.expectEqual(@as(i32, 200), getsBx(inst2));
}

test "RK 模式编码/解码" {
    try std.testing.expectEqual(@as(u8, 5), reg(5));
    try std.testing.expectEqual(@as(u8, 0x85), constk(5));

    try std.testing.expectEqual(RKOperand{ .reg = 5 }, decodeRK(reg(5)));
    try std.testing.expectEqual(RKOperand{ .const_idx = 5 }, decodeRK(constk(5)));
}

test "patchJump 回填偏移" {
    var code: [3]Instruction = .{
        makesBx(.jump_if_false, 0, 0), // idx 0: 占位跳转
        makeABC(.load_null, 1, 0, 0), // idx 1: 中间指令
        makeABC(.load_true, 2, 0, 0), // idx 2: 跳转目标
    };
    patchJump(&code, 0, 2);
    // offset = 2 - (0 + 1) = 1
    try std.testing.expectEqual(@as(i32, 1), getsBx(code[0]));
}
