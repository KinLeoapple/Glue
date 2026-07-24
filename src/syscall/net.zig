//! Glue Net syscall 原语（跨平台实现）
//!
//! 使用 std.Io.net（跨平台网络 API）。超时通过 util.runWithTimeout
//! 包装（Io.Select + concurrent + Timeout.sleep），engine 零改造。
//!
//! fd 模型：与 io.zig 一致，i64 跨平台存储 socket handle。
//! connect 超时：ConnectOptions.timeout 内建超时，无需手写 select。
//! accept/read/write/recv_from 超时：util.runWithTimeout 包装。
//!
//! 设计参考：docs/superpowers/specs/2026-07-24-net-io-design.md 第 3 节

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;
const util = @import("util.zig");

// 共享错误工具（io.zig/net.zig 共用）
const IOErrorKind = util.IOErrorKind;
const errToKind = util.errToKind;
const makeIOError = util.makeIOError;
const makeThrowOk = util.makeThrowOk;
const makeThrowErr = util.makeThrowErr;

const Io = std.Io;
const net = Io.net;
const IpAddress = net.IpAddress;
const Socket = net.Socket;
const Stream = net.Stream;
const Server = net.Server;

// ──────────────────────────────────────────────
// 辅助：从 Value 提取参数（与 io.zig 同模式）
// ──────────────────────────────────────────────

/// 从 Value 提取 bool
inline fn asBool(v: Value) bool {
    return switch (v) {
        .boolean => v.asBool(),
        else => false,
    };
}

/// 从 Value 提取字符串字节切片（Str 类型）
fn asStrBytes(v: Value) []const u8 {
    return switch (v) {
        .ref => |obj| blk: {
            if (obj.type_tag == .str) {
                const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", obj));
                break :blk s.bytes();
            }
            break :blk "";
        },
        else => "",
    };
}

/// 从 Value 提取 ArrayValue 指针（仅 array 类型）
fn asArray(v: Value) ?*value.ArrayValue {
    return switch (v) {
        .ref => |obj| blk: {
            if (obj.type_tag == .array) {
                break :blk @alignCast(@fieldParentPtr("header", obj));
            }
            break :blk null;
        },
        else => null,
    };
}

/// 从 Value 提取 RecordValue 指针（仅 record 类型）
fn asRecord(v: Value) ?*value.RecordValue {
    return switch (v) {
        .ref => |obj| blk: {
            if (obj.type_tag == .record) {
                break :blk @alignCast(@fieldParentPtr("header", obj));
            }
            break :blk null;
        },
        else => null,
    };
}

// ──────────────────────────────────────────────
// 辅助：跨平台 fd ↔ Socket 转换
// ──────────────────────────────────────────────

/// Socket.Handle = std.posix.fd_t（POSIX: i32，Windows: HANDLE 指针）
/// Glue 层用 i64 统一存储 fd，此处按 Handle 实际类型转换。
inline fn fdToSocketHandle(fd: i64) Socket.Handle {
    const H = Socket.Handle;
    switch (@typeInfo(H)) {
        .int => return @intCast(fd),
        .pointer => return @ptrFromInt(@as(usize, @intCast(fd))),
        else => @compileError("unsupported Socket.Handle type"),
    }
}

/// Socket → i64 fd
inline fn socketToFd(s: Socket) i64 {
    const H = Socket.Handle;
    switch (@typeInfo(H)) {
        .int => return @intCast(s.handle),
        .pointer => return @intCast(@intFromPtr(s.handle)),
        else => @compileError("unsupported Socket.Handle type"),
    }
}

/// i64 fd → Socket（address 设为 ip4 unspecified，仅 read/write/close 用 handle 字段）
inline fn fdToSocket(fd: i64) Socket {
    return .{
        .handle = fdToSocketHandle(fd),
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    };
}

/// i64 fd → Stream（TCP 流，仅 read/write/close 用 handle 字段）
inline fn fdToStream(fd: i64) Stream {
    return .{ .socket = fdToSocket(fd) };
}

/// i64 fd → Server（TCP 监听器，accept 需要 AcceptOptions）
/// Windows 上 AcceptOptions 为 { mode, protocol }，固定为 stream/tcp
inline fn fdToServer(fd: i64) Server {
    return .{
        .socket = fdToSocket(fd),
        .options = if (Server.AcceptOptions != void) .{ .mode = .stream, .protocol = .tcp } else {},
    };
}

