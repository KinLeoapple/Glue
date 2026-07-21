//! Glue Time syscall 原语
//!
//! 包装宿主时钟/sleep/时间分量转换，对外暴露为 __ 前缀 syscall 函数。
//! 业务错误通过 ThrowValue.err 传递（TimeError 内部封装 kind/msg/value 字段）。
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md 第 5 节

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ErrorValue = value.ErrorValue;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;

// ──────────────────────────────────────────────
// C 时间库 extern 声明（std.c 在 Zig 0.16 中未导出 tm/localtime_r 等）
// ──────────────────────────────────────────────

/// struct tm（POSIX 时间分量结构）
const tm = extern struct {
    sec: c_int, // 秒 [0..59]
    min: c_int, // 分钟 [0..59]
    hour: c_int, // 小时 [0..23]
    mday: c_int, // 月内日期 [1..31]
    mon: c_int, // 月份 [0..11]
    year: c_int, // 年份 - 1900
    wday: c_int, // 周内日期 [0..6]，0=周日
    yday: c_int, // 年内日期 [0..365]
    isdst: c_int, // 夏令时标志
    gmtoff: c_long, // 相对 UTC 的秒偏移
    zone: ?[*:0]const u8, // 时区缩写
};

extern "c" fn localtime_r(time: *const std.c.time_t, result: *tm) ?*tm;
extern "c" fn gmtime_r(time: *const std.c.time_t, result: *tm) ?*tm;
extern "c" fn timegm(t: *tm) std.c.time_t;
extern "c" fn mktime(t: *tm) std.c.time_t;

// ──────────────────────────────────────────────
// 辅助：从 Value 提取参数
// ──────────────────────────────────────────────

inline fn asI128(v: Value) i128 {
    return switch (v) {
        .i32 => v.asI32(),
        .i64 => v.asI64(),
        .i128 => v.asI128(),
        .usize => @intCast(v.asUsize()),
        else => 0,
    };
}

inline fn asI64(v: Value) i64 {
    return switch (v) {
        .i32 => v.asI32(),
        .i64 => v.asI64(),
        .i128 => @intCast(v.asI128()),
        else => 0,
    };
}

// ──────────────────────────────────────────────
// 辅助：构造返回值
// ──────────────────────────────────────────────

/// TimeErrorKind 枚举（与 TimeError.glue 中 ADT 变体一一对应，0-indexed）
const TimeErrorKind = enum(u8) {
    invalid_date_time = 0,
    invalid_format,
    parse_failed,
    out_of_range,
    timezone_not_found,
};

/// TimeError 字段数：__tag + 3 个用户字段（kind/msg/value）
const TimeErrorFieldCount: usize = 4;

/// 构造 TimeError 值（与 Glue error_newtype 布局一致，包含 __tag）
/// Glue 中 TimeError 是 error_newtype，field_id 从 1 开始（field_id=0 是 __tag）
/// 使用 RecordValue 而非 AdtValue，确保 execRecordGet 能正确按 field_id 读取
fn makeTimeError(tctx: *ThreadContext, kind: TimeErrorKind, msg: []const u8, val: []const u8) SyscallError!Value {
    var fields: [TimeErrorFieldCount]Value = .{
        Value.fromI64(0), // fields[0] = __tag
        Value.fromU8(@intFromEnum(kind)), // fields[1] = kind
        try Value.fromStringBytes(tctx, msg), // fields[2] = msg
        try Value.fromStringBytes(tctx, val), // fields[3] = value
    };
    _ = fields[2].retain(); // msg 字符串 retain（makeRecordWithNames 不主动 retain）
    _ = fields[3].retain(); // value 字符串 retain
    const field_names: [TimeErrorFieldCount]?[]const u8 = .{ "__tag", "kind", "msg", "value" };
    return Value.makeRecordWithNames(tctx, "TimeError", &fields, &field_names) catch return error.OutOfMemory;
}

/// 构造 Throw.ok(value) 包装
fn makeThrowOk(tctx: *ThreadContext, v: Value) SyscallError!Value {
    _ = v.retain();
    return Value.makeThrow(tctx, .{ .ok = v }) catch return error.OutOfMemory;
}

/// 构造 Throw.err(TimeError) 包装
/// TimeError 现在是 RecordValue（含 __tag），msg 在 fields[2]
fn makeThrowErr(tctx: *ThreadContext, err_val: Value) SyscallError!Value {
    const err_obj = err_val.asRef();
    _ = value.obj_header.retain(err_obj);
    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", err_obj));
    // msg 在 field_id=2（__tag=0, kind=1, msg=2）
    const msg_bytes = if (rec.fields.len > 2) switch (rec.fields[2]) {
        .ref => |o| if (o.type_tag == .str) blk: {
            const s: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", o));
            break :blk s.bytes();
        } else "",
        else => "",
    } else "";
    const err_ev = Value.makeError(tctx, "time error", msg_bytes, true) catch return error.OutOfMemory;
    _ = value.obj_header.retain(err_ev.asRef());
    value.obj_header.release(err_obj, tctx);
    const err_val_ptr: *ErrorValue = @alignCast(@fieldParentPtr("header", err_ev.asRef()));
    return Value.makeThrow(tctx, .{ .err = err_val_ptr }) catch return error.OutOfMemory;
}

