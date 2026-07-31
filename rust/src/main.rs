//! glue-rs 端到端 CLI
//!
//! 用法：
//!   glue parse <file>      解析 .glue 文件并打印 AST（规范 S-表达式）
//!   glue lex <file>        仅词法分析，打印 Token 列表
//!   glue parse -           从 stdin 读取源码并解析
//!   glue emit-c <file>     提取 @extern("C") 函数，生成 .c 文件到 stdout
//!   glue emit-ffi <file>   生成 Rust FFI 绑定 + wrapper 代码到 stdout

use std::env;
use std::fs;
use std::io::{self, Read};
use std::process;

use glue_rs::Ast::{ErrorCollector, Lexer, Parser, Printer, Token, TokenCollector};
use glue_rs::ModuleLoader::ModuleLoader;
use glue_rs::Sema::{EnvId, InferContext, SemaResult, TypeArena};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        usage();
        process::exit(1);
    }

    match args[1].as_str() {
        "parse" => {
            if args.len() < 3 {
                usage();
                process::exit(1);
            }
            let source = read_source(&args[2]);
            run_parse(&source);
        }
        "lex" => {
            if args.len() < 3 {
                usage();
                process::exit(1);
            }
            let source = read_source(&args[2]);
            run_lex(&source);
        }
        "emit-c" => {
            if args.len() < 3 {
                usage();
                process::exit(1);
            }
            let source = read_source(&args[2]);
            run_emit_c(&source);
        }
        "emit-ffi" => {
            if args.len() < 3 {
                usage();
                process::exit(1);
            }
            let source = read_source(&args[2]);
            run_emit_ffi(&source);
        }
        "check" => {
            if args.len() < 3 {
                usage();
                process::exit(1);
            }
            let source = read_source(&args[2]);
            run_check(&source, &args[2]);
        }
        "help" | "--help" | "-h" => {
            usage();
        }
        _ => {
            usage();
            process::exit(1);
        }
    }
}

fn usage() {
    eprintln!("glue-rs — Glue 语言 Rust 实现");
    eprintln!();
    eprintln!("用法:");
    eprintln!("  glue parse <file>    解析 .glue 文件并打印 AST");
    eprintln!("  glue parse -         从 stdin 读取源码并解析");
    eprintln!("  glue lex <file>      仅词法分析，打印 Token 列表");
    eprintln!("  glue emit-c <file>   提取 @extern(\"C\") 函数，生成 .c 文件");
    eprintln!("  glue emit-ffi <file> 生成 Rust FFI 绑定 + wrapper 代码");
    eprintln!("  glue check <file>    类型检查（加载 builtin + 传递依赖后 sema）");
    eprintln!("  glue help            显示帮助");
}

fn read_source(path: &str) -> String {
    if path == "-" {
        let mut buf = String::new();
        if io::stdin().read_to_string(&mut buf).is_err() {
            eprintln!("Error reading from stdin");
            process::exit(1);
        }
        buf
    } else {
        match fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Error reading {}: {}", path, e);
                process::exit(1);
            }
        }
    }
}

fn run_parse(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = Parser::new(tokens_ref, &arena, ErrorCollector::new());

    let module_name = "stdin";
    match parser.parse_module(module_name) {
        Ok(module) => {
            let mut printer = Printer::new(&module.arena);
            let output = printer.print_module(&module);
            print!("{}", output);
        }
        Err(err) => {
            eprintln!("Parse error at {}:{}: {}", err.line, err.column, err.message);
            process::exit(1);
        }
    }

    // 打印累积的语法错误（非致命）
    for err in parser.errors() {
        eprintln!("Warning: parse error at {}:{}: {}", err.line, err.column, err.message);
    }
}

fn run_lex(source: &str) {
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens = sink.into_tokens();
    for tok in &tokens {
        println!(
            "{:>4}:{:<3} {:<20} {}",
            tok.line,
            tok.column,
            format!("{:?}", tok.kind),
            tok.lexeme
        );
    }
}

fn run_emit_c(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = Parser::new(tokens_ref, &arena, ErrorCollector::new());

    match parser.parse_module("stdin") {
        Ok(module) => {
            // [A-2] 有非致命解析错误时 AST 可能残缺，不应继续生成代码（避免下游索引 panic）
            if !parser.errors().is_empty() {
                for err in parser.errors() {
                    eprintln!("Error: parse error at {}:{}: {}", err.line, err.column, err.message);
                }
                process::exit(1);
            }
            match glue_rs::ExternC::extract_c_from_module(&module) {
                Ok(c_code) => print!("{}", c_code),
                Err(e) => {
                    eprintln!("Error extracting C: {}", e);
                    process::exit(1);
                }
            }
        }
        Err(err) => {
            eprintln!("Parse error at {}:{}: {}", err.line, err.column, err.message);
            process::exit(1);
        }
    }
}

