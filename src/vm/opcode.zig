//! Glue 字节码 VM — 指令集定义（M0 骨架）
//!
//! 设计见 docs/bytecode-vm-plan.md §4。M0 仅覆盖算术核所需子集：
//! 字面量 / 局部变量 / 算术 / 比较 / 逻辑 / 跳转 / 栈操作 / return。
//! 函数调用 / 构造解构 / match / 异常 / 并发的 opcode 在 M1+ 增补。
//!
//! 编码：每条指令 = 1 字节 opcode + 0 或多个立即数。
//! 立即数宽度固定（u16 用于 idx/slot，i32 用于跳转偏移），小端序。
//! computed-goto / 变长编码是 §10 后续优化，首版求简单正确。

const std = @import("std");

pub const OpCode = enum(u8) {
    // —— 常量 / 字面量 ——
    /// OP_CONST <u16 idx>：常量池[idx] retain 后压栈
    op_const,
    /// 压入单例字面量（无操作数）
    op_null,
    op_unit,
    op_true,
    op_false,

    // —— 局部变量（帧内 slot，M0 单帧）——
    /// OP_GET_LOCAL <u16 slot>：读 slot，retain 后压栈
    op_get_local,
    /// OP_SET_LOCAL <u16 slot>：弹栈顶写入 slot（先 release 旧值）
    op_set_local,

    // —— 算术（pop 2，push 1）——
    op_add,
    op_sub,
    op_mul,
    op_div,
    op_mod,

    // —— 比较（pop 2，push bool）——
    op_eq,
    op_neq,
    op_lt,
    op_gt,
    op_le,
    op_ge,

    // —— 位运算 ——
    op_bit_and,
    op_bit_or,
    op_bit_xor,

    // —— 一元 ——
    op_neg,
    op_not,

    // —— 跳转（&&/|| 短路、if、while 用）——
    /// OP_JUMP <i32 off>：无条件相对跳转
    op_jump,
    /// OP_JUMP_IF_FALSE <i32 off>：peek 栈顶，false 则跳转（不弹）
    op_jump_if_false,
    /// OP_JUMP_IF_TRUE <i32 off>：peek 栈顶，true 则跳转（不弹）
    op_jump_if_true,

    // —— 栈操作 ——
    /// 弹栈顶并 release
    op_pop,
    /// OP_POP_N <u16 n>：批量弹栈（块退出清局部），逐个 release
    op_pop_n,
    /// 复制栈顶（retain）
    op_dup,

    // —— 调用 / 返回 ——
    /// OP_CALL <u16 func_idx> <u8 argc>（M1a 快路径）：直接调用顶层 program.functions[func_idx]。
    /// 调用前栈布局 [arg0..arg_{argc-1}]；返回后被替换为单个返回值。callee 不在栈上。
    op_call,
    /// OP_CLOSURE <u16 func_idx> <u8 n_upvalues> [<u8 is_local> <u16 index>]×n（M1b-1/2）：
    /// 把顶层/嵌套函数包成 vm_closure 压栈，并捕获 n 个 upvalue。每个描述符：
    ///   is_local=1 → 捕获 enclosing 帧的 local[index]（VM 就地 box 成 *Cell 并共享）；
    ///   is_local=0 → 捕获 enclosing 闭包的 upvalue[index]（共享同一 *Cell）。
    /// M1b-1 顶层函数作值时 n=0。
    op_closure,
    /// OP_GET_UPVALUE <u16 idx>：读当前帧 upvalues[idx]（*Cell）的 inner，retain 压栈。
    op_get_upvalue,
    /// OP_SET_UPVALUE <u16 idx>：弹栈顶写入 upvalues[idx]（*Cell）的 inner（先 release 旧 inner）。
    op_set_upvalue,
    /// OP_CALL_VALUE <u8 argc>（M1b-1）：callee 为栈上的值（vm_closure）。
    /// 调用前栈布局 [callee, arg0..arg_{argc-1}]（callee 在 args 下方）。
    /// argc==arity 建帧调用；argc<arity 产生部分应用；argc>arity → WrongArity。
    /// 返回后整段 [callee..args] 被替换为单个返回值。
    op_call_value,
    /// OP_TAIL_CALL <u16 func_idx> <u8 argc>（M1b-3）：尾位置调用顶层 program.functions[func_idx]。
    /// 与 OP_CALL 同编码，但**复用当前帧**（释放本帧局部 → args 落到 frame_base → ip=0），不压新帧。
    /// 仅编译器在尾位置且 argc==callee.arity 时发射；否则退回 OP_CALL+OP_RETURN。
    op_tail_call,
    /// OP_CALL_NATIVE <u8 native_id> <u8 argc>（bench 驱动）：调用内建原生函数（println/print 等）。
    /// argc 个实参在栈顶；分派后整段实参被替换为单个返回值（多数内建返回 unit）。
    /// native_id 见 Native 枚举。M1 仅接 println/print 以驱动 bench 端到端。
    op_call_native,
    /// 弹返回值，结束当前帧：释放本帧局部槽，弹 CallFrame，把返回值压回调用者栈。
    op_return,

    // ── M2a：复合值 / 模式匹配 ──
    /// OP_MAKE_ADT <u16 ctor_idx> <u8 argc>：弹栈顶 argc 个字段值（owned，接管），
    /// 按 program.adt_ctors[ctor_idx] 建 AdtValue（fields[i].name = desc.field_names[i]，
    /// type_name/constructor 借用 desc），压栈。
    op_make_adt,
    /// OP_GET_FIELD <u16 name_const_idx>：弹对象，按常量池字符串字段名读 adt/record 字段，
    /// retainOwned 压栈，release 对象。
    op_get_field,
    /// OP_GET_ADT_FIELD <u16 idx>：弹对象，按位置读 AdtValue 第 idx 个字段，retainOwned 压栈，
    /// release 对象。供 match constructor pattern 的字段绑定（按位置，非名）。
    op_get_adt_field,
    /// OP_TEST_CTOR <u16 ctor_name_const_idx>：peek 栈顶对象（不弹），测其是否为指定构造器名的
    /// AdtValue，压 bool。供 match 的 constructor pattern 测试（配合 OP_JUMP_IF_FALSE）。
    op_test_ctor,
    /// OP_MATCH_FAIL：match 全 arm 不中的运行时兜底（报错）。
    op_match_fail,

    // ── M2b：数组 / 记录字面量 / 索引 ──
    /// OP_MAKE_ARRAY <u16 n>：弹栈顶 n 个元素（owned，接管，先压的是 elements[0]），建动态 ArrayValue 压栈。
    op_make_array,
    /// OP_MAKE_RECORD <u16 shape_idx>：弹栈顶 n 个值（n=shape.field_names.len，先压的对应 field[0]），
    /// 按 program.record_shapes[shape_idx] 建 RecordValue（key dupe，value 接管 owned）压栈。
    op_make_record,
    /// OP_INDEX：弹 index 与 object（object 在下），array 按整数索引边界检查、string 按 codepoint 索引，
    /// retainOwned 元素压栈。
    op_index,

    // ── M2c：全模式 match / 记录扩展 / newtype ──
    /// OP_TEST_LIT <u16 const_idx>：弹对象，按"字面量模式语义"与常量比较（int/float 仅比值忽略
    /// type_tag，其余同 Value.equals），压 bool。供 match 的 literal pattern。
    op_test_lit,
    /// OP_RECORD_EXTEND <u16 shape_idx>：弹栈顶 n 个 update 值（n=shape.len）+ base record（在其下），
    /// 浅拷 base 字段 + 用 updates 覆盖/新增，建新 RecordValue 压栈。
    op_record_extend,
    /// OP_MAKE_NEWTYPE <u16 nt_idx>：弹 inner 值（owned，接管），按 program.newtype_ctors[nt_idx]
    /// 建 NewtypeValue（type_name 借 desc）压栈。
    op_make_newtype,
    /// OP_TEST_NEWTYPE <u16 name_const_idx>：peek 栈顶对象（不弹），测其是否为指定 type_name 的
    /// NewtypeValue，压 bool。供 match 的 newtype 构造器模式。
    op_test_newtype,
    /// OP_GET_NEWTYPE_INNER：弹 newtype 对象，retainOwned 其 inner 压栈，release 对象。
    op_get_newtype_inner,

    pub fn name(self: OpCode) []const u8 {
        return @tagName(self);
    }
};

