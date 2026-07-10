//! RegChunk 级 bytecode 优化 pass。
//! 在编译完成后、执行前对 RegChunk 做后端优化。
//! Pass 顺序：死寄存器消除 → 窥孔优化 → 冗余 move 消除
//! 迭代到 fixpoint（最多 5 轮）。

const std = @import("std");
const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");

/// 安全标记 base+offset 寄存器为已使用（u8 溢出时跳过）
fn markUsed(used: *std.AutoHashMapUnmanaged(u8, void), allocator: std.mem.Allocator, base: u8, offset: u8) void {
    const r = std.math.add(u8, base, offset) catch return;
    used.put(allocator, r, {}) catch {};
}

pub const PassResult = struct {
    instructions_removed: u32 = 0,
    moves_eliminated: u32 = 0,
    constants_folded: u32 = 0,
};

/// 对单个 RegChunk 运行全部 pass（迭代到 fixpoint）。
/// program 用于 call/call_memoized 的 arity 查询（null 时 DRE 跳过 call 参数追踪）。
pub fn optimizeChunk(
    chunk: *reg_chunk.RegChunk,
    allocator: std.mem.Allocator,
    program: ?*const reg_chunk.RegProgram,
) !PassResult {
    var result = PassResult{};
    var changed = true;
    var iterations: u8 = 0;
    while (changed and iterations < 5) {
        changed = false;
        iterations += 1;
        if (try deadRegisterElimination(chunk, allocator, program)) {
            changed = true;
            result.instructions_removed += 1;
        }
        if (peepholeOptimize(chunk)) {
            changed = true;
        }
        if (redundantMoveElimination(chunk)) {
            changed = true;
            result.moves_eliminated += 1;
        }
    }
    return result;
}

// ============================================================
// Pass 1: 死寄存器消除（DRE）— 基本块级活跃性分析
// ============================================================

/// 基本块：一段无跳转进入、无跳转退出（除末尾）的直线指令序列。
const BasicBlock = struct {
    start: usize, // 起始指令索引（含）
    end: usize, // 结束指令索引（不含）
    succs: [2]usize, // 后继 BB 索引（最多 2 个；无后继填 BB_NONE）
    succ_count: u8, // 实际后继数
    live_in: std.AutoHashMapUnmanaged(u8, void) = .{},
    live_out: std.AutoHashMapUnmanaged(u8, void) = .{},

    const BB_NONE: usize = std.math.maxInt(usize);
};

