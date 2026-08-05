#![allow(non_snake_case)]

pub mod ast;

#[path = "Value.rs"]
pub mod Value;

#[path = "TypeDesc.rs"]
pub mod TypeDesc;

pub mod sema;

#[path = "Reflect.rs"]
pub mod Reflect;

#[path = "ExternC.rs"]
pub mod ExternC;

#[path = "Ffi.rs"]
pub mod Ffi;

#[path = "ModuleLoader.rs"]
pub mod ModuleLoader;

pub mod ir;

#[path = "Engine.rs"]
pub mod Engine;

pub mod pass;
