//! 协程帧结构与帧池（第四分配器）。
//!
//! 协程帧是 async 函数调度的执行载体：状态机状态 + 局部值环境。
//! 无栈设计——帧不含独立栈，sync 函数调用借用 worker 的临时栈。
//!
//! 帧池是 LFE 的第四分配器（有意调整「三分配器」约束）：
//! - size-class 分桶 + LIFO free list
//! - O(1) 分配/释放，缓存友好
//! - Io.Mutex 保护（fiber-aware）
//! - 池只增不减，释放只回 free list

const std = @import("std");
const obj_header = @import("value").obj_header;
const ObjHeader = obj_header.ObjHeader;
const RefKind = obj_header.RefKind;
const Value = @import("value").Value;
const ir_mod = @import("ir");
const FrameLayout = ir_mod.FrameLayout;

/// 协程状态（与 AsyncStatus 对齐，但扩展 Ready/Suspended 运行态）
pub const CoroutineStatus = enum(u8) {
    /// 刚创建，未入就绪队列
    pending,
    /// 在就绪队列中，等待 worker 调度
    ready,
    /// 正在 worker 上执行
    running,
    /// 已挂起，等待唤醒事件（channel/handle/Io）
    suspended,
    /// 正常完成，结果已写入
    completed,
    /// 异常失败，panic_buf 已填充
    failed,
    /// 被 cancel 取消
    cancelled,
};

/// 协程挂起目标：决定帧注册到哪个等待队列
pub const SuspendTarget = union(enum) {
    /// 未挂起
    none,
    /// 等待 channel 可读（orbit_chan_recv 挂起）
    chan_recv: *anyopaque,
    /// 等待 channel 可写（orbit_chan_send 挂起）
    chan_send: *anyopaque,
    /// 等待 async handle 完成（orbit_async_join 挂起）
    async_join: *anyopaque,
};

/// 协程帧：async 函数实例的执行载体。
///
/// 内存布局：[ObjHeader][CoroutineFrame 固定字段][locals 区，64B 对齐]
/// locals 区大小在编译期由 FrameLayout 决定，运行时按需分配。
/// 本结构定义固定字段部分，locals 区紧跟其后（通过 locals_offset 定位）。
pub const CoroutineFrame = struct {
    header: ObjHeader,
    /// 当前段索引（状态机状态）
    state: u16,
    /// async 函数索引
    func_idx: u16,
    /// 当前挂起目标
    suspend_target: SuspendTarget,
    /// 已注册 defer 项数（defer 栈深度）
    defer_depth: u16,
    /// 当前循环嵌套层
    nesting_level: u8,
    /// 协程状态（原子，跨 worker 可见）
    status: std.atomic.Value(u8),
    /// 结果值（completed 时有效）
    result: ?Value,
    /// 关联的 AsyncHandle（spawn 时由 Engine 写入，complete 时 worker 据此写结果 + 唤醒 join 等待者）
    async_handle: ?*anyopaque = null,
    /// panic 消息缓冲（内联，无跨线程分配）
    panic_buf: [PANIC_BUF_SIZE]u8,
    panic_len: u16,
    /// locals 区起始偏移（相对于 frame 指针）
    locals_offset: u32,
    /// locals 区字节大小
    locals_size: u32,
    /// 等待队列链表指针（SuspendRegistry 的 WaiterList 用）
    /// 帧挂起时串入对应 channel/handle 的等待链；唤醒时摘除
    wait_next: ?*CoroutineFrame = null,
    /// 就绪队列链表指针（Worker 本地就绪队列用，单线程访问无需原子）
    ready_next: ?*CoroutineFrame = null,
    /// 泛型类型实参（spawn 时写入，segmentInstallFrame 段恢复时读取）
    /// 切片生命周期挂在 IR arena，帧只持有引用
    type_args: []const u16 = &[_]u16{},

    /// panic 缓冲区容量
    pub const PANIC_BUF_SIZE: usize = 128;

    /// 初始化帧的固定字段（locals 区由帧池单独写入）
    pub fn initFixed(func_idx: u16, layout: FrameLayout, type_args: []const u16) CoroutineFrame {
        return .{
            .header = .{ .type_tag = .coroutine_frame },
            .state = 0,
            .func_idx = func_idx,
            .suspend_target = .none,
            .defer_depth = 0,
            .nesting_level = 0,
            .status = std.atomic.Value(u8).init(@intFromEnum(CoroutineStatus.pending)),
            .result = null,
            .panic_buf = [_]u8{0} ** PANIC_BUF_SIZE,
            .panic_len = 0,
            // locals 区紧跟固定字段之后，按 64 对齐
            .locals_offset = @intCast(std.mem.alignForward(usize, @sizeOf(CoroutineFrame), 64)),
            .locals_size = layout.total_size,
            .type_args = type_args,
        };
    }

    /// 获取 locals 区指针
    pub fn localsPtr(self: *CoroutineFrame) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + self.locals_offset;
    }

    /// 获取状态
    pub fn getStatus(self: *const CoroutineFrame) CoroutineStatus {
        return @enumFromInt(self.status.load(.acquire));
    }

    /// 设置状态
    pub fn setStatus(self: *CoroutineFrame, s: CoroutineStatus) void {
        self.status.store(@intFromEnum(s), .release);
    }

    /// 写 panic 消息
    pub fn setPanic(self: *CoroutineFrame, msg: []const u8) void {
        const n = @min(msg.len, PANIC_BUF_SIZE);
        @memcpy(self.panic_buf[0..n], msg[0..n]);
        self.panic_len = @intCast(n);
    }

    /// 读 panic 消息
    pub fn getPanic(self: *const CoroutineFrame) []const u8 {
        return self.panic_buf[0..self.panic_len];
    }
};

