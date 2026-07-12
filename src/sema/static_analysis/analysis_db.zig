//! 静态分析数据库模块。
//!
//! 作为静态分析子系统的统一聚合点，集中导入并重新导出各分析子模块
//! （纯度、调用图、常量传播、分支可达、循环不变量、死代码、公共子表达式等），
//! 并通过 AnalysisDB 把各分析表组合为一个整体，便于一次性初始化与释放。

const std = @import("std");

pub const purity = @import("purity.zig");
pub const call_graph = @import("call_graph.zig");
pub const const_prop = @import("const_prop.zig");
pub const branch_reach = @import("branch_reach.zig");
pub const loop_invariant = @import("loop_invariant.zig");
pub const fused_analysis = @import("fused_analysis.zig");
pub const dead_code = @import("dead_code.zig");
pub const cse = @import("cse.zig");

// 重新导出各子模块的核心类型，便于上层直接通过 analysis_db 引用
pub const PurityInfo = purity.PurityInfo;
pub const PurityTable = purity.PurityTable;
pub const CallGraph = call_graph.CallGraph;
pub const ConstValue = const_prop.ConstValue;
pub const ConstTable = const_prop.ConstTable;
pub const BranchInfo = branch_reach.BranchInfo;
pub const BranchTable = branch_reach.BranchTable;
pub const LoopInfo = loop_invariant.LoopInfo;
pub const LoopTable = loop_invariant.LoopTable;
pub const HoistTable = loop_invariant.HoistTable;
pub const FusedAnalysis = fused_analysis.FusedAnalysis;
pub const DeadTable = dead_code.DeadTable;
pub const CseTable = cse.CseTable;

/// 静态分析数据库：把所有分析表聚合在一起，统一管理生命周期。
pub const AnalysisDB = struct {
    purity: PurityTable,
    call_graph: CallGraph,
    const_prop: ConstTable,
    branch_reach: BranchTable,
    loop_invariant: LoopTable,
    hoist_table: HoistTable,
    dead_code: DeadTable,
    cse: CseTable,
    allocator: std.mem.Allocator,

    /// 用给定分配器初始化所有分析表。
    pub fn init(allocator: std.mem.Allocator) AnalysisDB {
        return .{
            .purity = PurityTable.init(allocator),
            .call_graph = CallGraph.init(allocator),
            .const_prop = ConstTable.init(allocator),
            .branch_reach = BranchTable.init(allocator),
            .loop_invariant = LoopTable.init(allocator),
            .hoist_table = HoistTable.init(allocator),
            .dead_code = DeadTable.init(allocator),
            .cse = CseTable.init(allocator),
            .allocator = allocator,
        };
    }

    /// 释放所有分析表持有的资源。
    pub fn deinit(self: *AnalysisDB) void {
        self.purity.deinit();
        self.call_graph.deinit();
        self.const_prop.deinit();
        self.branch_reach.deinit();
        self.loop_invariant.deinit();
        self.hoist_table.deinit();
        self.dead_code.deinit();
        self.cse.deinit();
    }
};

test "AnalysisDB init/deinit" {
    var db = AnalysisDB.init(std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.purity.isEmpty());
    try std.testing.expect(db.call_graph.isEmpty());
}
