//! glue-rs CLI — 对齐 Zig 版本的 project-based 子命令集
//!
//! 子命令：
//!   glue init [name]               脚手架化新项目（创建 glue.toml + src/Main.glue）
//!   glue run [file] [--workers N]  构建并运行 Glue 程序
//!   glue debug [file] [--stage S]   诊断模式（默认完整 pipeline，--stage 指定阶段）
//!
//! run/debug 不带 file 时，从当前目录向上查找 glue.toml
//! 定位项目根，读取 manifest 的 entry 字段作为入口文件。
//! 无 manifest 时报错退出。

use std::fs;
use std::io::{self, Read};
use std::process;

use clap::{Parser, Subcommand};

use glue_rs::Ast::{ErrorCollector, Lexer, Parser as GlueParser, Printer, Token, TokenCollector};
use glue_rs::Engine::Engine;
use glue_rs::Analyzer;
use glue_rs::Ir::IrBuilder;
use glue_rs::ModuleLoader::ModuleLoader;
use glue_rs::Sema::{InferContext, SemaResult, TypeArena};

/// Glue 语言 Rust 实现 CLI
#[derive(Parser)]
#[command(name = "glue", version, about = "Glue language Rust implementation")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// 脚手架化新项目
    Init {
        /// 项目名称（在 ./name 目录创建，省略则在当前目录）
        name: Option<String>,
    },
    /// 构建并运行 Glue 程序
    Run {
        /// 入口文件（默认 src/Main.glue）
        file: Option<String>,
        /// worker 线程数（默认 1，即单线程模式）
        #[arg(long)]
        workers: Option<usize>,
    },
    /// 诊断模式（默认完整 pipeline，--stage 指定到某阶段停止并输出）
    Debug {
        /// 入口文件（默认 src/Main.glue，`-` 表示 stdin）
        file: Option<String>,
        /// 诊断阶段：tokens（仅词法）、ast（解析后打印 AST）、
        /// check（仅类型检查）、emit-c（提取 C 代码）、emit-ffi（生成 FFI 绑定）、
        /// full（默认，完整 pipeline + 执行统计）
        #[arg(long)]
        stage: Option<DebugStage>,
    },
}

/// debug 子命令的阶段选项
#[derive(Clone, Debug, clap::ValueEnum)]
enum DebugStage {
    /// 仅词法分析，打印 Token 列表
    Tokens,
    /// 解析后打印 AST（S-表达式）
    Ast,
    /// 仅类型检查
    Check,
    /// 提取 @extern("C") 函数生成 .c 到 stdout
    EmitC,
    /// 生成 Rust FFI 绑定 + wrapper 到 stdout
    EmitFfi,
    /// 完整 pipeline + 执行统计（默认）
    Full,
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Init { name } => cmd_init(name),
        Commands::Run { file, workers } => cmd_run(file, workers, false),
        Commands::Debug { file, stage } => cmd_debug(file, stage),
    }
}

// ==================== 项目清单 ====================

/// 项目清单文件名
const MANIFEST_NAME: &str = "glue.toml";
/// 默认入口文件
const DEFAULT_ENTRY: &str = "src/Main.glue";

/// 项目清单：名称、版本与入口文件路径
#[allow(dead_code)]
struct Manifest {
    name: String,
    version: String,
    entry: String,
}

/// 从当前目录向上逐级查找包含清单文件的目录，返回项目根目录路径
/// （对齐 Zig findProjectRoot，最多向上 64 级）
fn find_project_root() -> Option<String> {
    let mut current = std::env::current_dir().ok()?;
    for _ in 0..64 {
        let manifest_path = current.join(MANIFEST_NAME);
        if manifest_path.exists() {
            return Some(current.to_string_lossy().into_owned());
        }
        if !current.pop() {
            break;
        }
    }
    None
}

/// 解析清单文件内容（简化的 key = value 格式），返回 Manifest
/// （对齐 Zig parseManifest）
fn parse_manifest(source: &str) -> Manifest {
    let mut name = "app".to_string();
    let mut version = "0.0.0".to_string();
    let mut entry = DEFAULT_ENTRY.to_string();

    for raw_line in source.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some(eq) = line.find('=') else { continue };
        let key = line[..eq].trim();
        let mut val = line[eq + 1..].trim();
        // 去除引号
        if val.len() >= 2 && val.starts_with('"') && val.ends_with('"') {
            val = &val[1..val.len() - 1];
        }
        match key {
            "name" => name = val.to_string(),
            "version" => version = val.to_string(),
            "entry" => {
                if !val.is_empty() {
                    entry = val.to_string();
                }
            }
            _ => {}
        }
    }
    Manifest { name, version, entry }
}

