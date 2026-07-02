//! 类型表：表达式指针 → 推断出的类型种类。
//!
//! 由 Pass 0 在 type_check 完成后填充，供编译器查询操作数类型做特化。
//! 使用指针哈希，零侵入 AST，查询均摊 O(1)。
//!
//! 设计决策：内部存储 TypeKind（int/float/other）而非 *type_check.Type 指针，
//! 使本模块完全解耦于 type_check 模块——仅依赖 ast，可被 type_check 与 vm 同时导入，
//! 无循环依赖。Phase 1 仅需 Int/Float 区分，TypeKind 足够；未来若需更细粒度
//! （如宽度信息），可扩展 TypeKind 或新增字段而无需破坏公共接口。

const std = @import("std");
const ast = @import("ast");

/// 表达式的类型种类（用于特化 opcode 选择）。
pub const TypeKind = enum {
    /// 任意宽度整数（i8..i128, u8..u128）
    int,
    /// 任意宽度浮点（f16, f32, f64, f128）
    float,
    /// 其他类型（bool/str/char/record/adt/函数/未知等），不触发算术特化
    other,

    pub fn isInt(self: TypeKind) bool {
        return self == .int;
    }

    pub fn isFloat(self: TypeKind) bool {
        return self == .float;
    }
};

/// 类型表：表达式指针 → TypeKind。
/// 由 Pass 0 在 type_check 完成后填充，供编译器查询操作数类型做特化。
/// 使用指针哈希，零侵入 AST，查询均摊 O(1)。
pub const TypeTable = struct {
    entries: std.AutoHashMap(*const ast.Expr, TypeKind),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Expr, TypeKind).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeTable) void {
        self.entries.deinit();
    }

    /// 记录表达式的推断类型种类。
    pub fn put(self: *TypeTable, expr: *const ast.Expr, kind: TypeKind) !void {
        try self.entries.put(expr, kind);
    }

    /// 查询表达式的推断类型种类。未记录返回 null（编译器 fallback 到通用 opcode）。
    pub fn lookup(self: *const TypeTable, expr: *const ast.Expr) ?TypeKind {
        return self.entries.get(expr);
    }

    /// 判断表达式是否为整数类型（任意宽度）。
    pub fn isInt(self: *const TypeTable, expr: *const ast.Expr) bool {
        if (self.lookup(expr)) |kind| {
            return kind.isInt();
        }
        return false;
    }

    /// 判断表达式是否为浮点类型（任意宽度）。
    pub fn isFloat(self: *const TypeTable, expr: *const ast.Expr) bool {
        if (self.lookup(expr)) |kind| {
            return kind.isFloat();
        }
        return false;
    }
};

test "TypeTable basic put/lookup" {
    var table = TypeTable.init(std.testing.allocator);
    defer table.deinit();

    // 构造一个假 Expr 指针（unit_literal 是最简单的 Expr 变体）
    var dummy_expr: ast.Expr = .{ .unit_literal = .{ .line = 0, .column = 0 } };

    try table.put(&dummy_expr, .int);
    try std.testing.expect(table.lookup(&dummy_expr) != null);
    try std.testing.expect(table.isInt(&dummy_expr));
    try std.testing.expect(!table.isFloat(&dummy_expr));
}

test "TypeTable lookup missing returns null" {
    var table = TypeTable.init(std.testing.allocator);
    defer table.deinit();

    var dummy_expr: ast.Expr = .{ .unit_literal = .{ .line = 0, .column = 0 } };
    try std.testing.expect(table.lookup(&dummy_expr) == null);
    try std.testing.expect(!table.isInt(&dummy_expr));
    try std.testing.expect(!table.isFloat(&dummy_expr));
}

test "TypeKind helpers" {
    try std.testing.expect(TypeKind.int.isInt());
    try std.testing.expect(!TypeKind.int.isFloat());
    try std.testing.expect(TypeKind.float.isFloat());
    try std.testing.expect(!TypeKind.float.isInt());
    try std.testing.expect(!TypeKind.other.isInt());
    try std.testing.expect(!TypeKind.other.isFloat());
}
