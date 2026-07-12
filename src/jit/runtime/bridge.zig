//! C-ABI 桥接函数（架构无关）。
//!
//! 为 JIT 编译的代码提供 C-ABI 桥接函数，使 JIT 代码能够：
//! 1. 通过 rt_step 委托 VM 执行单条非控制流指令（冷门 opcode）
//! 2. 通过 rt_call_inline / rt_call 调用任意函数（JIT 编译或解释执行）
//! 3. 通过 rt_get_i64 / rt_set_i64 直接读写 reg_pool 中的 i64 值
//! 4. 通过 rt_array_push / rt_array_len 执行数组操作
//!
//! 桥接函数接收 VM 指针和寄存器槽位索引，直接操作 reg_pool，
//! 结果写回 reg_pool 对应槽位，无需 Value 结构体返回。

const std = @import("std");
const value = @import("value");
const reg_vm_mod = @import("reg_vm");

const RegVM = reg_vm_mod.reg_vm.RegVM;

/// 执行当前帧的一条指令（冷门 opcode 的桥接入口）。
///
/// vm: VM 指针, ip: 指令在当前帧中的索引
/// 返回: false = 指令已执行（JIT 继续），true = 函数已返回或尾调用（JIT 应退出）
///
/// 自动处理三类情况：
/// 1. 普通指令：单步执行，帧不变
/// 2. 返回指令：单步执行，帧弹出 → 返回 true
/// 3. 尾调用：单步执行，帧被替换 → 返回 true
/// 4. 调用指令：单步执行后帧增加 → 运行被调用函数至完成 → 返回 false
pub export fn rt_step(vm: *RegVM, ip: usize) callconv(.c) bool {
    const frame = &vm.frames.items[vm.frames.items.len - 1];
    frame.ip = ip;
    const initial_frames = vm.frames.items.len;
    const initial_func = frame.func;
    const initial_base = frame.base;

    _ = vm.jitStepOnce() catch return true;

    // 情况 1：函数返回（帧弹出，帧数减少）
    // return_op/return_unit/throw_op/propagate 始终写入返回槽位，无需补偿
    if (vm.frames.items.len < initial_frames) {
        return true;
    }

    // 情况 2：尾调用（帧被替换，帧数不变但函数或基址不同）
    if (vm.frames.items.len == initial_frames) {
        const cur_frame = vm.frames.items[vm.frames.items.len - 1];
        // 检测帧替换：函数不同，或基址不同（跨函数尾调用），或 ip 被重置为 0（同函数尾递归）
        if (cur_frame.func != initial_func or cur_frame.base != initial_base or
            (cur_frame.func == initial_func and cur_frame.ip == 0 and ip != 0))
        {
            // 尾调用：tail_call handler 仅替换了帧但未执行 callee。
            // 需运行 callee 至完成（return_base/return_reg 已指向原始调用者槽位）。
            const saved_stop = vm.stop_depth;
            vm.stop_depth = initial_frames; // 当 callee 帧返回时停止
            const result = vm.jitRunLoop() catch {
                vm.stop_depth = saved_stop;
                return true;
            };
            vm.stop_depth = saved_stop;
            // return_op 已将返回值写入 return_base+return_reg，释放 result 的额外 retain
            result.release(vm.allocator);
            return true;
        }
        // 普通指令，帧不变
        return false;
    }

    // 情况 3：调用类指令（帧增加，被调用函数尚未执行）
    // 保存返回槽位信息（被调用帧的 return_base/return_reg 指向 JIT 帧的寄存器）
    const callee_frame = vm.frames.items[vm.frames.items.len - 1];
    const ret_base = callee_frame.return_base;
    const ret_reg = callee_frame.return_reg;

    // 运行被调用函数至完成
    const saved_stop = vm.stop_depth;
    vm.stop_depth = initial_frames + 1; // 当被调用帧返回时停止
    const result = vm.jitRunLoop() catch {
        vm.stop_depth = saved_stop;
        return true;
    };
    vm.stop_depth = saved_stop;

    // 将返回值写入调用者（JIT 帧）的返回槽位
    // result 带 +1 retain（return_op 中 retain 转移给 result），写入寄存器即转移所有权
    vm.reg_pool[ret_base + ret_reg].release(vm.allocator);
    vm.reg_pool[ret_base + ret_reg] = result;

    // 检查 JIT 帧本身是否在调用过程中返回
    if (vm.frames.items.len < initial_frames) return true;

    // 被调用函数已完成，JIT 帧仍然活跃
    return false;
}

