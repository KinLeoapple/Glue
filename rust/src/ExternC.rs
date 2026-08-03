//! @extern("C") C 代码提取器 + Rust FFI wrapper 生成器
//!
//! 扫描已解析的 AST，提取所有带 `@extern("C")` 属性和 `extern_c_body` 的 FunDecl：
//! 1. 生成 C 源文件（函数原型 + 函数体 + 头文件依赖）
//! 2. 生成 Rust FFI 代码（extern "C" bindings + 安全 wrapper）
//!
//! ## 头文件管理
//!
//! 函数级 `@c_include("header.h")` 属性声明 C 函数体依赖的系统头文件。
//! 提取器收集所有函数的 @c_include，去重后输出到 .c 文件顶部。
//!
//! ## Glue → C 类型映射
//!
//! | Glue 类型 | C 参数 | C 返回 | Rust wrapper 类型 |
//! |-----------|--------|--------|-------------------|
//! | i8/i16/i32/i64 | name | int8_t..int64_t | i8..i64 |
//! | u8/u16/u32/u64 | name | uint8_t..uint64_t | u8..u64 |
//! | i128 | name_lo, name_hi | __int128 | i128 |
//! | u128 | name_lo, name_hi | unsigned __int128 | u128 |
//! | isize/usize | name | ssize_t/size_t | isize/usize |
//! | bool | name | int | bool |
//! | char | name | uint32_t | char |
//! | str | name_data, name_len | out: out_data, out_len | &str |
//! | f32 | name | float | f32 |
//! | f64 | name | double | f64 |
//! | f16 | name | uint16_t (bit pattern) | u16 |
//! | f128 | name_lo, name_hi | unsigned __int128 (bit pattern) | u128 |
//! | void (返回) | — | void | () |
//!
//! **str 返回**：C 无法直接返回 fat pointer，采用 out 参数模式。
//! Glue `fun foo(): str` → C `void glue_foo(..., const char** out_data, size_t* out_len)`。
//! C body 设置 `*out_data` 和 `*out_len`，Rust wrapper 构造 `&'static str`。
//!
//! **i128/u128/f128 返回**：C 侧用 `__int128`/`unsigned __int128`（GCC/Clang 扩展）。
//! Rust `i128`/`u128` 在 extern "C" 中 ABI 兼容。MSVC 不支持 `__int128`，需用 GCC/Clang。
//!
//! **f16/f128**：以 bit pattern 传递（u16/u128），C body 内部用 union/memcpy 转换。
//! f128 参数同 u128（lo/hi 两个 uint64_t），f128 返回用 `unsigned __int128`。
//!
//! ## Rust wrapper marshal 规则
//!
//! | Glue 参数 | Rust wrapper 类型 | marshal 动作 |
//! |-----------|-------------------|-------------|
//! | str | &str | s.as_ptr() as *const c_char, s.len() |
//! | i128/u128 | i128/u128 | (n as u64), (n >> 64) as u64 |
//! | f128 | u128 | (n as u64), (n >> 64) as u64 |
//! | bool | bool | b as c_int |
//! | char | char | c as u32 |
//! | 其他标量 | 同名 | 直接传 |

use crate::Ast::{Attribute, Decl, Module, TypeNode};
use std::borrow::Cow;

// ============ 类型映射 ============

/// C 函数参数：名称 + 类型
struct CParam {
    name: String,
    c_type: String,
}

/// Glue 参数（wrapper 签名用）
struct GlueParam {
    name: String,
    glue_type: String,
}

/// 提取结果：一个 @extern("C") 函数的完整信息
struct ExternCFunc {
    glue_name: String,
    c_return: String,
    c_name: String,
    c_params: Vec<CParam>,
    c_body: String,
    c_includes: Vec<String>,
    glue_params: Vec<GlueParam>,
    glue_return: String,
}

