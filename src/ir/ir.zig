//! Glue IR 顶层结构
//!
//! GlueIR 是一段连续内存，包含节点流、通道空间、元数据表、函数表。
//! 这是前端（parse + sema）的最终产物，也是中端（优化器）和后端（执行引擎）的输入。
//! 设计参考：docs/glue-ir-design.md 第 3.1 节
//!
//! Phase 1：节点流 + 通道 + 标量元数据 + 调用元数据 + 函数表 + 字符串池
//! 后续 Phase 添加：向量/门控/路由/竞争/清理元数据表、星轨表

const std = @import("std");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");

pub const Node = node_mod.Node;
pub const NodeOp = node_mod.NodeOp;
pub const ScalarMeta = meta_mod.ScalarMeta;
pub const ScalarKind = meta_mod.ScalarKind;
pub const ConstVal = meta_mod.ConstVal;
pub const CallMeta = meta_mod.CallMeta;
pub const CleanupMeta = meta_mod.CleanupMeta;
pub const HaltKind = meta_mod.HaltKind;
pub const Function = meta_mod.Function;
pub const VectorMeta = meta_mod.VectorMeta;
pub const VecOp = meta_mod.VecOp;
pub const GateMeta = meta_mod.GateMeta;
pub const GateKind = meta_mod.GateKind;
pub const RouteMeta = meta_mod.RouteMeta;
pub const RaceMeta = meta_mod.RaceMeta;
pub const OrbitMeta = meta_mod.OrbitMeta;
pub const LoopMeta = meta_mod.LoopMeta;
pub const LoopKind = meta_mod.LoopKind;
pub const ClosureMeta = meta_mod.ClosureMeta;
pub const ChanType = channel_mod.ChanType;
pub const ChannelMeta = channel_mod.ChannelMeta;
pub const ChannelSpace = channel_mod.ChannelSpace;

/// Glue IR：完整的共享内存图
///
/// 所有内存通过 arena 统一管理（编译期产物，程序级生命周期）。
/// 后续接入 ThreadContext 对象池时，arena 作为 backing allocator。
pub const GlueIR = struct {
    /// 节点流：所有节点连续存储，线性遍历
    nodes: []Node = &.{},

    /// 通道空间：全局通道索引 + 元信息
    channels: ChannelSpace,

    /// 标量元数据表（const_i/int_*/float_*/cmp_*/cast 等节点引用）
    scalar_metas: []ScalarMeta = &.{},

    /// 调用元数据表（call 节点引用）
    call_metas: []CallMeta = &.{},

    /// 向量元数据表（vec_* 节点引用，Phase 2）
    vector_metas: []VectorMeta = &.{},

    /// 门控元数据表（gate_* 节点引用，Phase 3）
    gate_metas: []GateMeta = &.{},

    /// 路由元数据表（route_* 节点引用，Phase 3）
    route_metas: []RouteMeta = &.{},

    /// 竞争元数据表（race_* 节点引用，Phase 3）
    race_metas: []RaceMeta = &.{},

    /// 清理元数据表（cleanup_register 节点引用，Phase 3）
    cleanup_metas: []CleanupMeta = &.{},

    /// 星轨元数据表（orbit_async_create/join 节点引用，Phase 5）
    orbit_metas: []OrbitMeta = &.{},

    /// 循环元数据表（scalar_loop 节点引用，含 break/continue 的循环）
    loop_metas: []LoopMeta = &.{},

    /// 闭包元数据表（closure_make 节点引用，lambda 编译）
    closure_metas: []ClosureMeta = &.{},

    /// 函数表：每个函数是一个子图（node_start..node_start+node_count）
    functions: []Function = &.{},

    /// 字符串常量池（const_str 节点的 meta_index 索引此池）
    string_pool: []const []const u8 = &.{},

    /// 入口函数索引（main 函数在 functions 表中的位置）
    entry_index: u16 = 0,

    /// 初始化函数索引（顶层 val/var 声明的初始化代码，run() 时先执行）
    init_index: ?u16 = null,

    /// 持有所有权的 arena（deinit 时释放所有编译期产物）
    /// 若为 null，则 nodes/metas/functions 为外部管理的内存，deinit 不释放
    arena: ?*std.heap.ArenaAllocator = null,

    /// 底层分配器（channels 等动态结构使用）
    backing: std.mem.Allocator,

    /// 释放 IR 占用的所有内存
    pub fn deinit(self: *GlueIR) void {
        if (self.arena) |a| {
            // arena 模式：channels.metas 也由 arena 分配
            // arena.deinit() 统一释放所有内存（nodes/metas/functions/channels.metas）
            a.deinit();
            self.backing.destroy(a);
            self.arena = null;
        } else {
            // 非 arena 模式：channels 自行管理内存
            self.channels.deinit();
        }
    }

    /// 获取函数的节点切片
    pub fn funcNodes(self: *const GlueIR, func_idx: u16) []Node {
        const f = self.functions[func_idx];
        return self.nodes[f.node_start .. f.node_start + f.node_count];
    }

    /// 获取入口函数
    pub fn entryFunc(self: *const GlueIR) Function {
        return self.functions[self.entry_index];
    }
};

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "GlueIR 基本结构" {
    const cs = ChannelSpace.init(testing.allocator);
    var ir = GlueIR{
        .channels = cs,
        .backing = testing.allocator,
    };
    defer ir.deinit();

    try testing.expectEqual(@as(usize, 0), ir.nodes.len);
    try testing.expectEqual(@as(usize, 0), ir.functions.len);
    try testing.expectEqual(@as(u16, 0), ir.entry_index);
}

test "GlueIR.funcNodes 获取函数节点切片" {
    const nodes = [_]Node{
        Node.makeSink(.const_i, 0, 0),
        Node.makeSink(.halt_return, 0, 0),
    };
    const funcs = [_]Function{
        .{
            .name = "main",
            .node_start = 0,
            .node_count = 2,
            .param_channels = &.{},
            .return_channel = 0,
            .is_entry = true,
        },
    };
    const cs = ChannelSpace.init(testing.allocator);
    var ir = GlueIR{
        .nodes = @constCast(&nodes),
        .functions = @constCast(&funcs),
        .channels = cs,
        .backing = testing.allocator,
    };
    defer ir.channels.deinit();

    const fn_nodes = ir.funcNodes(0);
    try testing.expectEqual(@as(usize, 2), fn_nodes.len);
    try testing.expectEqual(NodeOp.const_i, fn_nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, fn_nodes[1].op);
}
