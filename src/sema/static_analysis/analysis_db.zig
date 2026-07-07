//! JIT 分析数据库：聚合所有静态分析 pass 的结果。
//!
//! 编译器通过 AnalysisDB 查询优化决策。
//!
//! 模块根文件：re-export 子模块，供外部通过 @import("analysis_db") 访问。

const std = @import("std");

pub const purity = @import("purity.zig");
pub const call_graph = @import("call_graph.zig");
pub const const_prop = @import("const_prop.zig");
pub const branch_reach = @import("branch_reach.zig");
pub const loop_invariant = @import("loop_invariant.zig");
pub const fused_analysis = @import("fused_analysis.zig");
pub const dead_code = @import("dead_code.zig");
pub const cse = @import("cse.zig");

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

/// 分析数据库
pub const AnalysisDB = struct {
    purity: PurityTable,
    call_graph: CallGraph,
    const_prop: ConstTable,
    branch_reach: BranchTable,
    loop_invariant: LoopTable,
    /// 【LICM】循环不变量提升表：表达式指针 → 所属循环 stmt 指针
    hoist_table: HoistTable,
    /// 【DCE】死代码表：被标记为 dead 的 val_decl/var_decl stmt 指针集合
    dead_code: DeadTable,
    /// 【CSE】公共子表达式表：redundant → canonical 映射 + canonical 集合
    cse: CseTable,
    allocator: std.mem.Allocator,

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
