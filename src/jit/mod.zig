//! JIT 编译引擎入口。
//!
//! 负责热点函数检测、JIT 编译调度和编译后代码的缓存。
//! 运行时统计函数调用次数，超过阈值后触发 JIT 编译，
//! 后续调用直接执行原生机器码。

const std = @import("std");
const ir = @import("ir.zig");
const backend_mod = @import("backend.zig");
const mem_mod = @import("mem.zig");
const arch = @import("arch/mod.zig");
const runtime = @import("runtime/mod.zig");
const reg_vm = @import("reg_vm");
const reg_chunk = reg_vm.reg_chunk_mod;
const value = @import("value");

/// 当前平台的 JIT 后端实例（编译期选定）。
const backend: *const backend_mod.JitBackend = arch.selectBackend();

/// JIT 编译后的函数入口。
pub const CompiledFn = struct {
    /// 函数入口地址（可执行内存中的机器码地址）。
    entry: usize,
    /// 函数参数数量。
    arity: u8,
    /// 返回值类型（0=i64, 1=f64, 2=void/unit，0xFF=bridge 模式）。
    return_type: u8,
    /// 拥有的可执行内存块（per-function，保持存活）。
    exec_mem: mem_mod.ExecMemory,
    /// 是否为桥接模式（true=直接操作 reg_pool，false=旧 IR 模式返回 i64）。
    bridge: bool = false,

    /// 释放底层可执行内存。
    pub fn deinit(self: *CompiledFn) void {
        self.exec_mem.deinit();
    }
};

/// 热点阈值：首次调用即编译（ aggressive JIT 策略）。
/// 对于只调用一次但内部有热循环的函数（如 nestedLoop），也能受益。
pub const HOT_THRESHOLD: u32 = 1;