/// 死寄存器消除：基于基本块的活跃性分析。
/// 1. 划分基本块
/// 2. 迭代计算 live-in/live-out 直到 fixpoint
/// 3. 逆序遍历每条指令：若 dst 无副作用且不在 live-out/后续 live 集合中，消除
/// 替换为 load_unit 保持指令数不变（跳转目标索引不变）。
fn deadRegisterElimination(
    chunk: *reg_chunk.RegChunk,
    allocator: std.mem.Allocator,
    program: ?*const reg_chunk.RegProgram,
) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    // ── 1. 划分基本块 ──
    var blocks: std.ArrayListUnmanaged(BasicBlock) = .empty;
    defer {
        for (blocks.items) |*bb| {
            bb.live_in.deinit(allocator);
            bb.live_out.deinit(allocator);
        }
        blocks.deinit(allocator);
    }

    // 收集跳转目标（leader）
    var leaders = std.AutoHashMap(usize, void).init(allocator);
    defer leaders.deinit();
    leaders.put(0, {}) catch {};
    for (code, 0..) |inst, idx| {
        const op = reg_opcode.getOp(inst);
        switch (op) {
            .jump, .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                const offset = reg_opcode.getsBx(inst);
                const target: usize = @intCast(@as(i64, @intCast(idx + 1)) + offset);
                if (target < code.len) leaders.put(target, {}) catch {};
                // 跳转后下一条指令也是 leader
                if (idx + 1 < code.len) leaders.put(idx + 1, {}) catch {};
            },
            else => {},
        }
    }

    // 构建 BB 列表，并建立 指令索引→BB索引 映射
    var inst_to_bb = std.AutoHashMap(usize, usize).init(allocator);
    defer inst_to_bb.deinit();
    var sorted_leaders: std.ArrayListUnmanaged(usize) = .empty;
    defer sorted_leaders.deinit(allocator);
    {
        var it = leaders.iterator();
        while (it.next()) |e| sorted_leaders.append(allocator, e.key_ptr.*) catch {};
    }
    std.mem.sort(usize, sorted_leaders.items, {}, std.sort.asc(usize));

    for (sorted_leaders.items, 0..) |leader, bb_idx| {
        // 找到下一个 leader 或跳转指令+1 作为 end
        var end = code.len;
        if (bb_idx + 1 < sorted_leaders.items.len) {
            end = sorted_leaders.items[bb_idx + 1];
        }
        // BB 在跳转指令处结束（跳转指令本身属于本 BB）
        // end 已经是下一个 leader，自然包含跳转指令
        var bb: BasicBlock = .{
            .start = leader,
            .end = end,
            .succs = .{ BasicBlock.BB_NONE, BasicBlock.BB_NONE },
            .succ_count = 0,
        };
        // 确定后继：末尾指令决定
        if (end > 0 and end - 1 >= leader) {
            const last_inst = code[end - 1];
            const last_op = reg_opcode.getOp(last_inst);
            switch (last_op) {
                .jump => {
                    // 无条件跳转：唯一后继 = 跳转目标
                    const offset = reg_opcode.getsBx(last_inst);
                    const target: usize = @intCast(@as(i64, @intCast(end)) + offset);
                    if (target < code.len) {
                        if (inst_to_bb.get(target)) |tbb| {
                            bb.succs[0] = tbb;
                            bb.succ_count = 1;
                        }
                    }
                },
                .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                    // 条件跳转：后继 = 跳转目标 + fall-through
                    const offset = reg_opcode.getsBx(last_inst);
                    const target: usize = @intCast(@as(i64, @intCast(end)) + offset);
                    if (target < code.len) {
                        if (inst_to_bb.get(target)) |tbb| {
                            bb.succs[bb.succ_count] = tbb;
                            bb.succ_count += 1;
                        }
                    }
                    // fall-through：下一个 leader（即 end 处的 BB，若存在）
                    if (end < code.len) {
                        if (inst_to_bb.get(end)) |fbb| {
                            bb.succs[bb.succ_count] = fbb;
                            bb.succ_count += 1;
                        }
                    }
                },
                else => {
                    // 顺序执行：fall-through
                    if (end < code.len) {
                        if (inst_to_bb.get(end)) |fbb| {
                            bb.succs[0] = fbb;
                            bb.succ_count = 1;
                        }
                    }
                },
            }
        }
        // 注册本 BB 的起始指令映射（先注册，以便前驱引用）
        // 注意：后继引用可能还未创建（前向跳转），需二次遍历修复
        try blocks.append(allocator, bb);
        var i_inst = leader;
        while (i_inst < end) : (i_inst += 1) {
            try inst_to_bb.put(i_inst, bb_idx);
        }
    }

    // 二次遍历修复前向跳转的后继（此时所有 BB 已创建）
    for (blocks.items) |*bb| {
        if (bb.succ_count > 0) continue; // 已设置
        if (bb.end == 0 or bb.end - 1 < bb.start) continue;
        const last_inst = code[bb.end - 1];
        const last_op = reg_opcode.getOp(last_inst);
        switch (last_op) {
            .jump => {
                const offset = reg_opcode.getsBx(last_inst);
                const target: usize = @intCast(@as(i64, @intCast(bb.end)) + offset);
                if (target < code.len) {
                    if (inst_to_bb.get(target)) |tbb| {
                        bb.succs[0] = tbb;
                        bb.succ_count = 1;
                    }
                }
            },
            .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                const offset = reg_opcode.getsBx(last_inst);
                const target: usize = @intCast(@as(i64, @intCast(bb.end)) + offset);
                if (target < code.len) {
                    if (inst_to_bb.get(target)) |tbb| {
                        bb.succs[bb.succ_count] = tbb;
                        bb.succ_count += 1;
                    }
                }
                if (bb.end < code.len) {
                    if (inst_to_bb.get(bb.end)) |fbb| {
                        bb.succs[bb.succ_count] = fbb;
                        bb.succ_count += 1;
                    }
                }
            },
            else => {
                if (bb.end < code.len) {
                    if (inst_to_bb.get(bb.end)) |fbb| {
                        bb.succs[0] = fbb;
                        bb.succ_count = 1;
                    }
                }
            },
        }
    }

    // ── 2. 迭代计算 live-in/live-out 直到 fixpoint ──
    // live_out[BB] = ∪ live_in[succ] for succ in BB.succs
    // live_in[BB] = use[BB] ∪ (live_out[BB] - def[BB])
    // 其中 use/def 需逐指令计算（考虑指令的 dst/src）
    var iter: u8 = 0;
    while (iter < 20) : (iter += 1) {
        var any_changed = false;
        // 逆序遍历 BB（提高收敛速度）
        var bb_i: usize = blocks.items.len;
        while (bb_i > 0) {
            bb_i -= 1;
            const bb = &blocks.items[bb_i];

            // 计算 live_out = ∪ live_in[succ]
            var new_live_out = std.AutoHashMapUnmanaged(u8, void){};
            var s: u8 = 0;
            while (s < bb.succ_count) : (s += 1) {
                const succ_idx = bb.succs[s];
                if (succ_idx == BasicBlock.BB_NONE) continue;
                const succ = &blocks.items[succ_idx];
                var succ_it = succ.live_in.iterator();
                while (succ_it.next()) |e| {
                    new_live_out.put(allocator, e.key_ptr.*, {}) catch {};
                }
            }

            // 计算本 BB 的 live_in：逆序遍历指令，模拟 use/def
            var new_live_in = std.AutoHashMapUnmanaged(u8, void){};
            // 初始化为 live_out
            var out_it = new_live_out.iterator();
            while (out_it.next()) |e| {
                new_live_in.put(allocator, e.key_ptr.*, {}) catch {};
            }
            // 逆序遍历本 BB 指令：live_in = use ∪ (live_in - def)
            var inst_i = bb.end;
            while (inst_i > bb.start) {
                inst_i -= 1;
                const inst = code[inst_i];
                const op = reg_opcode.getOp(inst);
                const a = reg_opcode.getA(inst);

                // 先移除 dst（def）
                if (hasDestination(op)) {
                    _ = new_live_in.remove(a);
                }
                // test_* 读写同一寄存器
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    _ = new_live_in.remove(a);
                }
                // 加入 src
                addSourceRegs(&new_live_in, allocator, inst, op, program);
                // test_* 读 A
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    new_live_in.put(allocator, a, {}) catch {};
                }
            }

            // 比较是否有变化
            const out_changed = !hashSetEqual(&bb.live_out, &new_live_out);
            const in_changed = !hashSetEqual(&bb.live_in, &new_live_in);
            if (out_changed) {
                bb.live_out.deinit(allocator);
                bb.live_out = new_live_out;
                any_changed = true;
            } else {
                new_live_out.deinit(allocator);
            }
            if (in_changed) {
                bb.live_in.deinit(allocator);
                bb.live_in = new_live_in;
                any_changed = true;
            } else {
                new_live_in.deinit(allocator);
            }
        }
        if (!any_changed) break;
    }

    // ── 3. 基于活跃性消除死指令 ──
    var changed = false;
    for (blocks.items) |*bb| {
        // 本 BB 内逆序扫描，维护局部 live 集合（初始为 live_out）
        var live = std.AutoHashMapUnmanaged(u8, void){};
        defer live.deinit(allocator);
        var out_it = bb.live_out.iterator();
        while (out_it.next()) |e| {
            live.put(allocator, e.key_ptr.*, {}) catch {};
        }

        var inst_i = bb.end;
        while (inst_i > bb.start) {
            inst_i -= 1;
            const inst = code[inst_i];
            const op = reg_opcode.getOp(inst);
            const a = reg_opcode.getA(inst);

            const has_dst = hasDestination(op);
            const no_side_effect = isSideEffectFree(op);

            if (has_dst and no_side_effect and !live.contains(a)) {
                // 死指令：替换为 load_unit
                code[inst_i] = reg_opcode.makeABC(.load_unit, a, 0, 0);
                changed = true;
            } else {
                // 活跃指令：移除 dst，加入 src
                if (has_dst) {
                    _ = live.remove(a);
                }
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    _ = live.remove(a);
                }
                addSourceRegs(&live, allocator, inst, op, program);
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    live.put(allocator, a, {}) catch {};
                }
            }
        }
    }
    return changed;
}

