//! 字节码缓存系统：每模块缓存编译产物，按 mtime+size + 符号签名匹配判定命中。
//!
//! 缓存目录布局：
//!   .cache/
//!     <hash>.bcc             # 每模块缓存文件
//!
//! .bcc 文件格式：
//!   [Header] magic + version + src_mtime + src_size + module_name + src_path
//!   [Interface] 导出符号签名表
//!   [Usage] 使用的导入符号签名表
//!   [Bytecode] Chunk + Function + Desc 表（含重定位表）
//!   [Reloc] 重定位表

const std = @import("std");
const reloc_mod = @import("reloc.zig");
const vm = @import("vm");

// 引入 serializer 模块（使其测试随 cache 模块一起运行）
pub const serializer = @import("serializer.zig");
pub const interface = @import("interface.zig");
pub const usage = @import("usage.zig");
pub const reloc = @import("reloc.zig");

/// 缓存文件魔数（升级 Zig/Glue 后旧缓存自动失效）
pub const CACHE_MAGIC: [8]u8 = .{ 'G', 'L', 'U', 'E', 'B', 'C', '0', '1' };
/// 缓存格式版本（BccFile 结构变化时递增）
/// v2: 添加 deps 字段（whole-program cache 依赖列表）
pub const CACHE_VERSION: u32 = 3;

/// 缓存键：源文件路径 + mtime + size
pub const CacheKey = struct {
    src_path: []const u8,
    mtime: i128,
    size: u64,
};

/// 缓存条目（索引中的记录）
pub const CacheEntry = struct {
    src_path: []const u8,
    mtime: i128,
    size: u64,
    bcc_filename: []const u8,
};

/// 缓存存储：管理 .cache 目录
pub const CacheStore = struct {
    cache_dir: []const u8,
    allocator: std.mem.Allocator,
    enabled: bool,
    io: ?std.Io,

    pub fn init(allocator: std.mem.Allocator, io: ?std.Io, cache_dir: []const u8, enabled: bool) CacheStore {
        return .{
            .cache_dir = cache_dir,
            .allocator = allocator,
            .enabled = enabled,
            .io = io,
        };
    }

    /// 生成缓存文件名：<src_path 的 FNV-1a 64 hash>.bcc
    pub fn bccFilename(self: *const CacheStore, src_path: []const u8) ![]u8 {
        var hash: u64 = 0xCBF29CE484222325; // FNV-1a 64 offset basis
        for (src_path) |b| {
            hash ^= b;
            hash *%= 0x100000001B3;
        }
        return std.fmt.allocPrint(self.allocator, "{x:0>16}.bcc", .{hash});
    }

    /// 缓存文件完整路径
    pub fn bccPath(self: *const CacheStore, bcc_filename: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{c}{s}", .{
            self.cache_dir,
            std.fs.path.sep,
            bcc_filename,
        });
    }

    /// 确保缓存目录存在（不存在则创建，已存在则 noop）
    pub fn ensureDir(self: *const CacheStore) !void {
        if (!self.enabled) return;
        const io = self.io orelse return;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, self.cache_dir) catch {};
    }
};

// ============================================================
// BccFile：完整 .bcc 文件内容
// ============================================================

/// .bcc 文件头
pub const BccHeader = struct {
    magic: [8]u8,
    version: u32,
    src_mtime: i128,
    src_size: u64,
    module_name: []const u8,
    src_path: []const u8,
};

/// 依赖模块条目（whole-program cache 命中校验用）
/// src_path / module_name 为 owned（readBytes dupe）
pub const DepEntry = struct {
    src_path: []const u8,
    module_name: []const u8,
    mtime: i128,
    size: u64,
};

