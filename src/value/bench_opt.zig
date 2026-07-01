//! value 优化前后对比基准
//!
//! 对比 4 项优化：
//! 1. Int/Float: ByteArray union tag → [16]u8 + type.byteLength()
//! 2. format(): allocPrint → 栈缓冲 bufPrint
//! 3. Str: 移除每实例 allocator 字段（40B → 24B）
//! 4. retain/release: 17 显式分支 → inline prong
//!
//! 测量维度：
//! - 结构体大小（@sizeOf，编译期精确值）
//! - 分配次数（CountingAllocator 包装计数）
//! - CPU 周期（rdtsc，x86_64）
//! - 墙钟吞吐（std.Io.Clock）
//!
//! zig build bench-opt 运行

const std = @import("std");
const value_mod = @import("value");
const Int = value_mod.Int;
const Float = value_mod.Float;
const Str = value_mod.Str;
const Value = value_mod.Value;
const ByteArray = value_mod.ByteArray;
const IntType = value_mod.IntType;
const Char = value_mod.Char;

const Iterations = 1_000_000;
const FormatIterations = 100_000;
const RcIterations = 5_000_000;

// ============================================================
// 计数分配器（包装 page allocator，统计 alloc/free 次数与字节）
// ============================================================

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    bytes_allocated: u64 = 0,
    bytes_freed: u64 = 0,
    peak_in_use: u64 = 0,
    current_in_use: u64 = 0,

    fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        self.bytes_allocated += n;
        self.current_in_use += n;
        if (self.current_in_use > self.peak_in_use) self.peak_in_use = self.current_in_use;
        return self.backing.rawAlloc(n, alignment, ra);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            self.bytes_allocated += new_len - buf.len;
            self.current_in_use += new_len - buf.len;
        } else {
            self.bytes_freed += buf.len - new_len;
            self.current_in_use -= buf.len - new_len;
        }
        return self.backing.rawResize(buf, alignment, new_len, ra);
    }

    fn remapFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            self.bytes_allocated += new_len - buf.len;
            self.current_in_use += new_len - buf.len;
            if (self.current_in_use > self.peak_in_use) self.peak_in_use = self.current_in_use;
        } else {
            self.bytes_freed += buf.len - new_len;
            self.current_in_use -= buf.len - new_len;
        }
        return self.backing.rawRemap(buf, alignment, new_len, ra);
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.bytes_freed += buf.len;
        self.current_in_use -= buf.len;
        self.backing.rawFree(buf, alignment, ra);
    }

    fn reset(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.free_count = 0;
        self.bytes_allocated = 0;
        self.bytes_freed = 0;
        self.peak_in_use = 0;
        self.current_in_use = 0;
    }
};

// ============================================================
// rdtsc 周期计数（x86_64）
// ============================================================

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

inline fn rdtscStart() u64 {
    asm volatile ("lfence");
    return rdtsc();
}

inline fn rdtscEnd() u64 {
    const t = rdtsc();
    asm volatile ("lfence");
    return t;
}

// ============================================================
// Legacy 实现（优化前）
// ============================================================

/// 优化前的 ByteArray union（带 tag + switch 分派）
const LegacyByteArray = union(enum) {
    b1: [1]u8,
    b2: [2]u8,
    b4: [4]u8,
    b8: [8]u8,
    b16: [16]u8,

    pub fn byteLength(self: LegacyByteArray) u8 {
        return switch (self) {
            .b1 => 1,
            .b2 => 2,
            .b4 => 4,
            .b8 => 8,
            .b16 => 16,
        };
    }

    pub fn slice(self: *const LegacyByteArray) []const u8 {
        return switch (self.*) {
            .b1 => &self.b1,
            .b2 => &self.b2,
            .b4 => &self.b4,
            .b8 => &self.b8,
            .b16 => &self.b16,
        };
    }

    pub fn sliceMutable(self: *LegacyByteArray) []u8 {
        return switch (self.*) {
            .b1 => &self.b1,
            .b2 => &self.b2,
            .b4 => &self.b4,
            .b8 => &self.b8,
            .b16 => &self.b16,
        };
    }

    pub fn zero(byte_len: u8) LegacyByteArray {
        return switch (byte_len) {
            1 => .{ .b1 = [_]u8{0} },
            2 => .{ .b2 = [_]u8{0} ** 2 },
            4 => .{ .b4 = [_]u8{0} ** 4 },
            8 => .{ .b8 = [_]u8{0} ** 8 },
            16 => .{ .b16 = [_]u8{0} ** 16 },
            else => unreachable,
        };
    }
};

const LegacyIntType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,

    pub fn byteLength(self: LegacyIntType) u8 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32 => 4,
            .i64, .u64 => 8,
            .i128, .u128 => 16,
        };
    }

    pub fn isSigned(self: LegacyIntType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            else => false,
        };
    }
};

