//! RISC-V 32 (RV32G) 代码生成器。
//!
//! 将字节码编译为 RISC-V 32 机器码，写入可执行内存。
//! 支持 i64/f64 算术/比较、分支/循环控制流。
//! 使用桥接模式：热点 opcode 内联生成原生代码，冷门 opcode 通过 rt_step 桥接。
//!
//! RV32 与 RV64 的关键差异：
//! - 寄存器宽度 32 位，指针/地址为 32 位
//! - 移位立即数 shamt 为 5 位（RV64 为 6 位）
//! - 无 LD/SD 指令，使用 LW/SW 或两次 LW/SW 实现 64 位 load/store
//! - 无 FCVT.L.D/FCVT.D.L（64 位整数↔浮点转换），i64↔f64 转换回退 rt_step
//! - 64 位算术通过 32 位指令序列实现（add/sub 带进位，mul 用 MULH 等）
//! - FLD/FSD 仍可使用（D 扩展在 RV32 上支持 64 位浮点 load/store）

const std = @import("std");
const backend_mod = @import("../backend.zig");
const mem = @import("../mem.zig");
const value = @import("value");
const reg_vm_mod = @import("reg_vm");
const reg_chunk = reg_vm_mod.reg_chunk_mod;
const reg_opcode = reg_vm_mod.reg_opcode;
const runtime = @import("../runtime/mod.zig");
const RegVM = reg_vm_mod.reg_vm.RegVM;

/// RISC-V 32 通用寄存器编号（x0-x31），与 RV64 相同。
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

/// RISC-V 32 浮点寄存器编号（f0-f31），与 RV64 相同。
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
// RISC-V 32 指令编码辅助函数
// 所有编码遵循 RISC-V ISA Manual (RV32I + M + D)。
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
/// 参数 imm13 为字节偏移量（遵循 RISC-V ISA 规范，立即数字段以字节为单位）。
fn encB(imm13: i13, rs1: u8, rs2: u8, funct3: u3, opcode: u7) u32 {
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
/// 参数 imm21 为字节偏移量（遵循 RISC-V ISA 规范，立即数字段以字节为单位）。
fn encJtype(imm21: i21, rd: u8, opcode: u7) u32 {
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

// ── RV32I 算术指令 (R-type, opcode=0b0110011) ──

/// ADD rd, rs1, rs2
fn encAdd(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000000, rd, 0b000, rs1, rs2, 0b0110011);
}

/// SUB rd, rs1, rs2
fn encSub(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0100000, rd, 0b000, rs1, rs2, 0b0110011);
}

/// MUL rd, rs1, rs2 (M extension, 低 32 位)
fn encMul(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b000, rs1, rs2, 0b0110011);
}

/// MULH rd, rs1, rs2 (M extension, 有符号×有符号的高 32 位)
fn encMulh(rd: u8, rs1: u8, rs2: u8) u32 {
    return encR(0b0000001, rd, 0b001, rs1, rs2, 0b0110011);
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

// ── RV32I 立即数指令 (I-type, opcode=0b0010011) ──

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

/// SLLI rd, rs1, shamt (RV32: 5-bit shift amount)
/// 编码: 0000000 shamt[4:0] rs1 001 rd 0010011
fn encSlli(rd: u8, rs1: u8, shamt: u5) u32 {
    return (@as(u32, 0b0000000) << 25) |
        (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b001 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

/// SRLI rd, rs1, shamt (logical right shift, RV32: 5-bit shamt)
/// 编码: 0000000 shamt[4:0] rs1 101 rd 0010011
fn encSrli(rd: u8, rs1: u8, shamt: u5) u32 {
    return (@as(u32, 0b0000000) << 25) |
        (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b101 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

/// SRAI rd, rs1, shamt (RV32: 算术右移, 5-bit shamt)
/// 编码: 0100000 shamt[4:0] rs1 101 rd 0010011
fn encSrai(rd: u8, rs1: u8, shamt: u5) u32 {
    return (@as(u32, 0b0100000) << 25) |
        (@as(u32, shamt) << 20) |
        (@as(u32, rs1) << 15) |
        (0b101 << 12) |
        (@as(u32, rd) << 7) |
        0b0010011;
}

// ── RV32I load/store 指令 ──

/// LW rd, imm12(rs1) (load 32-bit signed)
fn encLw(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b010, rs1, 0b0000011);
}

/// LBU rd, imm12(rs1) (load byte unsigned)
fn encLbu(rd: u8, rs1: u8, imm12: i12) u32 {
    return encI(imm12, rd, 0b100, rs1, 0b0000011);
}

/// SW rs2, imm12(rs1) (store 32-bit)
fn encSw(rs2: u8, rs1: u8, imm12: i12) u32 {
    return encS(imm12, rs2, rs1, 0b010, 0b0100011);
}

/// SB rs2, imm12(rs1) (store byte)
fn encSb(rs2: u8, rs1: u8, imm12: i12) u32 {
    return encS(imm12, rs2, rs1, 0b000, 0b0100011);
}

// ── RV32I 分支指令 (B-type, opcode=0b1100011) ──

/// BEQ rs1, rs2, imm13
fn encBeq(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b000, 0b1100011);
}

/// BNE rs1, rs2, imm13
fn encBne(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b001, 0b1100011);
}

/// BLT rs1, rs2, imm13 (signed)
fn encBlt(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b100, 0b1100011);
}

/// BGE rs1, rs2, imm13 (signed)
fn encBge(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b101, 0b1100011);
}

/// BLTU rs1, rs2, imm13 (unsigned)
fn encBltu(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b110, 0b1100011);
}

/// BGEU rs1, rs2, imm13 (unsigned)
fn encBgeu(rs1: u8, rs2: u8, imm13: i13) u32 {
    return encB(imm13, rs1, rs2, 0b111, 0b1100011);
}

// ── RV32I 跳转指令 ──

