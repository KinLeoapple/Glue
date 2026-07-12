//! x86-64 代码生成器。
//!
//! 将 IR 指令编译为 x86-64 机器码，写入可执行内存。
//! 支持 i64 算术/比较、分支/循环控制流。
//! 使用 System V AMD64 调用约定（参数: rdi, rsi, rdx, rcx, r8, r9）。

const std = @import("std");
const builtin = @import("builtin");
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

/// x86-64 通用寄存器编号（使用 REX 编码时的 4 位编号）。
pub const GPR = struct {
    pub const rax: u8 = 0;
    pub const rcx: u8 = 1;
    pub const rdx: u8 = 2;
    pub const rbx: u8 = 3;
    pub const rsp: u8 = 4;
    pub const rbp: u8 = 5;
    pub const rsi: u8 = 6;
    pub const rdi: u8 = 7;
    pub const r8: u8 = 8;
    pub const r9: u8 = 9;
    pub const r10: u8 = 10;
    pub const r11: u8 = 11;
    pub const r12: u8 = 12;
    pub const r13: u8 = 13;
    pub const r14: u8 = 14;
    pub const r15: u8 = 15;
};

/// x86-64 浮点寄存器编号（xmm0-xmm15）。
/// xmm0: 返回值/scratch；xmm1: scratch；xmm2-xmm5: 调用者保存（volatile）；
/// Windows: xmm6-xmm15 被调用方保存；System V: xmm8-xmm15 被调用方保存。
pub const FPR = struct {
    pub const xmm0: u8 = 0;
    pub const xmm1: u8 = 1;
    pub const xmm2: u8 = 2;
    pub const xmm3: u8 = 3;
    pub const xmm4: u8 = 4;
    pub const xmm5: u8 = 5;
    pub const xmm6: u8 = 6; // Windows 被调用方保存
    pub const xmm7: u8 = 7; // Windows 被调用方保存
    pub const xmm8: u8 = 8; // 被调用方保存
    pub const xmm9: u8 = 9;
    pub const xmm10: u8 = 10;
    pub const xmm11: u8 = 11;
    pub const xmm12: u8 = 12;
    pub const xmm13: u8 = 13;
    pub const xmm14: u8 = 14;
    pub const xmm15: u8 = 15;
};

/// 可用于分配的通用寄存器（避开 rax=返回值, rsp=栈, rbp=帧, rdi-r9=参数）。
const AVAIL_GPRS = [_]backend_mod.PhysReg{
    .{ .id = GPR.rbx, .kind = .gpr },
    .{ .id = GPR.r10, .kind = .gpr },
    .{ .id = GPR.r11, .kind = .gpr },
    .{ .id = GPR.r12, .kind = .gpr },
    .{ .id = GPR.r13, .kind = .gpr },
    .{ .id = GPR.r14, .kind = .gpr },
    .{ .id = GPR.r15, .kind = .gpr },
};

/// 可用于分配的浮点寄存器（XMM0-XMM15，调用者保存）。
const AVAIL_FPRS = [_]backend_mod.PhysReg{
    .{ .id = 0, .kind = .fpr }, // xmm0
    .{ .id = 1, .kind = .fpr },
    .{ .id = 2, .kind = .fpr },
    .{ .id = 3, .kind = .fpr },
    .{ .id = 4, .kind = .fpr },
    .{ .id = 5, .kind = .fpr },
    .{ .id = 6, .kind = .fpr },
    .{ .id = 7, .kind = .fpr },
};