/// 优化前的 Int（type + ByteArray union，slice 经 switch 分派）
const LegacyInt = struct {
    type: LegacyIntType,
    bytes: LegacyByteArray,

    pub inline fn slice(self: *const LegacyInt) []const u8 {
        return self.bytes.slice();
    }

    pub inline fn sliceMutable(self: *LegacyInt) []u8 {
        return self.bytes.sliceMutable();
    }

    pub fn zero(t: LegacyIntType) LegacyInt {
        return .{ .type = t, .bytes = LegacyByteArray.zero(t.byteLength()) };
    }

    pub fn fromNative(t: LegacyIntType, v: i64) LegacyInt {
        const n = t.byteLength();
        var result = LegacyInt.zero(t);
        const src: [*]const u8 = @ptrCast(&v);
        const dst = result.bytes.sliceMutable();
        @memcpy(dst[0..n], src[0..n]);
        return result;
    }
};

/// 优化前的 Str（含 allocator 字段，40B）
const LegacyStr = struct {
    rc: u32 = 1,
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn fromLiteral(allocator: std.mem.Allocator, s: []const u8) !LegacyStr {
        const owned = try allocator.dupe(u8, s);
        return .{ .allocator = allocator, .bytes = owned };
    }

    pub fn deinit(self: *LegacyStr) void {
        self.allocator.free(self.bytes);
    }
};

// ============================================================
// 辅助：模拟优化前的 format()（allocPrint 路径）
// ============================================================

fn legacyFormatInt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), iv: i128) !void {
    const s = try std.fmt.allocPrint(allocator, "{d}", .{iv});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn legacyFormatFloat(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), fv: f64) !void {
    const s = try std.fmt.allocPrint(allocator, "{d}", .{fv});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// 优化后的 format()（栈缓冲 bufPrint 路径）
fn optimizedFormatInt(buf: *std.ArrayList(u8), iv: i128) !void {
    var temp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{iv}) catch unreachable;
    buf.appendSliceAssumeCapacity(s);
}

fn optimizedFormatFloat(buf: *std.ArrayList(u8), fv: f64) !void {
    var temp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{fv}) catch unreachable;
    buf.appendSliceAssumeCapacity(s);
}

// ============================================================
// 辅助：模拟优化前的 retain/release（17 显式分支）
// ============================================================

const LegacyDummy = struct {
    rc: u32 = 1,
};

const LegacyBoxed = union(enum) {
    p1: *LegacyDummy,
    p2: *LegacyDummy,
    p3: *LegacyDummy,
    p4: *LegacyDummy,
    p5: *LegacyDummy,
    p6: *LegacyDummy,
    p7: *LegacyDummy,
    p8: *LegacyDummy,
    p9: *LegacyDummy,
    p10: *LegacyDummy,
    p11: *LegacyDummy,
    p12: *LegacyDummy,
    p13: *LegacyDummy,
    p14: *LegacyDummy,
    p15: *LegacyDummy,
    p16: *LegacyDummy,
    p17: *LegacyDummy,

    fn retainLegacy(self: LegacyBoxed) void {
        switch (self) {
            .p1 => |p| p.rc += 1,
            .p2 => |p| p.rc += 1,
            .p3 => |p| p.rc += 1,
            .p4 => |p| p.rc += 1,
            .p5 => |p| p.rc += 1,
            .p6 => |p| p.rc += 1,
            .p7 => |p| p.rc += 1,
            .p8 => |p| p.rc += 1,
            .p9 => |p| p.rc += 1,
            .p10 => |p| p.rc += 1,
            .p11 => |p| p.rc += 1,
            .p12 => |p| p.rc += 1,
            .p13 => |p| p.rc += 1,
            .p14 => |p| p.rc += 1,
            .p15 => |p| p.rc += 1,
            .p16 => |p| p.rc += 1,
            .p17 => |p| p.rc += 1,
        }
    }

    fn releaseLegacy(self: LegacyBoxed) void {
        switch (self) {
            .p1 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p2 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p3 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p4 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p5 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p6 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p7 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p8 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p9 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p10 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p11 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p12 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p13 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p14 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p15 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p16 => |p| { if (p.rc > 1) p.rc -= 1; },
            .p17 => |p| { if (p.rc > 1) p.rc -= 1; },
        }
    }

    fn retainInline(self: LegacyBoxed) void {
        switch (self) {
            inline .p1, .p2, .p3, .p4, .p5, .p6, .p7, .p8,
            .p9, .p10, .p11, .p12, .p13, .p14, .p15, .p16, .p17 => |p| {
                p.rc += 1;
            },
        }
    }

    fn releaseInline(self: LegacyBoxed) void {
        switch (self) {
            inline .p1, .p2, .p3, .p4, .p5, .p6, .p7, .p8,
            .p9, .p10, .p11, .p12, .p13, .p14, .p15, .p16, .p17 => |p| {
                if (p.rc > 1) p.rc -= 1;
            },
        }
    }
};

// ============================================================
// 测量函数
// ============================================================

fn printSize(w: anytype, label: []const u8, size: usize) !void {
    try w.interface.print("{s:<42} {d:>6} bytes\n", .{ label, size });
    w.flush() catch {};
}