/// 帧池统计（profiling 用）
pub const FramePoolStats = struct {
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    active_frames: u64 = 0,
    backing_alloc_count: u64 = 0,
};

/// 空闲帧节点（free list 链表，复用帧内存）
const FreeNode = struct {
    next: ?*FreeNode = null,
};

/// 帧池的 size class 分桶
const SIZE_CLASSES: [6]usize = .{ 64, 128, 256, 512, 1024, 4096 };
const BUCKET_COUNT: usize = SIZE_CLASSES.len;

/// 协程帧池：第四分配器。
///
/// 按 FrameLayout.total_size 归入最近 size class 桶，
/// 每桶独立 LIFO free list。分配 O(1)，释放 O(1)。
/// Io.Mutex 保护，fiber-aware（协程化后挂起 fiber 而非阻塞线程）。
pub const FramePool = struct {
    backing: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    free_lists: [BUCKET_COUNT]?*FreeNode = [_]?*FreeNode{null} ** BUCKET_COUNT,
    stats: FramePoolStats = .{},

    /// 创建帧池
    pub fn init(backing: std.mem.Allocator, io: std.Io) FramePool {
        return .{
            .backing = backing,
            .io = io,
        };
    }

    /// 释放帧池：归还 free list 中所有帧到 backing allocator
    pub fn deinit(self: *FramePool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // 遍历每个 size class 桶，释放所有 free list 节点
        for (SIZE_CLASSES, 0..) |class, i| {
            while (self.free_lists[i]) |node| {
                self.free_lists[i] = node.next;
                const ptr: [*]align(64) u8 = @alignCast(@ptrCast(node));
                self.backing.free(ptr[0..class]);
            }
        }
    }

    /// 分配协程帧：O(1) free list pop，无可用则向 backing 申请
    pub fn alloc(self: *FramePool, func_idx: u16, layout: FrameLayout, type_args: []const u16) !*CoroutineFrame {
        const frame_size = @as(usize, @sizeOf(CoroutineFrame)) + layout.total_size;
        const bucket = bucketFor(frame_size);
        const alloc_size = SIZE_CLASSES[bucket];

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 尝试从 free list 取
        if (self.free_lists[bucket]) |node| {
            self.free_lists[bucket] = node.next;
            self.stats.alloc_count += 1;
            self.stats.active_frames += 1;
            const frame: *CoroutineFrame = @ptrCast(@alignCast(node));
            frame.* = CoroutineFrame.initFixed(func_idx, layout, type_args);
            return frame;
        }

        // free list 空，向 backing 申请（64B 对齐，SIMD 友好）
        const mem = try self.backing.alignedAlloc(u8, .@"64", alloc_size);
        self.stats.backing_alloc_count += 1;
        self.stats.alloc_count += 1;
        self.stats.active_frames += 1;

        const frame: *CoroutineFrame = @ptrCast(@alignCast(mem.ptr));
        frame.* = CoroutineFrame.initFixed(func_idx, layout, type_args);
        return frame;
    }

    /// 释放协程帧：O(1) free list push，不归还 backing
    pub fn free(self: *FramePool, frame: *CoroutineFrame) void {
        const frame_size = @as(usize, @sizeOf(CoroutineFrame)) + frame.locals_size;
        const bucket = bucketFor(frame_size);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const node: *FreeNode = @ptrCast(@alignCast(frame));
        node.next = self.free_lists[bucket];
        self.free_lists[bucket] = node;
        self.stats.free_count += 1;
        self.stats.active_frames -= 1;
    }

    /// 获取统计快照（profiling 用）
    pub fn getStats(self: *FramePool) FramePoolStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    /// 根据 frame_size 选择 size class 桶
    fn bucketFor(frame_size: usize) usize {
        for (SIZE_CLASSES, 0..) |class, i| {
            if (frame_size <= class) return i;
        }
        return BUCKET_COUNT - 1; // 超大帧归入最大桶
    }
};