/// 代码生成器状态。
const Codegen = struct {
    /// 机器码缓冲区（x86-64 是变长指令）。
    code: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    alloc: *const regalloc.Allocation,
    /// 标签 → 代码偏移映射。
    label_offsets: std.AutoHashMap(u32, u32),
    /// 待修复的跳转指令。
    pending_fixups: std.ArrayListUnmanaged(Fixup) = .empty,

    const Fixup = struct {
        code_offset: u32, // 跳转指令在 code 中的偏移
        target_label: u32,
        rel32_offset: u32, // rel32 字段的偏移量（需要计算的位置）
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

    fn emit(self: *Codegen, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    fn emitSlice(self: *Codegen, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    fn emitU32(self: *Codegen, val: u32) !void {
        try self.code.appendSlice(self.allocator, std.mem.asBytes(&val));
    }

    fn emitI32(self: *Codegen, val: i32) !void {
        try self.code.appendSlice(self.allocator, std.mem.asBytes(&val));
    }

    fn currentOffset(self: *const Codegen) u32 {
        return @intCast(self.code.items.len);
    }

    fn resolveReg(self: *const Codegen, vr: ir.VReg) u8 {
        if (self.alloc.vreg_to_phys.get(vr.id)) |preg| {
            return preg.id;
        }
        @panic("JIT register spill not supported in prototype");
    }

    /// 发射 REX 前缀。
    fn emitRex(self: *Codegen, w: bool, r: u8, x: u8, b: u8) !void {
        var rex: u8 = 0x40;
        if (w) rex |= 0x08;
        if (r >= 8) rex |= 0x04;
        if (x >= 8) rex |= 0x02;
        if (b >= 8) rex |= 0x01;
        if (rex != 0x40) try self.emit(rex);
    }
};

/// 条件码（x86-64 Jcc 指令使用）。
const Cond = struct {
    pub const E: u8 = 0x74; // JE/JZ
    pub const NE: u8 = 0x75; // JNE/JNZ
    pub const L: u8 = 0x7C; // JL
    pub const LE: u8 = 0x7E; // JLE
    pub const G: u8 = 0x7F; // JG
    pub const GE: u8 = 0x7D; // JGE
};

/// 编译 IR 函数为 x86-64 机器码。
pub fn compile(
    allocator: std.mem.Allocator,
    func: *const ir.IRFunction,
    exec_mem: *mem.ExecMemory,
    func_entries: []const usize,
) !usize {
    var alloc_result = try regalloc.allocate(allocator, func, &AVAIL_GPRS, &AVAIL_FPRS);
    defer alloc_result.deinit();

    var cg = Codegen.init(allocator, &alloc_result);
    defer cg.deinit();

    // ════════ 函数 prologue ════════
    // push rbp
    try cg.emit(0x55);
    // mov rbp, rsp
    try cg.emit(0x48);
    try cg.emit(0x89);
    try cg.emit(0xE5);

    // ════════ 函数体 ════════
    for (func.insts.items) |inst| {
        switch (inst.op) {
            .label => {
                try cg.label_offsets.put(inst.label, cg.currentOffset());
            },

            .const_i64 => {
                // mov r64, imm64
                const rd = cg.resolveReg(inst.dst);
                try cg.emitRex(true, 0, 0, rd);
                try cg.emit(0xB8 + (rd & 0x7)); // REX.B + mov r64, imm64
                const val: i64 = inst.imm;
                try cg.emitI32(@truncate(@as(u64, @bitCast(val))));
                try cg.emitI32(@truncate(@as(u64, @bitCast(val)) >> 32));
            },

            .const_f64 => {
                // 先加载 imm64 到 rax（GPR），再 movq 到 XMM
                const rd = cg.resolveReg(inst.dst);
                // mov rax, imm64
                try cg.emitRex(true, 0, 0, GPR.rax);
                try cg.emit(0xB8);
                const val: i64 = inst.imm;
                try cg.emitI32(@truncate(@as(u64, @bitCast(val))));
                try cg.emitI32(@truncate(@as(u64, @bitCast(val)) >> 32));
                // movq xmm_rd, rax（从 GPR 移动 64 位到 XMM）
                try emitMovqGprToXmm(&cg, rd, GPR.rax);
            },

            .const_f32 => {
                // 先加载 imm32 到 eax（GPR），再 movd 到 XMM
                const rd = cg.resolveReg(inst.dst);
                // mov eax, imm32
                try cg.emitRex(false, 0, 0, GPR.rax);
                try cg.emit(0xB8);
                const val: u32 = @truncate(@as(u64, @bitCast(inst.imm)));
                try cg.emitI32(@bitCast(val));
                // movd xmm_rd, eax（从 GPR 移动 32 位到 XMM）
                try emitMovdGprToXmm(&cg, rd, GPR.rax);
            },

            .const_bool => {
                const rd = cg.resolveReg(inst.dst);
                // xor r64, r64
                try cg.emitRex(true, rd, 0, rd);
                try cg.emit(0x31);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rd & 7));
                if (inst.imm != 0) {
                    // mov r8, 1 (短形式)
                    try cg.emitRex(false, 0, 0, rd);
                    try cg.emit(0xB0 + (rd & 7));
                    try cg.emit(1);
                }
            },

            .add_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                // mov rd, rn
                try emitMovReg(&cg, rd, rn);
                // add rd, rm
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x01);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rd & 7));
            },

            .sub_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, rd, rn);
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x29);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rd & 7));
            },

            .mul_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, rd, rn);
                // imul rd, rm
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(0xAF);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rm & 7));
            },

            .div_i64 => {
                // 使用 idiv: 需要把被除数放到 rax, 符号扩展到 rdx, 除数在指定寄存器
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                // mov rax, rn
                try emitMovReg(&cg, GPR.rax, rn);
                // cqo (符号扩展 rax → rdx:rax)
                try cg.emit(0x48);
                try cg.emit(0x99);
                // idiv rm
                try cg.emitRex(true, rm, 0, 0);
                try cg.emit(0xF7);
                try cg.emit(0xF8 | (rm & 7));
                // mov rd, rax
                try emitMovReg(&cg, rd, GPR.rax);
            },

            .rem_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, GPR.rax, rn);
                try cg.emit(0x48);
                try cg.emit(0x99); // cqo
                try cg.emitRex(true, rm, 0, 0);
                try cg.emit(0xF7);
                try cg.emit(0xF8 | (rm & 7));
                // mov rd, rdx (余数在 rdx)
                try emitMovReg(&cg, rd, GPR.rdx);
            },

            .neg_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitMovReg(&cg, rd, rn);
                // neg r64
                try cg.emitRex(true, 0, 0, rd);
                try cg.emit(0xF7);
                try cg.emit(0xD8 | (rd & 7));
            },

            .and_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, rd, rn);
                // and r64, r64
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x21);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rd & 7));
            },
            .or_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, rd, rn);
                // or r64, r64
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x09);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rd & 7));
            },
            .xor_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovReg(&cg, rd, rn);
                // xor r64, r64
                try cg.emitRex(true, rm, 0, rd);
                try cg.emit(0x31);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rd & 7));
            },
            .not_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitMovReg(&cg, rd, rn);
                // not r64
                try cg.emitRex(true, 0, 0, rd);
                try cg.emit(0xF7);
                try cg.emit(0xD0 | (rd & 7));
            },

            .eq_i64, .neq_i64, .lt_i64, .le_i64, .gt_i64, .ge_i64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                // cmp rn, rm
                try cg.emitRex(true, rm, 0, rn);
                try cg.emit(0x39);
                try cg.emit(0xC0 | ((rm & 7) << 3) | (rn & 7));
                // setcc rd
                const setcc: u8 = switch (inst.op) {
                    .eq_i64 => 0x94,
                    .neq_i64 => 0x95,
                    .lt_i64 => 0x9C,
                    .le_i64 => 0x9E,
                    .gt_i64 => 0x9F,
                    .ge_i64 => 0x9D,
                    else => unreachable,
                };
                try cg.emitRex(false, 0, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(setcc);
                try cg.emit(0xC0 | (rd & 7));
                // movzx rd, r8 (零扩展)
                try cg.emitRex(true, rd, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(0xB6);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rd & 7));
            },

            .bool_not => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitMovReg(&cg, rd, rn);
                // xor rd, 1
                try cg.emitRex(true, 0, 0, rd);
                try cg.emit(0x83);
                try cg.emit(0xF0 | (rd & 7));
                try cg.emit(1);
            },

            .move => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                if (rd != rn) {
                    // 根据 vreg 类型选择移动指令
                    if (inst.dst.type.isFloat()) {
                        if (inst.dst.type == .f64) {
                            try emitMovsdReg(&cg, rd, rn);
                        } else {
                            try emitMovssReg(&cg, rd, rn);
                        }
                    } else {
                        try emitMovReg(&cg, rd, rn);
                    }
                }
            },

            .i32_to_i64 => {
                // movsxd rd, rn (符号扩展)
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try cg.emitRex(true, rd, 0, rn);
                try cg.emit(0x63);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rn & 7));
            },

            .jump => {
                // jmp rel32 (5 bytes: E9 + rel32)
                const fixup_offset = cg.currentOffset();
                try cg.emit(0xE9);
                const rel32_pos = cg.currentOffset();
                try cg.emitI32(0); // 占位
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_offset = fixup_offset,
                    .target_label = inst.label,
                    .rel32_offset = rel32_pos,
                });
            },

            .branch => {
                // branch cond, true_label, false_label
                // 如果 cond != 0 跳转到 true_label
                const cond_reg = cg.resolveReg(inst.a.vreg);
                const false_label: u32 = @truncate(@as(u64, @bitCast(inst.imm)));

                // test cond_reg, cond_reg
                try cg.emitRex(true, cond_reg, 0, cond_reg);
                try cg.emit(0x85);
                try cg.emit(0xC0 | ((cond_reg & 7) << 3) | (cond_reg & 7));

                // jnz true_label
                const fixup_true = cg.currentOffset();
                try cg.emit(0x0F);
                try cg.emit(0x85); // JNZ rel32
                const rel32_true = cg.currentOffset();
                try cg.emitI32(0);
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_offset = fixup_true,
                    .target_label = inst.label,
                    .rel32_offset = rel32_true,
                });

                // jmp false_label
                const fixup_false = cg.currentOffset();
                try cg.emit(0xE9);
                const rel32_false = cg.currentOffset();
                try cg.emitI32(0);
                try cg.pending_fixups.append(cg.allocator, .{
                    .code_offset = fixup_false,
                    .target_label = false_label,
                    .rel32_offset = rel32_false,
                });
            },

            .load_arg => {
                // System V 调用约定: 整数参数 rdi, rsi, rdx, rcx, r8, r9；浮点参数 xmm0-xmm7
                const arg_idx: u8 = @intCast(inst.imm);
                if (arg_idx >= 8) return error.JitTooManyArgs;
                const rd = cg.resolveReg(inst.dst);
                if (inst.dst.type.isFloat()) {
                    // 浮点参数从 xmm0-xmm7 加载
                    if (inst.dst.type == .f64) {
                        try emitMovsdReg(&cg, rd, arg_idx); // xmm{arg_idx}
                    } else {
                        try emitMovssReg(&cg, rd, arg_idx);
                    }
                } else {
                    // 整数参数从 rdi, rsi, rdx, rcx, r8, r9 加载
                    const arg_regs = [_]u8{ GPR.rdi, GPR.rsi, GPR.rdx, GPR.rcx, GPR.r8, GPR.r9 };
                    if (arg_idx >= arg_regs.len) return error.JitTooManyArgs;
                    try emitMovReg(&cg, rd, arg_regs[arg_idx]);
                }
            },

            .return_val => {
                const rn = cg.resolveReg(inst.a.vreg);
                // 根据返回值类型选择返回寄存器：整数 rax，浮点 xmm0
                if (inst.a.vreg.type.isFloat()) {
                    if (inst.a.vreg.type == .f64) {
                        try emitMovsdReg(&cg, FPR.xmm0, rn);
                    } else {
                        try emitMovssReg(&cg, FPR.xmm0, rn);
                    }
                } else {
                    // mov rax, rn
                    try emitMovReg(&cg, GPR.rax, rn);
                }
                // pop rbp
                try cg.emit(0x5D);
                // ret
                try cg.emit(0xC3);
            },

            .return_void => {
                try cg.emit(0x5D); // pop rbp
                try cg.emit(0xC3); // ret
            },

            .call => {
                // JIT 内函数调用 (x86-64 System V ABI)
                // JIT 不遵循标准 ABI：callee 不保存 callee-saved 寄存器，
                // 因此 caller 必须保存所有 JIT 使用的寄存器 (rbx, r10-r15, xmm0-xmm7)。
                const target_idx = inst.call_target;
                if (target_idx >= func_entries.len or func_entries[target_idx] == 0) {
                    return error.JitCallTargetNotCompiled;
                }
                const entry_addr = func_entries[target_idx];

                const argc = inst.call_argc;
                if (argc > 6) return error.JitTooManyArgs;
                const int_arg_regs = [_]u8{ GPR.rdi, GPR.rsi, GPR.rdx, GPR.rcx, GPR.r8, GPR.r9 };

                // 保存所有 JIT GPR 寄存器 (rbx, r10-r15 = 7 个 = 56 字节)
                // push rbx (reg 3, 无需 REX)
                try cg.emit(0x50 | GPR.rbx);
                // push r10-r15 (需要 REX.B)
                try cg.emitRex(false, 0, 0, GPR.r10);
                try cg.emit(0x50 | (GPR.r10 & 7));
                try cg.emitRex(false, 0, 0, GPR.r11);
                try cg.emit(0x50 | (GPR.r11 & 7));
                try cg.emitRex(false, 0, 0, GPR.r12);
                try cg.emit(0x50 | (GPR.r12 & 7));
                try cg.emitRex(false, 0, 0, GPR.r13);
                try cg.emit(0x50 | (GPR.r13 & 7));
                try cg.emitRex(false, 0, 0, GPR.r14);
                try cg.emit(0x50 | (GPR.r14 & 7));
                try cg.emitRex(false, 0, 0, GPR.r15);
                try cg.emit(0x50 | (GPR.r15 & 7));

                // 保存所有 JIT FPR 寄存器 (xmm0-xmm7 = 8 个 = 64 字节)
                // sub rsp, 64
                try cg.emit(0x48);
                try cg.emit(0x83);
                try cg.emit(0xEC);
                try cg.emit(64);
                // movsd [rsp + i*8], xmm_i（使用 SIB 字节，因为 base=rsp）
                {
                    var xi: u8 = 0;
                    while (xi < 8) : (xi += 1) {
                        try cg.emit(0xF2);
                        try cg.emitRex(false, xi, 0, GPR.rsp);
                        try cg.emit(0x0F);
                        try cg.emit(0x11);
                        try cg.emit(0x40 | ((xi & 7) << 3) | 4); // mod=01, reg=xmm_i, rm=4 (SIB)
                        try cg.emit(0x24); // SIB: scale=0, index=none, base=rsp
                        try cg.emit(xi * 8); // disp8
                    }
                }

                // sub rsp, 8 (对齐到 16 字节：56 + 64 + 8 = 128 = 16 的倍数)
                try cg.emit(0x48);
                try cg.emit(0x83);
                try cg.emit(0xEC);
                try cg.emit(0x08);

                // 移动参数到参数寄存器
                // 整数参数和浮点参数独立编号：
                // - 整数参数 → rdi, rsi, rdx, rcx, r8, r9
                // - 浮点参数 → xmm0, xmm1, ..., xmm7
                var int_arg_idx: u8 = 0;
                var float_arg_idx: u8 = 0;
                var i: u8 = 0;
                while (i < argc) : (i += 1) {
                    const arg_vreg = inst.call_args[i];
                    if (arg_vreg.type.isFloat()) {
                        // 浮点参数：从栈上保存的位置加载到 xmm{float_arg_idx}
                        const src_xmm = cg.resolveReg(arg_vreg);
                        // 源 XMM 保存在 [rsp + 8 (对齐) + src_xmm * 8]
                        const disp: u8 = 8 + src_xmm * 8;
                        // movsd xmm{float_arg_idx}, [rsp + disp]（使用 SIB 字节）
                        try cg.emit(0xF2);
                        try cg.emitRex(false, float_arg_idx, 0, GPR.rsp);
                        try cg.emit(0x0F);
                        try cg.emit(0x10);
                        try cg.emit(0x40 | ((float_arg_idx & 7) << 3) | 4); // mod=01, rm=4 (SIB)
                        try cg.emit(0x24); // SIB
                        try cg.emit(disp);
                        float_arg_idx += 1;
                    } else {
                        // 整数参数：从 GPR 移动到 int_arg_regs[int_arg_idx]
                        const src_reg = cg.resolveReg(arg_vreg);
                        try emitMovReg(&cg, int_arg_regs[int_arg_idx], src_reg);
                        int_arg_idx += 1;
                    }
                }

                // 加载目标入口地址到 rax 并调用
                try cg.emitRex(true, 0, 0, GPR.rax);
                try cg.emit(0xB8 | (GPR.rax & 7));
                const addr: u64 = @intCast(entry_addr);
                const lo: u32 = @truncate(addr & 0xFFFFFFFF);
                const hi: u32 = @truncate((addr >> 32) & 0xFFFFFFFF);
                try cg.emit(@truncate(lo & 0xFF));
                try cg.emit(@truncate((lo >> 8) & 0xFF));
                try cg.emit(@truncate((lo >> 16) & 0xFF));
                try cg.emit(@truncate((lo >> 24) & 0xFF));
                try cg.emit(@truncate(hi & 0xFF));
                try cg.emit(@truncate((hi >> 8) & 0xFF));
                try cg.emit(@truncate((hi >> 16) & 0xFF));
                try cg.emit(@truncate((hi >> 24) & 0xFF));
                // call rax
                try cg.emitRex(true, 0, 0, GPR.rax);
                try cg.emit(0xFF);
                try cg.emit(0xD0 | (GPR.rax & 7));

                // add rsp, 8 (移除对齐填充)
                try cg.emit(0x48);
                try cg.emit(0x83);
                try cg.emit(0xC4);
                try cg.emit(0x08);

                // 恢复 JIT FPR 寄存器（从栈加载 xmm0-xmm7）
                {
                    var xi: u8 = 0;
                    while (xi < 8) : (xi += 1) {
                        try cg.emit(0xF2);
                        try cg.emitRex(false, xi, 0, GPR.rsp);
                        try cg.emit(0x0F);
                        try cg.emit(0x10);
                        try cg.emit(0x40 | ((xi & 7) << 3) | 4); // mod=01, rm=4 (SIB)
                        try cg.emit(0x24); // SIB
                        try cg.emit(xi * 8); // disp8
                    }
                }
                // add rsp, 64 (移除 XMM 保存区)
                try cg.emit(0x48);
                try cg.emit(0x83);
                try cg.emit(0xC4);
                try cg.emit(64);

                // 恢复 JIT GPR 寄存器（逆序，在移动返回值之前）
                try cg.emitRex(false, 0, 0, GPR.r15);
                try cg.emit(0x58 | (GPR.r15 & 7));
                try cg.emitRex(false, 0, 0, GPR.r14);
                try cg.emit(0x58 | (GPR.r14 & 7));
                try cg.emitRex(false, 0, 0, GPR.r13);
                try cg.emit(0x58 | (GPR.r13 & 7));
                try cg.emitRex(false, 0, 0, GPR.r12);
                try cg.emit(0x58 | (GPR.r12 & 7));
                try cg.emitRex(false, 0, 0, GPR.r11);
                try cg.emit(0x58 | (GPR.r11 & 7));
                try cg.emitRex(false, 0, 0, GPR.r10);
                try cg.emit(0x58 | (GPR.r10 & 7));
                try cg.emit(0x58 | GPR.rbx); // pop rbx (无需 REX)

                // 移动返回值到目标寄存器（在恢复寄存器之后，避免被覆盖）
                // 整数返回值在 rax，浮点返回值在 xmm0
                const dst = cg.resolveReg(inst.dst);
                if (inst.dst.type.isFloat()) {
                    if (inst.dst.type == .f64) {
                        try emitMovsdReg(&cg, dst, FPR.xmm0);
                    } else {
                        try emitMovssReg(&cg, dst, FPR.xmm0);
                    }
                } else {
                    try emitMovReg(&cg, dst, GPR.rax);
                }
            },

            // ════════ 浮点算术（f64）════════
            .add_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovsdReg(&cg, rd, rn); // movsd rd, rn
                try emitAddsd(&cg, rd, rm); // addsd rd, rm
            },
            .sub_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovsdReg(&cg, rd, rn);
                try emitSubsd(&cg, rd, rm);
            },
            .mul_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovsdReg(&cg, rd, rn);
                try emitMulsd(&cg, rd, rm);
            },
            .div_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovsdReg(&cg, rd, rn);
                try emitDivsd(&cg, rd, rm);
            },
            .neg_f64 => {
                // 翻转符号位：通过 GPR 中转异或 0x8000000000000000
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                // movq rax, xmm_rn（浮点位 → GPR）
                try emitMovqXmmToGpr(&cg, GPR.rax, rn);
                // mov rdx, 0x8000000000000000（符号位掩码）
                try cg.emitRex(true, 0, 0, GPR.rdx);
                try cg.emit(0xB8 | (GPR.rdx & 7));
                try cg.emitI32(0x00000000);
                try cg.emitI32(0x80000000);
                // xor rax, rdx（翻转符号位）
                try cg.emitRex(true, GPR.rdx, 0, GPR.rax);
                try cg.emit(0x31);
                try cg.emit(0xC0 | ((GPR.rdx & 7) << 3) | (GPR.rax & 7));
                // movq xmm_rd, rax（GPR → 浮点位）
                try emitMovqGprToXmm(&cg, rd, GPR.rax);
            },

            // ════════ 浮点比较（f64）→ bool ════════
            // ucomisd 设置 ZF/CF，使用无符号条件码（B/BE/A/AE）
            .eq_f64, .neq_f64, .lt_f64, .le_f64, .gt_f64, .ge_f64 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                // ucomisd rn, rm（比较 xmm_a 和 xmm_b）
                try emitUcomisd(&cg, rn, rm);
                // setcc rd（浮点使用无符号条件码）
                const setcc: u8 = switch (inst.op) {
                    .eq_f64 => 0x94, // sete (ZF=1)
                    .neq_f64 => 0x95, // setne (ZF=0)
                    .lt_f64 => 0x92, // setb (CF=1)
                    .le_f64 => 0x96, // setbe (CF=1 or ZF=1)
                    .gt_f64 => 0x97, // seta (CF=0 and ZF=0)
                    .ge_f64 => 0x93, // setae (CF=0)
                    else => unreachable,
                };
                try cg.emitRex(false, 0, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(setcc);
                try cg.emit(0xC0 | (rd & 7));
                // movzx rd, r8（零扩展）
                try cg.emitRex(true, rd, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(0xB6);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rd & 7));
            },

            // ════════ 浮点算术（f32）════════
            .add_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovssReg(&cg, rd, rn);
                try emitAddss(&cg, rd, rm);
            },
            .sub_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovssReg(&cg, rd, rn);
                try emitSubss(&cg, rd, rm);
            },
            .mul_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovssReg(&cg, rd, rn);
                try emitMulss(&cg, rd, rm);
            },
            .div_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitMovssReg(&cg, rd, rn);
                try emitDivss(&cg, rd, rm);
            },
            .neg_f32 => {
                // 翻转符号位：通过 GPR 中转异或 0x80000000（32 位）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                // movd eax, xmm_rn（浮点位 → GPR，32 位）
                try emitMovdXmmToGpr(&cg, GPR.rax, rn);
                // xor eax, 0x80000000（翻转 32 位符号位）
                try cg.emit(0x35); // xor eax, imm32
                try cg.emitI32(@bitCast(@as(u32, 0x80000000)));
                // movd xmm_rd, eax（GPR → 浮点位，32 位）
                try emitMovdGprToXmm(&cg, rd, GPR.rax);
            },

            // ════════ 浮点比较（f32）→ bool ════════
            .eq_f32, .neq_f32, .lt_f32, .le_f32, .gt_f32, .ge_f32 => {
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                const rm = cg.resolveReg(inst.b.vreg);
                try emitUcomiss(&cg, rn, rm);
                const setcc: u8 = switch (inst.op) {
                    .eq_f32 => 0x94,
                    .neq_f32 => 0x95,
                    .lt_f32 => 0x92,
                    .le_f32 => 0x96,
                    .gt_f32 => 0x97,
                    .ge_f32 => 0x93,
                    else => unreachable,
                };
                try cg.emitRex(false, 0, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(setcc);
                try cg.emit(0xC0 | (rd & 7));
                try cg.emitRex(true, rd, 0, rd);
                try cg.emit(0x0F);
                try cg.emit(0xB6);
                try cg.emit(0xC0 | ((rd & 7) << 3) | (rd & 7));
            },

            // ════════ 类型转换 ════════
            .i64_to_f64 => {
                // cvtsi2sd xmm_rd, r_rn（整数 → f64）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvtsi2sd64(&cg, rd, rn);
            },
            .f64_to_i64 => {
                // cvttsd2si r_rd, xmm_rn（f64 → 整数，截断）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvttsd2si64(&cg, rd, rn);
            },
            .i64_to_f32 => {
                // cvtsi2ss xmm_rd, r_rn（整数 → f32）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvtsi2ss64(&cg, rd, rn);
            },
            .f32_to_i64 => {
                // cvttss2si r_rd, xmm_rn（f32 → 整数，截断）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvttss2si64(&cg, rd, rn);
            },
            .f32_to_f64 => {
                // cvtss2sd xmm_rd, xmm_rn（f32 → f64，扩展精度）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvtss2sd(&cg, rd, rn);
            },
            .f64_to_f32 => {
                // cvtsd2ss xmm_rd, xmm_rn（f64 → f32，截断精度）
                const rd = cg.resolveReg(inst.dst);
                const rn = cg.resolveReg(inst.a.vreg);
                try emitCvtsd2ss(&cg, rd, rn);
            },
        }
    }

    // ════════ 回填跳转目标 ════════
    for (cg.pending_fixups.items) |fixup| {
        const target_offset = cg.label_offsets.get(fixup.target_label) orelse {
            return error.JitMissingLabel;
        };
        // rel32 = target - (fixup.rel32_offset + 4)
        const rel32: i32 = @intCast(@as(i64, target_offset) - @as(i64, fixup.rel32_offset + 4));
        const bytes = std.mem.asBytes(&rel32);
        cg.code.items[fixup.rel32_offset] = bytes[0];
        cg.code.items[fixup.rel32_offset + 1] = bytes[1];
        cg.code.items[fixup.rel32_offset + 2] = bytes[2];
        cg.code.items[fixup.rel32_offset + 3] = bytes[3];
    }

    // ════════ 写入可执行内存 ════════
    const code_bytes = cg.code.items.len;
    const dst = exec_mem.alloc(code_bytes) orelse return error.JitOutOfExecMemory;
    @memcpy(dst[0..code_bytes], cg.code.items);
    return @intFromPtr(dst);
}