fn printAllocResult(w: anytype, label: []const u8, ca: CountingAllocator, ns: i96, iterations: u64) !void {
    const ns_per_op: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));
    try w.interface.print("{s:<42} alloc={d:>6} free={d:>6} bytes={d:>8} | {d:>8.2} ns/op\n", .{
        label, ca.alloc_count, ca.free_count, ca.bytes_allocated, ns_per_op,
    });
    w.flush() catch {};
}

fn printCycleResult(w: anytype, label: []const u8, total_cycles: u64, iterations: u64) !void {
    const cyc_per_op: f64 = @as(f64, @floatFromInt(total_cycles)) / @as(f64, @floatFromInt(iterations));
    try w.interface.print("{s:<42} {d:>10.2} cycles/op\n", .{ label, cyc_per_op });
    w.flush() catch {};
}

fn printThroughput(w: anytype, label: []const u8, ns: i96, iterations: u64) !void {
    const ns_per_op: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec: f64 = 1_000_000_000.0 / ns_per_op;
    try w.interface.print("{s:<42} {d:>10.2} ns/op   {d:>10.2} M ops/s\n", .{
        label, ns_per_op, ops_per_sec / 1_000_000.0,
    });
    w.flush() catch {};
}

fn slowdown(custom: i96, native: i96) f64 {
    return @as(f64, @floatFromInt(custom)) / @as(f64, @floatFromInt(native));
}

// ============================================================
// 基准 1：结构体大小（编译期精确值）
// ============================================================

fn benchStructSizes(w: anytype) !void {
    try w.interface.print("=== 基准 1：结构体大小对比（@sizeOf 编译期精确值）===\n\n", .{});
    w.flush() catch {};

    try printSize(w, "LegacyByteArray (union enum)", @sizeOf(LegacyByteArray));
    try printSize(w, "[16]u8 (new)", @sizeOf([16]u8));
    try w.interface.print("\n", .{});

    try printSize(w, "LegacyInt (type + ByteArray)", @sizeOf(LegacyInt));
    try printSize(w, "Int (type + [16]u8, new)", @sizeOf(Int));
    try w.interface.print("\n", .{});

    try printSize(w, "LegacyStr (rc + allocator + bytes)", @sizeOf(LegacyStr));
    try printSize(w, "Str (rc + bytes, new)", @sizeOf(Str));
    try w.interface.print("\n", .{});

    try printSize(w, "LegacyBoxed (17-prong union)", @sizeOf(LegacyBoxed));
    try printSize(w, "Value (full union, new)", @sizeOf(Value));
    try w.interface.print("\n", .{});
}

// ============================================================
// 基准 2：format() 分配次数 + 周期（allocPrint vs bufPrint）
// ============================================================

fn benchFormatAlloc(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 2：format() 分配次数对比 ===\n\n", .{});
    w.flush() catch {};

    var counting = CountingAllocator.init(std.heap.page_allocator);
    const cal = counting.allocator();

    // —— 优化前：allocPrint 路径 ——
    {
        counting.reset();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(cal);
        try buf.ensureTotalCapacity(cal, 4096);

        const start = std.Io.Clock.awake.now(io);
        for (0..FormatIterations) |i| {
            buf.clearRetainingCapacity();
            try legacyFormatInt(cal, &buf, @as(i128, @intCast(i)));
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "format int (legacy allocPrint)", counting, start.durationTo(end).nanoseconds, FormatIterations);
    }

    // —— 优化后：bufPrint 路径 ——
    {
        counting.reset();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(cal);
        try buf.ensureTotalCapacity(cal, 4096);

        const start = std.Io.Clock.awake.now(io);
        for (0..FormatIterations) |i| {
            buf.clearRetainingCapacity();
            try optimizedFormatInt(&buf, @as(i128, @intCast(i)));
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "format int (new bufPrint)", counting, start.durationTo(end).nanoseconds, FormatIterations);
    }

    try w.interface.print("\n", .{});

    // —— float 格式化 ——
    {
        counting.reset();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(cal);
        try buf.ensureTotalCapacity(cal, 4096);

        const start = std.Io.Clock.awake.now(io);
        for (0..FormatIterations) |i| {
            buf.clearRetainingCapacity();
            try legacyFormatFloat(cal, &buf, @as(f64, @floatFromInt(i)) * 3.14159);
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "format float (legacy allocPrint)", counting, start.durationTo(end).nanoseconds, FormatIterations);
    }

    {
        counting.reset();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(cal);
        try buf.ensureTotalCapacity(cal, 4096);

        const start = std.Io.Clock.awake.now(io);
        for (0..FormatIterations) |i| {
            buf.clearRetainingCapacity();
            try optimizedFormatFloat(&buf, @as(f64, @floatFromInt(i)) * 3.14159);
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "format float (new bufPrint)", counting, start.durationTo(end).nanoseconds, FormatIterations);
    }

    try w.interface.print("\n", .{});
}

// ============================================================
// 基准 3：slice() 分派周期（ByteArray switch vs [16]u8 直接切片）
// ============================================================