/// Glue 类型名 → C 返回类型
///
/// str 返回 None：C 无法返回 fat pointer，由 `extract_extern_c_funcs` 用 out 参数模式处理。
/// i128/u128/f128 返回 `__int128`/`unsigned __int128`（需 GCC/Clang）。
/// f16 返回 `uint16_t`（bit pattern）。
fn glue_type_to_c_return(glue_name: &str) -> Option<&'static str> {
    match glue_name {
        "i8" => Some("int8_t"),
        "i16" => Some("int16_t"),
        "i32" => Some("int32_t"),
        "i64" => Some("int64_t"),
        "u8" => Some("uint8_t"),
        "u16" => Some("uint16_t"),
        "u32" => Some("uint32_t"),
        "u64" => Some("uint64_t"),
        "i128" => Some("__int128"),
        "u128" => Some("unsigned __int128"),
        "isize" => Some("ssize_t"),
        "usize" => Some("size_t"),
        "bool" => Some("int"),
        "char" => Some("uint32_t"),
        "f32" => Some("float"),
        "f64" => Some("double"),
        "f16" => Some("uint16_t"),
        "f128" => Some("unsigned __int128"),
        "void" => Some("void"),
        "*u8" => Some("uint8_t*"),
        "*i8" => Some("int8_t*"),
        "*u16" => Some("uint16_t*"),
        "*i16" => Some("int16_t*"),
        "*u32" => Some("uint32_t*"),
        "*i32" => Some("int32_t*"),
        "*u64" => Some("uint64_t*"),
        "*i64" => Some("int64_t*"),
        "*void" => Some("void*"),
        _ => None,
    }
}

/// Glue 类型名 → C 参数列表（一个 Glue 参数可能映射为多个 C 参数）
fn glue_type_to_c_params(glue_name: &str, param_name: &str) -> Option<Vec<CParam>> {
    match glue_name {
        "i8" => Some(vec![CParam { name: param_name.to_string(), c_type: "int8_t".to_string() }]),
        "i16" => Some(vec![CParam { name: param_name.to_string(), c_type: "int16_t".to_string() }]),
        "i32" => Some(vec![CParam { name: param_name.to_string(), c_type: "int32_t".to_string() }]),
        "i64" => Some(vec![CParam { name: param_name.to_string(), c_type: "int64_t".to_string() }]),
        "u8" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint8_t".to_string() }]),
        "u16" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint16_t".to_string() }]),
        "u32" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint32_t".to_string() }]),
        "u64" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint64_t".to_string() }]),
        "i128" | "u128" => Some(vec![
            CParam { name: format!("{}_lo", param_name), c_type: "uint64_t".to_string() },
            CParam { name: format!("{}_hi", param_name), c_type: "uint64_t".to_string() },
        ]),
        "isize" => Some(vec![CParam { name: param_name.to_string(), c_type: "ssize_t".to_string() }]),
        "usize" => Some(vec![CParam { name: param_name.to_string(), c_type: "size_t".to_string() }]),
        "bool" => Some(vec![CParam { name: param_name.to_string(), c_type: "int".to_string() }]),
        "char" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint32_t".to_string() }]),
        "str" => Some(vec![
            CParam { name: format!("{}_data", param_name), c_type: "const char*".to_string() },
            CParam { name: format!("{}_len", param_name), c_type: "size_t".to_string() },
        ]),
        "f32" => Some(vec![CParam { name: param_name.to_string(), c_type: "float".to_string() }]),
        "f64" => Some(vec![CParam { name: param_name.to_string(), c_type: "double".to_string() }]),
        "f16" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint16_t".to_string() }]),
        "f128" => Some(vec![
            CParam { name: format!("{}_lo", param_name), c_type: "uint64_t".to_string() },
            CParam { name: format!("{}_hi", param_name), c_type: "uint64_t".to_string() },
        ]),
        "u8[]" => Some(vec![
            CParam { name: format!("{}_data", param_name), c_type: "uint8_t*".to_string() },
            CParam { name: format!("{}_len", param_name), c_type: "size_t".to_string() },
        ]),
        "*u8" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint8_t*".to_string() }]),
        "*i8" => Some(vec![CParam { name: param_name.to_string(), c_type: "int8_t*".to_string() }]),
        "*u16" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint16_t*".to_string() }]),
        "*i16" => Some(vec![CParam { name: param_name.to_string(), c_type: "int16_t*".to_string() }]),
        "*u32" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint32_t*".to_string() }]),
        "*i32" => Some(vec![CParam { name: param_name.to_string(), c_type: "int32_t*".to_string() }]),
        "*u64" => Some(vec![CParam { name: param_name.to_string(), c_type: "uint64_t*".to_string() }]),
        "*i64" => Some(vec![CParam { name: param_name.to_string(), c_type: "int64_t*".to_string() }]),
        "*void" => Some(vec![CParam { name: param_name.to_string(), c_type: "void*".to_string() }]),
        _ => None,
    }
}

