//! ModuleLoader — 统一的模块加载器
//!
//! 合并 stdlib 和用户模块的加载逻辑：
//! - builtin 模块在初始化时全量预加载（默认可见，无需 import）
//! - std/user 模块按需通过 resolve_and_load 加载（遇到 ImportDecl 时触发）
//! - 模块缓存避免重复 parse/check
//!
//! ## 生命周期策略
//!
//! stdlib 源码是 `&'static str`（include_str!），用户模块源码通过 `Box::leak`
//! 转为 `&'static str`。Bump arena 同样通过 `Box::leak` 变为 `&'static`，
//! 因此所有 parse 产出的 `Module<'static>` 可安全缓存。
//! 编译器进程退出时由 OS 回收内存，无泄漏风险。
//!
//! ## 模块路径约定
//!
//! `import std.io.File` → module_path = ["std", "io", "File"]
//! → 解析为文件路径 "std/io/File.glue"
//! → 先查 stdlib 嵌入表，再查文件系统搜索路径

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::Ast::{
    Decl, ErrorCollector, ImportItem, Lexer, Module, ParseError, Parser, Token, TokenCollector,
    Visibility,
};

// ─── 标准库源码嵌入 ──────────────────────────────────────────────────
// 使用 include_str! 在编译期将 .glue 源文件嵌入二进制，供 ModuleLoader parse。
// 等价于 Zig 侧的 src/builtin/embed.zig + src/std/embed.zig。
//
// 目录结构：
// rust/stdlib/
// ├── builtin/          # 内置模块（默认可见，无需 import）
// │   ├── {io,net,time}/Raw.glue  # @extern("C") 原语（按领域拆分）
// │   ├── error/        # Err/Error/CastError/IOError/TimeError
// │   ├── cast/         # Raw.glue(@extern 原语) + Cast.glue(glue wrapper)
// │   ├── reflect/      # 运行时反射格式化（Reflect.format）
// │   ├── io/           # Reader/Writer trait + Console(print/println/scan...)
// │   └── iter/         # Iterator<T> 迭代器
// └── std/              # 标准库（需 import std.xxx）
//     ├── io/           # File/Path/Buffered/Dir/Fs
//     ├── time/         # Duration/Instant/SystemTime/DateTime/Calendar/Timer
//     └── net/          # Addr/TcpListener/TcpStream/UdpSocket/Dns

/// 标准库文件条目：(相对路径, 源码内容)
pub type StdlibFile = (&'static str, &'static str);

/// builtin 模块文件清单（默认可见，无需 import）
///
/// 顺序按依赖关系排列：
///   Raw(@extern 原语) → error → cast(Raw+Cast) → reflect → io(Reader/Writer/Console) → net → time → iter
/// @extern("C") 原语最先加载：全局可见，供 builtin/std wrapper 调用
/// cast/Raw.glue 与 {io,net,time}/Raw.glue 一起在原语层加载
pub const BUILTIN_FILES: &[StdlibFile] = &[
    // @extern("C") 原语模块（全局可见，按领域拆分到 Raw.glue）
    ("builtin/io/Raw.glue", include_str!("../stdlib/builtin/io/Raw.glue")),
    ("builtin/net/Raw.glue", include_str!("../stdlib/builtin/net/Raw.glue")),
    ("builtin/time/Raw.glue", include_str!("../stdlib/builtin/time/Raw.glue")),
    // error 模块
    ("builtin/error/pack.glue", include_str!("../stdlib/builtin/error/pack.glue")),
    ("builtin/error/Err.glue", include_str!("../stdlib/builtin/error/Err.glue")),
    ("builtin/error/Error.glue", include_str!("../stdlib/builtin/error/Error.glue")),
    ("builtin/error/CastError.glue", include_str!("../stdlib/builtin/error/CastError.glue")),
    ("builtin/error/IOError.glue", include_str!("../stdlib/builtin/error/IOError.glue")),
    ("builtin/error/TimeError.glue", include_str!("../stdlib/builtin/error/TimeError.glue")),
    // cast 模块（类型转换原语 + glue wrapper）
    ("builtin/cast/pack.glue", include_str!("../stdlib/builtin/cast/pack.glue")),
    ("builtin/cast/Raw.glue", include_str!("../stdlib/builtin/cast/Raw.glue")),
    ("builtin/cast/Cast.glue", include_str!("../stdlib/builtin/cast/Cast.glue")),
    // reflect 模块（运行时反射，Raw.glue 原语 + Reflect.glue wrapper）
    ("builtin/reflect/pack.glue", include_str!("../stdlib/builtin/reflect/pack.glue")),
    ("builtin/reflect/Raw.glue", include_str!("../stdlib/builtin/reflect/Raw.glue")),
    ("builtin/reflect/Reflect.glue", include_str!("../stdlib/builtin/reflect/Reflect.glue")),
    // io 模块（Reader/Writer trait + Console 标准IO）
    ("builtin/io/pack.glue", include_str!("../stdlib/builtin/io/pack.glue")),
    ("builtin/io/Reader.glue", include_str!("../stdlib/builtin/io/Reader.glue")),
    ("builtin/io/Writer.glue", include_str!("../stdlib/builtin/io/Writer.glue")),
    ("builtin/io/Console.glue", include_str!("../stdlib/builtin/io/Console.glue")),
    // net 模块（pack 声明，Raw 已在原语层加载）
    ("builtin/net/pack.glue", include_str!("../stdlib/builtin/net/pack.glue")),
    // time 模块（pack 声明，Raw 已在原语层加载）
    ("builtin/time/pack.glue", include_str!("../stdlib/builtin/time/pack.glue")),
    // str 模块（UTF-8 解码原语，iter 模块依赖）
    ("builtin/str/pack.glue", include_str!("../stdlib/builtin/str/pack.glue")),
    ("builtin/str/Raw.glue", include_str!("../stdlib/builtin/str/Raw.glue")),
    // iter 模块
    ("builtin/iter/pack.glue", include_str!("../stdlib/builtin/iter/pack.glue")),
    ("builtin/iter/Iterator.glue", include_str!("../stdlib/builtin/iter/Iterator.glue")),
];