fn benchSliceDispatch(w: anytype) !void {
    try w.interface.print("=== 基准 3：slice() 分派周期对比（rdtsc）===\n\n", .{});
    w.flush() catch {};

    // 准备数据（用 volatile 防止编译器提升 slice() 出循环）
    var legacy_vals: [16]LegacyInt = undefined;
    var new_vals: [16]Int = undefined;
    for (0..16) |i| {
        legacy_vals[i] = LegacyInt.fromNative(.i64, @as(i64, @intCast(i)));
        new_vals[i] = Int.fromNative(.i64, @as(i64, @intCast(i)));
    }

    // —— Legacy: ByteArray union switch 分派 ——
    {
        var sum: usize = 0;
        const start = rdtscStart();
        for (0..Iterations) |i| {
            const idx = i & 0xF;
            const s = legacy_vals[idx].slice();
            sum += s[0];
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "slice() legacy (ByteArray switch)", end - start, Iterations);
    }

    // —— New: {lo, hi} 直接字段访问 ——
    {
        var sum: usize = 0;
        const start = rdtscStart();
        for (0..Iterations) |i| {
            const idx = i & 0xF;
            sum += @as(u8, @truncate(new_vals[idx].lo));
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "field access new ({lo,hi} direct)", end - start, Iterations);
    }

    try w.interface.print("\n", .{});

    // —— sliceMutable 对比 ——
    {
        var sum: usize = 0;
        const start = rdtscStart();
        for (0..Iterations) |i| {
            const idx = i & 0xF;
            const s = legacy_vals[idx].sliceMutable();
            sum += s[0];
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "sliceMutable() legacy", end - start, Iterations);
    }

    {
        var sum: usize = 0;
        const start = rdtscStart();
        for (0..Iterations) |i| {
            const idx = i & 0xF;
            sum += @as(u8, @truncate(new_vals[idx].lo));
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "field access new (mutable)", end - start, Iterations);
    }

    try w.interface.print("\n", .{});
}

// ============================================================
// 基准 4：retain/release 周期（17 分支 vs inline prong）
// ============================================================

fn benchRetainRelease(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 4：retain/release 周期对比 ===\n\n", .{});
    w.flush() catch {};

    // 准备 17 个 dummy 指针，用不同变体防止编译器折叠
    var dummies: [17]LegacyDummy = undefined;
    for (&dummies) |*d| d.* = .{ .rc = 100 };

    // 用轮转方式访问不同变体（防止分支预测器过度学习 + 防止编译器提升）
    const variants = [_]LegacyBoxed{
        .{ .p1 = &dummies[0] },  .{ .p2 = &dummies[1] },  .{ .p3 = &dummies[2] },
        .{ .p4 = &dummies[3] },  .{ .p5 = &dummies[4] },  .{ .p6 = &dummies[5] },
        .{ .p7 = &dummies[6] },  .{ .p8 = &dummies[7] },  .{ .p9 = &dummies[8] },
        .{ .p10 = &dummies[9] }, .{ .p11 = &dummies[10] }, .{ .p12 = &dummies[11] },
        .{ .p13 = &dummies[12] }, .{ .p14 = &dummies[13] }, .{ .p15 = &dummies[14] },
        .{ .p16 = &dummies[15] }, .{ .p17 = &dummies[16] },
    };

    // —— Legacy: 17 显式分支 retain（轮转访问 17 个变体）——
    {
        var sum: u64 = 0;
        const start = rdtscStart();
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.retainLegacy();
            sum +%= dummies[i % 17].rc;
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "retain() legacy (17 branches, rotating)", end - start, RcIterations);
    }

    // 重置 rc
    for (&dummies) |*d| d.* = .{ .rc = 100 };

    // —— New: inline prong retain（轮转访问 17 个变体）——
    {
        var sum: u64 = 0;
        const start = rdtscStart();
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.retainInline();
            sum +%= dummies[i % 17].rc;
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "retain() new (inline prong, rotating)", end - start, RcIterations);
    }

    try w.interface.print("\n", .{});

    // 重置 rc
    for (&dummies) |*d| d.* = .{ .rc = 100_000 };

    // —— Legacy: 17 显式分支 release ——
    {
        var sum: u64 = 0;
        const start = rdtscStart();
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.releaseLegacy();
            sum +%= dummies[i % 17].rc;
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "release() legacy (17 branches, rotating)", end - start, RcIterations);
    }

    // 重置 rc
    for (&dummies) |*d| d.* = .{ .rc = 100_000 };

    // —— New: inline prong release ——
    {
        var sum: u64 = 0;
        const start = rdtscStart();
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.releaseInline();
            sum +%= dummies[i % 17].rc;
        }
        const end = rdtscEnd();
        std.mem.doNotOptimizeAway(sum);
        try printCycleResult(w, "release() new (inline prong, rotating)", end - start, RcIterations);
    }

    try w.interface.print("\n", .{});

    // —— 墙钟吞吐：retain+release 配对（轮转）——
    for (&dummies) |*d| d.* = .{ .rc = 1_000_000 };
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.retainLegacy();
            v.releaseLegacy();
            sum +%= dummies[i % 17].rc;
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "retain+release legacy (rotating)", start.durationTo(end).nanoseconds, RcIterations);
    }

    for (&dummies) |*d| d.* = .{ .rc = 1_000_000 };
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..RcIterations) |i| {
            const v = variants[i % 17];
            v.retainInline();
            v.releaseInline();
            sum +%= dummies[i % 17].rc;
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "retain+release new (rotating)", start.durationTo(end).nanoseconds, RcIterations);
    }

    try w.interface.print("\n", .{});
}

