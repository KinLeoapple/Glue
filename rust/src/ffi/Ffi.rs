//! FFI 绑定模块（由 build.rs 自动生成）
//!
//! bindings 和 wrapper 由 build.rs 从 builtin/*/Raw.glue 自动生成：
//! - `glue emit-c` 生成 .c 文件，cc 编译为 glue_extern 静态库
//! - `glue emit-ffi` 生成 Rust FFI 代码（bindings + wrapper），写入 $OUT_DIR/ffi_generated.rs
//!
//! 若 builtin 下无 @extern("C") .glue 文件，此模块为空。
//!
//! ## 使用方式
//!
//! 1. 在 builtin/{io,net,time,cast}/Raw.glue 中声明 @extern("C") 函数
//! 2. 运行 `cargo build`（首次构建 glue 二进制）
//! 3. 再次运行 `cargo build`（自动提取 C + 生成 FFI + 编译链接）
//!
//! ## 调用方式
//!
//! Glue 侧直接用函数名调用：`__stdout_write("hello")`
//! Rust 侧调用 wrapper：`unsafe { glue_rs::Ffi::wrapper::__stdout_write("hello") }`

include!(concat!(env!("OUT_DIR"), "/ffi_generated.rs"));
