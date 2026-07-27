//! 堆对象统一头部模块
//!
//! 定义所有堆分配值共享的统一对象头 ObjHeader，提供：
//! - RefKind 枚举：23 种堆对象类型标签
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
    /// 协程帧：async 函数调度的执行载体（M:N 协程调度）
    /// 内存布局：[ObjHeader][CoroutineFrame 字段][locals 区，64B 对齐]
    coroutine_frame,
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
    /// 对象由 orbit worker 线程的 Engine 分配。
    /// async 函数通过 &T 引用参数修改主线程对象时，worker 分配的堆值
    /// 会存入主线程对象的字段。worker 退出后这些值变为悬垂指针。
    /// 主线程在 join 后通过此标记识别并迁移到自身 tctx。
    pub const WORKER_ALLOCATED: u8 = 1 << 2;

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

    /// 标记为 worker 线程分配（用于跨线程引用值迁移）
    pub inline fn markWorkerAllocated(self: *ObjHeader) void {
        self.flags |= WORKER_ALLOCATED;
    }

    /// 是否由 worker 线程分配
    pub inline fn isWorkerAllocated(self: *const ObjHeader) bool {
        return (self.flags & WORKER_ALLOCATED) != 0;
    }

    /// 所有已定义的 flags 位掩码（用于验证指针合法性）
    pub const ALL_USED_FLAGS: u8 = TRACKED | ARENA_ALLOCATED | WORKER_ALLOCATED;

    /// 验证 ObjHeader 是否为合法堆对象（架构无关的指针验证）
    ///
    /// 用于 readRefObj 区分真实堆指针与标量位模式（标量值通过 ref_chan
    /// 传输时位模式可能被误判为指针）。验证项完全基于 ObjHeader 字段语义：
    /// - type_tag 在合法 RefKind 范围内（0..ref_kind_count）
    /// - rc >= 1（合法对象引用计数至少为 1，标量位模式在 rc 位置通常为 0）
    /// - flags 未使用位为 0（bit 4-7 保留，合法对象不会设置这些位）
    ///
    /// 此方法不依赖任何架构相关假设（如用户空间地址范围），可跨平台使用。
    pub inline fn isValidHeapObj(self: *const ObjHeader) bool {
        if (@intFromEnum(self.type_tag) >= ref_kind_count) return false;
        if (self.rc == 0) return false;
        if ((self.flags & ~ALL_USED_FLAGS) != 0) return false;
        return true;
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
/// 原子类型：主引擎写、worker 引擎并发读，需原子访问避免 UB。
/// 仅主引擎（is_worker=false）设置/清除；worker 引擎复用主引擎的标志。
pub var shutdown_mode: std.atomic.Value(bool) = .init(false);

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
            // rc 归零时记录 free 事件
            // arena 对象跳过 recordFree（由 recordAllocatorReset 批量扣减 live_count/live_bytes）
            // heap 对象从分配器元数据读取真实 size，使 free_bytes/current_bytes 准确
            if (!obj.isArenaAllocated()) {
                const sz = tctx.getAllocSize(@ptrCast(obj));
                p.recordFree(@intFromEnum(obj.type_tag), sz);
            }
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
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var global = mem_mod.GlobalPool.init(std.testing.allocator, threaded.io());
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
