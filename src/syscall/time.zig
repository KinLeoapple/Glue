//! Glue Time syscall 原语（跨平台实现）
//!
//! syscall 最小化原则：仅保留依赖宿主能力的原语（时钟读取、sleep、时区偏移）。
//! 纯算法（ns ↔ TimeComponents 转换、days_from_civil 等）已下沉为纯 Glue 实现，
//! 由 src/std/time/Calendar.glue + SystemTime.glue 承载，不占用 syscall 槽位。
//!
//! 保留的 4 个 syscall：
//!   - __instant_now_ns：单调时钟（CLOCK_MONOTONIC）
//!   - __systemtime_now_ns：墙钟（CLOCK_REALTIME，Unix epoch 纳秒）
//!   - __sleep_ns：纳秒级 sleep
//!   - __localtime_offset_minutes：本地时区偏移（依赖 libc localtime_r / kernel32）
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md 第 5 节

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");
const Value = value.Value;
const ThreadContext = value.obj_header.ThreadContext;
const registry = @import("registry.zig");
const SyscallError = registry.SyscallError;

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
// Windows 时区 API（kernel32，跨平台编译时仅在 Windows 链接）
// ──────────────────────────────────────────────

/// Windows SYSTEMTIME 结构（用于 TIME_ZONE_INFORMATION 的转换日期字段）
const SYSTEMTIME = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};

/// Windows TIME_ZONE_INFORMATION 结构
/// Bias: UTC = local + Bias（分钟），即本地时间落后 UTC 的分钟数
/// StandardBias / DaylightBias: 在 Bias 基础上的额外偏移（通常 StandardBias=0, DaylightBias=-60）
const TIME_ZONE_INFORMATION = extern struct {
    bias: i32,
    standard_name: [32]u16,
    standard_date: SYSTEMTIME,
    standard_bias: i32,
    daylight_name: [32]u16,
    daylight_date: SYSTEMTIME,
    daylight_bias: i32,
};

extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) callconv(.c) u32;

/// TIME_ZONE_ID 常量（GetTimeZoneInformation 返回值）
const TIME_ZONE_ID_UNKNOWN: u32 = 0;
const TIME_ZONE_ID_STANDARD: u32 = 1;
const TIME_ZONE_ID_DAYLIGHT: u32 = 2;
const TIME_ZONE_ID_INVALID: u32 = 0xFFFFFFFF;

// ──────────────────────────────────────────────
// 跨平台辅助：本地时区偏移
// ──────────────────────────────────────────────