/// 发射 mov r64, r64 指令。
fn emitMovReg(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emitRex(true, rs, 0, rd);
    try cg.emit(0x89);
    try cg.emit(0xC0 | ((rs & 7) << 3) | (rd & 7));
}

// ── SSE2 浮点指令编码（IR 后端专用）──

/// ModRM 字节（mod=3 寄存器模式）。
fn modrm3(reg: u8, rm: u8) u8 {
    return 0xC0 | ((reg & 7) << 3) | (rm & 7);
}

/// movsd xmm, xmm (0xF2 [REX] 0x0F 0x10 /r) — 寄存器间移动低 64 位
fn emitMovsdReg(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x10);
    try cg.emit(modrm3(rd, rs));
}

/// movss xmm, xmm (0xF3 [REX] 0x0F 0x10 /r) — 寄存器间移动低 32 位
fn emitMovssReg(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x10);
    try cg.emit(modrm3(rd, rs));
}

/// addsd xmm, xmm (0xF2 [REX] 0x0F 0x58 /r)
fn emitAddsd(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x58);
    try cg.emit(modrm3(rd, rs));
}

/// subsd xmm, xmm (0xF2 [REX] 0x0F 0x5C /r)
fn emitSubsd(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5C);
    try cg.emit(modrm3(rd, rs));
}

/// mulsd xmm, xmm (0xF2 [REX] 0x0F 0x59 /r)
fn emitMulsd(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x59);
    try cg.emit(modrm3(rd, rs));
}

/// divsd xmm, xmm (0xF2 [REX] 0x0F 0x5E /r)
fn emitDivsd(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5E);
    try cg.emit(modrm3(rd, rs));
}

/// addss xmm, xmm (0xF3 [REX] 0x0F 0x58 /r)
fn emitAddss(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x58);
    try cg.emit(modrm3(rd, rs));
}

/// subss xmm, xmm (0xF3 [REX] 0x0F 0x5C /r)
fn emitSubss(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5C);
    try cg.emit(modrm3(rd, rs));
}

/// mulss xmm, xmm (0xF3 [REX] 0x0F 0x59 /r)
fn emitMulss(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x59);
    try cg.emit(modrm3(rd, rs));
}

/// divss xmm, xmm (0xF3 [REX] 0x0F 0x5E /r)
fn emitDivss(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5E);
    try cg.emit(modrm3(rd, rs));
}

/// ucomisd xmm, xmm (0x66 [REX] 0x0F 0x2E /r)
fn emitUcomisd(cg: *Codegen, rn: u8, rm: u8) !void {
    try cg.emit(0x66);
    try cg.emitRex(false, rn, 0, rm);
    try cg.emit(0x0F);
    try cg.emit(0x2E);
    try cg.emit(modrm3(rn, rm));
}

/// ucomiss xmm, xmm ([REX] 0x0F 0x2E /r)
fn emitUcomiss(cg: *Codegen, rn: u8, rm: u8) !void {
    try cg.emitRex(false, rn, 0, rm);
    try cg.emit(0x0F);
    try cg.emit(0x2E);
    try cg.emit(modrm3(rn, rm));
}

/// cvtsi2sd xmm, r64 (0xF2 REX.W 0x0F 0x2A /r) — 整数转 f64
fn emitCvtsi2sd64(cg: *Codegen, xmm: u8, rd: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(true, xmm, 0, rd);
    try cg.emit(0x0F);
    try cg.emit(0x2A);
    try cg.emit(modrm3(xmm, rd));
}

/// cvttsd2si r64, xmm (0xF2 REX.W 0x0F 0x2C /r) — f64 转整数（截断）
fn emitCvttsd2si64(cg: *Codegen, rd: u8, xmm: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(true, rd, 0, xmm);
    try cg.emit(0x0F);
    try cg.emit(0x2C);
    try cg.emit(modrm3(rd, xmm));
}

/// cvtsi2ss xmm, r64 (0xF3 REX.W 0x0F 0x2A /r) — 整数转 f32
fn emitCvtsi2ss64(cg: *Codegen, xmm: u8, rd: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(true, xmm, 0, rd);
    try cg.emit(0x0F);
    try cg.emit(0x2A);
    try cg.emit(modrm3(xmm, rd));
}

/// cvttss2si r64, xmm (0xF3 REX.W 0x0F 0x2C /r) — f32 转整数（截断）
fn emitCvttss2si64(cg: *Codegen, rd: u8, xmm: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(true, rd, 0, xmm);
    try cg.emit(0x0F);
    try cg.emit(0x2C);
    try cg.emit(modrm3(rd, xmm));
}

/// cvtss2sd xmm, xmm (0xF3 [REX] 0x0F 0x5A /r) — f32 转 f64
fn emitCvtss2sd(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF3);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5A);
    try cg.emit(modrm3(rd, rs));
}

/// cvtsd2ss xmm, xmm (0xF2 [REX] 0x0F 0x5A /r) — f64 转 f32
fn emitCvtsd2ss(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x5A);
    try cg.emit(modrm3(rd, rs));
}

/// movq xmm, r64 (0x66 REX.W 0x0F 0x6E /r) — 从 GPR 移动 64 位到 XMM
fn emitMovqGprToXmm(cg: *Codegen, xmm: u8, rd: u8) !void {
    try cg.emit(0x66);
    try cg.emitRex(true, xmm, 0, rd);
    try cg.emit(0x0F);
    try cg.emit(0x6E);
    try cg.emit(modrm3(xmm, rd));
}

/// movd xmm, r32 (0x66 [REX] 0x0F 0x6E /r) — 从 GPR 移动 32 位到 XMM
fn emitMovdGprToXmm(cg: *Codegen, xmm: u8, rd: u8) !void {
    try cg.emit(0x66);
    try cg.emitRex(false, xmm, 0, rd);
    try cg.emit(0x0F);
    try cg.emit(0x6E);
    try cg.emit(modrm3(xmm, rd));
}

/// movq r64, xmm (0x66 REX.W 0x0F 0x7E /r) — 从 XMM 移动 64 位到 GPR
fn emitMovqXmmToGpr(cg: *Codegen, rd: u8, xmm: u8) !void {
    try cg.emit(0x66);
    try cg.emitRex(true, rd, 0, xmm);
    try cg.emit(0x0F);
    try cg.emit(0x7E);
    try cg.emit(modrm3(rd, xmm));
}

/// movd r32, xmm (0x66 [REX] 0x0F 0x7E /r) — 从 XMM 移动 32 位到 GPR
fn emitMovdXmmToGpr(cg: *Codegen, rd: u8, xmm: u8) !void {
    try cg.emit(0x66);
    try cg.emitRex(false, rd, 0, xmm);
    try cg.emit(0x0F);
    try cg.emit(0x7E);
    try cg.emit(modrm3(rd, xmm));
}

/// xorps xmm, xmm ([REX] 0x0F 0x57 /r) — 按位异或
fn emitXorps(cg: *Codegen, rd: u8, rs: u8) !void {
    try cg.emitRex(false, rd, 0, rs);
    try cg.emit(0x0F);
    try cg.emit(0x57);
    try cg.emit(modrm3(rd, rs));
}

/// movsd [r64 + disp8], xmm (0xF2 [REX] 0x0F 0x11 /r) — 存储 XMM 到内存
fn emitMovsdStoreMem(cg: *Codegen, base: u8, disp: i8, xmm: u8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, xmm, 0, base);
    try cg.emit(0x0F);
    try cg.emit(0x11);
    // ModRM: mod=01 (disp8), reg=xmm, rm=base
    try cg.emit(0x40 | ((xmm & 7) << 3) | (base & 7));
    try cg.emit(@bitCast(disp));
}

/// movsd xmm, [r64 + disp8] (0xF2 [REX] 0x0F 0x10 /r) — 从内存加载到 XMM
fn emitMovsdLoadMem(cg: *Codegen, xmm: u8, base: u8, disp: i8) !void {
    try cg.emit(0xF2);
    try cg.emitRex(false, xmm, 0, base);
    try cg.emit(0x0F);
    try cg.emit(0x10);
    try cg.emit(0x40 | ((xmm & 7) << 3) | (base & 7));
    try cg.emit(@bitCast(disp));
}

// ════════════════════════════════════════════════════════════════════
// 桥接协作模式：直接从字节码生成 x86-64 机器码
// ════════════════════════════════════════════════════════════════════

/// 是否为 Windows 平台（影响 C 调用约定：Windows x64 vs System V AMD64）。
const is_windows = builtin.os.tag == .windows;

/// 桥接模式栈空间：
/// - Windows: 32 字节 shadow space + 16 字节栈参数 + 8 字节对齐 = 56
/// - System V: 仅 8 字节对齐
const STACK_SPACE: u32 = if (is_windows) 56 else 8;

/// JIT 函数入口的参数寄存器（C 调用约定）。
const ARG0 = if (is_windows) GPR.rcx else GPR.rdi; // vm
const ARG1 = if (is_windows) GPR.rdx else GPR.rsi; // base

/// 调用 rt_* 函数时的参数寄存器（C 调用约定）。
/// Windows: rcx, rdx, r8, r9（第 5/6 参数在栈上）
/// System V: rdi, rsi, rdx, rcx, r8, r9
const CARG0 = if (is_windows) GPR.rcx else GPR.rdi;
const CARG1 = if (is_windows) GPR.rdx else GPR.rsi;
const CARG2 = if (is_windows) GPR.r8 else GPR.rdx;
const CARG3 = if (is_windows) GPR.r9 else GPR.rcx;
const CARG4 = if (is_windows) null else GPR.r8;
const CARG5 = if (is_windows) null else GPR.r9;

/// 桥接模式使用的 callee-saved 寄存器：
/// r12 = vm, r13 = base, r14 = rt_step, r15 = rt_call_inline, rbx = rt_array_push
const BR_VM = GPR.r12;
const BR_BASE = GPR.r13;
const BR_RT_STEP = GPR.r14;
const BR_RT_CALL = GPR.r15;
const BR_RT_PUSH = GPR.rbx;

/// 桥接模式使用的临时寄存器（caller-saved）。
const TMP0 = GPR.rax; // 算术、返回值
const TMP1 = GPR.r11; // 通用临时
const TMP2 = GPR.r10; // frame base（reg_pool + base * 32）