/// JIT 内联调用：为 .call 指令提供快速路径，跳过 jitStepOnce 的单步开销。
/// 直接设置帧并运行被调用函数至完成，返回值写入 return_base+return_reg。
/// 如果被调用函数已 JIT 编译，直接通过 callBridge 调用原生代码。
/// 返回 false = JIT 帧仍然活跃，继续执行下一条指令。
/// 返回 true = JIT 帧已返回（不应发生于普通 call，但安全起见保留）。
pub export fn rt_call_inline(vm: *RegVM, func_idx: u32, args_base: usize, argc: u8, return_base: usize, return_reg: u8) callconv(.c) bool {
    const program = vm.program orelse return true;
    if (func_idx >= program.functions.items.len) return true;
    const callee = &program.functions.items[func_idx];

    // 从 reg_pool 提取参数
    var args_buf: [16]value.Value = undefined;
    const n: usize = @min(argc, 16);
    for (0..n) |i| {
        args_buf[i] = vm.reg_pool[args_base + i];
    }

    const initial_frames = vm.frames.items.len;

    // JIT 快速路径：检查被调用函数是否已编译
    if (vm.jit_engine) |*je| {
        if (func_idx < je.compiled.len) {
            if (je.compiled[func_idx]) |*cfn| {
                if (cfn.bridge and vm.bridge_depth < 50) {
                    vm.setupFrame(callee, args_buf[0..n], return_base, return_reg) catch return true;
                    const callee_base = vm.frames.items[vm.frames.items.len - 1].base;
                    vm.bridge_depth += 1;
                    defer vm.bridge_depth -= 1;
                    const F = *const fn (*RegVM, usize) callconv(.c) void;
                    const f: F = @ptrFromInt(cfn.entry);
                    f(vm, callee_base);
                    // return_op 已将返回值写入 return_base+return_reg
                    return vm.frames.items.len < initial_frames;
                }
            } else {
                // 尝试 JIT 编译
                _ = je.recordCall(func_idx);
                if (je.shouldCompile(func_idx)) {
                    if (je.compileFunction(func_idx, callee)) |cfn| {
                        if (cfn.bridge and vm.bridge_depth < 50) {
                            vm.setupFrame(callee, args_buf[0..n], return_base, return_reg) catch return true;
                            const callee_base = vm.frames.items[vm.frames.items.len - 1].base;
                            vm.bridge_depth += 1;
                            defer vm.bridge_depth -= 1;
                            const F = *const fn (*RegVM, usize) callconv(.c) void;
                            const f: F = @ptrFromInt(cfn.entry);
                            f(vm, callee_base);
                            return vm.frames.items.len < initial_frames;
                        }
                    }
                }
            }
        }
    }

    // 回退：解释执行
    vm.setupFrame(callee, args_buf[0..n], return_base, return_reg) catch return true;

    // 运行被调用函数至完成
    const saved_stop = vm.stop_depth;
    vm.stop_depth = initial_frames + 1;
    const result = vm.jitRunLoop() catch {
        vm.stop_depth = saved_stop;
        return true;
    };
    vm.stop_depth = saved_stop;

    // 将返回值写入调用者的返回槽位
    vm.reg_pool[return_base + return_reg].release(vm.allocator);
    vm.reg_pool[return_base + return_reg] = result;

    // 检查 JIT 帧本身是否在调用过程中返回
    return vm.frames.items.len < initial_frames;
}

