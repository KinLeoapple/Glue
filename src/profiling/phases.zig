//! 管线阶段计时模块
//!
//! 扩展原 6 阶段为 7 顶层 + 5 子阶段，支持嵌套阶段 self_ns 自动计算。

const std = @import("std");
const stats = @import("stats.zig");

const nanoTimestamp = stats.nanoTimestamp;
const sleepNs = stats.sleepNs;

/// 编译/运行阶段标识
pub const Phase = enum {
    // 顶层阶段
    lex,
    parse,
    module_load,
    type_check,
    ir_build,
    ir_optimize,
    engine_run,

    // 子阶段（ir_build 内）
    fused_analysis,
    ir_build_core,

    // 子阶段（engine_run 内）
    engine_setup,
    engine_exec,
    engine_teardown,

    /// 返回父阶段（若有）
    pub fn parent(self: Phase) ?Phase {
        return switch (self) {
            .fused_analysis, .ir_build_core => .ir_build,
            .engine_setup, .engine_exec, .engine_teardown => .engine_run,
            else => null,
        };
    }

    /// 是否为顶层阶段
    pub fn isTopLevel(self: Phase) bool {
        return self.parent() == null;
    }
};

/// 阶段数量
pub const phase_count = @typeInfo(Phase).@"enum".fields.len;

/// 阶段显示名称
pub const PHASE_NAMES = blk: {
    var names: [phase_count][]const u8 = undefined;
    for (@typeInfo(Phase).@"enum".fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

/// 单阶段计时数据
pub const PhaseTiming = struct {
    begin_ns: i64 = 0,
    end_ns: i64 = 0,
    elapsed_ns: u64 = 0,
    children_elapsed_ns: u64 = 0,
    self_ns: u64 = 0,

    /// 计算占总时间的百分比
    pub fn pct(self: PhaseTiming, total_ns: u64) f64 {
        if (total_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(total_ns)) * 100;
    }

    /// 是否有子阶段（用于输出缩进）
    pub fn hasChildren(self: PhaseTiming) bool {
        return self.children_elapsed_ns > 0;
    }
};

/// 管线阶段计时器
pub const Phases = struct {
    enabled: bool = false,
    timings: [phase_count]PhaseTiming = [_]PhaseTiming{.{}} ** phase_count,
    total_ns: u64 = 0,

    /// 标记阶段开始
    pub fn phaseBegin(self: *Phases, phase: Phase) void {
        if (!self.enabled) return;
        self.timings[@intFromEnum(phase)].begin_ns = nanoTimestamp();
    }

    /// 标记阶段结束，自动计算 self_ns 和 total_ns
    pub fn phaseEnd(self: *Phases, phase: Phase) void {
        if (!self.enabled) return;
        const idx = @intFromEnum(phase);
        const now = nanoTimestamp();
        const t = &self.timings[idx];
        t.end_ns = now;
        t.elapsed_ns = @intCast(now - t.begin_ns);

        // 累加到父阶段的 children_elapsed_ns
        if (phase.parent()) |parent_phase| {
            const p = &self.timings[@intFromEnum(parent_phase)];
            p.children_elapsed_ns += t.elapsed_ns;
            // 父阶段的 self_ns 在父阶段 phaseEnd 时计算
        } else {
            // 顶层阶段累加 total
            self.total_ns += t.elapsed_ns;
        }

        // 计算 self_ns（elapsed - children）
        t.self_ns = t.elapsed_ns -| t.children_elapsed_ns;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "阶段计时基本功能" {
    var ph = Phases{ .enabled = true };
    ph.phaseBegin(.lex);
    sleepNs(1_000_000); // 1ms
    ph.phaseEnd(.lex);
    try std.testing.expect(ph.timings[@intFromEnum(Phase.lex)].elapsed_ns >= 1_000_000);
    try std.testing.expect(ph.total_ns >= 1_000_000);
}

test "子阶段 self_ns 计算" {
    var ph = Phases{ .enabled = true };
    ph.phaseBegin(.ir_build);
    sleepNs(500_000);
    ph.phaseBegin(.fused_analysis);
    sleepNs(1_000_000);
    ph.phaseEnd(.fused_analysis);
    ph.phaseBegin(.ir_build_core);
    sleepNs(800_000);
    ph.phaseEnd(.ir_build_core);
    ph.phaseEnd(.ir_build);

    const ir_build = ph.timings[@intFromEnum(Phase.ir_build)];
    const fused = ph.timings[@intFromEnum(Phase.fused_analysis)];
    const core = ph.timings[@intFromEnum(Phase.ir_build_core)];

    // ir_build.elapsed 应 >= fused.elapsed + core.elapsed + 一些 self 时间
    try std.testing.expect(ir_build.elapsed_ns >= fused.elapsed_ns + core.elapsed_ns);
    // children_elapsed_ns 应等于 fused + core
    try std.testing.expectEqual(fused.elapsed_ns + core.elapsed_ns, ir_build.children_elapsed_ns);
    // self_ns = elapsed - children
    try std.testing.expectEqual(ir_build.elapsed_ns - ir_build.children_elapsed_ns, ir_build.self_ns);
}
