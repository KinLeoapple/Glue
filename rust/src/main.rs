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

    for err in parser.errors() {
        eprintln!("Warning: parse error at {}:{}: {}", err.line, err.column, err.message);
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

    for err in parser.errors() {
        eprintln!("Warning: parse error at {}:{}: {}", err.line, err.column, err.message);
    }
}