/// 比较两个 HashSet 是否相等
fn hashSetEqual(a: *const std.AutoHashMapUnmanaged(u8, void), b: *const std.AutoHashMapUnmanaged(u8, void)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        if (!b.contains(e.key_ptr.*)) return false;
    }
    return true;
}

/// 判断 opcode 是否有目标寄存器（A 字段为写入目标）。
fn hasDestination(op: reg_opcode.Op) bool {
    return switch (op) {
        .load_const, .load_null, .load_unit, .load_true, .load_false,
        .load_global, .move, .move_raw, .bind, .assign, .bind_letrec,
        .add, .sub, .mul, .div, .mod, .neg, .eq, .neq, .lt, .gt, .le, .ge,
        .not_op, .bit_and, .bit_or, .bit_xor, .call, .call_value, .call_native,
        .call_method, .call_method_ic, .call_memoized, .tail_call,
        .get_field, .get_adt_field, .index_op, .get_upvalue, .get_upvalue_raw,
        .make_adt, .make_array, .make_record, .make_newtype, .make_range,
        .make_range_incl, .make_atomic, .make_lazy, .make_error, .make_trait,
        .interp, .cast, .coerce, .non_null, .propagate, .get_throw_ok,
        .get_throw_err, .get_newtype_inner, .concat_list, .closure, .spawn,
        .try_recv, .recv, .push_inplace, .for_next, .compound_local,
        .test_ctor, .test_lit, .test_newtype, .test_throw,
        .record_extend, .set_field, .set_index,
        => true,
        .return_op, .return_unit, .store_global, .set_upvalue,
        .match_fail, .throw_op, .release, .jump, .jump_if_false, .jump_if_true,
        .jump_if_null, .jump_if_not_null,
        => false,
    };
}

