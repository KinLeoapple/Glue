//! ARM64 (AArch64) 代码生成器。
//!
//! 将 IR 指令编译为 ARM64 机器码，写入可执行内存。
//! 支持 i64 算术/比较、f64 算术、分支/循环控制流。

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

/// ARM64 通用寄存器编号（x0-x30，x31=sp/xzr）。
pub const GPR = struct {
    pub const x0: u8 = 0;
    pub const x1: u8 = 1;
    pub const x2: u8 = 2;
    pub const x3: u8 = 3;
    pub const x4: u8 = 4;
    pub const x5: u8 = 5;
    pub const x6: u8 = 6;
    pub const x7: u8 = 7;
    pub const x8: u8 = 8;
    pub const x9: u8 = 9;
    pub const x10: u8 = 10;
    pub const x11: u8 = 11;
    pub const x12: u8 = 12;
    pub const x13: u8 = 13;
    pub const x14: u8 = 14;
    pub const x15: u8 = 15;
    pub const x16: u8 = 16; // IP0，调用约定可用
    pub const x17: u8 = 17; // IP1，调用约定可用
    pub const x18: u8 = 18; // 平台寄存器，避免使用
    pub const x19: u8 = 19;
    pub const x20: u8 = 20;
    pub const x21: u8 = 21;
    pub const x22: u8 = 22;
    pub const x23: u8 = 23;
    pub const x24: u8 = 24;
    pub const x25: u8 = 25;
    pub const x26: u8 = 26;
    pub const x27: u8 = 27;
    pub const x28: u8 = 28;
    pub const x29: u8 = 29; // FP
    pub const x30: u8 = 30; // LR
    pub const xzr: u8 = 31;
};

/// ARM64 浮点寄存器编号（d0-d31）。
pub const FPR = struct {
    pub const d0: u8 = 0;
    pub const d1: u8 = 1;
    pub const d2: u8 = 2;
    pub const d3: u8 = 3;
    pub const d4: u8 = 4;
    pub const d5: u8 = 5;
    pub const d6: u8 = 6;
    pub const d7: u8 = 7;
    pub const d8: u8 = 8; // 被调用方保存
    pub const d9: u8 = 9;
    pub const d10: u8 = 10;
    pub const d11: u8 = 11;
    pub const d12: u8 = 12;
    pub const d13: u8 = 13;
    pub const d14: u8 = 14;
    pub const d15: u8 = 15;
    pub const d16: u8 = 16;
    pub const d17: u8 = 17;
    pub const d18: u8 = 18;
    pub const d19: u8 = 19;
    pub const d20: u8 = 20;
    pub const d21: u8 = 21;
    pub const d22: u8 = 22;
    pub const d23: u8 = 23;
    pub const d24: u8 = 24;
    pub const d25: u8 = 25;
    pub const d26: u8 = 26;
    pub const d27: u8 = 27;
    pub const d28: u8 = 28;
    pub const d29: u8 = 29;
    pub const d30: u8 = 30;
    pub const d31: u8 = 31;
};

/// 可用于分配的通用寄存器（x9-x15, x19-x28，避开 x0-x7 参数、x16-x17 临时、x18 平台、x29-x30 栈帧）。
const AVAIL_GPRS = [_]backend_mod.PhysReg{
    .{ .id = GPR.x9, .kind = .gpr },
    .{ .id = GPR.x10, .kind = .gpr },
    .{ .id = GPR.x11, .kind = .gpr },
    .{ .id = GPR.x12, .kind = .gpr },
    .{ .id = GPR.x13, .kind = .gpr },
    .{ .id = GPR.x14, .kind = .gpr },
    .{ .id = GPR.x15, .kind = .gpr },
    .{ .id = GPR.x19, .kind = .gpr },
    .{ .id = GPR.x20, .kind = .gpr },
    .{ .id = GPR.x21, .kind = .gpr },
    .{ .id = GPR.x22, .kind = .gpr },
    .{ .id = GPR.x23, .kind = .gpr },
    .{ .id = GPR.x24, .kind = .gpr },
    .{ .id = GPR.x25, .kind = .gpr },
    .{ .id = GPR.x26, .kind = .gpr },
    .{ .id = GPR.x27, .kind = .gpr },
    .{ .id = GPR.x28, .kind = .gpr },
};

/// 可用于分配的浮点寄存器（d0-d7, d16-d31，调用者保存）。
const AVAIL_FPRS = [_]backend_mod.PhysReg{
    .{ .id = FPR.d0, .kind = .fpr },
    .{ .id = FPR.d1, .kind = .fpr },
    .{ .id = FPR.d2, .kind = .fpr },
    .{ .id = FPR.d3, .kind = .fpr },
    .{ .id = FPR.d4, .kind = .fpr },
    .{ .id = FPR.d5, .kind = .fpr },
    .{ .id = FPR.d6, .kind = .fpr },
    .{ .id = FPR.d7, .kind = .fpr },
    .{ .id = FPR.d16, .kind = .fpr },
    .{ .id = FPR.d17, .kind = .fpr },
    .{ .id = FPR.d18, .kind = .fpr },
    .{ .id = FPR.d19, .kind = .fpr },
    .{ .id = FPR.d20, .kind = .fpr },
    .{ .id = FPR.d21, .kind = .fpr },
    .{ .id = FPR.d22, .kind = .fpr },
    .{ .id = FPR.d23, .kind = .fpr },
};

/// 代码生成器状态。
const Codegen = struct {
    exec_mem: *mem.ExecMemory,
    /// 机器码缓冲区（u32 数组，ARM64 每条指令 4 字节）。
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
        /// 跳转指令的偏移字段位置（0=b.cond, 1=b, 2=cbz/cbnz）。
        fixup_kind: u8,
    };

    fn init(allocator: std.mem.Allocator, exec_mem: *mem.ExecMemory, alloc: *const regalloc.Allocation) Codegen {
        return .{
            .exec_mem = exec_mem,
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

    /// 追加一条 ARM64 指令。
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
        // 溢出到栈的情况暂不支持（prototype 阶段先断言）
        @panic("JIT register spill not supported in prototype");
    }
};

// ════════════════════════════════════════════════════════════════════
// ARM64 指令编码辅助函数
// 所有编码遵循 ARM Architecture Reference Manual (ARMv8-A)。
// 每个字段独立设置，避免位移混淆。
// ════════════════════════════════════════════════════════════════════

/// ADD (immediate): x_d = x_n + #imm12
/// 编码: sf op=0 S=0 100010 sh=0 imm12 Rn Rd
fn encAddImm(sf: u1, rd: u8, rn: u8, imm12: u12) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) | // op=0, S=0
        (0b100010 << 23) | // 固定
        (0 << 22) | // sh=0
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// SUB (immediate): x_d = x_n - #imm12
/// 编码: sf op=1 S=0 100010 sh=0 imm12 Rn Rd
fn encSubImm(sf: u1, rd: u8, rn: u8, imm12: u12) u32 {
    return (@as(u32, sf) << 31) |
        (0b10 << 29) | // op=1, S=0
        (0b100010 << 23) |
        (0 << 22) |
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// ADD (shifted register): x_d = x_n + x_m
/// 编码: sf op=0 S=0 01011 shift=00 Rm imm6=0 Rn Rd
fn encAddReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) | // op=0, S=0
        (0b01011 << 24) | // 固定
        (0b00 << 22) | // shift=LSL
        (@as(u32, rm) << 16) |
        (0 << 10) | // imm6=0
        (@as(u32, rn) << 5) |
        rd;
}

/// SUB (shifted register): x_d = x_n - x_m
/// 编码: sf op=1 S=0 01011 shift=00 Rm imm6=0 Rn Rd
fn encSubReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b10 << 29) | // op=1, S=0
        (0b01011 << 24) |
        (0b00 << 22) |
        (@as(u32, rm) << 16) |
        (0 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// MUL: x_d = x_n * x_m (使用 MADD Rd, Rn, Rm, XZR)
/// 编码: sf 00 11011 000 Rm 0 11111(XZR) Rn Rd
fn encMulReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) |
        (0b11011 << 24) |
        (0b000 << 21) |
        (@as(u32, rm) << 16) |
        (0 << 15) | // o0=0 (MADD)
        (0b11111 << 10) | // Ra=XZR
        (@as(u32, rn) << 5) |
        rd;
}

/// SDIV: x_d = x_n / x_m (有符号)
/// 编码: sf 00 11010 110 Rm 000011 Rn Rd
fn encSdiv(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) |
        (0b11010 << 24) |
        (0b110 << 21) |
        (@as(u32, rm) << 16) |
        (0b000011 << 10) | // 固定 opcode
        (@as(u32, rn) << 5) |
        rd;
}

