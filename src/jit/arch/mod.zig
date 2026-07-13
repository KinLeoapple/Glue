//! 架构分派模块。
//!
//! 根据编译目标平台选择对应的 JIT 后端，并提供桥接模式兼容性检查。
//! 各架构实现在 arm64.zig / x86_64.zig / riscv64.zig 中，通过 backend_instance 暴露。

const builtin = @import("builtin");
const backend_mod = @import("../backend.zig");
const reg_chunk = @import("reg_vm").reg_chunk_mod;

const arm64 = @import("arm64.zig");
const x86_64 = @import("x86_64.zig");
const riscv64 = @import("riscv64.zig");
const riscv32 = @import("riscv32.zig");

/// 根据当前编译目标平台选择 JIT 后端实例。
pub fn selectBackend() *const backend_mod.JitBackend {
    return switch (builtin.cpu.arch) {
        .aarch64 => &arm64.backend_instance,
        .x86_64 => &x86_64.backend_instance,
        .riscv64 => &riscv64.backend_instance,
        .riscv32 => &riscv32.backend_instance,
        else => @compileError("JIT not supported on this architecture"),
    };
}
