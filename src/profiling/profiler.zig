//! Glue 全管线 profiler —— 独立模块，覆盖 lex/parse/type_check/compile/vm 全阶段。
//!
//! 触发：命令行选项 `--profile`（glue run --profile / glue debug --profile）。
//! 输出到 stderr，不干扰程序正常输出。
//!
//! 三类统计：
//! 1. 阶段计时：各阶段墙钟耗时（基于 std.Io.Clock.awake 单调时钟）。
//! 2. 内存统计：SlabPool 峰值/活跃/保留字节 + 碎片率（Glue 无追踪式 GC，
//!    内存管理 = 引用计数 retain/release + SlabPool 箱体分配 + Arena 一次性分配；
//!    SlabPool 是运行时 Value 箱体的主要分配源，其统计反映运行时内存表现）。
//! 3. VM opcode 频率：按 u8 索引计数，供 superinstructions / inline caching 候选识别。
//!
//! 设计：profiler 完全独立（不依赖 vm/ast 等模块），opcode 名字通过回调注入，
//! 避免 profiler ↔ vm 循环依赖。

const std = @import("std");

/// 管线阶段。按 executeSource → tryRunOnVM 的执行顺序。
pub const Phase = enum {
    lex,
    parse,
    type_check,
    compile,
    vm,
};

const PHASE_NAMES = [@typeInfo(Phase).@"enum".fields.len][]const u8{
    "lex",
    "parse",
    "type_check",
    "compile",
    "vm",
};

