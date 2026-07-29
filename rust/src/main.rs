//! glue-rs 端到端 CLI
//!
//! 用法：
//!   glue parse <file>      解析 .glue 文件并打印 AST（规范 S-表达式）
//!   glue lex <file>        仅词法分析，打印 Token 列表
//!   glue parse -           从 stdin 读取源码并解析

use std::env;
use std::fs;
use std::io::{self, Read};
use std::process;

use glue_rs::Ast::{Lexer, Parser, Printer};

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
    let tokens = lexer.tokenize();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = Parser::new(tokens_ref, &arena);

    let module_name = "stdin";
    match parser.parse_module(module_name) {
        Ok(module) => {
            let mut printer = Printer::new();
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
    let tokens = lexer.tokenize();
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

// 引入 print_module 以避免 unused import 警告
// (已在上方直接使用 Printer)
