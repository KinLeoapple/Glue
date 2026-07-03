//! 符号使用记录：本模块实际用到的导入符号及其签名 hash。
//!
//! 在 type_check 的 importUseDecl 中埋点：每次从导入模块解析一个符号，
//! 记录 (导入路径, 符号名, 符号种类, 当时的 sig_hash)。
//!
//! 缓存命中判定：usage 中所有符号的 sig_hash 必须与被依赖模块当前接口的 sig_hash 匹配。

const std = @import("std");
const interface_mod = @import("interface.zig");
const reloc_mod = @import("reloc.zig");

/// 单条使用记录
pub const UsageEntry = struct {
    module_path: []const u8,
    symbol_name: []const u8,
    kind: interface_mod.SymbolKind,
    /// 使用时的 sig_hash（来自被依赖模块当时的接口）
    sig_hash: u64,
};

/// 符号使用表
pub const SymbolUsage = struct {
    entries: std.ArrayListUnmanaged(UsageEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolUsage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SymbolUsage) void {
        // entries 中的 module_path / symbol_name 为 owned（record 时 dupe）
        for (self.entries.items) |e| {
            self.allocator.free(e.module_path);
            self.allocator.free(e.symbol_name);
        }
        self.entries.deinit(self.allocator);
    }

    /// 记录一次符号使用（去重：同 module+name+kind 只保留首次）
    /// module_path / symbol_name 会被 dupe 为 owned
    pub fn record(
        self: *SymbolUsage,
        module_path: []const u8,
        symbol_name: []const u8,
        kind: interface_mod.SymbolKind,
        sig_hash: u64,
    ) !void {
        for (self.entries.items) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.module_path, module_path) and std.mem.eql(u8, e.symbol_name, symbol_name)) {
                return; // 已记录
            }
        }
        const mp = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(mp);
        const sn = try self.allocator.dupe(u8, symbol_name);
        errdefer self.allocator.free(sn);
        try self.entries.append(self.allocator, .{
            .module_path = mp,
            .symbol_name = sn,
            .kind = kind,
            .sig_hash = sig_hash,
        });
    }

    /// 校验：所有使用记录的 sig_hash 是否仍与被依赖模块当前接口匹配
    /// interfaces: 模块名 → ModuleInterface
    pub fn verifyAll(self: *const SymbolUsage, interfaces: *const std.StringHashMap(interface_mod.ModuleInterface)) bool {
        for (self.entries.items) |e| {
            const iface = interfaces.get(e.module_path) orelse return false;
            const current_hash = iface.lookupHash(e.symbol_name, e.kind) orelse return false;
            if (current_hash != e.sig_hash) return false;
        }
        return true;
    }

    /// 序列化到 buffer: u32 count + entries
    pub fn writeBytes(self: *const SymbolUsage, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        const count: u32 = @intCast(self.entries.items.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&count));
        for (self.entries.items) |e| {
            try writeOwnedStr(buf, allocator, e.module_path);
            try writeOwnedStr(buf, allocator, e.symbol_name);
            try buf.appendSlice(allocator, std.mem.asBytes(&e.kind));
            try buf.appendSlice(allocator, std.mem.asBytes(&e.sig_hash));
        }
    }

    /// 从光标反序列化（module_path / symbol_name 为 owned）
    pub fn readBytes(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !SymbolUsage {
        var usage = SymbolUsage.init(allocator);
        var count: u32 = undefined;
        try cur.read(std.mem.asBytes(&count));
        try usage.entries.ensureTotalCapacity(allocator, count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const mp = try readOwnedStr(allocator, cur);
            const sn = try readOwnedStr(allocator, cur);
            var kind: interface_mod.SymbolKind = undefined;
            try cur.read(std.mem.asBytes(&kind));
            var sig_hash: u64 = undefined;
            try cur.read(std.mem.asBytes(&sig_hash));
            try usage.entries.append(allocator, .{
                .module_path = mp,
                .symbol_name = sn,
                .kind = kind,
                .sig_hash = sig_hash,
            });
        }
        return usage;
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

// ============================================================
// 测试
// ============================================================

test "SymbolUsage record + verify" {
    var usage = SymbolUsage.init(std.testing.allocator);
    defer usage.deinit();
    try usage.record("Mod", "foo", .function, 12345);

    var interfaces = std.StringHashMap(interface_mod.ModuleInterface).init(std.testing.allocator);
    defer {
        var it = interfaces.valueIterator();
        while (it.next()) |iface| iface.deinit();
        interfaces.deinit();
    }
    var iface = interface_mod.ModuleInterface.init(std.testing.allocator, "Mod");
    try iface.addSymbol("foo", .function, 12345);
    try interfaces.put("Mod", iface);

    try std.testing.expect(usage.verifyAll(&interfaces));

    // 修改签名 hash → 不匹配
    interfaces.getPtr("Mod").?.symbols.items[0].sig_hash = 99999;
    try std.testing.expect(!usage.verifyAll(&interfaces));
}

test "SymbolUsage 去重" {
    var usage = SymbolUsage.init(std.testing.allocator);
    defer usage.deinit();
    try usage.record("Mod", "foo", .function, 1);
    try usage.record("Mod", "foo", .function, 1); // 重复
    try usage.record("Mod", "bar", .function, 2);
    try std.testing.expectEqual(@as(usize, 2), usage.entries.items.len);
}

test "SymbolUsage 序列化往返" {
    var usage = SymbolUsage.init(std.testing.allocator);
    defer usage.deinit();
    try usage.record("Collections", "Map", .type_decl, 0xAAAA);
    try usage.record("Utils", "hash", .function, 0xBBBB);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try usage.writeBytes(&buf, std.testing.allocator);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    var usage2 = try SymbolUsage.readBytes(std.testing.allocator, &cur);
    defer usage2.deinit();

    try std.testing.expectEqual(@as(usize, 2), usage2.entries.items.len);
    try std.testing.expectEqualStrings("Collections", usage2.entries.items[0].module_path);
    try std.testing.expectEqualStrings("Map", usage2.entries.items[0].symbol_name);
    try std.testing.expectEqual(interface_mod.SymbolKind.type_decl, usage2.entries.items[0].kind);
    try std.testing.expectEqual(@as(u64, 0xBBBB), usage2.entries.items[1].sig_hash);
}
