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
    Decl, ErrorCollector, ImportItem, Lexer, Module, Parser, Token, TokenCollector, Visibility,
};
use crate::Stdlib;

/// 已加载的模块条目
struct LoadedModule {
    /// parse 产出的 AST 模块（'static 生命周期，可安全缓存）
    module: Module<'static>,
    /// 模块导出的公开符号（pub fun / pub type / pub val 的名称）
    exports: HashSet<String>,
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
}

impl ModuleLoader {
    /// 创建新的加载器，并全量预加载 builtin 模块
    pub fn new() -> Self {
        let mut loader = Self {
            modules: HashMap::new(),
            search_paths: Vec::new(),
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
    /// 遍历 Stdlib::BUILTIN_FILES，parse 每个 .glue 文件并缓存。
    /// builtin 模块按依赖顺序排列（error → io → iter），保证后续 check 时依赖已就绪。
    fn preload_builtins(&mut self) {
        for (path, source) in Stdlib::BUILTIN_FILES {
            if let Some(module) = parse_source(path, source) {
                let exports = collect_exports(&module);
                self.modules.insert(path.to_string(), LoadedModule { module, exports });
            }
        }
    }

    /// 按模块路径段解析并加载模块
    ///
    /// `path = ["std", "io", "File"]` → 查找 "std/io/File.glue"
    /// 优先查缓存 → stdlib 嵌入表 → 文件系统搜索路径
    ///
    /// 返回已加载的 Module 引用，若未找到返回 None。
    pub fn resolve_and_load(&mut self, path: &[&str]) -> Option<&Module<'static>> {
        let path_str = module_path_to_file(path);

        // 1. 检查缓存
        if self.modules.contains_key(&path_str) {
            return self.modules.get(&path_str).map(|m| &m.module);
        }

        // 2. 查找 stdlib 嵌入表
        if let Some(source) = Stdlib::find(&path_str) {
            // path_str 是 String，需 leak 为 &'static str 供 parse_module 使用
            let path_static: &'static str = Box::leak(path_str.clone().into_boxed_str());
            if let Some(module) = parse_source(path_static, source) {
                let exports = collect_exports(&module);
                self.modules
                    .insert(path_str.clone(), LoadedModule { module, exports });
                return self.modules.get(&path_str).map(|m| &m.module);
            }
            return None;
        }

        // 3. 查找文件系统（用户模块）
        for base in &self.search_paths {
            let full = base.join(&path_str);
            if full.exists() {
                match std::fs::read_to_string(&full) {
                    Ok(source) => {
                        let source_static: &'static str =
                            Box::leak(source.into_boxed_str());
                        let path_static: &'static str =
                            Box::leak(path_str.clone().into_boxed_str());
                        if let Some(module) = parse_source(path_static, source_static) {
                            let exports = collect_exports(&module);
                            self.modules
                                .insert(path_str.clone(), LoadedModule { module, exports });
                            return self.modules.get(&path_str).map(|m| &m.module);
                        }
                    }
                    Err(_) => continue,
                }
            }
        }

        None
    }

    /// 获取已加载模块的导出符号列表
    pub fn get_exports(&self, path: &[&str]) -> Option<&HashSet<String>> {
        let path_str = module_path_to_file(path);
        self.modules.get(&path_str).map(|m| &m.exports)
    }

    /// 获取已加载的 builtin 模块（按 BUILTIN_FILES 顺序）
    pub fn builtin_modules(&self) -> impl Iterator<Item = (&str, &Module<'static>)> {
        Stdlib::BUILTIN_FILES.iter().filter_map(|(path, _)| {
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
fn parse_source(path: &'static str, source: &'static str) -> Option<Module<'static>> {
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
            // 报告非致命 parse 错误
            for err in parser.errors() {
                eprintln!(
                    "Warning: parse error in {} at {}:{}: {}",
                    path, err.line, err.column, err.message
                );
            }
            Some(module)
        }
        Err(err) => {
            eprintln!(
                "Error: parse error in {} at {}:{}: {}",
                path, err.line, err.column, err.message
            );
            None
        }
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
        assert_eq!(loader.loaded_count(), Stdlib::BUILTIN_FILES.len());
    }

    #[test]
    fn test_builtin_modules_all_parsed() {
        let loader = ModuleLoader::new();
        // 所有 builtin 模块应成功 parse
        assert_eq!(loader.builtin_modules().count(), Stdlib::BUILTIN_FILES.len());
    }

    #[test]
    fn test_resolve_std_module() {
        let mut loader = ModuleLoader::new();
        // 加载 std/io/File.glue
        let module = loader.resolve_and_load(&["std", "io", "File"]);
        assert!(module.is_some(), "应能加载 std/io/File");
        // builtin(11) + File = 12
        assert_eq!(loader.loaded_count(), Stdlib::BUILTIN_FILES.len() + 1);
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
        // 加载 std/io/Console.glue，它应该有 import 声明
        let module = loader.resolve_and_load(&["std", "io", "Console"]);
        assert!(module.is_some());
        let module = module.unwrap();
        let imports = collect_imports(module);
        // Console.glue 可能有也可能没有 import，但函数不应 panic
        println!("Console.glue imports: {:?}", imports.len());
    }

    #[test]
    fn test_all_stdlib_files_parseable() {
        // 验证所有 stdlib 文件都能被 ModuleLoader 正确 parse
        let mut loader = ModuleLoader::new();
        for (path, _) in Stdlib::STD_FILES {
            let parts: Vec<&str> = path.strip_suffix(".glue").unwrap().split('/').collect();
            let result = loader.resolve_and_load(&parts);
            assert!(result.is_some(), "无法 parse stdlib 文件: {}", path);
        }
    }
}
