//! 可调用与高级类型装箱 struct——VmClosure/PartialApplication/Builtin/TraitValue/LazyValue
//!
//! 每个 struct 首字段 rc:u32，Value union 持 *T 指针。
//! VmClosure.deinit 跳过 self_upvalue_idx 弱自引用，避免 letrec 自递归闭包的 cell 二次释放。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const ast = @import("ast");
const value = @import("mod.zig");
const Value = value.Value;

/// 内置函数指针类型（与旧 value.zig BuiltinFn 一致）
pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

/// 内置函数值
pub const Builtin = struct {
    rc: u32 = 1,
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,

    pub fn deinit(self: *Builtin, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // 函数指针无堆数据
    }
};

/// VM 闭包：func + upvalues + bound_args
/// self_upvalue_idx: letrec 自递归闭包的弱自引用 upvalue 索引，deinit 跳过该 idx 避免 cell 二次释放
pub const VmClosure = struct {
    rc: u32 = 1,
    func: *const anyopaque,
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{},
    allocator: std.mem.Allocator,
    self_upvalue_idx: i32 = -1,

    pub fn deinit(self: *VmClosure, allocator: std.mem.Allocator) void {
        // 弱自引用跳过：op_set_local_letrec 断环时已 cell.rc -= 1 抵消强引用，
        // 此 upvalue 不再持 cell 的 rc，release 时必须跳过，否则 cell 被二次释放（rc 下溢）。
        const self_idx = self.self_upvalue_idx;
        for (self.upvalues, 0..) |uv, i| {
            if (self_idx >= 0 and i == @as(usize, @intCast(self_idx))) continue;
            uv.release(allocator);
        }
        if (self.upvalues.len > 0) self.allocator.free(self.upvalues);
        for (self.bound_args) |ba| ba.release(allocator);
        if (self.bound_args.len > 0) self.allocator.free(self.bound_args);
    }
};

/// 部分应用：func + 已绑定参数 + 剩余 arity
pub const PartialApplication = struct {
    rc: u32 = 1,
    func: Value,
    bound_args: []Value,
    remaining_arity: u8,

    pub fn deinit(self: *PartialApplication, allocator: std.mem.Allocator) void {
        self.func.release(allocator);
        for (self.bound_args) |ba| ba.release(allocator);
        if (self.bound_args.len > 0) allocator.free(self.bound_args);
    }
};

/// Trait 值：trait_name + methods + 可选 data
pub const TraitValue = struct {
    rc: u32 = 1,
    trait_name: []const u8 = "",
    methods: std.StringHashMap(Value),
    data: ?Value = null,
    allocator: std.mem.Allocator,
    vm_owned: bool = false,

    pub fn deinit(self: *TraitValue, allocator: std.mem.Allocator) void {
        var it = self.methods.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.release(allocator);
        }
        self.methods.deinit();
        if (self.data) |v| v.release(allocator);
    }
};

/// 惰性值：expr + env + cached（expr/env 由外部管理，deinit 只释放 cached）
pub const LazyValue = struct {
    rc: u32 = 1,
    expr: *ast.Expr,
    env: *anyopaque,
    cached: ?Value = null,
    forced: bool = false,
    allocator: std.mem.Allocator,
    vm_thunk: ?*anyopaque = null,

    pub fn deinit(self: *LazyValue, allocator: std.mem.Allocator) void {
        if (self.cached) |cached| cached.release(allocator);
        // expr/env 由外部管理，不在此释放
    }
};
