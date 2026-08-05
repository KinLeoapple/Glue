//! 标准库源码嵌入表与查询。
//!
//! 使用 `include_str!` 在编译期将 `.glue` 源文件嵌入二进制，供 `Loader` parse。
//!
//! ## 目录结构
//!
//! ```text
//! src/stdlib/
//! ├── builtin/          # 内置模块（默认可见，无需 import）
//! │   ├── {io,net,time}/Raw.glue  # @extern("C") 原语（按领域拆分）
//! │   ├── error/        # Err/Error/CastError/IOError/TimeError
//! │   ├── cast/         # Raw.glue(@extern 原语) + Cast.glue(glue wrapper)
//! │   ├── reflect/      # 运行时反射格式化（Reflect.format）
//! │   ├── io/           # Reader/Writer trait + Console(print/println/scan...)
//! │   └── iter/         # Iterator<T> 迭代器
//! └── std/              # 标准库（需 import std.xxx）
//!     ├── io/           # File/Path/Buffered/Dir/Fs
//!     ├── time/         # Duration/Instant/SystemTime/DateTime/Calendar/Timer
//!     └── net/          # Addr/TcpListener/TcpStream/UdpSocket/Dns
//! ```

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
