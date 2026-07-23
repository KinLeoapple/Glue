//! Glue Time syscall 原语（跨平台实现）
//!
//! 使用 std.Io.Clock（跨平台时钟）/ std.Io.Clock.Duration.sleep（跨平台 sleep）
//! 和 std.time.epoch（纯 Zig UTC 分量计算）替代 std.c 的 POSIX 专属函数。
//! 本地时区偏移通过 localtime_r（C 标准库，POSIX）获取；Windows 暂返回 0。
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md 第 5 节

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const ErrorValue = value.ErrorValue;
const syscall_mod = @import("mod.zig");
const SyscallError = syscall_mod.SyscallError;
const epoch = std.time.epoch;

// ──────────────────────────────────────────────
// C 时间库 extern 声明（仅 localtime_r，用于本地时区偏移）
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
fn makeTimeError(tctx: *ThreadContext, kind: TimeErrorKind, msg: []const u8, val: []const u8) SyscallError!Value {
    var fields: [TimeErrorFieldCount]Value = .{
        Value.fromI64(0), // fields[0] = __tag
        Value.fromU8(@intFromEnum(kind)), // fields[1] = kind
        try Value.fromStringBytes(tctx, msg), // fields[2] = msg
        try Value.fromStringBytes(tctx, val), // fields[3] = value
    };
    _ = fields[2].retain();
    _ = fields[3].retain();
    const field_names: [TimeErrorFieldCount]?[]const u8 = .{ "__tag", "kind", "msg", "value" };
    return Value.makeRecordWithNames(tctx, "TimeError", &fields, &field_names) catch return error.OutOfMemory;
}

/// 构造 Throw.ok(value) 包装
fn makeThrowOk(tctx: *ThreadContext, v: Value) SyscallError!Value {
    _ = v.retain();
    return Value.makeThrow(tctx, .{ .ok = v }) catch return error.OutOfMemory;
}

/// 构造 Throw.err(TimeError) 包装
fn makeThrowErr(tctx: *ThreadContext, err_val: Value) SyscallError!Value {
    const err_obj = err_val.asRef();
    _ = value.obj_header.retain(err_obj);
    const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", err_obj));
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
// 跨平台辅助：UTC 分量计算（纯 Zig，替代 gmtime_r）
// ──────────────────────────────────────────────

/// TimeComponents 字段数：__tag + 9 个用户字段
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
        Value.fromI64(0), // fields[0] = __tag
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

/// 从 Unix epoch 秒数计算 UTC 时间分量（纯 Zig，替代 gmtime_r）
/// 使用 std.time.epoch 模块，跨平台。
fn epochSecondsToComponents(tctx: *ThreadContext, total_sec: u64, sub_ns: u32) SyscallError!Value {
    const ep_secs = epoch.EpochSeconds{ .secs = total_sec };
    const ep_day = ep_secs.getEpochDay();
    const year_day = ep_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = ep_secs.getDaySeconds();
    // weekday: 1970-01-01 是周四（4，0=周日）
    const weekday: u8 = @intCast(@mod(ep_day.day + 4, 7));
    return makeTimeComponents(
        tctx,
        @intCast(year_day.year),
        @intFromEnum(month_day.month) + 1, // Month 枚举 jan=0
        @intCast(month_day.day_index + 1), // day_index 0-indexed
        @intCast(day_secs.getHoursIntoDay()),
        @intCast(day_secs.getMinutesIntoHour()),
        @intCast(day_secs.getSecondsIntoMinute()),
        sub_ns,
        weekday,
        @intCast(year_day.day + 1), // 0-indexed
    );
}

/// Howard Hinnant days_from_civil 算法：年月日 → 自 1970-01-01 的天数
/// 纯算术，跨平台，替代 timegm。
fn daysFromCivil(year: i32, month: u32, day: u32) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else @as(i64, year);
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400); // [0, 399]
    const m: u32 = month; // [1, 12]
    const doy: u32 = @intCast((153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + day - 1); // [0, 365]
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    return era * 146097 + @as(i64, doe) - 719468;
}

/// 获取本地时区相对 UTC 的秒偏移（跨平台）
/// POSIX: localtime_r(&now).gmtoff；Windows: 暂返回 0（后续可用 _get_timezone 完善）
fn getLocalOffsetSec(io: std.Io) i64 {
    if (builtin.os.tag == .windows) {
        return 0; // TODO: Windows 用 _get_timezone 或注册表获取时区偏移
    }
    const ts = std.Io.Clock.real.now(io);
    const now_sec: std.c.time_t = @intCast(@divFloor(ts.nanoseconds, 1_000_000_000));
    var t: tm = undefined;
    _ = localtime_r(&now_sec, &t);
    return @intCast(t.gmtoff);
}

