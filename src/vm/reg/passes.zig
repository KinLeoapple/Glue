//! 寄存器 VM 字节码优化遍实现。
//!
//! 提供以下优化遍，通过多轮迭代直至收敛：
//! - **常量折叠**（constantFolding）：折叠常量算术 / 逻辑运算为 load_const
//! - **常量分支折叠**（constantBranchFolding）：折叠已知条件的条件跳转
//! - **代数简化**（algebraicSimplification）：利用代数恒等式简化算术与比较
//! - **强度削减**（strengthReduction）：将 x*2 替换为 x+x
//! - **跳转线程化**（jumpThreading）：简化跳转到跳转的链
//! - **不可达代码消除**（unreachableCodeElimination）：删除无条件控制流后的死代码
//! - **条件跳转链优化**（conditionalJumpChain）：合并 if-else 跳转模式
//! - **局部 CSE**（localCSE）：基本块内公共子表达式消除
//! - **拷贝传播**（copyPropagation）：传播 move 指令的源寄存器
//! - **move 合并**（moveCoalescing）：合并连续 move 链，减少寄存器复制
//! - **死存储消除**（deadStoreElimination）：删除基本块内被覆盖的无副作用写入
//! - **死寄存器消除**（deadRegisterElimination）：基于活跃性分析删除无副作用死指令
//! - **窥孔优化**（peepholeOptimize）：删除连续重复 move
//! - **冗余 move 消除**（redundantMoveElimination）：删除源与目标相同的 move

const std = @import("std");
const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");
const value = @import("value");

/// 标记某个寄存器为被使用（base + offset 后写入集合）。
fn markUsed(used: *std.AutoHashMapUnmanaged(u8, void), allocator: std.mem.Allocator, base: u8, offset: u8) void {
    const r = std.math.add(u8, base, offset) catch return;
    used.put(allocator, r, {}) catch {};
}

/// 单轮优化的统计结果。
pub const PassResult = struct {
    instructions_removed: u32 = 0,
    moves_eliminated: u32 = 0,
    constants_folded: u32 = 0,
    branches_folded: u32 = 0,
    unreachable_removed: u32 = 0,
    jumps_threaded: u32 = 0,
    cse_eliminated: u32 = 0,
    copies_propagated: u32 = 0,
    algebraic_simplified: u32 = 0,
    dead_stores_removed: u32 = 0,
    moves_coalesced: u32 = 0,
    jump_chains_optimized: u32 = 0,
    strength_reduced: u32 = 0,
};

/// 对字节码块执行多轮优化（最多 8 轮），直至不再变化。
///
/// 优化流水线按以下顺序执行，每轮迭代重复直至收敛：
/// 1. 常量折叠 — 折叠常量运算，为后续 pass 提供更多常量信息
/// 2. 常量分支折叠 — 利用常量信息简化条件跳转
/// 3. 代数简化 — 利用恒等式简化算术与比较（x+0→move, x==x→true）
/// 4. 强度削减 — 将乘以 2 替换为加法
/// 5. 跳转线程化 — 简化跳转链，为不可达代码消除提供准确的目标
/// 6. 不可达代码消除 — 删除死代码，减少后续 pass 需要分析的指令
/// 7. 条件跳转链优化 — 合并 if-else 跳转模式
/// 8. 局部 CSE — 消除基本块内冗余计算
/// 9. 拷贝传播 — 传播 move 源寄存器，为 DCE 提供更多可消除的指令
/// 10. move 合并 — 合并连续 move 链
/// 11. 死存储消除 — 删除被覆盖的无副作用写入
/// 12. 死寄存器消除 — 基于活跃性分析删除无副作用死指令
/// 13. 窥孔优化 — 删除连续重复 move
/// 14. 冗余 move 消除 — 删除源与目标相同的 move
pub fn optimizeChunk(
    chunk: *reg_chunk.RegChunk,
    allocator: std.mem.Allocator,
    program: ?*const reg_chunk.RegProgram,
) !PassResult {
    var result = PassResult{};
    var changed = true;
    var iterations: u8 = 0;
    while (changed and iterations < 8) {
        changed = false;
        iterations += 1;

        if (try constantFolding(chunk, allocator)) { changed = true; result.constants_folded += 1; }
        if (constantBranchFolding(chunk)) { changed = true; result.branches_folded += 1; }
        if (try algebraicSimplification(chunk, allocator)) { changed = true; result.algebraic_simplified += 1; }
        if (try strengthReduction(chunk, allocator)) { changed = true; result.strength_reduced += 1; }
        if (jumpThreading(chunk)) { changed = true; result.jumps_threaded += 1; }
        if (unreachableCodeElimination(chunk)) { changed = true; result.unreachable_removed += 1; }
        if (conditionalJumpChain(chunk)) { changed = true; result.jump_chains_optimized += 1; }
        if (try localCSE(chunk, allocator)) { changed = true; result.cse_eliminated += 1; }
        if (copyPropagation(chunk)) { changed = true; result.copies_propagated += 1; }
        if (moveCoalescing(chunk)) { changed = true; result.moves_coalesced += 1; }
        if (deadStoreElimination(chunk)) { changed = true; result.dead_stores_removed += 1; }
        if (try deadRegisterElimination(chunk, allocator, program)) { changed = true; result.instructions_removed += 1; }
        if (peepholeOptimize(chunk)) { changed = true; }
        if (redundantMoveElimination(chunk)) { changed = true; result.moves_eliminated += 1; }
    }
    return result;
}

/// 基本块，记录指令区间、后继与活跃性集合。
const BasicBlock = struct {
    start: usize,
    end: usize,
    succs: [2]usize,
    succ_count: u8,
    live_in: std.AutoHashMapUnmanaged(u8, void) = .{},
    live_out: std.AutoHashMapUnmanaged(u8, void) = .{},

    const BB_NONE: usize = std.math.maxInt(usize);
};

