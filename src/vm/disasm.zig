//! Glue 字节码 VM — 反汇编器（M0）
//!
//! 设计见 docs/bytecode-vm-plan.md §2.1。调试用途 + 黄金文件测试：
//! 把 Chunk 字节码打印成人类可读的指令清单，验证编译器输出正确。
//!
//! 输出写入 *std.ArrayListUnmanaged(u8)（Zig 0.16 unmanaged 风格，与代码库一致），
//! 内部用 std.fmt.allocPrint + appendSlice 格式化。

const std = @import("std");
const opcode = @import("opcode.zig");
const chunk_mod = @import("chunk.zig");

const OpCode = opcode.OpCode;
const Chunk = chunk_mod.Chunk;

const Buf = std.ArrayListUnmanaged(u8);

fn print(buf: *Buf, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// 反汇编整个 chunk 到 buf。
pub fn disassembleChunk(chunk: *const Chunk, name: []const u8, buf: *Buf, allocator: std.mem.Allocator) !void {
    try print(buf, allocator, "== {s} ==\n", .{name});
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset, buf, allocator);
    }
}

/// 反汇编单条指令，返回下一条指令的偏移。
pub fn disassembleInstruction(chunk: *const Chunk, offset: usize, buf: *Buf, allocator: std.mem.Allocator) !usize {
    try print(buf, allocator, "{d:0>4} ", .{offset});
    const code = chunk.code.items;
    const op: OpCode = @enumFromInt(code[offset]);
    switch (op) {
        // 无操作数
        .op_null, .op_unit, .op_true, .op_false, .op_pop, .op_dup, .op_return, .op_match_fail, .op_index, .op_set_index, .op_get_newtype_inner, .op_add, .op_sub, .op_mul, .op_div, .op_mod, .op_eq, .op_neq, .op_lt, .op_gt, .op_le, .op_ge, .op_bit_and, .op_bit_or, .op_bit_xor, .op_neg, .op_not, .op_non_null, .op_propagate, .op_throw, .op_get_throw_ok, .op_get_throw_err, .op_make_atomic, .op_spawn, .op_make_lazy, .op_try_recv, .op_recv, .op_concat_list => {
            try print(buf, allocator, "{s}\n", .{op.name()});
            return offset + 1;
        },
        // OP_TEST_THROW <u8 want_ok>
        .op_test_throw => {
            const want_ok = code[offset + 1];
            try print(buf, allocator, "{s} want_ok={d}\n", .{ op.name(), want_ok });
            return offset + 2;
        },
        // OP_MAKE_RANGE <u8 inclusive>
        .op_make_range => {
            const inclusive = code[offset + 1];
            try print(buf, allocator, "{s} inclusive={d}\n", .{ op.name(), inclusive });
            return offset + 2;
        },
        // OP_MAKE_TRAIT <u8 count>
        .op_make_trait => {
            const cnt = code[offset + 1];
            try print(buf, allocator, "{s} count={d}\n", .{ op.name(), cnt });
            return offset + 2;
        },
        // OP_CALL_METHOD <u16 name_const> <u8 argc>
        .op_call_method => {
            const name_idx = opcode.readU16(code, offset + 1);
            const argc = code[offset + 3];
            try print(buf, allocator, "{s} name#{d} argc={d}\n", .{ op.name(), name_idx, argc });
            return offset + 4;
        },
        // OP_FOR_NEXT <u16 iter_slot> <u16 idx_slot> <i32 exit_off>
        .op_for_next => {
            const iter_slot = opcode.readU16(code, offset + 1);
            const idx_slot = opcode.readU16(code, offset + 3);
            const rel = opcode.readI32(code, offset + 5);
            const target: i64 = @as(i64, @intCast(offset + 9)) + rel;
            try print(buf, allocator, "{s} iter={d} idx={d} exit={d} (-> {d})\n", .{ op.name(), iter_slot, idx_slot, rel, target });
            return offset + 9;
        },
        // u16 操作数
        .op_const, .op_get_local, .op_set_local, .op_set_local_letrec, .op_set_local_assign, .op_pop_n, .op_get_field, .op_get_adt_field, .op_test_ctor, .op_make_array, .op_make_record, .op_test_lit, .op_record_extend, .op_make_newtype, .op_make_error, .op_test_newtype, .op_interp, .op_cast, .op_coerce, .op_set_field, .op_get_global, .op_set_global, .op_get_local_raw, .op_get_upvalue_raw => {
            const arg = opcode.readU16(code, offset + 1);
            try print(buf, allocator, "{s} {d}\n", .{ op.name(), arg });
            return offset + 3;
        },
        // OP_COMPOUND_LOCAL <u16 slot> <u8 arith_op>
        .op_compound_local => {
            const slot = opcode.readU16(code, offset + 1);
            const aop: OpCode = @enumFromInt(code[offset + 3]);
            try print(buf, allocator, "{s} slot={d} op={s}\n", .{ op.name(), slot, aop.name() });
            return offset + 4;
        },
        // OP_COMPOUND_UPVALUE <u16 idx> <u8 arith_op>
        .op_compound_upvalue => {
            const idx = opcode.readU16(code, offset + 1);
            const aop: OpCode = @enumFromInt(code[offset + 3]);
            try print(buf, allocator, "{s} idx={d} op={s}\n", .{ op.name(), idx, aop.name() });
            return offset + 4;
        },
        // OP_MAKE_ADT <u16 ctor_idx> <u8 argc>
        .op_make_adt => {
            const ctor_idx = opcode.readU16(code, offset + 1);
            const argc = code[offset + 3];
            try print(buf, allocator, "{s} ctor#{d} argc={d}\n", .{ op.name(), ctor_idx, argc });
            return offset + 4;
        },
        // OP_CALL / OP_TAIL_CALL <u16 func_idx> <u8 argc>
        .op_call, .op_tail_call => {
            const func_idx = opcode.readU16(code, offset + 1);
            const argc = code[offset + 3];
            try print(buf, allocator, "{s} fn#{d} argc={d}\n", .{ op.name(), func_idx, argc });
            return offset + 4;
        },
        // OP_CLOSURE <u16 func_idx> <u8 n> [<u8 is_local> <u16 index>]×n
        .op_closure => {
            const func_idx = opcode.readU16(code, offset + 1);
            const n = code[offset + 3];
            try print(buf, allocator, "{s} fn#{d} upvals={d}\n", .{ op.name(), func_idx, n });
            return offset + 4 + @as(usize, n) * 3;
        },
        // OP_GET_UPVALUE / OP_SET_UPVALUE <u16 idx>
        .op_get_upvalue, .op_set_upvalue => {
            const idx = opcode.readU16(code, offset + 1);
            try print(buf, allocator, "{s} {d}\n", .{ op.name(), idx });
            return offset + 3;
        },
        // OP_CALL_VALUE <u8 argc>
        .op_call_value => {
            const argc = code[offset + 1];
            try print(buf, allocator, "{s} argc={d}\n", .{ op.name(), argc });
            return offset + 2;
        },
        // OP_CALL_NATIVE <u8 native_id> <u8 argc>
        .op_call_native => {
            const nid = code[offset + 1];
            const argc = code[offset + 2];
            const nat: opcode.Native = @enumFromInt(nid);
            try print(buf, allocator, "{s} {s} argc={d}\n", .{ op.name(), @tagName(nat), argc });
            return offset + 3;
        },
        // i32 跳转偏移：同时打印解码后的绝对目标，便于核对回填
        .op_jump, .op_jump_if_false, .op_jump_if_true, .op_jump_if_not_null, .op_jump_if_null => {
            const rel = opcode.readI32(code, offset + 1);
            const after = offset + 5;
            const target: i64 = @as(i64, @intCast(after)) + rel;
            try print(buf, allocator, "{s} {d} (-> {d})\n", .{ op.name(), rel, target });
            return offset + 5;
        },
    }
}
