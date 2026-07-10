//! 寄存器式 VM 执行引擎。
//! 全局寄存器池：单个大 Value 数组，帧通过 base_offset 划分。
//! 每帧占用 register_count 个连续槽位：[base, base+register_count)
//!
//! 与栈式 vm.zig 的 doArith/doCompare 镜像，但操作数从寄存器读取而非操作数栈弹栈。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const reg_opcode = @import("opcode.zig");
const reg_chunk = @import("chunk.zig");
const profiler_mod = @import("profiler");
const slab_allocator = @import("slab_allocator");
const shared = @import("shared");
const opcode = shared.native_mod;
const cast = shared.cast_mod;
const method = shared.method_mod;

pub const VMError = error{
    OutOfMemory,
    TypeMismatch,
    WrongArity,
    NoSuchMethod,
    NoSuchFunction,
    DivisionByZero,
    ArithmeticOverflow,
    InvalidInstruction,
    InvalidJump,
    ChannelClosed,
    StackOverflow,
    InvalidSpawn,
    InvalidUpvalue,
    Unsupported,
} || std.mem.Allocator.Error;

/// 全局寄存器池：初始 64K 槽，按需扩容至最大 1M 槽
const REG_POOL_INITIAL: usize = 64 * 1024;
const REG_POOL_MAX: usize = 1024 * 1024;
/// 最大帧深度
const MAX_FRAMES: usize = 64 * 1024;
/// 无效 memo_slot 标记
const MEMO_SLOT_NONE: u16 = 0xFFFF;
/// 内建类型名常量（集中定义于 ast.type_names）
const type_names = ast.type_names;

/// 调用帧
const RegFrame = struct {
    func: *const reg_chunk.RegFunction,
    ip: usize, // 指令索引（非字节偏移）
    base: usize, // 本帧在全局寄存器池中的基址
    upvalues: []value.Value, // 闭包捕获值
    memo_slot: u16, // MEMO_SLOT_NONE = 非 memoized
    memo_arg_hash: u64,
    /// 调用者帧中存放返回值的基址
    return_base: usize,
    /// 调用者帧中存放返回值的寄存器号
    return_reg: u8,
};

const MemoKey = struct {
    slot: u16,
    arg_hash: u64,
};

/// 运行时类型名（镜像栈式 VM 的 valueTypeName）。
fn regValueTypeName(val: value.Value) []const u8 {
    return switch (val) {
        .int => @tagName(val.asInt().type),
        .float => @tagName(val.asFloat().type),
        .boolean => "bool",
        .char => "char",
        .string => "str",
        .null_val => "null",
        .unit => "unit",
        .array => "array",
        .record => "record",
        .adt => val.adt.type_name,
        .newtype => val.newtype.type_name,
        .range => "range",
        .error_val => val.error_val.type_name,
        .throw_val => "Throw",
        .partial => "partial",
        .array_iterator => "array_iterator",
        .string_iterator => "string_iterator",
        .range_iterator => "range_iterator",
        .atomic_val => "Atomic",
        .spawn_val => "Spawn",
        .channel_val => "Channel",
        .sender_val => "Sender",
        .receiver_val => "Receiver",
        .trait_value => blk: {
            const tv = val.trait_value;
            break :blk if (tv.trait_name.len > 0) tv.trait_name else "trait";
        },
        .lazy_val => "Lazy",
        .cell => regValueTypeName(val.cell.inner),
        .builtin, .vm_closure => "function",
    };
}

/// 结构相等（镜像栈式 VM 的 structuralEquals，直接调用 value.equals）。
fn regStructuralEquals(a: value.Value, b: value.Value) bool {
    return value.equals(a, b);
}

