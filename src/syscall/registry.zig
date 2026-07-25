//! Syscall 声明式注册表（唯一真相源）
//!
//! 将 syscall 的 ID/名字/返回类型/Ok 类型名/实现函数全部集中到此数组。
//! 新增 syscall 只需在 REGISTRY 加一行，无需修改 IR 层。
//!
//! 依赖方向：本模块仅依赖 value（Value/ThreadContext）和 io/time/net 实现，
//! 不依赖 ir 模块（ChanType 不在此处使用，改用 SyscallRetKind 解耦）。
//!
//! 运行时分派：REGISTRY[id] 数组索引，O(1)，无 hash/字符串比较。
//! 编译期名字查找：inline for 展开，运行时 0 开销。

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;

const io = @import("io.zig");
const time = @import("time.zig");
const net = @import("net.zig");

/// Syscall 执行错误集（IO/Time/Net 实现返回的错误类型）
///
/// syscall 实现自身仅返回基础设施错误（内存分配失败），
/// 业务错误（如文件不存在）通过返回 ThrowValue.err 传递给上层。
pub const SyscallError = error{
    OutOfMemory,
    InvalidArgument,
    TooManyPools,
    AllocFailed,
};

/// Syscall 返回类型分类（不依赖 ir.ChanType，实现 ir ↔ syscall 解耦）
///
/// ir 模块的 builder 通过 retKindToChanType 将此枚举转为 ChanType。
pub const SyscallRetKind = enum(u3) {
    /// 堆对象（ref_chan）：File/Dir/Throw/数组等
    ref,
    /// i128（纳秒）：时间 syscall
    i128,
    /// i32（分钟）：时区偏移
    i32,
    /// unit：无返回值
    unit,
};

/// Syscall 实现函数指针类型
pub const SyscallFn = *const fn (std.Io, *ThreadContext, []const Value) SyscallError!Value;

/// Syscall 注册条目
pub const SyscallEntry = struct {
    /// 函数名（带 __ 前缀，如 "__file_open"）
    name: []const u8,
    /// 返回类型分类（ir 层据此分配通道类型）
    ret_kind: SyscallRetKind,
    /// Throw<T, E> 中 T 的类型名；null 表示非 Throw 返回（time/sleep 等）
    ok_type_name: ?[]const u8,
    /// 实现函数指针
    impl: SyscallFn,
};

/// Syscall ID（u16，与 REGISTRY 数组索引一一对应）
///
/// 新增 syscall 时：
/// 1. 在 REGISTRY 数组末尾添加条目
/// 2. 在此 enum 末尾添加对应变体（顺序必须与 REGISTRY 严格对齐）
/// 3. comptime_assert 会校验长度一致
pub const SyscallId = enum(u16) {
    // IO
    file_open,
    file_close,
    file_read,
    file_write,
    file_read_async,
    file_write_async,
    file_seek,
    file_stat,
    file_fstat,
    file_remove,
    file_rename,
    file_chmod,
    dir_create,
    dir_remove,
    dir_list,
    // Time
    instant_now_ns,
    systemtime_now_ns,
    sleep_ns,
    sleep_async,
    localtime_offset_minutes,
    // Net
    net_resolve,
    net_tcp_listen,
    net_tcp_accept,
    net_tcp_accept_async,
    net_tcp_connect,
    net_tcp_read,
    net_tcp_read_async,
    net_tcp_write,
    net_tcp_write_async,
    net_tcp_close,
    net_udp_bind,
    net_udp_send_to,
    net_udp_recv_from,
    net_udp_recv_from_async,
};