/// 判断 opcode 是否无副作用（可安全消除）。
/// 消除后需保证：不丢失引用计数操作（load_unit 会释放旧值，安全）。
fn isSideEffectFree(op: reg_opcode.Op) bool {
    return switch (op) {
        .load_const, .load_null, .load_unit, .load_true, .load_false,
        .move, .move_raw, .bind,
        .add, .sub, .mul, .div, .mod, .neg, .eq, .neq, .lt, .gt, .le, .ge,
        .not_op, .bit_and, .bit_or, .bit_xor,
        .get_field, .get_adt_field, .index_op, .get_upvalue, .get_upvalue_raw,
        .cast, .coerce, .get_throw_ok, .get_throw_err, .get_newtype_inner,
        => true,
        else => false,
    };
}

/// 将指令的源寄存器加入 used 集合。
fn addSourceRegs(
    used: *std.AutoHashMapUnmanaged(u8, void),
    allocator: std.mem.Allocator,
    inst: reg_opcode.Instruction,
    op: reg_opcode.Op,
    program: ?*const reg_chunk.RegProgram,
) void {
    const a = reg_opcode.getA(inst);
    const b = reg_opcode.getB(inst);
    const c = reg_opcode.getC(inst);
    const bx = reg_opcode.getBx(inst);

    switch (op) {
        // 无源寄存器（B 是常量 idx 非寄存器，不标记）
        .load_null, .load_unit, .load_true, .load_false, .return_unit,
        .match_fail, .jump, .load_const, .load_global,
        .get_upvalue, .get_upvalue_raw,
        => {},

        // closure A Bx: A 是 dst，Bx 是 func_idx。
        // 隐式读取 upvalue_specs 中 is_local=true 的寄存器（捕获外层局部）。
        .closure => {
            if (program) |prog| {
                if (bx < prog.functions.items.len) {
                    const specs = prog.functions.items[bx].upvalue_specs.items;
                    for (specs) |spec| {
                        if (spec.is_local) {
                            used.put(allocator, spec.index, {}) catch {};
                        }
                    }
                }
            }
        },

        // get_adt_field A Bx: A 既是 dst 又是源（读取 ADT 对象），需标记 A 为 used
        .get_adt_field => {
            used.put(allocator, a, {}) catch {};
        },

        // make_adt A B C: B=ctor_idx（常量），C=argc。源寄存器 A+1..A+C
        .make_adt => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },

        // make_record A B C: B=shape_idx（常量），C=field_count。源寄存器 A+1..A+C
        .make_record => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A 是条件/源寄存器
        .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null,
        .store_global, .return_op, .throw_op, .release, .non_null, .propagate,
        => {
            used.put(allocator, a, {}) catch {};
        },

        // A 是 receiver（读写）
        .record_extend, .set_field, .set_index, .push_inplace, .compound_local,
        => {
            used.put(allocator, a, {}) catch {};
            switch (op) {
                .set_field => used.put(allocator, c, {}) catch {}, // B 是字段名 idx
                .set_index => {
                    used.put(allocator, b, {}) catch {};
                    used.put(allocator, c, {}) catch {};
                },
                .push_inplace => used.put(allocator, c, {}) catch {},
                .compound_local => used.put(allocator, c, {}) catch {}, // B 是 op code
                .record_extend => {
                    var j: u8 = 1;
                    while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
                },
                else => {},
            }
        },

        // A B: B 是源寄存器
        .move, .move_raw, .bind, .assign, .bind_letrec,
        .neg, .not_op, .make_newtype, .make_atomic, .make_lazy,
        .get_throw_ok, .get_throw_err, .get_newtype_inner,
        => {
            used.put(allocator, b, {}) catch {};
        },

        // A B C: B/C 是源寄存器
        .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .le, .ge,
        .bit_and, .bit_or, .bit_xor, .index_op, .concat_list,
        .make_range, .make_range_incl,
        => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },

        // A B C: B 是源寄存器，C 是常量 idx
        .get_field, .test_lit, .cast, .coerce => {
            used.put(allocator, b, {}) catch {};
        },

        // A B C: A 是 callee/receiver（读），A+1..A+C 是参数
        .call_value, .call_method, .call_method_ic => {
            used.put(allocator, a, {}) catch {};
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A Bx C: A 是 dst，A+1..A+C 是参数
        .call_native => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A Bx: A 是 dst，args 在 A+1..A+arity（需查 program）
        .call, .call_memoized, .tail_call => {
            if (program) |prog| {
                if (bx < prog.functions.items.len) {
                    const arity = prog.functions.items[bx].arity;
                    var j: u8 = 1;
                    while (j <= arity) : (j += 1) markUsed(used, allocator, a, j);
                }
            } else {
                // 无 program：保守标记 A+1..A+8
                var j: u8 = 1;
                while (j <= 8) : (j += 1) markUsed(used, allocator, a, j);
            }
        },

        // A B C: A 是 dst，A+1..A+B 是元素
        .make_array => {
            var j: u8 = 1;
            while (j <= b) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A B C: A=dst, B=src(inner value), C=err_idx
        .make_error => {
            used.put(allocator, b, {}) catch {};
        },

        // A B C: A=dst, B=count, methods 在 R[A+1..A+B*2]（name_const, closure 交替）
        .make_trait => {
            const count: u8 = b;
            var j: u8 = 1;
            const total: u8 = count * 2;
            while (j <= total) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A B C: A 是 dst，A+1..A+B 是插值片段
        .interp => {
            var j: u8 = 1;
            while (j <= b) : (j += 1) markUsed(used, allocator, a, j);
        },

        // A B C: B 是 closure，B+1..B+C 是 args
        .spawn => {
            used.put(allocator, b, {}) catch {};
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, b, j);
        },

        // A B: B 是 channel
        .try_recv, .recv => {
            used.put(allocator, b, {}) catch {};
        },

        // A B C: A=elem(write), B=iter(read), C=idx(read+write)
        .for_next => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },

        // set_upvalue: A 是源
        .set_upvalue => {
            used.put(allocator, a, {}) catch {};
        },

        // 保守默认：标记 B/C
        else => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },
    }
}

