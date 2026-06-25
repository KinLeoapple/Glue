//! Glue 字节码 VM — 执行引擎（M0 骨架）
//!
//! 设计见 docs/bytecode-vm-plan.md §3/§6。M0 单帧执行（无 CALL/RETURN 跨帧），
//! 验证操作数栈 + dispatch 循环 + 算术核 + 局部变量 slot + 跳转。
//!
//! 栈所有权不变式（§6.1）：栈上每个 Value 持有一份 owned 引用。
//! 压栈即 +1（retain/retainOwned），弹栈消费即 -1（release）。
//! 局部变量住在操作数栈 slot_base + slot 处（M0 slot_base=0）。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const opcode = @import("opcode.zig");
const chunk_mod = @import("chunk.zig");
const cast = @import("cast.zig");
const method = @import("method.zig");

const OpCode = opcode.OpCode;
const Chunk = chunk_mod.Chunk;
const Function = chunk_mod.Function;
const Program = chunk_mod.Program;
const Value = value.Value;
const IntValue = value.IntValue;
const FloatValue = value.FloatValue;
const SpawnHandle = value.SpawnHandle;

/// M4c：spawn 协程上下文。每个 spawn 起一个 OS 线程跑子 VM；子 VM 用 per-spawn arena
/// （page_allocator 裸打底）分配，与父 VM 内存隔离（VM 纯 refcount，array/record 非原子 rc
/// 跨线程不安全 → 必须隔离堆）。结果存 handle.result（在 arena 内），await 时父线程深拷回父 allocator。
/// 生命周期：worker 退出前置 handle.finished；VM.deinit 自旋等待后 arena.deinit + 释放 handle。
const SpawnCtx = struct {
    handle: *SpawnHandle,
    program: *const Program,
    func: *const Function, // spawn body 编译成的零参 Function（在共享 program 内）
    captures: []Value, // 捕获快照（已深拷进 arena），按 func 的 upvalue 顺序
    arena: *std.heap.ArenaAllocator, // per-spawn 堆（子 VM 全部分配走这里）
    io: ?std.Io,
    thread: ?std.Thread = null,
};

/// 子 VM 线程入口：用 arena 起独立 VM，把 captures 包成 cell upvalues，跑 func，结果存 handle。
fn spawnThreadEntry(ctx: *SpawnCtx) void {
    const handle = ctx.handle;
    defer handle.finished.store(true, .seq_cst); // 最后置位，VM.deinit 凭此安全回收
    const alloc = ctx.arena.allocator();

    // captures → cell upvalues（子 VM 帧的 upvalues 需 *Cell）。
    var ups: []Value = &.{};
    if (ctx.captures.len > 0) {
        ups = alloc.alloc(Value, ctx.captures.len) catch {
            spawnFail(handle, "out of memory in spawned task");
            return;
        };
        for (ctx.captures, 0..) |cap, i| {
            const cell = alloc.create(value.Cell) catch {
                spawnFail(handle, "out of memory in spawned task");
                return;
            };
            cell.* = .{ .inner = cap, .rc = 1 };
            ups[i] = Value{ .cell_val = cell };
        }
    }

    var child = VM.init(alloc);
    child.io = ctx.io;
    child.program = ctx.program;
    defer child.deinit();

    const result = child.callClosureBody(ctx.program, ctx.func, ups) catch {
        const msg = if (child.err_msg) |m| m else "spawned task failed";
        spawnFail(handle, msg);
        return;
    };

    handle.mutex.lock();
    handle.result = result; // 在 arena 内；await 深拷回父 allocator 后由 arena.deinit 回收
    handle.status.store(.Completed, .seq_cst);
    handle.condition.broadcast();
    handle.mutex.unlock();
}

fn spawnFail(handle: *SpawnHandle, msg: []const u8) void {
    handle.mutex.lock();
    // panic_message 用 page_allocator（独立于 arena，await 后由父释放）。
    handle.panic_message = std.heap.page_allocator.dupe(u8, msg) catch null;
    handle.status.store(.Failed, .seq_cst);
    handle.condition.broadcast();
    handle.mutex.unlock();
}

pub const VMError = error{
    OutOfMemory,
    StackUnderflow,
    TypeMismatch,
    DivisionByZero,
    ArithmeticOverflow,
    WrongArity,
    StackOverflow,
    Unsupported,
    NonNullAssertFailed,
    SpawnFailed,
};

/// 调用帧（M1a/M1b）。局部变量住操作数栈 slot_base..slot_base+slot_count-1。
/// ip 是本帧在其函数 chunk 内的指令指针。
/// func 直接存 *const Function（OP_CALL 与 OP_CALL_VALUE 两路统一）。
/// frame_base：返回时栈回退到的位置 + 结果压入处。
///   - OP_CALL（callee 不在栈上）：frame_base == slot_base。
///   - OP_CALL_VALUE（callee 在 args 下方）：frame_base == slot_base - 1，stack[frame_base] 为 callee，
///     返回时额外 release。
/// upvalues：闭包捕获值（M1b-1 恒空，M1b-2 填充）。
pub const CallFrame = struct {
    func: *const Function,
    ip: usize,
    slot_base: usize,
    frame_base: usize,
    upvalues: []const Value = &.{},
};

/// 调用深度上限（防爆栈 / 无限递归）。
const MAX_FRAMES: usize = 64 * 1024;

/// 字面量模式比较（OP_TEST_LIT 语义，对齐树遍历器 matchLiteralPattern）：
/// int/float 仅比值（忽略 type_tag），bool/char/string/null 按内容。类型不符即 false。
fn literalPatternEq(pat: Value, obj: Value) bool {
    return switch (pat) {
        .integer => |pv| obj == .integer and obj.integer.value == pv.value,
        .float => |pv| obj == .float and obj.float.value == pv.value,
        .boolean => |b| obj == .boolean and obj.boolean == b,
        .char_val => |c| obj == .char_val and obj.char_val == c,
        .string => |s| obj == .string and std.mem.eql(u8, obj.string, s),
        .null_val => obj.isNull(),
        else => false,
    };
}

/// M5b：运行时类型名（镜像 eval.valueTypeName，纯 value→name）。供 type() native 用。
fn vmValueTypeName(val: Value) []const u8 {
    return switch (val) {
        .integer => |iv| @tagName(iv.type_tag),
        .float => |fv| @tagName(fv.type_tag),
        .boolean => "bool",
        .char_val => "char",
        .string => "str",
        .null_val => "null",
        .unit => "unit",
        .array => "array",
        .record => "record",
        .adt => |av| av.type_name,
        .newtype => |nv| nv.type_name,
        .range => "range",
        .error_val => |e| e.type_name,
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
        .trait_value => |tv| if (tv.trait_name.len > 0) tv.trait_name else "trait",
        .lazy_val => "Lazy",
        .cell_val => |c| vmValueTypeName(c.inner),
        .builtin, .vm_closure => "function",
    };
}

/// M5i：数值类型名（i8/u32/f64 等）。impl 数值宽度互通用。
fn implIsNumericTypeName(name: []const u8) bool {
    const nums = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "f16", "f32", "f64", "f128",
    };
    for (nums) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// M5i：两个数值类型名是否同类（都整数或都浮点）。镜像 eval numericKindMatches。
fn implNumericKindMatches(a: []const u8, b: []const u8) bool {
    const a_float = a.len > 0 and a[0] == 'f';
    const b_float = b.len > 0 and b[0] == 'f';
    return a_float == b_float;
}

/// M5i：receiver 类型名是否匹配 impl 目标类型名。精确匹配，或数值同类宽度互通
/// （字面量推断最小类型 5→i8，用户惯写 impl<i32>，故放宽，镜像 eval callMethod）。
fn implTypeMatches(recv: []const u8, impl_ty: []const u8) bool {
    if (impl_ty.len == 0) return true; // 未指定类型：按方法名匹配（向后兼容）
    if (std.mem.eql(u8, recv, impl_ty)) return true;
    return implIsNumericTypeName(recv) and implIsNumericTypeName(impl_ty) and implNumericKindMatches(recv, impl_ty);
}

/// M5i：在 program.impl_methods 查 (receiver 类型, 方法名) 对应的方法 func_idx。
fn findImplMethod(program: *const Program, recv_type: []const u8, method_name: []const u8) ?u16 {
    for (program.impl_methods.items) |d| {
        if (std.mem.eql(u8, d.method_name, method_name) and implTypeMatches(recv_type, d.type_name)) return d.func_idx;
    }
    return null;
}

/// M5i：在 program.trait_defaults 查方法名对应的默认方法 func_idx（impl 未覆写时回退）。
fn findTraitDefault(program: *const Program, method_name: []const u8) ?u16 {
    for (program.trait_defaults.items) |d| {
        if (std.mem.eql(u8, d.method_name, method_name)) return d.func_idx;
    }
    return null;
}

