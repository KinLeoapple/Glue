//! 函数调用图模块。
//!
//! 以函数索引（u16）为节点维护 caller -> callee 的边集合，支持添加边、
//! 查询直接被调用者，以及判断两个函数之间是否存在传递性调用关系。
//! 该调用图用于纯度分析等需要跨函数传播信息的场景。

const std = @import("std");

/// 调用图：以 u16 函数索引为键，值为该函数直接调用的被调用者列表。
pub const CallGraph = struct {
    edges: std.AutoHashMap(u16, std.ArrayListUnmanaged(u16)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CallGraph {
        return .{
            .edges = std.AutoHashMap(u16, std.ArrayListUnmanaged(u16)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CallGraph) void {
        var it = self.edges.valueIterator();
        while (it.next()) |callees| {
            callees.deinit(self.allocator);
        }
        self.edges.deinit();
    }

    /// 添加一条 caller -> callee 的边，已存在则去重。
    pub fn addEdge(self: *CallGraph, caller: u16, callee: u16) !void {
        const gop = try self.edges.getOrPut(caller);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (existing == callee) return;
        }
        try gop.value_ptr.append(self.allocator, callee);
    }

    /// 返回某函数直接调用的全部被调用者；无记录则返回空切片。
    pub fn getCallees(self: *const CallGraph, caller: u16) []const u16 {
        if (self.edges.get(caller)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// 判断 caller 是否（直接或传递性地）调用 callee。
    /// 通过 visited 集合避免环路上无限递归。
    pub fn callsTransitively(self: *const CallGraph, caller: u16, callee: u16) bool {
        var visited = std.AutoHashMap(u16, void).init(self.allocator);
        defer visited.deinit();
        return self.callsTransitivelyImpl(caller, callee, &visited);
    }

    fn callsTransitivelyImpl(
        self: *const CallGraph,
        caller: u16,
        callee: u16,
        visited: *std.AutoHashMap(u16, void),
    ) bool {
        if (caller == callee) return true;
        if (visited.contains(caller)) return false;
        visited.put(caller, {}) catch return false;
        for (self.getCallees(caller)) |c| {
            if (c == callee) return true;
            if (self.callsTransitivelyImpl(c, callee, visited)) return true;
        }
        return false;
    }

    /// 调用图是否为空（无边）。
    pub fn isEmpty(self: *const CallGraph) bool {
        return self.edges.count() == 0;
    }
};

test "CallGraph basic edges" {
    var cg = CallGraph.init(std.testing.allocator);
    defer cg.deinit();
    try cg.addEdge(0, 1);
    try cg.addEdge(1, 2);
    try cg.addEdge(0, 1);
    const callees = cg.getCallees(0);
    try std.testing.expectEqual(@as(usize, 1), callees.len);
    try std.testing.expectEqual(@as(u16, 1), callees[0]);
    try std.testing.expect(cg.callsTransitively(0, 2));
    try std.testing.expect(!cg.callsTransitively(2, 0));
}
