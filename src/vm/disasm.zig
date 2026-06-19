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
        .op_null, .op_unit, .op_true, .op_false, .op_pop, .op_dup, .op_return, .op_match_fail, .op_index, .op_get_newtype_inner, .op_add, .op_sub, .op_mul, .op_div, .op_mod, .op_eq, .op_neq, .op_lt, .op_gt, .op_le, .op_ge, .op_bit_and, .op_bit_or, .op_bit_xor, .op_neg, .op_not => {
            try print(buf, allocator, "{s}\n", .{op.name()});
            return offset + 1;
        },
        // u16 操作数
        .op_const, .op_get_local, .op_set_local, .op_pop_n, .op_get_field, .op_get_adt_field, .op_test_ctor, .op_make_array, .op_make_record, .op_test_lit, .op_record_extend, .op_make_newtype, .op_test_newtype => {
            const arg = opcode.readU16(code, offset + 1);
            try print(buf, allocator, "{s} {d}\n", .{ op.name(), arg });
            return offset + 3;
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
        .op_jump, .op_jump_if_false, .op_jump_if_true => {
            const rel = opcode.readI32(code, offset + 1);
            const after = offset + 5;
            const target: i64 = @as(i64, @intCast(after)) + rel;
            try print(buf, allocator, "{s} {d} (-> {d})\n", .{ op.name(), rel, target });
            return offset + 5;
        },
    }
}

test "disassemble basic chunk" {
    const ast = @import("ast");
    const value = @import("value");
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const k = try chunk.addConstant(value.Value{ .integer = .{ .value = 7, .type_tag = .i32 } });
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k);
    try chunk.writeOp(.op_return, loc);

    var buf: Buf = .empty;
    defer buf.deinit(allocator);
    try disassembleChunk(&chunk, "test", &buf, allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "op_const") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "op_return") != null);
}