/// 死寄存器消除：基于基本块活跃性分析删除无副作用的死指令。
fn deadRegisterElimination(
    chunk: *reg_chunk.RegChunk,
    allocator: std.mem.Allocator,
    program: ?*const reg_chunk.RegProgram,
) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    // 第一阶段：识别基本块边界（跳转目标与跳转后第一条指令为 leader）
    var blocks: std.ArrayListUnmanaged(BasicBlock) = .empty;
    defer {
        for (blocks.items) |*bb| {
            bb.live_in.deinit(allocator);
            bb.live_out.deinit(allocator);
        }
        blocks.deinit(allocator);
    }
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
                if (idx + 1 < code.len) leaders.put(idx + 1, {}) catch {};
            },
            else => {},
        }
    }

    // 第二阶段：构建基本块并连接后继
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
        var end = code.len;
        if (bb_idx + 1 < sorted_leaders.items.len) {
            end = sorted_leaders.items[bb_idx + 1];
        }
        var bb: BasicBlock = .{
            .start = leader,
            .end = end,
            .succs = .{ BasicBlock.BB_NONE, BasicBlock.BB_NONE },
            .succ_count = 0,
        };
        if (end > 0 and end - 1 >= leader) {
            const last_inst = code[end - 1];
            const last_op = reg_opcode.getOp(last_inst);
            switch (last_op) {
                .jump => {
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
                    const offset = reg_opcode.getsBx(last_inst);
                    const target: usize = @intCast(@as(i64, @intCast(end)) + offset);
                    if (target < code.len) {
                        if (inst_to_bb.get(target)) |tbb| {
                            bb.succs[bb.succ_count] = tbb;
                            bb.succ_count += 1;
                        }
                    }
                    if (end < code.len) {
                        if (inst_to_bb.get(end)) |fbb| {
                            bb.succs[bb.succ_count] = fbb;
                            bb.succ_count += 1;
                        }
                    }
                },
                else => {
                    if (end < code.len) {
                        if (inst_to_bb.get(end)) |fbb| {
                            bb.succs[0] = fbb;
                            bb.succ_count = 1;
                        }
                    }
                },
            }
        }
        try blocks.append(allocator, bb);
        var i_inst = leader;
        while (i_inst < end) : (i_inst += 1) {
            try inst_to_bb.put(i_inst, bb_idx);
        }
    }

    // 补充：为未被前一轮识别的后继建立连接
    for (blocks.items) |*bb| {
        if (bb.succ_count > 0) continue;
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

    // 第三阶段：迭代求解活跃性（最多 20 轮直至不动点）
    var iter: u8 = 0;
    while (iter < 20) : (iter += 1) {
        var any_changed = false;
        var bb_i: usize = blocks.items.len;
        while (bb_i > 0) {
            bb_i -= 1;
            const bb = &blocks.items[bb_i];
            // live_out = 并集(后继.live_in)
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
            // live_in = use ∪ (live_out - def)，逆向遍历指令
            var new_live_in = std.AutoHashMapUnmanaged(u8, void){};
            var out_it = new_live_out.iterator();
            while (out_it.next()) |e| {
                new_live_in.put(allocator, e.key_ptr.*, {}) catch {};
            }
            var inst_i = bb.end;
            while (inst_i > bb.start) {
                inst_i -= 1;
                const inst = code[inst_i];
                const op = reg_opcode.getOp(inst);
                const a = reg_opcode.getA(inst);
                if (hasDestination(op)) {
                    _ = new_live_in.remove(a);
                }
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    _ = new_live_in.remove(a);
                }
                addSourceRegs(&new_live_in, allocator, inst, op, program);
                if (op == .test_ctor or op == .test_newtype or op == .test_throw) {
                    new_live_in.put(allocator, a, {}) catch {};
                }
            }
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

    // 第四阶段：删除目的地不在 live_out 中的无副作用指令
    var changed = false;
    for (blocks.items) |*bb| {
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
                if (op != .load_unit) {
                    code[inst_i] = reg_opcode.makeABC(.load_unit, a, 0, 0);
                    changed = true;
                }
            } else {
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

/// 比较两个寄存器集合是否相等。
fn hashSetEqual(a: *const std.AutoHashMapUnmanaged(u8, void), b: *const std.AutoHashMapUnmanaged(u8, void)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        if (!b.contains(e.key_ptr.*)) return false;
    }
    return true;
}

/// 判断操作码是否写入目标寄存器 A。
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

/// 判断操作码是否无副作用（可安全删除）。
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

/// 根据指令的源操作数语义，将读取的寄存器加入 used 集合。
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
        .load_null, .load_unit, .load_true, .load_false, .return_unit,
        .match_fail, .jump, .load_const, .load_global,
        .get_upvalue, .get_upvalue_raw,
        => {},
        .closure => {
            // 闭包捕获的局部 upvalue 需要标记为使用
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
        .get_adt_field => {
            used.put(allocator, a, {}) catch {};
        },
        .make_adt => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },
        .make_record => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },
        .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null,
        .store_global, .return_op, .throw_op, .release, .non_null, .propagate,
        => {
            used.put(allocator, a, {}) catch {};
        },
        .record_extend, .set_field, .set_index, .push_inplace, .compound_local,
        => {
            used.put(allocator, a, {}) catch {};
            switch (op) {
                .set_field => used.put(allocator, c, {}) catch {},
                .set_index => {
                    used.put(allocator, b, {}) catch {};
                    used.put(allocator, c, {}) catch {};
                },
                .push_inplace => used.put(allocator, c, {}) catch {},
                .compound_local => used.put(allocator, c, {}) catch {},
                .record_extend => {
                    var j: u8 = 1;
                    while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
                },
                else => {},
            }
        },
        .move, .move_raw, .bind, .assign, .bind_letrec,
        .neg, .not_op, .make_newtype, .make_atomic, .make_lazy,
        .get_throw_ok, .get_throw_err, .get_newtype_inner,
        => {
            used.put(allocator, b, {}) catch {};
        },
        .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .le, .ge,
        .bit_and, .bit_or, .bit_xor, .index_op, .concat_list,
        .make_range, .make_range_incl,
        => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },
        .get_field, .test_lit, .cast, .coerce => {
            used.put(allocator, b, {}) catch {};
        },
        .call_value, .call_method, .call_method_ic => {
            used.put(allocator, a, {}) catch {};
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },
        .call_native => {
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, a, j);
        },
        .call, .call_memoized, .tail_call => {
            if (program) |prog| {
                if (bx < prog.functions.items.len) {
                    const arity = prog.functions.items[bx].arity;
                    var j: u8 = 1;
                    while (j <= arity) : (j += 1) markUsed(used, allocator, a, j);
                }
            } else {
                // 无程序上下文时保守估计最多 8 个参数
                var j: u8 = 1;
                while (j <= 8) : (j += 1) markUsed(used, allocator, a, j);
            }
        },
        .make_array => {
            var j: u8 = 1;
            while (j <= b) : (j += 1) markUsed(used, allocator, a, j);
        },
        .make_error => {
            used.put(allocator, b, {}) catch {};
        },
        .make_trait => {
            const count: u8 = b;
            var j: u8 = 1;
            const total: u8 = count * 2;
            while (j <= total) : (j += 1) markUsed(used, allocator, a, j);
        },
        .interp => {
            var j: u8 = 1;
            while (j <= b) : (j += 1) markUsed(used, allocator, a, j);
        },
        .spawn => {
            used.put(allocator, b, {}) catch {};
            var j: u8 = 1;
            while (j <= c) : (j += 1) markUsed(used, allocator, b, j);
        },
        .try_recv, .recv => {
            used.put(allocator, b, {}) catch {};
        },
        .for_next => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },
        .set_upvalue => {
            used.put(allocator, a, {}) catch {};
        },
        else => {
            used.put(allocator, b, {}) catch {};
            used.put(allocator, c, {}) catch {};
        },
    }
}