// ──────────────────────────────────────────────
// 时钟 syscall（跨平台，使用 std.Io.Clock）
// ──────────────────────────────────────────────

/// __instant_now_ns() -> i128
///
/// 单调时钟（std.Io.Clock.awake，等价 CLOCK_MONOTONIC），纳秒精度
pub fn instant_now_ns(io: std.Io, _: *ThreadContext, _: []const Value) SyscallError!Value {
    const ts = std.Io.Clock.awake.now(io);
    return Value.fromI128(@intCast(ts.nanoseconds));
}

/// __systemtime_now_ns() -> i128
///
/// 堆时钟（std.Io.Clock.real，等价 CLOCK_REALTIME），Unix epoch 纳秒
/// Windows 上自动从 1601 epoch 转换为 Unix epoch
pub fn systemtime_now_ns(io: std.Io, _: *ThreadContext, _: []const Value) SyscallError!Value {
    const ts = std.Io.Clock.real.now(io);
    return Value.fromI128(@intCast(ts.nanoseconds));
}

/// __sleep_ns(ns: i128) -> Unit
///
/// 纳秒级 sleep（阻塞当前线程，跨平台）
/// 使用 std.Io.Clock.Duration.sleep，已处理 EINTR
pub fn sleep_ns(io: std.Io, _: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = args[0].intCast(i128);
    if (ns <= 0) return Value.fromUnit();
    // i96 最大值约 2.4e28 纳秒（~7.7e11 年），ns 不会溢出
    const dur = std.Io.Duration.fromNanoseconds(@intCast(ns));
    std.Io.Clock.Duration.sleep(.{ .raw = dur, .clock = .awake }, io) catch {};
    return Value.fromUnit();
}

/// __localtime_offset_minutes() -> i32
///
/// 本地时区相对 UTC 的分钟偏移（北京时间 = +480）
pub fn localtime_offset_minutes(io: std.Io, _: *ThreadContext, _: []const Value) SyscallError!Value {
    const offset_sec = getLocalOffsetSec(io);
    return Value.fromI32(@intCast(@divTrunc(offset_sec, 60)));
}

// ──────────────────────────────────────────────
// 时间分量转换 syscall
// ──────────────────────────────────────────────

/// __systemtime_to_local_components(ns: i128) -> TimeComponents
///
/// 本地时间分量：UTC 分量 + 本地时区偏移（跨平台）
pub fn systemtime_to_local_components(io: std.Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = args[0].intCast(i128);
    const offset_sec = getLocalOffsetSec(io);
    // 本地时间 = UTC + offset
    const local_ns = ns + @as(i128, offset_sec) * 1_000_000_000;
    const total_sec: u64 = @intCast(@divFloor(local_ns, 1_000_000_000));
    const sub_ns: u32 = @intCast(@mod(local_ns, 1_000_000_000));
    return epochSecondsToComponents(tctx, total_sec, sub_ns);
}

/// __systemtime_to_utc_components(ns: i128) -> TimeComponents
///
/// UTC 时间分量（纯 Zig std.time.epoch，跨平台，替代 gmtime_r）
pub fn systemtime_to_utc_components(io: std.Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgument;
    const ns = args[0].intCast(i128);
    const total_sec: u64 = @intCast(@divFloor(ns, 1_000_000_000));
    const sub_ns: u32 = @intCast(@mod(ns, 1_000_000_000));
    return epochSecondsToComponents(tctx, total_sec, sub_ns);
}

/// __components_to_ns_utc(comp: TimeComponents) -> Throw<i128, TimeError>
///
/// UTC 字段 → 纳秒，验证字段合法性（纯算术 daysFromCivil，跨平台，替代 timegm）
pub fn components_to_ns_utc(io: std.Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgument;
    const v = args[0];
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
    const year: i32 = rec.fields[1].intCast(i32);
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

    // 纯算术计算 epoch 秒（跨平台，替代 timegm）
    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    const epoch_secs: i64 = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    if (epoch_secs < 0) {
        const err = try makeTimeError(tctx, .out_of_range, "components_to_ns_utc: before 1970", "");
        return makeThrowErr(tctx, err);
    }
    const ns: i128 = @as(i128, epoch_secs) * 1_000_000_000 + @as(i128, nanos);
    return makeThrowOk(tctx, Value.fromI128(ns));
}
