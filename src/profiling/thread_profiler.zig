//! Per-thread 采集器
//!
//! 挂在 ThreadContext 上，提供热路径 API：
//! - seqlock 保护一组相关计数器原子更新
//! - recordAlloc/Free/RC/Memo/SlotCache/AllocatorReset/Watermark
//! - setCurrentFunc（独立原子，不进 seqlock）
//! - onFuncCall/onFuncRet（实时调用栈计时，O(1) 无缓冲区限制）

const std = @import("std");
const stats = @import("stats.zig");

const GlobalStats = stats.GlobalStats;
const TypeStatsArray = stats.TypeStatsArray;
const AllocatorStats = stats.AllocatorStats;
const ArenaByTypeArray = stats.ArenaByTypeArray;
const AllocatorKind = stats.AllocatorKind;
const ref_kind_count = stats.ref_kind_count;
const FuncAllocArray = stats.FuncAllocArray;
const MAX_TRACKED_FUNCS = stats.MAX_TRACKED_FUNCS;
const MAX_CALL_DEPTH = stats.MAX_CALL_DEPTH;
const CallStackEntry = stats.CallStackEntry;
const FuncTimeArray = stats.FuncTimeArray;
const FuncCallArray = stats.FuncCallArray;
const nanoTimestamp = stats.nanoTimestamp;