/// std 模块文件清单（需 import std.xxx 加载）
///
/// 顺序按依赖关系排列：io → time → net
/// reflect 已移至 builtin/reflect（默认可见），Console 已移至 builtin/io（默认可见）
pub const STD_FILES: &[StdlibFile] = &[
    // io 模块（Console 已移至 builtin/io）
    ("std/io/pack.glue", include_str!("../stdlib/std/io/pack.glue")),
    ("std/io/Path.glue", include_str!("../stdlib/std/io/Path.glue")),
    ("std/io/File.glue", include_str!("../stdlib/std/io/File.glue")),
    ("std/io/Buffered.glue", include_str!("../stdlib/std/io/Buffered.glue")),
    ("std/io/Dir.glue", include_str!("../stdlib/std/io/Dir.glue")),
    ("std/io/Fs.glue", include_str!("../stdlib/std/io/Fs.glue")),
    // time 模块
    ("std/time/pack.glue", include_str!("../stdlib/std/time/pack.glue")),
    ("std/time/Duration.glue", include_str!("../stdlib/std/time/Duration.glue")),
    ("std/time/Instant.glue", include_str!("../stdlib/std/time/Instant.glue")),
    ("std/time/SystemTime.glue", include_str!("../stdlib/std/time/SystemTime.glue")),
    ("std/time/DateTime.glue", include_str!("../stdlib/std/time/DateTime.glue")),
    ("std/time/Calendar.glue", include_str!("../stdlib/std/time/Calendar.glue")),
    ("std/time/Timer.glue", include_str!("../stdlib/std/time/Timer.glue")),
    // net 模块（TcpStream 在 TcpListener 之前：TcpListener 依赖 __net_tcp_close 定义于 TcpStream）
    ("std/net/pack.glue", include_str!("../stdlib/std/net/pack.glue")),
    ("std/net/Addr.glue", include_str!("../stdlib/std/net/Addr.glue")),
    ("std/net/Dns.glue", include_str!("../stdlib/std/net/Dns.glue")),
    ("std/net/TcpStream.glue", include_str!("../stdlib/std/net/TcpStream.glue")),
    ("std/net/TcpListener.glue", include_str!("../stdlib/std/net/TcpListener.glue")),
    ("std/net/UdpSocket.glue", include_str!("../stdlib/std/net/UdpSocket.glue")),
];

/// 按路径查找标准库文件
pub fn find(path: &str) -> Option<&'static str> {
    BUILTIN_FILES
        .iter()
        .chain(STD_FILES.iter())
        .find(|(p, _)| *p == path)
        .map(|(_, src)| *src)
}

