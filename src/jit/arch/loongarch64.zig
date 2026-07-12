//! LoongArch64 (LA64) 代码生成器。
//!
//! 桥接模式：直接从字节码生成 LoongArch64 机器码。
//! 与 arm64.zig / x86_64.zig 的桥接模式功能完全对齐。
//!
//! LoongArch 指令为 32 位定长，小端序。
//! 使用 LP64D ABI（$a0-$a7 传参，$ra 返回地址，$s0-$s8/$fp callee-saved）。

const std = @import("std");
const builtin = @import("builtin");
const mem = @import("../mem.zig");
const ir = @import("../ir.zig");
const regalloc = @import("../regalloc.zig");
const value = @import("value");
const reg_vm_mod = @import("reg_vm");
const reg_chunk = reg_vm_mod.reg_chunk_mod;
const reg_opcode = reg_vm_mod.reg_opcode;
const runtime = @import("../runtime/mod.zig");
const backend_mod = @import("../backend.zig");
const RegVM = reg_vm_mod.reg_vm.RegVM;

/// LoongArch 通用寄存器编号。
pub const GPR = struct {
    pub const zero: u8 = 0; // $r0, 恒零
    pub const ra: u8 = 1; // $r1, 返回地址
    pub const tp: u8 = 2; // $r2, 线程指针
    pub const sp: u8 = 3; // $r3, 栈指针
    pub const a0: u8 = 4; // $r4, 参数/返回值
    pub const a1: u8 = 5; // $r5
    pub const a2: u8 = 6; // $r6
    pub const a3: u8 = 7; // $r7
    pub const a4: u8 = 8; // $r8
    pub const a5: u8 = 9; // $r9
    pub const a6: u8 = 10; // $r10
    pub const a7: u8 = 11; // $r11
    pub const t0: u8 = 12; // $r12, 临时
    pub const t1: u8 = 13; // $r13
    pub const t2: u8 = 14; // $r14
    pub const t3: u8 = 15; // $r15
    pub const t4: u8 = 16; // $r16
    pub const t5: u8 = 17; // $r17
    pub const t6: u8 = 18; // $r18
    pub const t7: u8 = 19; // $r19
    pub const t8: u8 = 20; // $r20
    // r21 保留
    pub const fp: u8 = 22; // $r22, 帧指针 / $s9
    pub const s0: u8 = 23; // $r23, callee-saved
    pub const s1: u8 = 24; // $r24
    pub const s2: u8 = 25; // $r25
    pub const s3: u8 = 26; // $r26
    pub const s4: u8 = 27; // $r27
    pub const s5: u8 = 28; // $r28
    pub const s6: u8 = 29; // $r29
    pub const s7: u8 = 30; // $r30
    pub const s8: u8 = 31; // $r31
};

/// LoongArch 浮点寄存器编号。
pub const FPR = struct {
    pub const f0: u8 = 0; // $fa0, 参数/返回值
    pub const f1: u8 = 1; // $fa1
    pub const f2: u8 = 2; // $fa2
    pub const f3: u8 = 3; // $fa3
    pub const f4: u8 = 4; // $fa4
    pub const f5: u8 = 5; // $fa5
    pub const f6: u8 = 6; // $fa6
    pub const f7: u8 = 7; // $fa7
    pub const ft0: u8 = 8; // $f8, 临时
    pub const ft1: u8 = 9; // $f9
    pub const ft2: u8 = 10; // $f10
    pub const ft3: u8 = 11; // $f11
    pub const ft4: u8 = 12; // $f12
    pub const ft5: u8 = 13; // $f13
    pub const ft6: u8 = 14; // $f14
    pub const ft7: u8 = 15; // $f15
    pub const ft8: u8 = 16; // $f16, 临时
    pub const ft9: u8 = 17; // $f17
    pub const ft10: u8 = 18; // $f18
    pub const ft11: u8 = 19; // $f19
    pub const ft12: u8 = 20; // $f20
    pub const ft13: u8 = 21; // $f21
    pub const ft14: u8 = 22; // $f22
    pub const ft15: u8 = 23; // $f23
    pub const fs0: u8 = 24; // $f24, callee-saved
    pub const fs1: u8 = 25; // $f25
    pub const fs2: u8 = 26; // $f26
    pub const fs3: u8 = 27; // $f27
    pub const fs4: u8 = 28; // $f28
    pub const fs5: u8 = 29; // $f29
    pub const fs6: u8 = 30; // $f30
    pub const fs7: u8 = 31; // $f31
};

/// 可用于分配的通用寄存器（IR 模式用，桥接模式不使用）。
/// 使用 t0-t8（r12-r20，caller-saved）和 s0-s8（r23-r31，callee-saved）。
/// 避开 r0（恒零）、r1（ra）、r2（tp）、r3（sp）、r4-r11（a0-a7 参数）、r21（保留）、r22（fp）。
const AVAIL_GPRS = [_]backend_mod.PhysReg{
    .{ .id = GPR.t0, .kind = .gpr },
    .{ .id = GPR.t1, .kind = .gpr },
    .{ .id = GPR.t2, .kind = .gpr },
    .{ .id = GPR.t3, .kind = .gpr },
    .{ .id = GPR.t4, .kind = .gpr },
    .{ .id = GPR.t5, .kind = .gpr },
    .{ .id = GPR.t6, .kind = .gpr },
    .{ .id = GPR.t7, .kind = .gpr },
    .{ .id = GPR.t8, .kind = .gpr },
    .{ .id = GPR.s0, .kind = .gpr },
    .{ .id = GPR.s1, .kind = .gpr },
    .{ .id = GPR.s2, .kind = .gpr },
    .{ .id = GPR.s3, .kind = .gpr },
    .{ .id = GPR.s4, .kind = .gpr },
    .{ .id = GPR.s5, .kind = .gpr },
    .{ .id = GPR.s6, .kind = .gpr },
    .{ .id = GPR.s7, .kind = .gpr },
    .{ .id = GPR.s8, .kind = .gpr },
};

/// 可用于分配的浮点寄存器（IR 模式用）。
/// 使用 ft0-ft7（f8-f15，caller-saved）和 ft8-ft15（f16-f23，caller-saved）。
/// 避开 fa0-fa7（f0-f7，参数/返回值）和 fs0-fs7（f24-f31，callee-saved）。
const AVAIL_FPRS = [_]backend_mod.PhysReg{
    .{ .id = FPR.ft0, .kind = .fpr },
    .{ .id = FPR.ft1, .kind = .fpr },
    .{ .id = FPR.ft2, .kind = .fpr },
    .{ .id = FPR.ft3, .kind = .fpr },
    .{ .id = FPR.ft4, .kind = .fpr },
    .{ .id = FPR.ft5, .kind = .fpr },
    .{ .id = FPR.ft6, .kind = .fpr },
    .{ .id = FPR.ft7, .kind = .fpr },
    .{ .id = FPR.ft8, .kind = .fpr },
    .{ .id = FPR.ft9, .kind = .fpr },
    .{ .id = FPR.ft10, .kind = .fpr },
    .{ .id = FPR.ft11, .kind = .fpr },
    .{ .id = FPR.ft12, .kind = .fpr },
    .{ .id = FPR.ft13, .kind = .fpr },
    .{ .id = FPR.ft14, .kind = .fpr },
    .{ .id = FPR.ft15, .kind = .fpr },
};

// ════════════════════════════════════════════════════════════════════
// 桥接模式常量
// ════════════════════════════════════════════════════════════════════

/// JIT 函数入口的参数寄存器（LP64D ABI）。
const ARG0 = GPR.a0; // vm
const ARG1 = GPR.a1; // base

/// 调用 rt_* 函数时的参数寄存器。
const CARG0 = GPR.a0;
const CARG1 = GPR.a1;
const CARG2 = GPR.a2;
const CARG3 = GPR.a3;
const CARG4 = GPR.a4;
const CARG5 = GPR.a5;
const CARG6 = GPR.a6;
const CARG7 = GPR.a7;

/// 桥接模式使用的 callee-saved 寄存器：
/// s0 = vm, s1 = base, s2 = rt_step, s3 = rt_call_inline, s4 = rt_array_push,
/// s5 = rt_array_len, s6 = 常量池地址缓存（可选）
/// LoongArch 有 s0-s8 共 9 个 callee-saved + fp，资源充足。
const BR_VM = GPR.s0;
const BR_BASE = GPR.s1;
const BR_RT_STEP = GPR.s2;
const BR_RT_CALL = GPR.s3;
const BR_RT_PUSH = GPR.s4;
const BR_RT_LEN = GPR.s5;

/// 桥接模式使用的临时寄存器（caller-saved）。
const TMP0 = GPR.a0; // 算术、返回值（与 CARG0 复用，调用前需保存）
const TMP1 = GPR.t0; // 通用临时
const TMP2 = GPR.t1; // frame base（reg_pool + base * 32）
const TMP3 = GPR.t2; // 第二临时
const TMP4 = GPR.t3; // 第三临时

/// 浮点临时寄存器。
const FT0 = FPR.ft0; // f8
const FT1 = FPR.ft1; // f9

/// 桥接模式栈空间：保存 ra, fp, s0-s5 = 8 个寄存器 × 8 字节 = 64 字节，
/// 加上 16 字节对齐 = 80 字节。
const STACK_SPACE: u32 = 80;

/// RegVM 中 reg_pool 字段的偏移量（编译期常量）。
const REG_POOL_PTR_OFFSET: usize = @offsetOf(RegVM, "reg_pool");

/// Value 标签和类型常量。
const TAG_INT_VAL: u8 = runtime.TAG_INT;
const TAG_BOOLEAN_VAL: u8 = runtime.TAG_BOOLEAN;
const TAG_UNIT_VAL: u8 = runtime.TAG_UNIT;
const TAG_NULL_VAL: u8 = runtime.TAG_NULL;
const TAG_FLOAT_VAL: u8 = runtime.TAG_FLOAT;
const TAG_ARRAY_VAL: u8 = runtime.TAG_ARRAY;
const INT_TYPE_I64_VAL: u8 = runtime.INT_TYPE_I64;
const FLOAT_TYPE_F64_VAL: u8 = runtime.FLOAT_TYPE_F64;
const MAX_SCALAR_TAG: u8 = runtime.TAG_FLOAT;

/// Value 内存布局偏移量。
const TAG_OFF: u32 = @intCast(runtime.TAG_OFFSET); // 24
const PAYLOAD_OFF: u32 = @intCast(runtime.PAYLOAD_OFFSET); // 0
const INT_LO_OFF: u32 = @intCast(runtime.INT_LO_OFFSET); // 0
const INT_TYPE_OFF: u32 = @intCast(runtime.INT_TYPE_OFFSET); // 16
const FLOAT_BITS_OFF: u32 = @intCast(runtime.FLOAT_BITS_OFFSET); // 0
const FLOAT_TYPE_OFF: u32 = @intCast(runtime.FLOAT_TYPE_OFFSET); // 16

// ════════════════════════════════════════════════════════════════════
// LoongArch 指令编码辅助函数
// 所有编码遵循 LoongArch Reference Manual Vol1。
// 指令为 32 位定长，小端序。
// ════════════════════════════════════════════════════════════════════

/// 3R-type: opcode[31:15] | rk[14:10] | rj[9:5] | rd[4:0]
inline fn enc3R(opcode: u17, rd: u8, rj: u8, rk: u8) u32 {
    return @as(u32, opcode) << 15 |
        (@as(u32, rk) << 10) |
        (@as(u32, rj) << 5) |
        rd;
}

/// 2RI12-type: opcode[31:22] | imm12[21:10] | rj[9:5] | rd[4:0]
inline fn enc2RI12(opcode: u10, rd: u8, rj: u8, imm12: i16) u32 {
    return @as(u32, opcode) << 22 |
        ((@as(u32, @bitCast(@as(i32, imm12))) & 0xFFF) << 10) |
        (@as(u32, rj) << 5) |
        rd;
}

/// 2RI16-type: opcode[31:26] | imm16[25:10] | rj[9:5] | rd[4:0]
inline fn enc2RI16(opcode: u6, rd: u8, rj: u8, imm16: i16) u32 {
    return @as(u32, opcode) << 26 |
        ((@as(u32, @bitCast(@as(i32, imm16))) & 0xFFFF) << 10) |
        (@as(u32, rj) << 5) |
        rd;
}

/// 1RI20-type: opcode[31:25] | imm20[24:5] | rd[4:0]
inline fn enc1RI20(opcode: u7, rd: u8, imm20: i32) u32 {
    return @as(u32, opcode) << 25 |
        ((@as(u32, @bitCast(imm20)) & 0xFFFFF) << 5) |
        rd;
}

/// 1RI21-type: opcode[31:26] | imm21[15:0][25:10] | rj[9:5] | imm21[20:16][4:0]
inline fn enc1RI21(opcode: u6, rj: u8, imm21: i32) u32 {
    const uimm: u32 = @as(u32, @bitCast(imm21)) & 0x1FFFFF;
    return @as(u32, opcode) << 26 |
        ((uimm & 0xFFFF) << 10) |
        (@as(u32, rj) << 5) |
        ((uimm >> 16) & 0x1F);
}

/// I26-type: opcode[31:26] | imm26[15:0][25:10] | imm26[25:16][9:0]
inline fn encI26(opcode: u6, imm26: i32) u32 {
    const uimm: u32 = @as(u32, @bitCast(imm26)) & 0x3FFFFFF;
    return @as(u32, opcode) << 26 |
        ((uimm & 0xFFFF) << 10) |
        ((uimm >> 16) & 0x3FF);
}

/// 2R-type: opcode[31:10] | rj[9:5] | rd[4:0]
inline fn enc2R(opcode: u22, rd: u8, rj: u8) u32 {
    return @as(u32, opcode) << 10 |
        (@as(u32, rj) << 5) |
        rd;
}