/// M5n：接收者类型 recv_type 是否对组合 Trait trait_name 的**所有**父 Trait 都有 impl
/// （镜像 eval hasAllParentImpls）。组合分派仅在父 impl 齐备时生效。
fn hasAllParentImpls(program: *const Program, trait_name: []const u8, recv_type: []const u8) bool {
    var any_parent = false;
    for (program.trait_parents.items) |tp| {
        if (!std.mem.eql(u8, tp.trait_name, trait_name)) continue;
        any_parent = true;
        var found = false;
        for (program.impl_methods.items) |im| {
            if (std.mem.eql(u8, im.trait_name, tp.parent_name) and implTypeMatches(recv_type, im.type_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return any_parent;
}

/// M5n：在组合 Trait trait_name 内查方法 m 的消解描述（override/委托）。
fn findTraitResolve(program: *const Program, trait_name: []const u8, m: []const u8) ?chunk_mod.TraitResolveDesc {
    for (program.trait_resolves.items) |r| {
        if (std.mem.eql(u8, r.trait_name, trait_name) and std.mem.eql(u8, r.method_name, m)) return r;
    }
    return null;
}

/// M5n：查委托目标 (trait, method) 对应接收者类型 recv_type 的父 impl func_idx。
fn findImplMethodByTrait(program: *const Program, recv_type: []const u8, trait_name: []const u8, m: []const u8) ?u16 {
    for (program.impl_methods.items) |im| {
        if (std.mem.eql(u8, im.trait_name, trait_name) and std.mem.eql(u8, im.method_name, m) and
            implTypeMatches(recv_type, im.type_name)) return im.func_idx;
    }
    return null;
}

/// M5n：组合 Trait 分派（文档 §2.7.2）。按定义顺序遍历组合 Trait，对接收者类型父 impl 齐备的
/// 组合 Trait，若其消解了 m（override/委托），记为候选；**后定义的覆盖先定义的**（镜像 eval
/// trait_definition_order 遍历 + best_result 后写覆盖）。返回最终命中的 func_idx（override 体或委托
/// 目标父 impl），无命中返回 null（落回扁平 impl 查找）。
fn resolveComposedMethod(program: *const Program, recv_type: []const u8, m: []const u8) ?u16 {
    var best: ?u16 = null;
    for (program.trait_order.items) |trait_name| {
        if (!hasAllParentImpls(program, trait_name, recv_type)) continue;
        const r = findTraitResolve(program, trait_name, m) orelse continue;
        if (r.override_func) |fidx| {
            best = fidx; // override：调用 override 方法体
        } else if (r.delegate_trait) |dt| {
            // 委托：实现来自父 impl (delegate_trait, delegate_method)，按接收者类型查。
            if (findImplMethodByTrait(program, recv_type, dt, r.delegate_method.?)) |fidx| best = fidx;
        }
    }
    return best;
}

/// M5d：结构相等（深比较 array/record/adt/newtype），镜像 eval structuralEquals。供 eq() native 用。
fn vmStructuralEquals(a: Value, b: Value) bool {
    const at = std.meta.activeTag(a);
    const bt = std.meta.activeTag(b);
    if (at != bt) return false;
    return switch (a) {
        .integer => |iv| iv.value == b.integer.value,
        .float => |fv| fv.value == b.float.value and fv.type_tag == b.float.type_tag,
        .boolean => |bo| bo == b.boolean,
        .char_val => |c| c == b.char_val,
        .string => |s| std.mem.eql(u8, s, b.string),
        .null_val => true,
        .unit => true,
        .range => |r| r.start == b.range.start and r.end == b.range.end and r.inclusive == b.range.inclusive,
        .array => |arr| {
            if (arr.elements.len != b.array.elements.len) return false;
            for (arr.elements, b.array.elements) |x, y| {
                if (!vmStructuralEquals(x, y)) return false;
            }
            return true;
        },
        .record => |rec| {
            var it = rec.fields.iterator();
            while (it.next()) |e| {
                const bv = b.record.fields.get(e.key_ptr.*) orelse return false;
                if (!vmStructuralEquals(e.value_ptr.*, bv)) return false;
            }
            var bit = b.record.fields.iterator();
            while (bit.next()) |e| {
                if (rec.fields.get(e.key_ptr.*) == null) return false;
            }
            return true;
        },
        .adt => |av| {
            if (!std.mem.eql(u8, av.type_name, b.adt.type_name)) return false;
            if (!std.mem.eql(u8, av.constructor, b.adt.constructor)) return false;
            if (av.fields.len != b.adt.fields.len) return false;
            for (av.fields, b.adt.fields) |fa, fb| {
                if (!vmStructuralEquals(fa.value, fb.value)) return false;
            }
            return true;
        },
        .newtype => |nv| std.mem.eql(u8, nv.type_name, b.newtype.type_name) and vmStructuralEquals(nv.inner, b.newtype.inner),
        .error_val => |e| std.mem.eql(u8, e.type_name, b.error_val.type_name) and std.mem.eql(u8, e.message, b.error_val.message),
        // 其余（闭包/原语/迭代器等）引用相等。
        else => a.equals(b),
    };
}

/// M5d：scan/scanln 的持久 stdin reader 状态（镜像 eval StdinState）。
const StdinState = struct {
    buffer: [8192]u8 = undefined,
    reader: std.Io.File.Reader,
};

pub const VM = struct {
    /// 操作数栈：局部变量也住这里（slot_base + slot 索引）。
    stack: std.ArrayListUnmanaged(Value) = .empty,
    /// 调用帧栈（堆上，不吃 Zig 原生栈 → 深递归不爆 Zig 栈）。
    frames: std.ArrayListUnmanaged(CallFrame) = .empty,
    /// 值分配器（与求值器 value_allocator 同源，refcount 字节走这里）。
    allocator: std.mem.Allocator,
    /// 运行期错误位置（panic 报告用）。
    err_loc: ast.SourceLocation = .{ .line = 0, .column = 0 },
    err_msg: ?[]const u8 = null,
    /// IO 句柄（原生 println/print 输出到 stdout）；null 时回退 std.debug.print。
    io: ?std.Io = null,
    /// M4c：本 VM spawn 出的协程上下文（每个含 OS 线程 + per-spawn arena + handle）。
    /// VM.deinit 时自旋等待各 worker finished，再释放 arena/handle —— 避免 detached 线程写已释放内存。
    spawns: std.ArrayListUnmanaged(*SpawnCtx) = .empty,
    /// 当前 program（OP_SPAWN 需把 program 指针传给子 VM —— functions/constants 不可变跨线程共享）。
    program: ?*const Program = null,
    /// M4d：嵌套运行停止深度。runLoop 在 frames 弹回此深度时返回（默认 0 = 入口帧）。
    /// force lazy thunk 时临时抬高，使 thunk RETURN 在其帧弹出即返回，不continue 外层。
    stop_depth: usize = 0,
    /// M5d：scan/scanln 的 stdin 行缓冲 + 持久 reader（镜像 eval scan_line_buf/scan_line_pos/stdin_state）。
    scan_line_buf: std.ArrayListUnmanaged(u8) = .empty,
    scan_line_pos: usize = 0,
    stdin_state: ?*StdinState = null,
    /// M5g：顶层全局变量槽（OP_GET_GLOBAL/OP_SET_GLOBAL <idx> 索引）。call 时按 program.global_count
    /// 分配并以 unit 初始化；deinit 时 release 各槽。
    globals: std.ArrayListUnmanaged(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) VM {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *VM) void {
        // M4c：等待所有 spawn worker 彻底结束（join 线程），再释放 arena/handle/ctx。
        // join 保证 worker 不再触碰 handle/arena —— 无 use-after-free。
        for (self.spawns.items) |ctx| {
            if (ctx.thread) |t| t.join();
            // 平衡 deepCopyAcross 给捕获的共享原语（atomic/channel）加的 ref。子 VM 的 upvalue cell
            // 是 arena 分配（arena.deinit 回收内存），但 cell.inner 持的共享对象（父 allocator 所有）
            // ref_count 不会随 arena 释放而递减 → 须显式 unref。标量/字符串是 arena 自有，无需处理。
            for (ctx.captures) |cap| self.releaseCapture(cap);
            if (ctx.handle.panic_message) |msg| std.heap.page_allocator.free(msg);
            self.allocator.destroy(ctx.handle);
            ctx.arena.deinit(); // 释放子 VM 全部分配（含 result、cell、sender/receiver 包装）
            self.allocator.destroy(ctx.arena);
            self.allocator.destroy(ctx);
        }
        self.spawns.deinit(self.allocator);
        // 退出时栈上残留值 release（正常执行后栈应为空或仅留结果）。
        for (self.stack.items) |v| v.releaseVM(self.allocator);
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        // M5d：释放 scan 行缓冲 + stdin reader 状态。
        self.scan_line_buf.deinit(self.allocator);
        if (self.stdin_state) |state| self.allocator.destroy(state);
        // M5g：release 全局变量槽。
        for (self.globals.items) |v| v.releaseVM(self.allocator);
        self.globals.deinit(self.allocator);
    }

    /// M4d：从 channel/sender/receiver 值取底层 *ChannelValue（select arm 用）。其它类型返回 null。
    fn channelOf(self: *VM, v: Value) ?*value.ChannelValue {
        _ = self;
        return switch (v) {
            .channel_val => |cv| cv,
            .sender_val => |sv| sv.channel,
            .receiver_val => |rv| rv.channel,
            else => null,
        };
    }

    /// M4d：建 vm_owned trait 值。栈顶 count 个 [name(string), closure] 对（顺序压栈 → 逆序弹）。
    /// vtable: name(dupe) -> vm_closure（接管所有权）。data=null（内联 trait 无 receiver）。
    fn doMakeTrait(self: *VM, count: u8, loc: ast.SourceLocation) VMError!void {
        const tv = self.allocator.create(value.TraitValue) catch return error.OutOfMemory;
        var methods = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var it = methods.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.*.releaseVM(self.allocator);
            }
            methods.deinit();
            self.allocator.destroy(tv);
        }
        // 逆序弹：栈顶是最后一对的 closure。每对 [name, closure] → 先弹 closure 再弹 name。
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const closure = self.pop();
            const name_v = self.pop();
            if (name_v != .string) {
                closure.releaseVM(self.allocator);
                name_v.releaseVM(self.allocator);
                return self.fail(loc, "trait method name must be a string", error.TypeMismatch);
            }
            // name_v.string 是 retainOwned 出的 owned 副本 —— 直接作为 key（移交），不再 dupe。
            const gop = methods.getOrPut(name_v.string) catch return error.OutOfMemory;
            if (gop.found_existing) {
                // 重名（override）：释放旧实现与重复 key 字节，覆盖。
                gop.value_ptr.*.releaseVM(self.allocator);
                self.allocator.free(name_v.string);
            } else {
                gop.key_ptr.* = name_v.string;
            }
            gop.value_ptr.* = closure;
        }
        tv.* = .{
            .trait_name = "",
            .methods = methods,
            .data = null,
            .allocator = self.allocator,
            .vm_owned = true,
            .rc = 1,
        };
        try self.push(Value{ .trait_value = tv });
    }

    /// M4c：平衡 spawn 捕获快照对共享原语加的 ref。仅处理内建原子 ref_count 的类型：
    /// atomic/channel unref 归零则 deinit+destroy（父 allocator 所有）；sender/receiver 仅 unref 其
    /// channel（包装本身是子 arena 所有，由 arena.deinit 回收，绝不在此 destroy）。其它（标量/字符串/
    /// 数组/record）是子 arena 自有，arena.deinit 统一回收，此处不碰。
    fn releaseCapture(self: *VM, cap: Value) void {
        switch (cap) {
            .atomic_val => |av| {
                if (av.unref()) self.allocator.destroy(av);
            },
            .channel_val => |ch| {
                if (ch.unref()) {
                    ch.deinit();
                    self.allocator.destroy(ch);
                }
            },
            .sender_val => |sv| {
                if (sv.channel.unref()) {
                    sv.channel.deinit();
                    self.allocator.destroy(sv.channel);
                }
            },
            .receiver_val => |rv| {
                if (rv.channel.unref()) {
                    rv.channel.deinit();
                    self.allocator.destroy(rv.channel);
                }
            },
            else => {},
        }
    }

    fn push(self: *VM, v: Value) VMError!void {
        try self.stack.append(self.allocator, v);
    }

    fn pop(self: *VM) Value {
        return self.stack.pop().?;
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    /// string 须 dupe 独立 owned（retain 对 string 是 no-op，见 §6.3）。
    fn retainOwned(self: *VM, v: Value) VMError!Value {
        if (v == .string) return Value{ .string = try self.allocator.dupe(u8, v.string) };
        // M4a：atomic_val 共享语义 —— 原子 ref_count +1，返回别名（与 releaseVM unref 平衡）。
        if (v == .atomic_val) {
            v.atomic_val.ref();
            return v;
        }
        // M4b：channel_val 共享语义 —— ref +1 返回别名。
        if (v == .channel_val) {
            v.channel_val.ref();
            return v;
        }
        // M4d：VM 模式 lazy —— rc+1 共享 thunk/缓存（与 releaseVM 平衡）。eval 模式（vm_thunk==null）no-op。
        if (v == .lazy_val and v.lazy_val.vm_thunk != null) {
            v.lazy_val.rc += 1;
            return v;
        }
        // M4d：VM 模式 trait 值 —— rc+1 共享 vtable（与 releaseVM 平衡）。eval 模式（vm_owned==false）no-op。
        if (v == .trait_value and v.trait_value.vm_owned) {
            v.trait_value.rc += 1;
            return v;
        }
        // M4b：sender/receiver 轻包装 —— ref channel + 新分配包装（与 releaseVM destroy 包装平衡）。
        if (v == .sender_val) {
            v.sender_val.channel.ref();
            const sv = self.allocator.create(value.SenderValue) catch return error.OutOfMemory;
            sv.* = .{ .channel = v.sender_val.channel };
            return Value{ .sender_val = sv };
        }
        if (v == .receiver_val) {
            v.receiver_val.channel.ref();
            const rv = self.allocator.create(value.ReceiverValue) catch return error.OutOfMemory;
            rv.* = .{ .channel = v.receiver_val.channel };
            return Value{ .receiver_val = rv };
        }
        // M3c：throw_val/error_val 在 eval 走 GC（retain 为 no-op）；VM 纯 refcount 用值语义——
        // 深拷壳 + 错误字符串，嵌套值仍走 retainOwned（rc+1，与 releaseVM 平衡）。
        if (v == .error_val) return Value{ .error_val = .{
            .type_name = try self.allocator.dupe(u8, v.error_val.type_name),
            .message = try self.allocator.dupe(u8, v.error_val.message),
            .is_error_subtype = v.error_val.is_error_subtype,
        } };
        if (v == .throw_val) {
            const new_tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
            switch (v.throw_val.*) {
                .ok => |inner| {
                    const cloned = self.allocator.create(Value) catch return error.OutOfMemory;
                    cloned.* = try self.retainOwned(inner.*);
                    new_tv.* = .{ .ok = cloned };
                },
                .err => |e| new_tv.* = .{ .err = .{
                    .type_name = try self.allocator.dupe(u8, e.type_name),
                    .message = try self.allocator.dupe(u8, e.message),
                    .is_error_subtype = e.is_error_subtype,
                } },
            }
            return Value{ .throw_val = new_tv };
        }
        return v.retain();
    }

    fn fail(self: *VM, loc: ast.SourceLocation, msg: []const u8, e: VMError) VMError {
        self.err_loc = loc;
        self.err_msg = msg;
        return e;
    }

    /// 执行 program 中索引为 entry 的函数，args 为实参（owned，所有权移交给 VM）。
    /// 返回该函数的返回值（owned，调用方负责 release）。
    /// M1a：跨帧 CALL/RETURN，callee 用 func_idx 立即数（无一等函数值）。
    pub fn call(self: *VM, program: *const Program, entry: u16, args: []const Value) VMError!Value {
        self.program = program; // M4c：OP_SPAWN 需 program 指针传子 VM。
        // M5g：预留全局槽（unit 占位），运行全局初始化函数（顶层 val/var 的 RHS）。
        if (self.globals.items.len < program.global_count) {
            const need = program.global_count - self.globals.items.len;
            var k: usize = 0;
            while (k < need) : (k += 1) try self.globals.append(self.allocator, Value.unit);
        }
        if (program.globals_init) |init_idx| {
            const init_result = try self.callNoArgs(program, init_idx);
            init_result.releaseVM(self.allocator); // 初始化函数返回 unit，丢弃
        }
        const f = &program.functions.items[entry];
        if (args.len != f.arity) return self.fail(.{ .line = 0, .column = 0 }, "wrong number of arguments", error.WrongArity);
        // 建立入口帧：实参占 slot 0..arity-1，其余局部槽补 unit 占位。
        const slot_base = self.stack.items.len;
        for (args) |a| try self.push(a); // 所有权移交栈（slot）
        var s: u16 = f.arity;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = slot_base, .frame_base = slot_base });
        return self.runLoop(program);
    }

    /// M5g：运行一个零参顶层函数到完成，返回其 owned 结果（用 stop_depth 边界使其 RETURN 即返回）。
    fn callNoArgs(self: *VM, program: *const Program, func_idx: u16) VMError!Value {
        const f = &program.functions.items[func_idx];
        const saved_depth = self.stop_depth;
        const base = self.stack.items.len;
        var s: u16 = 0;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = base, .frame_base = base });
        self.stop_depth = self.frames.items.len - 1;
        const result = self.runLoop(program) catch |e| {
            self.stop_depth = saved_depth;
            return e;
        };
        self.stop_depth = saved_depth;
        return result;
    }

    /// M4c：执行 spawn body —— 零参 Function + 给定 upvalues（cell）。建入口帧（带 upvalues）跑到 RETURN。
    fn callClosureBody(self: *VM, program: *const Program, f: *const Function, upvalues: []const Value) VMError!Value {
        self.program = program;
        const slot_base = self.stack.items.len;
        var s: u16 = 0;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = slot_base, .frame_base = slot_base, .upvalues = upvalues });
        return self.runLoop(program);
    }

    /// M4d：force VM 模式 lazy。已 forced → 返回缓存的 owned 副本；否则跑 thunk（零参闭包）到完成，
    /// 缓存结果。用 stop_depth 边界：临时设为当前帧深度，thunk 帧 RETURN 即返回（不 continue 外层 dispatch）。
    /// thunk 内的嵌套调用压更深帧，其 RETURN 深度 > stop_depth → 不误触发返回，语义正确。
    fn forceLazyVM(self: *VM, lz: *value.LazyValue, loc: ast.SourceLocation) VMError!Value {
        if (lz.forced) return try self.retainOwned(lz.cached.?);
        const thunk: *value.VmClosure = @ptrCast(@alignCast(lz.vm_thunk.?));
        const f: *const Function = @ptrCast(@alignCast(thunk.func));
        // 建 thunk 入口帧（零参 + upvalues），边界设当前深度。
        const saved_depth = self.stop_depth;
        const base = self.stack.items.len;
        var s: u16 = 0;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = base, .frame_base = base, .upvalues = thunk.upvalues });
        self.stop_depth = self.frames.items.len - 1; // thunk 帧弹出即停
        const result = self.runLoop(self.program.?) catch |e| {
            self.stop_depth = saved_depth;
            return e;
        };
        self.stop_depth = saved_depth;
        _ = loc;
        // result 既缓存（thunk 持有）又返回 owned 副本。
        lz.cached = result;
        lz.forced = true;
        return try self.retainOwned(result);
    }

    /// 主 dispatch 循环。从当前帧（frames 顶）取码执行，CALL 压帧、RETURN 弹帧。
    /// 当入口帧 RETURN（frames 清空）时返回其结果。
    fn runLoop(self: *VM, program: *const Program) VMError!Value {
        while (true) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const func = frame.func;
            const code = func.chunk.code.items;
            const op: OpCode = @enumFromInt(code[frame.ip]);
            const loc = func.chunk.lines.items[frame.ip];
            frame.ip += 1;
            switch (op) {
                .op_const => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.push(try self.retainOwned(func.chunk.constants.items[idx]));
                },
                .op_null => try self.push(Value.null_val),
                .op_unit => try self.push(Value.unit),
                .op_true => try self.push(Value{ .boolean = true }),
                .op_false => try self.push(Value{ .boolean = false }),

                .op_get_local => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cur = self.stack.items[frame.slot_base + slot];
                    // 透明解 cell：被闭包捕获的 local 已就地 box 成 *Cell，读其 inner。
                    const v = if (cur == .cell_val) cur.cell_val.inner else cur;
                    // M4a：Atomic<T> 透明读取 —— 一般读取 load 出当前标量（方法接收者走 OP_GET_LOCAL_RAW）。
                    if (v == .atomic_val) {
                        try self.push(v.atomic_val.load());
                    } else if (v == .lazy_val and v.lazy_val.vm_thunk != null) {
                        // M4d：Lazy<T> 透明读取 —— 首次 force 跑 thunk 缓存，返回缓存的 owned 副本。
                        try self.push(try self.forceLazyVM(v.lazy_val, loc));
                    } else {
                        try self.push(try self.retainOwned(v));
                    }
                },
                .op_set_local => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const dst = frame.slot_base + slot;
                    const cur = self.stack.items[dst];
                    // M5m：绑定语义（val/var/match/temp/循环变量）——总是纯覆写，建立**新**绑定。
                    // 不写穿残留 cell：上一轮循环若有闭包捕获了该 slot，op_closure 已就地 box 成 cell
                    // 并 retain（rc=2：slot+闭包）；此处 release slot 那一份（rc→1，逃逸闭包仍持旧值，
                    // 语义冻结），新值落槽。下一轮捕获再 box 成**新** cell → 每轮闭包各捕获独立 cell，
                    // 镜像 eval 每轮 fresh scope。早期写穿 cell.inner 致所有闭包共享一格（edge_closures
                    // 循环捕获印 3,3,3 而非 1,2,3）。assignment 走 op_set_local_assign（保留写穿+atomic）。
                    cur.releaseVM(self.allocator);
                    self.stack.items[dst] = v;
                },
                // M5m：assignment-to-local（非绑定）。镜像 eval env.set：slot/cell 持 Atomic<T> 时
                // 透明 atomic store（保持共享 atomic 身份，写对捕获该原子的 spawn 可见），不重写 inner。
                // 与 op_set_local 的区别：op_set_local 用于绑定（val/var/match/temp，slot 复用须纯覆写，
                // 否则栈复用残留的 atomic 会被误 store-through——见 edge_concurrency_race 的 $idx 槽复用崩溃）。
                .op_set_local_assign => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const dst = frame.slot_base + slot;
                    const cur = self.stack.items[dst];
                    if (cur == .cell_val) {
                        if (cur.cell_val.inner == .atomic_val) {
                            cur.cell_val.inner.atomic_val.store(v);
                            v.releaseVM(self.allocator); // 标量，no-op
                        } else {
                            cur.cell_val.inner.releaseVM(self.allocator);
                            cur.cell_val.inner = v;
                        }
                    } else if (cur == .atomic_val) {
                        cur.atomic_val.store(v);
                        v.releaseVM(self.allocator); // 标量，no-op
                    } else {
                        cur.releaseVM(self.allocator);
                        self.stack.items[dst] = v;
                    }
                },
                // M5c：letrec 自绑定。写闭包进 slot 的 cell.inner；若闭包捕获了该 cell（自引用），
                // 对 cell 少持一份 ref，断开 cell↔closure 循环（镜像 eval 弱自引用）。
                .op_set_local_letrec => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const dst = frame.slot_base + slot;
                    const cur = self.stack.items[dst];
                    // letrec 路径保证 slot 已 box 成 cell（先 op_unit + op_set_local 占位）。
                    if (cur == .cell_val) {
                        const cell = cur.cell_val;
                        cell.inner.releaseVM(self.allocator); // 释放占位 unit
                        cell.inner = v; // cell 持有闭包（强）
                        // 断环：闭包的 upvalue 若指向本 cell（递归自捕获），op_closure 已 retain 过
                        // 该 cell（rc+1）。标记该 upvalue 为弱（self_upvalue_idx），并 cell.rc-=1
                        // 抵消 op_closure 的 retain。此后 cell↔closure 无循环计数：cell 归零释放
                        // closure，closure 释放时跳过弱自引用（不反向释放 cell）。
                        if (v == .vm_closure) {
                            const vc = v.vm_closure;
                            for (vc.upvalues, 0..) |uv, i| {
                                if (uv == .cell_val and uv.cell_val == cell) {
                                    vc.self_upvalue_idx = @intCast(i);
                                    cell.rc -= 1;
                                    break;
                                }
                            }
                        }
                    } else {
                        cur.releaseVM(self.allocator);
                        self.stack.items[dst] = v;
                    }
                },
                .op_get_upvalue => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cell = frame.upvalues[idx].cell_val;
                    // M4a：Atomic<T> 透明读取（方法接收者走 OP_GET_UPVALUE_RAW）。
                    if (cell.inner == .atomic_val) {
                        try self.push(cell.inner.atomic_val.load());
                    } else if (cell.inner == .lazy_val and cell.inner.lazy_val.vm_thunk != null) {
                        try self.push(try self.forceLazyVM(cell.inner.lazy_val, loc));
                    } else {
                        try self.push(try self.retainOwned(cell.inner));
                    }
                },
                .op_set_upvalue => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop();
                    const cell = frame.upvalues[idx].cell_val;
                    // M5m：cell 持 Atomic<T> → 透明 atomic store（保持共享 atomic 身份，写对父/兄弟
                    // 协程可见），不重写 inner。镜像 eval env.set 的 atomic_val 分支（env.zig:231）。
                    // 早期直接 inner=v 把共享 atomic 覆写成子线程本地标量 → 累加丢失（edge_concurrency/phase4）。
                    if (cell.inner == .atomic_val) {
                        cell.inner.atomic_val.store(v);
                        v.releaseVM(self.allocator); // v 是标量（atomic 只存原始位），release 即 no-op
                    } else {
                        cell.inner.releaseVM(self.allocator);
                        cell.inner = v;
                    }
                },

                .op_add, .op_sub, .op_mul, .op_div, .op_mod, .op_bit_and, .op_bit_or, .op_bit_xor => {
                    const right = self.pop();
                    const left = self.pop();
                    defer left.releaseVM(self.allocator);
                    defer right.releaseVM(self.allocator);
                    try self.push(try self.arith(op, left, right, loc));
                },
                .op_eq, .op_neq, .op_lt, .op_gt, .op_le, .op_ge => {
                    const right = self.pop();
                    const left = self.pop();
                    defer left.releaseVM(self.allocator);
                    defer right.releaseVM(self.allocator);
                    try self.push(try self.compare(op, left, right, loc));
                },
                .op_neg => {
                    const v = self.pop();
                    defer v.releaseVM(self.allocator);
                    try self.push(try self.negate(v, loc));
                },
                .op_not => {
                    const v = self.pop();
                    defer v.releaseVM(self.allocator);
                    const b = v.asBoolean() catch return self.fail(loc, "'!' requires boolean operand", error.TypeMismatch);
                    try self.push(Value{ .boolean = !b });
                },

                .op_jump => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                .op_jump_if_false => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    const cond = self.peek(0).asBoolean() catch return self.fail(loc, "condition must be boolean", error.TypeMismatch);
                    if (!cond) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                .op_jump_if_true => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    const cond = self.peek(0).asBoolean() catch return self.fail(loc, "condition must be boolean", error.TypeMismatch);
                    if (cond) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                // M3c：`??` 短路 —— peek 栈顶非 null 则跳转（保留 left）。
                .op_jump_if_not_null => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    if (!self.peek(0).isNull()) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },
                .op_jump_if_null => {
                    const off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    if (self.peek(0).isNull()) frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + off);
                },

                .op_pop => self.pop().releaseVM(self.allocator),
                .op_pop_n => {
                    const n = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    var k: u16 = 0;
                    while (k < n) : (k += 1) self.pop().releaseVM(self.allocator);
                },
                .op_dup => try self.push(try self.retainOwned(self.peek(0))),

                .op_call => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doCall(program, func_idx, argc, loc);
                    // doCall 压入新帧；下轮循环自然切换到 callee（frame 指针失效，循环顶部重取）。
                },

                .op_tail_call => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doTailCall(program, func_idx, argc, loc);
                    // 复用当前帧（不增 frames）；下轮循环顶部重取 frame（已就地改写）。
                },

                .op_closure => {
                    const func_idx = opcode.readU16(code, frame.ip);
                    const n = code[frame.ip + 2];
                    frame.ip += 3;
                    const f = &program.functions.items[func_idx];
                    const ups: []Value = if (n > 0) try self.allocator.alloc(Value, n) else &.{};
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        const is_local = code[frame.ip] == 1;
                        const index = opcode.readU16(code, frame.ip + 1);
                        frame.ip += 3;
                        if (is_local) {
                            // 捕获 enclosing(当前)帧的 local[index]：就地 box 成 *Cell（若尚非 cell），
                            // 闭包与帧共享同一 cell（mutation 双向可见，cell rc 独立于帧 → 逃逸存活）。
                            const dst = frame.slot_base + index;
                            const cur = self.stack.items[dst];
                            if (cur != .cell_val) {
                                const cell = try self.allocator.create(value.Cell);
                                cell.* = .{ .inner = cur, .rc = 1 }; // 接管 slot 原 owned 值
                                self.stack.items[dst] = Value{ .cell_val = cell };
                            }
                            ups[k] = (Value{ .cell_val = self.stack.items[dst].cell_val }).retain();
                        } else {
                            // 捕获 enclosing 闭包的 upvalue[index]：共享同一 cell。
                            ups[k] = (Value{ .cell_val = frame.upvalues[index].cell_val }).retain();
                        }
                    }
                    const vc = try self.allocator.create(value.VmClosure);
                    vc.* = .{ .func = f, .arity = f.arity, .upvalues = ups, .rc = 1, .allocator = self.allocator };
                    try self.push(Value{ .vm_closure = vc });
                },

                .op_call_value => {
                    const argc = code[frame.ip];
                    frame.ip += 1;
                    try self.doCallValue(argc, loc);
                    // 足参→压新帧（下轮切换）；不足→partial 已压栈，继续本帧。
                },

                .op_call_native => {
                    const nid = code[frame.ip];
                    const argc = code[frame.ip + 1];
                    frame.ip += 2;
                    try self.doCallNative(@enumFromInt(nid), argc, loc);
                },

                // M2a：复合值 / 模式匹配。
                .op_make_adt => {
                    const ctor_idx = opcode.readU16(code, frame.ip);
                    const argc = code[frame.ip + 2];
                    frame.ip += 3;
                    try self.doMakeAdt(program, ctor_idx, argc, loc);
                },
                .op_get_field => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const field = func.chunk.constants.items[name_idx].string;
                    try self.doGetField(field, loc);
                },
                .op_get_adt_field => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    if (obj != .adt or idx >= obj.adt.fields.len)
                        return self.fail(loc, "OP_GET_ADT_FIELD on non-adt or out-of-range", error.TypeMismatch);
                    try self.push(try self.retainOwned(obj.adt.fields[idx].value));
                },
                .op_test_ctor => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const want = func.chunk.constants.items[name_idx].string;
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    const matched = obj == .adt and std.mem.eql(u8, obj.adt.constructor, want);
                    try self.push(Value{ .boolean = matched });
                },
                .op_match_fail => return self.fail(loc, "match: no arm matched", error.TypeMismatch),

                // M2b：数组 / 记录字面量 / 索引。
                .op_make_array => {
                    const n = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const elems = self.allocator.alloc(Value, n) catch return error.OutOfMemory;
                    const base = self.stack.items.len - n;
                    @memcpy(elems, self.stack.items[base..][0..n]); // 接管 owned
                    self.stack.shrinkRetainingCapacity(base);
                    const arr = value.Value.makeArray(self.allocator, elems, null) catch return error.OutOfMemory;
                    try self.push(arr);
                },
                // M5：数组拼接 `++` —— 弹 [left,right] 数组，拼新数组（元素各 retainOwned），压结果。
                .op_concat_list => {
                    const right = self.pop();
                    defer right.releaseVM(self.allocator);
                    const left = self.pop();
                    defer left.releaseVM(self.allocator);
                    if (left != .array or right != .array) {
                        return self.fail(loc, "operator '++' requires array operands", error.TypeMismatch);
                    }
                    const la = left.array.elements;
                    const ra = right.array.elements;
                    const elems = self.allocator.alloc(Value, la.len + ra.len) catch return error.OutOfMemory;
                    for (la, 0..) |e, i| elems[i] = try self.retainOwned(e);
                    for (ra, 0..) |e, i| elems[la.len + i] = try self.retainOwned(e);
                    const arr = value.Value.makeArray(self.allocator, elems, null) catch return error.OutOfMemory;
                    try self.push(arr);
                },
                .op_make_record => {
                    const shape_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.doMakeRecord(program, shape_idx);
                },
                .op_index => {
                    const index_val = self.pop();
                    defer index_val.releaseVM(self.allocator);
                    const object = self.pop();
                    defer object.releaseVM(self.allocator);
                    try self.doIndex(object, index_val, loc);
                },

                // M2c：全模式 match / 记录扩展 / newtype。
                .op_test_lit => {
                    const cidx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const pat = func.chunk.constants.items[cidx];
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    try self.push(Value{ .boolean = literalPatternEq(pat, obj) });
                },
                .op_record_extend => {
                    const shape_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.doRecordExtend(program, shape_idx, loc);
                },
                .op_make_newtype => {
                    const nt_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const inner = self.pop(); // 接管 owned
                    const nv = self.allocator.create(value.NewtypeValue) catch return error.OutOfMemory;
                    nv.* = .{ .type_name = program.newtype_ctors.items[nt_idx].type_name, .inner = inner, .rc = 1 };
                    try self.push(Value{ .newtype = nv });
                },
                .op_test_newtype => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const want = func.chunk.constants.items[name_idx].string;
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    const matched = obj == .newtype and std.mem.eql(u8, obj.newtype.type_name, want);
                    try self.push(Value{ .boolean = matched });
                },
                .op_get_newtype_inner => {
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    if (obj != .newtype) return self.fail(loc, "OP_GET_NEWTYPE_INNER on non-newtype", error.TypeMismatch);
                    try self.push(try self.retainOwned(obj.newtype.inner));
                },
                // M5e：自定义错误类型构造 —— 弹 str 消息，产 throw_val.err。镜像 eval error_newtype 构造器：
                //   FileError("msg") → err{type_name="FileError", message="file error: msg", is_error_subtype=true}。
                .op_make_error => {
                    const err_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const desc = program.error_ctors.items[err_idx];
                    const v = self.pop();
                    defer v.releaseVM(self.allocator);
                    if (v != .string) return self.fail(loc, "error constructor expects a str argument", error.TypeMismatch);
                    var msg: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer msg.deinit(self.allocator);
                    try msg.appendSlice(self.allocator, desc.default_prefix);
                    try msg.appendSlice(self.allocator, ": ");
                    try msg.appendSlice(self.allocator, v.string);
                    const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                    tv.* = .{ .err = .{
                        .type_name = self.allocator.dupe(u8, desc.type_name) catch return error.OutOfMemory,
                        .message = try msg.toOwnedSlice(self.allocator),
                        .is_error_subtype = true, // 文档 2.4.3: FileError <: Error
                    } };
                    try self.push(Value{ .throw_val = tv });
                },

                // M3a：字符串插值 —— 弹栈顶 n 段值，依次 format 拼接成新 string 压栈。
                .op_interp => {
                    const n = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.doInterp(n);
                },
                // M3a：类型转换 —— 弹值，按常量池目标类型名转换，压结果。
                .op_cast => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const tname = func.chunk.constants.items[name_idx].string;
                    try self.doCast(tname, loc);
                },
                // M5：隐式数值定型（best-effort）。仅 int/float 且目标 builtin 数值类型时协调，
                // 溢出/不符/非数值原样保留（不 panic）。镜像 eval `castValue catch val`。
                .op_coerce => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const tname = func.chunk.constants.items[name_idx].string;
                    self.doCoerce(tname);
                },
                // M3b：字段赋值 —— [record, val] → [new_record]（COW），写回由 SET_LOCAL 完成。
                .op_set_field => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const field = func.chunk.constants.items[name_idx].string;
                    try self.doSetField(field, loc);
                },
                // M5f：索引赋值 —— [array, index, val] → [new_array]（COW），写回由 SET_LOCAL 完成。
                .op_set_index => {
                    try self.doSetIndex(loc);
                },
                // M5g：全局读 —— retainOwned globals[idx] 压栈。
                .op_get_global => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.push(try self.retainOwned(self.globals.items[idx]));
                },
                // M5g：全局写 —— 弹 owned 值写入 globals[idx]（旧值 release）。
                .op_set_global => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const v = self.pop(); // 接管 owned
                    self.globals.items[idx].releaseVM(self.allocator);
                    self.globals.items[idx] = v;
                },

                .op_return => {
                    const result = self.pop();
                    if (try self.frameReturn(result)) |entry_result| return entry_result;
                },
                // M3c：非空断言 `!` —— peek 栈顶，null → panic，否则原样保留。
                .op_non_null => {
                    if (self.stack.items[self.stack.items.len - 1].isNull()) {
                        return self.fail(loc, "non-null assertion failed on null value", error.NonNullAssertFailed);
                    }
                },
                // M3c：传播 `?` —— null/err 提前返回，ok 解包，其它原样。
                .op_propagate => {
                    const top = self.stack.items[self.stack.items.len - 1];
                    if (top.isNull()) {
                        _ = self.pop(); // 弹 null（基础值，release 无副作用）
                        if (try self.frameReturn(Value.null_val)) |entry_result| return entry_result;
                    } else if (top == .throw_val) {
                        switch (top.throw_val.*) {
                            .ok => |inner| {
                                const unwrapped = try self.retainOwned(inner.*);
                                _ = self.pop();
                                top.releaseVM(self.allocator);
                                try self.push(unwrapped);
                            },
                            .err => {
                                const tv = self.pop(); // 接管 owned，作返回值移交
                                if (try self.frameReturn(tv)) |entry_result| return entry_result;
                            },
                        }
                    }
                    // 其它值：原样留栈顶。
                },
                // M3c：throw —— 弹 throw 值作为函数返回值（等价 OP_RETURN，Glue 无 try/catch）。
                .op_throw => {
                    const result = self.pop();
                    if (try self.frameReturn(result)) |entry_result| return entry_result;
                },
                // M3c：match Ok/Error 测试 —— 弹 throw_val，want_ok=1 测 .ok / =0 测 .err，压 bool。
                .op_test_throw => {
                    const want_ok = code[frame.ip];
                    frame.ip += 1;
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    // 镜像 eval pattern.zig：throw_val 按 ok/err 分支；非 throw_val 的裸值
                    // 视作 Ok 载荷（Ok(v) 匹配裸值绑定 v 本身），故 want_ok==1 时裸值也命中。
                    const matched = if (obj == .throw_val)
                        switch (obj.throw_val.*) {
                            .ok => want_ok == 1,
                            .err => want_ok == 0,
                        }
                    else
                        want_ok == 1;
                    try self.push(Value{ .boolean = matched });
                },
                // M3c：match Ok(v) 绑定 —— 弹 throw_val，retainOwned 其 .ok 内值压栈。
                // 裸值（非 throw_val）直接作为 Ok 载荷压回（镜像 eval matchConstructorPattern）。
                .op_get_throw_ok => {
                    const obj = self.pop();
                    if (obj != .throw_val) {
                        // 裸值即 Ok 载荷：所有权直接转回栈（不 release、不 retain）。
                        try self.push(obj);
                    } else {
                        defer obj.releaseVM(self.allocator);
                        if (obj.throw_val.* != .ok) return self.fail(loc, "OP_GET_THROW_OK on non-Ok", error.TypeMismatch);
                        try self.push(try self.retainOwned(obj.throw_val.ok.*));
                    }
                },
                // M3c：match Error(e) 绑定 —— 弹 throw_val，把 .err 包成 error_val 压栈。
                .op_get_throw_err => {
                    const obj = self.pop();
                    defer obj.releaseVM(self.allocator);
                    if (obj != .throw_val or obj.throw_val.* != .err) return self.fail(loc, "OP_GET_THROW_ERR on non-Error", error.TypeMismatch);
                    const e = obj.throw_val.err;
                    // 语言设计 §2.4.7: Error(e) 模式匹配时，e 绑定为 ErrorValue 对象
                    // 这样可以访问 e.message 字段（文档示例：Error(e) => println("error: " + e.message)）
                    const err_val = value.ErrorValue{
                        .type_name = try self.allocator.dupe(u8, e.type_name),
                        .message = try self.allocator.dupe(u8, e.message),
                        .is_error_subtype = e.is_error_subtype,
                    };
                    try self.push(Value{ .error_val = err_val });
                },
                // M3d：方法调用 —— 弹 argc 实参 + receiver，查内建方法表，压结果。
                .op_call_method => {
                    const name_idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const argc = code[frame.ip];
                    frame.ip += 1;
                    try self.doCallMethod(func, name_idx, argc, loc);
                },
                // M3d：构造 range —— 弹 [start,end]，压 range 值。
                .op_make_range => {
                    const inclusive = code[frame.ip] == 1;
                    frame.ip += 1;
                    const end_v = self.pop();
                    defer end_v.releaseVM(self.allocator);
                    const start_v = self.pop();
                    defer start_v.releaseVM(self.allocator);
                    if (start_v != .integer or end_v != .integer) return self.fail(loc, "range bounds must be integers", error.TypeMismatch);
                    const start: i128 = if (start_v.integer.type_tag.isSigned()) start_v.integer.signedValue() else @intCast(start_v.integer.value);
                    const end: i128 = if (end_v.integer.type_tag.isSigned()) end_v.integer.signedValue() else @intCast(end_v.integer.value);
                    try self.push(Value{ .range = .{ .start = start, .end = end, .inclusive = inclusive } });
                },
                // M4a：构造 atomic —— 弹值，包成 AtomicValue（ref_count=1），压 atomic_val。
                .op_make_atomic => {
                    const v = self.pop();
                    defer v.releaseVM(self.allocator);
                    const av = self.allocator.create(value.AtomicValue) catch return error.OutOfMemory;
                    switch (v) {
                        .integer => |iv| av.* = value.AtomicValue.initInt(@bitCast(iv.value), value.intTypeToAtomicType(iv.type_tag)),
                        .float => |fv| av.* = value.AtomicValue.initFloat(fv.value, switch (fv.type_tag) {
                            .f16 => .f16, .f32 => .f32, .f64 => .f64, .f128 => .f128,
                        }),
                        .boolean => |b| av.* = value.AtomicValue.initBool(b),
                        .char_val => |c| av.* = value.AtomicValue.initChar(c),
                        else => {
                            self.allocator.destroy(av);
                            return self.fail(loc, "atomic: unsupported type", error.TypeMismatch);
                        },
                    }
                    try self.push(Value{ .atomic_val = av });
                },
                // M4a：方法接收者用的原始 local 读取 —— 不对 atomic_val 透明 load（仍解 cell）。
                .op_get_local_raw => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cur = self.stack.items[frame.slot_base + slot];
                    const v = if (cur == .cell_val) cur.cell_val.inner else cur;
                    // raw 保留 atomic 引用（cas/swap 与 val 别名需要），但仍透明 force lazy
                    // （lazy 绑定语义与 eval 一致：bind 即 force；lazy 无方法，受者位置 force 亦正确）。
                    if (v == .lazy_val and v.lazy_val.vm_thunk != null) {
                        try self.push(try self.forceLazyVM(v.lazy_val, loc));
                    } else {
                        try self.push(try self.retainOwned(v));
                    }
                },
                .op_get_upvalue_raw => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const cell = frame.upvalues[idx].cell_val;
                    const v = cell.inner;
                    if (v == .lazy_val and v.lazy_val.vm_thunk != null) {
                        try self.push(try self.forceLazyVM(v.lazy_val, loc));
                    } else {
                        try self.push(try self.retainOwned(v));
                    }
                },
                // M4a：Atomic 透明复合赋值 —— slot 持 atomic → 原子 fetch<op>（不重写 slot）；否则常规读改写。
                .op_compound_local => {
                    const slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const arith_op: OpCode = @enumFromInt(code[frame.ip]);
                    frame.ip += 1;
                    try self.doCompoundLocal(frame, slot, arith_op, loc);
                },
                // M4c：Atomic 透明复合赋值（upvalue）—— cell.inner 持 atomic → 原子 fetch<op>；否则常规读改写 cell.inner。
                .op_compound_upvalue => {
                    const idx = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const arith_op: OpCode = @enumFromInt(code[frame.ip]);
                    frame.ip += 1;
                    try self.doCompoundUpvalue(frame, idx, arith_op, loc);
                },
                // M4c：spawn —— 弹零参 vm_closure（spawn body），深拷捕获进 arena，起线程跑子 VM。
                .op_spawn => {
                    try self.doSpawn(loc);
                },
                // M4d：lazy —— 弹零参 vm_closure（lazy expr），包成 lazy_val（vm_thunk 模式）压栈。
                .op_make_lazy => {
                    const callee = self.pop();
                    if (callee != .vm_closure) return self.fail(loc, "lazy body must be a closure", error.TypeMismatch);
                    const lz = self.allocator.create(value.LazyValue) catch return error.OutOfMemory;
                    lz.* = .{
                        .expr = undefined, // VM 模式占位（无 AST）
                        .env = undefined, // VM 模式占位（无 Environment）
                        .cached = null,
                        .forced = false,
                        .allocator = self.allocator,
                        .vm_thunk = @ptrCast(callee.vm_closure),
                        .rc = 1,
                    };
                    try self.push(Value{ .lazy_val = lz });
                },
                // M4d：select 支撑 —— 非阻塞 tryRecv。就绪压 [value, true]；否则压 [unit, false]。
                .op_try_recv => {
                    const chv = self.pop();
                    defer chv.releaseVM(self.allocator);
                    const ch = self.channelOf(chv) orelse return self.fail(loc, "select: not a channel", error.TypeMismatch);
                    if (ch.tryRecv()) |v| {
                        try self.push(v); // tryRecv 移交所有权
                        try self.push(Value{ .boolean = true });
                    } else {
                        try self.push(Value.unit);
                        try self.push(Value{ .boolean = false });
                    }
                },
                // M4d：select 阻塞兜底 —— 阻塞 recv。压 value（关闭则压 unit）。
                .op_recv => {
                    const chv = self.pop();
                    defer chv.releaseVM(self.allocator);
                    const ch = self.channelOf(chv) orelse return self.fail(loc, "select: not a channel", error.TypeMismatch);
                    if (ch.recv()) |v| {
                        try self.push(v);
                    } else {
                        try self.push(Value.unit);
                    }
                },
                // M4d：inline trait 值 —— 弹 count 个 [name, closure] 对建 vm_owned trait_value（vtable）。
                .op_make_trait => {
                    const count = code[frame.ip];
                    frame.ip += 1;
                    try self.doMakeTrait(count, loc);
                },
                // M3d：for 循环步进 —— iter_slot 持 array/range/string，idx_slot 持索引；
                // 耗尽跳 exit_off，否则压当前元素 + idx 自增。
                .op_for_next => {
                    const iter_slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const idx_slot = opcode.readU16(code, frame.ip);
                    frame.ip += 2;
                    const exit_off = opcode.readI32(code, frame.ip);
                    frame.ip += 4;
                    try self.doForNext(frame, iter_slot, idx_slot, exit_off, loc);
                },
            }
        }
    }

    /// 帧返回公共逻辑（OP_RETURN / OP_THROW / OP_PROPAGATE 提前返回共用）。
    /// 释放本帧局部槽 + callee box（若 OP_CALL_VALUE 帧），弹帧，把 result 移交调用方。
    /// 返回非 null：入口帧返回，结果交给 VM 调用者；返回 null：已压回调用者栈，继续主循环。
    fn frameReturn(self: *VM, result: Value) VMError!?Value {
        const frame = &self.frames.items[self.frames.items.len - 1];
        const base = frame.slot_base;
        var s: u16 = 0;
        while (s < frame.func.slot_count) : (s += 1) self.stack.items[base + s].releaseVM(self.allocator);
        const fbase = frame.frame_base;
        if (fbase < base) {
            var i = fbase;
            while (i < base) : (i += 1) self.stack.items[i].releaseVM(self.allocator);
        }
        self.stack.shrinkRetainingCapacity(fbase);
        _ = self.frames.pop();
        if (self.frames.items.len == self.stop_depth) return result; // 入口帧 / 嵌套运行边界返回
        try self.push(result); // 返回值压回调用者栈（所有权移交）
        return null;
    }

    /// 执行一次 OP_CALL（M1a 快路径）：argc 个实参已在栈顶，callee 不在栈上。
    /// argc==arity 建帧；argc<arity 产生部分应用的 vm_closure（默认柯里化）；argc>arity → WrongArity。
    fn doCall(self: *VM, program: *const Program, func_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee = &program.functions.items[func_idx];
        if (argc < callee.arity) {
            // 不足参：收集栈顶 argc 个实参为 bound_args，建部分应用 vm_closure 压栈。
            const bound = try self.allocator.alloc(Value, argc);
            const args_start = self.stack.items.len - argc;
            var i: usize = 0;
            while (i < argc) : (i += 1) bound[i] = self.stack.items[args_start + i]; // 接管 owned
            self.stack.shrinkRetainingCapacity(args_start);
            const vc = try self.allocator.create(value.VmClosure);
            vc.* = .{ .func = callee, .arity = callee.arity, .upvalues = &.{}, .bound_args = bound, .rc = 1, .allocator = self.allocator };
            try self.push(Value{ .vm_closure = vc });
            return;
        }
        if (argc > callee.arity) return self.fail(loc, "wrong number of arguments", error.WrongArity);
        if (self.frames.items.len >= MAX_FRAMES) return self.fail(loc, "stack overflow: call depth exceeded", error.StackOverflow);
        // 实参当前位于栈顶 argc 个槽，正好作为 callee 的 slot 0..arity-1（slot_base 指向它们）。
        const slot_base = self.stack.items.len - argc;
        var s: u16 = callee.arity;
        while (s < callee.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = callee, .ip = 0, .slot_base = slot_base, .frame_base = slot_base });
    }

    /// 执行 OP_TAIL_CALL：复用当前帧调用顶层 program.functions[func_idx]，不压新帧。
    /// 编译器保证仅在尾位置且 argc==callee.arity 时发射，故无柯里化/超参分支。
    /// 栈布局（调用前）：[..本帧 frame_base..局部槽.., arg0..arg_{argc-1}]，args 在栈顶。
    /// 步骤：暂存 args → 释放本帧局部槽(+callee box，若 frame_base<slot_base) → shrink 到 frame_base
    ///       → 写回 args 到 frame_base → 补 unit 到 slot_count → 就地改写帧(func,ip=0,slot_base=
    ///       frame_base,upvalues 清空)。
    fn doTailCall(self: *VM, program: *const Program, func_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee = &program.functions.items[func_idx];
        if (argc != callee.arity) return self.fail(loc, "wrong number of arguments", error.WrongArity);
        const frame = &self.frames.items[self.frames.items.len - 1];
        const fbase = frame.frame_base;
        const sbase = frame.slot_base;
        // 1) 暂存栈顶 argc 个实参（owned）到定长缓冲（argc ≤ 255）。
        var argbuf: [256]Value = undefined;
        const args_start = self.stack.items.len - argc;
        var i: usize = 0;
        while (i < argc) : (i += 1) argbuf[i] = self.stack.items[args_start + i];
        // 2) 释放本帧局部槽（slot_base..slot_base+slot_count）。args 在其上方，不在此列。
        var s: u16 = 0;
        while (s < frame.func.slot_count) : (s += 1) self.stack.items[sbase + s].releaseVM(self.allocator);
        // 3) OP_CALL_VALUE 帧：frame_base..slot_base 之间是 callee box，须 release。
        if (fbase < sbase) {
            var k = fbase;
            while (k < sbase) : (k += 1) self.stack.items[k].releaseVM(self.allocator);
        }
        // 4) 回退栈到 frame_base，写回 args（接管 owned），补 unit 到 slot_count。
        self.stack.shrinkRetainingCapacity(fbase);
        i = 0;
        while (i < argc) : (i += 1) try self.push(argbuf[i]);
        var p: u16 = callee.arity;
        while (p < callee.slot_count) : (p += 1) try self.push(Value.unit);
        // 5) 就地改写当前帧为 callee（slot_base==frame_base==fbase；callee 为顶层函数，无 upvalue）。
        frame.func = callee;
        frame.ip = 0;
        frame.slot_base = fbase;
        frame.frame_base = fbase;
        frame.upvalues = &.{};
    }

    /// 执行 OP_CALL_NATIVE：弹 argc 个实参，按 native_id 分派内建，压返回值（多数为 unit）。
    /// println/print 用 Value.format（与 eval 同一格式化路径）写 stdout。
    fn doCallNative(self: *VM, nat: opcode.Native, argc: u8, loc: ast.SourceLocation) VMError!void {
        switch (nat) {
            .println, .print => {
                if (argc != 1) return self.fail(loc, "println/print expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                v.format(&buf, self.allocator, false) catch return error.OutOfMemory;
                if (nat == .println) buf.append(self.allocator, '\n') catch {};
                if (self.io) |io| {
                    var out_buf: [4096]u8 = undefined;
                    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
                    w.interface.print("{s}", .{buf.items}) catch {};
                    w.flush() catch {};
                } else {
                    std.debug.print("{s}", .{buf.items});
                }
                try self.push(Value.unit);
            },
            // M3c：Ok(v) → throw_val.ok。inner 用 retainOwned（rc+1/字符串 dupe），与 releaseVM 平衡。
            .ok => {
                if (argc != 1) return self.fail(loc, "Ok expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                const inner = self.allocator.create(Value) catch return error.OutOfMemory;
                inner.* = try self.retainOwned(v);
                const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                tv.* = .{ .ok = inner };
                try self.push(Value{ .throw_val = tv });
            },
            // M3c：Error(msg) → throw_val.err{type_name="Error", message}（msg dupe 进 ErrorValue）。
            .err => {
                if (argc != 1) return self.fail(loc, "Error expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                if (v != .string) return self.fail(loc, "Error expects a str argument", error.TypeMismatch);
                const tv = self.allocator.create(value.ThrowValue) catch return error.OutOfMemory;
                tv.* = .{ .err = .{
                    .type_name = self.allocator.dupe(u8, "Error") catch return error.OutOfMemory,
                    .message = self.allocator.dupe(u8, v.string) catch return error.OutOfMemory,
                } };
                try self.push(Value{ .throw_val = tv });
            },
            // M4b：channel(cap) —— 弹整数容量，建 ChannelValue（ref_count=1），压 channel_val。
            .channel => {
                if (argc != 1) return self.fail(loc, "channel expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                if (v != .integer) return self.fail(loc, "channel expects an integer capacity", error.TypeMismatch);
                const cap: usize = @intCast(if (v.integer.type_tag.isSigned()) v.integer.signedValue() else @as(i128, @intCast(v.integer.value)));
                const ch = self.allocator.create(value.ChannelValue) catch return error.OutOfMemory;
                ch.* = value.ChannelValue.init(self.allocator, cap);
                try self.push(Value{ .channel_val = ch });
            },
            // M5b：type(v) —— 返回运行时类型名字符串（镜像 eval builtinTypeName/valueTypeName）。
            .type => {
                if (argc != 1) return self.fail(loc, "type expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                const name = vmValueTypeName(v);
                try self.push(Value{ .string = self.allocator.dupe(u8, name) catch return error.OutOfMemory });
            },
            // M5d：eq(a, b) —— 结构相等（深比较 array/record/adt/newtype），镜像 eval structuralEquals。
            .eq => {
                if (argc != 2) return self.fail(loc, "eq expects 2 arguments", error.WrongArity);
                const b = self.pop();
                defer b.releaseVM(self.allocator);
                const a = self.pop();
                defer a.releaseVM(self.allocator);
                try self.push(Value{ .boolean = vmStructuralEquals(a, b) });
            },
            // M5d：Panic(v) —— 格式化 v 后触发 VM panic（镜像 eval builtinPanic）。
            .panic => {
                if (argc != 1) return self.fail(loc, "Panic expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                v.format(&buf, self.allocator, false) catch {};
                // 拷进 err_msg（VM panic 报告读取）；用 allocator 持有（与 fail 一致，进程退出不回收）。
                const msg = self.allocator.dupe(u8, buf.items) catch "panic";
                return self.fail(loc, msg, error.Unsupported);
            },
            // M5d：eprintln/eprint —— 写 stderr（镜像 eval builtinEprintln/builtinEprint）。
            .eprintln, .eprint => {
                if (argc != 1) return self.fail(loc, "eprintln/eprint expects 1 argument", error.WrongArity);
                const v = self.pop();
                defer v.releaseVM(self.allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.allocator);
                v.format(&buf, self.allocator, false) catch return error.OutOfMemory;
                if (nat == .eprintln) buf.append(self.allocator, '\n') catch {};
                if (self.io) |io| {
                    var err_buf: [4096]u8 = undefined;
                    var w = std.Io.File.stderr().writerStreaming(io, &err_buf);
                    w.interface.print("{s}", .{buf.items}) catch {};
                    w.flush() catch {};
                } else {
                    std.debug.print("{s}", .{buf.items});
                }
                try self.push(Value.unit);
            },
            // M5d：scan() —— 读下一个空白分隔 token（跨行），EOF 返回 null（镜像 eval builtinScan）。
            .scan => {
                if (argc != 0) return self.fail(loc, "scan expects 0 arguments", error.WrongArity);
                try self.push(try self.doScan(loc));
            },
            // M5d：scanln() —— 读当前行剩余内容（或下一整行），EOF 返回 null（镜像 eval builtinScanln）。
            .scanln => {
                if (argc != 0) return self.fail(loc, "scanln expects 0 arguments", error.WrongArity);
                try self.push(try self.doScanln(loc));
            },
        }
    }

    /// M5d：scan token 提取 + 跨行读取（镜像 eval builtinScan）。
    fn doScan(self: *VM, loc: ast.SourceLocation) VMError!Value {
        while (true) {
            if (self.scan_line_pos < self.scan_line_buf.items.len) {
                const remaining = self.scan_line_buf.items[self.scan_line_pos..];
                var start: usize = 0;
                while (start < remaining.len and (remaining[start] == ' ' or remaining[start] == '\t' or remaining[start] == '\r')) start += 1;
                if (start < remaining.len) {
                    var end = start + 1;
                    while (end < remaining.len and remaining[end] != ' ' and remaining[end] != '\t' and remaining[end] != '\r') end += 1;
                    const token = remaining[start..end];
                    self.scan_line_pos += end;
                    return Value{ .string = self.allocator.dupe(u8, token) catch return error.OutOfMemory };
                }
            }
            const has_line = try self.readNextLine(loc);
            if (!has_line) return Value.null_val;
        }
    }

    /// M5d：scanln —— 当前行剩余 / 下一整行 / EOF→null（镜像 eval builtinScanln）。
    fn doScanln(self: *VM, loc: ast.SourceLocation) VMError!Value {
        if (self.scan_line_pos < self.scan_line_buf.items.len) {
            const remaining = self.scan_line_buf.items[self.scan_line_pos..];
            const owned = self.allocator.dupe(u8, remaining) catch return error.OutOfMemory;
            self.scan_line_pos = self.scan_line_buf.items.len;
            return Value{ .string = owned };
        }
        const has_line = try self.readNextLine(loc);
        if (!has_line) return Value.null_val;
        const owned = self.allocator.dupe(u8, self.scan_line_buf.items) catch return error.OutOfMemory;
        self.scan_line_pos = self.scan_line_buf.items.len;
        return Value{ .string = owned };
    }

    /// M5d：读 stdin 一行到 scan_line_buf（去尾部 CR），EOF 返回 false（镜像 eval readNextLine）。
    fn readNextLine(self: *VM, loc: ast.SourceLocation) VMError!bool {
        const reader = try self.ensureStdinReader(loc);
        self.scan_line_buf.clearRetainingCapacity();
        const line = reader.takeDelimiter('\n') catch {
            return self.fail(loc, "scan: IO error", error.Unsupported);
        };
        if (line) |l| {
            const trimmed = if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l;
            self.scan_line_buf.appendSlice(self.allocator, trimmed) catch return error.OutOfMemory;
            self.scan_line_pos = 0;
            return true;
        }
        return false;
    }

    /// M5d：惰性建持久 stdin reader（镜像 eval ensureStdinReader）。
    fn ensureStdinReader(self: *VM, loc: ast.SourceLocation) VMError!*std.Io.Reader {
        if (self.stdin_state) |state| return &state.reader.interface;
        const io = self.io orelse return self.fail(loc, "scan: no IO context", error.Unsupported);
        const state = self.allocator.create(StdinState) catch return error.OutOfMemory;
        state.* = .{
            .buffer = undefined,
            .reader = std.Io.File.Reader.initStreaming(std.Io.File.stdin(), io, &state.buffer),
        };
        self.stdin_state = state;
        return &state.reader.interface;
    }

    /// 执行 OP_MAKE_ADT：弹栈顶 argc 个字段值（owned，接管），按 program.adt_ctors[ctor_idx]
    /// 建 AdtValue（fields[i].name 取 desc.field_names[i]，type_name/constructor 借用 desc），压栈。
    fn doMakeAdt(self: *VM, program: *const Program, ctor_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const desc = program.adt_ctors.items[ctor_idx];
        if (desc.arity != argc) return self.fail(loc, "ADT constructor arity mismatch", error.WrongArity);
        const fields = self.allocator.alloc(value.AdtField, argc) catch return error.OutOfMemory;
        // 栈顶 argc 个值依次对应 field[0..argc]（先压的是 field0）。接管 owned。
        const base = self.stack.items.len - argc;
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            var fv = self.stack.items[base + i];
            // M5c：字段隐式数值定型（如 salary: i32 把 i8 实参 100 协调成 i32）。best-effort，
            // 仅 int/float + builtin 数值类型名时协调；失败原样。数值是内联值，无 rc 影响。
            if (desc.field_types[i]) |tn| {
                if (fv == .integer or fv == .float) {
                    if (cast.castNumeric(fv, tn)) |coerced| {
                        fv = coerced;
                    } else |_| {}
                }
            }
            fields[i] = .{ .name = desc.field_names[i], .value = fv };
        }
        self.stack.shrinkRetainingCapacity(base);
        const av = self.allocator.create(value.AdtValue) catch return error.OutOfMemory;
        av.* = .{ .type_name = desc.type_name, .constructor = desc.ctor_name, .fields = fields, .rc = 1 };
        try self.push(Value{ .adt = av });
    }

    /// 执行 OP_INTERP：弹栈顶 n 段值（先压的是第一段），依次 format 拼接成新 string 压栈，各段 release。
    fn doInterp(self: *VM, n: u16) VMError!void {
        const base = self.stack.items.len - n;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.stack.items[base + i].format(&buf, self.allocator, false) catch return error.OutOfMemory;
        }
        // 拼接完成后再 release 各段（format 借用其内容，须在 format 后释放）。
        i = 0;
        while (i < n) : (i += 1) self.stack.items[base + i].releaseVM(self.allocator);
        self.stack.shrinkRetainingCapacity(base);
        const owned = buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        try self.push(Value{ .string = owned });
    }

    /// 执行 OP_CAST：弹值，按目标类型名转换，压结果。str→format；数值互转 cast.zig；溢出→panic。
    fn doCast(self: *VM, type_name: []const u8, loc: ast.SourceLocation) VMError!void {
        const v = self.pop();
        defer v.releaseVM(self.allocator);
        if (std.mem.eql(u8, type_name, "str")) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);
            v.format(&buf, self.allocator, false) catch return error.OutOfMemory;
            const owned = buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            try self.push(Value{ .string = owned });
            return;
        }
        const result = cast.castNumeric(v, type_name) catch |e| switch (e) {
            error.CastOverflow => return self.fail(loc, "arithmetic overflow: narrowing conversion out of range", error.ArithmeticOverflow),
            error.CastTypeMismatch => return self.fail(loc, "invalid type conversion", error.TypeMismatch),
        };
        try self.push(result);
    }

    /// M5：隐式数值定型（OP_COERCE）。栈顶 peek，仅当为 int/float 且目标为 builtin 数值类型时
    /// 用 cast.castNumeric 协调 type_tag（拓宽/收窄），替换栈顶；任何失败（溢出/类型不符/非数值/
    /// 泛型类型名）原样保留——绝不 panic。镜像 eval 的 `castValue(...) catch val` best-effort 隐式协调。
    /// 注意：与 doCast 不同，不处理 str（隐式协调不做 to-string，保持值语义）。
    fn doCoerce(self: *VM, type_name: []const u8) void {
        const top = &self.stack.items[self.stack.items.len - 1];
        if (top.* != .integer and top.* != .float) return; // 非数值：原样
        const result = cast.castNumeric(top.*, type_name) catch return; // 溢出/不符：原样
        // 数值是内联值类型（无 rc / 无分配），直接替换栈顶，无需 release 旧值。
        top.* = result;
    }

    /// 执行 OP_GET_FIELD：弹对象，按名读 adt/record 字段，retainOwned 压栈，release 对象。
    fn doGetField(self: *VM, field: []const u8, loc: ast.SourceLocation) VMError!void {
        const obj = self.pop();
        defer obj.releaseVM(self.allocator);
        switch (obj) {
            .adt => |av| {
                for (av.fields) |f| {
                    if (f.name) |n| {
                        if (std.mem.eql(u8, n, field)) {
                            try self.push(try self.retainOwned(f.value));
                            return;
                        }
                    }
                }
                return self.fail(loc, "no such field on adt", error.TypeMismatch);
            },
            .record => |rec| {
                if (rec.fields.get(field)) |v| {
                    try self.push(try self.retainOwned(v));
                    return;
                }
                return self.fail(loc, "no such field on record", error.TypeMismatch);
            },
            // M5o：模块值（trait_value）字段访问 —— Store.Memory（子模块）/ Module.member。
            // vtable 查 field → retainOwned 压栈。镜像 eval accessField trait_value 分支（§4.6.2）。
            .trait_value => |tv| {
                if (tv.methods.get(field)) |v| {
                    try self.push(try self.retainOwned(v));
                    return;
                }
                return self.fail(loc, "no such member on module value", error.TypeMismatch);
            },
            // M3c：error_val 不再支持字段访问，必须使用方法调用 e.message() / e.type_name()
            .error_val => {
                return self.fail(loc, "Error trait methods must be called as methods, use .message() or .type_name()", error.TypeMismatch);
            },
            // M5e：throw_val 不再支持字段访问
            .throw_val => {
                return self.fail(loc, "Error trait methods must be called as methods, use .message() or .type_name()", error.TypeMismatch);
            },
            // M4b：Channel 方向类型字段 —— ch.sender / ch.receiver（各 ref channel + 新包装）。
            .channel_val => |cv| {
                if (std.mem.eql(u8, field, "sender")) {
                    cv.ref();
                    const sv = self.allocator.create(value.SenderValue) catch return error.OutOfMemory;
                    sv.* = .{ .channel = cv };
                    try self.push(Value{ .sender_val = sv });
                    return;
                }
                if (std.mem.eql(u8, field, "receiver")) {
                    cv.ref();
                    const rv = self.allocator.create(value.ReceiverValue) catch return error.OutOfMemory;
                    rv.* = .{ .channel = cv };
                    try self.push(Value{ .receiver_val = rv });
                    return;
                }
                return self.fail(loc, "no such field on Channel (only 'sender'/'receiver')", error.TypeMismatch);
            },
            else => return self.fail(loc, "field access on non-record/adt", error.TypeMismatch),
        }
    }

    /// 执行 OP_SET_FIELD：栈 [record, val] → [new_record]。
    /// record COW（rc>1 时浅拷分裂），写字段（旧值 release，val owned move 入槽），压结果 record。
    /// 镜像 eval field_assignment 的 record 分支（cowField + map 覆盖）。
    fn doSetField(self: *VM, field: []const u8, loc: ast.SourceLocation) VMError!void {
        const val = self.pop(); // 接管 owned
        const obj = self.pop();
        if (obj != .record) {
            val.releaseVM(self.allocator);
            obj.releaseVM(self.allocator);
            return self.fail(loc, "cannot assign field on non-record", error.TypeMismatch);
        }
        var rec = obj.record;
        // COW：共享（rc>1）时浅拷一份独占体，原体 rc-1。
        if (rec.rc > 1) {
            var new_map = std.StringHashMap(Value).init(self.allocator);
            var it = rec.fields.iterator();
            while (it.next()) |e| {
                const key = self.allocator.dupe(u8, e.key_ptr.*) catch return error.OutOfMemory;
                new_map.put(key, try self.retainOwned(e.value_ptr.*)) catch return error.OutOfMemory;
            }
            rec.rc -= 1;
            // type_name 是借用 slice（release 不释放它）；复用原 slice，不 dupe（dupe 会泄漏）。
            const new_rec = value.Value.makeRecord(self.allocator, rec.type_name, new_map) catch return error.OutOfMemory;
            rec = new_rec.record;
        }
        // 写字段：必须已存在（对齐 eval：不存在 → panic）。
        if (rec.fields.getPtr(field)) |existing| {
            existing.*.releaseVM(self.allocator);
            existing.* = val; // owned move
        } else {
            val.releaseVM(self.allocator);
            (Value{ .record = rec }).releaseVM(self.allocator);
            return self.fail(loc, "no such field on record", error.TypeMismatch);
        }
        try self.push(Value{ .record = rec });
    }

    /// array COW（rc>1 时浅拷分裂），写元素（旧值 release，val owned move 入槽），压结果 array。
    /// 镜像 eval assignment 的 .index/.array 分支（cowField + 元素覆盖）。
    /// 栈布局 [array, index, val] → [new_array]。
    fn doSetIndex(self: *VM, loc: ast.SourceLocation) VMError!void {
        const val = self.pop(); // 接管 owned
        const index_val = self.pop();
        defer index_val.releaseVM(self.allocator);
        const obj = self.pop();
        if (obj != .array) {
            val.releaseVM(self.allocator);
            obj.releaseVM(self.allocator);
            return self.fail(loc, "cannot index-assign on non-array", error.TypeMismatch);
        }
        if (index_val != .integer) {
            val.releaseVM(self.allocator);
            obj.releaseVM(self.allocator);
            return self.fail(loc, "array index must be an integer", error.TypeMismatch);
        }
        const iv = index_val.integer;
        const i: i128 = if (iv.type_tag.isSigned()) iv.signedValue() else @intCast(iv.value);
        var arr = obj.array;
        if (i < 0 or i >= @as(i128, @intCast(arr.elements.len))) {
            val.releaseVM(self.allocator);
            obj.releaseVM(self.allocator);
            return self.fail(loc, "index out of bounds", error.TypeMismatch);
        }
        // COW：共享（rc>1）时浅拷一份独占体，原体 rc-1。
        if (arr.rc > 1) {
            const new_elems = self.allocator.alloc(Value, arr.elements.len) catch return error.OutOfMemory;
            for (arr.elements, 0..) |e, k| new_elems[k] = self.retainOwned(e) catch return error.OutOfMemory;
            arr.rc -= 1;
            const new_arr = value.Value.makeArray(self.allocator, new_elems, arr.fixed_size) catch return error.OutOfMemory;
            arr = new_arr.array;
        }
        const slot = &arr.elements[@intCast(i)];
        slot.*.releaseVM(self.allocator);
        slot.* = val; // owned move
        try self.push(Value{ .array = arr });
    }

    /// 执行 OP_MAKE_RECORD：弹栈顶 n 个值（n=shape.field_names.len），建 RecordValue（key dupe，
    /// value 接管 owned）压栈。匿名记录 type_name=""（与树遍历器 evalRecordLiteral 一致）。
    fn doMakeRecord(self: *VM, program: *const Program, shape_idx: u16) VMError!void {
        const shape = program.record_shapes.items[shape_idx];
        const n = shape.field_names.len;
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.*.releaseVM(self.allocator);
            }
            map.deinit();
        }
        const base = self.stack.items.len - n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = self.allocator.dupe(u8, shape.field_names[i]) catch return error.OutOfMemory;
            // put 可能覆盖同名 key（重复字段）：释放旧值 + 复用旧 key，避免泄漏。
            const gop = map.getOrPut(key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.*.releaseVM(self.allocator);
            }
            gop.value_ptr.* = self.stack.items[base + i];
        }
        self.stack.shrinkRetainingCapacity(base);
        const rec = value.Value.makeRecord(self.allocator, "", map) catch return error.OutOfMemory;
        try self.push(rec);
    }

    /// 执行 OP_RECORD_EXTEND：栈布局 [base, u0..u_{n-1}]（base 在 n 个 update 值之下）。
    /// 浅拷 base 字段（dupe key + retain value）+ updates 覆盖/新增，建新 RecordValue 压栈。
    fn doRecordExtend(self: *VM, program: *const Program, shape_idx: u16, loc: ast.SourceLocation) VMError!void {
        const shape = program.record_shapes.items[shape_idx];
        const n = shape.field_names.len;
        const ubase = self.stack.items.len - n;
        const base_val = self.stack.items[ubase - 1];
        if (base_val != .record) return self.fail(loc, "record extend base must be a record", error.TypeMismatch);

        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.*.releaseVM(self.allocator);
            }
            map.deinit();
        }
        // 浅拷 base 字段（retain value，dupe key）。
        var bit = base_val.record.fields.iterator();
        while (bit.next()) |e| {
            const key = self.allocator.dupe(u8, e.key_ptr.*) catch return error.OutOfMemory;
            map.put(key, try self.retainOwned(e.value_ptr.*)) catch return error.OutOfMemory;
        }
        // updates 覆盖/新增（接管栈上 owned 值）。
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = self.allocator.dupe(u8, shape.field_names[i]) catch return error.OutOfMemory;
            const gop = map.getOrPut(key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.*.releaseVM(self.allocator); // 释放被覆盖的 base 字段拷贝
            }
            gop.value_ptr.* = self.stack.items[ubase + i];
        }
        // 弹 n 个 update + base（base 用完 release）。
        self.stack.shrinkRetainingCapacity(ubase - 1);
        base_val.releaseVM(self.allocator);
        const rec = value.Value.makeRecord(self.allocator, "", map) catch return error.OutOfMemory;
        try self.push(rec);
    }

    /// 执行 OP_INDEX：array 整数索引（边界检查）、string codepoint 索引，retainOwned 元素压栈。
    fn doIndex(self: *VM, object: Value, index_val: Value, loc: ast.SourceLocation) VMError!void {
        switch (object) {
            .array => |arr| {
                if (index_val != .integer) return self.fail(loc, "array index must be an integer", error.TypeMismatch);
                const iv = index_val.integer;
                const i: i128 = if (iv.type_tag.isSigned()) iv.signedValue() else @intCast(iv.value);
                if (i < 0 or i >= @as(i128, @intCast(arr.elements.len)))
                    return self.fail(loc, "index out of bounds", error.TypeMismatch);
                try self.push(try self.retainOwned(arr.elements[@intCast(i)]));
            },
            .string => |s| {
                if (index_val != .integer) return self.fail(loc, "string index must be an integer", error.TypeMismatch);
                const iv = index_val.integer;
                const i: i128 = if (iv.type_tag.isSigned()) iv.signedValue() else @intCast(iv.value);
                if (i < 0) return self.fail(loc, "index out of bounds", error.TypeMismatch);
                const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
                var iter = view.iterator();
                var ci: i128 = 0;
                while (iter.nextCodepoint()) |cp| : (ci += 1) {
                    if (ci == i) {
                        try self.push(Value{ .char_val = @intCast(cp) });
                        return;
                    }
                }
                return self.fail(loc, "index out of bounds", error.TypeMismatch);
            },
            else => return self.fail(loc, "cannot index into this type", error.TypeMismatch),
        }
    }

    /// M3d：执行 OP_CALL_METHOD。栈布局 [receiver, arg0..arg_{argc-1}]，receiver 在 args 下方。
    /// 弹实参 + receiver（均 owned，方法分派后 releaseVM），压 fresh owned 结果。
    fn doCallMethod(self: *VM, func: *const Function, name_idx: u16, argc: u8, loc: ast.SourceLocation) VMError!void {
        const name = func.chunk.constants.items[name_idx].string;
        const args_start = self.stack.items.len - argc;
        const args = self.stack.items[args_start..][0..argc];
        const receiver = self.stack.items[args_start - 1];

        // M5e：Error trait 内置方法：message() 和 type_name()
        // 这些方法直接从 error_val 或 throw_val.err 中提取字段值
        if (std.mem.eql(u8, name, "message") or std.mem.eql(u8, name, "type_name")) {
            if (argc != 0) return self.fail(loc, "Error trait method expects 0 arguments", error.WrongArity);
            const result = switch (receiver) {
                .error_val => |e| blk: {
                    const field_value = if (std.mem.eql(u8, name, "message")) e.message else e.type_name;
                    break :blk Value{ .string = try self.allocator.dupe(u8, field_value) };
                },
                .throw_val => |tv| blk: {
                    if (tv.* == .err) {
                        const field_value = if (std.mem.eql(u8, name, "message")) tv.err.message else tv.err.type_name;
                        break :blk Value{ .string = try self.allocator.dupe(u8, field_value) };
                    } else {
                        return self.fail(loc, "cannot call Error method on Ok value", error.TypeMismatch);
                    }
                },
                else => null,
            };
            if (result) |r| {
                receiver.releaseVM(self.allocator);
                self.stack.shrinkRetainingCapacity(args_start - 1);
                try self.push(r);
                return;
            }
        }

        // M4c：spawn_val 的 await/cancel 需 VM 级处理（等待 + 结果跨线程深拷回父 allocator）。
        if (receiver == .spawn_val) {
            return self.doSpawnMethod(receiver.spawn_val, name, args, args_start, loc);
        }
        // M4d：inline trait 值方法分派 —— vtable 查 name 得 vm_closure，以 args 调用（无 data receiver）。
        if (receiver == .trait_value and receiver.trait_value.vm_owned) {
            return self.doTraitMethod(receiver.trait_value, name, argc, args_start, loc);
        }
        // M5i：用户 impl 方法分派 —— 据 receiver 类型名 + 方法名查 program.impl_methods（数值宽度互通），
        // 命中则把 [receiver, args...] 作为方法 slot 跑方法体。未命中查 trait 默认方法；再未命中走 native。
        if (self.program) |prog| {
            // M5n：组合 Trait 冲突消解优先（文档 §2.7.2）——override/委托覆盖父 Trait impl，
            // 在扁平 impl 查找之前。镜像 eval：组合分派 > 扁平 impl > trait 默认。
            const recv_type = vmValueTypeName(receiver);
            if (resolveComposedMethod(prog, recv_type, name)) |fidx| {
                return self.invokeMethodBody(prog, fidx, argc, args_start, loc);
            }
            if (findImplMethod(prog, recv_type, name)) |fidx| {
                return self.invokeMethodBody(prog, fidx, argc, args_start, loc);
            }
            if (findTraitDefault(prog, name)) |fidx| {
                return self.invokeMethodBody(prog, fidx, argc, args_start, loc);
            }
        }
        const result = method.dispatch(self.allocator, receiver, name, args) catch |err| switch (err) {
            error.NoSuchMethod => return self.fail(loc, "no such method on this type", error.TypeMismatch),
            error.WrongArity => return self.fail(loc, "method called with wrong number of arguments", error.WrongArity),
            error.TypeMismatch => return self.fail(loc, "method not available on this type", error.TypeMismatch),
            error.ChannelClosed => return self.fail(loc, "channel: send on closed channel", error.TypeMismatch),
            error.OutOfMemory => return error.OutOfMemory,
        };
        // 释放实参 + receiver（分派已 retainOwned 需要的元素到结果）。
        for (args) |a| a.releaseVM(self.allocator);
        receiver.releaseVM(self.allocator);
        self.stack.shrinkRetainingCapacity(args_start - 1);
        try self.push(result);
    }

    /// M5i：以栈上 [receiver, arg0..arg_{argc-1}]（共 argc+1 个，起于 args_start-1）作为方法体的
    /// slot 0..argc，建帧跑方法体到 RETURN，结果压回 args_start-1。用 stop_depth 边界使方法体
    /// RETURN 即返回（不 continue 外层 dispatch），镜像 forceLazyVM/callNoArgs。
    fn invokeMethodBody(self: *VM, program: *const Program, func_idx: u16, argc: u8, args_start: usize, loc: ast.SourceLocation) VMError!void {
        const f = &program.functions.items[func_idx];
        const total_args = argc + 1; // receiver + 显式实参
        if (total_args != f.arity) return self.fail(loc, "method called with wrong number of arguments", error.WrongArity);
        if (self.frames.items.len >= MAX_FRAMES) return self.fail(loc, "stack overflow: call depth exceeded", error.StackOverflow);
        // receiver+args 已在栈顶 total_args 个槽（起于 args_start-1），正好作 slot 0..arity-1。
        const slot_base = args_start - 1;
        var s: u16 = f.arity;
        while (s < f.slot_count) : (s += 1) try self.push(Value.unit);
        const saved_depth = self.stop_depth;
        try self.frames.append(self.allocator, .{ .func = f, .ip = 0, .slot_base = slot_base, .frame_base = slot_base });
        self.stop_depth = self.frames.items.len - 1; // 方法帧弹出即停
        const result = self.runLoop(program) catch |e| {
            self.stop_depth = saved_depth;
            return e;
        };
        self.stop_depth = saved_depth;
        // 方法帧 RETURN 已释放 slot（含 receiver/args）并 shrink 到 slot_base；结果压回。
        try self.push(result);
    }

    /// M4c：Spawn<T> 方法。await() 挂起等待 worker 完成，把结果**跨线程深拷**回父 allocator
    /// （子结果在 arena 内，await 后 arena 仍由 VM.deinit 持有，故拷贝安全且独立）；Failed → panic。
    /// cancel() 标记取消。栈：[spawn_val, args...] → 弹掉换成结果。
    fn doSpawnMethod(self: *VM, handle: *SpawnHandle, name: []const u8, args: []const Value, args_start: usize, loc: ast.SourceLocation) VMError!void {
        const receiver = self.stack.items[args_start - 1];
        if (std.mem.eql(u8, name, "await")) {
            if (args.len != 0) return self.fail(loc, "await expects 0 arguments", error.WrongArity);
            handle.mutex.lock();
            while (handle.status.load(.seq_cst) == .Pending or handle.status.load(.seq_cst) == .Running) {
                handle.condition.wait(&handle.mutex);
            }
            const child_result = handle.result;
            handle.consumed.store(true, .seq_cst);
            const failed = handle.status.load(.seq_cst) == .Failed;
            handle.mutex.unlock();
            if (failed) {
                const msg = handle.panic_message orelse "spawn: coroutine failed";
                return self.fail(loc, msg, error.SpawnFailed);
            }
            // 跨线程深拷结果进父 allocator（子结果在 arena，独立于父 refcount 堆）。
            const owned = if (child_result) |r| (r.deepCopyAcross(self.allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(loc, "spawn: result type not supported across threads", error.TypeMismatch),
            }) else Value.unit;
            for (args) |a| a.releaseVM(self.allocator);
            receiver.releaseVM(self.allocator);
            self.stack.shrinkRetainingCapacity(args_start - 1);
            try self.push(owned);
            return;
        }
        if (std.mem.eql(u8, name, "cancel")) {
            if (args.len != 0) return self.fail(loc, "cancel expects 0 arguments", error.WrongArity);
            handle.mutex.lock();
            handle.status.store(.Cancelled, .seq_cst);
            handle.consumed.store(true, .seq_cst);
            handle.condition.broadcast();
            handle.mutex.unlock();
            for (args) |a| a.releaseVM(self.allocator);
            receiver.releaseVM(self.allocator);
            self.stack.shrinkRetainingCapacity(args_start - 1);
            try self.push(Value.unit);
            return;
        }
        // M5：status() —— 返回 SpawnStatus ADT 值（无字段构造器），镜像 eval makeSpawnStatus。
        if (std.mem.eql(u8, name, "status")) {
            if (args.len != 0) return self.fail(loc, "status expects 0 arguments", error.WrongArity);
            const s = handle.status.load(.seq_cst);
            const ctor: []const u8 = switch (s) {
                .Pending => "Pending",
                .Running => "Running",
                .Completed => "Completed",
                .Cancelled => "Cancelled",
                .Failed => "Failed",
            };
            const av = self.allocator.create(value.AdtValue) catch return error.OutOfMemory;
            av.* = .{ .type_name = "SpawnStatus", .constructor = ctor, .fields = &[_]value.AdtField{}, .rc = 1 };
            for (args) |a| a.releaseVM(self.allocator);
            receiver.releaseVM(self.allocator);
            self.stack.shrinkRetainingCapacity(args_start - 1);
            try self.push(Value{ .adt = av });
            return;
        }
        return self.fail(loc, "no such method on Spawn", error.TypeMismatch);
    }

    /// M4d：inline trait 值方法分派。栈：[trait_value, arg0..arg_{argc-1}]（args_start 指向 arg0）。
    /// vtable 查 name → vm_closure。把 receiver 槽替换为该 closure（retainOwned，vtable 仍持母本），
    /// 释放原 receiver，再 enterClosure + 边界 runLoop 跑到返回，结果压栈（替换 [closure,args] → result）。
    fn doTraitMethod(self: *VM, tv: *value.TraitValue, name: []const u8, argc: u8, args_start: usize, loc: ast.SourceLocation) VMError!void {
        const impl = tv.methods.get(name) orelse
            return self.fail(loc, "no such method on trait value", error.TypeMismatch);
        if (impl != .vm_closure) return self.fail(loc, "trait method is not callable", error.TypeMismatch);
        const callee_idx = args_start - 1;
        const receiver = self.stack.items[callee_idx];
        // 替换 receiver 槽为方法闭包（retainOwned：vtable 持母本，调用结束帧 release 此槽）。
        self.stack.items[callee_idx] = try self.retainOwned(impl);
        receiver.releaseVM(self.allocator); // 释放 trait_value receiver（rc-1）
        // 边界嵌套运行：enterClosure 建帧，runLoop 在帧弹回当前深度即返回。
        const vc = impl.vm_closure;
        const total = vc.bound_args.len + argc;
        if (total != vc.arity) return self.fail(loc, "trait method called with wrong number of arguments", error.WrongArity);
        const saved_depth = self.stop_depth;
        try self.enterClosure(vc, callee_idx, argc, loc);
        self.stop_depth = self.frames.items.len - 1;
        const result = self.runLoop(self.program.?) catch |e| {
            self.stop_depth = saved_depth;
            return e;
        };
        self.stop_depth = saved_depth;
        // enterClosure 的帧 RETURN 经 frameReturn 已 shrink 到 callee_idx 并释放槽。结果压回。
        try self.push(result);
    }

    /// M4a：执行 OP_COMPOUND_LOCAL。slot 持 atomic_val → 原子 fetch<op>（add/sub/and/or 直接；
    /// mul/div/mod 走 CAS 循环），不重写 slot；否则常规 slot_val arith rhs 写回 slot。
    fn doCompoundLocal(self: *VM, frame: *CallFrame, slot: u16, arith_op: OpCode, loc: ast.SourceLocation) VMError!void {
        const rhs = self.pop();
        defer rhs.releaseVM(self.allocator);
        const dst = frame.slot_base + slot;
        const cur = self.stack.items[dst];
        const target = if (cur == .cell_val) cur.cell_val.inner else cur;
        if (target == .atomic_val) {
            const av = target.atomic_val;
            const operand = value.valueToAtomicRaw(rhs, av.type_tag);
            switch (arith_op) {
                .op_add => _ = av.fetchAdd(operand),
                .op_sub => _ = av.fetchSub(operand),
                .op_mul => _ = av.fetchMul(operand),
                .op_bit_and => _ = av.fetchAnd(operand),
                .op_bit_or => _ = av.fetchOr(operand),
                .op_div, .op_mod => {
                    // CAS 循环：原子读改写（div/mod 无专用原子指令）。
                    while (true) {
                        const current = av.data.load(.seq_cst);
                        const cur_val = av.load();
                        const result = try self.arith(arith_op, cur_val, rhs, loc);
                        const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                        if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst) == null) break;
                    }
                },
                else => return self.fail(loc, "unsupported atomic compound op", error.TypeMismatch),
            }
            return; // atomic 就地更新，slot 不变
        }
        // 非 atomic：常规读改写。
        const result = try self.arith(arith_op, target, rhs, loc);
        if (cur == .cell_val) {
            cur.cell_val.inner.releaseVM(self.allocator);
            cur.cell_val.inner = result;
        } else {
            cur.releaseVM(self.allocator);
            self.stack.items[dst] = result;
        }
    }

    /// M4c：执行 OP_COMPOUND_UPVALUE。upvalue 是 *Cell；cell.inner 持 atomic → 原子 fetch<op>（不重写 inner）；
    /// 否则常规 inner arith rhs 写回 inner。镜像 doCompoundLocal 的 cell 分支，作用于捕获变量。
    fn doCompoundUpvalue(self: *VM, frame: *CallFrame, idx: u16, arith_op: OpCode, loc: ast.SourceLocation) VMError!void {
        const rhs = self.pop();
        defer rhs.releaseVM(self.allocator);
        const cell = frame.upvalues[idx].cell_val;
        const target = cell.inner;
        if (target == .atomic_val) {
            const av = target.atomic_val;
            const operand = value.valueToAtomicRaw(rhs, av.type_tag);
            switch (arith_op) {
                .op_add => _ = av.fetchAdd(operand),
                .op_sub => _ = av.fetchSub(operand),
                .op_mul => _ = av.fetchMul(operand),
                .op_bit_and => _ = av.fetchAnd(operand),
                .op_bit_or => _ = av.fetchOr(operand),
                .op_div, .op_mod => {
                    while (true) {
                        const current = av.data.load(.seq_cst);
                        const cur_val = av.load();
                        const result = try self.arith(arith_op, cur_val, rhs, loc);
                        const new_raw = value.valueToAtomicRaw(result, av.type_tag);
                        if (av.data.cmpxchgStrong(current, new_raw, .seq_cst, .seq_cst) == null) break;
                    }
                },
                else => return self.fail(loc, "unsupported atomic compound op", error.TypeMismatch),
            }
            return; // atomic 就地更新，inner 不变
        }
        const result = try self.arith(arith_op, target, rhs, loc);
        cell.inner.releaseVM(self.allocator);
        cell.inner = result;
    }

    /// M4c：执行 OP_SPAWN。栈顶是 spawn body 编译成的零参 vm_closure（upvalues = 父帧捕获的 cell）。
    /// 深拷各 upvalue 的当前值进 per-spawn arena（隔离堆），起 OS 线程跑子 VM，压 spawn_val 句柄。
    /// 失败时仍压 handle（status=Failed，await 传播 panic），保证线性 Spawn<T> 语义不破。
    fn doSpawn(self: *VM, loc: ast.SourceLocation) VMError!void {
        const callee = self.pop();
        defer callee.releaseVM(self.allocator);
        if (callee != .vm_closure) return self.fail(loc, "spawn body must be a closure", error.TypeMismatch);
        const vc = callee.vm_closure;
        // io 仅用于填充 handle（VM await 路径用 std.Thread.Futex，不依赖 io）；未设则用线程化默认。
        const io = self.io orelse std.Io.Threaded.global_single_threaded.io();

        // per-spawn arena（page_allocator 裸打底，与父/兄弟协程内存隔离）。
        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const aalloc = arena.allocator();

        // 深拷捕获快照：upvalue 是 *Cell，取 inner 当前值跨线程深拷进 arena。
        const caps = aalloc.alloc(Value, vc.upvalues.len) catch return error.OutOfMemory;
        for (vc.upvalues, 0..) |uv, i| {
            const inner = uv.cell_val.inner;
            caps[i] = inner.deepCopyAcross(aalloc) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(loc, "spawn: captured value type not supported across threads", error.TypeMismatch),
            };
        }

        // handle 用父 allocator（await 在父线程读，arena 释放后仍需存活直到 handle 释放）。
        const handle = self.allocator.create(SpawnHandle) catch return error.OutOfMemory;
        handle.* = SpawnHandle.init(self.allocator);
        handle.status.store(.Running, .seq_cst);

        const ctx = self.allocator.create(SpawnCtx) catch return error.OutOfMemory;
        ctx.* = .{
            .handle = handle,
            .program = self.program.?,
            .func = @ptrCast(@alignCast(vc.func)),
            .captures = caps,
            .arena = arena,
            .io = io,
        };
        self.spawns.append(self.allocator, ctx) catch return error.OutOfMemory;

        // 起 OS 线程（真并行；channel 阻塞点走 futex 回退）。
        ctx.thread = std.Thread.spawn(.{}, spawnThreadEntry, .{ctx}) catch {
            spawnFail(handle, "spawn: failed to create thread");
            try self.push(Value{ .spawn_val = handle });
            return;
        };
        try self.push(Value{ .spawn_val = handle });
    }

    /// M3d：执行 OP_FOR_NEXT。iter_slot 持 array/range/string，idx_slot 持索引（i64）。
    /// 耗尽 → ip += exit_off（不压元素）；否则压当前元素（retainOwned）+ idx 自增。
    fn doForNext(self: *VM, frame: *CallFrame, iter_slot: u16, idx_slot: u16, exit_off: i32, loc: ast.SourceLocation) VMError!void {
        const iter_raw = self.stack.items[frame.slot_base + iter_slot];
        const idx_raw = self.stack.items[frame.slot_base + idx_slot];
        // 闭包捕获可能把 iter/idx slot 就地 box 成 *Cell（如循环体内 spawn 捕获循环变量）；透明解包。
        const iter = if (iter_raw == .cell_val) iter_raw.cell_val.inner else iter_raw;
        const idx_v = if (idx_raw == .cell_val) idx_raw.cell_val.inner else idx_raw;
        const idx: i64 = @intCast(idx_v.integer.value);
        switch (iter) {
            .array => |arr| {
                if (idx >= arr.elements.len) {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + exit_off);
                    return;
                }
                try self.push(try self.retainOwned(arr.elements[@intCast(idx)]));
            },
            .range => |r| {
                const cur = r.start + idx;
                const past = if (r.inclusive) cur > r.end else cur >= r.end;
                if (past) {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + exit_off);
                    return;
                }
                try self.push(Value{ .integer = .{ .value = @bitCast(@as(i128, cur)), .type_tag = .i64 } });
            },
            .string => |s| {
                // 按码点迭代：idx 是码点序号，线性扫描到第 idx 个（字符串迭代通常短）。
                const view = std.unicode.Utf8View.init(s) catch return self.fail(loc, "invalid UTF-8 string", error.TypeMismatch);
                var it = view.iterator();
                var ci: i64 = 0;
                while (it.nextCodepoint()) |cp| : (ci += 1) {
                    if (ci == idx) {
                        try self.push(Value{ .char_val = @intCast(cp) });
                        break;
                    }
                } else {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + exit_off);
                    return;
                }
            },
            else => return self.fail(loc, "for: value is not iterable", error.TypeMismatch),
        }
        // idx++（仅在未耗尽时到达此处）。若 idx slot 被 box 成 cell，写 cell.inner。
        const new_idx = Value{ .integer = .{ .value = @intCast(idx + 1), .type_tag = .i64 } };
        if (idx_raw == .cell_val) {
            idx_raw.cell_val.inner = new_idx; // inner 是 i64 内联值，无需 release
        } else {
            self.stack.items[frame.slot_base + idx_slot] = new_idx;
        }
    }

    /// 执行一次 OP_CALL_VALUE（M1b）：栈布局 [callee, arg0..]，callee 在 args 下方。默认柯里化：
    /// total == arity → 建帧调用；< → 产生 bound_args 更长的新 vm_closure；> → WrongArity。
    fn doCallValue(self: *VM, argc: u8, loc: ast.SourceLocation) VMError!void {
        const callee_idx = self.stack.items.len - argc - 1;
        const callee = self.stack.items[callee_idx];
        if (callee != .vm_closure) return self.fail(loc, "value is not callable", error.TypeMismatch);
        const vc = callee.vm_closure;
        const total = vc.bound_args.len + argc;
        if (total == vc.arity) {
            try self.enterClosure(vc, callee_idx, argc, loc);
        } else if (total < vc.arity) {
            try self.makeBoundClosure(vc, callee_idx, argc);
        } else {
            return self.fail(loc, "wrong number of arguments", error.WrongArity);
        }
    }

    /// 足参调用：建 callee 帧。栈上 [callee, new_arg0..]；若 callee 有 bound_args，
    /// 须把 bound_args 插到 new_args 前面，组成完整的 arity 个 slot。
    /// 为统一栈布局，重排：把 callee 槽之上重建为 [bound..., new...]（共 arity 个），slot_base 指向首个。
    fn enterClosure(self: *VM, vc: *value.VmClosure, callee_idx: usize, argc: u8, loc: ast.SourceLocation) VMError!void {
        if (self.frames.items.len >= MAX_FRAMES) return self.fail(loc, "stack overflow: call depth exceeded", error.StackOverflow);
        const func: *const Function = @ptrCast(@alignCast(vc.func));
        const nbound = vc.bound_args.len;
        if (nbound > 0) {
            // 在 callee 槽与 new_args 之间插入 bound_args（各 retainOwned 一份独立 owned）。
            // 当前栈：[callee, new0..new_{argc-1}]。目标：[callee, bound0..,new0..]。
            // 先把 new_args 整体后移 nbound 格，再填 bound。
            var k: usize = 0;
            while (k < nbound) : (k += 1) try self.push(Value.unit); // 扩容 nbound 格
            const args_start = callee_idx + 1;
            // new_args 原占 [args_start, args_start+argc)，后移到 [args_start+nbound, ...)
            var i: usize = argc;
            while (i > 0) {
                i -= 1;
                self.stack.items[args_start + nbound + i] = self.stack.items[args_start + i];
            }
            // 填入 bound_args（retainOwned，因 vc 仍持有母本，调用结束帧 release 各 slot）
            for (vc.bound_args, 0..) |ba, j| {
                self.stack.items[args_start + j] = try self.retainOwned(ba);
            }
        }
        const slot_base = callee_idx + 1;
        var s: u16 = vc.arity;
        while (s < func.slot_count) : (s += 1) try self.push(Value.unit);
        try self.frames.append(self.allocator, .{ .func = func, .ip = 0, .slot_base = slot_base, .frame_base = callee_idx, .upvalues = vc.upvalues });
    }

    /// 不足参：产生 bound_args 更长的新 vm_closure，替换栈上 [callee, args..] 为单个新闭包。
    fn makeBoundClosure(self: *VM, vc: *value.VmClosure, callee_idx: usize, argc: u8) VMError!void {
        const nbound = vc.bound_args.len;
        const new_bound = try self.allocator.alloc(Value, nbound + argc);
        // 复制旧 bound（retainOwned）+ 新实参（直接接管栈上 owned）。
        for (vc.bound_args, 0..) |ba, j| new_bound[j] = try self.retainOwned(ba);
        const args_start = callee_idx + 1;
        var i: usize = 0;
        while (i < argc) : (i += 1) new_bound[nbound + i] = self.stack.items[args_start + i];
        // 新闭包共享 func + upvalues（retainOwned upvalues）。M1b-1 upvalues 恒空。
        const new_uv: []Value = if (vc.upvalues.len > 0) try self.allocator.alloc(Value, vc.upvalues.len) else &.{};
        for (vc.upvalues, 0..) |uv, j| new_uv[j] = try self.retainOwned(uv);
        const nvc = try self.allocator.create(value.VmClosure);
        nvc.* = .{ .func = vc.func, .arity = vc.arity, .upvalues = new_uv, .bound_args = new_bound, .rc = 1, .allocator = self.allocator };
        // 弹掉 [callee, args..]（callee release，args 所有权已转入 new_bound 不 release），压入新闭包。
        self.stack.items[callee_idx].releaseVM(self.allocator);
        self.stack.shrinkRetainingCapacity(callee_idx);
        try self.push(Value{ .vm_closure = nvc });
    }

    /// 算术 + 位运算。语义镜像 eval.zig evalAdd/Sub/...（复用 value.zig promote/inRange）。
    fn arith(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        if (left == .integer and right == .integer) {
            const lt = left.integer.type_tag;
            const rt = right.integer.type_tag;
            switch (op) {
                .op_bit_and, .op_bit_or, .op_bit_xor => {
                    const result_type = lt; // 位运算保留 left 类型（与 evalBinary 一致）
                    const result: u128 = switch (op) {
                        .op_bit_and => left.integer.value & right.integer.value,
                        .op_bit_or => left.integer.value | right.integer.value,
                        .op_bit_xor => left.integer.value ^ right.integer.value,
                        else => unreachable,
                    };
                    if (!result_type.inRange(result)) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
                    return Value{ .integer = .{ .value = result, .type_tag = result_type } };
                },
                else => {},
            }
            const result_type = value.promoteIntTypes(lt, rt);
            const signed = result_type.isSigned();
            const lv: i128 = @bitCast(left.integer.value);
            const rv: i128 = @bitCast(right.integer.value);
            const result: u128 = switch (op) {
                .op_add => if (signed) @bitCast(lv +% rv) else left.integer.value +% right.integer.value,
                .op_sub => if (signed) @bitCast(lv -% rv) else left.integer.value -% right.integer.value,
                .op_mul => if (signed) @bitCast(lv *% rv) else left.integer.value *% right.integer.value,
                .op_div => blk: {
                    if (right.integer.value == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk if (signed) @bitCast(@divTrunc(lv, rv)) else left.integer.value / right.integer.value;
                },
                .op_mod => blk: {
                    if (right.integer.value == 0) return self.fail(loc, "division by zero", error.DivisionByZero);
                    break :blk if (signed) @bitCast(@rem(lv, rv)) else left.integer.value % right.integer.value;
                },
                else => unreachable,
            };
            if (!result_type.inRange(result)) return self.fail(loc, "arithmetic overflow: integer operation out of range", error.ArithmeticOverflow);
            return Value{ .integer = .{ .value = result, .type_tag = result_type } };
        }
        // M5：字符串拼接 s + t（镜像 eval.evalAdd 的 string+string 分支）。
        if (op == .op_add and left == .string and right == .string) {
            var result = std.ArrayList(u8).empty;
            result.appendSlice(self.allocator, left.string) catch return error.OutOfMemory;
            result.appendSlice(self.allocator, right.string) catch return error.OutOfMemory;
            const owned = result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            return Value{ .string = owned };
        }
        return self.arithFloat(op, left, right, loc);
    }

    /// 浮点参与的算术（int↔float 混合按 evalBinary 提升为 float）。
    fn arithFloat(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        if ((left == .float or left == .integer) and (right == .float or right == .integer)) {
            const lf: f128 = if (left == .float) left.float.value else intToFloat(left.integer);
            const rf: f128 = if (right == .float) right.float.value else intToFloat(right.integer);
            const tag: value.FloatType = if (left == .float and right == .float)
                value.promoteFloatTypes(left.float.type_tag, right.float.type_tag)
            else if (left == .float) left.float.type_tag else right.float.type_tag;
            const result: f128 = switch (op) {
                .op_add => lf + rf,
                .op_sub => lf - rf,
                .op_mul => lf * rf,
                .op_div => lf / rf,
                .op_mod => @rem(lf, rf),
                else => return self.fail(loc, "bitwise op requires integer operands", error.TypeMismatch),
            };
            if (!tag.inRange(result)) return self.fail(loc, "arithmetic overflow: floating-point operation out of range", error.ArithmeticOverflow);
            return Value{ .float = .{ .value = result, .type_tag = tag } };
        }
        return self.fail(loc, "arithmetic requires numeric operands", error.TypeMismatch);
    }

    fn intToFloat(iv: IntValue) f128 {
        return if (iv.type_tag.isSigned()) @floatFromInt(@as(i128, @bitCast(iv.value))) else @floatFromInt(iv.value);
    }

    /// 比较：== != < > <= >=。返回 bool。
    fn compare(self: *VM, op: OpCode, left: Value, right: Value, loc: ast.SourceLocation) VMError!Value {
        // == / !=：数值按 promoteIntTypes 后**按值**比较（忽略 type_tag），镜像 eval evalBinary .eq/.not_eq。
        // 关键：隐式定型（OP_COERCE）后操作数 tag 可能不同（如 i32 形参 vs i8 字面量），
        // 不能用 tag-strict 的 Value.equals，否则 `n == 0` 恒 false（M5 整数定型回归）。
        if (op == .op_eq or op == .op_neq) {
            if (left == .integer and right == .integer) {
                const rt = value.promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
                const lv: i128 = if (rt.isSigned()) @bitCast(left.integer.value) else @intCast(left.integer.value);
                const rv: i128 = if (rt.isSigned()) @bitCast(right.integer.value) else @intCast(right.integer.value);
                const eq = lv == rv;
                return Value{ .boolean = if (op == .op_eq) eq else !eq };
            }
            if (left == .float and right == .float) {
                const eq = left.float.value == right.float.value;
                return Value{ .boolean = if (op == .op_eq) eq else !eq };
            }
            const eq = left.equals(right);
            return Value{ .boolean = if (op == .op_eq) eq else !eq };
        }
        if (left == .integer and right == .integer) {
            const result_type = value.promoteIntTypes(left.integer.type_tag, right.integer.type_tag);
            const lv: i128 = if (result_type.isSigned()) @bitCast(left.integer.value) else @intCast(left.integer.value);
            const rv: i128 = if (result_type.isSigned()) @bitCast(right.integer.value) else @intCast(right.integer.value);
            return Value{ .boolean = ordCmp(op, lv, rv) };
        }
        if ((left == .float or left == .integer) and (right == .float or right == .integer)) {
            const lf: f128 = if (left == .float) left.float.value else intToFloat(left.integer);
            const rf: f128 = if (right == .float) right.float.value else intToFloat(right.integer);
            return Value{ .boolean = ordCmp(op, lf, rf) };
        }
        // M5：字符串字典序比较（镜像 eval evalLt/Gt/Le/Ge 的 string 分支，std.mem.order）。
        if (left == .string and right == .string) {
            const ord = std.mem.order(u8, left.string, right.string);
            return Value{ .boolean = switch (op) {
                .op_lt => ord == .lt,
                .op_gt => ord == .gt,
                .op_le => ord != .gt,
                .op_ge => ord != .lt,
                else => unreachable,
            } };
        }
        // M5e：char 序比较（镜像 eval evalLt/Gt/Le/Ge 的 char_val 分支）。
        if (left == .char_val and right == .char_val) {
            return Value{ .boolean = ordCmp(op, @as(u32, left.char_val), @as(u32, right.char_val)) };
        }
        return self.fail(loc, "comparison requires numeric operands", error.TypeMismatch);
    }

    fn ordCmp(op: OpCode, l: anytype, r: anytype) bool {
        return switch (op) {
            .op_lt => l < r,
            .op_gt => l > r,
            .op_le => l <= r,
            .op_ge => l >= r,
            else => unreachable,
        };
    }

    fn negate(self: *VM, v: Value, loc: ast.SourceLocation) VMError!Value {
        if (v == .integer) {
            const t = v.integer.type_tag;
            const neg: i128 = -@as(i128, @bitCast(v.integer.value));
            const result: u128 = @bitCast(neg);
            if (!t.inRange(result)) return self.fail(loc, "arithmetic overflow: integer negation out of range", error.ArithmeticOverflow);
            return Value{ .integer = .{ .value = result, .type_tag = t } };
        }
        if (v == .float) {
            const t = v.float.type_tag;
            const result: f128 = -v.float.value;
            if (!t.inRange(result)) return self.fail(loc, "arithmetic overflow: floating-point negation out of range", error.ArithmeticOverflow);
            return Value{ .float = .{ .value = result, .type_tag = t } };
        }
        return self.fail(loc, "'-' requires numeric operand", error.TypeMismatch);
    }
};