/// C 类型名 → Rust binding 类型
fn c_type_to_rust(c_type: &str) -> &'static str {
    match c_type {
        "int8_t" => "i8",
        "int16_t" => "i16",
        "int32_t" => "i32",
        "int64_t" => "i64",
        "uint8_t" => "u8",
        "uint16_t" => "u16",
        "uint32_t" => "u32",
        "uint64_t" => "u64",
        "__int128" => "i128",
        "unsigned __int128" => "u128",
        "ssize_t" => "isize",
        "size_t" => "usize",
        "int" => "core::ffi::c_int",
        "const char*" => "*const core::ffi::c_char",
        "const char**" => "*mut *const core::ffi::c_char",
        "size_t*" => "*mut usize",
        "const uint8_t*" => "*const u8",
        "uint8_t*" => "*mut u8",
        "int8_t*" => "*mut i8",
        "uint16_t*" => "*mut u16",
        "int16_t*" => "*mut i16",
        "uint32_t*" => "*mut u32",
        "int32_t*" => "*mut i32",
        "uint64_t*" => "*mut u64",
        "int64_t*" => "*mut i64",
        "void*" => "*mut core::ffi::c_void",
        "float" => "f32",
        "double" => "f64",
        "void" => "()",
        _ => "()",
    }
}

/// Glue 类型名 → Rust wrapper 参数/返回类型
///
/// f16 → u16, f128 → u128：以 bit pattern 传递，Glue 侧 f16/f128 内部就是 u16/u128。
fn glue_type_to_rust_wrapper(glue_type: &str) -> Option<&'static str> {
    match glue_type {
        "i8" => Some("i8"),
        "i16" => Some("i16"),
        "i32" => Some("i32"),
        "i64" => Some("i64"),
        "u8" => Some("u8"),
        "u16" => Some("u16"),
        "u32" => Some("u32"),
        "u64" => Some("u64"),
        "i128" => Some("i128"),
        "u128" => Some("u128"),
        "isize" => Some("isize"),
        "usize" => Some("usize"),
        "bool" => Some("bool"),
        "char" => Some("char"),
        "str" => Some("&str"),
        "f32" => Some("f32"),
        "f64" => Some("f64"),
        "f16" => Some("u16"),
        "f128" => Some("u128"),
        "u8[]" => Some("&[u8]"),
        "void" => Some("()"),
        "*u8" => Some("*mut u8"),
        "*i8" => Some("*mut i8"),
        "*u16" => Some("*mut u16"),
        "*i16" => Some("*mut i16"),
        "*u32" => Some("*mut u32"),
        "*i32" => Some("*mut i32"),
        "*u64" => Some("*mut u64"),
        "*i64" => Some("*mut i64"),
        "*void" => Some("*mut core::ffi::c_void"),
        _ => None,
    }
}

// ============ 属性识别 ============

/// 检查属性列表是否包含 @extern("C")
/// [E-3] 仅识别大写 "C"（项目约束）；若误写小写 "c" 输出警告，避免静默漏判。
fn is_extern_c(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        if a.name != "extern" {
            return false;
        }
        if a.args.contains(&"C") {
            return true;
        }
        if a.args.contains(&"c") {
            eprintln!("warning: @extern(\"c\") must use uppercase 'C' (i.e. @extern(\"C\")); this attribute will be ignored");
        }
        false
    })
}