pub const Profiler = struct {
    enabled: bool = false,
    /// io 句柄（单调时钟需要）。null 时禁用计时。
    io: ?std.Io = null,

    // ── 阶段计时（纳秒）──
    phase_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = .{0} ** @typeInfo(Phase).@"enum".fields.len,
    phase_start: ?std.Io.Timestamp = null,
    current_phase: ?Phase = null,

    // ── VM opcode 计数（u8 索引，覆盖所有 OpCode 变体）──
    opcode_counts: [256]u64 = .{0} ** 256,
    /// opcode 索引 → 名字回调（由 VM 注入，避免 profiler 依赖 vm 模块）。null 时 dump 只输出索引。
    opcode_name_fn: ?*const fn (u8) []const u8 = null,

    // ── 内存统计（SlabPool，由 main.zig 在 VM 执行后注入）──
    /// reserved_bytes 峰值（向 backing 申请的最多字节数）。
    slab_peak_bytes: usize = 0,
    /// live_bytes 峰值（同时存活对象的最大字节数）。
    slab_live_peak_bytes: usize = 0,
    /// 结束时刻 live_bytes（理想为 0，表示无泄漏）。
    slab_live_bytes: usize = 0,
    /// 结束时刻 reserved_bytes（含 empty slab 缓存，可能 > 0）。
    slab_reserved_bytes: usize = 0,

    pub fn init(enabled: bool, io: ?std.Io) Profiler {
        return .{ .enabled = enabled, .io = io };
    }

    // ── 阶段计时 API ──

    /// 标记某阶段开始。管线线性不嵌套，current_phase 不会被覆盖。
    pub fn phaseBegin(self: *Profiler, phase: Phase) void {
        if (!self.enabled) return;
        if (self.io) |io| {
            self.phase_start = std.Io.Timestamp.now(io, .awake);
            self.current_phase = phase;
        }
    }

    /// 标记当前阶段结束，累加墙钟耗时到对应 phase_ns 槽。
    pub fn phaseEnd(self: *Profiler) void {
        if (!self.enabled) return;
        if (self.phase_start) |start| {
            if (self.io) |io| {
                const end = std.Io.Timestamp.now(io, .awake);
                const ns: i96 = start.durationTo(end).nanoseconds;
                if (ns > 0) {
                    if (self.current_phase) |p| {
                        self.phase_ns[@intFromEnum(p)] += @intCast(ns);
                    }
                }
            }
        }
        self.phase_start = null;
        self.current_phase = null;
    }

    // ── VM opcode 计数 API（热路径，调用方需判 enabled）──

    pub fn recordOpcode(self: *Profiler, op_idx: u8) void {
        self.opcode_counts[op_idx] += 1;
    }

    pub fn setOpcodeNameFn(self: *Profiler, f: *const fn (u8) []const u8) void {
        self.opcode_name_fn = f;
    }

    // ── 内存统计 API ──

    /// 注入 SlabPool 完整统计：结束时刻快照 + 峰值。调用方在 VM 执行后、pool.deinit 前调用。
    /// SlabPool 自己追踪峰值（覆盖所有自增点，无采样间隙），故这里直接接收峰值而非自行采样。
    pub fn recordSlabStats(
        self: *Profiler,
        live: usize,
        reserved: usize,
        live_peak: usize,
        reserved_peak: usize,
    ) void {
        self.slab_live_bytes = live;
        self.slab_reserved_bytes = reserved;
        self.slab_live_peak_bytes = live_peak;
        self.slab_peak_bytes = reserved_peak;
    }

    // ── 报告输出 ──

    pub fn dump(self: *Profiler, io: std.Io) void {
        if (!self.enabled) return;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        const wr = &w.interface;

        wr.print("\n[PROFILE]\n", .{}) catch {};

        // 阶段计时
        var total_ns: u64 = 0;
        for (self.phase_ns) |n| total_ns += n;
        wr.print("phases (wall-clock):\n", .{}) catch {};
        for (self.phase_ns, 0..) |n, i| {
            if (n == 0) continue;
            const ms = @as(f64, @floatFromInt(n)) / 1e6;
            const pct = if (total_ns > 0)
                (@as(f64, @floatFromInt(n)) * 100.0) / @as(f64, @floatFromInt(total_ns))
            else
                0;
            wr.print("  {s: <14}: {d:>8.3} ms ({d:.1}%)\n", .{ PHASE_NAMES[i], ms, pct }) catch {};
        }
        const total_ms = @as(f64, @floatFromInt(total_ns)) / 1e6;
        wr.print("  {s: <14}: {d:>8.3} ms\n", .{ "total", total_ms }) catch {};

        // 内存统计
        wr.print("\nmemory:\n", .{}) catch {};
        wr.print("  peak live     : {s}\n", .{formatBytes(self.slab_live_peak_bytes)}) catch {};
        wr.print("  peak reserved : {s}\n", .{formatBytes(self.slab_peak_bytes)}) catch {};
        // 碎片率基于峰值时刻：1 - live_peak/peak_reserved。
        // 用结束时刻会误导（live 已回落到 0 但 reserved 还缓存着 empty slab → 算出 100%）。
        if (self.slab_peak_bytes > 0) {
            const frag = 1.0 - (@as(f64, @floatFromInt(self.slab_live_peak_bytes)) /
                @as(f64, @floatFromInt(self.slab_peak_bytes)));
            wr.print("  fragmentation : {d:.1}%  (at peak)\n", .{frag * 100.0}) catch {};
        }
        wr.print("  final live    : {s}\n", .{formatBytes(self.slab_live_bytes)}) catch {};
        wr.print("  final reserved: {s}\n", .{formatBytes(self.slab_reserved_bytes)}) catch {};

        // VM opcode 频率
        var total_opcodes: u64 = 0;
        for (self.opcode_counts) |c| total_opcodes += c;
        if (total_opcodes > 0) {
            wr.print("\nvm opcodes (sorted desc):\n", .{}) catch {};
            // 收集非零项并按计数降序排序
            const Entry = struct { idx: u8, count: u64 };
            var entries: [256]Entry = undefined;
            var n_entries: usize = 0;
            for (self.opcode_counts, 0..) |c, i| {
                if (c > 0) {
                    entries[n_entries] = .{ .idx = @intCast(i), .count = c };
                    n_entries += 1;
                }
            }
            std.mem.sort(Entry, entries[0..n_entries], {}, struct {
                fn lt(_: void, a: Entry, b: Entry) bool {
                    return a.count > b.count;
                }
            }.lt);
            for (entries[0..n_entries]) |e| {
                const pct = (@as(f64, @floatFromInt(e.count)) * 100.0) /
                    @as(f64, @floatFromInt(total_opcodes));
                const name: []const u8 = if (self.opcode_name_fn) |f| f(e.idx) else "<idx>";
                wr.print("  {s}: {d} ({d:.1}%)\n", .{ name, e.count, pct }) catch {};
            }
            wr.print("  total opcodes: {d}\n", .{total_opcodes}) catch {};
            if (total_ns > 0) {
                const mips = @as(f64, @floatFromInt(total_opcodes)) /
                    (@as(f64, @floatFromInt(self.phase_ns[@intFromEnum(Phase.vm)])) / 1e9);
                wr.print("  throughput   : {d:.2} M instr/s (vm phase)\n", .{mips / 1e6}) catch {};
            }
        }

        w.flush() catch {};
    }
};

/// 字节数格式化（自动 KB/MB）。返回静态缓冲区，调用方立即使用。
fn formatBytes(bytes: usize) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    if (bytes < 1024) {
        return std.fmt.bufPrint(&Static.buf, "{d} B", .{bytes}) catch "<err>";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(&Static.buf, "{d:.1} KB", .{kb}) catch "<err>";
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(&Static.buf, "{d:.2} MB", .{mb}) catch "<err>";
    }
}
