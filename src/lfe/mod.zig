//! LFE (Laminar Flow Execution) 模块入口
//!
//! 层流执行引擎：将 Glue 程序编译为层流图并执行。
//! 替代传统 VM/JIT 的全新执行范式。

const std = @import("std");

pub const lamina = @import("lamina.zig");
pub const compiler = @import("compiler.zig");
pub const engine = @import("engine.zig");
pub const optimizer = @import("optimizer.zig");
pub const scheduler = @import("scheduler.zig");
pub const builtin = @import("builtin.zig");

// 重导出常用类型
pub const LaminarGraph = lamina.LaminarGraph;
pub const LaminarCompiler = compiler.LaminarCompiler;
pub const Engine = engine.Engine;
pub const Lamina = lamina.Lamina;
pub const LaminaOp = lamina.LaminaOp;
pub const ScalarChanType = lamina.ScalarChanType;
pub const PhysicalChannel = lamina.PhysicalChannel;
pub const HaltReason = engine.HaltReason;
pub const EngineError = engine.EngineError;
pub const CompileError = compiler.CompileError;
pub const Optimizer = optimizer;
pub const Scheduler = scheduler.Scheduler;
pub const LfeTask = scheduler.LfeTask;
pub const TaskState = scheduler.TaskState;
pub const simdLaneCount = lamina.simdLaneCount;

/// 执行 Glue 模块：编译 → 优化 → 运行
/// 返回进程退出码
pub fn execute(allocator: std.mem.Allocator, module: anytype) !i64 {
    var graph = try LaminarCompiler.compile(allocator, module);
    defer graph.deinit(allocator);

    // 优化层流图（常量折叠 + 死通道消除 + 层融合 + 槽位复用）
    var optimized = try optimizer.optimize(allocator, &graph);
    defer if (optimized.arena == null) {
        allocator.free(optimized.laminas);
        allocator.free(optimized.channel_metas);
        if (optimized.input_channels.len > 0) allocator.free(optimized.input_channels);
    };

    var eng = try Engine.init(allocator, &optimized, 1);
    defer eng.deinit();

    try eng.run();
    return eng.getReturnValue();
}

// 引用所有子模块以触发懒分析，使 `zig test` 能发现各文件中的测试块
test {
    _ = lamina;
    _ = compiler;
    _ = engine;
    _ = optimizer;
    _ = scheduler;
    _ = builtin;
}
