//! 模块导出接口：本模块导出的所有符号及其签名 hash。
//!
//! 用于跨模块缓存失效判定：当模块 M 的接口 hash 变化时，
//! 依赖 M 的模块的 usage 中对应符号的 sig 不再匹配，触发重编。
//!
//! 签名生成策略：
//! - fun_decl: 复用 TypeScheme 的 Type.formatArrayList 完整序列化 Type 树
//! - type_decl: name + type_params + TypeDef 形状 + methods 签名
//! - trait_decl: name + type_params + parents + methods 签名
//! - pack_decl: 子模块，sig_hash = 0

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");
const reloc_mod = @import("reloc.zig");

const Type = type_check.Type;
const TypeScheme = type_check.TypeScheme;
const TypeInferencer = type_check.TypeInferencer;

/// 符号种类
pub const SymbolKind = enum(u8) {
    function,
    type_decl,
    trait_decl,
    trait_impl,
    submodule,
};

/// 单个导出符号的签名
pub const ExportedSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
    sig_hash: u64,
};

/// 模块导出接口
pub const ModuleInterface = struct {
    module_name: []const u8,
    symbols: std.ArrayListUnmanaged(ExportedSymbol) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8) ModuleInterface {
        return .{
            .allocator = allocator,
            .module_name = module_name,
        };
    }

    pub fn deinit(self: *ModuleInterface) void {
        self.symbols.deinit(self.allocator);
    }

    pub fn addSymbol(self: *ModuleInterface, name: []const u8, kind: SymbolKind, sig_hash: u64) !void {
        try self.symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .sig_hash = sig_hash,
        });
    }

    /// 查找符号的 sig_hash
    pub fn lookupHash(self: *const ModuleInterface, name: []const u8, kind: SymbolKind) ?u64 {
        for (self.symbols.items) |s| {
            if (s.kind == kind and std.mem.eql(u8, s.name, name)) return s.sig_hash;
        }
        return null;
    }

    /// 计算整个接口的 hash（用于快速比对）
    pub fn interfaceHash(self: *const ModuleInterface) u64 {
        var hash: u64 = 0xCBF29CE484222325;
        for (self.symbols.items) |s| {
            for (s.name) |b| {
                hash ^= b;
                hash *%= 0x100000001B3;
            }
            hash ^= @intFromEnum(s.kind);
            hash *%= 0x100000001B3;
            hash ^= s.sig_hash;
            hash *%= 0x100000001B3;
        }
        return hash;
    }

    /// 序列化到 buffer: module_name + u32 count + symbols
    pub fn writeBytes(self: *const ModuleInterface, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try writeOwnedStr(buf, allocator, self.module_name);
        const count: u32 = @intCast(self.symbols.items.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&count));
        for (self.symbols.items) |s| {
            try writeOwnedStr(buf, allocator, s.name);
            try buf.appendSlice(allocator, std.mem.asBytes(&s.kind));
            try buf.appendSlice(allocator, std.mem.asBytes(&s.sig_hash));
        }
    }

    /// 从光标反序列化（name 为 owned，需调用方 deinit）
    pub fn readBytes(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !ModuleInterface {
        const module_name = try readOwnedStr(allocator, cur);
        var iface = ModuleInterface.init(allocator, module_name);
        var count: u32 = undefined;
        try cur.read(std.mem.asBytes(&count));
        try iface.symbols.ensureTotalCapacity(allocator, count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const name = try readOwnedStr(allocator, cur);
            var kind: SymbolKind = undefined;
            try cur.read(std.mem.asBytes(&kind));
            var sig_hash: u64 = undefined;
            try cur.read(std.mem.asBytes(&sig_hash));
            try iface.symbols.append(allocator, .{
                .name = name,
                .kind = kind,
                .sig_hash = sig_hash,
            });
        }
        return iface;
    }

    /// 释放反序列化分配的 owned 字符串
    pub fn freeOwned(self: *ModuleInterface) void {
        for (self.symbols.items) |s| self.allocator.free(s.name);
        self.allocator.free(self.module_name);
    }
};

/// FNV-1a 64 hash
pub fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = 0xCBF29CE484222325;
    for (data) |b| {
        hash ^= b;
        hash *%= 0x100000001B3;
    }
    return hash;
}

// ============================================================
// 签名字符串生成
// ============================================================

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