/// FPR 常驻池：xmm2-xmm5（4 个，全部 volatile，Windows/System V 均无需 prologue 保存）。
/// xmm0/xmm1 保留为运算 scratch。每个 xmm 缓存一个 f64 reg 的 bits（不写内存）。
const FPR_POOL = [_]u8{ FPR.xmm2, FPR.xmm3, FPR.xmm4, FPR.xmm5 };
const FPR_NONE: i8 = -1; // fpr_map 中表示"未分配"

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
/// 最大标量 tag 值（float=5）。tag 0-5 为标量，无需引用计数。
const MAX_SCALAR_TAG: u8 = runtime.TAG_FLOAT;

/// Value 内存布局偏移量。
const TAG_OFF: u32 = @intCast(runtime.TAG_OFFSET); // 24
const PAYLOAD_OFF: u32 = @intCast(runtime.PAYLOAD_OFFSET); // 0
const INT_LO_OFF: u32 = @intCast(runtime.INT_LO_OFFSET); // 0
const INT_TYPE_OFF: u32 = @intCast(runtime.INT_TYPE_OFFSET); // 16
const FLOAT_BITS_OFF: u32 = @intCast(runtime.FLOAT_BITS_OFFSET); // 0
const FLOAT_TYPE_OFF: u32 = @intCast(runtime.FLOAT_TYPE_OFFSET); // 16

// ════════════════════════════════════════════════════════════════════
// x86-64 指令编码辅助函数（桥接模式专用）
// ════════════════════════════════════════════════════════════════════

/// 桥接模式代码缓冲区。
const BridgeBuf = struct {
    code: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn append(self: *BridgeBuf, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    fn appendSlice(self: *BridgeBuf, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    fn appendU32(self: *BridgeBuf, val: u32) !void {
        try self.code.appendSlice(self.allocator, std.mem.asBytes(&val));
    }

    fn appendI32(self: *BridgeBuf, val: i32) !void {
        try self.code.appendSlice(self.allocator, std.mem.asBytes(&val));
    }

    fn len(self: *const BridgeBuf) u32 {
        return @intCast(self.code.items.len);
    }

    /// 发射 REX 前缀（仅在需要时）。
    /// w: 64位操作, r: reg字段扩展, x: index扩展, b: rm/base扩展
    fn rex(self: *BridgeBuf, w: bool, r: u8, x: u8, b: u8) !void {
        var rex_val: u8 = 0x40;
        if (w) rex_val |= 0x08;
        if (r >= 8) rex_val |= 0x04;
        if (x >= 8) rex_val |= 0x02;
        if (b >= 8) rex_val |= 0x01;
        if (rex_val != 0x40) try self.append(rex_val);
    }

    /// ModRM 字节。
    fn modrm(mod: u8, reg: u8, rm: u8) u8 {
        return (mod << 6) | ((reg & 7) << 3) | (rm & 7);
    }

    /// 发射 ModRM + 可选 SIB 字节。
    /// 当 base 的低 3 位为 4（rsp 或 r12）时，ModRM 的 rm 字段为 4
    /// 表示"SIB 字节跟随"，必须发射 SIB。SIB=0x24 表示：
    /// scale=0, index=none(4), base=4（配合 REX.B 即为 r12）。
    fn modrmMem(self: *BridgeBuf, mod: u8, reg: u8, base: u8) !void {
        try self.append(modrm(mod, reg, base));
        if ((base & 7) == 4) {
            try self.append(0x24);
        }
    }

    /// mov r64, r64 (REX.W + 0x89 + ModRM)
    fn movReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x89);
        try self.append(modrm(3, rs, rd));
    }

    /// mov r64, imm64 (REX.W + 0xB8+rd + imm64)
    fn movImm64(self: *BridgeBuf, rd: u8, val: u64) !void {
        try self.rex(true, 0, 0, rd);
        try self.append(0xB8 + (rd & 7));
        const bytes = std.mem.asBytes(&val);
        try self.appendSlice(bytes);
    }

    /// mov r64, [r64 + disp32] (REX.W + 0x8B + ModRM(mod=10))
    fn loadMem(self: *BridgeBuf, rd: u8, base: u8, disp: i32) !void {
        try self.rex(true, rd, 0, base);
        try self.append(0x8B);
        try self.modrmMem(2, rd, base);
        try self.appendI32(disp);
    }

    /// mov [r64 + disp32], r64 (REX.W + 0x89 + ModRM(mod=10))
    fn storeMem(self: *BridgeBuf, base: u8, disp: i32, rs: u8) !void {
        try self.rex(true, rs, 0, base);
        try self.append(0x89);
        try self.modrmMem(2, rs, base);
        try self.appendI32(disp);
    }

    /// movzx r64, byte [r64 + disp32] (REX.W + 0x0F 0xB6 + ModRM(mod=10))
    fn loadByte(self: *BridgeBuf, rd: u8, base: u8, disp: i32) !void {
        try self.rex(true, rd, 0, base);
        try self.append(0x0F);
        try self.append(0xB6);
        try self.modrmMem(2, rd, base);
        try self.appendI32(disp);
    }

    /// mov byte [r64 + disp32], r8 (REX + 0x88 + ModRM(mod=10))
    /// 注意：byte store 不需要 REX.W，但需要 REX.B if base >= r8
    fn storeByte(self: *BridgeBuf, base: u8, disp: i32, rs: u8) !void {
        try self.rex(false, rs, 0, base);
        try self.append(0x88);
        try self.modrmMem(2, rs, base);
        try self.appendI32(disp);
    }

    /// add r64, r64 (REX.W + 0x01 + ModRM(mod=3))
    fn addReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x01);
        try self.append(modrm(3, rs, rd));
    }

    /// sub r64, r64 (REX.W + 0x29 + ModRM(mod=3))
    fn subReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x29);
        try self.append(modrm(3, rs, rd));
    }

    /// imul r64, r64 (REX.W + 0x0F 0xAF + ModRM(mod=3))
    fn imulReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0xAF);
        try self.append(modrm(3, rd, rs));
    }

    /// idiv r64 (REX.W + 0xF7 /7 + ModRM(mod=3))
    /// 商在 rax，余数在 rdx；需先用 cqo 符号扩展
    fn idivReg(self: *BridgeBuf, divisor: u8) !void {
        try self.rex(true, 7, 0, divisor);
        try self.append(0xF7);
        try self.append(modrm(3, 7, divisor));
    }

    /// cqo: 符号扩展 rax → rdx:rax (REX.W + 0x99)
    fn cqo(self: *BridgeBuf) !void {
        try self.append(0x48);
        try self.append(0x99);
    }

    /// neg r64 (REX.W + 0xF7 /3 + ModRM(mod=3))
    fn negReg(self: *BridgeBuf, rd: u8) !void {
        try self.rex(true, 3, 0, rd);
        try self.append(0xF7);
        try self.append(modrm(3, 3, rd));
    }

    /// not r64 (REX.W + 0xF7 /2 + ModRM(mod=3))
    fn notReg(self: *BridgeBuf, rd: u8) !void {
        try self.rex(true, 2, 0, rd);
        try self.append(0xF7);
        try self.append(modrm(3, 2, rd));
    }

    /// and r64, r64 (REX.W + 0x21 + ModRM(mod=3))
    fn andReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x21);
        try self.append(modrm(3, rs, rd));
    }

    /// or r64, r64 (REX.W + 0x09 + ModRM(mod=3))
    fn orReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x09);
        try self.append(modrm(3, rs, rd));
    }

    /// xor r64, r64 (REX.W + 0x31 + ModRM(mod=3))
    fn xorReg(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rs, 0, rd);
        try self.append(0x31);
        try self.append(modrm(3, rs, rd));
    }

    /// xor r64, r64 (自身异或，清零）
    fn xorSelf(self: *BridgeBuf, rd: u8) !void {
        try self.rex(true, rd, 0, rd);
        try self.append(0x31);
        try self.append(modrm(3, rd, rd));
    }

    /// cmp r64, r64 (REX.W + 0x39 + ModRM(mod=3))
    fn cmpReg(self: *BridgeBuf, rn: u8, rm: u8) !void {
        try self.rex(true, rm, 0, rn);
        try self.append(0x39);
        try self.append(modrm(3, rm, rn));
    }

    /// cmp byte [r64 + disp32], imm8 (REX + 0x80 /7 + ModRM(mod=10))
    fn cmpByteMemImm(self: *BridgeBuf, base: u8, disp: i32, imm: u8) !void {
        try self.rex(false, 7, 0, base);
        try self.append(0x80);
        try self.modrmMem(2, 7, base);
        try self.appendI32(disp);
        try self.append(imm);
    }

    /// cmp r64, imm8 (REX.W + 0x83 /7 + ModRM(mod=3) + imm8)
    fn cmpImm8(self: *BridgeBuf, rd: u8, imm: u8) !void {
        try self.rex(true, 7, 0, rd);
        try self.append(0x83);
        try self.append(modrm(3, 7, rd));
        try self.append(imm);
    }

    /// test r64, r64 (REX.W + 0x85 + ModRM(mod=3))
    fn testReg(self: *BridgeBuf, rn: u8, rm: u8) !void {
        try self.rex(true, rm, 0, rn);
        try self.append(0x85);
        try self.append(modrm(3, rm, rn));
    }

    /// setcc r8 (0x0F 0x90+cc + ModRM(mod=3))
    /// cc: 4=SETE, 5=SETNE, C=SETL, E=SETLE, G=SETG, D=SETGE
    fn setcc(self: *BridgeBuf, rd: u8, cc: u8) !void {
        try self.rex(false, 0, 0, rd);
        try self.append(0x0F);
        try self.append(0x90 + cc);
        try self.append(modrm(3, 0, rd));
    }

    /// movzx r64, r8 (REX.W + 0x0F 0xB6 + ModRM(mod=3))
    fn movzxR8(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0xB6);
        try self.append(modrm(3, rd, rs));
    }

    /// jmp rel32 (0xE9 + rel32) — 占位时 rel32=0
    fn jmpRel32(self: *BridgeBuf) !u32 {
        const pos = self.len();
        try self.append(0xE9);
        try self.appendI32(0);
        return pos;
    }

    /// jcc rel32 (0x0F 0x80+cc + rel32) — 占位时 rel32=0
    fn jccRel32(self: *BridgeBuf, cc: u8) !u32 {
        const pos = self.len();
        try self.append(0x0F);
        try self.append(0x80 + cc);
        try self.appendI32(0);
        return pos;
    }

    /// call r64 (REX + 0xFF /2 + ModRM(mod=3))
    fn callReg(self: *BridgeBuf, rd: u8) !void {
        try self.rex(false, 2, 0, rd);
        try self.append(0xFF);
        try self.append(modrm(3, 2, rd));
    }

    /// push r64 (REX.B if r>=8 + 0x50+rd)
    fn pushReg(self: *BridgeBuf, rd: u8) !void {
        try self.rex(false, 0, 0, rd);
        try self.append(0x50 + (rd & 7));
    }

    /// pop r64 (REX.B if r>=8 + 0x58+rd)
    fn popReg(self: *BridgeBuf, rd: u8) !void {
        try self.rex(false, 0, 0, rd);
        try self.append(0x58 + (rd & 7));
    }

    /// ret (0xC3)
    fn ret(self: *BridgeBuf) !void {
        try self.append(0xC3);
    }

    /// sub rsp, imm8 (REX.W + 0x83 /5 + ModRM + imm8)
    fn subRspImm8(self: *BridgeBuf, imm: u8) !void {
        try self.append(0x48);
        try self.append(0x83);
        try self.append(0xEC);
        try self.append(imm);
    }

    /// add rsp, imm8 (REX.W + 0x83 /0 + ModRM + imm8)
    fn addRspImm8(self: *BridgeBuf, imm: u8) !void {
        try self.append(0x48);
        try self.append(0x83);
        try self.append(0xC4);
        try self.append(imm);
    }

    /// mov byte [r64 + disp32], imm8 (REX + 0xC6 /0 + ModRM(mod=10) + disp32 + imm8)
    fn storeByteImm(self: *BridgeBuf, base: u8, disp: i32, imm: u8) !void {
        try self.rex(false, 0, 0, base);
        try self.append(0xC6);
        try self.modrmMem(2, 0, base);
        try self.appendI32(disp);
        try self.append(imm);
    }

    /// mov [r64 + disp32], imm32 (REX.W + 0xC7 /0 + ModRM(mod=10) + disp32 + imm32)
    fn storeMemImm32(self: *BridgeBuf, base: u8, disp: i32, imm: u32) !void {
        try self.rex(true, 0, 0, base);
        try self.append(0xC7);
        try self.modrmMem(2, 0, base);
        try self.appendI32(disp);
        try self.appendU32(imm);
    }

    // ── SSE2 浮点指令 ──

    /// movsd xmm, [r64 + disp32] (0xF2 0x0F 0x10 + ModRM(mod=10))
    fn movsdLoad(self: *BridgeBuf, xmm: u8, base: u8, disp: i32) !void {
        try self.append(0xF2);
        try self.rex(true, xmm, 0, base);
        try self.append(0x0F);
        try self.append(0x10);
        try self.modrmMem(2, xmm, base);
        try self.appendI32(disp);
    }

    /// movsd [r64 + disp32], xmm (0xF2 0x0F 0x11 + ModRM(mod=10))
    fn movsdStore(self: *BridgeBuf, base: u8, disp: i32, xmm: u8) !void {
        try self.append(0xF2);
        try self.rex(true, xmm, 0, base);
        try self.append(0x0F);
        try self.append(0x11);
        try self.modrmMem(2, xmm, base);
        try self.appendI32(disp);
    }

    /// movsd xmm, xmm (0xF2 0x0F 0x10 + ModRM(mod=3)) — 寄存器间移动低 64 位
    fn movsdReg(self: *BridgeBuf, dst: u8, src: u8) !void {
        try self.append(0xF2);
        try self.rex(true, dst, 0, src);
        try self.append(0x0F);
        try self.append(0x10);
        try self.append(modrm(3, dst, src));
    }

    /// addsd xmm, xmm (0xF2 0x0F 0x58 + ModRM(mod=3))
    fn addsd(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.append(0xF2);
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0x58);
        try self.append(modrm(3, rd, rs));
    }

    /// subsd xmm, xmm (0xF2 0x0F 0x5C + ModRM(mod=3))
    fn subsd(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.append(0xF2);
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0x5C);
        try self.append(modrm(3, rd, rs));
    }

    /// mulsd xmm, xmm (0xF2 0x0F 0x59 + ModRM(mod=3))
    fn mulsd(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.append(0xF2);
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0x59);
        try self.append(modrm(3, rd, rs));
    }

    /// divsd xmm, xmm (0xF2 0x0F 0x5E + ModRM(mod=3))
    fn divsd(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.append(0xF2);
        try self.rex(true, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0x5E);
        try self.append(modrm(3, rd, rs));
    }

    /// ucomisd xmm, xmm (0x66 0x0F 0x2E + ModRM(mod=3))
    fn ucomisd(self: *BridgeBuf, rn: u8, rm: u8) !void {
        try self.append(0x66);
        try self.rex(true, rn, 0, rm);
        try self.append(0x0F);
        try self.append(0x2E);
        try self.append(modrm(3, rn, rm));
    }

    /// cvtsi2sd xmm, r64 (0xF2 0x0F 0x2A + ModRM(mod=3))
    /// 整数转浮点
    fn cvtsi2sd(self: *BridgeBuf, xmm: u8, rd: u8) !void {
        try self.append(0xF2);
        try self.rex(true, xmm, 0, rd);
        try self.append(0x0F);
        try self.append(0x2A);
        try self.append(modrm(3, xmm, rd));
    }

    /// cvttsd2si r64, xmm (0xF2 0x0F 0x2C + ModRM(mod=3))
    /// 浮点转整数（截断）
    fn cvttsd2si(self: *BridgeBuf, rd: u8, xmm: u8) !void {
        try self.append(0xF2);
        try self.rex(true, rd, 0, xmm);
        try self.append(0x0F);
        try self.append(0x2C);
        try self.append(modrm(3, rd, xmm));
    }

    /// movq xmm, r64 (0x66 REX.W 0x0F 0x6E + ModRM(mod=3))
    /// 从 GPR 移动 64 位到 XMM
    fn movqGprToXmm(self: *BridgeBuf, xmm: u8, rd: u8) !void {
        try self.append(0x66);
        try self.rex(true, xmm, 0, rd);
        try self.append(0x0F);
        try self.append(0x6E);
        try self.append(modrm(3, xmm, rd));
    }

    /// xorps xmm, xmm (0x0F 0x57 + ModRM(mod=3))
    /// 按位异或（用于翻转符号位）
    fn xorps(self: *BridgeBuf, rd: u8, rs: u8) !void {
        try self.rex(false, rd, 0, rs);
        try self.append(0x0F);
        try self.append(0x57);
        try self.append(modrm(3, rd, rs));
    }

    /// 回填 rel32 跳转目标。
    /// rel32 = target_offset - (rel32_pos + 4)
    fn patchRel32(code: []u8, rel32_pos: u32, target_offset: u32) void {
        const rel32: i32 = @intCast(@as(i64, target_offset) - @as(i64, rel32_pos + 4));
        const bytes = std.mem.asBytes(&rel32);
        code[rel32_pos] = bytes[0];
        code[rel32_pos + 1] = bytes[1];
        code[rel32_pos + 2] = bytes[2];
        code[rel32_pos + 3] = bytes[3];
    }
};

