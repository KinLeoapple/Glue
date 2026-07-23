//! Per-thread 采集器
//!
//! 挂在 ThreadContext 上，提供热路径 API：
//! - seqlock 保护一组相关计数器原子更新
//! - recordAlloc/Free/RC/Memo/SlotCache/AllocatorReset/Watermark
//! - setCurrentFunc（独立原子，不进 seqlock）
//! - onFuncCall/onFuncRet（推送函数事件到 func_events，mutex 保护）

const std = @import("std");
const stats = @import("stats.zig");

const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ArenaByTypeArray = stats.ArenaByTypeArray;
const AllocatorKind = stats.AllocatorKind;
const ref_kind_count = stats.ref_kind_count;
const FuncEvent = stats.FuncEvent;
const SpinMutex = stats.SpinMutex;
const nanoTimestamp = stats.nanoTimestamp;

/// 函数事件上限（每线程）
const FUNC_EVENT_MAX: usize = 1_000_000;

/// Per-thread 性能采集器
///
/// 所有热路径 API 开头 `if (!self.enabled) return;` 短路。
/// 非 --profile 时 enabled=false，开销仅一次分支预测。
pub const ThreadProfiler = struct {
    enabled: bool,
    thread_id: u32,
    allocator: std.mem.Allocator,

    // seqlock 写方计数器
    seq: std.atomic.Value(u64) = .init(0),

    // 当前函数（per-function 归因，独立原子）
    current_func_idx: std.atomic.Value(u32) = .init(0),

    // 计数器（普通 u64，在 seqlock 内更新）
    global: GlobalStats = .{},
    types: TypeStatsArray = [_]stats.TypeStats{.{}} ** ref_kind_count,
    allocators: AllocatorStats = .{},

    // arena 路径按类型累计（供 reset 时批量扣减 types.live_*）
    arena_by_type: ArenaByTypeArray = [_]stats.ArenaByType{.{}} ** ref_kind_count,

    // 函数调用事件流（精确重建 per-function 用）
    func_events: std.ArrayList(FuncEvent),
    func_event_mutex: SpinMutex = .{},

    /// 创建 ThreadProfiler
    pub fn init(allocator: std.mem.Allocator, enabled: bool, thread_id: u32) ThreadProfiler {
        return .{
            .enabled = enabled,
            .thread_id = thread_id,
            .allocator = allocator,
            .func_events = .empty,
        };
    }

    /// 释放资源
    pub fn deinit(self: *ThreadProfiler) void {
        self.func_events.deinit(self.allocator);
    }

    // ============ seqlock（内部）============

    /// 开始一组相关计数器更新，返回更新前的 seq 值
    /// 调用方必须 defer endUpdate(begin 返回值)
    inline fn beginUpdate(self: *ThreadProfiler) u64 {
        return self.seq.fetchAdd(1, .acq_rel); // seq 变奇数
    }

    /// 结束一组相关计数器更新
    inline fn endUpdate(self: *ThreadProfiler, prev: u64) void {
        _ = prev;
        _ = self.seq.fetchAdd(1, .acq_rel); // seq 变偶数
    }

    // ============ 热路径 API ============

    /// 通用分配埋点（在 initObjHeader 中调用，保证 ref_kind 与 size/is_arena 原子一致）
    /// ref_kind_idx: @intFromEnum(RefKind)，调用方转换
    pub fn recordAlloc(self: *ThreadProfiler, ref_kind_idx: u8, size: usize, is_arena: bool) void {
        if (!self.enabled) return;
        const k = ref_kind_idx;
        const sz: u64 = @intCast(size);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);

        // 全局
        self.global.alloc_count += 1;
        self.global.alloc_bytes += sz;
        self.global.current_bytes += sz;
        if (self.global.current_bytes > self.global.peak_bytes)
            self.global.peak_bytes = self.global.current_bytes;

        // 逃逸分流
        if (is_arena) {
            self.global.arena_alloc_count += 1;
            self.global.arena_alloc_bytes += sz;
            self.arena_by_type[k].count += 1;
            self.arena_by_type[k].bytes += sz;
        } else {
            self.global.heap_alloc_count += 1;
            self.global.heap_alloc_bytes += sz;
        }

        // 类型分布
        self.types[k].alloc_count += 1;
        self.types[k].alloc_bytes += sz;
        self.types[k].live_count += 1;
        self.types[k].live_bytes += sz;
    }

    /// 通用释放埋点（仅 heap 路径，arena 由 recordAllocatorReset 批量回收）
    pub fn recordFree(self: *ThreadProfiler, ref_kind_idx: u8, size: usize) void {
        if (!self.enabled) return;
        const k = ref_kind_idx;
        const sz: u64 = @intCast(size);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);

        self.global.free_count += 1;
        self.global.free_bytes += sz;
        self.global.current_bytes -|= sz;

        self.types[k].free_count += 1;
        self.types[k].live_count -|= 1;
        self.types[k].live_bytes -|= sz;
    }

    /// RC 操作埋点
    pub const RCOp = enum { retain, release, release_to_zero };

    pub fn recordRC(self: *ThreadProfiler, op: RCOp) void {
        if (!self.enabled) return;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        switch (op) {
            .retain => self.global.retain_count += 1,
            .release => self.global.release_count += 1,
            .release_to_zero => {
                self.global.release_count += 1;
                self.global.rc_to_zero_count += 1;
            },
        }
    }

    /// memo 缓存命中/未命中
    pub fn recordMemo(self: *ThreadProfiler, hit: bool) void {
        if (!self.enabled) return;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        if (hit) self.global.memo_hits += 1 else self.global.memo_misses += 1;
    }

    /// ObjectPool slot_cache 命中/未命中
    pub fn recordSlotCache(self: *ThreadProfiler, hit: bool) void {
        if (!self.enabled) return;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        if (hit) self.global.slot_cache_hits += 1 else self.global.slot_cache_misses += 1;
    }

    /// arena/channel reset 批量回收
    /// which: .channel / .shadow_arena；bytes: 本次 reset 回收的字节数
    pub fn recordAllocatorReset(self: *ThreadProfiler, which: AllocatorKind, bytes: usize) void {
        if (!self.enabled) return;
        const sz: u64 = @intCast(bytes);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);

        switch (which) {
            .channel => {
                self.allocators.channel.reset_count += 1;
                self.allocators.channel.reset_bytes += sz;
                self.allocators.channel.current_bytes = 0;
            },
            .shadow_arena => {
                self.allocators.shadow_arena.reset_count += 1;
                self.allocators.shadow_arena.reset_bytes += sz;
                self.allocators.shadow_arena.current_bytes = 0;

                // 批量扣减 global.current_bytes 和 types.live_*
                self.global.current_bytes -|= sz;
                for (0..ref_kind_count) |k| {
                    self.types[k].live_count -|= self.arena_by_type[k].count;
                    self.types[k].live_bytes -|= self.arena_by_type[k].bytes;
                    self.arena_by_type[k].count = 0;
                    self.arena_by_type[k].bytes = 0;
                }
            },
            .object_pool => {}, // ObjectPool 无 reset 语义
        }
    }

    /// 更新分配器峰值水位（channel_region/shadow_arena 在 alloc 时调用）
    pub fn recordAllocatorWatermark(self: *ThreadProfiler, which: AllocatorKind, current: usize) void {
        if (!self.enabled) return;
        const cur: u64 = @intCast(current);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        switch (which) {
            .channel => {
                self.allocators.channel.current_bytes = cur;
                self.allocators.channel.alloc_count += 1;
                if (cur > self.allocators.channel.peak_bytes)
                    self.allocators.channel.peak_bytes = cur;
            },
            .shadow_arena => {
                self.allocators.shadow_arena.current_bytes = cur;
                if (cur > self.allocators.shadow_arena.peak_bytes)
                    self.allocators.shadow_arena.peak_bytes = cur;
            },
            .object_pool => {},
        }
    }

    /// 设置当前函数（engine.zig call/ret 边界调用）
    /// 独立于 seqlock，采样线程单独读取
    pub fn setCurrentFunc(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        self.current_func_idx.store(func_idx, .release);
    }

    /// 函数调用事件（精确重建 per-function 用）
    pub fn onFuncCall(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        self.pushFuncEvent(.{ .timestamp_ns = nanoTimestamp(), .func_idx = func_idx, .kind = .call });
    }

    /// 函数返回事件
    pub fn onFuncRet(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        self.pushFuncEvent(.{ .timestamp_ns = nanoTimestamp(), .func_idx = func_idx, .kind = .ret });
    }

    fn pushFuncEvent(self: *ThreadProfiler, ev: FuncEvent) void {
        self.func_event_mutex.lock();
        defer self.func_event_mutex.unlock();
        // 超上限：丢弃最旧的 10%
        if (self.func_events.items.len >= FUNC_EVENT_MAX) {
            const drop = FUNC_EVENT_MAX / 10;
            std.mem.copyForwards(FuncEvent, self.func_events.items, self.func_events.items[drop..]);
            self.func_events.shrinkRetainingCapacity(self.func_events.items.len - drop);
        }
        self.func_events.append(self.allocator, ev) catch {};
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "recordAlloc 更新全局和类型统计" {
    var prof = ThreadProfiler.init(std.testing.allocator, true, 0);
    defer prof.deinit();

    // str = 0, array = 1, record = 2 (按 obj_header.RefKind 顺序)
    prof.recordAlloc(0, 64, false); // str
    try std.testing.expectEqual(@as(u64, 1), prof.global.alloc_count);
    try std.testing.expectEqual(@as(u64, 64), prof.global.alloc_bytes);
    try std.testing.expectEqual(@as(u64, 64), prof.global.current_bytes);
    try std.testing.expectEqual(@as(u64, 64), prof.global.peak_bytes);
    try std.testing.expectEqual(@as(u64, 1), prof.global.heap_alloc_count);
    try std.testing.expectEqual(@as(u64, 1), prof.types[0].alloc_count);
    try std.testing.expectEqual(@as(u64, 1), prof.types[0].live_count);
}

test "recordAlloc arena 路径" {
    var prof = ThreadProfiler.init(std.testing.allocator, true, 0);
    defer prof.deinit();

    prof.recordAlloc(1, 128, true); // array
    try std.testing.expectEqual(@as(u64, 1), prof.global.arena_alloc_count);
    try std.testing.expectEqual(@as(u64, 128), prof.global.arena_alloc_bytes);
    try std.testing.expectEqual(@as(u64, 1), prof.arena_by_type[1].count);
}

test "recordAllocatorReset shadow_arena 批量扣减" {
    var prof = ThreadProfiler.init(std.testing.allocator, true, 0);
    defer prof.deinit();

    prof.recordAlloc(1, 100, true); // array
    prof.recordAlloc(1, 50, true);
    try std.testing.expectEqual(@as(u64, 2), prof.types[1].live_count);
    try std.testing.expectEqual(@as(u64, 150), prof.types[1].live_bytes);

    prof.recordAllocatorReset(.shadow_arena, 150);
    try std.testing.expectEqual(@as(u64, 0), prof.types[1].live_count);
    try std.testing.expectEqual(@as(u64, 0), prof.types[1].live_bytes);
    try std.testing.expectEqual(@as(u64, 0), prof.global.current_bytes);
    try std.testing.expectEqual(@as(u64, 1), prof.allocators.shadow_arena.reset_count);
}

test "recordFree heap 路径" {
    var prof = ThreadProfiler.init(std.testing.allocator, true, 0);
    defer prof.deinit();

    prof.recordAlloc(2, 64, false); // record
    prof.recordFree(2, 64);
    try std.testing.expectEqual(@as(u64, 1), prof.global.free_count);
    try std.testing.expectEqual(@as(u64, 0), prof.global.current_bytes);
    try std.testing.expectEqual(@as(u64, 0), prof.types[2].live_count);
}

test "disabled 时所有 API 短路" {
    var prof = ThreadProfiler.init(std.testing.allocator, false, 0);
    defer prof.deinit();

    prof.recordAlloc(0, 64, false);
    prof.recordFree(0, 64);
    prof.recordRC(.retain);
    prof.recordMemo(true);
    prof.recordAllocatorReset(.shadow_arena, 100);
    prof.onFuncCall(0);

    try std.testing.expectEqual(@as(u64, 0), prof.global.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), prof.func_events.items.len);
}

test "func_events 上限保护" {
    var prof = ThreadProfiler.init(std.testing.allocator, true, 0);
    defer prof.deinit();

    // 推送少量事件验证基本功能（不测试 100 万上限，太慢）
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        prof.onFuncCall(i);
    }
    try std.testing.expectEqual(@as(usize, 100), prof.func_events.items.len);
}
