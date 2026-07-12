//! 程序级优化入口。
//!
//! 遍历 RegProgram 中的所有函数，对每个函数的指令块
//! 依次执行 passes 中定义的优化流水线，汇总优化统计。

const std = @import("std");
const reg_chunk = @import("chunk.zig");
const reg_passes = @import("passes.zig");

/// 优化结果统计，记录各类优化移除的指令数量。
pub const OptimizeResult = struct {
    total_removed: u32 = 0,
    total_moves_eliminated: u32 = 0,
    total_folded: u32 = 0,
};

/// 对程序中所有函数执行优化，返回累计的优化统计。
pub fn optimizeProgram(program: *reg_chunk.RegProgram, allocator: std.mem.Allocator) !OptimizeResult {
    var result = OptimizeResult{};
    for (program.functions.items) |*func| {
        const pr = try reg_passes.optimizeChunk(&func.chunk, allocator, program);
        result.total_removed += pr.instructions_removed;
        result.total_moves_eliminated += pr.moves_eliminated;
        result.total_folded += pr.constants_folded;
    }
    return result;
}