/// 唯一的真相源：所有 syscall 的声明式注册表
///
/// 顺序必须与 SyscallId enum 变体顺序严格一致（comptime 校验）。
pub const REGISTRY = [_]SyscallEntry{
    // ── IO syscall ──
    .{ .name = "__file_open", .ret_kind = .ref, .ok_type_name = "File", .impl = io.file_open },
    .{ .name = "__file_close", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.file_close },
    .{ .name = "__file_read", .ret_kind = .ref, .ok_type_name = "u8[]", .impl = io.file_read },
    .{ .name = "__file_write", .ret_kind = .ref, .ok_type_name = "usize", .impl = io.file_write },
    .{ .name = "__file_read_async", .ret_kind = .ref, .ok_type_name = null, .impl = io.file_read_async },
    .{ .name = "__file_write_async", .ret_kind = .ref, .ok_type_name = null, .impl = io.file_write_async },
    .{ .name = "__file_seek", .ret_kind = .ref, .ok_type_name = "i64", .impl = io.file_seek },
    .{ .name = "__file_stat", .ret_kind = .ref, .ok_type_name = "Stat", .impl = io.file_stat },
    .{ .name = "__file_fstat", .ret_kind = .ref, .ok_type_name = "Stat", .impl = io.file_fstat },
    .{ .name = "__file_remove", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.file_remove },
    .{ .name = "__file_rename", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.file_rename },
    .{ .name = "__file_chmod", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.file_chmod },
    .{ .name = "__dir_create", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.dir_create },
    .{ .name = "__dir_remove", .ret_kind = .ref, .ok_type_name = "Unit", .impl = io.dir_remove },
    .{ .name = "__dir_list", .ret_kind = .ref, .ok_type_name = "DirEntry[]", .impl = io.dir_list },
    // ── Time syscall ──
    .{ .name = "__instant_now_ns", .ret_kind = .i128, .ok_type_name = null, .impl = time.instant_now_ns },
    .{ .name = "__systemtime_now_ns", .ret_kind = .i128, .ok_type_name = null, .impl = time.systemtime_now_ns },
    .{ .name = "__sleep_ns", .ret_kind = .unit, .ok_type_name = null, .impl = time.sleep_ns },
    .{ .name = "__sleep_async", .ret_kind = .ref, .ok_type_name = null, .impl = time.sleep_async },
    .{ .name = "__localtime_offset_minutes", .ret_kind = .i32, .ok_type_name = null, .impl = time.localtime_offset_minutes },
    // ── Net syscall ──
    .{ .name = "__net_resolve", .ret_kind = .ref, .ok_type_name = "IpAddr[]", .impl = net.net_resolve },
    .{ .name = "__net_tcp_listen", .ret_kind = .ref, .ok_type_name = "i64", .impl = net.net_tcp_listen },
    .{ .name = "__net_tcp_accept", .ret_kind = .ref, .ok_type_name = "AcceptResult", .impl = net.net_tcp_accept },
    .{ .name = "__net_tcp_accept_async", .ret_kind = .ref, .ok_type_name = null, .impl = net.net_tcp_accept_async },
    .{ .name = "__net_tcp_connect", .ret_kind = .ref, .ok_type_name = "i64", .impl = net.net_tcp_connect },
    .{ .name = "__net_tcp_read", .ret_kind = .ref, .ok_type_name = "u8[]", .impl = net.net_tcp_read },
    .{ .name = "__net_tcp_read_async", .ret_kind = .ref, .ok_type_name = null, .impl = net.net_tcp_read_async },
    .{ .name = "__net_tcp_write", .ret_kind = .ref, .ok_type_name = "usize", .impl = net.net_tcp_write },
    .{ .name = "__net_tcp_write_async", .ret_kind = .ref, .ok_type_name = null, .impl = net.net_tcp_write_async },
    .{ .name = "__net_tcp_close", .ret_kind = .ref, .ok_type_name = "Unit", .impl = net.net_tcp_close },
    .{ .name = "__net_udp_bind", .ret_kind = .ref, .ok_type_name = "i64", .impl = net.net_udp_bind },
    .{ .name = "__net_udp_send_to", .ret_kind = .ref, .ok_type_name = "usize", .impl = net.net_udp_send_to },
    .{ .name = "__net_udp_recv_from", .ret_kind = .ref, .ok_type_name = "RecvFromResult", .impl = net.net_udp_recv_from },
    .{ .name = "__net_udp_recv_from_async", .ret_kind = .ref, .ok_type_name = null, .impl = net.net_udp_recv_from_async },
};

