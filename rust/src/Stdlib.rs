//! Glue 标准库源文件嵌入
//!
//! 等价于 Zig 侧的 src/builtin/embed.zig + src/std/embed.zig。
//! 使用 include_str! 在编译期将 .glue 源文件嵌入二进制。
//!
//! ## 目录结构
//!
//! ```text
//! rust/stdlib/
//! ├── builtin/          # 内置模块（默认可见，无需 import）
//! │   ├── error/        # Err/Error/CastError/IOError/TimeError
//! │   ├── io/           # Reader/Writer trait
//! │   └── iter/         # Iter<T> 迭代器
//! └── std/              # 标准库（需 import std.xxx）
//!     ├── io/           # File/Path/Buffered/Dir/Fs/Console
//!     ├── time/         # Duration/Instant/SystemTime/DateTime/Calendar/Timer
//!     ├── net/          # Addr/TcpListener/TcpStream/UdpSocket/Dns
//!     └── reflect/      # Reflect
//! ```
//!
//! ## 使用方式
//!
//! Rust 编译器前端就绪后，可通过 `BUILTIN_FILES` / `STD_FILES` 加载源码并解析：
//!
//! ```rust,ignore
//! use glue_rs::Stdlib;
//!
//! // 加载 builtin 模块
//! for (path, source) in Stdlib::BUILTIN_FILES {
//!     let module = parse(source);
//!     register_builtin(path, module);
//! }
//!
//! // 按需加载 std 模块
//! for (path, source) in Stdlib::STD_FILES {
//!     let module = parse(source);
//!     register_std(path, module);
//! }
//! ```

/// 标准库文件条目：(相对路径, 源码内容)
pub type StdlibFile = (&'static str, &'static str);

/// builtin 模块文件清单（默认可见，无需 import）
///
/// 顺序按依赖关系排列：error → io → iter
pub const BUILTIN_FILES: &[StdlibFile] = &[
    // error 模块
    ("builtin/error/pack.glue", include_str!("../stdlib/builtin/error/pack.glue")),
    ("builtin/error/Err.glue", include_str!("../stdlib/builtin/error/Err.glue")),
    ("builtin/error/Error.glue", include_str!("../stdlib/builtin/error/Error.glue")),
    ("builtin/error/CastError.glue", include_str!("../stdlib/builtin/error/CastError.glue")),
    ("builtin/error/IOError.glue", include_str!("../stdlib/builtin/error/IOError.glue")),
    ("builtin/error/TimeError.glue", include_str!("../stdlib/builtin/error/TimeError.glue")),
    // io 模块
    ("builtin/io/pack.glue", include_str!("../stdlib/builtin/io/pack.glue")),
    ("builtin/io/Reader.glue", include_str!("../stdlib/builtin/io/Reader.glue")),
    ("builtin/io/Writer.glue", include_str!("../stdlib/builtin/io/Writer.glue")),
    // iter 模块
    ("builtin/iter/pack.glue", include_str!("../stdlib/builtin/iter/pack.glue")),
    ("builtin/iter/Iter.glue", include_str!("../stdlib/builtin/iter/Iter.glue")),
];

/// std 模块文件清单（需 import std.xxx 加载）
///
/// 顺序按依赖关系排列：io → time → net → reflect
pub const STD_FILES: &[StdlibFile] = &[
    // io 模块
    ("std/io/pack.glue", include_str!("../stdlib/std/io/pack.glue")),
    ("std/io/Path.glue", include_str!("../stdlib/std/io/Path.glue")),
    ("std/io/File.glue", include_str!("../stdlib/std/io/File.glue")),
    ("std/io/Buffered.glue", include_str!("../stdlib/std/io/Buffered.glue")),
    ("std/io/Dir.glue", include_str!("../stdlib/std/io/Dir.glue")),
    ("std/io/Fs.glue", include_str!("../stdlib/std/io/Fs.glue")),
    ("std/io/Console.glue", include_str!("../stdlib/std/io/Console.glue")),
    // time 模块
    ("std/time/pack.glue", include_str!("../stdlib/std/time/pack.glue")),
    ("std/time/Duration.glue", include_str!("../stdlib/std/time/Duration.glue")),
    ("std/time/Instant.glue", include_str!("../stdlib/std/time/Instant.glue")),
    ("std/time/SystemTime.glue", include_str!("../stdlib/std/time/SystemTime.glue")),
    ("std/time/DateTime.glue", include_str!("../stdlib/std/time/DateTime.glue")),
    ("std/time/Calendar.glue", include_str!("../stdlib/std/time/Calendar.glue")),
    ("std/time/Timer.glue", include_str!("../stdlib/std/time/Timer.glue")),
    // net 模块
    ("std/net/pack.glue", include_str!("../stdlib/std/net/pack.glue")),
    ("std/net/Addr.glue", include_str!("../stdlib/std/net/Addr.glue")),
    ("std/net/Dns.glue", include_str!("../stdlib/std/net/Dns.glue")),
    ("std/net/TcpListener.glue", include_str!("../stdlib/std/net/TcpListener.glue")),
    ("std/net/TcpStream.glue", include_str!("../stdlib/std/net/TcpStream.glue")),
    ("std/net/UdpSocket.glue", include_str!("../stdlib/std/net/UdpSocket.glue")),
    // reflect 模块
    ("std/reflect/pack.glue", include_str!("../stdlib/std/reflect/pack.glue")),
    ("std/reflect/Reflect.glue", include_str!("../stdlib/std/reflect/Reflect.glue")),
];