/// 获取本地时区相对 UTC 的秒偏移（跨平台）
/// POSIX: localtime_r(&now).gmtoff
/// Windows: GetTimeZoneInformation，根据返回值叠加 StandardBias/DaylightBias
/// 偏移语义：返回值为「本地时间 - UTC」的秒数（北京时间 +28800）
fn getLocalOffsetSec(io: std.Io) i64 {
    if (builtin.os.tag == .windows) {
        var tzi: TIME_ZONE_INFORMATION = undefined;
        const tz_id = GetTimeZoneInformation(&tzi);
        if (tz_id == TIME_ZONE_ID_INVALID) return 0;
        // UTC = local + (Bias + extra_bias)
        // → local - UTC = -(Bias + extra_bias)
        const extra_bias: i32 = switch (tz_id) {
            TIME_ZONE_ID_DAYLIGHT => tzi.daylight_bias,
            else => tzi.standard_bias, // UNKNOWN 和 STANDARD 都用 standard_bias
        };
        const total_bias_min: i32 = tzi.bias + extra_bias;
        return @as(i64, -total_bias_min) * 60;
    }
    const ts = std.Io.Clock.real.now(io);
    const now_sec: std.c.time_t = @intCast(@divFloor(ts.nanoseconds, 1_000_000_000));
    var t: tm = undefined;
    // localtime_r 失败时返回 null，此时返回 0（UTC）避免读取未初始化内存
    if (localtime_r(&now_sec, &t) == null) return 0;
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
    // fromNanoseconds 接受 u64（最大约 1.8e19 ns ≈ 584 年），
    // i128 超出 u64 范围会导致 @intCast panic，钳位到 u64::MAX（约 584 年 sleep，实际无意义但安全）
    const ns_clamped: u64 = if (ns > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(ns);
    const dur = std.Io.Duration.fromNanoseconds(ns_clamped);
    std.Io.Clock.Duration.sleep(.{ .raw = dur, .clock = .awake }, io) catch {};
    return Value.fromUnit();
}

/// __sleep_async(ns: i128) -> *ChannelValue
///
/// 异步 sleep：创建完成 channel + launch 线程跑 sleep，
/// 完成后 chan.trySend(unit) + wake_chan_recv_fn 唤醒等待协程。
/// 返回 channel 指针，协程在 channel 上挂起（orbit_chan_recv）。
///
/// 协程不阻塞——挂起在 channel 上，worker 线程可跑其他协程。
/// sleep 线程完成后 ioComplete + 释放资源 + 退出。
pub fn sleep_async(io: std.Io, tctx: *ThreadContext, args: []const Value) SyscallError!Value {
    if (args.len != 1) return error.InvalidArgument;
    const ns = args[0].intCast(i128);
    if (ns <= 0) return Value.fromUnit();

    const ns_clamped: u64 = if (ns > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(ns);

    // 创建完成 channel（cap=1，buffer 容纳一个 unit 值）
    const chan = value.ChannelValue.create(tctx, 1) catch return error.OutOfMemory;

    // launch 线程跑 sleep + ioComplete
    const args_ptr = tctx.backing.create(SleepAsyncArgs) catch return error.OutOfMemory;
    args_ptr.* = .{
        .io = io,
        .chan = chan,
        .nanos = ns_clamped,
        .bridge = tctx.io_bridge.?,
        .wake_fn = tctx.wake_chan_recv_fn.?,
        .backing = tctx.backing,
    };
    const thread = std.Thread.spawn(.{}, sleepAsyncWorker, .{args_ptr}) catch {
        tctx.backing.destroy(args_ptr);
        // thread launch 失败：同步 sleep 阻塞当前线程（保底，不应发生）
        std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = ns_clamped }, .clock = .awake }, io) catch {};
        return Value.fromUnit();
    };
    thread.detach();

    // 返回 channel 指针（stdlib 调 recv 挂起）
    return Value.fromRef(@ptrCast(&chan.header));
}

/// sleep_async 的 worker 线程参数
const SleepAsyncArgs = struct {
    io: std.Io,
    chan: *value.ChannelValue,
    nanos: u64,
    bridge: *anyopaque,
    wake_fn: *const fn (bridge: *anyopaque, chan: *anyopaque) void,
    backing: std.mem.Allocator,
};

/// sleep_async worker 线程：sleep + trySend(unit) + wake + 释放资源。
/// 独立线程跑，不阻塞协程的 worker 线程。
fn sleepAsyncWorker(args: *SleepAsyncArgs) void {
    // 跨平台 sleep
    const dur = std.Io.Duration.fromNanoseconds(args.nanos);
    std.Io.Clock.Duration.sleep(.{ .raw = dur, .clock = .awake }, args.io) catch {};

    // sleep 完成：发 channel + 唤醒等待协程
    _ = args.chan.trySend(Value.fromUnit());
    args.wake_fn(args.bridge, @ptrCast(args.chan));

    // 释放资源
    args.backing.destroy(args);
}

/// __localtime_offset_minutes() -> i32
///
/// 本地时区相对 UTC 的分钟偏移（北京时间 = +480）
pub fn localtime_offset_minutes(io: std.Io, _: *ThreadContext, _: []const Value) SyscallError!Value {
    const offset_sec = getLocalOffsetSec(io);
    return Value.fromI32(@intCast(@divTrunc(offset_sec, 60)));
}