// ──────────────────────────────────────────────
// 辅助：Glue Value ↔ std.Io.net.IpAddress 转换
// ──────────────────────────────────────────────
//
// Glue 地址类型布局（与 docs/superpowers/specs/2026-07-24-net-io-design.md 第 2 节对齐）：
//   Ipv4Addr  : newtype，fields = [__tag=0, bits=u32]（网络字节序）
//   Ipv6Addr  : newtype，fields = [__tag=0, hi=u64, lo=u64]（hi/lo 各 8 字节，网络字节序）
//   IpAddr    : ADT，V4(__tag=0, addr=Ipv4Addr) | V6(__tag=1, addr=Ipv6Addr)
//   SocketAddr : newtype，fields = [__tag=0, ip=IpAddr, port=u16]
//   AcceptResult : newtype，fields = [__tag=0, stream_fd=i64, peer_addr=SocketAddr]
//   RecvFromResult: newtype，fields = [__tag=0, data=u8[], src_addr=SocketAddr]

/// 从 Glue IpAddr Value 提取 std.Io.net.IpAddress（设置给定 port）
/// 失败返回 null（调用方返回 invalid_input 错误）
fn valueToIpAddress(v: Value, port: u16) ?IpAddress {
    const rec = asRecord(v) orelse return null;
    if (rec.fields.len < 2) return null;
    const tag = rec.fields[0].intCast(i64);
    const addr_val = rec.fields[1];
    const addr_rec = asRecord(addr_val) orelse return null;

    switch (tag) {
        0 => { // V4
            if (addr_rec.fields.len < 2) return null;
            const bits = addr_rec.fields[1].intCast(u32);
            // bits 为网络字节序（大端），Ip4Address.bytes 也是大端 [4]u8
            const b: [4]u8 = .{
                @intCast((bits >> 24) & 0xFF),
                @intCast((bits >> 16) & 0xFF),
                @intCast((bits >> 8) & 0xFF),
                @intCast(bits & 0xFF),
            };
            return .{ .ip4 = .{ .bytes = b, .port = port } };
        },
        1 => { // V6
            if (addr_rec.fields.len < 3) return null;
            const hi = addr_rec.fields[1].intCast(u64);
            const lo = addr_rec.fields[2].intCast(u64);
            // hi/lo 为网络字节序（大端），展开为 16 字节大端数组
            var b: [16]u8 = undefined;
            b[0] = @intCast((hi >> 56) & 0xFF);
            b[1] = @intCast((hi >> 48) & 0xFF);
            b[2] = @intCast((hi >> 40) & 0xFF);
            b[3] = @intCast((hi >> 32) & 0xFF);
            b[4] = @intCast((hi >> 24) & 0xFF);
            b[5] = @intCast((hi >> 16) & 0xFF);
            b[6] = @intCast((hi >> 8) & 0xFF);
            b[7] = @intCast(hi & 0xFF);
            b[8] = @intCast((lo >> 56) & 0xFF);
            b[9] = @intCast((lo >> 48) & 0xFF);
            b[10] = @intCast((lo >> 40) & 0xFF);
            b[11] = @intCast((lo >> 32) & 0xFF);
            b[12] = @intCast((lo >> 24) & 0xFF);
            b[13] = @intCast((lo >> 16) & 0xFF);
            b[14] = @intCast((lo >> 8) & 0xFF);
            b[15] = @intCast(lo & 0xFF);
            return .{ .ip6 = .{ .bytes = b, .port = port, .flow = 0, .interface = .none } };
        },
        else => return null,
    }
}

/// 从字节切片构造 Glue u8[] 数组 Value（用于 read/recv_from 返回数据）
fn makeU8Array(tctx: *ThreadContext, bytes: []const u8) SyscallError!Value {
    if (bytes.len == 0) {
        return Value.makeArray(tctx, &[_]Value{}, null) catch return error.OutOfMemory;
    }
    // 临时分配 Value[] 缓冲区填充 fromU8；makeArray 会拷贝到自己的缓冲区，完成后释放临时区
    const buf = tctx.allocObj(bytes.len * @sizeOf(Value)) catch return error.OutOfMemory;
    const elems: []Value = @as([*]Value, @ptrCast(@alignCast(buf.ptr)))[0..bytes.len];
    for (bytes, 0..) |b, i| {
        elems[i] = Value.fromU8(b);
    }
    const result = Value.makeArray(tctx, elems, null) catch {
        tctx.freeObj(buf.ptr);
        return error.OutOfMemory;
    };
    tctx.freeObj(buf.ptr);
    return result;
}