// ============================================================
// 基准 5：Str 构造 + 释放（40B vs 24B，分配次数 + 周期）
// ============================================================

fn benchStrConstruct(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 5：Str 构造/释放对比（40B vs 24B）===\n\n", .{});
    w.flush() catch {};

    var counting = CountingAllocator.init(std.heap.page_allocator);
    const cal = counting.allocator();

    const StrIterations = 100_000;

    // —— Legacy Str（40B，含 allocator 字段）——
    {
        counting.reset();
        const start = std.Io.Clock.awake.now(io);
        for (0..StrIterations) |_| {
            var s = try LegacyStr.fromLiteral(cal, "hello world benchmark");
            s.deinit();
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "LegacyStr fromLiteral+deinit", counting, start.durationTo(end).nanoseconds, StrIterations);
    }

    // —— New Str（24B，无 allocator 字段）——
    {
        counting.reset();
        const start = std.Io.Clock.awake.now(io);
        for (0..StrIterations) |_| {
            var s = try Str.fromLiteral(cal, "hello world benchmark");
            s.deinit(cal);
        }
        const end = std.Io.Clock.awake.now(io);
        try printAllocResult(w, "Str fromLiteral+deinit (new)", counting, start.durationTo(end).nanoseconds, StrIterations);
    }

    try w.interface.print("\n", .{});

    // —— Str 堆分配大小对比（每实例）——
    try w.interface.print("每实例堆分配大小：\n", .{});
    try w.interface.print("  LegacyStr 堆头（allocator.destroy 开销）：{d} bytes\n", .{@sizeOf(LegacyStr)});
    try w.interface.print("  Str 堆头（new）：                        {d} bytes\n", .{@sizeOf(Str)});
    try w.interface.print("  每 Str 节省：                             {d} bytes ({d:.1}%)\n", .{
        @sizeOf(LegacyStr) - @sizeOf(Str),
        100.0 * @as(f64, @floatFromInt(@sizeOf(LegacyStr) - @sizeOf(Str))) / @as(f64, @floatFromInt(@sizeOf(LegacyStr))),
    });
    try w.interface.print("\n", .{});
    w.flush() catch {};
}

// ============================================================
// 基准 8：Str SSO（≤20B 内联零分配 vs >20B 堆分配）
// ============================================================

