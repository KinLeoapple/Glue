#![allow(non_snake_case)]

#[path = "Ast.rs"]
pub mod Ast;

#[path = "Value.rs"]
pub mod Value;

#[path = "TypeDesc.rs"]
pub mod TypeDesc;

#[path = "Sema.rs"]
pub mod Sema;

#[path = "Reflect.rs"]
pub mod Reflect;

#[path = "ExternC.rs"]
pub mod ExternC;

#[path = "Ffi.rs"]
pub mod Ffi;

#[path = "ModuleLoader.rs"]
pub mod ModuleLoader;

#[path = "Ir.rs"]
pub mod Ir;

#[path = "Engine.rs"]
pub mod Engine;

#[path = "Analyzer.rs"]
pub mod Analyzer;

#[path = "Optimizer.rs"]
pub mod Optimizer;
