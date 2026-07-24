//! syscall 共享工具：错误构造 + 超时包装
//!
//! 从 io.zig 抽取的 IOErrorKind/errToKind/makeIOError/makeThrowOk/makeThrowErr
//! 供 io.zig / net.zig 共享。
//!
//! 设计参考：docs/superpowers/specs/2026-07-24-net-io-design.md 第 4 节

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ErrorValue = value.ErrorValue;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;

const Io = std.Io;

// ──────────────────────────────────────────────
// 错误构造工具（从 io.zig 抽取，io.zig/net.zig 共享）
// ──────────────────────────────────────────────

/// IOErrorKind 枚举（与 IOError.glue 中 ADT 变体一一对应，0-indexed）
pub const IOErrorKind = enum(u8) {
    not_found = 0,
    permission_denied,
    already_exists,
    busy,
    invalid_input,
    unexpected_eof,
    broken_pipe,
    out_of_memory,
    interrupted,
    other,
    // ── Net 新增（10-19）──
    connection_refused = 10,
    connection_reset,
    connection_aborted,
    not_connected,
    addr_in_use,
    addr_not_available,
    timed_out,
    host_unreachable,
    network_unreachable,
    network_down,
};

/// std.Io 错误（anyerror）→ IOErrorKind 归一化映射
pub fn errToKind(err: anyerror) IOErrorKind {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName, error.SymLinkLoop => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.PathAlreadyExists => .already_exists,
        error.FileBusy, error.WouldBlock => .busy,
        error.InvalidArgument, error.IsDir => .invalid_input,
        error.UnexpectedEof, error.EndOfStream, error.Truncated => .unexpected_eof,
        error.BrokenPipe => .broken_pipe,
        error.SystemResources, error.OutOfMemory, error.NoSpaceLeft => .out_of_memory,
        error.Interrupted => .interrupted,
        // ── Net 映射 ──
        error.ConnectionRefused => .connection_refused,
        error.ConnectionResetByPeer => .connection_reset,
        error.ConnectionAborted => .connection_aborted,
        error.NotConnected => .not_connected,
        error.SocketUnconnected => .not_connected,
        error.SocketNotBound => .not_connected,
        error.AddressInUse => .addr_in_use,
        error.AddressNotAvailable => .addr_not_available,
        error.AddressUnavailable => .addr_not_available,
        error.TimedOut => .timed_out,
        error.Timeout => .timed_out,
        error.HostUnreachable => .host_unreachable,
        error.NetworkUnreachable => .network_unreachable,
        error.NetworkDown => .network_down,
        error.NetworkSubsystemFailed => .network_down,
        // Future/Group cancel → timed_out（超时取消的统一映射）
        error.Canceled => .timed_out,
        else => .other,
    };
}

/// 构造 IOError 值（error_newtype，布局：__tag + 4 个用户字段）
///
/// IOError 是 error_newtype，IR 编译器注册 field_id：__tag=0, kind=1, msg=2, os_err=3, path=4。
/// 必须用 makeRecordWithNames 构造 RecordValue（含 __tag），与 time.zig 保持一致。
///
/// RC 语义：makeRecordWithNames 仅 memcpy 字段（窃取调用方引用，不主动 retain）。
/// fromStringBytes 返回 RC=1，直接交给 record 窃取，无需额外 retain（否则泄漏）。
pub fn makeIOError(tctx: *ThreadContext, kind: IOErrorKind, msg: []const u8, os_err: i32, path: ?[]const u8) SyscallError!Value {
    var fields: [5]Value = .{
        Value.fromI64(0), // fields[0] = __tag（error_newtype 固定 0）
        Value.fromU8(@intFromEnum(kind)), // fields[1] = kind
        try Value.fromStringBytes(tctx, msg), // fields[2] = msg（RC=1，由 record 窃取）
        Value.fromI32(os_err), // fields[3] = os_err
        if (path) |p| try Value.fromStringBytes(tctx, p) else Value.fromNull(), // fields[4] = path（RC=1，由 record 窃取）
    };
    const field_names: [5]?[]const u8 = .{ "__tag", "kind", "msg", "os_err", "path" };
    return Value.makeRecordWithNames(tctx, "IOError", &fields, &field_names) catch {
        // OOM：释放已分配的 msg/path Str（makeRecordWithNames 未窃取）
        fields[2].release(tctx);
        if (path != null) fields[4].release(tctx);
        return error.OutOfMemory;
    };
}

