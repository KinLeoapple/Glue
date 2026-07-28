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
pub const ast_traits_mod = @import("ast_traits.zig");
pub const pattern_compiler_mod = @import("pattern_compiler.zig");
pub const decl_collector_mod = @import("decl_collector.zig");
pub const stmt_compiler_mod = @import("stmt_compiler.zig");
pub const func_compiler_mod = @import("func_compiler.zig");
pub const expr_compiler_mod = @import("expr_compiler.zig");
pub const sema_output_mod = @import("sema").sema_output;
pub const printer_mod = @import("printer.zig");
pub const optimizer_mod = @import("optimizer.zig");
pub const state_machine_transform = @import("state_machine_transform.zig");
pub const type_descriptor_mod = @import("type_descriptor.zig");
pub const builtin_registry = @import("builtin_registry.zig");
pub const op_table_mod = @import("op_table.zig");
pub const builtin_type_names = @import("builtin_type_names.zig");

// v3 阶段 5 便捷别名：OpTable 单表覆盖 NodeOp 全部静态属性维度
pub const OpTable = op_table_mod;
pub const op_table = op_table_mod;

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
pub const SyscallMeta = meta_mod.SyscallMeta;
pub const SuspendKind = meta_mod.SuspendKind;
pub const SegmentDesc = meta_mod.SegmentDesc;
pub const SlotDesc = meta_mod.SlotDesc;
pub const SlotRegion = meta_mod.SlotRegion;
pub const FrameLayout = meta_mod.FrameLayout;
pub const DeferEntry = meta_mod.DeferEntry;
pub const DeferTable = meta_mod.DeferTable;
pub const CatchEntry = meta_mod.CatchEntry;
pub const CatchTable = meta_mod.CatchTable;
pub const LoopEntry = meta_mod.LoopEntry;
pub const LoopTable = meta_mod.LoopTable;
pub const CoroutineMeta = meta_mod.CoroutineMeta;
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

// v3 TypeDescriptor 类型重导出（定义已移至 ir/type_descriptor.zig）
pub const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
pub const ScalarOps = type_descriptor_mod.ScalarOps;

// sema_output 别名：从 sema 模块重导出（sema_output.zig 已迁入 sema/）
pub const sema_output = sema_output_mod;