fn benchStrSso(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 8：Str SSO 短字符串内联对比 ===\n\n", .{});
    w.flush() catch {};

    var counting = CountingAllocator.init(std.heap.page_allocator);
    const cal = counting.allocator();

    const SsoIterations = 500_000;
    // 短字符串（10 字节，SSO 模式）
    const short_lit = "0123456789"; // 10 字节
    // 边界字符串（20 字节，SSO 模式上限）
    const boundary_lit = "0123456789ABCDEFGHIJ"; // 20 字节
    // 长字符串（30 字节，堆模式）
    const long_lit = "0123456789ABCDEFGHIJ0123456789"; // 30 字节

    // —— 短字符串 SSO ——
    {
        counting.reset();
        var checksum: usize = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..SsoIterations) |i| {
            var s = try Str.fromLiteral(cal, short_lit);
            std.mem.doNotOptimizeAway(s._word0);
            checksum +%= s.bytes()[0] ^ (i & 0xFF);
            s.deinit(cal);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(checksum);
        try printAllocResult(w, "Str 短(10B) SSO fromLiteral+deinit", counting, start.durationTo(end).nanoseconds, SsoIterations);
    }

    // —— 短字符串 LegacyStr（堆分配）——
    {
        counting.reset();
        var checksum: usize = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..SsoIterations) |i| {
            var s = try LegacyStr.fromLiteral(cal, short_lit);
            std.mem.doNotOptimizeAway(s.bytes.ptr);
            checksum +%= s.bytes[0] ^ (i & 0xFF);
            s.deinit();
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(checksum);
        try printAllocResult(w, "LegacyStr 短(10B) fromLiteral+deinit", counting, start.durationTo(end).nanoseconds, SsoIterations);
    }

    // —— 边界字符串 SSO（20 字节）——
    {
        counting.reset();
        var checksum: usize = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..SsoIterations) |i| {
            var s = try Str.fromLiteral(cal, boundary_lit);
            std.mem.doNotOptimizeAway(s._word0);
            checksum +%= s.bytes()[0] ^ (i & 0xFF);
            s.deinit(cal);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(checksum);
        try printAllocResult(w, "Str 边界(20B) SSO fromLiteral+deinit", counting, start.durationTo(end).nanoseconds, SsoIterations);
    }

    // —— 长字符串堆分配（30 字节）——
    {
        counting.reset();
        var checksum: usize = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..SsoIterations) |i| {
            var s = try Str.fromLiteral(cal, long_lit);
            std.mem.doNotOptimizeAway(s._word0);
            checksum +%= s.bytes()[0] ^ (i & 0xFF);
            s.deinit(cal);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(checksum);
        try printAllocResult(w, "Str 长(30B) heap fromLiteral+deinit", counting, start.durationTo(end).nanoseconds, SsoIterations);
    }

    // —— SSO concat（结果 ≤20B）——
    {
        counting.reset();
        var checksum: usize = 0;
        var a = try Str.fromLiteral(cal, "abc");
        defer a.deinit(cal);
        var b = try Str.fromLiteral(cal, "def");
        defer b.deinit(cal);
        const start = std.Io.Clock.awake.now(io);
        for (0..SsoIterations) |i| {
            var c = try a.concat(cal, b);
            std.mem.doNotOptimizeAway(c._word0);
            checksum +%= c.bytes()[0] ^ (i & 0xFF);
            c.deinit(cal);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(checksum);
        try printAllocResult(w, "Str concat SSO(6B) result", counting, start.durationTo(end).nanoseconds, SsoIterations);
    }

    try w.interface.print("\n", .{});
    try w.interface.print("SSO 阈值：{d} 字节（rc bit31=SSO 标志，bits 0-4=长度）\n", .{Str.SSO_MAX});
    try w.interface.print("短字符串 fromLiteral 零字节堆分配（deinit 也是 no-op）\n", .{});
    try w.interface.print("\n", .{});
    w.flush() catch {};
}

// ============================================================
// 基准 6：Int 算术吞吐（ ByteArray vs [16]u8 ）
// ============================================================

fn benchIntArith(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 6：Int 算术吞吐对比（含 slice 分派开销）===\n\n", .{});
    w.flush() catch {};

    // —— i64 加法：legacy ——
    {
        var acc = LegacyInt.fromNative(.i64, 0);
        var i: i64 = 0;
        const start = std.Io.Clock.awake.now(io);
        while (i < Iterations) : (i += 1) {
            const other = LegacyInt.fromNative(.i64, i);
            // 模拟算术中的 slice 访问
            const a = acc.slice();
            const b = other.slice();
            var result: [16]u8 = [_]u8{0} ** 16;
            @memcpy(result[0..a.len], a);
            for (0..a.len) |j| result[j] +%= b[j];
            const dst = acc.bytes.sliceMutable();
            @memcpy(dst[0..a.len], result[0..a.len]);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i64 add (legacy ByteArray)", start.durationTo(end).nanoseconds, Iterations);
    }

    // —— i64 加法：new ——
    {
        var acc = Int.fromNative(.i64, @as(i64, 0));
        var i: i64 = 0;
        const start = std.Io.Clock.awake.now(io);
        while (i < Iterations) : (i += 1) {
            const other = Int.fromNative(.i64, @as(i64, i));
            acc = acc.add(other).result;
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i64 add (new u64 native)", start.durationTo(end).nanoseconds, Iterations);
    }

    try w.interface.print("\n", .{});

    // —— i128 加法：legacy ——
    {
        var acc = LegacyInt.fromNative(.i128, 0);
        var i: i128 = 0;
        const start = std.Io.Clock.awake.now(io);
        while (i < Iterations) : (i += 1) {
            const other = LegacyInt.fromNative(.i128, @as(i64, @intCast(i)));
            const a = acc.slice();
            const b = other.slice();
            var result: [16]u8 = [_]u8{0} ** 16;
            @memcpy(result[0..a.len], a);
            for (0..a.len) |j| result[j] +%= b[j];
            const dst = acc.bytes.sliceMutable();
            @memcpy(dst[0..a.len], result[0..a.len]);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i128 add (legacy ByteArray)", start.durationTo(end).nanoseconds, Iterations);
    }

    // —— i128 加法：new ——
    {
        var acc = Int.fromNative(.i128, @as(i128, 0));
        var i: i128 = 0;
        const start = std.Io.Clock.awake.now(io);
        while (i < Iterations) : (i += 1) {
            const other = Int.fromNative(.i128, @as(i128, i));
            acc = acc.add(other).result;
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i128 add (new U128 word-level)", start.durationTo(end).nanoseconds, Iterations);
    }

    try w.interface.print("\n", .{});
}

// ============================================================
// 基准 7：i128 辅助函数字块化对比（byte-level vs u64 word-level）
// 对比 5：compareBytes / isAllZero / negateBytesInPlace / unsignedDivide
// ============================================================

/// 旧实现：逐字节 compareBytes（优化前）
fn legacyCompareBytes(a: []const u8, b: []const u8) std.math.Order {
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return .lt;
        if (a[i] > b[i]) return .gt;
    }
    return .eq;
}

/// 旧实现：逐字节 negateBytesInPlace
fn legacyNegateBytesInPlace(s: []u8) void {
    var carry: u16 = 1;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const inv: u8 = ~s[i];
        const sum: u16 = @as(u16, inv) + carry;
        s[i] = @truncate(sum);
        carry = sum >> 8;
    }
}

/// 旧实现：逐字节 shiftLeftOneBit
fn legacyShiftLeftOneBit(s: []u8) void {
    var carry: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const new_byte: u8 = (s[i] << 1) | carry;
        carry = s[i] >> 7;
        s[i] = new_byte;
    }
}

/// 旧实现：逐字节 subtractBytesInPlace
fn legacySubtractBytesInPlace(a: []u8, b: []const u8) void {
    var borrow: i16 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const bi: u16 = if (i < b.len) b[i] else 0;
        const diff: i16 = @as(i16, a[i]) - @as(i16, @intCast(bi)) - borrow;
        if (diff < 0) {
            a[i] = @intCast(diff + 256);
            borrow = 1;
        } else {
            a[i] = @intCast(diff);
            borrow = 0;
        }
    }
}

/// 旧实现：逐位恢复式长除法（128 次迭代 × 每次约 48 次字节操作）
fn legacyUnsignedDivide(a: []const u8, b: []const u8, quotient: []u8, remainder: []u8) void {
    @memset(quotient, 0);
    @memset(remainder, 0);
    const total_bits = a.len * 8;
    var bit: usize = total_bits;
    while (bit > 0) {
        bit -= 1;
        legacyShiftLeftOneBit(remainder);
        const byte_idx = bit / 8;
        const bit_idx: u3 = @intCast(bit % 8);
        if ((a[byte_idx] >> bit_idx) & 1 != 0) {
            remainder[0] |= 1;
        }
        if (legacyCompareBytes(remainder[0..b.len], b) != .lt) {
            legacySubtractBytesInPlace(remainder[0..b.len], b);
            quotient[byte_idx] |= (@as(u8, 1) << bit_idx);
        }
    }
}

fn benchIntHelpers(w: anytype, io: std.Io) !void {
    try w.interface.print("=== 基准 7：i128 辅助函数字块化对比（byte-level vs u64 word-level）===\n\n", .{});
    w.flush() catch {};

    // 准备 i128 测试数据（覆盖正/负/极值，避免编译器提升）
    const vals = [_]Int{
        Int.fromNative(.i128, @as(i128, 0)),
        Int.fromNative(.i128, @as(i128, 1)),
        Int.fromNative(.i128, @as(i128, -1)),
        Int.fromNative(.i128, @as(i128, 123456789)),
        Int.fromNative(.i128, @as(i128, -987654321)),
        Int.fromNative(.i128, @as(i128, std.math.maxInt(i128))),
        Int.fromNative(.i128, @as(i128, std.math.minInt(i128))),
        Int.fromNative(.i128, @as(i128, std.math.minInt(i128) + 1)),
    };
    const n_vals = vals.len;

    // —— i128 compare ——
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..Iterations) |i| {
            const a = vals[i % n_vals];
            const b = vals[(i + 1) % n_vals];
            // 旧实现：逐字节 compareBytes（复制 int.zig 优化前逻辑）
            var a_buf: [16]u8 = undefined;
            var b_buf: [16]u8 = undefined;
            a.toBytes(&a_buf);
            b.toBytes(&b_buf);
            const a_len: usize = a.type.byteLength();
            const b_len: usize = b.type.byteLength();
            const a_neg = a.type.isSigned() and (a_buf[a_len - 1] & 0x80) != 0;
            const b_neg = b.type.isSigned() and (b_buf[b_len - 1] & 0x80) != 0;
            var ord: std.math.Order = .eq;
            if (a_neg != b_neg) {
                ord = if (a_neg) .lt else .gt;
            } else {
                ord = legacyCompareBytes(a_buf[0..a_len], b_buf[0..b_len]);
            }
            sum +%= @intFromEnum(ord);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 compare (legacy byte-level)", start.durationTo(end).nanoseconds, Iterations);
    }
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..Iterations) |i| {
            const a = vals[i % n_vals];
            const b = vals[(i + 1) % n_vals];
            const ord = a.compare(b);
            sum +%= @intFromEnum(ord);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 compare (new u64 word-level)", start.durationTo(end).nanoseconds, Iterations);
    }
    try w.interface.print("\n", .{});

    // —— i128 multiply ——
    {
        var acc: [16]u8 = [_]u8{0} ** 16;
        const start = std.Io.Clock.awake.now(io);
        for (0..Iterations) |i| {
            const a = vals[i % n_vals];
            const b = vals[(i + 1) % n_vals];
            // 旧实现：逐字节 negate + schoolbook + 逐字节 overflow 判定
            var abs_a: [16]u8 = [_]u8{0} ** 16;
            var abs_b: [16]u8 = [_]u8{0} ** 16;
            a.toBytes(&abs_a);
            b.toBytes(&abs_b);
            if (a.type.isSigned() and a.isNegative()) legacyNegateBytesInPlace(abs_a[0..16]);
            if (b.type.isSigned() and b.isNegative()) legacyNegateBytesInPlace(abs_b[0..16]);
            // 简化：只跑 16 字节 schoolbook 等价的逐字节乘积累加（模拟优化前开销）
            var magnitude: [32]u8 = [_]u8{0} ** 32;
            for (0..16) |j| {
                for (0..16) |k| {
                    const prod: u16 = @as(u16, abs_a[j]) * @as(u16, abs_b[k]);
                    var carry: u16 = prod;
                    var idx = j + k;
                    while (idx < 32 and carry != 0) : (idx += 1) {
                        const sum: u16 = @as(u16, magnitude[idx]) + carry;
                        magnitude[idx] = @truncate(sum);
                        carry = sum >> 8;
                    }
                }
            }
            // 逐字节 overflow 检查（高 16 字节）
            var overflow = false;
            for (magnitude[16..32]) |byte| {
                if (byte != 0) {
                    overflow = true;
                    break;
                }
            }
            @memcpy(acc[0..16], magnitude[0..16]);
            std.mem.doNotOptimizeAway(overflow);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i128 multiply (legacy byte-level)", start.durationTo(end).nanoseconds, Iterations);
    }
    {
        var acc: [16]u8 = [_]u8{0} ** 16;
        const start = std.Io.Clock.awake.now(io);
        for (0..Iterations) |i| {
            const a = vals[i % n_vals];
            const b = vals[(i + 1) % n_vals];
            const r = a.multiply(b);
            r.result.toBytes(&acc);
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(acc);
        try printThroughput(w, "i128 multiply (new u64 word-level)", start.durationTo(end).nanoseconds, Iterations);
    }
    try w.interface.print("\n", .{});

    // —— i128 divide：三条路径分别测 ——
    const DivIters = 200_000; // 除法较慢，减少迭代数
    const small_div = Int.fromNative(.i128, @as(i128, 7)); // 路径 2：d ≤ 2^32
    const mid_div = Int.fromNative(.i128, @as(i128, 1) << 60); // 路径 3：d > 2^32，fit u64

    // 路径 2：小除数
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..DivIters) |i| {
            const a = vals[i % n_vals];
            const q = a.divideTruncating(small_div) catch continue;
            sum +%= @as(u8, @truncate(q.lo));
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 / 7 (new path2: 2x native div)", start.durationTo(end).nanoseconds, DivIters);
    }
    // 路径 3：中除数
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..DivIters) |i| {
            const a = vals[i % n_vals];
            const q = a.divideTruncating(mid_div) catch continue;
            sum +%= @as(u8, @truncate(q.lo));
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 / 2^60 (new path3: 64-iter bit-level)", start.durationTo(end).nanoseconds, DivIters);
    }
    // 路径 1：大除数（u128 / 2^100）
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..DivIters) |i| {
            const a = vals[i % n_vals];
            // a 是 i128，强转为 u128 语义：直接用 divideTruncating 测大除数路径
            // 对负数 a，divideTruncating 会先取绝对值；用 large_div（u128）需类型匹配
            const q = a.divideTruncating(Int.fromNative(.i128, @as(i128, @bitCast(@as(u128, 1) << 100)))) catch continue;
            sum +%= @as(u8, @truncate(q.lo));
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 / 2^100 (new path1: 128-iter U128)", start.durationTo(end).nanoseconds, DivIters);
    }
    // 旧实现：逐位恢复式长除法（与三条新路径对比）
    {
        var sum: u64 = 0;
        const start = std.Io.Clock.awake.now(io);
        for (0..DivIters) |i| {
            const a = vals[i % n_vals];
            // 取绝对值
            var abs_a: [16]u8 = [_]u8{0} ** 16;
            a.toBytes(&abs_a);
            if (a.type.isSigned() and a.isNegative()) legacyNegateBytesInPlace(abs_a[0..16]);
            // 旧除数：用 7（与路径 2 对比，体现算法差异而非除数大小差异）
            var abs_b: [16]u8 = [_]u8{0} ** 16;
            abs_b[0] = 7;
            var q_buf: [16]u8 = [_]u8{0} ** 16;
            var r_buf: [17]u8 = [_]u8{0} ** 17;
            legacyUnsignedDivide(abs_a[0..16], abs_b[0..16], q_buf[0..16], r_buf[0..17]);
            sum +%= q_buf[0];
        }
        const end = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(sum);
        try printThroughput(w, "i128 / 7 (legacy byte-level long division)", start.durationTo(end).nanoseconds, DivIters);
    }
    try w.interface.print("\n", .{});
    w.flush() catch {};
}

// ============================================================
// main
// ============================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);

    try w.interface.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try w.interface.print("║         Value 优化前后性能对比基准（Zig 0.16.0）            ║\n", .{});
    try w.interface.print("║  1. Int/Float: ByteArray union → [16]u8                     ║\n", .{});
    try w.interface.print("║  2. format(): allocPrint → bufPrint                          ║\n", .{});
    try w.interface.print("║  3. Str: 移除 allocator 字段 (40B→24B)                      ║\n", .{});
    try w.interface.print("║  4. retain/release: 17 branches → inline prong              ║\n", .{});
    try w.interface.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});
    w.flush() catch {};

    try benchStructSizes(&w);
    try benchFormatAlloc(&w, io);
    try benchSliceDispatch(&w);
    try benchRetainRelease(&w, io);
    try benchStrConstruct(&w, io);
    try benchStrSso(&w, io);
    try benchIntArith(&w, io);
    try benchIntHelpers(&w, io);

    try w.interface.print("=== 基准完成 ===\n", .{});
    w.flush() catch {};
}
