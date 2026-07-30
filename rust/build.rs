//! build.rs — Glue @extern("C") 自动编译 + FFI 生成集成
//!
//! 工作流程：
//! 1. 扫描 stdlib/syscall/ 目录下的 .glue 文件
//! 2. 若 glue 二进制可用：
//!    a. 对每个 .glue 调用 `glue emit-c` 生成 .c 文件
//!    b. 拼接所有 .glue 内容，通过 stdin 调用 `glue emit-ffi -` 生成 Rust FFI 代码
//! 3. 用 cc crate 编译所有 stdlib/syscall/*.c 为静态库 glue_extern
//! 4. 生成的 FFI 代码写入 $OUT_DIR/ffi_generated.rs，由 Ffi.rs include!
//! 5. 若无 .c 文件，生成空 FFI 模块，静默跳过
//!
//! 用户工作流：
//!   方式一（全自动）：cargo build（首次构建 glue 二进制，二次构建自动生成 FFI）
//!   方式二（手动）：cargo run -- emit-c stdlib/syscall/xxx.glue > stdlib/syscall/xxx.c && cargo build

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_extern_c)");

    let out_dir = env::var("OUT_DIR").unwrap();
    let ffi_path = Path::new(&out_dir).join("ffi_generated.rs");

    let extern_dir = Path::new("stdlib/syscall");

    // 收集 .glue 文件
    let glue_files: Vec<PathBuf> = if extern_dir.exists() {
        fs::read_dir(extern_dir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("glue"))
            .collect()
    } else {
        Vec::new()
    };

    // 尝试自动提取 C 代码和 FFI 代码
    if !glue_files.is_empty() {
        try_auto_extract_c(&glue_files);
    }

    // 总是覆盖写入 ffi_generated.rs（确保删除 stdlib/syscall/ 后 FFI 代码也清空）
    let ffi_code = if !glue_files.is_empty() {
        try_generate_ffi(&glue_files)
    } else {
        None
    };
    fs::write(&ffi_path, ffi_code.unwrap_or_else(|| empty_ffi_module().to_string())).unwrap();
    println!("cargo::rerun-if-changed={}", ffi_path.display());

    // 收集 .c 文件（自动提取的 + 用户手动放置的）
    let c_files: Vec<PathBuf> = if extern_dir.exists() {
        fs::read_dir(extern_dir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("c"))
            .collect()
    } else {
        Vec::new()
    };

    if c_files.is_empty() {
        if !glue_files.is_empty() && !find_glue_bin().exists() {
            println!("cargo:warning=发现 stdlib/syscall/*.glue 但 glue 二进制不可用，FFI 代码未生成");
            println!("cargo:warning=请再次运行 cargo build 以自动生成");
        }
        return;
    }

    // 用 cc crate 编译所有 .c 文件
    // 如果编译失败（如 C 代码有语法错误），只发出 warning 不阻塞构建
    // 这样 glue 二进制可以先编译成功，下一轮再重新提取
    let mut build = cc::Build::new();
    // marshal 层为 str/u8[] 自动生成 _data/_len 参数对，
    // 部分 C body 不使用 _len（如 write 用 buf_len），抑制 unused-parameter 噪音
    build.flag("-Wno-unused-parameter");
    for c_file in &c_files {
        build.file(c_file);
        println!("cargo:rerun-if-changed={}", c_file.display());
    }
    for glue_file in &glue_files {
        println!("cargo:rerun-if-changed={}", glue_file.display());
    }
    match build.try_compile("glue_extern") {
        Ok(_) => {
            println!("cargo::rustc-cfg=has_extern_c");
        }
        Err(e) => {
            println!("cargo:warning=C 编译失败，跳过 has_extern_c cfg: {}", e);
        }
    }
}

/// 空的 FFI 模块（无 @extern("C") 函数时使用）
fn empty_ffi_module() -> &'static str {
    r#"// Auto-generated: 无 @extern("C") 函数
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

/// 尝试调用 `glue emit-c file.glue` 提取每个 .glue → .c
fn try_auto_extract_c(glue_files: &[PathBuf]) {
    let glue_bin = find_glue_bin();
    if !glue_bin.exists() {
        return;
    }

    for glue_file in glue_files {
        let c_path = glue_file.with_extension("c");
        let output = Command::new(&glue_bin)
            .arg("emit-c")
            .arg(glue_file)
            .output();

        match output {
            Ok(result) if result.status.success() => {
                if fs::write(&c_path, &result.stdout).is_ok() {
                    println!("cargo:warning=提取 C: {} → {}", glue_file.display(), c_path.display());
                }
            }
            _ => {
                println!("cargo:warning=C 提取失败: {}", glue_file.display());
            }
        }
    }
}

/// 尝试调用 `glue emit-ffi -` 生成 FFI 代码（拼接所有 .glue 通过 stdin）
/// 成功返回 Some(code)，失败返回 None
fn try_generate_ffi(glue_files: &[PathBuf]) -> Option<String> {
    let glue_bin = find_glue_bin();
    if !glue_bin.exists() {
        return None;
    }

    // 拼接所有 .glue 文件内容
    let mut combined = String::new();
    for glue_file in glue_files {
        match fs::read_to_string(glue_file) {
            Ok(content) => {
                combined.push_str(&content);
                combined.push('\n');
            }
            Err(_) => {
                println!("cargo:warning=读取失败: {}", glue_file.display());
                return None;
            }
        }
    }

    // 通过 stdin 传给 glue emit-ffi -
    let mut child = match Command::new(&glue_bin)
        .arg("emit-ffi")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => {
            println!("cargo:warning=启动 glue emit-ffi 失败");
            return None;
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(combined.as_bytes());
    }

    let output = match child.wait_with_output() {
        Ok(o) => o,
        Err(_) => {
            println!("cargo:warning=glue emit-ffi 执行失败");
            return None;
        }
    };

    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        println!("cargo:warning=glue emit-ffi 返回非零状态");
        None
    }
}