/// 窥孔优化：删除连续的重复 move 指令。
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
        // 两条 move 写同一寄存器，前一条可删除
        if (op1 == .move and op2 == .move and a1 == a2) {
            code[i] = reg_opcode.makeABC(.load_unit, a1, 0, 0);
            changed = true;
            continue;
        }
    }
    return changed;
}

/// 冗余 move 消除：删除源与目标相同的 move/move_raw/bind。
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

// ============================================================
// 以下为新增的字节码级优化 pass
// ============================================================

/// 寄存器已知常量值的追踪信息。
const RegConst = union(enum) {
    const_val: value.Value,
    true_val,
    false_val,
    null_val,
    unit_val,
};

/// CSE 键：操作码 + 源操作数寄存器。
const CseKey = struct {
    op: reg_opcode.Op,
    b: u8,
    c: u8,
};

/// 将 RegConst 转换为 value.Value；仅对标量类型有效。
fn regConstToValue(rc: RegConst) ?value.Value {
    return switch (rc) {
        .const_val => |v| switch (v) {
            .boolean, .int, .float, .char, .null_val, .unit => v,
            else => null,
        },
        .true_val => value.Value{ .boolean = true },
        .false_val => value.Value{ .boolean = false },
        .null_val => value.Value{ .null_val = {} },
        .unit_val => value.Value{ .unit = {} },
    };
}

/// 判断操作码是否为可折叠的二元运算。
fn isFoldableBinary(op: reg_opcode.Op) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod,
        .eq, .neq, .lt, .gt, .le, .ge,
        .bit_and, .bit_or, .bit_xor,
        => true,
        else => false,
    };
}

/// 判断操作码是否使用 B 和 C 两个源寄存器。
fn usesBC(op: reg_opcode.Op) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod,
        .eq, .neq, .lt, .gt, .le, .ge,
        .bit_and, .bit_or, .bit_xor,
        .index_op, .concat_list,
        .make_range, .make_range_incl,
        => true,
        else => false,
    };
}

/// 判断操作码是否仅使用 B 一个源寄存器。
fn usesB(op: reg_opcode.Op) bool {
    return switch (op) {
        .move, .move_raw, .bind, .assign, .bind_letrec,
        .neg, .not_op, .make_newtype, .make_atomic, .make_lazy,
        .get_throw_ok, .get_throw_err, .get_newtype_inner,
        .get_field, .test_lit, .cast, .coerce,
        .make_error,
        => true,
        else => false,
    };
}

/// 判断操作码是否为基本块终止指令（跳转、返回、抛出等）。
fn isBlockTerminator(op: reg_opcode.Op) bool {
    return switch (op) {
        .jump, .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null,
        .return_op, .return_unit, .throw_op, .match_fail,
        => true,
        else => false,
    };
}

/// 判断操作码是否为调用指令（可能修改任意寄存器）。
fn isCallOp(op: reg_opcode.Op) bool {
    return switch (op) {
        .call, .call_value, .call_native, .call_method, .call_method_ic,
        .call_memoized, .tail_call, .spawn,
        => true,
        else => false,
    };
}

/// 判断操作码是否适合 CSE。
fn isCseEligible(op: reg_opcode.Op) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod,
        .eq, .neq, .lt, .gt, .le, .ge,
        .bit_and, .bit_or, .bit_xor,
        .neg, .not_op,
        => true,
        else => false,
    };
}

// ---- 常量折叠 ----

/// 对两个整数常量执行二元运算。
fn evaluateIntBinary(op: reg_opcode.Op, li: value.Int, ri: value.Int) ?value.Value {
    return switch (op) {
        .add => blk: {
            const result = li.add(ri);
            if (result.overflow) break :blk null;
            break :blk value.Value{ .int = result.result };
        },
        .sub => blk: {
            const result = li.subtract(ri);
            if (result.overflow) break :blk null;
            break :blk value.Value{ .int = result.result };
        },
        .mul => blk: {
            const result = li.multiply(ri);
            if (result.overflow) break :blk null;
            break :blk value.Value{ .int = result.result };
        },
        .div => blk: {
            const q = li.divideTruncating(ri) catch break :blk null;
            break :blk value.Value{ .int = q };
        },
        .mod => blk: {
            const r = li.remainder(ri) catch break :blk null;
            break :blk value.Value{ .int = r };
        },
        .eq => value.Value{ .boolean = li.compare(ri) == .eq },
        .neq => value.Value{ .boolean = li.compare(ri) != .eq },
        .lt => value.Value{ .boolean = li.compare(ri) == .lt },
        .gt => value.Value{ .boolean = li.compare(ri) == .gt },
        .le => value.Value{ .boolean = li.compare(ri) != .gt },
        .ge => value.Value{ .boolean = li.compare(ri) != .lt },
        .bit_and => value.Value{ .int = li.bitwiseAnd(ri) },
        .bit_or => value.Value{ .int = li.bitwiseOr(ri) },
        .bit_xor => value.Value{ .int = li.bitwiseXor(ri) },
        else => null,
    };
}

