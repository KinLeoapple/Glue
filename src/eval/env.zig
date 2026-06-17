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
    /// 运行期 Value 专用分配器（箱体/载荷归还）。默认 = allocator（行为不变）；
    /// 主求值器把它指向 SlabPool，使绑定 release 归还 pool 而非 no-op 的 arena。
    /// key 字符串仍走 allocator（与 define 时 dupe 同源）。
    value_allocator: std.mem.Allocator,
    /// 引用计数：创建时 1；被闭包捕获时 +1；作用域退出/闭包销毁时 -1，归零才真正销毁。
    /// 闭包按指针捕获其定义环境，故帧不能在函数返回时无条件销毁——必须等无人引用。
    rc: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return Environment{
            .values = std.StringHashMap(Variable).init(allocator),
            .parent = null,
            .children = std.ArrayList(*Environment).empty,
            .allocator = allocator,
            .value_allocator = allocator,
            .rc = 1,
        };
    }

    /// 引用计数 +1（闭包捕获环境时调用）。返回自身。
    pub fn retain(self: *Environment) *Environment {
        self.rc += 1;
        return self;
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

        // 释放值中的堆分配数据。用 release（引用计数感知）而非 deinit：
        // 共享值（rc>1）只减计数，归零才真正释放，避免多个变量持有同一记录/数组时双重释放。
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.value.release(self.value_allocator);
        }
        self.values.deinit();
    }

    /// 作用域退出/闭包销毁时调用：rc-1。归零则从父链摘除、release 所有绑定与残留子环境、销毁自身。
    /// rc>0（仍被闭包等引用）则保留。被销毁的帧已从 parent.children 摘除，避免与全局 deinit 双重释放。
    pub fn releaseEnv(self: *Environment) void {
        if (self.rc > 1) {
            self.rc -= 1;
            return;
        }
        self.rc = 0;
        // 从父环境 children 列表摘除自身（防止全局 deinit 重复销毁）
        if (self.parent) |p| {
            var idx: usize = 0;
            while (idx < p.children.items.len) : (idx += 1) {
                if (p.children.items[idx] == self) {
                    _ = p.children.swapRemove(idx);
                    break;
                }
            }
        }
        // 释放绑定
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.value.release(self.value_allocator);
        }
        self.values.deinit();
        // 残留子环境（理论上此时应为空或仍被引用）：对每个调用 releaseEnv
        const saved_parent = self.parent;
        var ci: usize = self.children.items.len;
        while (ci > 0) {
            ci -= 1;
            self.children.items[ci].releaseEnv();
        }
        self.children.deinit(self.allocator);
        const alloc = self.allocator;
        alloc.destroy(self);
        // 释放对父环境的引用（子持有父，使父在子存活期间不被回收）
        if (saved_parent) |p| p.releaseEnv();
    }

    pub fn define(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool) !void {
        return self.defineWithVisibility(name, val, is_mutable, false);
    }

    pub fn defineWithVisibility(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool, is_public: bool) !void {
        // 如果已存在，先移除旧条目并释放旧 key 和旧值（release：引用计数感知）
        if (self.values.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            old.value.value.release(self.value_allocator);
        }
        // 插入新条目（需要分配 key 的独立副本）。key 走 allocator（与 free 同源）。
        const key = try self.allocator.dupe(u8, name);
        // clone：带 rc 的复合值仅 retain（不分配）；string 等深拷走 value_allocator
        // 与 release 同源，避免 pool/arena 错配。
        const cloned_val = try val.clone(self.value_allocator);
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
            // owned 模型：val 为 owned，move 进变量（接管）；旧值被覆盖，release 归还。
            const old = v.value;
            v.value = val;
            old.release(self.value_allocator);
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
            .value_allocator = self.value_allocator,
            .rc = 1,
        };
        try self.children.append(self.allocator, child);
        _ = self.retain(); // 子持有父：父在子存活期间不被回收
        return child;
    }

    /// 深拷贝环境 — 用于 spawn 闭包捕获
    /// 创建完全独立的环境链，递归深拷贝所有变量值和父链
    /// spawn 捕获语义：深拷贝隔离，Atomic<T> 例外（浅拷贝）
    /// `atomic_values` 参数：如果非 null，其中的 Atomic 值将浅拷贝而非深拷贝
    pub fn deepCopy(self: *Environment, allocator: std.mem.Allocator, atomic_values: ?[]const *value.AtomicValue) anyerror!*Environment {
        const new_env = try allocator.create(Environment);
        new_env.* = Environment{
            .values = std.StringHashMap(Variable).init(allocator),
            .parent = null,
            .children = std.ArrayList(*Environment).empty,
            .allocator = allocator,
            .value_allocator = allocator,
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

    /// 跨 Heap 传递值 — 严格按照文档 §5.2 六类规则
    ///
    /// | 数据类型       | 跨 Heap 传递方式                         |
    /// |---------------|------------------------------------------|
    /// | 基础类型       | 值拷贝（栈上）                            |
    /// | 不可变数据结构  | 深拷贝到目标 heap                          |
    /// | 一等 Trait 值  | vtable 共享（全局只读）+ data 深拷贝        |
    /// | Channel       | 调度器 heap 中，两端只持有引用              |
    /// | 函数/闭包      | 深拷贝捕获的环境                           |
    /// | Atomic<T>     | 浅拷贝（原子增加引用计数）                  |
    pub fn deepCloneValue(val: value.Value, allocator: std.mem.Allocator, atomic_values: ?[]const *value.AtomicValue) anyerror!value.Value {
        _ = atomic_values; // 目前未使用，保留接口用于后续优化
        return switch (val) {
            // §5.2 规则 1: 基础类型 — 值拷贝（栈上）
            // integer, float, boolean, char_val, null_val, unit, range 均为值类型，
            // clone 直接返回自身副本，无需额外处理
            .integer,
            .float,
            .boolean,
            .char_val,
            .null_val,
            .unit,
            .range,
            => val,

            // §5.2 规则 6: Atomic<T> — 浅拷贝（共享底层内存 + 原子增加引用计数）
            // Atomic 是唯一允许跨 Heap 共享的可变状态，通过引用计数管理生命周期
            .atomic_val => |av| {
                av.ref();
                return value.Value{ .atomic_val = av };
            },

            // §5.2 规则 4: Channel — 调度器 heap 中，两端只持有引用
            // Channel/Sender/Receiver 的底层缓冲区位于调度器 heap，
            // 两端仅持有引用（通过 ref count 管理），跨 Heap 传递时增加引用计数
            .channel_val => |cv| {
                cv.ref();
                return value.Value{ .channel_val = cv };
            },
            .sender_val => |sv| {
                sv.ref();
                return value.Value{ .sender_val = sv };
            },
            .receiver_val => |rv| {
                rv.ref();
                return value.Value{ .receiver_val = rv };
            },

            // §5.2 规则 5: 函数/闭包 — 深拷贝捕获的环境
            // 闭包跨 Heap 传递时，需要确保捕获的环境被深拷贝。
            // 但 Environment.deepCopy 已经递归深拷贝了整个环境链，
            // 环境中的闭包变量只需浅拷贝（共享闭包指针），因为：
            // 1. 闭包代码（params+body）是不可变的，可安全共享
            // 2. 闭包捕获的环境已通过 deepCopy 递归深拷贝
            // 3. 递归深拷贝闭包内部环境会导致循环引用栈溢出
            .closure => val,

            // §5.2 规则 2: 不可变数据结构 — 深拷贝到目标 heap
            // string, array, record, adt, newtype, error_val, throw_val, partial
            // 这些类型在跨 Heap 时必须完整深拷贝，确保目标 heap 拥有独立副本
            .string,
            .array,
            .record,
            .adt,
            .newtype,
            .error_val,
            .throw_val,
            .partial,
            => try val.clone(allocator),

            // §5.2 规则 3: 一等 Trait 值 — vtable 共享 + data 深拷贝
            // builtin 函数可视为简化的 Trait 值：函数指针全局共享（等价 vtable），
            // 无 data 载荷，跨 Heap 传递时直接共享。
            .builtin => val,

            // 一等 Trait 值（Phase 7）：clone 已实现 vtable 浅拷贝 + data 深拷贝
            .trait_value => try val.clone(allocator),

            // Lazy<T>（Phase 7）：thunk 引用语义，跨 Heap 共享
            .lazy_val => val,

            // Spawn<T> 是线性类型，不允许跨 Heap 传递（必须通过 await/cancel 消费）
            .spawn_val => val,

            // 迭代器：不应跨 Heap 传递，保留引用语义
            .array_iterator,
            .string_iterator,
            .range_iterator,
            => val,
        };
    }
};