/// UDIV: x_d = x_n / x_m (无符号)
/// 编码: sf 00 11010 110 Rm 000010 Rn Rd
fn encUdiv(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) |
        (0b11010 << 24) |
        (0b110 << 21) |
        (@as(u32, rm) << 16) |
        (0b000010 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// MSUB: x_d = x_a - (x_n * x_m)  用于取余: rem = a - (a/b)*b
/// 编码: sf 00 11011 000 Rm 1(o0) Ra Rn Rd
fn encMsub(sf: u1, rd: u8, rn: u8, rm: u8, ra: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) |
        (0b11011 << 24) |
        (0b000 << 21) |
        (@as(u32, rm) << 16) |
        (1 << 15) | // o0=1 for MSUB
        (@as(u32, ra) << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// NEG: x_d = -x_n  (等价于 SUB x_d, xzr, x_n)
fn encNegReg(sf: u1, rd: u8, rn: u8) u32 {
    return encSubReg(sf, rd, 31, rn); // SUB rd, xzr, rn
}

/// AND (shifted register): x_d = x_n & x_m
/// 编码: sf opc=00 01010 shift=00 N=0 Rm imm6=0 Rn Rd
fn encAndReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b00 << 29) | // opc=00 (AND)
        (0b01010 << 24) |
        (0b00 << 22) |
        (0 << 21) | // N=0
        (@as(u32, rm) << 16) |
        (0 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// ORR (shifted register): x_d = x_n | x_m
fn encOrrReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b01 << 29) | // opc=01 (ORR)
        (0b01010 << 24) |
        (0b00 << 22) |
        (0 << 21) |
        (@as(u32, rm) << 16) |
        (0 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// EOR (shifted register): x_d = x_n ^ x_m
fn encEorReg(sf: u1, rd: u8, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b10 << 29) | // opc=10 (EOR)
        (0b01010 << 24) |
        (0b00 << 22) |
        (0 << 21) |
        (@as(u32, rm) << 16) |
        (0 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// MVN (register): x_d = ~x_n (等价于 ORN x_d, xzr, x_n)
fn encMvnReg(sf: u1, rd: u8, rn: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b01 << 29) | // opc=01 (ORN)
        (0b01010 << 24) |
        (0b00 << 22) |
        (1 << 21) | // N=1 (NOT)
        (@as(u32, rn) << 16) |
        (0 << 10) |
        (31 << 5) | // Rn = XZR
        rd;
}

/// CMP (shifted register): 设置 flags = x_n - x_m
/// 等价于 SUBS xzr, x_n, x_m
/// 编码: sf op=1 S=1 01011 shift=00 Rm imm6=0 Rn Rd=xzr(31)
fn encCmpReg(sf: u1, rn: u8, rm: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b11 << 29) | // op=1, S=1 (SUBS)
        (0b01011 << 24) |
        (0b00 << 22) |
        (@as(u32, rm) << 16) |
        (0 << 10) |
        (@as(u32, rn) << 5) |
        31; // Rd = xzr
}

/// CMP (immediate): 设置 flags = x_n - #imm12
/// 编码: sf op=1 S=1 100010 sh=0 imm12 Rn Rd=xzr
fn encCmpImm(sf: u1, rn: u8, imm12: u12) u32 {
    return (@as(u32, sf) << 31) |
        (0b11 << 29) | // op=1, S=1 (SUBS)
        (0b100010 << 23) |
        (0 << 22) |
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        31; // Rd = xzr
}

/// CSET: x_d = cond ? 1 : 0
/// 实际编码 CSINC Rd, XZR, XZR, invert(cond)
/// 编码: sf 00 11010100 Rm(=XZR) cond[15:12] op2=01[11:10] Rn(=XZR) Rd
fn encCset(rd: u8, cond: u4) u32 {
    const inv_cond: u4 = cond ^ 1; // CSET 条件取反
    return (1 << 31) | // sf=1 (仅支持 64 位)
        (0b00 << 29) |
        (0b11010100 << 21) |
        (0b11111 << 16) | // Rm = XZR
        (@as(u32, inv_cond) << 12) | // cond in bits [15:12]
        (0b01 << 10) | // op2=01 (CSINC) in bits [11:10]
        (0b11111 << 5) | // Rn = XZR
        rd;
}

/// MOV (register): x_d = x_n (等价于 ORR x_d, xzr, x_n)
/// 编码: sf opc=01 01010 shift=00 N=0 Rm imm6=0 Rn=xzr Rd
fn encMovReg(sf: u1, rd: u8, rn: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b01 << 29) | // opc=01 (ORR)
        (0b01010 << 24) |
        (0b00 << 22) | // shift=LSL
        (0 << 21) | // N=0
        (@as(u32, rn) << 16) | // Rm = source
        (0 << 10) | // imm6=0
        (31 << 5) | // Rn = XZR
        rd;
}

/// MOVZ: x_d = #imm16 << (hw * 16)
/// 编码: sf opc=10 100101 hw imm16 Rd
fn encMovz(sf: u1, rd: u8, imm16: u16, hw: u2) u32 {
    return (@as(u32, sf) << 31) |
        (0b10 << 29) | // opc=10 (MOVZ)
        (0b100101 << 23) |
        (@as(u32, hw) << 21) |
        (@as(u32, imm16) << 5) |
        rd;
}

/// MOVK: x_d = (x_d & ~mask) | (#imm16 << (hw * 16))
/// 编码: sf opc=11 100101 hw imm16 Rd
fn encMovk(sf: u1, rd: u8, imm16: u16, hw: u2) u32 {
    return (@as(u32, sf) << 31) |
        (0b11 << 29) | // opc=11 (MOVK)
        (0b100101 << 23) |
        (@as(u32, hw) << 21) |
        (@as(u32, imm16) << 5) |
        rd;
}

/// B (unconditional branch): 跳转到 PC + offset*4
/// 编码: 000101 imm26
fn encB(offset: i26) u32 {
    const imm26: u26 = @bitCast(@as(i26, offset));
    return 0b000101 << 26 | @as(u32, imm26);
}

/// B.cond: 条件分支
/// 编码: 01010100 0 imm19 0 cond
fn encBcond(cond: u4, offset: i19) u32 {
    const imm19: u19 = @bitCast(@as(i19, offset));
    return (0b01010100 << 24) |
        (@as(u32, imm19) << 5) |
        cond;
}

/// CBZ: if (x_t == 0) jump (占位符，imm19 通过 fixup 回填)
/// 编码: sf 011010 0 imm19 Rt
fn encCbz(sf: u1, rt: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b0110100 << 24) |
        rt;
}

/// CBNZ: if (x_t != 0) jump (占位符，imm19 通过 fixup 回填)
/// 编码: sf 011010 1 imm19 Rt
fn encCbnz(sf: u1, rt: u8) u32 {
    return (@as(u32, sf) << 31) |
        (0b0110101 << 24) |
        rt;
}

/// RET: 从函数返回
fn encRet() u32 {
    return 0xD65F03C0;
}

/// BL: 带链接跳转（函数调用）
/// 编码: 100101 imm26
fn encBl(offset: i26) u32 {
    const imm26: u26 = @bitCast(@as(i26, offset));
    return 0b100101 << 26 | @as(u32, imm26);
}

/// BR Xn: 间接跳转
fn encBr(rn: u8) u32 {
    return 0xD61F0000 | (@as(u32, rn) << 5);
}