/// Per-thread 性能采集器
///
/// 所有热路径 API 开头 `if (!self.enabled) return;` 短路。
/// 非 --profile 时 enabled=false，开销仅一次分支预测。
pub const ThreadProfiler = struct {
    enabled: bool,
    thread_id: u32,

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

    // per-function 分配/RC 累加（热路径 O(1) 数组访问，按 current_func_idx 索引）
    func_alloc: FuncAllocArray = [_]stats.FuncAllocAccum{.{}} ** MAX_TRACKED_FUNCS,

    // 实时调用栈计时（替代 func_events 事件流，O(1) 无缓冲区限制）
    func_call_stack: [MAX_CALL_DEPTH]CallStackEntry = undefined,
    func_call_stack_top: u32 = 0,
    func_time: FuncTimeArray = [_]u64{0} ** MAX_TRACKED_FUNCS,
    func_calls: FuncCallArray = [_]u64{0} ** MAX_TRACKED_FUNCS,

    /// 创建 ThreadProfiler
    pub fn init(enabled: bool, thread_id: u32) ThreadProfiler {
        return .{
            .enabled = enabled,
            .thread_id = thread_id,
        };
    }

    /// 释放资源（当前无堆分配资源，保留 API 兼容）
    pub fn deinit(self: *ThreadProfiler) void {
        _ = self;
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

        // per-function 归因（O(1) 数组访问，current_func_idx 独立原子读取）
        const fi = self.current_func_idx.load(.acquire);
        if (fi < MAX_TRACKED_FUNCS) {
            if (is_arena) {
                self.func_alloc[fi].arena_bytes += sz;
            } else {
                self.func_alloc[fi].heap_bytes += sz;
            }
        }
    }

    /// 通用释放埋点（仅 heap 路径，arena 由 recordAllocatorReset 批量回收）
    /// size=0 时仅更新计数，不更新字节（release 路径不知道 size）
    pub fn recordFree(self: *ThreadProfiler, ref_kind_idx: u8, size: usize) void {
        if (!self.enabled) return;
        const k = ref_kind_idx;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);

        self.global.free_count += 1;
        self.types[k].free_count += 1;
        self.types[k].live_count -|= 1;

        if (size > 0) {
            const sz: u64 = @intCast(size);
            self.global.free_bytes += sz;
            self.global.current_bytes -|= sz;
            self.types[k].live_bytes -|= sz;
        }
    }

    /// RC 操作埋点
    pub const RCOp = enum { retain, release, release_to_zero };

    pub fn recordRC(self: *ThreadProfiler, op: RCOp) void {
        if (!self.enabled) return;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        switch (op) {
            .retain => {
                self.global.retain_count += 1;
                const fi = self.current_func_idx.load(.acquire);
                if (fi < MAX_TRACKED_FUNCS) self.func_alloc[fi].retain_count += 1;
            },
            .release => {
                self.global.release_count += 1;
                const fi = self.current_func_idx.load(.acquire);
                if (fi < MAX_TRACKED_FUNCS) self.func_alloc[fi].release_count += 1;
            },
            .release_to_zero => {
                self.global.release_count += 1;
                self.global.rc_to_zero_count += 1;
                const fi = self.current_func_idx.load(.acquire);
                if (fi < MAX_TRACKED_FUNCS) self.func_alloc[fi].release_count += 1;
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
                // 扣减 global 总内存中 channel 部分
                self.global.current_bytes -|= self.allocators.channel.current_bytes;
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
    /// channel 内存同时纳入 global.current_bytes/peak_bytes（与 ObjHeader 内存独立，不重复计数）
    /// is_alloc=true 时计入 alloc_count（实际分配），false 时仅更新水位（如 leaveFunction 后重设）
    pub fn recordAllocatorWatermark(self: *ThreadProfiler, which: AllocatorKind, current: usize, is_alloc: bool) void {
        if (!self.enabled) return;
        const cur: u64 = @intCast(current);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        switch (which) {
            .channel => {
                const old_chan = self.allocators.channel.current_bytes;
                self.allocators.channel.current_bytes = cur;
                if (is_alloc) self.allocators.channel.alloc_count += 1;
                if (cur > self.allocators.channel.peak_bytes)
                    self.allocators.channel.peak_bytes = cur;
                // channel 内存纳入 global 总内存（channel 与 ObjHeader 是不同分配器，不重复）
                if (cur > old_chan) {
                    self.global.current_bytes += (cur - old_chan);
                } else if (old_chan > cur) {
                    self.global.current_bytes -|= (old_chan - cur);
                }
                if (self.global.current_bytes > self.global.peak_bytes)
                    self.global.peak_bytes = self.global.current_bytes;
            },
            .shadow_arena => {
                self.allocators.shadow_arena.current_bytes = cur;
                if (cur > self.allocators.shadow_arena.peak_bytes)
                    self.allocators.shadow_arena.peak_bytes = cur;
            },
            .object_pool => {},
        }
    }

    /// ObjectPool 分配埋点（allocBySize/allocLarge 调用）
    /// is_buddy=true 走 buddy 路径，is_buddy=false 走页池路径
    pub fn recordObjectPoolAlloc(self: *ThreadProfiler, size: usize, is_buddy: bool) void {
        if (!self.enabled) return;
        const sz: u64 = @intCast(size);
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        if (is_buddy) {
            self.allocators.object_pool.buddy_alloc_count += 1;
            self.allocators.object_pool.buddy_alloc_bytes += sz;
        } else {
            self.allocators.object_pool.page_alloc_count += 1;
        }
    }

    /// ObjectPool 释放埋点（freeBySize/freeObj 调用）
    pub fn recordObjectPoolFree(self: *ThreadProfiler) void {
        if (!self.enabled) return;
        const prev = self.beginUpdate();
        defer self.endUpdate(prev);
        self.allocators.object_pool.page_free_count += 1;
    }

    /// 设置当前函数（engine.zig call/ret 边界调用）
    /// 独立于 seqlock，采样线程单独读取
    pub fn setCurrentFunc(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        self.current_func_idx.store(func_idx, .release);
    }

    /// 函数调用：压入调用栈，记录起始时间戳
    /// 超过 MAX_CALL_DEPTH 时跳过（不崩溃），O(1) 操作无堆分配
    pub fn onFuncCall(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        if (self.func_call_stack_top >= MAX_CALL_DEPTH) return;
        self.func_call_stack[self.func_call_stack_top] = .{
            .func_idx = func_idx,
            .start_ns = nanoTimestamp(),
        };
        self.func_call_stack_top += 1;
    }

    /// 函数返回：弹出调用栈，累加 per-function 耗时和调用计数
    /// 调用栈为空时跳过（防御性，正常情况下 call/ret 配对）
    pub fn onFuncRet(self: *ThreadProfiler, func_idx: u32) void {
        if (!self.enabled) return;
        if (self.func_call_stack_top == 0) return;
        self.func_call_stack_top -= 1;
        const entry = self.func_call_stack[self.func_call_stack_top];
        const now = nanoTimestamp();
        const dur: u64 = @intCast(now - entry.start_ns);
        if (func_idx < MAX_TRACKED_FUNCS) {
            self.func_time[func_idx] += dur;
            self.func_calls[func_idx] += 1;
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "recordAlloc 更新全局和类型统计" {
    var prof = ThreadProfiler.init(true, 0);
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
    var prof = ThreadProfiler.init(true, 0);
    defer prof.deinit();

    prof.recordAlloc(1, 128, true); // array
    try std.testing.expectEqual(@as(u64, 1), prof.global.arena_alloc_count);
    try std.testing.expectEqual(@as(u64, 128), prof.global.arena_alloc_bytes);
    try std.testing.expectEqual(@as(u64, 1), prof.arena_by_type[1].count);
}

test "recordAllocatorReset shadow_arena 批量扣减" {
    var prof = ThreadProfiler.init(true, 0);
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
    var prof = ThreadProfiler.init(true, 0);
    defer prof.deinit();

    prof.recordAlloc(2, 64, false); // record
    prof.recordFree(2, 64);
    try std.testing.expectEqual(@as(u64, 1), prof.global.free_count);
    try std.testing.expectEqual(@as(u64, 0), prof.global.current_bytes);
    try std.testing.expectEqual(@as(u64, 0), prof.types[2].live_count);
}

test "disabled 时所有 API 短路" {
    var prof = ThreadProfiler.init(false, 0);
    defer prof.deinit();

    prof.recordAlloc(0, 64, false);
    prof.recordFree(0, 64);
    prof.recordRC(.retain);
    prof.recordMemo(true);
    prof.recordAllocatorReset(.shadow_arena, 100);
    prof.onFuncCall(0);
    prof.onFuncRet(0);

    try std.testing.expectEqual(@as(u64, 0), prof.global.alloc_count);
    try std.testing.expectEqual(@as(u32, 0), prof.func_call_stack_top);
    try std.testing.expectEqual(@as(u64, 0), prof.func_calls[0]);
}

test "调用栈实时计时" {
    var prof = ThreadProfiler.init(true, 0);
    defer prof.deinit();

    // 模拟 call A → call B → ret B → ret A
    prof.onFuncCall(0); // A
    prof.onFuncCall(1); // B
    prof.onFuncRet(1); // B 返回
    prof.onFuncRet(0); // A 返回

    // 每个函数各调用 1 次
    try std.testing.expectEqual(@as(u64, 1), prof.func_calls[0]);
    try std.testing.expectEqual(@as(u64, 1), prof.func_calls[1]);
    // 耗时非负（纳秒级，可能为 0 在高速机器上）
    try std.testing.expect(prof.func_time[0] >= prof.func_time[1]);
    // 调用栈已清空
    try std.testing.expectEqual(@as(u32, 0), prof.func_call_stack_top);
}

test "调用栈下溢防御" {
    var prof = ThreadProfiler.init(true, 0);
    defer prof.deinit();

    // 无匹配 call 的 ret，应安全跳过
    prof.onFuncRet(0);
    try std.testing.expectEqual(@as(u32, 0), prof.func_call_stack_top);
    try std.testing.expectEqual(@as(u64, 0), prof.func_calls[0]);
}
