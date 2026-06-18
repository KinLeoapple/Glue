//! 全局字符串驻留表（string interning）
//!
//! 把变量/参数/字段名字符串映射成稠密 u32 id，使运行时环境(env.zig)用整数键取代
//! StringHashMap：消除每次 define 的 key dupe/free + 每次 lookup 的字符串哈希。
//!
//! 关键约束（见 plans/fluffy-riding-snowflake.md）：所有 intern 必须在求值开始前完成
//! （parse/init/load + resolve 预pass，单线程），求值期 interner 只读——因为 spawn 在
//! 独立 Heap 上并发求值，求值期写 interner 会产生数据竞争。
//!
//! 每个唯一名字全程只 dupe 一次（map 持有副本所有权），对比现状的「每次 define dupe」。

const std = @import("std");

pub const INVALID: u32 = 0xFFFF_FFFF;

pub const Interner = struct {
    /// name -> id。key 是 intern 时 dupe 的独立副本，interner 持有所有权。
    map: std.StringHashMap(u32),
    /// id -> name。索引即 id，元素借用 map 的 key（同一份 dupe，不重复分配）。
    names: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Interner {
        return Interner{
            .map = std.StringHashMap(u32).init(allocator),
            .names = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Interner) void {
        // names 借用 map 的 key，故只 free map 的 key 一次。
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
        self.names.deinit(self.allocator);
    }

    /// 驻留一个名字，返回其 id。命中返回旧 id；未命中 dupe 一次 + 追加 + 返回新 id。
    pub fn intern(self: *Interner, str: []const u8) !u32 {
        if (self.map.get(str)) |id| {
            return id;
        }
        const id: u32 = @intCast(self.names.items.len);
        const key = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(key);
        try self.map.put(key, id);
        try self.names.append(self.allocator, key);
        return id;
    }

    /// id -> 源名字（报错/调试用）。越界返回 "<invalid>"。
    pub fn name(self: *const Interner, id: u32) []const u8 {
        if (id >= self.names.items.len) return "<invalid>";
        return self.names.items[id];
    }
};

test "intern roundtrip 同名同 id" {
    var i = Interner.init(std.testing.allocator);
    defer i.deinit();
    const a = try i.intern("foo");
    const b = try i.intern("foo");
    try std.testing.expectEqual(a, b);
}

test "intern 不同名不同 id" {
    var i = Interner.init(std.testing.allocator);
    defer i.deinit();
    const a = try i.intern("foo");
    const b = try i.intern("bar");
    try std.testing.expect(a != b);
}

test "intern id->name 还原" {
    var i = Interner.init(std.testing.allocator);
    defer i.deinit();
    const a = try i.intern("hello");
    const b = try i.intern("world");
    try std.testing.expectEqualStrings("hello", i.name(a));
    try std.testing.expectEqualStrings("world", i.name(b));
    try std.testing.expectEqualStrings("<invalid>", i.name(9999));
}

test "intern id 从 0 稠密递增" {
    var i = Interner.init(std.testing.allocator);
    defer i.deinit();
    try std.testing.expectEqual(@as(u32, 0), try i.intern("a"));
    try std.testing.expectEqual(@as(u32, 1), try i.intern("b"));
    try std.testing.expectEqual(@as(u32, 2), try i.intern("c"));
    try std.testing.expectEqual(@as(u32, 0), try i.intern("a"));
}