/// x86-64 条件码（用于 Jcc / SETcc 指令）。
/// E=0x4(相等), NE=0x5(不等), L=0xC(有符号小于), LE=0xE, G=0xF, GE=0xD
const X86Cond = struct {
    pub const E: u8 = 0x4;
    pub const NE: u8 = 0x5;
    pub const L: u8 = 0xC;
    pub const LE: u8 = 0xE;
    pub const G: u8 = 0xF;
    pub const GE: u8 = 0xD;
    pub const B: u8 = 0x2; // 无符号小于 (CF=1)
    pub const AE: u8 = 0x3; // 无符号大于等于 (CF=0)
    pub const A: u8 = 0x7; // 无符号大于 (CF=0 && ZF=0)
    pub const BE: u8 = 0x6; // 无符号小于等于
};

/// 加载 64 位地址到寄存器。
fn loadAddr64(buf: *BridgeBuf, rd: u8, addr: u64) !void {
    try buf.movImm64(rd, addr);
}

/// 发射计算 frame base 的代码：r10 = reg_pool + base * 32
/// reg_pool 指针从 [vm + REG_POOL_PTR_OFFSET] 加载。
fn emitFrameBase(buf: *BridgeBuf) !void {
    // mov r10, [r12 + REG_POOL_PTR_OFFSET]
    try buf.loadMem(TMP2, BR_VM, @intCast(REG_POOL_PTR_OFFSET));
    // mov r11, r13 (base)
    try buf.movReg(TMP1, BR_BASE);
    // shl r11, 5 (base * 32)
    // REX.WB=0x49, opcode=0xC1, ModRM(3, /4=SHL, rm=3) → r11 (3 + REX.B*8 = 11)
    try buf.append(0x49);
    try buf.append(0xC1);
    try buf.append(0xE3); // ModRM(3, 4, 3) = shl r11, imm8
    try buf.append(5);
    // add r10, r11
    try buf.addReg(TMP2, TMP1);
}

/// 发射 rt_step 桥接调用代码。
/// rt_step(vm, ip) — 返回 false=继续, true=函数已返回
/// 调用后 emit cbnz_exit (test rax + jne exit)
/// 调用前自动 spill 所有常驻 FPR（rt_step 可能修改 reg_pool）。
fn emitRtStepCall(
    buf: *BridgeBuf,
    ip: u32,
    pending_fixups: *std.ArrayListUnmanaged(BridgeFixup),
    allocator: std.mem.Allocator,
    fpr: *FprState,
) !void {
    // 清空 FPR 常驻状态（rt_step 会修改 reg_pool，xmm 缓存失效）
    try emitFrameBase(buf);
    fpr.invalidateAll();
    // 设置参数: CARG0 = vm (r12), CARG1 = ip
    try buf.movReg(CARG0, BR_VM);
    try buf.movImm64(CARG1, @intCast(ip));
    // call rt_step (r14)
    try buf.callReg(BR_RT_STEP);
    // test rax, rax
    try buf.testReg(TMP0, TMP0);
    // jne exit (占位)
    const jne_pos = try buf.jccRel32(X86Cond.NE);
    try pending_fixups.append(allocator, .{
        .code_offset = jne_pos,
        .target_ip = 0xFFFFFFFF,
        .kind = 3, // exit 跳转
        .rel32_pos = jne_pos + 2, // skip 0F 85
    });
}

/// 待回填的跳转（桥接模式专用，区别于 IR 模式的 Codegen.Fixup）。
const BridgeFixup = struct {
    code_offset: u32, // 跳转指令在 code 中的偏移
    target_ip: u32, // 目标字节码 IP（0xFFFFFFFF = exit）
    kind: u8, // 1=jmp, 2=jcc, 3=exit
    rel32_pos: u32, // rel32 字段的偏移量
};

/// FPR 常驻状态：跟踪 reg_pool 槽位 → XMM 寄存器的映射。
/// fpr_map[reg] = FPR_NONE 表示该 reg 的 f64 bits 仅在内存中；
/// 否则值 = FPR_POOL 索引（0..FPR_POOL.len-1），对应 xmm 寄存器持有最新 bits。
/// fpr_owner[pool_idx] = 持有该 xmm 的 reg 编号（仅当 fpr_map[reg]==pool_idx 时有效）。
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

    /// 获取 reg 对应的 xmm 编号；调用方需先 isResident 判断
    fn getXmm(self: *const FprState, reg: u8) u8 {
        const idx: usize = @intCast(self.fpr_map[reg]);
        return FPR_POOL[idx];
    }

    /// 将 reg 标记为常驻到 pool_idx 对应的 xmm（替换原 owner）
    fn setResident(self: *FprState, reg: u8, pool_idx: usize) void {
        // 先驱逐原 owner（如果有）
        const old_owner = self.fpr_owner[pool_idx];
        if (old_owner != 0xFF and old_owner < self.fpr_map.len) {
            self.fpr_map[old_owner] = FPR_NONE;
        }
        // 清除 reg 的旧映射（如果 reg 之前在其他 xmm）
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

    /// 清空所有 FPR 映射（跳转目标处重置）
    fn invalidateAll(self: *FprState) void {
        @memset(self.fpr_map, FPR_NONE);
        self.fpr_owner = [_]u8{0xFF} ** FPR_POOL.len;
    }
};

/// 确保 reg 的 f64 bits 加载到某个 xmm，返回 xmm 编号。
/// 若已常驻直接返回；否则从内存加载并标记常驻（必要时驱逐一个非 protect_reg 的槽）。
/// 调用前需已 emitFrameBase。
/// 仅用于编译时已知 f64 的路径；未知类型路径应使用 xmm6/xmm7 直接加载。
/// protect_reg: 指定一个 reg 编号，其常驻 xmm 不允许被驱逐（传 0xFF 表示无保护）。
fn emitEnsureFpr(buf: *BridgeBuf, fpr: *FprState, reg: u8, protect_reg: u8) !u8 {
    if (fpr.isResident(reg)) return fpr.getXmm(reg);
    // 分配空闲槽
    const slot = fpr.allocSlot() orelse blk: {
        // 池满：驱逐一个非 protect_reg 的槽
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
            // 所有槽都是 protect_reg 或空闲（不应发生，因为 allocSlot 返回 null 说明无空闲）
            // 强制驱逐 pool[0]
            evict_idx = 0;
        }
        const victim = fpr.fpr_owner[evict_idx];
        if (victim != 0xFF) {
            fpr.evict(victim);
        }
        break :blk evict_idx;
    };
    const xmm = FPR_POOL[slot];
    try buf.movsdLoad(xmm, TMP2, @intCast(@as(i32, reg) * 32 + @as(i32, FLOAT_BITS_OFF)));
    fpr.setResident(reg, slot);
    return xmm;
}