/// 构造 Throw.ok(value) 包装
///
/// RC 语义：窃取语义——makeThrow 直接 memcpy 窃取 v 的引用（RC=1）。
/// 所有调用方均为 `return makeThrowOk(tctx, val)` 形式，不再使用 v，故无需 retain。
/// 标量参数 retain 本就是 no-op；堆对象参数避免 retain 后泄漏 1 个引用。
pub fn makeThrowOk(tctx: *ThreadContext, v: Value) SyscallError!Value {
    return Value.makeThrow(tctx, .{ .ok = v }) catch {
        v.release(tctx); // OOM：释放 v 避免泄漏
        return error.OutOfMemory;
    };
}

/// 构造 Throw.err(IOError) 包装
///
/// IOError 现在是 RecordValue（含 __tag），msg 在 fields[2]。
/// 从 RecordValue 提取 msg 后构造 ErrorValue，包装为 Throw.err。
///
/// RC 语义：err_val 为窃取语义（调用方转移所有权）。提取 msg 后立即释放 err_val record；
/// makeError 返回 RC=1 的 ErrorValue，直接交 makeThrow 窃取，无需额外 retain。
pub fn makeThrowErr(tctx: *ThreadContext, err_val: Value) SyscallError!Value {
    const err_obj = err_val.asRef();
    // 提取 msg（借用，不改变 RC）
    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", err_obj));
    const msg_bytes = if (rec.fields.len > 2) switch (rec.fields[2]) {
        .ref => |o| if (o.type_tag == .str) blk: {
            const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", o));
            break :blk s.bytes();
        } else "",
        else => "",
    } else "";
    // 构造 ErrorValue（RC=1）
    const err_ev = Value.makeError(tctx, "io error", msg_bytes, true) catch {
        // OOM：释放 err_val（所有权已转移）
        value.obj_header.release(err_obj, tctx);
        return error.OutOfMemory;
    };
    // err_val 所有权已转移，释放 record（触发 deinit 释放其 msg/path 字段）
    value.obj_header.release(err_obj, tctx);
    // makeThrow 窃取 err_ev 的 RC=1
    const err_val_ptr: *ErrorValue = @alignCast(@fieldParentPtr("header", err_ev.asRef()));
    return Value.makeThrow(tctx, .{ .err = err_val_ptr }) catch {
        // OOM：释放 err_ev
        value.obj_header.release(err_ev.asRef(), tctx);
        return error.OutOfMemory;
    };
}

// ──────────────────────────────────────────────
// 超时包装工具
// ──────────────────────────────────────────────

/// op 函数签名约定：fn (Io, *ThreadContext, *anyopaque) anyerror!Value
/// 业务错误由 op 内部用 makeThrowErr 包装；基础设施错误（OOM）和取消（Canceled）向上传播。
/// runWithTimeout 接收 comptime 函数值（非指针），以满足 Io.Select.concurrent 的 ArgsTuple 构造要求。

/// Select 结果联合：op 完成或超时触发
///
/// op 字段保留 anyerror!Value 以兼容 Select.concurrent 的 union 初始化：
/// Io.Select 要求 field 类型与 function 返回类型一致，op 返回 anyerror!Value。
const SelectResult = union(enum) {
    op: anyerror!Value,
    timed_out: void,
};

