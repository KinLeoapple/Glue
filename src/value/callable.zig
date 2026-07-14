//! 可调用值类型模块
//!
//! 定义 Glue 语言中可被调用求值的值类型：
//! - Builtin 内置函数（原生函数指针）
//! - VmClosure 虚拟机闭包（捕获上值和绑定参数）
//! - PartialApplication 部分应用（已绑定部分参数的函数）
//! - TraitValue trait 对象（方法集 + 可选数据）
//! - LazyValue 惰性值（延迟求值的表达式）

const std = @import("std");
const ast = @import("ast");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const value = @import("mod.zig");
const Value = value.Value;

/// 内置函数指针类型：接收虚拟机上下文、用户上下文和参数列表
pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

/// 内置函数值，包装原生函数指针和可选用户上下文
pub const Builtin = struct {
    header: ObjHeader = .{ .type_tag = .builtin },
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,

    /// 空实现：函数指针和上下文由外部管理
    pub fn deinit(self: *Builtin, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// 虚拟机闭包，携带函数体、上值、绑定参数和 self 上值索引
pub const VmClosure = struct {
    header: ObjHeader = .{ .type_tag = .vm_closure },
    func: *const anyopaque,
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{},
    allocator: std.mem.Allocator,
    self_upvalue_idx: i32 = -1,

    /// 释放上值和绑定参数，跳过 self 上值以避免自引用释放
    pub fn deinit(self: *VmClosure, allocator: std.mem.Allocator) void {
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

/// 部分应用值，记录已绑定的参数和剩余所需参数个数
pub const PartialApplication = struct {
    header: ObjHeader = .{ .type_tag = .partial },
    func: Value,
    bound_args: []Value,
    remaining_arity: u8,

    /// 释放被包装函数和已绑定参数
    pub fn deinit(self: *PartialApplication, allocator: std.mem.Allocator) void {
        self.func.release(allocator);
        for (self.bound_args) |ba| ba.release(allocator);
        if (self.bound_args.len > 0) allocator.free(self.bound_args);
    }
};

/// trait 对象值，包含方法集和可选的关联数据
pub const TraitValue = struct {
    header: ObjHeader = .{ .type_tag = .trait_val },
    trait_name: []const u8 = "",
    methods: std.StringHashMap(Value),
    data: ?Value = null,
    allocator: std.mem.Allocator,
    vm_owned: bool = false,

    /// 释放所有方法键值和关联数据
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

/// 惰性值，延迟求值表达式，支持缓存和强制求值
pub const LazyValue = struct {
    header: ObjHeader = .{ .type_tag = .lazy_val },
    expr: *ast.Expr,
    env: *anyopaque,
    cached: ?Value = null,
    forced: bool = false,
    allocator: std.mem.Allocator,
    vm_thunk: ?*anyopaque = null,

    /// 释放缓存的求值结果和虚拟机 thunk 闭包
    pub fn deinit(self: *LazyValue, allocator: std.mem.Allocator) void {
        if (self.cached) |cached| cached.release(allocator);
        if (self.vm_thunk) |thunk| {
            const vc: *VmClosure = @ptrCast(@alignCast(thunk));
            (Value{ .ref = &vc.header }).release(allocator);
        }
    }
};

// ── deinit_table 注册函数 ──

pub fn builtinDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *Builtin = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

pub fn vmClosureDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *VmClosure = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

pub fn partialDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *PartialApplication = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

pub fn traitValDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *TraitValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

pub fn lazyValDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const self: *LazyValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(allocator);
    allocator.destroy(self);
}

/// 注册所有可调用类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.builtin, builtinDeinit);
    obj_header.registerDeinit(.vm_closure, vmClosureDeinit);
    obj_header.registerDeinit(.partial, partialDeinit);
    obj_header.registerDeinit(.trait_val, traitValDeinit);
    obj_header.registerDeinit(.lazy_val, lazyValDeinit);
}
