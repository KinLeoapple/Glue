//! Io 原语与协程桥接：Glue 调度器与 Zig std.Io 的边界。
//!
//! 核心协议（spec §4.7）：
//! IO 函数体内部用「临时 channel + Io.Select.concurrent」桥接：
//! 1. 协程调用 stdlib async IO 函数（如 Timer.sleep）
//! 2. stdlib 调用 syscall 异步变体（如 __sleep_async），传入完成 channel
//! 3. syscall 在 Io 线程池跑 op，完成后调 bridge.ioComplete(chan, result)
//! 4. ioComplete 做 chan.trySend(result) + registry.wakeChanRecv(chan)
//! 5. 协程在 chan 上挂起（orbit_chan_recv），被唤醒后继续段执行
//!
//! Io 层不知 Glue 协程，只往 channel 发数据 + 通知 registry 唤醒等待者。
//! 跨平台由 std.Io 保证（Linux io_uring / macOS GCD / Windows IOCP）。
//!
//! 临时 channel 分配策略（spec §8 风险表）：
//! 优先使用帧内内联 channel（无堆分配），溢出时退化为堆分配。

const std = @import("std");
const value_mod = @import("value");
const ChannelValue = value_mod.ChannelValue;
const Value = value_mod.Value;
const suspend_registry_mod = @import("suspend_registry.zig");
const SuspendRegistry = suspend_registry_mod.SuspendRegistry;

/// Io 桥接层：Glue 调度器与 Zig std.Io 的边界。
///
/// 持有 io + SuspendRegistry 引用，提供 Io 完成后的 channel 发送 + 协程唤醒。
/// 由 Scheduler 在 startWorkers 时创建，所有 worker 线程共享同一 IoBridge。
pub const IoBridge = struct {
    io: std.Io,
    registry: *SuspendRegistry,
    backing: std.mem.Allocator,

    /// 创建 Io 桥接
    pub fn init(io: std.Io, registry: *SuspendRegistry, backing: std.mem.Allocator) IoBridge {
        return .{
            .io = io,
            .registry = registry,
            .backing = backing,
        };
    }

    /// Io 完成回调：发 channel + 唤醒等待协程。
    ///
    /// 由 Io 线程池的 op 函数在完成后调用：
    /// 1. chan.trySend(result)：非阻塞发送结果到完成 channel
    /// 2. registry.wakeChanRecv(chan)：唤醒所有等待该 channel 的协程
    ///
    /// trySend 失败（channel 满）时丢弃结果并唤醒（协程 try-first 会重试）。
    /// 跨线程安全：ChannelValue 和 SuspendRegistry 内部均有锁保护。
    pub fn ioComplete(self: *IoBridge, chan: *ChannelValue, result: Value) void {
        _ = chan.trySend(result);
        self.registry.wakeChanRecv(chan);
    }

    /// Io 失败回调：发错误值到 channel + 唤醒等待协程。
    pub fn ioFail(self: *IoBridge, chan: *ChannelValue, err_val: Value) void {
        self.ioComplete(chan, err_val);
    }

    /// Io 关闭回调：关闭 channel + 唤醒所有等待者（recv 返回 null 表示关闭）。
    pub fn ioClose(self: *IoBridge, chan: *ChannelValue) void {
        chan.close();
        self.registry.wakeChanRecv(chan);
        self.registry.wakeChanSend(chan);
    }

    /// 在独立线程跑 sleep，完成后发 channel + 唤醒协程。
    ///
    /// Timer.sleep 迁移用：协程调 __sleep_async(nanos) → 此函数 → 协程在 chan 挂起。
    /// sleep 完成后 ioComplete 发 unit 值 + 唤醒。
    ///
    /// 实现用独立线程跑 Io.Timeout.sleep（跨平台阻塞 sleep）。
    /// 协程不阻塞——挂起在 channel 上，worker 线程可跑其他协程。
    /// sleep 线程完成后 ioComplete + 释放资源 + 退出。
    ///
    /// 阶段 5 迁移到 Io.Mutex 后可改用 Io 线程池的定时器回调，避免每 sleep 一个线程。
    pub fn spawnSleep(self: *IoBridge, chan: *ChannelValue, nanos: u64) void {
        const args = self.backing.create(SleepArgs) catch return;
        args.* = .{ .bridge = self, .chan = chan, .nanos = nanos };
        const thread = std.Thread.spawn(.{}, sleepWorker, .{args}) catch {
            self.backing.destroy(args);
            // spawn 失败：直接 ioComplete 发 unit（sleep 视为立即完成）
            self.ioComplete(chan, Value.fromUnit());
            return;
        };
        thread.detach();
    }
};

/// sleep worker 线程参数
const SleepArgs = struct {
    bridge: *IoBridge,
    chan: *ChannelValue,
    nanos: u64,
};

/// sleep worker 线程：sleep + ioComplete + 释放资源。
/// 独立线程跑，不阻塞协程的 worker 线程。
fn sleepWorker(args: *SleepArgs) void {
    // 用 Io.Timeout.sleep 跨平台 sleep
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = .{ .nanoseconds = args.nanos },
        .clock = .awake,
    } }, args.bridge.io) catch {};

    // sleep 完成：发 channel + 唤醒协程
    args.bridge.ioComplete(args.chan, Value.fromUnit());

    // 释放资源
    const backing = args.bridge.backing;
    backing.destroy(args);
}

// ════════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const obj_header = @import("value").obj_header;
const ThreadContext = @import("value").obj_header.ThreadContext;

test "IoBridge.ioComplete 发 channel + 唤醒" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var bridge = IoBridge.init(io, &registry, testing.allocator);

    // 创建 channel(cap=1)
    var global = @import("mem").GlobalPool.init(testing.allocator, io);
    defer global.deinit();
    var tctx = try ThreadContext.init(&global, testing.allocator, null);
    defer tctx.deinit();
    const chan = try ChannelValue.create(&tctx, 1);
    defer obj_header.release(&chan.header, &tctx);

    // ioComplete 发 unit 值
    bridge.ioComplete(chan, Value.fromUnit());

    // channel 应有数据
    try testing.expect(chan.tryRecv() != null);
}

test "IoBridge.spawnSleep 异步 sleep + 完成唤醒" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = SuspendRegistry.init(io, testing.allocator);
    defer registry.deinit();

    var bridge = IoBridge.init(io, &registry, testing.allocator);

    // 创建 channel(cap=1)
    var global = @import("mem").GlobalPool.init(testing.allocator, io);
    defer global.deinit();
    var tctx = try ThreadContext.init(&global, testing.allocator, null);
    defer tctx.deinit();
    const chan = try ChannelValue.create(&tctx, 1);

    // spawn sleep 1ms
    bridge.spawnSleep(chan, 1_000_000);

    // 轮询等待 channel 有数据（最多 1s）
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (chan.tryRecv() != null) break;
        std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 1_000_000 }, .clock = .awake }, io) catch {};
    }
    try testing.expect(i < 1000); // 应在 1s 内完成

    // 等待 sleep worker 线程完全退出（trySend + wake 后），避免释放 channel 时 UAF
    std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 5_000_000 }, .clock = .awake }, io) catch {};
    obj_header.release(&chan.header, &tctx);
}
