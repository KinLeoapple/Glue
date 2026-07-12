//! RISC-V 64 (RV64G) 代码生成器。
//!
//! 将字节码编译为 RISC-V 64 机器码，写入可执行内存。
//! 支持 i64/f64 算术/比较、分支/循环控制流。
//! 使用桥接模式：热点 opcode 内联生成原生代码，冷门 opcode 通过 rt_step 桥接。
//!
//! 功能与 ARM64 后端完全对齐。

const std = @import("std");
const ir = @import("../ir.zig");
const regalloc = @import("../regalloc.zig");
const backend_mod = @import("../backend.zig");
const mem = @import("../mem.zig");
const value = @import("value");
const reg_vm_mod = @import("reg_vm");
const reg_chunk = reg_vm_mod.reg_chunk_mod;
const reg_opcode = reg_vm_mod.reg_opcode;
const runtime = @import("../runtime/mod.zig");
const RegVM = reg_vm_mod.reg_vm.RegVM;

/// RISC-V 64 通用寄存器编号（x0-x31）。
pub const GPR = struct {
    pub const x0: u8 = 0; // zero
    pub const ra: u8 = 1; // return address
    pub const sp: u8 = 2;
    pub const gp: u8 = 3;
    pub const tp: u8 = 4;
    pub const t0: u8 = 5; // caller-saved temporary
    pub const t1: u8 = 6;
    pub const t2: u8 = 7;
    pub const s0: u8 = 8; // callee-saved (frame pointer)
    pub const s1: u8 = 9; // callee-saved
    pub const a0: u8 = 10; // argument / return value
    pub const a1: u8 = 11;
    pub const a2: u8 = 12;
    pub const a3: u8 = 13;
    pub const a4: u8 = 14;
    pub const a5: u8 = 15;
    pub const a6: u8 = 16;
    pub const a7: u8 = 17;
    pub const s2: u8 = 18; // callee-saved
    pub const s3: u8 = 19;
    pub const s4: u8 = 20;
    pub const s5: u8 = 21;
    pub const s6: u8 = 22;
    pub const s7: u8 = 23;
    pub const s8: u8 = 24;
    pub const s9: u8 = 25;
    pub const s10: u8 = 26;
    pub const s11: u8 = 27;
    pub const t3: u8 = 28; // caller-saved temporary
    pub const t4: u8 = 29;
    pub const t5: u8 = 30;
    pub const t6: u8 = 31;
};

/// RISC-V 64 浮点寄存器编号（f0-f31）。
pub const FPR = struct {
    pub const ft0: u8 = 0; // caller-saved
    pub const ft1: u8 = 1;
    pub const ft2: u8 = 2;
    pub const ft3: u8 = 3;
    pub const ft4: u8 = 4;
    pub const ft5: u8 = 5;
    pub const ft6: u8 = 6;
    pub const ft7: u8 = 7;
    pub const fs0: u8 = 8; // callee-saved
    pub const fs1: u8 = 9;
    pub const fa0: u8 = 10; // argument / return value
    pub const fa1: u8 = 11;
    pub const fa2: u8 = 12;
    pub const fa3: u8 = 13;
    pub const fa4: u8 = 14;
    pub const fa5: u8 = 15;
    pub const fa6: u8 = 16;
    pub const fa7: u8 = 17;
    pub const fs2: u8 = 18;
    pub const fs3: u8 = 19;
    pub const fs4: u8 = 20;
    pub const fs5: u8 = 21;
    pub const fs6: u8 = 22;
    pub const fs7: u8 = 23;
    pub const fs8: u8 = 24;
    pub const fs9: u8 = 25;
    pub const fs10: u8 = 26;
    pub const fs11: u8 = 27;
    pub const ft8: u8 = 28;
    pub const ft9: u8 = 29;
    pub const ft10: u8 = 30;
    pub const ft11: u8 = 31;
};

/// 可用于分配的通用寄存器（IR 模式用，桥接模式不使用）。
const AVAIL_GPRS = [_]backend_mod.PhysReg{
    .{ .id = GPR.s2, .kind = .gpr },
    .{ .id = GPR.s3, .kind = .gpr },
    .{ .id = GPR.s4, .kind = .gpr },
    .{ .id = GPR.s5, .kind = .gpr },
    .{ .id = GPR.s6, .kind = .gpr },
    .{ .id = GPR.s7, .kind = .gpr },
    .{ .id = GPR.s8, .kind = .gpr },
    .{ .id = GPR.s9, .kind = .gpr },
    .{ .id = GPR.s10, .kind = .gpr },
    .{ .id = GPR.s11, .kind = .gpr },
};

/// 可用于分配的浮点寄存器（IR 模式用）。
const AVAIL_FPRS = [_]backend_mod.PhysReg{
    .{ .id = FPR.ft0, .kind = .fpr },
    .{ .id = FPR.ft1, .kind = .fpr },
    .{ .id = FPR.ft2, .kind = .fpr },
    .{ .id = FPR.ft3, .kind = .fpr },
    .{ .id = FPR.ft4, .kind = .fpr },
    .{ .id = FPR.ft5, .kind = .fpr },
    .{ .id = FPR.ft6, .kind = .fpr },
    .{ .id = FPR.ft7, .kind = .fpr },
};

// ════════════════════════════════════════════════════════════════════
// RISC-V 指令编码辅助函数
// 所有编码遵循 RISC-V ISA Manual (RV64I + M + D)。
// 每条指令固定 4 字节。
// ════════════════════════════════════════════════════════════════════

/// R-type 编码: funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]
fn encR(funct7: u7, rd: u8, funct3: u3, rs1: u8, rs2: u8, opcode: u7) u32 {
    return (@as(u32, funct7) << 25) |
        (@as(u32, rs2) << 20) |
        (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rd) << 7) |
        opcode;
}

/// I-type 编码: imm[11:0][31:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]
fn encI(imm12: i12, rd: u8, funct3: u3, rs1: u8, opcode: u7) u32 {
    const imm: u12 = @bitCast(imm12);
    return (@as(u32, imm) << 20) |
        (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rd) << 7) |
        opcode;
}

/// S-type 编码: imm[11:5][31:25] rs2[24:20] rs1[19:15] funct3[14:12] imm[4:0][11:7] opcode[6:0]
fn encS(imm12: i12, rs2: u8, rs1: u8, funct3: u3, opcode: u7) u32 {
    const imm: u12 = @bitCast(imm12);
    const imm_hi: u7 = @truncate(imm >> 5);
    const imm_lo: u5 = @truncate(imm);
    return (@as(u32, imm_hi) << 25) |
        (@as(u32, rs2) << 20) |
        (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) |
        (@as(u32, imm_lo) << 7) |
        opcode;
}

/// B-type 编码: imm[12][31] imm[10:5][30:25] rs2[24:20] rs1[19:15] funct3[14:12] imm[4:1][11:8] imm[11][7] opcode[6:0]
/// 参数 idx 为指令索引差（以 4 字节为单位），内部乘 4 转为字节偏移量。
fn encB(idx: i32, rs1: u8, rs2: u8, funct3: u3, opcode: u7) u32 {
    const imm13: i13 = @intCast(@as(i64, idx) * 4);
    const imm: u13 = @bitCast(imm13);
    const b12: u1 = @truncate(imm >> 12);
    const b10_5: u6 = @truncate(imm >> 5);
    const b4_1: u4 = @truncate(imm >> 1);
    const b11: u1 = @truncate(imm >> 11);
    return (@as(u32, b12) << 31) |
        (@as(u32, b10_5) << 25) |
        (@as(u32, rs2) << 20) |
        (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) |
        (@as(u32, b4_1) << 8) |
        (@as(u32, b11) << 7) |
        opcode;
}

/// U-type 编码: imm[31:12][31:12] rd[11:7] opcode[6:0]
fn encU(imm20: i20, rd: u8, opcode: u7) u32 {
    const imm: u20 = @bitCast(imm20);
    return (@as(u32, imm) << 12) |
        (@as(u32, rd) << 7) |
        opcode;
}

/// J-type 编码: imm[20][31] imm[10:1][30:21] imm[11][20] imm[19:12][19:12] rd[11:7] opcode[6:0]
/// 参数 idx 为指令索引差（以 4 字节为单位），内部乘 4 转为字节偏移量。
fn encJtype(idx: i32, rd: u8, opcode: u7) u32 {
    const imm21: i21 = @intCast(@as(i64, idx) * 4);
    const imm: u21 = @bitCast(imm21);
    const b20: u1 = @truncate(imm >> 20);
    const b10_1: u10 = @truncate(imm >> 1);
    const b11: u1 = @truncate(imm >> 11);
    const b19_12: u8 = @truncate(imm >> 12);
    return (@as(u32, b20) << 31) |
        (@as(u32, b10_1) << 21) |
        (@as(u32, b11) << 20) |
        (@as(u32, b19_12) << 12) |
        (@as(u32, rd) << 7) |
        opcode;
}

// ── RV64I 算术指令 (R-type, opcode=0b0110011) ──

/// ADD rd, rs1, rs2
fn encAdd(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b000, rs1, rs2, 0b0110011);
}

/// SUB rd, rs1, rs2
fn encSub(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0100000, rd, 0b000, rs1, rs2, 0b0110011);
}

/// MUL rd, rs1, rs2 (M extension)
fn encMul(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b000, rs1, rs2, 0b0110011);
}

/// DIV rd, rs1, rs2 (signed, M extension)
fn encDiv(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b100, rs1, rs2, 0b0110011);
}

/// REM rd, rs1, rs2 (signed, M extension)
fn encRem(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b110, rs1, rs2, 0b0110011);
}

/// AND rd, rs1, rs2
fn encAnd(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b111, rs1, rs2, 0b0110011);
}

/// OR rd, rs1, rs2
fn encOr(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b110, rs1, rs2, 0b0110011);
}

/// XOR rd, rs1, rs2
fn encXor(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b100, rs1, rs2, 0b0110011);
}

/// SLT rd, rs1, rs2 (set less than, signed)
fn encSlt(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b010, rs1, rs2, 0b0110011);
}

/// SLTU rd, rs1, rs2 (set less than, unsigned)
fn encSltu(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b011, rs1, rs2, 0b0110011);
}

// ── RV64I 立即数指令 (I-type, opcode=0b0010011) ──

/// ADDI rd, rs1, imm12
fn encAddi(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b000, rs1, 0b0010011);
}

/// ANDI rd, rs1, imm12
fn encAndi(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b111, rs1, 0b0010011);
}

/// XORI rd, rs1, imm12
fn encXori(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b100, rs1, 0b0010011);
}