/// 寄存器式 VM
pub const RegVM = struct {
    allocator: std.mem.Allocator,
    /// 全局寄存器池
    reg_pool: []value.Value,
    /// 帧栈
    frames: std.ArrayListUnmanaged(RegFrame) = .empty,
    /// 程序指针
    program: ?*const reg_chunk.RegProgram = null,
    /// 全局变量区
    globals: std.ArrayListUnmanaged(value.Value) = .empty,
    /// IC slot 池（方法分派缓存）
    ic_slots: std.ArrayListUnmanaged(IcSlot) = .empty,
    /// memoization 缓存
    memo_cache: std.AutoHashMapUnmanaged(MemoKey, value.Value) = .empty,
    /// memo slot miss 计数
    memo_slot_misses: std.AutoHashMapUnmanaged(u16, u32) = .empty,
    /// 被禁用的 memo slot
    memo_disabled_slots: std.AutoHashMapUnmanaged(u16, void) = .empty,
    /// profiler
    profiler: ?*profiler_mod.Profiler = null,
    /// 诊断字段（与栈式 VM 保持兼容）
    err_msg: ?[]const u8 = null,
    err_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
    /// stop_depth（spawn 边界）
    stop_depth: usize = 0,
    /// IO 接口（用于 println/print 等内建输出）
    io: ?std.Io = null,

    const IcSlot = struct {
        cached_tag: u8 = 0,
        method_id: u8 = 0,
        is_builtin: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) RegVM {
        const pool = allocator.alloc(value.Value, REG_POOL_INITIAL) catch unreachable;
        @memset(pool, value.Value.fromNull());
        return .{
            .allocator = allocator,
            .reg_pool = pool,
        };
    }

    /// 按需扩容寄存器池（至少 needed 个槽）。新槽初始化为 null。
    fn ensureCapacity(self: *RegVM, needed: usize) VMError!void {
        if (needed <= self.reg_pool.len) return;
        if (needed > REG_POOL_MAX) return error.StackOverflow;
        const new_len = @min(needed * 2, REG_POOL_MAX);
        const new_pool = self.allocator.realloc(self.reg_pool, new_len) catch return error.OutOfMemory;
        @memset(new_pool[self.reg_pool.len..], value.Value.fromNull());
        self.reg_pool = new_pool;
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) RegVM {
        var vm = init(allocator);
        vm.io = io;
        return vm;
    }

    pub fn initWithCache(cache: *slab_allocator.ThreadCache, io: std.Io) RegVM {
        var vm = init(cache.allocator());
        vm.io = io;
        return vm;
    }

    pub fn setProfiler(self: *RegVM, p: *profiler_mod.Profiler) void {
        self.profiler = p;
    }

    pub fn deinit(self: *RegVM) void {
        self.allocator.free(self.reg_pool);
        self.frames.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.ic_slots.deinit(self.allocator);
        self.memo_cache.deinit(self.allocator);
        self.memo_slot_misses.deinit(self.allocator);
        self.memo_disabled_slots.deinit(self.allocator);
        // err_msg 指向字符串字面量，无需 free
    }

    /// 主入口：调用函数
    pub fn call(self: *RegVM, program: *const reg_chunk.RegProgram, entry: u16, args: []const value.Value) VMError!value.Value {
        self.program = program;
        // 运行全局初始化
        if (program.globals_init) |gi| {
            try self.globals.resize(self.allocator, program.global_count);
            @memset(self.globals.items, value.Value.fromNull());
            try self.setupFrame(&program.functions.items[gi], &.{}, 0, 0);
            self.stop_depth = 1;
            _ = try self.runLoop();
        }
        // 建立入口帧
        const func = &program.functions.items[entry];
        try self.setupFrame(func, args, 0, 0);
        self.stop_depth = self.frames.items.len;
        return try self.runLoop();
    }

    /// 建立新帧。return_base/return_reg 指示调用者存放返回值的位置。
    /// args 中的 Value 会被 retain（callee 帧持有自己的引用）。
    fn setupFrame(self: *RegVM, func: *const reg_chunk.RegFunction, args: []const value.Value, return_base: usize, return_reg: u8) VMError!void {
        if (self.frames.items.len >= MAX_FRAMES) return error.StackOverflow;
        // 分配寄存器区间：紧接上一帧之后
        const base = if (self.frames.items.len == 0) 0 else blk: {
            const prev = &self.frames.items[self.frames.items.len - 1];
            break :blk prev.base + prev.func.register_count;
        };
        if (base + func.register_count > self.reg_pool.len) {
            try self.ensureCapacity(base + func.register_count);
        }

        // 参数放入寄存器 [base, base+arity)，retain 确保 callee 持有独立引用
        for (args, 0..) |a, i| {
            if (i >= func.arity) break;
            self.reg_pool[base + i] = a.retain();
        }
        // 其余寄存器初始化为 unit
        var i: usize = func.arity;
        while (i < func.register_count) : (i += 1) {
            self.reg_pool[base + i] = value.Value.fromUnit();
        }

        try self.frames.append(self.allocator, .{
            .func = func,
            .ip = 0,
            .base = base,
            .upvalues = &.{},
            .memo_slot = MEMO_SLOT_NONE,
            .memo_arg_hash = 0,
            .return_base = return_base,
            .return_reg = return_reg,
        });
    }

    /// 计算纯函数调用的参数 hash（用于 memoization 缓存键）。
    /// 仅 hash 标量值（null/unit/bool/char/int/float/string）；任一参数为复合/引用类型 → 返回 null（不 memoize）。
    /// 不同值必产生不同 hash（无 false hit）；同值同路径必产生同 hash。
    fn hashArgsForMemo(args: []const value.Value) ?u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (args) |a| {
            switch (a) {
                .null_val => hasher.update(&[_]u8{0}),
                .unit => hasher.update(&[_]u8{1}),
                .boolean => |b| hasher.update(&[_]u8{ if (b) 2 else 3 }),
                .char => |c| {
                    hasher.update(&[_]u8{4});
                    var cp_bytes: [4]u8 = undefined;
                    std.mem.writeInt(u32, &cp_bytes, c.codepoint, .little);
                    hasher.update(&cp_bytes);
                },
                .int => |i| {
                    hasher.update(&[_]u8{5});
                    hasher.update(&[_]u8{@intFromEnum(i.type)});
                    var lo_bytes: [8]u8 = undefined;
                    var hi_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &lo_bytes, i.lo, .little);
                    std.mem.writeInt(u64, &hi_bytes, i.hi, .little);
                    hasher.update(&lo_bytes);
                    hasher.update(&hi_bytes);
                },
                .float => |f| {
                    hasher.update(&[_]u8{6});
                    hasher.update(&[_]u8{@intFromEnum(f.type)});
                    var b_bytes: [8]u8 = undefined;
                    var e_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &b_bytes, f.bits, .little);
                    std.mem.writeInt(u64, &e_bytes, f.extra, .little);
                    hasher.update(&b_bytes);
                    hasher.update(&e_bytes);
                },
                .string => |s| {
                    hasher.update(&[_]u8{7});
                    hasher.update(s.bytes());
                },
                else => return null, // 复合/引用类型 → 不 memoize（保守安全）
            }
        }
        return hasher.final();
    }

    /// 主执行循环
    fn runLoop(self: *RegVM) VMError!value.Value {
        var result: value.Value = value.Value.fromUnit();
        while (self.frames.items.len >= self.stop_depth) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const func = frame.func;
            const code = func.chunk.code.items;
            const base = frame.base;
            const ip = frame.ip;
            if (ip >= code.len) return error.InvalidInstruction;
            const inst = code[ip];
            const op = reg_opcode.getOp(inst);
            const a = reg_opcode.getA(inst);
            const b = reg_opcode.getB(inst);
            const c = reg_opcode.getC(inst);
            const bx = reg_opcode.getBx(inst);
            const sbx = reg_opcode.getsBx(inst);
            const loc = func.chunk.locAt(ip);
            frame.ip = ip + 1; // 预推进

            switch (op) {
                // ── 加载/常量 ──
                .load_const => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = func.chunk.constants.items[bx].retain();
                },
                .load_null => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromNull();
                },
                .load_unit => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromUnit();
                },
                .load_true => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(true);
                },
                .load_false => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(false);
                },
                .load_global => {
                    if (self.globals.items.len <= bx) return error.InvalidInstruction;
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = self.globals.items[bx].retain();
                },
                .store_global => {
                    if (self.globals.items.len <= bx) return error.InvalidInstruction;
                    self.globals.items[bx].release(self.allocator);
                    self.globals.items[bx] = self.reg_pool[base + a].retain();
                },

                // ── 寄存器间移动 ──
                .move, .bind => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = self.reg_pool[base + b].retain();
                },
                .assign => {
                    // 赋值语义：slot 持 atomic_val → 透明 atomic store（保持共享身份，
                    // 写对捕获该原子的 spawn 可见）。镜像栈式 op_set_local_assign。
                    const cur = self.reg_pool[base + a];
                    if (cur == .atomic_val) {
                        cur.atomic_val.store(unwrapTransparent(self.reg_pool[base + b]));
                    } else if (cur == .cell and cur.cell.inner == .atomic_val) {
                        cur.cell.inner.atomic_val.store(unwrapTransparent(self.reg_pool[base + b]));
                    } else {
                        cur.release(self.allocator);
                        self.reg_pool[base + a] = self.reg_pool[base + b].retain();
                    }
                },
                .move_raw => {
                    // 不 retain（用于 atomic 透明读），仅覆盖槽位
                    self.reg_pool[base + a] = self.reg_pool[base + b];
                },
                .bind_letrec => {
                    // BIND_LETREC A B C — R[A] = R[B]（letrec 自绑定），
                    // 并更新 closure 的 upvalue[C] Cell 使其指向 closure 自身（实现自引用）
                    const closure_val = self.reg_pool[base + b];
                    if (closure_val == .vm_closure) {
                        const cl = closure_val.vm_closure;
                        if (c < cl.upvalues.len) {
                            const uv = cl.upvalues[c];
                            if (uv == .cell) {
                                uv.cell.inner.release(self.allocator);
                                uv.cell.inner = closure_val.retain();
                            }
                        }
                    }
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = closure_val.retain();
                },

                // ── 隐式数值定型（caller-side coerce）──
                .coerce => {
                    // COERCE A B C — R[A] = coerce(R[B], type_name_idx=C)
                    const src = self.reg_pool[base + b];
                    const tname = func.chunk.constants.items[c].string.bytes();
                    if (src.isInteger() or src.isFloat()) {
                        if (cast.castNumeric(self.allocator, src, tname)) |coerced| {
                            self.reg_pool[base + a].release(self.allocator);
                            self.reg_pool[base + a] = coerced;
                        } else |_| {
                            // 溢出/不符：原样 move（best-effort，镜像栈式 VM doCoerce）
                            self.reg_pool[base + a].release(self.allocator);
                            self.reg_pool[base + a] = src.retain();
                        }
                    } else {
                        // 非数值：原样 move
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = src.retain();
                    }
                },

                // ── 算术（二元）──
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor => {
                    const result_val = try self.doArith(op, self.reg_pool[base + b], self.reg_pool[base + c], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 算术（一元）──
                .neg => {
                    const result_val = try self.doNegate(self.reg_pool[base + b], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 比较 ──
                .eq, .neq, .lt, .gt, .le, .ge => {
                    const result_val = try self.doCompare(op, self.reg_pool[base + b], self.reg_pool[base + c], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 逻辑非 ──
                .not_op => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(!self.reg_pool[base + b].asBool());
                },

                // ── 跳转 ──
                .jump => {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                },
                .jump_if_false => {
                    if (!self.reg_pool[base + a].asBool()) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_true => {
                    if (self.reg_pool[base + a].asBool()) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_null => {
                    if (self.reg_pool[base + a] == .null_val) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },
                .jump_if_not_null => {
                    if (self.reg_pool[base + a] != .null_val) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + sbx);
                    }
                },

                // ── 调用 ──
                .call => {
                    const func_idx = bx;
                    const callee = &self.program.?.functions.items[func_idx];
                    const argc = callee.arity;
                    // 参数在 [base+a+1, base+a+1+argc)
                    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
                    // setupFrame 会 retain 参数，callee 帧持有独立引用
                    try self.setupFrame(callee, args_slice, base, a);
                },
                .call_native => {
                    // CALL_NATIVE A B C — A=dst, B=native_id, C=argc；args 在 [base+a+1, base+a+1+C)
                    const nat: opcode.Native = @enumFromInt(b);
                    const argc: usize = c;
                    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
                    const result_val = try self.doCallNative(nat, argc, args_slice, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 返回 ──
                // return_base/return_reg 存储在被调用者帧（当前 frame）中，
                // frameReturn() 会弹出该帧，故需在弹出前保存。
                .return_op => {
                    const ret_val = self.reg_pool[base + a].retain();
                    const ret_base = frame.return_base;
                    const ret_reg = frame.return_reg;
                    // memoization：纯函数返回时缓存结果（帧弹出前读取 memo_slot/arg_hash）
                    const m_slot = frame.memo_slot;
                    const m_hash = frame.memo_arg_hash;
                    if (m_slot != MEMO_SLOT_NONE and ret_val.isMemoizableValue()) {
                        self.memo_cache.put(self.allocator, .{ .slot = m_slot, .arg_hash = m_hash }, ret_val.retain()) catch {};
                    }
                    try self.frameReturn();
                    if (self.frames.items.len < self.stop_depth) {
                        result = ret_val;
                        break;
                    }
                    // 返回值放入调用者指定的目标寄存器
                    self.reg_pool[ret_base + ret_reg].release(self.allocator);
                    self.reg_pool[ret_base + ret_reg] = ret_val;
                },
                .return_unit => {
                    const ret_base = frame.return_base;
                    const ret_reg = frame.return_reg;
                    const m_slot = frame.memo_slot;
                    const m_hash = frame.memo_arg_hash;
                    if (m_slot != MEMO_SLOT_NONE) {
                        self.memo_cache.put(self.allocator, .{ .slot = m_slot, .arg_hash = m_hash }, value.Value.fromUnit().retain()) catch {};
                    }
                    try self.frameReturn();
                    if (self.frames.items.len < self.stop_depth) {
                        result = value.Value.fromUnit();
                        break;
                    }
                    self.reg_pool[ret_base + ret_reg].release(self.allocator);
                    self.reg_pool[ret_base + ret_reg] = value.Value.fromUnit();
                },

                // ── 显式释放 ──
                .release => {
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromNull();
                },

                // ── 类型转换 ──
                .cast => {
                    const src = self.reg_pool[base + b];
                    const tname = func.chunk.constants.items[c].string.bytes();
                    const result_val = try self.doCast(src, tname, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 列表/字符串拼接 ──
                .concat_list => {
                    const left = self.reg_pool[base + b];
                    const right = self.reg_pool[base + c];
                    if (left == .array and right == .array) {
                        const la = left.array.elements;
                        const ra = right.array.elements;
                        const elems = self.allocator.alloc(value.Value, la.len + ra.len) catch return error.OutOfMemory;
                        for (la, 0..) |e, i| elems[i] = e.retain();
                        for (ra, 0..) |e, i| elems[la.len + i] = e.retain();
                        const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
                        arr_ptr.* = .{ .elements = elems, .capacity = elems.len, .fixed_size = null };
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
                    } else if (left == .string and right == .string) {
                        const ls = left.string.bytes();
                        const rs = right.string.bytes();
                        const total = ls.len + rs.len;
                        const buf = self.allocator.alloc(u8, total) catch return error.OutOfMemory;
                        @memcpy(buf[0..ls.len], ls);
                        @memcpy(buf[ls.len..total], rs);
                        const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
                        s.* = value.Str.fromOwnedBytes(self.allocator, buf);
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = value.Value{ .string = s };
                    } else {
                        return self.fail(loc, "operator '++' requires array or string operands", error.TypeMismatch);
                    }
                },

                // ── 数组构造 ──
                .make_array => {
                    const n: usize = b;
                    const elems = self.allocator.alloc(value.Value, n) catch return error.OutOfMemory;
                    for (0..n) |i| elems[i] = self.reg_pool[base + a + 1 + i].retain();
                    const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
                    arr_ptr.* = .{ .elements = elems, .capacity = elems.len, .fixed_size = null };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
                },

                // ── 数组/字符串索引 ──
                .index_op => {
                    const obj = self.reg_pool[base + b];
                    const idx_val = self.reg_pool[base + c];
                    const result_val = try self.doIndex(obj, idx_val, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 字段访问 ──
                .get_field => {
                    const obj = self.reg_pool[base + b];
                    const field_name = func.chunk.constants.items[c].string.bytes();
                    const result_val = try self.doGetField(obj, field_name, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── ADT 字段访问（按索引）──
                .get_adt_field => {
                    const obj = self.reg_pool[base + a];
                    if (obj != .adt) return self.fail(loc, "ADT field access on non-adt value", error.TypeMismatch);
                    const field_idx: usize = bx;
                    if (field_idx >= obj.adt.fields.len) return self.fail(loc, "ADT field index out of bounds", error.TypeMismatch);
                    const result_val = obj.adt.fields[field_idx].value.retain();
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 字段赋值（COW）──
                .set_field => {
                    const obj = self.reg_pool[base + a];
                    const field_name = func.chunk.constants.items[b].string.bytes();
                    const new_val = self.reg_pool[base + c];
                    const result_val = try self.doSetField(obj, field_name, new_val, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 索引赋值（COW）──
                .set_index => {
                    const obj = self.reg_pool[base + a];
                    const idx_val = self.reg_pool[base + b];
                    const new_val = self.reg_pool[base + c];
                    const result_val = try self.doSetIndex(obj, idx_val, new_val, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 方法调用 ──
                .call_method, .call_method_ic => {
                    // CALL_METHOD A B C — receiver=R[A], name_idx=B, argc=C; args in R[A+1..A+C]
                    // CALL_METHOD_IC same but B=ic_slot (ignored for now, fall through to call_method)
                    const recv = self.reg_pool[base + a];
                    const method_name = func.chunk.constants.items[b].string.bytes();
                    const argc: usize = c;
                    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
                    const result_val = try self.doCallMethod(recv, method_name, args_slice, loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── ADT 构造（iABC: A=dst, B=ctor_idx, C=argc）──
                .make_adt => {
                    const ctor_idx: usize = b;
                    const argc: usize = c;
                    const desc = self.program.?.adt_ctors.items[ctor_idx];
                    const fields = self.allocator.alloc(value.AdtField, argc) catch return error.OutOfMemory;
                    for (0..argc) |i| {
                        var fv = self.reg_pool[base + a + 1 + i].retain();
                        if (i < desc.field_types.len) if (desc.field_types[i]) |tn| {
                            if (fv.isInteger() or fv.isFloat()) {
                                if (cast.castNumeric(self.allocator, fv, tn)) |coerced| {
                                    fv.release(self.allocator);
                                    fv = coerced;
                                } else |_| {}
                            }
                        };
                        fields[i] = .{ .name = if (i < desc.field_names.len) desc.field_names[i] else null, .value = fv };
                    }
                    const adt_ptr = self.allocator.create(value.AdtValue) catch return error.OutOfMemory;
                    adt_ptr.* = .{ .type_name = desc.type_name, .constructor = desc.ctor_name, .fields = fields };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .adt = adt_ptr };
                },

                // ── newtype 构造（iABC: A=dst, B=src, C=nt_idx）──
                .make_newtype => {
                    const inner = self.reg_pool[base + b].retain();
                    const nt_idx: usize = c;
                    const desc = self.program.?.newtype_ctors.items[nt_idx];
                    const nt_ptr = self.allocator.create(value.NewtypeValue) catch return error.OutOfMemory;
                    nt_ptr.* = .{ .type_name = desc.type_name, .inner = inner };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .newtype = nt_ptr };
                },

                // ── error 构造 ──
                .make_error => {
                    // iABC: A=dst, B=src(inner value), C=err_idx
                    // 镜像栈式 op_make_error：拼 prefix+": "+msg → ErrorValue → 包装 throw_val.err
                    const inner = self.reg_pool[base + b].retain();
                    defer inner.release(self.allocator);
                    const err_idx: usize = c;
                    const desc = self.program.?.error_ctors.items[err_idx];
                    var msg: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer msg.deinit(self.allocator);
                    try msg.appendSlice(self.allocator, desc.default_prefix);
                    try msg.appendSlice(self.allocator, ": ");
                    if (inner == .string) {
                        try msg.appendSlice(self.allocator, inner.string.bytes());
                    } else {
                        const formatted = inner.formatAlloc(self.allocator) catch return error.OutOfMemory;
                        defer self.allocator.free(formatted);
                        try msg.appendSlice(self.allocator, formatted);
                    }
                    const e = self.allocator.create(value.ErrorValue) catch return error.OutOfMemory;
                    e.* = .{
                        .type_name = self.allocator.dupe(u8, desc.type_name) catch return error.OutOfMemory,
                        .message = try msg.toOwnedSlice(self.allocator),
                        .is_error_subtype = true,
                    };
                    const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                    tv.* = .{ .payload = .{ .err = e } };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .throw_val = tv };
                },

                // ── record 构造（iABC: A=dst, B=shape_idx, C=field_count）──
                .make_record => {
                    const shape_idx: usize = b;
                    const field_count: usize = c;
                    const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
                    var map = std.StringHashMap(value.Value).init(self.allocator);
                    const field_names = if (shape_idx < self.program.?.record_shapes.items.len)
                        self.program.?.record_shapes.items[shape_idx].field_names
                    else
                        &[_][]const u8{};
                    for (0..field_count) |i| {
                        const val = self.reg_pool[base + a + 1 + i].retain();
                        const fname = if (i < field_names.len) field_names[i] else "";
                        const key = self.allocator.dupe(u8, fname) catch return error.OutOfMemory;
                        map.put(key, val) catch return error.OutOfMemory;
                    }
                    rec_ptr.* = .{ .type_name = "", .fields = map };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .record = rec_ptr };
                },

                // ── range 构造 ──
                .make_range, .make_range_incl => |op_tag| {
                    // iABC: A=dst, B=left, C=right；inclusive 由 opcode 区分
                    const left_val = self.reg_pool[base + b];
                    const right_val = self.reg_pool[base + c];
                    const inclusive = op_tag == .make_range_incl;
                    if (!left_val.isInteger() or !right_val.isInteger()) return self.fail(loc, "range requires integer bounds", error.TypeMismatch);
                    const start_int = left_val.asInt();
                    const end_int = right_val.asInt();
                    const start_i64 = if (start_int.coerceTo(.i64)) |s| s.toNative(i64) else null;
                    const end_i64 = if (end_int.coerceTo(.i64)) |e| e.toNative(i64) else null;
                    const r = self.allocator.create(value.Range) catch return error.OutOfMemory;
                    r.* = .{ .start = start_int, .end = end_int, .inclusive = inclusive, .start_i64 = start_i64, .end_i64 = end_i64 };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .range = r };
                },

                // ── atomic 构造 ──
                .make_atomic => {
                    const inner = self.reg_pool[base + b];
                    const av = self.allocator.create(value.AtomicValue) catch return error.OutOfMemory;
                    av.* = value.AtomicValue.init(inner);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .atomic_val = av };
                },

                // ── lazy 构造（简化：直接求值）──
                .make_lazy => {
                    const inner = self.reg_pool[base + b].retain();
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = inner;
                },

                // ── trait 构造 ──
                .make_trait => {
                    // iABC: A=dst, B=count, methods 在 R[A+1..A+B*2]（name_const, closure 交替）
                    const count: usize = b;
                    const tv = self.allocator.create(value.TraitValue) catch return error.OutOfMemory;
                    tv.* = .{
                        .trait_name = "",
                        .methods = std.StringHashMap(value.Value).init(self.allocator),
                        .allocator = self.allocator,
                        .vm_owned = true,
                    };
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const name_reg = a + 1 + i * 2;
                        const closure_reg = a + 1 + i * 2 + 1;
                        const name_val = self.reg_pool[base + name_reg];
                        const closure_val = self.reg_pool[base + closure_reg].retain();
                        const name_str = if (name_val == .string) name_val.string.bytes() else "";
                        const name_copy = self.allocator.dupe(u8, name_str) catch return error.OutOfMemory;
                        tv.methods.put(name_copy, closure_val) catch return error.OutOfMemory;
                    }
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .trait_value = tv };
                },

                // ── non_null 断言 ──
                .non_null => {
                    if (self.reg_pool[base + a] == .null_val) {
                        return self.fail(loc, "non-null assertion failed", error.TypeMismatch);
                    }
                },

                // ── propagate ──
                .propagate => {
                    const v = self.reg_pool[base + a];
                    if (v == .null_val) {
                        // null propagate: return null to caller
                        const ret_base = frame.return_base;
                        const ret_reg = frame.return_reg;
                        try self.frameReturn();
                        if (self.frames.items.len < self.stop_depth) {
                            result = value.Value.fromNull();
                            break;
                        }
                        self.reg_pool[ret_base + ret_reg].release(self.allocator);
                        self.reg_pool[ret_base + ret_reg] = value.Value.fromNull();
                    } else if (v == .throw_val and v.throw_val.payload == .err) {
                        const ret_base = frame.return_base;
                        const ret_reg = frame.return_reg;
                        const err_val = v.retain();
                        try self.frameReturn();
                        if (self.frames.items.len < self.stop_depth) {
                            result = err_val;
                            break;
                        }
                        self.reg_pool[ret_base + ret_reg].release(self.allocator);
                        self.reg_pool[ret_base + ret_reg] = err_val;
                    }
                    // else: ok value, unwrap throw if needed
                    if (self.reg_pool[base + a] == .throw_val and self.reg_pool[base + a].throw_val.payload == .ok) {
                        const inner = self.reg_pool[base + a].throw_val.payload.ok.retain();
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = inner;
                    }
                },

                // ── throw ──
                .throw_op => {
                    const v = self.reg_pool[base + a].retain();
                    const ret_base = frame.return_base;
                    const ret_reg = frame.return_reg;
                    try self.frameReturn();
                    if (self.frames.items.len < self.stop_depth) {
                        result = v;
                        break;
                    }
                    self.reg_pool[ret_base + ret_reg].release(self.allocator);
                    self.reg_pool[ret_base + ret_reg] = v;
                },

                // ── match 失败 ──
                .match_fail => {
                    return self.fail(loc, "match failed: no matching pattern", error.TypeMismatch);
                },

                // ── 模式匹配测试 ──
                .test_ctor => {
                    const obj = self.reg_pool[base + a];
                    const ctor_idx: usize = bx;
                    const desc = self.program.?.adt_ctors.items[ctor_idx];
                    const matched = (obj == .adt) and std.mem.eql(u8, obj.adt.constructor, desc.ctor_name) and std.mem.eql(u8, obj.adt.type_name, desc.type_name);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(matched);
                },
                .test_lit => {
                    const obj = self.reg_pool[base + b];
                    const lit = func.chunk.constants.items[c];
                    const matched = value.equals(obj, lit);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(matched);
                },
                .test_newtype => {
                    const obj = self.reg_pool[base + a];
                    const nt_idx: usize = bx;
                    const desc = self.program.?.newtype_ctors.items[nt_idx];
                    const matched = (obj == .newtype) and std.mem.eql(u8, obj.newtype.type_name, desc.type_name);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(matched);
                },
                .test_throw => {
                    const obj = self.reg_pool[base + a];
                    const want_ok = (b != 0);
                    // 镜像栈式 op_test_throw：throw_val 按 ok/err 分支；非 throw_val 裸值视作 Ok 载荷
                    const matched = if (obj == .throw_val)
                        (if (want_ok) obj.throw_val.payload == .ok else obj.throw_val.payload == .err)
                    else
                        want_ok;
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value.fromBool(matched);
                },
                .get_throw_ok => {
                    // A=dst, B=scrut（读取不消费）
                    const obj = self.reg_pool[base + b];
                    if (obj != .throw_val) {
                        // 裸值即 Ok 载荷：retain 后写入 dst（src 保持不变）
                        const inner = obj.retain();
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = inner;
                    } else {
                        if (obj.throw_val.payload != .ok) return self.fail(loc, "GET_THROW_OK on non-Ok", error.TypeMismatch);
                        const inner = obj.throw_val.payload.ok.retain();
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = inner;
                    }
                },
                .get_throw_err => {
                    // A=dst, B=scrut（读取不消费）
                    const obj = self.reg_pool[base + b];
                    if (obj != .throw_val) return self.fail(loc, "GET_THROW_ERR on non-Error", error.TypeMismatch);
                    if (obj.throw_val.payload != .err) return self.fail(loc, "GET_THROW_ERR on non-Error", error.TypeMismatch);
                    // §2.4.7: Error(e) 模式匹配时，e 绑定为 ErrorValue 对象（可访问 e.message()）
                    const e = obj.throw_val.payload.err;
                    const type_name = self.allocator.dupe(u8, e.type_name) catch return error.OutOfMemory;
                    const message = self.allocator.dupe(u8, e.message) catch return error.OutOfMemory;
                    const result_val = try value.Value.makeError(self.allocator, type_name, message, e.is_error_subtype);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },
                .get_newtype_inner => {
                    const obj = self.reg_pool[base + b];
                    if (obj != .newtype) return self.fail(loc, "not a newtype value", error.TypeMismatch);
                    const inner = obj.newtype.inner.retain();
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = inner;
                },

                // ── compound_local（复合赋值）──
                .compound_local => {
                    const arith_op: reg_opcode.Op = @enumFromInt(b);
                    const result_val = try self.doArith(arith_op, self.reg_pool[base + a], self.reg_pool[base + c], loc);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = result_val;
                },

                // ── 闭包/upvalue ──
                .closure => {
                    const func_idx: u16 = @intCast(bx);
                    const callee = &self.program.?.functions.items[func_idx];
                    // 按 upvalue_specs 捕获 upvalue
                    var ups: []value.Value = &.{};
                    if (callee.upvalue_specs.items.len > 0) {
                        ups = self.allocator.alloc(value.Value, callee.upvalue_specs.items.len) catch return error.OutOfMemory;
                        for (callee.upvalue_specs.items, 0..) |spec, i| {
                            if (spec.is_local) {
                                // 拷贝寄存器值到新 Cell（不修改原寄存器），共享给闭包
                                const src_val = self.reg_pool[base + spec.index].retain();
                                const cell_ptr = self.allocator.create(value.Cell) catch return error.OutOfMemory;
                                cell_ptr.* = .{ .inner = src_val };
                                ups[i] = value.Value{ .cell = cell_ptr };
                            } else {
                                // 共享外层闭包的 upvalue（已是 Cell）
                                if (spec.index < frame.upvalues.len) {
                                    ups[i] = frame.upvalues[spec.index].retain();
                                } else {
                                    return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
                                }
                            }
                        }
                    }
                    const cl = self.allocator.create(value.VmClosure) catch return error.OutOfMemory;
                    cl.* = .{ .func = callee, .arity = callee.arity, .upvalues = ups, .allocator = self.allocator };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .vm_closure = cl };
                },
                .get_upvalue => {
                    if (frame.upvalues.len > b) {
                        const uv = frame.upvalues[b];
                        const inner = if (uv == .cell) uv.cell.inner.retain() else uv.retain();
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = inner;
                    } else {
                        return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
                    }
                },
                .set_upvalue => {
                    if (frame.upvalues.len > b) {
                        const uv = &frame.upvalues[b];
                        if (uv.* == .cell) {
                            uv.cell.inner.release(self.allocator);
                            uv.cell.inner = self.reg_pool[base + a].retain();
                        } else {
                            uv.release(self.allocator);
                            uv.* = self.reg_pool[base + a].retain();
                        }
                    } else {
                        return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
                    }
                },
                .get_upvalue_raw => {
                    if (frame.upvalues.len > b) {
                        const uv = frame.upvalues[b];
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = uv.retain();
                    } else {
                        return self.fail(loc, "upvalue index out of bounds", error.InvalidUpvalue);
                    }
                },

                // ── call_value（调用闭包值）──
                .call_value => {
                    const argc: usize = c;
                    const callee_val = self.reg_pool[base + a];
                    if (callee_val != .vm_closure) return self.fail(loc, "value is not callable", error.TypeMismatch);
                    const vc = callee_val.vm_closure;
                    // 检查参数数量
                    const total = vc.bound_args.len + argc;
                    if (total != vc.arity) return self.fail(loc, "wrong number of arguments", error.WrongArity);
                    // 收集参数：bound_args + new args
                    const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
                    defer self.allocator.free(all_args);
                    for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
                    for (0..argc) |i| all_args[vc.bound_args.len + i] = self.reg_pool[base + a + 1 + i];
                    const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
                    try self.setupFrame(callee, all_args, base, a);
                    // 传递闭包捕获的 upvalues 给新帧
                    self.frames.items[self.frames.items.len - 1].upvalues = vc.upvalues;
                },

                // ── tail_call（尾调用，复用帧）──
                .tail_call => {
                    const func_idx: u16 = @intCast(bx);
                    const callee = &self.program.?.functions.items[func_idx];
                    const argc: usize = callee.arity;
                    // 暂存参数 + 返回信息（frameReturn 后 frame 指针失效）
                    var argbuf: [256]value.Value = undefined;
                    for (0..argc) |i| argbuf[i] = self.reg_pool[base + a + 1 + i].retain();
                    const ret_base = frame.return_base;
                    const ret_reg = frame.return_reg;
                    // 释放本帧寄存器
                    try self.frameReturn();
                    // 重新建立帧（复用弹出的空间）
                    try self.setupFrame(callee, argbuf[0..argc], ret_base, ret_reg);
                },

                // ── string interpolation ──
                .interp => {
                    const part_count: usize = c;
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.allocator);
                    for (0..part_count) |i| {
                        const part = self.reg_pool[base + a + 1 + i];
                        if (part == .string) {
                            buf.appendSlice(self.allocator, part.string.bytes()) catch return error.OutOfMemory;
                        } else {
                            part.format(self.allocator, &buf) catch return error.OutOfMemory;
                        }
                    }
                    const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
                    s.* = value.Str.fromOwnedBytes(self.allocator, buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .string = s };
                },

                // ── push_inplace（rc==1 原地扩容）──
                .push_inplace => {
                    const arr_val = self.reg_pool[base + a];
                    const new_elem = self.reg_pool[base + c];
                    if (arr_val != .array) return self.fail(loc, "push_inplace on non-array", error.TypeMismatch);
                    // 简化：始终创建新数组
                    const old_elems = arr_val.array.elements;
                    const new_elems = self.allocator.alloc(value.Value, old_elems.len + 1) catch return error.OutOfMemory;
                    for (old_elems, 0..) |e, i| new_elems[i] = e.retain();
                    new_elems[old_elems.len] = new_elem.retain();
                    const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
                    arr_ptr.* = .{ .elements = new_elems, .capacity = new_elems.len, .fixed_size = null };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .array = arr_ptr };
                },

                // ── for_next（迭代器推进）──
                // 布局：FOR_NEXT, JUMP exit, <body>, JUMP back
                // 未耗尽：设 elem，跳过 JUMP exit（frame.ip+=1）→ 落入 body
                // 耗尽：不跳过 → 执行 JUMP exit 跳出循环
                .for_next => {
                    const elem_reg = a;
                    const iter_reg = b;
                    const idx_reg = c;
                    const iterable = self.reg_pool[base + iter_reg];
                    const idx = self.reg_pool[base + idx_reg];
                    var exhausted = false;
                    if (iterable == .array) {
                        const i: usize = if (idx.isInteger()) blk: {
                            const ic = idx.asInt().coerceTo(.i64) orelse return self.fail(loc, "loop index out of i64 range", error.ArithmeticOverflow);
                            break :blk @intCast(ic.toNative(i64));
                        } else 0;
                        if (i < iterable.array.elements.len) {
                            self.reg_pool[base + elem_reg].release(self.allocator);
                            self.reg_pool[base + elem_reg] = iterable.array.elements[i].retain();
                            self.reg_pool[base + idx_reg].release(self.allocator);
                            self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, @as(i64, @intCast(i + 1))));
                        } else {
                            exhausted = true;
                        }
                    } else if (iterable == .range) {
                        const r = iterable.range;
                        const start_i = r.start_i64 orelse return self.fail(loc, "range start out of i64 range", error.ArithmeticOverflow);
                        const end_i = r.end_i64 orelse return self.fail(loc, "range end out of i64 range", error.ArithmeticOverflow);
                        const off: i64 = if (idx.isInteger()) blk: {
                            const ic = idx.asInt().coerceTo(.i64) orelse return self.fail(loc, "loop index out of i64 range", error.ArithmeticOverflow);
                            break :blk ic.toNative(i64);
                        } else 0;
                        const cur: i64 = start_i + off;
                        const past = if (r.inclusive) cur > end_i else cur >= end_i;
                        if (!past) {
                            self.reg_pool[base + elem_reg].release(self.allocator);
                            self.reg_pool[base + elem_reg] = value.Value.fromInt(value.Int.fromNative(.i64, cur));
                            self.reg_pool[base + idx_reg].release(self.allocator);
                            self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, off + 1));
                        } else {
                            exhausted = true;
                        }
                    } else if (iterable == .string) {
                        const s = iterable.string.bytes();
                        const ci_target: i64 = if (idx.isInteger()) blk: {
                            const ic = idx.asInt().coerceTo(.i64) orelse return self.fail(loc, "loop index out of i64 range", error.ArithmeticOverflow);
                            break :blk ic.toNative(i64);
                        } else 0;
                        const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
                        var it = view.iterator();
                        var ci: i64 = 0;
                        var found = false;
                        while (it.nextCodepoint()) |cp| : (ci += 1) {
                            if (ci == ci_target) {
                                self.reg_pool[base + elem_reg].release(self.allocator);
                                self.reg_pool[base + elem_reg] = value.Value.fromChar(value.Char.fromNative(cp) catch unreachable);
                                self.reg_pool[base + idx_reg].release(self.allocator);
                                self.reg_pool[base + idx_reg] = value.Value.fromInt(value.Int.fromNative(.i64, ci_target + 1));
                                found = true;
                                break;
                            }
                        }
                        if (!found) exhausted = true;
                    } else {
                        return self.fail(loc, "for_next on non-iterable", error.TypeMismatch);
                    }
                    if (!exhausted) {
                        frame.ip += 1; // 跳过 JUMP exit，落入 body
                    }
                    // 耗尽时不跳过，下一条 JUMP exit 会跳出循环
                },

                // ── spawn ──
                .spawn => {
                    const closure_val = self.reg_pool[base + b];
                    const argc: usize = c;
                    if (closure_val != .vm_closure) return self.fail(loc, "spawn on non-closure", error.InvalidSpawn);
                    const vc = closure_val.vm_closure;
                    // 收集参数
                    const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
                    defer self.allocator.free(all_args);
                    for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
                    for (0..argc) |i| all_args[vc.bound_args.len + i] = self.reg_pool[base + b + 1 + i];
                    // spawn 需要跨线程，reg VM 简化：同步执行
                    const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
                    const saved_stop = self.stop_depth;
                    defer self.stop_depth = saved_stop;
                    try self.setupFrame(callee, all_args, 0, 0);
                    self.stop_depth = self.frames.items.len;
                    const spawn_result = try self.runLoop();
                    // 创建 SpawnHandle 并存储结果
                    const spawn_handle = self.allocator.create(value.SpawnHandle) catch return error.OutOfMemory;
                    spawn_handle.* = value.SpawnHandle.init(self.allocator);
                    spawn_handle.result = spawn_result;
                    spawn_handle.status.store(.Completed, .release);
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .spawn_val = spawn_handle };
                },

                // ── recv / try_recv ──
                .recv => {
                    const ch_val = self.reg_pool[base + b];
                    if (ch_val != .channel_val) return self.fail(loc, "recv on non-channel", error.TypeMismatch);
                    const ch = ch_val.channel_val;
                    const recv_result = ch.recv();
                    if (recv_result) |v| {
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = v;
                    } else {
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = value.Value.fromNull();
                    }
                },
                .try_recv => {
                    const ch_val = self.reg_pool[base + b];
                    if (ch_val != .channel_val) return self.fail(loc, "try_recv on non-channel", error.TypeMismatch);
                    const ch = ch_val.channel_val;
                    const recv_result = ch.tryRecv();
                    if (recv_result) |v| {
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = v;
                        self.reg_pool[base + a + 1].release(self.allocator);
                        self.reg_pool[base + a + 1] = value.Value.fromBool(true);
                    } else {
                        self.reg_pool[base + a].release(self.allocator);
                        self.reg_pool[base + a] = value.Value.fromNull();
                        self.reg_pool[base + a + 1].release(self.allocator);
                        self.reg_pool[base + a + 1] = value.Value.fromBool(false);
                    }
                },

                // ── record_extend ──
                .record_extend => {
                    // 简化：创建新 record，复制原字段 + 更新
                    const src = self.reg_pool[base + a];
                    if (src != .record) return self.fail(loc, "record_extend on non-record", error.TypeMismatch);
                    const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
                    var map = std.StringHashMap(value.Value).init(self.allocator);
                    var it = src.record.fields.iterator();
                    while (it.next()) |entry| {
                        const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                        map.put(key, entry.value_ptr.*.retain()) catch return error.OutOfMemory;
                    }
                    rec_ptr.* = .{ .type_name = src.record.type_name, .fields = map };
                    self.reg_pool[base + a].release(self.allocator);
                    self.reg_pool[base + a] = value.Value{ .record = rec_ptr };
                },

                // ── call_memoized（纯函数 memoization；约定与 .call 一致：A=dst, Bx=func_idx）──
                .call_memoized => {
                    const func_idx = bx;
                    const callee = &self.program.?.functions.items[func_idx];
                    const argc = callee.arity;
                    const args_slice = self.reg_pool[base + a + 1 ..][0..argc];
                    if (callee.memo_slot != MEMO_SLOT_NONE) {
                        // 计算参数 hash；任一参数不可 memoize（含复合/引用类型）→ 回退普通调用
                        if (hashArgsForMemo(args_slice)) |arg_hash| {
                            if (self.memo_cache.get(.{ .slot = callee.memo_slot, .arg_hash = arg_hash })) |cached| {
                                // 命中：直接写结果到 dst，不进入被调用者帧
                                self.reg_pool[base + a].release(self.allocator);
                                self.reg_pool[base + a] = cached.retain();
                            } else {
                                // 未命中：setupFrame 并在帧上记录 memo_slot + arg_hash，返回时存缓存
                                try self.setupFrame(callee, args_slice, base, a);
                                const new_frame = &self.frames.items[self.frames.items.len - 1];
                                new_frame.memo_slot = callee.memo_slot;
                                new_frame.memo_arg_hash = arg_hash;
                            }
                        } else {
                            try self.setupFrame(callee, args_slice, base, a);
                        }
                    } else {
                        try self.setupFrame(callee, args_slice, base, a);
                    }
                },

                // ── 其余 opcode 后续阶段实现 ──
                // switch 已穷尽所有 opcode，无需 else 分支
            }
        }
        return result;
    }

    /// 帧返回：释放本帧寄存器
    fn frameReturn(self: *RegVM) VMError!void {
        const frame = self.frames.items[self.frames.items.len - 1];
        const func = frame.func;
        const base = frame.base;
        // 释放本帧寄存器（release_mask 优化：仅释放持 boxed 值的寄存器）
        if (func.register_count <= 64 and func.release_mask != 0) {
            var mask = func.release_mask;
            while (mask != 0) {
                const bit = @ctz(mask);
                mask &= mask - 1;
                if (bit < func.register_count) {
                    self.reg_pool[base + bit].release(self.allocator);
                    self.reg_pool[base + bit] = value.Value.fromNull();
                }
            }
        } else {
            for (0..func.register_count) |i| {
                self.reg_pool[base + i].release(self.allocator);
                self.reg_pool[base + i] = value.Value.fromNull();
            }
        }
        _ = self.frames.pop();
    }

    // ============================================================
    // helper 函数
    // ============================================================

    fn fail(self: *RegVM, loc: ast.SourceLocation, msg: []const u8, e: VMError) VMError {
        self.err_loc = loc;
        self.err_msg = msg;
        return e;
    }

    /// 内建函数分派（镜像栈式 VM 的 doCallNative，但操作数从 args 切片读取，结果返回而非压栈）。
    /// args 不会被 retain（调用者寄存器仍持有引用），result 需是独立引用（retain 或新分配）。
    fn doCallNative(self: *RegVM, nat: opcode.Native, argc: usize, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
        switch (nat) {
            .println, .print => {
                if (argc != 1) return self.fail(loc, "println/print expects 1 argument", error.WrongArity);
                const v = unwrapTransparent(args[0]);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                if (v == .string) {
                    buf.appendSlice(self.allocator, v.string.bytes()) catch return error.OutOfMemory;
                } else {
                    v.format(self.allocator, &buf) catch return error.OutOfMemory;
                }
                if (nat == .println) buf.append(self.allocator, '\n') catch {};
                if (self.io) |io| {
                    var out_buf: [4096]u8 = undefined;
                    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
                    w.interface.print("{s}", .{buf.items}) catch {};
                    w.flush() catch {};
                } else {
                    std.debug.print("{s}", .{buf.items});
                }
                return value.Value.fromUnit();
            },
            .eprintln, .eprint => {
                if (argc != 1) return self.fail(loc, "eprintln/eprint expects 1 argument", error.WrongArity);
                const v = args[0];
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                if (v == .string) {
                    buf.appendSlice(self.allocator, v.string.bytes()) catch return error.OutOfMemory;
                } else {
                    v.format(self.allocator, &buf) catch return error.OutOfMemory;
                }
                if (nat == .eprintln) buf.append(self.allocator, '\n') catch {};
                if (self.io) |io| {
                    var err_buf: [4096]u8 = undefined;
                    var w = std.Io.File.stderr().writerStreaming(io, &err_buf);
                    w.interface.print("{s}", .{buf.items}) catch {};
                    w.flush() catch {};
                } else {
                    std.debug.print("{s}", .{buf.items});
                }
                return value.Value.fromUnit();
            },
            .type => {
                if (argc != 1) return self.fail(loc, "type expects 1 argument", error.WrongArity);
                const v = args[0];
                const name = regValueTypeName(v);
                return try value.Value.fromStringBytes(self.allocator, name);
            },
            .eq => {
                if (argc != 2) return self.fail(loc, "eq expects 2 arguments", error.WrongArity);
                return value.Value.fromBool(regStructuralEquals(args[0], args[1]));
            },
            .panic => {
                if (argc != 1) return self.fail(loc, "Panic expects 1 argument", error.WrongArity);
                const v = args[0];
                const msg = if (v == .string)
                    self.allocator.dupe(u8, v.string.bytes()) catch return error.OutOfMemory
                else
                    v.formatAlloc(self.allocator) catch return error.OutOfMemory;
                defer self.allocator.free(msg);
                return self.fail(loc, msg, error.Unsupported);
            },
            .ok => {
                if (argc != 1) return self.fail(loc, "Ok expects 1 argument", error.WrongArity);
                const inner = args[0].retain();
                const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                tv.* = .{ .payload = .{ .ok = inner } };
                return value.Value{ .throw_val = tv };
            },
            .err => {
                if (argc != 1) return self.fail(loc, "Error expects 1 argument", error.WrongArity);
                const v = args[0];
                if (v != .string) return self.fail(loc, "Error expects a str argument", error.TypeMismatch);
                const str = v.string.bytes();
                const e = self.allocator.create(value.ErrorValue) catch return error.OutOfMemory;
                e.* = .{
                    .type_name = self.allocator.dupe(u8, type_names.error_type) catch return error.OutOfMemory,
                    .message = self.allocator.dupe(u8, str) catch return error.OutOfMemory,
                };
                const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                tv.* = .{ .payload = .{ .err = e } };
                return value.Value{ .throw_val = tv };
            },
            .channel => {
                if (argc != 1) return self.fail(loc, "channel expects 1 argument", error.WrongArity);
                const v = args[0];
                if (!v.isInteger()) return self.fail(loc, "channel expects an integer capacity", error.TypeMismatch);
                const int_val = v.asInt();
                const coerced = int_val.coerceTo(.i64) orelse return self.fail(loc, "channel capacity out of range", error.ArithmeticOverflow);
                const cap_v = coerced.toNative(i64);
                if (cap_v < 0) return self.fail(loc, "channel capacity cannot be negative", error.ArithmeticOverflow);
                const cap: usize = @intCast(cap_v);
                const ch = self.allocator.create(value.ChannelValue) catch return error.OutOfMemory;
                ch.* = value.ChannelValue.init(self.allocator, cap) catch {
                    self.allocator.destroy(ch);
                    return error.OutOfMemory;
                };
                return value.Value{ .channel_val = ch };
            },
            .scan, .scanln => return self.fail(loc, "scan/scanln not supported in reg VM", error.Unsupported),
        }
    }

    /// 透明解包：atomic_val → load inner，cell → cell.inner，其他原样返回。
    /// 镜像栈式 VM op_get_local 的透明 load 语义（寄存器式无 get_local 指令，在消费点解包）。
    fn unwrapTransparent(v: value.Value) value.Value {
        return switch (v) {
            .atomic_val => v.atomic_val.load(),
            .cell => v.cell.inner,
            else => v,
        };
    }

    /// 算术运算（二元）。镜像栈式 VM 的 doArith，但操作数直接从寄存器读取。
    fn doArith(self: *RegVM, op: reg_opcode.Op, left_in: value.Value, right_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        // 透明解包 atomic/cell（镜像栈式 VM op_get_local 透明 load）
        const left = unwrapTransparent(left_in);
        const right = unwrapTransparent(right_in);
        // 整数运算
        if (left.isInteger() and right.isInteger()) {
            const left_int = left.asInt();
            const right_int = right.asInt();

            // 位运算（保留 left 类型）
            switch (op) {
                .bit_and => {
                    const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
                    return value.Value.fromInt(left_int.bitwiseAnd(right_coerced));
                },
                .bit_or => {
                    const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
                    return value.Value.fromInt(left_int.bitwiseOr(right_coerced));
                },
                .bit_xor => {
                    const right_coerced = right_int.coerceTo(left_int.type) orelse return self.fail(loc, "bitwise op: operand out of range", error.ArithmeticOverflow);
                    return value.Value.fromInt(left_int.bitwiseXor(right_coerced));
                },
                else => {},
            }

            const result_type = value.promoteIntTypes(left_int.type, right_int.type);
            const left_coerced = left_int.coerceTo(result_type) orelse return self.fail(loc, "arithmetic overflow: operand out of range", error.ArithmeticOverflow);
            const right_coerced = right_int.coerceTo(result_type) orelse return self.fail(loc, "arithmetic overflow: operand out of range", error.ArithmeticOverflow);

            return switch (op) {
                .add => blk: {
                    const r = left_coerced.add(right_coerced);
                    if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
                    break :blk value.Value.fromInt(r.result);
                },
                .sub => blk: {
                    const r = left_coerced.subtract(right_coerced);
                    if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
                    break :blk value.Value.fromInt(r.result);
                },
                .mul => blk: {
                    const r = left_coerced.multiply(right_coerced);
                    if (r.overflow) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
                    break :blk value.Value.fromInt(r.result);
                },
                .div => blk: {
                    const r = left_coerced.divideTruncating(right_coerced) catch return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk value.Value.fromInt(r);
                },
                .mod => blk: {
                    const r = left_coerced.remainder(right_coerced) catch return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk value.Value.fromInt(r);
                },
                else => return self.fail(loc, "unsupported integer operation", error.TypeMismatch),
            };
        }

        // 浮点运算（含 int↔float 混合，提升为 float）
        if ((left.isFloat() or left.isInteger()) and (right.isFloat() or right.isInteger())) {
            const tag: value.FloatType = if (left.isFloat() and right.isFloat()) blk: {
                const lt = left.asFloat().type;
                const rt = right.asFloat().type;
                break :blk if (@intFromEnum(lt) > @intFromEnum(rt)) lt else rt;
            } else if (left.isFloat()) left.asFloat().type else right.asFloat().type;

            const lf: value.Float = if (left.isFloat()) left.asFloat().toFloatType(tag) else value.Float.fromInt(tag, left.asInt());
            const rf: value.Float = if (right.isFloat()) right.asFloat().toFloatType(tag) else value.Float.fromInt(tag, right.asInt());

            const result: value.Float = switch (op) {
                .add => lf.add(rf),
                .sub => lf.subtract(rf),
                .mul => lf.multiply(rf),
                .div => lf.divide(rf),
                .mod => blk: {
                    if (rf.isZero()) return self.fail(loc, "float modulo by zero", error.DivisionByZero);
                    const q = lf.divide(rf);
                    const q_int = q.toInt(.i128) catch return self.fail(loc, "float modulo overflow", error.ArithmeticOverflow);
                    const q_float = value.Float.fromInt(tag, q_int);
                    break :blk lf.subtract(rf.multiply(q_float));
                },
                else => return self.fail(loc, "bitwise op requires integer operands", error.TypeMismatch),
            };
            return value.Value.fromFloat(result);
        }

        // M5：字符串拼接 s + t（镜像栈式 VM doArith 的 string+string 分支）。
        if (op == .add and left == .string and right == .string) {
            const left_str = left.string.bytes();
            const right_str = right.string.bytes();
            if (value.Str.canConcatSso(left_str.len, right_str.len)) {
                const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
                s.* = value.Str.concatSso(left_str, right_str);
                return value.Value{ .string = s };
            }
            const total = left_str.len + right_str.len;
            const buf = self.allocator.alloc(u8, total) catch return error.OutOfMemory;
            @memcpy(buf[0..left_str.len], left_str);
            @memcpy(buf[left_str.len..total], right_str);
            const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
            s.* = value.Str.fromOwnedBytes(self.allocator, buf);
            return value.Value{ .string = s };
        }

        return self.fail(loc, "arithmetic requires numeric operands", error.TypeMismatch);
    }

    /// 一元取负。镜像栈式 VM 的 doNegate。
    fn doNegate(self: *RegVM, v_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        const v = unwrapTransparent(v_in);
        if (v.isInteger()) {
            const int_val = v.asInt();
            const result = int_val.negate();
            // minInt 取负回绕：输入负但结果仍负 → 溢出
            if (int_val.type.isSigned() and int_val.isNegative() and result.isNegative()) {
                return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
            }
            return value.Value.fromInt(result);
        }
        if (v.isFloat()) {
            return value.Value.fromFloat(v.asFloat().negate());
        }
        return self.fail(loc, "'-' requires numeric operand", error.TypeMismatch);
    }

    /// 比较：== != < > <= >=。镜像栈式 VM 的 doCompare。
    fn doCompare(self: *RegVM, op: reg_opcode.Op, left_in: value.Value, right_in: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        // 透明解包 atomic/cell
        const left = unwrapTransparent(left_in);
        const right = unwrapTransparent(right_in);
        // == / !=：数值按 promoteIntTypes 后按值比较（忽略 type_tag）
        if (op == .eq or op == .neq) {
            if (left.isInteger() and right.isInteger()) {
                const left_int = left.asInt();
                const right_int = right.asInt();
                const rt = value.promoteIntTypes(left_int.type, right_int.type);
                const lc = left_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
                const rc = right_int.coerceTo(rt) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
                const eq = lc.compare(rc) == .eq;
                return value.Value.fromBool(if (op == .eq) eq else !eq);
            }
            if (left.isFloat() and right.isFloat()) {
                const lf = left.asFloat();
                const rf = right.asFloat();
                const tag: value.FloatType = if (@intFromEnum(lf.type) > @intFromEnum(rf.type)) lf.type else rf.type;
                const eq = lf.toFloatType(tag).compare(rf.toFloatType(tag)) == .eq;
                return value.Value.fromBool(if (op == .eq) eq else !eq);
            }
            const eq = value.equals(left, right);
            return value.Value.fromBool(if (op == .eq) eq else !eq);
        }

        // < > <= >=
        if (left.isInteger() and right.isInteger()) {
            const left_int = left.asInt();
            const right_int = right.asInt();
            const result_type = value.promoteIntTypes(left_int.type, right_int.type);
            const lc = left_int.coerceTo(result_type) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
            const rc = right_int.coerceTo(result_type) orelse return self.fail(loc, "comparison: operand out of range", error.ArithmeticOverflow);
            const ord = lc.compare(rc);
            return value.Value.fromBool(switch (op) {
                .lt => ord == .lt,
                .gt => ord == .gt,
                .le => ord != .gt,
                .ge => ord != .lt,
                else => unreachable,
            });
        }
        if ((left.isFloat() or left.isInteger()) and (right.isFloat() or right.isInteger())) {
            const tag: value.FloatType = if (left.isFloat() and right.isFloat()) blk: {
                const lt = left.asFloat().type;
                const rt = right.asFloat().type;
                break :blk if (@intFromEnum(lt) > @intFromEnum(rt)) lt else rt;
            } else if (left.isFloat()) left.asFloat().type else right.asFloat().type;
            const lf: value.Float = if (left.isFloat()) left.asFloat().toFloatType(tag) else value.Float.fromInt(tag, left.asInt());
            const rf: value.Float = if (right.isFloat()) right.asFloat().toFloatType(tag) else value.Float.fromInt(tag, right.asInt());
            const ord = lf.compare(rf);
            return value.Value.fromBool(switch (op) {
                .lt => ord == .lt,
                .gt => ord == .gt,
                .le => ord != .gt,
                .ge => ord != .lt,
                else => unreachable,
            });
        }
        // 字符串字典序比较
        if (left == .string and right == .string) {
            const ord = std.mem.order(u8, left.string.bytes(), right.string.bytes());
            return value.Value.fromBool(switch (op) {
                .lt => ord == .lt,
                .gt => ord == .gt,
                .le => ord != .gt,
                .ge => ord != .lt,
                else => unreachable,
            });
        }
        // char 序比较
        if (left == .char and right == .char) {
            const lc = left.asChar().toNative();
            const rc = right.asChar().toNative();
            const ord: std.math.Order = if (lc < rc) .lt else if (lc > rc) .gt else .eq;
            return value.Value.fromBool(switch (op) {
                .lt => ord == .lt,
                .gt => ord == .gt,
                .le => ord != .gt,
                .ge => ord != .lt,
                else => unreachable,
            });
        }
        return self.fail(loc, "comparison requires comparable operands", error.TypeMismatch);
    }

    // ============================================================
    // 复合值访问/操作 helper（镜像栈式 VM）
    // ============================================================

    /// 类型转换（.cast opcode）。镜像栈式 VM doCast。
    /// 输入 src 借用（不 release），返回独立 owned 结果。
    fn doCast(self: *RegVM, src: value.Value, tname: []const u8, loc: ast.SourceLocation) VMError!value.Value {
        if (std.mem.eql(u8, tname, type_names.str_type)) {
            // char → str：UTF-8 编码
            if (src == .char) {
                const c = src.asChar().toNative();
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &utf8_buf) catch return self.fail(loc, "invalid char codepoint", error.Unsupported);
                const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
                @memcpy(buf, utf8_buf[0..len]);
                const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
                s.* = value.Str.fromOwnedBytes(self.allocator, buf);
                return value.Value{ .string = s };
            }
            // string → str：复制内容
            if (src == .string) {
                const dup = self.allocator.dupe(u8, src.string.bytes()) catch return error.OutOfMemory;
                const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
                s.* = value.Str.fromOwnedBytes(self.allocator, dup);
                return value.Value{ .string = s };
            }
            // 其他 → formatAlloc
            const owned = src.formatAlloc(self.allocator) catch return error.OutOfMemory;
            const s = self.allocator.create(value.Str) catch return error.OutOfMemory;
            s.* = value.Str.fromOwnedBytes(self.allocator, @constCast(owned));
            return value.Value{ .string = s };
        }
        const result = cast.castNumeric(self.allocator, src, tname) catch |e| switch (e) {
            error.CastOverflow => return self.fail(loc, "arithmetic overflow: narrowing conversion out of range", error.ArithmeticOverflow),
            error.CastTypeMismatch => return self.fail(loc, "invalid type conversion", error.TypeMismatch),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return result;
    }

    /// 索引访问（.index_op opcode）。镜像栈式 VM doIndex。
    /// 输入 obj/idx 借用，返回独立 owned 结果（retain 元素）。
    fn doIndex(self: *RegVM, obj: value.Value, idx_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        switch (obj) {
            .array => {
                const arr = obj.array;
                if (!idx_val.isInteger()) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
                const iv = idx_val.asInt();
                const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
                const i = idx_coerced.toNative(i64);
                if (i < 0 or i >= @as(i64, @intCast(arr.elements.len)))
                    return self.fail(loc, "index out of bounds", error.TypeMismatch);
                return arr.elements[@intCast(i)].retain();
            },
            .string => {
                const s = obj.string.bytes();
                if (!idx_val.isInteger()) return self.fail(loc, "string index must be an integer", error.TypeMismatch);
                const iv = idx_val.asInt();
                const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
                const i = idx_coerced.toNative(i64);
                if (i < 0) return self.fail(loc, "index out of bounds", error.TypeMismatch);
                const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
                var iter = view.iterator();
                var ci: i64 = 0;
                while (iter.nextCodepoint()) |cp| : (ci += 1) {
                    if (ci == i) {
                        return value.Value.fromChar(value.Char.fromNative(cp) catch unreachable);
                    }
                }
                return self.fail(loc, "index out of bounds", error.TypeMismatch);
            },
            else => return self.fail(loc, "cannot index into this type", error.TypeMismatch),
        }
    }

    /// 字段访问（.get_field opcode）。镜像栈式 VM doGetField。
    /// 输入 obj 借用，返回独立 owned 结果。
    fn doGetField(self: *RegVM, obj: value.Value, field: []const u8, loc: ast.SourceLocation) VMError!value.Value {
        switch (obj) {
            .adt => {
                const av = obj.adt;
                for (av.fields) |f| {
                    if (f.name) |n| {
                        if (std.mem.eql(u8, n, field)) {
                            return f.value.retain();
                        }
                    }
                }
                return self.fail(loc, "no such field on adt", error.TypeMismatch);
            },
            .record => {
                const rec = obj.record;
                if (rec.fields.get(field)) |v| {
                    return v.retain();
                }
                return self.fail(loc, "no such field on record", error.TypeMismatch);
            },
            .trait_value => {
                const tv = obj.trait_value;
                if (tv.methods.get(field)) |v| {
                    return v.retain();
                }
                return self.fail(loc, "no such member on module value", error.TypeMismatch);
            },
            .channel_val => {
                const cv_ptr = obj.channel_val;
                const fid = method.MethodId.fromName(field);
                switch (fid) {
                    .sender => {
                        cv_ptr.ref();
                        const sv = self.allocator.create(value.SenderValue) catch return error.OutOfMemory;
                        sv.* = .{ .channel = cv_ptr };
                        return value.Value{ .sender_val = sv };
                    },
                    .receiver => {
                        cv_ptr.ref();
                        const rv = self.allocator.create(value.ReceiverValue) catch return error.OutOfMemory;
                        rv.* = .{ .channel = cv_ptr };
                        return value.Value{ .receiver_val = rv };
                    },
                    else => return self.fail(loc, "no such field on Channel (only 'sender'/'receiver')", error.TypeMismatch),
                }
            },
            else => return self.fail(loc, "field access on non-record/adt", error.TypeMismatch),
        }
    }

    /// 字段赋值 COW（.set_field opcode）。镜像栈式 VM doSetField。
    /// 输入 obj/new_val 借用，返回新 owned record。
    fn doSetField(self: *RegVM, obj: value.Value, field: []const u8, new_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        if (obj != .record) return self.fail(loc, "cannot assign field on non-record", error.TypeMismatch);
        const old_rec = obj.record;
        // COW 浅拷
        var new_map = std.StringHashMap(value.Value).init(self.allocator);
        var it = old_rec.fields.iterator();
        while (it.next()) |e| {
            const key = self.allocator.dupe(u8, e.key_ptr.*) catch return error.OutOfMemory;
            new_map.put(key, e.value_ptr.*.retain()) catch return error.OutOfMemory;
        }
        // 写字段
        if (new_map.getPtr(field)) |existing| {
            existing.*.release(self.allocator);
            existing.* = new_val.retain();
        } else {
            // 新增字段
            const key = self.allocator.dupe(u8, field) catch return error.OutOfMemory;
            new_map.put(key, new_val.retain()) catch return error.OutOfMemory;
        }
        const rec_ptr = self.allocator.create(value.RecordValue) catch return error.OutOfMemory;
        rec_ptr.* = .{ .type_name = old_rec.type_name, .fields = new_map };
        return value.Value{ .record = rec_ptr };
    }

    /// 索引赋值 COW（.set_index opcode）。镜像栈式 VM doSetIndex。
    /// 输入 obj/idx/new_val 借用，返回新 owned array。
    fn doSetIndex(self: *RegVM, obj: value.Value, idx_val: value.Value, new_val: value.Value, loc: ast.SourceLocation) VMError!value.Value {
        if (obj != .array) return self.fail(loc, "cannot index-assign on non-array", error.TypeMismatch);
        if (!idx_val.isInteger()) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
        const iv = idx_val.asInt();
        const idx_coerced = iv.coerceTo(.i64) orelse return self.fail(loc, "index out of range", error.TypeMismatch);
        const i = idx_coerced.toNative(i64);
        const old_elems = obj.array.elements;
        if (i < 0 or i >= @as(i64, @intCast(old_elems.len)))
            return self.fail(loc, "index out of bounds", error.TypeMismatch);
        // COW 浅拷
        const new_elems = self.allocator.alloc(value.Value, old_elems.len) catch return error.OutOfMemory;
        for (old_elems, 0..) |e, k| new_elems[k] = e.retain();
        new_elems[@intCast(i)].release(self.allocator);
        new_elems[@intCast(i)] = new_val.retain();
        const arr_ptr = self.allocator.create(value.ArrayValue) catch return error.OutOfMemory;
        arr_ptr.* = .{ .elements = new_elems, .capacity = new_elems.len, .fixed_size = obj.array.fixed_size };
        return value.Value{ .array = arr_ptr };
    }

    /// 方法调用（.call_method / .call_method_ic opcode）。镜像栈式 VM doCallMethod。
    /// 输入 recv/args 借用（寄存器仍持引用），返回独立 owned 结果。
    fn doCallMethod(self: *RegVM, recv: value.Value, name: []const u8, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
        // 1. 内建方法 ID 分派
        const method_id = method.MethodId.fromName(name);
        if (method_id != .unknown) {
            if (recv != .spawn_val and recv != .trait_value) {
                const result_opt = method.dispatchById(self.allocator, recv, method_id, args) catch |err| switch (err) {
                    error.NoSuchMethod => null,
                    error.WrongArity => return self.fail(loc, "method called with wrong number of arguments", error.WrongArity),
                    error.TypeMismatch => return self.fail(loc, "method not available on this type", error.TypeMismatch),
                    error.ChannelClosed => return self.fail(loc, "channel: send on closed channel", error.TypeMismatch),
                    error.ArithmeticOverflow => return self.fail(loc, "method result out of range", error.ArithmeticOverflow),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (result_opt) |result| return result;
            }
        }

        // 2. Spawn<T> 方法：await() / cancel() / status()（VM 级处理，镜像栈式 doSpawnMethod）
        if (recv == .spawn_val) {
            return try self.doSpawnMethod(recv.spawn_val, name, args, loc);
        }

        // 2b. TraitValue 方法：从 methods 表取出 closure 并调用
        if (recv == .trait_value) {
            const tv = recv.trait_value;
            if (tv.methods.get(name)) |method_val| {
                return try self.invokeClosure(method_val, args, loc);
            }
            return self.fail(loc, "no such method on trait", error.TypeMismatch);
        }

        // 3. Error trait 内置方法：message() / type_name()
        const err_mid = method.MethodId.fromName(name);
        if (err_mid == .message or err_mid == .type_name) {
            if (args.len != 0) return self.fail(loc, "Error trait method expects 0 arguments", error.WrongArity);
            switch (recv) {
                .error_val => {
                    const e = recv.error_val;
                    const field_value = if (err_mid == .message) e.message else e.type_name;
                    return value.Value.fromStringBytes(self.allocator, field_value) catch error.OutOfMemory;
                },
                .throw_val => {
                    const tv = recv.throw_val;
                    if (tv.payload == .err) {
                        const e = tv.payload.err;
                        const field_value = if (err_mid == .message) e.message else e.type_name;
                        return value.Value.fromStringBytes(self.allocator, field_value) catch error.OutOfMemory;
                    } else {
                        return self.fail(loc, "cannot call Error method on Ok value", error.TypeMismatch);
                    }
                },
                else => {},
            }
        }

        // 3. 用户 trait 方法分派（查 program.trait_methods）
        if (self.program) |prog| {
            const recv_type = regValueTypeName(recv);
            if (findRegTraitMethod(prog, recv_type, name)) |func_idx| {
                return try self.invokeRegMethodBody(prog, func_idx, recv, args, loc);
            }
            if (findRegTraitDefault(prog, name)) |func_idx| {
                return try self.invokeRegMethodBody(prog, func_idx, recv, args, loc);
            }
        }

        // 4. 兜底：method.dispatch 字符串分派
        const result = method.dispatch(self.allocator, recv, name, args) catch |err| switch (err) {
            error.NoSuchMethod => return self.fail(loc, "no such method on this type", error.TypeMismatch),
            error.WrongArity => return self.fail(loc, "method called with wrong number of arguments", error.WrongArity),
            error.TypeMismatch => return self.fail(loc, "method not available on this type", error.TypeMismatch),
            error.ChannelClosed => return self.fail(loc, "channel: send on closed channel", error.TypeMismatch),
            error.ArithmeticOverflow => return self.fail(loc, "method result out of range", error.ArithmeticOverflow),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return result;
    }

    /// 以 [receiver, args...] 建帧跑方法体到 RETURN，结果返回。
    /// 镜像栈式 VM invokeMethodBody（stop_depth 边界）。
    fn invokeRegMethodBody(self: *RegVM, program: *const reg_chunk.RegProgram, func_idx: u16, recv: value.Value, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
        const f = &program.functions.items[func_idx];
        const total: usize = 1 + args.len;
        if (total != f.arity) return self.fail(loc, "trait method arity mismatch", error.WrongArity);
        const all_args = self.allocator.alloc(value.Value, f.arity) catch return error.OutOfMemory;
        defer self.allocator.free(all_args);
        all_args[0] = recv;
        for (args, 0..) |a, i| all_args[1 + i] = a;
        const saved_stop = self.stop_depth;
        defer self.stop_depth = saved_stop;
        try self.setupFrame(f, all_args, 0, 0);
        self.stop_depth = self.frames.items.len;
        return try self.runLoop();
    }

    /// 调用闭包值（trait_value 方法分派用）。
    /// args 为实参（不含 receiver），直接传入闭包。
    fn invokeClosure(self: *RegVM, closure_val: value.Value, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
        if (closure_val != .vm_closure) return self.fail(loc, "trait method is not callable", error.TypeMismatch);
        const vc = closure_val.vm_closure;
        const total = vc.bound_args.len + args.len;
        if (total != vc.arity) return self.fail(loc, "trait method arity mismatch", error.WrongArity);
        const all_args = self.allocator.alloc(value.Value, vc.arity) catch return error.OutOfMemory;
        defer self.allocator.free(all_args);
        for (vc.bound_args, 0..) |ba, i| all_args[i] = ba;
        for (args, 0..) |a, i| all_args[vc.bound_args.len + i] = a;
        const callee: *const reg_chunk.RegFunction = @ptrCast(@alignCast(vc.func));
        const saved_stop = self.stop_depth;
        defer self.stop_depth = saved_stop;
        try self.setupFrame(callee, all_args, 0, 0);
        self.frames.items[self.frames.items.len - 1].upvalues = vc.upvalues;
        self.stop_depth = self.frames.items.len;
        return try self.runLoop();
    }

    /// Spawn<T> 方法分派（镜像栈式 doSpawnMethod）。
    /// await()：取结果（同 allocator，retain 即可；reg VM spawn 同步执行已完成）。
    /// cancel()：标记取消。status()：返回 SpawnStatus ADT。
    fn doSpawnMethod(self: *RegVM, handle: *value.SpawnHandle, name: []const u8, args: []const value.Value, loc: ast.SourceLocation) VMError!value.Value {
        const mid = method.MethodId.fromName(name);
        switch (mid) {
            .await_op => {
                if (args.len != 0) return self.fail(loc, "await expects 0 arguments", error.WrongArity);
                handle.mutex.lock();
                const child_result = handle.result;
                handle.consumed.store(true, .seq_cst);
                const failed = handle.status.load(.seq_cst) == .Failed;
                handle.mutex.unlock();
                if (failed) {
                    const msg = handle.panic_message orelse "spawn: coroutine failed";
                    return self.fail(loc, msg, error.InvalidSpawn);
                }
                // reg VM spawn 同步执行（同 allocator），retain 结果即可
                return if (child_result) |r| r.retain() else value.Value.fromUnit();
            },
            .cancel => {
                if (args.len != 0) return self.fail(loc, "cancel expects 0 arguments", error.WrongArity);
                handle.mutex.lock();
                handle.status.store(.Cancelled, .seq_cst);
                handle.consumed.store(true, .seq_cst);
                handle.condition.broadcast();
                handle.mutex.unlock();
                return value.Value.fromUnit();
            },
            .status => {
                if (args.len != 0) return self.fail(loc, "status expects 0 arguments", error.WrongArity);
                const s = handle.status.load(.seq_cst);
                const ctor: []const u8 = @tagName(s);
                return value.Value.makeAdt(self.allocator, type_names.spawn_status_type, ctor, &[_]value.AdtField{}) catch error.OutOfMemory;
            },
            else => return self.fail(loc, "no such method on Spawn", error.TypeMismatch),
        }
    }
};

// ============================================================
// 顶层 helper（trait 方法查找，镜像栈式 VM）
// ============================================================

/// 内建数值类型枚举（替代字符串名列表，避免大小写/前缀判断）。
const NumericType = enum {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f128,

    pub fn isFloat(self: NumericType) bool {
        return switch (self) {
            .f16, .f32, .f64, .f128 => true,
            else => false,
        };
    }
};

/// builtin 数值类型名 → NumericType 枚举（精确匹配，无前缀判断）。
fn parseNumericType(name: []const u8) ?NumericType {
    switch (name.len) {
        2 => {
            if (name[0] == 'i' and name[1] == '8') return .i8;
            if (name[0] == 'u' and name[1] == '8') return .u8;
        },
        3 => {
            if (name[0] == 'i' and name[1] == '1' and name[2] == '6') return .i16;
            if (name[0] == 'u' and name[1] == '1' and name[2] == '6') return .u16;
            if (name[0] == 'i' and name[1] == '3' and name[2] == '2') return .i32;
            if (name[0] == 'u' and name[1] == '3' and name[2] == '2') return .u32;
            if (name[0] == 'i' and name[1] == '6' and name[2] == '4') return .i64;
            if (name[0] == 'u' and name[1] == '6' and name[2] == '4') return .u64;
            if (name[0] == 'f' and name[1] == '1' and name[2] == '6') return .f16;
            if (name[0] == 'f' and name[1] == '3' and name[2] == '2') return .f32;
            if (name[0] == 'f' and name[1] == '6' and name[2] == '4') return .f64;
        },
        4 => {
            if (name[0] == 'i' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .i128;
            if (name[0] == 'u' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .u128;
            if (name[0] == 'f' and name[1] == '1' and name[2] == '2' and name[3] == '8') return .f128;
        },
        else => {},
    }
    return null;
}

fn isNumericTypeName(name: []const u8) bool {
    return parseNumericType(name) != null;
}

fn numericKindMatches(a: []const u8, b: []const u8) bool {
    const na = parseNumericType(a) orelse return false;
    const nb = parseNumericType(b) orelse return false;
    return na.isFloat() == nb.isFloat();
}

fn regTraitTypeMatches(recv: []const u8, target_ty: []const u8) bool {
    if (target_ty.len == 0) return true;
    if (std.mem.eql(u8, recv, target_ty)) return true;
    return isNumericTypeName(recv) and isNumericTypeName(target_ty) and numericKindMatches(recv, target_ty);
}

fn findRegTraitMethod(program: *const reg_chunk.RegProgram, recv_type: []const u8, method_name: []const u8) ?u16 {
    for (program.trait_methods.items) |d| {
        if (std.mem.eql(u8, d.method_name, method_name) and regTraitTypeMatches(recv_type, d.type_name)) return d.func_idx;
    }
    return null;
}

fn findRegTraitDefault(program: *const reg_chunk.RegProgram, method_name: []const u8) ?u16 {
    for (program.trait_defaults.items) |d| {
        if (std.mem.eql(u8, d.method_name, method_name)) return d.func_idx;
    }
    return null;
}
