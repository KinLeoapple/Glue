//! 常量传播模块。
//!
//! 提供常量值表示（ConstValue）、表达式常量表（ConstTable）和作用域常量环境
//! （ConstEnv），以及二元 / 一元运算的常量折叠辅助函数。常量传播是其他优化
//! （分支可达性、CSE 等）的基础数据来源，由 fused_analysis 在跨函数分析时
//! 将结果写入 ConstTable。

const std = @import("std");
const ast = @import("ast");

/// 编译期可追踪的常量值。unknown 表示该表达式无法折叠为常量。
pub const ConstValue = union(enum) {
    int_val: i128,
    float_val: f64,
    bool_val: bool,
    unknown,

    /// 是否为整型常量。
    pub fn isInt(self: ConstValue) bool {
        return self == .int_val;
    }

    /// 是否为布尔常量。
    pub fn isBool(self: ConstValue) bool {
        return self == .bool_val;
    }
};

/// 表达式到常量值的映射表。键为 AST 表达式指针，值为折叠后的常量。
pub const ConstTable = struct {
    entries: std.AutoHashMap(*const ast.Expr, ConstValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstTable {
        return .{
            .entries = std.AutoHashMap(*const ast.Expr, ConstValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *ConstTable, expr: *const ast.Expr, val: ConstValue) !void {
        try self.entries.put(expr, val);
    }

    pub fn lookup(self: *const ConstTable, expr: *const ast.Expr) ?ConstValue {
        return self.entries.get(expr);
    }

    /// 常量表是否为空。
    pub fn isEmpty(self: *const ConstTable) bool {
        return self.entries.count() == 0;
    }
};

/// 作用域常量环境。通过 parent 指针形成词法作用域链，用于跟踪变量名到常量值的绑定。
pub const ConstEnv = struct {
    parent: ?*ConstEnv,
    locals: std.StringHashMap(ConstValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*ConstEnv) ConstEnv {
        return .{
            .parent = parent,
            .locals = std.StringHashMap(ConstValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstEnv) void {
        self.locals.deinit();
    }

    /// 沿作用域链查找变量名对应的常量值。
    pub fn get(self: *const ConstEnv, name: []const u8) ?ConstValue {
        var cur: ?*const ConstEnv = self;
        while (cur) |e| {
            if (e.locals.get(name)) |v| return v;
            cur = e.parent;
        }
        return null;
    }

    pub fn put(self: *ConstEnv, name: []const u8, val: ConstValue) !void {
        try self.locals.put(name, val);
    }

    /// 移除变量绑定，用于变量被重新赋值为非常量时。
    pub fn remove(self: *ConstEnv, name: []const u8) void {
        _ = self.locals.remove(name);
    }
};