/// 收集 @c_include("...") 属性中的头文件名
fn collect_c_includes(attrs: &[Attribute]) -> Vec<String> {
    let mut includes = Vec::new();
    for attr in attrs {
        if attr.name == "c_include" {
            for arg in &attr.args {
                let inc = arg.to_string();
                if !includes.contains(&inc) {
                    includes.push(inc);
                }
            }
        }
    }
    includes
}

// ============ AST 提取 ============

/// 从 TypeNode 提取类型名字字符串
///
/// 支持的类型：
/// - `Named { name }` → 返回 name（如 "i32"、"str"）
/// - `Array { element_type, size: None }` → 返回 "elem[]"（如 "u8[]"）
/// - `Array { element_type, size: Some(n) }` → 返回 "elem[n]"（暂不支持 @extern("C")）
///
/// 其他复杂类型（Record/Function 等）返回 None。
fn extract_type_name<'a>(
    ty: Option<crate::Ast::TypeRef>,
    arena: &crate::Ast::AstArena<'a>,
) -> Option<Cow<'a, str>> {
    let ty_ref = ty?;
    // [E-2] 安全索引：畸形 AST（parser 错误恢复）可能产生非法 TypeRef，避免 panic
    let node = arena.types.get(ty_ref.0 as usize)?;
    match &node.node {
        TypeNode::Named { name } => Some(Cow::Borrowed(*name)),
        TypeNode::RawPtr { inner } => {
            // *T → "*T"（如 *u8 → "*u8"），由 glue_type_to_c_return/params 映射为 C 指针
            let inner_ref = *inner;
            let inner_node = arena.types.get(inner_ref.0 as usize)?;
            if let TypeNode::Named { name: inner_name } = &inner_node.node {
                Some(Cow::Owned(format!("*{}", inner_name)))
            } else {
                None
            }
        }
        TypeNode::Array { element_type, size } => {
            let elem_ref = *element_type;
            let elem_node = arena.types.get(elem_ref.0 as usize)?;
            if let TypeNode::Named { name: elem_name } = &elem_node.node {
                if size.is_none() {
                    Some(Cow::Owned(format!("{}[]", elem_name)))
                } else {
                    // 固定大小数组暂不支持 @extern("C")
                    None
                }
            } else {
                None
            }
        }
        _ => None,
    }
}

