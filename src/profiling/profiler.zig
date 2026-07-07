//! Glue 全管线 profiler —— 独立模块，覆盖 lex/parse/type_check/compile/vm 全阶段。
//!
//! 触发：命令行选项 `--profile`（glue run --profile / glue debug --profile）。
//! 输出到 stderr，不干扰程序正常输出。
//!
//! 六类统计：
//! 1. 阶段计时：各阶段墙钟耗时（基于 std.Io.Clock.awake 单调时钟）。
//! 2. 内存统计：SlabAllocator 峰值/活跃/保留字节 + 碎片率 + 缓存规模 + idle 回收。
//! 3. VM opcode 频率：按 u8 索引计数 + 按功能大类聚合（算术/内存/控制流/调用/...）。
//! 4. VM 调用统计：call/method/tail_call/spawn/await/cancel 累计计数。
//! 5. memoization 统计：hit/miss/disabled/cache_size，反映 JIT Phase 3 收益。
//! 6. ThreadCache 统计：hit/miss/refill/drain，反映快路径命中率。
//!
//! 设计：profiler 完全独立（不依赖 vm/ast 等模块），opcode 名字通过回调注入，
//! 避免 profiler ↔ vm 循环依赖。所有计数器为 u64 atomic（热路径调用方判 enabled 后再递增）。

const std = @import("std");

/// 管线阶段。按 executeSource → tryRunOnVM 的执行顺序。
pub const Phase = enum {
    lex,
    parse,
    type_check,
    compile,
    vm,
};

const PHASE_NAMES = [@typeInfo(Phase).@"enum".fields.len][]const u8{
    "lex",
    "parse",
    "type_check",
    "compile",
    "vm",
};

// ============================================================
// opcode 大类分类表（comptime 生成，用于 dump 时聚合）
// ============================================================

/// opcode 功能大类。用于聚合输出，识别热点类别（如算术密集 vs 调用密集）。
const OpCategory = enum {
    const_literal, // 常量/字面量加载
    local, // 局部变量读写
    upvalue, // upvalue 读写
    global, // 全局变量读写
    arithmetic, // 算术（add/sub/mul/div/mod/neg）
    comparison, // 比较（eq/neq/lt/gt/le/ge）
    bitwise, // 位运算（and/or/xor）
    logical, // 逻辑（not + 短路跳转）
    jump, // 跳转（jump/jump_if_false/jump_if_true/for_next）
    stack, // 栈操作（pop/pop_n/dup）
    call, // 函数调用（call/call_value/call_rec/call_native/call_memoized/return）
    tail_call, // 尾调用（tail_call/tail_call_rec）
    method, // 方法调用（call_method）
    spawn, // 协程（spawn）
    construct, // 构造复合值（make_adt/make_array/make_record/make_newtype/make_atomic/make_lazy/make_trait/make_range/make_error）
    access, // 字段/索引访问（get_field/get_adt_field/index/test_ctor/test_newtype/get_newtype_inner）
    assign, // 字段/索引赋值（set_field/set_index/compound_local/compound_upvalue/push_inplace*）
    cast, // 类型转换（cast/coerce/concat_list/interp）
    exception, // 异常（throw/propagate/non_null/test_throw/get_throw_*）
    channel, // 通道（try_recv/recv）
    other, // 其他（closure/match_fail/set_local_letrec/set_local_assign/get_local_raw/get_upvalue_raw）
};

const OP_CATEGORY_NAMES = [@typeInfo(OpCategory).@"enum".fields.len][]const u8{
    "const/literal",
    "local var",
    "upvalue",
    "global var",
    "arithmetic",
    "comparison",
    "bitwise",
    "logical",
    "jump/control",
    "stack op",
    "call",
    "tail call",
    "method call",
    "spawn",
    "construct",
    "field/index access",
    "assign",
    "cast/convert",
    "exception",
    "channel",
    "other",
};