/// .bcc 文件完整内容（header + deps + interface + usage + bytecode + reloc）
pub const BccFile = struct {
    header: BccHeader,
    /// 【whole-program cache】依赖模块列表（入口模块的 use 依赖 + 传递依赖）
    /// 命中校验：每个依赖的 mtime+size 必须与磁盘当前状态匹配
    deps: std.ArrayListUnmanaged(DepEntry) = .empty,
    iface: interface.ModuleInterface,
    usage: usage.SymbolUsage,
    // 字节码部分（对应 vm.chunk.Program 的字段）
    entry: ?u16 = null,
    functions: std.ArrayListUnmanaged(vm.chunk.Function) = .empty,
    adt_ctors: std.ArrayListUnmanaged(vm.chunk.AdtCtorDesc) = .empty,
    record_shapes: std.ArrayListUnmanaged(vm.chunk.RecordShape) = .empty,
    newtype_ctors: std.ArrayListUnmanaged(vm.chunk.NewtypeCtorDesc) = .empty,
    error_ctors: std.ArrayListUnmanaged(vm.chunk.ErrorCtorDesc) = .empty,
    trait_methods: std.ArrayListUnmanaged(vm.chunk.TraitMethodDesc) = .empty,
    trait_defaults: std.ArrayListUnmanaged(vm.chunk.TraitDefaultDesc) = .empty,
    trait_parents: std.ArrayListUnmanaged(vm.chunk.TraitParentDesc) = .empty,
    trait_resolves: std.ArrayListUnmanaged(vm.chunk.TraitResolveDesc) = .empty,
    trait_order: std.ArrayListUnmanaged([]const u8) = .empty,
    global_count: u16 = 0,
    globals_init: ?u16 = null,
    reloc_table: reloc_mod.RelocTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, header: BccHeader) BccFile {
        return .{
            .allocator = allocator,
            .header = header,
            .iface = interface.ModuleInterface.init(allocator, header.module_name),
            .usage = usage.SymbolUsage.init(allocator),
            .reloc_table = reloc_mod.RelocTable.init(allocator),
        };
    }

    pub fn deinit(self: *BccFile) void {
        // iface: symbol names 是 owned（readBytes dupe），module_name 借用 header（由 header 释放）
        for (self.iface.symbols.items) |s| self.allocator.free(s.name);
        self.iface.deinit();
        // header: module_name + src_path 是 owned
        self.allocator.free(self.header.module_name);
        self.allocator.free(self.header.src_path);
        // deps: src_path + module_name 均 owned
        for (self.deps.items) |d| {
            self.allocator.free(d.src_path);
            self.allocator.free(d.module_name);
        }
        self.deps.deinit(self.allocator);
        self.usage.deinit();
        for (self.functions.items) |*f| f.deinit();
        self.functions.deinit(self.allocator);
        // 反序列化的 Desc 表字符串为 owned，需释放
        for (self.adt_ctors.items) |*d| serializer.freeAdtCtor(self.allocator, d);
        self.adt_ctors.deinit(self.allocator);
        for (self.record_shapes.items) |*s| serializer.freeRecordShape(self.allocator, s);
        self.record_shapes.deinit(self.allocator);
        for (self.newtype_ctors.items) |*n| serializer.freeNewtypeCtor(self.allocator, n);
        self.newtype_ctors.deinit(self.allocator);
        for (self.error_ctors.items) |*e| serializer.freeErrorCtor(self.allocator, e);
        self.error_ctors.deinit(self.allocator);
        for (self.trait_methods.items) |*m| serializer.freeTraitMethod(self.allocator, m);
        self.trait_methods.deinit(self.allocator);
        for (self.trait_defaults.items) |*d| serializer.freeTraitDefault(self.allocator, d);
        self.trait_defaults.deinit(self.allocator);
        for (self.trait_parents.items) |*p| serializer.freeTraitParent(self.allocator, p);
        self.trait_parents.deinit(self.allocator);
        for (self.trait_resolves.items) |*r| serializer.freeTraitResolve(self.allocator, r);
        self.trait_resolves.deinit(self.allocator);
        for (self.trait_order.items) |s| self.allocator.free(s);
        self.trait_order.deinit(self.allocator);
        self.reloc_table.deinit();
    }

    /// 序列化到 buffer（header + deps + iface + usage + bytecode + reloc）
    pub fn writeBytes(self: *const BccFile, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        // Header
        try buf.appendSlice(allocator, &self.header.magic);
        try buf.appendSlice(allocator, std.mem.asBytes(&self.header.version));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.header.src_mtime));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.header.src_size));
        try writeOwnedStr(buf, allocator, self.header.module_name);
        try writeOwnedStr(buf, allocator, self.header.src_path);

        // Deps（whole-program cache 依赖列表）
        const deps_count: u32 = @intCast(self.deps.items.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&deps_count));
        for (self.deps.items) |d| {
            try writeOwnedStr(buf, allocator, d.src_path);
            try writeOwnedStr(buf, allocator, d.module_name);
            try buf.appendSlice(allocator, std.mem.asBytes(&d.mtime));
            try buf.appendSlice(allocator, std.mem.asBytes(&d.size));
        }

        // Interface
        try self.iface.writeBytes(buf, allocator);

        // Usage
        try self.usage.writeBytes(buf, allocator);

        // Bytecode: entry + global_count + globals_init + functions + Desc tables
        try buf.appendSlice(allocator, std.mem.asBytes(&self.entry));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.global_count));
        try buf.appendSlice(allocator, std.mem.asBytes(&self.globals_init));

        const fn_count: u32 = @intCast(self.functions.items.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&fn_count));
        for (self.functions.items) |*f| {
            try serializer.serializeFunction(buf, allocator, f);
        }

        try writeDescSlice(buf, allocator, self.adt_ctors.items, serializer.serializeAdtCtor);
        try writeDescSlice(buf, allocator, self.record_shapes.items, serializer.serializeRecordShape);
        try writeDescSlice(buf, allocator, self.newtype_ctors.items, serializer.serializeNewtypeCtor);
        try writeDescSlice(buf, allocator, self.error_ctors.items, serializer.serializeErrorCtor);
        try writeDescSlice(buf, allocator, self.trait_methods.items, serializer.serializeTraitMethod);
        try writeDescSlice(buf, allocator, self.trait_defaults.items, serializer.serializeTraitDefault);
        try writeDescSlice(buf, allocator, self.trait_parents.items, serializer.serializeTraitParent);
        try writeDescSlice(buf, allocator, self.trait_resolves.items, serializer.serializeTraitResolve);

        // trait_order: u32 count + 每个 owned str
        const to_count: u32 = @intCast(self.trait_order.items.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&to_count));
        for (self.trait_order.items) |s| try writeOwnedStr(buf, allocator, s);

        // Reloc table
        try self.reloc_table.writeBytes(buf);
    }

    /// 从光标反序列化（所有字符串为 owned）
    pub fn readBytes(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !BccFile {
        // Header
        var magic: [8]u8 = undefined;
        try cur.read(&magic);
        if (!std.mem.eql(u8, &magic, &CACHE_MAGIC)) return error.InvalidCacheMagic;
        var version: u32 = undefined;
        try cur.read(std.mem.asBytes(&version));
        if (version != CACHE_VERSION) return error.CacheVersionMismatch;
        var src_mtime: i128 = undefined;
        var src_size: u64 = undefined;
        try cur.read(std.mem.asBytes(&src_mtime));
        try cur.read(std.mem.asBytes(&src_size));
        const module_name = try readOwnedStr(allocator, cur);
        const src_path = try readOwnedStr(allocator, cur);

        var file = BccFile.init(allocator, .{
            .magic = magic,
            .version = version,
            .src_mtime = src_mtime,
            .src_size = src_size,
            .module_name = module_name,
            .src_path = src_path,
        });
        errdefer file.deinit();

        // Deps（whole-program cache 依赖列表）
        var deps_count: u32 = undefined;
        try cur.read(std.mem.asBytes(&deps_count));
        try file.deps.ensureTotalCapacity(allocator, deps_count);
        var di: u32 = 0;
        while (di < deps_count) : (di += 1) {
            const dep_src_path = try readOwnedStr(allocator, cur);
            const dep_module_name = try readOwnedStr(allocator, cur);
            var dep_mtime: i128 = undefined;
            var dep_size: u64 = undefined;
            try cur.read(std.mem.asBytes(&dep_mtime));
            try cur.read(std.mem.asBytes(&dep_size));
            try file.deps.append(allocator, .{
                .src_path = dep_src_path,
                .module_name = dep_module_name,
                .mtime = dep_mtime,
                .size = dep_size,
            });
        }

        // Interface（readBytes 会 dupe module_name，但 BccFile.init 已用 header.module_name；
        // 这里读出的 iface.module_name 是 owned，需释放以避免泄漏。我们让 iface 复用 header 的 module_name）
        {
            var iface = try interface.ModuleInterface.readBytes(allocator, cur);
            defer iface.freeOwned(); // 释放 readBytes dupe 的 module_name + symbol names
            // 把符号迁移到 file.iface（复用 header.module_name）
            file.iface.symbols = iface.symbols;
            iface.symbols = .empty;
        }

        // Usage
        file.usage = try usage.SymbolUsage.readBytes(allocator, cur);

        // Bytecode
        try cur.read(std.mem.asBytes(&file.entry));
        try cur.read(std.mem.asBytes(&file.global_count));
        try cur.read(std.mem.asBytes(&file.globals_init));

        var fn_count: u32 = undefined;
        try cur.read(std.mem.asBytes(&fn_count));
        try file.functions.ensureTotalCapacity(allocator, fn_count);
        var i: u32 = 0;
        while (i < fn_count) : (i += 1) {
            const f = try serializer.deserializeFunction(allocator, cur);
            try file.functions.append(allocator, f);
        }

        try readDescSlice(allocator, cur, &file.adt_ctors, serializer.deserializeAdtCtor);
        try readDescSlice(allocator, cur, &file.record_shapes, serializer.deserializeRecordShape);
        try readDescSlice(allocator, cur, &file.newtype_ctors, serializer.deserializeNewtypeCtor);
        try readDescSlice(allocator, cur, &file.error_ctors, serializer.deserializeErrorCtor);
        try readDescSlice(allocator, cur, &file.trait_methods, serializer.deserializeTraitMethod);
        try readDescSlice(allocator, cur, &file.trait_defaults, serializer.deserializeTraitDefault);
        try readDescSlice(allocator, cur, &file.trait_parents, serializer.deserializeTraitParent);
        try readDescSlice(allocator, cur, &file.trait_resolves, serializer.deserializeTraitResolve);

        // trait_order
        var to_count: u32 = undefined;
        try cur.read(std.mem.asBytes(&to_count));
        try file.trait_order.ensureTotalCapacity(allocator, to_count);
        i = 0;
        while (i < to_count) : (i += 1) {
            const s = try readOwnedStr(allocator, cur);
            try file.trait_order.append(allocator, s);
        }

        // Reloc table
        file.reloc_table = try reloc_mod.RelocTable.readBytes(allocator, cur);

        return file;
    }
};

