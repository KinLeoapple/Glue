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
    /// OP_SET_LOCAL_LETREC <u16 slot>（M5c）：letrec 自绑定——弹闭包写入 slot 的 cell.inner，
    /// 并断开自引用循环：若闭包某 upvalue 正是该 slot 的 cell（递归局部函数捕获自身），
    /// 对该 cell 少持一份 ref（自引用变弱），避免 cell↔closure 循环泄漏（镜像 eval defineWeak）。
    op_set_local_letrec,
    /// OP_SET_LOCAL_ASSIGN <u16 slot>（M5m）：assignment-to-local（非绑定）。与 op_set_local 区别：
    /// slot/cell 持 Atomic<T> 时透明 atomic store（保持共享身份，写对捕获该原子的 spawn 可见）。
    /// 绑定（val/var/match/temp）仍用 op_set_local 纯覆写——slot 复用残留 atomic 不可误 store-through。
    op_set_local_assign,

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
    /// OP_CALL_REC <u16 func_idx> <u8 argc>（letrec 自递归快路径）：
    /// 直接调用 program.functions[func_idx]，callee 不在栈上，upvalues 继承当前帧。
    /// 用于 val f = fun(){...f()...} 的自递归调用——编译期识别 f 是当前 letrec 名字，
    /// 不走 cell + upvalue 捕获，从根本消除循环引用。要求 argc==callee.arity。
    op_call_rec,
    /// OP_TAIL_CALL <u16 func_idx> <u8 argc>（M1b-3）：尾位置调用顶层 program.functions[func_idx]。
    /// 与 OP_CALL 同编码，但**复用当前帧**（释放本帧局部 → args 落到 frame_base → ip=0），不压新帧。
    /// 仅编译器在尾位置且 argc==callee.arity 时发射；否则退回 OP_CALL+OP_RETURN。
    op_tail_call,
    /// OP_TAIL_CALL_REC <u16 func_idx> <u8 argc>（letrec 自递归尾调用 TCO）：
    /// 语义同 OP_CALL_REC（callee 是当前 letrec lambda，upvalues 继承），但**复用当前帧**（同 OP_TAIL_CALL）。
    /// 用于尾位置的 letrec 自递归（如 fun go(){...match{=>go()}...}），避免深度递归栈溢出 + 帧建立开销。
    /// callee.func_idx == 当前帧 func（自递归），故 func 不变，仅 ip=0 + slot_base=frame_base。
    op_tail_call_rec,
    /// OP_CALL_NATIVE <u8 native_id> <u8 argc>（bench 驱动）：调用内建原生函数（println/print 等）。
    /// argc 个实参在栈顶；分派后整段实参被替换为单个返回值（多数内建返回 unit）。
    /// native_id 见 Native 枚举。M1 仅接 println/print 以驱动 bench 端到端。
    op_call_native,
    /// OP_CALL_MEMOIZED <u16 func_idx> <u8 argc> <u16 memo_slot>（JIT Phase 3）：
    /// 调用纯函数，结果缓存在 memo_cache[memo_slot]。
    /// 首次调用：执行函数体，返回时缓存结果。
    /// 后续调用：若参数 hash 命中缓存，直接返回缓存值（跳过整个函数体）。
    /// 仅编译器对纯函数发射。memo_slot 由编译器分配，每个调用点唯一。
    op_call_memoized,
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
    /// OP_MAKE_ERROR <u16 err_idx>：弹 str 消息（owned，接管），按 program.error_ctors[err_idx]
    /// 建 throw_val.err{type_name, message=prefix+": "+msg, is_error_subtype=true} 压栈。
    op_make_error,

    // ── M3a：字符串插值 / 类型转换 ──
    /// OP_INTERP <u16 n>：弹栈顶 n 段值（先压的是第一段，literal 文本段也压成 string 常量），
    /// 依次 Value.format 拼接成新 string 压栈，各段 release。
    op_interp,
    /// OP_CAST <u16 type_name_const_idx>：弹值，按常量池字符串目标类型名转换（cast.zig），
    /// 压结果。str→format；int/float 互转 clamp + type_tag；narrowing 溢出 → VM panic。
    op_cast,
    /// OP_COERCE <u16 type_name_const_idx>：隐式数值类型协调（M5：VM 整数定型）。
    /// 镜像 eval 的 `castValue(...) catch val` best-effort 语义：仅当栈顶是 int/float 且目标是
    /// builtin 数值类型时按 cast.zig 协调 type_tag（如形参 i32 把 i8 实参拓宽成 i32）；
    /// 溢出/类型不符/非数值/泛型类型名 → **原样保留**（绝不 panic，区别于 op_cast）。
    op_coerce,
    /// OP_CONCAT_LIST（无操作数）：弹 [left, right] 两数组，拼接成新数组（元素 retainOwned 各自一份），
    /// 压结果。镜像 eval evalConcatList（`++`）。非数组操作数 → panic。
    op_concat_list,

    // ── M3b：字段赋值（控制流补全的复合赋值/break/continue/loop 均无新 opcode）──
    /// OP_SET_FIELD <u16 name_const_idx>：栈布局 [obj, val]，弹 val 写入 obj 的命名字段
    /// （record COW；不可变绑定/非 record → panic），弹 obj release，压 unit。
    op_set_field,
    /// OP_SET_INDEX：栈布局 [array, index, val]，弹三者，array[index] = val（array COW；
    /// 越界/非数组/非整数索引 → panic），压回 new_array（写回由 SET_LOCAL 完成，镜像 SET_FIELD）。
    op_set_index,
    /// OP_GET_GLOBAL <u16 idx>：读 VM globals[idx]，retainOwned 后压栈（顶层 val/var 跨函数读）。
    op_get_global,
    /// OP_SET_GLOBAL <u16 idx>：弹栈顶 owned 值写入 globals[idx]（旧值 release）。全局初始化 + var 赋值用。
    op_set_global,

    // ── M3c：异常 / 传播 / 非空断言 / elvis ──
    /// OP_JUMP_IF_NOT_NULL <i32 off>：peek 栈顶，非 null 则相对跳转（不弹）。供 `??` 短路。
    op_jump_if_not_null,
    /// OP_JUMP_IF_NULL <i32 off>：peek 栈顶，null 则相对跳转（不弹）。供 `?.` 安全访问短路。
    op_jump_if_null,
    /// OP_NON_NULL：peek 栈顶，null → VM panic（断言失败）；否则原样保留（T? 与 T 同表示）。供 `!`。
    op_non_null,
    /// OP_PROPAGATE：peek 栈顶。null → 提前返回 null；throw_val.err → 提前返回该 throw_val；
    /// throw_val.ok → 弹并解包 inner 压栈（retainOwned）；其它 → 原样。供 `?`。
    op_propagate,
    /// OP_THROW：弹 throw 值（throw_val.err 或 error_val 自动包装），作为函数返回值
    /// （等价 OP_RETURN，Glue 无 try/catch，throw 即返回 Throw<T,E> 的 Error 分支）。
    op_throw,
    /// OP_TEST_THROW <u8 want_ok>：弹栈顶 throw_val，want_ok=1 测 .ok / =0 测 .err，压 bool。
    /// 供 match 的 Ok(v)/Error(e) 模式（配合 OP_JUMP_IF_FALSE）。
    op_test_throw,
    /// OP_GET_THROW_OK：弹 throw_val，retainOwned 其 .ok 内值压栈。供 match Ok(v) 字段绑定。
    op_get_throw_ok,
    /// OP_GET_THROW_ERR：弹 throw_val，把其 .err（ErrorValue）包成 error_val 压栈。供 match Error(e) 绑定。
    op_get_throw_err,

    // ── M3d：方法调用 + for 循环 ──
    /// OP_CALL_METHOD <u16 name_const><u8 argc>：栈布局 [receiver, arg0..arg_{argc-1}]，
    /// 按 receiver 类型查内建方法表（method.zig），弹 receiver + 实参，压结果。未知方法 → panic。
    op_call_method,
    /// OP_FOR_NEXT <u16 iter_slot><u16 idx_slot><i32 exit_off>：iter_slot 持 array/range/string，
    /// idx_slot 持当前索引（i64）。若耗尽 → 跳 exit_off（不压元素）；否则压当前元素 + idx 自增。
    op_for_next,
    /// OP_MAKE_RANGE <u8 inclusive>：弹 [start, end]（两整数），压 range 值。供 `..`(0) / `..=`(1)。
    op_make_range,

    // ── M4a：atomic（运行时不变，VM 纯 refcount 用 AtomicValue 内建原子 ref_count）──
    /// OP_MAKE_ATOMIC：弹栈顶值（int/float/bool/char），包成 AtomicValue（ref_count=1），压 atomic_val。供 `atomic e`。
    op_make_atomic,
    /// OP_GET_LOCAL_RAW <u16 slot>：同 OP_GET_LOCAL 但**不**对 atomic_val 透明 load
    /// （仍透明解 cell）。供方法调用接收者（cas/swap 需原始 Atomic，不是 load 出的标量）。
    op_get_local_raw,
    /// OP_GET_UPVALUE_RAW <u16 idx>：同 OP_GET_UPVALUE 但不透明 load atomic_val。供方法调用接收者。
    op_get_upvalue_raw,
    /// OP_COMPOUND_LOCAL <u16 slot><u8 arith_op>：弹 rhs。slot 持 atomic_val → 原子 fetch<op>（不重写 slot）；
    /// 否则 slot_val arith rhs 写回 slot。arith_op 为 OpCode 整数值（op_add/op_sub/...）。供 Atomic 透明复合赋值。
    op_compound_local,
    /// OP_COMPOUND_UPVALUE <u16 idx><u8 arith_op>：同 OP_COMPOUND_LOCAL 但作用于 upvalue cell（spawn body
    /// 捕获的 Atomic 复合赋值必经此路——cell.inner 持 atomic 时原子 fetch<op>，不可退化为标量覆盖）。
    op_compound_upvalue,

    // ── M4c：spawn（运行时不变，VM 协程内起独立执行上下文）──
    /// OP_SPAWN：弹栈顶 vm_closure（spawn body 编译成的零参闭包），深拷捕获快照进 per-spawn arena，
    /// 起 OS 线程跑子 VM 执行 body，压 spawn_val 句柄。await 时取结果（深拷回父 allocator）。
    op_spawn,
    /// OP_MAKE_LAZY：弹栈顶 vm_closure（lazy expr 编译成的零参闭包），包成 lazy_val（vm_thunk 模式）压栈。
    /// 首次透明读取（OP_GET_LOCAL/UPVALUE 见 lazy）时 force：跑 thunk 缓存结果。
    op_make_lazy,
    // ── M4d：select 多路复用（镜像 eval：poll 各 recv arm 取首个就绪；否则首个 timeout body；否则阻塞首 arm）──
    /// OP_TRY_RECV：弹栈顶 channel/sender/receiver，非阻塞 tryRecv。就绪压 [value, true]；否则压 [unit, false]。
    op_try_recv,
    /// OP_RECV：弹栈顶 channel/sender/receiver，阻塞 recv。压 value（关闭则压 unit）。
    op_recv,
    /// OP_MAKE_TRAIT <u8 count>：弹栈顶 count 个 [name(string), closure] 对（顺序压栈，逆序弹），
    /// 建 vm_owned trait_value（vtable: name->vm_closure，data=null）压栈。供内联 trait 值。
    op_make_trait,
    /// OP_PUSH_INPLACE <u16 slot>：弹栈顶 arg。读 slot 的数组 v（不 retain）。
    /// 若 v 是 array 且 v.rc==1：原地扩容（capacity 倍增），写入 arg，push v.retain()。
    /// 否则 fallback 到通用 push（method.dispatch）。供 `arr = arr.push(x)` 模式。
    op_push_inplace,

    pub fn name(self: OpCode) []const u8 {
        return @tagName(self);
    }
};