/// TypeScheme 转签名字符串（复用 Type.formatArrayList 完整序列化 Type 树）
fn schemeToSigString(allocator: std.mem.Allocator, scheme: TypeScheme) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "qv:{d}|bounds:{d}|", .{ scheme.quantified_vars.len, scheme.bounds.len });
    for (scheme.bounds) |b| {
        try buf.print(allocator, "{s}:{d},", .{ b.trait_name, b.type_param_index });
    }
    try scheme.ty.*.formatArrayList(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

/// type_decl 转签名字符串（name + type_params + TypeDef 形状 + methods）
fn typeDeclToSigString(allocator: std.mem.Allocator, td: anytype) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "type:{s}:params:{d}:def:", .{ td.name, td.type_params.len });
    switch (td.def) {
        .adt => |a| {
            try buf.appendSlice(allocator, "adt:");
            try buf.print(allocator, "{d}", .{a.constructors.len});
            for (a.constructors) |c| {
                try buf.print(allocator, ",{s}:{d}", .{ c.name, c.fields.len });
            }
        },
        .record => |r| {
            try buf.appendSlice(allocator, "rec:");
            try buf.print(allocator, "{d}", .{r.fields.len});
            for (r.fields) |f| {
                try buf.print(allocator, ",{s}", .{f.name});
            }
        },
        .alias => try buf.appendSlice(allocator, "alias"),
        .newtype => |nt| try buf.print(allocator, "newtype:{s}", .{nt.name}),
        .error_newtype => |en| try buf.print(allocator, "err_newtype:{s}:{d}", .{ en.name, en.params.len }),
    }
    try buf.print(allocator, ":methods:{d}", .{td.methods.len});
    for (td.methods) |m| {
        try buf.print(allocator, ",{s}:{d}", .{ m.name, m.params.len });
    }
    return buf.toOwnedSlice(allocator);
}

/// trait_decl 转签名字符串
fn traitDeclToSigString(allocator: std.mem.Allocator, trd: anytype) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "trait:{s}:params:{d}:parents:{d}:methods:{d}", .{
        trd.name, trd.type_params.len, trd.parents.len, trd.methods.len,
    });
    for (trd.methods) |m| {
        try buf.print(allocator, ",{s}:{d}", .{ m.name, m.params.len });
    }
    return buf.toOwnedSlice(allocator);
}

/// 从 AST + TypeInferencer 提取模块接口
pub fn extractInterface(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    inferencer: *const TypeInferencer,
) !ModuleInterface {
    var iface = ModuleInterface.init(allocator, module.name);
    for (module.declarations) |decl| {
        switch (decl) {
            .fun_decl => |fd| {
                if (fd.visibility == .public) {
                    const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ module.name, fd.name });
                    defer allocator.free(key);
                    if (inferencer.exported_schemes.get(key)) |scheme| {
                        const sig = try schemeToSigString(allocator, scheme);
                        defer allocator.free(sig);
                        try iface.addSymbol(fd.name, .function, fnv1a64(sig));
                    }
                }
            },
            .type_decl => |td| {
                if (td.visibility == .public) {
                    const sig = try typeDeclToSigString(allocator, td);
                    defer allocator.free(sig);
                    try iface.addSymbol(td.name, .type_decl, fnv1a64(sig));
                }
            },
            .trait_decl => |trd| {
                if (trd.visibility == .public) {
                    const sig = try traitDeclToSigString(allocator, trd);
                    defer allocator.free(sig);
                    try iface.addSymbol(trd.name, .trait_decl, fnv1a64(sig));
                }
            },
            .pack_decl => |pd| {
                if (pd.visibility == .public) {
                    try iface.addSymbol(pd.name, .submodule, 0);
                }
            },
            else => {},
        }
    }
    return iface;
}

// ============================================================
// 测试
// ============================================================

test "ModuleInterface basic add/lookup" {
    var iface = ModuleInterface.init(std.testing.allocator, "test");
    defer iface.deinit();
    try iface.addSymbol("foo", .function, 12345);
    try iface.addSymbol("Bar", .type_decl, 67890);
    try std.testing.expect(iface.lookupHash("foo", .function) != null);
    try std.testing.expect(iface.lookupHash("baz", .function) == null);
    try std.testing.expect(iface.interfaceHash() != 0);
}

test "ModuleInterface 序列化往返" {
    var iface = ModuleInterface.init(std.testing.allocator, "Mod");
    defer iface.deinit();
    try iface.addSymbol("fn1", .function, 0xAAAA);
    try iface.addSymbol("Type2", .type_decl, 0xBBBB);
    try iface.addSymbol("Trait3", .trait_decl, 0xCCCC);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try iface.writeBytes(&buf, std.testing.allocator);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    var iface2 = try ModuleInterface.readBytes(std.testing.allocator, &cur);
    defer {
        iface2.freeOwned();
        iface2.deinit();
    }
    try std.testing.expectEqualStrings("Mod", iface2.module_name);
    try std.testing.expectEqual(@as(usize, 3), iface2.symbols.items.len);
    try std.testing.expectEqual(@as(u64, 0xAAAA), iface2.symbols.items[0].sig_hash);
    try std.testing.expectEqualStrings("Type2", iface2.symbols.items[1].name);
    try std.testing.expectEqual(SymbolKind.trait_decl, iface2.symbols.items[2].kind);
}

test "fnv1a64 稳定性" {
    const h1 = fnv1a64("hello");
    const h2 = fnv1a64("hello");
    const h3 = fnv1a64("world");
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}
