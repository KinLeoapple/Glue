//! Pass 3：静态调用图。
//!
//! 记录每个函数调用了哪些其他函数（按 func_idx）。
//! 用于递归检测、内联决策、memoization 安全性证明。

const std = @import("std");
const ast = @import("ast");

/// 调用图：func_idx → 被调用者 func_idx 列表
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

    pub fn addEdge(self: *CallGraph, caller: u16, callee: u16) !void {
        const gop = try self.edges.getOrPut(caller);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        // 去重
        for (gop.value_ptr.items) |existing| {
            if (existing == callee) return;
        }
        try gop.value_ptr.append(self.allocator, callee);
    }

    pub fn getCallees(self: *const CallGraph, caller: u16) []const u16 {
        if (self.edges.get(caller)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// 判断 caller 是否（直接或间接）调用 callee
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

    pub fn isEmpty(self: *const CallGraph) bool {
        return self.edges.count() == 0;
    }
};

/// Pass 3：静态调用图构建器
pub const CallGraphPass = struct {
    graph: CallGraph,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CallGraphPass {
        return .{
            .graph = CallGraph.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CallGraphPass) void {
        self.graph.deinit();
    }

    /// 分析模块，构建调用图。
    /// name_to_idx: 函数名 → func_idx 映射（由编译器第一遍填充）
    pub fn analyzeModule(
        self: *CallGraphPass,
        module: *const ast.Module,
        name_to_idx: *const std.StringHashMap(u16),
    ) !void {
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const fd = decl.fun_decl;
            const caller_idx = name_to_idx.get(fd.name) orelse continue;
            try self.collectCalls(fd.body, caller_idx, name_to_idx);
        }
    }

    fn collectCalls(
        self: *CallGraphPass,
        expr: *const ast.Expr,
        caller_idx: u16,
        name_to_idx: *const std.StringHashMap(u16),
    ) !void {
        switch (expr.*) {
            .call => |c| {
                if (c.callee.* == .identifier) {
                    if (name_to_idx.get(c.callee.identifier.name)) |callee_idx| {
                        try self.graph.addEdge(caller_idx, callee_idx);
                    }
                }
                try self.collectCalls(c.callee, caller_idx, name_to_idx);
                for (c.arguments) |arg| {
                    try self.collectCalls(arg, caller_idx, name_to_idx);
                }
            },
            .method_call => |mc| {
                try self.collectCalls(mc.object, caller_idx, name_to_idx);
                for (mc.arguments) |arg| {
                    try self.collectCalls(arg, caller_idx, name_to_idx);
                }
            },
            .binary => |b| {
                try self.collectCalls(b.left, caller_idx, name_to_idx);
                try self.collectCalls(b.right, caller_idx, name_to_idx);
            },
            .unary => |u| try self.collectCalls(u.operand, caller_idx, name_to_idx),
            .if_expr => |i| {
                try self.collectCalls(i.condition, caller_idx, name_to_idx);
                try self.collectCalls(i.then_branch, caller_idx, name_to_idx);
                if (i.else_branch) |e| try self.collectCalls(e, caller_idx, name_to_idx);
            },
            .block => |b| {
                for (b.statements) |s| {
                    try self.collectStmtCalls(s, caller_idx, name_to_idx);
                }
                if (b.trailing_expr) |te| try self.collectCalls(te, caller_idx, name_to_idx);
            },
            .match => |m| {
                try self.collectCalls(m.scrutinee, caller_idx, name_to_idx);
                for (m.arms) |arm| {
                    try self.collectCalls(arm.body, caller_idx, name_to_idx);
                }
            },
            .lambda => |l| {
                switch (l.body) {
                    .block_expr => |blk| {
                        for (blk.statements) |s| try self.collectStmtCalls(s, caller_idx, name_to_idx);
                        if (blk.trailing_expr) |te| try self.collectCalls(te, caller_idx, name_to_idx);
                    },
                    .expr_body => |e| try self.collectCalls(e, caller_idx, name_to_idx),
                }
            },
            .array_literal => |a| {
                for (a.elements) |e| try self.collectCalls(e, caller_idx, name_to_idx);
            },
            .record_literal => |r| {
                for (r.fields) |f| try self.collectCalls(f.value, caller_idx, name_to_idx);
            },
            .field_access => |f| try self.collectCalls(f.object, caller_idx, name_to_idx),
            .safe_access => |f| try self.collectCalls(f.object, caller_idx, name_to_idx),
            .index => |i| {
                try self.collectCalls(i.object, caller_idx, name_to_idx);
                try self.collectCalls(i.index, caller_idx, name_to_idx);
            },
            .spawn => |s| try self.collectCalls(s.body, caller_idx, name_to_idx),
            .atomic_expr => |a| try self.collectCalls(a.value, caller_idx, name_to_idx),
            .lazy => |l| try self.collectCalls(l.expr, caller_idx, name_to_idx),
            .type_cast => |t| try self.collectCalls(t.expr, caller_idx, name_to_idx),
            .non_null_assert => |n| try self.collectCalls(n.expr, caller_idx, name_to_idx),
            .propagate => |p| try self.collectCalls(p.expr, caller_idx, name_to_idx),
            .assignment_expr => |a| {
                try self.collectCalls(a.target, caller_idx, name_to_idx);
                try self.collectCalls(a.value, caller_idx, name_to_idx);
            },
            .compound_assign => |c| {
                try self.collectCalls(c.target, caller_idx, name_to_idx);
                try self.collectCalls(c.value, caller_idx, name_to_idx);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expr) try self.collectCalls(part.expr, caller_idx, name_to_idx);
                }
            },
            .record_extend => |r| {
                try self.collectCalls(r.base, caller_idx, name_to_idx);
                for (r.updates) |u| try self.collectCalls(u.value, caller_idx, name_to_idx);
            },
            .safe_method_call => |smc| {
                try self.collectCalls(smc.object, caller_idx, name_to_idx);
                for (smc.arguments) |arg| try self.collectCalls(arg, caller_idx, name_to_idx);
            },
            .select => |s| {
                for (s.arms) |arm| {
                    if (arm.body) |b| try self.collectCalls(b, caller_idx, name_to_idx);
                }
            },
            .inline_trait_value => {},
            .int_literal,
            .float_literal,
            .bool_literal,
            .char_literal,
            .string_literal,
            .null_literal,
            .unit_literal,
            .identifier,
            => {},
        }
    }

    fn collectStmtCalls(
        self: *CallGraphPass,
        stmt: *const ast.Stmt,
        caller_idx: u16,
        name_to_idx: *const std.StringHashMap(u16),
    ) !void {
        switch (stmt.*) {
            .val_decl => |v| try self.collectCalls(v.value, caller_idx, name_to_idx),
            .var_decl => |v| try self.collectCalls(v.value, caller_idx, name_to_idx),
            .assignment => |a| try self.collectCalls(a.value, caller_idx, name_to_idx),
            .field_assignment => |f| try self.collectCalls(f.value, caller_idx, name_to_idx),
            .compound_assignment => |c| try self.collectCalls(c.value, caller_idx, name_to_idx),
            .expression => |e| try self.collectCalls(e.expr, caller_idx, name_to_idx),
            .return_stmt => |r| if (r.value) |v| try self.collectCalls(v, caller_idx, name_to_idx),
            .defer_stmt => |d| try self.collectCalls(d.expr, caller_idx, name_to_idx),
            .throw_stmt => |t| try self.collectCalls(t.expr, caller_idx, name_to_idx),
            .break_stmt, .continue_stmt => {},
            .for_stmt => |f| {
                try self.collectCalls(f.iterable, caller_idx, name_to_idx);
                try self.collectCalls(f.body, caller_idx, name_to_idx);
            },
            .while_stmt => |w| {
                try self.collectCalls(w.condition, caller_idx, name_to_idx);
                try self.collectCalls(w.body, caller_idx, name_to_idx);
            },
            .loop_stmt => |l| try self.collectCalls(l.body, caller_idx, name_to_idx),
        }
    }
};

test "CallGraph basic edges" {
    var cg = CallGraph.init(std.testing.allocator);
    defer cg.deinit();
    try cg.addEdge(0, 1);
    try cg.addEdge(1, 2);
    try cg.addEdge(0, 1); // 去重
    const callees = cg.getCallees(0);
    try std.testing.expectEqual(@as(usize, 1), callees.len);
    try std.testing.expectEqual(@as(u16, 1), callees[0]);
    try std.testing.expect(cg.callsTransitively(0, 2));
    try std.testing.expect(!cg.callsTransitively(2, 0));
}
