//! Glue IO syscall 原语（跨平台实现）
//!
//! 使用 std.Io.File / std.Io.Dir（跨平台文件/目录 API）替代 POSIX 专属的 std.c 调用。
//! 业务错误通过 ThrowValue.err 传递（IOError 内部封装 kind/msg/os_err/path 字段）。
//!
//! 跨平台 fd 模型：Glue 层用 i64 存储 fd；Zig 层 File.handle 在 POSIX 上是 i32、
//! Windows 上是 *anyopaque（HANDLE），通过 fdToHandle/fileToFd 用 @typeInfo 统一转换。
//!
//! seek/tell：std.Io 的 vtable 只有 fileSeekBy/fileSeekTo，无 tell（获取当前位置）。
//! 故 seek/tell 用条件编译：POSIX 走 std.c.lseek（libc，覆盖 Linux/macOS/BSD），
//! Windows 走 SetFilePointerEx（kernel32）。
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md 第 4 节

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ErrorValue = value.ErrorValue;
const AdtField = value.AdtField;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

// ──────────────────────────────────────────────
// 辅助：从 Value 提取参数
// ──────────────────────────────────────────────

// 整数跨宽度转换统一使用 Value.intCast(T)。
// 浮点跨宽度转换统一使用 Value.floatCast(T)。

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
/// 仅用于 POSIX chmod（需要 [*:0]const u8）。std.Io API 接收 []const u8 无需 sentinel。
/// 返回 null 表示路径过长
fn pathToZ(path: []const u8, buf: *[4096]u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

// ──────────────────────────────────────────────
// 辅助：跨平台 fd ↔ File 转换
// ──────────────────────────────────────────────

/// i64 fd → File.Handle（POSIX: i32，Windows: *anyopaque）
/// Glue 层用 i64 统一存储 fd，此处按 Handle 实际类型转换。
inline fn fdToHandle(fd: i64) File.Handle {
    const H = File.Handle;
    switch (@typeInfo(H)) {
        .int => return @intCast(fd),
        .pointer => return @ptrFromInt(@as(usize, @intCast(fd))),
        else => @compileError("unsupported File.Handle type"),
    }
}

/// File → i64 fd
inline fn fileToFd(file: File) i64 {
    const H = File.Handle;
    switch (@typeInfo(H)) {
        .int => return @intCast(file.handle),
        .pointer => return @intCast(@intFromPtr(file.handle)),
        else => @compileError("unsupported File.Handle type"),
    }
}

/// i64 fd → File
/// flags.nonblocking=false：fd 由 Glue 层管理，不假定非阻塞语义
inline fn fdToFile(fd: i64) File {
    return .{ .handle = fdToHandle(fd), .flags = .{ .nonblocking = false } };
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

/// std.Io 错误（anyerror）→ IOErrorKind 归一化映射
fn errToKind(err: anyerror) IOErrorKind {
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

/// 根据 File.Kind 构造 FileKind ADT 值（无字段变体 File/Directory/Symlink/Other）
///
/// FileKind 在 std/io/File.glue 中定义为 ADT：
///   type FileKind = | File | Directory | Symlink | Other
/// syscall 层按 std.Io.File.Kind 枚举选择构造器（跨平台）。
/// 返回的 Value 已 RC=1（makeAdt 初始 RC），调用方如需放入 record 字段须额外 retain。
fn makeFileKind(tctx: *ThreadContext, kind: File.Kind) SyscallError!Value {
    const ctor: []const u8 = switch (kind) {
        .file => "File",
        .directory => "Directory",
        .sym_link => "Symlink",
        else => "Other",
    };
    return Value.makeAdt(tctx, "FileKind", ctor, &.{}) catch return error.OutOfMemory;
}

// ──────────────────────────────────────────────
// seek/tell：条件编译（std.Io 无 tell API）
// ──────────────────────────────────────────────

const SeekFail = error{ SeekFailed };

/// 跨平台 seek：设置 fd 位置并返回新位置
/// whence: 0=SET, 1=CUR, 2=END（与 SEEK_SET/CUR/END、Windows FILE_BEGIN/CURRENT/END 一致）
fn seekFile(file: File, offset: i64, whence: i32) SeekFail!i64 {
    return switch (builtin.os.tag) {
        .windows => seekFileWindows(file, offset, whence),
        else => seekFilePosix(file, offset, whence),
    };
}

/// POSIX seek（std.c.lseek，libc 覆盖 Linux/macOS/BSD）
fn seekFilePosix(file: File, offset: i64, whence: i32) SeekFail!i64 {
    const fd: std.c.fd_t = @intCast(file.handle);
    const result = std.c.lseek(fd, @intCast(offset), @intCast(whence));
    if (result < 0) return error.SeekFailed;
    return @intCast(result);
}

/// Windows seek（SetFilePointerEx，kernel32）
/// Zig 0.16 的 std.os.windows.kernel32 未导出 SetFilePointerEx，此处直接 extern 声明
extern "kernel32" fn SetFilePointerEx(
    hFile: std.os.windows.HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: *i64,
    dwMoveMethod: u32,
) callconv(.c) c_int;

fn seekFileWindows(file: File, offset: i64, whence: i32) SeekFail!i64 {
    var new_pos: i64 = 0;
    const rc = SetFilePointerEx(file.handle, offset, &new_pos, @intCast(whence));
    if (rc == 0) return error.SeekFailed;
    return new_pos;
}

// ──────────────────────────────────────────────
// 文件 syscall
// ──────────────────────────────────────────────

/// __file_open(path: str, flags: i32, mode: i32) -> Throw<i64, IOError>
///
/// flags 为 POSIX 风格（O_RDONLY/O_WRONLY/O_RDWR/O_CREAT/O_TRUNC/O_APPEND）。
/// O_CREAT → Dir.createFile；否则 → Dir.openFile。
/// O_APPEND 当前由 Glue 层 seek End 语义处理（std.Io 无 append 选项）。
/// 返回 i64 fd（跨平台：POSIX i32 扩展，Windows HANDLE 转整数）。
pub fn file_open(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const flags = args[1].intCast(i32);
    _ = args[2]; // mode（permissions）：std.Io 用 .default_file，忽略 POSIX mode

    const O_ACCMODE: i32 = 3;
    const O_CREAT: i32 = 64;
    const O_TRUNC: i32 = 512;
    const accmode = flags & O_ACCMODE;
    const read = accmode != 1; // 非 O_WRONLY
    const write = accmode != 0; // 非 O_RDONLY
    const create = (flags & O_CREAT) != 0;
    const truncate = (flags & O_TRUNC) != 0;

    const file = if (create) blk: {
        const f = Dir.cwd().createFile(io, path, .{
            .read = read,
            .truncate = truncate,
            .permissions = .default_file,
        }) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "file_open failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
        break :blk f;
    } else blk: {
        const mode: Dir.OpenFileOptions.Mode = if (read and write) .read_write else if (write) .write_only else .read_only;
        const f = Dir.cwd().openFile(io, path, .{ .mode = mode }) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "file_open failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
        break :blk f;
    };
    return makeThrowOk(tctx, Value.fromI64(fileToFd(file)));
}

/// __file_close(fd: i64) -> Throw<Unit, IOError>
pub fn file_close(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    fdToFile(fd).close(io);
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_read(fd: i64, buf: u8[], len: usize) -> Throw<usize, IOError>
///
/// 优化：栈缓冲区 32KB，单次 read 即可填满 8192 默认 buf，减少 syscall 次数。
/// 语义保持单次 read（不循环阻塞，兼容管道/交互式 IO）。
pub fn file_read(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const arr = asArray(args[1]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_read: buf not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const len = args[2].intCast(usize);
    const actual_len = @min(len, arr.elements.len);
    // 将 Value 元素视作 u8：约定 u8[] 的每个 Value 都是 .u8 标量
    var tmp_buf: [32768]u8 = undefined;
    const read_len = @min(actual_len, tmp_buf.len);
    const file = fdToFile(fd);
    const n = file.readStreaming(io, &.{tmp_buf[0..read_len]}) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_read failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    // 将读到的字节写回 array（覆盖前 n 个元素）
    var i: usize = 0;
    while (i < n) : (i += 1) {
        arr.elements[i] = Value.fromU8(tmp_buf[i]);
    }
    return makeThrowOk(tctx, Value.fromUsize(n));
}

/// __file_write(fd: i64, buf: u8[], len: usize) -> Throw<usize, IOError>
///
/// 优化：栈缓冲区 32KB，单次 write 即可写完 8192 默认 buf。
pub fn file_write(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 3) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const arr = asArray(args[1]) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_write: buf not array", 22, null);
        return makeThrowErr(tctx, io_err);
    };
    const len = args[2].intCast(usize);
    const actual_len = @min(len, arr.elements.len);
    // 拼接 u8 字节，逐个 Value 转 u8
    var tmp_buf: [32768]u8 = undefined;
    const write_len = @min(actual_len, tmp_buf.len);
    var i: usize = 0;
    while (i < write_len) : (i += 1) {
        tmp_buf[i] = switch (arr.elements[i]) {
            .u8 => arr.elements[i].asU8(),
            else => 0,
        };
    }
    const file = fdToFile(fd);
    const n = file.writeStreaming(io, &.{}, &.{tmp_buf[0..write_len]}, 1) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_write failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromUsize(n));
}

/// __file_seek(fd: i64, offset: i64, whence: i32) -> Throw<i64, IOError>
///
/// whence: 0=SET, 1=CUR, 2=END
/// 跨平台条件编译：POSIX lseek / Windows SetFilePointerEx
pub fn file_seek(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    _ = io; // seek/tell 不依赖 std.Io（直接操作底层 handle）
    if (args.len != 3) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const offset = args[1].intCast(i64);
    const whence = args[2].intCast(i32);
    if (whence < 0 or whence > 2) {
        const io_err = try makeIOError(tctx, .invalid_input, "file_seek: bad whence", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const file = fdToFile(fd);
    const result = seekFile(file, offset, whence) catch {
        const io_err = try makeIOError(tctx, .other, "file_seek failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI64(result));
}

/// __file_tell(fd: i64) -> Throw<i64, IOError>
///
/// 获取当前 fd 位置（seek(fd, 0, SEEK_CUR)）
pub fn file_tell(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const file = fdToFile(fd);
    const result = seekFile(file, 0, 1) catch { // SEEK_CUR=1
        const io_err = try makeIOError(tctx, .other, "file_tell failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromI64(result));
}

/// __file_stat(path: str) -> Throw<Stat, IOError>
///
/// Stat 字段布局（与 std/io/File.glue 中 Stat newtype 定义对齐）：
///   size     : u64      — 文件大小（字节数）
///   mtime_ns : i64      — 修改时间（纳秒，Unix epoch）
///   ctime_ns : i64      — 元数据变更时间（纳秒，Unix epoch）
///   kind     : FileKind — 文件种类 ADT（File/Directory/Symlink/Other）
pub fn file_stat(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const stat = Dir.cwd().statFile(io, path, .{}) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_stat failed", 0, path);
        return makeThrowErr(tctx, io_err);
    };
    return makeStatValue(tctx, stat);
}

/// __file_fstat(fd: i64) -> Throw<Stat, IOError>
pub fn file_fstat(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const fd = args[0].intCast(i64);
    const file = fdToFile(fd);
    const stat = file.stat(io) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_fstat failed", 0, null);
        return makeThrowErr(tctx, io_err);
    };
    return makeStatValue(tctx, stat);
}

/// 从 std.Io.File.Stat 构造 Glue Stat record 值
fn makeStatValue(tctx: *ThreadContext, stat: File.Stat) SyscallError!Value {
    const kind_val = try makeFileKind(tctx, stat.kind);
    // kind_val 是堆对象（AdtValue），进入 record 字段需额外 retain（makeRecordWithNames 不主动 retain）
    _ = kind_val.retain();
    var fields: [4]Value = .{
        Value.fromU64(stat.size),
        Value.fromI64(@intCast(stat.mtime.nanoseconds)),
        Value.fromI64(@intCast(stat.ctime.nanoseconds)),
        kind_val,
    };
    const field_names: [4]?[]const u8 = .{ "size", "mtime_ns", "ctime_ns", "kind" };
    const stat_val = Value.makeRecordWithNames(tctx, "Stat", &fields, &field_names) catch return error.OutOfMemory;
    return makeThrowOk(tctx, stat_val);
}

/// __file_remove(path: str) -> Throw<Unit, IOError>
pub fn file_remove(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    Dir.cwd().deleteFile(io, path) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_remove failed", 0, path);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_rename(old: str, new: str) -> Throw<Unit, IOError>
pub fn file_rename(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const old_path = asStrBytes(args[0]);
    const new_path = asStrBytes(args[1]);
    const cwd = Dir.cwd();
    Dir.rename(cwd, old_path, cwd, new_path, io) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "file_rename failed", 0, old_path);
        return makeThrowErr(tctx, io_err);
    };
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __file_chmod(path: str, mode: i32) -> Throw<Unit, IOError>
///
/// 跨平台：POSIX 用 std.c.chmod（Unix 权限位）；Windows 权限模型不同，暂为 no-op。
pub fn file_chmod(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const mode = args[1].intCast(i32);

    if (builtin.os.tag == .windows) {
        // Windows 无 Unix 权限位模型，chmod 语义不适用，直接成功
        return makeThrowOk(tctx, Value.fromUnit());
    }

    var path_buf: [4096]u8 = undefined;
    const path_z = pathToZ(path, &path_buf) orelse {
        const io_err = try makeIOError(tctx, .invalid_input, "file_chmod: path too long", 36, path);
        return makeThrowErr(tctx, io_err);
    };
    const rc = std.c.chmod(path_z, @intCast(mode));
    if (rc != 0) {
        const io_err = try makeIOError(tctx, .permission_denied, "file_chmod failed", 0, path);
        return makeThrowErr(tctx, io_err);
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

// ──────────────────────────────────────────────
// 目录 syscall
// ──────────────────────────────────────────────

/// __dir_create(path: str, recursive: bool) -> Throw<Unit, IOError>
pub fn dir_create(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const recursive = asBool(args[1]);

    if (recursive) {
        Dir.cwd().createDirPath(io, path) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_create recursive failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
    } else {
        Dir.cwd().createDir(io, path, .default_dir) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_create failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __dir_remove(path: str, recursive: bool) -> Throw<Unit, IOError>
pub fn dir_remove(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 2) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    const recursive = asBool(args[1]);

    if (recursive) {
        Dir.cwd().deleteTree(io, path) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_remove failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
    } else {
        Dir.cwd().deleteDir(io, path) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_remove failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
    }
    return makeThrowOk(tctx, Value.fromUnit());
}

/// __dir_list(path: str) -> Throw<DirEntry[], IOError>
///
/// DirEntry 是 (name: str, kind: FileKind) record
pub fn dir_list(io: Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const path = asStrBytes(args[0]);
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        const io_err = try makeIOError(tctx, errToKind(err), "dir_list failed", 0, path);
        return makeThrowErr(tctx, io_err);
    };
    defer dir.close(io);

    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(tctx.backing);

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_list iterate failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
        const e = entry orelse break;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const name_val = Value.fromStringBytes(tctx, e.name) catch return error.OutOfMemory;
        _ = name_val.retain();
        // DirEntry.kind 字段是 FileKind ADT（File/Directory/Symlink/Other，无字段变体）
        const kind_val = try makeFileKind(tctx, e.kind);
        _ = kind_val.retain();
        var fields: [2]Value = .{ name_val, kind_val };
        const field_names: [2]?[]const u8 = .{ "name", "kind" };
        const rec = Value.makeRecordWithNames(tctx, "DirEntry", &fields, &field_names) catch return error.OutOfMemory;
        _ = rec.retain();
        entries.append(tctx.backing, rec) catch return error.OutOfMemory;
    }

    const arr_val = Value.makeArray(tctx, entries.items, null) catch return error.OutOfMemory;
    return makeThrowOk(tctx, arr_val);
}