// comptime 校验：SyscallId enum 变体数必须与 REGISTRY 长度一致
comptime {
    const enum_count = @typeInfo(SyscallId).@"enum".fields.len;
    std.debug.assert(enum_count == REGISTRY.len);
}

/// 按函数名查询 SyscallId（编译期 inline for 展开，运行时 0 开销）
///
/// IRBuilder 编译 `__` 前缀函数时调用此函数识别 syscall。
pub fn lookupByName(name: []const u8) ?SyscallId {
    inline for (REGISTRY, 0..) |entry, i| {
        if (std.mem.eql(u8, name, entry.name)) {
            return @enumFromInt(i);
        }
    }
    return null;
}

/// 按 SyscallId 查询返回类型分类
pub fn returnKind(id: SyscallId) SyscallRetKind {
    return REGISTRY[@intFromEnum(id)].ret_kind;
}

/// 按 SyscallId 查询 Throw<T, E> 中 T 的类型名
///
/// 非 Throw 返回的 syscall（time/sleep）返回 null。
pub fn okTypeName(id: SyscallId) ?[]const u8 {
    return REGISTRY[@intFromEnum(id)].ok_type_name;
}

/// Syscall 分派函数：按 SyscallId 路由到对应实现
///
/// 数组索引 + 间接函数调用，O(1)。无 switch，无 hash。
pub fn dispatch(io_inst: std.Io, tctx: *ThreadContext, id: SyscallId, args: []const Value) SyscallError!Value {
    return REGISTRY[@intFromEnum(id)].impl(io_inst, tctx, args);
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "REGISTRY 与 SyscallId 长度一致（comptime assert 兜底）" {
    try testing.expectEqual(@as(usize, 34), REGISTRY.len);
    try testing.expectEqual(@as(usize, 34), @typeInfo(SyscallId).@"enum".fields.len);
}

test "lookupByName 命中" {
    try testing.expectEqual(SyscallId.file_open, lookupByName("__file_open").?);
    try testing.expectEqual(SyscallId.net_udp_recv_from, lookupByName("__net_udp_recv_from").?);
    try testing.expectEqual(SyscallId.instant_now_ns, lookupByName("__instant_now_ns").?);
}

test "lookupByName 未命中" {
    try testing.expect(lookupByName("__unknown") == null);
    try testing.expect(lookupByName("file_open") == null); // 无 __ 前缀
}

test "returnKind 分类正确" {
    try testing.expectEqual(SyscallRetKind.ref, returnKind(.file_open));
    try testing.expectEqual(SyscallRetKind.i128, returnKind(.instant_now_ns));
    try testing.expectEqual(SyscallRetKind.i32, returnKind(.localtime_offset_minutes));
    try testing.expectEqual(SyscallRetKind.unit, returnKind(.sleep_ns));
    try testing.expectEqual(SyscallRetKind.ref, returnKind(.sleep_async));
    try testing.expectEqual(SyscallRetKind.ref, returnKind(.net_tcp_read));
}

test "okTypeName 命中与 null" {
    try testing.expectEqualStrings("File", okTypeName(.file_open).?);
    try testing.expectEqualStrings("u8[]", okTypeName(.file_read).?);
    try testing.expectEqualStrings("usize", okTypeName(.file_write).?);
    try testing.expectEqualStrings("DirEntry[]", okTypeName(.dir_list).?);
    try testing.expectEqualStrings("AcceptResult", okTypeName(.net_tcp_accept).?);
    // 非 Throw 返回的 syscall
    try testing.expect(okTypeName(.instant_now_ns) == null);
    try testing.expect(okTypeName(.sleep_ns) == null);
    try testing.expect(okTypeName(.localtime_offset_minutes) == null);
}
