//! JIT 中间表示（IR）。
//!
//! 将 RegChunk 字节码提升为线性 SSA IR，作为寄存器分配和
//! 多后端代码生成的公共中间层。仅支持 JIT 友好的子集：
//! 整数/浮点算术与比较、布尔逻辑、控制流（分支/循环）。
//! 不支持的指令（数组/record/ADT/spawn/channel 等）导致
//! 编译失败，调用方回退到解释器执行。

const std = @import("std");
const reg_vm = @import("reg_vm");
const reg_opcode = reg_vm.reg_opcode;
const reg_chunk = reg_vm.reg_chunk_mod;

/// IR 值类型，对应 JIT 支持的数据类型子集。
pub const Type = enum {
    i32,
    i64,
    f32,
    f64,
    boolean,
    unit,
    /// 指针（用于传入的数组/字符串引用，JIT 代码不分配堆对象）
    ptr,

    /// 返回该类型在机器上的字节大小。
    pub fn sizeOf(self: Type) usize {
        return switch (self) {
            .i32, .boolean, .f32 => 4,
            .i64, .f64, .ptr => 8,
            .unit => 0,
        };
    }

    /// 是否为浮点类型
    pub fn isFloat(self: Type) bool {
        return self == .f32 or self == .f64;
    }
};

/// IR 操作码，与具体架构无关。
pub const Opcode = enum {
    // 常量加载
    const_i64, // dst = imm64
    const_f64, // dst = imm64 (bitcast to f64)
    const_f32, // dst = imm32 (低 32 位 bitcast to f32)
    const_bool, // dst = imm1

    // 算术（i64）
    add_i64,
    sub_i64,
    mul_i64,
    div_i64, // 有符号整除
    rem_i64, // 有符号取余
    neg_i64,

    // 位运算（i64）
    and_i64,
    or_i64,
    xor_i64,
    not_i64, // 按位取反

    // 算术（f64）
    add_f64,
    sub_f64,
    mul_f64,
    div_f64,
    neg_f64,

    // 算术（f32）
    add_f32,
    sub_f32,
    mul_f32,
    div_f32,
    neg_f32,

    // 比较（i64）→ bool
    eq_i64,
    neq_i64,
    lt_i64,
    le_i64,
    gt_i64,
    ge_i64,

    // 比较（f64）→ bool
    eq_f64,
    neq_f64,
    lt_f64,
    le_f64,
    gt_f64,
    ge_f64,

    // 比较（f32）→ bool
    eq_f32,
    neq_f32,
    lt_f32,
    le_f32,
    gt_f32,
    ge_f32,

    // 类型转换
    i32_to_i64, // 符号扩展
    i64_to_f64, // 整数转浮点（double）
    f64_to_i64, // 浮点转整数
    i64_to_f32, // 整数转浮点（single）
    f32_to_i64, // 单精度浮点转整数
    f32_to_f64, // 单精度→双精度
    f64_to_f32, // 双精度→单精度

    // 布尔逻辑
    bool_not,

    // 数据移动
    move, // dst = src（寄存器间复制）

    // 控制流
    branch, // 条件跳转: branch cond, true_label, false_label
    jump, // 无条件跳转: jump label
    label, // 标签（代码位置标记，不生成指令）

    // 函数调用
    call, // call func_idx, args[] → dst
    return_void,
    return_val, // return_val src

    // 内存访问（仅读取，不分配）
    load_arg, // 加载函数参数: load_arg arg_idx → dst
};

/// IR 指令，使用虚拟寄存器（vreg）引用操作数。
pub const Inst = struct {
    op: Opcode,
    /// 目标虚拟寄存器（无目标则为无效值）。
    dst: VReg = .invalid,
    /// 第一个源操作数。
    a: Operand = .{ .none = {} },
    /// 第二个源操作数（二元运算用）。
    b: Operand = .{ .none = {} },
    /// 立即数（用于常量加载和跳转偏移）。
    imm: i64 = 0,
    /// 跳转目标标签索引（branch/jump/label 用）。
    label: u32 = 0,
    /// 调用目标的函数索引（call 用）。
    call_target: u32 = 0,
    /// 函数调用的参数 vreg 列表（最多 16 个）。
    call_args: [16]VReg = [_]VReg{.invalid} ** 16,
    /// 函数调用的参数数量。
    call_argc: u8 = 0,
};

