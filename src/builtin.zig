//! Glue builtin 类型元信息表
//!
//! 集中管理所有用 Glue 源码定义的内建类型（src/builtin/**/*.glue）。
//! 作为 sema 启动时加载 builtin 类型定义、Zig 端构造 builtin 值时查询字段布局的
//! 单一真相来源（决策 #18/#23/#24/#25）。
//!
//! 设计要点：
//!   - 编译期元信息已知（comptime 表），运行期按需加载（仅引用的方法体编译）
//!   - sema 启动时遍历 BUILTIN_TYPES 注册所有类型定义到类型环境
//!   - IR builder 启动时遍历注册所有构造器到 ctor_table / type_table
//!   - Zig 端构造 builtin 值时通过 getFieldLayout 查询字段顺序
//!   - builtin 类型对所有用户代码默认可见，禁止遮蔽（决策 #19）
//!
//! 子目录结构（决策 #17）：
//!   src/builtin/
//!   ├── error/
//!   │   ├── pack.glue          // pub pack CastError
//!   │   └── CastError.glue     // CastError 类型定义
//!   └── (未来其他 builtin 类别)

const std = @import("std");

/// Builtin 类型类别
pub const BuiltinKind = enum {
    /// Error 子类型（type X: Error = X(...) ）
    error_newtype,
    /// 关联 ADT（type X = | A | B(...) ），如 IOErrorKind / TimeErrorKind
    adt,
    // 未来扩展：record / trait 等
};

/// Builtin 字段元信息
pub const FieldInfo = struct {
    /// 字段名（源码中显式声明的名字；运行时通过 _<idx> 别名访问）
    name: []const u8,
    /// 字段类型名（"str"/"i32"/"usize"/...）
    type_name: []const u8,
};

/// Builtin 类型元信息
pub const BuiltinTypeInfo = struct {
    /// 类型名（如 "CastError"）
    name: []const u8,
    /// 类型类别
    kind: BuiltinKind,
    /// 父类型名（error_newtype 时为 "Error"）
    parent_trait: []const u8,
    /// 构造器名（通常等于类型名）
    constructor_name: []const u8,
    /// 字段列表（按源码声明顺序）
    fields: []const FieldInfo,
    /// ADT 构造器名列表（kind == .adt 时使用；其他情况为空）
    constructors: []const []const u8 = &[_][]const u8{},
    /// 源文件相对路径（相对项目根，用于按需加载方法体）
    source_path: []const u8,
    /// 所属 pack 名（用于模块导入解析）
    pack_name: []const u8,
};

/// 所有 builtin 类型元信息表（comptime 单一真相来源）
///
/// 新增 builtin 类型时只需在此表追加条目，并在 src/builtin/ 下创建对应 .glue 文件。
/// sema 与 IR builder 均通过此表加载，避免硬编码。
pub const BUILTIN_TYPES = [_]BuiltinTypeInfo{
    .{
        .name = "CastError",
        .kind = .error_newtype,
        .parent_trait = "Error",
        .constructor_name = "CastError",
        .fields = &[_]FieldInfo{
            .{ .name = "msg", .type_name = "str" },
            .{ .name = "from", .type_name = "str" },
            .{ .name = "to", .type_name = "str" },
            .{ .name = "value", .type_name = "str" },
        },
        .source_path = "src/builtin/error/CastError.glue",
        .pack_name = "CastError",
    },
    .{
        .name = "IOError",
        .kind = .error_newtype,
        .parent_trait = "Error",
        .constructor_name = "IOError",
        .fields = &[_]FieldInfo{
            .{ .name = "kind", .type_name = "IOErrorKind" },
            .{ .name = "msg", .type_name = "str" },
            .{ .name = "os_err", .type_name = "i32" },
            .{ .name = "path", .type_name = "str?" },
        },
        .source_path = "src/builtin/error/IOError.glue",
        .pack_name = "IOError",
    },
    .{
        .name = "TimeError",
        .kind = .error_newtype,
        .parent_trait = "Error",
        .constructor_name = "TimeError",
        .fields = &[_]FieldInfo{
            .{ .name = "kind", .type_name = "TimeErrorKind" },
            .{ .name = "msg", .type_name = "str" },
            .{ .name = "value", .type_name = "str" },
        },
        .source_path = "src/builtin/error/TimeError.glue",
        .pack_name = "TimeError",
    },
    // ── 关联 ADT（kind == .adt） ──
    // 作为 builtin error_newtype 的分类枚举，自动注册构造器到 env
    .{
        .name = "IOErrorKind",
        .kind = .adt,
        .parent_trait = "",
        .constructor_name = "",
        .fields = &[_]FieldInfo{},
        .constructors = &[_][]const u8{
            "NotFound",
            "PermissionDenied",
            "AlreadyExists",
            "Busy",
            "InvalidInput",
            "UnexpectedEof",
            "BrokenPipe",
            "OutOfMemory",
            "Interrupted",
            "Other",
        },
        .source_path = "src/builtin/error/IOError.glue",
        .pack_name = "IOError",
    },
    .{
        .name = "TimeErrorKind",
        .kind = .adt,
        .parent_trait = "",
        .constructor_name = "",
        .fields = &[_]FieldInfo{},
        .constructors = &[_][]const u8{
            "InvalidDateTime",
            "InvalidFormat",
            "ParseFailed",
            "OutOfRange",
            "TimezoneNotFound",
        },
        .source_path = "src/builtin/error/TimeError.glue",
        .pack_name = "TimeError",
    },
};

