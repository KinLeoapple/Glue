//! 架构分派模块。
//!
//! 根据编译目标平台选择对应的 JIT 后端，并提供桥接模式兼容性检查。
//! 各架构实现在 arm64.zig / x86_64.zig / riscv64.zig / loongarch64.zig 中，通过 backend_instance 暴露。

const builtin = @import("builtin");
const backend_mod = @import("../backend.zig");
const reg_chunk = @import("reg_vm").reg_chunk_mod;

const arm64 = @import("arm64.zig");
const x86_64 = @import("x86_64.zig");
const riscv64 = @import("riscv64.zig");
const loongarch64 = @import("loongarch64.zig");

/// 根据当前编译目标平台选择 JIT 后端实例。
pub fn selectBackend() *const backend_mod.JitBackend {
    return switch (builtin.cpu.arch) {
        .aarch64 => &arm64.backend_instance,
        .x86_64 => &x86_64.backend_instance,
        .riscv64 => &riscv64.backend_instance,
        .loongarch64 => &loongarch64.backend_instance,
        else => @compileError("JIT not supported on this architecture"),
    };
}

/// 检查函数字节码是否包含桥接模式无法安全处理的复杂 opcode。
/// 包含以下模式的函数回退到解释器以确保正确性：
/// - 闭包/upvalue：CPS 风格递归闭包在桥接模式下存在 stop_depth/帧管理交互问题
/// - 动态分派：call_value 依赖运行时类型，无法静态编译
/// - 尾调用：tail_call 帧替换语义复杂
/// - 异常：throw_op 跨帧传播
/// - 并发：spawn 涉及线程调度
pub fn containsClosureOps(func: *const reg_chunk.RegFunction) bool {
    const reg_opcode = @import("reg_vm").reg_opcode;
    for (func.chunk.code.items) |inst| {
        switch (reg_opcode.getOp(inst)) {
            .closure,
            .get_upvalue,
            .set_upvalue,
            .call_value,
            .tail_call,
            .throw_op,
            .spawn,
            => return true,
            else => {},
        }
    }
    return false;
}