/// 按模块名前缀查找（如 "std/io" 返回所有 std/io/*.glue）
pub fn find_by_prefix(prefix: &str) -> impl Iterator<Item = StdlibFile> + use<'_> {
    BUILTIN_FILES
        .iter()
        .chain(STD_FILES.iter())
        .copied()
        .filter(move |(p, _)| p.starts_with(prefix))
}

/// 已加载的模块条目
struct LoadedModule {
    /// parse 产出的 AST 模块（'static 生命周期，可安全缓存）
    module: Module<'static>,
    /// 模块导出的公开符号（pub fun / pub type / pub val 的名称）
    exports: HashSet<String>,
}

/// 模块加载失败的原因
///
/// 所有加载失败（模块未找到 / 解析失败）均结构化记录到 `ModuleLoader::load_errors`，
/// 由调用方统一报告，避免错误被静默吞掉后引发 sema 级联误报。
#[derive(Debug, Clone)]
pub enum LoadError {
    /// 模块路径未找到（stdlib 嵌入表和文件系统搜索路径均未命中）
    ModuleNotFound { path: String },
    /// 模块源码解析失败（致命 parse 错误，AST 不可用）
    ParseFailed {
        path: String,
        line: u32,
        column: u32,
        message: String,
    },
}

impl LoadError {
    /// 返回失败模块的路径
    pub fn path(&self) -> &str {
        match self {
            LoadError::ModuleNotFound { path } => path,
            LoadError::ParseFailed { path, .. } => path,
        }
    }
}

/// 统一的模块加载器
///
/// 合并 stdlib 嵌入表和文件系统两种 backend，对调用方透明。
/// builtin 模块在 `new()` 时全量预加载。
pub struct ModuleLoader {
    /// 模块缓存：相对路径（如 "std/io/File.glue"）→ LoadedModule
    modules: HashMap<String, LoadedModule>,
    /// 用户模块的文件系统搜索路径
    search_paths: Vec<PathBuf>,
    /// 加载失败记录（模块未找到 / 解析失败），按发生顺序排列
    load_errors: Vec<LoadError>,
    /// 已尝试加载但失败的路径集合，避免对同一路径重复记录错误
    failed_paths: HashSet<String>,
}

impl ModuleLoader {
    /// 创建新的加载器，并全量预加载 builtin 模块
    pub fn new() -> Self {
        let mut loader = Self {
            modules: HashMap::new(),
            search_paths: Vec::new(),
            load_errors: Vec::new(),
            failed_paths: HashSet::new(),
        };
        loader.preload_builtins();
        loader
    }

    /// 添加用户模块的文件系统搜索路径
    pub fn add_search_path(&mut self, path: impl Into<PathBuf>) {
        self.search_paths.push(path.into());
    }

    /// 预加载 builtin 模块（默认可见，无需 import）
    ///
    /// 遍历 BUILTIN_FILES，parse 每个 .glue 文件并缓存。
    /// builtin 模块按依赖顺序排列（error → io → iter），保证后续 check 时依赖已就绪。
    /// 解析失败时记录到 `load_errors`，避免错误被静默吞掉。
    fn preload_builtins(&mut self) {
        for (path, source) in BUILTIN_FILES {
            match parse_source(path, source) {
                Ok(module) => {
                    let exports = collect_exports(&module);
                    self.modules
                        .insert(path.to_string(), LoadedModule { module, exports });
                }
                Err(err) => {
                    self.failed_paths.insert(path.to_string());
                    self.load_errors.push(LoadError::ParseFailed {
                        path: path.to_string(),
                        line: err.line,
                        column: err.column,
                        message: err.message,
                    });
                }
            }
        }
    }

    /// 按模块路径段解析并加载模块
    ///
    /// `path = ["std", "io", "File"]` → 查找 "std/io/File.glue"
    /// 优先查缓存 → stdlib 嵌入表 → 文件系统搜索路径
    ///
    /// 返回已加载的 Module 引用。加载失败（模块未找到 / 解析失败）时返回 None，
    /// 失败原因结构化记录到 `load_errors`，由调用方通过 `load_errors()` 统一报告。
    pub fn resolve_and_load(&mut self, path: &[&str]) -> Option<&Module<'static>> {
        let path_str = module_path_to_file(path);

        // 1. 检查缓存（已成功加载）
        if self.modules.contains_key(&path_str) {
            return self.modules.get(&path_str).map(|m| &m.module);
        }