/// 对两个浮点常量执行二元运算。
fn evaluateFloatBinary(op: reg_opcode.Op, lf: value.Float, rf: value.Float) ?value.Value {
    return switch (op) {
        .add => value.Value{ .float = lf.add(rf) },
        .sub => value.Value{ .float = lf.subtract(rf) },
        .mul => value.Value{ .float = lf.multiply(rf) },
        .div => blk: {
            if (rf.isZero()) break :blk null;
            break :blk value.Value{ .float = lf.divide(rf) };
        },
        .eq => value.Value{ .boolean = lf.compare(rf) == .eq },
        .neq => value.Value{ .boolean = lf.compare(rf) != .eq },
        .lt => value.Value{ .boolean = lf.compare(rf) == .lt },
        .gt => value.Value{ .boolean = lf.compare(rf) == .gt },
        .le => value.Value{ .boolean = lf.compare(rf) != .gt },
        .ge => value.Value{ .boolean = lf.compare(rf) != .lt },
        else => null,
    };
}

/// 对两个已知常量执行二元运算，返回结果值；无法折叠时返回 null。
fn evaluateBinary(op: reg_opcode.Op, lv: RegConst, rv: RegConst) ?value.Value {
    const l = regConstToValue(lv) orelse return null;
    const r = regConstToValue(rv) orelse return null;

    // 布尔运算
    if (l == .boolean and r == .boolean) {
        return switch (op) {
            .eq => value.Value{ .boolean = l.boolean == r.boolean },
            .neq => value.Value{ .boolean = l.boolean != r.boolean },
            else => null,
        };
    }

    // 整数运算
    if (l == .int and r == .int) {
        return evaluateIntBinary(op, l.int, r.int);
    }

    // 浮点运算
    if (l == .float and r == .float) {
        return evaluateFloatBinary(op, l.float, r.float);
    }

    return null;
}

/// 对已知常量执行一元运算。
fn evaluateUnary(op: reg_opcode.Op, src: RegConst) ?value.Value {
    const v = regConstToValue(src) orelse return null;
    return switch (v) {
        .boolean => |b| switch (op) {
            .not_op => value.Value{ .boolean = !b },
            else => null,
        },
        .int => |i| switch (op) {
            .neg => value.Value{ .int = i.negate() },
            else => null,
        },
        .float => |f| switch (op) {
            .neg => value.Value{ .float = f.negate() },
            else => null,
        },
        else => null,
    };
}

/// 常量折叠 pass：在基本块内追踪寄存器的已知常量值，
/// 对两个已知常量操作数的算术/逻辑指令进行编译期求值，
/// 将结果添加到常量池并替换为 load_const。
fn constantFolding(chunk: *reg_chunk.RegChunk, allocator: std.mem.Allocator) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var reg_consts = std.AutoHashMap(u8, RegConst).init(allocator);
    defer reg_consts.deinit();

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);

        // 基本块边界：清空已知常量
        if (isBlockTerminator(op)) {
            reg_consts.clearRetainingCapacity();
            continue;
        }

        // 调用指令可能修改任意寄存器，保守清空
        if (isCallOp(op)) {
            reg_consts.clearRetainingCapacity();
            if (hasDestination(op)) _ = reg_consts.remove(a);
            continue;
        }

        // 追踪已知常量值
        switch (op) {
            .load_const => {
                const bx = reg_opcode.getBx(inst);
                if (bx < chunk.constants.items.len) {
                    reg_consts.put(a, .{ .const_val = chunk.constants.items[bx] }) catch {};
                }
                continue;
            },
            .load_true => {
                reg_consts.put(a, .true_val) catch {};
                continue;
            },
            .load_false => {
                reg_consts.put(a, .false_val) catch {};
                continue;
            },
            .load_null => {
                reg_consts.put(a, .null_val) catch {};
                continue;
            },
            .load_unit => {
                reg_consts.put(a, .unit_val) catch {};
                continue;
            },
            else => {},
        }

        // 尝试折叠一元运算
        if (op == .neg or op == .not_op) {
            if (reg_consts.get(b)) |src_const| {
                if (evaluateUnary(op, src_const)) |result| {
                    const idx = try chunk.addConstant(result);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, .{ .const_val = result }) catch {};
                    changed = true;
                    continue;
                }
            }
        }

        // 尝试折叠二元运算
        if (isFoldableBinary(op)) {
            const b_val = reg_consts.get(b);
            const c_val = reg_consts.get(c);
            if (b_val != null and c_val != null) {
                if (evaluateBinary(op, b_val.?, c_val.?)) |result| {
                    const idx = try chunk.addConstant(result);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, .{ .const_val = result }) catch {};
                    changed = true;
                    continue;
                }
            }
        }

        // 指令写入目标寄存器，清除其常量追踪
        if (hasDestination(op)) {
            _ = reg_consts.remove(a);
        }
    }

    return changed;
}

// ---- 常量分支折叠 ----

/// 常量分支折叠 pass：当条件跳转的条件寄存器为已知布尔常量时，
/// 将条件跳转替换为无条件跳转或 nop。
fn constantBranchFolding(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var bool_reg: ?u8 = null;
    var bool_val: bool = false;

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);

        // 检查条件跳转
        if (op == .jump_if_false or op == .jump_if_true) {
            if (bool_reg) |br| {
                if (br == a) {
                    // 条件已知，替换为无条件跳转或 nop
                    const should_jump = switch (op) {
                        .jump_if_false => !bool_val,
                        .jump_if_true => bool_val,
                        else => unreachable,
                    };
                    if (should_jump) {
                        code[i] = reg_opcode.makesBx(.jump, 0, reg_opcode.getsBx(inst));
                    } else {
                        code[i] = reg_opcode.makeABC(.load_unit, 0, 0, 0);
                    }
                    changed = true;
                }
            }
        }

        // 基本块边界：清空追踪
        if (isBlockTerminator(op)) {
            bool_reg = null;
            continue;
        }

        // 调用指令保守清空
        if (isCallOp(op)) {
            bool_reg = null;
            if (hasDestination(op)) {
                if (bool_reg) |br| {
                    if (br == a) bool_reg = null;
                }
            }
            continue;
        }

        // 追踪已知布尔值
        switch (op) {
            .load_true => {
                bool_reg = a;
                bool_val = true;
                continue;
            },
            .load_false => {
                bool_reg = a;
                bool_val = false;
                continue;
            },
            else => {},
        }

        // 其他指令写入目标寄存器，清除追踪
        if (hasDestination(op)) {
            if (bool_reg) |br| {
                if (br == a) bool_reg = null;
            }
        }
    }

    return changed;
}

