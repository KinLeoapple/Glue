//! 可调用值类型模块
//!
//! 定义 Glue 语言中可被调用求值的值类型：
//! - Builtin 内置函数（原生函数指针，固定大小）
//! - Closure 闭包（连续内存：header + upvalues + bound_args）
//! - PartialApplication 部分应用（连续内存：header + bound_args）
//! - TraitValue trait 对象（连续内存：header + method_values；method_names owned 时独立分配）
//! - LazyValue 惰性值（固定大小）

const std = @import("std");
const ast = @import("ast");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
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
    pub fn deinit(self: *Builtin, tctx: *ThreadContext) void {
        _ = self;
        _ = tctx;
    }
};

/// 闭包，携带函数体、上值、绑定参数和 self 上值索引
///
/// 连续内存布局：[Closure header | upvalues[] | bound_args[]]
/// upvalues 和 bound_args 切片指向尾部连续区域，单次分配单次释放
pub const Closure = struct {
    header: ObjHeader = .{ .type_tag = .closure },
    func: *const anyopaque,
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{},
    self_upvalue_idx: i32 = -1,

    /// 释放上值和绑定参数的引用计数，跳过 self 上值以避免自引用释放
    /// upvalues 和 bound_args 是连续内存的一部分，由 closureDeinit 中的 freeObj 统一释放
    pub fn deinit(self: *Closure, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            const self_idx = self.self_upvalue_idx;
            for (self.upvalues, 0..) |uv, i| {
                if (self_idx >= 0 and i == @as(usize, @intCast(self_idx))) continue;
                uv.release(tctx);
            }
            for (self.bound_args) |ba| ba.release(tctx);
        }
    }
};

/// 部分应用值，记录已绑定的参数和剩余所需参数个数
///
/// 连续内存布局：[PartialApplication header | bound_args[]]
/// bound_args 切片指向尾部连续区域，单次分配单次释放
pub const PartialApplication = struct {
    header: ObjHeader = .{ .type_tag = .partial },
    func: Value,
    bound_args: []Value,
    remaining_arity: u8,

    /// 释放被包装函数和已绑定参数的引用计数
    /// bound_args 是连续内存的一部分，由 partialDeinit 中的 freeObj 统一释放
    pub fn deinit(self: *PartialApplication, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            self.func.release(tctx);
            for (self.bound_args) |ba| ba.release(tctx);
        }
    }
};

/// trait 对象值，包含方法集和可选的关联数据
/// methods 用并行数组存储（names + values），线性查找
/// trait 方法数通常 <8，线性查找比 HashMap 快（无 hash 计算 + 无冲突，cache 连续）
///
/// 连续内存布局：[TraitValue header | method_values[]]
/// method_values 切片指向尾部连续区域，随 header 单次释放
/// method_names 当 owned=true 时为独立分配（每个名字字符串 + 指针数组均独立分配），
///   在 deinit 中逐个释放；当 owned=false 时为借用指针，无需释放
pub const TraitValue = struct {
    header: ObjHeader = .{ .type_tag = .trait_val },
    trait_name: []const u8 = "",
    method_names: []const []const u8 = &.{},
    method_values: []Value = &.{},
    data: ?Value = null,
    owned: bool = false,

    /// 按名查找方法值，找不到返回 null
    pub fn getMethod(self: *const TraitValue, name: []const u8) ?Value {
        for (self.method_names, self.method_values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    /// 释放所有方法键值和关联数据
    /// method_values 是连续内存的一部分，由 traitValDeinit 中的 freeObj 统一释放
    /// method_names 当 owned=true 时为独立分配，在此逐个释放
    /// arena 分配的对象：owned names 也从 arena 分配，跳过 freeObj
    pub fn deinit(self: *TraitValue, tctx: *ThreadContext) void {
        if (self.owned and !self.header.isArenaAllocated()) {
            for (self.method_names) |n| {
                if (n.len > 0) tctx.freeObj(@ptrCast(@constCast(n.ptr)));
            }
            if (self.method_names.len > 0) tctx.freeObj(@ptrCast(@constCast(self.method_names.ptr)));
        }
        if (!obj_header.shutdown_mode) {
            for (self.method_values) |v| v.release(tctx);
            if (self.data) |v| v.release(tctx);
        }
    }
};

/// 惰性值，延迟求值表达式，支持缓存和强制求值
pub const LazyValue = struct {
    header: ObjHeader = .{ .type_tag = .lazy_val },
    expr: *ast.Expr,
    env: *anyopaque,
    cached: ?Value = null,
    forced: bool = false,
    thunk: ?*anyopaque = null,

    /// 释放缓存的求值结果和 thunk 闭包
    pub fn deinit(self: *LazyValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            if (self.cached) |cached| cached.release(tctx);
            if (self.thunk) |thunk| {
                const vc: *Closure = @ptrCast(@alignCast(thunk));
                (Value{ .ref = &vc.header }).release(tctx);
            }
        }
    }
};

// ── deinit_table 注册函数 ──
// 所有 deinit 包装函数：执行 Type.deinit（释放内部 RC 子对象/独立缓冲区），
// 若对象非 arena 分配则 freeObj 释放对象本体；arena 分配的对象由 arena.reset 统一回收。

pub fn builtinDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *Builtin = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn closureDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *Closure = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn partialDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *PartialApplication = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn traitValDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *TraitValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn lazyValDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *LazyValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

/// 注册所有可调用类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.builtin, builtinDeinit);
    obj_header.registerDeinit(.closure, closureDeinit);
    obj_header.registerDeinit(.partial, partialDeinit);
    obj_header.registerDeinit(.trait_val, traitValDeinit);
    obj_header.registerDeinit(.lazy_val, lazyValDeinit);
}