/// 写一个 owned 字符串（u32 len + bytes）
fn writeOwnedStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const len: u32 = @intCast(s.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&len));
    try buf.appendSlice(allocator, s);
}

/// 读一个 owned 字符串
fn readOwnedStr(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) ![]const u8 {
    var len: u32 = undefined;
    try cur.read(std.mem.asBytes(&len));
    const result = try allocator.alloc(u8, len);
    try cur.read(result);
    return result;
}

/// 写 Desc 切片（u32 count + 每个 desc）
fn writeDescSlice(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    items: anytype,
    comptime serialize_fn: anytype,
) !void {
    const count: u32 = @intCast(items.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (items) |*d| try serialize_fn(buf, allocator, d);
}

/// 读 Desc 切片
fn readDescSlice(
    allocator: std.mem.Allocator,
    cur: *reloc_mod.ByteCursor,
    list: anytype,
    comptime deserialize_fn: anytype,
) !void {
    var count: u32 = undefined;
    try cur.read(std.mem.asBytes(&count));
    try list.ensureTotalCapacity(allocator, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const d = try deserialize_fn(allocator, cur);
        try list.append(allocator, d);
    }
}

/// 判定缓存是否命中（单模块模式，向后兼容）
/// key: 当前文件的 mtime+size
/// interfaces: 已加载的被依赖模块接口
pub fn isCacheHit(file: *const BccFile, key: CacheKey, interfaces: *const std.StringHashMap(interface.ModuleInterface)) bool {
    // 1. mtime + size 匹配
    if (file.header.src_mtime != key.mtime) return false;
    if (file.header.src_size != key.size) return false;
    // 2. usage 中所有符号 sig 仍匹配
    if (!file.usage.verifyAll(interfaces)) return false;
    return true;
}

/// 【whole-program cache】判定缓存命中：
/// 1. 入口模块 mtime+size 匹配
/// 2. 所有依赖模块 mtime+size 与磁盘当前状态匹配
/// 3. usage 中所有符号 sig 仍匹配（接口签名稳定性）
/// io / cwd 用于 stat 依赖文件
pub fn isCacheHitWholeProgram(
    file: *const BccFile,
    key: CacheKey,
    io: std.Io,
    interfaces: *const std.StringHashMap(interface.ModuleInterface),
) bool {
    // 1. 入口模块 mtime + size 匹配
    if (file.header.src_mtime != key.mtime) return false;
    if (file.header.src_size != key.size) return false;
    // 2. 所有依赖模块 mtime + size 与磁盘当前状态匹配
    const cwd = std.Io.Dir.cwd();
    for (file.deps.items) |d| {
        const stat = cwd.statFile(io, d.src_path, .{}) catch return false;
        if (@as(i128, stat.mtime.nanoseconds) != d.mtime) return false;
        if (stat.size != d.size) return false;
    }
    // 3. usage 中所有符号 sig 仍匹配
    if (!file.usage.verifyAll(interfaces)) return false;
    return true;
}

/// 【whole-program cache】简化命中判定（跳过 usage 校验）：
/// 1. 入口模块 mtime+size 匹配
/// 2. 所有依赖模块 mtime+size 与磁盘当前状态匹配
/// 依赖 mtime+size 匹配即说明源码未变，接口签名必然未变，usage 校验冗余。
pub fn isCacheHitWholeProgramSimple(
    file: *const BccFile,
    key: CacheKey,
    io: std.Io,
) bool {
    // 1. 入口模块 mtime + size 匹配
    if (file.header.src_mtime != key.mtime) return false;
    if (file.header.src_size != key.size) return false;
    // 2. 所有依赖模块 mtime + size 与磁盘当前状态匹配
    const cwd = std.Io.Dir.cwd();
    for (file.deps.items) |d| {
        const stat = cwd.statFile(io, d.src_path, .{}) catch return false;
        if (@as(i128, stat.mtime.nanoseconds) != d.mtime) return false;
        if (stat.size != d.size) return false;
    }
    return true;
}

/// 写 .bcc 文件到磁盘
pub fn writeBccFile(io: std.Io, store: *const CacheStore, file: *const BccFile, bcc_filename: []const u8) !void {
    const bcc_path = try store.bccPath(bcc_filename);
    defer store.allocator.free(bcc_path);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(store.allocator);
    try file.writeBytes(&buf, store.allocator);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = bcc_path, .data = buf.items });
}