// ---- 不可达代码消除 ----

/// 不可达代码消除 pass：删除无条件控制流指令（jump/return/throw/match_fail）
/// 之后、下一个跳转目标之前的所有指令，替换为 nop。
fn unreachableCodeElimination(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    // 收集所有跳转目标
    var targets = std.AutoHashMap(usize, void).init(chunk.allocator);
    defer targets.deinit();
    for (code, 0..) |inst, idx| {
        const op = reg_opcode.getOp(inst);
        switch (op) {
            .jump, .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null => {
                const offset = reg_opcode.getsBx(inst);
                const target: usize = @intCast(@as(i64, @intCast(idx + 1)) + offset);
                if (target < code.len) {
                    targets.put(target, {}) catch {};
                }
            },
            else => {},
        }
    }

    var changed = false;
    var unreachable_start: ?usize = null;

    for (code, 0..) |_, i| {
        // 如果当前位置是跳转目标，结束不可达区域
        if (targets.contains(i)) {
            unreachable_start = null;
        }

        if (unreachable_start != null) {
            if (reg_opcode.getOp(code[i]) != .load_unit) {
                code[i] = reg_opcode.makeABC(.load_unit, 0, 0, 0);
                changed = true;
            }
            continue;
        }

        const op = reg_opcode.getOp(code[i]);
        switch (op) {
            .jump, .return_op, .return_unit, .throw_op, .match_fail => {
                unreachable_start = i + 1;
            },
            else => {},
        }
    }

    return changed;
}

// ---- 跳转线程化 ----

/// 跳转线程化 pass：当无条件跳转的目标也是无条件跳转时，
/// 将第一条跳转直接重写为指向最终目标，消除跳转链。
fn jumpThreading(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        if (op != .jump) continue;

        // 跟随跳转链，最多 10 步防止无限循环
        var current_idx = i;
        var steps: u8 = 0;
        while (steps < 10) : (steps += 1) {
            const offset = reg_opcode.getsBx(code[current_idx]);
            const target: usize = @intCast(@as(i64, @intCast(current_idx + 1)) + offset);
            if (target >= code.len) break;
            if (reg_opcode.getOp(code[target]) != .jump) break;
            current_idx = target;
        }

        if (current_idx != i) {
            // 重写跳转偏移为指向最终目标
            const final_offset = reg_opcode.getsBx(code[current_idx]);
            const final_target: i64 = @as(i64, @intCast(current_idx + 1)) + final_offset;
            const new_offset: i32 = @intCast(final_target - @as(i64, @intCast(i + 1)));
            code[i] = reg_opcode.makesBx(.jump, 0, new_offset);
            changed = true;
        }
    }

    return changed;
}

// ---- 局部 CSE ----

/// 局部公共子表达式消除 pass：在基本块内追踪已计算的二元/一元表达式，
/// 当后续遇到相同的表达式时，用 move 从已有结果寄存器复制，消除冗余计算。
fn localCSE(chunk: *reg_chunk.RegChunk, allocator: std.mem.Allocator) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var seen = std.AutoHashMap(CseKey, u8).init(allocator);
    defer seen.deinit();

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);

        // 基本块边界：清空已见集合
        if (isBlockTerminator(op)) {
            seen.clearRetainingCapacity();
            continue;
        }

        // 调用指令可能修改任意寄存器，保守清空
        if (isCallOp(op)) {
            seen.clearRetainingCapacity();
            if (hasDestination(op)) _ = seen.remove(.{ .op = op, .b = a, .c = 0 });
            continue;
        }

        // 检查是否为可消除的运算
        if (isCseEligible(op)) {
            const key = CseKey{ .op = op, .b = b, .c = c };
            if (seen.get(key)) |existing_reg| {
                // 替换为 move：复用已有结果
                code[i] = reg_opcode.makeABC(.move, a, existing_reg, 0);
                changed = true;
            } else {
                try seen.put(key, a);
            }
        }

        // 指令写入目标寄存器，失效所有使用该寄存器作为操作数的已见表达式
        if (hasDestination(op)) {
            var to_remove: std.ArrayListUnmanaged(CseKey) = .empty;
            defer to_remove.deinit(allocator);
            var it = seen.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.b == a or entry.key_ptr.c == a) {
                    to_remove.append(allocator, entry.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |key| {
                _ = seen.remove(key);
            }
        }
    }

    return changed;
}

// ---- 拷贝传播 ----

/// 拷贝传播 pass：在基本块内追踪 move 指令的拷贝关系（R_dst → R_src），
/// 将后续指令中对 R_dst 的引用替换为 R_src，直到 R_dst 或 R_src 被重新定义。
fn copyPropagation(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var copies = std.AutoHashMap(u8, u8).init(chunk.allocator);
    defer copies.deinit();

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);

        // 基本块边界：清空拷贝关系
        if (isBlockTerminator(op)) {
            copies.clearRetainingCapacity();
            continue;
        }

        // 调用指令可能修改任意寄存器，保守清空
        if (isCallOp(op)) {
            copies.clearRetainingCapacity();
            if (hasDestination(op)) _ = copies.remove(a);
            continue;
        }

        // 对使用 B/C 操作数的指令，尝试传播拷贝
        if (usesBC(op)) {
            var new_b = b;
            var new_c = c;
            if (copies.get(b)) |src| new_b = src;
            if (copies.get(c)) |src| new_c = src;
            if (new_b != b or new_c != c) {
                code[i] = reg_opcode.makeABC(op, a, new_b, new_c);
                changed = true;
            }
        } else if (usesB(op)) {
            var new_b = b;
            if (copies.get(b)) |src| new_b = src;
            if (new_b != b) {
                code[i] = reg_opcode.makeABC(op, a, new_b, c);
                changed = true;
            }
        }

        // 记录 move 指令的拷贝关系（跟随拷贝链）
        if (op == .move or op == .move_raw or op == .bind) {
            const actual_src = copies.get(b) orelse b;
            copies.put(a, actual_src) catch {};
        }

        // 指令写入目标寄存器，失效以该寄存器为目标或源的拷贝
        if (hasDestination(op)) {
            _ = copies.remove(a);
            // 失效以 a 为源的所有拷贝
            var to_remove: std.ArrayListUnmanaged(u8) = .empty;
            defer to_remove.deinit(chunk.allocator);
            var it = copies.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == a) {
                    to_remove.append(chunk.allocator, entry.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |key| {
                _ = copies.remove(key);
            }
        }
    }

    return changed;
}