/// 桥接模式编译：直接从字节码生成 x86-64 机器码。
///
/// JIT 函数签名: fn(vm: *RegVM, base: usize) callconv(.c) void
/// 热点 opcode（i64/f64 算术/比较/跳转）生成内联原生代码。
/// 冷门 opcode 通过 rt_step 桥接函数委托 VM 单步执行。
///
/// 仅支持 register_count <= 120 的函数（确保寄存器偏移在 disp32 范围内）。
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
    // 寄存器数过多时偏移超出 disp32 范围，不 JIT
    if (func.register_count > 120) return error.JitTooManyRegisters;
    _ = func_idx;

    var code = std.ArrayListUnmanaged(u8).empty;
    defer code.deinit(allocator);

    var buf = BridgeBuf{ .code = &code, .allocator = allocator };

    // 字节码 ip → 代码偏移映射（用于跳转回填）
    var ip_to_code = std.AutoHashMap(u32, u32).init(allocator);
    defer ip_to_code.deinit();

    // 待回填的向前跳转
    var pending_fixups = std.ArrayListUnmanaged(BridgeFixup).empty;
    defer pending_fixups.deinit(allocator);

    // ── 类型传播：跟踪每个寄存器的已知类型 ──
    const RegType = enum { unknown, i64, f64, boolean };
    const reg_count = func.register_count;
    var reg_types = try allocator.alloc(RegType, reg_count);
    defer allocator.free(reg_types);
    @memset(reg_types, .unknown);

    // ── FPR 常驻状态 ──
    var fpr_state = try FprState.init(allocator, reg_count);
    defer fpr_state.deinit(allocator);
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

    // ════════ 函数 prologue ════════
    // push rbp
    try buf.pushReg(GPR.rbp);
    // push rbx, r12, r13, r14, r15
    try buf.pushReg(GPR.rbx);
    try buf.pushReg(GPR.r12);
    try buf.pushReg(GPR.r13);
    try buf.pushReg(GPR.r14);
    try buf.pushReg(GPR.r15);
    // sub rsp, STACK_SPACE (shadow space + alignment)
    try buf.subRspImm8(@intCast(STACK_SPACE));

    // mov r12, ARG0 (vm)
    try buf.movReg(BR_VM, ARG0);
    // mov r13, ARG1 (base)
    try buf.movReg(BR_BASE, ARG1);

    // 加载 rt_step 地址到 r14
    try loadAddr64(&buf, BR_RT_STEP, rt_step_addr);
    // 加载 rt_call_inline 地址到 r15
    try loadAddr64(&buf, BR_RT_CALL, rt_call_inline_addr);
    // 加载 rt_array_push 地址到 rbx
    try loadAddr64(&buf, BR_RT_PUSH, rt_array_push_addr);

    // ════════ 函数体：遍历字节码 ════════
    const instructions = func.chunk.code.items;

    var ip: u32 = 0;
    while (ip < instructions.len) : (ip += 1) {
        // 记录字节码 ip → 代码偏移
        try ip_to_code.put(ip, buf.len());

        // 跳转目标处重置类型传播与 FPR 状态
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
            .add, .sub, .mul, .div, .mod => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                // a 将被覆盖；若 a 常驻 FPR，先 spill 回内存（防止 a==b/c 时数据丢失）。
                // i64/unknown 路径会覆盖 a 的内存字段，spill 是冗余但安全的。
                try emitFrameBase(&buf);
                fpr_state.evict(a);

                if (b_known_i64 and c_known_i64) {
                    // ── 类型已知 i64：跳过 tag 检查，直接算术 ──
                    try emitFrameBase(&buf);
                    // rax = reg_pool[b].lo
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    // r11 = reg_pool[c].lo
                    try buf.loadMem(TMP1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    switch (op) {
                        .add => try buf.addReg(TMP0, TMP1),
                        .sub => try buf.subReg(TMP0, TMP1),
                        .mul => try buf.imulReg(TMP0, TMP1),
                        .div => {
                            // cqo (sign-extend rax → rdx:rax)
                            try buf.cqo();
                            try buf.idivReg(TMP1);
                        },
                        .mod => {
                            try buf.cqo();
                            try buf.idivReg(TMP1);
                            // 余数在 rdx
                            try buf.movReg(TMP0, GPR.rdx);
                        },
                        else => unreachable,
                    }
                    // 存储 tag = TAG_INT
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    // 存储 int type = I64
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                    // 存储 lo
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);
                    reg_types[a] = .i64;
                } else if (b_known_f64 and c_known_f64 and op != .mod) {
                    // ── 类型已知 f64：跳过 tag 检查，用 FPR 池加载 ──
                    try emitFrameBase(&buf);
                    const xmm_b = try emitEnsureFpr(&buf, &fpr_state, b, 0xFF);
                    const xmm_c = try emitEnsureFpr(&buf, &fpr_state, c, b);
                    // xmm0 = xmm_b；xmm0 op= xmm_c
                    try buf.movsdReg(0, xmm_b);
                    switch (op) {
                        .add => try buf.addsd(0, xmm_c),
                        .sub => try buf.subsd(0, xmm_c),
                        .mul => try buf.mulsd(0, xmm_c),
                        .div => try buf.divsd(0, xmm_c),
                        else => unreachable,
                    }
                    // 将结果写回内存
                    try buf.movsdStore(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)), 0);
                    // 更新 tag/type（内存元数据需同步，供 cold 路径检查）
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                    // 若 a==b 或 a==c，a 的内存已更新但 b/c 的 xmm 缓存已过时，需失效
                    if (a == b) fpr_state.evict(b);
                    if (a == c) fpr_state.evict(c);
                    reg_types[a] = .f64;
                } else {
                    // ── 未知类型：带 tag 检查的通用路径 ──
                    try emitFrameBase(&buf);

                    // 检查 b 的 tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const jne1_pos = try buf.jccRel32(X86Cond.NE);

                    // 检查 c 的 tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const jne2_pos = try buf.jccRel32(X86Cond.NE);

                    // 加载 i64 值
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.loadMem(TMP1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));

                    // 执行运算
                    switch (op) {
                        .add => try buf.addReg(TMP0, TMP1),
                        .sub => try buf.subReg(TMP0, TMP1),
                        .mul => try buf.imulReg(TMP0, TMP1),
                        .div => {
                            try buf.cqo();
                            try buf.idivReg(TMP1);
                        },
                        .mod => {
                            try buf.cqo();
                            try buf.idivReg(TMP1);
                            try buf.movReg(TMP0, GPR.rdx);
                        },
                        else => unreachable,
                    }

                    // 存储 i64 结果到 dst(a)
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);

                    const b_next = try buf.jmpRel32(); // 跳过 float 路径和 cold

                    // not_int_target: 非 i64 入口
                    const not_int_target = buf.len();
                    // 回填 jne1, jne2 到 not_int_target
                    BridgeBuf.patchRel32(code.items, jne1_pos + 2, not_int_target);
                    BridgeBuf.patchRel32(code.items, jne2_pos + 2, not_int_target);

                    var b_next2: u32 = 0;

                    // ── f64 快速路径（.mod 无浮点路径，直接走 cold）──
                    if (op != .mod) {
                        // 检查 b 的 tag == TAG_FLOAT
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                        const jne_f1 = try buf.jccRel32(X86Cond.NE);

                        // 检查 c 的 tag == TAG_FLOAT
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                        const jne_f2 = try buf.jccRel32(X86Cond.NE);

                        // 检查 b 的 float type == F64
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                        const jne_f3 = try buf.jccRel32(X86Cond.NE);

                        // 检查 c 的 float type == F64
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                        const jne_f4 = try buf.jccRel32(X86Cond.NE);

                        // a 将被覆盖；若 a 常驻 FPR，先失效
                        fpr_state.evict(a);
                        // 用 xmm6/xmm7 直接加载 b、c（不走 FPR 池，避免编译时状态污染）
                        try buf.movsdLoad(FPR.xmm6, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                        try buf.movsdLoad(FPR.xmm7, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));
                        // xmm0 = xmm6；xmm0 op= xmm7
                        try buf.movsdReg(0, FPR.xmm6);
                        switch (op) {
                            .add => try buf.addsd(0, FPR.xmm7),
                            .sub => try buf.subsd(0, FPR.xmm7),
                            .mul => try buf.mulsd(0, FPR.xmm7),
                            .div => try buf.divsd(0, FPR.xmm7),
                            else => unreachable,
                        }
                        // 将结果写回 a 的内存
                        try buf.movsdStore(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)), 0);
                        // 更新 tag/type
                        try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                        try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);

                        b_next2 = try buf.jmpRel32(); // 跳过 cold

                        // cold 目标
                        const cold_off = buf.len();
                        // 回填 float jne 到 cold
                        inline for (.{ jne_f1, jne_f2, jne_f3, jne_f4 }) |jne_pos| {
                            BridgeBuf.patchRel32(code.items, jne_pos + 2, cold_off);
                        }
                    }

                    // ── cold: rt_step 桥接 ──
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    // ── .next: 回填 b_next 和 b_next2 ──
                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                    if (op != .mod) {
                        BridgeBuf.patchRel32(code.items, b_next2 + 1, next_off);
                    }
                    reg_types[a] = .unknown;
                }
            },

            // ── 热点 opcode：i64/f64 取反 ──
            .neg => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                try emitFrameBase(&buf);
                // a 将被覆盖，失效其 FPR 常驻
                fpr_state.evict(a);

                if (b_known_i64) {
                    // 类型已知 i64：跳过 tag 检查
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.negReg(TMP0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);
                    reg_types[a] = .i64;
                } else if (b_known_f64) {
                    // 类型已知 f64：用 xorps 翻转符号位（FPR 池加载）
                    const xmm_b = try emitEnsureFpr(&buf, &fpr_state, b, 0xFF);
                    // 复制 b 到 xmm0
                    try buf.movsdReg(0, xmm_b);
                    // 加载符号位掩码（仅最高位为 1）到 rax
                    try buf.movImm64(TMP0, 0x8000000000000000);
                    // movq xmm1, rax（掩码到 xmm1）
                    try buf.movqGprToXmm(1, TMP0);
                    // xorps xmm0, xmm1（翻转符号位）
                    try buf.xorps(0, 1);
                    // 将结果写回内存
                    try buf.movsdStore(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)), 0);
                    // 更新 tag/type
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                    // 若 a==b，b 的 xmm 缓存已过时
                    if (a == b) fpr_state.evict(b);
                    reg_types[a] = .f64;
                } else {
                    // 未知类型：先检查 TAG_INT，再检查 TAG_FLOAT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const jne_not_int = try buf.jccRel32(X86Cond.NE);

                    // i64 路径
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.negReg(TMP0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);

                    const b_next = try buf.jmpRel32();

                    // not_int: 检查 TAG_FLOAT
                    const not_int_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_not_int + 2, not_int_off);

                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    const jne_cold = try buf.jccRel32(X86Cond.NE);
                    // 检查 float type == F64
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                    const jne_cold2 = try buf.jccRel32(X86Cond.NE);

                    // f64 路径：用 xorps 翻转符号位（xmm6 直接加载，不走 FPR 池）
                    try buf.movsdLoad(FPR.xmm6, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.movsdReg(0, FPR.xmm6);
                    try buf.movImm64(TMP0, 0x8000000000000000);
                    try buf.movqGprToXmm(1, TMP0);
                    try buf.xorps(0, 1);
                    try buf.movsdStore(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)), 0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);

                    const b_next2 = try buf.jmpRel32();

                    // .cold
                    const cold_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_cold + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, jne_cold2 + 2, cold_off);

                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                    BridgeBuf.patchRel32(code.items, b_next2 + 1, next_off);
                    reg_types[a] = .unknown;
                }
            },

            // ── 热点 opcode：i64/f64 比较 ──
            .eq, .neq, .lt, .gt, .le, .ge => {
                const b_known_i64 = b < reg_count and reg_types[b] == .i64;
                const c_known_i64 = c < reg_count and reg_types[c] == .i64;
                const b_known_f64 = b < reg_count and reg_types[b] == .f64;
                const c_known_f64 = c < reg_count and reg_types[c] == .f64;

                // a 将被写为 boolean，失效其 FPR 常驻
                fpr_state.evict(a);

                if (b_known_i64 and c_known_i64) {
                    // ── 类型已知 i64：跳过 tag 检查 ──
                    try emitFrameBase(&buf);
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.loadMem(TMP1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.cmpReg(TMP0, TMP1);
                    const cc: u8 = switch (op) {
                        .eq => X86Cond.E,
                        .neq => X86Cond.NE,
                        .lt => X86Cond.L,
                        .gt => X86Cond.G,
                        .le => X86Cond.LE,
                        .ge => X86Cond.GE,
                        else => unreachable,
                    };
                    try buf.setcc(TMP0, cc);
                    try buf.movzxR8(TMP0, TMP0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                    try buf.storeByte(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), TMP0);
                    reg_types[a] = .boolean;
                } else if (b_known_f64 and c_known_f64) {
                    // ── 类型已知 f64：用 FPR 池加载 ──
                    try emitFrameBase(&buf);
                    const xmm_b = try emitEnsureFpr(&buf, &fpr_state, b, 0xFF);
                    const xmm_c = try emitEnsureFpr(&buf, &fpr_state, c, b);
                    // ucomisd xmm_b, xmm_c（xmm0 作 scratch）
                    try buf.movsdReg(0, xmm_b);
                    try buf.ucomisd(0, xmm_c);
                    const cc: u8 = switch (op) {
                        .eq => X86Cond.E,
                        .neq => X86Cond.NE,
                        .lt => X86Cond.B, // ucomisd: CF=1 表示小于
                        .gt => X86Cond.A, // CF=0 && ZF=0 表示大于
                        .le => X86Cond.BE,
                        .ge => X86Cond.AE,
                        else => unreachable,
                    };
                    try buf.setcc(TMP0, cc);
                    try buf.movzxR8(TMP0, TMP0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                    try buf.storeByte(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), TMP0);
                    reg_types[a] = .boolean;
                } else {
                    // ── 未知类型：带 tag 检查（INT + FLOAT 双路径）──
                    try emitFrameBase(&buf);

                    // 检查 b 的 tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const jne_not_int1 = try buf.jccRel32(X86Cond.NE);

                    // 检查 c 的 tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const jne_not_int2 = try buf.jccRel32(X86Cond.NE);

                    // i64 比较路径
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.loadMem(TMP1, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.cmpReg(TMP0, TMP1);

                    const cc_int: u8 = switch (op) {
                        .eq => X86Cond.E,
                        .neq => X86Cond.NE,
                        .lt => X86Cond.L,
                        .gt => X86Cond.G,
                        .le => X86Cond.LE,
                        .ge => X86Cond.GE,
                        else => unreachable,
                    };
                    try buf.setcc(TMP0, cc_int);
                    try buf.movzxR8(TMP0, TMP0);

                    // 存储布尔结果
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                    try buf.storeByte(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), TMP0);

                    const b_next = try buf.jmpRel32();

                    // not_int: 检查 TAG_FLOAT
                    const not_int_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_not_int1 + 2, not_int_off);
                    BridgeBuf.patchRel32(code.items, jne_not_int2 + 2, not_int_off);

                    // 检查 b 的 tag == TAG_FLOAT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    const jne_cold1 = try buf.jccRel32(X86Cond.NE);
                    // 检查 c 的 tag == TAG_FLOAT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    const jne_cold2 = try buf.jccRel32(X86Cond.NE);
                    // 检查 b 的 float type == F64
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                    const jne_cold3 = try buf.jccRel32(X86Cond.NE);
                    // 检查 c 的 float type == F64
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                    const jne_cold4 = try buf.jccRel32(X86Cond.NE);

                    // f64 比较路径：ucomisd + setcc（xmm6/xmm7 直接加载，不走 FPR 池）
                    try buf.movsdLoad(FPR.xmm6, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.movsdLoad(FPR.xmm7, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, FLOAT_BITS_OFF)));
                    try buf.movsdReg(0, FPR.xmm6);
                    try buf.ucomisd(0, FPR.xmm7);
                    const cc_float: u8 = switch (op) {
                        .eq => X86Cond.E,
                        .neq => X86Cond.NE,
                        .lt => X86Cond.B, // ucomisd: CF=1 表示小于
                        .gt => X86Cond.A, // CF=0 && ZF=0 表示大于
                        .le => X86Cond.BE,
                        .ge => X86Cond.AE,
                        else => unreachable,
                    };
                    try buf.setcc(TMP0, cc_float);
                    try buf.movzxR8(TMP0, TMP0);
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                    try buf.storeByte(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), TMP0);

                    const b_next2 = try buf.jmpRel32();

                    // .cold
                    const cold_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_cold1 + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, jne_cold2 + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, jne_cold3 + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, jne_cold4 + 2, cold_off);

                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                    BridgeBuf.patchRel32(code.items, b_next2 + 1, next_off);
                    reg_types[a] = .boolean;
                }
            },

            // ── 热点 opcode：布尔取反（一元: dst=a, src=b）──
            .not_op => {
                try emitFrameBase(&buf);
                // a 将被写为 boolean，失效其 FPR 常驻
                fpr_state.evict(a);

                // 检查源操作数 b 的 tag == TAG_BOOLEAN
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                const jne_cold = try buf.jccRel32(X86Cond.NE);

                // 加载布尔值并取反: rax = rax ^ 1
                try buf.loadByte(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, PAYLOAD_OFF)));
                try buf.append(0x48);
                try buf.append(0x83);
                try buf.append(0xF0); // xor rax, imm8
                try buf.append(1);

                // 存储结果到 dst(a)
                try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                try buf.storeByte(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), TMP0);

                const b_next = try buf.jmpRel32();

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, jne_cold + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
            },

            // ── 热点 opcode：无条件跳转 ──
            .jump => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                if (ip_to_code.get(target_ip)) |target_off| {
                    // 向后跳转：直接计算偏移
                    const jmp_pos = try buf.jmpRel32();
                    BridgeBuf.patchRel32(code.items, jmp_pos + 1, target_off);
                } else {
                    // 向前跳转：占位，稍后回填
                    const jmp_pos = try buf.jmpRel32();
                    try pending_fixups.append(allocator, .{
                        .code_offset = jmp_pos,
                        .target_ip = target_ip,
                        .kind = 1,
                        .rel32_pos = jmp_pos + 1,
                    });
                }
            },

            // ── 热点 opcode：条件跳转 ──
            .jump_if_false, .jump_if_true => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emitFrameBase(&buf);

                // 检查 tag 是否为 BOOLEAN
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                const jne_cold = try buf.jccRel32(X86Cond.NE);

                // 加载布尔值
                try buf.loadByte(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)));

                if (op == .jump_if_false) {
                    // jump_if_false: 如果值为 0 (false)，跳转到 target
                    // test rax, rax
                    try buf.testReg(TMP0, TMP0);
                    // jne next (跳过跳转)
                    const jne_next = try buf.jccRel32(X86Cond.NE);
                    // jmp target (占位)
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const jmp_pos = try buf.jmpRel32();
                        BridgeBuf.patchRel32(code.items, jmp_pos + 1, target_off);
                    } else {
                        const jmp_pos = try buf.jmpRel32();
                        try pending_fixups.append(allocator, .{
                            .code_offset = jmp_pos,
                            .target_ip = target_ip,
                            .kind = 1,
                            .rel32_pos = jmp_pos + 1,
                        });
                    }
                    // next:
                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_next + 2, next_off);
                } else {
                    // jump_if_true: 如果值不为 0 (true)，跳转到 target
                    // test rax, rax
                    try buf.testReg(TMP0, TMP0);
                    // je next (跳过跳转)
                    const je_next = try buf.jccRel32(X86Cond.E);
                    // jmp target (占位)
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const jmp_pos = try buf.jmpRel32();
                        BridgeBuf.patchRel32(code.items, jmp_pos + 1, target_off);
                    } else {
                        const jmp_pos = try buf.jmpRel32();
                        try pending_fixups.append(allocator, .{
                            .code_offset = jmp_pos,
                            .target_ip = target_ip,
                            .kind = 1,
                            .rel32_pos = jmp_pos + 1,
                        });
                    }
                    // next:
                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, je_next + 2, next_off);
                }

                const b_next = try buf.jmpRel32(); // 跳过 cold

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, jne_cold + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：null 检查跳转 ──
            .jump_if_null, .jump_if_not_null => {
                const target_ip: u32 = @intCast(@as(i64, @intCast(ip + 1)) + sbx);
                try emitFrameBase(&buf);

                // 加载 tag 字节
                try buf.loadByte(TMP0, TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)));

                if (op == .jump_if_null) {
                    // TAG_NULL = 0, 可直接用 test rax, rax + je
                    try buf.testReg(TMP0, TMP0);
                    // je target
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const je_pos = try buf.jccRel32(X86Cond.E);
                        BridgeBuf.patchRel32(code.items, je_pos + 2, target_off);
                    } else {
                        const je_pos = try buf.jccRel32(X86Cond.E);
                        try pending_fixups.append(allocator, .{
                            .code_offset = je_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                            .rel32_pos = je_pos + 2,
                        });
                    }
                } else {
                    // jump_if_not_null: CBNZ 语义
                    try buf.testReg(TMP0, TMP0);
                    // jne target
                    if (ip_to_code.get(target_ip)) |target_off| {
                        const jne_pos = try buf.jccRel32(X86Cond.NE);
                        BridgeBuf.patchRel32(code.items, jne_pos + 2, target_off);
                    } else {
                        const jne_pos = try buf.jccRel32(X86Cond.NE);
                        try pending_fixups.append(allocator, .{
                            .code_offset = jne_pos,
                            .target_ip = target_ip,
                            .kind = 2,
                            .rel32_pos = jne_pos + 2,
                        });
                    }
                }
            },

            // ── return_op / return_unit：通过 rt_step 处理，然后跳到 exit ──
            .return_op, .return_unit => {
                // rt_step(vm, ip) — rt_step 会检测到返回并返回 true
                // emitRtStepCall 内部会 spill 所有常驻 FPR
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);
            },

            // ── 热点 opcode：load_const（标量快速路径）──
            .load_const => {
                try emitFrameBase(&buf);
                // load_const 有 cold/fast 两条路径；cold 路径会 invalidateAll，
                // 为保持两条路径后 FPR 状态一致，fast 路径前也 invalidateAll。
                fpr_state.invalidateAll();

                // 加载常量池地址到 r11
                const const_addr: u64 = @intFromPtr(func.chunk.constants.items.ptr) + @as(u64, bx) * @sizeOf(value.Value);
                try loadAddr64(&buf, TMP1, const_addr);

                // 检查 dst(a) 是否标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold1 = try buf.jccRel32(X86Cond.A);

                // 检查 src(常量) 是否标量
                try buf.cmpByteMemImm(TMP1, @intCast(@as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold2 = try buf.jccRel32(X86Cond.A);

                // 快速路径：从常量池拷贝 32 字节到 reg_pool[base + a]
                // 拷贝 4 个 8 字节
                inline for (0..4) |i| {
                    try buf.loadMem(TMP0, TMP1, @intCast(i * 8));
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)), TMP0);
                }

                const b_next = try buf.jmpRel32();

                // .cold: rt_step 桥接
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, bhi_cold1 + 2, cold_off);
                BridgeBuf.patchRel32(code.items, bhi_cold2 + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);

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
            .move, .assign => {
                try emitFrameBase(&buf);
                // move 有 cold/fast 两条路径；为保持一致，fast 路径前先 spillAll。
                fpr_state.invalidateAll();

                // 检查 src(b) 是否标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold1 = try buf.jccRel32(X86Cond.A);

                // 检查 dst(a) 是否标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold2 = try buf.jccRel32(X86Cond.A);

                // 快速路径：从 reg_pool[b] 拷贝 32 字节到 reg_pool[a]
                inline for (0..4) |i| {
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, i * 8)));
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)), TMP0);
                }

                const b_next = try buf.jmpRel32();

                // .cold: rt_step 桥接
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, bhi_cold1 + 2, cold_off);
                BridgeBuf.patchRel32(code.items, bhi_cold2 + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                // 类型传播：move 复制源类型
                if (b < reg_count) reg_types[a] = reg_types[b];
            },

            // ── 热点 opcode：load_unit / load_null（标量快速路径）──
            .load_unit, .load_null => {
                try emitFrameBase(&buf);
                // 有 cold/fast 两条路径；为保持一致，fast 路径前先 spillAll。
                fpr_state.invalidateAll();

                // 检查 dst 是否标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold = try buf.jccRel32(X86Cond.A);

                // 快速路径：设置 tag
                const tag_val: u8 = if (op == .load_unit) TAG_UNIT_VAL else TAG_NULL_VAL;
                try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), tag_val);

                const b_next = try buf.jmpRel32();

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, bhi_cold + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
            },

            // ── 热点 opcode：load_true / load_false（标量快速路径）──
            .load_true, .load_false => {
                try emitFrameBase(&buf);
                // 有 cold/fast 两条路径；为保持一致，fast 路径前先 spillAll。
                fpr_state.invalidateAll();

                // 检查 dst 是否标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold = try buf.jccRel32(X86Cond.A);

                // 快速路径：设置 tag=BOOLEAN, payload=0/1
                try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_BOOLEAN_VAL);
                const payload_val: u8 = if (op == .load_true) 1 else 0;
                try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, PAYLOAD_OFF)), payload_val);

                const b_next = try buf.jmpRel32();

                // .cold
                const cold_off = buf.len();
                BridgeBuf.patchRel32(code.items, bhi_cold + 2, cold_off);

                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                reg_types[a] = .boolean;
            },

            // ── 热点 opcode：cast / coerce ──
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

                // 无法解析的类型 → rt_step 桥接
                if (int_target == null and float_target == null) {
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);
                    continue;
                }

                try emitFrameBase(&buf);
                // cast 有 cold/fast 两条路径；为保持一致，fast 路径前先 spillAll。
                fpr_state.invalidateAll();

                if (int_target) |it| {
                    // 目标是整数类型
                    // 检查 src(b) tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const bne_not_int = try buf.jccRel32(X86Cond.NE);

                    // 检查 dst(a) tag == TAG_INT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const bne_cold2 = try buf.jccRel32(X86Cond.NE);

                    // int→int 快速路径：拷贝 src 的 lo/hi，设置目标 int type
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + 8)); // hi at offset 8
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + 8), TMP0);
                    const type_byte: u8 = @intCast(@intFromEnum(it));
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), type_byte);

                    const b_next = try buf.jmpRel32();

                    // not_int: 检查 f64→i64 转换（仅 i64 目标支持）
                    const not_int_off = buf.len();
                    BridgeBuf.patchRel32(code.items, bne_not_int + 2, not_int_off);

                    if (it == .i64) {
                        // 检查 src(b) tag == TAG_FLOAT
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                        const bne_cold_f1 = try buf.jccRel32(X86Cond.NE);
                        // 检查 src(b) float type == F64
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);
                        const bne_cold_f2 = try buf.jccRel32(X86Cond.NE);
                        // 检查 dst(a) tag == TAG_INT
                        try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                        const bne_cold_f3 = try buf.jccRel32(X86Cond.NE);

                        // f64→i64：cvttsd2si（xmm6 直接加载，不走 FPR 池）
                        try buf.movsdLoad(FPR.xmm6, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, FLOAT_BITS_OFF)));
                        try buf.cvttsd2si(TMP0, FPR.xmm6);
                        try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                        try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                        try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, INT_LO_OFF)), TMP0);

                        const b_next2 = try buf.jmpRel32();

                        // .cold
                        const cold_off = buf.len();
                        BridgeBuf.patchRel32(code.items, bne_cold2 + 2, cold_off);
                        BridgeBuf.patchRel32(code.items, bne_cold_f1 + 2, cold_off);
                        BridgeBuf.patchRel32(code.items, bne_cold_f2 + 2, cold_off);
                        BridgeBuf.patchRel32(code.items, bne_cold_f3 + 2, cold_off);

                        try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                        const next_off = buf.len();
                        BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                        BridgeBuf.patchRel32(code.items, b_next2 + 1, next_off);
                    } else {
                        // 非 i64 目标：直接走 cold
                        const cold_off = buf.len();
                        BridgeBuf.patchRel32(code.items, bne_cold2 + 2, cold_off);

                        try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                        const next_off = buf.len();
                        BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                    }
                } else if (float_target) |ft| {
                    // 目标是浮点类型
                    // 检查 src(b) tag == TAG_INT（int→float 转换）
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                    const bne_cold1 = try buf.jccRel32(X86Cond.NE);

                    // 检查 src(b) int type == i64
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_TYPE_OFF)), INT_TYPE_I64_VAL);
                    const bne_cold2 = try buf.jccRel32(X86Cond.NE);

                    // 检查 dst(a) tag == TAG_FLOAT
                    try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    const bne_cold3 = try buf.jccRel32(X86Cond.NE);

                    // 仅支持 f64 目标
                    if (ft != .f64) {
                        try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);
                        continue;
                    }

                    // 加载 i64 值到 rax
                    try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, INT_LO_OFF)));
                    // cvtsi2sd xmm0, rax (i64 → f64)
                    try buf.cvtsi2sd(0, TMP0);
                    // 将结果写回 a 的内存
                    try buf.movsdStore(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_BITS_OFF)), 0);
                    // 设置 tag = FLOAT
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), TAG_FLOAT_VAL);
                    // 设置 float type = F64
                    try buf.storeByteImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, FLOAT_TYPE_OFF)), FLOAT_TYPE_F64_VAL);

                    const b_next = try buf.jmpRel32();

                    // .cold
                    const cold_off = buf.len();
                    BridgeBuf.patchRel32(code.items, bne_cold1 + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, bne_cold2 + 2, cold_off);
                    BridgeBuf.patchRel32(code.items, bne_cold3 + 2, cold_off);

                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                }
                // 类型传播
                reg_types[a] = if (int_target != null) .i64 else if (float_target != null) .f64 else .unknown;
            },

            // ── 热点 opcode：call（通过 rt_call_inline）──
            .call => {
                const func_idx_val = bx;
                // spill 所有常驻 FPR（rt_call_inline 可能修改 reg_pool）
                try emitFrameBase(&buf);
                fpr_state.invalidateAll();
                // rt_call_inline(vm, func_idx, args_base, argc, return_base, return_reg)
                try buf.movReg(CARG0, BR_VM); // x0 = vm
                try buf.movImm64(CARG1, @intCast(func_idx_val)); // x1 = func_idx
                // args_base = base + a + 1
                try buf.movReg(TMP0, BR_BASE);
                try buf.append(0x48);
                try buf.append(0x83);
                try buf.append(0xC0); // add rax, imm8
                try buf.append(@intCast(@as(u8, a) + 1));
                try buf.movReg(CARG2, TMP0); // x2 = args_base
                // argc = callee.arity
                const callee_arity: u32 = if (func_idx_val < functions.len) functions[func_idx_val].arity else 0;
                try buf.movImm64(CARG3, @intCast(callee_arity)); // x3 = argc

                if (is_windows) {
                    // Windows: 第 5/6 参数在栈上 [rsp+32] / [rsp+40]
                    // return_base = base (r13)
                    try buf.movReg(TMP0, BR_BASE);
                    try buf.storeMem(GPR.rsp, 32, TMP0);
                    // return_reg = a
                    try buf.movImm64(TMP0, @intCast(@as(u8, a)));
                    try buf.storeMem(GPR.rsp, 40, TMP0);
                } else {
                    // System V: 第 5/6 参数在 r8/r9
                    try buf.movReg(CARG4, BR_BASE); // r8 = return_base
                    try buf.movImm64(CARG5, @intCast(@as(u8, a))); // r9 = return_reg
                }

                // call rt_call_inline (r15)
                try buf.callReg(BR_RT_CALL);

                // 检查返回值: test rax, rax + jne exit
                try buf.testReg(TMP0, TMP0);
                const jne_exit = try buf.jccRel32(X86Cond.NE);
                try pending_fixups.append(allocator, .{
                    .code_offset = jne_exit,
                    .target_ip = 0xFFFFFFFF,
                    .kind = 3,
                    .rel32_pos = jne_exit + 2,
                });
                reg_types[a] = .unknown;
            },

            // ── 热点 opcode：index_op（数组索引快速路径）──
            .index_op => {
                try emitFrameBase(&buf);
                // index_op 有 cold/fast 两条路径；为保持一致，fast 路径前先 spillAll。
                fpr_state.invalidateAll();

                // 检查 arr(b) tag == TAG_ARRAY
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, b) * 32 + @as(i32, TAG_OFF)), TAG_ARRAY_VAL);
                const bne_cold1 = try buf.jccRel32(X86Cond.NE);

                // 检查 idx(c) tag == TAG_INT
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, c) * 32 + @as(i32, TAG_OFF)), TAG_INT_VAL);
                const bne_cold2 = try buf.jccRel32(X86Cond.NE);

                // 检查 dst(a) 是标量
                try buf.cmpByteMemImm(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold3 = try buf.jccRel32(X86Cond.A);

                // 加载 ArrayValue* from arr payload (offset 0)
                try buf.loadMem(TMP0, TMP2, @intCast(@as(i32, b) * 32 + @as(i32, PAYLOAD_OFF))); // TMP0 = arr pointer

                // 加载 elements.ptr (offset 0) → TMP1
                try buf.loadMem(TMP1, TMP0, 0);
                // 加载 elements.len (offset 8) → rax (we'll reuse TMP0 register number, but need a third temp)
                // Actually let me use a different approach: load len into r8
                try buf.loadMem(GPR.r8, TMP0, 8);

                // 加载 index (Int.lo, offset 0) → r9
                try buf.loadMem(GPR.r9, TMP2, @intCast(@as(i32, c) * 32 + @as(i32, INT_LO_OFF)));

                // 边界检查: index < len (unsigned): cmp r9, r8 + jae cold
                try buf.cmpReg(GPR.r9, GPR.r8);
                const bhs_cold4 = try buf.jccRel32(X86Cond.AE);

                // 计算元素地址: r8 = elements.ptr + index * 32
                // mov r8, r9 (index)
                try buf.movReg(GPR.r8, GPR.r9);
                // shl r8, 5 (index * 32)
                try buf.append(0x49);
                try buf.append(0xC1);
                try buf.append(0xE0); // shl r8, imm8
                try buf.append(5);
                // add r8, r11 (elements.ptr)
                try buf.addReg(GPR.r8, TMP1);

                // 检查元素是否标量
                try buf.cmpByteMemImm(GPR.r8, @intCast(@as(i32, TAG_OFF)), MAX_SCALAR_TAG);
                const bhi_cold5 = try buf.jccRel32(X86Cond.A);

                // 快速路径: 拷贝 32 字节
                inline for (0..4) |i| {
                    try buf.loadMem(TMP0, GPR.r8, @intCast(i * 8));
                    try buf.storeMem(TMP2, @intCast(@as(i32, a) * 32 + @as(i32, i * 8)), TMP0);
                }

                const b_next = try buf.jmpRel32();

                // cold: rt_step 桥接
                const cold_off = buf.len();
                inline for (.{ bne_cold1, bne_cold2, bhi_cold3, bhs_cold4, bhi_cold5 }) |jcc_pos| {
                    BridgeBuf.patchRel32(code.items, jcc_pos + 2, cold_off);
                }
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                const next_off = buf.len();
                BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
            },

            // ── 热点 opcode：call_method ──
            .call_method, .call_method_ic => {
                const method_val = func.chunk.constants.items[b];
                const mname = method_val.string.bytes();

                if (std.mem.eql(u8, mname, "len") and c == 0) {
                    // arr.len() → rt_array_len(vm, recv_slot, dst_slot)
                    // spill 所有常驻 FPR（rt_array_len 可能修改 reg_pool）
                    try emitFrameBase(&buf);
                    fpr_state.invalidateAll();
                    try buf.movReg(CARG0, BR_VM); // vm
                    // recv_slot = base + a
                    try buf.movReg(TMP0, BR_BASE);
                    try buf.append(0x48);
                    try buf.append(0x83);
                    try buf.append(0xC0);
                    try buf.append(@intCast(@as(u8, a)));
                    try buf.movReg(CARG1, TMP0); // recv_slot
                    // dst_slot = base + a (same as recv)
                    try buf.movReg(CARG2, TMP0); // dst_slot

                    // 加载 rt_array_len 地址到 r11（临时）
                    try loadAddr64(&buf, TMP1, rt_array_len_addr);
                    try buf.callReg(TMP1);

                    // 检查返回值: cmp rax, 0 + jne cold
                    try buf.cmpImm8(TMP0, 0);
                    const jne_cold = try buf.jccRel32(X86Cond.NE);

                    const b_next = try buf.jmpRel32();

                    // cold: rt_step
                    const cold_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_cold + 2, cold_off);

                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                } else if (std.mem.eql(u8, mname, "push") and c == 1) {
                    // arr.push(elem) → rt_array_push(vm, recv_slot, arg_slot, dst_slot)
                    // spill 所有常驻 FPR（rt_array_push 可能修改 reg_pool）
                    try emitFrameBase(&buf);
                    fpr_state.invalidateAll();
                    try buf.movReg(CARG0, BR_VM); // vm
                    // recv_slot = base + a
                    try buf.movReg(TMP0, BR_BASE);
                    try buf.append(0x48);
                    try buf.append(0x83);
                    try buf.append(0xC0);
                    try buf.append(@intCast(@as(u8, a)));
                    try buf.movReg(CARG1, TMP0); // recv_slot
                    // arg_slot = base + a + 1
                    try buf.movReg(TMP0, BR_BASE);
                    try buf.append(0x48);
                    try buf.append(0x83);
                    try buf.append(0xC0);
                    try buf.append(@intCast(@as(u8, a) + 1));
                    try buf.movReg(CARG2, TMP0); // arg_slot
                    // dst_slot = base + a
                    try buf.movReg(TMP0, BR_BASE);
                    try buf.append(0x48);
                    try buf.append(0x83);
                    try buf.append(0xC0);
                    try buf.append(@intCast(@as(u8, a)));
                    try buf.movReg(CARG3, TMP0); // dst_slot

                    // call rt_array_push (rbx)
                    try buf.callReg(BR_RT_PUSH);

                    // 检查返回值
                    try buf.cmpImm8(TMP0, 0);
                    const jne_cold = try buf.jccRel32(X86Cond.NE);

                    const b_next = try buf.jmpRel32();

                    // cold: rt_step
                    const cold_off = buf.len();
                    BridgeBuf.patchRel32(code.items, jne_cold + 2, cold_off);

                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);

                    const next_off = buf.len();
                    BridgeBuf.patchRel32(code.items, b_next + 1, next_off);
                } else {
                    // 其他方法 → rt_step 桥接
                    try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);
                }
            },

            // ── 所有其他 opcode：通过 rt_step 桥接 ──
            else => {
                try emitRtStepCall(&buf, ip, &pending_fixups, allocator, &fpr_state);
            },
        }
    }

    // ════════ 函数 epilogue (= exit 标签) ════════
    exit_offset = buf.len();

    // add rsp, STACK_SPACE
    try buf.addRspImm8(@intCast(STACK_SPACE));
    // pop r15, r14, r13, r12, rbx, rbp
    try buf.popReg(GPR.r15);
    try buf.popReg(GPR.r14);
    try buf.popReg(GPR.r13);
    try buf.popReg(GPR.r12);
    try buf.popReg(GPR.rbx);
    try buf.popReg(GPR.rbp);
    // ret
    try buf.ret();

    // ════════ 回填跳转目标 ════════
    for (pending_fixups.items) |fixup| {
        if (fixup.kind == 3) {
            // exit 跳转：跳到 exit_offset
            BridgeBuf.patchRel32(code.items, fixup.rel32_pos, exit_offset);
        } else {
            const target_off = ip_to_code.get(fixup.target_ip) orelse {
                return error.JitMissingJumpTarget;
            };
            BridgeBuf.patchRel32(code.items, fixup.rel32_pos, target_off);
        }
    }

    // ════════ 写入可执行内存 ════════
    const code_bytes = code.items.len;
    const dst = exec_mem.alloc(code_bytes) orelse return error.JitOutOfExecMemory;
    @memcpy(dst[0..code_bytes], code.items);
    return @intFromPtr(dst);
}

