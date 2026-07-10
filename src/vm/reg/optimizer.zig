//! RegModuleCompiler 编译后优化入口。
//! 遍历所有函数的 RegChunk，运行 reg_passes.optimizeChunk。
//! 在 compileModuleWithDeps 末尾调用，编译后执行前优化字节码。

const std = @import("std");
const reg_chunk = @import("chunk.zig");
const reg_passes = @import("passes.zig");

pub const OptimizeResult = struct {
    total_removed: u32 = 0,
    total_moves_eliminated: u32 = 0,
    total_folded: u32 = 0,
};

/// 对程序中所有函数的 chunk 运行优化 pass。
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