/// 从 Ip4Address.bytes 构造 Ipv4Addr Value（newtype: __tag + bits）
fn makeIpv4AddrValue(tctx: *ThreadContext, bytes: [4]u8) SyscallError!Value {
    // bytes 为大端，组装为 u32 网络字节序值
    const bits: u32 = (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
    var fields: [2]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        Value.fromU32(bits), // fields[1] = bits
    };
    const field_names: [2]?[]const u8 = .{ "__tag", "bits" };
    return Value.makeRecordWithNames(tctx, "Ipv4Addr", &fields, &field_names) catch return error.OutOfMemory;
}

/// 从 Ip6Address.bytes 构造 Ipv6Addr Value（newtype: __tag + hi + lo）
fn makeIpv6AddrValue(tctx: *ThreadContext, bytes: [16]u8) SyscallError!Value {
    // bytes[0..8] → hi（大端），bytes[8..16] → lo（大端）
    const hi: u64 =
        (@as(u64, bytes[0]) << 56) | (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) | (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) | (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) | @as(u64, bytes[7]);
    const lo: u64 =
        (@as(u64, bytes[8]) << 56) | (@as(u64, bytes[9]) << 48) |
        (@as(u64, bytes[10]) << 40) | (@as(u64, bytes[11]) << 32) |
        (@as(u64, bytes[12]) << 24) | (@as(u64, bytes[13]) << 16) |
        (@as(u64, bytes[14]) << 8) | @as(u64, bytes[15]);
    var fields: [3]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        Value.fromU64(hi), // fields[1] = hi
        Value.fromU64(lo), // fields[2] = lo
    };
    const field_names: [3]?[]const u8 = .{ "__tag", "hi", "lo" };
    return Value.makeRecordWithNames(tctx, "Ipv6Addr", &fields, &field_names) catch return error.OutOfMemory;
}

/// 从 std.Io.net.IpAddress 构造 Glue IpAddr Value（ADT: V4 | V6）
fn makeIpAddrValue(tctx: *ThreadContext, addr: IpAddress) SyscallError!Value {
    switch (addr) {
        .ip4 => |ip4| {
            const v4_val = try makeIpv4AddrValue(tctx, ip4.bytes);
            // v4_val RC=1，由 IpAddr record 窃取，无需额外 retain
            var fields: [2]Value = .{
                Value.fromI64(0), // fields[0] = __tag（V4 = 0）
                v4_val, // fields[1] = addr（Ipv4Addr，RC=1，由 record 窃取）
            };
            const field_names: [2]?[]const u8 = .{ "__tag", "addr" };
            return Value.makeRecordWithNames(tctx, "IpAddr", &fields, &field_names) catch {
                v4_val.release(tctx); // OOM：释放 v4_val
                return error.OutOfMemory;
            };
        },
        .ip6 => |ip6| {
            const v6_val = try makeIpv6AddrValue(tctx, ip6.bytes);
            // v6_val RC=1，由 IpAddr record 窃取，无需额外 retain
            var fields: [2]Value = .{
                Value.fromI64(1), // fields[0] = __tag（V6 = 1）
                v6_val, // fields[1] = addr（Ipv6Addr，RC=1，由 record 窃取）
            };
            const field_names: [2]?[]const u8 = .{ "__tag", "addr" };
            return Value.makeRecordWithNames(tctx, "IpAddr", &fields, &field_names) catch {
                v6_val.release(tctx); // OOM：释放 v6_val
                return error.OutOfMemory;
            };
        },
    }
}

/// 从 std.Io.net.IpAddress 构造 Glue SocketAddr Value（newtype: __tag + ip + port）
fn makeSocketAddrValue(tctx: *ThreadContext, addr: IpAddress) SyscallError!Value {
    const ip_val = try makeIpAddrValue(tctx, addr);
    // ip_val RC=1，由 SocketAddr record 窃取，无需额外 retain
    const port = addr.getPort();
    var fields: [3]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        ip_val, // fields[1] = ip（IpAddr，RC=1，由 record 窃取）
        Value.fromU16(port), // fields[2] = port
    };
    const field_names: [3]?[]const u8 = .{ "__tag", "ip", "port" };
    return Value.makeRecordWithNames(tctx, "SocketAddr", &fields, &field_names) catch {
        ip_val.release(tctx); // OOM：释放 ip_val
        return error.OutOfMemory;
    };
}