// ════════════════════════════════════════════════════════════════════
// JitBackend 接口实现（桥接模式）
// ════════════════════════════════════════════════════════════════════

/// x86-64 JitBackend 实例（桥接模式）。
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

    // 直接从字节码编译为 x86-64 机器码
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

/// JitBackend.compileFn 实现：IR 模式编译入口。
/// engine_ctx 实际类型为 *JitEngine，内部通过 @ptrCast 还原。
fn compileIrFn(
    engine_ctx: *anyopaque,
    func_idx: u32,
    func_opaque: *const anyopaque,
) ?*const anyopaque {
    const jit_mod = @import("../mod.zig");
    const JitEngine = jit_mod.JitEngine;
    const engine: *JitEngine = @ptrCast(@alignCast(engine_ctx));
    const func: *const reg_chunk.RegFunction = @ptrCast(@alignCast(func_opaque));

    // 正在编译中（循环递归），入口地址已在 compiling map 中
    if (engine.compiling.get(func_idx)) |_| {
        return null;
    }

    // 第一遍：lift IR 确定函数是否可 JIT
    const lift_result = ir.liftFromChunk(engine.allocator, func, engine.functions) catch {
        engine.failed[func_idx] = true;
        return null;
    };

    if (lift_result == .unsupported) {
        engine.failed[func_idx] = true;
        return null;
    }

    var ir_func = lift_result.success;
    defer ir_func.deinit();

    // 预分配可执行内存
    var exec_mem = mem.allocExec(16 * 1024) catch {
        engine.failed[func_idx] = true;
        return null;
    };
    errdefer exec_mem.deinit();

    // 预计算入口地址并标记为正在编译
    const entry_addr = @intFromPtr(exec_mem.ptr);
    engine.compiling.put(func_idx, entry_addr) catch {
        exec_mem.deinit();
        engine.failed[func_idx] = true;
        return null;
    };
    defer _ = engine.compiling.remove(func_idx);

    // 递归编译所有 call 目标函数
    for (ir_func.insts.items) |inst| {
        if (inst.op == .call) {
            const target = inst.call_target;
            if (target < engine.functions.len) {
                _ = engine.compileFunction(target, &engine.functions[target]);
            }
        }
    }

    // 构建 func_entries 数组
    var func_entries = engine.allocator.alloc(usize, engine.functions.len) catch {
        exec_mem.deinit();
        engine.failed[func_idx] = true;
        return null;
    };
    defer engine.allocator.free(func_entries);
    @memset(func_entries, 0);
    for (engine.compiled, 0..) |maybe_cfn, i| {
        if (maybe_cfn) |cfn| {
            if (i < func_entries.len) {
                func_entries[i] = cfn.entry;
            }
        }
    }
    var compiling_it = engine.compiling.iterator();
    while (compiling_it.next()) |entry| {
        if (entry.key_ptr.* < func_entries.len) {
            func_entries[entry.key_ptr.*] = entry.value_ptr.*;
        }
    }

    // IR → 机器码
    const entry = ir_backend_instance.compileFn(
        &ir_backend_instance,
        engine.allocator,
        &ir_func,
        &exec_mem,
        func_entries,
    ) catch {
        exec_mem.deinit();
        engine.failed[func_idx] = true;
        return null;
    };

    exec_mem.finalize();

    engine.compiled[func_idx] = jit_mod.CompiledFn{
        .entry = entry,
        .arity = func.arity,
        .return_type = 0, // i64
        .exec_mem = exec_mem,
        .bridge = false,
    };

    return @ptrCast(&engine.compiled[func_idx].?);
}

/// 旧 IR 模式后端实例（供 compileIrFn 内部使用）。
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