        // 2. 已知失败路径：不重复记录错误，直接返回 None
        if self.failed_paths.contains(&path_str) {
            return None;
        }

        // 3. 查找 stdlib 嵌入表
        if let Some(source) = find(&path_str) {
            let path_static: &'static str = Box::leak(path_str.clone().into_boxed_str());
            match parse_source(path_static, source) {
                Ok(module) => {
                    let exports = collect_exports(&module);
                    self.modules
                        .insert(path_str.clone(), LoadedModule { module, exports });
                    return self.modules.get(&path_str).map(|m| &m.module);
                }
                Err(err) => {
                    self.failed_paths.insert(path_str.clone());
                    self.load_errors.push(LoadError::ParseFailed {
                        path: path_str,
                        line: err.line,
                        column: err.column,
                        message: err.message,
                    });
                    return None;
                }
            }
        }

        // 4. 查找文件系统（用户模块）
        for base in &self.search_paths {
            let full = base.join(&path_str);
            if full.exists() {
                match std::fs::read_to_string(&full) {
                    Ok(source) => {
                        let source_static: &'static str =
                            Box::leak(source.into_boxed_str());
                        let path_static: &'static str =
                            Box::leak(path_str.clone().into_boxed_str());
                        match parse_source(path_static, source_static) {
                            Ok(module) => {
                                let exports = collect_exports(&module);
                                self.modules.insert(
                                    path_str.clone(),
                                    LoadedModule { module, exports },
                                );
                                return self.modules.get(&path_str).map(|m| &m.module);
                            }
                            Err(err) => {
                                self.failed_paths.insert(path_str.clone());
                                self.load_errors.push(LoadError::ParseFailed {
                                    path: path_str,
                                    line: err.line,
                                    column: err.column,
                                    message: err.message,
                                });
                                return None;
                            }
                        }
                    }
                    Err(_) => continue,
                }
            }
        }

