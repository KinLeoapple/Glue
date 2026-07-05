//! JIT 分析数据库：聚合所有静态分析 pass 的结果。
//!
//! 编译器通过 AnalysisDB 查询优化决策。
//!
//! 模块根文件：re-export 子模块，供外部通过 @import("analysis_db") 访问。

const std = @import("std");
const ast = @import("ast");

pub const purity = @import("purity.zig");
pub const call_graph = @import("call_graph.zig");
pub const const_prop = @import("const_prop.zig");
pub const branch_reach = @import("branch_reach.zig");
pub const loop_invariant = @import("loop_invariant.zig");
pub const fused_analysis = @import("fused_analysis.zig");

pub const PurityInfo = purity.PurityInfo;
pub const PurityTable = purity.PurityTable;
pub const PurityPass = purity.PurityPass;
pub const CallGraph = call_graph.CallGraph;
pub const CallGraphPass = call_graph.CallGraphPass;
pub const ConstValue = const_prop.ConstValue;
pub const ConstTable = const_prop.ConstTable;
pub const ConstPropPass = const_prop.ConstPropPass;
pub const BranchInfo = branch_reach.BranchInfo;
pub const BranchTable = branch_reach.BranchTable;
pub const BranchReachPass = branch_reach.BranchReachPass;
pub const LoopInfo = loop_invariant.LoopInfo;
pub const LoopTable = loop_invariant.LoopTable;
pub const LoopInvariantPass = loop_invariant.LoopInvariantPass;
pub const FusedAnalysis = fused_analysis.FusedAnalysis;

/// 分析数据库
pub const AnalysisDB = struct {
    purity: PurityTable,
    call_graph: CallGraph,
    const_prop: ConstTable,
    branch_reach: BranchTable,
    loop_invariant: LoopTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnalysisDB {
        return .{
            .purity = PurityTable.init(allocator),
            .call_graph = CallGraph.init(allocator),
            .const_prop = ConstTable.init(allocator),
            .branch_reach = BranchTable.init(allocator),
            .loop_invariant = LoopTable.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalysisDB) void {
        self.purity.deinit();
        self.call_graph.deinit();
        self.const_prop.deinit();
        self.branch_reach.deinit();
        self.loop_invariant.deinit();
    }
};

test "AnalysisDB init/deinit" {
    var db = AnalysisDB.init(std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.purity.isEmpty());
    try std.testing.expect(db.call_graph.isEmpty());
}