/// 超时分支的 sleep 函数：睡眠 timeout_ns 后返回 void。
/// 被 cancel 时 Timeout.sleep 返回 error.Canceled，此处吞掉（Select.cancelDiscard 语义）。
fn sleepFn(io: Io, timeout_ns: u64) void {
    Io.Timeout.sleep(.{ .duration = .{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake,
    } }, io) catch {};
}

/// 包装 op 的执行，附加超时控制。
///
/// timeout_ns == 0 时直接在当前线程调用 op（无超时）。
/// timeout_ns > 0 时用 Io.Select 并发跑 op 与 sleep：
///   - op 先完成 → 返回 op 结果（cancelDiscard 取消 sleep）
///   - sleep 先完成 → cancelDiscard 取消 op，返回 TimedOut IOError
///
/// 线程安全：op 通过 Select.concurrent 在 Io 线程池跑，访问调用方的 tctx。
/// 调用方（orbit worker）在 Select.await 处阻塞，不触碰 tctx，故无数据竞争。
/// op 内部 catch Canceled 并转为 Throw.err(timed_out)，cancelDiscard 丢弃该 Value，
/// 其内存在 tctx 析构时回收。
///
/// 设计参考：docs/superpowers/specs/2026-07-24-net-io-design.md 第 1.3 节
pub fn runWithTimeout(
    io: Io,
    tctx: *ThreadContext,
    timeout_ns: u64,
    /// comptime 函数值（非函数指针）：Io.Select.concurrent 要求 @TypeOf(function)
    /// 为函数类型以构造 ArgsTuple。传函数字面量（如 readOp）时保持函数类型。
    comptime op: anytype,
    op_ctx: *anyopaque,
) SyscallError!Value {
    // 无超时：直接在当前线程调用
    if (timeout_ns == 0) {
        return op(io, tctx, op_ctx) catch |err| {
            return wrapOpError(tctx, err);
        };
    }

    // 有超时：用 Io.Select 竞速 op vs sleep
    var results_buf: [2]SelectResult = undefined;
    var sel = Io.Select(SelectResult).init(io, &results_buf);

    // spawn op（Io 线程池跑）
    sel.concurrent(.op, op, .{ io, tctx, op_ctx }) catch {
        // ConcurrencyUnavailable：退化为直接调用（无超时保护）
        return op(io, tctx, op_ctx) catch |err| {
            return wrapOpError(tctx, err);
        };
    };
    // spawn sleep（Io 线程池跑）
    sel.concurrent(.timed_out, sleepFn, .{ io, timeout_ns }) catch {
        // ConcurrencyUnavailable：取消已 spawn 的 op，退化为直接调用
        sel.cancelDiscard();
        return op(io, tctx, op_ctx) catch |err| {
            return wrapOpError(tctx, err);
        };
    };

    // 等待先完成者
    const first = sel.await() catch {
        // Select 自身被取消：取消所有任务，返回超时
        sel.cancelDiscard();
        const io_err = try makeIOError(tctx, .timed_out, "operation canceled", 0, null);
        return makeThrowErr(tctx, io_err);
    };

    switch (first) {
        .op => |op_result| {
            // op 先完成：取消 sleep
            sel.cancelDiscard();
            return op_result catch |err| {
                return wrapOpError(tctx, err);
            };
        },
        .timed_out => {
            // sleep 先完成：取消 op，返回 TimedOut
            sel.cancelDiscard();
            const io_err = try makeIOError(tctx, .timed_out, "operation timed out", 0, null);
            return makeThrowErr(tctx, io_err);
        },
    }
}

/// 将 op 返回的错误包装为 IOError Throw。
/// Canceled → timed_out；其他错误经 errToKind 归一化。
/// OOM（makeIOError 内部失败）向上传播为 SyscallError.OutOfMemory。
inline fn wrapOpError(tctx: *ThreadContext, err: anyerror) SyscallError!Value {
    const kind: IOErrorKind = if (err == error.Canceled) .timed_out else errToKind(err);
    const io_err = try makeIOError(tctx, kind, "operation failed", 0, null);
    return makeThrowErr(tctx, io_err);
}