// ──────────────────────────────────────────────
// 时钟 syscall
// ──────────────────────────────────────────────

/// __instant_now_ns() -> i128
///
/// 单调时钟（CLOCK_MONOTONIC），纳秒精度
pub fn instant_now_ns(_: *ThreadContext, _: []const Value) SyscallError!Value {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return Value.fromI128(0);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    return Value.fromI128(ns);
}

/// __systemtime_now_ns() -> i128
///
/// 堆时钟（CLOCK_REALTIME），Unix epoch 纳秒
pub fn systemtime_now_ns(_: *ThreadContext, _: []const Value) SyscallError!Value {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return Value.fromI128(0);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    return Value.fromI128(ns);
}

/// __sleep_ns(ns: i128) -> Unit
///
/// 纳秒级 sleep（阻塞当前线程）
pub fn sleep_ns(_: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = asI128(args[0]);
    if (ns <= 0) return Value.fromUnit();
    const sec: i64 = @intCast(@divFloor(ns, 1_000_000_000));
    const rem_ns: i64 = @intCast(@mod(ns, 1_000_000_000));
    const req = std.c.timespec{
        .sec = sec,
        .nsec = @intCast(rem_ns),
    };
    var rem: std.c.timespec = undefined;
    // nanosleep 被信号打断时返回剩余时间，循环重试
    var cur_req = req;
    while (true) {
        const rc = std.c.nanosleep(&cur_req, &rem);
        if (rc == 0) break;
        // 错误：返回（首批实现忽略错误）
        break;
    }
    return Value.fromUnit();
}

/// __localtime_offset_minutes() -> i32
///
/// 本地时区相对 UTC 的分钟偏移（北京时间 = +480）
pub fn localtime_offset_minutes(_: *ThreadContext, _: []const Value) SyscallError!Value {
    // 通过 clock_gettime(CLOCK_REALTIME) 获取当前时间（替代已删除的 std.time.timestamp）
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return Value.fromI32(0);
    const now: std.c.time_t = ts.sec;
    var t: tm = undefined;
    _ = localtime_r(&now, &t);
    // gmtoff 是秒数，转分钟
    return Value.fromI32(@intCast(@divTrunc(t.gmtoff, 60)));
}

// ──────────────────────────────────────────────
// 时间分量转换 syscall
// ──────────────────────────────────────────────

/// TimeComponents 字段数：__tag + 9 个用户字段
/// Glue 中 TimeComponents 是 ADT（单构造器），field_id 从 1 开始（field_id=0 是 __tag）
/// syscall 层必须与 Glue 的 ADT 布局一致：fields[0]=__tag, fields[1..9]=用户字段
const TimeComponentsFieldCount: usize = 10;

/// 构造 TimeComponents record 值（与 Glue ADT 布局一致，包含 __tag）
fn makeTimeComponents(
    tctx: *ThreadContext,
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanos: u32,
    weekday: u8,
    day_of_year: u16,
) SyscallError!Value {
    var fields: [TimeComponentsFieldCount]Value = .{
        Value.fromI64(0), // fields[0] = __tag（构造器索引 0）
        Value.fromI32(year), // fields[1] = year
        Value.fromU8(month), // fields[2] = month
        Value.fromU8(day), // fields[3] = day
        Value.fromU8(hour), // fields[4] = hour
        Value.fromU8(minute), // fields[5] = minute
        Value.fromU8(second), // fields[6] = second
        Value.fromU32(nanos), // fields[7] = nanos
        Value.fromU8(weekday), // fields[8] = weekday
        Value.fromU16(day_of_year), // fields[9] = day_of_year
    };
    const field_names: [TimeComponentsFieldCount]?[]const u8 = .{
        "__tag", "year", "month", "day", "hour", "minute", "second", "nanos", "weekday", "day_of_year",
    };
    return Value.makeRecordWithNames(tctx, "TimeComponents", &fields, &field_names) catch return error.OutOfMemory;
}

/// __systemtime_to_local_components(ns: i128) -> TimeComponents
pub fn systemtime_to_local_components(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = asI128(args[0]);
    const sec: i64 = @intCast(@divFloor(ns, 1_000_000_000));
    const sub_ns: i64 = @intCast(@mod(ns, 1_000_000_000));
    const sec_t: std.c.time_t = @intCast(sec);
    var t: tm = undefined;
    _ = localtime_r(&sec_t, &t);
    return makeTimeComponents(
        tctx,
        @intCast(t.year + 1900),
        @intCast(t.mon + 1),
        @intCast(t.mday),
        @intCast(t.hour),
        @intCast(t.min),
        @intCast(t.sec),
        @intCast(if (sub_ns < 0) 0 else sub_ns),
        @intCast(t.wday),
        @intCast(t.yday + 1),
    );
}