/// 加载项目清单：向上查找项目根，读取并解析 glue.toml
/// 无 manifest 时报错退出（project-based，对齐 Zig）
fn load_manifest() -> (String, Manifest) {
    let root = find_project_root().unwrap_or_else(|| {
        eprintln!("error: not a Glue project (no {} found in current or parent directories)", MANIFEST_NAME);
        eprintln!("  hint: run `glue init` to scaffold a new project");
        process::exit(1);
    });
    let manifest_path = std::path::Path::new(&root).join(MANIFEST_NAME);
    let content = fs::read_to_string(&manifest_path).unwrap_or_else(|e| {
        eprintln!("error: could not read {}: {}", manifest_path.display(), e);
        process::exit(1);
    });
    let manifest = parse_manifest(&content);
    (root, manifest)
}

/// 解析入口文件路径：project-based 模式从 manifest 读 entry，非 project 模式用默认值
/// file 参数优先级最高（显式指定）
fn resolve_entry_path(file: Option<String>) -> String {
    match file {
        Some(f) => f,
        None => {
            let (root, manifest) = load_manifest();
            // entry 路径相对于项目根
            let entry = if std::path::Path::new(&manifest.entry).is_absolute() {
                manifest.entry
            } else {
                format!("{}/{}", root, manifest.entry)
            };
            entry
        }
    }
}

// ==================== init 子命令 ====================

fn cmd_init(name: Option<String>) {
    let proj_name = name.as_deref().unwrap_or("app");
    let target_dir = name.as_deref().unwrap_or("");

    // 检查目标目录状态
    if !target_dir.is_empty() {
        match fs::metadata(target_dir) {
            Ok(_) => {
                let manifest_path = format!("{}/{}", target_dir, MANIFEST_NAME);
                if fs::metadata(&manifest_path).is_ok() {
                    eprintln!("error: already a Glue project ({} contains {})", target_dir, MANIFEST_NAME);
                    process::exit(1);
                }
                if let Ok(entries) = fs::read_dir(target_dir) {
                    if entries.count() > 0 {
                        eprintln!("error: {} is not an empty directory", target_dir);
                        process::exit(1);
                    }
                }
            }
            Err(_) => {
                if let Err(e) = fs::create_dir_all(target_dir) {
                    eprintln!("error: could not create directory '{}': {}", target_dir, e);
                    process::exit(1);
                }
            }
        }
    }

    let manifest_path = if target_dir.is_empty() {
        MANIFEST_NAME.to_string()
    } else {
        format!("{}/{}", target_dir, MANIFEST_NAME)
    };
    let src_dir = if target_dir.is_empty() {
        "src".to_string()
    } else {
        format!("{}/src", target_dir)
    };

    if let Err(e) = fs::create_dir_all(&src_dir) {
        eprintln!("error: could not create directory '{}': {}", src_dir, e);
        process::exit(1);
    }

    let manifest_content = format!(
        "name = \"{}\"\nversion = \"0.1.0\"\nentry = \"{}\"\n",
        proj_name, DEFAULT_ENTRY
    );
    if let Err(e) = fs::write(&manifest_path, manifest_content) {
        eprintln!("error: could not write '{}': {}", manifest_path, e);
        process::exit(1);
    }

    let main_path = if target_dir.is_empty() {
        DEFAULT_ENTRY.to_string()
    } else {
        format!("{}/{}", target_dir, DEFAULT_ENTRY)
    };
    // Console 在 builtin/io 下，默认可见无需 import
    let main_content = "fun main(): void {\n    println(\"Hello, Glue!\")\n}\n";
    if let Err(e) = fs::write(&main_path, main_content) {
        eprintln!("error: could not write '{}': {}", main_path, e);
        process::exit(1);
    }

    println!("Created Glue project '{}'", proj_name);
    println!("  {}", manifest_path);
    println!("  {}", main_path);
}

// ==================== debug 子命令 ====================

