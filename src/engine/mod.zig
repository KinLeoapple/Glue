//! Glue IR 执行引擎（后端）
//!
//! 接收优化的 GlueIR，线性遍历 nodes[]，switch 跳转表分派，读写通道，产出运行结果。
//! 设计参考：docs/glue-ir-design.md 第 6 章
//!
//! 内存体系：自实现三层分配器（src/mem/）
//!   - ChannelRegion：通道运行时数据（bump+reset，64B 对齐 SIMD 友好）
//!   - ShadowArena：defer 栈 + 临时缓冲（bump+reset，函数级 reset）
//!   - ThreadContext 对象池：堆对象（中长生命周期）
//!
//! Phase 1：标量 op + 控制流 + 函数调用
//! 后续 Phase：向量/门控/路由/竞争/清理/星轨

const std = @import("std");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");

pub const engine_mod = @import("engine.zig");
pub const runtime_mod = @import("runtime.zig");

pub const Engine = engine_mod.Engine;
pub const EngineError = engine_mod.EngineError;
pub const Runtime = runtime_mod.Runtime;

test {
    _ = engine_mod;
    _ = runtime_mod;
}
