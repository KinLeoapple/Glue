//! pass — Post-processing passes (Sema-post and IR-post).
//!
//! Aggregates two post-processing pass modules:
//! - [`Analyzer`]: Sema-post static analysis (dead code / dead var / dead func
//!   + memoization strategies). Consumes [`SemaResult`] + AST, produces
//!   [`AnalysisReport`] consumed by IrBuilder.
//! - [`Optimizer`]: IR-post graph optimization (ConstFold → CSE → CopyProp → DCE).
//!   Consumes and transforms [`DataFlowGraph`] in place.
//!
//! Both are independent post-processing passes sitting between major pipeline
//! stages: Analyzer runs between Sema and IR build; Optimizer runs between IR
//! build and Engine execution.
//!
//! [`SemaResult`]: crate::sema::Sema::SemaResult
//! [`AnalysisReport`]: crate::pass::Analyzer::AnalysisReport
//! [`DataFlowGraph`]: crate::ir::Ir::DataFlowGraph

pub mod Analyzer;
pub mod Optimizer;
