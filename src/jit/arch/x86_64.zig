//! x86-64 代码生成器。
//!
//! 将 IR 指令编译为 x86-64 机器码，写入可执行内存。
//! 支持 i64 算术/比较、分支/循环控制流。
//! 使用 System V AMD64 调用约定（参数: rdi, rsi, rdx, rcx, r8, r9）。

const std = @import("std");
const ir = @import("../ir.zig");
const regalloc = @import("../regalloc.zig");
const backend_mod = @import("../backend.zig");
const mem = @import("../mem.zig");

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
    var alloc_result = try regalloc.allocate(allocator, func, &AVAIL_GPRS);
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

            .const_i64, .const_f64 => {
                // mov r64, imm64
                const rd = cg.resolveReg(inst.dst);
                try cg.emitRex(true, 0, 0, rd);
                try cg.emit(0xB8 + (rd & 0x7)); // REX.B + mov r64, imm64
                const val: i64 = inst.imm;
                try cg.emitI32(@truncate(@as(u64, @bitCast(val))));
                try cg.emitI32(@truncate(@as(u64, @bitCast(val)) >> 32));
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
                    try emitMovReg(&cg, rd, rn);
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
                // System V 调用约定: rdi, rsi, rdx, rcx, r8, r9
                const arg_regs = [_]u8{ GPR.rdi, GPR.rsi, GPR.rdx, GPR.rcx, GPR.r8, GPR.r9 };
                const arg_idx: u8 = @intCast(inst.imm);
                if (arg_idx >= arg_regs.len) return error.JitTooManyArgs;
                const rd = cg.resolveReg(inst.dst);
                try emitMovReg(&cg, rd, arg_regs[arg_idx]);
            },

            .return_val => {
                const rn = cg.resolveReg(inst.a.vreg);
                // mov rax, rn
                try emitMovReg(&cg, GPR.rax, rn);
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
                // 因此 caller 必须保存所有 JIT 使用的寄存器 (rbx, r10-r15)。
                const target_idx = inst.call_target;
                if (target_idx >= func_entries.len or func_entries[target_idx] == 0) {
                    return error.JitCallTargetNotCompiled;
                }
                const entry_addr = func_entries[target_idx];

                const argc = inst.call_argc;
                if (argc > 6) return error.JitTooManyArgs;
                const arg_regs = [_]u8{ GPR.rdi, GPR.rsi, GPR.rdx, GPR.rcx, GPR.r8, GPR.r9 };

                // 保存所有 JIT 寄存器 (rbx, r10-r15 = 7 个 = 56 字节)
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
                // sub rsp, 8 (对齐到 16 字节)
                try cg.emit(0x48);
                try cg.emit(0x83);
                try cg.emit(0xEC);
                try cg.emit(0x08);

                // 移动参数到参数寄存器
                var i: u8 = 0;
                while (i < argc) : (i += 1) {
                    const src_reg = cg.resolveReg(inst.call_args[i]);
                    try emitMovReg(&cg, arg_regs[i], src_reg);
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

                // 恢复 JIT 寄存器（逆序，在移动返回值之前）
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

                // 移动返回值 rax 到目标寄存器（在恢复寄存器之后，避免被覆盖）
                const dst = cg.resolveReg(inst.dst);
                try emitMovReg(&cg, dst, GPR.rax);
            },

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

// ════════════════════════════════════════════════════════════════════
// JitBackend 接口实现（IR 模式）
// ════════════════════════════════════════════════════════════════════

/// x86-64 JitBackend 实例（IR 模式）。
pub const backend_instance: backend_mod.JitBackend = .{
    .compileFn = compileIrFn,
    .is_bridge = false,
};

/// JitBackend.compileFn 实现：IR 模式编译入口。
/// engine_ctx 实际类型为 *JitEngine，内部通过 @ptrCast 还原。
fn compileIrFn(
    engine_ctx: *anyopaque,
    func_idx: u32,
    func_opaque: *const anyopaque,
) ?*const anyopaque {
    const jit_mod = @import("../mod.zig");
    const JitEngine = jit_mod.JitEngine;
    const reg_chunk = @import("reg_vm").reg_chunk_mod;
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