/// __systemtime_to_utc_components(ns: i128) -> TimeComponents
pub fn systemtime_to_utc_components(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = asI128(args[0]);
    const sec: i64 = @intCast(@divFloor(ns, 1_000_000_000));
    const sub_ns: i64 = @intCast(@mod(ns, 1_000_000_000));
    const sec_t: std.c.time_t = @intCast(sec);
    var t: tm = undefined;
    _ = gmtime_r(&sec_t, &t);
    return makeTimeComponents(
        tctx,
        @intCast(t.year + 1900),
        @intCast(t.mon + 1),
        @intCast(t.mday),
        @intCast(t.hour),
        @intCast(t.min),
        @intCast(t.sec),
        @intCast(if (sub_ns < 0) 0 else sub_ns),
        @intCast(t.wday),
        @intCast(t.yday + 1),
    );
}

/// __components_to_ns_utc(comp: TimeComponents) -> Throw<i128, TimeError>
///
/// UTC 字段 → 纳秒，验证字段合法性
pub fn components_to_ns_utc(tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const v = args[0];
    // 提取 record 字段
    const rec: *value.RecordValue = switch (v) {
        .ref => |obj| if (obj.type_tag == .record) @alignCast(@fieldParentPtr("header", obj)) else {
            const err = try makeTimeError(tctx, .invalid_format, "components_to_ns_utc: not a record", "");
            return makeThrowErr(tctx, err);
        },
        else => {
            const err = try makeTimeError(tctx, .invalid_format, "components_to_ns_utc: not a record", "");
            return makeThrowErr(tctx, err);
        },
    };
    if (rec.fields.len < TimeComponentsFieldCount) {
        const err = try makeTimeError(tctx, .invalid_format, "components_to_ns_utc: field count mismatch", "");
        return makeThrowErr(tctx, err);
    }
    // 用户字段从 fields[1] 开始（fields[0] 是 __tag）
    const year: i32 = switch (rec.fields[1]) {
        .i32 => rec.fields[1].asI32(),
        .i64 => @intCast(rec.fields[1].asI64()),
        else => 0,
    };
    const month: u8 = switch (rec.fields[2]) {
        .u8 => rec.fields[2].asU8(),
        else => 1,
    };
    const day: u8 = switch (rec.fields[3]) {
        .u8 => rec.fields[3].asU8(),
        else => 1,
    };
    const hour: u8 = switch (rec.fields[4]) {
        .u8 => rec.fields[4].asU8(),
        else => 0,
    };
    const minute: u8 = switch (rec.fields[5]) {
        .u8 => rec.fields[5].asU8(),
        else => 0,
    };
    const second: u8 = switch (rec.fields[6]) {
        .u8 => rec.fields[6].asU8(),
        else => 0,
    };
    const nanos: u32 = switch (rec.fields[7]) {
        .u32 => rec.fields[7].asU32(),
        else => 0,
    };

    // 字段合法性验证
    if (month < 1 or month > 12) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "month={d}", .{month}) catch "month out of range";
        const err = try makeTimeError(tctx, .invalid_date_time, "components_to_ns_utc: month out of range", msg);
        return makeThrowErr(tctx, err);
    }
    if (day < 1 or day > 31) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "day={d}", .{day}) catch "day out of range";
        const err = try makeTimeError(tctx, .invalid_date_time, "components_to_ns_utc: day out of range", msg);
        return makeThrowErr(tctx, err);
    }
    if (hour > 23 or minute > 59 or second > 59) {
        const err = try makeTimeError(tctx, .invalid_date_time, "components_to_ns_utc: time field out of range", "");
        return makeThrowErr(tctx, err);
    }
    if (nanos >= 1_000_000_000) {
        const err = try makeTimeError(tctx, .invalid_date_time, "components_to_ns_utc: nanos >= 1e9", "");
        return makeThrowErr(tctx, err);
    }

    // 使用 mktime 转换（timegm 是 UTC 版本，避免时区影响）
    var t: tm = .{
        .sec = @intCast(second),
        .min = @intCast(minute),
        .hour = @intCast(hour),
        .mday = @intCast(day),
        .mon = @intCast(month - 1),
        .year = @intCast(year - 1900),
        .wday = 0,
        .yday = 0,
        .isdst = 0,
        .gmtoff = 0,
        .zone = null,
    };
    // timegm 是 GNU/BSD 扩展，用于 UTC 时间转换；macOS 支持
    const tt = timegm(&t);
    if (tt < 0) {
        const err = try makeTimeError(tctx, .out_of_range, "components_to_ns_utc: timegm failed", "");
        return makeThrowErr(tctx, err);
    }
    const ns: i128 = @as(i128, tt) * 1_000_000_000 + @as(i128, nanos);
    return makeThrowOk(tctx, Value.fromI128(ns));
}