fn cmd_debug(file: Option<String>, stage: Option<DebugStage>) {
    let stage = stage.unwrap_or(DebugStage::Full);
    let entry_path = resolve_entry_path(file);
    let source = read_source(&entry_path);

    match stage {
        DebugStage::Tokens => debug_tokens(&source),
        DebugStage::Ast => debug_ast(&source),
        DebugStage::EmitC => debug_emit_c(&source),
        DebugStage::EmitFfi => debug_emit_ffi(&source),
        DebugStage::Check => debug_check(&source, &entry_path),
        DebugStage::Full => cmd_run(Some(entry_path), None, true),
    }
}

/// 仅词法分析，打印 Token 列表
fn debug_tokens(source: &str) {
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

/// 解析并打印 AST（S-表达式）
fn debug_ast(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = GlueParser::new(tokens_ref, &arena, ErrorCollector::new());

    match parser.parse_module("stdin") {
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
    for err in parser.errors() {
        eprintln!("Warning: parse error at {}:{}: {}", err.line, err.column, err.message);
    }
}

/// 提取 @extern("C") 函数生成 .c 到 stdout
fn debug_emit_c(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = GlueParser::new(tokens_ref, &arena, ErrorCollector::new());

    match parser.parse_module("stdin") {
        Ok(module) => {
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

/// 生成 Rust FFI 绑定 + wrapper 到 stdout
fn debug_emit_ffi(source: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = GlueParser::new(tokens_ref, &arena, ErrorCollector::new());

    match parser.parse_module("stdin") {
        Ok(module) => {
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

/// 仅类型检查
fn debug_check(source: &str, filename: &str) {
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = GlueParser::new(tokens_ref, &arena, ErrorCollector::new());

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

    let mut loader = ModuleLoader::new();
    let dep_keys = loader.load_transitive_imports(&entry_module);

    let std_keys: Vec<String> = glue_rs::ModuleLoader::STD_FILES
        .iter()
        .map(|(p, _)| p.to_string())
        .collect();
    for key in &std_keys {
        let parts: Vec<&str> = key.strip_suffix(".glue").unwrap().split('/').collect();
        let _ = loader.resolve_and_load(&parts);
    }

    if loader.has_load_errors() {
        for err in loader.load_errors() {
            match err {
                glue_rs::ModuleLoader::LoadError::ModuleNotFound { path } => {
                    eprintln!("error: module not found: {}", path);
                }
                glue_rs::ModuleLoader::LoadError::ParseFailed { path, line, column, message } => {
                    eprintln!("error: parse failed in {} at {}:{}: {}", path, line, column, message);
                }
                glue_rs::ModuleLoader::LoadError::CircularImport { path } => {
                    eprintln!("error: circular import detected: {}", path);
                }
            }
        }
        process::exit(1);
    }

    let mut type_arena = TypeArena::new();
    let mut sema_result = SemaResult::new();
    let mut ctx = InferContext::new(&mut type_arena, &mut sema_result);

    ctx.reset_state();
    let root_env = ctx.env.root();
    ctx.register_builtins(root_env);

    let module_logical_paths: Vec<String> = loader
        .loaded_keys()
        .iter()
        .filter_map(|k| k.strip_suffix(".glue").map(|s| s.replace('/', ".")))
        .collect();
    ctx.register_module_aliases(root_env, &module_logical_paths);

    // 预扫描：先 predeclare 所有模块的函数和类型构造器到 root_env，
    // 解决模块间前向引用问题（如 SystemTime.glue 引用 Calendar.glue 的函数，
    // 但 Calendar 在 STD_FILES 中位于 SystemTime 之后）。
    // check_module_with_env 内部会再次 predeclare 当前模块（幂等，重复注册无害）。
    for (_, m) in loader.builtin_modules() {
        ctx.predeclare_declarations(m, root_env);
    }
    for key in &std_keys {
        if let Some(m) = loader.get_module_by_key(key) {
            ctx.predeclare_declarations(m, root_env);
        }
    }
    for k in &dep_keys {
        if let Some(m) = loader.get_module_by_key(k) {
            ctx.predeclare_declarations(m, root_env);
        }
    }

    let mut prev_err_len = 0usize;

    for (path, m) in loader.builtin_modules() {
        ctx.check_module_with_env(m, root_env);
        for err in &ctx.sema_result.errors[prev_err_len..] {
            eprintln!("{}:{}:{}: {}", path, err.line, err.column, err.message);
        }
        prev_err_len = ctx.sema_result.errors.len();
    }

    for key in &std_keys {
        if let Some(m) = loader.get_module_by_key(key) {
            ctx.check_module_with_env(m, root_env);
            for err in &ctx.sema_result.errors[prev_err_len..] {
                eprintln!("{}:{}:{}: {}", key, err.line, err.column, err.message);
            }
            prev_err_len = ctx.sema_result.errors.len();
        }
    }

    for k in &dep_keys {
        if let Some(m) = loader.get_module_by_key(k) {
            ctx.check_module_with_env(m, root_env);
            for err in &ctx.sema_result.errors[prev_err_len..] {
                eprintln!("{}:{}:{}: {}", k, err.line, err.column, err.message);
            }
            prev_err_len = ctx.sema_result.errors.len();
        }
    }

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

// ==================== run 子命令（debug full 也复用） ====================

fn cmd_run(file: Option<String>, workers: Option<usize>, debug: bool) {
    let entry_path = resolve_entry_path(file);
    let source = read_source(&entry_path);

    if debug {
        eprintln!("=== Glue Debug Mode ===");
        eprintln!("[1/5] Parsing {} ...", entry_path);
    }

    // 1. Parse
    let arena = bumpalo::Bump::new();
    let mut lexer = Lexer::new(&source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token<'_>> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);
    let mut parser = GlueParser::new(tokens_ref, &arena, ErrorCollector::new());

    let entry_module = match parser.parse_module(&entry_path) {
        Ok(m) => m,
        Err(err) => {
            eprintln!("{}:{}:{}: parse error: {}", entry_path, err.line, err.column, err.message);
            process::exit(1);
        }
    };
    for err in parser.errors() {
        eprintln!("Warning: {}:{}:{}: {}", entry_path, err.line, err.column, err.message);
    }

    if debug {
        eprintln!("  AST: {} declarations", entry_module.declarations.len());
        eprintln!("[2/5] Loading modules ...");
    }

    // 2. 模块加载
    let mut loader = ModuleLoader::new();
    // 添加入口文件所在目录为搜索路径，用于解析用户模块（如 Math/Geometry.glue）
    if let Some(src_dir) = std::path::Path::new(&entry_path).parent() {
        loader.add_search_path(src_dir);
    }
    let dep_keys = loader.load_transitive_imports(&entry_module);

    // 预加载所有 std 模块
    let std_keys: Vec<String> = glue_rs::ModuleLoader::STD_FILES
        .iter()
        .map(|(p, _)| p.to_string())
        .collect();
    for key in &std_keys {
        let parts: Vec<&str> = key.strip_suffix(".glue").unwrap().split('/').collect();
        let _ = loader.resolve_and_load(&parts);
    }

    if loader.has_load_errors() {
        for err in loader.load_errors() {
            match err {
                glue_rs::ModuleLoader::LoadError::ModuleNotFound { path } => {
                    eprintln!("error: module not found: {}", path);
                }
                glue_rs::ModuleLoader::LoadError::ParseFailed { path, line, column, message } => {
                    eprintln!("error: parse failed in {} at {}:{}: {}", path, line, column, message);
                }
                glue_rs::ModuleLoader::LoadError::CircularImport { path } => {
                    eprintln!("error: circular import detected: {}", path);
                }
            }
        }
        process::exit(1);
    }

    if debug {
        let builtin_count = loader.builtin_modules().count();
        eprintln!("  Loaded: {} builtin + {} std + {} deps", 
            builtin_count, std_keys.len(), dep_keys.len());
        eprintln!("[3/5] Type checking ...");
    }

    // 3. Sema check
    let mut type_arena = TypeArena::new();
    let mut sema_result = SemaResult::new();
    let mut ctx = InferContext::new(&mut type_arena, &mut sema_result);

    ctx.reset_state();
    let root_env = ctx.env.root();
    ctx.register_builtins(root_env);

    let module_logical_paths: Vec<String> = loader
        .loaded_keys()
        .iter()
        .filter_map(|k| k.strip_suffix(".glue").map(|s| s.replace('/', ".")))
        .collect();
    ctx.register_module_aliases(root_env, &module_logical_paths);

    let mut prev_err_len = 0usize;

    // builtin → std → 依赖 → entry
    for (_path, m) in loader.builtin_modules() {
        ctx.check_module_with_env(m, root_env);
        prev_err_len = ctx.sema_result.errors.len();
    }
    for key in &std_keys {
        if let Some(m) = loader.get_module_by_key(key) {
            ctx.check_module_with_env(m, root_env);
            prev_err_len = ctx.sema_result.errors.len();
        }
    }
    for k in &dep_keys {
        if let Some(m) = loader.get_module_by_key(k) {
            ctx.check_module_with_env(m, root_env);
            prev_err_len = ctx.sema_result.errors.len();
        }
    }
    ctx.check_module_with_env(&entry_module, root_env);

    if ctx.sema_result.errors.len() > prev_err_len {
        for err in &ctx.sema_result.errors[prev_err_len..] {
            eprintln!("{}:{}:{}: {}", entry_path, err.line, err.column, err.message);
        }
        process::exit(1);
    }

    if debug {
        eprintln!("  Sema: OK (no type errors)");
        eprintln!("[4/5] Compiling IR ...");
    }

    // 4. 静态分析（Sema 后、IR 前）：死代码/死变量/死函数 + 记忆化策略
    //    对 entry 模块运行分析；debug 模式下打印报告摘要。
    let analysis_report = Analyzer::analyze(&entry_module, &entry_module.arena, &sema_result);
    if debug {
        eprintln!("  Analyzer: dead_code={} dead_var={} dead_func={} memo_candidates={} dead_param={} inline={} stack_alloc={} non_exhaustive={} unreachable_arms={}",
            analysis_report.dead_code.dead_stmts.len(),
            analysis_report.dead_var.dead_vars.len(),
            analysis_report.dead_func.dead.len(),
            analysis_report.memo.candidates.len(),
            analysis_report.dead_param.dead_params.len(),
            analysis_report.inline.candidates.len(),
            analysis_report.stack_alloc.candidates.len(),
            analysis_report.match_report.non_exhaustive.len(),
            analysis_report.match_report.unreachable_arms.len());
    }

    // 5. IR 编译
    // 收集所有非 entry 模块（builtin + std + dep），传给 IR builder 编译为子图
    let mut non_entry_modules: Vec<&_> = loader.builtin_modules().map(|(_, m)| m).collect();
    for key in &std_keys {
        if let Some(m) = loader.get_module_by_key(key) {
            non_entry_modules.push(m);
        }
    }
    for k in &dep_keys {
        if let Some(m) = loader.get_module_by_key(k) {
            non_entry_modules.push(m);
        }
    }
    let mut graph = IrBuilder::new(&sema_result, &entry_module)
        .with_builtins(non_entry_modules)
        .with_analysis(&analysis_report)
        .build();

    // 检查 IR 编译错误（未实现的特性降级、找不到函数等）
    if !graph.ir_errors.is_empty() {
        for err in &graph.ir_errors {
            eprintln!("{}: IR error: {}", entry_path, err);
        }
        process::exit(1);
    }

    // 检查入口子图：无 main 函数时优雅报错，避免 Engine panic
    if graph.entry_subgraph.is_none() {
        eprintln!("error: no entry point found in {} (expected a `main` function)", entry_path);
        process::exit(1);
    }

    if debug {
        eprintln!("  IR (before opt): {} nodes, {} subgraphs, {} compute_fns",
            graph.nodes.len(), graph.subgraphs.len(), graph.compute_fns.len());
    }

    // IR 后优化：ConstFold/CSE/CopyProp/DCE 固定点迭代
    if std::env::var("GLUE_NO_OPT").is_err() {
        glue_rs::Optimizer::optimize(&mut graph);
    }

    if debug {
        eprintln!("  IR (after opt):  {} nodes, {} subgraphs, {} compute_fns",
            graph.nodes.len(), graph.subgraphs.len(), graph.compute_fns.len());
        if let Some(entry) = graph.entry_subgraph {
            eprintln!("  Entry subgraph: {:?}", entry);
        }
        eprintln!("[5/5] Executing ...");
    }

    // 5. Engine 执行
    let mut engine = Engine::new(graph);
    let result = match workers {
        Some(n) if n > 1 => {
            if debug {
                eprintln!("  Mode: multi-worker ({} workers)", n);
            }
            engine.run_multi_worker(n)
        }
        _ => {
            if debug {
                eprintln!("  Mode: single-thread");
            }
            engine.run_entry()
        }
    };

    if debug {
        eprintln!("  Result: {:?}", result);
        eprintln!("=== Done ===");
    }
}

// ==================== 公共工具 ====================

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
