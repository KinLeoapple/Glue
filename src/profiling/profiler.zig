//! 性能分析器。
//!
//! 收集编译与运行各阶段的耗时、VM 调用计数、内存 slab 统计、
//! 记忆化与线程缓存命中率，以及按类别分组的 opcode 执行频次，
//! 最终通过 dump 输出可读的报告到 stderr。

const std = @import("std");

/// 平台自适应计数器类型：64 位平台用 u64，32 位平台用 u32（避免 64 位原子不支持）。
const Counter = if (@sizeOf(usize) >= 8) u64 else u32;

/// 编译/运行阶段标识，用于阶段级耗时统计。
pub const Phase = enum {
    lex,
    parse,
    type_check,
    compile,
    vm,
};

/// 各阶段对应的显示名称，与 Phase 枚举顺序一致。
const PHASE_NAMES = [@typeInfo(Phase).@"enum".fields.len][]const u8{
    "lex",
    "parse",
    "type_check",
    "compile",
    "vm",
};

/// opcode 分类，用于将 256 个 opcode 归并为可读的统计维度。
const OpCategory = enum {
    const_literal,
    local,
    upvalue,
    global,
    arithmetic,
    comparison,
    bitwise,
    logical,
    jump,
    stack,
    call,
    tail_call,
    method,
    spawn,
    construct,
    access,
    assign,
    cast,
    exception,
    channel,
    other,
};

/// 各分类对应的显示名称，与 OpCategory 枚举顺序一致。
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

/// 根据 opcode 名称字符串推断其所属分类。
/// 匹配寄存器 VM 的 Op 枚举标签名（无 "op_" 前缀）。
fn categorizeOpName(name: []const u8) OpCategory {
    // 调用相关（顺序敏感：更具体的前缀先判断）
    if (std.mem.eql(u8, name, "tail_call")) return .tail_call;
    if (std.mem.startsWith(u8, name, "call_method")) return .method;
    if (std.mem.eql(u8, name, "call") or
        std.mem.eql(u8, name, "call_value") or
        std.mem.eql(u8, name, "call_native") or
        std.mem.eql(u8, name, "call_memoized") or
        std.mem.eql(u8, name, "return_op") or
        std.mem.eql(u8, name, "return_unit")) return .call;
    if (std.mem.eql(u8, name, "spawn")) return .spawn;
    // 构造
    if (std.mem.startsWith(u8, name, "make_")) return .construct;
    // 字段/索引访问
    if (std.mem.startsWith(u8, name, "get_field")) return .access;
    if (std.mem.startsWith(u8, name, "get_adt_field")) return .access;
    if (std.mem.startsWith(u8, name, "get_newtype_inner")) return .access;
    if (std.mem.startsWith(u8, name, "test_ctor")) return .access;
    if (std.mem.startsWith(u8, name, "test_newtype")) return .access;
    if (std.mem.eql(u8, name, "index_op")) return .access;
    if (std.mem.eql(u8, name, "record_extend")) return .access;
    if (std.mem.eql(u8, name, "concat_list")) return .access;
    if (std.mem.eql(u8, name, "test_lit")) return .access;
    if (std.mem.eql(u8, name, "match_fail")) return .access;
    // 赋值
    if (std.mem.startsWith(u8, name, "set_field")) return .assign;
    if (std.mem.eql(u8, name, "set_index")) return .assign;
    if (std.mem.eql(u8, name, "compound_local")) return .assign;
    if (std.mem.eql(u8, name, "push_inplace")) return .assign;
    if (std.mem.eql(u8, name, "bind") or
        std.mem.eql(u8, name, "assign") or
        std.mem.eql(u8, name, "bind_letrec")) return .assign;
    if (std.mem.eql(u8, name, "release")) return .assign;
    // 变量访问
    if (std.mem.eql(u8, name, "move") or
        std.mem.eql(u8, name, "move_raw")) return .local;
    if (std.mem.startsWith(u8, name, "get_upvalue") or
        std.mem.startsWith(u8, name, "set_upvalue")) return .upvalue;
    if (std.mem.eql(u8, name, "load_global") or
        std.mem.eql(u8, name, "store_global")) return .global;
    if (std.mem.eql(u8, name, "closure")) return .upvalue;
    // 常量/字面量
    if (std.mem.startsWith(u8, name, "load_const") or
        std.mem.eql(u8, name, "load_null") or
        std.mem.eql(u8, name, "load_unit") or
        std.mem.eql(u8, name, "load_true") or
        std.mem.eql(u8, name, "load_false")) return .const_literal;
    // 算术
    if (std.mem.eql(u8, name, "add") or
        std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "mul") or
        std.mem.eql(u8, name, "div") or
        std.mem.eql(u8, name, "mod") or
        std.mem.eql(u8, name, "neg")) return .arithmetic;
    // 比较
    if (std.mem.eql(u8, name, "eq") or
        std.mem.eql(u8, name, "neq") or
        std.mem.eql(u8, name, "lt") or
        std.mem.eql(u8, name, "gt") or
        std.mem.eql(u8, name, "le") or
        std.mem.eql(u8, name, "ge")) return .comparison;
    // 位运算与逻辑
    if (std.mem.eql(u8, name, "bit_and") or
        std.mem.eql(u8, name, "bit_or") or
        std.mem.eql(u8, name, "bit_xor")) return .bitwise;
    if (std.mem.eql(u8, name, "not_op")) return .logical;
    // 跳转
    if (std.mem.startsWith(u8, name, "jump")) return .jump;
    if (std.mem.eql(u8, name, "for_next")) return .jump;
    // 类型转换
    if (std.mem.eql(u8, name, "cast") or
        std.mem.eql(u8, name, "coerce") or
        std.mem.eql(u8, name, "interp")) return .cast;
    // 异常处理
    if (std.mem.eql(u8, name, "throw_op") or
        std.mem.eql(u8, name, "propagate") or
        std.mem.eql(u8, name, "non_null") or
        std.mem.startsWith(u8, name, "test_throw") or
        std.mem.startsWith(u8, name, "get_throw")) return .exception;
    // 通道
    if (std.mem.startsWith(u8, name, "try_recv") or
        std.mem.eql(u8, name, "recv")) return .channel;
    return .other;
}