/// 3R-type 操作码常量（bits[31:15]）。
/// 指令 = opcode << 15 | (rk << 10) | (rj << 5) | rd
const OP3R = struct {
    pub const ADD_D: u17 = 0b0000000000_01_00001; // 0x00108000 >> 15 = 0x21
    pub const SUB_D: u17 = 0b0000000000_01_00011; // 0x00118000 >> 15 = 0x23
    pub const SLT: u17 = 0b0000000000_00_00100; // 0x00120000 >> 15 = 0x24
    pub const SLTU: u17 = 0b0000000000_00_00101; // 0x00128000 >> 15 = 0x25
    pub const NOR: u17 = 0b0000000000_00_01000; // 0x00140000 >> 15 = 0x28
    pub const AND: u17 = 0b0000000000_00_01001; // 0x00148000 >> 15 = 0x29
    pub const OR: u17 = 0b0000000000_00_01010; // 0x00150000 >> 15 = 0x2A
    pub const XOR: u17 = 0b0000000000_00_01011; // 0x00158000 >> 15 = 0x2B
    pub const ORN: u17 = 0b0000000000_00_01100; // 0x00160000 >> 15 = 0x2C
    pub const ANDN: u17 = 0b0000000000_00_01101; // 0x00168000 >> 15 = 0x2D
    pub const SLL_D: u17 = 0b0000000000_01_10001; // 0x00188000 >> 15 = 0x31
    pub const SRL_D: u17 = 0b0000000000_01_10010; // 0x00190000 >> 15 = 0x32
    pub const SRA_D: u17 = 0b0000000000_01_10011; // 0x00198000 >> 15 = 0x33
    pub const MUL_D: u17 = 0b0000000000_01_11011; // 0x001d8000 >> 15 = 0x3B
    pub const MULH_D: u17 = 0b0000000000_01_11100; // 0x001e0000 >> 15 = 0x3C
    pub const DIV_D: u17 = 0b0000000000_10_00100; // 0x00220000 >> 15 = 0x44
    pub const MOD_D: u17 = 0b0000000000_10_00101; // 0x00228000 >> 15 = 0x45
    pub const DIV_DU: u17 = 0b0000000000_10_00110; // 0x00230000 >> 15 = 0x46
    pub const MOD_DU: u17 = 0b0000000000_10_00111; // 0x00238000 >> 15 = 0x47
};

/// 2RI12-type 操作码常量（bits[31:22]）。
const OP2RI12 = struct {
    pub const SLTI: u10 = 0b0000001000; // 0x02000000 >> 22 = 0x008
    pub const SLTUI: u10 = 0b0000001001; // 0x02400000 >> 22 = 0x009
    pub const ADDI_W: u10 = 0b0000001010; // 0x02800000 >> 22 = 0x00A
    pub const ADDI_D: u10 = 0b0000001011; // 0x02c00000 >> 22 = 0x00B
    pub const LU52I_D: u10 = 0b0000001100; // 0x03000000 >> 22 = 0x00C
    pub const ANDI: u10 = 0b0000001101; // 0x03400000 >> 22 = 0x00D
    pub const ORI: u10 = 0b0000001110; // 0x03800000 >> 22 = 0x00E
    pub const XORI: u10 = 0b0000001111; // 0x03c00000 >> 22 = 0x00F
    pub const LD_B: u10 = 0b0010100000; // 0x28000000 >> 22 = 0x0A0
    pub const LD_H: u10 = 0b0010100001; // 0x28400000 >> 22 = 0x0A1
    pub const LD_W: u10 = 0b0010100010; // 0x28800000 >> 22 = 0x0A2
    pub const LD_D: u10 = 0b0010100011; // 0x28c00000 >> 22 = 0x0A3
    pub const ST_B: u10 = 0b0010100100; // 0x29000000 >> 22 = 0x0A4
    pub const ST_H: u10 = 0b0010100101; // 0x29400000 >> 22 = 0x0A5
    pub const ST_W: u10 = 0b0010100110; // 0x29800000 >> 22 = 0x0A6
    pub const ST_D: u10 = 0b0010100111; // 0x29c00000 >> 22 = 0x0A7
    pub const LD_BU: u10 = 0b0010101000; // 0x2a000000 >> 22 = 0x0A8
    pub const LD_HU: u10 = 0b0010101001; // 0x2a400000 >> 22 = 0x0A9
    pub const LD_WU: u10 = 0b0010101010; // 0x2a800000 >> 22 = 0x0AA
};

/// 1RI20-type 操作码常量（bits[31:25]）。
const OP1RI20 = struct {
    pub const LU12I_W: u7 = 0b0001010; // 0x14000000 >> 25 = 0x0A
    pub const LU32I_D: u7 = 0b0001011; // 0x16000000 >> 25 = 0x0B
    pub const PCADDI: u7 = 0b0001100; // 0x18000000 >> 25 = 0x0C
    pub const PCALAU12I: u7 = 0b0001101; // 0x1a000000 >> 25 = 0x0D
    pub const PCADDU12I: u7 = 0b0001110; // 0x1c000000 >> 25 = 0x0E
    pub const PCADDU18I: u7 = 0b0001111; // 0x1e000000 >> 25 = 0x0F
};

/// 2RI16-type / 1RI21-type / I26-type 操作码常量（bits[31:26]）。
const OPBR = struct {
    pub const ADDU16I_D: u6 = 0b000100; // 0x10000000 >> 26 = 0x04
    pub const JIRL: u6 = 0b010011; // 0x4c000000 >> 26 = 0x13
    pub const BEQZ: u6 = 0b010000; // 0x40000000 >> 26 = 0x10
    pub const BNEZ: u6 = 0b010001; // 0x44000000 >> 26 = 0x11
    pub const BCEQZ: u6 = 0b010010; // 0x48000000 >> 26 = 0x12
    pub const BCNEZ: u6 = 0b010010; // 0x48000100 >> 26 = 0x12 (distinguished by bit 8)
    pub const B: u6 = 0b010100; // 0x50000000 >> 26 = 0x14
    pub const BL: u6 = 0b010101; // 0x54000000 >> 26 = 0x15
    pub const BEQ: u6 = 0b010110; // 0x58000000 >> 26 = 0x16
    pub const BNE: u6 = 0b010111; // 0x5c000000 >> 26 = 0x17
    pub const BLT: u6 = 0b011000; // 0x60000000 >> 26 = 0x18
    pub const BGE: u6 = 0b011001; // 0x64000000 >> 26 = 0x19
    pub const BLTU: u6 = 0b011010; // 0x68000000 >> 26 = 0x1A
    pub const BGEU: u6 = 0b011011; // 0x6c000000 >> 26 = 0x1B
};

/// 2R-type 浮点操作码常量（bits[31:10]）。
const OP2R = struct {
    pub const FMOV_D: u22 = 0b0001000101001011100000; // 0x01149800 >> 10
    pub const FABS_D: u22 = 0b0001000101001010000010; // 0x01140800 >> 10
    pub const FNEG_D: u22 = 0b0001000101001011000110; // 0x01141800 >> 10
    pub const MOVGR2FR_D: u22 = 0b0001000101001010001010; // 0x0114a800 >> 10
    pub const MOVFR2GR_D: u22 = 0b0001000101001011101010; // 0x0114b800 >> 10
    pub const FFINT_D_L: u22 = 0b0001000111010010010000; // 0x011d2800 >> 10 (int64→double)
    pub const FTINTRZ_W_D: u22 = 0b0001000110101000100010; // 0x011a8800 >> 10 (double→int32 trunc)
    pub const FTINTRNE_W_D: u22 = 0b0001000110101100100010; // 0x011ac800 >> 10 (double→int32 round)
};

/// 浮点 3R-type 操作码常量（bits[31:15]）。
const OPF3R = struct {
    pub const FADD_D: u17 = 0b0000000010000010_0; // 0x01010000 >> 15
    pub const FSUB_D: u17 = 0b0000000010000110_0; // 0x01030000 >> 15
    pub const FMUL_D: u17 = 0b0000000010001010_0; // 0x01050000 >> 15
    pub const FDIV_D: u17 = 0b0000000010001110_0; // 0x01070000 >> 15
    pub const FCMP_CEQ_D: u17 = 0b0000011000010010_0; // 0x0c220000 >> 15
    pub const FCMP_CLT_D: u17 = 0b0000011000010001_0; // 0x0c210000 >> 15
    pub const FCMP_CLE_D: u17 = 0b0000011000010011_0; // 0x0c230000 >> 15
};

/// 浮点 2RI12-type 操作码常量（bits[31:22]）。
const OPF2RI12 = struct {
    pub const FLD_D: u10 = 0b0010101110; // 0x2b800000 >> 22 = 0x0AE
    pub const FST_D: u10 = 0b0010101111; // 0x2bc00000 >> 22 = 0x0AF
};

/// 条件码映射（LoongArch 分支条件）。
/// 对于整数比较后的分支：BLT/BGE/BLTU/BGEU/BEQ/BNE
const LACond = struct {
    pub const EQ: u6 = OPBR.BEQ;
    pub const NE: u6 = OPBR.BNE;
    pub const LT: u6 = OPBR.BLT;
    pub const GE: u6 = OPBR.BGE;
    pub const LTU: u6 = OPBR.BLTU;
    pub const GEU: u6 = OPBR.BGEU;
};

// ════════════════════════════════════════════════════════════════════
// 桥接模式代码缓冲区与指令发射
// ════════════════════════════════════════════════════════════════════