        // 5. stdlib 和文件系统均未命中：记录模块未找到
        self.failed_paths.insert(path_str.clone());
        self.load_errors.push(LoadError::ModuleNotFound { path: path_str });
        None
    }

    /// 获取已加载模块的导出符号列表
    pub fn get_exports(&self, path: &[&str]) -> Option<&HashSet<String>> {
        let path_str = module_path_to_file(path);
        self.modules.get(&path_str).map(|m| &m.exports)
    }

    /// 获取已加载的 builtin 模块（按 BUILTIN_FILES 顺序）
    pub fn builtin_modules(&self) -> impl Iterator<Item = (&str, &Module<'static>)> {
        BUILTIN_FILES.iter().filter_map(|(path, _)| {
            self.modules.get(*path).map(|m| (*path, &m.module))
        })
    }

    /// 获取所有已加载模块的数量
    pub fn loaded_count(&self) -> usize {
        self.modules.len()
    }

    /// 判断模块是否已加载
    pub fn is_loaded(&self, path: &[&str]) -> bool {
        let path_str = module_path_to_file(path);
        self.modules.contains_key(&path_str)
    }

    /// 返回所有加载失败记录（模块未找到 / 解析失败），按发生顺序排列。
    ///
    /// 调用方应在 sema check 之前检查并报告这些错误，避免因模块缺失引发
    /// 大量级联类型误报，掩盖真正的根因。
    pub fn load_errors(&self) -> &[LoadError] {
        &self.load_errors
    }

    /// 是否存在加载失败
    pub fn has_load_errors(&self) -> bool {
        !self.load_errors.is_empty()
    }

    /// 递归加载 `module` 的所有传递依赖（import 的模块）。
    ///
    /// 后序遍历：被依赖的模块先出现在返回值中，保证调用方按返回顺序
    /// check 时，被依赖模块的定义已先 populate 到 SemaResult。
    /// builtin 模块已在 `new()` 中预加载，不包含在返回值中。
    ///
    /// 返回按 check 顺序排列的模块缓存 key（文件路径形式，如 `"std/io/File.glue"`）。
    pub fn load_transitive_imports(&mut self, module: &Module<'_>) -> Vec<String> {
        let mut order: Vec<String> = Vec::new();
        // visited：已 finalize 的模块（已登记到 order）
        let mut visited: HashSet<String> = HashSet::new();
        // visiting：当前栈中正在展开但未 finalize 的模块，用于检测循环依赖
        // 循环依赖（A↔B）下，第二次遇到 (A,false) 时 visiting.contains(A) 命中，
        // 直接跳过，避免无限展开。后序遍历对无环部分仍正确。
        let mut visiting: HashSet<String> = HashSet::new();
        // 栈元素：(模块路径段, 是否已展开收集子依赖)
        let mut stack: Vec<(Vec<String>, bool)> = collect_imports(module)
            .into_iter()
            .map(|(p, _)| (p.iter().map(|s| s.to_string()).collect::<Vec<String>>(), false))
            .collect();

        while let Some((path_segments, expanded)) = stack.pop() {
            let path_refs: Vec<&str> = path_segments.iter().map(|s| s.as_str()).collect();
            let key = module_path_to_file(&path_refs);
            if visited.contains(&key) {
                continue;
            }
            if !expanded {
                // 循环依赖检测：若 key 已在当前展开路径中，跳过避免无限循环
                if visiting.contains(&key) {
                    eprintln!("warning: circular import detected, skipping: {}", key);
                    continue;
                }
                visiting.insert(key.clone());
                // 首次访问：先收集子依赖路径（owned），再重新入栈自己
                let mut child_segs_list: Vec<Vec<String>> = Vec::new();
                if let Some(dep) = self.resolve_and_load(&path_refs) {
                    for (child_path, _) in collect_imports(dep) {
                        child_segs_list.push(
                            child_path.iter().map(|s| s.to_string()).collect::<Vec<String>>(),
                        );
                    }
                }
                // 自己重新入栈（标记 expanded），等子依赖处理完后再登记到 order
                stack.push((path_segments, true));
                // 子依赖入栈（LIFO 保证后序：子依赖先于自己登记到 order）
                for child_segs in child_segs_list {
                    stack.push((child_segs, false));
                }
            } else {
                visiting.remove(&key);
                visited.insert(key.clone());
                order.push(key);
            }
        }
        order
    }

    /// 按缓存 key 获取已加载模块（key 为 `module_path_to_file` 的返回值，如 `"std/io/File.glue"`）。
    pub fn get_module_by_key(&self, key: &str) -> Option<&Module<'static>> {
        self.modules.get(key).map(|m| &m.module)
    }

    /// 返回所有已加载模块的缓存 key（文件路径形式，如 `"std/io/File.glue"`）。
    pub fn loaded_keys(&self) -> Vec<String> {
        self.modules.keys().map(|s| s.to_string()).collect()
    }
}

impl Default for ModuleLoader {
    fn default() -> Self {
        Self::new()
    }
}

// ─── 辅助函数 ──────────────────────────────────────────────────────

/// 模块路径段 → 文件路径
/// `["std", "io", "File"]` → `"std/io/File.glue"`
fn module_path_to_file(path: &[&str]) -> String {
    let joined = path.join("/");
    if joined.ends_with(".glue") {
        joined
    } else {
        format!("{}.glue", joined)
    }
}

/// 解析源码为 Module<'static>
///
/// source 和 path 必须是 'static（stdlib 的 include_str! 或 Box::leak 的用户源码）。
/// arena 通过 Box::leak 变为 'static，确保 Module<'static> 可安全缓存。
///
/// 返回 `Result`：解析成功返回 Module，致命解析错误返回 `ParseError`。
/// 非致命解析错误（parser 已恢复）通过 stderr 输出为警告，不阻断加载。
fn parse_source(path: &'static str, source: &'static str) -> Result<Module<'static>, ParseError> {
    // Box::leak arena：编译器进程内长期存活，退出时由 OS 回收
    let arena: &'static bumpalo::Bump = Box::leak(Box::new(bumpalo::Bump::new()));

    let mut lexer = Lexer::new(source);
    let mut sink = TokenCollector::new();
    lexer.tokenize_into(&mut sink);
    let tokens: Vec<Token> = sink.into_tokens();
    let tokens_ref = arena.alloc_slice_copy(&tokens);

    let mut parser = Parser::new(tokens_ref, arena, ErrorCollector::new());

    match parser.parse_module(path) {
        Ok(module) => {
            // 非致命 parse 错误（parser 已恢复）：输出警告，模块仍可用
            for err in parser.errors() {
                eprintln!(
                    "Warning: parse error in {} at {}:{}: {}",
                    path, err.line, err.column, err.message
                );
            }
            Ok(module)
        }
        Err(err) => Err(err),
    }
}

