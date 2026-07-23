//! 堆对象统一头部模块
//!
//! 定义所有堆分配值共享的统一对象头 ObjHeader，提供：
//! - RefKind 枚举：22 种堆对象类型标签
//! - ObjHeader：extern struct，保证跨架构布局一致
//! - 统一 retain/release 引用计数接口
//! - deinit_table 分派表与注册机制
//!
//! 本模块仅依赖 std，不导入 value 子模块，避免循环依赖。
//! 具体堆对象类型（composite.zig、callable.zig 等）通过
//! registerDeinit 在初始化时注册各自的 deinit 函数。

const std = @import("std");
const mem_mod = @import("mem");

/// 重导出 ThreadContext，供所有 value 子模块使用
pub const ThreadContext = mem_mod.ThreadContext;

/// 堆对象类型标签，覆盖全部 22 种堆分配值
///
/// 按语义分组：复合、可调用、控制流、迭代器、并发。
pub const RefKind = enum(u8) {
    // 复合
    str,
    array,
    record,
    adt,
    newtype,
    cell,
    range,
    // 可调用
    closure,
    partial,
    builtin,
    trait_val,
    lazy_val,
    // 控制流
    error_val,
    throw_val,
    // 迭代器
    array_iter,
    string_iter,
    range_iter,
    // 并发
    atomic_val,
    async_val,
    channel_val,
    sender_val,
    receiver_val,
    /// 装箱标量：&i32/&f64 等标量引用的堆容器，内联标量值紧跟 ObjHeader 之后
    /// 内存布局：[ObjHeader][标量值，最多 16B]
    boxed_scalar,
};

/// 所有堆对象的统一头部
///
/// 作为每个堆对象 struct 的首字段，提供类型识别和引用计数。
/// extern struct 保证跨架构内存布局一致：
/// - type_tag: 1B，类型识别
/// - flags: 1B，标志位（bit0: tracked，bit1: arena_allocated）
/// - rc: 4B，统一引用计数（初始 1）
/// - 2B 隐式 padding 对齐到 8B
pub const ObjHeader = extern struct {
    type_tag: RefKind,
    flags: u8 = 0,
    rc: u32 = 1,
    // 2B 隐式 padding 对齐到 8B

    /// flags 位掩码
    pub const TRACKED: u8 = 1 << 0;
    /// 对象从 ShadowArena 分配（逃逸分析驱动）
    /// - release 归零时跳过 freeObj，由 endFunction 的 arena.reset 统一回收
    /// - deinit 仍执行（释放内部非 arena 资源，如子对象 release）
    pub const ARENA_ALLOCATED: u8 = 1 << 1;

    /// 标记为已被引擎跟踪
    pub inline fn markTracked(self: *ObjHeader) void {
        self.flags |= TRACKED;
    }

    /// 是否已被引擎跟踪
    pub inline fn isTracked(self: *const ObjHeader) bool {
        return (self.flags & TRACKED) != 0;
    }

    /// 标记为 ShadowArena 分配
    pub inline fn markArenaAllocated(self: *ObjHeader) void {
        self.flags |= ARENA_ALLOCATED;
    }

    /// 是否从 ShadowArena 分配
    pub inline fn isArenaAllocated(self: *const ObjHeader) bool {
        return (self.flags & ARENA_ALLOCATED) != 0;
    }
};

/// 类型特定的析构函数指针
///
/// 负责释放对象内部资源（递归 release 子值、释放切片等）。
/// 注册时由各具体对象模块提供，通过 @fieldParentPtr 或
/// @ptrCast 将 ObjHeader 指针还原为具体类型指针。
pub const DeinitFn = *const fn (*ObjHeader, *ThreadContext) void;

/// RefKind 变体数量，用于确定分派表长度
pub const ref_kind_count = @typeInfo(RefKind).@"enum".fields.len;