/// 桥接模式代码缓冲区。
const BridgeBuf = struct {
    code: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn append(self: *BridgeBuf, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    fn appendU32(self: *BridgeBuf, val: u32) !void {
        try self.code.appendSlice(self.allocator, std.mem.asBytes(&val));
    }

    fn len(self: *const BridgeBuf) u32 {
        return @intCast(self.code.items.len);
    }

    /// 发射一条 32 位指令（小端序）。
    fn emit(self: *BridgeBuf, inst: u32) !void {
        try self.appendU32(inst);
    }

    // ── 整数算术指令 ──

    /// add.d rd, rj, rk
    fn addD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.ADD_D, rd, rj, rk));
    }

    /// sub.d rd, rj, rk
    fn subD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SUB_D, rd, rj, rk));
    }

    /// mul.d rd, rj, rk
    fn mulD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.MUL_D, rd, rj, rk));
    }

    /// div.d rd, rj, rk (有符号除法)
    fn divD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.DIV_D, rd, rj, rk));
    }

    /// mod.d rd, rj, rk (有符号取余)
    fn modD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.MOD_D, rd, rj, rk));
    }

    /// and rd, rj, rk
    fn andReg(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.AND, rd, rj, rk));
    }

    /// or rd, rj, rk
    fn orReg(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.OR, rd, rj, rk));
    }

    /// xor rd, rj, rk
    fn xorReg(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.XOR, rd, rj, rk));
    }

    /// slt rd, rj, rk (有符号比较，rd = rj < rk ? 1 : 0)
    fn slt(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SLT, rd, rj, rk));
    }

    /// sltu rd, rj, rk (无符号比较)
    fn sltu(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SLTU, rd, rj, rk));
    }

    /// sll.d rd, rj, rk (逻辑左移)
    fn sllD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SLL_D, rd, rj, rk));
    }

    /// srl.d rd, rj, rk (逻辑右移)
    fn srlD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SRL_D, rd, rj, rk));
    }

    /// sra.d rd, rj, rk (算术右移)
    fn sraD(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.SRA_D, rd, rj, rk));
    }

    /// nor rd, rj, rk
    fn norReg(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.NOR, rd, rj, rk));
    }

    /// orn rd, rj, rk
    fn ornReg(self: *BridgeBuf, rd: u8, rj: u8, rk: u8) !void {
        try self.emit(enc3R(OP3R.ORN, rd, rj, rk));
    }

    // ── 立即数算术指令 ──

    /// addi.d rd, rj, imm12
    fn addiD(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ADDI_D, rd, rj, imm12));
    }

    /// addi.w rd, rj, imm12
    fn addiW(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ADDI_W, rd, rj, imm12));
    }

    /// slti rd, rj, imm12
    fn slti(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.SLTI, rd, rj, imm12));
    }

    /// andi rd, rj, imm12
    fn andi(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ANDI, rd, rj, imm12));
    }

    /// ori rd, rj, imm12
    fn ori(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ORI, rd, rj, imm12));
    }

    /// xori rd, rj, imm12
    fn xori(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.XORI, rd, rj, imm12));
    }

    // ── 大立即数加载 ──

    /// lu12i.w rd, imm20 (加载低 20 位到 bits[31:12]，符号扩展到 64 位)
    fn lu12iW(self: *BridgeBuf, rd: u8, imm20: i32) !void {
        try self.emit(enc1RI20(OP1RI20.LU12I_W, rd, imm20));
    }

    /// lu32i.d rd, imm20 (加载 bits[51:32]，保持 bits[31:0] 不变)
    fn lu32iD(self: *BridgeBuf, rd: u8, imm20: i32) !void {
        try self.emit(enc1RI20(OP1RI20.LU32I_D, rd, imm20));
    }

    /// lu52i.d rd, rj, imm12 (加载 bits[63:52])
    fn lu52iD(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.LU52I_D, rd, rj, imm12));
    }

    /// addu16i.d rd, rj, imm16 (rd = rj + (imm16 << 16))
    fn addu16iD(self: *BridgeBuf, rd: u8, rj: u8, imm16: i16) !void {
        try self.emit(enc2RI16(OPBR.ADDU16I_D, rd, rj, imm16));
    }

    // ── 访存指令 ──

    /// ld.d rd, rj, imm12 (加载 8 字节)
    fn ldD(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.LD_D, rd, rj, imm12));
    }

    /// ld.w rd, rj, imm12 (加载 4 字节，符号扩展)
    fn ldW(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.LD_W, rd, rj, imm12));
    }

    /// ld.bu rd, rj, imm12 (加载 1 字节，零扩展)
    fn ldBu(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.LD_BU, rd, rj, imm12));
    }

    /// ld.wu rd, rj, imm12 (加载 4 字节，零扩展)
    fn ldWu(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.LD_WU, rd, rj, imm12));
    }

    /// st.d rd, rj, imm12 (存储 8 字节)
    fn stD(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ST_D, rd, rj, imm12));
    }

    /// st.w rd, rj, imm12 (存储 4 字节)
    fn stW(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ST_W, rd, rj, imm12));
    }

    /// st.b rd, rj, imm12 (存储 1 字节)
    fn stB(self: *BridgeBuf, rd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OP2RI12.ST_B, rd, rj, imm12));
    }

    // ── 浮点访存指令 ──

    /// fld.d fd, rj, imm12 (加载 8 字节浮点)
    fn fldD(self: *BridgeBuf, fd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OPF2RI12.FLD_D, fd, rj, imm12));
    }

    /// fst.d fd, rj, imm12 (存储 8 字节浮点)
    fn fstD(self: *BridgeBuf, fd: u8, rj: u8, imm12: i16) !void {
        try self.emit(enc2RI12(OPF2RI12.FST_D, fd, rj, imm12));
    }

    // ── 浮点算术指令 ──

    /// fadd.d fd, fj, fk
    fn faddD(self: *BridgeBuf, fd: u8, fj: u8, fk: u8) !void {
        try self.emit(enc3R(OPF3R.FADD_D, fd, fj, fk));
    }

    /// fsub.d fd, fj, fk
    fn fsubD(self: *BridgeBuf, fd: u8, fj: u8, fk: u8) !void {
        try self.emit(enc3R(OPF3R.FSUB_D, fd, fj, fk));
    }

    /// fmul.d fd, fj, fk
    fn fmulD(self: *BridgeBuf, fd: u8, fj: u8, fk: u8) !void {
        try self.emit(enc3R(OPF3R.FMUL_D, fd, fj, fk));
    }

    /// fdiv.d fd, fj, fk
    fn fdivD(self: *BridgeBuf, fd: u8, fj: u8, fk: u8) !void {
        try self.emit(enc3R(OPF3R.FDIV_D, fd, fj, fk));
    }

    /// fcmp.ceq.d cc, fj, fk (结果写入 FCC 寄存器 cc)
    /// LoongArch FCMP 格式: opcode[31:15] | fk[14:10] | fj[9:5] | cond[4:3]=00 | cc[2:0]
    fn fcmpCeqD(self: *BridgeBuf, cc: u8, fj: u8, fk: u8) !void {
        // FCMP.CEQ.D: opcode bits[31:15] = 0b0000011000010010_0, bit[15]=0 for C variant
        // 实际编码: cond[19:16]=0010(CEQ), bit[15]=0
        // 完整指令 = (0x0c220000) | (fk<<10) | (fj<<5) | (0<<3) | (cc&7)
        const inst: u32 = 0x0c220000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
        try self.emit(inst);
    }

    /// fcmp.clt.d cc, fj, fk
    fn fcmpCltD(self: *BridgeBuf, cc: u8, fj: u8, fk: u8) !void {
        const inst: u32 = 0x0c210000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
        try self.emit(inst);
    }

    /// fcmp.cle.d cc, fj, fk
    fn fcmpCleD(self: *BridgeBuf, cc: u8, fj: u8, fk: u8) !void {
        const inst: u32 = 0x0c230000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
        try self.emit(inst);
    }

    // ── 浮点 2R 指令 ──

    /// fmov.d fd, fj
    fn fmovD(self: *BridgeBuf, fd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.FMOV_D, fd, fj));
    }

    /// fabs.d fd, fj
    fn fabsD(self: *BridgeBuf, fd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.FABS_D, fd, fj));
    }

    /// fneg.d fd, fj
    fn fnegD(self: *BridgeBuf, fd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.FNEG_D, fd, fj));
    }

    /// movgr2fr.d fd, rj (GPR → FPR)
    fn movgr2frD(self: *BridgeBuf, fd: u8, rj: u8) !void {
        try self.emit(enc2R(OP2R.MOVGR2FR_D, fd, rj));
    }

    /// movfr2gr.d rd, fj (FPR → GPR)
    fn movfr2grD(self: *BridgeBuf, rd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.MOVFR2GR_D, rd, fj));
    }

    /// ffint.d.l fd, fj (int64 → double)
    fn ffintDL(self: *BridgeBuf, fd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.FFINT_D_L, fd, fj));
    }

    /// ftintrz.w.d fd, fj (double → int32, 向零取整)
    fn ftintrzWD(self: *BridgeBuf, fd: u8, fj: u8) !void {
        try self.emit(enc2R(OP2R.FTINTRZ_W_D, fd, fj));
    }

    // ── 伪指令 ──

    /// move rd, rj (等价于 or rd, rj, zero)
    fn moveReg(self: *BridgeBuf, rd: u8, rj: u8) !void {
        try self.orReg(rd, rj, GPR.zero);
    }

    /// 加载 64 位立即数到寄存器。
    /// 使用 lu12i.w + lu32i.d + lu52i.d 三条指令。
    fn loadImm64(self: *BridgeBuf, rd: u8, val: u64) !void {
        const lo20: i32 = @intCast((val >> 12) & 0xFFFFF);
        const mid20: i32 = @intCast((val >> 32) & 0xFFFFF);
        const hi12: i16 = @intCast((val >> 52) & 0xFFF);
        // lu12i.w rd, lo20 (bits[31:12] = lo20, 符号扩展到 64 位)
        // 注意：imm20 是 bits[31:12] 的值，需要符号扩展
        const lo20_signed: i32 = if (lo20 & 0x80000 != 0) lo20 - 0x100000 else lo20;
        try self.lu12iW(rd, lo20_signed);
        // lu32i.d rd, mid20 (bits[51:32] = mid20)
        const mid20_signed: i32 = if (mid20 & 0x80000 != 0) mid20 - 0x100000 else mid20;
        try self.lu32iD(rd, mid20_signed);
        // lu52i.d rd, rd, hi12 (bits[63:52] = hi12)
        try self.lu52iD(rd, rd, hi12);
    }

    // ── 分支指令 ──

    /// b offs26 (无条件跳转，PC 相对)
    /// 返回跳转指令在 code 中的偏移（用于后续回填）。
    fn b(self: *BridgeBuf) !u32 {
        const pos = self.len();
        try self.emit(encI26(OPBR.B, 0));
        return pos;
    }

    /// bl offs26 (带链接跳转，ra = PC + 4)
    fn bl(self: *BridgeBuf) !u32 {
        const pos = self.len();
        try self.emit(encI26(OPBR.BL, 0));
        return pos;
    }

    /// jirl rd, rj, imm16 (间接跳转并链接：rd = PC + 4, PC = rj + imm16<<2)
    fn jirl(self: *BridgeBuf, rd: u8, rj: u8, imm16: i16) !void {
        try self.emit(enc2RI16(OPBR.JIRL, rd, rj, imm16));
    }

    /// beq rj, rd, offs16
    /// 返回跳转指令偏移（用于回填）。
    fn beq(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        // beq 格式: opcode[31:26] | offs16[25:10] | rj[9:5] | rd[4:0]
        // 占位 offs16=0
        try self.emit((@as(u32, OPBR.BEQ) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// bne rj, rd, offs16
    fn bne(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        try self.emit((@as(u32, OPBR.BNE) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// blt rj, rd, offs16
    fn blt(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        try self.emit((@as(u32, OPBR.BLT) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// bge rj, rd, offs16
    fn bge(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        try self.emit((@as(u32, OPBR.BGE) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// bltu rj, rd, offs16
    fn bltu(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        try self.emit((@as(u32, OPBR.BLTU) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// bgeu rj, rd, offs16
    fn bgeu(self: *BridgeBuf, rj: u8, rd: u8) !u32 {
        const pos = self.len();
        try self.emit((@as(u32, OPBR.BGEU) << 26) | (@as(u32, rj) << 5) | rd);
        return pos;
    }

    /// beqz rj, offs21
    fn beqz(self: *BridgeBuf, rj: u8) !u32 {
        const pos = self.len();
        try self.emit(@as(u32, OPBR.BEQZ) << 26 | (@as(u32, rj) << 5));
        return pos;
    }

    /// bnez rj, offs21
    fn bnez(self: *BridgeBuf, rj: u8) !u32 {
        const pos = self.len();
        try self.emit(@as(u32, OPBR.BNEZ) << 26 | (@as(u32, rj) << 5));
        return pos;
    }

    /// bceqz cj, offs21 (FCC 条件跳转：FCC[cj]==0 时跳转)
    /// 编码: opcode[31:26]=010010 | offs21[15:0][25:10] | subop[9:8]=00 | cj[7:5] | offs21[20:16][4:0]
    fn bceqz(self: *BridgeBuf, cj: u8) !u32 {
        const pos = self.len();
        try self.emit(@as(u32, 0b010010) << 26 | (@as(u32, cj & 7) << 5));
        return pos;
    }

    /// bcnez cj, offs21 (FCC 条件跳转：FCC[cj]!=0 时跳转)
    /// 编码: opcode[31:26]=010010 | offs21[15:0][25:10] | subop[9:8]=01 | cj[7:5] | offs21[20:16][4:0]
    fn bcnez(self: *BridgeBuf, cj: u8) !u32 {
        const pos = self.len();
        try self.emit(@as(u32, 0b010010) << 26 | (@as(u32, 0b01) << 8) | (@as(u32, cj & 7) << 5));
        return pos;
    }

    // ── 栈操作 ──

    /// st.d rd, sp, imm12
    fn pushReg(self: *BridgeBuf, rd: u8, offset: i16) !void {
        try self.stD(rd, GPR.sp, offset);
    }

    /// ld.d rd, sp, imm12
    fn popReg(self: *BridgeBuf, rd: u8, offset: i16) !void {
        try self.ldD(rd, GPR.sp, offset);
    }

    // ── 回填函数 ──

    /// 回填 B/BL 跳转目标（I26-type）。
    /// 偏移量 = (target_offset - jump_offset) >> 2，需为 4 字节对齐。
    /// I26 编码: imm26[15:0] 在 bits[25:10], imm26[25:16] 在 bits[9:0]
    fn patchB(code: []u8, jump_offset: u32, target_offset: u32) void {
        const diff: i64 = @as(i64, target_offset) - @as(i64, jump_offset);
        const off26: i32 = @intCast(diff >> 2);
        const uimm: u32 = @as(u32, @bitCast(off26)) & 0x3FFFFFF;
        // 读取当前指令
        var inst: u32 = std.mem.readInt(u32, code[jump_offset..][0..4], .little);
        // 清除 imm26 字段
        inst &= ~((0xFFFF << 10) | 0x3FF);
        // 设置新的 imm26
        inst |= ((uimm & 0xFFFF) << 10) | ((uimm >> 16) & 0x3FF);
        std.mem.writeInt(u32, code[jump_offset..][0..4], inst, .little);
    }

    /// 回填 BEQ/BNE/BLT/BGE/BLTU/BGEU 跳转目标（2RI16-type）。
    /// 偏移量 = (target_offset - jump_offset) >> 2。
    /// offs16 在 bits[25:10]。
    fn patchBcc(code: []u8, jump_offset: u32, target_offset: u32) void {
        const diff: i64 = @as(i64, target_offset) - @as(i64, jump_offset);
        const off16: i32 = @intCast(diff >> 2);
        const uimm: u32 = @as(u32, @bitCast(off16)) & 0xFFFF;
        var inst: u32 = std.mem.readInt(u32, code[jump_offset..][0..4], .little);
        inst &= ~(0xFFFF << 10);
        inst |= uimm << 10;
        std.mem.writeInt(u32, code[jump_offset..][0..4], inst, .little);
    }

    /// 回填 BEQZ/BNEZ 跳转目标（1RI21-type）。
    /// 偏移量 = (target_offset - jump_offset) >> 2。
    /// imm21[15:0] 在 bits[25:10], imm21[20:16] 在 bits[4:0]。
    fn patchBz(code: []u8, jump_offset: u32, target_offset: u32) void {
        const diff: i64 = @as(i64, target_offset) - @as(i64, jump_offset);
        const off21: i32 = @intCast(diff >> 2);
        const uimm: u32 = @as(u32, @bitCast(off21)) & 0x1FFFFF;
        var inst: u32 = std.mem.readInt(u32, code[jump_offset..][0..4], .little);
        // 清除 imm21 字段: bits[25:10] 和 bits[4:0]
        inst &= ~((0xFFFF << 10) | 0x1F);
        inst |= ((uimm & 0xFFFF) << 10) | ((uimm >> 16) & 0x1F);
        std.mem.writeInt(u32, code[jump_offset..][0..4], inst, .little);
    }
};

/// 待回填的跳转（桥接模式专用）。
const BridgeFixup = struct {
    code_offset: u32, // 跳转指令在 code 中的偏移
    target_ip: u32, // 目标字节码 IP（0xFFFFFFFF = exit）
    kind: u8, // 1=B(uncond), 2=Bcc(cond), 3=Bz(zero), 4=exit_via_B
};

/// 发射 rt_step 桥接调用代码。
/// rt_step(vm, ip) — 返回 false=继续, true=函数已返回
/// 调用后检查返回值，如果为 true 则跳转到 exit。
fn emitRtStepCall(
    buf: *BridgeBuf,
    ip: u32,
    pending_fixups: *std.ArrayListUnmanaged(BridgeFixup),
    allocator: std.mem.Allocator,
) !void {
    // 设置参数: a0 = vm (s0), a1 = ip
    try buf.moveReg(CARG0, BR_VM);
    try buf.loadImm64(CARG1, @intCast(ip));
    // jirl ra, s2, 0 (调用 rt_step)
    try buf.jirl(GPR.ra, BR_RT_STEP, 0);
    // beqz a0, next (如果返回 false=继续，跳过 exit)
    const bz_pos = try buf.beqz(TMP0);
    // b exit (占位)
    const b_pos = try buf.b();
    // next:
    const next_off = buf.len();
    BridgeBuf.patchBz(buf.code.items, bz_pos, next_off);
    // exit 跳转回填
    try pending_fixups.append(allocator, .{
        .code_offset = b_pos,
        .target_ip = 0xFFFFFFFF,
        .kind = 4,
    });
}

/// 发射计算 frame base 的代码：TMP2 = reg_pool.ptr + base * 32
/// reg_pool 指针从 [vm + REG_POOL_PTR_OFFSET] 加载（它是 slice，ptr 在 offset 0）。
fn emitFrameBase2(buf: *BridgeBuf) !void {
    const pool_off: i16 = @intCast(REG_POOL_PTR_OFFSET);
    // ld.d TMP3, BR_VM, pool_off  → TMP3 = reg_pool.ptr
    try buf.ldD(TMP3, BR_VM, pool_off);
    // addi.d TMP4, zero, 5
    try buf.addiD(TMP4, GPR.zero, 5);
    // sll.d TMP4, BR_BASE, TMP4   → TMP4 = base << 5 = base * 32
    try buf.sllD(TMP4, BR_BASE, TMP4);
    // add.d TMP2, TMP3, TMP4      → TMP2 = frame base
    try buf.addD(TMP2, TMP3, TMP4);
}

// ════════════════════════════════════════════════════════════════════
// 桥接模式编译主函数
// ════════════════════════════════════════════════════════════════════

/// 桥接模式编译：直接从字节码生成 LoongArch64 机器码。
///
/// JIT 函数签名: fn(vm: *RegVM, base: usize) callconv(.c) void
/// 热点 opcode（i64/f64 算术/比较/跳转）生成内联原生代码。
/// 冷门 opcode 通过 rt_step 桥接函数委托 VM 单步执行。
///
/// 仅支持 register_count <= 120 的函数。
pub fn compileBridge(
    allocator: std.mem.Allocator,
    func: *const reg_chunk.RegFunction,
    func_idx: u32,
    exec_mem: *mem.ExecMemory,
    rt_step_addr: usize,
    rt_call_inline_addr: usize,
    rt_array_push_addr: usize,
    rt_array_len_addr: usize,
    functions: []const reg_chunk.RegFunction,
) !usize {
    if (func.register_count > 120) return error.JitTooManyRegisters;
    _ = func_idx;

    var code = std.ArrayListUnmanaged(u8).empty;
    defer code.deinit(allocator);

    var buf = BridgeBuf{ .code = &code, .allocator = allocator };

    // 字节码 ip → 代码偏移映射
    var ip_to_code = std.AutoHashMap(u32, u32).init(allocator);
    defer ip_to_code.deinit();

    // 待回填的向前跳转
    var pending_fixups = std.ArrayListUnmanaged(BridgeFixup).empty;
    defer pending_fixups.deinit(allocator);

    // ── 类型传播 ──
    const RegType = enum { unknown, i64, f64, boolean };
    const reg_count = func.register_count;
    var reg_types = try allocator.alloc(RegType, reg_count);
    defer allocator.free(reg_types);
    @memset(reg_types, .unknown);
    for (func.param_types, 0..) |pt, i| {
        if (i >= reg_count) break;
        if (pt) |tname| {
            if (std.mem.eql(u8, tname, "i8") or std.mem.eql(u8, tname, "i16") or
                std.mem.eql(u8, tname, "i32") or std.mem.eql(u8, tname, "i64") or
                std.mem.eql(u8, tname, "u8") or std.mem.eql(u8, tname, "u16") or
                std.mem.eql(u8, tname, "u32") or std.mem.eql(u8, tname, "u64") or
                std.mem.eql(u8, tname, "i128") or std.mem.eql(u8, tname, "u128"))
            {
                reg_types[i] = .i64;
            } else if (std.mem.eql(u8, tname, "f16") or std.mem.eql(u8, tname, "f32") or
                std.mem.eql(u8, tname, "f64") or std.mem.eql(u8, tname, "f128"))
            {
                reg_types[i] = .f64;
            } else if (std.mem.eql(u8, tname, "bool")) {
                reg_types[i] = .boolean;
            }
        }
    }

    // ── 第一遍：收集跳转目标 ──
    var jump_targets = std.AutoHashMap(u32, void).init(allocator);
    defer jump_targets.deinit();
    {
        const jt_instrs = func.chunk.code.items;
        var jt_ip: u32 = 0;
        while (jt_ip < jt_instrs.len) : (jt_ip += 1) {
            const jt_inst = jt_instrs[jt_ip];
            const jt_op = reg_opcode.getOp(jt_inst);
            const jt_sbx = reg_opcode.getsBx(jt_inst);
            switch (jt_op) {
                .jump, .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                    const target: u32 = @intCast(@as(i64, @intCast(jt_ip + 1)) + jt_sbx);
                    if (target < jt_instrs.len) {
                        jump_targets.put(target, {}) catch {};
                    }
                },
                else => {},
            }
        }
    }

    var exit_offset: u32 = 0;

    // ════════ 函数 prologue ════════
    // addi.d sp, sp, -STACK_SPACE
    try buf.addiD(GPR.sp, GPR.sp, -@as(i16, @intCast(STACK_SPACE)));
    // st.d ra, sp, 0
    try buf.stD(GPR.ra, GPR.sp, 0);
    // st.d fp, sp, 8
    try buf.stD(GPR.fp, GPR.sp, 8);
    // st.d s0, sp, 16
    try buf.stD(GPR.s0, GPR.sp, 16);
    // st.d s1, sp, 24
    try buf.stD(GPR.s1, GPR.sp, 24);
    // st.d s2, sp, 32
    try buf.stD(GPR.s2, GPR.sp, 32);
    // st.d s3, sp, 40
    try buf.stD(GPR.s3, GPR.sp, 40);
    // st.d s4, sp, 48
    try buf.stD(GPR.s4, GPR.sp, 48);
    // st.d s5, sp, 56
    try buf.stD(GPR.s5, GPR.sp, 56);

    // move s0, a0 (vm)
    try buf.moveReg(BR_VM, ARG0);
    // move s1, a1 (base)
    try buf.moveReg(BR_BASE, ARG1);

    // 加载 rt 函数地址到 callee-saved 寄存器
    try buf.loadImm64(BR_RT_STEP, @intCast(rt_step_addr));
    try buf.loadImm64(BR_RT_CALL, @intCast(rt_call_inline_addr));
    try buf.loadImm64(BR_RT_PUSH, @intCast(rt_array_push_addr));
    try buf.loadImm64(BR_RT_LEN, @intCast(rt_array_len_addr));

    // ════════ 函数体 ════════
    const instructions = func.chunk.code.items;

    var ip: u32 = 0;
    while (ip < instructions.len) : (ip += 1) {
        try ip_to_code.put(ip, buf.len());

        // 跳转目标处重置类型传播
        if (ip > 0 and jump_targets.contains(ip)) {
            @memset(reg_types, .unknown);
        }

        const inst = instructions[ip];
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);
        const bx = reg_opcode.getBx(inst);
        const sbx = reg_opcode.getsBx(inst);

        switch (op) {
            // ── 热点 opcode：i64/f64 算术 ──
            .add, .sub, .mul, .div, .mod => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                if (b_known_i64 and c_known_i64) {
                    // ── i64 快速路径 ──
                    try emitFrameBase2(&buf);
                    // t0 = reg_pool[b].lo
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    // t3 = reg_pool[c].lo
                    try buf.ldD(TMP3, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    switch (op) {
                        .add => try buf.addD(TMP0, TMP0, TMP3),
                        .sub => try buf.subD(TMP0, TMP0, TMP3),
                        .mul => try buf.mulD(TMP0, TMP0, TMP3),
                        .div => try buf.divD(TMP0, TMP0, TMP3),
                        .mod => try buf.modD(TMP0, TMP0, TMP3),
                        else => unreachable,
                    }
                    // 存储 tag = TAG_INT
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    // 存储 int type = I64
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));
                    // 存储 lo
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));
                    reg_types[a] = .i64;
                } else if (b_known_f64 and c_known_f64 and op != .mod) {
                    // ── f64 快速路径 ──
                    try emitFrameBase2(&buf);
                    // ft0 = reg_pool[b].bits
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    // ft1 = reg_pool[c].bits
                    try buf.fldD(FT1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    switch (op) {
                        .add => try buf.faddD(FT0, FT0, FT1),
                        .sub => try buf.fsubD(FT0, FT0, FT1),
                        .mul => try buf.fmulD(FT0, FT0, FT1),
                        .div => try buf.fdivD(FT0, FT0, FT1),
                        else => unreachable,
                    }
                    // 存储 f64 结果
                    try buf.fstD(FT0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：tag 检查通用路径 ──
                    try emitFrameBase2(&buf);

                    // 检查 b tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const bne1_pos = try buf.bne(TMP0, TMP1);

                    // 检查 c tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)));
                    const bne2_pos = try buf.bne(TMP0, TMP1);

                    // 加载 i64 值
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.ldD(TMP3, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));

                    switch (op) {
                        .add => try buf.addD(TMP0, TMP0, TMP3),
                        .sub => try buf.subD(TMP0, TMP0, TMP3),
                        .mul => try buf.mulD(TMP0, TMP0, TMP3),
                        .div => try buf.divD(TMP0, TMP0, TMP3),
                        .mod => try buf.modD(TMP0, TMP0, TMP3),
                        else => unreachable,
                    }

                    // 存储 i64 结果
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));

                    const b_next = try buf.b();

                    // not_int 目标
                    const not_int_target = buf.len();
                    BridgeBuf.patchBcc(code.items, bne1_pos, not_int_target);
                    BridgeBuf.patchBcc(code.items, bne2_pos, not_int_target);

                    var b_next2: u32 = 0;

                    // ── f64 快速路径（.mod 无浮点路径）──
                    if (op != .mod) {
                        // 检查 b tag == TAG_FLOAT
                        try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                        try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                        const jne_f1 = try buf.bne(TMP0, TMP1);

                        // 检查 c tag == TAG_FLOAT
                        try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)));
                        const jne_f2 = try buf.bne(TMP0, TMP1);

                        // 检查 b float type == F64
                        try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                        try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                        const jne_f3 = try buf.bne(TMP0, TMP1);

                        // 检查 c float type == F64
                        try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                        const jne_f4 = try buf.bne(TMP0, TMP1);

                        // 加载 f64 bits
                        try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                        try buf.fldD(FT1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));

                        switch (op) {
                            .add => try buf.faddD(FT0, FT0, FT1),
                            .sub => try buf.fsubD(FT0, FT0, FT1),
                            .mul => try buf.fmulD(FT0, FT0, FT1),
                            .div => try buf.fdivD(FT0, FT0, FT1),
                            else => unreachable,
                        }

                        // 存储 f64 结果
                        try buf.fstD(FT0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)));
                        try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                        try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                        try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                        try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)));

                        b_next2 = try buf.b();

                        // cold 目标
                        const cold_off = buf.len();
                        inline for (.{ jne_f1, jne_f2, jne_f3, jne_f4 }) |jne_pos| {
                            BridgeBuf.patchBcc(code.items, jne_pos, cold_off);
                        }
                    }

                    // ── cold: rt_step 桥接 ──
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    // ── .next ──
                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                    if (op != .mod) {
                        BridgeBuf.patchB(code.items, b_next2, next_off);
                    }
                    reg_types[a] = .unknown;
                }
            },

            // ── i64/f64 取反 ──
            .neg => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                try emitFrameBase2(&buf);

                if (b_known_i64) {
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    // sub.d t0, zero, t0 (negate)
                    try buf.subD(TMP0, GPR.zero, TMP0);
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));
                    reg_types[a] = .i64;
                } else if (b_known_f64) {
                    // ── f64 快速路径 ──
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.fnegD(FT0, FT0);
                    try buf.fstD(FT0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：tag 检查 ──
                    // 检查 tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const jne_cold = try buf.bne(TMP0, TMP1);

                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.subD(TMP0, GPR.zero, TMP0);

                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));

                    const b_next = try buf.b();

                    // not_int 目标：检查 f64
                    const not_int_target = buf.len();
                    BridgeBuf.patchBcc(code.items, jne_cold, not_int_target);

                    // 检查 b tag == TAG_FLOAT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    const jne_f1 = try buf.bne(TMP0, TMP1);

                    // 检查 b float type == F64
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    const jne_f2 = try buf.bne(TMP0, TMP1);

                    // f64 取反
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.fnegD(FT0, FT0);
                    try buf.fstD(FT0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)));

                    const b_next2 = try buf.b();

                    // cold 目标
                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, jne_f1, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f2, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                    BridgeBuf.patchB(code.items, b_next2, next_off);
                    reg_types[a] = .unknown;
                }
            },

            // ── i64/f64 比较 ──
            .eq, .neq, .lt, .gt, .le, .ge => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                if (b_known_i64 and c_known_i64) {
                    try emitFrameBase2(&buf);
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.ldD(TMP3, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    // slt/sltu 结果为 0/1
                    switch (op) {
                        .eq => {
                            // xor t0, t0, t3; sltu t0, zero, t0 → t0 = (t0 != 0) ? 1 : 0; xori t0, t0, 1
                            try buf.xorReg(TMP0, TMP0, TMP3);
                            try buf.sltu(TMP0, GPR.zero, TMP0);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                        .neq => {
                            try buf.xorReg(TMP0, TMP0, TMP3);
                            try buf.sltu(TMP0, GPR.zero, TMP0);
                        },
                        .lt => try buf.slt(TMP0, TMP0, TMP3),
                        .gt => try buf.slt(TMP0, TMP3, TMP0),
                        .le => {
                            try buf.slt(TMP0, TMP3, TMP0);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                        .ge => {
                            try buf.slt(TMP0, TMP0, TMP3);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                    }
                    // 存储布尔结果
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));
                    reg_types[a] = .boolean;
                } else if (b_known_f64 and c_known_f64) {
                    try emitFrameBase2(&buf);
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.fldD(FT1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    // 使用 FCC0 进行浮点比较
                    // eq/lt/gt/le/ge: 条件为真时 FCC0 != 0 → BCNEZ
                    // neq: 条件为真时 FCC0 == 0 → BCEQZ (用 CEQ 然后 BCEQZ 取反)
                    switch (op) {
                        .eq => try buf.fcmpCeqD(0, FT0, FT1),
                        .neq => try buf.fcmpCeqD(0, FT0, FT1),
                        .lt => try buf.fcmpCltD(0, FT0, FT1),
                        .gt => try buf.fcmpCltD(0, FT1, FT0),
                        .le => try buf.fcmpCleD(0, FT0, FT1),
                        .ge => try buf.fcmpCleD(0, FT1, FT0),
                    }
                    // 模式: addi.d t0, zero, 0; [BCNEZ|BCEQZ] cj=0, set_true; b done; set_true: addi.d t0, zero, 1; done:
                    try buf.addiD(TMP0, GPR.zero, 0);
                    const bz_pos = if (op == .neq) try buf.bceqz(0) else try buf.bcnez(0);
                    const b_done = try buf.b();
                    const set_true_off = buf.len();
                    BridgeBuf.patchBz(code.items, bz_pos, set_true_off);
                    try buf.addiD(TMP0, GPR.zero, 1);
                    const done_off = buf.len();
                    BridgeBuf.patchB(code.items, b_done, done_off);
                    // 存储布尔结果
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));
                    reg_types[a] = .boolean;
                } else {
                    // ── 未知类型：tag 检查 ──
                    try emitFrameBase2(&buf);

                    // 检查 b tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const jne_cold1 = try buf.bne(TMP0, TMP1);

                    // 检查 c tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)));
                    const jne_cold2 = try buf.bne(TMP0, TMP1);

                    // 加载 i64 值并比较
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.ldD(TMP3, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    switch (op) {
                        .eq => {
                            try buf.xorReg(TMP0, TMP0, TMP3);
                            try buf.sltu(TMP0, GPR.zero, TMP0);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                        .neq => {
                            try buf.xorReg(TMP0, TMP0, TMP3);
                            try buf.sltu(TMP0, GPR.zero, TMP0);
                        },
                        .lt => try buf.slt(TMP0, TMP0, TMP3),
                        .gt => try buf.slt(TMP0, TMP3, TMP0),
                        .le => {
                            try buf.slt(TMP0, TMP3, TMP0);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                        .ge => {
                            try buf.slt(TMP0, TMP0, TMP3);
                            try buf.xori(TMP0, TMP0, 1);
                        },
                    }
                    // 存储布尔结果
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                    const b_next = try buf.b();

                    // not_int 目标：检查 f64
                    const not_int_target = buf.len();
                    BridgeBuf.patchBcc(code.items, jne_cold1, not_int_target);
                    BridgeBuf.patchBcc(code.items, jne_cold2, not_int_target);

                    // 检查 b tag == TAG_FLOAT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    const jne_f1 = try buf.bne(TMP0, TMP1);

                    // 检查 c tag == TAG_FLOAT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)));
                    const jne_f2 = try buf.bne(TMP0, TMP1);

                    // 检查 b float type == F64
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    const jne_f3 = try buf.bne(TMP0, TMP1);

                    // 检查 c float type == F64
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    const jne_f4 = try buf.bne(TMP0, TMP1);

                    // 加载 f64 bits
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.fldD(FT1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));

                    // 浮点比较，结果写入 FCC0
                    switch (op) {
                        .eq => try buf.fcmpCeqD(0, FT0, FT1),
                        .neq => try buf.fcmpCeqD(0, FT0, FT1),
                        .lt => try buf.fcmpCltD(0, FT0, FT1),
                        .gt => try buf.fcmpCltD(0, FT1, FT0),
                        .le => try buf.fcmpCleD(0, FT0, FT1),
                        .ge => try buf.fcmpCleD(0, FT1, FT0),
                    }

                    // 将 FCC0 转换为 0/1 布尔值
                    try buf.addiD(TMP0, GPR.zero, 0);
                    const bz_pos = if (op == .neq) try buf.bceqz(0) else try buf.bcnez(0);
                    const b_done = try buf.b();
                    const set_true_off = buf.len();
                    BridgeBuf.patchBz(code.items, bz_pos, set_true_off);
                    try buf.addiD(TMP0, GPR.zero, 1);
                    const done_off = buf.len();
                    BridgeBuf.patchB(code.items, b_done, done_off);

                    // 存储布尔结果
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                    const b_next2 = try buf.b();

                    // cold 目标
                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, jne_f1, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f2, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f3, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f4, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                    BridgeBuf.patchB(code.items, b_next2, next_off);
                    reg_types[a] = .boolean;
                }
            },

            // ── 布尔取反 ──
            .not_op => {
                try emitFrameBase2(&buf);

                // 检查 tag == TAG_BOOLEAN
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                const jne_cold = try buf.bne(TMP0, TMP1);

                // 加载布尔值并取反: xori t0, t0, 1
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, PAYLOAD_OFF)));
                try buf.xori(TMP0, TMP0, 1);

                // 存储结果
                try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                const b_next = try buf.b();

                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, jne_cold, cold_off);
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);
            },

            // ── 无条件跳转 ──
            .jump => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                if (ip_to_code.get(target_ip)) |target_off| {
                    const b_pos = try buf.b();
                    BridgeBuf.patchB(code.items, b_pos, target_off);
                } else {
                    const b_pos = try buf.b();
                    try pending_fixups.append(allocator, .{
                        .code_offset = b_pos,
                        .target_ip = target_ip,
                        .kind = 1,
                    });
                }
            },

            // ── 条件跳转 ──
            .jump_if_false, .jump_if_true => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emitFrameBase2(&buf);

                // 检查 tag == TAG_BOOLEAN
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                const jne_cold = try buf.bne(TMP0, TMP1);

                // 加载布尔值
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                if (op == .jump_if_false) {
                    // jump_if_false: 如果值为 0 (false)，跳转到 target
                    // beq t0, zero, target
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const beq_pos = try buf.beq(TMP0, GPR.zero);
                        BridgeBuf.patchBcc(code.items, beq_pos, target_off);
                    } else {
                        const beq_pos = try buf.beq(TMP0, GPR.zero);
                        try pending_fixups.append(allocator, .{
                            .code_offset = beq_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                        });
                    }
                } else {
                    // jump_if_true: 如果值不为 0 (true)，跳转到 target
                    // bne t0, zero, target
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const bne_pos = try buf.bne(TMP0, GPR.zero);
                        BridgeBuf.patchBcc(code.items, bne_pos, target_off);
                    } else {
                        const bne_pos = try buf.bne(TMP0, GPR.zero);
                        try pending_fixups.append(allocator, .{
                            .code_offset = bne_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                        });
                    }
                }

                const b_next = try buf.b();

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, jne_cold, cold_off);
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);
                reg_types[a] = .boolean;
            },

            // ── null 检查跳转 ──
            .jump_if_null, .jump_if_not_null => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emitFrameBase2(&buf);

                // 加载 tag 字节
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));

                if (op == .jump_if_null) {
                    // TAG_NULL = 0
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const beq_pos = try buf.beq(TMP0, GPR.zero);
                        BridgeBuf.patchBcc(code.items, beq_pos, target_off);
                    } else {
                        const beq_pos = try buf.beq(TMP0, GPR.zero);
                        try pending_fixups.append(allocator, .{
                            .code_offset = beq_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                        });
                    }
                } else {
                    // jump_if_not_null
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const bne_pos = try buf.bne(TMP0, GPR.zero);
                        BridgeBuf.patchBcc(code.items, bne_pos, target_off);
                    } else {
                        const bne_pos = try buf.bne(TMP0, GPR.zero);
                        try pending_fixups.append(allocator, .{
                            .code_offset = bne_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                        });
                    }
                }
            },

            // ── return_op / return_unit ──
            .return_op, .return_unit => {
                // rt_step(vm, ip)
                try buf.moveReg(CARG0, BR_VM);
                try buf.loadImm64(CARG1, @intCast(ip));
                try buf.jirl(GPR.ra, BR_RT_STEP, 0);
                // rt_step 返回 true，跳到 exit
                const b_pos = try buf.b();
                try pending_fixups.append(allocator, .{
                    .code_offset = b_pos,
                    .target_ip = 0xFFFFFFFF,
                    .kind = 4,
                });
            },

            // ── load_const（标量快速路径）──
            .load_const => {
                try emitFrameBase2(&buf);

                // 加载常量池地址
                const const_addr: u64 = @intFromPtr(func.chunk.constants.items.ptr) + @as(u64, bx) * @sizeOf(value.Value);
                try buf.loadImm64(TMP3, const_addr);

                // 检查 dst(a) 是否标量：tag > MAX_SCALAR_TAG → cold
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                try buf.sltu(TMP4, TMP1, TMP0); // t4 = (MAX_SCALAR_TAG < tag) ? 1 : 0
                const bhi_cold1 = try buf.bne(TMP4, GPR.zero);

                // 检查 src(常量) 是否标量
                try buf.ldBu(TMP0, TMP3, @intCast(@as(i32, TAG_OFF)));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold2 = try buf.bne(TMP4, GPR.zero);

                // 快速路径：拷贝 32 字节
                inline for (0..4) |i| {
                    try buf.ldD(TMP0, TMP3, @intCast(i * 8));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)));
                }

                const b_next = try buf.b();

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, bhi_cold1, cold_off);
                BridgeBuf.patchBcc(code.items, bhi_cold2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);

                // 类型传播
                if (bx < func.chunk.constants.items.len) {
                    reg_types[a] = switch (func.chunk.constants.items[bx]) {
                        .int => .i64,
                        .float => .f64,
                        .boolean => .boolean,
                        else => .unknown,
                    };
                }
            },

            // ── move / assign ──
            .move, .assign => {
                try emitFrameBase2(&buf);

                // 检查 src(b) 是否标量
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                // sltu t4, t1, t0 → t4 = (MAX_SCALAR_TAG < tag) ? 1 : 0
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold1 = try buf.bne(TMP4, GPR.zero);

                // 检查 dst(a) 是否标量
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold2 = try buf.bne(TMP4, GPR.zero);

                // 快速路径：拷贝 32 字节
                inline for (0..4) |i| {
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, i * 8)));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)));
                }

                const b_next = try buf.b();

                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, bhi_cold1, cold_off);
                BridgeBuf.patchBcc(code.items, bhi_cold2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);

                if (b < reg_count) reg_types[a] = reg_types[b];
            },

            // ── load_unit / load_null ──
            .load_unit, .load_null => {
                try emitFrameBase2(&buf);

                // 检查 dst 是否标量
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold = try buf.bne(TMP4, GPR.zero);

                // 快速路径：设置 tag
                const tag_val: u8 = if (op == .load_unit) TAG_UNIT_VAL else TAG_NULL_VAL;
                try buf.addiD(TMP0, GPR.zero, @intCast(tag_val));
                try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));

                const b_next = try buf.b();

                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, bhi_cold, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);
            },

            // ── load_true / load_false ──
            .load_true, .load_false => {
                try emitFrameBase2(&buf);

                // 检查 dst 是否标量
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold = try buf.bne(TMP4, GPR.zero);

                // 快速路径：设置 tag=BOOLEAN, payload=0/1
                try buf.addiD(TMP0, GPR.zero, @intCast(TAG_BOOLEAN_VAL));
                try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                const payload_val: u8 = if (op == .load_true) 1 else 0;
                try buf.addiD(TMP0, GPR.zero, @intCast(payload_val));
                try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                const b_next = try buf.b();

                const cold_off = buf.len();
                BridgeBuf.patchBcc(code.items, bhi_cold, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);
                reg_types[a] = .boolean;
            },

            // ── call（通过 rt_call_inline）──
            .call => {
                const func_idx_val = bx;
                // rt_call_inline(vm, func_idx, args_base, argc, return_base, return_reg)
                try buf.moveReg(CARG0, BR_VM); // a0 = vm
                try buf.loadImm64(CARG1, @intCast(func_idx_val)); // a1 = func_idx
                // args_base = base + a + 1
                try buf.addiD(CARG2, BR_BASE, @intCast(@as(i16, @intCast(a)) + 1));
                // argc = callee.arity
                const callee_arity: u32 = if (func_idx_val < functions.len) functions[func_idx_val].arity else 0;
                try buf.loadImm64(CARG3, @intCast(callee_arity)); // a3 = argc
                // return_base = base
                try buf.moveReg(CARG4, BR_BASE); // a4 = return_base
                // return_reg = a
                try buf.addiD(CARG5, GPR.zero, @intCast(@as(u8, a))); // a5 = return_reg

                // jirl ra, s3, 0 (调用 rt_call_inline)
                try buf.jirl(GPR.ra, BR_RT_CALL, 0);

                // 检查返回值: bne a0, zero, exit
                const bne_pos = try buf.bne(TMP0, GPR.zero);
                try pending_fixups.append(allocator, .{
                    .code_offset = bne_pos,
                    .target_ip = 0xFFFFFFFF,
                    .kind = 2, // Bcc → exit
                });
                reg_types[a] = .unknown;
            },

            // ── index_op（数组索引快速路径）──
            .index_op => {
                try emitFrameBase2(&buf);

                // 检查 arr(b) tag == TAG_ARRAY
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(TAG_ARRAY_VAL));
                const bne_cold1 = try buf.bne(TMP0, TMP1);

                // 检查 idx(c) tag == TAG_INT
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                const bne_cold2 = try buf.bne(TMP0, TMP1);

                // 检查 dst(a) 是标量
                try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold3 = try buf.bne(TMP4, GPR.zero);

                // 加载 ArrayValue* from arr payload (offset 0)
                try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, PAYLOAD_OFF))); // TMP0 = arr pointer

                // 加载 elements.ptr (offset 0) → TMP3
                try buf.ldD(TMP3, TMP0, 0);
                // 加载 elements.len (offset 8) → TMP4
                try buf.ldD(TMP4, TMP0, 8);

                // 加载 index (Int.lo, offset 0) → a0(TMP0)
                try buf.ldD(TMP0, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));

                // 边界检查: index < len (unsigned): sltu t4, t0, t4; beq t4, zero, cold
                try buf.sltu(TMP4, TMP0, TMP4);
                const beq_cold4 = try buf.beq(TMP4, GPR.zero);

                // 计算元素地址: TMP3 = elements.ptr + index * 32
                // sll.d t0, t0, t4(shift=5)... 需要先设置移位量
                // 用 t4 = 5: addi.d t4, zero, 5; sll.d t0, t0, t4
                try buf.addiD(TMP4, GPR.zero, 5);
                try buf.sllD(TMP0, TMP0, TMP4);
                try buf.addD(TMP3, TMP3, TMP0); // TMP3 = elements.ptr + index * 32

                // 检查元素是否标量
                try buf.ldBu(TMP0, TMP3, @intCast(@as(i32, TAG_OFF)));
                try buf.addiD(TMP1, GPR.zero, @intCast(MAX_SCALAR_TAG));
                try buf.sltu(TMP4, TMP1, TMP0);
                const bhi_cold5 = try buf.bne(TMP4, GPR.zero);

                // 快速路径: 拷贝 32 字节
                inline for (0..4) |i| {
                    try buf.ldD(TMP0, TMP3, @intCast(i * 8));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)));
                }

                const b_next = try buf.b();

                const cold_off = buf.len();
                inline for (.{ bne_cold1, bne_cold2, bhi_cold3, beq_cold4, bhi_cold5 }) |jcc_pos| {
                    BridgeBuf.patchBcc(code.items, jcc_pos, cold_off);
                }
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                const next_off = buf.len();
                BridgeBuf.patchB(code.items, b_next, next_off);
            },

            // ── call_method ──
            .call_method, .call_method_ic => {
                const method_val = func.chunk.constants.items[b];
                const mname = method_val.string.bytes();

                if (std.mem.eql(u8, mname, "len") and c == 0) {
                    // arr.len() → rt_array_len(vm, recv_slot, dst_slot)
                    try buf.moveReg(CARG0, BR_VM); // vm
                    // recv_slot = base + a
                    try buf.addiD(CARG1, BR_BASE, @intCast(@as(u8, a)));
                    // dst_slot = base + a
                    try buf.addiD(CARG2, BR_BASE, @intCast(@as(u8, a)));

                    // jirl ra, s5, 0 (调用 rt_array_len)
                    try buf.jirl(GPR.ra, BR_RT_LEN, 0);

                    // 检查返回值: bne a0, zero, cold
                    const bne_cold = try buf.bne(TMP0, GPR.zero);

                    const b_next = try buf.b();

                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, bne_cold, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                } else if (std.mem.eql(u8, mname, "push") and c == 1) {
                    // arr.push(elem) → rt_array_push(vm, recv_slot, arg_slot, dst_slot)
                    try buf.moveReg(CARG0, BR_VM); // vm
                    // recv_slot = base + a
                    try buf.addiD(CARG1, BR_BASE, @intCast(@as(u8, a)));
                    // arg_slot = base + a + 1
                    try buf.addiD(CARG2, BR_BASE, @intCast(@as(u16, a) + 1));
                    // dst_slot = base + a
                    try buf.addiD(CARG3, BR_BASE, @intCast(@as(u8, a)));

                    // jirl ra, s4, 0 (调用 rt_array_push)
                    try buf.jirl(GPR.ra, BR_RT_PUSH, 0);

                    // 检查返回值
                    const bne_cold = try buf.bne(TMP0, GPR.zero);

                    const b_next = try buf.b();

                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, bne_cold, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                } else {
                    // 其他方法 → rt_step 桥接
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);
                }
            },

            // ── cast / coerce ──
            .cast, .coerce => {
                const type_val = func.chunk.constants.items[c];
                const tname = type_val.string.bytes();

                const int_target: ?value.IntType = blk: {
                    if (std.mem.eql(u8, tname, "i8")) break :blk .i8;
                    if (std.mem.eql(u8, tname, "i16")) break :blk .i16;
                    if (std.mem.eql(u8, tname, "i32")) break :blk .i32;
                    if (std.mem.eql(u8, tname, "i64")) break :blk .i64;
                    if (std.mem.eql(u8, tname, "u8")) break :blk .u8;
                    if (std.mem.eql(u8, tname, "u16")) break :blk .u16;
                    if (std.mem.eql(u8, tname, "u32")) break :blk .u32;
                    if (std.mem.eql(u8, tname, "u64")) break :blk .u64;
                    break :blk null;
                };
                const float_target: ?value.FloatType = blk: {
                    if (std.mem.eql(u8, tname, "f32")) break :blk .f32;
                    if (std.mem.eql(u8, tname, "f64")) break :blk .f64;
                    break :blk null;
                };

                if (int_target == null and float_target == null) {
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);
                    continue;
                }

                try emitFrameBase2(&buf);

                if (int_target) |it| {
                    // 目标是整数类型
                    // 检查 src(b) tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const bne_cold1 = try buf.bne(TMP0, TMP1);

                    // 检查 dst(a) tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    const bne_cold2 = try buf.bne(TMP0, TMP1);

                    // 快速路径：拷贝 lo/hi，设置 int type
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + 8)); // hi
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + 8));
                    const type_byte: u8 = @intCast(@intFromEnum(it));
                    try buf.addiD(TMP0, GPR.zero, @intCast(type_byte));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));

                    const b_next = try buf.b();

                    // not_int 目标：检查 f64→int 路径
                    const not_int_target = buf.len();
                    BridgeBuf.patchBcc(code.items, bne_cold1, not_int_target);
                    BridgeBuf.patchBcc(code.items, bne_cold2, not_int_target);

                    // 检查 src(b) tag == TAG_FLOAT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    const jne_f1 = try buf.bne(TMP0, TMP1);

                    // 检查 src(b) float type == F64
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    const jne_f2 = try buf.bne(TMP0, TMP1);

                    // 检查 dst(a) tag == TAG_INT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const jne_f3 = try buf.bne(TMP0, TMP1);

                    // f64 → int32 截断（FTINTRZ.W.D）
                    try buf.fldD(FT0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.ftintrzWD(FT0, FT0); // double → int32，向零取整
                    try buf.movfr2grD(TMP0, FT0); // FPR → GPR

                    // 符号扩展 32→64 位
                    try buf.addiD(TMP3, GPR.zero, 32);
                    try buf.sllD(TMP0, TMP0, TMP3);
                    try buf.sraD(TMP0, TMP0, TMP3);

                    // 存储到 dst(a) 的 INT_LO_OFF
                    try buf.stD(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)));
                    // 存储 hi（符号扩展，用于 i128 兼容）
                    try buf.addiD(TMP3, GPR.zero, 63);
                    try buf.sraD(TMP3, TMP0, TMP3);
                    try buf.stD(TMP3, TMP2, @intCast(@as(i32, a) * 32 + 8));

                    // 设置 tag = TAG_INT, int type = I64
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    try buf.stB(TMP1, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)));

                    const b_next2 = try buf.b();

                    // cold 目标
                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, jne_f1, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f2, cold_off);
                    BridgeBuf.patchBcc(code.items, jne_f3, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                    BridgeBuf.patchB(code.items, b_next2, next_off);
                } else if (float_target) |ft| {
                    // 目标是浮点类型
                    // 检查 src(b) tag == TAG_INT（int→float）
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_INT_VAL));
                    const bne_cold1 = try buf.bne(TMP0, TMP1);

                    // 检查 src(b) int type == i64
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_TYPE_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(INT_TYPE_I64_VAL));
                    const bne_cold2 = try buf.bne(TMP0, TMP1);

                    // 检查 dst(a) tag == TAG_FLOAT
                    try buf.ldBu(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    try buf.addiD(TMP1, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    const bne_cold3 = try buf.bne(TMP0, TMP1);

                    if (ft != .f64) {
                        try emitRtStepCall(&buf, ip, &pending_fixups, allocator);
                        continue;
                    }

                    // 加载 i64 → ffint.d.l ft0, t0
                    try buf.ldD(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.movgr2frD(FT0, TMP0);
                    try buf.ffintDL(FT0, FT0); // int64 → double
                    // 存储 f64 bits 到 dst(a)
                    try buf.fstD(FT0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    // 设置 tag = FLOAT
                    try buf.addiD(TMP0, GPR.zero, @intCast(TAG_FLOAT_VAL));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));
                    // 设置 float type = F64
                    try buf.addiD(TMP0, GPR.zero, @intCast(FLOAT_TYPE_F64_VAL));
                    try buf.stB(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)));

                    const b_next = try buf.b();

                    const cold_off = buf.len();
                    BridgeBuf.patchBcc(code.items, bne_cold1, cold_off);
                    BridgeBuf.patchBcc(code.items, bne_cold2, cold_off);
                    BridgeBuf.patchBcc(code.items, bne_cold3, cold_off);
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator);

                    const next_off = buf.len();
                    BridgeBuf.patchB(code.items, b_next, next_off);
                }
                reg_types[a] = if (int_target != null) .i64 else if (float_target != null) .f64 else .unknown;
            },

            // ── 所有其他 opcode：rt_step 桥接 ──
            else => {
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator);
            },
        }
    }

    // ════════ 函数 epilogue (= exit 标签) ════════
    exit_offset = buf.len();

    // ld.d ra, sp, 0
    try buf.ldD(GPR.ra, GPR.sp, 0);
    // ld.d fp, sp, 8
    try buf.ldD(GPR.fp, GPR.sp, 8);
    // ld.d s0, sp, 16
    try buf.ldD(GPR.s0, GPR.sp, 16);
    // ld.d s1, sp, 24
    try buf.ldD(GPR.s1, GPR.sp, 24);
    // ld.d s2, sp, 32
    try buf.ldD(GPR.s2, GPR.sp, 32);
    // ld.d s3, sp, 40
    try buf.ldD(GPR.s3, GPR.sp, 40);
    // ld.d s4, sp, 48
    try buf.ldD(GPR.s4, GPR.sp, 48);
    // ld.d s5, sp, 56
    try buf.ldD(GPR.s5, GPR.sp, 56);
    // addi.d sp, sp, STACK_SPACE
    try buf.addiD(GPR.sp, GPR.sp, @intCast(STACK_SPACE));
    // jirl zero, ra, 0 (返回)
    try buf.jirl(GPR.zero, GPR.ra, 0);

    // ════════ 回填跳转目标 ════════
    for (pending_fixups.items) |fixup| {
        if (fixup.kind == 4) {
            // exit 跳转 (B-type)
            BridgeBuf.patchB(code.items, fixup.code_offset, exit_offset);
        } else if (fixup.kind == 2) {
            // exit 跳转 (Bcc-type, target_ip == 0xFFFFFFFF)
            if (fixup.target_ip == 0xFFFFFFFF) {
                BridgeBuf.patchBcc(code.items, fixup.code_offset, exit_offset);
            } else {
                const target_off = ip_to_code.get(fixup.target_ip) orelse {
                    return error.JitMissingJumpTarget;
                };
                BridgeBuf.patchBcc(code.items, fixup.code_offset, target_off);
            }
        } else if (fixup.kind == 1) {
            // B-type 跳转
            const target_off = ip_to_code.get(fixup.target_ip) orelse {
                return error.JitMissingJumpTarget;
            };
            BridgeBuf.patchB(code.items, fixup.code_offset, target_off);
        }
    }

    // ════════ 写入可执行内存 ════════
    const code_bytes = code.items.len;
    const dst = exec_mem.alloc(code_bytes) orelse return error.JitOutOfExecMemory;
    @memcpy(dst[0..code_bytes], code.items);
    return @intFromPtr(dst);
}