/// 调用任意函数（JIT 编译或解释执行）。
/// vm: VM 指针, func_idx: 函数索引
/// args_base: 参数在 reg_pool 中的起始索引, argc: 参数数量
/// dst_slot: 返回值写入的 reg_pool 索引
pub export fn rt_call(vm: *RegVM, func_idx: u32, args_base: usize, argc: u8, dst_slot: usize) callconv(.c) void {
    // 从 reg_pool 提取参数（仅拷贝 Value 结构体，不 retain）
    var args_buf: [16]value.Value = undefined;
    const n: usize = @min(argc, 16);
    for (0..n) |i| {
        args_buf[i] = vm.reg_pool[args_base + i];
    }
    // jitCallFunction 返回的结果已带 +1 retain（return_op 中 retain）；
    // 释放 dst_slot 旧值后写入，引用计数正确。
    const result = vm.jitCallFunction(func_idx, args_buf[0..n], dst_slot, 0) catch {
        vm.reg_pool[dst_slot].release(vm.allocator);
        vm.reg_pool[dst_slot] = value.Value.fromNull();
        return;
    };
    vm.reg_pool[dst_slot].release(vm.allocator);
    vm.reg_pool[dst_slot] = result;
}

/// 构造 i64 Value 并写入指定槽位。
/// dst_slot: 目标 reg_pool 索引, val: i64 值
pub export fn rt_set_i64(vm: *RegVM, dst_slot: usize, val: i64) callconv(.c) void {
    vm.reg_pool[dst_slot] = value.Value.fromInt(value.Int.fromNative(.i64, val));
}

/// 从指定槽位读取 i64 值（不做类型检查，调用方需确保类型正确）。
/// slot: 源 reg_pool 索引
/// 返回: i64 值
pub export fn rt_get_i64(vm: *RegVM, slot: usize) callconv(.c) i64 {
    const v = vm.reg_pool[slot];
    return switch (v) {
        .int => |iv| blk: {
            if (iv.coerceTo(.i64)) |native| {
                break :blk native.toNative(i64);
            }
            break :blk @bitCast(iv.lo);
        },
        .boolean => |b| if (b) 1 else 0,
        else => 0,
    };
}

/// 数组 push 操作的 C-ABI 桥接：为 arr.push(elem) 分配新数组并返回。
/// recv_slot: 接收者数组在 reg_pool 中的索引
/// arg_slot: 要追加的元素在 reg_pool 中的索引
/// dst_slot: 结果写入的 reg_pool 索引
/// 返回: 0 = 成功, 非 0 = 失败（调用方应回退到 rt_step）
pub export fn rt_array_push(vm: *RegVM, recv_slot: usize, arg_slot: usize, dst_slot: usize) callconv(.c) u8 {
    const recv = vm.reg_pool[recv_slot];
    if (recv != .array) return 1;
    const arr = recv.array;
    const elem = vm.reg_pool[arg_slot];

    const new_len = arr.elements.len + 1;
    const new_elems = vm.allocator.alloc(value.Value, new_len) catch return 2;
    @memcpy(new_elems[0..arr.elements.len], arr.elements);
    new_elems[arr.elements.len] = elem.retain();

    const arr_ptr = vm.allocator.create(value.ArrayValue) catch {
        vm.allocator.free(new_elems);
        return 2;
    };
    arr_ptr.* = .{ .elements = new_elems, .capacity = new_elems.len, .fixed_size = null };

    vm.reg_pool[dst_slot].release(vm.allocator);
    vm.reg_pool[dst_slot] = value.Value{ .array = arr_ptr };
    return 0;
}

/// 数组 len 操作的 C-ABI 桥接：返回 arr.len()。
/// recv_slot: 接收者数组在 reg_pool 中的索引
/// dst_slot: 结果写入的 reg_pool 索引
/// 返回: 0 = 成功, 非 0 = 失败（调用方应回退到 rt_step）
pub export fn rt_array_len(vm: *RegVM, recv_slot: usize, dst_slot: usize) callconv(.c) u8 {
    const recv = vm.reg_pool[recv_slot];
    if (recv != .array) return 1;
    const len = recv.array.elements.len;
    const len_i32 = std.math.cast(i32, len) orelse return 2;
    vm.reg_pool[dst_slot].release(vm.allocator);
    vm.reg_pool[dst_slot] = value.Value.fromInt(value.Int.fromNative(.i32, len_i32));
    return 0;
}
