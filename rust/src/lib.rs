#![allow(non_snake_case)]

#[path = "Ast.rs"]
pub mod Ast;

#[path = "Value.rs"]
pub mod Value;

#[path = "TypeDesc.rs"]
pub mod TypeDesc;

#[path = "Sema.rs"]
pub mod Sema;

#[path = "ExternC.rs"]
pub mod ExternC;

#[path = "Ffi.rs"]
pub mod Ffi;

#[path = "Stdlib.rs"]
pub mod Stdlib;