// ════════════════════════════════════════════════════════════════════
// JitBackend 接口实现
// ════════════════════════════════════════════════════════════════════

/// LoongArch64 JitBackend 实例（桥接模式）。
pub const backend_instance: backend_mod.JitBackend = .{
    .compileFn = compileBridgeFn,
    .is_bridge = true,
};

/// JitBackend.compileFn 实现：桥接模式编译入口。
fn compileBridgeFn(
    engine_ctx: *anyopaque,
    func_idx: u32,
    func_opaque: *const anyopaque,
) ?*const anyopaque {
    const jit_mod = @import("../mod.zig");
    const JitEngine = jit_mod.JitEngine;
    const engine: *JitEngine = @ptrCast(@alignCast(engine_ctx));
    const func: *const reg_chunk.RegFunction = @ptrCast(@alignCast(func_opaque));

    // 跳过包含闭包/upvalue 的函数
    if (@import("mod.zig").containsClosureOps(func)) {
        engine.failed[func_idx] = true;
        return null;
    }

    // 预分配可执行内存（32KB）
    var exec_mem = mem.allocExec(32 * 1024) catch {
        engine.failed[func_idx] = true;
        return null;
    };
    errdefer exec_mem.deinit();

    // 获取 C-ABI 桥接函数地址
    const rt_step_addr = @intFromPtr(&runtime.bridge.rt_step);
    const rt_call_inline_addr = @intFromPtr(&runtime.bridge.rt_call_inline);
    const rt_array_push_addr = @intFromPtr(&runtime.bridge.rt_array_push);
    const rt_array_len_addr = @intFromPtr(&runtime.bridge.rt_array_len);

    // 直接从字节码编译为 LoongArch64 机器码
    const entry = compileBridge(
        engine.allocator,
        func,
        func_idx,
        &exec_mem,
        rt_step_addr,
        rt_call_inline_addr,
        rt_array_push_addr,
        rt_array_len_addr,
        engine.functions,
    ) catch {
        exec_mem.deinit();
        engine.failed[func_idx] = true;
        return null;
    };

    exec_mem.finalize();

    engine.compiled[func_idx] = jit_mod.CompiledFn{
        .entry = entry,
        .arity = func.arity,
        .return_type = 0xFF, // bridge 模式标记
        .exec_mem = exec_mem,
        .bridge = true,
    };

    return @ptrCast(&engine.compiled[func_idx].?);
}