/// 未注册类型占位的空析构函数
///
/// 在具体类型通过 registerDeinit 注册前作为默认值，
/// 防止 release 调用未初始化的函数指针。
fn noopDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    _ = obj;
    _ = tctx;
}

/// deinit 分派表：按 RefKind 索引到类型特定析构函数
///
/// 初始全部填充 noopDeinit，由各对象模块在初始化时注册。
pub var deinit_table: [ref_kind_count]DeinitFn = [_]DeinitFn{noopDeinit} ** ref_kind_count;

/// 关闭模式标志：为 true 时，deinit 函数跳过对包含值的级联 release。
/// 引擎 deinit 时设置为 true，tracked_objs 循环会单独释放每个跟踪的对象，
/// 避免级联 release 释放已被跟踪的包含对象后，循环访问已释放内存。
pub var shutdown_mode: bool = false;

/// 注册类型特定的析构函数
///
/// 各对象模块在初始化时调用，将自身的 deinit 实现填入分派表。
pub fn registerDeinit(kind: RefKind, f: DeinitFn) void {
    deinit_table[@intFromEnum(kind)] = f;
}

/// 统一 retain：原子递增引用计数，返回自身以便链式调用
///
/// 使用原子操作保证线程安全，无竞争时开销约 1 周期（x86 LOCK 前缀）。
pub fn retain(obj: *ObjHeader, tctx: *ThreadContext) *ObjHeader {
    _ = @atomicRmw(u32, &obj.rc, .Add, 1, .monotonic);
    if (tctx.prof) |p| p.recordRC(.retain);
    return obj;
}

/// 统一 release：原子递减引用计数，归零时分派到类型特定 deinit
///
/// 使用 acq_rel 内存序保证 deinit 看到所有先行写操作（Zig 0.15+ 移除了 @fence，
/// 改用 acq_rel RMW 同时提供 acquire 与 release 语义）。
/// deinit 函数负责释放内部资源并销毁对象本体。
pub fn release(obj: *ObjHeader, tctx: *ThreadContext) void {
    const old = @atomicRmw(u32, &obj.rc, .Sub, 1, .acq_rel);
    if (tctx.prof) |p| {
        if (old == 1) {
            p.recordRC(.release_to_zero);
        } else {
            p.recordRC(.release);
        }
    }
    if (old == 1) {
        deinit_table[@intFromEnum(obj.type_tag)](obj, tctx);
    }
}

/// 统一 ObjHeader 初始化：设置类型标签、重置标志位、设置 rc=1，并记录分配埋点
///
/// 所有堆对象分配后应调用此函数初始化 header，确保 profiling 采集到 alloc 事件。
/// size 为对象总分配大小（含 header），is_arena 标记是否从 ShadowArena 分配。
pub fn initObjHeader(header: *ObjHeader, kind: RefKind, size: usize, is_arena: bool, tctx: *ThreadContext) void {
    header.type_tag = kind;
    header.flags = 0;
    header.rc = 1;
    if (is_arena) header.markArenaAllocated();
    if (tctx.prof) |p| p.recordAlloc(@intFromEnum(kind), size, is_arena);
}

test {
    std.testing.refAllDecls(@This());
}

test "retain 与 release 引用计数" {
    var global = mem_mod.GlobalPool.init(std.testing.allocator);
    defer global.deinit();
    var ctx = ThreadContext.init(&global, std.testing.allocator, null) catch unreachable;
    defer ctx.deinit();

    var obj = ObjHeader{ .type_tag = .array, .rc = 1 };
    _ = retain(&obj, &ctx);
    try std.testing.expectEqual(@as(u32, 2), obj.rc);
    // rc 从 2 递减到 1，不触发 deinit 分派
    release(&obj, &ctx);
    try std.testing.expectEqual(@as(u32, 1), obj.rc);
}

test "ObjHeader 布局为 8B" {
    // extern struct 保证 8B 大小（1B tag + 1B flags + 2B padding + 4B rc）
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ObjHeader));
}
