//! build.rs — Glue @extern("C") 自动编译 + FFI 生成集成
//!
//! 工作流程：
//! 1. 扫描 EXTERN_GLUE_FILES 列表中的 .glue 文件（含 @extern("C") 声明）
//! 2. 若 glue 二进制可用：
//!    a. 对每个 .glue 调用 `glue emit-c` 生成 .c 文件到 OUT_DIR（不污染源码目录）
//!    b. 拼接所有 .glue 内容，通过 stdin 调用 `glue emit-ffi -` 生成 Rust FFI 代码
//! 3. 用 cc crate 编译所有 .c 文件为静态库 glue_extern
//! 4. 编译成功后删除 OUT_DIR 中的 .c 中间产物（不保留中间产物）
//! 5. 生成的 FFI 代码写入 $OUT_DIR/ffi_generated.rs，由 Ffi.rs include!

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// 含 @extern("C") 声明的 .glue 文件列表
///
/// reflect/Raw.glue 不在此列表：其原语实现在 Rust 侧 #[no_mangle] extern "C" fn，
/// 不需 emit-c 提取 C body。Raw.glue 文件本身由 Sema 直接加载（builtin）供 type check。
const EXTERN_GLUE_FILES: &[&str] = &[
    "stdlib/builtin/io/Raw.glue",
    "stdlib/builtin/net/Raw.glue",
    "stdlib/builtin/time/Raw.glue",
    "stdlib/builtin/cast/Raw.glue",
    "stdlib/builtin/str/Raw.glue",
];

fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_extern_c)");

    let out_dir = env::var("OUT_DIR").unwrap();
    let ffi_path = Path::new(&out_dir).join("ffi_generated.rs");

    // 收集存在的 .glue 文件
    let glue_files: Vec<PathBuf> = EXTERN_GLUE_FILES
        .iter()
        .map(PathBuf::from)
        .filter(|p| p.exists())
        .collect();

    // 1. 提取 Raw.c 到 OUT_DIR
    if !glue_files.is_empty() {
        try_auto_extract_c(&glue_files, &out_dir);
    }

    // 2. 生成 FFI 代码
    let ffi_code = if !glue_files.is_empty() {
        try_generate_ffi(&glue_files)
    } else {
        None
    };
    let ffi_ok = ffi_code.is_some();
    fs::write(
        &ffi_path,
        ffi_code.unwrap_or_else(|| empty_ffi_module().to_string()),
    )
    .unwrap();
    println!("cargo::rerun-if-changed={}", ffi_path.display());

    // 3. 收集 .c 文件（OUT_DIR 中的 Raw.c）
    let mut c_files: Vec<PathBuf> = Vec::new();
    for glue_file in &glue_files {
        let c_name = glue_file_to_c_name(glue_file);
        let c_path = Path::new(&out_dir).join(&c_name);
        if c_path.exists() {
            c_files.push(c_path);
        }
    }

    if c_files.is_empty() {
        if !glue_files.is_empty() && !find_glue_bin().exists() {
            println!(
                "cargo:warning=Found @extern(\"C\") .glue but glue binary unavailable, FFI code not generated"
            );
            println!("cargo:warning=Please run cargo build again to generate automatically");
        }
        return;
    }

    // 4. cc::Build 编译所有 .c 文件
    let mut build = cc::Build::new();
    build.flag("-Wno-unused-parameter");
    for c_file in &c_files {
        build.file(c_file);
    }
    for glue_file in &glue_files {
        println!("cargo::rerun-if-changed={}", glue_file.display());
    }
    match build.try_compile("glue_extern") {
        Ok(_) => {
            if ffi_ok {
                println!("cargo::rustc-cfg=has_extern_c");
            } else {
                println!(
                    "cargo:warning=C compilation succeeded but FFI generation failed, skipping has_extern_c cfg (wrapper module empty)"
                );
            }
            // 编译成功后删除 OUT_DIR 中的 .c 中间产物（不保留）
            for c_file in &c_files {
                let _ = fs::remove_file(c_file);
            }
        }
        Err(e) => {
            println!("cargo:warning=C compilation failed, skipping has_extern_c cfg: {}", e);
        }
    }
}

/// glue 文件路径 → OUT_DIR 中的唯一 .c 文件名
fn glue_file_to_c_name(glue_file: &Path) -> String {
    let stem = glue_file
        .with_extension("")
        .to_string_lossy()
        .replace('/', "_");
    format!("{}.c", stem)
}

/// 空的 FFI 模块（无 @extern("C") 函数时使用）
fn empty_ffi_module() -> &'static str {
    r#"// Auto-generated: no @extern("C") functions
#[cfg(has_extern_c)]
pub mod bindings {
    extern "C" {}
}

pub mod wrapper {}
"#
}

/// 查找已构建的 glue 二进制
fn find_glue_bin() -> PathBuf {
    let profile = if cfg!(debug_assertions) { "debug" } else { "release" };
    PathBuf::from(env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| "target".to_string()))
        .join(profile)
        .join("glue")
}

/// 尝试调用 `glue emit-c file.glue` 提取每个 .glue → OUT_DIR/xxx.c
fn try_auto_extract_c(glue_files: &[PathBuf], out_dir: &str) {
    let glue_bin = find_glue_bin();
    if !glue_bin.exists() {
        return;
    }

    for glue_file in glue_files {
        let c_name = glue_file_to_c_name(glue_file);
        let c_path = Path::new(out_dir).join(&c_name);
        let output = Command::new(&glue_bin)
            .arg("debug")
            .arg("--stage")
            .arg("emit-c")
            .arg(glue_file)
            .output();

        match output {
            Ok(result) if result.status.success() => {
                if fs::write(&c_path, &result.stdout).is_ok() {
                    println!(
                        "cargo:warning=Extracted C: {} → {}",
                        glue_file.display(),
                        c_path.display()
                    );
                }
            }
            _ => {
                println!("cargo:warning=C extraction failed: {}", glue_file.display());
            }
        }
    }
}

/// 尝试调用 `glue emit-ffi -` 生成 FFI 代码（拼接所有 .glue 通过 stdin）
fn try_generate_ffi(glue_files: &[PathBuf]) -> Option<String> {
    let glue_bin = find_glue_bin();
    if !glue_bin.exists() {
        return None;
    }

    let mut combined = String::new();
    for glue_file in glue_files {
        match fs::read_to_string(glue_file) {
            Ok(content) => {
                combined.push_str(&content);
                combined.push('\n');
            }
            Err(_) => {
                println!("cargo:warning=Read failed: {}", glue_file.display());
                return None;
            }
        }
    }

    let mut child = match Command::new(&glue_bin)
        .arg("debug")
        .arg("--stage")
        .arg("emit-ffi")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => {
            println!("cargo:warning=Failed to start glue debug --stage emit-ffi");
            return None;
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(combined.as_bytes());
    }

    let output = match child.wait_with_output() {
        Ok(o) => o,
        Err(_) => {
            println!("cargo:warning=glue debug --stage emit-ffi execution failed");
            return None;
        }
    };

    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        println!("cargo:warning=glue debug --stage emit-ffi returned non-zero status");
        None
    }
}
