//! 函数纯度分析模块。
//!
//! 定义函数纯度信息（PurityInfo）与纯度表（PurityTable），用于记录每个函数
//! 是 pure / impure / unknown。纯度信息由 fused_analysis 在跨函数分析时计算，
//! 是常量传播、公共子表达式消除等优化能否安全施行的关键前提。

const std = @import("std");

/// 函数纯度分类：纯函数、非纯函数、未知。
pub const PurityInfo = enum {
    pure,
    impure,
    unknown,

    /// 是否为纯函数。
    pub fn isPure(self: PurityInfo) bool {
        return self == .pure;
    }
};

/// 函数名到纯度信息的映射表。
pub const PurityTable = struct {
    entries: std.StringHashMap(PurityInfo),
    /// 直接递归函数集合（函数体中调用自身的函数）
    /// memoization 仅对递归函数有益，非递归纯函数的开销 > 收益
    recursive_fns: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PurityTable {
        return .{
            .entries = std.StringHashMap(PurityInfo).init(allocator),
            .recursive_fns = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PurityTable) void {
        self.entries.deinit();
        self.recursive_fns.deinit();
    }

    pub fn put(self: *PurityTable, name: []const u8, info: PurityInfo) !void {
        try self.entries.put(name, info);
    }

    /// 标记函数为直接递归
    pub fn markRecursive(self: *PurityTable, name: []const u8) !void {
        try self.recursive_fns.put(name, {});
    }

    pub fn lookup(self: *const PurityTable, name: []const u8) ?PurityInfo {
        return self.entries.get(name);
    }

    /// 判断给定函数名是否为纯函数；未记录则视为非纯。
    pub fn isPure(self: *const PurityTable, name: []const u8) bool {
        if (self.lookup(name)) |info| return info.isPure();
        return false;
    }

    /// 判断给定函数名是否为直接递归函数
    pub fn isRecursive(self: *const PurityTable, name: []const u8) bool {
        return self.recursive_fns.contains(name);
    }

    /// 纯度表是否为空。
    pub fn isEmpty(self: *const PurityTable) bool {
        return self.entries.count() == 0;
    }
};

test "PurityTable basic put/lookup" {
    var table = PurityTable.init(std.testing.allocator);
    defer table.deinit();
    try table.put("fib", .pure);
    try table.put("println", .impure);
    try std.testing.expect(table.isPure("fib"));
    try std.testing.expect(!table.isPure("println"));
    try std.testing.expect(!table.isPure("unknown"));
}