// ════════════════════════════════════════════════════════════════════
// IR 模式代码生成器
// ════════════════════════════════════════════════════════════════════

/// 浮点指令编码辅助函数（IR 模式专用，直接使用 hex 值避免常量歧义）。
/// LoongArch 浮点指令格式：
///   3R-type: opcode[31:15] | fk[14:10] | fj[9:5] | fd[4:0]
///   2R-type: opcode[31:10] | fj[9:5] | fd[4:0]

/// fadd.d fd, fj, fk
fn cgFaddD(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01010000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fsub.d fd, fj, fk
fn cgFsubD(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01030000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fmul.d fd, fj, fk
fn cgFmulD(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01050000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fdiv.d fd, fj, fk
fn cgFdivD(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01070000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fadd.s fd, fj, fk
fn cgFaddS(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01100000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fsub.s fd, fj, fk
fn cgFsubS(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01120000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fmul.s fd, fj, fk
fn cgFmulS(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01140000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}
/// fdiv.s fd, fj, fk
fn cgFdivS(fd: u8, fj: u8, fk: u8) u32 {
    return 0x01160000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | fd;
}

/// fcmp.ceq.d cc, fj, fk (结果写入 FCC[cc])
fn cgFcmpCeqD(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C220000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}
/// fcmp.clt.d cc, fj, fk
fn cgFcmpCltD(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C210000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}
/// fcmp.cle.d cc, fj, fk
fn cgFcmpCleD(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C230000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}
/// fcmp.ceq.s cc, fj, fk
fn cgFcmpCeqS(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C120000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}
/// fcmp.clt.s cc, fj, fk
fn cgFcmpCltS(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C110000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}
/// fcmp.cle.s cc, fj, fk
fn cgFcmpCleS(cc: u8, fj: u8, fk: u8) u32 {
    return 0x0C130000 | (@as(u32, fk) << 10) | (@as(u32, fj) << 5) | (cc & 7);
}

/// fmov.d fd, fj
fn cgFmovD(fd: u8, fj: u8) u32 {
    return 0x01149800 | (@as(u32, fj) << 5) | fd;
}
/// fneg.d fd, fj
fn cgFnegD(fd: u8, fj: u8) u32 {
    return 0x01141800 | (@as(u32, fj) << 5) | fd;
}
/// fmov.s fd, fj
fn cgFmovS(fd: u8, fj: u8) u32 {
    return 0x01149000 | (@as(u32, fj) << 5) | fd;
}
/// fneg.s fd, fj
fn cgFnegS(fd: u8, fj: u8) u32 {
    return 0x01141000 | (@as(u32, fj) << 5) | fd;
}
/// movgr2fr.d fd, rj (GPR → FPR)
fn cgMovgr2frD(fd: u8, rj: u8) u32 {
    return 0x0114A800 | (@as(u32, rj) << 5) | fd;
}
/// movfr2gr.d rd, fj (FPR → GPR)
fn cgMovfr2grD(rd: u8, fj: u8) u32 {
    return 0x0114B800 | (@as(u32, fj) << 5) | rd;
}
/// ffint.d.l fd, fj (int64 → double)
fn cgFfintDL(fd: u8, fj: u8) u32 {
    return 0x011D2800 | (@as(u32, fj) << 5) | fd;
}
/// ftintrz.l.d fd, fj (double → int64, trunc)
fn cgFtintrzLD(fd: u8, fj: u8) u32 {
    return 0x011B8800 | (@as(u32, fj) << 5) | fd;
}
/// fcvt.s.d fd, fj (double → float)
fn cgFcvtSD(fd: u8, fj: u8) u32 {
    return 0x01198000 | (@as(u32, fj) << 5) | fd;
}
/// fcvt.d.s fd, fj (float → double)
fn cgFcvtDS(fd: u8, fj: u8) u32 {
    return 0x01190000 | (@as(u32, fj) << 5) | fd;
}
/// ffint.s.l fd, fj (int64 → float)
fn cgFfintSL(fd: u8, fj: u8) u32 {
    return 0x011D6800 | (@as(u32, fj) << 5) | fd;
}
/// ftintrz.l.s fd, fj (float → int64, trunc)
fn cgFtintrzLS(fd: u8, fj: u8) u32 {
    return 0x011B9800 | (@as(u32, fj) << 5) | fd;
}
/// fld.d fd, rj, imm12 (load double)
fn cgFldD(fd: u8, rj: u8, imm12: i16) u32 {
    return enc2RI12(OPF2RI12.FLD_D, fd, rj, imm12);
}
/// fst.d fd, rj, imm12 (store double)
fn cgFstD(fd: u8, rj: u8, imm12: i16) u32 {
    return enc2RI12(OPF2RI12.FST_D, fd, rj, imm12);
}

/// bceqz cj, offs21 (FCC[cj]==0 时跳转)
fn cgBceqz(cj: u8) u32 {
    return @as(u32, 0b010010) << 26 | (@as(u32, cj & 7) << 5);
}
/// bcnez cj, offs21 (FCC[cj]!=0 时跳转)
fn cgBcnez(cj: u8) u32 {
    return @as(u32, 0b010010) << 26 | (@as(u32, 0b01) << 8) | (@as(u32, cj & 7) << 5);
}

/// IR 模式代码生成器状态。
const Codegen = struct {
    /// 机器码缓冲区（u32 数组，LoongArch 每条指令 4 字节）。
    code: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,
    /// 寄存器分配结果。
    alloc: *const regalloc.Allocation,
    /// 标签 → 代码偏移映射（以指令索引计）。
    label_offsets: std.AutoHashMap(u32, u32),
    /// 待修复的跳转指令（需要回填目标地址）。
    pending_fixups: std.ArrayListUnmanaged(Fixup) = .empty,

    const Fixup = struct {
        /// 需要修复的代码索引（code 数组中的位置）。
        code_idx: u32,
        /// 目标标签 ID。
        target_label: u32,
        /// 跳转指令类型（1=B/I26, 2=Bcc/2RI16, 3=Bz/1RI21, 4=Bceqz/BCnez/1RI21）。
        fixup_kind: u8,
    };

    fn init(allocator: std.mem.Allocator, alloc: *const regalloc.Allocation) Codegen {
        return .{
            .allocator = allocator,
            .alloc = alloc,
            .label_offsets = std.AutoHashMap(u32, u32).init(allocator),
            .pending_fixups = .empty,
        };
    }

    fn deinit(self: *Codegen) void {
        self.code.deinit(self.allocator);
        self.label_offsets.deinit();
        self.pending_fixups.deinit(self.allocator);
    }

    /// 追加一条 LoongArch 指令。
    fn emit(self: *Codegen, enc: u32) !void {
        try self.code.append(self.allocator, enc);
    }

    /// 当前代码偏移（以指令数计）。
    fn currentOffset(self: *const Codegen) u32 {
        return @intCast(self.code.items.len);
    }

    /// 解析虚拟寄存器到物理寄存器编号。
    fn resolveReg(self: *const Codegen, vr: ir.VReg) u8 {
        if (self.alloc.vreg_to_phys.get(vr.id)) |preg| {
            return preg.id;
        }
        @panic("JIT register spill not supported in prototype");
    }
};

/// 加载 64 位立即数到寄存器（IR 模式）。
/// 使用 lu12i.w + lu32i.d + lu52i.d 三条指令。
fn loadImm64Cg(cg: *Codegen, rd: u8, val: u64) !void {
    const lo20: i32 = @intCast((val >> 12) & 0xFFFFF);
    const mid20: i32 = @intCast((val >> 32) & 0xFFFFF);
    const hi12: i16 = @intCast((val >> 52) & 0xFFF);
    const lo20_signed: i32 = if (lo20 & 0x80000 != 0) lo20 - 0x100000 else lo20;
    const mid20_signed: i32 = if (mid20 & 0x80000 != 0) mid20 - 0x100000 else mid20;
    try cg.emit(enc1RI20(OP1RI20.LU12I_W, rd, lo20_signed));
    try cg.emit(enc1RI20(OP1RI20.LU32I_D, rd, mid20_signed));
    try cg.emit(enc2RI12(OP2RI12.LU52I_D, rd, rd, hi12));
}

/// 回填 B/BL 跳转目标（I26-type）。
fn patchI26(code_item: *u32, jump_idx: u32, target_idx: u32) void {
    const diff: i64 = @as(i64, target_idx) - @as(i64, jump_idx);
    const off26: i32 = @intCast(diff);
    const uimm: u32 = @as(u32, @bitCast(off26)) & 0x3FFFFFF;
    code_item.* = (code_item.* & ~((0xFFFF << 10) | 0x3FF)) | ((uimm & 0xFFFF) << 10) | ((uimm >> 16) & 0x3FF);
}

/// 回填 BEQ/BNE/BLT/BGE/BLTU/BGEU 跳转目标（2RI16-type）。
fn patchBcc(code_item: *u32, jump_idx: u32, target_idx: u32) void {
    const diff: i64 = @as(i64, target_idx) - @as(i64, jump_idx);
    const off16: i32 = @intCast(diff);
    const uimm: u32 = @as(u32, @bitCast(off16)) & 0xFFFF;
    code_item.* = (code_item.* & ~(0xFFFF << 10)) | (uimm << 10);
}

/// 回填 BEQZ/BNEZ/BCEQZ/BCNEZ 跳转目标（1RI21-type）。
fn patchBz(code_item: *u32, jump_idx: u32, target_idx: u32) void {
    const diff: i64 = @as(i64, target_idx) - @as(i64, jump_idx);
    const off21: i32 = @intCast(diff);
    const uimm: u32 = @as(u32, @bitCast(off21)) & 0x1FFFFF;
    code_item.* = (code_item.* & ~((0xFFFF << 10) | 0x1F)) | ((uimm & 0xFFFF) << 10) | ((uimm >> 16) & 0x1F);
}

/// 编译 IR 函数为 LoongArch64 机器码。
pub fn compile(
    allocator: std.mem.Allocator,
    func: *const ir.IRFunction,
    exec_mem: *mem.ExecMemory,
    func_entries: []const usize,
) !usize {
    // 寄存器分配（GPR + FPR 类型感知）
    var alloc_result = try regalloc.allocate(allocator, func, &AVAIL_GPRS, &AVAIL_FPRS);
    defer alloc_result.deinit();

    var cg = Codegen.init(allocator, &alloc_result);
    defer cg.deinit();

    // ════════ 函数 prologue ════════
    // 保存 ra 和 fp，建立 16 字节栈帧
    // addi.d sp, sp, -16
    try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.sp, GPR.sp, -16));
    // st.d ra, sp, 8
    try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.ra, GPR.sp, 8));
    // st.d fp, sp, 0
    try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.fp, GPR.sp, 0));
    // addi.d fp, sp, 16
    try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.fp, GPR.sp, 16));

    // ════════ 函数体 ════════
    for (func.insts.items) |inst| {
        switch (inst.op) {
            .label => {
                try cg.label_offsets.put(inst.label, cg.currentOffset());
            },

            .const_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const uval: u64 = @bitCast(inst.imm);
                try loadImm64Cg(&cg, rd, uval);
            },

            .const_f64 => {
                // 加载 imm64 到 GPR t0，再用 movgr2fr.d 移到 FPR
                const rd = cg.resolveReg(inst.dst); // FPR
                const uval: u64 = @bitCast(inst.imm);
                try loadImm64Cg(&cg, GPR.t0, uval);
                try cg.emit(cgMovgr2frD(rd, GPR.t0));
            },

            .const_f32 => {
                // 加载 imm32 到 GPR t0（高位补0），再用 movgr2fr.d 移到 FPR
                const rd = cg.resolveReg(inst.dst); // FPR
                const uval: u64 = @bitCast(inst.imm);
                try loadImm64Cg(&cg, GPR.t0, uval);
                try cg.emit(cgMovgr2frD(rd, GPR.t0));
            },

            .const_bool => {
                const rd = cg.resolveReg(inst.dst);
                if (inst.imm != 0) {
                    // addi.d rd, zero, 1
                    try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                } else {
                    // addi.d rd, zero, 0
                    try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                }
            },

            // ── i64 算术 ──
            .add_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.ADD_D, rd, rj, rk));
            },
            .sub_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SUB_D, rd, rj, rk));
            },
            .mul_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.MUL_D, rd, rj, rk));
            },
            .div_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.DIV_D, rd, rj, rk));
            },
            .rem_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.MOD_D, rd, rj, rk));
            },
            .neg_i64 => {
                // neg rd, rs = sub.d rd, zero, rs
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(enc3R(OP3R.SUB_D, rd, GPR.zero, rs1));
            },

            // ── i64 位运算 ──
            .and_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.AND, rd, rj, rk));
            },
            .or_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.OR, rd, rj, rk));
            },
            .xor_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.XOR, rd, rj, rk));
            },
            .not_i64 => {
                // not rd, rs = nor rd, rs, zero
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(enc3R(OP3R.NOR, rd, rs1, GPR.zero));
            },

            // ── i64 比较 → bool（结果为 0/1）──
            .eq_i64 => {
                // slt t0, zero, sub(rd=rj-rk); 但 LoongArch 没有 sub 后自动设置条件
                // 用: sub.d t0, rj, rk; sltui rd, t0, 1 (rd = t0 < 1 ? 1:0 = t0==0 ? 1:0)
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SUB_D, GPR.t0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.SLTUI, rd, GPR.t0, 1));
            },
            .neq_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SUB_D, GPR.t0, rj, rk));
                // sltu rd, zero, t0 (rd = 0 < t0 ? 1:0 = t0 != 0 ? 1:0)
                try cg.emit(enc3R(OP3R.SLTU, rd, GPR.zero, GPR.t0));
            },
            .lt_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SLT, rd, rj, rk));
            },
            .gt_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SLT, rd, rk, rj));
            },
            .le_i64 => {
                // le = !(a > b) = !(b < a): slt rd, rk, rj; xori rd, rd, 1
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SLT, rd, rk, rj));
                try cg.emit(enc2RI12(OP2RI12.XORI, rd, rd, 1));
            },
            .ge_i64 => {
                // ge = !(a < b): slt rd, rj, rk; xori rd, rd, 1
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(enc3R(OP3R.SLT, rd, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.XORI, rd, rd, 1));
            },

            // ── 布尔逻辑 ──
            .bool_not => {
                // rd = rs ^ 1
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(enc2RI12(OP2RI12.XORI, rd, rs1, 1));
            },

            // ── 数据移动 ──
            .move => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                if (rd != rs1) {
                    if (inst.dst.type.isFloat()) {
                        if (inst.dst.type == .f32) {
                            try cg.emit(cgFmovS(rd, rs1));
                        } else {
                            try cg.emit(cgFmovD(rd, rs1));
                        }
                    } else {
                        // move rd, rs = or rd, rs, zero
                        try cg.emit(enc3R(OP3R.OR, rd, rs1, GPR.zero));
                    }
                }
            },

            // ── 类型转换 ──
            .i32_to_i64 => {
                // 符号扩展：slli.d rd, rs, 32; sra.d rd, rd, 32
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                // 加载 32 到 t0
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.t0, GPR.zero, 32));
                try cg.emit(enc3R(OP3R.SLL_D, rd, rs1, GPR.t0));
                try cg.emit(enc3R(OP3R.SRA_D, rd, rd, GPR.t0));
            },
            .i64_to_f64 => {
                // ffint.d.l fd, rj (int64 → double)
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // GPR
                try cg.emit(cgFfintDL(rd, rs1));
            },
            .f64_to_i64 => {
                // ftintrz.l.d fd, fj (double → int64 trunc); movfr2gr.d rd, fd
                const rd = cg.resolveReg(inst.dst); // GPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                // ftintrz.l.d 结果在 FPR，需要 movfr2gr.d 移到 GPR
                try cg.emit(cgFtintrzLD(FPR.ft0, rs1));
                try cg.emit(cgMovfr2grD(rd, FPR.ft0));
            },
            .i64_to_f32 => {
                // ffint.d.l + fcvt.s.d
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // GPR
                try cg.emit(cgFfintDL(FPR.ft0, rs1));
                try cg.emit(cgFcvtSD(rd, FPR.ft0));
            },
            .f32_to_i64 => {
                // fcvt.d.s + ftintrz.l.d + movfr2gr.d
                const rd = cg.resolveReg(inst.dst); // GPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(cgFcvtDS(FPR.ft0, rs1));
                try cg.emit(cgFtintrzLD(FPR.ft0, FPR.ft0));
                try cg.emit(cgMovfr2grD(rd, FPR.ft0));
            },
            .f32_to_f64 => {
                // fcvt.d.s fd, fj
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(cgFcvtDS(rd, rs1));
            },
            .f64_to_f32 => {
                // fcvt.s.d fd, fj
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(cgFcvtSD(rd, rs1));
            },

            // ── 控制流 ──
            .jump => {
                // b offs26 → 待回填
                const fixup_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_idx,
                    .target_label = inst.label,
                    .fixup_kind = 1, // I26
                });
            },
            .branch => {
                // branch cond, true_label, false_label
                // cond 为布尔值(0/1)，非零跳转到 true_label，否则跳转到 false_label
                const cond_reg = cg.resolveReg(inst.a.vreg);
                const false_label: u32 = @truncate(@as(u64, @bitCast(inst.imm)));

                // bne cond, zero, true_label (待回填)
                const fixup_true = cg.currentOffset();
                // bne rj=cond, rd=zero, offs16
                try cg.emit((@as(u32, OPBR.BNE) << 26) | (@as(u32, cond_reg) << 5) | GPR.zero);
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_true,
                    .target_label = inst.label, // true_label
                    .fixup_kind = 2, // Bcc
                });

                // b false_label (待回填)
                const fixup_false = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_false,
                    .target_label = false_label,
                    .fixup_kind = 1, // I26
                });
            },

            // ── 函数参数加载 ──
            .load_arg => {
                // 整数参数在 a0-a7(r4-r11)，浮点参数在 fa0-fa7(f0-f7)
                const arg_idx: u8 = @intCast(inst.imm);
                const rd = cg.resolveReg(inst.dst);
                const arg_ty = func.arg_types[arg_idx];
                if (arg_ty.isFloat()) {
                    const arg_reg: u8 = FPR.fa0 + arg_idx;
                    if (rd != arg_reg) {
                        if (arg_ty == .f32) {
                            try cg.emit(cgFmovS(rd, arg_reg));
                        } else {
                            try cg.emit(cgFmovD(rd, arg_reg));
                        }
                    }
                } else {
                    const arg_reg: u8 = GPR.a0 + arg_idx;
                    if (rd != arg_reg) {
                        // move rd, arg = or rd, arg, zero
                        try cg.emit(enc3R(OP3R.OR, rd, arg_reg, GPR.zero));
                    }
                }
            },

            // ── 函数返回 ──
            .return_val => {
                // 整数返回值在 a0(r4)，浮点返回值在 fa0(f0)
                const rn = cg.resolveReg(inst.a.vreg);
                if (inst.a.vreg.type.isFloat()) {
                    if (rn != FPR.fa0) {
                        if (inst.a.vreg.type == .f32) {
                            try cg.emit(cgFmovS(FPR.fa0, rn));
                        } else {
                            try cg.emit(cgFmovD(FPR.fa0, rn));
                        }
                    }
                } else {
                    if (rn != GPR.a0) {
                        try cg.emit(enc3R(OP3R.OR, GPR.a0, rn, GPR.zero));
                    }
                }
                // 函数 epilogue
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.ra, GPR.sp, 8));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.fp, GPR.sp, 0));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.sp, GPR.sp, 16));
                // jirl r0, ra, 0 (return)
                try cg.emit(enc2RI16(OPBR.JIRL, GPR.zero, GPR.ra, 0));
            },
            .return_void => {
                // 函数 epilogue
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.ra, GPR.sp, 8));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.fp, GPR.sp, 0));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.sp, GPR.sp, 16));
                try cg.emit(enc2RI16(OPBR.JIRL, GPR.zero, GPR.ra, 0));
            },

            // ── 函数调用 ──
            .call => {
                // JIT 内函数调用：JIT 不遵循标准 ABI，callee 不保存 callee-saved 寄存器，
                // 因此 caller 必须保存所有 JIT 使用的寄存器。
                // AVAIL_GPRS: t0-t8(9) + s0-s8(9) = 18 个 GPR
                // AVAIL_FPRS: ft0-ft15(16) = 16 个 FPR
                // 共 34 个寄存器 × 8 字节 = 272 字节，16 字节对齐 = 288 字节
                const target_idx = inst.call_target;
                if (target_idx >= func_entries.len or func_entries[target_idx] == 0) {
                    return error.JitCallTargetNotCompiled;
                }
                const entry_addr = func_entries[target_idx];

                // 保存 t0-t8, s0-s8, ft0-ft15 (34 个寄存器 = 272 字节, 对齐到 288)
                // 栈布局: sp+0..sp+71 = t0-t8(9), sp+72..sp+143 = s0-s8(9),
                //         sp+144..sp+271 = ft0-ft15(16), sp+272..sp+287 = padding
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.sp, GPR.sp, -288));
                // 保存 t0-t8 (r12-r20)
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t0, GPR.sp, 0));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t1, GPR.sp, 8));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t2, GPR.sp, 16));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t3, GPR.sp, 24));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t4, GPR.sp, 32));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t5, GPR.sp, 40));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t6, GPR.sp, 48));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t7, GPR.sp, 56));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.t8, GPR.sp, 64));
                // 保存 s0-s8 (r23-r31)
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s0, GPR.sp, 72));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s1, GPR.sp, 80));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s2, GPR.sp, 88));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s3, GPR.sp, 96));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s4, GPR.sp, 104));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s5, GPR.sp, 112));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s6, GPR.sp, 120));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s7, GPR.sp, 128));
                try cg.emit(enc2RI12(OP2RI12.ST_D, GPR.s8, GPR.sp, 136));
                // 保存 ft0-ft15 (f8-f23)
                try cg.emit(cgFstD(FPR.ft0, GPR.sp, 144));
                try cg.emit(cgFstD(FPR.ft1, GPR.sp, 152));
                try cg.emit(cgFstD(FPR.ft2, GPR.sp, 160));
                try cg.emit(cgFstD(FPR.ft3, GPR.sp, 168));
                try cg.emit(cgFstD(FPR.ft4, GPR.sp, 176));
                try cg.emit(cgFstD(FPR.ft5, GPR.sp, 184));
                try cg.emit(cgFstD(FPR.ft6, GPR.sp, 192));
                try cg.emit(cgFstD(FPR.ft7, GPR.sp, 200));
                try cg.emit(cgFstD(FPR.ft8, GPR.sp, 208));
                try cg.emit(cgFstD(FPR.ft9, GPR.sp, 216));
                try cg.emit(cgFstD(FPR.ft10, GPR.sp, 224));
                try cg.emit(cgFstD(FPR.ft11, GPR.sp, 232));
                try cg.emit(cgFstD(FPR.ft12, GPR.sp, 240));
                try cg.emit(cgFstD(FPR.ft13, GPR.sp, 248));
                try cg.emit(cgFstD(FPR.ft14, GPR.sp, 256));
                try cg.emit(cgFstD(FPR.ft15, GPR.sp, 264));

                // 移动参数到 a0-a7（整数）/ fa0-fa7（浮点）
                const argc = inst.call_argc;
                if (argc > 8) return error.JitTooManyArgs;
                var i: u8 = 0;
                while (i < argc) : (i += 1) {
                    const arg_vreg = inst.call_args[i];
                    const arg_reg = cg.resolveReg(arg_vreg);
                    if (arg_vreg.type.isFloat()) {
                        const target_reg: u8 = FPR.fa0 + i;
                        if (arg_reg != target_reg) {
                            if (arg_vreg.type == .f32) {
                                try cg.emit(cgFmovS(target_reg, arg_reg));
                            } else {
                                try cg.emit(cgFmovD(target_reg, arg_reg));
                            }
                        }
                    } else {
                        const target_reg: u8 = GPR.a0 + i;
                        if (arg_reg != target_reg) {
                            try cg.emit(enc3R(OP3R.OR, target_reg, arg_reg, GPR.zero));
                        }
                    }
                }

                // 加载目标入口地址到 t0
                const addr: u64 = @intCast(entry_addr);
                try loadImm64Cg(&cg, GPR.t0, addr);

                // jirl ra, t0, 0（调用函数，ra 保存返回地址）
                try cg.emit(enc2RI16(OPBR.JIRL, GPR.ra, GPR.t0, 0));

                // 恢复 t0-t8, s0-s8, ft0-ft15（在移动返回值之前）
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t0, GPR.sp, 0));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t1, GPR.sp, 8));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t2, GPR.sp, 16));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t3, GPR.sp, 24));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t4, GPR.sp, 32));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t5, GPR.sp, 40));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t6, GPR.sp, 48));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t7, GPR.sp, 56));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.t8, GPR.sp, 64));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s0, GPR.sp, 72));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s1, GPR.sp, 80));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s2, GPR.sp, 88));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s3, GPR.sp, 96));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s4, GPR.sp, 104));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s5, GPR.sp, 112));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s6, GPR.sp, 120));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s7, GPR.sp, 128));
                try cg.emit(enc2RI12(OP2RI12.LD_D, GPR.s8, GPR.sp, 136));
                try cg.emit(cgFldD(FPR.ft0, GPR.sp, 144));
                try cg.emit(cgFldD(FPR.ft1, GPR.sp, 152));
                try cg.emit(cgFldD(FPR.ft2, GPR.sp, 160));
                try cg.emit(cgFldD(FPR.ft3, GPR.sp, 168));
                try cg.emit(cgFldD(FPR.ft4, GPR.sp, 176));
                try cg.emit(cgFldD(FPR.ft5, GPR.sp, 184));
                try cg.emit(cgFldD(FPR.ft6, GPR.sp, 192));
                try cg.emit(cgFldD(FPR.ft7, GPR.sp, 200));
                try cg.emit(cgFldD(FPR.ft8, GPR.sp, 208));
                try cg.emit(cgFldD(FPR.ft9, GPR.sp, 216));
                try cg.emit(cgFldD(FPR.ft10, GPR.sp, 224));
                try cg.emit(cgFldD(FPR.ft11, GPR.sp, 232));
                try cg.emit(cgFldD(FPR.ft12, GPR.sp, 240));
                try cg.emit(cgFldD(FPR.ft13, GPR.sp, 248));
                try cg.emit(cgFldD(FPR.ft14, GPR.sp, 256));
                try cg.emit(cgFldD(FPR.ft15, GPR.sp, 264));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, GPR.sp, GPR.sp, 288));

                // 移动返回值到目标寄存器（在恢复寄存器之后，避免被覆盖）
                const dst = cg.resolveReg(inst.dst);
                if (inst.dst.type.isFloat()) {
                    if (dst != FPR.fa0) {
                        if (inst.dst.type == .f32) {
                            try cg.emit(cgFmovS(dst, FPR.fa0));
                        } else {
                            try cg.emit(cgFmovD(dst, FPR.fa0));
                        }
                    }
                } else {
                    if (dst != GPR.a0) {
                        try cg.emit(enc3R(OP3R.OR, dst, GPR.a0, GPR.zero));
                    }
                }
            },

            // ════════ 浮点算术（f64）════════
            .add_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFaddD(rd, rj, rk));
            },
            .sub_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFsubD(rd, rj, rk));
            },
            .mul_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFmulD(rd, rj, rk));
            },
            .div_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFdivD(rd, rj, rk));
            },
            .neg_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(cgFnegD(rd, rs1));
            },

            // ════════ 浮点算术（f32）════════
            .add_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFaddS(rd, rj, rk));
            },
            .sub_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFsubS(rd, rj, rk));
            },
            .mul_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFmulS(rd, rj, rk));
            },
            .div_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFdivS(rd, rj, rk));
            },
            .neg_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(cgFnegS(rd, rs1));
            },

            // ════════ 浮点比较（f64）→ bool ════════
            // LoongArch FCMP 结果写入 FCC 寄存器，需要 BCEQZ/BCNEZ 转换为 GPR 0/1。
            // 模式: addi.d rd, zero, 0; [BCNEZ|BCEQZ] cj=0, set_true; b done;
            //      set_true: addi.d rd, zero, 1; done:
            .eq_f64 => {
                const rd = cg.resolveReg(inst.dst); // GPR
                const rj = cg.resolveReg(inst.a.vreg); // FPR
                const rk = cg.resolveReg(inst.b.vreg); // FPR
                try cg.emit(cgFcmpCeqD(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0)); // FCC0 != 0 → 条件为真
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0)); // 跳过 set_true
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .neq_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCeqD(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBceqz(0)); // FCC0 == 0 → 不相等 → 条件为真
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .lt_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCltD(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .le_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCleD(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .gt_f64 => {
                // gt(a,b) = lt(b,a)
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCltD(0, rk, rj));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .ge_f64 => {
                // ge(a,b) = le(b,a)
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCleD(0, rk, rj));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },

            // ════════ 浮点比较（f32）→ bool ════════
            .eq_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCeqS(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .neq_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCeqS(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBceqz(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .lt_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCltS(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .le_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCleS(0, rj, rk));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .gt_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCltS(0, rk, rj));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
            .ge_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rj = cg.resolveReg(inst.a.vreg);
                const rk = cg.resolveReg(inst.b.vreg);
                try cg.emit(cgFcmpCleS(0, rk, rj));
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 0));
                const bz_idx = cg.currentOffset();
                try cg.emit(cgBcnez(0));
                const b_idx = cg.currentOffset();
                try cg.emit(encI26(OPBR.B, 0));
                const set_true_idx = cg.currentOffset();
                try cg.emit(enc2RI12(OP2RI12.ADDI_D, rd, GPR.zero, 1));
                const done_idx = cg.currentOffset();
                patchBz(&cg.code.items[bz_idx], bz_idx, set_true_idx);
                patchI26(&cg.code.items[b_idx], b_idx, done_idx);
            },
        }
    }

    // ════════ 回填跳转目标 ════════
    for (cg.pending_fixups.items) |fixup| {
        const target_offset = cg.label_offsets.get(fixup.target_label) orelse {
            return error.JitMissingLabel;
        };
        const current_offset = fixup.code_idx;

        switch (fixup.fixup_kind) {
            1 => patchI26(&cg.code.items[fixup.code_idx], current_offset, target_offset),
            2 => patchBcc(&cg.code.items[fixup.code_idx], current_offset, target_offset),
            3 => patchBz(&cg.code.items[fixup.code_idx], current_offset, target_offset),
            else => return error.JitUnknownFixupKind,
        }
    }

    // ════════ 写入可执行内存 ════════
    const code_bytes = cg.code.items.len * 4;
    const dst = exec_mem.alloc(code_bytes) orelse return error.JitOutOfExecMemory;
    for (cg.code.items, 0..) |enc, i| {
        const ptr: *u32 = @ptrCast(@alignCast(dst + i * 4));
        ptr.* = enc;
    }

    return @intFromPtr(dst);
}

// ════════════════════════════════════════════════════════════════════
// IR 模式后端接口
// ════════════════════════════════════════════════════════════════════

/// IR 模式后端实例（供 IR 编译路径使用）。
pub const ir_backend_instance: backend_mod.Backend = .{
    .availableGPRs = &AVAIL_GPRS,
    .availableFPRs = &AVAIL_FPRS,
    .compileFn = compileWrapper,
};

fn compileWrapper(
    _: *const backend_mod.Backend,
    allocator: std.mem.Allocator,
    func: *const ir.IRFunction,
    exec_mem: *mem.ExecMemory,
    func_entries: []const usize,
) !usize {
    return compile(allocator, func, exec_mem, func_entries);
}