/// 虚拟寄存器编号。
pub const VReg = struct {
    id: u32,
    type: Type = .i64,

    pub const invalid: VReg = .{ .id = 0xFFFF_FFFF, .type = .unit };

    pub fn isValid(self: VReg) bool {
        return self.id != 0xFFFF_FFFF;
    }
};

/// 操作数：可以是虚拟寄存器或立即数。
pub const Operand = union(enum) {
    none: void,
    vreg: VReg,
    imm_i64: i64,
    imm_f64: f64,
    imm_bool: bool,
};

/// IR 函数，包含一个函数的完整 IR 指令序列。
pub const IRFunction = struct {
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    vreg_count: u32 = 0,
    arg_count: u8 = 0,
    arg_types: [16]Type = .{.i64} ** 16,
    return_type: Type = .i64,
    name: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IRFunction {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IRFunction) void {
        self.insts.deinit(self.allocator);
    }

    /// 分配一个新的虚拟寄存器。
    pub fn newVReg(self: *IRFunction, ty: Type) !VReg {
        const id = self.vreg_count;
        self.vreg_count += 1;
        return .{ .id = id, .type = ty };
    }

    /// 追加一条 IR 指令。
    pub fn append(self: *IRFunction, inst: Inst) !void {
        try self.insts.append(self.allocator, inst);
    }

    /// 追加一个标签。
    pub fn appendLabel(self: *IRFunction, label_id: u32) !void {
        try self.append(.{ .op = .label, .label = label_id });
    }
};

/// 标签分配器，为分支跳转目标分配唯一编号。
pub const LabelAlloc = struct {
    next: u32 = 0,

    pub fn newLabel(self: *LabelAlloc) u32 {
        const id = self.next;
        self.next += 1;
        return id;
    }
};

/// 字节码到 IR 的提升结果。
pub const LiftResult = union(enum) {
    success: IRFunction,
    /// 不支持的字节码模式，无法 JIT 编译。
    unsupported: reg_opcode.Op,
};

/// 将类型名字符串映射为 IR Type，无法识别时返回 null。
fn typeNameToIRType(name: []const u8) ?Type {
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "unit")) return .unit;
    return null;
}

/// 推断每个字节码寄存器的 IR 类型，并返回函数的返回类型。
/// 基于前向单遍扫描：寄存器类型由最近一次写入决定。
fn inferRegTypes(func: *const reg_chunk.RegFunction, reg_types: []Type) Type {
    @memset(reg_types, .i64);
    var seen_return_op = false;
    var return_type: Type = .i64;
    const code = func.chunk.code.items;

    for (code) |inst| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);
        const bx = reg_opcode.getBx(inst);

        switch (op) {
            .load_const => {
                if (a >= reg_types.len) continue;
                const kv = func.chunk.constants.items[bx];
                switch (kv) {
                    .int => |iv| {
                        if (iv.type != .i128) reg_types[a] = .i64;
                    },
                    .float => |fv| {
                        reg_types[a] = switch (fv.type) {
                            .f32 => .f32,
                            .f64 => .f64,
                            else => .i64, // f8/f16/f128 走桥接，标记为 i64 让 lift 失败
                        };
                    },
                    .boolean => reg_types[a] = .boolean,
                    else => {},
                }
            },
            .load_unit => {
                if (a < reg_types.len) reg_types[a] = .unit;
            },
            .load_true, .load_false => {
                if (a < reg_types.len) reg_types[a] = .boolean;
            },
            .move, .bind, .coerce, .assign => {
                if (a < reg_types.len and b < reg_types.len) reg_types[a] = reg_types[b];
            },
            .add, .sub, .mul, .div, .mod => {
                if (a >= reg_types.len) continue;
                // 算术运算结果与操作数相同（f32 优先于 f64）
                const lhs_f32 = b < reg_types.len and reg_types[b] == .f32;
                const rhs_f32 = c < reg_types.len and reg_types[c] == .f32;
                const lhs_f64 = b < reg_types.len and reg_types[b] == .f64;
                const rhs_f64 = c < reg_types.len and reg_types[c] == .f64;
                if (lhs_f32 and rhs_f32) {
                    reg_types[a] = .f32;
                } else if (lhs_f64 and rhs_f64) {
                    reg_types[a] = .f64;
                } else if (lhs_f32 or rhs_f32) {
                    reg_types[a] = .f32;
                } else if (lhs_f64 or rhs_f64) {
                    reg_types[a] = .f64;
                } else if (b < reg_types.len) {
                    reg_types[a] = reg_types[b];
                } else {
                    reg_types[a] = .i64;
                }
            },
            .neg => {
                if (a < reg_types.len and b < reg_types.len) reg_types[a] = reg_types[b];
            },
            .bit_and, .bit_or, .bit_xor => {
                if (a < reg_types.len) reg_types[a] = .i64;
            },
            .eq, .neq, .lt, .gt, .le, .ge => {
                if (a < reg_types.len) reg_types[a] = .boolean;
            },
            .not_op => {
                if (a < reg_types.len) reg_types[a] = .boolean;
            },
            .cast => {
                if (a >= reg_types.len) continue;
                if (c >= func.chunk.constants.items.len) continue;
                const tname = func.chunk.constants.items[c].string.bytes();
                if (typeNameToIRType(tname)) |ty| {
                    reg_types[a] = ty;
                }
            },
            .return_op => {
                if (a < reg_types.len) return_type = reg_types[a];
                seen_return_op = true;
            },
            .return_unit => {
                if (!seen_return_op) return_type = .unit;
            },
            else => {},
        }
    }

    return return_type;
}

