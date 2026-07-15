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
};

/// 所有堆对象的统一头部
///
/// 作为每个堆对象 struct 的首字段，提供类型识别和引用计数。
/// extern struct 保证跨架构内存布局一致：
/// - type_tag: 1B，类型识别
/// - rc: 4B，统一引用计数（初始 1）
/// - 3B 隐式 padding 对齐到 8B
pub const ObjHeader = extern struct {
    type_tag: RefKind,
    rc: u32 = 1,
    // 3B 隐式 padding 对齐到 8B
};

/// 类型特定的析构函数指针
///
/// 负责释放对象内部资源（递归 release 子值、释放切片等）。
/// 注册时由各具体对象模块提供，通过 @fieldParentPtr 或
/// @ptrCast 将 ObjHeader 指针还原为具体类型指针。
pub const DeinitFn = *const fn (*ObjHeader, std.mem.Allocator) void;

/// RefKind 变体数量，用于确定分派表长度
const ref_kind_count = @typeInfo(RefKind).@"enum".fields.len;

/// 未注册类型占位的空析构函数
///
/// 在具体类型通过 registerDeinit 注册前作为默认值，
/// 防止 release 调用未初始化的函数指针。
fn noopDeinit(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    _ = obj;
    _ = allocator;
}

/// deinit 分派表：按 RefKind 索引到类型特定析构函数
///
/// 初始全部填充 noopDeinit，由各对象模块在初始化时注册。
var deinit_table: [ref_kind_count]DeinitFn = [_]DeinitFn{noopDeinit} ** ref_kind_count;

/// 注册类型特定的析构函数
///
/// 各对象模块在初始化时调用，将自身的 deinit 实现填入分派表。
pub fn registerDeinit(kind: RefKind, f: DeinitFn) void {
    deinit_table[@intFromEnum(kind)] = f;
}

/// 统一 retain：原子递增引用计数，返回自身以便链式调用
///
/// 使用原子操作保证线程安全，无竞争时开销约 1 周期（x86 LOCK 前缀）。
pub fn retain(obj: *ObjHeader) *ObjHeader {
    _ = @atomicRmw(u32, &obj.rc, .Add, 1, .monotonic);
    return obj;
}

/// 统一 release：原子递减引用计数，归零时分派到类型特定 deinit
///
/// 使用 acq_rel 内存序保证 deinit 看到所有先行写操作（Zig 0.15+ 移除了 @fence，
/// 改用 acq_rel RMW 同时提供 acquire 与 release 语义）。
/// deinit 函数负责释放内部资源并销毁对象本体。
pub fn release(obj: *ObjHeader, allocator: std.mem.Allocator) void {
    const old = @atomicRmw(u32, &obj.rc, .Sub, 1, .acq_rel);
    if (old == 1) {
        deinit_table[@intFromEnum(obj.type_tag)](obj, allocator);
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "retain 与 release 引用计数" {
    var obj = ObjHeader{ .type_tag = .array, .rc = 1 };
    _ = retain(&obj);
    try std.testing.expectEqual(@as(u32, 2), obj.rc);
    // rc 从 2 递减到 1，不触发 deinit 分派
    release(&obj, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), obj.rc);
}

test "ObjHeader 布局为 8B" {
    // extern struct 保证 8B 大小（1B tag + 3B padding + 4B rc）
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ObjHeader));
}
