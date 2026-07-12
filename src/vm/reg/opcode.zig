//! 寄存器 VM 指令集定义。
//!
//! 定义 32 位指令的编码/解码格式（iABC / iABx / iAsBx）、
//! 全部操作码枚举以及 RK 操作数（寄存器或常量）的编解码。
//! 同时提供跳转指令回填工具与单元测试。

const std = @import("std");

/// RK 模式下标记常量的最高位标志。
pub const RK_CONST_FLAG: u8 = 0x80;

/// 将寄存器号编码为 RK 操作数（直接保留低 7 位）。
pub inline fn reg(r: u8) u8 {
    std.debug.assert(r < RK_CONST_FLAG);
    return r;
}

/// 将常量索引编码为 RK 操作数（设置最高位标志）。
pub inline fn constk(k_idx: u8) u8 {
    std.debug.assert(k_idx < RK_CONST_FLAG);
    return k_idx | RK_CONST_FLAG;
}

/// RK 操作数解析结果：寄存器或常量索引。
pub const RKOperand = union(enum) {
    reg: u8,
    const_idx: u8,
};

/// 解码 RK 操作数，依据最高位判断是寄存器还是常量。
pub inline fn decodeRK(rk: u8) RKOperand {
    if (rk & RK_CONST_FLAG != 0) {
        return .{ .const_idx = rk & ~RK_CONST_FLAG };
    }
    return .{ .reg = rk };
}

/// 全部操作码枚举，按功能分组排列。
pub const Op = enum(u8) {
    load_const,
    load_null,
    load_unit,
    load_true,
    load_false,
    load_global,
    store_global,
    move,
    move_raw,
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    not_op,
    bit_and,
    bit_or,
    bit_xor,
    jump,
    jump_if_false,
    jump_if_true,
    jump_if_null,
    jump_if_not_null,
    call,
    call_value,
    call_native,
    call_method,
    call_method_ic,
    tail_call,
    call_memoized,
    return_op,
    return_unit,
    closure,
    get_upvalue,
    set_upvalue,
    get_upvalue_raw,
    make_adt,
    make_array,
    make_record,
    make_newtype,
    make_range,
    make_range_incl,
    make_atomic,
    make_lazy,
    make_error,
    make_trait,
    get_field,
    set_field,
    get_adt_field,
    index_op,
    set_index,
    record_extend,
    concat_list,
    test_ctor,
    test_lit,
    test_newtype,
    test_throw,
    get_throw_ok,
    get_throw_err,
    get_newtype_inner,
    match_fail,
    interp,
    cast,
    coerce,
    non_null,
    propagate,
    throw_op,
    for_next,
    compound_local,
    spawn,
    try_recv,
    recv,
    push_inplace,
    bind,
    assign,
    bind_letrec,
    release,
};

/// 32 位指令类型。
pub const Instruction = u32;

/// 编码 iABC 格式指令：操作码 + 三字节操作数。
pub inline fn makeABC(op: Op, a: u8, b: u8, c: u8) Instruction {
    return (@as(u32, @intFromEnum(op)) << 24) |
        (@as(u32, a) << 16) |
        (@as(u32, b) << 8) |
        @as(u32, c);
}

/// 编码 iABx 格式指令：操作码 + 单字节 A + 双字节 Bx。
pub inline fn makeABx(op: Op, a: u8, bx: u16) Instruction {
    return (@as(u32, @intFromEnum(op)) << 24) |
        (@as(u32, a) << 16) |
        @as(u32, bx);
}

/// 从指令中提取操作码。
pub inline fn getOp(inst: Instruction) Op {
    return @enumFromInt(@as(u8, @intCast(inst >> 24)));
}

/// 返回 opcode 索引对应的名称字符串（供 profiler 使用）。
pub fn opName(op_idx: u8) []const u8 {
    return @tagName(@as(Op, @enumFromInt(op_idx)));
}

/// 从指令中提取操作数 A（高字节）。
pub inline fn getA(inst: Instruction) u8 {
    return @intCast((inst >> 16) & 0xFF);
}

/// 从指令中提取操作数 B（中字节）。
pub inline fn getB(inst: Instruction) u8 {
    return @intCast((inst >> 8) & 0xFF);
}

/// 从指令中提取操作数 C（低字节）。
pub inline fn getC(inst: Instruction) u8 {
    return @intCast(inst & 0xFF);
}

/// 从指令中提取无符号操作数 Bx（低 16 位）。
pub inline fn getBx(inst: Instruction) u16 {
    return @intCast(inst & 0xFFFF);
}

/// 从指令中提取有符号操作数 sBx（偏移 32768 的 Bx）。
pub inline fn getsBx(inst: Instruction) i32 {
    const bx = getBx(inst);
    return @as(i32, @intCast(bx)) - 32768;
}

/// 编码 iAsBx 格式指令：操作码 + A + 有符号偏移。
pub inline fn makesBx(op: Op, a: u8, offset: i32) Instruction {
    const bx: u16 = @intCast(@as(i32, offset) + 32768);
    return makeABx(op, a, bx);
}

/// 回填跳转指令的目标地址，将跳转偏移写入指定位置。
pub fn patchJump(code: []Instruction, jump_inst_idx: usize, target_idx: usize) void {
    const offset: i32 = @intCast(@as(i64, @intCast(target_idx)) - @as(i64, @intCast(jump_inst_idx + 1)));
    const inst = code[jump_inst_idx];
    const op = getOp(inst);
    const a = getA(inst);
    code[jump_inst_idx] = makesBx(op, a, offset);
}

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
        makesBx(.jump_if_false, 0, 0),
        makeABC(.load_null, 1, 0, 0),
        makeABC(.load_true, 2, 0, 0),
    };
    patchJump(&code, 0, 2);
    try std.testing.expectEqual(@as(i32, 1), getsBx(code[0]));
}