// ──────────────────────────────────────────────
// Net syscall 实现
// ──────────────────────────────────────────────

/// __net_resolve(host: str) -> Throw<IpAddr[], IOError>
///
/// 一期：仅 IP 字面量解析（IpAddress.resolve），非 DNS。
/// 解析成功 → 返回单元素数组 [IpAddr]；解析失败 → 返回空数组（非错误）。
/// DNS（HostName.lookup）为二期补全。
pub fn net_resolve(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const host = asStrBytes(args[0]);

    // IpAddress.resolve 尝试 IPv4 再 IPv6 字面量解析
    const addr = IpAddress.resolve(io, host, 0) catch {
        // 一期：非 IP 字面量返回空数组（不报错，DNS 二期补全）
        var empty: [0]Value = .{};
        const arr_val = Value.makeArray(tctx, empty[0..], null) catch return error.OutOfMemory;
        return makeThrowOk(tctx, arr_val);
    };

    const ip_val = try makeIpAddrValue(tctx, addr);
    // ip_val RC=1，由 array 窃取，无需额外 retain
    var elems = [_]Value{ip_val};
    const arr_val = Value.makeArray(tctx, elems[0..], null) catch {
        ip_val.release(tctx); // OOM：释放 ip_val
        return error.OutOfMemory;
    };
    return makeThrowOk(tctx, arr_val);
}

/// __net_tcp_listen(ip: IpAddr, port: u16, reuse_addr: bool) -> Throw<i64, IOError>
///
/// 监听 TCP 地址，返回 listener fd（i64）。
pub fn net_tcp_listen(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const port = args[1].intCast(u16);
    var addr = valueToIpAddress(args[0], port) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_listen: invalid ip", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const reuse_addr = asBool(args[2]);

    const server = IpAddress.listen(&addr, io, .{
        .reuse_address = reuse_addr,
        .mode = .stream,
        .protocol = .tcp,
    }) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_tcp_listen failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI64(socketToFd(server.socket)));
}

/// __net_tcp_accept(fd: i64, timeout_ns: i64) -> Throw<AcceptResult, IOError>
///
/// 接受 TCP 连接。timeout_ns <= 0 时无超时。
/// 返回 AcceptResult(stream_fd, peer_addr)。
const AcceptCtx = struct {
    fd: i64,
};

fn acceptOp(io: Io, tctx: *ThreadContext, ctx: *anyopaque) anyerror!Value {
    const c: *AcceptCtx = @ptrCast(@alignCast(ctx));
    var server = fdToServer(c.fd);
    const stream = server.accept(io) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_tcp_accept failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    // peer 地址从 stream.socket.address 获取
    const peer_addr_val = try makeSocketAddrValue(tctx, stream.socket.address);
    // peer_addr_val RC=1，由 AcceptResult record 窃取，无需额外 retain
    var fields: [3]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        Value.fromI64(socketToFd(stream.socket)), // fields[1] = stream_fd
        peer_addr_val, // fields[2] = peer_addr（SocketAddr，RC=1，由 record 窃取）
    };
    const field_names: [3]?[]const u8 = .{ "__tag", "stream_fd", "peer_addr" };
    const result = Value.makeRecordWithNames(tctx, "AcceptResult", &fields, &field_names) catch {
        peer_addr_val.release(tctx); // OOM：释放 peer_addr_val
        return error.OutOfMemory;
    };
    return makeThrowOk(tctx, result);
}

pub fn net_tcp_accept(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const timeout_ns_raw = args[1].intCast(i64);
    // 负超时视为无超时（0 = 直接调用）
    const timeout_ns: u64 = if (timeout_ns_raw <= 0) 0 else @intCast(timeout_ns_raw);

    var ctx = AcceptCtx{ .fd = fd };
    return util.runWithTimeout(io, tctx, timeout_ns, acceptOp, &ctx);
}

/// __net_tcp_connect(ip: IpAddr, port: u16, timeout_ns: i64) -> Throw<i64, IOError>
///
/// 发起 TCP 连接。timeout_ns <= 0 时无超时。
/// 超时通过 ConnectOptions.timeout 内建实现（无需 runWithTimeout）。
pub fn net_tcp_connect(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const port = args[1].intCast(u16);
    var addr = valueToIpAddress(args[0], port) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_connect: invalid ip", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const timeout_ns_raw = args[2].intCast(i64);

    const timeout: Io.Timeout = if (timeout_ns_raw <= 0) .none else .{ .duration = .{
        .raw = .{ .nanoseconds = @intCast(timeout_ns_raw) },
        .clock = .awake,
    } };

    const stream = IpAddress.connect(&addr, io, .{
        .mode = .stream,
        .timeout = timeout,
    }) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_tcp_connect failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI64(socketToFd(stream.socket)));
}

