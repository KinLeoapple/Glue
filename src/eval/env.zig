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
    /// 续14/闭包转换：弱引用绑定（不拥有 value）。用于 letrec 递归闭包的自引用槽——
    /// 闭包的 capture_env 里指向闭包自己，若 retain 则成环。weak=true 时 release/teardown
    /// 跳过 value 的 release，避免环 + 避免悬空 double-free。
    is_weak: bool = false,
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
    /// 续14/闭包转换：是否为闭包 capture_env。capture_env 的 parent(global_env) 是非拥有
    /// 引用（不 retain、不在 parent.children），releaseEnv 时不 detach、不 release parent。
    is_capture: bool = false,

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
            // 用子自己的 allocator 销毁：运行期子帧走 value_allocator(pool)，
            // 而父可能是 arena。用 self.allocator 销毁 pool 分配的子 → 分配器错配 invalid free。
            child.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);

        // 释放值中的堆分配数据。用 release（引用计数感知）而非 deinit：
        // 共享值（rc>1）只减计数，归零才真正释放，避免多个变量持有同一记录/数组时双重释放。
        // 续14：weak 绑定不拥有 value，跳过 release。
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (!entry.value_ptr.is_weak) entry.value_ptr.value.release(self.value_allocator);
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
        // 从父环境 children 列表摘除自身（防止全局 deinit 重复销毁）。
        // 续14：capture_env 不在 parent.children（parent 是非拥有引用），跳过 detach。
        if (!self.is_capture) {
            if (self.parent) |p| {
                var idx: usize = 0;
                while (idx < p.children.items.len) : (idx += 1) {
                    if (p.children.items[idx] == self) {
                        _ = p.children.swapRemove(idx);
                        break;
                    }
                }
            }
        }
        // 释放绑定（续14：weak 绑定不拥有 value，跳过 release）
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (!entry.value_ptr.is_weak) entry.value_ptr.value.release(self.value_allocator);
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
        const is_cap = self.is_capture;
        const alloc = self.allocator;
        alloc.destroy(self);
        // 释放对父环境的引用（子持有父）。续14：capture_env 未 retain parent，跳过。
        if (!is_cap) {
            if (saved_parent) |p| p.releaseEnv();
        }
    }

    pub fn define(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool) !void {
        return self.defineWithVisibility(name, val, is_mutable, false);
    }

    pub fn defineWithVisibility(self: *Environment, name: []const u8, val: value.Value, is_mutable: bool, is_public: bool) !void {
        // 如果已存在，先移除旧条目并释放旧 key 和旧值（release：引用计数感知）。
        // 续14：weak 旧值不 release（不拥有）。
        if (self.values.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            if (!old.value.is_weak) old.value.value.release(self.value_allocator);
        }
        // 插入新条目（需要分配 key 的独立副本）。key 走 allocator（与 free 同源）。
        const key = try self.allocator.dupe(u8, name);
        // clone：带 rc 的复合值仅 retain（不分配）；string 等深拷走 value_allocator
        // 与 release 同源，避免 pool/arena 错配。
        const cloned_val = try val.clone(self.value_allocator);
        try self.values.put(key, Variable{ .value = cloned_val, .is_mutable = is_mutable, .is_public = is_public });
    }

    /// 续14/闭包转换：弱绑定（不拥有 value，不 clone/retain）。用于 letrec 递归自引用。
    /// release/teardown/覆盖时跳过 value.release，避免环与 double-free。
    pub fn defineWeak(self: *Environment, name: []const u8, val: value.Value) !void {
        if (self.values.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            if (!old.value.is_weak) old.value.value.release(self.value_allocator);
        }
        const key = try self.allocator.dupe(u8, name);
        try self.values.put(key, Variable{ .value = val, .is_mutable = false, .is_public = false, .is_weak = true });
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
            // 续14/闭包转换：被捕获 var 的 cell 透明写入——写进 cell.inner（帧与捕获闭包共享，
            // 故 mutation 对双方可见）。旧内值 release，新值 move 进 cell。绑定本身仍是同一 *Cell。
            if (v.value == .cell_val) {
                const cell = v.value.cell_val;
                const old_inner = cell.inner;
                cell.inner = val;
                old_inner.release(self.value_allocator);
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

    /// 续14/闭包转换（3b：快照可见作用域）：为闭包构造捕获环境。
    /// 从 self 沿父链向上到 root（global_env，不含），把每个帧的绑定快照进新 capture_env：
    /// - val（不可变）：clone（retain）值进 capture_env，is_mutable=false。
    /// - var（可变）：提升为共享 cell——若原绑定还不是 cell_val，就地装箱原帧绑定（原帧与
    ///   capture_env 指向同一 *Cell，mutation 双向可见，cell 寿命独立于帧 → escaped 闭包仍可变）。
    /// capture_env.parent = root（global_env），使闭包体名字解析回落到全局（函数/类型/顶层）。
    /// 内层 shadowing 外层：已捕获的名字跳过更外层同名。
    /// 结果：闭包持 capture_env 而非定义帧 → 闭包不再指向帧 → 环断开，帧纯 RC 即时回收。
    /// capture_env 走 value_allocator（pool），随闭包 release 一起回收。
    /// 续14/闭包转换：供 Closure.env_release_fn 用的回调——把不透明 capture_env 指针
    /// 还原为 *Environment 并 releaseEnv。闭包 rc 归零时（value.zig release）调用。
    pub fn releaseEnvOpaque(ptr: *anyopaque) void {
        const e: *Environment = @ptrCast(@alignCast(ptr));
        e.releaseEnv();
    }

    pub fn buildCaptureEnv(self: *Environment) !*Environment {
        // 找到 root（global_env）：parent == null 的那个。
        var root: *Environment = self;
        while (root.parent) |p| root = p;

        const alloc = self.value_allocator;
        const cap = try alloc.create(Environment);
        cap.* = Environment{
            .values = std.StringHashMap(Variable).init(alloc),
            .parent = root,
            .children = std.ArrayList(*Environment).empty,
            .allocator = alloc,
            .value_allocator = alloc,
            .rc = 1,
            .is_capture = true,
        };
        // capture_env 的 parent=root(global_env) 仅用于名字解析回落到全局。global_env 是
        // evaluator 字段、最后销毁，必然 outlive 所有闭包，故 capture_env **不 retain root、
        // 不进 root.children**——否则 (1) global deinit 会重复释放它，(2) 闭包 rc 归零时
        // releaseEnv 在 global deinit 半途 detach root.children 造成 UAF（实测崩 21 测试）。

        // 从 self 向上到 root（不含 root）逐帧快照绑定，内层优先（已存在则跳过）。
        var frame: ?*Environment = self;
        var guard: usize = 0;
        while (frame) |f| {
            guard += 1;
            if (guard > 10000) @panic("buildCaptureEnv runaway frame chain");
            if (f == root) break;
            var it = f.values.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                if (cap.values.contains(name)) continue; // 内层 shadowing：已捕获则跳过外层同名
                const v = entry.value_ptr;
                if (v.is_mutable) {
                    // var：提升为共享 cell。原绑定就地装箱（若尚未），capture 持同一 cell（retain）。
                    if (v.value != .cell_val) {
                        const cell = try alloc.create(value.Cell);
                        cell.* = value.Cell{ .inner = v.value, .rc = 1 };
                        v.value = value.Value{ .cell_val = cell };
                    }
                    const shared = v.value.cell_val;
                    shared.rc += 1;
                    const key = try alloc.dupe(u8, name);
                    try cap.values.put(key, Variable{ .value = value.Value{ .cell_val = shared }, .is_mutable = true, .is_public = v.is_public });
                } else {
                    // val：拷值快照（retain），与原帧独立（不可变，无需共享）。
                    const key = try alloc.dupe(u8, name);
                    const cloned = try v.value.clone(alloc);
                    try cap.values.put(key, Variable{ .value = cloned, .is_mutable = false, .is_public = v.is_public });
                }
            }
            frame = f.parent;
        }
        return cap;
    }

    pub fn createChild(self: *Environment) !*Environment {
        // 运行期作用域帧走 value_allocator（SlabPool）：releaseEnv 时即时回收，
        // 不像 arena 那样焊在峰值。深递归/大量调用下帧内存随作用域退出回落。
        // 子帧的 allocator 设为 value_allocator，使其 key dupe / HashMap backing /
        // children 列表 / 销毁全部同源于 pool（releaseEnv 用 self.allocator 释放）。
        const frame_alloc = self.value_allocator;
        const child = try frame_alloc.create(Environment);
        child.* = Environment{
            .values = std.StringHashMap(Variable).init(frame_alloc),
            .parent = self,
            .children = std.ArrayList(*Environment).empty,
            .allocator = frame_alloc,
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

            // 续14/闭包转换：捕获 var cell。spawn 跨 heap 深拷其内值到目标 heap（独立 cell），
            // 与"不可变数据结构深拷"一致——跨 heap 不共享可变状态（除 Atomic）。退化用 clone 内值。
            .cell_val => |c| blk: {
                const new_inner = try deepCloneValue(c.inner, allocator, null);
                const nc = try allocator.create(value.Cell);
                nc.* = value.Cell{ .inner = new_inner, .rc = 1 };
                break :blk value.Value{ .cell_val = nc };
            },
        };
    }
};