/// 原生内建函数 id（OP_CALL_NATIVE 的立即数）。编译器按裸名映射，VM 按 id 分派。
pub const Native = enum(u8) {
    println,
    print,
    ok,
    err,
    channel,
    type,
    eq,
    panic,
    eprintln,
    eprint,
    scan,
    scanln,

    pub fn fromName(s: []const u8) ?Native {
        if (std.mem.eql(u8, s, "println")) return .println;
        if (std.mem.eql(u8, s, "print")) return .print;
        if (std.mem.eql(u8, s, "Ok")) return .ok;
        if (std.mem.eql(u8, s, "Error")) return .err;
        if (std.mem.eql(u8, s, "channel")) return .channel;
        if (std.mem.eql(u8, s, "type")) return .type;
        if (std.mem.eql(u8, s, "eq")) return .eq;
        if (std.mem.eql(u8, s, "Panic")) return .panic;
        if (std.mem.eql(u8, s, "eprintln")) return .eprintln;
        if (std.mem.eql(u8, s, "eprint")) return .eprint;
        if (std.mem.eql(u8, s, "scan")) return .scan;
        if (std.mem.eql(u8, s, "scanln")) return .scanln;
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

/// 指针版立即数解码：从 [*]const u8 直接读取，省去基址+偏移加法。
/// 供 VM dispatch 循环的 ip_ptr 缓存路径使用。
pub inline fn readU16Ptr(ptr: [*]const u8) u16 {
    return @as(u16, ptr[0]) | (@as(u16, ptr[1]) << 8);
}

pub inline fn readI32Ptr(ptr: [*]const u8) i32 {
    const u: u32 = @as(u32, ptr[0]) |
        (@as(u32, ptr[1]) << 8) |
        (@as(u32, ptr[2]) << 16) |
        (@as(u32, ptr[3]) << 24);
    return @bitCast(u);
}

/// 指针跳转：ip_ptr 前进 off 字节（off 可为负）。用 wrapping 加法支持回退。
pub inline fn jumpPtr(ptr: [*]const u8, off: i32) [*]const u8 {
    const off_isize: isize = @intCast(off);
    return @ptrFromInt(@intFromPtr(ptr) +% @as(usize, @bitCast(off_isize)));
}