/// ORI rd, rs1, imm12
fn encOri(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b110, rs1, 0b0010011);
}

/// SLLI rd, rs1, shamt (RV64: 6-bit shift amount)
/// 编码: 000000 shamt[5:0] rs1 001 rd 0010011
fn encSlli(rd: u8, rs1: u8, shamt: u6) u32 {
    return (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b001 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

/// SRLI rd, rs1, shamt (logical right shift)
/// 编码: 000000 shamt[5:0] rs1 101 rd 0010011
fn encSrli(rd: u8, rs1: u8, shamt: u6) u32 {
    return (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b101 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

// ── RV64I load/store 指令 ──

/// LD rd, imm12(rs1) (load 64-bit)
fn encLd(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b011, rs1, 0b0000011);
}

/// LBU rd, imm12(rs1) (load byte unsigned)
fn encLbu(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b100, rs1, 0b0000011);
}

/// SD rs2, imm12(rs1) (store 64-bit)
fn encSd(rs2: u8, rs1: u8, imm12: i12) u32 {
    return encS(imm12, rs2, rs1, 0b011, 0b0100011);
}

/// SB rs2, imm12(rs1) (store byte)
fn encSb(rs2: u8, rs1: u8, imm12: i12) u32 {
    return encS(imm12, rs2, rs1, 0b000, 0b0100011);
}

// ── RV64I 分支指令 (B-type, opcode=0b1100011) ──

/// BEQ rs1, rs2, imm13
fn encBeq(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b000, 0b1100011);
}

/// BNE rs1, rs2, imm13
fn encBne(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b001, 0b1100011);
}

/// BLT rs1, rs2, imm13 (signed)
fn encBlt(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b100, 0b1100011);
}

/// BGE rs1, rs2, imm13 (signed)
fn encBge(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b101, 0b1100011);
}

/// BLTU rs1, rs2, imm13 (unsigned)
fn encBltu(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b110, 0b1100011);
}

/// BGEU rs1, rs2, imm13 (unsigned)
fn encBgeu(rs1: u8, rs2: u8, idx: i32) u32 {
    return encB(idx, rs1, rs2, 0b111, 0b1100011);
}

// ── RV64I 跳转指令 ──

/// JAL rd, imm21 (opcode=0b1101111)
fn encJal(rd: u8, idx: i32) u32 {
    return encJtype(idx, rd, 0b1101111);
}

/// JALR rd, rs1, imm12 (opcode=0b1100111)
fn encJalr(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b000, rs1, 0b1100111);
}

/// LUI rd, imm20 (opcode=0b0110111)
fn encLui(rd: u8, imm20: i20) u32 {
    return encU(imm20, rd, 0b0110111);
}

// ── 伪指令 ──

/// RET = JALR x0, ra, 0
fn encRet() u32 {
    return encJalr(0, GPR.ra, 0);
}

/// MV rd, rs = ADDI rd, rs, 0
fn encMv(rd: u8, rs: u8) u32 {
    return encAddi(rd, rs, 0);
}

/// NEG rd, rs = SUB rd, x0, rs
fn encNeg(rd: u8, rs: u8) u32 {
    return encSub(rd, GPR.x0, rs);
}

/// NOT rd, rs = XORI rd, rs, -1
fn encNot(rd: u8, rs: u8) u32 {
    return encXori(rd, rs, -1);
}

/// SEQZ rd, rs = SLTIU rd, rs, 1
fn encSeqz(rd: u8, rs: u8) u32 {
    return encI(1, rd, 0b011, rs, 0b0010011);
}

/// SNEZ rd, rs = SLTU rd, x0, rs
fn encSnez(rd: u8, rs: u8) u32 {
    return encSltu(rd, GPR.x0, rs);
}

/// J imm21 = JAL x0, imm21 (无条件跳转)
fn encJ(idx: i32) u32 {
    return encJal(GPR.x0, idx);
}

// ── RV64D 浮点指令 (D extension) ──

/// FLD rd, imm12(rs1) (load double, opcode=0b0000111)
fn encFld(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b011, rs1, 0b0000111);
}

/// FSD rs2, imm12(rs1) (store double, opcode=0b0100111)
fn encFsd(rs2: u8, rs1: u8, imm12: i12) u32 {
    return encS(imm12, rs2, rs1, 0b011, 0b0100111);
}

/// FADD.D rd, rs1, rs2 (funct7=0b0000001, rm=0b000=RNE)
fn encFaddD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSUB.D rd, rs1, rs2
fn encFsubD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000101, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FMUL.D rd, rs1, rs2
fn encFmulD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0001001, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FDIV.D rd, rs1, rs2
fn encFdivD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0001101, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSGNJ.D rd, rs1, rs2 (用于 FMV.D: fsgnj.d rd, rs, rs)
fn encFsgnjD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0010001, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSGNJN.D rd, rs1, rs2 (用于 FNEG.D: fsgnjn.d rd, rs, rs)
fn encFsgnjnD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0010001, rd, 0b001, rs1, rs2, 0b1010011);
}

/// FCVT.D.L rd, rs1 (i64 → f64, rm=RNE)
/// funct7=0b1101001, rs2=0b010(i64)
fn encFcvtDL(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b1101001) << 25) |
        (@as(u32, 0b010) << 20) |
        (@as(u32, rs1) << 15) |
        (0b000 << 12) |
        (@as(u32, rd) << 7) |
        0b1010011;
}

/// FCVT.L.D rd, rs1 (f64 → i64, rm=RTZ)
/// funct7=0b1100001, rs2=0b010(i64)
fn encFcvtLD(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b1100001) << 25) |
        (@as(u32, 0b010) << 20) |
        (@as(u32, rs1) << 15) |
        (0b001 << 12) | // rm=RTZ (round toward zero)
        (@as(u32, rd) << 7) |
        0b1010011;
}

/// FEQ.D rd, rs1, rs2
fn encFeqD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010001, rd, 0b010, rs1, rs2, 0b1010011);
}

/// FLT.D rd, rs1, rs2
fn encFltD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010001, rd, 0b001, rs1, rs2, 0b1010011);
}

/// FLE.D rd, rs1, rs2
fn encFleD(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010001, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FMV.D rd, rs = FSGNJ.D rd, rs, rs
fn encFmvD(rd: u8, rs: u8) u32 {
    return encFsgnjD(rd, rs, rs);
}

/// FNEG.D rd, rs = FSGNJN.D rd, rs, rs
fn encFnegD(rd: u8, rs: u8) u32 {
    return encFsgnjnD(rd, rs, rs);
}

// ── RV64I 移位立即数（算术右移）──

/// SRAI rd, rs1, shamt (RV64: 算术右移, 6-bit shamt)
/// 编码: 010000 shamt[5:0] rs1 101 rd 0010011
fn encSrai(rd: u8, rs1: u8, shamt: u6) u32 {
    return (@as(u32, 0b010000) << 26) |
        (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b101 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

// ── RV64F 单精度浮点指令 (F extension) ──

/// FADD.S rd, rs1, rs2 (funct7=0b0000000, rm=RNE)
fn encFaddS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSUB.S rd, rs1, rs2
fn encFsubS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000100, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FMUL.S rd, rs1, rs2
fn encFmulS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0001000, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FDIV.S rd, rs1, rs2
fn encFdivS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0001100, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSGNJ.S rd, rs1, rs2 (用于 FMV.S: fsgnj.s rd, rs, rs)
fn encFsgnjS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0010000, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FSGNJN.S rd, rs1, rs2 (用于 FNEG.S: fsgnjn.s rd, rs, rs)
fn encFsgnjnS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0010000, rd, 0b001, rs1, rs2, 0b1010011);
}

/// FMV.S rd, rs = FSGNJ.S rd, rs, rs
fn encFmvS(rd: u8, rs: u8) u32 {
    return encFsgnjS(rd, rs, rs);
}

/// FNEG.S rd, rs = FSGNJN.S rd, rs, rs
fn encFnegS(rd: u8, rs: u8) u32 {
    return encFsgnjnS(rd, rs, rs);
}

/// FEQ.S rd, rs1, rs2
fn encFeqS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010000, rd, 0b010, rs1, rs2, 0b1010011);
}

/// FLT.S rd, rs1, rs2
fn encFltS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010000, rd, 0b001, rs1, rs2, 0b1010011);
}

/// FLE.S rd, rs1, rs2
fn encFleS(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b1010000, rd, 0b000, rs1, rs2, 0b1010011);
}

/// FCVT.S.L rd, rs1 (i64 → f32, rm=RNE)
/// funct7=0b1101000, rs2=0b010(i64)
fn encFcvtSL(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b1101000) << 25) |
        (@as(u32, 0b010) << 20) |
        (@as(u32, rs1) << 15) |
        (0b000 << 12) |
        (@as(u32, rd) << 7) |
        0b1010011;
}

/// FCVT.L.S rd, rs1 (f32 → i64, rm=RTZ)
/// funct7=0b1100000, rs2=0b010(i64)
fn encFcvtLS(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b1100000) << 25) |
        (@as(u32, 0b010) << 20) |
        (@as(u32, rs1) << 15) |
        (0b001 << 12) | // rm=RTZ
        (@as(u32, rd) << 7) |
        0b1010011;
}

/// FCVT.S.D rd, rs1 (f64 → f32, rm=RNE)
/// funct7=0b0100001, rs2=0b001
fn encFcvtSD(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b0100001) << 25) |
        (@as(u32, 0b001) << 20) |
        (@as(u32, rs1) << 15) |
        (0b000 << 12) |
        (@as(u32, rd) << 7) |
        0b1010011;
}

/// FCVT.D.S rd, rs1 (f32 → f64, rm=RNE)
/// funct7=0b0100001, rs2=0b000
fn encFcvtDS(rd: u8, rs1: u8) u32 {
    return (@as(u32, 0b0100001) << 25) |
        (@as(u32, 0b000) << 20) |
        (@as(u32, rs1) << 15) |
        (0b000 << 12) |
        (@as(u32, rd) << 7) |
        0b1010011;
}

// ── GPR ↔ FPR 位移动指令 ──

/// FMV.D.X rd, rs1 (GPR → FPR, 双精度位移动)
/// funct7=0b1111001, rs2=0b00000, funct3=0b000
fn encFmvDX(rd: u8, rs1: u8) u32 {
    return encR(0b1111001, rd, 0b000, rs1, 0, 0b1010011);
}

