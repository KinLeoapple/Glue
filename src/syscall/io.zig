//! Glue IO syscall 原语
//!
//! 包装宿主文件/目录/路径/字节字符串操作，对外暴露为 __ 前缀 syscall 函数。
//! 业务错误通过 ThrowValue.err 传递（IOError 内部封装 kind/msg/os_err/path 字段）。
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md 第 4 节

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ErrorValue = value.ErrorValue;
const AdtField = value.AdtField;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;

// ──────────────────────────────────────────────
// 辅助：从 Value 提取参数
// ──────────────────────────────────────────────

/// 从 Value 提取 i32
inline fn asI32(v: Value) i32 {
    return switch (v) {
        .i32 => v.asI32(),
        .i64 => @intCast(v.asI64()),
        .i128 => @intCast(v.asI128()),
        .usize => @intCast(v.asUsize()),
        .u8 => @intCast(v.asU8()),
        .u16 => @intCast(v.asU16()),
        .u32 => @intCast(v.asU32()),
        .u64 => @intCast(v.asU64()),
        else => 0,
    };
}

/// 从 Value 提取 i64
inline fn asI64(v: Value) i64 {
    return switch (v) {
        .i32 => v.asI32(),
        .i64 => v.asI64(),
        .i128 => @intCast(v.asI128()),
        .usize => @intCast(v.asUsize()),
        else => 0,
    };
}

/// 从 Value 提取 i128
inline fn asI128(v: Value) i128 {
    return switch (v) {
        .i32 => v.asI32(),
        .i64 => v.asI64(),
        .i128 => v.asI128(),
        .usize => @intCast(v.asUsize()),
        else => 0,
    };
}

/// 从 Value 提取 usize
inline fn asUsize(v: Value) usize {
    return switch (v) {
        .i32 => @intCast(v.asI32()),
        .i64 => @intCast(v.asI64()),
        .i128 => @intCast(v.asI128()),
        .usize => v.asUsize(),
        .u8 => v.asU8(),
        .u16 => v.asU16(),
        .u32 => v.asU32(),
        .u64 => @intCast(v.asU64()),
        else => 0,
    };
}

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

