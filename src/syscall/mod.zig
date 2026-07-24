//! Glue syscall 分派模块
//!
//! Glue 用户代码 → stdlib 业务层 → __ 前缀 syscall 原语 → 本模块分派。
//! syscall_call 节点的 meta_index 索引 GlueIR.syscall_metas 表得到 SyscallId，
//! Engine.execSyscall 调用本模块的 dispatch 函数按 SyscallId 路由到 io/time 实现。
//!
//! 分层职责：
//! - builtin 类型层（src/builtin/）：IOError/TimeError 等 error_newtype 定义
//! - syscall 原语层（本模块）：宿主 syscall 包装，构造错误用 makeError+makeThrow
//! - stdlib 业务层（src/stdlib/）：File/Path/Duration 等高层 API（Phase 后续）
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ir_mod = @import("ir");

pub const io = @import("io.zig");
pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const util = @import("util.zig");

pub const SyscallId = ir_mod.SyscallId;

/// syscall 执行错误集（IO/Time 实现返回的错误类型）
///
/// 设计：syscall 实现自身仅返回基础设施错误（内存分配失败），
/// 业务错误（如文件不存在）通过返回 ThrowValue.err 传递给上层。
pub const SyscallError = error{
    OutOfMemory,
    InvalidArgument,
    TooManyPools,
    AllocFailed,
};

/// syscall 分派函数：按 SyscallId 路由到对应实现
///
/// 调用方：Engine.execSyscall
/// 参数：
///   - tctx：线程上下文（用于对象分配）
///   - id：syscall 标识（从 SyscallMeta 读取）
///   - args：参数 Value 切片（按 spec 顺序）
/// 返回：syscall 产出的 Value（可能是 Throw 值、标量或堆对象）
pub fn dispatch(io_inst: std.Io, tctx: *ThreadContext, id: SyscallId, args: []const Value) SyscallError!Value {
    return switch (id) {
        // IO syscall
        .file_open => io.file_open(io_inst, tctx, args),
        .file_close => io.file_close(io_inst, tctx, args),
        .file_read => io.file_read(io_inst, tctx, args),
        .file_write => io.file_write(io_inst, tctx, args),
        .file_seek => io.file_seek(io_inst, tctx, args),
        .file_tell => io.file_tell(io_inst, tctx, args),
        .file_stat => io.file_stat(io_inst, tctx, args),
        .file_fstat => io.file_fstat(io_inst, tctx, args),
        .file_remove => io.file_remove(io_inst, tctx, args),
        .file_rename => io.file_rename(io_inst, tctx, args),
        .file_chmod => io.file_chmod(io_inst, tctx, args),
        .dir_create => io.dir_create(io_inst, tctx, args),
        .dir_remove => io.dir_remove(io_inst, tctx, args),
        .dir_list => io.dir_list(io_inst, tctx, args),

        // Time syscall
        .instant_now_ns => time.instant_now_ns(io_inst, tctx, args),
        .systemtime_now_ns => time.systemtime_now_ns(io_inst, tctx, args),
        .sleep_ns => time.sleep_ns(io_inst, tctx, args),
        .localtime_offset_minutes => time.localtime_offset_minutes(io_inst, tctx, args),
        .systemtime_to_local_components => time.systemtime_to_local_components(io_inst, tctx, args),
        .systemtime_to_utc_components => time.systemtime_to_utc_components(io_inst, tctx, args),
        .components_to_ns_utc => time.components_to_ns_utc(io_inst, tctx, args),

        // Net syscall
        .net_resolve => net.net_resolve(io_inst, tctx, args),
        .net_tcp_listen => net.net_tcp_listen(io_inst, tctx, args),
        .net_tcp_accept => net.net_tcp_accept(io_inst, tctx, args),
        .net_tcp_connect => net.net_tcp_connect(io_inst, tctx, args),
        .net_tcp_read => net.net_tcp_read(io_inst, tctx, args),
        .net_tcp_write => net.net_tcp_write(io_inst, tctx, args),
        .net_tcp_close => net.net_tcp_close(io_inst, tctx, args),
        .net_udp_bind => net.net_udp_bind(io_inst, tctx, args),
        .net_udp_send_to => net.net_udp_send_to(io_inst, tctx, args),
        .net_udp_recv_from => net.net_udp_recv_from(io_inst, tctx, args),
    };
}

test {
    _ = io;
    _ = time;
    _ = net;
    _ = util;
}