// ============================================================
// 新增字节码级优化 pass（第二批）
// ============================================================

/// 判断 value.Value 是否为整数零。
fn isIntZero(v: value.Value) bool {
    return v == .int and v.int.isZero();
}

/// 判断 value.Value 是否为浮点零。
fn isFloatZero(v: value.Value) bool {
    return v == .float and v.float.isZero();
}

/// 判断 value.Value 是否为数值零（整数或浮点）。
fn isNumericZero(v: value.Value) bool {
    return isIntZero(v) or isFloatZero(v);
}

/// 判断 value.Value 是否为整数一。
fn isIntOne(v: value.Value) bool {
    if (v != .int) return false;
    return switch (v.int.type) {
        .i8 => v.int.toNative(i8) == 1,
        .i16 => v.int.toNative(i16) == 1,
        .i32 => v.int.toNative(i32) == 1,
        .i64 => v.int.toNative(i64) == 1,
        .u8 => v.int.toNative(u8) == 1,
        .u16 => v.int.toNative(u16) == 1,
        .u32 => v.int.toNative(u32) == 1,
        .u64 => v.int.toNative(u64) == 1,
        else => v.int.compare(value.Int.fromNative(.i128, 1)) == .eq,
    };
}

/// 判断 value.Value 是否为浮点一。
fn isFloatOne(v: value.Value) bool {
    if (v != .float) return false;
    return switch (v.float.type) {
        .f32 => v.float.toNative(f32) == 1.0,
        .f64 => v.float.toNative(f64) == 1.0,
        else => v.float.compare(value.Float.fromNative(.f64, 1.0)) == .eq,
    };
}

/// 判断 value.Value 是否为数值一（整数或浮点）。
fn isNumericOne(v: value.Value) bool {
    return isIntOne(v) or isFloatOne(v);
}