/// opcode → 大类映射。通过 opcode 名字前缀/关键字 comptime 分类。
/// 与 OpCode 枚举顺序无关，按名字模式匹配，对新 opcode 自动归入 other。
fn categorizeOpName(name: []const u8) OpCategory {
    // 调用类（先匹配，避免被 local/call 前缀误判）
    if (std.mem.startsWith(u8, name, "op_tail_call")) return .tail_call;
    if (std.mem.startsWith(u8, name, "op_call_method")) return .method;
    if (std.mem.startsWith(u8, name, "op_call")) return .call; // call/call_value/call_rec/call_native/call_memoized
    if (std.mem.eql(u8, name, "op_return")) return .call;
    if (std.mem.eql(u8, name, "op_spawn")) return .spawn;

    // 构造类
    if (std.mem.startsWith(u8, name, "op_make_")) return .construct;
    if (std.mem.eql(u8, name, "op_make_error")) return .construct;

    // 访问类
    if (std.mem.startsWith(u8, name, "op_get_field")) return .access;
    if (std.mem.startsWith(u8, name, "op_get_adt_field")) return .access;
    if (std.mem.startsWith(u8, name, "op_get_newtype_inner")) return .access;
    if (std.mem.startsWith(u8, name, "op_test_ctor")) return .access;
    if (std.mem.startsWith(u8, name, "op_test_newtype")) return .access;
    if (std.mem.eql(u8, name, "op_index")) return .access;

    // 赋值类
    if (std.mem.startsWith(u8, name, "op_set_field")) return .assign;
    if (std.mem.startsWith(u8, name, "op_set_index")) return .assign;
    if (std.mem.startsWith(u8, name, "op_compound_")) return .assign;
    if (std.mem.startsWith(u8, name, "op_push_inplace")) return .assign;

    // 局部变量
    if (std.mem.startsWith(u8, name, "op_get_local")) return .local;
    if (std.mem.startsWith(u8, name, "op_set_local")) return .local;

    // upvalue
    if (std.mem.startsWith(u8, name, "op_get_upvalue")) return .upvalue;
    if (std.mem.startsWith(u8, name, "op_set_upvalue")) return .upvalue;

    // 全局
    if (std.mem.startsWith(u8, name, "op_get_global")) return .global;
    if (std.mem.startsWith(u8, name, "op_set_global")) return .global;

    // 常量/字面量
    if (std.mem.startsWith(u8, name, "op_const")) return .const_literal;
    if (std.mem.eql(u8, name, "op_null")) return .const_literal;
    if (std.mem.eql(u8, name, "op_unit")) return .const_literal;
    if (std.mem.eql(u8, name, "op_true")) return .const_literal;
    if (std.mem.eql(u8, name, "op_false")) return .const_literal;

    // 算术
    if (std.mem.eql(u8, name, "op_add")) return .arithmetic;
    if (std.mem.eql(u8, name, "op_sub")) return .arithmetic;
    if (std.mem.eql(u8, name, "op_mul")) return .arithmetic;
    if (std.mem.eql(u8, name, "op_div")) return .arithmetic;
    if (std.mem.eql(u8, name, "op_mod")) return .arithmetic;
    if (std.mem.eql(u8, name, "op_neg")) return .arithmetic;

    // 比较
    if (std.mem.eql(u8, name, "op_eq")) return .comparison;
    if (std.mem.eql(u8, name, "op_neq")) return .comparison;
    if (std.mem.eql(u8, name, "op_lt")) return .comparison;
    if (std.mem.eql(u8, name, "op_gt")) return .comparison;
    if (std.mem.eql(u8, name, "op_le")) return .comparison;
    if (std.mem.eql(u8, name, "op_ge")) return .comparison;

    // 位运算
    if (std.mem.eql(u8, name, "op_bit_and")) return .bitwise;
    if (std.mem.eql(u8, name, "op_bit_or")) return .bitwise;
    if (std.mem.eql(u8, name, "op_bit_xor")) return .bitwise;

    // 逻辑/跳转
    if (std.mem.eql(u8, name, "op_not")) return .logical;
    if (std.mem.startsWith(u8, name, "op_jump")) return .jump;
    if (std.mem.eql(u8, name, "op_for_next")) return .jump;

    // 栈操作
    if (std.mem.startsWith(u8, name, "op_pop")) return .stack;
    if (std.mem.eql(u8, name, "op_dup")) return .stack;

    // 类型转换
    if (std.mem.eql(u8, name, "op_cast")) return .cast;
    if (std.mem.eql(u8, name, "op_coerce")) return .cast;
    if (std.mem.eql(u8, name, "op_concat_list")) return .cast;
    if (std.mem.eql(u8, name, "op_interp")) return .cast;

    // 异常
    if (std.mem.eql(u8, name, "op_throw")) return .exception;
    if (std.mem.eql(u8, name, "op_propagate")) return .exception;
    if (std.mem.eql(u8, name, "op_non_null")) return .exception;
    if (std.mem.startsWith(u8, name, "op_test_throw")) return .exception;
    if (std.mem.startsWith(u8, name, "op_get_throw")) return .exception;
    if (std.mem.startsWith(u8, name, "op_jump_if_null")) return .exception;
    if (std.mem.startsWith(u8, name, "op_jump_if_not_null")) return .exception;

    // 通道
    if (std.mem.startsWith(u8, name, "op_try_recv")) return .channel;
    if (std.mem.startsWith(u8, name, "op_recv")) return .channel;

    return .other;
}