/// 性能分析器，聚合各阶段耗时、VM 计数与内存统计。
/// 计数字段使用 atomic 以支持多线程安全更新。
pub const Profiler = struct {
    enabled: bool = false,
    io: ?std.Io = null,
    phase_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = .{0} ** @typeInfo(Phase).@"enum".fields.len,
    phase_start: ?std.Io.Timestamp = null,
    current_phase: ?Phase = null,
    opcode_counts: [256]u64 = .{0} ** 256,
    opcode_name_fn: ?*const fn (u8) []const u8 = null,
    slab_peak_bytes: usize = 0,
    slab_live_peak_bytes: usize = 0,
    slab_live_bytes: usize = 0,
    slab_reserved_bytes: usize = 0,
    slab_empty_count: usize = 0,
    slab_large_active: usize = 0,
    slab_large_cached: usize = 0,
    slab_evicted_slabs: u64 = 0,
    slab_evicted_large: u64 = 0,
    slab_evict_scans: u64 = 0,
    vm_call_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_tail_call_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_method_call_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_spawn_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_await_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_cancel_count: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_memo_hits: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_memo_misses: std.atomic.Value(Counter) = .{ .raw = 0 },
    vm_memo_cache_size: usize = 0,
    vm_memo_disabled_count: usize = 0,
    cache_hits: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_misses: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_refills: std.atomic.Value(Counter) = .{ .raw = 0 },
    cache_drains: std.atomic.Value(Counter) = .{ .raw = 0 },

    /// 创建分析器实例，enabled 控制是否实际采集数据。
    pub fn init(enabled: bool, io: ?std.Io) Profiler {
        return .{ .enabled = enabled, .io = io };
    }

    /// 标记某阶段开始计时。
    pub fn phaseBegin(self: *Profiler, phase: Phase) void {
        if (!self.enabled) return;
        if (self.io) |io| {
            self.phase_start = std.Io.Timestamp.now(io, .awake);
            self.current_phase = phase;
        }
    }

    /// 结束当前阶段计时，将耗时累加到对应 phase_ns 槽位。
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

    /// 记录某 opcode 的执行次数。
    pub fn recordOpcode(self: *Profiler, op_idx: u8) void {
        self.opcode_counts[op_idx] += 1;
    }

    /// 设置 opcode 索引到名称的映射函数，用于 dump 时显示可读名称。
    pub fn setOpcodeNameFn(self: *Profiler, f: *const fn (u8) []const u8) void {
        self.opcode_name_fn = f;
    }

    // VM 调用计数（原子操作，线程安全）
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

    // 记忆化命中/未命中计数
    pub inline fn recordMemoHit(self: *Profiler) void {
        _ = self.vm_memo_hits.fetchAdd(1, .monotonic);
    }
    pub inline fn recordMemoMiss(self: *Profiler) void {
        _ = self.vm_memo_misses.fetchAdd(1, .monotonic);
    }

    // 线程缓存命中/未命中/填充/排空计数
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

    /// 记录 slab 内存分配器的当前与峰值字节数。
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

    /// 记录 slab 缓存的空 slab 数、大对象数及驱逐统计。
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

    /// 记录记忆化缓存的当前大小与被禁用计数。
    pub fn recordMemoStats(
        self: *Profiler,
        cache_size: usize,
        disabled_count: usize,
    ) void {
        self.vm_memo_cache_size = cache_size;
        self.vm_memo_disabled_count = disabled_count;
    }

    /// 整体设置线程缓存统计（用于从外部汇总导入）。
    pub fn recordCacheStats(
        self: *Profiler,
        hits: u64,
        misses: u64,
        refills: u64,
        drains: u64,
    ) void {
        self.cache_hits.store(@intCast(hits), .monotonic);
        self.cache_misses.store(@intCast(misses), .monotonic);
        self.cache_refills.store(@intCast(refills), .monotonic);
        self.cache_drains.store(@intCast(drains), .monotonic);
    }

    /// 将所有采集到的统计以可读格式输出到 stderr。
    /// 包含阶段耗时、内存、调用计数、记忆化、线程缓存与 opcode 分布。
    pub fn dump(self: *Profiler, io: std.Io) void {
        if (!self.enabled) return;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        const wr = &w.interface;
        wr.print("\n[PROFILE]\n", .{}) catch {};

        // 阶段耗时
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

        // 内存统计
        wr.print("\nmemory:\n", .{}) catch {};
        wr.print("  peak live     : {s}\n", .{formatBytes(self.slab_live_peak_bytes)}) catch {};
        wr.print("  peak reserved : {s}\n", .{formatBytes(self.slab_peak_bytes)}) catch {};
        if (self.slab_peak_bytes > 0) {
            const frag = 1.0 - (@as(f64, @floatFromInt(self.slab_live_peak_bytes)) /
                @as(f64, @floatFromInt(self.slab_peak_bytes)));
            wr.print("  fragmentation : {d:.1}%  (at peak)\n", .{frag * 100.0}) catch {};
        }
        wr.print("  final live    : {s}\n", .{formatBytes(self.slab_live_bytes)}) catch {};
        wr.print("  final reserved: {s}\n", .{formatBytes(self.slab_reserved_bytes)}) catch {};

        // 内存缓存统计
        wr.print("\nmemory cache:\n", .{}) catch {};
        wr.print("  empty slabs cached : {d}\n", .{self.slab_empty_count}) catch {};
        wr.print("  large objects live : {d}\n", .{self.slab_large_active}) catch {};
        wr.print("  large objects idle : {d}\n", .{self.slab_large_cached}) catch {};
        if (self.slab_evict_scans > 0) {
            wr.print("  idle evict scans   : {d}\n", .{self.slab_evict_scans}) catch {};
            wr.print("  idle evicted slabs : {d}\n", .{self.slab_evicted_slabs}) catch {};
            wr.print("  idle evicted large : {d}\n", .{self.slab_evicted_large}) catch {};
        }

        // VM 调用统计
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

        // 记忆化统计
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

        // 线程缓存统计
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

        // opcode 分类统计与 Top 20
        var total_opcodes: u64 = 0;
        for (self.opcode_counts) |c| total_opcodes += c;
        if (total_opcodes > 0) {
            // 按类别聚合
            var cat_counts: [@typeInfo(OpCategory).@"enum".fields.len]u64 = .{0} ** @typeInfo(OpCategory).@"enum".fields.len;
            for (self.opcode_counts, 0..) |c, i| {
                if (c == 0) continue;
                const name: []const u8 = if (self.opcode_name_fn) |f| f(@intCast(i)) else "";
                const cat = if (name.len > 0) categorizeOpName(name) else .other;
                cat_counts[@intFromEnum(cat)] += c;
            }
            wr.print("\nvm opcodes by category:\n", .{}) catch {};
            const CatEntry = struct { idx: usize, count: u64 };
            var cat_entries: [@typeInfo(OpCategory).@"enum".fields.len]CatEntry = undefined;
            var n_cats: usize = 0;
            for (cat_counts, 0..) |c, i| {
                if (c > 0) {
                    cat_entries[n_cats] = .{ .idx = i, .count = c };
                    n_cats += 1;
                }
            }
            // 按计数降序排序
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

            // Top 20 opcode
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
            // 吞吐量：每秒指令数
            if (total_ns > 0 and self.phase_ns[@intFromEnum(Phase.vm)] > 0) {
                const mips = @as(f64, @floatFromInt(total_opcodes)) /
                    (@as(f64, @floatFromInt(self.phase_ns[@intFromEnum(Phase.vm)])) / 1e9);
                wr.print("  {s: <24}: {d:.2} M instr/s\n", .{ "throughput", mips / 1e6 }) catch {};
            }
        }
        w.flush() catch {};
    }
};

/// 将字节数格式化为人类可读的字符串（B/KB/MB）。
/// 使用静态缓冲区，结果在下一次调用前有效。
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