/// STR (immediate, unsigned offset): 存储 x_t 到 [x_n + #imm]
fn encStrImm(sf: u1, rt: u8, rn: u8, imm12: u12) u32 {
    return (@as(u32, sf) << 31) |
        (0b11 << 30) | // opc=11 (64-bit STR)
        (0b111001 << 24) | // 固定
        (0b00 << 22) | // unsigned offset
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// LDR (immediate, unsigned offset): 加载 x_t from [x_n + #imm*8]
fn encLdrImm(sf: u1, rt: u8, rn: u8, imm12: u12) u32 {
    return (@as(u32, sf) << 31) |
        (0b11 << 30) | // opc=11 (64-bit LDR)
        (0b111001 << 24) |
        (0b01 << 22) | // L=1 (load)
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// STP (pre-index): 存储一对寄存器到 [x_n + #imm]!
/// 编码: opc=10 101 0 01 11 0 imm7 rt2 rn rt1 (64-bit GPR, pre-index)
fn encStpPre(sf: u1, rt1: u8, rn: u8, rt2: u8, imm7: i7) u32 {
    const imm7_bits: u7 = @bitCast(imm7);
    return (@as(u32, sf) << 31) |
        (0b1010100110 << 22) | // opc=10, 101, V=0, 011=pre-index, L=0(store)
        (@as(u32, imm7_bits) << 15) |
        (@as(u32, rt2) << 10) |
        (@as(u32, rn) << 5) |
        rt1;
}

/// LDP (post-index): 加载一对寄存器 from [x_n], #imm
/// 编码: opc=10 101 0 00 01 1 imm7 rt2 rn rt1 (64-bit GPR, post-index, load)
fn encLdpPost(sf: u1, rt1: u8, rn: u8, rt2: u8, imm7: i7) u32 {
    const imm7_bits: u7 = @bitCast(imm7);
    return (@as(u32, sf) << 31) |
        (0b1010100011 << 22) | // opc=10, 101, V=0, 001=post-index, L=1(load)
        (@as(u32, imm7_bits) << 15) |
        (@as(u32, rt2) << 10) |
        (@as(u32, rn) << 5) |
        rt1;
}

/// STP (unsigned offset): 存储一对寄存器到 [x_n + #imm*8]
/// 编码: opc=10 101 0 01 0 0 imm7 rt2 rn rt1 (64-bit GPR, signed offset, store)
fn encStrPair(sf: u1, rt1: u8, rt2: u8, rn: u8, imm7: i7) u32 {
    const imm7_bits: u7 = @bitCast(imm7);
    return (@as(u32, sf) << 31) |
        (0b1010100100 << 22) | // opc=10, 101, V=0, 010=signed offset, L=0(store)
        (@as(u32, imm7_bits) << 15) |
        (@as(u32, rt2) << 10) |
        (@as(u32, rn) << 5) |
        rt1;
}

/// LDP (unsigned offset): 加载一对寄存器 from [x_n + #imm*8]
/// 编码: opc=10 101 0 01 0 1 imm7 rt2 rn rt1 (64-bit GPR, signed offset, load)
fn encLdrPair(sf: u1, rt1: u8, rt2: u8, rn: u8, imm7: i7) u32 {
    const imm7_bits: u7 = @bitCast(imm7);
    return (@as(u32, sf) << 31) |
        (0b1010100101 << 22) | // opc=10, 101, V=0, 010=signed offset, L=1(load)
        (@as(u32, imm7_bits) << 15) |
        (@as(u32, rt2) << 10) |
        (@as(u32, rn) << 5) |
        rt1;
}

/// BLR Xn: 带链接间接跳转（函数调用）
/// 编码: 1101011 0000 0 1 11111 0000 0 0 Rn 00000
fn encBlr(rn: u8) u32 {
    return 0xD63F0000 | (@as(u32, rn) << 5);
}

/// FADD: d_d = d_n + d_m
/// 00011110011 1 Rm 0010 10 Rn Rd  (64-bit: ftype=01, M=1, opcode=0010, bits[11:10]=10)
fn encFadd(rd: u8, rn: u8, rm: u8) u32 {
    return (0b00011110011 << 21) |
        (@as(u32, rm) << 16) |
        (0b0010 << 12) |
        (0b10 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FSUB: d_d = d_n - d_m
/// 00011110011 1 Rm 0011 10 Rn Rd  (opcode=0011)
fn encFsub(rd: u8, rn: u8, rm: u8) u32 {
    return (0b00011110011 << 21) |
        (@as(u32, rm) << 16) |
        (0b0011 << 12) |
        (0b10 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FMUL: d_d = d_n * d_m
/// 00011110011 1 Rm 0000 10 Rn Rd  (opcode=0000)
fn encFmul(rd: u8, rn: u8, rm: u8) u32 {
    return (0b00011110011 << 21) |
        (@as(u32, rm) << 16) |
        (0b0000 << 12) |
        (0b10 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FDIV: d_d = d_n / d_m
/// 00011110011 1 Rm 0001 10 Rn Rd  (opcode=0001)
fn encFdiv(rd: u8, rn: u8, rm: u8) u32 {
    return (0b00011110011 << 21) |
        (@as(u32, rm) << 16) |
        (0b0001 << 12) |
        (0b10 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FNEG: d_d = -d_n
/// 00011110011 10000 0001 10 Rn Rd
fn encFneg(rd: u8, rn: u8) u32 {
    return (0b00011110011 << 21) |
        (0b10000 << 16) |
        (0b0001 << 12) |
        (1 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FCMP: 比较 d_n 和 d_m，设置 flags
/// ARM64 编码: 0001 1110 011 Rm 0 0 1 0 0 0 Rn 0 0000
/// bit[13]=1 是 FCMP 指令的固定位
fn encFcmp(rn: u8, rm: u8) u32 {
    return (0b00011110011 << 21) |
        (@as(u32, rm) << 16) |
        (1 << 13) |
        (@as(u32, rn) << 5);
}

/// SCVTF: 整数转浮点 d_d = (f64) x_n (有符号 64 位 → double)
/// 格式: sf 00 11110 type 0 0 rmode(2) opcode(3) 1 0 Rn Rd
/// sf=1, type=01(double), rmode=00, opcode=010
fn encScvtf(rd: u8, rn: u8) u32 {
    return (1 << 31) |
        (0b00 << 29) |
        (0b11110 << 24) |
        (0b01 << 22) |
        (0 << 21) |
        (0b00 << 19) |
        (0b010 << 16) |
        (1 << 15) |
        (0 << 14) |
        (0b0000 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FCVTZS: 浮点转整数 x_d = (i64) d_n (向零取整, double → 有符号 64 位)
/// 格式: sf 00 11110 type 0 1 rmode(2) opcode(3) 1 0 Rn Rd
/// sf=1, type=01(double), rmode=00, opcode=000
fn encFcvtzs(rd: u8, rn: u8) u32 {
    return (1 << 31) |
        (0b00 << 29) |
        (0b11110 << 24) |
        (0b01 << 22) |
        (0 << 21) |
        (0b01 << 19) |
        (0b000 << 16) |
        (1 << 15) |
        (0 << 14) |
        (0b0000 << 10) |
        (@as(u32, rn) << 5) |
        rd;
}

/// FMOV: d_d = d_n (浮点寄存器间移动)
/// 1-source 形式: 00011110011 000000 1 0000 Rn Rd  (M=1, opcode=000000, bit14=1)
fn encFmov(rd: u8, rn: u8) u32 {
    return (0b00011110011 << 21) |
        (1 << 14) |
        (@as(u32, rn) << 5) |
        rd;
}

/// LDR (SIMD&FP, unsigned offset): d_t = [x_n + #imm*8]
/// 编码: size=11 111101 01 imm12 Rn Rt  (64-bit double)
fn encLdrF64(rt: u8, rn: u8, imm12: u12) u32 {
    return (0b11 << 30) |
        (0b111101 << 24) |
        (0b01 << 22) | // unsigned offset, load
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// STR (SIMD&FP, unsigned offset): [x_n + #imm*8] = d_t
/// 编码: size=11 111101 00 imm12 Rn Rt  (64-bit double)
fn encStrF64(rt: u8, rn: u8, imm12: u12) u32 {
    return (0b11 << 30) |
        (0b111101 << 24) |
        (0b00 << 22) | // unsigned offset, store
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// 条件码
const Cond = struct {
    pub const EQ: u4 = 0; // 相等
    pub const NE: u4 = 1; // 不等
    pub const HS: u4 = 2; // 无符号大于等于（C=1）
    pub const HI: u4 = 8; // 无符号大于（C=1 && Z=0）
    pub const LT: u4 = 11; // 有符号小于
    pub const LE: u4 = 13; // 有符号小于等于
    pub const GT: u4 = 12; // 有符号大于
    pub const GE: u4 = 10; // 有符号大于等于
};

/// 加载 64 位立即数到寄存器（使用 MOVZ + MOVK）。
fn loadImm64(cg: *Codegen, rd: u8, val: i64) !void {
    const uval: u64 = @bitCast(val);
    const lo16: u16 = @truncate(uval);
    const mid16: u16 = @truncate(uval >> 16);
    const hi16: u16 = @truncate(uval >> 32);
    const top16: u16 = @truncate(uval >> 48);

    try cg.emit(encMovz(1, rd, lo16, 0));
    if (mid16 != 0 or hi16 != 0 or top16 != 0) {
        try cg.emit(encMovk(1, rd, mid16, 1));
    }
    if (hi16 != 0 or top16 != 0) {
        try cg.emit(encMovk(1, rd, hi16, 2));
    }
    if (top16 != 0) {
        try cg.emit(encMovk(1, rd, top16, 3));
    }
}

/// LDRB (unsigned offset): load byte from [x_n + #imm12]
fn encLdrb(rt: u8, rn: u8, imm12: u12) u32 {
    return (0b00 << 30) |
        (0b111001 << 24) |
        (0b01 << 22) |
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// STRB (unsigned offset): store byte w_t to [x_n + #imm12]
fn encStrb(rt: u8, rn: u8, imm12: u12) u32 {
    return (0b00 << 30) |
        (0b111001 << 24) |
        (0b00 << 22) |
        (@as(u32, imm12) << 10) |
        (@as(u32, rn) << 5) |
        rt;
}

/// ADD (shifted register, LSL #5): x_d = x_n + (x_m << 5)
/// Used to compute base * 32
fn encAddLsl5(rd: u8, rn: u8, rm: u8) u32 {
    return (1 << 31) | // sf=1
        (0b00 << 29) | // op=0, S=0
        (0b01011 << 24) |
        (0b00 << 22) | // shift=LSL
        (@as(u32, rm) << 16) |
        (5 << 10) | // imm6=5 (shift amount)
        (@as(u32, rn) << 5) |
        rd;
}

/// 编译 IR 函数为 ARM64 机器码。
pub fn compile(
    allocator: std.mem.Allocator,
    func: *const ir.IRFunction,
    exec_mem: *mem.ExecMemory,
    func_entries: []const usize,
) !usize {
    // 寄存器分配
    var alloc_result = try regalloc.allocate(allocator, func, &AVAIL_GPRS);
    defer alloc_result.deinit();

    var cg = Codegen.init(allocator, exec_mem, &alloc_result);
    defer cg.deinit();

    // ════════ 函数 prologue ════════
    // stp x29, x30, [sp, #-16]!
    try cg.emit(encStpPre(1, GPR.x29, 31, GPR.x30, -2)); // imm7 = -2 (即 -16 字节，以 8 字节为单位)
    // add x29, sp, #0 (设置帧指针；ADD 中 reg 31 = SP，而 ORR 中 reg 31 = XZR)
    try cg.emit(encAddImm(1, GPR.x29, 31, 0));

    // ════════ 函数体 ════════
    for (func.insts.items) |inst| {
        switch (inst.op) {
            .label => {
                // 记录标签位置
                try cg.label_offsets.put(inst.label, cg.currentOffset());
            },

            .const_i64, .const_f64 => {
                const rd = cg.resolveReg(inst.dst);
                try loadImm64(&cg, rd, inst.imm);
            },

            .const_bool => {
                const rd = cg.resolveReg(inst.dst);
                if (inst.imm != 0) {
                    // mov rd, #1
                    try cg.emit(encMovz(1, rd, 1, 0));
                } else {
                    // mov rd, #0
                    try cg.emit(encMovz(1, rd, 0, 0));
                }
            },

            .add_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encAddReg(1, rd, rn, rm));
            },

            .sub_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSubReg(1, rd, rn, rm));
            },

            .mul_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encMulReg(1, rd, rn, rm));
            },

            .div_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encSdiv(1, rd, rn, rm));
            },

            .rem_i64 => {
                // rem = a - (a/b)*b
                // 使用 MSUB: Rd = Ra - (Rn * Rm)
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg); // a
                const rm = cg.resolveReg(inst.b.vreg); // b
                // 先算 a/b → x9
                try cg.emit(encSdiv(1, GPR.x9, rn, rm));
                // MSUB rd = rn - (x9 * rm) = a - (a/b)*b
                try cg.emit(encMsub(1, rd, GPR.x9, rm, rn));
            },

            .neg_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try cg.emit(encNegReg(1, rd, rn));
            },

            .and_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encAndReg(1, rd, rn, rm));
            },
            .or_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encOrrReg(1, rd, rn, rm));
            },
            .xor_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try cg.emit(encEorReg(1, rd, rn, rm));
            },
            .not_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try cg.emit(encMvnReg(1, rd, rn));
            },

            .move => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                if (rd != rn) {
                    try cg.emit(encMovReg(1, rd, rn));
                }
            },

            .eq_i64, .neq_i64, .lt_i64, .le_i64, .gt_i64, .ge_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                // CMP rn, rm → SUBS xzr, rn, rm
                try cg.emit(encCmpReg(1, rn, rm));
                // CSET rd, cond
                const cond: u4 = switch (inst.op) {
                    .eq_i64 => Cond.EQ,
                    .neq_i64 => Cond.NE,
                    .lt_i64 => Cond.LT,
                    .le_i64 => Cond.LE,
                    .gt_i64 => Cond.GT,
                    .ge_i64 => Cond.GE,
                    else => unreachable,
                };
                try cg.emit(encCset(rd, cond));
            },

            .bool_not => {
                // bool_not: rd = src ^ 1 (XOR with 1)
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                // 先 mov x9, #1
                try cg.emit(encMovz(1, GPR.x9, 1, 0));
                // EOR rd, rn, x9: sf 10 01010 shift=00 N=0 Rm imm6=0 Rn Rd
                try cg.emit((1 << 31) | (0b10 << 29) | (0b01010 << 24) | (0b00 << 22) | (0 << 21) | (@as(u32, GPR.x9) << 16) | (0 << 10) | (@as(u32, rn) << 5) | rd);
            },

            .i32_to_i64 => {
                // 符号扩展：SXTW rd, rn = SBFM rd, rn, #0, #31
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                // SBFM: sf 00 100110 N immr imms Rn Rd
                // SXTW: immr=0, imms=31, N=1, sf=1
                try cg.emit((1 << 31) | (0b00 << 29) | (0b100110 << 23) | (1 << 22) | (0 << 16) | (31 << 10) | (@as(u32, rn) << 5) | rd);
            },

            .jump => {
                // B label → 待回填
                const fixup_idx = cg.currentOffset();
                try cg.emit(encB(0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_idx,
                    .target_label = inst.label,
                    .fixup_kind = 1, // B
                });
            },

            .branch => {
                // branch cond, true_label, false_label
                // jump_if_false 语义: 条件为真跳转 → CBZ (反) 或 B.NE
                // 这里 cond 为布尔值 (0 或 1)
                // 如果 cond != 0 跳转到 true_label，否则 fallthrough 到 false_label
                const cond_reg = cg.resolveReg(inst.a.vreg);
                const false_label: u32 = @truncate(@as(u64, @bitCast(inst.imm)));

                // CBNZ cond, true_label (待回填)
                const fixup_true = cg.currentOffset();
                try cg.emit(encCbnz(1, cond_reg)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_true,
                    .target_label = inst.label, // true_label
                    .fixup_kind = 2, // CBNZ
                });

                // B false_label (待回填)
                const fixup_false = cg.currentOffset();
                try cg.emit(encB(0)); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_idx = fixup_false,
                    .target_label = false_label,
                    .fixup_kind = 1, // B
                });
            },

            .load_arg => {
                // 参数已在 x0-x7 中，移动到分配的寄存器
                const arg_idx: u8 = @intCast(inst.imm);
                const rd = cg.resolveReg(inst.dst);
                if (rd != arg_idx) {
                    try cg.emit(encMovReg(1, rd, arg_idx));
                }
            },

            .return_val => {
                // 移动返回值到 x0
                const rn = cg.resolveReg(inst.a.vreg);
                if (rn != GPR.x0) {
                    try cg.emit(encMovReg(1, GPR.x0, rn));
                }
                // 函数 epilogue
                // ldp x29, x30, [sp], #16
                try cg.emit(encLdpPost(1, GPR.x29, 31, GPR.x30, 2));
                try cg.emit(encRet());
            },

            .return_void => {
                try cg.emit(encLdpPost(1, GPR.x29, 31, GPR.x30, 2));
                try cg.emit(encRet());
            },

            .call => {
                // JIT 内函数调用
                // JIT 不遵循标准 ABI：callee 不保存 callee-saved 寄存器，
                // 因此 caller 必须保存所有 JIT 使用的寄存器 (x9-x15, x19-x28)。
                const target_idx = inst.call_target;
                if (target_idx >= func_entries.len or func_entries[target_idx] == 0) {
                    return error.JitCallTargetNotCompiled;
                }
                const entry_addr = func_entries[target_idx];

                // 保存 x9-x15, x19-x28 (17 个寄存器 = 136 字节，对齐到 144 字节 = 9 对)
                // stp x9, x10, [sp, #-144]!
                try cg.emit(encStpPre(1, GPR.x9, 31, GPR.x10, -18));
                // stp x11, x12, [sp, #16]
                try cg.emit(encStrPair(1, GPR.x11, GPR.x12, 31, 2));
                // stp x13, x14, [sp, #32]
                try cg.emit(encStrPair(1, GPR.x13, GPR.x14, 31, 4));
                // stp x15, x19, [sp, #48]
                try cg.emit(encStrPair(1, GPR.x15, GPR.x19, 31, 6));
                // stp x20, x21, [sp, #64]
                try cg.emit(encStrPair(1, GPR.x20, GPR.x21, 31, 8));
                // stp x22, x23, [sp, #80]
                try cg.emit(encStrPair(1, GPR.x22, GPR.x23, 31, 10));
                // stp x24, x25, [sp, #96]
                try cg.emit(encStrPair(1, GPR.x24, GPR.x25, 31, 12));
                // stp x26, x27, [sp, #112]
                try cg.emit(encStrPair(1, GPR.x26, GPR.x27, 31, 14));
                // stp x28, xzr, [sp, #128]
                try cg.emit(encStrPair(1, GPR.x28, 31, 31, 16));

                // 移动参数到 x0-x7
                const argc = inst.call_argc;
                if (argc > 8) return error.JitTooManyArgs;
                var i: u8 = 0;
                while (i < argc) : (i += 1) {
                    const arg_reg = cg.resolveReg(inst.call_args[i]);
                    if (arg_reg != i) {
                        try cg.emit(encMovReg(1, i, arg_reg));
                    }
                }

                // 加载目标入口地址到 x16
                const addr: u64 = @intCast(entry_addr);
                try cg.emit(encMovz(1, GPR.x16, @truncate(addr & 0xFFFF), 0));
                try cg.emit(encMovk(1, GPR.x16, @truncate((addr >> 16) & 0xFFFF), 1));
                try cg.emit(encMovk(1, GPR.x16, @truncate((addr >> 32) & 0xFFFF), 2));
                try cg.emit(encMovk(1, GPR.x16, @truncate((addr >> 48) & 0xFFFF), 3));

                // BLR x16
                try cg.emit(encBlr(GPR.x16));

                // 恢复 x9-x15, x19-x28（在移动返回值之前）
                // ldp x28, xzr, [sp, #128]
                try cg.emit(encLdrPair(1, GPR.x28, 31, 31, 16));
                // ldp x26, x27, [sp, #112]
                try cg.emit(encLdrPair(1, GPR.x26, GPR.x27, 31, 14));
                // ldp x24, x25, [sp, #96]
                try cg.emit(encLdrPair(1, GPR.x24, GPR.x25, 31, 12));
                // ldp x22, x23, [sp, #80]
                try cg.emit(encLdrPair(1, GPR.x22, GPR.x23, 31, 10));
                // ldp x20, x21, [sp, #64]
                try cg.emit(encLdrPair(1, GPR.x20, GPR.x21, 31, 8));
                // ldp x15, x19, [sp, #48]
                try cg.emit(encLdrPair(1, GPR.x15, GPR.x19, 31, 6));
                // ldp x13, x14, [sp, #32]
                try cg.emit(encLdrPair(1, GPR.x13, GPR.x14, 31, 4));
                // ldp x11, x12, [sp, #16]
                try cg.emit(encLdrPair(1, GPR.x11, GPR.x12, 31, 2));
                // ldp x9, x10, [sp], #144
                try cg.emit(encLdpPost(1, GPR.x9, 31, GPR.x10, 18));

                // 移动返回值 x0 到目标寄存器（在恢复寄存器之后，避免被覆盖）
                const dst = cg.resolveReg(inst.dst);
                if (dst != GPR.x0) {
                    try cg.emit(encMovReg(1, dst, GPR.x0));
                }
            },

            // 浮点运算（prototype 阶段暂不支持，需要 FPR 寄存器分配）
            .add_f64, .sub_f64, .mul_f64, .div_f64, .neg_f64,
            .eq_f64, .neq_f64, .lt_f64, .le_f64, .gt_f64, .ge_f64,
            .i64_to_f64, .f64_to_i64,
            => return error.JitFloatNotSupported,
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
            1 => { // B: imm26 (以指令为单位)
                const offset: i26 = @intCast(delta);
                cg.code.items[fixup.code_idx] = encB(offset);
            },
            2 => { // CBNZ: imm19 在 bits [23:5]
                const offset: i32 = @intCast(delta);
                const imm19: u19 = @truncate(@as(u32, @bitCast(offset)));
                // 保留原有寄存器和操作码位，只替换 imm19
                cg.code.items[fixup.code_idx] = (cg.code.items[fixup.code_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
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
// 桥接协作模式：直接从字节码生成 ARM64 机器码
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
const INT_TYPE_I32_VAL: u8 = runtime.INT_TYPE_I32;
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

/// 桥接模式编译：直接从字节码生成 ARM64 机器码。
///
/// JIT 函数签名: fn(vm: *RegVM, base: usize) callconv(.c) void
/// 热点 opcode（i64/f64 算术/比较/跳转）生成内联原生代码。
/// 冷门 opcode 通过 rt_step 桥接函数委托 VM 单步执行。
///
/// 仅支持 register_count <= 120 的函数（确保寄存器偏移在 imm12 范围内）。
/// func_idx: 当前函数在程序函数表中的索引（用于 tail_call 自递归检测）。
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
    // 寄存器数过多时偏移超出 imm12 范围，不 JIT
    if (func.register_count > 120) return error.JitTooManyRegisters;
    _ = func_idx; // 预留：tail_call 自递归检测

    var code = std.ArrayListUnmanaged(u32).empty;
    defer code.deinit(allocator);

    // 字节码 ip → 代码偏移映射（用于跳转回填）
    var ip_to_code = std.AutoHashMap(u32, u32).init(allocator);
    defer ip_to_code.deinit();

    // 待回填的向前跳转
    const Fixup = struct { code_idx: u32, target_ip: u32, kind: u8 };
    var pending_fixups = std.ArrayListUnmanaged(Fixup).empty;
    defer pending_fixups.deinit(allocator);

    // ── 类型传播：跟踪每个寄存器的已知类型 ──
    // 在单次前向遍历中，根据字节码推导寄存器类型。
    // 注意：类型传播仅在基本块内有效，跳转目标处需重置为 unknown，
    // 因为不同控制流路径可能赋予寄存器不同的类型。
    const RegType = enum { unknown, i64, f64, boolean };
    const reg_count = func.register_count;
    var reg_types = try allocator.alloc(RegType, reg_count);
    defer allocator.free(reg_types);
    @memset(reg_types, .unknown);
    // 从 param_types 初始化参数寄存器类型（仅在入口基本块有效）
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

    // ── 第一遍：收集所有跳转目标 IP ──
    // 在跳转目标处重置 reg_types 为 unknown，确保类型传播不会跨基本块泄露。
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

    // 出口标签的代码偏移（epilogue 位置）
    var exit_offset: u32 = 0;

    const emit = struct {
        fn push(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, enc: u32) !void {
            try buf.append(alloc, enc);
        }
    }.push;

    // ── 辅助：加载 64 位地址到寄存器 ──
    const loadAddr = struct {
        fn gen(buf: *std.ArrayListUnmanaged(u32), alloc: std.mem.Allocator, rd: u8, addr: u64) !void {
            const lo16: u16 = @truncate(addr);
            const mid16: u16 = @truncate(addr >> 16);
            const hi16: u16 = @truncate(addr >> 32);
            const top16: u16 = @truncate(addr >> 48);
            try emit(buf, alloc, encMovz(1, rd, lo16, 0));
            if (mid16 != 0 or hi16 != 0 or top16 != 0) {
                try emit(buf, alloc, encMovk(1, rd, mid16, 1));
            }
            if (hi16 != 0 or top16 != 0) {
                try emit(buf, alloc, encMovk(1, rd, hi16, 2));
            }
            if (top16 != 0) {
                try emit(buf, alloc, encMovk(1, rd, top16, 3));
            }
        }
    }.gen;

    // ════════ 函数 prologue ════════
    // stp x29, x30, [sp, #-16]!
    try emit(&code, allocator, encStpPre(1, GPR.x29, 31, GPR.x30, -2));
    // stp x19, x20, [sp, #-16]!
    try emit(&code, allocator, encStpPre(1, GPR.x19, 31, GPR.x20, -2));
    // stp x21, x22, [sp, #-16]!
    try emit(&code, allocator, encStpPre(1, GPR.x21, 31, GPR.x22, -2));
    // stp x23, x24, [sp, #-16]!
    try emit(&code, allocator, encStpPre(1, GPR.x23, 31, GPR.x24, -2));

    // mov x19, x0  (vm)
    try emit(&code, allocator, encMovReg(1, GPR.x19, GPR.x0));
    // mov x20, x1  (base)
    try emit(&code, allocator, encMovReg(1, GPR.x20, GPR.x1));

    // 加载 rt_step 地址到 x21
    try loadAddr(&code, allocator, GPR.x21, rt_step_addr);
    // 加载 rt_call_inline 地址到 x22
    try loadAddr(&code, allocator, GPR.x22, rt_call_inline_addr);
    // 加载 rt_array_push 地址到 x23
    try loadAddr(&code, allocator, GPR.x23, rt_array_push_addr);
    // 加载 rt_array_len 地址到 x24
    try loadAddr(&code, allocator, GPR.x24, rt_array_len_addr);

    // ════════ 函数体：遍历字节码 ════════
    const instructions = func.chunk.code.items;

    var ip: u32 = 0;
    while (ip < instructions.len) : (ip += 1) {
        // 记录字节码 ip → 代码偏移
        try ip_to_code.put(ip, @intCast(code.items.len));

        // 跳转目标处重置类型传播：不同控制流路径可能赋予寄存器不同类型
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
                    // ── 类型已知 i64：跳过 tag 检查，直接算术 ──
                    try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                    try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                    try emit(&code, allocator, encLdrImm(1, GPR.x14, GPR.x10, @intCast((@as(u32, c) * 32 + INT_LO_OFF) / 8)));
                    switch (op) {
                        .add => try emit(&code, allocator, encAddReg(1, GPR.x13, GPR.x13, GPR.x14)),
                        .sub => try emit(&code, allocator, encSubReg(1, GPR.x13, GPR.x13, GPR.x14)),
                        .mul => try emit(&code, allocator, encMulReg(1, GPR.x13, GPR.x13, GPR.x14)),
                        .div => try emit(&code, allocator, encSdiv(1, GPR.x13, GPR.x13, GPR.x14)),
                        .mod => {
                            try emit(&code, allocator, encSdiv(1, GPR.x15, GPR.x13, GPR.x14));
                            try emit(&code, allocator, encMsub(1, GPR.x13, GPR.x15, GPR.x14, GPR.x13));
                        },
                        else => unreachable,
                    }
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_INT_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, INT_TYPE_I64_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + INT_TYPE_OFF)));
                    try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, a) * 32 + INT_LO_OFF) / 8)));
                    reg_types[a] = .i64;
                } else if (b_known_f64 and c_known_f64 and op != .mod) {
                    // ── 类型已知 f64：跳过 tag 检查，直接浮点算术 ──
                    try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                    try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));
                    try emit(&code, allocator, encLdrF64(FPR.d0, GPR.x10, @intCast((@as(u32, b) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encLdrF64(FPR.d1, GPR.x10, @intCast((@as(u32, c) * 32 + FLOAT_BITS_OFF) / 8)));
                    switch (op) {
                        .add => try emit(&code, allocator, encFadd(FPR.d0, FPR.d0, FPR.d1)),
                        .sub => try emit(&code, allocator, encFsub(FPR.d0, FPR.d0, FPR.d1)),
                        .mul => try emit(&code, allocator, encFmul(FPR.d0, FPR.d0, FPR.d1)),
                        .div => try emit(&code, allocator, encFdiv(FPR.d0, FPR.d0, FPR.d1)),
                        else => unreachable,
                    }
                    try emit(&code, allocator, encStrF64(FPR.d0, GPR.x10, @intCast((@as(u32, a) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_FLOAT_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, FLOAT_TYPE_F64_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + FLOAT_TYPE_OFF)));
                    reg_types[a] = .f64;
                } else {
                // ── 未知类型：带 tag 检查的通用路径 ──
                // 加载 reg_pool 指针和 frame_base
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // ── i64 快速路径 ──
                // 检查 b 的 tag == TAG_INT
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                const bne_not_int1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 检查 c 的 tag == TAG_INT
                try emit(&code, allocator, encLdrb(GPR.x12, GPR.x10, @intCast(@as(u32, c) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x12, TAG_INT_VAL));
                const bne_not_int2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 加载 i64 值
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                try emit(&code, allocator, encLdrImm(1, GPR.x14, GPR.x10, @intCast((@as(u32, c) * 32 + INT_LO_OFF) / 8)));

                // 执行运算
                switch (op) {
                    .add => try emit(&code, allocator, encAddReg(1, GPR.x13, GPR.x13, GPR.x14)),
                    .sub => try emit(&code, allocator, encSubReg(1, GPR.x13, GPR.x13, GPR.x14)),
                    .mul => try emit(&code, allocator, encMulReg(1, GPR.x13, GPR.x13, GPR.x14)),
                    .div => try emit(&code, allocator, encSdiv(1, GPR.x13, GPR.x13, GPR.x14)),
                    .mod => {
                        // rem = a - (a/b)*b
                        try emit(&code, allocator, encSdiv(1, GPR.x15, GPR.x13, GPR.x14));
                        try emit(&code, allocator, encMsub(1, GPR.x13, GPR.x15, GPR.x14, GPR.x13));
                    },
                    else => unreachable,
                }

                // 存储 i64 结果到 dst(a)
                try emit(&code, allocator, encMovz(1, GPR.x11, TAG_INT_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encMovz(1, GPR.x11, INT_TYPE_I64_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + INT_TYPE_OFF)));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, a) * 32 + INT_LO_OFF) / 8)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 跳过 float 路径和 cold

                // not_int_target: 非 i64 入口（float 检查或 cold）
                const not_int_target: u32 = @intCast(code.items.len);
                // 回填 bne_not_int1/2
                {
                    const d1: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int1));
                    const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                    code.items[bne_not_int1] = (code.items[bne_not_int1] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);
                    const d2: i64 = @as(i64, not_int_target) - @as(i64, @intCast(bne_not_int2));
                    const imm19_2: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d2)))));
                    code.items[bne_not_int2] = (code.items[bne_not_int2] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_2) << 5);
                }

                var b_next2: u32 = 0;

                // ── f64 快速路径（.mod 无浮点路径，直接走 cold）──
                if (op != .mod) {
                    // 检查 b 的 tag == TAG_FLOAT
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_FLOAT_VAL));
                    const bne_cold_f1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 c 的 tag == TAG_FLOAT
                    try emit(&code, allocator, encLdrb(GPR.x12, GPR.x10, @intCast(@as(u32, c) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x12, TAG_FLOAT_VAL));
                    const bne_cold_f2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 b 的 float type == F64
                    try emit(&code, allocator, encLdrb(GPR.x13, GPR.x10, @intCast(@as(u32, b) * 32 + FLOAT_TYPE_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x13, FLOAT_TYPE_F64_VAL));
                    const bne_cold_f3: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 c 的 float type == F64
                    try emit(&code, allocator, encLdrb(GPR.x14, GPR.x10, @intCast(@as(u32, c) * 32 + FLOAT_TYPE_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x14, FLOAT_TYPE_F64_VAL));
                    const bne_cold_f4: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 加载 f64 bits 到 FPR
                    try emit(&code, allocator, encLdrF64(FPR.d0, GPR.x10, @intCast((@as(u32, b) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encLdrF64(FPR.d1, GPR.x10, @intCast((@as(u32, c) * 32 + FLOAT_BITS_OFF) / 8)));

                    // 执行浮点运算
                    switch (op) {
                        .add => try emit(&code, allocator, encFadd(FPR.d0, FPR.d0, FPR.d1)),
                        .sub => try emit(&code, allocator, encFsub(FPR.d0, FPR.d0, FPR.d1)),
                        .mul => try emit(&code, allocator, encFmul(FPR.d0, FPR.d0, FPR.d1)),
                        .div => try emit(&code, allocator, encFdiv(FPR.d0, FPR.d0, FPR.d1)),
                        else => unreachable,
                    }

                    // 存储 f64 结果到 dst(a)
                    try emit(&code, allocator, encStrF64(FPR.d0, GPR.x10, @intCast((@as(u32, a) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_FLOAT_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, FLOAT_TYPE_F64_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + FLOAT_TYPE_OFF)));

                    b_next2 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0)); // 跳过 cold

                    // cold 目标
                    const cold_off: u32 = @intCast(code.items.len);
                    // 回填 float bne 到 cold
                    inline for (.{ bne_cold_f1, bne_cold_f2, bne_cold_f3, bne_cold_f4 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                        code.items[bne_off] = (code.items[bne_off] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    }
                }

                // ── cold: rt_step 桥接 ──
                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                // ── .next: 回填 b_next 和 b_next2 ──
                const next_off: u32 = @intCast(code.items.len);
                {
                    const d: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encB(@intCast(d));
                }
                if (op != .mod) {
                    const d2: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next2));
                    code.items[b_next2] = encB(@intCast(d2));
                }
                reg_types[a] = .unknown;
                } // end else (unknown type path)
            },

            // ── 热点 opcode：i64 取反 ──
            .neg => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                if (b_known_i64) {
                    // 类型已知 i64：跳过 tag 检查
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                    try emit(&code, allocator, encNegReg(1, GPR.x13, GPR.x13));
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_INT_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encMovz(1, GPR.x11, INT_TYPE_I64_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + INT_TYPE_OFF)));
                    try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, a) * 32 + INT_LO_OFF) / 8)));
                    reg_types[a] = .i64;
                } else {
                // 检查源操作数 b 的 tag
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                const bne_cold = code.items.len;
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 加载 i64 值并取反
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                try emit(&code, allocator, encNegReg(1, GPR.x13, GPR.x13));

                // 存储结果到 dst(a)
                try emit(&code, allocator, encMovz(1, GPR.x11, TAG_INT_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encMovz(1, GPR.x11, INT_TYPE_I64_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + INT_TYPE_OFF)));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, a) * 32 + INT_LO_OFF) / 8)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bne_cold] = (code.items[bne_cold] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                reg_types[a] = .unknown;
                } // end else
            },

            // ── 热点 opcode：i64 比较 ──
            .eq, .neq, .lt, .gt, .le, .ge => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                if (b_known_i64 and c_known_i64) {
                    // ── 类型已知 i64：跳过 tag 检查 ──
                    try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                    try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                    try emit(&code, allocator, encLdrImm(1, GPR.x14, GPR.x10, @intCast((@as(u32, c) * 32 + INT_LO_OFF) / 8)));
                    try emit(&code, allocator, encCmpReg(1, GPR.x13, GPR.x14));
                    const cond: u4 = switch (op) {
                        .eq => Cond.EQ, .neq => Cond.NE, .lt => Cond.LT,
                        .gt => Cond.GT, .le => Cond.LE, .ge => Cond.GE,
                        else => unreachable,
                    };
                    try emit(&code, allocator, encCset(GPR.x13, cond));
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_BOOLEAN_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encStrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));
                    reg_types[a] = .boolean;
                } else if (b_known_f64 and c_known_f64) {
                    // ── 类型已知 f64：跳过 tag 检查 ──
                    try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                    try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                    try emit(&code, allocator, encLdrF64(FPR.d0, GPR.x10, @intCast((@as(u32, b) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encLdrF64(FPR.d1, GPR.x10, @intCast((@as(u32, c) * 32 + FLOAT_BITS_OFF) / 8)));
                    try emit(&code, allocator, encFcmp(FPR.d0, FPR.d1));
                    const cond: u4 = switch (op) {
                        .eq => Cond.EQ, .neq => Cond.NE, .lt => Cond.LT,
                        .gt => Cond.GT, .le => Cond.LE, .ge => Cond.GE,
                        else => unreachable,
                    };
                    try emit(&code, allocator, encCset(GPR.x13, cond));
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_BOOLEAN_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encStrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));
                    reg_types[a] = .boolean;
                } else {
                // ── 未知类型：带 tag 检查 ──
                // 加载 reg_pool 指针和 frame_base
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                const bne_cold1 = code.items.len;
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                try emit(&code, allocator, encLdrb(GPR.x12, GPR.x10, @intCast(@as(u32, c) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x12, TAG_INT_VAL));
                const bne_cold2 = code.items.len;
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 加载 i64 值并比较
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast((@as(u32, b) * 32 + INT_LO_OFF) / 8)));
                try emit(&code, allocator, encLdrImm(1, GPR.x14, GPR.x10, @intCast((@as(u32, c) * 32 + INT_LO_OFF) / 8)));
                try emit(&code, allocator, encCmpReg(1, GPR.x13, GPR.x14));

                // cset x13, cond
                const cond: u4 = switch (op) {
                    .eq => Cond.EQ,
                    .neq => Cond.NE,
                    .lt => Cond.LT,
                    .gt => Cond.GT,
                    .le => Cond.LE,
                    .ge => Cond.GE,
                    else => unreachable,
                };
                try emit(&code, allocator, encCset(GPR.x13, cond));

                // 存储布尔结果
                // tag = TAG_BOOLEAN
                try emit(&code, allocator, encMovz(1, GPR.x11, TAG_BOOLEAN_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                // payload (boolean value at offset 8)
                try emit(&code, allocator, encStrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bne_cold1] = (code.items[bne_cold1] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);
                const d2: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold2));
                const imm19_2: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d2)))));
                code.items[bne_cold2] = (code.items[bne_cold2] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_2) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                reg_types[a] = .boolean;
                } // end else (unknown type path)
            },

            // ── 热点 opcode：布尔取反（一元: dst=a, src=b）──
            .not_op => {
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查源操作数 b 的 tag
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_BOOLEAN_VAL));
                const bne_cold = code.items.len;
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 加载布尔值并取反: x13 = x13 ^ 1
                try emit(&code, allocator, encLdrb(GPR.x13, GPR.x10, @intCast(@as(u32, b) * 32 + PAYLOAD_OFF)));
                try emit(&code, allocator, encMovz(1, GPR.x14, 1, 0));
                // eor x13, x13, x14
                try emit(&code, allocator, (1 << 31) | (0b10 << 29) | (0b01010 << 24) | (0b00 << 22) | (0 << 21) | (@as(u32, GPR.x14) << 16) | (0 << 10) | (@as(u32, GPR.x13) << 5) | GPR.x13);

                // 存储结果到 dst(a)：tag + payload
                try emit(&code, allocator, encMovz(1, GPR.x11, TAG_BOOLEAN_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encStrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bne_cold] = (code.items[bne_cold] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
            },

            // ── 热点 opcode：无条件跳转 ──
            .jump => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                // 检查目标是否已处理（向后跳转）
                if (ip_to_code.get(target_ip)) |target_off| {
                    // 向后跳转：直接计算偏移
                    const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(code.items.len));
                    try emit(&code, allocator, encB(@intCast(delta)));
                } else {
                    // 向前跳转：占位，稍后回填
                    const idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0));
                    try pending_fixups.append(allocator, .{ .code_idx = idx, .target_ip = target_ip, .kind = 1 });
                }
            },

            // ── 热点 opcode：条件跳转 ──
            .jump_if_false, .jump_if_true => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查 tag 是否为 BOOLEAN
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_BOOLEAN_VAL));
                const bne_cold = code.items.len;
                try emit(&code, allocator, encBcond(Cond.NE, 0)); // 占位

                // 加载布尔值
                try emit(&code, allocator, encLdrb(GPR.x12, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));

                if (op == .jump_if_false) {
                    // jump_if_false: 如果值为 0 (false)，跳转到 target
                    // cbz w12, target (占位)
                    const cbz_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbz(1, GPR.x12)); // 占位
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(cbz_idx));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                        code.items[cbz_idx] = (code.items[cbz_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = cbz_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    // jump_if_true: 如果值不为 0 (true)，跳转到 target
                    const cbnz_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x12)); // 占位
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(cbnz_idx));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                        code.items[cbnz_idx] = (code.items[cbnz_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = cbnz_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bne_cold] = (code.items[bne_cold] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：null 检查跳转 ──
            // iABx: A=值寄存器, Bx=有符号跳转偏移
            // TAG_NULL = 0, 可直接用 CBZ/CBNZ
            .jump_if_null, .jump_if_not_null => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));

                if (op == .jump_if_null) {
                    // CBZ x11, target
                    const cbz_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbz(1, GPR.x11));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(cbz_idx));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                        code.items[cbz_idx] = (code.items[cbz_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = cbz_idx, .target_ip = target_ip, .kind = 2 });
                    }
                } else {
                    // CBNZ x11, target
                    const cbnz_idx: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x11));
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(cbnz_idx));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                        code.items[cbnz_idx] = (code.items[cbnz_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    } else {
                        try pending_fixups.append(allocator, .{ .code_idx = cbnz_idx, .target_ip = target_ip, .kind = 2 });
                    }
                }
            },

            // ── return_op / return_unit：通过 rt_step 处理，然后跳到 exit ──
            .return_op, .return_unit => {
                // rt_step(vm, ip) — rt_step 会检测到返回并返回 true
                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                // rt_step 返回 true（函数已返回），跳到 exit
                const b_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位 — 无条件跳到 exit
                try pending_fixups.append(allocator, .{ .code_idx = b_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
            },

            // ── 热点 opcode：load_const（标量快速路径）──
            // iABx: A=dst, Bx=常量池索引
            .load_const => {
                // 加载 reg_pool 指针和 frame_base
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 加载常量池地址到 x12（JIT 编译期已知）
                const const_addr: u64 = @intFromPtr(func.chunk.constants.items.ptr) + @as(u64, bx) * @sizeOf(value.Value);
                try loadAddr(&code, allocator, GPR.x12, const_addr);

                // 检查 dst(a) 是否标量
                try emit(&code, allocator, encLdrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x13, MAX_SCALAR_TAG));
                const bhi_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 检查 src(常量) 是否标量
                try emit(&code, allocator, encLdrb(GPR.x13, GPR.x12, @intCast(TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x13, MAX_SCALAR_TAG));
                const bhi_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 快速路径：从常量池拷贝 32 字节到 reg_pool[base + a]
                const a_off: u12 = @intCast(@as(u32, a) * 4);
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x12, 0));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x12, 1));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 1));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x12, 2));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 2));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x12, 3));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 3));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 跳过 cold

                // .cold: rt_step 桥接
                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                    code.items[bne_off] = (code.items[bne_off] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                }

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                // 类型传播：根据常量值设置类型
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
            // iABC: A=dst, B=src。assign 对 atomic 的特殊处理在标量路径中自然跳过。
            .move, .assign => {
                // 加载 reg_pool 指针和 frame_base
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查 src(b) 是否标量
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, MAX_SCALAR_TAG));
                const bhi_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 检查 dst(a) 是否标量
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, MAX_SCALAR_TAG));
                const bhi_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 快速路径：从 reg_pool[b] 拷贝 32 字节到 reg_pool[a]
                const b_off: u12 = @intCast(@as(u32, b) * 4);
                const a_off: u12 = @intCast(@as(u32, a) * 4);
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off + 1));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 1));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off + 2));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 2));
                try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off + 3));
                try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 3));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 跳过 cold

                // .cold: rt_step 桥接
                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bhi_cold1, bhi_cold2 }) |bne_off| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                    const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                    code.items[bne_off] = (code.items[bne_off] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                }

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                // 类型传播：move 复制源类型
                if (b < reg_count) reg_types[a] = reg_types[b];
            },

            // ── 热点 opcode：load_unit / load_null（标量快速路径）──
            // iABC: A=dst。标量时只需设置 tag。
            .load_unit, .load_null => {
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查 dst 是否标量
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, MAX_SCALAR_TAG));
                const bhi_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0)); // 占位

                // 快速路径：设置 tag
                const tag_val: u16 = if (op == .load_unit) TAG_UNIT_VAL else TAG_NULL_VAL;
                try emit(&code, allocator, encMovz(1, GPR.x12, tag_val, 0));
                try emit(&code, allocator, encStrb(GPR.x12, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bhi_cold));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bhi_cold] = (code.items[bhi_cold] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
            },

            // ── 热点 opcode：load_true / load_false（标量快速路径）──
            // iABC: A=dst。标量时设置 tag=BOOLEAN + payload。
            .load_true, .load_false => {
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查 dst 是否标量
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, MAX_SCALAR_TAG));
                const bhi_cold: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0)); // 占位

                // 快速路径：设置 tag=BOOLEAN, payload=0/1
                try emit(&code, allocator, encMovz(1, GPR.x12, TAG_BOOLEAN_VAL, 0));
                try emit(&code, allocator, encStrb(GPR.x12, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                const payload_val: u16 = if (op == .load_true) 1 else 0;
                try emit(&code, allocator, encMovz(1, GPR.x12, payload_val, 0));
                try emit(&code, allocator, encStrb(GPR.x12, GPR.x10, @intCast(@as(u32, a) * 32 + PAYLOAD_OFF)));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0)); // 占位

                // .cold
                const cold_off: u32 = @intCast(code.items.len);
                const d1: i64 = @as(i64, cold_off) - @as(i64, @intCast(bhi_cold));
                const imm19_1: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d1)))));
                code.items[bhi_cold] = (code.items[bhi_cold] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19_1) << 5);

                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：cast / coerce（编译期解析目标类型，生成专用转换）──
            // iABC: A=dst, B=src, C=常量池索引（类型名字符串）
            .cast, .coerce => {
                // 编译期解析目标类型名
                const type_val = func.chunk.constants.items[c];
                const tname = type_val.string.bytes();

                // 尝试解析为整数类型
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

                // 无法解析的类型 → rt_step 桥接
                if (int_target == null and float_target == null) {
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
                    continue;
                }

                // 加载 reg_pool 指针和 frame_base
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                if (int_target) |it| {
                    // 目标是整数类型
                    // 检查 src(b) tag == TAG_INT
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 dst(a) tag == TAG_INT（标量，可直接覆写）
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                    const bne_cold2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 快速路径：拷贝 src 的 lo/hi（offset 0, 8），设置目标 int type（offset 16）
                    const b_off: u12 = @intCast(@as(u32, b) * 4);
                    const a_off: u12 = @intCast(@as(u32, a) * 4);
                    // 拷贝 lo (offset 0)
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off));
                    try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off));
                    // 拷贝 hi (offset 8)
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, b_off + 1));
                    try emit(&code, allocator, encStrImm(1, GPR.x13, GPR.x10, a_off + 1));
                    // 设置目标 int type
                    const type_byte: u16 = @intCast(@intFromEnum(it));
                    try emit(&code, allocator, encMovz(1, GPR.x12, type_byte, 0));
                    try emit(&code, allocator, encStrb(GPR.x12, GPR.x10, @intCast(@as(u32, a) * 32 + INT_TYPE_OFF)));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0)); // 跳过 cold

                    // .cold: rt_step 桥接
                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold1, bne_cold2 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                        code.items[bne_off] = (code.items[bne_off] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    }
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                    const next_off: u32 = @intCast(code.items.len);
                    const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encB(@intCast(d_next));
                } else if (float_target) |ft| {
                    // 目标是浮点类型
                    // 检查 src(b) tag == TAG_INT（int→float 转换）
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_INT_VAL));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 src(b) int type == i64（仅支持 i64→f64 快速路径）
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + INT_TYPE_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, INT_TYPE_I64_VAL));
                    const bne_cold2: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 检查 dst(a) tag == TAG_FLOAT（标量，可直接覆写）
                    try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_FLOAT_VAL));
                    const bne_cold3: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    // 仅支持 f64 目标
                    if (ft != .f64) {
                        // f32 目标走桥接
                        try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                        try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                        if (ip > 0xFFFF) {
                            try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                        }
                        try emit(&code, allocator, encBlr(GPR.x21));
                        const cbnz_exit: u32 = @intCast(code.items.len);
                        try emit(&code, allocator, encCbnz(1, GPR.x0));
                        try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
                        continue;
                    }

                    // 加载 i64 值到 GPR
                    try emit(&code, allocator, encLdrImm(1, GPR.x13, GPR.x10, @intCast(@as(u32, b) * 4)));
                    // SCVTF d0, x13 (i64 → f64)
                    try emit(&code, allocator, encScvtf(FPR.d0, GPR.x13));
                    // 存储 f64 bits 到 dst(a)
                    try emit(&code, allocator, encStrF64(FPR.d0, GPR.x10, @intCast((@as(u32, a) * 32 + FLOAT_BITS_OFF) / 8)));
                    // 设置 tag = FLOAT
                    try emit(&code, allocator, encMovz(1, GPR.x11, TAG_FLOAT_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                    // 设置 float type = F64
                    try emit(&code, allocator, encMovz(1, GPR.x11, FLOAT_TYPE_F64_VAL, 0));
                    try emit(&code, allocator, encStrb(GPR.x11, GPR.x10, @intCast(@as(u32, a) * 32 + FLOAT_TYPE_OFF)));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0)); // 跳过 cold

                    // .cold: rt_step 桥接
                    const cold_off: u32 = @intCast(code.items.len);
                    inline for (.{ bne_cold1, bne_cold2, bne_cold3 }) |bne_off| {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_off));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                        code.items[bne_off] = (code.items[bne_off] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    }
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                    const next_off: u32 = @intCast(code.items.len);
                    const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encB(@intCast(d_next));
                }
                // 类型传播：cast 结果类型由目标类型决定
                reg_types[a] = if (int_target != null) .i64 else if (float_target != null) .f64 else .unknown;
            },

            // ── 热点 opcode：call（通过 rt_call_inline 快速路径，跳过 jitStepOnce）──
            // iABx: A=返回寄存器, Bx=函数索引。参数在 reg_pool[base+A+1..]
            .call => {
                const func_idx_val = bx;
                // rt_call_inline(vm, func_idx, args_base, argc, return_base, return_reg)
                // x0 = vm (x19)
                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                // x1 = func_idx
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(func_idx_val), 0));
                if (func_idx_val > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(func_idx_val >> 16), 1));
                }
                // x2 = args_base = frame_base + a + 1
                try emit(&code, allocator, encAddImm(1, GPR.x2, GPR.x20, @intCast(@as(u32, a) + 1)));
                // x3 = argc = callee.arity（编译期已知）
                const callee_arity: u32 = if (func_idx_val < functions.len) functions[func_idx_val].arity else 0;
                try emit(&code, allocator, encMovz(1, GPR.x3, @truncate(callee_arity), 0));
                // x4 = return_base = frame_base
                try emit(&code, allocator, encMovReg(1, GPR.x4, GPR.x20));
                // x5 = return_reg = a
                try emit(&code, allocator, encMovz(1, GPR.x5, @truncate(a), 0));
                // blr x22 (rt_call_inline)
                try emit(&code, allocator, encBlr(GPR.x22));
                // cbnz w0, exit（如果 rt_call_inline 返回 true，函数已返回）
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
                // call 返回值类型未知（暂时无法跨函数追踪返回类型）
                reg_types[a] = .unknown;
            },

            // ── 热点 opcode：index_op（数组索引 a[b] 快速路径）──
            // iABC: A=dst, B=arr, C=idx
            // 快速路径: array[i64] → 标量元素直接拷贝（无需 retain/release）
            .index_op => {
                try emit(&code, allocator, encLdrImm(1, GPR.x9, GPR.x19, @intCast(REG_POOL_PTR_OFFSET / 8)));
                try emit(&code, allocator, encAddLsl5(GPR.x10, GPR.x9, GPR.x20));

                // 检查 arr(b) tag == TAG_ARRAY
                try emit(&code, allocator, encLdrb(GPR.x11, GPR.x10, @intCast(@as(u32, b) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x11, TAG_ARRAY_VAL));
                const bne_cold1: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.NE, 0));

                // 检查 idx(c) tag == TAG_INT
                try emit(&code, allocator, encLdrb(GPR.x12, GPR.x10, @intCast(@as(u32, c) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x12, TAG_INT_VAL));
                const bne_cold2: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.NE, 0));

                // 检查 dst(a) 是标量（可直接覆写）
                try emit(&code, allocator, encLdrb(GPR.x13, GPR.x10, @intCast(@as(u32, a) * 32 + TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x13, MAX_SCALAR_TAG));
                const bhi_cold3: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 加载 ArrayValue* from arr payload (offset 0)
                const b_off: u12 = @intCast(@as(u32, b) * 4);
                try emit(&code, allocator, encLdrImm(1, GPR.x14, GPR.x10, b_off));

                // 加载 elements.ptr (offset 0) 和 elements.len (offset 8)
                try emit(&code, allocator, encLdrImm(1, GPR.x15, GPR.x14, 0)); // elements.ptr
                try emit(&code, allocator, encLdrImm(1, GPR.x16, GPR.x14, 1)); // elements.len

                // 加载 index (Int.lo, offset 0)
                const c_off: u12 = @intCast(@as(u32, c) * 4);
                try emit(&code, allocator, encLdrImm(1, GPR.x17, GPR.x10, c_off));

                // 边界检查: index < len (unsigned)
                try emit(&code, allocator, encCmpReg(1, GPR.x17, GPR.x16));
                const bhs_cold4: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HS, 0));

                // 计算元素地址: x11 = elements.ptr + index * 32
                try emit(&code, allocator, encAddLsl5(GPR.x11, GPR.x15, GPR.x17));

                // 检查元素是否标量（标量无需 retain）
                try emit(&code, allocator, encLdrb(GPR.x13, GPR.x11, @intCast(TAG_OFF)));
                try emit(&code, allocator, encCmpImm(1, GPR.x13, MAX_SCALAR_TAG));
                const bhi_cold5: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encBcond(Cond.HI, 0));

                // 快速路径: 拷贝 32 字节
                const a_off: u12 = @intCast(@as(u32, a) * 4);
                try emit(&code, allocator, encLdrImm(1, GPR.x12, GPR.x11, 0));
                try emit(&code, allocator, encStrImm(1, GPR.x12, GPR.x10, a_off));
                try emit(&code, allocator, encLdrImm(1, GPR.x12, GPR.x11, 1));
                try emit(&code, allocator, encStrImm(1, GPR.x12, GPR.x10, a_off + 1));
                try emit(&code, allocator, encLdrImm(1, GPR.x12, GPR.x11, 2));
                try emit(&code, allocator, encStrImm(1, GPR.x12, GPR.x10, a_off + 2));
                try emit(&code, allocator, encLdrImm(1, GPR.x12, GPR.x11, 3));
                try emit(&code, allocator, encStrImm(1, GPR.x12, GPR.x10, a_off + 3));

                const b_next: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encB(0));

                // cold: rt_step 桥接
                const cold_off: u32 = @intCast(code.items.len);
                inline for (.{ bne_cold1, bne_cold2, bhi_cold3, bhs_cold4, bhi_cold5 }) |b_off2| {
                    const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(b_off2));
                    const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                    code.items[b_off2] = (code.items[b_off2] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                }
                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0));
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                const next_off: u32 = @intCast(code.items.len);
                const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                code.items[b_next] = encB(@intCast(d_next));
            },

            // ── 热点 opcode：call_method（编译期解析方法名，常见方法内联）──
            // iABC: A=recv/dst, B=常量池索引(方法名), C=argc
            .call_method, .call_method_ic => {
                // 编译期解析方法名
                const method_val = func.chunk.constants.items[b];
                const mname = method_val.string.bytes();

                if (std.mem.eql(u8, mname, "len") and c == 0) {
                    // arr.len() → rt_array_len(vm, recv_slot, dst_slot)
                    // x0 = vm
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    // x1 = recv_slot = base + a
                    try emit(&code, allocator, encAddImm(1, GPR.x1, GPR.x20, @intCast(@as(u32, a))));
                    // x2 = dst_slot = base + a (same as recv)
                    try emit(&code, allocator, encAddImm(1, GPR.x2, GPR.x20, @intCast(@as(u32, a))));
                    // blr x24 (rt_array_len)
                    try emit(&code, allocator, encBlr(GPR.x24));
                    // 检查返回值: 非 0 → rt_step 回退
                    try emit(&code, allocator, encCmpImm(1, GPR.x0, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0));

                    // cold: rt_step
                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                        code.items[bne_cold1] = (code.items[bne_cold1] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    }
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                    const next_off: u32 = @intCast(code.items.len);
                    const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encB(@intCast(d_next));
                } else if (std.mem.eql(u8, mname, "push") and c == 1) {
                    // arr.push(elem) → rt_array_push(vm, recv_slot, arg_slot, dst_slot)
                    // x0 = vm
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    // x1 = recv_slot = base + a
                    try emit(&code, allocator, encAddImm(1, GPR.x1, GPR.x20, @intCast(@as(u32, a))));
                    // x2 = arg_slot = base + a + 1
                    try emit(&code, allocator, encAddImm(1, GPR.x2, GPR.x20, @intCast(@as(u32, a) + 1)));
                    // x3 = dst_slot = base + a
                    try emit(&code, allocator, encAddImm(1, GPR.x3, GPR.x20, @intCast(@as(u32, a))));
                    // blr x23 (rt_array_push)
                    try emit(&code, allocator, encBlr(GPR.x23));
                    // 检查返回值
                    try emit(&code, allocator, encCmpImm(1, GPR.x0, 0));
                    const bne_cold1: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encBcond(Cond.NE, 0));

                    const b_next: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encB(0));

                    // cold: rt_step
                    const cold_off: u32 = @intCast(code.items.len);
                    {
                        const d: i64 = @as(i64, cold_off) - @as(i64, @intCast(bne_cold1));
                        const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(d)))));
                        code.items[bne_cold1] = (code.items[bne_cold1] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                    }
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });

                    const next_off: u32 = @intCast(code.items.len);
                    const d_next: i64 = @as(i64, next_off) - @as(i64, @intCast(b_next));
                    code.items[b_next] = encB(@intCast(d_next));
                } else {
                    // 其他方法 → rt_step 桥接
                    try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                    try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                    if (ip > 0xFFFF) {
                        try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                    }
                    try emit(&code, allocator, encBlr(GPR.x21));
                    const cbnz_exit: u32 = @intCast(code.items.len);
                    try emit(&code, allocator, encCbnz(1, GPR.x0));
                    try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
                }
            },

            // ── 所有其他 opcode：通过 rt_step 桥接 ──
            else => {
                // rt_step(vm, ip)
                try emit(&code, allocator, encMovReg(1, GPR.x0, GPR.x19));
                try emit(&code, allocator, encMovz(1, GPR.x1, @truncate(ip), 0));
                if (ip > 0xFFFF) {
                    try emit(&code, allocator, encMovk(1, GPR.x1, @truncate(ip >> 16), 1));
                }
                try emit(&code, allocator, encBlr(GPR.x21));
                // cbnz w0, exit（如果 rt_step 返回 true，函数已返回）
                const cbnz_exit: u32 = @intCast(code.items.len);
                try emit(&code, allocator, encCbnz(1, GPR.x0)); // 占位
                try pending_fixups.append(allocator, .{ .code_idx = cbnz_exit, .target_ip = 0xFFFFFFFF, .kind = 3 });
            },
        }
    }

    // ════════ 函数 epilogue (= exit 标签) ════════
    exit_offset = @intCast(code.items.len);

    // ldp x23, x24, [sp], #16
    try emit(&code, allocator, encLdpPost(1, GPR.x23, 31, GPR.x24, 2));
    // ldp x21, x22, [sp], #16
    try emit(&code, allocator, encLdpPost(1, GPR.x21, 31, GPR.x22, 2));
    // ldp x19, x20, [sp], #16
    try emit(&code, allocator, encLdpPost(1, GPR.x19, 31, GPR.x20, 2));
    // ldp x29, x30, [sp], #16
    try emit(&code, allocator, encLdpPost(1, GPR.x29, 31, GPR.x30, 2));
    // ret
    try emit(&code, allocator, encRet());

    // ════════ 回填跳转目标 ════════
    for (pending_fixups.items) |fixup| {
        if (fixup.kind == 3) {
            // exit 跳转：跳到 exit_offset
            const delta: i64 = @as(i64, exit_offset) - @as(i64, @intCast(fixup.code_idx));
            if (fixup.code_idx < code.items.len) {
                // 检查是 B 还是 CBNZ
                const inst_val = code.items[fixup.code_idx];
                const is_b = (inst_val >> 26) == 0b000101;
                const is_cbnz = (inst_val & 0x7F000000) == 0x35000000;
                if (is_b) {
                    code.items[fixup.code_idx] = encB(@intCast(delta));
                } else if (is_cbnz) {
                    const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                    code.items[fixup.code_idx] = (code.items[fixup.code_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
                }
            }
        } else {
            const target_off = ip_to_code.get(fixup.target_ip) orelse {
                return error.JitMissingJumpTarget;
            };
            const delta: i64 = @as(i64, target_off) - @as(i64, @intCast(fixup.code_idx));
            switch (fixup.kind) {
                1 => code.items[fixup.code_idx] = encB(@intCast(delta)),
                2 => {
                    const imm19: u19 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(delta)))));
                    code.items[fixup.code_idx] = (code.items[fixup.code_idx] & ~(@as(u32, 0x7FFFF) << 5)) | (@as(u32, imm19) << 5);
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

/// ARM64 JitBackend 实例（桥接模式）。
pub const backend_instance: backend_mod.JitBackend = .{
    .compileFn = compileBridgeFn,
    .is_bridge = true,
};

/// JitBackend.compileFn 实现：桥接模式编译入口。
/// engine_ctx 实际类型为 *JitEngine，内部通过 @ptrCast 还原。
fn compileBridgeFn(
    engine_ctx: *anyopaque,
    func_idx: u32,
    func_opaque: *const anyopaque,
) ?*const anyopaque {
    const jit_mod = @import("../mod.zig");
    const JitEngine = jit_mod.JitEngine;
    const engine: *JitEngine = @ptrCast(@alignCast(engine_ctx));
    const func: *const reg_chunk.RegFunction = @ptrCast(@alignCast(func_opaque));

    // 跳过包含闭包/upvalue 的函数：回退到解释器以确保正确性
    if (@import("mod.zig").containsClosureOps(func)) {
        engine.failed[func_idx] = true;
        return null;
    }

    // 预分配可执行内存（32KB，桥接模式代码量较大）
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

    // 直接从字节码编译为 ARM64 机器码
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

/// 旧 IR 模式后端实例（保留供 IR 编译路径使用，当前 ARM64 不使用）。
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