/// __net_tcp_read(fd: i64, len: usize, timeout_ns: i64) -> Throw<u8[], IOError>
///
/// 从 TCP 流读取数据，返回读到的字节数组（空数组 = EOF）。
/// 单次 read 语义（不循环阻塞）。
///
/// 设计说明：不再接受 buf 参数就地填充。async fun 参数会被 orbit worker
/// 深拷贝，就地修改 buf 对调用方不可见。改为返回新分配的 u8[] 数组，
/// 由 async 返回值路径正常传回调用方。
const ReadCtx = struct {
    fd: i64,
    len: usize,
};

fn readOp(io: Io, tctx: *ThreadContext, ctx: *anyopaque) anyerror!Value {
    const c: *ReadCtx = @ptrCast(@alignCast(ctx));
    var tmp_buf: [32768]u8 = undefined;
    const read_len = @min(c.len, tmp_buf.len);
    const stream = fdToStream(c.fd);
    // 直接调用 vtable.netRead（单次 read，不经过 Reader 接口缓冲层）
    var bufs = [_][]u8{tmp_buf[0..read_len]};
    const n = io.vtable.netRead(io.userdata, stream.socket.handle, bufs[0..]) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_tcp_read failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    // 构造 u8[] 数组返回（调用方通过返回值获取数据，而非就地填充 buf）
    const arr_val = try makeU8Array(tctx, tmp_buf[0..n]);
    return makeThrowOk(tctx, arr_val);
}

pub fn net_tcp_read(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const len_raw = args[1].intCast(i64);
    if (len_raw < 0) {
        const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_read: negative len", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const len: usize = @intCast(len_raw);
    const timeout_ns_raw = args[2].intCast(i64);
    const timeout_ns: u64 = if (timeout_ns_raw <= 0) 0 else @intCast(timeout_ns_raw);

    var ctx = ReadCtx{ .fd = fd, .len = len };
    return util.runWithTimeout(io, tctx, timeout_ns, readOp, &ctx);
}

/// __net_tcp_write(fd: i64, buf: u8[], len: usize, timeout_ns: i64) -> Throw<usize, IOError>
///
/// 向 TCP 流写入数据。返回实际写入字节数。
const WriteCtx = struct {
    fd: i64,
    arr: *value.ArrayValue,
    len: usize,
};

fn writeOp(io: Io, tctx: *ThreadContext, ctx: *anyopaque) anyerror!Value {
    const c: *WriteCtx = @ptrCast(@alignCast(ctx));
    var tmp_buf: [32768]u8 = undefined;
    const write_len = @min(c.len, tmp_buf.len);
    // 拼接 u8 字节，逐个 Value 转 u8；非 u8 元素直接报错
    var i: usize = 0;
    while (i < write_len) : (i += 1) {
        tmp_buf[i] = switch (c.arr.elements[i]) {
            .u8 => c.arr.elements[i].asU8(),
            else => {
                const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_write: buf element not u8", 22, null);
                return makeThrowErr(tctx, io_err);
            },
        };
    }
    const stream = fdToStream(c.fd);
    // 直接调用 vtable.netWrite（header 空，data 单缓冲，splat=1）
    const n = io.vtable.netWrite(io.userdata, stream.socket.handle, &.{}, &.{tmp_buf[0..write_len]}, 1) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_tcp_write failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromUsize(n));
}

