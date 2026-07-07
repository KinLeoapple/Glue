//! Pass 2：函数纯度分析。
//!
//! 纯函数定义：不修改全局状态、不执行 IO、不调用 impure 函数。
//! 纯函数可安全做 memoization（相同参数→相同结果）。
//!
//! 算法：fixpoint 迭代——所有函数默认 pure，反复扫描函数体，
//! 若调用 impure 函数则降级，直到收敛。

const std = @import("std");

/// 函数纯度信息
pub const PurityInfo = enum {
    /// 纯函数：无副作用，可 memoize
    pure,
    /// 不纯函数：有副作用
    impure,
    /// 未知（保守视为 impure）
    unknown,

    pub fn isPure(self: PurityInfo) bool {
        return self == .pure;
    }
};

/// 纯度表：函数名 → PurityInfo
pub const PurityTable = struct {
    entries: std.StringHashMap(PurityInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PurityTable {
        return .{
            .entries = std.StringHashMap(PurityInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PurityTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *PurityTable, name: []const u8, info: PurityInfo) !void {
        try self.entries.put(name, info);
    }

    pub fn lookup(self: *const PurityTable, name: []const u8) ?PurityInfo {
        return self.entries.get(name);
    }

    pub fn isPure(self: *const PurityTable, name: []const u8) bool {
        if (self.lookup(name)) |info| return info.isPure();
        return false;
    }

    pub fn isEmpty(self: *const PurityTable) bool {
        return self.entries.count() == 0;
    }
};

/// 已知的 impure 内建函数名
const impure_builtins = [_][]const u8{
    "println", "print", "eprintln", "eprint",
    "spawn",   "lazy",  "select",   "send",   "recv",
};

fn isImpureBuiltin(name: []const u8) bool {
    for (impure_builtins) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

test "PurityTable basic put/lookup" {
    var table = PurityTable.init(std.testing.allocator);
    defer table.deinit();
    try table.put("fib", .pure);
    try table.put("println", .impure);
    try std.testing.expect(table.isPure("fib"));
    try std.testing.expect(!table.isPure("println"));
    try std.testing.expect(!table.isPure("unknown"));
}
