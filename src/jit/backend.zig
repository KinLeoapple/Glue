//! JIT 后端接口定义。
//!
//! 定义架构无关的后端接口 JitBackend，各架构（ARM64、x86-64）实现此接口。
//! 编译引擎通过统一接口分派到具体架构的后端实现，VM 侧无需感知底层架构。

const std = @import("std");
const ir = @import("ir.zig");
const regalloc = @import("regalloc.zig");
const mem = @import("mem.zig");

/// 物理寄存器标识。
pub const PhysReg = struct {
    id: u8,
    kind: Kind,

    pub const Kind = enum { gpr, fpr };

    /// 寄存器是否为整数寄存器。
    pub fn isGPR(self: PhysReg) bool {
        return self.kind == .gpr;
    }

    /// 寄存器是否为浮点寄存器。
    pub fn isFPR(self: PhysReg) bool {
        return self.kind == .fpr;
    }
};

/// 架构无关的 JIT 后端接口。
/// 各架构（ARM64、x86-64）通过提供 backend_instance 实现此接口。
/// 编译引擎通过此接口分派到具体架构，VM 侧无需感知底层架构。
///
/// compileFn 接收 engine_ctx（实际类型为 *JitEngine，使用 anyopaque 避免循环引用），
/// 各架构实现内部通过 @ptrCast 还原为 *JitEngine 以访问编译上下文
///（allocator、compiled、failed、functions、compiling 等）。
pub const JitBackend = struct {
    /// 编译函数为机器码。
    /// engine_ctx: *JitEngine（以 anyopaque 传递以打破循环依赖）
    /// func_idx: 函数索引, func: 函数定义
    /// 返回编译结果指针（已缓存到 engine 中），失败返回 null
    compileFn: *const fn (
        engine_ctx: *anyopaque,
        func_idx: u32,
        func: *const anyopaque, // *const reg_chunk.RegFunction
    ) ?*const anyopaque, // *const CompiledFn

    /// 该后端是否为桥接模式（影响 VM 调用前的帧管理）。
    /// true = 桥接模式（ARM64）：VM 需先 setupFrame
    /// false = IR 模式（x86-64）：VM 无需 setupFrame
    is_bridge: bool,
};

/// 旧 IR 模式的后端接口（供 x86-64 IR 代码生成器实现）。
/// 桥接模式（ARM64）不使用此接口，直接通过 JitBackend.compileFn 分派。
pub const Backend = struct {
    /// 返回该后端可用于分配的通用寄存器列表。
    availableGPRs: []const PhysReg,
    /// 返回该后端可用于分配的浮点寄存器列表。
    availableFPRs: []const PhysReg,
    /// 编译 IR 函数为机器码，写入 exec_mem。
    /// func_entries 提供已编译函数的入口地址（用于 JIT 内调用），
    /// 索引 0 表示未编译（调用时回退到解释器）。
    /// 返回编译后的函数入口地址。
    compileFn: *const fn (
        backend: *const Backend,
        allocator: std.mem.Allocator,
        func: *const ir.IRFunction,
        exec_mem: *mem.ExecMemory,
        func_entries: []const usize,
    ) anyerror!usize,

    /// 可用寄存器（GPR），供寄存器分配器使用。
    pub fn allAvailRegs(self: *const Backend) []const PhysReg {
        return self.availableGPRs;
    }
};
