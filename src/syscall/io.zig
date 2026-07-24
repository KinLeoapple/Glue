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
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;
const util = @import("util.zig");

// 共享错误工具（从 io.zig 抽取到 util.zig，io.zig/net.zig 共用）
const IOErrorKind = util.IOErrorKind;
const errToKind = util.errToKind;
const makeIOError = util.makeIOError;
const makeThrowOk = util.makeThrowOk;
const makeThrowErr = util.makeThrowErr;

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
//
// IOErrorKind / errToKind / makeIOError / makeThrowOk / makeThrowErr
// 已抽取到 util.zig（io.zig/net.zig 共享），见文件顶部 import。

/// 根据 File.Kind 构造 FileKind ADT 值（无字段变体 File/Directory/Symlink/Other）
///
/// FileKind 在 std/io/File.glue 中定义为 ADT：
///   type FileKind = | File | Directory | Symlink | Other
/// IR 编译器为每个变体分配 __tag（按声明顺序 0/1/2/3），field_count=1（仅 __tag）。
/// syscall 层按 std.Io.File.Kind 枚举选择构造器（跨平台）。
/// 返回的 Value 已 RC=1（makeRecordWithNames 初始 RC），调用方如需放入 record 字段须额外 retain。
fn makeFileKind(tctx: *ThreadContext, kind: File.Kind) SyscallError!Value {
    // __tag 值按 FileKind ADT 声明顺序：File=0, Directory=1, Symlink=2, Other=3
    const tag_val: i64 = switch (kind) {
        .file => 0,
        .directory => 1,
        .sym_link => 2,
        else => 3, // unknown/whiteout/door/event_port/named_pipe/block_device/character_device/unix_domain_socket
    };
    var fields: [1]Value = .{
        Value.fromI64(tag_val), // fields[0] = __tag
    };
    const field_names: [1]?[]const u8 = .{"__tag"};
    return Value.makeRecordWithNames(tctx, "FileKind", &fields, &field_names) catch return error.OutOfMemory;
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

    // POSIX O_ 标志位按平台取值（Linux 与 BSD/macOS 不同，硬编码会导致位误判）
    // O_ACCMODE 低 2 位跨平台一致；O_CREAT/O_TRUNC 按平台 switch
    const O_ACCMODE: i32 = 3;
    const O_CREAT: i32 = switch (builtin.os.tag) {
        .linux => 64, // 0o100
        .macos, .ios, .watchos, .tvos, .freebsd, .netbsd, .openbsd, .dragonfly => 512, // 0o200
        .windows => 0, // Windows 不使用 POSIX O_ 位
        else => 64, // 默认 Linux 值
    };
    const O_TRUNC: i32 = switch (builtin.os.tag) {
        .linux => 512, // 0o1000
        .macos, .ios, .watchos, .tvos, .freebsd, .netbsd, .openbsd, .dragonfly => 1024, // 0o400
        .windows => 0,
        else => 512,
    };
    const accmode = flags & O_ACCMODE;
    // accmode 仅 0(O_RDONLY)/1(O_WRONLY)/2(O_RDWR) 合法，3+ 为非法值
    if (accmode > 2) {
        const io_err = try makeIOError(tctx, .invalid_input, "file_open: invalid access mode", 22, path);
        return makeThrowErr(tctx, io_err);
    }
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
    // 负 len 值会导致 intCast panic，先验证再转换
    const len_raw = args[2].intCast(i64);
    if (len_raw < 0) {
        const io_err = try makeIOError(tctx, .invalid_input, "file_read: negative len", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const len: usize = @intCast(len_raw);
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
    // 负 len 值会导致 intCast panic，先验证再转换
    const len_raw = args[2].intCast(i64);
    if (len_raw < 0) {
        const io_err = try makeIOError(tctx, .invalid_input, "file_write: negative len", 22, null);
        return makeThrowErr(tctx, io_err);
    }
    const len: usize = @intCast(len_raw);
    const actual_len = @min(len, arr.elements.len);
    // 拼接 u8 字节，逐个 Value 转 u8；非 u8 元素直接报错而非静默写零
    var tmp_buf: [32768]u8 = undefined;
    const write_len = @min(actual_len, tmp_buf.len);
    var i: usize = 0;
    while (i < write_len) : (i += 1) {
        tmp_buf[i] = switch (arr.elements[i]) {
            .u8 => arr.elements[i].asU8(),
            else => {
                const io_err = try makeIOError(tctx, .invalid_input, "file_write: buf element not u8", 22, null);
                return makeThrowErr(tctx, io_err);
            },
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
///
/// Stat 是 newtype（type Stat = Stat(size, mtime_ns, ctime_ns, kind)），
/// IR 编译器注册 field_id：__tag=0, size=1, mtime_ns=2, ctime_ns=3, kind=4。
fn makeStatValue(tctx: *ThreadContext, stat: File.Stat) SyscallError!Value {
    const kind_val = try makeFileKind(tctx, stat.kind);
    // kind_val RC=1，直接交 makeRecordWithNames 窃取，无需额外 retain
    // mtime/ctime.nanoseconds 为 i128，钳位到 i64 范围避免 @intCast panic（超出 ±292 年的极端时间戳）
    const mtime_ns: i64 = if (stat.mtime.nanoseconds > std.math.maxInt(i64))
        std.math.maxInt(i64)
    else if (stat.mtime.nanoseconds < std.math.minInt(i64))
        std.math.minInt(i64)
    else
        @intCast(stat.mtime.nanoseconds);
    const ctime_ns: i64 = if (stat.ctime.nanoseconds > std.math.maxInt(i64))
        std.math.maxInt(i64)
    else if (stat.ctime.nanoseconds < std.math.minInt(i64))
        std.math.minInt(i64)
    else
        @intCast(stat.ctime.nanoseconds);
    var fields: [5]Value = .{
        Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
        Value.fromU64(stat.size), // fields[1] = size
        Value.fromI64(mtime_ns), // fields[2] = mtime_ns
        Value.fromI64(ctime_ns), // fields[3] = ctime_ns
        kind_val, // fields[4] = kind（RC=1，由 record 窃取）
    };
    const field_names: [5]?[]const u8 = .{ "__tag", "size", "mtime_ns", "ctime_ns", "kind" };
    const stat_val = Value.makeRecordWithNames(tctx, "Stat", &fields, &field_names) catch {
        kind_val.release(tctx); // OOM：释放 kind_val
        return error.OutOfMemory;
    };
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
    // mode 为 i32，chmod 需要 mode_t（POSIX 通常 u16/u32 因平台而异）。
    // 负 mode 用 @bitCast 转 u32，再窄化到 mode_t 避免 panic
    const mode_u: u32 = @bitCast(mode);
    const rc = std.c.chmod(path_z, @truncate(mode_u));
    if (rc != 0) {
        // 读取真实 errno 映射到 IOErrorKind，而非硬编码 permission_denied
        const errno_val: i32 = blk: {
            if (@hasDecl(std.c, "_errno")) {
                break :blk @intCast(std.c._errno().*);
            }
            break :blk 0;
        };
        const kind: IOErrorKind = switch (errno_val) {
            2 => .not_found, // ENOENT
            13 => .permission_denied, // EACCES
            17 => .already_exists, // EEXIST
            22 => .invalid_input, // EINVAL
            else => .other,
        };
        const io_err = try makeIOError(tctx, kind, "file_chmod failed", errno_val, path);
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

    // 成功路径（makeThrowOk）将 entries 所有权转移给 makeArray；
    // 任何失败/错误返回时（iterate 失败、OOM、makeThrowErr）释放已创建的 DirEntry，避免泄漏
    var entries_consumed = false;
    defer {
        if (!entries_consumed) {
            for (entries.items) |e| e.release(tctx);
        }
    }

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |err| {
            const io_err = try makeIOError(tctx, errToKind(err), "dir_list iterate failed", 0, path);
            return makeThrowErr(tctx, io_err);
        };
        const e = entry orelse break;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const name_val = Value.fromStringBytes(tctx, e.name) catch return error.OutOfMemory;
        // name_val RC=1，直接交 record 窃取，无需 retain
        // DirEntry.kind 字段是 FileKind ADT（File/Directory/Symlink/Other，无字段变体）
        const kind_val = makeFileKind(tctx, e.kind) catch {
            name_val.release(tctx); // OOM：释放 name_val
            return error.OutOfMemory;
        };
        // kind_val RC=1，直接交 record 窃取，无需 retain
        // DirEntry 是 newtype，field_id：__tag=0, name=1, kind=2
        var fields: [3]Value = .{
            Value.fromI64(0), // fields[0] = __tag（newtype 固定 0）
            name_val, // fields[1] = name（RC=1，由 record 窃取）
            kind_val, // fields[2] = kind（RC=1，由 record 窃取）
        };
        const field_names: [3]?[]const u8 = .{ "__tag", "name", "kind" };
        const rec = Value.makeRecordWithNames(tctx, "DirEntry", &fields, &field_names) catch {
            name_val.release(tctx); // OOM：释放已分配字段
            kind_val.release(tctx);
            return error.OutOfMemory;
        };
        // rec RC=1，直接交 makeArray 窃取，无需 retain
        entries.append(tctx.backing, rec) catch {
            rec.release(tctx); // OOM：释放 rec（级联释放 name_val/kind_val）
            return error.OutOfMemory;
        };
    }

    const arr_val = Value.makeArray(tctx, entries.items, null) catch return error.OutOfMemory;
    // makeArray 成功，entries 所有权转移给 arr_val，失败时不再释放
    entries_consumed = true;
    return makeThrowOk(tctx, arr_val);
}