// ============================================================
// Pass 2: 窥孔优化
// ============================================================

/// 窥孔优化：局部模式匹配替换。
/// 模式：
/// 1. move A B; move A C → 第一条无效（A 被立即覆盖）
fn peepholeOptimize(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len < 2) return false;
    var changed = false;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 1) {
        const inst1 = code[i];
        const inst2 = code[i + 1];
        const op1 = reg_opcode.getOp(inst1);
        const op2 = reg_opcode.getOp(inst2);
        const a1 = reg_opcode.getA(inst1);
        const a2 = reg_opcode.getA(inst2);

        // 模式1: move A B 后接 move A C → 第一条无效（A 被覆盖）
        if (op1 == .move and op2 == .move and a1 == a2) {
            code[i] = reg_opcode.makeABC(.load_unit, a1, 0, 0);
            changed = true;
            continue;
        }
    }
    return changed;
}

// ============================================================
// Pass 3: 冗余 move 消除
// ============================================================

/// 冗余 move 消除：move A A（自赋值）替换为 load_unit。
/// move_raw/bind 的自赋值同理。
fn redundantMoveElimination(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    var changed = false;
    for (code) |*inst| {
        const op = reg_opcode.getOp(inst.*);
        if (op == .move or op == .move_raw or op == .bind) {
            const a = reg_opcode.getA(inst.*);
            const b = reg_opcode.getB(inst.*);
            if (a == b) {
                inst.* = reg_opcode.makeABC(.load_unit, a, 0, 0);
                changed = true;
            }
        }
    }
    return changed;
}