/// 收集模块的公开导出符号
///
/// 遍历 Module.declarations，收集所有 pub 可见性的函数/类型名称。
/// 用于后续 import 别名注册。
fn collect_exports(module: &Module<'_>) -> HashSet<String> {
    let mut exports = HashSet::new();
    for decl in &module.declarations {
        match &decl.node {
            Decl::FunDecl {
                name,
                visibility: Visibility::Public,
                ..
            } => {
                exports.insert((*name).to_string());
            }
            Decl::TypeDecl {
                name,
                visibility: Visibility::Public,
                ..
            } => {
                exports.insert((*name).to_string());
            }
            _ => {}
        }
    }
    exports
}

// ─── ImportDecl 遍历辅助 ───────────────────────────────────────────

/// 遍历模块中的 ImportDecl，返回 (module_path, items) 列表
///
/// 用于编译入口在 check_module 前批量处理 import。
pub fn collect_imports<'a>(
    module: &'a Module<'a>,
) -> Vec<(Vec<&'a str>, Option<&'a [ImportItem<'a>]>)> {
    let mut imports = Vec::new();
    for decl in &module.declarations {
        if let Decl::ImportDecl {
            module_path,
            items,
            ..
        } = &decl.node
        {
            let items_ref = items.as_deref();
            imports.push((module_path.to_vec(), items_ref));
        }
    }
    imports
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_module_loader_new_preloads_builtins() {
        let loader = ModuleLoader::new();
        // builtin 有 11 个文件
        assert_eq!(loader.loaded_count(), BUILTIN_FILES.len());
    }

    #[test]
    fn test_builtin_modules_all_parsed() {
        let loader = ModuleLoader::new();
        // 所有 builtin 模块应成功 parse
        assert_eq!(loader.builtin_modules().count(), BUILTIN_FILES.len());
    }

    #[test]
    fn test_resolve_std_module() {
        let mut loader = ModuleLoader::new();
        // 加载 std/io/File.glue
        let module = loader.resolve_and_load(&["std", "io", "File"]);
        assert!(module.is_some(), "应能加载 std/io/File");
        // builtin(11) + File = 12
        assert_eq!(loader.loaded_count(), BUILTIN_FILES.len() + 1);
    }

    #[test]
    fn test_resolve_cached_no_reload() {
        let mut loader = ModuleLoader::new();
        // 第一次加载
        let _ = loader.resolve_and_load(&["std", "io", "File"]);
        let count_after_first = loader.loaded_count();
        // 第二次加载同一模块，不应增加计数
        let _ = loader.resolve_and_load(&["std", "io", "File"]);
        assert_eq!(loader.loaded_count(), count_after_first);
    }

    #[test]
    fn test_resolve_nonexistent() {
        let mut loader = ModuleLoader::new();
        let result = loader.resolve_and_load(&["nonexistent", "module"]);
        assert!(result.is_none(), "不存在的模块应返回 None");
        // 缺失模块应记录到 load_errors，而非静默跳过
        assert!(loader.has_load_errors(), "缺失模块应记录加载错误");
        let errors = loader.load_errors();
        assert_eq!(errors.len(), 1, "应有 1 条加载错误");
        match &errors[0] {
            LoadError::ModuleNotFound { path } => {
                assert!(path.contains("nonexistent"), "错误路径应包含 nonexistent");
            }
            other => panic!("期望 ModuleNotFound，实际: {:?}", other),
        }
        // 重复加载同一路径不应重复记录错误
        let _ = loader.resolve_and_load(&["nonexistent", "module"]);
        assert_eq!(loader.load_errors().len(), 1, "重复加载不应重复记录错误");
    }

    #[test]
    fn test_is_loaded() {
        let mut loader = ModuleLoader::new();
        // builtin 模块已预加载
        assert!(loader.is_loaded(&["builtin", "error", "Err"]));
        // std 模块尚未加载
        assert!(!loader.is_loaded(&["std", "io", "File"]));
        // 加载后
        let _ = loader.resolve_and_load(&["std", "io", "File"]);
        assert!(loader.is_loaded(&["std", "io", "File"]));
    }

    #[test]
    fn test_get_exports() {
        let mut loader = ModuleLoader::new();
        let _ = loader.resolve_and_load(&["std", "io", "File"]);
        let exports = loader.get_exports(&["std", "io", "File"]);
        assert!(exports.is_some());
        // File.glue 应导出 File 类型和相关函数
        let exports = exports.unwrap();
        assert!(exports.contains("File") || exports.contains("open"), "File.glue 应导出 File 或 open");
    }

    #[test]
    fn test_module_path_to_file() {
        assert_eq!(
            module_path_to_file(&["std", "io", "File"]),
            "std/io/File.glue"
        );
        assert_eq!(
            module_path_to_file(&["builtin", "error", "Err"]),
            "builtin/error/Err.glue"
        );
        // 已带 .glue 后缀的不重复添加
        assert_eq!(
            module_path_to_file(&["test.glue"]),
            "test.glue"
        );
    }

    #[test]
    fn test_collect_exports_from_builtin() {
        let mut loader = ModuleLoader::new();
        // std/io/File.glue 应导出 pub fun/ pub type
        let _ = loader.resolve_and_load(&["std", "io", "File"]);
        let exports = loader.get_exports(&["std", "io", "File"]);
        assert!(exports.is_some());
        let exports = exports.unwrap();
        // File.glue 有 pub fun open / pub type File 等
        assert!(!exports.is_empty(), "File.glue 应有 pub 导出符号");
    }

    #[test]
    fn test_collect_imports() {
        let mut loader = ModuleLoader::new();
        // 加载 std/io/File.glue，它应该有 import 声明
        let module = loader.resolve_and_load(&["std", "io", "File"]);
        assert!(module.is_some());
        let module = module.unwrap();
        let imports = collect_imports(module);
        // File.glue 可能有也可能没有 import，但函数不应 panic
        println!("File.glue imports: {:?}", imports.len());
    }

    #[test]
    fn test_all_stdlib_files_parseable() {
        // 验证所有 stdlib 文件都能被 ModuleLoader 正确 parse
        let mut loader = ModuleLoader::new();
        for (path, _) in STD_FILES {
            let parts: Vec<&str> = path.strip_suffix(".glue").unwrap().split('/').collect();
            let result = loader.resolve_and_load(&parts);
            assert!(result.is_some(), "无法 parse stdlib 文件: {}", path);
        }
    }

    // ─── 源码嵌入表测试（迁自 Stdlib.rs） ─────────────────────────────

    #[test]
    fn test_builtin_files_count() {
        // Raw(3: io+net+time) + error(6) + cast(3: pack+Raw+Cast) + reflect(3: pack+Raw+Reflect) + io(4: pack+Reader+Writer+Console) + net(1) + time(1) + str(2: pack+Raw) + iter(2) = 25
        assert_eq!(BUILTIN_FILES.len(), 25, "builtin 应有 25 个文件");
    }

    #[test]
    fn test_std_files_count() {
        // io(6) + time(7) + net(6) = 19
        assert_eq!(STD_FILES.len(), 19, "std 应有 19 个文件");
    }

    #[test]
    fn test_total_files_count() {
        // builtin(25) + std(19) = 44
        assert_eq!(
            BUILTIN_FILES.len() + STD_FILES.len(),
            44,
            "总计 44 个文件"
        );
    }

    #[test]
    fn test_find_existing() {
        let src = find("builtin/error/Err.glue");
        assert!(src.is_some(), "应能找到 builtin/error/Err.glue");
        assert!(src.unwrap().contains("trait Err"), "Err.glue 应包含 trait Err");
    }

    #[test]
    fn test_find_nonexistent() {
        assert!(find("nonexistent.glue").is_none());
    }

    #[test]
    fn test_find_by_prefix() {
        let io_files: Vec<_> = find_by_prefix("std/io/").collect();
        assert!(io_files.len() >= 6, "std/io/ 应至少 6 个文件");
        assert!(io_files.iter().any(|(p, _)| *p == "std/io/File.glue"));
    }

    #[test]
    fn test_all_files_nonempty() {
        for (path, src) in BUILTIN_FILES.iter().chain(STD_FILES.iter()) {
            assert!(!src.is_empty(), "{} 不应为空", path);
        }
    }

    #[test]
    fn test_file_paths_well_formed() {
        for (path, _) in BUILTIN_FILES.iter().chain(STD_FILES.iter()) {
            assert!(path.ends_with(".glue"), "{} 应以 .glue 结尾", path);
            assert!(!path.starts_with('/'), "{} 不应以 / 开头", path);
        }
    }
}