/// 将 RegChunk 字节码提升为 IR。
/// 如果遇到不支持的指令（非纯算术/控制流），返回 unsupported。
/// functions 参数用于查找 call_memoized/tail_call 的 callee.arity。
pub fn liftFromChunk(allocator: std.mem.Allocator, func: *const reg_chunk.RegFunction, functions: []const reg_chunk.RegFunction) !LiftResult {
    var ir = IRFunction.init(allocator);
    ir.arg_count = func.arity;
    ir.name = func.name;

    // 推断参数类型
    for (0..@min(func.arity, func.param_types.len)) |arg_idx| {
        if (func.param_types[arg_idx]) |ptn| {
            if (typeNameToIRType(ptn)) |ty| {
                ir.arg_types[arg_idx] = ty;
            }
        }
    }

    var labels = LabelAlloc{};
    const code = func.chunk.code.items;

    // 跳转目标映射：字节码地址 → IR 标签号
    var jump_targets = std.AutoHashMap(usize, u32).init(allocator);
    defer jump_targets.deinit();

    // 第一遍：扫描所有跳转目标，分配标签
    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        switch (op) {
            .jump, .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                const offset = reg_opcode.getsBx(inst);
                const target: i64 = @as(i64, @intCast(i + 1)) + offset;
                if (target < 0 or target >= code.len) return .{ .unsupported = op };
                const target_idx: usize = @intCast(target);
                if (!jump_targets.contains(target_idx)) {
                    try jump_targets.put(target_idx, labels.newLabel());
                }
            },
            else => {},
        }
    }

    // 类型推断：确定每个字节码寄存器的 IR 类型和函数返回类型
    const reg_types = try allocator.alloc(Type, func.register_count);
    defer allocator.free(reg_types);
    ir.return_type = inferRegTypes(func, reg_types);

    // 虚拟寄存器映射：字节码寄存器号 → VReg（非 SSA 模式，每个字节码寄存器对应固定 vreg）
    var reg_map: std.ArrayListUnmanaged(VReg) = .empty;
    defer reg_map.deinit(allocator);
    try reg_map.appendNTimes(allocator, .invalid, func.register_count);

    // 为每个字节码寄存器分配一个固定的虚拟寄存器
    for (0..func.register_count) |r| {
        reg_map.items[r] = try ir.newVReg(reg_types[r]);
    }

    // 加载函数参数到虚拟寄存器
    for (0..func.arity) |arg_idx| {
        try ir.append(.{
            .op = .load_arg,
            .dst = reg_map.items[arg_idx],
            .imm = @intCast(arg_idx),
        });
    }

    // 第二遍：逐条转换字节码为 IR
    for (code, 0..) |inst, ip| {
        const op = reg_opcode.getOp(inst);

        // 如果是跳转目标，发射标签
        if (jump_targets.get(ip)) |label_id| {
            try ir.appendLabel(label_id);
        }

        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);
        const bx = reg_opcode.getBx(inst);
        const sbx = reg_opcode.getsBx(inst);

        switch (op) {
            // 常量加载
            .load_const => {
                const kv = func.chunk.constants.items[bx];
                const dst = reg_map.items[a];
                switch (kv) {
                    .int => |iv| {
                        if (iv.type == .i128) {
                            return .{ .unsupported = .load_const };
                        }
                        const val: i64 = @bitCast(iv.lo);
                        try ir.append(.{ .op = .const_i64, .dst = dst, .imm = val });
                    },
                    .float => |fv| {
                        switch (fv.type) {
                            .f64 => {
                                const bits: i64 = @bitCast(fv.bits);
                                try ir.append(.{ .op = .const_f64, .dst = dst, .imm = bits });
                            },
                            .f32 => {
                                // f32 的 bits 存储在低 32 位，扩展为 i64 立即数
                                const bits32: u32 = @truncate(fv.bits);
                                const bits: i64 = @intCast(bits32);
                                try ir.append(.{ .op = .const_f32, .dst = dst, .imm = bits });
                            },
                            else => return .{ .unsupported = .load_const },
                        }
                    },
                    .boolean => {
                        try ir.append(.{ .op = .const_bool, .dst = dst, .imm = if (kv.boolean) 1 else 0 });
                    },
                    else => return .{ .unsupported = .load_const },
                }
            },

            // 标量字面量
            .load_null => return .{ .unsupported = op },
            .load_unit => {
                try ir.append(.{ .op = .const_i64, .dst = reg_map.items[a], .imm = 0 });
            },
            .load_true => {
                try ir.append(.{ .op = .const_bool, .dst = reg_map.items[a], .imm = 1 });
            },
            .load_false => {
                try ir.append(.{ .op = .const_bool, .dst = reg_map.items[a], .imm = 0 });
            },

            // move/bind/coerce: 生成 move 指令（非 SSA 下不能只复制映射）
            .move, .bind, .coerce => {
                try ir.append(.{
                    .op = .move,
                    .dst = reg_map.items[a],
                    .a = .{ .vreg = reg_map.items[b] },
                });
            },

            // i64/f64/f32 算术（按操作数类型分派）
            .add, .sub, .mul, .div, .mod => {
                const lhs = reg_map.items[b];
                const rhs = reg_map.items[c];
                const dst = reg_map.items[a];
                const lhs_ty: Type = if (b < reg_types.len) reg_types[b] else .i64;
                const rhs_ty: Type = if (c < reg_types.len) reg_types[c] else .i64;
                // mod 仅整数支持
                if (op == .mod and (lhs_ty.isFloat() or rhs_ty.isFloat())) {
                    return .{ .unsupported = op };
                }
                const ir_op: Opcode = blk: {
                    if (lhs_ty == .f32 or rhs_ty == .f32) break :blk switch (op) {
                        .add => .add_f32,
                        .sub => .sub_f32,
                        .mul => .mul_f32,
                        .div => .div_f32,
                        else => unreachable,
                    };
                    if (lhs_ty == .f64 or rhs_ty == .f64) break :blk switch (op) {
                        .add => .add_f64,
                        .sub => .sub_f64,
                        .mul => .mul_f64,
                        .div => .div_f64,
                        else => unreachable,
                    };
                    break :blk switch (op) {
                        .add => .add_i64,
                        .sub => .sub_i64,
                        .mul => .mul_i64,
                        .div => .div_i64,
                        .mod => .rem_i64,
                        else => unreachable,
                    };
                };
                try ir.append(.{
                    .op = ir_op,
                    .dst = dst,
                    .a = .{ .vreg = lhs },
                    .b = .{ .vreg = rhs },
                });
            },

            // 取反（按操作数类型分派）
            .neg => {
                const src_ty: Type = if (b < reg_types.len) reg_types[b] else .i64;
                const ir_op: Opcode = switch (src_ty) {
                    .f32 => .neg_f32,
                    .f64 => .neg_f64,
                    else => .neg_i64,
                };
                try ir.append(.{
                    .op = ir_op,
                    .dst = reg_map.items[a],
                    .a = .{ .vreg = reg_map.items[b] },
                });
            },

            // 位运算
            .bit_and, .bit_or, .bit_xor => {
                const lhs = reg_map.items[b];
                const rhs = reg_map.items[c];
                const dst = reg_map.items[a];
                const ir_op: Opcode = switch (op) {
                    .bit_and => .and_i64,
                    .bit_or => .or_i64,
                    .bit_xor => .xor_i64,
                    else => unreachable,
                };
                try ir.append(.{
                    .op = ir_op,
                    .dst = dst,
                    .a = .{ .vreg = lhs },
                    .b = .{ .vreg = rhs },
                });
            },

            // 比较（按操作数类型分派 i64/f64/f32）
            .eq, .neq, .lt, .gt, .le, .ge => {
                const lhs = reg_map.items[b];
                const rhs = reg_map.items[c];
                const dst = reg_map.items[a];
                const lhs_ty: Type = if (b < reg_types.len) reg_types[b] else .i64;
                const rhs_ty: Type = if (c < reg_types.len) reg_types[c] else .i64;
                const ir_op: Opcode = blk: {
                    if (lhs_ty == .f32 or rhs_ty == .f32) break :blk switch (op) {
                        .eq => .eq_f32,
                        .neq => .neq_f32,
                        .lt => .lt_f32,
                        .gt => .gt_f32,
                        .le => .le_f32,
                        .ge => .ge_f32,
                        else => unreachable,
                    };
                    if (lhs_ty == .f64 or rhs_ty == .f64) break :blk switch (op) {
                        .eq => .eq_f64,
                        .neq => .neq_f64,
                        .lt => .lt_f64,
                        .gt => .gt_f64,
                        .le => .le_f64,
                        .ge => .ge_f64,
                        else => unreachable,
                    };
                    break :blk switch (op) {
                        .eq => .eq_i64,
                        .neq => .neq_i64,
                        .lt => .lt_i64,
                        .gt => .gt_i64,
                        .le => .le_i64,
                        .ge => .ge_i64,
                        else => unreachable,
                    };
                };
                try ir.append(.{
                    .op = ir_op,
                    .dst = dst,
                    .a = .{ .vreg = lhs },
                    .b = .{ .vreg = rhs },
                });
            },

            // 布尔取反
            .not_op => {
                try ir.append(.{
                    .op = .bool_not,
                    .dst = reg_map.items[a],
                    .a = .{ .vreg = reg_map.items[b] },
                });
            },

            // 类型转换
            .cast => {
                const tname = func.chunk.constants.items[c].string.bytes();
                const target_ty = typeNameToIRType(tname) orelse return .{ .unsupported = .cast };
                const src_ty: Type = if (b < reg_types.len) reg_types[b] else .i64;
                const dst = reg_map.items[a];
                const src = .{ .vreg = reg_map.items[b] };

                const ir_op: ?Opcode = blk: {
                    if (src_ty == target_ty) break :blk .move;
                    switch (target_ty) {
                        .i64 => break :blk switch (src_ty) {
                            .f64 => .f64_to_i64,
                            .f32 => .f32_to_i64,
                            .i32 => .i32_to_i64,
                            else => .i32_to_i64,
                        },
                        .f64 => break :blk switch (src_ty) {
                            .f32 => .f32_to_f64,
                            .i32, .i64 => .i64_to_f64,
                            else => .i64_to_f64,
                        },
                        .f32 => break :blk switch (src_ty) {
                            .f64 => .f64_to_f32,
                            .i32, .i64 => .i64_to_f32,
                            else => .i64_to_f32,
                        },
                        .i32 => break :blk .move,
                        else => break :blk null,
                    }
                };

                if (ir_op) |op2| {
                    try ir.append(.{ .op = op2, .dst = dst, .a = src });
                } else {
                    return .{ .unsupported = .cast };
                }
            },

            // 跳转
            .jump => {
                const target: i64 = @as(i64, @intCast(ip + 1)) + sbx;
                const target_idx: usize = @intCast(target);
                const label_id = jump_targets.get(target_idx).?;
                try ir.append(.{ .op = .jump, .label = label_id });
            },
            .jump_if_false => {
                const cond = reg_map.items[a];
                const target: i64 = @as(i64, @intCast(ip + 1)) + sbx;
                const target_idx: usize = @intCast(target);
                const label_id = jump_targets.get(target_idx).?;
                const true_label = labels.newLabel();
                try ir.append(.{
                    .op = .branch,
                    .a = .{ .vreg = cond },
                    .label = true_label,
                    .imm = @intCast(label_id),
                });
                try ir.appendLabel(true_label);
            },
            .jump_if_true => {
                const cond = reg_map.items[a];
                const target: i64 = @as(i64, @intCast(ip + 1)) + sbx;
                const target_idx: usize = @intCast(target);
                const label_id = jump_targets.get(target_idx).?;
                const false_label = labels.newLabel();
                try ir.append(.{
                    .op = .branch,
                    .a = .{ .vreg = cond },
                    .label = label_id,
                    .imm = @intCast(false_label),
                });
                try ir.appendLabel(false_label);
            },
            .jump_if_null => {
                // null 视为假值，非 null 视为真值
                const cond = reg_map.items[a];
                const target: i64 = @as(i64, @intCast(ip + 1)) + sbx;
                const target_idx: usize = @intCast(target);
                const label_id = jump_targets.get(target_idx).?;
                const true_label = labels.newLabel();
                try ir.append(.{
                    .op = .branch,
                    .a = .{ .vreg = cond },
                    .label = true_label,
                    .imm = @intCast(label_id),
                });
                try ir.appendLabel(true_label);
            },
            .jump_if_not_null => {
                // null 视为假值，非 null 视为真值
                const cond = reg_map.items[a];
                const target: i64 = @as(i64, @intCast(ip + 1)) + sbx;
                const target_idx: usize = @intCast(target);
                const label_id = jump_targets.get(target_idx).?;
                const false_label = labels.newLabel();
                try ir.append(.{
                    .op = .branch,
                    .a = .{ .vreg = cond },
                    .label = label_id,
                    .imm = @intCast(false_label),
                });
                try ir.appendLabel(false_label);
            },

            // 返回
            .return_op => {
                try ir.append(.{ .op = .return_val, .a = .{ .vreg = reg_map.items[a] } });
            },
            .return_unit => {
                try ir.append(.{ .op = .return_void });
            },

            // 赋值：生成 move 指令
            .assign => {
                try ir.append(.{
                    .op = .move,
                    .dst = reg_map.items[a],
                    .a = .{ .vreg = reg_map.items[b] },
                });
            },

            // 函数调用（同模块内已知函数）
            // call: A=dst, Bx=callee_idx, C=argc
            // call_memoized: A=dst, Bx=callee_idx, argc=callee.arity
            // tail_call: A=dst, Bx=callee_idx, argc=callee.arity
            // 参数在 a+1, a+2, ..., a+argc 寄存器中
            .call, .call_memoized, .tail_call => {
                const callee_idx: usize = bx;
                if (callee_idx >= functions.len) return .{ .unsupported = op };
                const callee = &functions[callee_idx];
                const argc: usize = switch (op) {
                    .call => c,
                    .call_memoized, .tail_call => callee.arity,
                    else => unreachable,
                };
                if (argc > 16) return .{ .unsupported = op };
                var call_inst = Inst{
                    .op = .call,
                    .dst = reg_map.items[a],
                    .call_target = @intCast(callee_idx),
                    .call_argc = @intCast(argc),
                };
                // 参数在 a+1, a+2, ..., a+argc
                for (0..argc) |i| {
                    call_inst.call_args[i] = reg_map.items[a + 1 + i];
                }
                try ir.append(call_inst);
            },

            // 未实现/不支持的指令
            else => return .{ .unsupported = op },
        }
    }

    return .{ .success = ir };
}

/// 确保寄存器映射数组足够大。
fn ensureReg(reg_map: *std.ArrayListUnmanaged(VReg), allocator: std.mem.Allocator, idx: usize) !void {
    while (reg_map.items.len <= idx) {
        try reg_map.append(allocator, .invalid);
    }
}