test "vm arithmetic: (2 + 3) * 4 = 20" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const k2 = try chunk.addConstant(Value{ .integer = .{ .value = 2, .type_tag = .i32 } });
    const k3 = try chunk.addConstant(Value{ .integer = .{ .value = 3, .type_tag = .i32 } });
    const k4 = try chunk.addConstant(Value{ .integer = .{ .value = 4, .type_tag = .i32 } });
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k2);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k3);
    try chunk.writeOp(.op_add, loc);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k4);
    try chunk.writeOp(.op_mul, loc);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 0);
    defer result.releaseVM(allocator);
    try std.testing.expectEqual(@as(u128, 20), result.integer.value);
}

test "vm local variable: slot store + load" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    // 局部槽 0 = 10；读 slot0 + 5 = 15
    const k10 = try chunk.addConstant(Value{ .integer = .{ .value = 10, .type_tag = .i32 } });
    const k5 = try chunk.addConstant(Value{ .integer = .{ .value = 5, .type_tag = .i32 } });
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k10);
    try chunk.writeOp(.op_set_local, loc);
    try chunk.writeU16(0);
    try chunk.writeOp(.op_get_local, loc);
    try chunk.writeU16(0);
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k5);
    try chunk.writeOp(.op_add, loc);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 1); // 1 个局部槽
    defer result.releaseVM(allocator);
    try std.testing.expectEqual(@as(u128, 15), result.integer.value);
}