/// FMV.W.X rd, rs1 (GPR → FPR, 单精度位移动)
/// funct7=0b1111000, rs2=0b00000, funct3=0b000
fn encFmvWX(rd: u8, rs1: u8) u32 {
    return encR(0b1111000, rd, 0b000, rs1, 0, 0b1010011);
}

// ── B-type / J-type 立即数回填辅助 ──

/// 回填 B-type 立即数（保留 rs1/rs2/funct3/opcode，仅替换立即数位）。
/// 参数 idx 为指令索引差（以 4 字节为单位），内部乘 4 转为字节偏移量。
fn patchB(inst: u32, idx: i32) u32 {
    const new_imm13: i13 = @intCast(@as(i64, idx) * 4);
    const imm: u13 = @bitCast(new_imm13);
    const b12: u32 = @as(u32, @as(u1, @truncate(imm >> 12))) << 31;
    const b10_5: u32 = @as(u32, @as(u6, @truncate(imm >> 5))) << 25;
    const b4_1: u32 = @as(u32, @as(u4, @truncate(imm >> 1))) << 8;
    const b11: u32 = @as(u32, @as(u1, @truncate(imm >> 11))) << 7;
    const imm_mask = b12 | b10_5 | b4_1 | b11;
    const keep_mask: u32 = ~((@as(u32, 1) << 31) | (@as(u32, 0x3F) << 25) | (@as(u32, 0xF) << 8) | (@as(u32, 1) << 7));
    return (inst & keep_mask) | imm_mask;
}

/// 回填 J-type 立即数（保留 rd/opcode，仅替换立即数位）。
/// 参数 idx 为指令索引差（以 4 字节为单位），内部乘 4 转为字节偏移量。
fn patchJ(inst: u32, idx: i32) u32 {
    const new_imm21: i21 = @intCast(@as(i64, idx) * 4);
    const imm: u21 = @bitCast(new_imm21);
    const b20: u32 = @as(u32, @as(u1, @truncate(imm >> 20))) << 31;
    const b10_1: u32 = @as(u32, @as(u10, @truncate(imm >> 1))) << 21;
    const b11: u32 = @as(u32, @as(u1, @truncate(imm >> 11))) << 20;
    const b19_12: u32 = @as(u32, @as(u8, @truncate(imm >> 12))) << 12;
    const imm_mask = b20 | b10_1 | b11 | b19_12;
    const keep_mask: u32 = ~((@as(u32, 1) << 31) | (@as(u32, 0x3FF) << 21) | (@as(u32, 1) << 20) | (@as(u32, 0xFF) << 12));
    return (inst & keep_mask) | imm_mask;
}

// ── 立即数加载辅助 ──

/// 加载 32 位有符号立即数到寄存器（LUI + ADDI，2 条指令）。
/// 使用 %hi/%lo 补偿 ADDI 的符号扩展。
fn loadImm32(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, val: i32) !void {
    const uval: u32 = @bitCast(val);
    const hi20_u: u20 = @truncate((uval +% 0x800) >> 12);
    const lo12_u: u12 = @truncate(uval);
    if (hi20_u == 0) {
        // 仅需 ADDI（从 x0 加载）
        try buf.append(alloc, encAddi(rd, GPR.x0, @bitCast(lo12_u)));
    } else {
        try buf.append(alloc, encLui(rd, @bitCast(hi20_u)));
        if (lo12_u != 0) {
            try buf.append(alloc, encAddi(rd, rd, @bitCast(lo12_u)));
        }
    }
}

/// 加载 64 位立即数/地址到寄存器。
/// 若高 32 位为 0 或 0xFFFFFFFF（32 位符号扩展），仅需 LUI + ADDI（2 条）。
/// 否则使用 s6 作为临时寄存器，共 7 条指令。
fn loadImm64(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, val: u64) !void {
    const upper32: u32 = @intCast(val >> 32);
    const lower32: u32 = @truncate(val);

    if (upper32 == 0 or upper32 == 0xFFFFFFFF) {
        // 32 位符号扩展：LUI + ADDI 自动符号扩展到 64 位
        const v32: i32 = @bitCast(lower32);
        try loadImm32(buf, alloc, rd, v32);
    } else {
        // 完整 64 位加载
        // 加载低 32 位到 rd
        const lo_v32: i32 = @bitCast(lower32);
        const lo_uval: u32 = @bitCast(lo_v32);
        const lo_hi20: u20 = @truncate((lo_uval +% 0x800) >> 12);
        const lo_lo12: u12 = @truncate(lo_uval);
        try buf.append(alloc, encLui(rd, @bitCast(lo_hi20)));
        if (lo_lo12 != 0) {
            try buf.append(alloc, encAddi(rd, rd, @bitCast(lo_lo12)));
        }
        // 加载高 32 位到 s6
        const up_v32: i32 = @bitCast(upper32);
        const up_uval: u32 = @bitCast(up_v32);
        const up_hi20: u20 = @truncate((up_uval +% 0x800) >> 12);
        const up_lo12: u12 = @truncate(up_uval);
        try buf.append(alloc, encLui(GPR.s6, @bitCast(up_hi20)));
        if (up_lo12 != 0) {
            try buf.append(alloc, encAddi(GPR.s6, GPR.s6, @bitCast(up_lo12)));
        }
        // s6 左移 32 位
        try buf.append(alloc, encSlli(GPR.s6, GPR.s6, 32));
        // 合并
        try buf.append(alloc, encOr(rd, rd, GPR.s6));
    }
}

// ════════════════════════════════════════════════════════════════════
// IR 模式代码生成器
// ════════════════════════════════════════════════════════════════════

/// IR 模式代码生成器状态。
const Codegen = struct {
    /// 机器码缓冲区（u32 数组，RISC-V 每条指令 4 字节）。
    code: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,
    /// 寄存器分配结果。
    alloc: *const regalloc.Allocation,
    /// 标签 → 代码偏移映射。
    label_offsets: std.AutoHashMap(u32, u32),
    /// 待修复的跳转指令（需要回填目标地址）。
    pending_fixups: std.ArrayListUnmanaged(Fixup) = .empty,

    const Fixup = struct {
        /// 需要修复的代码索引（code 数组中的位置）。
        code_idx: u32,
        /// 目标标签 ID。
        target_label: u32,
        /// 跳转指令类型（1=J-type, 2=B-type）。
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

    /// 追加一条 RISC-V 指令。
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
        // 溢出到栈的情况暂不支持
        @panic("JIT register spill not supported in prototype");
    }
};

/// 加载 32 位有符号立即数到寄存器（IR 模式，使用 Codegen 接口）。
fn loadImm32Cg(cg: *Codegen, rd: u8, val: i32) !void {
    const uval: u32 = @bitCast(val);
    const hi20_u: u20 = @truncate((uval +% 0x800) >> 12);
    const lo12_u: u12 = @truncate(uval);
    if (hi20_u == 0) {
        try cg.emit(encAddi(rd, GPR.x0, @bitCast(lo12_u)));
    } else {
        try cg.emit(encLui(rd, @bitCast(hi20_u)));
        if (lo12_u != 0) {
            try cg.emit(encAddi(rd, rd, @bitCast(lo12_u)));
        }
    }
}

/// 加载 64 位立即数到寄存器（IR 模式，使用 t1 作为临时寄存器）。
fn loadImm64Cg(cg: *Codegen, rd: u8, val: i64) !void {
    const uval: u64 = @bitCast(val);
    const upper32: u32 = @intCast(uval >> 32);
    const lower32: u32 = @truncate(uval);

    if (upper32 == 0 or upper32 == 0xFFFFFFFF) {
        // 32 位符号扩展：LUI + ADDI 自动符号扩展到 64 位
        const v32: i32 = @bitCast(lower32);
        try loadImm32Cg(cg, rd, v32);
    } else {
        // 完整 64 位加载，使用 t1 作为临时寄存器
        // 加载低 32 位到 rd
        const lo_v32: i32 = @bitCast(lower32);
        const lo_uval: u32 = @bitCast(lo_v32);
        const lo_hi20: u20 = @truncate((lo_uval +% 0x800) >> 12);
        const lo_lo12: u12 = @truncate(lo_uval);
        try cg.emit(encLui(rd, @bitCast(lo_hi20)));
        if (lo_lo12 != 0) {
            try cg.emit(encAddi(rd, rd, @bitCast(lo_lo12)));
        }
        // 加载高 32 位到 t1
        const up_v32: i32 = @bitCast(upper32);
        const up_uval: u32 = @bitCast(up_v32);
        const up_hi20: u20 = @truncate((up_uval +% 0x800) >> 12);
        const up_lo12: u12 = @truncate(up_uval);
        try cg.emit(encLui(GPR.t1, @bitCast(up_hi20)));
        if (up_lo12 != 0) {
            try cg.emit(encAddi(GPR.t1, GPR.t1, @bitCast(up_lo12)));
        }
        // t1 左移 32 位
        try cg.emit(encSlli(GPR.t1, GPR.t1, 32));
        // 合并
        try cg.emit(encOr(rd, rd, GPR.t1));
    }
}