// ============================================================
// Profiler 主体
// ============================================================

pub const Profiler = struct {
    enabled: bool = false,
    /// io 句柄（单调时钟需要）。null 时禁用计时。
    io: ?std.Io = null,

    // ── 阶段计时（纳秒）──
    phase_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = .{0} ** @typeInfo(Phase).@"enum".fields.len,
    phase_start: ?std.Io.Timestamp = null,
    current_phase: ?Phase = null,

    // ── VM opcode 计数（u8 索引，覆盖所有 OpCode 变体）──
    opcode_counts: [256]u64 = .{0} ** 256,
    /// opcode 索引 → 名字回调（由 VM 注入，避免 profiler 依赖 vm 模块）。null 时 dump 只输出索引。
    opcode_name_fn: ?*const fn (u8) []const u8 = null,

    // ── 内存统计（SlabAllocator，由 main.zig 在 VM 执行后注入）──
    /// reserved_bytes 峰值（向 backing 申请的最多字节数）。
    slab_peak_bytes: usize = 0,
    /// live_bytes 峰值（同时存活对象的最大字节数）。
    slab_live_peak_bytes: usize = 0,
    /// 结束时刻 live_bytes（理想为 0，表示无泄漏）。
    slab_live_bytes: usize = 0,
    /// 结束时刻 reserved_bytes（含 empty slab 缓存，可能 > 0）。
    slab_reserved_bytes: usize = 0,

    // ── 内存缓存规模快照（反映内存紧凑度 + idle 回收效益）──
    /// 结束时刻 empty_slabs 缓存数量（等待复用的空 slab）。
    slab_empty_count: usize = 0,
    /// 结束时刻活跃大对象数量（large_list 链长度）。
    slab_large_active: usize = 0,
    /// 结束时刻缓存大对象数量（large_free_list 链长度，idle 回收未归还的）。
    slab_large_cached: usize = 0,
    /// idle 回收协程累计归还的 slab 数。
    slab_evicted_slabs: u64 = 0,
    /// idle 回收协程累计归还的大对象数。
    slab_evicted_large: u64 = 0,
    /// idle 回收协程扫描次数。
    slab_evict_scans: u64 = 0,

    // ── VM 调用统计（atomic，热路径递增）──
    /// OP_CALL / OP_CALL_VALUE / OP_CALL_REC 累计执行数。
    vm_call_count: std.atomic.Value(u64) = .{ .raw = 0 },
    /// OP_TAIL_CALL / OP_TAIL_CALL_REC 累计执行数（TCO 复用帧）。
    vm_tail_call_count: std.atomic.Value(u64) = .{ .raw = 0 },
    /// OP_CALL_METHOD 累计执行数（内建方法分派）。
    vm_method_call_count: std.atomic.Value(u64) = .{ .raw = 0 },
    /// OP_SPAWN 累计执行数（协程创建）。
    vm_spawn_count: std.atomic.Value(u64) = .{ .raw = 0 },
    /// await() 调用数（Spawn<T>.await()）。
    vm_await_count: std.atomic.Value(u64) = .{ .raw = 0 },
    /// cancel() 调用数（Spawn<T>.cancel()）。
    vm_cancel_count: std.atomic.Value(u64) = .{ .raw = 0 },

    // ── memoization 统计（JIT Phase 3 收益指标）──
    /// 缓存命中数（跳过整个函数体）。
    vm_memo_hits: std.atomic.Value(u64) = .{ .raw = 0 },
    /// 缓存未命中数（执行函数体并缓存结果）。
    vm_memo_misses: std.atomic.Value(u64) = .{ .raw = 0 },
    /// 结束时刻 memo_cache 条目数。
    vm_memo_cache_size: usize = 0,
    /// 结束时刻被禁用的 memo_slot 数（连续 miss 超阈值）。
    vm_memo_disabled_count: usize = 0,

    // ── ThreadCache 统计（快路径命中率）──
    /// alloc 快路径命中（free_lists 有缓存）。
    cache_hits: std.atomic.Value(u64) = .{ .raw = 0 },
    /// alloc 慢路径 miss（触发 refill）。
    cache_misses: std.atomic.Value(u64) = .{ .raw = 0 },
    /// refill 调用次数（批量从 SlabAllocator 取 slot）。
    cache_refills: std.atomic.Value(u64) = .{ .raw = 0 },
    /// drain 调用次数（批量归还 slot 到 SlabAllocator）。
    cache_drains: std.atomic.Value(u64) = .{ .raw = 0 },

    pub fn init(enabled: bool, io: ?std.Io) Profiler {
        return .{ .enabled = enabled, .io = io };
    }

    // ── 阶段计时 API ──

    /// 标记某阶段开始。管线线性不嵌套，current_phase 不会被覆盖。
    pub fn phaseBegin(self: *Profiler, phase: Phase) void {
        if (!self.enabled) return;
        if (self.io) |io| {
            self.phase_start = std.Io.Timestamp.now(io, .awake);
            self.current_phase = phase;
        }
    }

    /// 标记当前阶段结束，累加墙钟耗时到对应 phase_ns 槽。
    pub fn phaseEnd(self: *Profiler) void {
        if (!self.enabled) return;
        if (self.phase_start) |start| {
            if (self.io) |io| {
                const end = std.Io.Timestamp.now(io, .awake);
                const ns: i96 = start.durationTo(end).nanoseconds;
                if (ns > 0) {
                    if (self.current_phase) |p| {
                        self.phase_ns[@intFromEnum(p)] += @intCast(ns);
                    }
                }
            }
        }
        self.phase_start = null;
        self.current_phase = null;
    }

    // ── VM opcode 计数 API（热路径，调用方需判 enabled）──

    pub fn recordOpcode(self: *Profiler, op_idx: u8) void {
        self.opcode_counts[op_idx] += 1;
    }

    pub fn setOpcodeNameFn(self: *Profiler, f: *const fn (u8) []const u8) void {
        self.opcode_name_fn = f;
    }

    // ── VM 调用统计 API（热路径，调用方需判 enabled）──

    pub inline fn recordCall(self: *Profiler) void {
        _ = self.vm_call_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordTailCall(self: *Profiler) void {
        _ = self.vm_tail_call_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordMethodCall(self: *Profiler) void {
        _ = self.vm_method_call_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordSpawn(self: *Profiler) void {
        _ = self.vm_spawn_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordAwait(self: *Profiler) void {
        _ = self.vm_await_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordCancel(self: *Profiler) void {
        _ = self.vm_cancel_count.fetchAdd(1, .monotonic);
    }
    pub inline fn recordMemoHit(self: *Profiler) void {
        _ = self.vm_memo_hits.fetchAdd(1, .monotonic);
    }
    pub inline fn recordMemoMiss(self: *Profiler) void {
        _ = self.vm_memo_misses.fetchAdd(1, .monotonic);
    }

    // ── ThreadCache 统计 API（热路径，调用方需判 enabled）──

    pub inline fn recordCacheHit(self: *Profiler) void {
        _ = self.cache_hits.fetchAdd(1, .monotonic);
    }
    pub inline fn recordCacheMiss(self: *Profiler) void {
        _ = self.cache_misses.fetchAdd(1, .monotonic);
    }
    pub inline fn recordRefill(self: *Profiler) void {
        _ = self.cache_refills.fetchAdd(1, .monotonic);
    }
    pub inline fn recordDrain(self: *Profiler) void {
        _ = self.cache_drains.fetchAdd(1, .monotonic);
    }

    // ── 内存统计注入 API ──

    /// 注入 SlabAllocator 完整统计：结束时刻快照 + 峰值。调用方在 VM 执行后、pool.deinit 前调用。
    /// SlabAllocator 自己追踪峰值（覆盖所有自增点，无采样间隙），故这里直接接收峰值而非自行采样。
    pub fn recordSlabStats(
        self: *Profiler,
        live: usize,
        reserved: usize,
        live_peak: usize,
        reserved_peak: usize,
    ) void {
        self.slab_live_bytes = live;
        self.slab_reserved_bytes = reserved;
        self.slab_live_peak_bytes = live_peak;
        self.slab_peak_bytes = reserved_peak;
    }

    /// 注入 SlabAllocator 缓存规模 + idle 回收累计统计。
    pub fn recordSlabCacheStats(
        self: *Profiler,
        empty_count: usize,
        large_active: usize,
        large_cached: usize,
        evicted_slabs: u64,
        evicted_large: u64,
        evict_scans: u64,
    ) void {
        self.slab_empty_count = empty_count;
        self.slab_large_active = large_active;
        self.slab_large_cached = large_cached;
        self.slab_evicted_slabs = evicted_slabs;
        self.slab_evicted_large = evicted_large;
        self.slab_evict_scans = evict_scans;
    }

    /// 注入 memoization 统计（结束时刻快照）。
    pub fn recordMemoStats(
        self: *Profiler,
        cache_size: usize,
        disabled_count: usize,
    ) void {
        self.vm_memo_cache_size = cache_size;
        self.vm_memo_disabled_count = disabled_count;
    }

    /// 注入 ThreadCache 命中率统计（结束时刻快照）。
    /// ThreadCache 维护自身非原子本地计数器（单线程快路径），由 main 在 dump 前一次性注入。
    pub fn recordCacheStats(
        self: *Profiler,
        hits: u64,
        misses: u64,
        refills: u64,
        drains: u64,
    ) void {
        self.cache_hits.store(hits, .monotonic);
        self.cache_misses.store(misses, .monotonic);
        self.cache_refills.store(refills, .monotonic);
        self.cache_drains.store(drains, .monotonic);
    }

    // ── 报告输出 ──

    pub fn dump(self: *Profiler, io: std.Io) void {
        if (!self.enabled) return;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        const wr = &w.interface;

        wr.print("\n[PROFILE]\n", .{}) catch {};

        // ── 阶段计时 ──
        var total_ns: u64 = 0;
        for (self.phase_ns) |n| total_ns += n;
        wr.print("phases (wall-clock):\n", .{}) catch {};
        for (self.phase_ns, 0..) |n, i| {
            if (n == 0) continue;
            const ms = @as(f64, @floatFromInt(n)) / 1e6;
            const pct = if (total_ns > 0)
                (@as(f64, @floatFromInt(n)) * 100.0) / @as(f64, @floatFromInt(total_ns))
            else
                0;
            wr.print("  {s: <14}: {d:>8.3} ms ({d:.1}%)\n", .{ PHASE_NAMES[i], ms, pct }) catch {};
        }
        const total_ms = @as(f64, @floatFromInt(total_ns)) / 1e6;
        wr.print("  {s: <14}: {d:>8.3} ms\n", .{ "total", total_ms }) catch {};

        // ── 内存统计 ──
        wr.print("\nmemory:\n", .{}) catch {};
        wr.print("  peak live     : {s}\n", .{formatBytes(self.slab_live_peak_bytes)}) catch {};
        wr.print("  peak reserved : {s}\n", .{formatBytes(self.slab_peak_bytes)}) catch {};
        // 碎片率基于峰值时刻：1 - live_peak/peak_reserved。
        if (self.slab_peak_bytes > 0) {
            const frag = 1.0 - (@as(f64, @floatFromInt(self.slab_live_peak_bytes)) /
                @as(f64, @floatFromInt(self.slab_peak_bytes)));
            wr.print("  fragmentation : {d:.1}%  (at peak)\n", .{frag * 100.0}) catch {};
        }
        wr.print("  final live    : {s}\n", .{formatBytes(self.slab_live_bytes)}) catch {};
        wr.print("  final reserved: {s}\n", .{formatBytes(self.slab_reserved_bytes)}) catch {};

        // 内存缓存规模 + idle 回收
        wr.print("\nmemory cache:\n", .{}) catch {};
        wr.print("  empty slabs cached : {d}\n", .{self.slab_empty_count}) catch {};
        wr.print("  large objects live : {d}\n", .{self.slab_large_active}) catch {};
        wr.print("  large objects idle : {d}\n", .{self.slab_large_cached}) catch {};
        if (self.slab_evict_scans > 0) {
            wr.print("  idle evict scans   : {d}\n", .{self.slab_evict_scans}) catch {};
            wr.print("  idle evicted slabs : {d}\n", .{self.slab_evicted_slabs}) catch {};
            wr.print("  idle evicted large : {d}\n", .{self.slab_evicted_large}) catch {};
        }

        // ── VM 调用统计 ──
        const calls = self.vm_call_count.load(.monotonic);
        const tail_calls = self.vm_tail_call_count.load(.monotonic);
        const method_calls = self.vm_method_call_count.load(.monotonic);
        const spawns = self.vm_spawn_count.load(.monotonic);
        const awaits = self.vm_await_count.load(.monotonic);
        const cancels = self.vm_cancel_count.load(.monotonic);
        if (calls + tail_calls + method_calls + spawns + awaits + cancels > 0) {
            wr.print("\nvm calls:\n", .{}) catch {};
            wr.print("  function calls : {d}\n", .{calls}) catch {};
            wr.print("  tail calls     : {d}  (TCO)\n", .{tail_calls}) catch {};
            wr.print("  method calls   : {d}\n", .{method_calls}) catch {};
            if (spawns > 0) wr.print("  spawns         : {d}\n", .{spawns}) catch {};
            if (awaits > 0) wr.print("  awaits         : {d}\n", .{awaits}) catch {};
            if (cancels > 0) wr.print("  cancels        : {d}\n", .{cancels}) catch {};
        }

        // ── memoization 统计 ──
        const memo_hits = self.vm_memo_hits.load(.monotonic);
        const memo_misses = self.vm_memo_misses.load(.monotonic);
        if (memo_hits + memo_misses > 0) {
            const memo_total = memo_hits + memo_misses;
            const hit_rate = (@as(f64, @floatFromInt(memo_hits)) * 100.0) /
                @as(f64, @floatFromInt(memo_total));
            wr.print("\nmemoization:\n", .{}) catch {};
            wr.print("  hits       : {d}\n", .{memo_hits}) catch {};
            wr.print("  misses     : {d}\n", .{memo_misses}) catch {};
            wr.print("  hit rate   : {d:.1}%\n", .{hit_rate}) catch {};
            wr.print("  cache size : {d}\n", .{self.vm_memo_cache_size}) catch {};
            wr.print("  disabled   : {d}\n", .{self.vm_memo_disabled_count}) catch {};
        }

        // ── ThreadCache 统计 ──
        const cache_h = self.cache_hits.load(.monotonic);
        const cache_m = self.cache_misses.load(.monotonic);
        if (cache_h + cache_m > 0) {
            const cache_total = cache_h + cache_m;
            const hit_rate = (@as(f64, @floatFromInt(cache_h)) * 100.0) /
                @as(f64, @floatFromInt(cache_total));
            wr.print("\nthread cache:\n", .{}) catch {};
            wr.print("  hits    : {d}\n", .{cache_h}) catch {};
            wr.print("  misses  : {d}\n", .{cache_m}) catch {};
            wr.print("  hit rate: {d:.1}%\n", .{hit_rate}) catch {};
            wr.print("  refills : {d}\n", .{self.cache_refills.load(.monotonic)}) catch {};
            wr.print("  drains  : {d}\n", .{self.cache_drains.load(.monotonic)}) catch {};
        }

        // ── VM opcode 频率（大类聚合 + top N 明细）──
        var total_opcodes: u64 = 0;
        for (self.opcode_counts) |c| total_opcodes += c;
        if (total_opcodes > 0) {
            // 大类聚合
            var cat_counts: [@typeInfo(OpCategory).@"enum".fields.len]u64 = .{0} ** @typeInfo(OpCategory).@"enum".fields.len;
            for (self.opcode_counts, 0..) |c, i| {
                if (c == 0) continue;
                const name: []const u8 = if (self.opcode_name_fn) |f| f(@intCast(i)) else "";
                const cat = if (name.len > 0) categorizeOpName(name) else .other;
                cat_counts[@intFromEnum(cat)] += c;
            }

            wr.print("\nvm opcodes by category:\n", .{}) catch {};
            // 收集非零大类并降序排序
            const CatEntry = struct { idx: usize, count: u64 };
            var cat_entries: [@typeInfo(OpCategory).@"enum".fields.len]CatEntry = undefined;
            var n_cats: usize = 0;
            for (cat_counts, 0..) |c, i| {
                if (c > 0) {
                    cat_entries[n_cats] = .{ .idx = i, .count = c };
                    n_cats += 1;
                }
            }
            std.mem.sort(CatEntry, cat_entries[0..n_cats], {}, struct {
                fn lt(_: void, a: CatEntry, b: CatEntry) bool {
                    return a.count > b.count;
                }
            }.lt);
            for (cat_entries[0..n_cats]) |e| {
                const pct = (@as(f64, @floatFromInt(e.count)) * 100.0) /
                    @as(f64, @floatFromInt(total_opcodes));
                wr.print("  {s: <20}: {d:>12} ({d:>5.1}%)\n", .{ OP_CATEGORY_NAMES[e.idx], e.count, pct }) catch {};
            }

            // Top N 明细
            wr.print("\nvm opcodes top 20:\n", .{}) catch {};
            const Entry = struct { idx: u8, count: u64 };
            var entries: [256]Entry = undefined;
            var n_entries: usize = 0;
            for (self.opcode_counts, 0..) |c, i| {
                if (c > 0) {
                    entries[n_entries] = .{ .idx = @intCast(i), .count = c };
                    n_entries += 1;
                }
            }
            std.mem.sort(Entry, entries[0..n_entries], {}, struct {
                fn lt(_: void, a: Entry, b: Entry) bool {
                    return a.count > b.count;
                }
            }.lt);
            const top_n = @min(n_entries, 20);
            for (entries[0..top_n]) |e| {
                const pct = (@as(f64, @floatFromInt(e.count)) * 100.0) /
                    @as(f64, @floatFromInt(total_opcodes));
                const name: []const u8 = if (self.opcode_name_fn) |f| f(e.idx) else "<idx>";
                wr.print("  {s: <24}: {d:>12} ({d:>5.1}%)\n", .{ name, e.count, pct }) catch {};
            }
            wr.print("  {s: <24}: {d:>12}\n", .{ "total", total_opcodes }) catch {};
            if (total_ns > 0 and self.phase_ns[@intFromEnum(Phase.vm)] > 0) {
                const mips = @as(f64, @floatFromInt(total_opcodes)) /
                    (@as(f64, @floatFromInt(self.phase_ns[@intFromEnum(Phase.vm)])) / 1e9);
                wr.print("  {s: <24}: {d:.2} M instr/s\n", .{ "throughput", mips / 1e6 }) catch {};
            }
        }

        w.flush() catch {};
    }
};

/// 字节数格式化（自动 KB/MB）。返回静态缓冲区，调用方立即使用。
fn formatBytes(bytes: usize) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    if (bytes < 1024) {
        return std.fmt.bufPrint(&Static.buf, "{d} B", .{bytes}) catch "<err>";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(&Static.buf, "{d:.1} KB", .{kb}) catch "<err>";
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(&Static.buf, "{d:.2} MB", .{mb}) catch "<err>";
    }
}