/// 所有标准库文件（builtin + std）
///
/// 使用 const 上下文手动拼接，避免运行时开销。
pub const ALL_FILES: &[StdlibFile] = &[
    // builtin
    ("builtin/error/pack.glue", include_str!("../stdlib/builtin/error/pack.glue")),
    ("builtin/error/Err.glue", include_str!("../stdlib/builtin/error/Err.glue")),
    ("builtin/error/Error.glue", include_str!("../stdlib/builtin/error/Error.glue")),
    ("builtin/error/CastError.glue", include_str!("../stdlib/builtin/error/CastError.glue")),
    ("builtin/error/IOError.glue", include_str!("../stdlib/builtin/error/IOError.glue")),
    ("builtin/error/TimeError.glue", include_str!("../stdlib/builtin/error/TimeError.glue")),
    ("builtin/io/pack.glue", include_str!("../stdlib/builtin/io/pack.glue")),
    ("builtin/io/Reader.glue", include_str!("../stdlib/builtin/io/Reader.glue")),
    ("builtin/io/Writer.glue", include_str!("../stdlib/builtin/io/Writer.glue")),
    ("builtin/iter/pack.glue", include_str!("../stdlib/builtin/iter/pack.glue")),
    ("builtin/iter/Iter.glue", include_str!("../stdlib/builtin/iter/Iter.glue")),
    // std
    ("std/io/pack.glue", include_str!("../stdlib/std/io/pack.glue")),
    ("std/io/Path.glue", include_str!("../stdlib/std/io/Path.glue")),
    ("std/io/File.glue", include_str!("../stdlib/std/io/File.glue")),
    ("std/io/Buffered.glue", include_str!("../stdlib/std/io/Buffered.glue")),
    ("std/io/Dir.glue", include_str!("../stdlib/std/io/Dir.glue")),
    ("std/io/Fs.glue", include_str!("../stdlib/std/io/Fs.glue")),
    ("std/io/Console.glue", include_str!("../stdlib/std/io/Console.glue")),
    ("std/time/pack.glue", include_str!("../stdlib/std/time/pack.glue")),
    ("std/time/Duration.glue", include_str!("../stdlib/std/time/Duration.glue")),
    ("std/time/Instant.glue", include_str!("../stdlib/std/time/Instant.glue")),
    ("std/time/SystemTime.glue", include_str!("../stdlib/std/time/SystemTime.glue")),
    ("std/time/DateTime.glue", include_str!("../stdlib/std/time/DateTime.glue")),
    ("std/time/Calendar.glue", include_str!("../stdlib/std/time/Calendar.glue")),
    ("std/time/Timer.glue", include_str!("../stdlib/std/time/Timer.glue")),
    ("std/net/pack.glue", include_str!("../stdlib/std/net/pack.glue")),
    ("std/net/Addr.glue", include_str!("../stdlib/std/net/Addr.glue")),
    ("std/net/Dns.glue", include_str!("../stdlib/std/net/Dns.glue")),
    ("std/net/TcpListener.glue", include_str!("../stdlib/std/net/TcpListener.glue")),
    ("std/net/TcpStream.glue", include_str!("../stdlib/std/net/TcpStream.glue")),
    ("std/net/UdpSocket.glue", include_str!("../stdlib/std/net/UdpSocket.glue")),
    ("std/reflect/pack.glue", include_str!("../stdlib/std/reflect/pack.glue")),
    ("std/reflect/Reflect.glue", include_str!("../stdlib/std/reflect/Reflect.glue")),
];

/// 按路径查找标准库文件
pub fn find(path: &str) -> Option<&'static str> {
    ALL_FILES.iter().find(|(p, _)| *p == path).map(|(_, src)| *src)
}

/// 按模块名前缀查找（如 "std/io" 返回所有 std/io/*.glue）
pub fn find_by_prefix(prefix: &str) -> impl Iterator<Item = StdlibFile> + use<'_> {
    ALL_FILES.iter().copied().filter(move |(p, _)| p.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_files_count() {
        assert_eq!(BUILTIN_FILES.len(), 11, "builtin 应有 11 个文件");
    }

    #[test]
    fn test_std_files_count() {
        // io(7) + time(7) + net(6) + reflect(2) = 22
        assert_eq!(STD_FILES.len(), 22, "std 应有 22 个文件");
    }

    #[test]
    fn test_all_files_count() {
        // builtin(11) + std(22) = 33
        assert_eq!(ALL_FILES.len(), 33, "总计 33 个文件");
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
        for (path, src) in ALL_FILES {
            assert!(!src.is_empty(), "{} 不应为空", path);
        }
    }

    #[test]
    fn test_file_paths_well_formed() {
        for (path, _) in ALL_FILES {
            assert!(path.ends_with(".glue"), "{} 应以 .glue 结尾", path);
            assert!(!path.starts_with('/'), "{} 不应以 / 开头", path);
        }
    }
}
