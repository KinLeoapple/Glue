//! Glue 语言变量环境
//!
//! 管理变量绑定和词法作用域，支持：
//! - 不可变（val）和可变（var）变量
//! - 嵌套作用域（父子环境链）
//! - 变量查找沿父链向上遍历

const std = @import("std");
const value = @import("value");

/// 变量绑定
pub const Variable = struct {
    value: value.Value,
    is_mutable: bool,
    /// 是否对外公开（pub 声明）
    /// 抽象类型：pub type Handle = Handle(i32) — 类型名公开，构造器私有
    is_public: bool = false,
};

/// 变量环境（词法作用域）
pub const Environment = struct {
    values: std.StringHashMap(Variable),
    parent: ?*Environment,
    children: std.ArrayList(*Environment),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return Environment{
            .values = std.StringHashMap(Variable).init(allocator),
            .parent = null,
            .children = std.ArrayList(*Environment).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        // 递归释放子环境（LIFO 顺序）
        var i: usize = self.children.items.len;
        while (i > 0) {
            i -= 1;
            var child = self.children.items[i];
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);

        // 释放值中的堆分配数据
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.value;
            val.deinit(self.allocator);
        }
        self.values.deinit();
    }

    pub fn define(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool) !void {
        return self.defineWithVisibility(name, val, is_mutable, false);
    }

    pub fn defineWithVisibility(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool, is_public: bool) !void {
        // 如果已存在，先移除旧条目并释放旧 key 和旧值
        if (self.values.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            var old_val = old.value.value;
            old_val.deinit(self.allocator);
        }
        // 插入新条目（需要分配 key 的独立副本）
        const key = try self.allocator.dupe(u8, name);
        try self.values.put(key, Variable{ .value = val, .is_mutable = is_mutable, .is_public = is_public });
    }

    pub fn get(self: *Environment, name: []const u8) ?Variable {
        if (self.values.get(name)) |v| {
            return v;
        }
        if (self.parent) |p| {
            return p.get(name);
        }
        return null;
    }

    pub fn getPtr(self: *Environment, name: []const u8) ?*Variable {
        if (self.values.getPtr(name)) |v| {
            return v;
        }
        if (self.parent) |p| {
            return p.getPtr(name);
        }
        return null;
    }

    pub fn set(self: *Environment, name: []const u8, val: value.Value) !void {
        if (self.values.getPtr(name)) |v| {
            if (!v.is_mutable) {
                return error.ImmutableAssignment;
            }
            v.value = val;
            return;
        }
        if (self.parent) |p| {
            try p.set(name, val);
            return;
        }
        return error.UndefinedVariable;
    }

    pub fn createChild(self: *Environment) !*Environment {
        const child = try self.allocator.create(Environment);
        child.* = Environment{
            .values = std.StringHashMap(Variable).init(self.allocator),
            .parent = self,
            .children = std.ArrayList(*Environment).empty,
            .allocator = self.allocator,
        };
        try self.children.append(self.allocator, child);
        return child;
    }
};
