//! 模块源接口（v3 阶段 13）
//!
//! 统一 stdlib embedFile 源与用户文件系统源的读取接口，
//! 消除 module_loader.zig 中 loadStdlibPack/loadUserPack 的重复骨架。
//!
//! 每个 ModuleSource 实现提供：
//! - readSource(path) → 源字节切片（失败返回 null，不抛 error）
//! - modulePrefix() → mangling 前缀（"std.<pack>" 或 "<module>"）
//! - subModuleKey(sub_name) → 去重 key（"<pack>/<sub>" 或 "<module>/<sub>"）
//! - isStdlib() → 是否为 stdlib 源（决定是否递归处理 transitive imports）
//! - freeSource(bytes) → 释放源字节（stdlib embedFile 不释放，user fs 需释放）

const std = @import("std");
const std_embed = @import("std_embed");

/// 模块源接口（vtable）
pub const ModuleSource = struct {
    /// 读取源文件内容。返回 null 表示文件不存在或读取失败。
    /// 返回的切片生命周期由 freeSource 管理。
    readSource: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8,
    /// 释放 readSource 返回的切片。stdlib embedFile 源为 no-op。
    freeSource: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8) void,
    /// mangling 前缀（"std.<pack>" 或 "<module>"）
    modulePrefix: *const fn (ctx: *anyopaque) []const u8,
    /// 子模块去重 key（"<pack>/<sub>" 或 "<module>/<sub>"）
    subModuleKey: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, sub_name: []const u8) []const u8,
    /// 是否为 stdlib 源（决定递归处理 transitive imports）
    isStdlib: *const fn (ctx: *anyopaque) bool,
    /// 类型擦除上下文
    ctx: *anyopaque,
};

/// stdlib 源：从 @embedFile 表读取
pub const StdlibSource = struct {
    pack_name: []const u8,
    module_prefix: []const u8, // "std.<pack>"

    pub fn init(pack_name: []const u8, module_prefix: []const u8) StdlibSource {
        return .{ .pack_name = pack_name, .module_prefix = module_prefix };
    }

    fn readSource(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        _ = allocator;
        _ = ctx;
        // std_embed.find 返回 @embedFile 的 const 数据，无需释放
        return std_embed.find(path);
    }

    fn freeSource(ctx: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8) void {
        _ = ctx;
        _ = allocator;
        _ = bytes;
        // embedFile 数据不需要释放
    }

    fn modulePrefix(ctx: *anyopaque) []const u8 {
        const self: *StdlibSource = @ptrCast(@alignCast(ctx));
        return self.module_prefix;
    }

    fn subModuleKey(ctx: *anyopaque, allocator: std.mem.Allocator, sub_name: []const u8) []const u8 {
        const self: *StdlibSource = @ptrCast(@alignCast(ctx));
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.pack_name, sub_name }) catch sub_name;
    }

    fn isStdlib(ctx: *anyopaque) bool {
        _ = ctx;
        return true;
    }

    pub fn source(self: *StdlibSource) ModuleSource {
        return .{
            .readSource = readSource,
            .freeSource = freeSource,
            .modulePrefix = modulePrefix,
            .subModuleKey = subModuleKey,
            .isStdlib = isStdlib,
            .ctx = @ptrCast(self),
        };
    }
};

/// 用户文件系统源
pub const UserSource = struct {
    module_name: []const u8,
    source_dir_with_sep: []const u8,
    io: std.Io,
    dir: std.Io.Dir,

    pub fn init(module_name: []const u8, source_dir_with_sep: []const u8, io: std.Io, dir: std.Io.Dir) UserSource {
        return .{
            .module_name = module_name,
            .source_dir_with_sep = source_dir_with_sep,
            .io = io,
            .dir = dir,
        };
    }

    fn readSource(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *UserSource = @ptrCast(@alignCast(ctx));
        return self.dir.readFileAlloc(self.io, path, allocator, .unlimited) catch null;
    }

    fn freeSource(ctx: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8) void {
        _ = ctx;
        allocator.free(bytes);
    }

    fn modulePrefix(ctx: *anyopaque) []const u8 {
        const self: *UserSource = @ptrCast(@alignCast(ctx));
        return self.module_name;
    }

    fn subModuleKey(ctx: *anyopaque, allocator: std.mem.Allocator, sub_name: []const u8) []const u8 {
        const self: *UserSource = @ptrCast(@alignCast(ctx));
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.module_name, sub_name }) catch sub_name;
    }

    fn isStdlib(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }

    pub fn source(self: *UserSource) ModuleSource {
        return .{
            .readSource = readSource,
            .freeSource = freeSource,
            .modulePrefix = modulePrefix,
            .subModuleKey = subModuleKey,
            .isStdlib = isStdlib,
            .ctx = @ptrCast(self),
        };
    }
};