/// 将 []const u8 路径转换为 sentinel-terminated 字符串（写入栈缓冲区）
/// 返回 null 表示路径过长
fn pathToZ(path: []const u8, buf: *[4096]u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

// ──────────────────────────────────────────────
// 辅助：构造返回值
// ──────────────────────────────────────────────

/// IOErrorKind 枚举（与 IOError.glue 中 ADT 变体一一对应，0-indexed）
const IOErrorKind = enum(u8) {
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
};

/// errno → IOErrorKind 映射（POSIX 错误码归一化）
fn errnoToKind(errno: i32) IOErrorKind {
    return switch (errno) {
        2 => .not_found, // ENOENT
        13, 1 => .permission_denied, // EACCES, EPERM
        17 => .already_exists, // EEXIST
        16, 11 => .busy, // EBUSY, EAGAIN
        22 => .invalid_input, // EINVAL
        32 => .broken_pipe, // EPIPE
        4 => .interrupted, // EINTR
        12 => .out_of_memory, // ENOMEM
        else => .other,
    };
}

/// 构造 IOError 值（ADT 单构造器，4 字段：kind/msg/os_err/path）
///
/// IOError 是 error_newtype，构造器名 = 类型名 "IOError"，
/// 字段位置参数别名 _0.._3，按 spec 顺序 kind/msg/os_err/path。
fn makeIOError(tctx: *ThreadContext, kind: IOErrorKind, msg: []const u8, os_err: i32, path: ?[]const u8) SyscallError!Value {
    var fields: [4]AdtField = .{
        .{ .name = "kind", .value = Value.fromU8(@intFromEnum(kind)) },
        .{ .name = "msg", .value = try Value.fromStringBytes(tctx, msg) },
        .{ .name = "os_err", .value = Value.fromI32(os_err) },
        .{ .name = "path", .value = if (path) |p| try Value.fromStringBytes(tctx, p) else Value.fromNull() },
    };
    // msg/path 已分配新堆对象，需 retain 后传入 makeAdt（makeAdt 不主动 retain）
    _ = fields[1].value.retain();
    if (path != null) _ = fields[3].value.retain();
    return Value.makeAdt(tctx, "IOError", "IOError", &fields) catch return error.OutOfMemory;
}

/// 构造 Throw.ok(value) 包装
fn makeThrowOk(tctx: *ThreadContext, v: Value) SyscallError!Value {
    _ = v.retain();
    return Value.makeThrow(tctx, .{ .ok = v }) catch return error.OutOfMemory;
}

/// 构造 Throw.err(IOError) 包装
fn makeThrowErr(tctx: *ThreadContext, err_val: Value) SyscallError!Value {
    // err_val 是 IOError ADT 对象（ref），需取 header 并 retain
    const err_obj = err_val.asRef();
    _ = value.obj_header.retain(err_obj);
    // 取 ErrorValue：IOError 是 error_newtype，本身即 ErrorValue 的子类型
    // 但 ADT 值与 ErrorValue 是不同 ObjHeader 类型，此处 err_val 是 ADT 而非 ErrorValue
    // 设计上：ThrowValue.err 需 *ErrorValue，而 IOError ADT 需进一步包装为 ErrorValue
    // 为简化：将 IOError ADT 的描述信息拷贝到新 ErrorValue
    const adt: *value.AdtValue = @alignCast(@fieldParentPtr("header", err_obj));
    const msg_bytes = if (adt.fields.len > 1) switch (adt.fields[1].value) {
        .ref => |o| if (o.type_tag == .str) blk: {
            const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", o));
            break :blk s.bytes();
        } else "",
        else => "",
    } else "";
    const err_ev = Value.makeError(tctx, "io error", msg_bytes, true) catch return error.OutOfMemory;
    _ = value.obj_header.retain(err_ev.asRef());
    // 释放临时 retain 的 ADT
    value.obj_header.release(err_obj, tctx);
    const err_val_ptr: *ErrorValue = @alignCast(@fieldParentPtr("header", err_ev.asRef()));
    return Value.makeThrow(tctx, .{ .err = err_val_ptr }) catch return error.OutOfMemory;
}

/// 根据 st_mode 构造 FileKind ADT 值（无字段变体 File/Directory/Symlink/Other）
///
/// FileKind 在 std/io/File.glue 中定义为 ADT：
///   type FileKind = | File | Directory | Symlink | Other
/// syscall 层按 POSIX S_IFMT 位域选择构造器。
/// 返回的 Value 已 RC=1（makeAdt 初始 RC），调用方如需放入 record 字段须额外 retain。
fn makeFileKind(tctx: *ThreadContext, mode: u32) SyscallError!Value {
    const S_IFMT: u32 = 0o170000;
    const S_IFREG: u32 = 0o100000;
    const S_IFDIR: u32 = 0o040000;
    const S_IFLNK: u32 = 0o120000;
    const ctor: []const u8 = switch (mode & S_IFMT) {
        S_IFREG => "File",
        S_IFDIR => "Directory",
        S_IFLNK => "Symlink",
        else => "Other",
    };
    return Value.makeAdt(tctx, "FileKind", ctor, &.{}) catch return error.OutOfMemory;
}

// ──────────────────────────────────────────────
// 文件 syscall
// ──────────────────────────────────────────────

/// __file_open(path: str, flags: i32, mode: i32) -> Throw<i32, IOError>
pub fn file_open(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const flags = asI32(args[1]);
    const mode = asI32(args[2]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_open: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    const oflag: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    const fd = std.posix.openatZ(@as(std.c.fd_t, std.c.AT.FDCWD), path_z, oflag, @intCast(mode)) catch |err| {
        const errno: i32 = switch (err) {
            error.AccessDenied => 13,
            error.FileNotFound => 2,
            error.PathAlreadyExists => 17,
            error.FileBusy => 16,
            error.SymLinkLoop => 40,
            error.SystemResources => 12,
            error.ProcessFdQuotaExceeded => 4,
            error.NameTooLong => 36,
            else => 0,
        };
        const io_err = try makeIOError(tctx, errnoToKind(errno), "file_open failed", errno, path);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI32(fd));
}

/// __file_close(fd: i32) -> Throw<Unit, IOError>
pub fn file_close(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = asI32(args[0]);
    _ = std.c.close(@intCast(fd));
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_read(fd: i32, buf: u8[], len: usize) -> Throw<usize, IOError>
pub fn file_read(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = asI32(args[0]);
    const arr = asArray(args[1]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_read: buf not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const len = asUsize(args[2]);
    const actual_len = @min(len, arr.elements.len);
    // 将 Value 元素视作 u8：约定 u8[] 的每个 Value 都是 .u8 标量
    // 优化：若 array 的底层布局是连续 u8 字节，直接读入；这里为通用性逐字节写回
    var tmp_buf: [4096]u8 = undefined;
    const read_len = if (actual_len <= tmp_buf.len) actual_len else tmp_buf.len;
    const n = std.posix.read(@intCast(fd), tmp_buf[0..read_len]) catch |err| {
        const errno: i32 = switch (err) {
            error.WouldBlock => 11,
            error.NotOpenForReading => 9,
            error.ConnectionResetByPeer => 104,
            else => 0,
        };
        const io_err = try makeIOError(tctx, errnoToKind(errno), "file_read failed", errno, null);
        return makeThrowErr(tctx, io_err);
    };
    // 将读到的字节写回 array（覆盖前 n 个元素）
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i >= arr.elements.len) break;
        arr.elements[i] = Value.fromU8(tmp_buf[i]);
    }
    return makeThrowOk(tctx, Value.fromUsize(n));
}

/// __file_write(fd: i32, buf: u8[], len: usize) -> Throw<usize, IOError>
pub fn file_write(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = asI32(args[0]);
    const arr = asArray(args[1]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_write: buf not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const len = asUsize(args[2]);
    const actual_len = @min(len, arr.elements.len);
    // 拼接 u8 字节，逐个 Value 转 u8
    var tmp_buf: [4096]u8 = undefined;
    const write_len = if (actual_len <= tmp_buf.len) actual_len else tmp_buf.len;
    var i: usize = 0;
    while (i < write_len) : (i += 1) {
        tmp_buf[i] = switch (arr.elements[i]) {
            .u8 => arr.elements[i].asU8(),
            else => 0,
        };
    }
    const write_rc = std.c.write(@intCast(fd), tmp_buf[0..write_len].ptr, write_len);
    if (write_rc < 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, errnoToKind(errno), "file_write failed", errno, null);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromUsize(@intCast(write_rc)));
}

/// __file_seek(fd: i32, offset: i64, whence: i32) -> Throw<i64, IOError>
pub fn file_seek(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = asI32(args[0]);
    const offset = asI64(args[1]);
    const whence = asI32(args[2]);
    // whence: 0=SET, 1=CUR, 2=END
    if (whence < 0 or whence > 2) {
        const io_err = try makeIOError(tctx, .invalid_input, "file_seek: bad whence", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    // 使用 lseek 系统调用（SEEK_SET=0, SEEK_CUR=1, SEEK_END=2）
    const result = std.c.lseek(fd, offset, @intCast(whence));
    if (result < 0) {
        const errno: i32 = -1;
        const io_err = try makeIOError(tctx, .invalid_input, "file_seek failed", errno, null);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromI64(@intCast(result)));
}

/// __file_tell(fd: i32) -> Throw<i64, IOError>
pub fn file_tell(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = asI32(args[0]);
    const result = std.c.lseek(fd, 0, 1); // SEEK_CUR
    if (result < 0) {
        const errno: i32 = -1;
        const io_err = try makeIOError(tctx, .invalid_input, "file_tell failed", errno, null);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromI64(@intCast(result)));
}

/// __file_stat(path: str) -> Throw<Stat, IOError>
///
/// Stat 字段布局（与 std/io/File.glue 中 Stat newtype 定义对齐）：
///   size     : u64      — 文件大小（字节数）
///   mtime_ns : i64      — 修改时间（纳秒，Unix epoch）
///   ctime_ns : i64      — 元数据变更时间（纳秒，Unix epoch）
///   kind     : FileKind — 文件种类 ADT（File/Directory/Symlink/Other）
pub fn file_stat(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_stat: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    var st: std.c.Stat = undefined;
    const rc = std.c.fstatat(@as(std.c.fd_t, std.c.AT.FDCWD), path_z, &st, 0);
    if (rc != 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, .not_found, "file_stat failed", errno, path);
        return makeThrowErr(tctx, io_err);
    }
    const mtime_sec: i64 = @intCast(st.mtimespec.sec);
    const mtime_nsec: i64 = @intCast(st.mtimespec.nsec);
    const ctime_sec: i64 = @intCast(st.ctimespec.sec);
    const ctime_nsec: i64 = @intCast(st.ctimespec.nsec);
    const mode_u32: u32 = @intCast(st.mode);
    const kind_val = try makeFileKind(tctx, mode_u32);
    // kind_val 是堆对象（AdtValue），进入 record 字段需额外 retain（makeRecordWithNames 不主动 retain）
    _ = kind_val.retain();
    var fields: [4]Value = .{
        Value.fromU64(@intCast(st.size)),
        Value.fromI64(mtime_sec * 1_000_000_000 + mtime_nsec),
        Value.fromI64(ctime_sec * 1_000_000_000 + ctime_nsec),
        kind_val,
    };
    const field_names: [4]?[]const u8 = .{ "size", "mtime_ns", "ctime_ns", "kind" };
    const stat_val = Value.makeRecordWithNames(tctx, "Stat", &fields, &field_names) catch return error.OutOfMemory;
    return makeThrowOk(tctx, stat_val);
}

/// __file_fstat(fd: i32) -> Throw<Stat, IOError>
pub fn file_fstat(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = asI32(args[0]);
    var st: std.c.Stat = undefined;
    const rc = std.c.fstat(@intCast(fd), &st);
    if (rc != 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, .invalid_input, "file_fstat failed", errno, null);
        return makeThrowErr(tctx, io_err);
    }
    const mtime_sec: i64 = @intCast(st.mtimespec.sec);
    const mtime_nsec: i64 = @intCast(st.mtimespec.nsec);
    const ctime_sec: i64 = @intCast(st.ctimespec.sec);
    const ctime_nsec: i64 = @intCast(st.ctimespec.nsec);
    const mode_u32: u32 = @intCast(st.mode);
    const kind_val = try makeFileKind(tctx, mode_u32);
    _ = kind_val.retain();
    var fields: [4]Value = .{
        Value.fromU64(@intCast(st.size)),
        Value.fromI64(mtime_sec * 1_000_000_000 + mtime_nsec),
        Value.fromI64(ctime_sec * 1_000_000_000 + ctime_nsec),
        kind_val,
    };
    const field_names: [4]?[]const u8 = .{ "size", "mtime_ns", "ctime_ns", "kind" };
    const stat_val = Value.makeRecordWithNames(tctx, "Stat", &fields, &field_names) catch return error.OutOfMemory;
    return makeThrowOk(tctx, stat_val);
}

/// __file_remove(path: str) -> Throw<Unit, IOError>
pub fn file_remove(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_remove: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    const rc = std.c.unlink(path_z);
    if (rc != 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, errnoToKind(errno), "file_remove failed", errno, path);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_rename(old: str, new: str) -> Throw<Unit, IOError>
pub fn file_rename(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const old_path = asStrBytes(args[0]);
    const new_path = asStrBytes(args[1]);
    var old_buf: [4096]u8 = undefined;
    var new_buf: [4096]u8 = undefined;
    const old_z = pathToZ(old_path, &old_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_rename: old path too long", 36, old_path);
        return makeThrowErr(tctx, io_err);
    };
    const new_z = pathToZ(new_path, &new_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_rename: new path too long", 36, new_path);
        return makeThrowErr(tctx, io_err);
    };
    const rc = std.c.rename(old_z, new_z);
    if (rc != 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, errnoToKind(errno), "file_rename failed", errno, old_path);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_chmod(path: str, mode: i32) -> Throw<Unit, IOError>
pub fn file_chmod(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const mode = asI32(args[1]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_chmod: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    const rc = std.c.chmod(path_z, @intCast(mode));
    if (rc != 0) {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, .permission_denied, "file_chmod failed", errno, path);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

// ──────────────────────────────────────────────
// 目录 syscall
// ──────────────────────────────────────────────

/// __dir_create(path: str, recursive: bool) -> Throw<Unit, IOError>
pub fn dir_create(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const recursive = asBool(args[1]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "dir_create: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    if (recursive) {
        // 递归创建：逐级 mkdir，忽略已存在的目录
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (i == path.len or path[i] == '/') {
                if (i == 0) continue;
                const seg_z = path_buf[0..i :0];
                _ = std.c.mkdir(seg_z, 0o755);
                // 忽略已存在（EEXIST=17）错误，继续下一级
            }
        }
    } else {
        const rc = std.c.mkdir(path_z, 0o777);
        if (rc != 0) {
            const errno: i32 = @intCast(std.c._errno().*);
            const io_err = try makeIOError(tctx, errnoToKind(errno), "dir_create failed", errno, path);
            return makeThrowErr(tctx, io_err);
        }
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// 递归删除目录及其内容
fn removeTreeRecursive(path_z: [:0]const u8, path_buf: *[4096]u8) c_int {
    // 先尝试 rmdir（仅对空目录有效）
    var rc = std.c.rmdir(path_z);
    if (rc == 0) return 0;
    const en = std.c._errno().*;
    // ENOTEMPTY=66 (macOS)，其他错误直接返回
    if (en != 66) return -1;

    // 打开目录迭代并删除内容
    const dir = std.c.opendir(path_z) orelse return -1;
    defer _ = std.c.closedir(dir);
    const base_len = path_z.len;
    while (true) {
        const entry = std.c.readdir(dir) orelse break;
        const name_bytes = entry.name[0..entry.namlen];
        if (std.mem.eql(u8, name_bytes, ".") or std.mem.eql(u8, name_bytes, "..")) continue;
        if (base_len + 1 + entry.namlen + 1 > path_buf.len) continue;
        @memcpy(path_buf[0..base_len], path_z[0..base_len]);
        path_buf[base_len] = '/';
        @memcpy(path_buf[base_len + 1 .. base_len + 1 + entry.namlen], name_bytes);
        const child_end = base_len + 1 + entry.namlen;
        path_buf[child_end] = 0;
        const child_z = path_buf[0..child_end :0];
        if (entry.type == std.c.DT.DIR) {
            _ = removeTreeRecursive(child_z, path_buf);
        } else {
            _ = std.c.unlink(child_z);
        }
    }
    // 内容删除后再次尝试 rmdir
    rc = std.c.rmdir(path_z);
    return rc;
}

/// __dir_remove(path: str, recursive: bool) -> Throw<Unit, IOError>
pub fn dir_remove(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const recursive = asBool(args[1]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "dir_remove: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    if (recursive) {
        const rc = removeTreeRecursive(path_z, &path_buf);
        if (rc != 0) {
            const errno: i32 = @intCast(std.c._errno().*);
            const io_err = try makeIOError(tctx, errnoToKind(errno), "dir_remove failed", errno, path);
            return makeThrowErr(tctx, io_err);
        }
    } else {
        const rc = std.c.rmdir(path_z);
        if (rc != 0) {
            const errno: i32 = @intCast(std.c._errno().*);
            const io_err = try makeIOError(tctx, errnoToKind(errno), "dir_remove failed", errno, path);
            return makeThrowErr(tctx, io_err);
        }
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __dir_list(path: str) -> Throw<DirEntry[], IOError>
///
/// DirEntry 是 (name: str, kind: FileKind) record
pub fn dir_list(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "dir_list: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    const dir = std.c.opendir(path_z) orelse {
        const errno: i32 = @intCast(std.c._errno().*);
        const io_err = try makeIOError(tctx, errnoToKind(errno), "dir_list failed", errno, path);
        return makeThrowErr(tctx, io_err);
    };
    defer _ = std.c.closedir(dir);

    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(tctx.backing);

    while (true) {
        const entry = std.c.readdir(dir) orelse break;
        const name_bytes = entry.name[0..entry.namlen];
        if (std.mem.eql(u8, name_bytes, ".") or std.mem.eql(u8, name_bytes, "..")) continue;
        const name_val = Value.fromStringBytes(tctx, name_bytes) catch return error.OutOfMemory;
        _ = name_val.retain();
        // DirEntry.kind 字段是 FileKind ADT（File/Directory/Symlink/Other，无字段变体）
        const kind_ctor: []const u8 = switch (entry.type) {
            std.c.DT.REG => "File",
            std.c.DT.DIR => "Directory",
            std.c.DT.LNK => "Symlink",
            else => "Other",
        };
        const kind_val = Value.makeAdt(tctx, "FileKind", kind_ctor, &.{}) catch return error.OutOfMemory;
        _ = kind_val.retain();
        var fields: [2]Value = .{ name_val, kind_val };
        const field_names: [2]?[]const u8 = .{ "name", "kind" };
        const e = Value.makeRecordWithNames(tctx, "DirEntry", &fields, &field_names) catch return error.OutOfMemory;
        _ = e.retain();
        entries.append(tctx.backing, e) catch return error.OutOfMemory;
    }

    const arr_val = Value.makeArray(tctx, entries.items, null) catch return error.OutOfMemory;
    return makeThrowOk(tctx, arr_val);
}