/// 从模块中提取所有 @extern("C") 函数信息
fn extract_extern_c_funcs<'a>(module: &Module<'a>) -> Result<Vec<ExternCFunc>, String> {
    let arena = &module.arena;
    let mut funcs = Vec::new();
    let mut errors = Vec::new();

    for decl in &module.declarations {
        if let Decl::FunDecl {
            name,
            params,
            return_type,
            attributes,
            extern_c_body,
            ..
        } = &decl.node
        {
            // 只处理带 @extern("C") 属性的函数
            if !is_extern_c(attributes) {
                continue;
            }

            // @extern("C") 必须有 C 函数体
            let c_body = match extern_c_body {
                Some(body) => body.to_string(),
                None => {
                    errors.push(format!(
                        "@extern(\"C\") 函数 '{}': 缺少 C 函数体（需要 #{{ ... }}# 原始块）",
                        name
                    ));
                    continue;
                }
            };

            // 收集 @c_include 依赖
            let c_includes = collect_c_includes(attributes);

            // 映射返回类型
            // str 返回用 out 参数模式：C 函数返回 void，追加 out_data/out_len 参数
            // i128/u128/f128 返回用 __int128/unsigned __int128（需 GCC/Clang）
            let ret_name = extract_type_name(*return_type, arena);
            let glue_return = ret_name.as_deref().unwrap_or("void").to_string();
            let is_str_return = glue_return == "str";
            let c_return = if is_str_return {
                "void".to_string()
            } else {
                match ret_name.as_deref().and_then(glue_type_to_c_return) {
                    Some(c) => c.to_string(),
                    None => {
                        let ty_str = ret_name.as_deref().unwrap_or("<unknown>");
                        errors.push(format!(
                            "@extern(\"C\") 函数 '{}': 不支持的返回类型 '{}'",
                            name, ty_str
                        ));
                        continue;
                    }
                }
            };

            // 映射参数
            let mut c_params = Vec::new();
            let mut glue_params = Vec::new();
            let mut param_ok = true;
            for param in params.iter() {
                let param_ty_name = extract_type_name(param.type_annotation, arena);
                let glue_type = param_ty_name.as_deref().unwrap_or("<unknown>").to_string();
                match param_ty_name.as_deref().and_then(|n| glue_type_to_c_params(n, param.name)) {
                    Some(ps) => c_params.extend(ps),
                    None => {
                        let ty_str = param_ty_name.as_deref().unwrap_or("<unknown>");
                        errors.push(format!(
                            "@extern(\"C\") 函数 '{}': 不支持的参数类型 '{}'（参数 '{}'）",
                            name, ty_str, param.name
                        ));
                        param_ok = false;
                        break;
                    }
                }
                glue_params.push(GlueParam {
                    name: param.name.to_string(),
                    glue_type,
                });
            }
            if !param_ok {
                continue;
            }

            // str 返回追加 out 参数（C 侧填充 out_data/out_len）
            if is_str_return {
                c_params.push(CParam {
                    name: "out_data".to_string(),
                    c_type: "const char**".to_string(),
                });
                c_params.push(CParam {
                    name: "out_len".to_string(),
                    c_type: "size_t*".to_string(),
                });
            }

            funcs.push(ExternCFunc {
                glue_name: name.to_string(),
                c_return,
                c_name: format!("glue_extern_{}", name),
                c_params,
                c_body,
                c_includes,
                glue_params,
                glue_return,
            });
        }
    }

    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }

    Ok(funcs)
}

// ============ C 代码生成 ============

/// 从模块中提取所有 @extern("C") 函数，生成完整 .c 文件内容
pub fn extract_c_from_module<'a>(module: &Module<'a>) -> Result<String, String> {
    let funcs = extract_extern_c_funcs(module)?;

    // 收集所有头文件去重
    let mut all_includes: Vec<String> = Vec::new();
    for func in &funcs {
        for inc in &func.c_includes {
            if !all_includes.contains(inc) {
                all_includes.push(inc.clone());
            }
        }
    }

    let mut out = String::new();
    out.push_str("// Auto-generated by glue-rs @extern(\"C\") extractor\n");
    out.push_str("// DO NOT EDIT — regenerate with: glue emit-c <file>\n");
    out.push_str("#include <stdint.h>\n");
    out.push_str("#include <stddef.h>\n");
    for inc in &all_includes {
        out.push_str(&format!("#include <{}>\n", inc));
    }
    out.push('\n');

    for func in &funcs {
        let params_str = if func.c_params.is_empty() {
            "void".to_string()
        } else {
            func.c_params
                .iter()
                .map(|p| format!("{} {}", p.c_type, p.name))
                .collect::<Vec<_>>()
                .join(", ")
        };
        out.push_str(&format!("{} {}({}) {{\n", func.c_return, func.c_name, params_str));

        // 为 i128/u128/f128 参数自动插入 lo/hi 重建变量
        // 使 C body 可直接用原始参数名（如 x），无需手动处理 x_lo/x_hi
        for p in &func.glue_params {
            match p.glue_type.as_str() {
                "i128" => {
                    out.push_str(&format!(
                        "    __int128 {n} = (__int128)((unsigned __int128){n}_lo | ((unsigned __int128){n}_hi << 64));\n",
                        n = p.name
                    ));
                }
                "u128" | "f128" => {
                    out.push_str(&format!(
                        "    unsigned __int128 {n} = (unsigned __int128){n}_lo | ((unsigned __int128){n}_hi << 64);\n",
                        n = p.name
                    ));
                }
                _ => {}
            }
        }

        let body = func.c_body.trim_matches('\n');
        out.push_str(body);
        out.push_str("\n}\n\n");
    }

    Ok(out)
}