/// 按类型名查找 builtin 元信息
pub fn getBuiltinType(name: []const u8) ?*const BuiltinTypeInfo {
    inline for (&BUILTIN_TYPES) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// 按类型名查找字段布局（用于 Zig 端构造 builtin 值时按顺序填充字段）
pub fn getFieldLayout(name: []const u8) ?[]const FieldInfo {
    if (getBuiltinType(name)) |t| return t.fields;
    return null;
}

/// 判断名字是否为 builtin 类型名（用于重定义防护）
pub fn isBuiltinTypeName(name: []const u8) bool {
    return getBuiltinType(name) != null;
}

// ── 测试 ──

const testing = std.testing;

test "BUILTIN_TYPES 包含 CastError/IOError/TimeError + 关联 ADT" {
    try testing.expectEqual(@as(usize, 5), BUILTIN_TYPES.len);
    const t = BUILTIN_TYPES[0];
    try testing.expectEqualStrings("CastError", t.name);
    try testing.expectEqual(BuiltinKind.error_newtype, t.kind);
    try testing.expectEqualStrings("Error", t.parent_trait);
    try testing.expectEqualStrings("CastError", t.constructor_name);

    const io = BUILTIN_TYPES[1];
    try testing.expectEqualStrings("IOError", io.name);
    try testing.expectEqual(BuiltinKind.error_newtype, io.kind);
    try testing.expectEqualStrings("Error", io.parent_trait);
    try testing.expectEqualStrings("IOError", io.constructor_name);

    const tm = BUILTIN_TYPES[2];
    try testing.expectEqualStrings("TimeError", tm.name);
    try testing.expectEqual(BuiltinKind.error_newtype, tm.kind);
    try testing.expectEqualStrings("Error", tm.parent_trait);
    try testing.expectEqualStrings("TimeError", tm.constructor_name);

    const io_kind = BUILTIN_TYPES[3];
    try testing.expectEqualStrings("IOErrorKind", io_kind.name);
    try testing.expectEqual(BuiltinKind.adt, io_kind.kind);
    try testing.expectEqual(@as(usize, 10), io_kind.constructors.len);
    try testing.expectEqualStrings("NotFound", io_kind.constructors[0]);
    try testing.expectEqualStrings("InvalidInput", io_kind.constructors[4]);
    try testing.expectEqualStrings("Other", io_kind.constructors[9]);

    const tm_kind = BUILTIN_TYPES[4];
    try testing.expectEqualStrings("TimeErrorKind", tm_kind.name);
    try testing.expectEqual(BuiltinKind.adt, tm_kind.kind);
    try testing.expectEqual(@as(usize, 5), tm_kind.constructors.len);
    try testing.expectEqualStrings("InvalidDateTime", tm_kind.constructors[0]);
    try testing.expectEqualStrings("TimezoneNotFound", tm_kind.constructors[4]);
}

test "CastError 字段布局" {
    const layout = getFieldLayout("CastError") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), layout.len);
    try testing.expectEqualStrings("msg", layout[0].name);
    try testing.expectEqualStrings("str", layout[0].type_name);
    try testing.expectEqualStrings("from", layout[1].name);
    try testing.expectEqualStrings("to", layout[2].name);
    try testing.expectEqualStrings("value", layout[3].name);
}

test "IOError 字段布局" {
    const layout = getFieldLayout("IOError") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), layout.len);
    try testing.expectEqualStrings("kind", layout[0].name);
    try testing.expectEqualStrings("IOErrorKind", layout[0].type_name);
    try testing.expectEqualStrings("msg", layout[1].name);
    try testing.expectEqualStrings("str", layout[1].type_name);
    try testing.expectEqualStrings("os_err", layout[2].name);
    try testing.expectEqualStrings("i32", layout[2].type_name);
    try testing.expectEqualStrings("path", layout[3].name);
    try testing.expectEqualStrings("str?", layout[3].type_name);
}

test "TimeError 字段布局" {
    const layout = getFieldLayout("TimeError") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), layout.len);
    try testing.expectEqualStrings("kind", layout[0].name);
    try testing.expectEqualStrings("TimeErrorKind", layout[0].type_name);
    try testing.expectEqualStrings("msg", layout[1].name);
    try testing.expectEqualStrings("str", layout[1].type_name);
    try testing.expectEqualStrings("value", layout[2].name);
    try testing.expectEqualStrings("str", layout[2].type_name);
}

test "getBuiltinType 命中/未命中" {
    try testing.expect(getBuiltinType("CastError") != null);
    try testing.expect(getBuiltinType("IOError") != null);
    try testing.expect(getBuiltinType("TimeError") != null);
    try testing.expect(getBuiltinType("FileError") == null);
}

test "isBuiltinTypeName" {
    try testing.expect(isBuiltinTypeName("CastError"));
    try testing.expect(isBuiltinTypeName("IOError"));
    try testing.expect(isBuiltinTypeName("TimeError"));
    try testing.expect(!isBuiltinTypeName("NotABuiltin"));
}