/// 编译 IR 函数为 RISC-V 64 机器码。
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
    // 保存 ra 和 fp(s0)，建立 16 字节栈帧
    try cg.emit(encAddi(GPR.sp, GPR.sp, -16));
    try cg.emit(encSd(GPR.ra, GPR.sp, 8));
    try cg.emit(encSd(GPR.s0, GPR.sp, 0));
    try cg.emit(encAddi(GPR.s0, GPR.sp, 16));

    // ════════ 函数体 ════════
    for (func.insts.items) |inst| {
        switch (inst.op) {
            .label => {
                // 记录标签位置
                try cg.label_offsets.put(inst.label, cg.currentOffset());
            },

            .const_i64 => {
                const rd = cg.resolveReg(inst.dst);
                try loadImm64Cg(&cg, rd, inst.imm);
            },

            .const_f64 => {
                // 加载 imm64 到 GPR t0，再用 FMV.D.X 移到 FPR
                const rd = cg.resolveReg(inst.dst); // FPR
                try loadImm64Cg(&cg, GPR.t0, inst.imm);
                try cg.emit(encFmvDX(rd, GPR.t0));
            },

            .const_f32 => {
                // 加载 imm32 到 GPR t0，再用 FMV.W.X 移到 FPR
                const rd = cg.resolveReg(inst.dst); // FPR
                try loadImm64Cg(&cg, GPR.t0, inst.imm);
                try cg.emit(encFmvWX(rd, GPR.t0));
            },

            .const_bool => {
                const rd = cg.resolveReg(inst.dst);
                if (inst.imm != 0) {
                    try cg.emit(encAddi(rd, GPR.x0, 1));
                } else {
                    try cg.emit(encAddi(rd, GPR.x0, 0));
                }
            },

            // ── i64 算术 ──
            .add_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encAdd(rd, rs1, rs2));
            },
            .sub_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSub(rd, rs1, rs2));
            },
            .mul_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encMul(rd, rs1, rs2));
            },
            .div_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encDiv(rd, rs1, rs2));
            },
            .rem_i64 => {
                // rem = a - (a/b)*b，使用 t0 作为临时寄存器
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encDiv(GPR.t0, rs1, rs2));
                try cg.emit(encMul(GPR.t0, GPR.t0, rs2));
                try cg.emit(encSub(rd, rs1, GPR.t0));
            },
            .neg_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encNeg(rd, rs1));
            },

            // ── i64 位运算 ──
            .and_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encAnd(rd, rs1, rs2));
            },
            .or_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encOr(rd, rs1, rs2));
            },
            .xor_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encXor(rd, rs1, rs2));
            },
            .not_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encNot(rd, rs1));
            },

            // ── i64 比较 → bool（结果为 0/1）──
            .eq_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                // SUB t0, rs1, rs2; SEQZ rd, t0
                try cg.emit(encSub(GPR.t0, rs1, rs2));
                try cg.emit(encSeqz(rd, GPR.t0));
            },
            .neq_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSub(GPR.t0, rs1, rs2));
                try cg.emit(encSnez(rd, GPR.t0));
            },
            .lt_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSlt(rd, rs1, rs2));
            },
            .gt_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSlt(rd, rs2, rs1));
            },
            .le_i64 => {
                // le = !(a > b) = !(b < a)：SLT rd, b, a; XORI rd, rd, 1
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSlt(rd, rs2, rs1));
                try cg.emit(encXori(rd, rd, 1));
            },
            .ge_i64 => {
                // ge = !(a < b)：SLT rd, a, b; XORI rd, rd, 1
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSlt(rd, rs1, rs2));
                try cg.emit(encXori(rd, rd, 1));
            },

            // ── 布尔逻辑 ──
            .bool_not => {
                // rd = rs ^ 1
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encXori(rd, rs1, 1));
            },

            // ── 数据移动 ──
            .move => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                if (rd != rs1) {
                    if (inst.dst.type.isFloat()) {
                        if (inst.dst.type == .f32) {
                            try cg.emit(encFmvS(rd, rs1));
                        } else {
                            try cg.emit(encFmvD(rd, rs1));
                        }
                    } else {
                        try cg.emit(encMv(rd, rs1));
                    }
                }
            },

            // ── 类型转换 ──
            .i32_to_i64 => {
                // 符号扩展：SLLI rd, rs, 32; SRAI rd, rd, 32
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encSlli(rd, rs1, 32));
                try cg.emit(encSrai(rd, rd, 32));
            },
            .i64_to_f64 => {
                // FCVT.D.L rd, rs1 (i64 → f64)
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // GPR
                try cg.emit(encFcvtDL(rd, rs1));
            },
            .f64_to_i64 => {
                // FCVT.L.D rd, rs1 (f64 → i64)
                const rd = cg.resolveReg(inst.dst); // GPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(encFcvtLD(rd, rs1));
            },
            .i64_to_f32 => {
                // FCVT.S.L rd, rs1 (i64 → f32)
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // GPR
                try cg.emit(encFcvtSL(rd, rs1));
            },
            .f32_to_i64 => {
                // FCVT.L.S rd, rs1 (f32 → i64)
                const rd = cg.resolveReg(inst.dst); // GPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(encFcvtLS(rd, rs1));
            },
            .f32_to_f64 => {
                // FCVT.D.S rd, rs1 (f32 → f64)
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(encFcvtDS(rd, rs1));
            },
            .f64_to_f32 => {
                // FCVT.S.D rd, rs1 (f64 → f32)
                const rd = cg.resolveReg(inst.dst); // FPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                try cg.emit(encFcvtSD(rd, rs1));
            },

            // ── 控制流 ──
            .jump => {
                // J label → 待回填
                const fixup_idx = cg.currentOffset();
                try cg.emit(encJ(0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_idx,
                    .target_label = inst.label,
                    .fixup_kind = 1, // J-type
                });
            },
            .branch => {
                // branch cond, true_label, false_label
                // cond 为布尔值(0/1)，非零跳转到 true_label，否则跳转到 false_label
                const cond_reg = cg.resolveReg(inst.a.vreg);
                const false_label: u32 = @truncate(@as(u64, @bitCast(inst.imm)));

                // BNE cond, x0, true_label (待回填)
                const fixup_true = cg.currentOffset();
                try cg.emit(encBne(cond_reg, GPR.x0, 0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_true,
                    .target_label = inst.label, // true_label
                    .fixup_kind = 2, // B-type
                });

                // J false_label (待回填)
                const fixup_false = cg.currentOffset();
                try cg.emit(encJ(0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_false,
                    .target_label = false_label,
                    .fixup_kind = 1, // J-type
                });
            },

            // ── 函数参数加载 ──
            .load_arg => {
                // 整数参数在 a0-a7(x10-x17)，浮点参数在 fa0-fa7(f10-f17)
                const arg_idx: u8 = @intCast(inst.imm);
                const rd = cg.resolveReg(inst.dst);
                const arg_ty = func.arg_types[arg_idx];
                if (arg_ty.isFloat()) {
                    const arg_reg: u8 = FPR.fa0 + arg_idx;
                    if (rd != arg_reg) {
                        if (arg_ty == .f32) {
                            try cg.emit(encFmvS(rd, arg_reg));
                        } else {
                            try cg.emit(encFmvD(rd, arg_reg));
                        }
                    }
                } else {
                    const arg_reg: u8 = GPR.a0 + arg_idx;
                    if (rd != arg_reg) {
                        try cg.emit(encMv(rd, arg_reg));
                    }
                }
            },

            // ── 函数返回 ──
            .return_val => {
                // 整数返回值在 a0(x10)，浮点返回值在 fa0(f10)
                const rn = cg.resolveReg(inst.a.vreg);
                if (inst.a.vreg.type.isFloat()) {
                    if (rn != FPR.fa0) {
                        if (inst.a.vreg.type == .f32) {
                            try cg.emit(encFmvS(FPR.fa0, rn));
                        } else {
                            try cg.emit(encFmvD(FPR.fa0, rn));
                        }
                    }
                } else {
                    if (rn != GPR.a0) {
                        try cg.emit(encMv(GPR.a0, rn));
                    }
                }
                // 函数 epilogue
                try cg.emit(encLd(GPR.ra, GPR.sp, 8));
                try cg.emit(encLd(GPR.s0, GPR.sp, 0));
                try cg.emit(encAddi(GPR.sp, GPR.sp, 16));
                try cg.emit(encRet());
            },
            .return_void => {
                // 函数 epilogue
                try cg.emit(encLd(GPR.ra, GPR.sp, 8));
                try cg.emit(encLd(GPR.s0, GPR.sp, 0));
                try cg.emit(encAddi(GPR.sp, GPR.sp, 16));
                try cg.emit(encRet());
            },

            // ── 函数调用 ──
            .call => {
                // JIT 内函数调用：JIT 不遵循标准 ABI，callee 不保存 callee-saved 寄存器，
                // 因此 caller 必须保存所有 JIT 使用的寄存器 (s2-s11, ft0-ft7)。
                const target_idx = inst.call_target;
                if (target_idx >= func_entries.len or func_entries[target_idx] == 0) {
                    return error.JitCallTargetNotCompiled;
                }
                const entry_addr = func_entries[target_idx];

                // 保存 s2-s11, ft0-ft7 (18 个寄存器 = 144 字节，16 字节对齐)
                try cg.emit(encAddi(GPR.sp, GPR.sp, -144));
                try cg.emit(encSd(GPR.s2, GPR.sp, 0));
                try cg.emit(encSd(GPR.s3, GPR.sp, 8));
                try cg.emit(encSd(GPR.s4, GPR.sp, 16));
                try cg.emit(encSd(GPR.s5, GPR.sp, 24));
                try cg.emit(encSd(GPR.s6, GPR.sp, 32));
                try cg.emit(encSd(GPR.s7, GPR.sp, 40));
                try cg.emit(encSd(GPR.s8, GPR.sp, 48));
                try cg.emit(encSd(GPR.s9, GPR.sp, 56));
                try cg.emit(encSd(GPR.s10, GPR.sp, 64));
                try cg.emit(encSd(GPR.s11, GPR.sp, 72));
                try cg.emit(encFsd(FPR.ft0, GPR.sp, 80));
                try cg.emit(encFsd(FPR.ft1, GPR.sp, 88));
                try cg.emit(encFsd(FPR.ft2, GPR.sp, 96));
                try cg.emit(encFsd(FPR.ft3, GPR.sp, 104));
                try cg.emit(encFsd(FPR.ft4, GPR.sp, 112));
                try cg.emit(encFsd(FPR.ft5, GPR.sp, 120));
                try cg.emit(encFsd(FPR.ft6, GPR.sp, 128));
                try cg.emit(encFsd(FPR.ft7, GPR.sp, 136));

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
                                try cg.emit(encFmvS(target_reg, arg_reg));
                            } else {
                                try cg.emit(encFmvD(target_reg, arg_reg));
                            }
                        }
                    } else {
                        const target_reg: u8 = GPR.a0 + i;
                        if (arg_reg != target_reg) {
                            try cg.emit(encMv(target_reg, arg_reg));
                        }
                    }
                }

                // 加载目标入口地址到 t0
                const addr: u64 = @intCast(entry_addr);
                try loadImm64Cg(&cg, GPR.t0, @bitCast(addr));

                // JALR ra, t0, 0（调用函数，ra 保存返回地址）
                try cg.emit(encJalr(GPR.ra, GPR.t0, 0));

                // 恢复 s2-s11, ft0-ft7（在移动返回值之前）
                try cg.emit(encLd(GPR.s2, GPR.sp, 0));
                try cg.emit(encLd(GPR.s3, GPR.sp, 8));
                try cg.emit(encLd(GPR.s4, GPR.sp, 16));
                try cg.emit(encLd(GPR.s5, GPR.sp, 24));
                try cg.emit(encLd(GPR.s6, GPR.sp, 32));
                try cg.emit(encLd(GPR.s7, GPR.sp, 40));
                try cg.emit(encLd(GPR.s8, GPR.sp, 48));
                try cg.emit(encLd(GPR.s9, GPR.sp, 56));
                try cg.emit(encLd(GPR.s10, GPR.sp, 64));
                try cg.emit(encLd(GPR.s11, GPR.sp, 72));
                try cg.emit(encFld(FPR.ft0, GPR.sp, 80));
                try cg.emit(encFld(FPR.ft1, GPR.sp, 88));
                try cg.emit(encFld(FPR.ft2, GPR.sp, 96));
                try cg.emit(encFld(FPR.ft3, GPR.sp, 104));
                try cg.emit(encFld(FPR.ft4, GPR.sp, 112));
                try cg.emit(encFld(FPR.ft5, GPR.sp, 120));
                try cg.emit(encFld(FPR.ft6, GPR.sp, 128));
                try cg.emit(encFld(FPR.ft7, GPR.sp, 136));
                try cg.emit(encAddi(GPR.sp, GPR.sp, 144));

                // 移动返回值到目标寄存器（在恢复寄存器之后，避免被覆盖）
                const dst = cg.resolveReg(inst.dst);
                if (inst.dst.type.isFloat()) {
                    if (dst != FPR.fa0) {
                        if (inst.dst.type == .f32) {
                            try cg.emit(encFmvS(dst, FPR.fa0));
                        } else {
                            try cg.emit(encFmvD(dst, FPR.fa0));
                        }
                    }
                } else {
                    if (dst != GPR.a0) {
                        try cg.emit(encMv(dst, GPR.a0));
                    }
                }
            },

            // ════════ 浮点算术（f64）════════
            .add_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFaddD(rd, rs1, rs2));
            },
            .sub_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFsubD(rd, rs1, rs2));
            },
            .mul_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFmulD(rd, rs1, rs2));
            },
            .div_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFdivD(rd, rs1, rs2));
            },
            .neg_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encFnegD(rd, rs1));
            },

            // ════════ 浮点算术（f32）════════
            .add_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFaddS(rd, rs1, rs2));
            },
            .sub_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFsubS(rd, rs1, rs2));
            },
            .mul_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFmulS(rd, rs1, rs2));
            },
            .div_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFdivS(rd, rs1, rs2));
            },
            .neg_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                try cg.emit(encFnegS(rd, rs1));
            },

            // ════════ 浮点比较（f64）→ bool ════════
            .eq_f64 => {
                const rd = cg.resolveReg(inst.dst); // GPR
                const rs1 = cg.resolveReg(inst.a.vreg); // FPR
                const rs2 = cg.resolveReg(inst.b.vreg); // FPR
                try cg.emit(encFeqD(rd, rs1, rs2));
            },
            .neq_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFeqD(rd, rs1, rs2));
                try cg.emit(encXori(rd, rd, 1));
            },
            .lt_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFltD(rd, rs1, rs2));
            },
            .le_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFleD(rd, rs1, rs2));
            },
            .gt_f64 => {
                // gt(a,b) = lt(b,a)
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFltD(rd, rs2, rs1));
            },
            .ge_f64 => {
                // ge(a,b) = le(b,a)
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFleD(rd, rs2, rs1));
            },

            // ════════ 浮点比较（f32）→ bool ════════
            .eq_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFeqS(rd, rs1, rs2));
            },
            .neq_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFeqS(rd, rs1, rs2));
                try cg.emit(encXori(rd, rd, 1));
            },
            .lt_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFltS(rd, rs1, rs2));
            },
            .le_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFleS(rd, rs1, rs2));
            },
            .gt_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFltS(rd, rs2, rs1));
            },
            .ge_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rs1 = cg.resolveReg(inst.a.vreg);
                const rs2 = cg.resolveReg(inst.b.vreg);
                try cg.emit(encFleS(rd, rs2, rs1));
            },
        }
    }

    // ════════ 回填跳转目标 ════════
    for (cg.pending_fixups.items) |fixup| {
        const target_offset = cg.label_offsets.get(fixup.target_label) orelse {
            return error.JitMissingLabel;
        };
        const current_offset = fixup.code_idx;
        const delta: i64 = @as(i64, target_offset) - @as(i64, current_offset);

        switch (fixup.fixup_kind) {
            1 => { // J-type (JAL x0, ...)
                cg.code.items[fixup.code_idx] = encJ(@intCast(delta));
            },
            2 => { // B-type (BNE/BEQ)
                cg.code.items[fixup.code_idx] = patchB(cg.code.items[fixup.code_idx], @intCast(delta));
            },
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
// 桥接协作模式：直接从字节码生成 RISC-V 64 机器码
// ════════════════════════════════════════════════════════════════════

/// RegVM 中 reg_pool 字段的偏移量（编译期常量）。
const REG_POOL_PTR_OFFSET: usize = @offsetOf(RegVM, "reg_pool");

/// Value 标签和 Int 类型常量。
const TAG_INT_VAL: u8 = runtime.TAG_INT;
const TAG_BOOLEAN_VAL: u8 = runtime.TAG_BOOLEAN;
const TAG_UNIT_VAL: u8 = runtime.TAG_UNIT;
const TAG_NULL_VAL: u8 = runtime.TAG_NULL;
const TAG_FLOAT_VAL: u8 = runtime.TAG_FLOAT;
const TAG_ARRAY_VAL: u8 = runtime.TAG_ARRAY;
const INT_TYPE_I64_VAL: u8 = runtime.INT_TYPE_I64;
const FLOAT_TYPE_F64_VAL: u8 = runtime.FLOAT_TYPE_F64;
/// 最大标量 tag 值（float=5）。tag 0-5 为标量，无需引用计数。
const MAX_SCALAR_TAG: u8 = runtime.TAG_FLOAT;

/// Value 内存布局偏移量（Zig union(enum) 将 tag 放在末尾）。
const TAG_OFF: u32 = @intCast(runtime.TAG_OFFSET); // 24
const PAYLOAD_OFF: u32 = @intCast(runtime.PAYLOAD_OFFSET); // 0
const INT_LO_OFF: u32 = @intCast(runtime.INT_LO_OFFSET); // 0
const INT_TYPE_OFF: u32 = @intCast(runtime.INT_TYPE_OFFSET); // 16
const FLOAT_BITS_OFF: u32 = @intCast(runtime.FLOAT_BITS_OFFSET); // 0
const FLOAT_TYPE_OFF: u32 = @intCast(runtime.FLOAT_TYPE_OFFSET); // 16
const ARRAY_ELEMS_LEN_OFF: u32 = @intCast(runtime.ARRAY_ELEMENTS_LEN_OFFSET); // 8
const ARRAY_ELEMS_PTR_OFF: u32 = @intCast(runtime.ARRAY_ELEMENTS_PTR_OFFSET); // 0

// ── 桥接寄存器分配 ──
// s0 (x8)  = vm 指针
// s1 (x9)  = base（帧基址索引）
// s2 (x18) = rt_step 地址
// s3 (x19) = rt_call_inline 地址
// s4 (x20) = rt_array_push 地址
// s5 (x21) = rt_array_len 地址
// s6 (x22) = 临时（用于 loadImm64）
// t0 (x5)  = 临时（reg_pool_ptr）
// t1 (x6)  = 临时（frame_base = reg_pool_ptr + base*32）
// t2 (x7)  = 临时（tag/立即数）
// t3 (x28) = 临时
// t4 (x29) = 临时（加载的值）
// t5 (x30) = 临时（加载的值）
// t6 (x31) = 临时（除法中间值/大偏移地址计算）
// ft0(f0)  = 浮点临时 0
// ft1(f1)  = 浮点临时 1
// a0 (x10) = C 调用参数 0 / 返回值
// a1 (x11) = C 调用参数 1

/// 桥接模式编译：直接从字节码生成 RISC-V 64 机器码。
///
/// JIT 函数签名: fn(vm: *RegVM, base: usize) callconv(.c) void
/// 热点 opcode（i64/f64 算术/比较/跳转）生成内联原生代码。
/// 冷门 opcode 通过 rt_step 桥接函数委托 VM 单步执行。
///
/// 仅支持 register_count <= 120 的函数。
/// func_idx: 当前函数在程序函数表中的索引。
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

    var code = std.ArrayListUnmanaged(u32).empty;
    defer code.deinit(allocator);

    var ip_to_code = std.AutoHashMap(u32, u32).init(allocator);
    defer ip_to_code.deinit();

    const Fixup = struct { code_idx: u32, target_ip: u32, kind: u8 };
    var pending_fixups = std.ArrayListUnmanaged(Fixup).empty;
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

    // ── 收集跳转目标 ──
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

    const emit = struct {
        fn push(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, enc: u32) !void {
            try buf.append(alloc, enc);
        }
    }.push;

    // ── 辅助：从 frame_base(t1) 加载寄存器字段 ──
    // 若偏移超出 i12 范围，使用 t6 计算地址。
    const regLd64 = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encLd(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encLd(rd, GPR.t6, 0));
            }
        }
    }.call;
    const regLbu = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encLbu(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encLbu(rd, GPR.t6, 0));
            }
        }
    }.call;
    const regSd = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs2: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encSd(rs2, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encSd(rs2, GPR.t6, 0));
            }
        }
    }.call;
    const regSb = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs2: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encSb(rs2, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encSb(rs2, GPR.t6, 0));
            }
        }
    }.call;

    // ── 辅助：浮点寄存器访问（与 regLd64/regSd 相同的偏移处理）──
    const regFld = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encFld(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encFld(rd, GPR.t6, 0));
            }
        }
    }.call;
    const regFsd = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs2: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encFsd(rs2, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.t1, GPR.t6));
                try emit(buf, alloc, encFsd(rs2, GPR.t6, 0));
            }
        }
    }.call;

    // ── 辅助：加载 reg_pool_ptr 到 t0，计算 frame_base 到 t1 ──
    const loadFrameBase = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // t0 = vm->reg_pool (slice pointer: ptr at offset 0 of the slice)
            const pool_off: i32 = @intCast(REG_POOL_PTR_OFFSET);
            if (pool_off >= -2048 and pool_off <= 2047) {
                try emit(buf, alloc, encLd(GPR.t0, GPR.s0, @intCast(pool_off)));
            } else {
                try loadImm32(buf, alloc, GPR.t6, pool_off);
                try emit(buf, alloc, encAdd(GPR.t6, GPR.s0, GPR.t6));
                try emit(buf, alloc, encLd(GPR.t0, GPR.t6, 0));
            }
            // t1 = t0 + s1 * 32 (s1 << 5)
            try emit(buf, alloc, encSlli(GPR.t1, GPR.s1, 5));
            try emit(buf, alloc, encAdd(GPR.t1, GPR.t0, GPR.t1));
        }
    }.call;

    // ── 辅助：生成 cold 路径（rt_step 调用 + exit 检查）──
    const emitCold = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, pfixups: *std.ArrayListUnmanaged(Fixup), ip: u32) !void {
            // a0 = vm
            try emit(buf, alloc, encMv(GPR.a0, GPR.s0));
            // a1 = ip
            try loadImm32(buf, alloc, GPR.a1, @intCast(ip));
            // JALR ra, s2, 0 (call rt_step)
            try emit(buf, alloc, encJalr(GPR.ra, GPR.s2, 0));
            // BNE a0, x0, exit (占位)
            const bne_exit: u32 = @intCast(buf.items.len);
            try emit(buf, alloc, encBne(GPR.a0, GPR.x0, 0));
            try pfixups.append(alloc, .{ .code_idx = bne_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
        }
    }.call;

    // ════════ 函数 prologue ════════
    // 保存 ra + s0-s6 = 8 寄存器，80 字节帧（16 字节对齐）
    try emit(&code, allocator, encAddi(GPR.sp, GPR.sp, -80));
    try emit(&code, allocator, encSd(GPR.ra, GPR.sp, 72));
    try emit(&code, allocator, encSd(GPR.s0, GPR.sp, 64));
    try emit(&code, allocator, encSd(GPR.s1, GPR.sp, 56));
    try emit(&code, allocator, encSd(GPR.s2, GPR.sp, 48));
    try emit(&code, allocator, encSd(GPR.s3, GPR.sp, 40));
    try emit(&code, allocator, encSd(GPR.s4, GPR.sp, 32));
    try emit(&code, allocator, encSd(GPR.s5, GPR.sp, 24));
    try emit(&code, allocator, encSd(GPR.s6, GPR.sp, 16));

    // s0 = vm, s1 = base
    try emit(&code, allocator, encMv(GPR.s0, GPR.a0));
    try emit(&code, allocator, encMv(GPR.s1, GPR.a1));

    // 加载 rt_* 地址
    try loadImm64(&code, allocator, GPR.s2, rt_step_addr);
    try loadImm64(&code, allocator, GPR.s3, rt_call_inline_addr);
    try loadImm64(&code, allocator, GPR.s4, rt_array_push_addr);
    try loadImm64(&code, allocator, GPR.s5, rt_array_len_addr);

    // ════════ 函数体：遍历字节码 ════════
    const instructions = func.chunk.code.items;

    var ip: u32 = 0;
    while (ip < instructions.len) : (ip += 1) {
        try ip_to_code.put(ip, @intCast(code.items.len));

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
                    try loadFrameBase(&code, allocator);
                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try regLd64(&code, allocator, GPR.t5, c, INT_LO_OFF);
                    switch (op) {
                        .add => try emit(&code, allocator, encAdd(GPR.t4, GPR.t4, GPR.t5)),
                        .sub => try emit(&code, allocator, encSub(GPR.t4, GPR.t4, GPR.t5)),
                        .mul => try emit(&code, allocator, encMul(GPR.t4, GPR.t4, GPR.t5)),
                        .div => try emit(&code, allocator, encDiv(GPR.t4, GPR.t4, GPR.t5)),
                        .mod => {
                            try emit(&code, allocator, encDiv(GPR.t6, GPR.t4, GPR.t5));
                            try emit(&code, allocator, encMul(GPR.t6, GPR.t6, GPR.t5));
                            try emit(&code, allocator, encSub(GPR.t4, GPR.t4, GPR.t6));
                        },
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd(&code, allocator, GPR.t4, a, INT_LO_OFF);
                    reg_types[a] = .i64;
                } else if (b_known_f64 and c_known_f64 and op != .mod) {
                    try loadFrameBase(&code, allocator);
                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try regFld(&code, allocator, FPR.ft1, c, FLOAT_BITS_OFF);
                    switch (op) {
                        .add => try emit(&code, allocator, encFaddD(FPR.ft0, FPR.ft0, FPR.ft1)),
                        .sub => try emit(&code, allocator, encFsubD(FPR.ft0, FPR.ft0, FPR.ft1)),
                        .mul => try emit(&code, allocator, encFmulD(FPR.ft0, FPR.ft0, FPR.ft1)),
                        .div => try emit(&code, allocator, encFdivD(FPR.ft0, FPR.ft0, FPR.ft1)),
                        else => unreachable,
                    }
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：带 tag 检查的通用路径 ──
                    try loadFrameBase(&code, allocator);

                    // i64 快速路径
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, c, TAG_OFF);
                    const bne_not_int2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try regLd64(&code, allocator, GPR.t5, c, INT_LO_OFF);
                    switch (op) {
                        .add => try emit(&code, allocator, encAdd(GPR.t4, GPR.t4, GPR.t5)),
                        .sub => try emit(&code, allocator, encSub(GPR.t4, GPR.t4, GPR.t5)),
                        .mul => try emit(&code, allocator, encMul(GPR.t4, GPR.t4, GPR.t5)),
                        .div => try emit(&code, allocator, encDiv(GPR.t4, GPR.t4, GPR.t5)),
                        .mod => {
                            try emit(&code, allocator, encDiv(GPR.t6, GPR.t4, GPR.t5));
                            try emit(&code, allocator, encMul(GPR.t6, GPR.t6, GPR.t5));
                            try emit(&code, allocator, encSub(GPR.t4, GPR.t4, GPR.t6));
                        },
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd(&code, allocator, GPR.t4, a, INT_LO_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                        code.items[bne_not_int1] = patchB(code.items[bne_not_int1], @intCast(d1));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = patchB(code.items[bne_not_int2], @intCast(d2));
                    }

                    var b_next2: u32 = 0;
                    if (op != .mod) {
                        // f64 快速路径
                        try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                        try loadImm32(&code, allocator, GPR.t3, TAG_FLOAT_VAL);
                        const bne_cold_f1: u32 = @intCast(code.items.len);
                        try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                        try regLbu(&code, allocator, GPR.t2, c, TAG_OFF);
                        const bne_cold_f2: u32 = @intCast(code.items.len);
                        try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                        try regLbu(&code, allocator, GPR.t2, b, FLOAT_TYPE_OFF);
                        try loadImm32(&code, allocator, GPR.t3, FLOAT_TYPE_F64_VAL);
                        const bne_cold_f3: u32 = @intCast(code.items.len);
                        try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                        try regLbu(&code, allocator, GPR.t2, c, FLOAT_TYPE_OFF);
                        const bne_cold_f4: u32 = @intCast(code.items.len);
                        try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                        try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                        try regFld(&code, allocator, FPR.ft1, c, FLOAT_BITS_OFF);
                        switch (op) {
                            .add => try emit(&code, allocator, encFaddD(FPR.ft0, FPR.ft0, FPR.ft1)),
                            .sub => try emit(&code, allocator, encFsubD(FPR.ft0, FPR.ft0, FPR.ft1)),
                            .mul => try emit(&code, allocator, encFmulD(FPR.ft0, FPR.ft0, FPR.ft1)),
                            .div => try emit(&code, allocator, encFdivD(FPR.ft0, FPR.ft0, FPR.ft1)),
                            else => unreachable,
                        }
                        try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                        try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                        try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                        try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                        try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);

                        b_next2 = @intCast(code.items.len);
                        try emit(&code, allocator, encJ(0));

                        const cold_off: u32 = @intCast(code.items.len);
                        inline for (.{ bne_cold_f1, bne_cold_f2, bne_cold_f3, bne_cold_f4 }) |bne_off| {
                            const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                            code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                        }
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                    if (op != .mod) {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2));
                    }
                    reg_types[a] = .unknown;
                }
            },

            // ── 热点 opcode：i64/f64 取反 ──
            .neg => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                try loadFrameBase(&code, allocator);

                if (b_known_i64) {
                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try emit(&code, allocator, encNeg(GPR.t4, GPR.t4));
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd(&code, allocator, GPR.t4, a, INT_LO_OFF);
                    reg_types[a] = .i64;
                } else if (b_known_f64) {
                    // 已知 f64 类型：直接用 FNEG.D 取反
                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try emit(&code, allocator, encFnegD(FPR.ft0, FPR.ft0));
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：i64 → f64 → cold 三层路径 ──
                    // i64 快速路径
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try emit(&code, allocator, encNeg(GPR.t4, GPR.t4));
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd(&code, allocator, GPR.t4, a, INT_LO_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int));
                        code.items[bne_not_int] = patchB(code.items[bne_not_int], @intCast(d));
                    }

                    // f64 快速路径：检查 b 的 tag == TAG_FLOAT 且 float_type == F64
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_FLOAT_VAL);
                    const bne_cold_f1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, b, FLOAT_TYPE_OFF);
                    try loadImm32(&code, allocator, GPR.t3, FLOAT_TYPE_F64_VAL);
                    const bne_cold_f2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try emit(&code, allocator, encFnegD(FPR.ft0, FPR.ft0));
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);

                    const b_next2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold_f1, bne_cold_f2 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                    {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2));
                    }
                    reg_types[a] = .unknown;
                }
            },

            // ── 热点 opcode：i64/f64 比较 ──
            .eq, .neq, .lt, .gt, .le, .ge => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                if (b_known_i64 and c_known_i64) {
                    try loadFrameBase(&code, allocator);
                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try regLd64(&code, allocator, GPR.t5, c, INT_LO_OFF);
                    switch (op) {
                        .eq => { try emit(&code, allocator, encSub(GPR.t3, GPR.t4, GPR.t5)); try emit(&code, allocator, encSeqz(GPR.t4, GPR.t3)); },
                        .neq => { try emit(&code, allocator, encSub(GPR.t3, GPR.t4, GPR.t5)); try emit(&code, allocator, encSnez(GPR.t4, GPR.t3)); },
                        .lt => try emit(&code, allocator, encSlt(GPR.t4, GPR.t4, GPR.t5)),
                        .gt => try emit(&code, allocator, encSlt(GPR.t4, GPR.t5, GPR.t4)),
                        .le => { try emit(&code, allocator, encSlt(GPR.t4, GPR.t5, GPR.t4)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        .ge => { try emit(&code, allocator, encSlt(GPR.t4, GPR.t4, GPR.t5)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);
                    reg_types[a] = .boolean;
                } else if (b_known_f64 and c_known_f64) {
                    try loadFrameBase(&code, allocator);
                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try regFld(&code, allocator, FPR.ft1, c, FLOAT_BITS_OFF);
                    switch (op) {
                        .eq => try emit(&code, allocator, encFeqD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .neq => { try emit(&code, allocator, encFeqD(GPR.t4, FPR.ft0, FPR.ft1)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        .lt => try emit(&code, allocator, encFltD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .gt => try emit(&code, allocator, encFltD(GPR.t4, FPR.ft1, FPR.ft0)),
                        .le => try emit(&code, allocator, encFleD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .ge => try emit(&code, allocator, encFleD(GPR.t4, FPR.ft1, FPR.ft0)),
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);
                    reg_types[a] = .boolean;
                } else {
                    try loadFrameBase(&code, allocator);
                    // i64 快速路径
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, c, TAG_OFF);
                    const bne_not_int2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try regLd64(&code, allocator, GPR.t5, c, INT_LO_OFF);
                    switch (op) {
                        .eq => { try emit(&code, allocator, encSub(GPR.t3, GPR.t4, GPR.t5)); try emit(&code, allocator, encSeqz(GPR.t4, GPR.t3)); },
                        .neq => { try emit(&code, allocator, encSub(GPR.t3, GPR.t4, GPR.t5)); try emit(&code, allocator, encSnez(GPR.t4, GPR.t3)); },
                        .lt => try emit(&code, allocator, encSlt(GPR.t4, GPR.t4, GPR.t5)),
                        .gt => try emit(&code, allocator, encSlt(GPR.t4, GPR.t5, GPR.t4)),
                        .le => { try emit(&code, allocator, encSlt(GPR.t4, GPR.t5, GPR.t4)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        .ge => { try emit(&code, allocator, encSlt(GPR.t4, GPR.t4, GPR.t5)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                        code.items[bne_not_int1] = patchB(code.items[bne_not_int1], @intCast(d1));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = patchB(code.items[bne_not_int2], @intCast(d2));
                    }

                    // f64 快速路径：检查 b/c 的 tag == TAG_FLOAT 且 float_type == F64
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_FLOAT_VAL);
                    const bne_cold_f1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, c, TAG_OFF);
                    const bne_cold_f2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, b, FLOAT_TYPE_OFF);
                    try loadImm32(&code, allocator, GPR.t3, FLOAT_TYPE_F64_VAL);
                    const bne_cold_f3: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, c, FLOAT_TYPE_OFF);
                    const bne_cold_f4: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try regFld(&code, allocator, FPR.ft1, c, FLOAT_BITS_OFF);
                    switch (op) {
                        .eq => try emit(&code, allocator, encFeqD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .neq => { try emit(&code, allocator, encFeqD(GPR.t4, FPR.ft0, FPR.ft1)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        .lt => try emit(&code, allocator, encFltD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .gt => try emit(&code, allocator, encFltD(GPR.t4, FPR.ft1, FPR.ft0)),
                        .le => try emit(&code, allocator, encFleD(GPR.t4, FPR.ft0, FPR.ft1)),
                        .ge => try emit(&code, allocator, encFleD(GPR.t4, FPR.ft1, FPR.ft0)),
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);

                    const b_next2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold_f1, bne_cold_f2, bne_cold_f3, bne_cold_f4 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                    {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2));
                    }
                    reg_types[a] = .boolean;
                }
            },

            // ── 热点 opcode：布尔取反 ──
            .not_op => {
                try loadFrameBase(&code, allocator);
                try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, TAG_BOOLEAN_VAL);
                const bne_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                try regLbu(&code, allocator, GPR.t4, b, PAYLOAD_OFF);
                try emit(&code, allocator, encXori(GPR.t4, GPR.t4, 1));
                try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                    code.items[bne_cold] = patchB(code.items[bne_cold], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
            },

            // ── 热点 opcode：无条件跳转 ──
            .jump => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                if (ip_to_code.get(target_ip)) |target_off| {
                    const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(code.items.len));
                    try emit(&code, allocator, encJ(@intCast(delta)));
                } else {
                    const idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));
                    try pending_fixups.append(allocator, .{ .code_idx = idx, .target_ip = target_ip, .kind = 1 });
                }
            },

            // ── 热点 opcode：条件跳转 ──
            .jump_if_false, .jump_if_true => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try loadFrameBase(&code, allocator);
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, TAG_BOOLEAN_VAL);
                const bne_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                try regLbu(&code, allocator, GPR.t4, a, PAYLOAD_OFF);

                if (op == .jump_if_false) {
                    const beq_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBeq(GPR.t4, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(beq_idx));
                        code.items[beq_idx] = patchB(code.items[beq_idx], @intCast(delta));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = beq_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    const bne_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t4, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(bne_idx));
                        code.items[bne_idx] = patchB(code.items[bne_idx], @intCast(delta));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = bne_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                    code.items[bne_cold] = patchB(code.items[bne_cold], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：null 检查跳转 ──
            .jump_if_null, .jump_if_not_null => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try loadFrameBase(&code, allocator);
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);

                if (op == .jump_if_null) {
                    const beq_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBeq(GPR.t2, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(beq_idx));
                        code.items[beq_idx] = patchB(code.items[beq_idx], @intCast(delta));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = beq_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    const bne_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(bne_idx));
                        code.items[bne_idx] = patchB(code.items[bne_idx], @intCast(delta));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = bne_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }
            },

            // ── return_op / return_unit ──
            .return_op, .return_unit => {
                try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                try loadImm32(&code, allocator, GPR.a1, @intCast(ip));
                try emit(&code, allocator, encJalr(GPR.ra, GPR.s2, 0));
                const j_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));
                try pending_fixups.append(allocator, .{ .code_idx = j_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
            },

            // ── 热点 opcode：load_const（标量快速路径）──
            .load_const => {
                try loadFrameBase(&code, allocator);
                const const_addr: u64 = @intFromPtr(func.chunk.constants.items.ptr) + @as(u64, bx) * @sizeOf(value.Value);
                try loadImm64(&code, allocator, GPR.t3, const_addr);

                // 检查 dst(a) 是否标量
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t4, MAX_SCALAR_TAG);
                const bhi_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t4, GPR.t2, 0));

                // 检查 src(常量) 是否标量
                try emit(&code, allocator, encLbu(GPR.t2, GPR.t3, @intCast(TAG_OFF)));
                try loadImm32(&code, allocator, GPR.t4, MAX_SCALAR_TAG);
                const bhi_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t4, GPR.t2, 0));

                // 快速路径：拷贝 32 字节
                try emit(&code, allocator, encLd(GPR.t5, GPR.t3, 0));
                try regSd(&code, allocator, GPR.t5, a, 0);
                try emit(&code, allocator, encLd(GPR.t5, GPR.t3, 8));
                try regSd(&code, allocator, GPR.t5, a, 8);
                try emit(&code, allocator, encLd(GPR.t5, GPR.t3, 16));
                try regSd(&code, allocator, GPR.t5, a, 16);
                try emit(&code, allocator, encLd(GPR.t5, GPR.t3, 24));
                try regSd(&code, allocator, GPR.t5, a, 24);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
                if (bx < func.chunk.constants.items.len) {
                    reg_types[a] = switch (func.chunk.constants.items[bx]) {
                        .int => .i64,
                        .float => .f64,
                        .boolean => .boolean,
                        else => .unknown,
                    };
                }
            },

            // ── 热点 opcode：move / assign（标量快速路径）──
            .move, .assign => {
                try loadFrameBase(&code, allocator);

                try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, MAX_SCALAR_TAG);
                const bhi_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t3, GPR.t2, 0));

                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                const bhi_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t3, GPR.t2, 0));

                // 快速路径：拷贝 32 字节
                try regLd64(&code, allocator, GPR.t4, b, 0);
                try regSd(&code, allocator, GPR.t4, a, 0);
                try regLd64(&code, allocator, GPR.t4, b, 8);
                try regSd(&code, allocator, GPR.t4, a, 8);
                try regLd64(&code, allocator, GPR.t4, b, 16);
                try regSd(&code, allocator, GPR.t4, a, 16);
                try regLd64(&code, allocator, GPR.t4, b, 24);
                try regSd(&code, allocator, GPR.t4, a, 24);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
                if (b < reg_count) reg_types[a] = reg_types[b];
            },

            // ── 热点 opcode：load_unit / load_null ──
            .load_unit, .load_null => {
                try loadFrameBase(&code, allocator);
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, MAX_SCALAR_TAG);
                const bhi_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t3, GPR.t2, 0));

                const tag_val: i32 = if (op == .load_unit) TAG_UNIT_VAL else TAG_NULL_VAL;
                try loadImm32(&code, allocator, GPR.t4, tag_val);
                try regSb(&code, allocator, GPR.t4, a, TAG_OFF);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bhi_cold));
                    code.items[bhi_cold] = patchB(code.items[bhi_cold], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
            },

            // ── 热点 opcode：load_true / load_false ──
            .load_true, .load_false => {
                try loadFrameBase(&code, allocator);
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, MAX_SCALAR_TAG);
                const bhi_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t3, GPR.t2, 0));

                try loadImm32(&code, allocator, GPR.t4, TAG_BOOLEAN_VAL);
                try regSb(&code, allocator, GPR.t4, a, TAG_OFF);
                const payload_val: i32 = if (op == .load_true) 1 else 0;
                try loadImm32(&code, allocator, GPR.t4, payload_val);
                try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bhi_cold));
                    code.items[bhi_cold] = patchB(code.items[bhi_cold], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：cast / coerce ──
            .cast, .coerce => {
                const type_val = func.chunk.constants.items[c];
                const tname = type_val.string.bytes();

                const int_target: ?@import("value").IntType = blk: {
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
                const float_target: ?@import("value").FloatType = blk: {
                    if (std.mem.eql(u8, tname, "f32")) break :blk .f32;
                    if (std.mem.eql(u8, tname, "f64")) break :blk .f64;
                    break :blk null;
                };

                if (int_target == null and float_target == null) {
                    try emitCold(&code, allocator, &pending_fixups, ip);
                    continue;
                }

                try loadFrameBase(&code, allocator);

                if (int_target) |it| {
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                    const bne_not_int2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    // 拷贝 lo/hi，设置 int type
                    try regLd64(&code, allocator, GPR.t4, b, 0);
                    try regSd(&code, allocator, GPR.t4, a, 0);
                    try regLd64(&code, allocator, GPR.t4, b, 8);
                    try regSd(&code, allocator, GPR.t4, a, 8);
                    const type_byte: i32 = @intCast(@intFromEnum(it));
                    try loadImm32(&code, allocator, GPR.t4, type_byte);
                    try regSb(&code, allocator, GPR.t4, a, INT_TYPE_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                        code.items[bne_not_int1] = patchB(code.items[bne_not_int1], @intCast(d1));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = patchB(code.items[bne_not_int2], @intCast(d2));
                    }

                    // f64 → i64 路径：检查 b 的 tag == TAG_FLOAT 且 float_type == F64
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_FLOAT_VAL);
                    const bne_cold_f1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, b, FLOAT_TYPE_OFF);
                    try loadImm32(&code, allocator, GPR.t3, FLOAT_TYPE_F64_VAL);
                    const bne_cold_f2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    // f64 → i64 转换
                    try regFld(&code, allocator, FPR.ft0, b, FLOAT_BITS_OFF);
                    try emit(&code, allocator, encFcvtLD(GPR.t4, FPR.ft0));
                    try regSd(&code, allocator, GPR.t4, a, INT_LO_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);

                    const b_next2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold_f1, bne_cold_f2 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                    {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2));
                    }
                } else if (float_target) |ft| {
                    if (ft != .f64) {
                        try emitCold(&code, allocator, &pending_fixups, ip);
                        continue;
                    }

                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, b, INT_TYPE_OFF);
                    try loadImm32(&code, allocator, GPR.t3, INT_TYPE_I64_VAL);
                    const bne_cold2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_FLOAT_VAL);
                    const bne_cold3: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    // i64 → f64 转换
                    try regLd64(&code, allocator, GPR.t4, b, INT_LO_OFF);
                    try emit(&code, allocator, encFcvtDL(FPR.ft0, GPR.t4));
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold1, bne_cold2, bne_cold3 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                }
                reg_types[a] = if (int_target != null) .i64 else if (float_target != null) .f64 else .unknown;
            },

            // ── 热点 opcode：call（通过 rt_call_inline）──
            .call => {
                const func_idx_val = bx;
                try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                try loadImm32(&code, allocator, GPR.a1, @intCast(func_idx_val));
                try emit(&code, allocator, encAddi(GPR.a2, GPR.s1, @intCast(@as(u32, a) + 1)));
                const callee_arity: u32 = if (func_idx_val < functions.len) functions[func_idx_val].arity else 0;
                try loadImm32(&code, allocator, GPR.a3, @intCast(callee_arity));
                try emit(&code, allocator, encMv(GPR.a4, GPR.s1));
                try loadImm32(&code, allocator, GPR.a5, @intCast(a));
                try emit(&code, allocator, encJalr(GPR.ra, GPR.s3, 0));
                const bne_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBne(GPR.a0, GPR.x0, 0));
                try pending_fixups.append(allocator, .{ .code_idx = bne_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
                reg_types[a] = .unknown;
            },

            // ── 热点 opcode：index_op（数组索引快速路径）──
            .index_op => {
                try loadFrameBase(&code, allocator);

                // 检查 arr(b) tag == TAG_ARRAY
                try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, TAG_ARRAY_VAL);
                const bne_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                // 检查 idx(c) tag == TAG_INT
                try regLbu(&code, allocator, GPR.t2, c, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                const bne_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                // 检查 dst(a) 是标量
                try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                try loadImm32(&code, allocator, GPR.t3, MAX_SCALAR_TAG);
                const bhi_cold3: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t3, GPR.t2, 0));

                // 加载 index（先加载，避免与 t6 冲突）
                try regLd64(&code, allocator, GPR.t2, c, INT_LO_OFF);
                // 加载 ArrayValue*
                try regLd64(&code, allocator, GPR.t4, b, 0);
                // 加载 elements.ptr 和 elements.len
                try emit(&code, allocator, encLd(GPR.t5, GPR.t4, @intCast(ARRAY_ELEMS_PTR_OFF)));
                try emit(&code, allocator, encLd(GPR.t6, GPR.t4, @intCast(ARRAY_ELEMS_LEN_OFF)));

                // 边界检查: index < len (unsigned)
                const bhs_cold4: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBgeu(GPR.t2, GPR.t6, 0));

                // 计算元素地址: t3 = elements.ptr + index * 32
                try emit(&code, allocator, encSlli(GPR.t3, GPR.t2, 5));
                try emit(&code, allocator, encAdd(GPR.t3, GPR.t5, GPR.t3));

                // 检查元素是否标量
                try emit(&code, allocator, encLbu(GPR.t4, GPR.t3, @intCast(TAG_OFF)));
                try loadImm32(&code, allocator, GPR.t5, MAX_SCALAR_TAG);
                const bhi_cold5: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBltu(GPR.t5, GPR.t4, 0));

                // 拷贝 32 字节
                try emit(&code, allocator, encLd(GPR.t2, GPR.t3, 0));
                try regSd(&code, allocator, GPR.t2, a, 0);
                try emit(&code, allocator, encLd(GPR.t2, GPR.t3, 8));
                try regSd(&code, allocator, GPR.t2, a, 8);
                try emit(&code, allocator, encLd(GPR.t2, GPR.t3, 16));
                try regSd(&code, allocator, GPR.t2, a, 16);
                try emit(&code, allocator, encLd(GPR.t2, GPR.t3, 24));
                try regSd(&code, allocator, GPR.t2, a, 24);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bne_cold1, bne_cold2, bhi_cold3, bhs_cold4, bhi_cold5 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = patchB(code.items[bne_off], @intCast(d));
                }
                try emitCold(&code, allocator, &pending_fixups, ip);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d));
                }
            },

            // ── 热点 opcode：call_method（编译期解析方法名）──
            .call_method, .call_method_ic => {
                const method_val = func.chunk.constants.items[b];
                const mname = method_val.string.bytes();

                if (std.mem.eql(u8, mname, "len") and c == 0) {
                    // arr.len() → rt_array_len(vm, recv_slot, dst_slot)
                    try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                    try emit(&code, allocator, encAddi(GPR.a1, GPR.s1, @intCast(a)));
                    try emit(&code, allocator, encAddi(GPR.a2, GPR.s1, @intCast(a)));
                    try emit(&code, allocator, encJalr(GPR.ra, GPR.s5, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.a0, GPR.x0, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        code.items[bne_cold1] = patchB(code.items[bne_cold1], @intCast(d));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                } else if (std.mem.eql(u8, mname, "push") and c == 1) {
                    // arr.push(elem) → rt_array_push(vm, recv_slot, arg_slot, dst_slot)
                    try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                    try emit(&code, allocator, encAddi(GPR.a1, GPR.s1, @intCast(a)));
                    try emit(&code, allocator, encAddi(GPR.a2, GPR.s1, @intCast(@as(u32, a) + 1)));
                    try emit(&code, allocator, encAddi(GPR.a3, GPR.s1, @intCast(a)));
                    try emit(&code, allocator, encJalr(GPR.ra, GPR.s4, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.a0, GPR.x0, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        code.items[bne_cold1] = patchB(code.items[bne_cold1], @intCast(d));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d));
                    }
                } else {
                    try emitCold(&code, allocator, &pending_fixups, ip);
                }
            },

            else => {
                try emitCold(&code, allocator, &pending_fixups, ip);
            },
        }
    }

    // ════════ 函数 epilogue (= exit 标签) ════════
    exit_offset = @intCast(code.items.len);
    try emit(&code, allocator, encLd(GPR.ra, GPR.sp, 72));
    try emit(&code, allocator, encLd(GPR.s0, GPR.sp, 64));
    try emit(&code, allocator, encLd(GPR.s1, GPR.sp, 56));
    try emit(&code, allocator, encLd(GPR.s2, GPR.sp, 48));
    try emit(&code, allocator, encLd(GPR.s3, GPR.sp, 40));
    try emit(&code, allocator, encLd(GPR.s4, GPR.sp, 32));
    try emit(&code, allocator, encLd(GPR.s5, GPR.sp, 24));
    try emit(&code, allocator, encLd(GPR.s6, GPR.sp, 16));
    try emit(&code, allocator, encAddi(GPR.sp, GPR.sp, 80));
    try emit(&code, allocator, encRet());

    // ════════ 回填跳转目标 ════════
    for (pending_fixups.items) |fixup| {
        if (fixup.kind == 3) {
            // exit 跳转：跳到 exit_offset
            const delta: i64 = @as(i64, exit_offset) - @as(i64, @intCast(fixup.code_idx));
            if (fixup.code_idx < code.items.len) {
                // 检查是 J-type（return_op/return_unit 的 encJ）还是 B-type（emitCold/call 的 encBne）
                const inst_val = code.items[fixup.code_idx];
                const opcode = inst_val & 0x7F;
                if (opcode == 0b1101111) {
                    // J-type (JAL x0, ...)
                    code.items[fixup.code_idx] = patchJ(inst_val, @intCast(delta));
                } else {
                    // B-type (BNE/BEQ)
                    code.items[fixup.code_idx] = patchB(inst_val, @intCast(delta));
                }
            }
        } else {
            const target_off = ip_to_code.get(fixup.target_ip) orelse {
                return error.JitMissingJumpTarget;
            };
            const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(fixup.code_idx));
            switch (fixup.kind) {
                1 => code.items[fixup.code_idx] = encJ(@intCast(delta)),
                2 => code.items[fixup.code_idx] = patchB(code.items[fixup.code_idx], @intCast(delta)),
                else => {},
            }
        }
    }

    // ════════ 写入可执行内存 ════════
    const code_bytes = code.items.len * 4;
    const dst = exec_mem.alloc(code_bytes) orelse return error.JitOutOfExecMemory;
    for (code.items, 0..) |enc, i| {
        const ptr: *u32 = @ptrCast(@alignCast(dst + i * 4));
        ptr.* = enc;
    }

    return @intFromPtr(dst);
}

// ════════════════════════════════════════════════════════════════════
// JitBackend 接口实现（桥接模式）
// ════════════════════════════════════════════════════════════════════

/// RISC-V 64 JitBackend 实例（桥接模式）。
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

    if (@import("mod.zig").containsClosureOps(func)) {
        engine.failed[func_idx] = true;
        return null;
    }

    var exec_mem = mem.allocExec(32 * 1024) catch {
        engine.failed[func_idx] = true;
        return null;
    };
    errdefer exec_mem.deinit();

    const rt_step_addr = @intFromPtr(&runtime.bridge.rt_step);
    const rt_call_inline_addr = @intFromPtr(&runtime.bridge.rt_call_inline);
    const rt_array_push_addr = @intFromPtr(&runtime.bridge.rt_array_push);
    const rt_array_len_addr = @intFromPtr(&runtime.bridge.rt_array_len);

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
        .return_type = 0xFF,
        .exec_mem = exec_mem,
        .bridge = true,
    };

    return @ptrCast(&engine.compiled[func_idx].?);
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