/// JIT 引擎，管理热点检测和编译缓存。
pub const JitEngine = struct {
    allocator: std.mem.Allocator,
    /// 已编译函数缓存（函数索引 → 编译结果，null=未编译）。
    /// CompiledFn 拥有自己的 exec_mem，存储在数组中保持存活。
    compiled: []?CompiledFn = &.{},
    /// 编译失败的函数集合（避免重复尝试）。
    failed: []bool = &.{},
    /// 函数调用计数器（按函数索引）。
    call_counts: []u32 = &.{},
    /// 正在编译中的函数（函数索引 → 预分配的入口地址），用于处理循环递归。
    /// 仅 IR 模式使用，桥接模式不涉及。
    compiling: std.AutoHashMap(u32, usize),
    /// 程序中的所有函数列表（用于查找 callee 信息）。
    functions: []const reg_chunk.RegFunction = &.{},

    /// 创建 JIT 引擎实例。
    pub fn init(allocator: std.mem.Allocator) JitEngine {
        return .{
            .allocator = allocator,
            .compiling = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    /// 绑定程序函数列表（在 VM 加载程序后调用）。
    /// 同时分配 compiled/failed/call_counts 数组，实现 O(1) 查找。
    pub fn setFunctions(self: *JitEngine, funcs: []const reg_chunk.RegFunction) void {
        self.functions = funcs;
        const n = funcs.len;
        // 释放旧数组（如果已有）
        if (self.compiled.len > 0) {
            for (self.compiled) |*maybe_cfn| {
                if (maybe_cfn.*) |*cfn| cfn.deinit();
            }
            self.allocator.free(self.compiled);
        }
        if (self.failed.len > 0) self.allocator.free(self.failed);
        if (self.call_counts.len > 0) self.allocator.free(self.call_counts);
        // 分配新数组
        self.compiled = self.allocator.alloc(?CompiledFn, n) catch return;
        self.failed = self.allocator.alloc(bool, n) catch return;
        self.call_counts = self.allocator.alloc(u32, n) catch return;
        @memset(self.compiled, null);
        @memset(self.failed, false);
        @memset(self.call_counts, 0);
    }

    pub fn deinit(self: *JitEngine) void {
        // 释放所有已编译函数的可执行内存
        if (self.compiled.len > 0) {
            for (self.compiled) |*maybe_cfn| {
                if (maybe_cfn.*) |*cfn| cfn.deinit();
            }
            self.allocator.free(self.compiled);
        }
        if (self.failed.len > 0) self.allocator.free(self.failed);
        if (self.call_counts.len > 0) self.allocator.free(self.call_counts);
        self.compiling.deinit();
    }

    /// 记录函数调用，返回已编译函数入口（如果已 JIT 编译）。
    pub fn recordCall(self: *JitEngine, func_idx: u32) ?*const CompiledFn {
        if (func_idx >= self.compiled.len) return null;
        // 已编译则直接返回
        if (self.compiled[func_idx]) |*cfn| {
            return cfn;
        }

        // 已知编译失败，不再尝试
        if (self.failed[func_idx]) return null;

        // 增加调用计数
        self.call_counts[func_idx] += 1;

        // 未达阈值不编译
        return null;
    }

    /// 检查函数是否应该被 JIT 编译（达到热点阈值且未编译过）。
    pub fn shouldCompile(self: *const JitEngine, func_idx: u32) bool {
        if (func_idx >= self.compiled.len) return false;
        if (self.compiled[func_idx] != null) return false;
        if (self.failed[func_idx]) return false;
        return self.call_counts[func_idx] >= HOT_THRESHOLD;
    }

    /// JIT 编译指定函数。
    /// 成功返回编译结果指针（缓存在 engine 中），失败返回 null。
    /// 通过 JitBackend 接口分派到当前平台的具体实现：
    /// - ARM64: 桥接模式（直接从字节码生成机器码）
    /// - x86-64: IR 模式（IR 提升 + 寄存器分配 + 递归编译）
    /// - RISC-V 64: 桥接模式（直接从字节码生成机器码）
    pub fn compileFunction(self: *JitEngine, func_idx: u32, func: *const reg_chunk.RegFunction) ?*const CompiledFn {
        if (func_idx >= self.compiled.len) return null;
        // 已编译则直接返回
        if (self.compiled[func_idx]) |*cfn| return cfn;

        // 已知失败
        if (self.failed[func_idx]) return null;

        // 通过架构无关接口分派到具体后端
        const result = backend.compileFn(
            @ptrCast(self),
            func_idx,
            @ptrCast(func),
        );
        return @ptrCast(@alignCast(result));
    }

    /// 尝试用 JIT 编译后的代码执行函数（IR 模式）。
    /// 成功返回 i64 结果，失败返回 null（调用方应回退到解释器）。
    /// 参数为 value.Value 数组，通过统一 Value 数组调用约定传递。
    pub fn tryCall(self: *JitEngine, func_idx: u32, args: []const value.Value) ?i64 {
        if (func_idx >= self.compiled.len) return null;
        const cfn_opt = &self.compiled[func_idx];
        if (cfn_opt.*) |*cfn| {
            const result = callCompiledValue(cfn, args);
            return @bitCast(result);
        }
        return null;
    }
};

/// 调用 IR 模式 JIT 函数（统一 Value 数组调用约定）。
/// 参数通过 *const value.Value 数组传递，返回 u64。
fn callCompiledValue(cfn: *const CompiledFn, args: []const value.Value) u64 {
    var val_args: [6]value.Value = .{value.Value.fromUnit()} ** 6;
    const argc = @min(args.len, cfn.arity);
    for (args[0..argc], 0..) |val, i| {
        val_args[i] = val;
    }
    return callRawValue(cfn.entry, &val_args);
}

/// 调用接收 *const value.Value 数组的 JIT 函数。
fn callRawValue(entry: usize, args: *const [6]value.Value) u64 {
    const F = *const fn (*const value.Value) callconv(.c) u64;
    const f: F = @ptrFromInt(entry);
    return f(@ptrCast(args));
}

/// 将 i64 结果包装为 value.Value。
pub fn wrapI64Result(result: i64) value.Value {
    return value.Value.fromInt(value.Int.fromNative(.i64, result));
}

/// 将 f64 结果包装为 value.Value。
pub fn wrapF64Result(result: f64) value.Value {
    return value.Value.fromFloat(value.Float.fromNative(.f64, result));
}

/// 调用桥接模式 JIT 编译的函数。
/// entry: JIT 编译后的函数入口地址
/// vm: VM 指针, base: 寄存器基址
/// JIT 代码直接操作 reg_pool，返回值由 return_op 写入返回槽位。
pub fn callBridge(vm: *reg_vm.reg_vm.RegVM, entry: usize, base: usize) void {
    vm.bridge_depth += 1;
    defer vm.bridge_depth -= 1;
    const F = *const fn (*reg_vm.reg_vm.RegVM, usize) callconv(.c) void;
    const f: F = @ptrFromInt(entry);
    f(vm, base);
}

/// JIT 统一调用入口（供 VM 使用）。
/// VM 需根据 cfn.bridge 决定是否预先 setupFrame：
/// - 桥接模式（cfn.bridge == true）：VM 需先 setupFrame(callee, args, return_base, return_reg)
/// - IR 模式（cfn.bridge == false）：VM 无需 setupFrame
/// 结果统一写入 reg_pool[return_base + return_reg]。
pub fn invokeJit(
    vm: *reg_vm.reg_vm.RegVM,
    cfn: *const CompiledFn,
    args: []const value.Value,
    return_base: usize,
    return_reg: u8,
) void {
    if (cfn.bridge) {
        // 桥接模式：VM 已 setupFrame，获取 callee_base 并调用原生代码
        const callee_base = vm.frames.items[vm.frames.items.len - 1].base;
        callBridge(vm, cfn.entry, callee_base);
    } else {
        // IR 模式：统一 Value 数组调用约定
        vm.reg_pool[return_base + return_reg].release(vm.allocator);
        const result = callCompiledValue(cfn, args);
        switch (cfn.return_type) {
            1 => {
                // f64 返回值：u64 bitcast 为 f64
                const f64_result: f64 = @bitCast(result);
                vm.reg_pool[return_base + return_reg] = wrapF64Result(f64_result);
            },
            2 => {
                // void/unit 返回值
                vm.reg_pool[return_base + return_reg] = value.Value.fromUnit();
            },
            else => {
                // i64 返回值
                vm.reg_pool[return_base + return_reg] = wrapI64Result(@bitCast(result));
            },
        }
    }
}

test "JIT 引擎基础" {
    var engine = JitEngine.init(std.testing.allocator);
    defer engine.deinit();

    // 手动分配数组（模拟 setFunctions 的效果，无需真实 RegFunction）
    engine.compiled = try std.testing.allocator.alloc(?CompiledFn, 2);
    engine.failed = try std.testing.allocator.alloc(bool, 2);
    engine.call_counts = try std.testing.allocator.alloc(u32, 2);
    @memset(engine.compiled, null);
    @memset(engine.failed, false);
    @memset(engine.call_counts, 0);

    // 未编译的函数应返回 null
    try std.testing.expect(engine.recordCall(0) == null);

    // 模拟调用达到阈值
    for (0..HOT_THRESHOLD) |_| {
        _ = engine.recordCall(0);
    }
    try std.testing.expect(engine.shouldCompile(0));
}
