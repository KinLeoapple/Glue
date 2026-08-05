//! sema — 语义分析模块
//!
//! 汇总 Sema 管线的 5 个子模块：
//! - `Sema`：类型系统核心数据结构（ConcreteType / TypeArena / SemaResult）
//! - `Relations`：类型关系判定（等价 / 子类型 / 数值提升）
//! - `Inference`：类型推断与约束求解
//! - `Monomorph`：单态化实例收集
//! - `Analyzer`：Sema 后静态分析（死代码 / 记忆化策略）

pub mod Sema;
pub mod Relations;
pub mod Inference;
pub mod Monomorph;
pub mod Analyzer;
