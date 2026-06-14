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
        // 深拷贝值，确保每个环境拥有自己的数据副本，避免 double-free
        const cloned_val = try val.clone(self.allocator);
        try self.values.put(key, Variable{ .value = cloned_val, .is_mutable = is_mutable, .is_public = is_public });
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
            // Atomic<T> 透明操作：写入时使用 atomic_store
            if (v.value == .atomic_val) {
                v.value.atomic_val.store(val);
                return;
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

    /// 深拷贝环境 — 用于 spawn 闭包捕获
    /// 创建完全独立的环境链，递归深拷贝所有变量值和父链
    /// spawn 捕获语义：深拷贝隔离，Atomic<T> 例外（浅拷贝）
    /// `atomic_values` 参数：如果非 null，其中的 Atomic 值将浅拷贝而非深拷贝
    pub fn deepCopy(self: *Environment, allocator: std.mem.Allocator, atomic_values: ?[]const *value.AtomicValue) !*Environment {
        const new_env = try allocator.create(Environment);
        new_env.* = Environment{
            .values = std.StringHashMap(Variable).init(allocator),
            .parent = null,
            .children = std.ArrayList(*Environment).empty,
            .allocator = allocator,
        };
        // 深拷贝当前环境的所有变量
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const cloned_val = try deepCloneValue(entry.value_ptr.value, allocator, atomic_values);
            try new_env.values.put(key, Variable{
                .value = cloned_val,
                .is_mutable = entry.value_ptr.is_mutable,
                .is_public = entry.value_ptr.is_public,
            });
        }
        // 递归深拷贝父环境链
        if (self.parent) |parent| {
            new_env.parent = try parent.deepCopy(allocator, atomic_values);
        }
        return new_env;
    }

    /// 深拷贝值 — Atomic<T> 浅拷贝例外
    fn deepCloneValue(val: value.Value, allocator: std.mem.Allocator, atomic_values: ?[]const *value.AtomicValue) !value.Value {
        _ = atomic_values; // 目前未使用，保留接口用于后续优化
        // 如果是 Atomic 值，浅拷贝（共享底层内存 + 增加引用计数）
        if (val == .atomic_val) {
            val.atomic_val.ref();
            return val;
        }
        // 如果 atomic_values 列表中有匹配的指针，也需要浅拷贝
        // 这里主要处理 closure 等复合类型内部可能包含 Atomic 的情况
        return try val.clone(allocator);
    }
};
