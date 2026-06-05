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
        const key = try self.allocator.dupe(u8, name);
        // 如果已存在，释放旧 key 和旧值
        if (try self.values.fetchPut(key, Variable{ .value = val, .is_mutable = is_mutable })) |old| {
            self.allocator.free(old.key);
            var old_val = old.value.value;
            old_val.deinit(self.allocator);
        }
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