/// 读 .bcc 文件
pub fn readBccFile(allocator: std.mem.Allocator, io: std.Io, store: *const CacheStore, bcc_filename: []const u8) !BccFile {
    const bcc_path = try store.bccPath(bcc_filename);
    defer allocator.free(bcc_path);

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, bcc_path, allocator, .unlimited);
    defer allocator.free(data);

    var cur = reloc_mod.ByteCursor{ .data = data };
    return try BccFile.readBytes(allocator, &cur);
}

/// 【whole-program cache】从 BccFile 构造 Program，转移所有权（functions / Desc 表 / trait_order）。
/// 调用后 BccFile 的对应字段被清空（避免 double-free），调用方拥有返回的 Program。
/// 注意：BccFile.deinit 仍需调用以释放 header/deps/iface/usage/reloc_table。
/// 返回的 Program.owns_desc_strings = true（所有字符串 owned，deinit 时释放）。
pub fn bccFileToProgram(file: *BccFile) !vm.chunk.Program {
    var program = vm.chunk.Program.init(file.allocator);
    program.entry = file.entry;
    program.global_count = file.global_count;
    program.globals_init = file.globals_init;
    program.owns_desc_strings = true; // cache 路径：所有字符串 owned

    // 转移 functions 所有权
    program.functions = file.functions;
    file.functions = .empty;

    // 转移 Desc 表所有权（字符串均为 owned，由 BccFile 反序列化时 dupe）
    program.adt_ctors = file.adt_ctors;
    file.adt_ctors = .empty;
    program.record_shapes = file.record_shapes;
    file.record_shapes = .empty;
    program.newtype_ctors = file.newtype_ctors;
    file.newtype_ctors = .empty;
    program.error_ctors = file.error_ctors;
    file.error_ctors = .empty;
    program.trait_methods = file.trait_methods;
    file.trait_methods = .empty;
    program.trait_defaults = file.trait_defaults;
    file.trait_defaults = .empty;
    program.trait_parents = file.trait_parents;
    file.trait_parents = .empty;
    program.trait_resolves = file.trait_resolves;
    file.trait_resolves = .empty;
    program.trait_order = file.trait_order;
    file.trait_order = .empty;

    return program;
}

test "CacheStore bccFilename 稳定 hash" {
    var store = CacheStore.init(std.testing.allocator, null, ".cache", true);
    const name1 = try store.bccFilename("src/Main.glue");
    defer std.testing.allocator.free(name1);
    const name2 = try store.bccFilename("src/Main.glue");
    defer std.testing.allocator.free(name2);
    try std.testing.expectEqualStrings(name1, name2);
    const name3 = try store.bccFilename("src/Foo.glue");
    defer std.testing.allocator.free(name3);
    try std.testing.expect(!std.mem.eql(u8, name1, name3));
}

test "CacheStore bccPath 拼接" {
    var store = CacheStore.init(std.testing.allocator, null, ".cache", true);
    const path = try store.bccPath("abc.bcc");
    defer std.testing.allocator.free(path);
    // 路径应包含目录和文件名
    try std.testing.expect(std.mem.endsWith(u8, path, "abc.bcc"));
    try std.testing.expect(std.mem.indexOf(u8, path, ".cache") != null);
}

// 强制分析所有导入文件以包含其测试块（Zig 0.16 测试发现机制要求）
test {
    _ = serializer;
    _ = interface;
    _ = usage;
    _ = reloc_mod;
}
