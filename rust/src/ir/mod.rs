//! ir — Intermediate representation and IR builder modules.
//!
//! Aggregates two IR-related submodules:
//! - [`Ir`]: IR data structures (Node, Frame, SubGraph, DataFlowGraph, ComputeFn table).
//! - [`Builder`]: IR builder (IrBuilder + all compile_* methods + build() entry point).

pub mod Ir;
pub mod Builder;