/// 代数简化 pass：利用代数恒等式简化算术与比较指令。
///
/// 恒等式规则（当操作数为已知常量时应用）：
/// - `x + 0` → `move x`，`0 + x` → `move x`
/// - `x - 0` → `move x`
/// - `x * 1` → `move x`，`1 * x` → `move x`
/// - `x * 0` → `load_const 0`，`0 * x` → `load_const 0`
/// - `x / 1` → `move x`
/// - `x == x` → `load_true`（同寄存器）
/// - `x != x` → `load_false`
/// - `x <= x` → `load_true`，`x >= x` → `load_true`
/// - `x < x` → `load_false`，`x > x` → `load_false`
/// - `x ^ x` → `load_const 0`（异或自消）
/// - `x & x` → `move x`，`x | x` → `move x`
fn algebraicSimplification(chunk: *reg_chunk.RegChunk, allocator: std.mem.Allocator) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var reg_consts = std.AutoHashMap(u8, value.Value).init(allocator);
    defer reg_consts.deinit();

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);

        if (isBlockTerminator(op) or isCallOp(op)) {
            reg_consts.clearRetainingCapacity();
            if (hasDestination(op)) _ = reg_consts.remove(a);
            continue;
        }

        switch (op) {
            .load_const => {
                const bx = reg_opcode.getBx(inst);
                if (bx < chunk.constants.items.len) {
                    reg_consts.put(a, chunk.constants.items[bx]) catch {};
                }
                continue;
            },
            .load_true => { reg_consts.put(a, value.Value{ .boolean = true }) catch {}; continue; },
            .load_false => { reg_consts.put(a, value.Value{ .boolean = false }) catch {}; continue; },
            .load_null => { reg_consts.put(a, value.Value{ .null_val = {} }) catch {}; continue; },
            .load_unit => { reg_consts.put(a, value.Value{ .unit = {} }) catch {}; continue; },
            else => {},
        }

        // 同寄存器恒等式：比较和位运算中 B == C
        if (b == c) {
            switch (op) {
                .eq => {
                    code[i] = reg_opcode.makeABC(.load_true, a, 0, 0);
                    reg_consts.put(a, value.Value{ .boolean = true }) catch {};
                    changed = true;
                    continue;
                },
                .neq => {
                    code[i] = reg_opcode.makeABC(.load_false, a, 0, 0);
                    reg_consts.put(a, value.Value{ .boolean = false }) catch {};
                    changed = true;
                    continue;
                },
                .lt, .gt => {
                    code[i] = reg_opcode.makeABC(.load_false, a, 0, 0);
                    reg_consts.put(a, value.Value{ .boolean = false }) catch {};
                    changed = true;
                    continue;
                },
                .le, .ge => {
                    code[i] = reg_opcode.makeABC(.load_true, a, 0, 0);
                    reg_consts.put(a, value.Value{ .boolean = true }) catch {};
                    changed = true;
                    continue;
                },
                .bit_xor => {
                    const zero = value.Value.fromInt(value.Int.fromNative(.i64, 0));
                    const idx = try chunk.addConstant(zero);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, zero) catch {};
                    changed = true;
                    continue;
                },
                .bit_and, .bit_or => {
                    code[i] = reg_opcode.makeABC(.move, a, b, 0);
                    changed = true;
                    if (reg_consts.get(b)) |bv| reg_consts.put(a, bv) catch {};
                    continue;
                },
                .sub => {
                    const zero = value.Value.fromInt(value.Int.fromNative(.i64, 0));
                    const idx = try chunk.addConstant(zero);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, zero) catch {};
                    changed = true;
                    continue;
                },
                else => {},
            }
        }

        const b_const = reg_consts.get(b);
        const c_const = reg_consts.get(c);

        // x + 0 / 0 + x → move x
        if (op == .add) {
            if (c_const) |cv| {
                if (isNumericZero(cv)) {
                    code[i] = reg_opcode.makeABC(.move, a, b, 0);
                    changed = true;
                    if (b_const) |bv| reg_consts.put(a, bv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
            if (b_const) |bv| {
                if (isNumericZero(bv)) {
                    code[i] = reg_opcode.makeABC(.move, a, c, 0);
                    changed = true;
                    if (c_const) |cv| reg_consts.put(a, cv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
        }

        // x - 0 → move x
        if (op == .sub) {
            if (c_const) |cv| {
                if (isNumericZero(cv)) {
                    code[i] = reg_opcode.makeABC(.move, a, b, 0);
                    changed = true;
                    if (b_const) |bv| reg_consts.put(a, bv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
        }

        // x * 1 / 1 * x → move x
        if (op == .mul) {
            if (c_const) |cv| {
                if (isNumericOne(cv)) {
                    code[i] = reg_opcode.makeABC(.move, a, b, 0);
                    changed = true;
                    if (b_const) |bv| reg_consts.put(a, bv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
            if (b_const) |bv| {
                if (isNumericOne(bv)) {
                    code[i] = reg_opcode.makeABC(.move, a, c, 0);
                    changed = true;
                    if (c_const) |cv| reg_consts.put(a, cv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
            // x * 0 / 0 * x → load_const 0
            if (c_const) |cv| {
                if (isNumericZero(cv)) {
                    const zero = value.Value.fromInt(value.Int.fromNative(.i64, 0));
                    const idx = try chunk.addConstant(zero);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, zero) catch {};
                    changed = true;
                    continue;
                }
            }
            if (b_const) |bv| {
                if (isNumericZero(bv)) {
                    const zero = value.Value.fromInt(value.Int.fromNative(.i64, 0));
                    const idx = try chunk.addConstant(zero);
                    code[i] = reg_opcode.makeABx(.load_const, a, idx);
                    reg_consts.put(a, zero) catch {};
                    changed = true;
                    continue;
                }
            }
        }

        // x / 1 → move x
        if (op == .div) {
            if (c_const) |cv| {
                if (isNumericOne(cv)) {
                    code[i] = reg_opcode.makeABC(.move, a, b, 0);
                    changed = true;
                    if (b_const) |bv| reg_consts.put(a, bv) catch {} else _ = reg_consts.remove(a);
                    continue;
                }
            }
        }

        // not_op true → load_false, not_op false → load_true
        if (op == .not_op) {
            if (b_const) |bv| {
                if (bv == .boolean) {
                    if (bv.boolean) {
                        code[i] = reg_opcode.makeABC(.load_false, a, 0, 0);
                        reg_consts.put(a, value.Value{ .boolean = false }) catch {};
                    } else {
                        code[i] = reg_opcode.makeABC(.load_true, a, 0, 0);
                        reg_consts.put(a, value.Value{ .boolean = true }) catch {};
                    }
                    changed = true;
                    continue;
                }
            }
        }

        if (hasDestination(op)) {
            _ = reg_consts.remove(a);
        }
    }

    return changed;
}

/// 判断指令是否读取指定寄存器。
fn readsReg(inst: reg_opcode.Instruction, op: reg_opcode.Op, reg: u8) bool {
    const a = reg_opcode.getA(inst);
    const b = reg_opcode.getB(inst);
    const c = reg_opcode.getC(inst);
    if (usesBC(op)) {
        return b == reg or c == reg;
    }
    if (usesB(op)) {
        return b == reg;
    }
    switch (op) {
        .jump_if_false, .jump_if_true, .jump_if_null, .jump_if_not_null,
        .store_global, .return_op, .throw_op, .release, .non_null, .propagate,
        .set_upvalue,
        => return a == reg,
        .move, .move_raw, .bind, .assign, .bind_letrec,
        .neg, .not_op, .make_newtype, .make_atomic, .make_lazy,
        .get_throw_ok, .get_throw_err, .get_newtype_inner,
        .make_error, .get_field, .test_lit, .cast, .coerce,
        .try_recv, .recv,
        => return b == reg,
        .get_adt_field => return a == reg,
        // test_ctor / test_newtype / test_throw 读取 A（被匹配的 scrutinee）
        .test_ctor, .test_newtype, .test_throw => return a == reg,
        .set_field => return a == reg or c == reg,
        .set_index => return a == reg or b == reg or c == reg,
        .push_inplace => return a == reg or c == reg,
        .compound_local => return a == reg or c == reg,
        .record_extend => return a == reg,
        .make_adt, .make_record => {
            var k: u8 = 1;
            while (k <= c) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        .make_trait => {
            const total: u8 = b * 2;
            var k: u8 = 1;
            while (k <= total) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        .interp => {
            var k: u8 = 1;
            while (k <= b) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        .make_array => {
            var k: u8 = 1;
            while (k <= b) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        .spawn => {
            if (b == reg) return true;
            var k: u8 = 1;
            while (k <= c) : (k += 1) {
                if (b + k == reg) return true;
            }
            return false;
        },
        .for_next => return b == reg or c == reg,
        .call_value, .call_method, .call_method_ic => {
            if (a == reg) return true;
            var k: u8 = 1;
            while (k <= c) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        .call_native => {
            var k: u8 = 1;
            while (k <= c) : (k += 1) {
                if (a + k == reg) return true;
            }
            return false;
        },
        // 保守：未知指令视为读取所有寄存器
        else => return true,
    }
}

/// 死存储消除 pass：在基本块内，若寄存器被写入后、在下一次读取前又被写入，
/// 则前一次写入（若无副作用）可替换为 nop。
fn deadStoreElimination(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var i: usize = 0;
    while (i < code.len) {
        const op = reg_opcode.getOp(code[i]);
        if (isBlockTerminator(op) or isCallOp(op)) {
            i += 1;
            continue;
        }
        if (!hasDestination(op) or !isSideEffectFree(op)) {
            i += 1;
            continue;
        }

        const a = reg_opcode.getA(code[i]);
        var j = i + 1;
        var dead = false;
        while (j < code.len) : (j += 1) {
            const j_op = reg_opcode.getOp(code[j]);
            if (isBlockTerminator(j_op) or isCallOp(j_op)) break;
            // 先检查读取：若后续指令读取该寄存器（即使同时写入），前一次写入不是死存储
            if (readsReg(code[j], j_op, a)) break;
            // 再检查写入：若后续指令写入该寄存器（且未读取），前一次写入为死存储
            if (hasDestination(j_op) and reg_opcode.getA(code[j]) == a) {
                dead = true;
                break;
            }
        }

        if (dead and op != .load_unit) {
            code[i] = reg_opcode.makeABC(.load_unit, a, 0, 0);
            changed = true;
        }
        i += 1;
    }

    return changed;
}

/// move 合并 pass：将 `move A→B` 后紧跟 `move B→C` 的模式合并为 `move A→C`，
/// 当 B 在第二条 move 之后不再被使用时。
fn moveCoalescing(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len < 2) return false;

    var changed = false;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 1) {
        const inst1 = code[i];
        const op1 = reg_opcode.getOp(inst1);
        if (op1 != .move and op1 != .move_raw and op1 != .bind) continue;

        const a1 = reg_opcode.getA(inst1);
        const b1 = reg_opcode.getB(inst1);

        const inst2 = code[i + 1];
        const op2 = reg_opcode.getOp(inst2);
        if (op2 != .move and op2 != .move_raw and op2 != .bind) continue;

        const a2 = reg_opcode.getA(inst2);
        const b2 = reg_opcode.getB(inst2);

        if (b2 != a1) continue;
        if (a2 == b1) continue;

        var dead = false;
        var j = i + 2;
        while (j < code.len) : (j += 1) {
            const j_op = reg_opcode.getOp(code[j]);
            if (isBlockTerminator(j_op) or isCallOp(j_op)) break;
            if (readsReg(code[j], j_op, a1)) {
                dead = false;
                break;
            }
            if (hasDestination(j_op) and reg_opcode.getA(code[j]) == a1) {
                dead = true;
                break;
            }
        }

        if (dead) {
            code[i + 1] = reg_opcode.makeABC(op2, a2, b1, 0);
            code[i] = reg_opcode.makeABC(.load_unit, a1, 0, 0);
            changed = true;
        }
    }

    return changed;
}

/// 条件跳转链优化 pass：当 `jump_if_false A → L` 后紧跟 `jump → M`，
/// 且 L 指向紧跟 jump 后的指令时，可将两条跳转合并为 `jump_if_true A → M`。
fn conditionalJumpChain(chunk: *reg_chunk.RegChunk) bool {
    const code = chunk.code.items;
    if (code.len < 2) return false;

    var changed = false;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 1) {
        const inst1 = code[i];
        const op1 = reg_opcode.getOp(inst1);
        if (op1 != .jump_if_false and op1 != .jump_if_true) continue;

        const inst2 = code[i + 1];
        const op2 = reg_opcode.getOp(inst2);
        if (op2 != .jump) continue;

        const cond_reg = reg_opcode.getA(inst1);
        const cond_offset = reg_opcode.getsBx(inst1);
        const jump_offset = reg_opcode.getsBx(inst2);

        const cond_target: i64 = @as(i64, @intCast(i + 1)) + cond_offset;
        const jump_target: i64 = @as(i64, @intCast(i + 2)) + jump_offset;

        if (cond_target != @as(i64, @intCast(i + 2))) continue;
        if (jump_target <= @as(i64, @intCast(i + 1))) continue;
        if (jump_target < 0 or jump_target >= code.len) continue;

        const new_op: reg_opcode.Op = if (op1 == .jump_if_false) .jump_if_true else .jump_if_false;
        const new_cond_offset: i32 = @intCast(jump_target - @as(i64, @intCast(i + 1)));
        code[i] = reg_opcode.makesBx(new_op, cond_reg, new_cond_offset);
        // fallthrough 跳转目标为原条件跳转目标 i+2，offset = target - (i+1+1) = 0
        code[i + 1] = reg_opcode.makesBx(.jump, 0, 0);
        changed = true;
    }

    return changed;
}

/// 强度削减 pass：将乘以 2 替换为加法（x*2 → x+x）。
fn strengthReduction(chunk: *reg_chunk.RegChunk, allocator: std.mem.Allocator) !bool {
    const code = chunk.code.items;
    if (code.len == 0) return false;

    var changed = false;
    var reg_consts = std.AutoHashMap(u8, value.Value).init(allocator);
    defer reg_consts.deinit();

    for (code, 0..) |inst, i| {
        const op = reg_opcode.getOp(inst);
        const a = reg_opcode.getA(inst);
        const b = reg_opcode.getB(inst);
        const c = reg_opcode.getC(inst);

        if (isBlockTerminator(op) or isCallOp(op)) {
            reg_consts.clearRetainingCapacity();
            if (hasDestination(op)) _ = reg_consts.remove(a);
            continue;
        }

        switch (op) {
            .load_const => {
                const bx = reg_opcode.getBx(inst);
                if (bx < chunk.constants.items.len) {
                    reg_consts.put(a, chunk.constants.items[bx]) catch {};
                }
                continue;
            },
            .load_true => { reg_consts.put(a, value.Value{ .boolean = true }) catch {}; continue; },
            .load_false => { reg_consts.put(a, value.Value{ .boolean = false }) catch {}; continue; },
            .load_null => { reg_consts.put(a, value.Value{ .null_val = {} }) catch {}; continue; },
            .load_unit => { reg_consts.put(a, value.Value{ .unit = {} }) catch {}; continue; },
            else => {},
        }

        if (op == .mul) {
            const c_is_two = isIntTwo(reg_consts.get(c));
            const b_is_two = isIntTwo(reg_consts.get(b));

            if (c_is_two) {
                code[i] = reg_opcode.makeABC(.add, a, b, b);
                changed = true;
                _ = reg_consts.remove(a);
                continue;
            }
            if (b_is_two) {
                code[i] = reg_opcode.makeABC(.add, a, c, c);
                changed = true;
                _ = reg_consts.remove(a);
                continue;
            }
        }

        if (hasDestination(op)) {
            _ = reg_consts.remove(a);
        }
    }

    return changed;
}

/// 判断可选 value.Value 是否为整数二。
fn isIntTwo(v_opt: ?value.Value) bool {
    if (v_opt) |v| {
        if (v == .int) {
            return switch (v.int.type) {
                .i8 => v.int.toNative(i8) == 2,
                .i16 => v.int.toNative(i16) == 2,
                .i32 => v.int.toNative(i32) == 2,
                .i64 => v.int.toNative(i64) == 2,
                .u8 => v.int.toNative(u8) == 2,
                .u16 => v.int.toNative(u16) == 2,
                .u32 => v.int.toNative(u32) == 2,
                .u64 => v.int.toNative(u64) == 2,
                else => v.int.compare(value.Int.fromNative(.i128, 2)) == .eq,
            };
        }
    }
    return false;
}