/// JAL rd, imm21 (opcode=0b1101111)
fn encJal(rd: u8, imm21: i21) u32 {
    return encJtype(imm21, rd, 0b1101111);
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
fn encJ(imm21: i21) u32 {
    return encJal(GPR.x0, imm21);
}

// ── RV32D 浮点指令 (D extension) ──
// FLD/FSD 在 RV32 上可用，操作 64 位双精度浮点。

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

// ── RV32F 单精度浮点指令 (F extension) ──

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

// ── B-type / J-type 回填辅助 ──
// 回填采用"解码 + 重新编码"方式：从占位指令中提取 rs1/rs2/funct3/opcode，
// 再用 encB/encJtype 一次性生成正确的完整指令，无需保留位掩码。

/// 从 B-type 指令中提取 funct3 字段。
fn bFunct3(inst: u32) u3 {
    return @truncate((inst >> 12) & 0x7);
}

/// 从 B-type 指令中提取 rs1 字段。
fn bRs1(inst: u32) u8 {
    return @truncate((inst >> 15) & 0x1F);
}

/// 从 B-type 指令中提取 rs2 字段。
fn bRs2(inst: u32) u8 {
    return @truncate((inst >> 20) & 0x1F);
}

/// 回填 B-type 跳转指令：解码占位指令的寄存器/功能位，用新偏移重新编码。
/// 参数 imm13 为字节偏移量（遵循 RISC-V ISA 规范）。
fn reencB(inst: u32, imm13: i13) u32 {
    return encB(imm13, bRs1(inst), bRs2(inst), bFunct3(inst), 0b1100011);
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

/// 加载 32 位地址到寄存器（RV32 指针为 32 位）。
fn loadAddr(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, addr: usize) !void {
    const v32: i32 = @bitCast(@as(u32, @truncate(addr)));
    try loadImm32(buf, alloc, rd, v32);
}

// ════════════════════════════════════════════════════════════════════
// 桥接协作模式：直接从字节码生成 RISC-V 32 机器码
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
// s6 (x22) = 临时（carry/borrow，用于 64 位算术）
// s7 (x23) = 临时（中间结果，用于 64 位算术）
// t0 (x5)  = 临时（reg_pool_ptr）
// t1 (x6)  = 临时（frame_base = reg_pool_ptr + base*32）
// t2 (x7)  = 临时（tag/立即数）
// t3 (x28) = 临时（c.hi 或其他）
// t4 (x29) = 临时（b.lo 或 result.lo）
// t5 (x30) = 临时（b.hi 或 result.hi）
// t6 (x31) = 临时（c.lo 或地址计算）
// ft0(f0)  = 浮点临时 0（scratch，未知类型路径用 + 32 字节拷贝用）
// ft1(f1)  = 浮点临时 1（scratch，未知类型路径用）
// ft2-ft5  = FPR 缓存池（已知 f64 路径用，caller-saved）
// a0 (x10) = C 调用参数 0 / 返回值
// a1 (x11) = C 调用参数 1

/// FPR 缓存池：用于已知 f64 路径的输入操作数缓存。
/// 选择 ft2-ft5（caller-saved），保留 ft0/ft1 作为未知类型路径的 scratch。
const FPR_POOL = [_]u8{
    FPR.ft2, FPR.ft3, FPR.ft4, FPR.ft5,
};

const FPR_NONE: i8 = -1;

/// FPR 常驻状态：跟踪 reg_pool 槽位 → FPR 缓存池的映射。
const FprState = struct {
    fpr_map: []i8, // reg_count × 1
    fpr_owner: [FPR_POOL.len]u8, // pool_idx → reg（0xFF=空闲）

    fn init(allocator: std.mem.Allocator, reg_count: usize) !FprState {
        const m = try allocator.alloc(i8, reg_count);
        @memset(m, FPR_NONE);
        return .{ .fpr_map = m, .fpr_owner = [_]u8{0xFF} ** FPR_POOL.len };
    }

    fn deinit(self: *FprState, allocator: std.mem.Allocator) void {
        allocator.free(self.fpr_map);
    }

    /// 判断 reg 是否常驻 FPR
    fn isResident(self: *const FprState, reg: u8) bool {
        return reg < self.fpr_map.len and self.fpr_map[reg] != FPR_NONE;
    }

    /// 获取 reg 对应的 FPR 编号；调用方需先 isResident 判断
    fn getFpr(self: *const FprState, reg: u8) u8 {
        const idx: usize = @intCast(self.fpr_map[reg]);
        return FPR_POOL[idx];
    }

    /// 将 reg 标记为常驻到 pool_idx 对应的 FPR（替换原 owner）
    fn setResident(self: *FprState, reg: u8, pool_idx: usize) void {
        const old_owner = self.fpr_owner[pool_idx];
        if (old_owner != 0xFF and old_owner < self.fpr_map.len) {
            self.fpr_map[old_owner] = FPR_NONE;
        }
        if (reg < self.fpr_map.len and self.fpr_map[reg] != FPR_NONE) {
            const old_idx: usize = @intCast(self.fpr_map[reg]);
            self.fpr_owner[old_idx] = 0xFF;
        }
        self.fpr_map[reg] = @intCast(pool_idx);
        self.fpr_owner[pool_idx] = reg;
    }

    /// 驱逐 reg（如果常驻），使其仅在内存
    fn evict(self: *FprState, reg: u8) void {
        if (reg >= self.fpr_map.len) return;
        const idx = self.fpr_map[reg];
        if (idx == FPR_NONE) return;
        self.fpr_owner[@intCast(idx)] = 0xFF;
        self.fpr_map[reg] = FPR_NONE;
    }

    /// 分配一个空闲 pool_idx；若无空闲返回 null
    fn allocSlot(self: *const FprState) ?usize {
        var i: usize = 0;
        while (i < FPR_POOL.len) : (i += 1) {
            if (self.fpr_owner[i] == 0xFF) return i;
        }
        return null;
    }

    /// 清空所有 FPR 映射（跳转目标/rt_step 调用前重置）
    fn invalidateAll(self: *FprState) void {
        @memset(self.fpr_map, FPR_NONE);
        self.fpr_owner = [_]u8{0xFF} ** FPR_POOL.len;
    }
};

/// 确保 reg 的 f64 bits 加载到某个 FPR，返回 FPR 编号。
fn emitEnsureFpr(
    code: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    fpr: *FprState,
    reg: u8,
    protect_reg: u8,
) !u8 {
    if (fpr.isResident(reg)) return fpr.getFpr(reg);
    const slot = fpr.allocSlot() orelse blk: {
        var evict_idx: usize = 0;
        var found_evict = false;
        var i: usize = 0;
        while (i < FPR_POOL.len) : (i += 1) {
            const owner = fpr.fpr_owner[i];
            if (owner == 0xFF) continue;
            if (owner == protect_reg) continue;
            evict_idx = i;
            found_evict = true;
            break;
        }
        if (!found_evict) {
            evict_idx = 0;
        }
        const victim = fpr.fpr_owner[evict_idx];
        if (victim != 0xFF) {
            fpr.evict(victim);
        }
        break :blk evict_idx;
    };
    const fpr_reg = FPR_POOL[slot];
    // 从 frame_base(t1) 加载 reg.float.bits 到 fpr_reg
    const off: i32 = @intCast(@as(u32, reg) * 32 + FLOAT_BITS_OFF);
    if (off >= -2048 and off <= 2047) {
        try code.append(allocator, encFld(fpr_reg, GPR.t1, @intCast(off)));
    } else {
        try loadImm32(code, allocator, GPR.a2, off);
        try code.append(allocator, encAdd(GPR.a2, GPR.t1, GPR.a2));
        try code.append(allocator, encFld(fpr_reg, GPR.a2, 0));
    }
    fpr.setResident(reg, slot);
    return fpr_reg;
}

/// 桥接模式编译：直接从字节码生成 RISC-V 32 机器码。
///
/// JIT 函数签名: fn(vm: *RegVM, base: usize) callconv(.c) void
/// 热点 opcode（i64/f64 算术/比较/跳转）生成内联原生代码。
/// 冷门 opcode 通过 rt_step 桥接函数委托 VM 单步执行。
///
/// RV32 上 64 位算术通过 32 位指令序列实现：
/// - i64 add/sub: 带进位/借位的双字运算
/// - i64 mul: MUL + MULH + 交叉乘加
/// - i64 div/rem: 回退 rt_step（软件除法太复杂）
/// - i64 比较: 高字优先 + 低字无符号比较
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

    // ── FPR 常驻状态 ──
    var fpr_state = try FprState.init(allocator, reg_count);
    defer fpr_state.deinit(allocator);
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

    // ── 辅助：从 frame_base(t1) 加载 32 位寄存器字段 ──
    const regLw = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encLw(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encLw(rd, GPR.a2, 0));
            }
        }
    }.call;
    const regLbu = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encLbu(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encLbu(rd, GPR.a2, 0));
            }
        }
    }.call;
    const regSb = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs2: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encSb(rs2, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encSb(rs2, GPR.a2, 0));
            }
        }
    }.call;

    // ── 辅助：64 位 load/store（两次 LW/SW）──
    // 加载 64 位值到 rd_lo（低 32 位）和 rd_hi（高 32 位）
    const regLd64Pair = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd_lo: u8, rd_hi: u8, reg_idx: u8, field_off: u32) !void {
            const off_lo: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            const off_hi: i32 = off_lo + 4;
            if (off_lo >= -2048 and off_lo <= 2047) {
                try emit(buf, alloc, encLw(rd_lo, GPR.t1, @intCast(off_lo)));
                try emit(buf, alloc, encLw(rd_hi, GPR.t1, @intCast(off_hi)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off_lo);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encLw(rd_lo, GPR.a2, 0));
                try emit(buf, alloc, encLw(rd_hi, GPR.a2, 4));
            }
        }
    }.call;
    // 存储 64 位值从 rs_lo（低 32 位）和 rs_hi（高 32 位）
    const regSd64Pair = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs_lo: u8, rs_hi: u8, reg_idx: u8, field_off: u32) !void {
            const off_lo: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            const off_hi: i32 = off_lo + 4;
            if (off_lo >= -2048 and off_lo <= 2047) {
                try emit(buf, alloc, encSw(rs_lo, GPR.t1, @intCast(off_lo)));
                try emit(buf, alloc, encSw(rs_hi, GPR.t1, @intCast(off_hi)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off_lo);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encSw(rs_lo, GPR.a2, 0));
                try emit(buf, alloc, encSw(rs_hi, GPR.a2, 4));
            }
        }
    }.call;

    // ── 辅助：浮点寄存器访问（FLD/FSD，RV32 可用）──
    const regFld = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encFld(rd, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encFld(rd, GPR.a2, 0));
            }
        }
    }.call;
    const regFsd = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rs2: u8, reg_idx: u8, field_off: u32) !void {
            const off: i32 = @intCast(@as(u32, reg_idx) * 32 + field_off);
            if (off >= -2048 and off <= 2047) {
                try emit(buf, alloc, encFsd(rs2, GPR.t1, @intCast(off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.t1, GPR.a2));
                try emit(buf, alloc, encFsd(rs2, GPR.a2, 0));
            }
        }
    }.call;

    // ── 辅助：32 字节拷贝（使用 FLD/FSD，4 对指令）──
    const regCopy32 = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, src_base: u8, dst_idx: u8) !void {
            // 从 src_base 地址加载 4×8 字节，存入 dst 寄存器槽
            try emit(buf, alloc, encFld(FPR.ft0, src_base, 0));
            try regFsd(buf, alloc, FPR.ft0, dst_idx, 0);
            try emit(buf, alloc, encFld(FPR.ft0, src_base, 8));
            try regFsd(buf, alloc, FPR.ft0, dst_idx, 8);
            try emit(buf, alloc, encFld(FPR.ft0, src_base, 16));
            try regFsd(buf, alloc, FPR.ft0, dst_idx, 16);
            try emit(buf, alloc, encFld(FPR.ft0, src_base, 24));
            try regFsd(buf, alloc, FPR.ft0, dst_idx, 24);
        }
    }.call;

    // ── 辅助：加载 reg_pool_ptr 到 t0，计算 frame_base 到 t1 ──
    const loadFrameBase = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // t0 = vm->reg_pool (32-bit slice pointer at offset 0)
            const pool_off: i32 = @intCast(REG_POOL_PTR_OFFSET);
            if (pool_off >= -2048 and pool_off <= 2047) {
                try emit(buf, alloc, encLw(GPR.t0, GPR.s0, @intCast(pool_off)));
            } else {
                try loadImm32(buf, alloc, GPR.a2, pool_off);
                try emit(buf, alloc, encAdd(GPR.a2, GPR.s0, GPR.a2));
                try emit(buf, alloc, encLw(GPR.t0, GPR.a2, 0));
            }
            // t1 = t0 + s1 * 32 (s1 << 5)
            try emit(buf, alloc, encSlli(GPR.t1, GPR.s1, 5));
            try emit(buf, alloc, encAdd(GPR.t1, GPR.t0, GPR.t1));
        }
    }.call;

    // ── 辅助：生成 cold 路径（rt_step 调用 + exit 检查）──
    const emitCold = struct {
        fn call(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, pfixups: *std.ArrayListUnmanaged(Fixup), ip: u32, fpr: *FprState) !void {
            // a0 = vm
            try emit(buf, alloc, encMv(GPR.a0, GPR.s0));
            // a1 = ip
            try loadImm32(buf, alloc, GPR.a1, @intCast(ip));
            // rt_step 会 clobber caller-saved FPR，缓存必须失效
            fpr.invalidateAll();
            // JALR ra, s2, 0 (call rt_step)
            try emit(buf, alloc, encJalr(GPR.ra, GPR.s2, 0));
            // BEQ a0, x0, +8 (if false, skip JAL; continue execution)
            // JAL x0, exit (占位, J-type 有 ±1MB 范围，规避 B-type ±4KB 限制)
            try emit(buf, alloc, encBeq(GPR.a0, GPR.x0, 8));
            const j_exit: u32 = @intCast(buf.items.len);
            try emit(buf, alloc, encJ(0));
            try pfixups.append(alloc, .{ .code_idx = j_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
        }
    }.call;

    // ── 辅助：64 位算术序列 ──
    // 操作数约定：t4=b.lo, t5=b.hi, t6=c.lo, t3=c.hi
    // 结果约定：t4=lo, t5=hi
    // s6=carry/borrow temp, s7=intermediate temp
    const arith64 = struct {
        // 64 位加法: t4:t5 = t4:t5 + t6:t3
        fn add(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            try emit(buf, alloc, encAdd(GPR.t4, GPR.t4, GPR.t6)); // lo = b.lo + c.lo
            try emit(buf, alloc, encSltu(GPR.s6, GPR.t4, GPR.t6)); // carry = (lo < c.lo)
            try emit(buf, alloc, encAdd(GPR.t5, GPR.t5, GPR.t3)); // hi = b.hi + c.hi
            try emit(buf, alloc, encAdd(GPR.t5, GPR.t5, GPR.s6)); // hi += carry
        }
        // 64 位减法: t4:t5 = t4:t5 - t6:t3
        fn sub(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            try emit(buf, alloc, encSltu(GPR.s6, GPR.t4, GPR.t6)); // borrow = (b.lo < c.lo)
            try emit(buf, alloc, encSub(GPR.t4, GPR.t4, GPR.t6)); // lo = b.lo - c.lo
            try emit(buf, alloc, encSub(GPR.t5, GPR.t5, GPR.t3)); // hi = b.hi - c.hi
            try emit(buf, alloc, encSub(GPR.t5, GPR.t5, GPR.s6)); // hi -= borrow
        }
        // 64 位乘法: t4:t5 = t4:t5 * t6:t3 (signed)
        // 使用 s7 存储中间结果
        fn mul(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // s7 = b.lo * c.lo (低 32 位 = result.lo)
            try emit(buf, alloc, encMul(GPR.s7, GPR.t4, GPR.t6));
            // s6 = MULH(b.lo, c.lo) (高 32 位 of b.lo*c.lo)
            try emit(buf, alloc, encMulh(GPR.s6, GPR.t4, GPR.t6));
            // s6 += b.lo * c.hi (低 32 位)
            try emit(buf, alloc, encMul(GPR.t4, GPR.t4, GPR.t3));
            try emit(buf, alloc, encAdd(GPR.s6, GPR.s6, GPR.t4));
            // s6 += b.hi * c.lo (低 32 位)
            try emit(buf, alloc, encMul(GPR.t4, GPR.t5, GPR.t6));
            try emit(buf, alloc, encAdd(GPR.s6, GPR.s6, GPR.t4));
            // 结果: s7=lo, s6=hi → 移到 t4, t5
            try emit(buf, alloc, encMv(GPR.t4, GPR.s7));
            try emit(buf, alloc, encMv(GPR.t5, GPR.s6));
        }
        // 64 位取反: t4:t5 = -t4:t5
        fn neg(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // 0 - t4:t5
            try emit(buf, alloc, encSltu(GPR.s6, GPR.x0, GPR.t4)); // borrow = (0 < b.lo) = (b.lo != 0)
            try emit(buf, alloc, encSub(GPR.t4, GPR.x0, GPR.t4)); // lo = -b.lo
            try emit(buf, alloc, encSub(GPR.t5, GPR.x0, GPR.t5)); // hi = -b.hi
            try emit(buf, alloc, encSub(GPR.t5, GPR.t5, GPR.s6)); // hi -= borrow
        }
        // 64 位按位运算 (and/or/xor): t4:t5 = t4:t5 OP t6:t3
        fn bitwise(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, op: reg_opcode.Op) !void {
            switch (op) {
                .bit_and => {
                    try emit(buf, alloc, encAnd(GPR.t4, GPR.t4, GPR.t6));
                    try emit(buf, alloc, encAnd(GPR.t5, GPR.t5, GPR.t3));
                },
                .bit_or => {
                    try emit(buf, alloc, encOr(GPR.t4, GPR.t4, GPR.t6));
                    try emit(buf, alloc, encOr(GPR.t5, GPR.t5, GPR.t3));
                },
                .bit_xor => {
                    try emit(buf, alloc, encXor(GPR.t4, GPR.t4, GPR.t6));
                    try emit(buf, alloc, encXor(GPR.t5, GPR.t5, GPR.t3));
                },
                else => unreachable,
            }
        }
        // 64 位比较 eq: t4 = (t4:t5 == t6:t3) ? 1 : 0
        fn cmpEq(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            try emit(buf, alloc, encXor(GPR.t4, GPR.t4, GPR.t6)); // lo xor
            try emit(buf, alloc, encXor(GPR.t5, GPR.t5, GPR.t3)); // hi xor
            try emit(buf, alloc, encOr(GPR.t4, GPR.t4, GPR.t5)); // | 
            try emit(buf, alloc, encSeqz(GPR.t4, GPR.t4)); // (== 0) ? 1 : 0
        }
        // 64 位比较 neq: t4 = (t4:t5 != t6:t3) ? 1 : 0
        fn cmpNeq(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            try emit(buf, alloc, encXor(GPR.t4, GPR.t4, GPR.t6));
            try emit(buf, alloc, encXor(GPR.t5, GPR.t5, GPR.t3));
            try emit(buf, alloc, encOr(GPR.t4, GPR.t4, GPR.t5));
            try emit(buf, alloc, encSnez(GPR.t4, GPR.t4));
        }
        // 64 位有符号比较 lt: t4 = (t4:t5 < t6:t3) ? 1 : 0 (signed)
        // 无分支实现：高位不同用 SLT，高位相同用 SLTU 比较低位
        fn cmpLt(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // s6 = (b.hi != c.hi) ? 1 : 0
            try emit(buf, alloc, encXor(GPR.s6, GPR.t5, GPR.t3));
            try emit(buf, alloc, encSnez(GPR.s6, GPR.s6));
            // s7 = (b.hi < c.hi) signed
            try emit(buf, alloc, encSlt(GPR.s7, GPR.t5, GPR.t3));
            // t2 = (b.lo < c.lo) unsigned
            try emit(buf, alloc, encSltu(GPR.t2, GPR.t4, GPR.t6));
            // result = (s6 != 0) ? s7 : t2
            // 用 NEG 将 0/1 转为 0/-1 掩码
            try emit(buf, alloc, encNeg(GPR.s6, GPR.s6)); // s6 = 0 or 0xFFFFFFFF
            try emit(buf, alloc, encAnd(GPR.s7, GPR.s7, GPR.s6)); // s7 & mask
            try emit(buf, alloc, encNot(GPR.s6, GPR.s6)); // ~mask
            try emit(buf, alloc, encAnd(GPR.t2, GPR.t2, GPR.s6)); // t2 & ~mask
            try emit(buf, alloc, encOr(GPR.t4, GPR.s7, GPR.t2)); // result
        }
        // 64 位有符号比较 le: t4 = (t4:t5 <= t6:t3) ? 1 : 0
        // le = !(b > c) = !(c < b) = !cmpLt(c, b)
        fn cmpLe(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator) !void {
            // 交换 b 和 c 后做 lt，再取反
            // t4↔t6, t5↔t3
            try emit(buf, alloc, encXor(GPR.t4, GPR.t4, GPR.t6));
            try emit(buf, alloc, encXor(GPR.t6, GPR.t4, GPR.t6));
            try emit(buf, alloc, encXor(GPR.t4, GPR.t4, GPR.t6));
            try emit(buf, alloc, encXor(GPR.t5, GPR.t5, GPR.t3));
            try emit(buf, alloc, encXor(GPR.t3, GPR.t5, GPR.t3));
            try emit(buf, alloc, encXor(GPR.t5, GPR.t5, GPR.t3));
            // 现在 t4:t5 = c, t6:t3 = b，做 lt(c, b)
            try cmpLt(buf, alloc);
            // 取反
            try emit(buf, alloc, encXori(GPR.t4, GPR.t4, 1));
        }
    };

    // ════════ 函数 prologue ════════
    // 保存 ra + s0-s7 = 9 寄存器，48 字节帧（16 字节对齐）
    // scratch 区 0-7 用于 FPR↔GPR 中转（FSD/FLD）
    try emit(&code, allocator, encAddi(GPR.sp, GPR.sp, -48));
    try emit(&code, allocator, encSw(GPR.ra, GPR.sp, 40));
    try emit(&code, allocator, encSw(GPR.s0, GPR.sp, 36));
    try emit(&code, allocator, encSw(GPR.s1, GPR.sp, 32));
    try emit(&code, allocator, encSw(GPR.s2, GPR.sp, 28));
    try emit(&code, allocator, encSw(GPR.s3, GPR.sp, 24));
    try emit(&code, allocator, encSw(GPR.s4, GPR.sp, 20));
    try emit(&code, allocator, encSw(GPR.s5, GPR.sp, 16));
    try emit(&code, allocator, encSw(GPR.s6, GPR.sp, 12));
    try emit(&code, allocator, encSw(GPR.s7, GPR.sp, 8));

    // s0 = vm, s1 = base
    try emit(&code, allocator, encMv(GPR.s0, GPR.a0));
    try emit(&code, allocator, encMv(GPR.s1, GPR.a1));

    // 加载 rt_* 地址（RV32 地址为 32 位）
    try loadAddr(&code, allocator, GPR.s2, rt_step_addr);
    try loadAddr(&code, allocator, GPR.s3, rt_call_inline_addr);
    try loadAddr(&code, allocator, GPR.s4, rt_array_push_addr);
    try loadAddr(&code, allocator, GPR.s5, rt_array_len_addr);

    // ════════ 函数体：遍历字节码 ════════
    const instructions = func.chunk.code.items;

    var ip: u32 = 0;
    while (ip < instructions.len) : (ip += 1) {
        try ip_to_code.put(ip, @intCast(code.items.len));

        if (ip > 0 and jump_targets.contains(ip)) {
            @memset(reg_types, .unknown);
            fpr_state.invalidateAll();
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
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                if (b_known_i64 and c_known_i64) {
                    try loadFrameBase(&code, allocator);
                    // div/mod 在 RV32 上需要软件除法，回退 rt_step
                    if (op == .div or op == .mod) {
                        try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
                        reg_types[a] = .unknown;
                        continue;
                    }
                    // 加载 b 到 t4(lo)/t5(hi), c 到 t6(lo)/t3(hi)
                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try regLd64Pair(&code, allocator, GPR.t6, GPR.t3, c, INT_LO_OFF);
                    switch (op) {
                        .add => try arith64.add(&code, allocator),
                        .sub => try arith64.sub(&code, allocator),
                        .mul => try arith64.mul(&code, allocator),
                        .bit_and, .bit_or, .bit_xor => try arith64.bitwise(&code, allocator, op),
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd64Pair(&code, allocator, GPR.t4, GPR.t5, a, INT_LO_OFF);
                    reg_types[a] = .i64;
                } else if (b_known_f64 and c_known_f64 and op != .mod and op != .bit_and and op != .bit_or and op != .bit_xor) {
                    // ── 类型已知 f64：用 FPR 缓存池加载，跳过 tag 检查 ──
                    try loadFrameBase(&code, allocator);
                    fpr_state.evict(a);
                    const fpr_b = try emitEnsureFpr(&code, allocator, &fpr_state, b, 0xFF);
                    const fpr_c = try emitEnsureFpr(&code, allocator, &fpr_state, c, b);
                    switch (op) {
                        .add => try emit(&code, allocator, encFaddD(FPR.ft0, fpr_b, fpr_c)),
                        .sub => try emit(&code, allocator, encFsubD(FPR.ft0, fpr_b, fpr_c)),
                        .mul => try emit(&code, allocator, encFmulD(FPR.ft0, fpr_b, fpr_c)),
                        .div => try emit(&code, allocator, encFdivD(FPR.ft0, fpr_b, fpr_c)),
                        else => unreachable,
                    }
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);
                    if (a == b) fpr_state.evict(b);
                    if (a == c) fpr_state.evict(c);
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

                    // div/mod 回退 rt_step
                    if (op == .div or op == .mod) {
                        // 跳到 cold
                        const not_int_target_div: u32 = @intCast(code.items.len);
                        {
                            const d1: i64 = @as(i64, not_int_target_div) - @as(i64, @intCast(bne_not_int1));
                            code.items[bne_not_int1] = reencB(code.items[bne_not_int1], @intCast(d1 << 2));
                            const d2: i64 = @as(i64, not_int_target_div) - @as(i64, @intCast(bne_not_int2));
                            code.items[bne_not_int2] = reencB(code.items[bne_not_int2], @intCast(d2 << 2));
                        }
                        try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
                        reg_types[a] = .unknown;
                        continue;
                    }

                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try regLd64Pair(&code, allocator, GPR.t6, GPR.t3, c, INT_LO_OFF);
                    switch (op) {
                        .add => try arith64.add(&code, allocator),
                        .sub => try arith64.sub(&code, allocator),
                        .mul => try arith64.mul(&code, allocator),
                        .bit_and, .bit_or, .bit_xor => try arith64.bitwise(&code, allocator, op),
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd64Pair(&code, allocator, GPR.t4, GPR.t5, a, INT_LO_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                        code.items[bne_not_int1] = reencB(code.items[bne_not_int1], @intCast(d1 << 2));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = reencB(code.items[bne_not_int2], @intCast(d2 << 2));
                    }

                    var b_next2: u32 = 0;
                    if (op != .mod and op != .bit_and and op != .bit_or and op != .bit_xor) {
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
                            code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                        }
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                    if (op != .mod and op != .bit_and and op != .bit_or and op != .bit_xor) {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2 << 2));
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
                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try arith64.neg(&code, allocator);
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd64Pair(&code, allocator, GPR.t4, GPR.t5, a, INT_LO_OFF);
                    reg_types[a] = .i64;
                } else if (b_known_f64) {
                    // ── 类型已知 f64：用 FPR 缓存池加载，直接浮点取反 ──
                    fpr_state.evict(a);
                    const fpr_b = try emitEnsureFpr(&code, allocator, &fpr_state, b, 0xFF);
                    try emit(&code, allocator, encFnegD(FPR.ft0, fpr_b));
                    try regFsd(&code, allocator, FPR.ft0, a, FLOAT_BITS_OFF);
                    try loadImm32(&code, allocator, GPR.t2, TAG_FLOAT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, FLOAT_TYPE_F64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, FLOAT_TYPE_OFF);
                    if (a == b) fpr_state.evict(b);
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：i64 → f64 → cold 三层路径 ──
                    // i64 快速路径
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try arith64.neg(&code, allocator);
                    try loadImm32(&code, allocator, GPR.t2, TAG_INT_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t2, INT_TYPE_I64_VAL);
                    try regSb(&code, allocator, GPR.t2, a, INT_TYPE_OFF);
                    try regSd64Pair(&code, allocator, GPR.t4, GPR.t5, a, INT_LO_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int));
                        code.items[bne_not_int] = reencB(code.items[bne_not_int], @intCast(d << 2));
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
                        code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                    {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2 << 2));
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
                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try regLd64Pair(&code, allocator, GPR.t6, GPR.t3, c, INT_LO_OFF);
                    switch (op) {
                        .eq => try arith64.cmpEq(&code, allocator),
                        .neq => try arith64.cmpNeq(&code, allocator),
                        .lt => try arith64.cmpLt(&code, allocator),
                        .gt => {
                            // gt(a,b) = lt(b,a)：交换操作数
                            try emit(&code, allocator, encXor(GPR.t4, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t6, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t4, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t5, GPR.t5, GPR.t3));
                            try emit(&code, allocator, encXor(GPR.t3, GPR.t5, GPR.t3));
                            try emit(&code, allocator, encXor(GPR.t5, GPR.t5, GPR.t3));
                            try arith64.cmpLt(&code, allocator);
                        },
                        .le => try arith64.cmpLe(&code, allocator),
                        .ge => {
                            // ge(a,b) = !(a<b) = !lt(a,b)
                            try arith64.cmpLt(&code, allocator);
                            try emit(&code, allocator, encXori(GPR.t4, GPR.t4, 1));
                        },
                        else => unreachable,
                    }
                    try loadImm32(&code, allocator, GPR.t2, TAG_BOOLEAN_VAL);
                    try regSb(&code, allocator, GPR.t2, a, TAG_OFF);
                    try regSb(&code, allocator, GPR.t4, a, PAYLOAD_OFF);
                    reg_types[a] = .boolean;
                } else if (b_known_f64 and c_known_f64) {
                    // ── 类型已知 f64：用 FPR 缓存池加载，跳过 tag 检查 ──
                    try loadFrameBase(&code, allocator);
                    const fpr_b = try emitEnsureFpr(&code, allocator, &fpr_state, b, 0xFF);
                    const fpr_c = try emitEnsureFpr(&code, allocator, &fpr_state, c, b);
                    switch (op) {
                        .eq => try emit(&code, allocator, encFeqD(GPR.t4, fpr_b, fpr_c)),
                        .neq => { try emit(&code, allocator, encFeqD(GPR.t4, fpr_b, fpr_c)); try emit(&code, allocator, encXori(GPR.t4, GPR.t4, -1)); },
                        .lt => try emit(&code, allocator, encFltD(GPR.t4, fpr_b, fpr_c)),
                        .gt => try emit(&code, allocator, encFltD(GPR.t4, fpr_c, fpr_b)),
                        .le => try emit(&code, allocator, encFleD(GPR.t4, fpr_b, fpr_c)),
                        .ge => try emit(&code, allocator, encFleD(GPR.t4, fpr_c, fpr_b)),
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

                    try regLd64Pair(&code, allocator, GPR.t4, GPR.t5, b, INT_LO_OFF);
                    try regLd64Pair(&code, allocator, GPR.t6, GPR.t3, c, INT_LO_OFF);
                    switch (op) {
                        .eq => try arith64.cmpEq(&code, allocator),
                        .neq => try arith64.cmpNeq(&code, allocator),
                        .lt => try arith64.cmpLt(&code, allocator),
                        .gt => {
                            try emit(&code, allocator, encXor(GPR.t4, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t6, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t4, GPR.t4, GPR.t6));
                            try emit(&code, allocator, encXor(GPR.t5, GPR.t5, GPR.t3));
                            try emit(&code, allocator, encXor(GPR.t3, GPR.t5, GPR.t3));
                            try emit(&code, allocator, encXor(GPR.t5, GPR.t5, GPR.t3));
                            try arith64.cmpLt(&code, allocator);
                        },
                        .le => try arith64.cmpLe(&code, allocator),
                        .ge => {
                            try arith64.cmpLt(&code, allocator);
                            try emit(&code, allocator, encXori(GPR.t4, GPR.t4, 1));
                        },
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
                        code.items[bne_not_int1] = reencB(code.items[bne_not_int1], @intCast(d1 << 2));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = reencB(code.items[bne_not_int2], @intCast(d2 << 2));
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
                        code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                    }

                    // cold: rt_step 桥接
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                    {
                        const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                        code.items[b_next2] = encJ(@intCast(d2 << 2));
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
                    code.items[bne_cold] = reencB(code.items[bne_cold], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
                }
            },

            // ── 热点 opcode：无条件跳转 ──
            .jump => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                if (ip_to_code.get(target_ip)) |target_off| {
                    const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(code.items.len));
                    try emit(&code, allocator, encJ(@intCast(delta << 2)));
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
                        code.items[beq_idx] = reencB(code.items[beq_idx], @intCast(delta << 2));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = beq_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    const bne_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t4, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(bne_idx));
                        code.items[bne_idx] = reencB(code.items[bne_idx], @intCast(delta << 2));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = bne_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                    code.items[bne_cold] = reencB(code.items[bne_cold], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
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
                        code.items[beq_idx] = reencB(code.items[beq_idx], @intCast(delta << 2));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = beq_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    const bne_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.x0, 0));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(bne_idx));
                        code.items[bne_idx] = reencB(code.items[bne_idx], @intCast(delta << 2));
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = bne_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }
            },

            // ── return_op / return_unit ──
            .return_op, .return_unit => {
                try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                try loadImm32(&code, allocator, GPR.a1, @intCast(ip));
                fpr_state.invalidateAll();
                try emit(&code, allocator, encJalr(GPR.ra, GPR.s2, 0));
                const j_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));
                try pending_fixups.append(allocator, .{ .code_idx = j_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
            },

            // ── 热点 opcode：load_const（标量快速路径）──
            .load_const => {
                try loadFrameBase(&code, allocator);
                const const_addr: usize = @intFromPtr(func.chunk.constants.items.ptr) + @as(usize, bx) * @sizeOf(value.Value);
                try loadAddr(&code, allocator, GPR.t3, const_addr);

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

                // 快速路径：用 FLD/FSD 拷贝 32 字节（4 对）
                try regCopy32(&code, allocator, GPR.t3, a);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
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

                // 快速路径：拷贝 32 字节（使用 FLD/FSD，offset 由 regFld/regFsd 内部计算）
                try regFld(&code, allocator, FPR.ft0, b, 0);
                try regFsd(&code, allocator, FPR.ft0, a, 0);
                try regFld(&code, allocator, FPR.ft0, b, 8);
                try regFsd(&code, allocator, FPR.ft0, a, 8);
                try regFld(&code, allocator, FPR.ft0, b, 16);
                try regFsd(&code, allocator, FPR.ft0, a, 16);
                try regFld(&code, allocator, FPR.ft0, b, 24);
                try regFsd(&code, allocator, FPR.ft0, a, 24);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
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
                    code.items[bhi_cold] = reencB(code.items[bhi_cold], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
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
                    code.items[bhi_cold] = reencB(code.items[bhi_cold], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
                }
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：cast / coerce ──
            // RV32 上 i64↔f64 转换无硬件指令，回退 rt_step
            // 仅整数间类型转换可内联（拷贝 lo/hi + 设置 type 字节）
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
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
                    continue;
                }

                // float 转换需要 FCVT.L.D/FCVT.D.L，RV32 不支持，回退
                if (float_target != null) {
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
                    continue;
                }

                // 整数间转换：拷贝 lo/hi 并设置 int type
                try loadFrameBase(&code, allocator);
                if (int_target) |it| {
                    try regLbu(&code, allocator, GPR.t2, b, TAG_OFF);
                    try loadImm32(&code, allocator, GPR.t3, TAG_INT_VAL);
                    const bne_not_int1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    try regLbu(&code, allocator, GPR.t2, a, TAG_OFF);
                    const bne_not_int2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.t2, GPR.t3, 0));

                    // 拷贝 lo/hi（用 FLD/FSD），设置 int type
                    try regFld(&code, allocator, FPR.ft0, b, 0);
                    try regFsd(&code, allocator, FPR.ft0, a, 0);
                    try regFld(&code, allocator, FPR.ft0, b, 8);
                    try regFsd(&code, allocator, FPR.ft0, a, 8);
                    const type_byte: i32 = @intCast(@intFromEnum(it));
                    try loadImm32(&code, allocator, GPR.t4, type_byte);
                    try regSb(&code, allocator, GPR.t4, a, INT_TYPE_OFF);

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const not_int_target: u32 = @intCast(code.items.len);
                    {
                        const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                        code.items[bne_not_int1] = reencB(code.items[bne_not_int1], @intCast(d1 << 2));
                        const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                        code.items[bne_not_int2] = reencB(code.items[bne_not_int2], @intCast(d2 << 2));
                    }

                    // f64 → i64 路径需要 FCVT.L.D，RV32 不支持，回退
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                }
                reg_types[a] = if (int_target != null) .i64 else .unknown;
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
                fpr_state.invalidateAll();
                try emit(&code, allocator, encJalr(GPR.ra, GPR.s3, 0));
                // BEQ a0, x0, +8 (if false, skip JAL; continue execution)
                // JAL x0, exit (占位, J-type 有 ±1MB 范围，规避 B-type ±4KB 限制)
                try emit(&code, allocator, encBeq(GPR.a0, GPR.x0, 8));
                const j_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));
                try pending_fixups.append(allocator, .{ .code_idx = j_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
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

                // 加载 index（32 位低字足够，索引不会超过 2^31）
                try regLw(&code, allocator, GPR.t2, c, INT_LO_OFF);
                // 加载 ArrayValue*（32 位指针）
                try regLw(&code, allocator, GPR.t4, b, 0);
                // 加载 elements.ptr 和 elements.len（32 位）
                try emit(&code, allocator, encLw(GPR.t5, GPR.t4, @intCast(ARRAY_ELEMS_PTR_OFF)));
                try emit(&code, allocator, encLw(GPR.t6, GPR.t4, @intCast(ARRAY_ELEMS_LEN_OFF)));

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

                // 拷贝 32 字节（使用 FLD/FSD）
                try regCopy32(&code, allocator, GPR.t3, a);

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encJ(0));

                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bne_cold1, bne_cold2, bhi_cold3, bhs_cold4, bhi_cold5 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    code.items[bne_off] = reencB(code.items[bne_off], @intCast(d << 2));
                }
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encJ(@intCast(d << 2));
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
                    fpr_state.invalidateAll();
                    try emit(&code, allocator, encJalr(GPR.ra, GPR.s5, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.a0, GPR.x0, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        code.items[bne_cold1] = reencB(code.items[bne_cold1], @intCast(d << 2));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                } else if (std.mem.eql(u8, mname, "push") and c == 1) {
                    // arr.push(elem) → rt_array_push(vm, recv_slot, arg_slot, dst_slot)
                    try emit(&code, allocator, encMv(GPR.a0, GPR.s0));
                    try emit(&code, allocator, encAddi(GPR.a1, GPR.s1, @intCast(a)));
                    try emit(&code, allocator, encAddi(GPR.a2, GPR.s1, @intCast(@as(u32, a) + 1)));
                    try emit(&code, allocator, encAddi(GPR.a3, GPR.s1, @intCast(a)));
                    fpr_state.invalidateAll();
                    try emit(&code, allocator, encJalr(GPR.ra, GPR.s4, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBne(GPR.a0, GPR.x0, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encJ(0));

                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        code.items[bne_cold1] = reencB(code.items[bne_cold1], @intCast(d << 2));
                    }
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);

                    const next_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                        code.items[b_next] = encJ(@intCast(d << 2));
                    }
                } else {
                    try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
                }
            },

            else => {
                try emitCold(&code, allocator, &pending_fixups, ip, &fpr_state);
            },
        }
    }

    // ════════ 函数 epilogue (= exit 标签) ════════
    exit_offset = @intCast(code.items.len);
    try emit(&code, allocator, encLw(GPR.ra, GPR.sp, 40));
    try emit(&code, allocator, encLw(GPR.s0, GPR.sp, 36));
    try emit(&code, allocator, encLw(GPR.s1, GPR.sp, 32));
    try emit(&code, allocator, encLw(GPR.s2, GPR.sp, 28));
    try emit(&code, allocator, encLw(GPR.s3, GPR.sp, 24));
    try emit(&code, allocator, encLw(GPR.s4, GPR.sp, 20));
    try emit(&code, allocator, encLw(GPR.s5, GPR.sp, 16));
    try emit(&code, allocator, encLw(GPR.s6, GPR.sp, 12));
    try emit(&code, allocator, encLw(GPR.s7, GPR.sp, 8));
    try emit(&code, allocator, encAddi(GPR.sp, GPR.sp, 48));
    try emit(&code, allocator, encRet());

    // ════════ 回填跳转目标 ════════
    for (pending_fixups.items) |fixup| {
        if (fixup.kind == 3) {
            // exit 跳转：跳到 exit_offset
            const delta: i64 = @as(i64, exit_offset) - @as(i64, @intCast(fixup.code_idx));
            if (fixup.code_idx < code.items.len) {
                const inst_val = code.items[fixup.code_idx];
                const opcode = inst_val & 0x7F;
                if (opcode == 0b1101111) {
                    // J-type (JAL x0, ...)
                    code.items[fixup.code_idx] = encJ(@intCast(delta << 2));
                } else {
                    // B-type (BNE/BEQ) — 残留路径，检查范围
                    const byte_delta = delta << 2;
                    if (byte_delta < std.math.minInt(i13) or byte_delta > std.math.maxInt(i13)) {
                        return error.JitBranchOutOfRange;
                    }
                    code.items[fixup.code_idx] = reencB(inst_val, @intCast(byte_delta));
                }
            }
        } else {
            const target_off = ip_to_code.get(fixup.target_ip) orelse {
                return error.JitMissingJumpTarget;
            };
            const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(fixup.code_idx));
            switch (fixup.kind) {
                1 => code.items[fixup.code_idx] = encJ(@intCast(delta << 2)),
                2 => {
                    // B-type 条件跳转：检查 ±4KB 范围，超出则报错
                    const byte_delta = delta << 2;
                    if (byte_delta < std.math.minInt(i13) or byte_delta > std.math.maxInt(i13)) {
                        return error.JitBranchOutOfRange;
                    }
                    code.items[fixup.code_idx] = reencB(code.items[fixup.code_idx], @intCast(byte_delta));
                },
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

/// RISC-V 32 JitBackend 实例（桥接模式）。
/// RV32 无 FCVT.L.D/FCVT.D.L，不支持 IR 模式，仅使用桥接模式。
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
    const engine: *jit_mod.JitEngine = @ptrCast(@alignCast(engine_ctx));
    const func: *const reg_chunk.RegFunction = @ptrCast(@alignCast(func_opaque));

    // 自递归情况下，内层 compileBridgeFn 可能已设置 compiled[func_idx]，
    // 此时直接返回已编译结果，避免重复编译和内存泄漏
    if (engine.compiled[func_idx]) |*existing_cfn| {
        return @ptrCast(existing_cfn);
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