fn run_emit_ffi(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = Parser::new(tokens_ref, &arena, ErrorCollector::new());

    match parser.parse_module("stdin") {
        Ok(module) => {
            // [A-2] 有非致命解析错误时 AST 可能残缺，不应继续生成代码（避免下游索引 panic）
            if !parser.errors().is_empty() {
                for err in parser.errors() {
                    eprintln!("Error: parse error at {}:{}: {}", err.line, err.column, err.message);
                }
                process::exit(1);
            }
            match glue_rs::ExternC::extract_rust_ffi_from_module(&module) {
                Ok(ffi_code) => print!("{}", ffi_code),
                Err(e) => {
                    eprintln!("Error generating FFI: {}", e);
                    process::exit(1);
                }
            }
        }
        Err(err) => {
            eprintln!("Parse error at {}:{}: {}", err.line, err.column, err.message);
            process::exit(1);
        }
    }
}

fn run_check(source: &str, filename: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = Parser::new(tokens_ref, &arena, ErrorCollector::new());

    let entry_module = match parser.parse_module(filename) {
        Ok(m) => m,
        Err(err) => {
            eprintln!("{}:{}:{}: parse error: {}", filename, err.line, err.column, err.message);
            process::exit(1);
        }
    };
    for err in parser.errors() {
        eprintln!("Warning: {}:{}:{}: {}", filename, err.line, err.column, err.message);
    }

    // 模块加载：builtin 已在 new() 预加载，递归加载 entry_module 的传递依赖
    let mut loader = ModuleLoader::new();
    let dep_keys = loader.load_transitive_imports(&entry_module);

    // 预加载所有 std 模块（同包符号互相可见：如 Instant.glue 引用 Duration 构造器）
    let std_keys: Vec<String> = glue_rs::ModuleLoader::STD_FILES
        .iter()
        .map(|(p, _)| p.to_string())
        .collect();
    for key in &std_keys {
        let parts: Vec<&str> = key.strip_suffix(".glue").unwrap().split('/').collect();
        let _ = loader.resolve_and_load(&parts);
    }

    // 报告模块加载失败（模块未找到 / 解析失败），避免 sema 级联误报掩盖根因
    if loader.has_load_errors() {
        for err in loader.load_errors() {
            match err {
                glue_rs::ModuleLoader::LoadError::ModuleNotFound { path } => {
                    eprintln!("error: module not found: {}", path);
                }
                glue_rs::ModuleLoader::LoadError::ParseFailed {
                    path,
                    line,
                    column,
                    message,
                } => {
                    eprintln!("error: parse failed in {} at {}:{}: {}", path, line, column, message);
                }
            }
        }
        process::exit(1);
    }

    // Sema check：共享 root_env，builtin → std（按依赖顺序）→ 依赖 → entry
    let mut type_arena = TypeArena::new();
    let mut sema_result = SemaResult::new();
    let mut ctx = InferContext::new(&mut type_arena, &mut sema_result);

    // 创建共享 root_env，注册 builtins（所有模块共用）
    ctx.reset_state();
    let root_env: EnvId = ctx.env.root();
    ctx.register_builtins(root_env);

    // 注册所有已加载模块的短名别名（同包模块符号可见性）
    // 将文件路径 key（如 "std/io/File.glue"）转为逻辑路径（如 "std.io.File"）
    let module_logical_paths: Vec<String> = loader
        .loaded_keys()
        .iter()
        .filter_map(|k| {
            k.strip_suffix(".glue")
                .map(|s| s.replace('/', "."))
        })
        .collect();
    ctx.register_module_aliases(root_env, &module_logical_paths);

    let mut prev_err_len = 0usize;

    // 1. builtin 模块（按 BUILTIN_FILES 顺序，含 syscall 原语）
    for (path, m) in loader.builtin_modules() {
        ctx.check_module_with_env(m, root_env);
        for err in &ctx.sema_result.errors[prev_err_len..] {
            eprintln!("{}:{}:{}: {}", path, err.line, err.column, err.message);
        }
        prev_err_len = ctx.sema_result.errors.len();
    }

    // 2. 所有 std 模块（按 STD_FILES 顺序，同包符号互相可见）
    for key in &std_keys {
        if let Some(m) = loader.get_module_by_key(key) {
            ctx.check_module_with_env(m, root_env);
            for err in &ctx.sema_result.errors[prev_err_len..] {
                eprintln!("{}:{}:{}: {}", key, err.line, err.column, err.message);
            }
            prev_err_len = ctx.sema_result.errors.len();
        }
    }

    // 3. 依赖模块（按后序，被依赖在前）
    for k in &dep_keys {
        if let Some(m) = loader.get_module_by_key(k) {
            ctx.check_module_with_env(m, root_env);
            for err in &ctx.sema_result.errors[prev_err_len..] {
                eprintln!("{}:{}:{}: {}", k, err.line, err.column, err.message);
            }
            prev_err_len = ctx.sema_result.errors.len();
        }
    }

    // 4. entry 模块
    ctx.check_module_with_env(&entry_module, root_env);
    for err in &ctx.sema_result.errors[prev_err_len..] {
        eprintln!("{}:{}:{}: {}", filename, err.line, err.column, err.message);
    }

    if ctx.sema_result.errors.is_empty() {
        println!("ok: {} (no type errors)", filename);
    } else {
        process::exit(1);
    }
}
