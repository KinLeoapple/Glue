//! Glue IR 模块入口
//!
//! 定义 Glue 语言的共享内存图执行模型的数据结构。
//! 这是前端（parse + sema）的产物，也是中端（优化器）和后端（执行引擎）的输入。
//!
//! 架构：parse（纯语法）→ sema（图构建驱动）→ Glue IR → optimizer → engine
//! 设计文档：docs/glue-ir-design.md
//!
//! Phase 1：核心数据结构 + 图构建器（标量 op + 基础控制流）
//! Phase 2：向量 op（循环/递归向量化）
//! Phase 3：门控/路由/竞争/清理
//! Phase 4：优化器（常量折叠/死节点消除/通道活跃性/向量融合）
//! Phase 5：星轨扩展（async/spawn 并行执行层）

const std = @import("std");

pub const node_mod = @import("node.zig");
pub const meta_mod = @import("meta.zig");
pub const channel_mod = @import("channel.zig");
pub const ir_mod = @import("ir.zig");
pub const builder_mod = @import("builder.zig");
pub const sema_output_mod = @import("sema_output.zig");
pub const printer_mod = @import("printer.zig");
pub const optimizer_mod = @import("optimizer.zig");

// 核心类型重导出
pub const Node = node_mod.Node;
pub const NodeOp = node_mod.NodeOp;
pub const ScalarMeta = meta_mod.ScalarMeta;
pub const ScalarKind = meta_mod.ScalarKind;
pub const ConstVal = meta_mod.ConstVal;
pub const CallMeta = meta_mod.CallMeta;
pub const VectorMeta = meta_mod.VectorMeta;
pub const VecOp = meta_mod.VecOp;
pub const GateMeta = meta_mod.GateMeta;
pub const GateKind = meta_mod.GateKind;
pub const RouteMeta = meta_mod.RouteMeta;
pub const RaceMeta = meta_mod.RaceMeta;
pub const CleanupMeta = meta_mod.CleanupMeta;
pub const OrbitMeta = meta_mod.OrbitMeta;
pub const HaltKind = meta_mod.HaltKind;
pub const Function = meta_mod.Function;
pub const SyscallId = meta_mod.SyscallId;
pub const SyscallMeta = meta_mod.SyscallMeta;
pub const ChanType = channel_mod.ChanType;
pub const ChannelMeta = channel_mod.ChannelMeta;
pub const ChannelSpace = channel_mod.ChannelSpace;
pub const nullableElemWidth = channel_mod.nullableElemWidth;
pub const GlueIR = ir_mod.GlueIR;
pub const IRBuilder = builder_mod.IRBuilder;
pub const BuildError = builder_mod.BuildError;
pub const SemaResult = sema_output_mod.SemaResult;
pub const ExprInfo = sema_output_mod.ExprInfo;
pub const printIR = printer_mod.printIR;
pub const optimize = optimizer_mod.optimize;
pub const OptStats = optimizer_mod.OptStats;

test {
    // 引用所有子模块以触发懒分析
    _ = node_mod;
    _ = meta_mod;
    _ = channel_mod;
    _ = ir_mod;
    _ = builder_mod;
    _ = sema_output_mod;
    _ = printer_mod;
    _ = optimizer_mod;
}
