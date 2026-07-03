//! Pass 2：函数纯度分析。
//!
//! 纯函数定义：不修改全局状态、不执行 IO、不调用 impure 函数。
//! 纯函数可安全做 memoization（相同参数→相同结果）。
//!
//! 算法：fixpoint 迭代——所有函数默认 pure，反复扫描函数体，
//! 若调用 impure 函数则降级，直到收敛。

const std = @import("std");
const ast = @import("ast");

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

/// Pass 2：函数纯度分析器
pub const PurityPass = struct {
    table: PurityTable,
    /// 已知纯函数名集合（迭代收敛后填充）
    pure_set: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PurityPass {
        return .{
            .table = PurityTable.init(allocator),
            .pure_set = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PurityPass) void {
        self.table.deinit();
        self.pure_set.deinit();
    }

    /// 分析模块：两遍迭代
    /// Pass 1: 所有函数默认标记 pure
    /// Pass 2: 遍历函数体，若调用 impure 函数则降级为 impure
    /// 重复 Pass 2 直到收敛（fixpoint）
    pub fn analyzeModule(self: *PurityPass, module: *const ast.Module) !void {
        // Pass 1: 所有 fun_decl 默认 pure
        for (module.declarations) |decl| {
            if (decl == .fun_decl) {
                try self.table.put(decl.fun_decl.name, .pure);
                try self.pure_set.put(decl.fun_decl.name, {});
            }
        }

        // Pass 2: 迭代到 fixpoint
        var changed = true;
        while (changed) {
            changed = false;
            for (module.declarations) |decl| {
                if (decl != .fun_decl) continue;
                const fd = decl.fun_decl;
                if (!self.table.isPure(fd.name)) continue; // 已 impure，跳过

                if (try self.exprHasImpureCall(fd.body, fd.name)) {
                    try self.table.put(fd.name, .impure);
                    _ = self.pure_set.remove(fd.name);
                    changed = true;
                }
            }
        }
    }

    /// 递归检查表达式是否包含 impure 调用
    fn exprHasImpureCall(self: *PurityPass, expr: *const ast.Expr, current_fn: []const u8) anyerror!bool {
        return switch (expr.*) {
            .int_literal,
            .float_literal,
            .bool_literal,
            .char_literal,
            .string_literal,
            .null_literal,
            .unit_literal,
            .identifier,
            => false,

            .binary => |b| try self.exprHasImpureCall(b.left, current_fn) or
                try self.exprHasImpureCall(b.right, current_fn),

            .unary => |u| try self.exprHasImpureCall(u.operand, current_fn),

            .call => |c| blk: {
                if (c.callee.* == .identifier) {
                    const name = c.callee.identifier.name;
                    // 自递归不 impure（已在本函数纯度判定中）
                    if (!std.mem.eql(u8, name, current_fn)) {
                        if (isImpureBuiltin(name)) break :blk true;
                        // 查纯度表：若不在 pure_set 中则 impure
                        if (!self.pure_set.contains(name)) break :blk true;
                    }
                } else {
                    // 间接调用（callee 非标识符）→ 保守 impure
                    if (try self.exprHasImpureCall(c.callee, current_fn)) break :blk true;
                    break :blk true;
                }
                for (c.arguments) |arg| {
                    if (try self.exprHasImpureCall(arg, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .method_call => true, // 方法调用保守视为 impure

            .field_access => |f| try self.exprHasImpureCall(f.object, current_fn),
            .safe_access => |f| try self.exprHasImpureCall(f.object, current_fn),
            .safe_method_call => true,
            .non_null_assert => |n| try self.exprHasImpureCall(n.expr, current_fn),
            .propagate => |p| try self.exprHasImpureCall(p.expr, current_fn),
            .index => |i| try self.exprHasImpureCall(i.object, current_fn) or
                try self.exprHasImpureCall(i.index, current_fn),

            .array_literal => |a| blk: {
                for (a.elements) |e| {
                    if (try self.exprHasImpureCall(e, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .record_literal => |r| blk: {
                for (r.fields) |f| {
                    if (try self.exprHasImpureCall(f.value, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .record_extend => |r| blk: {
                if (try self.exprHasImpureCall(r.base, current_fn)) break :blk true;
                for (r.updates) |u| {
                    if (try self.exprHasImpureCall(u.value, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .lambda => false,

            .if_expr => |i| try self.exprHasImpureCall(i.condition, current_fn) or
                try self.exprHasImpureCall(i.then_branch, current_fn) or
                (if (i.else_branch) |e| try self.exprHasImpureCall(e, current_fn) else false),

            .block => |b| blk: {
                for (b.statements) |s| {
                    if (try self.stmtHasImpureCall(s, current_fn)) break :blk true;
                }
                if (b.trailing_expr) |te| {
                    if (try self.exprHasImpureCall(te, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .match => |m| blk: {
                if (try self.exprHasImpureCall(m.scrutinee, current_fn)) break :blk true;
                for (m.arms) |arm| {
                    if (try self.exprHasImpureCall(arm.body, current_fn)) break :blk true;
                }
                break :blk false;
            },

            .type_cast => |t| try self.exprHasImpureCall(t.expr, current_fn),
            .spawn => true,
            .atomic_expr => |a| try self.exprHasImpureCall(a.value, current_fn),
            .lazy => |l| try self.exprHasImpureCall(l.expr, current_fn),
            .select => true,
            .inline_trait_value => true,

            .assignment_expr => |a| try self.exprHasImpureCall(a.target, current_fn) or
                try self.exprHasImpureCall(a.value, current_fn),

            .compound_assign => |c| try self.exprHasImpureCall(c.target, current_fn) or
                try self.exprHasImpureCall(c.value, current_fn),

            .string_interpolation => |si| blk: {
                for (si.parts) |part| {
                    if (part == .expression) {
                        if (try self.exprHasImpureCall(part.expression, current_fn)) break :blk true;
                    }
                }
                break :blk false;
            },
        };
    }

    fn stmtHasImpureCall(self: *PurityPass, stmt: *const ast.Stmt, current_fn: []const u8) anyerror!bool {
        return switch (stmt.*) {
            .val_decl => |v| try self.exprHasImpureCall(v.value, current_fn),
            .var_decl => |v| try self.exprHasImpureCall(v.value, current_fn),
            .assignment => true,
            .field_assignment => true,
            .compound_assignment => true,
            .expression => |e| try self.exprHasImpureCall(e.expr, current_fn),
            .return_stmt => |r| if (r.value) |v| try self.exprHasImpureCall(v, current_fn) else false,
            .defer_stmt => true,
            .throw_stmt => true,
            .break_stmt, .continue_stmt => false,
            .for_stmt => |f| try self.exprHasImpureCall(f.iterable, current_fn) or
                try self.exprHasImpureCall(f.body, current_fn),
            .while_stmt => |w| try self.exprHasImpureCall(w.condition, current_fn) or
                try self.exprHasImpureCall(w.body, current_fn),
            .loop_stmt => |l| try self.exprHasImpureCall(l.body, current_fn),
        };
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