/// 原生内建函数 id（OP_CALL_NATIVE 的立即数）。编译器按裸名映射，VM 按 id 分派。
pub const Native = enum(u8) {
    println,
    print,

    pub fn fromName(s: []const u8) ?Native {
        if (std.mem.eql(u8, s, "println")) return .println;
        if (std.mem.eql(u8, s, "print")) return .print;
        return null;
    }
};

/// 立即数编码 helper：小端写入字节流。
pub fn writeU16(code: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u16) !void {
    try code.append(allocator, @intCast(v & 0xFF));
    try code.append(allocator, @intCast((v >> 8) & 0xFF));
}

pub fn writeI32(code: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: i32) !void {
    const u: u32 = @bitCast(v);
    try code.append(allocator, @intCast(u & 0xFF));
    try code.append(allocator, @intCast((u >> 8) & 0xFF));
    try code.append(allocator, @intCast((u >> 16) & 0xFF));
    try code.append(allocator, @intCast((u >> 24) & 0xFF));
}

/// 立即数解码 helper：从 code[offset..] 小端读取。
pub fn readU16(code: []const u8, offset: usize) u16 {
    return @as(u16, code[offset]) | (@as(u16, code[offset + 1]) << 8);
}

pub fn readI32(code: []const u8, offset: usize) i32 {
    const u: u32 = @as(u32, code[offset]) |
        (@as(u32, code[offset + 1]) << 8) |
        (@as(u32, code[offset + 2]) << 16) |
        (@as(u32, code[offset + 3]) << 24);
    return @bitCast(u);
}

test "u16 round-trip" {
    const allocator = std.testing.allocator;
    var code: std.ArrayListUnmanaged(u8) = .empty;
    defer code.deinit(allocator);
    try writeU16(&code, allocator, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), readU16(code.items, 0));
}

test "i32 round-trip negative" {
    const allocator = std.testing.allocator;
    var code: std.ArrayListUnmanaged(u8) = .empty;
    defer code.deinit(allocator);
    try writeI32(&code, allocator, -12345);
    try std.testing.expectEqual(@as(i32, -12345), readI32(code.items, 0));
}