test "vm jump: if false skips" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    // 所有权移交 runChunkForTest 的 Program，勿在此 deinit（避免 double-free）
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    // push false; jump_if_false -> L; push 99 (skipped); L: pop cond; push 7; return
    const k99 = try chunk.addConstant(Value{ .integer = .{ .value = 99, .type_tag = .i32 } });
    const k7 = try chunk.addConstant(Value{ .integer = .{ .value = 7, .type_tag = .i32 } });
    try chunk.writeOp(.op_false, loc);
    const j = try chunk.emitJump(.op_jump_if_false, loc);
    try chunk.writeOp(.op_const, loc); // 被跳过
    try chunk.writeU16(k99);
    chunk.patchJump(j);
    try chunk.writeOp(.op_pop, loc); // 弹 cond(false)
    try chunk.writeOp(.op_const, loc);
    try chunk.writeU16(k7);
    try chunk.writeOp(.op_return, loc);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try runChunkForTest(&vm, allocator, chunk, 0);
    defer result.releaseVM(allocator);
    try std.testing.expectEqual(@as(u128, 7), result.integer.value);
}

/// 测试 helper：把一个裸 chunk 包成单函数 Program（arity=0, slot_count=N）并执行。
/// 接管 chunk 所有权（放入 Program，由 Program.deinit 释放）。
fn runChunkForTest(vm: *VM, allocator: std.mem.Allocator, chunk: Chunk, slot_count: u16) VMError!Value {
    var program = Program.init(allocator);
    defer program.deinit();
    _ = try program.addFunction(.{ .chunk = chunk, .arity = 0, .slot_count = slot_count });
    return vm.call(&program, 0, &.{});
}