pub fn net_tcp_write(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 4) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const arr = asArray(args[1]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_write: buf not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const len_raw = args[2].intCast(i64);
    if (len_raw < 0) {
        const io_err = try makeIOError(tctx, .invalid_input, "net_tcp_write: negative len", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const len: usize = @intCast(len_raw);
    const timeout_ns_raw = args[3].intCast(i64);
    const timeout_ns: u64 = if (timeout_ns_raw <= 0) 0 else @intCast(timeout_ns_raw);

    var ctx = WriteCtx{ .fd = fd, .arr = arr, .len = @min(len, arr.elements.len) };
    return util.runWithTimeout(io, tctx, timeout_ns, writeOp, &ctx);
}

/// __net_tcp_close(fd: i64) -> Throw<Unit, IOError>
///
/// 关闭 TCP 流（或监听器）。
pub fn net_tcp_close(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const stream = fdToStream(fd);
    stream.close(io);
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __net_udp_bind(ip: IpAddr, port: u16, reuse_addr: bool) -> Throw<i64, IOError>
///
/// 绑定 UDP 地址，返回 socket fd（i64）。
pub fn net_udp_bind(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const port = args[1].intCast(u16);
    var addr = valueToIpAddress(args[0], port) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_udp_bind: invalid ip", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    _ = asBool(args[2]); // reuse_addr：BindOptions 无 reuse_address 字段，预留参数

    const sock = IpAddress.bind(&addr, io, .{
        .mode = .dgram,
        .ip6_only = false,
        .allow_broadcast = false,
    }) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_udp_bind failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI64(socketToFd(sock)));
}

/// __net_udp_send_to(fd: i64, ip: IpAddr, port: u16, data: u8[]) -> Throw<usize, IOError>
///
/// 向目标地址发送 UDP 数据报。数据报不阻塞，无需超时。
/// 返回实际发送字节数。
pub fn net_udp_send_to(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 4) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const port = args[2].intCast(u16);
    var dest = valueToIpAddress(args[1], port) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_udp_send_to: invalid ip", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const arr = asArray(args[3]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "net_udp_send_to: data not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };

    // 拼接 u8 字节到栈缓冲区（32KB 上限，与 file_write 一致）
    var tmp_buf: [32768]u8 = undefined;
    const write_len = @min(arr.elements.len, tmp_buf.len);
    var i: usize = 0;
    while (i < write_len) : (i += 1) {
        tmp_buf[i] = switch (arr.elements[i]) {
            .u8 => arr.elements[i].asU8(),
            else => {
                const io_err = try makeIOError(tctx, .invalid_input, "net_udp_send_to: data element not u8", 22, null);
                return makeThrowErr(tctx, io_err);
            },
        };
    }

    const sock = fdToSocket(fd);
    sock.send(io, &dest, tmp_buf[0..write_len]) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_udp_send_to failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromUsize(write_len));
}

/// __net_udp_recv_from(fd: i64, len: usize, timeout_ns: i64) -> Throw<RecvFromResult, IOError>
///
/// 接收 UDP 数据报。返回 RecvFromResult(data, src_addr)。
/// data 为读到的字节数组（可通过 data.len() 获取长度）。
const RecvFromCtx = struct {
    fd: i64,
    len: usize,
};

fn recvFromOp(io: Io, tctx: *ThreadContext, ctx: *anyopaque) anyerror!Value {
    const c: *RecvFromCtx = @ptrCast(@alignCast(ctx));
    var tmp_buf: [32768]u8 = undefined;
    const read_len = @min(c.len, tmp_buf.len);
    const sock = fdToSocket(c.fd);
    const msg = sock.receive(io, tmp_buf[0..read_len]) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "net_udp_recv_from failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    // 构造 u8[] 数据数组（返回值路径，非就地填充）
    const data_val = try makeU8Array(tctx, msg.data);
    // 构造 RecvFromResult(data, src_addr)
    const src_addr_val = try makeSocketAddrValue(tctx, msg.from);
    // src_addr_val RC=1，data_val RC=1，均由 RecvFromResult record 窃取
    var fields: [3]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        data_val, // fields[1] = data（u8[]，RC=1，由 record 窃取）
        src_addr_val, // fields[2] = src_addr（SocketAddr，RC=1，由 record 窃取）
    };
    const field_names: [3]?[]const u8 = .{ "__tag", "data", "src_addr" };
    const result = Value.makeRecordWithNames(tctx, "RecvFromResult", &fields, &field_names) catch {
        src_addr_val.release(tctx); // OOM：释放
        data_val.release(tctx);
        return error.OutOfMemory;
    };
    return makeThrowOk(tctx, result);
}

pub fn net_udp_recv_from(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const len_raw = args[1].intCast(i64);
    if (len_raw < 0) {
        const io_err = try makeIOError(tctx, .invalid_input, "net_udp_recv_from: negative len", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const len: usize = @intCast(len_raw);
    const timeout_ns_raw = args[2].intCast(i64);
    const timeout_ns: u64 = if (timeout_ns_raw <= 0) 0 else @intCast(timeout_ns_raw);

    var ctx = RecvFromCtx{ .fd = fd, .len = len };
    return util.runWithTimeout(io, tctx, timeout_ns, recvFromOp, &ctx);
}
