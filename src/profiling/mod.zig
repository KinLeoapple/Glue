//! Profiler 模块入口
//!
//! 提供 GlobalProfiler 单例，聚合：
//! - per-thread ThreadProfiler 注册表（mutex 保护）
//! - 后台采样线程 Sampler
//! - 时间序列 Timeline
//! - 管线阶段计时 Phases

const std = @import("std");
const thread_profiler_mod = @import("thread_profiler.zig");
const timeline_mod = @import("timeline.zig");
const sampler_mod = @import("sampler.zig");
const phases_mod = @import("phases.zig");
const aggregator_mod = @import("aggregator.zig");
const reporter = @import("reporter.zig");

// Re-export（pub const 直接对外暴露，内部亦通过同一标识符引用）
pub const stats = @import("stats.zig");
pub const ThreadProfiler = thread_profiler_mod.ThreadProfiler;
pub const Timeline = timeline_mod.Timeline;
pub const Sampler = sampler_mod.Sampler;
pub const Phases = phases_mod.Phases;
pub const Phase = phases_mod.Phase;
pub const Report = aggregator_mod.Report;
pub const Aggregator = aggregator_mod.Aggregator;
pub const dumpText = reporter.dumpText;
pub const dumpJson = reporter.dumpJson;

const SpinMutex = stats.SpinMutex;
const ThreadProfilerType = thread_profiler_mod.ThreadProfiler;

/// 全局 Profiler 单例
pub const GlobalProfiler = struct {
    enabled: bool,
    interval_ns: u64,
    json_output_path: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    thread_profilers: std.ArrayList(*ThreadProfilerType),
    registry_mutex: SpinMutex = .{},

    sampler: ?sampler_mod.Sampler = null,
    timeline: timeline_mod.Timeline,
    phases: phases_mod.Phases,

    /// 函数名表（按 func_idx 索引）：由调用方在 build 完 IR 后通过
    /// `setFuncNames` 注入。dump 时拷贝到 Report 用于显示。
    /// 内存归 GlobalProfiler 所有，deinit 时释放。
    func_names: ?[][]const u8 = null,

    /// 初始化
    pub fn init(
        allocator: std.mem.Allocator,
        enabled: bool,
        interval_us: u64,
        json_path: ?[]const u8,
    ) !GlobalProfiler {
        return .{
            .enabled = enabled,
            .interval_ns = if (interval_us == 0) 1_000_000 else interval_us * 1000,
            .json_output_path = json_path,
            .allocator = allocator,
            .thread_profilers = .empty,
            .timeline = try timeline_mod.Timeline.init(allocator),
            .phases = .{ .enabled = enabled },
        };
    }

    /// 清理
    pub fn deinit(self: *GlobalProfiler) void {
        self.stop();
        // 若 dump 未被调用（如异常退出），仍需清理 ThreadProfiler
        for (self.thread_profilers.items) |prof| {
            prof.deinit();
            self.allocator.destroy(prof);
        }
        self.timeline.deinit();
        self.thread_profilers.deinit(self.allocator);
        if (self.func_names) |names| {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
            self.func_names = null;
        }
    }

    /// 注入函数名表（深拷贝，所有权归 GlobalProfiler）
    /// `names[i]` 对应 IR.functions[i].name；调用方传入的内存可随即释放。
    pub fn setFuncNames(self: *GlobalProfiler, names: []const []const u8) !void {
        if (self.func_names) |old| {
            for (old) |n| self.allocator.free(n);
            self.allocator.free(old);
            self.func_names = null;
        }
        const dup = try self.allocator.alloc([]const u8, names.len);
        errdefer self.allocator.free(dup);
        var copied: usize = 0;
        errdefer {
            for (dup[0..copied]) |n| self.allocator.free(n);
        }
        for (names, 0..) |n, i| {
            dup[i] = try self.allocator.dupe(u8, n);
            copied += 1;
        }
        self.func_names = dup;
    }

    /// 注册 ThreadProfiler（ThreadContext 初始化时调用）
    pub fn registerThread(self: *GlobalProfiler, prof: *ThreadProfilerType) void {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        self.thread_profilers.append(self.allocator, prof) catch {};
    }

    /// 启动采样线程
    pub fn start(self: *GlobalProfiler) !void {
        if (!self.enabled) return;
        if (self.sampler != null) return;

        self.sampler = .{
            .global_prof = .{
                .thread_profilers = &self.thread_profilers,
                .registry_mutex = &self.registry_mutex,
                .timeline = &self.timeline,
            },
            .interval_ns = self.interval_ns,
        };
        try self.sampler.?.start();
    }

    /// 停止采样线程
    pub fn stop(self: *GlobalProfiler) void {
        if (self.sampler) |*s| {
            s.stop();
            self.sampler = null;
        }
    }

    /// 输出报告
    pub fn dump(self: *GlobalProfiler, io: std.Io) void {
        if (!self.enabled) return;

        // 先停止采样线程，防止 ThreadProfiler 数据变化和全零样本覆盖
        self.stop();

        var agg = aggregator_mod.Aggregator.init(self.allocator);
        var report = agg.buildReport(&self.timeline, self.phases, self.thread_profilers.items) catch return;
        defer report.deinit();
        // 注入函数名表（若调用方在 build IR 后已 setFuncNames）
        if (self.func_names) |names| report.func_names = names;

        // 文本格式到 stderr
        const stderr = std.Io.File.stderr();
        var buf: [8192]u8 = undefined;
        var w = stderr.writerStreaming(io, &buf);
        dumpText(&report, &w.interface) catch {};
        w.flush() catch {};

        // JSON 格式到文件
        if (self.json_output_path) |path| {
            const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
            defer file.close(io);
            var fb: [8192]u8 = undefined;
            var fw = file.writerStreaming(io, &fb);
            dumpJson(&report, &fw.interface) catch {};
            fw.flush() catch {};
        }

        // dump 完成后清理 ThreadProfiler（生命周期到此结束）
        for (self.thread_profilers.items) |prof| {
            prof.deinit();
            self.allocator.destroy(prof);
        }
        self.thread_profilers.clearRetainingCapacity();
    }
};

test {
    std.testing.refAllDecls(@This());
}