// ============ Rust FFI 生成 ============

/// 从模块中提取所有 @extern("C") 函数，生成 Rust FFI 代码（bindings + wrapper）
pub fn extract_rust_ffi_from_module<'a>(module: &Module<'a>) -> Result<String, String> {
    let funcs = extract_extern_c_funcs(module)?;
    generate_rust_ffi(&funcs)
}

fn generate_rust_ffi(funcs: &[ExternCFunc]) -> Result<String, String> {
    let mut out = String::new();

    out.push_str("// Auto-generated by glue-rs @extern(\"C\") FFI generator\n");
    out.push_str("// DO NOT EDIT — regenerate with: glue emit-ffi <file>\n\n");

    // === bindings 模块 ===
    out.push_str("/// @extern(\"C\") 绑定：由 build.rs 编译的 glue_extern 静态库提供符号\n");
    out.push_str("#[cfg(has_extern_c)]\n");
    out.push_str("pub mod bindings {\n");
    out.push_str("    extern \"C\" {\n");
    for func in funcs {
        let params = if func.c_params.is_empty() {
            String::new()
        } else {
            func.c_params
                .iter()
                .map(|p| format!("{}: {}", p.name, c_type_to_rust(&p.c_type)))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let ret = c_type_to_rust(&func.c_return);
        if ret == "()" {
            out.push_str(&format!("        pub fn {}({});\n", func.c_name, params));
        } else {
            out.push_str(&format!("        pub fn {}({}) -> {};\n", func.c_name, params, ret));
        }
    }
    out.push_str("    }\n");
    out.push_str("}\n\n");

    // === wrapper 模块 ===
    out.push_str("/// 安全包装层：Glue 值 → C ABI marshal\n");
    out.push_str("#[allow(clippy::missing_safety_doc)]\n");
    out.push_str("pub mod wrapper {\n");
    out.push_str("    /// 调用底层 binding（需 cfg(has_extern_c)）\n");
    out.push_str("    #[cfg(has_extern_c)]\n");
    out.push_str("    use super::bindings;\n\n");

    for func in funcs {
        out.push_str(&generate_wrapper_fn(func));
    }

    out.push_str("}\n");

    Ok(out)
}

/// 为单个函数生成 wrapper 函数
///
/// str 返回用 out 参数模式：声明 out 变量 → 调用 binding 传入 &mut → 构造 &'static str。
/// f128 参数同 u128（lo/hi 拆分），f16 参数直接传 u16。
fn generate_wrapper_fn(func: &ExternCFunc) -> String {
    let mut out = String::new();
    let is_str_return = func.glue_return == "str";

    // 文档注释
    let glue_sig = format!(
        "fun {}({}): {}",
        func.glue_name,
        func.glue_params
            .iter()
            .map(|p| format!("{}: {}", p.name, p.glue_type))
            .collect::<Vec<_>>()
            .join(", "),
        func.glue_return
    );
    out.push_str(&format!("    /// @extern(\"C\") {} 的安全包装\n", func.glue_name));
    out.push_str(&format!("    /// Glue 签名: {}\n", glue_sig));

    // 函数签名
    let rust_params: Vec<String> = func
        .glue_params
        .iter()
        .map(|p| {
            format!(
                "{}: {}",
                p.name,
                glue_type_to_rust_wrapper(&p.glue_type).unwrap_or("()")
            )
        })
        .collect();
    // str 返回用 &'static str（C 侧 out 参数填充，wrapper 构造引用）
    let rust_return = if is_str_return {
        "&'static str"
    } else {
        glue_type_to_rust_wrapper(&func.glue_return).unwrap_or("()")
    };

    out.push_str("    #[cfg(has_extern_c)]\n");
    if rust_return == "()" {
        out.push_str(&format!(
            "    pub unsafe fn {}({}) {{\n",
            func.glue_name,
            rust_params.join(", ")
        ));
    } else {
        out.push_str(&format!(
            "    pub unsafe fn {}({}) -> {} {{\n",
            func.glue_name,
            rust_params.join(", "),
            rust_return
        ));
    }

    // str 返回：声明 out 变量供 C 侧填充
    if is_str_return {
        out.push_str("        let mut out_data: *const core::ffi::c_char = core::ptr::null();\n");
        out.push_str("        let mut out_len: usize = 0;\n");
    }

    // marshal 代码：为 1:N 参数生成拆分变量
    for p in &func.glue_params {
        match p.glue_type.as_str() {
            "str" => {
                out.push_str(&format!(
                    "        let {n}_data = {n}.as_ptr() as *const core::ffi::c_char;\n",
                    n = p.name
                ));
                out.push_str(&format!("        let {n}_len = {n}.len();\n", n = p.name));
            }
            "u8[]" => {
                out.push_str(&format!(
                    "        let {n}_data = {n}.as_ptr() as *mut u8;\n",
                    n = p.name
                ));
                out.push_str(&format!("        let {n}_len = {n}.len();\n", n = p.name));
            }
            "i128" | "u128" | "f128" => {
                out.push_str(&format!("        let {n}_lo = {n} as u64;\n", n = p.name));
                out.push_str(&format!("        let {n}_hi = ({n} >> 64) as u64;\n", n = p.name));
            }
            _ => {}
        }
    }

    // 生成调用参数：按 Glue 参数顺序展开为 C 参数
    let mut call_args: Vec<String> = Vec::new();
    for p in &func.glue_params {
        match p.glue_type.as_str() {
            "str" => {
                call_args.push(format!("{}_data", p.name));
                call_args.push(format!("{}_len", p.name));
            }
            "u8[]" => {
                call_args.push(format!("{}_data", p.name));
                call_args.push(format!("{}_len", p.name));
            }
            "i128" | "u128" | "f128" => {
                call_args.push(format!("{}_lo", p.name));
                call_args.push(format!("{}_hi", p.name));
            }
            "bool" => {
                call_args.push(format!("{} as core::ffi::c_int", p.name));
            }
            "char" => {
                call_args.push(format!("{} as u32", p.name));
            }
            _ => {
                call_args.push(p.name.clone());
            }
        }
    }

    // str 返回追加 out 参数到调用列表
    if is_str_return {
        call_args.push("&mut out_data".to_string());
        call_args.push("&mut out_len".to_string());
    }

    // 返回值转换
    let call_expr = format!("bindings::{}({})", func.c_name, call_args.join(", "));

    if is_str_return {
        // str 返回：先调用 binding 填充 out 变量，再构造 &'static str 返回。
        // [E-1] 安全化：校验 null + UTF-8，消除 from_utf8_unchecked 与 null 切片两重 UB。
        // 生命周期 UB 由 C body 契约消除：C body 必须写入 'static 内存（字符串字面量指针），
        // 不得用栈/堆临时缓冲返回（否则 wrapper 返回的 &'static str 在 C 函数返回后悬垂）。
        out.push_str(&format!("        {};\n", call_expr));
        out.push_str("        if out_data.is_null() || out_len == 0 {\n");
        out.push_str("            \"\"\n");
        out.push_str("        } else {\n");
        out.push_str("            let bytes = core::slice::from_raw_parts(out_data as *const u8, out_len);\n");
        out.push_str("            core::str::from_utf8(bytes).unwrap_or(\"\")\n");
        out.push_str("        }\n");
    } else {
        let return_expr = if rust_return == "()" {
            call_expr
        } else {
            let c_ret = c_type_to_rust(&func.c_return);
            if c_ret == rust_return {
                call_expr
            } else {
                match func.glue_return.as_str() {
                    "bool" => format!("{} != 0", call_expr),
                    "char" => format!("{} as char", call_expr),
                    _ => format!("{} as {}", call_expr, rust_return),
                }
            }
        };
        if rust_return == "()" {
            out.push_str(&format!("        {};\n", return_expr));
        } else {
            out.push_str(&format!("        {}\n", return_expr));
        }
    }

    out.push_str("    }\n\n");

    out
}
